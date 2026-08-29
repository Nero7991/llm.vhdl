# TRACK PBLOCK -- the decisive ablation: delete the INHERITED soft pblock
# pblock_bd_i (fk33_pcieep.xdc:133-140) and change NOTHING else.  Same placer
# directive as TRACK SHELL's own build (ExtraPostPlacementOpt), no pb_core.
set OPT "/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/eng_full/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper_opt.dcp"
set OUT "/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pblock/out"
set CORE "bd_i/eng/inst/eng/dut/core"
set_param general.maxThreads 6
proc stamp {m} { puts "PBLOCK-STAMP [clock format [clock seconds] -format %H:%M:%S] $m" ; flush stdout }

stamp "=== BEGIN DX ==="
open_checkpoint $OPT
stamp "DX opened"
puts "PBLOCK-PROOF DX pblocks_before=[get_pblocks -quiet *]"
catch {puts "PBLOCK-PROOF DX IS_SOFT=[get_property IS_SOFT [get_pblocks pblock_bd_i]]"}
catch {puts "PBLOCK-PROOF DX GRID=[get_property GRID_RANGES [get_pblocks pblock_bd_i]]"}
catch {puts "PBLOCK-PROOF DX cells=[llength [get_cells -quiet -of_objects [get_pblocks pblock_bd_i]]]"}
delete_pblocks [get_pblocks pblock_bd_i]
create_pblock pb_core
add_cells_to_pblock [get_pblocks pb_core] [get_cells $CORE]
resize_pblock [get_pblocks pb_core] -add {CLOCKREGION_X0Y0:CLOCKREGION_X6Y3}
puts "PBLOCK-PROOF DX GRID_RANGES=[get_property GRID_RANGES [get_pblocks pb_core]]"
puts "PBLOCK-PROOF DX DERIVED=[get_property DERIVED_RANGES [get_pblocks pb_core]]"
report_utilization -pblocks [get_pblocks pb_core] -file $OUT/DX_pblock_util_preplace.rpt
puts "PBLOCK-PROOF DX pblocks_after=[get_pblocks -quiet *]"
flush stdout

stamp "DX place_design start"
place_design -directive ExtraPostPlacementOpt
stamp "DX place_design done"
catch {report_design_analysis -congestion -file $OUT/DX_congestion.rpt}
catch {report_timing_summary -no_detailed_paths -file $OUT/DX_timing_placed.rpt}
catch {report_utilization -file $OUT/DX_util.rpt}

# clock-region row histogram of the core, SLICE only (divisor 60, MEASURED)
catch {
  set leaves [get_cells -quiet ${CORE}/*]
  set locs [get_property LOC $leaves]
  array set h {}
  set n 0
  foreach l $locs {
    if {[regexp {^SLICE_X[0-9]+Y([0-9]+)$} $l -> y]} {
      incr n
      set r [expr {$y/60}]
      if {[info exists h($r)]} { incr h($r) } else { set h($r) 1 }
    }
  }
  puts "PBLOCK-HIST DX slice_leaves=$n"
  for {set r 3} {$r >= 0} {incr r -1} {
    set v 0 ; if {[info exists h($r)]} { set v $h($r) }
    puts [format "PBLOCK-HIST DX Yrow%d %8d %6.2f%%" $r $v [expr {$n ? 100.0*$v/$n : 0}]]
  }
}
flush stdout
catch {write_checkpoint -force $OUT/DX_placed.dcp}
stamp "ALL DONE"
