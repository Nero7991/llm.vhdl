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
# Written by sim/gen_jc_ctl_vec.py (Task 2, fix round 1); tools/jc/jc_ctl.py gen must write
# the same format. Lines starting with '#' are comments. Fields are separated by single spaces.
#
# S <nbits> <endscan> <wready> <ack> <rspv> <nrsp> <desync> <crcf> <ovf> <st_in> <slot> <npush> {<tag> <word>}
#   nbits    bits of this slot shifted, 1..16384 (decimal); < 16384 only with endscan 1 or 2
#   endscan  0: the next slot follows in the same Shift-DR. 1: the host leaves Shift-DR,
#            a foreign scan (another instruction, sel = 0) runs, then a new Capture-DR.
#            2: the host leaves Shift-DR and goes straight back to Capture-DR
#            (Exit1, Update, Select, Capture), so a Capture lands mid-slot
#   wready   the FIFO's w_ready during this slot (0 makes every push an overflow)
#   ack      1 if rsp_ack_tgl toggles in this slot, exactly once, at the rising TCK edge that
#            shifts slot bit 16159 (the CRC verdict of a PASS frame whose header carries
#            ack_valid = 1 and ack_seq = the rsp_seq presented in this slot); 0: no toggle
#   rspv     rsp_valid (status bit 112) as it must appear on TDO in this slot
#   nrsp     response words that must follow the status on TDO (bits 384..384+32*nrsp-1);
#            also the rsp_count [111:96] that TDO must show
#   desync, crcf, ovf  the frame core's own status fields as they must appear on TDO in this
#            slot, i.e. counted over the slots BEFORE this one (decimal)
#   st_in    the 384-bit status the aclk side presents for this slot: 96 hex digits, most
#            significant first (bit 383 leftmost). The frame core latches it at slot start.
#            Its rsp_crc field [212:181] is random here: the bench replaces it with the
#            CRC-32 of its own response RAM model over min(rsp_count, 496) words
#   slot     the 16,384 TDI bits: 4,096 hex digits with no separators, LSB word first: 64
#            words of 256 bits, word 0 (the header) first, each word 64 hex digits MSB first.
#            TDI bit i is bit (i mod 256) of word (i div 256)
#   npush    FIFO pushes expected during this slot (decimal), then npush pairs of
#            <tag> (0 DATA, 1 HDR, 2 PASS, 3 FAIL, decimal) and <word> (64 hex digits)
# E <desync> <crcf> <ovf>
#   the final counts after the last slot
#
# TDO in every slot: bits 0..383 are st_in with [31:0] = 4A435354, [111:96] = nrsp,
# [112] = rspv, [163:148] = desync, [164] = ovf, [180:165] = crcf, [212:181] passed through,
# [383:213] = 0; then nrsp words of the response RAM, word k = RAM address k, LSB first;
# then zero to the end of the slot.
"""


def build_slot(seq, op, addr, count, items=None, nwords=None, magic=MAGIC,
               ack_seq=0, ack_valid=0):
    """2048 bytes, bit i of the slot = bit (i % 8) of byte (i // 8), as shifted on TDI."""
    items = list(items or [])
    if nwords is None:
        nwords = (count + 7) // 8 if op in (OP_WR_INC, OP_WR_FIX) else 0
    hdr = (magic | (seq << 32) | (op << 64) | (count << 72) | (nwords << 104)
           | (addr << 120) | (ack_seq << 184) | (ack_valid << 216))
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
    """A 384-bit st_in: random everywhere (so pass-through, the core's overwrites and the
    forced-zero top are all visible), with the response fields set explicitly."""
    v = rng.getrandbits(ST_BITS)
    def put(v, lo, width, x):
        m = ((1 << width) - 1) << lo
        return (v & ~m) | ((x << lo) & m)
    v = put(v, 64, 32, rsp_seq)
    v = put(v, 96, 16, rsp_count)
    v = put(v, 112, 1, rsp_valid)
    return v


class Model:
    """The frame core as the brief and fix round 1 state it."""

    def __init__(self):
        self.desync = self.crcf = self.ovf = 0
        self.pend = False
        self.acked_seq = None
        self.lines = []
        self.nack = 0

    def slot(self, s, st, nbits=SLOT_BITS, endscan=0, wready=1):
        assert nbits == SLOT_BITS or endscan in (1, 2)
        st_valid = (st >> 112) & 1
        st_seq = (st >> 64) & 0xFFFFFFFF
        st_cnt = (st >> 96) & 0xFFFF
        # status latched at slot start; stale = an acked seq a lagging status still shows
        stale = self.pend and st_valid == 1 and st_seq == self.acked_seq
        if not stale:
            self.pend = False
        rspv = 0 if stale else st_valid
        nrsp = min(st_cnt, MAX_ITEMS) if rspv else 0
        shown = (self.desync, self.crcf, self.ovf)
        ack = 0
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
                    a_seq = (h >> 184) & 0xFFFFFFFF
                    a_v = (h >> 216) & 1
                    if ok and a_v and rspv and a_seq == st_seq:
                        ack = 1
                        self.nack += 1
                        self.pend, self.acked_seq = True, st_seq
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
    nop = lambda seq, **kw: build_slot(seq, OP_NOP, 0, 1, **kw)
    ack = lambda seq, a: build_slot(seq, OP_NOP, 0, 1, ack_seq=a, ack_valid=1)

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
    # (e) count over 496 rejected as desync: exactly one over, all ones, and high bits set
    # over small low bits (0x0200 and 0x0203 pass a 9-bit compare, 0x8001 a 15-bit one)
    for c in (497, 0xFFFF, 0x0200, 0x0203, 0x8001, 0x1005):
        m.slot(build_slot(4, OP_RD_INC, 0xE000, c), idle())
    # nwords over 62 rejected, with a legal count: 63, 64 and 0x41 (pass a 6-bit compare),
    # 0x0100 and 0x8000 (pass an 8-bit and a 15-bit compare)
    for nw in (63, 64, 0x41, 0x0100, 0x8000):
        m.slot(build_slot(5, OP_WR_INC, 0xE000, 8, items(8), nwords=nw), idle())
    # the boundary: count 496 accepted (a full 62-word WR_FIX)
    m.slot(build_slot(4, OP_WR_FIX, 0xE004, 496, items(496)), idle())

    # ---- (d) responses, host-driven ack ----
    st3 = status(rng, 1, 3, 5)
    m.slot(nop(6), st3)                                           # presented, no ack frame
    m.slot(ack(7, 4), st3)                                        # wrong ack_seq: ignored
    m.slot(build_slot(8, OP_NOP, 0, 1, ack_seq=3, ack_valid=0), st3)  # ack_valid 0: ignored
    s = bytearray(ack(9, 3)); s[100] ^= 0x01
    m.slot(bytes(s), st3)                                         # right ack on a FAIL frame
    m.slot(ack(9, 3), st3)                                        # acked at its verdict
    m.slot(ack(10, 3), status(rng, 1, 3, 5))                      # lagging: stale, re-ack ignored
    m.slot(ack(11, 3), status(rng, 0, 3, 5))                      # cleared: not presented, ignored
    # a full 496-word response, acked by a frame that also carries a full write
    m.slot(build_slot(12, OP_WR_INC, 0xE100, 496, items(496), ack_seq=7, ack_valid=1),
           status(rng, 1, 7, 496))
    # Captures mid-slot (endscan 2): one inside the status region before the header
    # completes (no push), one right after a good header's push (HDR only, no verdict, no
    # ack although the header acks). The response is presented again each time.
    st9 = status(rng, 1, 9, 2)
    m.slot(ack(13, 9), st9, nbits=200, endscan=2)
    m.slot(ack(13, 9), st9, nbits=257, endscan=2)
    m.slot(build_slot(13, OP_WR_INC, 0xE000, 17, items(17), ack_seq=9, ack_valid=1), st9,
           endscan=1)                                             # full slot: acked
    m.slot(build_slot(14, OP_RD_INC, 0xE000, 1), st9, wready=0)   # stale; pushes overflow
    st12 = status(rng, 1, 12, 1)
    m.slot(ack(15, 12), st12)              # a NEW seq with no clear in between: acked
    m.slot(ack(16, 12), status(rng, 1, 12, 1))                    # stale
    m.slot(nop(17), idle())                                       # clear
    m.slot(ack(18, 12), status(rng, 1, 12, 1), endscan=1)  # same seq after a clear: acked
    # rsp_count 600 shows as 496 on TDO and 496 words are shifted; acked
    m.slot(ack(19, 20), status(rng, 1, 20, 600))
    # rsp_valid with rsp_count 0: presented (no words), then acked
    st21 = status(rng, 1, 21, 0)
    m.slot(nop(20), st21)
    m.slot(ack(21, 21), st21)
    # wrong magic in an otherwise good acking frame
    s = bytearray(build_slot(22, OP_WR_INC, 0xE000, 8, items(8), ack_seq=21, ack_valid=1))
    s[1] ^= 0x01
    m.slot(bytes(s), idle())
    # back to back, random shapes; odd k present a response, acked on alternate ones
    for k in range(10):
        op = rng.choice([OP_WR_INC, OP_WR_FIX, OP_RD_INC, OP_RD_FIX, OP_MEM_RD, OP_NOP])
        cnt = rng.randrange(1, MAX_ITEMS + 1)
        if op == OP_MEM_RD:
            cnt = 8 * rng.randrange(1, 63)
        its = items(cnt) if op in (OP_WR_INC, OP_WR_FIX) else None
        rs = 100 + k
        st = status(rng, 1, rs, rng.randrange(1, MAX_ITEMS + 1)) if k % 2 else idle()
        m.slot(build_slot(30 + k, op, rng.getrandbits(16) & ~3, cnt, its,
                          ack_seq=rs, ack_valid=int(k % 4 == 1)), st)
    m.end()
    with open(out, "w") as f:
        f.write(FORMAT)
        f.write("\n".join(m.lines) + "\n")
    sys.stderr.write("%d slots, %d acks\n" % (len(m.lines) - 1, m.nack))


if __name__ == "__main__":
    main()
