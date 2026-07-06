library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity softmax_ps is
  generic(NMAX:positive:=4; Q:integer:=12);
  port(clk,rst,start:in std_logic; n:in integer;
       score_mant:in std_logic_vector(NMAX*16-1 downto 0); score_exp:in integer;
       done:out std_logic; prob_q:out std_logic_vector(NMAX*32-1 downto 0);
       e_out:out std_logic_vector(NMAX*32-1 downto 0); sum_out:out std_logic_vector(63 downto 0));
end;
architecture w of softmax_ps is
  component softmax is
    port(clk,rst,start:in std_logic; n:in std_logic_vector(31 downto 0);
         score_mant:in std_logic_vector(63 downto 0); score_exp:in std_logic_vector(31 downto 0);
         done:out std_logic; prob_q:out std_logic_vector(127 downto 0);
         e_out:out std_logic_vector(127 downto 0); sum_out:out std_logic_vector(63 downto 0));
  end component;
begin
  u: softmax port map(clk=>clk,rst=>rst,start=>start,n=>std_logic_vector(to_signed(n,32)),
     score_mant=>score_mant,score_exp=>std_logic_vector(to_signed(score_exp,32)),
     done=>done,prob_q=>prob_q,e_out=>e_out,sum_out=>sum_out);
end;
