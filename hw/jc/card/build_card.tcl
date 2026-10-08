# hw/jc/card/build_card.tcl -- Jungle Cat (VU35P, no PCIe) Qwen3.8-27B inference card.
# Synthesis, implementation and reports only: nothing here opens a hardware target.
#
#   vivado -mode batch -source build_card.tcl -tclargs <build_dir> [part] [bd_only] [allow_neg] -nonce <value>
#
# Called by run_card.sh, never directly: run_card.sh has already copied the TRACKED
# tree into <build_dir>/../src (git archive HEAD), applied build12_levers_off.patch
# there, and regenerated the 27B hw/fk33/rtl/fk33_card.vhd and the three
# hw/jc/card/gen_jc_card.py outputs IN PLACE in that tree.  This script's `here` is
# that tree's hw/jc/card, so every path below resolves inside the copy, never the
# live repository.
#
# Flow: project mode for the block design and synthesis (synth_1), then the
# implementation runs IN THIS PROCESS on the opened synthesized design, so the
# timing/CDC constraints (jc_loader_timing.tcl, hw/jc/ctl/jc_ctl_timing.tcl) are
# applied by Tcl that stops the build when a query matches nothing, and every check
# below is a hard error, not a warning.  Modelled on hw/jc/loader/build_loader.tcl
# (same anchored-sentinel, open_run-then-constrain, report-everything shape).
#
# PART: default xcvu35p-fsvh2104-2L-e (global-constraints.md; the silicon in hand).
# CLK_CORE_MHZ: 200, the one clock (global-constraints.md): every enabled HBM AXI
# port, the engine and the ctl/loader cores are all on it, with no AXI clock
# converter anywhere, so aclk's period must read back as 5.000 ns or the BD was
# built for a different clock than this script constrains.
#
# Anchored sentinels: JCCARD_BD_DONE, JCCARD_SYNTH_DONE, JCCARD_LEVERS_OK,
# JCCARD_BSCAN_SUMMARY, JCCARD_WNS, JCCARD_WHS, JCCARD_BIT, JCCARD_DONE; any failure
# prints JCCARD_FAIL <reason> and exits 1.  A waiter gates on these lines in THIS
# script's own stdout/log, never on Vivado's exit code alone (CLAUDE.md: "a
# completion signal that also fires on failure is not one").
set here  [file normalize [file dirname [info script]]]
set repo  [file normalize $here/../../..]
set bd    [file normalize [lindex $argv 0]]
set part  [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xcvu35p-fsvh2104-2L-e"}]
set bdonly    [expr {[lsearch -exact $argv bd_only]   >= 0}]
set allow_neg [expr {[lsearch -exact $argv allow_neg] >= 0}]
set nonce_idx [lsearch -exact $argv -nonce]
set nonce     [expr {$nonce_idx >= 0 ? [lindex $argv [expr {$nonce_idx + 1}]] : ""}]
# clk_core in integer MHz from run_card.sh (--clk-mhz, default 200); gen_jc_card.py
# already emitted the clk_wiz and HBM AXI frequencies from the same value.
set clk_idx   [lsearch -exact $argv -clk_mhz]
set clk_mhz   [expr {$clk_idx >= 0 ? [lindex $argv [expr {$clk_idx + 1}]] : 200}]
set TCK_P 37.037
set DNA_DIV 10
set CORE_LOADER "*u_jc_core/"
set CORE_CTL    "*ctl/inst/"
proc jcc_fail {msg} { puts "JCCARD_FAIL $msg"; exit 1 }
# Task 9 fix round 1, IMPORTANT I3: the VERY FIRST thing this script prints (ahead
# of JCCARD_PART, ahead of create_project) is this run's own nonce, so run_card.sh
# can gate JCCARD_DONE on a log that actually carries THIS run's identity, not a
# stale file left by an earlier run in a reused root (Vivado's own startup banner
# still precedes it in the raw -log file, which is why run_card.sh gates on the
# first JCCARD_* line carrying the nonce, not literally byte 0 of the file).
# run_card.sh always passes -nonce; a direct invocation without one is refused.
if {$nonce eq ""} { jcc_fail "no -nonce given on -tclargs (run_card.sh always passes one)" }
puts "JCCARD_NONCE $nonce"
puts "JCCARD_PART $part"
if {![string is integer -strict $clk_mhz] || $clk_mhz < 50 || $clk_mhz > 250} { jcc_fail "-clk_mhz $clk_mhz is not an integer in 50..250" }
puts "JCCARD_CLK_CORE_MHZ $clk_mhz"

# BSCAN census, as a proc so it can be run twice (Task 9 fix round 1, CRITICAL C2):
# once right after opt_design (cheap: the design is not yet placed or routed) and
# again right before write_bitstream, rather than once after route_design. Running
# it early means a wrong census is caught before paying for placement and routing,
# not after hours of routing; running it again before the bitstream catches anything
# place/route itself might have changed.
#
# C2: jtag_hbm (an IP-packaged jtag_axi core, the card's own JTAG-over-HBM debug
# master) makes Vivado insert exactly one debug hub on JTAG chain 1, exactly as
# hw/jc/loader/README.md's own measured BSCAN census records for the loader's
# jtag_axi_0 and jtag_hbm cores ("Debug cores (ltx): ... both on user chain 1"). The
# original "no debug hub" refusal (`$nhub != 0`) would have refused every correct
# build, including a bitstream that is otherwise exactly right, for the same reason
# the loader's own bitstream has one. One debug hub, and only on chain 1, is allowed;
# more than one, or one anywhere else, is still refused.
proc jccard_bscan_census {} {
  set n3 0; set n3ours 0; set n4 0; set n4ours 0; set nall 0
  foreach c [get_cells -hierarchical -filter {REF_NAME == BSCANE2}] {
    set ch [get_property JTAG_CHAIN $c]
    puts "JCCARD_BSCAN $c JTAG_CHAIN=$ch"
    incr nall
    if {$ch == 3} { incr n3; if {[string match "*u_jc_ctl_rx/u_jc_ctl_bscan" $c]} { incr n3ours } }
    if {$ch == 4} { incr n4; if {[string match "*u_jc_frx/u_jc_bscan" $c]} { incr n4ours } }
  }
  set nhub 0; set nhub_chain1 0
  foreach d [get_debug_cores -quiet] {
    incr nhub
    if {[llength [list_property $d C_USER_SCAN_CHAIN]]} {
      set chv [get_property C_USER_SCAN_CHAIN $d]
      puts "JCCARD_DEBUGCORE $d C_USER_SCAN_CHAIN=$chv"
      if {$chv == 1} { incr nhub_chain1 }
    } else {
      puts "JCCARD_DEBUGCORE $d"
    }
  }
  puts "JCCARD_BSCAN_SUMMARY total=$nall chain3=$n3 chain3_ctl=$n3ours chain4=$n4 chain4_loader=$n4ours debug_hub=$nhub debug_hub_chain1=$nhub_chain1"
  return [list $n3 $n3ours $n4 $n4ours $nhub $nhub_chain1]
}

proc jccard_bscan_check {stage} {
  lassign [jccard_bscan_census] n3 n3ours n4 n4ours nhub nhub_chain1
  # exactly one chain-3 (ctl, ours) and one chain-4 (loader, ours); AT MOST one
  # debug hub, and if it exists it must be the chain-1 one jtag_hbm causes.
  if {$n3 != 1 || $n3ours != 1 || $n4 != 1 || $n4ours != 1
      || $nhub > 1 || ($nhub == 1 && $nhub_chain1 != 1)} {
    jcc_fail "bscan census ($stage): chain3=$n3 chain3_ctl=$n3ours chain4=$n4 chain4_loader=$n4ours debug_hub=$nhub debug_hub_chain1=$nhub_chain1"
  }
  puts "JCCARD_BSCAN_OK $stage"
}

create_project -force jc_card $bd -part $part
set_param general.maxThreads 8
set_param synth.maxThreads 8

# ---- RTL sources ------------------------------------------------------------------
# Every path is listed explicitly, in dependency order, never globbed (the project's
# own rule: a glob would pull in whichever half-edited file another track has open).
# hw/fk33/gen_pcieep.py's own ENG_SRCS / CARD_SRCS are the source of truth for this
# list (hw/fk33/CLAUDE.md); this duplicates them in Tcl because the Jungle Cat card
# is not built from gen_pcieep.py's own Tcl text (build_fk33_pcieep.tcl is the FK33's
# PCIe endpoint, not this card), only from its imported section functions
# (gen_jc_card.py, via jc_card_bd.tcl). Keep the two lists in step by hand; Task 9's
# test file pins the load-bearing entries (a_util_ctr.vhd, jc_ctl_core.vhd) so a
# silent drop is caught red before any Vivado run.

# -- the USER4 loader (rtl/jc_loader_*.vhd, hw/jc/loader/rtl/*: UNCHANGED, never
#    edited; global-constraints.md).  VHDL-2008: the loader's own build sets these.
set LOADER_2008 {
  rtl/util_pkg.vhd rtl/jc_loader_pkg.vhd rtl/async_fifo.vhd rtl/jc_frame_core.vhd
  rtl/jc_hbm_writer.vhd rtl/jc_hbm_crc.vhd rtl/jc_status_sync.vhd
  rtl/jc_dna_reader.vhd rtl/jc_loader_core.vhd
}
foreach f $LOADER_2008 { add_files -norecurse $repo/$f }
# the loader's own tops: VHDL-93 (module-reference / BSCANE2 wrapper, no 2008 construct)
add_files -norecurse $repo/hw/jc/loader/rtl/jc_frame_rx.vhd
add_files -norecurse $repo/hw/jc/loader/rtl/jc_loader_top.vhd
update_compile_order -fileset sources_1

# -- the USER3 ctl core (rtl/jc_ctl_core.vhd and what it instantiates; plan Task 4).
#    jc_ctl_core.vhd itself is VHDL-93 (a module-reference top); jc_ctl_pkg.vhd,
#    jc_ctl_frame_core.vhd and jc_ctl_exec.vhd are VHDL-2008 underneath it (brief).
set CTL_2008 { rtl/jc_ctl_pkg.vhd rtl/jc_ctl_frame_core.vhd rtl/jc_ctl_exec.vhd }
foreach f $CTL_2008 { add_files -norecurse $repo/$f }
add_files -norecurse $repo/rtl/jc_ctl_core.vhd
add_files -norecurse $repo/hw/jc/ctl/rtl/jc_ctl_rx.vhd
update_compile_order -fileset sources_1

# -- subsystem A (gen_pcieep.ENG_SRCS, the engine's own RTL; VHDL-93 default, as the
#    FK33 build leaves them). rtl/a_util_ctr.vhd is Task 1's addition: it must be
#    here, or the engine elaborates against stale port counts.
set ENG_SRCS {
  rtl/mv4i_arith_pkg.vhd rtl/matvec_int4_desc_pkg.vhd rtl/stream_fifo.vhd
  rtl/axi_rd_fsm.vhd rtl/axi_rd_port.vhd rtl/weight_streamer.vhd
  rtl/act_mem_striped.vhd rtl/matvec_core.vhd rtl/matvec_int4.vhd
  rtl/a_util_ctr.vhd rtl/matvec_int4_desc_axi.vhd
}
foreach f $ENG_SRCS { add_files -norecurse $repo/$f }
add_files -norecurse $repo/hw/fk33/rtl/fk33_engine.vhd
update_compile_order -fileset sources_1

# -- the host seam (module-reference "fk33_seam"; VHDL-93)
add_files -norecurse $repo/rtl/fk33_seam.vhd
update_compile_order -fileset sources_1

# -- subsystems B/C/D (gen_pcieep.CARD_SRCS), VHDL-2008.  model_cfg_pkg.vhd is
#    DELIBERATELY NOT in this list: the 27B package (hw/fk33/gen/model_cfg_pkg_
#    QWEN38_27B.vhd) is added by jc_card_bd.tcl itself, before create_bd_design,
#    and it refuses the build if rtl/model_cfg_pkg.vhd (the 9B binding) is already
#    in sources_1 -- so this script must never add that file.
set CARD_2008 {
  rtl/bc_port_grant.vhd rtl/a_desc_adapter.vhd rtl/a_job_counter.vhd rtl/attn_emit.vhd
  rtl/fixed_luts_pkg.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd rtl/attn_mac_array.vhd
  rtl/divider_rs.vhd rtl/attn_recip.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
  rtl/attn_softmax.vhd rtl/imrope_pkg.vhd rtl/attn_twiddle.vhd rtl/fixed_pkg.vhd
  rtl/rmsnorm_rs.vhd rtl/attn_block.vhd rtl/attn_kv_axi.vhd rtl/gdn_conv.vhd
  rtl/gdn_head_emit.vhd rtl/gdn_silu.vhd rtl/gdn_y_emit.vhd rtl/rmsnorm_bf.vhd
  rtl/gdn_emit_chain.vhd rtl/gdn_exp_capture.vhd rtl/gdn_recur_pipe.vhd
  rtl/gdn_scalar.vhd rtl/l2norm_rs.vhd rtl/gdn_block.vhd rtl/gdn_job_seq.vhd
  rtl/gdn_conv_tap_mem.vhd rtl/gdn_conv_w_mem.vhd rtl/gdn_exp_mem.vhd
  rtl/gdn_state_axi.vhd rtl/gdn_state_mem.vhd rtl/gdn_state_store.vhd
  rtl/llama_map_pkg.vhd rtl/region_mem.vhd rtl/vec_mem.vhd rtl/rmsnorm_rs_mem.vhd
  rtl/rmsnorm_bf_mem.vhd rtl/swiglu_mem.vhd rtl/sampler_stream.vhd
  rtl/seq_desc_fetch.vhd rtl/seq_opdec.vhd rtl/seq_region_lock.vhd
  rtl/seq_vec_issue.vhd rtl/seq_vec_res.vhd
}
foreach f $CARD_2008 { add_files -norecurse $repo/$f }
add_files -norecurse $repo/rtl/fk33_llama_top.vhd
lappend CARD_2008 rtl/fk33_llama_top.vhd
update_compile_order -fileset sources_1

# -- the two remaining card tops (VHDL-93, module-reference: fk33_bc_grant, fk33_card.
#    fk33_card.vhd on disk here is the 27B one: run_card.sh ran gen_fk33_card.py
#    under JC_CARD_ENV in this tree before Vivado ever started, and this script
#    re-checks that below (JCCARD_27B), independently of gen_jc_card.py's own check.
add_files -norecurse $repo/hw/fk33/rtl/fk33_bc_grant.vhd
add_files -norecurse $repo/hw/fk33/rtl/fk33_card.vhd
update_compile_order -fileset sources_1

# -- READ BACK every VHDL-2008 property (the FK33 lesson: a path that does not match
#    leaves the file at VHDL-93 and the failure surfaces hundreds of lines later in a
#    generated bd.v, naming neither the file nor the standard).
set VHDL2008 [concat $LOADER_2008 $CTL_2008 $ENG_SRCS $CARD_2008]
# util_pkg.vhd and async_fifo.vhd are shared with ENG_SRCS at the FK33's own default
# (VHDL-93 there); the loader's hard requirement for 2008 wins for this project, since
# VHDL-2008 is a superset for the plain package/entity code in both files.
foreach f $VHDL2008 {
  set_property FILE_TYPE {VHDL 2008} [get_files $repo/$f]
}
foreach f $VHDL2008 {
  set t [get_property FILE_TYPE [get_files -quiet $repo/$f]]
  if {$t ne "VHDL 2008"} { jcc_fail "source $f is FILE_TYPE \"$t\", not VHDL 2008" }
}
puts "JCCARD_SOURCES [llength $VHDL2008] at VHDL 2008, [expr {[llength $ENG_SRCS] + 6}] at the default"
update_compile_order -fileset sources_1

# ---- the block design ---------------------------------------------------------------
if {[catch {source $here/jc_card_bd.tcl} err]} { jcc_fail "bd: $err" }
puts "JCCARD_BD_DONE"
if {$bdonly} {
  foreach p [lsort [get_bd_pins -quiet hbm/*]] { puts "JCCARD_HBMPIN $p" }
  exit 0
}

# -- the 27B model package must have landed as part of sourcing the BD above.
set pkgf [get_files -quiet "*model_cfg_pkg_QWEN38_27B.vhd"]
if {[llength $pkgf] != 1} { jcc_fail "27b package: expected one model_cfg_pkg_QWEN38_27B.vhd in sources_1, got [llength $pkgf]" }
puts "JCCARD_27B package $pkgf"

generate_target all [get_files jcc.bd]
make_wrapper -files [get_files jcc.bd] -top -import
add_files -norecurse $here/jc_card_top.vhd
add_files -fileset constrs_1 -norecurse $here/jc_card.xdc
set_property top jc_card_top [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { jcc_fail "synth_1 [get_property STATUS [get_runs synth_1]]" }
puts "JCCARD_SYNTH_DONE"
open_run synth_1 -name synth_1

# ---- the six module-reference cells: each input pin must carry a net (BD 41-759 is
#      silent when the VHDL port has a default; every one of ours has none) ----------
set EXPECT_CELLS {loader ctl eng fk33_seam_0 card bcgrant}
# constant BY DESIGN, per bit and polarity (jccard2 classification, 2026-10-07)
source $repo/hw/jc/card/jccard_const_allow.tcl
set total_nin 0; set total_bad {}; set total_allowed 0
foreach cname $EXPECT_CELLS {
  # anchored on the IP REF_NAME: fk33_engine has an inner instance also named `eng`
  set c [get_cells -quiet -hierarchical -filter "NAME =~ \"*/$cname\" && IS_PRIMITIVE == 0 && REF_NAME == jcc_${cname}_0"]
  if {[llength $c] != 1} { jcc_fail "netlist: cell $cname not found ([llength $c])" }
  foreach pin [get_pins -of_objects $c -filter {DIRECTION == IN}] {
    incr total_nin
    set n [get_nets -quiet -of_objects $pin]
    if {$n eq ""} { lappend total_bad "$pin:no_net"; continue }
    set t [get_property TYPE $n]
    if {($t eq "GROUND" || $t eq "POWER") && ![jcc_const_allowed $pin $t]} { lappend total_bad "$pin:$t"; continue }
    if {$t eq "GROUND" || $t eq "POWER"} { incr total_allowed }
  }
}
puts "JCCARD_NETLIST_INPUTS checked=$total_nin allowed_const=$total_allowed constant_or_open=[llength $total_bad]"
foreach b $total_bad { puts "JCCARD_NETLIST_CONST $b" }
if {[llength $total_bad] > 0} { jcc_fail "netlist: [llength $total_bad] module-reference inputs constant or open" }

# ---- THE LEVERS NOT VISIBLE TO THE BD: NWIDE, SWEEP_PIPE, SCORE_EARLY -------------
# FAST_POP is a generic on the fk33_engine module-reference cell and gen_jc_card.py
# already reads its CONFIG property back at BD-generation time (m6, task-8 fix round
# 1). NWIDE, SWEEP_PIPE and SCORE_EARLY are generic maps deep inside fk33_llama_top
# and reach no module-reference boundary, so the only place they can be read is
# synthesis's own `Parameter <NAME> bound to: <value>` trace line (hw/fk33/CLAUDE.md:
# "Diff `Parameter <NAME> bound to` out of both builds' logs before attributing
# anything"; "Bind lines can be missing from a log... so a lever's absence from the
# log proves nothing" -- which is why a MISSING line is refused here exactly as a
# WRONG value is, not treated as silent pass).
#
# Task 9 fix round 1, CRITICAL C1 (MEASURED against three real builds; evidence and
# the parsing proc are in hw/jc/card/jccard_levers.tcl, tested stand-alone by
# test_jccard_levers.py against real log excerpts):
#  1. Vivado spells a boolean generic's bound value as the NUMBER 0/1 ("Parameter
#     NWIDE bound to: 0 - type: bool"), never the word "false"/"true". The original
#     check here compared against the literal word "false" and so refused build20
#     itself -- the one build its own levers patch is supposed to reproduce.
#  2. The line is not in synth_1's `runme.log` at all for a project-mode run:
#     runme.log is the project launcher's own log. The synthesis ENGINE's full
#     elaboration trace -- every module's own `Parameter ... bound to` line -- goes
#     only to `<top>.vds` in the same run directory (MEASURED: build20's runme.log
#     has 782 unrelated `bound to` lines and zero for NWIDE; its bd_wrapper.vds has
#     exactly one). The original check read runme.log and so found NOTHING, which
#     its own "no bind line" refusal then (correctly, but for the wrong reason)
#     turned into a hard failure on every build, correct or not.
source $here/jccard_levers.tcl
set top [get_property top [current_fileset]]
set synthlog [get_property DIRECTORY [get_runs synth_1]]/${top}.vds
if {![file exists $synthlog]} { jcc_fail "levers: no synth_1 trace at $synthlog" }
set logtxt [read [open $synthlog]]
set LEVERS_OFF {NWIDE SWEEP_PIPE SCORE_EARLY}
set lever_bad {}
foreach lv $LEVERS_OFF {
  set res [jccard_lever_status $lv $logtxt]
  set status [lindex $res 0]
  set detail [lindex $res 1]
  switch -- $status {
    off     { puts "JCCARD_LEVER $lv off ($detail)" }
    on      { lappend lever_bad "$lv: bound ON ($detail), expected off" }
    missing { lappend lever_bad "$lv: $detail (build12_levers_off.patch not applied, or the log moved)" }
    mixed   { lappend lever_bad "$lv: $detail" }
  }
}
if {[llength $lever_bad] > 0} { jcc_fail "levers: [join $lever_bad {; }]" }
puts "JCCARD_LEVERS_OK NWIDE=off SWEEP_PIPE=off SCORE_EARLY=off"

# ---- clocks and CDC -----------------------------------------------------------------
source $repo/hw/jc/loader/jc_loader_timing.tcl
source $repo/hw/jc/ctl/jc_ctl_timing.tcl
if {[catch {
  # sysclk, and clk_core (clk_wiz_0/clk_out3) through its own IP constraints: find
  # aclk from a register this build's own RTL clocks, and require 1000/clk_mhz ns:
  # the ONE clock domain global-constraints.md pins for this card, at -clk_mhz.
  set aclk_clk [get_clocks -of_objects [jcl_pins "${CORE_LOADER}sync/pub_reg/C"]]
  set aclk_p [get_property PERIOD $aclk_clk]
  puts "JCCARD_ACLK $aclk_clk period $aclk_p"
  set aclk_want [expr {1000.0 / $clk_mhz}]
  if {abs($aclk_p - $aclk_want) > 0.001} { jcc_fail "aclk period $aclk_p, expected [format %.3f $aclk_want] (clk_core must be $clk_mhz MHz)" }

  # chain-4 (loader, unchanged RTL/constraints, hierarchy prefix absorbed by the
  # leading wildcard in CORE_LOADER and in the bscan pattern below) and chain-3
  # (ctl, plan Task 4) share the one physical TCK.
  set tckpin4 [jcl_pins "*u_jc_frx/u_jc_bscan/INTERNAL_TCK"]
  if {[llength $tckpin4] != 1} { error "expected one loader BSCANE2 INTERNAL_TCK pin, got [llength $tckpin4]" }
  create_clock -name tck_user4 -period $TCK_P $tckpin4
  set tckpin3 [jctl_pins "*u_jc_ctl_rx/u_jc_ctl_bscan/INTERNAL_TCK"]
  if {[llength $tckpin3] != 1} { error "expected one ctl BSCANE2 INTERNAL_TCK pin, got [llength $tckpin3]" }
  create_clock -name tck_user3 -period $TCK_P $tckpin3

  jcl_dna_clock $CORE_LOADER $DNA_DIV
  jcl_cdc $CORE_LOADER $aclk_clk [get_clocks tck_user4] $aclk_p $TCK_P
  jcl_tdi "*u_jc_frx/u_jc_bscan" [expr {$TCK_P / 2.0}]
  jcl_dna_mcp $DNA_DIV $aclk_clk

  jctl_cdc $CORE_CTL $aclk_clk [get_clocks tck_user3] $aclk_p $TCK_P
  jctl_tdi "*u_jc_ctl_rx/u_jc_ctl_bscan" [expr {$TCK_P / 2.0}]
  jctl_rram $CORE_CTL $aclk_clk [get_clocks tck_user3]

  # CATTRIP -> compute_halt: RULED asynchronous (task-8 report concern 1; no 2-FF
  # synchroniser module exists for it, and adding one is outside this task's file
  # list), so it is constrained the way the loader's own hbm_cat_trip is: a quasi-
  # static level, false-pathed rather than timed against a meaningless edge
  # relationship. halt_or is the util_vector_logic OR cell gen_jc_card.py's I3 fix
  # added (fix round 1); its Res pin drives eng/compute_halt.
  set halt_src [get_pins -quiet -hierarchical -filter {NAME =~ "*halt_or*/Res"}]
  if {[llength $halt_src] != 1} { error "expected one halt_or/Res pin, got [llength $halt_src]" }
  set_false_path -from $halt_src
  puts "JCCARD_CATTRIP_FALSE_PATH $halt_src"
} err]} { jcc_fail "constraints: $err" }

# ---- CDC audit: every endpoint reached across the two clocks that is not one of the
#      ctl core's named synchronisers is UNEXPECTED (jctl_cdc_audit, shared with the
#      ctl OOC route). The loader's own crossings have no equivalent generic audit
#      proc (its build never needed one, being the only other clock in its design);
#      report_cdc below is read for those by eye against jc_loader_timing.tcl's
#      named list until one is written. -----------------------------------------------
set cdc_bad [jctl_cdc_audit $CORE_CTL $aclk_clk [get_clocks tck_user3]]
puts "JCCARD_CDC_UNEXPECTED $cdc_bad"
if {$cdc_bad != 0} { jcc_fail "cdc audit: $cdc_bad unexpected ctl crossing(s)" }

opt_design
jccard_bscan_check post_opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $bd/jc_card_routed.dcp

set rp $bd/reports
file mkdir $rp
report_route_status -file $rp/route_status.rpt
report_utilization -file $rp/utilization.rpt
report_utilization -hierarchical -file $rp/utilization_hier.rpt
report_timing_summary -max_paths 20 -report_unconstrained -file $rp/timing_summary.rpt
report_clock_interaction -file $rp/clock_interaction.rpt
report_clocks -file $rp/clocks.rpt
report_cdc -details -file $rp/cdc.rpt
report_cdc -file $rp/cdc_summary.rpt
report_exceptions -file $rp/exceptions.rpt
report_exceptions -ignored -file $rp/exceptions_ignored.rpt
report_bus_skew -file $rp/bus_skew.rpt
report_methodology -file $rp/methodology.rpt
report_drc -file $rp/drc.rpt
report_pulse_width -all -file $rp/pulse_width.rpt
check_timing -file $rp/check_timing.rpt

# report_cdc's own severity classification: no "Critical" row outside the named
# synchronisers (loader's 6, ctl's 6, the CATTRIP false path). UNVERIFIED in Vivado
# (report_cdc's exact column layout has not been read from a real run on this
# design): this is a best-effort text scan, not a parsed table, and its false-negative
# risk is why jctl_cdc_audit above is the hard gate and this is a second opinion.
set cdc_txt [read [open $rp/cdc.rpt]]
set OK_PAT {sync/st_r_reg sync/tgl_s1_reg sync/ack_s1_reg rak_s1_reg fifo/wp_g_s1_reg
            fifo/rp_g_s1_reg trst_s1_reg trip_s1_reg halt_or rram dnar INTERNAL_TDI}
set crit_bad 0
foreach line [split $cdc_txt "\n"] {
  if {![regexp -nocase {critical} $line]} { continue }
  set known 0
  foreach pat $OK_PAT { if {[string match "*$pat*" $line]} { set known 1; break } }
  if {!$known} { incr crit_bad; puts "JCCARD_CDC_REPORT_UNKNOWN $line" }
}
puts "JCCARD_CDC_REPORT_CRITICAL_UNKNOWN $crit_bad"
if {$crit_bad > 0} { jcc_fail "report_cdc: $crit_bad critical crossing(s) outside the named synchronisers" }

set rs [report_route_status -return_string]
if {![regexp {routing errors[ .]*:\s*(\d+)} $rs -> nerr] || $nerr != 0} { jcc_fail "route status" }
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "JCCARD_WNS $wns"
puts "JCCARD_WHS $whs"
if {$whs eq "" || $whs < 0} { jcc_fail "timing WHS=$whs (hold violations are never waived by allow_neg)" }
if {$wns eq ""} { jcc_fail "timing WNS=$wns" }
if {$wns < 0} {
  if {!$allow_neg} { jcc_fail "timing WNS=$wns < 0 (pass allow_neg on -tclargs to override)" }
  puts "JCCARD_WNS_NEGATIVE_ALLOWED $wns"
}

jccard_bscan_check pre_write_bitstream
write_bitstream -force $bd/jc_card.bit
write_debug_probes -force $bd/jc_card.ltx
if {![file exists $bd/jc_card.bit]} { jcc_fail "no bitstream" }
puts "JCCARD_BIT $bd/jc_card.bit"
puts "JCCARD_LTX [expr {[file exists $bd/jc_card.ltx] ? "$bd/jc_card.ltx" : "none"}]"
puts "JCCARD_DONE"
