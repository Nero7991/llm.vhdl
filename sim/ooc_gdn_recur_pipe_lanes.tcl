# OOC synth of gdn_recur_pipe across LANES -- TRACK BRECUR 2026-09-20.
#
# THE QUESTION.  `rtl/llama_top.vhd` ships `B_RECUR_LANES = 4` and
# `rtl/gdn_block.vhd` DEFAULTS the same generic to 32 ("section 3.1's
# assumption").  The shipping 4 is justified in llama_top only as "the exact
# set sim/tb_gdn_block.vhd defaults to", i.e. a BENCH default, and the sweep
# is VAL_HEADS*DIM*(DIM/LANES) cycles, so the lane count is an 8x lever on
# the largest phase of a B job.  What it costs has never been measured at any
# lane count but 32.
#
# WHY A SWEEP AND NOT A SCALING ARGUMENT.  docs/debugging/2026-08-26_gdn-
# recurrence-column-pipelining.md measured ONE point: 129 DSP and 24,037 LUT
# at LANES=32.  DSP is safe to derive -- there are exactly four per-lane
# multiply sites (gdn_recur_pipe.vhd:514,527,712,849) plus one scalar (:616),
# so 4*LANES+1, and 4*32+1 = 129 agrees with the measurement.  LUT IS NOT.
# CLAUDE.md's TRACK LEVERC48 entry is explicit that fitting a trend to two or
# three points of a resource that may simply scatter produces "a confident
# wrong one", and the per-lane LUT figure here has never been plotted at all.
# So: measure every point that the design can actually reach and quote the
# measurements, rather than extrapolate from the one point that exists.
#
# WHY 4, 8, 16, 32 AND WHY 32 IS PRINTED BUT NOT USABLE.  The card cannot
# reach LANES=32: `rtl/gdn_state_axi.vhd:212` is
#     constant WPB : positive := AXI_DW / WBITS;
# with `WBITS = RECUR_LANES*16` and `AXI_DW = 256`, so a `positive` goes to
# zero at RECUR_LANES=32 and the elaboration dies, and :232
# `bad_axi_dw_not_multiple_of_word` forces WORD_BITS to divide 256 exactly.
# The reachable set is therefore {1,2,4,8,16}.  32 is synthesized anyway
# because it is the one point with a published number, so this sweep can be
# checked against it: if this script reports anything but 129 DSP / ~24,037
# LUT at LANES=32, the harness is wrong and none of the other rows count.
# THAT ROW IS THE CONTROL, and it is the reason the sweep is trustworthy.
#
# Run from sim/:  vivado -mode batch -source ooc_gdn_recur_pipe_lanes.tcl
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
# pfRoot -- the repo root, DERIVED from this script's own location rather than
# written in as a literal, so the run works from any checkout path and survives
# the repo directory being renamed (TRACK PATHFREE, 2026-09-20).  Probed rather
# than trusted: a wrong root would otherwise read_vhdl nothing and fail much
# later as a missing entity.
set pfRoot [file normalize [file join [file dirname [info script]] ..]]
if {![file exists $pfRoot/rtl/util_pkg.vhd]} {
    error "pfRoot: derived repo root '$pfRoot' does not contain rtl/util_pkg.vhd. Source this script by its path in the tree."
}
set rtldir $pfRoot/rtl
set csv [open "gdn_recur_pipe_lanes.csv" w]
puts $csv "lanes,slots,dsp,lut,ff,bram,dsp_derived,lut_util,wns_ns,fmax_mhz"

# SLOTS.  gdn_recur_pipe:410 asserts SLOTS >= the columns in flight, which is
# SHAPE-dependent: at DIM=128 the minimum is 8/9/11 at LANES 4/8/16 and 16
# covers all of them, but at DIM=32 LANES=16 it is 22 and 16 FAILS LOUDLY.
# 16 is held constant here so the area rows differ in LANES and nothing else.
foreach cfg {{4 16} {8 16} {16 16} {32 16}} {
  lassign $cfg L S
  puts "======== gdn_recur_pipe DIM=128 LANES=$L SLOTS=$S ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir gdn_recur_pipe.vhd]
  synth_design -mode out_of_context -top gdn_recur_pipe -part $part \
               -generic DIM=128 -generic LANES=$L -generic SLOTS=$S
  create_clock -period $period -name clk [get_ports clk]
  set rpt [report_timing_summary -no_header -return_string]
  set wns 0.0
  if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
  set fmax [expr {1000.0/($period - $wns)}]

  # THE OBJECT-LEVEL CENSUS, which CLAUDE.md makes authoritative over the
  # inference log AND over the utilization total.  `REF_NAME =~ DSP*` and not
  # `PRIMITIVE_GROUP == DSP`: the latter is MEASURED to match nothing on this
  # part and to return a WARNING rather than an error, so a census built on it
  # prints zero beside a utilization report saying 194.
  # MEASURED BY THIS SCRIPT, 2026-09-20, AT LANES=4: the first draft used
  # `PRIMITIVE_GROUP == LUT` and `PRIMITIVE_GROUP == FLOP_LATCH`, copied from
  # `sim/ooc_gdn_recur_pipe_dbuf.tcl:31-32`, and BOTH MATCHED NOTHING -- the
  # row read `lut=0 ff=0` next to a utilization report saying 9,427 LUTs, with
  # only a `WARNING: [Vivado 12-180]` and a successful exit.  That is exactly
  # the silent-empty-filter shape CLAUDE.md records for `PRIMITIVE_GROUP ==
  # DSP`, and `sim/ooc_gdn_recur_pipe_dbuf.tcl` STILL CARRIES IT, so any LUT
  # or FF figure that script has ever printed is zero and was never read.
  # The only reason it was caught here is the `lut_util` cross-check column
  # below, which exists because CLAUDE.md says to put the census next to the
  # utilization row rather than instead of it.
  set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
  set nlut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
  set nff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
  set nbr  [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] \
                + 0.5*[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]

  # And the utilization report's own LUT row, printed NEXT TO the census
  # rather than instead of it.  When the two disagree the census wins, but a
  # silent disagreement is what this column exists to make loud.
  set urpt [report_utilization -return_string]
  set ulut 0
  if {[regexp {CLB LUTs[^|]*\|\s*(\d+)} $urpt -> u]} { set ulut $u }

  set dsp_derived [expr {4*$L + 1}]
  puts "RESULT L=$L dsp=$ndsp (derived $dsp_derived) lut=$nlut (util $ulut) \
ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  if {$ndsp != $dsp_derived} {
    puts "WARN_DSP L=$L census $ndsp against derived 4*LANES+1 = $dsp_derived"
  }
  puts $csv "$L,$S,$ndsp,$nlut,$nff,$nbr,$dsp_derived,$ulut,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "BRECUR_LANES_DONE"
