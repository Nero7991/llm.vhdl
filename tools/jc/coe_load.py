#!/usr/bin/env python3
"""Load a weight image into a Jungle Cat die's HBM over JTAG (plan Tasks 8 and 9).

    coe_load.py identify --bmc 192.0.2.1 --chain AB|BA --die A|B --dies DIES.json [--force]
    coe_load.py load   MANIFEST.json --bmc 192.0.2.1 --die A|B --chain AB|BA --dies DIES.json [--resume]
                [--append]
                [--reconnect-secs 270] [--max-reconnects 50]
    coe_load.py verify MANIFEST.json --bmc 192.0.2.1 --die A|B --chain AB|BA --dies DIES.json

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

Task 9b (Oren 2026-10-05): die identity. With the loader on BOTH dies, (die=A,
chain=AB) and (die=B, chain=BA) put identical traffic on the wire, so a wrong --chain
used to load the other die with nothing noticing. The status word is now 384 bits and
carries each die's 96-bit DNA_PORTE2 value ([351:256], dna_valid [352]). `identify`
records die name -> DNA once at bring-up in a JSON file OUTSIDE the repo (no DNA from
real hardware is ever committed); `load` and `verify` require that file (--dies) and, on
every scan open, wait for dna_valid and abort unless the die answering at the selected
chain position has the recorded DNA. Every status after that must carry the same DNA.
The checkpoint records the DNA too, and a checkpoint for another DNA is refused before
the board is touched.

Task 9 final-review minors, folded into 9b: the range-CRC wait is time-based (from the
transport's TCK rate), keeps polling while the die shows its own range frame committed
and the CRC unit busy instead of re-requesting the CRC, accepts a result a reopen's
settled status already carries, and retries a piece once with a fresh seq after an HBM
read error (RRESP) before reporting it.

Fix round 3 (final review, 2026-10-05), host-only, no RTL/Vivado change:
  1. `--hz` on load/verify/identify (default 27_000_000, refused above it or at/below
     zero), passed to CoeTransport. Every range-wait budget already reads it off the
     transport (`t.hz`, `range_polls`); this is what lets --hz actually move them.
  2. The `dna_valid` timeout now also names HBM calibration (`hbm_ready0/1` holds the
     loader core in reset until both stacks calibrate; LED_B is off until then), not
     only "the die is not the loader" -- both are live explanations on real hardware.
  3. MAX_RESYNCS is now a floor, not a hard cap: `--max-resyncs` (default 8, >= 1) sets
     it, and the budget REFILLS -- an extra `--max-resyncs` is granted per 100,000 data
     frames the die's own status shows committed this run (`_Session.max_committed`,
     updated from every status word read, including through a resume). A short run sees
     the bare floor; a multi-GB load earns a proportionally larger allowance for
     transient events without raising the floor for a run that never gets that far.
  4. `identify` now also prints the bit-reversed 96-bit DNA, labelled as such and as an
     ESTIMATE (the reader's bit order is unconfirmed; Task 11 cross-checks it against
     Vivado hardware manager). Printed only; the die record still stores the
     un-reversed value `read_identity`/`_take` always reported -- nothing about what is
     recorded, matched, or checked changes.
  5. `plan_frames` (planning: manifest parse, hashing, preflight) now runs inside
     main()'s own try/except, alongside dna_for and the checkpoint path's repo check: a
     PlanError or a missing/unreadable manifest prints the `JCLOAD_ABORT` sentinel and
     exits nonzero, the same as every other abort, instead of an uncaught traceback.
  6. Each piece's expected range CRC is now computed ONCE, during plan_frames's own
     hashing pass (the same streaming read that computes the manifest's blake2b check),
     and frozen on the Frame (`exp_crc`) for a "range" frame. `expected_range_crc`
     returns that stored value and reads nothing: before this, it (like `read_payload`
     for the data send) re-read the file at compare time, so a file rewritten after
     planning moved the "expected" value right along with the actual send, and the
     blake2b check done at planning time caught nothing. `read_payload` still reads the
     file live at send time (unavoidable -- that is what is actually transmitted), so
     the rewritten bytes still reach the die; the range compare is what now catches the
     mismatch. `plan_sha` is unchanged by this: it still folds in only
     (file, addr, file_offset, nbytes, blake2b_128, die, MAX_PAYLOAD_BYTES) -- a derived
     CRC is not identity data, so two manifests that plan identically still resume
     against the same checkpoint.

Reconnect (2026-10-07, host-only). MEASURED (docs/debugging/2026-10-05_jc-jtag-axi-host-
path-is-latency-bound.md S14-S15): the BMC ends every CoE connection after ~310-320 s
whatever the data rate, alternately by RST and by going silent. A whole die used to take
~10 `load --resume` invocations, each re-planning (re-hashing ~7 GB) first. Now one
`load`/`verify` runs to completion by itself, with the plan built once:
  - proactive: `--reconnect-secs` (default 270, 30 <= s <= 300, 0 disables), counted
    from the moment the current connection's scan settled (fix round 1: not from
    start(), so a slow settle cannot livelock; NO_PROGRESS_ROTATIONS rotations in a row
    with nothing committed and no piece checked abort). When it is reached, at a
    clean point (between slots, never with a frame half-sent): read every outstanding
    reply, leave Shift-DR through close_scan (the client's vetted exit_dr_to_idle),
    close the socket, open a new connection (a fresh CoeTransport: start() flushes
    stale replies and resyncs from UNKNOWN), open the scan, and settle -- which
    re-checks the die's DNA exactly as on any scan open -- then continue from the
    die's own committed seq.
  - reactive: a link-level failure (ConnectionError, TimeoutError, any OSError from the
    transport, wrapped as LinkLost so a file error is never mistaken for one) closes
    the dead socket and reconnects the same way, up to `--max-reconnects` (default 50)
    per run. Neither kind counts against --max-resyncs. Each prints one line,
    `JCLOAD_RECONNECT n reason secs_on_connection`. RECONNECT_TRIES consecutive failed
    attempts (dial, start, scan open or settle) abort with the connection-lost message,
    which says to run again with --resume.
The CoE client's JTAG guard is untouched: every new connection goes through start() and
only the vetted calls CoeTransport already used.
"""
import argparse, collections, contextlib, hashlib, json, math, os, re, sys, time, zlib
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33", "host"))
from jc import jc_frame as F
from jc import coe
import fk33_load_weights as FLW

Frame = collections.namedtuple("Frame", "seq addr path off n kind raw_n exp_crc")

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
        raw_pieces = list(FLW.pieces_of(e))
        offs = [int(p["file_offset"]) for p in raw_pieces]
        lens = [int(p["nbytes"]) for p in raw_pieces]
        # One read of the file: the whole-file blake2b digest (the manifest's own
        # integrity check) AND, in the same streaming pass, each piece's raw-byte
        # CRC32 run (fix round 3 item 6) -- never re-read later for the range compare,
        # so a file rewritten after this point cannot move the "expected" value along
        # with it.
        dig = hashlib.blake2b(digest_size=16)
        crc = [0] * len(raw_pieces)
        pos = 0
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 24), b""):
                dig.update(chunk)
                end = pos + len(chunk)
                for i in range(len(raw_pieces)):
                    lo, hi = max(pos, offs[i]), min(end, offs[i] + lens[i])
                    if lo < hi:
                        crc[i] = zlib.crc32(chunk[lo - pos:hi - pos], crc[i])
                pos = end
        if dig.hexdigest() != e["blake2b_128"]:
            raise PlanError("%s hashes to %s, the manifest says %s"
                            % (e["file"], dig.hexdigest(), e["blake2b_128"]))
        declared = e.get("stack")
        header_addr = int(e["hbm_offset"])
        if declared is not None and int(declared) != _stack_of(header_addr):
            raise PlanError("%s declares stack %s, its header at %#x is actually in "
                            "stack %d" % (e["file"], declared, header_addr, _stack_of(header_addr)))
        for i, p in enumerate(raw_pieces):
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
            padded = (n + 31) // 32 * 32
            pcrc = crc[i]
            if padded > n:
                pcrc = zlib.crc32(bytes(padded - n), pcrc)
            pieces.append((addr, path, foff, n, pcrc & 0xFFFFFFFF))
            h.update(("%s %d %d %d %s\n" % (e["file"], addr, foff, n, e["blake2b_128"])).encode())
    pieces.sort()
    for (a0, _, _, n0, _), (a1, _, _, _, _) in zip(pieces, pieces[1:]):
        if a0 + (n0 + 31) // 32 * 32 > a1:
            raise PlanError("pieces overlap after padding: %#x+%d reaches %#x" % (a0, n0, a1))
    seq = 0
    for addr, path, foff, n, _ in pieces:
        k = 0
        while k < n:
            m = min(F.MAX_PAYLOAD_BYTES, n - k)
            frames.append(Frame(seq, addr + k, path, foff + k, m, "data", m, None)); seq += 1
            k += m
    for addr, path, foff, n, exp_crc in pieces:
        frames.append(Frame(seq, addr, path, foff, (n + 31) // 32 * 32, "range", n, exp_crc)); seq += 1
    return frames, h.hexdigest()

def read_payload(fr):
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        return fh.read(fr.n)

def expected_range_crc(fr):
    """The piece's range CRC (over its real `raw_n` bytes, zero-padded to the frame's
    32-byte length `n` -- the same padding jc_frame.build_slot applies before the writer
    commits whole words), computed ONCE by plan_frames during its hashing pass and
    frozen on the Frame as `exp_crc` (fix round 3 item 6). Returns that stored value;
    reads nothing. A Frame not produced by plan_frames (or a "data" frame, which has no
    range CRC) has no stored value and is refused rather than silently re-derived."""
    if fr.exp_crc is None:
        raise ValueError("expected_range_crc: %r has no stored exp_crc (not a range "
                          "frame from plan_frames)" % (fr,))
    return fr.exp_crc


# ====================================================================== Task 9

FILLER_BITS = F.SLOT_BITS
MAX_RESYNCS = 8           # resyncs/recoveries/tail resends: the floor (--max-resyncs)
REFILL_FRAMES = 100_000   # frames committed per extra MAX_RESYNCS granted (fix round 3 item 3)
MAX_POLLS = 32            # status polls per wait; small so a wrong --chain fails fast
CKPT_EVERY = 1000         # frames between checkpoint writes
RECONNECT_SECS = 270      # proactive reconnect after this long on one connection (--reconnect-secs)
RECONNECT_SECS_MAX = 300  # the BMC ends a connection at ~310-320 s (MEASURED, S15)
RECONNECT_SECS_MIN = 30   # floor (fix round 1 item 1): a rotation must leave time to work
NO_PROGRESS_ROTATIONS = 3 # consecutive proactive rotations with no progress: abort
RECONNECT_SETTLE_SECS = 1.0  # after a lost link, before dialing (the BMC drops the old session)
MAX_RECONNECTS = 50       # reactive reconnects per run (--max-reconnects)
RECONNECT_TRIES = 5       # consecutive failed reconnect attempts before giving up
RECONNECT_BACKOFF = 2.0   # seconds; attempt k waits k * this before the next
NONE = 0xFFFFFFFF         # status "last committed seq" before anything committed
M32 = 0xFFFFFFFF

class LoadAborted(Exception):
    pass

class LinkLost(ConnectionError):
    """The connection itself is gone (RST, silence past the socket timeout, a poisoned
    client): what the transport raised, as `orig`. Raised only by _Guarded, around
    transport calls, so an OSError from a manifest file or a checkpoint write is never
    taken for one."""
    def __init__(s, orig):
        ConnectionError.__init__(s, "%s: %s" % (type(orig).__name__, orig))
        s.orig = orig

class _Guarded:
    """The Loader's handle on one connection: transport calls that fail at the link
    level (OSError, ConnectionError and TimeoutError included) raise LinkLost instead.
    LinkFault, the CoE guard's refusals and everything else pass through untouched."""
    def __init__(s, t):
        s.raw = t
    def __getattr__(s, k):
        return getattr(s.raw, k)
    def _call(s, fn, *a):
        try:
            return fn(*a)
        except OSError as e:
            if isinstance(e, LinkLost):
                raise
            raise LinkLost(e)
    def open_scan(s):
        return s._call(s.raw.open_scan)
    def send(s, slot):
        return s._call(s.raw.send, slot)
    def recv(s):
        return s._call(s.raw.recv)
    def close_scan(s):
        return s._call(s.raw.close_scan)
    def recover(s):
        return s._call(s.raw.recover)
    def abort_close(s):
        try:
            s.raw.abort_close()
        except Exception:
            pass
    def close(s):
        try:
            s.raw.close()
        except Exception:
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
    nb = (F.STATUS_BITS + offset + 7) // 8
    v = int.from_bytes(tdo[:nb], "little") >> offset
    return F.parse_status((v & ((1 << F.STATUS_BITS) - 1)).to_bytes(F.STATUS_BYTES, "little"))

# ---------------------------------------------------------------- die record (Task 9b)

DIE_NAMES = ("A", "B")
_DNA_HEX = re.compile(r"[0-9a-fA-F]{24}")        # used with fullmatch (M3)

def _no_dup_keys(pairs):
    keys = [k for k, _ in pairs]
    dup = sorted(set(k for k in keys if keys.count(k) > 1))
    if dup:
        raise ValueError("duplicate key(s) %s" % ", ".join(dup))
    return dict(pairs)

def dna_hex(v):
    return "%024x" % v

def dna_mask(v):
    """A DNA as printed by load/verify (fix round 1, M6): first and last 4 hex digits
    only. Only identify prints the full value."""
    h = dna_hex(v)
    return "%s...%s" % (h[:4], h[-4:])

def dna_bitrev(v):
    """The DNA with its F.DNA_BITS (96) bits reversed end for end. Fix round 3 item 4:
    identify also prints this, labelled as such and as an ESTIMATE -- the reader's bit
    order is not yet confirmed; Task 11 cross-checks it against Vivado hardware
    manager. Printed only: it never reaches the die record or any comparison."""
    n = F.DNA_BITS
    out = 0
    for i in range(n):
        out |= ((v >> i) & 1) << (n - 1 - i)
    return out

def _git_root_above(path):
    """The first directory at or above the RESOLVED parent of `path` holding a `.git`
    entry (a checkout's directory or a worktree's file), else None."""
    d = os.path.dirname(os.path.realpath(path))
    while True:
        if os.path.lexists(os.path.join(d, ".git")):
            return d
        up = os.path.dirname(d)
        if up == d:
            return None
        d = up

def _outside_repo(path, what="the die record"):
    """Files holding a real DNA (the die record, a checkpoint) must never sit inside ANY
    git checkout or worktree, this one or another (fix round 1, I1): refuse a path whose
    resolved parent chain holds a `.git` file or directory."""
    root = _git_root_above(path)
    if root is not None:
        raise LoadAborted("%s %s is inside a git checkout or worktree (%s has a .git entry): "
                          "keep it outside every repository, no DNA from real hardware is "
                          "ever committed" % (what, path, root))

def read_dies(path, must_exist=True):
    """Parse a die record: JSON {"A": "<24 hex digits>", "B": "<24 hex digits>"}, either
    key may be absent. Returns {name: int}. Anything else is refused (LoadAborted)."""
    _outside_repo(path)
    if not os.path.exists(path):
        if must_exist:
            raise LoadAborted("no die record at %s: run `coe_load.py identify` for each die "
                              "once at bring-up (see identify --help)" % path)
        return {}
    try:
        with open(path) as f:
            d = json.load(f, object_pairs_hook=_no_dup_keys)
    except (OSError, ValueError) as e:
        raise LoadAborted("the die record %s is unreadable (%s)" % (path, e))
    if not isinstance(d, dict) or not set(d) <= set(DIE_NAMES):
        raise LoadAborted("the die record %s must be a JSON object with keys from %s"
                          % (path, "/".join(DIE_NAMES)))
    out = {}
    for k, v in d.items():
        if not isinstance(v, str) or not _DNA_HEX.fullmatch(v):
            raise LoadAborted("the die record %s: die %s must be 24 hex digits (96 bits), "
                              "got %r" % (path, k, v))
        out[k] = int(v, 16)
    if len(out) == 2 and out["A"] == out["B"]:
        raise LoadAborted("the die record %s gives dies A and B the same DNA: it is wrong, "
                          "redo identify for both dies" % path)
    return out

def dna_for(path, die):
    rec = read_dies(path)
    if die not in rec:
        raise LoadAborted("die %s is not in the die record %s: run `coe_load.py identify "
                          "--bmc IP --chain AB|BA --die %s --dies %s` once at bring-up, "
                          "cross-checked as identify --help describes" % (die, path, die, path))
    return rec[die]

def write_dies(path, rec):
    _outside_repo(path)
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({k: dna_hex(v) for k, v in sorted(rec.items())}, f, indent=1)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)

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
    setting, a dropped connection (`drop_after` sends), and (Task 9b) a die identity
    that is not yet valid for the first `dna_valid_after` slots shifted. The die's
    DNA itself is the model's (`model.dna`, `model.dna_valid`).

    Reconnect (2026-10-07): `drop_after` ends the connection RST-like (that send
    raises ConnectionResetError, nothing shifted); `silent_after` ends it silence-like
    (slots still reach the die, but no reply comes: the first recv owed one raises
    TimeoutError). Either way the connection is then dead, as the CoE client's poison
    makes it: every later call raises ConnectionError. `close()` closes the socket
    (`gone`); any call after it fails the test. `on_shift` runs once per slot shifted
    (a test's fake clock). `lost_after` (fix round 1 item 5): later sends are accepted
    but never reach the die (lost in flight), and the first recv owed on one times
    out. `accepted_seqs`, `shifted_seqs` and `unshifted_seqs` record the real frames'
    seqs: every send that returned, those of them that reached the die, and those lost.

    `model` is a LoaderModel, or (fix round 1) a jc_model.FifoOverflowModel built with
    `crc_ticks_per_byte`: then every slot shifted advances its clock one tick, so the
    CRC unit's busy time and the finite FIFO behind it are modelled too.

    It also enforces the same protocol CoeTransport's CoE client does: open_scan only
    when closed; send/recv only while open; close_scan only with every TDO read;
    after a LinkFault nothing but recover(). A loader that breaks the order fails
    with AssertionError here instead of passing against a lenient fake."""
    def __init__(s, model, lead, lag_slots=2, fail_seqs=(), drop_after=None,
                 wrong_lead=False, drop_seqs=(), desync_seqs=(), fault_sends=(),
                 trip_after=None, fail_forever=False, rerr_seqs=(), stale_range=False,
                 dna_valid_after=0, hz=27_000_000, silent_after=None, on_shift=None,
                 lost_after=None):
        s.m, s.lead, s.lag = model, lead, lag_slots
        s.fail = set(fail_seqs); s.fail_forever = fail_forever
        s.drop = set(drop_seqs); s.desync = set(desync_seqs); s.faults = set(fault_sends)
        s.drop_after, s.wrong, s.trip_after = drop_after, wrong_lead, trip_after
        s.rerr = set(rerr_seqs); s.stale_range = stale_range
        s.prev_rep, s.staled = None, set()
        s.depth, s.status_offset = 4, 1
        s.hz, s.dna_valid_after, s.nshift = hz, dna_valid_after, 0
        s.hist, s.out, s.sent, s.first_seq_sent = [], [], 0, None
        s.state, s.opens, s.recovers, s.abort_closes = "closed", 0, 0, 0
        s.misaligned = False
        s.silent_after, s.on_shift, s.lost_after = silent_after, on_shift, lost_after
        s.accepted_seqs, s.shifted_seqs, s.unshifted_seqs = [], [], []
        s.dead, s.gone = None, False
        s._feed = getattr(model, "feed_slot", None) or model.feed
        s._status = getattr(model, "loader_status", None) or model.status
        s._tick = getattr(model, "tick", None)

    def _shift(s, slot):
        """One slot on the wire: what the die does with it, and the TDO it returns."""
        if s._tick is not None:
            s._tick(1)
        if s.on_shift is not None:
            s.on_shift()
        s.nshift += 1
        h0 = dict(s._status())
        if s.nshift <= s.dna_valid_after:
            h0["dna"], h0["dna_valid"] = 0, 0
        s.hist.append(h0)
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
        nb = (F.STATUS_BITS + s.status_offset + 7) // 8
        tdo[:nb] = v.to_bytes(nb, "little")
        return bytes(tdo)

    def _alive(s, what):
        assert not s.gone, "%s after close()" % what
        if s.dead:
            raise ConnectionError("fake: connection is dead (%s)" % s.dead)

    def open_scan(s):
        s._alive("open_scan")
        assert s.state == "closed", "open_scan while %s" % s.state
        s.state = "open"; s.opens += 1
        s.misaligned = s.wrong
        s._shift(bytes(F.SLOT_BYTES))                 # the filler: one desync, TDO unread

    def send(s, slot):
        s._alive("send")
        assert s.state == "open", "send while %s" % s.state
        assert len(slot) == F.SLOT_BYTES
        if s.drop_after is not None and s.sent >= s.drop_after:
            s.dead = "reset"
            raise ConnectionResetError("fake link reset")
        h = F.parse_header(slot)
        real = h["magic"] == F.MAGIC_FRAME and (h["nwords"] or h["flags"])
        if s.lost_after is not None and s.sent >= s.lost_after:
            if real:
                s.accepted_seqs.append(h["seq"]); s.unshifted_seqs.append(h["seq"])
            s.sent += 1
            s.out.append(("silent", None))           # never shifted, never answered
            return
        if s.first_seq_sent is None and real:
            s.first_seq_sent = h["seq"]
        fault = s.sent in s.faults
        if s.silent_after is not None and s.sent >= s.silent_after:
            fault = "silent"
        if real:
            s.accepted_seqs.append(h["seq"]); s.shifted_seqs.append(h["seq"])
        tdo = s._shift(slot)
        s.sent += 1
        s.out.append((fault, tdo))

    def recv(s):
        s._alive("recv")
        assert s.state == "open", "recv while %s" % s.state
        assert s.out, "recv with nothing outstanding"
        fault, tdo = s.out.pop(0)
        if fault == "silent":
            s.dead = "silent"
            raise TimeoutError("timed out")
        if fault:
            s.state = "faulted"
            raise LinkFault("fake: injected bad CoE reply")
        return tdo

    def close_scan(s):
        s._alive("close_scan")
        assert s.state == "open", "close_scan while %s" % s.state
        assert not s.out, "close_scan with %d TDO unread" % len(s.out)
        s.state = "closed"

    def recover(s):
        s._alive("recover")
        s.out.clear()
        s.state = "closed"; s.recovers += 1

    def abort_close(s):
        """What CoeTransport.abort_close does: whatever state, end closed."""
        s.out.clear()
        if s.state != "closed":
            s.abort_closes += 1
        s.state = "closed"

    def close(s):
        """What CoeTransport.close does: the socket is closed; nothing may follow."""
        s.out.clear()
        s.gone = True

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

    Die identity (Task 9b): if BOTH dies carry the loader, a wrong --chain selects USER4
    on the OTHER die, whose status word is just as valid; this transport cannot tell.
    The Loader can: every status carries the die's DNA, checked against the die record
    on every scan open.

    `user` (2026-10-07, jc_broker.py) picks the target's USER register: 4 (the default,
    the loader) or 3 (the USER3 control core). Nothing else changes with it; the default
    path's bytes on the wire are unchanged."""
    def __init__(s, ip, die, chain, hz=27_000_000, client=None, user=4):
        if len(chain) != coe.CHAIN_DEVICES or sorted(chain) != ["A", "B"] or die not in chain:
            raise ValueError("chain must be AB or BA and contain the die")
        if type(user) is not int or user not in (3, 4):
            raise ValueError("user must be 3 (USER3) or 4 (USER4), got %r" % (user,))
        s.c = client if client is not None else coe.CoE(ip)
        s.hz = hz
        s.pending = []
        try:
            with _link():
                s.c.start(hz)                           # handshake, IDCODEs, resync -> RTI
        except BaseException:
            s.close()                                   # fix round 1 item 3: never leak it
            raise
        pos = chain.index(die)
        ir = coe.IR_USER4 if user == 4 else coe.IR_USER3
        s.ops = [ir if d == die else coe.IR_BYPASS for d in chain]
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

    def close(s):
        """Close the socket (no JTAG traffic). The loader calls it after close_scan has
        left Shift-DR (a proactive reconnect) or on a connection already lost; this
        client is never used again, a new connection is a new CoeTransport."""
        s.pending = []
        sock = getattr(s.c, "s", None)
        if sock is not None and hasattr(sock, "close"):
            try:
                sock.close()
            except OSError:
                pass

# Range-CRC wait (Task 9 review M1/M3, folded into 9b), TIME-based from the transport's
# TCK rate. The RTL-derived CRC rate is ~340 MB/s (the review's pessimistic 512 bytes per
# 1.5 us). The wait first allows a piece MAX_POLLS polls plus its CRC at RANGE_EXPECT_BPS;
# past that it keeps polling only while the die shows the range frame committed and the
# CRC unit busy, up to the piece at RANGE_FLOOR_BPS, then gives up.
RANGE_EXPECT_BPS = 100e6
RANGE_FLOOR_BPS = 1e6

def range_polls(nbytes, bps, hz):
    """Polls (one 16,384-bit slot each at `hz` TCK) covering nbytes of CRC at bps."""
    return MAX_POLLS + math.ceil(nbytes / bps / (F.SLOT_BITS / hz))

class _Session:
    """What every scan does, for the Loader and for `identify`: read the lagged status
    out of each TDO, settle after an open, and (Task 9b) establish the die's identity.

    `dna` is the DNA the die at this chain position must have (from the die record);
    None only for `identify`, which reads it instead. `health` turns on the HBM trip and
    BRESP aborts in _take (the Loader's; identify only reads the identity)."""
    def __init__(s, t, dna, dna_label="the die record", health=True):
        if dna is not None and not (isinstance(dna, int) and 0 <= dna < 1 << F.DNA_BITS):
            raise ValueError("dna must be a %d-bit integer" % F.DNA_BITS)
        s.t, s.dna, s.dna_label, s.health = t, dna, dna_label, health
        s.identified = False
        s.st = None
        s.seq_base = 0            # load --append: wire seq = plan seq + seq_base (2026-10-09)
        s.max_piece = 0           # bytes; the Loader sets its largest range piece
        s.max_committed = 0       # highest "committed" any status has shown (fix round 3 item 3)

    def _dna_mismatch(s, got):
        when = ("the die changed under the run" if s.identified else
                "found before any data frame was sent; a wrong --chain selects the other die")
        return ("die identity mismatch: the die at this chain position reports DNA %s, "
                "but %s says it is %s (%s): check --chain and --die"
                % (dna_mask(got), s.dna_label, dna_mask(s.dna), when))

    def _wire(s, seq):
        """A plan seq as it goes on the wire (load --append offsets it by seq_base)."""
        return (seq + s.seq_base) & M32

    def _to_plan(s, st):
        """The die's status with every seq field (last, range_seq) moved from wire space
        into plan space: the ONE place the Loader's view of a seq is made, so its index
        arithmetic, range phase and checkpoints never see the offset. With seq_base 0
        this is the identity. A wire last of seq_base - 1 (the earlier plan's final
        frame) means none of this plan: NONE. A wire last below that (or the die's own
        NONE) means the die lost the earlier plan's frames under the run."""
        b = s.seq_base
        if b == 0:
            return st
        raw = st["last"]
        if raw == NONE or raw < b - 1:
            raise LoadAborted("the die's last committed seq went to %s, below this append's "
                              "base %d: the die was reset or reconfigured mid-run; reload "
                              "the bitstream and load every image again"
                              % ("none" if raw == NONE else raw, b))
        st = dict(st)
        st["last"] = NONE if raw == b - 1 else raw - b
        st["range_seq"] = (st["range_seq"] - b) & M32
        return st

    def _take(s):
        """Read the oldest outstanding TDO. None if it carries no status word.

        Task 9b: once this scan's die has been identified, every status must carry
        dna_valid = 1 and the same DNA; anything else means the die was reset,
        reconfigured or swapped under the run. Before that, a status that already shows
        a valid DNA other than the expected one aborts at once."""
        st = status_of(s.t.recv(), s.t.status_offset)
        if st["magic"] != F.MAGIC_STAT:
            return None
        st = s._to_plan(st)
        if st["committed"] > s.max_committed:
            s.max_committed = st["committed"]
        if s.dna is not None:
            if st["dna_valid"] and st["dna"] != s.dna:
                raise LoadAborted(s._dna_mismatch(st["dna"]))
            if s.identified and not st["dna_valid"]:
                raise LoadAborted("the die's identity went invalid (dna_valid = 0) after it "
                                  "was checked: the die was reset or reconfigured mid-run; "
                                  "reload the bitstream and load again")
        if not s.health:
            s.st = st
            return st
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
        stale pairs. 2 x depth covers the spec's 1-to-4-slot lag with margin.

        Task 9b (M1): a reopen can land while the CRC unit is still busy on a big piece
        (longer than MAX_POLLS slots at a slow CRC). Every status that still reports busy
        grants a fresh MAX_POLLS polls from that point, up to the largest piece at
        RANGE_FLOOR_BPS in total."""
        need = 2 * s.t.depth
        cap = max(MAX_POLLS, range_polls(s.max_piece, RANGE_FLOOR_BPS, s.t.hz))
        prev, run, seen, until = None, 0, 0, MAX_POLLS
        for k in range(cap):
            if prev is not None and prev["busy"] == 1:
                until = k + MAX_POLLS
            if k >= until:
                break
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
        raise LoadAborted("status never settled in %d polls (busy=%d)" % (k + 1, prev["busy"] if prev else -1))

    def _identify(s, st):
        """After a settled open: wait (bounded) for dna_valid, then require the DNA to be
        the expected one. Returns the newest status."""
        polls = 0
        while not st["dna_valid"]:
            if polls >= MAX_POLLS:
                raise LoadAborted("the die's identity (dna_valid) never became valid in %d "
                                  "polls: the bitstream's DNA reader is not running or the "
                                  "die is not the loader, or HBM has not finished calibrating "
                                  "(the core is held in reset until both stacks calibrate; "
                                  "LED_B off); check the bitstream" % MAX_POLLS)
            s.t.send(F.poll_slot())
            x = s._take()
            polls += 1
            if x is not None:
                st = x
        if s.dna is not None and st["dna"] != s.dna:
            raise LoadAborted(s._dna_mismatch(st["dna"]))
        s.identified = True
        return st

    def _settle(s):
        return s._identify(s._poll_settled())

class Loader(_Session):
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
    def __init__(s, t, frames, plan_sha, ckpt_path, resume=False, *, dna, append=False,
                 dna_label="the die record", max_resyncs=MAX_RESYNCS, corrupt_seq=None,
                 connect=None, reconnect_secs=0, max_reconnects=MAX_RECONNECTS,
                 clock=None, sleep=None, log=None):
        """`connect` makes a NEW connection (a CoeTransport, whose constructor runs
        start()); None means no reconnect at all (a lost link ends the run, as before).
        `reconnect_secs` > 0 turns on the proactive reconnect; `max_reconnects` bounds
        the reactive ones. `clock`, `sleep` and `log` are injectable for tests."""
        if dna is None:
            raise ValueError("the Loader needs the die's expected DNA (from --dies)")
        if append and resume:
            raise ValueError(APPEND_RESUME_REFUSED)
        if max_resyncs < 1:
            raise ValueError("max_resyncs must be >= 1, got %r" % (max_resyncs,))
        if not (reconnect_secs == 0 or RECONNECT_SECS_MIN <= reconnect_secs <= RECONNECT_SECS_MAX):
            raise ValueError("reconnect_secs must be 0 (off) or in [%d, %d], got %r"
                             % (RECONNECT_SECS_MIN, RECONNECT_SECS_MAX, reconnect_secs))
        if max_reconnects < 0:
            raise ValueError("max_reconnects must be >= 0, got %r" % (max_reconnects,))
        _Session.__init__(s, _Guarded(t), dna, dna_label)
        s.connect, s.reconnect_secs, s.max_reconnects = connect, reconnect_secs, max_reconnects
        s.clock = clock if clock is not None else (lambda: time.monotonic())
        s.sleep = sleep if sleep is not None else (lambda secs: time.sleep(secs))
        s.log = log if log is not None else (lambda line: print(line, flush=True))
        s.conn_t0 = s.clock()     # restarted by _connected() once the scan has settled
        s.connections = 1
        s.reconnects = 0          # every reconnect, proactive or reactive
        s.lost = 0                # reactive ones only: bounded by max_reconnects
        s.prog0 = None            # progress marker when this connection settled
        s.no_progress = 0         # consecutive proactive rotations with no progress
        if not frames or [f.seq for f in frames] != list(range(len(frames))):
            raise ValueError("frames must be plan_frames() output: seq 0..n-1 in order")
        s.frames, s.sha, s.ckpt, s.resume = frames, plan_sha, ckpt_path, resume
        s.append = append
        s.max_resyncs = max_resyncs
        s.ranges = [f for f in frames if f.kind == "range"]
        s.nd = len(frames) - len(s.ranges)
        s.max_piece = max((f.n for f in s.ranges), default=0)
        if not s.ranges or s.nd == 0 or any(f.kind != "data" for f in frames[:s.nd]):
            raise ValueError("frames must be data frames, then one range frame per piece")
        s.resyncs = 0
        s.causes = []             # why each resync / recovery / resend happened
        s.saved_last = None
        s.rerr_retried = set()    # pieces already retried once after an HBM read error
        s.range_results = {}      # piece index -> (got or None on an HBM read error, want)
        s.already_complete = False
        # Debug fault injection (--corrupt-seq, Task 11): this data frame goes out ONCE with
        # one payload bit flipped after its CRC was computed, so the die must reject it.
        if corrupt_seq is not None and not (0 <= corrupt_seq < s.nd):
            raise ValueError("--corrupt-seq must name a data frame (seq 0..%d), got %r"
                             % (s.nd - 1, corrupt_seq))
        s.corrupt_seq = corrupt_seq
        s.data_bytes_sent = 0     # payload bytes of data frames this run put on the wire

    def _slot(s, fr):
        if fr.kind == "range":
            return F.range_crc_slot(s._wire(fr.seq), fr.addr, fr.n)
        slot = F.build_slot(s._wire(fr.seq), fr.addr, read_payload(fr))
        if fr.seq == s.corrupt_seq:
            s.corrupt_seq = None                   # first send only
            b = bytearray(slot)
            b[32] ^= 0x01                          # bit 0 of payload byte 0 (word 1)
            slot = bytes(b)
        return slot

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

    def _budget(s):
        """The resync/recovery/tail-resend budget: s.max_resyncs (--max-resyncs, floor),
        plus one more full allowance per REFILL_FRAMES data frames the die's own status
        has shown committed this run (fix round 3 item 3) -- a long load earns a
        proportionally larger allowance for transient events without raising the floor
        for a run that never commits that many frames."""
        return s.max_resyncs * (1 + s.max_committed // REFILL_FRAMES)

    def _count_retry(s, why):
        s.resyncs += 1
        s.causes.append(why)
        budget = s._budget()
        if s.resyncs > budget:
            raise LoadAborted("giving up after %d resyncs (budget %d: max_resyncs=%d, "
                              "%d frames committed); last cause: %s"
                              % (s.resyncs - 1, budget, s.max_resyncs, s.max_committed, why))

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
                return s._settle()
            except LinkFault as e:
                faulted, why = True, "link: %s" % e

    def _progress(s):
        return (s.max_committed, len(s.range_results))

    def _connected(s, st):
        """A connection's scan is open and settled: its proactive timer starts NOW (fix
        round 1 item 1b), not when start() returned, so a slow settle cannot eat it."""
        s.conn_t0 = s.clock()
        s.prog0 = s._progress()
        return st

    def _open(s):
        try:
            s.t.open_scan()
            return s._connected(s._settle())
        except LinkFault as e:
            return s._restore("link: %s" % e, faulted=True)
        except LinkLost as e:
            return s._restore(lost=e)

    # ------------------------------------------------------------ reconnect (2026-10-07)

    def _restore(s, why=None, faulted=False, lost=None):
        """Get back to a settled scan: _reopen (a resync, counted against max_resyncs)
        unless the connection itself is gone (`lost`), in which case reconnect. A
        connection lost DURING a reopen also turns into a reconnect."""
        while True:
            try:
                if lost is not None:
                    return s._reconnect_lost(lost)
                return s._reopen(why, faulted)
            except LinkLost as e:
                lost = e

    def _due(s):
        return (s.connect is not None and s.reconnect_secs > 0
                and s.clock() - s.conn_t0 >= s.reconnect_secs)

    def _rotate(s):
        """Proactive reconnect, at a clean point (the caller has read every reply it
        owes: no frame is half-sent). Leave Shift-DR the vetted way, close the socket,
        reconnect. Returns the new connection's settled status."""
        secs = s.clock() - s.conn_t0
        if s._progress() == s.prog0:
            s.no_progress += 1
            if s.no_progress >= NO_PROGRESS_ROTATIONS:
                raise LoadAborted("no progress on %d consecutive connections (nothing "
                                  "committed and no piece checked in %d s on each, "
                                  "--reconnect-secs %s): stopping instead of reconnecting "
                                  "again; the die keeps what it committed: run again with "
                                  "--resume" % (s.no_progress, round(secs), s.reconnect_secs))
        else:
            s.no_progress = 0
        try:
            s.t.close_scan()
        except (LinkFault, LinkLost):
            s.t.abort_close()     # swallows; the connection is being dropped anyway
        s.t.close()
        return s._reconnect("proactive", secs)

    def _reconnect_lost(s, e):
        """Reactive reconnect after LinkLost `e`. Without a connect factory, or with
        max_reconnects used up, the run ends with the connection-lost abort."""
        secs = s.clock() - s.conn_t0
        s.t.close()
        if s.connect is None or s.max_reconnects == 0:
            raise e.orig
        if s.lost >= s.max_reconnects:
            raise ConnectionError("the link was lost again (%s) after %d reconnects "
                                  "(--max-reconnects %d); the die keeps what it committed: "
                                  "run again with --resume" % (e, s.lost, s.max_reconnects))
        s.lost += 1
        s.sleep(RECONNECT_SETTLE_SECS)             # fix round 1 item 8
        return s._reconnect("lost:%s" % type(e.orig).__name__, secs)

    def _reconnect(s, reason, secs):
        """A new connection (s.connect(): a fresh CoeTransport, whose constructor runs
        start()), a new scan, and _settle -- which re-checks the die's DNA exactly as
        on any scan open. Up to RECONNECT_TRIES consecutive attempts with a short
        backoff. Only link-level failures are retried: LoadAborted (a DNA mismatch above
        all), the CoE guard's refusals (IRNotAllowed, TapProtocolError) and anything else
        (RuntimeError for unexpected IDCODEs) propagate at once and end the run."""
        s.reconnects += 1
        s.log("JCLOAD_RECONNECT %d %s %.1f" % (s.reconnects, reason, secs))
        last = None
        for k in range(1, RECONNECT_TRIES + 1):
            t = None
            try:
                t = _Guarded(s.connect())
                s.t = t
                s.connections += 1
                t.open_scan()
                return s._connected(s._settle())
            except (OSError, LinkFault) as e:      # LinkLost is an OSError
                last = e
                if t is not None:
                    t.abort_close()
                    t.close()
            if k < RECONNECT_TRIES:
                s.sleep(RECONNECT_BACKOFF * k)
        raise ConnectionError("could not reconnect in %d consecutive attempts (last: %s: "
                              "%s); the die keeps what it committed: run again with --resume"
                              % (RECONNECT_TRIES, type(last).__name__, last))

    def _close_end(s):
        """Leave Shift-DR at the end of a run; every result is already in hand."""
        try:
            s.t.close_scan()
        except LinkFault:
            try:
                s.t.recover()
            except LinkLost:
                pass
        except LinkLost:
            pass

    def _check_ckpt(s):
        _outside_repo(s.ckpt, "the checkpoint")
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
            if s.resume and (ck.get("append") or ck.get("seq_base")):
                raise LoadAborted("the checkpoint %s was written by a load --append (seq base "
                                  "%s): a resumed append is not supported; run load --append "
                                  "again, which sends the whole plan after the die's last "
                                  "frame" % (s.ckpt, ck.get("seq_base")))
            if ck.get("dna") != dna_hex(s.dna):
                got = ck.get("dna")
                got = (dna_mask(int(got, 16)) if isinstance(got, str) and _DNA_HEX.fullmatch(got)
                       else "none" if got is None else "an unreadable value")
                raise LoadAborted("the checkpoint %s was written for die DNA %s, this run "
                                  "expects %s (%s): check --die and --dies, or %s"
                                  % (s.ckpt, got, dna_mask(s.dna), s.dna_label, how))
        elif s.resume:
            raise LoadAborted("--resume given but no checkpoint at %s" % s.ckpt)

    def _save_ckpt(s, last):
        _outside_repo(s.ckpt, "the checkpoint")
        tmp = s.ckpt + ".tmp"
        with open(tmp, "w") as f:
            json.dump(dict(plan_sha=s.sha, dna=dna_hex(s.dna),
                           last=None if last == NONE else last,
                           append=s.append, seq_base=s.seq_base), f)
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
                if s._due():
                    while inflight:               # a clean point: every owed reply read
                        s._take(); inflight -= 1
                    st = s._rotate()
                    base, nxt = _errs(st), (0 if st["last"] == NONE else st["last"] + 1)
                    continue
                while nxt < s.nd and inflight < s.t.depth:
                    fr = s.frames[nxt]
                    s.t.send(s._slot(fr)); nxt += 1; inflight += 1
                    s.data_bytes_sent += fr.n      # fix round 1 item 7: only once sent
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
                st = s._restore("link: %s" % e, faulted=True)
                base, nxt = _errs(st), (0 if st["last"] == NONE else st["last"] + 1)
            except LinkLost as e:
                inflight = 0
                st = s._restore(lost=e)
                base, nxt = _errs(st), (0 if st["last"] == NONE else st["last"] + 1)

    def _range_ok(s, q):
        return (lambda x: x["range_seq"] == q and x["range_valid"] == 1 and
                x["last"] == q and x["busy"] == 0)

    def _wait_range(s, q, nbytes, base):
        """Poll for range frame q's own result (M1, M3). Within range_polls(nbytes,
        RANGE_EXPECT_BPS) polls any good status may come; every status showing q
        committed and the CRC unit busy (it is working on q: re-requesting would only
        queue another CRC behind it) grants MAX_POLLS more from that point, up to the
        piece at RANGE_FLOOR_BPS in total.
        Returns ("ok", st), ("err", st) on a counter move off `base`, ("timeout", st)."""
        polls = range_polls(nbytes, RANGE_EXPECT_BPS, s.t.hz)
        cap = max(polls, range_polls(nbytes, RANGE_FLOOR_BPS, s.t.hz))
        ok, st, until = s._range_ok(q), None, polls
        for k in range(cap):
            s.t.send(F.poll_slot())
            x = s._take()
            if x is not None:
                st = x
                if _errs(st) != base:
                    return "err", st
                if ok(st):
                    return "ok", st
                if st["last"] == q and st["busy"] == 1:   # the CRC unit is on q
                    until = max(until, k + 1 + MAX_POLLS)
            if k + 1 >= until:
                break
        return "timeout", st

    def _accept(s, i, x):
        """Record piece i's result from status x, or (M2) leave it unrecorded for one
        retry with a fresh seq after an HBM read error. True if recorded."""
        if x["range_rerr"] and i not in s.rerr_retried:
            s.rerr_retried.add(i)
            s.causes.append("HBM read error on piece %d (seq %d): retried once"
                            % (i, x["range_seq"]))
            return False
        s.range_results[i] = (None if x["range_rerr"] else x["range_crc"],
                              expected_range_crc(s.ranges[i]))
        return True

    def _range_phase(s, st, use_plan_seqs):
        """Range-check every piece, one frame at a time (see the class docstring).
        Fills s.range_results; returns the last status."""
        s.range_results = {}
        first, final = s.ranges[0].seq, s.frames[-1].seq
        base = _errs(st)
        while len(s.range_results) < len(s.ranges):
            if s._due():                          # between pieces: nothing outstanding
                try:
                    st = s._rotate()
                except LinkLost as e:
                    st = s._restore(lost=e)
                base = _errs(st)
                continue
            seq = (st["last"] + 1) & M32
            i = seq - first if use_plan_seqs and first <= seq <= final else None
            if i is None or i in s.range_results:
                i = next(k for k in range(len(s.ranges)) if k not in s.range_results)
            fr = s.ranges[i]
            try:
                s.t.send(F.range_crc_slot(s._wire(seq), fr.addr, fr.n))
                s._take()
                how, x = s._wait_range(seq, fr.n, base)
                if how == "ok":
                    s._accept(i, x)
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
                st = s._restore("link: %s" % e, faulted=True)
            except LinkLost as e:
                st = s._restore(lost=e)
            # M1: the reopen's settled status may already carry this frame's result
            if s._range_ok(seq)(st):
                s._accept(i, st)
            base = _errs(st)
        return st

    def _mismatches(s):
        return [(s.ranges[i], got, want) for i, (got, want) in sorted(s.range_results.items())
                if got != want]

    def _run_load(s):
        s._check_ckpt()
        st = s._open()
        if s.append and st["last"] != NONE:
            # fixed once, for the life of the run (every reconnect keeps it): this plan's
            # seq 0 goes on the wire as the die's last + 1
            if st["last"] + len(s.frames) >= NONE:
                raise LoadAborted("the die's last seq %d leaves no room for %d more frames "
                                  "before the 32-bit seq wraps: reload the bitstream"
                                  % (st["last"], len(s.frames)))
            s.seq_base = st["last"] + 1
            st = s._to_plan(st)
            s.st = st
        if st["last"] != NONE and not s.resume:
            raise LoadAborted("the die already holds frames up to seq %d; use --resume with "
                              "the same plan, --append to load this plan after them (a "
                              "second image), or reload the bitstream" % st["last"])
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
            nrerr = sum(1 for _, g, _ in bad if g is None)
            if nrerr == len(bad):
                advice = ("every one is an HBM read error (RRESP, twice per piece), not a "
                          "CRC mismatch: the data may well be right; run load --resume, "
                          "which re-checks every piece by range CRC (no reload needed for "
                          "a read error)")
            elif nrerr:
                advice = ("the die does not hold this plan, reload the bitstream and load "
                          "again (%d of them are HBM read errors only, which load --resume "
                          "would re-check without a reload)" % nrerr)
            else:
                advice = "the die does not hold this plan, reload the bitstream and load again"
            raise LoadAborted("%d of %d pieces failed the range CRC after loading: %s%s; %s"
                              % (len(bad), len(s.ranges),
                                 ", ".join("%#x+%d got %s want %08x"
                                           % (f.addr, f.n, "RERR" if g is None else "%08x" % g, w)
                                           for f, g, w in bad[:8]),
                                 " ..." if len(bad) > 8 else "", advice))
        s._close_end()                                 # every result is already in hand
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
        s._close_end()
        return s._mismatches()

CKPT_DIR = "/mnt/storage/fk33_builds/jc_load"

APPEND_RESUME_REFUSED = ("--append with --resume is refused: a resumed append would need "
                         "the original run's seq base, which is out of scope; run load "
                         "--append again (it re-sends the whole plan after the die's last "
                         "frame)")

def default_ckpt(sha, die):
    return os.path.join(CKPT_DIR, "%s_%s.json" % (sha[:12], die))

def read_identity(t):
    """Open a scan on transport `t`, settle, wait for dna_valid and return the DNA the
    die at that chain position reports (Task 9b). Closes the scan either way."""
    se = _Session(t, None, health=False)
    try:
        t.open_scan()
        st = se._settle()
    except (LoadAborted, LinkFault):
        t.abort_close()
        raise
    try:
        t.close_scan()
    except LinkFault:
        t.recover()
    return st["dna"]

def identify(t, die, dies_path, force=False):
    """Read the DNA at the chain position `t` was opened for and record it as `die` in
    the die record. Refuses to change a different existing entry for `die` unless
    `force`, and always refuses a DNA the record already gives the OTHER die (that is
    the wrong --chain this record exists to catch). Returns (dna, "added" | "unchanged"
    | "replaced")."""
    if die not in DIE_NAMES:
        raise ValueError("die must be one of %s" % "/".join(DIE_NAMES))
    rec = read_dies(dies_path, must_exist=False)       # refuses a bad file before the board
    dna = read_identity(t)
    for other, v in rec.items():
        if other != die and v == dna:
            raise LoadAborted("the die at this chain position has DNA %s, which %s already "
                              "records as die %s: --chain is wrong for --die %s, or the "
                              "record is; fix it (delete the file and identify both dies, "
                              "cross-checked) before loading anything"
                              % (dna_hex(dna), dies_path, other, die))
    if die in rec and rec[die] == dna:
        return dna, "unchanged"
    if die in rec and not force:
        raise LoadAborted("%s records die %s as %s, but the die at this chain position "
                          "reports %s: refusing to change it without --force (check --chain "
                          "first: a wrong --chain reads the other die)"
                          % (dies_path, die, dna_hex(rec[die]), dna_hex(dna)))
    how = "replaced" if die in rec else "added"
    rec[die] = dna
    write_dies(dies_path, rec)
    return dna, how

IDENTIFY_HELP = """Read a die's DNA_PORTE2 identity through the loader bitstream and record it
in the die record (--dies, a JSON file OUTSIDE the repo: no DNA read from real hardware is
ever committed). load and verify refuse to run unless the die answering at the chosen
chain position has the recorded DNA.

identify itself CANNOT tell AB from BA: it records whatever die answers at the position
--chain gives for --die. The record is only as trustworthy as that choice, so make it
ONCE, at bring-up, for each die, and cross-check it: in Vivado hardware manager, read the
DNA of each device on the chain (device 0 is the one nearest TDI) and confirm the value
identify printed for --die matches the device at the position --chain puts that die in.
Then keep the file; do not re-identify to make a load go through. identify refuses to
record a DNA the file already gives the other die, and refuses to change an existing
entry without --force.

identify is the only command that prints a die's full DNA (load and verify show it
masked, first and last 4 hex digits). Do not commit its output, or paste it into the
repo, an issue or a log under version control; the record file and checkpoints are
refused anywhere inside a git checkout or worktree."""

MAX_HZ = 27_000_000       # the BMC's rated TCK rate (fix round 3 item 1)

def _hz_type(s):
    try:
        v = int(s)
    except ValueError:
        raise argparse.ArgumentTypeError("--hz must be an integer, got %r" % s)
    if v <= 0:
        raise argparse.ArgumentTypeError("--hz must be > 0, got %d" % v)
    if v > MAX_HZ:
        raise argparse.ArgumentTypeError("--hz must not exceed %d (the BMC's rated TCK "
                                          "rate), got %d" % (MAX_HZ, v))
    return v

def _max_resyncs_type(s):
    try:
        v = int(s)
    except ValueError:
        raise argparse.ArgumentTypeError("--max-resyncs must be an integer, got %r" % s)
    if v < 1:
        raise argparse.ArgumentTypeError("--max-resyncs must be >= 1, got %d" % v)
    return v

def _reconnect_secs_type(s):
    try:
        v = float(s)
    except ValueError:
        raise argparse.ArgumentTypeError("--reconnect-secs must be a number, got %r" % s)
    if not (v == 0 or RECONNECT_SECS_MIN <= v <= RECONNECT_SECS_MAX):
        raise argparse.ArgumentTypeError("--reconnect-secs must be 0 (off) or >= %d and <= %d "
                                          "(the BMC ends a connection at ~310 s), got %s"
                                          % (RECONNECT_SECS_MIN, RECONNECT_SECS_MAX, s))
    return int(v) if v == int(v) else v

def _max_reconnects_type(s):
    try:
        v = int(s)
    except ValueError:
        raise argparse.ArgumentTypeError("--max-reconnects must be an integer, got %r" % s)
    if v < 0:
        raise argparse.ArgumentTypeError("--max-reconnects must be >= 0, got %d" % v)
    return v

def main(argv=None):
    ap = argparse.ArgumentParser(description="Load or verify a Jungle Cat die's HBM over "
                                 "JTAG, or record a die's identity (main session only: "
                                 "this opens the board's JTAG).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    def common(p):
        p.add_argument("--bmc", required=True, help="BMC address, e.g. 192.0.2.1 (no default)")
        p.add_argument("--die", required=True, choices=list(DIE_NAMES))
        p.add_argument("--chain", required=True, choices=["AB", "BA"],
                       help="dies in order from TDI to TDO, measured at bring-up. The die "
                       "record (--dies) catches a wrong --chain when both dies carry the "
                       "loader")
        p.add_argument("--dies", required=True,
                       help="die record, JSON {\"A\": \"<24 hex digits>\", \"B\": ...}, kept "
                       "outside the repo; written by identify")
        p.add_argument("--hz", type=_hz_type, default=MAX_HZ,
                       help=("JTAG TCK rate in Hz passed to the BMC (default: %(default)s); "
                       "must be > 0 and <= {0} (the BMC's rated rate). Every range-wait "
                       "budget scales with it").format(MAX_HZ))
    for name in ("load", "verify"):
        p = sub.add_parser(name)
        p.add_argument("manifest")
        common(p)
        p.add_argument("--resume", action="store_true")
        p.add_argument("--ckpt", default=None)
        if name == "load":
            p.add_argument("--append", action="store_true",
                           help="load this plan onto a die that already holds an earlier "
                           "plan's frames (a second image in the same bitstream session): "
                           "its frames go on the wire numbered from the die's last + 1. "
                           "On a die holding nothing it is an ordinary load. Not with "
                           "--resume")
        p.add_argument("--max-resyncs", type=_max_resyncs_type, default=MAX_RESYNCS,
                       help=("resyncs/recoveries/tail-resends allowed before giving up "
                       "(default: %(default)s); must be >= 1. The budget refills: an "
                       "extra --max-resyncs allowance is granted per {0} data frames the "
                       "die has committed this run, so a long load gets a proportionally "
                       "larger allowance for transient events than a short one"
                       ).format(REFILL_FRAMES))
        p.add_argument("--reconnect-secs", type=_reconnect_secs_type, default=RECONNECT_SECS,
                       help=("open a new CoE connection after this many seconds on one, at "
                       "a clean point, before the BMC ends it (MEASURED ~310-320 s); "
                       "default %(default)s, must be >= {1} and <= {0}, 0 disables. Timed "
                       "from when the connection's scan settled. The plan is reused and the "
                       "die's DNA re-checked on every new connection; {2} rotations in a row "
                       "with no progress abort").format(RECONNECT_SECS_MAX, RECONNECT_SECS_MIN,
                                                        NO_PROGRESS_ROTATIONS))
        p.add_argument("--max-reconnects", type=_max_reconnects_type, default=MAX_RECONNECTS,
                       help=("reconnects after a LOST connection allowed per run (default: "
                       "%(default)s, 0 disables); proactive ones (--reconnect-secs) are not "
                       "counted, and neither kind counts against --max-resyncs"))
        p.add_argument("--corrupt-seq", type=int, default=None,
                       help=("DEBUG (load only): send this data frame once with one payload "
                             "bit flipped, to prove on silicon that the die's CRC check "
                             "rejects it and the loader resends it"))
    p = sub.add_parser("identify", description=IDENTIFY_HELP,
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    common(p)
    p.add_argument("--force", action="store_true",
                   help="replace an existing, different entry for --die")
    a = ap.parse_args(argv)
    if a.cmd == "identify":
        try:
            t = CoeTransport(a.bmc, a.die, a.chain, hz=a.hz)
            dna, how = identify(t, a.die, a.dies, force=a.force)
        except (LoadAborted, LinkFault) as e:
            print("JCIDENTIFY_ABORT %s" % e)
            return 2
        except (ConnectionError, TimeoutError, OSError) as e:
            print("JCIDENTIFY_ABORT connection lost (%s: %s)" % (type(e).__name__, e))
            return 2
        except Exception as e:
            print("JCIDENTIFY_ABORT %s: %s" % (type(e).__name__, e))
            return 2
        print("JCIDENTIFY_DONE die=%s chain=%s dna=%s %s in %s; cross-check this value "
              "against Vivado hardware manager's DNA for that chain position (identify "
              "--help); bit-reversed dna=%s (bit order ESTIMATE, Task 11 cross-checks "
              "against Vivado)" % (a.die, a.chain, dna_hex(dna), how, a.dies,
                                   dna_hex(dna_bitrev(dna))))
        return 0
    t_start = time.time()
    append = getattr(a, "append", False)
    if append and a.resume:
        print("JCLOAD_ABORT %s" % APPEND_RESUME_REFUSED)
        return 2
    try:
        dna = dna_for(a.dies, a.die)
        label = "the die record %s (die %s)" % (a.dies, a.die)
        frames, sha = plan_frames(a.manifest, die=a.die)
        ck = a.ckpt or default_ckpt(sha, a.die)
        _outside_repo(ck, "the checkpoint")
    except LoadAborted as e:
        print("JCLOAD_ABORT %s" % e)
        return 2
    except PlanError as e:
        print("JCLOAD_ABORT %s" % e)
        return 2
    except OSError as e:
        print("JCLOAD_ABORT manifest %s is unreadable (%s: %s)"
              % (a.manifest, type(e).__name__, e))
        return 2
    os.makedirs(os.path.dirname(os.path.abspath(ck)), exist_ok=True)
    t0 = time.time()
    plan_s = t0 - t_start
    connect = lambda: CoeTransport(a.bmc, a.die, a.chain, hz=a.hz)
    try:
        t = connect()
        ld = Loader(t, frames, sha, ck, resume=a.resume, dna=dna, dna_label=label,
                   append=append,
                   max_resyncs=a.max_resyncs,
                   corrupt_seq=a.corrupt_seq if a.cmd == "load" else None,
                   connect=connect, reconnect_secs=a.reconnect_secs,
                   max_reconnects=a.max_reconnects)
        if a.cmd == "load":
            st = ld.run_load()
            n = ld.data_bytes_sent          # this run only (a resume sends the remainder)
            now = time.time()
            dt = max(now - t0, 1e-9)        # on the link: first connection to done
            wall = now - t_start            # planning included
            conns = "connections=%d reconnects=%d" % (ld.connections, ld.reconnects)
            if ld.seq_base:
                print("JCLOAD_APPEND seq_base=%d (plan seq 0 went on the wire as %d)"
                      % (ld.seq_base, ld.seq_base))
            if ld.already_complete:
                print("JCLOAD_DONE already complete: %d pieces re-checked by range CRC, "
                      "last=%d resyncs=%d, wall %.0f s (planning %.0f s), %s"
                      % (len(ld.range_results), st["last"], ld.resyncs, wall, plan_s, conns))
            else:
                print("JCLOAD_DONE last=%d committed=%d crc_fail=%d resyncs=%d pieces=%d "
                      "matched, wall %.0f s (planning %.0f s), %s, this run sent %d data "
                      "bytes in %.0f s at %.2f MB/s"
                      % (st["last"], st["committed"], st["crc_fail"], ld.resyncs,
                         len(ld.range_results), wall, plan_s, conns, n, dt, n / dt / 1e6))
            return 0
        bad = ld.run_verify()
    except (LoadAborted, LinkFault) as e:
        print("JCLOAD_ABORT %s" % e)
        return 2
    except (ConnectionError, TimeoutError, OSError) as e:
        print("JCLOAD_ABORT connection lost (%s: %s); the die keeps what it committed: "
              "run again with --resume" % (type(e).__name__, e))
        return 2
    except Exception as e:
        # fix round 1 item 4: a guard refusal (IRNotAllowed, TapProtocolError), unexpected
        # IDCODEs (RuntimeError) or anything else is never retried, but a waiter gating
        # on ^JCLOAD_(DONE|ABORT) must still see the sentinel, not a bare traceback
        print("JCLOAD_ABORT %s: %s" % (type(e).__name__, e))
        return 2
    for fr, got, want in bad[:20]:
        print("JCVERIFY_BAD addr=%#x n=%d got=%s want=%08x"
              % (fr.addr, fr.n, "RERR" if got is None else "%08x" % got, want))
    if any(got is None for _, got, _ in bad):
        print("JCVERIFY_NOTE RERR is an HBM read error (twice per piece), not a CRC "
              "mismatch: verify again; no reload is needed for a read error alone")
    print("JCVERIFY_%s %d pieces, %d bad" % ("PASS" if not bad else "FAIL",
          sum(1 for f in frames if f.kind == "range"), len(bad)))
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
