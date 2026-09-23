proc r0check {tag dcp} {
set fk33_r0_dead {}
set fk33_r0_n 0
set fk33_r0_msg ""
if {[catch {
  open_checkpoint $dcp
  set fk33_r0 [get_cells -hier -quiet -filter {NAME =~ *u_regmem/g_region[0].bank_reg* && REF_NAME =~ RAMB*}]
  set fk33_r0_n [llength $fk33_r0]
  foreach c $fk33_r0 {
    set live 0
    foreach pin [get_pins -of $c -filter {REF_PIN_NAME =~ WEBWE* || REF_PIN_NAME =~ WEA*}] {
      set n [get_nets -of $pin -quiet]
      if {$n ne "" && [get_property TYPE $n] ne "GROUND" && [get_property TYPE $n] ne "POWER"} { incr live }
    }
    puts "FK33_REGION0_WE bram [file tail $c] live_write_pins=$live"
    if {$live == 0} { lappend fk33_r0_dead [file tail $c] }
  }
} fk33_r0_err]} { set fk33_r0_msg $fk33_r0_err }
catch {close_design}
if {$fk33_r0_msg ne ""} {
  puts "R0CHECK $tag RESULT: FK33_REGION0_WE NOT CHECKED, and an unchecked netlist is not implemented: $fk33_r0_msg"
}
if {$fk33_r0_n == 0} {
  puts "R0CHECK $tag RESULT: FK33_REGION0_WE skipped: no region-0 block RAM in this netlist (engine-only build?)"
} elseif {[llength $fk33_r0_dead] > 0} {
  puts "R0CHECK $tag RESULT: FK33_REGION0_WE FAIL: [llength $fk33_r0_dead] of $fk33_r0_n region-0 block RAMs have every write enable on a constant net ($fk33_r0_dead).  The engine would read a never-written R_X (builds 15/17).  Do not implement this netlist."
} else {
  puts "R0CHECK $tag RESULT: FK33_REGION0_WE OK: $fk33_r0_n region-0 block RAMs, every one with live write enables"
}

}
r0check synth17 /mnt/storage/fk33_builds/KEEP_build17_dcp/bd_wrapper_synth.dcp
r0check routed14 /mnt/storage/fk33_builds/KEEP_build14_dcp/bd_wrapper_routed.dcp
puts "R0CHECK_ALL_DONE"
