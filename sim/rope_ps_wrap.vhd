library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity rope_ps is
  generic(DIM:integer:=64; HEAD:integer:=8; KVDIM:integer:=32);
  port(clk,rst,start:in std_logic; pos:in integer;
       q_mant:in std_logic_vector(DIM*16-1 downto 0); q_exp:in integer;
       k_mant:in std_logic_vector(KVDIM*16-1 downto 0); k_exp:in integer;
       done:out std_logic; qo_mant:out std_logic_vector(DIM*16-1 downto 0); qo_exp:out integer;
       ko_mant:out std_logic_vector(KVDIM*16-1 downto 0); ko_exp:out integer);
end;
architecture w of rope_ps is
  component rope is
    port(clk,rst,start:in std_logic; pos:in std_logic_vector(31 downto 0);
         q_mant:in std_logic_vector(1023 downto 0); q_exp:in std_logic_vector(31 downto 0);
         k_mant:in std_logic_vector(511 downto 0); k_exp:in std_logic_vector(31 downto 0);
         done:out std_logic; qo_mant:out std_logic_vector(1023 downto 0); qo_exp:out std_logic_vector(31 downto 0);
         ko_mant:out std_logic_vector(511 downto 0); ko_exp:out std_logic_vector(31 downto 0));
  end component;
  signal qe,ke:std_logic_vector(31 downto 0);
begin
  qo_exp<=to_integer(signed(qe)); ko_exp<=to_integer(signed(ke));
  u: rope port map(clk=>clk,rst=>rst,start=>start,pos=>std_logic_vector(to_signed(pos,32)),
    q_mant=>q_mant,q_exp=>std_logic_vector(to_signed(q_exp,32)),k_mant=>k_mant,k_exp=>std_logic_vector(to_signed(k_exp,32)),
    done=>done,qo_mant=>qo_mant,qo_exp=>qe,ko_mant=>ko_mant,ko_exp=>ke);
end;
