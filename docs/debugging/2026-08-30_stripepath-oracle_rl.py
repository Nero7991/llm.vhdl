#!/usr/bin/env python3
"""TRACK STRIPEPATH -- the same discrimination control for
hw/fk33/host/fk33_run_layer.py, over all 32 layers.

Same oracle shape as `stripepath_oracle.py`: every striped base is re-derived
from the .mv4i's own 0x38 table and the manifest's raw `pieces` JSON, with no
call into `gen_mv4i_desc` or `hbm_map`.  Segment from ADDRESS BITS, never a
label."""
import json
import os
import struct
import sys

HDR = 4096
SEG = (8 << 30) // 32


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
    assert len(a) == len(b)
    nmoved = nsame = nchecked = 0
    wrong = []
    seg_f, seg_s = set(), set()
    words_same = 0
    for x, y in zip(a, b):
        assert (x["layer"], x["idx"], x["tensor"]) == (y["layer"], y["idx"],
                                                       y["tensor"])
        if x["words"] == y["words"]:
            words_same += 1
        name = x["tensor"] + ".mv4i"
        npw, nss, offs = header_table(os.path.join(model_strp, name))
        pieces = {int(p["file_offset"]): int(p["hbm_offset"])
                  for p in sm[name]["pieces"]}
        bf0 = int(fm[name]["hbm_offset"])
        for kind, key, o0 in (("w", "w_base", 0), ("s", "s_base", npw)):
            for i, (pf, ps) in enumerate(zip(x[key], y[key])):
                off = offs[o0 + i]
                skip = pf - (bf0 + off)
                want = pieces[off] + skip
                nchecked += 1
                if ps != want:
                    wrong.append((x["tensor"], kind, i, ps, want))
                nsame += (ps == pf)
                nmoved += (ps != pf)
                seg_f.add(pf // SEG)
                seg_s.add(ps // SEG)
    print("STRIPEPATH DISCRIMINATION CONTROL -- fk33_run_layer.py make_layer")
    print("  layers                      32")
    print("  descriptors compared        %d" % len(a))
    print("  descriptors byte-identical  %d (must be 0)" % words_same)
    print("  sub-region bases compared   %d" % nchecked)
    print("  bases that MOVED            %d" % nmoved)
    print("  bases unchanged             %d" % nsame)
    print("  bases WRONG vs the manifest %d %s" % (len(wrong), wrong[:3]))
    print("  distinct segments, FLAT     %d %s" % (len(seg_f), sorted(seg_f)))
    print("  distinct segments, STRIPED  %d %s" % (len(seg_s), sorted(seg_s)))
    ok = not wrong and nmoved == nchecked and words_same == 0
    print("  -> %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
