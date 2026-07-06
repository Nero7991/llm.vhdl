library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity lm_head_ps is
  generic(DIM:integer:=64; VOCAB:integer:=512; WEIGHT_DIR:string:="../mem/weights/"; ROM_DIR:string:="../mem/rom/");
  port(clk,rst,start:in std_logic; x_mant:in std_logic_vector(DIM*16-1 downto 0); x_exp:in integer;
       done:out std_logic; logits:out std_logic_vector(VOCAB*32-1 downto 0);
       logit_valid:out std_logic; logit_v:out std_logic_vector(31 downto 0));
end;
architecture w of lm_head_ps is
  component lm_head is
    port(clk,rst,start:in std_logic; x_mant:in std_logic_vector(1023 downto 0); x_exp:in std_logic_vector(31 downto 0);
         done:out std_logic; logits:out std_logic_vector(16383 downto 0); logit_valid:out std_logic; logit_v:out std_logic_vector(31 downto 0));
  end component;
begin
  u: lm_head port map(clk=>clk,rst=>rst,start=>start,x_mant=>x_mant,x_exp=>std_logic_vector(to_signed(x_exp,32)),
     done=>done,logits=>logits,logit_valid=>logit_valid,logit_v=>logit_v);
end;
