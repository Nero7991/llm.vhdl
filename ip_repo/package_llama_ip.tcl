# package_llama_ip.tcl -- package rtl/llama_engine_axi.vhd (+ all engine RTL) as a
# Vivado IP  user.org:user:llama_engine_axi:1.0  into ip_repo/llama_engine_axi_1_0.
# VHDL-2008 is fine INSIDE a packaged IP (unlike BD module reference).
set part  xczu3eg-sfvc784-1-e
set llama /home/orencollaco/GitHub/llama.vhdl
set ipdir $llama/ip_repo/llama_engine_axi_1_0
file delete -force $ipdir
file mkdir $ipdir

create_project -force tmp_llama_pkg /tmp/tmp_llama_pkg -part $part

set r $llama/rtl
set rtlfiles [list \
  $r/util_pkg.vhd $r/rom_init_pkg.vhd $r/rms_weights_pkg.vhd $r/wq_l0_rom_pkg.vhd \
  $r/rope_rom_pkg.vhd $r/lmhead_rom_pkg.vhd $r/embed_rom_pkg.vhd $r/fixed_luts_pkg.vhd \
  $r/fixed_pkg.vhd $r/mac_array.vhd $r/kv_mem.vhd $r/vec_mem.vhd $r/matmul_rt.vhd $r/rmsnorm.vhd \
  $r/rope.vhd $r/swiglu.vhd $r/embed.vhd $r/lm_head.vhd $r/sampler.vhd \
  $r/sampler_stream.vhd $r/softmax.vhd $r/attention_ml.vhd $r/residual.vhd \
  $r/bfp_pack.vhd $r/engine_shared.vhd $r/llama_engine_axi.vhd ]
add_files -norecurse $rtlfiles
foreach f $rtlfiles { set_property file_type {VHDL 2008} [get_files $f] }
set_property top llama_engine_axi [current_fileset]
update_compile_order -fileset sources_1

# Package with source import (copies RTL into the IP, self-contained like matvec).
ipx::package_project -root_dir $ipdir -vendor user.org -library user \
  -taxonomy /UserIP -import_files -force

set core [ipx::current_core]
set_property vendor       user.org             $core
set_property library      user                 $core
set_property name         llama_engine_axi     $core
set_property version      1.0                  $core
set_property display_name llama_engine_axi_v1_0 $core
set_property vendor_display_name {user} $core

# Ensure the AXI4-Lite slave + its clock/reset are inferred.  package_project
# usually auto-infers from s_axi_* / s_axi_aclk / s_axi_aresetn naming; make the
# clock<->interface + reset associations explicit and robust.
ipx::infer_bus_interfaces xilinx.com:interface:aximm_rtl:1.0 $core
catch { ipx::associate_bus_interfaces -busif s_axi -clock s_axi_aclk $core }
catch { ipx::associate_bus_interfaces -clock s_axi_aclk -reset s_axi_aresetn $core }

ipx::create_xgui_files $core
ipx::update_checksums   $core
ipx::check_integrity    $core
ipx::save_core          $core

puts "AXI_IFS: [ipx::get_bus_interfaces -of_objects $core]"
puts "PACKAGE_DONE"
close_project
