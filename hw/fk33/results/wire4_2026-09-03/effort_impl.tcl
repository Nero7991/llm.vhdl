# Controlled effort experiment: the SAME wire4_synth.dcp as the default impl,
# only the directives differ.  Answers whether core_clk's -0.502 ns is a
# property of the design or of the default directives.  NO HARDWARE.
set SP /tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/4d84bf97-4b0d-407d-ac40-96158eb597e1/scratchpad
set out $SP/c4wire/eff
open_checkpoint $SP/c4wire/out/wire4_synth.dcp
puts "EFF_BEGIN same_synth_dcp"

opt_design -directive Explore
puts "EFF_STAGE opt done"

place_design -directive ExtraTimingOpt
puts "EFF_WNS_PLACED [get_property SLACK [get_timing_paths -delay_type max]]"

phys_opt_design -directive AggressiveExplore -quiet
puts "EFF_WNS_PHYSOPT [get_property SLACK [get_timing_paths -delay_type max]]"

set rrc [catch {route_design -directive AggressiveExplore} rmsg]
puts "EFF_ROUTE_RC $rrc"

# a post-route physical optimisation pass, which the default flow does not run
phys_opt_design -directive AggressiveExplore -quiet
puts "EFF_WNS_ROUTED [get_property SLACK [get_timing_paths -delay_type max]]"

report_timing_summary -file $out/timing_eff_routed.rpt
report_utilization    -file $out/util_eff_routed.rpt
report_route_status   -file $out/route_status_eff.rpt
write_checkpoint -force $out/wire4_eff_routed.dcp

set paths [get_timing_paths -max_paths 20000 -nworst 1 -slack_lesser_than 0 -setup]
puts "EFF_FAILING [llength $paths]"
array set b {}
foreach p $paths {
    set top [lindex [split [get_property NAME [get_property ENDPOINT_PIN $p]] /] 0]
    if {[info exists b($top)]} { incr b($top) } else { set b($top) 1 }
}
foreach k [lsort [array names b]] { puts "EFF_BUCKET $k $b($k)" }
puts "EFF_DONE"
