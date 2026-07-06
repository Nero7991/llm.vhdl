library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity swiglu_ps is
  generic(N:positive:=172; Q:integer:=12);
  port(clk,rst,start:in std_logic; hb_mant:in std_logic_vector(N*16-1 downto 0); hb_exp:in integer;
       hb2_mant:in std_logic_vector(N*16-1 downto 0); hb2_exp:in integer; done:out std_logic;
       out_q:out std_logic_vector(N*32-1 downto 0));
end;
architecture w of swiglu_ps is
  component swiglu is
    port(clk,rst,start:in std_logic; hb_mant:in std_logic_vector(2751 downto 0); hb_exp:in std_logic_vector(31 downto 0);
         hb2_mant:in std_logic_vector(2751 downto 0); hb2_exp:in std_logic_vector(31 downto 0); done:out std_logic;
         out_q:out std_logic_vector(5503 downto 0));
  end component;
begin
  u: swiglu port map(clk=>clk,rst=>rst,start=>start,hb_mant=>hb_mant,hb_exp=>std_logic_vector(to_signed(hb_exp,32)),
     hb2_mant=>hb2_mant,hb2_exp=>std_logic_vector(to_signed(hb2_exp,32)),done=>done,out_q=>out_q);
end;
