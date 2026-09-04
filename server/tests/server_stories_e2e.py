#!/usr/bin/env python3
"""The stories260K OpenAI surface: usage accounting and prompt echo.

WHY THIS EXISTS.  server/tests/server_e2e.py checks the QWEN35 path -- the
chat template, the tokenizer, prefill against a simulated card.  Nothing
checked the DEFAULT path, the one `./server/llama_server` serves and the one
that does REAL fixed-point inference, and two OpenAI-compatibility defects sat
in it:

  1. `usage.prompt_tokens` was the literal 0 in both response builders, so
     `total_tokens` equalled `completion_tokens` and no client could see the
     prompt cost at all.
  2. /v1/completions ECHOED THE PROMPT unconditionally.  ref/run_fx.c's
     generate_stream calls on_piece for the teacher-forced prompt positions as
     well as the sampled ones -- correct for llama2.c's CLI, wrong for this
     API -- so the prompt came back prepended to the completion, every echoed
     piece counted as a completion token, and max_tokens was spent on them.
     `max_tokens: 8` on a 3-token prompt returned 5 new tokens.

Both were invisible to every existing test because both produce a well-formed
200 response with plausible-looking text.

THE LOAD-BEARING CHECK IS C5, not the echo checks.  Suppressing an echo is the
kind of change that can quietly alter what the model is asked to do.  C5 pins
that it did not: the `echo=true` text must be exactly the prompt-echo followed
by the same continuation the default request returns, so the two requests
agree token for token and the fix is presentational.  If a future change makes
the server re-tokenize, re-prompt or re-seed, C5 fails and the echo checks do
not.

    python3 server/tests/server_stories_e2e.py            # starts its own server
    python3 server/tests/server_stories_e2e.py --url http://127.0.0.1:8010
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(HERE)
ROOT = os.path.dirname(SERVER_DIR)

PROMPT = "Once upon a time there was a little girl"
NTOK = 24

fails = []


def check(tag, cond, detail):
    print("  %-4s %s   %s" % ("ok" if cond else "FAIL", tag, detail))
    if not cond:
        fails.append("%s: %s" % (tag, detail))


def post(url, path, payload, stream=False):
    req = urllib.request.Request(
        url + path, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        body = r.read().decode()
    if not stream:
        return json.loads(body)
    out = []
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("data: ") and line != "data: [DONE]":
            out.append(json.loads(line[6:]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url")
    args = ap.parse_args()

    proc = None
    url = args.url
    if not url:
        exe = os.path.join(SERVER_DIR, "llama_server")
        if not os.path.exists(exe):
            print("SERVER_STORIES VOID: %s does not exist (run `make -C server`)"
                  % exe)
            return 1
        port = 8123
        url = "http://127.0.0.1:%d" % port
        proc = subprocess.Popen([exe, "--port", str(port)], cwd=ROOT,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        for _ in range(80):
            time.sleep(0.25)
            try:
                urllib.request.urlopen(url + "/v1/models", timeout=2).read()
                break
            except Exception:
                if proc.poll() is not None:
                    print("SERVER_STORIES VOID: the server exited during startup")
                    return 1
        else:
            proc.kill()
            print("SERVER_STORIES VOID: the server never became ready")
            return 1

    try:
        # --- the default completion ------------------------------------------
        d = post(url, "/v1/completions",
                 {"model": "stories260k", "prompt": PROMPT,
                  "max_tokens": NTOK, "temperature": 0})
        u = d["usage"]
        text = d["choices"][0]["text"]

        check("C1", u["prompt_tokens"] > 0,
              "usage.prompt_tokens = %d (was hardcoded 0)" % u["prompt_tokens"])
        check("C2", u["total_tokens"] == u["prompt_tokens"] + u["completion_tokens"],
              "total %d == prompt %d + completion %d"
              % (u["total_tokens"], u["prompt_tokens"], u["completion_tokens"]))
        # C3 is INSENSITIVE to the defect and is kept as a shape check only.
        # MEASURED against the pre-fix server: it PASSES there.  The old code
        # counted echo pieces in `generated` and stopped at max_tokens, so
        # completion_tokens was exactly NTOK in both versions -- what differed
        # was how many of those were real.  Do not read a C3 pass as evidence
        # about echo; C4, C5 and C11 are what discriminate.
        check("C3", u["completion_tokens"] == NTOK,
              "completion_tokens = %d == max_tokens %d (SHAPE ONLY: this "
              "passes on the pre-fix server too)"
              % (u["completion_tokens"], NTOK))
        check("C4", not text.startswith(PROMPT),
              "the default completion does not echo the prompt: %r" % text[:40])

        # --- echo=true --------------------------------------------------------
        e = post(url, "/v1/completions",
                 {"model": "stories260k", "prompt": PROMPT,
                  "max_tokens": NTOK, "temperature": 0, "echo": True})
        etext = e["choices"][0]["text"]
        eu = e["usage"]

        check("C5", etext.endswith(text) and etext != text,
              "THE INVARIANT: echo=true is the prompt echo followed by the "
              "SAME continuation, so suppressing the echo changed presentation "
              "and not the token stream (%d chars of echo)"
              % (len(etext) - len(text)))
        check("C6", eu["completion_tokens"] == u["completion_tokens"],
              "echo does not change completion_tokens (%d == %d); OpenAI counts "
              "echoed prompt under prompt_tokens"
              % (eu["completion_tokens"], u["completion_tokens"]))

        # --- chat never echoes ------------------------------------------------
        c = post(url, "/v1/chat/completions",
                 {"model": "stories260k",
                  "messages": [{"role": "user", "content": "Lily had a cat."}],
                  "max_tokens": 12, "temperature": 0})
        ctext = c["choices"][0]["message"]["content"]
        check("C7", "Lily had a cat." not in ctext,
              "chat has no `echo` in the API and must never echo: %r"
              % ctext[:40])
        check("C8", c["usage"]["prompt_tokens"] > 0,
              "chat usage.prompt_tokens = %d" % c["usage"]["prompt_tokens"])

        # --- streaming --------------------------------------------------------
        chunks = post(url, "/v1/completions",
                      {"model": "stories260k", "prompt": "The dog",
                       "max_tokens": 4, "temperature": 0, "stream": True},
                      stream=True)
        content = [k for k in chunks
                   if k["choices"][0].get("finish_reason") is None]
        # C9 is also INSENSITIVE, for the same reason as C3, and MEASURED to
        # pass on the pre-fix server: the old code emitted echo pieces as
        # chunks but still stopped at max_tokens, so the COUNT was 4 either
        # way.  C11 below is the streaming check with teeth.
        check("C9", len(content) == 4,
              "a stream of max_tokens=4 carries exactly 4 content chunks, got "
              "%d (SHAPE ONLY: passes on the pre-fix server too)"
              % len(content))
        joined = "".join(k["choices"][0]["text"] for k in content)
        check("C11", not joined.startswith("The dog"),
              "the STREAM does not lead with the prompt either: %r. C9 counts "
              "chunks and cannot see this; the pre-fix server streamed 'The', "
              "' do', 'g' before any generated token" % joined)
        check("C10", chunks and chunks[-1]["choices"][0].get("finish_reason"),
              "the last chunk carries a finish_reason (%r)"
              % (chunks[-1]["choices"][0].get("finish_reason") if chunks else None))
    finally:
        if proc:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except Exception:
                proc.kill()

    if fails:
        for f in fails:
            print("FAILED " + f)
        print("SERVER_STORIES FAIL (%d failed)" % len(fails))
        return 1
    print("SERVER_STORIES PASS (0 failed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
