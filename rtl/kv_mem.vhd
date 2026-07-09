library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
entity kv_mem is
  generic(WORDS:positive; W:positive:=16);
  port(clk:in std_logic; we:in std_logic;
       waddr,raddr:in std_logic_vector(clog2(WORDS)-1 downto 0);
       din:in std_logic_vector(W-1 downto 0);
       dout:out std_logic_vector(W-1 downto 0));
end;
architecture rtl of kv_mem is
  type ram_t is array(0 to WORDS-1) of std_logic_vector(W-1 downto 0);
  signal ram : ram_t := (others=>(others=>'0'));
  -- NOTE: NOT block RAM.  Forcing block RAM introduced a read/write COLLISION on
  -- HW -- a read of a fixed slot returned different data at different times (V[0]
  -- varied run-to-run across token positions), corrupting attention from pos ~3 on.
  -- Distributed RAM reads the OLD value on a same-address R/W (deterministic), and
  -- the non-determinism block RAM was meant to fix was actually cured by the
  -- softmax-exp pipeline.  Explicit READ_FIRST semantics below make it unambiguous.
begin
  process(clk) begin
    if rising_edge(clk) then
      dout <= ram(to_integer(unsigned(raddr)));   -- read BEFORE write (READ_FIRST)
      if we='1' then ram(to_integer(unsigned(waddr))) <= din; end if;
    end if;
  end process;
end;
