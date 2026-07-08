library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity attention_ml_net_ps is
  generic(DIM:integer:=64; HEAD_SIZE:integer:=8; NHEADS:integer:=8; NKVH:integer:=4;
          KVDIM:integer:=32; MAXPOS:integer:=24; NLAYERS:integer:=5; Q:integer:=12);
  port(clk,rst,start:in std_logic; layer:in integer; cur_pos:in integer;
       q_mant:in std_logic_vector(DIM*16-1 downto 0); q_exp:in integer;
       k_new_mant:in std_logic_vector(KVDIM*16-1 downto 0); k_new_exp:in integer;
       v_new_mant:in std_logic_vector(KVDIM*16-1 downto 0); v_new_exp:in integer;
       done:out std_logic; xb_mant:out std_logic_vector(DIM*16-1 downto 0); xb_exp:out integer);
end;
architecture w of attention_ml_net_ps is
  component attention_ml is
    port(clk,rst,start:in std_logic; layer:in std_logic_vector(31 downto 0); cur_pos:in std_logic_vector(31 downto 0);
         q_mant:in std_logic_vector(1023 downto 0); q_exp:in std_logic_vector(31 downto 0);
         k_new_mant:in std_logic_vector(511 downto 0); k_new_exp:in std_logic_vector(31 downto 0);
         v_new_mant:in std_logic_vector(511 downto 0); v_new_exp:in std_logic_vector(31 downto 0);
         done:out std_logic; xb_mant:out std_logic_vector(1023 downto 0); xb_exp:out std_logic_vector(31 downto 0));
  end component;
  signal xe:std_logic_vector(31 downto 0);
begin
  xb_exp <= to_integer(signed(xe));
  u: attention_ml port map(clk=>clk,rst=>rst,start=>start,
     layer=>std_logic_vector(to_signed(layer,32)),cur_pos=>std_logic_vector(to_signed(cur_pos,32)),
     q_mant=>q_mant,q_exp=>std_logic_vector(to_signed(q_exp,32)),
     k_new_mant=>k_new_mant,k_new_exp=>std_logic_vector(to_signed(k_new_exp,32)),
     v_new_mant=>v_new_mant,v_new_exp=>std_logic_vector(to_signed(v_new_exp,32)),
     done=>done,xb_mant=>xb_mant,xb_exp=>xe);
end;
