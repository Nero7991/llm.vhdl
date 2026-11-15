"""hw/jc/host/jc_seam.py against a fake broker on a Unix socket (no board).

    python3 -m pytest -q hw/jc/host/test_jc_seam.py
"""
import json, os, socket, subprocess, sys, tempfile, threading

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "jc_seam.py")


class FakeBroker:
    """Answers rd32/wr32/memrd/status like tools/jc/jc_broker.py's Broker.handle()."""
    def __init__(s, regs, util, halted=None):
        s.dir = tempfile.mkdtemp(prefix="jcs")
        s.path = os.path.join(s.dir, "b.sock")
        s.regs, s.util, s.halted = dict(regs), dict(util), halted
        s.sel, s.writes = 0, []
        s.lst = socket.socket(socket.AF_UNIX)
        s.lst.bind(s.path)
        s.lst.listen(1)
        s.t = threading.Thread(target=s.serve, daemon=True)
        s.t.start()

    def answer(s, q):
        op = q.get("op")
        if op == "status":
            return {"ok": True, "dies": {}, "halted": s.halted}
        if op == "rd32":
            off = q["off"]
            if off == 0x12044:
                i, hi = s.sel >> 1, s.sel & 1
                v = s.util.get(i, 0)
                return {"ok": True, "val": (v >> 32) & 0xFFFF if hi else v & 0xFFFFFFFF}
            return {"ok": True, "val": s.regs.get(off, 0)}
        if op == "wr32":
            s.writes.append((q["off"], q["val"]))
            if q["off"] == 0x12040:
                s.sel = q["val"]
            return {"ok": True}
        if op == "memrd":
            return {"ok": True, "hex": "00" * q["n"]}
        return {"ok": False, "err": "ValueError: unknown op"}

    def serve(s):
        while True:
            try:
                c, _ = s.lst.accept()
            except OSError:
                return
            f = c.makefile("rwb")
            for line in f:
                f.write((json.dumps(s.answer(json.loads(line))) + "\n").encode())
                f.flush()
            c.close()


SEAM = {0xE000: 0x4C4C4D32, 0xE004: 2, 0xE008: 248320, 0xE00C: (64 << 16) | 5120,
        0xE010: 16384, 0xE04C: 0xFD, 0xE018: 0x1, 0xE040: 123456}
ENG = {0x12014: 0x4D563449, 0x1201C: 24 | (3 << 8) | (48 << 16) | (32 << 24)}


def tool(*args):
    return subprocess.run([sys.executable, TOOL] + list(args), capture_output=True, text=True,
                          timeout=60)


def test_util_reads_every_counter_48_bits():
    jobcyc = (1 << 32) + 1000
    util = {i: (i + 1) * 1000 for i in range(27)}
    util[5] = (1 << 32) + 500            # high half must be read and used
    util[27] = jobcyc
    fb = FakeBroker({**SEAM, **ENG}, util)
    p = tool("util", "--sock", fb.path, "--die", "B")
    assert p.returncode == 0, p.stdout + p.stderr
    o = p.stdout
    assert "JCUTIL die B nports_w 24 nports_s 3 jobcyc %d seam_cycles_last_go 123456" % jobcyc in o
    assert "JCUTIL die B port 05 w beats %d ratio %.4f" % ((1 << 32) + 500, ((1 << 32) + 500) / jobcyc) in o
    assert "JCUTIL die B port 26 s beats 27000" in o
    assert o.count(" w beats ") == 24 and o.count(" s beats ") == 3
    assert "JCUTIL_DONE die B" in o
    # selector writes only: 2 per counter, never UTIL_CLR
    assert len(fb.writes) == 56 and all(off == 0x12040 for off, _ in fb.writes)


def test_util_reports_counters_not_built():
    """a450 Task 9b: a split-on card has no counters; UTIL_SEL[31] says so.  The tool must
    say "not built" and read no counter (one UTIL_DATA read on a built card's absent counter
    would be a 0 that looks like an idle port), not print garbage ratios."""
    fb = FakeBroker({**SEAM, **ENG, 0x12040: 0x80000000}, {i: 999 for i in range(28)})
    p = tool("util", "--sock", fb.path, "--die", "A")
    assert p.returncode == 0, p.stdout + p.stderr
    assert "JCUTIL_NONE die A seam_cycles_last_go 123456" in p.stdout
    assert "JCUTIL_DONE die A" in p.stdout
    assert " beats " not in p.stdout and "JCUTIL die A nports_w" not in p.stdout
    assert fb.writes == []


def test_util_clear_on_a_card_without_counters_writes_nothing():
    """Task 9b fix round 1 (m3): util-clear on a split-on card says the counters are not
    built, and writes no UTIL_CLR (a write that clears nothing must not print CLEARED)."""
    fb = FakeBroker({**ENG, 0x12040: 0x80000000}, {})
    p = tool("util-clear", "--sock", fb.path, "--die", "B")
    assert p.returncode == 0, p.stdout + p.stderr
    assert "JCUTIL_NONE die B" in p.stdout and "JCUTIL_CLEARED" not in p.stdout
    assert fb.writes == []


def test_util_refuses_a_dead_engine():
    fb = FakeBroker({**SEAM, 0x12014: 0xFFFFFFFF}, {})
    p = tool("util", "--sock", fb.path, "--die", "A")
    assert p.returncode == 1 and "JCUTIL_FAIL" in p.stdout


def test_util_clear_writes_clr():
    fb = FakeBroker(ENG, {})
    p = tool("util-clear", "--sock", fb.path, "--die", "A")
    assert p.returncode == 0 and "JCUTIL_CLEARED die A" in p.stdout
    assert fb.writes == [(0x12048, 1)]


def test_seam_is_fk33ctls_report_and_read_only():
    fb = FakeBroker(SEAM, {})
    p = tool("seam", "--sock", fb.path, "--die", "A")
    o = p.stdout
    assert "seam id    0x4c4c4d32" in o, o + p.stderr
    assert "caps       n_vocab 248320  n_embd 5120  n_layer 64  ctx 16384 tokens" in o
    assert any(l.startswith("status ") and "err=0" in l for l in o.splitlines())
    assert "JCSEAM_DONE die A" in o
    assert fb.writes == []


def test_status_and_halt():
    fb = FakeBroker({}, {})
    p = tool("status", "--sock", fb.path)
    assert p.returncode == 0 and p.stdout.startswith("JCSEAM_STATUS ok ")
    fb2 = FakeBroker({}, {}, halted="LoadAborted: DNA mismatch")
    p = tool("status", "--sock", fb2.path)
    assert p.returncode == 1 and p.stdout.startswith("JCSEAM_STATUS halted ")
