# OOC of gdn_emit_chain across HEADS, at the adopted SILU_LANES=16.
#
# WHY.  gdn_y_emit's header calls out its per-head exponent lookup as a
# HEADS-to-1 mux that was deliberately given its OWN pipeline stage, because
# folding it into the shift stage would put a mux in front of a barrel shift --
# the exact pairing that held rmsnorm_rs at 117.2 MHz.  That reasoning has
# never been tested against a CHANGING head count: everything so far was
# measured at 24.  If the mux is the scaling term, Fmax falls with HEADS and
# the stage split is doing real work; if it is flat, the split is free
# insurance and the note should say so.
#
# 24 is the shipping value (48 value heads / 2 cards).  32 is included to see
# the trend past it, not because any configuration needs it.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "gdn_emit_chain_heads.csv" w]
puts $csv "heads,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach H {8 16 24 32} {
  puts "======== gdn_emit_chain HEADS=$H ========"
  create_project -in_memory -part $part
  foreach f {util_pkg fixed_luts_pkg fixed_pkg \
             gdn_head_emit rmsnorm_bf gdn_silu gdn_y_emit gdn_emit_chain} {
    read_vhdl -vhdl2008 [file join $rtldir $f.vhd]
  }
  synth_design -mode out_of_context -top gdn_emit_chain -part $part \
               -generic HEADS=$H -generic DIM=128 \
               -generic SILU_LANES=16 -generic RMS_LANES=4 -generic Q=12
  create_clock -period $period -name clk [get_ports clk]
  set rpt [report_timing_summary -no_header -return_string]
  set wns 0.0
  if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
  set fmax [expr {1000.0/($period - $wns)}]
  set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
  set nlut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
  set nff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
  set nbr  [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] \
                + 0.5*[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]
  puts "RESULT HEADS=$H dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  puts "---- worst path ----"
  puts [report_timing -max_paths 1 -nworst 1 -return_string]
  puts $csv "$H,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "CHAIN_HEADS_OOC_DONE"
