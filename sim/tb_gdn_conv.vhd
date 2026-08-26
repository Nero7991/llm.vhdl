-- Checks gdn_conv (B 2.1.3's depthwise causal conv) the same two ways
-- tb_gdn_recur does, and for the same reason: bit-exactness against a second
-- transcription of the recipe catches transcription errors and cannot catch an
-- error IN the recipe, which is how the l2norm collapse survived 55 passing
-- cases.
--
--   1. BIT-EXACT against ref/gdn_conv_vec.c, a different language.
--   2. REAL-VALUED against a double-precision oracle of the same segment,
--      carried in the same file.  Different number system, so it can catch a
--      wrong recipe.
--
-- The case set deliberately sweeps the VALID MASK, including the sequence-start
-- prefixes 0001/0011/0111, because 2.1.3's rule that invalid taps leave the
-- e_ref MINIMUM as well as the sum is the rule 2.1.4 violated twice, both times
-- costing the first token most of its precision.
-- The lane loop index is `ln`, not `k`: VHDL is case-insensitive, so `for k`
-- shadows the generic `K` and every `*K + t` in here silently becomes `*k + t`.
-- The DUT had the same bug and it cost real time; see rtl/gdn_conv.vhd.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_conv is
  generic(CH    : positive := 256;
          K     : positive := 4;
          LANES : positive := 8;
          VECS  : string   := "gdn_conv_vec.txt";
          -- Against the ORACLE, in LSB of the segment's own grid.  Each tap is
          -- floor-aligned before summing, so the accumulator can be up to K
          -- LSBs low on ITS grid, which becomes K/2^sh_seg on the output grid;
          -- the final requantize adds half an LSB.  Set from measurement.
          -- Measured worst is 0.4999999 LSB, so 0.75 is the honest bound: it
          -- leaves room for the floor-alignment of each tap while still
          -- separating correct round-half-up from truncation, which reaches
          -- 1.0.  A tolerance set from a round number rather than from the
          -- measurement is how tb_l2norm_rs admitted a dropped rounding bias.
          TOL : real := 0.75);
end entity;

architecture sim of tb_gdn_conv is
  constant NB : integer := CH / LANES;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal start, s_valid, o_valid, o_done, err_seg, ready : std_logic := '0';
  signal tvalid : std_logic_vector(K-1 downto 0) := (others => '0');
  signal e_t    : std_logic_vector(K*8-1 downto 0) := (others => '0');
  signal cw_exp : signed(7 downto 0) := (others => '0');
  signal x_in, w_in : std_logic_vector(K*LANES*16-1 downto 0) := (others => '0');
  signal o_data : std_logic_vector(LANES*16-1 downto 0);
  signal e_seg  : signed(7 downto 0);
  signal sh_seg : integer range 0 to 63;

  signal loaded : boolean := false;
  type i_arr is array (natural range <>) of integer;
  type r_arr is array (natural range <>) of real;
begin
  clk <= not clk after 5 ns;

  dut : entity work.gdn_conv
    generic map(CH => CH, K => K, LANES => LANES)
    port map(clk => clk, rst => rst, start => start,
             tvalid => tvalid, e_t => e_t, cw_exp => cw_exp,
             s_valid => s_valid, x_in => x_in, w_in => w_in,
             o_valid => o_valid, o_data => o_data, o_done => o_done,
             e_seg => e_seg, sh_seg => sh_seg, err_seg => err_seg, ready => ready);

  drive : process
    file fh : text; variable ln : line;
    variable iv, ncase, chv, kv : integer; variable rv : real;
    variable c_vmask, c_cw, c_eseg, c_sh, c_err : integer;
    variable c_et : i_arr(0 to K-1);
    variable xv, wv : i_arr(0 to CH*K-1);
    variable sm : i_arr(0 to CH-1);
    variable orc : r_arr(0 to CH-1);
    variable got : i_arr(0 to CH-1);
    variable g, bad, nbad, ntol, e_ref_i : integer;
    variable e, worst : real;
    variable cyc : integer;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, ncase); read(ln, chv); read(ln, kv);
    assert chv = CH and kv = K report "vector file shape" severity failure;
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);
    nbad := 0; ntol := 0; worst := 0.0;

    for c in 0 to ncase-1 loop
      readline(fh, ln);
      read(ln, c_vmask); read(ln, c_cw);
      for t in 0 to K-1 loop read(ln, c_et(t)); end loop;
      read(ln, c_eseg); read(ln, c_sh); read(ln, c_err);
      readline(fh, ln); for i in 0 to CH*K-1 loop read(ln, xv(i)); end loop;
      readline(fh, ln); for i in 0 to CH*K-1 loop read(ln, wv(i)); end loop;
      readline(fh, ln); for i in 0 to CH-1 loop read(ln, sm(i)); end loop;
      readline(fh, ln); for i in 0 to CH-1 loop read(ln, orc(i)); end loop;

      for t in 0 to K-1 loop
        tvalid(t) <= '1' when (c_vmask / (2**t)) mod 2 = 1 else '0';
        e_t((t+1)*8-1 downto t*8) <= std_logic_vector(to_signed(c_et(t), 8));
      end loop;
      cw_exp <= to_signed(c_cw, 8);
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';

      -- pass A: stream the channel groups once the unit is ready
      while ready /= '1' loop wait until rising_edge(clk); end loop;
      for gi in 0 to NB-1 loop
        for t in 0 to K-1 loop
          for ln in 0 to LANES-1 loop
            -- the file stores channel-major, K taps per channel
            x_in((t*LANES+ln+1)*16-1 downto (t*LANES+ln)*16)
              <= std_logic_vector(to_signed(xv((gi*LANES+ln)*K + t), 16));
            w_in((t*LANES+ln+1)*16-1 downto (t*LANES+ln)*16)
              <= std_logic_vector(to_signed(wv((gi*LANES+ln)*K + t), 16));
          end loop;
        end loop;
        s_valid <= '1';
        wait until rising_edge(clk);
      end loop;
      s_valid <= '0';

      -- collect pass B
      g := 0; cyc := 0;
      while o_done /= '1' loop
        if o_valid = '1' then
          for ln in 0 to LANES-1 loop
            got(g*LANES + ln) := to_integer(signed(o_data((ln+1)*16-1 downto ln*16)));
          end loop;
          g := g + 1;
        end if;
        wait until rising_edge(clk);
        cyc := cyc + 1;
        assert cyc < 20000 report "gdn_conv: no done" severity failure;
      end loop;
      wait for 1 ns;

      -- check 1: bit-exact
      bad := 0;
      for i in 0 to CH-1 loop
        if got(i) /= sm(i) then bad := bad + 1; end if;
      end loop;
      if c_err = 1 then
        if err_seg /= '1' then bad := bad + 1; end if;
      else
        if to_integer(e_seg) /= c_eseg then bad := bad + 1; end if;
        if sh_seg /= c_sh then bad := bad + 1; end if;
      end if;
      if bad /= 0 then
        report "case " & integer'image(c) & ": NOT BIT-EXACT in "
             & integer'image(bad) & " field(s)  (e_seg got "
             & integer'image(to_integer(e_seg)) & " want " & integer'image(c_eseg)
             & ", sh got " & integer'image(sh_seg) & " want " & integer'image(c_sh)
             & ")" severity error;
        nbad := nbad + 1;
      end if;

      -- check 2: real-valued.  sm * 2^-e_seg = orc * 2^-cw_exp, and
      -- e_seg = e_ref + cw_exp - sh_seg, so sm = orc * 2^(e_ref - sh_seg).
      if c_err = 0 then
        e_ref_i := c_eseg + c_sh - c_cw;
        bad := 0;
        for i in 0 to CH-1 loop
          e := abs(real(got(i)) - orc(i) * 2.0 ** real(e_ref_i - c_sh));
          if e > worst then worst := e; end if;
          if e > TOL then bad := bad + 1; end if;
        end loop;
        if bad /= 0 then
          report "case " & integer'image(c) & ": OUT OF TOLERANCE vs ORACLE in "
               & integer'image(bad) & " channel(s)" severity error;
          ntol := ntol + 1;
        end if;
      end if;
    end loop;

    file_close(fh);
    assert nbad = 0 report "gdn_conv is NOT bit-exact in " & integer'image(nbad)
      & " case(s)" severity error;
    assert ntol = 0 report "gdn_conv is outside oracle tolerance in "
      & integer'image(ntol) & " case(s)" severity error;
    if nbad = 0 and ntol = 0 then
      report "gdn_conv: bit-exact with the C recipe on all " & integer'image(ncase)
           & " cases; worst vs the double ORACLE " & real'image(worst) & " LSB"
           severity note;
    end if;
    wait;
  end process;
end architecture;
