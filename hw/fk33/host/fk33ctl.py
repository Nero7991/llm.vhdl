#!/usr/bin/env python3
"""Host-side control of the FK33 over PCIe.  No dependencies beyond CPython.

Two paths into the card, both provided by the XDMA driver:

  /dev/xdma0_user     the AXI-Lite BAR.  MMIO, ~1 us per access, reaches
                      SYSMON at 0x3400 and the I2C bit-bang GPIO at 0x9000.
  /dev/xdma0_h2c_0    DMA into HBM.  The file offset IS the HBM byte address,
  /dev/xdma0_c2h_0    flat and contiguous from 0 to 0x1_FFFF_FFFF (8 GB).

Subcommands, in the order they should first be run.  Each does strictly more
than the last, so a failure localises itself:

  sysmon     MMIO read only.  Proves BAR -> AXI-Lite -> peripheral.  No DMA.
  gpio       MMIO read of the I2C pins.  Proves MMIO WRITES land (SYSMON is
             read-only, so it cannot show that).  Drives nothing.
  vccint     raise VCCINT to ~0.717 V over MMIO.  This is the same volatile
             digital-pot write that tcl/vccint_step.tcl does over JTAG, and it
             is what eventually removes JTAG from the loop: the rail powers up
             at 0.678 V, below the -2L floor, on every single power cycle.
  selftest   4 KB DMA write, read back, compare.  Proves the DMA engines.
  bench      throughput.  This number, not a datasheet, sets the cold weight
             load time.
  load       write a file into HBM at an offset, then verify it.
  verify     read HBM back and compare against a file.

Nothing here needs root once the udev rule from build_xdma_driver.sh is in
place.
"""
import argparse
import hashlib
import os
import struct
import sys
import time

USER = "/dev/xdma0_user"
H2C = "/dev/xdma0_h2c_0"
C2H = "/dev/xdma0_c2h_0"

HBM_SIZE = 0x2_0000_0000          # 8 GB, 0 .. 0x1FFFFFFFF
SYSMON_TEMP = 0x3400
SYSMON_VCCINT = 0x3404
GPIO_DAT = 0x9000                 # channel 1: bit0 = SCL (BB24), bit1 = SDA (BA24)
GPIO_TRI = 0x9004                 # 1 = released (board pull-up), 0 = driven low
POT_ADDR = 0x2C                   # MCP45XX-class digital pot, VCCINT

# Matches tcl/vccint_step.tcl.  Do not widen these without re-reading the
# reasoning there; the safety argument is in the code, not in a comment.
V_TARGET, V_LO, V_HI = 0.720, 0.716, 0.728
V_CEILING = 0.760
W_FLOOR, W_DEFAULT = 60, 128
DV_MAX, W_STEP_MAX = 0.035, 4


# ---------------------------------------------------------------- MMIO

class Mmio:
    def __init__(self, path=USER):
        try:
            self.fd = os.open(path, os.O_RDWR | os.O_SYNC)
        except FileNotFoundError:
            sys.exit(f"{path} does not exist.\n"
                     "The xdma driver is not loaded or did not bind.  Run\n"
                     "  ./fk33_pcie_check.sh\n"
                     "which will say which of those it is.")

    def rd(self, off):
        return struct.unpack("<I", os.pread(self.fd, 4, off))[0]

    def wr(self, off, val):
        os.pwrite(self.fd, struct.pack("<I", val & 0xFFFFFFFF), off)

    def close(self):
        os.close(self.fd)


def die_temp(m):
    return m.rd(SYSMON_TEMP) * 507.6 / 65536.0 - 279.43


def vccint(m, n=3):
    # Median of n, same as the JTAG script: one bad ADC sample must not be able
    # to move a voltage decision.
    return sorted(m.rd(SYSMON_VCCINT) * 3.0 / 65536.0 for _ in range(n))[n // 2]


# ---------------------------------------------------------------- bit-banged I2C
#
# Strict open drain, exactly as tcl/i2cbang.tcl: GPIO_DAT is written once to
# zero and never again, and every edge is made through GPIO_TRI.  The pins can
# therefore be pulled low or released, never driven high against another
# controller.  That rule is the whole safety argument for touching this bus at
# all, and it is enforced here by never calling wr(GPIO_DAT, ...) after setup.

class I2C:
    def __init__(self, m):
        self.m = m
        m.wr(GPIO_DAT, 0)
        self.lines(1, 1)

    def lines(self, scl, sda):
        self.m.wr(GPIO_TRI, (1 if scl else 0) | (2 if sda else 0))

    def sda_in(self):
        return (self.m.rd(GPIO_DAT) >> 1) & 1

    def scl_in(self):
        return self.m.rd(GPIO_DAT) & 1

    def start(self):
        self.lines(1, 1); self.lines(1, 0); self.lines(0, 0)

    def stop(self):
        self.lines(0, 0); self.lines(1, 0); self.lines(1, 1)

    def wbit(self, b):
        self.lines(0, b); self.lines(1, b); self.lines(0, b)

    def rbit(self):
        self.lines(0, 1); self.lines(1, 1)
        v = self.sda_in()
        self.lines(0, 1)
        return v

    def wbyte(self, v):
        for i in range(7, -1, -1):
            self.wbit((v >> i) & 1)
        return self.rbit()        # 0 = ACK

    def rbyte(self, ack):
        v = 0
        for _ in range(8):
            v = (v << 1) | self.rbit()
        self.wbit(0 if ack else 1)
        return v

    def pot_write(self, addr, wiper):
        if not 0 <= wiper <= 255:
            raise ValueError(f"wiper {wiper} out of range")
        self.start()
        k = self.wbyte((addr << 1) & 0xFE)
        k += self.wbyte(0x00)     # volatile wiper 0; a power cycle undoes it
        k += self.wbyte(wiper)
        self.stop()
        return k                  # 0 means every byte was acknowledged

    def pot_read(self, addr):
        self.start()
        if self.wbyte((addr << 1) | 1) != 0:
            self.stop()
            return -1
        hi = self.rbyte(True)
        lo = self.rbyte(False)
        self.stop()
        return (hi << 8) | lo


# ---------------------------------------------------------------- DMA

def dma_write(off, data):
    fd = os.open(H2C, os.O_WRONLY)
    try:
        n, mv = 0, memoryview(data)
        while n < len(mv):
            n += os.pwrite(fd, mv[n:n + (8 << 20)], off + n)
        return n
    finally:
        os.close(fd)


def dma_read(off, length):
    fd = os.open(C2H, os.O_RDONLY)
    try:
        out, n = bytearray(length), 0
        mv = memoryview(out)
        while n < length:
            chunk = os.pread(fd, min(8 << 20, length - n), off + n)
            if not chunk:
                raise IOError(f"short read at HBM offset {off + n:#x}")
            mv[n:n + len(chunk)] = chunk
            n += len(chunk)
        return bytes(out)
    finally:
        os.close(fd)


def check_range(off, length):
    if off < 0 or off + length > HBM_SIZE:
        sys.exit(f"HBM range {off:#x}..{off + length:#x} is outside the 8 GB map "
                 f"(0..{HBM_SIZE - 1:#x})")


# ---------------------------------------------------------------- commands

def cmd_sysmon(a):
    m = Mmio()
    t, v = die_temp(m), vccint(m)
    print(f"die temperature  {t:6.1f} C")
    print(f"VCCINT           {v:6.4f} V")
    if not 5.0 < t < 95.0:
        print("  IMPLAUSIBLE temperature -- SYSMON may be unclocked, which "
              "would mean the AXI-Lite path is not really working")
    if v < 0.698:
        print(f"  BELOW the 0.698 V -2L floor.  Run: {sys.argv[0]} vccint")
    elif v > V_CEILING:
        print(f"  ABOVE the {V_CEILING} V ceiling -- investigate before loading weights")
    else:
        print("  in spec")
    print("\nCross-check this against hw/fk33/pcieep.sh --check, which reads the"
          "\nsame registers over JTAG.  Agreement proves the PCIe MMIO path end"
          "\nto end against a path that is already trusted.")
    m.close()


def cmd_gpio(a):
    m = Mmio()
    tri, dat = m.rd(GPIO_TRI), m.rd(GPIO_DAT)
    print(f"GPIO_TRI  0x{tri:08x}   (1 = released; reset value is all-ones)")
    print(f"GPIO_DAT  0x{dat:08x}   bit0 = SCL, bit1 = SDA")
    print(f"  SCL reads {dat & 1}, SDA reads {(dat >> 1) & 1} -- both must be 1")
    print("  Both high means a live pull-up on BB24/BA24, so the bus exists.")
    m.close()


def cmd_vccint(a):
    """Step the pot up in voltage, verifying on SYSMON after every step.

    The safety structure is deliberately the same as tcl/vccint_step.tcl, and
    for the same reason: the first move is one step in the WRONG direction, so
    that if the sign of dV/dwiper is misunderstood we find out while moving
    AWAY from overvoltage rather than towards it.
    """
    m = Mmio()
    i2c = I2C(m)
    w = i2c.pot_read(POT_ADDR)
    v = vccint(m)
    print(f"START   wiper={w}  VCCINT={v:.4f} V  die={die_temp(m):.1f} C")
    if w < 0:
        sys.exit("ABORT: the pot did not acknowledge.  Nothing was written.")
    if not W_FLOOR <= w <= W_DEFAULT:
        sys.exit(f"ABORT: wiper {w} is outside the sane band {W_FLOOR}..{W_DEFAULT}. "
                 "Not touching anything.")
    if V_LO <= v <= V_HI:
        print("already in the acceptance band; nothing to do")
        return

    def revert(why):
        print(f"ABORT: {why}\n  reverting wiper to the factory default {W_DEFAULT}")
        i2c.pot_write(POT_ADDR, W_DEFAULT)
        time.sleep(0.2)
        print(f"  wiper now {i2c.pot_read(POT_ADDR)}, VCCINT {vccint(m):.4f} V")
        sys.exit(1)

    print("SAFETY PROBE: one step in the WRONG direction first")
    if i2c.pot_write(POT_ADDR, w + 1) != 0:
        sys.exit("ABORT: pot did not acknowledge the write.  Nothing changed.")
    time.sleep(0.2)
    v1 = vccint(m)
    if i2c.pot_read(POT_ADDR) != w + 1:
        revert("wiper did not read back what was written")
    if v1 >= v:
        revert(f"wiper up gave {v1:.4f} V, expected a DROP from {v:.4f} V; "
               "the sign of dV/dwiper is not what this code assumes")
    print(f"  wiper {w + 1}  VCCINT {v1:.4f} V  (dropped, as expected)")
    step_v = v - v1

    w, v = w + 1, v1
    while not V_LO <= v <= V_HI:
        need = (V_TARGET - v) / step_v if step_v > 1e-6 else 1
        step = max(1, min(W_STEP_MAX, int(abs(need))))
        nw = w - step
        if nw < W_FLOOR:
            revert(f"next step would take the wiper to {nw}, below the floor {W_FLOOR}")
        if i2c.pot_write(POT_ADDR, nw) != 0:
            revert("pot did not acknowledge")
        time.sleep(0.2)
        nv = vccint(m)
        if i2c.pot_read(POT_ADDR) != nw:
            revert("wiper did not read back")
        if nv > V_CEILING:
            revert(f"VCCINT {nv:.4f} V exceeded the {V_CEILING} V ceiling")
        if abs(nv - v) > DV_MAX:
            revert(f"a single move changed the rail by {abs(nv - v):.4f} V, "
                   f"more than the {DV_MAX} V cap")
        if nv < v:
            revert(f"wiper down gave {nv:.4f} V, lower than {v:.4f} V")
        print(f"  wiper {nw}  VCCINT {nv:.4f} V")
        step_v = max(1e-6, (nv - v) / step)
        w, v = nw, nv

    print(f"SETTLED wiper={w}  VCCINT={v:.4f} V  die={die_temp(m):.1f} C")
    print("This is VOLATILE.  A power cycle restores 128 and 0.678 V.")
    m.close()


def cmd_selftest(a):
    off = a.offset
    check_range(off, 4096)
    src = bytes((i * 7 + 13) & 0xFF for i in range(4096))
    n = dma_write(off, src)
    if n != 4096:
        sys.exit(f"FAIL: wrote {n} of 4096 bytes")
    got = dma_read(off, 4096)
    if got == src:
        print(f"PASS  4 KB round trip through HBM at {off:#x}")
        print("      DMA engines, descriptor path, smartconnect and HBM all work.")
    else:
        bad = next(i for i in range(4096) if got[i] != src[i])
        sys.exit(f"FAIL  first mismatch at byte {bad}: wrote {src[bad]:#04x} "
                 f"read {got[bad]:#04x}\n"
                 "      Cross-check the SAME address over JTAG with\n"
                 "      hw/fk33/pcieep.sh --check.  If JTAG sees the right data\n"
                 "      the fault is in XDMA or the driver; if it sees the wrong\n"
                 "      data too, the fault is in HBM or the interconnect.")


def cmd_bench(a):
    size = a.size_mb << 20
    check_range(a.offset, size)
    buf = os.urandom(1 << 20) * (size >> 20)
    t0 = time.perf_counter()
    dma_write(a.offset, buf)
    tw = time.perf_counter() - t0
    t0 = time.perf_counter()
    got = dma_read(a.offset, size)
    tr = time.perf_counter() - t0
    ok = got == buf
    print(f"H2C  {size / tw / 1e9:6.2f} GB/s   ({size >> 20} MB in {tw:.3f} s)")
    print(f"C2H  {size / tr / 1e9:6.2f} GB/s   ({size >> 20} MB in {tr:.3f} s)")
    print(f"data {'MATCHES' if ok else 'DIFFERS -- the numbers above are meaningless'}")
    print()
    print("Gen3 x4 raw payload ceiling is 3.94 GB/s.  Expect 3.2-3.5 GB/s with a")
    print("256 byte MPS, ~3.0 GB/s at 128 byte.  Much below that, in order of")
    print("likelihood: MPS/MRRS negotiated small (lspci -vvv, DevCtl), the driver")
    print("in poll mode on a busy CPU, or chunks too small to amortise descriptors.")
    print()
    print(f"At {size / tw / 1e9:.2f} GB/s a 4.5 GB INT4 9B weight set loads in "
          f"{4.5e9 / (size / tw):.1f} s.")


def cmd_load(a):
    sz = os.path.getsize(a.file)
    check_range(a.offset, sz)
    print(f"loading {a.file} ({sz / 1e9:.2f} GB) to HBM {a.offset:#x}")
    h = hashlib.blake2b(digest_size=16)
    t0 = time.perf_counter()
    fd = os.open(H2C, os.O_WRONLY)
    try:
        with open(a.file, "rb") as f:
            pos = 0
            while True:
                chunk = f.read(8 << 20)
                if not chunk:
                    break
                h.update(chunk)
                k = 0
                while k < len(chunk):
                    k += os.pwrite(fd, chunk[k:], a.offset + pos + k)
                pos += len(chunk)
    finally:
        os.close(fd)
    dt = time.perf_counter() - t0
    print(f"wrote {pos} bytes in {dt:.2f} s = {pos / dt / 1e9:.2f} GB/s")
    print(f"source blake2b-128 {h.hexdigest()}")
    if a.verify:
        _verify(a.offset, a.file, sz)


def cmd_verify(a):
    _verify(a.offset, a.file, os.path.getsize(a.file))


def _verify(off, path, sz):
    print("verifying by read-back")
    hs, hd = hashlib.blake2b(digest_size=16), hashlib.blake2b(digest_size=16)
    fd = os.open(C2H, os.O_RDONLY)
    try:
        with open(path, "rb") as f:
            pos = 0
            while pos < sz:
                want = f.read(8 << 20)
                got = os.pread(fd, len(want), off + pos)
                if len(got) != len(want):
                    sys.exit(f"FAIL short read at {off + pos:#x}")
                hs.update(want)
                hd.update(got)
                if got != want:
                    bad = next(i for i in range(len(want)) if got[i] != want[i])
                    sys.exit(f"FAIL first mismatch at HBM {off + pos + bad:#x}")
                pos += len(want)
    finally:
        os.close(fd)
    print(f"PASS  {sz} bytes identical")
    print(f"      source {hs.hexdigest()}  hbm {hd.hexdigest()}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sysmon").set_defaults(fn=cmd_sysmon)
    sub.add_parser("gpio").set_defaults(fn=cmd_gpio)
    sub.add_parser("vccint").set_defaults(fn=cmd_vccint)

    s = sub.add_parser("selftest")
    s.add_argument("--offset", type=lambda x: int(x, 0), default=0x1FFFFF000)
    s.set_defaults(fn=cmd_selftest)

    s = sub.add_parser("bench")
    s.add_argument("--size-mb", type=int, default=1024)
    s.add_argument("--offset", type=lambda x: int(x, 0), default=0)
    s.set_defaults(fn=cmd_bench)

    s = sub.add_parser("load")
    s.add_argument("file")
    s.add_argument("--offset", type=lambda x: int(x, 0), default=0)
    s.add_argument("--verify", action="store_true")
    s.set_defaults(fn=cmd_load)

    s = sub.add_parser("verify")
    s.add_argument("file")
    s.add_argument("--offset", type=lambda x: int(x, 0), default=0)
    s.set_defaults(fn=cmd_verify)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
