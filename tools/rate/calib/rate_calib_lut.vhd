-- tools/rate/calib/rate_calib_lut.vhd -- DEPTH levels of LUT6 between registers, WIDTH lanes.
-- dont_touch on every stage keeps one LUT per level; the rating shell supplies the registers.
library ieee; use ieee.std_logic_1164.all;
entity rate_calib_lut is
  generic(DEPTH : positive := 4; WIDTH : positive := 64);
  port(clk : in std_logic;
       d   : in  std_logic_vector(WIDTH*6-1 downto 0);
       q   : out std_logic_vector(WIDTH-1 downto 0));
end entity;
architecture rtl of rate_calib_lut is
  type stage_t is array (0 to DEPTH) of std_logic_vector(WIDTH-1 downto 0);
  signal s : stage_t;
  attribute dont_touch : string;
  attribute dont_touch of s : signal is "true";
begin
  lanes : for l in 0 to WIDTH-1 generate
    s(0)(l) <= d(l*6) xor d(l*6+1) xor d(l*6+2) xor d(l*6+3) xor d(l*6+4) xor d(l*6+5);
    levels : for k in 1 to DEPTH-1 generate
      s(k)(l) <= s(k-1)(l) xor d((l*6 + k) mod (WIDTH*6)) xor d((l*6 + 2*k + 1) mod (WIDTH*6))
                 xor d((l*6 + 3*k + 2) mod (WIDTH*6)) xor d((l*6 + 5*k + 3) mod (WIDTH*6))
                 xor d((l*6 + 7*k + 4) mod (WIDTH*6));
    end generate;
    q(l) <= s(DEPTH-1)(l);
  end generate;
end architecture;
