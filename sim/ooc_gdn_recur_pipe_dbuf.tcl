# OOC synth of gdn_recur_pipe with the head-boundary double buffer, against the
# pre-double-buffer commit as the control.  The question this answers is NOT
# whether the buffer works -- tb_gdn_recur_pipe settles that -- but whether the
# extra 2:1 bank select in front of the k_n/q_s group mux costs Fmax.  A wide
# mux in front of a fetch is exactly what cost rmsnorm_rs 257 MHz, so it is
# measured rather than assumed.
#
# Run from sim/:  vivado -mode batch -source ooc_gdn_recur_pipe_dbuf.tcl
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
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
set csv [open "gdn_recur_pipe_dbuf.csv" w]
puts $csv "src,lanes,slots,dsp,lut,ff,bram,wns_ns,fmax_mhz"
# "before" is the file as committed at 2e666de, staged into scratch by the
# caller; "after" is the working tree.  Both are synthesized in the same
# session, same part, same period, so the comparison is like for like.
foreach src [list $env(PIPE_BEFORE) [file join $rtldir gdn_recur_pipe.vhd]] {
  foreach cfg {{32 16}} {
    lassign $cfg L S
    puts "======== [file tail $src] LANES=$L SLOTS=$S ========"
    create_project -in_memory -part $part
    read_vhdl -vhdl2008 $src
    synth_design -mode out_of_context -top gdn_recur_pipe -part $part \
                 -generic LANES=$L -generic SLOTS=$S
    create_clock -period $period -name clk [get_ports clk]
    set rpt [report_timing_summary -no_header -return_string]
    set wns 0.0
    if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
    set fmax [expr {1000.0/($period - $wns)}]
    set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
    set nlut [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
    set nff  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
    set nbr  [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] \
                  + 0.5*[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]
    puts "RESULT src=[file tail $src] L=$L dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
    puts $csv "[file tail $src],$L,$S,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
    flush $csv
    close_project
  }
}
close $csv
puts "PIPE_DBUF_DONE"
