# TEETH CHECK for the FK33_PBLK post-implementation gate.
#
# The gate emitted by gen_pcieep.py asserts three things about the implemented
# design: pblock_bd_i is absent, pb_core is present, and pb_core's GRID_RANGES
# is CLOCKREGION_X0Y0:CLOCKREGION_X6Y3.  A full build passing the gate shows the
# gate does not fire on a GOOD design.  It does NOT show the gate would fire on
# a bad one, and a checker never shown to fail has not been shown to work.
#
# So: open the routed checkpoint the build actually produced, and run the gate
# four times -- once as written, three times against a mutated design or a
# mutated expectation, each of which the gate MUST reject.  Every mutation that
# does NOT bite is reported under its own name, because that is the gate's
# resolution floor.
#
# No hardware.  open_checkpoint and get_pblocks only; nothing is written back.

set dcp [lindex $argv 0]

proc gate {tag want_range want_name} {
    # A verbatim copy of the three assertions in the emitted build script,
    # parameterised only in the two places a mutation needs to reach.
    set pbs [lsort [get_property NAME [get_pblocks -quiet *]]]
    if {[lsearch $pbs pblock_bd_i] >= 0} {
        error "FK33_PBLK FAIL: pblock_bd_i is in the implemented design."
    }
    if {[llength [get_pblocks -quiet $want_name]] != 1} {
        error "FK33_PBLK FAIL: $want_name is not in the implemented design."
    }
    set pbr [get_property GRID_RANGES [get_pblocks $want_name]]
    if {$pbr ne $want_range} {
        error "FK33_PBLK FAIL: $want_name range is '$pbr', not $want_range."
    }
    return "pblocks=$pbs $want_name=$pbr"
}

proc run {tag expect want_range want_name} {
    if {[catch {gate $tag $want_range $want_name} res]} {
        set got FIRED
    } else {
        set got PASSED
    }
    if {$got eq $expect} { set verdict OK } else { set verdict "*** MUTATION DID NOT BITE ***" }
    puts "TEETH_PBLK $tag expect=$expect got=$got $verdict"
    puts "TEETH_PBLK $tag detail: $res"
}

open_checkpoint $dcp
puts "TEETH_PBLK opened $dcp"
puts "TEETH_PBLK pblocks present: [lsort [get_property NAME [get_pblocks -quiet *]]]"

# ---- the reports the comparison needs, taken from the ARTEFACT the project
# run produced, before any mutation touches the design.  The emitted build
# script writes timing, congestion and utilization but neither route status nor
# DRC, and those are two of the four numbers this track was asked to report.
report_route_status                   -file e2e_route_status.rpt
report_utilization -pblocks [get_pblocks pb_core] -file e2e_pblock_util_routed.rpt
report_design_analysis -congestion    -file e2e_congestion_routed.rpt
puts "TEETH_PBLK reports written"

# M0 -- the gate exactly as the build runs it.  Must PASS.
run M0_as_built PASSED CLOCKREGION_X0Y0:CLOCKREGION_X6Y3 pb_core

# M1 -- mutate the EXPECTATION: a range one clock-region column narrower.
#       Tests that the range comparison is a real comparison.
run M1_wrong_range FIRED CLOCKREGION_X0Y0:CLOCKREGION_X5Y3 pb_core

# M2 -- mutate the EXPECTATION: a pblock name that does not exist.
#       Tests the "pb_core is absent" arm.
run M2_missing_pblock FIRED CLOCKREGION_X0Y0:CLOCKREGION_X6Y3 pb_core_typo

# M3 -- mutate the DESIGN: put a pblock literally named pblock_bd_i back.
#       This is the arm that guards the actual regression, so it is the one
#       that most needs teeth.
create_pblock pblock_bd_i
run M3_bd_i_reintroduced FIRED CLOCKREGION_X0Y0:CLOCKREGION_X6Y3 pb_core
delete_pblocks [get_pblocks pblock_bd_i]
puts "TEETH_PBLK after cleanup: [lsort [get_property NAME [get_pblocks -quiet *]]]"

# M4 -- control for M3: with the injected pblock removed again, the gate must
#       go back to passing.  Without this, "M3 fired" is compatible with the
#       gate having been broken by the injection rather than by the pblock.
run M4_restored PASSED CLOCKREGION_X0Y0:CLOCKREGION_X6Y3 pb_core

puts "TEETH_PBLK_DONE"
