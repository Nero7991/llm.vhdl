# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "C_S_AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAXPOS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAXTOK" -parent ${Page_0}
  ipgui::add_param $IPINST -name "NGEN" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ROM_DIR" -parent ${Page_0}


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

proc update_PARAM_VALUE.MAXPOS { PARAM_VALUE.MAXPOS } {
	# Procedure called to update MAXPOS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAXPOS { PARAM_VALUE.MAXPOS } {
	# Procedure called to validate MAXPOS
	return true
}

proc update_PARAM_VALUE.MAXTOK { PARAM_VALUE.MAXTOK } {
	# Procedure called to update MAXTOK when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAXTOK { PARAM_VALUE.MAXTOK } {
	# Procedure called to validate MAXTOK
	return true
}

proc update_PARAM_VALUE.NGEN { PARAM_VALUE.NGEN } {
	# Procedure called to update NGEN when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.NGEN { PARAM_VALUE.NGEN } {
	# Procedure called to validate NGEN
	return true
}

proc update_PARAM_VALUE.ROM_DIR { PARAM_VALUE.ROM_DIR } {
	# Procedure called to update ROM_DIR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ROM_DIR { PARAM_VALUE.ROM_DIR } {
	# Procedure called to validate ROM_DIR
	return true
}


proc update_MODELPARAM_VALUE.MAXPOS { MODELPARAM_VALUE.MAXPOS PARAM_VALUE.MAXPOS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAXPOS}] ${MODELPARAM_VALUE.MAXPOS}
}

proc update_MODELPARAM_VALUE.NGEN { MODELPARAM_VALUE.NGEN PARAM_VALUE.NGEN } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.NGEN}] ${MODELPARAM_VALUE.NGEN}
}

proc update_MODELPARAM_VALUE.MAXTOK { MODELPARAM_VALUE.MAXTOK PARAM_VALUE.MAXTOK } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAXTOK}] ${MODELPARAM_VALUE.MAXTOK}
}

proc update_MODELPARAM_VALUE.ROM_DIR { MODELPARAM_VALUE.ROM_DIR PARAM_VALUE.ROM_DIR } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ROM_DIR}] ${MODELPARAM_VALUE.ROM_DIR}
}

proc update_MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH}
}

