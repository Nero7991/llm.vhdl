# rmsnorm_bf across LANES, against rmsnorm_rs at the same lane count.
#
# WHY: the LANES=4 comparison measured rmsnorm_bf as DSP-neutral and
# timing-identical at +8.0% LUT (sim/rmsnorm_bf.csv).  That is one operating
# point.  Two things it does not establish:
#
#   * whether the +719 LUT is a FIXED cost or an element-proportional one.
#     The S_INV chain is scalar and runs ONCE per pass, so the delta should be
#     flat in LANES -- if instead it scales, something in the new chain is
#     being replicated per lane and the whole-die arithmetic changes.
#   * whether the new chain still meets timing when the element loop is wider.
#     rmsnorm_rs's own LANES=16 max-reduce bug is the recorded precedent for a
#     lane count changing behaviour, so lane sweeps are not assumed here.
#
# Q is fixed at 12 because the model-range measurement put rmsnorm_bf at
# 1.33e-4 worst relative gain error there, so no Q bump is being bought.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "rmsnorm_bf_lanes.csv" w]
puts $csv "unit,q,lanes,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach L {1 2 8 16} {
  foreach unit {rmsnorm_rs rmsnorm_bf} {
    puts "======== $unit LANES=$L ========"
    create_project -in_memory -part $part
    read_vhdl -vhdl2008 [file join $rtldir util_pkg.vhd]
    read_vhdl -vhdl2008 [file join $rtldir fixed_luts_pkg.vhd]
    read_vhdl -vhdl2008 [file join $rtldir fixed_pkg.vhd]
    read_vhdl -vhdl2008 [file join $rtldir $unit.vhd]
    synth_design -mode out_of_context -top $unit -part $part \
                 -generic N=128 -generic LANES=$L -generic Q=12
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
    puts "RESULT $unit LANES=$L dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
    puts $csv "$unit,12,$L,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
    flush $csv
    close_project
  }
}
close $csv
puts "DONE"
