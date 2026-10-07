"""Jungle Cat USER3 control protocol: TDI slot builder, TDO slot parser.

Spec: docs/superpowers/plans/2026-10-07-jc-engine-composition.md, Task 2
("Protocol (exact)"). Slot shape (16,384 bits, LSB first), word size (256 bits),
and the CRC convention (CRC-32 over the first 16,128 bits, at bits 16128..16159)
all follow tools/jc/jc_frame.py, the loader's own definition.
"""
import argparse, random, struct, sys, zlib

SLOT_BITS = 16384
SLOT_BYTES = SLOT_BITS // 8                      # 2048
WORD_BYTES = 32                                  # one 256-bit word
MAX_PAYLOAD_WORDS = 62
MAX_PAYLOAD_BYTES = MAX_PAYLOAD_WORDS * WORD_BYTES   # 1984
CRC_OFFSET = 63 * WORD_BYTES                     # 2016 bytes = 16,128 bits
ITEMS_PER_WORD = WORD_BYTES // 4                 # 8 32-bit items per 256-bit word

MAGIC = 0x4A435431          # "JCT1"
STAT_MAGIC = 0x4A435354      # "JCST"
MAX_ITEMS = 496
RSP_SEQ_NONE = 0xFFFFFFFF

OP_NOP, OP_WR_INC, OP_WR_FIX, OP_RD_INC, OP_RD_FIX, OP_MEM_RD = 0, 1, 2, 3, 4, 5
WRITE_OPS = (OP_WR_INC, OP_WR_FIX)

STATUS_BITS = 384
STATUS_BYTES = STATUS_BITS // 8                  # 48
RSP_BUF_BITS = 32 * MAX_ITEMS                     # 15,872
RSP_BUF_BYTES = RSP_BUF_BITS // 8                 # 1984


def header(seq, op, addr, count, nwords):
    """Pack the 32-byte (256-bit) header word. Bounds and the MEM_RD-specific
    alignment/multiple checks apply regardless of caller (build_slot or a direct
    caller), matching the "Protocol (exact)" table."""
    if not 0 <= seq <= 0xFFFFFFFF:
        raise ValueError("seq out of range: %d" % seq)
    if not 0 <= op <= 0xFF:
        raise ValueError("op out of range: %d" % op)
    if not 1 <= count <= MAX_ITEMS:
        raise ValueError("count out of range (1..%d): %d" % (MAX_ITEMS, count))
    if not 0 <= nwords <= MAX_PAYLOAD_WORDS:
        raise ValueError("nwords out of range: %d" % nwords)
    if not 0 <= addr < (1 << 64):
        raise ValueError("addr out of range: %#x" % addr)
    if op == OP_MEM_RD:
        if addr % WORD_BYTES:
            raise ValueError("MEM_RD addr must be 32-byte aligned: %#x" % addr)
        if count % ITEMS_PER_WORD:
            raise ValueError("MEM_RD count must be a multiple of %d: %d" %
                              (ITEMS_PER_WORD, count))
    v = (MAGIC | (seq & 0xFFFFFFFF) << 32 | (op & 0xFF) << 64 | (count & 0xFFFF) << 72
         | (nwords & 0xFFFF) << 104 | addr << 120)
    return v.to_bytes(WORD_BYTES, "little")


def parse_header(hdr):
    """Decode a 32-byte header word. Used only by this module's own `gen`; tests
    that check build_slot must decode independently, not through this function."""
    v = int.from_bytes(hdr[:WORD_BYTES], "little")
    return dict(magic=v & 0xFFFFFFFF, seq=(v >> 32) & 0xFFFFFFFF, op=(v >> 64) & 0xFF,
                count=(v >> 72) & 0xFFFF, nwords=(v >> 104) & 0xFFFF,
                addr=(v >> 120) & ((1 << 64) - 1))


def slot_crc_ok(slot):
    return struct.unpack_from("<I", slot, CRC_OFFSET)[0] == zlib.crc32(slot[:CRC_OFFSET]) & 0xFFFFFFFF


def slot_hex(slot):
    return "%04096x" % int.from_bytes(slot, "little")


def build_slot(seq, op, addr, items, count):
    """Build one 2048-byte TDI slot: header word 0, 62 payload words, CRC-32 over
    the first 16,128 bits at bits 16128..16159, zero padding after."""
    if op in WRITE_OPS:
        if items is None or len(items) != count:
            raise ValueError("WR op needs len(items) == count: items=%r count=%d" %
                              (None if items is None else len(items), count))
        nwords = (count + ITEMS_PER_WORD - 1) // ITEMS_PER_WORD
    else:
        nwords = 0
    hdr = header(seq, op, addr, count, nwords)
    if op in WRITE_OPS:
        payload = b"".join(struct.pack("<I", it & 0xFFFFFFFF) for it in items)
        payload = payload.ljust(MAX_PAYLOAD_BYTES, b"\0")
    else:
        payload = bytes(MAX_PAYLOAD_BYTES)
    body = hdr + payload
    assert len(body) == CRC_OFFSET
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return body + struct.pack("<I", crc) + bytes(SLOT_BYTES - CRC_OFFSET - 4)


def parse_tdo(slot):
    """Decode one 2048-byte TDO slot: 384-bit status word, then up to 496 32-bit
    response words (word 0 first, each word LSB first)."""
    if len(slot) != SLOT_BYTES:
        raise ValueError("TDO slot must be %d bytes: got %d" % (SLOT_BYTES, len(slot)))
    v = int.from_bytes(slot[:STATUS_BYTES], "little")
    magic = v & 0xFFFFFFFF
    if magic != STAT_MAGIC:
        raise ValueError("bad STAT magic: %#x (want %#x)" % (magic, STAT_MAGIC))
    rsp_bytes = slot[STATUS_BYTES:STATUS_BYTES + RSP_BUF_BYTES]
    rsp = [int.from_bytes(rsp_bytes[i:i + 4], "little") for i in range(0, len(rsp_bytes), 4)]
    return dict(
        last_done_seq=(v >> 32) & 0xFFFFFFFF,
        rsp_seq=(v >> 64) & 0xFFFFFFFF,
        rsp_count=(v >> 96) & 0xFFFF,
        rsp_valid=(v >> 112) & 1,
        axi_err=(v >> 113) & 1,
        axi_resp=(v >> 114) & 0x3,
        err_seq=(v >> 116) & 0xFFFFFFFF,
        desync=(v >> 148) & 0xFFFF,
        ovf=(v >> 164) & 1,
        crc_fail=(v >> 165) & 0xFFFF,
        rsp=rsp,
    )


# ---------------------------------------------------------------------------
# `gen`: write a jc_ctl bench vector file.
#
# CONCERN (see task-5-report.md): Task 2 had not committed sim/gen_jc_ctl_vec.py
# or sim/jc_ctl_frame_vec.txt at the time this was written, so the real line
# format (described in the plan's Task 2 Step 1 as "one slot as 4,096 hex digits
# ... then the expected tagged FIFO words") could not be read. This falls back
# to the loader's own analogue, tools/jc/gen_jc_vectors.py's gen_frame(): one
# line per slot, "S <ok> <nwords> <crc_ok> <seq_hex> <slot_hex>". Do not point
# this at sim/jc_ctl_frame_vec.txt until that format is confirmed against
# Task 2's actual bench.
# ---------------------------------------------------------------------------

def gen(path, seed=20261007):
    rng = random.Random(seed)
    lines = []

    def add(s, ok, seq):
        h = parse_header(s)
        good = bool(ok) and h["magic"] == MAGIC and h["nwords"] <= MAX_PAYLOAD_WORDS \
            and 1 <= h["count"] <= MAX_ITEMS
        nw = h["nwords"] if good else 0
        passed = int(good and slot_crc_ok(s))
        lines.append("S %d %d %d %08x %s" % (int(good), nw, passed, seq & 0xFFFFFFFF, slot_hex(s)))

    # filler: all-zero slot, magic is wrong -> desync, no FIFO words
    add(bytes(SLOT_BYTES), ok=False, seq=0)

    # (a) good WR_INC frame of 3 items
    items = [0x11111111, 0x22222222, 0x33333333]
    s_good = build_slot(0, OP_WR_INC, 0x40, items, 3)
    add(s_good, ok=True, seq=0)

    # a good RD_INC and a good MEM_RD, for coverage beyond the single WR case
    add(build_slot(1, OP_RD_INC, 0x80, None, 4), ok=True, seq=1)
    add(build_slot(2, OP_MEM_RD, 0x2000, None, 8), ok=True, seq=2)

    # (b) corrupted payload bit -> FAIL (CRC mismatch), magic and bounds still good
    bad_bit = bytearray(s_good)
    bad_bit[100] ^= 0x04
    add(bytes(bad_bit), ok=True, seq=0)

    # (c) bad magic -> desync, no FIFO words
    bad_magic = bytearray(s_good)
    bad_magic[0] ^= 0x80
    add(bytes(bad_magic), ok=False, seq=0)

    # (e) count > 496 rejected as desync. build_slot refuses to emit this (count is
    # out of range by construction), so patch a valid slot's header field by hand.
    raw = bytearray(build_slot(3, OP_RD_INC, 0xC0, None, 8))
    hv = int.from_bytes(raw[:WORD_BYTES], "little")
    hv = (hv & ~(0xFFFF << 72)) | (497 << 72)
    raw[:WORD_BYTES] = hv.to_bytes(WORD_BYTES, "little")
    add(bytes(raw), ok=False, seq=0)

    # a handful of back-to-back WR_INC/WR_FIX/RD_FIX frames for general coverage
    for k in range(4):
        n = rng.randrange(1, MAX_ITEMS + 1)
        op = (OP_WR_INC, OP_WR_FIX, OP_RD_INC, OP_RD_FIX)[k % 4]
        if op in WRITE_OPS:
            its = [rng.getrandbits(32) for _ in range(n)]
            add(build_slot(10 + k, op, 0x1000 * (k + 1), its, n), ok=True, seq=10 + k)
        else:
            add(build_slot(10 + k, op, 0x1000 * (k + 1), None, n), ok=True, seq=10 + k)

    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen", help="write a jc_ctl bench vector file")
    g.add_argument("path")
    a = ap.parse_args(argv)
    if a.cmd == "gen":
        gen(a.path)
        print("wrote", a.path)


if __name__ == "__main__":
    main()
