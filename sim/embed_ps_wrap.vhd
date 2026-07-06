library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity embed_ps is
  generic(DIM:integer:=64; VOCAB:integer:=512; WEIGHT_DIR:string:="../mem/weights/"; ROM_DIR:string:="../mem/rom/");
  port(clk:in std_logic; en:in std_logic:='1'; token:in integer; done:out std_logic;
       x_mant:out std_logic_vector(DIM*16-1 downto 0); x_exp:out integer);
end;
architecture w of embed_ps is
  component embed is
    port(clk:in std_logic; en:in std_logic; token:in std_logic_vector(31 downto 0);
         done:out std_logic; x_mant:out std_logic_vector(1023 downto 0); x_exp:out std_logic_vector(31 downto 0));
  end component;
  signal xe:std_logic_vector(31 downto 0);
begin
  x_exp <= to_integer(signed(xe));
  u: embed port map(clk=>clk,en=>en,token=>std_logic_vector(to_signed(token,32)),done=>done,x_mant=>x_mant,x_exp=>xe);
end;
