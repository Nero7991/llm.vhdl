# Failing-endpoint census on the ROUTED checkpoint, by top-level instance.
# Reading the worst path and calling it the cause is the mistake this project
# has paid for repeatedly; 5,287 endpoints fail and the report lists 4 paths.
open_checkpoint /tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/4d84bf97-4b0d-407d-ac40-96158eb597e1/scratchpad/c4wire/out/wire4_routed.dcp
set paths [get_timing_paths -max_paths 20000 -nworst 1 -slack_lesser_than 0 -setup]
puts "CENSUS_TOTAL [llength $paths]"
array set b {}
foreach p $paths {
    set ep [get_property ENDPOINT_PIN $p]
    set n  [get_property NAME $ep]
    set top [lindex [split $n /] 0]
    if {[info exists b($top)]} { incr b($top) } else { set b($top) 1 }
}
foreach k [lsort [array names b]] { puts "CENSUS_BUCKET $k $b($k)" }
# worst slack per bucket, so a bucket with many shallow misses is not confused
# with one that is deeply broken
array set w {}
foreach p $paths {
    set s [get_property SLACK $p]
    set top [lindex [split [get_property NAME [get_property ENDPOINT_PIN $p]] /] 0]
    if {![info exists w($top)] || $s < $w($top)} { set w($top) $s }
}
foreach k [lsort [array names w]] { puts "CENSUS_WORST $k $w($k)" }
puts "CENSUS_DONE"
