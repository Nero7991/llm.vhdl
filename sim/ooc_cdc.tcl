# sim/ooc_cdc.tcl -- STATIC clock-domain-crossing analysis for the weight
# path's CDC, out of context.
#
# WHY THIS EXISTS.  docs/debugging/2026-08-29_cdc-and-fifo-coverage.md closed
# rtl/async_fifo.vhd and rtl/axi_rd_fsm.vhd with a functional bench and a
# 33-row mutation table each, and then stated the exact limit of what any
# simulation can reach:
#
#   > No functional bench can test the gray coding.  G1 replaces BOTH bin2gray
#   > and gray2bin with the identity -- binary pointers straight across the CDC
#   > -- and survives every one of the eight clock ratios. ... Closing these
#   > needs Vivado report_cdc, ASYNC_REG and asynchronous clock groups -- not
#   > simulation.
#
# This script is that flow.  It synthesises out of context, declares the two
# clocks asynchronous, and runs report_cdc / report_clock_interaction, plus an
# ASYNC_REG census taken from the NETLIST rather than from the source, because
# an attribute that synthesis did not apply is indistinguishable from one that
# was never written.
#
# PATTERN.  Follows sim/ooc_fk33_a.tcl, which is the established OOC script for
# these units, and keeps its three rules: constrain BEFORE synth_design; parse
# report_utilization rather than get_cells -filter PRIMITIVE_TYPE; cap threads.
# Two things are added that it does not have:
#
#   * `rtldir` is an ARGUMENT.  Every mutation in the teeth table is applied to
#     a COPY of rtl/ in a scratch directory and this script is pointed at it.
#     Nothing under rtl/ is ever edited.
#   * `groups` selects whether set_clock_groups -asynchronous is emitted at
#     all.  groups=0 is not a configuration anyone would build -- it is the
#     measurement that answers "would this flow report nothing and look clean".
#
# USAGE
#   vivado -mode batch -source sim/ooc_cdc.tcl -tclargs <unit> [k=v ...]
#
#   unit     async_fifo | axi_rd_port
#   rtldir   directory holding the .vhd sources     (default ../rtl)
#   outdir   directory for the reports              (default sim/ooc_cdc)
#   tag      report filename stem                   (default = unit)
#   groups   1 = emit set_clock_groups -asynchronous, 0 = do not  (default 1)
#   iodelay  1 = constrain every non-clock port so port-to-register and
#            register-to-port crossings are analysable too  (default 0)
#   dual     0|1 DUAL_CLK, axi_rd_port only         (default 1)
#   depth    FIFO depth in beats                    (default 512)
#   axidw    data width                             (default 256)
#   period   core clock period ns                   (default 3.3)
#   aperiod  AXI clock period ns                    (default 3.333)
#   part     (default xcvu33p-fsvh2104-2L-e)
#
# WHAT AN OOC report_cdc IS AND IS NOT.  report_cdc is STRUCTURAL: it walks the
# netlist between clock domains and classifies what it finds against a fixed
# rule set.  It does not simulate and it does not need placement, so an OOC
# netlist answers it exactly as a placed one would for the rules that concern
# synchroniser topology.  It says nothing about routing, and it does not know
# what a gray code is -- see the write-up for what that costs.

set unit [lindex $argv 0]
if {$unit eq ""} { error "usage: -tclargs <unit> \[k=v ...\]" }

set here [file normalize [file dirname [info script]]]

array set o {
  part    xcvu33p-fsvh2104-2L-e
  period  3.3
  aperiod 3.333
  dual    1
  depth   512
  axidw   256
  addrw   40
  maxb    16
  maxout  16
  groups  1
  iodelay 0
  rtldir  ""
  outdir  ""
  tag     ""
}
foreach a [lrange $argv 1 end] {
  if {![regexp {^([a-z]+)=(.*)$} $a -> k v]} { error "bad arg '$a'" }
  if {![info exists o($k)]} { error "unknown key '$k'" }
  set o($k) $v
}
if {$o(rtldir) eq ""} { set o(rtldir) [file normalize [file join $here ../rtl]] }
if {$o(outdir) eq ""} { set o(outdir) [file normalize [file join $here ooc_cdc]] }
if {$o(tag)    eq ""} { set o(tag)    $unit }
file mkdir $o(outdir)

# See sim/ooc_fk33_a.tcl: a VHDL boolean generic must be the literal
# true/false, not 0/1, or elaboration fails with a width mismatch pointing at
# the generic's own declaration line.
set DUALV [expr {$o(dual) ? "true" : "false"}]

# The 2026-07-04 systemd-oomd incident.  Seven other agents are on this box.
set_param general.maxThreads 4

switch -- $unit {
  async_fifo {
    set files {util_pkg.vhd async_fifo.vhd}
    set top   async_fifo
    set clks  {wclk rclk}
  }
  axi_rd_port {
    set files {util_pkg.vhd stream_fifo.vhd async_fifo.vhd axi_rd_fsm.vhd axi_rd_port.vhd}
    set top   axi_rd_port
    set clks  {clk aclk}
  }
  default { error "unknown unit '$unit'" }
}

create_project -in_memory -part $o(part)
foreach f $files { read_vhdl -vhdl2008 [file join $o(rtldir) $f] }

lassign $clks CK_CORE CK_AXI
set xdc [file join $o(outdir) clk_$o(tag).xdc]
set fh [open $xdc w]
puts $fh "create_clock -name coreclk -period $o(period) \[get_ports $CK_CORE\]"
puts $fh "create_clock -name axiclk  -period $o(aperiod) \[get_ports $CK_AXI\]"
if {$o(groups)} {
  puts $fh "set_clock_groups -asynchronous -group \[get_clocks coreclk\] -group \[get_clocks axiclk\]"
}
# IO DELAYS.  report_cdc says so itself, in an INFO on every run: "Ports with
# no input delay constraint are skipped."  Out of context, a crossing whose
# SOURCE is an input port (the `rst` synchroniser) or whose DESTINATION is an
# output port (the `run_f`-gated `q_valid`) is not a register-to-register path,
# and the report is silent about it.  MEASURED 2026-08-29: mutations PA, PB and
# PF are invisible without this, and PA/PB/PF are exactly those two shapes.
# iodelay=1 constrains every non-clock port against the clock its domain
# belongs to, which is what makes those paths analysable.
if {$o(iodelay)} {
  if {$unit eq "axi_rd_port"} {
    puts $fh "set_input_delay  -clock coreclk 0.100 \[get_ports {rst start base\[*\] n_beats\[*\] q_ready}\]"
    puts $fh "set_input_delay  -clock axiclk  0.100 \[get_ports {arready rvalid rdata\[*\] rlast}\]"
    puts $fh "set_output_delay -clock coreclk 0.100 \[get_ports {q_valid q_data\[*\]}\]"
    puts $fh "set_output_delay -clock axiclk  0.100 \[get_ports {arvalid araddr\[*\] arlen\[*\] arsize\[*\] arburst\[*\] rready}\]"
  } else {
    puts $fh "set_input_delay  -clock coreclk 0.100 \[get_ports {wrst w_valid w_data\[*\] clr}\]"
    puts $fh "set_input_delay  -clock axiclk  0.100 \[get_ports {rrst q_ready}\]"
    puts $fh "set_output_delay -clock coreclk 0.100 \[get_ports {w_ready w_level\[*\] clr_done}\]"
    puts $fh "set_output_delay -clock axiclk  0.100 \[get_ports {q_valid q_data\[*\]}\]"
  }
}
close $fh
read_xdc -mode out_of_context $xdc

# PROVE THE XDC WAS APPLIED.  Vivado's XDC reader skips a block it dislikes
# with only a CRITICAL WARNING, and a silently skipped constraint looks exactly
# like a constraint that did not help.  This prints what the design actually
# holds, after the read, so the log carries the evidence rather than the intent.
puts "CDC_XDC_FILE $xdc"
puts "CDC_XDC_CONTENT_BEGIN"
set fh [open $xdc r]; puts -nonewline [read $fh]; close $fh
puts "CDC_XDC_CONTENT_END"

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
}
synth_design {*}$ga

# ---------------------------------------------------------------- clocks seen
# The trap this line exists for: report_cdc on a design where the clocks were
# never created, or where they were created but ended up related, reports
# NOTHING and reads as clean.  Print what the design believes before believing
# any report.
puts "CDC_CLOCKS_BEGIN"
foreach c [get_clocks] {
  puts [format "  clock %-10s period %s  sources %s" \
        $c [get_property PERIOD $c] [get_property SOURCE_PINS $c]]
}
puts "CDC_CLOCKS_END"
# PROOF THAT THE CLOCK GROUP TOOK EFFECT, measured rather than asserted.
# Vivado 2023.2 has no `get_clock_groups` command (MEASURED: "invalid command
# name"), so the constraint cannot be read back directly.  What CAN be read
# back is its consequence: with the two clocks in asynchronous groups the timer
# has no cross-clock path to report, and without it every CDC register pair is
# a timed path.  0 here means the constraint is live; nonzero means it is not.
set xpaths [get_timing_paths -quiet -max_paths 1 \
              -from [get_clocks coreclk] -to [get_clocks axiclk]]
set ypaths [get_timing_paths -quiet -max_paths 1 \
              -from [get_clocks axiclk] -to [get_clocks coreclk]]
puts "CDC_XCLK_TIMED_PATHS_CORE_TO_AXI [llength $xpaths]"
puts "CDC_XCLK_TIMED_PATHS_AXI_TO_CORE [llength $ypaths]"

# ------------------------------------------------------------ ASYNC_REG census
# Taken from the NETLIST, not from the source.  A comment claiming a
# synchroniser and a synthesised flop carrying ASYNC_REG=TRUE are different
# facts, and only the second one constrains the placer.
set allff  [get_cells -quiet -hier -filter {IS_SEQUENTIAL}]
set arff   [get_cells -quiet -hier -filter {IS_SEQUENTIAL && ASYNC_REG}]
puts "CDC_ASYNC_REG_TOTAL_SEQ [llength $allff]"
puts "CDC_ASYNC_REG_TRUE [llength $arff]"
if {[llength $arff] > 0} {
  puts "CDC_ASYNC_REG_CELLS_BEGIN"
  foreach c $arff { puts "  $c" }
  puts "CDC_ASYNC_REG_CELLS_END"
}

# Did the synchroniser chains survive as flops at all, or did shift-register
# extraction turn one into an SRL?  An SRL cannot be a synchroniser: it is one
# LUT, the intermediate stages are not flops, and ASYNC_REG cannot be applied.
set srls [get_cells -quiet -hier -filter {REF_NAME =~ SRL*}]
puts "CDC_SRL_COUNT [llength $srls]"
foreach c $srls { puts "  SRL $c" }

# ------------------------------------------------------------------- the reports
set cdcrpt [file join $o(outdir) cdc_$o(tag).rpt]
report_cdc -details -file $cdcrpt
report_clock_interaction -delay_type min_max \
  -file [file join $o(outdir) clkint_$o(tag).rpt]
report_utilization -file [file join $o(outdir) util_$o(tag).rpt]

# report_cdc's own summary, echoed into the run log so the log alone is
# evidence.  -return_string keeps it out of a second file.
puts "CDC_SUMMARY_BEGIN"
puts [report_cdc -return_string]
puts "CDC_SUMMARY_END"

puts "OOC_CDC_DONE $unit tag=$o(tag) groups=$o(groups) dual=$o(dual)"
