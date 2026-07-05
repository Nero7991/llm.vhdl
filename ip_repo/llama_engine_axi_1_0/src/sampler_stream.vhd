-- rtl/sampler_stream.vhd
-- STREAMING argmax over VOCAB signed int32 logits, first-max-on-ties, matching
-- the C oracle's sample_argmax() (index 0 is the initial candidate; later indices
-- displace it only on a STRICT '>' compare, so the first max wins on ties).
--
-- Used by rtl/engine_shared.vhd in place of the parallel rtl/sampler.vhd: instead
-- of a VOCAB*32-bit logits bus + an unrolled 512-way comparator tree (which
-- flattened to ~21K LUT reading a 16384-bit bus), lm_head streams one logit per
-- cycle and this unit keeps a running max:
--   clr='1'      -> reset (the next in_valid is index 0).
--   in_valid='1' -> fold the logit at the running index into the max.
-- `token` holds the running argmax; it is final once the producer's `done` fires.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sampler_stream is
  generic(
    VOCAB : integer := 512
  );
  port(
    clk      : in  std_logic;
    rst      : in  std_logic;
    clr      : in  std_logic;                       -- reset the running max
    in_valid : in  std_logic;                       -- one logit this cycle
    in_v     : in  std_logic_vector(31 downto 0);   -- the logit value
    token    : out integer
  );
end entity;

architecture rtl of sampler_stream is
begin

  process(clk)
    variable idx    : integer := 0;
    variable first  : boolean := true;
    variable best_i : integer := 0;
    variable best_v : signed(31 downto 0) := (others => '0');
    variable cur    : signed(31 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        token  <= 0;
        idx    := 0;
        first  := true;
        best_i := 0;
      elsif clr = '1' then
        idx    := 0;
        first  := true;
        best_i := 0;
      elsif in_valid = '1' then
        cur := signed(in_v);
        if first then
          best_v := cur;      -- index 0 is the initial candidate
          best_i := 0;
          first  := false;
        elsif cur > best_v then
          best_v := cur;      -- strict '>' so the first max wins on ties
          best_i := idx;
        end if;
        idx   := idx + 1;
        token <= best_i;      -- running argmax (final after the last logit)
      end if;
    end if;
  end process;

end architecture;
