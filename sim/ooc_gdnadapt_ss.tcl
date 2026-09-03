# OOC synthesis of subsystem B's data mover WITH gdn_state_store substituted
# for the 24 MiB all-layers state array.  Generated top:
#   python3 sim/ooc_gdnadapt_extract.py --state-store rtl/llama_top.vhd \
#           rtl/ooc_gdnadapt_ss_top.vhd ooc_gdnadapt_ss
#
# WHAT THIS ANSWERS: whether B's mover fits once the recurrent state is tiered
# to one resident layer.  The unsubstituted control is sim/ooc_gdnadapt.tcl,
# which measures 5472 RAMB36 against 672 on the part -- one array,
# `gb_real.stmem_p.stmem_reg`, named by Vivado's own RAM inference table.
# docs/debugging/2026-09-03_b-mover-does-not-fit.md.
#
# WHAT IT DOES NOT ANSWER: whether B computes a correct token, and whether the
# store's load/save sequencing is right.  `rtl/gdn_job_seq.vhd` exists and is
# verified standalone; nothing drives the store from it here.  llama_top:4316
# still refuses B_SRC_REAL past token 0.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
create_project -in_memory -part $part
foreach f [glob $rtldir/*.vhd] { read_vhdl -vhdl2008 $f }
set mr [expr {[info exists ::env(GDNADAPT_MAXROWS)] ? $::env(GDNADAPT_MAXROWS) : 0}]
puts "=== A_MAXROWS override = $mr (0 = region_max(SHAPE), 12288 at 9B) ==="
synth_design -mode out_of_context -top ooc_gdnadapt_ss -part $part -generic MAXROWS_OVR=$mr
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization (the budget numbers) ==="
puts [report_utilization -return_string]
# The object-level attribution.  CLAUDE.md: the log lies in both directions and
# only the mapping report and a census are authoritative, so print the census
# rather than reasoning from the totals -- that is the exact mistake the
# unsubstituted run's write-up records.
puts "=== BRAM census by cell ==="
foreach c [get_cells -hier -filter {REF_NAME =~ RAMB*}] {
  puts "RAMB $c [get_property REF_NAME [get_cells $c]]"
}
puts "=== URAM census by cell ==="
foreach c [get_cells -hier -filter {REF_NAME =~ URAM*}] {
  puts "URAM $c [get_property REF_NAME [get_cells $c]]"
}
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "RESULT ooc_gdnadapt_ss maxrows=$mr wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "SENTINEL_OOC_GDNADAPT_SS_DONE"
