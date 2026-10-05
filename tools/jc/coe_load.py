#!/usr/bin/env python3
"""Load a weight image into a Jungle Cat die's HBM over JTAG (plan Tasks 8 and 9).

    coe_load.py load   MANIFEST.json --bmc IP --die A|B --chain AB|BA [--resume]
    coe_load.py verify MANIFEST.json --bmc IP --die A|B --chain AB|BA

Main session only: this opens the board's JTAG. Addresses come only from the manifest,
through fk33_load_weights.pieces_of() (tools/hbm_map.py::file_pieces()).
"""
import collections, hashlib, json, os, sys, zlib
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33", "host"))
from jc import jc_frame as F
import fk33_load_weights as FLW

Frame = collections.namedtuple("Frame", "seq addr path off n kind")

class PlanError(Exception):
    pass

def _entries(mani):
    return list(mani["files"]) + list(FLW.const_entries(mani))

def plan_frames(manifest_path):
    with open(manifest_path) as f:
        mani = json.load(f)
    root = os.path.dirname(os.path.abspath(manifest_path))
    frames, pieces = [], []
    h = hashlib.sha256()
    for e in _entries(mani):
        path = os.path.join(root, e["file"])
        dig = hashlib.blake2b(digest_size=16)
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 24), b""):
                dig.update(chunk)
        if dig.hexdigest() != e["blake2b_128"]:
            raise PlanError("%s hashes to %s, the manifest says %s"
                            % (e["file"], dig.hexdigest(), e["blake2b_128"]))
        for p in FLW.pieces_of(e):
            addr, foff, n = int(p["hbm_offset"]), int(p["file_offset"]), int(p["nbytes"])
            if addr % 32:
                raise PlanError("%s piece at %#x is not 32-byte aligned" % (e["file"], addr))
            pieces.append((addr, path, foff, n))
            h.update(("%s %d %d %d\n" % (e["file"], addr, foff, n)).encode())
    pieces.sort()
    for (a0, _, _, n0), (a1, _, _, _) in zip(pieces, pieces[1:]):
        if a0 + (n0 + 31) // 32 * 32 > a1:
            raise PlanError("pieces overlap after padding: %#x+%d reaches %#x" % (a0, n0, a1))
    seq = 0
    for addr, path, foff, n in pieces:
        k = 0
        while k < n:
            m = min(F.MAX_PAYLOAD_BYTES, n - k)
            frames.append(Frame(seq, addr + k, path, foff + k, m, "data")); seq += 1
            k += m
    for addr, path, foff, n in pieces:
        frames.append(Frame(seq, addr, path, foff, (n + 31) // 32 * 32, "range")); seq += 1
    return frames, h.hexdigest()

def read_payload(fr):
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        return fh.read(fr.n)

def expected_range_crc(fr):
    """CRC over the piece's bytes padded with zeros to the frame's 32-byte length."""
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        raw = fh.read(fr.n)
    return zlib.crc32(raw.ljust(fr.n, b"\0")) & 0xFFFFFFFF
