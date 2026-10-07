#!/usr/bin/env python3
"""Jungle Cat host broker (plan Task 6): the one process that holds the board BMC's CoE
connection, talks the USER3 control protocol (tools/jc/jc_ctl.py) to both dies, and
serves a Unix socket to the C inference server (server/fk33_transport_jc.c).

    jc_broker.py serve --bmc 192.0.2.1 --chain AB --dies DIES.json --sock PATH
                 [--hz 27000000] [--reconnect-secs 270]
                 [--manifest A=MANIFEST.json] [--manifest B=MANIFEST.json]
                 [--allow-image-read]

(192.0.2.1 is a documentation address; --bmc is required and has no default.)

MAIN SESSION ONLY: this opens the board's JTAG. No subagent runs it against a real
address. The broker and coe_load.py are separate lanes and never hold the BMC at once.

Socket protocol: one JSON object per line each way, one client at a time (a second
client gets {"ok":false,"err":"Busy: ..."} and is closed).

    {"die":"A","op":"rd32","off":N}                    -> {"ok":true,"val":V}
    {"die":"A","op":"wr32","off":N,"val":V}            -> {"ok":true}
    {"die":"A","op":"wrn","off":N,"fix":true,"vals":[...]}   -> {"ok":true}
    {"die":"A","op":"rdn","off":N,"fix":false,"n":K}   -> {"ok":true,"vals":[...]}
    {"die":"A","op":"memrd","addr":A,"n":K}            -> {"ok":true,"hex":"..."}
    {"op":"status"}                                    -> {"ok":true,"dies":{...},"connections":C,...}
    any failure                                        -> {"ok":false,"err":"<class>: <msg>"}

`off` is an AXI-Lite byte offset (4-byte aligned, 32-bit); `fix` selects WR_FIX/RD_FIX
(every item at `off`, the seam's WIN_DATA windows) over WR_INC/RD_INC. `memrd` reads
`n` BYTES of HBM at any `addr` through MEM_RD (the span is widened to whole 32-byte
words on the wire and cut back). `status` answers from what the broker last saw and
never touches the board.

How it drives the board:
  - One coe.CoE connection reaches both dies. Each (die, USER register) pair is a
    coe_load.CoeTransport view of it (user=3 for control, user=4 for identity), made
    with CoeTransport's own constructor; only the first view runs start() (the later
    ones get the same client through _SharedClient, whose start() is a no-op, so
    the handshake runs once per connection). Only one view has a scan open at a time:
    switching closes the open one (exit_dr_to_idle) and opens the other (ir_scan,
    to_shift_dr, filler), all through coe.py's vetted calls and its guard.
  - Die identity: before the first request to a die on every connection (so after every
    reconnect, proactive or reactive), the broker opens that die's USER4 loader and
    runs coe_load._Session's own settle and _identify against the --dies record. A
    mismatch HALTS the broker: every later request is refused until it is restarted.
  - Ops are cut into slots of at most jc_ctl.MAX_ITEMS (496) items. ONE frame is in
    flight per die at a time, so at most one read is outstanding: the broker sends
    the frame, then polls with NOP slots until the die's own status says it is done
    (a write: last_done_seq == its seq; a read: rsp_valid with rsp_seq == its seq and
    rsp_crc matching the words, never a response taken by position), for at most
    CTL_POLLS polls.
  - Host-driven ack (Ruling 2026-10-07): a response stays presented until a PASS frame
    carries ack_valid=1 and ack_seq = its rsp_seq. Every frame the broker sends to a
    die (NOP polls included) carries the ack of the last response it ACCEPTED on that
    die; an ack of an already-acked seq is ignored by the core and seqs are never
    reused, so carrying it again is harmless. A response whose rsp_crc does not match
    is never acked: the broker re-polls (at most RSP_CRC_RETRIES times) and the core
    re-presents it. Before any read the broker polls until the previous response is
    released (rsp_valid = 0 or another seq), so read B never goes out before read A
    is acked. A presented response the broker never accepted (a read it gave up on,
    or one left by an earlier broker process), seen before a read or while waiting for
    one, is acked to release it, logged as JCBROKER_DISCARD and counted.
  - A frame is LOST when an error counter (crc_fail, desync, ovf) moves and its seq is
    still not done LOSS_POLLS polls later. A lost frame is resent once with a fresh seq
    (CRC_RETRIES); a second loss is FrameLost. A frame is never resent while it might
    still execute, so a fixed-window write is never doubled or reordered.
  - axi_err with err_seq == the frame's seq is AxiError.
  - Link loss (coe_load.LinkLost: RST, silence, a poisoned client) closes the
    connection and reconnects (coe_load.RECONNECT_SETTLE_SECS, then up to
    RECONNECT_TRIES dials with RECONNECT_BACKOFF), re-identifies the die, and resumes
    the frame in flight: if the die's settled status shows it done it is not resent.
    At most LINK_RETRIES link losses per request. A bad CoE reply (coe_load.LinkFault)
    is recovered in place (drain() then resync()) and resumes the same way.
  - Proactive reconnect: coe_load's rule. Before a request, if the connection is
    --reconnect-secs old (default coe_load.RECONNECT_SECS = 270, under the BMC's
    ~310 s timer), the broker leaves Shift-DR cleanly, closes the socket and dials anew.
  - The JTAG guard's own refusals (coe.IRNotAllowed, coe.TapProtocolError) are never
    retried or recovered around: they halt the broker.

Control-core contract this relies on (the USER3 core, plan Tasks 2 to 4): a NOP frame
is a status poll; apart from its ack it never changes last_done_seq, rsp_seq, err_seq or
axi_err. Polls use seq 0xFFFFFFFF (jc_ctl.RSP_SEQ_NONE), a value no op frame is ever given.

TEMPORARY SHIM: when this was written tools/jc/jc_ctl.py (Task 5) did not yet carry the
2026-10-07 ruling's header fields ([215:184] ack_seq, [216] ack_valid) or the status's
[212:181] rsp_crc. build_frame() sets the two header fields on jc_ctl.build_slot's slot
and recomputes the slot CRC; ctl_status() reads rsp_crc out of the raw status bits when
parse_tdo does not return it. Replace both with jc_ctl's own once it has them.

memrd and the weight image: --manifest DIE=PATH names the image on each die. A memrd
that touches any of its pieces is Refused unless --allow-image-read; the image record
(the last 512 bytes of the manifest's descriptor arena, server/fk33_imglock.c) is always
allowed, because pl_open reads it there. A die with no --manifest has no known image,
so every memrd on it is Refused unless --allow-image-read.
"""
import argparse, json, os, selectors, socket, stat, struct, sys, time, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from jc import coe
from jc import jc_ctl as C
from jc import coe_load as L

M32 = 0xFFFFFFFF
NOP_SEQ = C.RSP_SEQ_NONE
READ_OPS = (C.OP_RD_INC, C.OP_RD_FIX, C.OP_MEM_RD)
ACK_SEQ_LSB, ACK_VALID_BIT = 184, 216     # header word (Ruling 2026-10-07)
RSP_CRC_LSB = 181                          # status word (Ruling 2026-10-07)

CTL_POLLS = 64            # NOP polls waiting for one frame's result
LOSS_POLLS = 8            # polls after an error counter moved before a frame is lost
RSP_CRC_RETRIES = 8       # re-polls of one response whose rsp_crc does not match
CRC_RETRIES = 1           # a lost frame is resent this many times
LINK_RETRIES = 3          # link losses or bad replies survived inside one request
SETTLE_EQUAL = 2          # consecutive equal control statuses after a scan open
SETTLE_POLLS = L.MAX_POLLS
MAX_N = 1 << 16           # items per rdn/wrn request (a residual is 5,120)
MAX_MEMRD = 1 << 20       # bytes per memrd request
IMGLOCK_BYTES = 512       # FK33_IMGLOCK_BYTES, server/fk33_imglock.h
LINE_MAX = 8 << 20        # bytes of one request line


class BrokerError(Exception):
    pass

class AxiError(BrokerError):
    pass

class FrameLost(BrokerError):
    pass

class CtlTimeout(BrokerError):
    pass

class Refused(BrokerError):
    pass

class Halted(BrokerError):
    pass

class _Lost(Exception):
    """One frame went missing (an error counter moved, its seq never completed)."""


def err_reply(e):
    return {"ok": False, "err": "%s: %s" % (type(e).__name__, e)}


def build_frame(seq, op, addr, items, count, ack=None):
    """jc_ctl.build_slot, plus the header's ack fields when `ack` is a seq (see the
    TEMPORARY SHIM note above): ack_seq at [215:184], ack_valid at [216], slot CRC
    recomputed over the first 16,128 bits exactly as build_slot computes it."""
    slot = C.build_slot(seq, op, addr, items, count)
    if ack is None:
        return slot
    if not 0 <= ack <= M32:
        raise ValueError("ack seq out of range: %r" % (ack,))
    v = int.from_bytes(slot[:C.WORD_BYTES], "little")
    if (v >> ACK_SEQ_LSB) & ((1 << 33) - 1):
        raise ValueError("jc_ctl.build_slot already set header bits [216:184]; retire the shim")
    v |= ack << ACK_SEQ_LSB | 1 << ACK_VALID_BIT
    body = v.to_bytes(C.WORD_BYTES, "little") + slot[C.WORD_BYTES:C.CRC_OFFSET]
    return body + struct.pack("<I", zlib.crc32(body) & M32) + slot[C.CRC_OFFSET + 4:]


def ctl_status(tdo, offset):
    """The control status of one TDO, `offset` bits in (CoeTransport.status_offset), or
    None if it carries none (no JCST magic). Carries rsp_crc ([212:181])."""
    v = int.from_bytes(tdo, "little") >> offset
    b = (v & ((1 << C.SLOT_BITS) - 1)).to_bytes(C.SLOT_BYTES, "little")
    try:
        st = C.parse_tdo(b)
    except ValueError:
        return None
    if "rsp_crc" not in st:
        st["rsp_crc"] = (int.from_bytes(b[:C.STATUS_BYTES], "little") >> RSP_CRC_LSB) & M32
    return st


def rsp_ok(st):
    """rsp_crc checks: CRC-32 (zlib's: reflected, init and final xor all ones, the loader
    frame CRC's convention) over the rsp_count words as shifted (little endian)."""
    n = st["rsp_count"]
    if not 1 <= n <= C.MAX_ITEMS:
        return False
    data = b"".join(struct.pack("<I", w) for w in st["rsp"][:n])
    return zlib.crc32(data) & M32 == st["rsp_crc"]


def _errs(st):
    return (st["crc_fail"], st["desync"], st["ovf"])


def _settle_key(st):
    return tuple(sorted((k, v) for k, v in st.items() if k != "rsp"))


# ---------------------------------------------------------------- the weight-image fence

class ImageFence:
    """The HBM extents of one die's weight image, and its image record's address."""
    def __init__(s, extents, record=None):
        merged = []
        for a, b in sorted(extents):
            if merged and a <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], b)
            else:
                merged.append([a, b])
        s.extents = [tuple(x) for x in merged]
        s.record = record

    def check(s, lo, hi, allow):
        if s.record is not None and s.record[0] <= lo and hi <= s.record[1]:
            return
        if allow:
            return
        for a, b in s.extents:
            if lo < b and a < hi:
                raise Refused("HBM %#x..%#x overlaps the weight image (%#x..%#x); the "
                              "broker serves only the image record there unless started "
                              "with --allow-image-read" % (lo, hi, a, b))


def load_fence(path):
    """An ImageFence from a manifest: every piece of every object (coe_load._entries,
    pieces through fk33_load_weights.pieces_of, i.e. tools/hbm_map.file_pieces), and
    the image record at desc_arena_base + desc_arena_bytes - 512."""
    with open(path) as f:
        mani = json.load(f)
    ext = []
    for e in L._entries(mani):
        for p in L.FLW.pieces_of(e):
            a = int(p["hbm_offset"])
            ext.append((a, a + int(p["nbytes"])))
    hbm = mani.get("hbm") or {}
    base, nb = int(hbm.get("desc_arena_base") or 0), int(hbm.get("desc_arena_bytes") or 0)
    rec = (base + nb - IMGLOCK_BYTES, base + nb) if base and nb >= IMGLOCK_BYTES else None
    return ImageFence(ext, rec)


# ---------------------------------------------------------------- one BMC connection

class _SharedClient:
    """The connection's coe.CoE, for every view after the first: start() already ran
    on it (in the first view's constructor), so here it is a no-op; everything else is
    the client itself, guard and shadow TAP included."""
    def __init__(s, c):
        object.__setattr__(s, "_c", c)
    def start(s, hz=None):
        return None
    def __getattr__(s, k):
        return getattr(s._c, k)
    def __setattr__(s, k, v):
        setattr(s._c, k, v)


class _Conn:
    def __init__(s, client, chain, hz, t0):
        s.client, s.chain, s.hz, s.t0 = client, chain, hz, t0
        s.views, s.open, s.identified = {}, None, set()

    def view(s, die, user):
        k = (die, user)
        if k not in s.views:
            c = s.client if not s.views else _SharedClient(s.client)
            s.views[k] = L._Guarded(L.CoeTransport(None, die, s.chain, hz=s.hz, client=c,
                                                   user=user))
        return s.views[k]

    def select(s, die, user):
        """The view for (die, user) with its scan open; True if it was opened now."""
        k = (die, user)
        if s.open == k:
            return s.views[k], False
        if s.open is not None:
            v, s.open = s.views[s.open], None
            v.close_scan()
        v = s.view(die, user)
        v.open_scan()
        s.open = k
        return v, True

    def close(s, clean):
        if s.open is not None:
            v, s.open = s.views[s.open], None
            if clean:
                try:
                    v.close_scan()
                except Exception:
                    v.abort_close()
            else:
                v.abort_close()
        for v in s.views.values():
            v.close()
            break


# ---------------------------------------------------------------- the broker

class Broker:
    """Requests in, frames out. `connect()` dials the BMC and returns a coe.CoE (the
    CLI's is coe.CoE(--bmc); tests pass a modelled chain). `dies` is {name: DNA}, from
    the --dies record; `fences` {name: ImageFence}."""
    def __init__(s, connect, chain, dies, *, hz=27_000_000, reconnect_secs=L.RECONNECT_SECS,
                 fences=None, allow_image_read=False, dies_label="the die record",
                 now=time.monotonic, sleep=time.sleep, log=None):
        if len(chain) != coe.CHAIN_DEVICES or sorted(chain) != sorted(L.DIE_NAMES):
            raise ValueError("chain must be AB or BA")
        for d in chain:
            if d not in dies:
                raise L.LoadAborted("die %s is not in %s: run `coe_load.py identify` for "
                                    "it once at bring-up" % (d, dies_label))
        s.connect_fn, s.chain, s.dies, s.hz = connect, chain, dict(dies), hz
        s.reconnect_secs, s.fences = reconnect_secs, dict(fences or {})
        s.allow_image_read, s.dies_label = allow_image_read, dies_label
        s.now, s.sleep, s.log = now, sleep, log
        s.conn, s.halted = None, None
        s.connections = s.reconnects = s.crc_retries = 0
        s.rsp_crc_mismatches = s.discarded = 0
        s.seq = {d: None for d in chain}
        s.st = {d: None for d in chain}
        s.ack = {d: None for d in chain}    # last response accepted (or released) per die

    def _say(s, msg):
        if s.log is not None:
            print(msg, file=s.log, flush=True)

    # ---- connection lifecycle

    def _connect(s):
        last = None
        for k in range(L.RECONNECT_TRIES):
            if k:
                s.sleep(k * L.RECONNECT_BACKOFF)
            try:
                client = s.connect_fn()
                conn = _Conn(client, s.chain, s.hz, s.now())
                conn.view(s.chain[0], 3)                  # start(): handshake, resync
            except (OSError, L.LinkFault) as e:
                last = e
                continue
            s.conn = conn
            s.connections += 1
            s.st = {d: None for d in s.chain}
            s._say("JCBROKER_CONNECT %d" % s.connections)
            return conn
        raise L.LinkLost(last)

    def _drop(s, clean):
        c, s.conn = s.conn, None
        s.st = {d: None for d in s.chain}
        if c is not None:
            c.close(clean)

    def _maybe_rotate(s):
        c = s.conn
        if c is None or not s.reconnect_secs:
            return
        secs = s.now() - c.t0
        if secs >= s.reconnect_secs:
            s._say("JCBROKER_RECONNECT %d proactive %.0f" % (s.reconnects + 1, secs))
            s.reconnects += 1
            s._drop(clean=True)

    def _link_lost(s, e):
        secs = s.now() - s.conn.t0 if s.conn is not None else 0.0
        s.reconnects += 1
        s._say("JCBROKER_RECONNECT %d %s %.0f" % (s.reconnects, e, secs))
        s._drop(clean=False)
        s.sleep(L.RECONNECT_SETTLE_SECS)

    def _halt(s, e):
        s.halted = "%s: %s" % (type(e).__name__, e)
        s._say("JCBROKER_HALT %s" % s.halted)
        try:
            s._drop(clean=False)
        except Exception:
            pass

    # ---- one die's control scan

    def _ensure(s, die):
        """Connected, `die` identified on this connection, its USER3 scan open and its
        control status settled. Returns the view."""
        if s.conn is None:
            s._connect()
        c = s.conn
        if die not in c.identified:
            v, _ = c.select(die, 4)
            L._Session(v, s.dies[die], dna_label=s.dies_label, health=False)._settle()
            c.identified.add(die)
        v, opened = c.select(die, 3)
        if opened or s.st[die] is None:
            s._settle(v, die)
        return v

    def _xfer(s, v, die, slot):
        v.send(slot)
        st = ctl_status(v.recv(), v.status_offset)
        if st is not None:
            s.st[die] = st
        return st

    def _settle(s, v, die):
        prev, run, seen = None, 0, 0
        for _ in range(SETTLE_POLLS):
            st = s._xfer(v, die, s._nop(die))
            if st is None:
                prev, run = None, 0
                continue
            seen += 1
            key = _settle_key(st)
            run = run + 1 if key == prev else 1
            prev = key
            if run >= SETTLE_EQUAL:
                return st
        if not seen:
            raise BrokerError("no USER3 control status from die %s in %d polls: is the "
                              "bitstream the composed card with the control core, and is "
                              "--chain right?" % (die, SETTLE_POLLS))
        raise BrokerError("die %s's control status never settled in %d polls"
                          % (die, SETTLE_POLLS))

    def _nop(s, die):
        return build_frame(NOP_SEQ, C.OP_NOP, 0, None, 1, s.ack[die])

    def _alloc(s, die):
        st = s.st[die]
        n = s.seq[die]
        if n is None:
            n = (st["last_done_seq"] + 1) & M32
        avoid = {NOP_SEQ, st["last_done_seq"], st["rsp_seq"], st["err_seq"], s.ack[die]}
        while n in avoid:
            n = (n + 1) & M32
        s.seq[die] = (n + 1) & M32
        return n

    def _axi_check(s, die, st, seq, op, addr):
        if st["axi_err"] and st["err_seq"] == seq:
            raise AxiError("die %s seq %d (op %d at %#x): AXI error, resp %d"
                           % (die, seq, op, addr, st["axi_resp"]))

    def _take(s, die, st, mine, count):
        """The response in `st` if it is one of this frame's seqs (`mine`) and its
        rsp_crc checks: accepted, and acked from the next frame on. None if it is not
        there; a CRC mismatch is counted and left unacked (the core re-presents it)."""
        if not (st["rsp_valid"] and st["rsp_seq"] in mine):
            return None
        if st["rsp_count"] != count:
            raise BrokerError("die %s seq %d: response carries %d items, asked for %d"
                              % (die, st["rsp_seq"], st["rsp_count"], count))
        if not rsp_ok(st):
            s.rsp_crc_mismatches += 1
            s._say("JCBROKER_RSP_CRC die %s seq %d: mismatch, re-polling"
                   % (die, st["rsp_seq"]))
            return False
        s.ack[die] = st["rsp_seq"]
        return st["rsp"][:count]

    def _release(s, v, die):
        """Before a read: poll (each NOP carrying the ack) until no response is
        presented, so the next read can never go out ahead of the last one's ack."""
        for _ in range(CTL_POLLS):
            st = s.st[die]
            if not st["rsp_valid"]:
                return
            x = st["rsp_seq"]
            if x != s.ack[die]:
                s._discard(die, x)
            s._xfer(v, die, s._nop(die))
        raise CtlTimeout("die %s: response seq %d still presented after %d acked polls"
                         % (die, s.st[die]["rsp_seq"], CTL_POLLS))

    def _discard(s, die, x):
        """Ack a presented response this broker never accepted, so the core releases it
        (a read given up on, or an earlier process's). A seq the core is not presenting
        (a transient or corrupted status) makes the ack a no-op there."""
        s.discarded += 1
        s._say("JCBROKER_DISCARD die %s: response seq %d was never accepted; acking it "
               "to release the buffer" % (die, x))
        s.ack[die] = x

    def _confirm(s, v, die, seq, op, addr, items, count, mine):
        base = _errs(s.st[die])
        s._xfer(v, die, build_frame(seq, op, addr, items, count, s.ack[die]))
        moved, bad = None, 0
        for k in range(CTL_POLLS):
            st = s._xfer(v, die, s._nop(die))
            if st is None:
                continue
            s._axi_check(die, st, seq, op, addr)
            if op in READ_OPS:
                got = s._take(die, st, mine, count)
                if got is False:
                    bad += 1
                    if bad > RSP_CRC_RETRIES:
                        raise BrokerError("die %s seq %d: response CRC mismatched %d times"
                                          % (die, st["rsp_seq"], bad))
                    continue
                if got is not None:
                    return got
                if (st["rsp_valid"] and st["rsp_seq"] not in mine
                        and st["rsp_seq"] != s.ack[die]):
                    s._discard(die, st["rsp_seq"])       # it would hold this read back
            elif st["last_done_seq"] == seq:
                return None
            if moved is None and _errs(st) != base:
                moved = k
            if moved is not None and k - moved >= LOSS_POLLS:
                raise _Lost("die %s seq %d: crc_fail/desync/ovf %s -> %s and the frame "
                            "never completed" % (die, seq, base, _errs(st)))
        raise CtlTimeout("die %s seq %d (op %d at %#x): not done after %d polls"
                         % (die, seq, op, addr, CTL_POLLS))

    def _frame(s, die, op, addr, items, count):
        """One frame on `die`, confirmed. Returns the read items, or None for a write."""
        lost_left, link_left = CRC_RETRIES, LINK_RETRIES
        pending = None              # a frame sent before a link event: done or not?
        mine = set()                # every seq this one frame has gone out under
        while True:
            try:
                v = s._ensure(die)
                if pending is not None:
                    st = s.st[die]
                    s._axi_check(die, st, pending, op, addr)
                    if op in READ_OPS:
                        got = s._take(die, st, mine, count)
                        if got:
                            return got
                    elif st["last_done_seq"] == pending:
                        return None
                    pending = None
                if op in READ_OPS:
                    s._release(v, die)
                seq = s._alloc(die)
                mine.add(seq)
                try:
                    return s._confirm(v, die, seq, op, addr, items, count, mine)
                except (L.LinkLost, L.LinkFault):
                    pending = seq
                    raise
            except _Lost as e:
                if lost_left == 0:
                    raise FrameLost("%s; already resent %d time(s)" % (e, CRC_RETRIES))
                lost_left -= 1
                s.crc_retries += 1
                s._say("JCBROKER_RETRY %s" % e)
            except L.LinkFault as e:
                if link_left == 0:
                    raise
                link_left -= 1
                s._recover(e)
            except L.LinkLost as e:
                if link_left == 0:
                    s._drop(clean=False)
                    raise
                link_left -= 1
                s._link_lost(e)

    def _recover(s, e):
        """A bad CoE reply on a still-framed connection: drain() then resync() through
        the open view, then reopen on the next _ensure."""
        c = s.conn
        s._say("JCBROKER_RECOVER %s" % e)
        k, c.open = c.open, None
        for d in s.chain:
            s.st[d] = None
        try:
            if k is not None:
                c.views[k].recover()
        except L.LinkLost as e2:
            s._link_lost(e2)

    # ---- ops

    def rd32(s, die, off):
        return s._frame(die, C.OP_RD_INC, off, None, 1)[0]

    def wr32(s, die, off, val):
        s._frame(die, C.OP_WR_INC, off, [val], 1)

    def wrn(s, die, off, fix, vals):
        op = C.OP_WR_FIX if fix else C.OP_WR_INC
        for i in range(0, len(vals), C.MAX_ITEMS):
            chunk = vals[i:i + C.MAX_ITEMS]
            s._frame(die, op, off if fix else off + 4 * i, chunk, len(chunk))

    def rdn(s, die, off, fix, n):
        op = C.OP_RD_FIX if fix else C.OP_RD_INC
        out = []
        for i in range(0, n, C.MAX_ITEMS):
            k = min(C.MAX_ITEMS, n - i)
            out += s._frame(die, op, off if fix else off + 4 * i, None, k)
        return out

    def memrd(s, die, addr, n):
        lo = addr - addr % C.WORD_BYTES
        hi = (addr + n + C.WORD_BYTES - 1) // C.WORD_BYTES * C.WORD_BYTES
        fence = s.fences.get(die)
        if fence is not None:
            fence.check(lo, hi, s.allow_image_read)
        elif not s.allow_image_read:
            raise Refused("no --manifest for die %s, so its weight image is unknown; memrd "
                          "is refused on it unless the broker runs with --allow-image-read"
                          % die)
        out = bytearray()
        a = lo
        while a < hi:
            nb = min(C.MAX_PAYLOAD_BYTES, hi - a)
            words = s._frame(die, C.OP_MEM_RD, a, None, nb // 4)
            out += b"".join(struct.pack("<I", w) for w in words)
            a += nb
        return bytes(out[addr - lo:addr - lo + n])

    def status(s):
        dies = {}
        for d in s.chain:
            st = s.st[d] or {}
            dies[d] = dict(dna=L.dna_mask(s.dies[d]),
                           identified=bool(s.conn and d in s.conn.identified),
                           manifest=d in s.fences,
                           **{k: st.get(k) for k in ("last_done_seq", "crc_fail", "desync",
                                                     "ovf", "axi_err", "err_seq")})
        return {"ok": True, "dies": dies, "connections": s.connections,
                "connected": s.conn is not None,
                "secs_on_connection": (s.now() - s.conn.t0) if s.conn else None,
                "reconnects": s.reconnects, "crc_retries": s.crc_retries,
                "rsp_crc_mismatches": s.rsp_crc_mismatches,
                "responses_discarded": s.discarded, "halted": s.halted}

    # ---- requests

    def handle(s, req):
        try:
            if not isinstance(req, dict):
                raise ValueError("a request is a JSON object")
            op = req.get("op")
            if op == "status":
                return s.status()
            if s.halted:
                raise Halted(s.halted)
            die = req.get("die")
            if die not in s.chain:
                raise ValueError("die must be one of %s, got %r" % ("/".join(s.chain), die))
            if op == "rd32":
                off = _off(req, 1)
                return s._run(lambda: {"ok": True, "val": s.rd32(die, off)})
            if op == "wr32":
                off, val = _off(req, 1), _u(req, "val", 32)
                return s._run(lambda: (s.wr32(die, off, val), {"ok": True})[1])
            if op == "wrn":
                fix, vals = _bool(req, "fix"), req.get("vals")
                if (not isinstance(vals, list) or not 1 <= len(vals) <= MAX_N
                        or any(type(x) is not int or not 0 <= x <= M32 for x in vals)):
                    raise ValueError("vals must be a list of 1..%d integers 0..2^32-1" % MAX_N)
                off = _off(req, 1 if fix else len(vals))
                return s._run(lambda: (s.wrn(die, off, fix, vals), {"ok": True})[1])
            if op == "rdn":
                fix, n = _bool(req, "fix"), _u(req, "n", 32)
                if not 1 <= n <= MAX_N:
                    raise ValueError("n must be 1..%d, got %d" % (MAX_N, n))
                off = _off(req, 1 if fix else n)
                return s._run(lambda: {"ok": True, "vals": s.rdn(die, off, fix, n)})
            if op == "memrd":
                addr, n = _u(req, "addr", 64), _u(req, "n", 32)
                if not 1 <= n <= MAX_MEMRD or addr + n > L.HBM_SIZE:
                    raise ValueError("memrd needs 1..%d bytes inside the %d GiB HBM map"
                                     % (MAX_MEMRD, L.HBM_SIZE >> 30))
                return s._run(lambda: {"ok": True, "hex": s.memrd(die, addr, n).hex()})
            raise ValueError("unknown op %r" % (op,))
        except (coe.IRNotAllowed, coe.TapProtocolError, L.LoadAborted) as e:
            s._halt(e)
            return err_reply(e)
        except Exception as e:
            return err_reply(e)

    def _run(s, fn):
        s._maybe_rotate()
        return fn()

    def close(s):
        s._drop(clean=True)


def _u(req, k, bits):
    v = req.get(k)
    if type(v) is not int or not 0 <= v < 1 << bits:
        raise ValueError("%s must be an integer 0..2^%d-1, got %r" % (k, bits, v))
    return v

def _off(req, n_items):
    v = _u(req, "off", 32)
    if v % 4:
        raise ValueError("off must be 4-byte aligned, got %#x" % v)
    if v + 4 * n_items > 1 << 32:
        raise ValueError("off %#x + %d items runs past the 32-bit AXI-Lite space" % (v, n_items))
    return v

def _bool(req, k):
    v = req.get(k)
    if type(v) is not bool:
        raise ValueError("%s must be true or false, got %r" % (k, v))
    return v


# ---------------------------------------------------------------- the Unix socket

def _line(obj):
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode()


class Server:
    """One client at a time; requests are served in order, one line each way."""
    def __init__(s, broker):
        s.b, s.client, s.buf, s.refused = broker, None, bytearray(), 0

    def offer(s, conn):
        if s.client is not None:
            s.refused += 1
            try:
                conn.sendall(_line({"ok": False, "err": "Busy: the broker already has a "
                                    "client and serves one at a time"}))
            except OSError:
                pass
            conn.close()
            return False
        conn.setblocking(True)
        s.client, s.buf = conn, bytearray()
        return True

    def _end(s):
        c, s.client, s.buf = s.client, None, bytearray()
        if c is not None:
            try:
                c.close()
            except OSError:
                pass

    def pump(s):
        """Read what the client sent (one recv) and answer every complete line."""
        try:
            data = s.client.recv(1 << 20)
        except OSError:
            data = b""
        if not data:
            s._end()
            return
        s.buf += data
        while s.client is not None:
            i = s.buf.find(b"\n")
            if i < 0:
                if len(s.buf) > LINE_MAX:
                    s._send(err_reply(ValueError("request line over %d bytes" % LINE_MAX)))
                    s._end()
                return
            line, s.buf = bytes(s.buf[:i]), s.buf[i + 1:]
            if not line.strip():
                continue
            try:
                req = json.loads(line)
            except ValueError as e:
                rsp = err_reply(e)
            else:
                rsp = s.b.handle(req)
            s._send(rsp)

    def _send(s, rsp):
        try:
            s.client.sendall(_line(rsp))
        except OSError:
            s._end()

    def serve(s, listener, stop=lambda: False, timeout=1.0):
        sel = selectors.DefaultSelector()
        sel.register(listener, selectors.EVENT_READ, None)
        reg = None
        try:
            while not stop():
                for key, _ in sel.select(timeout):
                    if key.data is None:
                        conn, _ = listener.accept()
                        if s.offer(conn):
                            sel.register(conn, selectors.EVENT_READ, "client")
                            reg = conn
                    else:
                        s.pump()
                if reg is not None and s.client is not reg:
                    sel.unregister(reg)
                    reg = None
        finally:
            sel.close()


def listen(path):
    """Bind the broker's Unix socket at `path`, mode 0600. A socket file already there
    is refused if something answers on it (another broker), else replaced."""
    if os.path.lexists(path):
        if not stat.S_ISSOCK(os.lstat(path).st_mode):
            raise L.LoadAborted("%s exists and is not a socket" % path)
        probe = socket.socket(socket.AF_UNIX)
        try:
            probe.connect(path)
        except OSError:
            os.unlink(path)
        else:
            probe.close()
            raise L.LoadAborted("another broker is serving %s" % path)
    lst = socket.socket(socket.AF_UNIX)
    old = os.umask(0o177)
    try:
        lst.bind(path)
    finally:
        os.umask(old)
    os.chmod(path, 0o600)
    lst.listen(2)
    return lst


# ---------------------------------------------------------------- CLI

def _manifest_arg(v):
    die, sep, path = v.partition("=")
    if not sep or die not in L.DIE_NAMES or not path:
        raise argparse.ArgumentTypeError("--manifest takes DIE=PATH with DIE A or B, got %r" % v)
    return die, path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("serve", help="hold the BMC and serve the Unix socket")
    p.add_argument("--bmc", required=True, help="the board BMC's address (no default)")
    p.add_argument("--chain", required=True, choices=["AB", "BA"])
    p.add_argument("--dies", required=True, help="die record from coe_load.py identify")
    p.add_argument("--sock", required=True, help="Unix socket path to serve")
    p.add_argument("--hz", type=L._hz_type, default=27_000_000)
    p.add_argument("--reconnect-secs", type=L._reconnect_secs_type, default=L.RECONNECT_SECS)
    p.add_argument("--manifest", type=_manifest_arg, action="append", default=[],
                   help="DIE=PATH: the weight image on that die (fences memrd)")
    p.add_argument("--allow-image-read", action="store_true")
    a = ap.parse_args(argv)
    try:
        dies = {d: L.dna_for(a.dies, d) for d in a.chain}
        fences = {}
        for d, path in a.manifest:
            if d in fences:
                raise L.LoadAborted("--manifest given twice for die %s" % d)
            fences[d] = load_fence(path)
        br = Broker(lambda: coe.CoE(a.bmc), a.chain, dies, hz=a.hz,
                    reconnect_secs=a.reconnect_secs, fences=fences,
                    allow_image_read=a.allow_image_read, dies_label=a.dies, log=sys.stderr)
        lst = listen(a.sock)
    except (L.LoadAborted, OSError, ValueError, KeyError) as e:
        print("JCBROKER_ABORT %s: %s" % (type(e).__name__, e), flush=True)
        return 1
    print("JCBROKER_READY %s" % a.sock, flush=True)
    try:
        Server(br).serve(lst)
    except KeyboardInterrupt:
        pass
    finally:
        br.close()
        lst.close()
        try:
            os.unlink(a.sock)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
