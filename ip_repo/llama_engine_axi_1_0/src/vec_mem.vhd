-- rtl/vec_mem.vhd
-- Small synchronous single-clock simple-dual-port RAM for the FFN swiglu->bfp_pack
-- intermediate (N=HIDDEN Q12 int32 values).
--
-- WHY: swiglu used to emit its N*32-bit result as one wide `out_q` register and
-- bfp_pack read it back with a variable index in BOTH its S_MAX and S_PACK passes.
-- Synth turned that into a 172-way 32-bit DEMUX (swiglu) plus two 172-way 32-bit
-- MUXes (bfp_pack) -- several K LUTs on a LUT-bound (~82%) design.  Moving the
-- intermediate into a BRAM makes the access sequential-address (no mux) and frees
-- those LUTs at the cost of ~1 BRAM tile.
--
-- Registered read (1-cycle latency), synchronous write.  Mirrors kv_mem.vhd.
-- The producer (swiglu) writes all N words first; only AFTER swiglu's `done` does
-- the master FSM start bfp_pack reading -- so write and read are temporally
-- separated and there is never a same-address read/write collision here.  With no
-- collision hazard it is safe to force block RAM (unlike kv_mem, which must let
-- Vivado pick to get READ_FIRST collision behaviour on the shared KV cache).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
entity vec_mem is
  generic(WORDS : positive := 172; W : positive := 32);
  port(clk   : in  std_logic;
       we    : in  std_logic;
       waddr : in  std_logic_vector(clog2(WORDS)-1 downto 0);
       raddr : in  std_logic_vector(clog2(WORDS)-1 downto 0);
       din   : in  std_logic_vector(W-1 downto 0);
       dout  : out std_logic_vector(W-1 downto 0));
end;
architecture rtl of vec_mem is
  type ram_t is array(0 to WORDS-1) of std_logic_vector(W-1 downto 0);
  signal ram : ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of ram : signal is "block";
begin
  process(clk) begin
    if rising_edge(clk) then
      if we = '1' then ram(to_integer(unsigned(waddr))) <= din; end if;
      dout <= ram(to_integer(unsigned(raddr)));
    end if;
  end process;
end;
