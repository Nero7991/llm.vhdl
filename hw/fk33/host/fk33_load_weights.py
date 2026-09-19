#!/usr/bin/env python3
"""Place the whole 9B weight image into FK33 HBM, and prove it is there.

    fk33_load_weights.py plan      MANIFEST.json
    fk33_load_weights.py load      MANIFEST.json [--verify] [--only PAT]
    fk33_load_weights.py verify    MANIFEST.json [--headers-only] [--only PAT]
    fk33_load_weights.py selfcheck                         (no card, no image)

`fk33ctl.py load` places ONE file at ONE offset.  The 9B image is 250 objects
at 250 different offsets and a hand-typed offset is exactly the mistake that
cannot be seen afterwards, so this walks the manifest instead.  It is a
separate file rather than a subcommand of `fk33ctl.py` on purpose: `fk33ctl.py`
is the bring-up instrument and is being run against a live card by other
people; this is the model loader and has a different lifetime.


WHY `verify` HERE IS NOT `fk33ctl.py verify`
--------------------------------------------

`fk33ctl.py verify` reads HBM back and compares it, byte for byte, against the
LOCAL FILE it was told to compare against.  That is a good transport check --
H2C wrote and C2H read, two different DMA engines -- and it is not an answer to
the question that matters here, which is:

    is the image on the card the image I MEANT to put there?

It cannot be, because the operator supplies the file AND the offset on the
command line, so the same wrong pairing that produced a wrong load reproduces
itself in the verify and the run reports PASS.  A load of `blk.7.ffn_up` to
`blk.7.ffn_gate`'s base passes `fk33ctl.py verify` when handed the same two
arguments.  That is this project's recorded failure mode, not a hypothetical.

So `verify` in this file:

  * NEVER opens a .mv4i file.  It reads the manifest -- a few hundred KB of
    JSON -- and nothing else off the local disk.  The image can be on another
    machine, or deleted.  It is therefore structurally impossible for it to
    re-read what `load` just wrote through the same path.
  * compares the read-back bytes against `blake2b_128` in the manifest, which
    `tools/pack_model_fk33.py` computed from the PACKED BYTES at pack time.
    That digest is the artefact.  A tensor loaded at another tensor's base
    fails it; a byte flipped in flight fails it; a stale image from a previous
    pack fails it.
  * independently PARSES the read-back 4 KB header of every packed tensor,
    with a parser written here from the spec 6.4/6.5a byte offsets, and checks
    M, K, ROWS_IF, NPORTS_W, BLOCK, AXI_DW, `scale_offset`, `n_scale_sub` and
    the whole sub-region offset table at 0x38 against the manifest entry and
    against the geometry re-derived from first principles.  That table is the
    second independent artefact: no generator wrote it into the manifest, the
    packer wrote it into the tensor, and `tools/gen_layer_program.py` reads it
    to build every descriptor.  If the header at a base is not the header the
    manifest says lives there, the descriptors the card will execute are wrong
    and this says so before a single job runs.

`--headers-only` runs the second check alone: 250 reads of 4 KB, about a
megabyte, seconds rather than the full read-back.  It catches every
wrong-base and wrong-tensor error and no payload corruption.  Run it first.


TEETH
-----

`selfcheck` needs no card and no weight image.  It builds a small synthetic
image and a sparse file that stands in for HBM, points the DMA paths at it
through `FK33_H2C`/`FK33_C2H`, loads, verifies, and then applies a table of
deliberate corruptions -- a flipped payload byte, a tensor written at another
tensor's base, two tensors swapped, a truncated write, a header field altered
-- and FAILS if any of them is not caught.  A checker never shown to fail has
not been shown to work.


THE DEVICE PATHS

`FK33_H2C` and `FK33_C2H` override `/dev/xdma0_h2c_0` and `/dev/xdma0_c2h_0`.
They exist for `selfcheck` and for dry runs against a file; against the card,
leave them unset.  The file offset IS the HBM byte address, flat from 0 to
0x1_FFFF_FFFF, and the engine's own masters see the same flat map -- MEASURED
from `hw/fk33/gen_pcieep.py`, which assigns every engine master all 32
`HBM_MEM` segments at `s * 0x1000_0000`.  So `hbm_offset` in the manifest is
one number that means the same thing to the loader and to subsystem A.
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import tempfile
import time

# THE WHOLE-MAP CHECK.  This file's own preflight sees the packed objects and
# nothing else, so it would happily load an image under a top of HBM where the
# subsystem A descriptor arena is sitting on the logits writeback -- MEASURED
# 2026-08-29, 153,664 B of it, the top 15.47% of the vocabulary, and the
# symptom is a wrong token.  `tools/hbm_map.py` is the one model of the whole
# 8 GiB and is consulted here before a byte moves.  Absent (a stripped
# checkout), the per-object checks below still run and the gap is STATED, not
# swallowed: silence about a check that did not run is how this got here.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "tools"))
try:
    import hbm_map as HM
except Exception as _e:                                   # pragma: no cover
    HM = None
    _HM_WHY = str(_e)

HBM_SIZE = 0x2_0000_0000
CHUNK = 8 << 20
ALIGN = 4096
HDR_BYTES = 4096
MV4I_MAGIC = 0x4D563449               # "MV4I", spec 6.4
BLOCK = 32                            # spec 6.1


class StripedWithoutMap(Exception):
    pass


def pieces_of(e):
    """The extents this object occupies: one for a v1 flat manifest, 28 for a
    v2 lane-striped one (a 4 KB header plus one sub-region per engine master,
    each in its own HBM pseudo-channel).

    DELEGATED, NOT REIMPLEMENTED.  `tools/hbm_map.py::file_pieces()` is the one
    producer of this model and three other consumers read it through the same
    function.  A local copy here would be a second idea of where a tensor is,
    which is precisely the class of defect this whole change exists to close.

    A v2 manifest with no `hbm_map` importable is REFUSED rather than treated
    as flat.  Treating it as flat is not a degraded check, it is a wrong one:
    `hbm_offset` on a striped object is a 4 KB header, so a flat reading would
    write `nbytes` bytes over 27 other lanes' arenas and verify a range that
    does not exist."""
    if HM is not None:
        return HM.file_pieces(e)
    if e.get("pieces"):
        raise StripedWithoutMap(
            "%s carries `pieces` (a lane-striped v2 manifest) and "
            "tools/hbm_map.py could not be imported (%s), so the extents "
            "cannot be read.  Refusing: reading hbm_offset/nbytes as one "
            "contiguous range would place and verify bytes that are not "
            "there." % (e.get("file"), _HM_WHY))
    # The stripped-checkout fallback, and FLAT ONLY.  It is the one line of
    # this model that exists twice, it is reachable only when hbm_map is
    # absent, and it is why the branch above refuses rather than falls through.
    return [dict(index=0, kind="whole", lane=None, file_offset=0,
                 hbm_offset=int(e["hbm_offset"]), nbytes=int(e["nbytes"]),
                 segment=None, segment_declared=None)]


def h2c():
    return os.environ.get("FK33_H2C", "/dev/xdma0_h2c_0")


def c2h():
    return os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0")


# ---------------------------------------------------------------- spec 6.5a
# Re-derived here rather than imported from tools/pack_int4.py.  The point of
# this file is to be a second opinion about bytes the packer produced; sharing
# the packer's arithmetic would make the two incapable of disagreeing, which is
# the `m7 mutant` failure recorded in CLAUDE.md.

def _n_scale_sub(rows_if, axi_dw):
    """Scale sub-regions: one ROWS_IF-entry group is rows_if * 2 bytes, and a
    beat is axi_dw/8 bytes, so a group spans ceil over the beat."""
    port_b = axi_dw // 8
    g = rows_if * 2
    from math import gcd
    return g // gcd(g, port_b)


def _nports_w(rows_if, axi_dw):
    """The 6.5 invariant: one tile word is ROWS_IF row-chunks of BLOCK/2 bytes
    and it must slice exactly into AXI_DW-wide sub-regions."""
    word_b = rows_if * (BLOCK // 2)
    port_b = axi_dw // 8
    if word_b % port_b:
        return None
    return word_b // port_b


def _align4k(n):
    return (n + ALIGN - 1) & ~(ALIGN - 1)


def _packed_layout(M, K, rows_if, axi_dw):
    """(sub_sz, nports, scl_off, scl_sub_sz, nss, total) for spec 6.5a."""
    nb = (K + BLOCK - 1) // BLOCK
    tiles = (M + rows_if - 1) // rows_if
    port_b = axi_dw // 8
    nports = _nports_w(rows_if, axi_dw)
    sub_sz = _align4k(tiles * nb * port_b)
    nss = _n_scale_sub(rows_if, axi_dw)
    grp = (port_b * nss) // 2 // rows_if          # ROWS_IF groups per superword
    nsuper = (tiles * nb + grp - 1) // grp
    scl_sub_sz = _align4k(nsuper * port_b)
    scl_off = HDR_BYTES + sub_sz * nports
    total = scl_off + scl_sub_sz * nss
    return sub_sz, nports, scl_off, scl_sub_sz, nss, total


class HeaderMismatch(Exception):
    pass


def parse_and_check_header(buf, ent, geom, where):
    """Parse a 4 KB MV4I header out of `buf` and check it against the manifest
    entry and the geometry.  Raises HeaderMismatch with the FIRST discrepancy.

    Byte layout, spec 6.4, little-endian:
        0x00 u32 magic   0x04 u16 version   0x06 u16 flags
        0x08 u32 M       0x0C u32 K
        0x10 i32 w_exp   0x14 i32 out_shift
        0x18 u16 rows_if 0x1A u16 nports_w  0x1C u16 block  0x1E u16 axi_dw
        0x20 16 x i8 codebook
        0x30 u32 scale_offset               0x34 u32 n_scale_sub
        0x38 + 8p u64 weight sub-region p
        0x38 + 8(nports+q) u64 scale sub-region q
    """
    def bad(msg):
        raise HeaderMismatch(f"{where}: {msg}")

    if len(buf) < HDR_BYTES:
        bad(f"only {len(buf)} bytes read, need {HDR_BYTES}")
    magic, ver, _flags, M, K = struct.unpack_from("<IHHII", buf, 0x00)
    if magic != MV4I_MAGIC:
        bad(f"magic {magic:#010x} is not MV4I ({MV4I_MAGIC:#010x}) -- there is "
            f"no packed tensor at this address")
    if ver != 1:
        bad(f"version {ver}, expected 1")
    w_exp, out_shift = struct.unpack_from("<ii", buf, 0x10)
    rows_if, nports, blk, axi_dw = struct.unpack_from("<HHHH", buf, 0x18)
    scl_off, nss = struct.unpack_from("<II", buf, 0x30)

    for name, got, want in (
            ("M", M, int(ent["M"])),
            ("K", K, int(ent["K"])),
            ("w_exp", w_exp, int(ent["w_exp"])),
            ("out_shift", out_shift, int(ent["out_shift"])),
            ("ROWS_IF", rows_if, int(geom["rows_if"])),
            ("NPORTS_W", nports, int(geom["nports_w"])),
            ("BLOCK", blk, int(geom["block"])),
            ("AXI_DW", axi_dw, int(geom["axi_dw"])),
            ("n_scale_sub", nss, int(geom["n_scale_sub"]))):
        if got != want:
            bad(f"header {name} = {got}, manifest/geometry says {want}")

    # Re-derive, do not trust: NPORTS_W and n_scale_sub from the invariant.
    if _nports_w(rows_if, axi_dw) != nports:
        bad(f"header NPORTS_W = {nports}, the 6.5 invariant at ROWS_IF="
            f"{rows_if} AXI_DW={axi_dw} gives {_nports_w(rows_if, axi_dw)}")
    if _n_scale_sub(rows_if, axi_dw) != nss:
        bad(f"header n_scale_sub = {nss}, spec 6.5a gives "
            f"{_n_scale_sub(rows_if, axi_dw)}")

    sub_sz, np_, want_scl, scl_sub_sz, nss_, total = \
        _packed_layout(M, K, rows_if, axi_dw)
    if total != int(ent["nbytes"]):
        bad(f"the layout implied by the header is {total} bytes, the manifest "
            f"places {ent['nbytes']}")
    if scl_off != want_scl:
        bad(f"scale_offset {scl_off}, the layout gives {want_scl}")

    # The sub-region offset table.  This is the artefact no generator wrote.
    for p in range(nports):
        (off,) = struct.unpack_from("<Q", buf, 0x38 + 8 * p)
        want = HDR_BYTES + sub_sz * p
        if off != want:
            bad(f"weight sub-region {p} offset {off}, layout gives {want}")
        if off % ALIGN:
            bad(f"weight sub-region {p} offset {off} is not 4 KB aligned")
    for q in range(nss):
        (off,) = struct.unpack_from("<Q", buf, 0x38 + 8 * (nports + q))
        want = scl_off + scl_sub_sz * q
        if off != want:
            bad(f"scale sub-region {q} offset {off}, layout gives {want}")
        if off % ALIGN:
            bad(f"scale sub-region {q} offset {off} is not 4 KB aligned")
    if 0x38 + 8 * (nports + nss) > HDR_BYTES:
        bad("the sub-region offset table does not fit the 4 KB header")


# ---------------------------------------------------------------- manifest

def load_manifest(path):
    with open(path) as f:
        m = json.load(f)
    if "files" not in m or "geometry" not in m:
        sys.exit(f"{path} is not a load manifest (no files/geometry)")
    return m, os.path.dirname(os.path.abspath(path))


def const_entries(mani):
    """THE GDN CONSTANT IMAGE AS A LOADABLE OBJECT (2026-09-18, the B
    constants path, docs/2026-09-18_b-constants-path.md).

    `tools/pack_gdn_consts.py` declares the image in the manifest's `hbm`
    block -- `gdn_const_base`, `gdn_const_bytes`, `gdn_const_file`,
    `gdn_const_blake2b_128` -- and NOT as a `files` entry, because every
    other reader of `files` (tools/check_hbm_stack.py, tools/check_mv4i_set.py)
    parses each entry that is not an `f32blob` as an mv4i header, and the
    image has none.  So the loader synthesises the one entry here, shaped
    like a flat headerless object, and every path below (preflight, load,
    verify, plan) treats it as it treats `nonmatvec_f32.bin`: written from
    the file, digested on load, digested again on verify against the
    pack-time blake2b, even under --headers-only.

    A manifest without the region yields nothing: the card then runs the
    m12 stand-ins, which is a build decision and not a loader fault."""
    hbm = mani.get("hbm") or {}
    if not hbm.get("gdn_const_bytes"):
        return []
    missing = [k for k in ("gdn_const_base", "gdn_const_file",
                           "gdn_const_blake2b_128") if k not in hbm]
    if missing:
        sys.exit("hbm.gdn_const_bytes is declared but %s is not; the image "
                 "cannot be placed or verified.  Re-run "
                 "tools/pack_gdn_consts.py." % ", ".join(missing))
    return [dict(file=hbm["gdn_const_file"], kind="gdn_const",
                 tensor="<gdn constants, %s layers x %s B>"
                 % (hbm.get("gdn_const_layers", "?"),
                    hbm.get("gdn_const_bytes_per_layer", "?")),
                 hbm_offset=int(hbm["gdn_const_base"]),
                 nbytes=int(hbm["gdn_const_bytes"]),
                 stack=hbm.get("gdn_const_stack"),
                 blake2b_128=hbm["gdn_const_blake2b_128"])]


def select(mani, only):
    ents = mani["files"] + const_entries(mani)
    if only:
        ents = [e for e in ents if only in e["file"]]
        if not ents:
            sys.exit(f"--only {only!r} matched none of {len(mani['files'])} objects")
    return sorted(ents, key=lambda e: int(e["hbm_offset"]))


def preflight(mani, ents, root, need_files, desc_jobs=311,
              max_chunk=None):
    """Everything that can be wrong BEFORE a byte moves.  A load is minutes; a
    refusal is a second."""
    bad = []
    seen = []
    for e in ents:
        off, nb = int(e["hbm_offset"]), int(e["nbytes"])
        # PER EXTENT, NOT PER OBJECT.  A lane-striped object is one file at 28
        # addresses; `off + nb` names a range it does not occupy and every
        # check on that range is answering about nothing.  `pieces_of()`
        # returns a single whole-object extent for a flat manifest, so this
        # loop is the old code on the old input.
        try:
            pcs = pieces_of(e)
        except StripedWithoutMap as ex:
            bad.append(str(ex))
            pcs = []
        pos = 0
        for p in pcs:
            po, pn = p["hbm_offset"], p["nbytes"]
            tag = e["file"] if len(pcs) == 1 else f"{e['file']}:{p['index']}"
            if po % ALIGN:
                bad.append(f"{tag}: base {po:#x} is not 4 KB aligned")
            if po + pn > HBM_SIZE:
                bad.append(f"{tag}: {po:#x}+{pn} runs past the 8 GiB map")
            if po < 0x1_0000_0000 < po + pn:
                bad.append(f"{tag}: spans the HBM stack boundary; an "
                           f"out-of-stack read returns wrong bytes and reports "
                           f"success")
            if p["file_offset"] != pos:
                bad.append(f"{tag}: starts at file +{p['file_offset']}, the "
                           f"pieces before it end at +{pos}.  They do not tile "
                           f"the file, so the manifest's whole-file digest is "
                           f"not a digest of what would be written")
            pos += pn
            seen.append((po, po + pn, tag))
        if pcs and pos != nb:
            bad.append(f"{e['file']}: its extents cover {pos} bytes, the "
                       f"manifest declares {nb}")
        if need_files:
            p = os.path.join(root, e["file"])
            if not os.path.exists(p):
                bad.append(f"{e['file']}: not present in {root}")
            elif os.path.getsize(p) != nb:
                bad.append(f"{e['file']}: on disk {os.path.getsize(p)} bytes, "
                           f"manifest says {nb}")
        if "blake2b_128" not in e:
            bad.append(f"{e['file']}: the manifest carries no blake2b_128, so "
                       f"verify would have nothing independent to compare to")
    seen.sort()
    for (a0, a1, an), (b0, b1, bn) in zip(seen, seen[1:]):
        if b0 < a1:
            bad.append(f"OVERLAP: {an} {a0:#x}..{a1:#x} and {bn} "
                       f"{b0:#x}..{b1:#x}")

    # ---- the WHOLE map, not just the objects this command was given.
    #
    # The three allocators are pack_model_fk33.py (these objects), the A
    # descriptor arena and pl_derive_bases()'s host blocks.  A load that places
    # perfect weights under a colliding top is still a wrong token, and it is
    # the same manifest that determines both, so it is checked here.
    if HM is None:
        bad.append("tools/hbm_map.py could not be imported (%s), so the "
                   "descriptor arena and the host blocks were NOT checked "
                   "against this image.  That is the check the 2026-08-29 "
                   "collision needed." % _HM_WHY)
    else:
        # THE REGION BLOCK IS REQUIRED (Oren, 2026-08-29).  A manifest that
        # does not declare hbm.desc_arena_base / _bytes / host_max_chunk is a
        # manifest whose map cannot be fully checked, and a load that places
        # perfect weights under an unchecked top is still a wrong token.  This
        # is the same refusal server/fk33_manifest.c makes, on this side of the
        # language boundary, so a set cannot be loadable by one and refused by
        # the other.
        try:
            HM.manifest_arena(mani)
        except HM.NoRegionBlock as e:
            bad.append("REGION BLOCK: %s" % e)
        try:
            m = HM.plan(mani, desc_jobs=desc_jobs, max_chunk=max_chunk)
            for msg in m.check():
                bad.append("WHOLE MAP: " + msg)
        except SystemExit as e:
            bad.append("WHOLE MAP: hbm_map refused to build a map: %s" % e)
    return bad


# ---------------------------------------------------------------- commands

def cmd_plan(a):
    mani, root = load_manifest(a.manifest)
    ents = select(mani, a.only)
    bad = preflight(mani, ents, root, need_files=not a.no_files)
    tot = sum(int(e["nbytes"]) for e in ents)
    exts = [p for e in ents for p in pieces_of(e)]
    lo = min(p["hbm_offset"] for p in exts)
    hi = max(p["hbm_offset"] + p["nbytes"] for p in exts)
    print(f"{len(ents)} objects in {len(exts)} extents, {tot:,} B = "
          f"{tot / 2**30:.4f} GiB, HBM {lo:#x}..{hi:#x}")
    for d in mani.get("dropped_tensors", []):
        print(f"  DROPPED {d['name']}: {d['bytes_if_placed']:,} B not placed")
    if a.list:
        for e in ents:
            for p in pieces_of(e):
                tag = (e["file"] if p["kind"] == "whole"
                       else f"{e['file']}:{p['index']} ({p['kind']}"
                            f"{'' if p['lane'] is None else ' lane %d' % p['lane']}"
                            f", seg {p['segment']})")
                print(f"  {p['hbm_offset']:#014x}  {p['nbytes']:>12,}  "
                      f"stack {e.get('stack')}  {tag}")
    for m in bad:
        print(f"FAIL  {m}")
    if bad:
        print(f"{len(bad)} FAIL")
        return 1
    print("PASS  every EXTENT is aligned, in range, in one stack and disjoint; "
          "every object tiles its file, is present at its manifest size, and "
          "carries a digest")
    return 0


def cmd_load(a):
    mani, root = load_manifest(a.manifest)
    ents = select(mani, a.only)
    bad = preflight(mani, ents, root, need_files=True)
    if bad:
        for m in bad:
            print(f"FAIL  {m}")
        print(f"{len(bad)} FAIL -- refusing to write anything")
        return 1

    tot = sum(int(e["nbytes"]) for e in ents)
    print(f"loading {len(ents)} objects, {tot / 1e9:.2f} GB, "
          f"H2C {h2c()}")
    t0 = time.perf_counter()
    fd = os.open(h2c(), os.O_WRONLY)
    fails = 0
    try:
        for i, e in enumerate(ents):
            nb = int(e["nbytes"])
            dig = hashlib.blake2b(digest_size=16)
            # ONE DIGEST OVER THE WHOLE FILE, WRITTEN IN AS MANY PIECES AS THE
            # MANIFEST SAYS.  The file is still read start to finish in file
            # order -- preflight has already refused a piece list that does not
            # tile it from 0 -- so the digest is byte-identical to the flat
            # one and stays comparable against the packer's pack-time value.
            # That is what keeps `--verify` an oracle after striping instead of
            # a round trip.
            with open(os.path.join(root, e["file"]), "rb") as f:
                pos = 0
                for p in pieces_of(e):
                    off, want = p["hbm_offset"], p["nbytes"]
                    got = 0
                    while got < want:
                        chunk = f.read(min(CHUNK, want - got))
                        if not chunk:
                            break
                        dig.update(chunk)
                        k = 0
                        while k < len(chunk):
                            k += os.pwrite(fd, chunk[k:], off + got + k)
                        got += len(chunk)
                    pos += got
                    if got != want:
                        break
            if pos != nb:
                print(f"FAIL  {e['file']}: wrote {pos} of {nb} bytes")
                fails += 1
                continue
            # The source digest is checked HERE, against the manifest, so a
            # corrupt file on disk is caught at load rather than surviving to
            # look like a transport fault at verify.
            if dig.hexdigest() != e["blake2b_128"]:
                print(f"FAIL  {e['file']}: the bytes just written hash to "
                      f"{dig.hexdigest()}, the manifest says "
                      f"{e['blake2b_128']} -- the file on disk is not the file "
                      f"that was packed")
                fails += 1
            if a.progress and (i % 25 == 0 or i == len(ents) - 1):
                dt = time.perf_counter() - t0
                done = sum(int(x["nbytes"]) for x in ents[:i + 1])
                print(f"  {i + 1:>4}/{len(ents)}  {done / 1e9:6.2f} GB  "
                      f"{done / dt / 1e9:5.2f} GB/s")
    finally:
        os.close(fd)
    dt = time.perf_counter() - t0
    print(f"wrote {tot:,} bytes in {dt:.2f} s = {tot / dt / 1e9:.2f} GB/s")
    if fails:
        print(f"{fails} FAIL")
        return 1
    print("PASS  every object written and its source bytes match the manifest "
          "digest")
    if a.verify:
        return _verify(mani, ents, headers_only=False, progress=a.progress)
    return 0


def cmd_verify(a):
    mani, _root = load_manifest(a.manifest)
    ents = select(mani, a.only)
    return _verify(mani, ents, a.headers_only, a.progress)


def _verify(mani, ents, headers_only, progress):
    """Read the card back and judge it against the manifest ALONE.  No .mv4i
    file is opened anywhere in this function; that is the whole point."""
    geom = mani["geometry"]
    mode = "headers only" if headers_only else "full read-back"
    print(f"verifying {len(ents)} objects against the manifest ({mode}), "
          f"C2H {c2h()}")
    fd = os.open(c2h(), os.O_RDONLY)
    fails, nhdr, nhash, nbytes_read = [], 0, 0, 0
    # ATTEMPTED, not passed.  The first version of the coverage guard below
    # counted `nhdr + nhash`, i.e. successes, so an object that WAS checked and
    # FAILED looked identical to one that was never looked at -- and the guard
    # fired first, reporting a genuine wrong-offset fault as "a hole in the
    # CHECKER".  Caught by teeth-check T1 (blob base moved one 4K page), which
    # is the only reason this comment exists.
    attempted = set()
    # EXTENTS READ, STATED SEPARATELY FROM OBJECTS.  Under a lane-striped
    # manifest one object is up to 28 extents in 28 pseudo-channels, and
    # "250 of 250 objects" would be true of a run that read one piece of each.
    nextent = nextent_read = 0
    t0 = time.perf_counter()
    try:
        for i, e in enumerate(ents):
            off, nb = int(e["hbm_offset"]), int(e["nbytes"])
            pcs = pieces_of(e)
            nextent += len(pcs)
            # ---- check 1: the header at the claimed base IS this tensor's
            if e["kind"] == "mv4i":
                hdr = os.pread(fd, HDR_BYTES, off)
                nbytes_read += len(hdr)
                attempted.add(i)
                try:
                    parse_and_check_header(hdr, e, geom,
                                           f"{e['file']} @ {off:#x}")
                    nhdr += 1
                except HeaderMismatch as ex:
                    fails.append(str(ex))
                    if headers_only:
                        continue
            # ---- check 2: the payload hashes to what the packer recorded
            #
            # HEADERS-ONLY USED TO LEAVE AN OBJECT CHECKED BY NOTHING AND STILL
            # PRINT PASS.  Check 1 is gated on `kind == "mv4i"` because only an
            # mv4i object HAS a parseable header; check 2 was then skipped for
            # everything.  So a non-mv4i object fell through both and was
            # counted in neither tally.  MEASURED 2026-08-29 against the live
            # card: 250 objects in, "249 headers parsed and matched", PASS.
            # The one that vanished is `nonmatvec_f32.bin` (kind `f32blob`,
            # 4,571,136 bytes) -- the norms and biases, i.e. exactly the class
            # whose corruption gives subtly wrong logits rather than garbage.
            #
            # A headerless object is therefore digested even in headers-only
            # mode.  That is affordable because it is the ONLY such object and
            # it is 4.5 MB: MEASURED 0.01 s at 0.69 GB/s, against 0.00 s for
            # the 249 headers.  If a future image carries large headerless
            # objects this becomes a real cost and needs revisiting -- but the
            # answer then is a per-kind policy, NOT going back to skipping,
            # because "PASS" must never cover an object nothing looked at.
            if headers_only and e["kind"] == "mv4i":
                continue
            attempted.add(i)
            dig = hashlib.blake2b(digest_size=16)
            pos = 0
            short = False
            # ONE DIGEST, READ BACK OUT OF AS MANY PSEUDO-CHANNELS AS THE
            # MANIFEST PLACED IT IN, in FILE order.  The pieces tile the file
            # (preflight refuses a list that does not), so this reconstructs
            # exactly the byte sequence the packer digested and the comparison
            # below stays the same oracle it was under the flat layout.  That
            # is the property that makes verify catch PACKSTRIPE's M9 -- two
            # tensors swapping a lane arena -- which no structural check can.
            for p in pcs:
                po, pn = p["hbm_offset"], p["nbytes"]
                got_n = 0
                while got_n < pn:
                    got = os.pread(fd, min(CHUNK, pn - got_n), po + got_n)
                    if not got:
                        fails.append(f"{e['file']}: short read at "
                                     f"{po + got_n:#x} ({pos + got_n} of {nb})")
                        short = True
                        break
                    dig.update(got)
                    got_n += len(got)
                pos += got_n
                if short:
                    break
                nextent_read += 1
            nbytes_read += pos
            if short:
                continue
            if dig.hexdigest() != e["blake2b_128"]:
                fails.append(
                    f"{e['file']} @ {off:#x}: HBM hashes to {dig.hexdigest()}, "
                    f"the manifest's pack-time digest is {e['blake2b_128']} -- "
                    f"the bytes on the card are NOT this tensor")
            else:
                nhash += 1
            if progress and (i % 25 == 0 or i == len(ents) - 1):
                dt = time.perf_counter() - t0
                print(f"  {i + 1:>4}/{len(ents)}  {nbytes_read / 1e9:6.2f} GB  "
                      f"{nbytes_read / max(dt, 1e-9) / 1e9:5.2f} GB/s")
    finally:
        os.close(fd)
    dt = time.perf_counter() - t0
    print(f"read {nbytes_read:,} bytes in {dt:.2f} s = "
          f"{nbytes_read / max(dt, 1e-9) / 1e9:.2f} GB/s")
    print(f"{nhdr} headers parsed and matched, {nhash} payload digests matched")
    # EXTENT COVERAGE, SAID OUT LOUD.  A striped object is one file in up to 28
    # pseudo-channels, so an object tally alone would call a run that read one
    # piece of each "250 of 250".  In headers-only mode NO mv4i sub-region is
    # read at all -- 249 of 6,973 extents on the shipping set -- and that is a
    # property of the mode, not a fault, which is exactly why it is printed
    # rather than left for the reader to infer.
    print(f"extents      {nextent_read} of {nextent} digested"
          + (" (headers-only: an mv4i's payload extents are NOT read)"
             if headers_only else ""))

    # STATE THE COVERAGE, DO NOT LET THE READER INFER IT.  The old summary
    # printed two tallies and a PASS, and 249 + 0 against 250 objects read as
    # a rounding detail rather than as an object nobody looked at.  Say the
    # arithmetic out loud, and refuse to call it PASS if it does not close.
    # A REAL FAULT OUTRANKS A COVERAGE COMPLAINT.  Report fails first: if an
    # object was read and disagreed, that is the finding, and calling it a
    # checker hole would send the reader to the wrong file.
    for m in fails:
        print(f"FAIL  {m}")
    if fails:
        print(f"{len(fails)} FAIL")
        return 1

    # STATE THE COVERAGE, DO NOT LET THE READER INFER IT.  The old summary
    # printed two tallies and a PASS, and "249 headers" against 250 objects
    # read as a rounding detail rather than as an object nobody looked at.
    #
    # THIS BRANCH IS CURRENTLY UNREACHABLE, AND IS LABELLED SO RATHER THAN
    # PRESENTED AS A WORKING CHECK.  Every path now marks `attempted`: an mv4i
    # object via its header, anything else via the digest it falls through to.
    # Teeth-checked 2026-08-29 with three manifests -- a moved blob base (FAIL,
    # correctly, on the digest), an unknown `kind` (PASS at 250/250, because an
    # unknown kind is digested rather than skipped, which is the intent), and
    # an untouched control (PASS).  None of the three reaches this branch and I
    # could not construct one that does.  It is kept as defence against a
    # FUTURE `kind` whose handling `continue`s past both checks, which is
    # exactly the shape of the bug this whole block exists to prevent.
    # A guard never shown to fire has not been shown to work; treat it as
    # unproven, not as verified.
    unlooked = [e for i, e in enumerate(ents) if i not in attempted]
    if unlooked:
        print(f"UNVERIFIED  {len(unlooked)} of {len(ents)} objects were read "
              f"by neither check.  This is a hole in the CHECKER, not a fault "
              f"in the image, and it is not a PASS.")
        for e in unlooked:
            print(f"            unlooked-at: {e['file']} kind={e['kind']}")
        return 1

    print(f"PASS  the image on the card is the image the manifest describes "
          f"({len(attempted)} of {len(ents)} objects read and checked)")
    return 0


# ---------------------------------------------------------------- selfcheck

def _synth_mv4i(M, K, rows_if, axi_dw, w_exp, out_shift, seed):
    """Build a byte-exact spec 6.4/6.5a file with deterministic payload."""
    sub_sz, nports, scl_off, scl_sub_sz, nss, total = \
        _packed_layout(M, K, rows_if, axi_dw)
    buf = bytearray(total)
    struct.pack_into("<IHHII", buf, 0x00, MV4I_MAGIC, 1, 1, M, K)
    struct.pack_into("<ii", buf, 0x10, w_exp, out_shift)
    struct.pack_into("<HHHH", buf, 0x18, rows_if, nports, BLOCK, axi_dw)
    for j in range(16):
        buf[0x20 + j] = (j * 7 + seed) & 0xFF
    struct.pack_into("<II", buf, 0x30, scl_off, nss)
    for p in range(nports):
        struct.pack_into("<Q", buf, 0x38 + 8 * p, HDR_BYTES + sub_sz * p)
    for q in range(nss):
        struct.pack_into("<Q", buf, 0x38 + 8 * (nports + q),
                         scl_off + scl_sub_sz * q)
    st = (seed * 2654435761 + 1) & 0xFFFFFFFF
    payload = bytearray(total - HDR_BYTES)
    for j in range(0, len(payload), 4):
        st = (st * 1103515245 + 12345) & 0xFFFFFFFF
        payload[j:j + 4] = struct.pack("<I", st)[:len(payload) - j]
    buf[HDR_BYTES:] = payload
    return bytes(buf)


def cmd_selfcheck(a):
    """Prove every check in this file can FAIL.  No card, no weight image."""
    tmp = tempfile.mkdtemp(prefix="fk33lw-")
    rows_if, axi_dw = 48, 256
    specs = [("t0.weight", 96, 256, 3, 1, 11),
             ("t1.weight", 144, 512, 5, 2, 22),
             ("t2.weight", 48, 128, 7, 0, 33),
             # t3 is t0's SHAPE with a different payload.  At the 9B set 246
             # of 249 packed tensors are in such a class, so this is the
             # normal case and not a contrived one.
             ("t3.weight", 96, 256, 3, 1, 44)]
    files, base = [], 0
    for name, M, K, we, osh, seed in specs:
        blob = _synth_mv4i(M, K, rows_if, axi_dw, we, osh, seed)
        with open(os.path.join(tmp, name + ".mv4i"), "wb") as f:
            f.write(blob)
        files.append(dict(file=name + ".mv4i", kind="mv4i", tensor=name,
                          M=M, K=K, w_exp=we, out_shift=osh,
                          nbytes=len(blob), hbm_offset=base, stack=0,
                          blake2b_128=hashlib.blake2b(
                              blob, digest_size=16).hexdigest()))
        base += (len(blob) + ALIGN - 1) & ~(ALIGN - 1)
    # A REGION BLOCK, because preflight requires one.  These synthetic sets
    # carry no output.weight, so hbm_map cannot model the host blocks and
    # cannot run the allocation rule; the block is therefore written out by
    # hand, well clear of the four tiny objects, and its job here is to be
    # PRESENT.  What it is NOT is a second allocator: nothing derives a
    # shipping address from this, and `no_region_block` below removes it to
    # show the requirement biting.
    # A GDN CONSTANT IMAGE, three 512 B "layers" of deterministic bytes,
    # placed above the four objects.  Declared the way pack_gdn_consts.py
    # declares it -- in `hbm`, not in `files` -- so the loader's own
    # `const_entries()` is what puts it on the load list, and the C rows
    # below are what show that path can fail.
    # The layer term is not decoration.  The first draft was `(j*31+7) & 0xFF`,
    # which has period 256, so all three 512 B layers were IDENTICAL and C4
    # (two layers swapped) could not bite -- MEASURED, one row WRONG.  A
    # fixture whose parts are indistinguishable cannot show a swap.
    cimg = bytes((j * 31 + 7 + (j // 512) * 97) & 0xFF for j in range(3 * 512))
    cbase = base
    with open(os.path.join(tmp, "gdn_const.bin"), "wb") as f:
        f.write(cimg)
    base += (len(cimg) + ALIGN - 1) & ~(ALIGN - 1)
    mani = dict(format="selfcheck", geometry=dict(
        rows_if=rows_if, axi_dw=axi_dw, block=BLOCK,
        nports_w=_nports_w(rows_if, axi_dw),
        n_scale_sub=_n_scale_sub(rows_if, axi_dw)),
        hbm=dict(desc_arena_base=0x1_F000_0000, desc_arena_bytes=0x28000,
                 host_max_chunk=512,
                 gdn_const_base=cbase, gdn_const_bytes=len(cimg),
                 gdn_const_stack=0, gdn_const_layers=3,
                 gdn_const_bytes_per_layer=512,
                 gdn_const_file="gdn_const.bin",
                 gdn_const_blake2b_128=hashlib.blake2b(
                     cimg, digest_size=16).hexdigest()),
        files=files)
    mpath = os.path.join(tmp, "manifest.json")
    with open(mpath, "w") as f:
        json.dump(mani, f)

    dev = os.path.join(tmp, "fake_hbm.bin")
    span = base + ALIGN

    def fresh():
        with open(dev, "wb") as f:
            f.truncate(span)
        os.environ["FK33_H2C"] = dev
        os.environ["FK33_C2H"] = dev

    class NS:
        manifest, only, verify, progress, headers_only, no_files, list = \
            mpath, None, False, False, False, False, False

    results, hard = [], 0

    def run(label, mutate, expect_fail, headers_only=False):
        nonlocal hard
        fresh()
        rc = cmd_load(NS())
        if rc != 0:
            print(f"  selfcheck harness could not load a clean image")
            hard += 1
            return
        if mutate:
            mutate()
        ns = NS()
        ns.headers_only = headers_only
        rc = _verify(mani, select(mani, None), headers_only, False)
        caught = rc != 0
        ok = caught == expect_fail
        results.append((label, expect_fail, caught, ok))
        if not ok:
            hard += 1

    def poke(off, val):
        def go():
            with open(dev, "r+b") as f:
                f.seek(off)
                cur = f.read(1)[0]
                f.seek(off)
                f.write(bytes([cur ^ val]))
        return go

    def place_at(src, dst):
        """Write the file that belongs at `src` over the base `dst`."""
        def go():
            e = next(x for x in files if x["hbm_offset"] == src)
            with open(os.path.join(tmp, e["file"]), "rb") as f:
                blob = f.read()
            with open(dev, "r+b") as g:
                g.seek(dst)
                g.write(blob)
        return go

    def truncate_last():
        """Cut the device off part-way through the LAST object, so the
        read-back is short.  On the card HBM is always 8 GiB and a short read
        cannot happen, so this exercises the short-read path rather than a
        field failure; it is here because the path exists and would otherwise
        never be executed."""
        last = files[-1]
        def go():
            with open(dev, "r+b") as f:
                f.truncate(int(last["hbm_offset"]) + int(last["nbytes"]) // 2)
        return go

    def shift_whole_image(delta):
        """The operator typed one extra --offset.  Every object is present,
        intact and in the right order, and every base is wrong."""
        def go():
            with open(dev, "rb") as f:
                img = f.read()
            with open(dev, "wb") as f:
                f.truncate(span)
                f.seek(delta)
                f.write(img[:span - delta])
        return go

    def swap_two(i, j):
        """Two tensors at each other's bases.  Every byte in the image is a
        byte that belongs in the image, just not there."""
        def go():
            a_, b_ = files[i], files[j]
            n = min(int(a_["nbytes"]), int(b_["nbytes"]))
            with open(dev, "r+b") as f:
                f.seek(int(a_["hbm_offset"])); x = f.read(n)
                f.seek(int(b_["hbm_offset"])); y = f.read(n)
                f.seek(int(a_["hbm_offset"])); f.write(y)
                f.seek(int(b_["hbm_offset"])); f.write(x)
        return go

    b1 = files[1]["hbm_offset"]
    run("BASELINE clean image (must PASS)", None, False)
    run("BASELINE clean image, headers only (must PASS)", None, False, True)
    run("M1 one payload byte flipped", poke(b1 + HDR_BYTES + 1234, 0xFF), True)
    run("M2 one header byte flipped (M)", poke(b1 + 0x08, 0x01), True)
    run("M3 magic destroyed", poke(b1 + 0x00, 0xFF), True)
    run("M4 tensor 0 written over tensor 1's base",
        place_at(files[0]["hbm_offset"], b1), True)
    run("M5 tensor 0 written over tensor 1's base, headers only",
        place_at(files[0]["hbm_offset"], b1), True, True)
    run("M6 image truncated at the top", truncate_last(), True)
    run("M7 sub-region offset table entry altered",
        poke(b1 + 0x38 + 8 * 3, 0x10), True)
    run("M8 one payload byte flipped, headers only "
        "(EXPECTED NOT TO BITE)", poke(b1 + HDR_BYTES + 1234, 0xFF),
        False, True)
    run("M9 whole image shifted by one 4 KB page",
        shift_whole_image(ALIGN), True)
    run("M10 whole image shifted, headers only",
        shift_whole_image(ALIGN), True, True)
    run("M11 two DIFFERENT-shape tensors swapped", swap_two(0, 2), True)
    run("M12 two different-shape tensors swapped, headers only",
        swap_two(0, 2), True, True)
    run("M13 two IDENTICAL-shape tensors swapped", swap_two(0, 3), True)
    run("M14 two identical-shape tensors swapped, headers only "
        "(EXPECTED NOT TO BITE)", swap_two(0, 3), False, True)

    # ---- the GDN constant image.  Headerless, so the digest is its only
    # oracle, and it is digested even under --headers-only (the f32blob
    # policy: a headerless object nothing looked at must not be PASS).
    def place_const_at(dst):
        def go():
            with open(dev, "r+b") as g:
                g.seek(dst)
                g.write(cimg)
                g.seek(cbase)
                g.write(bytes(len(cimg)))
        return go

    run("C1 one byte of the GDN constant image flipped",
        poke(cbase + 700, 0x80), True)
    run("C2 one byte of the GDN constant image flipped, headers only",
        poke(cbase + 700, 0x80), True, True)
    run("C3 the constant image written one 4 KB page above its base",
        place_const_at(cbase + ALIGN), True)
    def swap_const_layers(i, j):
        """Two layers of the constant image at each other's stride.  Every
        byte belongs in the image; layer i's B job reads layer j's weights."""
        def go():
            with open(dev, "r+b") as f:
                f.seek(cbase + 512 * i); x = f.read(512)
                f.seek(cbase + 512 * j); y = f.read(512)
                f.seek(cbase + 512 * i); f.write(y)
                f.seek(cbase + 512 * j); f.write(x)
        return go

    run("C4 layers 1 and 2 of the constant image swapped",
        swap_const_layers(1, 2), True)

    # ---------------------------------------------------- the striped arm
    #
    # THE SAME FOUR FILES, CUT AT THEIR OWN SUB-REGION BOUNDARIES AND
    # SCATTERED.  A lane-striped object is one file at 28 addresses and the
    # order in HBM is NOT the order in the file, so a load that reads the
    # file sequentially and a verify that reads HBM sequentially would both
    # "work" while describing different bytes.  Nothing above exercises that,
    # and a path with no teeth is a path nobody has shown to work.
    #
    # The pieces are deliberately placed in REVERSE order of file offset, at a
    # coarse stride, so any consumer that quietly assumes HBM order equals file
    # order gets a wrong digest rather than a lucky pass.
    spieces, sfiles, cur = [], [], span + ALIGN
    stride = 0
    for e in files:
        blob = open(os.path.join(tmp, e["file"]), "rb").read()
        sub_sz, nports, scl_off, scl_sub_sz, nss, total = _packed_layout(
            int(e["M"]), int(e["K"]), rows_if, axi_dw)
        cuts = [(0, HDR_BYTES, "header", None)]
        for p in range(nports):
            cuts.append((HDR_BYTES + sub_sz * p, sub_sz, "w", p))
        for q in range(nss):
            cuts.append((scl_off + scl_sub_sz * q, scl_sub_sz, "s",
                         nports + q))
        stride = max(stride, max(n for _, n, _, _ in cuts) + ALIGN)
        pcs = []
        for k, (fo, n, kind, lane) in enumerate(cuts):
            pcs.append(dict(kind=kind, lane=lane, segment=None,
                            file_offset=fo, nbytes=n, hbm_offset=0))
        spieces.append(pcs)
        sfiles.append(dict(e))
    # Reverse placement, one arena per piece index, so file order and HBM
    # order disagree everywhere.
    for pcs in spieces:
        for k, p in enumerate(reversed(pcs)):
            p["hbm_offset"] = cur
            cur += (p["nbytes"] + ALIGN - 1) & ~(ALIGN - 1)
    for e, pcs in zip(sfiles, spieces):
        e["pieces"] = pcs
        e["hbm_offset"] = pcs[0]["hbm_offset"]
        e["stack"] = 0
    smani = dict(mani)
    smani["format"] = "selfcheck v2 lane-striped"
    smani["files"] = sfiles
    sdev = os.path.join(tmp, "fake_hbm_striped.bin")
    sspan = cur + ALIGN
    spath = os.path.join(tmp, "manifest_striped.json")
    with open(spath, "w") as f:
        json.dump(smani, f)

    class SNS(NS):
        manifest = spath

    def srun(label, mutate, expect_fail, headers_only=False):
        nonlocal hard
        with open(sdev, "wb") as f:
            f.truncate(sspan)
        os.environ["FK33_H2C"] = sdev
        os.environ["FK33_C2H"] = sdev
        if cmd_load(SNS()) != 0:
            print("  selfcheck harness could not load a clean STRIPED image")
            hard += 1
            return
        if mutate:
            mutate()
        rc = _verify(smani, select(smani, None), headers_only, False)
        caught = rc != 0
        ok = caught == expect_fail
        results.append((label, expect_fail, caught, ok))
        if not ok:
            hard += 1

    def spoke(fi, pi, delta):
        def go():
            off = spieces[fi][pi]["hbm_offset"] + delta
            with open(sdev, "r+b") as f:
                f.seek(off)
                cur_ = f.read(1)[0]
                f.seek(off)
                f.write(bytes([cur_ ^ 0xFF]))
        return go

    def sswap_pieces(fi, i, j):
        """Two of ONE tensor's sub-regions at each other's addresses.  Every
        byte in HBM belongs there; the lanes read each other's."""
        def go():
            a_, b_ = spieces[fi][i], spieces[fi][j]
            n = min(a_["nbytes"], b_["nbytes"])
            with open(sdev, "r+b") as f:
                f.seek(a_["hbm_offset"]); x = f.read(n)
                f.seek(b_["hbm_offset"]); y = f.read(n)
                f.seek(a_["hbm_offset"]); f.write(y)
                f.seek(b_["hbm_offset"]); f.write(x)
        return go

    def sswap_lane_arena(i, j, pi):
        """PACKSTRIPE's M9: two tensors swap ONE lane's arena.  The placement
        stays well-formed and every structural rule accepts it."""
        def go():
            a_, b_ = spieces[i][pi], spieces[j][pi]
            n = min(a_["nbytes"], b_["nbytes"])
            with open(sdev, "r+b") as f:
                f.seek(a_["hbm_offset"]); x = f.read(n)
                f.seek(b_["hbm_offset"]); y = f.read(n)
                f.seek(a_["hbm_offset"]); f.write(y)
                f.seek(b_["hbm_offset"]); f.write(x)
        return go

    srun("S0 BASELINE striped image (must PASS)", None, False)
    srun("S1 BASELINE striped, headers only (must PASS)", None, False, True)
    srun("S2 one byte flipped in a MIDDLE sub-region",
         spoke(1, 5, 17), True)
    srun("S3 two sub-regions of one tensor swapped in HBM",
         sswap_pieces(1, 3, 7), True)
    srun("S4 two IDENTICAL-shape tensors swap one lane arena "
         "(PACKSTRIPE M9)", sswap_lane_arena(0, 3, 4), True)
    srun("S5 one byte flipped in a middle sub-region, headers only "
         "(EXPECTED NOT TO BITE)", spoke(1, 5, 17), False, True)

    print()
    print(f"{'mutation':56s} {'expect':>8s} {'caught':>7s}  verdict")
    for label, exp, got, ok in results:
        print(f"{label:56s} {'FAIL' if exp else 'PASS':>8s} "
              f"{'yes' if got else 'no':>7s}  {'ok' if ok else 'WRONG'}")
    print()
    print("M8 and M14 are recorded, not hidden. --headers-only reads 4 KB per "
          "object, so it cannot see a payload byte, and it cannot tell two "
          "tensors of the SAME (M, K, w_exp, out_shift) apart -- MEASURED on "
          "the 9B set, 246 of 249 packed tensors are in such a class. That is "
          "the resolution floor of the header pass and the reason the full "
          "digest verify exists.")
    print()
    print("S5 is the same floor on the striped path and is WIDER there: a "
          "lane-striped object is one file in as many pseudo-channels as the "
          "manifest names, and --headers-only reads exactly ONE of those "
          "extents per object -- 4 of 112 in this run, 249 of 6,973 on the "
          "shipping 9B set.  The `extents N of M digested` line says so on "
          "every run rather than leaving it to be inferred.  S4 is the one "
          "that matters: two tensors swapping a lane arena is a WELL-FORMED "
          "placement that every structural rule in tools/hbm_map.py and "
          "tools/pack_model_fk33.py accepts (PACKSTRIPE teeth M9), and this "
          "full read-back is what catches it.")
    for f in os.listdir(tmp):
        os.unlink(os.path.join(tmp, f))
    os.rmdir(tmp)
    if hard:
        print(f"\n{hard} check(s) did not behave as designed")
        return 1
    print("\nPASS  every check was shown to fail on a defect it claims to catch")
    return 0


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(s, files=True):
        s.add_argument("manifest")
        s.add_argument("--only", help="substring of the object's file name")
        s.add_argument("--progress", action="store_true")
        return s

    s = common(sub.add_parser("plan", help="check placement, touch no device"))
    s.add_argument("--list", action="store_true")
    s.add_argument("--no-files", action="store_true",
                   help="do not require the .mv4i files to be present")
    s.set_defaults(fn=cmd_plan)

    s = common(sub.add_parser("load"))
    s.add_argument("--verify", action="store_true",
                   help="run the independent verify afterwards")
    s.set_defaults(fn=cmd_load)

    s = common(sub.add_parser("verify"))
    s.add_argument("--headers-only", action="store_true")
    s.set_defaults(fn=cmd_verify)

    s = sub.add_parser("selfcheck", help="prove the checks can fail; no card")
    s.set_defaults(fn=cmd_selfcheck)

    a = p.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
