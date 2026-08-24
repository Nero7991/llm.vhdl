#!/usr/bin/env python3
"""Build an agentic-software-development corpus for KL-divergence evaluation.

WHY NOT wikitext.  Everything measured so far used wikitext-2, which is
Wikipedia prose.  The deployment target is agentic coding: source files, tool
calls, diffs, shell output, and the model's own reasoning between them.  A
quantization change can be nearly free on prose and expensive on code, because
code has far more low-entropy structure (identifiers, syntax, exact literals)
where a single wrong top-1 token breaks the output.  Measuring on the wrong
domain is the most likely way for this whole evaluation to mislead.

TWO PARTS, deliberately mixed rather than measured separately:
  * real dsh session transcripts -- tool calls, agent reasoning, command output.
    This is the actual token distribution the FPGA will serve.
  * repository source -- VHDL, C, Python, Tcl, shell. Dense code, the part
    where top-1 agreement matters most.

The transcripts are the user's own local sessions and never leave this machine.
Only human/assistant text and tool payloads are extracted; ids, timestamps and
sequence numbers are dropped, since they are high-entropy noise that would
dilute the measurement without representing anything the model must get right.
"""
import glob
import json
import os
import random
import subprocess
import sys

OUT = "/mnt/storage/ppl-data/corpus/agentic_code.txt"
TARGET_BYTES = 400_000          # ~100k tokens at ~4 chars/token; we cap chunks later


def from_sessions():
    out = []
    for f in glob.glob(os.path.expanduser(
            "~/.dsh/sessions/*/session-*/session.jsonl.zstd")):
        try:
            raw = subprocess.run(["zstd", "-dc", f], capture_output=True,
                                 timeout=120).stdout.decode("utf-8", "replace")
        except Exception:
            continue
        for line in raw.splitlines():
            try:
                ev = json.loads(line)
            except Exception:
                continue
            # Walk the event and pull out any free text.  Structure varies by
            # event type and dsh is a preview release, so this is deliberately
            # duck-typed rather than schema-bound.
            def walk(o, depth=0):
                if depth > 6:
                    return
                if isinstance(o, str):
                    if len(o) >= 40:
                        out.append(o)
                elif isinstance(o, dict):
                    for k, v in o.items():
                        if k in ("id", "seq", "time", "createdAt", "sessionId"):
                            continue
                        walk(v, depth + 1)
                elif isinstance(o, list):
                    for v in o:
                        walk(v, depth + 1)
            walk(ev.get("data"))
    return out


EXT = (".vhd", ".c", ".h", ".py", ".tcl", ".sh", ".md")


def from_repo():
    out = []
    for root, dirs, files in os.walk(os.path.expanduser("~/GitHub/llama.vhdl")):
        dirs[:] = [d for d in dirs
                   if d not in (".git", "build_artifacts", "mem", "ooc_micro")
                   and not d.startswith("build_artifacts")]
        for fn in files:
            if fn.endswith(EXT):
                p = os.path.join(root, fn)
                try:
                    if os.path.getsize(p) > 400_000:
                        continue
                    out.append(open(p, encoding="utf-8", errors="replace").read())
                except Exception:
                    pass
    return out


sess = from_sessions()
repo = from_repo()
print(f"session fragments: {len(sess)}  ({sum(map(len, sess))/1e6:.2f} MB)")
print(f"repo files:        {len(repo)}  ({sum(map(len, repo))/1e6:.2f} MB)")
if not sess:
    print("WARNING: no session transcripts extracted -- corpus is code only, "
          "which under-represents tool-call and reasoning tokens")

# Interleave so neither half dominates any contiguous region: chunks are scored
# in file order, so a corpus of "all transcripts then all code" would make the
# per-chunk numbers a function of position rather than of content.
rng = random.Random(1234)
rng.shuffle(sess)
rng.shuffle(repo)

buf, n = [], 0
si = ri = 0
while n < TARGET_BYTES and (si < len(sess) or ri < len(repo)):
    for src, idx in (("s", si), ("r", ri)):
        pool = sess if src == "s" else repo
        if idx >= len(pool):
            continue
        piece = pool[idx]
        buf.append(piece)
        n += len(piece)
        if src == "s":
            si += 1
        else:
            ri += 1
        if n >= TARGET_BYTES:
            break

text = "\n\n".join(buf)
open(OUT, "w", encoding="utf-8").write(text)
print(f"wrote {OUT}  ({len(text)/1e6:.2f} MB, ~{len(text)//4} tokens est)")
