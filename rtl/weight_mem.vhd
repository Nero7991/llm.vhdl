library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all; use work.util_pkg.all;
entity weight_mem is
  generic(WORDS:positive; W:positive:=8; INIT:string);
  port(clk:in std_logic; addr:in std_logic_vector(clog2(WORDS)-1 downto 0);
       dout:out std_logic_vector(W-1 downto 0));
end;
architecture rtl of weight_mem is
  type rom_t is array(0 to WORDS-1) of std_logic_vector(W-1 downto 0);
  -- impure: reads a file at elaboration to initialize the ROM.
  impure function load(fn:string) return rom_t is
    file fh:text open read_mode is fn; variable L:line; variable v:integer;
    variable r:rom_t;
  begin
    for i in 0 to WORDS-1 loop
      readline(fh,L); read(L,v);
      r(i):=std_logic_vector(to_signed(v,W));
    end loop; return r;
  end function;
  signal rom:rom_t := load(INIT);
begin
  process(clk) begin
    if rising_edge(clk) then dout <= rom(to_integer(unsigned(addr))); end if;
  end process;
end;
