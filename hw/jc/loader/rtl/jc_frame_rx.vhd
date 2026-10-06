-- Jungle Cat loader: the BSCANE2 (USER4) primitive and the TCK clock buffer. Synthesis
-- only: GHDL cannot simulate the primitive, so benches drive rtl/jc_frame_core.vhd (and
-- rtl/jc_loader_core.vhd, which contains it) directly.
--
-- Task 10 adaptation of the plan text: the plan's jc_frame_rx wrapped jc_frame_core.
-- jc_loader_core already instantiates jc_frame_core (Task 6), so wrapping it here would
-- put a second receiver in the design. This entity therefore exposes the primitive's
-- TCK (through a BUFG), SEL, CAPTURE, SHIFT, TDI and takes TDO, and nothing else; the
-- receiver lives in the core exactly once.
--
-- JTAG_CHAIN => 4 is USER4 (IR 100011100100 on the VU35P, BSDL xcvu35p_fsvh2104.bsd).
-- build_loader.tcl prints every BSCANE2's JTAG_CHAIN from the implemented netlist and
-- refuses a build where this is not exactly one chain-4 instance or where the debug
-- hub also sits on chain 4.
library ieee;
use ieee.std_logic_1164.all;
library unisim;
use unisim.vcomponents.all;

entity jc_frame_rx is
  port(
    tck_o     : out std_logic;
    sel_o     : out std_logic;
    capture_o : out std_logic;
    shift_o   : out std_logic;
    tdi_o     : out std_logic;
    tdo_i     : in  std_logic
  );
end entity;

architecture rtl of jc_frame_rx is
  signal tck_raw : std_logic;
begin
  u_jc_bscan : BSCANE2
    generic map(JTAG_CHAIN => 4)
    port map(CAPTURE => capture_o, DRCK => open, RESET => open, RUNTEST => open,
             SEL => sel_o, SHIFT => shift_o, TCK => tck_raw, TDI => tdi_o, TMS => open,
             UPDATE => open, TDO => tdo_i);

  u_jc_tck_bufg : BUFG
    port map(I => tck_raw, O => tck_o);
end architecture;
