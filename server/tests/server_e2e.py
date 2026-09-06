#!/usr/bin/env python3
"""End-to-end check of llama_server's OWN request path, against an
independently computed expected token.

WHY THIS EXISTS.  server/verify_chat_template.py checks the renderer through
tests/chat_batch.c.  server/tests/seam_selftest.c checks the seam through the
pl_backend API.  Neither touches `build_chat_msgs()` in llama_server.cpp, the
HTTP layer, the sampler, the UTF-8 boundary gate or the detokenizer -- and a
column of well-verified units and a green smoke test are jointly compatible
with a server that builds the wrong prompt.

WHAT IT DOES.  The simulated card's greedy argmax is a published closed form
over the WHOLE prefix since the last reset:

    hist = fnv1a chain over (token_id, position, fnv1a(embed(token_id)))
    pick = (hist*31 + position*7 + fnv1a(embed(last_token))) mod n_vocab

So for a given message list the first greedy token is predictable WITHOUT going
anywhere near the server.  This script replays the chain over the ids that
tests/chat_batch.c produces, asks the server for exactly one greedy token, and
compares the detokenized text.

The chain matters.  The first version of the simulated card used the LAST
token id where `hist` now is, so the expected value depended only on the last
id and the prompt length -- and cases 2 and 4 below, two different 25-id
prompts ending in the same token, produced the SAME expectation.  The check
could not have seen a prefill that dropped, duplicated or reordered any earlier
token.  Coverage of the input space was not coverage of the output space.

That is an oracle, not a round trip: nothing here decodes what the server
encoded.  Two independent computations of one quantity are compared, and only
one of them goes through the HTTP layer, `build_chat_msgs`, prefill and the
detokenizer.

WHAT IT CANNOT DO.  Say anything about inference.  The card is simulated and
the embedding is synthetic; see server/fk33_seam.h.

    python3 server/tests/server_e2e.py            # starts its own server
    python3 server/tests/server_e2e.py --url http://127.0.0.1:8000
"""

import argparse
import json
import os
import struct
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(HERE)
ROOT = os.path.dirname(SERVER_DIR)
sys.path.insert(0, SERVER_DIR)
from verify_chat_template import run_c, ROLE, build              # noqa: E402


# --- the two functions the simulated card and pl_backend publish -------------

def synthetic_embed(token_id, n_embd):
    """server/pl_backend.c pl_embed_synthetic."""
    h = (2166136261 ^ (token_id & 0xFFFFFFFF)) & 0xFFFFFFFF
    out = []
    for i in range(n_embd):
        h = (h ^ i) & 0xFFFFFFFF
        h = (h * 16777619) & 0xFFFFFFFF
        v = (h >> 16) - 32768
        out.append(v & 0xFFFF)          # as stored, little-endian int16
    return out


def fnv1a_u16(vals):
    """server/fk33_sim.c fold_x, over the int16 as stored."""
    h = 2166136261
    for v in vals:
        h = ((h ^ (v & 0xFFFF)) * 16777619) & 0xFFFFFFFF
    return h


def expected_first_token(ids, n_embd, n_vocab):
    """server/fk33_sim.c default_logits, replayed over the whole prefix."""
    hist, fx = 2166136261, 0
    for pos, tok in enumerate(ids):
        fx = fnv1a_u16(synthetic_embed(tok, n_embd))
        hist = ((hist ^ (tok & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
        hist = ((hist ^ (pos & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
        hist = ((hist ^ fx) * 16777619) & 0xFFFFFFFF
    # MASK TO 32 BITS.  fk33_sim.c computes this in uint32 arithmetic and
    # `hist * 31` overflows on essentially every input; Python's unbounded ints
    # do not.  This bit me twice -- the first time the sum was small enough not
    # to wrap and the omission was invisible.
    return (((hist * 31 + (len(ids) - 1) * 7 + fx) & 0xFFFFFFFF)) % n_vocab


# --- detokenize one id, via the C batch driver's decode path -----------------

def piece_of(cbin, qtk, token_id):
    """Ask tokenizer_c_batch for one id's bytes.  Uses the OTHER driver, the
    tokenizer one, so this script never links the code it is checking."""
    p = bytearray(struct.pack("<I", 0))              # no encode texts
    p += struct.pack("<I", 1)                        # one id list
    p += struct.pack("<I", 1) + struct.pack("<i", token_id)
    r = subprocess.run([cbin, qtk, "--detok"], input=bytes(p), stdout=subprocess.PIPE)
    if r.returncode != 0:
        raise SystemExit(f"{cbin} exited {r.returncode}")
    buf, pos = r.stdout, 0
    m = struct.unpack_from("<I", buf, pos)[0]; pos += 4
    return bytes(buf[pos:pos + m])


def post(url, body, timeout=60):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def get(url, timeout=60):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode())


CASES = [
    [{"role": "user", "content": "hello"}],
    [{"role": "system", "content": "You are terse."}, {"role": "user", "content": "hi"}],
    [{"role": "user", "content": "a"}, {"role": "assistant", "content": "b"},
     {"role": "user", "content": "c"}],
    [{"role": "user", "content": "  日本語のテキスト  "}],
    [{"role": "user", "content": "q"},
     {"role": "assistant", "content": "<think>\nr\n</think>\n\nbody"},
     {"role": "user", "content": "again"}],
    # An explicit reasoning_content, which the template prefers over splitting
    # the content on </think>.  Added because the "drop the reasoning field"
    # mutation did NOT bite without it -- no case exercised that branch of
    # build_chat_msgs at all.
    [{"role": "user", "content": "q"},
     {"role": "assistant", "content": "body", "reasoning_content": "the reasoning"}],
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=None, help="an already-running server")
    ap.add_argument("--port", type=int, default=8231)
    ap.add_argument("--qtk", default=os.path.join(ROOT, "build_artifacts_tok",
                                                  "qwen35_9b.qtk"))
    ap.add_argument("--cbin", default=os.path.join(ROOT, "build_artifacts_tok",
                                                   "chat_batch"))
    ap.add_argument("--tokbin", default=os.path.join(ROOT, "build_artifacts_tok",
                                                     "tokenizer_c_batch"))
    a = ap.parse_args()

    for f in (a.qtk, a.tokbin):
        if not os.path.exists(f):
            print(f"SKIP: {f} is missing.  Build it: "
                  f"python3 server/verify_chat_template.py --build")
            return 0

    # ALWAYS rebuild chat_batch, never trust the one on disk.
    #
    # MEASUREMENT TRAP, hit on this script's first run: verify_chat_template.py
    # --mutate leaves a MUTATED chat_batch at the same path, and the last thing
    # run before this was `--mutate no-special`.  So the reference ids came from
    # a build with parse_special = 0: 28 ids where the correct answer is 13, and
    # every case "failed" with the server being right and the oracle wrong.  A
    # stale artefact from a deliberately-broken build is the most convincing
    # kind of wrong reference, because it looks like a reference.
    build(a.cbin)

    proc = None
    url = a.url
    if not url:
        exe = os.path.join(SERVER_DIR, "llama_server")
        if not os.path.exists(exe):
            print("SKIP: server/llama_server not built")
            return 0
        # --embed synthetic is EXPLICIT and load-bearing.  This script's own
        # oracle (synthetic_embed below) models pl_embed_synthetic, so it can
        # only check the request path against that provider.  llama_server's
        # default became the BF16 GGUF on 2026-08-29; leaving the default here
        # would make every case fail with the server right and the oracle wrong,
        # which is the most convincing kind of wrong reference.
        # --desc-arena-bytes is REQUIRED, not decoration.  pl_open refuses an
        # undeclared subsystem A descriptor arena (a refusal added 2026-08-29,
        # replacing a printed note), and llama_server deliberately supplies no
        # default because nothing may re-derive it.  159232 = 311 descriptors
        # at a 512-byte slot, the 9B token program's size.
        #
        # stderr is CAPTURED, not discarded.  It used to go to DEVNULL, so when
        # the server started refusing this test reported only "server never came
        # up" -- a statement about the harness, with the actual reason thrown
        # away.  On failure the captured text is printed below.
        proc = subprocess.Popen([exe, "--model", "qwen35", "--port", str(a.port),
                                 "--qtk", a.qtk, "--embed", "synthetic",
                                 "--desc-arena-bytes", "159232"],
                                cwd=ROOT, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE)
        url = f"http://127.0.0.1:{a.port}"
        for _ in range(120):
            try:
                get(url + "/v1/models", timeout=2)
                break
            except Exception:                                    # noqa: BLE001
                time.sleep(1)
        else:
            proc.kill()
            err = b""
            try:
                err = proc.stderr.read() or b""
            except Exception:                                    # noqa: BLE001
                pass
            print("FAIL: server never came up")
            if err:
                print("---- the server's own stderr ----")
                print(err.decode("utf-8", "replace").rstrip())
                print("---- end ----")
            return 1

    try:
        models = get(url + "/v1/models")
        m = models["data"][0]
        n_vocab, n_embd = m["n_vocab"], 4096
        print(f"server            : {m['id']} n_vocab={n_vocab} n_ctx={m['n_ctx']}")
        assert "NOT INFERENCE" in m["description"], \
            "the model description must say the output is not inference"

        # the ids, from the SAME driver verify_chat_template.py checks
        cases = [(c, 1, 0) for c in CASES]
        rendered = run_c(a.cbin, cases, a.qtk)

        fails = 0
        for i, ((msgs, _, _), (rc, txt, ids)) in enumerate(zip(cases, rendered)):
            if rc < 0:
                print(f"  case {i}: renderer refused ({rc}); skipped")
                continue
            want_id = expected_first_token(ids, n_embd, n_vocab)
            want_bytes = piece_of(a.tokbin, a.qtk, want_id)

            r = post(url + "/v1/chat/completions",
                     {"messages": msgs, "max_tokens": 1, "temperature": 0})
            got = r["choices"][0]["message"]["content"].encode("utf-8")

            # A control token renders as nothing with render_special = 0, which
            # is what the server uses; treat that as a match against b"".
            if got != want_bytes:
                fails += 1
                print(f"  FAIL case {i}: {len(ids)} prompt ids, last={ids[-1]}, "
                      f"pos={len(ids)-1}")
                print(f"    expected id {want_id} -> {want_bytes!r}")
                print(f"    server gave            {got!r}")
            else:
                print(f"  ok   case {i}: {len(ids)} ids, first token {want_id} "
                      f"-> {want_bytes!r}")

        # ---- usage.prompt_tokens on THIS arm -----------------------------
        #
        # The FK33 seam arm reported `prompt_tokens: 0` on every response, and
        # `total_tokens` equal to the completion alone.  The stories arm has
        # set it correctly since the hardcoded-zero fix and pins it with C8 --
        # which is exactly why this survived: the row that would have caught it
        # was written against the OTHER arm, so both arms were "covered" and
        # one of them was wrong.
        #
        # TWO PROMPTS, NOT ONE, AND THAT IS THE POINT.  A single case cannot
        # tell a real token count from a constant: the pre-fix server returned
        # 0 for everything, and a server that returned 13 for everything would
        # pass a one-prompt check just as happily.  The check that has teeth is
        # that a longer prompt reports MORE tokens, and that total = prompt +
        # completion holds at both lengths.
        u_short = post(url + "/v1/chat/completions",
                       {"messages": [{"role": "user", "content": "hello"}],
                        "max_tokens": 4})["usage"]
        u_long = post(url + "/v1/chat/completions",
                      {"messages": [{"role": "user", "content":
                                     "a considerably longer prompt with a good "
                                     "many more words in it than the first"}],
                       "max_tokens": 2})["usage"]
        for nm, u in (("short", u_short), ("long", u_long)):
            if u["prompt_tokens"] <= 0:
                fails += 1
                print(f"  FAIL: usage.prompt_tokens is {u['prompt_tokens']} on "
                      f"the {nm} prompt; the seam arm is not counting it")
            elif u["total_tokens"] != u["prompt_tokens"] + u["completion_tokens"]:
                fails += 1
                print(f"  FAIL: usage on the {nm} prompt does not add up: {u}")
        if not (fails) and u_long["prompt_tokens"] <= u_short["prompt_tokens"]:
            fails += 1
            print(f"  FAIL: the longer prompt reports "
                  f"{u_long['prompt_tokens']} tokens, not more than the "
                  f"shorter one's {u_short['prompt_tokens']} -- this is a "
                  f"constant, not a count")
        elif not fails:
            print(f"  ok   usage.prompt_tokens counts: {u_short['prompt_tokens']}"
                  f" for the short prompt, {u_long['prompt_tokens']} for the "
                  f"long one, and total = prompt + completion at both")

        # And the refusal path, which no other test drives through HTTP.
        try:
            post(url + "/v1/chat/completions",
                 {"messages": [{"role": "tool", "content": "x"},
                               {"role": "user", "content": "q"}], "max_tokens": 1})
            fails += 1
            print("  FAIL: the tool role was accepted over HTTP")
        except urllib.error.HTTPError as e:
            body = json.loads(e.read().decode())
            if e.code == 400 and "tool" in body["error"]["message"]:
                print(f"  ok   refusal: {e.code} {body['error']['message']}")
            else:
                fails += 1
                print(f"  FAIL: wrong refusal {e.code} {body}")

        print(f"\nSERVER_E2E {'FAIL' if fails else 'PASS'} ({fails} failed)")
        return 1 if fails else 0
    finally:
        if proc:
            proc.terminate()
            proc.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
