library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity matmul_rt_ps is
  generic(MAXROWS:integer:=172; MAXCOLS:integer:=172);
  port(clk,rst,start: in std_logic;
       mat_sel, layer: in integer;
       x_mant: in std_logic_vector(MAXCOLS*16-1 downto 0);
       x_exp: in integer;
       done: out std_logic;
       o_mant: out std_logic_vector(MAXROWS*16-1 downto 0);
       o_exp: out integer);
end;
architecture w of matmul_rt_ps is
  component matmul_rt is
    port(clk,rst,start:in std_logic;
         mat_sel,layer:in std_logic_vector(31 downto 0);
         x_mant:in std_logic_vector(2751 downto 0);
         x_exp:in std_logic_vector(31 downto 0);
         done:out std_logic;
         o_mant:out std_logic_vector(2751 downto 0);
         o_exp:out std_logic_vector(31 downto 0));
  end component;
  signal oe: std_logic_vector(31 downto 0);
begin
  o_exp <= to_integer(signed(oe));
  u: matmul_rt port map(clk=>clk,rst=>rst,start=>start,
     mat_sel=>std_logic_vector(to_signed(mat_sel,32)),
     layer=>std_logic_vector(to_signed(layer,32)),
     x_mant=>x_mant, x_exp=>std_logic_vector(to_signed(x_exp,32)),
     done=>done, o_mant=>o_mant, o_exp=>oe);
end;
