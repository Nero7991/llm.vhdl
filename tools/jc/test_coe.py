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

class FakeTransport:
    """Auto-acks every request with STATUS_OK and the right length of data for
    CMD_IDCODES/CMD_TDI (or a scripted reply, or a scripted bad status, by send index),
    and records every sendall(). Never opens a real socket; this is the only transport
    any test in this file uses."""
    def __init__(self, cmd_data=None, status=None, reply_txn=None):
        self.sent = []
        self._buf = b""
        self._cmd_data = dict(cmd_data or {})
        self._status = dict(status or {})          # {send_index: status}
        self._reply_txn = dict(reply_txn or {})     # {send_index: txn to reply with}

    def sendall(self, b):
        i = len(self.sent)
        self.sent.append(bytes(b))
        t, cmd = struct.unpack_from("<HI", b, 2)
        data = self._cmd_data.get(cmd, b"")
        if cmd == coe.CMD_TDI:
            n = struct.unpack_from("<H", b, 10)[0]
            data = bytes((n + 7) // 8)
        reply_t = self._reply_txn.get(i, t)
        st = self._status.get(i, coe.STATUS_OK)
        self._buf += struct.pack("<HHI", 8 + len(data), reply_t, st) + data

    def recv(self, n):
        c, self._buf = self._buf[:n], self._buf[n:]
        return c

    def setsockopt(self, *a):
        pass

def make_coe(sock=None, tap=coe.RUN_TEST_IDLE):
    c = coe.CoE.__new__(coe.CoE)
    c.s = sock if sock is not None else FakeTransport()
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

def test_ir_scan_payload_requires_exactly_the_chain_device_count():
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([coe.IR_USER4])                     # one op
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([])                                 # empty
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([coe.IR_USER4, coe.IR_BYPASS, coe.IR_IDCODE])  # three

def test_dr_payload_requires_matching_tdi_length():
    with pytest.raises(ValueError):
        coe.dr_payload(100, b"\0")                 # 100 bits needs 13 bytes, not 1

def test_pair_payload_requires_equal_length_and_binary_bits():
    with pytest.raises(ValueError):
        coe.pair_payload([0, 0], [0])               # unequal length
    with pytest.raises(ValueError):
        coe.pair_payload([2] + [0] * 7, [0] * 8)     # not a bit

def test_ir_scan_refuses_jprogram_before_sending_anything():
    c = make_coe(tap=coe.UNKNOWN)                   # state irrelevant: validated first
    with pytest.raises(coe.IRNotAllowed):
        c.ir_scan([coe.IR_USER4, int(DANGEROUS[0], 2)])
    assert c.s.sent == []

# ======================================================================
# Fix round 3 (re-review, 2026-10-05): C1, the public send()/reply() path validated
# a CMD_TMS against the shadow but never committed it (the commit lived only in
# _call_token), so send()+reply() used directly desynced the shadow from the real TAP,
# and a later call() validated against that stale shadow while the real TAP walked
# into Capture-IR/Update-IR. Ruling: there is no public path for CMD_TMS at all.
# ======================================================================

# ---------------------------------------------------------------- item A: send()/call() restricted

def test_send_refuses_cmd_tms_and_sends_nothing():
    """The exact hole the review found: send(CMD_TMS, ...) used to validate-then-defer
    the commit. It must now be refused outright, unconditionally."""
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TMS, coe.tms_payload([1, 0, 0]))
    assert c.s.sent == []

def test_send_refuses_handshake_and_unknown_commands():
    c = make_coe(tap=coe.SHIFT_DR)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_HELLO)
    with pytest.raises(coe.TapProtocolError):
        c.send(0x12345678)
    assert c.s.sent == []

def test_call_refuses_cmd_tms():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c.call(coe.CMD_TMS, coe.tms_payload([1, 1]))
    assert c.s.sent == []

def test_call_refuses_cmd_tdi():
    c = make_coe(tap=coe.SHIFT_DR)
    with pytest.raises(coe.TapProtocolError):
        c.call(coe.CMD_TDI, coe.dr_payload(8, bytes(1)))
    assert c.s.sent == []

def test_send_cmd_tdi_requires_shift_dr():
    c = make_coe(tap=coe.SHIFT_IR)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TDI, coe.dr_payload(8, bytes(1)))
    assert c.s.sent == []

def test_send_cmd_tdi_from_shift_dr_never_moves_the_shadow():
    c = make_coe(tap=coe.SHIFT_DR)
    t = c.send(coe.CMD_TDI, coe.dr_payload(8, bytes(1)))
    st, data = c.reply(t)
    assert st == coe.STATUS_OK and c.tap == coe.SHIFT_DR     # flags=0x20 cannot move it

# ---------------------------------------------------------------- item D: token/state binding

def test_ir_scan_requires_run_test_idle():
    c = make_coe(tap=coe.SHIFT_IR)
    with pytest.raises(coe.TapProtocolError):
        c.ir_scan([coe.IR_USER4, coe.IR_BYPASS])
    assert c.s.sent == []

def test_ir_shift_all_ones_requires_run_test_idle():
    c = make_coe(tap=coe.SHIFT_DR)
    with pytest.raises(coe.TapProtocolError):
        c.ir_shift_all_ones(64)
    assert c.s.sent == []

def test_to_shift_dr_requires_run_test_idle():
    c = make_coe(tap=coe.SHIFT_IR)
    with pytest.raises(coe.TapProtocolError):
        c.to_shift_dr()
    assert c.s.sent == []

def test_exit_dr_to_idle_requires_shift_dr():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c.exit_dr_to_idle()
    assert c.s.sent == []

def test_to_shift_dr_and_exit_dr_to_idle_round_trip():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    c.to_shift_dr()
    assert c.tap == coe.SHIFT_DR
    c.exit_dr_to_idle()
    assert c.tap == coe.RUN_TEST_IDLE

def test_call_token_rejects_an_unrecognized_token():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c._call_token(coe.CMD_TMS, coe._TO_IR, object())
    assert c.s.sent == []

def test_call_token_rejects_a_step_from_the_wrong_state():
    """The same payload (_TO_IR) is only valid from Run-Test/Idle; having already used
    it once (landing in Shift-IR) must not let it be sent again."""
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    c._call_token(coe.CMD_TMS, coe._TO_IR, coe._IR_TOKEN)
    assert c.tap == coe.SHIFT_IR
    with pytest.raises(coe.TapProtocolError):
        c._call_token(coe.CMD_TMS, coe._TO_IR, coe._IR_TOKEN)
    assert c.tap == coe.SHIFT_IR                      # refused: shadow did not move

def test_call_token_refuses_jprogram_shaped_payload_under_ir_token():
    c = make_coe(tap=coe.SHIFT_IR)
    op = int(DANGEROUS[0], 2)
    bits = [(op >> i) & 1 for i in range(12)] + [(coe.IR_USER4 >> i) & 1 for i in range(12)]
    bogus = coe.pair_payload(bits, [0] * 23 + [1])
    with pytest.raises(coe.TapProtocolError):
        c._call_token(coe.CMD_TMS, bogus, coe._IR_TOKEN)
    assert c.s.sent == []

def test_call_token_refuses_a_non_all_ones_payload_under_all_ones_token():
    c = make_coe(tap=coe.SHIFT_IR)
    bits = [1] * 23 + [0]
    bogus = coe.pair_payload(bits, [0] * 23 + [1])
    with pytest.raises(coe.TapProtocolError):
        c._call_token(coe.CMD_TMS, bogus, coe._ALL_ONES_TOKEN)
    assert c.s.sent == []

def test_call_token_refuses_the_resync_payload_under_the_wrong_token():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c._call_token(coe.CMD_TMS, coe._RESYNC_PAYLOAD, coe._IR_TOKEN)
    assert c.s.sent == []

# ---------------------------------------------------------------- item C: reply()

def test_reply_rejects_a_header_shorter_than_eight_bytes():
    class S:
        def __init__(s2, d): s2.d = d
        def recv(s2, n): r = s2.d[:n]; s2.d = s2.d[n:]; return r
    c = make_coe(S(struct.pack("<HHI", 4, 5, coe.STATUS_OK) + b"XXXX"))
    with pytest.raises(coe.CoEError):
        c.reply(5)

def test_reply_requires_the_expected_txn():
    sock = FakeTransport(reply_txn={0: 99})
    c = make_coe(sock, tap=coe.SHIFT_DR)
    t = c.send(coe.CMD_TDI, coe.dr_payload(8, bytes(1)))
    with pytest.raises(coe.CoEError):
        c.reply(t)

def test_reply_requires_ok_status():
    sock = FakeTransport(status={0: 0xDEAD0000})
    c = make_coe(sock, tap=coe.SHIFT_DR)
    t = c.send(coe.CMD_TDI, coe.dr_payload(8, bytes(1)))
    with pytest.raises(coe.CoEError):
        c.reply(t)

# ---------------------------------------------------------------- item B/E: UNKNOWN discipline

def test_unknown_is_a_dedicated_sentinel_not_minus_one():
    assert coe.UNKNOWN != -1
    assert coe.UNKNOWN is coe.UNKNOWN            # stable identity, compared with `is`

def test_new_coe_starts_unknown(monkeypatch):
    sock = FakeTransport()
    monkeypatch.setattr(coe.socket, "create_connection", lambda *a, **k: sock)
    c = coe.CoE("192.0.2.1")                     # TEST-NET-1, never dialled
    assert c.tap is coe.UNKNOWN

def test_unknown_shadow_refuses_every_vetted_method_except_resync():
    for method, args in [("ir_scan", ([coe.IR_USER4, coe.IR_BYPASS],)),
                          ("ir_shift_all_ones", (64,)),
                          ("to_shift_dr", ()),
                          ("exit_dr_to_idle", ())]:
        c = make_coe(tap=coe.UNKNOWN)
        with pytest.raises(coe.TapProtocolError):
            getattr(c, method)(*args)
        assert c.s.sent == []
    c = make_coe(tap=coe.UNKNOWN)
    c.resync()
    assert c.tap == coe.RUN_TEST_IDLE

def test_handshake_call_forces_unknown_even_on_success():
    c = make_coe(tap=coe.SHIFT_DR)
    c.call(coe.CMD_HELLO)
    assert c.tap is coe.UNKNOWN

def test_handshake_call_forces_unknown_on_failure_too():
    sock = FakeTransport(status={0: 0xDEAD0000})
    c = make_coe(sock, tap=coe.SHIFT_DR)
    with pytest.raises(coe.CoEError):
        c.call(coe.CMD_HELLO)
    assert c.tap is coe.UNKNOWN

def test_start_ends_at_run_test_idle_via_resync():
    sock = FakeTransport(cmd_data={coe.CMD_IDCODES: coe.VU35P_X2_IDCODES})
    c = make_coe(sock, tap=coe.UNKNOWN)
    ids = c.start(hz=27_000_000)
    assert ids == coe.VU35P_X2_IDCODES
    cmds = [struct.unpack_from("<I", b, 4)[0] for b in sock.sent]
    assert cmds == [coe.CMD_HELLO, coe.CMD_SPEED, coe.CMD_MODE, coe.CMD_IDCODES,
                     coe.CMD_IRLEN, coe.CMD_MODE, coe.CMD_TMS]
    assert sock.sent[6][8:] == coe._RESYNC_PAYLOAD
    assert c.tap == coe.RUN_TEST_IDLE

def test_vetted_method_leaves_unknown_on_bad_status():
    sock = FakeTransport(status={0: 0xDEAD0000})
    c = make_coe(sock, tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.CoEError):
        c.ir_scan([coe.IR_BYPASS] * 2)
    assert c.tap is coe.UNKNOWN

def test_vetted_method_leaves_unknown_on_txn_mismatch():
    sock = FakeTransport(reply_txn={0: 99})
    c = make_coe(sock, tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.CoEError):
        c.ir_scan([coe.IR_BYPASS] * 2)
    assert c.tap is coe.UNKNOWN

def test_ctrl_c_mid_ir_scan_leaves_unknown_and_blocks_the_next_move():
    class KI(FakeTransport):
        def recv(self, n):
            raise KeyboardInterrupt
    c = make_coe(KI(), tap=coe.RUN_TEST_IDLE)
    with pytest.raises(KeyboardInterrupt):
        c.ir_scan([coe.IR_BYPASS] * 2)
    assert c.tap is coe.UNKNOWN
    with pytest.raises(coe.TapProtocolError):
        c.to_shift_dr()
    assert len(c.s.sent) == 1                             # the refused move sent nothing new

def test_pipelined_cmd_tdi_with_two_of_four_replies_failing_leaves_unknown():
    sock = FakeTransport(status={1: 0xDEAD0000, 2: 0xDEAD0000})
    c = make_coe(sock, tap=coe.SHIFT_DR)
    txns = [c.send(coe.CMD_TDI, coe.dr_payload(8, bytes(1))) for _ in range(4)]
    failures = 0
    for t in txns:
        try:
            c.reply(t)
        except coe.CoEError:
            failures += 1
    assert failures == 2
    assert c.tap is coe.UNKNOWN

# ---------------------------------------------------------------- item F: minors

def test_cmd_tms_padding_bits_must_be_zero():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    bad = struct.pack("<BBH", 0, 0, 1) + bytes([0x00, 0xFE])   # count=1, TMS byte padded 0xFE
    with pytest.raises(coe.TapProtocolError):
        c._call_token(coe.CMD_TMS, bad, coe._IR_TOKEN)
    assert c.s.sent == []

def test_cmd_tdi_padding_bits_must_be_zero():
    c = make_coe(tap=coe.SHIFT_DR)
    bad = struct.pack("<BBH", 0, 0x20, 1) + bytes([0xFE])      # nbits=1, byte padded 0xFE
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TDI, bad)
    assert c.s.sent == []

def test_cmd_tms_trailing_bytes_beyond_count_refused():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    bad = coe.tms_payload([0]) + bytes([0xFF, 0xFF] * 4)
    with pytest.raises(coe.TapProtocolError):
        c._call_token(coe.CMD_TMS, bad, coe._IR_TOKEN)
    assert c.s.sent == []

def test_cmd_tdi_requires_exact_length():
    c = make_coe(tap=coe.SHIFT_DR)
    bad = struct.pack("<BBH", 0, 0x20, 64) + b"\0"             # 64 bits needs 8 bytes
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TDI, bad)
    assert c.s.sent == []

# ---------------------------------------------------------------- resync derivation

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
    assert len(c.s.sent) == 1

def test_resync_works_from_an_unrecognized_real_state_too():
    """resync's own step tolerates ANY starting shadow, UNKNOWN included -- its start
    requirement is None in _TOKEN_STEPS."""
    c = make_coe(tap=coe.UNKNOWN)
    c.resync()
    assert c.tap == coe.RUN_TEST_IDLE

# ---------------------------------------------------------------- full legal sequence

def test_full_legal_load_sequence_passes():
    """start, ir_scan(USER4, BYPASS), to_shift_dr, N pipelined CMD_TDI sends (with
    replies), exit -- driven against an independent TAP model of the real chain, not
    just the shadow -- must complete with the shadow and the modelled real TAP in
    agreement at every step, and no unsafe Update-IR transition ever observed."""
    class RealTap(FakeTransport):
        def __init__(self, state):
            FakeTransport.__init__(self)
            self.real = state
            self.unsafe_events = []
        def sendall(self, b):
            t, cmd = struct.unpack_from("<HI", b, 2)
            if cmd == coe.CMD_TMS:
                p = b[8:]
                n = struct.unpack_from("<H", p, 2)[0]
                for k in range(n):
                    tms = (p[5 + 2 * (k // 8)] >> (k % 8)) & 1
                    ns = coe.TAP_NEXT[self.real][tms]
                    if ns == coe.UPDATE_IR and self.real not in (coe.EXIT1_IR, coe.EXIT2_IR):
                        self.unsafe_events.append("impossible edge")   # cannot happen
                    self.real = ns
            FakeTransport.sendall(self, b)

    sock = RealTap(coe.SHIFT_IR)      # an arbitrary, unfavourable real starting state
    c = make_coe(sock, tap=coe.UNKNOWN)
    sock._cmd_data[coe.CMD_IDCODES] = coe.VU35P_X2_IDCODES
    c.start()
    assert c.tap == coe.RUN_TEST_IDLE == sock.real
    c.ir_scan([coe.IR_USER4, coe.IR_BYPASS])
    assert c.tap == coe.RUN_TEST_IDLE == sock.real
    c.to_shift_dr()
    assert c.tap == coe.SHIFT_DR == sock.real
    for i in range(5):
        t = c.send(coe.CMD_TDI, coe.dr_payload(8, bytes([i])))
        st, data = c.reply(t)
        assert st == coe.STATUS_OK and len(data) == 1
        assert c.tap == coe.SHIFT_DR == sock.real       # never moves during the run
    c.exit_dr_to_idle()
    assert c.tap == coe.RUN_TEST_IDLE == sock.real
    assert sock.unsafe_events == []

@pytest.mark.parametrize("real_start", list(range(16)))
def test_start_is_safe_from_every_real_tap_starting_state(real_start):
    """The same full sequence, started with the modelled REAL chain in each of its 16
    possible positions (not just the shadow) -- start()'s resync() must always recover
    a known, safe state."""
    class RealTap(FakeTransport):
        def __init__(self, state):
            FakeTransport.__init__(self)
            self.real = state
        def sendall(self, b):
            t, cmd = struct.unpack_from("<HI", b, 2)
            if cmd == coe.CMD_TMS:
                p = b[8:]
                n = struct.unpack_from("<H", p, 2)[0]
                for k in range(n):
                    tms = (p[5 + 2 * (k // 8)] >> (k % 8)) & 1
                    self.real = coe.TAP_NEXT[self.real][tms]
            FakeTransport.sendall(self, b)
    sock = RealTap(real_start)
    sock._cmd_data[coe.CMD_IDCODES] = coe.VU35P_X2_IDCODES
    c = make_coe(sock, tap=coe.UNKNOWN)
    c.start()
    assert c.tap == coe.RUN_TEST_IDLE == sock.real
