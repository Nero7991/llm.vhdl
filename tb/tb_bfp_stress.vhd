-- tb/tb_bfp_stress.vhd
-- Adversarial stress of the swiglu->vec_mem->bfp_pack read-ahead/addressing.
-- Wires vec_mem + bfp_pack exactly as engine_shared does, fills the BRAM with
-- KNOWN per-index patterns (distinct per element, spikes at boundary indices)
-- that the full-engine golden never specifically produces, then checks every
-- o_mant[i] and o_exp against an INDEPENDENTLY hand-computed reference (does NOT
-- call scale_mul).  Detects: off-by-one read-ahead in S_MAX or S_PACK, a dropped
-- first/last element in the max scan, and a stale i_rdata at the S_MAX->S_PACK
-- turnaround.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity tb_bfp_stress is end entity;

architecture sim of tb_bfp_stress is
  constant N : integer := 172;
  constant Q : integer := 12;
  constant AW : integer := clog2(N);

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';

  -- vec_mem write port (driven by tb, mimicking swiglu)
  signal we    : std_logic := '0';
  signal waddr : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal wdata : std_logic_vector(31 downto 0)   := (others => '0');

  -- bfp_pack <-> vec_mem read link
  signal raddr : std_logic_vector(AW-1 downto 0);
  signal rdata : std_logic_vector(31 downto 0);

  signal hbp_start : std_logic := '0';
  signal hbp_done  : std_logic;
  signal o_mant    : std_logic_vector(N*16-1 downto 0);
  signal o_exp     : integer;

  type pat_t is array(0 to N-1) of integer;
  signal fail_count : integer := 0;

  -- Independent reference: round-half-up divide by 2^shift (floor via signed
  -- shift_right of (x + bias)), then clamp to int16.  Deliberately NOT scale_mul.
  function ref_mant(x : integer; shift : integer) return integer is
    variable bias : integer;
    variable r    : integer;
  begin
    if shift = 0 then
      r := x;
    else
      bias := 2**(shift-1);
      r := to_integer(shift_right(to_signed(x + bias, 64), shift));
    end if;
    if    r >  32767 then r :=  32767;
    elsif r < -32768 then r := -32768; end if;
    return r;
  end function;

begin
  clk <= not clk after 5 ns;

  u_mem : entity work.vec_mem
    generic map(WORDS => N, W => 32)
    port map(clk => clk, we => we, waddr => waddr, raddr => raddr,
             din => wdata, dout => rdata);

  u_bfp : entity work.bfp_pack
    generic map(N => N, Q => Q)
    port map(clk => clk, rst => rst, start => hbp_start,
             o_raddr => raddr, i_rdata => rdata, done => hbp_done,
             o_mant => o_mant, o_exp => o_exp);

  stim : process
    variable pat    : pat_t;
    variable maxabs : integer;
    variable shift  : integer;
    variable exp_e  : integer;
    variable got    : integer;
    variable want   : integer;
    variable emsb   : integer;

    -- Load the whole pattern into vec_mem (one write/cycle, like swiglu), then
    -- pulse bfp_pack start and wait for done, then verify.
    procedure run_case(name : string; p : pat_t) is
    begin
      -- compute reference max / shift / exp
      maxabs := 0;
      for i in 0 to N-1 loop
        if abs(p(i)) > maxabs then maxabs := abs(p(i)); end if;
      end loop;
      emsb  := msb_pos(maxabs);
      shift := emsb - 14; if shift < 0 then shift := 0; end if;
      exp_e := Q - shift;

      -- write all N elements
      wait until rising_edge(clk);
      for i in 0 to N-1 loop
        we    <= '1';
        waddr <= std_logic_vector(to_unsigned(i, AW));
        wdata <= std_logic_vector(to_signed(p(i), 32));
        wait until rising_edge(clk);
      end loop;
      we <= '0';
      -- separation gap (engine waits for swiglu 'done' before hbp start)
      wait until rising_edge(clk);
      wait until rising_edge(clk);

      -- pulse start (single cycle, like L_HBPACK_S)
      hbp_start <= '1';
      wait until rising_edge(clk);
      hbp_start <= '0';

      -- wait for done
      loop
        wait until rising_edge(clk);
        exit when hbp_done = '1';
      end loop;
      -- o_mant/o_exp valid on the done edge; sample after a delta
      wait for 1 ns;

      -- check exponent
      if o_exp /= exp_e then
        report "CASE " & name & ": o_exp MISMATCH got=" & integer'image(o_exp) &
               " want=" & integer'image(exp_e) severity error;
        fail_count <= fail_count + 1;
      else
        report "CASE " & name & ": o_exp OK = " & integer'image(o_exp) &
               " (maxabs=" & integer'image(maxabs) & " shift=" &
               integer'image(shift) & ")" severity note;
      end if;

      -- check every mantissa element
      for i in 0 to N-1 loop
        got  := to_integer(signed(o_mant((i+1)*16-1 downto i*16)));
        want := ref_mant(p(i), shift);
        if got /= want then
          report "CASE " & name & ": o_mant[" & integer'image(i) &
                 "] MISMATCH got=" & integer'image(got) &
                 " want=" & integer'image(want) &
                 " (pat=" & integer'image(p(i)) & ")" severity error;
          fail_count <= fail_count + 1;
          wait for 0 ns;   -- let fail_count settle before next iter accumulation
        end if;
      end loop;
      report "CASE " & name & ": mantissa scan complete" severity note;
    end procedure;

  begin
    -- reset
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- CASE A: shift=0, distinct per-index ramp (index-sensitive; first=idx0,
    -- last=idx171 both nonzero).  A one-element addressing shift => mismatch.
    for i in 0 to N-1 loop pat(i) := i - 86; end loop;
    run_case("A_ramp_shift0", pat);

    -- CASE B: spike at a MID index (137) sets shift=6; ramp distinct multiples
    -- of 64 with negative (floor) rounding; saturation-free but index-sensitive.
    for i in 0 to N-1 loop pat(i) := (i - 86) * 4096; end loop;
    pat(137) := 1048576;   -- 2^20 -> msb 20 -> shift 6 -> o_exp 6
    run_case("B_spike_mid", pat);

    -- CASE C: spike at the LAST index (N-1) -- specifically checks the S_MAX
    -- drain folds element N-1 into the max.  If the read-ahead dropped the last
    -- element, shift/o_exp collapse and pat(171) would NOT saturate/shift right.
    for i in 0 to N-1 loop pat(i) := (i mod 5) - 2; end loop;
    pat(N-1) := 524288;    -- 2^19 -> msb 19 -> shift 5 -> o_exp 7
    run_case("C_spike_last", pat);

    -- CASE D: spike at index 0 -- checks the S_MAX fill folds element 0.
    for i in 0 to N-1 loop pat(i) := (i mod 7) - 3; end loop;
    pat(0) := 262144;      -- 2^18 -> msb 18 -> shift 4 -> o_exp 8
    run_case("D_spike_first", pat);

    wait for 1 ns;
    if fail_count = 0 then
      report "ALL BFP-PACK STRESS CASES PASSED" severity note;
    else
      report "BFP-PACK STRESS FAILURES: " & integer'image(fail_count) severity failure;
    end if;
    std.env.stop;
  end process;
end architecture;
