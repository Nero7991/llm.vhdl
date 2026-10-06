"""Direct SQRL CoE client for the Jungle Cat BMC (no sqrl_bridge).

Protocol: docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md S12.
Only commands observed from the stock bridge are sent. The IR allowlist is the one
guard against shifting JPROGRAM or an eFUSE opcode (xcvu35p_fsvh2104.bsd); keep it.

Fix round 1: round 1's guard moved the IR allowlist down to `send()`, backed by a
shadow 16-state TAP machine advanced by every TMS bit transmitted.

Fix round 2 closed three gaps in that guard: an untokened CMD_TMS could enter
Capture-IR or latch Update-IR from the IR side with no real shift at all; the shadow
could desync (it started at an assumed Test-Logic-Reset and committed a predicted
state even on a failed reply); and the two per-call tokens were a bare identity check,
not bound to what was actually under them.

Fix round 3 (re-review, 2026-10-05) found the shadow could STILL desync, through a
path round 2 left wide open on purpose: the then-public `send()` validated a CMD_TMS
against the shadow but deferred the actual commit to `_call_token`, so calling the
public `send()` directly (as the old `CoE.call()` itself did not, but nothing stopped
a caller from doing) and reading `reply()` separately left the shadow exactly where it
started -- while the REAL TAP had moved. A second `send()`/`call()` then validated
against that stale shadow and could walk the real TAP into Capture-IR/Update-IR
believing it was still safe. Round 3's ruling, applied below:

  A. The public `send()` now accepts ONLY `CMD_TDI`. A TDI-only shift's wire form
     (`flags=0x20`, see `_require_tdi_shape`) holds TMS at 0 for the entire shift --
     there is no "last bit TMS=1" variant anywhere in `dr_payload`/`_require_tdi_shape`
     -- so a TDI-only shift cannot leave Shift-DR by construction. That is exactly why
     it is safe to leave public: there is nothing to predict and later confirm, unlike
     every CMD_TMS move. `send()` requires the shadow to already be Shift-DR (reached
     via `to_shift_dr()`) and refuses every other command, including CMD_TMS.
  B. Every CMD_TMS now goes through a synchronous vetted method -- `resync`, `ir_scan`,
     `to_shift_dr`, `exit_dr_to_idle`, `ir_shift_all_ones` -- and nothing else; there is
     no public way to send a CMD_TMS payload at all. Each one sets `s.tap = UNKNOWN`
     BEFORE the bytes go out, and restores the predicted end state only once the reply
     is confirmed good, inside a `try`/`finally` so a `BaseException` (Ctrl-C) leaves
     UNKNOWN rather than resurrecting a stale guess.
  C. `reply()` now takes the expected txn, checks it AND the status itself, forces
     `s.tap = UNKNOWN` on either failure (or on any exception at all, `BaseException`
     included), and always raises rather than returning silently on a mismatch.
  D. Every vetted method's step is bound to the state it must start from (`_TO_IR`
     only from Run-Test/Idle, the opcode/all-ones shift only from Shift-IR, `_EXIT_IR`
     only from Exit1-IR, the resync payload from any state at all) as well as to its
     exact payload shape; the private token that selects which binding applies is not
     a parameter of any public method.
  E. The handshake commands (`CMD_IDCODES`, `CMD_MODE`, and by the same reasoning every
     other one) can drive the real TAP by mechanisms this shadow does not model, so
     they now force `s.tap = UNKNOWN` unconditionally -- `start()` already resyncs
     afterward, which is now load-bearing rather than a courtesy.
  F. Minors: the unused padding bits in a CMD_TMS/CMD_TDI body's last byte must be zero
     (checked, not just ignored); UNKNOWN is a dedicated sentinel object, compared with
     `is`, not the integer `-1` (which merely happened not to collide with a real
     state). `resync()`'s own docstring now says plainly that it passes one Update-DR,
     under whatever instruction was active before, from 10 of the 16 starting states
     (see `tools/jc/derive_resync.py`'s `resync_check`-style analysis) -- harmless to
     `jc_frame_core`, which never acts on Update-DR, but it does mean any frame that was
     only partially shifted in before `resync()` was called is abandoned, not completed.

Task 9 (Task 8 final review, items N1-N3, 2026-10-05):

  N1. `send()` records every CMD_TDI txn in `s.outstanding` (send order) and `reply()`
      removes the oldest one when it reads a reply. Every vetted TMS move (resync
      included) and every handshake `call()` is refused while any are unread: the
      move's own reply() would otherwise read a pipelined CMD_TDI reply as its own and
      commit a TAP state on the strength of it. `drain()` reads every outstanding
      reply, forcing UNKNOWN on any bad one (exactly as reply() does) but reading the
      rest regardless, so the reply stream is clean afterwards. A reply() for a txn
      that is not the oldest outstanding one is refused without reading anything.
  N2. Recovery after a pipelined failure is `drain()` then `resync()`.
  N3. A CMD_TDI with nbits=0 is refused (the BMC's behaviour for it is not measured).

  Also: a reply whose bytes stop arriving part-way (socket closed, timeout, Ctrl-C
  inside the read) or whose header is malformed leaves the byte stream unframed, so
  no later reply can be matched to its command. That POISONS the connection (`s.dead`):
  every later write and read raises ConnectionError, nothing more is sent, and the
  caller must open a new connection and start() again. Same for a failed write.
  `CoE(ip, sock=...)` takes an already-made socket-like object (tests only; it never
  dials when one is given).
"""
import socket
import time, struct

IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4 = 0xFFF, 0x249, 0x8A4, 0x8E4
IR_ALLOW = {IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4}
IR_LEN = 12
CHAIN_DEVICES = 2                        # IR lengths 0x0c 0x0c read by start(): 2 devices
CMD_HELLO, CMD_SPEED, CMD_MODE = 0x80001000, 0x8000100C, 0x80001001
CMD_IDCODES, CMD_IRLEN = 0x80001010, 0x80001011
CMD_TMS, CMD_TDI = 0x8000100E, 0x8000100F
STATUS_OK = 0x8000000A
VU35P_X2_IDCODES = bytes.fromhex("9310b7149310b714")

# The commands start() issues. All five can drive the real TAP by mechanisms this
# shadow does not model (fix round 3, item E), so a call to any of them forces UNKNOWN.
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

class _UnknownTap(object):
    """A dedicated sentinel, not the integer -1: fix round 3 item F. Compare with
    `is`/`is not`, never `==`; nothing about it is meant to look like a real state."""
    __slots__ = ()
    def __repr__(self):
        return "UNKNOWN"

# The real TAP's position is not known. CoE starts here; every vetted method sets this
# BEFORE transmitting and only clears it once a reply confirms success; `resync()` is
# the only method willing to run from here (or from any other state).
UNKNOWN = _UnknownTap()

# Private tokens, each selecting a fixed list of (content check, required start state,
# end state) steps in _TOKEN_STEPS below. Not reachable from any public signature
# (fix round 3 item D): send() takes no token at all now, and _call_token is the only
# place that consumes one.
_IR_TOKEN = object()
_ALL_ONES_TOKEN = object()
_RESYNC_TOKEN = object()
_TO_DR_TOKEN = object()
_EXIT_DR_TOKEN = object()

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
    pairs -- no more, no less -- and the unused padding bits in the last byte, if
    count is not a multiple of 8, must be zero (fix round 3 item F). Returns
    (count, tdi_bits, tms_bits)."""
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
    if n % 8:
        pad_mask = (~((1 << (n % 8)) - 1)) & 0xFF
        if payload[-2] & pad_mask or payload[-1] & pad_mask:
            raise TapProtocolError("CMD_TMS has nonzero padding bits beyond its count=%d" % n)
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
    no more, no less -- and, same as CMD_TMS, zero padding bits beyond nbits in the
    last byte. flags=0x20 is the ONLY form this client builds or accepts: it holds TMS
    at 0 for the whole shift, so a TDI-only command can never leave Shift-DR -- there
    is no "last bit TMS=1" variant to model. Returns nbits."""
    if len(payload) < 4:
        raise TapProtocolError("CMD_TDI payload shorter than its 4-byte header")
    dev, flags, n = struct.unpack_from("<BBH", payload, 0)
    if dev != 0 or flags != 0x20:
        raise TapProtocolError("CMD_TDI requires dev=0, flags=0x20, got dev=%d flags=%#x"
                                % (dev, flags))
    if n == 0:
        raise TapProtocolError("CMD_TDI with nbits=0 is refused (Task 9 N3)")
    need = 4 + (n + 7) // 8
    if len(payload) != need:
        raise TapProtocolError("CMD_TDI nbits=%d needs exactly %d payload bytes, got %d"
                                % (n, need, len(payload)))
    if n % 8:
        pad_mask = (~((1 << (n % 8)) - 1)) & 0xFF
        if payload[-1] & pad_mask:
            raise TapProtocolError("CMD_TDI has nonzero padding bits beyond its nbits=%d" % n)
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
    sufficient to send it -- the only path that ever transmits a CMD_TMS payload is the
    private, state-bound `_call_token`, reached from `CoE.ir_scan` and nowhere else for
    this exact shape."""
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

# Fixed payloads for every legal TMS move this client ever makes, each byte-identical
# to what the pre-guard, hand-rolled TMS dance used to send.
_TO_IR = tms_payload([1, 1, 0, 0])              # Run-Test/Idle -> Shift-IR
_EXIT_IR = tms_payload([1, 0])                  # Exit1-IR -> Run-Test/Idle
_TO_DR_PAYLOAD = tms_payload([1, 0, 0])          # Run-Test/Idle -> Shift-DR ("toDR")
_EXIT_DR_PAYLOAD = tms_payload([1, 1, 0])        # Shift-DR -> Run-Test/Idle ("exit")

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

def _is_ir_scan_shift(payload, tdi_bits, tms_bits, n):
    ops = _ir_scan_ops_from_bits(tdi_bits)
    if ops is None:
        return False
    try:
        return payload == ir_scan_payload(ops)
    except IRNotAllowed:
        return False

def _is_all_ones_shift(payload, tdi_bits, tms_bits, n):
    if n < CHAIN_DEVICES * IR_LEN:
        return False
    if any(b != 1 for b in tdi_bits):
        return False
    return tms_bits == [0] * (n - 1) + [1]

def _matches(expected):
    return lambda payload, tdi_bits, tms_bits, n: payload == expected

# Derived by tools/jc/derive_resync.py (exhaustive BFS over all 16 starting states); see
# that file's docstring for the exact safety property. Length 55.
# test_coe.py::test_resync_derivation_matches_the_committed_sequence re-derives and
# compares this exact list, so a hand transcription error cannot drift silently.
_RESYNC_TMS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 1, 1, 0]
_RESYNC_PAYLOAD = pair_payload([1] * len(_RESYNC_TMS), _RESYNC_TMS)

# Every CMD_TMS payload this client will ever transmit, grouped by the private token
# that vouches for it, as (content check, required start state or None, end state).
# `_call_token` is the only consumer: it looks up `token`, finds the step whose check
# matches the given payload, requires the shadow to already be in that step's start
# state (None means any state at all, including UNKNOWN -- only resync's step uses
# this), and on a confirmed-good reply commits the shadow to that step's end state.
_TOKEN_STEPS = {
    _IR_TOKEN: [
        (_matches(_TO_IR), RUN_TEST_IDLE, SHIFT_IR),
        (_is_ir_scan_shift, SHIFT_IR, EXIT1_IR),
        (_matches(_EXIT_IR), EXIT1_IR, RUN_TEST_IDLE),
    ],
    _ALL_ONES_TOKEN: [
        (_matches(_TO_IR), RUN_TEST_IDLE, SHIFT_IR),
        (_is_all_ones_shift, SHIFT_IR, EXIT1_IR),
        (_matches(_EXIT_IR), EXIT1_IR, RUN_TEST_IDLE),
    ],
    _TO_DR_TOKEN: [
        (_matches(_TO_DR_PAYLOAD), RUN_TEST_IDLE, SHIFT_DR),
    ],
    _EXIT_DR_TOKEN: [
        (_matches(_EXIT_DR_PAYLOAD), SHIFT_DR, RUN_TEST_IDLE),
    ],
    _RESYNC_TOKEN: [
        (_matches(_RESYNC_PAYLOAD), None, RUN_TEST_IDLE),
    ],
}

class CoE:
    def __init__(s, ip, port=21363, timeout=10.0, sock=None):
        if sock is None:
            s.s = socket.create_connection((ip, port), timeout=timeout)
            s.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        else:
            s.s = sock                   # a fake transport (tests): never dials
        s.txn = 1
        s.tap = UNKNOWN                  # the real TAP's position is not known yet
        s.outstanding = []               # CMD_TDI txns sent, replies not yet read (N1)
        s.dead = None                    # reason, once the reply stream is unframed

    def _poison(s, why):
        """The byte stream can no longer be framed: nothing later can be trusted."""
        s.tap = UNKNOWN
        s.outstanding = []
        if not s.dead:
            s.dead = why

    def _require_alive(s):
        if s.dead:
            raise ConnectionError("CoE connection is unusable (%s); open a new one and "
                                  "start() again" % s.dead)

    def _require_no_outstanding(s, what):
        if s.outstanding:
            raise TapProtocolError(
                "%s refused: %d CMD_TDI repl%s still unread (txn %s); drain() first"
                % (what, len(s.outstanding), "y" if len(s.outstanding) == 1 else "ies",
                   ", ".join("%#06x" % t for t in s.outstanding)))

    def _raw_send(s, cmd, payload):
        """The only place that actually writes to the socket. No validation, no shadow
        update of its own beyond the universal rule: if the write itself fails (bytes
        may have partially gone out), the shadow can no longer be trusted, and neither
        can the reply stream (the BMC may or may not answer a half-written command), so
        the connection is poisoned."""
        s._require_alive()
        t = s.txn
        s.txn = s.txn + 1 if s.txn < 0x7FFF else 1
        try:
            s.s.sendall(struct.pack("<HHI", 8 + len(payload), t, cmd) + payload)
        except BaseException:
            s._poison("a write failed part-way")
            raise
        return t

    def send(s, cmd, payload=b""):
        """PUBLIC. Accepts ONLY CMD_TDI -- the bulk, pipelined DR-shift command this
        exists for (coe_stream.py's throughput loop, and the loader's frame writes).
        Every CMD_TDI payload holds TMS at 0 for its entire shift (fix round 3 item A:
        flags=0x20 is the only form `dr_payload`/`_require_tdi_shape` build or accept;
        there is no "last bit TMS=1" variant), so a TDI-only shift cannot leave
        Shift-DR by construction -- there is nothing here to predict and later confirm,
        unlike every CMD_TMS move. Requires the shadow to already be Shift-DR (reached
        via `to_shift_dr()`) and refuses every other command, CMD_TMS included: there
        is no public way to send a CMD_TMS payload at all -- use a vetted method
        (resync, ir_scan, to_shift_dr, exit_dr_to_idle, ir_shift_all_ones)."""
        if cmd != CMD_TDI:
            raise TapProtocolError(
                "send() accepts only CMD_TDI; every CMD_TMS move goes through a vetted "
                "method (resync, ir_scan, to_shift_dr, exit_dr_to_idle, ir_shift_all_ones)")
        _require_tdi_shape(payload)
        if s.tap != SHIFT_DR:
            raise TapProtocolError(
                "CMD_TDI sent while the shadow TAP is %r, not Shift-DR" % (s.tap,))
        t = s._raw_send(cmd, payload)           # tap unchanged: flags=0x20 cannot move it
        s.outstanding.append(t)                 # N1: its reply is now owed
        return t

    def _recv(s, n):
        b = bytearray()
        while len(b) < n:
            c = s.s.recv(n - len(b))
            if not c:
                raise ConnectionError("CoE closed")
            b += c
        return bytes(b)

    def reply(s, expect_txn):
        """Reads one reply and validates it completely: a short header, a txn other
        than `expect_txn`, a status other than STATUS_OK, or any other exception
        (BaseException included -- Ctrl-C must not look like success) all force
        `s.tap = UNKNOWN` and raise. There is no silent return on a mismatch (fix
        round 3 item C).

        N1: while CMD_TDI replies are outstanding, replies arrive in send order, so
        `expect_txn` must be the oldest outstanding txn; anything else is refused
        before reading (forcing UNKNOWN). A reply that is read completely removes the
        oldest outstanding txn whatever it says. A read that fails part-way, or a
        malformed header, poisons the connection (see the module docstring)."""
        s._require_alive()
        if s.outstanding and expect_txn != s.outstanding[0]:
            s.tap = UNKNOWN
            raise TapProtocolError(
                "reply(%#06x) out of order: the oldest unread CMD_TDI reply is txn %#06x"
                % (expect_txn, s.outstanding[0]))
        try:
            hdr = s._recv(8)
            L, t, st = struct.unpack("<HHI", hdr)
            if L < 8:
                raise CoEError("reply length %d is less than the 8-byte header" % L)
            data = s._recv(L - 8)
        except BaseException:
            s._poison("a reply read failed part-way or was malformed")
            raise
        if s.outstanding:
            s.outstanding.pop(0)
        if t != expect_txn:
            s.tap = UNKNOWN
            raise CoEError("txn mismatch: expected %#06x, reply carried %#06x" % (expect_txn, t))
        if st != STATUS_OK:
            s.tap = UNKNOWN
            raise CoEError("status %#010x, expected STATUS_OK %#010x" % (st, STATUS_OK))
        return st, data

    def drain(s):
        """N1/N2: read every outstanding CMD_TDI reply, oldest first. A bad one (txn
        mismatch, non-OK status) forces UNKNOWN exactly as reply() does, and the rest
        are still read, so afterwards no reply is owed and the next vetted move's reply
        is its own. Returns (good, bad): good is [(txn, status, data)], bad is
        [(txn, CoEError)]. Never restores a known state: after any bad reply the
        shadow stays UNKNOWN and only resync() may run (N2: recovery after a pipelined
        failure is drain() then resync()). A framing loss raises ConnectionError (the
        connection is poisoned and nothing further can be read)."""
        s._require_alive()
        good, bad = [], []
        while s.outstanding:
            t = s.outstanding[0]
            try:
                st, data = s.reply(t)
                good.append((t, st, data))
            except CoEError as e:
                if s.dead:
                    raise ConnectionError("CoE reply framing lost during drain(): %s" % e)
                bad.append((t, e))
        return good, bad

    def _call_token(s, cmd, payload, token):
        """The only place a CMD_TMS payload is ever transmitted. Looks up which of
        `token`'s recognized steps `payload` matches (shape first, then content);
        requires the shadow to already be in that step's required start state (or
        tolerates any state, UNKNOWN included, when the step's start is None -- only
        resync's step does this); sets the shadow to UNKNOWN BEFORE transmitting; and,
        inside try/finally so a BaseException leaves UNKNOWN rather than resurrecting a
        stale guess, restores the step's end state only once the reply has confirmed
        success (fix round 3 items B and D)."""
        if cmd != CMD_TMS:
            raise TapProtocolError("_call_token is for CMD_TMS only")
        s._require_alive()
        s._require_no_outstanding("a vetted TMS move")
        n, tdi_bits, tms_bits = _require_tms_shape(payload)
        steps = _TOKEN_STEPS.get(token)
        if steps is None:
            raise TapProtocolError("not a recognized vetted-method token")
        match = None
        for check, start, end in steps:
            if check(payload, tdi_bits, tms_bits, n):
                match = (start, end)
                break
        if match is None:
            raise TapProtocolError("token payload does not match any of its vetted steps")
        start, end = match
        if start is not None and s.tap != start:
            raise TapProtocolError(
                "this vetted step requires shadow state %r, shadow is %r" % (start, s.tap))
        s.tap = UNKNOWN
        done = False
        try:
            t = s._raw_send(cmd, payload)
            result = s.reply(t)
            done = True
        finally:
            if done:
                s.tap = end
            # else: already UNKNOWN; nothing to restore
        return result

    def _call_handshake(s, cmd, payload=b""):
        """CMD_HELLO/SPEED/MODE/IDCODES/IRLEN. Forces UNKNOWN unconditionally, before
        transmitting, and never restores anything -- these can drive the real TAP by
        means this shadow does not model (fix round 3 item E), so start()'s closing
        resync() is load-bearing, not a courtesy."""
        s._require_alive()
        s._require_no_outstanding("a handshake call()")
        s.tap = UNKNOWN
        t = s._raw_send(cmd, payload)
        return s.reply(t)

    def call(s, cmd, payload=b""):
        """PUBLIC. Accepts ONLY the handshake commands. CMD_TMS has no public path at
        all (use a vetted method); CMD_TDI uses the public send()/reply() pair instead
        (it is pipelined -- call()'s one-send-one-reply shape does not fit it)."""
        if cmd not in _HANDSHAKE_CMDS:
            raise TapProtocolError(
                "call() accepts only the handshake commands %s; a CMD_TMS move goes "
                "through a vetted method, CMD_TDI through send()/reply()"
                % sorted(hex(c) for c in _HANDSHAKE_CMDS))
        return s._call_handshake(cmd, payload)

    def ir_scan(s, ops):
        """The one vetted way to shift an IR opcode into every device on the chain:
        validates against the allowlist and the chain's device count FIRST (raises
        IRNotAllowed, nothing sent), then drives Run-Test/Idle -> Shift-IR -> (ops) ->
        Run-Test/Idle, each of the three sub-calls bound to its own required start
        state by `_call_token`, byte-identical to the old hand-rolled
        toIR/shift/exitIR sequence."""
        payload = ir_scan_payload(ops)
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
        s._call_token(CMD_TMS, _TO_IR, _ALL_ONES_TOKEN)
        s._call_token(CMD_TMS, pair_payload([1] * n, [0] * (n - 1) + [1]), _ALL_ONES_TOKEN)
        s._call_token(CMD_TMS, _EXIT_IR, _ALL_ONES_TOKEN)

    def to_shift_dr(s):
        """Run-Test/Idle -> Shift-DR: the move needed before a run of CMD_TDI shifts.
        Not IR-side, so it needs no opcode validation, only the same state-bound,
        set-UNKNOWN-then-confirm discipline as every other CMD_TMS move."""
        s._call_token(CMD_TMS, _TO_DR_PAYLOAD, _TO_DR_TOKEN)

    def exit_dr_to_idle(s):
        """Shift-DR -> Run-Test/Idle: the move after the last CMD_TDI shift of a run."""
        s._call_token(CMD_TMS, _EXIT_DR_PAYLOAD, _EXIT_DR_TOKEN)

    def resync(s):
        """The one way to bring the shadow (and the real TAP) to a known state from ANY
        starting condition, including a genuinely UNKNOWN shadow and a TAP stranded in
        Shift-IR. Holds TDI=1 throughout and plays the fixed sequence derived by
        tools/jc/derive_resync.py: safe (never reaches Update-IR before at least 24
        fresh ones have been shifted into the IR register) and convergent (ends at
        Run-Test/Idle) from every one of the TAP's 16 possible starting states.

        Not modelled, and not a defect this client can do anything about: from 10 of
        those 16 starting states the sequence passes exactly one Update-DR under
        whatever instruction was active before resync() was called. jc_frame_core never
        acts on Update-DR, so this is harmless to the loader's own correctness -- but it
        means a frame that was only partially shifted in when resync() was called is
        abandoned, not completed. Calling resync() mid-load discards that one frame;
        the resend-from-last-committed-seq design (Task 9) is what recovers it."""
        s._call_token(CMD_TMS, _RESYNC_PAYLOAD, _RESYNC_TOKEN)

    def _flush_stale(s, quiet=0.3, cap=3.0):
        """Discard bytes the BMC still holds from a PREVIOUS connection before this one
        sends anything. MEASURED 2026-10-05: after a sqrl_bridge session was stopped,
        the next connection's HELLO got a reply carrying txn 0x0000 and the load
        aborted on the txn check (the bridge's own log shows the mirror case,
        "Orphaned Transaction 0000"). Reads until `quiet` seconds pass with nothing
        arriving, at most `cap` seconds; no JTAG command has been sent yet and the
        shadow TAP is UNKNOWN, so nothing here can move the TAP. A fake transport
        without settimeout() is skipped."""
        s.flushed = 0
        if not hasattr(s.s, "settimeout"):
            return
        old = s.s.gettimeout() if hasattr(s.s, "gettimeout") else None
        t_end = time.monotonic() + cap
        try:
            s.s.settimeout(quiet)
            while time.monotonic() < t_end:
                try:
                    c = s.s.recv(4096)
                except socket.timeout:
                    break
                if not c:
                    s._poison("the BMC closed the connection before the handshake")
                    raise ConnectionError("CoE closed")
                s.flushed += len(c)
        finally:
            s.s.settimeout(old)

    def start(s, hz=27_000_000):
        s._flush_stale()
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
