#!/usr/bin/env python3
"""Read a Jungle Cat die's seam and A's utilisation counters through the broker.

    jc_seam.py status    --sock SOCK
    jc_seam.py seam      --sock SOCK --die A|B [--manifest M]
    jc_seam.py util      --sock SOCK --die A|B
    jc_seam.py util-clear --sock SOCK --die A|B

A client of tools/jc/jc_broker.py's Unix socket (one JSON object per line each way). The
broker serves ONE client at a time, so run this only while no run_prompt holds the socket.

  status      the broker's own view ({"op":"status"}); never touches the board. Prints
              `JCSEAM_STATUS ok {...}`, or `JCSEAM_STATUS halted ...` when it has halted.
  seam        hw/fk33/host/fk33ctl.py's `seam` report, unchanged, with its register reads
              sent as broker rd32 ops and its image-record read as a broker memrd (the
              broker allows the record even when it fences the image). Writes nothing.
              Lines to gate on are fk33ctl's: `seam id`, `caps`, `cap flags`, `status`,
              `image`. NOTE: fk33ctl compares CAPS against the 9B shape, so a 27B die
              prints `MISMATCH n_embd`/`n_layer` lines and a `SEAM n problem(s)` tail;
              those are expected for the 27B and are not the error bit.
  util        A's per-port read-beat counters and the A-job cycle counter
              (rtl/a_util_ctr.vhd), at the engine's AXI-Lite map 0x12000
              (hw/fk33/host/fk33_regs.h: UTIL_SEL 0x40, UTIL_DATA 0x44; CAPS 0x1C gives
              NPORTS_W and NPORTS_S; counter NPORTS_W+NPORTS_S is the job cycles). Writes
              UTIL_SEL only (a selector, it moves no data). On the JC card hbm_aclk and
              clk_core are one net (hw/jc/card/gen_jc_card.py), so job cycles are clk_core
              cycles and beats/jobcyc is the port's fraction of one 32-byte beat a cycle.
              A split-on card (JC_A_TILED=1 JC_A_CLK_SPLIT=1, a450 Task 9b) does not build
              the counters: UTIL_SEL bit 31 (UTIL_NONE) reads 1, and this prints
              `JCUTIL_NONE die X seam_cycles_last_go N` and `JCUTIL_DONE` and exits 0,
              reading no counter.  The cadence of such a card is measured from the seam's
              cycles only (port_beats is not available on it).
  util-clear  writes UTIL_CLR (0x48): zeroes every counter. Counters ACCUMULATE across
              jobs until this or reset (rtl/matvec_int4_desc_axi.vhd, register map).

Drives the board through the broker: the main session or Oren runs it, never a subagent.
"""
import argparse, json, os, socket, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FK33_HOST = os.path.join(HERE, "..", "..", "fk33", "host")

ENG_CTL_BASE = 0x12000        # hw/fk33/host/fk33_regs.h FK33_ENG_CTL_BASE
ENG_ID = ENG_CTL_BASE + 0x14
ENG_CAPS = ENG_CTL_BASE + 0x1C
ENG_UTIL_SEL = ENG_CTL_BASE + 0x40
ENG_UTIL_DATA = ENG_CTL_BASE + 0x44
ENG_UTIL_CLR = ENG_CTL_BASE + 0x48
UTIL_NONE = 1 << 31           # UTIL_SEL bit 31: counters not built (rtl/matvec_int4_desc_axi.vhd)
ENG_ID_MAGIC = 0x4D563449     # "MV4I"
UTIL_DEAD = 0xDEADDEAD
SEAM_CYCLES = 0xE000 + 0x40   # server/fk33_seam.h FK33_SEAM_CYCLES (GO to done, core cycles)
IMGLOCK_BYTES = 512


class BrokerError(Exception):
    pass


class Broker:
    def __init__(s, path, timeout=120.0):
        s.sock = socket.socket(socket.AF_UNIX)
        s.sock.settimeout(timeout)
        s.sock.connect(path)
        s.buf = b""

    def req(s, obj):
        s.sock.sendall((json.dumps(obj) + "\n").encode())
        while b"\n" not in s.buf:
            chunk = s.sock.recv(1 << 16)
            if not chunk:
                raise BrokerError("the broker closed the connection")
            s.buf += chunk
        line, s.buf = s.buf.split(b"\n", 1)
        rsp = json.loads(line)
        if not rsp.get("ok"):
            raise BrokerError(rsp.get("err", "no error text"))
        return rsp

    def rd32(s, die, off):
        return int(s.req({"die": die, "op": "rd32", "off": off})["val"])

    def wr32(s, die, off, val):
        s.req({"die": die, "op": "wr32", "off": off, "val": val & 0xFFFFFFFF})

    def memrd(s, die, addr, n):
        return bytes.fromhex(s.req({"die": die, "op": "memrd", "addr": addr, "n": n})["hex"])

    def close(s):
        s.sock.close()


def cmd_status(a):
    b = Broker(a.sock)
    try:
        st = b.req({"op": "status"})
    finally:
        b.close()
    if st.get("halted"):
        print("JCSEAM_STATUS halted %s" % json.dumps(st, sort_keys=True))
        return 1
    print("JCSEAM_STATUS ok %s" % json.dumps(st, sort_keys=True))
    return 0


def cmd_seam(a):
    sys.path.insert(0, FK33_HOST)
    import fk33ctl
    import fk33_imgfp as IMGFP
    b = Broker(a.sock)

    class BrokerMmio:
        def __init__(self, *_):
            pass

        def rd(self, off):
            return b.rd32(a.die, off)

        def wr(self, off, val):            # cmd_seam writes nothing; refuse if it ever does
            raise BrokerError("jc_seam.py seam is read-only (write to %#x refused)" % off)

        def close(self):
            pass

    def read_record(mani, fd=None):
        addr = IMGFP.record_addr(mani)
        return IMGFP.unpack_record(b.memrd(a.die, addr, IMGFP.RECORD_BYTES))

    fk33ctl.Mmio = BrokerMmio
    IMGFP.read_record = read_record
    print("die        %s via broker %s" % (a.die, a.sock))
    try:
        rc = fk33ctl.cmd_seam(argparse.Namespace(manifest=a.manifest))
    finally:
        b.close()
    print("JCSEAM_DONE die %s rc %d" % (a.die, rc))
    return rc


def read_util(b, die):
    """[(index, 48-bit value)] for every counter, the job-cycle counter last."""
    caps = b.rd32(die, ENG_CAPS)
    npw, nps = caps & 0xFF, (caps >> 8) & 0xFF
    out = []
    for i in range(npw + nps + 1):
        b.wr32(die, ENG_UTIL_SEL, i << 1)
        lo = b.rd32(die, ENG_UTIL_DATA)
        b.wr32(die, ENG_UTIL_SEL, (i << 1) | 1)
        hi = b.rd32(die, ENG_UTIL_DATA)
        if UTIL_DEAD in (lo, hi):
            raise BrokerError("counter %d read 0xDEADDEAD: the counter domain did not answer" % i)
        out.append((i, ((hi & 0xFFFF) << 32) | lo))
    return npw, nps, out


def cmd_util(a):
    b = Broker(a.sock)
    try:
        ident = b.rd32(a.die, ENG_ID)
        if ident != ENG_ID_MAGIC:
            print("JCUTIL_FAIL die %s engine ID reads 0x%08x, not 0x%08x (\"MV4I\")"
                  % (a.die, ident, ENG_ID_MAGIC))
            return 1
        if b.rd32(a.die, ENG_UTIL_SEL) & UTIL_NONE:
            cyc = b.rd32(a.die, SEAM_CYCLES)
            print("JCUTIL_NONE die %s seam_cycles_last_go %d: the utilisation counters are not "
                  "built on this card (UTIL_SEL[31]; A_TILED and A_CLK_SPLIT)" % (a.die, cyc))
            print("JCUTIL_DONE die %s" % a.die)
            return 0
        npw, nps, ctr = read_util(b, a.die)
        cyc = b.rd32(a.die, SEAM_CYCLES)
    finally:
        b.close()
    jobcyc = ctr[-1][1]
    print("JCUTIL die %s nports_w %d nports_s %d jobcyc %d seam_cycles_last_go %d"
          % (a.die, npw, nps, jobcyc, cyc))
    ratios = []
    for i, v in ctr[:-1]:
        kind = "w" if i < npw else "s"
        r = (v / jobcyc) if jobcyc else 0.0
        if kind == "w":
            ratios.append((r, i))
        print("JCUTIL die %s port %02d %s beats %d ratio %.4f" % (a.die, i, kind, v, r))
    if ratios and jobcyc:
        lo, hi = min(ratios), max(ratios)
        mean = sum(r for r, _ in ratios) / len(ratios)
        print("JCUTIL_SUMMARY die %s weight ports %d  min %.4f (port %d)  mean %.4f  max %.4f (port %d)"
              % (a.die, len(ratios), lo[0], lo[1], mean, hi[0], hi[1]))
    else:
        print("JCUTIL_SUMMARY die %s jobcyc 0: no A job ran since the last clear/reset" % a.die)
    print("JCUTIL_DONE die %s" % a.die)
    return 0


def cmd_util_clear(a):
    b = Broker(a.sock)
    try:
        b.wr32(a.die, ENG_UTIL_CLR, 1)
    finally:
        b.close()
    print("JCUTIL_CLEARED die %s" % a.die)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("status"); p.add_argument("--sock", required=True)
    p.set_defaults(fn=cmd_status)
    for name, fn in (("seam", cmd_seam), ("util", cmd_util), ("util-clear", cmd_util_clear)):
        p = sub.add_parser(name)
        p.add_argument("--sock", required=True)
        p.add_argument("--die", required=True, choices=["A", "B"])
        if name == "seam":
            p.add_argument("--manifest", default=None)
        p.set_defaults(fn=fn)
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except (OSError, BrokerError, ValueError) as e:
        print("JCSEAM_ERROR %s: %s" % (type(e).__name__, e))
        return 2


if __name__ == "__main__":
    sys.exit(main())
