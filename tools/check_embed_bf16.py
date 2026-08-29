#!/usr/bin/env python3
"""Check the C BF16 embedding gather against implementations nobody here wrote.

WHAT IS BEING CHECKED, AND AGAINST WHAT
---------------------------------------
`ref/embed_bf16.c` walks a GGUF header and `pread`s one row; `server/embed_bf16.c`
BFP-packs it.  A round trip through that reader would prove nothing (CLAUDE.md's
`m7`: a packer plus a reversed decoder passed an entire self-test suite while
both were wrong).  So every check here compares against something else:

  CHK-A  gguf-py's GGUFReader              a parser this project did not write,
                                           reading the SAME file.  Bit-exact.
  CHK-B  llama.cpp's own embedding rows    `model.input_embed` inside a rung-1
                                           anchor stream.  This is the strong
                                           one: a different loader, a different
                                           language, and a code path that shares
                                           nothing with either of the above.
                                           Bit-exact.
  CHK-C  ref/run9b.c's own R_X.embed seam  the whole-model reference's packed
                                           row, out of its unmodified `reg_put`.
                                           Bit-exact on mantissa AND exponent.
                                           This is what makes "the host ships
                                           what the reference evaluated" a
                                           measurement rather than a claim.
  CHK-D  the header geometry               ne0, ne1 and the absolute offset of
                                           row 0, against gguf-py's own numbers.
  CHK-E  neighbour separation              row t against the GGUF's row t+1, the
                                           smallest possible addressing error.

CHK-D and CHK-E are STRUCTURAL and are reported as such: neither can see a pack
defect, and CHK-D cannot see any value defect at all.  The mutation table below
names, for every mutant, which checks fired and which did not, because a check
never shown to fail has not been shown to work.

usage:
    tools/check_embed_bf16.py --gguf G --dump ./embed_bf16_dump [--n 64]
        [--anchor /mnt/storage/ref9b/anchor_f32.r9bs --anchor-tokens 760,...]
        [--ref-stream ref_bfp_gguf.r9bs]
        [--compare-mv4i FILE --mv4i-dump ./embed_dump]  # INT4 vs BF16 head to head
        [--mutate]
"""
import argparse
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "ref9b"))

import embed_gather                                        # noqa: E402


# ------------------------------------------------------------------- tokens
def sample_tokens(n_vocab, ne0, row0, n):
    """Corner-forced, not random.

    Coverage of the input space is not coverage of the output space, so the
    corners are FORCED and only the remainder is a seeded spread:

      * row 0 and row n_vocab-1
      * the rows either side of the first row whose absolute byte offset passes
        2^31.  A 32-bit off_t would break there and nowhere else, and this
        tensor genuinely crosses it (row0 + 248319*8192 = 4.08e9).
      * the rows either side of a 4 KiB page boundary landing mid-row
      * powers of two, which is where an index computed in the wrong width goes
    """
    row_b = ne0 * 2
    out = [0, n_vocab - 1]
    r2g = (2 ** 31 - row0 + row_b - 1) // row_b
    for r in (r2g - 1, r2g, r2g + 1):
        if 0 <= r < n_vocab:
            out.append(int(r))
    p = 4096
    r = (p - (row0 % p)) // 2          # first row whose start is page-aligned-ish
    for d in (-1, 0, 1):
        if 0 <= r + d < n_vocab:
            out.append(int(r + d))
    b = 1
    while b < n_vocab:
        out.append(b)
        b *= 2
    out = sorted(set(x for x in out if 0 <= x < n_vocab))
    if len(out) < n:
        rng = np.random.default_rng(20260829)
        extra = rng.integers(0, n_vocab, size=n * 2)
        for x in extra:
            if len(out) >= n:
                break
            if int(x) not in out:
                out.append(int(x))
        out = sorted(set(out))
    return out[:max(n, len(out))] if n >= len(out) else out[:n]


# --------------------------------------------------------------- the C side
def run_dump(dump, gguf, toks, mutant=0, tensor=None):
    """{tok: (exp, mant ndarray, vals ndarray)} plus the INFO line."""
    cmd = [dump, "--gguf", gguf, "--tokens", ",".join(str(t) for t in toks),
           "--vals"]
    if tensor:
        cmd += ["--tensor", tensor]
    if mutant:
        cmd += ["--mutant", str(mutant)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("%s failed rc=%d\n%s" % (dump, p.returncode, p.stderr))
    rows, info, shape = {}, "", (0, 0)
    tok = None
    for line in p.stdout.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "INFO":
            info = line[5:]
        elif f[0] == "SHAPE":
            shape = (int(f[2]), int(f[4]))
        elif f[0] == "TOK":
            tok = int(f[1])
            rows[tok] = {"exp": int(f[3])}
        elif f[0] == "MANT":
            rows[tok]["mant"] = np.array([int(x) for x in f[1:]], dtype=np.int64)
        elif f[0] == "VALS":
            rows[tok]["vals"] = np.array([float(x) for x in f[1:]],
                                         dtype=np.float64)
    return rows, info, shape


def bfp_pack_np(v):
    """ref/run9b.c reg_put, in numpy, for the ADVISORY re-derivation only.

    NOT used as an oracle for the shipped pack -- it is written here, so it
    would be a round trip.  The oracle for the pack is CHK-C, the reference's
    own R_X.embed seam."""
    amax = float(np.max(np.abs(v)))
    if amax == 0:
        return 0, np.zeros(len(v), dtype=np.int64)
    ex = 14 - int(np.floor(np.log2(amax)))
    q = np.floor(np.ldexp(v, ex) + 0.5)
    return ex, np.clip(q, -32768, 32767).astype(np.int64)


def relerr(a, b):
    n = float(np.linalg.norm(a - b))
    d = float(np.linalg.norm(b))
    return n / d if d else (0.0 if n == 0 else float("inf"))


# ------------------------------------------------------------------ checks
def do_checks(a, quiet=False):
    """Returns a dict of per-check failure counts.  Every count is a NUMBER of
    rows, so a mutation table can print which check fired and how hard."""
    r = dict(n=0, a_bad=0, b_bad=0, b_n=0, c_bad=0, c_n=0, d_bad=0,
             e_worst_matched=0.0, e_best_mismatched=float("inf"),
             worst_relerr_vs_gguf=0.0, a_nonfinite=0)

    toks = a["toks"]
    crows, info, shape = run_dump(a["dump"], a["gguf"], toks, a.get("mutant", 0),
                                 a.get("tensor"))
    r["info"] = info
    r["n"] = len(toks)

    # ---- CHK-A: gguf-py, bit-exact
    ref = embed_gather.gguf_rows(a["gguf"], a["tensor"] or "token_embd.weight",
                                 toks)
    for t in toks:
        c = crows[t]["vals"]
        g = ref[t]
        if not np.array_equal(c, g):
            r["a_bad"] += 1
        # TRAP, hit on mutant m4: a row read at a mis-derived offset can decode
        # to NaN, and then relerr is NaN, and `max(0.0, nan)` is 0.0 in Python.
        # A relative error printed as 0 on a row that is entirely NaN reads as
        # "no error at all".  Count the non-finite rows separately and say so.
        e = relerr(c, g)
        if np.isfinite(e):
            r["worst_relerr_vs_gguf"] = max(r["worst_relerr_vs_gguf"], e)
        else:
            r["a_nonfinite"] += 1

    # ---- CHK-D: geometry, against gguf-py's own numbers
    want_ne0, want_ne1, want_off = a["geom"]
    got = {}
    for kv in info.split():
        if "=" in kv:
            k, v = kv.split("=", 1)
            got[k] = v
    if (int(got.get("ne0", -1)) != want_ne0 or int(got.get("ne1", -1)) != want_ne1
            or int(got.get("row0", "0x0"), 16) != want_off
            or shape != (want_ne1, want_ne0)):
        r["d_bad"] = 1

    # ---- CHK-B: llama.cpp's own embedding rows
    if a.get("anchor_rows"):
        for p, (t, arow) in enumerate(a["anchor_rows"]):
            if t not in crows:
                continue
            r["b_n"] += 1
            if not np.array_equal(crows[t]["vals"], arow):
                r["b_bad"] += 1

    # ---- CHK-C: ref/run9b.c's own packed seam
    if a.get("ref_seam"):
        for t, (rexp, rmant) in a["ref_seam"].items():
            if t not in crows:
                continue
            r["c_n"] += 1
            if crows[t]["exp"] != rexp or not np.array_equal(crows[t]["mant"],
                                                             rmant):
                r["c_bad"] += 1

    # ---- CHK-E: neighbour separation
    nb = [t for t in toks if t + 1 < want_ne1]
    if nb:
        refn = embed_gather.gguf_rows(a["gguf"],
                                      a["tensor"] or "token_embd.weight",
                                      [t + 1 for t in nb])
        m, s = [], []
        for t in nb:
            g = ref[t]
            if np.linalg.norm(g) == 0:
                continue
            m.append(relerr(crows[t]["vals"], g))
            s.append(relerr(crows[t]["vals"], refn[t + 1]))
        if m:
            r["e_worst_matched"] = max(m)
            r["e_best_mismatched"] = min(s)

    if not quiet:
        pass
    return r


# ------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gguf", default="/mnt/storage/llama-models/qwen35-9b/"
                                      "Qwen3.5-9B-BF16.gguf")
    ap.add_argument("--tensor", default=None)
    ap.add_argument("--dump", default="./embed_bf16_dump")
    ap.add_argument("--n", type=int, default=64)
    ap.add_argument("--anchor", default=None,
                    help="a rung-1 .r9bs; its model.input_embed records are "
                         "llama.cpp's OWN embedding rows")
    ap.add_argument("--anchor-tokens", default="760,6511,314,9338,369",
                    help="the token ids the anchor stream was produced with, "
                         "in stream order")
    ap.add_argument("--ref-stream", default=None,
                    help="a run9b --embed gguf .r9bs; its R_X.embed records are "
                         "the reference's OWN packed rows")
    ap.add_argument("--ref-tokens", default="760,6511,314,9338,369")
    ap.add_argument("--compare-mv4i", default=None,
                    help="a packed token_embd.weight.mv4i; adds the head-to-head "
                         "accuracy comparison of the two copies at the ACTIVATION")
    ap.add_argument("--mv4i-dump", default="./embed_dump")
    ap.add_argument("--mutate", action="store_true")
    a = ap.parse_args()

    if not os.path.exists(a.gguf):
        print("SKIP: %s is not present" % a.gguf)
        return 0

    tensor = a.tensor or "token_embd.weight"

    # geometry from gguf-py, so CHK-D compares against a foreign parser
    for p in ("/mnt/storage/llama-dflash2-src/gguf-py",
              os.path.expanduser("~/GitHub/llama.cpp.upstream/gguf-py")):
        if os.path.isdir(p) and p not in sys.path:
            sys.path.insert(0, p)
    from gguf.gguf_reader import GGUFReader
    rd = GGUFReader(a.gguf, "r")
    t = next(x for x in rd.tensors if x.name == tensor)
    ne0, ne1 = int(t.shape[0]), int(t.shape[1])
    row0 = int(t.data_offset)

    toks = sample_tokens(ne1, ne0, row0, a.n)

    anchor_rows = []
    if a.anchor and os.path.exists(a.anchor):
        import r9bs
        idx = r9bs.index(a.anchor, want={"model.input_embed"})
        at = [int(x) for x in a.anchor_tokens.split(",")]
        for p, tok in enumerate(at):
            if ("model.input_embed", p) in idx:
                anchor_rows.append((tok, idx[("model.input_embed", p)].value))
        for tok, _ in anchor_rows:
            if tok not in toks:
                toks.append(tok)

    ref_seam = {}
    if a.ref_stream and os.path.exists(a.ref_stream):
        import r9bs
        idx = r9bs.index(a.ref_stream, want={"R_X.embed"})
        rt = [int(x) for x in a.ref_tokens.split(",")]
        for p, tok in enumerate(rt):
            if ("R_X.embed", p) in idx:
                rec = idx[("R_X.embed", p)]
                ref_seam[tok] = (int(rec.exp), rec.raw.astype(np.int64))
        for tok in ref_seam:
            if tok not in toks:
                toks.append(tok)

    toks = sorted(set(toks))

    args = dict(gguf=a.gguf, tensor=a.tensor, dump=a.dump, toks=toks,
                geom=(ne0, ne1, row0), anchor_rows=anchor_rows,
                ref_seam=ref_seam)

    print("gguf     %s" % a.gguf)
    print("tensor   %s  BF16 ne0=%d ne1=%d row0=0x%x  (gguf-py)"
          % (tensor, ne0, ne1, row0))
    print("tokens   %d, corner-forced" % len(toks))
    print("oracles  gguf-py=yes  anchor=%s  ref-stream=%s"
          % ("yes(%d)" % len(anchor_rows) if anchor_rows else "no",
             "yes(%d)" % len(ref_seam) if ref_seam else "no"))
    print()

    r = do_checks(args)
    print("CHK-D header geometry vs gguf-py     %s"
          % ("OK" if not r["d_bad"] else "MISMATCH"))
    print("CHK-A rows vs gguf-py                %d of %d differ (%d non-finite)"
          % (r["a_bad"], r["n"], r["a_nonfinite"]))
    print("CHK-B rows vs llama.cpp input_embed  %d of %d differ"
          % (r["b_bad"], r["b_n"]))
    print("CHK-C pack vs ref/run9b R_X.embed    %d of %d differ"
          % (r["c_bad"], r["c_n"]))
    print("CHK-E worst matched relerr           %.6g" % r["e_worst_matched"])
    print("      best  mismatched relerr        %.6g" % r["e_best_mismatched"])
    ok = (r["a_bad"] == 0 and r["b_bad"] == 0 and r["c_bad"] == 0
          and not r["d_bad"]
          and r["e_worst_matched"] < r["e_best_mismatched"])
    print()
    print("CHECK %s" % ("PASS" if ok else "FAIL"))

    if a.compare_mv4i and os.path.exists(a.compare_mv4i):
        print()
        print("the two copies at the ACTIVATION, both packed to int16 BFP by the")
        print("same rule, both scored against the SAME BF16 GGUF row")
        ct = [t for t in toks if t < ne1]
        p4 = subprocess.run([a.mv4i_dump, "--mv4i", a.compare_mv4i, "--tokens",
                             ",".join(str(t) for t in ct)],
                            capture_output=True, text=True)
        if p4.returncode != 0:
            print("  SKIP: %s failed rc=%d" % (a.mv4i_dump, p4.returncode))
        else:
            i4 = {}
            tokn = None
            for line in p4.stdout.splitlines():
                f = line.split()
                if not f:
                    continue
                if f[0] == "TOK":
                    tokn = int(f[1])
                    i4[tokn] = {"exp": int(f[3])}
                elif f[0] == "MANT":
                    i4[tokn]["mant"] = np.array([int(x) for x in f[1:]],
                                                dtype=np.int64)
            crows, _, _ = run_dump(a.dump, a.gguf, ct, 0, a.tensor)
            ref = embed_gather.gguf_rows(a.gguf, tensor, ct)
            e4, eb = [], []
            for t in ct:
                g = ref[t]
                if np.linalg.norm(g) == 0:
                    continue
                v4 = i4[t]["mant"].astype(np.float64) * 2.0 ** -i4[t]["exp"]
                vb = crows[t]["mant"].astype(np.float64) * 2.0 ** -crows[t]["exp"]
                e4.append(relerr(v4, g))
                eb.append(relerr(vb, g))
            print("  rows %d" % len(e4))
            print("  packed INT4 -> BFP int16   mean relerr %.6f  worst %.6f"
                  % (float(np.mean(e4)), float(np.max(e4))))
            print("  GGUF BF16   -> BFP int16   mean relerr %.6f  worst %.6f"
                  % (float(np.mean(eb)), float(np.max(eb))))
            print("  ratio INT4/BF16 mean = %.1fx"
                  % (float(np.mean(e4)) / float(np.mean(eb))))

    if not a.mutate:
        return 0 if ok else 1

    print()
    print("mutation table -- a row is KILLED if some check refuses it")
    print("%-46s %-8s %s" % ("mutant", "verdict", "what fired"))
    names = subprocess.run([a.dump, "--list-mutants"], capture_output=True,
                           text=True).stdout.splitlines()
    killed = total = 0
    for line in names:
        num, nm = line.split(" ", 1)
        num = int(num)
        args2 = dict(args)
        args2["mutant"] = num
        try:
            m = do_checks(args2, quiet=True)
        except RuntimeError as ex:
            print("%-46s %-8s %s" % ("m%d %s" % (num, nm), "KILLED",
                                     "the dump itself refused: %s"
                                     % str(ex).splitlines()[-1][:70]))
            killed += 1
            total += 1
            continue
        fired = []
        if m["d_bad"]:
            fired.append("CHK-D geometry")
        if m["a_bad"]:
            fired.append("CHK-A gguf-py %d/%d worst relerr %.4g%s"
                         % (m["a_bad"], m["n"], m["worst_relerr_vs_gguf"],
                            (" (+%d rows NON-FINITE)" % m["a_nonfinite"])
                            if m["a_nonfinite"] else ""))
        if m["b_bad"]:
            fired.append("CHK-B llama.cpp %d/%d" % (m["b_bad"], m["b_n"]))
        if m["c_bad"]:
            fired.append("CHK-C ref seam %d/%d" % (m["c_bad"], m["c_n"]))
        if m["e_worst_matched"] >= m["e_best_mismatched"]:
            fired.append("CHK-E separation lost (%.4g >= %.4g)"
                         % (m["e_worst_matched"], m["e_best_mismatched"]))
        if num == 0:
            v = "PASS" if not fired else "BROKEN"
            print("%-46s %-8s %s" % ("m0 %s" % nm, v,
                                     "must PASS or the table means nothing"))
            continue
        total += 1
        if fired:
            killed += 1
        print("%-46s %-8s %s" % ("m%d %s" % (num, nm),
                                 "KILLED" if fired else "SURVIVED",
                                 ", ".join(fired) if fired
                                 else "NOTHING FIRED -- see the write-up"))
    print("killed %d of %d" % (killed, total))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
