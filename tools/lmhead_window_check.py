#!/usr/bin/env python3
"""tools/lmhead_window_check.py -- drive tools/lmhead_window_oracle.c with the
DESCRIPTORS a real schedule emits, and mutate them until the check bites.

THE QUESTION IT ANSWERS.  `tools/gen_lmhead_windows.py` proves the window set
tiles `output.weight` -- rows and bytes.  It does not compute a single logit,
and `docs/2026-08-28_token-io-path.md` section 10 item 3 says so:

    "No lm_head result was ever computed.  The window set is proved to tile
     the tensor; nothing here shows that 15 jobs produce the same 248,320
     logits as one hypothetical job would."

This closes that.  The spec file handed to the C oracle contains, per window,
the 27 sub-region byte offsets taken VERBATIM out of the emitted descriptor's
`w_base`/`s_base` words (minus the tensor's HBM offset), plus `n_rows`.  So the
thing being judged is the descriptor, not a re-derivation of it: a base that is
well formed and aimed at the wrong bytes produces wrong logits here, and that
is the one defect class the byte-cover check structurally cannot see.

THE SOURCE OF THE WINDOWS.  They come out of `gen_layer_program.build_plan`,
i.e. out of the SHIPPING schedule, and `windows_from_plan` refuses to proceed
if the plan's steps do not carry the same list `lmhead_windows` produced.  So
this checks what the tool actually emits, not a second window list written for
the test.

WHAT IT CANNOT REACH.  Only rows and bases move here.  x is one deterministic
vector per seed, so a defect that needs a particular activation pattern is out
of reach; `--seeds` sweeps that as far as it goes.  And the judge is
`ref/matvec_int4.c`, not the RTL, so nothing here says the gateware agrees with
the reference -- that is `sim/tb_matvec_core`'s and `sim/tb_matvec_fk33*`'s job.

Usage:
    tools/lmhead_window_check.py --mv4i FILE.mv4i --x-exp 0
    tools/lmhead_window_check.py --mv4i FILE.mv4i --x-exp 0 --mode bfp
    tools/lmhead_window_check.py --mv4i FILE.mv4i --x-exp 0 --mutate
    tools/lmhead_window_check.py --mv4i SMALL.mv4i --x-exp 0 \\
        --maxrows-bfp 200 --mutate    # force many windows on a small tensor
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import gen_mv4i_desc as G                                    # noqa: E402
import gen_lmhead_windows as WIN                             # noqa: E402
import gen_layer_program as LP                               # noqa: E402

MODES = {"bfp": G.MODE_BFP, "raw": G.MODE_RAW, "partial": G.MODE_PARTIAL}


# ------------------------------------------------------------------- build
def cc_oracle(outdir):
    exe = os.path.join(outdir, "lmhead_window_oracle")
    src = os.path.join(HERE, "lmhead_window_oracle.c")
    cmd = ["cc", "-O2", "-Wall", "-Wextra", "-I", os.path.join(ROOT, "ref"),
           "-o", exe, src]
    subprocess.check_call(cmd)
    return exe


# ref/matvec_int4.c's `--emit` CANNOT be used to make a synthetic tensor here,
# and the reason is a finding rather than an inconvenience.  `pack_geom`
# (ref/matvec_int4.c:474-480) 4 KB-ALIGNS every sub-region (`align4k`), while
# `gen_mv4i_desc.sub_offsets_from_layout` encodes the TIGHT layout -- one
# sub-region immediately after the last -- as "the offsets spec 6.5a's layout
# implies".  Both are legal: the file names its own offsets in the 4 KB header
# and the reference reads them.  But `check_bases` compares the header table
# against the tight rule and refuses on any disagreement, so it refuses every
# C-packed file:
#
#   header w=[4096, 8192, 12288, ...]   layout w=[4096, 6784, 9472, ...]
#
# The tensors this tool is for were written by tools/pack_int4.py, which packs
# tight, so the check is exercised against real bytes instead.

# ------------------------------------------------------------------ windows
def windows_from_plan(M, build):
    """The windows the SHIPPING schedule emits, not a second list."""
    s = LP.Shape(blocks=1, attn_interval=99, hidden=64, ffn=128, key_heads=1,
                 val_heads=1, head_dim=8, attn_q_heads=1, attn_kv_heads=1,
                 attn_head_dim=8, vocab_shard=M)
    wins = LP.lmhead_windows(s, build)
    steps = LP.build_plan(s, lm_windows=wins)
    out = [(st.row_start, st.n_rows) for st in steps
           if st.tensor == "output.weight"]
    if out != wins:
        raise SystemExit("build_plan did not carry the window list through")
    return out


def descriptors(h, wins, x_exp, mode, hbm_base=0):
    return [G.build_descriptor(h, hbm_base, nr, x_exp, out_mode=mode,
                               cb_load=True, row_start=rs)
            for rs, nr in wins]


def write_spec(path, descs, x_exp, mode, seed, xamp, hbm_base=0, tweak=None):
    """The spec the C oracle reads.  Every offset comes out of the DESCRIPTOR's
    base words, so this file is the descriptor restated in the C's units."""
    lines = ["XEXP %d" % x_exp, "SEED %d" % seed, "XAMP %d" % xamp,
             "MODE %d" % mode, "NWIN %d" % len(descs)]
    for i, d in enumerate(descs):
        e0 = d.ext0
        npw = d.fields["nsub_w"]
        nps = d.fields["nsub_s"]
        n_rows = d.words[1] & 0xFFFFFFFF
        w = [d.words[G.DESC_BASE0 + p] - hbm_base for p in range(npw)]
        s = [d.words[G.DESC_BASE0 + npw + q] - hbm_base for q in range(nps)]
        rs = d.fields["row_start"]
        if tweak is not None:
            rs, n_rows, w, s = tweak(i, rs, n_rows, w, s)
        lines.append("WIN %d %d %d" % (i, rs, n_rows))
        for p, v in enumerate(w):
            lines.append("WOFF %d %d %d" % (i, p, v))
        for q, v in enumerate(s):
            lines.append("SOFF %d %d %d" % (i, q, v))
        assert e0  # the extension exists; unused here, the C reads no beats
    with open(path, "w") as fp:
        fp.write("\n".join(lines) + "\n")


def run(exe, mv4i, spec):
    p = subprocess.run([exe, mv4i, spec], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


# ---------------------------------------------------------------- mutations
def mutations(h, wins, build):
    """Each returns (name, tweak, why).  A tweak edits ONE window's row_start,
    n_rows or bases -- the fields a descriptor actually carries -- and the
    check must fail.  Ones that do NOT bite are reported under their own names
    because they measure the resolution floor."""
    ri = h.rows_if
    nb = h.nb
    pb = h.port_b
    tile_bytes = nb * pb                       # one tile's bytes per sub-region
    last = len(wins) - 1

    def m1(i, rs, nr, w, s):                   # one window's bases one tile high
        if i == 1:
            w = [v + tile_bytes for v in w]
            s = [v + tile_bytes for v in s]
        return rs, nr, w, s

    # MAXROWS_BFP ROUNDED UP to a tile instead of down.  gen_lmhead_windows'
    # own header names this as the dangerous form -- rounding to a tile
    # boundary without re-deriving the window COUNT -- and says it "is not
    # loud at all".  Rounding down is the correct rule; rounding up advances
    # every window's bases by (ceil-floor)/ROWS_IF tiles too far.
    def m2(i, rs, nr, w, s):
        mb = build["maxrows_bfp"]
        up = ((mb + ri - 1) // ri) * ri
        dn = (mb // ri) * ri
        dt = (up - dn) // ri                    # extra TILES per window
        if i > 0 and dt:
            w = [v + i * dt * tile_bytes for v in w]
            s = [v + i * dt * tile_bytes for v in s]
        return rs, nr, w, s

    def m3(i, rs, nr, w, s):                   # two windows' bases swapped
        return rs, nr, w, s                    # handled by the caller

    def m4(i, rs, nr, w, s):                   # ONE weight sub-region misaimed
        if i == 0 and len(w) > 7:
            w = list(w)
            w[7] = w[7] + tile_bytes
        return rs, nr, w, s

    def m5(i, rs, nr, w, s):                   # ONE scale sub-region misaimed
        if i == 0 and len(s) > 1:
            s = list(s)
            s[1] = s[1] + tile_bytes
        return rs, nr, w, s

    def m6(i, rs, nr, w, s):                   # last window rounded up a tile
        if i == last:
            nr = nr + ri
        return rs, nr, w, s

    def m7(i, rs, nr, w, s):                   # window 0 shortened one tile
        if i == 0:
            nr = nr - ri
        return rs, nr, w, s

    def m8(i, rs, nr, w, s):                   # weight sub-regions 0 and 1 swapped
        w = list(w)
        w[0], w[1] = w[1], w[0]
        return rs, nr, w, s

    def m9(i, rs, nr, w, s):                   # every base advanced ONE BEAT
        if i == 1:
            w = [v + pb for v in w]
            s = [v + pb for v in s]
        return rs, nr, w, s

    def m10(i, rs, nr, w, s):                  # windows issued DESCENDING
        return rs, nr, w, s                    # handled by the caller

    return [
        ("m1  window 1 bases one TILE high", m1,
         "the OI-3 family: a well-formed base at the wrong bytes"),
        ("m2  MAXROWS_BFP rounded UP to a tile", m2,
         "gen_lmhead_windows' header: the form that is NOT loud"),
        ("m3  windows 1 and 2 bases swapped", m3,
         "row cover still exact, bytes still cover, values transposed"),
        ("m4  ONE weight sub-region (7) misaimed", m4,
         "OI-1's case 19 at lm_head scale: only 2 of 48 rows per tile move"),
        ("m5  ONE scale sub-region (1) misaimed", m5,
         "the scale plane has its own bases and its own skip arithmetic"),
        ("m6  last window rounded up one tile", m6,
         "the 5,056-row remainder read as 5,104"),
        ("m7  window 0 short by one tile", m7,
         "48 rows never computed"),
        ("m8  weight sub-regions 0 and 1 swapped", m8,
         "a permuted base ARRAY, which check_bases only sees inside the file"),
        ("m9  window 1 bases one BEAT high", m9,
         "sub-tile misalignment, the smallest base error expressible"),
        ("m10 windows issued DESCENDING", m10,
         "NON-BITER by construction: every window carries its own row_start, "
         "so values are order-independent.  Issue order is a SAMPLER index "
         "property and no value check can ever see it; 706a2a4 measured it "
         "on rtl/sampler_stream.vhd directly"),
    ]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mv4i", default=None)
    ap.add_argument("--maxrows-bfp", type=int, default=None,
                    help="override the build's MAXROWS_BFP, so a small tensor "
                         "can be forced into many windows")
    ap.add_argument("--x-exp", type=int, default=0)
    ap.add_argument("--mode", choices=sorted(MODES), default="raw")
    ap.add_argument("--seed", type=int, default=20260829)
    ap.add_argument("--seeds", type=int, default=1)
    ap.add_argument("--xamp", type=int, default=8000)
    ap.add_argument("--mutate", action="store_true")
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args(argv)

    outdir = a.outdir or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                      "lmhead_window_check")
    if not os.path.isdir(outdir):
        os.makedirs(outdir)

    build = dict(G.FK33)
    if a.maxrows_bfp:
        build["maxrows_bfp"] = a.maxrows_bfp

    mv4i = a.mv4i
    if not mv4i:
        raise SystemExit("--mv4i is required")

    exe = cc_oracle(outdir)
    h = G.Mv4iHeader(mv4i)
    if h.rows_if != build["rows_if"]:
        build["rows_if"] = h.rows_if
    wins = windows_from_plan(h.M, build)
    mode = MODES[a.mode]

    print("tensor    %s" % mv4i)
    print("geometry  M=%d K=%d ROWS_IF=%d AXI_DW=%d nports_w=%d n_scale_sub=%d"
          % (h.M, h.K, h.rows_if, h.axi_dw, h.nports_w, h.n_scale_sub))
    print("windows   MAXROWS_BFP=%d stride=%d -> %d window%s"
          % (build["maxrows_bfp"],
             (build["maxrows_bfp"] // h.rows_if) * h.rows_if, len(wins),
             "" if len(wins) == 1 else "s"))
    print("mode      %s (%d)   x_exp=%d" % (a.mode, mode, a.x_exp))
    print()

    descs = descriptors(h, wins, a.x_exp, mode)
    bad = [n for d in descs for _, n in G.rtl_would_reject(d, build=build)]
    if bad:
        raise SystemExit("the gateware would refuse a window: %s" % bad[0])
    print("all %d descriptors pass rtl_would_reject at MAXROWS_BFP=%d"
          % (len(descs), build["maxrows_bfp"]))

    rc_all = 0
    for si in range(a.seeds):
        seed = a.seed + si
        spec = os.path.join(outdir, "spec_%d.txt" % seed)
        write_spec(spec, descs, a.x_exp, mode, seed, a.xamp)
        rc, txt = run(exe, mv4i, spec)
        print(txt.rstrip())
        rc_all |= rc
    if not a.mutate:
        return rc_all

    # ---------------------------------------------------------- the teeth
    print()
    print("MUTATIONS (the check must FAIL on every one; ones that do not are "
          "the resolution floor)")
    print("%-42s %-6s %s" % ("mutation", "verd", "why it was tried"))
    rows = []
    for name, tweak, why in mutations(h, wins, build):
        spec = os.path.join(outdir, "mut.txt")
        if name.startswith("m3"):
            if len(descs) < 3:
                rows.append((name, "N/A", why + " (needs 3 windows)"))
                continue
            d2 = list(descs)
            d2[1], d2[2] = d2[2], d2[1]
            # keep row_start/n_rows in place; only the BASES move
            def swap(i, rs, nr, w, s, _o=[wins[1], wins[2]]):
                if i == 1:
                    return _o[0][0], _o[0][1], w, s
                if i == 2:
                    return _o[1][0], _o[1][1], w, s
                return rs, nr, w, s
            write_spec(spec, d2, a.x_exp, mode, a.seed, a.xamp, tweak=swap)
        elif name.startswith("m10"):
            write_spec(spec, list(reversed(descs)), a.x_exp, mode, a.seed,
                       a.xamp)
        else:
            write_spec(spec, descs, a.x_exp, mode, a.seed, a.xamp, tweak=tweak)
        rc, txt = run(exe, mv4i, spec)
        verd = "KILL" if rc != 0 else "PASS"
        rows.append((name, verd, why))
        with open(os.path.join(outdir, "mut_%s.log"
                               % name.split()[0]), "w") as fp:
            fp.write(txt)
    for name, verd, why in rows:
        print("%-42s %-6s %s" % (name, verd, why))
    nk = sum(1 for _, v, _ in rows if v == "KILL")
    print("%d of %d mutations killed" % (nk, len(rows)))
    return rc_all


if __name__ == "__main__":
    sys.exit(main())
