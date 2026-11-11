#!/usr/bin/env python3
"""tools/jc/jc_loop.py -- run decode on the Jungle Cat's on-fabric token loop (spec 2026-11-04,
plan Task 7). The host only starts, answers NEED_ROW (host rows), relays tokens and credits
between the dies (spec 1b.5 phase 1, plan D3), resends on a paused link, and drains OUT.

    jc_loop.py --sock S --die A [--die2 B] --prompt FILE --max-new N --stop ID
               (--mv4i PATH | --synthetic) --ids-out FILE [--base 0x20000] [--timeout-s 3600]

Run `run_prompt --jc S --jc-die A [--jc-die2 B] ... --open-only` first: it streams the
programs; this tool never touches them. One broker client at a time.
Prints `timing <n> GOs` (run_prompt's line, so jc_ctxtest.sh's check applies) and ends with
^JCLOOP_DONE ids=<n> reason=<r> or ^JCLOOP_FAIL <why>. NO direct hardware access: it is a
broker client, and a real run is the main session's or Oren's (CLAUDE.md).

A WindowUnknown write (NEXT_TOKEN, CTRL, OUT_ACK and the rest outside send_row/setup's own
re-seek-and-resend loops) is never retried (finding 10): it propagates out of run() as a
RuntimeError and main() reports JCLOOP_FAIL rather than risk a double-applied write.
"""
import argparse, json, os, socket, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

REG = dict(ID=0x000, CAPS=0x008, CTRL=0x00C, STATUS=0x010, POS=0x014, N_GEN=0x018,
           PROMPT_LEN=0x01C, MAX_NEW=0x020, ROW_SRC=0x024, ROLE=0x028, RESEND_CAP=0x034,
           ROW_TOK=0x044, NEXT_TOKEN=0x048, ROW_EXP=0x04C, ROW_ADDR=0x050, ROW_DATA=0x054,
           PROMPT_ADDR=0x058, PROMPT_DATA=0x05C, OUT_COUNT=0x060, OUT_ACK=0x064, OUT_ADDR=0x068,
           OUT_DATA=0x06C, LINK_CREDIT=0x074, LINK_CONSUMED=0x078, CRC_FAILS=0x08C,
           LINK_DOWNS=0x094, RESENDS=0x098, STOP_ID0=0x0C0)
REASONS = ["none", "MAX_NEW", "STOP_ID", "MAXPOS", "ABORT", "ENGINE_ERR", "ENGINE_TIMEOUT",
           "SEAM_ERR", "LINK_TIMEOUT", "LINK_RETRY_EXHAUSTED", "BAD_CONFIG", "SEQ_RESET_FAIL",
           "GATHER_ERR"]
ID_MAGIC = 0x544C5031


class Broker:
    def __init__(s, path):
        s.k = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.k.connect(path)
        s.f = s.k.makefile("rwb")

    def _send(s, req):
        # compact separators: fk33_transport_jc.c's form, which the fake broker's parser expects
        s.f.write((json.dumps(req, separators=(",", ":")) + "\n").encode()); s.f.flush()
        return json.loads(s.f.readline())

    def call(s, req, retries=5):
        """finding 10: a WindowUnknown retry is safe only for rd32 -- re-reading changes
        nothing. A write (wr32, wrn) gets exactly one attempt here; it may already have
        landed, so the caller decides what a failure means (re-seek and resend the whole
        buffer for ROW_DATA/PROMPT_DATA, or JCLOOP_FAIL for everything else), never a blind
        retry of a write that could double-apply (a shifted row, a re-armed NEXT_TOKEN)."""
        idempotent = req.get("op") == "rd32"
        for i in range(retries):
            r = s._send(req)
            if r.get("ok"):
                return r
            if not idempotent or "WindowUnknown" not in r.get("err", "") or i == retries - 1:
                raise RuntimeError("broker: %s -> %s" % (req, r.get("err")))
            time.sleep(0.2)


class Die:
    def __init__(s, br, name, base):
        s.br, s.name, s.base = br, name, base

    def rd(s, reg):
        return s.br.call({"die": s.name, "op": "rd32", "off": s.base + REG[reg]})["val"]

    def wr(s, reg, val):
        s.br.call({"die": s.name, "op": "wr32", "off": s.base + REG[reg], "val": val & 0xFFFFFFFF})

    def wrn_fix(s, reg, vals):
        s.br.call({"die": s.name, "op": "wrn", "off": s.base + REG[reg], "fix": True,
                   "vals": [v & 0xFFFFFFFF for v in vals]})


def row_source(a):
    if a.synthetic:
        import tok_loop_model as M
        return lambda tok, n: M.synth_row(tok, n)
    import embed_gather as EG
    pt = EG.PackedTensor(a.mv4i)
    return lambda tok, n: pt.row_bfp(tok, recipe=EG.RECIPE_WIDE)


def send_row(d, row_of, n):
    """Answer NEED_ROW. ROW_DATA auto-increments, so a failed bulk write is redone from
    ROW_ADDR 0; ROW_READY is re-sent only while the same position still needs its row.
    finding 10: this re-seek-and-resend loop is the only retry ROW_DATA gets -- Broker.call
    itself no longer retries a write silently underneath it."""
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
        d.wr("CTRL", 8)


def setup(d, prompt, max_new, stop, role, src, cap):
    if d.rd("ID") != ID_MAGIC:
        raise RuntimeError("die %s: no tok_loop at %#x (ID %#x)" % (d.name, d.base, d.rd("ID")))
    d.wr("PROMPT_LEN", len(prompt)); d.wr("MAX_NEW", max_new)
    d.wr("STOP_ID0", stop if stop >= 0 else 0xFFFFFFFF)
    d.wr("ROLE", role); d.wr("ROW_SRC", src); d.wr("RESEND_CAP", cap)
    if role == 1:
        d.wr("LINK_CREDIT", 0)
    for attempt in range(3):   # finding 10: re-seek PROMPT_ADDR and resend the whole prompt,
        try:                   # never a blind retry of a bulk write that may have partly landed
            d.wr("PROMPT_ADDR", 0)
            d.wrn_fix("PROMPT_DATA", prompt)
            break
        except RuntimeError:
            if attempt == 2:
                raise


def drain(d, got):
    n = d.rd("OUT_COUNT")
    while len(got) < n:
        d.wr("OUT_ADDR", len(got))
        got.append(d.rd("OUT_DATA"))
    d.wr("OUT_ACK", len(got))


def run(a, br):
    prompt = [int(x) for x in open(a.prompt).read().split()]
    A = Die(br, a.die, a.base)
    B = Die(br, a.die2, a.base) if a.die2 else None
    n = A.rd("CAPS") & 0xFFFF
    row_of = row_source(a)
    if B:
        setup(A, prompt, a.max_new, a.stop, 1, 1, a.resend_max)
        setup(B, prompt, a.max_new, a.stop, 2, 2, a.resend_max)
        B.wr("CTRL", 1)
    else:
        setup(A, prompt, a.max_new, a.stop, 0, 1, a.resend_max)
    A.wr("CTRL", 1)
    out, ids = (B or A), []
    relayed = credit = handled = 0
    t0 = time.time()
    while True:
        sa = A.rd("STATUS")
        sb = B.rd("STATUS") if B else sa
        if sa & 4:
            send_row(A, row_of, n)
        drain(out, ids)
        if B:
            c = B.rd("LINK_CONSUMED")
            if c != credit:
                credit = c; A.wr("LINK_CREDIT", c)
            while relayed < len(ids):
                A.wr("NEXT_TOKEN", ids[relayed]); relayed += 1
            A.wr("OUT_ACK", A.rd("OUT_COUNT"))       # A's ring holds the relayed ids: keep it drained
            if sb & 0x10:
                fails = B.rd("CRC_FAILS") + B.rd("LINK_DOWNS")
                if fails > handled:
                    handled = fails
                    bpos = B.rd("POS")
                    A.wr("CTRL", 4)
                    print("jc_loop: die %s paused at position %d, RESEND on %s" % (B.name, bpos, A.name))
            if (sa & 3) == 2 and (sb & 3) == 1:
                B.wr("CTRL", 2)
        if (sa & 3) == 2 and (sb & 3) == 2:
            break
        if time.time() - t0 > a.timeout_s:
            raise RuntimeError("timeout after %d s at position %d" % (a.timeout_s, A.rd("POS")))
    drain(out, ids)
    ra, rb = (sa >> 8) & 0xFF, (sb >> 8) & 0xFF
    with open(a.ids_out, "w") as f:
        f.write("".join("%d\n" % t for t in ids))
    print("timing %d GOs" % (len(prompt) + len(ids) - 1 if ids else len(prompt)))
    ok = {1, 2}
    if ra not in ok or rb not in ok:
        return "JCLOOP_FAIL reason A=%s B=%s ids=%d" % (REASONS[ra], REASONS[rb] if B else "-", len(ids))
    return "JCLOOP_DONE ids=%d reason=%s" % (len(ids), REASONS[rb if B else ra])


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
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x20000)
    ap.add_argument("--resend-max", type=int, default=3)
    ap.add_argument("--timeout-s", type=int, default=3600)
    a = ap.parse_args(argv)
    try:
        line = run(a, Broker(a.sock))
    except (RuntimeError, OSError, ValueError) as e:
        line = "JCLOOP_FAIL %s" % e
    print(line)
    return 0 if "JCLOOP_DONE" in line else 1   # finding 15: a FAULT_PAUSED= prefix moves this off startswith


if __name__ == "__main__":
    sys.exit(main())
