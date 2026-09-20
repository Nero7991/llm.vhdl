# OOC census of ONE GDN layer's recurrent state store, on the FK33 part.
#
# THE QUESTION: `rtl/gdn_state_mem.vhd` holds VAL_HEADS*DIM*DIM*16 bits =
# 8,388,608 at the 9B shape.  What does the device actually spend on it, in
# URAM and in BRAM?  The whole point of the 24 MB finding
# (docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md) is that ONE
# layer fits and 24 do not, and "fits" has to be a measured primitive count
# rather than a bit count divided by a tile size.
#
# PRE-REGISTERED PREDICTIONS, written before the first run:
#   STYLE=ultra   32 URAM288, 0 BRAM.  URAM288 is 4096 x 72, so 131072 words
#                 cascade 32 deep and 64 of the 72 bits are used.
#   STYLE=block  256 RAMB36, 0 URAM.   At width 64 a RAMB36 is 512 x 72, so
#                 131072/512 = 256 tiles -- which does NOT fit the budget and
#                 is the reason the ultra path matters.
#   STYLE=auto    unknown.  This is the control: it says what Vivado picks
#                 with no attribute at all.
# A bit-count estimate said 29 URAM and 228 BRAM.  Both are expected to be
# WRONG, because allocation is quantised by WIDTH as well as depth -- the same
# trap that made a region_mem estimate wrong by 47%.
#
# THE CENSUS IS AUTHORITATIVE, NOT THE LOG.  Vivado's inference messages have
# been measured lying in BOTH directions in this project, so every number here
# comes from `get_cells`, and `report_utilization` is printed only alongside.

# THE `PRIMITIVE_GROUP` FILTER DOES NOT WORK IN THIS VIVADO AND RETURNS ZERO.
# MEASURED 2026-09-02: `get_cells -hier -filter {PRIMITIVE_GROUP == LUT}` and
# `== FLOP_LATCH` both returned 0 on a design whose own report_utilization said
# 269 LUTs and 703 registers in the same run.  A census that reports zero looks
# like a tiny module rather than like a broken filter, which is the worst way
# for a measurement to fail.  Use REF_NAME patterns, and CROSS-CHECK against
# report_utilization every time -- when they disagree the census wins, but only
# once you know both are actually counting something.

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

set csv [open "gdn_state_census.csv" w]
puts $csv "style,uram,ramb36,ramb18,lut,lutram,ff,wns_ns,fmax_mhz"

foreach STYLE {ultra block auto} {
  puts "======== gdn_state_mem STYLE=$STYLE ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir gdn_state_mem.vhd]
  synth_design -mode out_of_context -top gdn_state_mem -part $part \
               -generic STYLE=$STYLE

  create_clock -period $period -name clk [get_ports clk]
  set rpt [report_timing_summary -no_header -return_string]
  set wns 0.0
  if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
  set fmax [expr {1000.0/($period - $wns)}]

  # The object-level census.  REF_NAME, not the utilization table.
  set nuram [llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]
  set nb36  [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
  set nb18  [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
  # NOT `REF_NAME =~ RAM*`: that also matches RAMB36E2, so the BRAM count was
  # reported a second time in the LUTRAM column.  RAM32M/RAM64M/RAM256X are the
  # distributed-RAM primitives.
  set nlutr [llength [get_cells -hier -filter {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* || REF_NAME =~ RAM256*}]]
  set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
  set nff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]

  puts "CENSUS STYLE=$STYLE URAM288=$nuram RAMB36=$nb36 RAMB18=$nb18 \
LUTasRAM=$nlutr LUT=$nlut FF=$nff WNS=$wns FMAX=$fmax"
  puts "---- report_utilization, for cross-check ONLY ----"
  puts [report_utilization -return_string]
  puts $csv "$STYLE,$nuram,$nb36,$nb18,$nlut,$nlutr,$nff,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "GDN_STATE_CENSUS_DONE"
