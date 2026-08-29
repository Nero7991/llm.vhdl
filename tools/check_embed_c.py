#!/usr/bin/env python3
"""tools/check_embed_c.py -- check `server/embed_mv4i.c` against three things it
did not write, and measure what each of those three can actually see.

WHAT IS BEING CHECKED, AND WHY NONE OF IT IS A ROUND TRIP
--------------------------------------------------------
`server/embed_mv4i.c` gathers one embedding row out of a packed `.mv4i` as TWO
CONTIGUOUS READS and BFP-packs it.  Comparing it to itself would prove nothing:
CLAUDE.md records `m7`, a packer plus a reversed decoder that passed an entire
self-test suite while both were wrong.  So it is compared against:

  A  ref/matvec_int4.c's `get_widx`/`get_scale`, wrapped by
     server/tests/embed_ref_oracle.c, which reproduces `ref/run9b.c`'s own
     `embed()` + `reg_put()`.  DIFFERENT LANGUAGE FEATURES, DIFFERENT SHAPE:
     that addressing is per-element and recomputes the sub-region and the beat
     for every weight.  This is the strongest of the three, because run9b IS the
     whole-model 9B reference, so agreeing with it means agreeing with the
     activation the rest of the pipeline was verified against, not merely with
     another decoder.  Compared BIT-EXACT on mantissas and exponent.

  B  tools/embed_gather.py's `direct` AND `reassemble` decoders, in Python and
     numpy.  `reassemble` rebuilds the whole tile word from all 24 weight
     sub-regions and the whole superword from all 3 scale sub-regions, so it
     shares no addressing arithmetic with anything else here.  Compared
     BIT-EXACT on mantissas, exponent and the pre-pack integer row.

  C  the BF16 rows of `Qwen3.5-9B-BF16.gguf`, which never touch the packed file
     at all.  Cannot be bit-exact (the pack is lossy by construction), so it is
     gated on the relative-error and correlation band that
     `tools/embed_gather.py --separation` MEASURED rather than chose.

The token set is `embed_gather.sample_tokens`, which forces row 0, row M-1, the
rows either side of every tile / beat-half / scale-sub-region boundary, and the
first row of the PARTIAL last tile, then fills with a seeded spread.  Coverage
of the input space is not coverage of the output space, and random sampling
reaches none of those corners reliably.

`--mutate` runs the table: thirteen named defects compiled into the C under
-DEMBED_MV4I_MUTANTS, each reported with WHICH checks fired.  A mutant that
fires nothing is not hidden; it is printed under its own name, because that is
the measurement of where the checks stop.

NO HARDWARE.  Everything here opens ordinary files read-only.

Usage:
    tools/check_embed_c.py --mv4i F.mv4i [--dump BIN] [--ref-oracle BIN]
                           [--gguf G] [--n 64] [--mutate] [--build DIR]
"""

import argparse
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import embed_gather as eg                                       # noqa: E402
from gen_mv4i_desc import DescError                             # noqa: E402

DEFAULT_MV4I = "/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i"
DEFAULT_GGUF = "/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf"


# ------------------------------------------------------------------- building
def build(outdir):
    """Compile both C binaries.  The dump gets -DEMBED_MV4I_MUTANTS; the oracle
    does not and cannot, because it does not include the provider at all."""
    os.makedirs(outdir, exist_ok=True)
    dump = os.path.join(outdir, "embed_dump")
    orac = os.path.join(outdir, "embed_ref_oracle")
    cc = os.environ.get("CC", "gcc")
    cmds = [
        [cc, "-O2", "-std=c99", "-Wall", "-Wextra", "-DEMBED_MV4I_MUTANTS",
         "-o", dump,
         os.path.join(ROOT, "server/tests/embed_dump.c"),
         os.path.join(ROOT, "server/embed_mv4i.c")],
        [cc, "-O2", "-std=c99", "-Wall", "-Wextra", "-o", orac,
         os.path.join(ROOT, "server/tests/embed_ref_oracle.c"), "-lm"],
    ]
    for c in cmds:
        r = subprocess.run(c, capture_output=True, text=True)
        if r.returncode:
            sys.stderr.write(r.stdout + r.stderr)
            raise SystemExit("check_embed_c: build failed: %s" % " ".join(c))
        if r.stderr.strip():
            sys.stderr.write("(build warnings)\n" + r.stderr)
    return dump, orac


# ------------------------------------------------------------------- running
def run_dump(dump, mv4i, toks, recipe="wide", mutant=0, vals=False):
    """-> {tok: dict(exp=, mant=np.int32[], vals=np.int64[]|None, addr=(...))}"""
    cmd = [dump, "--mv4i", mv4i, "--recipe", recipe,
           "--tokens", ",".join(str(t) for t in toks)]
    if mutant:
        cmd += ["--mutant", str(mutant)]
    if vals:
        cmd += ["--vals"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("check_embed_c: embed_dump exited %d" % r.returncode)
    out, cur = {}, None
    for line in r.stdout.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "TOK":
            cur = dict(tok=int(f[1]), exp=int(f[3]), val_exp=int(f[5]),
                       amax=int(f[7]),
                       addr=tuple(int(x) for x in f[9:15]),
                       woff=int(f[15]), soff=int(f[16]), nbytes=int(f[17]),
                       mant=None, vals=None)
            out[cur["tok"]] = cur
        elif f[0] == "MANT":
            cur["mant"] = np.array([int(x) for x in f[1:]], dtype=np.int64)
        elif f[0] == "VALS":
            cur["vals"] = np.array([int(x) for x in f[1:]], dtype=np.int64)
    return out


def run_ref_oracle(orac, mv4i, toks):
    """-> {tok: (exp, np.int64[])} from ref/matvec_int4.c's own accessors."""
    r = subprocess.run([orac, "--mv4i", mv4i,
                        "--tokens", ",".join(str(t) for t in toks)],
                       capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("check_embed_c: embed_ref_oracle exited %d" % r.returncode)
    out, tok, exp = {}, None, None
    for line in r.stdout.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "TOK":
            tok, exp = int(f[1]), int(f[3])
        elif f[0] == "MANT":
            out[tok] = (exp, np.array([int(x) for x in f[1:]], dtype=np.int64))
    return out


# ------------------------------------------------------------------ checking
def compare(pt, cres, ref, gguf_ref, toks, recipe, verbose=True):
    """Every check, counted.  Returns a dict; nothing here shares code with the
    C being checked."""
    r = dict(n=0, vs_ref_exp=0, vs_ref_mant=0,
             vs_py_direct_exp=0, vs_py_direct_mant=0,
             vs_py_reasm_exp=0, vs_py_reasm_mant=0,
             vs_py_rowint=0, addr_bad=0,
             gguf_checked=0, gguf_bad=0, gguf_worst=0.0, corr_worst=1.0,
             zero_rows=0)
    rec = eg.RECIPE_WIDE if recipe == "wide" else eg.RECIPE_D32
    for tok in toks:
        c = cres.get(tok)
        if c is None:
            r["addr_bad"] += 1
            continue
        r["n"] += 1

        # --- A: ref/matvec_int4.c via run9b's own embed() + reg_put()
        if ref is not None and tok in ref:
            rexp, rmant = ref[tok]
            if rexp != c["exp"]:
                r["vs_ref_exp"] += 1
            elif not np.array_equal(rmant, c["mant"]):
                r["vs_ref_mant"] += 1

        # --- B: tools/embed_gather.py, both decoders, bit-exact
        for dec, ke, km in (("direct", "vs_py_direct_exp", "vs_py_direct_mant"),
                            ("reassemble", "vs_py_reasm_exp", "vs_py_reasm_mant")):
            m, xe = pt.row_bfp(tok, dec, rec)
            if xe != c["exp"]:
                r[ke] += 1
            elif not np.array_equal(np.asarray(m, dtype=np.int64), c["mant"]):
                r[km] += 1
        if c["vals"] is not None:
            v, ve = pt.row_int(tok, "direct", rec)
            if ve != c["val_exp"] or not np.array_equal(
                    np.asarray(v, dtype=np.int64), c["vals"]):
                r["vs_py_rowint"] += 1

        # --- the addressing the C reports, against the Python's own
        t, rr = divmod(tok, pt.h.rows_if)
        want = (t, rr, rr // pt.rows_per_beat, rr % pt.rows_per_beat,
                rr // pt.scales_per_beat, rr % pt.scales_per_beat)
        if c["addr"] != want:
            r["addr_bad"] += 1

        # --- C: the BF16 GGUF, which never touches the packed file
        if gguf_ref is not None:
            exact = gguf_ref[tok]
            got = eg.bfp_to_float(c["mant"], c["exp"])
            if float(np.linalg.norm(exact)) == 0.0 or np.std(got) == 0:
                r["zero_rows"] += 1
                continue
            e = eg.relerr(got, exact)
            cc = float(np.corrcoef(got, exact)[0, 1])
            r["gguf_checked"] += 1
            r["gguf_worst"] = max(r["gguf_worst"], e)
            r["corr_worst"] = min(r["corr_worst"], cc)
            if e > eg.RELERR_MAX or cc < eg.CORR_MIN:
                r["gguf_bad"] += 1
                if verbose:
                    print("  token %d: relerr %.4f corr %.4f outside the gate"
                          % (tok, e, cc))
    return r


BITEXACT_KEYS = ("vs_ref_exp", "vs_ref_mant",
                 "vs_py_direct_exp", "vs_py_direct_mant",
                 "vs_py_reasm_exp", "vs_py_reasm_mant",
                 "vs_py_rowint", "addr_bad")


def fired(r, gate_gguf):
    out = []
    if r["vs_ref_exp"] or r["vs_ref_mant"]:
        out.append("ref/matvec_int4 %d exp + %d mant of %d"
                   % (r["vs_ref_exp"], r["vs_ref_mant"], r["n"]))
    if r["vs_py_direct_exp"] or r["vs_py_direct_mant"]:
        out.append("embed_gather direct %d exp + %d mant"
                   % (r["vs_py_direct_exp"], r["vs_py_direct_mant"]))
    if r["vs_py_reasm_exp"] or r["vs_py_reasm_mant"]:
        out.append("embed_gather reassemble %d exp + %d mant"
                   % (r["vs_py_reasm_exp"], r["vs_py_reasm_mant"]))
    if r["vs_py_rowint"]:
        out.append("pre-pack integer row %d" % r["vs_py_rowint"])
    if r["addr_bad"]:
        out.append("reported addressing %d" % r["addr_bad"])
    if r["gguf_bad"] and gate_gguf:
        out.append("gguf %d/%d worst relerr %.3f corr %.3f"
                   % (r["gguf_bad"], r["gguf_checked"],
                      r["gguf_worst"], r["corr_worst"]))
    elif r["gguf_bad"]:
        out.append("gguf %d/%d (ADVISORY for this recipe)"
                   % (r["gguf_bad"], r["gguf_checked"]))
    return out


# --------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mv4i", default=DEFAULT_MV4I)
    ap.add_argument("--gguf", default=DEFAULT_GGUF)
    ap.add_argument("--tensor", default=None)
    ap.add_argument("--dump", default=None)
    ap.add_argument("--ref-oracle", default=None)
    ap.add_argument("--build", default=None,
                    help="build both binaries into this directory first")
    ap.add_argument("--recipe", choices=("wide", "d32"), default="wide")
    ap.add_argument("--n", type=int, default=64)
    ap.add_argument("--tokens", default=None,
                    help="explicit comma list instead of the corner sample")
    ap.add_argument("--mutate", action="store_true")
    ap.add_argument("--no-gguf", action="store_true")
    ap.add_argument("--no-ref", action="store_true",
                    help="skip the ref/matvec_int4 oracle (it mmaps the file)")
    a = ap.parse_args(argv)

    if a.build:
        a.dump, a.ref_oracle = build(a.build)
    if not a.dump:
        ap.error("--dump BIN or --build DIR is required")

    pt = eg.PackedTensor(a.mv4i)
    tensor = a.tensor or os.path.basename(a.mv4i)[:-len(".mv4i")]
    toks = ([int(x) for x in a.tokens.split(",")] if a.tokens
            else eg.sample_tokens(pt.h.M, a.n))
    toks = sorted(set(toks))

    gguf = None if a.no_gguf else a.gguf
    if gguf and not os.path.exists(gguf):
        sys.stderr.write("gguf %s not present; the external oracle is SKIPPED, "
                         "and this run therefore checks decoders against "
                         "decoders only\n" % gguf)
        gguf = None
    gguf_ref = eg.gguf_rows(gguf, tensor, toks) if gguf else None

    ref = None
    if not a.no_ref and a.ref_oracle:
        ref = run_ref_oracle(a.ref_oracle, a.mv4i, toks)

    gate = eg.GATEABLE.get(eg.RECIPE_WIDE if a.recipe == "wide"
                           else eg.RECIPE_D32, False)

    print("mv4i     %s" % a.mv4i)
    print("geometry M=%d K=%d ROWS_IF=%d AXI_DW=%d nb=%d w_exp=%d GRP=%d"
          % (pt.h.M, pt.h.K, pt.h.rows_if, pt.h.axi_dw, pt.nb, pt.h.w_exp,
             pt.h.grp))
    print("tokens   %d, corner-forced%s" % (len(toks), "" if not a.tokens else " (explicit)"))
    print("oracles  ref/matvec_int4=%s  embed_gather=yes  gguf=%s"
          % ("yes" if ref else "NO", "yes" if gguf_ref is not None else "NO"))
    print("recipe   %s" % a.recipe)

    if a.mutate:
        cres = run_dump(a.dump, a.mv4i, toks, a.recipe, 0, vals=True)
        clean = compare(pt, cres, ref, gguf_ref, toks, a.recipe, verbose=False)
        ok = all(clean[k] == 0 for k in BITEXACT_KEYS) and \
             (clean["gguf_bad"] == 0 or not gate)
        print()
        print("mutation table -- a row is KILLED if some check refuses it")
        print("%-44s %-8s %s" % ("mutant", "verdict", "what fired"))
        print("%-44s %-8s %s" % ("c0 clean (control)", "PASS" if ok else "FAIL",
                                 "must PASS or the table means nothing"))
        killed = 0
        names = subprocess.run([a.dump, "--list-mutants"],
                               capture_output=True, text=True).stdout.splitlines()
        nmap = {int(l.split()[0]): l.split(" ", 1)[1] for l in names if l.strip()}
        for m in sorted(k for k in nmap if k != 0):
            mres = run_dump(a.dump, a.mv4i, toks, a.recipe, m, vals=True)
            rr = compare(pt, mres, ref, gguf_ref, toks, a.recipe, verbose=False)
            f = fired(rr, gate)
            if f:
                killed += 1
            print("%-44s %-8s %s" % (nmap[m], "KILLED" if f else "SILENT",
                                     ", ".join(f) or
                                     "NOTHING -- this is the resolution floor"))
        print("killed %d of %d" % (killed, len(nmap) - 1))
        return 0 if (ok and killed == len(nmap) - 1) else 1

    cres = run_dump(a.dump, a.mv4i, toks, a.recipe, 0, vals=True)
    r = compare(pt, cres, ref, gguf_ref, toks, a.recipe)
    print()
    print("tokens compared                     %d" % r["n"])
    if ref:
        print("vs ref/matvec_int4 (run9b embed)    %d exp, %d mant mismatches"
              % (r["vs_ref_exp"], r["vs_ref_mant"]))
    print("vs embed_gather direct              %d exp, %d mant mismatches"
          % (r["vs_py_direct_exp"], r["vs_py_direct_mant"]))
    print("vs embed_gather reassemble          %d exp, %d mant mismatches"
          % (r["vs_py_reasm_exp"], r["vs_py_reasm_mant"]))
    print("vs embed_gather pre-pack integers   %d mismatches" % r["vs_py_rowint"])
    print("reported addressing disagreements   %d" % r["addr_bad"])
    if gguf_ref is not None:
        print("checked against the BF16 GGUF       %d (%d zero rows skipped)"
              % (r["gguf_checked"], r["zero_rows"]))
        print("worst relative error                %.5f" % r["gguf_worst"])
        print("worst correlation                   %.5f" % r["corr_worst"])
        print("rows the GGUF gate rejects          %d%s"
              % (r["gguf_bad"], "" if gate else "  (ADVISORY for this recipe)"))
    ok = all(r[k] == 0 for k in BITEXACT_KEYS) and \
         (r["gguf_bad"] == 0 or not gate) and r["n"] == len(toks)
    print("CHECK %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DescError as e:
        sys.stderr.write("check_embed_c: %s\n" % e)
        sys.exit(2)
