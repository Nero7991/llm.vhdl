import os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import coe
from jc.derive_resync import search as derive_resync_search, verify as derive_resync_verify

# Captured from the stock sqrl_bridge on 2026-10-05 (debugging doc S12).
CAPTURED = {"reset": "00000600001f", "toIR": "000004000003", "exitIR": "000002000001",
            "toDR": "000003000001", "exit": "000003000003"}

# A sample of the opcodes in xcvu35p_fsvh2104.bsd that are not on the allowlist (copied
# from the BSDL). The real proof that the allowlist accepts ONLY the four allowed values
# is test_allowlist_accepts_exactly_four_opcodes, which sweeps all 4096 twelve-bit values;
# these twelve (JPROGRAM and the eFUSE-programming opcodes among them) are a sample used
# to parametrize the refusal test, not the exhaustive check.
DANGEROUS = ["001011001011", "010001010001", "110000100100", "110001100100", "110010100100",
             "110100100100", "110011100100", "011001100100", "100100110000", "100100110001",
             "100100110010", "100100110100"]

class FakeSocket:
    """Records every sendall() and answers each request with a scripted payload (by cmd)
    or, with none scripted, a generic STATUS_OK reply with no data. Never opens a real
    socket; this is the only transport any test in this file uses."""
    def __init__(self, cmd_data=None):
        self.sent = []
        self._buf = b""
        self._cmd_data = dict(cmd_data or {})

    def sendall(self, b):
        self.sent.append(bytes(b))
        t, cmd = struct.unpack_from("<HI", b, 2)
        data = self._cmd_data.get(cmd, b"")
        self._buf += struct.pack("<HHI", 8 + len(data), t, coe.STATUS_OK) + data

    def recv(self, n):
        c, self._buf = self._buf[:n], self._buf[n:]
        return c

    def setsockopt(self, *a):
        pass

class RaisingSocket:
    """sendall() always raises -- models a dead transport, never a real one."""
    def __init__(self):
        self.sent = []
    def sendall(self, b):
        raise BrokenPipeError("fake transport closed")
    def recv(self, n):
        raise ConnectionError("fake transport closed")

def make_coe(sock=None, tap=coe.RUN_TEST_IDLE):
    c = coe.CoE.__new__(coe.CoE)
    c.s = sock if sock is not None else FakeSocket()
    c.txn = 1
    c.tap = tap
    return c

def test_tms_payloads_match_the_bridge_byte_for_byte():
    assert coe.tms_payload([1, 1, 1, 1, 1, 0]).hex() == CAPTURED["reset"]
    assert coe.tms_payload([1, 1, 0, 0]).hex() == CAPTURED["toIR"]
    assert coe.tms_payload([1, 0]).hex() == CAPTURED["exitIR"]
    assert coe.tms_payload([1, 0, 0]).hex() == CAPTURED["toDR"]
    assert coe.tms_payload([1, 1, 0]).hex() == CAPTURED["exit"]

@pytest.mark.parametrize("op", DANGEROUS)
def test_allowlist_refuses_jprogram_and_fuse_opcodes(op):
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([coe.IR_USER4, int(op, 2)])

def test_allowlist_accepts_exactly_four_opcodes():
    ok = []
    for v in range(4096):
        try:
            coe.ir_scan_payload([v, coe.IR_BYPASS])
            ok.append(v)
        except coe.IRNotAllowed:
            pass
    assert sorted(ok) == sorted(coe.IR_ALLOW)

def test_allowlist_teeth(monkeypatch):
    """The same refusal test must FAIL if the allowlist is disabled."""
    monkeypatch.setattr(coe, "IR_ALLOW", set(range(4096)))
    coe.ir_scan_payload([coe.IR_USER4, int(DANGEROUS[0], 2)])   # no exception now

def test_ir_scan_shifts_the_tdo_side_device_first():
    p = coe.ir_scan_payload([coe.IR_USER4, coe.IR_BYPASS])      # [near TDI, near TDO]
    pairs = p[4:]
    tdi = 0
    for k in range(3):
        tdi |= pairs[2 * k] << (8 * k)
    assert tdi & 0xFFF == coe.IR_BYPASS and (tdi >> 12) & 0xFFF == coe.IR_USER4
    assert pairs[-1] == 0x80                                     # TMS high on bit 23 only

def test_txn_never_sets_bit_15():
    c = make_coe()
    c.txn = 0x7FFE
    seen = [c.send(coe.CMD_HELLO) for _ in range(4)]
    assert seen == [0x7FFE, 0x7FFF, 1, 2]

def test_ir_scan_payload_requires_exactly_the_chain_device_count():
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([coe.IR_USER4])                     # one op
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([])                                 # empty
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([coe.IR_USER4, coe.IR_BYPASS, coe.IR_IDCODE])  # three

def test_ir_scan_refuses_jprogram_before_sending_anything():
    c = make_coe()
    with pytest.raises(coe.IRNotAllowed):
        c.ir_scan([coe.IR_USER4, int(DANGEROUS[0], 2)])
    assert c.s.sent == []

def test_raw_tms_send_refuses_a_hand_built_ir_payload_already_in_shift_ir():
    """round 1's rule, kept: clocking a bit while already in Shift-IR, untokened."""
    c = make_coe(tap=coe.SHIFT_IR)
    op = int(DANGEROUS[0], 2)
    bits = [(op >> i) & 1 for i in range(12)] + [(coe.IR_BYPASS >> i) & 1 for i in range(12)]
    bogus = coe.pair_payload(bits, [0] * 23 + [1])
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bogus)
    assert c.s.sent == []

def test_dr_shift_while_in_shift_ir_refuses_and_sends_nothing():
    c = make_coe(tap=coe.SHIFT_IR)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TDI, coe.dr_payload(8, bytes(1)))
    assert c.s.sent == []

def test_unknown_command_refused():
    c = make_coe()
    with pytest.raises(coe.TapProtocolError):
        c.send(0x12345678)
    assert c.s.sent == []

def test_start_sends_the_documented_handshake_sequence_and_resyncs():
    sock = FakeSocket(cmd_data={coe.CMD_IDCODES: coe.VU35P_X2_IDCODES})
    c = make_coe(sock, tap=coe.UNKNOWN)
    ids = c.start(hz=27_000_000)
    assert ids == coe.VU35P_X2_IDCODES
    cmds = [struct.unpack_from("<I", b, 4)[0] for b in sock.sent]
    assert cmds == [coe.CMD_HELLO, coe.CMD_SPEED, coe.CMD_MODE, coe.CMD_IDCODES,
                     coe.CMD_IRLEN, coe.CMD_MODE, coe.CMD_TMS]
    assert sock.sent[1][8:] == struct.pack("<II", 0, 27_000_000)
    assert sock.sent[2][8:] == bytes.fromhex("0002")
    assert sock.sent[3][8:] == bytes.fromhex("0000")
    assert sock.sent[4][8:] == bytes.fromhex("000c0c")
    assert sock.sent[5][8:] == bytes.fromhex("0001")
    assert sock.sent[6][8:] == coe._RESYNC_PAYLOAD        # start() resyncs, not a raw reset
    assert c.tap == coe.RUN_TEST_IDLE                     # resync's guaranteed end state

# ---------------------------------------------------------------- fix round 1: minors

def test_reply_rejects_a_header_shorter_than_eight_bytes():
    class S:
        def __init__(s2, d): s2.d = d
        def recv(s2, n): r = s2.d[:n]; s2.d = s2.d[n:]; return r
    c = coe.CoE.__new__(coe.CoE)
    c.s = S(struct.pack("<HHI", 4, 5, coe.STATUS_OK) + b"XXXX")
    with pytest.raises(coe.CoEError):
        c.reply()

def test_call_raises_on_txn_mismatch():
    sock = FakeSocket()
    c = make_coe(sock)
    real_send = c.send
    def bad_send(cmd, payload=b"", _token=None):
        t = real_send(cmd, payload, _token=_token)
        return t + 1                               # lie about our own txn
    c.send = bad_send
    with pytest.raises(coe.CoEError):
        c.call(coe.CMD_HELLO)

def test_call_raises_on_a_non_ok_status():
    class S:
        def __init__(s2): s2.sent = []; s2._buf = b""
        def sendall(s2, b):
            s2.sent.append(bytes(b))
            t = struct.unpack_from("<H", b, 2)[0]
            s2._buf += struct.pack("<HHI", 8, t, 0xDEAD0000)
        def recv(s2, n):
            c2, s2._buf = s2._buf[:n], s2._buf[n:]
            return c2
    c = make_coe(S())
    with pytest.raises(coe.CoEError):
        c.call(coe.CMD_HELLO)

def test_dr_payload_requires_matching_tdi_length():
    with pytest.raises(ValueError):
        coe.dr_payload(100, b"\0")                 # 100 bits needs 13 bytes, not 1

def test_pair_payload_requires_equal_length_and_binary_bits():
    with pytest.raises(ValueError):
        coe.pair_payload([0, 0], [0])               # unequal length
    with pytest.raises(ValueError):
        coe.pair_payload([2] + [0] * 7, [0] * 8)     # not a bit

# ======================================================================
# Fix round 2 (re-review, 2026-10-05)
# ======================================================================

# ---------------------------------------------------------------- item 1: Capture-IR
# and Update-IR-from-the-IR-side, untokened, with no shift at all

def test_untokened_capture_ir_entry_refused_and_sends_nothing():
    """RTI -> Select-DR -> Select-IR -> Capture-IR -> Exit1-IR -> Update-IR with no
    real shift: Update-IR would latch Capture-IR's value (BSDL "...01") as the live
    instruction. The review's own example."""
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, coe.tms_payload([1, 1, 0, 1, 1, 0]))
    assert c.s.sent == []

def test_untokened_update_ir_via_pause_ir_refused_and_sends_nothing():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, coe.tms_payload([1, 1, 0, 1, 0, 1, 1, 0]))
    assert c.s.sent == []

@pytest.mark.parametrize("start", [coe.CAPTURE_IR, coe.SHIFT_IR, coe.EXIT1_IR,
                                    coe.PAUSE_IR, coe.EXIT2_IR])
def test_naive_five_ones_reset_from_an_ir_side_state_refused(start):
    """The plain 'TMS=1 x5' universal-reset idiom is only safe from a DR-side, RTI, or
    TLR start -- from any IR-side state it reaches Update-IR within 1-2 bits with no
    shift at all. This is exactly why CoE.resync() exists."""
    c = make_coe(tap=start)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, coe.tms_payload([1, 1, 1, 1, 1, 0]))
    assert c.s.sent == []

def test_untokened_transition_into_capture_ir_refused_even_split_across_two_sends():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    c.call(coe.CMD_TMS, coe.tms_payload([1, 1]))          # RTI -> Select-DR -> Select-IR
    assert c.tap == coe.SELECT_IR
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, coe.tms_payload([0]))         # Select-IR -> Capture-IR
    assert c.tap == coe.SELECT_IR                         # refused: shadow did not move

# ---------------------------------------------------------------- item 2: UNKNOWN shadow

def test_new_coe_starts_with_unknown_shadow(monkeypatch):
    sock = FakeSocket()
    monkeypatch.setattr(coe.socket, "create_connection", lambda *a, **k: sock)
    c = coe.CoE("192.0.2.1")                              # TEST-NET-1, never dialled
    assert c.tap == coe.UNKNOWN

def test_unknown_shadow_refuses_tms_and_tdi():
    c = make_coe(tap=coe.UNKNOWN)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, coe.tms_payload([0]))
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TDI, coe.dr_payload(8, bytes(1)))
    assert c.s.sent == []

def test_unknown_shadow_still_allows_handshake_commands():
    c = make_coe(tap=coe.UNKNOWN)
    c.call(coe.CMD_HELLO)                                 # must not raise
    assert c.tap == coe.UNKNOWN                           # handshake never touches it

def test_unknown_shadow_is_resolved_by_resync():
    c = make_coe(tap=coe.UNKNOWN)
    c.resync()
    assert c.tap == coe.RUN_TEST_IDLE

def test_send_failure_marks_shadow_unknown():
    c = make_coe(RaisingSocket(), tap=coe.RUN_TEST_IDLE)
    with pytest.raises(Exception):
        c.call(coe.CMD_HELLO)
    assert c.tap == coe.UNKNOWN

def test_reply_failure_marks_shadow_unknown():
    """reply() itself raising (not just a mismatched txn/status on an otherwise-good
    reply) must also force the shadow to UNKNOWN. A reply that declares a length
    shorter than its own 8-byte header is reply()'s own CoEError, independent of
    whatever bytes happen to follow on the wire."""
    class S:
        def __init__(s2): s2.sent = []; s2._buf = b""
        def sendall(s2, b):
            s2.sent.append(bytes(b))
            t = struct.unpack_from("<H", b, 2)[0]
            s2._buf += struct.pack("<HHI", 4, t, coe.STATUS_OK) + b"XXXX"
        def recv(s2, n):
            c2, s2._buf = s2._buf[:n], s2._buf[n:]
            return c2
    c = make_coe(S(), tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.CoEError):
        c.call(coe.CMD_HELLO)
    assert c.tap == coe.UNKNOWN

def test_bad_status_marks_shadow_unknown():
    class S:
        def __init__(s2): s2.sent = []; s2._buf = b""
        def sendall(s2, b):
            s2.sent.append(bytes(b))
            t = struct.unpack_from("<H", b, 2)[0]
            s2._buf += struct.pack("<HHI", 8, t, 0xDEAD0000)
        def recv(s2, n):
            c2, s2._buf = s2._buf[:n], s2._buf[n:]
            return c2
    c = make_coe(S(), tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.CoEError):
        c.call(coe.CMD_HELLO)
    assert c.tap == coe.UNKNOWN

def test_txn_mismatch_marks_shadow_unknown():
    sock = FakeSocket()
    c = make_coe(sock, tap=coe.RUN_TEST_IDLE)
    real_send = c.send
    def bad_send(cmd, payload=b"", _token=None):
        t = real_send(cmd, payload, _token=_token)
        return t + 1
    c.send = bad_send
    with pytest.raises(coe.CoEError):
        c.call(coe.CMD_HELLO)
    assert c.tap == coe.UNKNOWN

def test_a_validation_refusal_does_not_touch_the_shadow():
    """Nothing was sent, so nothing is known to have changed: a refused send must
    leave the shadow exactly as it was, not force it to UNKNOWN."""
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, coe.tms_payload([1, 1, 0, 1, 1, 0]))  # item 1's own example
    assert c.tap == coe.RUN_TEST_IDLE

def test_shadow_advances_only_after_confirmed_success():
    sock = FakeSocket()
    c = make_coe(sock, tap=coe.RUN_TEST_IDLE)
    c.call(coe.CMD_TMS, coe.tms_payload([1, 0, 0]))       # toDR
    assert c.tap == coe.SHIFT_DR

def test_resync_derivation_matches_the_committed_sequence():
    """A hand-transcription error in coe._RESYNC_TMS would not show up any other way:
    re-run the same exhaustive search and compare."""
    assert list(derive_resync_search()) == coe._RESYNC_TMS

def test_resync_sequence_is_safe_and_convergent_from_every_start_state():
    ok, bad_s0, why = derive_resync_verify(tuple(coe._RESYNC_TMS))
    assert ok, "start=%r %s" % (bad_s0, why)

def test_resync_escapes_the_round_1_shift_ir_dead_end():
    c = make_coe(tap=coe.SHIFT_IR)
    c.resync()
    assert c.tap == coe.RUN_TEST_IDLE
    assert len(c.s.sent) == 1                             # one CMD_TMS call, the whole sequence

def test_resync_token_requires_the_exact_derived_payload():
    c = make_coe(tap=coe.UNKNOWN)
    wrong = coe.tms_payload([1, 1, 1, 1, 1, 0])            # the old naive reset, not resync's
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, wrong, _token=coe._RESYNC_TOKEN)
    assert c.s.sent == []

# ---------------------------------------------------------------- item 3: ir_shift_all_ones >= 24

@pytest.mark.parametrize("n", [1, 11, 12, 23])
def test_ir_shift_all_ones_refuses_fewer_than_24_bits(n):
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(ValueError):
        c.ir_shift_all_ones(n)
    assert c.s.sent == []

@pytest.mark.parametrize("n", [24, 25, 64])
def test_ir_shift_all_ones_accepts_24_or_more(n):
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    c.ir_shift_all_ones(n)                                 # must not raise
    assert c.tap == coe.RUN_TEST_IDLE
    assert len(c.s.sent) == 3                              # toIR, the shift, exitIR

# ---------------------------------------------------------------- item 4: exact payload shape

def test_cmd_tms_requires_dev_zero():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    bad = struct.pack("<BBH", 1, 0, 1) + bytes([0, 0])
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bad)
    assert c.s.sent == []

def test_cmd_tms_requires_flags_zero():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    bad = struct.pack("<BBH", 0, 0x20, 4) + bytes([0x00, 0x03])
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bad)
    assert c.s.sent == []

def test_cmd_tms_refuses_trailing_bytes_beyond_count():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    bad = coe.tms_payload([0]) + bytes([0xFF, 0xFF] * 4)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bad)
    assert c.s.sent == []

def test_cmd_tms_zero_count_refuses_trailing_bytes():
    c = make_coe(tap=coe.SHIFT_IR)
    bad = struct.pack("<BBH", 0, 0, 0) + bytes([0xCB, 0, 0x02, 0, 0xCB, 0x80])
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bad)
    assert c.s.sent == []

def test_cmd_tdi_requires_flags_0x20():
    c = make_coe(tap=coe.SHIFT_DR)
    bad = coe.pair_payload([0] * 7, [1, 1, 1, 1, 0, 0, 0])   # pair-format body, flags=0
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TDI, bad)
    assert c.s.sent == []

def test_cmd_tdi_requires_exact_length():
    c = make_coe(tap=coe.SHIFT_DR)
    bad = struct.pack("<BBH", 0, 0x20, 64) + b"\0"           # 64 bits needs 8 bytes, not 1
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TDI, bad)
    assert c.s.sent == []

# ---------------------------------------------------------------- item 5: token bound to payload

def test_call_has_no_public_token_parameter():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(TypeError):
        c.call(coe.CMD_TMS, coe.ir_scan_payload([coe.IR_USER4, coe.IR_BYPASS]),
               _token=coe._IR_TOKEN)
    assert c.s.sent == []                                  # TypeError before anything is sent

def test_ir_token_refuses_a_jprogram_shaped_payload_sent_directly():
    """Holding coe._IR_TOKEN is not enough: the bits under it must decode to exactly
    an ir_scan_payload() for allowlisted ops."""
    c = make_coe(tap=coe.SHIFT_IR)
    op = int(DANGEROUS[0], 2)
    bits = [(op >> i) & 1 for i in range(12)] + [(coe.IR_USER4 >> i) & 1 for i in range(12)]
    bogus = coe.pair_payload(bits, [0] * 23 + [1])
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bogus, _token=coe._IR_TOKEN)
    assert c.s.sent == []

def test_ir_token_refuses_an_otherwise_valid_looking_payload_of_the_wrong_length():
    c = make_coe(tap=coe.SHIFT_IR)
    bogus = coe.pair_payload([1] * 30, [0] * 29 + [1])
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bogus, _token=coe._IR_TOKEN)
    assert c.s.sent == []

def test_all_ones_token_refuses_a_payload_that_is_not_all_ones():
    c = make_coe(tap=coe.SHIFT_IR)
    bits = [1] * 23 + [0]                                    # one zero bit among 24
    bogus = coe.pair_payload(bits, [0] * 23 + [1])
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bogus, _token=coe._ALL_ONES_TOKEN)
    assert c.s.sent == []

def test_all_ones_token_refuses_fewer_than_24_bits():
    c = make_coe(tap=coe.SHIFT_IR)
    bogus = coe.pair_payload([1] * 12, [0] * 11 + [1])
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, bogus, _token=coe._ALL_ONES_TOKEN)
    assert c.s.sent == []
