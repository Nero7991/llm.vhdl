#!/usr/bin/env python3
"""THE 8 GiB HBM ADDRESS SPACE, IN ONE PLACE, WITH A CHECK THAT BITES.

    hbm_map.py MANIFEST.json [--desc-jobs N] [--desc-base ADDR]
               [--policy manifest|allocate-below-host|top-down] [--max-chunk N]
               [--no-host-blocks] [--json] [--markdown] [--check-c]
               [--emit-manifest-hbm] [--write-manifest-hbm]

THE MANIFEST IS THE AUTHORITY (Oren, 2026-08-29).  The mechanism question that
TRACK ADDRARENA left open -- does the arena live in the manifest, or does
`pl_derive_bases()` allocate it -- is decided: **a region block in the
manifest's `hbm` object states every base, and neither producer invents one.**

    hbm.desc_arena_base    the first A descriptor's byte address
    hbm.desc_arena_bytes   the page-rounded reservation
    hbm.desc_arena_jobs    how many descriptors it was sized for
    hbm.desc_arena_stride  bytes per descriptor
    hbm.host_max_chunk     the max_chunk the host blocks were placed at
    hbm.host_n_embd / host_n_vocab
    hbm.host_x_base / host_l_base / host_desc_ptr

`tools/pack_model_fk33.py` writes that block at pack time by calling
`derive_region_block()` below; `--write-manifest-hbm` writes the same block
into a set that was packed before the block existed.  `derive_region_block()`
is the ONLY function in this repository that chooses an arena address.
Everything else -- `gen_layer_program.py`, `pl_derive_bases()`,
`weights_residency.py`, `fk33_load_weights.py` -- READS it.

`--policy allocate-below-host` is the allocation RULE that block is computed
with.  It is no longer an interim fallback for consumers: a consumer that
cannot find the block in the manifest REFUSES rather than re-deriving it, so
"two producers agreed" is not a state this address space can be in.

WHY THIS FILE EXISTS.  On 2026-08-29 TRACK WEIGHTS measured that THREE
allocators share this device and none of them can see the other two, and that
two of them anchor at the same end:

  1. `tools/pack_model_fk33.py` places the 249 packed tensors and the F32 side
     blob upward from 0, declares the GDN state, and calls the remainder the KV
     arena.  It writes all of that into `manifest.json`.
  2. `tools/gen_layer_program.py` places the subsystem A descriptor arena.  Its
     own comment says why it must: "Nothing in the manifest reserves descriptor
     space.  Take it from the TOP of HBM, aligned down, and state the cost."
  3. `server/pl_backend.c::pl_derive_bases()` places the host's three blocks --
     R_X staging, the logits writeback, and the D program -- ALSO top-down from
     the top of HBM.

(2) and (3) COLLIDE at the shipping default, MEASURED at HEAD 9d7a9e5 on
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd`:

    A descriptor arena     0x1_FFFD_9000 .. 0x1_FFFF_FE00   159,232 B
    host logits writeback  0x1_FFF0_C000 .. 0x1_FFFF_E840   993,344 B  -153,664
    host D program         0x1_FFFF_F000 .. 0x2_0000_0000     4,096 B  -  3,584

153,664 B of the logits writeback is 38,416 float32 logit slots, the top 15.47%
of the 248,320-entry vocabulary.  Whichever master writes last wins, and the
symptom is a WRONG TOKEN, silently.

THE POINT OF THIS FILE IS NOT TO DETECT THAT ONCE.  `tools/weights_residency.py`
already did, and a detector is not a fix: it re-derived (3) in Python from the
strides in `server/fk33_seam.h`, so it was a FOURTH model of the same address
space, free to drift from the C the moment anyone edited `pl_derive_bases()`.

So this module is the ONE model, and everything else CONSULTS it:

  * `tools/gen_layer_program.py` asks it where the descriptor arena goes and
    REFUSES to emit descriptors if the answer overlaps anything.  A producer
    that cannot emit a colliding arena cannot reintroduce the defect.
  * `tools/weights_residency.py` is a report over this map plus the
    manifest-arithmetic checks that are its own.
  * `hw/fk33/host/fk33_load_weights.py` preflights against it before it writes
    a byte to the device.
  * `--check-c` COMPILES AND RUNS the real `pl_derive_bases()` out of
    `server/pl_backend.c` and requires it to agree address for address.  That
    is the only thing here that is evidence rather than assertion: two Python
    copies agreeing would prove nothing, and this project has a recorded case
    (TRACK SCHED-FIX) of a wrong constant surviving precisely because "the two
    generators agreed with each other".

CONSTANTS ARE SCRAPED, NOT RESTATED.  `FK33_BLOCK_ALIGN`, `FK33_SEAM_HDR_BYTES`,
`FK33_HBM_TOP` and `FK33_HBM_STACK_LINE` are read out of `server/fk33_seam.h`
at import, and a scrape that stops matching is a hard failure rather than a
silent default.  `tools/gen_layer_program.py` set that precedent for the VHDL
nports values after a literal copy of a wrong number agreed with the wrong
original.

THE ALLOCATION RULE, AND WHY IT IS NOT INTERIM ANY MORE.
`--policy allocate-below-host` places the arena in the first 4 KB-aligned block
below the host's R_X staging.  At the 9B shape that is 0x1_FFAD_D000, which is
the address TRACK WEIGHTS measured as making the map disjoint.  MEASURED cost
against the colliding placement: 2 tokens of KV context, 61,231 -> 61,229 (TRACK
WEIGHTS said 3; the arithmetic is in the ADDRARENA write-up).  It is a
DERIVATION, so it moves when the shape moves -- and now it is EVALUATED ONCE, at
pack time, and written down.  The address in a shipped manifest is a fact about
that packed set, not a policy a reader has to re-run and hope to reproduce.
`--policy top-down` reproduces the historic colliding placement, on purpose, so
the check can be shown going red.

WHY THE HOST BLOCKS ARE IN THE BLOCK TOO.  `pl_derive_bases()` places them from
the card's CAPS at open time, and `max_chunk` is one of those CAPS: a bigger cap
drags `x_base` DOWN, through a fixed arena.  Pinning `hbm.host_max_chunk` turns
that from an unconstrained runtime parameter into a declared one, and the
overlap check in `pl_check_bases()` then REFUSES an open whose cap does not
match the one the arena was placed under.  ADDRARENA left this as an open item
(`max_chunk_grown_over_a_fixed_arena`); it is closed here by declaration, not by
another checker.

WHAT THIS FILE DOES NOT DO.  It never opens a `.mv4i` file, never hashes a
payload, and never touches the card.  Bytes on disk are `check_mv4i_set.py`'s
job; bytes on the device are `fk33_load_weights.py verify`'s.  This is about
ADDRESSES and nothing else.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SEAM_H = os.path.join(REPO, "server", "fk33_seam.h")

if HERE not in sys.path:
    sys.path.insert(0, HERE)


# ------------------------------------------------------- scraped constants

def _scrape_seam_h(names, path=SEAM_H):
    """Read `#define NAME <integer>` out of server/fk33_seam.h.

    A restatement here would be a second copy of exactly the number that this
    file exists to keep single.  A missing or unparseable define is a hard
    failure: a default would be the defect with a different address."""
    try:
        with open(path) as f:
            txt = f.read()
    except OSError as e:
        raise SystemExit("hbm_map: cannot read %s: %s\n"
                         "  The HBM constants are scraped from it rather than "
                         "restated here." % (path, e))
    out = {}
    for n in names:
        m = re.search(r"^#define\s+%s\s+(0x[0-9A-Fa-f]+|\d+)[uU]*[lL]*\s*(?:/\*|//|$)"
                      % re.escape(n), txt, re.M)
        if not m:
            raise SystemExit(
                "hbm_map: %s is not defined in %s in a form this scrape "
                "recognises.  Fix the pattern rather than defaulting: a "
                "default is how the address space got three models."
                % (n, path))
        out[n] = int(m.group(1), 0)
    return out


_C = _scrape_seam_h(["FK33_BLOCK_ALIGN", "FK33_SEAM_HDR_BYTES",
                     "FK33_HBM_TOP", "FK33_HBM_STACK_LINE"])

BLOCK_ALIGN = _C["FK33_BLOCK_ALIGN"]
SEAM_HDR_BYTES = _C["FK33_SEAM_HDR_BYTES"]
HBM_TOP = _C["FK33_HBM_TOP"]
STACK_LINE = _C["FK33_HBM_STACK_LINE"]
PAGE = 4096                       # pl_derive_bases()'s own page granularity

# The GDN constant image's fixed terms, from docs/2026-09-18_b-constants-path.md
# (and rtl/gdn_state_store.vhd's CONST_WORDS once track A lands it).  The
# scalar block is 256 sixteen-bit words = 512 B whatever the shape; the six
# exponents are cw_exp[0..2], dt_e, a_e, w_exp; and 512 B is one 16-beat AXI3
# burst at 32 B, the granule the mover fetches in.
GDN_CONST_SCALAR_WORDS = 256
GDN_CONST_N_EXP = 6
GDN_CONST_BURST_BYTES = 512


def _desc_stride():
    """Bytes one subsystem A descriptor occupies in the arena.

    `tools/gen_layer_program.py` advances by
    `ceil(desc_bytes / align) * align` with `align = desc_maxb * axi_dw/8`,
    and sizes the arena at that same figure per job.  Imported from
    `gen_mv4i_desc.FK33` so the two cannot disagree."""
    try:
        import gen_mv4i_desc as G
    except ImportError:
        return 512
    b = G.FK33
    return int(b["desc_maxb"]) * (int(b["axi_dw"]) // 8)


DESC_STRIDE = _desc_stride()


# ------------------------------------------------- the shape, scraped from RTL
#
# WHY THIS SECTION EXISTS.  Until 2026-08-29 the two arenas that are RESERVED
# rather than PLACED -- the GDN recurrent state and the KV cache -- were sized
# by four literals in `tools/pack_model_fk33.py`:
#
#     GDN_STATE_LAYERS             = 48
#     GDN_STATE_BYTES_PER_LAYER    = 6144 * 128 * 2
#     KV_LAYERS                    = 16
#     KV_BYTES_PER_LAYER_PER_TOKEN = 4 * 256 * 2 * 2
#
# Every one of those is a **Qwen3.8-27B** figure, and three of the four are
# wrong for `QWEN35_9B` even after the layer counts are corrected:
#
#   * 48 GDN and 16 attention layers are 27B's (64 blocks / interval 4).  The
#     9B is 32 blocks / interval 4 = 24 GDN and 8 attention.
#   * `6144` is 27B's `d_inner` = lin_val_heads 48 x lin_head_dim 128.  The 9B
#     is 32 x 128 = 4096.  TRACK ARENA-MANIFEST reported the layer count and
#     explicitly did NOT check this term; it is wrong too, so the GDN arena was
#     3x over, not 2x.
#   * `4 * 256 * 2 * 2` assumes an **int16** KV mantissa and no record header.
#     `rtl/attn_kv_axi.vhd` stores an int8 BFP record: 16 header bytes (NBLK
#     int8 block exponents zero-padded to the 16-byte granule) + HEAD_DIM int8
#     mantissas = 272 B, not 1024 B.
#
# So the numbers are not restated here either.  They are DERIVED from the model
# record in `rtl/model_cfg_pkg.vhd` and from the format constants in the RTL
# that implements each arena, scraped at import, with a hard failure if a
# scrape stops matching.  That is the same rule `_scrape_seam_h` above already
# follows, for the same reason: a literal that agrees with a document is two
# documents agreeing, and this project has a recorded case (TRACK SCHED-FIX) of
# a wrong constant surviving exactly that way.
#
# WHERE EACH TERM COMES FROM.  Named by SYMBOL, not by line, because these
# files are edited daily:
#
#   shape              `rtl/model_cfg_pkg.vhd`, constant QWEN35_9B / QWEN38_27B
#   attn/gdn layers    `rtl/model_cfg_pkg.vhd`, functions attn_layers/gdn_layers
#                      (blocks/attn_interval and blocks - that)
#   GDN state extent   `rtl/gdn_block.vhd` ports st_rhead (0..VAL_HEADS-1),
#                      st_rcol (0..DIM-1), st_rgrp (0..DIM/RECUR_LANES-1) and
#                      st_rdata (RECUR_LANES*16 bits): the array is
#                      VAL_HEADS x DIM x DIM sixteen-bit words.  Corroborated by
#                      `model_cfg_pkg.gdn_sweep_cycles`, whose body says "state
#                      is head_dim x head_dim per VALUE head".
#   GDN mantissa width `rtl/gdn_recur.vhd` port s_in, std_logic_vector(DIM*W-1)
#   GDN exponent table `rtl/gdn_block.vhd` ports se_rhead/se_rcol/se_rdata:
#                      VAL_HEADS x DIM words of `signed(se_j'range)` from
#                      `rtl/gdn_recur.vhd`.
#   KV record          `rtl/attn_kv_axi.vhd` constants CH_B (the 16-byte record
#                      granule) and MANT_B = HEAD_DIM*CM_W/8, REC_B = CH_B +
#                      MANT_B.  Mirrored in `rtl/llama_top.vhd` as REC_B_C.
#   KV region extent   `rtl/llama_top.vhd` constant KVREG_B =
#                      C_LAY*C_NKVH*C_MAXPOS*REC_B_C, ONE region; K and V are
#                      SEPARATE regions with separate bases (C_K_BASE /
#                      C_V_BASE), hence the factor 2.
#
# WHAT IS DELIBERATELY OVER-RESERVED, AND SAID OUT LOUD.  The GDN state
# EXPONENT table is a combinational read in `gdn_block.vhd` and its header says
# it is "small enough to be distributed RAM", so it may never touch HBM.  It is
# reserved anyway (4 KiB per layer, 96 KiB total at the 9B shape) because
# over-reservation costs context and under-reservation silently corrupts a
# neighbouring arena, and 96 KiB of context is 5 tokens.

MODEL_CFG_VHD = os.path.join(REPO, "rtl", "model_cfg_pkg.vhd")
GDN_BLOCK_VHD = os.path.join(REPO, "rtl", "gdn_block.vhd")
GDN_RECUR_VHD = os.path.join(REPO, "rtl", "gdn_recur.vhd")
KV_AXI_VHD = os.path.join(REPO, "rtl", "attn_kv_axi.vhd")

# The record fields of `model_cfg_t`, in the order they are declared.  Listed
# so a field ADDED to the record and not handled here is a loud KeyError at the
# call site rather than a silently ignored dimension.
MODEL_CFG_FIELDS = ("blocks", "attn_interval", "hidden", "ffn",
                    "lin_key_heads", "lin_val_heads", "lin_head_dim",
                    "conv_kernel", "attn_q_heads", "attn_kv_heads",
                    "attn_head_dim", "vocab", "max_context")


def _scrape_fail(what, path, hint):
    raise SystemExit(
        "hbm_map: cannot scrape %s out of %s.\n  %s\n"
        "  Fix the pattern rather than restating the number here: a literal is "
        "how the GDN and KV arenas came to be sized for a different model."
        % (what, path, hint))


def scrape_model_cfg(name="QWEN35_9B", path=MODEL_CFG_VHD):
    """The model record out of `rtl/model_cfg_pkg.vhd`, as a dict.

    Parses the named `constant <NAME> : model_cfg_t := ( ... );` aggregate in
    its NAMED-ASSOCIATION form (`blocks => 32, ...`), which is the form both
    records in that file are written in.  Positional aggregates are NOT
    accepted: reading one positionally would reintroduce exactly the
    16-versus-24 head confusion the file's own header was written to end."""
    try:
        txt = open(path).read()
    except OSError as e:
        _scrape_fail("the model shape", path, str(e))
    m = re.search(r"constant\s+%s\s*:\s*model_cfg_t\s*:=\s*\((.*?)\)\s*;"
                  % re.escape(name), txt, re.S)
    if not m:
        _scrape_fail("constant %s : model_cfg_t" % name, path,
                     "no such aggregate; the known ones are "
                     + ", ".join(re.findall(
                         r"constant\s+(\w+)\s*:\s*model_cfg_t", txt)))
    body = m.group(1)
    out = {}
    for k, v in re.findall(r"(\w+)\s*=>\s*(\d+)", body):
        out[k] = int(v)
    missing = [f for f in MODEL_CFG_FIELDS if f not in out]
    if missing:
        _scrape_fail("fields %s of %s" % (", ".join(missing), name), path,
                     "the aggregate parsed as %r" % out)
    return out


def scrape_build_model(path=MODEL_CFG_VHD):
    """Which record `constant MODEL` selects.  The BUILD target, not a guess."""
    try:
        txt = open(path).read()
    except OSError as e:
        _scrape_fail("constant MODEL", path, str(e))
    m = re.search(r"constant\s+MODEL\s*:\s*model_cfg_t\s*:=\s*(\w+)\s*;", txt)
    if not m:
        _scrape_fail("constant MODEL : model_cfg_t := <name>", path,
                     "the build target is chosen there and nowhere else")
    return m.group(1)


def _scrape_int(path, pattern, what):
    try:
        txt = open(path).read()
    except OSError as e:
        _scrape_fail(what, path, str(e))
    m = re.search(pattern, txt, re.M)
    if not m:
        _scrape_fail(what, path, "pattern %r did not match" % pattern)
    return int(m.group(1))


def scrape_kv_record_terms():
    """(header granule bytes, cache mantissa bits) for one KV head-vector.

    `CH_B` is `attn_kv_axi`'s record granule -- the NBLK int8 block exponents
    zero-padded up to it -- and `CM_W` is the cache mantissa width, which that
    unit asserts must be 8 and `llama_top` re-asserts naming the caller."""
    ch_b = _scrape_int(KV_AXI_VHD,
                       r"^\s*constant\s+CH_B\s*:\s*integer\s*:=\s*(\d+)\s*;",
                       "constant CH_B (the KV record granule)")
    cm_w = _scrape_int(KV_AXI_VHD,
                       r"^\s*CM_W\s*:\s*positive\s*:=\s*(\d+)\s*;",
                       "generic CM_W (the KV cache mantissa width)")
    return ch_b, cm_w


def scrape_gdn_state_terms():
    """(state mantissa bits, state exponent bits) for the GDN recurrent state.

    Both come from `gdn_recur`'s PORTS, which is where the widths are load
    bearing: `s_in` carries DIM mantissas of the first width and `se_j` is the
    per-column exponent of the second."""
    mant = _scrape_int(
        GDN_RECUR_VHD,
        r"^\s*s_in\s*:\s*in\s+std_logic_vector\(DIM\*(\d+)\s*-\s*1\s+downto\s+0\)",
        "port s_in (the GDN state mantissa width)")
    hi = _scrape_int(
        GDN_RECUR_VHD,
        r"^\s*se_j\s*:\s*in\s+signed\((\d+)\s+downto\s+0\)",
        "port se_j (the GDN state column exponent width)")
    return mant, hi + 1


def scrape_gdn_conv_mant_bits():
    """The per-element width of a stored conv tap, from `gdn_block`'s PORT.

    `cv_x` carries `KCONV*CONV_LANES` elements of this width, and that port is
    where the width is load bearing: it is what the tap memory must hand over
    and therefore what a saved column costs per channel."""
    return _scrape_int(
        GDN_BLOCK_VHD,
        r"^\s*cv_x\s*:\s*in\s+std_logic_vector\("
        r"KCONV\*CONV_LANES\*(\d+)\s*-\s*1\s+downto\s+0\)",
        "port cv_x (the conv tap element width)")


def arena_sizes(cfg=None, ncards=1, include_gdn_exp=True,
                include_gdn_conv=True):
    """THE ONLY PLACE THE TWO RESERVED ARENAS ARE SIZED.

    `cfg` is a `scrape_model_cfg()` dict; None means the build target that
    `constant MODEL` selects.  Returns a dict of every intermediate as well as
    the two totals, so a caller can print the arithmetic rather than assert the
    answer.

    Every figure is DERIVED.  Nothing below is a literal except the two factors
    that are structural rather than dimensional: `2` for K and V being separate
    regions, and `8` for bits per byte."""
    if cfg is None:
        cfg = scrape_model_cfg(scrape_build_model())
    ch_b, cm_w = scrape_kv_record_terms()
    gdn_mant_w, gdn_exp_w = scrape_gdn_state_terms()
    conv_w = scrape_gdn_conv_mant_bits()

    attn_layers = cfg["blocks"] // cfg["attn_interval"]
    gdn_layers = cfg["blocks"] - attn_layers
    if cfg["lin_val_heads"] % ncards or cfg["attn_kv_heads"] % ncards:
        raise SystemExit(
            "hbm_map: the head counts do not divide across %d cards "
            "(lin_val_heads %d, attn_kv_heads %d).  model_cfg_pkg's "
            "val_heads_per_card asserts the same thing."
            % (ncards, cfg["lin_val_heads"], cfg["attn_kv_heads"]))
    val_heads = cfg["lin_val_heads"] // ncards
    kv_heads = cfg["attn_kv_heads"] // ncards
    dim = cfg["lin_head_dim"]

    # ---- GDN.  VAL_HEADS x DIM x DIM mantissas, plus VAL_HEADS x DIM column
    # exponents.  See the port list of rtl/gdn_block.vhd.
    gdn_mant_b = val_heads * dim * dim * (gdn_mant_w // 8)
    gdn_exp_b = val_heads * dim * (gdn_exp_w // 8)

    # ---- The CONV TAP HISTORY, added 2026-09-02.  THIS IS THE THIRD PIECE OF
    # PER-LAYER GDN STATE AND IT HAD NO RESERVATION AT ALL.
    #
    # `gdn_block` reads `cv_x` as "[KCONV-1 stored columns | this token's qkv]"
    # (its header, and rtl/fk33_llama_top.vhd:270 names the same buffer as one
    # "this file does not have").  A depthwise causal conv of kernel KCONV over
    # the qkv stream therefore needs the previous KCONV-1 columns of the WHOLE
    # qkv width carried from token to token, exactly like the recurrent state.
    # Without it the second token of any sequence convolves against zeros, and
    # that is a WRONG NUMBER rather than a hang -- which is why the omission
    # survived: `B_SRC_REAL` has never run past token 0 anywhere.
    #
    # `qkv_dim = 2*key_dim + val_dim` is not invented here.  It is
    # `gen_layer_program.Shape.qkv_dim` and `llama_map_pkg.qkv_dim`, and
    # `pack_model_fk33.py` already checks the packed weights against the same
    # identity.  Deriving it a fourth way would be a fourth thing to drift.
    key_dim = cfg["lin_key_heads"] // ncards * dim
    val_dim = val_heads * dim
    qkv_dim = 2 * key_dim + val_dim
    gdn_conv_b = (cfg["conv_kernel"] - 1) * qkv_dim * (conv_w // 8)

    gdn_per_layer = (gdn_mant_b
                     + (gdn_exp_b if include_gdn_exp else 0)
                     + (gdn_conv_b if include_gdn_conv else 0))

    # ---- THE LEARNED GDN CONSTANTS, added 2026-09-18 (TRACK B of the
    # constants path, docs/2026-09-18_b-constants-path.md).  A FOURTH
    # per-layer region, and unlike the three above it is written ONCE by
    # tools/pack_gdn_consts.py and only ever READ by the card: the conv
    # weights (KCONV x QKVN int16), then one 512 B scalar block holding
    # ssm_dt_bias[VAL_HEADS], ssm_a[VAL_HEADS], ssm_norm[DIM] and the six
    # exponents.  512 B is the contract's burst granule (16-beat AXI3 bursts
    # at 32 B), so the per-layer figure must stay a multiple of it, and the
    # scalar block must actually hold what it is declared to hold -- both are
    # refused here rather than left to a reader.
    gdn_const_words = cfg["conv_kernel"] * qkv_dim + GDN_CONST_SCALAR_WORDS
    gdn_const_scalar_used = 2 * val_heads + dim + GDN_CONST_N_EXP
    if gdn_const_scalar_used > GDN_CONST_SCALAR_WORDS:
        raise SystemExit(
            "hbm_map: the GDN constant scalar block needs %d words (2 x %d "
            "heads + %d dim + %d exponents) and the contract gives it %d.  "
            "The layout in docs/2026-09-18_b-constants-path.md does not hold "
            "at this shape." % (gdn_const_scalar_used, val_heads, dim,
                                GDN_CONST_N_EXP, GDN_CONST_SCALAR_WORDS))
    gdn_const_b = 2 * gdn_const_words
    if gdn_const_b % GDN_CONST_BURST_BYTES:
        raise SystemExit(
            "hbm_map: the GDN constant image is %d B per layer, which is not "
            "a multiple of the %d B burst granule; the mover cannot fetch it."
            % (gdn_const_b, GDN_CONST_BURST_BYTES))

    # ---- KV.  One record per (layer, kv_head, position) per STREAM, and K and
    # V are separate regions.
    kv_rec_b = ch_b + cfg["attn_head_dim"] * cm_w // 8
    kv_per_layer_per_token = 2 * kv_heads * kv_rec_b

    return dict(
        model_blocks=cfg["blocks"], attn_interval=cfg["attn_interval"],
        model_conv_kernel=cfg["conv_kernel"],
        ncards=ncards,
        attn_layers=attn_layers, gdn_layers=gdn_layers,
        val_heads_per_card=val_heads, kv_heads_per_card=kv_heads,
        lin_head_dim=dim, attn_head_dim=cfg["attn_head_dim"],
        max_context=cfg["max_context"],
        gdn_mant_bits=gdn_mant_w, gdn_exp_bits=gdn_exp_w,
        gdn_state_mant_bytes_per_layer=gdn_mant_b,
        gdn_state_exp_bytes_per_layer=gdn_exp_b,
        gdn_conv_mant_bits=conv_w, gdn_qkv_dim=qkv_dim,
        gdn_state_conv_bytes_per_layer=gdn_conv_b,
        gdn_state_bytes_per_layer=gdn_per_layer,
        gdn_state_bytes=gdn_layers * gdn_per_layer,
        gdn_const_layers=gdn_layers,
        gdn_const_words_per_layer=gdn_const_words,
        gdn_const_bytes_per_layer=gdn_const_b,
        gdn_const_bytes=gdn_layers * gdn_const_b,
        gdn_const_scalar_words_used=gdn_const_scalar_used,
        kv_record_hdr_bytes=ch_b, kv_mantissa_bits=cm_w,
        kv_record_bytes=kv_rec_b,
        kv_bytes_per_layer_per_token=kv_per_layer_per_token,
        kv_bytes_per_token=attn_layers * kv_per_layer_per_token,
    )


def arena_arithmetic(sz):
    """The derivation, as text, so a reader never has to trust the total."""
    return [
        "shape          %d blocks at attn_interval %d -> %d attention, %d GDN"
        % (sz["model_blocks"], sz["attn_interval"], sz["attn_layers"],
           sz["gdn_layers"]),
        "GDN per layer  %d val heads x %d x %d x %d/8 B = %d B mantissas"
        % (sz["val_heads_per_card"], sz["lin_head_dim"], sz["lin_head_dim"],
           sz["gdn_mant_bits"], sz["gdn_state_mant_bytes_per_layer"]),
        "               + %d x %d x %d/8 B = %d B column exponents"
        % (sz["val_heads_per_card"], sz["lin_head_dim"], sz["gdn_exp_bits"],
           sz["gdn_state_exp_bytes_per_layer"]),
        "               + %d x %d x %d/8 B = %d B conv tap history"
        % (sz["model_conv_kernel"] - 1, sz["gdn_qkv_dim"],
           sz["gdn_conv_mant_bits"], sz["gdn_state_conv_bytes_per_layer"]),
        "GDN total      %d layers x %d B = %d B"
        % (sz["gdn_layers"], sz["gdn_state_bytes_per_layer"],
           sz["gdn_state_bytes"]),
        "GDN consts     2 B x (%d taps x %d qkv + %d scalar words) = %d B "
        "per layer, x %d layers = %d B"
        % (sz["model_conv_kernel"], sz["gdn_qkv_dim"], GDN_CONST_SCALAR_WORDS,
           sz["gdn_const_bytes_per_layer"], sz["gdn_const_layers"],
           sz["gdn_const_bytes"]),
        "KV record      %d B header + %d x %d/8 B mantissas = %d B"
        % (sz["kv_record_hdr_bytes"], sz["attn_head_dim"],
           sz["kv_mantissa_bits"], sz["kv_record_bytes"]),
        "KV per layer   2 streams (K,V) x %d kv heads x %d B = %d B/token"
        % (sz["kv_heads_per_card"], sz["kv_record_bytes"],
           sz["kv_bytes_per_layer_per_token"]),
        "KV total       %d attention layers x %d B = %d B/token"
        % (sz["attn_layers"], sz["kv_bytes_per_layer_per_token"],
           sz["kv_bytes_per_token"]),
    ]


def shape_of_manifest(mani):
    """Which scraped model record this manifest's `output.weight` matches.

    Returns (name, cfg) or (None, None).  Matching on the lm_head's (K, M) is
    the only shape evidence a manifest carries that is independent of anything
    this file computes, which is why the check below is gated on it rather than
    on a name written into the manifest."""
    lm = next((e for e in mani.get("files", [])
               if e.get("tensor") == "output.weight"), None)
    if lm is not None:
        k, m = int(lm["K"]), int(lm["M"])
    else:
        # A layer-split card without the head (2026-09-21, two-card pipeline)
        # still records the model's n_embd and vocabulary in its host blocks,
        # which the packer derived from the GGUF's own metadata; that is the
        # same pair output.weight's shape would have given.
        hbm = mani.get("hbm") or {}
        if "host_n_embd" not in hbm or "host_n_vocab" not in hbm:
            return None, None
        k, m = int(hbm["host_n_embd"]), int(hbm["host_n_vocab"])
    try:
        txt = open(MODEL_CFG_VHD).read()
    except OSError:
        return None, None
    for nm in re.findall(r"constant\s+(\w+)\s*:\s*model_cfg_t\s*:=\s*\(", txt):
        cfg = scrape_model_cfg(nm)
        if (k, m) == (cfg["hidden"], cfg["vocab"]):
            return nm, cfg
    return None, None


def check_arenas(mani, ncards=1):
    """FAIL for every arena reserved SMALLER than the shape needs.

    UNDER-reservation is silent corruption: a 25th GDN slot in a 24-slot arena
    lands on the KV cache, and an attention layer past the end of a KV record
    lands on the next token's.  OVER-reservation only costs context, so it is a
    NOTE.  Returns (fails, notes)."""
    fails, notes = [], []
    hbm = mani.get("hbm") or {}
    name, cfg = shape_of_manifest(mani)
    if cfg is None:
        notes.append(
            "the arenas were NOT checked against the RTL shape: this "
            "manifest's output.weight matches no model_cfg_t record in "
            "rtl/model_cfg_pkg.vhd (or it carries no output.weight)")
        return fails, notes
    sz = arena_sizes(cfg, ncards)
    for key, want, what in (
            ("gdn_state_bytes", sz["gdn_state_bytes"],
             "the GDN recurrent state arena"),
            ("kv_bytes_per_token", sz["kv_bytes_per_token"],
             "the KV cache reservation per token")):
        got = hbm.get(key)
        if got is None:
            notes.append("hbm.%s is absent, so %s was not checked"
                         % (key, what))
            continue
        got = int(got)
        if got < want:
            fails.append(
                "%s: hbm.%s is %d B and the %s shape needs %d B.  "
                "UNDER-reservation is not a capacity cost, it is a "
                "neighbouring arena being overwritten -- a GDN slot past the "
                "end lands on the KV cache, and an attention layer past the "
                "end of a token's record lands on the next token's.  "
                "Derivation: %s"
                % (what, key, got, name, want, "; ".join(arena_arithmetic(sz))))
        elif got > want:
            # The excess is stated in KV TOKENS, because that is the unit it is
            # actually paid in: an over-reserved GDN arena pushes kv_base up
            # and an over-reserved per-token figure divides the arena by too
            # much.  Both come out of the same context budget.
            if key == "gdn_state_bytes":
                cost = "%d tokens of context" % (
                    (got - want) // sz["kv_bytes_per_token"])
            else:
                cost = "a context %.3fx smaller than the shape allows" % (
                    got / float(want))
            notes.append(
                "%s reserves %d B where the %s shape needs %d B (%.3fx); the "
                "excess costs %s.  Over-reservation is SAFE, so this is a "
                "note and not a fault."
                % (what, got, name, want, got / float(want), cost))
    # THE GDN CONSTANT IMAGE.  Two checks, and the second is the sharper one:
    # a region that is big enough but declares the wrong PER-LAYER STRIDE
    # serves layer L the bytes of some other layer, and every address in the
    # map is still aligned, in range and disjoint.  The stride is therefore
    # required to be exactly the derived one, not merely large enough.
    if "gdn_const_bytes" in hbm:
        got = int(hbm["gdn_const_bytes"])
        if got < sz["gdn_const_bytes"]:
            fails.append(
                "the GDN constant image: hbm.gdn_const_bytes is %d B and the "
                "%s shape needs %d B (%d layers x %d B).  The layer past the "
                "end is read from whatever sits above the region."
                % (got, name, sz["gdn_const_bytes"], sz["gdn_const_layers"],
                   sz["gdn_const_bytes_per_layer"]))
        stride = hbm.get("gdn_const_bytes_per_layer")
        if stride is not None and int(stride) != sz["gdn_const_bytes_per_layer"]:
            fails.append(
                "the GDN constant image: hbm.gdn_const_bytes_per_layer is %d "
                "and the %s shape packs %d B per layer (2 x (%d x %d + %d)).  "
                "A wrong stride hands layer L another layer's constants with "
                "no address fault."
                % (int(stride), name, sz["gdn_const_bytes_per_layer"],
                   sz["model_conv_kernel"], sz["gdn_qkv_dim"],
                   GDN_CONST_SCALAR_WORDS))
        layers = hbm.get("gdn_const_layers")
        if layers is not None and int(layers) != sz["gdn_const_layers"]:
            fails.append(
                "the GDN constant image: hbm.gdn_const_layers is %d, the %s "
                "shape has %d GDN layers." % (int(layers), name,
                                               sz["gdn_const_layers"]))
    return fails, notes


# ------------------------------------------------------------------ helpers

def h(n):
    return f"{n:#_x}"


def gib(n):
    return f"{n / 2**30:.4f} GiB"


def align_up(v, a):
    return (v + a - 1) // a * a


def align_down(v, a):
    return v // a * a


def stack_of(addr):
    return 0 if addr < STACK_LINE else 1


# ------------------------------------------------------- HBM pseudo-channels
#
# 32 pseudo-channels, 256 MiB each, DERIVED from HBM_TOP rather than re-scraped
# out of `hw/fk33/gen_pcieep.py`.  The two are cross-checked in
# `manifest_piece_fails()` P6, so a manifest that was striped at some other
# granule is a FAIL here instead of a plausible-looking map.

HBM_SEGMENTS = 32
SEGMENT_BYTES = HBM_TOP // HBM_SEGMENTS


def segment_of(addr):
    """Which HBM pseudo-channel a byte address decodes to.

    ADDRESS BITS, NEVER A LABEL.  `hw/fk33/gen_pcieep.py`'s ENGINE_ADDR block
    assigns every engine master `HBM_MEM<s>` at `s * 0x1000_0000` with range
    256M, so address bits [32:28] select the pseudo-channel and nothing else
    does.

    TRACK PACKSTRIPE's teeth case T3 is why this function exists rather than a
    read of the manifest's `segment` field: its first distinct-segment check
    counted that FIELD, so two lanes given the same `hbm_offset` with their
    labels left alone still looked like 27 distinct segments and the mutant
    survived.  A check that reads a label certifies a layout it never saw."""
    return addr // SEGMENT_BYTES


def file_pieces(e):
    """THE extents one manifest object occupies.  ONE PRODUCER, four consumers.

    v1 flat: one extent, the whole object at `hbm_offset`.

    v2 lane-striped: the object's `pieces` -- a 4 KB header plus one
    sub-region per engine master, each placed in its own 256 MiB
    pseudo-channel segment.  `hbm_offset` then names the HEADER and NOT
    `nbytes` contiguous bytes, which is what the `format` bump exists to
    announce.  A v1 consumer that reads the (hbm_offset, nbytes) pair on a v2
    object describes a region that does not exist: `tools/check_hbm_stack.py`
    PASSES over 7,154 such fictitious ranges, of which zero are real.

    THE FLAT CASE RETURNS A SYNTHETIC ONE-PIECE LIST ON PURPOSE.  Every
    consumer then runs exactly one loop over one producer, so the flat path and
    the striped path cannot drift apart -- and `--stripe-lanes` being inert on
    a flat model is checkable by comparing outputs rather than by reading code.

    This function READS.  It does not validate, and it never repairs: a reader
    that quietly fixed what it read would make `manifest_piece_fails()` unable
    to see it."""
    hbm0, nb = int(e["hbm_offset"]), int(e["nbytes"])
    pcs = e.get("pieces")
    if not pcs:
        return [dict(index=0, kind="whole", lane=None, file_offset=0,
                     hbm_offset=hbm0, nbytes=nb,
                     segment=segment_of(hbm0), segment_declared=None)]
    out = []
    for i, x in enumerate(pcs):
        a = int(x["hbm_offset"])
        out.append(dict(index=i, kind=x.get("kind"), lane=x.get("lane"),
                        file_offset=int(x["file_offset"]),
                        hbm_offset=a, nbytes=int(x["nbytes"]),
                        segment=segment_of(a),
                        segment_declared=x.get("segment")))
    return out


def stripe_lane_segments(mani):
    """The pseudo-channels a weight lane occupies, out of the manifest's own
    `lane_stripe` block.  Empty set on a FLAT manifest, which is what makes
    every rule below inert there.

    READ, never re-derived.  `pack_model_fk33.lane_stripe_plan()` chose these
    segments and recorded them; recomputing the choice here would be a second
    allocator, which is the exact defect this function exists to catch."""
    ls = (mani.get("hbm") or mani).get("lane_stripe") or {}
    return {int(x["segment"]) for x in ls.get("segments") or []}


def stripe_residency_fails(mani):
    """P7: ON A LANE-STRIPED MANIFEST, NO BYTE OF THE GDN STATE OR OF THE KV
    ARENA MAY DECODE TO A PSEUDO-CHANNEL THAT A WEIGHT LANE OCCUPIES.

    THE DEFECT THIS EXISTS FOR, MEASURED 2026-09-20 in the SHIPPED striped
    image.  `pack_model_fk33` places the GDN state at the next SEGMENT
    boundary above the weights and refuses outright if that segment belongs
    to a lane (`stripe_context_tokens()`'s docstring states the rule and
    `main()` enforces it).  `hbm_map.relayout_arenas()` then re-placed the
    same arena with a 4 KB round-up and rewrote the manifest in place, which
    pulled `gdn_state_base` from segment 27 back into segment 26 -- 26.4 MB
    of B's recurrent state and the first 2,463 tokens of the KV cache sharing
    one pseudo-channel with six weight lanes.

    WHY NO EXISTING CHECK SAW IT.  Every other rule in this file is about
    BYTES: alignment, range, the stack line, pairwise overlap.  Those bytes
    overlap nothing -- they sit in the TAIL of segment 26, above the highest
    lane arena, and `check_kv_map.py` passes them for the same reason.  The
    invariant that was violated is about the pseudo-channel the ADDRESS
    decodes to, and until this function there was no rule of that shape.

    WHAT IS DELIBERATELY NOT CHECKED, named so nothing is credited with it:
    that `gdn_state_base` is SEGMENT-aligned.  A base that is page- but not
    segment-aligned inside a RESERVED segment costs nothing -- the contention
    is a property of which pseudo-channel the bytes land on, not of where in
    it they start -- so an alignment rule here would be a rule that fires for
    a reason other than the one it names.  The alignment comes from
    `stripe_context_tokens()` being the only thing that chooses the base."""
    hbm = mani.get("hbm") or mani
    lane_segs = stripe_lane_segments(mani)
    if not lane_segs:
        # A FLAT manifest has no `lane_stripe` key at all and there is nothing
        # to say.  A manifest that HAS the block and lists no segments is a
        # different thing: MEASURED as teeth row M-C, it made the allocator
        # fall straight back to the 4 KB rule and reproduce the 2026-09-20
        # placement in silence.  An empty set is not evidence of a flat image.
        if hbm.get("lane_stripe") is not None:
            return ["PIECES P7: this manifest carries an hbm.lane_stripe "
                    "block that lists no segments.  A striped manifest whose "
                    "lane plan is empty cannot be checked against it, and "
                    "treating it as flat puts the arenas back on a 4 KB "
                    "round-up.  Refusing rather than assuming."]
        return []
    fails = []
    ceil = None
    for k in ("gdn_const_base", "desc_arena_base", "size"):
        if hbm.get(k):
            ceil = int(hbm[k])
            break
    spans = []
    if hbm.get("gdn_state_bytes"):
        spans.append(("gdn_state", int(hbm["gdn_state_base"]),
                      int(hbm["gdn_state_base"]) + int(hbm["gdn_state_bytes"])))
    if hbm.get("kv_base") is not None and ceil is not None:
        spans.append(("kv arena", int(hbm["kv_base"]), ceil))
    for name, lo, hi in spans:
        if hi <= lo:
            continue
        hit = sorted(s for s in range(segment_of(lo), segment_of(hi - 1) + 1)
                     if s in lane_segs)
        if not hit:
            continue
        s0 = hit[0]
        shared = min(hi, (s0 + 1) * SEGMENT_BYTES) - max(lo, s0 * SEGMENT_BYTES)
        fails.append(
            "PIECES P7: %s spans %s..%s, which decodes to pseudo-channel(s) "
            "%s that weight lane(s) occupy (%d byte(s) in segment %d alone).  "
            "pack_model_fk33.stripe_context_tokens() places these arenas at "
            "the next SEGMENT boundary above the weights precisely so this "
            "cannot happen; a 4 KB round-up puts them back on a lane's "
            "pseudo-channel and overlaps nothing, so no byte-range rule can "
            "see it." % (name, h(lo), h(hi),
                         ", ".join(str(s) for s in hit), shared, s0))
    return fails


def manifest_piece_fails(mani):
    """What a striped object's PIECES must satisfy that the region model cannot.

    `manifest_regions()` turns pieces into regions, so alignment, range, the
    stack line and every pairwise overlap are already checked by `check()` --
    on the real extents, which is the whole point.  What is left is the
    relation between the pieces and the FILE they were cut from, plus the two
    labels nothing else compares:

      P1  the pieces tile the file exactly, in increasing file order, from 0.
          If they do not, the whole-file blake2b that
          `fk33_load_weights.py verify` reads HBM back to check -- the only
          residency oracle in this system -- is computed over different bytes
          than the packer digested, and it would then fail for a reason nobody
          could attribute.
      P2  the pieces' bytes sum to the object's declared `nbytes`.
      P3  the object's `hbm_offset` IS its first piece's address, so a v1
          reader at least lands on the header instead of in the middle of some
          other tensor's lane arena.
      P4  the object's declared `stack` is the stack its header is really in.
          The pieces carry no declared stack, so `manifest_regions()` gives
          them none: 12 of the 27 lanes are in stack 1 by design and comparing
          them against the object's field would fail on a correct layout.
          This is where that field is checked instead.
      P5  every piece's declared `segment` agrees with the segment its ADDRESS
          decodes to.  This is the only place the label and the hardware's
          decode are ever compared.
      P6  the granule the packer scraped out of `hw/fk33/gen_pcieep.py` is the
          granule this file derives from HBM_TOP.  Striping at the wrong
          granule puts every lane back on one pseudo-channel and looks like it
          worked.

    NOT CHECKED HERE, named so nothing is credited with it: that each lane's
    pieces land in the segment that lane's engine MASTER is wired to.  That
    needs `ENG_PORT_MAP`, it is `pack_model_fk33.check_lane_stripe()` check 1,
    and it is the load-bearing one.  Nor is this a residency check: two
    tensors swapping a lane arena is a well-formed placement that every rule
    here accepts (PACKSTRIPE teeth M9)."""
    fails = []
    ls = (mani.get("hbm") or {}).get("lane_stripe") or {}
    if ls.get("segment_bytes") is not None:
        got = int(ls["segment_bytes"])
        if got != SEGMENT_BYTES:
            fails.append(
                "PIECES P6: the manifest was striped at a %d B granule and "
                "hw/fk33/gen_pcieep.py's ENGINE_ADDR block gives %d B.  At the "
                "wrong granule every lane lands back on one pseudo-channel and "
                "the map still looks striped." % (got, SEGMENT_BYTES))
    for e in mani.get("files", []):
        if not e.get("pieces"):
            continue
        name = e["file"]
        pcs = file_pieces(e)
        pos = 0
        for p in pcs:
            if p["file_offset"] != pos:
                fails.append(
                    "PIECES P1: %s piece %d starts at file +%d, the pieces "
                    "before it end at +%d.  They do not tile the file, so the "
                    "manifest's whole-file digest is not a digest of what "
                    "would be loaded." % (name, p["index"], p["file_offset"],
                                          pos))
                break
            pos += p["nbytes"]
        else:
            if pos != int(e["nbytes"]):
                fails.append(
                    "PIECES P2: %s pieces cover %d bytes, the object declares "
                    "%d" % (name, pos, int(e["nbytes"])))
        if pcs and pcs[0]["hbm_offset"] != int(e["hbm_offset"]):
            fails.append(
                "PIECES P3: %s declares hbm_offset %s and its first piece is "
                "at %s" % (name, h(int(e["hbm_offset"])),
                           h(pcs[0]["hbm_offset"])))
        if e.get("stack") is not None and \
                int(e["stack"]) != stack_of(int(e["hbm_offset"])):
            fails.append(
                "PIECES P4: %s declares stack %s, its header at %s is in "
                "stack %d" % (name, e["stack"], h(int(e["hbm_offset"])),
                              stack_of(int(e["hbm_offset"]))))
        for p in pcs:
            if p["segment_declared"] is None:
                continue
            if int(p["segment_declared"]) != p["segment"]:
                fails.append(
                    "PIECES P5: %s piece %d is labelled segment %s and its "
                    "address %s decodes to segment %d.  The label is not what "
                    "the hardware reads."
                    % (name, p["index"], p["segment_declared"],
                       h(p["hbm_offset"]), p["segment"]))
    return fails


class Region:
    """A named half-open byte range [base, base+nbytes), and WHO placed it.

    `owner` is load-bearing.  Every collision this project has had in this
    address space was between two allocators, so a region that cannot name its
    allocator cannot be argued about."""

    __slots__ = ("name", "base", "nbytes", "kind", "owner", "stack_field")

    def __init__(self, name, base, nbytes, kind, owner, stack_field=None):
        self.name, self.base, self.nbytes = name, int(base), int(nbytes)
        self.kind, self.owner, self.stack_field = kind, owner, stack_field

    @property
    def end(self):
        return self.base + self.nbytes

    def __repr__(self):
        return f"<{self.name} {h(self.base)}..{h(self.end)} by {self.owner}>"


# ------------------------------------------------------------- the producers
#
# One function per allocator.  Each one is the ONLY place its addresses are
# computed, and `--check-c` proves the second one still agrees with the C.

def manifest_regions(mani):
    """Allocator 1: `tools/pack_model_fk33.py`, read back out of its manifest.

    Read, never re-derived: the packer's placement IS the ground truth for the
    weight image, and a second derivation of it here would be a claim, not a
    check.  What IS checked (in `check_map`) is that the manifest's own
    summary fields agree with its own placements."""
    hbm = mani.get("hbm", {})
    out = []
    for e in mani["files"]:
        pcs = file_pieces(e)
        if len(pcs) == 1 and not e.get("pieces"):
            out.append(Region(e["file"], e["hbm_offset"], e["nbytes"],
                              e["kind"], "pack_model_fk33.py", e.get("stack")))
            continue
        # A LANE-STRIPED OBJECT IS ONE FILE AT UP TO 28 ADDRESSES.  One Region
        # each, named `file:index`, so a collision report says WHICH
        # sub-region.  They carry no declared stack because the manifest gives
        # a piece none, and inventing one from the address would be a check
        # comparing a value to itself; the object's own `stack` field is
        # checked against its header in `manifest_piece_fails()` P4 instead.
        for p in pcs:
            out.append(Region("%s:%d" % (e["file"], p["index"]),
                              p["hbm_offset"], p["nbytes"], e["kind"],
                              "pack_model_fk33.py", None))
    if hbm.get("gdn_state_bytes"):
        out.append(Region("<gdn recurrent state>", hbm["gdn_state_base"],
                          hbm["gdn_state_bytes"], "gdn",
                          "pack_model_fk33.py", hbm.get("gdn_state_stack")))
    for i, ext in enumerate(hbm.get("kv_extents", [])):
        out.append(Region(f"<kv arena {i}>", ext["base"], ext["nbytes"], "kv",
                          "pack_model_fk33.py", ext.get("stack")))
    if hbm.get("gdn_const_bytes"):
        # Placed by derive_gdn_const_block() below, at pack_gdn_consts.py's
        # request: the one region in this map that is written once and only
        # read by the card.
        out.append(Region("<gdn constants>", hbm["gdn_const_base"],
                          hbm["gdn_const_bytes"], "gdn_const",
                          "pack_gdn_consts.py", hbm.get("gdn_const_stack")))
    return out


def host_blocks(n_embd, n_vocab, max_chunk, hbm_top=None):
    """Allocator 3: `server/pl_backend.c::pl_derive_bases()`, mirrored.

    A MIRROR IS NOT EVIDENCE.  This is arithmetic in Python that claims to
    equal arithmetic in C, and the claim is worth exactly as much as the test
    that checks it: `check_against_c()` compiles `server/pl_backend.c` and
    requires every address to match.  Run it, do not trust this.

    Returns (regions, dict of the raw numbers)."""
    top = HBM_TOP if hbm_top is None else int(hbm_top)
    x_stride = align_up(SEAM_HDR_BYTES + 2 * n_embd, BLOCK_ALIGN)
    l_stride = align_up(SEAM_HDR_BYTES + 4 * n_vocab, BLOCK_ALIGN)
    x_span = x_stride * max_chunk
    l_span = l_stride
    desc_span = PAGE
    desc_ptr = align_down(align_down(top, PAGE) - desc_span, PAGE)
    l_base = align_down(desc_ptr - l_span, PAGE)
    x_base = align_down(l_base - x_span, PAGE)
    regs = [
        Region("<host R_X staging>", x_base, x_span, "host", "pl_derive_bases()"),
        Region("<host logits writeback>", l_base, l_span, "host",
               "pl_derive_bases()"),
        Region("<host D program>", desc_ptr, desc_span, "host",
               "pl_derive_bases()"),
    ]
    raw = dict(x_base=x_base, x_span=x_span, l_base=l_base, l_span=l_span,
               desc_ptr=desc_ptr, desc_span=desc_span, hbm_top=top)
    return regs, raw


# The keys the manifest's `hbm` object carries under the decided mechanism.
# REQUIRED_HBM_KEYS are the ones `server/fk33_manifest.c` also requires, so a
# manifest either states them or is refused on both sides of the language
# boundary.  The rest are provenance: they let a reader see WHAT the address was
# derived from without re-deriving it.
REQUIRED_HBM_KEYS = ("desc_arena_base", "desc_arena_bytes", "host_max_chunk")
PROVENANCE_HBM_KEYS = ("desc_arena_jobs", "desc_arena_stride",
                       "host_n_embd", "host_n_vocab",
                       "host_x_base", "host_l_base", "host_desc_ptr")
REGION_BLOCK_KEYS = REQUIRED_HBM_KEYS + PROVENANCE_HBM_KEYS


class NoRegionBlock(Exception):
    """The manifest does not declare the arena, so there is nothing to read.

    Raised, never defaulted.  A default here would be a second allocator with
    a different address, which is the entire defect this file exists to end."""


def manifest_arena(mani):
    """THE AUTHORITY.  Read the arena out of the manifest's `hbm` block.

    No arithmetic.  If the block is absent this raises `NoRegionBlock`; the
    caller decides whether that is a refusal (every PRODUCER: yes) or a
    reported gap (an AUDITOR over a pre-block set: yes, loudly)."""
    hbm = (mani.get("hbm") or {}) if isinstance(mani, dict) else {}
    missing = [k for k in REQUIRED_HBM_KEYS if k not in hbm]
    if missing:
        raise NoRegionBlock(
            "the manifest's hbm block does not declare " + ", ".join(missing)
            + ".  The descriptor arena is declared in the manifest and read "
              "from it; nothing re-derives it.  Run "
              "`python3 tools/hbm_map.py <manifest> --write-manifest-hbm` on a "
              "set packed before the block existed, or repack.")
    base = int(hbm["desc_arena_base"])
    nbytes = int(hbm["desc_arena_bytes"])
    return base, nbytes, int(hbm["host_max_chunk"])


def desc_arena(n_jobs, base=None, policy="allocate-below-host",
               host_floor=None, stride=None, strict=True):
    """Allocator 2: the subsystem A descriptor arena.

    `policy`:
      allocate-below-host  the first 4 KB-aligned block below `host_floor`
                   (which is pl_derive_bases()'s x_base).  THIS IS THE
                   ALLOCATION RULE, and it runs at PACK time only -- see
                   `derive_region_block()`.  A consumer never reaches it.
      top-down     `(hbm_top - need) & ~0xFFF`, the historic placement.  It
                   COLLIDES with the host blocks at the 9B shape and is kept
                   so the check can be shown going red.

    An explicit `base` overrides the policy and is checked like any other;
    `policy="manifest"` is handled by the caller, which supplies that base."""
    if not n_jobs:
        return [], None
    stride = DESC_STRIDE if stride is None else stride
    need = align_up(stride * n_jobs, PAGE)
    if base is None:
        if policy == "top-down":
            base = align_down(HBM_TOP - stride * n_jobs, PAGE)
        elif policy in ("allocate-below-host", "below-host"):
            if host_floor is None:
                # NO HOST BLOCKS MEANS NO FLOOR TO SIT UNDER.  A producer that
                # is about to emit descriptors must not guess (strict=True, it
                # raises); an auditor over a manifest that carries no
                # `output.weight` -- the loader's synthetic selfcheck images do
                # not -- should report the gap and carry on, because a tool
                # that refuses to run is a tool nobody runs.
                if strict:
                    raise SystemExit(
                        "hbm_map: --policy allocate-below-host needs the host "
                        "blocks, and they were not modelled.  Placing the "
                        "arena without them is exactly the blindness this file "
                        "exists to remove; pass --desc-base to say where it "
                        "goes instead.")
                return [], None
            base = align_down(host_floor - need, PAGE)
        else:
            raise SystemExit("hbm_map: unknown arena policy %r" % policy)
    return [Region("<A descriptor arena>", base, need, "desc",
                   "gen_layer_program.py", stack_of(base))], base


# ------------------------------------------------------------------ the map

class HbmMap:
    def __init__(self, regions, hbm, notes=None, hbm_top=HBM_TOP):
        self.regions = list(regions)
        self.hbm = dict(hbm or {})
        self.notes = list(notes or [])
        self.hbm_top = hbm_top
        # Faults that are not about a pair of addresses: a max_chunk that does
        # not match the one the arena was placed under, and a reservation that
        # is in the right place but too small for the program.  They are FAILs
        # like any other and are appended by check().
        self.extra_fails = []
        self.declared_host = {}

    def by_kind(self, *kinds):
        return [r for r in self.regions if r.kind in kinds]

    def carve_kv(self):
        """The KV arena is DEFINED as everything from the end of the GDN state
        to the end of the device, so every top-anchored reservation overlaps it
        BY CONSTRUCTION.  That is a capacity CHARGE, not a collision, and
        reporting it as a fault would be noise that hides the real one.  Shrink
        the arena to the lowest top-anchored base and restate the context.

        An overlap between two TOP-ANCHORED regions is a different thing and
        stays a FAIL."""
        top = [r for r in self.regions
               if r.kind in ("host", "desc", "gdn_const")]
        per = int(self.hbm.get("kv_bytes_per_token", 0)) or 1
        charged = 0
        for r in self.regions:
            if r.kind != "kv":
                continue
            # ONLY a reservation that sits INSIDE this extent is a charge.  An
            # earlier version took min() over every top-anchored base, so a
            # mutation that put the arena at address 0 shrank the KV arena to
            # zero bytes and the first reported fault was "nbytes 0 is not
            # positive" -- true, and not the fault anyone was looking for.  A
            # reservation BELOW the arena is a collision with whatever is down
            # there, and the overlap check says so on its own.
            inside = [t.base for t in top if r.base <= t.base < r.end]
            if not inside:
                continue
            floor_ = min(inside)
            cut = r.end - floor_
            charged += cut
            r.nbytes = max(0, r.nbytes - cut)
            self.notes.append(
                f"{r.name} shortened to {h(floor_)} by the top-anchored "
                f"reservations: {cut:,} B = {cut // per} tokens")
        return charged, charged // per

    # -------------------------------------------------------------- checks
    def check(self):
        """Every finding is a FAIL.  Returns a list of strings; empty is PASS.

        Teeth, in the order they were shown to bite (see the write-up):
          * an unaligned base;
          * a region outside the map, or with a non-positive length;
          * a region that CONTAINS the 4 GiB stack line strictly inside it --
            an out-of-stack read does not fault, it returns the wrong bytes and
            reports success;
          * a declared `stack` that is not the stack the base is really in;
          * ANY pairwise overlap, across ALL allocators.  This is the one that
            was missing: the two producers each checked their own regions."""
        fails = list(self.extra_fails)
        # THE MANIFEST'S OWN HOST BLOCKS, AGAINST THE MIRROR.  The block records
        # what pl_derive_bases() produced at pack time; if the mirror here no
        # longer reproduces them the manifest is describing a layout this tool
        # can no longer build, and every base below it is suspect.
        for key, name in (("host_x_base", "<host R_X staging>"),
                          ("host_l_base", "<host logits writeback>"),
                          ("host_desc_ptr", "<host D program>")):
            if key not in self.declared_host:
                continue
            got = next((r.base for r in self.regions if r.name == name), None)
            if got is None:
                continue
            if int(self.declared_host[key]) != int(got):
                fails.append(
                    f"the manifest declares hbm.{key} = "
                    f"{h(int(self.declared_host[key]))} but this map places "
                    f"{name} at {h(got)}")
        for r in self.regions:
            if r.base % PAGE:
                fails.append(f"{r.name}: base {h(r.base)} is not 4 KB aligned "
                             f"(placed by {r.owner})")
            if r.base < 0 or r.end > self.hbm_top:
                fails.append(f"{r.name}: {h(r.base)}..{h(r.end)} is outside "
                             f"the {gib(self.hbm_top)} map (placed by {r.owner})")
            if r.nbytes <= 0:
                fails.append(f"{r.name}: nbytes {r.nbytes} is not positive")
            if r.base < STACK_LINE < r.end:
                fails.append(
                    f"{r.name}: {h(r.base)}..{h(r.end)} CONTAINS the stack "
                    f"line {h(STACK_LINE)}; an out-of-stack read does not "
                    f"fault, it returns the wrong bytes and reports success")
            if r.stack_field is not None and stack_of(r.base) != r.stack_field:
                fails.append(f"{r.name}: manifest says stack {r.stack_field}, "
                             f"base {h(r.base)} is in stack {stack_of(r.base)}")

        order = sorted(self.regions, key=lambda r: (r.base, r.end))
        for a, b in zip(order, order[1:]):
            if b.base < a.end:
                fails.append(
                    f"OVERLAP: {a.name} {h(a.base)}..{h(a.end)} "
                    f"(placed by {a.owner}) and {b.name} "
                    f"{h(b.base)}..{h(b.end)} (placed by {b.owner}) share "
                    f"{min(a.end, b.end) - b.base} bytes")
        return fails

    # -------------------------------------------------------------- report
    def rows(self):
        placed = [r for r in self.regions if r.kind in ("mv4i", "f32blob")]
        out = []
        if placed:
            order_p = sorted(placed, key=lambda r: r.base)
            holes = sum(b.base - a.end for a, b in zip(order_p, order_p[1:]))
            out.append(("packed weights + F32 blob", order_p[0].base,
                        sum(r.nbytes for r in placed), "pack_model_fk33.py",
                        f"{len(placed)} objects, {holes} B of stack-line hole"))
        for r in self.regions:
            if r.kind in ("mv4i", "f32blob"):
                continue
            note = ""
            if r.kind == "kv":
                per = int(self.hbm.get("kv_bytes_per_token", 1)) or 1
                note = f"{r.nbytes // per} tokens at {per} B/token, after the charge"
            elif r.kind in ("host", "desc"):
                note = "NOT reserved by the manifest"
            elif r.kind == "gdn_const":
                note = (f"{self.hbm.get('gdn_const_layers', '?')} layers x "
                        f"{self.hbm.get('gdn_const_bytes_per_layer', '?')} B, "
                        f"read-only to the card")
            out.append((r.name.strip("<>"), r.base, r.nbytes, r.owner, note))
        out.sort(key=lambda t: t[1])
        return out

    def print_report(self, markdown=False):
        rows = self.rows()
        if markdown:
            print("| region | base | end | bytes | GiB | placed by | note |")
            print("|---|---|---|---|---|---|---|")
            for n, b, nb, own, note in rows:
                print(f"| {n} | `{h(b)}` | `{h(b + nb)}` | {nb:,} | "
                      f"{nb / 2**30:.4f} | `{own}` | {note} |")
        else:
            print(f"{'region':28s} {'base':>14s} {'end':>14s} {'bytes':>15s}  "
                  f"{'GiB':>8s}  {'placed by':22s} note")
            for n, b, nb, own, note in rows:
                print(f"{n:28s} {h(b):>14s} {h(b + nb):>14s} {nb:>15,}  "
                      f"{nb / 2**30:8.4f}  {own:22s} {note}")
        print()
        acc = sum(nb for _, _, nb, _, _ in rows)
        placed = [r for r in self.regions if r.kind in ("mv4i", "f32blob")]
        if placed:
            order_p = sorted(placed, key=lambda r: r.base)
            acc += sum(b.base - a.end for a, b in zip(order_p, order_p[1:]))
        print(f"device      {self.hbm_top:,} B = {gib(self.hbm_top)}")
        print(f"accounted   {acc:,} B = {gib(acc)}")
        print(f"unaccounted {self.hbm_top - acc:,} B")
        for n in self.notes:
            print(f"note: {n}")

    def to_json(self):
        return dict(
            hbm_top=self.hbm_top, stack_line=STACK_LINE,
            block_align=BLOCK_ALIGN, seam_hdr_bytes=SEAM_HDR_BYTES,
            desc_stride=DESC_STRIDE,
            regions=[dict(name=r.name, base=r.base, end=r.end,
                          nbytes=r.nbytes, kind=r.kind, owner=r.owner)
                     for r in sorted(self.regions, key=lambda r: r.base)],
            notes=self.notes)


# ------------------------------------------------------------------- plan()

def plan(mani, desc_jobs=311, desc_base=None, policy="manifest",
         max_chunk=None, want_host_blocks=True, n_embd=None, n_vocab=None,
         strict_arena=False, _allow_chunk_mismatch=False):
    """THE ONE ENTRY POINT.  Build the whole map from a manifest.

    `mani` is a parsed manifest dict or a path to one.  Returns an `HbmMap`.
    Nothing here opens a payload file or a device.

    `policy="manifest"` (the DEFAULT, and what every consumer uses) takes the
    arena base and `max_chunk` straight out of the manifest's region block and
    performs NO placement arithmetic at all.  The other policies exist for the
    two callers that are allowed to allocate: `derive_region_block()` at pack
    time, and the teeth.

    `max_chunk=None` means "the manifest's `hbm.host_max_chunk`".  An explicit
    value is honoured and, when the manifest also states one and they differ,
    the disagreement is recorded as a FAIL rather than silently preferred:
    the arena was placed under ONE cap and only that cap reproduces the map.

    ORDER MATTERS AND IS NOT ARBITRARY.  The host blocks are placed FIRST,
    because the allocation rule puts the descriptor arena underneath them, and
    because that is the order the shipping code already has: the host's blocks
    come from the card's own CAPS at open time, and the arena is built offline
    by a tool that can be told where to go."""
    if isinstance(mani, str):
        with open(mani) as f:
            mani = json.load(f)
    hbm = mani.get("hbm", {})
    top = int(hbm.get("size", HBM_TOP))
    notes = []
    regions = manifest_regions(mani)
    declared_chunk = hbm.get("host_max_chunk")

    # THE CAP THE ARENA WAS PLACED UNDER.  Not a preference: a cap the map was
    # not built for produces different host blocks and therefore a different
    # answer to "is this disjoint".
    chunk_fail = None
    if max_chunk is None:
        if declared_chunk is None:
            max_chunk = 512
            notes.append(
                "no hbm.host_max_chunk in this manifest, so max_chunk 512 was "
                "ASSUMED.  The host blocks below are a guess at what "
                "pl_derive_bases() will do, not a reading of what was declared.")
        else:
            max_chunk = int(declared_chunk)
    elif (declared_chunk is not None and not _allow_chunk_mismatch
          and int(max_chunk) > int(declared_chunk)):
        # ONE DIRECTION ONLY.  x_base = align_down(l_base - x_stride*max_chunk)
        # decreases monotonically in max_chunk, so a SMALLER cap can only move
        # x_base up, away from the arena: a gap, never an overlap.  A LARGER
        # cap moves it down through a fixed arena, which is the hazard.
        chunk_fail = (
            "max_chunk %d was asked for, but the manifest pinned "
            "hbm.host_max_chunk = %d and the arena was placed under THAT cap.  "
            "A LARGER cap drags x_base DOWN through the arena and the map is "
            "no longer the one that was checked."
            % (int(max_chunk), int(declared_chunk)))

    host_floor = None
    if want_host_blocks:
        if n_embd is None or n_vocab is None:
            lm = next((e for e in mani["files"]
                       if e.get("tensor") == "output.weight"), None)
            if lm is None:
                notes.append("no output.weight in the manifest, so n_embd and "
                             "n_vocab could not be inferred; the host blocks "
                             "are NOT modelled and no overlap with them can "
                             "be checked")
                want_host_blocks = False
            else:
                n_embd = n_embd if n_embd is not None else int(lm["K"])
                n_vocab = n_vocab if n_vocab is not None else int(lm["M"])
    if want_host_blocks:
        hb, raw = host_blocks(n_embd, n_vocab, max_chunk, top)
        regions += hb
        host_floor = raw["x_base"]
        notes.append(
            f"host blocks mirrored from pl_derive_bases() at n_embd={n_embd} "
            f"n_vocab={n_vocab} max_chunk={max_chunk}: {top - raw['x_base']:,} B "
            f"from {h(raw['x_base'])} to the top.  max_chunk is a RUNTIME cap "
            f"from CAPS, not a manifest field: a larger one moves x_base DOWN "
            f"and the arena with it.")

    # ------------------------------------------------------------ the arena
    #
    # THE DEFAULT PATH DOES NO ARITHMETIC.  It reads.  `arena_bytes_declared`
    # is kept so `check()` can compare the reservation against what the
    # program actually needs -- a block that is in the right place but too
    # SMALL is a real failure the address model can see, unlike a block that
    # holds the wrong descriptors, which it never can.
    arena_fail = None
    block_fail = None
    declared_bytes = None
    if policy == "manifest" and desc_base is None:
        try:
            base, declared_bytes, _ = manifest_arena(mani)
        except NoRegionBlock as e:
            # A PRODUCER raises; an AUDITOR reports -- but reports it as a
            # FAIL, not a note.  ADDRARENA left the absence of an arena as a
            # printed warning on the C side and named that as the live hazard;
            # the same hazard on this side would be a green map over a set
            # whose descriptors nothing has placed.  A tool that refuses to
            # RUN is a tool nobody runs, so the map is still built and still
            # printed; what it is not is PASS.
            if strict_arena:
                raise SystemExit("hbm_map: " + str(e))
            block_fail = "NO REGION BLOCK: " + str(e)
            da, base = [], None
        else:
            da = [Region("<A descriptor arena>", base, declared_bytes, "desc",
                         "manifest hbm.desc_arena_base", stack_of(base))]
            need = align_up(DESC_STRIDE * desc_jobs, PAGE) if desc_jobs else 0
            if need > declared_bytes:
                arena_fail = (
                    "<A descriptor arena>: the manifest reserves %d B but %d "
                    "jobs at %d B/descriptor need %d B.  The reservation is in "
                    "the right place and TOO SMALL, so the tail of the program "
                    "would run past it into %s."
                    % (declared_bytes, desc_jobs, DESC_STRIDE, need,
                       "the host R_X staging"))
    else:
        da, base = desc_arena(desc_jobs, desc_base, policy, host_floor,
                              strict=strict_arena)
    regions += da
    if desc_jobs and not da:
        notes.append(
            "NO DESCRIPTOR ARENA IS IN THIS MAP.  Nothing here has checked "
            "where gen_layer_program.py's descriptors go.")
    if da:
        if policy == "manifest" and desc_base is None:
            notes.append(
                f"descriptor arena READ from the manifest at {h(base)}, "
                f"{declared_bytes} B.  Nothing here placed it; "
                f"tools/pack_model_fk33.py did, once, at pack time.")
        elif desc_base is not None:
            notes.append(f"descriptor arena base given explicitly: {h(base)}")
        elif policy == "top-down":
            notes.append(
                f"descriptor arena at gen_layer_program.py's HISTORIC top-down "
                f"default {h(base)}.  This is the placement that collides.")
        else:
            notes.append(
                f"descriptor arena ALLOCATED by rule 'allocate-below-host' at "
                f"{h(base)}: the first 4 KB block below the host's R_X "
                f"staging.  This rule runs at PACK time; a consumer reads the "
                f"answer out of the manifest instead.")

    # THE TWO ARENAS NOTHING ALLOCATES WITHIN.  Reported, not modelled: a
    # Region per KV slot would be ~490k regions at the 9B shape and the report
    # would be unreadable.  What the manifest now declares is the SUB-STRUCTURE
    # -- how many layers and at what stride -- which is the input a future
    # per-slot check needs and which nothing wrote down before.
    if "gdn_state_layers" in hbm:
        notes.append(
            "GDN state sub-structure DECLARED but not allocated within: %d "
            "layers x %d B (%d used by the program).  Nothing places a slot "
            "inside this extent, so nothing can check one."
            % (hbm["gdn_state_layers"], hbm.get("gdn_state_bytes_per_layer", 0),
               hbm.get("gdn_state_layers_used", -1)))
    if "kv_layers" in hbm:
        notes.append(
            "KV sub-structure DECLARED but not allocated within: %d attention "
            "layers x %d B per token (%d used).  Same limit."
            % (hbm["kv_layers"], hbm.get("kv_bytes_per_layer_per_token", 0),
               hbm.get("kv_layers_used", -1)))

    # THE TWO RESERVED ARENAS, AGAINST THE RTL SHAPE.  This is the ONLY check
    # in this file that is not about a pair of addresses: `gdn_state_bytes` and
    # `kv_bytes_per_token` are SIZES, and a size that is too small does not
    # overlap anything in this map -- the arena it corrupts is the one it grows
    # into, which the map models as a single opaque extent.  So no amount of
    # overlap checking can see it, and it is checked here instead, against
    # `rtl/model_cfg_pkg.vhd` rather than against a constant.
    arena_fails, arena_notes = check_arenas(mani)
    notes.extend(arena_notes)

    m = HbmMap(regions, hbm, notes, top)
    m.extra_fails = [s for s in (block_fail, chunk_fail, arena_fail) if s] \
        + arena_fails + manifest_piece_fails(mani) \
        + stripe_residency_fails(mani)
    # THE DECLARED HOST BLOCKS ARE A FACT ABOUT `host_max_chunk`, so they are
    # only comparable when this map was built at that cap.  Comparing them at
    # any other cap would report a disagreement that is simply the cap doing
    # what a cap does, and a check that fires for the wrong reason is not
    # measuring the thing it names.
    if declared_chunk is None or int(declared_chunk) == int(max_chunk):
        m.declared_host = {k: hbm[k] for k in
                           ("host_x_base", "host_l_base", "host_desc_ptr")
                           if k in hbm}
    m.carve_kv()
    return m


# ------------------------------------------------- the ONE allocator, at pack time

def derive_region_block(mani, desc_jobs, max_chunk=512, n_embd=None,
                        n_vocab=None):
    """THE ONLY PLACE IN THIS REPOSITORY THAT CHOOSES AN ARENA ADDRESS.

    Called by `tools/pack_model_fk33.py` while it is writing the manifest, and
    by `--write-manifest-hbm` for a set packed before the block existed.
    Returns the dict that goes into the manifest's `hbm` object.

    It REFUSES rather than returning a block it cannot stand behind: if the
    resulting map has any overlap, no block is written, because a declared
    address that collides is worse than an absent one -- absent is loud."""
    if isinstance(mani, str):
        with open(mani) as f:
            mani = json.load(f)
    if desc_jobs <= 0:
        raise SystemExit("hbm_map: derive_region_block needs a positive job "
                         "count; 0 would reserve nothing and mean 'no A'.")
    lm = next((e for e in mani["files"] if e.get("tensor") == "output.weight"),
              None)
    if n_embd is None or n_vocab is None:
        if lm is None:
            raise SystemExit(
                "hbm_map: no output.weight in this manifest, so the host "
                "blocks cannot be modelled and the arena has no floor to sit "
                "under.  Pass n_embd/n_vocab explicitly.")
        n_embd = n_embd if n_embd is not None else int(lm["K"])
        n_vocab = n_vocab if n_vocab is not None else int(lm["M"])
    top = int(mani.get("hbm", {}).get("size", HBM_TOP))
    _, raw = host_blocks(n_embd, n_vocab, max_chunk, top)
    da, base = desc_arena(desc_jobs, None, "allocate-below-host",
                          raw["x_base"], strict=True)
    blk = {
        "desc_arena_base": int(base),
        "desc_arena_bytes": int(da[0].nbytes),
        "desc_arena_jobs": int(desc_jobs),
        "desc_arena_stride": int(DESC_STRIDE),
        "host_max_chunk": int(max_chunk),
        "host_n_embd": int(n_embd),
        "host_n_vocab": int(n_vocab),
        "host_x_base": int(raw["x_base"]),
        "host_l_base": int(raw["l_base"]),
        "host_desc_ptr": int(raw["desc_ptr"]),
    }
    # Stand behind it: build the whole map with the block installed and require
    # it to be clean before handing it back.
    trial = json.loads(json.dumps(mani))
    trial.setdefault("hbm", {}).update(blk)
    m = plan(trial, desc_jobs=desc_jobs, policy="manifest", strict_arena=True)
    fails = m.check()
    if fails:
        raise SystemExit(
            "hbm_map: REFUSING to declare a descriptor arena -- the map that "
            "results has %d fault(s):\n" % len(fails)
            + "\n".join("  " + s for s in fails))
    return blk


def kv_extents_below(kv_base, cap, top, stack, per):
    """The KV arena as per-stack extents from `kv_base` up to `cap`.

    `pack_model_fk33.py`'s rule, restated with a CEILING: the region is split
    at every stack boundary and whole records counted inside each extent, so a
    record cannot straddle the line.  `cap` is the lowest address the arena
    may not reach -- `top` when nothing is reserved above it, and
    `gdn_const_base` once the constant image is placed, because that image is
    the one top-anchored region the manifest itself declares and the context
    figure it publishes must not count bytes the card cannot cache into."""
    extents, q = [], int(kv_base)
    cap = min(int(cap), int(top))
    while q < cap:
        e = min((q // stack + 1) * stack, cap)
        extents.append(dict(base=q, nbytes=e - q, stack=stack_of(q),
                            tokens=(e - q) // per))
        q = e
    return extents


def derive_gdn_const_block(mani, ncards=1):
    """THE ONLY PLACE THAT CHOOSES WHERE THE GDN CONSTANT IMAGE LIVES.

    Called by `tools/pack_gdn_consts.py` after it has packed the image, and by
    `--write-manifest-gdn-const`.  Returns the dict that goes into the
    manifest's `hbm` object.

    THE RULE: the first 4 KB-aligned block BELOW `desc_arena_base` that holds
    the whole image.  Nothing already placed moves -- the weights, the GDN
    state, `kv_base`, the descriptor arena and the host blocks all keep their
    addresses -- and the image is paid for out of the KV arena's top, which is
    the same account the descriptor arena and the host blocks are charged to.
    The KV extents are therefore RE-CAPPED at the new base and
    `max_context_tokens` / `free_after_gdn` recomputed, so the figure the
    manifest publishes is the context the card can actually hold.

    It REFUSES rather than returning a block it cannot stand behind: the
    manifest must already carry the region block (the arena is the floor this
    sits under, and a floor nobody declared is not a floor), the shape must
    match a model_cfg_t record (the size is derived, never typed), and the
    resulting map must check clean."""
    if isinstance(mani, str):
        with open(mani) as f:
            mani = json.load(f)
    hbm = mani.get("hbm") or {}
    name, cfg = shape_of_manifest(mani)
    if cfg is None:
        raise SystemExit(
            "hbm_map: this manifest's output.weight matches no model_cfg_t "
            "record in rtl/model_cfg_pkg.vhd, so the GDN constant image has "
            "no derived size.  Refusing rather than guessing.")
    sz = arena_sizes(cfg, ncards)
    try:
        desc_base, _, _ = manifest_arena(mani)
    except NoRegionBlock as e:
        raise SystemExit("hbm_map: " + str(e))
    for k in ("kv_base", "kv_bytes_per_token"):
        if k not in hbm:
            raise SystemExit("hbm_map: the manifest declares no hbm.%s, so "
                             "the KV arena cannot be re-capped under the "
                             "constant image." % k)
    top = int(hbm.get("size", HBM_TOP))
    stack = int(hbm.get("stack_bytes", STACK_LINE))
    need = align_up(sz["gdn_const_bytes"], PAGE)
    base = align_down(desc_base - need, PAGE)
    per = int(hbm["kv_bytes_per_token"])
    extents = kv_extents_below(hbm["kv_base"], base, top, stack, per)
    kv_total = sum(x["nbytes"] for x in extents)
    blk = {
        "gdn_const_base": int(base),
        "gdn_const_bytes": int(sz["gdn_const_bytes"]),
        "gdn_const_stack": stack_of(base),
        "gdn_const_layers": int(sz["gdn_const_layers"]),
        "gdn_const_bytes_per_layer": int(sz["gdn_const_bytes_per_layer"]),
        "gdn_const_words_per_layer": int(sz["gdn_const_words_per_layer"]),
        "gdn_const_placement": "first 4 KB block below hbm.desc_arena_base, "
                               "by tools/hbm_map.py derive_gdn_const_block()",
        "kv_extents": extents,
        "free_after_gdn": int(kv_total),
        "max_context_tokens": int(sum(x["tokens"] for x in extents)),
    }
    trial = json.loads(json.dumps(mani))
    trial.setdefault("hbm", {}).update(blk)
    m = plan(trial, policy="manifest", strict_arena=True)
    fails = m.check()
    if fails:
        raise SystemExit(
            "hbm_map: REFUSING to declare a GDN constant region -- the map "
            "that results has %d fault(s):\n" % len(fails)
            + "\n".join("  " + s for s in fails))
    return blk


def write_gdn_const_block(path, blk, extra=None):
    """Install `derive_gdn_const_block()`'s dict (plus `extra`, the packer's
    digest and file name) into a manifest, atomically, keeping a
    `.bak-gdnconst`.  Additive on every key but the three KV figures it
    re-caps (`kv_extents`, `free_after_gdn`, `max_context_tokens`), which is
    the whole point of the re-cap: a reader that predates the region still
    parses, and the context figure it reads is the true one."""
    with open(path) as f:
        mani = json.load(f)
    if "hbm" not in mani:
        raise SystemExit("hbm_map: %s has no top-level hbm object" % path)
    keys = list(blk) + list(extra or {})
    before = {k: mani["hbm"].get(k) for k in keys}
    mani["hbm"].update(blk)
    if extra:
        mani["hbm"].update(extra)
    bak = path + ".bak-gdnconst"
    if not os.path.exists(bak):
        with open(bak, "w") as f:
            json.dump(json.load(open(path)), f, indent=1)
    tmp = path + ".tmp-gdnconst"
    with open(tmp, "w") as f:
        json.dump(mani, f, indent=1)
    os.replace(tmp, path)
    return before, bak


def relayout_arenas(mani, ncards=1):
    """Re-place the GDN state and the KV arena at the size the SHAPE needs.

    THE MIGRATION FOR A SET PACKED AGAINST THE 27B LITERALS.  A repack is the
    honest way to fix a manifest, and it is not available: a real pack needs
    the 18 GB GGUF and hours, on a root filesystem at 97 percent.  What this
    does instead is recompute the ONLY fields that depend on the two arena
    sizes and leave every placed tensor exactly where it is -- which is sound
    because the weight image ends at `weights_end` and both arenas begin after
    it.  Nothing that is already resident in HBM moves.

    The placement rule is `pack_model_fk33.place()`, imported rather than
    reimplemented: the stack-boundary rule that says an object may not straddle
    the 4 GiB line is that function's, and a second copy of it here would be a
    fourth model of this address space.  The import is deferred because
    `pack_model_fk33` imports THIS module at load time.

    Returns (new_hbm_dict, before_dict) without writing anything."""
    import pack_model_fk33 as PK

    hbm = dict(mani["hbm"])
    before = {k: hbm.get(k) for k in
              ("gdn_state_base", "gdn_state_bytes", "gdn_state_stack",
               "kv_base", "kv_bytes_per_token", "kv_extents",
               "free_after_gdn", "max_context_tokens",
               "gdn_state_layers", "gdn_state_bytes_per_layer",
               "kv_layers", "kv_bytes_per_layer_per_token")}

    name, cfg = shape_of_manifest(mani)
    if cfg is None:
        raise SystemExit(
            "hbm_map: this manifest's output.weight matches no model_cfg_t "
            "record in rtl/model_cfg_pkg.vhd, so there is no shape to size the "
            "arenas from.  Refusing rather than guessing.")
    sz = arena_sizes(cfg, ncards)

    top = int(hbm.get("size", HBM_TOP))
    stack = int(hbm.get("stack_bytes", 4 * 1024 ** 3))
    weights_end = int(hbm["weights_end"])
    gdn_bytes = sz["gdn_state_bytes"]
    per = sz["kv_bytes_per_token"]

    # THE PLACEMENT RULE IS THE PACKER'S, CALLED, NOT RESTATED.  On a LANE-
    # STRIPED manifest the GDN state and the KV cache start at the next
    # SEGMENT boundary above the weights, not at the next 4 KB page, so the
    # state does not share the top lane's pseudo-channel.
    # `pack_model_fk33.stripe_context_tokens()` is where that rule lives and
    # its docstring is where it is argued; CALLING it is the only form that
    # cannot drift from the packer.  Until 2026-09-20 this function used
    # `PK.place()` unconditionally and silently undid the packer's choice in
    # the SHIPPED image -- see docs/debugging/2026-09-20_stripe-width-after-
    # the-kv-halved.md section 4.11, and section 11 for the fix.
    segment_pad = 0
    # THE BLOCK'S PRESENCE, NOT ITS CONTENTS.  Branching on a non-empty
    # segment set let a `lane_stripe` block with an empty `segments` list fall
    # through to the 4 KB rule (teeth M-C); presence is what says "this is a
    # striped image", and an unusable block is then refused below rather than
    # silently treated as a flat one.
    if hbm.get("lane_stripe") is not None:
        _tokens, gdn_base, _kvb = PK.stripe_context_tokens(
            weights_end, gdn_bytes, top, per)
        segment_pad = gdn_base - weights_end
        # THE STACK RULE STILL APPLIES.  A segment boundary is not a stack
        # boundary, so a large enough arena placed at one could still straddle
        # the 4 GiB line.  `PK.place()` is asked whether the segment-aligned
        # base is legal rather than asked to choose one; a disagreement is
        # REFUSED rather than quietly moved, because moving it would leave the
        # segment boundary behind and reintroduce exactly this defect.
        chk, _ = PK.place(gdn_base, gdn_bytes)
        if chk != gdn_base:
            raise SystemExit(
                "hbm_map: the lane-striped GDN state at %s straddles the "
                "stack line and cannot be placed at a segment boundary.  "
                "Refusing rather than falling back to a 4 KB placement."
                % h(gdn_base))
        hole = 0
    else:
        gdn_base, hole = PK.place(weights_end, gdn_bytes)
    kv_base = align_up(gdn_base + gdn_bytes, int(hbm.get("align", 4096)))

    # The KV region is split at every stack boundary and whole records counted
    # inside each extent, which is `pack_model_fk33`'s rule and the reason a
    # record cannot straddle the line by an alignment coincidence.  CAPPED at
    # the GDN constant image when one is placed: that region is charged to the
    # KV arena's top and the context figure must not count it.
    cap = int(hbm["gdn_const_base"]) if hbm.get("gdn_const_bytes") else top
    extents = kv_extents_below(kv_base, cap, top, stack, per)

    hbm.update(
        gdn_state_base=gdn_base, gdn_state_bytes=gdn_bytes,
        gdn_state_stack=stack_of(gdn_base),
        gdn_state_layers=sz["gdn_layers"],
        gdn_state_bytes_per_layer=sz["gdn_state_bytes_per_layer"],
        gdn_state_mant_bytes_per_layer=sz["gdn_state_mant_bytes_per_layer"],
        gdn_state_exp_bytes_per_layer=sz["gdn_state_exp_bytes_per_layer"],
        kv_base=kv_base, kv_bytes_per_token=per,
        kv_layers=sz["attn_layers"],
        kv_bytes_per_layer_per_token=sz["kv_bytes_per_layer_per_token"],
        kv_record_bytes=sz["kv_record_bytes"],
        kv_extents=extents,
        # `_used` is what the PROGRAM will place inside the extent.  With the
        # reservation now derived from the same shape the program is emitted
        # for, reserved and used are equal BY CONSTRUCTION -- which is the
        # point of the change and is why they are written rather than left at
        # the -1 that means "nobody said".
        gdn_state_layers_used=sz["gdn_layers"],
        kv_layers_used=sz["attn_layers"],
        free_after_gdn=sum(x["nbytes"] for x in extents),
        max_context_tokens=sum(x["tokens"] for x in extents),
        arena_sizing="derived from rtl/model_cfg_pkg.vhd %s by "
                     "tools/hbm_map.py arena_sizes()" % name)
    if hole:
        # The packer records stack holes; a re-layout that opens a new one must
        # say so rather than lose the bytes silently.
        hbm.setdefault("stack_holes", []).append(
            dict(offset=weights_end, nbytes=hole,
                 why="stack boundary before the re-laid-out GDN state region"))
        hbm["stack_hole_bytes"] = sum(h["nbytes"]
                                      for h in hbm["stack_holes"])
    if segment_pad:
        # NOT a stack hole, and deliberately not filed as one: these bytes are
        # skipped to reach a PSEUDO-CHANNEL boundary, not a stack boundary,
        # and merging the two would make `stack_hole_bytes` a number about two
        # different mechanisms.  The packer records neither; recording it here
        # is additive and costs no reader.
        hbm["gdn_state_segment_pad_bytes"] = int(segment_pad)

    # THE RESULT IS CHECKED BEFORE IT IS RETURNED, against the same rule every
    # other reader of this manifest now applies.  A producer that trusts its
    # own arithmetic is how the 2026-09-20 placement came to be written.
    fails = stripe_residency_fails(dict(mani, hbm=hbm))
    if fails:
        raise SystemExit(
            "hbm_map: REFUSING to re-lay-out the arenas -- the result puts "
            "them on a weight lane's pseudo-channel:\n"
            + "\n".join("  " + s for s in fails))
    return hbm, before


def write_arenas(path, ncards=1):
    """Install `relayout_arenas()` into a manifest, atomically, keeping a .bak.

    A DISTINCT backup name from `write_region_block()`'s.  That one creates
    `manifest.json.bak` only if absent, so reusing it here would either clobber
    the pre-region-block snapshot or silently keep it and record nothing about
    this change."""
    with open(path) as f:
        mani = json.load(f)
    new_hbm, before = relayout_arenas(mani, ncards)
    mani["hbm"] = new_hbm
    bak = path + ".bak-arenas"
    if not os.path.exists(bak):
        with open(bak, "w") as f:
            json.dump(json.load(open(path)), f, indent=1)
    tmp = path + ".tmp-arenas"
    with open(tmp, "w") as f:
        json.dump(mani, f, indent=1)
    os.replace(tmp, path)
    return before, new_hbm, bak


def write_region_block(path, blk):
    """Install `blk` into an existing manifest.json, atomically, keeping a
    .bak.  Additive: no existing key is removed and none but the region-block
    keys is touched, so every reader that predates the block still parses."""
    with open(path) as f:
        mani = json.load(f)
    if "hbm" not in mani:
        raise SystemExit("hbm_map: %s has no top-level hbm object" % path)
    before = {k: mani["hbm"].get(k) for k in REGION_BLOCK_KEYS}
    mani["hbm"].update(blk)
    bak = path + ".bak"
    if not os.path.exists(bak):
        with open(bak, "w") as f:
            json.dump(json.load(open(path)), f, indent=1)
    tmp = path + ".tmp-hbm-map"
    with open(tmp, "w") as f:
        json.dump(mani, f, indent=1)
    os.replace(tmp, path)          # atomic: a concurrent reader sees one or the
                                   # other whole file, never a torn one
    return before


# --------------------------------------------- the C, compiled and executed

C_PROBE = r"""
/* Generated by tools/hbm_map.py --check-c.  Not committed, not a fixture: it
 * is written to a temp dir, compiled against the REAL server/pl_backend.c, run,
 * and deleted.  Its two jobs:
 *
 *   1. print what pl_derive_bases() actually computes, so the Python mirror in
 *      hbm_map.host_blocks() can be required to equal it rather than merely
 *      resemble it;
 *   2. drive pl_check_bases() over a table of descriptor-arena placements, so
 *      the C refusal can be SHOWN to fire.  A checker never seen to fail has
 *      not been shown to work.
 */
#include <stdio.h>
#include <stdlib.h>
#include "pl_backend.h"
#include "fk33_seam.h"

static void emit_case(const char *name, pl_hbm_bases b,
                      unsigned long long abase, unsigned long long aspan)
{
    b.arena_base = abase;
    b.arena_span = aspan;
    printf("  {\"case\": \"%s\", \"arena_base\": %llu, \"arena_span\": %llu,"
           " \"rc\": %d},\n", name, abase, aspan, pl_check_bases(&b));
}

int main(int argc, char **argv)
{
    pl_hbm_bases b, p;
    int e;
    unsigned long long top;
    if (argc < 5) return 2;
    top = strtoull(argv[4], 0, 0);
    e = pl_derive_bases(atoi(argv[1]), atoi(argv[2]), atoi(argv[3]), top,
                        0, 0, &b);
    printf("{\"rc\": %d, \"x_base\": %llu, \"x_span\": %llu,"
           " \"l_base\": %llu, \"l_span\": %llu,"
           " \"desc_ptr\": %llu, \"desc_span\": %llu, \"hbm_top\": %llu,\n",
           e, (unsigned long long)b.x_base,   (unsigned long long)b.x_span,
              (unsigned long long)b.l_base,   (unsigned long long)b.l_span,
              (unsigned long long)b.desc_ptr, (unsigned long long)b.desc_span,
              (unsigned long long)b.hbm_top);
    printf(" \"arena_cases\": [\n");
    /* no arena declared: must still pass, and pl_open warns about the silence */
    emit_case("none", b, 0, 0);
    /* the HISTORIC gen_layer_program.py placement, 311 jobs at 512 B */
    emit_case("historic_top_down", b,
              (top - 311ull * 512ull) & ~0xFFFull, 159744ull);
    /* exactly one page over the D program */
    emit_case("on_d_program", b, (unsigned long long)b.desc_ptr, 4096ull);
    /* one page over the top of the logits row */
    emit_case("on_logits_tail", b,
              (unsigned long long)(b.l_base + b.l_span - 4096ull) & ~0xFFFull,
              4096ull);
    /* one page over the R_X staging block */
    emit_case("on_r_x", b, (unsigned long long)b.x_base, 4096ull);
    /* 512-B aligned but not 4 KB, and clear of every other block.  This case
     * WANTED 0 until 2026-08-29: pl_check_bases() demanded 512-B alignment of
     * the arena while hbm_map.check() demanded 4 KB of every region, so a
     * 512-aligned base was accepted by the C and rejected by the Python.
     * TRACK ADDRARENA recorded that divergence under its own name rather than
     * harmonising it, because 512 is the descriptor stride and 4 KB is the
     * allocation granularity and both were defensible while nobody produced
     * such an address.  With the manifest as the authority something does now
     * produce the address -- derive_region_block() -- and it produces a
     * page-aligned one, so the looser rule bought nothing and cost a hole
     * where the two checkers disagreed.  The C is now 4 KB too and this case
     * WANTS A REFUSAL.  The first attempt at it put the base 512 B HIGHER and
     * so ran 512 B into R_X; it was refused for OVERLAP and read as an
     * alignment failure, which is why the -4096 is there: a case that cannot
     * separate two reasons for a refusal is not measuring the one it names. */
    emit_case("aligned_512_not_4k", b,
              (unsigned long long)b.x_base - 159744ull - 4096ull + 512ull,
              159744ull);
    /* misaligned below 512 */
    emit_case("misaligned_64", b,
              (unsigned long long)b.x_base - 159744ull - 4096ull + 64ull,
              159744ull);
    /* off the top of the device */
    emit_case("past_top", b, top - 4096ull, 8192ull);
    /* straddling the 4 GiB stack line */
    emit_case("straddles_stack_line", b,
              (unsigned long long)FK33_HBM_STACK_LINE - 4096ull, 8192ull);
    /* the below-host placement: the one that must be accepted */
    p = b;
    e = pl_place_desc_arena(&p, 159232ull);
    printf("  {\"case\": \"place_below_host\", \"arena_base\": %llu,"
           " \"arena_span\": %llu, \"rc\": %d}\n",
           (unsigned long long)p.arena_base, (unsigned long long)p.arena_span, e);
    printf(" ]}\n");
    return 0;
}
"""

C_SOURCES = ["pl_backend.c", "fk33_transport.c", "fk33_sim.c",
             "fk33_manifest.c"]


def check_against_c(n_embd, n_vocab, max_chunk, hbm_top=HBM_TOP, cc=None,
                    verbose=False):
    """Compile `server/pl_backend.c` and require the real C to agree.

    THIS IS THE ONLY EVIDENCE IN THIS FILE.  Everything above is a Python
    model; `host_blocks()` claims to reproduce `pl_derive_bases()` and that
    claim is worth nothing on its own.  Two Python copies agreeing would be
    the failure mode TRACK SCHED-FIX recorded, where a wrong constant survived
    because the two generators agreed with each other.

    Returns (ok, list_of_messages).  A compiler that is not present is
    reported as SKIP, not as a pass."""
    cc = cc or os.environ.get("CC", "cc")
    srcdir = os.path.join(REPO, "server")
    msgs = []
    with tempfile.TemporaryDirectory(prefix="hbm_map_c_") as td:
        cpath = os.path.join(td, "probe.c")
        with open(cpath, "w") as f:
            f.write(C_PROBE)
        exe = os.path.join(td, "probe")
        cmd = [cc, "-O1", "-std=c99", "-I", srcdir, "-o", exe, cpath] + \
              [os.path.join(srcdir, s) for s in C_SOURCES]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True)
        except OSError as e:
            return None, [f"SKIP  no C compiler ({cc}): {e}"]
        if p.returncode:
            return False, ["FAIL  the C probe did not compile:\n" + p.stderr]
        r = subprocess.run([exe, str(n_embd), str(n_vocab), str(max_chunk),
                            str(hbm_top)], capture_output=True, text=True)
        if r.returncode:
            return False, [f"FAIL  the C probe exited {r.returncode}: {r.stderr}"]
        got = json.loads(r.stdout)
    _, want = host_blocks(n_embd, n_vocab, max_chunk, hbm_top)
    ok = True
    for k in ("x_base", "x_span", "l_base", "l_span", "desc_ptr", "desc_span",
              "hbm_top"):
        if int(got[k]) != int(want[k]):
            ok = False
            msgs.append(f"FAIL  {k}: this file says {h(want[k])}, "
                        f"server/pl_backend.c says {h(int(got[k]))}")
        elif verbose:
            msgs.append(f"ok    {k} = {h(want[k])}  (C and Python agree)")
    if got["rc"] != 0:
        msgs.append(f"note  pl_derive_bases returned {got['rc']} "
                    f"(reserved_end was passed as 0 here, so only the "
                    f"self-consistency half of pl_check_bases ran)")
    if ok and not msgs:
        msgs.append("ok    all seven derived values match server/pl_backend.c")

    # ---- the arena teeth, run in the C.
    #
    # WANT is the verdict each placement MUST get, written down before the
    # numbers were seen.  A case that does not bite is reported under its own
    # name and kept: it is the resolution floor of the check, and this project
    # has repeatedly found that the non-biting rows are the informative ones.
    want_rc = {
        # MANDATORY AS OF 2026-08-29.  This row used to want 0 -- an undeclared
        # arena PASSED, protected only by a printed warning, and ADDRARENA
        # flagged it as the live hazard.  With the manifest as the authority
        # there is no such thing as "no arena declared": either the manifest
        # states it or the manifest is refused, so a layout with arena_span 0
        # is incomplete and pl_check_bases() now says so.
        "none":                 "nonzero",
        "historic_top_down":    "nonzero",
        "on_d_program":         "nonzero",
        "on_logits_tail":       "nonzero",
        "on_r_x":               "nonzero",
        "aligned_512_not_4k":   "nonzero",   # 4 KB now, harmonised with the map
        "misaligned_64":        "nonzero",
        "past_top":             "nonzero",
        "straddles_stack_line": "nonzero",
        "place_below_host":     0,
    }
    for cs in got.get("arena_cases", []):
        want = want_rc.get(cs["case"])
        rc = int(cs["rc"])
        got_kind = "nonzero" if rc else 0
        verdict = "ok  " if got_kind == want else "FAIL"
        if got_kind != want:
            ok = False
        msgs.append(f"{verdict}  pl_check_bases arena case {cs['case']:22s} "
                    f"base={h(int(cs['arena_base']))} span={cs['arena_span']} "
                    f"-> rc {rc} (wanted {want})")
    return ok, msgs


# ------------------------------------------------------------------- teeth
#
# A CHECKER NEVER SHOWN TO FAIL HAS NOT BEEN SHOWN TO WORK.  Each row mutates a
# real manifest or a real placement and states, BEFORE the run, whether
# `HbmMap.check()` must go red.  Rows that must go GREEN are not filler: the
# map deliberately treats a top-anchored region overlapping the KV arena as a
# capacity charge rather than a collision, and a row that pins that decision
# down is the only thing separating "by design" from "cannot see it".

def _teeth_cases(mani, max_chunk=None, desc_jobs=311):
    """Yield (name, want_red, builder) where builder returns an HbmMap.

    The manifest handed in may or may not carry a region block.  Every row
    below runs against a copy that DOES, installed by `derive_region_block()`,
    so the rows measure the decided mechanism rather than the migration state
    of whichever file the caller pointed at.  The rows that measure the ABSENCE
    of a block install nothing."""
    raw = json.loads(json.dumps(mani))
    blocked = json.loads(json.dumps(mani))
    blocked.setdefault("hbm", {}).update(
        derive_region_block(raw, desc_jobs, max_chunk or 512))
    # AND THE GDN CONSTANT REGION, installed the same way, so every row below
    # runs over the map the card will actually see: weights, GDN state, KV,
    # constants, descriptor arena, host blocks.  A manifest that predates the
    # region gets it derived here; one that carries it keeps what it carries
    # (the derivation is deterministic, so the two agree or the rows say so).
    if not blocked["hbm"].get("gdn_const_bytes"):
        blocked["hbm"].update(derive_gdn_const_block(blocked))
    mani = blocked

    def base_map(**kw):
        kw.setdefault("desc_jobs", desc_jobs)
        kw.setdefault("max_chunk", max_chunk)
        return plan(json.loads(json.dumps(mani)), **kw)

    def mutate(fn, **kw):
        m2 = json.loads(json.dumps(mani))
        fn(m2)
        kw.setdefault("desc_jobs", desc_jobs)
        kw.setdefault("max_chunk", max_chunk)
        return plan(m2, **kw)

    yield ("control_clean", False, lambda: base_map())

    # ---------------------------------------------------------------- the
    # mechanism itself.  These four rows are what item 3 of the ARENA-MANIFEST
    # brief asked for: the mandatory block, shown failing.

    def _drop_block(m2):
        for k in REGION_BLOCK_KEYS:
            m2["hbm"].pop(k, None)
    yield ("no_region_block_at_all", True,
           lambda: mutate(_drop_block, strict_arena=False))

    def _drop_one_key(m2):
        m2["hbm"].pop("desc_arena_bytes")
    yield ("region_block_missing_one_key", True,
           lambda: mutate(_drop_one_key, strict_arena=False))

    def _block_overlaps_logits(m2):
        # The historic colliding address, but DECLARED.  A block is not
        # trusted because it is declared; it is checked like any other region.
        m2["hbm"]["desc_arena_base"] = align_down(
            HBM_TOP - DESC_STRIDE * desc_jobs, PAGE)
    yield ("declared_block_on_the_logits_row", True,
           lambda: mutate(_block_overlaps_logits))

    def _block_too_small(m2):
        m2["hbm"]["desc_arena_bytes"] = PAGE
    yield ("declared_block_too_small_for_the_program", True,
           lambda: mutate(_block_too_small))

    def _block_unaligned(m2):
        m2["hbm"]["desc_arena_base"] = int(m2["hbm"]["desc_arena_base"]) + 64
    yield ("declared_block_unaligned", True,
           lambda: mutate(_block_unaligned))

    def _host_blocks_disagree(m2):
        m2["hbm"]["host_x_base"] = int(m2["hbm"]["host_x_base"]) + PAGE
    yield ("declared_host_x_base_disagrees_with_the_mirror", True,
           lambda: mutate(_host_blocks_disagree))

    # THE ROW THAT WAS RED AND UNCLOSEABLE AT ADDRARENA.  max_chunk comes from
    # CAPS and nothing constrained it; now the manifest pins it, so opening at
    # a different cap is a stated disagreement rather than a moved map.
    yield ("max_chunk_larger_than_the_one_the_arena_was_placed_under", True,
           lambda: base_map(max_chunk=4096))

    # MUST STAY GREEN, and it is a derivation rather than a leniency:
    # x_base = align_down(l_base - x_stride*max_chunk) decreases monotonically
    # in max_chunk, so a SMALLER cap moves x_base UP, away from the arena.  The
    # result is a gap between the arena and R_X -- wasted, never overwritten.
    # Refusing it would break every caller that opens a small simulated card
    # against a real manifest, which server/tests/embed_e2e.c does deliberately
    # at max_chunk 8.
    yield ("max_chunk_smaller_than_the_pinned_one", False,
           lambda: base_map(max_chunk=8))

    yield ("arena_historic_top_down", True,
           lambda: base_map(policy="top-down"))

    yield ("arena_on_weight_image", True,
           lambda: base_map(desc_base=0))

    yield ("arena_straddles_stack_line", True,
           lambda: base_map(desc_base=STACK_LINE - 4096))

    yield ("arena_unaligned", True,
           lambda: base_map(desc_base=align_down(HBM_TOP, PAGE) - 8 * PAGE + 512))

    yield ("arena_past_top", True,
           lambda: base_map(desc_base=HBM_TOP - 4096))

    # ADDRARENA's `max_chunk_grown_over_a_fixed_arena` lived here.  It is
    # SUPERSEDED, not deleted: it drove an UNDECLARED max_chunk over a fixed
    # arena, and with the cap now pinned in the manifest that mutation goes red
    # for TWO reasons at once -- the geometric overlap it was written for and
    # the declared-cap disagreement.  A row that cannot separate two reasons
    # for a refusal is not measuring the one it names (ADDRARENA section 7), so
    # it was replaced by `max_chunk_not_the_one_the_arena_was_placed_under`
    # above, which isolates the declaration, and by this row, which isolates
    # the geometry by keeping the cap consistent and moving the arena instead.
    yield ("host_blocks_grown_down_through_a_fixed_arena", True,
           lambda: base_map(desc_base=align_down(
               HBM_TOP - 5_226_496 - align_up(DESC_STRIDE * desc_jobs, PAGE),
               PAGE), max_chunk=4096, _allow_chunk_mismatch=True))

    def _overlap_two_tensors(m2):
        f = [e for e in m2["files"] if e["kind"] == "mv4i"]
        f[7]["hbm_offset"] = f[6]["hbm_offset"]
    yield ("two_packed_tensors_on_one_address", True,
           lambda: mutate(_overlap_two_tensors))

    def _gdn_into_kv(m2):
        m2["hbm"]["gdn_state_base"] = int(m2["hbm"]["kv_base"]) + 4096
    yield ("gdn_state_moved_into_the_kv_arena", True,
           lambda: mutate(_gdn_into_kv))

    def _wrong_stack_field(m2):
        for e in m2["files"]:
            if int(e["hbm_offset"]) >= STACK_LINE:
                e["stack"] = 0
                return
    yield ("a_tensor_declares_the_wrong_stack", True,
           lambda: mutate(_wrong_stack_field))

    def _straddle_tensor(m2):
        big = max((e for e in m2["files"] if e["kind"] == "mv4i"),
                  key=lambda e: int(e["nbytes"]))
        big["hbm_offset"] = STACK_LINE - int(big["nbytes"]) // 2
    yield ("a_tensor_straddles_the_stack_line", True,
           lambda: mutate(_straddle_tensor))

    # MUST STAY GREEN.  The KV arena is defined as everything above the GDN
    # state, so every top-anchored reservation overlaps it by construction and
    # the map charges it instead of failing.  Naming the row is what stops that
    # design decision from being mistaken for blindness later.
    yield ("arena_inside_the_kv_arena_only", False,
           lambda: base_map(desc_base=align_down(
               int(mani["hbm"]["kv_base"]) + (1 << 30), PAGE)))

    # MUST STAY GREEN, and this is the resolution floor worth knowing: the map
    # sees ADDRESSES.  A descriptor arena of the right size in the right place
    # that is nonetheless filled with the wrong descriptors is invisible here,
    # and always will be.  That is gen_layer_program.py's and
    # fk33_load_weights.py verify's job, not this one.
    yield ("arena_right_place_wrong_jobcount", False,
           lambda: base_map(desc_jobs=1))

    # ---------------------------------------------------------------- the
    # GDN constant image (2026-09-18).  Same shape of evidence as the arena
    # rows: the region is declared, so it is checked like any other, and the
    # three ways a declared address can be wrong each get a row.

    def _const_on_the_arena(m2):
        m2["hbm"]["gdn_const_base"] = int(m2["hbm"]["desc_arena_base"])
    yield ("gdn_const_placed_on_the_descriptor_arena", True,
           lambda: mutate(_const_on_the_arena))

    def _const_in_gdn_state(m2):
        m2["hbm"]["gdn_const_base"] = int(m2["hbm"]["gdn_state_base"]) + PAGE
    yield ("gdn_const_placed_inside_the_gdn_state", True,
           lambda: mutate(_const_in_gdn_state))

    def _const_unaligned(m2):
        m2["hbm"]["gdn_const_base"] = int(m2["hbm"]["gdn_const_base"]) + 64
    yield ("gdn_const_unaligned", True, lambda: mutate(_const_unaligned))

    def _const_under_the_host(m2):
        # Right size, aligned, but sitting under R_X staging: the host's
        # next prefill overwrites layer 23's conv weights.
        m2["hbm"]["gdn_const_base"] = align_down(
            int(m2["hbm"]["host_x_base"]) + PAGE, PAGE)
    yield ("gdn_const_placed_under_the_host_rx_staging", True,
           lambda: mutate(_const_under_the_host))

    # MUST STAY GREEN.  With the KV extent NOT re-capped -- a manifest whose
    # kv_extents still run to the top of the device, as every set packed
    # before this region existed does -- the image sits INSIDE the KV arena
    # and is a CHARGE, not a collision, exactly as the descriptor arena is.
    # Named so that green is read as the decision it is; the context figure
    # such a manifest publishes is then over by the image's size, which is
    # tools/weights_residency.py's finding and not this map's.
    def _const_in_uncapped_kv(m2):
        h_ = m2["hbm"]
        top = int(h_.get("size", HBM_TOP))
        h_["kv_extents"] = kv_extents_below(
            h_["kv_base"], top, top, int(h_.get("stack_bytes", STACK_LINE)),
            int(h_["kv_bytes_per_token"]))
    yield ("gdn_const_inside_an_uncapped_kv_extent_is_a_charge", False,
           lambda: mutate(_const_in_uncapped_kv))


# ----------------------------------------------------- teeth, the two arenas
#
# A SEPARATE TABLE FROM `_teeth_cases`, on purpose.  Those rows mutate
# ADDRESSES and are checked by the overlap machinery.  These mutate SIZES, and
# a size that is too small overlaps nothing -- the arena it corrupts is modelled
# as one opaque extent -- so they are checked by `check_arenas()` against
# `rtl/model_cfg_pkg.vhd`.  Two different oracles, so two tables.
#
# Each row states, BEFORE it runs, whether the map must go red.  Rows that must
# stay GREEN are the resolution floor and are the most useful line here: they
# say exactly what this check cannot see.

def _arena_teeth_cases(mani):
    sz = arena_sizes()

    def mutate(fn, **kw):
        m2 = json.loads(json.dumps(mani))
        m2.setdefault("hbm", {})
        fn(m2)
        return check_arenas(m2)[0]

    # ---- the two under-reservations this whole track exists to make visible
    yield ("kv_per_token_one_byte_under_the_shape", True,
           lambda: mutate(lambda m: m["hbm"].update(
               kv_bytes_per_token=sz["kv_bytes_per_token"] - 1)))
    yield ("kv_per_token_one_attention_layer_short", True,
           lambda: mutate(lambda m: m["hbm"].update(
               kv_bytes_per_token=(sz["attn_layers"] - 1)
               * sz["kv_bytes_per_layer_per_token"])))
    yield ("kv_per_token_sized_for_int8_but_without_the_record_header", True,
           lambda: mutate(lambda m: m["hbm"].update(
               kv_bytes_per_token=sz["attn_layers"] * 2
               * sz["kv_heads_per_card"] * sz["attn_head_dim"])))
    yield ("gdn_arena_one_byte_under_the_shape", True,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_state_bytes=sz["gdn_state_bytes"] - 1)))
    yield ("gdn_arena_one_layer_short", True,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_state_bytes=(sz["gdn_layers"] - 1)
               * sz["gdn_state_bytes_per_layer"])))
    # The mantissas alone, i.e. the exponent table assumed to stay on chip.
    # THIS IS DELIBERATELY RED.  The exponent table probably never reaches HBM
    # (gdn_block.vhd calls it distributed RAM), so this reservation is very
    # likely fine in practice -- and the check refuses it anyway, because "very
    # likely fine" is not a property a silent-corruption boundary should have.
    # 96 KiB is 5 tokens; buying certainty for 5 tokens is not a trade.
    yield ("gdn_arena_mantissas_only_no_exponent_table", True,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_state_bytes=sz["gdn_layers"]
               * sz["gdn_state_mant_bytes_per_layer"])))

    # ---- the GDN constant image: size, stride and layer count
    yield ("gdn_const_one_byte_under_the_shape", True,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_const_bytes=sz["gdn_const_bytes"] - 1)))
    yield ("gdn_const_one_layer_short", True,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_const_bytes=(sz["gdn_const_layers"] - 1)
               * sz["gdn_const_bytes_per_layer"])))
    # Big enough and WRONG: the whole region at 24 x 65536, i.e. the conv
    # weights with the scalar block forgotten.  Every address check passes and
    # layer 1 reads its dt bias out of layer 0's tail.  This is the row the
    # stride check exists for.
    yield ("gdn_const_stride_forgets_the_scalar_block", True,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_const_bytes=sz["gdn_const_bytes"],
               gdn_const_bytes_per_layer=sz["gdn_const_bytes_per_layer"]
               - GDN_CONST_BURST_BYTES)))
    yield ("gdn_const_layers_counted_as_all_blocks", True,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_const_bytes=sz["gdn_const_bytes"],
               gdn_const_layers=sz["model_blocks"])))
    yield ("gdn_const_exactly_the_derived_size", False,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_const_bytes=sz["gdn_const_bytes"],
               gdn_const_bytes_per_layer=sz["gdn_const_bytes_per_layer"],
               gdn_const_layers=sz["gdn_const_layers"])))
    # The floor: a manifest with no constant image declared is a manifest
    # whose card runs the m12 stand-ins, and that is a build decision this
    # check cannot see.  Green, and named.
    yield ("gdn_const_keys_absent_entirely", False,
           lambda: mutate(lambda m: [m["hbm"].pop(k, None) for k in
                                     ("gdn_const_bytes",
                                      "gdn_const_bytes_per_layer",
                                      "gdn_const_layers")]))

    # ---- exactly right, and over.  Both must stay GREEN.
    yield ("both_arenas_exactly_the_derived_size", False,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_state_bytes=sz["gdn_state_bytes"],
               kv_bytes_per_token=sz["kv_bytes_per_token"])))
    # THE SHIPPING VALUES AS OF THIS MORNING.  Over-reserved 2.99x and 3.76x
    # and still GREEN, because over-reservation costs context and corrupts
    # nothing.  Named so that green is read as the decision it is.
    yield ("the_27b_literals_this_track_replaced_are_over_not_under", False,
           lambda: mutate(lambda m: m["hbm"].update(
               gdn_state_bytes=48 * 6144 * 128 * 2,
               kv_bytes_per_token=16 * 4 * 256 * 2 * 2)))

    # ---- the resolution floor: what this check CANNOT see.
    yield ("arena_keys_absent_entirely", False,
           lambda: mutate(lambda m: [m["hbm"].pop(k, None) for k in
                                     ("gdn_state_bytes",
                                      "kv_bytes_per_token")]))

    def _unknown_shape(m):
        for e in m["files"]:
            if e.get("tensor") == "output.weight":
                e["K"] = 1234
    yield ("shape_matches_no_model_cfg_record", False,
           lambda: mutate(_unknown_shape))


def _arena_shape_teeth():
    """Does the DERIVED figure move when the shape moves, and the right way?

    This is item 4 of the brief.  A constant that silently encodes 48 GDN
    layers is exactly how the defect survived, so the replacement has to be
    shown tracking the shape -- and the sharpest available demonstration is
    that `arena_sizes(QWEN38_27B)` REPRODUCES the very literals that were
    removed.  That is not a coincidence to be noted; it is the proof that the
    four literals were a different model's figures rather than merely stale."""
    rows = []

    def row(name, got, want):
        rows.append((name, got, want, got == want))

    nine = arena_sizes(scrape_model_cfg("QWEN35_9B"))
    tw = arena_sizes(scrape_model_cfg("QWEN38_27B"))

    row("27B gdn layers reproduce the removed GDN_STATE_LAYERS",
        tw["gdn_layers"], 48)
    row("27B gdn mantissas reproduce the removed 6144*128*2",
        tw["gdn_state_mant_bytes_per_layer"], 6144 * 128 * 2)
    row("27B attention layers reproduce the removed KV_LAYERS",
        tw["attn_layers"], 16)
    row("9B gdn layers are 24, not 48", nine["gdn_layers"], 24)
    row("9B attention layers are 8, not 16", nine["attn_layers"], 8)
    row("9B gdn mantissas are 4096*128*2, not 6144*128*2",
        nine["gdn_state_mant_bytes_per_layer"], 4096 * 128 * 2)
    # The constant image's contract figures (docs/2026-09-18_b-constants-path.md)
    # are DERIVED here from the RTL record, so the row is the contract being
    # reproduced rather than restated: 2 x (4 x 8192 + 256) = 66048 = 129
    # bursts, x 24 layers.  The 27B figure is what the same rule gives at
    # qkv 10240 and is stated so a shape change is seen to move it.
    row("9B constant image is 66048 B per layer (129 x 512)",
        (nine["gdn_const_bytes_per_layer"],
         nine["gdn_const_bytes_per_layer"] % GDN_CONST_BURST_BYTES),
        (66048, 0))
    row("9B constant image totals 24 x 66048 = 1585152 B",
        nine["gdn_const_bytes"], 1585152)
    row("27B constant image is 2 x (4 x 10240 + 256) = 82432 B per layer",
        tw["gdn_const_bytes_per_layer"], 82432)
    row("the scalar block holds 2 x 32 + 128 + 6 = 198 of 256 words at 9B",
        nine["gdn_const_scalar_words_used"], 198)
    # The KV RECORD is shape-independent between these two models -- both have
    # attn_kv_heads 4 and attn_head_dim 256 -- so the per-layer KV term is the
    # SAME 2176 B at both scales and only the layer count moves.  Stated
    # because a row that moves for two reasons at once measures neither.
    row("the KV record is 272 B at BOTH scales (head dim 256, int8)",
        (nine["kv_record_bytes"], tw["kv_record_bytes"]), (272, 272))
    row("only the layer count moves the KV per-token figure",
        (nine["kv_bytes_per_token"], tw["kv_bytes_per_token"]),
        (8 * 2176, 16 * 2176))
    # Tensor parallelism divides the value heads and the KV heads, so both
    # arenas must halve at NCARDS 2.  model_cfg_pkg's val_heads_per_card
    # asserts the same divisibility.
    row("NCARDS=2 halves the GDN arena",
        arena_sizes(scrape_model_cfg("QWEN38_27B"), 2)["gdn_state_bytes"] * 2,
        tw["gdn_state_bytes"])
    row("NCARDS=2 halves the KV per-token figure",
        arena_sizes(scrape_model_cfg("QWEN38_27B"), 2)["kv_bytes_per_token"]
        * 2, tw["kv_bytes_per_token"])
    return rows


def _arena_scrape_teeth():
    """A scrape that stops matching must HARD FAIL, never default.

    `_scrape_seam_h` set that precedent above and the reason is the same: a
    default is the defect with a different address."""
    rows = []
    with tempfile.TemporaryDirectory(prefix="hbm_map_scrape_") as td:
        src = open(MODEL_CFG_VHD).read()
        for name, mangled in (
                ("model record renamed away",
                 src.replace("constant QWEN35_9B", "constant QWEN35_9B_OLD")),
                ("a field dropped from the record",
                 src.replace("lin_val_heads => 32,", "")),
                ("the aggregate turned positional",
                 src.replace("blocks        => 32,   attn_interval => 4,",
                             "32, 4,"))):
            path = os.path.join(td, "mangled.vhd")
            with open(path, "w") as f:
                f.write(mangled)
            try:
                scrape_model_cfg("QWEN35_9B", path)
                rows.append((name, False))
            except SystemExit:
                rows.append((name, True))
    return rows


def run_arena_teeth(mani, verbose=True):
    bad = 0
    rows = []
    for name, want_red, build_ in _arena_teeth_cases(mani):
        try:
            fails = build_()
        except SystemExit as e:
            fails = ["SystemExit: %s" % e]
        red = bool(fails)
        ok = (red == want_red)
        bad += (not ok)
        rows.append((name, want_red, red, len(fails), ok,
                     fails[0] if fails else ""))
    if verbose:
        print("ARENA SIZE TEETH  (oracle: rtl/model_cfg_pkg.vhd, not a constant)")
        print(f"{'mutation':56s} {'want':>5s} {'got':>5s} {'n':>3s}  verdict")
        for name, want_red, red, n, ok, first in rows:
            print(f"{name:56s} {'RED' if want_red else 'green':>5s} "
                  f"{'RED' if red else 'green':>5s} {n:>3d}  "
                  f"{'ok' if ok else 'DID NOT BITE'}")
        print()
        print("DOES THE DERIVED FIGURE TRACK THE SHAPE")
    for name, got, want, ok in _arena_shape_teeth():
        bad += (not ok)
        if verbose:
            print(f"  {'ok  ' if ok else 'FAIL'}  {name:58s} {got!r}"
                  + ("" if ok else f"  wanted {want!r}"))
    if verbose:
        print()
        print("DOES A BROKEN SCRAPE HARD-FAIL")
    for name, ok in _arena_scrape_teeth():
        bad += (not ok)
        if verbose:
            print(f"  {'ok  ' if ok else 'FAIL'}  {name:58s}"
                  f"  {'refused' if ok else 'RETURNED A VALUE ANYWAY'}")
    return bad, rows


def run_teeth(mani, max_chunk=512, desc_jobs=311, verbose=True):
    rows, bad = [], 0
    for name, want_red, build_ in _teeth_cases(mani, max_chunk, desc_jobs):
        try:
            m = build_()
            fails = m.check()
        except SystemExit as e:
            fails = [f"SystemExit: {e}"]
        red = bool(fails)
        ok = (red == want_red)
        if not ok:
            bad += 1
        rows.append((name, want_red, red, len(fails), ok,
                     fails[0] if fails else ""))
    if verbose:
        print(f"{'mutation':40s} {'want':>5s} {'got':>5s} {'n':>3s}  verdict")
        for name, want_red, red, n, ok, first in rows:
            print(f"{name:40s} {'RED' if want_red else 'green':>5s} "
                  f"{'RED' if red else 'green':>5s} {n:>3d}  "
                  f"{'ok' if ok else 'DID NOT BITE'}")
            if first:
                print(f"    {first[:150]}")
    return bad, rows


# ----------------------------------------------- manifest keys, for option (a)

def manifest_hbm_patch(m):
    """The region block as this map sees it, for `--emit-manifest-hbm`.

    Superseded as a PRODUCER by `derive_region_block()`, which is what the
    packer and `--write-manifest-hbm` call; this one just reports whatever map
    is in hand, including one built by a policy nobody should ship."""
    a = [r for r in m.regions if r.kind == "desc"]
    if not a:
        return None
    return {"desc_arena_base": a[0].base, "desc_arena_bytes": a[0].nbytes}


# ------------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest")
    ap.add_argument("--desc-jobs", type=int, default=311,
                    help="A descriptors to reserve for (311 at the 9B token "
                         "program, MEASURED). 0 removes the arena entirely, "
                         "which is the 'descriptors live in host memory' "
                         "arrangement")
    ap.add_argument("--desc-base", type=lambda x: int(x, 0), default=None,
                    help="place the arena here instead of by policy")
    ap.add_argument("--policy",
                    choices=("manifest", "allocate-below-host", "top-down"),
                    default="manifest",
                    help="manifest: READ hbm.desc_arena_base, the decided "
                         "mechanism, no arithmetic.  allocate-below-host: the "
                         "allocation rule, which is what pack time runs.  "
                         "top-down: gen_layer_program.py's historic default, "
                         "which COLLIDES and is kept only to show the refusal")
    ap.add_argument("--max-chunk", type=int, default=None,
                    help="pl_open()'s max_chunk, which sets the R_X span.  "
                         "Default: hbm.host_max_chunk out of the manifest.  "
                         "Passing one that disagrees with the pinned value is "
                         "a FAIL, not a preference")
    ap.add_argument("--no-host-blocks", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--check-c", action="store_true",
                    help="compile server/pl_backend.c and require the real "
                         "pl_derive_bases() to agree address for address")
    ap.add_argument("--self-test", action="store_true",
                    help="mutate a real manifest and require check() to go "
                         "red where it must and stay green where it must.  "
                         "Rows that DO NOT bite are printed under their own "
                         "names, because they are the resolution floor")
    ap.add_argument("--emit-manifest-hbm", action="store_true",
                    help="print the region block this map implies")
    ap.add_argument("--arena", action="store_true",
                    help="print the GDN and KV arena sizing DERIVED from "
                         "rtl/model_cfg_pkg.vhd, term by term, and what this "
                         "manifest reserves against it")
    ap.add_argument("--write-manifest-arenas", action="store_true",
                    help="RE-LAY-OUT the GDN state and KV arenas at the size "
                         "the RTL shape needs and write them into this "
                         "manifest, atomically, keeping a .bak-arenas.  No "
                         "placed tensor moves; both arenas begin after "
                         "weights_end")
    ap.add_argument("--gdn-const", action="store_true",
                    help="print the GDN constant region this manifest would "
                         "get from derive_gdn_const_block(): the base below "
                         "the descriptor arena, the re-capped KV extents and "
                         "the new max_context_tokens.  Writes nothing")
    ap.add_argument("--write-manifest-gdn-const", action="store_true",
                    help="DERIVE the GDN constant region and WRITE it into "
                         "this manifest, atomically, keeping a .bak-gdnconst. "
                         "tools/pack_gdn_consts.py does this itself after "
                         "packing; this is for a manifest whose image already "
                         "exists (the digest keys are left as they are)")
    ap.add_argument("--ncards", type=int, default=1,
                    help="tensor-parallel group size, which divides the value "
                         "heads and the KV heads.  1 for the 9B bring-up, "
                         "matching rtl/model_cfg_pkg.vhd's NCARDS")
    ap.add_argument("--write-manifest-hbm", action="store_true",
                    help="DERIVE the region block with the allocation rule and "
                         "WRITE it into this manifest, atomically, keeping a "
                         ".bak.  This is the migration for a set packed before "
                         "the block existed; new packs get it from "
                         "tools/pack_model_fk33.py")
    a = ap.parse_args(argv)

    with open(a.manifest) as f:
        mani = json.load(f)

    if a.arena:
        name, cfg = shape_of_manifest(mani)
        print("RTL shape      rtl/model_cfg_pkg.vhd constant MODEL = %s"
              % scrape_build_model())
        print("this manifest  output.weight matches %s"
              % (name or "NO model_cfg_t record -- not checked"))
        sz = arena_sizes(cfg, a.ncards) if cfg else arena_sizes(
            ncards=a.ncards)
        print()
        for line in arena_arithmetic(sz):
            print("  " + line)
        print()
        hbm = mani.get("hbm", {})
        for k in ("gdn_state_bytes", "kv_bytes_per_token"):
            got = hbm.get(k)
            want = sz[k]
            print("  %-20s manifest %-12s derived %-12s %s"
                  % (k, got if got is not None else "absent", want,
                     "" if got is None else
                     ("EQUAL" if int(got) == want else
                      "%.3fx %s" % (int(got) / float(want),
                                    "OVER" if int(got) > want else "UNDER"))))
        fails, notes = check_arenas(mani, a.ncards)
        print()
        for s_ in notes:
            print("note: " + s_)
        for s_ in fails:
            print("FAIL  " + s_)
        return 1 if fails else 0

    if a.gdn_const or a.write_manifest_gdn_const:
        blk = derive_gdn_const_block(mani, a.ncards)
        hbm = mani.get("hbm", {})
        print("GDN constant region for %s" % a.manifest)
        for k in ("gdn_const_base", "gdn_const_bytes", "gdn_const_stack",
                  "gdn_const_layers", "gdn_const_bytes_per_layer",
                  "gdn_const_words_per_layer", "free_after_gdn",
                  "max_context_tokens"):
            b = hbm.get(k)
            print("  %-28s %-14s -> %s" % (
                k, "absent" if b is None else (h(b) if "base" in k else b),
                h(blk[k]) if "base" in k else blk[k]))
        print("  %-28s %d extent(s) -> %d extent(s), KV top %s -> %s"
              % ("kv_extents", len(hbm.get("kv_extents", [])),
                 len(blk["kv_extents"]),
                 h(max(int(x["base"]) + int(x["nbytes"])
                       for x in hbm.get("kv_extents", [dict(base=0, nbytes=0)]))),
                 h(blk["kv_extents"][-1]["base"] + blk["kv_extents"][-1]["nbytes"])))
        if a.write_manifest_gdn_const:
            before, bak = write_gdn_const_block(a.manifest, blk)
            print("  written; backup: %s" % bak)
        return 0

    if a.write_manifest_arenas:
        before, new_hbm, bak = write_arenas(a.manifest, a.ncards)
        print("re-laid-out the GDN and KV arenas in %s" % a.manifest)
        for k in sorted(before):
            b, n = before[k], new_hbm.get(k)
            if k == "kv_extents":
                b = "%d extent(s)" % len(b or [])
                n = "%d extent(s)" % len(n or [])
            if b != n:
                print("  %-30s %s -> %s" % (k, b, n))
        print("  backup: %s" % bak)
        return 0

    if a.write_manifest_hbm:
        blk = derive_region_block(mani, a.desc_jobs,
                                  512 if a.max_chunk is None else a.max_chunk)
        before = write_region_block(a.manifest, blk)
        had = {k: v for k, v in before.items() if v is not None}
        print("wrote the region block into %s" % a.manifest)
        print("  before: %s" % (json.dumps(had) if had
                                else "no region block at all"))
        print("  after:  %s" % json.dumps(blk, indent=1))
        print("  backup: %s" % (a.manifest + ".bak"))
        return 0

    if a.self_test:
        bad, _ = run_teeth(mani, a.max_chunk, a.desc_jobs)
        print()
        bad += run_arena_teeth(mani)[0]
        print()
        if bad:
            print(f"{bad} mutation(s) did not behave as predicted")
            return 1
        print("TEETH PASS  every mutation gave the verdict written down for it "
              "before it ran")
        return 0

    m = plan(mani, desc_jobs=a.desc_jobs, desc_base=a.desc_base,
             policy=a.policy, max_chunk=a.max_chunk,
             want_host_blocks=not a.no_host_blocks)
    fails = m.check()

    if a.json:
        j = m.to_json()
        j["fails"] = fails
        print(json.dumps(j, indent=1))
    else:
        m.print_report(a.markdown)

    rc = 0
    if a.check_c:
        lm = next((e for e in mani["files"]
                   if e.get("tensor") == "output.weight"), None)
        print()
        if lm is None:
            print("SKIP  no output.weight; cannot pick a shape for the C check")
        else:
            chunk = (a.max_chunk if a.max_chunk is not None
                     else int(mani.get("hbm", {}).get("host_max_chunk", 512)))
            ok, msgs = check_against_c(int(lm["K"]), int(lm["M"]), chunk,
                                       int(mani.get("hbm", {}).get("size",
                                                                   HBM_TOP)),
                                       verbose=True)
            for s in msgs:
                print(s)
            if ok is False:
                rc = 1

    if a.emit_manifest_hbm:
        p = manifest_hbm_patch(m)
        print()
        print("# add to manifest.json's top-level \"hbm\" object:")
        print(json.dumps(p, indent=1) if p else "# no descriptor arena in this map")

    print()
    if fails:
        for s in fails:
            print(f"FAIL  {s}")
        print(f"\n{len(fails)} FAIL")
        return 1
    print("PASS  every region is aligned, in range, in one stack, and disjoint "
          f"across all {len({r.owner for r in m.regions})} allocators")
    return rc


if __name__ == "__main__":
    sys.exit(main())
