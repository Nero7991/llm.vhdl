# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "AW" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "IN_DIM" -parent ${Page_0}
  ipgui::add_param $IPINST -name "OUT_DIM" -parent ${Page_0}
  ipgui::add_param $IPINST -name "WW" -parent ${Page_0}
  ipgui::add_param $IPINST -name "XW" -parent ${Page_0}


}

proc update_PARAM_VALUE.AW { PARAM_VALUE.AW } {
	# Procedure called to update AW when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AW { PARAM_VALUE.AW } {
	# Procedure called to validate AW
	return true
}

proc update_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to update C_S_AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to validate C_S_AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to update C_S_AXI_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to validate C_S_AXI_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.IN_DIM { PARAM_VALUE.IN_DIM } {
	# Procedure called to update IN_DIM when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.IN_DIM { PARAM_VALUE.IN_DIM } {
	# Procedure called to validate IN_DIM
	return true
}

proc update_PARAM_VALUE.OUT_DIM { PARAM_VALUE.OUT_DIM } {
	# Procedure called to update OUT_DIM when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.OUT_DIM { PARAM_VALUE.OUT_DIM } {
	# Procedure called to validate OUT_DIM
	return true
}

proc update_PARAM_VALUE.WW { PARAM_VALUE.WW } {
	# Procedure called to update WW when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.WW { PARAM_VALUE.WW } {
	# Procedure called to validate WW
	return true
}

proc update_PARAM_VALUE.XW { PARAM_VALUE.XW } {
	# Procedure called to update XW when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.XW { PARAM_VALUE.XW } {
	# Procedure called to validate XW
	return true
}


proc update_MODELPARAM_VALUE.OUT_DIM { MODELPARAM_VALUE.OUT_DIM PARAM_VALUE.OUT_DIM } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.OUT_DIM}] ${MODELPARAM_VALUE.OUT_DIM}
}

proc update_MODELPARAM_VALUE.IN_DIM { MODELPARAM_VALUE.IN_DIM PARAM_VALUE.IN_DIM } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.IN_DIM}] ${MODELPARAM_VALUE.IN_DIM}
}

proc update_MODELPARAM_VALUE.WW { MODELPARAM_VALUE.WW PARAM_VALUE.WW } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.WW}] ${MODELPARAM_VALUE.WW}
}

proc update_MODELPARAM_VALUE.XW { MODELPARAM_VALUE.XW PARAM_VALUE.XW } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.XW}] ${MODELPARAM_VALUE.XW}
}

proc update_MODELPARAM_VALUE.AW { MODELPARAM_VALUE.AW PARAM_VALUE.AW } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AW}] ${MODELPARAM_VALUE.AW}
}

proc update_MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH}
}

