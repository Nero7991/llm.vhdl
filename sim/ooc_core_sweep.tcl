# OOC synthesis sweep of matvec_core across ROWS_IF, on a REAL part at a REAL
# clock. Exists because section 13's FK33 budget rests on two estimates that the
# AXU3EG build already contradicts:
#
#   * it assumes the VU33P has 2,976 DSP; `get_property DSP` says 2,880
#   * it assumes 34 DSP per row; the AXU3EG bitstream used 192 DSP48E2 at
#     ROWS_IF=4, and the engine is that design's only DSP consumer, so the
#     measured figure is 48 per row
#
# One point cannot separate fixed overhead from per-row cost, which is the whole
# reason this is a sweep and not a single build. Fit DSP = a + b*ROWS_IF over
# the results; `b` is what sets the maximum ROWS_IF that fits the part.
#
# matvec_core is the right unit: it holds all the DSP and has no AXI ports, so
# ROWS_IF can be swept without also inventing an HBM streamer configuration.
# weight_streamer is replaced for HBM anyway (section 13), and its port count
# does not follow the core-clock relation NPORTS_W*AXI_DW = ROWS_IF*BLK*4 once
# the HBM ports run at 450 MHz against a 300 MHz fabric.
#
#   vivado -mode batch -source sim/ooc_core_sweep.tcl -tclargs <part> <period_ns> <rows...>

set part   [lindex $argv 0]
set period [lindex $argv 1]
# Optional 3rd arg "dsp=<N>": cap DSP inference at N and let everything above it
# fall into LUT fabric. -1 (default) leaves Vivado's normal inference alone.
#   dsp=0     every multiplier in LUTs -- gives LUT-per-MAC by difference
#   dsp=2880  the VU33P's real budget -- the hybrid-array question
set maxdsp -1
set rest [lrange $argv 2 end]
if {[regexp {^dsp=(-?\d+)$} [lindex $rest 0] -> v]} {
  set maxdsp $v
  set rest [lrange $rest 1 end]
}
# Optional "volt=<V>": analyse timing at a VCCINT other than the part default.
# Exists because every Fmax figure in every spec is Vivado's default analysis,
# which for -1/-2/-2L is the 0.85 V point, while the FK33 powers up at 0.678 V
# and is set by hand to 0.717 V (docs/debugging/2026-08-24_fk33-sysmon-vccint-
# undervolt.md).  -2L is dual-characterised, so 0.70/0.72 are real speed data,
# not an extrapolation.  Applied AFTER synthesis so the reported number is the
# pure voltage derate of one netlist rather than two differently-optimised ones.
set volt -1
if {[regexp {^volt=([0-9.]+)$} [lindex $rest 0] -> v]} {
  set volt $v
  set rest [lrange $rest 1 end]
}
set rowlist $rest

set_param general.maxThreads 4
set here   [file normalize [file dirname [info script]]]
set rtldir [file normalize [file join $here ../rtl]]
set outdir [file normalize [file join $here ooc_sweep]]
file mkdir $outdir

# Append, but write the header if the file is new or empty -- the first version
# always appended and produced a headerless CSV whenever the file had been moved
# aside between runs, which silently turned the first data row into the header.
set csvpath [file join $outdir results.csv]
set fresh [expr {![file exists $csvpath] || [file size $csvpath] == 0}]
set csv [open $csvpath a]
if {$fresh} { puts $csv "part,period_ns,max_dsp,volt,rows_if,dsp,lut,ff,bram,wns_ns,fmax_mhz" }

foreach R $rowlist {
  puts "======== ROWS_IF=$R part=$part period=${period}ns max_dsp=$maxdsp ========"
  create_project -in_memory -part $part
  foreach f {util_pkg.vhd mv4i_arith_pkg.vhd matvec_core.vhd} {
    read_vhdl -vhdl2008 [file join $rtldir $f]
  }

  # Constrain BEFORE synthesis, not after. The existing ooc_matvec_int4.tcl
  # creates the clock after synth_design, which reports a number against a
  # design that was optimised unconstrained -- fine for a utilisation check,
  # misleading as an Fmax. Here the period is the question, so it has to be an
  # input to synthesis.
  set xdc [file join $outdir clk_${R}_${maxdsp}.xdc]
  set fh [open $xdc w]
  puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
  close $fh
  read_xdc -mode out_of_context $xdc

  set synthargs [list -mode out_of_context -top matvec_core -part $part \
    -generic BLK=32 -generic ROWS_IF=$R \
    -generic MAXCOLS=17408 -generic MAXROWS_BFP=17408]
  if {$maxdsp >= 0} { lappend synthargs -max_dsp $maxdsp }
  synth_design {*}$synthargs

  if {$volt > 0} {
    set_operating_conditions -voltage [list VCCINT $volt]
    puts "  operating conditions: VCCINT = $volt V"
  }

  set tag "R$R"
  if {$maxdsp >= 0} { set tag "R${R}_dsp$maxdsp" }
  if {$volt > 0}    { set tag "${tag}_v$volt" }
  set rpt [file join $outdir util_$tag.rpt]
  report_utilization -file $rpt
  report_timing_summary -delay_type max -max_paths 3 \
    -file [file join $outdir timing_$tag.rpt]

  # Parse report_utilization rather than counting cells. The first version of
  # this used get_cells -hier -filter {PRIMITIVE_TYPE =~ ARITHMETIC.*} and
  # friends, which reported 1728 DSP at ROWS_IF=4 (the true figure is 192, as
  # both this report and the AXU3EG bitstream agree), 0 LUTs, and 13455 DSP at
  # ROWS_IF=32 on a part that has 1824. PRIMITIVE_TYPE is not reliably set on a
  # synthesized, unplaced netlist, and a glob that matches nothing returns an
  # empty list rather than an error -- so the wrong numbers looked like data.
  # The 0 LUT column is what gave it away; take that as the lesson, since the
  # DSP column alone was wrong in a way that could have been believed.
  set dsp 0; set lut 0; set ff 0; set bram 0.0
  set fh [open $rpt r]
  foreach line [split [read $fh] \n] {
    if {[regexp {^\| DSPs\s+\|\s+([0-9]+)} $line -> v]}           { set dsp $v }
    # NOTE the \*? -- out-of-context synthesis emits "CLB LUTs*" with a
    # trailing asterisk, and the un-asterisked pattern silently matched nothing.
    if {[regexp {^\| CLB LUTs\*?\s+\|\s+([0-9]+)} $line -> v]}     { set lut $v }
    if {[regexp {^\| CLB Registers\s+\|\s+([0-9]+)} $line -> v]}  { set ff $v }
    if {[regexp {^\| Block RAM Tile\s+\|\s+([0-9.]+)} $line -> v]} { set bram $v }
  }
  close $fh
  set wns  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
  # WNS is slack against `period`, so the achievable period is period-WNS and
  # Fmax follows. Reported explicitly because a negative WNS at 300 MHz is the
  # expected outcome at large ROWS_IF and the useful question is "by how much".
  set fmax [expr {1000.0 / ($period - $wns)}]

  puts $csv "$part,$period,$maxdsp,$volt,$R,$dsp,$lut,$ff,$bram,$wns,$fmax"
  flush $csv
  puts [format "RESULT ROWS_IF=%-3s DSP=%-5s LUT=%-7s FF=%-7s BRAM=%-4s WNS=%.3f Fmax=%.1f MHz" \
        $R $dsp $lut $ff $bram $wns $fmax]
  close_project
}
close $csv
puts "SWEEP_DONE"
