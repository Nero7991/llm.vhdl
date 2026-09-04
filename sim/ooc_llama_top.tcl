# llama_top ALONE at the DEFAULT 9B shape.  THE INTEGRATION TOP, SYNTHESISED
# FOR THE FIRST TIME.
#
# WHY THIS FILE EXISTS.  rtl/llama_top.vhd is the wired composition -- it
# instantiates subsystem D's five sequencer units, A's matvec_int4, B's
# gdn_block with its state store and job sequencer, C's attn_block with
# attn_kv_axi, the norm and the sampler -- and its SHAPE generic already
# DEFAULTS to `mk_shape(MODEL, NCARDS)`, the real 9B target.  Benches shrink it
# with `mk_shape_scaled`; nothing was ever shrinking it for synthesis, because
# there has never BEEN a synthesis.  Before this file, `ls sim/ooc_*.tcl` had
# no row for llama_top at any shape.
#
# hw/fk33/rtl/compose4_top.vhd is NOT this.  It carries A, B, C and D at the
# 9B shape and places and routes, but its own header says "THE SUBSYSTEMS ARE
# NOT WIRED TO EACH OTHER", so it measures fit and timing for a composition
# that cannot compute anything.  llama_top is the one that is wired.
#
# B_STATE_AXI IS TRUE AND THAT IS NOT OPTIONAL AT THIS SHAPE.  MEASURED
# 2026-09-03 (docs/debugging/2026-09-03_b-mover-does-not-fit.md): with the flat
# store, Vivado's own RAM table names
#   gb_real.stmem_p.stmem_reg | 3072 K x 64 | 5472
# that is 24.0 MiB in ONE object, 5,472 RAMB36 against the 672 this part has.
# It does not fit by a factor of eight.  Substituting gdn_state_store takes it
# to 34 tiles and halves LUT.  So a run of this file with B_STATE_AXI=false
# would not be a measurement of llama_top, it would be a measurement of a
# design that cannot exist.
#
# WHAT THIS ESTABLISHES: whether the wired 9B composition fits, and what it
# costs.  WHAT IT DOES NOT ESTABLISH: arithmetic.  A design that fits is not a
# correct one.  The benches are the oracle for that, and they run at a scaled
# shape.
#
# MEMORY.  This is the largest synthesis in the project and its peak is
# UNKNOWN -- engine_shared OOC peaks at 23.8 GB and a full pcieep build at
# 25.0 GiB, both of which exceed the BC-250's 14 GB, so assume this does too
# until measured.  Run it ALONE, under a cgroup cap, and read memory.peak only
# if the run did not reach that cap.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
create_project -in_memory -part $part
foreach f [glob $rtldir/*.vhd] { read_vhdl -vhdl2008 $f }

# SHAPE is a record and cannot be passed from Tcl, so it is LEFT AT ITS
# DEFAULT.  That default IS the real target -- rtl/llama_top.vhd's generic
# clause reads `SHAPE : shape_t := mk_shape(MODEL, NCARDS)` -- so this run is
# at 9B precisely BECAUSE nothing is overridden here.  Do not "fix" this by
# inventing a shape generic.
synth_design -mode out_of_context -top llama_top -part $part \
             -generic B_STATE_AXI=true

create_clock -period $period -name clk [get_ports clk]

puts "=== report_utilization ==="
puts [report_utilization -return_string]

# The object-level census, because CLAUDE.md records that Vivado's inference
# log lies in BOTH directions and only the mapping report and a census are
# authoritative.  If the utilization total and this disagree, the census wins.
puts "=== RAM primitive census ==="
foreach t {RAMB36E2 RAMB18E2 URAM288 RAM32M16 RAM64M8 RAM32X1D RAM64X1D} {
  catch {puts [format "CENSUS %-10s %d" $t [llength [get_cells -hier -quiet -filter "REF_NAME == $t"]]]}
}
puts "=== Report RAM Utilization (names the objects) ==="
catch {puts [report_ram_utilization -return_string]}

set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
puts "RESULT llama_top wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "OOC_LLAMA_TOP_DONE"
