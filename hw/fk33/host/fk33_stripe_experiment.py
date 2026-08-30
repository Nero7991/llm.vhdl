#!/usr/bin/env python3
"""Run the HBM lane-striping experiment end to end and print ONE table.

    fk33_stripe_experiment.py precheck        offline.  Opens nothing under /dev
    fk33_stripe_experiment.py run             THE command.  Card required
    fk33_stripe_experiment.py run --dry-run   the whole control flow, no card
    fk33_stripe_experiment.py selfcheck       prove the guards can fail.  No card

WHAT THE EXPERIMENT IS
----------------------
`docs/debugging/2026-08-30_counters-cycles-beats-starved.md` MEASURED the
engine at 21.67 core cycles per BEATS increment and DERIVED that the cause is
the HBM address map: a `.mv4i` is laid down contiguously, every tensor is far
smaller than the 256 MiB pseudo-channel granule, so all 27 of its AXI read
masters queue for ONE pseudo-channel that retires one beat per 250 MHz cycle.

`tools/pack_model_fk33.py --stripe-lanes` places each of the 27 sub-regions in
a DIFFERENT 256 MiB segment.  `docs/debugging/2026-08-30_stripepath-five-emitters.md`
section 10 pre-registered the prediction:

    cycles/beat falls from the MEASURED 21.67 to between 1.60 and 3.0.
    10-12 means half the lanes still share a channel.
    UNCHANGED 21.6 means the image or the descriptors are not the striped
    ones, and is NOT evidence about the theory.

THAT LAST FAILURE MODE IS WHY THIS FILE EXISTS.  A null result and a
misconfigured run produce the same number, so the run has to prove it is
measuring what it claims BEFORE it measures.  Every guard below exists to make
one specific way of being fooled impossible:

  G1  the striped manifest really is v2                 (a v1 set silently
      passes every downstream tool and lands 21.6)
  G2  the 27 sub-region bases really are spread, derived INDEPENDENTLY from
      the .mv4i's own 0x38 table and the manifest's raw `pieces` JSON, never
      from any emitter and never from a piece's `segment` LABEL
  G3  the base `fk33_run_job.py` actually emitted equals G2's derivation
      (G2 alone says the MANIFEST is striped; G3 says the DESCRIPTOR is)
  G4  the bytes on the card hash to the manifest's pack-time digest, over
      every extent (`fk33_load_weights.py verify`)
  G5  the thermal trip counter is CLEARED and OBSERVED ZERO before each job,
      and must not move across it
  G6  every line this file parses out of a child was actually found
  G7  the child's verdict is PASS -- wrong numbers make the cycle count
      meaningless whatever it says

G5 IS NOT REDUNDANT WITH THE CHILD'S OWN THERMAL CHECK, AND THE REASON IS THE
WHOLE POINT OF OPEN ISSUE THERM-255.  `fk33_run_job.py` reads the trip counter
before and after the job and calls the result INCONCLUSIVE when it moved.  That
counter is `trip_cnt : unsigned(7 downto 0)` in `hw/fk33/rtl/fk33_thermal.vhd`
and line 1166 is

    if trip_cnt /= to_unsigned(255, trip_cnt'length) then trip_cnt <= trip_cnt + 1;

i.e. it SATURATES.  Once it reaches 255 -- which is the observed steady state
this open issue is named for -- `trip1 != trip0` is FALSE FOREVER and the
child's thermal veto is dead while still printing.  So this file clears the
counter before every job and REFUSES TO PROCEED unless the clear is observed to
have taken.  A guard that cannot fail is decoration; this one could not fail
until the clear was added.

WHAT THIS FILE DELIBERATELY DOES NOT DO
---------------------------------------
It does not build a descriptor, it does not compute a base, and it does not
place anything.  It drives `fk33_load_weights.py`, `fk33_run_job.py` and
`fk33ctl.py` as subprocesses and reads their stdout.  The only arithmetic it
does is the G2 oracle, which is deliberately written from `struct` and raw JSON
so that agreeing with the emitters is evidence rather than tautology.

HAZARD.  `run` loads BOTH images.  The flat control goes down first and the
striped image second, so the card is left holding a complete, verified STRIPED
image.  Nothing is left in a mixed state on a run that completes; a run
interrupted between the two phases leaves whichever image had been loaded last,
and re-running from the top is the fix.  Both phases are full loads, so this
command is idempotent.
"""
import argparse
import json
import os
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # repo root
TOOLS = os.path.join(ROOT, "tools")

HDR_BYTES = 4096
MV4I_MAGIC = 0x4D563449
HBM_TOP = 8 << 30
NSEG = 32
SEG = HBM_TOP // NSEG                                  # 256 MiB pseudo-channel

# hw/fk33/gen_pcieep.py:376.  Engine master i is DIRECTLY wired to SAXI_<this>.
# Read here as DATA, to report how many lanes cross the HBM switch laterally.
# Nothing below gates on it: it is a measurement, not a rule.
ENG_PORT_MAP = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29]

DEF_FLAT = "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd"
DEF_STRIPED = "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped"

# The four jobs of the published table in
# docs/debugging/2026-08-30_counters-cycles-beats-starved.md section 4.2, so
# the striped numbers are a COMPARISON and not four new numbers.
#   (tensor, rows, x_exp, the published flat CYCLES/BEATS for reference)
JOBS = [
    ("blk.0.ssm_alpha.weight",  32, -6, 2992, 128),
    ("blk.0.ffn_gate.weight",  100, -6, 8582, 384),
    ("blk.11.attn_k.weight",    64, -6, 5724, 256),
    ("blk.20.ffn_down.weight",  64, -6, 16847, 768),
]

# G2 thresholds.  DERIVED, not tuned: the packer has 25 usable segments (1..15
# and 17..26; 0 holds the descriptor arena and the f32 blob, 16 is the host's
# SAXI_16, 27..31 hold the GDN state and the KV cache), so 27 lanes cannot do
# better than 25 distinct channels with 2 channels doubled.  A layout that
# lands FEWER than 20 distinct channels, or puts more than 3 lanes on one, is
# not the layout this experiment is about and the measurement would be
# uninterpretable rather than merely disappointing.
MIN_STRIPED_SEGS = 20
MAX_LANES_PER_SEG = 3


class Bail(Exception):
    """A guard fired.  Never caught to continue; only to print and exit."""


# --------------------------------------------------------------- G2, the oracle
#
# Deliberately imports NEITHER `gen_mv4i_desc` NOR `hbm_map`.  If it did, its
# agreement with the descriptor emitters would be self-agreement -- the m7-mutant
# shape this project has recorded twice.  Segments come from ADDRESS BITS
# [32:28] (`addr // 256 MiB`) and never from a piece's `segment` label, which is
# PACKSTRIPE's T3 and TOKENSTRIPE's S6.

def header_table(path):
    """(nports_w, n_scale_sub, [sub-region file offsets]) out of spec 6.4."""
    with open(path, "rb") as fp:
        h = fp.read(HDR_BYTES)
    if len(h) < HDR_BYTES:
        raise Bail("%s is shorter than one 4 KB header" % path)
    magic, = struct.unpack_from("<I", h, 0)
    if magic != MV4I_MAGIC:
        raise Bail("%s: magic %#x is not MV4I" % (path, magic))
    npw, = struct.unpack_from("<H", h, 0x1A)
    _scl, nss = struct.unpack_from("<II", h, 0x30)
    offs = [struct.unpack_from("<Q", h, 0x38 + 8 * i)[0]
            for i in range(npw + nss)]
    return npw, nss, offs


def load_raw(manifest):
    with open(manifest) as fp:
        m = json.load(fp)
    return m, {f["file"]: f for f in m["files"]}


def lane_census(model_dir, ent, name):
    """The 27 sub-region BASES and the pseudo-channel each one lands in.

    Flat entry: base = hbm_offset + <file offset>, which is the v1 rule.
    Striped entry: base = the hbm_offset of the PIECE whose `file_offset` is
    that sub-region's file offset.  An exact-key lookup on purpose -- a packer
    that cut the file anywhere other than the header's own 0x38 table raises
    here instead of being silently tiled over.
    """
    path = os.path.join(model_dir, ent["file"])
    npw, nss, offs = header_table(path)
    pcs = ent.get("pieces")
    if pcs:
        by_off = {int(p["file_offset"]): int(p["hbm_offset"]) for p in pcs}
        bases = []
        for o in offs:
            if o not in by_off:
                raise Bail(
                    "%s: sub-region at file +%d has no piece with that "
                    "file_offset.  The manifest cuts this file somewhere "
                    "other than its own 0x38 table; see "
                    "tools/check_hbm_stack.py." % (name, o))
            bases.append(by_off[o])
        striped = True
    else:
        hb = int(ent["hbm_offset"])
        bases = [hb + o for o in offs]
        striped = False
    segs = [b // SEG for b in bases]
    hist = {}
    for s in segs:
        hist[s] = hist.get(s, 0) + 1
    direct = sum(1 for i, s in enumerate(segs)
                 if i < len(ENG_PORT_MAP) and ENG_PORT_MAP[i] == s)
    return dict(name=name, npw=npw, nss=nss, nlanes=len(offs), bases=bases,
                segs=segs, distinct=sorted(hist), maxlanes=max(hist.values()),
                direct=direct, striped=striped, w_base0=bases[0],
                s_base0=bases[npw])


# ------------------------------------------------------------------- subprocess

def run_child(argv, label, timeout=1800):
    """Run a child and return (rc, text).  Output is echoed as it is kept."""
    t0 = time.perf_counter()
    p = subprocess.run([sys.executable] + argv, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    txt = p.stdout.decode("utf-8", "replace")
    dt = time.perf_counter() - t0
    return p.returncode, txt, dt


def need(pat, txt, what, label):
    """G6.  A pattern that is not found ABORTS.  It never defaults."""
    m = re.search(pat, txt, re.M)
    if not m:
        raise Bail("could not find %s in the output of %s.  This file parses "
                   "another tool's stdout, so a format change reads as a "
                   "missing measurement and MUST NOT be defaulted to zero.\n"
                   "--- the output it searched ---\n%s"
                   % (what, label, txt[-2000:]))
    return m


# ---------------------------------------------------------------------- G5, therm

def therm_clear(dry):
    """Clear the trip counter and PROVE the clear took.

    Returns the raw THERM_STATUS word after the clear.  See the module
    docstring: without this the child's `trips moved` veto is dead at 255.
    """
    if dry:
        return 0x80000000
    rc, txt, _ = run_child([os.path.join(HERE, "fk33ctl.py"), "thermal",
                            "--clear"], "fk33ctl.py thermal --clear", 120)
    m = need(r"cleared; THERM_STATUS now (0x[0-9a-fA-F]+)", txt,
             "the post-clear THERM_STATUS word", "fk33ctl.py thermal --clear")
    st = int(m.group(1), 16)
    trips = (st >> 16) & 0xFF
    if trips != 0:
        raise Bail(
            "the thermal trip counter reads %d AFTER a clear (THERM_STATUS "
            "%#010x).  The counter saturates at 255 "
            "(hw/fk33/rtl/fk33_thermal.vhd:1166), so while it is non-zero and "
            "pinned every downstream `trips moved` test is dead and a "
            "throughput number taken now is not evidence about striping.  "
            "See open issue THERM-255." % (trips, st))
    if st & 1:
        raise Bail(
            "THERM_STATUS %#010x has bit 0 set: the guard is HALTING the "
            "compute domain right now, and a clear does not release a halt.  "
            "No job run in this state is a subsystem-A measurement." % st)
    if not st & 4:
        raise Bail(
            "THERM_STATUS %#010x has bit 2 clear: the thermal guard is NOT "
            "ARMED.  Refusing to run a sustained workload with no guard."
            % st)
    return st


# ------------------------------------------------------------------- the phases

def do_verify(manifest, layout, expect_extents, dry):
    """G4.  The bytes on the card, judged against the manifest alone."""
    if dry:
        return "DRY RUN -- no read-back was taken"
    rc, txt, dt = run_child(
        [os.path.join(HERE, "fk33_load_weights.py"), "verify", manifest],
        "fk33_load_weights.py verify", 1800)
    m = need(r"^extents\s+(\d+) of (\d+) digested", txt, "the extent tally",
             "fk33_load_weights.py verify")
    got, tot = int(m.group(1)), int(m.group(2))
    if rc != 0:
        raise Bail("the %s image on the card FAILED verify (rc=%d).  The "
                   "measurement is not taken: an unverified image makes an "
                   "unchanged cycles/beat unreadable.\n%s"
                   % (layout, rc, txt[-3000:]))
    if got != tot:
        raise Bail("verify digested %d of %d extents on the %s image.  A "
                   "partial read-back is not a residency proof."
                   % (got, tot, layout))
    if expect_extents is not None and tot != expect_extents:
        raise Bail(
            "verify read %d extents on the %s image and this experiment "
            "expected %d.  A striped object is one file in 28 pieces and a "
            "flat one is a single range, so the EXTENT count is the cheapest "
            "statement of which layout is actually resident -- the OBJECT "
            "count is 250 either way and discriminates nothing."
            % (tot, layout, expect_extents))
    return "%d of %d extents digested in %.1f s" % (got, tot, dt)


def do_load(manifest, layout, dry):
    if dry:
        return "DRY RUN -- nothing was written to the card"
    rc, txt, dt = run_child(
        [os.path.join(HERE, "fk33_load_weights.py"), "load", manifest],
        "fk33_load_weights.py load", 1800)
    if rc != 0:
        raise Bail("loading the %s image failed (rc=%d).\n%s"
                   % (layout, rc, txt[-3000:]))
    m = need(r"wrote ([\d,]+) bytes in ([\d.]+) s", txt, "the write tally",
             "fk33_load_weights.py load")
    return "wrote %s bytes in %.1f s" % (m.group(1), dt)


def one_job(model_dir, manifest, tensor, rows, x_exp, cen, layout, a):
    """Run ONE matvec and return a row of the table, or raise Bail."""
    argv = [os.path.join(HERE, "fk33_run_job.py"), "run",
            "--mv4i", os.path.join(model_dir, tensor + ".mv4i"),
            "--manifest", manifest, "--rows", str(rows),
            "--x-exp", str(x_exp), "--slot", str(a.slot)]
    if a.scratch:
        argv += ["--scratch", a.scratch]
    if a.dry_run:
        argv += ["--dry-run"]
    label = "fk33_run_job.py run %s" % tensor

    attempts = []
    for attempt in range(1, a.therm_retries + 2):
        st = therm_clear(a.dry_run)                       # G5
        rc, txt, dt = run_child(argv, label, a.timeout + 120)

        # G3.  The base the emitter ACTUALLY put in the descriptor, against the
        # base this file derived from the .mv4i header and the raw manifest.
        m = need(r"^weights\s+hbm_base=0x([0-9A-Fa-f]+)\s+"
                 r"w_base\[0\]=0x([0-9A-Fa-f]+)\s+s_base\[0\]=0x([0-9A-Fa-f]+)",
                 txt, "the emitted descriptor bases", label)
        w0, s0 = int(m.group(2), 16), int(m.group(3), 16)
        if (w0, s0) != (cen["w_base0"], cen["s_base0"]):
            raise Bail(
                "G3 FAILED on %s under the %s layout.\n"
                "  the descriptor emitter put   w_base[0]=%#x  s_base[0]=%#x\n"
                "  this file derived            w_base[0]=%#x  s_base[0]=%#x\n"
                "  derived independently from the .mv4i's own 0x38 table and "
                "the manifest's raw `pieces` JSON, importing no emitter.\n"
                "  THIS IS THE 'unchanged 21.6' FAILURE MODE CAUGHT BEFORE IT "
                "BECOMES A NUMBER: the descriptors are not the ones this "
                "layout calls for."
                % (tensor, layout, w0, s0, cen["w_base0"], cen["s_base0"]))

        # G6 on the counters and the thermal line.
        m = need(r"^counters\s+CYCLES=(\d+) BEATS=(\d+) STARVED=(\d+)", txt,
                 "the CYCLES/BEATS/STARVED line", label)
        cyc, beats, starv = int(m.group(1)), int(m.group(2)), int(m.group(3))
        m = need(r"^thermal\s+STATUS=0x[0-9A-Fa-f]+ trips=(\d+) \(was (\d+)\)",
                 txt, "the post-job thermal line", label)
        t_after, t_before = int(m.group(1)), int(m.group(2))
        m = need(r"^VERDICT\s+(\S+)", txt, "the verdict", label)
        verdict = m.group(1)

        attempts.append((verdict, t_before, t_after, cyc, beats))

        # G5, the other half: a trip ACROSS the job.
        if t_after != t_before:
            if attempt <= a.therm_retries:
                continue
            raise Bail(
                "%s under the %s layout: the thermal trip counter moved "
                "%d -> %d during the job on all %d attempts.  EACH TRIP HALTS "
                "THE COMPUTE DOMAIN, so this cycle count is not evidence "
                "about striping.  See open issue THERM-255 and "
                "docs/debugging/2026-08-30_therm255-is-two-stacks-not-two-copies.md."
                % (tensor, layout, t_before, t_after, attempt))
        # G7.
        if verdict != "PASS":
            raise Bail(
                "%s under the %s layout returned VERDICT %s (rc=%d).  A run "
                "whose mantissas do not match ref/matvec_int4.c is not a "
                "throughput measurement of the right computation.\n%s"
                % (tensor, layout, verdict, rc, txt[-3000:]))
        if beats == 0:
            raise Bail("%s: BEATS=0, so cycles/beat is undefined" % tensor)
        return dict(tensor=tensor, rows=rows, cycles=cyc, beats=beats,
                    starved=starv, cpb=cyc / beats, trips=t_after,
                    attempts=attempt, wall=dt, verdict=verdict,
                    segs=len(cen["distinct"]), maxlanes=cen["maxlanes"],
                    direct=cen["direct"], nlanes=cen["nlanes"])
    raise Bail("unreachable")


# --------------------------------------------------------------------- precheck

def precheck(a, quiet=False):
    """Everything that can be established without the card.  Raises Bail."""
    out = []

    def w(s):
        out.append(s)
        if not quiet:
            print(s)

    fm_path = os.path.join(a.flat, "manifest.json")
    sm_path = os.path.join(a.striped, "manifest.json")
    for p in (fm_path, sm_path):
        if not os.path.exists(p):
            raise Bail("no manifest at %s" % p)
    import hashlib
    w("manifests   pinned by sha256, because this file has moved under two "
      "tracks already:")
    for p in (fm_path, sm_path):
        h = hashlib.sha256(open(p, "rb").read()).hexdigest()
        w("  %s  %s" % (h, p))

    fman, fent = load_raw(fm_path)
    sman, sent = load_raw(sm_path)

    # G1.
    nstr = sum(1 for f in sman["files"] if f.get("pieces"))
    nflat_str = sum(1 for f in fman["files"] if f.get("pieces"))
    if "lane_stripe" not in sman.get("hbm", {}):
        raise Bail(
            "G1 FAILED: %s has no `hbm.lane_stripe` block, so it is a v1 FLAT "
            "manifest.  Every downstream tool accepts it, every descriptor is "
            "built correctly, and the measurement lands on 21.6 for a reason "
            "that has nothing to do with the theory." % sm_path)
    if nstr == 0:
        raise Bail("G1 FAILED: %s declares lane_stripe but not one of its %d "
                   "objects carries a `pieces` list"
                   % (sm_path, len(sman["files"])))
    if nflat_str != 0:
        raise Bail("G1 FAILED: the CONTROL manifest %s has %d objects with a "
                   "`pieces` list.  It is not a flat control."
                   % (fm_path, nflat_str))
    w("G1  PASS    striped: %d of %d objects lane-striped, `hbm.lane_stripe` "
      "present;  flat: 0 of %d"
      % (nstr, len(sman["files"]), len(fman["files"])))

    # index.txt -- the packaging gap this track closed.  The host re-run path
    # (`fk33_run_token.py plan`) reads it and refuses without it.
    for d, lbl in ((a.flat, "flat"), (a.striped, "striped")):
        ip = os.path.join(d, "index.txt")
        if not os.path.exists(ip):
            raise Bail(
                "no index.txt in the %s packed dir (%s).  Generate it with\n"
                "    python3 tools/ref9b/make_index.py %s\n"
                "It carries GEOMETRY and SHAPE only -- no hbm_offset and no "
                "pieces -- so the striped one is byte-identical to the flat "
                "one apart from the provenance comment on line 1." % (lbl, ip, d))
    w("index.txt   present in both packed dirs")

    # G2, per measurement tensor, both layouts.
    census = {}
    w("")
    w("G2  the 27 sub-region bases, derived from each .mv4i's own 0x38 table")
    w("    and the manifest's raw `pieces` JSON.  Segments are ADDRESS BITS")
    w("    [32:28], never a piece's `segment` label.")
    w("    %-26s %-7s %6s %5s %8s %s"
      % ("tensor", "layout", "lanes", "chans", "max/chan", "on their own SAXI"))
    for tensor, rows, x_exp, _pc, _pb in a.jobs:
        fn = tensor + ".mv4i"
        for lbl, mdir, ents in (("flat", a.flat, fent),
                                ("striped", a.striped, sent)):
            if fn not in ents:
                raise Bail("%s is not in the %s manifest" % (fn, lbl))
            c = lane_census(mdir, ents[fn], "%s [%s]" % (tensor, lbl))
            census[(tensor, lbl)] = c
            w("    %-26s %-7s %6d %5d %8d %d of %d"
              % (tensor, lbl, c["nlanes"], len(c["distinct"]),
                 c["maxlanes"], c["direct"], c["nlanes"]))
        cf, cs = census[(tensor, "flat")], census[(tensor, "striped")]
        if cf["striped"]:
            raise Bail("G2 FAILED: the flat control's %s carries pieces" % fn)
        if len(cf["distinct"]) != 1:
            raise Bail(
                "G2 FAILED: %s under the FLAT layout already spans %d "
                "pseudo-channels %s.  The control is supposed to be the "
                "single-channel case; a tensor that already straddles is not "
                "a control for this experiment."
                % (fn, len(cf["distinct"]), cf["distinct"]))
        if not cs["striped"]:
            raise Bail("G2 FAILED: %s carries no `pieces` in the striped "
                       "manifest" % fn)
        if len(cs["distinct"]) < MIN_STRIPED_SEGS:
            raise Bail(
                "G2 FAILED: %s under the STRIPED layout lands its %d lanes in "
                "only %d distinct pseudo-channels %s, and this experiment "
                "requires at least %d.  A 'striped' layout that collapses "
                "back onto few channels is STRIPEPATH's teeth row T12: it is "
                "structurally valid, every consumer accepts it, and it would "
                "measure ~21.6 while looking like a null result."
                % (fn, cs["nlanes"], len(cs["distinct"]), cs["distinct"],
                   MIN_STRIPED_SEGS))
        if cs["maxlanes"] > MAX_LANES_PER_SEG:
            raise Bail(
                "G2 FAILED: %s puts %d lanes on one pseudo-channel under the "
                "striped layout, and the prediction in "
                "docs/debugging/2026-08-30_stripepath-five-emitters.md "
                "section 10 is derived from at most 2.  Re-derive the "
                "prediction before measuring, do not widen it afterwards."
                % (fn, cs["maxlanes"]))
    w("G2  PASS    every measurement tensor: flat 1 channel, striped >= %d, "
      "at most %d lanes per channel" % (MIN_STRIPED_SEGS, MAX_LANES_PER_SEG))

    # G2b, THE WHOLE IMAGE, not only the four tensors this run measures.
    # Four tensors passing says nothing about the other 245, and the layout
    # that matters for a token run is all of them.  Reading 249 4 KB headers
    # costs well under a second, so there is no reason to sample.
    w("")
    hist_s, hist_f, worst = {}, {}, []
    for f in sman["files"]:
        if f["kind"] != "mv4i":
            continue
        c = lane_census(a.striped, f, f["file"])
        k = (len(c["distinct"]), c["maxlanes"])
        hist_s[k] = hist_s.get(k, 0) + 1
        if len(c["distinct"]) < MIN_STRIPED_SEGS or c["maxlanes"] > MAX_LANES_PER_SEG:
            worst.append((f["file"], len(c["distinct"]), c["maxlanes"]))
    for f in fman["files"]:
        if f["kind"] != "mv4i":
            continue
        c = lane_census(a.flat, f, f["file"])
        k = (len(c["distinct"]), c["maxlanes"])
        hist_f[k] = hist_f.get(k, 0) + 1
    w("G2b whole-image census, (channels, max lanes on one channel) -> tensors")
    w("    flat     %s" % dict(sorted(hist_f.items())))
    w("    striped  %s" % dict(sorted(hist_s.items())))
    if worst:
        raise Bail(
            "G2b FAILED: %d tensor(s) are not striped to this experiment's "
            "requirement (>= %d channels, <= %d lanes on one).  The first "
            "few: %s.  A layout that is striped for the four tensors this run "
            "measures and collapsed for the rest is not the image a token run "
            "would use, and the four numbers would not generalise."
            % (len(worst), MIN_STRIPED_SEGS, MAX_LANES_PER_SEG, worst[:5]))
    w("G2b PASS    all %d striped tensors meet the requirement"
      % sum(hist_s.values()))

    # The prediction, restated from the census that was just measured, so the
    # number on the page is derived from THIS manifest and not quoted.
    w("")
    mx = max(census[(t, "striped")]["maxlanes"] for t, _, _, _, _ in a.jobs)
    w("PREDICTION  pre-registered in "
      "docs/debugging/2026-08-30_stripepath-five-emitters.md section 10,")
    w("            restated here against the census above and NOT re-derived "
      "to taste:")
    w("            flat    27 beats on 1 pseudo-channel / 250 MHz = 108.0 ns "
      "= 21.60 core cycles at 200 MHz;  MEASURED 21.67")
    w("            striped %d beats on the busiest channel / 250 MHz = %.1f ns "
      "= %.2f core cycles" % (mx, mx * 4.0, mx * 0.8))
    w("            so cycles/beat should fall to between 1.60 and 3.0.")
    w("            10-12 means half the lanes still share a channel.")
    w("            UNCHANGED ~21.6 means the image or the descriptors are not "
      "the striped ones,")
    w("            and G2/G3/G4 above are what make that outcome impossible "
      "to reach silently.")
    return census, out


# -------------------------------------------------------------------- the table

def table(rows_flat, rows_strp, therm_note, dry):
    print("")
    print("=" * 78)
    print("STRIPING EXPERIMENT -- cycles/beat, both layouts, one session")
    if dry:
        print("*** DRY RUN.  The register plane is SIMULATED and CYCLES is a")
        print("*** constant.  This is a statement about this tool, not the card.")
    print("=" * 78)
    print("%-26s %5s %9s %7s %9s %8s %6s %6s %8s %8s"
          % ("tensor", "rows", "CYCLES", "BEATS", "STARVED", "cyc/beat",
             "trips", "chans", "max/chan", "own SAXI"))
    for lbl, rows in (("FLAT (control)", rows_flat), ("STRIPED", rows_strp)):
        print("-- %s" % lbl)
        for r in rows:
            print("%-26s %5d %9d %7d %9d %8.2f %6d %6d %8d %8s"
                  % (r["tensor"], r["rows"], r["cycles"], r["beats"],
                     r["starved"], r["cpb"], r["trips"], r["segs"],
                     r["maxlanes"], "%d/%d" % (r["direct"], r["nlanes"])))
    print("")
    print("chans/max-chan/own-SAXI are the G2 census of THIS run's manifest, "
          "printed beside the")
    print("number so the layout and the measurement are never read apart.  "
          "'own SAXI' is how many")
    print("of the 27 lanes read the pseudo-channel their own engine master is "
          "wired to in")
    print("hw/fk33/gen_pcieep.py's ENG_PORT_MAP; the rest cross the HBM global "
          "switch laterally.")
    print("")
    if dry:
        print("READING  SUPPRESSED.  In a dry run CYCLES is the constant 4096 "
              "from the simulated")
        print("         register plane, so every cycles/beat above is an "
              "artefact of BEATS alone")
        print("         and says nothing whatever about striping.")
    elif rows_flat and rows_strp:
        fm = sum(r["cpb"] for r in rows_flat) / len(rows_flat)
        sm = sum(r["cpb"] for r in rows_strp) / len(rows_strp)
        print("mean cycles/beat   flat %.2f   striped %.2f   speedup %.2fx"
              % (fm, sm, fm / sm if sm else float("nan")))
        print("")
        if sm <= 3.0:
            print("READING  the prediction HOLDS: the bound has stopped being "
                  "one pseudo-channel.")
        elif sm <= 12.0:
            print("READING  between 3 and 12.  Half the lanes are still "
                  "sharing a channel, or the")
            print("         lateral crossing is not free.  Look at "
                  "ENG_PORT_MAP against the segments")
            print("         the packer chose (the 'on their own SAXI' column "
                  "in the precheck), NOT at")
            print("         the host descriptors: G3 has already measured "
                  "those correct.")
        else:
            print("READING  unchanged.  G2, G3 and G4 all passed, so the image "
                  "IS striped, the")
            print("         descriptors ARE striped and the bytes ARE the "
                  "manifest's -- which means")
            print("         this IS evidence against the "
                  "single-pseudo-channel theory, and is the one")
            print("         case where that reading is available.")
    print("")
    print("thermal  %s" % therm_note)
    print("         A throughput number with a non-zero trip count is not "
          "evidence about striping.")


# --------------------------------------------------------------------- commands

def cmd_precheck(a):
    try:
        precheck(a)
    except Bail as e:
        print("\nSTRIPE EXPERIMENT REFUSED\n%s" % e, file=sys.stderr)
        return 1
    print("\nPRECHECK PASS -- nothing under /dev was opened.")
    return 0


def cmd_run(a):
    try:
        census, _ = precheck(a)
        fm = os.path.join(a.flat, "manifest.json")
        sm = os.path.join(a.striped, "manifest.json")
        n_f = sum(len(f.get("pieces") or [1])
                  for f in load_raw(fm)[0]["files"])
        n_s = sum(len(f.get("pieces") or [1])
                  for f in load_raw(sm)[0]["files"])

        print("")
        if not a.dry_run:
            rc, txt, _ = run_child([os.path.join(HERE, "fk33ctl.py"), "id"],
                                   "fk33ctl.py id", 120)
            print(txt.rstrip())
            if rc != 0:
                raise Bail("fk33ctl.py id failed (rc=%d).  The card is not "
                           "enumerated; see "
                           "docs/debugging/2026-08-30_restoring-the-card-"
                           "after-a-power-cycle.md" % rc)

        trips_seen = []
        results = {}
        for lbl, mdir, mani, nx in (("flat", a.flat, fm, n_f),
                                    ("striped", a.striped, sm, n_s)):
            print("")
            print("### PHASE: %s" % lbl.upper())
            print("load        %s" % do_load(mani, lbl, a.dry_run))
            print("verify      %s" % do_verify(mani, lbl, nx, a.dry_run))
            rows = []
            for tensor, nrows, x_exp, _pc, _pb in a.jobs:
                r = one_job(mdir, mani, tensor, nrows, x_exp,
                            census[(tensor, lbl)], lbl, a)
                rows.append(r)
                trips_seen.append(r["trips"])
                print("job         %-26s CYCLES=%-7d BEATS=%-5d "
                      "cyc/beat=%6.2f  trips=%d  attempts=%d"
                      % (tensor, r["cycles"], r["beats"], r["cpb"],
                         r["trips"], r["attempts"]))
            results[lbl] = rows

        note = ("trip counter cleared and observed 0 before every one of the "
                "%d jobs; %d job(s) reported a non-zero count afterwards"
                % (len(trips_seen), sum(1 for t in trips_seen if t)))
        table(results["flat"], results["striped"], note, a.dry_run)
        if a.dry_run:
            print("\nDRY RUN COMPLETE -- nothing under /dev was opened.")
        else:
            print("\nThe card is left holding the STRIPED image, fully "
                  "verified.  Re-running this command is safe.")
        return 0
    except Bail as e:
        print("\nSTRIPE EXPERIMENT REFUSED -- no number was produced.\n%s" % e,
              file=sys.stderr)
        return 1
    except subprocess.TimeoutExpired as e:
        print("\nSTRIPE EXPERIMENT REFUSED -- a child timed out: %s" % e,
              file=sys.stderr)
        return 1


# -------------------------------------------------------------------- selfcheck

def cmd_selfcheck(a):
    """Prove each guard can FAIL, and say which ones earn nothing.

    Every row builds a defect, runs the guard, and requires the stated verdict.
    A guard that has never been shown to fail has not been shown to work.
    """
    import copy
    import tempfile
    ok = True

    def row(name, fn, want_bail, why):
        nonlocal ok
        try:
            fn()
            got = False
        except Bail:
            got = True
        except Exception as e:                       # a harness fault is a fail
            print("  %-34s HARNESS FAULT %r" % (name, e))
            ok = False
            return
        good = (got == want_bail)
        ok = ok and good
        print("  %-34s %-9s %-9s %s"
              % (name, "BAIL" if got else "pass",
                 "ok" if good else "WRONG", why))

    print("selfcheck: each row builds a defect and requires the guard to fire.")
    print("  %-34s %-9s %-9s %s" % ("row", "got", "verdict", "what it isolates"))

    # --- G6, the parser.  The highest-risk guard in this file, because it
    #     reads another tool's prose.
    good = ("weights     hbm_base=0x1000  w_base[0]=0x2000  s_base[0]=0x3000\n"
            "thermal     STATUS=0x80000000 trips=0 (was 0)\n"
            "counters    CYCLES=4096 BEATS=256 STARVED=0  (expected 256)\n"
            "VERDICT     PASS -- fine\n")
    pats = [(r"^counters\s+CYCLES=(\d+) BEATS=(\d+) STARVED=(\d+)", "counters"),
            (r"^thermal\s+STATUS=0x[0-9A-Fa-f]+ trips=(\d+) \(was (\d+)\)",
             "thermal"),
            (r"^VERDICT\s+(\S+)", "verdict"),
            (r"^weights\s+hbm_base=0x([0-9A-Fa-f]+)\s+w_base\[0\]=0x"
             r"([0-9A-Fa-f]+)\s+s_base\[0\]=0x([0-9A-Fa-f]+)", "bases")]
    for pat, nm in pats:
        row("G6 control: %s present" % nm,
            lambda p=pat: need(p, good, "x", "y"), False,
            "the parser must NOT fire on well-formed output")
    for pat, nm in pats:
        drop = "\n".join(l for l in good.splitlines()
                         if not re.match(pat, l)) + "\n"
        row("G6 %s line deleted" % nm,
            lambda p=pat, d=drop: need(p, d, "x", "y"), True,
            "a missing line must ABORT, never default to zero")
    row("G6 CYCLES renamed to Cycles",
        lambda: need(pats[0][0], good.replace("CYCLES", "Cycles"), "x", "y"),
        True, "a child format change reads as a missing measurement")

    # --- G5, the thermal clear.  Constructed against the real parse path by
    #     monkeypatching the child runner, so the rule under test is the
    #     shipping one and not a copy of it.
    global run_child
    real = run_child

    def fake(word):
        def f(argv, label, timeout=120):
            return 0, "cleared; THERM_STATUS now %#010x\n" % word, 0.0
        return f

    def with_fake(word):
        global run_child
        run_child = fake(word)
        try:
            therm_clear(False)
        finally:
            run_child = real

    row("G5 control: clear reads 0, armed",
        lambda: with_fake(0x80000004), False, "a good clear must not fire")
    row("G5 counter SATURATED at 255",
        lambda: with_fake(0x80FF0004), True,
        "THE THERM-255 CASE.  trip_cnt saturates, so the child's "
        "`trips moved` veto is dead here")
    row("G5 counter left at 1 after clear",
        lambda: with_fake(0x80010004), True,
        "any non-zero residue means the clear did not take")
    row("G5 guard is HALTING (bit 0)",
        lambda: with_fake(0x80000005), True,
        "a clear does not release a halt")
    row("G5 guard NOT ARMED (bit 2 clear)",
        lambda: with_fake(0x80000000), True,
        "no guard at all is not a safe state to sweep in")

    def no_line():
        global run_child
        run_child = lambda argv, label, timeout=120: (0, "nothing useful\n", 0.0)
        try:
            therm_clear(False)
        finally:
            run_child = real
    row("G5 no THERM_STATUS line at all", no_line, True,
        "G6 covers G5's own input too")

    # --- G1 and G2, against the real manifests, mutated in scratch.
    fm_path = os.path.join(a.flat, "manifest.json")
    sm_path = os.path.join(a.striped, "manifest.json")
    if not (os.path.exists(fm_path) and os.path.exists(sm_path)):
        print("  (G1/G2 rows skipped: no manifests at %s / %s)"
              % (fm_path, sm_path))
        print("SELFCHECK %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok else 1

    sman, _ = load_raw(sm_path)
    tmp = tempfile.mkdtemp(prefix="stripe_selfcheck_")

    def farm(mdir, man):
        """A symlink farm of the model dir plus ONE written manifest.

        A bare scratch directory is TOKENSTRIPE's recorded trap: make_tail and
        the census both open the .mv4i beside the manifest, so every row dies
        on FileNotFoundError -- the control included, and a column whose
        control dies attributes nothing.
        """
        d = tempfile.mkdtemp(dir=tmp)
        for n in os.listdir(mdir):
            if n == "manifest.json":
                continue
            os.symlink(os.path.join(mdir, n), os.path.join(d, n))
        with open(os.path.join(d, "manifest.json"), "w") as fp:
            json.dump(man, fp)
        return d

    class Args:
        pass

    def try_layouts(fdir, sdir):
        b = Args()
        b.flat, b.striped, b.jobs = fdir, sdir, a.jobs
        precheck(b, quiet=True)

    row("G1/G2 control: the shipping pair",
        lambda: try_layouts(a.flat, a.striped), False,
        "THE CONTROL.  If this fires, nothing below attributes")

    m = copy.deepcopy(sman)
    del m["hbm"]["lane_stripe"]
    row("G1 lane_stripe block deleted",
        lambda mm=m: try_layouts(a.flat, farm(a.striped, mm)), True,
        "a v1 manifest in the striped slot lands 21.6 with no other tell")

    m = copy.deepcopy(sman)
    for f in m["files"]:
        f.pop("pieces", None)
    row("G1 every `pieces` list removed",
        lambda mm=m: try_layouts(a.flat, farm(a.striped, mm)), True,
        "lane_stripe declared, nothing actually striped")

    row("G1 the FLAT manifest in both slots",
        lambda: try_layouts(a.flat, a.flat), True,
        "the commonest way to measure the wrong thing")

    row("G1 the STRIPED manifest as the control",
        lambda: try_layouts(a.striped, a.striped), True,
        "a control that is not flat is not a control")

    # T12: all 27 lanes of ONE tensor collapsed back into ONE pseudo-channel,
    # laid out so nothing OVERLAPS.  This is the row STRIPEPATH and TOKENSTRIPE
    # both left open: it is a structurally valid layout that check_hbm_stack
    # passes outright and hbm_map only catches when it happens to collide.
    tgt = a.jobs[1][0] + ".mv4i"
    m = copy.deepcopy(sman)
    for f in m["files"]:
        if f["file"] == tgt:
            pcs = sorted(f["pieces"], key=lambda p: int(p["file_offset"]))
            base = int(pcs[0]["hbm_offset"]) // SEG * SEG
            cur = base
            for p in pcs:
                p["hbm_offset"] = cur
                p["segment"] = cur // SEG
                cur += (int(p["nbytes"]) + 4095) // 4096 * 4096
            f["hbm_offset"] = int(pcs[0]["hbm_offset"])
    row("G2 T12: 27 lanes into ONE channel",
        lambda mm=m: try_layouts(a.flat, farm(a.striped, mm)), True,
        "THE DEFECT STRIPING EXISTS TO REMOVE.  This construction also "
        "OVERLAPS, so hbm_map would catch it too; the CLEAN "
        "non-overlapping version that nothing else catches is M5b/M9 in "
        "docs/debugging/2026-08-30_stripeready-teeth.py")

    m = copy.deepcopy(sman)
    for f in m["files"]:
        if f["file"] == tgt:
            f["pieces"][3]["file_offset"] = int(f["pieces"][3]["file_offset"]) + 4096
    row("G2 a piece cut off the 0x38 table",
        lambda mm=m: try_layouts(a.flat, farm(a.striped, mm)), True,
        "the manifest cuts the file somewhere its own header does not")

    print("SELFCHECK %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(s):
        s.add_argument("--flat", default=DEF_FLAT)
        s.add_argument("--striped", default=DEF_STRIPED)
        return s

    s = common(sub.add_parser("precheck", help="offline; opens nothing in /dev"))
    s.set_defaults(fn=cmd_precheck)

    s = common(sub.add_parser("run", help="THE command"))
    s.add_argument("--dry-run", action="store_true",
                   help="simulated register plane, no load, no verify.  "
                        "Opens nothing under /dev.  Proves this tool, not the "
                        "card")
    s.add_argument("--slot", type=int, default=0)
    s.add_argument("--timeout", type=float, default=30.0)
    s.add_argument("--therm-retries", type=int, default=2, dest="therm_retries",
                   help="re-runs allowed when the trip counter moves across a "
                        "job.  The result is refused, never averaged")
    s.add_argument("--scratch", default=None)
    s.set_defaults(fn=cmd_run)

    s = common(sub.add_parser("selfcheck", help="prove the guards can fail"))
    s.set_defaults(fn=cmd_selfcheck)

    a = ap.parse_args(argv)
    a.jobs = JOBS
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
