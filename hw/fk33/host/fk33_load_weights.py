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


def select(mani, only):
    ents = mani["files"]
    if only:
        ents = [e for e in ents if only in e["file"]]
        if not ents:
            sys.exit(f"--only {only!r} matched none of {len(mani['files'])} objects")
    return sorted(ents, key=lambda e: int(e["hbm_offset"]))


def preflight(mani, ents, root, need_files, desc_jobs=311,
              max_chunk=512):
    """Everything that can be wrong BEFORE a byte moves.  A load is minutes; a
    refusal is a second."""
    bad = []
    seen = []
    for e in ents:
        off, nb = int(e["hbm_offset"]), int(e["nbytes"])
        if off % ALIGN:
            bad.append(f"{e['file']}: base {off:#x} is not 4 KB aligned")
        if off + nb > HBM_SIZE:
            bad.append(f"{e['file']}: {off:#x}+{nb} runs past the 8 GiB map")
        if off < 0x1_0000_0000 < off + nb:
            bad.append(f"{e['file']}: spans the HBM stack boundary; an "
                       f"out-of-stack read returns wrong bytes and reports "
                       f"success")
        seen.append((off, off + nb, e["file"]))
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
    lo = min(int(e["hbm_offset"]) for e in ents)
    hi = max(int(e["hbm_offset"]) + int(e["nbytes"]) for e in ents)
    print(f"{len(ents)} objects, {tot:,} B = {tot / 2**30:.4f} GiB, "
          f"HBM {lo:#x}..{hi:#x}")
    for d in mani.get("dropped_tensors", []):
        print(f"  DROPPED {d['name']}: {d['bytes_if_placed']:,} B not placed")
    if a.list:
        for e in ents:
            print(f"  {int(e['hbm_offset']):#014x}  {int(e['nbytes']):>12,}  "
                  f"stack {e.get('stack')}  {e['file']}")
    for m in bad:
        print(f"FAIL  {m}")
    if bad:
        print(f"{len(bad)} FAIL")
        return 1
    print("PASS  every object is aligned, in range, in one stack, disjoint, "
          "present at its manifest size, and carries a digest")
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
            off, nb = int(e["hbm_offset"]), int(e["nbytes"])
            dig = hashlib.blake2b(digest_size=16)
            with open(os.path.join(root, e["file"]), "rb") as f:
                pos = 0
                while pos < nb:
                    chunk = f.read(min(CHUNK, nb - pos))
                    if not chunk:
                        break
                    dig.update(chunk)
                    k = 0
                    while k < len(chunk):
                        k += os.pwrite(fd, chunk[k:], off + pos + k)
                    pos += len(chunk)
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
    t0 = time.perf_counter()
    try:
        for i, e in enumerate(ents):
            off, nb = int(e["hbm_offset"]), int(e["nbytes"])
            # ---- check 1: the header at the claimed base IS this tensor's
            if e["kind"] == "mv4i":
                hdr = os.pread(fd, HDR_BYTES, off)
                nbytes_read += len(hdr)
                try:
                    parse_and_check_header(hdr, e, geom,
                                           f"{e['file']} @ {off:#x}")
                    nhdr += 1
                except HeaderMismatch as ex:
                    fails.append(str(ex))
                    if headers_only:
                        continue
            # ---- check 2: the payload hashes to what the packer recorded
            if headers_only:
                continue
            dig = hashlib.blake2b(digest_size=16)
            pos = 0
            short = False
            while pos < nb:
                got = os.pread(fd, min(CHUNK, nb - pos), off + pos)
                if not got:
                    fails.append(f"{e['file']}: short read at "
                                 f"{off + pos:#x} ({pos} of {nb})")
                    short = True
                    break
                dig.update(got)
                pos += len(got)
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
    for m in fails:
        print(f"FAIL  {m}")
    if fails:
        print(f"{len(fails)} FAIL")
        return 1
    print("PASS  the image on the card is the image the manifest describes")
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
    mani = dict(format="selfcheck", geometry=dict(
        rows_if=rows_if, axi_dw=axi_dw, block=BLOCK,
        nports_w=_nports_w(rows_if, axi_dw),
        n_scale_sub=_n_scale_sub(rows_if, axi_dw)), files=files)
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
        rc = _verify(mani, sorted(mani["files"],
                                  key=lambda e: e["hbm_offset"]),
                     headers_only, False)
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
