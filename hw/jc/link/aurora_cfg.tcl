# hw/jc/link/aurora_cfg.tcl -- the lane table and the Aurora 64B66B configuration
# (spec 2026-11-04 section 1b.2; plan Task 5). Sourced by gen_aurora_ip.tcl and by the card
# build's BD script (gen_jc_card.py emits a `source` of this file).
#
# Lane table: lane -> {site txpol rxpol}. Lane 0 is MEASURED (IBERT, die 0 X0Y0 TX -> die 1
# X0Y0 RX, polarity 0/0 after the AC caps were fitted). Lanes 1-3 are for the NLANES 4
# simulation only: their caps are not fitted (spec "Open") and their polarities are unmeasured.
# txpol is XORed with LINK_CTRL bit 2 at runtime; rxpol is an expectation (plan D5).
set JC_LANES {
  0 {GTYE4_CHANNEL_X0Y0 0 0}
  1 {GTYE4_CHANNEL_X0Y1 0 0}
  2 {GTYE4_CHANNEL_X0Y2 0 0}
  3 {GTYE4_CHANNEL_X0Y3 0 0}
}

# jc_aurora_config nlanes rate mode -> list of CONFIG.* name/value pairs.
# rate: 10.3125 (first build) or 1.25 (fallback). mode: card | sim (sim shortens the IP's
# internal timers through C_EXAMPLE_SIMULATION).
proc jc_aurora_config {nlanes rate mode} {
  global JC_LANES
  if {$nlanes < 1 || $nlanes > 4} { error "AURORA_CFG_FAIL nlanes $nlanes" }
  if {$rate ne "10.3125" && $rate ne "1.25"} { error "AURORA_CFG_FAIL rate $rate" }
  set first [lindex [dict get $JC_LANES 0] 0]
  if {![regexp {X(\d+)Y(\d+)$} $first -> x0 y0]} { error "AURORA_CFG_FAIL site $first" }
  # init_clk is jc_gtg_clk's CLKOUT1 (1250 MHz VCO / INIT_DIV): the IP bounds C_INIT_CLK by
  # line_rate/64 (MEASURED 2026-11-10, IP_Flow 19-3488: (3.125,161.13) at 10.3125, (3.125,19.53)
  # at 1.25), so the 200 MHz sclk cannot be init_clk. INIT_DIV 10 -> 125 MHz, 80 -> 15.625 MHz.
  set initclk [jc_init_clk_mhz $rate]
  # drp_mode is not set here. The packaged IP (gen_aurora_ip.tcl, Task 5's xsim core) keeps
  # AXI4_LITE, its default there: Disabled was refused (MEASURED 2026-11-10, IP_Flow 19-3461:
  # valid values AXI4_LITE, Native), and its idle s_axi_* slave is tied per aurora_ties.py. The
  # card's BD cell defaults to Disabled (MEASURED 2026-11-11, aurprobe: no s_axi_* pins; Task 7
  # ruling): gen_jc_card.py reads drp_mode back and emits the DRP ties only if it is not Disabled.
  # C_UCOLUMN_USED first: the IP defaults to the right (X1) column and refuses Quad_X0Y0/X0Y0 until
  # it is left. 156.25, not 156.250: the IP matches the refclk frequency as a string.
  set cfg [list \
    CONFIG.C_UCOLUMN_USED       {left} \
    CONFIG.dataflow_config      {TX/RX_Simplex} \
    CONFIG.interface_mode       {Framing} \
    CONFIG.crc_mode             {false} \
    CONFIG.flow_mode            {None} \
    CONFIG.C_AURORA_LANES       $nlanes \
    CONFIG.C_LINE_RATE          $rate \
    CONFIG.C_REFCLK_FREQUENCY   {156.25} \
    CONFIG.C_INIT_CLK           $initclk \
    CONFIG.SupportLevel         {1} \
    CONFIG.TransceiverControl   {true} \
    CONFIG.RX_EQ_MODE           {AUTO} \
    CONFIG.INS_LOSS_NYQ         {20} \
    CONFIG.C_START_QUAD         "Quad_X${x0}Y[expr {$y0 / 4}]" \
    CONFIG.C_START_LANE         "X${x0}Y${y0}" \
    CONFIG.C_EXAMPLE_SIMULATION [expr {$mode eq "sim" ? "true" : "false"}]]
  # C_GT_LOC_<row+1> = <lane+1> for each lane's site row; every other row stays X (the IP default)
  for {set l 0} {$l < $nlanes} {incr l} {
    set s [lindex [dict get $JC_LANES $l] 0]
    regexp {Y(\d+)$} $s -> y
    lappend cfg CONFIG.C_GT_LOC_[expr {$y + 1}] [expr {$l + 1}]
  }
  return $cfg
}

# jc_lane_txpol nlanes -> bit string, lane nlanes-1 first (MSB), for the gt_txpolarity XOR
proc jc_lane_txpol {nlanes} {
  global JC_LANES
  set s ""
  for {set l [expr {$nlanes - 1}]} {$l >= 0} {incr l -1} { append s [lindex [dict get $JC_LANES $l] 1] }
  return $s
}

# jc_init_div rate -> the jc_gtg_clk INIT_DIV generic for that line rate; jc_init_clk_mhz rate ->
# the matching C_INIT_CLK (1250 / INIT_DIV). Shared so the card's generic and the IP cannot differ.
proc jc_init_div {rate} {
  if {$rate eq "10.3125"} { return 10 }
  if {$rate eq "1.25"} { return 80 }
  error "AURORA_CFG_FAIL init_div: rate $rate"
}
proc jc_init_clk_mhz {rate} { return [format %.3f [expr {1250.0 / [jc_init_div $rate]}]] }

# The nominal refclk: MGTREFCLK0 of lane 0's own quad. The IP offers only the start quad's two
# refclks (MEASURED 2026-11-10: MGTREFCLK1_of_Quad_X0Y2 refused, IP_Flow 19-3461, valid values
# MGTREFCLK0_of_Quad_X0Y0, MGTREFCLK1_of_Quad_X0Y0), and list_property_value returns {} for this
# IP, so the pick is fixed rather than searched. The pin refclk is never used: the gtg ECO
# (eco_aurora_gtg.tcl) sets the POWERED QPLL's QPLL<q>REFCLKSEL to 111 (GTGREFCLK<q>; the card's
# core runs QPLL1, Task 5 ruling), the method IBERT G measured on 2026-11-04. A `pin` card is
# refused by gen_jc_card.py and build_card.tcl (final ruling 2026-11-11). These package pins are UNDRIVEN on the Jungle Cat board (the board refclk is AC36,
# MGTREFCLK1 of bank 126); they only give the IP's IBUFDS_GTE4 a legal site.
# JC_REFCLK_PINS: {P N} = MGTREFCLK0P_124/MGTREFCLK0N_124, MEASURED from the device package data
# (get_package_pins, xcvu35p-fsvh2104, 2026-11-10; README). eco_check.tcl re-reads PIN_FUNC and
# refuses on a mismatch.
set JC_REFCLK_PINS {AK38 AK39}
proc jc_refclk_choice {} {
  global JC_LANES
  set first [lindex [dict get $JC_LANES 0] 0]
  if {![regexp {X(\d+)Y(\d+)$} $first -> x0 y0]} { error "AURORA_CFG_FAIL site $first" }
  return "MGTREFCLK0_of_Quad_X${x0}Y[expr {$y0 / 4}]"
}

# jc_aurora_refclk obj -> sets C_REFCLK_SOURCE to the fixed pick on obj (an IP or a BD cell),
# reads it back, errors AURORA_CFG_FAIL on a refusal or a mismatch, returns the pick. Call it
# AFTER the jc_aurora_config dict is applied: the choice list depends on C_UCOLUMN_USED and
# C_START_QUAD, and a default (right-column) core refuses an X0 refclk.
proc jc_aurora_refclk {obj} {
  set want [jc_refclk_choice]
  if {[catch {set_property CONFIG.C_REFCLK_SOURCE $want $obj} msg]} {
    error "AURORA_CFG_FAIL refclk: $want refused: $msg"
  }
  set got [get_property CONFIG.C_REFCLK_SOURCE $obj]
  puts "AURORA_REFCLK want=$want got=$got"
  if {$got ne $want} { error "AURORA_CFG_FAIL refclk: asked $want, reads back $got" }
  return $got
}

# jc_aurora_check obj cfg: every CONFIG the object was given reads back (numbers compared
# as numbers: the IP may print 200.0 as 200.0000). Errors AURORA_CFG_FAIL readback.
proc jc_aurora_check {obj cfg} {
  set bad {}
  foreach {k v} $cfg {
    set got [get_property $k $obj]
    if {$got ne $v && !([string is double -strict $got] && [string is double -strict $v] && $got == $v)} {
      lappend bad "$k=$got (asked $v)"
    }
    puts "AURORA_CFG $k=$got"
  }
  if {[llength $bad]} { error "AURORA_CFG_FAIL readback: $bad" }
}
