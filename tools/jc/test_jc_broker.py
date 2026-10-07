"""Tests for jc_broker.py (plan Task 6). No test opens a real socket: every CoE client is
built on CtlChainSock, a modelled two-die JTAG chain whose dies each run the USER4
loader model (for the DNA) and FakeCtlDie behind USER3 (for the control protocol). The
broker drives the REAL coe.CoE client and the REAL coe_load.CoeTransport over it."""
import collections, hashlib, json, os, socket, struct, sys, threading, time, zlib
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import coe, jc_ctl as C, jc_frame as F
from jc import coe_load as L
from jc import jc_broker as B
from jc.jc_model import LoaderModel
from jc.test_coe_load import ChainSock

NONE = C.RSP_SEQ_NONE
DNA_A = 0x0123456789ABCDEF01234567
DNA_B = 0x89ABCDEF0123456789ABCDEF
READ_OPS = (C.OP_RD_INC, C.OP_RD_FIX, C.OP_MEM_RD)


@pytest.fixture(autouse=True)
def _no_real_sockets(monkeypatch):
    def refuse(*a, **k):
        raise AssertionError("a test tried to open a real socket: %r" % (a,))
    monkeypatch.setattr(coe.socket, "create_connection", refuse)


# ---------------------------------------------------------------- the fake control core

def _ack_of(slot):
    """The ruling's header ack fields, decoded here independently of the broker's shim
    (jc_ctl.parse_header does not carry them yet): [215:184] ack_seq, [216] ack_valid."""
    v = int.from_bytes(slot[:32], "little")
    return (v >> 216) & 1, (v >> 184) & 0xFFFFFFFF


class FakeCtlDie:
    """The USER3 control core as the host sees it, on jc_ctl's frame model: a slot is
    received (magic and bounds -> desync, CRC -> crc_fail, else queued), executed `lag`
    slot times later against a dict register file or this die's seeded HBM, and the
    TDO of every slot is the status word and response buffer latched at the slot's
    start.

    Host-driven ack (Ruling 2026-10-07): a response is presented in every TDO until a
    PASS frame (any op, NOP included) carries ack_valid=1 and ack_seq == rsp_seq; a
    read waits for that ack before it executes. rsp_crc ([212:181]) is CRC-32 over the
    rsp_count words; with no valid response the region and rsp_crc are zero.

    Contract the broker relies on, modelled here: a NOP is a status poll; apart from its
    ack it never touches last_done_seq, rsp_seq or the error bits. axi_err is sticky until
    the next non-NOP frame executes. `fifos[off]` makes off a FIFO window for reads.

    Injections: `flip_rsp` corrupts response word 0 in that many TDOs that present a
    response; `ghost` makes the next that-many TDOs after a read frame arrives present
    a CRC-correct response of a seq nobody issued. Records: `frames` (every execution),
    `acks`, `reads_over_unacked` (read frames that arrived while a response was still
    presented, which the broker must never cause)."""
    def __init__(s, seed, lag=1, slverr=(), fifos=None):
        s.seed, s.lag, s.slverr = seed, lag, set(slverr)
        s.regs = {}
        s.fifos = {k: list(v) for k, v in (fifos or {}).items()}
        s.wlog = collections.defaultdict(list)       # off -> every value written there
        s.frames = []                                # (seq, op) of every PASS non-NOP frame
        s.last_done, s.rsp_seq, s.rsp_count, s.rsp_valid = NONE, NONE, 0, 0
        s.rsp = [0] * C.MAX_ITEMS
        s.axi_err = s.axi_resp = s.err_seq = 0
        s.desync = s.crc_fail = s.ovf = 0
        s.q, s.nslot = [], 0
        s.stall = False
        s.acks = s.reads_over_unacked = 0
        s.flip_rsp = s.ghost = s.ghost_left = 0

    def hbm(s, addr):
        return hashlib.blake2b(b"%d:%d" % (s.seed, addr), digest_size=32).digest()

    def latch(s):
        valid, seq, cnt, words = s.rsp_valid, s.rsp_seq, s.rsp_count, s.rsp
        if s.ghost_left:
            s.ghost_left -= 1
            valid, seq, cnt, words = 1, 0x0BADBEEF, s.rsp_count or 1, [0xBAD0BAD0] * C.MAX_ITEMS
        if valid:
            data = b"".join(struct.pack("<I", w) for w in words[:cnt])
            crc = zlib.crc32(data) & 0xFFFFFFFF
            rsp = b"".join(struct.pack("<I", w) for w in words)
        else:
            crc, rsp = 0, bytes(C.RSP_BUF_BYTES)
        v = (C.STAT_MAGIC | s.last_done << 32 | seq << 64 | cnt << 96
             | valid << 112 | s.axi_err << 113 | s.axi_resp << 114
             | s.err_seq << 116 | s.desync << 148 | s.ovf << 164 | s.crc_fail << 165
             | crc << 181)
        st = v.to_bytes(C.STATUS_BYTES, "little")
        tdo = int.from_bytes((st + rsp).ljust(C.SLOT_BYTES, b"\0"), "little")
        if valid and s.flip_rsp:
            s.flip_rsp -= 1
            tdo ^= 1 << (C.STATUS_BITS + 5)               # one bit of response word 0
        return tdo

    def end_slot(s, slot):
        s.nslot += 1
        s._exec()
        h = C.parse_header(slot)
        if (h["magic"] != C.MAGIC or not 1 <= h["count"] <= C.MAX_ITEMS
                or h["nwords"] > C.MAX_PAYLOAD_WORDS):
            s.desync += 1
            return
        if not C.slot_crc_ok(slot):
            s.crc_fail += 1
            return
        if h["op"] in READ_OPS:
            # judged BEFORE this frame's own ack: read B riding on the frame that acks
            # read A still went out before A was acked
            s.reads_over_unacked += s.rsp_valid
            s.ghost_left = s.ghost
        av, aseq = _ack_of(slot)
        if av and s.rsp_valid and aseq == s.rsp_seq:
            s.rsp_valid = 0                               # rsp_ack (host-driven)
            s.acks += 1
        s.q.append((s.nslot, h, slot))

    def _exec(s):
        while s.q and not s.stall and s.nslot - s.q[0][0] >= s.lag:
            _, h, slot = s.q[0]
            op, seq, addr, n = h["op"], h["seq"], h["addr"], h["count"]
            if op in READ_OPS and s.rsp_valid:
                return                                    # waits for rsp_ack
            s.q.pop(0)
            if op == C.OP_NOP:
                continue
            s.frames.append((seq, op))
            s.axi_err = 0
            if op in C.WRITE_OPS:
                items = [int.from_bytes(slot[32 + 4 * i:36 + 4 * i], "little") for i in range(n)]
                for i, val in enumerate(items):
                    off = addr if op == C.OP_WR_FIX else addr + 4 * i
                    if off in s.slverr:
                        s._err(seq)
                        continue
                    s.regs[off] = val
                    s.wlog[off].append(val)
            else:
                out = []
                if op == C.OP_MEM_RD:
                    for w in range(n // 8):
                        word = s.hbm(addr + 32 * w)
                        out += [int.from_bytes(word[4 * i:4 * i + 4], "little") for i in range(8)]
                else:
                    for i in range(n):
                        off = addr if op == C.OP_RD_FIX else addr + 4 * i
                        if off in s.slverr:
                            s._err(seq)
                            out.append(0)
                        elif off in s.fifos:
                            out.append(s.fifos[off].pop(0))
                        else:
                            out.append(s.regs.get(off, 0))
                s.rsp = out + [0] * (C.MAX_ITEMS - len(out))
                s.rsp_seq, s.rsp_count, s.rsp_valid = seq, n, 1
            s.last_done = seq

    def _err(s, seq):
        if not s.axi_err:
            s.axi_err, s.axi_resp, s.err_seq = 1, 2, seq


class CtlChainSock(ChainSock):
    """ChainSock (USER4 loader per die, real TAP and IR model) plus, on each die, a
    USER3 receiver in front of a FakeCtlDie: Capture-DR resets its bit counter and
    latches the status; every 16,384 bits is one slot; the TDO shifts out LSB first.
    `board` carries what must persist across connections: the dies, the TAP state,
    the frame-corruption and link-drop injections."""
    def __init__(s, board):
        ChainSock.__init__(s, board.models[0], 0, other=board.models[1], start=board.tap)
        s.board = board
        s.ctl = board.ctl
        s.cbit, s.cacc, s.csr = [0, 0], [0, 0], [0, 0]
        s.ntdi_conn = 0
        s.eof = False

    def _ctl_capture(s, d):
        s.cbit[d], s.cacc[d] = 0, 0
        s.csr[d] = s.ctl[d].latch()

    def _clock(s, tms, tdi):
        if s.state == coe.CAPTURE_DR:
            for d in range(2):
                if s.ir[d] == coe.IR_USER3:
                    s._ctl_capture(d)
        ChainSock._clock(s, tms, tdi)
        s.board.tap = s.state

    def _dev(s, d, n, x, tdi_cmd=False):
        if s.ir[d] == coe.IR_USER3:
            return s._ctl_core(d, n, x)
        return ChainSock._dev(s, d, n, x, tdi_cmd)

    def _ctl_core(s, d, n, x):
        out, i = 0, 0
        while i < n:
            take = min(n - i, C.SLOT_BITS - s.cbit[d])
            out |= (s.csr[d] & ((1 << take) - 1)) << i
            s.csr[d] >>= take
            s.cacc[d] |= ((x >> i) & ((1 << take) - 1)) << s.cbit[d]
            s.cbit[d] += take
            i += take
            if s.cbit[d] == C.SLOT_BITS:
                slot = s.cacc[d].to_bytes(C.SLOT_BYTES, "little")
                h = C.parse_header(slot)
                if h["magic"] == C.MAGIC and h["op"] != C.OP_NOP:
                    k = s.board.nframes
                    s.board.nframes += 1
                    s.board.wire_ops.append((d, h["seq"], h["op"]))
                    if k in s.board.flip:
                        b = bytearray(slot); b[100] ^= 1; slot = bytes(b)
                elif h["magic"] == C.MAGIC:
                    k = s.board.nnops
                    s.board.nnops += 1
                    if k in s.board.flip_nops:
                        b = bytearray(slot); b[100] ^= 1; slot = bytes(b)
                    elif _ack_of(slot)[0]:
                        k = s.board.nacknops
                        s.board.nacknops += 1
                        if k in s.board.flip_acknops:
                            b = bytearray(slot); b[100] ^= 1; slot = bytes(b)
                s.ctl[d].end_slot(slot)
                s.csr[d] = s.ctl[d].latch()
                s.cbit[d], s.cacc[d] = 0, 0
        return out

    def sendall(s, b):
        cmd = struct.unpack_from("<I", b, 4)[0]
        lose_reply = False
        if cmd == coe.CMD_TDI:
            drop = s.board.drop.get(s.board.nconn)
            if drop is not None and s.ntdi_conn >= drop:
                raise ConnectionResetError("fake BMC: connection reset")
            lr = s.board.drop_reply.get(s.board.nconn)
            lose_reply = lr is not None and s.ntdi_conn >= lr
            s.ntdi_conn += 1
        ChainSock.sendall(s, b)
        s.board.tap = s.state
        if lose_reply:                     # shifted, but the reply never arrives
            s.q, s.eof = b"", True

    def recv(s, n):
        if s.eof:
            return b""
        return ChainSock.recv(s, n)


class Board:
    """Two dies on chain AB, persisting across connections. connect() is the broker's
    dial: each call is one new BMC connection (a new CtlChainSock, the TAP where the
    last one left it). `drop[n]` resets connection n after that many CMD_TDI."""
    def __init__(s, lag=1, **ctl_kw):
        s.models = [LoaderModel(dna=DNA_A), LoaderModel(dna=DNA_B)]
        s.ctl = [FakeCtlDie(seed=1, lag=lag, **ctl_kw), FakeCtlDie(seed=2, lag=lag)]
        s.tap = coe.TEST_LOGIC_RESET
        s.flip, s.drop, s.drop_reply, s.flip_acknops = set(), {}, {}, set()
        s.flip_nops = set()
        s.nframes, s.nconn, s.nacknops, s.nnops = 0, 0, 0, 0
        s.wire_ops = []
        s.socks, s.clients = [], []
        s.on_connect = None

    def connect(s):
        s.nconn += 1
        if s.on_connect is not None:
            s.on_connect(s, s.nconn)
        sock = CtlChainSock(s)
        s.socks.append(sock)
        c = coe.CoE(None, sock=sock)
        s.clients.append(c)
        return c

    def violations(s):
        return [v for k in s.socks for v in k.violations]


class Clock:
    def __init__(s):
        s.t = 1000.0
    def __call__(s):
        return s.t


def make(board=None, **kw):
    board = board or Board()
    clock = Clock()
    kw.setdefault("now", clock)
    kw.setdefault("sleep", lambda secs: None)
    b = B.Broker(board.connect, "AB", {"A": DNA_A, "B": DNA_B}, **kw)
    return b, board, clock


def ok(r):
    assert r.get("ok") is True, r
    return r


# ---------------------------------------------------------------- the brief's cases

def test_rd32_wr32_round_trip():
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0xE010, "val": 0xDEADBEEF}))
    assert board.ctl[0].regs == {0xE010: 0xDEADBEEF} and board.ctl[1].regs == {}
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0xE010}))["val"] == 0xDEADBEEF
    ok(b.handle({"die": "B", "op": "wr32", "off": 0xE010, "val": 7}))
    assert ok(b.handle({"die": "B", "op": "rd32", "off": 0xE010}))["val"] == 7
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0xE010}))["val"] == 0xDEADBEEF
    assert board.violations() == []
    assert all(v in coe.IR_ALLOW for k in board.socks for u in k.ir_updates for v in u)
    assert b.connections == 1


def test_wrn_5120_to_a_fixed_window_is_11_slots_in_order():
    b, board, _ = make()
    vals = [(0x9E3779B9 * i) & 0xFFFFFFFF for i in range(5120)]
    ok(b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": vals}))
    die = board.ctl[0]
    assert die.wlog[0xE008] == vals and list(die.wlog) == [0xE008]
    assert [op for _, op in die.frames] == [C.OP_WR_FIX] * 11
    assert len([1 for d, _, _ in board.wire_ops if d == 0]) == 11
    seqs = [q for q, _ in die.frames]
    assert seqs == sorted(seqs) and len(set(seqs)) == 11


def test_wrn_incrementing_lands_at_consecutive_offsets():
    b, board, _ = make()
    vals = list(range(1000, 1000 + 600))
    ok(b.handle({"die": "B", "op": "wrn", "off": 0x100, "fix": False, "vals": vals}))
    assert [board.ctl[1].regs[0x100 + 4 * i] for i in range(600)] == vals
    assert [op for _, op in board.ctl[1].frames] == [C.OP_WR_INC] * 2


def test_rdn_5120_from_a_fixed_window():
    src = [(0x85EBCA6B * i + 3) & 0xFFFFFFFF for i in range(5120)]
    b, board, _ = make(Board(fifos={0xE00C: src}))
    r = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 5120}))
    assert r["vals"] == src
    assert [op for _, op in board.ctl[0].frames] == [C.OP_RD_FIX] * 11


def test_rdn_incrementing():
    b, board, _ = make()
    board.ctl[1].regs.update({0x200 + 4 * i: i * 3 for i in range(700)})
    r = ok(b.handle({"die": "B", "op": "rdn", "off": 0x200, "fix": False, "n": 700}))
    assert r["vals"] == [i * 3 for i in range(700)]


def test_a_second_client_is_refused():
    b, board, _ = make()
    srv = B.Server(b)
    a1, c1 = socket.socketpair()
    a2, c2 = socket.socketpair()
    c2.settimeout(5)                                     # a served c2 fails, never hangs
    assert srv.offer(a1) is True
    assert srv.offer(a2) is False
    line = c2.makefile("rb").readline()
    r = json.loads(line)
    assert r["ok"] is False and r["err"].startswith("Busy:")
    assert c2.recv(10) == b""                            # and closed
    c1.sendall(b'{"die":"A","op":"wr32","off":16,"val":5}\n{"op":"status"}\n')
    srv.pump()
    f = c1.makefile("rb")
    assert json.loads(f.readline()) == {"ok": True}
    assert json.loads(f.readline())["ok"] is True
    f.close()
    c1.close()
    srv.pump()                                           # EOF: the client is gone
    assert srv.client is None
    a3, c3 = socket.socketpair()
    assert srv.offer(a3) is True                         # the next client is served


def test_axi_err_is_returned_as_ok_false():
    b, board, _ = make(Board(slverr={0xE0F0}))
    r = b.handle({"die": "A", "op": "wr32", "off": 0xE0F0, "val": 1})
    assert r["ok"] is False and r["err"].startswith("AxiError:"), r
    r = b.handle({"die": "A", "op": "rd32", "off": 0xE0F0})
    assert r["ok"] is False and r["err"].startswith("AxiError:"), r
    # a later op on a good address still runs (the error is per frame, not a halt)
    ok(b.handle({"die": "A", "op": "wr32", "off": 0xE000, "val": 2}))
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0xE000}))["val"] == 2


def test_dna_swap_after_a_reconnect_aborts_the_next_request():
    b, board, clock = make(reconnect_secs=270)
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 1}))
    ok(b.handle({"die": "B", "op": "wr32", "off": 0x10, "val": 2}))
    def swap(bd, n):
        if n == 2:
            bd.models[0].dna, bd.models[1].dna = bd.models[1].dna, bd.models[0].dna
    board.on_connect = swap
    clock.t += 280                                       # past --reconnect-secs: rotate
    before = [list(d.frames) for d in board.ctl]
    r = b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 99})
    assert r["ok"] is False and "die identity mismatch" in r["err"], r
    assert board.nconn == 2
    assert [list(d.frames) for d in board.ctl] == before  # nothing reached either die
    r = b.handle({"die": "B", "op": "rd32", "off": 0x10})
    assert r["ok"] is False and r["err"].startswith("Halted:"), r
    assert board.nconn == 2                               # halted: no further dial
    st = b.handle({"op": "status"})
    assert st["ok"] is True and "identity mismatch" in st["halted"]


def test_dna_is_rechecked_after_a_reactive_reconnect_too():
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 1}))
    def swap(bd, n):
        if n == 2:
            bd.models[0].dna, bd.models[1].dna = bd.models[1].dna, bd.models[0].dna
    board.on_connect = swap
    board.drop[1] = board.socks[0].ntdi_conn             # the next CMD_TDI resets the link
    r = b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 2})
    assert r["ok"] is False and "die identity mismatch" in r["err"], r
    assert board.ctl[0].regs[0x10] == 1


def test_a_crc_fail_on_one_slot_is_retried_exactly_once_and_succeeds():
    b, board, _ = make()
    vals = list(range(5120))
    board.flip = {3}                                     # the 4th op frame on the wire
    ok(b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": vals}))
    die = board.ctl[0]
    assert die.crc_fail == 1 and b.crc_retries == 1
    assert die.wlog[0xE008] == vals                       # order preserved, nothing twice
    assert len(die.frames) == 11 and board.nframes == 12


def test_a_corrupted_poll_behind_a_good_frame_is_not_a_lost_frame():
    """The write frame passes; the NOP poll right behind it fails CRC, and with an
    executor lag of 3 slots the moved crc_fail shows BEFORE the write completes. The
    broker must keep polling (LOSS_POLLS) and see it done, not resend it: a resend
    would write the fixed window twice."""
    b, board, _ = make(Board(lag=3))
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    board.flip_nops = {board.nnops}                       # the first poll after the frame
    ok(b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": [1, 2, 3]}))
    die = board.ctl[0]
    assert die.crc_fail == 1 and b.crc_retries == 0
    assert die.wlog[0xE008] == [1, 2, 3]


def test_a_slot_that_fails_twice_is_not_retried_again():
    b, board, _ = make()
    board.flip = {0, 1}
    r = b.handle({"die": "A", "op": "wr32", "off": 0x40, "val": 3})
    assert r["ok"] is False and r["err"].startswith("FrameLost:"), r
    assert board.nframes == 2 and board.ctl[0].crc_fail == 2 and 0x40 not in board.ctl[0].regs


def test_a_crc_fail_on_a_read_is_retried():
    b, board, _ = make()
    board.ctl[0].regs[0x80] = 0x1234
    board.flip = {0}
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0x80}))["val"] == 0x1234
    assert b.crc_retries == 1


def test_ir_not_allowed_is_never_retried():
    board = Board()
    calls = []
    def connect():
        c = board.connect()
        def refuse(ops):
            calls.append(list(ops))
            raise coe.IRNotAllowed("refused by test")
        c.ir_scan = refuse
        return c
    b = B.Broker(connect, "AB", {"A": DNA_A, "B": DNA_B}, now=Clock(), sleep=lambda x: None)
    r = b.handle({"die": "A", "op": "rd32", "off": 0})
    assert r["ok"] is False and r["err"].startswith("IRNotAllowed:"), r
    assert len(calls) == 1 and board.nconn == 1 and b.crc_retries == 0
    r = b.handle({"die": "A", "op": "rd32", "off": 0})
    assert r["err"].startswith("Halted:") and len(calls) == 1 and board.nconn == 1


# ---------------------------------------------------------------- beyond the brief

def test_reads_match_by_rsp_seq_never_by_position():
    """After the read goes out, the TDO presents a CRC-correct response of another seq
    for three slots before the read's own. The broker must skip it; one that took the
    first valid response would return 0xBAD0BAD0."""
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x30, "val": 0xAAAA5555}))
    board.ctl[0].ghost = 3
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0x30}))["val"] == 0xAAAA5555


def test_a_response_left_presented_is_released_before_the_next_read():
    """A response nobody here accepted (an earlier broker's, say) holds the buffer: the
    broker acks it to release it, counts it, and only then sends its read."""
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x30, "val": 0x600D}))
    die = board.ctl[0]
    die.rsp_valid, die.rsp_seq, die.rsp_count = 1, 0x7777, 1
    die.rsp = [0xBAD0BAD0] + [0] * (C.MAX_ITEMS - 1)
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0x30}))["val"] == 0x600D
    assert b.discarded == 1 and die.acks == 1


def test_a_response_left_presented_is_released_before_the_next_read_when_seen():
    """The same, with the broker's last status already showing it: released BEFORE the
    read frame goes out."""
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x30, "val": 0x600D}))
    die = board.ctl[0]
    die.rsp_valid, die.rsp_seq, die.rsp_count = 1, 0x7777, 1
    die.rsp = [0xBAD0BAD0] + [0] * (C.MAX_ITEMS - 1)
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x34, "val": 1}))   # the broker sees it
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0x30}))["val"] == 0x600D
    assert b.discarded == 1 and die.reads_over_unacked == 0


# ---------------------------------------------------------------- ack and response CRC

def test_a_tdo_flip_in_the_response_region_is_repolled_then_accepted():
    src = list(range(0xA000, 0xA000 + 40))
    b, board, _ = make(Board(fifos={0xE00C: src}))
    die = board.ctl[0]
    die.flip_rsp = 2                                      # the first two presentations
    r = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 10}))
    assert r["vals"] == src[:10]
    assert b.rsp_crc_mismatches == 2 and die.flip_rsp == 0
    assert die.frames == [(die.frames[0][0], C.OP_RD_FIX)]   # executed exactly once
    assert die.fifos[0xE00C] == src[10:]
    assert ok(b.handle({"op": "status"}))["rsp_crc_mismatches"] == 2


def test_a_response_crc_that_never_checks_is_bounded():
    b, board, _ = make()
    board.ctl[0].flip_rsp = 10 ** 6
    r = b.handle({"die": "A", "op": "rd32", "off": 0})
    assert r["ok"] is False and "CRC mismatched" in r["err"], r
    assert b.rsp_crc_mismatches == B.RSP_CRC_RETRIES + 1
    assert board.ctl[0].acks == 0                         # a bad response is never acked


def _drop_cases():
    return [(kind, extra) for kind in ("drop", "drop_reply") for extra in range(0, 8)]

@pytest.mark.parametrize("kind,extra", _drop_cases())
def test_a_drop_around_a_response_accepts_it_once_and_reads_the_window_once(kind, extra):
    """A CoE drop anywhere from the read frame to past its ack (send side: the command
    never reaches the board; reply side: it is shifted but its TDO is lost). The
    window read (a FIFO: every execution pops) runs exactly once per frame and the
    caller gets every value exactly once, in order."""
    src = [(0x01000193 * i) & 0xFFFFFFFF for i in range(1, 1201)]
    b, board, _ = make(Board(fifos={0xE00C: src}))
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    getattr(board, kind)[1] = board.socks[0].ntdi_conn + extra
    r = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 600}))
    die = board.ctl[0]
    assert r["vals"] == src[:600]
    assert die.fifos[0xE00C] == src[600:]
    assert [op for _, op in die.frames] == [C.OP_RD_INC, C.OP_RD_FIX, C.OP_RD_FIX]
    assert board.nconn == 2 and b.reconnects == 1
    assert die.reads_over_unacked == 0
    r = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 600}))
    assert r["vals"] == src[600:] and die.fifos[0xE00C] == []


def test_a_drop_right_after_the_response_is_received_still_acks_it_on_the_next_link():
    """The TDO carrying the response arrives and is accepted; the very next CMD_TDI
    (the frame that would carry the ack) is reset. The ack goes out on the new
    connection and the next read follows it."""
    b, board, _ = make()
    die = board.ctl[0]
    die.regs.update({0x40: 11, 0x44: 22})
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0x40}))["val"] == 11
    board.drop[1] = board.socks[0].ntdi_conn
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0x44}))["val"] == 22
    # conn 1 died on the frame after the first response: its ack went out on conn 2
    assert board.nconn == 2 and die.acks == 1 and die.reads_over_unacked == 0
    assert die.rsp_valid == 1 and len(die.frames) == 2      # the second ack is owed
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x48, "val": 0}))
    assert die.acks == 2 and die.rsp_valid == 0


def test_read_b_never_goes_out_before_read_a_is_acked():
    """Back-to-back reads on one die, with the first two ack-carrying NOPs corrupted so
    the release of each response is delayed: every read frame reaches the die with no
    response still presented."""
    b, board, _ = make()
    die = board.ctl[1]
    die.regs.update({4 * i: i + 100 for i in range(8)})
    board.flip_acknops = {0, 1, 5}
    for i in range(8):
        assert ok(b.handle({"die": "B", "op": "rd32", "off": 4 * i}))["val"] == i + 100
    r = ok(b.handle({"die": "B", "op": "rdn", "off": 0, "fix": False, "n": 1000}))
    assert r["vals"][:8] == [i + 100 for i in range(8)]
    assert die.reads_over_unacked == 0 and die.crc_fail == 3
    assert die.acks == 8 + 3 - 1 and die.rsp_valid == 1   # the last one is still owed


def test_a_reactive_reconnect_inside_a_write_resumes_without_a_double_write():
    """The link resets part-way through an 11-slot fixed-window write. The broker
    reconnects, re-identifies the die, and continues from the die's own last_done_seq:
    the window sees every value exactly once, in order."""
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    board.drop[1] = board.socks[0].ntdi_conn + 9          # mid-request
    vals = [i ^ 0x5A5A for i in range(5120)]
    ok(b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": vals}))
    assert board.nconn == 2 and b.reconnects == 1
    assert board.ctl[0].wlog[0xE008] == vals
    assert board.violations() == []


@pytest.mark.parametrize("extra", range(0, 6))
def test_a_reset_at_any_point_of_a_slot_wait_loses_and_doubles_nothing(extra):
    b, board, _ = make()
    ok(b.handle({"die": "B", "op": "rd32", "off": 0}))
    board.drop[1] = board.socks[0].ntdi_conn + extra
    vals = list(range(1, 1001))
    ok(b.handle({"die": "B", "op": "wrn", "off": 0xE008, "fix": True, "vals": vals}))
    assert board.ctl[1].wlog[0xE008] == vals


def test_the_link_is_given_up_after_bounded_attempts():
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    for n in range(1, 40):
        board.drop[n] = 0 if n > 1 else board.socks[0].ntdi_conn
    r = b.handle({"die": "A", "op": "rd32", "off": 0})
    assert r["ok"] is False and r["err"].startswith("LinkLost:"), r
    assert board.nconn <= 1 + B.LINK_RETRIES + 1


def test_proactive_rotation_reconnects_and_reidentifies():
    b, board, clock = make(reconnect_secs=270)
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 1}))
    clock.t += 100
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x14, "val": 2}))
    assert board.nconn == 1
    clock.t += 171
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x18, "val": 3}))
    assert board.nconn == 2 and b.connections == 2
    assert board.socks[0].closed and not board.socks[1].closed
    assert board.clients[0].tap == coe.RUN_TEST_IDLE and board.clients[0].outstanding == []
    assert board.ctl[0].regs == {0x10: 1, 0x14: 2, 0x18: 3}


def test_a_poll_timeout_raises_and_is_bounded():
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    board.ctl[0].stall = True
    n0 = board.socks[0].ntdi_conn
    r = b.handle({"die": "A", "op": "wr32", "off": 4, "val": 1})
    assert r["ok"] is False and r["err"].startswith("CtlTimeout:"), r
    assert board.socks[0].ntdi_conn - n0 <= B.CTL_POLLS + 2


def test_memrd_reads_seeded_hbm_and_is_unaligned_safe():
    b, board, _ = make(allow_image_read=True)
    addr, n = 0x1_0000_0010, 100
    r = ok(b.handle({"die": "B", "op": "memrd", "addr": addr, "n": n}))
    lo = addr - addr % 32
    want = b"".join(board.ctl[1].hbm(a) for a in range(lo, addr + n + 32, 32))
    assert bytes.fromhex(r["hex"]) == want[addr - lo:addr - lo + n]
    r = ok(b.handle({"die": "B", "op": "memrd", "addr": 0x2000, "n": 4096}))
    want = b"".join(board.ctl[1].hbm(a) for a in range(0x2000, 0x3000, 32))
    assert bytes.fromhex(r["hex"]) == want
    assert [op for _, op in board.ctl[1].frames] == [C.OP_MEM_RD] * 4


def _manifest(tmp_path, arena_base=0x1FFADD000, arena_bytes=159744):
    m = dict(format="test", hbm=dict(desc_arena_base=arena_base, desc_arena_bytes=arena_bytes),
             files=[dict(file="w0.bin", nbytes=0x10000, hbm_offset=0x0),
                    dict(file="w1.bin", nbytes=0x8000, hbm_offset=0x1_0000_0000,
                         pieces=[dict(hbm_offset=0x1_0000_0000, nbytes=0x1000, file_offset=0),
                                 dict(hbm_offset=0x1_1000_0000, nbytes=0x7000, file_offset=0x1000)])])
    p = tmp_path / "manifest.json"
    p.write_text(json.dumps(m))
    return str(p)


def test_memrd_refuses_the_weight_image_but_allows_the_image_record(tmp_path):
    fence = B.load_fence(_manifest(tmp_path))
    rec = 0x1FFADD000 + 159744 - 512
    assert fence.record == (rec, rec + 512)
    b, board, _ = make(fences={"A": fence, "B": fence})
    for addr, n in [(0x0, 32), (0xFFE0, 64), (0x1_1000_6FE0, 32), (0x1_0000_0FFF, 2)]:
        r = b.handle({"die": "A", "op": "memrd", "addr": addr, "n": n})
        assert r["ok"] is False and r["err"].startswith("Refused:"), (hex(addr), r)
    assert board.ctl[0].frames == []
    r = ok(b.handle({"die": "A", "op": "memrd", "addr": rec, "n": 512}))
    assert bytes.fromhex(r["hex"]) == b"".join(board.ctl[0].hbm(a) for a in range(rec, rec + 512, 32))
    ok(b.handle({"die": "A", "op": "memrd", "addr": 0x10000, "n": 32}))       # just past w0
    ok(b.handle({"die": "A", "op": "memrd", "addr": 0x1_0000_1000, "n": 32})) # between pieces
    b2, _, _ = make(fences={"A": fence}, allow_image_read=True)
    ok(b2.handle({"die": "A", "op": "memrd", "addr": 0x0, "n": 32}))


def test_memrd_without_a_manifest_is_refused_unless_allowed():
    b, board, _ = make()
    r = b.handle({"die": "A", "op": "memrd", "addr": 0x1000, "n": 32})
    assert r["ok"] is False and r["err"].startswith("Refused:"), r


def test_bad_requests_are_ok_false_and_touch_nothing():
    b, board, _ = make()
    for req in [{"die": "C", "op": "rd32", "off": 0}, {"die": "A", "op": "rd32", "off": 2},
                {"die": "A", "op": "rd32"}, {"die": "A", "op": "wr32", "off": 0, "val": -1},
                {"die": "A", "op": "wr32", "off": 0, "val": 1 << 32},
                {"die": "A", "op": "rdn", "off": 0, "fix": False, "n": 0},
                {"die": "A", "op": "wrn", "off": 0, "fix": "yes", "vals": [1]},
                {"die": "A", "op": "wrn", "off": 0, "fix": False, "vals": []},
                {"die": "A", "op": "rd32", "off": True},
                {"die": "A", "op": "frob"}, ["not", "an", "object"]]:
        r = b.handle(req)
        assert r["ok"] is False and ": " in r["err"], (req, r)
    assert board.nconn == 0


def test_status_reports_dies_and_connections_without_touching_the_board():
    b, board, _ = make()
    st = ok(b.handle({"op": "status"}))
    assert st["connections"] == 0 and set(st["dies"]) == {"A", "B"} and board.nconn == 0
    ok(b.handle({"die": "B", "op": "wr32", "off": 0, "val": 0}))
    st = ok(b.handle({"op": "status"}))
    assert st["connections"] == 1
    assert st["dies"]["B"]["identified"] is True and st["dies"]["A"]["identified"] is False
    assert DNA_A.__format__("024x") not in json.dumps(st)  # DNA masked, never printed whole


def test_the_serve_loop_over_a_unix_socket(tmp_path):
    b, board, _ = make()
    path = str(tmp_path / "b.sock")
    lst = B.listen(path)
    srv = B.Server(b)
    stop = threading.Event()
    th = threading.Thread(target=srv.serve, args=(lst, stop.is_set, 0.05))
    th.start()
    try:
        c1 = socket.socket(socket.AF_UNIX); c1.connect(path)
        f1 = c1.makefile("rwb")
        f1.write(b'{"die":"A","op":"wr32","off":8,"val":9}\n'); f1.flush()
        assert json.loads(f1.readline()) == {"ok": True}
        c2 = socket.socket(socket.AF_UNIX); c2.connect(path)
        assert json.loads(c2.makefile("rb").readline())["err"].startswith("Busy:")
        f1.write(b'{"die":"A","op":"rd32","off":8}\n'); f1.flush()
        assert json.loads(f1.readline()) == {"ok": True, "val": 9}
        f1.write(b'not json\n'); f1.flush()
        assert json.loads(f1.readline())["ok"] is False
    finally:
        stop.set()
        th.join(5)
    assert oct(os.stat(path).st_mode & 0o777) == "0o600"


def test_cli_requires_the_bmc_address_and_has_no_default(tmp_path):
    with pytest.raises(SystemExit) as e:
        B.main(["serve", "--chain", "AB", "--dies", str(tmp_path / "d.json"),
                "--sock", str(tmp_path / "s")])
    assert e.value.code == 2
    import re
    ips = set(re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", open(B.__file__).read()))
    assert ips <= {"192.0.2.1"}, ips
