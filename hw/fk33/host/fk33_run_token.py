#!/usr/bin/env python3
"""fk33_run_token.py -- drive a WHOLE TOKEN's subsystem-A matvecs through the
FK33, in program order, all 32 layers plus the 15-window lm_head, on one open
device, and compare every result -- and the TOKEN the card's own logits imply
-- against ref/run9b's whole-model stream.

    fk33_run_token.py plan      --ref R.r9bs        no card, no /dev
    fk33_run_token.py selfcheck                     no card, no model
    fk33_run_token.py teeth     --ref R.r9bs        no card, no /dev
    fk33_run_token.py run       --dry-run --ref ... no card, no /dev
    fk33_run_token.py run       --ref R.r9bs        THE CARD

WHY THIS EXISTS
---------------
On 2026-08-29 TRACK LAYERRUN drove ONE transformer layer's subsystem-A matvecs
through the card in program order and Oren ran it: layer 0 (Gated DeltaNet, 10
jobs) and layer 3 (attention, 7 jobs), 88,128 result rows compared element for
element, zero differ, in `chained` mode where every activation after the layer
input is the card's own output
(docs/debugging/2026-08-29_first-layer-in-sequence-on-silicon.md).

NOTHING HAS RUN A WHOLE TOKEN.  This is that tool.  It does not reimplement
LAYERRUN: it IMPORTS hw/fk33/host/fk33_run_layer.py and calls its `make_layer`,
`bind_reference`, `host_rerun`, `check_host_steps` and `run_layer` once per
layer against one open device, one Meter and one compiled oracle, and it adds
exactly the four things a token needs that a layer did not:

  1. TOKEN-LEVEL CHAINING.  In `--mode chained` layer L's input is the CARD's
     own R_X-(L-1), not the reference's.  A layer's re-anchor at its B or C gap
     stays; nothing else is re-anchored, so one wrong bit at layer 0 reaches
     layer 31.
  2. THE TAIL.  The final RMS norm (host, `output_norm.weight`) and the lm_head,
     which is FIFTEEN raw row windows and not one job: `output.weight` is
     248,320 x 4,096 and MAXROWS_BFP is 17,408, so `matvec_int4_desc_axi`
     REFUSES a single-job lm_head in every out_mode (TRACK LMHEAD, `a781326`).
  3. THE TOKEN.  The argmax over the card's OWN 248,320 s32 logits, by
     rtl/sampler_stream.vhd's first-maximum rule, compared against the
     reference stream's `TOKEN` record.  That single integer is the deliverable
     that no per-job table can produce.
  4. A LONG RUN'S OWN FAILURE MODES -- the three below, each of which a
     seventeen-job layer was too short to be exposed to.

WHAT IT COVERS AND WHAT IT DOES NOT -- READ THIS BEFORE QUOTING ANY RESULT
--------------------------------------------------------------------------
`hw/fk33/rtl/fk33_engine.vhd` instantiates `matvec_int4_desc_axi` and NOTHING
ELSE.  Subsystems B (Gated DeltaNet), C (gated attention) and D (the sequencer)
HAVE NEVER RUN ON THIS SILICON.  So what runs on the card here is exactly the
token's subsystem-A matvecs -- 296 inside the 32 layers plus 15 lm_head windows,
311 jobs -- and everything between them runs on the HOST: the 64 RMS norms, the
final norm, the 64 residual adds, the 32 SwiGLUs, and the whole GDN or attention
block of every layer.

THE HONEST DESCRIPTION IS THEREFORE: THIS IS THE MATVEC SKELETON OF A TOKEN,
RUN IN ORDER ON THE CARD, WITH THE NON-MATVEC WORK ON THE HOST.  There are 32
re-anchors, one per layer, at the B or C block that does not exist on this
silicon; they are named, counted and printed, never absorbed.  A token that
completes is not a token that computed, and a token that computed here is not a
token the card computed by itself.

THREE THINGS A LONG RUN MEETS THAT A LAYER DID NOT
--------------------------------------------------
DONE-1, LIVE IN THE BITSTREAM.  TRACK DONE1 (`3ecc729`) MEASURED that
`rtl/matvec_int4_desc_axi.vhd` leaves a 3-core-clock window after a GO in which
STATUS reads done=1, busy=0 -- the PREVIOUS job's completion, indistinguishable
from this one's.  The RTL is fixed (STATUS bit 0 is now `done_l and not
go_now`); THE BITSTREAM ON THE CARD IS NOT.  The engine is never reset between
runs, so every job after the first is a trial of that race and a whole token is
311 of them.  Two independent detectors run here, per job:
  * the BEATS test LAYERRUN wrote (`stale_done_check`), which is blind on a
    same-shape adjacency such as ffn_gate -> ffn_up, and
  * THE POLL WITNESS: the number of STATUS reads after the GO.  N = 1 means the
    very first read already said done.  DERIVED: the SMALLEST job in the token
    is ssm_beta at 32 rows x 4,096 cols = 1 tile x 128 blocks = 128 weight
    beats, which at the MEASURED 21.6 core cycles per beat is 2,765 cycles =
    13.8 us at 200 MHz, against a MEASURED 2.34 us per STATUS read.  So no
    legitimate job can complete inside one poll, and N = 1 is the race lost.
    It is counted per job and it makes the TOKEN inconclusive, not just the job.
  MEASURED 2026-08-30 by Oren: the race did NOT reproduce in 200 trials -- zero
  `after 1 polls`, minimum observed 6.  That is the PREDICTED outcome given a
  ~15 ns window against a microsecond-scale MMIO read, and it is not evidence
  about the RTL.  The witness is kept because it costs nothing and because a
  token is a few hundred more trials of the same race.

THERM-255, WHICH IS NOT THERMAL.  Root-caused 2026-08-30 (`54f45c5`,
docs/debugging/2026-08-30_therm255-is-two-stacks-not-two-copies.md):
`hw/fk33/build_fk33_pcieep.tcl:781-782` wires DRAM_0_STAT_TEMP and
DRAM_1_STAT_TEMP -- TWO PHYSICALLY SEPARATE HBM STACKS -- into hbm_temp0 and
hbm_temp1, and `hw/fk33/rtl/fk33_thermal.vhd` made their EQUALITY a validity
condition, with invalidity turning straight into a halt.  So the guard halted
the compute domain whenever the two stacks differed by one temperature code --
the normal condition for two dies under different load, and guaranteed
transiently at every code crossing because the two accepted values have
independent debounce counters.  MEASURED there: an idle card at code 38 halted
compute 255 times against a halt threshold of 85.

THE TREE IS FIXED AND THE BITSTREAM IS NOT.  `a4a564c` removed the equality
term from `hbm_valid` (and `7a7ec6f` corrected the host-side wording that called
the two ports "copies" and the sticky "a CDC fault" -- do not trust an older
build's string).  **The image loaded on the card predates both**, so for this
run the halt is live and this file is built around it.

WHAT THAT MEANS FOR A TOKEN, AND WHAT THIS FILE DOES ABOUT IT.  The failure is
an ABORT, not a slowdown.  `fk33_run_job.run_job:811` REFUSES to start a job
while compute_halt is asserted -- it calls refuse(), it does not wait -- and
G_MIN_HALT_MS is 100, so a single spurious trip holds the halt for at least
100 ms.  A token is several hundred sequential jobs, so the realistic outcome
is that job k aborts mid-token and leaves a partially advanced sequence.  So:

  * A HALT IS WAITED OUT AND THE JOB IS RETRIED, not treated as fatal.  See
    `run_job_halt_retry`, which is installed over `fk33_run_job.run_job` for the
    duration of the run.  THE RETRY IS SAFE AND THAT IS ARGUED, not assumed: a
    refused GO means the engine never left S_IDLE, so nothing in the chain
    advanced -- the descriptor and the activation are rewritten from host state
    the tool still holds, and the job's inputs are byte-identical.  Chaining
    does not make it unsafe, because a job only enters the chain once it has
    PASSED and a refused job never produced a value at all.
  * A HALT IS NOT EVIDENCE OF A COMPUTE FAULT and is not, by itself, a reason to
    call the arithmetic inconclusive.  Halts and retries get their own column.
    A trip is only allowed to make the token INCONCLUSIVE where it coincides
    with a job whose numbers actually differ -- there, and only there, is the
    disagreement unattributable.
  * THE COUNT IS A LOWER BOUND, and it is printed as one.  MEASURED 2026-08-30:
    400 THERM_STATUS samples taken at job boundaries while compute was active
    caught NOTHING, and the trip appeared only in an idle read afterwards.
    Sampling at job boundaries is far too coarse; this file samples at job
    boundaries, so it UNDERCOUNTS.
  * THE LATCHED CAUSE LIES.  The trip capture is gated on halted/halted_d
    (:963), one cycle after the combinational hbm_hot rose, and samples
    cause/h0_acc/h1_acc in that LATER cycle -- so a transient inequality records
    CAUSE_NONE with equal, benign temperatures.  "cause none" does not mean "no
    cause", and nothing here reports the latched cause as a diagnosis.

A7's OUTSTANDING-COUNT UNDERFLOW, also live and unfixed on the card
(`rtl/axi_rd_fsm.vhd`).  Its hardware signature is a port that silently STOPS
ISSUING AR FOREVER, which presents as a job that never completes and never
errors.  `run_job` already reports that shape; this file names it in the
summary rather than leaving it as a generic timeout, because a long run is far
more exposed to it than a short one.

THE READBACK IS THE COST, AND IT WAS DESIGNED FOR RATHER THAN DISCOVERED
------------------------------------------------------------------------
MEASURED by Oren on 2026-08-29 for ONE Gated DeltaNet layer: 49,152 activation
MMIO writes at 0.85 us, 4,463 status polls at 2.34 us, and 90,240 result
readback reads at 2.88 us -- the readback is 0.260 s and dominates.  There is
no bulk path: `hw/fk33/host/fk33_regs.h` gives Y_IDX/Y_LO/Y_HI and nothing
else, so a row costs one MMIO write plus two MMIO reads and that is a property
of the register map, not of this tool.

DERIVED for a whole token at those rates, and printed by `plan` so the card can
refute it:  1,675,264 result rows (24 GDN layers x 45,120 + 8 attention layers
x 43,008 + 248,320 lm_head rows), i.e. 3,350,528 reads = 9.65 s plus 1,675,264
index writes = 1.42 s; and 1,536,000 activation writes = 1.31 s.  So the token
is expected to be READBACK-BOUND at roughly 11 s of a ~15 s run, and the single
largest item in it is the lm_head's 248,320 rows -- 15% of the whole token's
readback for one tensor.  What this tool does about it: ONE process, one open
device, one compiled oracle, one parsed manifest, and the descriptor for every
one of the 311 jobs placed in its OWN slot of the 311-slot arena the manifest
declares, so no job waits on another's memory.  What it deliberately does NOT
do is skip rows: a sampled readback would make the lm_head cheap and the token
unfalsifiable.

NO AGENT MAY RUN THE DEFAULT PATH.  The hardware boundary in CLAUDE.md is
absolute: an agent writes and exercises this through `plan`, `selfcheck`,
`teeth` and `run --dry-run`, and the run against the card belongs to whoever is
at the bench.
"""

import argparse
import json
import math
import os
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tools"))

import fk33_run_job as J            # noqa: E402  the ONE job runner, reused
import fk33_run_layer as LR         # noqa: E402  the ONE layer runner, reused
import gen_layer_program as L       # noqa: E402  the ONE layer program
import gen_mv4i_desc as G           # noqa: E402  the ONE descriptor builder

DEFAULT_MANIFEST = J.DEFAULT_MANIFEST


class TokenError(Exception):
    pass


# The tail's own seams, out of ref/run9b.c's main() (:1066-1074).  Read from
# the artefact, not from a spec: `R_XN.final` and `LOGITS` and `TOKEN` are
# emitted ONLY when run9b ran all N_LAYER layers, which is why a partial
# reference cannot close a token and this file refuses rather than improvises.
SEAM_FINAL_IN = "R_X-%d"            # % (blocks - 1)
SEAM_FINAL_XN = "R_XN.final"
SEAM_LOGITS = "LOGITS"
SEAM_TOKEN = "TOKEN"
FINAL_NORM_W = "output_norm.weight"
LM_TENSOR = "output.weight"


# ===================================================== the per-layer arg shim
class _LayerArgs(object):
    """fk33_run_layer's entry points take an argparse namespace.  Rather than
    fabricate one per call site, this mirrors exactly the attributes those
    functions read, so a new attribute appearing there fails loudly here
    instead of being silently defaulted."""
    __slots__ = ("layer", "tok", "ref", "manifest", "packed", "ref_manifest",
                 "addr_w", "scratch", "cc", "mode", "dry_run", "timeout",
                 "show", "stop_on_fail", "inject")

    def __init__(self, a, layer):
        self.layer = layer
        self.tok = a.tok
        self.ref = a.ref
        self.manifest = a.manifest
        self.packed = a.packed
        self.ref_manifest = a.ref_manifest
        self.addr_w = a.addr_w
        self.scratch = a.scratch
        self.cc = a.cc
        self.mode = getattr(a, "mode", "anchored")
        self.dry_run = getattr(a, "dry_run", False)
        self.timeout = getattr(a, "timeout", 30.0)
        self.show = getattr(a, "show", 8)
        self.stop_on_fail = getattr(a, "stop_on_fail", False)
        self.inject = list(getattr(a, "inject", []))


def _scratch(a):
    d = a.scratch or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                  "fk33_run_token")
    os.makedirs(d, exist_ok=True)
    return d


# ================================================ the whole token's A program
def make_token(a, out=None):
    """Every layer's plan plus the tail, with GLOBAL descriptor slots.

    WHY GLOBAL SLOTS.  `fk33_run_layer.make_layer` numbers a layer's
    descriptors from the arena base, so layer 0's job 3 and layer 1's job 3
    land on the SAME address.  For one layer that is correct and for a token it
    is a reuse that nothing needs: the manifest declares
    `desc_arena_jobs = 311`, which is exactly the whole token program's A-job
    count (24 GDN x 10 + 8 attention x 7 + 15 lm_head windows), and the arena
    was sized from the FULL token program on purpose
    (tools/gen_layer_program.place_desc_arena).  So every job gets its own slot
    here, which is what subsystem D would do, and it makes each descriptor's
    round-trip check independent of the job before it."""
    out = out or sys.stdout
    s = L.QWEN35_9B
    layers, notes_by_layer = [], {}
    ref = LR.read_r9bs(a.ref)

    upto = a.upto if a.upto is not None else s.blocks
    if not 1 <= upto <= s.blocks:
        raise TokenError("--upto %d is outside 1..%d" % (upto, s.blocks))

    slot = 0
    for il in range(upto):
        la = _LayerArgs(a, il)
        plan = LR.make_layer(la)
        arena, stride, n_slots = (plan["arena_base"], plan["stride"],
                                  plan["n_slots"])
        for j in plan["jobs"]:
            if slot >= n_slots:
                raise TokenError(
                    "the token needs more than the %d descriptor slots the "
                    "manifest declares (desc_arena_jobs).  Nothing may be "
                    "placed outside the arena hbm_map checked." % n_slots)
            j.desc_addr = arena + slot * stride
            slot += 1
        notes_by_layer[il] = LR.bind_reference(plan, ref, a.tok)
        layers.append(plan)

    tail = None
    if upto == s.blocks and not a.no_lmhead:
        tail = make_tail(a, s, slot, layers[0]["arena_base"],
                         layers[0]["stride"], layers[0]["n_slots"])
        slot += len(tail["jobs"])

    return dict(shape=s, layers=layers, notes=notes_by_layer, tail=tail,
                ref=ref, upto=upto, n_slots_used=slot,
                arena_base=layers[0]["arena_base"],
                stride=layers[0]["stride"], n_slots=layers[0]["n_slots"])


class TailJob(object):
    """Deliberately the same attribute names `stale_done_check` and the
    printers read off a layer Job, so the tail is not a special case anywhere
    downstream."""
    __slots__ = ("idx", "gidx", "step", "tensor", "short", "row_start",
                 "logical_row", "n_rows", "n_cols", "M", "K", "w_exp",
                 "out_shift", "mv4i", "hbm_offset", "pieces", "desc_addr",
                 "src_region",
                 "dst_region", "dst_off", "ordinal", "src2", "const_base",
                 "out_mode", "segment", "src_seam", "dst_seam")


def make_tail(a, s, slot0, arena, stride, n_slots):
    """The final norm's target and the lm_head's 15 RAW row windows.

    THE WINDOW LIST IS NOT WRITTEN HERE.  It comes out of
    `gen_layer_program.lmhead_windows`, and the steps come out of the SHIPPING
    `build_plan`, and this refuses to proceed if the two disagree -- the same
    refusal `tools/lmhead_window_check.py` makes, for the same reason: a second
    window list written for a test checks the test."""
    mani_path = a.manifest
    mani = json.load(open(mani_path))
    root = os.path.dirname(os.path.abspath(mani_path))
    by_file = {f["file"]: f for f in mani["files"]}

    lmw = L.lmhead_windows(s)
    steps = L.build_plan(s, lm_windows=lmw)
    sel = L.layer_slice(steps, s.blocks)
    ajobs = [st for st in sel if st.opcode == L.OP_A_JOB]
    got = [(st.row_start, st.n_rows) for st in ajobs]
    if got != [tuple(x) for x in lmw]:
        raise TokenError(
            "the shipping plan's lm_head steps are %r and lmhead_windows() "
            "says %r.  Refusing: a window list that disagrees with the "
            "schedule would check this file against itself." % (got, lmw))
    cover = sum(n for _, n in got)
    if cover != s.vocab_shard:
        raise TokenError("the %d windows cover %d rows and vocab_shard is %d"
                         % (len(got), cover, s.vocab_shard))

    name = LM_TENSOR + ".mv4i"
    ent = by_file.get(name)
    if ent is None:
        raise TokenError("%s is not in %s, so the lm_head is not on the card"
                         % (name, mani_path))
    path = os.path.join(root, name)
    h = G.Mv4iHeader(path)
    if h.M != s.vocab_shard or h.K != s.hidden:
        raise TokenError("%s is %d x %d and the shape says %d x %d"
                         % (name, h.M, h.K, s.vocab_shard, s.hidden))

    # The same load-bearing refusal make_layer makes for a layer's tensors: the
    # reference was built against ONE packed set and the card holds ANOTHER, and
    # comparing across two sets with the same names and different bytes is a
    # wrong-answer report with no fault anywhere.
    if a.ref_manifest:
        b = {f["file"]: f for f in json.load(open(a.ref_manifest))["files"]}
        eb = b.get(name)
        if eb is None:
            raise TokenError("%s is in the run manifest and not in the "
                             "reference manifest" % name)
        da, db = ent.get("blake2b_128"), eb.get("blake2b_128")
        if da is None or db is None:
            raise TokenError("%s carries no blake2b_128 in %s; an absent digest "
                             "must not pass by being absent"
                             % (name, "the run manifest" if da is None
                                else "the reference manifest"))
        if da != db:
            raise TokenError("%s hashes %s on the card's set and %s on the "
                             "reference's" % (name, da, db))

    jobs = []
    for i, st in enumerate(ajobs):
        if slot0 + i >= n_slots:
            raise TokenError("the lm_head needs descriptor slot %d and the "
                             "arena has %d" % (slot0 + i, n_slots))
        if st.out_mode != G.MODE_RAW:
            raise TokenError(
                "lm_head window %d is emitted with out_mode = %d and only RAW "
                "(%d) has no cross-row term, so only RAW lets 15 windows carry "
                "one exponent and be sliced out of a whole-tensor expectation."
                % (i, st.out_mode, G.MODE_RAW))
        j = TailJob()
        j.idx, j.gidx, j.step = i, slot0 + i, st.idx
        j.tensor, j.short = st.tensor, "output.weight w%02d" % i
        j.row_start = j.logical_row = st.row_start
        j.n_rows, j.n_cols = st.n_rows, st.n_cols
        j.M, j.K, j.w_exp, j.out_shift = h.M, h.K, h.w_exp, h.out_shift
        j.mv4i, j.hbm_offset = path, int(ent["hbm_offset"])
        # WHERE EACH SUB-REGION ACTUALLY IS.  Same defect and same fix as
        # `fk33_run_layer.make_layer` (TRACK STRIPEPATH, `d7f96cd`): this file
        # reads the manifest with a bare `json.load` at the top of this
        # function, so `gen_mv4i_desc.load_manifest()`'s refusal of a v2
        # lane-striped manifest never reaches it.  MEASURED 2026-08-30 on the
        # pre-change file against the shipping striped manifest: 15 window
        # descriptors emitted, 0 errors, and 405 of 405 sub-region bases WRONG
        # -- every one `hbm_offset + <file offset>` where `hbm_offset` names
        # only the tensor's 4 KB header.
        #
        # THE TRAP THAT HIDES IT HERE.  `output.weight.mv4i` is placed at
        # hbm_offset 0 under BOTH layouts, so the pre-change tail's 15
        # descriptors are BYTE-IDENTICAL between the flat and the striped
        # manifest.  Diffing the two runs shows nothing at all; only a
        # comparison against the manifest's `pieces` sees it.
        #
        # None for a v1 flat manifest, in which case `build_descriptor`
        # reduces to exactly the old `hbm_base + file offset`; a
        # `{file_offset: (hbm_offset, nbytes)}` map for a v2 one.  The join is
        # the FILE OFFSET, never a lane, kind or segment label -- see
        # `gen_mv4i_desc.sub_base()`.
        #
        # No `hbm_map.plan().check()` is added here, for a stronger version of
        # the reason STRIPEPATH recorded in `make_layer`: `make_token` above
        # calls `fk33_run_layer.make_layer` for EVERY layer before it reaches
        # this function, and each of those calls `place_desc_arena()`, which
        # runs `hbm_map.plan(...).check()` and raises SystemExit on any fault.
        # A manifest whose pieces overlap, straddle a stack or sit off a 4 KB
        # line has already been refused 32 times over.  A 33rd copy would earn
        # no kills -- MEASURED, TOKENSTRIPE teeth table, the `runlayer` column.
        j.pieces = G.piece_extents(ent)
        j.desc_addr = arena + (slot0 + i) * stride
        j.src_region, j.dst_region, j.dst_off = st.src, st.dst, st.dst_off
        j.ordinal, j.src2, j.const_base = st.ordinal, st.src2, st.const_base
        j.out_mode, j.segment = st.out_mode, None
        j.src_seam, j.dst_seam = SEAM_FINAL_XN, SEAM_LOGITS
        jobs.append(j)

    return dict(jobs=jobs, mv4i=path, header=h, hbm_offset=int(ent["hbm_offset"]),
                windows=got, arena_base=arena, stride=stride)


# ================================================== the tail's host arithmetic
def tail_host_norm(tok_plan, ref, tok, packed_dir, x_seam=None):
    """R_X-31 -> the final RMS norm -> R_XN.final, and check it against the
    reference's own R_XN.final when the input IS the reference's own R_X-31.

    Returns (mant, exp, row) where row is the check line.  `x_seam` overrides
    the input, which is what chained mode passes: the CARD's R_X-31."""
    s = tok_plan["shape"]
    blob, f32idx = LR.load_f32_index(packed_dir)
    wt = LR.f32_tensor(blob, f32idx, FINAL_NORM_W)
    if len(wt) != s.hidden:
        raise TokenError("%s has %d elements and hidden is %d"
                         % (FINAL_NORM_W, len(wt), s.hidden))
    src_name = SEAM_FINAL_IN % (s.blocks - 1)
    d = ref.get((SEAM_FINAL_XN, tok))
    if d is None:
        raise TokenError(
            "the reference stream carries no %s.  ref/run9b emits it, LOGITS "
            "and TOKEN only when it ran all %d layers -- regenerate with "
            "--layers %d." % (SEAM_FINAL_XN, s.blocks, s.blocks))
    if x_seam is None:
        src = ref.get((src_name, tok))
        if src is None:
            raise TokenError("the reference stream carries no %s" % src_name)
        xm, xe = list(src.mant), src.exp
    else:
        xm, xe = x_seam
    if len(xm) != s.hidden:
        raise TokenError("%s has %d elements and hidden is %d"
                         % (src_name, len(xm), s.hidden))
    vals = [math.ldexp(v, -xe) for v in xm]
    m, e = LR.reg_put(LR.host_rmsnorm(vals, wt))
    nd = sum(1 for i in range(len(m)) if m[i] != d.mant[i])
    row = dict(kind="norm", produces=SEAM_FINAL_XN, ndiff=nd, dexp=e - d.exp,
               n=len(m), detail="%s -> %s" % (src_name, SEAM_FINAL_XN),
               ok=(nd == 0 and e == d.exp))
    return m, e, row


def build_lm_oracle(scratch, cc="cc"):
    src = os.path.join(HERE, "lmhead_raw_oracle.c")
    exe = os.path.join(scratch, "lmhead_raw_oracle")
    dep = os.path.join(REPO, "ref", "matvec_int4.c")
    if (not os.path.exists(exe)
            or os.path.getmtime(exe) < max(os.path.getmtime(src),
                                           os.path.getmtime(dep))):
        cmd = [cc, "-O2", "-w", "-I", os.path.join(REPO, "ref"),
               "-o", exe, src, "-lm"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            raise TokenError("could not build the lm_head oracle:\n  %s\n%s"
                             % (" ".join(cmd), r.stderr))
    return exe


def lm_oracle_run(tail, xm, xe, scratch, cc="cc", tag="ref"):
    """The whole-tensor RAW lm_head, as s32.  Returns
    (values, y_exp, argmax_index, sat, wall)."""
    exe = build_lm_oracle(scratch, cc)
    xp = os.path.join(scratch, "lmhead_x_%s.i16" % tag)
    yp = os.path.join(scratch, "lmhead_y_%s.s32" % tag)
    with open(xp, "wb") as fp:
        fp.write(struct.pack("<%dh" % len(xm), *xm))
    t0 = time.time()
    r = subprocess.run([exe, tail["mv4i"], xp, str(xe), yp],
                       capture_output=True, text=True)
    wall = time.time() - t0
    got = {}
    for line in r.stdout.splitlines():
        f = line.split()
        if f and f[0] == "BAD":
            raise TokenError("lmhead_raw_oracle refused it: %s" % line.strip())
        if f:
            got[f[0]] = f[1:]
    if r.returncode or "OK" not in got:
        raise TokenError("lmhead_raw_oracle failed (rc=%d):\n%s\n%s"
                         % (r.returncode, r.stdout, r.stderr))
    m = int(got["HEAD"][0])
    y = list(struct.unpack("<%di" % m, open(yp, "rb").read()))
    y_exp = int(got["YEXP"][0])
    want = tail["header"].w_exp + xe - tail["header"].out_shift
    if y_exp != want:
        raise TokenError("the oracle reports y_exp = %d and raw mode's rule "
                         "w_exp + x_exp - out_shift is %d" % (y_exp, want))
    return y, y_exp, int(got["ARGMAX"][0]), int(got["SAT"][0]), wall


def _f32(x):
    """The float32 a C `float` assignment would produce, exactly."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def check_lm_against_reference(tail, y, y_exp, ref, tok, out=None):
    """Tie the oracle's s32 to the reference stream's own LOGITS record.

    THIS IS THE STEP THAT MAKES THE ORACLE MORE THAN A RE-RUN OF ITSELF.  The
    oracle calls mv4i_matvec, which is what ref/run9b.c's lm_head() calls, so
    agreeing with it says nothing about the arithmetic; what it says is that
    the ACTIVATION this file pulled out of R_XN.final and the EXPONENT it read
    off that seam are the ones the reference used.  A wrong x or a wrong
    exponent shows up here and nowhere else on the host side.

    THE COMPARISON DIRECTION IS DELIBERATE AND IT IS LOSSY IN ONE DIRECTION.
    run9b writes LOGITS as float32 (`seam_f32`, ref/run9b.c:353) while the card
    publishes raw s32, so s32 -> f32 is many-to-one: for |y| >= 2^24 several
    adjacent s32 values round to the same float.  So this compares
    float32(ldexp(y, -e)) against the stored float32 BIT FOR BIT, which is
    exact in the direction it is used (equal s32 must give an equal float) and
    is silent about a low-bit s32 error on a large logit.  The bound is stated
    rather than hidden, and it is why the TOKEN record -- an integer, exactly
    comparable -- is the seam that decides the run."""
    out = out or sys.stdout
    d = ref.get((SEAM_LOGITS, tok))
    if d is None:
        raise TokenError("the reference stream carries no %s" % SEAM_LOGITS)
    if d.kind != LR.KIND_F32:
        raise TokenError("%s is kind %d, not F32" % (SEAM_LOGITS, d.kind))
    if d.n != len(y):
        raise TokenError("%s has %d elements and the oracle produced %d"
                         % (SEAM_LOGITS, d.n, len(y)))
    e = -y_exp
    nbad, first, big = 0, -1, 0
    for i in range(len(y)):
        if abs(y[i]) >= (1 << 24):
            big += 1
        if _f32(math.ldexp(y[i], e)) != d.mant[i]:
            nbad += 1
            if first < 0:
                first = i
    out.write("\nthe lm_head oracle against the reference's own LOGITS "
              "record:\n")
    out.write("  compared    %d of %d logits, %d differ%s\n"
              % (len(y), d.n, nbad,
                 "" if first < 0 else " (first at index %d)" % first))
    out.write("  resolution  %d of %d have |s32| >= 2^24, where s32 -> f32 is "
              "many-to-one\n              and this comparison cannot see a "
              "low-bit error\n" % (big, len(y)))
    return nbad == 0, nbad, big


def argmax_first(v):
    """rtl/sampler_stream.vhd seeds its candidate with index 0 and displaces it
    only on a STRICT '>', so the FIRST maximum wins; ref/run9b.c:372 is the
    same rule.  UNEXERCISED wherever the logits are all distinct, which they
    are on the reference prompt -- so agreement is not evidence about ties."""
    bi = 0
    for i in range(1, len(v)):
        if v[i] > v[bi]:
            bi = i
    return bi


def ref_token_id(ref, tok):
    d = ref.get((SEAM_TOKEN, tok))
    if d is None:
        raise TokenError(
            "the reference stream carries no %s record.  ref/run9b writes it "
            "only on a full-model run; regenerate with --layers 32."
            % SEAM_TOKEN)
    if d.kind != LR.KIND_S32 or d.n != 1:
        raise TokenError("%s is kind %d with %d elements; expected one S32"
                         % (SEAM_TOKEN, d.kind, d.n))
    return d.mant[0]


# ==================================================== the metering, per token
class TokenMeter(LR.Meter):
    """LR.Meter plus the POLL WITNESS for DONE-1.

    `run_layer` resets the meter before every job, so the log always holds
    exactly one job.  Harvesting on reset therefore captures each job's own
    STATUS traffic, VALUE BY VALUE, without scraping anyone's prose -- which
    matters because the thing being counted is a race whose only evidence is a
    number that a change of wording would silently take away."""

    def __init__(self, inner, kind, regs):
        self.regs = regs
        self.polls = []          # one (n, first_value, us) per completed job
        LR.Meter.__init__(self, inner, kind)

    def harvest(self):
        """Idempotent BY CONSTRUCTION, because it is called from two places --
        `reset()` before each job and explicitly after the last one -- and a
        harvest that re-scanned already-counted entries reported 22 witnesses
        for 20 jobs on the first dry run.  `_hpos` is how far the scan has got;
        the log itself is left alone, because run_layer reads Y_LO/Y_HI back
        out of it after the job."""
        log = getattr(self, "log", None)
        start = getattr(self, "_hpos", 0)
        if not log or start >= len(log):
            return
        self._hpos = len(log)
        log = log[start:]
        ctrl = self.regs["FK33_ENG_CTRL"]
        stat = self.regs["FK33_ENG_STATUS"]
        go_t, n, first, us = None, 0, None, None
        for t, dt, k, o, v in log:
            if k == "w" and o == ctrl and (v & 1):
                go_t = t + dt
                n, first, us = 0, None, None
            elif k == "r" and o == stat and go_t is not None:
                n += 1
                if first is None:
                    first, us = v, (t - go_t) * 1e6
        if go_t is not None:
            self.polls.append((n, first, us))

    def reset(self):
        self.harvest()
        LR.Meter.reset(self)
        self._hpos = 0


class GuardLog(object):
    """Everything THERM-255 did to this run, recorded BY REGISTER VALUE.

    Two distinct events, kept apart because they mean different things:

      REFUSAL  the guard would not let a job start -- a live compute_halt, or
               the GO_BLOCKED sticky after a swallowed GO.  The job did not
               run, so there is no result to judge; it is waited out and the
               job is retried.
      TRIP     the trip counter moved ACROSS a job that DID run.  That job has
               a result, and whether the result is right is a separate question
               from whether the guard fired.  It is retried too, because a
               clean repeat is worth more than an unattributable first attempt,
               and a job is idempotent (see install_halt_retry).

    Both are detected by reading ENGX_STAT and THERM_STATUS directly, never by
    matching on another module's wording.

    THE COUNT IS A LOWER BOUND AND IT SAYS SO.  MEASURED 2026-08-30: 400
    THERM_STATUS reads taken at job boundaries while compute was active caught
    nothing, and the trip appeared only in an idle read afterwards.  This file
    samples at job boundaries too, so a halt that rises and falls inside one
    job's compute is invisible here.  Reporting the number as a total would be
    the measurement trap, so it is reported as a floor."""

    def __init__(self):
        self.refusals = []   # (key, attempt, waited_s, cleared, why)
        self.trips = []      # (key, attempt, before, after, recovered)

    def refusal(self, key, attempt, waited, cleared, why):
        self.refusals.append((key, attempt, waited, cleared, why))

    def trip(self, key, attempt, before, after, recovered):
        self.trips.append((key, attempt, before, after, recovered))

    @property
    def n_refusals(self):
        return len(self.refusals)

    @property
    def waited(self):
        return sum(e[2] for e in self.refusals)

    @property
    def unrecovered(self):
        return [e for e in self.refusals if not e[3]]

    @property
    def n_trips(self):
        return len(self.trips)

    @property
    def trips_unrecovered(self):
        return [e for e in self.trips if not e[4]]


_ORIG_RUN_JOB = J.run_job


def install_halt_retry(regs, log, retries=8, wait_s=5.0, poll_s=0.02,
                       sleep=time.sleep):
    """Install a wrapper around `fk33_run_job.run_job` that waits out a
    spurious compute_halt and retries the job.

    WHY A WRAPPER AND NOT AN EDIT.  `fk33_run_job.py` and
    `fk33_run_layer.py` belong to other tracks and this file may not change
    them; `run_layer` resolves `J.run_job` at call time, so binding a wrapper
    over the module attribute is the only way to get a retry into the loop
    without a second copy of the register protocol.  It is installed for the
    duration of one run and restored in a finally, and the original is captured
    at import so a second install cannot nest.

    WHY THE RETRY IS SAFE.  `run_job` refuses in exactly two places for a halt:
    before it writes anything (ENGX_STAT bit 0, the LIVE halt), and after the
    GO when the guard swallowed it (ENGX_STAT bit 1, GO_BLOCKED sticky).  In
    both the engine never left S_IDLE, so no descriptor was consumed, no Y
    register moved and no region was written.  The retry rewrites the same
    descriptor bytes and the same activation from host state this tool still
    holds, so the second attempt's inputs are byte-identical to the first's.
    Chaining does not make it unsafe: a value only enters the chain after its
    job PASSED, and a refused job produced none.

    THE DETECTION IS BY REGISTER VALUE, NOT BY MESSAGE.  A wrapper that matched
    on `run_job`'s wording would stop working silently the day the wording
    changed, and the thing it is detecting is the one condition a long run has
    to survive."""
    def _wait_clear(bar):
        """Wait for the LIVE halt to drop.  Bounded by BOTH wall time and poll
        count: with a no-op sleep (the dry run) a purely time-bounded loop
        would spin for the whole budget, and with a real sleep a purely
        count-bounded loop would not respect --halt-wait."""
        # poll_s = 0 is a legitimate caller intent ("do not sleep at all") and
        # used to be a ZeroDivisionError here, raised before the job ran and
        # therefore indistinguishable from a guard refusal.  Found while
        # writing the wrapper's teeth rows below, which are its first coverage.
        cap = max(1, int(wait_s / poll_s)) if poll_s > 0 else 1
        t0, n = time.time(), 0
        while (bar.rd(regs["FK33_ENGX_STAT"]) & 1):
            if n >= cap or time.time() - t0 >= wait_s:
                break
            sleep(poll_s)
            n += 1
        return time.time() - t0

    # There is deliberately NO _trips(bar) helper here any more.  Sampling the
    # trip counter around a call that clears it is the phantom-retry hazard
    # described below; the observation arrives on p["therm"] instead.

    def run_job_halt_retry(p, regs_, bar, hbm, a, out=sys.stdout):
        key = (p["fields"].get("tensor", "?"), p["desc_addr"])
        last_exc, last_res = None, None
        for attempt in range(retries + 1):
            # Wait out a LIVE halt before even trying: G_MIN_HALT_MS is 100 ms
            # and the dwell is self-clearing, so waiting is the correct action
            # and refusing is not.
            waited = _wait_clear(bar)
            p.pop("therm", None)       # never read a previous job's record
            try:
                res = _ORIG_RUN_JOB(p, regs_, bar, hbm, a, out)
            except J.RunError as e:
                last_exc = e
                x = bar.rd(regs["FK33_ENGX_STAT"])
                halt_now, go_blocked = bool(x & 1), bool(x & 2)
                if not (halt_now or go_blocked):
                    raise                  # not the guard; someone else's fault
                w2 = _wait_clear(bar)
                cleared = not (bar.rd(regs["FK33_ENGX_STAT"]) & 1)
                bar.wr(regs["FK33_ENGX_STAT"], 2)   # drop the GO_BLOCKED sticky
                log.refusal(key, attempt, waited + w2, cleared,
                            "live halt" if halt_now else "GO_BLOCKED")
                out.write("guard       the guard REFUSED this job (ENGX_STAT="
                          "0x%08X); waited %.3f s, halt %s -- retrying "
                          "(attempt %d of %d).  THERM-255 is a two-stack "
                          "inequality, not heat.\n"
                          % (x, waited + w2, "cleared" if cleared
                             else "STILL ASSERTED", attempt + 2, retries + 1))
                if not cleared:
                    break
                continue
            # The job RAN.  Did the guard fire across it?
            #
            # This USED TO sample the counter here, around the call, and the
            # comment said: "Read the counter, do not read run_job's prose:
            # [...] a check that depended on another module's wording would
            # stop working without saying so."  That rule is right and is kept.
            # What changed is that run_job now CLEARS the counter before the
            # job, because it saturates at 255 and 'it did not move' is false
            # forever at the ceiling (open issue THERM-255).  Sampling around a
            # call that clears would see t1 < t0 on EVERY job and burn a
            # phantom retry on every job of every layer of every token -- a
            # dead veto converted into a live false alarm, which is worse,
            # because it would read as evidence about THERM-255 itself.
            #
            # So run_job publishes a STRUCTURED observation on the plan dict
            # this caller already owns, and this reads that.  A dict of ints is
            # not prose: `moved` is a boolean the producer computed from two
            # readings taken either side of the job, with a base it proved was
            # 0.  The rule the old comment states is about not parsing text,
            # and a missing or malformed field is a REFUSAL here rather than a
            # silent pass, so it still cannot stop working without saying so.
            th = p.get("therm")
            if not isinstance(th, dict) or th.get("moved") is None:
                raise J.RunError(
                    "fk33_run_job returned without publishing p['therm'], so "
                    "this wrapper cannot tell whether the thermal guard fired "
                    "across the job.  Sampling the counter here instead is "
                    "NOT a fallback: run_job clears it before the job, so a "
                    "sample either side would read as a trip on every single "
                    "job.  The two files must be updated together; see "
                    "docs/debugging/2026-08-30_tripveto-every-consumer-of-a-"
                    "saturating-counter.md section 5.")
            t0, t1 = th["trip0"], th["trip1"]
            if not th["moved"] or res[0] == J.Verdict.PASS:
                if th["moved"]:
                    log.trip(key, attempt, t0, t1, True)
                return res
            last_res = res
            more = attempt < retries
            log.trip(key, attempt, t0, t1, more)
            out.write("guard       the trip counter moved %d -> %d ACROSS this "
                      "job, so fk33_run_job called it\n            "
                      "INCONCLUSIVE.  %s\n"
                      % (t0, t1, "Retrying: the job is idempotent and a clean "
                         "repeat is worth more than an unattributable first "
                         "attempt." if more
                         else "Out of retries; reporting it as it stands."))
            if not more:
                return res
        if last_res is not None:
            return last_res
        raise J.RunError(
            "the guard refused this job %d times and the halt did not clear "
            "within %.1f s each time.  THERM-255 halts the compute domain "
            "whenever the two HBM STACKS differ by one temperature code "
            "(fk33_thermal.vhd:816/:827), so this is not heat and not a "
            "compute fault -- but the job never started, so there is no "
            "result.  Last refusal: %s" % (retries + 1, wait_s, last_exc))

    J.run_job = run_job_halt_retry
    return run_job_halt_retry


def uninstall_halt_retry():
    J.run_job = _ORIG_RUN_JOB


def poll_races(meter):
    """Jobs whose FIRST STATUS read after the GO already reported done.

    See the module header for why N = 1 cannot be a legitimate completion at
    any job size in this model: the smallest job needs 13.8 us of compute and a
    STATUS read costs 2.34 us."""
    return [i for i, (n, first, us) in enumerate(meter.polls)
            if n <= 1 and first is not None and (first & 1)]


# ========================================================= the dry transport
class _TokenDryBar(object):
    """A simulated register plane spanning the WHOLE token.

    A dry-run PASS is a statement about this tool's sequencing and its checks
    and NOTHING about the card: the numbers never went near an engine.  It is
    a separate class from fk33_run_layer._DryBar for one reason -- that one
    keys its expectation table on a single layer's `plan["jobs"]` and answers
    from the reference's dst_seam, and neither is true of a raw lm_head window,
    which has no dst seam at all.  This one is handed an explicit table.

    `busy_polls` defaults to 3 and not to fk33_run_job.SimBar's 1, deliberately:
    a model that completes on the first poll would make EVERY dry-run job look
    like the DONE-1 race, and the witness would be worthless.  `poll1` is then
    an injectable fault, which is the only honest way to have it."""

    INJECT = ("bad-row", "stale", "trip", "halt", "halt-stuck", "wrong-exp",
              "poll1", "never-done")

    def __init__(self, regs, inject=None):
        self.regs = regs
        self.sim = J.SimBar(regs, {}, {})
        self.byslot = {}
        self.cur = None
        self.prev = None
        # `halt` models the SWALLOWED GO, which is the shape THERM-255 actually
        # produces on a job that was allowed to start: the guard masks CTRL bit
        # 0 and sets the GO_BLOCKED sticky, so run_job refuses AFTER writing the
        # descriptor and the activation.  It is armed ONCE, so the retry sees a
        # clean engine -- which is the behaviour under test.  `halt-stuck` never
        # clears and is the abort case.
        self._armed_go_block = False
        self._go_block_done = set()
        self.inject = {}
        for spec in (inject or []):
            name, _, which = spec.partition(":")
            if name not in self.INJECT:
                raise TokenError("unknown --inject %r; known: %s"
                                 % (name, ", ".join(self.INJECT)))
            self.inject.setdefault(int(which or 0), []).append(name)

    def load(self, entries):
        """entries: {desc_addr: dict(gidx, n_rows, K, ymant, y_exp)}.  Called
        once per layer and once for the tail, because a token's 311 jobs do not
        all fit in memory as expectation tables at once -- the lm_head alone is
        248,320 rows."""
        self.byslot.update(entries)

    def _beats(self, ent):
        return ((ent["n_rows"] + 47) // 48) * (ent["K"] // 32)

    def rd(self, off):
        r = self.regs
        if self.cur is not None:
            src = self.cur
            if "stale" in self.inject.get(self.cur["gidx"], ()) \
                    and self.prev is not None:
                src = self.prev
            if off == r["FK33_ENG_BEATS"]:
                return self._beats(src)
            if off == r["FK33_ENG_CYCLES"]:
                return int(self._beats(src) * 21.6)
        return self.sim.rd(off)

    def wr(self, off, val):
        r = self.regs
        if off == r["FK33_ENG_CTRL"] and (val & 1) and self._armed_go_block:
            # The guard swallowed this GO.  Model it exactly as
            # rtl/fk33_engine.vhd does -- CTRL bit 0 masked, GO_BLOCKED sticky
            # set, the engine never started -- and disarm, so the retry runs
            # against a clean engine.
            self._armed_go_block = False
            self.sim.f = dict(self.sim.f, halt=1)
            self.sim.wr(off, val)
            self.sim.f.pop("halt", None)
            return
        self.sim.wr(off, val)
        # ON THE HI WRITE, NOT THE LO.  The arena is above 4 GiB, so a pointer
        # is only complete after both halves; LAYERRUN found this the hard way
        # by keying on the LO write and getting every mantissa wrong.
        if off == r["FK33_ENG_DESC_PTR_HI"]:
            nxt = self.byslot.get(self.sim.dptr)
            if nxt is not None:
                self.prev, self.cur = self.cur, nxt
                self.sim.o = dict(ymant=nxt["ymant"], y_exp=nxt["y_exp"],
                                  w_beats=self._beats(nxt))
                faults = self.inject.get(nxt["gidx"], ())
                f = dict(busy_polls=3)
                if "poll1" in faults:
                    f["busy_polls"] = 1
                if "bad-row" in faults:
                    f["bad_row"] = 0
                if "wrong-exp" in faults:
                    f["y_exp"] = (nxt["y_exp"] + 1) & 0xFFFFFFFF
                if "trip" in faults:
                    f["trip_during"] = 1
                # ARMED ONCE PER FAULT, not once per descriptor write.  The
                # retry rewrites DESC_PTR_HI, so re-arming here would make the
                # halt permanent and the retry untestable -- which is exactly
                # what the first teeth run showed.
                self._armed_go_block = ("halt" in faults
                                        and nxt["gidx"] not in self._go_block_done)
                if self._armed_go_block:
                    self._go_block_done.add(nxt["gidx"])
                if "halt-stuck" in faults:
                    f["halt"] = 1
                if "never-done" in faults:
                    f["never_done"] = 1
                # The trip counter is CUMULATIVE and deliberately survives the
                # job boundary: run_job reads it before and after each job, so
                # a model that zeroed it would make the job AFTER an injected
                # trip look like a second trip running backwards.
                keep = self.sim.trip
                self.sim.f = f
                self.sim.trip = keep
                self.sim.started = False

    def close(self):
        self.sim.close()


# ======================================================== running the token
def _gidx(desc_addr, arena, stride):
    """The GLOBAL job ordinal, recovered from the slot the job's descriptor
    occupies.  `--inject NAME:N` names this number, and it is the same number
    on both sides because there is only one place it is computed."""
    return (desc_addr - arena) // stride


def _entries_for_layer(plan, ref, tok, arena, stride):
    ent = {}
    for j in plan["jobs"]:
        d = ref[(j.dst_seam, tok)]
        ent[j.desc_addr] = dict(
            gidx=_gidx(j.desc_addr, arena, stride), n_rows=j.n_rows, K=j.K,
            ymant={i: d.mant[i] & 0xFFFFFFFFFFFFFFFF for i in range(j.n_rows)},
            y_exp=d.exp)
    return ent


def _seam_from(mant, exp, name, tok, layer):
    return LR.Seam(name, tok, layer, LR.KIND_BFP16, exp, list(mant))


def run_token(a, tp, regs, bar, hbm, out=None):
    """Every layer in program order on one open device, then the tail."""
    out = out or sys.stdout
    w = out.write
    s = tp["shape"]
    ref = tp["ref"]
    chained = a.mode == "chained"
    # The PRISTINE reference is never mutated; `ref_run` is what the layer
    # runner is handed, and in chained mode its R_X-(L-1) record is replaced by
    # the card's own.  Two dicts and not one, so that every EXPECTATION stays
    # the reference's while every INPUT can be the card's.
    ref_run = dict(ref)

    quiet = LR._Sink()
    per_layer, reanchors, halted = [], [], None
    t0_all = time.time()
    therm0 = bar.rd(regs["FK33_THERM_STATUS"])
    trips0 = (therm0 >> 16) & 0xFF

    for plan in tp["layers"]:
        il = plan["layer"]
        la = _LayerArgs(a, il)
        if a.dry_run:
            bar.inner.load(_entries_for_layer(plan, ref, a.tok,
                                              tp["arena_base"], tp["stride"]))
        sink = LR._Sink() if not a.verbose else None
        t0 = time.time()
        results, t_layer, anch, reanch, live, layer_out = LR.run_layer(
            la, plan, ref_run, a.tok, regs, bar, hbm,
            out=(sink if sink is not None else out))
        bar.harvest()
        wall = time.time() - t0

        npass = sum(1 for r in results if r["verdict"] == J.Verdict.PASS)
        ninc = sum(1 for r in results if r["verdict"] == J.Verdict.INCONCLUSIVE)
        nfail = len(results) - npass - ninc
        partial = len(results) != len(plan["jobs"])
        ok = (not partial and nfail == 0 and ninc == 0
              and (layer_out is None or layer_out["ok"]))

        rec = dict(layer=il, kind="attn" if plan["is_attn"] else "gdn",
                   results=results, npass=npass, nfail=nfail, ninc=ninc,
                   partial=partial, wall=wall, layer_out=layer_out, ok=ok,
                   rows=sum(r["job"].n_rows for r in results),
                   text=(sink.text if sink is not None else ""))
        per_layer.append(rec)
        for nm, why in reanch:
            reanchors.append((il, nm, why))

        w("layer %-3d %-4s %2d/%2d jobs PASS  %6d rows  %6.3f s  %s\n"
          % (il, rec["kind"], npass, len(plan["jobs"]), rec["rows"], wall,
             ("out %s" % ("MATCH" if layer_out and layer_out["ok"]
                          else ("%d/%d differ" % (layer_out["ndiff"],
                                                  layer_out["n"])
                                if layer_out else "-- (anchored)"))
              if chained else "anchored")))
        out.flush() if hasattr(out, "flush") else None

        if chained:
            name = "R_X-%d" % il
            if layer_out is not None and layer_out["ndiff"] >= 0 \
                    and ("R_X-%d" % il) in live:
                m, e = live["R_X-%d" % il]
                ref_run[(name, a.tok)] = _seam_from(m, e, name, a.tok, il)
            else:
                # The layer did not close, so the next layer cannot be fed the
                # card's own output.  Re-anchor by name rather than continue on
                # a value nothing produced.
                reanchors.append((il, name, "layer %d did not close, so the "
                                            "next layer was re-anchored to the "
                                            "reference" % il))
        if not ok and not a.keep_going:
            halted = il
            break

    # ------------------------------------------------------------ the tail
    tail_rec = None
    if tp["tail"] is not None and halted is None:
        tail_rec = run_tail(a, tp, regs, bar, hbm, ref_run, out=out)

    therm1 = bar.rd(regs["FK33_THERM_STATUS"])
    trips1 = (therm1 >> 16) & 0xFF
    return dict(per_layer=per_layer, tail=tail_rec, reanchors=reanchors,
                halted=halted, wall=time.time() - t0_all,
                trips0=trips0, trips1=trips1)


def run_tail(a, tp, regs, bar, hbm, ref_run, out=None):
    out = out or sys.stdout
    w = out.write
    s = tp["shape"]
    ref = tp["ref"]
    tail = tp["tail"]
    scratch = _scratch(a)
    chained = a.mode == "chained"

    w("\nthe tail -- the final norm on the host, then the lm_head as %d RAW "
      "windows on the card\n" % len(tail["jobs"]))

    # ---- the final norm.  In chained mode its input is the CARD's R_X-31.
    x_seam = None
    src_name = SEAM_FINAL_IN % (s.blocks - 1)
    if chained:
        sr = ref_run.get((src_name, a.tok))
        if sr is None:
            raise TokenError("no %s to norm" % src_name)
        x_seam = (list(sr.mant), sr.exp)
    xm, xe, nrow = tail_host_norm(tp, ref, a.tok, a.packed, x_seam=x_seam)
    w("  final norm  %s -> %s: %d of %d mantissas differ from the reference, "
      "exp d=%d\n" % (src_name, SEAM_FINAL_XN, nrow["ndiff"], nrow["n"],
                      nrow["dexp"]))
    rs0 = ref[(SEAM_FINAL_XN, a.tok)]
    if not chained:
        # ANCHORED means every job's x is the REFERENCE's, and the lm_head is
        # a job like any other.  The host norm above still RAN, because it is
        # the check that the host reproduces the reference -- but its output is
        # not what gets written to the card here.
        xm, xe = list(rs0.mant), rs0.exp
        w("  anchored    the lm_head's x is the reference's own %s, not the "
          "one just derived\n" % SEAM_FINAL_XN)

    # ---- the expectation.  Once from the reference's own R_XN.final, always;
    # a second time from the card-derived one only if it actually differs.
    rs = ref[(SEAM_FINAL_XN, a.tok)]
    y_ref, e_ref, am_ref, sat_ref, wall_ref = lm_oracle_run(
        tail, list(rs.mant), rs.exp, scratch, a.cc, tag="ref")
    ok_log, nbad_log, nbig = check_lm_against_reference(
        tail, y_ref, e_ref, ref, a.tok, out=out)
    ref_tok = ref_token_id(ref, a.tok)
    w("  reference   %s = %d; the oracle's own argmax over its s32 is %d\n"
      % (SEAM_TOKEN, ref_tok, am_ref))
    if am_ref != ref_tok:
        raise TokenError(
            "the oracle's argmax over the reference's own activation is %d and "
            "the stream's TOKEN record is %d.  The two sides of the host "
            "comparison already disagree; nothing about a card run would be "
            "attributable." % (am_ref, ref_tok))

    same_x = (list(xm), xe) == (list(rs.mant), rs.exp)
    if same_x:
        y, y_exp = y_ref, e_ref
        w("  activation  the %s this run derived is IDENTICAL to the "
          "reference's, so the\n              expectation is unchanged "
          "(oracle %.1f s, run once)\n" % (SEAM_FINAL_XN, wall_ref))
    else:
        y, y_exp, am2, sat2, wall2 = lm_oracle_run(
            tail, xm, xe, scratch, a.cc, tag="run")
        w("  activation  the %s this run derived DIFFERS from the "
          "reference's, so the\n              expectation was recomputed from "
          "it (oracle %.1f s)\n" % (SEAM_FINAL_XN, wall2))

    # ---- the 15 windows on the card
    class _JA:
        pass
    ja = _JA()
    ja.timeout, ja.show, ja.addr_w = a.timeout, a.show, a.addr_w

    if a.dry_run:
        ent = {}
        for j in tail["jobs"]:
            ent[j.desc_addr] = dict(
                gidx=_gidx(j.desc_addr, tail["arena_base"], tail["stride"]),
                n_rows=j.n_rows, K=j.K,
                ymant={i: y[j.row_start + i] & 0xFFFFFFFFFFFFFFFF
                       for i in range(j.n_rows)},
                y_exp=y_exp & 0xFFFFFFFF)
        bar.inner.load(ent)

    got_all = [None] * tail["header"].M
    results = []
    for j in tail["jobs"]:
        d = G.build_descriptor(
            tail["header"], j.hbm_offset, j.n_rows, xe,
            out_mode=j.out_mode, cb_load=True, addr_w=a.addr_w,
            row_start=j.row_start, src_region=j.src_region,
            dst_region=j.dst_region, dst_offset=j.dst_off, ordinal=j.ordinal,
            src_region2=j.src2, const_base=j.const_base, const_exp=0,
            pieces=j.pieces)
        bad = G.rtl_would_reject(d, build=LR._build(a), desc_addr=j.desc_addr)
        if bad:
            raise TokenError(
                "lm_head window %d would be REFUSED by the gateware before it "
                "ran:\n  " % j.idx
                + "\n  ".join("%s %s" % ("0x%X" % c if c is not None else "----",
                                         n) for c, n in bad))
        p = dict(desc=d, fields=d.fields, desc_addr=j.desc_addr,
                 stride=tail["stride"],
                 oracle=dict(x=[m & 0xFFFF for m in xm],
                             ymant={r: y[j.row_start + r] & 0xFFFFFFFFFFFFFFFF
                                    for r in range(j.n_rows)},
                             y_exp=y_exp))
        bar.reset()
        if hasattr(hbm, "reset"):
            hbm.reset()
        buf = LR._Sink()
        t0 = time.time()
        try:
            verdict, detail = J.run_job(p, regs, bar, hbm, ja, buf)
        except J.RunError as e:
            verdict, detail = J.Verdict.REFUSED, str(e).splitlines()[0]
        wall = time.time() - t0
        ok_stale, stale_detail = LR.stale_done_check(bar, regs, j)
        if verdict == J.Verdict.PASS and not ok_stale:
            verdict = J.Verdict.INCONCLUSIVE
            detail = ("the numbers match but the completion may not belong to "
                      "this window: " + stale_detail)
        got = LR._read_back_mantissas(bar, regs, j.n_rows)
        yexp_card = bar.last_read(regs["FK33_ENG_Y_EXP"])
        bar.harvest()
        ndiff = 0
        for r in range(j.n_rows):
            v = got[r]
            sv = None if v is None else (v - (1 << 64) if v >> 63 else v)
            got_all[j.row_start + r] = sv
            if v != (y[j.row_start + r] & 0xFFFFFFFFFFFFFFFF):
                ndiff += 1
        results.append(dict(job=j, verdict=verdict, detail=detail, wall=wall,
                            ndiff=ndiff, y_exp=yexp_card, stale=stale_detail,
                            text=buf.text, rd_n=bar.rd_n, wr_n=bar.wr_n,
                            rd_s=bar.rd_s, wr_s=bar.wr_s,
                            by_off=dict(bar.by_off)))
        w("  window %-2d   rows %6d..%6d  %-12s %s\n"
          % (j.idx, j.row_start, j.row_start + j.n_rows - 1, verdict,
             ("%d differ" % ndiff) if verdict != J.Verdict.PASS
             else "%.3f s" % wall))
        if verdict != J.Verdict.PASS and not a.keep_going:
            break

    covered = sum(1 for v in got_all if v is not None)
    card_tok = None
    if covered == len(got_all):
        card_tok = argmax_first(got_all)
    return dict(norm=nrow, results=results, y=y, y_exp=y_exp,
                logits_ok=ok_log, logits_ndiff=nbad_log, logits_big=nbig,
                ref_token=ref_tok, card_token=card_tok, covered=covered,
                total=len(got_all), same_x=same_x, oracle_argmax=am_ref)


# ===================================================================== output
def print_program(tp, out=None):
    out = out or sys.stdout
    w = out.write
    s = tp["shape"]
    nA = sum(len(p["jobs"]) for p in tp["layers"])
    nlm = len(tp["tail"]["jobs"]) if tp["tail"] else 0
    rows = sum(sum(j.n_rows for j in p["jobs"]) for p in tp["layers"])
    lmrows = sum(j.n_rows for j in tp["tail"]["jobs"]) if tp["tail"] else 0
    xw = sum(sum(j.K for j in p["jobs"]) for p in tp["layers"])
    lmxw = sum(j.K for j in tp["tail"]["jobs"]) if tp["tail"] else 0
    beats = 0
    for p in tp["layers"]:
        for j in p["jobs"]:
            beats += ((j.n_rows + 47) // 48) * (j.K // 32)
    if tp["tail"]:
        for j in tp["tail"]["jobs"]:
            beats += ((j.n_rows + 47) // 48) * (j.K // 32)

    w("model       Qwen3.5-9B: %d blocks, %d Gated DeltaNet + %d attention, "
      "hidden %d, vocab %d\n"
      % (s.blocks, s.n_gdn(), s.n_attn(), s.hidden, s.vocab_shard))
    w("program     %d layers selected; %d subsystem-A jobs in the layers"
      % (tp["upto"], nA))
    w(" + %d lm_head windows = %d\n" % (nlm, nA + nlm) if nlm else "\n")
    w("arena       0x%X, %d slots of %d bytes, %d used\n"
      % (tp["arena_base"], tp["n_slots"], tp["stride"], tp["n_slots_used"]))
    if tp["tail"]:
        ws = tp["tail"]["windows"]
        w("lm_head     %d windows at stride %d, last %d rows, covering %d of "
          "%d rows\n" % (len(ws), ws[1][0] - ws[0][0] if len(ws) > 1 else 0,
                         ws[-1][1], sum(n for _, n in ws), s.vocab_shard))

    # DERIVED, at Oren's MEASURED per-access rates of 2026-08-29.
    RD, WR = 2.88e-6, 0.85e-6
    tot_rows, tot_x = rows + lmrows, xw + lmxw
    w("\ncost, DERIVED from the MEASURED per-access rates of 2026-08-29 "
      "(0.85 us per MMIO\nwrite, 2.88 us per MMIO read).  NOT a prediction of "
      "the whole wall time -- it omits\nthe status polling and every host step:"
      "\n")
    w("  activation writes  %9d   %6.2f s\n" % (tot_x, tot_x * WR))
    w("  Y index writes     %9d   %6.2f s\n" % (tot_rows, tot_rows * WR))
    w("  Y readback reads   %9d   %6.2f s   <-- the term that decides the run\n"
      % (2 * tot_rows, 2 * tot_rows * RD))
    w("  of which lm_head   %9d   %6.2f s   (%.0f%% of the readback, one "
      "tensor)\n" % (2 * lmrows, 2 * lmrows * RD,
                     100.0 * lmrows / tot_rows if tot_rows else 0))
    w("  weight beats       %9d   %6.2f s   at the MEASURED 21.6 core cycles "
      "per beat, 200 MHz\n" % (beats, beats * 21.6 / 200e6))
    w("  MMIO total         %9d   %6.2f s\n"
      % (tot_x + tot_rows + 2 * tot_rows,
         tot_x * WR + tot_rows * WR + 2 * tot_rows * RD))


def print_layer_table(tp, out=None):
    out = out or sys.stdout
    w = out.write
    w("\n  %-5s %-5s %5s %8s %9s %10s\n"
      % ("layer", "kind", "jobs", "rows", "x writes", "beats"))
    for p in tp["layers"]:
        rows = sum(j.n_rows for j in p["jobs"])
        xw = sum(j.K for j in p["jobs"])
        bt = sum(((j.n_rows + 47) // 48) * (j.K // 32) for j in p["jobs"])
        w("  %-5d %-5s %5d %8d %9d %10d\n"
          % (p["layer"], "attn" if p["is_attn"] else "gdn", len(p["jobs"]),
             rows, xw, bt))


def print_mmio(res, simulated, out=None):
    out = out or sys.stdout
    w = out.write
    rows = []
    for rec in res["per_layer"]:
        rows.extend(rec["results"])
    if res["tail"]:
        rows.extend(res["tail"]["results"])
    if not rows:
        return
    rd_n = sum(r["rd_n"] for r in rows)
    wr_n = sum(r["wr_n"] for r in rows)
    rd_s = sum(r["rd_s"] for r in rows)
    wr_s = sum(r["wr_s"] for r in rows)
    w("\nPCIe register traffic over the whole run, counted per access by "
      "Meter:\n")
    w("  MMIO reads   %9d   %8.3f s   %6.2f us each\n"
      % (rd_n, rd_s, 1e6 * rd_s / rd_n if rd_n else 0))
    w("  MMIO writes  %9d   %8.3f s   %6.2f us each\n"
      % (wr_n, wr_s, 1e6 * wr_s / wr_n if wr_n else 0))
    if simulated:
        w("  THESE ARE NOT PCIe NUMBERS.  Under --dry-run the transport is a "
          "Python object,\n  so the TIMES are the cost of a method call.  The "
          "COUNTS are the only part that\n  carries over to the card.\n")
    else:
        w("  Setup is amortised -- one process, one open device, one compiled "
          "oracle -- so\n  what is left IS the PCIe cost.\n")


def print_verdict(a, tp, res, out=None):
    out = out or sys.stdout
    w = out.write
    s = tp["shape"]
    nlayers = len(res["per_layer"])
    njobs = sum(len(r["results"]) for r in res["per_layer"])
    nplan = sum(len(p["jobs"]) for p in tp["layers"])
    npass = sum(r["npass"] for r in res["per_layer"])
    nfail = sum(r["nfail"] for r in res["per_layer"])
    ninc = sum(r["ninc"] for r in res["per_layer"])
    rows = sum(r["rows"] for r in res["per_layer"])
    t = res["tail"]
    if t:
        njobs += len(t["results"])
        for r in t["results"]:
            if r["verdict"] == J.Verdict.PASS:
                npass += 1
            elif r["verdict"] == J.Verdict.INCONCLUSIVE:
                ninc += 1
            else:
                nfail += 1
            rows += r["job"].n_rows

    w("\nresult      %d of %d layers run; %d of %d jobs; %d PASS, %d "
      "FAIL/REFUSED, %d INCONCLUSIVE\n"
      % (nlayers, tp["upto"], njobs,
         nplan + (len(tp["tail"]["jobs"]) if tp["tail"] else 0),
         npass, nfail, ninc))
    w("            %d result rows compared against ref/run9b's stream, "
      "element for element\n" % rows)
    w("            token wall %.3f s\n" % res["wall"])
    if a.mode == "chained":
        w("            RE-ANCHORED %d times (the chain was broken here):\n"
          % len(res["reanchors"]))
        byreason = {}
        for il, nm, why in res["reanchors"]:
            byreason.setdefault(why, []).append(il)
        for why, ils in sorted(byreason.items(), key=lambda kv: -len(kv[1])):
            w("              %3d x  %s\n" % (len(ils), why))
    else:
        w("            ANCHORED: every job's x came from the reference, so "
          "there is no chain to\n                      break and no "
          "re-anchor to count.\n")

    races = poll_races(a._meter) if getattr(a, "_meter", None) else []
    w("            DONE-1 poll witness: %d of %d jobs completed on their FIRST "
      "STATUS read\n" % (len(races), len(a._meter.polls)
                         if getattr(a, "_meter", None) else 0))

    # THERM-255 gets its OWN column, and it is not allowed to condemn
    # arithmetic that compared bit-exact.  A trip is a two-stack inequality,
    # not heat and not a compute fault (54f45c5), so the question it raises is
    # "did this job's numbers still match", and that is answered per job.
    trips_moved = res["trips1"] != res["trips0"]
    g = getattr(a, "_guard", None)
    tripped_keys = set(e[0] for e in g.trips) if g else set()
    tripped_dirty = [r for rec in res["per_layer"] for r in rec["results"]
                     if r["verdict"] != J.Verdict.PASS
                     and (r["job"].tensor, r["job"].desc_addr) in tripped_keys]
    if t:
        tripped_dirty += [r for r in t["results"]
                          if r["verdict"] != J.Verdict.PASS
                          and (r["job"].tensor, r["job"].desc_addr)
                          in tripped_keys]
    # The counter SATURATES at 255 (rtl/fk33_thermal.vhd:1166).  The adjacent
    # paragraph already warns that this number is a lower bound BECAUSE OF
    # SAMPLING; the ceiling is a second, independent reason and used to go
    # unmentioned, so `255 -> 255` printed with no MOVED read as "the guard
    # never fired" when it means "nothing after the 255th can be seen".
    _sat = " (SATURATED: a FLOOR, not a count)" if res["trips1"] == 255 else ""
    w("            THERM-255 trip counter %d -> %d%s%s\n"
      % (res["trips0"], res["trips1"], _sat,
         "  <-- MOVED" if trips_moved else
         ("  <-- cannot be observed at the ceiling" if res["trips0"] == 255
          else "")))
    if g is not None:
        w("            GUARD       %d refused GO(s) waited out and retried "
          "(%.2f s waiting, %d\n                        unrecovered); %d trip"
          "(s) across a job that ran, %d of\n                        those "
          "left a job that did not PASS\n"
          % (g.n_refusals, g.waited, len(g.unrecovered), g.n_trips,
             len(tripped_dirty)))
    w("            THE TRIP COUNT IS A LOWER BOUND.  It is sampled at job "
      "boundaries, and\n            MEASURED 2026-08-30: 400 such samples "
      "taken while compute was active caught\n            NOTHING, while an "
      "idle read afterwards did.  A halt that rises and falls\n            "
      "inside one job is invisible here.  Nothing in this run reports the "
      "LATCHED\n            cause, which is captured a cycle late and reads "
      "CAUSE_NONE on exactly the\n            transient inequality that "
      "caused it (fk33_thermal.vhd:963).\n")

    never = [r for rec in res["per_layer"] for r in rec["results"]
             if "never completed" in (r["detail"] or "")]
    if never:
        w("            %d job(s) never completed and never errored.  That is "
          "the signature of\n            TRACK A7's outstanding-count "
          "underflow in rtl/axi_rd_fsm.vhd, which is LIVE\n            in this "
          "bitstream: a port stops issuing AR forever.  Reload before "
          "retrying.\n" % len(never))

    if t:
        w("\n            the tail:\n")
        w("              final norm  %s\n"
          % ("reproduces the reference exactly"
             if t["norm"]["ok"] else
             "%d of %d mantissas differ, exp d=%d"
             % (t["norm"]["ndiff"], t["norm"]["n"], t["norm"]["dexp"])))
        w("              lm_head     %d of %d rows read back from the card\n"
          % (t["covered"], t["total"]))
        w("              LOGITS      the oracle matched the reference's f32 "
          "record on %s\n"
          % ("all of them" if t["logits_ok"]
             else "all but %d" % t["logits_ndiff"]))
        w("              TOKEN       card argmax %s, reference %d\n"
          % (t["card_token"] if t["card_token"] is not None
             else "NOT FORMED (the readback is incomplete)", t["ref_token"]))

    # ------------------------------------------------------------- the verdict
    if g is not None and g.unrecovered:
        verdict = J.Verdict.INCONCLUSIVE
        why = ("the guard refused %d job(s) and the halt never cleared within "
               "the retry budget, so the token ABORTED part way through.  "
               "THERM-255 halts whenever the two HBM STACKS differ by one "
               "temperature code, so this is not heat; raise --halt-wait or "
               "--halt-retries and re-run." % len(g.unrecovered))
    elif tripped_dirty:
        verdict = J.Verdict.INCONCLUSIVE
        why = ("%d job(s) BOTH saw the trip counter move AND disagreed with "
               "the reference.  A halt is not itself a compute fault, but on "
               "these jobs the disagreement is not attributable to either.  "
               "Clear the counter (fk33ctl.py thermal --clear) and re-run "
               "those layers alone." % len(tripped_dirty))
    elif races:
        verdict = J.Verdict.INCONCLUSIVE
        why = ("%d job(s) reported done on the FIRST STATUS read after their "
               "GO.  This bitstream carries the DONE-1 window (fixed in the "
               "RTL at 3ecc729, NOT in this image), so those completions may "
               "belong to the previous job and their Y readback may be stale: "
               "jobs %s" % (len(races), races[:12]))
    elif ninc:
        verdict = J.Verdict.INCONCLUSIVE
        why = "%d job(s) were inconclusive; see their detail lines" % ninc
    elif nfail:
        verdict = J.Verdict.FAIL
        why = "%d job(s) did not reproduce ref/run9b's seam" % nfail
    elif res["halted"] is not None:
        # AFTER the FAIL branch, deliberately.  A run that stopped BECAUSE a
        # job did not reproduce the reference is a FAIL and saying otherwise
        # would bury the one result the run exists to produce; a run that
        # stopped for any other reason has no verdict over a partial token.
        verdict = J.Verdict.INCONCLUSIVE
        why = ("the run stopped at layer %d; a verdict over a partial token is "
               "not a verdict.  Re-run that layer alone with "
               "fk33_run_layer.py --mode anchored to localise it."
               % res["halted"])
    elif njobs != nplan + (len(tp["tail"]["jobs"]) if tp["tail"] else 0):
        verdict = J.Verdict.INCONCLUSIVE
        why = "the run is partial"
    elif any(rec["layer_out"] is not None and not rec["layer_out"]["ok"]
             for rec in res["per_layer"]):
        bad = [rec["layer"] for rec in res["per_layer"]
               if rec["layer_out"] is not None and not rec["layer_out"]["ok"]]
        verdict = J.Verdict.FAIL
        why = ("every job matched and the LAYER OUTPUT did not, at layer(s) "
               "%s.  A green per-job table with a wrong composition is exactly "
               "the outcome this tool exists to be able to report." % bad)
    elif t is None and not getattr(a, "partial_ok", False):
        # DEFAULT.  A run that produced no token is not a token result, and the
        # safe verdict for it is INCONCLUSIVE -- otherwise a bounded run's PASS
        # is quotable as "the card ran a token".  --partial-ok is the explicit
        # request to be judged on the layers that were asked for, and it makes
        # the PASS say NO TOKEN WAS PRODUCED in the verdict line itself.
        verdict = J.Verdict.INCONCLUSIVE
        why = ("%d layer(s) reproduced the reference and the lm_head was not "
               "run, so NO TOKEN was produced.  Pass --partial-ok to be judged "
               "on the layers you asked for." % nlayers)
    elif t is None:
        verdict = J.Verdict.PASS
        why = ("every one of the %d matvecs in layers 0..%d reproduced "
               "ref/run9b's stream bit-exactly, in program order, on one open "
               "device.  NO TOKEN WAS PRODUCED: the lm_head was not run."
               % (njobs, nlayers - 1))
    elif t["card_token"] is None:
        verdict = J.Verdict.INCONCLUSIVE
        why = "the lm_head readback is incomplete, so no argmax was formed"
    elif t["card_token"] != t["ref_token"]:
        verdict = J.Verdict.FAIL
        why = ("THE TOKEN DISAGREES: the card's own logits argmax to %d and "
               "ref/run9b's TOKEN record is %d"
               % (t["card_token"], t["ref_token"]))
    else:
        verdict = J.Verdict.PASS
        why = ("every one of the %d matvecs in the token reproduced "
               "ref/run9b's stream bit-exactly, in program order, on one open "
               "device, and the argmax over the card's OWN %d logits is token "
               "%d -- the same token ref/run9b picked"
               % (njobs, t["total"], t["card_token"]))
        if g is not None and (g.n_trips or g.n_refusals):
            why += ("  (the guard refused %d GO(s) and tripped across %d job(s) "
                    "during the run; every one was retried and every retry "
                    "compared bit-exact, and a THERM-255 trip is a two-stack "
                    "inequality rather than a compute fault)"
                    % (g.n_refusals, g.n_trips))

    w("\nVERDICT     %s -- %s\n" % (verdict, why))
    w("SCOPE       subsystem A only.  The %d RMS norms%s, the %d residual "
      "adds,\n            the %d SwiGLUs and the whole Gated DeltaNet "
      "or attention block of every\n            layer ran on the HOST.  B, C "
      "and D are not on this silicon, so this is the\n            MATVEC "
      "SKELETON of a token, not a token the card computed by itself.\n"
      % (2 * len(res["per_layer"]), " and the final norm" if t else "",
         2 * len(res["per_layer"]), len(res["per_layer"])))
    w("            ONE token, ONE position, ONE prompt.  Coverage of the input "
      "space is not\n            coverage of the output space: this exercises "
      "one activation per job at the\n            exponents this prompt "
      "happens to produce, and reaches no saturation corner\n            and "
      "no row count other than the shapes the model has.\n")
    if a.dry_run:
        w("            DRY RUN.  This is a statement about this tool, not "
          "about any FPGA.\n")
    return verdict


# ==================================================================== commands
def cmd_plan(a):
    regs = J.load_regs()
    LR._bind_offsets(regs)
    scratch = _scratch(a)
    tp = make_token(a)
    print_program(tp)
    if a.table:
        print_layer_table(tp)

    only = None
    if a.only_layers:
        only = set(int(v) for v in a.only_layers.split(","))
    nbad_all, nlay, nrun = 0, 0, 0
    hfail = 0
    print("\nhost re-run of every job through ref/matvec_int4.c, and every "
          "host non-matvec\nstep, from the reference's own seams.  This "
          "EXCLUDES THE HOST: if it passes and\nthe card later disagrees, the "
          "disagreement is the card's.\n")
    print("  %-5s %-5s %5s %8s %8s %8s  %s"
          % ("layer", "kind", "jobs", "mant!=", "steps", "uncov", "verdict"))
    t0 = time.time()
    for plan in tp["layers"]:
        il = plan["layer"]
        if only is not None and il not in only:
            continue
        nlay += 1
        la = _LayerArgs(a, il)
        rows, wall = LR.host_rerun(plan, tp["ref"], a.tok, scratch, a.cc)
        nbad = sum(1 for r in rows if r["ndiff"] or not r["exp_ok"])
        nbad_all += nbad
        nrun += len(rows)
        sink = LR._Sink()
        hrows, hok = LR.check_host_steps(plan, tp["ref"], a.tok, a.packed,
                                         out=sink)
        nunc = sum(1 for r in hrows if r[2] == "UNCOVERED")
        nhf = sum(1 for r in hrows if r[2] == "FAIL")
        hfail += nhf + nunc
        print("  %-5d %-5s %5d %8d %8s %8d  %s"
              % (il, "attn" if plan["is_attn"] else "gdn", len(rows), nbad,
                 "%d/%d" % (sum(1 for r in hrows if r[2] == "PASS"),
                            sum(1 for r in hrows if r[2] in ("PASS", "FAIL"))),
                 nunc, "ok" if (nbad == 0 and hok) else "MISMATCH"))
        sys.stdout.flush()
    print("  coverage    %d of %d layers checked, %d of %d jobs re-run, %d "
          "differ, %d host-step faults (%.1f s)"
          % (nlay, len(tp["layers"]), nrun,
             sum(len(p["jobs"]) for p in tp["layers"]), nbad_all, hfail,
             time.time() - t0))
    if only is not None:
        print("  NOT COVERED %d layer(s) were skipped by --only-layers; a "
              "partial check is not a\n              statement about the "
              "layers it did not read"
              % (len(tp["layers"]) - nlay))

    tail_ok = True
    if tp["tail"] is not None:
        print("\nthe tail, with no card:")
        m, e, nrow = tail_host_norm(tp, tp["ref"], a.tok, a.packed)
        print("  final norm  %s: %d of %d mantissas differ, exp d=%d -> %s"
              % (nrow["detail"], nrow["ndiff"], nrow["n"], nrow["dexp"],
                 "PASS" if nrow["ok"] else "FAIL"))
        rs = tp["ref"][(SEAM_FINAL_XN, a.tok)]
        y, ye, am, sat, wall = lm_oracle_run(tp["tail"], list(rs.mant), rs.exp,
                                             scratch, a.cc, tag="ref")
        print("  lm_head     %d rows RAW in %.1f s, y_exp=%d, sat_event=%d"
              % (len(y), wall, ye, sat))
        ok_log, nbad_log, nbig = check_lm_against_reference(
            tp["tail"], y, ye, tp["ref"], a.tok)
        rt = ref_token_id(tp["ref"], a.tok)
        print("  TOKEN       the oracle's argmax is %d and the reference's "
              "TOKEN record is %d -> %s" % (am, rt, "PASS" if am == rt else
                                            "FAIL"))
        tail_ok = nrow["ok"] and ok_log and am == rt

    ok = nbad_all == 0 and hfail == 0 and tail_ok
    print("\nplan        %s"
          % ("consistent -- every job's seam pairing, every host step and the "
             "tail reproduce the reference" if ok else "INCONSISTENT"))
    return 0 if ok else 1


def cmd_run(a):
    regs = J.load_regs()
    LR._bind_offsets(regs)
    scratch = _scratch(a)
    tp = make_token(a)
    print_program(tp)

    if a.mode == "chained":
        print("\nchecking the host non-matvec steps before chaining anything "
              "through them:")
        bad = []
        for plan in tp["layers"]:
            sink = LR._Sink()
            hrows, hok = LR.check_host_steps(plan, tp["ref"], a.tok, a.packed,
                                             out=sink)
            if not hok:
                bad.append(plan["layer"])
        if tp["tail"] is not None:
            _, _, nrow = tail_host_norm(tp, tp["ref"], a.tok, a.packed)
            if not nrow["ok"]:
                bad.append("final norm")
        print("  %d of %d layers' host steps reproduce the reference%s"
              % (len(tp["layers"]) - len([b for b in bad if b != "final norm"]),
                 len(tp["layers"]),
                 "" if not bad else "; FAULTS at %r" % bad))
        if bad:
            print("\nREFUSING --mode chained: the host non-matvec steps do not "
                  "reproduce the reference, so any chained divergence would be "
                  "unattributable.", file=sys.stderr)
            return 2

    if a.dry_run:
        bar_i = _TokenDryBar(regs, a.inject)
        hbm_i = J.FileHbm(os.path.join(scratch, "hbm.bin"),
                          regs["FK33_HBM_TOP"])
        print("\ntransport   SIMULATED.  Nothing under /dev is opened, and the "
              "model REPLAYS the\n            expectation table.")
    else:
        bar_i = J.DevBar(os.environ.get("FK33_USER", "/dev/xdma0_user"))
        hbm_i = J.DevHbm(os.environ.get("FK33_H2C", "/dev/xdma0_h2c_0"),
                         os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0"),
                         regs["FK33_HBM_TOP"])
        print("\ntransport   %s + %s/%s"
              % (os.environ.get("FK33_USER", "/dev/xdma0_user"),
                 os.environ.get("FK33_H2C", "/dev/xdma0_h2c_0"),
                 os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0")))
    bar = TokenMeter(bar_i, "bar", regs)
    hbm = LR.Meter(hbm_i, "hbm")
    a._meter = bar
    a._guard = GuardLog()
    install_halt_retry(regs, a._guard, retries=a.halt_retries,
                       wait_s=a.halt_wait,
                       sleep=(lambda s: None) if a.dry_run else time.sleep)
    print("halt policy a spurious THERM-255 halt is WAITED OUT and the job "
          "RETRIED, up to %d\n            times per job with %.2f s of wait "
          "each.  A refused GO leaves the engine in\n            S_IDLE, so no "
          "descriptor was consumed and the retry's inputs are byte-\n"
          "            identical -- see install_halt_retry.\n"
          % (a.halt_retries, a.halt_wait))

    print("\nmode        %s\n" % (
        "ANCHORED -- every job's x comes from the reference; a divergence is "
        "attributable\n            to that job and nothing propagates.  The "
        "CONTROL."
        if a.mode == "anchored" else
        "CHAINED -- only the token input comes from the reference; every other "
        "x is\n            derived on the host from the CARD's own outputs, "
        "ACROSS layer boundaries"))
    try:
        res = run_token(a, tp, regs, bar, hbm)
    finally:
        uninstall_halt_retry()
        bar.harvest()
        bar.close()
        hbm.close()

    print_mmio(res, a.dry_run)
    verdict = print_verdict(a, tp, res)
    return {J.Verdict.PASS: 0, J.Verdict.FAIL: 1,
            J.Verdict.INCONCLUSIVE: 3, J.Verdict.REFUSED: 2}[verdict]


# ======================================================================= teeth
TEETH = [
    (None, J.Verdict.PASS, "control (clean)"),
    ("bad-row:5", J.Verdict.FAIL, "one wrong mantissa in job 5"),
    ("wrong-exp:9", J.Verdict.FAIL, "wrong y_exp in job 9"),
    ("stale:4", J.Verdict.INCONCLUSIVE, "job 4 reports job 3's counters"),
    ("poll1:6", J.Verdict.INCONCLUSIVE,
     "job 6 completes on its FIRST poll -- the DONE-1 race"),
    # THE TWO THERM-255 ROWS ARE OPPOSITE ON PURPOSE.  A trip that a job
    # survives with matching numbers must NOT condemn the token -- that was the
    # rule before the 2026-08-30 root cause and it would abort a whole token on
    # a two-stack inequality.  A halt that never clears MUST abort it, because
    # then the job genuinely never ran.
    ("trip:2", J.Verdict.PASS,
     "a trip across job 2 whose numbers still match -> PASS, halt column only"),
    ("halt:0", J.Verdict.PASS,
     "job 0's GO swallowed once, then retried -> PASS"),
    ("halt-stuck:1", J.Verdict.INCONCLUSIVE,
     "job 1's halt never clears -> the token aborts"),
    ("never-done:3", J.Verdict.FAIL,
     "job 3 never completes -- A7's AR-starved port"),
]


def cmd_teeth(a):
    """Prove the checks bite.  A checker never shown to fail has not been shown
    to work, and a row that does NOT bite is printed under its own name because
    it measures this check's resolution floor."""
    rows, nbad = [], 0
    base = dict(vars(a))
    for spec, want, label in TEETH:
        na = argparse.Namespace(**base)
        na.mode = "chained"
        na.dry_run = True
        na.inject = [] if spec is None else [spec]
        na.verbose = False
        na.keep_going = False
        na.upto = a.upto if a.upto is not None else 2
        na.no_lmhead = True
        na.timeout, na.show, na.stop_on_fail = 5.0, 4, False
        na.halt_retries, na.halt_wait = 2, 0.05
        na.partial_ok = True
        na.fn = cmd_run
        buf = _Cap()
        rc = _run_captured(cmd_run, na, buf)
        got = _verdict_of(buf.text)
        ok = (got == want)
        nbad += 0 if ok else 1
        rows.append((label, want, got, "ok" if ok else "MISMATCH"))
    print("\n%-52s %-14s %-14s %s" % ("mutation", "want", "got", "verdict"))
    print("-" * 96)
    for label, want, got, v in rows:
        print("%-52s %-14s %-14s %s" % (label, want, got, v))
    print("\nteeth       %s" % ("PASS" if nbad == 0 else "FAIL (%d)" % nbad))
    print("coverage    %d rows, every one required to produce a STATED "
          "verdict; a row that\n            does not bite is a measurement of "
          "this checker's resolution floor and is\n            reported, never "
          "deleted." % len(rows))
    return 0 if nbad == 0 else 1


class _Cap(object):
    def __init__(self):
        self.buf = []

    def write(self, s):
        self.buf.append(s)

    def flush(self):
        pass

    @property
    def text(self):
        return "".join(self.buf)


def _run_captured(fn, na, buf):
    old = sys.stdout
    sys.stdout = buf
    try:
        return fn(na)
    except (TokenError, LR.LayerError, J.RunError) as e:
        buf.write("\nVERDICT     REFUSED -- %s\n" % e)
        return 2
    finally:
        sys.stdout = old


def _verdict_of(text):
    for line in text.splitlines():
        if line.startswith("VERDICT"):
            return line.split()[1]
    return "NONE"


# =================================================================== selfcheck
def cmd_selfcheck(a):
    """No card, no model, nothing under /dev.  Every row must FAIL when it is
    supposed to; a row that passes when it should is not evidence."""
    rows = []

    def chk(name, fn, want_raise=True):
        try:
            fn()
            rows.append((name, "raise" if want_raise else "return",
                         "returned", "MISMATCH" if want_raise else "ok"))
        except Exception as e:
            rows.append((name, "raise" if want_raise else "return",
                         type(e).__name__, "ok" if want_raise else "MISMATCH"))

    # ---- the r9bs tail records this file depends on
    import tempfile
    d = tempfile.mkdtemp(prefix="tokenrun-selfcheck-")
    good = os.path.join(d, "good.r9bs")
    _synth_tail(good, ver=2, with_token=True, with_logits=True)
    r = LR.read_r9bs(good)
    rows.append(("read a v2 stream carrying LOGITS(f32) and TOKEN(s32)",
                 "3 records", "%d records" % len(r),
                 "ok" if len(r) == 3 else "MISMATCH"))
    rows.append(("TOKEN decodes as one S32",
                 "42", str(ref_token_id(r, 0)),
                 "ok" if ref_token_id(r, 0) == 42 else "MISMATCH"))

    no_tok = os.path.join(d, "notok.r9bs")
    _synth_tail(no_tok, ver=2, with_token=False, with_logits=True)
    chk("a stream with no TOKEN record is a refusal, not a skip",
        lambda: ref_token_id(LR.read_r9bs(no_tok), 0))

    v1 = os.path.join(d, "v1.r9bs")
    _synth_tail(v1, ver=1, with_token=True, with_logits=True)
    chk("an S32 record in a version-1 file is a refusal (mis-framing)",
        lambda: LR.read_r9bs(v1))

    # ---- the argmax rule
    rows.append(("argmax_first takes the FIRST maximum, not the last",
                 "1", str(argmax_first([0, 5, 3, 5])),
                 "ok" if argmax_first([0, 5, 3, 5]) == 1 else "MISMATCH"))
    rows.append(("argmax_first on an all-equal vector is index 0",
                 "0", str(argmax_first([7] * 9)),
                 "ok" if argmax_first([7] * 9) == 0 else "MISMATCH"))

    # ---- the f32 round trip the LOGITS comparison rests on
    ok24 = all(_f32(math.ldexp(v, -3)) == _f32(_f32(math.ldexp(v, -3)))
               for v in (1, -1, 1 << 20, -(1 << 20)))
    rows.append(("float32(ldexp(s32, -e)) is idempotent below 2^24",
                 "True", str(ok24), "ok" if ok24 else "MISMATCH"))
    collide = _f32(math.ldexp((1 << 25) + 1, 0)) == _f32(math.ldexp(1 << 25, 0))
    rows.append(("and MANY-TO-ONE above it -- the stated blind spot",
                 "True", str(collide), "ok" if collide else "MISMATCH"))

    # ---- the poll witness
    class _M(object):
        def __init__(self, polls):
            self.polls = polls
    m1 = _M([(1, 0x1, 3.0), (400, 0x2, 3.0)])
    rows.append(("the poll witness fires on n=1 with done set",
                 "[0]", str(poll_races(m1)),
                 "ok" if poll_races(m1) == [0] else "MISMATCH"))
    m2 = _M([(1, 0x2, 3.0), (400, 0x1, 3.0)])
    rows.append(("and NOT on n=1 with busy set (a legitimate first poll)",
                 "[]", str(poll_races(m2)),
                 "ok" if poll_races(m2) == [] else "MISMATCH"))
    mm = TokenMeter(J.SimBar(J.load_regs(), {}, {}), "bar", _regs())
    mm.log = [(0.0, 0.0, "w", _regs()["FK33_ENG_CTRL"], 1),
              (1.0, 0.0, "r", _regs()["FK33_ENG_STATUS"], 0x1)]
    mm.harvest()
    rows.append(("TokenMeter.harvest counts STATUS reads after the GO by VALUE",
                 "(1, 1)", str((mm.polls[-1][0], mm.polls[-1][1])),
                 "ok" if mm.polls[-1][:2] == (1, 1) else "MISMATCH"))

    # ---- the tail refusals that stop a wrong comparison
    class _T(object):
        pass
    chk("a LOGITS record of the wrong length is a refusal",
        lambda: check_lm_against_reference(
            dict(header=None), [0] * 4, 0,
            {(SEAM_LOGITS, 0): LR.Seam(SEAM_LOGITS, 0, -1, LR.KIND_F32, 0,
                                       [0.0] * 5)}, 0, out=_Cap()))
    chk("a LOGITS record that is not F32 is a refusal",
        lambda: check_lm_against_reference(
            dict(header=None), [0] * 4, 0,
            {(SEAM_LOGITS, 0): LR.Seam(SEAM_LOGITS, 0, -1, LR.KIND_BFP16, 0,
                                       [0] * 4)}, 0, out=_Cap()))

    # ---- the halt-retry wrapper, which had NO coverage at all
    #
    # docs/debugging/2026-08-30_tripveto-every-consumer-of-a-saturating-
    # counter.md section 5 named the hazard that kept the THERM-255 fix out of
    # the tree: run_job must CLEAR the trip counter (it saturates at 255, where
    # "it did not move" is false forever), and a wrapper that samples the
    # counter either side of that call sees t1 < t0 on EVERY job and burns a
    # phantom retry on every job of every layer of every token.  The wrapper
    # now reads run_job's published p["therm"] instead.  These rows are what
    # make that claim checkable; the write-up listed them as unrun.
    class _FakeBar(object):
        """Counts nothing but ENGX_STAT/THERM_STATUS reads, and models a card
        that is NOT halted, so _wait_clear returns immediately."""
        def __init__(self, regs, trip=0):
            self.r, self.trip, self.reads = regs, trip, 0
        def rd(self, off):
            self.reads += 1
            if off == self.r["FK33_THERM_STATUS"]:
                return (1 << 31) | ((min(self.trip, 255) & 0xFF) << 16)
            return 0                      # ENGX_STAT: no halt, no GO_BLOCKED
        def wr(self, off, val):
            pass

    def _wrapper_row(name, publish, want_calls, want_trips, expect_raise=False):
        regs_ = _regs()
        log = GuardLog()
        bar = _FakeBar(regs_, trip=255)
        plan = dict(fields=dict(tensor="t"), desc_addr=0)
        calls = []

        def fake_run_job(pp, rr, bb, hh, aa, out=sys.stdout):
            calls.append(1)
            # The real run_job clears the counter, so the register MOVES
            # BACKWARDS across this call.  A wrapper that sampled it would
            # read that as a trip.
            bb.trip = 0
            if publish is not None:
                pp["therm"] = dict(publish)
            return (J.Verdict.PASS if publish and not publish.get("moved")
                    else J.Verdict.INCONCLUSIVE, "detail")

        orig = J.run_job
        try:
            wrapped = install_halt_retry(regs_, log, retries=2, wait_s=0.01,
                                         poll_s=0.01, sleep=lambda _s: None)
            J.run_job = fake_run_job          # what the wrapper calls through
            globals()["_ORIG_RUN_JOB"] = fake_run_job
            try:
                wrapped(plan, regs_, bar, None, None, out=_Cap())
                got_raise = False
            except Exception:
                got_raise = True
        finally:
            J.run_job = orig
            globals()["_ORIG_RUN_JOB"] = orig
            uninstall_halt_retry()

        if expect_raise:
            rows.append((name, "refuse", "refused" if got_raise else "returned",
                         "ok" if got_raise else "MISMATCH"))
            return
        ok = (len(calls) == want_calls and log.n_trips == want_trips
              and not got_raise)
        rows.append((name, "%d call/%d trip" % (want_calls, want_trips),
                     "%d call/%d trip%s" % (len(calls), log.n_trips,
                                            " RAISED" if got_raise else ""),
                     "ok" if ok else "MISMATCH"))

    # THE REGRESSION ROW.  run_job cleared 255 -> 0 and reported no movement.
    # One call, no retry, nothing logged.  A wrapper sampling the register
    # would see 255 -> 0, call that a trip, and retry.
    _wrapper_row("a job that CLEARED the counter is not a phantom trip",
                 dict(trip0=0, trip1=0, moved=False, cleared=True,
                      guard=True, saturated=False), 1, 0)
    # And a REAL trip is still retried, so the row above is not just deafness.
    _wrapper_row("a real in-job trip is still retried",
                 dict(trip0=0, trip1=1, moved=True, cleared=True,
                      guard=True, saturated=False), 3, 3)
    # A run_job that publishes nothing is a REFUSAL, not a silent pass: the
    # two files must move together and a stale half must say so.
    _wrapper_row("run_job publishing no p['therm'] is a refusal",
                 None, 0, 0, expect_raise=True)

    print("\n%-62s %-12s %-14s %s" % ("check", "want", "got", "verdict"))
    print("-" * 108)
    for n, want, got, v in rows:
        print("%-62s %-12s %-14s %s" % (n, want, got, v))
    nbad = sum(1 for r in rows if r[3] != "ok")
    print("\nselfcheck   %s over %d checks, none of which needs a model, a "
          "card or /dev"
          % ("PASS" if nbad == 0 else "FAIL (%d)" % nbad, len(rows)))
    print("coverage    this covers the TAIL and the WITNESSES only.  Everything "
          "the layer path\n            does is covered by "
          "fk33_run_layer.py selfcheck, which this does not repeat.")
    return 0 if nbad == 0 else 1


def _regs():
    r = J.load_regs()
    LR._bind_offsets(r)
    return r


def _synth_tail(path, ver=2, with_token=True, with_logits=True):
    with open(path, "wb") as fp:
        fp.write(LR.R9BS_MAGIC + struct.pack("<I", ver))

        def rec(name, kind, exp, payload, fmt):
            nb = name.encode()
            fp.write(LR._HDR.pack(len(nb), len(payload), 0, -1, kind, exp))
            fp.write(nb)
            fp.write(struct.pack(fmt % len(payload), *payload))
        rec(SEAM_FINAL_XN, LR.KIND_BFP16, 5, [1, 2, 3, 4], "<%dh")
        if with_logits:
            rec(SEAM_LOGITS, LR.KIND_F32, 0, [1.0, 2.0, 3.0, 4.0], "<%df")
        if with_token:
            rec(SEAM_TOKEN, LR.KIND_S32, 0, [42], "<%di")
    return path


# ======================================================================== main
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(s):
        s.add_argument("--tok", type=int, default=0,
                       help="token index inside the reference stream")
        s.add_argument("--ref", required=True,
                       help="the .r9bs reference, built with --layers 32")
        s.add_argument("--manifest", default=DEFAULT_MANIFEST,
                       help="the manifest of the set RESIDENT ON THE CARD")
        s.add_argument("--packed", default=os.path.dirname(DEFAULT_MANIFEST),
                       help="the packed dir holding index.txt and the f32 blob")
        s.add_argument("--ref-manifest", default=None, dest="ref_manifest",
                       help="the manifest ref/run9b was run against.  When "
                            "given, every tensor this token touches must hash "
                            "the same in it and in --manifest.  Omitting it "
                            "leaves that unchecked.")
        s.add_argument("--upto", type=int, default=None,
                       help="run only layers 0..N-1.  The tail needs all 32, "
                            "and is skipped with a stated reason otherwise")
        s.add_argument("--no-lmhead", action="store_true",
                       help="run the layers and stop; no token is produced")
        s.add_argument("--addr-w", type=int, default=40, dest="addr_w")
        s.add_argument("--scratch", default=None)
        s.add_argument("--cc", default="cc")

    s = sub.add_parser("plan", help="build, cross-check and re-run the whole "
                                    "token on the host; no card, no /dev")
    common(s)
    s.add_argument("--table", action="store_true",
                   help="print the per-layer job/row/beat table")
    s.add_argument("--only-layers", default=None,
                   help="comma-separated layers to re-run on the host.  A "
                        "PARTIAL check, and it says so in the coverage line")
    s.set_defaults(fn=cmd_plan)

    s = sub.add_parser("run", help="run the token (see --dry-run)")
    common(s)
    s.add_argument("--mode", choices=("anchored", "chained"),
                   default="anchored")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--timeout", type=float, default=30.0)
    s.add_argument("--show", type=int, default=8)
    s.add_argument("--verbose", action="store_true",
                   help="print every job's own lines, not one line per layer")
    s.add_argument("--keep-going", action="store_true",
                   help="do not stop at the first layer that is not PASS.  "
                        "Off by default: after a bad layer everything "
                        "downstream is unattributable and the bench time is "
                        "real")
    s.add_argument("--stop-on-fail", action="store_true",
                   help="stop INSIDE a layer at its first bad job")
    s.add_argument("--partial-ok", action="store_true", dest="partial_ok",
                   help="judge an explicitly bounded run (--upto / --no-lmhead) "
                        "on the layers it was asked for.  Its PASS says NO "
                        "TOKEN WAS PRODUCED in the verdict line")
    s.add_argument("--halt-retries", type=int, default=8, dest="halt_retries",
                   help="how many times a job refused by the THERM-255 guard "
                        "is retried after the halt clears.  A refused GO "
                        "leaves the engine in S_IDLE, so the retry is safe")
    s.add_argument("--halt-wait", type=float, default=5.0, dest="halt_wait",
                   help="seconds to wait for a live compute_halt to drop "
                        "before each attempt.  G_MIN_HALT_MS is 100")
    s.add_argument("--inject", action="append", default=[],
                   help="--dry-run only.  NAME:INDEX, e.g. bad-row:5, "
                        "poll1:6, stale:4, trip:2, halt:0, halt-stuck:1, "
                        "never-done:3.  These are the TEETH.")
    s.set_defaults(fn=cmd_run)

    s = sub.add_parser("teeth", help="run the dry run once per injected fault "
                                     "and require the stated verdict")
    common(s)
    s.set_defaults(fn=cmd_teeth)

    s = sub.add_parser("selfcheck",
                       help="prove the checks can fail; no card, no model")
    s.add_argument("--scratch", default=None)
    s.add_argument("--cc", default="cc")
    s.set_defaults(fn=cmd_selfcheck)

    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except (TokenError, LR.LayerError, J.RunError) as e:
        print("fk33_run_token: " + str(e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
