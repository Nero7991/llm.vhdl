# sim/elab_cardtop.tcl -- does the design ELABORATE at the real 9B shape?
#
# TRACK CARDTOP, item 5 of the work breakdown in
# docs/debugging/2026-08-31_cardtop-design-note.md.
#
# THE QUESTION.  sim/mk_browse_proj.tcl records, MEASURED, that `llama_top` at
# the real shape CRASHES Vivado in `HOptDfg::dissolveRam at 2,752,512 bits`.
# That number is the flat region array: 14 regions x 12,288 elements x 16 bits.
# D3 replaces it with sized per-region BRAM banks, so `fk33_llama_top` should
# elaborate where `llama_top` cannot.
#
# THIS SCRIPT RUNS BOTH, ONE AT A TIME, because a success on the card top alone
# proves nothing: the tool version, the machine and the source set have all
# moved since that crash was recorded, and any of them could explain a pass.
# The control is the whole experiment.
#
#   TOP=fk33_llama_top vivado -mode batch -source sim/elab_cardtop.tcl
#   TOP=llama_top      vivado -mode batch -source sim/elab_cardtop.tcl
#
# NO HARDWARE.  This elaborates only; it opens no target and programs nothing.

set repo [file normalize [file dirname [info script]]/..]
set top "fk33_llama_top"
if {[info exists ::env(TOP)]} { set top $::env(TOP) }
set outdir "/mnt/storage/llama-elab"
if {[info exists ::env(ELAB_OUT)]} { set outdir $::env(ELAB_OUT) }
file mkdir $outdir

puts "ELAB_TOP $top"
puts "ELAB_PART xcvu33p-fsvh2104-2L-e"

set srcs [glob -nocomplain $repo/rtl/*.vhd]
set fk33 [glob -nocomplain $repo/hw/fk33/rtl/*.vhd]
if {[llength $fk33] > 0} { set srcs [concat $srcs $fk33] }
puts "ELAB_SRCS [llength $srcs]"

foreach f $srcs { read_vhdl -vhdl2008 $f }

# -rtl stops after elaboration: no mapping, no place, no route.  That is the
# stage the recorded crash happens in, and it is the cheapest stage that can
# answer the question.
# HOST_WINDOW is the D5 generic: true = the simulation configuration in which
# identity with llama_top is proven, false = the card, where hr_data reads
# zero and the region banks are free to infer BRAM.  The two runs differ in
# this generic ALONE, which is what makes the pair a controlled experiment
# rather than two separate observations.
set gen {}
if {[info exists ::env(HOST_WINDOW)] && $top ne "llama_top"} {
    set gen [list -generic "HOST_WINDOW=$::env(HOST_WINDOW)"]
    puts "ELAB_HOST_WINDOW $::env(HOST_WINDOW)"
} else {
    puts "ELAB_HOST_WINDOW default"
}

set rc [catch {
    synth_design -rtl -name elab_$top -top $top -part xcvu33p-fsvh2104-2L-e {*}$gen
} err]

if {$rc} {
    puts "ELAB_RESULT FAIL $top"
    puts "ELAB_ERROR $err"
} else {
    set ncell [llength [get_cells -hier -quiet]]
    set nnet  [llength [get_nets  -hier -quiet]]
    puts "ELAB_RESULT OK $top cells=$ncell nets=$nnet"
}
puts "ELAB_SENTINEL_DONE $top"
