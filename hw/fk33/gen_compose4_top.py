#!/usr/bin/env python3
"""gen_compose4_top.py -- TRACK COMPOSE4, 2026-08-29.

Emit `hw/fk33/rtl/compose4_top.vhd`: ONE synthesis top that carries subsystems
A, B, C and D together, at the real Qwen3.5-9B shape, so the composition can be
taken through `place_design` and `route_design` instead of being a sum of
independent out-of-context synthesis runs.

WHAT PROBLEM THIS SOLVES
------------------------
Board row N3: no RTL top composes A+B+C+D for the card.  `hw/fk33/rtl/
fk33_engine.vhd` carries subsystem A alone.  `rtl/llama_top.vhd` carries all
four but is a SIMULATION top -- it binds `matvec_int4`, which has no descriptor
plane, and `C_REAL`/`C_KV_AXI`/`NORM_REAL`/`B_SRC_REAL` all default false.

TRACK DISTRAM's 217,381 CLB LUT for B+C+D is the SUM of seven independent
`synth_design -mode out_of_context -flatten_hierarchy none` runs, with
`opt_design` deliberately not run, across FOUR different pinned trees, none of
them placed and none routed.  Nothing in this project has ever placed or routed
`gdn_block`, `attn_block` or any `seq_*` unit.

WHAT THIS TOP IS, STATED PLAINLY, AND WHAT IT IS NOT
----------------------------------------------------
It is a CO-RESIDENCY top.  The nine instances share `core_clk` and `core_rst`
(and `fk33_engine` additionally takes `hbm_aclk`, the second domain the card
runs); every other port of every instance is brought out to the top level.

So this top MEASURES:
  * the composed synthesis area with cross-boundary optimisation ALLOWED,
    which the four booked rows forbade (`-flatten_hierarchy none`);
  * whether the composition PLACES inside a `pb_core`-shaped region;
  * whether it ROUTES;
  * the post-route WNS on the real 5.0 ns core clock, on the real part.

It does NOT measure:
  * anything about arithmetic.  A routed design is not a correct one, and
    subsystems B and C have never run on this silicon at all.
  * inter-subsystem nets.  The subsystems are not wired to each other, because
    HOW they are wired is board row N2 -- the host-seam contract -- and N2 is a
    decision reserved for Oren.  Wiring them would be picking it.
  * the FK33 shell (XDMA, the HBM controller, clk_wiz, the thermal block, the
    AXI interconnect).  The shell's own cells inside `pb_core` are accounted
    for by CONSTRAINING the pblock to the free region, not by instantiating it.

WHY EVERY OTHER PORT GOES TO THE TOP LEVEL RATHER THAN TO A STIMULUS HARNESS
----------------------------------------------------------------------------
A harness that drives the wide inputs from an LFSR and XOR-reduces the wide
outputs would add its own LUTs and FFs to the very number this exists to
measure, and would have to be measured and subtracted -- a second measurement
with its own error.  An out-of-context port costs nothing and cannot be
optimised away, so the cell count is the subsystems' own.  The price is that
`report_route_status` will report the port nets as unrouted; the caller's
script counts those separately and reports them separately.  See
`sim/ooc_compose4_pnr.tcl`.

GENERIC PROVENANCE -- these are the BOOKING's generics, not new ones
--------------------------------------------------------------------
Every generic below is exactly what the corresponding row of TRACK DISTRAM's
217,381 booking was synthesised with, so the composed number is comparable to
it without adjustment:

    B  gdn_block      all defaults          (distram result_dr_gdn_2abc_f.csv)
    C  attn_block     HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8
                                            (writedec result_wd_attn_after.csv)
    D  seq_*  x5      all defaults          (writedec result_wd_seq_*.csv)
    D  ooc_normadapt  all defaults          (normadapt result_na_after.csv)

TWO CONSEQUENCES OF THAT CHOICE, both recorded because they are real gaps:

 1. `seq_vec_res` at its DEFAULT `ADDR_W = 13`, and `rtl/llama_top.vhd` passes
    16.  `seq_desc_fetch` at its default `WDOG_LIMIT = 4096`, and llama_top
    passes 200000.  Matching the booking was chosen over matching llama_top
    because a number that cannot be compared to the booking answers nothing.
    Both units are small (4,820 and 702 LUT).

 2. `ooc_normadapt` carries `NORM_W_IMAGE = ""`, so the norm gain table is the
    synthetic ramp and NOT a real image.  TRACK NWROM MEASURED that a real
    image costs +32,943 LUT, and TRACK NWFIX is fixing the elaboration blocker
    (Vivado's 65,536 per-loop limit against 266,240 lines).  So NO number this
    top produces includes the gain image, and 32,943 must be added before
    comparing against a pb_core budget.  The generated file says so too.

`fk33_engine` has NO generics at all -- it is the shipping subsystem A,
byte-for-byte the entity in the bitstream on card 1.

NO HARDWARE.  This script reads and writes text files and nothing else.

usage:  python3 hw/fk33/gen_compose4_top.py [--rtl <dir>] [--fk33-rtl <dir>]
                                            [--out <file>]
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# THE REPO ROOT IS TWO LEVELS UP FROM hw/fk33, NOT ONE.  MEASURED 2026-08-30 by
# TRACK ROUTE2: this was `os.path.dirname(HERE)`, which is `<repo>/hw`, so the
# default `--rtl` resolved to `<repo>/hw/rtl` -- a directory that has never
# existed in this tree.  Every invocation since the generator was written has
# therefore had to pass `--rtl` explicitly, and running it without one aborts
# with `COMPOSE4 ABORT: missing <repo>/hw/rtl/gdn_block.vhd`.  That abort is
# loud, which is the only reason this was harmless rather than silent.
REPO = os.path.dirname(os.path.dirname(HERE))

# ---------------------------------------------------------------------------
# The composition.  (instance, entity, source file, generic overrides)
#
# The order is A, B, C, then D's five control leaves, then D's vector
# arithmetic.  `ooc_normadapt` is GENERATED by sim/ooc_normadapt_extract.py
# from rtl/llama_top.vhd and is expected to already be in the RTL directory.
# ---------------------------------------------------------------------------
#
# THE TWO AREA LEVERS, ADDED 2026-08-30 BY TRACK ROUTE2.  Both were MEASURED
# elsewhere and neither was reachable from this top until now:
#
#  * LEVER C, the IQ4_NL codebook to LUTRAM (TRACK LEVERC48, `a4828ab`).
#    Selected by `CB_STYLE` on `a_eng`, defaulting to "distributed" here and
#    settable with --cb-style for the attribution control.  It only became
#    reachable when `fk33_engine` gained a CB_STYLE generic to forward; before
#    that the lever lived in `matvec_core` and no top the card or this
#    composition builds could ask for it.
#
#  * THE NORM LEVER, `rmsnorm_rs_mem` (TRACK RMSWIRE, `47c9d9c`).  NOT a
#    generic here.  `d_norm` is `ooc_normadapt`, which is GENERATED by
#    sim/ooc_normadapt_extract.py from `rtl/llama_top.vhd`'s `gvr` block, and
#    HEAD's `gvr` instantiates `rmsnorm_rs_mem` unconditionally (llama_top.vhd
#    :2190).  So the lever arrives by RE-EXTRACTING against HEAD and by
#    nothing else, and a `rtl/ooc_normadapt_top.vhd` left over from an older
#    tree silently draws the pre-lever design.  The extractor MUST be re-run
#    immediately before this generator.
#
INSTANCES = [
    ("a_eng",   "fk33_engine",     "FK33", {}),
    ("b_gdn",   "gdn_block",       "RTL",  {}),
    ("c_attn",  "attn_block",      "RTL",  {"HEAD_DIM": "256", "N_QH": "16",
                                            "N_KVH": "4", "LAYERS": "8"}),
    ("d_fetch", "seq_desc_fetch",  "RTL",  {}),
    ("d_opdec", "seq_opdec",       "RTL",  {}),
    ("d_lock",  "seq_region_lock", "RTL",  {}),
    ("d_viss",  "seq_vec_issue",   "RTL",  {}),
    ("d_vres",  "seq_vec_res",     "RTL",  {}),
    ("d_norm",  "ooc_normadapt",   "RTL",  {}),
]

# Ports that are SHARED rather than exported, per instance-entity.
# Everything else becomes a top-level port.
#
# THE CLOCKS ARE THE BUFG OUTPUTS, not the ports.  MEASURED 2026-08-29 on this
# part with a four-flop probe: `synth_design -mode out_of_context` inserts NO
# clock buffer (0 BUFG cells, and the clock net's TYPE comes back
# `LOCAL_CLOCK`), and an out-of-context XDC carrying
# `set_property CLOCK_BUFFER_TYPE BUFG [get_ports clk]` does not insert one
# either -- also 0.  A 300,000-load clock on local routing would make every
# placement, routing and timing number below meaningless, so the buffers are
# instantiated here.
SHARED = {
    "fk33_engine": {"core_clk": "core_clk_i", "hbm_aclk": "hbm_aclk_i",
                    "core_aresetn": "core_aresetn"},
    "_default":    {"clk": "core_clk_i", "rst": "core_rst"},
}

# ======================================================================
# WIRING (--wire).  TRACK CARDTOP, 2026-09-02.
#
# Without this the top is a CO-RESIDENCY vehicle: every port of every
# instance is brought out, nothing is connected to anything, and what it
# measures is area / place / route with cross-boundary optimisation allowed.
# That is what TRACK ROUTE3 measured and its numbers describe THAT top.
#
# WIRING CHANGES WHAT THE NUMBERS MEAN.  Ports that were top-level become
# internal, so the tool has more to optimise across and the wiring itself
# adds logic.  ROUTE3's +21.0 BRAM headroom and 80.63% DSP are evidence the
# four subsystems CO-FIT AND ROUTE on this part -- which is the hard part and
# still stands -- and they are NOT predictions for the wired design.  The
# wired top needs its own place-and-route run.
#
# --wire is therefore OFF by default: the measurement vehicle is preserved
# exactly, and `sim/ooc_compose4_pnr.tcl` keeps measuring the thing its
# numbers were taken on.
#
# A port listed here stops being exported and joins the named net instead.
# Two instances naming one net are wired to each other.
# ======================================================================
WIRE = {
    # subsystem A's control plane is driven by rtl/a_desc_adapter.vhd, which
    # is instantiated in the glue below rather than in INSTANCES, because it
    # is a SEAM and not a subsystem.
    "fk33_engine": {
        "s_axi_awvalid": "w_a_awvalid", "s_axi_awready": "w_a_awready",
        "s_axi_awaddr":  "w_a_awaddr",  "s_axi_awprot":  "w_a_awprot",
        "s_axi_wvalid":  "w_a_wvalid",  "s_axi_wready":  "w_a_wready",
        "s_axi_wdata":   "w_a_wdata",   "s_axi_wstrb":   "w_a_wstrb",
        "s_axi_bvalid":  "w_a_bvalid",  "s_axi_bready":  "w_a_bready",
        "s_axi_bresp":   "w_a_bresp",
        "d_job_done":    "w_a_job_done",
        "d_job_err":     "w_a_job_err",
        # Driven by rtl/a_job_counter.vhd in the glue, together with the
        # adapter's `u_index`.  The two are the SAME number in the two widths
        # their consumers declare, which is why one counter feeds both.
        "job_index":     "w_a_job_index32",
    },
    # D's unit-facing vectors become internal; the glue slices U_A out of
    # them for the adapter and ties the units D does not have here.
    # B and C are BOTH driven through rtl/u_seam.vhd.  They are nearly the
    # same shape and the differences are exactly what the seam is
    # parameterised over, read off the RTL rather than assumed:
    #   B  rtl/gdn_block.vhd:625   `done` is a PULSE, and there are THREE
    #                              error bits, ORed in the glue.
    #   C  rtl/attn_block.vhd:1799 `done` is a LEVEL held until `done_ack`,
    #                              and there is ONE `err`.
    "gdn_block": {
        "start": "w_b_start", "busy": "w_b_busy", "done": "w_b_done",
        "err_conv": "w_b_err_conv", "err_g": "w_b_err_g",
        "err_se": "w_b_err_se",
    },
    "attn_block": {
        "start": "w_c_start", "busy": "w_c_busy", "done": "w_c_done",
        "done_ack": "w_c_done_ack", "err": "w_c_err",
    },
    "seq_desc_fetch": {
        "u_start": "w_u_start", "u_ready": "w_u_ready",
        "u_done":  "w_u_done",  "u_ack":   "w_u_ack",
        "u_err":   "w_u_err",   "u_done_epoch": "w_u_done_epoch",
        "job_epoch": "w_job_epoch",
    },
}

# Nets the WIRE table names, declared once.  A net named in WIRE and missing
# here is a hard error rather than an implicit std_logic, because a silently
# defaulted control signal is the plausible-wrong-number failure this
# project keeps finding.
WIRE_SIGNALS = [
    ("w_a_awvalid",  "std_logic"),
    ("w_a_awready",  "std_logic"),
    ("w_a_awaddr",   None),   # width filled in from the engine's own port
    ("w_a_awprot",   "std_logic_vector(2 downto 0)"),
    ("w_a_wvalid",   "std_logic"),
    ("w_a_wready",   "std_logic"),
    ("w_a_wdata",    "std_logic_vector(31 downto 0)"),
    ("w_a_wstrb",    "std_logic_vector(3 downto 0)"),
    ("w_a_bvalid",   "std_logic"),
    ("w_a_bready",   "std_logic"),
    ("w_a_bresp",    "std_logic_vector(1 downto 0)"),
    ("w_a_job_done", "std_logic"),
    ("w_a_job_err",  "std_logic"),
    ("w_a_job_index",   "std_logic_vector(15 downto 0)"),
    ("w_a_job_index32", "std_logic_vector(31 downto 0)"),
    ("w_u_start",    "std_logic_vector(NUNIT-1 downto 0)"),
    ("w_u_ready",    "std_logic_vector(NUNIT-1 downto 0)"),
    ("w_u_done",     "std_logic_vector(NUNIT-1 downto 0)"),
    ("w_u_ack",      "std_logic_vector(NUNIT-1 downto 0)"),
    ("w_u_err",      "std_logic_vector(NUNIT-1 downto 0)"),
    ("w_u_done_epoch", "std_logic_vector(NUNIT*EPOCH_W-1 downto 0)"),
    ("w_job_epoch",  "unsigned(EPOCH_W-1 downto 0)"),
    ("w_b_start",    "std_logic"),
    ("w_b_busy",     "std_logic"),
    ("w_b_done",     "std_logic"),
    ("w_b_err_conv", "std_logic"),
    ("w_b_err_g",    "std_logic"),
    ("w_b_err_se",   "std_logic"),
    ("w_b_err",      "std_logic"),
    ("w_c_start",    "std_logic"),
    ("w_c_busy",     "std_logic"),
    ("w_c_done",     "std_logic"),
    ("w_c_done_ack", "std_logic"),
    ("w_c_err",      "std_logic"),
]

SRC_FILE = {
    "fk33_engine":     ("FK33", "fk33_engine.vhd"),
    "gdn_block":       ("RTL",  "gdn_block.vhd"),
    "attn_block":      ("RTL",  "attn_block.vhd"),
    "seq_desc_fetch":  ("RTL",  "seq_desc_fetch.vhd"),
    "seq_opdec":       ("RTL",  "seq_opdec.vhd"),
    "seq_region_lock": ("RTL",  "seq_region_lock.vhd"),
    "seq_vec_issue":   ("RTL",  "seq_vec_issue.vhd"),
    "seq_vec_res":     ("RTL",  "seq_vec_res.vhd"),
    "ooc_normadapt":   ("RTL",  "ooc_normadapt_top.vhd"),
}

# A port declaration line.  Deliberately strict: anything in an entity's port
# clause that does NOT match is a parse failure and aborts, rather than being
# silently dropped.  A dropped port is a dangling input tied to its default,
# which is exactly the plausible-wrong-number failure this project keeps
# finding.
PORT_RE = re.compile(
    r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*:\s*(in|out|inout)\s+(.*?)\s*$")
GEN_RE = re.compile(
    r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_ ]*"
    r"(?:\s+range\s+[^:]*?)?)\s*:=\s*(.*?)\s*$")


GLUE = """
  -- ====================================================================
  -- THE D-TO-A SEAM.  TRACK CARDTOP, 2026-09-02.
  --
  -- rtl/a_desc_adapter.vhd is a SEAM, not a subsystem, so it is here rather
  -- than in INSTANCES.  It programs DESC_PTR_LO/HI and pulses CTRL bit 0
  -- over the engine's AXI-Lite slave, converts A's completion to D's
  -- held-level contract, and echoes D's epoch.
  --
  -- D's unit-facing ports are VECTORS across NUNIT.  Only slot U_A is
  -- driven here; the others are tied so that D can never select a unit that
  -- is not wired.  THE TIE MATTERS: u_ready tied HIGH on an absent unit
  -- would let D issue to it and wait forever for a done that no logic
  -- produces, so absent units read NOT ready, which is the one value that
  -- makes the omission visible rather than silent.
  -- ====================================================================
  -- LABELLED `seam_*`, NOT `u_a`/`u_b`/`u_c`.  VHDL identifiers are
  -- case-insensitive and llama_map_pkg declares the slot indices `U_A`,
  -- `U_B`, `U_C`, so an instance labelled `u_a` hides the constant `U_A`
  -- and every `w_u_ready(U_A)` in this block becomes
  -- "'u_a' is illegal in an expression".
  -- ====================================================================
  -- WHICH A DESCRIPTOR.  rtl/a_job_counter.vhd, 2026-09-03.
  --
  -- This used to be a top-level INPUT (`a_job_index`), exported because
  -- nothing in the RTL decided it.  Something does now.  The counter holds
  -- the number of A jobs retired so far in the current token and the adapter
  -- turns that into `arena_base + u_index*DESC_STRIDE`; the descriptor's own
  -- stamped index is checked against it inside matvec_int4_desc_axi, so a
  -- misordered descriptor table is refused rather than producing a wrong
  -- token.  See docs/2026-08-28_matvec-descriptor-format.md, version 2.
  --
  -- `job_retire` IS D's `u_ack`, and it is a genuine ONE-CYCLE PULSE:
  -- seq_desc_fetch.vhd:963 drives it from `state = S_COMPLETE`, and every
  -- branch of S_COMPLETE assigns a new state, so the unit cannot sit there.
  -- A level would multi-count and walk off the end of the descriptor table.
  --
  -- IT ADVANCES ON RETIRE, NOT ISSUE, WHICH IS WHAT MAKES IT SAFE HERE.
  -- a_desc_adapter:200-212 warns that `u_index` must be sampled one cycle
  -- after `u_start` if its driver changes it there.  This one does not: the
  -- index is constant from before one `u_start` until after that job's
  -- completion is acknowledged, so both samples agree and the deferral
  -- question does not arise.
  seam_a_idx : entity work.a_job_counter
    generic map (N_JOBS => 311)
    port map (
      clk        => core_clk_i,
      rst        => core_rst,
      tok_start  => d_fetch_go,
      job_retire => w_u_ack(U_A),
      u_index    => w_a_job_index,
      job_index  => w_a_job_index32,
      err        => a_index_err);

  seam_a : entity work.a_desc_adapter
    generic map (
      ADDR_W      => 40,
      LITE_AW     => %LITE_AW%,
      DESC_STRIDE => 512,
      N_JOBS      => 311,
      EPOCH_W     => EPOCH_W)
    port map (
      clk        => core_clk_i,
      rstn       => core_aresetn,
      arena_base => a_arena_base,
      u_start    => w_u_start(U_A),
      u_index    => w_a_job_index,
      u_ready    => w_u_ready(U_A),
      u_done     => w_u_done(U_A),
      u_err      => w_u_err(U_A),
      u_ack      => w_u_ack(U_A),
      job_epoch  => w_job_epoch,
      u_done_epoch => w_u_done_epoch((U_A+1)*EPOCH_W-1 downto U_A*EPOCH_W),
      m_awaddr   => w_a_awaddr,
      m_awvalid  => w_a_awvalid,
      m_awready  => w_a_awready,
      m_wdata    => w_a_wdata,
      m_wstrb    => w_a_wstrb,
      m_wvalid   => w_a_wvalid,
      m_wready   => w_a_wready,
      m_bresp    => w_a_bresp,
      m_bvalid   => w_a_bvalid,
      m_bready   => w_a_bready,
      job_done   => w_a_job_done,
      job_err    => w_a_job_err,
      jobs_issued => a_jobs_issued);

  w_a_awprot <= (others => '0');

  -- ====================================================================
  -- THE D-TO-B AND D-TO-C SEAMS.
  --
  -- One entity serves both.  rtl/u_seam.vhd latches `done` (so a PULSE is
  -- caught), emits `unit_ack` (so a unit that HOLDS `done` is released),
  -- latches `unit_err` with the completion, and echoes D's epoch.
  --
  -- THE EPOCH IS LATCHED ONE CYCLE AFTER ISSUE, inside the seam.  That is
  -- not a detail: seq_desc_fetch bumps `epoch_r` ON the issue edge (:790)
  -- while `job_epoch <= epoch_r` is combinational (:932), so a seam that
  -- latched at issue would echo the OLD epoch and D would reject every
  -- completion as stale at S_COMPLETE (:834).
  -- ====================================================================
  seam_b : entity work.u_seam
    generic map (EPOCH_W => EPOCH_W)
    port map (
      clk => core_clk_i, rstn => core_aresetn,
      u_start => w_u_start(U_B), u_ready => w_u_ready(U_B),
      u_done  => w_u_done(U_B),  u_err   => w_u_err(U_B),
      u_ack   => w_u_ack(U_B),   job_epoch => w_job_epoch,
      u_done_epoch => w_u_done_epoch((U_B+1)*EPOCH_W-1 downto U_B*EPOCH_W),
      unit_start => w_b_start, unit_busy => w_b_busy,
      unit_done  => w_b_done,  unit_ack  => open,
      unit_err   => w_b_err);

  -- B publishes THREE error bits and the seam takes one.  ORed here rather
  -- than inside the seam, because which bits exist is a property of the
  -- unit and not of the contract.  gdn_block.vhd:162-164.
  w_b_err <= w_b_err_conv or w_b_err_g or w_b_err_se;

  seam_c : entity work.u_seam
    generic map (EPOCH_W => EPOCH_W)
    port map (
      clk => core_clk_i, rstn => core_aresetn,
      u_start => w_u_start(U_C), u_ready => w_u_ready(U_C),
      u_done  => w_u_done(U_C),  u_err   => w_u_err(U_C),
      u_ack   => w_u_ack(U_C),   job_epoch => w_job_epoch,
      u_done_epoch => w_u_done_epoch((U_C+1)*EPOCH_W-1 downto U_C*EPOCH_W),
      unit_start => w_c_start, unit_busy => w_c_busy,
      unit_done  => w_c_done,  unit_ack  => w_c_done_ack,
      unit_err   => w_c_err);

  -- ====================================================================
  -- THE REGION FILE.  rtl/region_mem.vhd, the card's activation store.
  --
  -- HOST_WINDOW => FALSE.  That generic exists because of D5: with the
  -- host read window present, `hr_data` is a COMBINATIONAL read of every
  -- region, and a memory with a combinational read port cannot be a BRAM.
  -- The identity between the card top and llama_top was proven with
  -- HOST_WINDOW=true; the CARD is built with it false, which is the one
  -- output port the two configurations differ by.  With it false the
  -- per-region banks carry `ram_style = "block"` and can actually infer.
  --
  -- SZ comes from `region_sizes(RG_SHAPE)`, the SAME function llama_top
  -- uses.  A hand-written size list here would be a second opinion about
  -- fourteen numbers, and region_mem's own pad contract is UNVERIFIED
  -- (its bench never drives an out-of-size access), so a wrong entry
  -- would not be caught by anything.
  --
  -- REGMAX is asserted against the shape rather than assumed: region_mem
  -- defaults REGMAX to 12288, which happens to BE region_max at 9B, and a
  -- default that is right by coincidence stops being right at 27B (17408)
  -- with nothing to say so.
  -- ====================================================================
  rgfile : entity work.region_mem
    generic map (
      NREGION     => NREGION,
      REGMAX      => region_max(RG_SHAPE),
      LANES       => 8,
      MANT_W      => 16,
      GA_W        => 11,
      SZ          => region_sizes(RG_SHAPE),
      HOST_WINDOW => false)
    port map (
      clk      => core_clk_i,
      el_ren   => rg_el_ren,
      el_reg   => rg_el_reg,
      el_addr  => rg_el_addr,
      el_rdata => rg_el_rdata,
      el_we    => rg_el_we,
      el_wreg  => rg_el_wreg,
      el_waddr => rg_el_waddr,
      el_wdata => rg_el_wdata,
      r_en     => rg_r_en,
      r_rega   => rg_r_rega,
      r_regb   => rg_r_regb,
      r_addr   => rg_r_addr,
      x_rdata  => rg_x_rdata,
      e_rdata  => rg_e_rdata,
      w_we     => rg_w_we,
      w_regd   => rg_w_regd,
      w_addr   => rg_w_addr,
      w_be     => rg_w_be,
      w_data   => rg_w_data,
      -- HOST_WINDOW is false, so these select nothing and `hr_data` is
      -- driven constant inside.  Tied rather than exported so no caller can
      -- believe there is a host read path on the card.
      hr_reg   => 0,
      hr_addr  => 0,
      hr_data  => open);

  -- Unit V is NOT wired yet.  NOT ready, deliberately: see above.
  g_unwired : for u in 0 to NUNIT-1 generate
    g_off : if u /= U_A and u /= U_B and u /= U_C generate
      w_u_ready(u) <= '0';
      w_u_done(u)  <= '0';
      w_u_err(u)   <= '0';
      w_u_done_epoch((u+1)*EPOCH_W-1 downto u*EPOCH_W) <= (others => '0');
    end generate;
  end generate;
"""


def strip_comment(line):
    # No VHDL string literal in any entity header here contains "--", and the
    # parser asserts on anything it cannot read, so a naive split is safe.
    i = line.find("--")
    return line if i < 0 else line[:i]


def clause(text, entity, kw):
    """Return the raw lines of `entity`'s generic/port clause, comments gone."""
    m = re.search(r"^entity\s+%s\s+is\s*$" % re.escape(entity), text,
                  re.M | re.I)
    if not m:
        sys.exit("COMPOSE4 ABORT: no entity %s" % entity)
    body = text[m.end():]
    e = re.search(r"^\s*end\s+(entity|%s)\b" % re.escape(entity), body,
                  re.M | re.I)
    if not e:
        sys.exit("COMPOSE4 ABORT: no end of entity %s" % entity)
    body = body[:e.start()]

    k = re.search(r"^\s*%s\s*\(\s*$" % kw, body, re.M | re.I)
    if not k:
        return []
    rest = body[k.end():]
    # Walk to the matching close paren at depth 0.
    depth, out, cur = 1, [], ""
    for ch in rest:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                break
        cur += ch
    for ln in cur.split("\n"):
        ln = strip_comment(ln).rstrip()
        if ln.strip():
            out.append(ln.strip())
    # A declaration may span several lines (`seq_region_lock`'s REG_SIZE
    # integer_vector does).  Rejoin on DEPTH-0 semicolons so each element of
    # the returned list is exactly one declaration.  Splitting on newlines
    # instead is what made the first run of this script abort on
    # '8192, 1024, 1024, 4096,'.
    joined = " ".join(out)
    decls, depth, cur2 = [], 0, ""
    for ch in joined:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == ";" and depth == 0:
            decls.append(cur2.strip())
            cur2 = ""
        else:
            cur2 += ch
    if cur2.strip():
        decls.append(cur2.strip())
    return [d for d in decls if d]


def parse_generics(lines):
    """name -> default expression.  A generic with no default is an error."""
    g = {}
    for ln in lines:
        ln = ln.strip().rstrip(";")
        if not ln:
            continue
        m = GEN_RE.match(ln)
        if not m:
            sys.exit("COMPOSE4 ABORT: unparsed generic %r" % ln)
        g[m.group(1)] = m.group(3).strip()
    return g


def parse_ports(lines, entity):
    """[(name, dir, type)] with the trailing `:= default` removed."""
    ports = []
    for ln in lines:
        s = ln.strip().rstrip(";").strip()
        if not s:
            continue
        m = PORT_RE.match(s)
        if not m:
            sys.exit("COMPOSE4 ABORT: %s: unparsed port line %r" % (entity, s))
        name, direction, typ = m.group(1), m.group(2), m.group(3)
        # Strip a port default.  `:=` cannot appear inside a type mark here.
        #
        # THE OLD FORM CORRUPTED VECTOR TYPES THAT CARRY A DEFAULT.  It was
        #   typ.split(":=")[0].strip().rstrip(")").strip()
        #       if typ.strip().endswith(")") and ":=" in typ else typ
        # and for `std_logic_vector(15 downto 0) := (others => '0')` the
        # rstrip ate the TYPE'S OWN closing paren, emitting
        # `std_logic_vector(15 downto 0` -- a syntax error in the generated
        # file.  It never showed because no port in this design had both a
        # vector type and a default until fk33_engine's D-facing inputs did,
        # and those NEED defaults so an unconnected instantiation still
        # elaborates (hw/fk33/gen_pcieep.py drives none of them).
        #
        # Balance the parens instead of stripping blind: remove a trailing
        # `)` only when there is one more `)` than `(`, which is the port
        # clause's own closer landing on this line.
        if ":=" in typ:
            typ = typ.split(":=")[0].strip()
        if typ.count(")") == typ.count("(") + 1 and typ.endswith(")"):
            typ = typ[:-1].strip()
        if ":=" in typ:
            typ = typ.split(":=")[0].strip()
        typ = typ.rstrip(";").strip()
        ports.append((name, direction, typ))
    return ports


def subst(expr, gmap):
    """Replace generic identifiers by their effective literal expressions.

    Iterated to a fixed point because a default may name another generic.  An
    expression that still names a generic after the cap is an abort, not a
    silently wrong width.
    """
    if not gmap:
        return expr
    # `REG_SIZE'length` must become a NUMBER, not `(4096, 4096, ...)'length`:
    # an aggregate literal has no 'length attribute and Vivado would reject it.
    # Counted from the depth-0 commas of the aggregate, so it tracks the file.
    for g, v in gmap.items():
        v = v.strip()
        if not (v.startswith("(") and v.endswith(")")):
            continue
        depth, n = 0, 1
        for ch in v[1:-1]:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                n += 1
        expr = re.sub(r"\b%s'length\b" % re.escape(g), str(n), expr,
                      flags=re.I)
    pat = re.compile(r"\b(%s)\b" % "|".join(
        sorted(map(re.escape, gmap), key=len, reverse=True)))
    prev = None
    cur = expr
    for _ in range(8):
        if cur == prev:
            break
        prev = cur
        cur = pat.sub(lambda m: "(%s)" % gmap[m.group(1)], cur)
    if pat.search(cur):
        sys.exit("COMPOSE4 ABORT: generic substitution did not converge on %r"
                 % expr)
    return cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", default=os.path.join(REPO, "rtl"))
    ap.add_argument("--fk33-rtl", default=os.path.join(HERE, "rtl"))
    ap.add_argument("--out", default=os.path.join(HERE, "rtl",
                                                  "compose4_top.vhd"))
    # A SUBSET top, for the case where the full composition will not fit in the
    # box's memory or the night's hours.  `--instances b_gdn,c_attn,d_*` gives
    # a B+C+D-only top that is directly comparable to the 217,381 booking, and
    # `--entity` names it so it cannot be confused with the full one.
    ap.add_argument("--instances", default="",
                    help="comma-separated instance names to keep; default all")
    ap.add_argument("--entity", default="compose4_top")
    ap.add_argument("--wire", action="store_true",
                    help="connect D to A instead of exporting both. OFF by "
                         "default so the co-residency measurement vehicle, "
                         "and TRACK ROUTE3's numbers taken on it, are "
                         "preserved exactly.")
    # LEVER C.  "distributed" is the configuration STEP 2 is asking about;
    # "regs" reproduces the pre-lever composition and is the attribution
    # control.  Anything else is rejected here rather than silently meaning
    # "regs" three levels down in matvec_core.
    ap.add_argument("--cb-style", default="distributed",
                    choices=["distributed", "regs"])
    # THE NORM LEVER'S CONTROL.  There is no generic for it: `d_norm` is an
    # extraction of llama_top's `gvr` block, so the ONLY way to draw the
    # pre-lever configuration is to point this at an extraction taken from a
    # pre-RMSWIRE llama_top.  Kept as an explicit, named, loud option rather
    # than as a way to disable the staleness guard, because the guard exists to
    # catch an ACCIDENTALLY stale file and this is a DELIBERATE one.  The guard
    # is not bypassed here, it is INVERTED: with --norm-entity naming the flat
    # variant, the generator aborts if the file DOES bind rmsnorm_rs_mem.
    ap.add_argument("--norm-entity", default="ooc_normadapt",
                    choices=["ooc_normadapt", "ooc_normadapt_flat"])
    ap.add_argument("--norm-file", default="")
    # THE GAIN IMAGE, TRACK ROUTE3, 2026-08-31.  Every composed draw before
    # this option carried NORM_W_IMAGE = "" (the synthetic ramp), so the
    # composed BRAM figure never included the gain store.  GAIN16 replaced
    # that store with an 11-bit codebook index (99 RAMB36, MEASURED OOC) plus
    # a 1,567-entry table, and the question ROUTE3 answers is whether the
    # composition still ROUTES with it in.  The path is BAKED INTO the
    # generated file's d_norm generic map, exactly as CB_STYLE is, because
    # the PnR Tcl passes no generics on its synth_design line.  Default ""
    # preserves every existing number.
    ap.add_argument("--norm-w-image", default="")
    a = ap.parse_args()

    global INSTANCES
    INSTANCES = [(i[0], i[1], i[2],
                  (dict(i[3], CB_STYLE='"%s"' % a.cb_style)
                   if i[0] == "a_eng" else i[3]))
                 for i in INSTANCES]
    if a.norm_w_image:
        INSTANCES = [(i[0], i[1], i[2],
                      (dict(i[3], NORM_W_IMAGE='"%s"' % a.norm_w_image)
                       if i[0] == "d_norm" else i[3]))
                     for i in INSTANCES]
    if a.norm_entity != "ooc_normadapt":
        INSTANCES = [(i[0], a.norm_entity, i[2], i[3]) if i[0] == "d_norm"
                     else i for i in INSTANCES]
        SRC_FILE[a.norm_entity] = (
            "RTL", a.norm_file or ("%s_top.vhd" % a.norm_entity))
    if a.instances:
        keep = set(x.strip() for x in a.instances.split(",") if x.strip())
        unknown = keep - set(i[0] for i in INSTANCES)
        if unknown:
            sys.exit("COMPOSE4 ABORT: unknown instance(s) %s"
                     % ",".join(sorted(unknown)))
        INSTANCES = [i for i in INSTANCES if i[0] in keep]

    roots = {"RTL": a.rtl, "FK33": a.fk33_rtl}

    top_ports = []          # (name, dir, type)
    inst_blocks = []
    summary = []
    epoch_w_default = None
    lite_aw = None

    for inst, ent, _which, over in INSTANCES:
        which, fname = SRC_FILE[ent]
        path = os.path.join(roots[which], fname)
        if not os.path.exists(path):
            sys.exit("COMPOSE4 ABORT: missing %s" % path)
        text = open(path).read()

        # THE STALE-EXTRACTION GUARD, and it has teeth: it FAILS on the
        # ooc_normadapt_top.vhd every run of this generator before 2026-08-30
        # consumed, because that one instantiated the flat `rmsnorm_rs`.  A
        # stale extraction is otherwise silent -- it parses, elaborates,
        # synthesises, and reports 62,053 CLB LUT that the design does not
        # have.  Keyed on the INSTANTIATION, not on a comment: HEAD's
        # extracted file mentions `rmsnorm_rs_mem` in prose at line 312 while
        # the binding is at line 485, so a substring test on the whole file
        # would pass over an extraction that binds the flat unit.
        if ent == "ooc_normadapt_flat":
            # THE GUARD, INVERTED.  This entity exists ONLY to draw the
            # pre-lever configuration, so a file that DOES bind the
            # memory-backed unit here is just as wrong as a stale one is in the
            # other direction -- and it would silently report the levered area
            # under the control's name, which is the worse of the two errors.
            if re.search(r"entity\s+work\.rmsnorm_rs_mem\b", text):
                sys.exit(
                    "COMPOSE4 ABORT: %s binds rmsnorm_rs_mem, but it was asked\n"
                    "  for as the FLAT pre-lever control.  Extract it from a\n"
                    "  llama_top from BEFORE TRACK RMSWIRE (`47c9d9c`), e.g.\n"
                    "    git show 012d28d~1:rtl/llama_top.vhd > /tmp/pre.vhd\n"
                    "    python3 sim/ooc_normadapt_extract.py /tmp/pre.vhd \\\n"
                    "            %s ooc_normadapt_flat" % (path, path))
            if not re.search(r"entity\s+work\.rmsnorm_rs\b", text):
                sys.exit("COMPOSE4 ABORT: %s binds neither rmsnorm_rs nor "
                         "rmsnorm_rs_mem." % path)
        if ent == "ooc_normadapt":
            if not re.search(r"entity\s+work\.rmsnorm_rs_mem\b", text):
                sys.exit(
                    "COMPOSE4 ABORT: %s does not instantiate rmsnorm_rs_mem.\n"
                    "  This is a STALE extraction: rtl/llama_top.vhd's `gvr`\n"
                    "  block has bound rmsnorm_rs_mem since TRACK RMSWIRE\n"
                    "  (`47c9d9c`).  Re-run:\n"
                    "    python3 sim/ooc_normadapt_extract.py \\\n"
                    "        rtl/llama_top.vhd %s ooc_normadapt" % (path, path))

        gdefs = parse_generics(clause(text, ent, "generic"))
        if ent == "seq_desc_fetch":
            # NOT a hardcoded 4.  `EPOCH_W` is a generic of seq_desc_fetch and
            # of llama_top, and the composed top instantiates D with its
            # DEFAULTS, so the top's constant must be that default and not a
            # second opinion about it.  hbm_map.py already recorded what an
            # independent copy of a shared address costs: it becomes a fourth
            # model of the same quantity, and the copies drift silently.
            epoch_w_default = gdefs.get("EPOCH_W")
            if epoch_w_default is None:
                sys.exit("COMPOSE4 ABORT: seq_desc_fetch declares no EPOCH_W "
                         "generic; the composed top cannot size w_job_epoch "
                         "without inventing a value")
        for k in over:
            if k not in gdefs:
                sys.exit("COMPOSE4 ABORT: %s has no generic %s" % (ent, k))
        gmap = dict(gdefs)
        gmap.update(over)

        ports = parse_ports(clause(text, ent, "port"), ent)
        if ent == "fk33_engine":
            # LITE_AW IS LIFTED FROM THE ENGINE'S OWN PORT, not written here.
            # MEASURED 2026-09-02: the glue passed `LITE_AW => 8` and the
            # engine declares `s_axi_awaddr : std_logic_vector(11 downto 0)`,
            # so elaboration failed with `port width mismatch ... port width
            # = 12, actual width = 8`.  The adapter's OWN bench cannot see
            # this -- it drives a slave model of the adapter's chosen width,
            # so it agrees with the adapter and not with the engine.  This is
            # the third quantity in this file that had to stop being a
            # literal for the same reason.
            for pn_, dir_, tp_ in ports:
                if pn_ == "s_axi_awaddr":
                    m_ = re.search(r"\(\s*(\d+)\s+downto\s+0\s*\)", tp_)
                    if not m_:
                        sys.exit("COMPOSE4 ABORT: cannot read the width of "
                                 "fk33_engine.s_axi_awaddr from %r" % tp_)
                    lite_aw = int(m_.group(1)) + 1
        shared = dict(SHARED.get(ent, SHARED["_default"]))
        if a.wire:
            for pn_, net_ in WIRE.get(ent, {}).items():
                if net_ not in dict(WIRE_SIGNALS):
                    sys.exit("COMPOSE4 ABORT: WIRE names net %s for %s.%s but "
                             "WIRE_SIGNALS does not declare it.  An undeclared "
                             "net would become an implicit signal and a "
                             "silently defaulted control line."
                             % (net_, ent, pn_))
                shared[pn_] = net_

        maps = []
        nbits_exported = 0
        for name, direction, typ in ports:
            if name in shared:
                maps.append("      %s => %s" % (name, shared[name]))
                continue
            tp = subst(typ, gmap)
            pn = "%s_%s" % (inst, name)
            top_ports.append((pn, direction, tp))
            maps.append("      %s => %s" % (name, pn))
            nbits_exported += 1

        gl = ""
        if over:
            gl = ("    generic map(\n"
                  + ",\n".join("      %s => %s" % (k, v)
                               for k, v in sorted(over.items()))
                  + "\n    )\n")
        inst_blocks.append(
            "  -- %s : %s%s\n  %s : entity work.%s\n%s    port map(\n%s\n    );\n"
            % (inst, ent,
               ("  " + " ".join("%s=%s" % (k, v) for k, v in sorted(over.items()))
                if over else "  (all generics at their file defaults)"),
               inst, ent, gl, ",\n".join(maps)))
        summary.append((inst, ent, len(ports), nbits_exported,
                        " ".join("%s=%s" % (k, v) for k, v in sorted(over.items()))
                        or "(defaults)"))

    hdr = [
        "-- hw/fk33/rtl/compose4_top.vhd -- GENERATED by hw/fk33/gen_compose4_top.py.",
        "-- DO NOT HAND-EDIT; edit the generator.  TRACK COMPOSE4, 2026-08-29.",
        "--",
        "-- ONE synthesis top carrying subsystems A, B, C and D together at the real",
        "-- Qwen3.5-9B shape, so the composition can be PLACED and ROUTED rather than",
        "-- summed from independent out-of-context synthesis runs.",
        "--",
        "-- WHAT THIS ESTABLISHES: fit, placement, routability and post-route timing.",
        "-- WHAT IT DOES NOT ESTABLISH: arithmetic.  A routed design is not a correct",
        "-- one, and subsystems B and C have never run on this silicon at all.",
        "--",
        "-- THE SUBSYSTEMS ARE NOT WIRED TO EACH OTHER.  How they are wired is board",
        "-- row N2 -- the host-seam contract -- and that is a decision reserved for",
        "-- Oren.  They share `core_clk` and `core_rst`; `fk33_engine` additionally",
        "-- takes `hbm_aclk`, the second domain the card runs.  Both domains are",
        "-- 5.000 ns / 200.000 MHz in the routed shell build",
        "-- (hw/fk33/results/build_e2e_2026-08-29/e2e_timing_routed_summary.rpt).",
        "--",
        "-- BOTH AREA LEVERS ARE IN THIS FILE as of 2026-08-30 (TRACK ROUTE2):",
        "--   * lever C, `a_eng`'s CB_STYLE generic, printed in the instance list below;",
        "--   * the norm lever, which is NOT a generic -- `d_norm` is an extraction of",
        "--     rtl/llama_top.vhd's `gvr` block and HEAD's `gvr` binds rmsnorm_rs_mem.",
        "-- The generator ABORTS if the extraction it is handed binds the flat unit.",
        "--",
    ]
    if a.norm_w_image:
        hdr += [
            "-- NORM_W_IMAGE IS REAL HERE (TRACK ROUTE3): %s" % a.norm_w_image,
            "-- The gain store is GAIN16's 11-bit codebook index plus a",
            "-- 1,567-entry table, 99 RAMB36 MEASURED OOC, so this top's BRAM",
            "-- total INCLUDES the gain image and no addition is needed before",
            "-- comparing it to a pb_core budget.",
        ]
    else:
        hdr += [
            "-- NORM_W_IMAGE IS EMPTY HERE, as it was in every row of the booking this",
            "-- is compared against.  TRACK NWROM MEASURED that a real gain image costs",
            "-- +32,943 CLB LUT, so that must be ADDED to any number this top produces",
            "-- before comparing it to a pb_core budget.",
        ]
    hdr += [
        "--",
        "-- Instances, and the generics each carries:",
    ]
    for inst, ent, np, ne, gs in summary:
        hdr.append("--   %-8s %-16s %3d ports, %3d exported   %s"
                   % (inst, ent, np, ne, gs))
    hdr += [
        "--",
        "-- Regenerate with:  python3 hw/fk33/gen_compose4_top.py",
        "",
        "-- NOTE: this file is SYNTHESIS ONLY.  It instantiates BUFGCE from",
        "-- UNISIM, so GHDL cannot analyse it without -P<unisim>.  That is not a",
        "-- loss: it is not simulable in any useful sense either, because the nine",
        "-- instances are not wired to each other.",
        "",
        "library ieee;",
        "use ieee.std_logic_1164.all;",
        "use ieee.numeric_std.all;",
        "use work.util_pkg.all;      -- clog2, used by attn_block's port widths",
    ] + ([
        "use work.model_cfg_pkg.all; -- MODEL and NCARDS, for the shape",
        "use work.llama_map_pkg.all; -- NUNIT, the U_* slot indices used by",
        "                            -- D's unit-facing vectors, and the",
        "                            -- region size/extent functions",
    ] if a.wire else []) + [
        "library unisim;",
        "use unisim.vcomponents.all; -- BUFGCE",
        "",
        "entity %s is" % a.entity,
        "  generic(",
        "    -- FALSE leaves the clocks on local routing.  Only ever useful for",
        "    -- reproducing the measurement that made the buffers necessary.",
        "    CLK_BUFG : boolean := true" + (";" if a.wire else ""),
    ] + ([
        "    -- THE MODEL SHAPE, so the region file's port widths below size",
        "    -- themselves from the same function llama_top uses rather than",
        "    -- from literals.  A generic and not an architecture constant,",
        "    -- because the PORT CLAUSE needs it and constants cannot be",
        "    -- declared ahead of it.",
        "    RG_SHAPE : shape_t := mk_shape(MODEL, NCARDS)",
    ] if a.wire else []) + [
        "  );",
        "  port(",
        "    -- the two clocks the card runs, both 5.000 ns",
        "    core_clk     : in  std_logic;",
        "    core_rst     : in  std_logic;",
        "    core_aresetn : in  std_logic;",
        "    hbm_aclk     : in  std_logic;",
        "",
    ]

    if a.wire:
        # THE SEAM'S TWO REMAINING INPUTS, EXPORTED RATHER THAN INVENTED.
        #
        # `a_arena_base` is the HBM base of the descriptor arena, which is
        # host-supplied at run time and is legitimately a port.
        #
        # `a_job_index` WAS a top-level input here, exported because nothing
        # in the RTL decided it.  SETTLED 2026-09-03: rtl/a_job_counter.vhd
        # decides it, instantiated in the glue above, so the port is gone.
        #
        # The reasoning that kept it exported still stands and is why the
        # answer is a counter rather than a wire: D's `job_ordinal` is WRONG
        # twice over -- 8 bits, so it cannot address the 311 A jobs at all,
        # and rtl/llama_top.vhd uses it as `wsyn(r, c, j_ord)`, a synthetic
        # weight selector in the simulation model, not a descriptor pointer.
        # Wiring THAT would have elaborated cleanly and produced wrong
        # descriptors on the card.  See section 13 of
        # docs/debugging/2026-08-31_cardtop-design-note.md and the CORRECTION
        # in docs/debugging/2026-09-03_a-desc-ptr.md.
        #
        # `a_index_err` is exported instead: it is the counter running past
        # the end of the descriptor table, which is a bring-up signal the host
        # has no other way to see.
        top_ports.append(("a_arena_base", "in", "std_logic_vector(39 downto 0)"))
        top_ports.append(("a_index_err",  "out", "std_logic"))
        # The adapter's own issue counter.  Exported rather than left `open`
        # so that a bring-up read has something to compare against the 311
        # jobs the token program contains; an `open` output is invisible and
        # this is the cheapest liveness signal subsystem A has.
        top_ports.append(("a_jobs_issued", "out", "std_logic_vector(31 downto 0)"))

        # THE REGION FILE'S SURFACE, EXPORTED.
        #
        # rtl/region_mem.vhd is the card's activation store.  Its real drivers
        # are the per-unit data movers, which do not exist yet, so every port
        # is brought out -- exactly as the rest of this top does with anything
        # not yet wired.  That is not cosmetic: a memory whose inputs are tied
        # to constants is optimised away entirely, and then a place-and-route
        # of this top would report a fit that the card does not have.  TRACK
        # ROUTE3 measured a composed design with NO region file in it at all,
        # so its numbers do not answer the fit question for the card.
        #
        # Widths come from `RG_SHAPE` and from llama_map_pkg's NREGION, never
        # from literals: `region_max(mk_shape(QWEN35_9B, 1))` is 12288 today
        # and 17408 at 27B, and a literal would be wrong at exactly the moment
        # the retarget happens.
        RG = [
            ("el_ren",   "in",  "std_logic"),
            ("el_reg",   "in",  "natural range 0 to NREGION-1"),
            ("el_addr",  "in",  "natural range 0 to region_max(RG_SHAPE)-1"),
            ("el_rdata", "out", "signed(15 downto 0)"),
            ("el_we",    "in",  "std_logic"),
            ("el_wreg",  "in",  "natural range 0 to NREGION-1"),
            ("el_waddr", "in",  "natural range 0 to region_max(RG_SHAPE)-1"),
            ("el_wdata", "in",  "signed(15 downto 0)"),
            ("r_en",     "in",  "std_logic"),
            ("r_rega",   "in",  "unsigned(7 downto 0)"),
            ("r_regb",   "in",  "unsigned(7 downto 0)"),
            ("r_addr",   "in",  "unsigned(10 downto 0)"),
            ("x_rdata",  "out", "std_logic_vector(8*16-1 downto 0)"),
            ("e_rdata",  "out", "std_logic_vector(8*16-1 downto 0)"),
            ("w_we",     "in",  "std_logic"),
            ("w_regd",   "in",  "unsigned(7 downto 0)"),
            ("w_addr",   "in",  "unsigned(10 downto 0)"),
            ("w_be",     "in",  "std_logic_vector(7 downto 0)"),
            ("w_data",   "in",  "std_logic_vector(8*16-1 downto 0)"),
        ]
        for pn_, dir_, tp_ in RG:
            top_ports.append(("rg_" + pn_, dir_, tp_))

    w = max(len(p[0]) for p in top_ports)
    body = []
    last_inst = None
    for pn, direction, tp in top_ports:
        pref = pn.split("_")[0] + "_" + pn.split("_")[1]
        if pref != last_inst:
            body.append("")
            last_inst = pref
        body.append("    %-*s : %-5s %s;" % (w, pn, direction, tp))
    # The final port declaration must not carry a semicolon.
    for i in range(len(body) - 1, -1, -1):
        if body[i].strip():
            body[i] = body[i].rstrip(";")
            break

    out = hdr + body + [
        "  );",
        "end entity;",
        "",
        "architecture rtl of %s is" % a.entity,
        "  signal core_clk_i : std_logic;",
        "  signal hbm_aclk_i : std_logic;",
    ] + ([
        "",
        "  -- EPOCH_W is LIFTED from seq_desc_fetch's own generic default, not",
        "  -- written here.  The composed top instantiates D with its defaults,",
        "  -- so a literal in this file would be a second, independent opinion",
        "  -- about a width D alone owns, and the two would drift in silence.",
        "  constant EPOCH_W : positive := %s;" % epoch_w_default,
        "",
        "  -- nets carrying the D-to-A, D-to-B and D-to-C seams; see WIRE",
    ] + ["  signal %-16s : %s;"
         % (n, t if t is not None
              else "std_logic_vector(%d downto 0)" % (lite_aw - 1))
         for n, t in WIRE_SIGNALS]
        if a.wire else []) + [
        "begin",
        "",
        "  gbufg : if CLK_BUFG generate",
        "    u_bufg_core : BUFGCE port map(I => core_clk, CE => '1', O => core_clk_i);",
        "    u_bufg_hbm  : BUFGCE port map(I => hbm_aclk, CE => '1', O => hbm_aclk_i);",
        "  end generate;",
        "  gnobufg : if not CLK_BUFG generate",
        "    core_clk_i <= core_clk;",
        "    hbm_aclk_i <= hbm_aclk;",
        "  end generate;",
        "",
    ] + inst_blocks + (GLUE.replace("%LITE_AW%", str(lite_aw)).splitlines()
                       if a.wire else []) + [
        "end architecture;",
        "",
    ]

    with open(a.out, "w") as fh:
        fh.write("\n".join(out))

    print("COMPOSE4_GEN wrote %s : %d instances, %d top-level ports"
          % (a.out, len(INSTANCES), len(top_ports) + 4))
    for inst, ent, np, ne, gs in summary:
        print("COMPOSE4_GEN   %-8s %-16s ports=%d exported=%d  %s"
              % (inst, ent, np, ne, gs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
