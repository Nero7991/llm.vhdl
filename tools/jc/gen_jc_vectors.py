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

def gen_writer(rng):
    """Events fed straight into the writer's FIFO port, plus the model's final state."""
    from jc import jc_frame as F
    from jc.jc_model import LoaderModel
    bad = 0x0600                                # the third burst of the first full frame
    m = LoaderModel(bad_bresp_addrs={bad})
    ev, slots = [], []
    def frame(seq, addr, payload, corrupt=False):
        s = F.build_slot(seq, addr, payload)
        if corrupt:
            s = bytearray(s); s[50] ^= 1; s = bytes(s)
        slots.append(s)
    frame(0, 0x0000, rng.randbytes(1984))       # 4 bursts, one SLVERR at 0x600
    frame(1, 0x0FE0, rng.randbytes(96))         # crosses 4 KB: bursts of 1 then 2
    frame(1, 0x0FE0, rng.randbytes(96))         # duplicate
    frame(3, 0x2000, rng.randbytes(64))         # gap
    frame(2, 0x3000, rng.randbytes(64), corrupt=True)   # CRC fail
    frame(2, 0x3000, rng.randbytes(1000))       # short, padded last word
    slots.append(F.poll_slot())
    for s in slots:
        m.feed(s)
        h = F.parse_header(s)
        ev.append("H %064x" % int.from_bytes(s[:32], "little"))
        for k in range(h["nwords"]):
            ev.append("D %064x" % int.from_bytes(s[32 * (k + 1):32 * (k + 2)], "little"))
        ev.append("%s %08x" % ("P" if F.slot_crc_ok(s) else "F", h["seq"]))
    st = m.status()
    with open(sim("jc_writer_vec.txt"), "w") as f:
        f.write("B %010x\n" % bad)
        f.write("\n".join(ev) + "\n")
        for a in sorted(m.mem):
            f.write("M %010x %064x\n" % (a, int.from_bytes(m.mem[a], "little")))
        f.write("C %08x %08x %04x %04x %04x %04x\n" % (st["last"], st["committed"],
                st["crc_fail"], st["seq_err"], st["dup"], st["bresp_err"]))

# jc_axi3_mem's BAD_RRESP_ADDR in the tb_jc_hbm_crc instantiation: a single-beat read
# starting here comes back with RRESP = SLVERR on every beat of that burst. Lies inside
# the 0x2000 preload base (word 8 of 70) so the data is real, only the response is bad.
JC_CRCUNIT_BAD_ADDR = 0x2100

def gen_crcunit(rng):
    """Preloaded memory plus range requests with zlib CRCs over the same bytes."""
    words = {}
    for base in (0x0000, 0x0FC0, 0x2000):
        for k in range(70):
            words[base + 32 * k] = rng.randbytes(32)
    reqs = [(0x0000, 32, 1, 0), (0x0000, 70 * 32, 2, 0), (0x0FC0, 5 * 32, 3, 0),  # 5 beats across 4 KB
            (0x2000, 16 * 32, 4, 0), (0x2000, 17 * 32, 5, 0), (0x2000, 0, 6, 0),  # 0 bytes: CRC of nothing
            (JC_CRCUNIT_BAD_ADDR, 32, 7, 1)]                                      # RRESP error expected
    with open(sim("jc_crcunit_vec.txt"), "w") as f:
        for a in sorted(words):
            f.write("M %010x %064x\n" % (a, int.from_bytes(words[a], "little")))
        for a, n, seq, experr in reqs:
            data = b"".join(words.get(x, bytes(32)) for x in range(a, a + n, 32))
            f.write("R %010x %010x %08x %08x %d\n" %
                    (a, n, seq, zlib.crc32(data) & 0xFFFFFFFF, experr))

GENS = {"crc32": gen_crc32, "frame": gen_frame, "writer": gen_writer, "crcunit": gen_crcunit}

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
