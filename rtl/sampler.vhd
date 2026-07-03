-- rtl/sampler.vhd
-- Argmax over VOCAB=512 signed int32 logits, first-max-on-ties, matching the
-- C oracle's sample_argmax() exactly:
--   int max_i = 0; float max_p = probabilities[0];
--   for (i = 1; i < n; i++) if (probabilities[i] > max_p) { max_i = i; max_p = probabilities[i]; }
-- i.e. index 0 is the initial candidate and later indices only displace it on
-- a STRICT '>' comparison, so the first occurrence of the maximum wins.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sampler is
  generic(
    VOCAB : integer := 512
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    logits : in  std_logic_vector(VOCAB*32-1 downto 0);
    done   : out std_logic;
    token  : out integer
  );
end entity;

architecture rtl of sampler is
begin

  process(clk)
    variable best_i : integer;
    variable best_v : signed(31 downto 0);
    variable cur_v  : signed(31 downto 0);
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        token <= 0;
      elsif start = '1' then
        best_i := 0;
        best_v := signed(logits(32-1 downto 0));
        for v in 1 to VOCAB-1 loop
          cur_v := signed(logits((v+1)*32-1 downto v*32));
          if cur_v > best_v then
            best_v := cur_v;
            best_i := v;
          end if;
        end loop;
        token <= best_i;
        done  <= '1';
      end if;
    end if;
  end process;

end architecture;
