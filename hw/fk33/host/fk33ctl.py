#!/usr/bin/env python3
"""Host-side control of the FK33 over PCIe.  No dependencies beyond CPython.

Two paths into the card, both provided by the XDMA driver:

  /dev/xdma0_user     the AXI-Lite BAR.  MMIO, ~1 us per access, reaches
                      SYSMON at 0x3400 and the I2C bit-bang GPIO at 0x9000.
  /dev/xdma0_h2c_0    DMA into HBM.  The file offset IS the HBM byte address,
  /dev/xdma0_c2h_0    flat and contiguous from 0 to 0x1_FFFF_FFFF (8 GB).

Subcommands, in the order they should first be run.  Each does strictly more
than the last, so a failure localises itself:

  id         MMIO read of the read-only identity register.  The FIRST thing to
             run: 0x464B3333 ("FK33") cannot be produced by a driver that
             merely loaded, by an unanswered BAR (0xFFFFFFFF) or by a fabric
             held in reset (0x00000000).
  scratch    write and read back the 8 KB of BRAM on the AXI-Lite BAR.  The
             only thing here that proves MMIO WRITES land.
  sysmon     MMIO read only.  Proves BAR -> AXI-Lite -> peripheral.  No DMA.
  gpio       MMIO read of the I2C pins.  Confirms a live pull-up on the board
             bus.  Drives nothing.  (Use `scratch` to prove writes land -- it
             touches no board pins.)
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
import re
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
# Bring-up peripherals.  These must stay in step with hw/fk33/gen_pcieep.py and
# with host/fk33_bringup.c -- three places that agree is redundancy, three
# places that disagree is a day lost.
ID_MAGIC_OFF = 0xA000             # READ-ONLY, fabric constant
ID_BUILD_OFF = 0xA008             # READ-ONLY, fabric constant
ID_MAGIC = 0x464B3333             # "FK33" in ASCII
SCRATCH_BASE = 0x10000            # 8 KB of read/write BRAM
SCRATCH_SIZE = 0x2000

# Thermal protection.  Produced by rtl/fk33_thermal.vhd on the free-running aux
# clock and resynchronised into this clock domain by the module itself, so
# these reads are coherent rather than torn.  The same five words are readable
# over JTAG (tcl/aux_probe.tcl) with the PCIe link down.
THERM_STATUS = 0xB000
THERM_TEMPS  = 0xB008
THERM_PEAK   = 0xC000
THERM_TRIP   = 0xC008
THERM_CTL    = 0xD000             # write; [31:16] must be the key
THERM_CANARY = 0xD008
THERM_KEY    = 0xC1EA
# ---------------------------------------------------------------- the v2 seam
# rtl/fk33_seam.vhd's AXI-Lite slave, the host-card contract for whole-token
# inference.  The authority for these offsets is server/fk33_seam.h and they
# are repeated here rather than shared because that header is C and this file
# deliberately imports nothing; `seam` below CROSS-CHECKS itself against the
# header at run time, so a drift is reported rather than silently tolerated.
SEAM_BASE       = 0xE000
SEAM_ID         = SEAM_BASE + 0x00
SEAM_VERSION    = SEAM_BASE + 0x04
SEAM_CAPS_VOCAB = SEAM_BASE + 0x08
SEAM_CAPS_EMBD  = SEAM_BASE + 0x0C      # [15:0] n_embd  [31:16] n_layer
SEAM_CAPS_CTX   = SEAM_BASE + 0x10
SEAM_STATUS     = SEAM_BASE + 0x18
SEAM_ERR_INFO   = SEAM_BASE + 0x1C
SEAM_SEQ_POS    = SEAM_BASE + 0x20
SEAM_CYCLES     = SEAM_BASE + 0x40
SEAM_ARGMAX     = SEAM_BASE + 0x44
SEAM_LOGIT_EXP  = SEAM_BASE + 0x48
SEAM_CAPS_FLAGS = SEAM_BASE + 0x4C
SEAM_TBL_LEN    = SEAM_BASE + 0x50
SEAM_SMP_N      = SEAM_BASE + 0x64
SEAM_FAULTS     = SEAM_BASE + 0x68
SEAM_STEPS_ISS  = SEAM_BASE + 0x7C      # R  obs_issue count since GO (2026-09-18)
SEAM_ISSUE_CYC  = SEAM_BASE + 0x80      # R  CYCLES at the last issue
SEAM_BCB_LO     = SEAM_BASE + 0x84      # RW bst_const_base[31:0], B's learned constants (2026-09-18)
SEAM_BCB_HI     = SEAM_BASE + 0x88      # RW bst_const_base[32]
SEAM_TOK_POS    = SEAM_BASE + 0x8C      # R  llama_top's own tok_pos (2026-09-19)
SEAM_ID_MAGIC   = 0x4C4C4D32            # "LLM2"
SEAM_CAP = ((1 << 0, "WINDOWS   the DESC/REL/XIN/XOUT window port"),
            (1 << 1, "HBM_FETCH the card fetches its own D program"),
            (1 << 2, "SAMPLER   the card computes a running argmax"),
            (1 << 3, "LOGITS    the card writes the full logits row"))
SEAM_FAULT = ((1 << 0, "SMP_OVF    the logits FIFO lost beats"),
              (1 << 1, "LOST_BEAT  an unstallable producer beat was dropped"),
              (1 << 2, "GATE_DROP  the region lock refused a write"),
              (1 << 3, "UNIT_STUB  a STUB unit produced a result"),
              (1 << 4, "E_COLL     OP_E_COLL issued at NCARDS=1"),
              (1 << 5, "KV         attn_kv_axi's sticky error"))
SEAM_ERR = {0: "NONE", 1: "POS", 2: "NSTEP", 3: "ALIGN", 4: "STACK",
            5: "RSVD", 6: "DESC", 7: "HALT", 8: "SEQ"}

# Subsystem D's OWN codes, carried in ERR_INFO[3:0] whenever the seam's code
# is 6 (DESC).  rtl/seq_desc_fetch.vhd:263-271.  The seam wraps EVERY D error
# as DESC (rtl/fk33_seam.vhd:148-152), so "DESC" alone says only "D reported
# something"; the decode below is what says what.  MEASURED 2026-09-18: the
# first GO on the composed card returned DESC with ERR_INFO 0x00070074 =
# ERR_WDOG at step 7 after 7 steps, and the raw hex was read as a refused
# program for the first minute.
D_ERR = {0: "NONE", 1: "UNIT", 2: "LOCK", 3: "DESC", 4: "WDOG", 5: "GRANT",
         6: "CTX", 7: "EPOCH", 8: "ABORT"}


def decode_err_info(info):
    """ERR_INFO per rtl/fk33_seam.vhd:921-929: D code [3:0], failing step
    [14:4], descriptors completed [26:16] (STEP_W = 11)."""
    dcode = info & 0xF
    dstep = (info >> 4) & 0x7FF
    ddone = (info >> 16) & 0x7FF
    return dcode, dstep, ddone

THERM_CAUSE = {
    0: "none",
    1: "SYSMON over-temperature alarm (the armed 101 C backstop)",
    2: "SYSMON user temperature alarm",
    3: "die above the halt threshold",
    4: "die sensor STALE or implausible -- treated as hot",
    5: "an HBM stack asserted CATTRIP",
    6: "HBM above the halt threshold",
    7: "HBM sensor STALE or implausible -- treated as hot",
}
DMABRAM_BASE = 0x2_0000_0000      # 64 KB BRAM on the DMA master, above HBM
DMABRAM_SIZE = 0x10000
POT_ADDR = 0x2C                   # MCP45XX-class digital pot, VCCINT

# Do not widen these without re-reading the reasoning in tcl/vccint_step.tcl;
# the safety argument is in the code, not in a comment.
V_TARGET, V_LO, V_HI = 0.720, 0.716, 0.728
V_CEILING = 0.760

# W_FLOOR RAISED 60 -> 68 on 2026-08-28.  68 is the sanctioned maximum for this
# card: lower wiper means HIGHER voltage, and wiper 68 is ~0.717 V.  Measured
# reference points: wiper 128 = 0.6786 V, wiper 64 = 0.7203 V, so a step is
# about 0.00065 V and 68 lands just inside the 0.716..0.728 acceptance band.
#
# The standing instruction is explicit: VCCINT must NEVER be taken to 0.850 V,
# which is what the vendor's own script does.  A floor of 60 left ~5 further
# steps of headroom below the sanctioned point for no benefit.  This is the
# enforcement, not the comment: the loop below cannot write a wiper under
# W_FLOOR by any path.
#
# NOTE tcl/vccint_step.tcl still carries W_FLOOR 60.  It is owned by another
# agent in this session and was deliberately not edited here.  Raise it there
# too; until then the JTAG path is the looser of the two.
W_FLOOR, W_DEFAULT = 68, 128
W_ABSOLUTE_FLOOR = 68             # never raise W_FLOOR above this line's value
DV_MAX, W_STEP_MAX = 0.035, 4

assert W_FLOOR >= W_ABSOLUTE_FLOOR, (
    "W_FLOOR must never go below 68 (~0.717 V).  Lower wiper = higher VCCINT, "
    "and the standing hardware instruction forbids raising VCCINT to 0.85 V.")


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


def describe_dead_word(v):
    """Say what a register word MEANS when it is not the expected value.

    The distinction this makes is the point.  A read that never happened must
    never be reported as a read that returned the wrong data.  Over JTAG-AXI
    the failure surfaces as -1; over MMIO it surfaces as 0xFFFFFFFF from an
    unanswered BAR or 0x00000000 from a fabric in reset.  All three are
    "the path is not working", not "the bitstream is wrong", and conflating
    them is what sent the 2026-08-28 bring-up down a wrong path.
    """
    if v in (-1, 0xFFFFFFFF):
        return ("NOT A VALUE -- this is a FAILED transaction.\n"
                "all-ones (or -1 over JTAG-AXI) means the access was issued "
                "and nothing\nanswered: link down, BAR unmapped, or the AXI "
                "fabric unclocked.  It is NOT\n'the wrong data came back', so "
                "do not read it as a bitstream mismatch.")
    if v == 0:
        return ("NOT A VALUE -- all-zeroes.\n"
                "The BAR exists and decodes, but the fabric behind it is "
                "unclocked or held\nin reset.  Again a path fault, not a "
                "content mismatch.")
    return ("something answers with real data, but it is not this bitstream. "
            "THIS one\nis a genuine value mismatch, unlike the all-ones and "
            "all-zeroes cases above.")


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
        # THE hard clamp, deliberately at the lowest level rather than in the
        # stepping loop, so that no future caller can route around it.  A lower
        # wiper is a HIGHER rail; W_FLOOR is the sanctioned maximum voltage.
        if wiper < W_FLOOR:
            raise ValueError(
                f"refusing to write wiper {wiper}: below the floor {W_FLOOR}. "
                f"Lower wiper means higher VCCINT, and {W_FLOOR} is the "
                f"sanctioned maximum (~0.717 V).  VCCINT must never be taken "
                f"to 0.85 V.")
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


def cmd_thermal(a):
    """Read the thermal guard.

    Reads the SAME words tcl/aux_probe.tcl reads over JTAG, so agreement
    between the two proves the PCIe MMIO path against a path that does not
    depend on the link.
    """
    m = Mmio()
    st = m.rd(THERM_STATUS)
    tp = m.rd(THERM_TEMPS)
    pk = m.rd(THERM_PEAK)
    tr = m.rd(THERM_TRIP)
    cn = m.rd(THERM_CANARY)

    if st in (0, 0xFFFFFFFF):
        print(f"THERM_STATUS = {st:#010x} -- that is a dead bus, not a reading.")
        m.close()
        return
    if not st & (1 << 31):
        print(f"THERM_STATUS = {st:#010x}")
        print("  BIT 31 IS CLEAR.  This bitstream has NO thermal guard.  The only")
        print("  protection is SYSMON's armed over-temperature shutdown at 101 C,")
        print("  which is above the -2LE sustained rating of 100 C, says nothing")
        print("  about the HBM stacks, and takes the card off the PCIe bus when it")
        print("  fires.  Do not run a sustained workload on this bitstream.")
        m.close()
        return

    def die_c(code):
        # the exact external-reference transfer function, on the 10-bit bus
        return code * 507.5921310 / 1024.0 - 279.42657680

    print(f"halted        {'YES' if st & 1 else 'no'}"
          f"        warn {'YES' if st & 2 else 'no'}"
          f"        armed {'yes' if st & 4 else 'NO'}")
    print(f"die   {die_c(tp & 0x3FF):6.1f} C   valid={'yes' if st & 8 else 'NO'}"
          f"   peak {die_c(pk & 0x3FF):6.1f} C")
    print(f"HBM   code {(tp >> 10) & 0x7F:3d} / {(tp >> 17) & 0x7F:3d}"
          f"   valid={'yes' if st & 16 else 'NO'}"
          f"   peak {(pk >> 10) & 0x7F:3d} / {(pk >> 17) & 0x7F:3d}")
    print("      (HBM is a RAW stack code.  Its mapping to Celsius is NOT")
    print("       calibrated on this card; idle codes have measured 25-29 at a")
    print("       die temperature of 22-28 C.)")
    print(f"live cause    {THERM_CAUSE.get((st >> 8) & 0xF, '?')}")
    if st & (1 << 7):
        print(f"LATCHED TRIP  {THERM_CAUSE.get((st >> 12) & 0xF, '?')}")
        print(f"              at die {die_c(tr & 0x3FF):.1f} C, HBM code "
              f"{(tr >> 10) & 0x7F} / {(tr >> 17) & 0x7F}")
        _tc = (st >> 16) & 0xFF
        # The field is 8 bits and SATURATES (rtl/fk33_thermal.vhd:1166), so at
        # 255 this is a floor and not a count.  Printing the bare number read
        # as "255 trips"; the true figure is unbounded above.
        print(f"              trips since the last clear: {_tc}"
              + (" OR MORE (the 8-bit counter is SATURATED; clear it with "
                 "--clear\n              to make the next reading a count)"
                 if _tc == 255 else ""))
    else:
        print("LATCHED TRIP  none since the last clear")
    for bit, what in ((25, "SYSMON OT alarm has fired"),
                      (27, "SYSMON user temperature alarm has fired"),
                      (28, "HBM stack 0 asserted CATTRIP"),
                      (29, "HBM stack 1 asserted CATTRIP"),
                      (30, "the two HBM stacks disagreed for longer than the "
                           "dwell.  DIAGNOSTIC ONLY -- it does not halt.  "
                           "hbm_temp0/1 are two SEPARATE DIES, so this is a "
                           "stuck or torn stack sensor, or two stacks that "
                           "have genuinely separated under load.  It is NOT "
                           "a CDC fault")):
        if st & (1 << bit):
            print(f"  STICKY: {what}")
    print(f"canary        {cn}  (advances only while the compute domain is")
    print("               running AND the guard has released it; read twice)")

    if a.clear or a.clear_peak:
        bits = (1 if a.clear else 0) | (2 if a.clear_peak else 0)
        # Edge triggered: assert, then deassert.  Leaving the word set would do
        # nothing further, but a stale key in the register is a foot-gun.
        m.wr(THERM_CTL, (THERM_KEY << 16) | bits)
        time.sleep(0.01)
        m.wr(THERM_CTL, 0)
        st2 = m.rd(THERM_STATUS)
        print(f"\ncleared; THERM_STATUS now {st2:#010x}")
        if st2 & 1:
            print("  still HALTED -- a clear does not release the halt.  The halt")
            print("  is recomputed from the live sensors every cycle, so the card")
            print("  is still hot or a sensor is still stale.")
    m.close()


def cmd_id(a):
    """The single read that distinguishes a working path from a loaded driver.

    0xFFFFFFFF is what a mapped-but-unanswered BAR returns and 0x00000000 is
    what a fabric held in reset returns, so neither can be mistaken for a pass.
    """
    m = Mmio()
    magic, build = m.rd(ID_MAGIC_OFF), m.rd(ID_BUILD_OFF)
    print(f"id magic   0x{magic:08x}   expected 0x{ID_MAGIC:08x} (\"FK33\")")
    print(f"id build   0x{build:08x}   yyyymmdd, BCD")
    if magic == ID_MAGIC:
        print("  OK -- link, config space, BAR placement, AXI-Lite clock and "
              "reset,\n  smartconnect decode and bitstream identity are ALL "
              "proven by this one read.")
    else:
        print("  " + describe_dead_word(magic).replace("\n", "\n  "))
    m.close()
    return 0 if magic == ID_MAGIC else 1


def seam_header_offsets(path=None):
    """The offsets server/fk33_seam.h declares, so `seam` can prove it agrees
    with the C half rather than assuming it.  Two copies of a register map that
    nothing compares are two copies that will drift; this is the comparison.
    Returns {} when the header is not reachable, which is not a failure -- this
    tool must work from a directory that has no repository around it."""
    if path is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "..", "..", "server", "fk33_seam.h")
    try:
        txt = open(path).read()
    except OSError:
        return {}
    out = {}
    for m in re.finditer(r"^#define\s+(FK33_SEAM_[A-Z0-9_]+)\s+"
                         r"(0x[0-9A-Fa-f]+)u?\s", txt, re.M):
        out[m.group(1)] = int(m.group(2), 16)
    return out


def cmd_seam(a):
    """Read the v2 seam and say whether the card can be driven at all.

    This is the FIRST thing to run on a freshly loaded card build.  Like
    `id`, the single ID read settles a great deal at once -- but unlike `id` it
    settles it about the SEAM: that rtl/fk33_seam.vhd is present in this
    bitstream, that it is decoded at 0xE000, and that its AXI-Lite clock and
    reset are alive.  0xFFFFFFFF and 0x00000000 are both dead-bus words and
    neither can be mistaken for a pass.

    It writes NOTHING.  Every register read here is R or RW-read, so this is
    safe to run against a card mid-job; the counters it prints are simply the
    last job's.
    """
    m = Mmio()
    bad = 0
    ident = m.rd(SEAM_ID)
    print(f"seam id    0x{ident:08x}   expected 0x{SEAM_ID_MAGIC:08x} "
          f"(\"LLM2\") at BAR+0x{SEAM_BASE:04X}")
    if ident != SEAM_ID_MAGIC:
        print("  " + describe_dead_word(ident).replace("\n", "\n  "))
        if ident not in (0, 0xFFFFFFFF):
            print("  A real answer that is not the magic means the seam is NOT "
                  "in this\n  bitstream, or is decoded somewhere else.  An "
                  "engine-only build reads\n  as a dead word here, which is "
                  "correct: it has no seam.")
        m.close()
        return 1

    ver   = m.rd(SEAM_VERSION)
    vocab = m.rd(SEAM_CAPS_VOCAB)
    embd  = m.rd(SEAM_CAPS_EMBD)
    ctx   = m.rd(SEAM_CAPS_CTX)
    flags = m.rd(SEAM_CAPS_FLAGS)
    print(f"version    {ver}")
    print(f"caps       n_vocab {vocab}  n_embd {embd & 0xFFFF}  "
          f"n_layer {(embd >> 16) & 0xFFFF}  ctx {ctx} tokens")
    # rtl/model_cfg_pkg.vhd's QWEN35_9B.  A mismatch here is not cosmetic: the
    # host derives x_stride and l_stride from these and would address the
    # wrong rows.  The audit flags n_vocab as UNVERIFIED, so it is COMPARED
    # and reported rather than asserted.
    want = (("n_vocab", vocab, 248320), ("n_embd", embd & 0xFFFF, 4096),
            ("n_layer", (embd >> 16) & 0xFFFF, 32))
    for nm, got, exp in want:
        if got != exp:
            print(f"  MISMATCH {nm} reads {got}, rtl/model_cfg_pkg.vhd's "
                  f"QWEN35_9B says {exp}")
            bad += 1
    if ctx == 0:
        print("  MISMATCH ctx is 0: the card claims no KV capacity at all")
        bad += 1

    print(f"cap flags  0x{flags:08x}")
    for bit, what in SEAM_CAP:
        print(f"  {'yes' if flags & bit else ' no'}  {what}")
    if not flags:
        print("  NO capabilities at all.  A seam that answers its ID and "
              "claims nothing is\n  a tie-off, not an engine.")
        bad += 1

    st = m.rd(SEAM_STATUS)
    ec = (st >> 8) & 0xF
    print(f"status     0x{st:08x}  done={st & 1} busy={(st >> 1) & 1} "
          f"err={(st >> 2) & 1} err_code={ec} ({SEAM_ERR.get(ec, '?')})")
    if st & (1 << 2):
        info = m.rd(SEAM_ERR_INFO)
        print(f"  ERR is STICKY from a previous job.  ERR_INFO=0x{info:08x}")
        if ec == 6:
            dcode, dstep, ddone = decode_err_info(info)
            print(f"  D's own code {dcode} ({D_ERR.get(dcode, '?')}) at step "
                  f"{dstep}, {ddone} descriptor(s) completed before it."
                  f"{'  WDOG: the unit did not finish within WDOG_LIMIT cycles; the GO was ACCEPTED.' if dcode == 4 else ''}")
    if st & (1 << 1):
        print("  BUSY: a job is in flight right now, so the counters below "
              "are mid-job.")

    faults = m.rd(SEAM_FAULTS)
    print(f"faults     0x{faults:08x}" + ("  (none)" if not faults else ""))
    for bit, what in SEAM_FAULT:
        if faults & bit:
            print(f"  SET  {what}")
            bad += 1

    # THE ENGINE'S position beside the seam's.  They are different counters:
    # the seam's is cleared by SEQ_RESET, the engine's (B's tk0, C's position)
    # only by SEQ_RESET on a card with caps bit 4, else by reconfiguration
    # (docs/debugging/2026-09-19_b-ran-every-probe-token-as-not-the-first.md).
    # On a card without bit 4 this register does not exist and reads 0.
    caps = m.rd(SEAM_CAPS_FLAGS)
    tp = m.rd(SEAM_TOK_POS)
    if caps & (1 << 4):
        print(f"engine     tok_pos {tp}" + ("" if tp == 0 else
              "  (NOT 0: the next token is not a first token; B runs at tk0=0)"))
    else:
        print("engine     tok_pos UNREADABLE (caps bit 4 clear): only a "
              "reconfiguration clears it on this bitstream")
    print(f"last job   seq_pos {m.rd(SEAM_SEQ_POS)}  cycles "
          f"{m.rd(SEAM_CYCLES)}  argmax {m.rd(SEAM_ARGMAX)}  "
          f"logit_exp {m.rd(SEAM_LOGIT_EXP)}")
    print(f"           tbl_len {m.rd(SEAM_TBL_LEN)}  smp_n {m.rd(SEAM_SMP_N)}")
    # Live progress (a bitstream before 2026-09-18 19:00 reads both as 0).
    si, ic, cy = m.rd(SEAM_STEPS_ISS), m.rd(SEAM_ISSUE_CYC), m.rd(SEAM_CYCLES)
    print(f"progress   steps issued {si}  last issue at cycle {ic}  "
          f"(the current or last step has run {cy - ic if cy >= ic else 0} "
          f"cycles)")
    # B's learned-constants base (docs/2026-09-18_b-constants-path.md).  Read
    # only; a bitstream before 2026-09-18 22:00 has no register here and reads
    # a dead word.  Zero after a model load means the host never wrote it,
    # and a card built with B_CONST_HBM then loads its constants from HBM
    # address 0, the weight image, with no fault raised: the seam does NOT
    # refuse a GO on it, so this line is the only place it shows.
    bcb = ((m.rd(SEAM_BCB_HI) & 1) << 32) | m.rd(SEAM_BCB_LO)
    print(f"bases      bst_const_base 0x{bcb:09x}"
          + ("  (ZERO: never written by the host)" if bcb == 0 else ""))

    # Two copies of a register map, compared.  See seam_header_offsets.
    hdr = seam_header_offsets()
    if not hdr:
        print("drift      server/fk33_seam.h not reachable from here; the "
              "offsets above were\n           NOT cross-checked")
    else:
        mine = {"FK33_SEAM_ID": SEAM_ID, "FK33_SEAM_VERSION": SEAM_VERSION,
                "FK33_SEAM_CAPS_VOCAB": SEAM_CAPS_VOCAB,
                "FK33_SEAM_CAPS_EMBD": SEAM_CAPS_EMBD,
                "FK33_SEAM_CAPS_CTX": SEAM_CAPS_CTX,
                "FK33_SEAM_STATUS": SEAM_STATUS,
                "FK33_SEAM_ERR_INFO": SEAM_ERR_INFO,
                "FK33_SEAM_SEQ_POS": SEAM_SEQ_POS,
                "FK33_SEAM_CYCLES": SEAM_CYCLES,
                "FK33_SEAM_ARGMAX": SEAM_ARGMAX,
                "FK33_SEAM_LOGIT_EXP": SEAM_LOGIT_EXP,
                "FK33_SEAM_CAPS_FLAGS": SEAM_CAPS_FLAGS,
                "FK33_SEAM_TBL_LEN": SEAM_TBL_LEN,
                "FK33_SEAM_SMP_N": SEAM_SMP_N,
                "FK33_SEAM_FAULTS": SEAM_FAULTS,
                "FK33_SEAM_STEPS_ISS": SEAM_STEPS_ISS,
                "FK33_SEAM_ISSUE_CYC": SEAM_ISSUE_CYC,
                "FK33_SEAM_BCB_LO": SEAM_BCB_LO,
                "FK33_SEAM_BCB_HI": SEAM_BCB_HI,
                "FK33_SEAM_TOK_POS": SEAM_TOK_POS}
        drift = [(k, v - SEAM_BASE, hdr[k]) for k, v in sorted(mine.items())
                 if k in hdr and v - SEAM_BASE != hdr[k]]
        miss = [k for k in mine if k not in hdr]
        if drift or miss:
            for k, got, exp in drift:
                print(f"  DRIFT {k}: this file 0x{got:02X}, "
                      f"server/fk33_seam.h 0x{exp:02X}")
            for k in miss:
                print(f"  DRIFT {k} is not in server/fk33_seam.h at all")
            bad += 1
        else:
            print(f"drift      {len(mine)} offsets agree with "
                  f"server/fk33_seam.h")

    m.close()
    if bad:
        print(f"\nSEAM {bad} problem(s) above.  The ID read PASSED, so the "
              "path is good and\nthe card is answering; what is wrong is what "
              "it answers.")
        return 1
    print("\nSEAM OK -- the seam is present, decoded, claims a usable shape, "
          "and reports\nno sticky fault.  That is the whole of what a "
          "read-only check can settle: it\nsays NOTHING about whether a job "
          "computes correctly.")
    return 0


def cmd_scratch(a):
    """Prove MMIO WRITES land.  SYSMON and the id register are both read-only."""
    m = Mmio()
    bad = 0
    for b in range(32):
        v = 1 << b
        m.wr(SCRATCH_BASE, v)
        rb = m.rd(SCRATCH_BASE)
        if rb != v:
            print(f"  walking-one bit {b}: wrote 0x{v:08x} read 0x{rb:08x}")
            bad += 1
    words = SCRATCH_SIZE // 4
    for i in range(words):
        m.wr(SCRATCH_BASE + 4 * i, 0xA5A50000 | i)
    for i in range(words):
        rb = m.rd(SCRATCH_BASE + 4 * i)
        if rb != (0xA5A50000 | i):
            print(f"  address-in-word {i}: read 0x{rb:08x}")
            bad += 1
            if bad > 8:
                break
    m.wr(SCRATCH_BASE, ID_MAGIC)
    m.close()
    print(f"scratch {SCRATCH_SIZE >> 10} KB at 0x{SCRATCH_BASE:05x}: "
          f"{'OK' if not bad else str(bad) + ' FAILURES'}")
    return 1 if bad else 0


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
    # pot_read returns -1 for a NACK.  That is a FAILED read, not a wiper
    # value, and printing it in the wiper field invites exactly the confusion
    # this session was sent to remove.  Report it as its own condition first.
    if w < 0:
        print(f"START   wiper=READ FAILED (I2C NACK)  VCCINT={v:.4f} V  "
              f"die={die_temp(m):.1f} C")
        sys.exit("ABORT: the pot did not acknowledge.  The -1 is a failed I2C "
                 "read, not a wiper value; do not compare it against 128.  "
                 "Nothing was written.")
    print(f"START   wiper={w}  VCCINT={v:.4f} V  die={die_temp(m):.1f} C")
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
            # STOP at the floor rather than reverting to 128.  Reverting puts
            # the rail back to 0.678 V, BELOW the 0.698 V -2L floor, which is
            # strictly worse than stopping at the sanctioned maximum of
            # W_FLOOR (~0.717 V, already in spec).  The revert path exists for
            # signs of a misunderstanding of the hardware; running out of
            # sanctioned travel is not that.
            print(f"STOPPED at the wiper floor {W_FLOOR}: the next step would "
                  f"be {nw}.\n"
                  f"  wiper {w}, VCCINT {v:.4f} V.  Left here deliberately:"
                  f" {W_FLOOR} is the sanctioned\n"
                  f"  maximum and this rail is above the 0.698 V -2L floor,"
                  f" whereas reverting to\n"
                  f"  {W_DEFAULT} would put it back to ~0.678 V and out of spec.")
            sys.exit(1)
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


def manifest_place(a):
    """`--manifest M`: take the OFFSET and the expected DIGEST of `file` from
    the manifest instead of the command line.  Added 2026-09-18 for the GDN
    constant image (docs/2026-09-18_b-constants-path.md): `load` and
    `verify` here pair a file with an offset the OPERATOR typed, which is the
    recorded way a wrong pairing reproduces itself in the verify.  With the
    manifest named, the pairing is the packer's, and a `--offset` that
    disagrees is a refusal.

    The only object the `hbm` block places by name today is the constant
    image (`hbm.gdn_const_file` at `hbm.gdn_const_base`, digest
    `hbm.gdn_const_blake2b_128`); the packed tensors are `files` entries and
    belong to `fk33_load_weights.py`, which walks all 250 of them.  Returns
    (offset, digest or None)."""
    if not getattr(a, "manifest", None):
        return a.offset, None
    import json
    with open(a.manifest) as f:
        mani = json.load(f)
    hbm = mani.get("hbm") or {}
    root = os.path.dirname(os.path.abspath(a.manifest))
    want = os.path.abspath(a.file)
    if hbm.get("gdn_const_file") and \
            os.path.abspath(os.path.join(root, hbm["gdn_const_file"])) == want:
        off = int(hbm["gdn_const_base"])
        dig = hbm.get("gdn_const_blake2b_128")
        sz = os.path.getsize(a.file)
        if sz != int(hbm["gdn_const_bytes"]):
            sys.exit(f"FAIL {a.file} is {sz} B on disk, the manifest declares "
                     f"hbm.gdn_const_bytes {hbm['gdn_const_bytes']}")
    else:
        sys.exit(f"FAIL {a.manifest} does not place {a.file}: the only object "
                 f"its hbm block names is "
                 f"{hbm.get('gdn_const_file', '(no gdn_const_file)')}.  The "
                 f"packed tensors are loaded by fk33_load_weights.py, which "
                 f"reads their offsets from the manifest's files list.")
    if a.offset and a.offset != off:
        sys.exit(f"FAIL --offset {a.offset:#x} disagrees with the manifest's "
                 f"{off:#x} for {a.file}; the manifest is the authority, drop "
                 f"the --offset")
    print(f"offset {off:#x} and digest {dig} taken from {a.manifest}")
    return off, dig


def cmd_load(a):
    sz = os.path.getsize(a.file)
    a.offset, want_dig = manifest_place(a)
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
    if want_dig and h.hexdigest() != want_dig:
        # The bytes are already on the card; say so rather than verify them
        # against the same wrong file and print PASS.
        sys.exit(f"FAIL the file just written hashes to {h.hexdigest()}, the "
                 f"manifest's pack-time digest is {want_dig}: the file on "
                 f"disk is not the image that was packed, and it is now in "
                 f"HBM at {a.offset:#x}")
    if a.verify:
        _verify(a.offset, a.file, sz, want_dig)


def cmd_verify(a):
    a.offset, want_dig = manifest_place(a)
    _verify(a.offset, a.file, os.path.getsize(a.file), want_dig)


def _verify(off, path, sz, want_dig=None):
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
    if want_dig and hd.hexdigest() != want_dig:
        sys.exit(f"FAIL HBM hashes to {hd.hexdigest()}, the manifest's "
                 f"pack-time digest is {want_dig}: the card holds the file "
                 f"it was handed, and that file is not the packed image")
    print(f"PASS  {sz} bytes identical"
          + (" and the manifest's pack-time digest" if want_dig else ""))
    print(f"      source {hs.hexdigest()}  hbm {hd.hexdigest()}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("id").set_defaults(fn=cmd_id)
    sub.add_parser("seam", help="read the v2 inference seam at BAR+0xE000; "
                                "writes nothing").set_defaults(fn=cmd_seam)
    sub.add_parser("scratch").set_defaults(fn=cmd_scratch)
    sub.add_parser("sysmon").set_defaults(fn=cmd_sysmon)
    sub.add_parser("gpio").set_defaults(fn=cmd_gpio)
    sub.add_parser("vccint").set_defaults(fn=cmd_vccint)

    s = sub.add_parser("thermal", help="read the thermal guard, optionally clear it")
    s.add_argument("--clear", action="store_true",
                   help="clear the trip latch, the cause and the trip count. "
                        "Does NOT clear the peak-hold and does NOT release a "
                        "halt that the live sensors still justify.")
    s.add_argument("--clear-peak", action="store_true",
                   help="clear the peak-hold. It re-acquires the live reading "
                        "on the next cycle, so it does not go to zero.")
    s.set_defaults(fn=cmd_thermal)

    s = sub.add_parser("selftest")
    # Default to the on-chip DMA BRAM, not HBM.  It is the same descriptor
    # path, the same M_AXI and the same smartconnect, but it takes HBM out of
    # the loop -- so a failure here and a failure to HBM point at different
    # subsystems.  --offset 0x1FFFFF000 for the old HBM-top behaviour.
    s.add_argument("--offset", type=lambda x: int(x, 0), default=DMABRAM_BASE)
    s.set_defaults(fn=cmd_selftest)

    s = sub.add_parser("bench")
    s.add_argument("--size-mb", type=int, default=1024)
    s.add_argument("--offset", type=lambda x: int(x, 0), default=0)
    s.set_defaults(fn=cmd_bench)

    s = sub.add_parser("load")
    s.add_argument("file")
    s.add_argument("--offset", type=lambda x: int(x, 0), default=0)
    s.add_argument("--manifest", default=None,
                   help="take the offset and the pack-time digest of FILE "
                        "from this manifest.json (today: the GDN constant "
                        "image, hbm.gdn_const_file at hbm.gdn_const_base). "
                        "A --offset that disagrees is refused")
    s.add_argument("--verify", action="store_true")
    s.set_defaults(fn=cmd_load)

    s = sub.add_parser("verify")
    s.add_argument("file")
    s.add_argument("--offset", type=lambda x: int(x, 0), default=0)
    s.add_argument("--manifest", default=None, help="as for load")
    s.set_defaults(fn=cmd_verify)

    a = p.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
