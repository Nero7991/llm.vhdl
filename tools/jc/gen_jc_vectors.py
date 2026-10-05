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

GENS = {"crc32": gen_crc32}

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
