import os, struct, sys, zlib
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import jc_frame as F
from jc.jc_model import LoaderModel

def test_slot_layout_and_crc():
    s = F.build_slot(7, 0x1000, b"\x11" * 64)
    assert len(s) == F.SLOT_BYTES
    h = F.parse_header(s)
    assert (h["magic"], h["seq"], h["addr"], h["nwords"]) == (F.MAGIC_FRAME, 7, 0x1000, 2)
    assert struct.unpack_from("<I", s, F.CRC_OFFSET)[0] == zlib.crc32(s[:F.CRC_OFFSET]) & 0xFFFFFFFF
    assert s[F.CRC_OFFSET + 4:] == bytes(F.SLOT_BYTES - F.CRC_OFFSET - 4)
    assert F.slot_crc_ok(s)

def test_flipped_bit_fails_crc():
    s = bytearray(F.build_slot(1, 0, b"\xAB" * 1984))
    s[100] ^= 0x04
    assert not F.slot_crc_ok(bytes(s))

def test_header_rejects_bad_input():
    with pytest.raises(ValueError):
        F.header(0, 0x10, 1)            # not 32-byte aligned
    with pytest.raises(ValueError):
        F.build_slot(0, 0, b"\0" * 1985)  # over 62 words

def test_status_round_trip():
    d = dict(magic=F.MAGIC_STAT, last=5, committed=6, crc_fail=1, seq_err=2, desync=3,
             bresp_err=4, dup=5, busy=1, hbm_trip=0, range_valid=1, fifo_ovf=0,
             range_rerr=0, range_crc=0xDEADBEEF, range_seq=9)
    assert F.parse_status(F.pack_status(d)) == d

def test_bursts_respect_16_beats_and_4k():
    assert F.bursts(0x0, 62) == [(0x0, 16), (0x200, 16), (0x400, 16), (0x600, 14)]
    assert F.bursts(0xFE0, 3) == [(0xFE0, 1), (0x1000, 2)]

def test_model_commits_in_order_and_counts():
    m = LoaderModel()
    m.feed(bytes(F.SLOT_BYTES))                       # filler: desync
    m.feed(F.build_slot(0, 0x40, b"\x01" * 32))
    m.feed(F.build_slot(0, 0x40, b"\x02" * 32))       # duplicate
    m.feed(F.build_slot(2, 0x80, b"\x03" * 32))       # gap
    bad = bytearray(F.build_slot(1, 0x60, b"\x04" * 32)); bad[40] ^= 1
    m.feed(bytes(bad))                                # crc fail
    m.feed(F.build_slot(1, 0x60, b"\x05" * 32))
    m.feed(F.poll_slot())
    st = m.status()
    assert (st["desync"], st["dup"], st["seq_err"], st["crc_fail"]) == (1, 1, 1, 1)
    assert (st["last"], st["committed"]) == (1, 2)
    assert m.mem[0x40] == b"\x01" * 32 and m.mem[0x60] == b"\x05" * 32 and 0x80 not in m.mem

def test_model_range_crc():
    m = LoaderModel()
    m.feed(F.build_slot(0, 0x100, bytes(range(64))))
    m.feed(F.range_crc_slot(1, 0x100, 64))
    st = m.status()
    assert st["range_valid"] == 1 and st["range_seq"] == 1
    assert st["range_crc"] == zlib.crc32(bytes(range(64))) & 0xFFFFFFFF

def test_model_counts_bresp_per_burst():
    m = LoaderModel(bad_bresp_addrs={0x200})
    m.feed(F.build_slot(0, 0x0, b"\x07" * 1984))       # bursts at 0x0, 0x200, 0x400, 0x600
    assert m.status()["bresp_err"] == 1
