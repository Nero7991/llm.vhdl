import os, socket, struct, sys
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
    c.outstanding = []                  # Task 9 N1: unread CMD_TDI txns, in send order
    c.dead = None                       # Task 9: set once reply framing is lost
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
    # Task 9: an interrupted reply read now also poisons the connection (the reply may
    # be half-read, so the stream cannot be framed again), so the refusal is the
    # stricter ConnectionError rather than the UNKNOWN-state TapProtocolError.
    assert c.dead
    with pytest.raises(ConnectionError):
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

# ======================================================================
# Task 9 (Task 8 final review items N1-N3, 2026-10-05): the client tracks the CMD_TDI
# replies it has not read yet. A vetted TMS move or a handshake call() while any are
# unread would read a pipelined CMD_TDI reply as its own (and decide the TAP's state
# from it), so it is refused; drain() reads them all. Recovery after a pipelined
# failure is drain() then resync(). A zero-bit CMD_TDI is refused (N3).
# ======================================================================

def _tdi8(c, v=0):
    return c.send(coe.CMD_TDI, coe.dr_payload(8, bytes([v])))

def test_send_tracks_outstanding_and_reply_clears_it_in_order():
    c = make_coe(tap=coe.SHIFT_DR)
    ts = [_tdi8(c) for _ in range(3)]
    assert c.outstanding == ts
    c.reply(ts[0])
    assert c.outstanding == ts[1:]
    c.reply(ts[1]); c.reply(ts[2])
    assert c.outstanding == []

def _moves(c):
    return {"exit_dr_to_idle": lambda: c.exit_dr_to_idle(),
            "resync": lambda: c.resync(),
            "to_shift_dr": lambda: c.to_shift_dr(),
            "ir_scan": lambda: c.ir_scan([coe.IR_USER4, coe.IR_BYPASS]),
            "ir_shift_all_ones": lambda: c.ir_shift_all_ones(64),
            "call": lambda: c.call(coe.CMD_HELLO)}

@pytest.mark.parametrize("move", sorted(_moves(None)))
def test_tms_moves_and_call_are_refused_while_tdi_replies_are_unread(move):
    """N1: the refusal is the outstanding-reply guard itself (match="unread"), not the
    state guard that would also refuse some of these from Shift-DR, and nothing is sent."""
    c = make_coe(tap=coe.SHIFT_DR)
    _tdi8(c)
    n = len(c.s.sent)
    with pytest.raises(coe.TapProtocolError, match="unread"):
        _moves(c)[move]()
    assert len(c.s.sent) == n

def test_exit_dr_to_idle_is_allowed_once_every_reply_is_read():
    c = make_coe(tap=coe.SHIFT_DR)
    t = _tdi8(c)
    c.reply(t)
    c.exit_dr_to_idle()
    assert c.tap == coe.RUN_TEST_IDLE

def test_drain_reads_every_reply_and_keeps_shift_dr_when_all_are_good():
    c = make_coe(tap=coe.SHIFT_DR)
    ts = [_tdi8(c, k) for k in range(4)]
    good, bad = c.drain()
    assert [g[0] for g in good] == ts and bad == []
    assert c.outstanding == [] and c.tap == coe.SHIFT_DR and c.s._buf == b""
    c.exit_dr_to_idle()
    assert c.tap == coe.RUN_TEST_IDLE

def test_drain_forces_unknown_on_a_bad_reply_and_still_reads_the_rest():
    sock = FakeTransport(status={2: 0xDEAD0000})
    c = make_coe(sock, tap=coe.SHIFT_DR)
    ts = [_tdi8(c) for _ in range(4)]
    good, bad = c.drain()
    assert [g[0] for g in good] == [ts[0], ts[1], ts[3]]
    assert [b[0] for b in bad] == [ts[2]] and isinstance(bad[0][1], coe.CoEError)
    assert c.tap is coe.UNKNOWN and c.outstanding == [] and sock._buf == b""
    with pytest.raises(coe.TapProtocolError):
        c.exit_dr_to_idle()                       # UNKNOWN: only resync() may run

def test_drain_forces_unknown_on_a_txn_mismatch_too():
    sock = FakeTransport(reply_txn={1: 99})
    c = make_coe(sock, tap=coe.SHIFT_DR)
    ts = [_tdi8(c) for _ in range(3)]
    good, bad = c.drain()
    assert [b[0] for b in bad] == [ts[1]] and c.tap is coe.UNKNOWN and c.outstanding == []

def test_drain_with_nothing_outstanding_reads_nothing():
    c = make_coe(tap=coe.SHIFT_DR)
    assert c.drain() == ([], [])
    assert c.tap == coe.SHIFT_DR and c.s.sent == []

def test_reply_out_of_send_order_is_refused_without_consuming_anything():
    c = make_coe(tap=coe.SHIFT_DR)
    ts = [_tdi8(c) for _ in range(3)]
    with pytest.raises(coe.TapProtocolError):
        c.reply(ts[1])
    assert c.outstanding == ts and c.tap is coe.UNKNOWN
    good, bad = c.drain()
    assert [g[0] for g in good] == ts and bad == []

def test_pipelined_failure_recovery_is_drain_then_resync():
    """N2: four CMD_TDI shifts in flight, the second reply bad. reply() forces UNKNOWN;
    resync() is refused while two replies are still unread (it would read one of them
    as its own); drain() reads them; resync() then lands the shadow AND an independent
    model of the real TAP at Run-Test/Idle, and the normal sequence runs again."""
    class RealTap(FakeTransport):
        def __init__(self, state, **kw):
            FakeTransport.__init__(self, **kw)
            self.real = state
        def sendall(self, b):
            t, cmd = struct.unpack_from("<HI", b, 2)
            if cmd == coe.CMD_TMS:
                p = b[8:]
                n = struct.unpack_from("<H", p, 2)[0]
                for k in range(n):
                    self.real = coe.TAP_NEXT[self.real][(p[5 + 2 * (k // 8)] >> (k % 8)) & 1]
            FakeTransport.sendall(self, b)
    sock = RealTap(coe.SHIFT_DR, status={1: 0xDEAD0000})
    c = make_coe(sock, tap=coe.SHIFT_DR)
    ts = [_tdi8(c, k) for k in range(4)]
    c.reply(ts[0])
    with pytest.raises(coe.CoEError):
        c.reply(ts[1])
    assert c.tap is coe.UNKNOWN
    n = len(sock.sent)
    with pytest.raises(coe.TapProtocolError, match="unread"):
        c.resync()
    assert len(sock.sent) == n
    good, bad = c.drain()
    assert [g[0] for g in good] == ts[2:] and bad == []
    assert c.tap is coe.UNKNOWN                    # drain() never restores a known state
    c.resync()
    assert c.tap == coe.RUN_TEST_IDLE == sock.real
    c.ir_scan([coe.IR_USER4, coe.IR_BYPASS])
    c.to_shift_dr()
    t = _tdi8(c)
    c.reply(t)
    c.exit_dr_to_idle()
    assert c.tap == coe.RUN_TEST_IDLE == sock.real

def test_lost_reply_framing_poisons_the_connection():
    """A reply cut short (socket closed mid-header) leaves the byte stream unframed:
    no later reply can be trusted, so drain() and every move refuse with
    ConnectionError and nothing more is written. Recovery is a new connection."""
    class Cut(FakeTransport):
        def recv(self, n):
            return b""
    c = make_coe(Cut(), tap=coe.SHIFT_DR)
    ts = [_tdi8(c) for _ in range(2)]
    with pytest.raises(ConnectionError):
        c.reply(ts[0])
    assert c.tap is coe.UNKNOWN and c.dead
    n = len(c.s.sent)
    with pytest.raises(ConnectionError):
        c.drain()
    with pytest.raises(ConnectionError):
        c.resync()
    with pytest.raises(ConnectionError):
        c.call(coe.CMD_HELLO)
    assert len(c.s.sent) == n

def test_cmd_tdi_with_zero_bits_is_refused():
    """N3: nbits=0 is a shape this client never needs, and what the BMC does with it is
    not measured, so it is refused before anything is sent."""
    c = make_coe(tap=coe.SHIFT_DR)
    with pytest.raises(coe.TapProtocolError):
        c.send(coe.CMD_TDI, struct.pack("<BBH", 0, 0x20, 0))
    assert c.s.sent == [] and c.outstanding == []

def test_coe_takes_an_injected_socket_and_never_dials(monkeypatch):
    def refuse(*a, **k):
        raise AssertionError("a test tried to open a real socket")
    monkeypatch.setattr(coe.socket, "create_connection", refuse)
    sock = FakeTransport()
    c = coe.CoE(None, sock=sock)
    assert c.s is sock and c.tap is coe.UNKNOWN and c.outstanding == [] and not c.dead

class StaleSock(FakeTransport):
    """A real-socket-like fake: the BMC still holds a reply from a previous connection
    (MEASURED 2026-10-05 on silicon: the first load after a sqrl_bridge session got a
    reply carrying txn 0x0000 to its HELLO). recv() times out when nothing is queued."""
    def __init__(self, stale=b"", **k):
        FakeTransport.__init__(self, **k)
        self._buf = stale
        self._timeout = None
    def settimeout(self, t):
        self._timeout = t
    def gettimeout(self):
        return self._timeout
    def recv(self, n):
        if not self._buf:
            raise socket.timeout("timed out")
        return FakeTransport.recv(self, n)

def test_start_discards_a_stale_reply_left_by_a_previous_connection():
    stale = struct.pack("<HHI", 8, 0x0000, coe.STATUS_OK)
    sock = StaleSock(stale, cmd_data={coe.CMD_IDCODES: coe.VU35P_X2_IDCODES})
    c = make_coe(sock, tap=coe.UNKNOWN)
    assert c.start(hz=27_000_000) == coe.VU35P_X2_IDCODES
    assert c.flushed == len(stale)
    assert c.tap == coe.RUN_TEST_IDLE

def test_start_flush_restores_the_socket_timeout():
    sock = StaleSock(b"", cmd_data={coe.CMD_IDCODES: coe.VU35P_X2_IDCODES})
    sock.settimeout(10.0)
    c = make_coe(sock, tap=coe.UNKNOWN)
    c.start(hz=27_000_000)
    assert c.flushed == 0 and sock.gettimeout() == 10.0
