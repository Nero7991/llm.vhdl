# TRACK CBINFER.  Does Vivado infer distributed RAM from matvec_core's
# codebook `cb`, an array-of-array-of-signed?
#
# THE QUESTION THIS SCRIPT EXISTS TO ANSWER, and why it is not the obvious one.
# docs/debugging/2026-08-30_leverc-codebook-lutram.md section 7 item 1 says the
# whole of lever C rests on an UNVERIFIED inference: if `cb` does not infer
# LUTRAM at CB_STYLE = "distributed", the lever produces a register bank with
# one copy per LANE -- strictly worse than what ships.  Vivado's own note in
# matvec_core.vhd ([Synth 8-11357], "RAM from Record/Structs") records that a
# nested type does not infer BRAM; whether it infers DISTRIBUTED RAM from that
# shape is a different question with a different answer, and nobody had run it.
#
# WHY report_utilization ALONE IS NOT THE ANSWER.  Vivado emits log lines that
# read like conclusions ("Distributed RAM: ... inferred") and can still build
# registers.  So this script reports TWO independent things and the caller must
# read both:
#   * the utilization table's "LUT as Distributed RAM" row, and
#   * the PRIMITIVE CENSUS (RAMD*/RAMS*/SRL vs FDRE vs MUXF7/MUXF8), taken
#     from report_utilization's own Primitives section.
# If they disagree, the census wins: it counts the cells that exist.
#
# WHY THE VARIANT MECHANISM.  CB_STYLE is a string generic and the attribute
# values are constants returned by FUNCTIONS OF IT.  Passing the generic on the
# synth_design command line would confound two failures that must be told
# apart: "Vivado will not infer LUTRAM from this SHAPE" and "Vivado will not
# accept a non-literal ATTRIBUTE VALUE".  So each variant is a whole edited
# copy of rtl/, built by sim/cbinfer_variants.sh, and this script is told which
# directory to read.  The variant with literal attribute strings is the control
# that separates those two causes.
#
# USAGE
#   vivado -mode batch -source sim/ooc_cbinfer.tcl -tclargs <tag> <rtldir> [k=v]
#
#   tag     free-form label, becomes the CSV row name and the report filenames
#   rtldir  directory holding util_pkg.vhd mv4i_arith_pkg.vhd matvec_core.vhd
#   rows    ROWS_IF                        (default 4)
#   blk     BLK                            (default 32)
#   maxrows MAXROWS_BFP                    (default 17408)
#   maxcols MAXCOLS                        (default 17408)
#   period  clock period ns                (default 3.3)
#   part    (default xcvu33p-fsvh2104-2L-e, the FK33 part CONGEST and TIMING
#           drew their MUXF7/MUXF8 census on -- do not change it without
#           saying so, a part change silently invalidates the comparison)
#   outdir  where reports and the CSV land (default sim/ooc_cbinfer)
#
# NOT HARDWARE.  synth_design and report_* only.  No place, no route, no
# programming.  An OOC synthesis number is not a placed one, and lever C's
# claim is about PACKING, which only placement measures.

set tag    [lindex $argv 0]
set rtldir [lindex $argv 1]
if {$tag eq "" || $rtldir eq ""} { error "usage: -tclargs <tag> <rtldir> \[k=v ...\]" }
set rtldir [file normalize $rtldir]

array set o {
  part    xcvu33p-fsvh2104-2L-e
  rows    4
  blk     32
  maxrows 17408
  maxcols 17408
  period  3.3
  outdir  ""
}
foreach a [lrange $argv 2 end] {
  if {![regexp {^([a-z]+)=(.+)$} $a -> k v]} { error "bad arg '$a'" }
  if {![info exists o($k)]} { error "unknown key '$k'" }
  set o($k) $v
}

set here [file normalize [file dirname [info script]]]
if {$o(outdir) eq ""} { set o(outdir) [file join $here ooc_cbinfer] }
set outdir [file normalize $o(outdir)]
file mkdir $outdir

# One Vivado at a time on either box, and 4 threads is what every other OOC
# script here caps at.  See CLAUDE.md "THE MEMORY BUDGET IS GLOBAL".
set_param general.maxThreads 4

create_project -in_memory -part $o(part)
foreach f {util_pkg.vhd mv4i_arith_pkg.vhd matvec_core.vhd} {
  read_vhdl -vhdl2008 [file join $rtldir $f]
}

# Constrain BEFORE synth_design.  ooc_matvec_int4.tcl creates the clock
# afterwards and so reports a number against a design that was optimised
# unconstrained; ooc_core_sweep.tcl and ooc_fk33_a.tcl both record that as a
# trap.  Timing is not the question here, but an unconstrained synth also
# changes the AREA answer, which is.
set xdc [file join $outdir clk_${tag}.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name coreclk -period $o(period) \[get_ports clk\]"
close $fh
read_xdc -mode out_of_context $xdc

synth_design -mode out_of_context -top matvec_core -part $o(part) \
  -generic BLK=$o(blk) -generic ROWS_IF=$o(rows) \
  -generic MAXCOLS=$o(maxcols) -generic MAXROWS_BFP=$o(maxrows)

set rpt [file join $outdir util_${tag}.rpt]
report_utilization -file $rpt
report_timing_summary -delay_type max -max_paths 5 \
  -file [file join $outdir timing_${tag}.rpt]

# ------------------------------------------------------- utilization parse
set lut 0; set lutram 0; set lutlog 0; set ff 0; set bram 0.0; set dsp 0
set distram 0; set shiftreg 0
set fh [open $rpt r]
set txt [read $fh]
close $fh
foreach line [split $txt \n] {
  if {[regexp {^\| CLB LUTs\*?\s+\|\s+([0-9]+)} $line -> v]}          { set lut $v }
  if {[regexp {^\|   LUT as Logic\s+\|\s+([0-9]+)} $line -> v]}       { set lutlog $v }
  if {[regexp {^\|   LUT as Memory\s+\|\s+([0-9]+)} $line -> v]}      { set lutram $v }
  if {[regexp {^\|     LUT as Distributed RAM\s+\|\s+([0-9]+)} $line -> v]} { set distram $v }
  if {[regexp {^\|     LUT as Shift Register\s+\|\s+([0-9]+)} $line -> v]}  { set shiftreg $v }
  if {[regexp {^\| CLB Registers\s+\|\s+([0-9]+)} $line -> v]}        { set ff $v }
  if {[regexp {^\| Block RAM Tile\s+\|\s+([0-9.]+)} $line -> v]}      { set bram $v }
  if {[regexp {^\| DSPs\s+\|\s+([0-9]+)} $line -> v]}                 { set dsp $v }
}

# ------------------------------------------------------- primitive census
# The Primitives section of report_utilization is a count of the cells that
# EXIST in the netlist, which is the thing the utilization table summarises and
# a log message does not.  Parsed by ref name so a zero is visible as a zero
# rather than as an absent row.
# The Primitives table is THREE columns -- | Ref Name | Used | Functional
# Category | -- and NOT the four-column shape the other utilization tables use.
# The first version of this parser assumed four and silently produced a census
# of all zeros beside a utilization table full of numbers.  That is the exact
# failure mode this cross-check exists to catch, so the parser now takes the
# section by its heading and hard-errors if it finds no rows.
set inprim 0
array set prim {}
foreach line [split $txt \n] {
  if {[regexp {^8\. Primitives} $line]}   { set inprim 1; continue }
  if {[regexp {^9\. Black Boxes} $line]}  { set inprim 0 }
  if {!$inprim} { continue }
  if {[regexp {^\|\s*([A-Za-z0-9_]+)\s*\|\s*([0-9]+)\s*\|} $line -> ref n]} {
    if {$ref eq "Ref"} { continue }
    set prim($ref) $n
  }
}
if {[array size prim] == 0} {
  error "CBINFER: the Primitives census parsed ZERO rows.  A census of zeros\
         beside a populated utilization table is indistinguishable from a\
         design with no primitives, which is the confusion this cross-check\
         exists to prevent.  Fix the parser before reading any number."
}
proc pget {name} {
  upvar 1 prim p
  if {[info exists p($name)]} { return $p($name) }
  return 0
}
set n_muxf7 [pget MUXF7]
set n_muxf8 [pget MUXF8]
set n_fdre  [pget FDRE]
set n_ramd32 [expr {[pget RAMD32] + [pget RAMD32M64] + [pget RAMD64E]}]
set n_rams32 [expr {[pget RAMS32] + [pget RAMS64E] + [pget RAMS64E1]}]
set n_srl    [expr {[pget SRL16E] + [pget SRLC32E]}]
set n_ramcell [expr {$n_ramd32 + $n_rams32}]

# Every RAM-ish and mux-ish ref name that actually appeared, so a primitive
# this script does not know the name of cannot hide as a zero.
set unknown_ram {}
foreach k [array names prim] {
  if {[regexp {^(RAM|SRL)} $k]} { lappend unknown_ram "$k=$prim($k)" }
}

# ------------------------------------------------- object-level cb census
# The aggregate tables say how many LUTs became memory.  They do NOT say which
# SIGNAL they came from, and the whole question is about one signal.  These two
# numbers are the decisive pair: RAM cells carrying cb's name, and flip-flops
# carrying cb's name.  A codebook that is LUTRAM has the first and not the
# second; a codebook that is a register bank has the second and not the first.
set cb_ram  [llength [get_cells -hier -quiet -filter {NAME =~ *cb_reg* && REF_NAME =~ RAM*}]]
set cb_ff   [llength [get_cells -hier -quiet -filter {NAME =~ *cb_reg* && REF_NAME =~ FD*}]]

set wns ""
set p [get_timing_paths -delay_type max -max_paths 1]
if {[llength $p] > 0} { set wns [get_property SLACK $p] }

set csvpath [file join $outdir results.csv]
set fresh [expr {![file exists $csvpath] || [file size $csvpath] == 0}]
set csv [open $csvpath a]
if {$fresh} {
  puts $csv "tag,part,rows_if,blk,lut,lut_as_logic,lut_as_mem,dist_ram,shift_reg,ff,bram36,dsp,muxf7,muxf8,fdre,ram_cells,srl,cb_ram_cells,cb_ff_cells,wns_ns"
}
puts $csv "$tag,$o(part),$o(rows),$o(blk),$lut,$lutlog,$lutram,$distram,$shiftreg,$ff,$bram,$dsp,$n_muxf7,$n_muxf8,$n_fdre,$n_ramcell,$n_srl,$cb_ram,$cb_ff,$wns"
close $csv

puts "==== CBINFER $tag  rtl=$rtldir  part=$o(part)  ROWS_IF=$o(rows) BLK=$o(blk) ===="
puts [format "UTIL   LUT=%s (logic %s / memory %s: distRAM %s, SRL %s)  FF=%s  BRAM36=%s  DSP=%s" \
      $lut $lutlog $lutram $distram $shiftreg $ff $bram $dsp]
puts [format "CENSUS MUXF7=%s  MUXF8=%s  FDRE=%s  RAM cells=%s  SRL=%s" \
      $n_muxf7 $n_muxf8 $n_fdre $n_ramcell $n_srl]
puts "CENSUS RAM/SRL refs present: [join [lsort $unknown_ram] { }]"
puts [format "CB     cells named cb_reg*: RAM=%s  FF=%s" $cb_ram $cb_ff]
puts "WNS=$wns ns at period $o(period) ns"
# The sentinel.  A waiter that fires on a killed job is not a completion signal
# (CLAUDE.md); gate on this line, and on util_<tag>.rpt existing.
puts "CBINFER_DONE $tag"
