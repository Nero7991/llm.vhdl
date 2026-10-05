"""Direct SQRL CoE client for the Jungle Cat BMC (no sqrl_bridge).

Protocol: docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md S12.
Only commands observed from the stock bridge are sent. The IR allowlist is the one
guard against shifting JPROGRAM or an eFUSE opcode (xcvu35p_fsvh2104.bsd); keep it.

Fix round 1 (review: opus, 2026-10-05): the allowlist alone was not a safety boundary,
because `pair_payload`/`send` would happily transmit ANY bits, allowlisted or not, and
nothing tracked which IEEE 1149.1 TAP state those bits would land in. A hand-built
payload sent while the chain was already in Shift-IR could shift JPROGRAM straight
through, allowlist or no allowlist. The fix moves the guard down to `send()`: CoE now
keeps a shadow 16-state TAP machine, advanced by every TMS bit it transmits, and
`send()` refuses (before anything reaches the socket) any CMD_TDI issued outside
Shift-DR and any CMD_TMS payload that would clock a bit while the shadow TAP is
already in Shift-IR, unless the call carries the private `_IR_TOKEN` that only
`CoE.ir_scan` and `CoE.ir_shift_all_ones` hand out. The allowlist itself still lives in
`ir_scan_payload` (now also pinned to the chain's exact device count), but it is no
longer the only thing standing between a caller and JPROGRAM.
"""
import socket, struct

IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4 = 0xFFF, 0x249, 0x8A4, 0x8E4
IR_ALLOW = {IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4}
IR_LEN = 12
CHAIN_DEVICES = 2                        # IR lengths 0x0c 0x0c read by start(): 2 devices
CMD_HELLO, CMD_SPEED, CMD_MODE = 0x80001000, 0x8000100C, 0x80001001
CMD_IDCODES, CMD_IRLEN = 0x80001010, 0x80001011
CMD_TMS, CMD_TDI = 0x8000100E, 0x8000100F
STATUS_OK = 0x8000000A
VU35P_X2_IDCODES = bytes.fromhex("9310b7149310b714")

# The commands start() issues that carry no TMS/TDI bits and so never touch the shadow
# TAP state. Anything else reaching send() that is not CMD_TMS or CMD_TDI is refused.
_HANDSHAKE_CMDS = {CMD_HELLO, CMD_SPEED, CMD_MODE, CMD_IDCODES, CMD_IRLEN}

# IEEE 1149.1 TAP controller states (Fig. 6-3). TAP_NEXT[state] = (next_on_tms0, next_on_tms1).
(TEST_LOGIC_RESET, RUN_TEST_IDLE, SELECT_DR, CAPTURE_DR, SHIFT_DR, EXIT1_DR, PAUSE_DR,
 EXIT2_DR, UPDATE_DR, SELECT_IR, CAPTURE_IR, SHIFT_IR, EXIT1_IR, PAUSE_IR, EXIT2_IR,
 UPDATE_IR) = range(16)

TAP_NEXT = {
    TEST_LOGIC_RESET: (RUN_TEST_IDLE, TEST_LOGIC_RESET),
    RUN_TEST_IDLE:    (RUN_TEST_IDLE, SELECT_DR),
    SELECT_DR:        (CAPTURE_DR, SELECT_IR),
    CAPTURE_DR:       (SHIFT_DR, EXIT1_DR),
    SHIFT_DR:         (SHIFT_DR, EXIT1_DR),
    EXIT1_DR:         (PAUSE_DR, UPDATE_DR),
    PAUSE_DR:         (PAUSE_DR, EXIT2_DR),
    EXIT2_DR:         (SHIFT_DR, UPDATE_DR),
    UPDATE_DR:        (RUN_TEST_IDLE, SELECT_DR),
    SELECT_IR:        (CAPTURE_IR, TEST_LOGIC_RESET),
    CAPTURE_IR:       (SHIFT_IR, EXIT1_IR),
    SHIFT_IR:         (SHIFT_IR, EXIT1_IR),
    EXIT1_IR:         (PAUSE_IR, UPDATE_IR),
    PAUSE_IR:         (PAUSE_IR, EXIT2_IR),
    EXIT2_IR:         (SHIFT_IR, UPDATE_IR),
    UPDATE_IR:        (RUN_TEST_IDLE, SELECT_DR),
}

# A private token. Not a public parameter: nothing outside this module can name it
# without reaching into coe._IR_TOKEN, which is not something a caller does casually.
_IR_TOKEN = object()

class IRNotAllowed(Exception):
    pass

class TapProtocolError(Exception):
    """A send/call would violate the shadow TAP state machine or the CoE reply
    contract. Raised before anything is written to the socket."""
    pass

class CoEError(Exception):
    """A reply failed the protocol's own contract (short header, txn mismatch, a
    status other than STATUS_OK)."""
    pass

def _decode_pair_payload(payload):
    """Reverse of pair_payload: -> (count, tdi_bits, tms_bits)."""
    dev, flags, n = struct.unpack_from("<BBH", payload, 0)
    tdi_bits, tms_bits = [], []
    off = 4
    for k in range(0, n, 8):
        m = min(8, n - k)
        tb, mb = payload[off], payload[off + 1]
        off += 2
        for j in range(m):
            tdi_bits.append((tb >> j) & 1)
            tms_bits.append((mb >> j) & 1)
    return n, tdi_bits, tms_bits

def pair_payload(tdi_bits, tms_bits):
    """0x8000100e body: dev 0, flags 0, count, then (TDI byte, TMS byte) pairs."""
    if len(tdi_bits) != len(tms_bits):
        raise ValueError("tdi_bits and tms_bits must be the same length: %d != %d"
                          % (len(tdi_bits), len(tms_bits)))
    for b in tdi_bits:
        if b not in (0, 1):
            raise ValueError("tdi bit must be 0 or 1, got %r" % (b,))
    for b in tms_bits:
        if b not in (0, 1):
            raise ValueError("tms bit must be 0 or 1, got %r" % (b,))
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
    first. TMS rises on the last bit (Shift-IR -> Exit1-IR).

    This is a pure builder: it validates the opcodes and the chain length, and raises
    IRNotAllowed before building anything, but building a valid payload here is NOT
    sufficient to send it -- CoE.send refuses to clock these bits unless the call
    carries the internal token that only CoE.ir_scan hands out."""
    if len(ops_tdi_to_tdo) != CHAIN_DEVICES:
        raise IRNotAllowed("ir_scan needs exactly %d ops (one per chain device), got %d"
                            % (CHAIN_DEVICES, len(ops_tdi_to_tdo)))
    for op in ops_tdi_to_tdo:
        if op not in IR_ALLOW:
            raise IRNotAllowed("IR value %#05x is not BYPASS/IDCODE/USER3/USER4" % op)
    bits = []
    for op in reversed(ops_tdi_to_tdo):
        bits += [(op >> i) & 1 for i in range(IR_LEN)]
    tms = [0] * (len(bits) - 1) + [1]
    return pair_payload(bits, tms)

def dr_payload(nbits, tdi):
    need = (nbits + 7) // 8
    if len(tdi) != need:
        raise ValueError("dr_payload(%d, ...) needs %d bytes of tdi, got %d"
                          % (nbits, need, len(tdi)))
    return struct.pack("<BBH", 0, 0x20, nbits) + tdi

# Precomputed, byte-identical to what the manual TMS dance in coe_stream.py used to
# send by hand: RTI -> Shift-IR, and Exit1-IR -> RTI.
_TO_IR = tms_payload([1, 1, 0, 0])
_EXIT_IR = tms_payload([1, 0])

class CoE:
    def __init__(s, ip, port=21363, timeout=10.0):
        s.s = socket.create_connection((ip, port), timeout=timeout)
        s.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.txn = 1
        s.tap = TEST_LOGIC_RESET

    def send(s, cmd, payload=b"", _token=None):
        if cmd == CMD_TMS:
            count, tdi_bits, tms_bits = _decode_pair_payload(payload)
            state = s.tap
            for i in range(count):
                if state == SHIFT_IR and _token is not _IR_TOKEN:
                    raise TapProtocolError(
                        "CMD_TMS would clock a bit while the shadow TAP is in Shift-IR; "
                        "route IR shifts through CoE.ir_scan or CoE.ir_shift_all_ones")
                state = TAP_NEXT[state][tms_bits[i]]
            next_tap = state
        elif cmd == CMD_TDI:
            if s.tap != SHIFT_DR:
                raise TapProtocolError(
                    "CMD_TDI sent while the shadow TAP is in state %d, not Shift-DR (%d)"
                    % (s.tap, SHIFT_DR))
            next_tap = s.tap                 # flags=0x20 holds TMS at 0 for the whole shift
        elif cmd in _HANDSHAKE_CMDS:
            next_tap = s.tap                 # BMC-level commands; no TAP effect
        else:
            raise TapProtocolError("unknown CoE command %#x" % cmd)
        # txn bit 15 is not a counter bit: txn 0x8000 drew a 4-byte error reply (MEASURED)
        t = s.txn
        s.txn = s.txn + 1 if s.txn < 0x7FFF else 1
        s.s.sendall(struct.pack("<HHI", 8 + len(payload), t, cmd) + payload)
        s.tap = next_tap
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
        hdr = s._recv(8)
        L, t, st = struct.unpack("<HHI", hdr)
        if L < 8:
            raise CoEError("reply length %d is less than the 8-byte header" % L)
        return t, st, s._recv(L - 8)

    def call(s, cmd, payload=b"", _token=None):
        t = s.send(cmd, payload, _token=_token)
        rt, st, d = s.reply()
        if rt != t:
            raise CoEError("txn mismatch: sent %#06x, reply carried %#06x" % (t, rt))
        if st != STATUS_OK:
            raise CoEError("status %#010x, expected STATUS_OK %#010x" % (st, STATUS_OK))
        return st, d

    def ir_scan(s, ops):
        """The one vetted way to shift an IR opcode into every device on the chain:
        validates against the allowlist and the chain's device count FIRST (raises
        IRNotAllowed, nothing sent), then drives RTI -> Shift-IR -> (ops) -> RTI with
        the internal token, byte-identical to the old hand-rolled toIR/shift/exitIR
        sequence."""
        payload = ir_scan_payload(ops)
        if s.tap != RUN_TEST_IDLE:
            raise TapProtocolError(
                "ir_scan must start from Run-Test/Idle, shadow TAP is in state %d" % s.tap)
        s.call(CMD_TMS, _TO_IR)
        s.call(CMD_TMS, payload, _token=_IR_TOKEN)
        s.call(CMD_TMS, _EXIT_IR)

    def ir_shift_all_ones(s, n):
        """The raw-throughput measurement tool's own pattern (coe_stream.py): shifting
        n >= chain IR bits of all-ones loads BYPASS into every device regardless of IR
        length, independent of the allowlist (there is no opcode to check -- the bit
        pattern is fixed and always safe). Kept here, not in coe_stream.py, so it goes
        through the same TAP guard as ir_scan rather than hand-building IR payloads."""
        if n < 1:
            raise ValueError("ir_shift_all_ones needs at least 1 bit")
        if s.tap != RUN_TEST_IDLE:
            raise TapProtocolError(
                "ir_shift_all_ones must start from Run-Test/Idle, shadow TAP is in "
                "state %d" % s.tap)
        s.call(CMD_TMS, _TO_IR)
        s.call(CMD_TMS, pair_payload([1] * n, [0] * (n - 1) + [1]), _token=_IR_TOKEN)
        s.call(CMD_TMS, _EXIT_IR)

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

# Backward-compatible aliases: short names used by the TAP checks above, kept at module
# scope under both spellings so a test can refer to either coe.SHIFT_IR or the full name.
TLR, RTI = TEST_LOGIC_RESET, RUN_TEST_IDLE
