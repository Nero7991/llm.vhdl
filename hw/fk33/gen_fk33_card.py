#!/usr/bin/env python3
"""Emit hw/fk33/rtl/fk33_card.vhd -- the board-facing face of subsystems B, C
and D, so the block designer can instantiate them.

THE CARD IS A TWO-CELL BLOCK DESIGN.  Subsystem A is its own cell,
`hw/fk33/rtl/fk33_engine.vhd`, wrapping `matvec_int4_desc_axi` and its 28
masters.  This is the OTHER cell: `rtl/fk33_llama_top.vhd` at `A_DESC = true`,
which carries B, C and D and DRIVES A's descriptor plane over a 23-port `a_*`
seam.  `ga_desc` there instantiates `a_job_counter` and `a_desc_adapter` only
-- the control plane -- and deliberately contains no A compute unit.

WHY A GENERATED WRAPPER RATHER THAN THE ENTITY ITSELF.  Three packager rules,
none of which any bench can see, because they belong to the IP packager and not
to VHDL:

  * `[IP_Flow 19-734]`  `natural` is not a port type.  The card top has four,
    all of them the host region-file window.
  * `[IP_Flow 19-627]`  a port width is an XPath expression over the generics
    and may not call a function.
  * A FLATTENED VECTOR IS NOT AN INTERFACE.  `gen_fk33_engine.py` says it
    plainly: "Vivado's block designer cannot see a flattened vector as AXI at
    all, so it cannot be connected to `hbm/SAXI_nn`, which is an interface
    pin."  On this top exactly two masters have that shape -- C's reads.

The wrapper also declares NO GENERICS.  That is deliberate: it gives the
packager a cell with nothing to infer, and it puts the CONFIGURATION in this
file, where it is reviewable, rather than in a block-design property.

THE CONFIGURATION, and each entry is a decision:

  B_STATE_AXI = true   B's recurrent state behind an AXI master (`bst_*`).
                       Default false, and every composed measurement before
                       2026-09-07 was taken with it off.
  C_KV_AXI    = true   C's KV cache behind three masters (`kv_*`).  Same.
  C_KV_BLOCK  = 32     REQUIRED.  `attn_kv_axi` asserts `KV_BLOCK >= 16` (its
                       record is a byte layout on a 16-byte granule at the
                       mandatory CM_W = 8), and the generic's default here is
                       4.  So `C_KV_AXI = true` at the default is not a legal
                       configuration, and 32 is the composed shape's value.

The `--const` values are read FROM THE VHDL, not from a comment: `NREGION` and
`region_max(mk_shape(MODEL, NCARDS))` come from a GHDL probe, and `A_NPORTS`
is `rtl/llama_map_pkg.vhd:69`.  Note `A_NPORTS = 5` is the SIMULATION path's A
(`matvec_int4`, 4 weight ports plus 1 scale); the card's A is the 28-master
descriptor unit in the other cell, so those five ports are not the card's.
"""

import os
import subprocess
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
import genstamp  # noqa: E402  (needs REPO, which is computed above)
OUT = os.path.join(HERE, "rtl", "fk33_card.vhd")
SRC = os.path.join(REPO, "rtl", "fk33_llama_top.vhd")
# THE REAL NORM GAIN IMAGE, 65 x 4096 entries at NORM_W_EXP = 12, written by
# sim/ooc_nwrom_gen_image.py and committed (track E of
# docs/2026-09-18_b-constants-path.md).  An ABSOLUTE path derived from this
# script's own location, because `NORM_W_IMAGE` is opened by file_open at
# elaboration from wherever Vivado's cwd happens to be; the BC-250 holds the
# repo at the same absolute path, so the generated wrapper is valid on both
# lanes.  Refused here if absent: a missing image fails only at elaboration,
# hours in, as `file_open ... severity failure`, which synthesis may not even
# honour.
NORM_W_HEX = os.path.join(REPO, "hw", "fk33", "gen", "norm_w_9b.hex")
if not os.path.exists(NORM_W_HEX):
    sys.exit("gen_fk33_card.py: NORM_W_IMAGE %s does not exist; the card "
             "would elaborate the synthetic norm gain ramp, or fail at "
             "file_open hours into synthesis.  Run "
             "sim/ooc_nwrom_gen_image.py (track E) first." % NORM_W_HEX)
# THE REAL QK-NORM GAIN IMAGE, 8 attention layers x (q, k) x 256 entries at
# C_QKN_EXP = 12, written by tools/gen_qkn_image.py and committed (TRACK F,
# 2026-09-18; the last stand-in after docs/2026-09-18_b-constants-path.md).
# Same absolute-path and refuse-if-absent rules as NORM_W_HEX, for the same
# reasons.  Held to its generator by sim:qknimage.
QKN_HEX = os.path.join(REPO, "hw", "fk33", "gen", "qkn_9b.hex")
if not os.path.exists(QKN_HEX):
    sys.exit("gen_fk33_card.py: C_QKN_IMAGE %s does not exist; the card "
             "would elaborate the synthetic QK-norm gain ramp, or fail at "
             "file_open hours into synthesis.  Run tools/gen_qkn_image.py "
             "(track F) first." % QKN_HEX)

# ---- the THIRD cell: the B/C grant ---------------------------------------
# A takes 28 HBM masters, B needs 2 and C needs 3, which is 33 against the 30
# the host leaves free.  `rtl/bc_port_grant.vhd` closes B-versus-C to 3 SHARED
# ports with a drain interlock, and it belongs in the block design between the
# card cell and hbm/SAXI_nn rather than inside the card top -- putting it
# inside would mean hand-writing a 141-port RTL level around a generated one.
#
# It is already packager-legal (63 ports, 0 refusals); it only needs its
# flattened groups cut into named interfaces: C's TWO reads on the requester
# side, and the THREE shared masters on the pool side.
GRANT_OUT = os.path.join(HERE, "rtl", "fk33_bc_grant.vhd")
GRANT_SRC = os.path.join(REPO, "rtl", "bc_port_grant.vhd")

GRANT_C2 = ",".join([
    "c_arvalid", "c_arready", "c_araddr", "c_arlen",
    "c_rvalid", "c_rdata", "c_rlast", "c_rready",
])
GRANT_M2 = ",".join([
    "m_arvalid", "m_araddr", "m_arlen", "m_arready",
    "m_rvalid", "m_rdata", "m_rlast", "m_rready",
    "m_awvalid", "m_awaddr", "m_awlen", "m_awready",
    "m_wvalid", "m_wdata", "m_wlast", "m_wready",
    "m_bvalid", "m_bready",
])

GRANT_ARGS = [
    "--src", GRANT_SRC,
    "--entity", "bc_port_grant",
    "--wrapper", "fk33_bc_grant",
    "--split", "2:" + GRANT_C2,
    "--split", "2:" + GRANT_M2,
]

# C's two read masters, carried flattened on the card top.  EXPLICIT, because a
# width being divisible by 2 does not make a port two masters: `kv_awaddr` is
# 16 bits and is one, and inferring here would cut a working interface in half.
KV_READ = ",".join([
    "kv_arvalid", "kv_arready", "kv_araddr", "kv_arlen", "kv_arsize",
    "kv_arburst", "kv_rvalid", "kv_rready", "kv_rdata", "kv_rlast", "kv_rresp",
])

ARGS = [
    "--src", SRC,
    "--entity", "fk33_llama_top",
    "--wrapper", "fk33_card",
    "--const", "NREGION=14",
    "--const", "REGMAX=12288",
    "--const", "A_NPORTS=5",
    # A_DESC = true IS THE WHOLE POINT OF THIS CELL and it was missing from
    # the first version of this list, which is worth recording because nothing
    # complained about the omission directly.  With A_DESC false the `ga_real`
    # generate is instantiated, bringing `matvec_int4` -- the SIMULATION path's
    # A, five masters at ROWS_IF 4 -- into a cell whose entire purpose is to
    # drive the OTHER cell's A over the `a_*` seam.
    #
    # The symptom was not "A_DESC is false".  It was
    #   [Synth 8-549] port width mismatch for port 'm_arvalid':
    #                 port width = 49, actual width = 5
    # because A_ROWS_IF = 48 asks `matvec_int4` for 49 masters while
    # `A_NPORTS` is a package CONSTANT of 5 (llama_map_pkg.vhd:69, pinned
    # because `weight_streamer.vhd` fixes NPORTS_W = ROWS_IF = 4 at BLK 32 /
    # AXI_DW 128).  That reads as "A_ROWS_IF = 48 is illegal here", which is
    # true of `ga_real` and irrelevant to this cell -- the path should not
    # exist at all.
    "--generic", "A_DESC=true",
    "--generic", "B_STATE_AXI=true",
    # B_SRC_REAL: subsystem B takes its conv taps, alpha and beta from the
    # regions the schedule wrote (R_QKV and the two gate projections) instead
    # of the `m12` stand-ins that every card build so far ran.  MEASURED
    # 2026-09-18, docs/debugging/2026-09-18_the-card-runs-subsystem-b-on-
    # stand-in-inputs-and-weights.md: the composed card computed B on
    # synthetic inputs and synthetic weights.  Legal here because B_STATE_AXI
    # is true: rtl/llama_top.vhd asserts `not (B_SRC_REAL and not
    # B_STATE_AXI and tok_pos > 0)`, and the pair was verified with the tier
    # on 2026-09-05.  docs/2026-09-18_b-constants-path.md, track C.
    "--generic", "B_SRC_REAL=true",
    # B_CONST_HBM=true: the fourth, load-only phase of gdn_state_store that
    # brings the learned conv weights, dt bias, A and ssm norm gain in from
    # HBM at `bst_const_base` (seam 0x84/0x88, hbm.gdn_const_base, image by
    # tools/pack_gdn_consts.py).  Landed f425d82, 2026-09-18.  MEASURED at
    # the sim shape: with B_SRC_REAL, B_STATE_AXI and this, 9 of 9 R_Y seams
    # over 3 tokens match tools/ref9b/gdn_oracle.py --b-src-real --b-const
    # bit for bit, and 0 of 9 with either the constants or the inputs left
    # as stand-ins.  Without this line B's arithmetic is not the model's
    # whatever its inputs are.  tools/gen_bd_wrapper.py emits generics
    # VERBATIM and checks nothing against the entity, which is why this line
    # waited for the generic to exist in rtl/fk33_llama_top.vhd.
    "--generic", "B_CONST_HBM=true",
    "--generic", "C_KV_AXI=true",
    # ---------------------------------------------------------------------
    # HOST_WINDOW=false IS THE CARD CONFIGURATION, AND IT WAS NEVER SET.
    #
    # MEASURED 2026-09-10, and rtl/region_mem.vhd states it outright in the
    # comment above the generic: llama_top exposes hr_reg/hr_addr/hr_data as a
    # COMBINATIONAL, full-range random read into the region file, and
    #   "A memory with a combinational read port CANNOT be a BRAM, so while
    #    that port exists this store is LUTs and registers no matter what
    #    shape the array has.  MEASURED 2026-09-02: Vivado reports
    #    `[Synth 8-11357] ... RAM mem_reg with 2752512 registers` ...
    #    Reorganising the array from flat to per-region did not change it,
    #    because the array's shape was never the cause."
    #
    # The generic DEFAULTS TO TRUE, `fk33_llama_top` re-declares it as `true`,
    # and nothing here overrode it -- so every card build so far asked Vivado
    # to optimise 2.75 MILLION REGISTERS.  That is a sufficient explanation for
    # the synthesis wall: ten builds, ~40 hours, none of which ever emitted a
    # phase marker past `Starting RTL Elaboration`.
    #
    # The port is DEAD ON THE CARD -- nothing on the board drives or consumes
    # it; it exists for sim/tb_llama_top.vhd, which reads results through it.
    # region_mem's own comment records the decision as Oren's, 2026-09-02:
    #   TRUE  (default) -- simulation.  Identity against llama_top is proven
    #                      in this configuration.
    #   FALSE           -- the card.  hr_data reads zero and the banks can
    #                      infer BRAM.
    # It was decided and then never wired into this generator.  Same defect
    # class as the KV geometry above, in the same file, found the same way.
    "--generic", "HOST_WINDOW=false",
    # ======================================================================
    # THE THREE SWITCHES THAT MAKE THIS A CARD THAT CAN RUN INFERENCE.
    # Added 2026-09-11. Before this the card passed NONE of them, so it built
    # subsystem C as a STUB and could not have run the model whatever happened
    # to synthesis. See docs/debugging/2026-09-11_the-card-builds-subsystem-c-
    # as-a-stub.md. PLAN_TO_FIRST_INFERENCE.md:236 required all of them.
    #
    # C_REAL gates `gcr`, which is where attn_block AND attn_kv_axi live --
    # fk33_llama_top instantiates attn_block exactly once, at :5893, inside it.
    # With C_REAL false, `gc` elaborates instead: a three-state stub FSM that
    # hardwires u_err(U_C) <= '0'. It ALSO makes the five KV generics below
    # inert (they are consumed inside gcr) and makes `gkvtie` tie the kv0/kv1
    # AXI ports off, despite the block design wiring them to HBM.
    "--generic", "C_REAL=true",
    # NORM_REAL gates `gvr`, the real norm, against a stub at `gv`.
    "--generic", "NORM_REAL=true",
    # SWG_REAL gates `gsr`, the real SwiGLU (rtl/swiglu_mem.vhd: Q12
    # silu(g)*u with bfp_pack's pack), against the `g*u / 2**MANT_W` stand-in
    # at `gv`.  Added 2026-09-19.  Before this every card build computed H
    # as a plain product with no gate, and the token-0 bisection on silicon
    # found G and U right and H wrong in every block
    # (docs/debugging/2026-09-19_the-swiglu-on-the-card-is-a-product-with-
    # no-gate.md).  It was the LAST stand-in in the composed top.  llama_top's
    # default is FALSE so every existing bench elaborates unchanged; the
    # card wants the real unit, exactly as it wants NORM_REAL.
    "--generic", "SWG_REAL=true",
    # NORM_W_IMAGE: the REAL RMSNorm gains, one row per OP_VEC_NORM of a token
    # in schedule order, read at elaboration into ~114 BRAM
    # (docs/debugging/2026-08-29_nwrom-norm-gain-image-area.md).  Empty, the
    # default and what every card build so far used, keeps the SYNTHETIC ramp
    # (fk33_llama_top.vhd, the NORM_W_IMAGE comment).  The path is built from
    # REPO above rather than written as a literal so the wrapper is right on
    # whichever machine generates it; NORM_W_EXP stays at its default of 12,
    # which is the exponent the image was packed at.  A VHDL string generic
    # needs the quotes, and gen_bd_wrapper passes the value through as is.
    "--generic", 'NORM_W_IMAGE="%s"' % NORM_W_HEX,
    # C_QKN_IMAGE: the REAL QK-norm gains, one q and one k vector of 256 per
    # attention layer in schedule order, read at elaboration into a table
    # indexed by the C job's layer ordinal (fk33_llama_top.vhd, the
    # C_QKN_IMAGE comment).  Empty, the default and what every card build
    # before 2026-09-18 used, keeps the SYNTHETIC `qkn_const` ramp, which is
    # a wrong number at every attention layer.  C_QKN_EXP stays at its
    # default of 12, the exponent the image was packed at.
    "--generic", 'C_QKN_IMAGE="%s"' % QKN_HEX,
    # SMP_EN BUILDS THE SAMPLER, AND WITHOUT IT THE CARD CANNOT SAY WHICH TOKEN
    # IT PRODUCED.  llama_top's default is FALSE, which ties the entire logits
    # stream off: `gsmptie` drives smp_* to zero and the seam's `smp_token`
    # carries nothing.  Every other piece of the path already exists -- the
    # ga_desc adapter has the producer half (`smp_be_we`, `smp_run`, and
    # `j_smp <= job_flags(1)` for FLG_TO_SMP), and gen_pcieep.py wires
    # `smp_token` from the card to the seam -- so this generic is the whole
    # difference between a card that computes a token and a card that can
    # report one.
    #
    # THE TWO CAPS BITS FOLLOW THIS FLAG AND ARE CHECKED AGAINST IT.
    # tools/check_seam_regs.py derives its SAMPLER and LOGITS expectations from
    # this line rather than hardcoding them, so flipping it here REQUIRES
    # CAPS_FLAGS_V in rtl/fk33_seam.vhd to set bits 2 and 3. That check exists
    # because the reverse mistake shipped: bit 2 was set while SMP_EN was
    # false, telling every host to wait for an argmax that never arrives.
    "--generic", "SMP_EN=true",
    # C_N_ROT: NOT a free choice and NOT the declared default. llama_top's
    # default is 8, which is SIMULATION-scaled -- the same trap as C_KV_BLOCK's
    # default of 4. The RoPE table is GENERATED for N_ROT = 64:
    #   rtl/imrope_pkg.vhd   IMROPE_NPAIR = 32, IMROPE_W is (0 to 31)
    #   tools/gen_imrope_pkg.py   NPAIR = 32   # N_ROT / 2
    #   rtl/attn_twiddle.vhd  NPAIR : positive := 32
    #   rtl/attn_block.vhd    N_ROT : positive := 64  -- GGUF rope.dimension_count
    # At 8 the design would index 4 of the 32 table entries. That is IN RANGE,
    # raises nothing, and rotates the wrong number of dimensions -- a bitstream
    # that builds and computes garbage, which is the defect class this file has
    # already shipped once.
    "--generic", "C_N_ROT=64",

    "--generic", "C_KV_BLOCK=32",
    # ---------------------------------------------------------------------
    # THE 9B KV GEOMETRY.  MEASURED 2026-09-09: these five were NEVER SET, so
    # every card build so far synthesised `rtl/fk33_llama_top.vhd`'s DEFAULTS
    # -- a KV cache of FOUR positions with a context length of ONE, K based at
    # byte 16 and V at byte 4064, on a 16-bit address bus.  That is the bench
    # stand-in, not Qwen3.5-9B.
    #
    # The symptom was visible in every build and nothing branched on it:
    #   CRITICAL WARNING: [BD 41-2383] Width mismatch when connecting input
    #   pin '/bcgrant/c0_araddr'(33) to pin '/card/kv0_araddr'(16) - Only
    #   lower order bits will be connected, and other input bits of this pin
    #   will be left unconnected.
    # Twenty of them, across kv0/kv1/kv_aw and the host register address.
    # The build gates on `^ERROR`, and a CRITICAL WARNING is not one, so a
    # SILENT 17-BIT ADDRESS TRUNCATION on C's entire KV path passed every
    # gate this project has. C would have read and written the low 64 KiB of
    # HBM for every head of every layer, and the bitstream would have run.
    #
    # The values are `rtl/fk33_llama_top.vhd`'s own documented shipping set
    # (the comment block above C_K_BASE_CH), not invented here.
    #
    # C_MAXPOS IS SAFE TO RAISE ONLY BECAUSE C_KV_AXI IS TRUE.  The
    # behavioural cache that C_MAXPOS would size is inside
    # `gkvmem : if not C_KV_AXI generate`, so it is not instantiated at all
    # here; the file records it costing 8.9 GB of elaboration at C_MAXPOS 256
    # when it IS instantiated. With the real cache in HBM, C_MAXPOS buys only
    # POSW = clog2(C_MAXPOS+1) = 17 bits of position width against 3 today.
    #
    # C_CTXLEN = C_MAXPOS is legal, and was not always: POSW used to be
    # clog2(C_MAXPOS) and the guard demanded both `C_CTXLEN <= C_MAXPOS` and
    # `C_CTXLEN < 2**POSW`, which is self-contradictory at exactly the
    # boundary. That is already fixed in the RTL (POSW = clog2(C_MAXPOS+1)).
    "--generic", "C_KV_ADDR_W=33",
    # SINCE 2026-09-20 THE TWO BASES ARE DEFAULTS, NOT THE ADDRESS C USES.
    # MEASURED on silicon that day (docs/debugging/2026-09-20_the-kv-cache-
    # base-is-compiled-into-the-bitstream.md): these generics are the FLAT
    # manifest's layout, the loaded image was the lane-striped one (kv_base
    # 0x1AD71C000), and every C job wrote its records into weight pieces --
    # 40 objects corrupted, predicted exactly by the 64 compiled slot heads.
    # The card's `kv_k_base`/`kv_v_base` input ports (rtl/llama_top.vhd,
    # beside bst_state_base) now carry the pair, the seam drives them from
    # A_KVK_LO/HI (0x90/0x94) and A_KVV_LO/HI (0x98/0x9C), and the host
    # writes those from the loaded manifest's hbm.kv_base at model load --
    # the same path bst_state_base already took.  gen_bd_wrapper strips the
    # port defaults, so on the card the generics below reach NOTHING but the
    # elaboration guards; they are kept at the flat manifest's values so that
    # sim:kvmap's identity rows (the flat manifest against the defaults) and
    # sim/realshape_gate.sh's real_kv_map row keep the same meaning.
    #
    # RE-DERIVED 2026-09-18 from the migrated manifest, and the gate row
    # sim:kvmap is what forced it.  The old values (282598912 / 353902080) put
    # the K cache at 0x10D81E000, which leaves EXACTLY 25,264,128 B between
    # weights_end and the K base -- the old, under-sized GDN arena figure.
    # The correct GDN arena is 26,443,776 B (it omitted the conv tap history;
    # docs/debugging/2026-09-17_gdn-arena-omitted-the-conv-tap-history.md),
    # so B's recurrent state overran C's K cache by 1,179,648 B.  The RTL
    # constant inherited the same defect the manifest had.
    #   C_K_BASE_CH = hbm.kv_base / 16              = 0x10D93E000 / 16
    #   C_V_BASE_CH = (kv_base + 8704 * C_MAXPOS) / 16
    #               = (4522762240 + 8704 * 65536) / 16 = 318324224
    # Both re-derived by tools/check_kv_map.py against the manifest; the row
    # is an IDENTITY, so a manifest that moves again fails the gate rather
    # than silently disagreeing with the DEFAULT.
    "--generic", "C_K_BASE_CH=282672640",
    "--generic", "C_V_BASE_CH=318324224",
    # C_MAXPOS HALVED 2026-09-20, 131072 -> 65536, so the STRIPED layout fits.
    # The striped manifest has 1,378,082,816 B free above the GDN state
    # (hbm.free_after_gdn); two regions of MAXPOS * 8704 B each need
    # 2*131072*8704 = 2,281,701,376 B (does not fit) or 2*65536*8704 =
    # 1,140,850,688 B (fits, 237 MB spare).  The seam publishes this value
    # at A_KV_MAXPOS (hw/fk33/gen_pcieep.py sets the seam's MAXPOS from THIS
    # line) so the host refuses a manifest whose KV extent is smaller than
    # the pair rather than discovering it as corrupted weights.  C_CTXLEN
    # follows it (the RTL requires C_CTXLEN <= C_MAXPOS).  The cost is
    # context: 65,536 tokens, half of Qwen3.5-9B's native 131,072, and one
    # bit of POSW (17 against 18); nothing else in the card reads C_MAXPOS
    # (the behavioural cache it would size is not instantiated, C_KV_AXI).
    "--generic", "C_MAXPOS=65536",
    "--generic", "C_CTXLEN=65536",
    # D'S PER-JOB WATCHDOG.  The default, 200,000 cycles, was set when B's
    # state was on chip and the benches ran a SCALED shape.  MEASURED on
    # silicon 2026-09-18 (the first GO on the composed card,
    # docs/debugging/2026-09-18_first-token-on-silicon-stops-at-step-7.md):
    # steps 0-6 (a norm and six A jobs, 25 MB of weights) took ~320,000
    # cycles, then the first B job hit the watchdog at exactly 200,000.
    # DERIVED from the RTL geometry, a 9B B job cannot fit: one recurrent
    # pass is 32*(128/4)*128 = 131,072 cycles and the tiered store moves
    # 1,101,824 B in and out over a 256-bit port, 68,864 beats, before any
    # HBM latency.  And at the measured A rate the 12,288-row FFN jobs need
    # ~320,000 each.  4,000,000 is ten times the largest derived job and
    # still 53 ms at 75 MHz, so a hung unit is reported, not waited on
    # forever.  seq_desc_fetch's counter is 32 bits.
    "--generic", "WDOG_LIMIT=4000000",
    # A_ROWS_IF = 48 IS NOT A TUNING CHOICE, IT IS THE SEAM WIDTH.
    # `hw/fk33/gen_fk33_engine.py` pins `ROWS_IF = 48` (TRACK LEVERC48 measured
    # "distributed" at 48 as -42,633 CLB LUT), so the engine cell's
    # `d_y_data` is 48*64 = 3072 bits and `d_y_mask` is 48.  The card top's
    # `A_ROWS_IF` DEFAULTS TO 4, which makes `a_y_data` 256 bits and `a_y_mask`
    # 4 -- a 12x mismatch on the seam that joins the two cells.
    #
    # Found by comparing the two entities' port lists rather than by a tool:
    # nothing in either file references the other, and each is internally
    # consistent, so the disagreement is invisible until they are connected.
    # This is also what makes `--generic` drive width folding load-bearing
    # rather than defensive -- a pin that did not reach the folding would leave
    # the wrapper's port 256 bits wide over a 3072-bit instance.
    "--generic", "A_ROWS_IF=48",
    # A_JOB_STRIDE = 0x40000 (262,144) EXISTS ONLY TO SATISFY A GUARD THAT IS
    # OVER-BROAD IN THIS CONFIGURATION, and saying so is the point of this note.
    #
    # `fk33_llama_top.vhd:1092` is
    #     CHK_A_BLOCK : natural := A_JOB_STRIDE - (A_ROWS_IF + 1) * A_SUB_BYTES
    # which is the project's out-of-range-natural idiom for a compile-time
    # assertion, because Vivado silently ignores `assert ... severity failure`
    # in synthesis.  At A_ROWS_IF = 48 it evaluates to
    # 32,768 - 49*4,096 = -167,936 and Vivado refuses with
    # `[Synth 8-11323] assigned value '-167936' out of range`.
    #
    # The guard is CORRECT arithmetic and its own comment says what it guards:
    # "the run-time half of this bound is A_SUB_BEATS / A_SCL_BEATS in the
    # `ga_real` generate; this is the half a synthesis run can see."  But
    # `ga_real` is `if not A_BEHAV and not A_DESC generate`, so at A_DESC = true
    # it is NOT INSTANTIATED, and MEASURED by grep, A_JOB_STRIDE appears
    # nowhere else outside that generate.  The constant is declared in the
    # architecture's declarative region, so it is evaluated regardless of
    # whether the path it describes exists.
    #
    # So the guard fires over a memory map this configuration does not build:
    # in the card, A's weight sub-regions belong to the OTHER cell,
    # `fk33_engine`, and A_ROWS_IF here only sizes the `a_y_*` seam.  262,144
    # is 49*4,096 rounded up to a power of two; nothing reads it.
    #
    # The cleaner fix is to make CHK_A_BLOCK conditional on `not A_DESC` in
    # rtl/llama_top.vhd and regenerate.  Deliberately NOT done here: that edits
    # a guard, and a guard weakened by someone who only wanted their own build
    # to pass is how guards stop working.
    "--generic", "A_JOB_STRIDE=16#40000#",
    "--split", "2:" + KV_READ,
]


# ---------------------------------------------------------------------------
# TRIM OVERRIDES, for a FIRST card bitstream that need not be full 9B geometry.
#
# WHY THIS SHAPE.  The `"--generic", "NAME=VALUE"` literals above are left
# EXACTLY as they are and the override is applied to the built list here,
# because tools/check_kv_map.py reads this file's SOURCE TEXT with a regex
# (read_card / _read_bool_generic).  Rewriting a literal into an f-string or an
# os.environ call would make those rows stop matching, and a checker whose
# pattern matches nothing REPORTS NOTHING -- the recorded silent-empty failure,
# which is indistinguishable from a pass.
#
# CONSEQUENCE, AND IT IS REAL: with an override active, check_kv_map.py
# validates the DEFAULT geometry while the build uses the trimmed one.  Two
# things keep that detectable rather than silent:
#   1. a loud stderr banner whenever an override is in force, and
#   2. the value lands in the GENERATED VHDL as `C_KV_BLOCK => N,`, so
#      `grep -E 'C_KV_BLOCK|A_ROWS_IF' hw/fk33/rtl/fk33_card.vhd` states what
#      was really built.
# DO NOT run the kvmap gate row against an overridden tree and believe it.
# A TRIM IS NOT A FREE PARAMETER.  MEASURED 2026-09-11, the hard way: this
# dispatcher trimmed C_KV_BLOCK 32 -> 4 on the reasoning that an 8x cut was
# well characterised for DSPs, and never checked the legal set.  4 is ILLEGAL
# at the shipping shape and the build was doomed from launch.
#
# rtl/llama_top.vhd states the rule where it is easy to miss, because the
# generic's own default is the ILLEGAL value for this configuration:
#     C_KV_BLOCK : positive := 4;   <- correct only when C_KV_AXI is FALSE
#     "legal set at head_dim 256 is {16,32,64,128}"
# The card sets C_KV_AXI=true, and then attn_kv_axi requires a 16-byte granule:
# KV_BLOCK*CM_W/8 must be a multiple of 16, i.e. KV_BLOCK >= 16.  attn_head_dim
# is 256 for BOTH 9B and 27B, so this does not relax at either shape.
#
# It would NOT have been silent -- rtl/attn_kv_axi.vhd's CHK_HDR_FITS is the
# out-of-range-natural idiom precisely so it survives Vivado, and that file
# records the measurement: at HEAD_DIM 256 / KV_BLOCK 4 synthesis FAILS with
# "[Synth 8-11323] assigned value '-48' out of range".  But that fires deep in
# elaboration, hours in.  Refusing here costs nothing and fails in a second.
LEGAL = {
    "C_KV_BLOCK": (
        (16, 32, 64, 128),
        "attn_kv_axi needs a 16-byte granule (KV_BLOCK*CM_W/8 a multiple of 16,"
        " so >= 16) and attn_block needs HEAD_DIM/KV_BLOCK >= 2; head_dim is 256"
        " at both 9B and 27B. See rtl/llama_top.vhd and rtl/attn_kv_axi.vhd:412.",
    ),
    # A_ROWS_IF has no legal set recorded anywhere in the tree.  Left unchecked
    # DELIBERATELY rather than guessed at: a fabricated bound would be worse
    # than none, because it would read as authoritative.
}

TRIMMABLE = ("C_KV_BLOCK", "A_ROWS_IF")
_trims = []
for _k in TRIMMABLE:
    _v = os.environ.get("FK33_" + _k)
    if not _v:
        continue
    if not _v.isdigit() or int(_v) <= 0:
        sys.exit("FK33_%s must be a positive integer, got %r" % (_k, _v))
    if _k in LEGAL and int(_v) not in LEGAL[_k][0]:
        sys.exit("FK33_%s=%s is NOT in the legal set %s.\n  %s\n"
                 "  Refusing here rather than letting synthesis discover it hours in."
                 % (_k, _v, list(LEGAL[_k][0]), LEGAL[_k][1]))
    _hit = 0
    for _i in range(len(ARGS) - 1):
        if ARGS[_i] == "--generic" and ARGS[_i + 1].startswith(_k + "="):
            _was = ARGS[_i + 1].split("=", 1)[1]
            ARGS[_i + 1] = "%s=%s" % (_k, _v)
            _trims.append("%s %s -> %s" % (_k, _was, _v))
            _hit += 1
    # Exactly one, or the override silently did nothing (or too much).
    if _hit != 1:
        sys.exit("FK33_%s: expected exactly 1 generic to override, matched %d"
                 % (_k, _hit))
# THE STAMP.  The banner two lines into the generated file says it is
# GENERATED; it does not say WITH WHAT, and this generator's output depends on
# the environment above.  MEASURED 2026-09-20 (TRACK BUILDREPORT), on the
# sibling case `hw/fk33/build_fk33_pcieep.tcl`: regenerating an env-dependent
# file with the DEFAULT environment -- the remedy the banner invites -- changed
# its configuration by 497 deletions and destroyed the only record of what it
# had been.  So the file now carries its own inputs.  See tools/genstamp.py.
#
# Only the TRIMMABLE variables appear: they are the complete set this generator
# reads (`grep -n 'os.environ' hw/fk33/gen_fk33_card.py`), and an input that is
# not read cannot change the output.  An UNSET one is stamped rather than
# omitted, so the reader learns the knob exists.
STAMP_INPUTS = [("env", "FK33_" + _k, os.environ.get("FK33_" + _k) or None)
                for _k in TRIMMABLE]


def stamp_cmd(inputs):
    """The reproduce line, DERIVED FROM `inputs` and from nothing else.

    MEASURED while writing this, and it is the trap this whole track is about
    in miniature.  The first version built ONE command for both outputs, from
    the process environment.  `fk33_bc_grant.vhd` does not depend on FK33_*
    and is stamped `inputs: NONE` -- yet under FK33_C_KV_BLOCK=16 it grew by
    exactly 19 bytes, the width of the `FK33_C_KV_BLOCK=16 ` prefix, because
    the stamp itself had smuggled the environment into a file that is supposed
    to be independent of it.  A stamp that claims no dependence while varying
    with the environment is worse than no stamp: it is a false negative in the
    one place someone would look.  Deriving the command from the same list the
    rows are printed from makes the claim and the evidence the same object.
    """
    return (["%s=%s" % (n, v) for (_, n, v) in sorted(inputs) if v]
            + ["python3", "hw/fk33/gen_fk33_card.py"])

if _trims:
    sys.stderr.write(
        "\n*** FK33 CARD TRIM ACTIVE: %s ***\n"
        "*** NOT the default geometry.  check_kv_map.py validates the DEFAULTS\n"
        "*** and will NOT see this.  Verify what was built with:\n"
        "***   grep -E 'C_KV_BLOCK|A_ROWS_IF' hw/fk33/rtl/fk33_card.vhd\n\n"
        % ", ".join(_trims))


def render(dest, args=None):
    cmd = [sys.executable, os.path.join(REPO, "tools", "gen_bd_wrapper.py"),
           "--out", dest] + (ARGS if args is None else args)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        return None
    return open(dest).read()


# THE ONE THING IN THE OUTPUT THAT LEGITIMATELY DEPENDS ON WHERE THE TREE
# LIVES, AND WHY `--check` MUST COMPARE MODULO IT.
#
# `NORM_W_IMAGE` and `C_QKN_IMAGE` are opened by VHDL `file_open` at
# elaboration, from wherever Vivado's cwd happens to be -- see the NORM_W_HEX
# comment above.  An absolute path is therefore GENUINELY REQUIRED in the
# generated entity, and this generator already computes it correctly, from its
# own location rather than from a literal.  It is the one case in this tree
# where an absolute path must survive into a generated file.
#
# The consequence, MEASURED 2026-09-20 (TRACK GATEDAY): in a git worktree the
# regenerated text differed from the committed text in exactly those two lines
# and `--check` reported STALE, so gate row sim:fk33card was red for a reason
# that had nothing to do with the card.  Comparing the raw bytes asks "was this
# file generated in THIS directory", which is not the question the row exists
# to answer.
#
# So the comparison canonicalises the repo prefix of the image paths and
# nothing else.  What that KEEPS teeth on: the generic being present at all,
# the file name, the directory under the repo, the quoting, and every other
# byte of the entity.  What it GIVES UP, stated plainly: a committed file whose
# images sit under a DIFFERENT repo at the same relative path now compares
# equal.  That is a real loss of resolution and it is why the prefix is
# reported on the OK line rather than silently dropped -- after the
# llama.vhdl -> llm.vhdl rename the printed prefix is how you see that the
# committed file still names the old directory and wants regenerating.
HEXPATH_RE = re.compile(r'"(/[^"]*?)(/hw/fk33/gen/[^"]*\.hex)"')


def _canon_hexpaths(text):
    """Return (canonicalised text, sorted list of distinct repo prefixes)."""
    seen = set()

    def sub(m):
        seen.add(m.group(1))
        return '"@REPO@%s"' % m.group(2)

    return HEXPATH_RE.sub(sub, text), sorted(seen)


def one(out, args, label, source, inputs):
    check = "--check" in sys.argv
    tmp = out + (".check" if check else "")
    text = render(tmp, args)
    if text is None:
        print("FK33_CARD_CHECK: GENERATOR FAILED for %s" % label)
        return 1
    # STAMPED HERE, NOT IN gen_bd_wrapper.py, because the inputs are THIS
    # generator's.  gen_bd_wrapper is a library with several callers and knows
    # nothing about FK33_*; a stamp written there would either be empty or be
    # a claim it cannot support.
    #
    # `inputs` is per-output and NOT the same list for both files: only
    # fk33_card.vhd carries the trimmable generics, so stamping fk33_bc_grant
    # with them would assert a dependence that does not exist.  It gets the
    # empty stamp, which says so positively.
    #
    # DETERMINISM: the block is built from `inputs` alone, never from sys.argv
    # and never from the process environment directly, so a `--check` run and
    # a write run produce identical bytes.  That is what keeps gate row
    # sim:fk33card able to compare them.
    text = genstamp.insert_after(
        text, "DO NOT HAND-EDIT",
        genstamp.stamp(stamp_cmd(inputs), inputs, comment="--"))
    if not check:
        open(tmp, "w").write(text)
    if check:
        try:
            cur = open(out).read()
        except IOError:
            os.remove(tmp)
            print("FK33_CARD_CHECK: MISSING %s -- run "
                  "hw/fk33/gen_fk33_card.py" % out)
            return 1
        os.remove(tmp)
        cur_c, cur_pfx = _canon_hexpaths(cur)
        new_c, _ = _canon_hexpaths(text)
        if cur_c != new_c:
            print("FK33_CARD_CHECK: STALE %s -- %s or the configuration "
                  "changed and this file was not regenerated. Run "
                  "hw/fk33/gen_fk33_card.py." % (out, source))
            return 1
        # The prefix is REPORTED, not checked.  A prefix that is not this
        # checkout is legal (a worktree comparing a committed file) but it is
        # also exactly what a post-rename stale file looks like, so it must be
        # visible rather than absorbed.
        pfx = ", ".join(cur_pfx) if cur_pfx else "none"
        print("FK33_CARD_CHECK: OK %s (%d bytes, image repo prefix: %s)"
              % (os.path.basename(out), len(text), pfx))
        return 0
    print("wrote %s (%d bytes)" % (out, len(text)))
    return 0


def main():
    rc = one(OUT, ARGS, "fk33_card", "rtl/fk33_llama_top.vhd", STAMP_INPUTS)
    rc |= one(GRANT_OUT, GRANT_ARGS, "fk33_bc_grant", "rtl/bc_port_grant.vhd",
              [])
    return rc


if __name__ == "__main__":
    sys.exit(main())
