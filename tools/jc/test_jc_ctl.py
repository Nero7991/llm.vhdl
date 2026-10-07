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
                addr=(v >> 120) & ((1 << 64) - 1),
                ack_seq=(v >> 184) & 0xFFFFFFFF, ack_valid=(v >> 216) & 1)


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
              err_seq, desync, ovf, crc_fail, rsp_words, rsp_crc=None, bad_st_crc=False):
    """Independent encoder, the counterpart of _decode_header: does not call
    C.header/C.parse_header/C.parse_tdo. rsp_crc defaults to the CRC-32 (zlib, the
    loader's own convention) of rsp_words[:rsp_count], the plan's "as shifted"; pass
    an explicit value to build a deliberate mismatch. st_crc is always computed
    correctly over status bits [351:0] unless bad_st_crc flips one of its bits, so
    every existing caller gets a self-consistent status for free."""
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
    if rsp_crc is None:
        data = b"".join(struct.pack("<I", w & 0xFFFFFFFF) for w in rsp_words[:rsp_count])
        rsp_crc = zlib.crc32(data) & 0xFFFFFFFF
    v |= (rsp_crc & 0xFFFFFFFF) << 181
    st_crc = zlib.crc32((v & ((1 << 352) - 1)).to_bytes(44, "little")) & 0xFFFFFFFF
    if bad_st_crc:
        st_crc ^= 1
    v |= (st_crc & 0xFFFFFFFF) << 352
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
    data = b"".join(struct.pack("<I", w) for w in rsp_words)
    assert d["rsp_crc"] == zlib.crc32(data) & 0xFFFFFFFF
    assert d["rsp_crc_ok"] is True


# ---------------------------------------------------------------------------
# 2026-10-07 realignment: host-driven ack (header [215:184]/[216]) and the two
# CRCs (status rsp_crc [212:181], st_crc [383:352]).
# ---------------------------------------------------------------------------

def test_build_slot_ack_defaults_to_no_ack():
    s = C.build_slot(0, C.OP_NOP, 0, None, 1)
    h = _decode_header(s[:32])
    assert h["ack_seq"] == 0 and h["ack_valid"] == 0


def test_build_slot_ack_fields_round_trip():
    s = C.build_slot(5, C.OP_RD_INC, 0x40, None, 4, ack_seq=0x1234, ack_valid=1)
    h = _decode_header(s[:32])
    assert h["ack_seq"] == 0x1234 and h["ack_valid"] == 1
    # reserved bits [255:217] stay zero
    v = int.from_bytes(s[:32], "little")
    assert v >> 217 == 0


def test_header_rejects_bad_ack_fields():
    with pytest.raises(ValueError):
        C.build_slot(0, C.OP_NOP, 0, None, 1, ack_seq=1 << 32, ack_valid=1)
    with pytest.raises(ValueError):
        C.build_slot(0, C.OP_NOP, 0, None, 1, ack_seq=0, ack_valid=2)


def test_parse_tdo_detects_rsp_crc_mismatch_without_raising():
    rsp_words = [1, 2, 3]
    slot = _pack_tdo(C.STAT_MAGIC, 0, 7, 3, 1, 0, 0, 0, 0, 0, 0, rsp_words,
                      rsp_crc=0xDEADBEEF)
    d = C.parse_tdo(slot)
    assert d["rsp_crc"] == 0xDEADBEEF
    assert d["rsp_crc_ok"] is False


def test_parse_tdo_returns_bad_st_sentinel_on_st_crc_mismatch():
    slot = _pack_tdo(C.STAT_MAGIC, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, [], bad_st_crc=True)
    result = C.parse_tdo(slot)
    assert result is C.BAD_ST


def test_st_crc_checked_before_magic_is_ever_used():
    """A bad st_crc must short-circuit before the magic field (or any other field) is
    even looked at: a slot with BOTH a wrong magic and a wrong st_crc must come back
    BAD_ST, never the ValueError that a wrong magic alone raises."""
    slot = _pack_tdo(0xDEADBEEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, [], bad_st_crc=True)
    assert C.parse_tdo(slot) is C.BAD_ST


def test_rsp_crc_ok_helper_matches_parse_tdo():
    rsp_words = [9, 8, 7, 6]
    slot = _pack_tdo(C.STAT_MAGIC, 0, 3, 4, 1, 0, 0, 0, 0, 0, 0, rsp_words)
    d = C.parse_tdo(slot)
    assert C.rsp_crc_ok(d) == d["rsp_crc_ok"] == True


def test_gen_entry_point_execs_the_committed_generator(tmp_path):
    """NOT a check of jc_ctl's encoder. `gen` deliberately delegates to the committed
    sim/gen_jc_ctl_vec.py (Task 2's own generator) rather than re-implementing its
    vectors, so this only proves that delegation is wired up (gen's own entry point
    reproduces that script's file) -- it is `gen` execing sim/gen_jc_ctl_vec.py and then
    comparing the result to sim/gen_jc_ctl_vec.py's own output, i.e. A calling A equals
    A. It says nothing about jc_ctl.build_slot/jc_ctl.parse_tdo, the functions the
    broker actually calls against hardware: see
    test_production_encoder_and_decoder_match_the_sim_models_independent_implementation
    below for the cross-check that exercises those directly, against the sim model's
    own independent implementation, not through this delegation."""
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    committed = os.path.join(repo, "sim", "jc_ctl_frame_vec.txt")
    out = tmp_path / "jc_ctl_frame_vec.txt"
    C.gen(str(out))
    with open(committed, "rb") as f:
        want = f.read()
    assert out.read_bytes() == want


def _expected_tdo_status_bytes(st_in_v, rspv, nrsp, desync, ovf, crcf):
    """The real TDO status for one slot, built by the rule documented at the top of
    sim/jc_ctl_frame_vec.txt: st_in with the core's own fields forced (magic, rsp_count,
    rsp_valid, desync, ovf, crc_fail) and [351:213] zeroed, then st_crc computed over
    bits [351:0] and appended. Independent bit math: does not call jc_ctl.header,
    jc_ctl.parse_header or jc_ctl.parse_tdo."""
    v = st_in_v & ((1 << 384) - 1)

    def put(v, lo, width, x):
        m = ((1 << width) - 1) << lo
        return (v & ~m) | ((x << lo) & m)

    v = put(v, 0, 32, 0x4A435354)
    v = put(v, 96, 16, nrsp)
    v = put(v, 112, 1, rspv)
    v = put(v, 148, 16, desync & 0xFFFF)
    v = put(v, 164, 1, ovf)
    v = put(v, 165, 16, crcf & 0xFFFF)
    v = put(v, 213, 139, 0)                         # [351:213] forced zero
    st_crc = zlib.crc32((v & ((1 << 352) - 1)).to_bytes(44, "little")) & 0xFFFFFFFF
    v = put(v, 352, 32, st_crc)
    return v.to_bytes(48, "little")


def test_production_encoder_and_decoder_match_the_sim_models_independent_implementation(tmp_path):
    """Cross-checks jc_ctl's PRODUCTION encoder and decoder -- header/build_slot and
    parse_tdo, the functions the broker actually ships to and reads from hardware --
    against sim/gen_jc_ctl_vec.py's own, independent implementation (its build_slot at
    sim/gen_jc_ctl_vec.py:40-53 for TDI, its Model.slot's TDO construction, documented
    at the top of sim/jc_ctl_frame_vec.txt, for TDO), for every case that script's
    main() builds while writing the vector file.

    Unlike test_gen_entry_point_execs_the_committed_generator, this never goes through
    jc_ctl.gen: it loads the sim script, monkeypatches its module-level `build_slot`
    and its `Model.slot` method to intercept the exact arguments main() uses (same
    seed, same cases, run live rather than re-parsed from committed text), calls each
    sim construction once as before, and in the same breath builds/parses the identical
    case with jc_ctl's own functions, asserting the bytes (TDI) or every decoded field
    (TDO) agree. A case the sim model can express but jc_ctl deliberately cannot build
    (an out-of-range count, a magic or nwords override -- jc_ctl.build_slot has no
    parameter for either) is skipped with an explicit reason instead of asserted on.
    """
    mod = C._load_ref_gen()
    sim_build_slot = mod.build_slot
    orig_model_slot = mod.Model.slot
    checked, skipped, tdo_checked = [], [], []

    def build_wrapper(seq, op, addr, count, items=None, nwords=None, magic=mod.MAGIC,
                       ack_seq=0, ack_valid=0):
        sim_slot = sim_build_slot(seq, op, addr, count, items, nwords, magic,
                                   ack_seq, ack_valid)
        if magic != mod.MAGIC:
            skipped.append("seq=%d op=%d: magic override %#x -- jc_ctl.build_slot "
                            "always writes MAGIC, it cannot forge another"
                            % (seq, op, magic))
        elif nwords is not None:
            skipped.append("seq=%d op=%d count=%d: nwords override %d -- "
                            "jc_ctl.build_slot has no nwords parameter, it always "
                            "derives nwords from count" % (seq, op, count, nwords))
        else:
            try:
                ours = C.build_slot(seq, op, addr, (list(items) if items else None),
                                     count, ack_seq=ack_seq, ack_valid=ack_valid)
            except ValueError as e:
                skipped.append("seq=%d op=%d count=%d addr=%#x: jc_ctl.build_slot "
                                "refuses it (%s)" % (seq, op, count, addr, e))
            else:
                assert ours == sim_slot, (
                    "seq=%d op=%d addr=%#x count=%d: jc_ctl.build_slot produced a "
                    "DIFFERENT slot than the sim model's own build_slot"
                    % (seq, op, addr, count))
                checked.append(seq)
        return sim_slot

    def slot_wrapper(self, s, st, nbits=mod.SLOT_BITS, endscan=0, wready=1):
        orig_model_slot(self, s, st, nbits=nbits, endscan=endscan, wready=wready)
        # "S" nbits endscan wready ack rspv nrsp desync crcf ovf st_in slot npush ...
        fields = self.lines[-1].split()
        rspv, nrsp = int(fields[5]), int(fields[6])
        desync, crcf, ovf = int(fields[7]), int(fields[8]), int(fields[9])
        st_in_v = int(fields[10], 16)
        tdo = _expected_tdo_status_bytes(st_in_v, rspv, nrsp, desync, ovf, crcf) \
            .ljust(C.SLOT_BYTES, b"\0")
        d = C.parse_tdo(tdo)
        assert d is not C.BAD_ST, "our own expected status failed its own st_crc check"
        assert d["last_done_seq"] == (st_in_v >> 32) & 0xFFFFFFFF
        assert d["rsp_seq"] == (st_in_v >> 64) & 0xFFFFFFFF
        assert d["rsp_count"] == nrsp
        assert d["rsp_valid"] == rspv
        assert d["axi_err"] == (st_in_v >> 113) & 1
        assert d["axi_resp"] == (st_in_v >> 114) & 0x3
        assert d["err_seq"] == (st_in_v >> 116) & 0xFFFFFFFF
        assert d["desync"] == desync & 0xFFFF
        assert d["ovf"] == ovf
        assert d["crc_fail"] == crcf & 0xFFFF
        assert d["rsp_crc"] == (st_in_v >> 181) & 0xFFFFFFFF
        tdo_checked.append(True)

    mod.build_slot = build_wrapper
    mod.Model.slot = slot_wrapper
    try:
        sys.argv = ["gen_jc_ctl_vec.py", str(tmp_path / "ignored_jc_ctl_frame_vec.txt")]
        mod.main()
    finally:
        mod.build_slot = sim_build_slot
        mod.Model.slot = orig_model_slot

    # Sanity on the cross-check itself, not just on jc_ctl: both buckets must be
    # non-trivial, or this test would be vacuously green (everything skipped, or
    # nothing ever run).
    assert len(checked) >= 30, "too few TDI cases actually compared: %d" % len(checked)
    assert len(skipped) >= 1, "expected at least one deliberately-unbuildable case"
    assert len(tdo_checked) >= 30, "too few TDO cases actually compared: %d" % len(tdo_checked)


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
