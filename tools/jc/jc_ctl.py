"""Jungle Cat USER3 control protocol: TDI slot builder, TDO slot parser.

Spec: docs/superpowers/plans/2026-10-07-jc-engine-composition.md, Task 2
("Protocol (exact)"), as amended by the Task 2/6 review rulings (commits
250010c, 5547681): host-driven ack ([215:184] ack_seq, [216] ack_valid on the
header) and the two status CRCs (rsp_crc [212:181], st_crc [383:352]). Slot shape
(16,384 bits, LSB first), word size (256 bits), and the frame CRC convention
(CRC-32 over the first 16,128 bits, at bits 16128..16159) all follow
tools/jc/jc_frame.py, the loader's own definition; rsp_crc and st_crc use the
same zlib.crc32 convention, "loader conventions" per the ruling.
"""
import argparse, importlib.util, os, struct, sys, zlib

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

# header word, ack fields (Ruling 2026-10-07)
ACK_SEQ_LO, ACK_SEQ_HI = 184, 215
ACK_VALID_BIT = 216

STATUS_BITS = 384
STATUS_BYTES = STATUS_BITS // 8                  # 48
RSP_BUF_BITS = 32 * MAX_ITEMS                     # 15,872
RSP_BUF_BYTES = RSP_BUF_BITS // 8                 # 1984

# status word, the two CRCs (Ruling 2026-10-07, after the Task 6 review)
RSP_CRC_LO, RSP_CRC_HI = 181, 212
ST_CRC_LO, ST_CRC_HI = 352, 383
ST_CRC_BYTES = ST_CRC_LO // 8                     # 44: st_crc covers status bits [351:0]

BAD_ST = object()      # parse_tdo: a status whose st_crc does not check. No field of
                        # a BAD_ST status is ever used; it is returned, never raised,
                        # so a caller need not special-case an exception to get it.


def header(seq, op, addr, count, nwords, ack_seq=0, ack_valid=0):
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
    if not 0 <= ack_seq <= 0xFFFFFFFF:
        raise ValueError("ack_seq out of range: %d" % ack_seq)
    if ack_valid not in (0, 1):
        raise ValueError("ack_valid must be 0 or 1: %r" % (ack_valid,))
    v = (MAGIC | (seq & 0xFFFFFFFF) << 32 | (op & 0xFF) << 64 | (count & 0xFFFF) << 72
         | (nwords & 0xFFFF) << 104 | addr << 120
         | (ack_seq & 0xFFFFFFFF) << ACK_SEQ_LO | (ack_valid & 1) << ACK_VALID_BIT)
    return v.to_bytes(WORD_BYTES, "little")


def parse_header(hdr):
    """Decode a 32-byte header word. Used only by this module's own `gen`; tests
    that check build_slot must decode independently, not through this function."""
    v = int.from_bytes(hdr[:WORD_BYTES], "little")
    return dict(magic=v & 0xFFFFFFFF, seq=(v >> 32) & 0xFFFFFFFF, op=(v >> 64) & 0xFF,
                count=(v >> 72) & 0xFFFF, nwords=(v >> 104) & 0xFFFF,
                addr=(v >> 120) & ((1 << 64) - 1),
                ack_seq=(v >> ACK_SEQ_LO) & 0xFFFFFFFF,
                ack_valid=(v >> ACK_VALID_BIT) & 1)


def slot_crc_ok(slot):
    return struct.unpack_from("<I", slot, CRC_OFFSET)[0] == zlib.crc32(slot[:CRC_OFFSET]) & 0xFFFFFFFF


def slot_hex(slot):
    return "%04096x" % int.from_bytes(slot, "little")


def build_slot(seq, op, addr, items, count, ack_seq=0, ack_valid=0):
    """Build one 2048-byte TDI slot: header word 0, 62 payload words, CRC-32 over
    the first 16,128 bits at bits 16128..16159, zero padding after. `ack_seq`/
    `ack_valid` default to no ack, backward compatible with every pre-2026-10-07
    caller; a PASS frame with ack_valid=1 and ack_seq equal to the rsp_seq being
    presented in that slot acks the response (Ruling 2026-10-07)."""
    if op in WRITE_OPS:
        if items is None or len(items) != count:
            raise ValueError("WR op needs len(items) == count: items=%r count=%d" %
                              (None if items is None else len(items), count))
        nwords = (count + ITEMS_PER_WORD - 1) // ITEMS_PER_WORD
    else:
        nwords = 0
    hdr = header(seq, op, addr, count, nwords, ack_seq, ack_valid)
    if op in WRITE_OPS:
        payload = b"".join(struct.pack("<I", it & 0xFFFFFFFF) for it in items)
        payload = payload.ljust(MAX_PAYLOAD_BYTES, b"\0")
    else:
        payload = bytes(MAX_PAYLOAD_BYTES)
    body = hdr + payload
    assert len(body) == CRC_OFFSET
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return body + struct.pack("<I", crc) + bytes(SLOT_BYTES - CRC_OFFSET - 4)


def rsp_crc_ok(st):
    """rsp_crc checks: CRC-32 (zlib's: reflected, init and final xor all ones, the
    loader frame CRC's convention) over the rsp_count response words as shifted
    (each word little endian). False (never raises) if rsp_count is not a legal
    item count, so a corrupt or stale rsp_count cannot be used to index `rsp`."""
    n = st["rsp_count"]
    if not 1 <= n <= MAX_ITEMS:
        return False
    data = b"".join(struct.pack("<I", w & 0xFFFFFFFF) for w in st["rsp"][:n])
    return zlib.crc32(data) & 0xFFFFFFFF == st["rsp_crc"]


def parse_tdo(slot):
    """Decode one 2048-byte TDO slot: 384-bit status word, then up to 496 32-bit
    response words (word 0 first, each word LSB first).

    st_crc ([383:352], CRC-32 over status bits [351:0] as shifted) is verified
    FIRST, before any other field -- including the magic -- is even looked at:
    returns the BAD_ST sentinel on a mismatch, never a dict, so nothing downstream
    can accidentally use a field of an untrustworthy status. Only once st_crc
    checks does the magic get checked (ValueError on a mismatch, as before), and
    only then are the remaining fields decoded, including rsp_crc, whose match
    against the response words is verified and exposed as rsp_crc_ok (exposed,
    never raised: a bad response is a fact about the data, not a malformed slot).
    """
    if len(slot) != SLOT_BYTES:
        raise ValueError("TDO slot must be %d bytes: got %d" % (SLOT_BYTES, len(slot)))
    st_bytes = slot[:STATUS_BYTES]
    v = int.from_bytes(st_bytes, "little")
    computed_st_crc = zlib.crc32(st_bytes[:ST_CRC_BYTES]) & 0xFFFFFFFF
    stored_st_crc = (v >> ST_CRC_LO) & 0xFFFFFFFF
    if stored_st_crc != computed_st_crc:
        return BAD_ST
    magic = v & 0xFFFFFFFF
    if magic != STAT_MAGIC:
        raise ValueError("bad STAT magic: %#x (want %#x)" % (magic, STAT_MAGIC))
    rsp_bytes = slot[STATUS_BYTES:STATUS_BYTES + RSP_BUF_BYTES]
    rsp = [int.from_bytes(rsp_bytes[i:i + 4], "little") for i in range(0, len(rsp_bytes), 4)]
    d = dict(
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
        rsp_crc=(v >> RSP_CRC_LO) & 0xFFFFFFFF,
        st_crc=stored_st_crc,
        rsp=rsp,
    )
    d["rsp_crc_ok"] = rsp_crc_ok(d)
    return d


# ---------------------------------------------------------------------------
# `gen`: write a jc_ctl bench vector file.
#
# sim/gen_jc_ctl_vec.py (Task 2) is the format's and the stale-rule model's own
# reference implementation, and its own docstring says Task 5's `gen` "replaces
# this script and must write the same format". The surest way to write the same
# format, byte for byte, with no second implementation to drift out of step, is
# to run that committed script itself against the requested path: it is read
# here, never edited (the global constraint), and this module owns no copy of
# its Model class or its vector lines.
# ---------------------------------------------------------------------------

def _load_ref_gen():
    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(here))
    ref_path = os.path.join(repo_root, "sim", "gen_jc_ctl_vec.py")
    spec = importlib.util.spec_from_file_location("_jc_ctl_ref_gen", ref_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def gen(path):
    """Write a jc_ctl_frame_vec.txt-format vector file to `path`, byte-identical to
    sim/gen_jc_ctl_vec.py's own output for the same path (same seed, same cases: it
    IS that script, loaded and run against `path`)."""
    mod = _load_ref_gen()
    saved_argv = sys.argv
    try:
        sys.argv = ["gen_jc_ctl_vec.py", path]
        mod.main()
    finally:
        sys.argv = saved_argv
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
