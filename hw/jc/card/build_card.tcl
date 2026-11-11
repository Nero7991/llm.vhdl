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
# implementation strategy from run_card.sh --impl (default | congestion)
set impl_idx  [lsearch -exact $argv -impl]
set impl      [expr {$impl_idx >= 0 ? [lindex $argv [expr {$impl_idx + 1}]] : "default"}]
set TCK_P 37.037
set DNA_DIV 10
set CORE_LOADER "*u_jc_core/"
# anchored: "*ctl/inst/" also prefixes u_bd/jcc_i/engctl/inst/ (a smartconnect)
set CORE_CTL    "*/jcc_i/ctl/inst/"
proc jcc_fail {msg} { puts "JCCARD_FAIL $msg"; exit 1 }
# pure census / bus-skew / report_cdc evaluators (tested stand-alone: test_jccard_post.py)
source $here/jccard_post.tcl
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
if {$impl ni {default congestion}} { jcc_fail "-impl $impl is not default or congestion" }
puts "JCCARD_IMPL $impl"

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
# Fix round 2026-10-07 (post-synth-audit.md WILL-FAIL 2): get_debug_cores returns the
# debug HUB (dbg_hub, created inside opt_design, the only core with C_USER_SCAN_CHAIN)
# AND every JTAG-AXI core (here u_bd/jcc_i/jtag_hbm). The previous census counted both
# as hubs, read 2, and refused every correct card. They are now counted apart and the
# set is exact: one hub, dbg_hub, on chain 1, and one JTAG-AXI core, jtag_hbm
# (jccard_census_eval in jccard_post.tcl, tested by test_jccard_post.py).
proc jccard_bscan_census {} {
  set bscans {}
  foreach c [get_cells -hierarchical -filter {REF_NAME == BSCANE2}] {
    set ch [get_property JTAG_CHAIN $c]
    puts "JCCARD_BSCAN $c JTAG_CHAIN=$ch"
    lappend bscans [list [get_property NAME $c] $ch]
  }
  set cores {}
  foreach d [get_debug_cores -quiet] {
    if {[llength [list_property $d C_USER_SCAN_CHAIN]]} {
      set chv [get_property C_USER_SCAN_CHAIN $d]
      puts "JCCARD_DEBUGCORE hub $d C_USER_SCAN_CHAIN=$chv"
    } else {
      set chv ""
      puts "JCCARD_DEBUGCORE jtag_axi $d"
    }
    lappend cores [list [get_property NAME $d] $chv]
  }
  lassign [jccard_census_eval $bscans $cores] ok summary
  puts "JCCARD_BSCAN_SUMMARY $summary"
  return [list $ok $summary]
}

proc jccard_bscan_check {stage} {
  lassign [jccard_bscan_census] ok summary
  if {!$ok} { jcc_fail "bscan census ($stage): $summary" }
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

# -- the token loop and the die-to-die link (plan 2026-11-04 Task 7). tok_loop and what it
#    instantiates are VHDL-2008; rtl/jc_loader_pkg.vhd, rtl/async_fifo.vhd and
#    rtl/util_pkg.vhd are already in the project (the loader list). The two module-reference
#    tops, rtl/jc_tok_top.vhd and hw/jc/link/rtl/jc_gtg_clk.vhd, are plain VHDL: a BD module
#    reference refuses a VHDL-2008 top file (MEASURED Task 5, filemgmt 56-195).
set LINK_2008 {
  rtl/tok_loop_pkg.vhd rtl/tok_loop_regs.vhd rtl/tok_loop_axm.vhd rtl/tok_loop_fsm.vhd
  rtl/jc_seam_mux.vhd rtl/embed_gather.vhd rtl/jc_link_pkg.vhd rtl/jc_link_tx.vhd
  rtl/jc_link_rx.vhd rtl/tok_loop.vhd
}
foreach f $LINK_2008 { add_files -norecurse $repo/$f }
set LINK_TOPS { rtl/jc_tok_top.vhd hw/jc/link/rtl/jc_gtg_clk.vhd }
foreach f $LINK_TOPS { add_files -norecurse $repo/$f }
update_compile_order -fileset sources_1

# -- READ BACK every VHDL-2008 property (the FK33 lesson: a path that does not match
#    leaves the file at VHDL-93 and the failure surfaces hundreds of lines later in a
#    generated bd.v, naming neither the file nor the standard).
set VHDL2008 [concat $LOADER_2008 $CTL_2008 $ENG_SRCS $CARD_2008 $LINK_2008]
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
foreach f $LINK_TOPS {
  set t [get_property FILE_TYPE [get_files -quiet $repo/$f]]
  if {$t ne "VHDL"} { jcc_fail "source $f is FILE_TYPE \"$t\", not VHDL (a module-reference top)" }
}
puts "JCCARD_SOURCES [llength $VHDL2008] at VHDL 2008, [expr {[llength $ENG_SRCS] + 6 + [llength $LINK_TOPS]}] at the default"
update_compile_order -fileset sources_1

# ---- the block design ---------------------------------------------------------------
if {[catch {source $here/jc_card_bd.tcl} err]} { jcc_fail "bd: $err" }
# THE TOP'S COMPONENT MUST BE THE WRAPPER'S PORT LIST. jc_card_top.vhd declares jcc_wrapper
# as a component with the ports gen_jc_card.py predicts (the GT interface ports' names are a
# Vivado convention, <intf port>_<member>); read the wrapper make_wrapper writes and refuse
# on any difference, here, before synthesis (plan 2026-11-04 Task 7).
proc jcc_wrapper_ports {f} {
  set fh [open $f]; set t [read $fh]; close $fh
  set ps {}
  foreach {- d n} [regexp -all -inline -line {^\s*(input|output)\s+(?:\[[^\]]*\]\s*)?(\w+)\s*[;,]?\s*$} $t] {
    lappend ps [list $n [expr {$d eq "input" ? "in" : "out"}]]
  }
  return [lsort $ps]
}
proc jcc_component_ports {f} {
  set fh [open $f]; set t [read $fh]; close $fh
  if {![regexp {component\s+jcc_wrapper\s+is\s+port\s*\((.*?)\)\s*;\s*end\s+component} $t -> body]} {
    jcc_fail "wrapper check: no jcc_wrapper component in $f"
  }
  set ps {}
  foreach {- n d} [regexp -all -inline {(\w+)\s*:\s*(in|out)\s} $body] { lappend ps [list $n $d] }
  return [lsort $ps]
}
set _wf [make_wrapper -files [get_files jcc.bd] -top -force]
set _wp [jcc_wrapper_ports $_wf]
set _cp [jcc_component_ports $here/jc_card_top.vhd]
puts "JCCARD_WRAPPER_PORTS [llength $_wp] component=[llength $_cp] file=$_wf"
if {$_wp ne $_cp} {
  foreach p $_wp { if {[lsearch -exact $_cp $p] < 0} { puts "JCCARD_WRAPPER_ONLY $p" } }
  foreach p $_cp { if {[lsearch -exact $_wp $p] < 0} { puts "JCCARD_COMPONENT_ONLY $p" } }
  jcc_fail "wrapper ports differ from jc_card_top.vhd's jcc_wrapper component"
}
puts "JCCARD_WRAPPER_PORTS_OK"
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

# Every synthesis run (the OOC IP runs and synth_1) caps synth_design's helper processes
# through a TCL.PRE hook: set_param here does not reach launch_runs' children, and each
# synth_design otherwise forks up to 8 (jccard3/jccard4 ran out of swap, 2026-10-07).
if {[catch {create_ip_run [get_files jcc.bd]} e]} { puts "JCCARD_SYNTH_HOOK create_ip_run: $e" }
set synth_runs [get_runs -filter {IS_SYNTHESIS}]
foreach r $synth_runs { set_property STEPS.SYNTH_DESIGN.TCL.PRE $here/synth_threads_pre.tcl $r }
puts "JCCARD_SYNTH_HOOK runs=[llength $synth_runs]"
if {[llength $synth_runs] < 2} { jcc_fail "synth hook: only [llength $synth_runs] synthesis run(s) exist before launch; the OOC IP runs would not get the cap" }

# -jobs 2, not 4: jccard3 (2026-10-07) ran out of swap with four IP syntheses overlapping
launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { jcc_fail "synth_1 [get_property STATUS [get_runs synth_1]]" }
# teeth for the hook: every run that ran synth_design must report the cap in its own log
set uncapped {}
foreach r $synth_runs {
  set lf [file join [get_property DIRECTORY $r] runme.log]
  if {![file exists $lf]} continue
  set fh [open $lf]; set txt [read $fh]; close $fh
  if {[string first "Multithreading enabled for synth_design" $txt] >= 0 && [string first "maximum of 2 processes" $txt] < 0} { lappend uncapped [get_property NAME $r] }
}
if {[llength $uncapped] > 0} { jcc_fail "synth hook not applied (not maximum of 2 processes): $uncapped" }
puts "JCCARD_SYNTH_HOOK verified"
puts "JCCARD_SYNTH_DONE"
open_run synth_1 -name synth_1

# ---- the six module-reference cells: each input pin must carry a net (BD 41-759 is
#      silent when the VHDL port has a default; every one of ours has none) ----------
set EXPECT_CELLS {loader ctl eng fk33_seam_0 card bcgrant tok gtgclk}
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
#  3. With the BD's module-reference cells synthesized OUT OF CONTEXT, the card's own
#     elaboration (and so its bind lines) is in jcc_card_0_synth_1/jcc_card_0.vds, not in
#     synth_1/<top>.vds (MEASURED, jccard5 2026-10-07). Gather every synthesis run's .vds.
set synthlogs {}
foreach r [get_runs -filter {IS_SYNTHESIS}] {
  foreach f [glob -nocomplain -directory [get_property DIRECTORY $r] *.vds] { lappend synthlogs $f }
}
if {[llength $synthlogs] == 0} { jcc_fail "levers: no synthesis .vds trace in any synthesis run" }
puts "JCCARD_LEVER_LOGS [llength $synthlogs]"
set logtxt ""
foreach f $synthlogs { set fh [open $f]; append logtxt [read $fh] "\n"; close $fh }
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
source $repo/hw/jc/link/jc_link_timing.tcl
set CORE_TOK "*/jcc_i/tok/inst/"
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
  # synchroniser STRUCTURE on the linked synthesized netlist, before opt_design can
  # replicate a flop (fix round 2026-10-07, post-synth-audit.md PASS-WRONGLY 5): the
  # card's ctl is its own OOC synthesis, so ooc_ctl_core.tcl's JCCTL_SYNC_OK does not
  # transfer; this is the same call that flow makes, with the card's prefix.
  jctl_syncs $CORE_CTL

  # the token loop's crossings (rtl/jc_tok_top.vhd; hw/jc/link/jc_link_timing.tcl): aclk,
  # the Aurora user_clk, and init_clk (jc_gtg_clk's CLKOUT1), each found from a register
  # the tok RTL clocks; the Aurora IP's own XDC defines user_clk, jc_gtg_clk's MMCM init_clk.
  # Only the STRUCTURAL audit runs here. The bounds (jlk_cdc) are applied after the gtg ECO
  # and opt_design, below: jccard_loop2 (2026-11-11, MEASURED) applied them here, the ECO
  # re-derived the Aurora clocks as txoutclk_out[0]_1, every "-from user_clk" bound stopped
  # applying (17 crossings timed as synchronous, WNS -2.306) and report_exceptions died on
  # the dangling clock (Constraints 18-396).
  set clk_u [jlk_clock_of_pin "${CORE_TOK}rxf/wp_g_reg*/C"]
  set clk_i [jlk_clock_of_pin "${CORE_TOK}i_rpb_reg*/C"]
  set lk_bad [jlk_cdc_audit $CORE_TOK $aclk_clk $clk_u $clk_i]
  puts "JCCARD_LINK_CDC_UNEXPECTED $lk_bad"
  if {$lk_bad != 0} { error "link cdc audit: $lk_bad unexpected crossing(s)" }

  # the GTG MMCM's site and dedicated route (jc_card.xdc; finding 3): read back, because a
  # filter that matches nothing in an XDC is a CRITICAL WARNING, not a stop.
  set gm [get_cells -quiet -hierarchical -filter {NAME =~ "*gtgclk/*u_mmcm" && IS_PRIMITIVE == 1}]
  if {[llength $gm] != 1} { error "gtg mmcm: [llength $gm] cells match *gtgclk/*u_mmcm" }
  set gn [get_nets -of_objects [get_pins $gm/CLKIN1]]
  puts "JCCARD_GTG_MMCM $gm LOC=[get_property LOC $gm] CLKIN1_net=$gn CDR=[get_property CLOCK_DEDICATED_ROUTE $gn]"
  if {[get_property LOC $gm] ne "MMCM_X0Y2"} { error "gtg mmcm LOC [get_property LOC $gm], not MMCM_X0Y2" }
  if {[get_property CLOCK_DEDICATED_ROUTE $gn] ne "BACKBONE"} { error "gtg mmcm CLKIN1 net CLOCK_DEDICATED_ROUTE is not BACKBONE" }

  # CATTRIP -> compute_halt: RULED asynchronous (task-8 report concern 1; no 2-FF
  # synchroniser module exists for it, and adding one is outside this task's file
  # list), so it is constrained the way the loader's own hbm_cat_trip is: a quasi-
  # static level, false-pathed rather than timed against a meaningless edge
  # relationship. halt_or is the util_vector_logic OR cell gen_jc_card.py's I3 fix
  # added (fix round 1); its Res pin drives eng/compute_halt.
  #
  # Fix round 2026-10-07 (post-synth-audit.md WILL-FAIL 1, PASS-WRONGLY 3). The OR's
  # output is the bus pin Res[0] (C_SIZE 1), so `*halt_or*/Res` matched 0; a glob on
  # `*/halt_or/Res*` with DIRECTION == OUT matches 2 (Res[0] and the inner LUT's
  # Res[0]_INST_0/O). The output pins OF the hierarchical cell match exactly one.
  # MEASURED (jccard5 synth_1): the pin is not a startpoint, and `set_false_path -from`
  # on it is ERROR Constraints 18-513; the real paths through it start at the HBM APB
  # PCLK (clk_out1) and end in eng/card on aclk. So the exception is -through, and it
  # must be seen to land: every setup path through the pin must carry EXCEPTION
  # "False Path", and there must be at least one such path.
  set halt_cell [get_cells -quiet -hierarchical -filter {NAME =~ "*/jcc_i/halt_or" && IS_PRIMITIVE == 0}]
  if {[llength $halt_cell] != 1} { error "expected one halt_or cell, got [llength $halt_cell]" }
  set halt_src [get_pins -quiet -of_objects $halt_cell -filter {DIRECTION == OUT}]
  if {[llength $halt_src] != 1} { error "expected one halt_or output pin, got [llength $halt_src]" }
  set_false_path -through $halt_src
  set hp [get_timing_paths -quiet -setup -through $halt_src -max_paths 1000 -nworst 1]
  set h_fp 0; set h_other {}
  foreach p $hp {
    if {[get_property EXCEPTION $p] eq "False Path"} { incr h_fp } else { lappend h_other "[get_property ENDPOINT_PIN $p]:[get_property EXCEPTION $p]" }
  }
  puts "JCCARD_CATTRIP_PATHS through=[llength $hp] false_path=$h_fp other=[llength $h_other]"
  if {$h_fp == 0 || [llength $h_other] > 0} { error "halt_or false path did not land: false_path=$h_fp other={$h_other}" }
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

# the GTG refclk ECO (plan D11). The choice is READ FROM jc_card_bd.tcl's GENSTAMP
# (gen_jc_card.py stamps JC_LINK_REFCLK; unset = gtg), not from this process's environment:
# run_card.sh launches Vivado through systemd-run --user, which does not pass the caller's
# environment. A JC_LINK_REFCLK that does reach this process must agree with the stamp.
# gtg: the QPLL the core runs is moved to GTGREFCLK from jc_gtg_clk's 156.25 MHz BUFG. pin
# (no ECO, the QPLL on the IP's nominal AK38/AK39, which the Jungle Cat board does NOT drive)
# is refused here and in gen_jc_card.py (final ruling 2026-11-11): its link could never lock.
set _bdt [open $here/jc_card_bd.tcl]; set _bdtxt [read $_bdt]; close $_bdt
if {![regexp -line {^#\s+env\s+JC_LINK_REFCLK\s*=\s*(\S+)} $_bdtxt -> _stamped]} {
  jcc_fail "jc_card_bd.tcl carries no JC_LINK_REFCLK GENSTAMP line"
}
set _lr [expr {$_stamped eq "(unset)" ? "gtg" : $_stamped}]
if {$_lr ne "gtg"} { jcc_fail "jc_card_bd.tcl was generated with JC_LINK_REFCLK=$_stamped; only gtg is built (AK38/AK39 undriven)" }
if {[info exists ::env(JC_LINK_REFCLK)] && $::env(JC_LINK_REFCLK) ne "" && $::env(JC_LINK_REFCLK) ne $_lr} {
  jcc_fail "JC_LINK_REFCLK=$::env(JC_LINK_REFCLK) here, but jc_card_bd.tcl was generated with $_stamped"
}
puts "JCCARD_LINK_REFCLK $_lr (stamped $_stamped)"
if {$_lr eq "gtg"} {
  set _ac [get_cells -quiet -hierarchical -filter {NAME =~ "*/jcc_i/aur" && IS_PRIMITIVE == 0}]
  if {[llength $_ac] != 1} { jcc_fail "gtg eco: [llength $_ac] cells match */jcc_i/aur" }
  set _gp [get_pins -quiet -hierarchical -filter {NAME =~ "*gtgclk/*u_gbg/O"}]
  if {[llength $_gp] != 1} { jcc_fail "gtg eco: [llength $_gp] pins match *gtgclk/*u_gbg/O" }
  set ::JC_AUR_CELL [get_property NAME $_ac]
  set ::JC_GTG_PIN [get_property NAME $_gp]
  if {[catch {source $repo/hw/jc/link/eco_aurora_gtg.tcl} err]} { jcc_fail "gtg eco: $err" }
}
# -impl congestion (jccard7, 2026-10-08): 125 MHz placed at WNS +0.513 but routed at -8.833,
# 49k endpoints, one-LUT paths with ~16 ns of routing in u_arr and A's core: congestion
# detours, not logic depth. Spread placement and aggressive route/phys_opt for that case.
if {$impl eq "congestion"} {
  opt_design -directive ExploreWithRemap
} else {
  opt_design
}
jccard_bscan_check post_opt_design
# the link CDC bounds, HERE: after the gtg ECO has re-derived the Aurora clocks and after
# opt_design, with the clocks found again from the tok's own registers and the GT's TXOUTCLK
# pin, and every bound anchored to pins and cells (jlk_src), so no later re-derivation can
# orphan one. jlk_exc_audit refuses after route if they did not stay in force.
if {[catch {
  lassign [jlk_clocks $CORE_TOK] clk_u clk_i
  set lk_n [jlk_cdc $CORE_TOK $aclk_clk $clk_u $clk_i]
  puts "JCCARD_LINK_CDC_APPLIED post_opt_design bounds=$lk_n user=[get_property NAME $clk_u] init=[get_property NAME $clk_i]"
} err]} { jcc_fail "link constraints: $err" }
# cb_data / cb_addr (jccard_loop2 root cause 2, MEASURED): eng's codebook write command
# registers each drive all 1536 cbw_d/cbw_a copies in matvec_core (one register per copy,
# by design). Placement pressure from the link logic stretched cb_data_reg[3]'s net to an
# 8.5 ns route (0 logic levels, -0.847 ns; the same RTL met +0.109 on jccard10). Fixed
# card-side, not in the shared engine RTL: force-replicate the 12 drivers after placement
# so each replica sits near its share of the loads. Refuses unless replicas appear.
proc jcc_cbdata_repl {} {
  set flt {(NAME =~ "*/eng/inst/eng/cb_data_reg*" || NAME =~ "*/eng/inst/eng/cb_addr_reg*") && REF_NAME =~ FD*}
  set regs [get_cells -quiet -hierarchical -filter $flt]
  set orig {}
  foreach c $regs { if {[string first "_replica" [get_property NAME $c]] < 0} { lappend orig $c } }
  if {[llength $orig] != 12} { jcc_fail "cb_data replication: [llength $orig] cb_data/cb_addr registers, expected 12 (8 + 4)" }
  set nets [get_nets -of_objects [get_pins -of_objects $orig -filter {REF_PIN_NAME == Q}]]
  set loads {}
  foreach n $nets { lappend loads [llength [get_pins -leaf -of_objects $n -filter {DIRECTION == IN}]] }
  set lmin [tcl::mathfunc::min {*}$loads]
  set before [llength $regs]
  phys_opt_design -force_replication_on_nets $nets
  set after [llength [get_cells -quiet -hierarchical -filter $flt]]
  if {$after <= $before} { jcc_fail "cb_data replication: no replica created (drivers $before -> $after)" }
  puts "JCCARD_CBDATA_REPL nets=[llength $nets] loads=$lmin..[tcl::mathfunc::max {*}$loads] drivers=$before->$after"
}
# one GT channel, at the measured lane's site (spec 1b.2: die 0 X0Y0 TX -> die 1 X0Y0 RX),
# checked right after placement, before routing is paid for
proc jcc_gt_loc_check {} {
  set gts [get_cells -hierarchical -filter {REF_NAME == GTYE4_CHANNEL}]
  if {[llength $gts] != 1 || [get_property LOC $gts] ne "GTYE4_CHANNEL_X0Y0"} {
    jcc_fail "GT placement: [llength $gts] channel(s) at [get_property LOC $gts], want one at GTYE4_CHANNEL_X0Y0"
  }
  puts "JCCARD_GT_LOC [get_property LOC $gts]"
}
if {$impl eq "congestion"} {
  place_design -directive AltSpreadLogic_high
  jcc_gt_loc_check
  jcc_cbdata_repl
  phys_opt_design -directive AggressiveExplore
  route_design -directive AggressiveExplore
} else {
  place_design
  jcc_gt_loc_check
  jcc_cbdata_repl
  phys_opt_design
  route_design
}
set post_wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "JCCARD_POST_ROUTE_WNS $post_wns"
if {$impl eq "congestion" && $post_wns < 0} {
  phys_opt_design -directive AggressiveExplore
  puts "JCCARD_POST_ROUTE_PHYSOPT_WNS [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]"
}
write_checkpoint -force $bd/jc_card_routed.dcp
# the link bounds must still be in force on the routed design (written first, so a refusal
# leaves the checkpoint to read): every path user_clk/init_clk <-> aclk under a datapath-only
# max delay, and no "(unsafe)" clock-interaction row between them.
if {[catch {
  lassign [jlk_clocks $CORE_TOK] clk_u clk_i
  set lk_exc [jlk_exc_audit $aclk_clk $clk_u $clk_i]
} err]} { jcc_fail "link exception audit: $err" }
puts "JCCARD_LINK_EXC_AUDIT bad=$lk_exc"
if {$lk_exc != 0} { jcc_fail "link cdc bounds not in force after route: $lk_exc failure(s) (JCLINK_EXC_* lines)" }

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
# a constraint left naming an object that no longer exists makes report_exceptions an ERROR
# (jccard_loop2: Constraints 18-396, the pre-ECO "-from user_clk" bounds): a refusal, by name
if {[catch {
  report_exceptions -file $rp/exceptions.rpt
  report_exceptions -ignored -file $rp/exceptions_ignored.rpt
} err]} { jcc_fail "report_exceptions: $err" }
report_bus_skew -file $rp/bus_skew.rpt
report_methodology -file $rp/methodology.rpt
report_drc -file $rp/drc.rpt
report_pulse_width -all -file $rp/pulse_width.rpt
check_timing -file $rp/check_timing.rpt

# report_bus_skew (fix round 2026-10-07, post-synth-audit.md PASS-WRONGLY 4): the gray
# pointers' set_bus_skew (jcl_cdc, jctl_cdc) and the jtag_axi/dbg_hub XPM FIFOs are not
# timing paths, so the WNS gate below never sees them. Every constraint row of the
# summary must parse and none may have negative slack. Floor 4: the loader's two gray
# buses and the ctl's two (jcl_cdc/jctl_cdc each call set_bus_skew twice).
# A constraint with no paths ("NA") is refused too: it checks nothing.
lassign [jccard_bus_skew_parse [report_bus_skew -return_string]] bs_ids bs_rows bs_neg bs_worst bs_na
puts "JCCARD_BUS_SKEW constraints=$bs_ids rows=$bs_rows violated=$bs_neg worst=$bs_worst no_paths=$bs_na"
if {$bs_ids < 4 || $bs_rows != $bs_ids || $bs_neg > 0} {
  jcc_fail "bus skew: constraints=$bs_ids rows=$bs_rows violated=$bs_neg worst=$bs_worst no_paths=$bs_na"
}

# report_cdc's own severity classification (fix round 2026-10-07, post-synth-audit.md
# PASS-WRONGLY 6): a Critical row is allowed ONLY when its DESTINATION is the first stage
# of a named synchroniser (the loader's, the ctl's and the tok's, anchored on their own
# hierarchy) AND its rule is not one refused everywhere (CDC-10; see jccard_cdc_scan).
# The previous scan whitelisted a line when a known name appeared anywhere in it, so a
# Critical crossing FROM a synchroniser register TO an unsynchronised one passed on its
# Source column (masked in practice: the report's own summary row `CDC-1 Critical <n>`
# names no synchroniser, so that scan refused every Critical crossing, even the named
# ones). The Critical rows parsed must also add up to the count the report's own
# summary table states, so a row the parse missed is a refusal, not a pass
# (jccard_cdc_scan in jccard_post.tcl, tested against the loader's real cdc.rpt).
set fh [open $rp/cdc.rpt]; set cdc_txt [read $fh]; close $fh
set CDC_DST_OK {}
foreach sy {sync/st_r_reg sync/tgl_s1_reg sync/ack_s1_reg fifo/wp_g_s1_reg fifo/rp_g_s1_reg
           trst_s1_reg trip_s1_reg dnar/} { lappend CDC_DST_OK "${CORE_LOADER}${sy}*" }
foreach sy {sync/st_r_reg sync/tgl_s1_reg sync/ack_s1_reg rak_s1_reg fifo/wp_g_s1_reg
           fifo/rp_g_s1_reg rram_reg} { lappend CDC_DST_OK "${CORE_CTL}${sy}*" }
# the token loop's synchroniser first stages (rtl/jc_tok_top.vhd, the list jlk_cdc_audit
# names; 2026-11-11), anchored on the tok hierarchy so a crossing into one of them is
# reported BY NAME. Naming one does not make every Critical at it pass: jccard_cdc_scan
# refuses a CDC-10 (combinational logic before the synchroniser) wherever it lands.
foreach sy {s_tx_reg s_rx_reg s_pll_reg s_gtg_reg s_ovf_reg u_rst_s_reg u_pol_reg
           i_rpb_reg i_pma_reg i_lck_reg txf/wp_g_s1_reg txf/rp_g_s1_reg txf/clr_r_s1_reg
           txf/clr_a_s1_reg rxf/wp_g_s1_reg rxf/rp_g_s1_reg rxf/clr_r_s1_reg
           rxf/clr_a_s1_reg} { lappend CDC_DST_OK "${CORE_TOK}${sy}*" }
lassign [jccard_cdc_scan $cdc_txt $CDC_DST_OK] crit_sum crit_rows crit_unknown crit_named
foreach l $crit_unknown { puts "JCCARD_CDC_REPORT_UNKNOWN $l" }
set crit_bad [llength $crit_unknown]
set crit_nref 0
foreach n $crit_named {
  lassign $n v id pat row
  if {$v eq "refused"} { incr crit_nref }
  puts "JCCARD_CDC_REPORT_NAMED [string toupper $v] $id at $pat: $row"
}
puts "JCCARD_CDC_REPORT_CRITICAL summary=$crit_sum rows=$crit_rows unknown=$crit_bad named=[llength $crit_named] named_refused=$crit_nref"
if {$crit_rows != $crit_sum} { jcc_fail "report_cdc: summary states $crit_sum critical, $crit_rows detail rows parsed" }
if {$crit_bad > 0} { jcc_fail "report_cdc: $crit_bad critical crossing(s) whose destination is not a named synchroniser" }
if {$crit_nref > 0} { jcc_fail "report_cdc: $crit_nref critical crossing(s) at a named synchroniser of a refused kind (JCCARD_CDC_REPORT_NAMED REFUSED)" }

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
