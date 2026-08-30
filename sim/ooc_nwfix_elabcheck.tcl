# ooc_nwfix_elabcheck.tcl -- TRACK NWFIX, 2026-08-29.
#
# THE CHECK THAT WAS MISSING.  On 2026-08-29 TRACK NWROM measured that at the
# real 9B shape `rtl/llama_top.vhd`'s `NORM_W_IMAGE` loader did not synthesise
# at all: it failed ELABORATION, on Vivado's per-loop-statement limit of 65,536
# iterations.  Nothing in this project could see that.  GHDL has no such limit,
# so the `tb_llama_top_normw` gate row passed; and that row's image is 576
# lines against the 266,240 the real shape needs, so it could not have reached
# the failure even under a tool that had a limit.
#
# The general shape of the defect is worth naming, because the loader is not
# the only place it can occur: **a real-shape property, in the one tool that is
# not in the gate.**  The only honest guard against it is to run that tool at
# that shape.  This script is the cheap way to do that -- `synth_design -rtl`
# stops after elaboration, so it costs elaboration and nothing else, and
# elaboration is precisely the phase that was failing.
#
# IT DELIBERATELY DOES NOT RAISE THE LOOP LIMIT.  TRACK NWROM measured that
# `set_param synth.elaboration.rodinMoreOptions {rt::set_parameter maxLoopLimit
# 4000000}` makes the OLD loader elaborate.  That parameter must never appear
# here: the whole assertion this script makes is that the shipping RTL
# elaborates with the tool at its DEFAULT settings, and a run that raised the
# limit would assert nothing.
#
# NO HARDWARE.  synth_design -rtl only; no place, no route, no programming.
#
# env:
#   NWFIX_TOP    entity to elaborate            (default ooc_normadapt)
#   NWFIX_RTL    directory of .vhd to read      (default rtl)
#   NWFIX_PART   part                           (default xcvu33p-fsvh2104-2L-e)
#   NWFIX_GEN    space-separated NAME=VALUE generics

proc envor {n d} { if {[info exists ::env($n)]} { return $::env($n) } ; return $d }

set top   [envor NWFIX_TOP  ooc_normadapt]
set rtld  [envor NWFIX_RTL  rtl]
set part  [envor NWFIX_PART xcvu33p-fsvh2104-2L-e]
set gens  [envor NWFIX_GEN  ""]

puts "NWFIX_ELAB_BEGIN top=$top part=$part rtl=$rtld gen=$gens"

foreach f [lsort [glob -directory $rtld *.vhd]] {
    if {[catch {read_vhdl -vhdl2008 $f} e]} { puts "NWFIX_READ_SKIP $f : $e" }
}

set cmd [list synth_design -rtl -mode out_of_context -top $top -part $part]
foreach g $gens { lappend cmd -generic $g }
puts "NWFIX_ELAB_CMD $cmd"

if {[catch {eval $cmd} e]} {
    puts "NWFIX_ELAB_FAIL $top : $e"
    puts "NWFIX_ELAB_FAIL_HINT If this is 'loop limit (65536) exceeded', an"
    puts "NWFIX_ELAB_FAIL_HINT elaboration-time loop is iterating once per"
    puts "NWFIX_ELAB_FAIL_HINT ELEMENT of the real shape.  Restructure the loop"
    puts "NWFIX_ELAB_FAIL_HINT so no single loop statement exceeds the limit."
    puts "NWFIX_ELAB_FAIL_HINT Do NOT raise maxLoopLimit to get past this."
    exit 1
}

puts "NWFIX_ELAB_PASS $top"
