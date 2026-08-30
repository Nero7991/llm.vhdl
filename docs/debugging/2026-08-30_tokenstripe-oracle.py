#!/usr/bin/env python3
"""TRACK TOKENSTRIPE -- the discrimination control for the lm-head TAIL of
hw/fk33/host/fk33_run_token.py.

Same oracle shape as TRACK STRIPEPATH's `2026-08-30_stripepath-oracle_rl.py`:
every striped base is re-derived from the .mv4i's own 0x38 sub-region table and
the manifest's RAW `pieces` JSON.  It imports neither `gen_mv4i_desc` (so it
cannot inherit `sub_base`'s join) nor `hbm_map` (so it cannot inherit
`file_pieces`).  The segment is read from ADDRESS BITS [32:28], never from a
piece's `segment` label.

The row-window skip is recovered as the RESIDUE of the FLAT dump's own base
arithmetic, so it never comes from the striped side.

usage: tokenstripe_oracle.py FLAT.json STRIPED.json FLAT_MANI STRIPED_MANI STRIPED_DIR
"""
import json
import os
import struct
import sys

HDR = 4096
SEG = (8 << 30) // 32
LM = "output.weight.mv4i"


def header_table(path):
    with open(path, "rb") as fp:
        h = fp.read(HDR)
    assert struct.unpack_from("<I", h, 0)[0] == 0x4D563449, path
    npw, = struct.unpack_from("<H", h, 0x1A)
    _s, nss = struct.unpack_from("<II", h, 0x30)
    return npw, nss, [struct.unpack_from("<Q", h, 0x38 + 8 * i)[0]
                      for i in range(npw + nss)]


def main():
    flatj, strpj, flatman, strpman, model_strp = sys.argv[1:6]
    a = json.load(open(flatj))
    b = json.load(open(strpj))
    fm = {f["file"]: f for f in json.load(open(flatman))["files"]}
    sm = {f["file"]: f for f in json.load(open(strpman))["files"]}
    assert len(a) == len(b), (len(a), len(b))
    npw, nss, offs = header_table(os.path.join(model_strp, LM))
    pieces = {int(p["file_offset"]): int(p["hbm_offset"])
              for p in sm[LM]["pieces"]}
    bf0 = int(fm[LM]["hbm_offset"])
    nmoved = nsame = nchecked = words_same = 0
    wrong = []
    seg_f, seg_s = set(), set()
    for x, y in zip(a, b):
        assert (x["idx"], x["tensor"], x["row_start"]) == (
            y["idx"], y["tensor"], y["row_start"])
        if x["words"] == y["words"]:
            words_same += 1
        for kind, key, o0 in (("w", "w_base", 0), ("s", "s_base", npw)):
            for i, (pf, ps) in enumerate(zip(x[key], y[key])):
                off = offs[o0 + i]
                skip = pf - (bf0 + off)          # the row-window skip, FLAT side
                want = pieces[off] + skip
                nchecked += 1
                if ps != want:
                    wrong.append((x["short"], kind, i, ps, want))
                nsame += (ps == pf)
                nmoved += (ps != pf)
                seg_f.add(pf // SEG)
                seg_s.add(ps // SEG)
    print("TOKENSTRIPE DISCRIMINATION CONTROL -- fk33_run_token.py make_tail")
    print("  windows compared            %d" % len(a))
    print("  windows byte-identical      %d (must be 0)" % words_same)
    print("  sub-region bases compared   %d" % nchecked)
    print("  bases that MOVED            %d" % nmoved)
    print("  bases unchanged             %d" % nsame)
    print("  bases WRONG vs the manifest %d %s" % (len(wrong), wrong[:3]))
    print("  distinct segments, FLAT     %d %s" % (len(seg_f), sorted(seg_f)))
    print("  distinct segments, STRIPED  %d %s" % (len(seg_s), sorted(seg_s)))
    ok = not wrong and nmoved == nchecked and words_same == 0
    print("  -> %s the pieces path is %s"
          % ("PASS" if ok else "FAIL", "LIVE" if ok else "NOT live"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
