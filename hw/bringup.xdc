# Board fan output.  Same pin as design_1/design_2, so a bitstream from this
# build drives the fan exactly as the running one does.  Without it AA11 is
# unconfigured, and the fan is ACTIVE-LOW: an undriven pin stops the fan while
# the thermal governor still reports healthy.
set_property PACKAGE_PIN AA11 [get_ports pwm_out_0]
set_property IOSTANDARD LVCMOS33 [get_ports pwm_out_0]
