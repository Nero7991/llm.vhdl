# OOC synthesis of subsystem C's DATA MOVER, extracted from llama_top's `gcr`
# block by sim/ooc_cattnadapt_extract.py.  Same method, and the same pair of
# questions, as sim/ooc_gdnadapt.tcl did for B.
#
# WHAT THIS ANSWERS: what C's mover costs, and whether it FITS.  Nothing has
# measured either, because until now the block could not be built outside
# llama_top.  B's answer was that it did NOT fit -- one object,
# `gb_real.stmem_p.stmem_reg`, was 5,472 RAMB36 against 672 on the part.
#
# WHAT IT DOES NOT ANSWER: whether C computes a correct token, or whether the
# composition fits.  It is one generate block synthesised alone.
#
# THE CONTROL MATTERS AS MUCH AS THE RUN.  C_KV_AXI selects whether the KV
# cache lives behind an AXI master or on chip, and that is exactly the axis
# B's state store turned out to sit on.  Sweep it from the environment so both
# arms are the SAME script:
#   CATTN_KV_AXI=false  (default) on-chip KV
#   CATTN_KV_AXI=true              KV behind the AXI face
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
create_project -in_memory -part $part
foreach f [glob $rtldir/*.vhd] { read_vhdl -vhdl2008 $f }

set kv [expr {[info exists ::env(CATTN_KV_AXI)] ? $::env(CATTN_KV_AXI) : "false"}]

# C_KV_BLOCK IS NOT FREE TO STAY AT ITS DEFAULT IN THE AXI ARM, and the design
# says so itself rather than mis-synthesising.  MEASURED: C_KV_AXI=true with
# the default C_KV_BLOCK=4 is REFUSED at elaboration --
#
#   ERROR: [Synth 8-11323] assigned value '-48' out of range
#
# which is `CHK_KV_NBLK : natural := 16 - C_NBLK*8/8` going negative, the
# out-of-range-natural idiom this project uses because Vivado ignores a
# failing `assert ... severity failure` in synthesis.  C_NBLK is
# attn_head_dim / C_KV_BLOCK = 256/4 = 64 at the 9B shape, and the block
# exponents must fit a 16-byte header chunk, so C_NBLK must be <= 16 and
# therefore C_KV_BLOCK >= 16.  The refusal exists to name the CALLER; it is
# mirrored from attn_kv_axi's own :455 assert.
set blk [expr {[info exists ::env(CATTN_KV_BLOCK)] ? $::env(CATTN_KV_BLOCK) \
               : ($kv eq "true" ? 16 : 4)}]
# C_N_ROT WAS NEVER SET HERE, AND THE CARD DOES NOT BUILD THE DEFAULT.
# rtl/ooc_cattnadapt_top.vhd defaults C_N_ROT to 8 and passes it to attn_block
# as N_ROT, so every area figure this harness has ever produced for C is at
# N_ROT=8.  hw/fk33/rtl/fk33_card.vhd passes C_N_ROT => 64, pinned two-sided
# to 2*IMROPE_NPAIR by tools/check_kv_map.py, so the shipping configuration is
# EIGHT TIMES the rotation pairs that were measured.  Default stays 8 so every
# previous number reproduces; set CATTN_N_ROT=64 for the card's shape.
set rot [expr {[info exists ::env(CATTN_N_ROT)] ? $::env(CATTN_N_ROT) : 8}]
puts "=== C_KV_AXI = $kv  C_KV_BLOCK = $blk  C_N_ROT = $rot ==="
puts "CATTN_CONFIG kv=$kv blk=$blk rot=$rot"

synth_design -mode out_of_context -top ooc_cattnadapt_top -part $part \
             -generic C_KV_AXI=$kv -generic C_KV_BLOCK=$blk \
             -generic C_N_ROT=$rot

create_clock -period $period -name clk [get_ports clk]

puts "=== report_utilization ==="
puts [report_utilization -return_string]

# The object-level census.  CLAUDE.md records that Vivado's inference log lies
# in BOTH directions and that only the mapping report and a census are
# authoritative; B's 5,472 tiles were found by the RAM table NAMING the
# object, not by the utilization total.
puts "=== Report RAM Utilization (names the objects) ==="
catch {puts [report_ram_utilization -return_string]}

set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
puts "RESULT ooc_cattnadapt kv_axi=$kv kv_block=$blk wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "OOC_CATTNADAPT_DONE"
