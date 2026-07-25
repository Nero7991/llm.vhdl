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
  -- Canonical Vivado READ_FIRST simple-dual-port template (write-if, then read).
  -- Forcing block RAM earlier gave an undefined same-address R/W collision on
  -- silicon (a write-once slot read back DIFFERENT values at different token
  -- positions).  This canonical order is what Vivado's inference reliably maps to
  -- a READ_FIRST RAM (old value on collision) -- matching what tb_engine_shared
  -- validates -- for BOTH the wide value caches and the narrow exp caches.  No
  -- ram_style override, so each instance picks the right primitive.
begin
  process(clk) begin
    if rising_edge(clk) then
      if we='1' then ram(to_integer(unsigned(waddr))) <= din; end if;
      dout <= ram(to_integer(unsigned(raddr)));
    end if;
  end process;
end;
