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
  -- Force BLOCK RAM: the narrow exp caches (u_kc_e/u_vc_e) otherwise infer as
  -- DISTRIBUTED RAM, which ignores the zero-init -> uninitialised reads are
  -- non-deterministic on HW (attention output varied run-to-run while the KV
  -- INPUT was deterministic).  Block RAM honours the init (reads-before-write = 0).
  attribute ram_style : string;
  attribute ram_style of ram : signal is "block";
begin
  process(clk) begin
    if rising_edge(clk) then
      if we='1' then ram(to_integer(unsigned(waddr))) <= din; end if;
      dout <= ram(to_integer(unsigned(raddr)));
    end if;
  end process;
end;
