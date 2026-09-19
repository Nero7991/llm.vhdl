# GENERATED from hw/fk33/build_fk33_i2cprobe.tcl by hw/fk33/gen_pcieep.py
# -- do not hand-edit; regenerate so the probe build's fixes are not lost.
#
# PCIe Gen3 x4 XDMA endpoint for the FK33.  The first bitstream in this project
# with a PCIe endpoint at all.
#
# What the host sees when this works:
#   BAR (XDMA config)     the DMA engine's own registers
#   BAR (AXI-Lite, 128K)  0x3400  SYSMON die temperature
#                         0x3404  SYSMON VCCINT
#                         0x9000  GPIO ch1 DATA  bit0=SCL(BB24) bit1=SDA(BA24)
#                         0x9004  GPIO ch1 TRI   1 = released, 0 = driven low
#                         0x9008  GPIO ch2 DATA  the 7 board LEDs, via led_inv
#                         0xA000  ID magic       READ-ONLY, always 0x464B3333
#                         0xA008  ID build date  READ-ONLY, 0x20260827 (BCD)
#                         0x10000 scratch RAM    8 KB, read/write, drives nothing
#   /dev/xdma0_h2c_0      writes into HBM, file offset == HBM byte address
#   /dev/xdma0_c2h_0      reads  from HBM, same addressing
#     0x0_0000_0000 .. 0x1_FFFF_FFFF   HBM, 8 GB
#     0x2_0000_0000 .. 0x2_0000_FFFF   64 KB BRAM, the DMA loopback target
#
# The identity register is the one read that distinguishes "the whole path
# works" from "a driver loaded".  0x00000000 and 0xFFFFFFFF are what a BAR that
# is mapped but unanswered returns, and neither can be mistaken for "FK33".
#
# HBM is flat and contiguous from the DMA master: 0x0_0000_0000 .. 0x1_FFFF_FFFF,
# 8 GB, MEM00-15 through SAXI_00 and MEM16-31 through SAXI_16, with the
# redundant cross-stack routes excluded so there is exactly one path to each.
#
# WATCH OUT -- the whole AXI fabric above is clocked by xdma/axi_aclk, which is
# derived from the PCIe reference clock, and held in reset until the link is
# up.  On the bench, with no slot, there is no reference clock, so all of it is
# EXPECTED to look completely dead over JTAG.  That is not a broken build.
#
# THE AUX DOMAIN IS THE EXCEPTION, and the reason this build exists in its
# current form.  It runs on the FK33's 200 MHz board oscillator (BC26/BC27)
# through a plain BUFG -- no MMCM, nothing to lock, nothing anyone can hold in
# reset -- and is readable over a THIRD JTAG-AXI master, jtag_aux, whose entire
# branch is on that clock.  There is no wire at all between it and xdma:
#
#   jtag_aux (its own address space, JTAG only, never on the PCIe BAR)
#     0x0000  AUX_MAGIC     0x41555831 = "AUX1"
#     0x0008  AUX_VERSION   0x20260828
#     0x1000  UCLK_TICKS    free-running; 1 tick per 128 xdma/axi_aclk cycles
#     0x1008  UCLK_HZ       measured xdma/axi_aclk in Hz.  250000000 = the PCIe
#                           hard block is clocked, so a down link is a TRAINING
#                           failure.  0 with PERST# HIGH means the host is not
#                           driving a reference clock.  0 with PERST# LOW just
#                           means we are held in reset
#     0x2000  AUX_STATUS    [0] PERST# level     [1] PERST# level at config
#                           [2] PERST# ever low  [3] PERST# ever high
#                           [7:4] PERST# deassertion count, saturating at 15
#                           [8] xdma axi_aresetn [9] axi_aresetn ever released
#                           [10] user_lnk_up     [11] user_lnk_up ever
#                           [12] uclk alive      [13] uclk ever ticked
#                           [14] PERST_MS valid  [15] aux reset released
#                           [31:16] 0xA5A5, fixed
#     0x2008  POT_STATUS    [0] done  [1] failed  [2] bus owned  [3] saw a NACK
#                           [5:4] transaction  [10:8] failure reason
#                           [15:12] attempts    [23:16] wiper last read back
#                           [31:24] the ONLY wiper this bitstream can write.
#                                   It must read 0x44 (68 = 0.717 V).
#     0x3000  AUX_MS        milliseconds since configuration
#     0x3008  PERST_MS      AUX_MS at the FIRST deassertion of PERST#
#
# PERST_MS is the flash-boot timing measurement.  AUX_STATUS[1] = 0 with
# PERST_MS valid means the FPGA was configured and watching BEFORE the host
# released reset.  AUX_STATUS[1] = 1 means reset had already been released when
# configuration finished, which is the loss condition and today is
# indistinguishable from a card that never worked.
#
# The aux domain also raises VCCINT on its own, with no host and no JTAG, a few
# milliseconds after configuration.  See rtl/fk33_aux.vhd.
#
# THERMAL PROTECTION.  rtl/fk33_thermal.vhd, also on the aux domain, halts the
# compute datapath at die 90 C / HBM code 85 and resumes at 75 / 70.  It halts
# ARITHMETIC ONLY: the link, the AXI fabric, the aux domain and every register
# below stay alive, because a card that vanishes when it overheats cannot be
# asked what happened.  SYSMON's own over-temperature alarm is armed at 101 C
# and is a die-destruction backstop, not management -- above the -2LE sustained
# rating of 100 C, silent about the HBM stacks' 95 C recommendation, and its
# consequence is a device shutdown.  The same five words appear twice:
#
#   jtag_aux (link down)          AXI-Lite BAR (host)
#     0x4000 THERM_STATUS           0xB000 THERM_STATUS
#     0x4008 THERM_TEMPS            0xB008 THERM_TEMPS
#     0x5000 THERM_PEAK             0xC000 THERM_PEAK
#     0x5008 THERM_TRIP             0xC008 THERM_TRIP
#     0x6000 THERM_CTL   (write)    0xD000 THERM_CTL   (write)
#     0x6008 THERM_CANARY           0xD008 THERM_CANARY
#
# THERM_STATUS[31] is a fabric constant 1, so a bitstream WITHOUT the guard
# reads 0 there and "is this card protected" is one read.  THERM_CTL needs the
# key 0xC1EA in [31:16]; [0] clears the trip latch, [1] clears the peak-hold,
# both edge triggered, and neither releases a halt the live sensors justify.
#
# GENERATED from build_fk33_firstlight.tcl by hw/fk33/gen_i2cprobe.py
# -- do not hand-edit; regenerate.
#
# I2C PROBE bitstream.  Identical to first light except that axi_iic is replaced
# by a dual-channel axi_gpio, giving raw control of the two I2C balls:
#
#   0x9000  GPIO_DATA   channel 1, bit0 = BB24 (scl), bit1 = BA24 (sda)
#   0x9004  GPIO_TRI    channel 1, 1 = input/released, 0 = driven.  Resets to
#                       all-ones, so this bitstream drives NOTHING until asked.
#   0x9008  GPIO2_DATA  channel 2, the 7 board LEDs (via led_inv, active low)
#   0x900c  GPIO2_TRI   unused, channel 2 is all-outputs
#
# The question it exists to answer: with both pins released, do they read HIGH?
# HIGH means a powered pull-up, so that bus is real and the devices are simply
# elsewhere.  LOW or indeterminate means those balls are not a live I2C bus on
# this board, and SQRL's 0x2C/0x18/0x19/0x1F addresses never applied to it.
#
# GENERATED from SQRL_FK33/projects/fk33_example.tcl by hw/fk33/gen_firstlight.py
# -- do not hand-edit; regenerate so upstream fixes are not lost.
#
# FIRST-LIGHT bitstream for the FK33: JTAG only, no PCIe.
# Four changes from upstream, each of which would otherwise stop the build or
# produce the wrong artifact:
#
#  1. EnablePCIe 0.  docs/fpga-hardware-recon.md establishes that both planned
#     experiments are reachable over JTAG alone, so first light needs nothing
#     resolved about PCIe, ACS or P2P.  Fewer moving parts on the first power-on.
#
#  2. The Vivado version gate is removed.  Upstream hard-errors unless the tool
#     is exactly 2022.2; this install is 2023.2 and installing a second Vivado
#     is ~100 GB.  This is the risky change: block designs carry IP versions, so
#     an explicit upgrade_ip pass is added below and its output must be read,
#     not assumed.
#
#  3. Part forced to xcvu33p-fsvh2104-2L-e, NOT the -2-e upstream hardcodes.
#     Upstream contradicts its own board file, which says -2L
#     (board_files/sqrl_fk33/1.1/board.xml).  -2 is the FASTER grade, so
#     building for it and deploying on -2L silicon signs timing off against
#     hardware we do not have.  -2L is the conservative direction.  Settle it
#     empirically once the card is in: Vivado hardware manager reports the real
#     part from the IDCODE, and if it is genuinely -2 this can be relaxed for
#     free headroom.
#
#  4. Upstream never builds anything -- it creates the project and stops.
#     Synthesis, implementation and write_bitstream are appended.
#

set ProjectName fk33_pcieep
set ProjectFolder ./$ProjectName

set EnablePCIe 1
set HBMGlobalSwitch 1

#Remove unnecessary files.
set file_list [glob -nocomplain webtalk*.*]
foreach name $file_list {
    file delete $name
}

#Delete old project if folder already exists.
if {[file exists .Xil]} { 
    file delete -force .Xil
}

#Delete old project if folder already exists.
if {[file exists "$ProjectFolder"]} { 
    file delete -force $ProjectFolder
}

# paths pinned to the upstream checkout -- see header note 7
set scriptPath "/home/orencollaco/GitHub/SQRL_FK33/projects"
set sourceRoot "/home/orencollaco/GitHub/SQRL_FK33"
#puts stdout $scriptPath
#puts stdout [join [lrange [file split [file dirname [info script]]] 0 end-2] "/"]
#return -code 1

# version gate removed -- see header note 2
puts "INFO: building with Vivado [version -short] (upstream targets 2022.2)"

create_project $ProjectName ./$ProjectName -part "xcvu33p-fsvh2104-2L-e"

# ---- aux RTL (gen_pcieep.py) ----------------------------------------------
# Added before the block design so `create_bd_cell -type module -reference
# fk33_aux` can find it.  Absolute path because the build runs in a scratch
# directory, not here.
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_aux.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_thermal.vhd
update_compile_order -fileset sources_1

# ---- subsystem A RTL (gen_pcieep.py) --------------------------------------
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/util_pkg.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/mv4i_arith_pkg.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/matvec_int4_desc_pkg.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/stream_fifo.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/async_fifo.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/axi_rd_fsm.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/axi_rd_port.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/weight_streamer.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/act_mem_striped.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/matvec_core.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/matvec_int4.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/matvec_int4_desc_axi.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_engine.vhd
update_compile_order -fileset sources_1

# ---- host seam RTL (gen_pcieep.py) ----------------------------------------
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/fk33_seam.vhd
update_compile_order -fileset sources_1

# ---- subsystems B/C/D RTL (gen_pcieep.py) ---------------------------------
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/bc_port_grant.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/a_desc_adapter.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/a_job_counter.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_emit.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/fixed_luts_pkg.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_gate.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_quant.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_mac_array.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/divider_rs.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_recip.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_rope.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_score_q12.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_softmax.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/imrope_pkg.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_twiddle.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/fixed_pkg.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_rs.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_block.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_axi.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_head_emit.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_silu.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_y_emit.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_bf.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_emit_chain.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_exp_capture.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_recur_pipe.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_scalar.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/l2norm_rs.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_block.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_job_seq.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv_tap_mem.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_exp_mem.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_axi.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_mem.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_store.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/model_cfg_pkg.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/llama_map_pkg.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/region_mem.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/vec_mem.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_rs_mem.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/sampler_stream.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/seq_desc_fetch.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/seq_opdec.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/seq_region_lock.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/seq_vec_issue.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/seq_vec_res.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/rtl/fk33_llama_top.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_bc_grant.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_card.vhd
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/bc_port_grant.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/a_desc_adapter.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/a_job_counter.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_emit.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/fixed_luts_pkg.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_gate.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_quant.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_mac_array.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/divider_rs.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_recip.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_rope.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_score_q12.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_softmax.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/imrope_pkg.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_twiddle.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/fixed_pkg.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_rs.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_block.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_axi.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_head_emit.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_silu.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_y_emit.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_bf.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_emit_chain.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_exp_capture.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_recur_pipe.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_scalar.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/l2norm_rs.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_block.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_job_seq.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv_tap_mem.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_exp_mem.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_axi.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_mem.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_store.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/model_cfg_pkg.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/llama_map_pkg.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/region_mem.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/vec_mem.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_rs_mem.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/sampler_stream.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/seq_desc_fetch.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/seq_opdec.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/seq_region_lock.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/seq_vec_issue.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/seq_vec_res.vhd}]
set_property FILE_TYPE {VHDL 2008} [get_files {/home/orencollaco/GitHub/llama.vhdl/rtl/fk33_llama_top.vhd}]
# READ BACK.  A path that did not match leaves the file at VHDL-93 and
# the failure is 400 lines later in a generated bd.v, naming neither
# the file nor the standard.
foreach f {/home/orencollaco/GitHub/llama.vhdl/rtl/bc_port_grant.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/a_desc_adapter.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/a_job_counter.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_emit.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/fixed_luts_pkg.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_gate.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_quant.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_mac_array.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/divider_rs.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_recip.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_rope.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_score_q12.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_softmax.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/imrope_pkg.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_twiddle.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/fixed_pkg.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_rs.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_block.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_axi.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_head_emit.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_silu.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_y_emit.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_bf.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_emit_chain.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_exp_capture.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_recur_pipe.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_scalar.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/l2norm_rs.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_block.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_job_seq.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv_tap_mem.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_exp_mem.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_axi.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_mem.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_store.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/model_cfg_pkg.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/llama_map_pkg.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/region_mem.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/vec_mem.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_rs_mem.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/sampler_stream.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/seq_desc_fetch.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/seq_opdec.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/seq_region_lock.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/seq_vec_issue.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/seq_vec_res.vhd /home/orencollaco/GitHub/llama.vhdl/rtl/fk33_llama_top.vhd} {
    set t [get_property FILE_TYPE [get_files -quiet $f]]
    if {$t ne "VHDL 2008"} {
        error "FK33_CARD FAIL: $f is FILE_TYPE \"$t\", not VHDL 2008."
    }
}
puts "FK33_CARD 48 sources set to VHDL 2008 (the two wrapper tops stay VHDL-93)"
update_compile_order -fileset sources_1

#create_project $ProjectName ./$ProjectName -part xcvu33p-fsvh2104-2-e-es1

set_param synth.maxThreads 8
set_param general.maxThreads 12


# injected by gen_firstlight.py -- see header note 6
proc exclude_seg_if {seg space} {
    set sp [get_bd_addr_spaces -quiet $space]
    if {[llength $sp] == 0} {
        return
    }
    set sg [get_bd_addr_segs -quiet $seg]
    if {[llength $sg] == 0} {
        return
    }
    exclude_bd_addr_seg $sg -target_address_space $sp
}

create_bd_design "bd"

create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 hbm
set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} CONFIG.USER_MEMORY_DISPLAY {8192}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_HBM_REF_CLK_1 {200}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_AXI_INPUT_CLK_FREQ {250} ] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_AXI_INPUT_CLK1_FREQ {250}] [get_bd_cells hbm]

if {$HBMGlobalSwitch == 0} {
    set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {FALSE} CONFIG.USER_SWITCH_ENABLE_01 {FALSE}] [get_bd_cells hbm]
    set_property -dict [list CONFIG.USER_MEMORY_DISPLAY {4608} CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_MC_ENABLE_01 {FALSE} CONFIG.USER_MC_ENABLE_02 {FALSE} CONFIG.USER_MC_ENABLE_03 {FALSE} CONFIG.USER_MC_ENABLE_04 {FALSE} CONFIG.USER_MC_ENABLE_05 {FALSE} CONFIG.USER_MC_ENABLE_06 {FALSE} CONFIG.USER_MC_ENABLE_07 {FALSE} CONFIG.USER_SAXI_01 {false}] [get_bd_cells hbm]
    set_property -dict [list CONFIG.USER_MEMORY_DISPLAY {1024} CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK} CONFIG.USER_MC_ENABLE_09 {FALSE} CONFIG.USER_MC_ENABLE_10 {FALSE} CONFIG.USER_MC_ENABLE_11 {FALSE} CONFIG.USER_MC_ENABLE_12 {FALSE} CONFIG.USER_MC_ENABLE_13 {FALSE} CONFIG.USER_MC_ENABLE_14 {FALSE} CONFIG.USER_MC_ENABLE_15 {FALSE} CONFIG.USER_SAXI_01 {false} CONFIG.USER_SAXI_17 {false} CONFIG.USER_SAXI_31 {false}] [get_bd_cells hbm]
} else {
    set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK}] [get_bd_cells hbm]
    set_property -dict [list CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK} CONFIG.USER_SAXI_30 {false} CONFIG.USER_SAXI_31 {false}] [get_bd_cells hbm]
    set_property -dict [list CONFIG.USER_MC0_TRAFFIC_OPTION {Random} CONFIG.USER_MC1_TRAFFIC_OPTION {Random} CONFIG.USER_MC2_TRAFFIC_OPTION {Random} CONFIG.USER_MC3_TRAFFIC_OPTION {Random} CONFIG.USER_MC4_TRAFFIC_OPTION {Random} CONFIG.USER_MC5_TRAFFIC_OPTION {Random} CONFIG.USER_MC6_TRAFFIC_OPTION {Random} CONFIG.USER_MC7_TRAFFIC_OPTION {Random} CONFIG.USER_MC8_TRAFFIC_OPTION {Random} CONFIG.USER_MC9_TRAFFIC_OPTION {Random} CONFIG.USER_MC10_TRAFFIC_OPTION {Random} CONFIG.USER_MC11_TRAFFIC_OPTION {Random} CONFIG.USER_MC12_TRAFFIC_OPTION {Random} CONFIG.USER_MC13_TRAFFIC_OPTION {Random} CONFIG.USER_MC14_TRAFFIC_OPTION {Random} CONFIG.USER_MC15_TRAFFIC_OPTION {Random}] [get_bd_cells hbm]
}

set_property CONFIG.USER_APB_EN false [get_bd_cells hbm]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 hbm_reset

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property CONFIG.RESET_TYPE ACTIVE_LOW [get_bd_cells /clk_wiz_0]
set_property -dict [list CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000}] [get_bd_cells clk_wiz_0]
set_property -dict [list CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]
set_property -dict [list CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {75.000}] [get_bd_cells clk_wiz_0]
                                                                                                     
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_hbm
set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {64} CONFIG.M_AXI_ADDR_WIDTH {64}] [get_bd_cells jtag_hbm]
set_property -dict [list CONFIG.M_HAS_BURST {0}] [get_bd_cells jtag_hbm]

#Add AXI I2C to control voltages
# ---- I2C PROBE ------------------------------------------------------------
# axi_iic replaced by a dual-channel axi_gpio.  Channel 1 is two bidirectional
# bits on the I2C balls BB24 (scl) / BA24 (sda), released at reset:
# C_TRI_DEFAULT is all-ones so the pins come up as inputs and this bitstream
# cannot drive the board's bus until told to.  That matters -- if some other
# controller does own that bus, powering up driving it would be the one way to
# do real damage.  Channel 2 keeps the 7 LED bits so the board stays visibly
# controllable.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0
set_property -dict [list CONFIG.C_GPIO_WIDTH {2} CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO2_WIDTH {7} CONFIG.C_ALL_INPUTS {0} CONFIG.C_ALL_OUTPUTS {0} \
    CONFIG.C_ALL_INPUTS_2 {0} CONFIG.C_ALL_OUTPUTS_2 {1} \
    CONFIG.C_TRI_DEFAULT {0xFFFFFFFF} CONFIG.C_DOUT_DEFAULT {0x00000000} \
    CONFIG.C_DOUT_DEFAULT_2 {0x00000040}] [get_bd_cells axi_gpio_0]
# [gen_pcieep] axi_gpio_0/GPIO is NOT made external here any more.  Its
# gpio_io_o / gpio_io_t / gpio_io_i now go into fk33_aux_0, which arbitrates
# between this GPIO and the autonomous VCCINT controller and instantiates the
# IOBUFs itself.  The external inout port is created there with the same name,
# i2cprobe_tri_io, so fk33_pcieep.xdc is unchanged for those two balls.

create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 led_inv
set_property -dict [list CONFIG.C_SIZE {7} CONFIG.C_OPERATION {not} CONFIG.LOGO_FILE {data/sym_notgate.png}] [get_bd_cells led_inv]
connect_bd_net [get_bd_pins led_inv/Op1] [get_bd_pins axi_gpio_0/gpio2_io_o]
make_bd_pins_external  [get_bd_pins led_inv/Res]
set_property name led [get_bd_ports Res_0]

#Add AXI interconnect IP
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 pcie2hbm
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells pcie2hbm]

connect_bd_intf_net [get_bd_intf_pins jtag_hbm/M_AXI] [get_bd_intf_pins pcie2hbm/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2hbm/M00_AXI] [get_bd_intf_pins hbm/SAXI_00]
connect_bd_intf_net [get_bd_intf_pins pcie2hbm/M01_AXI] [get_bd_intf_pins hbm/SAXI_16]

connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/APB_0_PRESET_N]
connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/APB_1_PRESET_N]

connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins hbm_reset/dcm_locked]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_0_PCLK]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_1_PCLK]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm_reset/slowest_sync_clk]
#connect_bd_net [get_bd_pins clk_wiz_0/clk_in1] [get_bd_pins util_ds_buf_1/IBUF_OUT]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_0]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_1]

#PCIe M_AXI_LITE
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 pcie2axil
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]

create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axil
connect_bd_intf_net [get_bd_intf_pins jtag_axil/M_AXI] [get_bd_intf_pins pcie2axil/S00_AXI]


#Add SystemManagement
create_bd_cell -type ip -vlnv xilinx.com:ip:system_management_wiz:1.3 system_management_wiz_0
set_property -dict [list CONFIG.USER_TEMP_ALARM {false} CONFIG.ENABLE_VBRAM_ALARM {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.TEMPERATURE_ALARM_OT_TRIGGER {101} CONFIG.TEMPERATURE_ALARM_OT_RESET {99}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.VCCINT_ALARM_LOWER {0.70} CONFIG.VCCINT_ALARM_UPPER {0.89}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.VCCAUX_ALARM_UPPER {1.85} CONFIG.VBRAM_ALARM_LOWER {0.82}] [get_bd_cells system_management_wiz_0] 
set_property -dict [list CONFIG.VBRAM_ALARM_UPPER {0.88} CONFIG.REFERENCE {External}] [get_bd_cells system_management_wiz_0]
# ---- THERMAL (gen_pcieep.py): see item 11 in the header --------------------
set_property -dict [list CONFIG.ENABLE_TEMP_BUS {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_TEMP_ALARM {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.TEMPERATURE_ALARM_TRIGGER {90} CONFIG.TEMPERATURE_ALARM_RESET {75}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY0_ALARM {true} CONFIG.USER_SUPPLY0_BANK {224} CONFIG.SELECT_USER_SUPPLY0 {AVCC}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY1_ALARM {true} CONFIG.USER_SUPPLY1_BANK {224} CONFIG.SELECT_USER_SUPPLY1 {MGTVCCAUX}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY2_ALARM {true} CONFIG.USER_SUPPLY2_BANK {224} CONFIG.SELECT_USER_SUPPLY2 {AVTT}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY3_ALARM {true} CONFIG.USER_SUPPLY3_BANK {64} CONFIG.SELECT_USER_SUPPLY3 {VCCO}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY0_ALARM_LOWER {1.19} CONFIG.USER_SUPPLY0_ALARM_UPPER {1.21}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY1_ALARM_LOWER {1.79} CONFIG.USER_SUPPLY1_ALARM_UPPER {1.81}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY2_ALARM_LOWER {1.19} CONFIG.USER_SUPPLY2_ALARM_UPPER {1.21}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY3_ALARM_LOWER {1.19} CONFIG.USER_SUPPLY3_ALARM_UPPER {1.21}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VUSER0 {true} CONFIG.CHANNEL_ENABLE_VUSER1 {true} CONFIG.CHANNEL_ENABLE_VUSER2 {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VP_VN {false} CONFIG.CHANNEL_ENABLE_VAUXP0_VAUXN0 {false} CONFIG.CHANNEL_ENABLE_VAUXP4_VAUXN4 {false}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VAUXP5_VAUXN5 {false} CONFIG.CHANNEL_ENABLE_VAUXP8_VAUXN8 {false} CONFIG.CHANNEL_ENABLE_VAUXP12_VAUXN12 {false}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VAUXP13_VAUXN13 {true} CONFIG.ANALOG_BANK_SELECTION {66} CONFIG.COMMON_N_VAUXP13_VAUXN13 {false} CONFIG.COMMON_N_SOURCE {Vaux13}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VP_VN {true} CONFIG.CHANNEL_ENABLE_VAUXP0_VAUXN0 {true} CONFIG.CHANNEL_ENABLE_VAUXP4_VAUXN4 {true} ] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VAUXP5_VAUXN5 {true} CONFIG.CHANNEL_ENABLE_VAUXP8_VAUXN8 {true} CONFIG.CHANNEL_ENABLE_VAUXP12_VAUXN12 {true}] [get_bd_cells system_management_wiz_0]

set_property -dict [list CONFIG.NUM_MI {2}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/M01_AXI] [get_bd_intf_pins system_management_wiz_0/S_AXI_LITE]

make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vp_Vn]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux0]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux4]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux5]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux8]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux12]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux13]


set_property name Vp_Vn [get_bd_intf_ports Vp_Vn_0]
set_property name Vaux0 [get_bd_intf_ports Vaux0_0]
set_property name Vaux4 [get_bd_intf_ports Vaux4_0]
set_property name Vaux5 [get_bd_intf_ports Vaux5_0]
set_property name Vaux8 [get_bd_intf_ports Vaux8_0]
set_property name Vaux12 [get_bd_intf_ports Vaux12_0]
set_property name Vaux13 [get_bd_intf_ports Vaux13_0]


if {$EnablePCIe == 1} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma
    set_property -dict [list CONFIG.cfg_mgmt_if {false}] [get_bd_cells xdma]
    # x4 Gen3 = edge lanes 0-3 = GTY quad 227, verified against Vivado's own
    # xcvu33p_fsvh2104.pkg.  Quads 226/225/224 (edge lanes 4-15) stay free for
    # Aurora.  x1 and x2 would free no additional quad, so the width decision
    # cannot be deferred past this line.
    #
    # 128-bit AXI at 250 MHz = 4.0 GB/s, just over the 3.94 GB/s Gen3 x4 raw
    # payload ceiling, so the fabric is not the limit.  Do not raise it: a
    # wider M_AXI only adds smartconnect logic the link can never fill.
    set_property -dict [list CONFIG.pl_link_cap_max_link_width {X4} CONFIG.pl_link_cap_max_link_speed {8.0_GT/s}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.axi_data_width {128_bit}] [get_bd_cells xdma]
    # One DMA channel each way.  The weight load is one direction and the token
    # path is bytes; more channels buy nothing here and each one is another
    # thing that can fail to be identified by the driver at probe time.
    set_property -dict [list CONFIG.xdma_rnum_chnl {1} CONFIG.xdma_wnum_chnl {1}] [get_bd_cells xdma]
    #set_property -dict [list CONFIG.pl_link_cap_max_link_width {X16} CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} CONFIG.axi_data_width {512_bit}] [get_bd_cells xdma]
    #set_property -dict [list CONFIG.xdma_rnum_chnl {4} CONFIG.xdma_wnum_chnl {4}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.xdma_pcie_64bit_en {true} CONFIG.pf0_msix_cap_table_bir {BAR_1:0} CONFIG.pf0_msix_cap_pba_bir {BAR_1:0} CONFIG.xdma_pcie_prefetchable {true}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.pcie_blk_locn {PCIE4C_X1Y0}] [get_bd_cells xdma]
    # Vendor/device ID overrides REMOVED.  SQRL sets 1E24:1533, which is not in
    # any stock XDMA driver's match table, so the driver would silently not
    # bind and the failure would look like a broken endpoint.  The IP's own
    # defaults are the IDs Xilinx's dma_ip_drivers table was generated from.
    # Whatever it picks, read it out of the build log and out of `lspci -nn`
    # before assuming the driver will bind -- see the host plan.
    puts "FK33_PCIE_IDS vendor=[get_property CONFIG.vendor_id [get_bd_cells xdma]] device=[get_property CONFIG.pf0_device_id [get_bd_cells xdma]]"
    set_property -dict [list CONFIG.pf0_revision_id {A3} CONFIG.pf0_subsystem_vendor_id {1E24} CONFIG.pf0_subsystem_id {0001}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.pf0_Use_Class_Code_Lookup_Assistant {true} CONFIG.pf0_base_class_menu {Processing_accelerators} CONFIG.pf0_class_code_base {12} CONFIG.pf0_sub_class_interface_menu {Unknown} CONFIG.pf0_class_code_interface {00} CONFIG.pf0_class_code {120000}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.axisten_freq {250}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.axilite_master_en {true} CONFIG.axilite_master_size {128} CONFIG.axilite_master_scale {Kilobytes} CONFIG.pf0_msix_cap_table_bir {BAR_3:2} CONFIG.pf0_msix_cap_pba_bir {BAR_3:2} CONFIG.axil_master_64bit_en {true} CONFIG.axil_master_prefetchable {true}] [get_bd_cells xdma]

    create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0
    set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells util_ds_buf_0]
       
    make_bd_intf_pins_external  [get_bd_intf_pins xdma/pcie_mgt]
    set_property name pcie [get_bd_intf_ports pcie_mgt_0]
    
    make_bd_intf_pins_external  [get_bd_intf_pins util_ds_buf_0/CLK_IN_D]
    set_property name pcie_refclk [get_bd_intf_ports CLK_IN_D_0]
    connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_DS_ODIV2] [get_bd_pins xdma/sys_clk]
    connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins xdma/sys_clk_gt]
 
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins clk_wiz_0/clk_in1]
    
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0
    # CLKREQ# is ACTIVE LOW and it is the endpoint that asserts it to request
    # the reference clock.  Upstream leaves CONST_VAL at its default of 1, i.e.
    # deasserted.  Most desktop slots free-run the refclk and never look, but a
    # host that does honour it would gate the clock and the link would never
    # train -- with no symptom that separates it from a dead transceiver.
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells xlconstant_0]
    make_bd_pins_external  [get_bd_pins xlconstant_0/dout]
    set_property name pcie_clkreq [get_bd_ports dout_0]
    
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2}] [get_bd_cells pcie2hbm]
    connect_bd_intf_net [get_bd_intf_pins xdma/M_AXI] [get_bd_intf_pins pcie2hbm/S01_AXI]
    
    # NUM_MI is 2, not upstream's 1.  Upstream shrinks this smartconnect back to
    # one master AFTER system_management_wiz has already been connected to M01,
    # which deletes that port and orphans SYSMON.  The bug survives in SQRL's
    # script only because that script never synthesises -- it creates the
    # project and stops.  Left as 1, this build fails at address assignment.
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2}] [get_bd_cells pcie2axil]

    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/aclk]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/aresetn]
    
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/S00_ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/S01_ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/M00_ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/M01_ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/M02_ACLK]
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins hbm/AXI_00_ACLK]
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins hbm/AXI_16_ACLK]
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins axi_gpio_0/s_axi_aclk]
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins jtag_hbm/aclk]
    
    
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/S00_ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/S01_ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/M00_ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/M01_ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/M02_ARESETN]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins jtag_hbm/aresetn]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_00_ARESET_N]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_16_ARESET_N]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm_reset/ext_reset_in]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins clk_wiz_0/resetn]
    
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2axil/aclk]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2axil/aresetn]
    connect_bd_intf_net [get_bd_intf_pins xdma/M_AXI_LITE] [get_bd_intf_pins pcie2axil/S01_AXI]
    
    connect_bd_net [get_bd_pins jtag_axil/aclk] [get_bd_pins xdma/axi_aclk]
    connect_bd_net [get_bd_pins jtag_axil/aresetn] [get_bd_pins xdma/axi_aresetn]
    
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins system_management_wiz_0/s_axi_aclk]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins system_management_wiz_0/s_axi_aresetn]
    
    make_bd_pins_external  [get_bd_pins xdma/sys_rst_n]
    set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports sys_rst_n_0]
    set_property name pcie_perstn [get_bd_ports sys_rst_n_0]

    # ---- LINK-UP LED ------------------------------------------------------
    # LED 6 shows the PCIe link state with no host, no JTAG and no instrument.
    # Needed because every other diagnostic in this design sits DOWNSTREAM of
    # the link: xdma drives axi_aclk/axi_aresetn for the whole fabric, so if
    # the link never comes up the JTAG-AXI masters are held in reset and their
    # reads hang -- indistinguishable from an unpowered card.
    #
    # led_inv is a 7-bit NOT, so LED 6 shows the INVERSE of user_lnk_up.  The
    # board's LED polarity is not documented anywhere, so do not predict which
    # way it goes: observe LED 6 with the link down and with it up, and take
    # the CHANGE as the signal.
    if {![info exists ::env(FK33_NO_LNKLED)]} {
        set lnk [get_bd_pins -quiet xdma/user_lnk_up]
        if {[llength $lnk] == 0} {
            puts "FK33_LNKLED SKIP: xdma/user_lnk_up not present on this IP version"
        } elseif {[catch {
            set n [get_bd_nets -quiet -of_objects [get_bd_pins led_inv/Op1]]
            if {[llength $n]} { delete_bd_objs $n }
            create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 gpo_lo
            set_property -dict [list CONFIG.DIN_WIDTH {7} CONFIG.DIN_FROM {5} \
                CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {6}] [get_bd_cells gpo_lo]
            create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 led_cat
            set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {6} \
                CONFIG.IN1_WIDTH {1}] [get_bd_cells led_cat]
            connect_bd_net [get_bd_pins axi_gpio_0/gpio2_io_o] [get_bd_pins gpo_lo/Din]
            connect_bd_net [get_bd_pins gpo_lo/Dout] [get_bd_pins led_cat/In0]
            connect_bd_net $lnk [get_bd_pins led_cat/In1]
            connect_bd_net [get_bd_pins led_cat/dout] [get_bd_pins led_inv/Op1]
            puts "FK33_LNKLED OK: LED 6 follows NOT(user_lnk_up)"
        } err]} {
            puts "FK33_LNKLED FAIL: $err"
            puts "FK33_LNKLED reverting to the original GPIO wiring"
            catch {delete_bd_objs [get_bd_cells -quiet {gpo_lo led_cat}]}
            connect_bd_net [get_bd_pins axi_gpio_0/gpio2_io_o] [get_bd_pins led_inv/Op1]
        }
    }

    
} else {
    
    create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_1
    set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDS}] [get_bd_cells util_ds_buf_1]
    make_bd_intf_pins_external  [get_bd_intf_pins util_ds_buf_1/CLK_IN_D]
    set_property name sysref [get_bd_intf_ports CLK_IN_D_0]
    set_property -dict [list CONFIG.FREQ_HZ {200000000}] [get_bd_intf_ports sysref]
    
    connect_bd_net [get_bd_pins util_ds_buf_1/IBUF_OUT] [get_bd_pins clk_wiz_0/clk_in1]
    set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_0]
    set_property -dict [list CONFIG.PRIM_IN_FREQ {200} CONFIG.CLKIN1_JITTER_PS {50.0} CONFIG.MMCM_CLKFBOUT_MULT_F {6.000} CONFIG.MMCM_CLKIN1_PERIOD {5.000} CONFIG.MMCM_CLKIN2_PERIOD {10.0} CONFIG.CLKOUT1_JITTER {106.024} CONFIG.CLKOUT1_PHASE_ERROR {82.655} CONFIG.CLKOUT2_JITTER {92.799} CONFIG.CLKOUT2_PHASE_ERROR {82.655}] [get_bd_cells clk_wiz_0]
    set_property -dict [list CONFIG.USE_RESET {false}] [get_bd_cells clk_wiz_0]
    
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins pcie2hbm/aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins pcie2axil/aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins jtag_hbm/aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins jtag_axil/aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_gpio_0/s_axi_aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins system_management_wiz_0/s_axi_aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/AXI_00_ACLK]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/AXI_16_ACLK]
    
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins system_management_wiz_0/s_axi_aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/AXI_00_ARESET_N]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/AXI_16_ARESET_N]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins pcie2hbm/aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins pcie2axil/aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins jtag_axil/aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins jtag_hbm/aresetn]
    
    create_bd_port -dir I -type rst pcie_perstn
    connect_bd_net [get_bd_ports pcie_perstn] [get_bd_pins hbm_reset/ext_reset_in]
}





# ---- BRING-UP PERIPHERALS (gen_pcieep.py) ---------------------------------
# None of this is in SQRL's design.  It exists because the first time this card
# is in a slot there has to be something testable that is not the inference
# engine, and because each stage of the host path has to fail distinguishably
# from the next.  Without these three, the only host-visible things are SYSMON
# (read-only) and a GPIO wired to real board pins (unsafe to scribble on), and
# there is no DMA target at all except HBM -- which would make "the DMA engine
# is broken" and "HBM is broken" produce the same symptom.
#
#   fk33_id        READ-ONLY, driven from fabric constants, so no host write
#                  and no earlier test can change it.  Reading 0x464b3333
#                  ("FK33" in ASCII) proves, in one access, all of: the link
#                  trained, config space answered, the BIOS placed the BAR, the
#                  AXI-Lite master is clocked and out of reset, the smartconnect
#                  decodes, and the fabric holds THIS bitstream.  A driver that
#                  merely loaded cannot produce that value, and neither can a
#                  floating bus -- which reads as 0x00000000 or 0xFFFFFFFF.
#   fk33_scratch   true read/write BRAM on the same AXI-Lite BAR.  SYSMON is
#                  read-only and the GPIO drives board pins, so before this
#                  there was nowhere safe to prove that MMIO WRITES land.
#   fk33_dmabram   BRAM on the 128-bit DMA master.  A host write-then-read-back
#                  through here uses the same descriptor path, the same M_AXI
#                  and the same smartconnect as the weight load, with HBM taken
#                  out of the loop.
#
# Clocks and resets are joined onto the smartconnect nets rather than wired to
# a named source, because those nets come from xdma when EnablePCIe is 1 and
# from clk_wiz/hbm_reset when it is 0.  Joining keeps this block correct in
# both branches with no duplication.

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 id_magic
set_property -dict [list CONFIG.CONST_WIDTH {32} CONFIG.CONST_VAL {1179333427}] [get_bd_cells id_magic]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 id_build
set_property -dict [list CONFIG.CONST_WIDTH {32} CONFIG.CONST_VAL {539363368}] [get_bd_cells id_build]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_id
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_ALL_OUTPUTS {0} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells fk33_id]
connect_bd_net [get_bd_pins id_magic/dout] [get_bd_pins fk33_id/gpio_io_i]
connect_bd_net [get_bd_pins id_build/dout] [get_bd_pins fk33_id/gpio2_io_i]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fk33_scratch
set_property -dict [list CONFIG.DATA_WIDTH {32} CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.ECC_TYPE {0}] [get_bd_cells fk33_scratch]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 fk33_scratch_ram
set_property -dict [list CONFIG.Memory_Type {Single_Port_RAM}] [get_bd_cells fk33_scratch_ram]
connect_bd_intf_net [get_bd_intf_pins fk33_scratch/BRAM_PORTA] [get_bd_intf_pins fk33_scratch_ram/BRAM_PORTA]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fk33_dmabram
set_property -dict [list CONFIG.DATA_WIDTH {128} CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.ECC_TYPE {0}] [get_bd_cells fk33_dmabram]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 fk33_dmabram_ram
set_property -dict [list CONFIG.Memory_Type {Single_Port_RAM}] [get_bd_cells fk33_dmabram_ram]
connect_bd_intf_net [get_bd_intf_pins fk33_dmabram/BRAM_PORTA] [get_bd_intf_pins fk33_dmabram_ram/BRAM_PORTA]

# Grow the two smartconnects rather than setting an absolute NUM_MI, so this
# stays correct if a later edit adds a master port before this point.  Growing
# is safe; SHRINKING deletes ports and silently orphans whatever was on them,
# which is exactly the upstream bug fixed above.
set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]
set_property CONFIG.NUM_MI [expr {$n + 2}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins fk33_id/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {$n + 1}]]] \
                    [get_bd_intf_pins fk33_scratch/S_AXI]

set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2hbm]]
set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells pcie2hbm]
connect_bd_intf_net [get_bd_intf_pins pcie2hbm/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins fk33_dmabram/S_AXI]

connect_bd_net [get_bd_pins fk33_id/s_axi_aclk]         [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_id/s_axi_aresetn]      [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_scratch/s_axi_aclk]    [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_scratch/s_axi_aresetn] [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_dmabram/s_axi_aclk]    [get_bd_pins pcie2hbm/aclk]
connect_bd_net [get_bd_pins fk33_dmabram/s_axi_aresetn] [get_bd_pins pcie2hbm/aresetn]
# ---- end bring-up peripherals ---------------------------------------------


# ---- FREE-RUNNING AUX DOMAIN (gen_pcieep.py) ------------------------------
# Read the header of gen_pcieep.py, item 9, before changing anything here.  In
# short: in this bitstream the clock the debug hub uses is an MMCM output whose
# reference is xdma/axi_aclk and whose MMCM is held in reset by
# xdma/axi_aresetn, so NOTHING in the shipped design survives the link being
# down.  The 200 MHz oscillator on BC26/BC27 does, and is the only clock every
# EnablePCIe == 0 bitstream in this repository has ever run from.
if {$EnablePCIe != 1} {
    error "the aux block assumes EnablePCIe 1, and this generated script is only ever built that way"
}

create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_1
set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDS}] [get_bd_cells util_ds_buf_1]
make_bd_intf_pins_external  [get_bd_intf_pins util_ds_buf_1/CLK_IN_D]
set_property name sysref [get_bd_intf_ports CLK_IN_D_0]
set_property -dict [list CONFIG.FREQ_HZ {200000000}] [get_bd_intf_ports sysref]

create_bd_cell -type module -reference fk33_aux fk33_aux_0
connect_bd_net [get_bd_pins util_ds_buf_1/IBUF_OUT] [get_bd_pins fk33_aux_0/clk_free_in]

# The PCIe USER clock, measured rather than used.  A direct measurement of the
# raw reference clock was built and REJECTED: it needs a second BUFG_GT on
# util_ds_buf_0/IBUF_DS_ODIV2, and DRC BFGTL-1 kills route_design because two
# BUFG_GTs sharing one GT clock source must have identical CE and CLR nets --
# xdma drives its own from an internal BUFG_GT_SYNC that is not exposed as a
# pin.  Do not retry that; see the debugging note.  axi_aclk plus the PERST#
# level answers the same question by elimination.
connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins fk33_aux_0/xdma_aclk]

# Both of these are already driven; joining a second load changes nothing about
# what xdma sees, and makes the two states the endpoint cannot currently report
# visible with the link down.
connect_bd_net [get_bd_ports pcie_perstn]       [get_bd_pins fk33_aux_0/perstn]
connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins fk33_aux_0/xdma_aresetn]

# LTSSM is deliberately absent.  xdma 4.1 exposes no LTSSM pin unless
# CONFIG.enable_ltssm_dbg or CONFIG.en_debug_ports is turned on, both of which
# change the IP configuration; user_lnk_up is a pin at the current settings and
# needs nothing.
set auxlnk [get_bd_pins -quiet xdma/user_lnk_up]
if {[llength $auxlnk]} {
    connect_bd_net $auxlnk [get_bd_pins fk33_aux_0/user_lnk_up]
    puts "FK33_AUX LNK user_lnk_up wired into the aux status word"
} else {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 aux_lnk_stub
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells aux_lnk_stub]
    connect_bd_net [get_bd_pins aux_lnk_stub/dout] [get_bd_pins fk33_aux_0/user_lnk_up]
    puts "FK33_AUX LNK user_lnk_up ABSENT on this IP version, status bit tied 0"
}

# The two I2C balls now go through the aux block, which arbitrates.  The GPIO
# owns them except while the autonomous controller is mid-transaction, and the
# controller hands them back the moment it finishes, so host/fk33ctl.py vccint
# and tcl/vccint_step.tcl keep working unchanged.  The external port keeps the
# name the XDC already constrains, so no pin constraint moves.
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins fk33_aux_0/gpio_o]
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_t] [get_bd_pins fk33_aux_0/gpio_t]
connect_bd_net [get_bd_pins fk33_aux_0/gpio_i]    [get_bd_pins axi_gpio_0/gpio_io_i]
make_bd_pins_external [get_bd_pins fk33_aux_0/i2c_io]
set_property name i2cprobe_tri_io [get_bd_ports i2c_io_0]

# The aux read path.  A THIRD JTAG-AXI master with its own smartconnect and its
# own slaves, every one of them clocked by fk33_aux_0/aux_clk.  It is not a
# branch off pcie2axil and it is not reachable from xdma: that is deliberate,
# and it is what makes "the read path does not touch xdma/axi_aclk" a property
# of the netlist rather than a claim about it.
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_aux
set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {32} CONFIG.M_AXI_ADDR_WIDTH {32} \
    CONFIG.M_HAS_BURST {0}] [get_bd_cells jtag_aux]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 auxconnect
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6}] [get_bd_cells auxconnect]
connect_bd_intf_net [get_bd_intf_pins jtag_aux/M_AXI] [get_bd_intf_pins auxconnect/S00_AXI]

set auxi 0
foreach c {aux_id aux_clkst aux_stat aux_time aux_therm aux_peak} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 $c
    set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
        CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
        CONFIG.C_ALL_OUTPUTS {0} CONFIG.C_ALL_OUTPUTS_2 {0} \
        CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells $c]
    connect_bd_intf_net [get_bd_intf_pins auxconnect/[format M%02d_AXI $auxi]] \
                        [get_bd_intf_pins $c/S_AXI]
    connect_bd_net [get_bd_pins $c/s_axi_aclk]    [get_bd_pins fk33_aux_0/aux_clk]
    connect_bd_net [get_bd_pins $c/s_axi_aresetn] [get_bd_pins fk33_aux_0/aux_aresetn]
    incr auxi
}

connect_bd_net [get_bd_pins jtag_aux/aclk]      [get_bd_pins fk33_aux_0/aux_clk]
connect_bd_net [get_bd_pins jtag_aux/aresetn]   [get_bd_pins fk33_aux_0/aux_aresetn]
connect_bd_net [get_bd_pins auxconnect/aclk]    [get_bd_pins fk33_aux_0/aux_clk]
connect_bd_net [get_bd_pins auxconnect/aresetn] [get_bd_pins fk33_aux_0/aux_aresetn]

connect_bd_net [get_bd_pins fk33_aux_0/stat_magic]    [get_bd_pins aux_id/gpio_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_version]  [get_bd_pins aux_id/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_uclkticks] [get_bd_pins aux_clkst/gpio_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_uclkhz]    [get_bd_pins aux_clkst/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_status]   [get_bd_pins aux_stat/gpio_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_pot]      [get_bd_pins aux_stat/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_ms]       [get_bd_pins aux_time/gpio_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_perstms]  [get_bd_pins aux_time/gpio2_io_i]
# ---- end free-running aux domain ------------------------------------------


# ---- THERMAL PROTECTION (gen_pcieep.py) -----------------------------------
# Read rtl/fk33_thermal.vhd before changing anything here.  In short: nothing in
# this design did ANY thermal management.  SYSMON was a register the host could
# read, the HBM stacks' own temperature and catastrophic-trip outputs were left
# dangling, and no comparison against a limit existed anywhere in the fabric.
#
# The silicon's own protection is a backstop, not management.  The SYSMONE4
# primitive accepts a write to the OT upper-limit register 53h only when the low
# nibble is 0011, which IS the automatic-shutdown enable, and
# system_management_wiz forces that nibble unconditionally -- so this design's
# OT shutdown is armed, at the 101 C SQRL programs.  DS890 Table 33 puts
# sustained Tj for -2LE at 100 C and recommends a maximum of 95 C for the HBM,
# so OT fires after the part is already out of spec, and its consequence is a
# shutdown that takes the card off the PCIe bus.  The guard below fires first,
# inside the datasheet, and halts ARITHMETIC ONLY.

create_bd_cell -type module -reference fk33_thermal fk33_therm_0

# The guard lives on the free-running aux domain, NOT on any PCIe-derived
# clock.  Both sensors are in PCIe-derived domains, so a guard clocked by
# either would lose the thermal record exactly when it is wanted -- after an OT
# shutdown, a host reset or a link drop -- and its staleness watchdogs could
# themselves go stale.
connect_bd_net [get_bd_pins fk33_aux_0/aux_clk]     [get_bd_pins fk33_therm_0/aux_clk]
connect_bd_net [get_bd_pins fk33_aux_0/aux_aresetn] [get_bd_pins fk33_therm_0/aux_aresetn]

# DIE.  system_management_wiz temp_out[9:0] needs CONFIG.ENABLE_TEMP_BUS, and
# user_temp_alarm_out needs CONFIG.USER_TEMP_ALARM -- upstream sets the latter
# FALSE, so both are re-set above and both are read back in the BD check.
# Vivado SILENTLY IGNORES a set_property on a CONFIG name that does not apply,
# so "we asked for it" is not evidence that it happened.
connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins fk33_therm_0/sysmon_clk]
connect_bd_net [get_bd_pins system_management_wiz_0/temp_out] \
               [get_bd_pins fk33_therm_0/sysmon_temp]
connect_bd_net [get_bd_pins system_management_wiz_0/ot_out] \
               [get_bd_pins fk33_therm_0/sysmon_ot]
connect_bd_net [get_bd_pins system_management_wiz_0/user_temp_alarm_out] \
               [get_bd_pins fk33_therm_0/sysmon_alarm]
# eoc_out is the LIVENESS source, and it is the reason a stuck ADC is caught.
# A value comparison alone cannot tell a frozen sensor from a cold card.
connect_bd_net [get_bd_pins system_management_wiz_0/eoc_out] \
               [get_bd_pins fk33_therm_0/sysmon_eoc]

# HBM.  These four pins EXIST on hbm_v1_0 with no reconfiguration:
# DRAM_0_STAT_TEMP/CATTRIP are unconditional and DRAM_1_* appear whenever
# USER_HBM_STACK is 2, which this design already sets.  The stock FK33 design
# simply leaves them dangling, so the stacks' own catastrophic-temperature
# signal has been asserting into the void.  hw/fk33/gen_hbmbw.py already wires
# the same four into rtl/hbm_tg.vhd; this is the same wiring in the endpoint.
#
# APB_0_PCLK is clk_wiz_0/clk_out1, the 100 MHz clock the IP's internal
# temperature reader runs on (TEMP_WAIT_PERIOD_0 = 100000 -> a refresh every
# ~1 ms).  It is the only liveness signal HBM offers: the reader's internal
# temp_valid_r is not brought out to a pin.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins fk33_therm_0/hbm_pclk]
connect_bd_net [get_bd_pins hbm/DRAM_0_STAT_TEMP]    [get_bd_pins fk33_therm_0/hbm_temp0]
connect_bd_net [get_bd_pins hbm/DRAM_1_STAT_TEMP]    [get_bd_pins fk33_therm_0/hbm_temp1]
connect_bd_net [get_bd_pins hbm/DRAM_0_STAT_CATTRIP] [get_bd_pins fk33_therm_0/hbm_cattrip0]
connect_bd_net [get_bd_pins hbm/DRAM_1_STAT_CATTRIP] [get_bd_pins fk33_therm_0/hbm_cattrip1]

# The compute domain.  compute_halt IS CONNECTED as of 2026-08-29: it reaches
# subsystem A in ENGINE_BLOCK below.  The canary stays and is now doubly
# useful, because it counts toggles of THE ENGINE'S OWN CORE CLOCK -- so
# THERM_CANARY answers "is the compute domain clocked and un-halted" over JTAG
# with the PCIe link down, about the real datapath rather than about a stand-in.
#
# What the halt does to the engine, stated here because the contract is in this
# module's header and the implementation is in rtl/fk33_engine.vhd: it masks
# the GO bit of an AXI-Lite write, so no NEW job can start.  A job already
# running is not disturbed and runs to completion, which is what retires every
# AXI burst it has already issued.  Abandoning an accepted burst would hang
# that HBM channel permanently.
# compute_clk is the ENGINE'S CORE CLOCK (clk_wiz_0/clk_out3), not
# xdma/axi_aclk.  It was xdma/axi_aclk only because there was no compute
# datapath; now there is, and fk33_thermal's contract is that compute_halt is
# SYNCHRONOUS TO compute_clk.  Driving it from a clock the datapath does not
# use would hand the engine an unsynchronised halt, which is precisely the
# torn-word failure this module's own host_* outputs exist to avoid.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins fk33_therm_0/compute_clk]
connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins fk33_therm_0/ctl_host_clk]

# ---- thermal registers on the AUX (JTAG) side -----------------------------
# aux_therm and aux_peak come out of the all-inputs loop above.  aux_ctl is the
# only aux register with an OUTPUT channel, so it is built here.  Its
# C_DOUT_DEFAULT is 0, which does NOT match the clear key, so a card coming out
# of configuration cannot be clearing anything.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 aux_ctl
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {0} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_DOUT_DEFAULT {0x00000000} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells aux_ctl]
set n [get_property CONFIG.NUM_MI [get_bd_cells auxconnect]]
set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells auxconnect]
connect_bd_intf_net [get_bd_intf_pins auxconnect/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins aux_ctl/S_AXI]
connect_bd_net [get_bd_pins aux_ctl/s_axi_aclk]    [get_bd_pins fk33_aux_0/aux_clk]
connect_bd_net [get_bd_pins aux_ctl/s_axi_aresetn] [get_bd_pins fk33_aux_0/aux_aresetn]

connect_bd_net [get_bd_pins fk33_therm_0/stat_therm]  [get_bd_pins aux_therm/gpio_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/stat_temps]  [get_bd_pins aux_therm/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/stat_peak]   [get_bd_pins aux_peak/gpio_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/stat_trip]   [get_bd_pins aux_peak/gpio2_io_i]
connect_bd_net [get_bd_pins aux_ctl/gpio_io_o]        [get_bd_pins fk33_therm_0/ctl_aux]
connect_bd_net [get_bd_pins fk33_therm_0/stat_canary] [get_bd_pins aux_ctl/gpio2_io_i]

# ---- thermal registers on the PCIe AXI-Lite BAR ---------------------------
# The SAME words, resynchronised into the xdma domain inside fk33_thermal.  A
# 32-bit aux-domain word handed straight to an axi_gpio on this clock would tear
# under the host's read; the module's agreement filter is what makes these
# coherent.  These three cells are deliberately NOT part of the aux branch and
# are excluded from the aux clock-isolation check for that reason.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_therm
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_ALL_OUTPUTS {0} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells fk33_therm]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_thermp
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_ALL_OUTPUTS {0} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells fk33_thermp]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_thermc
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {0} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_DOUT_DEFAULT {0x00000000} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells fk33_thermc]

set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]
set_property CONFIG.NUM_MI [expr {$n + 3}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins fk33_therm/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {$n + 1}]]] \
                    [get_bd_intf_pins fk33_thermp/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {$n + 2}]]] \
                    [get_bd_intf_pins fk33_thermc/S_AXI]
connect_bd_net [get_bd_pins fk33_therm/s_axi_aclk]     [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_therm/s_axi_aresetn]  [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_thermp/s_axi_aclk]    [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_thermp/s_axi_aresetn] [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_thermc/s_axi_aclk]    [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_thermc/s_axi_aresetn] [get_bd_pins pcie2axil/aresetn]

connect_bd_net [get_bd_pins fk33_therm_0/host_therm]  [get_bd_pins fk33_therm/gpio_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/host_temps]  [get_bd_pins fk33_therm/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/host_peak]   [get_bd_pins fk33_thermp/gpio_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/host_trip]   [get_bd_pins fk33_thermp/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_thermc/gpio_io_o]    [get_bd_pins fk33_therm_0/ctl_host]
connect_bd_net [get_bd_pins fk33_therm_0/host_canary] [get_bd_pins fk33_thermc/gpio2_io_i]
# ---- end thermal protection -----------------------------------------------


# ---- SUBSYSTEM A (gen_pcieep.py) ------------------------------------------
# rtl/fk33_engine.vhd wraps rtl/matvec_int4_desc_axi.vhd and exposes its 28
# read masters as named AXI interfaces, because a flattened std_logic_vector
# is not something the block designer can connect to hbm/SAXI_nn.  Read
# hw/fk33/gen_fk33_engine.py's docstring for what that wrapper adds beyond
# wiring: the thermal halt, the activation write port and the 40 -> 33 bit
# address truncation.
create_bd_cell -type module -reference fk33_engine eng

# LEVER C, opt-in via FK33_CB_STYLE.  A module-reference cell takes a
# generic as a CONFIG property; `-generic` on synth_design would reach
# only the top and never this instance (fk33_engine.vhd:67).
set_property CONFIG.CB_STYLE {distributed} [get_bd_cells eng]
# READ BACK.  Vivado silently ignores a set_property whose target did
# not match, and this file already does this for every other CONFIG it
# sets.  A lever that was quietly not applied looks exactly like a
# lever that did not work.
set _cb [get_property CONFIG.CB_STYLE [get_bd_cells eng]]
if {$_cb ne "distributed"} {
    error "FK33_CB_STYLE FAIL: CONFIG.CB_STYLE is \"$_cb\", not distributed"
}
puts "FK33_CB_STYLE $_cb"

# x_exp FROM THE PORT, not the descriptor (FK33_CARD).  Same mechanism as
# CB_STYLE: a generic on a module-reference cell is a CONFIG property.
# Read back for the same reason: a set_property that matched nothing is
# silent, and a lever quietly not applied looks like one that did not
# work -- here, wrong exponents with FAULTS = 0.
set_property CONFIG.USE_XEXP_PORT {true} [get_bd_cells eng]
set _xe [get_property CONFIG.USE_XEXP_PORT [get_bd_cells eng]]
if {![string is true -strict $_xe]} {
    error "FK33_XEXP_PORT FAIL: CONFIG.USE_XEXP_PORT is \"$_xe\", not true"
}
puts "FK33_XEXP_PORT $_xe"

# WHICH CLOCK OWNS WHICH INTERFACE.  A module-reference cell with ONE clock
# port gets this for free -- which is why rtl/hbm_tg_ip.vhd never needed it
# and build_fk33_hbmbw.tcl has no line like this.  This wrapper has TWO, so
# Vivado cannot infer the association and every inferred interface defaults
# to 100 MHz.  MEASURED: without these lines HDL generation dies with 30
# separate BD 41-237 'FREQ_HZ does not match' errors, one per interface, and
# not one of them names the missing association as the cause.
#
# Read back below rather than assumed: Vivado silently ignores set_property
# on a CONFIG name an object does not have, which is the project-wide trap
# that the SYSMON read-back exists for.
set_property CONFIG.ASSOCIATED_BUSIF {s_axi:s_axix} [get_bd_pins eng/core_clk]
set_property CONFIG.ASSOCIATED_RESET {core_aresetn} [get_bd_pins eng/core_clk]
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_pins eng/core_aresetn]
set_property CONFIG.ASSOCIATED_BUSIF {m00_axi:m01_axi:m02_axi:m03_axi:m04_axi:m05_axi:m06_axi:m07_axi:m08_axi:m09_axi:m10_axi:m11_axi:m12_axi:m13_axi:m14_axi:m15_axi:m16_axi:m17_axi:m18_axi:m19_axi:m20_axi:m21_axi:m22_axi:m23_axi:m24_axi:m25_axi:m26_axi:m27_axi} [get_bd_pins eng/hbm_aclk]
foreach {pin want} [list eng/core_clk {s_axi:s_axix} eng/hbm_aclk {m00_axi:m01_axi:m02_axi:m03_axi:m04_axi:m05_axi:m06_axi:m07_axi:m08_axi:m09_axi:m10_axi:m11_axi:m12_axi:m13_axi:m14_axi:m15_axi:m16_axi:m17_axi:m18_axi:m19_axi:m20_axi:m21_axi:m22_axi:m23_axi:m24_axi:m25_axi:m26_axi:m27_axi}] {
    set got [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins $pin]]
    if {$got ne $want} {
        error "FK33_ENG FAIL: $pin ASSOCIATED_BUSIF is \"$got\", not \"$want\". Every AXI interface would default to 100 MHz."
    }
    puts "FK33_ENG ASSOCIATED_BUSIF $pin = $got"
}

# THE CORE CLOCK.  A third MMCM output rather than a reuse of clk_out2:
# clk_out2 is HBM_REF_CLK_0/1, and sharing the HBM reference clock net with
# a fabric datapath clock would tie two unrelated requirements together for
# no gain.  clk_wiz_0's reference is xdma/axi_aclk in this branch, so the
# core clock stops with the PCIe link -- which is correct: with no host
# there is no job, and the thermal guard is on the aux domain and does not
# stop with it.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 core_reset
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins core_reset/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins core_reset/dcm_locked]
connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins core_reset/ext_reset_in]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins eng/core_clk]
connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins eng/core_aresetn]
connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins eng/hbm_aclk]

# THE THERMAL HALT.  fk33_thermal's contract requires compute_halt to be
# SYNCHRONOUS TO compute_clk, so compute_clk is moved onto the engine's core
# clock above; it used to be xdma/axi_aclk because there was no datapath.
# The wrapper consumes the halt by masking the GO bit of an AXI-Lite write.
# It does NOT gate a clock, does NOT touch a reset, and does NOT interrupt a
# job that has already started -- so no accepted HBM burst is ever
# abandoned, which would hang that channel permanently.
connect_bd_net [get_bd_pins fk33_therm_0/compute_halt] [get_bd_pins eng/compute_halt]

# CONTROL.  A dedicated smartconnect because the engine's AXI-Lite slave is
# in the CORE clock domain (matvec_int4_desc_axi's s_axi_aclk IS the core
# clock) while pcie2axil is in xdma's.  NUM_CLKS 2 with aclk on the incoming
# side and aclk1 on the outgoing side is exactly the shape
# build_fk33_hbmbw.tcl:334-341 used for axil2tg, which built, routed and ran.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil2eng
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {2}] [get_bd_cells axil2eng]
set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]
set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins axil2eng/S00_AXI]
connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins axil2eng/aclk]
connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins axil2eng/aresetn]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins axil2eng/aclk1]
connect_bd_intf_net [get_bd_intf_pins axil2eng/M00_AXI] [get_bd_intf_pins eng/s_axi]
connect_bd_intf_net [get_bd_intf_pins axil2eng/M01_AXI] [get_bd_intf_pins eng/s_axix]

# THE 28 HBM MASTERS.  Every ENABLED SAXI port exposes its own ACLK and
# ARESET_N pin and leaving them dangling fails HDL generation with 41-758;
# build_fk33_hbmbw.tcl:373-376 records that, and it is why enabling the
# ports was never a change that could be made ahead of having an engine.
connect_bd_intf_net [get_bd_intf_pins eng/m00_axi] [get_bd_intf_pins hbm/SAXI_01]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_01_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_01_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m01_axi] [get_bd_intf_pins hbm/SAXI_02]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_02_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_02_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m02_axi] [get_bd_intf_pins hbm/SAXI_03]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_03_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_03_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m03_axi] [get_bd_intf_pins hbm/SAXI_04]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_04_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_04_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m04_axi] [get_bd_intf_pins hbm/SAXI_05]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_05_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_05_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m05_axi] [get_bd_intf_pins hbm/SAXI_06]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_06_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_06_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m06_axi] [get_bd_intf_pins hbm/SAXI_07]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_07_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_07_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m07_axi] [get_bd_intf_pins hbm/SAXI_08]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_08_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_08_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m08_axi] [get_bd_intf_pins hbm/SAXI_09]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_09_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_09_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m09_axi] [get_bd_intf_pins hbm/SAXI_10]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_10_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_10_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m10_axi] [get_bd_intf_pins hbm/SAXI_11]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_11_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_11_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m11_axi] [get_bd_intf_pins hbm/SAXI_12]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_12_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_12_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m12_axi] [get_bd_intf_pins hbm/SAXI_13]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_13_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_13_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m13_axi] [get_bd_intf_pins hbm/SAXI_14]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_14_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_14_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m14_axi] [get_bd_intf_pins hbm/SAXI_15]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_15_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_15_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m15_axi] [get_bd_intf_pins hbm/SAXI_17]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_17_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_17_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m16_axi] [get_bd_intf_pins hbm/SAXI_18]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_18_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_18_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m17_axi] [get_bd_intf_pins hbm/SAXI_19]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_19_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_19_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m18_axi] [get_bd_intf_pins hbm/SAXI_20]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_20_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_20_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m19_axi] [get_bd_intf_pins hbm/SAXI_21]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_21_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_21_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m20_axi] [get_bd_intf_pins hbm/SAXI_22]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_22_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_22_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m21_axi] [get_bd_intf_pins hbm/SAXI_23]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_23_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_23_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m22_axi] [get_bd_intf_pins hbm/SAXI_24]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_24_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_24_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m23_axi] [get_bd_intf_pins hbm/SAXI_25]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_25_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_25_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m24_axi] [get_bd_intf_pins hbm/SAXI_26]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_26_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_26_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m25_axi] [get_bd_intf_pins hbm/SAXI_27]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_27_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_27_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m26_axi] [get_bd_intf_pins hbm/SAXI_28]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_28_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_28_ARESET_N]
connect_bd_intf_net [get_bd_intf_pins eng/m27_axi] [get_bd_intf_pins hbm/SAXI_29]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_29_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_29_ARESET_N]
# ---- end subsystem A ------------------------------------------------------

# ---- THE HOST SEAM (gen_pcieep.py) ----------------------------------------
# rtl/fk33_seam.vhd, TRACK DSEAM.  Read the long note above SEAM_BLOCK in
# gen_pcieep.py before changing anything here: the d_err tie is HIGH on
# purpose and tying it low makes a host poll loop hang.
create_bd_cell -type module -reference fk33_seam fk33_seam_0

set_property -dict [list CONFIG.REGMAX {12288} CONFIG.HADDR_W {14}] [get_bd_cells fk33_seam_0]
puts "FK33_SEAM REGMAX=[get_property CONFIG.REGMAX [get_bd_cells fk33_seam_0]] HADDR_W=[get_property CONFIG.HADDR_W [get_bd_cells fk33_seam_0]]"

# THE CLOCK.  The seam rides the engine's CORE clock, not xdma/axi_aclk,
# and it does so through the smartconnect ENGINE_BLOCK already built.  Two
# reasons, in order: subsystem D will be in the core domain, so putting the
# seam anywhere else now buys a move later; and axil2eng is already
# NUM_CLKS 2 with the incoming side on xdma/axi_aclk and the outgoing side
# on clk_wiz_0/clk_out3, so this is one more MI on an interconnect that
# exists rather than a new one.
set n [get_property CONFIG.NUM_MI [get_bd_cells axil2eng]]
set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells axil2eng]
connect_bd_intf_net [get_bd_intf_pins axil2eng/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins fk33_seam_0/s_axi]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins fk33_seam_0/clk]

# THE RESET IS ACTIVE HIGH.  fk33_seam's `rst` is `if rst = '1'`, so it
# takes proc_sys_reset's peripheral_reset and NOT peripheral_aresetn.
# Wiring the active-low net here would leave the block permanently in
# reset after the MMCM locks, which reads from the host as a seam that
# answers 0 to everything -- indistinguishable from an unmapped BAR.
connect_bd_net [get_bd_pins core_reset/peripheral_reset] [get_bd_pins fk33_seam_0/rst]

# ---- the subsystem-D tie-off ----------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 seam_z1
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells seam_z1]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 seam_h1
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells seam_h1]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 seam_nd4
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {15}] [get_bd_cells seam_nd4]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 seam_z11
set_property -dict [list CONFIG.CONST_WIDTH {11} CONFIG.CONST_VAL {0}] [get_bd_cells seam_z11]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 seam_z16
set_property -dict [list CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {0}] [get_bd_cells seam_z16]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 seam_z32
set_property -dict [list CONFIG.CONST_WIDTH {32} CONFIG.CONST_VAL {0}] [get_bd_cells seam_z32]
# d_busy is driven by card/busy (FK33_CARD): no tie-off.
# d_tok_done is driven by card/tok_done (FK33_CARD): no tie-off.
# d_err is driven by card/err (FK33_CARD): no tie-off.
# d_err_code is driven by card/err_code (FK33_CARD): no tie-off.
# d_err_step is driven by card/err_step (FK33_CARD): no tie-off.
# d_steps_done is driven by card/steps_done (FK33_CARD): no tie-off.
# d_raddr is driven by card/d_raddr (FK33_CARD): no tie-off.
# d_ren is driven by card/d_ren (FK33_CARD): no tie-off.
# hr_data is driven by card/hr_data (FK33_CARD): no tie-off.
# obs_issue is driven by card/obs_issue (FK33_CARD): no tie-off.
# obs_tok_pos is driven by card/obs_tok_pos (FK33_CARD): no tie-off.
# smp_token is driven by card/smp_token (FK33_CARD): no tie-off.
# smp_n is driven by card/smp_n (FK33_CARD): no tie-off.
# smp_exp is driven by card/smp_exp (FK33_CARD): no tie-off.
# f_smp_ovf is driven by card/err_smp_ovf (FK33_CARD): no tie-off.
# f_lost_beat is driven by card/err_lost_beat (FK33_CARD): no tie-off.
# f_gate_drop is driven by card/err_gate_drop (FK33_CARD): no tie-off.
# f_unit_stub is driven by card/err_unit_stub (FK33_CARD): no tie-off.
# f_e_coll is driven by card/err_e_coll (FK33_CARD): no tie-off.
# f_kv_err is driven by card/kv_err (FK33_CARD): no tie-off.

set_property CONFIG.CAPS_CTX {131072} [get_bd_cells fk33_seam_0]
set_property CONFIG.CAPS_EMBD {4096} [get_bd_cells fk33_seam_0]
set_property CONFIG.CAPS_LAYER {32} [get_bd_cells fk33_seam_0]
set_property CONFIG.CAPS_VOCAB {248320} [get_bd_cells fk33_seam_0]
# READ BACK, DO NOT ASSUME.  Vivado silently ignores set_property on a
# CONFIG name an object does not have and get_property then returns the
# empty string, so a generic RENAMED in rtl/fk33_seam.vhd would leave this
# build claiming a model geometry it does not have -- or, since 2026-09-17,
# publishing 0 for a model that IS behind the seam, which a host reads as
# 'no model' and refuses.
foreach {g want} {CAPS_VOCAB 248320 CAPS_EMBD 4096 CAPS_LAYER 32 CAPS_CTX 131072} {
    set v [get_property CONFIG.$g [get_bd_cells fk33_seam_0]]
    if {$v ne $want} {
        error "FK33_SEAM FAIL: $g is \"$v\", not $want. Subsystem D is in this bitstream, so the seam must publish the model geometry the card was built for."
    }
    puts "FK33_SEAM $g = $v"
}
# ---- end host seam --------------------------------------------------------

# ---- SUBSYSTEMS B, C, D + THE B/C GRANT (gen_pcieep.py) -------------------
create_bd_cell -type module -reference fk33_card card
create_bd_cell -type module -reference fk33_bc_grant bcgrant

# WHAT VIVADO ACTUALLY INFERRED, printed rather than assumed.  The name of
# an inferred interface is the PORT PREFIX, not the prefix plus `_axi`:
# `a_awvalid` gives an interface called `a`, and the engine's `m00_axi_*`
# gives `m00_axi` only because `_axi` is part of its port names.  Guessing
# `card/a_axi` cost a --bd-only run that got through every cell, both
# clocks and all eleven A-seam nets before failing on BD 5-232.
foreach c {card bcgrant} {
    foreach i [get_bd_intf_pins -quiet $c/*] {
        puts "FK33_CARD INTF $c [file tail $i]"
    }
}

# CLOCKS.  Both cells sit wholly in the CORE domain -- clk_wiz_0/clk_out3 --
# including the HBM-facing side of the grant, which is why the grant's
# m0/m1 need a clock converter at the HBM end if the two ever differ.  They
# do not today: ENGINE_BLOCK already drives every SAXI ACLK from
# xdma/axi_aclk, so CARD_CDC below is where that assumption is checked
# rather than assumed.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins card/clk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins bcgrant/clk]

# RESET POLARITY, read back rather than assumed.  The card takes an ACTIVE
# HIGH `rst` and the grant an ACTIVE LOW `rstn`, so one of them gets the
# inverted form.  Getting this backwards holds a subsystem in reset
# forever, which looks exactly like a subsystem that never starts.
set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_pins card/rst]
set_property CONFIG.POLARITY ACTIVE_LOW  [get_bd_pins bcgrant/rstn]
connect_bd_net [get_bd_pins core_reset/peripheral_reset]   [get_bd_pins card/rst]
connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins bcgrant/rstn]

# ---- the A seam, card <-> eng --------------------------------------------
connect_bd_net [get_bd_pins card/a_job_index] [get_bd_pins eng/job_index]
connect_bd_net [get_bd_pins card/a_x_we] [get_bd_pins eng/d_x_we]
connect_bd_net [get_bd_pins card/a_x_waddr] [get_bd_pins eng/d_x_waddr]
connect_bd_net [get_bd_pins card/a_x_wdata] [get_bd_pins eng/d_x_wdata]
connect_bd_net [get_bd_pins card/a_x_exp] [get_bd_pins eng/d_x_exp]
connect_bd_net [get_bd_pins card/a_y_we] [get_bd_pins eng/d_y_we]
connect_bd_net [get_bd_pins card/a_y_addr] [get_bd_pins eng/d_y_addr]
connect_bd_net [get_bd_pins card/a_y_data] [get_bd_pins eng/d_y_data]
connect_bd_net [get_bd_pins card/a_y_mask] [get_bd_pins eng/d_y_mask]
connect_bd_net [get_bd_pins card/a_y_exp] [get_bd_pins eng/d_y_exp]
connect_bd_net [get_bd_pins card/a_job_done] [get_bd_pins eng/d_job_done]
connect_bd_net [get_bd_pins card/a_job_err] [get_bd_pins eng/d_job_err]

# THE CARD'S AXI-LITE MASTER ONTO THE ENGINE'S CONTROL SLAVE.  Two masters
# now want eng/s_axi: the host, to place DESC_PTR and the arena base before
# a run, and the card, to issue one job per A step during it.  The existing
# net is DELETED and both go through a 2:1 smartconnect, rather than
# ENGINE_BLOCK being edited, so that block stays exactly what the
# engine-only build already proved.
delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins eng/s_axi]]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 engctl
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells engctl]
connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins engctl/aclk]
connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins engctl/aresetn]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins engctl/aclk1]
connect_bd_intf_net [get_bd_intf_pins axil2eng/M00_AXI] [get_bd_intf_pins engctl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins card/a]             [get_bd_intf_pins engctl/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins engctl/M00_AXI]   [get_bd_intf_pins eng/s_axi]

# ---- the host seam, fk33_seam <-> card ------------------------------------
# Subsystem D is PRESENT now, so _seam_block skipped every _SEAM_TIES
# constant that stood in for it -- the tie-off is not emitted rather than
# emitted and deleted, so check_seam_tieoff's reading of the script text
# stays true.  The xlconstant cells still exist for the pins NOT in
# SEAM_FROM_CARD; Vivado drops any that end up unused.
connect_bd_net [get_bd_pins fk33_seam_0/d_busy] [get_bd_pins card/busy]
connect_bd_net [get_bd_pins fk33_seam_0/d_tok_done] [get_bd_pins card/tok_done]
connect_bd_net [get_bd_pins fk33_seam_0/d_err] [get_bd_pins card/err]
connect_bd_net [get_bd_pins fk33_seam_0/d_err_code] [get_bd_pins card/err_code]
connect_bd_net [get_bd_pins fk33_seam_0/d_err_step] [get_bd_pins card/err_step]
connect_bd_net [get_bd_pins fk33_seam_0/d_steps_done] [get_bd_pins card/steps_done]
connect_bd_net [get_bd_pins fk33_seam_0/d_raddr] [get_bd_pins card/d_raddr]
connect_bd_net [get_bd_pins fk33_seam_0/d_ren] [get_bd_pins card/d_ren]
connect_bd_net [get_bd_pins fk33_seam_0/hr_data] [get_bd_pins card/hr_data]
connect_bd_net [get_bd_pins fk33_seam_0/obs_issue] [get_bd_pins card/obs_issue]
connect_bd_net [get_bd_pins fk33_seam_0/obs_tok_pos] [get_bd_pins card/obs_tok_pos]
connect_bd_net [get_bd_pins fk33_seam_0/smp_token] [get_bd_pins card/smp_token]
connect_bd_net [get_bd_pins fk33_seam_0/smp_n] [get_bd_pins card/smp_n]
connect_bd_net [get_bd_pins fk33_seam_0/smp_exp] [get_bd_pins card/smp_exp]
connect_bd_net [get_bd_pins fk33_seam_0/f_smp_ovf] [get_bd_pins card/err_smp_ovf]
connect_bd_net [get_bd_pins fk33_seam_0/f_lost_beat] [get_bd_pins card/err_lost_beat]
connect_bd_net [get_bd_pins fk33_seam_0/f_gate_drop] [get_bd_pins card/err_gate_drop]
connect_bd_net [get_bd_pins fk33_seam_0/f_unit_stub] [get_bd_pins card/err_unit_stub]
connect_bd_net [get_bd_pins fk33_seam_0/f_e_coll] [get_bd_pins card/err_e_coll]
connect_bd_net [get_bd_pins fk33_seam_0/f_kv_err] [get_bd_pins card/kv_err]
connect_bd_net [get_bd_pins fk33_seam_0/d_go] [get_bd_pins card/go]
connect_bd_net [get_bd_pins fk33_seam_0/d_abort] [get_bd_pins card/abort]
connect_bd_net [get_bd_pins fk33_seam_0/d_tbl_len] [get_bd_pins card/tbl_len]
connect_bd_net [get_bd_pins fk33_seam_0/d_host_x_exp] [get_bd_pins card/host_x_exp]
connect_bd_net [get_bd_pins fk33_seam_0/d_rel_mask] [get_bd_pins card/rel_mask]
connect_bd_net [get_bd_pins fk33_seam_0/d_tok_ack] [get_bd_pins card/tok_ack]
connect_bd_net [get_bd_pins fk33_seam_0/d_rdata] [get_bd_pins card/d_rdata]
connect_bd_net [get_bd_pins fk33_seam_0/d_rvalid] [get_bd_pins card/d_rvalid]
connect_bd_net [get_bd_pins fk33_seam_0/hw_we] [get_bd_pins card/hw_we]
connect_bd_net [get_bd_pins fk33_seam_0/hw_reg] [get_bd_pins card/hw_reg]
connect_bd_net [get_bd_pins fk33_seam_0/hw_addr] [get_bd_pins card/hw_addr]
connect_bd_net [get_bd_pins fk33_seam_0/hw_data] [get_bd_pins card/hw_data]
connect_bd_net [get_bd_pins fk33_seam_0/hr_reg] [get_bd_pins card/hr_reg]
connect_bd_net [get_bd_pins fk33_seam_0/hr_addr] [get_bd_pins card/hr_addr]
connect_bd_net [get_bd_pins fk33_seam_0/d_a_arena] [get_bd_pins card/a_arena_base]
connect_bd_net [get_bd_pins fk33_seam_0/d_bst_base] [get_bd_pins card/bst_state_base]

# ---- B and C onto the grant -----------------------------------------------
connect_bd_net [get_bd_pins bcgrant/b_arvalid] [get_bd_pins card/bst_arvalid]
connect_bd_net [get_bd_pins bcgrant/b_arready] [get_bd_pins card/bst_arready]
connect_bd_net [get_bd_pins bcgrant/b_araddr] [get_bd_pins card/bst_araddr]
connect_bd_net [get_bd_pins bcgrant/b_arlen] [get_bd_pins card/bst_arlen]
connect_bd_net [get_bd_pins bcgrant/b_rvalid] [get_bd_pins card/bst_rvalid]
connect_bd_net [get_bd_pins bcgrant/b_rready] [get_bd_pins card/bst_rready]
connect_bd_net [get_bd_pins bcgrant/b_rdata] [get_bd_pins card/bst_rdata]
connect_bd_net [get_bd_pins bcgrant/b_rlast] [get_bd_pins card/bst_rlast]
connect_bd_net [get_bd_pins bcgrant/b_awvalid] [get_bd_pins card/bst_awvalid]
connect_bd_net [get_bd_pins bcgrant/b_awready] [get_bd_pins card/bst_awready]
connect_bd_net [get_bd_pins bcgrant/b_awaddr] [get_bd_pins card/bst_awaddr]
connect_bd_net [get_bd_pins bcgrant/b_awlen] [get_bd_pins card/bst_awlen]
connect_bd_net [get_bd_pins bcgrant/b_wvalid] [get_bd_pins card/bst_wvalid]
connect_bd_net [get_bd_pins bcgrant/b_wready] [get_bd_pins card/bst_wready]
connect_bd_net [get_bd_pins bcgrant/b_wdata] [get_bd_pins card/bst_wdata]
connect_bd_net [get_bd_pins bcgrant/b_wlast] [get_bd_pins card/bst_wlast]
connect_bd_net [get_bd_pins bcgrant/b_bvalid] [get_bd_pins card/bst_bvalid]
connect_bd_net [get_bd_pins bcgrant/b_bready] [get_bd_pins card/bst_bready]
connect_bd_net [get_bd_pins bcgrant/c0_arvalid] [get_bd_pins card/kv0_arvalid]
connect_bd_net [get_bd_pins bcgrant/c0_arready] [get_bd_pins card/kv0_arready]
connect_bd_net [get_bd_pins bcgrant/c0_araddr] [get_bd_pins card/kv0_araddr]
connect_bd_net [get_bd_pins bcgrant/c0_arlen] [get_bd_pins card/kv0_arlen]
connect_bd_net [get_bd_pins bcgrant/c0_rvalid] [get_bd_pins card/kv0_rvalid]
connect_bd_net [get_bd_pins bcgrant/c0_rready] [get_bd_pins card/kv0_rready]
connect_bd_net [get_bd_pins bcgrant/c0_rdata] [get_bd_pins card/kv0_rdata]
connect_bd_net [get_bd_pins bcgrant/c0_rlast] [get_bd_pins card/kv0_rlast]
connect_bd_net [get_bd_pins bcgrant/c1_arvalid] [get_bd_pins card/kv1_arvalid]
connect_bd_net [get_bd_pins bcgrant/c1_arready] [get_bd_pins card/kv1_arready]
connect_bd_net [get_bd_pins bcgrant/c1_araddr] [get_bd_pins card/kv1_araddr]
connect_bd_net [get_bd_pins bcgrant/c1_arlen] [get_bd_pins card/kv1_arlen]
connect_bd_net [get_bd_pins bcgrant/c1_rvalid] [get_bd_pins card/kv1_rvalid]
connect_bd_net [get_bd_pins bcgrant/c1_rready] [get_bd_pins card/kv1_rready]
connect_bd_net [get_bd_pins bcgrant/c1_rdata] [get_bd_pins card/kv1_rdata]
connect_bd_net [get_bd_pins bcgrant/c1_rlast] [get_bd_pins card/kv1_rlast]
connect_bd_net [get_bd_pins bcgrant/c_awvalid] [get_bd_pins card/kv_awvalid]
connect_bd_net [get_bd_pins bcgrant/c_awready] [get_bd_pins card/kv_awready]
connect_bd_net [get_bd_pins bcgrant/c_awaddr] [get_bd_pins card/kv_awaddr]
connect_bd_net [get_bd_pins bcgrant/c_awlen] [get_bd_pins card/kv_awlen]
connect_bd_net [get_bd_pins bcgrant/c_wvalid] [get_bd_pins card/kv_wvalid]
connect_bd_net [get_bd_pins bcgrant/c_wready] [get_bd_pins card/kv_wready]
connect_bd_net [get_bd_pins bcgrant/c_wdata] [get_bd_pins card/kv_wdata]
connect_bd_net [get_bd_pins bcgrant/c_wlast] [get_bd_pins card/kv_wlast]
connect_bd_net [get_bd_pins bcgrant/c_bvalid] [get_bd_pins card/kv_bvalid]
connect_bd_net [get_bd_pins bcgrant/c_bready] [get_bd_pins card/kv_bready]

# THE REQUESTS.  Neither B nor C exposes a `want the bus` line, and their
# `busy` outputs are the WRONG signal: busy means `I have traffic in
# flight`, which cannot be asserted before the grant is held, so using it
# would be circular -- no grant without traffic, no traffic without a
# grant.  A master's own VALID is the correct request: AXI requires VALID
# to stay asserted until READY, so a denied requester holds its request up
# by the rules of the protocol and no separate handshake is needed.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 b_req_or
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {or}] [get_bd_cells b_req_or]
connect_bd_net [get_bd_pins card/bst_arvalid] [get_bd_pins b_req_or/Op1]
connect_bd_net [get_bd_pins card/bst_awvalid] [get_bd_pins b_req_or/Op2]
connect_bd_net [get_bd_pins b_req_or/Res]   [get_bd_pins bcgrant/b_req]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 c_req_or0
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {or}] [get_bd_cells c_req_or0]
connect_bd_net [get_bd_pins card/kv0_arvalid] [get_bd_pins c_req_or0/Op1]
connect_bd_net [get_bd_pins card/kv1_arvalid] [get_bd_pins c_req_or0/Op2]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 c_req_or1
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {or}] [get_bd_cells c_req_or1]
connect_bd_net [get_bd_pins c_req_or0/Res]  [get_bd_pins c_req_or1/Op1]
connect_bd_net [get_bd_pins card/kv_awvalid]  [get_bd_pins c_req_or1/Op2]
connect_bd_net [get_bd_pins c_req_or1/Res]  [get_bd_pins bcgrant/c_req]

# ---- the grant's pool onto the two SAXI the budget leaves -----------------
# These two are CONFIG.USER_SAXI_nn {false} in the engine-only build and
# have to be turned on here.  Every ENABLED port exposes its own ACLK and
# ARESET_N and leaving them dangling fails HDL generation with 41-758.
# A CLOCK CONVERTER PER PORT, and the engine is why it is needed HERE and
# not there.  fk33_engine has TWO clock ports -- core_clk and hbm_aclk --
# because matvec_int4_desc_axi carries its own async_fifo and crosses the
# domain INSIDE the unit.  The grant does not: it is one clock domain, and
# its requesters (the card's B and C) are in the core domain, so its
# masters come out at clk_out3 while every HBM SAXI is on xdma/axi_aclk.
# Connecting them directly fails with four BD 41-237 errors -- FREQ_HZ
# 200000000 against 250000000 and CLK_DOMAIN clk_out1 against axi_aclk --
# which name the symptom and not the cause.
#
# axi_clock_converter rather than a smartconnect: SmartConnect speaks
# AXI4/AXI4-Lite, and BOTH ends here are AXI3 (the grant's 4-bit length
# above, and the HBM slave itself), so a smartconnect would have to
# protocol-convert twice to do a job that is purely a domain crossing.
set_property CONFIG.USER_SAXI_30 {true} [get_bd_cells hbm]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 bc_cdc0
set_property -dict [list CONFIG.PROTOCOL {AXI3}] [get_bd_cells bc_cdc0]
connect_bd_intf_net [get_bd_intf_pins bcgrant/m0] [get_bd_intf_pins bc_cdc0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins bc_cdc0/M_AXI] [get_bd_intf_pins hbm/SAXI_30]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins bc_cdc0/s_axi_aclk]
connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins bc_cdc0/s_axi_aresetn]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins bc_cdc0/m_axi_aclk]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins bc_cdc0/m_axi_aresetn]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_30_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_30_ARESET_N]
# READ BACK.  Vivado silently ignores set_property on a CONFIG name an
# object does not have, so an IP that quietly stayed AXI4 would fail
# again at the far end with the same unhelpful 41-237.
set _p [get_property CONFIG.PROTOCOL [get_bd_cells bc_cdc0]]
if {$_p ne "AXI3"} {
    error "FK33_CARD FAIL: bc_cdc0 PROTOCOL is \"$_p\", not AXI3."
}
puts "FK33_CARD bc_cdc0 PROTOCOL $_p -> SAXI_30"
set_property CONFIG.USER_SAXI_31 {true} [get_bd_cells hbm]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 bc_cdc1
set_property -dict [list CONFIG.PROTOCOL {AXI3}] [get_bd_cells bc_cdc1]
connect_bd_intf_net [get_bd_intf_pins bcgrant/m1] [get_bd_intf_pins bc_cdc1/S_AXI]
connect_bd_intf_net [get_bd_intf_pins bc_cdc1/M_AXI] [get_bd_intf_pins hbm/SAXI_31]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins bc_cdc1/s_axi_aclk]
connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins bc_cdc1/s_axi_aresetn]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins bc_cdc1/m_axi_aclk]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins bc_cdc1/m_axi_aresetn]
connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_31_ACLK]
connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_31_ARESET_N]
# READ BACK.  Vivado silently ignores set_property on a CONFIG name an
# object does not have, so an IP that quietly stayed AXI4 would fail
# again at the far end with the same unhelpful 41-237.
set _p [get_property CONFIG.PROTOCOL [get_bd_cells bc_cdc1]]
if {$_p ne "AXI3"} {
    error "FK33_CARD FAIL: bc_cdc1 PROTOCOL is \"$_p\", not AXI3."
}
puts "FK33_CARD bc_cdc1 PROTOCOL $_p -> SAXI_31"
foreach i {30 31} {
    set v [get_property CONFIG.USER_SAXI_$i [get_bd_cells hbm]]
    if {$v ne "true"} {
        error "FK33_CARD FAIL: USER_SAXI_$i is \"$v\", not true. The grant has nowhere to go."
    }
    puts "FK33_CARD SAXI_$i ENABLED"
}

# THE CARD'S OWN VIEW OF THE ENGINE, assigned HERE and not in ENGINE_ADDR.
# `a_awaddr` is 8 bits, so this master can reach 256 bytes; ENGINE_ADDR
# maps the same slave at 4K for the HOST, and an unqualified
# assign_bd_address covers EVERY master that can reach the segment. It
# therefore tried to give this 8-bit master a 4K window and failed with
# BD 41-1075 -- `the proposed range 4K is greater than the maximum range
# 256`. Assigning the narrow space first, with an explicit target, leaves
# ENGINE_ADDR's later call to find this one already mapped and skip it.
assign_bd_address -offset 0x00000000 -range 256 \
    -target_address_space [get_bd_addr_spaces card/a] \
    [get_bd_addr_segs {eng/s_axi/reg0}]
set _cseg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces card/a]]
if {[llength $_cseg] != 1} {
    error "FK33_CARD FAIL: card/a maps [llength $_cseg] segments, not 1. The card cannot issue A jobs."
}
puts "FK33_CARD card/a maps $_cseg"

# ---- end subsystems B, C, D -----------------------------------------------
regenerate_bd_layout
save_bd_design

assign_bd_address -offset 0x00003000 -range 4K [get_bd_addr_segs {system_management_wiz_0/S_AXI_LITE/Reg}]
assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_gpio_0/S_AXI/Reg}]

# ---- bring-up peripheral address map (gen_pcieep.py) -----------------------
# On the AXI-Lite BAR, which the XDMA IP sizes at 128 KB.  Everything here must
# fit in 0x00000..0x1FFFF or address assignment fails.
assign_bd_address -offset 0x0000A000  -range 4K  [get_bd_addr_segs {fk33_id/S_AXI/Reg}]
assign_bd_address -offset 0x00010000  -range 8K  [get_bd_addr_segs {fk33_scratch/S_AXI/Mem0}]
# On the DMA master, deliberately ABOVE the 8 GB of HBM so a bad host offset
# lands on nothing rather than silently in memory.  Left visible to jtag_hbm as
# well as to xdma/M_AXI, so the same bytes can be read back over JTAG -- which
# is what separates "XDMA wrote the wrong thing" from "the readback is wrong".
assign_bd_address -offset 0x200000000 -range 64K [get_bd_addr_segs {fk33_dmabram/S_AXI/Mem0}]

# ---- aux register map (gen_pcieep.py) --------------------------------------
# In jtag_aux's OWN address space.  Nothing here is reachable from xdma, by
# design: these registers exist precisely for the case where xdma is dead.
#   0x0000  AUX_MAGIC     0x41555831 = "AUX1", read-only fabric constant
#   0x0008  AUX_VERSION   0x20260828
#   0x1000  UCLK_TICKS    free-running, 1 tick per 128 xdma/axi_aclk cycles
#   0x1008  UCLK_HZ       measured xdma/axi_aclk in Hz.  250000000 = the PCIe
#                         hard block is clocked; 0 = it is not, and the PERST#
#                         level says whether that is reset or a missing refclk
#   0x2000  AUX_STATUS    PERST#, its stickies, axi_aresetn, user_lnk_up
#   0x2008  POT_STATUS    the VCCINT controller.  [31:24] is the ONLY wiper
#                         this bitstream is able to write, and must read 0x44
#   0x3000  AUX_MS        milliseconds since configuration
#   0x3008  PERST_MS      AUX_MS at the FIRST deassertion of PERST#
assign_bd_address -offset 0x00000000 -range 4K [get_bd_addr_segs {aux_id/S_AXI/Reg}]
assign_bd_address -offset 0x00001000 -range 4K [get_bd_addr_segs {aux_clkst/S_AXI/Reg}]
assign_bd_address -offset 0x00002000 -range 4K [get_bd_addr_segs {aux_stat/S_AXI/Reg}]
assign_bd_address -offset 0x00003000 -range 4K [get_bd_addr_segs {aux_time/S_AXI/Reg}]

# ---- thermal register map (gen_pcieep.py) ----------------------------------
# On jtag_aux, readable with the PCIe link DOWN:
#   0x4000  THERM_STATUS  halt/warn/valid/cause/trip count/stickies, [31]=1
#   0x4008  THERM_TEMPS   [9:0] die code [16:10] HBM0 [23:17] HBM1 [31:24] die C
#   0x5000  THERM_PEAK    the same fields, peak-hold
#   0x5008  THERM_TRIP    the same code fields captured at the trip + cause
#   0x6000  THERM_CTL     WRITE.  [31:16] must be 0xC1EA, [0] clear trip,
#                         [1] clear peak.  Edge triggered.
#   0x6008  THERM_CANARY  count of compute-domain canary toggles
assign_bd_address -offset 0x00004000 -range 4K [get_bd_addr_segs {aux_therm/S_AXI/Reg}]
assign_bd_address -offset 0x00005000 -range 4K [get_bd_addr_segs {aux_peak/S_AXI/Reg}]
assign_bd_address -offset 0x00006000 -range 4K [get_bd_addr_segs {aux_ctl/S_AXI/Reg}]
# On the PCIe AXI-Lite BAR, the same five words plus the same control:
#   0xB000/0xB008  THERM_STATUS / THERM_TEMPS
#   0xC000/0xC008  THERM_PEAK   / THERM_TRIP
#   0xD000/0xD008  THERM_CTL    / THERM_CANARY
assign_bd_address -offset 0x0000B000 -range 4K [get_bd_addr_segs {fk33_therm/S_AXI/Reg}]
assign_bd_address -offset 0x0000C000 -range 4K [get_bd_addr_segs {fk33_thermp/S_AXI/Reg}]
assign_bd_address -offset 0x0000D000 -range 4K [get_bd_addr_segs {fk33_thermc/S_AXI/Reg}]

# ---- subsystem A address map (gen_pcieep.py) -------------------------------
# On the PCIe AXI-Lite BAR:
#   0x12000  the engine's own map (DESC_PTR, CTRL/GO, STATUS, ERR_INFO, ID,
#            ADDR_CAP, CAPS, DESC_WORDS, Y_IDX/Y_LO/Y_HI/Y_EXP, CYCLES, BEATS,
#            STARVED).  Documented in rtl/matvec_int4_desc_axi.vhd; it does not
#            change shape with geometry, which is the whole point of the
#            descriptor-in-memory decision.
#   0x13000  the activation writer (X_ADDR, X_DATA, ENG_STAT, ENG_ID).
#            Documented in rtl/fk33_engine.vhd.
# Both fit under the 128 KB the XDMA IP sizes the BAR at.  They start at
# 0x12000 and not at 0x11000: fk33_scratch is 8 KB at 0x10000, so it occupies
# 0x10000..0x11FFF, and 0x11000 collides with its second 4 KB.  MEASURED -- the
# --bd-only gate refused it with BD 41-1075 in 90 seconds, which is what that
# gate is for.
foreach sp {jtag_axil/Data xdma/M_AXI_LITE} {
    assign_bd_address -offset 0x00012000 -range 4K \
        -target_address_space [get_bd_addr_spaces $sp] \
        [get_bd_addr_segs {eng/s_axi/reg0}]
}
assign_bd_address -offset 0x00013000 -range 4K [get_bd_addr_segs {eng/s_axix/reg0}]

# EVERY engine master sees ALL 32 pseudo-channel segments, i.e. the whole 8 GiB.
#
# That is not laziness and it is not a bandwidth claim.  Under the flat packed
# layout the 27 sub-regions of one tensor are contiguous, so a given lane's
# bytes for different tensors are scattered across the whole address space; a
# master restricted to its own stack's 16 segments would DECERR on more than
# half the tensors.  Giving every master the full decode is what makes the
# layout that exists today work at all, and it is a superset of anything the
# residency map's 27-lane arena scheme would later want -- that scheme only
# ever REMOVES segments.  It also costs nothing in the fabric: the engine
# connects DIRECTLY to the HBM IP with no interconnect in the path, so
# assign_bd_address here constrains Vivado's address editor and the IP's own
# switch decode, not a decoder we pay for.
#
# MEASURED, from the IP, docs/2026-08-28_can-27-read-masters-be-served.md 2.1:
# with USER_SWITCH_ENABLE_00/01 TRUE -- which this design sets -- every one of
# the 32 SAXI ports already exposes all 32 HBM_MEM segments.  The stack rule in
# the residency map is a build discipline, not a property of the silicon.
foreach pair {{m00 1} {m01 2} {m02 3} {m03 4} {m04 5} {m05 6} {m06 7} {m07 8} {m08 9} {m09 10} {m10 11} {m11 12} {m12 13} {m13 14} {m14 15} {m15 17} {m16 18} {m17 19} {m18 20} {m19 21} {m20 22} {m21 23} {m22 24} {m23 25} {m24 26} {m25 27} {m26 28} {m27 29}} {
    set m  [lindex $pair 0]
    set sx [lindex $pair 1]
    for {set s 0} {$s < 32} {incr s} {
        assign_bd_address \
            -target_address_space [get_bd_addr_spaces eng/${m}_axi] \
            -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \
            [get_bd_addr_segs [format "hbm/SAXI_%02d/HBM_MEM%02d" $sx $s]]
    }
}

# ---- host seam address map (gen_pcieep.py) ---------------------------------
# 0xE000, 4 KB, on the PCIe AXI-Lite BAR.  This is board row N2's missing
# line: server/fk33_seam.h has declared this base since TRACK SERVER and
# nothing decoded it.  See the SEAM_BASE block in gen_pcieep.py for why 0xE000
# and not another hole, and check_bar_map() for what stops it colliding.
assign_bd_address -offset 0x0000E000 -range 4K [get_bd_addr_segs {fk33_seam_0/s_axi/reg0}]


if {$HBMGlobalSwitch == 1} {
    assign_bd_address -offset  0x00000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM00 }]
    assign_bd_address -offset  0x10000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM01 }]
    assign_bd_address -offset  0x20000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM02 }]
    assign_bd_address -offset  0x30000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM03 }]
    assign_bd_address -offset  0x40000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM04 }]
    assign_bd_address -offset  0x50000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM05 }]
    assign_bd_address -offset  0x60000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM06 }]
    assign_bd_address -offset  0x70000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM07 }]
    assign_bd_address -offset  0x80000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM08 }]
    assign_bd_address -offset  0x90000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM09 }]
    assign_bd_address -offset  0xA0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM10 }]
    assign_bd_address -offset  0xB0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM11 }]
    assign_bd_address -offset  0xC0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM12 }]
    assign_bd_address -offset  0xD0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM13 }]
    assign_bd_address -offset  0xE0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM14 }]
    assign_bd_address -offset  0xF0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM15 }]
    assign_bd_address -offset 0x100000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM16 }]
    assign_bd_address -offset 0x110000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM17 }]
    assign_bd_address -offset 0x120000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM18 }]
    assign_bd_address -offset 0x130000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM19 }]
    assign_bd_address -offset 0x140000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM20 }]
    assign_bd_address -offset 0x150000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM21 }]
    assign_bd_address -offset 0x160000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM22 }]
    assign_bd_address -offset 0x170000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM23 }]
    assign_bd_address -offset 0x180000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM24 }]
    assign_bd_address -offset 0x190000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM25 }]
    assign_bd_address -offset 0x1A0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM26 }]
    assign_bd_address -offset 0x1B0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM27 }]
    assign_bd_address -offset 0x1C0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM28 }]
    assign_bd_address -offset 0x1D0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM29 }]
    assign_bd_address -offset 0x1E0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM30 }]
    assign_bd_address -offset 0x1F0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM31 }]

    exclude_seg_if hbm/SAXI_16/HBM_MEM00 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM01 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM02 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM03 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM04 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM05 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM06 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM07 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM08 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM09 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM10 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM11 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM12 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM13 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM14 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM15 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM16 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM17 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM18 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM19 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM20 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM21 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM22 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM23 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM24 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM25 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM26 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM27 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM28 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM29 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM30 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM31 xdma/M_AXI

    exclude_seg_if hbm/SAXI_16/HBM_MEM00 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM01 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM02 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM03 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM04 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM05 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM06 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM07 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM08 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM09 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM10 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM11 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM12 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM13 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM14 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM15 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM16 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM17 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM18 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM19 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM20 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM21 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM22 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM23 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM24 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM25 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM26 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM27 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM28 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM29 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM30 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM31 jtag_hbm/Data
} else {
    assign_bd_address -offset  0x00000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM00 }]
    assign_bd_address -offset 0x100000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM16 }]

    exclude_seg_if hbm/SAXI_00/HBM_MEM01 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM17 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM16 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM00 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM17 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM01 jtag_hbm/Data

    if {$EnablePCIe == 1} {
        exclude_seg_if hbm/SAXI_00/HBM_MEM01 xdma/M_AXI
        exclude_seg_if hbm/SAXI_00/HBM_MEM16 xdma/M_AXI
        exclude_seg_if hbm/SAXI_00/HBM_MEM17 xdma/M_AXI
        exclude_seg_if hbm/SAXI_16/HBM_MEM00 xdma/M_AXI
        exclude_seg_if hbm/SAXI_16/HBM_MEM01 xdma/M_AXI
        exclude_seg_if hbm/SAXI_16/HBM_MEM17 xdma/M_AXI
    }
}
   
#set_property PR_FLOW 1 [current_project]
add_files -fileset constrs_1 -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pcieep.xdc
set_property target_constrs_file /home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pcieep.xdc [current_fileset -constrset]

set_property synth_checkpoint_mode None [get_files ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/bd.bd]
puts "FK33_CARD synth_checkpoint_mode = [get_property synth_checkpoint_mode [get_files ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/bd.bd]]"
make_wrapper -files [get_files ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/bd.bd] -top
add_files -norecurse ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/hdl/bd_wrapper.v
update_compile_order -fileset sources_1
set_property top bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
if {[get_property top [current_fileset]] ne "bd_wrapper"} {
    error "FK33_TOP FAIL: top is [get_property top [current_fileset]], not bd_wrapper. The engine's 28 AXI masters would become top-level I/O."
}
puts "FK33_TOP [get_property top [current_fileset]]"

set fk33_strategy "Performance_RefinePlacement"
if {[info exists ::env(FK33_IMPL_STRATEGY)] && $::env(FK33_IMPL_STRATEGY) ne ""} {
    set fk33_strategy $::env(FK33_IMPL_STRATEGY)
}
set_property strategy $fk33_strategy [get_runs impl_1]
if {[get_property strategy [get_runs impl_1]] ne $fk33_strategy} {
    error "FK33_STRATEGY FAIL: asked for '$fk33_strategy', run reports '[get_property strategy [get_runs impl_1]]'. set_property accepted it silently and it did not apply."
}
puts "FK33_IMPL_STRATEGY [get_property strategy [get_runs impl_1]]"
add_files -fileset constrs_1 -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pblock.xdc
set_property used_in_synthesis false [get_files /home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pblock.xdc]
set_property used_in_implementation true [get_files /home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pblock.xdc]
if {[get_property used_in_synthesis [get_files /home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pblock.xdc]]} {
    error "FK33_PBLK FAIL: fk33_pblock.xdc is still used_in_synthesis. It addresses bd_i/eng/inst/eng/dut/core, a path that exists only in the LINKED design, so synthesis would read it, match nothing, leave an empty pb_core behind and say so only as a Vivado 12-180 warning."
}
puts "FK33_PBLK fk33_pblock.xdc added, implementation only"

#open_hw
#create_hw_cfgmem -hw_device [lindex [get_hw_devices xcvu33p_0] 0] [lindex [get_cfgmem_parts {mt25qu256-spi-x1_x2_x4}] 0]
#set_property PROGRAM.BLANK_CHECK  0 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#set_property PROGRAM.ERASE  1 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#set_property PROGRAM.CFG_PROGRAM  1 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#set_property PROGRAM.VERIFY  1 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#set_property PROGRAM.CHECKSUM  0 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#close_hw




# ---------------------------------------------------------------- build
# IP upgrade first, and REPORT it.  Crossing 2022.2 -> 2023.2 can revise the HBM
# controller, the smartconnect and xdma; a stale IP either fails to generate or,
# worse, generates with different defaults.  report_ip_status output is the
# thing to read if this build misbehaves.

# ---- thermal sensor availability (gen_pcieep.py) --------------------------
# Vivado SILENTLY IGNORES set_property on a CONFIG name that does not apply to
# an IP, so asking for temp_out is not evidence of getting it.  Each check
# below is a way the thermal guard can be built present, timing-clean, and
# BLIND: without ENABLE_TEMP_BUS there is no die temperature in the fabric at
# all, and the guard would then sit permanently halted on a stale die sensor.
# This runs unconditionally.  It costs a few seconds and it is the difference
# between a thermal guard and a thermal guard-shaped hole.
foreach p {ENABLE_TEMP_BUS USER_TEMP_ALARM TEMPERATURE_ALARM_TRIGGER            TEMPERATURE_ALARM_RESET TEMPERATURE_ALARM_OT_TRIGGER            TEMPERATURE_ALARM_OT_RESET REFERENCE INTERFACE_SELECTION} {
    puts "FK33_SYSMON $p = [get_property CONFIG.$p [get_bd_cells system_management_wiz_0]]"
}
if {[get_property CONFIG.ENABLE_TEMP_BUS [get_bd_cells system_management_wiz_0]] ne "true"} {
    error "FK33_THERM FAIL: CONFIG.ENABLE_TEMP_BUS did not take.  There is no die temperature bus in the fabric, so the thermal guard has no die sensor."
}
if {[get_property CONFIG.USER_TEMP_ALARM [get_bd_cells system_management_wiz_0]] ne "true"} {
    error "FK33_THERM FAIL: CONFIG.USER_TEMP_ALARM did not take, so user_temp_alarm_out does not exist and the die has only ONE comparator instead of two."
}
# The four HBM pins the guard needs.  They exist with no reconfiguration --
# DRAM_0_* unconditionally and DRAM_1_* because USER_HBM_STACK is 2 -- but if a
# future edit ever drops to one stack they would vanish silently.
foreach hp {DRAM_0_STAT_TEMP DRAM_1_STAT_TEMP DRAM_0_STAT_CATTRIP DRAM_1_STAT_CATTRIP} {
    set hpin [get_bd_pins -quiet hbm/$hp]
    if {![llength $hpin]} {
        error "FK33_THERM FAIL: hbm/$hp does not exist at this IP configuration"
    }
    set hn [get_bd_nets -quiet -of_objects $hpin]
    if {![llength $hn]} {
        error "FK33_THERM FAIL: hbm/$hp is UNCONNECTED.  The stacks' own temperature is going nowhere, which is the defect this build exists to fix."
    }
    puts "FK33_THERM hbm/$hp connected"
}

# ---- unconnected input pins (gen_pcieep.py) --------------------------------
# THE DISCRIMINATOR IS VIVADO'S OWN.  The first version of this check walked
# every input pin with no net and FAILED on 37 of them -- MEASURED 2026-09-18
# --bd-only: 32 hbm/AXI_nn_WDATA_PARITY, two aux_reset_in, two
# mb_debug_sys_rst and xdma/usr_irq_req -- every one an IP pin that carries a
# default and that validate_bd_design does NOT warn about.  A check stricter
# than the tool it replaces needs an allowlist, and an allowlist is a second
# place for the truth to live.  So the rule is not re-derived here: run the
# validation and turn ITS 41-759 into a failure.
#
# The message shape is fixed by Vivado: the warning line, then the sentence
# "Please check your design and connect them as needed:", then one pin path
# per line, then a blank line.  Anchored on the message ID, not on prose.
set fk33_vmsg ""
if {[catch {validate_bd_design -force} fk33_vmsg]} {
    error "FK33_BD_VALIDATE FAIL (pre-wrapper): $fk33_vmsg"
}
set fk33_uncon_bad {}
# The pins are read from the cells the way the warning lists them: every
# input pin left with no net, restricted to MODULE-REFERENCE cells (the card,
# the seam, the engine).  IP cells declare a default for a floating input and
# validate_bd_design does not warn about those; a user module has no such
# default and 41-759 names exactly its pins.  That is the discriminator, and
# it is Vivado's rather than one invented here.
# MEASURED 2026-09-18 by a probe against the live project, because the first
# version of this loop was wrong in two ways that made it fire on NOTHING:
#   * a module-reference cell reports TYPE "ip", the same as any packaged IP.
#     What distinguishes it is the VLNV, xilinx.com:module_ref:<entity>:1.0.
#   * a top-level pin's PARENT property is EMPTY, so get_bd_cells of it
#     resolves to the root, whose TYPE is "hier" -- every pin was excluded.
# The attribution control caught it: the exact pre-fix state (both nets
# deleted from the Tcl) ran through the first version and reported count=0.
foreach cell [get_bd_cells -hierarchical -quiet -filter {VLNV =~ "*:module_ref:*"}] {
    foreach pin [get_bd_pins -quiet -of_objects $cell -filter {DIR == I && INTF == false}] {
        if {[llength [get_bd_nets -quiet -of_objects $pin]] > 0} { continue }
        lappend fk33_uncon_bad [get_property PATH $pin]
    }
}
puts "FK33_UNCONNECTED count=[llength $fk33_uncon_bad]"
foreach p $fk33_uncon_bad { puts "FK33_UNCONNECTED pin $p" }
if {[llength $fk33_uncon_bad] > 0} {
    error "FK33_UNCONNECTED FAIL: [llength $fk33_uncon_bad] module input pin(s) have no driver and no tie-off: $fk33_uncon_bad.  An unconnected input is ZERO.  Connect it or tie it off explicitly."
}

# ---- no-card block-design check (gen_pcieep.py) ----------------------------
# FK33_STOP_AFTER_BD=1 stops here.  Everything above this line is IP
# configuration and address assignment, which is the part that can be checked
# without a card and without an hour of implementation.  It matters more than
# it sounds: Vivado SILENTLY IGNORES set_property on a CONFIG.* name that does
# not exist for that IP, so a typo in any of the xdma settings above produces a
# perfectly clean build of the wrong design.  Reading the parameters back is
# the only thing that catches it.
if {[info exists ::env(FK33_STOP_AFTER_BD)]} {
    puts "==== FK33_BD_CHECK ===="
    foreach p {pl_link_cap_max_link_width pl_link_cap_max_link_speed \
               axi_data_width xdma_rnum_chnl xdma_wnum_chnl \
               axilite_master_en axilite_master_size axilite_master_scale \
               vendor_id pf0_device_id pf0_subsystem_vendor_id pf0_subsystem_id \
               pcie_blk_locn axisten_freq} {
        if {[llength [get_bd_cells -quiet xdma]]} {
            puts "FK33_CFG xdma.$p = [get_property CONFIG.$p [get_bd_cells xdma]]"
        }
    }
    foreach c {pcie2axil pcie2hbm auxconnect} {
        puts "FK33_CFG $c.NUM_SI = [get_property CONFIG.NUM_SI [get_bd_cells $c]]"
        puts "FK33_CFG $c.NUM_MI = [get_property CONFIG.NUM_MI [get_bd_cells $c]]"
    }
    foreach c {fk33_id fk33_scratch fk33_dmabram core_reset axil2eng} {
        if {![llength [get_bd_cells -quiet $c]]} { puts "FK33_CFG MISSING CELL $c" }
    }
    # SUBSYSTEM A.  Three ways this build can come out looking healthy and be
    # wrong, each read back from the tool rather than assumed:
    #   * a SAXI port that should be enabled is not, so a master is dangling
    #   * an enabled port's ACLK or ARESET_N is undriven (41-758 catches that at
    #     HDL generation, but only if it is still undriven THEN)
    #   * an engine master interface never got connected to an HBM port
    # READ FROM THE DESIGN, not from a generator flag.  Whether the card is in
    # this build is a fact about the block design, and asking the tool means
    # this check cannot disagree with what was actually built.
    set ::fk33_card_on [expr {[llength [get_bd_cells -quiet card]] > 0}]
    # AND WHETHER SUBSYSTEM A IS IN IT, read the same way and for the same
    # reason: FK33_ENG=0 omits the engine deliberately, and every expectation
    # below has to follow the configuration rather than assert the shipping
    # one.  An enabled SAXI port with no master is not a harmless leftover --
    # its ACLK and ARESET_N reach HDL generation undriven and fail with
    # 41-758 -- so with no engine the 28 ports must be OFF, which is a real
    # check and not a skip.
    set ::fk33_eng_on [expr {[llength [get_bd_cells -quiet eng]] > 0}]
    puts "FK33_ENG present=$::fk33_eng_on card=$::fk33_card_on"
    set engbad 0
    foreach i {01 02 03 04 05 06 07 08 09 10 11 12 13 14 15                17 18 19 20 21 22 23 24 25 26 27 28 29} {
        set v [get_property CONFIG.USER_SAXI_$i [get_bd_cells hbm]]
        set _want [expr {$::fk33_eng_on ? "true" : "false"}]
        if {[string tolower $v] ne $_want} {
            puts "FK33_ENG SAXI_$i = $v, must be $_want"
            incr engbad
        }
        if {$::fk33_eng_on} {
            foreach pin [list hbm/AXI_${i}_ACLK hbm/AXI_${i}_ARESET_N] {
                if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins -quiet $pin]]]} {
                    puts "FK33_ENG $pin IS UNDRIVEN"
                    incr engbad
                }
            }
        }
    }
    foreach i {30 31} {
        set v [get_property CONFIG.USER_SAXI_$i [get_bd_cells hbm]]
        # THE EXPECTATION FOLLOWS THE CONFIGURATION.  Without the card these two
        # are spare and MUST stay off, or a later edit could quietly consume the
        # only ports B and C will ever have.  With the card they are the grant's
        # pool and must be ON.  Hardcoding `false` made this check report
        # bad=2 on a correct card build -- and the build passed anyway, which
        # is the more serious half: see the abort added below.
        set _want [expr {$::fk33_card_on ? "true" : "false"}]
        puts "FK33_ENG SAXI_$i = $v (must be $_want)"
        if {[string tolower $v] ne $_want} { incr engbad }
    }
    if {$::fk33_eng_on} {
        for {set m 0} {$m < 28} {incr m} {
            set ip [get_bd_intf_pins -quiet [format "eng/m%02d_axi" $m]]
            if {![llength $ip]} { puts "FK33_ENG eng/m${m}_axi MISSING"; incr engbad; continue }
            if {![llength [get_bd_intf_nets -quiet -of_objects $ip]]} {
                puts [format "FK33_ENG eng/m%02d_axi IS NOT CONNECTED" $m]
                incr engbad
            }
        }
    }
    puts "FK33_ENG portcheck bad=$engbad (must be 0)"
    # AND IT MUST ACTUALLY STOP THE BUILD.  Until 2026-09-07 this counter was
    # printed and never acted on, so `bad=2` sailed through a --bd-only run
    # that reported success.  A check whose result nothing branches on is
    # decoration: every fault it counts -- a dangling master, an undriven
    # ACLK, an unconnected m..._axi, an undriven compute_halt -- was being
    # reported into a log nobody reads and then ignored.
    if {$engbad != 0} {
        error "FK33_ENG FAIL: portcheck bad=$engbad. See the FK33_ENG lines above for which."
    }
    if {$::fk33_eng_on} {
        puts "FK33_ENG masters=28 halt=[llength [get_bd_nets -quiet -of_objects [get_bd_pins eng/compute_halt]]]"
        if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins eng/compute_halt]]]} {
            puts "FK33_ENG compute_halt IS UNDRIVEN -- the thermal guard cannot stop the array"
            incr engbad
        }
    } else {
        # THE THERMAL GUARD HAS NOTHING TO STOP, and that is the honest state to
        # report rather than a silent pass: with no engine there is no HBM read
        # traffic and no DSP array, so compute_halt has no consumer.  B and C in
        # the card are NOT halt-gated -- that path does not exist -- which is one
        # more thing a bitstream built this way does not prove.
        puts "FK33_ENG absent: no masters, no compute_halt consumer, no thermal throttle path"
    }
    # The aux domain.  A missing cell here means the bitstream is blind with
    # the link down, which is the exact condition it exists for, so name them.
    foreach c {fk33_aux_0 util_ds_buf_1 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time                aux_therm aux_peak aux_ctl fk33_therm_0 fk33_therm fk33_thermp fk33_thermc} {
        if {![llength [get_bd_cells -quiet $c]]} { puts "FK33_CFG MISSING AUX CELL $c" }
    }
    # Prove, from the tool rather than from the diagram, that not one pin of the
    # aux branch is driven by xdma.  This is the check that would catch a future
    # edit quietly joining the aux clock or reset onto the PCIe domain.
    # Exactly two aux pins may see something xdma drives, and both are MEASURED
    # SIGNALS rather than parts of the read path:
    #   fk33_aux_0/xdma_aclk     clocks a divider whose only output is a single
    #                            bit through a synchroniser
    #   fk33_aux_0/xdma_aresetn  is an input to a synchroniser
    # If axi_aclk reaches anything else in the aux branch, the read path is no
    # longer independent of the PCIe link and this build is pointless.
    #
    # fk33_therm_0 adds three more MEASURED-OR-CONSUMER pins on the PCIe clock,
    # and each is named individually rather than exempting the cell:
    #   sysmon_clk    clocks a divider on SYSMON's eoc_out, nothing else
    #   ctl_host_clk  clocks the host clear qualifier and the publication filter
    #   compute_clk   the datapath's own clock; the halt is synchronised INTO it
    # The guard's decision logic, its watchdogs and its latches are all on
    # fk33_aux_0/aux_clk, which is the point: they must survive the PCIe domain
    # dying.  If any OTHER thermal pin ever joins xdma/axi_aclk this fails.
    set auxallow {/fk33_aux_0/xdma_aclk /fk33_aux_0/xdma_aresetn                   /fk33_therm_0/sysmon_clk /fk33_therm_0/ctl_host_clk                   /fk33_therm_0/compute_clk}
    set auxbad 0
    foreach c {fk33_aux_0 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time                aux_therm aux_peak aux_ctl fk33_therm_0} {
        foreach p [get_bd_pins -quiet $c/*] {
            if {[lsearch -exact $auxallow $p] >= 0} { continue }
            foreach n [get_bd_nets -quiet -of_objects $p] {
                foreach src [get_bd_pins -quiet -of_objects $n] {
                    if {[string match "/xdma/axi_aclk" $src]} {
                        puts "FK33_AUX_VIOLATION $p shares a net with $src"
                        incr auxbad
                    }
                }
            }
        }
    }
    puts "FK33_AUX_CLKCHECK violations=$auxbad"
    puts "FK33_CFG id_magic = [get_property CONFIG.CONST_VAL [get_bd_cells id_magic]]"
    puts "FK33_CFG id_build = [get_property CONFIG.CONST_VAL [get_bd_cells id_build]]"
    puts "==== FK33_MAP (address space / segment / offset / range) ===="
    foreach sp [get_bd_addr_spaces] {
        foreach sg [get_bd_addr_segs -quiet -of_objects $sp] {
            catch {
                puts [format "FK33_MAP %-24s %-42s %-14s %s" \
                      [get_property PATH $sp] $sg \
                      [get_property OFFSET $sg] [get_property RANGE $sg]]
            }
        }
    }
    puts "==== validate_bd_design ===="
    if {[catch {validate_bd_design -force} verr]} {
        puts "FK33_BD_VALIDATE FAIL: $verr"
        puts "FK33_BD_ONLY_DONE"
        return -code error "block design validation failed"
    }
    puts "FK33_BD_VALIDATE OK"
    puts "FK33_BD_ONLY_DONE"
    return
}

puts "==== IP status before upgrade ===="
report_ip_status
set stale [get_ips -filter {IS_LOCKED == 1 || UPGRADE_VERSIONS != ""}]
if {[llength $stale] > 0} {
    puts "==== upgrading [llength $stale] IP ===="
    upgrade_ip $stale
    report_ip_status
}


# ---------------------------------------------------------------- run guards
# GENERATED by gen_pcieep.py.  See the BUILD-HANG comment there, and
# docs/debugging/2026-08-29_noguard-three-guards.md, for the measurements each
# line rests on.  Teeth-checked by `python3 hw/fk33/gen_pcieep.py --selftest`,
# which drives these two procs under tclsh with get_runs/get_property stubbed,
# so the guard is exercised without a synthesis.
proc fk33_assert_run_started {run} {
    set r    [get_runs $run]
    set dir  [get_property DIRECTORY $r]
    set st   [get_property STATUS $r]
    if {![file isdirectory $dir]} {
        error "FK33_RUNSTART FAIL: launch_runs reported success but run '$run' has NO run directory at all ($dir), STATUS '$st'. The run never started. This is the 2026-08-29 BUILD-HANG: an unbounded wait_on_run then blocks forever on a run that does not exist -- 27.6 hours, 7 minutes of CPU. Do not wait; read the launch_runs output above this line."
    }
    if {![file exists [file join $dir runme.sh]]} {
        error "FK33_RUNSTART FAIL: run '$run' has a directory ($dir) but no runme.sh in it, STATUS '$st', so no run script was ever written. MEASURED 2026-08-29: launch_runs writes runme.sh synchronously before it returns, so this is a real failure and not a race."
    }
    puts "FK33_RUNSTART $run dir=$dir status=$st"
}
proc fk33_bound {name v} {
    # MEASURED 2026-08-29 while teeth-checking this guard: setting the limit
    # to -1 restores the ORIGINAL unbounded wait -- Vivado documents -1 as
    # "no limit" -- while satisfying every textual check on this script,
    # including the one that refuses a bare `wait_on_run`.  A bound is only a
    # bound if the number is positive, and the environment can supply it.
    if {![string is integer -strict $v] || $v <= 0} {
        error "FK33_RUNBOUND FAIL: $name is '$v'. wait_on_run -timeout treats -1 (and any non-positive value) as NO LIMIT, which is the unbounded wait that blocked a build for 27.6 hours. Give a positive number of minutes."
    }
    return $v
}
proc fk33_assert_run_done {run limit_min} {
    set r    [get_runs $run]
    set dir  [get_property DIRECTORY $r]
    set prog [get_property PROGRESS $r]
    set st   [get_property STATUS $r]
    if {$prog eq "100%"} {
        puts "FK33_RUNDONE $run $prog status=$st"
        return
    }
    error "FK33_RUNDONE FAIL: run '$run' is at $prog with STATUS '$st'. Either it failed -- read $dir/runme.log -- or it exceeded the ${limit_min}-minute bound passed to wait_on_run -timeout. MEASURED 2026-08-29: wait_on_run -timeout RETURNS rc 0 with an empty message when it expires, so this check is the only thing that turns the bound into a stop."
}

set FK33_SYNTH_MAX_MIN [fk33_bound FK33_SYNTH_MAX_MIN 360]
set FK33_IMPL_MAX_MIN  [fk33_bound FK33_IMPL_MAX_MIN  720]
if {[info exists ::env(FK33_SYNTH_MAX_MIN)]} { set FK33_SYNTH_MAX_MIN [fk33_bound FK33_SYNTH_MAX_MIN $::env(FK33_SYNTH_MAX_MIN)] }
if {[info exists ::env(FK33_IMPL_MAX_MIN)]}  { set FK33_IMPL_MAX_MIN  [fk33_bound FK33_IMPL_MAX_MIN  $::env(FK33_IMPL_MAX_MIN)] }
puts "FK33_RUNBOUND synth=$FK33_SYNTH_MAX_MIN min impl=$FK33_IMPL_MAX_MIN min"

# THE PROCESS COUNT IS `general.maxThreads`, NOT `-jobs`.  CORRECTION to the
# reasoning above, MEASURED 2026-09-08 after `synth_checkpoint_mode None` was
# in place: the run directory listing showed exactly ONE run (`synth_1`), so
# global mode HAD removed every per-IP out-of-context run -- and there were
# still TEN Vivado processes at 21.16 GB.
#
# They are not runs. They are the parallel synthesis workers Vivado forks
# INSIDE one run, which this file already records ("four at 2.36 GB each plus
# a 1.41 GB parent") and which `-jobs` has never governed. `-jobs` bounds
# concurrent RUNS; `general.maxThreads` bounds the workers within a run. Every
# earlier attempt turned the wrong knob, including the one that concluded
# `-jobs` "does not bound this build at all" -- it does bound runs, there was
# simply only ever one run to bound once global mode was on.
set_param general.maxThreads 2
puts "FK33_CARD general.maxThreads = [get_param general.maxThreads]"

# FLATTEN_HIERARCHY.  Vivado's default is `rebuilt`: flatten the WHOLE design,
# optimise across every boundary, then rebuild the hierarchy for reporting.
# On this design that default is the documented failure, twice over --
# docs/debugging/2026-09-08_card-ooc-synthesis-does-not-finish.md records two
# flat synthesis attempts of the card, ~10 hours of Vivado between them, and
# NEITHER FINISHED.  The second emitted no phase marker in 6 h 34 m while
# sitting at a comfortable 15.52 GB, so the binding constraint there was TIME,
# not memory.  cardbuild9 then hit 24.00 GB on the same flat strategy applied
# to the whole top and was still growing at 144 minutes.
#
# `none` keeps the module boundaries, so the optimiser never builds the single
# enormous flat netlist that both of those runs were grinding on.  It is the
# ONE lever that addresses both failures at once, and grep says it had never
# been set anywhere in this flow -- every previous attempt turned a
# parallelism or memory-cap knob and left the strategy alone.
#
# THE TRADE IS REAL AND IS DELIBERATELY ACCEPTED: forbidding cross-boundary
# optimisation costs QoR, so expect worse timing than the -0.422 the composed
# top reached.  Standing instruction from Oren is that a bitstream comes
# first and 200 MHz is an optimisation for afterwards, which is exactly this
# trade.  Set FK33_FLATTEN=rebuilt to get the old strategy back.
set fk33_flat "none"
if {$fk33_flat ne ""} {
  set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY $fk33_flat [get_runs synth_1]
  puts "FK33_CARD FLATTEN_HIERARCHY = [get_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY [get_runs synth_1]]"
}
launch_runs synth_1 -jobs 1
fk33_assert_run_started synth_1
wait_on_run -timeout $FK33_SYNTH_MAX_MIN synth_1
fk33_assert_run_done synth_1 $FK33_SYNTH_MAX_MIN
puts "==== synthesis done ===="

launch_runs impl_1 -to_step write_bitstream -jobs 8
fk33_assert_run_started impl_1
wait_on_run -timeout $FK33_IMPL_MAX_MIN impl_1
fk33_assert_run_done impl_1 $FK33_IMPL_MAX_MIN

open_run impl_1
puts "==== FK33 aux-domain constraint verification (implemented design) ===="
# 1. the free-running clock must exist, exactly once, at 5 ns
set auxclks [get_clocks -quiet -of_objects [get_ports {sysref_clk_p[0]}]]
puts "FK33_AUXCLK clocks=$auxclks"
if {[llength $auxclks] != 1} {
    error "FK33_AUXCLK FAIL: expected exactly one clock on sysref_clk_p\[0\], got [llength $auxclks]. The aux domain would be unconstrained."
}
puts "FK33_AUXCLK period=[get_property PERIOD [lindex $auxclks 0]] ns"

# 2. it must be asynchronous to everything else.
#
# COUNTING the crossing paths is the WRONG test and gave a false failure once:
# get_timing_paths still ENUMERATES a path that an asynchronous clock group has
# excluded, it just reports it with an EMPTY slack and GROUP "(none)".  The real
# question is whether any crossing path is still ANALYSED.
#
# NOT remove_from_collection either: that is a Synopsys-style command Vivado
# does not have ("invalid command name").  Filter by name.
set others [get_clocks -quiet -filter {NAME != "sysref_clk"}]
set xbad 0
foreach pth [concat [get_timing_paths -quiet -from [lindex $auxclks 0] -to $others -max_paths 8]                     [get_timing_paths -quiet -from $others -to [lindex $auxclks 0] -max_paths 8]] {
    if {[get_property SLACK $pth] ne ""} {
        puts "FK33_AUXCLK TIMED-CROSSING [get_property STARTPOINT_CLOCK $pth] -> [get_property ENDPOINT_CLOCK $pth] slack=[get_property SLACK $pth] ep=[get_property ENDPOINT_PIN $pth]"
        incr xbad
    }
}
puts "FK33_AUXCLK analysed paths crossing the aux boundary: $xbad (must be 0)"
if {$xbad > 0} {
    error "FK33_AUXCLK FAIL: set_clock_groups did not apply; the CDC into the aux domain is being timed rather than declared asynchronous."
}

# 3. the debug hub must be on it.  This is the one that decides whether ANY of
# this is readable with the link down.
set hubpins [get_pins -quiet -hierarchical -filter {NAME =~ "*dbg_hub*" && REF_PIN_NAME == "clk"}]
set hubclks [get_clocks -quiet -of_objects $hubpins]
puts "FK33_HUBCLK pins=$hubpins clocks=$hubclks"
if {[llength $hubclks] == 0} {
    error "FK33_HUBCLK FAIL: no clock reaches the debug hub's clk pin. connect_debug_port did not apply."
}
if {[lsearch -exact [get_property NAME $hubclks] "sysref_clk"] < 0} {
    error "FK33_HUBCLK FAIL: the debug hub is clocked by \"$hubclks\", not sysref_clk. With the PCIe link down it would not answer, which is the whole point of this build."
}
puts "FK33_HUBCLK OK dbg_hub is on sysref_clk"

# 4. and nothing in the aux branch may be clocked by the PCIe user clock
foreach auxcell {fk33_aux_0 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time                  aux_therm aux_peak aux_ctl fk33_therm_0} {
    set c [get_cells -quiet bd_i/$auxcell]
    if {[llength $c] == 0} { error "FK33_AUX FAIL: bd_i/$auxcell is missing from the implemented design" }
}
puts "FK33_AUX all aux cells present in the implemented design"

# 5. the thermal guard's decision logic must be on the free-running clock.  A
# guard clocked by anything the PCIe link can stop is a guard that stops with
# it, and that is the exact failure this whole domain exists to avoid.
set tcell [get_cells -quiet bd_i/fk33_therm_0]
set tclks [get_clocks -quiet -of_objects [get_pins -quiet -of_objects $tcell -filter {REF_PIN_NAME == "aux_clk"}]]
puts "FK33_THERMCLK fk33_therm_0/aux_clk clocks=$tclks"
if {[lsearch -exact [get_property NAME $tclks] "sysref_clk"] < 0} {
    error "FK33_THERMCLK FAIL: the thermal guard's aux_clk is "$tclks", not sysref_clk."
}
puts "FK33_THERMCLK OK the thermal guard runs on the free-running oscillator"

# 6. the alarm thresholds as they exist IN THE ROUTED NETLIST, not as they were
# asked for in the block design.  This is the only check in the build that reads
# what actually reaches the device: the SYSMONE4 primitive's INIT_4x/INIT_5x
# attributes ARE the configuration registers, loaded from the bitstream at
# startup.  A BD CONFIG parameter is a request; these are the answer.
#
# Register map (UG580 / the SYSMONE4 primitive):
#   50h  user temperature upper (alarm trigger)
#   53h  OT upper -- [15:4] limit, [3:0] must be 0011 to ARM automatic shutdown
#   54h  user temperature lower (alarm reset, i.e. the hysteresis floor)
#   57h  OT lower (shutdown reset)
# External-reference transfer function, from the same source:
#   T = code * 507.5921310 / 65536 - 279.42657680
proc sysmon_degc {code} { expr {$code * 507.5921310 / 65536.0 - 279.42657680} }

# Vivado does not promise a format for an INIT attribute.  It has been seen as
# 16'hBA40, as a bare hex string, and as a binary literal; guessing wrong here
# would abort a fifty-minute build on a formatting detail rather than on
# anything about the design, so parse all three and fail loudly only if the
# value is genuinely unreadable.
proc sysmon_parse {name raw} {
    set t [string trim $raw]
    if {[regexp {^[0-9]+'[bB]([01]+)$} $t -> bits]} {
        set v 0
        foreach c [split $bits ""] { set v [expr {$v * 2 + $c}] }
        return $v
    }
    if {[regexp {^[0-9]+'[hH]([0-9a-fA-F]+)$} $t -> hx]} { scan $hx %x v ; return $v }
    if {[regexp {^0[xX]([0-9a-fA-F]+)$} $t -> hx]}       { scan $hx %x v ; return $v }
    if {[regexp {^[0-9a-fA-F]+$} $t]}                    { scan $t  %x v ; return $v }
    error "FK33_SYSMONI FAIL: cannot parse $name = "$raw""
}

set smc [get_cells -quiet -hierarchical -filter {REF_NAME =~ "SYSMONE4*"}]
if {[llength $smc] != 1} {
    error "FK33_SYSMONI FAIL: expected exactly one SYSMONE4 in the routed design, found [llength $smc]: $smc"
}
puts "FK33_SYSMONI cell=[get_property NAME $smc]"
array set smwant {INIT_50 90.0 INIT_54 75.0}
foreach r {INIT_50 INIT_53 INIT_54 INIT_57} {
    set raw [get_property $r $smc]
    if {$raw eq ""} { error "FK33_SYSMONI FAIL: $r is not readable on the SYSMONE4 primitive" }
    set code [sysmon_parse $r $raw]
    puts [format "FK33_SYSMONI %s = 0x%04X -> %.2f C" $r $code [sysmon_degc $code]]
    if {[info exists smwant($r)]} {
        set d [expr {abs([sysmon_degc $code] - $smwant($r))}]
        if {$d > 1.0} {
            error "FK33_SYSMONI FAIL: $r decodes to [format %.2f [sysmon_degc $code]] C, not $smwant($r) C. The threshold in the bitstream is NOT the one this design asked for."
        }
    }
}
# The OT arming nibble.  This is the Task-1 question answered from the artefact
# rather than from documentation: 53h[3:0] == 0011 means SYSMON will power the
# device down by itself at the OT limit.  It is REPORTED, not enforced -- what
# the nibble should be is a decision for the bench, and the fabric guard exists
# precisely because the OT shutdown is a die-destruction backstop rather than a
# thermal-management mechanism.
set c53 [sysmon_parse INIT_53 [get_property INIT_53 $smc]]
set otarm [expr {$c53 & 0xF}]
set otlim [expr {$c53 & 0xFFF0}]
puts [format "FK33_SYSMONI OT limit  = 0x%04X -> %.2f C" $otlim [sysmon_degc $otlim]]
puts [format "FK33_SYSMONI OT arming nibble 53h\[3:0\] = 0x%X (0x3 = automatic power-down ARMED)" $otarm]
if {$otarm == 3} {
    puts "FK33_SYSMONI OT automatic shutdown is ARMED in this bitstream"
} else {
    puts "FK33_SYSMONI OT automatic shutdown is NOT armed; the fabric guard is the only protection"
}

# ---- SUBSYSTEM A, on the implemented design (gen_pcieep.py) ---------------
# The deliverable of the shell-integration track: the quantities the
# out-of-context runs reported, measured with the HBM IP, the XDMA shell, the
# aux domain and the thermal guard present, after place and route.  The OOC
# ceilings to compare against, both at VCCINT 0.717 V:
#     AXI  257.33 MHz   core  230.73 MHz
#     LUT 134,534   FF 64,067   DSP 1,585   BRAM36 192.5
# (docs/debugging/2026-08-28_ar-throttle-timing-close.md and
#  docs/debugging/2026-08-28_matvec-divide-by-48-core-clock.md.)
puts "==== FK33 subsystem A (implemented design) ===="
if {[llength [get_cells -quiet bd_i/eng]] == 0} {
    error "FK33_ENGI FAIL: bd_i/eng is not in the implemented design"
}

# THE TWO CLOCKS, read off the engine's own pins rather than assumed from the
# clk_wiz request -- a clk_wiz cannot always synthesise what it was asked for.
#
# This is ALSO the check that the XDC's set_clock_groups matched something.
# The XDC addresses the two groups through these exact pins, so if either
# lookup is empty here it was empty there, and a set_clock_groups with an empty
# group is a WARNING rather than an error -- the silent no-op this guards
# against.
#
# WHAT IT DOES NOT PROVE, stated because a stronger check was WRITTEN, RUN AND
# REMOVED: it does not prove the group was APPLIED.  The stronger form is the
# one FK33_AUXCLK uses, enumerating crossing paths and demanding that none has
# a slack -- and on THIS design it does not terminate.  MEASURED 2026-08-29:
# `get_timing_paths -from <core> -to <axi> -max_paths 8` ran over 20 minutes on
# the post-phys_opt checkpoint without returning, because an asynchronous group
# does not stop the enumeration and 28 gray-pointer FIFOs plus their
# four-phase clear handshakes is an enormous one.  The aux-domain check is
# cheap for the opposite reason: that domain is a handful of single-bit
# crossings.  A check that hangs a fifty-minute build is worse than a weaker
# check that runs, so the pair is reported in clkint.rpt below for a human to
# read instead.
set ecore [get_clocks -quiet -of_objects [get_pins bd_i/eng/core_clk]]
set eaxi  [get_clocks -quiet -of_objects [get_pins bd_i/eng/hbm_aclk]]
if {[llength $ecore] != 1 || [llength $eaxi] != 1} {
    error "FK33_ENGI FAIL: expected one clock on each of eng/core_clk and eng/hbm_aclk, got [llength $ecore] and [llength $eaxi]. The XDC clock group matched nothing and the per-port CDC is being timed."
}
foreach cn [list $ecore $eaxi] {
    puts [format "FK33_ENGI clock %-30s period %.3f ns (%.2f MHz)"           [get_property NAME $cn] [get_property PERIOD $cn]           [expr {1000.0 / [get_property PERIOD $cn]}]]
}

# AREA OF THE ENGINE ALONE, so it can be compared with the OOC figure without
# the shell in it.  report_utilization -cells is the only honest way:
# subtracting a remembered shell number from a design total is how the
# 1,200-LUT error in the previous area comparison happened.
report_utilization -cells [get_cells bd_i/eng] -file fk33_pcieep_engine_util.rpt
puts "FK33_ENGI engine utilization -> fk33_pcieep_engine_util.rpt"

# NOTHING ABOVE THIS POINT EXISTS UNDER FK33_ENG=0.  Everything from the top of
# this section down to the `set wns` line below reads bd_i/eng off the
# implemented design, so under FK33_ENG=0 it is replaced (see _IMPL_TAIL_AT,
# just after this string) by a line saying the engine is absent.  The tail from
# `set wns` on is configuration-independent and is kept in both.
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts [format "FK33_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns $whs]
# -no_detailed_paths: the per-clock table is what the duty identity needs and
# the detailed paths are what make this report expensive.
report_timing_summary -no_detailed_paths -file fk33_pcieep_timing.rpt
report_clock_interaction -file fk33_pcieep_clkint.rpt
report_design_analysis -congestion -file fk33_pcieep_congestion.rpt
report_clock_utilization -file fk33_pcieep_clkutil.rpt

# ---- THE FLOORPLAN, verified on the implemented design (gen_pcieep.py) -----
# Two things have to be true and neither is visible from the source files.
#
#   1. `pb_core` EXISTS with the range fk33_pblock.xdc asked for.  Vivado's XDC
#      reader downgrades a lot to a warning, and a pblock that was silently
#      skipped looks exactly like a pblock that did not help.  GRID_RANGES is
#      read back from the design, not from the file.
#
#   2. `pblock_bd_i` is GONE.  It is the SQRL shell floorplan the probe XDC
#      inherits, it is IS_SOFT, and with the engine present it is
#      oversubscribed by half on LUTs and by 3x on DSPs.  Leaving it in is what
#      made the first engine build unroutable.  gen_pcieep.py comments it out
#      of the emitted XDC; this is the check that the comment-out worked.
set pbs [lsort [get_property NAME [get_pblocks -quiet *]]]
puts "FK33_PBLK pblocks in the implemented design: $pbs"
if {[lsearch $pbs pblock_bd_i] >= 0} {
    error "FK33_PBLK FAIL: pblock_bd_i is in the implemented design. It is a soft pblock covering SLICE_X0Y0:X218Y50 plus the right-hand columns, it cannot hold the engine, and it is what caused the global congestion level 7 that stopped the router. See docs/debugging/2026-08-29_shell-pblock.md."
}
if {[llength [get_pblocks -quiet pb_core]] != 1} {
    error "FK33_PBLK FAIL: pb_core is not in the implemented design. The engine would be free to pack into clock-region column X7, which Tandem PCIe reserves, and the floorplan this build was measured with is not in effect."
}
set pbr [get_property GRID_RANGES [get_pblocks pb_core]]
if {$pbr ne "CLOCKREGION_X0Y0:CLOCKREGION_X6Y3"} {
    error "FK33_PBLK FAIL: pb_core range is '$pbr', not CLOCKREGION_X0Y0:CLOCKREGION_X6Y3."
}
puts "FK33_PBLK pb_core $pbr"
report_utilization -pblocks [get_pblocks pb_core] -file fk33_pcieep_pblock_util.rpt
puts "FK33_PBLK pblock utilization -> fk33_pcieep_pblock_util.rpt"
report_utilization -file fk33_pcieep_util.rpt

set bit [glob -nocomplain ./$ProjectName/$ProjectName.runs/impl_1/*.bit]
if {[llength $bit] == 1} {
    puts "FK33_BITSTREAM [lindex $bit 0] ([file size [lindex $bit 0]] bytes)"
} else {
    puts "FK33_BITSTREAM MISSING"
}
puts "FK33_BUILD_DONE"
