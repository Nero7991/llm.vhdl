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

set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl

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
  set nlutr [llength [get_cells -hier -filter {REF_NAME =~ RAM*}]]
  set nlut  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
  set nff   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]

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
