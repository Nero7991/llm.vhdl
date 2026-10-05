import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import coe

# Captured from the stock sqrl_bridge on 2026-10-05 (debugging doc S12).
CAPTURED = {"reset": "00000600001f", "toIR": "000004000003", "exitIR": "000002000001",
            "toDR": "000003000001", "exit": "000003000003"}

def test_tms_payloads_match_the_bridge_byte_for_byte():
    assert coe.tms_payload([1, 1, 1, 1, 1, 0]).hex() == CAPTURED["reset"]
    assert coe.tms_payload([1, 1, 0, 0]).hex() == CAPTURED["toIR"]
    assert coe.tms_payload([1, 0]).hex() == CAPTURED["exitIR"]
    assert coe.tms_payload([1, 0, 0]).hex() == CAPTURED["toDR"]
    assert coe.tms_payload([1, 1, 0]).hex() == CAPTURED["exit"]

# Every opcode in xcvu35p_fsvh2104.bsd that is not on the allowlist (copied from the BSDL).
DANGEROUS = ["001011001011", "010001010001", "110000100100", "110001100100", "110010100100",
             "110100100100", "110011100100", "011001100100", "100100110000", "100100110001",
             "100100110010", "100100110100"]

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
    c = coe.CoE.__new__(coe.CoE)
    c.txn = 0x7FFE
    class S:
        def sendall(self, b): self.b = b
    c.s = S()
    seen = [c.send(1) for _ in range(4)]
    assert seen == [0x7FFE, 0x7FFF, 1, 2]
