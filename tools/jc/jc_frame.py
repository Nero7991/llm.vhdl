"""Jungle Cat loader frame and status format: the one Python definition.

Spec: docs/superpowers/specs/2026-10-05-jc-jtag-hbm-loader-design.md S4 and S10.
"""
import struct, zlib

SLOT_BITS = 16384
SLOT_BYTES = SLOT_BITS // 8
WORD_BYTES = 32
MAX_PAYLOAD_WORDS = 62
MAX_PAYLOAD_BYTES = MAX_PAYLOAD_WORDS * WORD_BYTES
CRC_OFFSET = 63 * WORD_BYTES
MAGIC_FRAME = 0x4A4C4431
MAGIC_STAT = 0x4A4C5354
FLAG_RANGE_CRC = 1
M40 = (1 << 40) - 1

def header(seq, hbm_addr, nwords, flags=0, range_len=0):
    if hbm_addr % WORD_BYTES or not 0 <= hbm_addr <= M40:
        raise ValueError("hbm_addr must be 32-byte aligned and fit 40 bits: %#x" % hbm_addr)
    if not 0 <= nwords <= MAX_PAYLOAD_WORDS:
        raise ValueError("nwords out of range: %d" % nwords)
    if range_len % WORD_BYTES or not 0 <= range_len <= M40:
        raise ValueError("range_len must be a multiple of 32: %d" % range_len)
    v = (MAGIC_FRAME | (seq & 0xFFFFFFFF) << 32 | hbm_addr << 64 | nwords << 104
         | (flags & 0xFFFF) << 120 | range_len << 136)
    return v.to_bytes(32, "little")

def build_slot(seq, hbm_addr, payload=b"", flags=0, range_len=0):
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ValueError("payload over %d bytes" % MAX_PAYLOAD_BYTES)
    nwords = (len(payload) + WORD_BYTES - 1) // WORD_BYTES
    body = header(seq, hbm_addr, nwords, flags, range_len) + payload.ljust(MAX_PAYLOAD_BYTES, b"\0")
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return body + struct.pack("<I", crc) + bytes(SLOT_BYTES - CRC_OFFSET - 4)

def poll_slot():
    return build_slot(0, 0, b"")

def range_crc_slot(seq, hbm_addr, range_len):
    return build_slot(seq, hbm_addr, b"", FLAG_RANGE_CRC, range_len)

def parse_header(slot):
    v = int.from_bytes(slot[:32], "little")
    return dict(magic=v & 0xFFFFFFFF, seq=(v >> 32) & 0xFFFFFFFF, addr=(v >> 64) & M40,
                nwords=(v >> 104) & 0xFFFF, flags=(v >> 120) & 0xFFFF,
                range_len=(v >> 136) & M40)

def slot_crc_ok(slot):
    return struct.unpack_from("<I", slot, CRC_OFFSET)[0] == zlib.crc32(slot[:CRC_OFFSET]) & 0xFFFFFFFF

# (name, lsb, width) -- the plan's "Status word layout" table. Task 9b (Oren 2026-10-05)
# widened the word from 256 to 384 bits: [351:256] is the die's 96-bit DNA_PORTE2 value,
# [352] dna_valid, [383:353] zero. TDO bits past 383 in a slot are zero.
STATUS_BITS = 384
STATUS_BYTES = STATUS_BITS // 8
DNA_BITS = 96
STATUS_FIELDS = [("magic", 0, 32), ("last", 32, 32), ("committed", 64, 32),
                 ("crc_fail", 96, 16), ("seq_err", 112, 16), ("desync", 128, 16),
                 ("bresp_err", 144, 16), ("dup", 160, 16), ("busy", 176, 1),
                 ("hbm_trip", 177, 1), ("range_valid", 178, 1), ("fifo_ovf", 179, 1),
                 ("range_rerr", 180, 1), ("range_crc", 192, 32), ("range_seq", 224, 32),
                 ("dna", 256, DNA_BITS), ("dna_valid", 352, 1)]

def parse_status(b):
    v = int.from_bytes(b[:STATUS_BYTES], "little")
    return {n: (v >> lsb) & ((1 << w) - 1) for n, lsb, w in STATUS_FIELDS}

def pack_status(d):
    v = 0
    for n, lsb, w in STATUS_FIELDS:
        v |= (d[n] & ((1 << w) - 1)) << lsb
    return v.to_bytes(STATUS_BYTES, "little")

def bursts(addr, nbeats):
    """AXI3 split: at most 16 beats of 32 bytes, never across a 4 KB boundary."""
    out = []
    while nbeats:
        to4k = (4096 - addr % 4096) // WORD_BYTES
        n = min(16, nbeats, to4k)
        out.append((addr, n))
        addr += n * WORD_BYTES
        nbeats -= n
    return out

def slot_hex(slot):
    return "%04096x" % int.from_bytes(slot, "little")
