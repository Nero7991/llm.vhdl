# Netlist census of region_mem's region 0 (R_X) in build 17's routed DCP and build 14's routed DCP: what became of
# `bank` and `shadow`, and what drives the shadow BRAM's write/address pins. Sentinels ^CENSUS_.
proc census {tag dcp} {
  open_checkpoint $dcp
  puts "CENSUS_OPENED $tag"
  set rm [get_cells -hier -filter {NAME =~ *u_regmem}]
  puts "CENSUS_REGMEM $tag [llength $rm] cells named u_regmem: $rm"
  foreach pat {*u_regmem/g_region[0].bank_reg* *u_regmem/g_region[0].g_shadow* *u_regmem/g_region[0]* *u_regmem/sh_* } {
    set cs [get_cells -hier -filter "NAME =~ $pat"]
    set kinds [dict create]
    foreach c $cs { set r [get_property REF_NAME $c]; dict incr kinds $r }
    puts "CENSUS_CELLS $tag $pat n=[llength $cs] kinds=[dict get $kinds]"
  }
  foreach c [get_cells -hier -filter {NAME =~ *u_regmem/g_region[0].g_shadow* && REF_NAME =~ RAMB*}] {
    puts "CENSUS_BRAM $tag $c"
    foreach p {WEA WEBWE ADDRARDADDR ADDRBWRADDR ENARDEN ENBWREN CLKARDCLK CLKBWRCLK} {
      foreach pin [get_pins -of $c -filter "REF_PIN_NAME =~ ${p}*"] {
        set n [get_nets -of $pin -quiet]; if {$n eq ""} { continue }
        set d [get_pins -leaf -of $n -filter {DIRECTION == OUT} -quiet]
        puts "CENSUS_PIN $tag [get_property REF_PIN_NAME $pin] net=$n driver=$d"
      }
    }
  }
  # the bank of region 0: what drives its write enables (first few), and the engine read port el_word_r
  set bk [get_cells -hier -filter {NAME =~ *u_regmem/g_region[0].bank_reg*}]
  puts "CENSUS_BANK0 $tag n=[llength $bk] first=[lrange $bk 0 3]"
  foreach c [lrange $bk 0 1] {
    foreach pin [get_pins -of $c -filter {REF_PIN_NAME =~ WE* || REF_PIN_NAME =~ CE* || REF_PIN_NAME =~ WCLK* || REF_PIN_NAME =~ ENARDEN || REF_PIN_NAME =~ WEA*}] {
      set n [get_nets -of $pin -quiet]; if {$n eq ""} { continue }
      puts "CENSUS_BANKPIN $tag $c [get_property REF_PIN_NAME $pin] net=$n"
    }
  }
  report_utilization -hierarchical -hierarchical_depth 8 -cells [get_cells -hier -filter {NAME =~ *u_regmem}] -file /mnt/storage/fk33_builds/build17/census/util_regmem_$tag.rpt
  close_design
  puts "CENSUS_DONE $tag"
}
census b17 /mnt/storage/fk33_builds/KEEP_build17_dcp/bd_wrapper_routed.dcp
census b14 /mnt/storage/fk33_builds/KEEP_build14_dcp/bd_wrapper_routed.dcp
puts "CENSUS_ALL_DONE"
