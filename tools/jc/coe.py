"""Direct SQRL CoE client for the Jungle Cat BMC (no sqrl_bridge).

Protocol: docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md S12.
Only commands observed from the stock bridge are sent. The IR allowlist is the one
guard against shifting JPROGRAM or an eFUSE opcode (xcvu35p_fsvh2104.bsd); keep it.

Fix round 1 (review: opus, 2026-10-05): the allowlist alone was not a safety boundary,
because `pair_payload`/`send` would happily transmit ANY bits, allowlisted or not, and
nothing tracked which IEEE 1149.1 TAP state those bits would land in. The fix moved the
guard down to `send()`: CoE keeps a shadow 16-state TAP machine, advanced by every TMS
bit it transmits.

Fix round 2 (re-review, 2026-10-05) found round 1's guard still had three gaps:

  1. An UNTOKENED CMD_TMS could walk Capture-IR -> Exit1-IR -> Update-IR with no real
     shift at all (e.g. `tms_payload([1,1,0,1,1,0])` from Run-Test/Idle), latching
     whatever Capture-IR loaded (BSDL "...01", which can match ISC_PROGRAM and other
     instructions on this device) as the live instruction. `send()` now refuses ANY
     untokened transition INTO Capture-IR, and any untokened transition into Update-IR
     whose immediately preceding state was Exit1-IR or Exit2-IR (the only two edges
     into Update-IR from the IR side) -- not just "already in Shift-IR", which was
     round 1's narrower rule and still kept, since it does not subsume this one (CMD_TMS
     can enter the IR branch and reach Update-IR in a single call without ever passing
     through a state that round 1's rule inspected).
  2. The shadow could silently desync from the real TAP: round 1 started it at
     Test-Logic-Reset (an assumption, not a fact) and committed a transmitted command's
     predicted next state even when the reply reported a failure. The shadow now starts
     UNKNOWN, is forced UNKNOWN by any exception from send()/reply(), by a txn mismatch,
     or by a non-OK status, and is advanced only once a call is confirmed to have
     succeeded. From UNKNOWN every send is refused except `CoE.resync()`, the one method
     that does not require (or trust) a known starting state: it holds TDI=1 and plays a
     fixed TMS sequence, derived by exhaustive search over all 16 possible starting
     states (`tools/jc/derive_resync.py`), that never reaches Update-IR before at least
     24 bits -- the chain's full IR length -- are known to have been freshly shifted
     into the IR shift register, and that ends at Run-Test/Idle from every one of them.
     `start()` calls it in place of a raw reset, and it is also how a TAP stranded in
     Shift-IR (round 1's dead end, since nothing could leave Shift-IR without a token)
     gets out.
  3. The two per-call tokens (`_IR_TOKEN` for `ir_scan`, `_ALL_ONES_TOKEN` for
     `ir_shift_all_ones`) were accepted as a bare "is this the right token" check with
     no regard for what the payload under them actually contained, and `call()`'s public
     signature exposed `_token` as an ordinary keyword, reachable by anyone holding a
     reference to the token object. `send()` now decodes the bits under a token and
     refuses unless they are EXACTLY the shape that method builds (the fixed toIR/exitIR
     constants, plus either a validated 2-op `ir_scan_payload` or an all-ones run of at
     least 24 bits with the right TMS tail) -- holding the token is no longer sufficient,
     the payload has to match it. `call()`'s public parameters no longer include a token
     at all; the three vetted methods reach the private `_call_token` helper instead.

Exact payload shape is also now checked up front for every CMD_TMS/CMD_TDI (dev/flags
bytes, and the body length matching the declared bit count with no trailing bytes) --
fix round 2 item 4; round 1 only decoded the bits it needed and ignored the rest.
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
# TAP state, even from UNKNOWN. Anything else reaching send() that is not CMD_TMS or
# CMD_TDI is refused.
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

# A shadow state meaning "the real TAP's position is not known" -- not one of the 16
# real states, so it never matches a TAP_NEXT lookup by accident. CoE starts here; any
# failed send/reply/call forces it back here; CoE.resync() is the only way out.
UNKNOWN = -1

# Private tokens. Not public parameters: nothing outside this module can name them
# without reaching into coe._IR_TOKEN etc., which is not something a caller does
# casually, and holding one is not enough on its own -- send() also checks that the
# payload under it is exactly the shape the corresponding method builds.
_IR_TOKEN = object()
_ALL_ONES_TOKEN = object()
_RESYNC_TOKEN = object()

class IRNotAllowed(Exception):
    pass

class TapProtocolError(Exception):
    """A send/call would violate the shadow TAP state machine, the CoE payload shape,
    or the reply contract. Raised before anything is written to the socket, except
    where noted (a transmit or reply failure forces the shadow to UNKNOWN as part of
    raising)."""
    pass

class CoEError(Exception):
    """A reply failed the protocol's own contract (short header, txn mismatch, a
    status other than STATUS_OK)."""
    pass

def _require_tms_shape(payload):
    """CMD_TMS body: dev=0, flags=0, count, then exactly ceil(count/8) (TDI,TMS) byte
    pairs -- no more, no less. Returns (count, tdi_bits, tms_bits)."""
    if len(payload) < 4:
        raise TapProtocolError("CMD_TMS payload shorter than its 4-byte header")
    dev, flags, n = struct.unpack_from("<BBH", payload, 0)
    if dev != 0 or flags != 0:
        raise TapProtocolError("CMD_TMS requires dev=0, flags=0, got dev=%d flags=%#x"
                                % (dev, flags))
    need = 4 + 2 * ((n + 7) // 8)
    if len(payload) != need:
        raise TapProtocolError("CMD_TMS count=%d needs exactly %d payload bytes, got %d"
                                % (n, need, len(payload)))
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

def _require_tdi_shape(payload):
    """CMD_TDI body: dev=0, flags=0x20, nbits, then exactly ceil(nbits/8) TDI bytes --
    no more, no less. Returns nbits."""
    if len(payload) < 4:
        raise TapProtocolError("CMD_TDI payload shorter than its 4-byte header")
    dev, flags, n = struct.unpack_from("<BBH", payload, 0)
    if dev != 0 or flags != 0x20:
        raise TapProtocolError("CMD_TDI requires dev=0, flags=0x20, got dev=%d flags=%#x"
                                % (dev, flags))
    need = 4 + (n + 7) // 8
    if len(payload) != need:
        raise TapProtocolError("CMD_TDI nbits=%d needs exactly %d payload bytes, got %d"
                                % (n, need, len(payload)))
    return n

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
    carries the internal token CoE.ir_scan hands out, AND the bits under that token
    decode back to exactly this builder's output for some allowlisted ops."""
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
# send by hand: RTI -> Shift-IR, and Exit1-IR -> RTI. Used by both ir_scan and
# ir_shift_all_ones, under either's token.
_TO_IR = tms_payload([1, 1, 0, 0])
_EXIT_IR = tms_payload([1, 0])

def _ir_scan_ops_from_bits(tdi_bits):
    """Reverse of ir_scan_payload's own bit-packing. None if the length is wrong for a
    CHAIN_DEVICES-op scan."""
    if len(tdi_bits) != CHAIN_DEVICES * IR_LEN:
        return None
    ops = []
    for d in range(CHAIN_DEVICES):
        v = 0
        for i in range(IR_LEN):
            v |= tdi_bits[d * IR_LEN + i] << i
        ops.append(v)
    ops.reverse()
    return ops

def _payload_matches_ir_token(payload, tdi_bits):
    if payload in (_TO_IR, _EXIT_IR):
        return True
    ops = _ir_scan_ops_from_bits(tdi_bits)
    if ops is None:
        return False
    try:
        return payload == ir_scan_payload(ops)
    except IRNotAllowed:
        return False

def _payload_matches_all_ones_token(payload, count, tdi_bits, tms_bits):
    if payload in (_TO_IR, _EXIT_IR):
        return True
    if count < CHAIN_DEVICES * IR_LEN:
        return False
    if any(b != 1 for b in tdi_bits):
        return False
    return tms_bits == [0] * (count - 1) + [1]

def _walk(state, tms_bits, guarded):
    """Advance `state` through TAP_NEXT for each bit in tms_bits. When `guarded`
    (an untokened CMD_TMS), refuse (fix round 2, item 1):
      - clocking any bit while already in Shift-IR (round 1's rule: the only way to
        shift real data into the IR without a vetted method),
      - a transition INTO Capture-IR (the sole entry to the whole IR-side subgraph --
        blocking it blocks every other way in too),
      - a transition INTO Update-IR whose previous state was Exit1-IR or Exit2-IR (the
        only two edges into Update-IR from the IR side: this is the latch itself)."""
    for bit in tms_bits:
        if guarded and state == SHIFT_IR:
            raise TapProtocolError(
                "CMD_TMS would clock a bit while the shadow TAP is in Shift-IR; route "
                "IR shifts through CoE.ir_scan, CoE.ir_shift_all_ones, or CoE.resync")
        new_state = TAP_NEXT[state][bit]
        if guarded and new_state == CAPTURE_IR:
            raise TapProtocolError(
                "CMD_TMS would enter Capture-IR untokened; route IR access through "
                "CoE.ir_scan, CoE.ir_shift_all_ones, or CoE.resync")
        if guarded and new_state == UPDATE_IR and state in (EXIT1_IR, EXIT2_IR):
            raise TapProtocolError(
                "CMD_TMS would latch Update-IR from the IR side untokened (the capture "
                "value is not safe to latch); route IR access through CoE.ir_scan, "
                "CoE.ir_shift_all_ones, or CoE.resync")
        state = new_state
    return state

class CoE:
    def __init__(s, ip, port=21363, timeout=10.0):
        s.s = socket.create_connection((ip, port), timeout=timeout)
        s.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.txn = 1
        s.tap = UNKNOWN                  # the real TAP's position is not known yet

    def send(s, cmd, payload=b"", _token=None):
        if cmd == CMD_TMS:
            if _token is _RESYNC_TOKEN:
                if payload != _RESYNC_PAYLOAD:
                    raise TapProtocolError(
                        "resync token used with a payload other than the derived "
                        "resync sequence")
                next_tap = RUN_TEST_IDLE     # guaranteed from EVERY starting state
            else:
                count, tdi_bits, tms_bits = _require_tms_shape(payload)
                if _token is _IR_TOKEN:
                    if not _payload_matches_ir_token(payload, tdi_bits):
                        raise TapProtocolError(
                            "ir_scan token used with a payload that is not the vetted "
                            "toIR/opcode-shift/exitIR shape")
                elif _token is _ALL_ONES_TOKEN:
                    if not _payload_matches_all_ones_token(payload, count, tdi_bits, tms_bits):
                        raise TapProtocolError(
                            "ir_shift_all_ones token used with a payload that is not "
                            "the vetted toIR/all-ones/exitIR shape")
                if s.tap is UNKNOWN:
                    raise TapProtocolError(
                        "shadow TAP is UNKNOWN (never resynced, or a prior send/reply "
                        "failed); call CoE.resync() first")
                guarded = _token not in (_IR_TOKEN, _ALL_ONES_TOKEN)
                next_tap = _walk(s.tap, tms_bits, guarded)
        elif cmd == CMD_TDI:
            _require_tdi_shape(payload)
            if s.tap is UNKNOWN:
                raise TapProtocolError(
                    "shadow TAP is UNKNOWN (never resynced, or a prior send/reply "
                    "failed); call CoE.resync() first")
            if s.tap != SHIFT_DR:
                raise TapProtocolError(
                    "CMD_TDI sent while the shadow TAP is in state %d, not Shift-DR (%d)"
                    % (s.tap, SHIFT_DR))
            next_tap = s.tap              # flags=0x20 holds TMS at 0 for the whole shift
        elif cmd in _HANDSHAKE_CMDS:
            next_tap = s.tap              # BMC-level commands; no TAP effect, any state
        else:
            raise TapProtocolError("unknown CoE command %#x" % cmd)
        # txn bit 15 is not a counter bit: txn 0x8000 drew a 4-byte error reply (MEASURED)
        t = s.txn
        s.txn = s.txn + 1 if s.txn < 0x7FFF else 1
        try:
            s.s.sendall(struct.pack("<HHI", 8 + len(payload), t, cmd) + payload)
        except Exception:
            s.tap = UNKNOWN               # bytes may have partially gone out; forget it
            raise
        s._pending_tap = next_tap         # NOT committed yet -- call()/_call_token does that
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
        try:
            hdr = s._recv(8)
            L, t, st = struct.unpack("<HHI", hdr)
            if L < 8:
                raise CoEError("reply length %d is less than the 8-byte header" % L)
            return t, st, s._recv(L - 8)
        except Exception:
            s.tap = UNKNOWN
            raise

    def _call_token(s, cmd, payload, token):
        """send() + reply() + the commit discipline: the shadow only advances to the
        state send() predicted once the reply is confirmed (matching txn, STATUS_OK);
        any failure anywhere in this sequence leaves (or forces) the shadow at UNKNOWN.
        Private: `token` is never a parameter a caller can reach through call()."""
        t = s.send(cmd, payload, _token=token)
        try:
            rt, st, d = s.reply()
        except Exception:
            s.tap = UNKNOWN
            raise
        if rt != t:
            s.tap = UNKNOWN
            raise CoEError("txn mismatch: sent %#06x, reply carried %#06x" % (t, rt))
        if st != STATUS_OK:
            s.tap = UNKNOWN
            raise CoEError("status %#010x, expected STATUS_OK %#010x" % (st, STATUS_OK))
        s.tap = s._pending_tap
        return st, d

    def call(s, cmd, payload=b""):
        return s._call_token(cmd, payload, None)

    def ir_scan(s, ops):
        """The one vetted way to shift an IR opcode into every device on the chain:
        validates against the allowlist and the chain's device count FIRST (raises
        IRNotAllowed, nothing sent), then drives RTI -> Shift-IR -> (ops) -> RTI, every
        sub-call under the internal token, byte-identical to the old hand-rolled
        toIR/shift/exitIR sequence."""
        payload = ir_scan_payload(ops)
        if s.tap != RUN_TEST_IDLE:
            raise TapProtocolError(
                "ir_scan must start from Run-Test/Idle, shadow TAP is in state %r" % (s.tap,))
        s._call_token(CMD_TMS, _TO_IR, _IR_TOKEN)
        s._call_token(CMD_TMS, payload, _IR_TOKEN)
        s._call_token(CMD_TMS, _EXIT_IR, _IR_TOKEN)

    def ir_shift_all_ones(s, n):
        """The raw-throughput measurement tool's own pattern (coe_stream.py): shifting
        n >= the chain's IR length (24 bits: two 12-bit devices) of all-ones loads
        BYPASS into every device regardless of IR length, independent of the allowlist
        (there is no opcode to check -- the bit pattern is fixed and always safe).
        Fewer than 24 bits would not necessarily clear every device's IR, so that is
        refused outright."""
        if n < CHAIN_DEVICES * IR_LEN:
            raise ValueError("ir_shift_all_ones needs at least %d bits (the chain's IR "
                              "length), got %d" % (CHAIN_DEVICES * IR_LEN, n))
        if s.tap != RUN_TEST_IDLE:
            raise TapProtocolError(
                "ir_shift_all_ones must start from Run-Test/Idle, shadow TAP is in "
                "state %r" % (s.tap,))
        s._call_token(CMD_TMS, _TO_IR, _ALL_ONES_TOKEN)
        s._call_token(CMD_TMS, pair_payload([1] * n, [0] * (n - 1) + [1]), _ALL_ONES_TOKEN)
        s._call_token(CMD_TMS, _EXIT_IR, _ALL_ONES_TOKEN)

    def resync(s):
        """The one way to bring the shadow (and the real TAP) to a known state from ANY
        starting condition, including a genuinely UNKNOWN shadow and a TAP stranded in
        Shift-IR. Holds TDI=1 throughout and plays the fixed sequence derived by
        tools/jc/derive_resync.py: safe (never reaches Update-IR before at least 24
        fresh ones have been shifted into the IR register) and convergent (ends at
        Run-Test/Idle) from every one of the TAP's 16 possible starting states."""
        s._call_token(CMD_TMS, _RESYNC_PAYLOAD, _RESYNC_TOKEN)

    def start(s, hz=27_000_000):
        s.call(CMD_HELLO)
        s.call(CMD_SPEED, struct.pack("<II", 0, hz))
        s.call(CMD_MODE, bytes.fromhex("0002"))
        _, ids = s.call(CMD_IDCODES, bytes.fromhex("0000"))
        if ids != VU35P_X2_IDCODES:
            raise RuntimeError("unexpected IDCODEs %s" % ids.hex())
        s.call(CMD_IRLEN, bytes.fromhex("000c0c"))
        s.call(CMD_MODE, bytes.fromhex("0001"))
        s.resync()
        return ids

# Backward-compatible aliases: short names used by the TAP checks above, kept at module
# scope under both spellings so a test can refer to either coe.SHIFT_IR or the full name.
TLR, RTI = TEST_LOGIC_RESET, RUN_TEST_IDLE

# Derived by tools/jc/derive_resync.py (exhaustive BFS over all 16 starting states); see
# that file's docstring for the exact safety property and CoE.resync's docstring for how
# it is used. Length 55. test_coe.py::test_resync_sequence_is_derived_safely re-derives
# and independently replays this exact list, so a hand transcription error cannot drift
# from the search silently.
_RESYNC_TMS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 1, 1, 0]
_RESYNC_PAYLOAD = pair_payload([1] * len(_RESYNC_TMS), _RESYNC_TMS)
