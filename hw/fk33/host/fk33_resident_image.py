#!/usr/bin/env python3
"""fk33_resident_image.py -- which packed image is actually on the card?

WHY THIS EXISTS, MEASURED 2026-09-20 and it cost the weight image twice in
one hour.  `fk33_chat.sh` defaulted to a hardcoded model directory.  The card
was holding the lane-striped image.  Driving the FLAT manifest at it did two
separate kinds of damage:

  * both manifests declare `desc_arena_base = 0x1ffadd000`, the SAME address,
    so the flat descriptor table overwrote the striped one and subsystem A
    fetched weights from flat addresses;
  * `pl_backend.c` programmed the FLAT `kv_base = 0x10d93e000` into the KV
    seam register, and C wrote its records into the striped WEIGHT image.
    Intersecting the flat KV slot grid at 24 tokens against the striped
    pieces predicts the 35 corrupted objects exactly: 0 missed, 0 extra.

Until 2026-09-20 a mismatched manifest merely MISADDRESSED READS.  Making
C's KV base a host-programmed register is what delivered the 2.04x on the
striped image, and it is also what turned this class from a wrong answer
into data loss.  Both halves of that trade are real; this file is the guard
the change needed and did not get.

THE PROBE IS A PLACEMENT PROBE, NOT A CONTENT DIGEST, AND THAT IS THE WHOLE
POINT.  The packed bytes of the flat, striped and seg27 images are
BYTE-IDENTICAL -- the packer only decides addresses, and every per-file
blake2b in all three manifests agrees.  A content digest of what HBM holds
therefore cannot tell them apart.  What differs is WHERE each piece sits, so
this reads a few bytes at addresses the candidate manifest claims and asks
whether the file's bytes are there.  A manifest whose pieces are somewhere
else fails on the first probe.

It reads HBM through /dev/xdma0_c2h_0 and writes nothing, so it is safe to
run at any time -- but it does open /dev/xdma*, so a human runs it, never a
subagent.
"""
import json
import os
import sys

# FK33_C2H overrides the device, the same convention fk33_load_weights.py
# and fk33_imgfp.py use.  It exists so this file's callers can be tested
# against an ordinary sparse file standing in for HBM -- without it the
# fallback branch of fk33_chat.sh could only be exercised on the card,
# which is the class of path this project has repeatedly found untested.
C2H = os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0")

# The directories a card in this project is ever loaded from.  Order matters
# only for reporting; the probe decides.
CANDIDATES = [
    "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27",
    "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped",
    "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd",
]

PROBE_BYTES = 256
# How many distinct pieces to check.  One is enough to separate the flat and
# striped layouts, but a lane-striped pair differing only in the tail of the
# plan needs several, and the cost is microseconds each.
N_PROBES = 24


def _pieces(mani):
    """(hbm_offset, file_path, file_offset, nbytes) for real payload pieces.

    Skips the 4 KB headers: every image writes a header at the same place for
    the same tensor, so a header probe cannot discriminate.
    """
    out = []
    d = os.path.dirname(os.path.abspath(mani["__path__"]))
    for f in mani.get("files", []):
        p = os.path.join(d, f["file"])
        ps = f.get("pieces")
        if ps:
            for x in ps:
                if x.get("kind") == "header":
                    continue
                out.append((x["hbm_offset"], p, x["file_offset"], x["nbytes"]))
        else:
            # flat entry: the payload follows the 4 KB header
            out.append((f["hbm_offset"] + 4096, p, 4096, f["nbytes"] - 4096))
    return out


def load_manifest(path):
    with open(path) as fh:
        m = json.load(fh)
    m["__path__"] = path
    return m


def probe(manifest_path, fd=None, n=N_PROBES):
    """Does the card hold the image this manifest describes?

    Returns (ok, checked, first_bad) where first_bad is a human-readable
    description of the first piece whose bytes are not where the manifest
    says, or None.
    """
    m = load_manifest(manifest_path)
    pieces = _pieces(m)
    if not pieces:
        return False, 0, "the manifest declares no payload pieces"
    # Spread the probes across the whole placement rather than taking the
    # first n, which would all be one tensor and one segment.
    step = max(1, len(pieces) // n)
    sel = pieces[::step][:n]
    own = fd is None
    if own:
        fd = os.open(C2H, os.O_RDONLY)
    try:
        for hbm_off, path, f_off, nbytes in sel:
            k = min(PROBE_BYTES, nbytes)
            got = os.pread(fd, k, hbm_off)
            with open(path, "rb") as fh:
                fh.seek(f_off)
                want = fh.read(k)
            if got != want:
                return (False, len(sel),
                        "%s at HBM %#x does not hold the bytes this manifest "
                        "puts there" % (os.path.basename(path), hbm_off))
    finally:
        if own:
            os.close(fd)
    return True, len(sel), None


def identify(candidates=None):
    """Which candidate manifest describes the resident image?  None if no
    candidate matches, which is a real answer: the card may hold an image
    this list does not know about, or no image at all."""
    hits = []
    for d in (candidates or CANDIDATES):
        mp = os.path.join(d, "manifest.json")
        if not os.path.exists(mp):
            continue
        ok, _, _ = probe(mp)
        if ok:
            hits.append(d)
    return hits


def main():
    args = sys.argv[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        print("usage: fk33_resident_image.py [--check <manifest.json>]")
        print("       with no argument, prints which known image is resident")
        return 0
    if len(args) >= 2 and args[0] == "--check":
        ok, n, why = probe(args[1])
        if ok:
            print("RESIDENT MATCH  %s  (%d pieces probed)" % (args[1], n))
            return 0
        print("RESIDENT MISMATCH  %s\n  %s" % (args[1], why), file=sys.stderr)
        hits = identify()
        if hits:
            print("  the card appears to hold: %s" % ", ".join(hits),
                  file=sys.stderr)
        else:
            print("  and no image this script knows about matches either",
                  file=sys.stderr)
        return 2
    hits = identify()
    if not hits:
        print("NO KNOWN IMAGE RESIDENT", file=sys.stderr)
        return 2
    for d in hits:
        print(d)
    return 0 if len(hits) == 1 else 3


if __name__ == "__main__":
    sys.exit(main())
