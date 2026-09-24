# Build 18 routed DCP: vectorless power, active vs clocks-only idle, by clock domain.
open_checkpoint /home/orencollaco/pwr18/bd_wrapper_routed.dcp
set o /home/orencollaco/pwr18
report_clocks -file $o/clocks.rpt
puts "PWR_STAGE active_default"
report_power -file $o/p_active_default.rpt
# idle: every non-clock net toggles 0 (no work), clocks keep running
set_switching_activity -default_toggle_rate 0 -default_static_probability 0
puts "PWR_STAGE idle_clocks_on"
report_power -file $o/p_idle_clocks_on.rpt
# same at the card's real VCCINT, if the power engine accepts it
if {[catch {set_operating_conditions -voltage {VCCINT 0.72}} e]} { puts "PWR_V072_REFUSED $e" } else {
  puts "PWR_STAGE idle_072"
  if {[catch {report_power -file $o/p_idle_072.rpt} e]} { puts "PWR_072_FAIL $e" }
  set_switching_activity -default_toggle_rate 12.5 -default_static_probability 0.5
  puts "PWR_STAGE active_072"
  if {[catch {report_power -file $o/p_active_072.rpt} e]} { puts "PWR_072_FAIL $e" }
}
puts "PWR_DONE"
