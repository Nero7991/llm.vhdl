#!/usr/bin/env python3
"""Load a weight image into a Jungle Cat die's HBM over JTAG (plan Tasks 8 and 9).

    coe_load.py load   MANIFEST.json --bmc 192.0.2.1 --die A|B --chain AB|BA [--resume]
    coe_load.py verify MANIFEST.json --bmc 192.0.2.1 --die A|B --chain AB|BA

(192.0.2.1 is a documentation address; --bmc is required and has no default.)

Main session only: this opens the board's JTAG. Addresses come only from the manifest,
through fk33_load_weights.pieces_of() (tools/hbm_map.py::file_pieces()).

Task 9 (the load driver, below plan_frames): a transport (CoeTransport for the board,
FakeTransport for tests) moves 16,384-bit slots and returns the TDO of each; the Loader
keeps `depth` slots in flight, reads the lagged status word out of each TDO, resyncs
(leave and re-enter Shift-DR, resend from the die's last committed seq) when an error
counter moves, recovers from a bad CoE reply by drain() then resync(), waits for the
die's own status to show the last frame before calling a load done, binds a
checkpoint to the plan's sha so a resume cannot continue someone else's image, and
re-checks every piece by range CRC in `verify`. The die's status, never the
checkpoint, says how far a load got.

Fix round 1 (review: opus, 2026-10-05) corrected three planning defects:
  (c) expected_range_crc used to pad a short piece with whatever bytes followed it in
      the same file -- real neighbour data, not what the card holds there. The card's
      jc_hbm_writer commits exactly `nwords` whole 32-byte words per frame, and
      jc_frame.build_slot zero-pads a frame's payload up to that word boundary, so the
      true padding is always zero. Frame now carries the piece's unpadded length
      (`raw_n`) alongside the padded one (`n`); expected_range_crc reads only `raw_n`
      real bytes and pads the rest with zero itself.
  (d) plan_sha depended only on (file, addr, file_offset, nbytes), so two manifests
      with identical layout but different CONTENT hashed the same -- a resume could not
      tell the data had changed. It now folds in each entry's blake2b_128, plus
      F.MAX_PAYLOAD_BYTES and the target die (a plan for die A must never be mistaken
      for one planned for die B).
  (e) Spec S5's preflight (aligned, in range, single stack, disjoint) was only partly
      implemented: alignment and pairwise overlap, but not the per-piece HBM range or
      stack checks. plan_frames now refuses a piece that runs past the die's 8 GiB HBM
      map, a piece that straddles the 4 GiB stack line. A zero-length piece is refused
      outright (nothing to compare the range CRC against).

Fix round 2 (re-review, 2026-10-05) corrected two more:
  (6) the stack check above was wrong, not just incomplete: it compared the declared
      `stack` field against EVERY piece's own address, but `stack` names the stack the
      OBJECT's header (its first piece / its own `hbm_offset`) is in, not a claim that
      every piece shares it -- a real lane-striped manifest deliberately puts some
      lanes in the other stack (`tools/hbm_map.py`'s `manifest_piece_fails` P4 checks
      the header only, for the same reason). The old per-piece version refused every
      object that actually used both stacks: 1,488 of 3,473 pieces on a real 9B
      manifest. Fixed to check once per entry, against `e["hbm_offset"]`, matching P4.
  (7) a piece could declare a negative address or file offset, or a length that runs
      past the end of its own source file, and nothing refused it (the file-offset
      case silently read fewer bytes than declared and comparing against a short slice
      happened to still produce *a* CRC, just not one of anything real). Both are now
      refused in planning, same spirit as `fk33_load_weights.py`'s own preflight
      `getsize` check.
"""
import collections, contextlib, hashlib, json, os, sys, time, zlib
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33", "host"))
from jc import jc_frame as F
from jc import coe
import fk33_load_weights as FLW

Frame = collections.namedtuple("Frame", "seq addr path off n kind raw_n")

# Spec S2/S3: HBM is 8 GiB per die, two 4 GiB stacks ("no piece crosses the 4 GB stack
# boundary"). Same values fk33_load_weights.py uses for the FK33's own (same-family) map.
HBM_SIZE = 0x2_0000_0000
STACK_LINE = 0x1_0000_0000

class PlanError(Exception):
    pass

def _stack_of(addr):
    return 0 if addr < STACK_LINE else 1

def _entries(mani):
    return list(mani["files"]) + list(FLW.const_entries(mani))

def plan_frames(manifest_path, die=None):
    with open(manifest_path) as f:
        mani = json.load(f)
    root = os.path.dirname(os.path.abspath(manifest_path))
    frames, pieces = [], []
    h = hashlib.sha256()
    h.update(("die=%s max_payload=%d\n" % (die, F.MAX_PAYLOAD_BYTES)).encode())
    for e in _entries(mani):
        path = os.path.join(root, e["file"])
        filesize = os.path.getsize(path)
        dig = hashlib.blake2b(digest_size=16)
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 24), b""):
                dig.update(chunk)
        if dig.hexdigest() != e["blake2b_128"]:
            raise PlanError("%s hashes to %s, the manifest says %s"
                            % (e["file"], dig.hexdigest(), e["blake2b_128"]))
        declared = e.get("stack")
        header_addr = int(e["hbm_offset"])
        if declared is not None and int(declared) != _stack_of(header_addr):
            raise PlanError("%s declares stack %s, its header at %#x is actually in "
                            "stack %d" % (e["file"], declared, header_addr, _stack_of(header_addr)))
        for p in FLW.pieces_of(e):
            addr, foff, n = int(p["hbm_offset"]), int(p["file_offset"]), int(p["nbytes"])
            if n == 0:
                raise PlanError("%s piece at %#x is zero length" % (e["file"], addr))
            if addr < 0:
                raise PlanError("%s piece has a negative HBM address %d" % (e["file"], addr))
            if foff < 0:
                raise PlanError("%s piece has a negative file offset %d" % (e["file"], foff))
            if addr % 32:
                raise PlanError("%s piece at %#x is not 32-byte aligned" % (e["file"], addr))
            if addr + n > HBM_SIZE:
                raise PlanError("%s piece at %#x+%d runs past the %d GiB HBM map"
                                % (e["file"], addr, n, HBM_SIZE >> 30))
            if addr < STACK_LINE < addr + n:
                raise PlanError("%s piece at %#x+%d spans the %d GiB HBM stack boundary"
                                % (e["file"], addr, n, STACK_LINE >> 30))
            if foff + n > filesize:
                raise PlanError("%s piece at file +%d+%d runs past the file's own size %d"
                                % (e["file"], foff, n, filesize))
            pieces.append((addr, path, foff, n))
            h.update(("%s %d %d %d %s\n" % (e["file"], addr, foff, n, e["blake2b_128"])).encode())
    pieces.sort()
    for (a0, _, _, n0), (a1, _, _, _) in zip(pieces, pieces[1:]):
        if a0 + (n0 + 31) // 32 * 32 > a1:
            raise PlanError("pieces overlap after padding: %#x+%d reaches %#x" % (a0, n0, a1))
    seq = 0
    for addr, path, foff, n in pieces:
        k = 0
        while k < n:
            m = min(F.MAX_PAYLOAD_BYTES, n - k)
            frames.append(Frame(seq, addr + k, path, foff + k, m, "data", m)); seq += 1
            k += m
    for addr, path, foff, n in pieces:
        frames.append(Frame(seq, addr, path, foff, (n + 31) // 32 * 32, "range", n)); seq += 1
    return frames, h.hexdigest()

def read_payload(fr):
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        return fh.read(fr.n)

def expected_range_crc(fr):
    """CRC over the piece's real (`raw_n`) bytes, zero-padded to the frame's 32-byte
    length `n` -- the same padding jc_frame.build_slot applies before the writer commits
    whole words, never bytes read from whatever happens to follow in the source file."""
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        raw = fh.read(fr.raw_n)
    return zlib.crc32(raw.ljust(fr.n, b"\0")) & 0xFFFFFFFF


# ====================================================================== Task 9

FILLER_BITS = F.SLOT_BITS
MAX_RESYNCS = 8           # resyncs/recoveries/tail resends per run, then give up
MAX_POLLS = 32            # status polls per wait; small so a wrong --chain fails fast
CKPT_EVERY = 1000         # frames between checkpoint writes
NONE = 0xFFFFFFFF         # status "last committed seq" before anything committed
M32 = 0xFFFFFFFF

class LoadAborted(Exception):
    pass

class LinkFault(Exception):
    """A CoE reply was bad (status, txn or length) but the connection is still framed:
    the transport's recover() (drain() then resync()) gets it back. A dead socket is a
    ConnectionError instead, which ends the run (resume later)."""
    pass

def _errs(st):
    """The counters whose movement means a frame was lost or rejected: resync."""
    return (st["crc_fail"], st["seq_err"], st["desync"], st["fifo_ovf"])

def status_of(tdo, offset):
    v = int.from_bytes(tdo[:40], "little") >> offset
    return F.parse_status((v & ((1 << 256) - 1)).to_bytes(32, "little"))

class FakeTransport:
    """The loader's view of the board, backed by LoaderModel (tests only). Models the
    chain lead bit, status lag (the status in a slot's TDO reflects the model
    `lag_slots` slots before that slot), injected CRC faults (`fail_seqs`, once each
    unless `fail_forever`), frames that vanish without a trace (`drop_seqs`, once
    each), slots that arrive misaligned (`desync_seqs`, once each), bad CoE replies
    (`fault_sends`, by send index: the slot is shifted, its recv() raises LinkFault),
    an HBM temperature trip (`trip_after` sends), an HBM read error on a range CRC
    (`rerr_seqs`), a range result that shows up one status late (`stale_range`: the
    first status after each range request still carries the previous range result,
    as the real writer's `last` can move before the CRC unit's), a wrong chain
    setting, and a dropped connection (`drop_after` sends).

    `model` is a LoaderModel, or (fix round 1) a jc_model.FifoOverflowModel built with
    `crc_ticks_per_byte`: then every slot shifted advances its clock one tick, so the
    CRC unit's busy time and the finite FIFO behind it are modelled too.

    It also enforces the same protocol CoeTransport's CoE client does: open_scan only
    when closed; send/recv only while open; close_scan only with every TDO read;
    after a LinkFault nothing but recover(). A loader that breaks the order fails
    with AssertionError here instead of passing against a lenient fake."""
    def __init__(s, model, lead, lag_slots=2, fail_seqs=(), drop_after=None,
                 wrong_lead=False, drop_seqs=(), desync_seqs=(), fault_sends=(),
                 trip_after=None, fail_forever=False, rerr_seqs=(), stale_range=False):
        s.m, s.lead, s.lag = model, lead, lag_slots
        s.fail = set(fail_seqs); s.fail_forever = fail_forever
        s.drop = set(drop_seqs); s.desync = set(desync_seqs); s.faults = set(fault_sends)
        s.drop_after, s.wrong, s.trip_after = drop_after, wrong_lead, trip_after
        s.rerr = set(rerr_seqs); s.stale_range = stale_range
        s.prev_rep, s.staled = None, set()
        s.depth, s.status_offset = 4, 1
        s.hist, s.out, s.sent, s.first_seq_sent = [], [], 0, None
        s.state, s.opens, s.recovers, s.abort_closes = "closed", 0, 0, 0
        s.misaligned = False
        s._feed = getattr(model, "feed_slot", None) or model.feed
        s._status = getattr(model, "loader_status", None) or model.status
        s._tick = getattr(model, "tick", None)

    def _shift(s, slot):
        """One slot on the wire: what the die does with it, and the TDO it returns."""
        if s._tick is not None:
            s._tick(1)
        s.hist.append(dict(s._status()))
        if s.misaligned:
            s._feed(bytes(F.SLOT_BYTES))          # the die sees garbage, TDO no status
            return bytes(F.SLOT_BYTES)
        h = F.parse_header(slot)
        real = h["magic"] == F.MAGIC_FRAME and (h["nwords"] or h["flags"])
        if real and h["seq"] in s.drop:
            s.drop.discard(h["seq"])                  # lost: never reaches the writer
        elif real and h["seq"] in s.desync:
            s.desync.discard(h["seq"])
            b = bytearray(slot); b[0] ^= 1; s._feed(bytes(b))
        elif real and h["seq"] in s.fail:
            if not s.fail_forever:
                s.fail.discard(h["seq"])
            b = bytearray(slot); b[100] ^= 1; s._feed(bytes(b))
        else:
            s._feed(slot)
        st = dict(s.hist[max(0, len(s.hist) - 1 - s.lag)])
        if s.trip_after is not None and s.sent >= s.trip_after:
            st["hbm_trip"] = 1
        if st["range_valid"] and st["range_seq"] in s.rerr:
            st["range_rerr"] = 1
        p = s.prev_rep
        if (s.stale_range and p is not None and st["range_seq"] != p["range_seq"]
                and st["range_seq"] not in s.staled):
            s.staled.add(st["range_seq"])
            for k in ("range_seq", "range_crc", "range_valid", "range_rerr"):
                st[k] = p[k]
        s.prev_rep = st
        tdo = bytearray(F.SLOT_BYTES)
        v = int.from_bytes(F.pack_status(st), "little") << s.status_offset
        tdo[:33] = v.to_bytes(33, "little")
        return bytes(tdo)

    def open_scan(s):
        assert s.state == "closed", "open_scan while %s" % s.state
        s.state = "open"; s.opens += 1
        s.misaligned = s.wrong
        s._shift(bytes(F.SLOT_BYTES))                 # the filler: one desync, TDO unread

    def send(s, slot):
        assert s.state == "open", "send while %s" % s.state
        assert len(slot) == F.SLOT_BYTES
        if s.drop_after is not None and s.sent >= s.drop_after:
            raise ConnectionError("fake link dropped")
        h = F.parse_header(slot)
        if s.first_seq_sent is None and h["magic"] == F.MAGIC_FRAME and (h["nwords"] or h["flags"]):
            s.first_seq_sent = h["seq"]
        fault = s.sent in s.faults
        tdo = s._shift(slot)
        s.sent += 1
        s.out.append((fault, tdo))

    def recv(s):
        assert s.state == "open", "recv while %s" % s.state
        assert s.out, "recv with nothing outstanding"
        fault, tdo = s.out.pop(0)
        if fault:
            s.state = "faulted"
            raise LinkFault("fake: injected bad CoE reply")
        return tdo

    def close_scan(s):
        assert s.state == "open", "close_scan while %s" % s.state
        assert not s.out, "close_scan with %d TDO unread" % len(s.out)
        s.state = "closed"

    def recover(s):
        s.out.clear()
        s.state = "closed"; s.recovers += 1

    def abort_close(s):
        """What CoeTransport.abort_close does: whatever state, end closed."""
        s.out.clear()
        if s.state != "closed":
            s.abort_closes += 1
        s.state = "closed"

@contextlib.contextmanager
def _link():
    """A bad CoE reply becomes LinkFault (recoverable). Everything else, the CoE
    client's guard refusals (TapProtocolError, IRNotAllowed) above all, propagates
    untouched: a refusal is never a link problem to recover around."""
    try:
        yield
    except coe.CoEError as e:
        if isinstance(e, coe.TapProtocolError):       # not a subclass today; stay safe
            raise
        raise LinkFault(str(e))

class CoeTransport:
    """The real board through the Task 8 CoE client (final API: start/resync, ir_scan,
    to_shift_dr, pipelined CMD_TDI send()/reply(), drain(), exit_dr_to_idle). `chain`
    lists the dies from TDI to TDO ("AB" or "BA"); `die` is the target. Main session
    only. `client` takes an already-made coe.CoE (tests build one on a fake socket);
    otherwise this dials `ip`.

    Alignment: `lead` BYPASS devices sit between TDI and the die, each delaying the
    data by one bit, so the scan opens with a 16384 - lead bit filler (one desync on
    the die) and later slots start on the die's slot boundary. The status word comes
    out `lead` + (devices between the die and TDO) bits into each command's TDO.

    PARKED RISK (review fix round 1, not fixed): if BOTH dies carry the loader
    bitstream, a wrong --chain selects USER4 on the OTHER die, whose status word is just
    as valid, so nothing here can tell and that die gets loaded. Telling them apart
    needs a die identity in the status word (an RTL/spec change)."""
    def __init__(s, ip, die, chain, hz=27_000_000, client=None):
        if len(chain) != coe.CHAIN_DEVICES or sorted(chain) != ["A", "B"] or die not in chain:
            raise ValueError("chain must be AB or BA and contain the die")
        s.c = client if client is not None else coe.CoE(ip)
        with _link():
            s.c.start(hz)                               # handshake, IDCODEs, resync -> RTI
        pos = chain.index(die)
        s.ops = [coe.IR_USER4 if d == die else coe.IR_BYPASS for d in chain]
        s.lead = pos
        s.tdo_delay = len(chain) - 1 - pos
        s.status_offset = s.lead + s.tdo_delay
        s.depth = 4
        s.pending = []

    def open_scan(s):
        """RTI -> select USER4 -> Shift-DR -> filler. Requires RTI (start(), close_scan()
        and recover() all end there); the client refuses anything else."""
        with _link():
            s.c.ir_scan(s.ops)
            s.c.to_shift_dr()
            n = FILLER_BITS - s.lead
            t = s.c.send(coe.CMD_TDI, coe.dr_payload(n, bytes((n + 7) // 8)))
            s.c.reply(t)

    def send(s, slot):
        if len(slot) != F.SLOT_BYTES:
            raise ValueError("a slot is %d bytes, got %d" % (F.SLOT_BYTES, len(slot)))
        with _link():
            s.pending.append(s.c.send(coe.CMD_TDI, coe.dr_payload(F.SLOT_BITS, slot)))

    def recv(s):
        t = s.pending.pop(0)
        with _link():
            _, d = s.c.reply(t)
        if len(d) != F.SLOT_BYTES:
            raise LinkFault("CoE reply txn %#06x carried %d bytes of TDO, expected %d"
                            % (t, len(d), F.SLOT_BYTES))
        return d

    def close_scan(s):
        while s.pending:
            s.recv()
        with _link():
            s.c.exit_dr_to_idle()

    def recover(s):
        """Task 8 review N2: after a pipelined failure, drain() then resync()."""
        s.pending = []
        with _link():
            s.c.drain()
            s.c.resync()

    def abort_close(s):
        """On an abort: read what is owed and leave Shift-DR, swallowing secondary
        errors (the abort's own reason is what the caller reports). From UNKNOWN the
        only legal move is resync(). A dead connection is left as it is."""
        s.pending = []
        for step in (lambda: s.c.drain(),
                     lambda: s.c.exit_dr_to_idle() if s.c.tap == coe.SHIFT_DR else None,
                     lambda: s.c.resync() if s.c.tap is coe.UNKNOWN else None):
            try:
                step()
            except Exception:
                pass

RANGE_BYTES_PER_POLL = 64 * 1024   # CRC bytes allowed per extra poll while waiting

class Loader:
    """Data phase: data frames pipelined `depth` deep, resync on a counter move,
    recover() on a LinkFault, until the die's status shows the last data frame.

    Range phase (fix round 1, I1+I3): one range frame at a time, then poll until the
    status carries THAT frame's own range_seq with range_valid=1 and busy=0, and
    compare its CRC with expected_range_crc(). Serialised because the CRC unit is
    slower than the wire on real pieces (review: >= 2.76 s of CRC against 2.11 s of
    range frames on the 9B card-0 manifest), and a pipelined burst backs range frames
    up in the FIFO until it overflows. The plan's own range frames go first, while
    their seqs are still uncommitted; any piece not checked in THIS run (its range
    frame committed by an earlier, interrupted run, or a result missed across a
    resync, or a resume onto a die whose last is already past the plan) is checked
    again with a fresh seq. A load is done only when every piece matched; any
    mismatch aborts naming the pieces. The die's status, never the checkpoint, says
    how far a load got; the checkpoint only binds a resume to the plan's sha."""
    def __init__(s, t, frames, plan_sha, ckpt_path, resume=False):
        if not frames or [f.seq for f in frames] != list(range(len(frames))):
            raise ValueError("frames must be plan_frames() output: seq 0..n-1 in order")
        s.t, s.frames, s.sha, s.ckpt, s.resume = t, frames, plan_sha, ckpt_path, resume
        s.ranges = [f for f in frames if f.kind == "range"]
        s.nd = len(frames) - len(s.ranges)
        if not s.ranges or s.nd == 0 or any(f.kind != "data" for f in frames[:s.nd]):
            raise ValueError("frames must be data frames, then one range frame per piece")
        s.resyncs = 0
        s.causes = []             # why each resync / recovery / resend happened
        s.st = None
        s.saved_last = None
        s.range_results = {}      # piece index -> (got or None on an HBM read error, want)
        s.already_complete = False

    def _slot(s, fr):
        if fr.kind == "range":
            return F.range_crc_slot(fr.seq, fr.addr, fr.n)
        return F.build_slot(fr.seq, fr.addr, read_payload(fr))

    def _take(s):
        """Read the oldest outstanding TDO. None if it carries no status word."""
        st = status_of(s.t.recv(), s.t.status_offset)
        if st["magic"] != F.MAGIC_STAT:
            return None
        if st["hbm_trip"]:
            raise LoadAborted("HBM catastrophic temperature trip reported at seq %d: stop "
                              "and check the card's cooling" % st["last"])
        if st["bresp_err"] != 0:
            # I2: a fresh configuration starts at 0, so any nonzero count means some
            # committed write failed -- in this run or one before it (a resume must not
            # absorb it into a baseline)
            raise LoadAborted("HBM write response error (BRESP count %d) by seq %d: "
                              "committed data is suspect; reload the bitstream and load "
                              "again" % (st["bresp_err"], st["last"]))
        s.st = st
        return st

    def _poll_settled(s):
        """Poll until SETTLE_EQUAL (2 x depth) consecutive good statuses agree, busy=0.

        Only used straight after an open_scan, whose filler always moves the desync
        count. If the status lags L slots behind the wire, a run of K equal statuses
        with K >= L + 1 cannot straddle the filler (that would contain a change), so
        it lies wholly after it and so reflects every slot sent before the filler.
        Two equal statuses (the brief's rule) are NOT enough under a lag: polls sent
        before the open (or the clamped start of a fresh status history) give equal
        stale pairs. 2 x depth covers the spec's 1-to-4-slot lag with margin."""
        need = 2 * s.t.depth
        prev, run, seen = None, 0, 0
        for _ in range(MAX_POLLS):
            s.t.send(F.poll_slot())
            st = s._take()
            if st is None:
                prev, run = None, 0
                continue
            seen += 1
            run = run + 1 if (st == prev and st["busy"] == 0) else (1 if st["busy"] == 0 else 0)
            prev = st
            if run >= need:
                return st
        if not seen:
            raise LoadAborted("no status word in %d polls: check --chain (die position "
                              "on the JTAG chain)" % MAX_POLLS)
        raise LoadAborted("status never settled in %d polls (busy=%d)" % (MAX_POLLS, prev["busy"] if prev else -1))

    def _poll_until(s, pred, base, polls=MAX_POLLS):
        """Poll until pred(status). Returns ("ok", st), ("err", st) if an error counter
        moved off `base`, or ("timeout", last good status or None)."""
        st = None
        for _ in range(polls):
            s.t.send(F.poll_slot())
            x = s._take()
            if x is None:
                continue
            st = x
            if _errs(st) != base:
                return "err", st
            if pred(st):
                return "ok", st
        return "timeout", st

    def _count_retry(s, why):
        s.resyncs += 1
        s.causes.append(why)
        if s.resyncs > MAX_RESYNCS:
            raise LoadAborted("giving up after %d resyncs; last cause: %s" % (MAX_RESYNCS, why))

    def _reopen(s, why, faulted):
        """Leave Shift-DR (or, after a LinkFault, drain and resync), re-enter it and
        settle. Each attempt counts against MAX_RESYNCS."""
        while True:
            s._count_retry(why)
            try:
                if faulted:
                    s.t.recover()
                else:
                    s.t.close_scan()
                s.t.open_scan()
                return s._poll_settled()
            except LinkFault as e:
                faulted, why = True, "link: %s" % e

    def _open(s):
        try:
            s.t.open_scan()
            return s._poll_settled()
        except LinkFault as e:
            return s._reopen("link: %s" % e, True)

    def _check_ckpt(s):
        if os.path.exists(s.ckpt):
            how = ("delete it to start a fresh load (the die's own status says how far a "
                   "load got, the file only binds --resume to a plan), or pass --ckpt for "
                   "this plan's checkpoint")
            try:
                with open(s.ckpt) as f:
                    ck = json.load(f)
            except (OSError, ValueError) as e:
                raise LoadAborted("the checkpoint %s is unreadable (%s): %s" % (s.ckpt, e, how))
            if not isinstance(ck, dict) or not isinstance(ck.get("plan_sha"), str):
                raise LoadAborted("%s is not a loader checkpoint: %s" % (s.ckpt, how))
            if ck["plan_sha"] != s.sha:
                raise LoadAborted("the checkpoint %s is for a different plan (%s): reload the "
                                  "bitstream to start over, or %s"
                                  % (s.ckpt, ck["plan_sha"][:12], how))
        elif s.resume:
            raise LoadAborted("--resume given but no checkpoint at %s" % s.ckpt)

    def _save_ckpt(s, last):
        tmp = s.ckpt + ".tmp"
        with open(tmp, "w") as f:
            json.dump(dict(plan_sha=s.sha, last=None if last == NONE else last), f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, s.ckpt)
        s.saved_last = last

    def _maybe_ckpt(s, st):
        last = st["last"]
        if last == NONE:
            return
        if s.saved_last in (None, NONE) or (last - s.saved_last) & M32 >= CKPT_EVERY:
            s._save_ckpt(last)

    def _aborting(s, fn):
        """Run fn; on LoadAborted close the scan cleanly first, then re-raise."""
        try:
            return fn()
        except LoadAborted:
            s.t.abort_close()
            raise

    def run_load(s):
        return s._aborting(s._run_load)

    def run_verify(s):
        return s._aborting(s._run_verify)

    def _data_phase(s, st):
        """Pipelined data frames until the status shows the last one committed."""
        lastd = s.nd - 1
        done = lambda x: x["last"] != NONE and x["last"] >= lastd and x["busy"] == 0
        nxt = 0 if st["last"] == NONE else st["last"] + 1
        base = _errs(st)
        inflight, stalls = 0, 0
        while True:
            try:
                while nxt < s.nd and inflight < s.t.depth:
                    s.t.send(s._slot(s.frames[nxt])); nxt += 1; inflight += 1
                if inflight == 0:
                    how, st = s._poll_until(done, base)
                    if how == "ok":
                        s._maybe_ckpt(st)
                        return st
                    if st is None:
                        raise LoadAborted("no status word while waiting for the data "
                                          "phase to finish: check --chain")
                    if how == "err":
                        st = s._reopen("error counters %s -> %s" % (base, _errs(st)), False)
                    else:
                        # frames vanished without moving a counter: resend the tail
                        s._count_retry("seq %d never committed" % lastd)
                    base, nxt = _errs(st), (0 if st["last"] == NONE else st["last"] + 1)
                    continue
                st = s._take(); inflight -= 1
                if st is None:
                    stalls += 1
                    if stalls > 2 * s.t.depth + 4:
                        raise LoadAborted("no status word for %d slots: check --chain" % stalls)
                    continue
                stalls = 0
                if _errs(st) != base:
                    why = "error counters %s -> %s at seq %d" % (base, _errs(st), st["last"])
                    while inflight:
                        s._take(); inflight -= 1
                    st = s._reopen(why, False)
                    base, nxt = _errs(st), (0 if st["last"] == NONE else st["last"] + 1)
                    continue
                s._maybe_ckpt(st)
            except LinkFault as e:
                inflight = 0
                st = s._reopen("link: %s" % e, True)
                base, nxt = _errs(st), (0 if st["last"] == NONE else st["last"] + 1)

    def _range_phase(s, st, use_plan_seqs):
        """Range-check every piece, one frame at a time (see the class docstring).
        Fills s.range_results; returns the last status."""
        s.range_results = {}
        first, final = s.ranges[0].seq, s.frames[-1].seq
        base = _errs(st)
        while len(s.range_results) < len(s.ranges):
            seq = (st["last"] + 1) & M32
            i = seq - first if use_plan_seqs and first <= seq <= final else None
            if i is None or i in s.range_results:
                i = next(k for k in range(len(s.ranges)) if k not in s.range_results)
            fr = s.ranges[i]
            try:
                s.t.send(F.range_crc_slot(seq, fr.addr, fr.n))
                s._take()
                pred = (lambda x, q=seq: x["range_seq"] == q and x["range_valid"] == 1 and
                        x["last"] == q and x["busy"] == 0)
                how, x = s._poll_until(pred, base, MAX_POLLS + fr.n // RANGE_BYTES_PER_POLL)
                if how == "ok":
                    want = expected_range_crc(fr)
                    s.range_results[i] = (None if x["range_rerr"] else x["range_crc"], want)
                    st = x
                    s._maybe_ckpt(st)
                    continue
                if x is None:
                    raise LoadAborted("no status word during the range phase: check --chain")
                if how == "timeout":
                    st = s._reopen("range CRC for seq %d never reported" % seq, False)
                else:
                    st = s._reopen("error counters %s -> %s in the range phase"
                                   % (base, _errs(x)), False)
            except LinkFault as e:
                st = s._reopen("link: %s" % e, True)
            base = _errs(st)
        return st

    def _mismatches(s):
        return [(s.ranges[i], got, want) for i, (got, want) in sorted(s.range_results.items())
                if got != want]

    def _run_load(s):
        s._check_ckpt()
        st = s._open()
        if st["last"] != NONE and not s.resume:
            raise LoadAborted("the die already holds frames up to seq %d; use --resume with "
                              "the same plan, or reload the bitstream" % st["last"])
        s._save_ckpt(st["last"])
        final = s.frames[-1].seq
        if st["last"] != NONE and st["last"] >= final:
            # every frame of the plan is committed (a finished load, maybe verified
            # since): nothing to send but the range checks, which decide
            s.already_complete = True
        else:
            st = s._data_phase(st)
        st = s._range_phase(st, use_plan_seqs=not s.already_complete)
        s._save_ckpt(st["last"])
        bad = s._mismatches()
        if bad:
            raise LoadAborted("%d of %d pieces failed the range CRC after loading: %s%s; "
                              "the die does not hold this plan, reload the bitstream and "
                              "load again"
                              % (len(bad), len(s.ranges),
                                 ", ".join("%#x+%d got %s want %08x"
                                           % (f.addr, f.n, "RERR" if g is None else "%08x" % g, w)
                                           for f, g, w in bad[:8]),
                                 " ..." if len(bad) > 8 else ""))
        try:
            s.t.close_scan()
        except LinkFault:
            s.t.recover()                              # every result is already in hand
        return st

    def _run_verify(s):
        """Range-CRC every piece again (fresh seqs continue after the die's last) and
        compare with the CRC of the blake2b-checked file bytes. Returns the mismatches
        as (Frame, got, want); got is None when the die reported an HBM read error.
        Refused on a die that does not hold the whole plan yet (C1): the writer commits
        range frames like any other, so a verify on a partial die would move `last`
        into the plan's data seqs and a later --resume would skip those frames."""
        st = s._open()
        if st["last"] == NONE or st["last"] < s.frames[-1].seq:
            raise LoadAborted("the die holds frames only up to seq %s, the plan needs %d: "
                              "finish the load (load --resume) before verify"
                              % ("none" if st["last"] == NONE else st["last"], s.frames[-1].seq))
        st = s._range_phase(st, use_plan_seqs=False)
        try:
            s.t.close_scan()
        except LinkFault:
            s.t.recover()
        return s._mismatches()

def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="Load or verify a Jungle Cat die's HBM over "
                                 "JTAG (main session only: this opens the board's JTAG).")
    ap.add_argument("cmd", choices=["load", "verify"])
    ap.add_argument("manifest")
    ap.add_argument("--bmc", required=True, help="BMC address, e.g. 192.0.2.1 (no default)")
    ap.add_argument("--die", required=True, choices=["A", "B"])
    ap.add_argument("--chain", required=True, choices=["AB", "BA"],
                    help="dies in order from TDI to TDO, measured at bring-up. RISK: if "
                    "both dies carry the loader, a wrong --chain loads the other die "
                    "undetected")
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--ckpt", default=None)
    a = ap.parse_args(argv)
    frames, sha = plan_frames(a.manifest, die=a.die)
    ck = a.ckpt or "/mnt/storage/fk33_builds/jc_load/%s_%s.json" % (sha[:12], a.die)
    os.makedirs(os.path.dirname(os.path.abspath(ck)), exist_ok=True)
    t0 = time.time()
    try:
        t = CoeTransport(a.bmc, a.die, a.chain)
        ld = Loader(t, frames, sha, ck, resume=a.resume)
        if a.cmd == "load":
            st = ld.run_load()
            n = sum(f.n for f in frames if f.kind == "data")
            dt = max(time.time() - t0, 1e-9)
            if ld.already_complete:
                print("JCLOAD_DONE already complete: %d pieces re-checked by range CRC, "
                      "last=%d resyncs=%d %.0f s" % (len(ld.range_results), st["last"],
                                                     ld.resyncs, dt))
            else:
                print("JCLOAD_DONE last=%d committed=%d crc_fail=%d resyncs=%d pieces=%d "
                      "matched %.0f s %.2f MB/s" % (st["last"], st["committed"],
                      st["crc_fail"], ld.resyncs, len(ld.range_results), dt, n / dt / 1e6))
            return 0
        bad = ld.run_verify()
    except (LoadAborted, LinkFault) as e:
        print("JCLOAD_ABORT %s" % e)
        return 2
    except (ConnectionError, TimeoutError, OSError) as e:
        print("JCLOAD_ABORT connection lost (%s: %s); the die keeps what it committed: "
              "run again with --resume" % (type(e).__name__, e))
        return 2
    for fr, got, want in bad[:20]:
        print("JCVERIFY_BAD addr=%#x n=%d got=%s want=%08x"
              % (fr.addr, fr.n, "RERR" if got is None else "%08x" % got, want))
    print("JCVERIFY_%s %d pieces, %d bad" % ("PASS" if not bad else "FAIL",
          sum(1 for f in frames if f.kind == "range"), len(bad)))
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
