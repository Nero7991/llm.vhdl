# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "ADDR_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "AXI_DW" -parent ${Page_0}
  ipgui::add_param $IPINST -name "BLK" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FIFO_DEPTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAXB" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAXCOLS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAXROWS_BFP" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ROWS_IF" -parent ${Page_0}


}

proc update_PARAM_VALUE.ADDR_W { PARAM_VALUE.ADDR_W } {
	# Procedure called to update ADDR_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ADDR_W { PARAM_VALUE.ADDR_W } {
	# Procedure called to validate ADDR_W
	return true
}

proc update_PARAM_VALUE.AXI_DW { PARAM_VALUE.AXI_DW } {
	# Procedure called to update AXI_DW when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AXI_DW { PARAM_VALUE.AXI_DW } {
	# Procedure called to validate AXI_DW
	return true
}

proc update_PARAM_VALUE.BLK { PARAM_VALUE.BLK } {
	# Procedure called to update BLK when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.BLK { PARAM_VALUE.BLK } {
	# Procedure called to validate BLK
	return true
}

proc update_PARAM_VALUE.FIFO_DEPTH { PARAM_VALUE.FIFO_DEPTH } {
	# Procedure called to update FIFO_DEPTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FIFO_DEPTH { PARAM_VALUE.FIFO_DEPTH } {
	# Procedure called to validate FIFO_DEPTH
	return true
}

proc update_PARAM_VALUE.MAXB { PARAM_VALUE.MAXB } {
	# Procedure called to update MAXB when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAXB { PARAM_VALUE.MAXB } {
	# Procedure called to validate MAXB
	return true
}

proc update_PARAM_VALUE.MAXCOLS { PARAM_VALUE.MAXCOLS } {
	# Procedure called to update MAXCOLS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAXCOLS { PARAM_VALUE.MAXCOLS } {
	# Procedure called to validate MAXCOLS
	return true
}

proc update_PARAM_VALUE.MAXROWS_BFP { PARAM_VALUE.MAXROWS_BFP } {
	# Procedure called to update MAXROWS_BFP when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAXROWS_BFP { PARAM_VALUE.MAXROWS_BFP } {
	# Procedure called to validate MAXROWS_BFP
	return true
}

proc update_PARAM_VALUE.ROWS_IF { PARAM_VALUE.ROWS_IF } {
	# Procedure called to update ROWS_IF when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ROWS_IF { PARAM_VALUE.ROWS_IF } {
	# Procedure called to validate ROWS_IF
	return true
}


proc update_MODELPARAM_VALUE.BLK { MODELPARAM_VALUE.BLK PARAM_VALUE.BLK } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.BLK}] ${MODELPARAM_VALUE.BLK}
}

proc update_MODELPARAM_VALUE.ROWS_IF { MODELPARAM_VALUE.ROWS_IF PARAM_VALUE.ROWS_IF } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ROWS_IF}] ${MODELPARAM_VALUE.ROWS_IF}
}

proc update_MODELPARAM_VALUE.AXI_DW { MODELPARAM_VALUE.AXI_DW PARAM_VALUE.AXI_DW } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AXI_DW}] ${MODELPARAM_VALUE.AXI_DW}
}

proc update_MODELPARAM_VALUE.ADDR_W { MODELPARAM_VALUE.ADDR_W PARAM_VALUE.ADDR_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ADDR_W}] ${MODELPARAM_VALUE.ADDR_W}
}

proc update_MODELPARAM_VALUE.MAXCOLS { MODELPARAM_VALUE.MAXCOLS PARAM_VALUE.MAXCOLS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAXCOLS}] ${MODELPARAM_VALUE.MAXCOLS}
}

proc update_MODELPARAM_VALUE.MAXROWS_BFP { MODELPARAM_VALUE.MAXROWS_BFP PARAM_VALUE.MAXROWS_BFP } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAXROWS_BFP}] ${MODELPARAM_VALUE.MAXROWS_BFP}
}

proc update_MODELPARAM_VALUE.FIFO_DEPTH { MODELPARAM_VALUE.FIFO_DEPTH PARAM_VALUE.FIFO_DEPTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FIFO_DEPTH}] ${MODELPARAM_VALUE.FIFO_DEPTH}
}

proc update_MODELPARAM_VALUE.MAXB { MODELPARAM_VALUE.MAXB PARAM_VALUE.MAXB } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAXB}] ${MODELPARAM_VALUE.MAXB}
}

