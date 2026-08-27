# Whole-die DSP/BRAM refresh for every subsystem B unit at its target config.
#
# WHY: the whole-die DSP figure is 2,606 to 2,648 of 2,880, i.e. 90.5% to
# 91.9%, and that number has been restated five times as units were built
# (87.2-88.2%, 87.6%, 88.4%, 89.5%, and three different absolute counts).  Two
# new units landed today -- gdn_head_emit and rmsnorm_bf -- and site 13 is
# being written now.  Rather than adjust the total by hand again, this
# synthesizes every B unit in ONE run, against the same Vivado, part and
# period, so the budget is a measurement rather than an accumulated edit.
#
# The per-unit numbers are what feed the reconciliation; the sum here is NOT
# the die total, because instance counts differ per unit and are applied
# separately in the budget document.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "b_budget.csv" w]
puts $csv "unit,generics,dsp,lut,ff,bram,wns_ns,fmax_mhz"

proc measure {csv part period rtldir unit deps gens label} {
  puts "======== $unit $label ========"
  create_project -in_memory -part $part
  foreach d $deps { read_vhdl -vhdl2008 [file join $rtldir $d.vhd] }
  read_vhdl -vhdl2008 [file join $rtldir $unit.vhd]
  set cmd [list synth_design -mode out_of_context -top $unit -part $part]
  foreach {g v} $gens { lappend cmd -generic $g=$v }
  eval $cmd
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
  puts "RESULT $unit $label dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  puts $csv "$unit,$label,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}

# Every unit gets the full package list.  The first version passed a minimal
# per-unit list and gdn_silu died on `package 'fixed_luts_pkg' not found`,
# wasting the whole run: read_vhdl of an unused package costs nothing, while a
# missing one costs the entire sweep.  Do not "optimise" this back.
set pk {util_pkg fixed_luts_pkg fixed_pkg}
measure $csv $part $period $rtldir gdn_silu       $pk {LANES 32 ARG_Q 12}            "LANES=32"
measure $csv $part $period $rtldir gdn_head_emit  $pk {DIM 128}                      "DIM=128"
measure $csv $part $period $rtldir rmsnorm_bf     $pk {N 128 LANES 4 Q 12}           "N=128,L=4"
measure $csv $part $period $rtldir rmsnorm_rs     $pk {N 128 LANES 4 Q 12}           "N=128,L=4"
measure $csv $part $period $rtldir l2norm_rs      $pk {N 128 LANES 4}                "N=128,L=4"
measure $csv $part $period $rtldir gdn_scalar     $pk {}                             "default"
measure $csv $part $period $rtldir gdn_conv       $pk {}                             "default"
measure $csv $part $period $rtldir gdn_y_emit     $pk {HEADS 24 DIM 128}            "H=24,D=128"

close $csv
puts "DONE"
