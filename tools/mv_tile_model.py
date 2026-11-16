#!/usr/bin/env python3
"""tools/mv_tile_model.py -- the subsystem A arithmetic model the 450 MHz tile is checked against.

WHY THIS EXISTS.  docs/superpowers/specs/2026-11-12-a450-per-port-tiles-design.md 3.1 names
the oracle for rtl/mv_tile.vhd: an INDEPENDENT implementation of the A arithmetic, not the
RTL's own structure.  This file is that implementation.  It shares no code with the RTL and
none with ref/matvec_int4.c: its only import is tools/gen_arith.py, the authority that the C
reference and rtl/mv4i_arith_pkg.vhd are both GENERATED from.

    tools/mv_tile_model.py --selftest     the model against ref/matvec_int4.c --trace, three
                                          traces, plus a negative control that must DIFFER
    tools/mv_tile_model.py --write        write sim/mv_tile_vec.txt
    tools/mv_tile_model.py --check        regenerate in memory and compare with the file

Sentinels (line-anchored): ^MV_TILE_MODEL_SELFTEST_OK, ^MV_TILE_MODEL_SELFTEST_FAIL,
^MV_TILE_VEC_WROTE, ^MV_TILE_VEC_CHECK OK|STALE.

THE CONTRACT MODELLED (spec 2026-08-20 7.4, as rtl/matvec_core.vhd implements it):
  partial = sum_j cb[idx] * x_j over one 32-column block (pad columns contribute 0); the
            C reference asserts |partial| < 2^27 (s28), and so does this model
  contrib = floor_shr(partial * scale, 15)          scale is the 16-bit field, MSB 0
  acc     = sum over blocks of contrib              s48
  raw     = sat32(round_shift(acc, out_shift))      modes 00 and 01
  sat     = raw != round_shift(acc, out_shift)      modes 00 and 01 only, EVERY row of every
            issued row-tile, pad rows included (matvec_core re2 loops rr over all ROWS_IF)
  partial mode 10 emits acc unrounded and never saturates
  BFP (00): ns = max(0, msb_pos(max |raw| over rows < n_rows) - 14),
            mant = sat16(round_shift(raw, ns)), y_exp = w_exp + x_exp - out_shift - ns
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from gen_arith import floor_shr, round_shift, sat16, sat32, msb_pos_u  # noqa: E402

BLK = 32
VEC = os.path.join(REPO, "sim", "mv_tile_vec.txt")
SEED = 20261112


def block_partial(cb, idx_blk, x_blk):
    """One row, one block: idx_blk and x_blk are BLK ints each (pad columns already 0)."""
    p = 0
    for j in range(BLK):
        p += cb[idx_blk[j]] * x_blk[j]
    assert -(1 << 27) < p < (1 << 27), "partial %d leaves s28: outside the C contract" % p
    return p


def row_acc(cb, idx_row, scale_row, xpad):
    """idx_row: NB*BLK nibbles, scale_row: NB scales, xpad: NB*BLK x values, pad zeroed."""
    acc = 0
    for b in range(len(scale_row)):
        p = block_partial(cb, idx_row[b * BLK:(b + 1) * BLK], xpad[b * BLK:(b + 1) * BLK])
        c = floor_shr(p * scale_row[b], 15)
        assert -(1 << 28) <= c < (1 << 28), "contrib leaves s29"
        acc += c
    assert -(1 << 47) <= acc < (1 << 47), "acc leaves s48"
    return acc


def row_out(acc, out_shift, mode):
    """(value the tile emits, sat bit).  mode: 0 BFP, 1 raw, 2 partial."""
    if mode == 2:
        return acc, 0
    r = round_shift(acc, out_shift)
    a = sat32(r)
    return a, int(a != r)


def matvec(cb, idx, scale, x, n_rows, n_cols, out_shift, mode, w_exp, x_exp, rows_if):
    """Whole-matrix model.  idx/scale are given for ceil(n_rows/rows_if)*rows_if rows (pad
    rows included, as the hardware reads them).  Returns dict(y, y_exp, sat, acc, ns)."""
    nb = (n_cols + BLK - 1) // BLK
    xpad = [x[k] if k < n_cols else 0 for k in range(nb * BLK)]
    acc = [row_acc(cb, idx[r], scale[r], xpad) for r in range(len(idx))]
    outs = [row_out(a, out_shift, mode) for a in acc]
    sat = int(any(s for (_, s) in outs))
    if mode == 2:
        return {"y": acc[:n_rows], "y_exp": w_exp + x_exp, "sat": sat, "acc": acc, "ns": None}
    raw = [v for (v, _) in outs]
    if mode == 1:
        return {"y": raw[:n_rows], "y_exp": w_exp + x_exp - out_shift, "sat": sat,
                "acc": acc, "ns": None}
    amax = max(abs(v) for v in raw[:n_rows])
    ns = max(0, msb_pos_u(amax) - 14)
    mant = [sat16(round_shift(v, ns)) for v in raw[:n_rows]]
    return {"y": mant, "y_exp": w_exp + x_exp - out_shift - ns, "sat": sat, "acc": acc,
            "ns": ns, "raw": raw}


# --------------------------------------------------------------------------- selftest
def parse_trace(path):
    t = {"cb": [0] * 16, "x": {}, "scale": {}, "idx": {}, "acc": {}, "ydata": {}, "ymant": {}}
    for ln in open(path):
        f = ln.split()
        if not f or f[0].startswith("#"):
            continue
        k = f[0]
        if k == "DIMS":
            t["M"], t["K"], t["NB"], t["os"], t["w_exp"], t["x_exp"], t["RI"] = map(int, f[1:8])
        elif k == "CB":
            t["cb"][int(f[1])] = int(f[2])
        elif k == "X":
            v = int(f[2], 16)
            t["x"][int(f[1])] = v - 65536 if v >= 32768 else v
        elif k == "SCALE":
            t["scale"][(int(f[1]), int(f[2]))] = int(f[3], 16)
        elif k == "IDX":
            t["idx"][(int(f[1]), int(f[2]))] = int(f[3])
        elif k in ("ACC", "YDATA", "YMANT"):
            v = int(f[2], 16)
            t[k.lower()][int(f[1])] = v - (1 << 64) if v >= (1 << 63) else v
        elif k == "NS":
            t["ns"] = int(f[1])
        elif k == "YEXP":
            t["yexp"] = int(f[1])
    return t


def check_trace(t, perturb=False):
    M, K, NB = t["M"], t["K"], t["NB"]
    idx = [[t["idx"].get((r, k), 0) for k in range(NB * BLK)] for r in range(M)]
    scale = [[t["scale"][(r, b)] for b in range(NB)] for r in range(M)]
    if perturb:
        scale[0][0] ^= 1
    x = [t["x"][k] for k in range(K)]
    m = matvec(t["cb"], idx, scale, x, M, K, t["os"], 0, t["w_exp"], t["x_exp"], t["RI"])
    bad = 0
    for r in range(M):
        bad += m["acc"][r] != t["acc"][r]
        bad += m["raw"][r] != t["ydata"][r]
        bad += m["y"][r] != t["ymant"][r]
    bad += m["ns"] != t["ns"]
    bad += m["y_exp"] != t["yexp"]
    return bad


def selftest(work):
    os.makedirs(work, exist_ok=True)
    exe = os.path.join(work, "mv4i_ref")
    subprocess.run(["cc", "-O2", "-w", "-I", os.path.join(REPO, "ref"), "-o", exe,
                    os.path.join(REPO, "ref", "matvec_int4.c"), "-lm"], check=True)
    n = 0
    for argv in (["8", "96", "4", "0"], ["8", "1024", "4", "1"], ["50", "200", "48", "0"]):
        tr = os.path.join(work, "tr_%s.txt" % "_".join(argv))
        subprocess.run([exe, "--trace", tr] + argv, check=True, stdout=subprocess.DEVNULL)
        t = parse_trace(tr)
        bad = check_trace(t)
        if bad:
            print("MV_TILE_MODEL_SELFTEST_FAIL trace %s: %d fields differ" % (" ".join(argv), bad))
            return 1
        if check_trace(t, perturb=True) == 0:
            print("MV_TILE_MODEL_SELFTEST_FAIL trace %s: a perturbed scale still agrees "
                  "(the comparison has no teeth)" % " ".join(argv))
            return 1
        n += 1
    print("MV_TILE_MODEL_SELFTEST_OK %d traces agree with ref/matvec_int4.c, perturbation detected"
          % n)
    return 0


# --------------------------------------------------------------------------- vectors
def hexs(v, bits):
    return format(v & ((1 << bits) - 1), "0%dX" % (bits // 4))


def gen_case(rng, cid, os_, mode, nb, ntiles, kind):
    """One tile case: 2 rows per row-tile.  Returns the vector-file lines."""
    if kind == "sat":
        cb = [-127] + [rng.randint(-127, 127) for _ in range(15)]
    else:
        cb = [rng.randint(-127, 127) for _ in range(16)]
    n_cols = nb * BLK - (rng.randint(0, BLK - 1) if kind == "pad" else 0)
    out = ["CASE %d %d %d %d %d" % (cid, os_, mode, nb, ntiles),
           "CB " + " ".join(str(c) for c in cb)]
    res = []
    for t in range(ntiles):
        if kind == "sat":
            x = [-32768] * (nb * BLK)
        else:
            x = [rng.randint(-32768, 32767) for _ in range(nb * BLK)]
        xpad = [x[k] if k < n_cols else 0 for k in range(nb * BLK)]
        idx = [[0 if kind == "sat" else rng.randint(0, 15) for _ in range(nb * BLK)]
               for _ in range(2)]
        if kind == "sat":
            sc = [[32767] * nb for _ in range(2)]
        elif kind == "zscale":
            sc = [[0] * nb, [rng.randint(0, 32767) for _ in range(nb)]]
        else:
            sc = [[rng.randint(0, 32767) for _ in range(nb)] for _ in range(2)]
        for b in range(nb):
            w = 0
            for r in range(2):
                for j in range(BLK):
                    w |= idx[r][b * BLK + j] << (4 * (r * BLK + j))
            xw = 0
            for j in range(BLK):
                xw |= (xpad[b * BLK + j] & 0xFFFF) << (16 * j)
            s = sc[0][b] | (sc[1][b] << 16)
            out.append("B %d %d %s %s %s %d %d" % (t, b, hexs(w, 256), hexs(xw, 512), hexs(s, 32),
                                                  int(b == 0), int(b == nb - 1)))
        vals = []
        sat = 0
        for r in range(2):
            a = row_acc(cb, idx[r], sc[r], xpad)
            v, s = row_out(a, os_, mode)
            vals.append(v)
            sat |= s
        res.append("R %d %s %s %d" % (t, hexs(vals[0], 48), hexs(vals[1], 48), sat))
    return out + res + ["END"]


def gen_vectors():
    rng = random.Random(SEED)
    lines = ["# GENERATED by tools/mv_tile_model.py --write -- DO NOT EDIT",
             "# CASE id out_shift mode nb ntiles / CB 16 ints / B t b w256 x512 s32 first last /",
             "# R t v0 v1 sat (v = 48-bit two's complement the tile emits) / END"]
    cases = []
    for os_ in (0, 1, 3, 15, 31, 40):
        for mode in (0, 1, 2):
            cases.append((os_, mode, rng.randint(1, 6), rng.randint(1, 4), "rand"))
    for mode in (0, 1, 2):
        cases.append((0, mode, 40, 2, "sat"))
    cases.append((7, 1, 5, 3, "pad"))
    cases.append((7, 0, 5, 3, "pad"))
    cases.append((9, 1, 3, 2, "zscale"))
    cases.append((12, 1, 160, 1, "rand"))
    cases.append((5, 2, 1, 6, "rand"))
    for cid, (os_, mode, nb, nt, kind) in enumerate(cases):
        lines += gen_case(rng, cid, os_, mode, nb, nt, kind)
    lines.append("DONE %d" % len(cases))
    return "\n".join(lines) + "\n"


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest(os.environ.get("MV_TILE_WORK", "/mnt/storage/fk33_builds/scratch/mv_tile_model"))
    if argv[1:] == ["--write"]:
        txt = gen_vectors()
        open(VEC, "w").write(txt)
        print("MV_TILE_VEC_WROTE %s %d lines" % (VEC, txt.count("\n")))
        return 0
    if argv[1:] == ["--check"]:
        ok = os.path.exists(VEC) and open(VEC).read() == gen_vectors()
        print("MV_TILE_VEC_CHECK %s" % ("OK" if ok else "STALE"))
        return 0 if ok else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
