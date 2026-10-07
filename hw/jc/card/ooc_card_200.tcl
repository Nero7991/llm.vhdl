# hw/jc/card/ooc_card_200.tcl -- Task 10.  OOC synth + opt + place + phys_opt +
# route of jc_ooc27_top (fk33_engine + fk33_seam + fk33_card, the 27B wrapper) at
# 200 MHz on xcvu35p-fsvh2104-2L-e.  Synthesis, implementation and reports only:
# no hardware access, no project, no block design, no HBM IP, no PCIe.
#
# Modelled on /mnt/storage/fk33_builds/ooc27_vu35/ooc_card_vu35.tcl (plain
# read_vhdl, one synth_design -mode out_of_context, opt/place/phys_opt/route,
# report_utilization + report_timing_summary) -- that script already has
# route_design; this one keeps it and adds the anchored sentinels and the
# worst-10-paths report Task 10 asks for.
#
# WHY jc_ooc27_top AND NOT fk33_card ALONE.  docs/debugging/2026-09-30_27b-
# fits-vu35p-ooc-timing-artifact.md measured fk33_card ALONE (no engine, no
# block design, no floorplan) at 69.9 MHz OOC on this exact part -- a ~2x
# pessimistic STANDALONE-OOC ARTIFACT, not a real limiter (the identical path
# on the committed 9B fk33_card gives 69.0 MHz OOC while the SHIPPED 9B build
# runs that same compute at >=120 MHz in-context).  Rerunning fk33_card alone
# here would just reproduce that known artifact under a new name.  jc_ooc27_top
# (hw/jc/card/gen_ooc27_top.py) restores two of that note's three missing-
# context items -- the engine, and the real dataflow between it and the card,
# every wired net transcribed verbatim from hw/jc/card/jc_card_bd.tcl's own
# connect_bd_net calls between these three cells -- while still having no
# floorplan, so a result from here is OOC evidence towards the open "real
# composed 200 MHz" question, not an in-context answer to it (see that note's
# "Open, not yet answered", and the generator's own docstring for exactly what
# is wired and what is only co-resident).
#
# THE PREPARED TREE.  <repo> must already be a tree with build12_levers_off.patch
# applied and hw/fk33/rtl/fk33_card.vhd regenerated for the 27B shape (run_ooc27.sh
# does both, the same way run_card.sh does for the full bitstream build) AND
# hw/jc/card/jc_ooc27_top.vhd already generated into it by gen_ooc27_top.py
# (run_ooc27.sh does this too). This script does not run either generator itself:
# it only reads what is already on disk at <repo>, so a tree it is pointed at
# with neither step done fails with "unit jc_ooc27_top not found" or elaborates
# the UNPATCHED (FAST_POP/NWIDE/SWEEP_PIPE/SCORE_EARLY at their un-levered
# defaults) RTL with no sentinel ever telling you which -- which is exactly why
# run_ooc27.sh, not a bare `vivado -source` on this file, is the supported entry
# point (test_ooc27.py's levers assertions are on run_ooc27.sh, not here).
#
# Usage:
#   vivado -mode batch -nojournal -log <logfile> -source ooc_card_200.tcl \
#       -tclargs <repo> <outdir> [part] -nonce <value>
#   <repo>   the prepared tree's root (run_ooc27.sh's <root>/src)
#   <outdir> where checkpoints and reports land
#   [part]   default xcvu35p-fsvh2104-2L-e (global-constraints.md)
#   -nonce   this run's identity (fix round 1, I2): printed FIRST, before
#            anything else, exactly as build_card.tcl's JCCARD_NONCE is, so
#            run_ooc27.sh can gate JCOOC27_DONE on a log that carries THIS
#            run's own nonce with DONE appearing AFTER it. The original
#            version of run_ooc27.sh instead appended the nonce to the log
#            file ITSELF before launching Vivado -- but Vivado's own -log
#            truncates/rotates the file it is given, so that line never
#            survived to be found, and every run therefore read as
#            JCOOC27_FAIL regardless of whether Vivado actually succeeded.
#
# Sentinels (anchored):
#   ^JCOOC27_NONCE <value>                     FIRST line this script prints
#   ^JCOOC27_PART <part>
#   ^JCOOC27_SCOPE internal_reg_to_reg_only io_untimed   (fix round 1, I5)
#   ^JCOOC27_ROUTE routing_errors <n>          (else ^JCOOC27_ROUTE_FAIL, which
#                                                stops this script before WNS/
#                                                WHS/WORST10/UTIL/DONE -- fix
#                                                round 1, M1)
#   ^JCOOC27_WNS <ns>   ^JCOOC27_WHS <ns>
#   ^JCOOC27_WORST10 <rank> slack=<ns> src_clk=<name> dst_clk=<name> start=<pin> end=<pin>
#   ^JCOOC27_UTIL <CATEGORY> used=<n> pct=<pct>
#   ^JCOOC27_DONE                              LAST line this script prints
# A Tcl error anywhere ends the run WITHOUT ^JCOOC27_DONE -- a waiter gates on
# that sentinel in THIS script's own log, never on Vivado's exit code alone
# (CLAUDE.md: "a completion signal that also fires on failure is not one").

proc jcoo27_fail {msg} { puts "JCOOC27_FAIL $msg"; exit 1 }

set repo  [file normalize [lindex $argv 0]]
set out   [file normalize [lindex $argv 1]]
set part  [expr {[llength $argv] > 2 && [lindex $argv 2] ne "-nonce" ? [lindex $argv 2] : "xcvu35p-fsvh2104-2L-e"}]
set nonce_idx [lsearch -exact $argv -nonce]
set nonce     [expr {$nonce_idx >= 0 ? [lindex $argv [expr {$nonce_idx + 1}]] : ""}]
if {$nonce eq ""} { jcoo27_fail "no -nonce given on -tclargs (run_ooc27.sh always passes one)" }
puts "JCOOC27_NONCE $nonce"
set ACLK_P 5.000

file mkdir $out
puts "JCOOC27_PART $part"
puts "JCOOC27_CLK_CORE_MHZ 200"
puts "JCOOC27_SCOPE internal_reg_to_reg_only io_untimed"
set_param general.maxThreads 8

# ---- the file list, explicit, never globbed (CLAUDE.md house style) --------
# Every path below is one of build_card.tcl's own ENG_SRCS / CARD_2008 groups
# (hw/jc/card/build_card.tcl), so a source added or removed there is a source
# this list drifts from -- deliberately not auto-shared via a Tcl proc import,
# because build_card.tcl's lists live inside a much larger project-mode flow
# this script does not run; test_ooc27.py instead greps both files for the
# same substrings so a drift between them fails the dry run, not a build six
# hours in.
#
# rtl/model_cfg_pkg.vhd (the 9B binding) is DELIBERATELY NOT in this list, for
# the same reason build_card.tcl excludes it: the 27B package below binds the
# SAME package name, and having both in one `read_vhdl` run shadows one with
# the other depending on read order, which is not an error Vivado raises.
set VHDL_FILES [list \
  rtl/util_pkg.vhd \
  rtl/async_fifo.vhd \
  hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd \
  rtl/mv4i_arith_pkg.vhd rtl/matvec_int4_desc_pkg.vhd rtl/stream_fifo.vhd \
  rtl/axi_rd_fsm.vhd rtl/axi_rd_port.vhd rtl/weight_streamer.vhd \
  rtl/act_mem_striped.vhd rtl/matvec_core.vhd rtl/matvec_int4.vhd \
  rtl/a_util_ctr.vhd rtl/matvec_int4_desc_axi.vhd \
  hw/fk33/rtl/fk33_engine.vhd \
  rtl/fk33_seam.vhd \
  rtl/bc_port_grant.vhd rtl/a_desc_adapter.vhd rtl/a_job_counter.vhd rtl/attn_emit.vhd \
  rtl/fixed_luts_pkg.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd rtl/attn_mac_array.vhd \
  rtl/divider_rs.vhd rtl/attn_recip.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd \
  rtl/attn_softmax.vhd rtl/imrope_pkg.vhd rtl/attn_twiddle.vhd rtl/fixed_pkg.vhd \
  rtl/rmsnorm_rs.vhd rtl/attn_block.vhd rtl/attn_kv_axi.vhd rtl/gdn_conv.vhd \
  rtl/gdn_head_emit.vhd rtl/gdn_silu.vhd rtl/gdn_y_emit.vhd rtl/rmsnorm_bf.vhd \
  rtl/gdn_emit_chain.vhd rtl/gdn_exp_capture.vhd rtl/gdn_recur_pipe.vhd \
  rtl/gdn_scalar.vhd rtl/l2norm_rs.vhd rtl/gdn_block.vhd rtl/gdn_job_seq.vhd \
  rtl/gdn_conv_tap_mem.vhd rtl/gdn_conv_w_mem.vhd rtl/gdn_exp_mem.vhd \
  rtl/gdn_state_axi.vhd rtl/gdn_state_mem.vhd rtl/gdn_state_store.vhd \
  rtl/llama_map_pkg.vhd rtl/region_mem.vhd rtl/vec_mem.vhd rtl/rmsnorm_rs_mem.vhd \
  rtl/rmsnorm_bf_mem.vhd rtl/swiglu_mem.vhd rtl/sampler_stream.vhd \
  rtl/seq_desc_fetch.vhd rtl/seq_opdec.vhd rtl/seq_region_lock.vhd \
  rtl/seq_vec_issue.vhd rtl/seq_vec_res.vhd \
  rtl/fk33_llama_top.vhd \
  hw/fk33/rtl/fk33_card.vhd \
  hw/jc/card/jc_ooc27_top.vhd \
]
foreach f $VHDL_FILES {
  set p [file join $repo $f]
  if {![file exists $p]} { error "JCOOC27_FAIL missing source $p" }
  read_vhdl -vhdl2008 $p
}
puts "JCOOC27_SOURCES [llength $VHDL_FILES]"

# ---- the one clock, two registered-reset inputs, and one false-pathed
#      control input ---------------------------------------------------------
# rst/rstn: fix round 1, I4. jc_ooc27_top.vhd now registers both on clk
# before use (rst_r2/rstn_r2, two flops), so the top-level port itself only
# ever fans out to ONE flop's D input, not ~2.7e5 of them (the original
# version's rst drove every reset pin across all three instances directly).
# A light input delay on that single-fanout net is still the right harness
# convention (ooc_loader_core.tcl's own rationale for arst/hbm_cat_trip:
# -min 0.5 stands for a parent register's clock-to-out plus route).
foreach p {rst rstn} {
  lappend xdc_lines "set_input_delay -clock clk -max 2.000 \[get_ports $p\]"
  lappend xdc_lines "set_input_delay -clock clk -min 0.500 \[get_ports $p\]"
}
# compute_halt: fix round 1, I4. build_card.tcl:342's own treatment of this
# exact signal (CATTRIP, ruled asynchronous/quasi-static, no synchroniser)
# is a false path, not a timed input delay -- an input delay implies a
# meaningful clock-relative timing requirement this signal does not have.
lappend xdc_lines "set_false_path -from \[get_ports compute_halt\]"
set x [file join $out clocks.xdc]
set fh [open $x w]
puts $fh "create_clock -name clk -period $ACLK_P \[get_ports clk\]"
foreach l $xdc_lines { puts $fh $l }
close $fh
read_xdc -mode out_of_context $x

synth_design -top jc_ooc27_top -part $part -mode out_of_context -flatten_hierarchy rebuilt
write_checkpoint -force [file join $out synth.dcp]
report_utilization -file [file join $out util_synth.rpt]

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out routed.dcp]

report_route_status -file [file join $out route_status.rpt]
report_utilization -file [file join $out util_routed.rpt]
report_utilization -hierarchical -file [file join $out util_routed_hier.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $out timing_routed.rpt]
report_clock_interaction -file [file join $out clock_interaction.rpt]
report_methodology -file [file join $out methodology.rpt]
check_timing -file [file join $out check_timing.rpt]

# ---- ^JCOOC27_ROUTE ---------------------------------------------------------
# fix round 1, M1: a routing failure must stop this script HERE, before WNS/
# WHS/WORST10/UTIL are even read (a route that did not finish has no
# meaningful timing to report) and, critically, before ^JCOOC27_DONE -- the
# original version printed JCOOC27_ROUTE_FAIL and then carried on to print
# JCOOC27_DONE anyway at the end regardless, so a waiter gating on DONE
# alone would have read a failed route as a finished one.
set rs [report_route_status -return_string]
if {[regexp {routing errors[ .]*:\s*(\d+)} $rs -> nerr]} {
  puts "JCOOC27_ROUTE routing_errors $nerr"
  if {$nerr != 0} { jcoo27_fail "route status: $nerr routing error(s)" }
} else {
  puts $rs
  jcoo27_fail "route status: could not parse routing error count"
}

# ---- ^JCOOC27_WNS / ^JCOOC27_WHS --------------------------------------------
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "JCOOC27_WNS $wns"
puts "JCOOC27_WHS $whs"

# ---- ^JCOOC27_WORST10 --------------------------------------------------------
# fix round 1, M2: -nworst 1 (one path PER ENDPOINT), not -nworst 10 (up to
# ten paths to the SAME endpoint, which could and did let the "worst 10"
# list repeat one endpoint instead of surfacing ten distinct ones).
set worst10 [get_timing_paths -max_paths 10 -nworst 1 -setup]
set rank 0
foreach p $worst10 {
  incr rank
  set slk    [get_property SLACK $p]
  set srcclk [get_property STARTPOINT_CLOCK $p]
  set dstclk [get_property ENDPOINT_CLOCK $p]
  set startp [get_property STARTPOINT_PIN $p]
  set endp   [get_property ENDPOINT_PIN $p]
  puts "JCOOC27_WORST10 $rank slack=$slk src_clk=$srcclk dst_clk=$dstclk start=$startp end=$endp"
}
puts "JCOOC27_WORST10_COUNT $rank"

# ---- ^JCOOC27_UTIL, with percentages ----------------------------------------
set u [report_utilization -return_string]
proc jcoo27_used_pct {u row} {
  if {[regexp "\\| $row +\\| +(\[0-9.\]+) +\\| +\[0-9.\]+ +\\| +\[0-9.\]+ +\\| +(\[0-9.\]+) +\\| +(\[0-9.\]+)" \
        $u -> used avail pct]} {
    return [list $used $pct]
  }
  return [list -1 -1]
}
foreach {label row} {
  CLB_LUT       {CLB LUTs}
  CLB_FF        {CLB Registers}
  BRAM          {Block RAM Tile}
  URAM          URAM
  DSP           DSPs
} {
  lassign [jcoo27_used_pct $u $row] used pct
  puts "JCOOC27_UTIL $label used=$used pct=$pct"
}

puts "JCOOC27_DONE"
