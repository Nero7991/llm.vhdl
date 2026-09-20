#!/usr/bin/env python3
"""fk33_imgfp.py -- the PLACEMENT fingerprint of a packed image, and the
512-byte record that says which one is resident on the card.

    fk33_imgfp.py print     MANIFEST.json      what this manifest fingerprints to
    fk33_imgfp.py read      MANIFEST.json      the record the card holds
    fk33_imgfp.py check     MANIFEST.json      read it and compare; rc=1 on mismatch
    fk33_imgfp.py write     MANIFEST.json      (re)write the record
    fk33_imgfp.py invalidate MANIFEST.json     zero it: "no image is resident"
    fk33_imgfp.py selfcheck                    teeth; no card, no image, no model dir


WHY THIS EXISTS.  MEASURED 2026-09-20, and it cost 35 weight objects.  The
card held the lane-striped image; `fk33_chat.sh` defaulted to the FLAT one.
Two separate kinds of damage followed, from the SAME cause:

  * both manifests declare `desc_arena_base = 0x1ffadd000`, the same address,
    so the flat descriptor table overwrote the striped one;
  * `server/pl_backend.c` programmed the FLAT `kv_base = 0x10d93e000` into the
    KV seam register, and subsystem C wrote 24 positions of KV records into
    the striped WEIGHT image.

Until that morning a mismatched manifest only MISADDRESSED READS.  Making C's
KV base a host-programmed register is what made the striped image runnable and
delivered 2.04x, and it is also what turned this class from a wrong answer
into data loss.  Both halves of that trade are real.  This file is the guard
the change needed and did not get.


WHY PLACEMENT AND NOT CONTENT
-----------------------------

MEASURED, over the three packed sets in `/mnt/storage/llama-models`:

    flat vs striped   : all 250 per-file blake2b_128 IDENTICAL, hbm_offsets differ
    striped vs seg27  : all 250 per-file blake2b_128 IDENTICAL,
                        all 250 hbm_offsets IDENTICAL, all pieces IDENTICAL

The packer decides ADDRESSES; the bytes it writes are the same bytes.  So a
digest of what HBM holds cannot tell the three apart, and a digest of the
files cannot either.  `hw/fk33/host/fk33_resident_image.py` probes the bytes
at the addresses a candidate manifest claims, which separates flat from
striped -- and CANNOT separate striped from seg27, because those two place
every weight piece at the same address and differ only in the GDN state and
KV regions, which hold no file bytes to probe.  That was the stated gap in
`c419de7`, and it is precisely the gap that matters: `kv_base` is the field
that did the damage.

So the fingerprint is over the PLACEMENT: the region block plus every piece
address.  The region block is the half that separates striped from seg27; the
piece list is the half that separates flat from striped without a read.


WHERE THE RECORD LIVES, AND WHAT THAT COSTS
-------------------------------------------

`desc_arena_base + desc_arena_bytes - 512`, the LAST 512 BYTES OF THE
DESCRIPTOR ARENA EXTENT.  For every set packed for the 9B shape that is
`0x1ffadd000 + 159744 - 512 = 0x1ffb03e00`.

  * It is already RESERVED.  `tools/hbm_map.py` carries the arena as a region
    and checks it disjoint from all four allocators, so nothing else can be
    placed there.  MEASURED: the map report shows
    `A descriptor arena 0x1_ffad_d000 0x1_ffb0_4000  159,744`.
  * NOTHING WRITES IT.  Subsystem A reads descriptor `i` at
    `base + i * stride` for `i < jobs`, so its last byte is
    `base + jobs*stride - 1`.  MEASURED: `token.arena` as emitted by
    `tools/gen_layer_program.py --arena-image` is 159,232 B = 311 * 512
    exactly, and `fk33ctl.py load ... --offset desc_arena_base` writes that
    many bytes and stops 512 short.
  * IT COSTS NO BITSTREAM AND NO MANIFEST MIGRATION.  Both alternatives do.
    See the REJECTED list at the bottom of this docstring.

THE MARGIN IS EXACTLY ZERO AND THAT IS SAID OUT LOUD: 311 * 512 = 159,232 and
159,744 - 512 = 159,232.  A shape needing one more job would take the record's
bytes, so `record_addr()` REFUSES when `jobs * stride > bytes - 512` rather
than overlapping.  Fail closed, loudly, at the moment of writing.

Hazards, named and handled:

  * A WEIGHT RELOAD THAT DOES NOT CLEAR IT would leave the record claiming an
    image that is no longer there.  Handled: `fk33_load_weights.py load`
    INVALIDATES the record before the first weight byte moves, and writes the
    new one only after every object has been written and hashed.  A load that
    dies half way leaves "no image resident", which every consumer refuses.
    That is the safe direction.
  * A TORN WRITE would leave half of one record and half of another.
    Handled: the record carries an FNV-1a-64 over its own body and a tail
    magic.  A torn record fails both and reads as ABSENT, which is a refusal,
    never an acceptance.  FNV is here to detect tearing, not to authenticate:
    nothing in this project has an adversary, and a hash that had to agree
    between Python and C is a second implementation that can disagree.
  * A PARTIAL LOAD (`--only PAT`) does not establish that the whole image is
    resident.  Handled: it invalidates and does NOT rewrite, so the card
    reports "no image" until a full load or an explicit
    `fk33_imgfp.py write` after a full `verify`.
  * A CARD THAT WAS NEVER LOADED reads zeros, which fail the magic, which is
    ABSENT, which is a refusal on the hardware path.


MEASURED AND REJECTED -- do not retry
-------------------------------------

  * A NEW SEAM REGISTER.  16 bytes of fingerprint is four registers and a
    4.5-hour place-and-route, and a register is cleared by reconfiguration
    while the image in HBM is not -- so after a bitstream reload the register
    would say "no image" about an image that is still there, and worse, a
    register written by the host is not evidence about HBM at all.
  * A CARVED PAGE AT THE TOP OF HBM.  There is no gap to carve.  MEASURED
    from the map: the arena ends at 0x1_ffb0_4000 and `host_x_base` begins at
    0x1_ffb0_4000; the host D-program page ends at 0x2_0000_0000.  Every
    block abuts.  Shifting any of them down a page makes every packed set's
    `host_x_base`/`host_l_base`/`host_desc_ptr` provenance disagree with
    `pl_derive_bases()` and puts the arena on top of `x_base`, so
    `fk33_load_weights.py load` would refuse EVERY existing image until each
    manifest was re-derived.  On a card that is serving, that is not a
    migration, it is an outage.
  * A HOST-SIDE STATE FILE.  The entire defect class is "the host believed
    something about the card".  A file goes stale on a reboot, on a second
    machine, and on anyone loading through `fk33ctl.py` directly, and it goes
    stale SILENTLY.
  * A CONTENT DIGEST OF RESIDENT BYTES.  Measured above: it cannot tell the
    three images apart at all.


NO HARDWARE unless you ask for it.  `print` and `selfcheck` open nothing.
`read`/`check`/`write`/`invalidate` open `/dev/xdma0_c2h_0` and
`/dev/xdma0_h2c_0` (overridable with FK33_C2H / FK33_H2C, which is how
`selfcheck` points them at an ordinary sparse file).  A human runs those
against the card, never a subagent.
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import time

RECORD_BYTES = 512
MAGIC = b"FK33IMG\x01"
TAIL = b"\x01GMI33KF"
VERSION = 1

# The region fields, in the order they are hashed AND the order they sit in
# the record.  server/fk33_imglock.c carries the same order and the same
# names; tools compare field by field rather than by hash, so the error can
# say WHICH one disagrees.
#
# `host_max_chunk` is here because a larger one drags the host's staging
# blocks down through a fixed arena, so two images differing only in it are
# two different maps.
REGION_FIELDS = (
    "size",
    "weights_end",
    "gdn_state_base",
    "gdn_state_bytes",
    "kv_base",
    "kv_bytes_per_token",
    "gdn_const_base",
    "gdn_const_bytes",
    "desc_arena_base",
    "desc_arena_bytes",
    "host_max_chunk",
)

# Byte offsets inside the record.  Mirrored in server/fk33_imglock.h.
OFF_MAGIC = 0x000
OFF_VERSION = 0x008
OFF_BYTES = 0x00C
OFF_FP = 0x010
OFF_REGION = 0x020           # 11 * 8 = 88 bytes, ends 0x078
OFF_WHEN = 0x078
OFF_OBJS_LOADED = 0x080
OFF_OBJS_TOTAL = 0x084
OFF_BYTES_LOADED = 0x088
OFF_PATH = 0x090             # 240 bytes, NUL padded, ends 0x180
PATH_BYTES = 240
OFF_FNV = 0x1F0
OFF_TAIL = 0x1F8

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "tools"))
try:
    import hbm_map as HM
except Exception as _e:                                   # pragma: no cover
    HM = None
    _HM_WHY = str(_e)


class BadRecord(Exception):
    """The 512 bytes are not a record.  ALWAYS a refusal, never a default."""


class NoRecordSlot(Exception):
    """This manifest's arena has no room for the record, or does not declare
    enough to place it.  Refused rather than overlapped."""


def h2c():
    return os.environ.get("FK33_H2C", "/dev/xdma0_h2c_0")


def c2h():
    return os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0")


def _hbm(mani):
    h = mani.get("hbm")
    if not isinstance(h, dict):
        raise NoRecordSlot("the manifest has no `hbm` block")
    return h


def region_of(mani):
    """The 11 numbers, as a dict.  A missing REQUIRED one is an error, not a
    zero: zero reads as `no constraint` and that is the failure this whole
    file exists to prevent.  `gdn_const_base`/`_bytes` are the documented
    optional pair (server/fk33_manifest.h) and read as 0 when absent, which
    is the honest value -- a set packed before the image existed."""
    h = _hbm(mani)
    out = {}
    for k in REGION_FIELDS:
        if k in ("gdn_const_base", "gdn_const_bytes"):
            out[k] = int(h.get(k, 0))
            continue
        if k not in h:
            raise NoRecordSlot(
                "the manifest's hbm block has no `%s`, so its placement "
                "cannot be fingerprinted.  Run\n"
                "    python3 tools/hbm_map.py <manifest> --write-manifest-hbm"
                % k)
        out[k] = int(h[k])
    return out


def _pieces(e):
    """DELEGATED to tools/hbm_map.py::file_pieces, the one producer of this
    model, for the reason fk33_load_weights.py::pieces_of states: a local
    copy would be a second idea of where a tensor is."""
    if HM is not None:
        return HM.file_pieces(e)
    if e.get("pieces"):
        raise NoRecordSlot(
            "%s carries `pieces` (a lane-striped manifest) and "
            "tools/hbm_map.py could not be imported (%s), so its placement "
            "cannot be read.  Refusing rather than fingerprinting a flat "
            "reading of a striped image." % (e.get("file"), _HM_WHY))
    return [dict(index=0, hbm_offset=int(e["hbm_offset"]),
                 nbytes=int(e["nbytes"]))]


def canonical_text(mani):
    """The exact bytes that are hashed.  Deliberately human-readable so a
    disagreement can be diffed rather than guessed at, and deliberately
    ordered by file name so a repacking that only reorders the list is the
    same fingerprint."""
    r = region_of(mani)
    lines = ["fk33-image-placement-v%d" % VERSION]
    for k in REGION_FIELDS:
        lines.append("hbm.%s %d" % (k, r[k]))
    ls = _hbm(mani).get("lane_stripe")
    if ls:
        lines.append("stripe %d %d" % (int(ls["segment_bytes"]),
                                       int(ls["n_segments"])))
    else:
        lines.append("stripe none")
    files = sorted(mani.get("files", []), key=lambda e: e["file"])
    if not files:
        raise NoRecordSlot("the manifest declares no files")
    for e in files:
        pcs = _pieces(e)
        lines.append("obj %s %d %s" % (
            e["file"], int(e["nbytes"]),
            " ".join("%d:%d:%d" % (int(p["index"]), int(p["hbm_offset"]),
                                   int(p["nbytes"])) for p in pcs)))
    return "\n".join(lines) + "\n"


def fingerprint(mani):
    """blake2b-128 over canonical_text().  16 bytes."""
    return hashlib.blake2b(canonical_text(mani).encode("utf-8"),
                           digest_size=16).digest()


def fingerprint_hex(mani):
    return fingerprint(mani).hex()


def record_addr(mani):
    """Where the record lives for THIS manifest.  Refuses rather than
    overlapping the descriptors; see the module docstring on the zero
    margin."""
    h = _hbm(mani)
    for k in ("desc_arena_base", "desc_arena_bytes"):
        if k not in h:
            raise NoRecordSlot(
                "the manifest's hbm block has no `%s`, so there is no "
                "reserved extent to put the record in" % k)
    base, nbytes = int(h["desc_arena_base"]), int(h["desc_arena_bytes"])
    if nbytes < RECORD_BYTES:
        raise NoRecordSlot(
            "the descriptor arena reserves %d B, less than the %d-byte record"
            % (nbytes, RECORD_BYTES))
    jobs = h.get("desc_arena_jobs")
    stride = h.get("desc_arena_stride")
    if jobs is None or stride is None:
        raise NoRecordSlot(
            "the manifest does not state desc_arena_jobs / desc_arena_stride, "
            "so it cannot be shown that the arena's last %d bytes are unused. "
            "Refusing rather than writing into a descriptor.  Run\n"
            "    python3 tools/hbm_map.py <manifest> --write-manifest-hbm"
            % RECORD_BYTES)
    used = int(jobs) * int(stride)
    if used > nbytes - RECORD_BYTES:
        raise NoRecordSlot(
            "the descriptor arena's %d jobs x %d B stride use %d of its %d "
            "reserved bytes, leaving %d -- less than the %d-byte record.  "
            "Writing it would overwrite descriptor %d.  Refusing."
            % (int(jobs), int(stride), used, nbytes, nbytes - used,
               RECORD_BYTES, used // int(stride) - 1))
    return base + nbytes - RECORD_BYTES


def fnv1a64(buf):
    """FNV-1a, 64-bit.  TEAR DETECTION ONLY.  It is here because it is six
    lines in C and six lines in Python and the two cannot drift; a real
    digest on both sides would be a second implementation, which is the `m7
    mutant` failure this project has already recorded."""
    h = 0xCBF29CE484222325
    for b in buf:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def pack_record(mani, manifest_path, objs_loaded, objs_total, bytes_loaded,
                when=None):
    r = region_of(mani)
    buf = bytearray(RECORD_BYTES)
    buf[OFF_MAGIC:OFF_MAGIC + 8] = MAGIC
    struct.pack_into("<I", buf, OFF_VERSION, VERSION)
    struct.pack_into("<I", buf, OFF_BYTES, RECORD_BYTES)
    buf[OFF_FP:OFF_FP + 16] = fingerprint(mani)
    for i, k in enumerate(REGION_FIELDS):
        struct.pack_into("<Q", buf, OFF_REGION + 8 * i, r[k])
    struct.pack_into("<Q", buf, OFF_WHEN,
                     int(time.time() if when is None else when))
    struct.pack_into("<I", buf, OFF_OBJS_LOADED, int(objs_loaded))
    struct.pack_into("<I", buf, OFF_OBJS_TOTAL, int(objs_total))
    struct.pack_into("<Q", buf, OFF_BYTES_LOADED, int(bytes_loaded))
    p = os.path.abspath(manifest_path).encode("utf-8")[:PATH_BYTES - 1]
    buf[OFF_PATH:OFF_PATH + len(p)] = p
    struct.pack_into("<Q", buf, OFF_FNV, fnv1a64(bytes(buf[:OFF_FNV])))
    buf[OFF_TAIL:OFF_TAIL + 8] = TAIL
    return bytes(buf)


def unpack_record(buf):
    """Raises BadRecord for anything that is not exactly a record.  There is
    no partial success: a record that does not parse is ABSENT, and absent is
    a refusal wherever it matters."""
    if len(buf) != RECORD_BYTES:
        raise BadRecord("record is %d bytes, expected %d"
                        % (len(buf), RECORD_BYTES))
    if bytes(buf[OFF_MAGIC:OFF_MAGIC + 8]) != MAGIC:
        if not any(buf):
            raise BadRecord("no record: the 512 bytes are all zero, so no "
                            "image has been recorded as resident here")
        raise BadRecord("no record: magic is %r, expected %r"
                        % (bytes(buf[:8]), MAGIC))
    ver, nb = struct.unpack_from("<II", buf, OFF_VERSION)
    if ver != VERSION:
        raise BadRecord("record version %d, this tool speaks %d"
                        % (ver, VERSION))
    if nb != RECORD_BYTES:
        raise BadRecord("record declares %d bytes, expected %d"
                        % (nb, RECORD_BYTES))
    if bytes(buf[OFF_TAIL:OFF_TAIL + 8]) != TAIL:
        raise BadRecord("record tail is %r, expected %r -- a TORN WRITE: the "
                        "head of one record and the tail of another, or of "
                        "nothing" % (bytes(buf[OFF_TAIL:OFF_TAIL + 8]), TAIL))
    want, = struct.unpack_from("<Q", buf, OFF_FNV)
    got = fnv1a64(bytes(buf[:OFF_FNV]))
    if want != got:
        raise BadRecord("record checksum 0x%016x, computed 0x%016x -- the "
                        "bytes are not a whole record (a torn or partial "
                        "write)" % (want, got))
    out = {"version": ver, "fp": bytes(buf[OFF_FP:OFF_FP + 16])}
    out["fp_hex"] = out["fp"].hex()
    for i, k in enumerate(REGION_FIELDS):
        out[k], = struct.unpack_from("<Q", buf, OFF_REGION + 8 * i)
    out["when"], = struct.unpack_from("<Q", buf, OFF_WHEN)
    out["objs_loaded"], out["objs_total"] = struct.unpack_from(
        "<II", buf, OFF_OBJS_LOADED)
    out["bytes_loaded"], = struct.unpack_from("<Q", buf, OFF_BYTES_LOADED)
    p = bytes(buf[OFF_PATH:OFF_PATH + PATH_BYTES])
    out["manifest_path"] = p.split(b"\x00", 1)[0].decode("utf-8", "replace")
    return out


def compare(rec, mani):
    """Every way this record and this manifest disagree, as a list of
    strings.  Empty means they describe the same placement.

    BOTH HALVES ARE CHECKED AND THEY ARE NOT REDUNDANT.  The fingerprint
    covers the piece list, which is what separates the flat image from the
    striped one; the field-by-field comparison covers the region block, which
    is what separates the two striped images AND is the half a C caller can
    make without parsing 250 file entries.  A fingerprint mismatch alone
    cannot say WHICH number is wrong, and that message is the whole value of
    the field loop."""
    bad = []
    r = region_of(mani)
    for k in REGION_FIELDS:
        if rec[k] != r[k]:
            bad.append("hbm.%s: resident 0x%X, this manifest 0x%X"
                       % (k, rec[k], r[k]))
    fp = fingerprint(mani)
    if rec["fp"] != fp:
        bad.append("placement fingerprint: resident %s, this manifest %s"
                   % (rec["fp"].hex(), fp.hex()))
    if rec["objs_loaded"] != rec["objs_total"]:
        bad.append("the resident image was only PARTIALLY loaded (%d of %d "
                   "objects); the rest of HBM is whatever was there before"
                   % (rec["objs_loaded"], rec["objs_total"]))
    return bad


# ------------------------------------------------------------------ the card

def read_record(mani, fd=None):
    """Returns the parsed record, or raises BadRecord."""
    addr = record_addr(mani)
    own = fd is None
    if own:
        fd = os.open(c2h(), os.O_RDONLY)
    try:
        buf = os.pread(fd, RECORD_BYTES, addr)
    finally:
        if own:
            os.close(fd)
    if len(buf) != RECORD_BYTES:
        raise BadRecord("read %d of %d bytes at %#x" % (len(buf),
                                                        RECORD_BYTES, addr))
    return unpack_record(buf)


def write_bytes(mani, buf, fd=None):
    addr = record_addr(mani)
    if len(buf) != RECORD_BYTES:
        raise ValueError("record must be %d bytes" % RECORD_BYTES)
    own = fd is None
    if own:
        fd = os.open(h2c(), os.O_WRONLY)
    try:
        k = 0
        while k < len(buf):
            k += os.pwrite(fd, buf[k:], addr + k)
    finally:
        if own:
            os.close(fd)
    return addr


def invalidate(mani, fd=None):
    """Zero the record.  Called BEFORE the first weight byte of a load moves,
    so that a load which dies half way leaves `no image resident` rather than
    a record describing an image that is only partly there."""
    return write_bytes(mani, b"\x00" * RECORD_BYTES, fd=fd)


def describe(rec):
    when = time.strftime("%Y-%m-%d %H:%M:%S",
                         time.localtime(rec["when"])) if rec["when"] else "?"
    return ("image %s\n  loaded %s from %s\n  %d of %d objects, %s bytes\n"
            "  kv_base 0x%X  gdn_state_base 0x%X  gdn_const_base 0x%X\n"
            "  desc_arena_base 0x%X  weights_end 0x%X  host_max_chunk %d"
            % (rec["fp_hex"], when, rec["manifest_path"] or "(no path)",
               rec["objs_loaded"], rec["objs_total"],
               format(rec["bytes_loaded"], ","),
               rec["kv_base"], rec["gdn_state_base"], rec["gdn_const_base"],
               rec["desc_arena_base"], rec["weights_end"],
               rec["host_max_chunk"]))


def load_manifest(path):
    with open(path) as fh:
        return json.load(fh)


# ------------------------------------------------------------------ commands

def cmd_print(a):
    mani = load_manifest(a.manifest)
    print(fingerprint_hex(mani))
    if a.verbose:
        sys.stdout.write(canonical_text(mani))
        print("record would live at %#x" % record_addr(mani))
    return 0


CANDIDATES = [
    "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27",
    "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped",
    "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-stripe27",
    "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd",
]


def cmd_which(a):
    """WHICH IMAGE IS ON THE CARD, from the card, in one line on stdout.

    THE ADDRESS COMES FROM A MANIFEST, so this needs candidates to know where
    to look -- but that is not a guess about the card, because a wrong address
    holds no record and no record is reported as no record.  Every packed set
    of the 9B shape puts the descriptor arena at the same place (the arena is
    allocated from the top of HBM under the host's blocks, which are a
    function of the SHAPE and not of the image), so in practice one read
    settles it.

    The record carries the manifest PATH it was written from, so the answer is
    the loader's own statement rather than an inference.  It is then CHECKED
    against that manifest: a record naming a file that has since been
    repacked is a mismatch, not an answer."""
    cands = a.candidates or CANDIDATES
    seen, last = set(), "no candidate manifest yielded a readable address"
    for d in cands:
        p = d if d.endswith(".json") else os.path.join(d, "manifest.json")
        if not os.path.exists(p):
            continue
        try:
            addr = record_addr(load_manifest(p))
        except (NoRecordSlot, ValueError, KeyError) as e:
            last = str(e)
            continue
        if addr in seen:
            continue
        seen.add(addr)
        try:
            rec = read_record(load_manifest(p))
        except BadRecord as e:
            last = str(e)
            continue
        rp = rec["manifest_path"]
        if not rp or not os.path.exists(rp):
            print("the card's record names %r, which is not a file here"
                  % (rp or "(nothing)"), file=sys.stderr)
            return 1
        bad = compare(rec, load_manifest(rp))
        if bad:
            print("the card's record names %s but does not agree with it "
                  "(%s): that file has been repacked since the load"
                  % (rp, bad[0]), file=sys.stderr)
            return 1
        print(rp)
        return 0
    print("NO IMAGE RECORD on this card (%s).  Nothing says which packed "
          "image is resident." % last, file=sys.stderr)
    return 1


def cmd_read(a):
    mani = load_manifest(a.manifest)
    try:
        rec = read_record(mani)
    except BadRecord as e:
        print("NO IMAGE RECORD at %#x: %s" % (record_addr(mani), e),
              file=sys.stderr)
        return 1
    print(describe(rec))
    return 0


def cmd_check(a):
    mani = load_manifest(a.manifest)
    try:
        rec = read_record(mani)
    except BadRecord as e:
        print("IMAGE LOCK: REFUSE -- %s" % e, file=sys.stderr)
        print("  nothing on the card says which image is resident, so this\n"
              "  manifest cannot be shown to describe it.  Load the image\n"
              "  with fk33_load_weights.py load <manifest> --verify, which\n"
              "  writes the record.", file=sys.stderr)
        return 1
    bad = compare(rec, mani)
    if bad:
        print("IMAGE LOCK: REFUSE -- the card is NOT holding this image",
              file=sys.stderr)
        print("  resident : %s" % (rec["manifest_path"] or "(no path)"),
              file=sys.stderr)
        print("  requested: %s" % os.path.abspath(a.manifest), file=sys.stderr)
        for m in bad:
            print("    %s" % m, file=sys.stderr)
        return 1
    print("IMAGE LOCK: MATCH  %s\n  %s" % (rec["fp_hex"],
                                           os.path.abspath(a.manifest)))
    return 0


def cmd_write(a):
    mani = load_manifest(a.manifest)
    n = len(mani.get("files", []))
    tot = sum(int(e["nbytes"]) for e in mani.get("files", []))
    buf = pack_record(mani, a.manifest, n, n, tot)
    addr = write_bytes(mani, buf)
    print("wrote the image record at %#x: %s" % (addr, fingerprint_hex(mani)))
    return 0


def cmd_invalidate(a):
    mani = load_manifest(a.manifest)
    addr = invalidate(mani)
    print("zeroed the image record at %#x: the card now reports NO IMAGE"
          % addr)
    return 0


# --------------------------------------------------------------------- teeth

def _synth_manifest(kv_base=0x1_B193_8000, gdn_state_base=0x1_B000_0000,
                    arena=0x1_FFAD_D000, arena_bytes=159744, jobs=311,
                    stride=512, striped=True, n_files=6, seed=1,
                    gdn_const_base=0x1_FF95_A000, host_max_chunk=512):
    """A manifest shaped like the real ones and hundreds of times smaller.
    No model directory, no /mnt/storage, no card."""
    files = []
    off = 0x1000
    for i in range(n_files):
        nb = 4096 * (4 + i)
        e = {"file": "blk.%d.w.mv4i" % i, "nbytes": nb, "hbm_offset": off,
             "blake2b_128": "%032x" % (seed * 1000 + i)}
        if striped:
            # four lanes plus a header, tiling the file exactly, the shape
            # tools/hbm_map.py::file_pieces produces for a v2 manifest.
            per = (nb - 4096) // 4
            e["striped"] = True
            e["pieces"] = [{"index": 0, "kind": "header", "lane": None,
                            "file_offset": 0, "nbytes": 4096,
                            "hbm_offset": off, "segment": 17,
                            "segment_declared": 17}]
            for L in range(4):
                e["pieces"].append(
                    {"index": L + 1, "kind": "lane", "lane": L,
                     "file_offset": 4096 + L * per, "nbytes": per,
                     "hbm_offset": 0x1_0000_0000 + (L + seed) * 0x100_0000 + off,
                     "segment": 17 + L, "segment_declared": 17 + L})
        files.append(e)
        off += nb
    hbm = {"size": 0x2_0000_0000, "align": 4096, "stack_bytes": 0x1_0000_0000,
           "weights_bytes": off, "weights_end": off,
           "gdn_state_base": gdn_state_base, "gdn_state_bytes": 26443776,
           "kv_base": kv_base, "kv_bytes_per_token": 17408,
           "max_context_tokens": 1000,
           "gdn_const_base": gdn_const_base, "gdn_const_bytes": 1585152,
           "desc_arena_base": arena, "desc_arena_bytes": arena_bytes,
           "desc_arena_jobs": jobs, "desc_arena_stride": stride,
           "host_max_chunk": host_max_chunk}
    if striped:
        hbm["lane_stripe"] = {"segment_bytes": 0x1000_0000, "n_segments": 32}
    return {"format": "test", "hbm": hbm, "files": files}


def _c_crosscheck(tmpdir, rec_bytes, mani, expect_agree):
    """COMPILE server/fk33_imglock.c AND MAKE IT ANSWER.

    A mirror is not evidence: the C decoder is a second implementation of the
    record layout and of FNV, and the only thing that makes the two comparable
    is a test that runs both.  Same argument as tools/hbm_map.py's
    check_against_c().  Returns (rc, stdout) or None if there is no compiler.
    """
    import subprocess
    repo = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "..", "..")
    src = os.path.join(repo, "server", "fk33_imglock.c")
    man = os.path.join(repo, "server", "fk33_manifest.c")
    if not os.path.exists(src):
        return None
    exe = os.path.join(tmpdir, "imglock_probe")
    cc = os.environ.get("CC", "cc")
    try:
        subprocess.run([cc, "-O1", "-Wall", "-Wextra", "-Werror",
                        "-DFK33_IMGLOCK_MAIN", "-I", os.path.join(repo, "server"),
                        src, man, "-o", exe],
                       check=True, capture_output=True)
    except FileNotFoundError:
        return None
    except subprocess.CalledProcessError as e:
        return (-1, e.stderr.decode("utf-8", "replace"))
    recf = os.path.join(tmpdir, "rec.bin")
    with open(recf, "wb") as fh:
        fh.write(rec_bytes)
    manf = os.path.join(tmpdir, "m.json")
    with open(manf, "w") as fh:
        json.dump(mani, fh)
    p = subprocess.run([exe, "check", recf, manf], capture_output=True)
    return (p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace"))


def _c_pack(tmpdir, mani, manifest_path, objs, tot, when):
    """THE OTHER DIRECTION.  C lays a record out; Python compares the bytes.

    One direction proves C can READ what Python writes and says nothing about
    what C would WRITE, which is the half a future C writer would depend on.
    Returns the 512 bytes, or None if there is no compiler."""
    import subprocess
    repo = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "..", "..")
    exe = os.path.join(tmpdir, "imglock_probe")
    if not os.path.exists(exe):
        return None
    manf = os.path.join(tmpdir, "m_pack.json")
    with open(manf, "w") as fh:
        json.dump(mani, fh)
    out = os.path.join(tmpdir, "c_rec.bin")
    p = subprocess.run([exe, "pack", manf, out, fingerprint_hex(mani),
                        str(when), str(objs), str(objs), str(tot),
                        manifest_path], capture_output=True)
    if p.returncode != 0:
        return (p.stdout + p.stderr).decode("utf-8", "replace")
    with open(out, "rb") as fh:
        return fh.read()


def cmd_selfcheck(a):
    """Teeth.  Every mutant is reported under its own name, including the
    ones that do NOT bite, because those measure the check's resolution
    floor.  Needs no card, no model directory and no /mnt/storage."""
    import tempfile
    fails = 0
    rows = []

    def row(name, verdict, detail=""):
        rows.append((name, verdict, detail))

    base = _synth_manifest()
    fp0 = fingerprint_hex(base)

    # ---- the properties, before any mutant.
    same = _synth_manifest()
    if fingerprint_hex(same) != fp0:
        row("determinism", "FAIL", "two identical manifests hash differently")
        fails += 1
    else:
        row("determinism", "ok", fp0)

    reordered = _synth_manifest()
    reordered["files"] = list(reversed(reordered["files"]))
    if fingerprint_hex(reordered) != fp0:
        row("file-order-invariance", "FAIL",
            "reordering the file list changed the fingerprint")
        fails += 1
    else:
        row("file-order-invariance", "ok", "same fingerprint")

    # A different CONTENT digest with identical placement must NOT change the
    # fingerprint.  This is the property that makes it a placement
    # fingerprint, and the reason the real images need one.
    other_bytes = _synth_manifest(seed=99)
    for e, f in zip(other_bytes["files"], base["files"]):
        e["blake2b_128"] = "%032x" % 0xDEADBEEF
        # keep the placement identical to base
        e["pieces"] = json.loads(json.dumps(f["pieces"]))
    if fingerprint_hex(other_bytes) != fp0:
        row("content-invariance", "FAIL",
            "changing every blake2b_128 changed the placement fingerprint")
        fails += 1
    else:
        row("content-invariance", "ok",
            "identical placement, different digests -> same fingerprint")

    addr = record_addr(base)
    if addr != 0x1_FFAD_D000 + 159744 - 512:
        row("record-addr", "FAIL", hex(addr))
        fails += 1
    else:
        row("record-addr", "ok", hex(addr))

    # ---- the round trip and the card path, against a sparse FILE, not a card.
    tmp = tempfile.mkdtemp(prefix="fk33imgfp.")
    hbmf = os.path.join(tmp, "hbm.bin")
    with open(hbmf, "wb") as fh:
        fh.truncate(0x2_0000_0000)
    old = (os.environ.get("FK33_H2C"), os.environ.get("FK33_C2H"))
    os.environ["FK33_H2C"] = hbmf
    os.environ["FK33_C2H"] = hbmf
    try:
        try:
            read_record(base)
            row("absent-record", "FAIL", "an unwritten slot parsed as a record")
            fails += 1
        except BadRecord as e:
            row("absent-record", "ok", str(e).split(":")[0])

        write_bytes(base, pack_record(base, "/models/base/manifest.json",
                                      len(base["files"]), len(base["files"]),
                                      1 << 20))
        rec = read_record(base)
        if rec["fp_hex"] != fp0 or compare(rec, base):
            row("round-trip", "FAIL", str(compare(rec, base)))
            fails += 1
        else:
            row("round-trip", "ok", "written, read back, agrees")

        # ---- THE MUTANT TABLE.  Every row is a manifest driven at a card
        # holding `base`.  "bites" means compare() refuses.
        def bite(name, mani, must_bite, why=""):
            nonlocal fails
            try:
                bad = compare(rec, mani)
            except NoRecordSlot as e:
                bad = ["refused before comparison: %s" % e]
            got = bool(bad)
            ok = (got == must_bite)
            row(name, "ok" if ok else "FAIL",
                ("REFUSED: " + bad[0]) if got else "accepted" + (
                    "  (" + why + ")" if why and not must_bite else ""))
            if not ok:
                fails += 1

        # THE INCIDENT ITSELF.  A flat manifest at a card holding a striped
        # image: the arena base is the SAME (that is what made it destructive)
        # and kv_base is not.
        flat = _synth_manifest(kv_base=0x1_0D93_E000,
                               gdn_state_base=0x1_0C00_6000, striped=False)
        bite("incident-flat-vs-striped", flat, True)

        # The same manifest twice.  MUST NOT bite, or the guard is useless.
        bite("same-manifest-twice", _synth_manifest(), False)

        # The case a CONTENT digest would miss, and the whole argument for a
        # placement fingerprint: identical file digests, identical piece
        # addresses, a different KV region.  This is striped vs seg27.
        bite("striped-vs-seg27-kv-only",
             _synth_manifest(kv_base=0x1_AD71_C000,
                             gdn_state_base=0x1_ABDE_4000), True)

        # kv_base alone, nothing else.
        bite("kv-base-edited-alone",
             _synth_manifest(kv_base=0x1_B193_9000), True)

        # gdn_const_base alone: B's constants, the third base.
        bite("gdn-const-base-edited-alone",
             _synth_manifest(gdn_const_base=0x1_FF00_0000), True)

        # host_max_chunk alone: it moves the host's staging blocks under a
        # fixed arena, so it is part of the map.
        bite("host-max-chunk-edited-alone",
             _synth_manifest(host_max_chunk=1024), True)

        # A different model SHAPE: more objects, different sizes.
        bite("different-model-shape", _synth_manifest(n_files=9), True)

        # ONE PIECE MOVED, region block untouched.  This is the half the
        # field-by-field comparison cannot see and the fingerprint can.
        moved = _synth_manifest()
        moved["files"][2]["pieces"][2]["hbm_offset"] += 4096
        bite("one-piece-moved", moved, True)

        # ---- MUTANTS THAT DO NOT BITE, reported under their own names
        # because they measure this check's resolution floor.  Discarding
        # them would overstate what it covers.
        #
        # 1. Different packed BYTES at the same addresses.  A placement
        #    fingerprint is deliberately blind to content, which is the
        #    property that makes it able to separate the three real images at
        #    all (their per-file digests are identical).  The guard that DOES
        #    catch this is `fk33_load_weights.py verify`, which reads HBM back
        #    and compares against the manifest's blake2b_128.
        diffbytes = _synth_manifest()
        for e in diffbytes["files"]:
            e["blake2b_128"] = "%032x" % 0x1234
        bite("NOT-BITING different-packed-bytes-same-addresses", diffbytes,
             False, "by design; the guard for this is "
                    "fk33_load_weights.py verify")

        # 2. A different declared CONTEXT CAP with the same kv_base.  It moves
        #    nothing, so no write lands anywhere new.  The guard that DOES
        #    catch an unrunnable capacity is pl_open()'s check that the card's
        #    C_MAXPOS extent fits under the image's KV ceiling.
        capped = _synth_manifest()
        capped["hbm"]["max_context_tokens"] = 7
        bite("NOT-BITING max-context-tokens-edited", capped, False,
             "moves no address; the guard for this is pl_open's "
             "C_MAXPOS extent check")

        # ATTRIBUTION CONTROL.  The same incident pair with the placement
        # fingerprint REMOVED from the comparison, to show what the region
        # fields alone would catch and what they would not.
        def region_only(mani):
            r = region_of(mani)
            return [k for k in REGION_FIELDS if rec[k] != r[k]]

        if region_only(flat):
            row("ATTRIBUTION region-fields-alone-vs-flat", "ok",
                "would still refuse on " + ",".join(region_only(flat)))
        else:
            row("ATTRIBUTION region-fields-alone-vs-flat", "FAIL",
                "region fields do not separate the incident pair")
            fails += 1
        if region_only(moved):
            row("ATTRIBUTION region-fields-alone-vs-moved-piece", "FAIL",
                "expected the region fields to be BLIND to a moved piece")
            fails += 1
        else:
            row("ATTRIBUTION region-fields-alone-vs-moved-piece", "ok",
                "BLIND, as intended: only the fingerprint catches this, so "
                "the fingerprint half is not redundant")

        # ---- record-level mutants: the bytes, not the manifest.
        good = pack_record(base, "/models/base/manifest.json", 6, 6, 1 << 20)

        def bad_bytes(name, buf, expect_msg):
            nonlocal fails
            try:
                unpack_record(buf)
                row(name, "FAIL", "parsed as a valid record")
                fails += 1
            except BadRecord as e:
                row(name, "ok", str(e)[:70])

        bad_bytes("record-all-zero", b"\x00" * RECORD_BYTES, "no record")
        b = bytearray(good); b[0] ^= 0xFF
        bad_bytes("record-magic-corrupt", bytes(b), "magic")
        b = bytearray(good); struct.pack_into("<I", b, OFF_VERSION, 7)
        bad_bytes("record-wrong-version", bytes(b), "version")
        b = bytearray(good); b[OFF_REGION + 32] ^= 0x01
        bad_bytes("record-body-bit-flipped", bytes(b), "checksum")
        # A TORN WRITE: the head of a new record over the tail of an old one.
        other = pack_record(_synth_manifest(kv_base=0x1_0D93_E000),
                            "/models/flat/manifest.json", 6, 6, 1 << 20)
        bad_bytes("record-torn-head-of-new-tail-of-old",
                  other[:256] + good[256:], "checksum")
        bad_bytes("record-truncated", good[:256], "bytes")
        b = bytearray(good); b[OFF_TAIL] ^= 0xFF
        bad_bytes("record-tail-clobbered", bytes(b), "tail")

        # A PARTIAL load must not read as a whole image.
        part = unpack_record(pack_record(base, "/models/base/manifest.json",
                                         3, 6, 1 << 19))
        if compare(part, base):
            row("partial-load-record", "ok",
                "REFUSED: " + compare(part, base)[-1][:60])
        else:
            row("partial-load-record", "FAIL", "a 3-of-6 load read as whole")
            fails += 1

        # ---- the arena slot guard.
        try:
            record_addr(_synth_manifest(jobs=312))
            row("arena-slot-overflow", "FAIL",
                "312 jobs x 512 B leaves no room and was not refused")
            fails += 1
        except NoRecordSlot as e:
            row("arena-slot-overflow", "ok", str(e)[:70])
        try:
            m = _synth_manifest()
            del m["hbm"]["desc_arena_jobs"]
            record_addr(m)
            row("arena-provenance-absent", "FAIL", "placed without proof")
            fails += 1
        except NoRecordSlot as e:
            row("arena-provenance-absent", "ok", str(e)[:70])

        # ---- THE TWO-LANGUAGE CROSS-CHECK.
        cc = _c_crosscheck(tmp, good, base, True)
        if cc is None:
            row("c-decoder-agrees", "SKIP",
                "server/fk33_imglock.c or a C compiler is not available")
        else:
            rc, out = cc
            if rc != 0:
                row("c-decoder-agrees", "FAIL", out.strip()[:200])
                fails += 1
            else:
                row("c-decoder-agrees", "ok", out.strip().splitlines()[-1][:80])
            cc2 = _c_crosscheck(tmp, good, flat, False)
            rc2, out2 = cc2
            if rc2 == 0:
                row("c-decoder-refuses-incident", "FAIL",
                    "the C side accepted the flat manifest")
                fails += 1
            else:
                row("c-decoder-refuses-incident", "ok",
                    out2.strip().splitlines()[-1][:80])
            b = bytearray(good); b[OFF_REGION + 32] ^= 0x01
            rc3, out3 = _c_crosscheck(tmp, bytes(b), base, False)
            if rc3 == 0:
                row("c-decoder-refuses-torn", "FAIL",
                    "the C side accepted a corrupted record")
                fails += 1
            else:
                row("c-decoder-refuses-torn", "ok",
                    out3.strip().splitlines()[-1][:80])
            # THE OTHER DIRECTION: C packs, Python compares the bytes.
            when = 1758300000
            cbytes = _c_pack(tmp, base, "/models/base/manifest.json", 6,
                             1 << 20, when)
            pybytes = pack_record(base, "/models/base/manifest.json", 6, 6,
                                  1 << 20, when=when)
            if not isinstance(cbytes, bytes):
                row("c-packer-agrees", "FAIL", str(cbytes)[:120])
                fails += 1
            elif cbytes != pybytes:
                d = [i for i in range(RECORD_BYTES) if cbytes[i] != pybytes[i]]
                row("c-packer-agrees", "FAIL",
                    "%d bytes differ, first at 0x%03X" % (len(d), d[0]))
                fails += 1
            else:
                row("c-packer-agrees", "ok",
                    "512 of 512 bytes identical to the Python packer")
    finally:
        for k, v in zip(("FK33_H2C", "FK33_C2H"), old):
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        os.unlink(os.path.join(tmp, "hbm.bin"))
        for f in os.listdir(tmp):
            os.unlink(os.path.join(tmp, f))
        os.rmdir(tmp)

    w = max(len(n) for n, _, _ in rows)
    for n, v, d in rows:
        print("  %-*s  %-4s  %s" % (w, n, v, d))
    print("IMGFP SELFCHECK: %d rows, %d FAIL" % (len(rows), fails))
    return 1 if fails else 0


def main():
    p = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog="NO HARDWARE from a subagent.  read/check/write/invalidate "
               "open /dev/xdma*.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("print", help="the fingerprint of a manifest; no card")
    s.add_argument("manifest")
    s.add_argument("-v", "--verbose", action="store_true")
    s.set_defaults(fn=cmd_print)
    for name, fn, helptext in (
            ("read", cmd_read, "print the record the card holds"),
            ("check", cmd_check, "compare the card's record with a manifest"),
            ("write", cmd_write, "(re)write the record"),
            ("invalidate", cmd_invalidate, "zero the record")):
        s = sub.add_parser(name, help=helptext)
        s.add_argument("manifest")
        s.set_defaults(fn=fn)
    s = sub.add_parser("which", help="print the manifest path of the image "
                                     "the card is holding")
    s.add_argument("candidates", nargs="*",
                   help="model directories or manifest.json paths to take the "
                        "record's ADDRESS from; default: the usual packed sets")
    s.set_defaults(fn=cmd_which)
    s = sub.add_parser("selfcheck", help="teeth; no card, no image")
    s.set_defaults(fn=cmd_selfcheck)
    a = p.parse_args()
    try:
        return a.fn(a)
    except NoRecordSlot as e:
        # A REFUSAL, not a crash.  Sets packed before the region block existed
        # (2026-08-29) land here, and the message is the migration.
        print("REFUSED: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
