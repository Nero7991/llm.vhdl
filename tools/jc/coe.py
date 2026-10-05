"""Direct SQRL CoE client for the Jungle Cat BMC (no sqrl_bridge).

Protocol: docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md S12.
Only commands observed from the stock bridge are sent. The IR allowlist is the one
guard against shifting JPROGRAM or an eFUSE opcode (xcvu35p_fsvh2104.bsd); keep it.
"""
import socket, struct

IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4 = 0xFFF, 0x249, 0x8A4, 0x8E4
IR_ALLOW = {IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4}
IR_LEN = 12
CMD_HELLO, CMD_SPEED, CMD_MODE = 0x80001000, 0x8000100C, 0x80001001
CMD_IDCODES, CMD_IRLEN = 0x80001010, 0x80001011
CMD_TMS, CMD_TDI = 0x8000100E, 0x8000100F
STATUS_OK = 0x8000000A
VU35P_X2_IDCODES = bytes.fromhex("9310b7149310b714")

class IRNotAllowed(Exception):
    pass

class CoE:
    def __init__(s, ip, port=21363, timeout=10.0):
        s.s = socket.create_connection((ip, port), timeout=timeout)
        s.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.txn = 1

    def send(s, cmd, payload=b""):
        # txn bit 15 is not a counter bit: txn 0x8000 drew a 4-byte error reply (MEASURED)
        t = s.txn
        s.txn = s.txn + 1 if s.txn < 0x7FFF else 1
        s.s.sendall(struct.pack("<HHI", 8 + len(payload), t, cmd) + payload)
        return t

    def _recv(s, n):
        b = bytearray()
        while len(b) < n:
            c = s.s.recv(n - len(b))
            if not c:
                raise ConnectionError("CoE closed")
            b += c
        return bytes(b)

    def reply(s):
        L, t, st = struct.unpack("<HHI", s._recv(8))
        return t, st, s._recv(L - 8)

    def call(s, cmd, payload=b""):
        t = s.send(cmd, payload)
        while True:
            rt, st, d = s.reply()
            if rt == t:
                return st, d

    def start(s, hz=27_000_000):
        s.call(CMD_HELLO)
        s.call(CMD_SPEED, struct.pack("<II", 0, hz))
        s.call(CMD_MODE, bytes.fromhex("0002"))
        _, ids = s.call(CMD_IDCODES, bytes.fromhex("0000"))
        if ids != VU35P_X2_IDCODES:
            raise RuntimeError("unexpected IDCODEs %s" % ids.hex())
        s.call(CMD_IRLEN, bytes.fromhex("000c0c"))
        s.call(CMD_MODE, bytes.fromhex("0001"))
        return ids

def pair_payload(tdi_bits, tms_bits):
    """0x8000100e body: dev 0, flags 0, count, then (TDI byte, TMS byte) pairs."""
    n = len(tdi_bits)
    out = bytearray(struct.pack("<BBH", 0, 0, n))
    for k in range(0, n, 8):
        m = min(8, n - k)
        out += bytes([sum(tdi_bits[k + j] << j for j in range(m)),
                      sum(tms_bits[k + j] << j for j in range(m))])
    return bytes(out)

def tms_payload(tms_bits):
    return pair_payload([0] * len(tms_bits), tms_bits)

def ir_scan_payload(ops_tdi_to_tdo):
    """IR bits for a chain listed from TDI to TDO. The TDO-side device's opcode is shifted
    first. TMS rises on the last bit (Shift-IR -> Exit1-IR)."""
    for op in ops_tdi_to_tdo:
        if op not in IR_ALLOW:
            raise IRNotAllowed("IR value %#05x is not BYPASS/IDCODE/USER3/USER4" % op)
    bits = []
    for op in reversed(ops_tdi_to_tdo):
        bits += [(op >> i) & 1 for i in range(IR_LEN)]
    tms = [0] * (len(bits) - 1) + [1]
    return pair_payload(bits, tms)

def dr_payload(nbits, tdi):
    return struct.pack("<BBH", 0, 0x20, nbits) + tdi
