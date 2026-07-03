set root /home/orencollaco/GitHub/llama.vhdl
create_project -force tmp_mac_ip $root/hw/ip_proj -part xczu3eg-sfvc784-1-e
add_files -norecurse [list $root/rtl/util_pkg.vhd $root/rtl/mac_array.vhd $root/rtl/mac_axi.vhd]
set_property file_type {VHDL 2008} [get_files *.vhd]
set_property top mac_axi [current_fileset]
update_compile_order -fileset sources_1

file delete -force $root/ip_repo/mac_axi_1_0
ipx::package_project -root_dir $root/ip_repo/mac_axi_1_0 -vendor user.org -library user -taxonomy /UserIP -import_files -set_current true -force
set core [ipx::current_core]
set_property name mac_axi $core
set_property version 1.0 $core
set_property display_name mac_axi $core
puts "BUSIFS: [ipx::get_bus_interfaces -of_objects $core]"
# single call: associates the s_axi bus with its clock (and, via the clock's
# inferred ASSOCIATED_RESET, the s_axi_aresetn reset)
ipx::associate_bus_interfaces -busif s_axi -clock s_axi_aclk $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
puts "CLOCK_ASSOC: [get_property CONFIG.ASSOCIATED_BUSIF [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]]"
puts "PACKAGE_DONE [file exists $root/ip_repo/mac_axi_1_0/component.xml]"
close_project
