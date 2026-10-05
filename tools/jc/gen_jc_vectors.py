#!/usr/bin/env python3
"""Write the Jungle Cat loader bench vectors (sim/jc_*_vec.txt).

Every expected value comes from zlib and tools/jc/jc_model.py, never from the RTL.
Usage: gen_jc_vectors.py [--only crc32|frame|writer|crcunit|loader]
"""
import argparse, os, random, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))

def sim(name):
    return os.path.join(REPO, "sim", name)

def gen_crc32(rng):
    lines = []
    for n in (1, 2, 8, 63, 504):
        words = [rng.getrandbits(32) for _ in range(n)]
        data = b"".join(struct.pack("<I", w) for w in words)
        crc = zlib.crc32(data) & 0xFFFFFFFF
        lines.append("%d %s %08x" % (n, " ".join("%08x" % w for w in words), crc))
    # zlib's published check value: CRC-32("123456789") = 0xcbf43926, 9 bytes padded is
    # not word-aligned, so use the 8-byte prefix "12345678" instead.
    data = b"12345678"
    w = struct.unpack("<2I", data)
    lines.append("2 %08x %08x %08x" % (w[0], w[1], zlib.crc32(data) & 0xFFFFFFFF))
    with open(sim("jc_crc32_vec.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")

def gen_frame(rng):
    from jc import jc_frame as F
    slots = []          # (slot, magic_ok, nwords, pass, seq)
    def add(s, ok=True):
        h = F.parse_header(s)
        good = ok and h["magic"] == F.MAGIC_FRAME and h["nwords"] <= F.MAX_PAYLOAD_WORDS
        slots.append((s, int(good), h["nwords"] if good else 0,
                      int(good and F.slot_crc_ok(s)), h["seq"] if good else 0))
    add(bytes(F.SLOT_BYTES), ok=False)                                # filler: desync
    add(F.build_slot(0, 0x0000, rng.randbytes(1984)))                 # full frame
    add(F.build_slot(1, 0x1000, rng.randbytes(32)))                   # one word
    add(F.build_slot(2, 0x2000, rng.randbytes(17 * 32 - 5)))          # short, padded
    add(F.poll_slot())                                                # poll: header only
    add(F.range_crc_slot(3, 0x0, 4096))                               # range request
    s = bytearray(F.build_slot(4, 0x3000, rng.randbytes(1984))); s[777] ^= 0x10
    add(bytes(s))                                                     # payload bit flip
    s = bytearray(F.build_slot(5, 0x4000, rng.randbytes(64))); s[F.CRC_OFFSET] ^= 1
    add(bytes(s))                                                     # CRC bit flip
    s = bytearray(F.build_slot(6, 0x5000, rng.randbytes(64))); s[0] ^= 0x80
    add(bytes(s), ok=False)                                           # wrong magic
    for k in range(8):                                                # back to back
        add(F.build_slot(7 + k, 0x6000 + 0x800 * k, rng.randbytes(rng.randrange(32, 1985))))
    with open(sim("jc_frame_vec.txt"), "w") as f:
        for s, ok, nw, ps, seq in slots:
            f.write("S %d %d %d %08x %s\n" % (ok, nw, ps, seq, F.slot_hex(s)))

GENS = {"crc32": gen_crc32, "frame": gen_frame}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=sorted(GENS))
    a = ap.parse_args()
    for name, fn in GENS.items():
        if a.only and name != a.only:
            continue
        fn(random.Random(20261005))
        print("wrote", name)

if __name__ == "__main__":
    main()
