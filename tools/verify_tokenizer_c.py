#!/usr/bin/env python3
"""Check the C tokenizer (server/qwen35_tok.c) against llama.cpp, bit for bit.

THE ORACLE IS llama.cpp, NOT tools/qwen35_tokenizer.py.  The Python is a second
opinion; it has its own bugs (this run found one -- see --all-ids below), and
checking C against Python would only prove the two agree.  Both processes here
speak the same length-prefixed binary protocol and neither knows the other
exists:

    tools/tok_oracle_batch.cpp   -> llama_tokenize / llama_detokenize
    tools/tokenizer_c_batch.c    -> qwen35_tok_encode / qwen35_tok_decode

Four checks, in increasing strength:

  1. --corpus   (default) the SAME corpus tools/verify_tokenizer.py builds,
                imported from it so the two runs are comparable, in both
                directions.  Decode is compared on the ORACLE'S ids, never on
                ours: feeding our own ids to our own decoder would let a
                compensating pair of encode/decode bugs pass.
  2. --all-ids  every token id in the vocabulary, decoded one at a time.  The
                corpus can only reach ids its own text produces; this reaches
                all 248,320, and it is what caught the UNUSED-token divergence.
  3. --sweep-codepoints  every codepoint in U+0000..U+10FFFF minus surrogates,
                in two contexts.  The pre-tokenizer's decisions are per-codepoint
                category decisions, so they can be enumerated rather than
                sampled.  This is the check that would catch a Unicode table
                built from the wrong UCD.
  4. --fuzz-bytes  random byte strings that are NOT valid UTF-8.  The Python
                harness could not express these (it carried Python str); this
                one carries raw bytes end to end.

--mutate NAME breaks the C on purpose and expects the comparison to FAIL.  The
mutations live in server/qwen35_tok.c behind -DQWEN35_TOK_MUTATE and are
DIFFERENT from the Python's: two of those are documented as structurally
unobservable and would prove nothing here.

    verify_tokenizer_c.py --build --qtk build_artifacts_tok/qwen35_9b.qtk \\
        --gguf /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
"""

import argparse
import os
import random
import struct
import subprocess
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from verify_tokenizer import build_corpus                       # noqa: E402

MUTATIONS = ("merge-rank", "byte-map", "drop-special", "mark-flag", "ws-table",
             "decode-bytemap", "decode-unused")


# ----------------------------------------------------------------- processes

def _pack_texts(items):
    p = bytearray(struct.pack("<I", len(items)))
    for b in items:
        p += struct.pack("<I", len(b)) + b
    return p


def _pack_ids(id_lists):
    p = bytearray(struct.pack("<I", len(id_lists)))
    for ids in id_lists:
        p += struct.pack("<I", len(ids))
        if ids:
            p += struct.pack(f"<{len(ids)}i", *ids)
    return p


def _unpack(buf, n_texts, n_ids):
    pos = 0
    enc = []
    for _ in range(n_texts):
        k = struct.unpack_from("<I", buf, pos)[0]; pos += 4
        enc.append(list(struct.unpack_from(f"<{k}i", buf, pos)) if k else [])
        pos += 4 * k
    det = None
    if n_ids is not None:
        det = []
        for _ in range(n_ids):
            m = struct.unpack_from("<I", buf, pos)[0]; pos += 4
            det.append(bytes(buf[pos:pos + m])); pos += m
    return enc, det


def run_batch(argv, texts, id_lists=None):
    """texts is a list of BYTES.  Returns (encodings, detokenizations)."""
    args = list(argv)
    if id_lists is not None:
        args.append("--detok")
    payload = _pack_texts(texts)
    if id_lists is not None:
        payload += _pack_ids(id_lists)
    p = subprocess.run(args, input=bytes(payload), stdout=subprocess.PIPE)
    if p.returncode != 0:
        raise SystemExit(f"{args[0]} exited {p.returncode}")
    return _unpack(p.stdout, len(texts), None if id_lists is None else len(id_lists))


def oracle_argv(a):
    return [a.oracle, a.gguf]


def ctok_argv(a):
    v = [a.ctok, a.qtk]
    if a.mutate:
        v += ["--mutate", a.mutate]
    return v


# --------------------------------------------------------------------- build

def build(a):
    cmd = ["cc", "-O2", "-std=c99", "-Wall", "-Wextra", "-DQWEN35_TOK_MUTATE",
           os.path.join(ROOT, "tools", "tokenizer_c_batch.c"),
           os.path.join(ROOT, "server", "qwen35_tok.c"),
           os.path.join(ROOT, "server", "qwen35_unicode_data.c"),
           "-I" + os.path.join(ROOT, "server"), "-o", a.ctok]
    print("+ " + " ".join(cmd))
    subprocess.run(cmd, check=True)


# -------------------------------------------------------------------- checks

def show(b, n=90):
    r = repr(b)
    return r if len(r) <= n else r[:n - 3] + "..."


def check_corpus(a):
    corpus = [s.encode("utf-8") for s in build_corpus(a.seed, a.n_random, ROOT)]
    print(f"corpus            : {len(corpus)} strings, {sum(len(b) for b in corpus)} UTF-8 bytes")

    theirs, _ = run_batch(oracle_argv(a), corpus)
    mine, _ = run_batch(ctok_argv(a), corpus)
    enc_bad = [i for i in range(len(corpus)) if mine[i] != theirs[i]]
    print(f"encode compared   : {len(corpus)}")
    print(f"encode mismatches : {len(enc_bad)}")
    for i in enc_bad[:a.max_report]:
        print(f"  [{i}] text={show(corpus[i])}")
        print(f"       ours  ={mine[i][:40]}")
        print(f"       oracle={theirs[i][:40]}")
    if len(enc_bad) > a.max_report:
        print(f"  ... {len(enc_bad) - a.max_report} more")

    dec_bad = []
    if not a.no_detok:
        # pass 2 runs on the ORACLE's ids, deliberately.  See the module docstring.
        _, det_o = run_batch(oracle_argv(a), corpus, id_lists=theirs)
        _, det_c = run_batch(ctok_argv(a), corpus, id_lists=theirs)
        dec_bad = [i for i in range(len(corpus)) if det_c[i] != det_o[i]]
        print(f"decode compared   : {len(corpus)}")
        print(f"decode mismatches : {len(dec_bad)}")
        for i in dec_bad[:a.max_report]:
            print(f"  [{i}] ids={theirs[i][:20]}")
            print(f"       ours  ={show(det_c[i])}")
            print(f"       oracle={show(det_o[i])}")

    bad = len(enc_bad) + len(dec_bad)
    print(f"\nRESULT: {'PASS' if bad == 0 else 'FAIL'} ({bad} mismatch"
          f"{'' if bad == 1 else 'es'} over {len(corpus)} strings x "
          f"{'2' if not a.no_detok else '1'} directions)")
    return 0 if bad == 0 else 1


def check_all_ids(a):
    """Decode every single token id and compare.

    The corpus only ever reaches ids that some corpus string encodes to.  The
    tail of this vocabulary (243 [PADnnnnnn] tokens, token_type 5 = UNUSED) is
    unreachable that way, and a sampler CAN emit those ids.  Enumerating the
    vocabulary is cheap and is strictly stronger.
    """
    n = a.n_vocab
    ids = [[i] for i in range(n)]
    _, det_o = run_batch(oracle_argv(a), [], id_lists=ids)
    _, det_c = run_batch(ctok_argv(a), [], id_lists=ids)
    bad = [i for i in range(n) if det_c[i] != det_o[i]]
    print(f"token ids compared: {n}")
    print(f"mismatches        : {len(bad)}")
    for i in bad[:a.max_report]:
        print(f"  id {i}  ours={show(det_c[i], 60)}  oracle={show(det_o[i], 60)}")
    if len(bad) > a.max_report:
        print(f"  ... {len(bad) - a.max_report} more")
    print(f"\nRESULT: {'PASS' if not bad else 'FAIL'}")
    return 0 if not bad else 1


def check_sweep(a):
    cps = [c for c in range(0x110000) if not (0xD800 <= c <= 0xDFFF)]
    ctxs = ("a{}b", " {}1")
    bad = []
    CH = 200000
    for s in range(0, len(cps), CH):
        chunk = cps[s:s + CH]
        texts, meta = [], []
        for cp in chunk:
            c = chr(cp)
            for f in ctxs:
                texts.append(f.format(c).encode("utf-8"))
                meta.append(cp)
        theirs, _ = run_batch(oracle_argv(a), texts)
        mine, _ = run_batch(ctok_argv(a), texts)
        for i in range(len(texts)):
            if mine[i] != theirs[i]:
                bad.append(meta[i])
        print(f"  ..{s + len(chunk)}/{len(cps)} divergent so far: {len(set(bad))}", flush=True)

    bad = sorted(set(bad))
    print(f"\ncodepoints swept  : {len(cps)}  (x{len(ctxs)} contexts = {len(cps) * len(ctxs)} strings)")
    print(f"divergent         : {len(bad)}")
    for cp in bad[:a.max_report]:
        try:
            nm = unicodedata.name(chr(cp))
        except ValueError:
            nm = "<unnamed>"
        print(f"   U+{cp:04X} cat={unicodedata.category(chr(cp))} {nm}")
    if len(bad) > a.max_report:
        print(f"   ... {len(bad) - a.max_report} more")
    print(f"\nRESULT: {'PASS' if not bad else 'FAIL'}")
    return 0 if not bad else 1


def check_fuzz_bytes(a):
    """Random byte strings, most of them not valid UTF-8.

    llama.cpp accepts arbitrary bytes: unicode_cpts_from_utf8 substitutes
    U+FFFD and advances one byte.  The Python verification protocol carried
    Python str and so could never express this; this one carries bytes.

    Lead bytes 0xF0..0xFF are excluded from the random pool.  llama.cpp's
    unicode_cpt_from_utf8 masks the lead byte with 0x07 and applies no upper
    bound, so e.g. the four bytes F4 BF BF BF decode to U+13FFFF; the very next
    thing llama.cpp does is call unicode_cpt_to_utf8 on it, which THROWS
    std::invalid_argument, and nothing on the path catches it.  The oracle
    process aborts (SIGABRT) rather than answering, so there is nothing to
    compare against.  That is a real llama.cpp defect on malformed input, not a
    gap we chose; see the write-up.  Truncated real sequences below still
    exercise the 4-byte lead path.
    """
    rng = random.Random(a.seed)
    pool = list(range(0x00, 0xF0))
    texts = []
    for _ in range(a.n_fuzz):
        k = rng.randrange(0, 24)
        texts.append(bytes(rng.choice(pool) for _ in range(k)))
    # plus hand-built truncations of real multi-byte sequences
    for s in ("你好", "é", "\U0001F600", "क्ष"):
        b = s.encode("utf-8")
        for i in range(1, len(b)):
            texts.append(b[:i])
            texts.append(b[i:])
            texts.append(b"a" + b[:i] + b"b")
    theirs, _ = run_batch(oracle_argv(a), texts)
    mine, _ = run_batch(ctok_argv(a), texts)
    bad = [i for i in range(len(texts)) if mine[i] != theirs[i]]
    print(f"byte strings      : {len(texts)}")
    print(f"mismatches        : {len(bad)}")
    for i in bad[:a.max_report]:
        print(f"  [{i}] bytes={show(texts[i])}")
        print(f"       ours  ={mine[i][:30]}")
        print(f"       oracle={theirs[i][:30]}")
    print(f"\nRESULT: {'PASS' if not bad else 'FAIL'}")
    return 0 if not bad else 1


# ---------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--qtk", default="build_artifacts_tok/qwen35_9b.qtk")
    ap.add_argument("--gguf", default="/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf")
    ap.add_argument("--oracle", default="build_artifacts_tok/tok_oracle_batch")
    ap.add_argument("--ctok", default="build_artifacts_tok/tokenizer_c_batch")
    ap.add_argument("--build", action="store_true", help="compile the C driver first")
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--n-random", type=int, default=1500)
    ap.add_argument("--n-fuzz", type=int, default=20000)
    ap.add_argument("--n-vocab", type=int, default=248320)
    ap.add_argument("--mutate", choices=MUTATIONS,
                    help="break the C on purpose; the run is expected to FAIL")
    ap.add_argument("--max-report", type=int, default=12)
    ap.add_argument("--no-detok", action="store_true")
    ap.add_argument("--all-ids", action="store_true")
    ap.add_argument("--sweep-codepoints", action="store_true")
    ap.add_argument("--fuzz-bytes", action="store_true")
    a = ap.parse_args()

    if a.build:
        build(a)
    if a.mutate:
        print(f"MUTATION REQUESTED: {a.mutate}  (the C prints what it broke on stderr)")

    if a.all_ids:
        return check_all_ids(a)
    if a.sweep_codepoints:
        return check_sweep(a)
    if a.fuzz_bytes:
        return check_fuzz_bytes(a)
    return check_corpus(a)


if __name__ == "__main__":
    sys.exit(main())
