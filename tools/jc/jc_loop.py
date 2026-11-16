#!/usr/bin/env python3
"""tools/jc/jc_loop.py -- run decode on the Jungle Cat's on-fabric token loop (spec 2026-11-04,
plan Task 7). The host only starts, answers NEED_ROW (host rows), relays tokens and credits
between the dies (spec 1b.5 phase 1, plan D3), resends on a paused link, and drains OUT.

    jc_loop.py --sock S --die A [--die2 B] --prompt FILE --max-new N --stop ID
               (--mv4i PATH | --synthetic) --ids-out FILE [--ids-stream PATH] [--base 0x20000]
               [--timeout-s 3600] [--dump-xout PATH] [--dump-xout2 PATH] [--fault-polarity-at N]

--ids-stream PATH (the llmvhdl_server.py loop-mode caller): each id is also written to PATH,
one decimal per line, flushed, as soon as drain() pulls it off OUT -- never twice, since
drain() is the only place `got` grows. A write failure there (BrokenPipeError/OSError, e.g.
a closed ssh pipe) is a stop request: it propagates out of decode() so run()'s finally sees
clean=False and ABORTs both dies. SIGTERM and SIGHUP do the same thing by another route: both
raise SystemExit (not caught by main()'s except tuple), which unwinds through the same finally.

--dump-xout/--dump-xout2 (plan Task 8 Step 1): after a clean finish, die A's / die B's R_X
from the seam's window 3, in run_prompt --dump-xout's format (server/tests/run_prompt.c:319:
`exp E`, then n_embd int16 lines). --fault-polarity-at N (pair, silicon only; the broker model
has no polarity): once N ids are out, invert die A's TX polarity (LINK_CTRL bit 2, plan D5),
wait for die B to pause, restore it, issue exactly one RESEND, and prefix the result line
`FAULT_PAUSED=<0|1> `; a run that never reached N ids fails.

Run `run_prompt --jc S --jc-die A [--jc-die2 B] ... --open-only` first: it streams the
programs; this tool never touches them. One broker client at a time.
Prints `timing <n> GOs` (run_prompt's line, so jc_ctxtest.sh's check applies) and ends with
^JCLOOP_DONE ids=<n> reason=<r> or ^JCLOOP_FAIL <why>. NO direct hardware access: it is a
broker client, and a real run is the main session's or Oren's (CLAUDE.md).

FAILURE HANDLING (final review I1, 2026-11-11):
  * before setup, a die whose loop is still RUNNING (an earlier client's run) is ABORTed and
    waited for (up to 5 s; refused if it does not stop): its START would otherwise be ignored
    and it would carry on with the stale run's latched configuration;
  * the run ends as soon as either die stops for a reason other than MAX_NEW or STOP_ID, or
    reads IDLE after its START;
  * every exit other than a clean finish (both dies stopped MAX_NEW/STOP_ID) writes ABORT to
    both dies, so nothing is left running on the card.

WindowUnknown (the broker cannot prove whether a frame ran; ruling 2026-11-11, which reverses
finding 10 for absolute writes):
  * reads, and writes of an ABSOLUTE value (ABSOLUTE below: OUT_ACK, LINK_CREDIT, ROW_EXP,
    ROW_ADDR, OUT_ADDR, PROMPT_ADDR and the configuration registers) are retried: writing the
    same value twice is harmless;
  * CTRL pulses (START, ABORT, RESEND, ROW_READY, CLEAR) are never retried: the state is read
    back, and the run goes on only if the read-back proves the pulse landed, else JCLOOP_FAIL;
  * NEXT_TOKEN (a duplicate re-arms it) is never retried: JCLOOP_FAIL;
  * ROW_DATA / PROMPT_DATA (auto-incrementing windows) keep their re-seek-and-resend loops.
Die B's TMO_LINK is written 0xFFFFFFFF in setup (final review I2): its link wait spans die A's
position and the host relay.
"""
import argparse, json, os, signal, socket, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

REG = dict(ID=0x000, CAPS=0x008, CTRL=0x00C, STATUS=0x010, POS=0x014, N_GEN=0x018,
           PROMPT_LEN=0x01C, MAX_NEW=0x020, ROW_SRC=0x024, ROLE=0x028, TMO_LINK=0x030, RESEND_CAP=0x034,
           ROW_TOK=0x044, NEXT_TOKEN=0x048, ROW_EXP=0x04C, ROW_ADDR=0x050, ROW_DATA=0x054,
           PROMPT_ADDR=0x058, PROMPT_DATA=0x05C, OUT_COUNT=0x060, OUT_ACK=0x064, OUT_ADDR=0x068,
           OUT_DATA=0x06C, LINK_CREDIT=0x074, LINK_CONSUMED=0x078, CRC_FAILS=0x08C,
           LINK_DOWNS=0x094, RESENDS=0x098, STOP_ID0=0x0C0,
           LINK_CTRL=0x07C, LINK_STATUS=0x080, FRAMES_SENT=0x084, FRAMES_GOOD=0x088, SEQPOS_BAD=0x090)
SEAM = 0xE000                             # server/fk33_seam.h:227
S_WIN_SEL, S_WIN_ADDR, S_WIN_DATA, S_XEXP_OUT = 0x58, 0x5C, 0x60, 0xA4
# registers whose write is an absolute value: a WindowUnknown write is simply written again
ABSOLUTE = frozenset(["PROMPT_LEN", "MAX_NEW", "ROW_SRC", "ROLE", "TMO_LINK", "RESEND_CAP",
                      "ROW_EXP", "ROW_ADDR", "PROMPT_ADDR", "OUT_ACK", "OUT_ADDR", "LINK_CREDIT",
                      "STOP_ID0", "LINK_CTRL"])
CTRL_BITS = dict(START=1, ABORT=2, RESEND=4, ROW_READY=8, CLEAR=16)
REASONS = ["none", "MAX_NEW", "STOP_ID", "MAXPOS", "ABORT", "ENGINE_ERR", "ENGINE_TIMEOUT",
           "SEAM_ERR", "LINK_TIMEOUT", "LINK_RETRY_EXHAUSTED", "BAD_CONFIG", "SEQ_RESET_FAIL",
           "GATHER_ERR"]
OK_REASONS = {1, 2}                       # MAX_NEW, STOP_ID
S_IDLE, S_RUN, S_STOPPED = 0, 1, 2
ID_MAGIC = 0x544C5031
TMO_LINK_MAX = 0xFFFFFFFF                 # rtl/tok_loop_pkg.vhd TMO_LINK_DEFAULT


class WindowUnknown(RuntimeError):
    """The broker could not prove whether the request ran."""


def reason_name(r):
    return REASONS[r] if r < len(REASONS) else "reason%d" % r


class Broker:
    def __init__(s, path):
        s.k = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.k.connect(path)
        s.f = s.k.makefile("rwb")

    def _send(s, req):
        # compact separators: fk33_transport_jc.c's form, which the fake broker's parser expects
        s.f.write((json.dumps(req, separators=(",", ":")) + "\n").encode()); s.f.flush()
        return json.loads(s.f.readline())

    def call(s, req, retries=5, retry_write=False):
        """A WindowUnknown is retried for rd32 and, when the caller says the write is of an
        absolute value (retry_write), for wr32; anything else gets exactly one attempt and
        raises WindowUnknown (or RuntimeError for any other failure) for the caller to judge."""
        again = req.get("op") == "rd32" or (retry_write and req.get("op") == "wr32")
        for i in range(retries):
            r = s._send(req)
            if r.get("ok"):
                return r
            err = r.get("err", "")
            if "WindowUnknown" not in err:
                raise RuntimeError("broker: %s -> %s" % (req, err))
            if not again or i == retries - 1:
                raise WindowUnknown("broker: %s -> %s" % (req, err))
            if req.get("op") != "rd32":
                print("jc_loop: die %s wr32 %#x WindowUnknown, written again (absolute value)"
                      % (req.get("die"), req.get("off", 0)))
            time.sleep(0.2)


class Die:
    def __init__(s, br, name, base):
        s.br, s.name, s.base = br, name, base

    def rd(s, reg):
        return s.br.call({"die": s.name, "op": "rd32", "off": s.base + REG[reg]})["val"]

    def wr(s, reg, val):
        if reg == "CTRL":
            raise ValueError("CTRL is a pulse register: use Die.ctrl(), which verifies by read-back")
        s.br.call({"die": s.name, "op": "wr32", "off": s.base + REG[reg], "val": val & 0xFFFFFFFF},
                  retry_write=reg in ABSOLUTE)

    def wrn_fix(s, reg, vals):
        s.br.call({"die": s.name, "op": "wrn", "off": s.base + REG[reg], "fix": True,
                   "vals": [v & 0xFFFFFFFF for v in vals]})

    def ctrl(s, pulse, landed):
        """Write one CTRL pulse, once. On WindowUnknown, `landed()` reads the state back: the run
        goes on only if it proves the pulse took effect."""
        try:
            s.br.call({"die": s.name, "op": "wr32", "off": s.base + REG["CTRL"], "val": CTRL_BITS[pulse]})
        except WindowUnknown:
            if not landed():
                raise RuntimeError("die %s: CTRL %s answered WindowUnknown and the read-back does not "
                                   "show it landed; not retried" % (s.name, pulse))
            print("jc_loop: die %s CTRL %s answered WindowUnknown; read-back shows it landed" % (s.name, pulse))


def state(st):
    return st & 3, (st >> 8) & 0xFF


def start(d):
    before = d.rd("STATUS")

    def landed():
        st = d.rd("STATUS")
        return st & 3 == S_RUN or (st & 3 == S_STOPPED and st != before)
    d.ctrl("START", landed)


def abort_and_wait(d, wait_s=5.0):
    d.ctrl("ABORT", lambda: d.rd("STATUS") & 3 != S_RUN)
    t0 = time.time()
    while d.rd("STATUS") & 3 == S_RUN:
        if time.time() - t0 > wait_s:
            raise RuntimeError("die %s: still running %.0f s after ABORT; refusing to set it up" % (d.name, wait_s))
        time.sleep(0.05)


def row_source(a):
    if a.synthetic:
        import tok_loop_model as M
        return lambda tok, n: M.synth_row(tok, n)
    import embed_gather as EG
    pt = EG.PackedTensor(a.mv4i)
    return lambda tok, n: pt.row_bfp(tok, recipe=EG.RECIPE_WIDE)


def send_row(d, row_of, n):
    """Answer NEED_ROW. ROW_DATA auto-increments, so a failed bulk write is redone from
    ROW_ADDR 0; ROW_READY is re-sent only while the same position still needs its row."""
    pos, tok = d.rd("POS"), d.rd("ROW_TOK")
    mant, exp = row_of(tok, n)
    for attempt in range(3):
        try:
            d.wr("ROW_EXP", exp); d.wr("ROW_ADDR", 0)
            d.wrn_fix("ROW_DATA", [m & 0xFFFF for m in mant])
            break
        except RuntimeError:
            if attempt == 2:
                raise
    st = d.rd("STATUS")
    if st & 4 and d.rd("POS") == pos:
        def landed():
            s2 = d.rd("STATUS")
            return not (s2 & 4) or d.rd("POS") != pos or s2 & 3 != S_RUN
        d.ctrl("ROW_READY", landed)


def setup(d, prompt, max_new, stop, role, src, cap):
    if d.rd("ID") != ID_MAGIC:
        raise RuntimeError("die %s: no tok_loop at %#x (ID %#x)" % (d.name, d.base, d.rd("ID")))
    d.wr("PROMPT_LEN", len(prompt)); d.wr("MAX_NEW", max_new)
    d.wr("STOP_ID0", stop if stop >= 0 else 0xFFFFFFFF)
    d.wr("ROLE", role); d.wr("ROW_SRC", src); d.wr("RESEND_CAP", cap)
    if role == 2:
        d.wr("TMO_LINK", TMO_LINK_MAX)
    if role == 1:
        d.wr("LINK_CREDIT", 0)
    for attempt in range(3):   # re-seek PROMPT_ADDR and resend the whole prompt, never a blind
        try:                   # retry of a bulk write that may have partly landed
            d.wr("PROMPT_ADDR", 0)
            d.wrn_fix("PROMPT_DATA", prompt)
            break
        except RuntimeError:
            if attempt == 2:
                raise


def drain(d, got, stream=None):
    """The one place `got` grows: streaming here (if `stream` is set) writes each newly
    drained id exactly once, in order, as soon as it is known. A write failure
    (BrokenPipeError/OSError) is not swallowed: it propagates so run()'s finally treats it
    as a stop request and aborts both dies."""
    n = d.rd("OUT_COUNT")
    while len(got) < n:
        d.wr("OUT_ADDR", len(got))
        v = d.rd("OUT_DATA")
        got.append(v)
        if stream is not None:
            stream.write("%d\n" % v)
            stream.flush()
    d.wr("OUT_ACK", len(got))


def resend(A):
    r0 = A.rd("RESENDS")

    def landed():
        st = A.rd("STATUS")
        return A.rd("RESENDS") != r0 or state(st)[1] == 9
    A.ctrl("RESEND", landed)


def dump_xout(br, die, n, path):
    """run_prompt --dump-xout's file from the seam's window 3, after the loop stopped and
    released the seam. WIN_SEL/WIN_ADDR are absolute (retried); a failed bulk read of the
    auto-incrementing WIN_DATA is redone from WIN_ADDR 0, never resumed."""
    for attempt in range(3):
        try:
            br.call({"die": die, "op": "wr32", "off": SEAM + S_WIN_SEL, "val": 3}, retry_write=True)
            br.call({"die": die, "op": "wr32", "off": SEAM + S_WIN_ADDR, "val": 0}, retry_write=True)
            vals = br.call({"die": die, "op": "rdn", "off": SEAM + S_WIN_DATA, "fix": True, "n": n})["vals"]
            break
        except WindowUnknown:
            if attempt == 2:
                raise
    e = br.call({"die": die, "op": "rd32", "off": SEAM + S_XEXP_OUT})["val"]
    e = e - (1 << 32) if e >= (1 << 31) else e
    with open(path, "w") as f:
        f.write("exp %d\n" % e)
        f.write("".join("%d\n" % ((v & 0xFFFF) - 0x10000 if v & 0x8000 else v & 0xFFFF) for v in vals))


def polarity_fault(A, B):
    """Plan Task 8 Step 1(a): invert A's TX polarity until B pauses (or 10 s), restore it,
    wait for B's rx_channel_up (or 10 s). Returns (paused, handled) where `handled` is one
    less than B's CRC_FAILS + LINK_DOWNS, so the relay issues exactly one RESEND."""
    A.wr("LINK_CTRL", 4)
    t1 = time.time()
    while not (B.rd("STATUS") & 0x10) and time.time() - t1 < 10:
        pass
    paused = bool(B.rd("STATUS") & 0x10)
    print("jc_loop: fault: TX polarity inverted on %s; %s paused=%d crc_fails=%d link_downs=%d"
          % (A.name, B.name, paused, B.rd("CRC_FAILS"), B.rd("LINK_DOWNS")))
    A.wr("LINK_CTRL", 0)
    t1 = time.time()
    while not (B.rd("LINK_STATUS") & 2) and time.time() - t1 < 10:
        pass
    return paused, B.rd("CRC_FAILS") + B.rd("LINK_DOWNS") - 1


def decode(a, A, B, prompt, stream=None):
    """The run proper. Returns (line, clean)."""
    n = A.rd("CAPS") & 0xFFFF
    row_of = row_source(a)
    for d in [A] + ([B] if B else []):       # I1: an earlier client's run still going
        st = d.rd("STATUS")
        if st & 3 == S_RUN:
            print("jc_loop: die %s was running (position %d); ABORT and wait" % (d.name, d.rd("POS")))
            abort_and_wait(d)
    if B:
        setup(A, prompt, a.max_new, a.stop, 1, 1, a.resend_max)
        setup(B, prompt, a.max_new, a.stop, 2, 2, a.resend_max)
        start(B)
    else:
        setup(A, prompt, a.max_new, a.stop, 0, 1, a.resend_max)
    start(A)
    out, ids = (B or A), []
    relayed = credit = handled = 0
    fault_done = fault_paused = False
    t0 = time.time()
    while True:
        sa = A.rd("STATUS")
        sb = B.rd("STATUS") if B else sa
        bad = []
        for d, st in ((A, sa), (B, sb)) if B else ((A, sa),):
            s, r = state(st)
            if s == S_IDLE:
                bad.append("die %s reads IDLE after START" % d.name)
            elif s == S_STOPPED and r not in OK_REASONS:
                bad.append("die %s stopped %s" % (d.name, reason_name(r)))
        if bad:
            drain(out, ids, stream)
            ra, rb = state(sa)[1], state(sb)[1]
            return ("JCLOOP_FAIL %s; reason A=%s B=%s ids=%d"
                    % ("; ".join(bad), reason_name(ra), reason_name(rb) if B else "-", len(ids))), False
        if sa & 4:
            send_row(A, row_of, n)
        drain(out, ids, stream)
        if B:
            c = B.rd("LINK_CONSUMED")
            if c != credit:
                credit = c; A.wr("LINK_CREDIT", c)
            while relayed < len(ids):
                A.wr("NEXT_TOKEN", ids[relayed]); relayed += 1
            A.wr("OUT_ACK", A.rd("OUT_COUNT"))       # A's ring holds the relayed ids: keep it drained
            if a.fault_polarity_at and not fault_done and len(ids) >= a.fault_polarity_at:
                fault_paused, handled = polarity_fault(A, B)
                fault_done = True
                sb = B.rd("STATUS")
            if sb & 0x10:
                fails = B.rd("CRC_FAILS") + B.rd("LINK_DOWNS")
                if fails > handled:
                    handled = fails
                    bpos = B.rd("POS")
                    resend(A)
                    print("jc_loop: die %s paused at position %d, RESEND on %s" % (B.name, bpos, A.name))
            if (sa & 3) == S_STOPPED and (sb & 3) == S_RUN:
                abort_and_wait(B)
        if (sa & 3) == S_STOPPED and (sb & 3) == S_STOPPED:
            break
        if time.time() - t0 > a.timeout_s:
            raise RuntimeError("timeout after %d s at position %d" % (a.timeout_s, A.rd("POS")))
    drain(out, ids, stream)
    sa = A.rd("STATUS"); sb = B.rd("STATUS") if B else sa
    ra, rb = state(sa)[1], state(sb)[1]
    with open(a.ids_out, "w") as f:
        f.write("".join("%d\n" % t for t in ids))
    print("timing %d GOs" % (len(prompt) + len(ids) - 1 if ids else len(prompt)))
    pre = "FAULT_PAUSED=%d " % fault_paused if a.fault_polarity_at else ""
    if ra not in OK_REASONS or rb not in OK_REASONS:
        return pre + "JCLOOP_FAIL reason A=%s B=%s ids=%d" % (reason_name(ra), reason_name(rb) if B else "-",
                                                               len(ids)), False
    if a.fault_polarity_at and not fault_done:
        return pre + "JCLOOP_FAIL the fault was never injected (%d ids < %d)" % (len(ids), a.fault_polarity_at), False
    if a.dump_xout:
        dump_xout(A.br, A.name, n, a.dump_xout)
    if a.dump_xout2 and B:
        dump_xout(B.br, B.name, n, a.dump_xout2)
    return pre + "JCLOOP_DONE ids=%d reason=%s" % (len(ids), reason_name(rb if B else ra)), True


def _say(msg):
    """print(), but a broken stdout (the ids-stream case, or a dropped ssh pipe) must not
    stop the rest of abort_all's work."""
    try:
        print(msg)
    except OSError:
        pass


def abort_all(dies):
    """I1: on any exit but a clean finish, ABORT every die (best effort: one failure must not
    stop the next die's ABORT). An ABORT to a die that is not running does nothing."""
    for d in dies:
        try:
            d.ctrl("ABORT", lambda d=d: d.rd("STATUS") & 3 != S_RUN)
            _say("jc_loop: ABORT sent to die %s" % d.name)
        except Exception as e:                   # report, keep going: the other die still needs it
            _say("jc_loop: ABORT to die %s failed: %s" % (d.name, e))


def run(a, br):
    prompt = [int(x) for x in open(a.prompt).read().split()]
    A = Die(br, a.die, a.base)
    B = Die(br, a.die2, a.base) if a.die2 else None
    clean = False
    stream = open(a.ids_stream, "w") if a.ids_stream else None
    try:
        line, clean = decode(a, A, B, prompt, stream)
        return line
    finally:
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass
        if not clean:
            abort_all([A] + ([B] if B else []))


def _raise_on_signal(signum, frame):
    """SIGTERM/SIGHUP handler: raise SystemExit, which is not in main()'s except tuple, so it
    unwinds through run()'s finally (clean is False there) and aborts both dies."""
    raise SystemExit(1)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", required=True)
    ap.add_argument("--die", required=True)
    ap.add_argument("--die2")
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--max-new", type=int, required=True)
    ap.add_argument("--stop", type=int, default=-1)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--mv4i")
    g.add_argument("--synthetic", action="store_true")
    ap.add_argument("--ids-out", required=True)
    ap.add_argument("--ids-stream")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x20000)
    ap.add_argument("--resend-max", type=int, default=3)
    ap.add_argument("--timeout-s", type=int, default=3600)
    ap.add_argument("--dump-xout")
    ap.add_argument("--dump-xout2")
    ap.add_argument("--fault-polarity-at", type=int, default=0)
    a = ap.parse_args(argv)
    if a.fault_polarity_at and not a.die2:
        ap.error("--fault-polarity-at needs --die2 (a pair)")

    signal.signal(signal.SIGTERM, _raise_on_signal)
    signal.signal(signal.SIGHUP, _raise_on_signal)

    try:
        line = run(a, Broker(a.sock))
    except (RuntimeError, OSError, ValueError, KeyError, ImportError) as e:
        line = "JCLOOP_FAIL %s" % e
    print(line)
    return 0 if "JCLOOP_DONE" in line else 1   # finding 15: a FAULT_PAUSED= prefix moves this off startswith


if __name__ == "__main__":
    sys.exit(main())
