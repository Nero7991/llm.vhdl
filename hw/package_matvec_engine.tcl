set root /home/orencollaco/GitHub/llama.vhdl
create_project -force tmp_mv_ip $root/hw/ip_proj_mv -part xczu3eg-sfvc784-1-e
add_files -norecurse [list \
  $root/rtl/util_pkg.vhd \
  $root/rtl/wq_l0_rom_pkg.vhd \
  $root/rtl/mac_array.vhd \
  $root/rtl/matvec_engine.vhd]
set_property file_type {VHDL 2008} [get_files *.vhd]
set_property top matvec_engine [current_fileset]
update_compile_order -fileset sources_1

file delete -force $root/ip_repo/matvec_engine_1_0
ipx::package_project -root_dir $root/ip_repo/matvec_engine_1_0 -vendor user.org -library user -taxonomy /UserIP -import_files -set_current true -force
set core [ipx::current_core]
set_property name matvec_engine $core
set_property version 1.0 $core
set_property display_name matvec_engine $core
puts "BUSIFS: [ipx::get_bus_interfaces -of_objects $core]"
ipx::associate_bus_interfaces -busif s_axi -clock s_axi_aclk $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
# See hw/package_mac_axi.tcl for the full note.  ASSOCIATED_BUSIF is an
# IP-XACT BUS PARAMETER on the clock interface, not a CONFIG.* property; the
# CONFIG.* spelling is the block-design one and raises `Unknown property
# 'CONFIG.ASSOCIATED_BUSIF' on bus_interface`.  MEASURED 2026-08-29, Vivado
# 2023.2, TRACK FLOOR.  It sat AFTER ipx::save_core, so this script exited
# non-zero having already written a correct IP.
set clkif [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]
set assoc [get_property VALUE [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $clkif]]
if {$assoc ne "s_axi"} {
    error "PACKAGE FAIL: s_axi_aclk ASSOCIATED_BUSIF is \"$assoc\", not \"s_axi\""
}
puts "CLOCK_ASSOC: $assoc"
puts "PACKAGE_DONE [file exists $root/ip_repo/matvec_engine_1_0/component.xml]"
close_project
