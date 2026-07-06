library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity rmsnorm_ps is
  generic(N:integer:=64; Q:integer:=12);
  port(clk,rst,start:in std_logic;
       x_mant:in std_logic_vector(N*16-1 downto 0); x_exp:in integer;
       w_mant:in std_logic_vector(N*16-1 downto 0); w_exp:in integer;
       done:out std_logic;
       o_mant:out std_logic_vector(N*16-1 downto 0); o_exp:out integer);
end;
architecture w of rmsnorm_ps is
  component rmsnorm is
    port(clk,rst,start:in std_logic;
         x_mant:in std_logic_vector(1023 downto 0); x_exp:in std_logic_vector(31 downto 0);
         w_mant:in std_logic_vector(1023 downto 0); w_exp:in std_logic_vector(31 downto 0);
         done:out std_logic;
         o_mant:out std_logic_vector(1023 downto 0); o_exp:out std_logic_vector(31 downto 0));
  end component;
  signal oe:std_logic_vector(31 downto 0);
begin
  o_exp <= to_integer(signed(oe));
  u: rmsnorm port map(clk=>clk,rst=>rst,start=>start,
     x_mant=>x_mant,x_exp=>std_logic_vector(to_signed(x_exp,32)),
     w_mant=>w_mant,w_exp=>std_logic_vector(to_signed(w_exp,32)),
     done=>done,o_mant=>o_mant,o_exp=>oe);
end;
