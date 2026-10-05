import os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import coe

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

def make_coe(sock=None, tap=coe.TEST_LOGIC_RESET):
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
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    c.txn = 0x7FFE
    seen = [c.send(coe.CMD_HELLO) for _ in range(4)]
    assert seen == [0x7FFE, 0x7FFF, 1, 2]

# ---------------------------------------------------------------- fix round 1: (a)/(b)

def test_ir_scan_payload_requires_exactly_the_chain_device_count():
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([coe.IR_USER4])                     # one op
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([])                                 # empty
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([coe.IR_USER4, coe.IR_BYPASS, coe.IR_IDCODE])  # three

def test_ir_scan_refuses_jprogram_before_sending_anything():
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.IRNotAllowed):
        c.ir_scan([coe.IR_USER4, int(DANGEROUS[0], 2)])
    assert c.s.sent == []

def test_raw_tms_send_refuses_a_hand_built_ir_payload_and_sends_nothing():
    """The hole the review found: pair_payload builds JPROGRAM unchecked, and nothing
    tracked TAP state, so a raw send() could shift it straight through once the chain
    happened to be in Shift-IR (e.g. left there by a previous legitimate toIR call)."""
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
    c = make_coe(tap=coe.RUN_TEST_IDLE)
    with pytest.raises(coe.TapProtocolError):
        c.send(0x12345678)
    assert c.s.sent == []

def test_full_legal_sequence_matches_the_old_hand_rolled_path():
    """reset, ir_scan([USER4, BYPASS]), toDR, a DR shift, exit -- driven through the
    shadow TAP machine -- must produce byte-identical traffic to the pre-guard sequence
    (toIR / ir_scan_payload under the internal token / exitIR, issued by hand)."""
    new_sock = FakeSocket()
    c = make_coe(new_sock, tap=coe.TEST_LOGIC_RESET)
    c.call(coe.CMD_TMS, coe.tms_payload([1, 1, 1, 1, 1, 0]))
    c.ir_scan([coe.IR_USER4, coe.IR_BYPASS])
    c.call(coe.CMD_TMS, coe.tms_payload([1, 0, 0]))
    c.call(coe.CMD_TDI, coe.dr_payload(8, bytes([0x5A])))
    c.call(coe.CMD_TMS, coe.tms_payload([1, 1, 0]))

    old_sock = FakeSocket()
    o = make_coe(old_sock, tap=coe.TEST_LOGIC_RESET)
    o.call(coe.CMD_TMS, coe.tms_payload([1, 1, 1, 1, 1, 0]))
    o.call(coe.CMD_TMS, coe.tms_payload([1, 1, 0, 0]))                                  # toIR
    o.call(coe.CMD_TMS, coe.ir_scan_payload([coe.IR_USER4, coe.IR_BYPASS]),
           _token=coe._IR_TOKEN)
    o.call(coe.CMD_TMS, coe.tms_payload([1, 0]))                                        # exitIR
    o.call(coe.CMD_TMS, coe.tms_payload([1, 0, 0]))
    o.call(coe.CMD_TDI, coe.dr_payload(8, bytes([0x5A])))
    o.call(coe.CMD_TMS, coe.tms_payload([1, 1, 0]))

    assert new_sock.sent == old_sock.sent
    assert c.tap == coe.RUN_TEST_IDLE == o.tap

def test_start_sends_the_documented_handshake_sequence():
    sock = FakeSocket(cmd_data={coe.CMD_IDCODES: coe.VU35P_X2_IDCODES})
    c = make_coe(sock, tap=coe.TEST_LOGIC_RESET)
    ids = c.start(hz=27_000_000)
    assert ids == coe.VU35P_X2_IDCODES
    cmds = [struct.unpack_from("<I", b, 4)[0] for b in sock.sent]
    assert cmds == [coe.CMD_HELLO, coe.CMD_SPEED, coe.CMD_MODE, coe.CMD_IDCODES,
                     coe.CMD_IRLEN, coe.CMD_MODE]
    assert sock.sent[1][8:] == struct.pack("<II", 0, 27_000_000)
    assert sock.sent[2][8:] == bytes.fromhex("0002")
    assert sock.sent[3][8:] == bytes.fromhex("0000")
    assert sock.sent[4][8:] == bytes.fromhex("000c0c")
    assert sock.sent[5][8:] == bytes.fromhex("0001")
    assert c.tap == coe.TEST_LOGIC_RESET          # start() never touches TMS/TDI

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
    c = make_coe(sock, tap=coe.RUN_TEST_IDLE)
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
    c = make_coe(S(), tap=coe.RUN_TEST_IDLE)
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
