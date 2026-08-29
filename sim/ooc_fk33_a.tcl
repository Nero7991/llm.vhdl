# OOC synthesis + timing for subsystem A at the FK33 geometry.
#
#   ROWS_IF=48, AXI_DW=256, NPORTS_W=24, NPORTS_S=3  ->  27 AXI read masters
#   (+ a 28th for the descriptor inside matvec_int4_desc_axi), MAXB=16 (AXI3),
#   MAXOUT=16, DUAL_CLK selectable, ADDR_W=40.
#
# WHY THIS EXISTS.  Every subsystem-A track on 2026-08-28 ended its report with
# "no synthesis, no timing, resource numbers are estimates".  The claims left
# standing on estimate were: a 6144-bit w_data net; 27-28 masters' worth of AR
# logic; MAXOUT 2->16 costing "~3 FF per port x 27 ports"; DEPTH=256 beats at
# 256 bits being 8 KB per port and therefore a BRAM question; and the target
# clock, where the whole HBM supply figure of 259.2 GB/s assumes 300 MHz on the
# strength of a 30-port hbm_tg design that closed at +0.101 ns WITH NO ENGINE
# IN IT.  This script measures each of those.
#
# PATTERN.  Follows sim/ooc_core_sweep.tcl, which is the established one here,
# and specifically its three hard-won rules:
#   * constrain BEFORE synth_design, not after -- ooc_matvec_int4.tcl creates
#     the clock afterwards and so reports a number against a design that was
#     optimised unconstrained.  Here the period IS the question.
#   * parse report_utilization, never get_cells -filter PRIMITIVE_TYPE, which
#     is not reliably set on an unplaced netlist and returns plausible-looking
#     wrong numbers.  Note the \*? in the LUT pattern: OOC synthesis emits
#     "CLB LUTs*" with a trailing asterisk.
#   * apply the voltage derate AFTER synthesis, so the reported number is the
#     pure derate of one netlist rather than two differently-optimised ones.
#     The FK33 runs at 0.717 V by hand (docs/debugging/2026-08-24_fk33-sysmon-
#     vccint-undervolt.md), not the 0.85 V Vivado analyses by default.
#
# USAGE
#   vivado -mode batch -source sim/ooc_fk33_a.tcl -tclargs <unit> [k=v ...]
#
#   unit    async_fifo | axi_rd_port | matvec_int4 | matvec_int4_desc_axi
#   period  core clock period ns          (default 3.3  -> 303.0 MHz)
#   aperiod AXI clock period ns           (default 3.333 -> 300.0 MHz)
#   volt    VCCINT for the timing derate  (default 0.717; -1 = part default)
#   dual    0|1, DUAL_CLK                 (default 1)
#   depth   per-port FIFO depth in beats  (default 512)
#   maxout  bursts in flight per port     (default 16)
#   part    (default xcvu33p-fsvh2104-2L-e)
#
# NOTE ON WHAT AN OOC NUMBER IS.  Out of context means no I/O buffers, no
# board pinout, no other subsystem competing for the same fabric, and no
# placement or routing at all -- synth_design's timing is an estimate that
# routing usually makes worse, not better.  These numbers bound the design's
# own logic depth and its own area.  They do NOT predict the final build.

set unit [lindex $argv 0]
if {$unit eq ""} { error "usage: -tclargs <unit> \[k=v ...\]" }

array set o {
  part    xcvu33p-fsvh2104-2L-e
  period  3.3
  aperiod 3.333
  volt    0.717
  dual    1
  depth   512
  maxout  16
  rows    48
  npw     24
  nps     3
  axidw   256
  addrw   40
  maxb    16
  maxcols 17408
  maxrows 17408
}
foreach a [lrange $argv 1 end] {
  if {![regexp {^([a-z]+)=(.+)$} $a -> k v]} { error "bad arg '$a'" }
  if {![info exists o($k)]} { error "unknown key '$k'" }
  set o($k) $v
}

# VHDL `boolean` generics are NOT 0/1 to Vivado.  `-generic DUAL_CLK=1` fails
# elaboration with "width mismatch in assignment; target has 1 bits, source has
# 32 bits" pointing at the generic's own declaration line, which reads like an
# RTL defect and is not one: the tool hands a 32-bit integer to a 1-bit boolean.
# It must be the literal true/false.  Keep the CSV column numeric.
set DUALV [expr {$o(dual) ? "true" : "false"}]

# The 2026-07-04 systemd-oomd incident took down unrelated services when a
# Vivado run ballooned on this 31 GB box.  4 threads is what every other OOC
# script here caps at and it costs nothing on a single synth_design.
set_param general.maxThreads 4

set here   [file normalize [file dirname [info script]]]
set rtldir [file normalize [file join $here ../rtl]]
set outdir [file normalize [file join $here ooc_fk33a]]
file mkdir $outdir

# --------------------------------------------------------------- source sets
# Listed explicitly rather than globbed: a glob would pull in whichever
# half-edited file another track has open, and three tracks are editing rtl/
# today.  Run this against a `git worktree add --detach <path> HEAD` tree.
set common {util_pkg.vhd}
switch -- $unit {
  async_fifo {
    set files [concat $common {async_fifo.vhd}]
    set top   async_fifo
    set clks  {wclk rclk}
  }
  axi_rd_port {
    set files [concat $common {stream_fifo.vhd async_fifo.vhd axi_rd_fsm.vhd axi_rd_port.vhd}]
    set top   axi_rd_port
    set clks  {clk aclk}
  }
  matvec_int4 {
    set files [concat $common {mv4i_arith_pkg.vhd stream_fifo.vhd async_fifo.vhd \
                               axi_rd_fsm.vhd axi_rd_port.vhd weight_streamer.vhd \
                               act_mem_striped.vhd matvec_core.vhd matvec_int4.vhd}]
    set top   matvec_int4
    set clks  {clk aclk}
  }
  matvec_int4_desc_axi {
    set files [concat $common {mv4i_arith_pkg.vhd matvec_int4_desc_pkg.vhd \
                               stream_fifo.vhd async_fifo.vhd \
                               axi_rd_fsm.vhd axi_rd_port.vhd weight_streamer.vhd \
                               act_mem_striped.vhd matvec_core.vhd matvec_int4.vhd \
                               matvec_int4_desc_axi.vhd}]
    set top   matvec_int4_desc_axi
    set clks  {s_axi_aclk m_aclk}
  }
  default { error "unknown unit '$unit'" }
}

create_project -in_memory -part $o(part)
foreach f $files { read_vhdl -vhdl2008 [file join $rtldir $f] }

# ------------------------------------------------------------------- clocks
# Two clocks, always created, even when DUAL_CLK=0 -- in the single-clock case
# the second port is tied off inside the RTL and the clock simply has no
# fanout, which is visible in the report rather than silently absent.
# They are declared asynchronous because that is what they physically are: the
# HBM SAXI fabric clock and the core clock come from different MMCM outputs.
# Without the clock group, synth_design times every CDC path as a real
# cross-clock path and reports a WNS that belongs to a design nobody built.
lassign $clks CK_CORE CK_AXI
set tag "${unit}_p$o(period)_a$o(aperiod)_d$o(dual)_v$o(volt)_m$o(maxout)_D$o(depth)"
set xdc [file join $outdir clk_${tag}.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name coreclk -period $o(period) \[get_ports $CK_CORE\]"
puts $fh "create_clock -name axiclk  -period $o(aperiod) \[get_ports $CK_AXI\]"
puts $fh "set_clock_groups -asynchronous -group \[get_clocks coreclk\] -group \[get_clocks axiclk\]"
close $fh
read_xdc -mode out_of_context $xdc

# -------------------------------------------------------------------- synth
set ga [list -mode out_of_context -top $top -part $o(part)]
switch -- $unit {
  async_fifo {
    lappend ga -generic W=$o(axidw) -generic DEPTH=$o(depth)
  }
  axi_rd_port {
    lappend ga -generic AXI_DW=$o(axidw) -generic ADDR_W=$o(addrw) \
               -generic DEPTH=$o(depth) -generic MAXB=$o(maxb) \
               -generic MAXOUT=$o(maxout) -generic DUAL_CLK=$DUALV
  }
  matvec_int4 - matvec_int4_desc_axi {
    lappend ga -generic BLK=32 -generic ROWS_IF=$o(rows) \
               -generic NPORTS_W=$o(npw) -generic NPORTS_S=$o(nps) \
               -generic AXI_DW=$o(axidw) -generic ADDR_W=$o(addrw) \
               -generic MAXCOLS=$o(maxcols) -generic MAXROWS_BFP=$o(maxrows) \
               -generic FIFO_DEPTH=$o(depth) -generic MAXB=$o(maxb) \
               -generic MAXOUT=$o(maxout) -generic DUAL_CLK=$DUALV
  }
}
synth_design {*}$ga

if {$o(volt) > 0} {
  set_operating_conditions -voltage [list VCCINT $o(volt)]
  puts "  operating conditions: VCCINT = $o(volt) V"
}

set rpt [file join $outdir util_${tag}.rpt]
report_utilization -file $rpt
report_utilization -hierarchical -hierarchical_depth 3 \
  -file [file join $outdir hier_${tag}.rpt]
report_timing_summary -delay_type max -max_paths 10 \
  -file [file join $outdir timing_${tag}.rpt]

# --------------------------------------------------------------- parse + CSV
set dsp 0; set lut 0; set ff 0; set bram 0.0; set uram 0; set lutram 0
set fh [open $rpt r]
foreach line [split [read $fh] \n] {
  if {[regexp {^\| DSPs\s+\|\s+([0-9]+)} $line -> v]}            { set dsp $v }
  if {[regexp {^\| CLB LUTs\*?\s+\|\s+([0-9]+)} $line -> v]}     { set lut $v }
  if {[regexp {^\| CLB Registers\s+\|\s+([0-9]+)} $line -> v]}   { set ff $v }
  if {[regexp {^\| Block RAM Tile\s+\|\s+([0-9.]+)} $line -> v]} { set bram $v }
  if {[regexp {^\| URAM\s+\|\s+([0-9]+)} $line -> v]}            { set uram $v }
  if {[regexp {^\|   LUT as Memory\s+\|\s+([0-9]+)} $line -> v]} { set lutram $v }
}
close $fh

# Per-clock WNS.  The overall figure alone cannot answer the question this run
# was launched for, which is specifically "does the CORE close at 236 MHz and
# does the AXI side close at 300 MHz", two different clocks with two different
# answers.
proc wns_of {args} {
  set p [get_timing_paths -delay_type max -max_paths 1 {*}$args]
  if {[llength $p] == 0} { return "" }
  return [get_property SLACK $p]
}
set w_all  [wns_of]
set w_core [wns_of -from [get_clocks coreclk] -to [get_clocks coreclk]]
set w_axi  [wns_of -from [get_clocks axiclk]  -to [get_clocks axiclk]]

proc fmax {period wns} {
  if {$wns eq ""} { return "" }
  return [format "%.2f" [expr {1000.0 / ($period - $wns)}]]
}
set f_core [fmax $o(period)  $w_core]
set f_axi  [fmax $o(aperiod) $w_axi]

set csvpath [file join $outdir results.csv]
set fresh [expr {![file exists $csvpath] || [file size $csvpath] == 0}]
set csv [open $csvpath a]
if {$fresh} {
  puts $csv "unit,part,dual,period_ns,aperiod_ns,volt,depth,maxout,rows_if,npw,nps,axi_dw,lut,lutram,ff,dsp,bram,uram,wns_all,wns_core,fmax_core_mhz,wns_axi,fmax_axi_mhz"
}
puts $csv "$unit,$o(part),$o(dual),$o(period),$o(aperiod),$o(volt),$o(depth),$o(maxout),$o(rows),$o(npw),$o(nps),$o(axidw),$lut,$lutram,$ff,$dsp,$bram,$uram,$w_all,$w_core,$f_core,$w_axi,$f_axi"
close $csv

puts "==== $unit @ $o(part)  DUAL_CLK=$o(dual) ===="
puts [format "LUT=%s (LUTRAM %s)  FF=%s  DSP=%s  BRAM36=%s  URAM=%s" \
      $lut $lutram $ff $dsp $bram $uram]
puts [format "WNS all=%s | core %s ns -> %s ns slack, Fmax %s MHz | axi %s ns -> %s ns slack, Fmax %s MHz" \
      $w_all $o(period) $w_core $f_core $o(aperiod) $w_axi $f_axi]
report_timing -delay_type max -max_paths 3
puts "OOC_FK33A_DONE $unit"
