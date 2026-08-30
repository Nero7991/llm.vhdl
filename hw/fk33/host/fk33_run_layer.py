#!/usr/bin/env python3
"""fk33_run_layer.py -- drive ONE transformer layer's subsystem-A matvecs
through the FK33, in program order, and compare the result against the
whole-model 9B reference rather than against each job in isolation.

    fk33_run_layer.py plan      --layer 0 --ref R.r9bs      no card, no /dev
    fk33_run_layer.py hoststeps --layer 0 --ref R.r9bs      no card, no /dev
    fk33_run_layer.py selfcheck                             no card, no model
    fk33_run_layer.py run       --layer 0 --ref R.r9bs      THE CARD
    fk33_run_layer.py run       --dry-run ...               no card, no /dev

WHY THIS EXISTS
---------------
On 2026-08-29 subsystem A was MEASURED computing bit-exactly on the card: 30+
jobs, all eight distinct (M, K) geometries in the 9B model, every mantissa and
every y_exp identical to ref/matvec_int4.c
(docs/debugging/2026-08-29_first-arithmetic-on-the-silicon.md).

EVERY ONE OF THOSE WAS A SINGLE JOB WITH THE HOST SUPPLYING THE ACTIVATION.
Nothing had ever run a SEQUENCE on this silicon: no layer, no chained jobs, no
output of one job feeding the input of the next.  This is that tool.

WHAT IT COVERS AND WHAT IT DOES NOT -- READ THIS BEFORE QUOTING ANY RESULT
--------------------------------------------------------------------------
A transformer layer is not only matvecs.  `hw/fk33/rtl/fk33_engine.vhd`
instantiates `matvec_int4_desc_axi` and NOTHING ELSE, so subsystems B (Gated
DeltaNet), C (gated attention) and D (the sequencer) have never run on this
silicon at all.  What this tool runs on the card is exactly the layer's
subsystem-A matvecs:

  GDN layer      attn_qkv q / k / v, attn_gate, ssm_beta, ssm_alpha,
                 ssm_out, ffn_gate, ffn_up, ffn_down            10 jobs
  attention layer attn_q, attn_k, attn_v, attn_output,
                 ffn_gate, ffn_up, ffn_down                      7 jobs

Everything BETWEEN them -- the two RMS norms, the residual adds, the SwiGLU,
and the whole GDN or attention block -- runs on the HOST.  So the honest
description is: THIS IS THE MATVEC SKELETON OF A LAYER, RUN IN ORDER ON THE
CARD, WITH THE NON-MATVEC STEPS DONE ON THE HOST.  It is still the first
sequence this project has ever run on the silicon, and overclaiming it would be
worse than the result is good.

TWO MODES, AND THE SECOND ONE IS THE POINT
------------------------------------------
  --mode anchored  every job's x comes from the REFERENCE stream.  Each job is
                   independent, so a divergence is attributable to that job and
                   nothing propagates.  This is the CONTROL, and it is what
                   localises a chained failure.
  --mode chained   only the LAYER INPUT comes from the reference.  Every
                   subsequent job's x is derived on the host from the CARD's
                   own outputs, through host norm / SwiGLU / residual steps
                   that `hoststeps` has already proved reproduce the reference
                   bit-for-bit.  The layer OUTPUT is then compared against the
                   reference's R_X-<layer> seam.

  In chained mode there is exactly ONE re-anchor, at the B_JOB (GDN) or C_JOB
  (attention) step, because that computation does not exist on this silicon and
  re-implementing it here would be a second implementation of the thing the
  project is trying to verify.  It is named, counted and printed in the
  summary, never quietly absorbed.

  CHAINING MAKES SELF-CONSISTENCY EASY AND MEANINGLESS, so the comparison is
  never against the previous job: it is always against ref/run9b's stream.

WHY NOT ONE PROCESS PER JOB
---------------------------
MEASURED 2026-08-29 by the dispatcher: `fk33_run_job.py`'s ~150 ms per job is
almost entirely per-invocation setup -- compiling the C oracle, parsing a
117 KB manifest, building the descriptor.  `plan`, which never opens
/dev/xdma*, takes 0.832 s while a full `run` takes 0.684 s, and the card
reports the job itself done in 0.001 s.  So this tool compiles the oracle once,
parses the manifest once, opens the device once, and reuses all three.  With
that removed, what is left IS the PCIe cost, and this tool measures it: every
MMIO access is counted and timed by register (see `Meter`), which is where the
first honest per-job PCIe number in this project comes from.

THE ORACLE
----------
`ref/run9b --acts bfp` (TRACK REF9B,
docs/debugging/2026-08-29_9b-whole-model-reference.md) writes a `.r9bs` stream
of 491 seams per token in the hardware's own INT4 + int16 BFP format, with its
subsystem-A jobs bit-exact against `ref/matvec_int4.c`.  A BFP seam is int16
mantissas plus one shared exponent, which is exactly the card's x and y format,
so the comparison is EXACT and not a tolerance.

`hw/fk33/host/mv4i_job_oracle.c` re-runs each job on the host from the same
seam.  It is NOT an independent oracle for the arithmetic -- it calls the same
`mv4i_matvec` -- and it does not pretend to be.  What it excludes is the HOST:
the step-to-seam mapping, the row window, the segment lookup and the exponent
plumbing in this file.  If the host path reproduces the reference and the card
does not, the disagreement is the card's.

OPEN ISSUE THERM-255
--------------------
The thermal trip counter fires in BURSTS: MEASURED at 30 s granularity, 34
trips in 151 s, then 631 consecutive seconds of exactly zero, then 66 in 150 s.
EACH TRIP HALTS THE COMPUTE DOMAIN.  A layer is a long run and is much more
exposed than the single jobs measured on 2026-08-29.  So the counter is read
before and after EVERY job (`fk33_run_job.run_job` does that), GO_BLOCKED is
cleared before each GO and read after, and a layer in which the counter moved
at any point is reported INCONCLUSIVE -- never PASS, never FAIL.

A HAZARD THIS TOOL FOUND AND CANNOT FIX: STALE `done` ACROSS A SEQUENCE
----------------------------------------------------------------------
`rtl/matvec_int4_desc_axi.vhd` holds `done_l = '1'` in S_DONE and clears it
only when S_IDLE consumes the next GO (`:643`).  So after a GO there are a few
core clocks in which STATUS still reads the PREVIOUS job's `done`, and a host
that polls STATUS immediately would accept a stale completion and read the
previous job's Y registers.  A single-job tool can never meet this; a sequence
meets it on every job after the first.

PCIe ordering plus AXI-Lite latency almost certainly closes it -- the read
cannot pass the posted CTRL write, and the fabric needs about 3 clocks at
200 MHz -- but that is an accident of timing, not a construction.  This tool
therefore checks, per job, that the completion it accepted was NOT stale, using
the engine's own CYCLES and BEATS counters, which are cleared at S_IDLE on GO
and are therefore the previous job's if the completion was stale.  See
`stale_done_check`.  The RTL fix belongs to whoever owns that file: clear
`done_l` on the CTRL write rather than at the next S_IDLE.

NO AGENT MAY RUN THE DEFAULT PATH.  The hardware boundary in CLAUDE.md is
absolute: an agent writes and exercises this through `plan`, `hoststeps`,
`selfcheck` and `run --dry-run`, and the run against the card belongs to
whoever is at the bench.
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
import gen_layer_program as L       # noqa: E402  the ONE layer program
import gen_mv4i_desc as G           # noqa: E402  the ONE descriptor builder
import hbm_map as HM                # noqa: E402  the ONE HBM address space

DEFAULT_MANIFEST = J.DEFAULT_MANIFEST
RMS_EPS = 1e-6                      # ref/run9b.c:142


class LayerError(Exception):
    pass


# ===================================================================== r9bs
# A 30-line reader rather than an import of tools/ref9b/r9bs.py, for ONE
# reason: that module imports numpy at module scope and this file must run on a
# bench host where the only requirement so far has been python3 and cc.  The
# format is tools/ref9b/seam_stream.h and the two readers are checked against
# each other by `selfcheck`, which fails if they disagree on any record.
R9BS_MAGIC = b"R9BS"
KIND_F32, KIND_BFP16, KIND_S32 = 0, 1, 2
_HDR = struct.Struct("<IIiiii")


class Seam(object):
    __slots__ = ("name", "tok", "layer", "kind", "exp", "mant")

    def __init__(self, name, tok, layer, kind, exp, mant):
        self.name, self.tok, self.layer = name, tok, layer
        self.kind, self.exp, self.mant = kind, exp, mant

    @property
    def n(self):
        return len(self.mant)

    def values(self):
        """The real values.  BFP/S32 is mant * 2^-exp -- note the NEGATIVE
        power, the convention tools/pack_int4.py:14 fixes for this project.
        Getting its sign backwards produces a stream wrong by 2^(2*exp) that
        still looks structurally perfect."""
        if self.kind == KIND_F32:
            return list(self.mant)
        e = -self.exp
        return [math.ldexp(m, e) for m in self.mant]


def read_r9bs(path):
    """{(name, tok): Seam}.  A duplicate key RAISES: a silent last-wins would
    let a stream with two records for one seam be compared against whichever
    happened to be later."""
    out = {}
    with open(path, "rb") as fp:
        hdr = fp.read(8)
        if len(hdr) != 8 or hdr[:4] != R9BS_MAGIC:
            raise LayerError("%s is not an r9bs stream" % path)
        ver = struct.unpack("<I", hdr[4:])[0]
        if ver not in (1, 2):
            raise LayerError("%s declares r9bs version %d; this reader knows "
                             "1 and 2" % (path, ver))
        while True:
            b = fp.read(_HDR.size)
            if not b:
                break
            if len(b) != _HDR.size:
                raise LayerError("%s: truncated record header" % path)
            name_len, n, tok, layer, kind, exp = _HDR.unpack(b)
            name = fp.read(name_len).decode("utf-8")
            if kind == KIND_F32:
                fmt, w = "<%df" % n, 4
            elif kind == KIND_BFP16:
                fmt, w = "<%dh" % n, 2
            elif kind == KIND_S32:
                if ver < 2:
                    raise LayerError("%s: an S32 record in a version-1 file; "
                                     "every record after it is mis-framed"
                                     % path)
                fmt, w = "<%di" % n, 4
            else:
                raise LayerError("%s: record %r has unknown kind %d, so the "
                                 "payload width is unknown and every record "
                                 "after it would be mis-framed"
                                 % (path, name, kind))
            payload = fp.read(n * w)
            if len(payload) != n * w:
                raise LayerError("%s: truncated payload for %s" % (path, name))
            key = (name, tok)
            if key in out:
                raise LayerError("%s: duplicate seam %r" % (path, key))
            out[key] = Seam(name, tok, layer, kind, exp,
                            list(struct.unpack(fmt, payload)))
    return out


# ============================================================ the seam map
# WHERE THIS COMES FROM.  ref/run9b.c's layer_gdn() (:576-715) and
# layer_attn() (:730-849) name every seam as they produce it, and the A jobs in
# tools/gen_layer_program.py's build_plan() are the same jobs in the same
# order.  This table is the join, keyed on the packed tensor and -- for the
# fused attn_qkv, which is three jobs -- on the LOGICAL row the step asks for.
#
# IT IS NOT TRUSTED.  make_layer() checks every row of it against the stream by
# shape (the source seam must be exactly K long and the destination exactly
# n_rows) and by exponent (w_exp + x_exp - out_shift - dst_exp must be a
# non-negative ns), and `plan` then RE-RUNS every job on the host through
# ref/matvec_int4.c and requires the destination seam back, element for
# element.  A wrong row here cannot survive any of the three.
SEAM_SRC = {
    "attn_qkv.weight": "R_XN",      "attn_gate.weight": "R_XN",
    "ssm_beta.weight": "R_XN",      "ssm_alpha.weight": "R_XN",
    "ssm_out.weight": "R_Y",
    "attn_q.weight": "R_XN",        "attn_k.weight": "R_XN",
    "attn_v.weight": "R_XN",        "attn_output.weight": "R_Y",
    "ffn_gate.weight": "R_XN.ffn",  "ffn_up.weight": "R_XN.ffn",
    "ffn_down.weight": "R_H",
}
SEAM_DST = {
    ("attn_qkv.weight", 0): "R_QKV.q",
    ("attn_qkv.weight", 2048): "R_QKV.k",
    ("attn_qkv.weight", 4096): "R_QKV.v",
    ("attn_gate.weight", 0): "R_Z",
    ("ssm_beta.weight", 0): "R_BETA",
    ("ssm_alpha.weight", 0): "R_ALPHA",
    ("ssm_out.weight", 0): "R_ER",
    ("attn_q.weight", 0): "R_QG",
    ("attn_k.weight", 0): "R_KIN",
    ("attn_v.weight", 0): "R_VIN",
    ("attn_output.weight", 0): "R_ER",
    ("ffn_gate.weight", 0): "R_G",
    ("ffn_up.weight", 0): "R_U",
    ("ffn_down.weight", 0): "R_ER.ffn",
}

# The host-side non-matvec steps of one layer, in order, as (kind, out, args).
# Every one is checked against the stream by `hoststeps` before `run --mode
# chained` will use it; `run` refuses chained mode if that check has not been
# made in the same invocation.
HOST_GDN = [
    ("norm", "R_XN",      ("R_IN",), "attn_norm.weight"),
    ("gap",  "R_Y",       (), "the Gated DeltaNet block -- subsystem B, which "
                              "is not on this silicon"),
    ("res",  "R_X.attn",  ("R_IN", "R_ER"), None),
    ("norm", "R_XN.ffn",  ("R_X.attn",), "post_attention_norm.weight"),
    ("swg",  "R_H",       ("R_G", "R_U"), None),
    ("res",  "R_X",       ("R_X.attn", "R_ER.ffn"), None),
]
HOST_ATTN = [
    ("norm", "R_XN",      ("R_IN",), "attn_norm.weight"),
    ("gap",  "R_Y",       (), "the gated attention block -- subsystem C, which "
                              "is not on this silicon"),
    ("res",  "R_X.attn",  ("R_IN", "R_ER"), None),
    ("norm", "R_XN.ffn",  ("R_X.attn",), "post_attention_norm.weight"),
    ("swg",  "R_H",       ("R_G", "R_U"), None),
    ("res",  "R_X",       ("R_X.attn", "R_ER.ffn"), None),
]


# =========================================================== host arithmetic
# ref/run9b.c's rmsnorm (:519), silu (:543) and reg_put (:315), re-expressed in
# Python floats, which are C doubles.  The SUMMATION ORDER is sequential
# because the reference's is: a pairwise or vectorised sum is a different
# number in the last bits, and the last bits are the whole comparison.
#
# These are a SECOND IMPLEMENTATION of six lines of the reference, and this
# project's standing position is that two producers agreeing is not evidence.
# So they are never used on trust: `hoststeps` drives each one from the
# reference's own input seam and requires the reference's own output seam back,
# mantissa for mantissa and exponent for exponent, before `run --mode chained`
# is allowed to use any of them.
def sat16(q):
    return -32768 if q < -32768 else (32767 if q > 32767 else int(q))


def reg_put(v):
    """float vector -> (int16 mantissas, exp).  ref/run9b.c:315.

    NOTE THIS IS THE UNCLAMPED REPACK RULE and the shipping RTL units use the
    clamped one -- open issue 'BFP repack rule' on the worklog, MEASURED as 341
    of 760 exponents differing on quiet blocks.  That does not affect this tool:
    the host performs these steps and the reference performed the same ones, so
    both sides are on the same rule, and no clamped unit is on the card.  It
    WILL matter the day subsystem D's vector ops run on the silicon."""
    amax = 0.0
    for x in v:
        a = -x if x < 0.0 else x
        if a > amax:
            amax = a
    if amax == 0.0:
        return [0] * len(v), 0
    e = int(math.floor(math.log2(amax)))
    exp = 14 - e
    m = [sat16(math.floor(math.ldexp(x, exp) + 0.5)) for x in v]
    return m, exp


def host_rmsnorm(x, w):
    s = 0.0
    for xi in x:
        s += xi * xi
    inv = 1.0 / math.sqrt(s / len(x) + RMS_EPS)
    return [x[i] * inv * w[i] for i in range(len(x))]


def host_silu_mul(g, u):
    return [(g[i] / (1.0 + math.exp(-g[i]))) * u[i] for i in range(len(g))]


def host_add(a, b):
    return [a[i] + b[i] for i in range(len(a))]


# ------------------------------------------------------- the f32 side tensors
def load_f32_index(packed_dir):
    """The `F32 <name> <offset> <nbytes> <ne0> <ne1>` rows of index.txt, which
    tools/ref9b/make_index.py copies out of the packer's own manifest.  Reading
    the index rather than re-deriving offsets is what makes it impossible for
    this file and ref/run9b.c to disagree about where a norm weight lives."""
    idx = os.path.join(packed_dir, "index.txt")
    if not os.path.exists(idx):
        raise LayerError("%s does not exist.  Build it with\n"
                         "  python3 tools/ref9b/make_index.py %s"
                         % (idx, packed_dir))
    blob, out = None, {}
    for line in open(idx):
        f = line.split()
        if not f or f[0].startswith("#"):
            continue
        if f[0] == "BLOB":
            blob = os.path.join(packed_dir, f[1])
        elif f[0] == "F32":
            out[f[1]] = (int(f[2]), int(f[3]))
    if blob is None:
        raise LayerError("%s names no BLOB, so no f32 tensor can be read" % idx)
    return blob, out


def f32_tensor(blob, f32idx, name):
    if name not in f32idx:
        raise LayerError("no f32 tensor %r in the packed index" % name)
    off, nbytes = f32idx[name]
    with open(blob, "rb") as fp:
        fp.seek(off)
        b = fp.read(nbytes)
    if len(b) != nbytes:
        raise LayerError("%s: short read for %s" % (blob, name))
    return list(struct.unpack("<%df" % (nbytes // 4), b))


# ================================================================== the plan
class Job(object):
    __slots__ = ("idx", "step", "tensor", "short", "logical_row", "row_start",
                 "n_rows", "n_cols", "M", "K", "w_exp", "out_shift",
                 "src_seam", "dst_seam", "mv4i", "hbm_offset", "desc_addr",
                 "src_region", "dst_region", "dst_off", "ordinal", "src2",
                 "const_base", "out_mode", "segment")


def make_layer(a):
    """The layer's A jobs, their descriptors' inputs, and the seams each one
    reads and writes.  No card, no /dev, and no descriptor is built yet: the
    x_exp a descriptor carries is a property of the vector that reaches the job,
    which in chained mode is not known until the previous job has run."""
    mani_path = a.manifest
    mani = json.load(open(mani_path))
    root = os.path.dirname(os.path.abspath(mani_path))
    by_file = {f["file"]: f for f in mani["files"]}

    # tools/gen_layer_program.py's own QWEN35_9B, which is
    # rtl/model_cfg_pkg.vhd's record and is cross-checked against the packed
    # tensors' shapes by that module's check_against_manifest().  Restating the
    # eleven numbers here would create a second shape free to disagree.
    s = L.QWEN35_9B
    if not 0 <= a.layer < s.blocks:
        raise LayerError("--layer %d is outside the model's %d blocks"
                         % (a.layer, s.blocks))

    steps = L.build_plan(s, lm_windows=L.lmhead_windows(s))
    sel = L.layer_slice(steps, a.layer)
    ajobs = [st for st in sel if st.opcode == L.OP_A_JOB]
    if not ajobs:
        raise LayerError("layer %d has no A_JOB steps, which cannot happen; "
                         "the slice is wrong" % a.layer)

    # The descriptor arena, DECIDED BY hbm_map through gen_layer_program, never
    # computed here.  Two producers each free to compute an address is how the
    # arena landed on top of the logits row once already (see place_desc_arena).
    class _A:
        pass
    pa = _A()
    pa.desc_base, pa.max_chunk, pa.print = None, None, False
    # "manifest" is hbm_map.plan()'s default and the ONLY policy that performs
    # no placement arithmetic: it reads the region block the packer wrote.  A
    # tool that computed the address itself would be a third allocator, which
    # is the defect place_desc_arena() exists to have removed.
    pa.desc_policy = "manifest"
    arena_base = L.place_desc_arena(pa, mani, steps, sel)
    stride = int(mani["hbm"].get("desc_arena_stride", 512))
    n_slots = int(mani["hbm"].get("desc_arena_jobs",
                                  mani["hbm"]["desc_arena_bytes"] // stride))
    if len(ajobs) > n_slots:
        raise LayerError("the layer needs %d descriptor slots and the arena "
                         "has %d" % (len(ajobs), n_slots))

    jobs = []
    for i, st in enumerate(ajobs):
        name = st.tensor + ".mv4i"
        ent = by_file.get(name)
        if ent is None:
            raise LayerError("%s is not in %s.  The card cannot be pointed at "
                             "a tensor the manifest does not place."
                             % (name, mani_path))
        path = os.path.join(root, name)
        h = G.Mv4iHeader(path)

        # LOGICAL row -> PACKED row, through the manifest's own segment table.
        # A lookup, never an arithmetic re-derivation: at ROWS_IF = 48 the
        # unpadded starts 2048 and 4096 are not tile multiples (2048 mod 48 =
        # 32) and two of the three qkv jobs would be inexpressible.
        packed_start, seg = st.row_start, None
        segs = ent.get("segments")
        if segs:
            hit = [q for q in segs
                   if q.get("logical_row", q["row_start"]) == st.row_start
                   and q["n_rows"] == st.n_rows]
            if len(hit) != 1:
                raise LayerError(
                    "%s declares %d row segments and %d of them is the window "
                    "(logical row %d, %d rows) step %d asks for"
                    % (name, len(segs), len(hit), st.row_start, st.n_rows,
                       st.idx))
            packed_start, seg = hit[0]["row_start"], hit[0]["name"]
        elif st.row_start and int(ent.get("M_logical", ent["M"])) != ent["M"]:
            raise LayerError("%s is padded but declares no segments" % name)
        if packed_start + st.n_rows > h.M:
            raise LayerError("%s window rows %d..%d runs past the packed M = %d"
                             % (name, packed_start,
                                packed_start + st.n_rows - 1, h.M))

        short = st.tensor.split(".", 2)[-1]
        if short not in SEAM_SRC or (short, st.row_start) not in SEAM_DST:
            raise LayerError(
                "no seam mapping for tensor %r at logical row %d.  This file "
                "will not guess: a wrong seam pairing compares the card "
                "against the wrong numbers and reads as an arithmetic defect."
                % (short, st.row_start))

        j = Job()
        j.idx, j.step, j.tensor, j.short = i, st.idx, st.tensor, short
        j.logical_row, j.row_start, j.segment = st.row_start, packed_start, seg
        j.n_rows, j.n_cols = st.n_rows, st.n_cols
        j.M, j.K, j.w_exp, j.out_shift = h.M, h.K, h.w_exp, h.out_shift
        j.mv4i, j.hbm_offset = path, int(ent["hbm_offset"])
        j.desc_addr = arena_base + i * stride
        j.src_region, j.dst_region, j.dst_off = st.src, st.dst, st.dst_off
        j.ordinal, j.src2, j.const_base = st.ordinal, st.src2, st.const_base
        j.out_mode = st.out_mode
        j.src_seam = "%s-%d" % (SEAM_SRC[short], a.layer)
        j.dst_seam = "%s-%d" % (SEAM_DST[(short, st.row_start)], a.layer)
        if j.n_cols != h.K:
            raise LayerError("step %d asks for n_cols = %d and %s has K = %d"
                             % (st.idx, j.n_cols, name, h.K))
        jobs.append(j)

    check_same_bytes(jobs, mani_path, a.ref_manifest)

    return dict(shape=s, steps=steps, sel=sel, jobs=jobs, manifest=mani,
                manifest_path=mani_path, root=root, arena_base=arena_base,
                stride=stride, n_slots=n_slots,
                is_attn=s.is_attn(a.layer), layer=a.layer)


def check_same_bytes(jobs, run_manifest, ref_manifest):
    """The reference was built against ONE packed set and the card holds
    ANOTHER.  Require them to be the same bytes for every tensor this layer
    touches.

    THIS IS NOT PEDANTRY, IT IS THE LOAD-BEARING FACT.  MEASURED 2026-08-29:
    `qwen35-9b-mv4i-noembd` (4,487,442,432 B, what the loader wrote to HBM) and
    `qwen35-9b-mv4i-qkvpad` (5,059,649,536 B, what TRACK REF9B built the
    reference against) share 250 files, every one with an IDENTICAL
    blake2b_128, and differ only by `token_embd.weight` -- which is an
    embedding gather, not a matvec, and is not on the card at all.  Only the
    hbm_offset differs, and that comes from the run manifest.

    So the comparison is legitimate.  But nothing enforced it, and two sets
    with the same tensor names and different bytes would produce a wrong-answer
    report with no fault anywhere.  A digest disagreement here is a REFUSAL,
    and a manifest that declares no digest is also a refusal: an absent digest
    must not be able to pass by being absent."""
    if not ref_manifest:
        return None
    a = {f["file"]: f for f in json.load(open(run_manifest))["files"]}
    b = {f["file"]: f for f in json.load(open(ref_manifest))["files"]}
    bad, checked = [], 0
    for j in jobs:
        name = j.tensor + ".mv4i"
        ea, eb = a.get(name), b.get(name)
        if ea is None or eb is None:
            bad.append("%s is in %s"
                       % (name, "only the run manifest" if eb is None
                          else "only the reference manifest"))
            continue
        da, db = ea.get("blake2b_128"), eb.get("blake2b_128")
        if da is None or db is None:
            bad.append("%s carries no blake2b_128 in %s"
                       % (name, "the run manifest" if da is None
                          else "the reference manifest"))
            continue
        checked += 1
        if da != db:
            bad.append("%s hashes %s on the card's set and %s on the "
                       "reference's" % (name, da, db))
    if bad:
        raise LayerError(
            "the card's packed set and the reference's are not the same bytes "
            "for this layer:\n  " + "\n  ".join(bad))
    return checked


# =========================================== the reference, and what it pins
def bind_reference(plan, ref, tok):
    """Attach the reference seam to every job, and CHECK the mapping.

    Three checks, and each catches a different way of pairing a job with the
    wrong seam:

      shape      the source seam must be exactly n_cols long and the
                 destination exactly n_rows.  Catches most swaps outright.
      exponent   ns = w_exp + x_exp - out_shift - dst_exp must be a
                 NON-NEGATIVE integer, because ns is a right shift chosen by
                 the job itself (ref/matvec_int4.c:413).  A negative ns means
                 the two seams cannot be the input and output of this job.
      presence   a seam this layer needs and the stream does not carry is a
                 REFUSAL, never a skip.  A checker that skips an object can
                 still print PASS; measured in this repository on 2026-08-29
                 at 250 objects in, 249 checked, PASS."""
    notes = []
    for j in plan["jobs"]:
        src = ref.get((j.src_seam, tok))
        dst = ref.get((j.dst_seam, tok))
        if src is None or dst is None:
            raise LayerError(
                "the reference stream carries no %s for token %d.  Regenerate "
                "it over enough layers:\n  ref/run9b --packed DIR --acts bfp "
                "--tokens ... --layers %d --out REF.r9bs"
                % (j.src_seam if src is None else j.dst_seam, tok,
                   plan["layer"] + 1))
        if src.kind != KIND_BFP16 or dst.kind != KIND_BFP16:
            raise LayerError("%s / %s are not both BFP16 records; only a BFP "
                             "seam is the card's own format and only a BFP "
                             "comparison is exact" % (j.src_seam, j.dst_seam))
        if src.n != j.n_cols:
            raise LayerError("seam %s has %d elements and job %d needs "
                             "n_cols = %d" % (j.src_seam, src.n, j.idx, j.n_cols))
        if dst.n != j.n_rows:
            raise LayerError("seam %s has %d elements and job %d produces "
                             "n_rows = %d" % (j.dst_seam, dst.n, j.idx, j.n_rows))
        ns = j.w_exp + src.exp - j.out_shift - dst.exp
        if ns < 0:
            raise LayerError(
                "seams %s -> %s imply ns = %d for job %d, and ns is a right "
                "shift the job chooses, so it cannot be negative.  The pairing "
                "is wrong." % (j.src_seam, j.dst_seam, ns, j.idx))
        notes.append((j, src, dst, ns))
    return notes


# ================================================== the host-side re-run
def host_rerun(plan, ref, tok, scratch, cc="cc"):
    """Re-run every job of the layer on the HOST, from the reference's own
    source seam, and require the reference's own destination seam back.

    This is what makes `plan` a NUMERIC statement rather than a structural one,
    with no card in the room.  It excludes the host: if this passes and the card
    later disagrees, the disagreement is the card's.  It does not exclude the
    arithmetic, because it calls the same mv4i_matvec ref/run9b.c calls -- see
    the header of hw/fk33/host/mv4i_job_oracle.c."""
    exe = build_job_oracle(scratch, cc)
    xdir = os.path.join(scratch, "x")
    ydir = os.path.join(scratch, "y")
    os.makedirs(xdir, exist_ok=True)
    os.makedirs(ydir, exist_ok=True)

    fids, spec = {}, []
    for j in plan["jobs"]:
        if j.mv4i not in fids:
            fids[j.mv4i] = len(fids)
            spec.append("FILE %d %s" % (fids[j.mv4i], j.mv4i))
    for j in plan["jobs"]:
        src = ref[(j.src_seam, tok)]
        xp = os.path.join(xdir, "j%02d.i16" % j.idx)
        with open(xp, "wb") as fp:
            fp.write(struct.pack("<%dh" % src.n, *src.mant))
        spec.append("JOB j%02d %d %d %d %d %s %s"
                    % (j.idx, fids[j.mv4i], j.row_start, j.n_rows, src.exp,
                       xp, os.path.join(ydir, "j%02d.i16" % j.idx)))
    spec_path = os.path.join(scratch, "oracle.spec")
    open(spec_path, "w").write("\n".join(spec) + "\n")

    t0 = time.time()
    r = subprocess.run([exe, spec_path], capture_output=True, text=True)
    wall = time.time() - t0
    got = {}
    for line in r.stdout.splitlines():
        f = line.split()
        if f and f[0] == "Y":
            got[f[1]] = dict(y_exp=int(f[2]), ns=int(f[3]), n=int(f[4]),
                             sat=int(f[5]))
        elif f and f[0] == "BAD":
            raise LayerError("mv4i_job_oracle refused %s: %s" % (f[1], f[2]))
    if r.returncode:
        raise LayerError("mv4i_job_oracle failed (rc=%d):\n%s"
                         % (r.returncode, r.stderr))

    rows = []
    for j in plan["jobs"]:
        key = "j%02d" % j.idx
        if key not in got:
            raise LayerError("mv4i_job_oracle produced no result for job %d; "
                             "a missing job is a refusal, not a pass" % j.idx)
        yp = os.path.join(ydir, "%s.i16" % key)
        mant = list(struct.unpack("<%dh" % j.n_rows,
                                  open(yp, "rb").read()))
        dst = ref[(j.dst_seam, tok)]
        bad = [i for i in range(j.n_rows) if mant[i] != dst.mant[i]]
        rows.append(dict(job=j, y_exp=got[key]["y_exp"], ns=got[key]["ns"],
                         sat=got[key]["sat"], ndiff=len(bad),
                         exp_ok=got[key]["y_exp"] == dst.exp,
                         first=bad[0] if bad else -1, mant=mant))
    return rows, wall


def build_job_oracle(scratch, cc="cc"):
    src = os.path.join(HERE, "mv4i_job_oracle.c")
    exe = os.path.join(scratch, "mv4i_job_oracle")
    dep = os.path.join(REPO, "ref", "matvec_int4.c")
    if (not os.path.exists(exe)
            or os.path.getmtime(exe) < max(os.path.getmtime(src),
                                           os.path.getmtime(dep))):
        # No -DNDEBUG: ref/matvec_int4.c #errors under it on purpose, because
        # every width bound of spec 7.4 is enforced by assert() alone.
        cmd = [cc, "-O2", "-w", "-I", os.path.join(REPO, "ref"),
               "-o", exe, src, "-lm"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            raise LayerError("could not build the job oracle:\n  %s\n%s"
                             % (" ".join(cmd), r.stderr))
    return exe


# ============================================= the host non-matvec steps
def check_host_steps(plan, ref, tok, packed_dir, out=None):
    """Drive each host step from the reference's OWN input seam and require the
    reference's OWN output seam back, mantissa for mantissa.

    This is the gate on `--mode chained`.  Chaining the card's outputs through
    a host step that is even one ulp off the reference produces a divergence
    that looks exactly like a card defect, and that misattribution is the whole
    reason this check runs first and separately.

    A step whose input seam is not in the stream is REPORTED as uncovered, not
    silently dropped: coverage is stated, never left as a tally the reader has
    to subtract."""
    out = out or sys.stdout
    w = out.write
    layer = plan["layer"]
    blob, f32idx = load_f32_index(packed_dir)
    prev = "R_X-%d" % (layer - 1) if layer else "R_X.embed"
    table = HOST_ATTN if plan["is_attn"] else HOST_GDN
    rows = []
    for kind, dst, srcs, arg in table:
        if kind == "gap":
            rows.append((kind, dst, "GAP", 0, 0, arg))
            continue
        names = [prev if s == "R_IN" else "%s-%d" % (s, layer) for s in srcs]
        dname = "%s-%d" % (dst, layer)
        have = [ref.get((n, tok)) for n in names]
        d = ref.get((dname, tok))
        if any(h is None for h in have) or d is None:
            miss = [n for n, h in zip(names, have) if h is None]
            if d is None:
                miss.append(dname)
            rows.append((kind, dst, "UNCOVERED", 0, 0,
                         "the stream carries no " + ", ".join(miss)))
            continue
        vals = [h.values() for h in have]
        if kind == "norm":
            wt = f32_tensor(blob, f32idx, "blk.%d.%s" % (layer, arg))
            if len(wt) != len(vals[0]):
                rows.append((kind, dst, "UNCOVERED", 0, 0,
                             "blk.%d.%s has %d elements and the seam has %d"
                             % (layer, arg, len(wt), len(vals[0]))))
                continue
            got = host_rmsnorm(vals[0], wt)
        elif kind == "res":
            got = host_add(vals[0], vals[1])
        elif kind == "swg":
            got = host_silu_mul(vals[0], vals[1])
        else:
            raise LayerError("unknown host step kind %r" % kind)
        m, e = reg_put(got)
        nd = sum(1 for i in range(len(m)) if m[i] != d.mant[i])
        rows.append((kind, dst, "PASS" if (nd == 0 and e == d.exp) else "FAIL",
                     nd, e - d.exp,
                     "%s -> %s" % (" + ".join(names), dname)))

    w("\nhost non-matvec steps, driven from the reference's own inputs:\n")
    w("  %-6s %-12s %-10s %8s %7s  %s\n"
      % ("kind", "produces", "verdict", "mant!=", "d(exp)", "detail"))
    for kind, dst, v, nd, de, detail in rows:
        w("  %-6s %-12s %-10s %8s %7s  %s\n"
          % (kind, dst, v, nd if v in ("PASS", "FAIL") else "-",
             de if v in ("PASS", "FAIL") else "-", detail))
    npass = sum(1 for r in rows if r[2] == "PASS")
    nfail = sum(1 for r in rows if r[2] == "FAIL")
    nunc = sum(1 for r in rows if r[2] == "UNCOVERED")
    ngap = sum(1 for r in rows if r[2] == "GAP")
    w("  coverage    %d checked (%d pass, %d fail), %d uncovered, "
      "%d structural gaps that no host step can fill\n"
      % (npass + nfail, npass, nfail, nunc, ngap))
    return rows, nfail == 0 and nunc == 0


# ================================================================ the meter
class Meter(object):
    """Wraps a register/HBM transport and RECORDS every access.

    THE REASON IT EXISTS is a measurement, not a debug aid.  This project's
    only published per-job figure was ~150 ms, and it was withdrawn: it was
    per-invocation setup, not PCIe.  With setup amortised, what is left is
    PCIe, and the honest way to report it is per REGISTER -- the activation
    write is thousands of MMIO writes and the Y readback is three MMIO
    accesses per row, and lumping them hides which one to attack.

    It also gives the layer-level checks access to the VALUES fk33_run_job read
    (BEATS, CYCLES, the first STATUS poll) without parsing its text output.  A
    check that scrapes prose breaks silently when the prose changes."""

    def __init__(self, inner, kind):
        self.inner, self.kind = inner, kind
        self.reset()

    def reset(self):
        self.log = []                # (t_start, dt, 'r'/'w', off, value)
        self.rd_n = self.wr_n = 0
        self.rd_s = self.wr_s = 0.0
        self.by_off = {}             # off -> [n_rd, s_rd, n_wr, s_wr]
        self.hbm_wb = self.hbm_rb = 0
        self.hbm_ws = self.hbm_rs = 0.0

    def _acc(self, off, dt, is_rd):
        e = self.by_off.setdefault(off, [0, 0.0, 0, 0.0])
        if is_rd:
            e[0] += 1
            e[1] += dt
        else:
            e[2] += 1
            e[3] += dt

    def rd(self, off):
        t = time.time()
        v = self.inner.rd(off)
        dt = time.time() - t
        self.rd_n += 1
        self.rd_s += dt
        self._acc(off, dt, True)
        self.log.append((t, dt, "r", off, v))
        return v

    def wr(self, off, val):
        t = time.time()
        self.inner.wr(off, val)
        dt = time.time() - t
        self.wr_n += 1
        self.wr_s += dt
        self._acc(off, dt, False)
        self.log.append((t, dt, "w", off, val))

    def write(self, addr, data):
        t = time.time()
        self.inner.write(addr, data)
        self.hbm_ws += time.time() - t
        self.hbm_wb += len(data)

    def read(self, addr, n):
        t = time.time()
        d = self.inner.read(addr, n)
        self.hbm_rs += time.time() - t
        self.hbm_rb += n
        return d

    def close(self):
        self.inner.close()

    # -- what the layer-level checks ask it
    def last_read(self, off, default=None):
        for t, dt, k, o, v in reversed(self.log):
            if k == "r" and o == off:
                return v
        return default

    def reads_of(self, off):
        return [v for t, dt, k, o, v in self.log if k == "r" and o == off]

    def first_status_after_go(self, ctrl_off, status_off):
        """(elapsed_since_go, value) for the FIRST STATUS read after the GO
        write, or None.  This is what makes the stale-`done` hazard visible."""
        go_t = None
        for t, dt, k, o, v in self.log:
            if k == "w" and o == ctrl_off:
                go_t = t + dt
            elif k == "r" and o == status_off and go_t is not None:
                return (t - go_t, v)
        return None


# ======================================================= the stale-done check
def stale_done_check(meter, regs, j, ns_cycles_per_beat=21.6):
    """Did this job's completion belong to THIS job?

    rtl/matvec_int4_desc_axi.vhd holds done_l through S_DONE and clears it only
    when S_IDLE consumes the next GO (:643).  So a host that polls STATUS too
    soon after a GO can accept the PREVIOUS job's completion and then read the
    previous job's Y registers -- a wrong number with no error anywhere, and a
    failure mode a single-job tool can never meet.

    CYCLES and BEATS are cleared at S_IDLE on the same GO (:646-648), so a
    stale completion reports the PREVIOUS job's counters.  BEATS has a
    predicted value for this job -- tiles * nblk -- so requiring it is a direct
    test.  Returns (ok, detail).  A BEATS that merely disagrees is reported as
    a WARN by fk33_run_job because that register's semantics were never
    verified against the RTL; here it is used only to answer a narrower
    question, namely whether the counter belongs to a different job."""
    beats = meter.last_read(regs["FK33_ENG_BEATS"])
    cycles = meter.last_read(regs["FK33_ENG_CYCLES"])
    tiles = (j.n_rows + 48 - 1) // 48
    want = tiles * ((j.K + 32 - 1) // 32)
    fs = meter.first_status_after_go(regs["FK33_ENG_CTRL"],
                                     regs["FK33_ENG_STATUS"])
    detail = "BEATS=%s want %d, CYCLES=%s" % (beats, want, cycles)
    if fs is not None:
        detail += ", first STATUS %.1f us after GO = 0x%08X" % (fs[0] * 1e6, fs[1])
    if beats is None:
        return True, detail + " (no BEATS read; not checked)"
    if beats != want:
        return False, (detail + " -- the completion does not belong to this "
                       "job, or BEATS does not mean what tiles*nblk predicts")
    return True, detail


# ===================================================================== run
def run_layer(a, plan, ref, tok, regs, bar, hbm, out=None):
    out = out or sys.stdout
    w = out.write
    tok_ref = ref
    layer = plan["layer"]
    chained = a.mode == "chained"
    prev_name = "R_X-%d" % (layer - 1) if layer else "R_X.embed"

    # The live region values, as (mantissas, exp).  In anchored mode every one
    # of them is the reference's; in chained mode only the layer input is, plus
    # the one re-anchor at the block that is not on this silicon.
    live, anchored_from_ref = {}, []

    def take(name):
        return live[name]

    def seed(name):
        s = tok_ref[(name, tok)]
        live[name] = (list(s.mant), s.exp)
        anchored_from_ref.append(name)

    seed(prev_name)
    if not chained:
        for j in plan["jobs"]:
            if j.src_seam not in live:
                seed(j.src_seam)
    else:
        blob, f32idx = load_f32_index(a.packed)

    class _JA:
        pass
    ja = _JA()
    ja.timeout, ja.show, ja.addr_w = a.timeout, a.show, a.addr_w

    host_table = HOST_ATTN if plan["is_attn"] else HOST_GDN
    host_by_dst = {}
    for kind, dst, srcs, arg in host_table:
        host_by_dst[dst] = (kind, srcs, arg)

    def host_step_for(seam_short, reanchors=None):
        """Run the host step producing `seam_short`, from `live`.

        RECURSIVE, because the dependency is a chain and not a list: the second
        residual needs R_X.attn, which needs R_ER, which the card produced.  A
        one-level version ran the whole layer and then raised a KeyError three
        steps from the end -- caught in the dry run, which is what the dry run
        is for."""
        kind, srcs, arg = host_by_dst[seam_short]
        names = [prev_name if s == "R_IN" else "%s-%d" % (s, layer)
                 for s in srcs]
        vals = []
        for n in names:
            if n not in live:
                short = n.rsplit("-", 1)[0]
                if short not in host_by_dst:
                    raise LayerError(
                        "nothing produces %s, which %s needs" % (n, seam_short))
                if host_by_dst[short][0] == "gap":
                    seed(n)
                    if reanchors is not None:
                        reanchors.append((n, host_by_dst[short][2]))
                else:
                    host_step_for(short, reanchors)
            m, e = take(n)
            ee = -e
            vals.append([math.ldexp(x, ee) for x in m])
        if kind == "norm":
            wt = f32_tensor(blob, f32idx, "blk.%d.%s" % (layer, arg))
            got = host_rmsnorm(vals[0], wt)
        elif kind == "res":
            got = host_add(vals[0], vals[1])
        elif kind == "swg":
            got = host_silu_mul(vals[0], vals[1])
        else:
            raise LayerError("host step %r has no implementation" % kind)
        live["%s-%d" % (seam_short, layer)] = reg_put(got)

    # In chained mode a job's x may need a host step that has not run yet.
    # The order is fixed by the program, so walk it: before each job, if its
    # source seam is not live, produce it -- by the host step that makes it, or
    # by re-anchoring at the ONE block this silicon does not carry.
    def ensure(seam_full, short, reanchors):
        if seam_full in live:
            return None
        if short not in host_by_dst:
            raise LayerError("nothing produces %s" % seam_full)
        if host_by_dst[short][0] == "gap":
            seed(seam_full)
            return host_by_dst[short][2]
        host_step_for(short, reanchors)
        return None

    results = []
    trips_moved = False
    reanchors = []
    t_layer = time.time()

    for j in plan["jobs"]:
        if chained:
            why = ensure(j.src_seam, j.src_seam.rsplit("-", 1)[0], reanchors)
            if why:
                reanchors.append((j.src_seam, why))
        xm, xe = take(j.src_seam)

        d = G.build_descriptor(
            G.Mv4iHeader(j.mv4i), j.hbm_offset, j.n_rows, xe,
            out_mode=j.out_mode, cb_load=True, addr_w=a.addr_w,
            row_start=j.row_start, src_region=j.src_region,
            dst_region=j.dst_region, dst_offset=j.dst_off, ordinal=j.ordinal,
            src_region2=j.src2, const_base=j.const_base, const_exp=0)
        bad = G.rtl_would_reject(d, build=_build(a), desc_addr=j.desc_addr)
        if bad:
            raise LayerError(
                "job %d (%s) would be REFUSED by the gateware before it ran:\n  "
                % (j.idx, j.tensor)
                + "\n  ".join("%s %s" % ("0x%X" % c if c is not None else "----",
                                         n) for c, n in bad))

        dstref = tok_ref[(j.dst_seam, tok)]
        p = dict(desc=d, fields=d.fields, desc_addr=j.desc_addr,
                 stride=plan["stride"],
                 oracle=dict(x=[m & 0xFFFF for m in xm],
                             ymant={r: dstref.mant[r] & 0xFFFFFFFFFFFFFFFF
                                    for r in range(j.n_rows)},
                             y_exp=dstref.exp))

        bar.reset()
        hbm.reset() if hasattr(hbm, "reset") else None
        t0 = time.time()
        buf = _Sink()
        try:
            verdict, detail = J.run_job(p, regs, bar, hbm, ja, buf)
        except J.RunError as e:
            verdict, detail = J.Verdict.REFUSED, str(e).splitlines()[0]
        wall = time.time() - t0

        ok_stale, stale_detail = stale_done_check(bar, regs, j)
        if verdict == J.Verdict.PASS and not ok_stale:
            verdict = J.Verdict.INCONCLUSIVE
            detail = ("the numbers match but the completion may not belong to "
                      "this job: " + stale_detail)

        yexp = bar.last_read(regs["FK33_ENG_Y_EXP"])
        got_m = _read_back_mantissas(bar, regs, j.n_rows)
        ndiff = sum(1 for r in range(j.n_rows)
                    if got_m[r] != (dstref.mant[r] & 0xFFFFFFFFFFFFFFFF))

        if "trip counter moved" in detail or "trips=" in buf.text and _moved(buf.text):
            trips_moved = True

        results.append(dict(job=j, verdict=verdict, detail=detail, wall=wall,
                            x_exp=xe, y_exp=yexp, ndiff=ndiff,
                            stale=stale_detail, text=buf.text,
                            rd_n=bar.rd_n, rd_s=bar.rd_s,
                            wr_n=bar.wr_n, wr_s=bar.wr_s,
                            by_off=dict(bar.by_off),
                            hbm_wb=bar.hbm_wb if hasattr(bar, "hbm_wb") else 0))

        if verdict != J.Verdict.PASS:
            w("job %-2d %-28s %-12s %s\n"
              % (j.idx, j.short, verdict, detail))
            if a.stop_on_fail:
                break
        else:
            w("job %-2d %-28s PASS  %5d rows, y_exp=%s, %.3f s\n"
              % (j.idx, j.short, j.n_rows, yexp, wall))

        # The card's own answer becomes the live region, in chained mode.
        if chained and verdict == J.Verdict.PASS:
            live[j.dst_seam] = ([_sx16(v) for v in got_m], yexp)
        else:
            live[j.dst_seam] = (list(dstref.mant), dstref.exp)
            if chained and verdict != J.Verdict.PASS:
                reanchors.append((j.dst_seam, "the job did not PASS, so the "
                                  "chain was re-anchored to keep going"))

    t_layer = time.time() - t_layer

    # ---- THE LAYER OUTPUT.  In chained mode the last host step (the second
    # residual) closes the layer, and its result is compared against the
    # reference's own R_X-<layer> seam.  That comparison is the deliverable:
    # a per-job table can be green while the composition is wrong.
    layer_out = None
    if chained and all(r["verdict"] == J.Verdict.PASS for r in results):
        try:
            host_step_for("R_X", reanchors)
            m, e = live["R_X-%d" % layer]
            d = tok_ref[("R_X-%d" % layer, tok)]
            nd = sum(1 for i in range(len(m)) if m[i] != d.mant[i])
            layer_out = dict(n=len(m), ndiff=nd, exp=e, ref_exp=d.exp,
                             ok=(nd == 0 and e == d.exp))
        except (LayerError, KeyError) as e:
            layer_out = dict(n=0, ndiff=-1, exp=None, ref_exp=None, ok=False,
                             why=str(e))
    return results, t_layer, anchored_from_ref, reanchors, live, layer_out


def _moved(text):
    for line in text.splitlines():
        if "<-- MOVED" in line:
            return True
    return False


def _sx16(v):
    v &= 0xFFFFFFFFFFFFFFFF
    return v - (1 << 64) if v >> 63 else v


def _read_back_mantissas(meter, regs, n_rows):
    """Reconstruct the Y values fk33_run_job read, from the meter's log.

    NOT a second readback: re-reading Y_LO/Y_HI here would be a second pass
    over the register file and could not be told apart from the first if the
    two disagreed."""
    lo = meter.reads_of(regs["FK33_ENG_Y_LO"])
    hi = meter.reads_of(regs["FK33_ENG_Y_HI"])
    out = []
    for i in range(min(n_rows, len(lo), len(hi))):
        out.append((hi[i] << 32) | lo[i])
    while len(out) < n_rows:
        out.append(None)
    return out


class _Sink(object):
    def __init__(self):
        self.buf = []

    def write(self, s):
        self.buf.append(s)

    @property
    def text(self):
        return "".join(self.buf)


def _build(a):
    b = dict(G.FK33)
    b["addr_w"] = a.addr_w
    return b


# =================================================================== reports
def print_plan(plan, notes, out=None):
    out = out or sys.stdout
    w = out.write
    w("layer       %d of %d, %s block\n"
      % (plan["layer"], plan["shape"].blocks,
         "attention" if plan["is_attn"] else "Gated DeltaNet"))
    w("program     %d steps in the layer, %d of them subsystem-A jobs\n"
      % (len(plan["sel"]), len(plan["jobs"])))
    w("arena       0x%X, %d slots of %d bytes, from tools/hbm_map.py\n"
      % (plan["arena_base"], plan["n_slots"], plan["stride"]))
    w("\n  %-3s %-26s %-8s %-7s %-14s %-14s %5s %6s\n"
      % ("#", "tensor", "rows", "cols", "reads", "writes", "row0", "ns"))
    for j, src, dst, ns in notes:
        w("  %-3d %-26s %-8d %-7d %-14s %-14s %5d %6d\n"
          % (j.idx, j.short, j.n_rows, j.n_cols, j.src_seam, j.dst_seam,
             j.row_start, ns))
    tot = sum(((j.n_rows + 47) // 48) * (j.K // 32) for j in plan["jobs"])
    w("\ncompute     %d weight beats over the layer; at the MEASURED 21.6 core "
      "cycles per beat\n            that is %.1f ms at 200 MHz -- a LOWER "
      "BOUND, matvecs only\n" % (tot, tot * 21.6 / 200e3))


def print_timing(results, out=None, simulated=False):
    """The per-job PCIe cost, decomposed.  This is the number the project does
    not have: the only figure ever published was withdrawn because it was
    per-invocation setup rather than PCIe."""
    out = out or sys.stdout
    w = out.write
    w("\nPCIe cost per job, MEASURED by counting and timing every MMIO access:\n")
    w("  %-3s %-24s %7s %9s %9s %9s %9s\n"
      % ("#", "tensor", "wall", "x wr", "poll rd", "Y rd", "other"))
    tot = dict(wall=0.0, x=0.0, poll=0.0, y=0.0, n_x=0, n_poll=0, n_y=0)
    for r in results:
        b = r["by_off"]
        xd = b.get(_X_DATA, [0, 0.0, 0, 0.0])
        st = b.get(_STATUS, [0, 0.0, 0, 0.0])
        yl = b.get(_Y_LO, [0, 0.0, 0, 0.0])
        yh = b.get(_Y_HI, [0, 0.0, 0, 0.0])
        yi = b.get(_Y_IDX, [0, 0.0, 0, 0.0])
        x_s, p_s = xd[3], st[1]
        y_s = yl[1] + yh[1] + yi[3]
        other = r["rd_s"] + r["wr_s"] - x_s - p_s - y_s
        w("  %-3d %-24s %6.3fs %8.3fs %8.3fs %8.3fs %8.3fs\n"
          % (r["job"].idx, r["job"].short, r["wall"], x_s, p_s, y_s, other))
        tot["wall"] += r["wall"]
        tot["x"] += x_s
        tot["poll"] += p_s
        tot["y"] += y_s
        tot["n_x"] += xd[2]
        tot["n_poll"] += st[0]
        tot["n_y"] += yl[0] + yh[0]
    w("  %-3s %-24s %6.3fs %8.3fs %8.3fs %8.3fs\n"
      % ("", "TOTAL", tot["wall"], tot["x"], tot["poll"], tot["y"]))
    if tot["n_x"]:
        w("  activation writes  %d MMIO writes, %.2f us each\n"
          % (tot["n_x"], tot["x"] / tot["n_x"] * 1e6))
    if tot["n_poll"]:
        w("  status polls       %d MMIO reads,  %.2f us each\n"
          % (tot["n_poll"], tot["poll"] / tot["n_poll"] * 1e6))
    if tot["n_y"]:
        w("  result readback    %d MMIO reads,  %.2f us each\n"
          % (tot["n_y"], tot["y"] / tot["n_y"] * 1e6))
    w("  An MMIO access is a full PCIe round trip on a read and a posted write\n"
      "  on a write; the two costs are NOT the same and are reported apart.\n")
    if simulated:
        w("  THESE ARE NOT PCIe NUMBERS.  Under --dry-run the transport is a\n"
          "  Python object, so every figure above is the cost of a Python call\n"
          "  and the COUNTS are the only part that carries over.  What carries\n"
          "  over is that one layer costs %d activation writes and %d result\n"
          "  reads, and that both scale with the shape rather than with the\n"
          "  arithmetic.\n" % (tot["n_x"], tot["n_y"]))
    else:
        w("  Setup is amortised: the oracle is compiled once, the manifest is\n"
          "  parsed once and the device is opened once, so what is left IS the\n"
          "  PCIe cost.  The ~150 ms per job published on 2026-08-29 was the\n"
          "  setup and was withdrawn.\n")


_X_DATA = _STATUS = _Y_LO = _Y_HI = _Y_IDX = None


def _bind_offsets(regs):
    global _X_DATA, _STATUS, _Y_LO, _Y_HI, _Y_IDX
    _X_DATA = regs["FK33_ENGX_X_DATA"]
    _STATUS = regs["FK33_ENG_STATUS"]
    _Y_LO = regs["FK33_ENG_Y_LO"]
    _Y_HI = regs["FK33_ENG_Y_HI"]
    _Y_IDX = regs["FK33_ENG_Y_IDX"]



# ==================================================================== teeth
# One command, one table, so the claim "these checks bite" is reproducible
# rather than a shell loop somebody once ran.  Every row states the verdict it
# MUST produce; a row that does not bite is printed under its own name.
TEETH_ROWS = [
    ("control (clean)",                None,          J.Verdict.PASS),
    ("one wrong mantissa in job 3",    "bad-row:3",   J.Verdict.FAIL),
    ("wrong y_exp in job 7",           "wrong-exp:7", J.Verdict.FAIL),
    ("job 4 reports job 3's counters", "stale:4",     J.Verdict.INCONCLUSIVE),
    ("a thermal trip during job 2",    "trip:2",      J.Verdict.INCONCLUSIVE),
    ("compute_halt high at job 0",     "halt:0",      J.Verdict.FAIL),
]


HOST_MUTANTS = {
    # ref/run9b.c's own mutant 7: the eps outside the sqrt.
    "norm-eps-outside": lambda: _swap("host_rmsnorm", lambda x, w: [
        x[i] * (1.0 / (math.sqrt(sum(t * t for t in x) / len(x)) + RMS_EPS))
        * w[i] for i in range(len(x))]),
    # silu applied to the WRONG operand of the SwiGLU.
    "swiglu-swapped": lambda: _swap("host_silu_mul", lambda g, u: [
        (u[i] / (1.0 + math.exp(-u[i]))) * g[i] for i in range(len(g))]),
    # amax into bit 15 instead of bit 14.  A one-character transcription error
    # of ref/run9b.c:323, and the most plausible way to get reg_put wrong.
    "repack-bit15": lambda: _swap("reg_put", _reg_put_bit15),
}

# MEASURED AND WITHDRAWN, recorded rather than deleted.  A fourth mutant here
# modelled the SHIPPING RTL's clamped repack rule as `if exp < 0: exp = 0` and
# it did NOT bite on layer 0 -- correctly, because that clamp fires only when
# amax >= 2^15 and this layer's seams peak near 73.  The model was also wrong:
# the shipping rule is `sh = max(0, msb_pos(amax) - 14)` on an INT Q-grid, i.e.
# "never shift LEFT", and ref/run9b.c's reg_put takes a float with no Q-grid,
# so it has no analogue at all.  The real disagreement between the two rules is
# the open worklog issue 'BFP repack rule' (MEASURED elsewhere at 341 of 760
# exponents differing on quiet blocks) and THIS TABLE CANNOT MEASURE IT.  It
# does not reach this tool either, because the host and the reference are on
# the same rule and no clamped unit is on the card -- but it will reach
# subsystem D's vector ops the day they run on silicon.


def _reg_put_bit15(v):
    amax = max((abs(x) for x in v), default=0.0)
    if amax == 0.0:
        return [0] * len(v), 0
    e = int(math.floor(math.log2(amax)))
    exp = 15 - e
    m = [sat16(math.floor(math.ldexp(x, exp) + 0.5)) for x in v]
    return m, exp


def _swap(name, fn):
    g = globals()
    old = g[name]
    g[name] = fn
    return lambda: g.__setitem__(name, old)


def _mk_plan_for(a):
    return make_layer(a)


def cmd_teeth(a):
    """Run the dry run once per injected fault and require the stated verdict.

    THE CONTROL ROW IS NOT EVIDENCE ABOUT ANY FPGA.  The simulated card replays
    the reference, so its PASS is a statement about this tool's sequencing.
    The rows that matter are the other five."""
    import io
    base = argparse.Namespace(**vars(a))
    base.mode, base.dry_run, base.timeout = "chained", True, 5.0
    base.show, base.stop_on_fail = 4, False
    print("%-34s %-14s %-14s %s" % ("mutation", "want", "got", "verdict"))
    print("-" * 84)
    nbad, notbiting = 0, []

    # THE HOST STEPS FIRST, because every chained result rests on them.  Each
    # mutant must make `hoststeps` FAIL; if it does not, chaining is resting on
    # a check that cannot see the thing it exists to see.
    for name, mk in sorted(HOST_MUTANTS.items()):
        undo = mk()
        try:
            buf, old = io.StringIO(), sys.stdout
            sys.stdout = buf
            try:
                rows, ok = check_host_steps(_mk_plan_for(a), read_r9bs(a.ref),
                                            a.tok, a.packed)
            finally:
                sys.stdout = old
        finally:
            undo()
        got = "PASS" if ok else "FAIL"
        good = got == "FAIL"
        if not good:
            nbad += 1
            notbiting.append(("host: " + name,
                              "hoststeps still PASSes with it applied"))
        print("%-34s %-14s %-14s %s"
              % ("host step: " + name, "FAIL", got, "ok" if good else "MISMATCH"))
    for name, inj, want in TEETH_ROWS:
        ns = argparse.Namespace(**vars(base))
        ns.inject = [inj] if inj else []
        buf, old = io.StringIO(), sys.stdout
        sys.stdout = buf
        try:
            rc = cmd_run(ns)
        finally:
            sys.stdout = old
        got = "?"
        for line in buf.getvalue().splitlines():
            if line.startswith("VERDICT"):
                got = line.split()[1]
        ok = got == want
        if not ok:
            nbad += 1
            notbiting.append((name, "wanted %s, got %s" % (want, got)))
        print("%-34s %-14s %-14s %s" % (name, want, got,
                                        "ok" if ok else "MISMATCH"))
    print("\nROWS THAT DO NOT BITE -- the resolution floor of this checking:")
    if not notbiting:
        print("  (none among the rows above)")
    for n, why in notbiting:
        print("  %-30s %s" % (n, why))
    print("""
  Two holes this table CANNOT close, stated rather than left to be inferred:
  * `stale` is caught through BEATS, so it is BLIND when the stale completion
    belongs to a job of the SAME shape.  In a 9B layer ffn_gate and ffn_up are
    exactly that pair.
  * Every row runs against a model that replays the reference.  None of them
    is evidence that any FPGA computes anything.""")
    print("\nteeth       %s" % ("PASS" if nbad == 0 else "FAIL"))
    return 0 if nbad == 0 else 1


# ==================================================================== main
def _scratch(a):
    d = a.scratch or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                  "fk33_run_layer")
    os.makedirs(d, exist_ok=True)
    return d


def cmd_plan(a):
    regs = J.load_regs()
    _bind_offsets(regs)
    plan = make_layer(a)
    ref = read_r9bs(a.ref)
    notes = bind_reference(plan, ref, a.tok)
    print_plan(plan, notes)

    rows, wall = host_rerun(plan, ref, a.tok, _scratch(a), a.cc)
    print("\nhost re-run of every job through ref/matvec_int4.c, from the "
          "reference's\nown source seam (%.2f s).  This EXCLUDES THE HOST; it "
          "is not an independent\noracle for the arithmetic -- see "
          "hw/fk33/host/mv4i_job_oracle.c.\n" % wall)
    print("  %-3s %-26s %8s %8s %6s %s"
          % ("#", "tensor", "mant!=", "y_exp", "ns", "verdict"))
    nbad = 0
    for r in rows:
        ok = r["ndiff"] == 0 and r["exp_ok"]
        nbad += 0 if ok else 1
        print("  %-3d %-26s %8d %8s %6d %s"
              % (r["job"].idx, r["job"].short, r["ndiff"],
                 "ok" if r["exp_ok"] else "DIFFERS", r["ns"],
                 "ok" if ok else "MISMATCH at element %d" % r["first"]))
    print("  coverage    %d of %d jobs re-run and compared, %d differ"
          % (len(rows), len(plan["jobs"]), nbad))

    hrows, hok = check_host_steps(plan, ref, a.tok, a.packed)
    print("\nplan        %s" % ("consistent -- every job's seam pairing and "
                                "every host step reproduces the reference"
                                if nbad == 0 and hok else "INCONSISTENT"))
    return 0 if (nbad == 0 and hok) else 1


def cmd_hoststeps(a):
    plan = make_layer(a)
    ref = read_r9bs(a.ref)
    rows, ok = check_host_steps(plan, ref, a.tok, a.packed)
    print("\nhoststeps   %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def cmd_run(a):
    regs = J.load_regs()
    _bind_offsets(regs)
    scratch = _scratch(a)
    plan = make_layer(a)
    ref = read_r9bs(a.ref)
    notes = bind_reference(plan, ref, a.tok)
    print_plan(plan, notes)

    if a.mode == "chained":
        hrows, hok = check_host_steps(plan, ref, a.tok, a.packed)
        if not hok:
            print("\nREFUSING --mode chained: the host non-matvec steps do not "
                  "reproduce the reference, so any chained divergence would be "
                  "unattributable.", file=sys.stderr)
            return 2

    if a.dry_run:
        bar_i = _DryBar(regs, plan, ref, a.tok, a.inject)
        hbm_i = J.FileHbm(os.path.join(scratch, "hbm.bin"),
                          regs["FK33_HBM_TOP"])
        print("\ntransport   SIMULATED.  Nothing under /dev is opened, and the "
              "model REPLAYS the reference.")
    else:
        bar_i = J.DevBar(os.environ.get("FK33_USER", "/dev/xdma0_user"))
        hbm_i = J.DevHbm(os.environ.get("FK33_H2C", "/dev/xdma0_h2c_0"),
                         os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0"),
                         regs["FK33_HBM_TOP"])
        print("\ntransport   %s + %s/%s"
              % (os.environ.get("FK33_USER", "/dev/xdma0_user"),
                 os.environ.get("FK33_H2C", "/dev/xdma0_h2c_0"),
                 os.environ.get("FK33_C2H", "/dev/xdma0_c2h_0")))
    bar = Meter(bar_i, "bar")
    hbm = Meter(hbm_i, "hbm")

    print("\nmode        %s\n" % (
        "ANCHORED -- every job's x comes from the reference; a divergence is "
        "attributable\n            to that job and nothing propagates"
        if a.mode == "anchored" else
        "CHAINED -- only the layer input comes from the reference; every other "
        "x is\n            derived on the host from the CARD's own outputs"))
    try:
        results, t_layer, anch, reanch, live, layer_out = run_layer(
            a, plan, ref, a.tok, regs, bar, hbm)
    finally:
        bar.close()
        hbm.close()

    print_timing(results, simulated=a.dry_run)

    npass = sum(1 for r in results if r["verdict"] == J.Verdict.PASS)
    ninc = sum(1 for r in results if r["verdict"] == J.Verdict.INCONCLUSIVE)
    nfail = len(results) - npass - ninc
    rows_cmp = sum(r["job"].n_rows for r in results)
    print("\nresult      %d of %d jobs run; %d PASS, %d FAIL/REFUSED, "
          "%d INCONCLUSIVE" % (len(results), len(plan["jobs"]), npass,
                               nfail, ninc))
    print("            %d result rows compared against ref/run9b's stream, "
          "element for element" % rows_cmp)
    print("            layer wall %.3f s" % t_layer)
    print("            anchored from the reference: %s" % ", ".join(anch))
    if reanch:
        print("            RE-ANCHORED (the chain was broken here):")
        for name, why in reanch:
            print("              %-16s %s" % (name, why))
    if layer_out is not None:
        if layer_out["ndiff"] < 0:
            print("            LAYER OUTPUT could not be formed: %s"
                  % layer_out.get("why", "?"))
        else:
            print("            LAYER OUTPUT R_X-%d: %d of %d mantissas differ "
                  "from ref/run9b, exp %s vs %s"
                  % (plan["layer"], layer_out["ndiff"], layer_out["n"],
                     layer_out["exp"], layer_out["ref_exp"]))

    if len(results) != len(plan["jobs"]):
        verdict = J.Verdict.INCONCLUSIVE
        why = ("the run stopped after %d of %d jobs; a verdict over a partial "
               "layer is not a verdict" % (len(results), len(plan["jobs"])))
    elif ninc:
        verdict = J.Verdict.INCONCLUSIVE
        why = "%d job(s) were inconclusive; see their detail lines" % ninc
    elif nfail:
        verdict = J.Verdict.FAIL
        why = "%d job(s) did not reproduce ref/run9b's seam" % nfail
    elif layer_out is not None and not layer_out["ok"]:
        # EVERY JOB GREEN AND THE COMPOSITION WRONG is exactly the outcome this
        # tool exists to be able to report, so it is a FAIL and not a footnote.
        verdict = J.Verdict.FAIL
        why = ("every job matched and the LAYER OUTPUT did not: %d of %d "
               "mantissas differ at R_X-%d"
               % (layer_out["ndiff"], layer_out["n"], plan["layer"]))
    else:
        verdict = J.Verdict.PASS
        why = ("every one of the %d matvecs in layer %d reproduced "
               "ref/run9b's seam bit-exactly, in program order, on one open "
               "device" % (len(results), plan["layer"]))

    print("\nVERDICT     %s -- %s" % (verdict, why))
    print("SCOPE       subsystem A only.  The two RMS norms, the residual "
          "adds, the SwiGLU\n            and the whole %s block ran on the "
          "HOST; B, C and D are not on this\n            silicon."
          % ("attention" if plan["is_attn"] else "Gated DeltaNet"))
    if a.dry_run:
        print("            DRY RUN.  This is a statement about this tool, not "
              "about any FPGA.")
    return {J.Verdict.PASS: 0, J.Verdict.FAIL: 1,
            J.Verdict.INCONCLUSIVE: 3, J.Verdict.REFUSED: 2}[verdict]


# ================================================================ selfcheck
def _synth_ref(path, layer, jobs_seams):
    """A synthetic .r9bs carrying exactly the seams one layer needs, with
    values chosen so every relation the checks test actually holds."""
    recs = []
    for name, n, exp in jobs_seams:
        mant = [((i * 37 + len(name) * 11) % 4001) - 2000 for i in range(n)]
        recs.append((name, 0, layer, KIND_BFP16, exp, mant))
    with open(path, "wb") as fp:
        fp.write(R9BS_MAGIC + struct.pack("<I", 1))
        for name, tok, lay, kind, exp, mant in recs:
            nb = name.encode()
            fp.write(_HDR.pack(len(nb), len(mant), tok, lay, kind, exp))
            fp.write(nb)
            fp.write(struct.pack("<%dh" % len(mant), *mant))
    return path


def cmd_selfcheck(a):
    """Prove the checks can FAIL.  No card, no model, nothing under /dev.

    Rows that do NOT bite are printed under their own names, because they
    measure the resolution floor of the checking and are the most valuable
    lines in the table.  Never discard one."""
    scratch = _scratch(a)
    ok_all = True
    print("scratch     %s" % scratch)

    # ---- 1. the r9bs reader, against tools/ref9b/r9bs.py where it is available
    print("\nr9bs reader, checked against tools/ref9b/r9bs.py record for record:")
    ref_path = a.ref
    if ref_path and os.path.exists(ref_path):
        mine = read_r9bs(ref_path)
        try:
            sys.path.insert(0, os.path.join(REPO, "tools", "ref9b"))
            import r9bs as R
            theirs = R.index(ref_path)
            nb = 0
            for k, v in theirs.items():
                m = mine.get(k)
                if m is None or m.exp != v.exp or m.kind != v.kind \
                        or list(v.raw) != m.mant:
                    nb += 1
            print("  %d records, %d disagree  -- %s"
                  % (len(theirs), nb, "ok" if nb == 0 else "MISMATCH"))
            ok_all = ok_all and nb == 0
        except ImportError as e:
            print("  tools/ref9b/r9bs.py not importable (%s); the two readers "
                  "were NOT cross-checked, and that is a hole, not a pass" % e)
    else:
        print("  no --ref given, so the two readers were NOT cross-checked.  "
              "That is a hole in this run, not a pass.")

    # ---- 2. the host arithmetic, against values computed a second way
    print("\nhost arithmetic, teeth:")
    rows = []

    def row(name, got, want):
        ok = got == want
        rows.append((name, "%r" % (got,), "%r" % (want,), ok))
        return ok

    row("reg_put of all zeros", reg_put([0.0, 0.0, 0.0]), ([0, 0, 0], 0))
    row("reg_put puts amax in bit 14", reg_put([1.0])[1], 14)
    row("reg_put exp of 3.0", reg_put([3.0])[1], 13)
    # SATURATION IS REACHABLE AND IT IS A CORNER, NOT A THEORETICAL ONE.  The
    # scaled amax lands in [16384, 32768); a value just under 2^(e+1) rounds up
    # to exactly 32768 and sat16 clamps it.  Getting this wrong -- believing
    # reg_put can never saturate because amax is the maximum -- would remove
    # the only clamp on the path.  The mirrored negative does NOT saturate,
    # because -32768 is representable, and that asymmetry is the row below.
    row("reg_put saturates the top value", reg_put([2.0 - 1e-9])[0][0], 32767)
    row("the mirrored negative does not", reg_put([-(2.0 - 1e-9)])[0][0], -32768)
    row("sat16 clamps high", sat16(99999), 32767)
    row("sat16 clamps low", sat16(-99999), -32768)
    # rmsnorm with unit weights on a constant vector: every element becomes
    # x / sqrt(x^2 + eps), which is ~1 for x = 1.
    v = host_rmsnorm([1.0] * 8, [1.0] * 8)
    row("rmsnorm of a constant vector", round(v[0], 9),
        round(1.0 / math.sqrt(1.0 + RMS_EPS), 9))
    row("silu(0) * u = 0", host_silu_mul([0.0], [5.0]), [0.0])
    row("add", host_add([1.5, -2.0], [0.5, 2.0]), [2.0, 0.0])
    # THE MUTATION THAT MATTERS: eps outside the sqrt is ref/run9b.c's own
    # mutant 7, and it must produce a DIFFERENT number here.
    bad = 1.0 / (math.sqrt(1.0) + RMS_EPS)
    rows.append(("eps outside sqrt differs (mutant 7)",
                 "%.12f" % bad, "%.12f" % v[0], bad != v[0]))

    for name, got, want, ok in rows:
        print("  %-38s %-24s %-24s %s"
              % (name, got, want, "ok" if ok else "MISMATCH"))
        ok_all = ok_all and ok

    # ---- 3. the seam-pairing checks, on a synthetic stream
    print("\nseam-pairing checks, on a synthetic stream (no model, no card):")
    class _J:
        pass
    j = _J()
    j.idx, j.n_rows, j.n_cols = 0, 4, 8
    j.w_exp, j.out_shift = 8, 3
    j.src_seam, j.dst_seam = "S-0", "D-0"
    plan = dict(jobs=[j], layer=0)

    def mk(nsrc, ndst, sexp, dexp):
        p = os.path.join(scratch, "sc.r9bs")
        _synth_ref(p, 0, [("S-0", nsrc, sexp), ("D-0", ndst, dexp)])
        return read_r9bs(p)

    def try_bind(ref):
        try:
            bind_reference(plan, ref, 0)
            return "accepted"
        except LayerError:
            return "refused"

    tt = [
        ("control: shapes and ns agree", mk(8, 4, 10, 12), "accepted"),
        ("source seam the wrong length", mk(9, 4, 10, 12), "refused"),
        ("destination the wrong length", mk(8, 5, 10, 12), "refused"),
        ("exponents imply ns < 0",       mk(8, 4, 10, 20), "refused"),
        ("ns exactly 0 (boundary)",      mk(8, 4, 10, 15), "accepted"),
    ]
    for name, ref, want in tt:
        got = try_bind(ref)
        print("  %-38s %-12s %-12s %s"
              % (name, want, got, "ok" if got == want else "MISMATCH"))
        ok_all = ok_all and got == want

    # a seam the stream does not carry at all
    p = os.path.join(scratch, "sc_missing.r9bs")
    _synth_ref(p, 0, [("S-0", 8, 10)])
    try:
        bind_reference(plan, read_r9bs(p), 0)
        got = "accepted"
    except LayerError:
        got = "refused"
    print("  %-38s %-12s %-12s %s"
          % ("destination seam absent entirely", "refused", got,
             "ok" if got == "refused" else "MISMATCH"))
    ok_all = ok_all and got == "refused"

    # ---- 4. the stale-done check
    print("\nthe stale-`done` check (the hazard a single-job tool cannot meet):")
    regs = J.load_regs()
    _bind_offsets(regs)

    class _FakeMeter(object):
        def __init__(self, beats, cycles):
            self.b, self.c = beats, cycles

        def last_read(self, off, default=None):
            if off == regs["FK33_ENG_BEATS"]:
                return self.b
            if off == regs["FK33_ENG_CYCLES"]:
                return self.c
            return default

        def first_status_after_go(self, *_):
            return None

    jj = _J()
    jj.n_rows, jj.K = 96, 4096                      # tiles=2, nblk=128 -> 256
    for name, beats, want in (("BEATS is this job's", 256, True),
                              ("BEATS is a previous job's", 5504, False),
                              ("BEATS is zero", 0, False)):
        got = stale_done_check(_FakeMeter(beats, 1), regs, jj)[0]
        print("  %-38s %-12s %-12s %s"
              % (name, want, got, "ok" if got == want else "MISMATCH"))
        ok_all = ok_all and got == want

    print("""
ROWS THAT DO NOT BITE -- the resolution floor of this checking:
  * The seam-pairing checks are SHAPE and EXPONENT checks.  Two seams of the
    same length whose exponents happen to admit a non-negative ns are accepted
    by all three, and only `plan`'s host re-run through ref/matvec_int4.c can
    tell them apart.  That is why `plan` runs it and why `run` prints the
    result of it.
  * stale_done_check cannot see a stale completion whose BEATS happens to equal
    this job's -- two consecutive jobs of the same shape.  In a 9B layer
    ffn_gate and ffn_up are exactly that pair, so the check is BLIND on one
    adjacency out of ten.  The CYCLES value is printed alongside for a reader,
    but it is not asserted on because this tool has not verified that counter's
    semantics against the RTL.
  * Nothing here proves any FPGA computes anything.  Every row above is
    DERIVED; the only MEASURED statement about the card comes from `run`
    without --dry-run.""")
    print("\nselfcheck   %s" % ("PASS" if ok_all else "FAIL"))
    return 0 if ok_all else 1


class _DryBar(object):
    """A simulated register plane for --dry-run that REPLAYS the reference.

    A dry-run PASS is a statement about this tool's sequencing and its checks.
    It says NOTHING about the card: the numbers never went near an engine.  It
    also deliberately models the SEQUENCE, which fk33_run_job.SimBar does not
    need to -- BEATS is answered per job from the descriptor the tool wrote, so
    the stale-`done` check has something to be right or wrong about."""

    # --inject NAME:JOB.  These are TEETH: a dry run whose model always agrees
    # with the reference cannot show that any check works, and a checker never
    # shown to fail has not been shown to work.
    INJECT = ("bad-row", "stale", "trip", "halt", "wrong-exp")

    def __init__(self, regs, plan, ref, tok, inject=None):
        self.regs, self.plan, self.ref, self.tok = regs, plan, ref, tok
        self.sim = J.SimBar(regs, {}, {})
        self.byslot = {j.desc_addr: j for j in plan["jobs"]}
        self.cur = None
        self.prev = None
        self.inject = {}
        for spec in (inject or []):
            name, _, which = spec.partition(":")
            if name not in self.INJECT:
                raise LayerError("unknown --inject %r; known: %s"
                                 % (name, ", ".join(self.INJECT)))
            self.inject.setdefault(int(which or 0), []).append(name)

    def _beats(self, j):
        return ((j.n_rows + 47) // 48) * (j.K // 32)

    def rd(self, off):
        r = self.regs
        if self.cur is not None:
            faults = self.inject.get(self.cur.idx, ())
            src = self.cur
            if "stale" in faults and self.prev is not None:
                src = self.prev          # the PREVIOUS job's counters
            if off == r["FK33_ENG_BEATS"]:
                return self._beats(src)
            if off == r["FK33_ENG_CYCLES"]:
                return int(self._beats(src) * 21.6)
        return self.sim.rd(off)

    def wr(self, off, val):
        r = self.regs
        self.sim.wr(off, val)
        # ON THE HI WRITE, NOT THE LO.  The arena sits at 0x1FFADD000, which is
        # 33 bits, so a pointer is only complete after both halves -- keying on
        # the LO write looked up 0xFFADD000, found nothing, and the first job
        # of the dry run failed with every mantissa wrong.  Found by running
        # the dry run, which is exactly what it is for.
        if off == r["FK33_ENG_DESC_PTR_HI"]:
            nxt = self.byslot.get(self.sim.dptr)
            if nxt is not None:
                self.prev, self.cur = self.cur, nxt
                d = self.ref[(self.cur.dst_seam, self.tok)]
                self.sim.o = dict(
                    ymant={i: d.mant[i] & 0xFFFFFFFFFFFFFFFF
                           for i in range(self.cur.n_rows)},
                    y_exp=d.exp, w_beats=self._beats(self.cur))
                faults = self.inject.get(self.cur.idx, ())
                f = {}
                if "bad-row" in faults:
                    f["bad_row"] = 0
                if "wrong-exp" in faults:
                    f["y_exp"] = (d.exp + 1) & 0xFFFFFFFF
                if "trip" in faults:
                    f["trip_during"] = 1
                if "halt" in faults:
                    f["halt"] = 1
                self.sim.f = f
                # The trip counter is CUMULATIVE and is deliberately not reset
                # between jobs: fk33_run_job reads it before and after each
                # one, so a model that zeroed it would make the job AFTER an
                # injected trip look like a second trip going backwards.  That
                # is a model artefact and it appeared in the first teeth run.
                self.sim.started = False

    def close(self):
        self.sim.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def layer_args(s):
        s.add_argument("--layer", type=int, default=0)
        s.add_argument("--tok", type=int, default=0,
                       help="token index inside the reference stream")
        s.add_argument("--ref", required=True, help="the .r9bs reference")
        s.add_argument("--manifest", default=DEFAULT_MANIFEST,
                       help="the manifest of the set RESIDENT ON THE CARD")
        s.add_argument("--packed", default=os.path.dirname(DEFAULT_MANIFEST),
                       help="the packed dir holding index.txt and the f32 blob")
        s.add_argument("--ref-manifest", default=None, dest="ref_manifest",
                       help="the manifest ref/run9b was run against.  When "
                            "given, every tensor this layer touches must hash "
                            "the same in it and in --manifest, so the "
                            "reference is known to describe the bytes the card "
                            "holds.  Omitting it leaves that unchecked.")
        s.add_argument("--addr-w", type=int, default=40, dest="addr_w")
        s.add_argument("--scratch", default=None)
        s.add_argument("--cc", default="cc")

    s = sub.add_parser("plan", help="build, cross-check and re-run on the "
                                    "host; no card, no /dev")
    layer_args(s)
    s.set_defaults(fn=cmd_plan)

    s = sub.add_parser("hoststeps",
                       help="check the host non-matvec steps against the "
                            "reference; no card, no /dev")
    layer_args(s)
    s.set_defaults(fn=cmd_hoststeps)

    s = sub.add_parser("run", help="run the layer (see --dry-run)")
    layer_args(s)
    s.add_argument("--mode", choices=("anchored", "chained"),
                   default="anchored")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--timeout", type=float, default=30.0)
    s.add_argument("--show", type=int, default=8)
    s.add_argument("--stop-on-fail", action="store_true")
    s.add_argument("--inject", action="append", default=[],
                   help="--dry-run only.  NAME:JOB, e.g. bad-row:3, stale:4, "
                        "trip:2, halt:0, wrong-exp:7.  These are the TEETH: a "
                        "model that always agrees with the reference cannot "
                        "show that any check works.")
    s.set_defaults(fn=cmd_run)

    s = sub.add_parser("teeth",
                       help="run the dry run once per injected fault and "
                            "require the stated verdict; no card, no /dev")
    layer_args(s)
    s.set_defaults(fn=cmd_teeth)

    s = sub.add_parser("selfcheck",
                       help="prove the checks can fail; no card, no model")
    s.add_argument("--scratch", default=None)
    s.add_argument("--cc", default="cc")
    s.add_argument("--ref", default=None)
    s.add_argument("--manifest", default=DEFAULT_MANIFEST)
    s.add_argument("--packed", default=os.path.dirname(DEFAULT_MANIFEST))
    s.add_argument("--layer", type=int, default=0)
    s.add_argument("--tok", type=int, default=0)
    s.add_argument("--addr-w", type=int, default=40, dest="addr_w")
    s.set_defaults(fn=cmd_selfcheck)

    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except (LayerError, J.RunError) as e:
        print("fk33_run_layer: " + str(e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
