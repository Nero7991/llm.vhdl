# hw/jc/link/eco_check.tcl -- run eco_aurora_gtg.tcl on a linked netlist of the card-mode core
# plus jc_gtg_clk, and check the result (plan 2026-11-04 Task 5 Step 5). Synth + link only.
# Also checks, against real netlists (coordinator ruling 4, 2026-11-10), the two GTG MMCM
# constraint patterns Task 7's render_xdc writes, and the refclk package pins of aurora_cfg.tcl:
#   phase 1: the flat OOC netlist below (instance gtgclk, as GTG_CELL in Task 7);
#   phase 2: jc_gtg_clk as a BD module-reference cell named gtgclk (the card's hierarchy).
# usage: vivado -mode batch -source hw/jc/link/eco_check.tcl -tclargs <ip_out_dir (l1card)> <work_dir>
# prints ^ECOCHK_OK, errors ^ECOCHK_FAIL (and ^ECOA_FAIL from the ECO)
lassign $argv ipout work
set here [file dirname [file normalize [info script]]]
source [file join $here aurora_cfg.tcl]
set part xcvu35p-fsvh2104-2L-e
file mkdir $work
# The two lines the plan's Task 7 render_xdc emits (plan ~6934-6936, GTG_CELL = gtgclk) match
# NOTHING in the BD: a module-reference cell puts the RTL under an `inst` level
# (bdchk_i/gtgclk/inst/u_mmcm, MEASURED 2026-11-10). They are reported (PLAN) but not relied on;
# the corrected patterns (FIXED, one `*` after gtgclk/) must match exactly one object in both
# hierarchies. Task 7 must emit the FIXED form; so must the ECO pin, which already does
# (*gtgclk/*u_gbg/O).
set XDC_PLAN_MMCM {NAME =~ *gtgclk/u_mmcm}
set XDC_PLAN_CLKIN {NAME =~ *gtgclk/u_mmcm/CLKIN1}
set XDC_MMCM {NAME =~ *gtgclk/*u_mmcm}
set XDC_CLKIN {NAME =~ *gtgclk/*u_mmcm/CLKIN1}
set ECO_GBG {NAME =~ *gtgclk/*u_gbg/O}
# xdc_paths tag: apply both constraint lines (FIXED form) and read them back
proc xdc_paths {tag} {
  puts "ECOCHK_XDC $tag PLAN mmcm_cells=[llength [get_cells -quiet -hier -filter $::XDC_PLAN_MMCM]] clkin_pins=[llength [get_pins -quiet -hier -filter $::XDC_PLAN_CLKIN]]"
  set g [get_pins -quiet -hier -filter $::ECO_GBG]
  puts "ECOCHK_XDC $tag ECO_PIN [llength $g] {$g}"
  if {[llength $g] != 1} { return 0 }
  set c [get_cells -quiet -hier -filter $::XDC_MMCM]
  set p [get_pins -quiet -hier -filter $::XDC_CLKIN]
  set all [get_cells -hier -filter {REF_NAME =~ MMCM*}]
  puts "ECOCHK_XDC $tag FIXED mmcm_cells=[llength $c] {$c} clkin_pins=[llength $p] {$p} all_mmcm={$all} refs={[get_property REF_NAME $all]}"
  if {[llength $c] != 1 || [llength $p] != 1} { return 0 }
  set_property LOC MMCM_X0Y2 $c
  set_property CLOCK_DEDICATED_ROUTE BACKBONE $p
  set n [get_nets -of_objects $p]
  # the net form IBERT G used (jc_board_g.xdc, on jc_sclk_g), applied too so both read back
  set_property CLOCK_DEDICATED_ROUTE BACKBONE $n
  puts "ECOCHK_XDC $tag LOC=[get_property LOC $c] pin_CDR=[get_property CLOCK_DEDICATED_ROUTE $p] net=$n net_CDR=[get_property CLOCK_DEDICATED_ROUTE $n] driver=[get_cells -of_objects [get_pins -leaf -of_objects $n -filter {DIRECTION == OUT}]]"
  return [expr {[get_property LOC $c] eq "MMCM_X0Y2" && [get_property CLOCK_DEDICATED_ROUTE $p] eq "BACKBONE" && [get_property CLOCK_DEDICATED_ROUTE $n] eq "BACKBONE"}]
}

set xci [lindex [glob $ipout/prj/aur.srcs/sources_1/ip/jc_aurora/jc_aurora.xci] 0]
read_ip $xci
read_vhdl -vhdl2008 [list $here/rtl/jc_gtg_clk.vhd $here/rtl/jc_aurora_wrap_l1.vhd]
set fh [open $work/eco_top.vhd w]
puts $fh {library ieee; use ieee.std_logic_1164.all;
entity eco_top is port(sys_i : in std_logic; refclk_p, refclk_n : in std_logic;
  rxp, rxn : in std_logic_vector(0 downto 0); txp, txn : out std_logic_vector(0 downto 0);
  up : out std_logic); end entity;
architecture a of eco_top is
  signal sclk, gclk, iclk, lk, uclk, tr, txu, rxu : std_logic;
  signal rd : std_logic_vector(63 downto 0);
begin
  gtgclk : entity work.jc_gtg_clk generic map(INIT_DIV => 10)
    port map(sys_i => sys_i, sclk => sclk, gtg_clk => gclk, init_clk => iclk, locked => lk);
  u_aur : entity work.jc_aurora_wrap port map(init_clk => iclk, reset_pb => '0', pma_init => not lk,
    refclk_p => refclk_p, refclk_n => refclk_n, tx_polarity => "0",
    s_tx_tdata => (others => '0'), s_tx_tkeep => (others => '1'), s_tx_tlast => '0', s_tx_tvalid => '0',
    s_tx_tready => tr, m_rx_tdata => rd, m_rx_tkeep => open, m_rx_tlast => open, m_rx_tvalid => open,
    txp => txp, txn => txn, rxp => rxp, rxn => rxn, tx_channel_up => txu, rx_channel_up => rxu,
    user_clk => uclk, tx_sys_reset => open, rx_sys_reset => open, gt_pll_lock => open);
  up <= txu and rxu and rd(0);
end architecture;}
close $fh
read_vhdl -vhdl2008 $work/eco_top.vhd
synth_design -top eco_top -part $part -mode out_of_context

# the nominal refclk pins (aurora_cfg.tcl JC_REFCLK_PINS) against the device package data
lassign $JC_REFCLK_PINS pp pn
set fp [get_property PIN_FUNC [get_package_pins $pp]]
set fn [get_property PIN_FUNC [get_package_pins $pn]]
puts "ECOCHK_PINS $pp=$fp $pn=$fn"
if {$fp ne "MGTREFCLK0P_124" || $fn ne "MGTREFCLK0N_124"} { error "ECOCHK_FAIL refclk pins: $pp=$fp $pn=$fn" }
set ib [get_cells -hier -filter {REF_NAME == IBUFDS_GTE4}]
puts "ECOCHK_IBUFDS_GTE4 [llength $ib] {$ib} I<-[get_nets -of_objects [get_pins -of_objects $ib -filter {REF_PIN_NAME == I}]]"

set ::JC_AUR_CELL u_aur/u_core
set ::JC_GTG_PIN gtgclk/u_gbg/O
source $here/eco_aurora_gtg.tcl
# Which QPLL the channels run, read from the CHANNELS (independent of the ECO's own QPLL<q>PD
# rule): TXPLLCLKSEL/RXPLLCLKSEL 11 = QPLL0, 10 = QPLL1, 00 = CPLL (UG578). Both must be
# constants and agree; that QPLL's GTGREFCLK<q> must come from the gtg BUFG and its
# QPLL<q>REFCLKSEL must be 111.
proc tie_bits {cell bus} {
  set v ""
  foreach k {1 0} {
    set t [get_property TYPE [get_nets -of_objects [get_pins "$cell/$bus\[$k\]"]]]
    if {$t eq "POWER"} { append v 1 } elseif {$t eq "GROUND"} { append v 0 } else { return "logic" }
  }
  return $v
}
set chans [get_cells -hier -filter {REF_NAME == GTYE4_CHANNEL}]
set used {}
foreach ch $chans {
  set tx [tie_bits $ch TXPLLCLKSEL]; set rx [tie_bits $ch RXPLLCLKSEL]
  puts "ECOCHK_CHAN $ch TXPLLCLKSEL=$tx RXPLLCLKSEL=$rx"
  foreach v [list $tx $rx] {
    if {$v eq "11"} { lappend used 0 } elseif {$v eq "10"} { lappend used 1 } else { error "ECOCHK_FAIL $ch PLL select $v is not a QPLL constant" }
  }
}
set used [lsort -unique $used]
if {[llength $used] != 1} { error "ECOCHK_FAIL channels use QPLLs {$used}" }
set q [lindex $used 0]
foreach c [get_cells -hier -filter {REF_NAME == GTYE4_COMMON}] {
  set d [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -of_objects [get_pins $c/GTGREFCLK$q]] -filter {DIRECTION == OUT}]]
  puts "ECOCHK $c channels on QPLL$q GTGREFCLK$q <- $d ([get_property REF_NAME $d])"
  if {[get_property REF_NAME $d] ne "BUFGCE" && [get_property REF_NAME $d] ne "BUFG"} { error "ECOCHK_FAIL $c GTGREFCLK$q not from a BUFG" }
  foreach k {0 1 2} {
    if {[get_property TYPE [get_nets -of_objects [get_pins "$c/QPLL${q}REFCLKSEL\[$k\]"]]] ne "POWER"} { error "ECOCHK_FAIL $c QPLL${q}REFCLKSEL bit $k" }
  }
}
set ok1 [xdc_paths flat]
opt_design
foreach c [get_cells -hier -filter {REF_NAME == GTYE4_COMMON}] {
  set d [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -of_objects [get_pins $c/GTGREFCLK$q]] -filter {DIRECTION == OUT}]]
  set sel {}
  foreach k {2 1 0} { lappend sel [get_property TYPE [get_nets -of_objects [get_pins "$c/QPLL${q}REFCLKSEL\[$k\]"]]] }
  puts "ECOCHK post_opt $c GTGREFCLK$q <- $d ([get_property REF_NAME $d]) sel=$sel"
}
close_design
if {[info exists ::env(JC_ECO_MUTATE)]} { error "ECOCHK_MUTANT_SURVIVED $::env(JC_ECO_MUTATE)" }

# phase 2: the BD module-reference hierarchy (Task 7 creates gtgclk with create_bd_cell -type module)
create_project -force bdp $work/bdprj -part $part
add_files -norecurse $here/rtl/jc_gtg_clk.vhd
# a BD module reference refuses a VHDL-2008 top file (MEASURED 2026-11-10, filemgmt 56-195:
# "This type is not allowed as the top file in the reference"); jc_gtg_clk is plain VHDL
set_property file_type {VHDL} [get_files jc_gtg_clk.vhd]
update_compile_order -fileset sources_1
create_bd_design bdchk
create_bd_cell -type module -reference jc_gtg_clk gtgclk
foreach p {sys_i} { create_bd_port -dir I -type clk -freq_hz 200000000 $p; connect_bd_net [get_bd_ports $p] [get_bd_pins gtgclk/$p] }
foreach p {sclk gtg_clk init_clk locked} { create_bd_port -dir O $p; connect_bd_net [get_bd_ports $p] [get_bd_pins gtgclk/$p] }
validate_bd_design
save_bd_design
set wrapper [make_wrapper -files [get_files bdchk.bd] -top]
add_files -norecurse $wrapper
set_property top bdchk_wrapper [current_fileset]
# global synthesis (no per-cell OOC dcp), so synth_design below sees the module-ref cell's sources
set_property synth_checkpoint_mode None [get_files bdchk.bd]
generate_target all [get_files bdchk.bd]
update_compile_order -fileset sources_1
synth_design -top bdchk_wrapper -part $part -mode out_of_context
set ok2 [xdc_paths bd]
puts "ECOCHK_XDC_RESULT flat=$ok1 bd=$ok2"
if {!$ok1 || !$ok2} { error "ECOCHK_FAIL xdc patterns: flat=$ok1 bd=$ok2" }
puts "ECOCHK_OK"
