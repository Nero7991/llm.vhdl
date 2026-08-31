# TRACK LEVERC48.  Does CB_STYLE reach matvec_core THROUGH THE WRAPPERS in
# SYNTHESIS, not just in simulation?
#
# THE GAP THIS CLOSES.  TRACK CBINFER established that Vivado infers LUTRAM
# from `cb` and accepts an attribute value that is a constant returned by a
# function of a generic -- but it did that with CB_STYLE as the DEFAULT on the
# TOP entity, by editing whole copies of matvec_core.vhd.  Lever C is only
# usable from a board top if the string travels the other way: given on the
# synth_design command line at matvec_int4, propagated down a port map into
# matvec_core, and STILL evaluated by the attribute functions there.
#
# Vivado's constant propagation of a STRING generic across a hierarchy boundary
# is not the same mechanism as reading a default, and it is exactly the sort of
# thing that fails silently: a generic that does not arrive leaves CB_STYLE at
# "regs", which is legal, builds the shipping design, and reports success.  The
# GHDL announcement in matvec_core catches that at simulation time; nothing
# catches it at synthesis time except this measurement.
#
# WHAT MAKES THE ANSWER UNAMBIGUOUS.  Not the LUT total, which moves for many
# reasons, but the OBJECT-LEVEL census of cells carrying cb's name:
#
#   arrived and honoured   ->  cb_reg* RAM cells > 0,  cb_reg* FF cells = 0
#   did not arrive         ->  cb_reg* RAM cells = 0,  cb_reg* FF cells > 0
#
# and MUXF7/MUXF8 going to zero beside it.  A design that reports 8 LUTRAM per
# lane and no muxes did not get there by accident.
#
# USAGE
#   vivado -mode batch -source sim/ooc_leverc48_thread.tcl -tclargs <tag> [k=v]
#
#   tag      CSV row name and report filename
#   style    CB_STYLE passed to matvec_int4   (default regs)
#   rows     ROWS_IF                          (default 48, the FK33 shape)
#   blk      BLK                              (default 32)
#   npw      NPORTS_W                         (default 24)
#   nps      NPORTS_S                         (default 3)
#   dw       AXI_DW                           (default 256)
#   addrw    ADDR_W                           (default 40)
#   period   clock period ns                  (default 5.0, the 200 MHz build)
#   part     (default xcvu33p-fsvh2104-2L-e, the FK33 part)
#   outdir   (default sim/ooc_leverc48_thread)
#
# NOT HARDWARE.  synth_design and report_* only.  And an OOC synthesis number
# is not a placed one: lever C's claim is about CLB PACKING, which only
# place_design measures.  Nothing here is a fit verdict.

set tag [lindex $argv 0]
if {$tag eq ""} { error "usage: -tclargs <tag> \[k=v ...\]" }

array set o {
  part   xcvu33p-fsvh2104-2L-e
  style  regs
  rows   48
  blk    32
  npw    24
  nps    3
  dw     256
  addrw  40
  period 5.0
  outdir ""
}
foreach a [lrange $argv 1 end] {
  if {![regexp {^([a-z]+)=(.+)$} $a -> k v]} { error "bad arg '$a'" }
  if {![info exists o($k)]} { error "unknown key '$k'" }
  set o($k) $v
}

set here [file normalize [file dirname [info script]]]
set rtldir [file normalize [file join $here ../rtl]]
if {$o(outdir) eq ""} { set o(outdir) [file join $here ooc_leverc48_thread] }
set outdir [file normalize $o(outdir)]
file mkdir $outdir

# ONE VIVADO PER BOX, and 4 threads is what every other OOC script here caps at.
set_param general.maxThreads 4

create_project -in_memory -part $o(part)
# The list sim/ooc_matvec_int4.tcl carries is STALE: it omits async_fifo.vhd and
# axi_rd_fsm.vhd, and a run built from it dies at elaboration with
# "[Synth 8-5826] no such design unit 'axi_rd_fsm'".  Taken from the actual
# `entity work.*` references in the four files below rather than copied.
foreach f {util_pkg.vhd mv4i_arith_pkg.vhd stream_fifo.vhd async_fifo.vhd
           axi_rd_fsm.vhd axi_rd_port.vhd weight_streamer.vhd
           act_mem_striped.vhd matvec_core.vhd matvec_int4.vhd} {
  read_vhdl -vhdl2008 [file join $rtldir $f]
}

# Constrain BEFORE synth_design.  ooc_matvec_int4.tcl creates its clock
# afterwards and so reports against a design optimised unconstrained; both
# ooc_core_sweep.tcl and ooc_fk33_a.tcl record that as a trap.
set xdc [file join $outdir clk_${tag}.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $o(period) \[get_ports clk\]"
close $fh
read_xdc -mode out_of_context $xdc

synth_design -mode out_of_context -top matvec_int4 -part $o(part) \
  -generic BLK=$o(blk) -generic ROWS_IF=$o(rows) \
  -generic NPORTS_W=$o(npw) -generic NPORTS_S=$o(nps) \
  -generic AXI_DW=$o(dw) -generic ADDR_W=$o(addrw) \
  -generic MAXCOLS=17408 -generic MAXROWS_BFP=17408 \
  -generic MAXB=16 -generic MAXOUT=16 \
  -generic CB_STYLE=$o(style)

set rpt [file join $outdir util_${tag}.rpt]
report_utilization -file $rpt
report_timing_summary -delay_type max -max_paths 5 \
  -file [file join $outdir timing_${tag}.rpt]

set lut 0; set lutlog 0; set lutram 0; set distram 0; set ff 0
set bram 0.0; set dsp 0; set f7 0; set f8 0
set fh [open $rpt r]; set txt [read $fh]; close $fh
foreach line [split $txt \n] {
  if {[regexp {^\| CLB LUTs\*?\s+\|\s+([0-9]+)} $line -> v]}          { set lut $v }
  if {[regexp {^\|   LUT as Logic\s+\|\s+([0-9]+)} $line -> v]}       { set lutlog $v }
  if {[regexp {^\|   LUT as Memory\s+\|\s+([0-9]+)} $line -> v]}      { set lutram $v }
  if {[regexp {^\|     LUT as Distributed RAM\s+\|\s+([0-9]+)} $line -> v]} { set distram $v }
  if {[regexp {^\| CLB Registers\s+\|\s+([0-9]+)} $line -> v]}        { set ff $v }
  if {[regexp {^\| Block RAM Tile\s+\|\s+([0-9.]+)} $line -> v]}      { set bram $v }
  if {[regexp {^\| DSPs\s+\|\s+([0-9]+)} $line -> v]}                 { set dsp $v }
  if {[regexp {^\| F7 Muxes\s+\|\s+([0-9]+)} $line -> v]}             { set f7 $v }
  if {[regexp {^\| F8 Muxes\s+\|\s+([0-9]+)} $line -> v]}             { set f8 $v }
}

# THE DECISIVE PAIR.  The aggregate rows above say how many LUTs became memory;
# they do not say which SIGNAL, and the whole question is about one signal
# inside a child entity two levels down.
set cb_ram [llength [get_cells -hier -quiet -filter {NAME =~ *cb_reg* && REF_NAME =~ RAM*}]]
set cb_ff  [llength [get_cells -hier -quiet -filter {NAME =~ *cb_reg* && REF_NAME =~ FD*}]]
if {$cb_ram == 0 && $cb_ff == 0} {
  error "LEVERC48: the cb census found NEITHER RAM cells NOR flip-flops named\
         cb_reg*.  That is not an answer, it is a broken filter -- the codebook\
         cannot be absent.  Fix the census before reading any number."
}

set wns ""
set p [get_timing_paths -delay_type max -max_paths 1]
if {[llength $p] > 0} { set wns [get_property SLACK $p] }

set csvpath [file join $outdir results.csv]
set fresh [expr {![file exists $csvpath] || [file size $csvpath] == 0}]
set csv [open $csvpath a]
if {$fresh} {
  puts $csv "tag,part,cb_style,rows_if,blk,lut,lut_as_logic,lut_as_mem,dist_ram,ff,bram36,dsp,muxf7,muxf8,cb_ram_cells,cb_ff_cells,wns_ns"
}
puts $csv "$tag,$o(part),$o(style),$o(rows),$o(blk),$lut,$lutlog,$lutram,$distram,$ff,$bram,$dsp,$f7,$f8,$cb_ram,$cb_ff,$wns"
close $csv

puts "==== LEVERC48 THREAD $tag  top=matvec_int4  CB_STYLE=$o(style)  ROWS_IF=$o(rows) ===="
puts [format "UTIL   LUT=%s (logic %s / memory %s: distRAM %s)  FF=%s  BRAM36=%s  DSP=%s  MUXF7=%s  MUXF8=%s" \
      $lut $lutlog $lutram $distram $ff $bram $dsp $f7 $f8]
puts [format "CB     cells named cb_reg*: RAM=%s  FF=%s" $cb_ram $cb_ff]
puts "WNS=$wns ns at period $o(period) ns"
# Gate on THIS line and on util_<tag>.rpt existing, never on an exit code: a
# Vivado run can print full success and then die on a Tcl error.
puts "LEVERC48_THREAD_DONE $tag"
