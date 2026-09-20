# pfRoot -- the repo root, DERIVED from this script's own location rather than
# written in as a literal, so the run works from any checkout path and survives
# the repo directory being renamed (TRACK PATHFREE, 2026-09-20).  Probed rather
# than trusted: a wrong root would otherwise read_vhdl nothing and fail much
# later as a missing entity.
set pfRoot [file normalize [file join [file dirname [info script]] ..]]
if {![file exists $pfRoot/rtl/util_pkg.vhd]} {
    error "pfRoot: derived repo root '$pfRoot' does not contain rtl/util_pkg.vhd. Source this script by its path in the tree."
}
set root $pfRoot
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
# ASSOCIATED_BUSIF is an IP-XACT BUS PARAMETER on the clock interface, not a
# CONFIG.* property of it.  In component.xml it is a <spirit:parameter> named
# ASSOCIATED_BUSIF inside the s_axi_aclk bus interface's <spirit:parameters>,
# so it is read through ipx::get_bus_parameters and its VALUE property.
#
# The CONFIG.* form is the BLOCK-DESIGN spelling (`get_property
# CONFIG.ASSOCIATED_BUSIF [get_bd_pins .../core_clk]`, as in
# hw/fk33/build_fk33_pcieep.tcl:904) and it does NOT exist on an ipx object.
# MEASURED 2026-08-29, Vivado 2023.2, TRACK FLOOR, on this very core:
#   CONFIG.ASSOCIATED_BUSIF   -> rc=1 Unknown property 'CONFIG.ASSOCIATED_BUSIF' on bus_interface
#   bare ASSOCIATED_BUSIF     -> rc=1 Unknown property 'ASSOCIATED_BUSIF' on bus_interface
#   bus parameter VALUE       -> rc=0 s_axi
# Because it sat AFTER ipx::save_core, the error aborted the script with a
# non-zero status having already written a correct IP: a caller gating on the
# exit code would have believed packaging failed.  See
# ip_repo/check_ip_sync.py's "honest weakness" note, which recorded it.
set clkif [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]
set assoc [get_property VALUE [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $clkif]]
# ipx::associate_bus_interfaces is exactly the shape of call that can do
# nothing quietly, so read it back and REFUSE, the way build_fk33_pcieep.tcl
# does for the block-design spelling.  Without the association every AXI
# interface defaults to 100 MHz downstream.
if {$assoc ne "s_axi"} {
    error "PACKAGE FAIL: s_axi_aclk ASSOCIATED_BUSIF is \"$assoc\", not \"s_axi\""
}
puts "CLOCK_ASSOC: $assoc"
puts "PACKAGE_DONE [file exists $root/ip_repo/mac_axi_1_0/component.xml]"
close_project
