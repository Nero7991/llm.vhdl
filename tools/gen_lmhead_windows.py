#!/usr/bin/env python3
"""tools/gen_lmhead_windows.py -- the descriptor SET for a tensor that does
not fit one job, and the proof that the set tiles it.

THE PROBLEM.  `output.weight` and `token_embd.weight` are both 248,320 x 4,096.
`rtl/matvec_int4_desc_axi.vhd:684` refuses `n_rows > MAXROWS_BFP` and the FK33
build sets `MAXROWS_BFP = 17408` (`:108`), so neither tensor is one job.  Every
window must ALSO start on a tile boundary, because a row window is expressed as
a byte offset on all 27 bases and a sub-region's beats run tile-major
(`tools/gen_mv4i_desc.py::build_descriptor`).

THE ARITHMETIC, and the part that is a finding.  Those two constraints are not
the same constraint, and MAXROWS_BFP does not satisfy the second one:

    ROWS_IF      = 48
    MAXROWS_BFP  = 17408        17408 mod 48 = 32,  NOT a tile multiple
    STRIDE       = floor(17408 / 48) * 48 = 362 * 48 = 17376
    jobs         = ceil(248320 / 17376) = 15
    cover        = 14 * 17376 + 5056 = 248320   exact

So the answer really is 15 jobs, but at a stride of **17,376, not 17,408**.  A
generator that took MAXROWS_BFP as the stride would emit window 1 at row 17,408,
which `build_descriptor` refuses outright (not a multiple of ROWS_IF) -- so this
particular error is loud.  A generator that ROUNDED it to a tile boundary
without re-deriving the count would emit 15 windows covering 260,640 rows and
run 12,320 rows off the end of the last one, which is not loud at all.

A SECOND CONSEQUENCE, kept because it is easy to lose.  `matvec_core`'s `ybuf`
is `array(0 to TILES-1)` with `TILES = ceil(MAXROWS_BFP / ROWS_IF) = 363`
(`rtl/matvec_core.vhd:120,202`), and worklog OI-8 is an index one past the end
whenever a job's `tiles` reaches TILES.  A tile-aligned window can never do
that: `STRIDE / ROWS_IF = 362 < 363` by construction, because flooring
MAXROWS_BFP to a tile boundary is exactly what removes the last tile.  The
window rule is therefore not merely legal, it is the rule that keeps every job
one tile below OI-8's corner.  (OI-8 itself is separately fixed in the working
tree by `ybuf_addr`, `rtl/matvec_core.vhd:128-130`.)

WHAT IS CHECKED, and none of it is a round trip:

  1. ROW COVER.  The windows are sorted, adjacent, start at 0 and end at M --
     computed from the emitted descriptors' own `row_start` and `n_rows`, not
     from the loop that produced them.
  2. BYTE COVER, per sub-region.  Each window's base for sub-region p, plus its
     own `w_beats * AXI_DW/8` bytes, must abut the next window's base exactly,
     and the union must be the sub-region.  This is the check that would catch a
     right-looking row cover with a wrong base arithmetic, which is the OI-3
     family (a well-formed base at the wrong bytes is undetectable by the
     gateware).
  3. ACCEPTANCE.  Every descriptor is put through `rtl_would_reject`, which
     re-states `matvec_int4_desc_axi`'s S_CHECK in its own order.
  4. y_exp INVARIANCE.  In RAW mode `y_exp = w_exp + x_exp - out_shift`
     (`rtl/matvec_core.vhd:959-961`) with no per-job term, so all 15 windows
     report the SAME exponent and a running argmax across them needs no
     exponent arithmetic.  In BFP mode the per-job `ns_r` enters and they do
     not.  This is checked as an assertion about the emitted fields, and it is
     why `--out-mode raw` is the default here.

Usage:
    tools/gen_lmhead_windows.py --mv4i FILE.mv4i --x-exp 5 [--out-mode raw]
    tools/gen_lmhead_windows.py --mv4i FILE.mv4i --x-exp 5 --outdir DIR
    tools/gen_lmhead_windows.py --mv4i FILE.mv4i --x-exp 5 --mutate
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_mv4i_desc as G                                    # noqa: E402
import hbm_map as HM                                         # noqa: E402
from gen_mv4i_desc import DescError                          # noqa: E402

MODES = {"bfp": G.MODE_BFP, "raw": G.MODE_RAW, "partial": G.MODE_PARTIAL}


def plan(M, rows_if, maxrows_bfp, granule=None):
    """The window list, as (row_start, n_rows).

    Derived here and NOWHERE else, so the checks below have exactly one thing
    to disagree with.  `granule` is `gen_mv4i_desc.window_granule()` -- the
    rows a window start must be a multiple of so that every port base stays
    4 KB aligned; it equals ROWS_IF at K = 4096 and 4 x ROWS_IF at K = 5120
    (2026-09-23).  None means ROWS_IF, the pre-27B behaviour."""
    if rows_if <= 0 or maxrows_bfp <= 0:
        raise DescError("rows_if and maxrows_bfp must be positive")
    granule = rows_if if granule is None else int(granule)
    if granule <= 0 or granule % rows_if:
        raise DescError("granule %d is not a positive multiple of rows_if %d"
                        % (granule, rows_if))
    stride = (maxrows_bfp // granule) * granule
    if stride == 0:
        raise DescError("MAXROWS_BFP = %d is below one tile of ROWS_IF = %d; "
                        "no legal window exists" % (maxrows_bfp, rows_if))
    out = []
    r = 0
    while r < M:
        out.append((r, min(stride, M - r)))
        r += stride
    return stride, out


def build_set(h, hbm_base, x_exp, out_mode, maxrows_bfp, cb_load_first_only,
              pieces=None):
    """`pieces` is `{file_offset: (hbm_offset, nbytes)}` from a v2 lane-striped
    manifest, or None for a v1 flat one -- in which case every base below is
    exactly the old `hbm_base + file offset`.  It is threaded rather than
    recomputed because the byte-cover check reads the bases back out of the
    descriptors, and a second idea of where a sub-region is would make that
    check agree with itself instead of with the manifest."""
    stride, wins = plan(h.M, h.rows_if, maxrows_bfp,
                        G.window_granule(h.rows_if, h.axi_dw, h.K))
    descs = []
    for i, (rs, nr) in enumerate(wins):
        # cb_load on every job is the safe default: the codebook register is
        # A's and nothing here knows whether another job ran between two
        # windows.  --cb-load-once models a schedule that does know.
        cb = True if not cb_load_first_only else (i == 0)
        descs.append(G.build_descriptor(h, hbm_base, nr, x_exp,
                                        out_mode=out_mode, cb_load=cb,
                                        row_start=rs, pieces=pieces))
    return stride, descs


# ------------------------------------------------------------------- checks
def check_row_cover(h, descs):
    """Read the cover back out of the descriptors' own fields."""
    prob = []
    spans = sorted((d.fields["row_start"], d.fields["n_rows"]) for d in descs)
    if not spans:
        return ["no windows"]
    if spans[0][0] != 0:
        prob.append("first window starts at row %d, not 0" % spans[0][0])
    end = 0
    for rs, nr in spans:
        if rs < end:
            prob.append("window at %d OVERLAPS the previous, which ended at %d"
                        % (rs, end))
        elif rs > end:
            prob.append("GAP: rows %d .. %d are in no window" % (end, rs - 1))
        if rs % h.rows_if:
            prob.append("window at %d is not a multiple of ROWS_IF = %d"
                        % (rs, h.rows_if))
        end = rs + nr
    if end != h.M:
        prob.append("windows end at row %d, the tensor has %d" % (end, h.M))
    return prob


def check_byte_cover(h, descs, pieces=None):
    """The same question asked of the BYTES, per sub-region.

    A row cover can be exactly right while the bases are wrong; worklog OI-1
    case 19 is that defect and the gateware cannot see it.  Here the two are
    independent: rows come from `row_start`/`n_rows`, bytes from `w_base`/
    `s_base` and `w_beats`/`s_beats`, and both are read off the emitted
    descriptor rather than recomputed.

    WHERE A SUB-REGION STARTS IS TWO SOURCES JOINED, NOT ONE READ BACK.  The
    FILE OFFSET comes from `G.check_bases(h)`, i.e. the .mv4i's own 0x38 table;
    the ADDRESS that offset was placed at comes from the manifest's `pieces`.
    Deliberately NOT `f["w_extent_base"]`, which `build_descriptor` wrote from
    the same manifest -- reading that back would make this check agree with the
    descriptor it is checking, which is the m7-mutant shape.

    Under a v1 flat manifest `pieces` is None and `want_start` is exactly the
    old `hbm_base + off`."""
    prob = []
    port_b = h.axi_dw // 8
    order = sorted(range(len(descs)), key=lambda i: descs[i].fields["row_start"])
    w_off, s_off, _ = G.check_bases(h)
    full = h.sub_bytes()
    for kind, offs, base_key, beat_key in (
            ("weight", w_off, "w_base", "w_beats"),
            ("scale", s_off, "s_base", "s_beats")):
        for p in range(len(offs)):
            cursor = None
            if pieces is not None:
                # THE EXTENT MUST BE THE WHOLE SUB-REGION.  A window set walks
                # one sub-region end to end, so a piece cut shorter than
                # `sub_bytes()` means the last window reads into whatever the
                # packer put next in that pseudo-channel, and nothing faults.
                # `hbm_map` cannot see this: it never opens the .mv4i.
                got = pieces.get(offs[p])
                if got is None:
                    prob.append("%s sub-region %d is at file +%d and the "
                                "manifest places no piece there"
                                % (kind, p, offs[p]))
                    continue
                if got[1] != full:
                    prob.append("%s sub-region %d: the manifest's piece at "
                                "file +%d is %d B, the header's own table "
                                "makes the sub-region %d B"
                                % (kind, p, offs[p], got[1], full))
            for i in order:
                f = descs[i].fields
                b = f[base_key][p]
                n = f[beat_key] * port_b
                want_start = (f["hbm_base"] + offs[p] if pieces is None
                              else pieces[offs[p]][0])
                if cursor is None:
                    cursor = want_start
                    if b != want_start:
                        prob.append("%s sub-region %d: first window base "
                                    "0x%X, sub-region starts at 0x%X"
                                    % (kind, p, b, want_start))
                if b != cursor:
                    prob.append("%s sub-region %d window at row %d: base 0x%X, "
                                "the previous window ends at 0x%X"
                                % (kind, p, f["row_start"], b, cursor))
                cursor = b + n
            if cursor is not None:
                want_end = ((descs[0].fields["hbm_base"] + offs[p]
                             if pieces is None else pieces[offs[p]][0]) + full)
                if cursor != want_end:
                    prob.append("%s sub-region %d: windows end at 0x%X, the "
                                "sub-region ends at 0x%X (%+d bytes)"
                                % (kind, p, cursor, want_end,
                                   cursor - want_end))
    return prob


def check_acceptance(descs, build=G.FK33):
    prob = []
    for d in descs:
        bad = G.rtl_would_reject(d, build=build)
        if bad:
            prob.append("window at row %d: %s"
                        % (d.fields["row_start"],
                           "; ".join("0x%X %s" % (c if c is not None else 0, w)
                                     for c, w in bad)))
    return prob


def check_y_exp(h, descs, out_mode):
    """y_exp per rtl/matvec_core.vhd:959-961, re-derived here.

    RAW      w_exp + x_exp - out_shift            no per-job term
    BFP      w_exp + x_exp - out_shift - ns_r     ns_r is the job's own scan
    PARTIAL  w_exp + x_exp                        no out_shift term

    Only RAW and PARTIAL are constant across a window SET, and PARTIAL does not
    apply the classifier's out_shift, so RAW is the only mode in which a single
    running argmax over the concatenated streams is exponent-free."""
    prob = []
    if out_mode == G.MODE_BFP:
        prob.append("out_mode = BFP: y_exp carries the per-job normalisation "
                    "shift ns_r, so the 15 windows report DIFFERENT exponents "
                    "and an argmax across them is not a plain int32 compare")
        return prob
    vals = set()
    for d in descs:
        f = d.fields
        if out_mode == G.MODE_RAW:
            vals.add(f["w_exp"] + f["x_exp"] - f["out_shift"])
        else:
            vals.add(f["w_exp"] + f["x_exp"])
    if len(vals) != 1:
        prob.append("y_exp is not constant across the set: %r" % sorted(vals))
    return prob


def run_checks(h, descs, out_mode, build=G.FK33, pieces=None):
    return [("row cover", check_row_cover(h, descs)),
            ("byte cover", check_byte_cover(h, descs, pieces)),
            ("gateware acceptance", check_acceptance(descs, build)),
            ("y_exp invariance", check_y_exp(h, descs, out_mode))]


def report(h, stride, descs, out_mode, build=G.FK33, verbose=True,
           pieces=None):
    if verbose:
        print("tensor        %s" % os.path.basename(h.path))
        print("shape         M=%d K=%d" % (h.M, h.K))
        print("build         ROWS_IF=%d AXI_DW=%d MAXROWS_BFP=%d "
              "nsub_w=%d nsub_s=%d"
              % (h.rows_if, h.axi_dw, build["maxrows_bfp"], h.nports_w,
                 h.n_scale_sub))
        print("stride        %d = floor(%d / %d) * %d   (MAXROWS_BFP mod "
              "ROWS_IF = %d, so MAXROWS_BFP is NOT a legal stride)"
              % (stride, build["maxrows_bfp"], h.rows_if, h.rows_if,
                 build["maxrows_bfp"] % h.rows_if))
        print("windows       %d" % len(descs))
        print()
        print("%-4s %-9s %-8s %-6s %-9s %-9s %s"
              % ("job", "row_start", "n_rows", "tiles", "w_beats", "s_beats",
                 "w_base[0]"))
        for i, d in enumerate(descs):
            f = d.fields
            print("%-4d %-9d %-8d %-6d %-9d %-9d 0x%010X"
                  % (i, f["row_start"], f["n_rows"], f["tiles"], f["w_beats"],
                     f["s_beats"], f["w_base"][0]))
        print()
    results = run_checks(h, descs, out_mode, build, pieces)
    ok = True
    for name, prob in results:
        if prob:
            ok = False
            if verbose:
                print("FAIL %s" % name)
                for p in prob[:8]:
                    print("     %s" % p)
                if len(prob) > 8:
                    print("     ... and %d more" % (len(prob) - 8))
        elif verbose:
            print("PASS %s" % name)
    return ok


# ------------------------------------------------------------------ mutants
def _stride_maxrows(h, build):
    """MAXROWS_BFP used directly as the stride."""
    stride = build["maxrows_bfp"]
    out, r = [], 0
    while r < h.M:
        out.append((r, min(stride, h.M - r)))
        r += stride
    return stride, out


def _stride_rounded_up(h, build):
    """Tile-aligned but rounded UP: 363 tiles = 17424 rows > MAXROWS_BFP."""
    stride = -(-build["maxrows_bfp"] // h.rows_if) * h.rows_if
    out, r = [], 0
    while r < h.M:
        out.append((r, min(stride, h.M - r)))
        r += stride
    return stride, out


def _count_kept(h, build):
    """Right stride, but the job count taken from MAXROWS_BFP instead of the
    stride -- 15 windows of 17376 that overrun the tensor."""
    stride = (build["maxrows_bfp"] // h.rows_if) * h.rows_if
    n = -(-h.M // build["maxrows_bfp"])
    return stride, [(i * stride, stride) for i in range(n)]


def _drop_last(h, build):
    stride, wins = plan(h.M, h.rows_if, build["maxrows_bfp"])
    return stride, wins[:-1]


def _swap_two(h, build):
    """Two windows given each other's bases.  The ROW cover is still perfect;
    only the byte cover can object."""
    return "swap", None


def run_mutations(h, hbm_base, x_exp, out_mode, build=G.FK33, pieces=None):
    print("mutation table -- KILLED means a check refused the window set")
    print("%-46s %-8s %s" % ("mutant", "verdict", "what fired"))
    stride, descs = build_set(h, hbm_base, x_exp, out_mode,
                              build["maxrows_bfp"], False, pieces=pieces)
    clean = report(h, stride, descs, out_mode, build, verbose=False,
                   pieces=pieces)
    print("%-46s %-8s %s" % ("m0 clean (control)", "PASS" if clean else "FAIL",
                             "must PASS or the table means nothing"))

    def run_plan(planner):
        try:
            st, wins = planner(h, build)
            ds = []
            for rs, nr in wins:
                if rs + nr > h.M:
                    return ["build_descriptor refused: row_start %d + rows %d "
                            "exceeds M = %d" % (rs, nr, h.M)]
                ds.append(G.build_descriptor(h, hbm_base, nr, x_exp,
                                             out_mode=out_mode, cb_load=True,
                                             row_start=rs, pieces=pieces))
        except DescError as e:
            return ["build_descriptor refused: %s" % e]
        fired = []
        for name, prob in run_checks(h, ds, out_mode, build, pieces):
            if prob:
                fired.append("%s (%d)" % (name, len(prob)))
        return fired

    killed = 0
    table = [("m1 stride = MAXROWS_BFP (17408)", _stride_maxrows),
             ("m2 stride rounded UP to 363 tiles", _stride_rounded_up),
             ("m3 count from MAXROWS_BFP, stride from tiles", _count_kept),
             ("m4 last window dropped", _drop_last)]
    for name, planner in table:
        fired = run_plan(planner)
        if fired:
            killed += 1
        print("%-46s %-8s %s" % (name, "KILLED" if fired else "SILENT",
                                 ", ".join(fired) or
                                 "NOTHING -- this is the resolution floor"))

    # m5 has to be done on the built descriptors, not on the plan
    st, ds = build_set(h, hbm_base, x_exp, out_mode, build["maxrows_bfp"], False)
    a, b = ds[3].fields, ds[4].fields
    a["w_base"], b["w_base"] = b["w_base"], a["w_base"]
    fired = [n for n, p in run_checks(h, ds, out_mode, build) if p]
    if fired:
        killed += 1
    print("%-46s %-8s %s" % ("m5 two windows' weight bases swapped",
                             "KILLED" if fired else "SILENT",
                             ", ".join(fired) or
                             "NOTHING -- this is the resolution floor"))

    # m6: the mode the whole y_exp argument turns on
    st, ds = build_set(h, hbm_base, x_exp, G.MODE_BFP, build["maxrows_bfp"],
                       False)
    fired = [n for n, p in run_checks(h, ds, G.MODE_BFP, build) if p]
    if fired:
        killed += 1
    print("%-46s %-8s %s" % ("m6 out_mode BFP instead of RAW",
                             "KILLED" if fired else "SILENT",
                             ", ".join(fired) or
                             "NOTHING -- this is the resolution floor"))
    print("killed %d of 6" % killed)
    return killed == 6 and clean


# --------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mv4i", required=True)
    ap.add_argument("--manifest",
                    default="/mnt/storage/llama-models/qwen35-9b-mv4i/"
                            "manifest.json")
    ap.add_argument("--x-exp", type=int, required=True,
                    help="activation block exponent; a runtime value, not "
                         "derivable from anything on disk")
    ap.add_argument("--out-mode", choices=sorted(MODES), default="raw")
    ap.add_argument("--maxrows-bfp", type=int, default=G.FK33["maxrows_bfp"])
    ap.add_argument("--no-hbm-base", action="store_true")
    ap.add_argument("--cb-load-once", action="store_true",
                    help="set cb_load on window 0 only (models a schedule "
                         "that knows nothing else touched A's codebook)")
    ap.add_argument("--outdir", help="write win%%02d.hex / .bin / .json here")
    ap.add_argument("--mutate", action="store_true")
    a = ap.parse_args(argv)

    h = G.Mv4iHeader(a.mv4i)
    if a.no_hbm_base:
        hbm_base, pieces = 0, None
    else:
        # `allow_striped=True`: TAUGHT.  `pieces` is read on the next line and
        # threaded into every window's descriptor, so each sub-region base is
        # the address the manifest placed that FILE OFFSET at.  Without it this
        # tool would emit a full window set off a v2 manifest with every base
        # computed from a 4 KB header, and the byte-cover check would agree
        # with it because both would share the mistake.
        hbm_base, _entry, _m = G.hbm_base_for(a.mv4i, a.manifest,
                                              allow_striped=True)
        pieces = G.piece_extents(_entry)
        # THE PLACEMENT, CHECKED BY SOMETHING THAT NEVER SEES THESE
        # DESCRIPTORS.  `check_byte_cover` below joins the file's 0x38 table to
        # the manifest's `pieces` -- so a piece placed at a WRONG but
        # self-consistent address (moved a whole segment, colliding with
        # another lane, or across the 4 GiB stack line) is invisible to it: the
        # placement is on both sides and cancels.  MEASURED 2026-08-30, teeth
        # rows T1, T3, T9, T10: without this call the window set is emitted
        # clean.  Same defect and same fix as `fk33_run_job.make_plan` at
        # 263e0ee, and `gen_layer_program.place_desc_arena` already does it for
        # the token program.
        fails = HM.plan(_m).check()
        if fails:
            print("REFUSING to emit windows -- tools/hbm_map.py finds %d "
                  "placement fault(s) in this manifest's own address map:"
                  % len(fails))
            for f in fails[:8]:
                print("  %s" % f)
            if len(fails) > 8:
                print("  ... and %d more" % (len(fails) - 8))
            return 1
    build = dict(G.FK33)
    build["maxrows_bfp"] = a.maxrows_bfp
    mode = MODES[a.out_mode]

    if a.mutate:
        return 0 if run_mutations(h, hbm_base, a.x_exp, mode, build,
                                  pieces=pieces) else 1

    stride, descs = build_set(h, hbm_base, a.x_exp, mode, a.maxrows_bfp,
                              a.cb_load_once, pieces=pieces)
    ok = report(h, stride, descs, mode, build, pieces=pieces)

    if a.outdir:
        os.makedirs(a.outdir, exist_ok=True)
        index = []
        for i, d in enumerate(descs):
            stem = os.path.join(a.outdir, "win%02d" % i)
            with open(stem + ".bin", "wb") as fp:
                fp.write(d.to_bytes())
            with open(stem + ".hex", "w") as fp:
                fp.write("# GENERATED by tools/gen_lmhead_windows.py -- "
                         "DO NOT EDIT\n")
                fp.write("# %s window %d/%d rows %d..%d out_mode=%d x_exp=%d\n"
                         % (os.path.basename(h.path), i, len(descs),
                            d.fields["row_start"],
                            d.fields["row_start"] + d.fields["n_rows"] - 1,
                            d.fields["out_mode"], d.fields["x_exp"]))
                for ln in d.hexlines():
                    fp.write(ln + "\n")
            index.append(dict(job=i, row_start=d.fields["row_start"],
                              n_rows=d.fields["n_rows"],
                              tiles=d.fields["tiles"],
                              w_beats=d.fields["w_beats"],
                              s_beats=d.fields["s_beats"],
                              w_base=["0x%X" % b for b in d.fields["w_base"]],
                              s_base=["0x%X" % b for b in d.fields["s_base"]]))
        with open(os.path.join(a.outdir, "index.json"), "w") as fp:
            json.dump(dict(tensor=os.path.basename(h.path), M=h.M, K=h.K,
                           rows_if=h.rows_if, axi_dw=h.axi_dw,
                           maxrows_bfp=a.maxrows_bfp, stride=stride,
                           out_mode=d.fields["out_mode"], windows=index),
                      fp, indent=1)
            fp.write("\n")
        print("\nwrote %d descriptors to %s" % (len(descs), a.outdir))

    print("\nWINDOW SET %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DescError as e:
        sys.stderr.write("gen_lmhead_windows: %s\n" % e)
        sys.exit(2)
