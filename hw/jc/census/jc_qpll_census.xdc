# hw/jc/census/jc_qpll_census.xdc -- for jc_qpll_census.vhd (2026-11-03).
# Refclk pins: MEASURED by a Vivado package query (brief, docs/boards/jungle-cat/README.md
# section 9).  refclk index i = 2*q + r; q 0..7 = bank 124+q, q 8..15 = bank 224+(q-8);
# r = MGTREFCLK r.  Bank 124+q is GTYE4_COMMON_X0Y(q), bank 224+q is X1Y(q).
# The XDC reader has no loops or ifs, so everything is written out.
set_property PACKAGE_PIN AK38 [get_ports {refclk_p[0]}]
set_property PACKAGE_PIN AH38 [get_ports {refclk_p[1]}]
set_property PACKAGE_PIN AF38 [get_ports {refclk_p[2]}]
set_property PACKAGE_PIN AE36 [get_ports {refclk_p[3]}]
set_property PACKAGE_PIN AD38 [get_ports {refclk_p[4]}]
set_property PACKAGE_PIN AC36 [get_ports {refclk_p[5]}]
set_property PACKAGE_PIN AB38 [get_ports {refclk_p[6]}]
set_property PACKAGE_PIN AA36 [get_ports {refclk_p[7]}]
set_property PACKAGE_PIN Y38 [get_ports {refclk_p[8]}]
set_property PACKAGE_PIN V38 [get_ports {refclk_p[9]}]
set_property PACKAGE_PIN U36 [get_ports {refclk_p[10]}]
set_property PACKAGE_PIN T38 [get_ports {refclk_p[11]}]
set_property PACKAGE_PIN R36 [get_ports {refclk_p[12]}]
set_property PACKAGE_PIN P38 [get_ports {refclk_p[13]}]
set_property PACKAGE_PIN N36 [get_ports {refclk_p[14]}]
set_property PACKAGE_PIN M38 [get_ports {refclk_p[15]}]
set_property PACKAGE_PIN AK9 [get_ports {refclk_p[16]}]
set_property PACKAGE_PIN AH9 [get_ports {refclk_p[17]}]
set_property PACKAGE_PIN AF9 [get_ports {refclk_p[18]}]
set_property PACKAGE_PIN AE11 [get_ports {refclk_p[19]}]
set_property PACKAGE_PIN AD9 [get_ports {refclk_p[20]}]
set_property PACKAGE_PIN AC11 [get_ports {refclk_p[21]}]
set_property PACKAGE_PIN AB9 [get_ports {refclk_p[22]}]
set_property PACKAGE_PIN AA11 [get_ports {refclk_p[23]}]
set_property PACKAGE_PIN Y9 [get_ports {refclk_p[24]}]
set_property PACKAGE_PIN V9 [get_ports {refclk_p[25]}]
set_property PACKAGE_PIN U11 [get_ports {refclk_p[26]}]
set_property PACKAGE_PIN T9 [get_ports {refclk_p[27]}]
set_property PACKAGE_PIN R11 [get_ports {refclk_p[28]}]
set_property PACKAGE_PIN P9 [get_ports {refclk_p[29]}]
set_property PACKAGE_PIN N11 [get_ports {refclk_p[30]}]
set_property PACKAGE_PIN M9 [get_ports {refclk_p[31]}]
set_property LOC GTYE4_COMMON_X0Y0 [get_cells {gen_q[0].u_com}]   ;# bank 124
set_property LOC GTYE4_COMMON_X0Y1 [get_cells {gen_q[1].u_com}]   ;# bank 125
set_property LOC GTYE4_COMMON_X0Y2 [get_cells {gen_q[2].u_com}]   ;# bank 126
set_property LOC GTYE4_COMMON_X0Y3 [get_cells {gen_q[3].u_com}]   ;# bank 127
set_property LOC GTYE4_COMMON_X0Y4 [get_cells {gen_q[4].u_com}]   ;# bank 128
set_property LOC GTYE4_COMMON_X0Y5 [get_cells {gen_q[5].u_com}]   ;# bank 129
set_property LOC GTYE4_COMMON_X0Y6 [get_cells {gen_q[6].u_com}]   ;# bank 130
set_property LOC GTYE4_COMMON_X0Y7 [get_cells {gen_q[7].u_com}]   ;# bank 131
set_property LOC GTYE4_COMMON_X1Y0 [get_cells {gen_q[8].u_com}]   ;# bank 224
set_property LOC GTYE4_COMMON_X1Y1 [get_cells {gen_q[9].u_com}]   ;# bank 225
set_property LOC GTYE4_COMMON_X1Y2 [get_cells {gen_q[10].u_com}]   ;# bank 226
set_property LOC GTYE4_COMMON_X1Y3 [get_cells {gen_q[11].u_com}]   ;# bank 227
set_property LOC GTYE4_COMMON_X1Y4 [get_cells {gen_q[12].u_com}]   ;# bank 228
set_property LOC GTYE4_COMMON_X1Y5 [get_cells {gen_q[13].u_com}]   ;# bank 229
set_property LOC GTYE4_COMMON_X1Y6 [get_cells {gen_q[14].u_com}]   ;# bank 230
set_property LOC GTYE4_COMMON_X1Y7 [get_cells {gen_q[15].u_com}]   ;# bank 231

set_property PACKAGE_PIN BC26 [get_ports sysclk_clk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_clk_p]
set_property DQS_BIAS TRUE [get_ports sysclk_clk_p]

set_property PACKAGE_PIN G9  [get_ports fan_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports fan_ctl]
set_property PACKAGE_PIN D13 [get_ports err_vccint]
set_property IOSTANDARD LVCMOS18 [get_ports err_vccint]
set_property PULLUP TRUE [get_ports err_vccint]
set_property PACKAGE_PIN K10 [get_ports LED_A]
set_property PACKAGE_PIN K9  [get_ports LED_B]
set_property PACKAGE_PIN J9  [get_ports LED_C]
set_property PACKAGE_PIN J10 [get_ports LED_D]
set_property IOSTANDARD LVCMOS18 [get_ports {LED_A LED_B LED_C LED_D}]

# Frequencies are what this bitstream measures, so the refclk periods are
# generous bounds (as jc_census), not claims.  Every domain is asynchronous.
create_clock -name ref0 -period 3.100 [get_ports {refclk_p[0]}]
create_clock -name ref1 -period 3.100 [get_ports {refclk_p[1]}]
create_clock -name ref2 -period 3.100 [get_ports {refclk_p[2]}]
create_clock -name ref3 -period 3.100 [get_ports {refclk_p[3]}]
create_clock -name ref4 -period 3.100 [get_ports {refclk_p[4]}]
create_clock -name ref5 -period 3.100 [get_ports {refclk_p[5]}]
create_clock -name ref6 -period 3.100 [get_ports {refclk_p[6]}]
create_clock -name ref7 -period 3.100 [get_ports {refclk_p[7]}]
create_clock -name ref8 -period 3.100 [get_ports {refclk_p[8]}]
create_clock -name ref9 -period 3.100 [get_ports {refclk_p[9]}]
create_clock -name ref10 -period 3.100 [get_ports {refclk_p[10]}]
create_clock -name ref11 -period 3.100 [get_ports {refclk_p[11]}]
create_clock -name ref12 -period 3.100 [get_ports {refclk_p[12]}]
create_clock -name ref13 -period 3.100 [get_ports {refclk_p[13]}]
create_clock -name ref14 -period 3.100 [get_ports {refclk_p[14]}]
create_clock -name ref15 -period 3.100 [get_ports {refclk_p[15]}]
create_clock -name ref16 -period 3.100 [get_ports {refclk_p[16]}]
create_clock -name ref17 -period 3.100 [get_ports {refclk_p[17]}]
create_clock -name ref18 -period 3.100 [get_ports {refclk_p[18]}]
create_clock -name ref19 -period 3.100 [get_ports {refclk_p[19]}]
create_clock -name ref20 -period 3.100 [get_ports {refclk_p[20]}]
create_clock -name ref21 -period 3.100 [get_ports {refclk_p[21]}]
create_clock -name ref22 -period 3.100 [get_ports {refclk_p[22]}]
create_clock -name ref23 -period 3.100 [get_ports {refclk_p[23]}]
create_clock -name ref24 -period 3.100 [get_ports {refclk_p[24]}]
create_clock -name ref25 -period 3.100 [get_ports {refclk_p[25]}]
create_clock -name ref26 -period 3.100 [get_ports {refclk_p[26]}]
create_clock -name ref27 -period 3.100 [get_ports {refclk_p[27]}]
create_clock -name ref28 -period 3.100 [get_ports {refclk_p[28]}]
create_clock -name ref29 -period 3.100 [get_ports {refclk_p[29]}]
create_clock -name ref30 -period 3.100 [get_ports {refclk_p[30]}]
create_clock -name ref31 -period 3.100 [get_ports {refclk_p[31]}]
# sys0 is the real 200 MHz period: GTYE4_COMMON DRPCLK has a 4.000 ns min period, so
# the 2.5 ns bound jc_census used fails a pulse-width check here.
create_clock -name sys0 -period 5.000 [get_ports sysclk_clk_p]
create_clock -name cfgm -period 15.000 [get_pins u_start/CFGMCLK]
set_clock_groups -asynchronous -group ref0 -group ref1 -group ref2 -group ref3 -group ref4 -group ref5 -group ref6 -group ref7 -group ref8 -group ref9 -group ref10 -group ref11 -group ref12 -group ref13 -group ref14 -group ref15 -group ref16 -group ref17 -group ref18 -group ref19 -group ref20 -group ref21 -group ref22 -group ref23 -group ref24 -group ref25 -group ref26 -group ref27 -group ref28 -group ref29 -group ref30 -group ref31 -group sys0 -group cfgm
set_false_path -to [get_ports {LED_A LED_B LED_C LED_D fan_ctl}]
set_false_path -from [get_ports err_vccint]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
