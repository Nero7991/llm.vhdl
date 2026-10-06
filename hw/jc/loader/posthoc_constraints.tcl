# hw/jc/loader/posthoc_constraints.tcl -- Task 10 fix round 1. Applies the two
# constraints added after the 2026-10-05 bitstream was routed (jcl_tdi, jcl_dna_mcp in
# jc_loader_timing.tcl) to that build's ROUTED checkpoint, without re-implementing, and
# writes the evidence. No hardware access.
#
#   vivado -mode batch -source posthoc_constraints.tcl -tclargs <routed.dcp> <outdir>
#
# Sentinels: JCLOADER_POSTHOC_TDI, JCLOADER_POSTHOC_DNA, JCLOADER_POSTHOC_WNS/WHS,
# JCLOADER_POSTHOC_DONE.
set here [file normalize [file dirname [info script]]]
set dcp [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
file mkdir $out
open_checkpoint $dcp
source $here/jc_loader_timing.tcl
set TCK_P 37.037
set clk_a [get_clocks clk_out3_jcl_clk_wiz_0_0]
set clk_t [get_clocks tck_user4]
set clk_d [get_clocks dna_clk]

# BEFORE: the same paths under the shipped constraints
set ep [all_fanout -endpoints_only -flat [get_pins -hier -filter {NAME =~ "*u_jc_frx/u_jc_bscan/INTERNAL_TDI"}]]
report_timing -from [get_pins -hier -filter {NAME =~ "*u_jc_frx/u_jc_bscan/INTERNAL_TDI"}] -to $ep \
  -max_paths 20 -nworst 1 -file $out/tdi_before.rpt
report_timing -from $clk_d -to $clk_a -max_paths 10 -nworst 1 -file $out/dna_dout_before.rpt

jcl_tdi "*u_jc_frx/u_jc_bscan" [expr {$TCK_P / 2.0}]
jcl_dna_mcp 10 $clk_a
set dnac [get_cells -hier -filter {REF_NAME == DNA_PORTE2}]
update_timing -full

set src [get_pins -hier -filter {NAME =~ "*u_jc_frx/u_jc_bscan/INTERNAL_TDI"}]
report_timing -from $src -to $ep -max_paths 20 -nworst 1 -file $out/tdi_after.rpt
report_timing -hold -from $src -to $ep -max_paths 20 -nworst 1 -file $out/tdi_after_hold.rpt
set p [get_timing_paths -setup -from $src -to $ep -max_paths 1]
set n [llength [get_timing_paths -setup -from $src -to $ep -max_paths 1000 -nworst 1]]
puts "JCLOADER_POSTHOC_TDI paths $n worst_slack [get_property SLACK $p] requirement [get_property REQUIREMENT $p] exception {[get_property EXCEPTION $p]} endpoint [get_property ENDPOINT_PIN $p]"
report_timing -from $clk_d -to $clk_a -max_paths 10 -nworst 1 -file $out/dna_clk_to_aclk_after.rpt
report_timing -from $dnac -to $clk_a -max_paths 10 -nworst 1 -file $out/dna_dout_after.rpt
report_timing -hold -from $dnac -to $clk_a -max_paths 10 -nworst 1 -file $out/dna_dout_after_hold.rpt
set p [get_timing_paths -setup -from $dnac -to $clk_a -max_paths 1]
set h [get_timing_paths -hold -from $dnac -to $clk_a -max_paths 1]
puts "JCLOADER_POSTHOC_DNA setup_slack [get_property SLACK $p] requirement [get_property REQUIREMENT $p] hold_slack [get_property SLACK $h] endpoint [get_property ENDPOINT_PIN $p]"

report_timing_summary -max_paths 10 -report_unconstrained -file $out/timing_summary.rpt
check_timing -verbose -file $out/check_timing.rpt
report_exceptions -file $out/exceptions.rpt
report_exceptions -ignored -file $out/exceptions_ignored.rpt
report_clock_interaction -file $out/clock_interaction.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "JCLOADER_POSTHOC_WNS $wns"
puts "JCLOADER_POSTHOC_WHS $whs"
puts "JCLOADER_POSTHOC_DONE"
