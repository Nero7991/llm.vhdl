-- Jungle Cat USER3 control core: the BSCANE2 (USER3) primitive and the TCK clock buffer.
-- Synthesis only: GHDL cannot simulate the primitive, so sim/tb_jc_ctl_core.vhd drives
-- rtl/jc_ctl_core.vhd's tck/sel/capture/shift/tdi directly.
--
-- The shape of hw/jc/loader/rtl/jc_frame_rx.vhd (which stays untouched), with
-- JTAG_CHAIN => 3: USER3, IR 100010100100 (0x8A4) on the VU35P (BSDL xcvu35p_fsvh2104.bsd).
-- It exposes the primitive's TCK (through a BUFG), SEL, CAPTURE, SHIFT and TDI and takes
-- TDO, and nothing else; the receiver lives once, inside jc_ctl_core (jc_ctl_frame_core).
-- hw/jc/card/gen_jc_card.py instantiates this entity in jc_card_top.vhd (its CTL_JTAG table
-- maps tck_o/sel_o/capture_o/shift_o/tdi_o/tdo_i to the BD's ctl_* ports). The card build
-- must find exactly one chain-3 BSCANE2 and one chain-4 BSCANE2 (the loader), and no debug
-- hub on either chain.
library ieee;
use ieee.std_logic_1164.all;
library unisim;
use unisim.vcomponents.all;

entity jc_ctl_rx is
  port(
    tck_o     : out std_logic;
    sel_o     : out std_logic;
    capture_o : out std_logic;
    shift_o   : out std_logic;
    tdi_o     : out std_logic;
    tdo_i     : in  std_logic
  );
end entity;

architecture rtl of jc_ctl_rx is
  signal tck_raw : std_logic;
begin
  u_jc_ctl_bscan : BSCANE2
    generic map(JTAG_CHAIN => 3)
    port map(CAPTURE => capture_o, DRCK => open, RESET => open, RUNTEST => open,
             SEL => sel_o, SHIFT => shift_o, TCK => tck_raw, TDI => tdi_o, TMS => open,
             UPDATE => open, TDO => tdo_i);

  u_jc_ctl_tck_bufg : BUFG
    port map(I => tck_raw, O => tck_o);
end architecture;
