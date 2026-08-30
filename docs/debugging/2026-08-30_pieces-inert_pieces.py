#!/usr/bin/env python3
"""TRACK PIECES -- is the `pieces` path INERT where it should be?

THE ORACLE.  Take the SHIPPING FLAT manifest and re-express it as a v2
`pieces` manifest that says exactly what the flat one says: cut every .mv4i at
its own sub-region boundaries (the header's 0x38 table, read independently by
`Mv4iHeader`) and place each piece at `hbm_base + file_offset`, i.e. contiguous
and unmoved.  Then build the descriptor BOTH ways and require the 39 words to
be bit-identical.

Why this is an oracle and not a round trip: the two descriptors are reached by
different code.  The flat arm never looks at a piece; the piece arm never
computes `hbm_base + off`.  They can only agree if the piece path composes to
the same addresses.  A mistake in the join, in the ordering, or in the bound
shows up as a word that differs.

No card, no /dev, no Vivado.  Reads .mv4i headers (4 KB each) only.
"""
import json
import os
import sys

REPO = "/home/orencollaco/GitHub/llama.vhdl"
sys.path.insert(0, os.path.join(REPO, "tools"))
import gen_mv4i_desc as G                                       # noqa: E402

FLAT = "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json"
ROOT = os.path.dirname(FLAT)


def flat_as_pieces(h, base):
    """The flat layout, expressed the way a v2 manifest expresses striping."""
    w_off, s_off, _ = G.check_bases(h)
    w_stride, s_stride = G.layout_strides(h)
    out = {0: (base, G.MV4I_HDR_BYTES)}
    for o in w_off:
        out[o] = (base + o, w_stride)
    for o in s_off:
        out[o] = (base + o, s_stride)
    return out


def main():
    m = json.load(open(FLAT))
    ents = [e for e in m["files"] if e.get("kind") == "mv4i"]
    n = 0
    njobs = 0
    diffs = []
    missing = []
    for e in sorted(ents, key=lambda x: x["file"]):
        p = os.path.join(ROOT, e["file"])
        if not os.path.exists(p):
            missing.append(e["file"])
            continue
        h = G.Mv4iHeader(p)
        base = int(e["hbm_offset"])
        pieces = flat_as_pieces(h, base)
        n += 1
        # Three jobs per tensor: a short prefix, the whole tensor, and a window
        # that does not start at row 0 -- the last one is the only case where
        # w_skip / s_skip are non-zero, and it is where a bound or an offset
        # mistake would hide.
        jobs = [(100 if h.M >= 100 else h.M, 0)]
        full = min(h.M, 17408 - (17408 % h.rows_if))
        jobs.append((full, 0))
        if h.M > 2 * h.rows_if:
            jobs.append((h.rows_if, h.rows_if))
        for n_rows, row_start in jobs:
            if row_start + n_rows > h.M:
                continue
            njobs += 1
            a = G.build_descriptor(h, base, n_rows, -6, row_start=row_start)
            b = G.build_descriptor(h, base, n_rows, -6, row_start=row_start,
                                   pieces=pieces)
            if a.words != b.words:
                bad = [(i, a.words[i], b.words[i])
                       for i in range(len(a.words)) if a.words[i] != b.words[i]]
                diffs.append((e["file"], n_rows, row_start, bad))
    print("INERTNESS ORACLE -- flat path vs pieces path on the FLAT manifest")
    print("  manifest                 %s" % FLAT)
    print("  format                   %r" % m["format"])
    print("  mv4i objects in manifest %d" % len(ents))
    print("  objects read from disk   %d   (COVERAGE: %d of %d)"
          % (n, n, len(ents)))
    print("  files absent             %d %s" % (len(missing), missing[:3]))
    print("  descriptors built        %d per arm, %d words each"
          % (njobs, len(a.words)))
    print("  words compared           %d" % (njobs * len(a.words)))
    print("  descriptors that DIFFER  %d" % len(diffs))
    for f, r, rs, bad in diffs[:5]:
        print("    %s rows=%d row_start=%d: %r" % (f, r, rs, bad[:4]))
    ok = not diffs and not missing and n == len(ents)
    print("  -> %s" % ("PASS the pieces path is inert on a flat layout"
                       if ok else "FAIL"))

    # THE DISCRIMINATION CONTROL FOR THE TEST ABOVE.  An inertness test passes
    # trivially if `pieces` is being ignored altogether, so the same comparison
    # is run against the REAL striped manifest, where the answer must be that
    # the bases MOVE.  Without this row, "0 words differ" is compatible with
    # the whole feature being dead code.
    strp = ("/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/"
            "manifest.json")
    ok2 = None
    if os.path.exists(strp):
        ms = json.load(open(strp))
        by = {e["file"]: e for e in ms["files"]}
        moved = same = 0
        segs = set()
        for e in sorted(ents, key=lambda x: x["file"]):
            se = by.get(e["file"])
            if se is None:
                continue
            p = os.path.join(ROOT, e["file"])
            h = G.Mv4iHeader(p)
            nr = min(h.M, 100)
            a = G.build_descriptor(h, int(e["hbm_offset"]), nr, -6)
            b = G.build_descriptor(h, int(se["hbm_offset"]), nr, -6,
                                   pieces=G.piece_extents(se))
            for x, y in zip(a.fields["w_base"] + a.fields["s_base"],
                            b.fields["w_base"] + b.fields["s_base"]):
                moved += x != y
                same += x == y
                segs.add(y >> 28)
        print()
        print("DISCRIMINATION CONTROL -- the same comparison on the STRIPED "
              "manifest")
        print("  format                   %r" % ms["format"])
        print("  sub-region bases compared %d" % (moved + same))
        print("  bases that MOVED          %d" % moved)
        print("  bases unchanged           %d" % same)
        print("  distinct segments reached %d  %s"
              % (len(segs), sorted(segs)))
        ok2 = moved > 0 and len(segs) > 1
        print("  -> %s" % ("PASS the pieces path is live: it moves bases into "
                           "many pseudo-channels"
                           if ok2 else "FAIL the pieces argument changes "
                           "nothing, so the inertness result above is vacuous"))
    return 0 if (ok and ok2 is not False) else 1


if __name__ == "__main__":
    sys.exit(main())
