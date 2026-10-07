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

    Status word as the RTL sends it (Ruling 2026-10-07, after the Task 6 review):
    [383:352] st_crc over bits [351:0] as shifted; [351:213] zero. STALE mask: once a
    response is acked, the status shows that rsp_seq with rsp_valid = 0, rsp_count = 0,
    rsp_crc = 0 and no words. crc_fail and desync are the frame core's: they move at the
    end of the failing slot and show from the next slot's status on, no lag. EXEC
    fields move `lag` (0..16) slot times after the frame passed, plus `bp[off]` more
    for a fixed-window op at `off` (window backpressure).

    Injections: `flip_rsp` corrupts response word 0 in that many TDOs that present a
    response; `flip_st` corrupts status bit `flip_st_bit` in that many TDOs (st_crc
    then fails); `fake_done` makes that many TDOs after an op frame arrives show
    last_done_seq = its seq with a st_crc that does NOT cover it; `ghost` makes the next
    that-many TDOs after a read frame arrives present a CRC-correct response of a seq
    nobody issued. Records: `frames` (every execution), `acks`, `reads_over_unacked`
    (read frames that arrived while a response was still presented, which the broker
    must never cause)."""
    def __init__(s, seed, lag=1, slverr=(), fifos=None, bp=None):
        s.seed, s.lag, s.slverr = seed, lag, set(slverr)
        s.bp = dict(bp or {})
        s.flip_st, s.flip_st_bit, s.fake_done, s.fake_seq = 0, 40, 0, None
        s.bad_count = 0
        s.reject_reads = 0          # force that many reads to be refused ("01")
        s.rejects = 0               # reads the executor refused, forced or by its rule
        s.clobber_tail = False      # re-presentations of a response lose words 492-495
        s.presented = collections.Counter()
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
        s.ghost_seq = 0x0BADBEEF

    def hbm(s, addr):
        return hashlib.blake2b(b"%d:%d" % (s.seed, addr), digest_size=32).digest()

    def latch(s):
        valid, seq, cnt, words = s.rsp_valid, s.rsp_seq, s.rsp_count, s.rsp
        if s.ghost_left:
            s.ghost_left -= 1
            valid, seq, cnt, words = 1, s.ghost_seq, s.rsp_count or 1, [0xBAD0BAD0] * C.MAX_ITEMS
        clobber = False
        if valid and not s.ghost_left_used(seq):
            s.presented[seq] += 1
            clobber = s.clobber_tail and s.presented[seq] > 1 and cnt > 492
        if valid and s.bad_count:
            s.bad_count -= 1
            cnt += 1                     # an executor glitch: self-consistent, wrong count
        if valid:
            data = b"".join(struct.pack("<I", w) for w in words[:cnt])
            crc = zlib.crc32(data) & 0xFFFFFFFF
            rsp = b"".join(struct.pack("<I", w) for w in words)
        else:
            cnt, crc, rsp = 0, 0, bytes(C.RSP_BUF_BYTES)      # the STALE mask
        v = (C.STAT_MAGIC | s.last_done << 32 | seq << 64 | cnt << 96
             | valid << 112 | s.axi_err << 113 | s.axi_resp << 114
             | s.err_seq << 116 | (s.desync & 0xFFFF) << 148 | s.ovf << 164
             | (s.crc_fail & 0xFFFF) << 165 | crc << 181)
        v |= (zlib.crc32(v.to_bytes(44, "little")) & 0xFFFFFFFF) << 352     # st_crc
        if s.fake_done and s.fake_seq is not None:
            s.fake_done -= 1
            v = (v & ~(0xFFFFFFFF << 32)) | s.fake_seq << 32  # st_crc no longer covers it
        st = v.to_bytes(C.STATUS_BYTES, "little")
        tdo = int.from_bytes((st + rsp).ljust(C.SLOT_BYTES, b"\0"), "little")
        if clobber:                       # the ack slot's tail overwritten by a MEM_RD
            for w in range(492, 496):
                tdo ^= 0xA5A5A5A5 << (C.STATUS_BITS + 32 * w)
        if valid and s.flip_rsp:
            s.flip_rsp -= 1
            tdo ^= 1 << (C.STATUS_BITS + 5)               # one bit of response word 0
        if s.flip_st:
            s.flip_st -= 1
            tdo ^= 1 << s.flip_st_bit
        return tdo

    def ghost_left_used(s, seq):
        return s.ghost_left > 0 or seq == s.ghost_seq

    def end_slot(s, slot, counted=False):
        """`counted`: the frame core already counted this slot as a desync at header
        bit 255 (bad magic or bounds); it is discarded."""
        s.nslot += 1
        s._exec()
        if not counted:
            s._rx(slot)
        s._exec()                                         # lag 0: runs at once

    def _rx(s, slot):
        h = C.parse_header(slot)
        if (h["magic"] != C.MAGIC or not 1 <= h["count"] <= C.MAX_ITEMS
                or h["nwords"] > C.MAX_PAYLOAD_WORDS):
            s.desync += 1
            return
        if not C.slot_crc_ok(slot):
            s.crc_fail += 1
            return
        if h["op"] != C.OP_NOP:
            s.fake_seq = h["seq"]
        if h["op"] in READ_OPS:
            # judged BEFORE this frame's own ack: read B riding on the frame that acks
            # read A still went out before A was acked
            s.reads_over_unacked += s.rsp_valid
            s.ghost_left = s.ghost
        av, aseq = _ack_of(slot)
        if av and s.rsp_valid and aseq == s.rsp_seq:
            s.rsp_valid = 0                               # rsp_ack (host-driven)
            s.acks += 1
        wait = s.lag + (s.bp.get(h["addr"], 0) if h["op"] in (C.OP_WR_FIX, C.OP_RD_FIX) else 0)
        s.q.append((s.nslot + wait, h, slot))

    def _exec(s):
        while s.q and not s.stall and s.nslot >= s.q[0][0]:
            _, h, slot = s.q[0]
            op, seq, addr, n = h["op"], h["seq"], h["addr"], h["count"]
            if op in READ_OPS and s.rsp_valid:
                return                                    # waits for rsp_ack
            s.q.pop(0)
            if op == C.OP_NOP:
                continue
            # Task 3 (rtl/jc_ctl_exec.vhd): every completed non-NOP frame sets
            # last_done_seq, errored or refused included; axi_err/axi_resp/err_seq
            # describe that frame (cleared to 0 / 0 / NONE when it did not error).
            s.axi_err, s.axi_resp, s.err_seq = 0, 0, NONE
            s.last_done = seq
            if op in READ_OPS and (seq == NONE or seq == s.rsp_seq or s.reject_reads):
                s.reject_reads = max(0, s.reject_reads - 1)
                s.rejects += 1
                s.axi_err, s.axi_resp, s.err_seq = 1, 1, seq      # "01": nothing ran
                continue
            s.frames.append((seq, op))
            if op in C.WRITE_OPS:
                items = [int.from_bytes(slot[32 + 4 * i:36 + 4 * i], "little") for i in range(n)]
                for i, val in enumerate(items):
                    off = addr if op == C.OP_WR_FIX else addr + 4 * i
                    if off in s.slverr:
                        s._err(seq)
                        break                             # the op stops at its first error
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
                            break                         # stops; publishes nothing
                        elif off in s.fifos:
                            out.append(s.fifos[off].pop(0))
                        else:
                            out.append(s.regs.get(off, 0))
                if s.axi_err:
                    continue
                s.rsp = out + [0] * (C.MAX_ITEMS - len(out))
                s.rsp_seq, s.rsp_count, s.rsp_valid = seq, n, 1

    def _err(s, seq):
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
        s.counted = [False, False]
        s.ntdi_conn = 0
        s.eof = False

    def _ctl_capture(s, d):
        s.cbit[d], s.cacc[d], s.counted[d] = 0, 0, False
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
            before = s.cbit[d]
            s.cbit[d] += take
            i += take
            if before < 256 <= s.cbit[d]:
                # rtl/jc_ctl_frame_core.vhd: magic and bounds are judged at header bit
                # 255; a bad header counts desync THEN, even if the slot is abandoned
                h = C.parse_header((s.cacc[d] & ((1 << 256) - 1)).to_bytes(32, "little"))
                bad = (h["magic"] != C.MAGIC or not 1 <= h["count"] <= C.MAX_ITEMS
                       or h["nwords"] > C.MAX_PAYLOAD_WORDS)
                if not bad and h["op"] != C.OP_NOP:
                    k = s.board.nhdr
                    s.board.nhdr += 1
                    bad = k in s.board.flip_magic
                if bad:
                    s.ctl[d].desync += 1
                    s.counted[d] = True
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
                s.ctl[d].end_slot(slot, s.counted[d])
                s.counted[d] = False
                s.csr[d] = s.ctl[d].latch()
                s.cbit[d], s.cacc[d] = 0, 0
        return out

    def sendall(s, b):
        cmd = struct.unpack_from("<I", b, 4)[0]
        lose_reply = False
        if cmd == coe.CMD_TDI:
            drop = s.board.drop.get(s.board.nconn)
            if (drop is not None and s.ntdi_conn >= drop) or s.board.drop_next:
                s.board.drop_next = False
                raise ConnectionResetError("fake BMC: connection reset")
            if s.board.drop_after_op is not None and len(b) >= 8 + 4 + 32:
                h = C.parse_header(b[12:12 + 32])
                if h["magic"] == C.MAGIC and h["op"] == s.board.drop_after_op:
                    s.board.drop_after_op, s.board.drop_next = None, True
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
        # ctl_kw (fifos, slverr, bp) configure die A; die B is plain
        s.models = [LoaderModel(dna=DNA_A), LoaderModel(dna=DNA_B)]
        s.ctl = [FakeCtlDie(seed=1, lag=lag, **ctl_kw), FakeCtlDie(seed=2, lag=lag)]
        s.tap = coe.TEST_LOGIC_RESET
        s.flip, s.drop, s.drop_reply, s.flip_acknops = set(), {}, {}, set()
        s.flip_nops = set()
        s.flip_magic, s.nhdr = set(), 0     # op frames (by header order) with a bad magic
        s.drop_after_op, s.drop_next = None, False   # reset the command after that op's frame
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
    assert r["ok"] is False and r["err"].startswith("WindowUnknown:") and "rsp_crc" in r["err"], r
    assert b.rsp_crc_mismatches == B.RSP_CRC_RETRIES + 1
    assert board.ctl[0].acks == 0                         # a bad response is never acked


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
    assert r["ok"] is False and r["err"].startswith("WindowUnknown:"), r
    assert "UNKNOWN" in ok(b.handle({"op": "status"}))["dies"]["A"]["window_state"]
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


# ---------------------------------------------------------------- fix round 1 (review of f7f0713)
# Ported from the reviewer's probes (scratchpad test_rev_t6.py, test_rev_t6b.py), with
# assertions added where the probe only printed.

def _rev_setup(extra_flip):
    src = list(range(100, 200))
    b, board, _ = make(Board(fifos={0xE00C: src}))
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 1}))
    n0 = board.socks[0].ntdi_conn
    board.drop[1] = n0 + 2                    # read frame n0, first poll n0+1, reset at n0+2
    def oc(bd, n):
        if n == 2:
            bd.ctl[0].flip_rsp = extra_flip
    board.on_connect = oc
    r = b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 4})
    return b, board, r, src

@pytest.mark.parametrize("extra_flip", [0, 3])
def test_rev_pending_read_with_corrupt_responses_executes_once(extra_flip):
    """C1: after a reconnect the read's response fails rsp_crc; it must be re-polled and
    accepted, never acked unaccepted and re-sent."""
    b, board, r, src = _rev_setup(extra_flip)
    assert r.get("vals") == src[:4], r
    assert [op for _, op in board.ctl[0].frames].count(C.OP_RD_FIX) == 1
    assert b.discarded == 0

def test_rev_deep_json_answers_ok_false():
    """M1: deeply nested JSON must not kill the broker."""
    b, board, _ = make()
    srv = B.Server(b)
    a1, c1 = socket.socketpair()
    c1.settimeout(5)
    srv.offer(a1)
    c1.sendall(b"[" * 200000 + b"\n")
    srv.pump()
    r = json.loads(c1.makefile("rb").readline())
    assert r["ok"] is False
    c1.sendall(b'{"op":"status"}\n')
    srv.pump()

@pytest.mark.parametrize("lag", [1, 10, 12])
@pytest.mark.parametrize("op", ["rd", "wr"])
def test_rev_corrupt_poll_behind_a_frame_never_doubles_it(op, lag):
    """I1: the first NOP after a frame fails CRC; the frame itself passed and executes
    `lag` slots later. It must run exactly once."""
    src = list(range(100, 200))
    b, board, _ = make(Board(lag=lag, fifos={0xE00C: src}))
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 1}))
    board.flip_nops = {board.nnops}
    die = board.ctl[0]
    if op == "rd":
        r = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 4}))
        r2 = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 4}))
        assert r["vals"] == src[:4] and r2["vals"] == src[4:8]
        assert [op_ for _, op_ in die.frames].count(C.OP_RD_FIX) == 2
    else:
        ok(b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": [7, 8]}))
        assert die.wlog[0xE008] == [7, 8]
    assert die.crc_fail == 1 and b.crc_retries == 0


# ---- link loss: exactly once, or UNKNOWN; never twice

def _window_write_under_drop(die_name, kind, extra, lag, n=1200):
    d = 0 if die_name == "A" else 1
    b, board, _ = make(Board(lag=lag))
    if d:
        board.ctl[1].lag = lag
    ok(b.handle({"die": die_name, "op": "rd32", "off": 0}))
    getattr(board, kind)[1] = board.socks[0].ntdi_conn + extra
    vals = [(0x9E3779B9 * (i + 1)) & 0xFFFFFFFF for i in range(n)]
    r = b.handle({"die": die_name, "op": "wrn", "off": 0xE008, "fix": True, "vals": vals})
    return r, b, board, vals, board.ctl[d]

DROPS = [(die, kind, extra) for die in "AB" for kind in ("drop", "drop_reply")
         for extra in range(0, 9)]

@pytest.mark.parametrize("lag", [0, 1, 10])
@pytest.mark.parametrize("die_name,kind,extra", DROPS)
def test_a_link_loss_in_a_window_write_is_exactly_once_or_unknown(die_name, kind, extra, lag):
    r, b, board, vals, die = _window_write_under_drop(die_name, kind, extra, lag)
    w = die.wlog[0xE008]
    assert w == vals[:len(w)], "a value was written twice or out of order"
    assert board.violations() == []
    if r["ok"]:
        assert w == vals
        assert ok(b.handle({"op": "status"}))["dies"][die_name]["window_state"] == "ok"
    else:
        assert r["err"].startswith("WindowUnknown:"), r
        assert len(w) % C.MAX_ITEMS == 0 or len(w) == len(vals)
        st = ok(b.handle({"op": "status"}))
        assert st["dies"][die_name]["window_state"].startswith("UNKNOWN")

@pytest.mark.parametrize("lag", [0, 1, 12])
@pytest.mark.parametrize("die_name,kind,extra", DROPS)
def test_a_link_loss_in_a_window_read_is_exactly_once_or_unknown(die_name, kind, extra, lag):
    """A FIFO window read (every execution pops) under a link loss anywhere from the
    read frame to past its ack: either the caller gets every value once in order and
    each frame ran once, or WindowUnknown with no frame run twice."""
    d = 0 if die_name == "A" else 1
    src = [(0x01000193 * i) & 0xFFFFFFFF for i in range(1, 1201)]
    board = Board(lag=lag)
    board.ctl[d] = FakeCtlDie(seed=d + 1, lag=lag, fifos={0xE00C: src})
    b, board, _ = make(board)
    ok(b.handle({"die": die_name, "op": "rd32", "off": 0}))
    getattr(board, kind)[1] = board.socks[0].ntdi_conn + extra
    r = b.handle({"die": die_name, "op": "rdn", "off": 0xE00C, "fix": True, "n": 600})
    die = board.ctl[d]
    seqs = [q for q, op in die.frames if op == C.OP_RD_FIX]
    assert len(seqs) == len(set(seqs)) <= 2
    assert die.reads_over_unacked == 0
    if r["ok"]:
        assert r["vals"] == src[:600] and len(seqs) == 2 and die.fifos[0xE00C] == src[600:]
        r2 = ok(b.handle({"die": die_name, "op": "rdn", "off": 0xE00C, "fix": True, "n": 600}))
        assert r2["vals"] == src[600:]
    else:
        assert r["err"].startswith("WindowUnknown:"), r

def test_a_link_loss_after_the_frames_own_verdict_resumes():
    """The frame's own slot and the first poll's status are both in hand (PASSED)
    before the link drops: the broker resumes on the new connection and completes."""
    for lag in (0, 1, 10):
        r, b, board, vals, die = _window_write_under_drop("A", "drop", 2, lag, n=10)
        assert r == {"ok": True} and die.wlog[0xE008] == vals, (lag, r)

def test_most_drop_points_resume():
    """Not a correctness property, a usefulness one: over the drop grid above, at least
    half of the window writes complete rather than end UNKNOWN."""
    okn = tot = 0
    for die_name, kind, extra in DROPS:
        r = _window_write_under_drop(die_name, kind, extra, 1)[0]
        tot += 1
        okn += r["ok"]
    assert okn * 2 >= tot, (okn, tot)


# ---- st_crc, the stale mask, lag and backpressure

def test_a_status_with_a_flipped_last_done_seq_is_rejected():
    """M4: the executor is stalled; a status claims last_done_seq == the frame's seq but
    its st_crc does not cover that. It must be rejected (counted), and the write must
    not be reported done."""
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    die = board.ctl[0]
    die.stall, die.fake_done = True, 5
    r = b.handle({"die": "A", "op": "wr32", "off": 0x20, "val": 5})
    assert r["ok"] is False and r["err"].startswith("WindowUnknown:"), r
    assert b.st_crc_fails >= 5 and 0x20 not in die.regs

@pytest.mark.parametrize("bit", [40, 70, 100, 113, 150, 170, 200])
def test_corrupted_status_fields_are_rejected_and_repolled(bit):
    """Corruption in last_done_seq, rsp_seq, rsp_count, axi_err, desync, crc_fail and
    rsp_crc: every such status is discarded; the ops still complete exactly once."""
    src = list(range(3000, 3600))
    b, board, _ = make(Board(fifos={0xE00C: src}))
    die = board.ctl[0]
    die.flip_st_bit = bit
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    die.flip_st = 3
    ok(b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": list(range(600))}))
    die.flip_st = 3
    r = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 600}))
    assert r["vals"] == src and die.wlog[0xE008] == list(range(600))
    assert b.st_crc_fails == 6 and b.crc_retries == 0

def test_the_stale_mask_after_an_ack():
    """After its ack the status shows the acked rsp_seq with rsp_valid=0 and count 0:
    that is not a response, and the next read proceeds."""
    b, board, _ = make()
    die = board.ctl[0]
    die.regs.update({0: 1, 4: 2})
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0}))["val"] == 1
    ok(b.handle({"die": "A", "op": "wr32", "off": 8, "val": 3}))
    st = b.st["A"]
    assert st["rsp_valid"] == 0 and st["rsp_count"] == 0 and st["rsp_seq"] == b.ack["A"]
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 4}))["val"] == 2
    assert b.discarded == 0

@pytest.mark.parametrize("lag", [0, 1, 2, 5, 10, 12, 16])
def test_executor_lag_0_to_16_with_window_backpressure(lag):
    src = list(range(7000, 7000 + 1000))
    b, board, _ = make(Board(lag=lag, fifos={0xE00C: src}, bp={0xE008: 16 - lag, 0xE00C: 16 - lag}))
    vals = list(range(1000))
    board.flip = {2}                                      # one op frame fails CRC
    board.flip_nops = {5, 9}                              # and two polls
    ok(b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": vals}))
    r = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 1000}))
    die = board.ctl[0]
    assert die.wlog[0xE008] == vals and r["vals"] == src
    assert b.crc_retries == 1 and die.crc_fail == 3
    assert die.reads_over_unacked == 0

def test_identify_retries_a_transient_settle_then_halts_on_mismatch_at_once(monkeypatch):
    b, board, _ = make()
    calls = []
    real = L._Session._poll_settled
    def flaky(sess):
        calls.append(1)
        if len(calls) <= 2:
            raise L.LoadAborted("status never settled in 32 polls (busy=1)")
        return real(sess)
    monkeypatch.setattr(L._Session, "_poll_settled", flaky)
    ok(b.handle({"die": "A", "op": "wr32", "off": 0, "val": 1}))
    assert b.identify_retries == 2 and b.halted is None
    calls.clear()
    def always(sess):
        raise L.LoadAborted("no status word in 32 polls: check --chain")
    monkeypatch.setattr(L._Session, "_poll_settled", always)
    r = b.handle({"die": "B", "op": "wr32", "off": 0, "val": 1})
    assert r["err"].startswith("LoadAborted:") and b.halted



# ---- fix round 1 teeth: cases that tell the surviving mutants apart

def test_a_memrd_whose_last_bit_never_reached_die_b_is_resent():
    """Die B sits behind one BYPASS bit, so a slot's last bit reaches it only with the
    next command. If the link dies on that next command, the MEM_RD never completed:
    its fate is unproven (NOTFAILED), and a MEM_RD may then be resent; it succeeds."""
    b, board, _ = make(allow_image_read=True)
    ok(b.handle({"die": "B", "op": "rd32", "off": 0}))
    board.drop_after_op = C.OP_MEM_RD
    r = ok(b.handle({"die": "B", "op": "memrd", "addr": 0x4000, "n": 64}))
    want = b"".join(board.ctl[1].hbm(a) for a in (0x4000, 0x4020))
    assert bytes.fromhex(r["hex"]) == want
    assert [op for _, op in board.ctl[1].frames].count(C.OP_MEM_RD) == 1
    assert b.crc_retries == 1 and board.nconn == 2

def test_a_window_write_that_executes_after_the_poll_bound_is_never_resent():
    """The write's TDO is lost on the wire (shifted, fate unproven) and the window is
    backpressured past CTL_POLLS: the request ends UNKNOWN, and the write still runs
    exactly once when the window drains."""
    b, board, _ = make(Board(bp={0xE008: B.CTL_POLLS + 20}))
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    board.drop_reply[1] = board.socks[0].ntdi_conn
    r = b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": [1, 2, 3]})
    assert r["ok"] is False and r["err"].startswith("WindowUnknown:"), r
    for _ in range(3):
        ok(b.handle({"die": "A", "op": "rdn", "off": 0x100, "fix": False, "n": 40}))
    assert board.ctl[0].wlog[0xE008] == [1, 2, 3]

def test_a_presented_response_of_the_current_frame_is_accepted_by_release():
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0, "val": 0}))
    die = board.ctl[0]
    die.rsp_valid, die.rsp_seq, die.rsp_count = 1, 0x5151, 2
    die.rsp = [11, 22] + [0] * (C.MAX_ITEMS - 2)
    ok(b.handle({"die": "A", "op": "wr32", "off": 4, "val": 0}))   # the broker sees it
    v = b._ensure("A")
    assert b._release(v, "A", [0x5151], 2) == [11, 22]
    assert b.discarded == 0 and b.ack["A"] == 0x5151

def test_a_self_consistent_wrong_rsp_count_is_repolled_not_fatal():
    b, board, _ = make()
    die = board.ctl[0]
    die.regs[0x60] = 77
    die.bad_count = 2
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0x60}))["val"] == 77
    assert b.rsp_count_mismatches == 2 and len(die.frames) == 1

def test_each_scan_open_hands_its_filler_to_the_ledger(monkeypatch):
    """Every reopen of a die's USER3 scan shifts one filler slot (one desync at the
    die); the first window resolved after it must carry exactly one certain [1, 1]
    entry, or D would be misattributed to the frames in that window."""
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0, "val": 0}))
    ok(b.handle({"die": "B", "op": "wr32", "off": 0, "val": 0}))
    seen = []
    real = B.Broker._resolve
    def spy(self, die, st, entries):
        seen.append((die, [list(e[:4]) for e in entries]))
        return real(self, die, st, entries)
    monkeypatch.setattr(B.Broker, "_resolve", spy)
    d0 = board.ctl[0].desync
    ok(b.handle({"die": "A", "op": "wr32", "off": 4, "val": 1}))      # reopens A
    assert board.ctl[0].desync == d0 + 1
    first = [ents for die, ents in seen if die == "A"][0]
    assert first.count([1, 1, None, True]) == 1

def _verdict(prev, st, entries):
    b, _, _ = make()
    b.st["A"] = prev
    b._resolve("A", st, entries)
    return b.verdict.get(7)

def _st(crc=0, desync=0, ovf=0):
    return dict(crc_fail=crc, desync=desync, ovf=ovf)

@pytest.mark.parametrize("entries,st,want", [
    ([[0, 1, 7, True, 1]], _st(0), "PASSED"),
    ([[0, 1, 7, True, 1]], _st(1), "LOST"),
    ([[0, 1, 7, False, 1]], _st(0), "NOTFAILED"),
    ([[0, 1, 7, False, 1]], _st(0, 1), "LOST"),              # it shifted and desynced
    ([[0, 1, 7, True, 1], [1, 1, None, True, 2]], _st(0, 1), "PASSED"),   # filler counted
    ([[0, 1, 7, True, 1], [1, 1, None, True, 2]], _st(0, 2), "LOST"),
    ([[0, 1, 7, True, 1], [0, 1, None, True, 1]], _st(1), "AMBIGUOUS"),
    ([[0, 1, 7, True, 1], [0, 1, None, True, 1]], _st(2), "LOST"),
    ([[0, 1, 7, True, 1]], _st(0, 0, 1), "AMBIGUOUS"),        # ovf rose: may be dropped
])
def test_the_ledger_verdicts(entries, st, want):
    assert _verdict(_st(), st, entries) == want


@pytest.mark.parametrize("die_name", ["A", "B"])
def test_a_window_write_whose_next_command_is_reset(die_name):
    """The link dies on the command right after a window write's frame. Die A (lead 0)
    has the whole frame by the end of its own command, so it PASSED and the broker
    resumes; die B (lead 1) never got the frame's last bit, so its fate is unproven and
    the request ends UNKNOWN. Either way the window holds the values at most once."""
    d = "AB".index(die_name)
    b, board, _ = make()
    ok(b.handle({"die": die_name, "op": "wr32", "off": 0, "val": 0}))
    board.drop_after_op = C.OP_WR_FIX
    r = b.handle({"die": die_name, "op": "wrn", "off": 0xE008, "fix": True, "vals": [4, 5]})
    w = board.ctl[d].wlog[0xE008]
    if die_name == "A":
        assert r == {"ok": True} and w == [4, 5]
    else:
        assert r["err"].startswith("WindowUnknown:") and w == []


# ---------------------------------------------------------------- fix round 2 (re-review)
# Ported from the reviewer's probes (scratchpad rr6/test_rr6.py), assertions added.

def _wstate(b, die="A"):
    return b.status()["dies"][die]["window_state"]

def test_rr6_counter_wrap_does_not_spill():
    board = Board()
    board.ctl[0].crc_fail = 0xFFFF; board.ctl[0].desync = 0xFFFE
    b, board, _ = make(board)
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 1}))
    board.flip = {1}
    r = b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": [7, 8]})
    assert r["ok"] and board.ctl[0].wlog[0xE008] == [7, 8], r
    assert b.crc_retries == 1

def test_rr6_two_faults_never_double_and_never_leave_ok_after_a_write():
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 1}))
    board.flip = {1}; board.ctl[0].flip_st = 2
    r = b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": [7, 8]})
    w = board.ctl[0].wlog[0xE008]
    assert w in ([], [7, 8])
    if r["ok"]:
        assert w == [7, 8] and _wstate(b) == "ok"
    elif w:
        assert _wstate(b).startswith("UNKNOWN")

def test_rr6_partial_wrn_frame_lost_reports_done_items_and_unknown():
    b, board, _ = make()
    board.flip = {1, 2}
    r = b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": list(range(600))})
    assert r["ok"] is False and r.get("done_items") == 496, r
    assert board.ctl[0].wlog[0xE008] == list(range(496))
    assert _wstate(b).startswith("UNKNOWN") and "UNKNOWN" in r["err"]

def test_rr6_partial_rdn_frame_lost_reports_done_items_and_unknown():
    src = list(range(2000))
    b, board, _ = make(Board(fifos={0xE00C: src}))
    board.flip = {1, 2}
    r = b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 600})
    assert r["ok"] is False and r.get("done_items") == 496, r
    assert len(board.ctl[0].fifos[0xE00C]) == 2000 - 496
    assert _wstate(b).startswith("UNKNOWN")

def test_rr6_settle_failure_with_a_frame_in_flight_marks_unknown():
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0x10, "val": 1}))
    board.drop_after_op = C.OP_WR_FIX
    def oc(bd, n):
        if n == 2:
            bd.ctl[0].flip_st = 1000
    board.on_connect = oc
    r = b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": [7, 8]})
    assert r["ok"] is False and "UNKNOWN" in r["err"], r
    assert _wstate(b).startswith("UNKNOWN")

def test_rr6_partial_inc_ops_report_done_items_without_unknown():
    b, board, _ = make()
    board.flip = {1, 2}
    r = b.handle({"die": "A", "op": "wrn", "off": 0x1000, "fix": False, "vals": list(range(600))})
    assert r["ok"] is False and r.get("done_items") == 496, r
    assert _wstate(b) == "ok"


def test_a_part_shifted_slot_with_a_bad_magic_counts_desync_and_never_doubles():
    """The frame core counts desync at header bit 255. Die B's WR_FIX goes out with a
    garbled magic and the link dies on the next command, so the slot is abandoned
    part-shifted AFTER its desync was counted. The ledger's [0, 1] for that uncertain
    slot must absorb it: no double write, and nothing is resent unless proven lost."""
    b, board, _ = make()
    ok(b.handle({"die": "B", "op": "wr32", "off": 0, "val": 0}))
    d0 = board.ctl[1].desync
    board.flip_magic = {board.nhdr}
    board.drop_after_op = C.OP_WR_FIX
    r = b.handle({"die": "B", "op": "wrn", "off": 0xE008, "fix": True, "vals": [1, 2]})
    w = board.ctl[1].wlog[0xE008]
    assert board.ctl[1].desync >= d0 + 2                  # the garbled header + the filler
    assert w in ([], [1, 2])
    if r["ok"]:
        assert w == [1, 2]
    else:
        assert r["err"].startswith("WindowUnknown:")

def test_a_garbled_magic_on_die_a_is_lost_and_resent_once():
    b, board, _ = make()
    ok(b.handle({"die": "A", "op": "wr32", "off": 0, "val": 0}))
    board.flip_magic = {board.nhdr}
    ok(b.handle({"die": "A", "op": "wrn", "off": 0xE008, "fix": True, "vals": [1, 2]}))
    assert board.ctl[0].wlog[0xE008] == [1, 2] and b.crc_retries == 1

def test_a_rejected_read_fails_and_is_never_resent():
    """axi_resp 01: the executor refused the frame, nothing ran. Not resent (no frame
    that reported axi_err ever is), the window is untouched, done_items is exact."""
    b, board, _ = make()
    die = board.ctl[0]
    die.regs[0x40] = 9
    die.reject_reads = 1
    n0 = board.nframes
    r = b.handle({"die": "A", "op": "rd32", "off": 0x40})
    assert r["ok"] is False and "rejected" in r["err"] and "nothing executed" in r["err"], r
    assert die.rejects == 1 and board.nframes == n0 + 1 and b.rejected == 1
    assert _wstate(b) == "ok"
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 0x40}))["val"] == 9

def test_alloc_never_reuses_the_published_rsp_seq():
    """Force the broker's next seq onto the response seq the die last published: the
    executor would refuse it ("01"); _alloc must step past it."""
    b, board, _ = make()
    die = board.ctl[0]
    die.regs.update({0: 1, 4: 2})
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    ok(b.handle({"die": "A", "op": "wr32", "off": 8, "val": 0}))   # last_done moves on
    assert die.last_done != die.rsp_seq
    b.seq["A"] = die.rsp_seq
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 4}))["val"] == 2
    b.seq["A"] = NONE
    ok(b.handle({"die": "A", "op": "rd32", "off": 4}))
    assert die.rejects == 0

def test_an_axi_error_stops_the_op_inc_is_reported_fix_is_unknown():
    b, board, _ = make(Board(slverr={0x108, 0xE0F0}))
    die = board.ctl[0]
    r = b.handle({"die": "A", "op": "wrn", "off": 0x100, "fix": False, "vals": [1, 2, 3, 4]})
    assert r["err"].startswith("AxiError:") and die.regs == {0x100: 1, 0x104: 2}
    assert _wstate(b) == "ok"
    r = b.handle({"die": "A", "op": "wrn", "off": 0xE0F0, "fix": True, "vals": [5, 6]})
    assert r["err"].startswith("AxiError:") and "UNKNOWN" in r["err"]
    assert _wstate(b).startswith("UNKNOWN")

def test_a_re_presented_accepted_response_with_a_clobbered_tail_is_ignored():
    """Task 3: the ack slot still shifts the tail of the response after the ack, and a
    following MEM_RD can overwrite words 492-495 in that slot. A re-presentation of a
    seq already accepted must be ignored: not counted as a CRC mismatch, not taken, not
    discarded."""
    src = [(0x2545F491 * i) & 0xFFFFFFFF for i in range(992)]
    b, board, _ = make(Board(fifos={0xE00C: src}))
    die = board.ctl[0]
    die.clobber_tail = True
    r = ok(b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 992}))
    assert r["vals"] == src
    assert max(die.presented.values()) >= 2                # it was re-presented
    assert b.rsp_crc_mismatches == 0 and b.discarded == 0


def test_an_older_accepted_seq_re_presented_is_ignored_not_discarded():
    b, board, _ = make()
    die = board.ctl[0]
    die.regs.update({0: 1, 4: 2, 8: 3})
    ok(b.handle({"die": "A", "op": "rd32", "off": 0}))
    x1 = b.ack["A"]
    die.rsp_valid, die.rsp_seq, die.rsp_count = 1, 0x7777, 1       # a foreign response
    die.rsp = [0] * C.MAX_ITEMS
    ok(b.handle({"die": "A", "op": "rd32", "off": 4}))              # discards it, takes X2
    assert b.discarded == 1 and b.ack["A"] != x1
    die.ghost, die.ghost_seq = 3, x1                                 # X1 shows up again
    assert ok(b.handle({"die": "A", "op": "rd32", "off": 8}))["val"] == 3
    assert b.discarded == 1


@pytest.mark.parametrize("resp", [2, 3])
@pytest.mark.parametrize("fix", [True, False])
def test_an_axi_error_is_never_resent_and_a_fixed_window_goes_unknown(fix, resp):
    """Task 3 ruling: the op stops at its first error with earlier items done, and the
    status has no count. Any axi_resp (SLVERR, DECERR, the coming timeout code) is
    never resent; on WR_FIX/RD_FIX the window goes UNKNOWN; done_items is a lower bound."""
    b, board, _ = make(Board(slverr={0xE0F0, 0x2000 + 4 * 500}))
    die = board.ctl[0]
    die_err = die._err
    die._err = lambda seq: (die_err(seq), setattr(die, "axi_resp", resp))
    off = 0xE0F0 if fix else 0x2000
    vals = list(range(700))
    n0 = board.nframes
    r = b.handle({"die": "A", "op": "wrn", "off": off, "fix": fix, "vals": vals})
    assert r["ok"] is False and r["err"].startswith("AxiError:"), r
    assert "partly executed" in r["err"]
    sent = board.nframes - n0
    if fix:
        assert sent == 1 and r["done_items"] == 0
        assert _wstate(b).startswith("UNKNOWN") and "UNKNOWN" in r["err"]
    else:
        assert sent == 2 and r["done_items"] == 496         # frame 2 stopped at item 4
        assert [die.regs.get(0x2000 + 4 * i) for i in range(500)] == vals[:500]
        assert _wstate(b) == "ok"
    assert r["done_items_exact"] is False
    assert b.crc_retries == 0

def test_an_axi_error_on_a_fifo_read_goes_unknown_and_is_not_resent():
    src = list(range(50))
    b, board, _ = make(Board(fifos={0xE00C: src}))
    die = board.ctl[0]
    real = die._exec
    def exec_with_err():
        q = die.q
        if q and q[0][1]["op"] == C.OP_RD_FIX and die.nslot >= q[0][0]:
            h = q.pop(0)[1]
            die.fifos[0xE00C].pop(0); die.fifos[0xE00C].pop(0)   # two items ran
            die.frames.append((h["seq"], C.OP_RD_FIX))
            die.last_done = h["seq"]
            die.axi_err, die.axi_resp, die.err_seq = 1, 2, h["seq"]
        real()
    die._exec = exec_with_err
    n0 = board.nframes
    r = b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 5})
    assert r["ok"] is False and "UNKNOWN" in r["err"] and r["done_items_exact"] is False, r
    assert board.nframes == n0 + 1 and len(die.fifos[0xE00C]) == 48
    assert _wstate(b).startswith("UNKNOWN")

def test_a_rejected_fixed_window_read_leaves_the_window_known():
    """A RD_FIX refused with 01 consumed nothing: window_state stays ok and done_items
    (0) is exact."""
    src = list(range(20))
    b, board, _ = make(Board(fifos={0xE00C: src}))
    die = board.ctl[0]
    die.reject_reads = 1
    r = b.handle({"die": "A", "op": "rdn", "off": 0xE00C, "fix": True, "n": 4})
    assert r["ok"] is False and "rejected" in r["err"], r
    assert r["done_items"] == 0 and r["done_items_exact"] is True
    assert _wstate(b) == "ok" and die.fifos[0xE00C] == src
