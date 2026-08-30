#!/usr/bin/env python3
"""Pack a whole GGUF model into the subsystem A INT4 format, plus a load map.

`tools/pack_int4.py` packs ONE tensor.  This drives it over an entire model at
one geometry, carries the tensors A does NOT pack, and emits the machine
readable manifest a loader needs to place everything in HBM.

    pack_model_fk33.py MODEL.gguf OUTDIR --rows-if 48 --axi-dw 256

WHAT IT DOES NOT DO: it does not re-derive anything.  The classification is
`pack_int4.is_matvec`, the size is `pack_int4.packed_layout`, the bytes are
`pack_int4.quantize` + `pack_int4.pack`.  `--audit` and a packed set are then
incapable of disagreeing, which is the whole reason the split and the layout
were lifted into named functions rather than copied here.

THE 4 KB RULE.  Spec 6.4: `weight_offset` and `scale_offset` must be 4 KB
aligned, because an AXI4 burst may not cross a 4 KB boundary.  A packed file is
already a whole number of 4 KB pages (4 KB header + `align4k` sub-regions), so
placing every file at a 4 KB aligned HBM address keeps every sub-region inside
it aligned as well.  This allocator therefore only has to round the F32 side
file, and it asserts the property rather than trusting it.

THE 177 NON-MATVEC TENSORS -- A DECISION, NOT THE SPEC.  Norms, biases, ssm_a
and the 4-tap ssm_conv1d are 1D or tiny and A does not pack them, but they
still have to reach the card.  The specs do not pin an HBM layout for them:
sequencer D SS6.4 keeps the norm weights in D's URAM constant memory precisely
to spend zero HBM ports on them, and D SS8.1's note that "the table and norm
weights move to HBM" is conditional and unspecified.  So the layout below is
chosen here:

  * ONE contiguous side file, `nonmatvec_f32.bin`, so the 177 arrive in a
    single DMA rather than 177 transfers averaging 3 KB each;
  * each tensor stored as little-endian float32 in GGUF element order
    (ne0 fastest), which is what both the F32 source tensors and the
    dequantized BF16 ones already are, so nothing is permuted;
  * each tensor 4 KB aligned WITHIN the file, so that with the file itself at a
    4 KB aligned base every individual tensor is independently 4 KB aligned and
    can be DMA'd or read on its own;
  * the padding is 0x00, matching spec 6.4's pad fill for the packed files.

The cost of that alignment is under 1 MB across all 177.  Revisit it only if
something is ever specified.

THE STACK RULE.  The FK33 carries TWO 4 GiB HBM stacks and the split is at a
hard address, 0x1_0000_0000.  An AXI master on a stack-0 SAXI port that issues
an address above that does NOT fault: the address decodes (the HBM IP exposes
all 32 pseudo-channel segments on every port when both global switches are on,
MEASURED in docs/2026-08-28_can-27-read-masters-be-served.md section 2.1), so
the read returns SOMETHING and the job reports success.  That is the
silent-wrong-answer class named in docs/2026-08-27_hbm-residency-map.md item 5.4
and it is the reason this allocator exists rather than a bare running offset.

The rule implemented here: NO placed object may CONTAIN the boundary strictly
inside it.  It applies to a whole .mv4i file, which is stronger than it needs to
be -- the sub-regions inside a file are what the 27 masters actually read -- but
a file that is wholly inside one stack has every one of its 27 sub-regions
wholly inside that stack for free, and the stronger rule is the one a reader can
check without parsing a header.  When the next object would straddle, the
allocator SKIPS to the boundary and records the hole; it never reorders, so the
manifest stays a function of the GGUF's tensor order alone.

THE qkv SEGMENT PAD.  The GDN block's `attn_qkv` is a FUSED matrix: its rows
are q | k | v, and the layer program issues one matvec JOB PER SEGMENT so each
gets its own BFP block exponent.  A job that does not start at row 0 is a row
WINDOW, and a window can only begin on a TILE boundary.  At the 9B shape the
segments are 2048 | 2048 | 4096 and ROWS_IF is 48, so `2048 mod 48 = 32` and
`4096 mod 48 = 16`: two of the three windows are not expressible, and MEASURED
by `tools/gen_layer_program.py`, 48 of a token's 297 subsystem A jobs are
refused for exactly that reason.

So each segment but the last is padded with ZERO ROWS up to a whole tile
(`pack_int4.segment_row_plan`), moving the starts to 0, 2064 and 4128.  M in
the header and in the manifest becomes the PADDED row count; the logical count
and the per-segment windows are recorded alongside it as `M_logical` and
`segments`, which is where a program generator reads the windows from rather
than re-deriving them.  Cost: 48 dead rows in 8,192, one extra tile per file,
110,592 B per tensor and 2,654,208 B over the 24.  `--no-qkv-pad` reproduces
the historic unpadded set; `manifest["geometry"]["qkv_segment_pad"]` says which
one a set is.

WHAT THIS RULE DOES NOT DO, stated so it is not mistaken for a solved problem:
it puts each tensor wholly in ONE stack, and subsystem A reads every tensor with
27 masters that CANNOT all be on one stack (a stack offers at most 15 engine
ports after the host takes one).  So under this flat layout at least 12 of the
27 masters read out of their own stack on every tensor.  Fixing THAT is the
27-lane arena layout of the residency map section 3, which needs a build-time
lane->port->stack table that no bitstream in this repo has.  This allocator
removes the straddle; it does not make the flat layout port-local.

`--drop TENSOR` -- LEAVING A TENSOR OUT OF THE IMAGE ON PURPOSE.  A tensor the
card never reads still costs HBM if it is placed, and HBM is the binding
resource at N=4 cards (docs/debugging/2026-08-29_token-embd-drop.md).  `--drop`
names a GGUF tensor that is NOT to be packed, NOT to be placed and NOT to appear
in the manifest's `files`.  It is repeatable, it defaults to EMPTY -- so the
default set is exactly the set this tool produced before the option existed --
and it REFUSES a name that is not in the GGUF, because a typo that silently
drops nothing is the failure mode an option like this invites.

What it is NOT: it is not a deletion of the data.  The manifest records every
dropped tensor by name, shape, and the byte count it WOULD have occupied, next
to `source_gguf`, so the set says out loud what it lacks and where to get it.
Whoever owns the tensor off-card reads it from that GGUF, or from a .mv4i packed
separately; `tools/embed_gather.py` is the row-gather recipe for the latter.

The intended use is `--drop token_embd.weight`: the host owns the embedding
gather and writes R_X into the card over the region-file write port -- the
`hw_we / hw_reg / hw_addr / hw_data` ports of `rtl/llama_top.vhd` (:583 at the
time of writing) and the `tok_fsm` of `rtl/seq_opdec.vhd` (:611) that publishes
that write into the lock plane -- so nothing on the card reads the embedding
table.  Cited by SYMBOL because those files are edited often and a line number
goes stale within the day; one already had.  Revisit the drop if an on-card
gather opcode is ever added, which is the trigger recorded in the note above.
"""

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pack_int4 as P                                        # noqa: E402
import hbm_map as HM              # noqa: E402  the ONE HBM address space
from gguf.gguf_reader import GGUFReader                       # noqa: E402

ALIGN = 4096
HBM_SIZE = 8 * 1024 ** 3
STACK_BYTES = 4 * 1024 ** 3                # one HBM stack; the boundary is here

# ------------------------------------------------------------- LANE STRIPING
#
# THE PSEUDO-CHANNEL GRANULE.  hw/fk33/gen_pcieep.py's ENGINE_ADDR block gives
# every engine master a window on all 32 HBM_MEM segments at
# `-offset [expr {$s * 0x10000000}] -range 256M`, and HBM_MEM<s> is
# pseudo-channel <s>.  So address bits [32:28] SELECT THE PSEUDO-CHANNEL, and
# 256 MiB is the granule at which the choice is made.  Nothing here may change
# that number without gen_pcieep.py changing with it; it is asserted against
# the scrape below.
SEGMENT_BYTES = 0x1000_0000                 # 256 MiB, one pseudo-channel
N_SEGMENTS = HBM_SIZE // SEGMENT_BYTES      # 32
GEN_PCIEEP = os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "hw", "fk33", "gen_pcieep.py")


def scrape_eng_port_map(path=GEN_PCIEEP):
    """master index -> HBM SAXI port index, READ OUT OF gen_pcieep.py.

    NOT restated here.  That file is the one that emits the
    `connect_bd_intf_net ... m%02d_axi ... hbm/SAXI_%02d` lines, so it is the
    only artefact that decides which pseudo-channel a master is physically
    attached to.  A copy in this file would be a second producer of the same
    fact, which is the defect class `tools/hbm_map.py` exists to end.

    The four invariants gen_pcieep.py asserts on its own list are re-asserted
    here rather than assumed, because a scrape that silently returns the wrong
    thing is worse than no scrape: it would place weights on the HOST's
    segments, which is the exact bug this striping is fixing."""
    with open(path) as fp:
        src = fp.read()
    m = re.search(r"^ENG_NMAST\s*=\s*(\d+)\s*$", src, re.M)
    if not m:
        raise SystemExit("pack_model_fk33: no ENG_NMAST in %s" % path)
    nmast = int(m.group(1))
    m = re.search(r"^ENG_PORT_MAP\s*=\s*\[(.*?)\]", src, re.M | re.S)
    if not m:
        raise SystemExit("pack_model_fk33: no ENG_PORT_MAP in %s" % path)
    pm = [int(x) for x in re.findall(r"\d+", m.group(1))]
    if len(pm) != nmast:
        raise SystemExit("pack_model_fk33: %s has ENG_NMAST %d and an "
                         "ENG_PORT_MAP of %d entries"
                         % (path, nmast, len(pm)))
    if len(set(pm)) != nmast:
        raise SystemExit("pack_model_fk33: ENG_PORT_MAP has a duplicate")
    if 0 in pm or 16 in pm:
        raise SystemExit("pack_model_fk33: ENG_PORT_MAP names SAXI_00 or "
                         "SAXI_16, which belong to the HOST")
    if not all(1 <= x <= 31 for x in pm):
        raise SystemExit("pack_model_fk33: ENG_PORT_MAP index out of range")
    # The granule this file stripes at has to be the granule that file maps at.
    if "-range 256M" not in src or "$s * 0x10000000" not in src:
        raise SystemExit(
            "pack_model_fk33: %s no longer maps the HBM segments at "
            "0x10000000 x 256M, so SEGMENT_BYTES = %#x here is stale.  "
            "Striping at the wrong granule puts every lane back on one "
            "pseudo-channel and looks like it worked." % (path, SEGMENT_BYTES))
    return pm


def segment_of(addr):
    return addr // SEGMENT_BYTES
# THE TWO ARENAS NOTHING ALLOCATES WITHIN, SIZED FROM THE SHAPE.
#
# Both are reserved as a single opaque extent and the manifest has never said
# what is inside them, so no check can see a per-layer slot land on its
# neighbour.  The FACTORS are written into the manifest (`gdn_state_layers` /
# `gdn_state_bytes_per_layer`, `kv_layers` / `kv_bytes_per_layer_per_token`) so
# the sub-structure is at least DECLARED, and `check_arena_substructure()`
# below refuses a reservation that is too small for the program.
#
# THESE USED TO BE FOUR LITERALS AND EVERY ONE OF THEM WAS A 27B FIGURE
# (TRACK KVSIZE, 2026-08-29):
#
#     GDN_STATE_LAYERS             = 48    27B's 64 blocks / interval 4
#     GDN_STATE_BYTES_PER_LAYER    = 6144 * 128 * 2    6144 = 27B's d_inner
#     KV_LAYERS                    = 16    27B's attention layer count
#     KV_BYTES_PER_LAYER_PER_TOKEN = 4 * 256 * 2 * 2   int16, and no record
#                                          header: the RTL stores an int8 BFP
#                                          record of 16 + HEAD_DIM bytes
#
# TRACK ARENA-MANIFEST caught the two layer counts and deliberately left the
# per-layer terms, saying they needed the RTL as their oracle.  They did, and
# both were wrong as well.  Nothing is restated here now: `hbm_map.arena_sizes`
# DERIVES every term from `rtl/model_cfg_pkg.vhd` and from the format constants
# in the RTL that implements each arena, and hard-fails if a scrape stops
# matching.  A figure derived from the shape cannot be a different model's.
_ARENA = HM.arena_sizes()
GDN_STATE_LAYERS = _ARENA["gdn_layers"]
GDN_STATE_BYTES_PER_LAYER = _ARENA["gdn_state_bytes_per_layer"]
GDN_STATE_BYTES = _ARENA["gdn_state_bytes"]
KV_LAYERS = _ARENA["attn_layers"]
KV_BYTES_PER_LAYER_PER_TOKEN = _ARENA["kv_bytes_per_layer_per_token"]
KV_BYTES_PER_TOKEN = _ARENA["kv_bytes_per_token"]


def check_arena_substructure(files):
    """The GDN and KV arenas, against the program that will use them.

    UNDER-reservation is a wrong answer: a 25th GDN slot in a 24-slot arena
    lands on the KV cache.  OVER-reservation only costs context, so it is
    REPORTED and not refused -- a check that fails on a safe configuration
    trains people to ignore it.

    SINCE 2026-08-29 THE SIZES ARE DERIVED FROM `rtl/model_cfg_pkg.vhd`, so the
    interesting comparison here changed.  It is no longer "does a literal match
    the program"; it is **does `gen_layer_program.QWEN35_9B` -- the Python
    mirror of the shape, which is what actually emits the descriptors -- agree
    with the RTL record the arenas were sized from**.  Those are two
    independent transcriptions of the same shape and a disagreement between
    them means one of the two is emitting for a model the other did not
    reserve for.  That is a HARD failure, not a note.

    Returns the factor keys for the manifest."""
    lm = next((e for e in files if e.get("tensor") == "output.weight"), None)
    base = dict(gdn_state_layers=GDN_STATE_LAYERS,
                gdn_state_bytes_per_layer=GDN_STATE_BYTES_PER_LAYER,
                kv_layers=KV_LAYERS,
                kv_bytes_per_layer_per_token=KV_BYTES_PER_LAYER_PER_TOKEN,
                kv_record_bytes=_ARENA["kv_record_bytes"],
                gdn_state_mant_bytes_per_layer=(
                    _ARENA["gdn_state_mant_bytes_per_layer"]),
                gdn_state_exp_bytes_per_layer=(
                    _ARENA["gdn_state_exp_bytes_per_layer"]),
                arena_sizing="derived from rtl/model_cfg_pkg.vhd by "
                             "tools/hbm_map.py arena_sizes()")
    if lm is None:
        return base
    import gen_layer_program as GL
    s = GL.QWEN35_9B
    if (int(lm["K"]), int(lm["M"])) != (s.hidden, s.vocab_shard):
        return base
    n_gdn, n_attn = s.n_gdn(), s.n_attn()
    if (n_gdn, n_attn) != (GDN_STATE_LAYERS, KV_LAYERS):
        raise SystemExit(
            "pack_model_fk33: gen_layer_program.QWEN35_9B says %d GDN and %d "
            "attention blocks, and rtl/model_cfg_pkg.vhd says %d and %d.  The "
            "descriptors are emitted from the first and the arenas are "
            "reserved from the second, so one of them is about a different "
            "model.  The RTL is the oracle; fix the mirror."
            % (n_gdn, n_attn, GDN_STATE_LAYERS, KV_LAYERS))
    if (s.attn_kv_heads, s.attn_head_dim) != (
            _ARENA["kv_heads_per_card"], _ARENA["attn_head_dim"]):
        raise SystemExit(
            "pack_model_fk33: gen_layer_program.QWEN35_9B has attn_kv_heads "
            "%d / attn_head_dim %d against the RTL's %d / %d.  The KV record "
            "is sized on the second pair."
            % (s.attn_kv_heads, s.attn_head_dim,
               _ARENA["kv_heads_per_card"], _ARENA["attn_head_dim"]))
    base.update(gdn_state_layers_used=n_gdn, kv_layers_used=n_attn)
    return base


def align_up(n: int) -> int:
    return (n + ALIGN - 1) & ~(ALIGN - 1)


def stack_of(off: int) -> int:
    return off // STACK_BYTES


def place(off: int, nbytes: int):
    """Next legal base for `nbytes` at or after `off`.  See THE STACK RULE.

    Returns (base, hole_bytes).  `base` is 4 KB aligned and `[base, base+nbytes)`
    contains no stack boundary strictly inside it.  `hole_bytes` is what was
    skipped, which the caller records rather than silently loses.

    Written as a loop over boundaries rather than as one `if` so that it is
    correct for an object larger than a stack (it cannot be placed at all, and
    the loop terminates on the range check instead of looping forever) and for
    any future HBM with more than two stacks.
    """
    base = align_up(off)
    hole = 0
    while True:
        if nbytes > STACK_BYTES:
            raise ValueError(f"object of {nbytes} B cannot fit in a "
                             f"{STACK_BYTES} B stack")
        b = (base // STACK_BYTES + 1) * STACK_BYTES     # next boundary above
        if base + nbytes <= b:
            return base, hole                            # wholly inside a stack
        hole += b - base
        base = b                                         # skip to the boundary


def lane_stripe_plan(recs, rows_if, axi_dw, port_map, outdir, nm_size):
    """THE 27-LANE ARENA.  One pseudo-channel per AXI read master.

    THE FINDING THIS IMPLEMENTS (TRACK COUNTERS, 2026-08-30,
    docs/debugging/2026-08-30_counters-cycles-beats-starved.md).  A .mv4i is
    laid down contiguously and is far smaller than 256 MiB, so all 27 of its
    sub-regions share ONE segment, i.e. ONE pseudo-channel, and 27 dedicated
    SAXI ports queue behind a single 8.000 GB/s resource.  MEASURED on the
    card: 21.67 core cycles per weight word against a DERIVED
    single-pseudo-channel bound of 21.60, and an aggregate byte rate flat at
    7.4-7.9 GB/s across a 6x range of job size.

    THE PLACEMENT.  Weight sub-region p goes into the 256 MiB segment that
    weight master p's own SAXI port is attached to, `port_map[p]`; scale
    sub-region q goes into `port_map[NPORTS_W + q]`.  Master p then reads only
    from its directly attached pseudo-channel, and -- because gen_pcieep.py
    puts masters 0..14 on SAXI_01..15 (stack 0) and 15..27 on SAXI_17..29
    (stack 1), while HBM_MEM<s> for s < 16 is stack 0 -- it never crosses the
    stack boundary either.  The flat layout could not do that for more than 15
    of the 27 masters at once; this one does it for all 27, by construction.

    NO RTL CHANGE AND NO REPACK.  `w_base[0..23]` and `s_base[0..2]` are
    already 27 independent 64-bit descriptor fields, and the PACKED BYTES do
    not move: this function only decides addresses.  Run without `--force` over
    an existing set and every .mv4i is KEPT byte for byte, which is what makes
    the blake2b digests in the manifest an oracle for "addresses changed,
    values did not".

    WHAT MOVES, IN ADDRESS ORDER
    ---------------------------
      segment 0            the 4 KB .mv4i HEADERS and nonmatvec_f32.bin.
                           SAXI_00 is the host's, so nothing here is on a
                           weight lane's pseudo-channel.  The engine never
                           reads a header -- the descriptor carries every field
                           -- but `fk33_load_weights.py verify` reads it back,
                           so it has to be resident and it has to be findable,
                           which is why `hbm_offset` keeps meaning "where this
                           file's header is".
      port_map[p]          lane p's weight or scale arena, bump-allocated in
                           manifest order from the bottom of the segment.
      16                   RESERVED FREE.  The other host port.  Reachable, and
                           deliberately unused: see the note on KV below.
      29, 30, 31           GDN state then the KV cache, then the descriptor
                           arena and the host blocks that
                           `hbm_map.derive_region_block()` anchors to the top.

    THE COST, AND IT IS CONTEXT, NOT CAPACITY.  The 27 lane arenas are equal
    (see the GRP note below) and each is well under a segment, so total free
    space is essentially unchanged.  What changes is that the free space is
    now 27 segment TAILS plus segment 16, and `server/fk33_manifest.c` requires
    `gdn_state_base >= weights_end` while `rtl/attn_kv_axi.vhd` addresses KV
    from ONE linear base (`C_K_BASE_CH`).  So the contiguous KV run is only
    what lies above the highest lane arena.  The tails are real memory and a
    consumer that could read `hbm.kv_extents` -- which this manifest already
    emits -- would get them back.  The number is printed, not buried.

    THE LANE ARENAS ARE EQUAL BY COINCIDENCE, NOT BY RULE.  At the FK33
    geometry GRP = 1, so `layout_strides()`'s scale stride equals its weight
    stride and all 27 lanes need identical bytes.  At GRP > 1 a scale lane
    needs 1/GRP as much.  Nothing below assumes equality: every lane is sized
    from its own sub-region sizes.  (`tools/gen_mv4i_desc.py::layout_strides`
    records what assuming that equality already cost once.)

    Returns (files, lane, common) where `files` is the manifest's file list
    with a `pieces` array on every entry, `lane` is the per-lane arena record
    and `common` describes segment 0.
    """
    npw = P.check_geometry(rows_if, axi_dw, emitting=False)
    nss = P.n_scale_sub(rows_if, axi_dw)
    nlane = npw + nss
    if len(port_map) < nlane:
        raise SystemExit("pack_model_fk33: the geometry needs %d read masters "
                         "and gen_pcieep.py's ENG_PORT_MAP has %d entries"
                         % (nlane, len(port_map)))
    seg = [port_map[i] for i in range(nlane)]
    if len(set(seg)) != nlane:
        raise SystemExit("pack_model_fk33: two lanes would share a segment")

    # ---- the lane arenas, bump-allocated from the bottom of their segment
    cur = [s * SEGMENT_BYTES for s in seg]
    top = [(s + 1) * SEGMENT_BYTES for s in seg]

    # ---- segment 0: headers first, then the F32 side file
    com = 0
    files, weights_end = [], 0

    def take(lane, nbytes):
        base = align_up(cur[lane])
        if base + nbytes > top[lane]:
            raise SystemExit(
                "pack_model_fk33: lane %d overflows HBM segment %d.  It needs "
                "%d B and the segment holds %d.  This is the capacity wall the "
                "27-lane arena has; the fallback is to stripe over fewer "
                "segments (two lanes per segment costs about half the gain) "
                "or to drop a tensor.  Nothing was written."
                % (lane, seg[lane], base + nbytes - seg[lane] * SEGMENT_BYTES,
                   SEGMENT_BYTES))
        cur[lane] = base + nbytes
        return base

    for r in recs:
        lay = P.packed_layout(r["M"], r["K"], rows_if, axi_dw, emitting=False)
        _, _, np_, sub_sz, nss_, scl_sz, tot_ = lay
        if (np_, nss_) != (npw, nss):
            raise SystemExit("pack_model_fk33: %s has %d/%d sub-regions and "
                             "the geometry says %d/%d"
                             % (r["name"], np_, nss_, npw, nss))
        if tot_ != r["nbytes"]:
            raise SystemExit("pack_model_fk33: %s layout says %d B, the packed "
                             "file is %d B" % (r["name"], tot_, r["nbytes"]))
        hdr_base = align_up(com)
        com = hdr_base + P.HDR_BYTES
        pieces = [dict(kind="header", lane=None, segment=segment_of(hdr_base),
                       file_offset=0, nbytes=P.HDR_BYTES, hbm_offset=hdr_base)]
        off = P.HDR_BYTES
        for p in range(npw):
            b = take(p, sub_sz)
            pieces.append(dict(kind="w", lane=p, segment=seg[p],
                               file_offset=off, nbytes=sub_sz, hbm_offset=b))
            off += sub_sz
        for q in range(nss):
            b = take(npw + q, scl_sz)
            pieces.append(dict(kind="s", lane=npw + q, segment=seg[npw + q],
                               file_offset=off, nbytes=scl_sz, hbm_offset=b))
            off += scl_sz
        if off != r["nbytes"]:
            raise SystemExit("pack_model_fk33: %s pieces cover %d of %d bytes"
                             % (r["name"], off, r["nbytes"]))
        ent = dict(file=r["name"] + ".mv4i", kind="mv4i", tensor=r["name"],
                   M=r["M"], K=r["K"], w_exp=r["w_exp"],
                   out_shift=r["out_shift"], nbytes=r["nbytes"],
                   hbm_offset=hdr_base, stack=stack_of(hdr_base),
                   striped=True, pieces=pieces,
                   blake2b_128=digest(os.path.join(outdir,
                                                   r["name"] + ".mv4i")))
        if r.get("segments"):
            ent["M_logical"] = r["m_logical"]
            ent["segments"] = r["segments"]
        files.append(ent)
        weights_end = max(weights_end, max(x["hbm_offset"] + x["nbytes"]
                                           for x in pieces))

    nm_base = align_up(com)
    com = nm_base + nm_size
    weights_end = max(weights_end, com)
    if com > SEGMENT_BYTES:
        raise SystemExit("pack_model_fk33: the headers and nonmatvec_f32.bin "
                         "need %d B and segment 0 holds %d"
                         % (com, SEGMENT_BYTES))

    lane = [dict(lane=i, kind=("w" if i < npw else "s"),
                 index=(i if i < npw else i - npw), master=i, saxi=seg[i],
                 segment=seg[i], stack=stack_of(seg[i] * SEGMENT_BYTES),
                 base=seg[i] * SEGMENT_BYTES,
                 bytes=cur[i] - seg[i] * SEGMENT_BYTES,
                 capacity=SEGMENT_BYTES)
            for i in range(nlane)]
    common = dict(segment=0, base=0, bytes=com, capacity=SEGMENT_BYTES,
                  holds="mv4i headers and nonmatvec_f32.bin")
    return files, lane, common, nm_base, weights_end


def expand_pieces(files):
    """The manifest's file list re-expressed as one entry per PLACED EXTENT.

    A striped `files` entry is one FILE at 28 addresses.  Anything that reasons
    about the address space -- `tools/hbm_map.py`'s region model, and any
    residency checker -- needs the extents, not the files, or it will believe a
    4 KB header occupies the whole `nbytes`.  This is the adaptor, in one place,
    so no consumer grows a second idea of where a tensor is."""
    out = []
    for f in files:
        if not f.get("pieces"):
            out.append(f)
            continue
        for i, x in enumerate(f["pieces"]):
            tag = ("hdr" if x["kind"] == "header"
                   else "%s%02d" % (x["kind"], x["lane"]))
            e = dict(file="%s:%s" % (f["file"], tag), kind=f["kind"],
                     tensor=f.get("tensor"), nbytes=x["nbytes"],
                     hbm_offset=x["hbm_offset"],
                     stack=stack_of(x["hbm_offset"]),
                     piece_of=f["file"], piece_index=i)
            # M and K ride on the HEADER piece only.  `hbm_map` finds the LM
            # head by `tensor == "output.weight"` and reads M/K off it to model
            # the host blocks; putting the shape on all 28 pieces would give it
            # 28 identical candidates and hide a future duplicate.
            if x["kind"] == "header":
                e["M"], e["K"] = f.get("M"), f.get("K")
            out.append(e)
    return out


def check_lane_stripe(files, lane, common, port_map, rows_if, axi_dw):
    """TEETH.  Every property the striping is FOR, checked on the output.

    Six of them, and each one names a way the placement can be built, load
    cleanly, verify green and still be wrong:

      1. every piece is inside the segment it claims, and that segment is the
         one `port_map` gives its lane.  A piece one byte over a 256 MiB
         boundary reads out of the NEXT pseudo-channel and nothing faults.
      2. every piece is 4 KB aligned in HBM and in the file (spec 6.4, and the
         gateware's EC 0xC refuses a base with [11:0] nonzero).
      3. the pieces of a file cover [0, nbytes) exactly once, in increasing
         file order, with no gap and no overlap -- which is what makes the
         manifest's pack-time blake2b of the WHOLE file still checkable by
         reading the pieces back in order.
      4. no two pieces anywhere overlap in HBM.
      5. every lane's arena is inside its segment.
      6. THE POINT: for every tensor, the 27 data pieces occupy 27 DISTINCT
         segments.  This is the one that would have caught the flat layout.

    Returns a list of (name, ok, detail).  Nothing is printed here; the caller
    decides.  A check that only ever runs on a passing input has not been shown
    to work, so `--stripe-teeth` runs each of these against a deliberately
    broken copy of the plan."""
    npw = P.check_geometry(rows_if, axi_dw, emitting=False)
    nss = P.n_scale_sub(rows_if, axi_dw)
    out = []
    bad = []
    for f in files:
        if not f.get("pieces"):
            continue
        for x in f["pieces"]:
            a, n = x["hbm_offset"], x["nbytes"]
            if segment_of(a) != x["segment"] or segment_of(a + n - 1) != x["segment"]:
                bad.append("%s %s piece at %#x+%d is not inside segment %d"
                           % (f["file"], x["kind"], a, n, x["segment"]))
            if x["kind"] == "w" and x["segment"] != port_map[x["lane"]]:
                bad.append("%s w[%d] is in segment %d, master %d is on SAXI_%02d"
                           % (f["file"], x["lane"], x["segment"], x["lane"],
                              port_map[x["lane"]]))
            if x["kind"] == "s" and x["segment"] != port_map[x["lane"]]:
                bad.append("%s s[%d] is in segment %d, master %d is on SAXI_%02d"
                           % (f["file"], x["lane"] - npw, x["segment"],
                              x["lane"], port_map[x["lane"]]))
    out.append(("1 every piece is in its master's own segment", not bad,
                "%d violation(s)%s" % (len(bad),
                                       "" if not bad else ": " + bad[0])))

    bad = [("%s %s piece hbm %#x file +%d" % (f["file"], x["kind"],
                                              x["hbm_offset"], x["file_offset"]))
           for f in files if f.get("pieces") for x in f["pieces"]
           if x["hbm_offset"] % ALIGN or x["file_offset"] % ALIGN]
    out.append(("2 every piece 4 KB aligned in HBM and in the file", not bad,
                "%d violation(s)%s" % (len(bad),
                                       "" if not bad else ": " + bad[0])))

    bad = []
    for f in files:
        if not f.get("pieces"):
            continue
        pos = 0
        for x in sorted(f["pieces"], key=lambda y: y["file_offset"]):
            if x["file_offset"] != pos:
                bad.append("%s: piece at file +%d, expected +%d"
                           % (f["file"], x["file_offset"], pos))
                break
            pos += x["nbytes"]
        else:
            if pos != f["nbytes"]:
                bad.append("%s: pieces cover %d of %d bytes"
                           % (f["file"], pos, f["nbytes"]))
    out.append(("3 the pieces tile the file exactly, in order", not bad,
                "%d violation(s)%s" % (len(bad),
                                       "" if not bad else ": " + bad[0])))

    ext = sorted(((x["hbm_offset"], x["nbytes"], f["file"], x["kind"])
                  for f in files if f.get("pieces") for x in f["pieces"]),
                 key=lambda t: t[0])
    bad = ["%s %s at %#x+%d overlaps %s %s at %#x"
           % (ext[i][2], ext[i][3], ext[i][0], ext[i][1],
              ext[i + 1][2], ext[i + 1][3], ext[i + 1][0])
           for i in range(len(ext) - 1)
           if ext[i][0] + ext[i][1] > ext[i + 1][0]]
    out.append(("4 no two pieces overlap in HBM", not bad,
                "%d of %d adjacent pairs%s" % (len(bad), max(len(ext) - 1, 0),
                                               "" if not bad else ": " + bad[0])))

    bad = ["lane %d: %d B in a %d B segment" % (L["lane"], L["bytes"],
                                                L["capacity"])
           for L in lane if L["bytes"] > L["capacity"]]
    out.append(("5 every lane arena fits its segment", not bad,
                "max fill %.1f%%"
                % (100.0 * max((L["bytes"] / float(L["capacity"])
                                for L in lane), default=0.0))))

    want = npw + nss
    bad = []
    for f in files:
        if not f.get("pieces"):
            continue
        segs = {x["segment"] for x in f["pieces"] if x["kind"] in ("w", "s")}
        if len(segs) != want:
            bad.append("%s spans %d segments, wanted %d"
                       % (f["file"], len(segs), want))
    out.append(("6 every tensor's %d data pieces are in %d DISTINCT segments"
                % (want, want), not bad,
                "%d tensor(s) not fully striped%s"
                % (len(bad), "" if not bad else ": " + bad[0])))
    return out


def digest(path: str) -> str:
    """blake2b-128 of a file, recorded in the manifest.

    WITHOUT this the manifest pins only sizes and headers, and a single flipped
    payload byte -- the exact damage a bad disk or a half-finished write leaves
    -- passes every structural check there is.  Measured: `check_mv4i_set.py`
    returned PASS on a file with byte 8192 set to 0xFF.  It is the same digest
    `fk33ctl.py load --verify` prints for the source, so the file on disk, the
    manifest and the bytes in HBM can all be compared to one number.
    """
    h = hashlib.blake2b(digest_size=16)
    with open(path, "rb") as f:
        while True:
            c = f.read(8 << 20)
            if not c:
                break
            h.update(c)
    return h.hexdigest()


def safe_name(name: str) -> str:
    """GGUF tensor names are already filesystem safe here; refuse if not."""
    if "/" in name or name in (".", "..") or name.startswith("-"):
        raise ValueError(f"tensor name is not a safe filename: {name!r}")
    return name


def dequant_f32(t) -> np.ndarray:
    """One GGUF tensor as a flat little-endian float32 array, GGUF order.

    `tensor_as_mk` reshapes to (M, K) without reordering, so flattening it
    again yields exactly the GGUF element order (ne0 fastest).  Going through
    it rather than calling `quants.dequantize` here keeps one dequantization
    path in the tree.
    """
    return np.ascontiguousarray(P.tensor_as_mk(t).reshape(-1), dtype="<f4")


def gguf_kv(rd, suffix: str):
    """One GGUF metadata value, addressed by key SUFFIX so the architecture
    prefix (`qwen35.`) does not have to be assumed.  Raises if it is missing or
    ambiguous: a fused-tensor split guessed from a default is exactly the kind
    of silent wrong number this repository keeps paying for."""
    hits = [k for k in rd.fields if k == suffix or k.endswith("." + suffix)]
    if len(hits) != 1:
        raise KeyError(f"GGUF metadata key {suffix!r}: {len(hits)} matches")
    return rd.fields[hits[0]].contents()


def qkv_segments(rd, M: int):
    """The q | k | v row segments of a fused GDN `attn_qkv`, DERIVED from the
    GGUF's own metadata and CHECKED against the tensor's row count.

        key_dim = ssm.state_size * ssm.group_count      (lin_head_dim * lin_key_heads)
        val_dim = ssm.inner_size
        M       = 2 * key_dim + val_dim

    `rtl/model_cfg_pkg.vhd:32-33` states the first two identities; the third is
    `gen_layer_program.Shape.qkv_dim`.  If the identity does not hold the split
    is unknown and nothing is padded -- the caller raises rather than assuming
    2048/2048/4096, which is a per-model number, not a constant.
    """
    key_dim = int(gguf_kv(rd, "ssm.state_size")) * int(gguf_kv(rd, "ssm.group_count"))
    val_dim = int(gguf_kv(rd, "ssm.inner_size"))
    if 2 * key_dim + val_dim != M:
        raise ValueError(
            f"attn_qkv has {M} rows but the GGUF metadata gives "
            f"2*{key_dim} + {val_dim} = {2 * key_dim + val_dim}; the fused "
            f"split is not what this model says it is")
    return [key_dim, key_dim, val_dim], ["q", "k", "v"]


def a_descriptor_jobs(files):
    """How many subsystem A descriptors this set's token program needs.

    COUNTED, not assumed: `tools/gen_layer_program.py.build_plan()` is the only
    thing that knows how many A_JOB steps a token is, and it builds the plan
    from a Shape alone -- no manifest -- so importing it here is not circular.
    The count is the MAXIMUM over every variant of the program, because
    `--qkv-fused` and `--one-lmhead-job` both REDUCE it (MEASURED 2026-08-29:
    311 default, 297 one-lmhead, 263 qkv-fused, 249 both) and a reservation
    that is too small for a variant somebody runs later is a silent overrun
    into the host's R_X staging.

    REFUSES on a shape that generator does not describe, rather than guessing.
    `--desc-arena-jobs N` is the way to state it for such a model."""
    import gen_layer_program as GL
    lm = next((e for e in files if e.get("tensor") == "output.weight"), None)
    if lm is None:
        raise SystemExit(
            "pack_model_fk33: no output.weight in this set, so the token "
            "program's A job count cannot be counted and the host blocks "
            "cannot be modelled.  Pass --desc-arena-jobs N, or "
            "--no-region-block and accept that fk33_manifest.c refuses the "
            "result.  A partial pack (--only) is not a loadable set, so "
            "--no-region-block is the right answer there.")
    s = GL.QWEN35_9B
    if (int(lm["K"]), int(lm["M"])) != (s.hidden, s.vocab_shard):
        raise SystemExit(
            "pack_model_fk33: this set's output.weight is %d x %d and "
            "tools/gen_layer_program.py describes %d x %d.  The A descriptor "
            "count is a property of the PROGRAM, and that generator is the "
            "only thing that knows it; it does not describe this model.  Pass "
            "--desc-arena-jobs N."
            % (int(lm["M"]), int(lm["K"]), s.vocab_shard, s.hidden))
    best, how = 0, None
    for one_lm in (False, True):
        for fused in (False, True):
            lmw = [(0, s.vocab_shard)] if one_lm else GL.lmhead_windows(s)
            steps = GL.build_plan(s, qkv_fused=fused, lm_windows=lmw)
            n = sum(1 for st in steps if st.opcode == GL.OP_A_JOB)
            if n > best:
                best, how = n, (one_lm, fused)
    print(f"  A job count      {best} descriptors, the max over the four "
          f"program variants (one_lmhead={how[0]} qkv_fused={how[1]})")
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gguf")
    ap.add_argument("outdir")
    ap.add_argument("--rows-if", type=int, default=48)
    ap.add_argument("--axi-dw", type=int, default=256)
    ap.add_argument("--only", default=None,
                    help="pack only tensors whose name contains this substring")
    ap.add_argument("--force", action="store_true",
                    help="repack even when an output of the right size exists")
    ap.add_argument("--no-qkv-pad", dest="qkv_pad", action="store_false",
                    default=True,
                    help="do NOT pad the fused attn_qkv row segments up to a "
                         "whole ROWS_IF tile. Reproduces the historic set, in "
                         "which two of the three qkv row windows per GDN block "
                         "are not expressible at ROWS_IF=48")
    ap.add_argument("--max-chunk", type=int, default=512,
                    help="the max_chunk pl_open() will run at.  It sets the "
                         "host R_X span, which is what the subsystem A "
                         "descriptor arena is placed below, so it MOVES the "
                         "arena.  It is PINNED into the manifest as "
                         "hbm.host_max_chunk and a card whose CAPS disagree is "
                         "refused at open time")
    ap.add_argument("--desc-arena-jobs", type=int, default=None,
                    help="how many subsystem A descriptors to reserve for.  "
                         "Default: the maximum over every variant of the full "
                         "token program, counted by importing "
                         "tools/gen_layer_program.py.  Give it explicitly for "
                         "a model that generator does not describe")
    ap.add_argument("--no-region-block", action="store_true",
                    help="do NOT write hbm.desc_arena_* / hbm.host_max_chunk.  "
                         "The result is a manifest server/fk33_manifest.c "
                         "REFUSES and tools/gen_layer_program.py refuses to "
                         "emit descriptors against.  It exists so the refusal "
                         "can be demonstrated, and for no other reason")
    ap.add_argument("--stripe-lanes", action="store_true",
                    help="place each tensor's 27 sub-regions in the 27 "
                         "DIFFERENT 256 MiB HBM segments their own AXI read "
                         "masters are attached to, instead of contiguously "
                         "inside one.  The packed .mv4i bytes do NOT change: "
                         "run without --force over an existing set and every "
                         "file is KEPT, so the manifest's blake2b digests are "
                         "unchanged and the only difference is addresses.  The "
                         "manifest's `format` becomes v2 and every mv4i entry "
                         "grows a `pieces` array, because `hbm_offset` then "
                         "names a 4 KB header and not a contiguous image")
    ap.add_argument("--drop", action="append", default=[], metavar="TENSOR",
                    help="exact GGUF tensor name to leave OUT of the image: not "
                         "packed, not placed, not in the manifest's files. "
                         "Repeatable. DEFAULT: drop nothing, which reproduces "
                         "the set this tool made before the option existed. "
                         "Refuses a name the GGUF does not have. Intended use "
                         "is --drop token_embd.weight, because the host owns "
                         "the embedding gather and nothing on the card reads "
                         "that tensor")
    a = ap.parse_args()

    rows_if, axi_dw = a.rows_if, a.axi_dw
    nports = P.check_geometry(rows_if, axi_dw, emitting=True)
    nss = P.n_scale_sub(rows_if, axi_dw)
    os.makedirs(a.outdir, exist_ok=True)

    print(f"model    {a.gguf}")
    print(f"outdir   {a.outdir}")
    print(f"geometry ROWS_IF={rows_if} AXI_DW={axi_dw} BLOCK={P.BLOCK} "
          f"-> NPORTS_W={nports} n_scale_sub={nss} "
          f"({nports + nss} AXI read masters)")
    sys.stdout.flush()

    rd = GGUFReader(a.gguf, "r")
    all_tensors = list(rd.tensors)

    # ---------------------------------------------------------- --drop
    # Resolved against the GGUF's own tensor list and REFUSED if a name does
    # not match exactly one tensor.  An unmatched --drop would otherwise be a
    # no-op that still reports success, i.e. an image nobody notices is full
    # size.  Done before classification so a dropped tensor is invisible to
    # everything downstream: it is not packed, not placed, not counted.
    drop_names = list(dict.fromkeys(a.drop))          # dedup, keep order
    by_name = {}
    for t in all_tensors:
        by_name.setdefault(t.name, []).append(t)
    for n in drop_names:
        if len(by_name.get(n, [])) != 1:
            raise SystemExit(
                f"--drop {n!r}: the GGUF has {len(by_name.get(n, []))} tensors "
                f"with that exact name, want exactly 1. Nothing was written.")
    dropped = []
    for n in drop_names:
        t = by_name[n][0]
        ne = [int(v) for v in t.shape]
        is_mv = P.is_matvec(t.name, ne)
        would = (P.packed_layout(ne[1], ne[0], rows_if, axi_dw,
                                 emitting=False)[-1] if is_mv
                 else align_up(int(np.prod(ne)) * 4))
        dropped.append(dict(name=n, shape_ne=ne, matvec=bool(is_mv),
                            bytes_if_placed=int(would)))
    tensors = [t for t in all_tensors if t.name not in set(drop_names)]

    mv, nonmv = [], []
    for t in tensors:
        ne = [int(v) for v in t.shape]
        (mv if P.is_matvec(t.name, ne) else nonmv).append(t)
    print(f"tensors  {len(all_tensors)} in the GGUF, {len(dropped)} dropped, "
          f"{len(tensors)} placed: {len(mv)} matvec, {len(nonmv)} kept F32")
    for d in dropped:
        print(f"  DROPPED {d['name']} ne={d['shape_ne']} "
              f"{'matvec' if d['matvec'] else 'f32'}, "
              f"{d['bytes_if_placed']} B not placed")
    sys.stdout.flush()

    # ---------------------------------------------------- the 177, one blob
    nm_path = os.path.join(a.outdir, "nonmatvec_f32.bin")
    nm_entries, cur = [], 0
    for t in nonmv:
        ne = [int(v) for v in t.shape]
        nbytes = int(np.prod(ne)) * 4
        nm_entries.append(dict(name=t.name, shape_ne=ne, offset=cur,
                               nbytes=nbytes, dtype="f32le"))
        cur = align_up(cur + nbytes)
    nm_size = cur

    if a.only is None and (a.force or not os.path.exists(nm_path)
                           or os.path.getsize(nm_path) != nm_size):
        t0 = time.perf_counter()
        with open(nm_path, "wb") as f:
            f.truncate(nm_size)
            for t, e in zip(nonmv, nm_entries):
                blob = dequant_f32(t).tobytes()
                assert len(blob) == e["nbytes"], (t.name, len(blob), e["nbytes"])
                f.seek(e["offset"])
                f.write(blob)
        assert os.path.getsize(nm_path) == nm_size
        print(f"wrote nonmatvec_f32.bin  {nm_size} bytes, {len(nonmv)} tensors, "
              f"{time.perf_counter() - t0:.1f} s")
    elif a.only is not None:
        print(f"--only given: nonmatvec_f32.bin not touched "
              f"(it would be {nm_size} bytes)")
    else:
        print(f"nonmatvec_f32.bin present at {nm_size} bytes, kept")
    sys.stdout.flush()

    # ------------------------------------------------------- the 250 matvec
    log_path = os.path.join(a.outdir, "pack.log")
    logf = open(log_path, "a")
    logf.write(f"# {time.strftime('%Y-%m-%d %H:%M:%S')} ROWS_IF={rows_if} "
               f"AXI_DW={axi_dw} NPORTS_W={nports} n_scale_sub={nss}\n")
    logf.write("# name\tM\tK\tw_exp\tout_shift\tNB\tbytes\tbits_per_weight\t"
               "seconds\tstatus\n")
    logf.flush()

    recs = []
    t_all = time.perf_counter()
    for i, t in enumerate(mv):
        name = safe_name(t.name)
        if a.only and a.only not in name:
            continue
        ne = [int(v) for v in t.shape]
        K, M = ne[0], ne[1]

        # THE qkv SEGMENT PAD.  See the module docstring.  `M` from here on is
        # the PADDED row count -- it is what the header, the file size and the
        # manifest all have to agree on -- and `m_logical`/`segs` carry the
        # real rows and the windows a program generator issues.
        seg_plan, segs, m_logical = None, None, M
        if a.qkv_pad and name.endswith("attn_qkv.weight"):
            seg_rows, seg_names = qkv_segments(rd, M)
            M, seg_plan = P.segment_row_plan(seg_rows, rows_if)
            segs = [dict(name=nm, row_start=q["row_start"], n_rows=q["n_rows"],
                         pad_rows=q["pad"], logical_row=q["src_start"])
                    for nm, q in zip(seg_names, seg_plan)]
            for q in segs:
                assert q["row_start"] % rows_if == 0, (name, q)
            assert M >= m_logical

        size = P.packed_layout(M, K, rows_if, axi_dw)[-1]
        out = os.path.join(a.outdir, name + ".mv4i")

        if (not a.force) and os.path.exists(out) and os.path.getsize(out) == size:
            w_exp, out_shift = struct.unpack_from(
                "<ii", open(out, "rb").read(0x18), 0x10)
            recs.append(dict(name=name, M=M, K=K, w_exp=w_exp,
                             out_shift=out_shift, nbytes=size,
                             m_logical=m_logical, segments=segs))
            logf.write(f"{name}\t{M}\t{K}\t{w_exp}\t{out_shift}\t"
                       f"{(K + P.BLOCK - 1)//P.BLOCK}\t{size}\t"
                       f"{size*8.0/(m_logical*K):.4f}\t0.0\tKEPT\n")
            logf.flush()
            print(f"[{i+1}/{len(mv)}] {name} kept ({size} B)")
            sys.stdout.flush()
            continue

        t0 = time.perf_counter()
        W = P.tensor_as_mk(t)
        assert W.shape == (m_logical, K), (W.shape, m_logical, K)
        if seg_plan is not None:
            W = P.apply_segment_padding(W, M, seg_plan)
        assert W.shape == (M, K), (W.shape, M, K)
        idx, scale, w_exp = P.quantize(W, P.IQ4_NL)
        del W                                   # 4 GB on the two 1.0e9 tensors
        out_shift = P.calibrate_out_shift(K)
        blob = P.pack(idx, scale, w_exp, M, K, rows_if, out_shift,
                      P.IQ4_NL, axi_dw)
        del idx, scale
        assert len(blob) == size, (len(blob), size)
        tmp = out + ".part"
        with open(tmp, "wb") as f:
            f.write(blob)
        del blob
        os.replace(tmp, out)
        dt = time.perf_counter() - t0

        recs.append(dict(name=name, M=M, K=K, w_exp=w_exp,
                         out_shift=out_shift, nbytes=size,
                         m_logical=m_logical, segments=segs))
        logf.write(f"{name}\t{M}\t{K}\t{w_exp}\t{out_shift}\t"
                   f"{(K + P.BLOCK - 1)//P.BLOCK}\t{size}\t"
                   f"{size*8.0/(m_logical*K):.4f}\t{dt:.1f}\tPACKED\n")
        logf.flush()
        print(f"[{i+1}/{len(mv)}] {name} M={M} K={K} w_exp={w_exp} "
              f"out_shift={out_shift} {size} B "
              f"{size*8.0/(m_logical*K):.3f} bpw {dt:.1f} s")
        sys.stdout.flush()

    logf.close()
    if a.only:
        print("--only given: no manifest written")
        return 0

    # ---------------------------------------------------------- the load map
    off = 0
    files = []
    holes = []
    lane, common, stripe_checks, port_map = None, None, None, None
    print("hashing the set for the manifest ...")
    sys.stdout.flush()
    if a.stripe_lanes:
        port_map = scrape_eng_port_map()
        files, lane, common, nm_base, weights_end = lane_stripe_plan(
            recs, rows_if, axi_dw, port_map, a.outdir, nm_size)
        files.append(dict(file="nonmatvec_f32.bin", kind="f32blob",
                          tensor=None, nbytes=nm_size, hbm_offset=nm_base,
                          stack=stack_of(nm_base),
                          blake2b_128=digest(nm_path),
                          entries=[dict(e, hbm_offset=nm_base + e["offset"])
                                   for e in nm_entries]))
        stripe_checks = check_lane_stripe(files, lane, common, port_map,
                                          rows_if, axi_dw)
        for nm, ok, det in stripe_checks:
            print("  stripe check %-58s %s  %s"
                  % (nm, "PASS" if ok else "FAIL", det))
        if not all(ok for _, ok, _ in stripe_checks):
            raise SystemExit("pack_model_fk33: the lane-striped placement "
                             "failed its own checks.  No manifest was written.")
        # GDN and KV start at the next SEGMENT boundary above the highest lane
        # arena, not at the next 4 KB page.  Two reasons, both load-bearing:
        # `server/fk33_manifest.c` requires gdn_state_base >= weights_end, and
        # a 4 KB round-up would leave the GDN state sharing scale lane 2's
        # pseudo-channel -- the exact contention this whole change removes.
        gdn_base = ((weights_end + SEGMENT_BYTES - 1)
                    // SEGMENT_BYTES) * SEGMENT_BYTES
        if segment_of(gdn_base) in set(port_map[:nports + nss]):
            raise SystemExit("pack_model_fk33: the GDN state would land in "
                             "segment %d, which a weight lane owns"
                             % segment_of(gdn_base))
        total = sum(f["nbytes"] for f in files)
    else:
        for r in recs:
            assert off % ALIGN == 0
            base, hole = place(off, r["nbytes"])
            if hole:
                holes.append(dict(offset=off, nbytes=hole,
                                  why=f"stack boundary before {r['name']}.mv4i"))
            ent = dict(file=r["name"] + ".mv4i", kind="mv4i",
                       tensor=r["name"], M=r["M"], K=r["K"],
                       w_exp=r["w_exp"], out_shift=r["out_shift"],
                       nbytes=r["nbytes"], hbm_offset=base,
                       stack=stack_of(base),
                       blake2b_128=digest(
                           os.path.join(a.outdir, r["name"] + ".mv4i")))
            if r.get("segments"):
                # M is the PADDED row count everywhere a size is derived from it.
                # These two fields are the only place the LOGICAL shape and the
                # per-segment row windows are written down, and they exist so that
                # a program generator reads them instead of re-deriving 2064/4128.
                ent["M_logical"] = r["m_logical"]
                ent["segments"] = r["segments"]
            files.append(ent)
            assert r["nbytes"] % ALIGN == 0, r["name"]
            off = base + r["nbytes"]
        nm_base, hole = place(off, nm_size)
        if hole:
            holes.append(dict(offset=off, nbytes=hole,
                              why="stack boundary before nonmatvec_f32.bin"))
        files.append(dict(file="nonmatvec_f32.bin", kind="f32blob",
                          tensor=None, nbytes=nm_size, hbm_offset=nm_base,
                          stack=stack_of(nm_base),
                          blake2b_128=digest(nm_path),
                          entries=[dict(e, hbm_offset=nm_base + e["offset"])
                                   for e in nm_entries]))
        weights_end = align_up(nm_base + nm_size)
        for f in files:
            assert f["hbm_offset"] % ALIGN == 0, f["file"]
            # THE STACK RULE, asserted rather than trusted: the file itself, and
            # every sub-region a master will read out of it.  A .mv4i is a header
            # plus NPORTS_W + n_scale_sub sub-regions, so checking the file is
            # sufficient AND checking it again per sub-region costs nothing.
            assert stack_of(f["hbm_offset"]) \
                == stack_of(f["hbm_offset"] + f["nbytes"] - 1), \
                f'{f["file"]} straddles the {STACK_BYTES} B stack boundary'
            if f["kind"] == "mv4i":
                lay = P.packed_layout(f["M"], f["K"], rows_if, axi_dw,
                                      emitting=False)
                _, _, np_, sub_sz, nss_, scl_sz, tot_ = lay
                assert tot_ == f["nbytes"], (f["file"], tot_, f["nbytes"])
                subs = [(P.HDR_BYTES + sub_sz * p, sub_sz) for p in range(np_)]
                so = P.HDR_BYTES + sub_sz * np_
                subs += [(so + scl_sz * q, scl_sz) for q in range(nss_)]
                for o, n in subs:
                    s = f["hbm_offset"] + o
                    assert stack_of(s) == stack_of(s + n - 1), \
                        f'{f["file"]} sub-region at +{o} straddles the boundary'
            if f["kind"] == "f32blob":
                for e in f["entries"]:
                    assert e["hbm_offset"] % ALIGN == 0, e["name"]
                    assert stack_of(e["hbm_offset"]) \
                        == stack_of(e["hbm_offset"] + e["nbytes"] - 1), e["name"]

        total = sum(f["nbytes"] for f in files)
        gdn_base, hole = place(weights_end, GDN_STATE_BYTES)
        if hole:
            holes.append(dict(offset=weights_end, nbytes=hole,
                              why="stack boundary before the GDN state region"))
    kv_base = align_up(gdn_base + GDN_STATE_BYTES)
    free = HBM_SIZE - kv_base
    hole_bytes = sum(h["nbytes"] for h in holes)

    # KV is a REGION, not an object, so the stack rule applies to the per-token
    # RECORD, not to the region.  Split the region at every stack boundary and
    # count whole records inside each extent; that makes a straddling record
    # impossible by construction rather than by an alignment coincidence, and
    # the extent list is what a KV allocator needs anyway.  The old
    # `free // KV_BYTES_PER_TOKEN` silently permitted one straddling record per
    # boundary crossed.
    kv_extents, p = [], kv_base
    while p < HBM_SIZE:
        e = min((p // STACK_BYTES + 1) * STACK_BYTES, HBM_SIZE)
        kv_extents.append(dict(base=p, nbytes=e - p, stack=stack_of(p),
                               tokens=(e - p) // KV_BYTES_PER_TOKEN))
        p = e
    max_ctx = sum(x["tokens"] for x in kv_extents)

    # ------------------------------------------------- the region block
    #
    # THE MANIFEST IS THE AUTHORITY (Oren, 2026-08-29).  Every base in the 8 GiB
    # is stated here, once, and no consumer re-derives one.  Before this, THREE
    # allocators shared the device and none could see the other two: this
    # packer placed the weights, `tools/gen_layer_program.py` placed the A
    # descriptor arena top-down from 0x2_0000_0000, and
    # `server/pl_backend.c::pl_derive_bases()` placed the host's three blocks
    # top-down from the same address.  The last two COLLIDED -- MEASURED at the
    # 9B shape, 153,664 B of the logits writeback and 3,584 B of the D program
    # page under the arena, whichever master wrote last winning, symptom a
    # wrong token with no fault.
    #
    # The arena address is DERIVED by `tools/hbm_map.py.derive_region_block()`,
    # which is the only function in this repository that chooses one.  It is
    # evaluated HERE, once, because the answer is a property of the packed set
    # and not of whoever runs a tool later: TRACK ADDRARENA measured the old
    # arena base moving with the COMMAND LINE, because it was sized from the
    # selected steps rather than the whole program.
    hbm_core = dict(size=HBM_SIZE, align=ALIGN, stack_bytes=STACK_BYTES,
                    weights_bytes=total, weights_end=weights_end,
                    stack_holes=holes, stack_hole_bytes=hole_bytes,
                    gdn_state_base=gdn_base, gdn_state_bytes=GDN_STATE_BYTES,
                    gdn_state_stack=stack_of(gdn_base),
                    kv_base=kv_base, kv_bytes_per_token=KV_BYTES_PER_TOKEN,
                    kv_extents=kv_extents,
                    free_after_gdn=free,
                    max_context_tokens=max_ctx,
                    **check_arena_substructure(files))
    if a.stripe_lanes:
        # Provenance, so a reader can see WHERE the segment assignment came
        # from without re-deriving it, and a checker can compare against
        # gen_pcieep.py itself rather than against a copy.
        hbm_core["lane_stripe"] = dict(
            segment_bytes=SEGMENT_BYTES, n_segments=N_SEGMENTS,
            eng_port_map=port_map,
            eng_port_map_source="hw/fk33/gen_pcieep.py ENG_PORT_MAP",
            lanes=lane, common=common,
            reserved_segments=sorted(set(range(N_SEGMENTS))
                                     - {L["segment"] for L in lane}),
            checks=[dict(name=n, ok=bool(o), detail=d)
                    for n, o, d in stripe_checks])
    region_block = None
    if not a.no_region_block:
        n_jobs = a.desc_arena_jobs
        if n_jobs is None:
            n_jobs = a_descriptor_jobs(files)
        # `hbm_map.manifest_regions()` models one file as `nbytes` contiguous
        # bytes at `hbm_offset`.  Under striping that is FALSE -- `hbm_offset`
        # is a 4 KB header and the payload is 27 pieces elsewhere -- so it is
        # handed the PIECE list instead of the file list.  That is not a
        # workaround for the check: it is the check being given the truth, and
        # it bites harder than before, because it now compares 6,724 extents
        # rather than 249.  (Handing it the file list refuses with 249 faults,
        # MEASURED.  That refusal is CORRECT and is why `hbm_map.py` itself
        # still needs the six-line `pieces` awareness reported in the write-up:
        # a later `hbm_map.py MANIFEST --markdown` reads the manifest's own
        # file list and cannot see this expansion.)
        region_files = expand_pieces(files) if a.stripe_lanes else files
        region_block = HM.derive_region_block(
            dict(files=region_files, hbm=hbm_core), n_jobs, a.max_chunk)

    man = dict(
        # THE FORMAT STRING IS THE GATE, and it changes on purpose.  A striped
        # manifest's `files[].hbm_offset` names a 4 KB HEADER and NOT the base
        # of `nbytes` contiguous bytes, so a v1 consumer that reads the pair
        # would place, verify or describe the image WRONG while reporting
        # success.  Changing the string is what makes that a refusal instead.
        # The consumers that have to learn `pieces` are listed in
        # docs/debugging/2026-08-30_packstripe-lane-arena-placement.md.
        format=("llama.vhdl FK33 load manifest v2 lane-striped"
                if a.stripe_lanes else "llama.vhdl FK33 load manifest v1"),
        source_gguf=os.path.abspath(a.gguf),
        generated=time.strftime("%Y-%m-%dT%H:%M:%S"),
        geometry=dict(rows_if=rows_if, axi_dw=axi_dw, block=P.BLOCK,
                      nports_w=nports, n_scale_sub=nss,
                      axi_read_masters=nports + nss,
                      qkv_segment_pad=bool(a.qkv_pad),
                      lane_stripe=bool(a.stripe_lanes)),
        hbm=dict(hbm_core, **(region_block or {})),
        # `tensors` counts what is PLACED, so it stays the sum of matvec+f32
        # and `check_mv4i_set.py`'s count check keeps its meaning.  What the
        # GGUF held is recorded separately, so the two can never be confused.
        counts=dict(tensors=len(tensors), matvec=len(mv), f32=len(nonmv),
                    gguf_tensors=len(all_tensors), dropped=len(dropped)),
        dropped_tensors=dropped,
        files=files,
    )
    mpath = os.path.join(a.outdir, "manifest.json")
    with open(mpath, "w") as f:
        json.dump(man, f, indent=1)
    print(f"\nwrote {mpath}")
    G = 1024.0 ** 3
    print(f"  weights          {total} B  {total/G:.3f} GiB  "
          f"({100.0*total/HBM_SIZE:.1f} % of 8 GiB)")
    print(f"  GDN state        {GDN_STATE_BYTES/1024**2:.1f} MB at "
          f"{gdn_base:#x}")
    if dropped:
        tot_d = sum(d["bytes_if_placed"] for d in dropped)
        print(f"  dropped          {len(dropped)} tensor(s), {tot_d} B "
              f"({tot_d/G:.3f} GiB) NOT placed: "
              + ", ".join(d["name"] for d in dropped))
    else:
        print("  dropped          none")
    print(f"  qkv segment pad  {'on' if a.qkv_pad else 'OFF'}, "
          f"{sum(1 for f in files if f.get('segments'))} fused tensor(s) padded")
    if a.stripe_lanes:
        M = 1024.0 ** 2
        print(f"  lane stripe      ON, {len(lane)} lanes on segments "
              f"{','.join(str(L['segment']) for L in lane[:3])}.."
              f"{lane[-1]['segment']} at {SEGMENT_BYTES//M:.0f} MiB each")
        print(f"    per lane       {lane[0]['bytes']} B = "
              f"{lane[0]['bytes']/M:.2f} MiB, "
              f"{100.0*lane[0]['bytes']/SEGMENT_BYTES:.1f}% of a segment "
              f"(min {min(L['bytes'] for L in lane)}, "
              f"max {max(L['bytes'] for L in lane)})")
        print(f"    segment 0      {common['bytes']} B of headers + "
              f"nonmatvec_f32.bin")
        print(f"    reserved segs  "
              f"{hbm_core['lane_stripe']['reserved_segments']}")
        tails = sum(L['capacity'] - L['bytes'] for L in lane)
        print(f"    UNUSED         {tails} B = {tails/G:.3f} GiB in the 27 "
              f"segment tails, plus whole reserved segments.  Only an "
              f"extent-aware KV consumer can use them; hbm.kv_extents is "
              f"already emitted")
    print(f"  stack holes      {hole_bytes} B  {hole_bytes/1024**2:.1f} MiB "
          f"in {len(holes)} hole(s)")
    for h in holes:
        print(f"    {h['nbytes']} B at {h['offset']:#x}: {h['why']}")
    print(f"  free for KV      {free/G:.3f} GiB from {kv_base:#x} "
          f"=> {max_ctx} tokens of context "
          f"in {len(kv_extents)} per-stack extent(s)")
    if region_block:
        print(f"  A desc arena     {region_block['desc_arena_bytes']} B at "
              f"{region_block['desc_arena_base']:#x} for "
              f"{region_block['desc_arena_jobs']} descriptors at "
              f"{region_block['desc_arena_stride']} B, under host_max_chunk "
              f"{region_block['host_max_chunk']}")
        print(f"  host blocks      x_base {region_block['host_x_base']:#x} "
              f"l_base {region_block['host_l_base']:#x} "
              f"desc_ptr {region_block['host_desc_ptr']:#x}")
    else:
        print("  A desc arena     NOT DECLARED (--no-region-block).  "
              "server/fk33_manifest.c will REFUSE this manifest.")
    print(f"  total elapsed    {time.perf_counter() - t_all:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
