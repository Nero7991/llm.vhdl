#!/usr/bin/env python3
"""tools/gen_layer_program.py -- emit subsystem D's descriptor PROGRAM for one
transformer layer, and subsystem A's per-job descriptors for the matvecs in it.

Worklog backlog item 6.  `tools/gen_mv4i_desc.py` emits ONE matvec job; nothing
emitted a LAYER.  A layer needs job SEQUENCING, REGION ROUTING and the D header
fields subsystem A reads none of.

============================================================================
THE TWO MEMORY OBJECTS, AND WHY THEY ARE NOT ONE
============================================================================
`docs/2026-08-28_matvec-descriptor-format.md` section 2 says A's descriptor is
D's 64-byte header plus a base array at 0x40 plus a four-word extension, and
that "a descriptor written to this specification is accepted by
`seq_desc_fetch` unchanged".  That is true of ONE descriptor read in isolation
and it is FALSE of a TABLE, which is what D walks:

    rtl/seq_desc_fetch.vhd:574   d_raddr <= fetch_idx & "000" + f_beat

so step i's header is at 64-bit word 8*i.  D's table is DENSE at a 64-byte
stride, and step i+1's header occupies exactly the bytes where step i's base
array would have to live.  The two cannot be the same block of memory.

This tool therefore emits TWO things:

  * `d_table.hex`   the D step table.  8 words per step, dense, in the form
                    the URAM model in `sim/tb_llama_top.vhd:705` reads
                    (one 64-bit word per line, hex, index order).
  * `a<NN>_<tensor>.hex`  one 312-byte / 39-word subsystem A descriptor per
                    A_JOB step, at the FK33 geometry, in the form
                    `sim/tb_mv4i_desc_image.vhd` reads.

WHAT NOTHING SUPPLIES: the pointer from a D step to its A descriptor.  D's
header has no field for it, `matvec_int4_desc_axi` takes `DESC_PTR` over
AXI-Lite, and `rtl/llama_top.vhd:1913` synthesises A's bases arithmetically
(`A_MEM_BASE + step*A_JOB_STRIDE`) precisely because the base array is not
fetched.  So the A descriptor ADDRESSES this tool emits are a host-side
allocation (see `--desc-base`), and which mechanism delivers them to the card
is an open integration decision, not a derivation.  Stated, not invented.

============================================================================
WHERE EVERY D HEADER FIELD COMES FROM
============================================================================
  opcode, src_region, dst_region, dst_offset, src_region2, n_rows, n_cols
        DERIVED, from the region map (`rtl/llama_map_pkg.vhd`) and the block
        structure.  These are NOT underivable: they are underivable from the
        MANIFEST, and fully determined by the SCHEDULE, which is this file.
  ordinal
        DERIVED: the PER-KIND layer index, `gdn_ord` on a B_JOB and `attn_ord`
        on a C_JOB, D spec 4.1.  The two VHDL generators DISAGREED about this
        until 2026-08-29 -- `sim/llama_sched_pkg.vhd` stamped the BLOCK index
        on every step, and `rtl/llama_top.vhd` re-derived a layer from it to
        match.  That was defect ORD-1; see
        `docs/debugging/2026-08-29_ordinal-two-meanings.md`.  All three
        generators now agree, and `--stamp sched` follows the fixed VHDL.
  w_exp, out_shift
        For an A_JOB: MANIFEST (`w_exp`, `out_shift` of the packed tensor).
        For a D-vec op: NOTHING SUPPLIES THEM.  `seq_vec_*` publishes its own
        exponents; the fields are read by `seq_desc_fetch` and handed on, and
        no unit in `llama_top` consumes them on a D-vec step.  Written 0 in
        `--stamp manifest`, and that is a finding, not a computation.
  const_base
        DERIVED as the block index (it is the norm-weight selector), but
        NOTHING CONSUMES IT: there is no weight region, no packed norm weight,
        and `llama_top`'s norm uses a fixed-scale stand-in (its NORM_W_EXP
        generic).  So the value is conventional.
  const_exp
        NOT DERIVABLE.  No owner, no consumer, no packing.  Written 0.
  flags
        DERIVED: 0 everywhere except the lm_head steps (FLG_TO_SMP).  Note that
        the format document calls bit 2 `cb_load`, and NEITHER VHDL generator
        ever sets it -- the codebook load is expressed in A's OWN descriptor,
        which is where A reads it.  `--d-cb-load` sets it in the D header too.

============================================================================
THE LM HEAD DOES NOT FIT ONE JOB, AND RAW MODE DOES NOT CHANGE THAT
============================================================================
`output.weight` is 248,320 x 4,096 and `MAXROWS_BFP` is 17,408, so the lm_head
is 15 A jobs, not one.  `rtl/matvec_core.vhd:947` bounds `n_rows` only when
`out_mode = "00"`, and spec 7.6 does say M may exceed `MAXROWS_BFP` in raw --
but NOTHING REACHES `matvec_core` EXCEPT THROUGH THE DESCRIPTOR PLANE, and
`rtl/matvec_int4_desc_axi.vhd:721-726` bounds it in EVERY mode:

    elsif unsigned(lo32(dw(1))) = 0
       or unsigned(lo32(dw(1))) > MAXROWS_BFP        -- no out_mode test

and it must, because `sh_rows` is `integer range 0 to MAXROWS_BFP` (:309).
MEASURED with the RTL as judge (`sim/tb_mv4i_desc_image`): a 248,320-row
descriptor is refused `err_code 0x3 err_info 1` in raw AND in BFP, and each of
the 15 windows is accepted.  So a one-job lm_head is not a schedule choice, it
is an RTL change.

`rel_mask` is not a descriptor field at all.  `rtl/seq_opdec.vhd` finding (3)
says it is a whole-TABLE liveness property with no field in the format, so it
arrives on a port and the host computes it.  This tool computes it, over the
whole token, and slices out the layer -- because "is this the last step that
reads region R" is not answerable from one layer's steps alone.

============================================================================
USAGE
============================================================================
    # the deliverable: one real Qwen3.5-9B layer at the FK33 geometry
    tools/gen_layer_program.py --layer 0 --x-exp 5 --outdir OUT --print

    # the whole token's D table, in the VHDL generators' own field stamping,
    # for byte comparison against them.  --one-lmhead-job is required for that
    # comparison at the 9B vocabulary: both generators encode the lm_head as
    # ONE 248,320-row job, which the gateware REFUSES (see THE LM HEAD below).
    tools/gen_layer_program.py --token --stamp seq_tbl --one-lmhead-job \\
        --d-table OUT/t.hex
    tools/gen_layer_program.py --token --shape sim --blocks 4 --attn-int 4 \\
        --stamp sched --d-table OUT/s.hex --rel-file OUT/s_rel.txt
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_mv4i_desc as G          # noqa: E402  the ONE matvec job, reused
import gen_lmhead_windows as W     # noqa: E402  the ONE window derivation
import hbm_map as HM               # noqa: E402  the ONE HBM address space

# --------------------------------------------------------------- the opcodes
# rtl/llama_map_pkg.vhd, which sim/seq_tbl_pkg.vhd asserts equality with.
OP_A_JOB, OP_B_JOB, OP_C_JOB, OP_E_COLL = 0, 1, 2, 3
OP_VEC_NORM, OP_VEC_RES, OP_VEC_SWG, OP_END_TOKEN = 4, 5, 6, 7
OPNAME = {0: "A_JOB", 1: "B_JOB", 2: "C_JOB", 3: "E_COLL",
          4: "VEC_NORM", 5: "VEC_RES", 6: "VEC_SWG", 7: "END_TOKEN"}

U_A, U_B, U_C, U_E, U_V = 0, 1, 2, 3, 4

FLG_TO_E, FLG_TO_SMP, FLG_CB, FLG_E_NEXT = 1, 2, 4, 8

# --------------------------------------------------------------- the regions
R_X, R_XN, R_QKV, R_Z, R_BETA, R_ALPHA = 0, 1, 2, 3, 4, 5
R_QG, R_KIN, R_VIN, R_Y, R_G, R_U, R_H, R_ER = 6, 7, 8, 9, 10, 11, 12, 13
NREGION = 14
R_NONE = 255
RNAME = ["X", "XN", "QKV", "Z", "BETA", "ALPHA", "QG", "KIN", "VIN",
         "Y", "G", "U", "H", "ER"]

# The per-opcode EXTRA consume mask, `seq_opdec`'s OPC_CONS generic.
# rtl/llama_map_pkg.vhd: (0, 56, 384, 0, 0, 8192, 2048, 0)
OPC_CONS_MAP = (0, 56, 384, 0, 0, 8192, 2048, 0)

NSTEP_GDN_N1, NSTEP_ATTN_N1 = 16, 13


class LayerError(Exception):
    pass


# ============================================================== the shape
class Shape(object):
    """Everything the schedule needs.  The 9B row is `rtl/model_cfg_pkg.vhd`'s
    QWEN35_9B; it is CROSS-CHECKED against the manifest's tensor shapes by
    `check_against_manifest`, which is the only independent source for it that
    exists in this repository."""

    def __init__(self, blocks, attn_interval, hidden, ffn, key_heads,
                 val_heads, head_dim, attn_q_heads, attn_kv_heads,
                 attn_head_dim, vocab_shard):
        self.blocks = blocks
        self.attn_interval = attn_interval
        self.hidden = hidden
        self.ffn = ffn
        self.key_heads = key_heads
        self.val_heads = val_heads
        self.head_dim = head_dim
        self.attn_q_heads = attn_q_heads
        self.attn_kv_heads = attn_kv_heads
        self.attn_head_dim = attn_head_dim
        self.vocab_shard = vocab_shard

    key_dim = property(lambda s: s.key_heads * s.head_dim)
    val_dim = property(lambda s: s.val_heads * s.head_dim)
    qkv_dim = property(lambda s: 2 * s.key_dim + s.val_dim)
    att_q = property(lambda s: s.attn_q_heads * s.attn_head_dim)
    att_qg = property(lambda s: 2 * s.att_q)
    att_kv = property(lambda s: s.attn_kv_heads * s.attn_head_dim)

    def is_attn(self, i):
        return ((i + 1) % self.attn_interval) == 0

    def n_attn(self):
        return self.blocks // self.attn_interval

    def n_gdn(self):
        return self.blocks - self.n_attn()

    def n_steps(self, lm_windows=1):
        """`lm_windows` is the number of A jobs the lm_head is split into.
        It is 1 for every shape whose `vocab_shard` fits one job, which is
        every SCALED shape, and 15 at the 9B vocabulary on the FK33 build --
        see `lmhead_windows` below."""
        return (self.n_gdn() * NSTEP_GDN_N1
                + self.n_attn() * NSTEP_ATTN_N1 + 2 + lm_windows)

    def region_sizes(self):
        r = [0] * NREGION
        r[R_X] = r[R_XN] = r[R_ER] = self.hidden
        r[R_QKV] = self.qkv_dim
        r[R_Z] = self.val_dim
        r[R_BETA] = r[R_ALPHA] = self.val_heads
        r[R_QG] = self.att_qg
        r[R_KIN] = r[R_VIN] = self.att_kv
        r[R_Y] = max(self.val_dim, self.att_q)
        r[R_G] = r[R_U] = r[R_H] = self.ffn
        return r


# rtl/model_cfg_pkg.vhd QWEN35_9B, NCARDS = 1.
QWEN35_9B = Shape(blocks=32, attn_interval=4, hidden=4096, ffn=12288,
                  key_heads=16, val_heads=32, head_dim=128,
                  attn_q_heads=16, attn_kv_heads=4, attn_head_dim=256,
                  vocab_shard=248320)


def mk_shape_scaled(blocks, attn_interval, attn_hd=32):
    """rtl/llama_map_pkg.vhd's `mk_shape_scaled`, so a program emitted here can
    be executed by `llama_top` in simulation.

    REFUSES above attn_hd 32 rather than mirroring the VHDL's third branch.
    The VHDL declares `attn_q_heads`/`attn_kv_heads` as `positive`, so at
    `attn_hd = 64` the shared formula's `32/64 = 0` is a hard elaboration
    error and the language catches it; that is why `llama_map_pkg.vhd` grew an
    explicit 64 branch (4 q heads, 2 kv heads, region widths growing instead).
    Python has no such subtype: without this raise, `--shape sim --attn-hd 64`
    runs, emits the SAME 61 steps and the SAME 488-line d_table.hex line
    count, and silently sizes R_KIN and R_VIN 0 instead of 128 -- so a
    step-count comparison against the VHDL calls that agreement.

    Refusing is deliberately not the same as mirroring. Nothing in the
    repository generates at attn_hd 64 today, the VHDL branch above 32 is a
    DIFFERENT shape from the one every published landmark was measured at, and
    an unverified Python transcription of it would be a second unchecked
    claim. A loud refusal is the honest state: when a caller genuinely needs
    attn_hd > 32, transcribe the VHDL branch and check it against the VHDL,
    then remove this raise."""
    if attn_hd <= 0 or 64 // attn_hd == 0 or 32 // attn_hd == 0:
        raise ValueError(
            "gen_layer_program: mk_shape_scaled has no shape at attn_hd=%r. "
            "64//attn_hd=%d and 32//attn_hd=%d, and a head count of 0 is not "
            "a shape -- the VHDL's `positive` subtype rejects it outright. "
            "rtl/llama_map_pkg.vhd carries a separate attn_hd>32 branch "
            "(4 q heads, 2 kv heads, att_q/att_qg/att_kv growing with the "
            "head dim); it is NOT transcribed here. Use attn_hd 16 or 32, or "
            "transcribe that branch and verify it against the VHDL first."
            % (attn_hd, 64 // attn_hd if attn_hd > 0 else 0,
               32 // attn_hd if attn_hd > 0 else 0))
    return Shape(blocks=blocks, attn_interval=attn_interval,
                 hidden=64, ffn=128, key_heads=2, val_heads=4, head_dim=32,
                 attn_q_heads=64 // attn_hd, attn_kv_heads=32 // attn_hd,
                 attn_head_dim=attn_hd, vocab_shard=128)


# ============================================================== the plan
class Step(object):
    __slots__ = ("opcode", "src", "src2", "dst", "dst_off", "n_rows",
                 "n_cols", "blk", "ordinal", "const_base", "tensor",
                 "row_start", "flags", "out_mode", "w_exp", "out_shift",
                 "rel", "idx", "note")

    def __init__(self, **kw):
        for s in self.__slots__:
            setattr(self, s, kw.get(s, 0))
        self.rel = kw.get("rel", 0)
        self.tensor = kw.get("tensor", None)
        self.note = kw.get("note", "")

    @property
    def unit(self):
        return {OP_A_JOB: U_A, OP_B_JOB: U_B, OP_C_JOB: U_C,
                OP_E_COLL: U_E, OP_END_TOKEN: U_A}.get(self.opcode, U_V)


def lmhead_windows(s, build=None):
    """The lm_head's row windows, as [(row_start, n_rows), ...].

    `output.weight` is `vocab_shard` x `hidden` and the FK33 build's
    `MAXROWS_BFP` is 17,408, so at the 9B vocabulary (248,320) it is not one
    job.  The stride is NOT MAXROWS_BFP: a window can only begin on a tile
    boundary, so it is `floor(MAXROWS_BFP / ROWS_IF) * ROWS_IF` = 17,376.

    THE DERIVATION IS NOT REPEATED HERE.  `tools/gen_lmhead_windows.plan` owns
    it, along with the byte-cover and acceptance checks that go with it; this
    calls it so there is exactly one place for the arithmetic to be wrong.
    For every scaled shape `vocab_shard` is below one stride, `plan` returns a
    single window at row 0, and the step sequence is bit-for-bit what it was
    before this function existed."""
    build = build or G.FK33
    _, wins = W.plan(s.vocab_shard, build["rows_if"], build["maxrows_bfp"])
    return wins


def build_plan(s, tensor_prefix="blk.%d.", qkv_fused=False, lm_windows=None):
    """The step sequence, per block, in order.  Independently written from the
    same D design spec sections 4.2 / 4.3 that `sim/seq_tbl_pkg.vhd` and
    `sim/llama_sched_pkg.vhd` implement; agreement with BOTH of those is the
    check, not the construction.

    `lm_windows` is the lm_head's row-window list; default is the single
    whole-tensor window the two VHDL generators encode, which is CORRECT only
    where `vocab_shard <= floor(MAXROWS_BFP/ROWS_IF)*ROWS_IF`."""
    steps = []
    lmw = list(lm_windows) if lm_windows else [(0, s.vocab_shard)]
    # Checked here rather than trusted, because a window list that does not
    # tile the vocabulary emits a program that is accepted by the gateware and
    # computes a partial argmax -- a silent wrong token, not an error.
    end = 0
    for rs, nr in lmw:
        if rs != end or nr <= 0:
            raise LayerError("lm_head windows do not tile: window at row %d "
                             "with %d rows follows row %d" % (rs, nr, end))
        end = rs + nr
    if end != s.vocab_shard:
        raise LayerError("lm_head windows cover %d rows, vocab_shard is %d"
                         % (end, s.vocab_shard))

    def emit(**kw):
        kw.setdefault("src", R_NONE)
        kw.setdefault("src2", R_NONE)
        kw.setdefault("dst", R_NONE)
        kw.setdefault("const_base", kw.get("blk", 0))
        st = Step(**kw)
        st.idx = len(steps)
        steps.append(st)

    def emit_ffn(b):
        p = tensor_prefix % b
        emit(opcode=OP_VEC_NORM, src=R_X, dst=R_XN, n_rows=s.hidden,
             blk=b, const_base=b, ordinal=b % 64)
        emit(opcode=OP_A_JOB, src=R_XN, dst=R_G, n_rows=s.ffn,
             n_cols=s.hidden, blk=b, tensor=p + "ffn_gate.weight")
        emit(opcode=OP_A_JOB, src=R_XN, dst=R_U, n_rows=s.ffn,
             n_cols=s.hidden, blk=b, tensor=p + "ffn_up.weight")
        emit(opcode=OP_VEC_SWG, src=R_G, src2=R_U, dst=R_H, n_rows=s.ffn,
             blk=b)
        emit(opcode=OP_A_JOB, src=R_H, dst=R_ER, n_rows=s.hidden,
             n_cols=s.ffn, blk=b, tensor=p + "ffn_down.weight")
        emit(opcode=OP_VEC_RES, src=R_X, src2=R_ER, dst=R_X, n_rows=s.hidden,
             blk=b)

    for b in range(s.blocks):
        p = tensor_prefix % b
        if s.is_attn(b):
            ao = (b - (s.attn_interval - 1)) // s.attn_interval
            emit(opcode=OP_VEC_NORM, src=R_X, dst=R_XN, n_rows=s.hidden,
                 blk=b, const_base=b, ordinal=b % 64)
            emit(opcode=OP_A_JOB, src=R_XN, dst=R_QG, n_rows=s.att_qg,
                 n_cols=s.hidden, blk=b, tensor=p + "attn_q.weight")
            emit(opcode=OP_A_JOB, src=R_XN, dst=R_KIN, n_rows=s.att_kv,
                 n_cols=s.hidden, blk=b, tensor=p + "attn_k.weight")
            emit(opcode=OP_A_JOB, src=R_XN, dst=R_VIN, n_rows=s.att_kv,
                 n_cols=s.hidden, blk=b, tensor=p + "attn_v.weight")
            emit(opcode=OP_C_JOB, src=R_QG, dst=R_Y, n_rows=s.att_q,
                 blk=b, ordinal=ao)
            emit(opcode=OP_A_JOB, src=R_Y, dst=R_ER, n_rows=s.hidden,
                 n_cols=s.att_q, blk=b, tensor=p + "attn_output.weight")
            emit(opcode=OP_VEC_RES, src=R_X, src2=R_ER, dst=R_X,
                 n_rows=s.hidden, blk=b)
            emit_ffn(b)
        else:
            go = b - (b + 1) // s.attn_interval
            emit(opcode=OP_VEC_NORM, src=R_X, dst=R_XN, n_rows=s.hidden,
                 blk=b, const_base=b, ordinal=b % 64)
            # THE THREE-WAY qkv SPLIT.  q | k | v at three offsets in ONE
            # region, so each segment gets its own y_exp -- that is what
            # `seq_opdec`'s MSEG mechanism infers from `dst_offset`.  The
            # packed tensor is FUSED (M = 2*key_dim + val_dim), so each of
            # these is a ROW WINDOW of it; see `a_jobs_for` for the geometry
            # constraint that makes two of the three inexpressible at
            # ROWS_IF = 48.
            if qkv_fused:
                # THE FALLBACK, and it is a DIFFERENT PROGRAM, not a repair.
                # One job for the whole fused tensor is expressible at any
                # ROWS_IF, and it costs the three exponent SEGMENTS: seq_opdec
                # infers the segment from `dst_offset`, so a single job at
                # offset 0 gives R_QKV one y_exp for q, k and v together.  It
                # also changes the STEP COUNT, so it is not interchangeable
                # with the split form and `n_steps()` no longer holds.
                emit(opcode=OP_A_JOB, src=R_XN, dst=R_QKV, dst_off=0,
                     n_rows=s.qkv_dim, n_cols=s.hidden, blk=b,
                     tensor=p + "attn_qkv.weight", row_start=0,
                     note="fused qkv: ONE exponent segment, not three")
            else:
                emit(opcode=OP_A_JOB, src=R_XN, dst=R_QKV, dst_off=0,
                     n_rows=s.key_dim, n_cols=s.hidden, blk=b,
                     tensor=p + "attn_qkv.weight", row_start=0)
                emit(opcode=OP_A_JOB, src=R_XN, dst=R_QKV, dst_off=s.key_dim,
                     n_rows=s.key_dim, n_cols=s.hidden, blk=b,
                     tensor=p + "attn_qkv.weight", row_start=s.key_dim)
                emit(opcode=OP_A_JOB, src=R_XN, dst=R_QKV,
                     dst_off=2 * s.key_dim,
                     n_rows=s.val_dim, n_cols=s.hidden, blk=b,
                     tensor=p + "attn_qkv.weight", row_start=2 * s.key_dim)
            emit(opcode=OP_A_JOB, src=R_XN, dst=R_Z, n_rows=s.val_dim,
                 n_cols=s.hidden, blk=b, tensor=p + "attn_gate.weight")
            emit(opcode=OP_A_JOB, src=R_XN, dst=R_BETA, n_rows=s.val_heads,
                 n_cols=s.hidden, blk=b, tensor=p + "ssm_beta.weight")
            emit(opcode=OP_A_JOB, src=R_XN, dst=R_ALPHA, n_rows=s.val_heads,
                 n_cols=s.hidden, blk=b, tensor=p + "ssm_alpha.weight")
            emit(opcode=OP_B_JOB, src=R_QKV, dst=R_Y, n_rows=s.val_dim,
                 blk=b, ordinal=go)
            emit(opcode=OP_A_JOB, src=R_Y, dst=R_ER, n_rows=s.hidden,
                 n_cols=s.val_dim, blk=b, tensor=p + "ssm_out.weight")
            emit(opcode=OP_VEC_RES, src=R_X, src2=R_ER, dst=R_X,
                 n_rows=s.hidden, blk=b)
            emit_ffn(b)

    # The TAIL norm's ordinal is 0, not `blocks % 64`.  sim/seq_tbl_pkg.vhd
    # passes it explicitly; sim/llama_sched_pkg.vhd stamps `blk % 64` on every
    # step and therefore writes `blocks % 64` here.  The two disagree.
    emit(opcode=OP_VEC_NORM, src=R_X, dst=R_XN, n_rows=s.hidden,
         blk=s.blocks, const_base=s.blocks, ordinal=0)
    # THE LM HEAD, one A job per row window.
    #
    # `dst` is R_NONE and FLG_TO_SMP on EVERY window, not only the first or
    # the last: each window streams its own slice of the logits to the
    # sampler, and there is no region write to attribute to one of them.
    # `dst_off` stays 0 for the same reason -- `seq_opdec` infers an exponent
    # SEGMENT from `dst_offset`, and a stream has no segments.  Commit
    # 706a2a4 MEASURED on the real `rtl/sampler_stream.vhd` that the windows
    # share one running argmax with NO offset arithmetic, provided `clr` is
    # pulsed once per token and they are issued ascending; they are emitted
    # ascending here, and nothing in the descriptor format expresses `clr`
    # (see the write-up's open list).
    #
    # `out_mode` is RAW (1) on every window and that is load-bearing, not
    # inherited: raw's `y_exp = w_exp + x_exp - out_shift`
    # (ref/matvec_int4.c:436) carries no per-job term, so 15 windows report
    # ONE exponent and their s32 payloads are directly comparable.  BFP's
    # `ns` is a max over the JOB's rows (:403-413), so 15 BFP windows would
    # carry 15 different exponents into a sampler whose only input is a
    # 32-bit integer (rtl/sampler_stream.vhd:27).
    for rs, nr in lmw:
        emit(opcode=OP_A_JOB, flags=FLG_TO_SMP, src=R_XN, dst=R_NONE,
             n_rows=nr, n_cols=s.hidden, out_mode=1, blk=s.blocks,
             tensor="output.weight", row_start=rs)
    emit(opcode=OP_END_TOKEN, blk=s.blocks)

    if not qkv_fused and len(steps) != s.n_steps(len(lmw)):
        raise LayerError("emitted %d steps, n_steps() says %d"
                         % (len(steps), s.n_steps(len(lmw))))
    build_rel(steps)
    return steps


def cons_mask(st):
    """The regions a step CONSUMES: its two region bytes plus the per-opcode
    extra mask, which is exactly what `seq_opdec` computes."""
    if st.opcode == OP_END_TOKEN:
        return 0
    m = OPC_CONS_MAP[st.opcode]
    if st.src < NREGION:
        m |= 1 << st.src
    if st.src2 < NREGION:
        m |= 1 << st.src2
    return m


def prod_mask(st):
    if st.opcode != OP_END_TOKEN and st.dst < NREGION:
        return 1 << st.dst
    return 0


def build_rel(steps):
    """THE LIVENESS PASS.  For step i and region R that i consumes, set rel(R)
    iff no LATER step consumes R before some step re-produces it.  The in-place
    residual (R_X in both sets) is handled by starting the scan at i+1."""
    n = len(steps)
    cons = [cons_mask(s) for s in steps]
    prod = [prod_mask(s) for s in steps]
    for i in range(n):
        rel = 0
        for r in range(NREGION):
            bit = 1 << r
            if not (cons[i] & bit):
                continue
            for j in range(i + 1, n):
                if cons[j] & bit:
                    break
                if prod[j] & bit:
                    rel |= bit
                    break
            else:
                rel |= bit
        steps[i].rel = rel


# ============================================================== the encoder
def u32(v):
    return v & 0xFFFFFFFF


def encode_header(st, stamp, nsub_w, nsub_s, d_cb_load=False,
                  nsub_every_step=False, const_base_every_step=False):
    """The 64-byte header, D design spec section 6.1, byte-pinned,
    little-endian.  Word layout from `rtl/seq_desc_fetch.vhd:93-101`, which is
    the source both the gateware and the two VHDL generators compute from."""
    d = [0] * 8
    flags = st.flags | (FLG_CB if d_cb_load and st.opcode == OP_A_JOB else 0)
    d[0] = ((st.opcode & 0xFF)
            | ((flags & 0xFF) << 8)
            | ((st.src & 0xFF) << 16)
            | ((st.dst & 0xFF) << 24)
            | ((st.dst_off & 0xFFFFFFFF) << 32))
    d[1] = (st.n_rows & 0xFFFFFFFF) | ((st.n_cols & 0xFFFFFFFF) << 32)

    w_exp, out_shift, const_exp, ordinal = stamp(st)

    # `nsub_w` / `nsub_s` describe A's base array and are meaningless on any
    # other opcode; both VHDL generators leave them 0 off an A_JOB and
    # `seq_desc_fetch` only range-checks them against NSUB_MAX.
    # `sim/seq_tbl_pkg.vhd` passes them only on an A_JOB; `sim/llama_sched_pkg
    # .vhd` passes them on EVERY step.  The two VHDL generators disagree, and
    # `seq_desc_fetch` only range-checks the field, so both are accepted.
    if nsub_every_step or st.opcode == OP_A_JOB:
        nw, ns = nsub_w, nsub_s
    else:
        nw, ns = 0, 0

    d[2] = u32(w_exp) | (u32(out_shift) << 32)
    d[3] = ((st.out_mode & 0xFF)
            | ((ordinal & 0xFF) << 8)
            | ((nw & 0xFFFF) << 16)
            | ((ns & 0xFFFF) << 32)
            | ((st.src2 & 0xFF) << 48))          # 63:56 is D's PAD, stays 0
    # `const_base` is the norm-weight selector.  `sim/seq_tbl_pkg.vhd` passes
    # it only on a VEC_NORM; `sim/llama_sched_pkg.vhd` passes the block index
    # on EVERY step.  Third disagreement between the two VHDL generators.
    cb = st.const_base if (const_base_every_step
                           or st.opcode == OP_VEC_NORM) else 0
    d[4] = (cb & 0xFFFFFFFF) | (u32(const_exp) << 32)
    d[5] = 0                                     # codebook, D's copy
    d[6] = 0
    d[7] = 0                                     # D's reserved word, PAD
    return d


# ---- the three field stampings ------------------------------------------
# The routing fields are identical in all three.  Only w_exp / out_shift /
# const_exp / ordinal move, and they move because the two VHDL generators
# stamp them from the STEP INDEX on purpose (so a stale capture is a wrong
# number rather than a repeat), while a real program takes them from the
# packed tensor.
def stamp_seq_tbl(st):
    """sim/seq_tbl_pkg.vhd's `emit`.  `p` is the step index."""
    p = st.idx
    return (((p * 7) % 61) - 30, (p % 23) - 11, ((p * 5) % 41) - 20,
            st.ordinal)


def stamp_sched(st):
    """sim/llama_sched_pkg.vhd's `build_table`.  Narrower `w_exp` /
    `out_shift` ranges, because that table is EXECUTED by a real matvec and
    `matvec_core.vhd:850-867` refuses a shift outside [0,40].

    `ordinal` used to be the BLOCK index on every step here, which is where
    the two VHDL generators disagreed (defect ORD-1, fixed 2026-08-29).  It is
    the per-kind ordinal now, identical to every other stamping, so this
    control still FAILS the oracle -- on w_exp and out_shift, which is what it
    was ever meant to be measuring."""
    i = st.idx
    return ((i % 5) - 2, i % 5, ((i * 5) % 41) - 20, st.ordinal)


def make_stamp_manifest(w_exp_of, shift_of):
    """The real one.  `w_exp` and `out_shift` come from the packed tensor for
    an A_JOB, and NOTHING SUPPLIES THEM for a D-vec op."""
    def f(st):
        if st.opcode == OP_A_JOB and st.tensor in w_exp_of:
            return (w_exp_of[st.tensor], shift_of[st.tensor], 0, st.ordinal)
        return (0, 0, 0, st.ordinal)
    return f


STAMPS = {"seq_tbl": stamp_seq_tbl, "sched": stamp_sched}


def vhdl_nports(src=None):
    """`A_NPORTS_W` / `A_NPORTS_S` as `sim/seq_tbl_pkg.vhd` declares them.

    Both VHDL generators take their `nsub_w` / `nsub_s` from those two
    constants, and `--stamp seq_tbl` / `--stamp sched` claim to reproduce those
    generators byte for byte.  Reading the declaration is the only version of
    that claim which cannot quietly become false.
    """
    import re
    if src is None:
        src = os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), "sim", "seq_tbl_pkg.vhd")
    txt = open(src).read()
    out = []
    for name in ("A_NPORTS_W", "A_NPORTS_S"):
        m = re.search(r"constant\s+%s\s*:\s*natural\s*:=\s*(\d+)\s*;" % name,
                      txt)
        if not m:
            raise SystemExit(
                "gen_layer_program: %s not found in %s.  The --stamp modes "
                "mirror the VHDL generators and cannot mirror a declaration "
                "they cannot read; fix the pattern rather than defaulting."
                % (name, src))
        out.append(int(m.group(1)))
    return out[0], out[1]


# ============================================================== A descriptors
def a_jobs_for(steps, manifest_path, x_exp, desc_base, out_mode=None,
               check_hash=True, build=None):
    """Build one subsystem A descriptor per A_JOB step, from the manifest.

    THE ROW-WINDOW CONSTRAINT IS WHERE THIS BITES.  A sub-region's beats run
    tile-major, so a job that does not start at row 0 is expressed by advancing
    every base by whole TILES -- `gen_mv4i_desc.build_descriptor` refuses a
    `row_start` that is not a multiple of ROWS_IF.  The GDN block's three-way
    qkv split asks for windows at rows `key_dim` and `2*key_dim`, and at the
    9B shape those are 2048 and 4096 while ROWS_IF is 48:

        2048 mod 48 = 32,  4096 mod 48 = 16

    so against an UNPADDED fused tensor two of the three are not expressible.
    They are reported, not fudged.

    THE PADDED SET closes this.  `tools/pack_model_fk33.py` pads each segment
    of a fused tensor up to a whole tile and records the resulting windows in
    the manifest as `segments`; the packed starts become 0, 2064 and 4128.  A
    step carries the LOGICAL row (`st.row_start`, which is also what R_QKV's
    `dst_offset` uses, because `seq_opdec` infers the exponent segment from
    the DESTINATION offset and that must not move), and this function maps it
    through the manifest to the PACKED row.  The mapping is a lookup, never an
    arithmetic re-derivation: if the manifest declares segments and none of
    them matches the step, nothing is emitted for it and the reason says so."""
    build = build or G.FK33
    m, by_file = G.load_manifest(manifest_path)
    root = os.path.dirname(os.path.abspath(manifest_path))
    out = []
    addr = desc_base
    align = build["desc_maxb"] * (build["axi_dw"] // 8)
    for st in steps:
        if st.opcode != OP_A_JOB:
            continue
        name = st.tensor + ".mv4i"
        ent = by_file.get(name)
        if ent is None:
            out.append(dict(step=st.idx, tensor=st.tensor, ok=False,
                            reason="not in the manifest"))
            continue
        path = os.path.join(root, name)
        try:
            h = G.Mv4iHeader(path)
        except (G.DescError, OSError) as e:
            out.append(dict(step=st.idx, tensor=st.tensor, ok=False,
                            reason=str(e)))
            continue
        if check_hash:
            got, want, ok = G.verify_image(path, ent)
            if not ok:
                out.append(dict(step=st.idx, tensor=st.tensor, ok=False,
                                reason="blake2b_128 %s, manifest says %s"
                                       % (got, want)))
                continue
        # LOGICAL row -> PACKED row, through the manifest's segment table.
        packed_start, seg_note = st.row_start, None
        segs = ent.get("segments")
        if segs:
            hit = [q for q in segs
                   if q.get("logical_row", q["row_start"]) == st.row_start
                   and q["n_rows"] == st.n_rows]
            if len(hit) != 1:
                out.append(dict(step=st.idx, tensor=st.tensor, ok=False,
                                reason="the manifest declares %d row segments "
                                       "and %d of them is the window "
                                       "(logical row %d, %d rows) this step "
                                       "asks for"
                                       % (len(segs), len(hit), st.row_start,
                                          st.n_rows)))
                continue
            packed_start = hit[0]["row_start"]
            seg_note = hit[0]["name"]
        elif st.row_start and int(ent.get("M_logical", ent["M"])) != ent["M"]:
            out.append(dict(step=st.idx, tensor=st.tensor, ok=False,
                            reason="tensor is padded but declares no segments"))
            continue
        # A window that runs past the packed rows is NOT caught anywhere else:
        # `row_start` is not a descriptor field (it is folded into the bases),
        # so the gateware cannot see it, and `rtl_would_reject` only bounds
        # `n_rows` against MAXROWS_BFP.  MEASURED as a silent pass before this
        # check existed: a `row_start` one tile too high was emitted, accepted
        # by the RTL, and would have read past the tensor's own sub-regions.
        if packed_start + st.n_rows > h.M:
            out.append(dict(step=st.idx, tensor=st.tensor, ok=False,
                            reason="window rows %d..%d runs past the packed "
                                   "M = %d" % (packed_start,
                                               packed_start + st.n_rows - 1,
                                               h.M)))
            continue
        try:
            d = G.build_descriptor(
                h, int(ent["hbm_offset"]), st.n_rows, x_exp,
                out_mode=(st.out_mode if out_mode is None else out_mode),
                cb_load=True, addr_w=build["addr_w"], row_start=packed_start,
                src_region=st.src, dst_region=st.dst,
                dst_offset=st.dst_off, ordinal=st.ordinal,
                src_region2=st.src2, const_base=st.const_base, const_exp=0)
        except G.DescError as e:
            out.append(dict(step=st.idx, tensor=st.tensor, ok=False,
                            reason=str(e)))
            continue
        bad = G.rtl_would_reject(d, build=build, desc_addr=addr)
        out.append(dict(step=st.idx, tensor=st.tensor, ok=not bad,
                        reason="; ".join(n for _, n in bad),
                        desc=d, desc_addr=addr,
                        w_exp=h.w_exp, out_shift=h.out_shift,
                        M=h.M, K=h.K, row_start=packed_start,
                        logical_row=st.row_start, segment=seg_note,
                        n_rows=st.n_rows,
                        w_beats=d.fields["w_beats"],
                        s_beats=d.fields["s_beats"]))
        addr += ((d.fields["desc_bytes"] + align - 1) // align) * align
    return out, m


# ====================================================== the descriptor arena
def place_desc_arena(a, mani, all_steps, sel):
    """Where the subsystem A descriptors go, DECIDED BY `tools/hbm_map.py`.

    THE DEFAULT PATH DOES NO ARITHMETIC AT ALL.  It reads
    `hbm.desc_arena_base` out of the manifest -- Oren's 2026-08-29 decision:
    the region block in the manifest is the authority, one file states every
    base, and neither producer invents a number.  `hbm_map` still builds the
    whole map and still refuses on any overlap, so a DECLARED address is
    checked exactly as hard as a computed one was; what is gone is the
    possibility of this file and `pl_derive_bases()` arriving at two answers.

    THIS USED TO BE FOUR LINES OF LOCAL ARITHMETIC AND IT PRODUCED A SILENT
    WRONG TOKEN.  It read:

        size = int(mani["hbm"].get("size", 1 << 33))
        need = 512 * max(1, sum(1 for st in sel if st.opcode == OP_A_JOB))
        desc_base = (size - need) & ~0xFFF

    which anchors at the TOP of the device -- and so does
    `server/pl_backend.c::pl_derive_bases()`, which puts the host's logits
    writeback and D program there.  Neither could see the other.  MEASURED at
    the 9B shape (TRACK WEIGHTS, 2026-08-29): the arena landed at
    0x1_FFFD_9000 and took 153,664 B out of the logits row, which is 38,416
    float32 slots, the top 15.47% of the 248,320-entry vocabulary.  Whichever
    master wrote last won, and the symptom is a wrong token with no fault.

    Two other things were wrong with those four lines and are fixed here:

      * `need` was sized from `sel`, the SELECTED steps.  So `--layer 3` and
        `--token` put the descriptors at DIFFERENT addresses out of the same
        program.  The arena is now sized from the whole token program, so the
        base is a property of the model and not of the command line.
      * the per-job stride 512 was a literal.  It is
        `desc_maxb * axi_dw/8` from `gen_mv4i_desc.FK33`, and `hbm_map` takes
        it from there.

    The check is not advisory.  If the resulting map has ANY overlap this
    raises SystemExit, so a colliding arena cannot be emitted at all.  That is
    the point: a detector run by hand is not what failed here, mutual
    blindness between two producers is."""
    if a.desc_base is not None and not mani:
        return a.desc_base
    if not mani:
        raise SystemExit(
            "gen_layer_program: the A descriptors need an address and there is "
            "no manifest to place them against.  Pass --manifest (note its "
            "default is the PRE-QKV-PAD set) or --desc-base, and if you pass "
            "--desc-base without a manifest NOTHING checks it for overlap.")

    n_full = max(1, sum(1 for st in all_steps if st.opcode == OP_A_JOB))
    n_sel = sum(1 for st in sel if st.opcode == OP_A_JOB)
    # strict_arena=True: a PRODUCER may not guess.  Under the decided mechanism
    # that means a manifest with no region block is a REFUSAL here, not a
    # re-derivation -- if this file could compute the address itself, two
    # producers would be free to disagree again, which is the defect.
    m = HM.plan(mani, desc_jobs=n_full, desc_base=a.desc_base,
                policy=a.desc_policy, max_chunk=a.max_chunk,
                strict_arena=True)
    fails = m.check()
    if fails:
        raise SystemExit(
            "gen_layer_program: REFUSING to emit A descriptors -- the HBM map "
            "has %d overlap/placement fault(s).  See tools/hbm_map.py.\n"
            % len(fails) + "\n".join("  " + s for s in fails))
    arena = [r for r in m.regions if r.kind == "desc"]
    if not arena:
        raise SystemExit("gen_layer_program: hbm_map placed no arena")
    if a.print:
        print("A descriptor arena %s .. %s (%d B, %d jobs in the full token "
              "program, %d selected here); READ FROM %s; checked disjoint "
              "against %d regions from %d allocators"
              % (HM.h(arena[0].base), HM.h(arena[0].end), arena[0].nbytes,
                 n_full, n_sel, arena[0].owner, len(m.regions),
                 len({r.owner for r in m.regions})))
    return arena[0].base


# ============================================================== manifest check
def check_against_manifest(s, manifest_path, layer=0):
    """The 9B shape constants are copied from `rtl/model_cfg_pkg.vhd`.  The ONE
    independent source for them in this repository is the packed tensors'
    own shapes, so they are checked against those rather than trusted."""
    m, by_file = G.load_manifest(manifest_path)

    def shp(name):
        """The LOGICAL shape.  `M` in the manifest is the PACKED row count,
        which for a fused tensor with padded segments is larger than the
        model's dimension by the pad rows; `M_logical` is the model's.  A check
        against `M` would fail on a padded set and would be checking the
        packing, not the shape."""
        e = by_file.get(name + ".mv4i")
        if e is None:
            return None
        return (int(e.get("M_logical", e["M"])), e["K"])

    p = "blk.%d." % layer
    checks = []
    g = shp(p + "ffn_gate.weight")
    if g:
        checks.append(("hidden", s.hidden, g[1]))
        checks.append(("ffn", s.ffn, g[0]))
    d = shp(p + "ffn_down.weight")
    if d:
        checks.append(("hidden (ffn_down M)", s.hidden, d[0]))
        checks.append(("ffn (ffn_down K)", s.ffn, d[1]))
    q = shp(p + "attn_qkv.weight")
    if q:
        checks.append(("qkv_dim", s.qkv_dim, q[0]))
    z = shp(p + "attn_gate.weight")
    if z:
        checks.append(("val_dim", s.val_dim, z[0]))
    b = shp(p + "ssm_beta.weight")
    if b:
        checks.append(("val_heads", s.val_heads, b[0]))
    o = shp(p + "ssm_out.weight")
    if o:
        checks.append(("val_dim (ssm_out K)", s.val_dim, o[1]))
    aq = shp(p + "attn_q.weight")
    if aq:
        checks.append(("att_qg", s.att_qg, aq[0]))
    ak = shp(p + "attn_k.weight")
    if ak:
        checks.append(("att_kv", s.att_kv, ak[0]))
    ao = shp(p + "attn_output.weight")
    if ao:
        checks.append(("att_q (attn_output K)", s.att_q, ao[1]))
    ow = shp("output.weight")
    if ow:
        checks.append(("vocab_shard", s.vocab_shard, ow[0]))
    return checks, m


# ============================================================== output
def write_hex(path, words):
    with open(path, "w") as fp:
        for w in words:
            fp.write("%016X\n" % w)


def write_rel(path, steps, nreg=NREGION):
    with open(path, "w") as fp:
        for st in steps:
            fp.write("".join("1" if (st.rel >> b) & 1 else "0"
                             for b in range(nreg - 1, -1, -1)) + "\n")


def rname(r):
    return RNAME[r] if r < NREGION else "-"


def print_plan(steps, first=0):
    print("  # step  opcode     src  src2 dst  off      n_rows  n_cols  "
          "ord  rel            tensor")
    for st in steps:
        print("  %5d  %-9s %-4s %-4s %-4s %-8d %-7d %-7d %-4d %-14s %s"
              % (st.idx, OPNAME[st.opcode], rname(st.src), rname(st.src2),
                 rname(st.dst), st.dst_off, st.n_rows, st.n_cols, st.ordinal,
                 "".join("1" if (st.rel >> b) & 1 else "0"
                         for b in range(NREGION - 1, -1, -1)),
                 st.tensor or ""))


def layer_slice(steps, layer):
    return [st for st in steps if st.blk == layer]


# ============================================================== CLI
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--manifest",
                    default="/mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json")
    ap.add_argument("--layer", type=int, default=None,
                    help="emit the program for this transformer block only")
    ap.add_argument("--token", action="store_true",
                    help="emit the whole token's D table instead of one layer")
    ap.add_argument("--shape", choices=("9b", "sim"), default="9b")
    ap.add_argument("--blocks", type=int, default=4, help="--shape sim only")
    ap.add_argument("--attn-int", type=int, default=4, help="--shape sim only")
    ap.add_argument("--attn-hd", type=int, default=32, help="--shape sim only")
    ap.add_argument("--close-token", action="store_true",
                    help="append an END_TOKEN so a LAYER SLICE is a runnable "
                         "table.  seq_desc_fetch enforces END_TOKEN-last in "
                         "hardware, so without this a layer is a fragment")
    ap.add_argument("--qkv-fused", action="store_true",
                    help="emit the GDN qkv as ONE job over the fused packed "
                         "tensor instead of three row windows.  Expressible "
                         "at ROWS_IF = 48, and it collapses R_QKV's three "
                         "exponent segments into one")
    ap.add_argument("--one-lmhead-job", action="store_true",
                    help="emit the lm_head as ONE A job over the whole "
                         "vocabulary instead of tile-aligned row windows.  "
                         "This is what both VHDL generators encode and it is "
                         "REFUSED by the gateware at the 9B vocabulary "
                         "(n_rows > MAXROWS_BFP, matvec_int4_desc_axi:722, "
                         "checked in EVERY out_mode).  Kept so the byte "
                         "comparison against those generators stays "
                         "reproducible")
    ap.add_argument("--stamp", choices=("manifest", "seq_tbl", "sched"),
                    default="manifest",
                    help="where w_exp/out_shift/const_exp/ordinal come from")
    ap.add_argument("--nsub-every-step", action="store_true", default=None,
                    help="write nsub_w/nsub_s on every step, not only on an "
                         "A_JOB.  Default follows --stamp: seq_tbl no, "
                         "sched yes")
    ap.add_argument("--d-cb-load", action="store_true",
                    help="also set flags bit 2 (cb_load) in the D header")
    ap.add_argument("--x-exp", type=int, default=None,
                    help="the activation BFP exponent.  NOT DERIVABLE; it is a "
                         "per-token runtime value from the previous stage")
    ap.add_argument("--desc-base", type=G.parse_int, default=None,
                    help="HBM byte address of the first A descriptor.  Nothing "
                         "in the manifest reserves descriptor space, so this "
                         "is CHECKED by tools/hbm_map.py against the host's "
                         "blocks and the weight image and REFUSED on overlap")
    ap.add_argument("--desc-policy",
                    choices=("manifest", "allocate-below-host", "top-down"),
                    default="manifest",
                    help="'manifest' READS hbm.desc_arena_base out of the "
                         "packed set, which is the decided mechanism and does "
                         "no arithmetic.  'allocate-below-host' re-runs the "
                         "allocation rule and 'top-down' reproduces this "
                         "file's HISTORIC colliding default; both exist only "
                         "so the refusals can be demonstrated and neither "
                         "should be used to emit a program")
    ap.add_argument("--max-chunk", type=int, default=None,
                    help="pl_open()'s max_chunk.  It sets the host R_X span, "
                         "which is what the arena is placed below, so it "
                         "MOVES the arena.  Default: hbm.host_max_chunk out of "
                         "the manifest, which PINS the cap the arena was "
                         "placed under; passing one that disagrees is a FAIL")
    ap.add_argument("--nsub-w", type=int, default=None,
                    help="D header nsub_w.  Default: the manifest geometry's "
                         "nports_w (24 on the FK33).  The VHDL generators "
                         "wrote 29 until 2026-08-29 -- the superseded "
                         "ROWS_IF=58 count -- and D only range-checks the "
                         "field, so nothing refused it; the A wrapper does, "
                         "with EC_GEOM.  Both now take it from "
                         "seq_tbl_pkg.A_NPORTS_W")
    ap.add_argument("--nsub-s", type=int, default=None)
    ap.add_argument("--outdir", default=None)
    ap.add_argument("--d-table", default=None, help="write the D table here")
    ap.add_argument("--rel-file", default=None)
    ap.add_argument("--json", default=None)
    ap.add_argument("--no-hash", action="store_true")
    ap.add_argument("--no-a", action="store_true",
                    help="D table only; do not touch the packed tensors")
    ap.add_argument("--print", action="store_true")
    a = ap.parse_args(argv)

    if a.shape == "sim":
        s = mk_shape_scaled(a.blocks, a.attn_int, a.attn_hd)
        a.no_a = True
    else:
        s = QWEN35_9B

    lmw = [(0, s.vocab_shard)] if a.one_lmhead_job else lmhead_windows(s)
    steps = build_plan(s, qkv_fused=a.qkv_fused, lm_windows=lmw)

    # ---- the shape, checked against the packed tensors -------------------
    mani = None
    geom = {}
    if a.shape == "9b" and os.path.exists(a.manifest):
        checks, mani = check_against_manifest(s, a.manifest,
                                              layer=a.layer or 0)
        bad = [(n, w, g) for (n, w, g) in checks if w != g]
        if bad:
            raise SystemExit(
                "gen_layer_program: the model shape and the packed tensors "
                "DISAGREE:\n" + "\n".join(
                    "  %-24s shape says %d, manifest says %d" % b for b in bad))
        geom = mani.get("geometry", {})
        if a.print:
            print("shape cross-checked against %d packed-tensor dimensions"
                  % len(checks))

    nsub_w = a.nsub_w if a.nsub_w is not None else geom.get("nports_w", 24)
    nsub_s = a.nsub_s if a.nsub_s is not None else geom.get("n_scale_sub", 3)
    if a.stamp in STAMPS:
        stamp = STAMPS[a.stamp]
        # READ the VHDL, do not restate it.  `--stamp seq_tbl` / `--stamp
        # sched` exist to be BYTE-IDENTICAL to the two VHDL generators, so a
        # literal here is a second copy of the number that was wrong in the
        # first place: while the packages carried 29/4 this line carried 29/4
        # too, and the two agreeing proved nothing about either.  Scraped from
        # the package instead, and a scrape that stops matching is a hard
        # failure rather than a silent default.
        vnw, vns = vhdl_nports()
        if a.nsub_w is None:
            nsub_w = vnw
        if a.nsub_s is None:
            nsub_s = vns
    else:
        wex, shf = {}, {}
        if mani:
            for f in mani["files"]:
                if f.get("kind") == "mv4i":
                    wex[f["tensor"]] = f["w_exp"]
                    shf[f["tensor"]] = f["out_shift"]
        stamp = make_stamp_manifest(wex, shf)

    nsub_every = (a.stamp == "sched") if a.nsub_every_step is None \
        else a.nsub_every_step
    cbase_every = (a.stamp == "sched")

    sel = steps if (a.token or a.layer is None) else layer_slice(steps, a.layer)
    if not sel:
        raise SystemExit("gen_layer_program: no steps for layer %r" % a.layer)

    if a.close_token and (sel and sel[-1].opcode != OP_END_TOKEN):
        # `rtl/seq_desc_fetch.vhd:526-533` enforces the counting identity in
        # hardware: END_TOKEN must be the LAST descriptor and the last
        # descriptor must be END_TOKEN.  A LAYER SLICE IS THEREFORE NOT A
        # RUNNABLE TABLE -- MEASURED: the 16-step layer 0 slice is refused
        # with ERR_DESC at its last step.  This appends the END_TOKEN that
        # closes it, so one layer can be executed on its own.
        term = Step(opcode=OP_END_TOKEN, src=R_NONE, src2=R_NONE, dst=R_NONE,
                    blk=sel[-1].blk)
        term.idx = sel[-1].idx + 1
        term.rel = 0
        sel = sel + [term]

    words = []
    for st in sel:
        words.extend(encode_header(st, stamp, nsub_w, nsub_s, a.d_cb_load,
                                   nsub_every, cbase_every))

    outdir = a.outdir
    if outdir:
        if not os.path.isdir(outdir):
            os.makedirs(outdir)
    d_table = a.d_table or (os.path.join(outdir, "d_table.hex")
                            if outdir else None)
    rel_file = a.rel_file or (os.path.join(outdir, "rel_mask.txt")
                              if outdir else None)
    if d_table:
        write_hex(d_table, words)
    if rel_file:
        write_rel(rel_file, sel)

    # ---- subsystem A ------------------------------------------------------
    ajobs = []
    if not a.no_a:
        if a.x_exp is None:
            raise SystemExit(
                "gen_layer_program: --x-exp is required for the A descriptors."
                "  It is the activation vector's BFP exponent, a per-token "
                "runtime value the previous stage produces; nothing in the "
                "manifest supplies it.  Use --no-a for the D table alone.")
        desc_base = place_desc_arena(a, mani, steps, sel)
        ajobs, mani = a_jobs_for(sel, a.manifest, a.x_exp, desc_base,
                                 check_hash=not a.no_hash)
        if outdir:
            for j in ajobs:
                if j.get("desc") is None:
                    continue
                write_hex(os.path.join(
                    outdir, "a%02d_%s.hex" % (j["step"], j["tensor"])),
                    j["desc"].words)

    # ---- report -----------------------------------------------------------
    if a.print:
        print("model     blocks=%d attn_interval=%d hidden=%d ffn=%d "
              "key_dim=%d val_dim=%d att_q=%d att_kv=%d"
              % (s.blocks, s.attn_interval, s.hidden, s.ffn, s.key_dim,
                 s.val_dim, s.att_q, s.att_kv))
        print("token     %d steps (%d GDN x %d, %d attn x %d, +2, "
              "+%d lm_head window%s)"
              % (s.n_steps(len(lmw)), s.n_gdn(), NSTEP_GDN_N1, s.n_attn(),
                 NSTEP_ATTN_N1, len(lmw), "" if len(lmw) == 1 else "s"))
        if a.layer is not None and not a.token:
            print("layer %-3d %s, %d steps, D table %d bytes"
                  % (a.layer, "ATTENTION" if s.is_attn(a.layer) else "GDN",
                     len(sel), 64 * len(sel)))
        print("D header  nsub_w=%d nsub_s=%d  stamp=%s" % (nsub_w, nsub_s,
                                                           a.stamp))
        print()
        print_plan(sel)
        if ajobs:
            print()
            print("subsystem A descriptors, FK33 geometry "
                  "(ROWS_IF=%d AXI_DW=%d nsub_w=%d nsub_s=%d):"
                  % (G.FK33["rows_if"], G.FK33["axi_dw"],
                     G.FK33["nports_w"], G.FK33["nports_s"]))
            for j in ajobs:
                if not j["ok"]:
                    print("  step %-4d %-28s REFUSED: %s"
                          % (j["step"], j["tensor"], j["reason"]))
                else:
                    print("  step %-4d %-28s rows %d..%d of %d  w_exp=%d "
                          "out_shift=%d w_beats=%d s_beats=%d  @0x%X"
                          % (j["step"], j["tensor"], j["row_start"],
                             j["row_start"] + j["n_rows"] - 1, j["M"],
                             j["w_exp"], j["out_shift"], j["w_beats"],
                             j["s_beats"], j["desc_addr"]))
            nref = sum(1 for j in ajobs if not j["ok"])
            print("  %d of %d A jobs emitted, %d refused"
                  % (len(ajobs) - nref, len(ajobs), nref))

    if a.json:
        blob = dict(
            shape=dict(blocks=s.blocks, attn_interval=s.attn_interval,
                       hidden=s.hidden, ffn=s.ffn, key_dim=s.key_dim,
                       val_dim=s.val_dim, att_q=s.att_q, att_kv=s.att_kv,
                       n_steps=s.n_steps(len(lmw)),
                       lm_windows=lmw),
            stamp=a.stamp, nsub_w=nsub_w, nsub_s=nsub_s,
            layer=a.layer, n_emitted=len(sel),
            steps=[dict(idx=st.idx, opcode=st.opcode,
                        opname=OPNAME[st.opcode], unit=st.unit,
                        src=st.src, src2=st.src2, dst=st.dst,
                        dst_off=st.dst_off, n_rows=st.n_rows,
                        n_cols=st.n_cols, blk=st.blk, ordinal=st.ordinal,
                        const_base=st.const_base, rel=st.rel,
                        tensor=st.tensor, row_start=st.row_start)
                   for st in sel],
            a_jobs=[dict((k, v) for k, v in j.items() if k != "desc")
                    for j in ajobs])
        with open(a.json, "w") as fp:
            json.dump(blob, fp, indent=1)

    if ajobs and any(not j["ok"] for j in ajobs):
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
