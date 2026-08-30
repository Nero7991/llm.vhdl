#!/usr/bin/env python3
"""TRACK STRIPEPATH -- the inertness oracle and its discrimination control.

ARM 1, INERTNESS.  On a v1 FLAT manifest every consumer taught `pieces` must
emit output byte-identical to the pre-change file.  Measured by `diff` on
artefacts captured BEFORE the edit; this program only counts what was compared.

ARM 2, DISCRIMINATION.  On the v2 lane-striped manifest the bases must MOVE,
and each one must land where the manifest placed that FILE OFFSET.  This is an
ORACLE and not a round trip: it re-derives every base from
  (a) the .mv4i's own 0x38 sub-region table, read here with `struct`, and
  (b) the manifest's `pieces` list, read here from raw JSON,
without importing `gen_mv4i_desc`, `hbm_map` or any code the emitters use.  The
segment is read from ADDRESS BITS [32:28] (`addr // 256 MiB`), never from a
piece's `segment` label -- PACKSTRIPE's T3 is the recorded cost of the other
choice."""
import json
import os
import struct
import sys

HDR = 4096
SEG = (8 << 30) // 32                       # 256 MiB, DERIVED from HBM_TOP/32


def header_table(path):
    """(nports_w, n_scale_sub, [sub-region file offsets]) out of spec 6.4."""
    with open(path, "rb") as fp:
        h = fp.read(HDR)
    magic, = struct.unpack_from("<I", h, 0)
    assert magic == 0x4D563449, path
    npw, = struct.unpack_from("<H", h, 0x1A)
    _scl, nss = struct.unpack_from("<II", h, 0x30)
    offs = [struct.unpack_from("<Q", h, 0x38 + 8 * i)[0]
            for i in range(npw + nss)]
    return npw, nss, offs


def read_hex(p):
    return [int(x, 16) for x in open(p).read().split()]


def bases_of(words, npw, nss):
    return words[8:8 + npw], words[8 + npw:8 + npw + nss]


def main():
    flatdir, strpdir, flatman, strpman, model_flat, model_strp = sys.argv[1:7]
    fm = {f["file"]: f for f in json.load(open(flatman))["files"]}
    sm = {f["file"]: f for f in json.load(open(strpman))["files"]}
    print("STRIPEPATH DISCRIMINATION CONTROL -- gen_layer_program.py --token")
    print("  flat manifest    %s" % flatman)
    print("  striped manifest %s" % strpman)

    names = sorted(n for n in os.listdir(strpdir) if n.startswith("a")
                   and n.endswith(".hex"))
    nmoved = nsame = nchecked = 0
    seg_flat, seg_strp = set(), set()
    wrong = []
    ndesc = 0
    for n in names:
        tensor = n.split("_", 1)[1][:-4]
        fa = read_hex(os.path.join(flatdir, n))
        sa = read_hex(os.path.join(strpdir, n))
        mv = os.path.join(model_strp, tensor + ".mv4i")
        npw, nss, offs = header_table(mv)
        fw, fs = bases_of(fa, npw, nss)
        sw, ss = bases_of(sa, npw, nss)
        ndesc += 1
        # the ONE piece of state the descriptor does not restate: the row
        # window's byte skip.  Re-derived from the flat program, whose base
        # arithmetic is `hbm_offset + file offset + skip` -- so the skip is the
        # residue, computed WITHOUT reading the striped side at all.
        base_flat = int(fm[tensor + ".mv4i"]["hbm_offset"])
        pieces = {int(x["file_offset"]): (int(x["hbm_offset"]), int(x["nbytes"]))
                  for x in sm[tensor + ".mv4i"]["pieces"]}
        for kind, fb, sb, o0 in (("w", fw, sw, 0), ("s", fs, ss, npw)):
            for i, (bf, bs) in enumerate(zip(fb, sb)):
                off = offs[o0 + i]
                skip = bf - (base_flat + off)
                want = pieces[off][0] + skip
                nchecked += 1
                if bs != want:
                    wrong.append((tensor, kind, i, bs, want))
                if bs == bf:
                    nsame += 1
                else:
                    nmoved += 1
                seg_flat.add(bf // SEG)
                seg_strp.add(bs // SEG)
    print("  descriptors compared        %d" % ndesc)
    print("  sub-region bases compared   %d" % nchecked)
    print("  bases that MOVED            %d" % nmoved)
    print("  bases unchanged             %d" % nsame)
    print("  bases WRONG vs the manifest %d %s"
          % (len(wrong), wrong[:3]))
    print("  distinct segments, FLAT     %d  %s"
          % (len(seg_flat), sorted(seg_flat)))
    print("  distinct segments, STRIPED  %d  %s"
          % (len(seg_strp), sorted(seg_strp)))
    ok = not wrong and nmoved == nchecked and len(seg_strp) > len(seg_flat)
    print("  -> %s" % ("PASS the pieces path is LIVE: every base moved, every "
                       "one lands where the manifest placed its file offset, "
                       "and they reach more pseudo-channels" if ok
                       else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
