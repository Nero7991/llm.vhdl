#!/usr/bin/env python3
"""Structural check of a packed model directory against its manifest.

    check_mv4i_set.py OUTDIR [--full]

This is a GUARD, not a summary: every finding is a FAIL and the exit code is
non-zero if there is one.  It is deliberately independent of the writer -- it
re-derives every size from `pack_int4.packed_layout` and re-reads the header
bytes from the file, so a manifest that disagrees with the bytes on disk is
caught rather than believed.

What it checks, per packed tensor:

  * the file exists and is exactly `packed_layout(...)` bytes;
  * magic "MV4I" and version;
  * M, K, ROWS_IF, NPORTS_W, BLOCK, AXI_DW, n_scale_sub in the header match
    the manifest and the geometry;
  * NPORTS_W is what the 6.5 invariant gives, not what the file claims;
  * every sub-region offset in the header table is 4 KB aligned, is inside the
    file, is exactly `sub_sz` apart, and the first weight sub-region starts at
    the 4 KB header boundary (spec 6.4/6.5);
  * `scale_offset` is where the weight region ends, and the n_scale_sub scale
    sub-regions tile the rest of the file exactly, with no gap and no overhang.

And over the set:

  * HBM offsets are 4 KB aligned, ascending, non-overlapping, and inside 8 GiB;
  * the F32 side file exists at its manifest size and every entry inside it is
    4 KB aligned and within it;
  * the totals in the manifest are the sum of the files on disk;
  * every tensor the manifest declares under `dropped_tensors` (see
    `pack_model_fk33.py --drop`) really is absent from `files`, and the
    placed/dropped/GGUF counts add up.

`--full` additionally hashes every byte and COMPARES the digest to the
`blake2b_128` the manifest recorded at pack time.  That is the only check that
catches a file of the right size with the right header and wrong payload:
measured, a single byte set to 0xFF at offset 8192 passes every structural test
in this file and is caught only here.  Without `--full` the run is
header-and-size only and takes seconds instead of minutes.
"""

import argparse
import hashlib
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pack_int4 as P                                        # noqa: E402

HBM_SIZE = 8 * 1024 ** 3
ALIGN = 4096


def check(outdir: str, full: bool = False) -> int:
    fails = []

    def fail(msg):
        fails.append(msg)
        print(f"FAIL {msg}")

    mpath = os.path.join(outdir, "manifest.json")
    if not os.path.exists(mpath):
        print(f"FAIL no manifest at {mpath}")
        return 1
    man = json.load(open(mpath))
    g = man["geometry"]
    rows_if, axi_dw = g["rows_if"], g["axi_dw"]

    nports = P.check_geometry(rows_if, axi_dw, emitting=True)
    nss = P.n_scale_sub(rows_if, axi_dw)
    if (nports, nss) != (g["nports_w"], g["n_scale_sub"]):
        fail(f"manifest geometry says NPORTS_W={g['nports_w']} "
             f"n_scale_sub={g['n_scale_sub']}, spec 6.5/6.5a gives "
             f"{nports}/{nss}")

    # ---- `--drop`ped tensors, when the manifest declares any.  A set that
    # says it left a tensor out must actually have left it out: the failure
    # this catches is a manifest edited to claim a drop that never happened,
    # or a stale entry surviving a repack.  Checked against the FILE LIST, not
    # against the packer's intent.
    dropped = man.get("dropped_tensors", [])
    placed = {e.get("tensor") for e in man["files"]}
    placed_files = {e["file"] for e in man["files"]}
    for d in dropped:
        if d["name"] in placed:
            fail(f"{d['name']}: declared dropped, but a manifest entry places "
                 f"it")
        if d["name"] + ".mv4i" in placed_files:
            fail(f"{d['name']}: declared dropped, but {d['name']}.mv4i is in "
                 f"the file list")
    c = man.get("counts", {})
    if "gguf_tensors" in c and "dropped" in c:
        if c["dropped"] != len(dropped):
            fail(f"counts.dropped {c['dropped']} but dropped_tensors lists "
                 f"{len(dropped)}")
        if c["gguf_tensors"] != c["tensors"] + c["dropped"]:
            fail(f"counts: {c['tensors']} placed + {c['dropped']} dropped "
                 f"!= {c['gguf_tensors']} in the GGUF")
    if c.get("tensors") is not None and \
            c["tensors"] != c.get("matvec", 0) + c.get("f32", 0):
        fail(f"counts.tensors {c['tensors']} != matvec {c.get('matvec')} "
             f"+ f32 {c.get('f32')}")

    def hashed(path):
        h = hashlib.blake2b(digest_size=16)
        with open(path, "rb") as f:
            while True:
                c = f.read(8 << 20)
                if not c:
                    break
                h.update(c)
        return h.hexdigest()

    prev_end = -1
    n_mv = 0
    total = 0
    n_hashed = 0
    for e in man["files"]:
        path = os.path.join(outdir, e["file"])
        off = e["hbm_offset"]
        if off % ALIGN:
            fail(f"{e['file']}: HBM offset {off:#x} is not 4 KB aligned")
        if off < prev_end:
            fail(f"{e['file']}: HBM offset {off:#x} overlaps the previous "
                 f"region ending {prev_end:#x}")
        if not os.path.exists(path):
            fail(f"{e['file']}: missing")
            continue
        sz = os.path.getsize(path)
        if sz != e["nbytes"]:
            fail(f"{e['file']}: on disk {sz} bytes, manifest {e['nbytes']}")
            continue
        if off + sz > HBM_SIZE:
            fail(f"{e['file']}: ends at {off + sz:#x}, past the 8 GiB HBM")
        prev_end = off + sz
        total += sz

        if full:
            want_h = e.get("blake2b_128")
            if not want_h:
                fail(f"{e['file']}: --full asked for, but the manifest records "
                     f"no blake2b_128 for it -- repack to record one, or the "
                     f"payload is unchecked")
            else:
                got_h = hashed(path)
                if got_h != want_h:
                    fail(f"{e['file']}: blake2b-128 {got_h}, manifest says "
                         f"{want_h} -- the payload has changed")
                else:
                    n_hashed += 1          # count MATCHES, never attempts: a
                                           # guard must not report a corrupt
                                           # file in its "matched" total

        if e["kind"] == "f32blob":
            for x in e["entries"]:
                if x["hbm_offset"] % ALIGN:
                    fail(f"{x['name']}: entry HBM offset not 4 KB aligned")
                if x["offset"] + x["nbytes"] > sz:
                    fail(f"{x['name']}: entry runs past the side file")
                if x["hbm_offset"] != off + x["offset"]:
                    fail(f"{x['name']}: entry HBM offset is not the file base "
                         f"plus its in-file offset")
            continue

        n_mv += 1
        want = P.packed_layout(e["M"], e["K"], rows_if, axi_dw)
        NB, tiles, np_, sub_sz, nss_, scl_sub_sz, want_sz = want
        if sz != want_sz:
            fail(f"{e['file']}: {sz} bytes, packed_layout says {want_sz}")
            continue

        with open(path, "rb") as f:
            hdr = f.read(P.HDR_BYTES)
        magic, ver, flags, M, K = struct.unpack_from("<IHHII", hdr, 0x00)
        w_exp, out_shift = struct.unpack_from("<ii", hdr, 0x10)
        h_rows, h_np, h_blk, h_dw = struct.unpack_from("<HHHH", hdr, 0x18)
        scl_off, h_nss = struct.unpack_from("<II", hdr, 0x30)

        if magic != P.MAGIC:
            fail(f"{e['file']}: magic {magic:#x}, want {P.MAGIC:#x}")
        if ver != P.VERSION:
            fail(f"{e['file']}: version {ver}, want {P.VERSION}")
        if (M, K) != (e["M"], e["K"]):
            fail(f"{e['file']}: header M={M} K={K}, manifest "
                 f"M={e['M']} K={e['K']}")
        if (h_rows, h_blk, h_dw) != (rows_if, P.BLOCK, axi_dw):
            fail(f"{e['file']}: header ROWS_IF/BLOCK/AXI_DW "
                 f"{h_rows}/{h_blk}/{h_dw}, want {rows_if}/{P.BLOCK}/{axi_dw}")
        if h_np != nports:
            fail(f"{e['file']}: header NPORTS_W={h_np}, the 6.5 invariant "
                 f"gives {nports}")
        if h_nss != nss:
            fail(f"{e['file']}: header n_scale_sub={h_nss}, 6.5a gives {nss}")
        if (w_exp, out_shift) != (e["w_exp"], e["out_shift"]):
            fail(f"{e['file']}: header w_exp/out_shift {w_exp}/{out_shift}, "
                 f"manifest {e['w_exp']}/{e['out_shift']}")
        if out_shift != P.calibrate_out_shift(K):
            fail(f"{e['file']}: out_shift {out_shift}, spec 7.4 at K={K} "
                 f"gives {P.calibrate_out_shift(K)}")

        # ---- the fused-tensor row segments, when the manifest declares them.
        # A window can only begin on a TILE boundary, so a `row_start` that is
        # not a multiple of ROWS_IF is a segment no descriptor can express and
        # is the whole reason the pad exists.  Re-derived here from ROWS_IF and
        # the declared lengths, not copied from the packer.
        segs = e.get("segments")
        if segs is not None:
            m_log = e.get("M_logical")
            if m_log is None:
                fail(f"{e['file']}: declares segments but no M_logical")
                m_log = 0
            if sum(x["n_rows"] for x in segs) != m_log:
                fail(f"{e['file']}: segments cover "
                     f"{sum(x['n_rows'] for x in segs)} rows, M_logical is "
                     f"{m_log}")
            if m_log > M:
                fail(f"{e['file']}: M_logical {m_log} exceeds the packed "
                     f"M {M}")
            want_start, want_src = 0, 0
            for si, x in enumerate(segs):
                if x["row_start"] % rows_if:
                    fail(f"{e['file']}: segment {x['name']!r} starts at row "
                         f"{x['row_start']}, which is not a multiple of "
                         f"ROWS_IF={rows_if}; no row window can express it")
                if x["row_start"] != want_start:
                    fail(f"{e['file']}: segment {x['name']!r} starts at "
                         f"{x['row_start']}, the pad rule gives {want_start}")
                if x.get("logical_row", want_src) != want_src:
                    fail(f"{e['file']}: segment {x['name']!r} logical_row "
                         f"{x.get('logical_row')}, want {want_src}")
                if x["row_start"] + x["n_rows"] > M:
                    fail(f"{e['file']}: segment {x['name']!r} ends past the "
                         f"packed M {M}")
                want_src += x["n_rows"]
                want_start += x["n_rows"] + x["pad_rows"]
                if si != len(segs) - 1 and want_start % rows_if:
                    fail(f"{e['file']}: segment {x['name']!r} pad_rows "
                         f"{x['pad_rows']} does not reach a tile boundary")
            if want_start > M:
                fail(f"{e['file']}: padded segments need {want_start} rows, "
                     f"the packed M is {M}")

        w_sub = [struct.unpack_from("<Q", hdr, 0x38 + 8 * p)[0]
                 for p in range(nports)]
        s_sub = [struct.unpack_from("<Q", hdr, 0x38 + 8 * (nports + q))[0]
                 for q in range(nss)]
        for p, o in enumerate(w_sub):
            if o % ALIGN:
                fail(f"{e['file']}: weight sub-region {p} at {o:#x} is not "
                     f"4 KB aligned (spec 6.4)")
            if o != P.HDR_BYTES + sub_sz * p:
                fail(f"{e['file']}: weight sub-region {p} at {o}, want "
                     f"{P.HDR_BYTES + sub_sz * p}")
        if scl_off != P.HDR_BYTES + sub_sz * nports:
            fail(f"{e['file']}: scale_offset {scl_off}, want "
                 f"{P.HDR_BYTES + sub_sz * nports}")
        if scl_off % ALIGN:
            fail(f"{e['file']}: scale_offset {scl_off:#x} is not 4 KB aligned")
        for q, o in enumerate(s_sub):
            if o % ALIGN:
                fail(f"{e['file']}: scale sub-region {q} at {o:#x} is not "
                     f"4 KB aligned")
            if o != scl_off + scl_sub_sz * q:
                fail(f"{e['file']}: scale sub-region {q} at {o}, want "
                     f"{scl_off + scl_sub_sz * q}")
        if s_sub and s_sub[-1] + scl_sub_sz != sz:
            fail(f"{e['file']}: the scale region ends at "
                 f"{s_sub[-1] + scl_sub_sz}, the file is {sz} bytes")
        if any(b for b in hdr[0x38 + 8 * (nports + nss):]):
            fail(f"{e['file']}: header padding past the offset table is not "
                 f"0x00 (spec 6.4)")

    if total != man["hbm"]["weights_bytes"]:
        fail(f"manifest weights_bytes {man['hbm']['weights_bytes']}, "
             f"files on disk sum to {total}")
    if n_mv != man["counts"]["matvec"]:
        fail(f"manifest counts.matvec {man['counts']['matvec']}, "
             f"{n_mv} .mv4i entries checked")

    if dropped:
        print(f"\n{len(dropped)} tensor(s) declared dropped and confirmed "
              f"absent from the image: "
              + ", ".join(f"{d['name']} ({d['bytes_if_placed']} B)"
                          for d in dropped))
    print(f"\n{n_mv} packed tensors + 1 F32 side file, {total} bytes total"
          + (f", {n_hashed} payloads hashed and matched" if full else
             " (payloads NOT hashed -- pass --full for that)"))
    if fails:
        print(f"{len(fails)} FAILURES")
        return 1
    print("PASS  every header, size, sub-region offset and HBM placement is "
          "as spec 6.4/6.5a requires")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir")
    ap.add_argument("--full", action="store_true",
                    help="also hash every byte of every file")
    a = ap.parse_args()
    return check(a.outdir, a.full)


if __name__ == "__main__":
    sys.exit(main())
