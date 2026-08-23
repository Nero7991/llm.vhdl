# Board fan output.  Same pin as design_1/design_2, so a bitstream from this
# build drives the fan exactly as the running one does.  Without it AA11 is
# unconfigured. MEASURED 2026-08-23: an unconfigured AA11 runs the fan at FULL
# SPEED, and the thermal governor reports healthy throughout because it is
# writing registers that reach nothing. (An earlier version of this comment
# predicted the opposite -- that the fan would stop -- which was a guess about
# which way a floating active-low input settles. It runs.)
#
# If these two lines ever match no port, the fan is NOT driven. Vivado reports
# that as a WARNING and builds a working bitstream anyway, so build_bringup.tcl
# asserts on the port and its placement rather than relying on reading the log.
set_property PACKAGE_PIN AA11 [get_ports pwm_out_0]
set_property IOSTANDARD LVCMOS33 [get_ports pwm_out_0]
