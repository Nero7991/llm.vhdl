# hw/build_bringup.tcl -- scripted board build for subsystem A on the AXU3EG.
#
#   vivado -mode batch -source hw/build_bringup.tcl -tclargs <stage>
#     stage = bd    stop after validate_bd_design (fast, for iterating)
#             synth stop after synthesis
#             all   through to a bitstream
#
# WHY A SEPARATE, SCRIPTED DESIGN.  The hardware repo's design_1/design_2 carry
# ~26 uncommitted files including a half-finished clock change, and design_1
# additionally carries video and ethernet IP this has no use for.  Editing a
# checked-in .bd there would mean committing someone else's work in progress and
# reviewing a binary blob.  This is generated from source instead, so the whole
# design is reviewable as text and reproducible from nothing.
#
# THE FAN IS NOT OPTIONAL.  fan_pwm is instantiated at the SAME address
# (0x80090000) as the running design, so the existing pl-pwm-fan driver and
# device tree bind unchanged.  Programming a bitstream without it would leave
# AA11 unconfigured, which MEASURES as the fan running at full speed -- with the
# thermal governor still reporting healthy, since it writes registers that reach
# nothing. This build shipped exactly that failure once; see the pin assertions
# below and hw/README.md.
#
# 14.4 pins ROWS_IF=4, NPORTS_W=4, AXI_DW=128, 200 MHz.  Each weight sub-region
# gets its OWN PS slave port (HP0..HP3) and the scales get HPC0: sharing a port
# would halve delivered bandwidth, and sustained bandwidth is 11's acceptance
# criterion.  DDR4-2400 x 64 bit is 19.2 GB/s peak against a 14.4 GB/s demand,
# so this is the measurement 4's premise rests on.

set stage "bd"
if {$argc > 0} { set stage [lindex $argv 0] }
# Optional: FIFO_DEPTH and MAXOUT, as build arguments rather than an edit, so a
# sweep leaves no diff behind to forget to revert.
#   vivado ... -tclargs all 1024 4
# Defaults match the RTL. See the bandwidth note in hw/README.md for why these
# two are the interesting knobs: the AXU3EG sustains 0.664 beats/cycle per port
# and every non-transfer cycle is a starve cycle, so the ports are waiting, not
# the datapath.
set fifo_depth 512
set maxout     2
if {$argc > 1} { set fifo_depth [lindex $argv 1] }
if {$argc > 2} { set maxout     [lindex $argv 2] }
puts "CONFIG stage=$stage FIFO_DEPTH=$fifo_depth MAXOUT=$maxout"

set here    [file normalize [file dirname [info script]]]
set repo    [file normalize $here/..]
set outdir  $here/mv_bringup
set part    xczu3eg-sfvc784-1-e
set fanrepo [file normalize ~/GitHub/axu3eg-pwm-ip/ip_repo]

source $here/ps_config.tcl

file delete -force $outdir
create_project mv_bringup $outdir -part $part -force

if {[file isdirectory $fanrepo]} {
  set_property ip_repo_paths [list $fanrepo] [current_project]
  update_ip_catalog -rebuild
} else {
  puts "WARNING: fan IP repo not found at $fanrepo -- the fan will NOT be driven"
}

# ---------------------------------------------------------------- sources
set rtl [list \
  util_pkg.vhd mv4i_arith_pkg.vhd stream_fifo.vhd axi_rd_port.vhd \
  weight_streamer.vhd act_mem_striped.vhd matvec_core.vhd \
  matvec_int4.vhd matvec_int4_axi.vhd matvec_int4_ip.vhd ]
foreach f $rtl { add_files -norecurse [file join $repo rtl $f] }
set_property file_type {VHDL 2008} [get_files -filter {FILE_TYPE == VHDL}]
# The module-reference TOP must not be VHDL 2008 -- Vivado refuses it outright
# ([filemgmt 56-195]).  matvec_int4_ip is deliberately plain VHDL-93: it is
# nothing but a port fan-out, so it needs no 2008 construct, and everything
# below it stays 2008.
set_property file_type {VHDL} [get_files */matvec_int4_ip.vhd]
add_files -fileset constrs_1 -norecurse $here/bringup.xdc

# ------------------------------------------------------------ block design
create_bd_design design_mv

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps]
apply_ps_config $ps

# Overrides on top of the running board's configuration: the PL clock this
# build needs, and the five slave ports.  GP0 is HPC0; GP2..GP5 are HP0..HP3.
set_property -dict [list \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {200} \
  CONFIG.PSU__USE__M_AXI_GP2 {1} \
  CONFIG.PSU__MAXIGP2__DATA_WIDTH {32} \
  CONFIG.PSU__USE__S_AXI_GP0 {1} \
  CONFIG.PSU__SAXIGP0__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP3 {1} \
  CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP4 {1} \
  CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP5 {1} \
  CONFIG.PSU__SAXIGP5__DATA_WIDTH {128} \
] $ps

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst]

set mv [create_bd_cell -type module -reference matvec_int4_ip mv]
if {$fifo_depth != 512 || $maxout != 2} {
  set_property -dict [list CONFIG.FIFO_DEPTH $fifo_depth CONFIG.MAXOUT $maxout] $mv
  # A module reference exposes its generics as CONFIG.*, but a typo silently
  # creates nothing rather than erroring -- the same shape of failure as the fan
  # pin. Read them back.
  foreach {g want} [list FIFO_DEPTH $fifo_depth MAXOUT $maxout] {
    set got [get_property CONFIG.$g $mv]
    if {$got ne $want} { error "generic $g did not take: asked $want, cell reports '$got'" }
  }
  puts "generics applied: FIFO_DEPTH=$fifo_depth MAXOUT=$maxout"
}
# A module reference's inferred interfaces default to FREQ_HZ 100 MHz, and
# every connection to a 200 MHz PS port is then a hard validation error -- the
# clock is right, only the metadata is wrong.  ASSOCIATED_BUSIF is READ-ONLY on
# a module reference, so the association cannot be declared that way and the
# frequency is stamped on each interface instead.  Read from the PS clock, not
# written as a literal: the PS PLL lands on 199,998,001 Hz, not a round 200 MHz.
set fhz [get_property CONFIG.FREQ_HZ [get_bd_pins ps/pl_clk0]]
foreach ifc {s_axi m00_axi m01_axi m02_axi m03_axi m04_axi} {
  set_property CONFIG.FREQ_HZ $fhz [get_bd_intf_pins mv/$ifc]
}

set fan ""
if {[llength [get_ipdefs -all *:axi_pwm:*]] > 0} {
  set fan [create_bd_cell -type ip -vlnv [lindex [get_ipdefs -all *:axi_pwm:*] 0] fan_pwm]
}

# ---------------------------------------------------------------- clocking
set pclk [get_bd_pins ps/pl_clk0]
connect_bd_net $pclk [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst/ext_reset_in]
connect_bd_net $pclk [get_bd_pins mv/s_axi_aclk]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins mv/s_axi_aresetn]
connect_bd_net $pclk [get_bd_pins ps/maxihpm0_lpd_aclk]
foreach p {saxihpc0_fpd_aclk saxihp0_fpd_aclk saxihp1_fpd_aclk \
           saxihp2_fpd_aclk saxihp3_fpd_aclk} {
  connect_bd_net $pclk [get_bd_pins ps/$p]
}

# ------------------------------------------------- AXI-Lite control fabric
set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ctrl_ic]
set nmi 1
if {$fan ne ""} { set nmi 2 }
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI $nmi] $ic
connect_bd_net $pclk [get_bd_pins ctrl_ic/aclk]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins ctrl_ic/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_LPD] \
                    [get_bd_intf_pins ctrl_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M00_AXI] \
                    [get_bd_intf_pins mv/s_axi]
if {$fan ne ""} {
  connect_bd_net $pclk [get_bd_pins fan_pwm/s00_axi_aclk]
  connect_bd_net [get_bd_pins rst/peripheral_aresetn] \
                 [get_bd_pins fan_pwm/s00_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M01_AXI] \
                      [get_bd_intf_pins fan_pwm/S00_AXI]
  # make_bd_PINS_external, not make_bd_INTF_pins_external.  pwm_out is a scalar
  # pin, not an interface, and the intf form applied to it does NOTHING AND
  # REPORTS NOTHING -- the first build of this design shipped with no external
  # port at all, so AA11 was left unconfigured and the fan ran flat out on a
  # floating active-low input.  The two XDC lines then matched nothing:
  #   WARNING: [Vivado 12-584] No ports matched 'pwm_out_0'
  # which is a warning, not an error, so the build "succeeded".  Hence the
  # assertion below rather than trust in the call having worked.
  make_bd_pins_external [get_bd_pins fan_pwm/pwm_out]
  if {[llength [get_bd_ports -quiet pwm_out_0]] != 1} {
    error "fan output was not externalised as pwm_out_0 -- bringup.xdc would\
           match nothing and the fan would run at full speed"
  }
}

# ----------------------------------------- one weight master per slave port
# m00..m03 are the four weight sub-regions, m04 the scale region (7.7)
set slaves {S_AXI_HP0_FPD S_AXI_HP1_FPD S_AXI_HP2_FPD S_AXI_HP3_FPD S_AXI_HPC0_FPD}
for {set i 0} {$i < 5} {incr i} {
  set m [format "m%02d_axi" $i]
  connect_bd_intf_net [get_bd_intf_pins mv/$m] \
                      [get_bd_intf_pins ps/[lindex $slaves $i]]
}

# ------------------------------------------------------------- addressing
assign_bd_address
# control apertures, matching the running board's map so the device tree and
# the pl-pwm-fan driver need no change
set_property offset 0x80000000 [get_bd_addr_segs {ps/Data/SEG_mv_reg0}]
set_property range  64K        [get_bd_addr_segs {ps/Data/SEG_mv_reg0}]
if {$fan ne ""} {
  set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data] \
             -filter {NAME =~ *fan_pwm*}]
  if {[llength $seg] > 0} {
    set_property offset 0x80090000 $seg
    set_property range  64K        $seg
  }
}

validate_bd_design
save_bd_design
write_bd_tcl -force $here/design_mv_generated.tcl
puts "BD_OK"
if {$stage eq "bd"} { puts "STAGE_BD_DONE"; return }

# Take the path make_wrapper REPORTS rather than assuming one: the output tree
# is .gen or .srcs depending on version, and the wrapper is .v or .vhd
# depending on what the BD contains.
set wrp [make_wrapper -files [get_files design_mv.bd] -top -force]
if {[llength $wrp] == 0} {
  set wrp [glob -nocomplain \
    $outdir/mv_bringup.gen/sources_1/bd/design_mv/hdl/design_mv_wrapper.* \
    $outdir/mv_bringup.srcs/sources_1/bd/design_mv/hdl/design_mv_wrapper.*]
}
if {[llength $wrp] == 0} { error "make_wrapper produced no wrapper file" }
puts "wrapper: $wrp"
add_files -norecurse $wrp
set_property top design_mv_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
puts "SYNTH_DONE"
if {$stage eq "synth"} { puts "STAGE_SYNTH_DONE"; return }

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
open_run impl_1
# min_max, NOT max.  A max-only summary reports Hold as "NA" and looks clean,
# and hold violations are a silicon-only failure class -- precisely the kind
# this project has been bitten by before.
report_timing_summary -delay_type min_max -max_paths 5 -file $here/timing_impl.rpt
report_utilization -file $here/util_impl.rpt

# GATE ON THE PIN.  Both of this design's silent-failure modes are pins, not
# logic: a bitstream with a perfect datapath and an unconfigured AA11 passes
# every timing and utilisation check and then runs the fan at full speed, or
# stops it, depending on which way the input floats.  Timing is checked by
# report_timing_summary above; nothing checks placement, so check it here.
set fanport [get_ports -quiet pwm_out_0]
if {[llength $fanport] != 1} {
  error "no pwm_out_0 port in the implemented design -- the fan is NOT driven"
}
set fanpin [get_property PACKAGE_PIN $fanport]
if {$fanpin ne "AA11"} {
  error "pwm_out_0 is on package pin '$fanpin', expected AA11 -- wrong pin means\
         the fan is not driven and something else is"
}
puts "fan: pwm_out_0 placed on $fanpin [get_property IOSTANDARD $fanport]"
puts "==== implemented timing ===="
report_timing_summary -delay_type max -max_paths 1
puts "BITSTREAM_DONE"
