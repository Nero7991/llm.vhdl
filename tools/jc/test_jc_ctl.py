import os, struct, sys, zlib
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import jc_ctl as C


def _decode_header(hdr32):
    """Independent decoder: does not call C.parse_header, so a build_slot bug in the
    packing direction cannot hide behind a matching bug in the library's own decode."""
    v = int.from_bytes(hdr32, "little")
    return dict(magic=v & 0xFFFFFFFF, seq=(v >> 32) & 0xFFFFFFFF, op=(v >> 64) & 0xFF,
                count=(v >> 72) & 0xFFFF, nwords=(v >> 104) & 0xFFFF,
                addr=(v >> 120) & ((1 << 64) - 1))


def _decode_items(payload, n):
    return [int.from_bytes(payload[i:i + 4], "little") for i in range(0, 4 * n, 4)]


def test_build_slot_round_trips_wr_inc():
    items = [0x11111111, 0x22222222, 0x33333333]
    s = C.build_slot(5, C.OP_WR_INC, 0x40, items, 3)
    assert len(s) == C.SLOT_BYTES == 2048
    h = _decode_header(s[:32])
    assert (h["magic"], h["seq"], h["op"], h["count"], h["nwords"], h["addr"]) == \
        (C.MAGIC, 5, C.OP_WR_INC, 3, 1, 0x40)
    payload = s[32:32 + C.MAX_PAYLOAD_BYTES]
    assert _decode_items(payload, 3) == items
    assert payload[12:] == bytes(len(payload) - 12)


def test_build_slot_round_trips_mem_rd():
    s = C.build_slot(9, C.OP_MEM_RD, 0x2000, None, 16)
    h = _decode_header(s[:32])
    assert (h["magic"], h["seq"], h["op"], h["count"], h["nwords"], h["addr"]) == \
        (C.MAGIC, 9, C.OP_MEM_RD, 16, 0, 0x2000)
    assert s[32:32 + C.MAX_PAYLOAD_BYTES] == bytes(C.MAX_PAYLOAD_BYTES)


def test_crc_matches_zlib_over_first_16128_bits():
    assert C.CRC_OFFSET * 8 == 16128
    s = C.build_slot(1, C.OP_RD_INC, 0x100, None, 4)
    crc = struct.unpack_from("<I", s, C.CRC_OFFSET)[0]
    assert crc == zlib.crc32(s[:C.CRC_OFFSET]) & 0xFFFFFFFF
    assert s[C.CRC_OFFSET + 4:] == bytes(C.SLOT_BYTES - C.CRC_OFFSET - 4)


def test_count_bounds_rejected():
    with pytest.raises(ValueError):
        C.build_slot(0, C.OP_NOP, 0, None, 0)
    with pytest.raises(ValueError):
        C.build_slot(0, C.OP_NOP, 0, None, 497)
    # the boundary values themselves must be accepted
    assert len(C.build_slot(0, C.OP_RD_INC, 0, None, 1)) == C.SLOT_BYTES
    assert len(C.build_slot(0, C.OP_RD_INC, 0, None, 496)) == C.SLOT_BYTES


def test_wr_ops_need_matching_items_length():
    with pytest.raises(ValueError):
        C.build_slot(0, C.OP_WR_INC, 0x40, [1, 2], 3)
    with pytest.raises(ValueError):
        C.build_slot(0, C.OP_WR_FIX, 0x40, None, 3)


def test_mem_rd_needs_aligned_addr_and_count_multiple_of_8():
    with pytest.raises(ValueError):
        C.build_slot(0, C.OP_MEM_RD, 0x10, None, 8)    # not 32-byte aligned
    with pytest.raises(ValueError):
        C.build_slot(0, C.OP_MEM_RD, 0x40, None, 7)    # not a multiple of 8
    s = C.build_slot(0, C.OP_MEM_RD, 0x40, None, 8)
    assert len(s) == C.SLOT_BYTES


def test_flipped_payload_bit_fails_crc():
    s = bytearray(C.build_slot(2, C.OP_WR_FIX, 0x80, [0xAB] * 3, 3))
    s[100] ^= 0x04
    assert not C.slot_crc_ok(bytes(s))


# ---------------------------------------------------------------------------
# parse_tdo: decoded against an independent packer, not C.parse_header/header.
# ---------------------------------------------------------------------------

def _pack_tdo(magic, last_done_seq, rsp_seq, rsp_count, rsp_valid, axi_err, axi_resp,
              err_seq, desync, ovf, crc_fail, rsp_words):
    v = magic & 0xFFFFFFFF
    v |= (last_done_seq & 0xFFFFFFFF) << 32
    v |= (rsp_seq & 0xFFFFFFFF) << 64
    v |= (rsp_count & 0xFFFF) << 96
    v |= (rsp_valid & 1) << 112
    v |= (axi_err & 1) << 113
    v |= (axi_resp & 0x3) << 114
    v |= (err_seq & 0xFFFFFFFF) << 116
    v |= (desync & 0xFFFF) << 148
    v |= (ovf & 1) << 164
    v |= (crc_fail & 0xFFFF) << 165
    status = v.to_bytes(C.STATUS_BYTES, "little")
    payload = b"".join(struct.pack("<I", w & 0xFFFFFFFF) for w in rsp_words)
    payload = payload.ljust(C.RSP_BUF_BYTES, b"\0")
    return (status + payload).ljust(C.SLOT_BYTES, b"\0")


def test_parse_tdo_decodes_status_and_response():
    rsp_words = [0xAAAAAAAA, 0xBBBBBBBB, 0x00000001]
    slot = _pack_tdo(C.STAT_MAGIC, last_done_seq=9, rsp_seq=7, rsp_count=3, rsp_valid=1,
                      axi_err=1, axi_resp=2, err_seq=42, desync=5, ovf=1, crc_fail=6,
                      rsp_words=rsp_words)
    d = C.parse_tdo(slot)
    assert d["last_done_seq"] == 9
    assert d["rsp_seq"] == 7
    assert d["rsp_count"] == 3
    assert d["rsp_valid"] == 1
    assert d["axi_err"] == 1
    assert d["axi_resp"] == 2
    assert d["err_seq"] == 42
    assert d["desync"] == 5
    assert d["ovf"] == 1
    assert d["crc_fail"] == 6
    assert len(d["rsp"]) == C.MAX_ITEMS
    assert d["rsp"][:3] == rsp_words
    assert d["rsp"][3:] == [0] * (C.MAX_ITEMS - 3)


def test_parse_tdo_rsp_seq_none_sentinel():
    slot = _pack_tdo(C.STAT_MAGIC, 1, C.RSP_SEQ_NONE, 0, 0, 0, 0, 0, 0, 0, 0, [])
    assert C.parse_tdo(slot)["rsp_seq"] == 0xFFFFFFFF


def test_parse_tdo_rejects_bad_magic():
    slot = _pack_tdo(0xDEADBEEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, [])
    with pytest.raises(ValueError):
        C.parse_tdo(slot)


def test_parse_tdo_rejects_wrong_length():
    with pytest.raises(ValueError):
        C.parse_tdo(bytes(100))
