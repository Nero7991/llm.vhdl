# OOC census of `rtl/gdn_exp_mem.vhd` at the real 9B shape, FK33 part.
#
# THE QUESTION: what does a 4,096 x 8 table with a COMBINATIONAL read cost?
# It cannot be BRAM or URAM -- gdn_block samples `se_rdata` on the same edge
# it presents the address -- so this is distributed RAM and the cost is real.
# `region_mem` is the recorded case of a single combinational read port
# turning a store into 91,073 LUT, so this is measured and not assumed.
#
# THE CENSUS IS AUTHORITATIVE AND report_utilization IS THE CROSS-CHECK, and
# the LUT-as-memory row is the one that matters: a run reporting RAM=0 with
# thousands of FF has built registers and a giant mux, not a memory.
#
# THE OBJECT CENSUS DOES NOT SEE DISTRIBUTED RAM, AND THE SITE COUNT IS THE
# BUDGET.  MEASURED 2026-09-02 on `gdn_exp_mem`: `REF_NAME =~ LUT*` reported
# 550 while `report_utilization`'s `CLB LUTs` reported 2,466, because 384
# RAM64M8 primitives occupy 1,920 LUT SITES -- five each -- and the LUT filter
# matches none of them.  Wrong by 4.5x.  Quote `CLB LUTs` for area; use the
# object census to answer WHICH PRIMITIVE was inferred, which is a different
# question.

set part   xcvu33p-fsvh2104-2L-e
set period 5.0
# pfRoot -- the repo root, DERIVED from this script's own location rather than
# written in as a literal, so the run works from any checkout path and survives
# the repo directory being renamed (TRACK PATHFREE, 2026-09-20).  Probed rather
# than trusted: a wrong root would otherwise read_vhdl nothing and fail much
# later as a missing entity.
set pfRoot [file normalize [file join [file dirname [info script]] ..]]
if {![file exists $pfRoot/rtl/util_pkg.vhd]} {
    error "pfRoot: derived repo root '$pfRoot' does not contain rtl/util_pkg.vhd. Source this script by its path in the tree."
}
set rtldir $pfRoot/rtl
set csv [open "gdn_exp_mem_census.csv" w]
puts $csv "style,lut,lutram,ff,ramb36,uram,wns_ns,wns_matched"
foreach STYLE {distributed auto} {
  puts "======== gdn_exp_mem STYLE=$STYLE ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir gdn_exp_mem.vhd]
  synth_design -mode out_of_context -top gdn_exp_mem -part $part \
    -generic VAL_HEADS=32 -generic DIM=128 -generic STYLE=$STYLE
  create_clock -period $period -name clk [get_ports clk]
  set rpt [report_timing_summary -no_header -return_string]
  set wns 0.0
  set matched 0
  if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} {
    set wns $w; set matched 1
  }
  set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
  set nff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
  set nb36  [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
  set nuram [llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]
  set nlutr [llength [get_cells -hier -filter {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* || REF_NAME =~ RAM256*}]]
  puts "CENSUS gdn_exp_mem STYLE=$STYLE LUT=$nlut LUTasRAM=$nlutr FF=$nff \
RAMB36=$nb36 URAM288=$nuram WNS=$wns WNS_MATCHED=$matched"
  puts "---- report_utilization ----"
  puts [report_utilization -return_string]
  puts $csv "$STYLE,$nlut,$nlutr,$nff,$nb36,$nuram,$wns,$matched"
  flush $csv
  close_project
}
close $csv
puts "GDN_EXP_MEM_CENSUS_DONE"
