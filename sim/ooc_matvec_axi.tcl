# OOC synthesis + timing for subsystem A at the spec 14.4 AXU3EG configuration.
#
#   ROWS_IF=4, NPORTS_W=4, AXI_DW=128, MAXCOLS/MAXROWS_BFP=17408, 200 MHz
#
# 14.4 predicts 136 of 360 DSP (128 multiply + 8 scale), ~43 BRAM36 and ~6-7K
# LUT.  This is the measurement that either confirms those or does not.
#
# Out of context, so the AXI masters and the activation write port become
# top-level ports with no board pinout; that is the point, since the same core
# is meant to sit behind DDR4 here and HBM on the FK33.
# Cap parallelism: the first run forked four ~2.3 GB synthesis helpers on top
# of a 5.6 GB parent and left the box at 365 MB free.  That was a symptom of the
# memories not inferring BRAM, now fixed, but the cap costs nothing.
set_param general.maxThreads 4
set part xczu3eg-sfvc784-1-e
# resolve rtl/ from the SCRIPT location, not the cwd: this runs from sim/ooc_mv
set rtldir [file normalize [file join [file dirname [info script]] ../rtl]]

set files [list \
  util_pkg.vhd mv4i_arith_pkg.vhd \
  stream_fifo.vhd axi_rd_port.vhd weight_streamer.vhd \
  act_mem_striped.vhd matvec_core.vhd matvec_int4.vhd matvec_int4_axi.vhd ]
foreach f $files { read_vhdl -vhdl2008 [file join $rtldir $f] }

synth_design -mode out_of_context -top matvec_int4_axi -part $part \
  -generic BLK=32 -generic ROWS_IF=4 -generic NPORTS_W=4 \
  -generic AXI_DW=128 -generic ADDR_W=32 \
  -generic MAXCOLS=17408 -generic MAXROWS_BFP=17408 \
  -generic FIFO_DEPTH=512 -generic MAXB=256

# 14.4 pins 200 MHz.  A negative WNS here means the real minimum period is
# 5 - WNS, so the number is directly readable as achievable Fmax.
create_clock -name clk -period 5.000 [get_ports s_axi_aclk]

report_utilization -file util_matvec_axi.rpt
report_utilization -hierarchical -hierarchical_depth 3 \
  -file util_matvec_axi_hier.rpt
report_timing_summary -delay_type max -max_paths 5 -file timing_matvec_axi.rpt

puts "==== matvec_int4 OOC utilization (14.4 config) ===="
report_utilization
puts "==== WNS / critical path ===="
report_timing -delay_type max -max_paths 1
# Post-synthesis FUNCSIM netlist.  The RTL is verified against the C reference,
# but the NETLIST is only argued-equivalent to the RTL -- and this project has a
# v1.0 history of silicon-only failures, plus four synthesis-driven rewrites in
# this subsystem alone.  sim/tb_matvec_int4_net.vhd runs the same end-to-end
# vectors against this.
write_checkpoint -force mv_axi_synth.dcp
write_vhdl -force -mode funcsim mv_axi_net.vhd
puts "OOC_MATVEC_DONE"
