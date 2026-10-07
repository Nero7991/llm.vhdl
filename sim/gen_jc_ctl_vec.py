#!/usr/bin/env python3
"""Write sim/jc_ctl_frame_vec.txt, the vectors for sim/tb_jc_ctl_frame_core.vhd.

Standalone on purpose (plan Task 2 ruling): the CRC is zlib.crc32 and the expected values
come from the small protocol model below, written from the Task 2 brief, never from the
RTL. Task 5's `tools/jc/jc_ctl.py gen` replaces this script and must write the same format
(documented in FORMAT below and at the top of the vector file).

Usage: python3 sim/gen_jc_ctl_vec.py [out_path]   (default: sim/jc_ctl_frame_vec.txt)
"""
import os, random, sys, zlib

SLOT_BITS, WORD_BITS, NWORDS_SLOT = 16384, 256, 64
CRC_BYTE = 63 * 32                     # bits 16128..16159
MAGIC, STAT_MAGIC = 0x4A435431, 0x4A435354
MAX_ITEMS, MAX_PAYLOAD = 496, 62
ST_BITS = 384
OP_NOP, OP_WR_INC, OP_WR_FIX, OP_RD_INC, OP_RD_FIX, OP_MEM_RD = 0, 1, 2, 3, 4, 5
TAG_DATA, TAG_HDR, TAG_PASS, TAG_FAIL = 0, 1, 2, 3

FORMAT = """\
# jc_ctl_frame_vec.txt: vectors for sim/tb_jc_ctl_frame_core.vhd (USER3 control frame core).
# Written by sim/gen_jc_ctl_vec.py (Task 2); tools/jc/jc_ctl.py gen must write the same format.
# Lines starting with '#' are comments. Fields are separated by single spaces.
#
# S <nbits> <endscan> <wready> <ack> <rspv> <nrsp> <desync> <crcf> <ovf> <st_in> <slot> <npush> {<tag> <word>}
#   nbits    bits of this slot shifted, 1..16384 (decimal); < 16384 only with endscan 1
#   endscan  1: the host leaves Shift-DR after this slot; the next slot starts a new scan
#            (a new Capture-DR). 0: the next slot follows in the same Shift-DR
#   wready   the FIFO's w_ready during this slot (0 makes every push an overflow)
#   ack      1 if rsp_ack_tgl toggles in this slot, at the rising TCK edge that shifts slot
#            bit 383 + 32*nrsp (the last response bit); 0 if it must not toggle at all
#   rspv     rsp_valid (status bit 112) as it must appear on TDO in this slot
#   nrsp     response words that must follow the status on TDO (bits 384..384+32*nrsp-1)
#   desync, crcf, ovf  the frame core's own status fields as they must appear on TDO in this
#            slot, i.e. counted over the slots BEFORE this one (decimal)
#   st_in    the 384-bit status the aclk side presents for this slot: 96 hex digits, most
#            significant first (bit 383 leftmost). The frame core latches it at slot start
#   slot     the 16,384 TDI bits: 4,096 hex digits with no separators, LSB word first: 64
#            words of 256 bits, word 0 (the header) first, each word 64 hex digits MSB first.
#            TDI bit i is bit (i mod 256) of word (i div 256)
#   npush    FIFO pushes expected during this slot (decimal), then npush pairs of
#            <tag> (0 DATA, 1 HDR, 2 PASS, 3 FAIL, decimal) and <word> (64 hex digits)
# E <desync> <crcf> <ovf>
#   the final counts after the last slot
#
# TDO in every slot: bits 0..383 are st_in with [31:0] = 4A435354, [112] = rspv,
# [163:148] = desync, [164] = ovf, [180:165] = crcf; then nrsp words of the response RAM,
# word k = RAM address k, LSB first; then zero to the end of the slot.
"""


def build_slot(seq, op, addr, count, items=None, nwords=None, magic=MAGIC):
    """2048 bytes, bit i of the slot = bit (i % 8) of byte (i // 8), as shifted on TDI."""
    items = list(items or [])
    if nwords is None:
        nwords = (count + 7) // 8 if op in (OP_WR_INC, OP_WR_FIX) else 0
    hdr = (magic | (seq << 32) | (op << 64) | (count << 72) | (nwords << 104)
           | (addr << 120))
    s = bytearray(SLOT_BITS // 8)
    s[0:32] = hdr.to_bytes(32, "little")
    for k, v in enumerate(items):
        o = 32 + 4 * k
        s[o:o + 4] = (v & 0xFFFFFFFF).to_bytes(4, "little")
    crc = zlib.crc32(bytes(s[:CRC_BYTE])) & 0xFFFFFFFF
    s[CRC_BYTE:CRC_BYTE + 4] = crc.to_bytes(4, "little")
    return bytes(s)


def word(s, k):
    return int.from_bytes(s[32 * k:32 * (k + 1)], "little")


def slot_hex(s):
    return "".join("%064x" % word(s, k) for k in range(NWORDS_SLOT))


def status(rng, rsp_valid, rsp_seq, rsp_count):
    """A 384-bit st_in: random everywhere (so pass-through and the core's overwrites are
    both visible), with the response fields this case is about set explicitly."""
    v = rng.getrandbits(ST_BITS)
    def put(v, lo, width, x):
        m = ((1 << width) - 1) << lo
        return (v & ~m) | ((x << lo) & m)
    v = put(v, 64, 32, rsp_seq)
    v = put(v, 96, 16, rsp_count)
    v = put(v, 112, 1, rsp_valid)
    return v


class Model:
    """The frame core as the brief states it (plus the stale-status rule in the report)."""

    def __init__(self):
        self.desync = self.crcf = self.ovf = 0
        self.pend = False
        self.acked_seq = None
        self.lines = []

    def slot(self, s, st, nbits=SLOT_BITS, endscan=0, wready=1):
        st_valid = (st >> 112) & 1
        st_seq = (st >> 64) & 0xFFFFFFFF
        st_cnt = (st >> 96) & 0xFFFF
        # status latched at slot start
        stale = self.pend and st_valid == 1 and st_seq == self.acked_seq
        if not stale:
            self.pend = False
        rspv = 0 if stale else st_valid
        nrsp = min(st_cnt, MAX_ITEMS) if rspv else 0
        shown = (self.desync, self.crcf, self.ovf)
        ack = 0
        if rspv and nbits > 383 + 32 * nrsp:
            ack = 1
            self.pend, self.acked_seq = True, st_seq
        # receive
        pushes = []
        if nbits >= 256:
            h = word(s, 0)
            cnt = (h >> 72) & 0xFFFF
            nw = (h >> 104) & 0xFFFF
            if (h & 0xFFFFFFFF) == MAGIC and cnt <= MAX_ITEMS and nw <= MAX_PAYLOAD:
                pushes.append((TAG_HDR, h))
                for k in range(1, nw + 1):
                    if nbits >= 256 * (k + 1):
                        pushes.append((TAG_DATA, word(s, k)))
                if nbits >= 16160:
                    seq = (h >> 32) & 0xFFFFFFFF
                    ok = (zlib.crc32(s[:CRC_BYTE]) & 0xFFFFFFFF) == \
                        int.from_bytes(s[CRC_BYTE:CRC_BYTE + 4], "little")
                    pushes.append((TAG_PASS if ok else TAG_FAIL, seq))
                    if not ok:
                        self.crcf = (self.crcf + 1) & 0xFFFF
            else:
                self.desync = (self.desync + 1) & 0xFFFF
        if pushes and not wready:
            self.ovf = 1
        f = ["S", nbits, endscan, wready, ack, rspv, nrsp, shown[0], shown[1], shown[2],
             "%096x" % st, slot_hex(s), len(pushes)]
        for t, w in pushes:
            f += [t, "%064x" % w]
        self.lines.append(" ".join(str(x) for x in f))

    def end(self):
        self.lines.append("E %d %d %d" % (self.desync, self.crcf, self.ovf))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "jc_ctl_frame_vec.txt")
    rng = random.Random(0x4A435431)
    m = Model()
    items = lambda n: [rng.getrandbits(32) for _ in range(n)]
    idle = lambda: status(rng, 0, 0xFFFFFFFF, 0)

    # (c) a zero filler: bad magic, desync, no pushes
    m.slot(bytes(SLOT_BITS // 8), idle())
    # (a) a good WR_INC of 3 items: HDR, one DATA word, PASS
    m.slot(build_slot(1, OP_WR_INC, 0xE000, 3, items(3)), idle())
    # (b) the same shape with one payload bit flipped: HDR, DATA, FAIL
    s = bytearray(build_slot(2, OP_WR_INC, 0xE010, 3, items(3))); s[40] ^= 0x04
    m.slot(bytes(s), idle())
    # (b) the CRC field itself corrupted on a header-only frame
    s = bytearray(build_slot(3, OP_RD_INC, 0xE000, 5)); s[CRC_BYTE + 3] ^= 0x80
    m.slot(bytes(s), idle())
    # a good RD_INC of 5 (header only)
    m.slot(build_slot(3, OP_RD_INC, 0xE000, 5), idle())
    # (e) count 497 rejected as desync (exactly one over), and 0xFFFF
    m.slot(build_slot(4, OP_RD_INC, 0xE000, 497), idle())
    m.slot(build_slot(4, OP_RD_FIX, 0xE000, 0xFFFF), idle())
    # the boundary: count 496 accepted (a full 62-word WR_FIX)
    m.slot(build_slot(4, OP_WR_FIX, 0xE004, 496, items(496)), idle())
    # nwords 63 rejected even with a legal count
    m.slot(build_slot(5, OP_WR_INC, 0xE000, 496, items(496), nwords=63), idle())
    # (d) a response: seq 3, 5 words; acked at bit 383 + 160
    st3 = status(rng, 1, 3, 5)
    m.slot(build_slot(6, OP_NOP, 0, 1), st3)
    # the same status again (the aclk side has not caught up): stale, masked, no ack
    m.slot(build_slot(7, OP_RD_FIX, 0xE008, 2), status(rng, 1, 3, 5))
    # the clear arrives
    m.slot(build_slot(8, OP_MEM_RD, 0x1_0000_0020, 8), idle())
    # a full 496-word response, acked at bit 16255; carries a full write
    m.slot(build_slot(9, OP_WR_INC, 0xE100, 496, items(496)), status(rng, 1, 7, 496))
    # a response of 2, aborted one bit before its last response bit: no ack. The header
    # is pushed (bit 255 shifted), nothing after it. The scan ends here.
    st9 = status(rng, 1, 9, 2)
    m.slot(build_slot(10, OP_WR_INC, 0xE000, 17, items(17)), st9, nbits=383 + 64, endscan=1)
    # a new scan: the same response is presented again and acked this time; retry seq 10
    m.slot(build_slot(10, OP_WR_INC, 0xE000, 17, items(17)), st9)
    # stale again, with w_ready low: every push overflows
    m.slot(build_slot(11, OP_RD_INC, 0xE000, 1), st9, wready=0)
    # a NEW seq published with no clear in between: not stale, acked, ovf now shown
    m.slot(build_slot(12, OP_MEM_RD, 0x2_0000_0000, 8), status(rng, 1, 12, 1))
    m.slot(build_slot(13, OP_NOP, 0, 1), status(rng, 1, 12, 1))       # stale
    m.slot(build_slot(14, OP_NOP, 0, 1), idle())                      # clear
    # the same seq published again after a clear is a new response: acked
    m.slot(build_slot(15, OP_NOP, 0, 1), status(rng, 1, 12, 1), endscan=1)
    # a malformed rsp_count over 496 is clamped to 496 (ack at 16255)
    m.slot(build_slot(16, OP_NOP, 0, 1), status(rng, 1, 20, 600))
    # wrong magic in an otherwise good frame
    s = bytearray(build_slot(17, OP_WR_INC, 0xE000, 8, items(8))); s[1] ^= 0x01
    m.slot(bytes(s), idle())
    # back to back, random shapes and random responses
    for k in range(8):
        op = rng.choice([OP_WR_INC, OP_WR_FIX, OP_RD_INC, OP_RD_FIX, OP_MEM_RD, OP_NOP])
        cnt = rng.randrange(1, MAX_ITEMS + 1)
        if op == OP_MEM_RD:
            cnt = 8 * rng.randrange(1, 63)
        its = items(cnt) if op in (OP_WR_INC, OP_WR_FIX) else None
        st = status(rng, 1, 100 + k, rng.randrange(1, MAX_ITEMS + 1)) if k % 2 else idle()
        m.slot(build_slot(18 + k, op, rng.getrandbits(16) & ~3, cnt, its), st)
    m.end()
    with open(out, "w") as f:
        f.write(FORMAT)
        f.write("\n".join(m.lines) + "\n")


if __name__ == "__main__":
    main()
