#!/usr/bin/env python3
"""A deterministic prompt of exactly N token ids, for the context-length tests.

    ctx_prompt.py --qtk build_artifacts_tok/qwen35_9b.qtk --n 65535 --out ids.txt

Real text, not random ids: the corpus is this repository's own `docs/**/*.md`,
sorted by path and concatenated (repeated if it runs short), encoded with the
verified Qwen3.5 BPE (`tools/qwen35_tokenizer.py`, bit-exact against llama.cpp)
with special-token parsing OFF, so no control token appears mid-prompt.  One
id per line, the format `run_prompt --prompt` reads.

Deterministic for a given tree: the same N from the same commit gives the same
file, which is what lets two runs of a context test be compared id for id.
Prints the corpus digest so a later run can tell whether the corpus moved.
"""
import argparse
import glob
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from qwen35_tokenizer import Qwen35Tokenizer  # noqa: E402


def corpus():
    paths = sorted(glob.glob(os.path.join(REPO, "docs", "**", "*.md"), recursive=True))
    if not paths:
        sys.exit("ctx_prompt: no docs/**/*.md to build a corpus from")
    parts = []
    for p in paths:
        with open(p, "rb") as f:
            parts.append(f.read().decode("utf-8", errors="replace"))
    return paths, "\n\n".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--qtk", required=True)
    ap.add_argument("--n", type=int, required=True, help="exact number of ids")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    if a.n < 1:
        sys.exit("ctx_prompt: --n must be >= 1")
    tk = Qwen35Tokenizer(a.qtk)
    paths, text = corpus()
    dig = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
    ids = []
    # Encode per document chunk so one huge string is never handed to the
    # BPE at once; the cut points are paragraph boundaries, so this is the
    # same tokenization a whole-text encode gives for text that does not
    # span them (and it is deterministic either way).
    chunks = text.split("\n\n")
    rounds = 0
    while len(ids) < a.n:
        for c in chunks:
            ids.extend(tk.encode(c + "\n\n", parse_special=False))
            if len(ids) >= a.n:
                break
        rounds += 1
        if rounds > 64:
            sys.exit("ctx_prompt: corpus too small for %d ids" % a.n)
    ids = ids[:a.n]
    with open(a.out, "w") as f:
        f.write("".join("%d\n" % i for i in ids))
    print("CTX_PROMPT %d ids -> %s (corpus %d docs, sha256 %s, %d pass(es))"
          % (len(ids), a.out, len(paths), dig, rounds))


if __name__ == "__main__":
    main()
