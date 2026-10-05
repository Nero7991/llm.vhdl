#!/usr/bin/env python3
"""Load a weight image into a Jungle Cat die's HBM over JTAG (plan Tasks 8 and 9).

    coe_load.py load   MANIFEST.json --bmc IP --die A|B --chain AB|BA [--resume]
    coe_load.py verify MANIFEST.json --bmc IP --die A|B --chain AB|BA

Main session only: this opens the board's JTAG. Addresses come only from the manifest,
through fk33_load_weights.pieces_of() (tools/hbm_map.py::file_pieces()).

Fix round 1 (review: opus, 2026-10-05) corrected three planning defects:
  (c) expected_range_crc used to pad a short piece with whatever bytes followed it in
      the same file -- real neighbour data, not what the card holds there. The card's
      jc_hbm_writer commits exactly `nwords` whole 32-byte words per frame, and
      jc_frame.build_slot zero-pads a frame's payload up to that word boundary, so the
      true padding is always zero. Frame now carries the piece's unpadded length
      (`raw_n`) alongside the padded one (`n`); expected_range_crc reads only `raw_n`
      real bytes and pads the rest with zero itself.
  (d) plan_sha depended only on (file, addr, file_offset, nbytes), so two manifests
      with identical layout but different CONTENT hashed the same -- a resume could not
      tell the data had changed. It now folds in each entry's blake2b_128, plus
      F.MAX_PAYLOAD_BYTES and the target die (a plan for die A must never be mistaken
      for one planned for die B).
  (e) Spec S5's preflight (aligned, in range, single stack, disjoint) was only partly
      implemented: alignment and pairwise overlap, but not the per-piece HBM range or
      stack checks. plan_frames now refuses a piece that runs past the die's 8 GiB HBM
      map, a piece that straddles the 4 GiB stack line. A zero-length piece is refused
      outright (nothing to compare the range CRC against).

Fix round 2 (re-review, 2026-10-05) corrected two more:
  (6) the stack check above was wrong, not just incomplete: it compared the declared
      `stack` field against EVERY piece's own address, but `stack` names the stack the
      OBJECT's header (its first piece / its own `hbm_offset`) is in, not a claim that
      every piece shares it -- a real lane-striped manifest deliberately puts some
      lanes in the other stack (`tools/hbm_map.py`'s `manifest_piece_fails` P4 checks
      the header only, for the same reason). The old per-piece version refused every
      object that actually used both stacks: 1,488 of 3,473 pieces on a real 9B
      manifest. Fixed to check once per entry, against `e["hbm_offset"]`, matching P4.
  (7) a piece could declare a negative address or file offset, or a length that runs
      past the end of its own source file, and nothing refused it (the file-offset
      case silently read fewer bytes than declared and comparing against a short slice
      happened to still produce *a* CRC, just not one of anything real). Both are now
      refused in planning, same spirit as `fk33_load_weights.py`'s own preflight
      `getsize` check.
"""
import collections, hashlib, json, os, sys, zlib
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33", "host"))
from jc import jc_frame as F
import fk33_load_weights as FLW

Frame = collections.namedtuple("Frame", "seq addr path off n kind raw_n")

# Spec S2/S3: HBM is 8 GiB per die, two 4 GiB stacks ("no piece crosses the 4 GB stack
# boundary"). Same values fk33_load_weights.py uses for the FK33's own (same-family) map.
HBM_SIZE = 0x2_0000_0000
STACK_LINE = 0x1_0000_0000

class PlanError(Exception):
    pass

def _stack_of(addr):
    return 0 if addr < STACK_LINE else 1

def _entries(mani):
    return list(mani["files"]) + list(FLW.const_entries(mani))

def plan_frames(manifest_path, die=None):
    with open(manifest_path) as f:
        mani = json.load(f)
    root = os.path.dirname(os.path.abspath(manifest_path))
    frames, pieces = [], []
    h = hashlib.sha256()
    h.update(("die=%s max_payload=%d\n" % (die, F.MAX_PAYLOAD_BYTES)).encode())
    for e in _entries(mani):
        path = os.path.join(root, e["file"])
        filesize = os.path.getsize(path)
        dig = hashlib.blake2b(digest_size=16)
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 24), b""):
                dig.update(chunk)
        if dig.hexdigest() != e["blake2b_128"]:
            raise PlanError("%s hashes to %s, the manifest says %s"
                            % (e["file"], dig.hexdigest(), e["blake2b_128"]))
        declared = e.get("stack")
        header_addr = int(e["hbm_offset"])
        if declared is not None and int(declared) != _stack_of(header_addr):
            raise PlanError("%s declares stack %s, its header at %#x is actually in "
                            "stack %d" % (e["file"], declared, header_addr, _stack_of(header_addr)))
        for p in FLW.pieces_of(e):
            addr, foff, n = int(p["hbm_offset"]), int(p["file_offset"]), int(p["nbytes"])
            if n == 0:
                raise PlanError("%s piece at %#x is zero length" % (e["file"], addr))
            if addr < 0:
                raise PlanError("%s piece has a negative HBM address %d" % (e["file"], addr))
            if foff < 0:
                raise PlanError("%s piece has a negative file offset %d" % (e["file"], foff))
            if addr % 32:
                raise PlanError("%s piece at %#x is not 32-byte aligned" % (e["file"], addr))
            if addr + n > HBM_SIZE:
                raise PlanError("%s piece at %#x+%d runs past the %d GiB HBM map"
                                % (e["file"], addr, n, HBM_SIZE >> 30))
            if addr < STACK_LINE < addr + n:
                raise PlanError("%s piece at %#x+%d spans the %d GiB HBM stack boundary"
                                % (e["file"], addr, n, STACK_LINE >> 30))
            if foff + n > filesize:
                raise PlanError("%s piece at file +%d+%d runs past the file's own size %d"
                                % (e["file"], foff, n, filesize))
            pieces.append((addr, path, foff, n))
            h.update(("%s %d %d %d %s\n" % (e["file"], addr, foff, n, e["blake2b_128"])).encode())
    pieces.sort()
    for (a0, _, _, n0), (a1, _, _, _) in zip(pieces, pieces[1:]):
        if a0 + (n0 + 31) // 32 * 32 > a1:
            raise PlanError("pieces overlap after padding: %#x+%d reaches %#x" % (a0, n0, a1))
    seq = 0
    for addr, path, foff, n in pieces:
        k = 0
        while k < n:
            m = min(F.MAX_PAYLOAD_BYTES, n - k)
            frames.append(Frame(seq, addr + k, path, foff + k, m, "data", m)); seq += 1
            k += m
    for addr, path, foff, n in pieces:
        frames.append(Frame(seq, addr, path, foff, (n + 31) // 32 * 32, "range", n)); seq += 1
    return frames, h.hexdigest()

def read_payload(fr):
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        return fh.read(fr.n)

def expected_range_crc(fr):
    """CRC over the piece's real (`raw_n`) bytes, zero-padded to the frame's 32-byte
    length `n` -- the same padding jc_frame.build_slot applies before the writer commits
    whole words, never bytes read from whatever happens to follow in the source file."""
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        raw = fh.read(fr.raw_n)
    return zlib.crc32(raw.ljust(fr.n, b"\0")) & 0xFFFFFFFF
