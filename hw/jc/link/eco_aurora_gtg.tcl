# hw/jc/link/eco_aurora_gtg.tcl -- netlist ECO for JC_LINK_REFCLK=gtg (plan D11), run as
# STEPS.OPT_DESIGN.TCL.PRE or before opt_design in a non-project flow: after link_design.
# Shape: IBERT G's src/eco_gtg.tcl. The Aurora core has no GTGREFCLK port, so, for each
# GTYE4_COMMON under the Aurora cell and the QPLL<q> the core actually runs:
#  1. GTGREFCLK<q> from <const0> to the gtg_clk net;
#  2. QPLL<q>REFCLKSEL[2:0] to VCC (111 = GTGREFCLK<q>) when the IP drives them from constants.
#     If the IP drives them from flops or logic, refuse: that select is runtime state and an
#     ECO on it is not the power-up value.
# WHICH QPLL (MEASURED 2026-11-10, l1card at 10.3125 Gb/s): the core runs QPLL1, not QPLL0. Its GT
# wizard is TX/RX_PLL_TYPE QPLL1 (ip_0/jc_aurora_gt.xci) and ip_0/synth/jc_aurora_gt.v ties
# .qpll0pd_in(1'H1) (QPLL0 powered down), .qpll1pd_in(1'H0), .qpll1refclksel_in(3'H1). The plan's
# fixed GTGREFCLK0/QPLL0REFCLKSEL would retarget the powered-down PLL and leave QPLL1 on the
# undriven MGTREFCLK0 pins. So q is read from the netlist: the one QPLL whose QPLL<q>PD is not
# tied to VCC; anything other than exactly one refuses.
# JC_ECO_MUTATE=qpll0 (teeth check only): force q = 0, the plan's original target.
# Inputs: ::JC_AUR_CELL (hier name of the Aurora cell), ::JC_GTG_PIN (the gtg BUFG output pin).
# Prints ^ECOA_DONE, errors ^ECOA_FAIL.
set gnet [get_nets -of_objects [get_pins $::JC_GTG_PIN]]
if {$gnet eq ""} { error "ECOA_FAIL no net on $::JC_GTG_PIN" }
set commons [lsort [get_cells -hier -filter "REF_NAME == GTYE4_COMMON && NAME =~ $::JC_AUR_CELL/*"]]
if {[llength $commons] < 1} { error "ECOA_FAIL no GTYE4_COMMON under $::JC_AUR_CELL" }
puts "ECOA_DT before=[get_property DONT_TOUCH $gnet]"
set_property DONT_TOUCH false $gnet
set vcc [get_nets -hier -filter {TYPE == POWER} -quiet]
if {$vcc eq ""} {
  create_cell -reference VCC eco_aur_vcc
  create_net eco_aur_vcc_net
  connect_net -net eco_aur_vcc_net -objects [get_pins eco_aur_vcc/P]
  set vcc [get_nets eco_aur_vcc_net]
} else {
  set vcc [lindex $vcc 0]
}
foreach c $commons {
  set act {}
  foreach q {0 1} {
    set t [get_property TYPE [get_nets -of_objects [get_pins $c/QPLL${q}PD]]]
    puts "ECOA_PD $c QPLL${q}PD $t"
    if {$t ne "POWER"} { lappend act $q }
  }
  if {[llength $act] != 1} { error "ECOA_FAIL $c: [llength $act] QPLLs not powered down ($act); need exactly one" }
  set q [lindex $act 0]
  if {[info exists ::env(JC_ECO_MUTATE)] && $::env(JC_ECO_MUTATE) eq "qpll0"} { set q 0; puts "ECOA_MUTANT qpll0" }
  set p [get_pins $c/GTGREFCLK$q]
  set old [get_nets -of_objects $p]
  if {[get_property TYPE $old] ne "GROUND"} { error "ECOA_FAIL $p was on $old ([get_property TYPE $old])" }
  disconnect_net -objects $p
  connect_net -hier -net $gnet -objects $p
  puts "ECOA_CONN QPLL$q $p old=$old new=[get_nets -of_objects $p]"
  foreach k {0 1 2} {
    set sp [get_pins "$c/QPLL${q}REFCLKSEL\[$k\]"]
    set n [get_nets -of_objects $sp]
    set t [get_property TYPE $n]
    if {$t ne "GROUND" && $t ne "POWER"} {
      error "ECOA_FAIL $sp is driven by $n (TYPE $t): a runtime select; use the IP's port instead"
    }
    if {$t eq "GROUND"} {
      disconnect_net -objects $sp
      connect_net -hier -net $vcc -objects $sp
    }
    puts "ECOA_SEL $c QPLL$q b$k was $t now [get_property TYPE [get_nets -of_objects $sp]]"
  }
}
set_property DONT_TOUCH true $gnet
puts "ECOA_DONE commons=[llength $commons] loads=[llength [get_pins -leaf -of_objects $gnet -filter {DIRECTION == IN}]]"
