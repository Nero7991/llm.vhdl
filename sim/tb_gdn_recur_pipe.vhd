-- Checks gdn_recur_pipe TWO ways and measures the achieved issue interval --
-- the last of which is the whole reason the pipelined unit exists.
--
--   1. BIT-EXACT against ref/gdn_recur_vec.c's fixed path, the same vectors
--      tb_gdn_recur uses.
--   2. REAL-VALUED against the double-precision ORACLE carried in the same
--      vector file, on the physically realizable columns.
--
-- WHY CHECK 2 IS HERE AS OF 2026-08-28.  Until today this file READ the
-- oracle's u and o columns and threw them away with two bare `readline`s, so
-- the only thing it asserted was that the pipelined unit reproduces
-- gdn_recur's recipe.  That is a transcription check, and gdn_recur_pipe --
-- NOT gdn_recur -- is the unit gdn_block instantiates and llama_top ships.  A
-- shared error in the recipe was therefore invisible in the shipping unit,
-- which is exactly the class that let the l2norm recipe collapse survive 55
-- passing cases (docs/debugging/2026-08-25_l2norm-recipe-collapse.md).
-- gdn_recur asserts its own oracle accuracy; the unit that ships did not.
-- Do not reinstate the discard.
--
-- Section 3.1's 589,824-cycle sweep assumes one column every
-- NB = DIM/LANES cycles; gdn_recur measures 58 at LANES = 32 against an NB of
-- 4.  This testbench reports what the pipelined unit actually sustains, so the
-- figure is measured rather than argued.
--
-- Columns are driven back-to-back within a head group.  k_n and q_s change
-- between head groups, and engines B and C are still working on the previous
-- head's columns when the next head's first column is issued, so the driver
-- DRAINS the pipeline between groups.  That drain is real: in the shipped
-- design a head is 128 columns, so it is a once-per-512-cycles cost, but it is
-- not free and it is measured separately below rather than folded into the II.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_recur_pipe is
  generic(DIM   : positive := 128;
          LANES : positive := 32;
          SLOTS : positive := 16;
          -- Case count, checked against the vector file's own header so a
          -- mismatch is a loud assertion rather than a silent short run.
          NCASE : positive := 384;
          GRP   : positive := 8;      -- columns per head group in the vectors
          -- Flip together with VECS; a mismatch is a loud bit-exact failure.
          D_NORM : boolean := true;   -- ADOPTED 2026-08-26, matches the DUT
          TK0_ED : boolean := true;   -- ADOPTED 2026-08-26, matches the DUT
          EG0_ED : boolean := true;   -- ADOPTED 2026-08-26, matches the DUT
          -- Idle cycles inserted BETWEEN columns.  0 is the real case, one
          -- column every NB cycles.  A large value serialises the unit and
          -- isolates arithmetic bugs from overlap bugs.
          GAP   : natural := 0;
          -- ORACLE tolerances, in the SAME units and with the SAME values as
          -- tb_gdn_recur's, because the two units are required to be
          -- bit-identical and a different bound here would be a second
          -- standard for one recipe.  Measured, not guessed: see that file.
          --
          -- CORRECTED 2026-08-29 (TRACK B-SEED).  This file HAD TOL_S = 12.0
          -- and TOL_O = 1.0e-4 for a day after tb_gdn_recur was retuned away
          -- from them, so the comment above was false and this bench was the
          -- second standard it forbids.  MEASURED on the honest unit over 30
          -- generator seeds, this bench and tb_gdn_recur print the SAME two
          -- figures to every printed digit, and at 12.0 / 1.0e-4 this bench
          -- went red at 5 of those 30 seeds (17%): seeds 17, 99, 777777,
          -- 20260101 and 31415926.  The honest state figure ranges 2.68 to
          -- 32.12 LSB and the honest output figure 1.01e-05 to 2.20e-04.
          --
          -- TOL_S is 48.0, which is 1.5x the 30-seed MAXIMUM of 32.12 rather
          -- than 1.5x the 52-seed maximum of 15.43 that set the former 24.0.
          -- Two independent sweeps at 52 and 30 seeds therefore disagree by
          -- 2.1x on the maximum of this statistic: its tail is heavy and a
          -- max-only bound on it is worth very little.  That is why the two
          -- COUNTS below matter more than TOL_S does.
          TOL_S : real := 48.0;      -- state mantissa, LSB of the 2^-se_new grid
          TOL_O : real := 1.2e-3;    -- output dot, relative to the term norm
          -- Ported from tb_gdn_recur 2026-08-29.  This bench had NO count and
          -- NO floor, which made its oracle gate strictly WEAKER than
          -- tb_gdn_recur's on the same vectors: MEASURED, mutations B3 and B6
          -- of sim/mutate_gdn_recur.sh reach only 9.27 and 10.45 state LSB
          -- and are caught by the count alone, so this bench could not see
          -- them at ANY honest value of TOL_S.  30-seed maxima 44 and 3.
          N_GT1_MAX : natural := 66;
          N_GT4_MAX : natural := 12;
          -- Floor on the columns the oracle check actually ran on, so an
          -- emptied check is loud instead of reporting 0.0000 and passing.
          -- 30-seed minimum 271.
          N_MIN     : natural := 240;
          VECS  : string   := "gdn_recur_vec.txt");
end entity;

architecture sim of tb_gdn_recur_pipe is
  constant NB : integer := DIM / LANES;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal eg, beta : unsigned(15 downto 0) := (others => '0');
  signal k_n, q_s : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal s_valid, s_first : std_logic := '0';
  signal s_data : std_logic_vector(LANES*16-1 downto 0) := (others => '0');
  signal c_tk0 : std_logic := '0';
  signal c_hsel : std_logic := '0';
  signal kq_we  : std_logic := '0';
  signal kq_wsel : std_logic := '0';
  signal c_se_j, c_e_v : signed(7 downto 0) := (others => '0');
  signal c_v_j : signed(15 downto 0) := (others => '0');
  signal o_valid, o_last, o_res_valid, o_err_se : std_logic;
  signal o_data : std_logic_vector(LANES*16-1 downto 0);
  signal o_se_new, o_e_o : signed(7 downto 0);
  signal o_acc : signed(39 downto 0);

  signal tick : integer := 0;
  signal loaded : boolean := false;

  type i_arr is array (natural range <>) of integer;
  type r_arr is array (natural range <>) of real;
  type col_rec is record
    phys, tk0, se_j, e_v, v_j, eg, beta, se_new, e_o, gid, err : integer;
    oacc : real;
    -- the oracle's output dot, and the sum of |term| that is the scale it
    -- lives on.  Normalising by |sum| is not a measurement here: it is a
    -- 128-term signed sum that cancels heavily.
    orr, onorm : real;
  end record;
  type col_arr is array (natural range <>) of col_rec;
  type big_arr is array (natural range <>) of i_arr(0 to DIM-1);
  type rbig_arr is array (natural range <>) of r_arr(0 to DIM-1);

  shared variable v_col  : col_arr(0 to NCASE-1);
  shared variable v_sm   : big_arr(0 to NCASE-1);
  shared variable v_kn   : big_arr(0 to NCASE-1);
  shared variable v_qs   : big_arr(0 to NCASE-1);
  shared variable v_snew : big_arr(0 to NCASE-1);
  -- the ORACLE's state vector, in real arithmetic on the 2^0 scale
  shared variable v_u    : rbig_arr(0 to NCASE-1);
  -- what the DUT actually emitted, kept per column so the accuracy check can
  -- be done against the DUT's own bits rather than against v_snew.  Checking
  -- the C model's output for accuracy and calling that a DUT result is the
  -- same substitution this file exists to stop making.
  shared variable v_got  : big_arr(0 to NCASE-1);

  shared variable nfail  : integer := 0;
  shared variable ncheck : integer := 0;
  shared variable last_last : integer := -1;
  shared variable ii_min, ii_max : integer := 0;
  -- Worst gap ACROSS a head boundary, kept separate from ii_max because it is
  -- the quantity the double buffer exists to remove.  ii_max deliberately
  -- filters gaps >= 100 so that the within-group number stays meaningful; this
  -- one filters nothing.
  shared variable ii_head : integer := 0;

  -- accuracy accounting (check 2)
  shared variable ntol   : integer := 0;   -- columns outside an oracle bound
  shared variable nphys  : integer := 0;   -- columns the oracle check applied to
  shared variable n_odeg : integer := 0;   -- columns whose oracle dot is identically 0
  shared variable worst_s, worst_o : real := 0.0;
  shared variable worst_o_on : real := 0.0;
  shared variable worst_o_c  : integer := -1;
  shared variable worst_s0, worst_s1 : real := 0.0;   -- tk = 0 / steady state
  -- Per-COLUMN worst element, and the counts built from it.  A max over the
  -- whole file is blind to a mutation that moves the BULK of the distribution
  -- without moving its worst case; these are what catch B3 and B6.
  shared variable n_gt1, n_gt4 : integer := 0;

  function to_real_s(v : signed) return real is
    variable m : unsigned(v'length-1 downto 0);
    variable r : real := 0.0;
  begin
    if v(v'high) = '1' then m := unsigned(-v); else m := unsigned(v); end if;
    for i in m'high downto 0 loop
      r := r * 2.0;
      if m(i) = '1' then r := r + 1.0; end if;
    end loop;
    if v(v'high) = '1' then return -r; else return r; end if;
  end function;
  -- The clock is GUARDED.  Unguarded, it keeps toggling after the stimulus
  -- process reaches its final `wait;`, so the simulation never ends: the test
  -- reports PASS and then spins at 100% CPU forever.  One such run was found
  -- alive after 4h58m.  It is invisible when output is piped through `tail`,
  -- because the report has already been printed by then.
  signal running : boolean := true;

begin
  clk <= not clk after 5 ns when running else '0';
  tickp : process(clk) begin
    if rising_edge(clk) then tick <= tick + 1; end if;
  end process;

  dut : entity work.gdn_recur_pipe
    generic map(DIM => DIM, LANES => LANES, SLOTS => SLOTS, D_NORM => D_NORM,
                TK0_ED => TK0_ED, EG0_ED => EG0_ED)
    port map(clk => clk, rst => rst,
             kq_we => kq_we, kq_wsel => kq_wsel,
             eg => eg, beta => beta,
             k_n => k_n, q_s => q_s,
             s_valid => s_valid, s_first => s_first, s_data => s_data,
             c_tk0 => c_tk0, c_hsel => c_hsel,
             c_se_j => c_se_j, c_e_v => c_e_v, c_v_j => c_v_j,
             o_valid => o_valid, o_last => o_last, o_data => o_data,
             o_se_new => o_se_new, o_acc => o_acc, o_e_o => o_e_o,
             o_res_valid => o_res_valid, o_err_se => o_err_se);

  load : process
    file fh : text; variable ln : line; variable iv : integer; variable rv : real;
    variable nc, dv : integer;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, dv);
    assert nc = NCASE and dv = DIM report "vector file shape" severity failure;
    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv); v_col(c).phys := iv;
      read(ln, iv); v_col(c).tk0 := iv;
      read(ln, iv); v_col(c).se_j := iv;
      read(ln, iv); v_col(c).e_v := iv;
      read(ln, iv); v_col(c).eg := iv;
      read(ln, iv); v_col(c).beta := iv;
      read(ln, iv); v_col(c).v_j := iv;
      read(ln, iv); v_col(c).gid := iv;
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, iv); v_sm(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, iv); v_kn(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, iv); v_qs(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, iv); v_snew(c)(i) := iv; end loop;
      readline(fh, ln);
      read(ln, iv); v_col(c).se_new := iv;
      read(ln, rv); v_col(c).oacc := rv;
      read(ln, iv); v_col(c).e_o := iv;
      read(ln, iv); v_col(c).err := iv;
      -- The ORACLE columns.  These were read and DISCARDED until 2026-08-28;
      -- see the note at the top of this file.
      readline(fh, ln); for i in 0 to DIM-1 loop read(ln, rv); v_u(c)(i) := rv; end loop;
      readline(fh, ln);
      read(ln, rv); v_col(c).orr := rv;
      read(ln, rv); v_col(c).onorm := rv;
    end loop;
    file_close(fh);
    loaded <= true;
    wait;
  end process;

  drive : process
    variable base, c : integer;
    -- bank alternates per head; prev_end / prev2_end are the column counts
    -- through the previous head and the one before it, which is the head that
    -- last used the bank about to be overwritten.
    variable bank : std_logic := '0';
    variable prev_end, prev2_end : integer := 0;
    -- Cycles actually spent waiting for a bank to free, which is what the old
    -- unconditional 200-cycle drain has been replaced by.  Reported as a total
    -- and as a worst case, split by whether the head that last used the bank
    -- was long enough to cover the pipe (DC + 2*NB cycles ~ 15 columns at
    -- II = NB).  Production heads are 128 columns and always are.
    variable stall, stall_tot, stall_max, stall_max_long : integer := 0;
    variable nhead : integer := 0;
    variable prev_len : integer := 0;
  begin
    wait until loaded;
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);

    c := 0;
    while c < NCASE loop
      -- a head runs until the group id changes; heads are 8 columns in the
      -- mixed set and 128 in the long one, and the driver must not assume
      base := c;
      -- The unit double-buffers k_n/q_s/eg/beta, so this head loads into the
      -- bank the PREVIOUS head is not using and issue never has to stop.  The
      -- old version of this loop drained 200 cycles here, which is precisely
      -- the 11.7% the buffer removes.
      --
      -- What still has to be waited for: the head that used THIS bank two heads
      -- ago must have fully retired, or its columns finish against the new
      -- vectors.  With production 128-column heads the pipe (DC + NB ~ 56
      -- cycles) has always drained long before, so the wait is free; it only
      -- bites in this vector set, whose mixed heads are 8 columns.  The unit
      -- asserts the same invariant from the inside, so a testbench that got
      -- this wrong would fail loudly rather than produce wrong numbers -- which
      -- is the point, because the previous failure mode here was silent: only
      -- o_acc wrong, only on the last column(s) of each head, state perfect,
      -- because the state does not depend on q_s at all.
      stall := 0;
      while ncheck < prev2_end loop
        wait until rising_edge(clk); stall := stall + 1;
      end loop;
      stall_tot := stall_tot + stall;
      if stall > stall_max then stall_max := stall; end if;
      if prev_len >= 16 and stall > stall_max_long then stall_max_long := stall; end if;
      kq_wsel <= bank;
      eg   <= to_unsigned(v_col(base).eg, 16);
      beta <= to_unsigned(v_col(base).beta, 16);
      for i in 0 to DIM-1 loop
        k_n((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_kn(base)(i), 16));
        q_s((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_qs(base)(i), 16));
      end loop;
      wait until rising_edge(clk);
      kq_we <= '1';
      wait until rising_edge(clk);
      kq_we <= '0';

      while c < NCASE and v_col(c).gid = v_col(base).gid loop
        for gi in 0 to NB-1 loop
          s_valid <= '1';
          if gi = 0 then
            s_first <= '1';
            c_tk0   <= '1' when v_col(c).tk0 = 1 else '0';
            c_hsel  <= bank;
            c_se_j  <= to_signed(v_col(c).se_j, 8);
            c_e_v   <= to_signed(v_col(c).e_v, 8);
            c_v_j   <= to_signed(v_col(c).v_j, 16);
          else
            s_first <= '0';
          end if;
          for k in 0 to LANES-1 loop
            s_data((k+1)*16-1 downto k*16)
              <= std_logic_vector(to_signed(v_sm(c)(gi*LANES + k), 16));
          end loop;
          wait until rising_edge(clk);
        end loop;
        if GAP > 0 then
          s_valid <= '0'; s_first <= '0';
          for d in 0 to GAP-1 loop wait until rising_edge(clk); end loop;
        end if;
        c := c + 1;
      end loop;
      s_valid <= '0'; s_first <= '0';
      nhead := nhead + 1;
      prev_len := c - prev_end;
      prev2_end := prev_end; prev_end := c;
      bank := not bank;
    end loop;

    for d in 0 to 399 loop wait until rising_edge(clk); end loop;

    assert nfail = 0
      report "gdn_recur_pipe: " & integer'image(nfail) & " mismatch(es) in "
           & integer'image(ncheck) & " columns" severity error;
    assert ntol = 0
      report "gdn_recur_pipe: OUT OF TOLERANCE vs the double ORACLE in "
           & integer'image(ntol) & " of " & integer'image(nphys)
           & " physically realizable column(s)" severity error;
    -- The two COUNTS and the FLOOR, ported from tb_gdn_recur 2026-08-29.  The
    -- wording is copied so sim/mutate_gdn_recur.sh's markers match on either
    -- bench.  A count is not decoration here: B3 and B6 of that script move
    -- the worst case only 8.955 -> 9.270 and -> 10.452 while moving the count
    -- past 1 LSB 29 -> 199 and 29 -> 130.
    assert n_gt1 <= N_GT1_MAX
      report "gdn_recur_pipe: " & integer'image(n_gt1) & " physical columns "
           & "are past 1 state LSB, over the gate of "
           & integer'image(N_GT1_MAX) & ".  The worst case can be inside its "
           & "bound and the DISTRIBUTION still be wrong; that is what this "
           & "counts." severity error;
    assert n_gt4 <= N_GT4_MAX
      report "gdn_recur_pipe: " & integer'image(n_gt4) & " physical columns "
           & "are past 4 state LSB, over the gate of "
           & integer'image(N_GT4_MAX) severity error;
    -- Every bound above gets HAPPIER as columns leave the checked set, and
    -- they leave it silently (c_phys = 0, or exp_err = 1).
    assert nphys >= N_MIN
      report "gdn_recur_pipe: only " & integer'image(nphys) & " columns "
           & "reached the oracle check, under the floor of "
           & integer'image(N_MIN) & ".  The accuracy figures above are "
           & "measuring almost nothing." severity error;
    report "gdn_recur_pipe: columns past 1 LSB " & integer'image(n_gt1)
         & " (gate " & integer'image(N_GT1_MAX) & "), past 4 LSB "
         & integer'image(n_gt4) & " (gate " & integer'image(N_GT4_MAX)
         & "), columns checked " & integer'image(nphys) & " (floor "
         & integer'image(N_MIN) & ")" severity note;
    if nfail = 0 and ntol = 0 and n_gt1 <= N_GT1_MAX
       and n_gt4 <= N_GT4_MAX and nphys >= N_MIN then
      report "gdn_recur_pipe: within the oracle bounds on all "
           & integer'image(nphys) & " physically realizable columns -- worst "
           & real'image(worst_s) & " state LSB (TOL_S " & real'image(TOL_S)
           & ") and " & real'image(worst_o) & " of the output dot's term norm "
           & "(TOL_O " & real'image(TOL_O) & ") [worst dot at column "
           & integer'image(worst_o_c) & ", term norm " & real'image(worst_o_on)
           & "; " & integer'image(n_odeg) & " columns had an identically-zero "
           & "oracle dot and were skipped for that check].  State error splits "
           & real'image(worst_s1) & " LSB steady state / " & real'image(worst_s0)
           & " LSB at tk = 0." severity note;
    end if;
    -- The success sentence carries sim/regress.sh's PASS_RE phrase
    -- ("bit-identical"), so it is gated on EVERY verdict and not on
    -- bit-exactness alone.  FAIL_RE does win over PASS_RE, so this is belt
    -- and braces rather than the only defence, but a bench that prints a
    -- success marker on a red run is one grep-pattern change from lying.
    if nfail = 0 and ntol = 0 and n_gt1 <= N_GT1_MAX
       and n_gt4 <= N_GT4_MAX and nphys >= N_MIN then
      report "gdn_recur_pipe: bit-identical to the reference on all "
           & integer'image(ncheck) & " columns; issue interval measured "
           & integer'image(ii_min) & " cycles (NB = " & integer'image(NB)
           & "), worst gap within a head group " & integer'image(ii_max)
           & ", worst gap ACROSS a head boundary " & integer'image(ii_head)
           severity note;
      report "gdn_recur_pipe: bank-free wait totals " & integer'image(stall_tot)
           & " cycles over " & integer'image(nhead) & " head boundaries, worst "
           & integer'image(stall_max) & "; worst after a head of >= 16 columns "
           & integer'image(stall_max_long)
           & " (the old unconditional drain was 200 per boundary)"
           severity note;
    end if;
    running <= false;
    wait;
  end process;

  -- collect the output stream and the scalar results, both in column order
  collect : process(clk)
    variable ncol_d, ncol_r, gcnt : integer := 0;
    variable got : i_arr(0 to DIM-1);
    variable bad, firstbad : integer;
    variable gsr, e_s, gs_val, e_o_rel : real;
    variable wcol : real;   -- worst element of THIS column, for the counts
  begin
    if rising_edge(clk) and rst = '0' then
      if o_valid = '1' then
        for k in 0 to LANES-1 loop
          got(gcnt*LANES + k) := to_integer(signed(o_data((k+1)*16-1 downto k*16)));
        end loop;
        if o_last = '1' then
          bad := 0; firstbad := -1;
          for i in 0 to DIM-1 loop
            if got(i) /= v_snew(ncol_d)(i) then
              bad := bad + 1;
              if firstbad < 0 then firstbad := i; end if;
            end if;
          end loop;
          for i in 0 to DIM-1 loop v_got(ncol_d)(i) := got(i); end loop;
          if bad /= 0 then
            report "column " & integer'image(ncol_d) & ": state differs in "
                 & integer'image(bad) & " element(s), first at i="
                 & integer'image(firstbad) & " (group " & integer'image(firstbad/LANES)
                 & ") got " & integer'image(got(firstbad)) & " want "
                 & integer'image(v_snew(ncol_d)(firstbad)) severity error;
            nfail := nfail + 1;
          end if;
          -- Issue interval: spacing of consecutive column completions.  The
          -- within-group max keeps its < 100 filter so it stays comparable with
          -- the pre-double-buffer runs; the head-boundary gap is now measured
          -- SEPARATELY and unfiltered, because that gap is the whole point of
          -- the buffer and hiding it behind a filter is how it went unnoticed.
          if last_last >= 0 then
            if ii_min = 0 or (tick - last_last) < ii_min then ii_min := tick - last_last; end if;
            if ncol_d > 0 and v_col(ncol_d).gid /= v_col(ncol_d-1).gid then
              if (tick - last_last) > ii_head then ii_head := tick - last_last; end if;
            elsif (tick - last_last) > ii_max and (tick - last_last) < 100 then
              ii_max := tick - last_last;
            end if;
          end if;
          last_last := tick;
          ncol_d := ncol_d + 1;
          gcnt := 0;
        else
          gcnt := gcnt + 1;
        end if;
      end if;

      if o_res_valid = '1' then
        bad := 0;
        -- 2.1.6: an out-of-int8 exponent must be REPORTED; the value is then
        -- meaningless by definition, so the check is that err_se fires.
        if v_col(ncol_r).err = 1 then
          if o_err_se /= '1' then bad := bad + 1; end if;
        else
          if to_integer(o_se_new) /= v_col(ncol_r).se_new then bad := bad + 1; end if;
          if to_integer(o_e_o)    /= v_col(ncol_r).e_o    then bad := bad + 1; end if;
        end if;
        if to_real_s(o_acc)     /= v_col(ncol_r).oacc   then bad := bad + 1; end if;
        if bad /= 0 then
          report "column " & integer'image(ncol_r) & ": scalars differ  se_new "
               & integer'image(to_integer(o_se_new)) & "/" & integer'image(v_col(ncol_r).se_new)
               & "  e_o " & integer'image(to_integer(o_e_o)) & "/" & integer'image(v_col(ncol_r).e_o)
               & "  oacc " & real'image(to_real_s(o_acc)) & "/" & real'image(v_col(ncol_r).oacc)
               severity error;
          nfail := nfail + 1;
        end if;

        -- ---- check 2: REAL-VALUED, against the double ORACLE -------------
        -- Same standard, same bounds and same exclusions as tb_gdn_recur:
        --   * PHYS columns only.  The adversarial group carries inputs this
        --     recurrence cannot receive (k that is not a unit vector above
        --     all), and holding those to an accuracy bound would measure the
        --     recipe against inputs it was never designed for.  They are
        --     still checked bit-exactly above, which is what corners are for.
        --   * err = 1 columns excluded: by 2.1.6 se_new is meaningless there,
        --     and the oracle comparison scales by 2^se_new.  The unit is
        --     still required to REPORT them, checked above.
        -- The scalars land AFTER the data stream, so the state for this
        -- column is already in v_got.  Asserted rather than assumed, because
        -- if that ordering ever changed this check would silently grade the
        -- previous column.
        if v_col(ncol_r).phys = 1 and v_col(ncol_r).err = 0 then
          assert ncol_d > ncol_r
            report "column " & integer'image(ncol_r)
                 & ": scalars arrived BEFORE the state stream -- the oracle "
                 & "check would grade the wrong column" severity failure;
          nphys := nphys + 1;
          bad := 0;
          wcol := 0.0;
          for i in 0 to DIM-1 loop
            gsr := v_u(ncol_r)(i) * 2.0 ** real(to_integer(o_se_new));
            e_s := abs(real(v_got(ncol_r)(i)) - gsr);
            if e_s > wcol then wcol := e_s; end if;
            if e_s > worst_s then worst_s := e_s; end if;
            if v_col(ncol_r).tk0 = 1 then
              if e_s > worst_s0 then worst_s0 := e_s; end if;
            else
              if e_s > worst_s1 then worst_s1 := e_s; end if;
            end if;
            if e_s > TOL_S then bad := bad + 1; end if;
          end loop;
          if wcol > 1.0 then n_gt1 := n_gt1 + 1; end if;
          if wcol > 4.0 then n_gt4 := n_gt4 + 1; end if;
          -- The output dot is normalised by the sum of |terms|, NOT by |sum|:
          -- it is a 128-term signed sum that cancels heavily, so dividing by
          -- the sum reports an enormous error wherever the sum lands near
          -- zero while every term is accurate.
          gs_val := to_real_s(o_acc) * 2.0 ** real(-to_integer(o_e_o));
          if v_col(ncol_r).onorm > 1.0e-300 then
            e_o_rel := abs(gs_val - v_col(ncol_r).orr) / v_col(ncol_r).onorm;
          else
            e_o_rel := 0.0;
            n_odeg  := n_odeg + 1;
          end if;
          if e_o_rel > worst_o then
            worst_o := e_o_rel; worst_o_on := v_col(ncol_r).onorm;
            worst_o_c := ncol_r;
          end if;
          if bad /= 0 or e_o_rel > TOL_O then
            report "column " & integer'image(ncol_r)
                 & ": OUT OF TOLERANCE vs ORACLE in " & integer'image(bad)
                 & " state element(s), o rel err " & real'image(e_o_rel)
                 severity error;
            ntol := ntol + 1;
          end if;
        end if;

        ncol_r := ncol_r + 1;
        ncheck := ncol_r;
      end if;
    end if;
  end process;
end architecture;
