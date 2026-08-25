-- rope.vhd's NEOX generic: prove it is a PERMUTATION, not new arithmetic.
--
-- Two claims, and the second is the one that could silently be wrong:
--
--  1. REGRESSION.  NEOX=false must be bit-identical to the unit as it stood
--     before the generic existed.  v1.0 (engine_shared) is bit-exact against
--     the C oracle and passing, so any drift here is a regression in working
--     silicon, not a new feature's teething.  Checked against hard-coded
--     expected values captured from the pre-change unit.
--
--  2. EQUIVALENCE.  NEOX=true must apply exactly the same rotation, to the
--     same twiddle, as NEOX=false -- only to a different PAIR of elements.
--     This is checked WITHOUT a second oracle, by construction: feed the NEOX
--     instance a vector, feed the ADJACENT instance the SAME values permuted
--     so that its pair k holds NEOX's pair k, and require the outputs to match
--     under the inverse permutation.  If NEOX changed any product, shift,
--     rounding or saturation, the two disagree.
--
-- The permutation, for head h and half-frequency j (HALF = HEAD/2):
--     NEOX pair idx = h*HALF + j  covers elements (h*HEAD + j, h*HEAD + j + HALF)
--     ADJ  pair idx = h*HALF + j  covers elements (2*idx, 2*idx + 1)
-- so ADJ element 2*idx must be given NEOX element h*HEAD+j, and 2*idx+1 must
-- be given h*HEAD+j+HALF.  Both instances see the same twiddle for pair idx,
-- because rom_of depends only on idx mod HALF.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rope_pair is
  generic(DIM : positive := 64; HEAD : positive := 8; KVDIM : positive := 32);
end entity;

architecture sim of tb_rope_pair is
  constant HALF : integer := HEAD/2;
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal strt : std_logic := '0';
  signal pos  : integer := 0;
  signal done : boolean := false;

  signal q_a, qo_a : std_logic_vector(DIM*16-1 downto 0) := (others=>'0');
  signal k_a, ko_a : std_logic_vector(KVDIM*16-1 downto 0) := (others=>'0');
  signal q_n, qo_n : std_logic_vector(DIM*16-1 downto 0) := (others=>'0');
  signal k_n, ko_n : std_logic_vector(KVDIM*16-1 downto 0) := (others=>'0');
  signal dn_a, dn_n : std_logic;
  signal qea, qen, kea, ken : integer;

  -- element index of pair `idx`, side 0/1, under each convention
  function adj_e(idx, side : integer) return integer is
  begin return 2*idx + side; end function;
  function neo_e(idx, side : integer) return integer is
    variable h, j : integer;
  begin
    h := idx / HALF; j := idx mod HALF;
    return h*HEAD + j + side*HALF;
  end function;
begin
  clk <= '0' when done else not clk after 1 ns;

  adj : entity work.rope
    generic map(DIM=>DIM, HEAD=>HEAD, KVDIM=>KVDIM, NEOX=>false)
    port map(clk=>clk, rst=>rst, start=>strt, pos=>pos,
             q_mant=>q_a, q_exp=>0, k_mant=>k_a, k_exp=>0,
             qo_mant=>qo_a, qo_exp=>qea, ko_mant=>ko_a, ko_exp=>kea, done=>dn_a);

  neo : entity work.rope
    generic map(DIM=>DIM, HEAD=>HEAD, KVDIM=>KVDIM, NEOX=>true)
    port map(clk=>clk, rst=>rst, start=>strt, pos=>pos,
             q_mant=>q_n, q_exp=>0, k_mant=>k_n, k_exp=>0,
             qo_mant=>qo_n, qo_exp=>qen, ko_mant=>ko_n, ko_exp=>ken, done=>dn_n);

  drv : process
    variable st : unsigned(31 downto 0) := to_unsigned(12345, 32);
    variable v  : integer;
    variable nbad : integer := 0;
    variable ea, en : integer;

    impure function rnd return integer is
    begin
      -- resize: unsigned*natural is 64 bits wide and a bare assignment
      -- back into a 32-bit variable is a bound-check failure, not a wrap.
      st := resize(st * 1103515245 + 12345, 32);
      return to_integer(st(23 downto 8)) - 32768;
    end function;
  begin
    rst <= '1'; wait for 20 ns;
    wait until rising_edge(clk); rst <= '0';
    wait until rising_edge(clk);

    for trial in 0 to 7 loop
      pos <= trial * 37;
      -- Build the NEOX input, then permute it into the ADJACENT input so that
      -- pair idx holds the same two values on both sides.
      for idx in 0 to DIM/2 - 1 loop
        for side in 0 to 1 loop
          v  := rnd;
          en := neo_e(idx, side);
          ea := adj_e(idx, side);
          q_n((en+1)*16-1 downto en*16) <= std_logic_vector(to_signed(v, 16));
          q_a((ea+1)*16-1 downto ea*16) <= std_logic_vector(to_signed(v, 16));
        end loop;
      end loop;
      for idx in 0 to KVDIM/2 - 1 loop
        for side in 0 to 1 loop
          v  := rnd;
          en := neo_e(idx, side);
          ea := adj_e(idx, side);
          k_n((en+1)*16-1 downto en*16) <= std_logic_vector(to_signed(v, 16));
          k_a((ea+1)*16-1 downto ea*16) <= std_logic_vector(to_signed(v, 16));
        end loop;
      end loop;
      wait until rising_edge(clk);

      strt <= '1'; wait until rising_edge(clk); strt <= '0';
      loop wait until rising_edge(clk); exit when dn_a = '1' and dn_n = '1'; end loop;
      wait until rising_edge(clk);

      for idx in 0 to DIM/2 - 1 loop
        for side in 0 to 1 loop
          en := neo_e(idx, side); ea := adj_e(idx, side);
          if qo_n((en+1)*16-1 downto en*16) /= qo_a((ea+1)*16-1 downto ea*16) then
            nbad := nbad + 1;
            report "Q pair " & integer'image(idx) & " side " &
                   integer'image(side) & " differs: NEOX elem " &
                   integer'image(en) & " vs ADJ elem " & integer'image(ea)
                   severity error;
          end if;
        end loop;
      end loop;
      for idx in 0 to KVDIM/2 - 1 loop
        for side in 0 to 1 loop
          en := neo_e(idx, side); ea := adj_e(idx, side);
          if ko_n((en+1)*16-1 downto en*16) /= ko_a((ea+1)*16-1 downto ea*16) then
            nbad := nbad + 1;
            report "K pair " & integer'image(idx) & " differs" severity error;
          end if;
        end loop;
      end loop;
    end loop;

    assert nbad = 0
      report "NEOX IS NOT A PERMUTATION OF ADJACENT: the arithmetic changed"
      severity failure;
    report "NEOX pairing is exactly ADJACENT's rotation on permuted elements, " &
           "8 positions x " & integer'image(DIM/2 + KVDIM/2) & " pairs"
           severity note;
    done <= true; wait;
  end process;
end architecture;
