# Same census on build 17's SYNTHESIS checkpoint: were the bank's write enables already constant after synth_design,
# or did opt_design / power_opt do it?  Sentinels ^CENSUS_.
open_checkpoint /mnt/storage/fk33_builds/KEEP_build17_dcp/bd_wrapper_synth.dcp
puts "CENSUS_OPENED synth17"
foreach pat {*u_regmem/g_region[0].bank_reg* *u_regmem/g_region[0].g_shadow*} {
  set cs [get_cells -hier -filter "NAME =~ $pat"]; set kinds [dict create]
  foreach c $cs { dict incr kinds [get_property REF_NAME $c] }
  puts "CENSUS_CELLS synth17 $pat n=[llength $cs] kinds=[dict get $kinds]"
}
foreach c [get_cells -hier -filter {NAME =~ *u_regmem/g_region[0].bank_reg* && REF_NAME =~ RAMB*}] {
  set wes {}
  foreach pin [get_pins -of $c -filter {REF_PIN_NAME =~ WEBWE* || REF_PIN_NAME =~ WEA* || REF_PIN_NAME =~ ENBWREN || REF_PIN_NAME =~ ENARDEN}] {
    set n [get_nets -of $pin -quiet]; lappend wes "[get_property REF_PIN_NAME $pin]=[expr {$n eq "" ? "NONE" : [file tail $n]}]"
  }
  puts "CENSUS_BANKPINS synth17 [file tail $c] $wes"
}
foreach c [get_cells -hier -filter {NAME =~ *u_regmem/g_region[0].g_shadow* && REF_NAME =~ RAMB*}] {
  set wes {}
  foreach pin [get_pins -of $c -filter {REF_PIN_NAME =~ WEBWE* || REF_PIN_NAME =~ WEA* || REF_PIN_NAME =~ ENBWREN || REF_PIN_NAME =~ ENARDEN}] {
    set n [get_nets -of $pin -quiet]; lappend wes "[get_property REF_PIN_NAME $pin]=[expr {$n eq "" ? "NONE" : [file tail $n]}]"
  }
  puts "CENSUS_SHADOWPINS synth17 [file tail $c] $wes"
}
puts "CENSUS_ALL_DONE"
