-- sim/tb_attn_rope.vhd
-- Bit-exact testbench for rtl/attn_rope.vhd against ref/attn_rope_vec.c.
--
-- THE ORACLE IS INDEPENDENT.  The golden file carries the C reference's
-- OUTPUT, and that reference was written from cos/sin at the true real angle
-- and checked by six oracles that share no fixed-point machinery with the RTL:
-- a DERIVED per-component bound, NORM PRESERVATION from the orthogonality of a
-- rotation, an exact equality over the unrotated tail, an exact equality at
-- pos = 0, an INEQUALITY separating the rounding mode from a floor, and both
-- saturation rails as reachable values.  It was mutation-tested BEFORE this
-- DUT existed: 13 of 13 killed, no survivors.
--
-- The twiddle port is driven FROM THE GOLDEN FILE, not from attn_twiddle.
-- That is deliberate: it keeps the two units independent, so a defect in
-- either one cannot mask a defect in the other, and it lets this file inject
-- twiddle timing (TW_GAP) that attn_twiddle would never naturally produce.
--
-- WHAT IS CHECKED, AND WHY EACH ONE IS SEPARATE FROM THE OTHERS.
--   1  every y element bit-exact against the golden
--   2  y arrives in EXACT dim order 0 .. HEAD_DIM-1, checked as its own
--      counter rather than by trusting y_index.  The three phases emit from
--      three different sources -- the rotate pipeline, buf2, and the memory --
--      so an ordering defect is a real and reachable failure mode, and a
--      checker that indexed the golden BY y_index would pass through it
--      silently.
--   3  y_index agrees with that counter, which is what makes check 2 a check
--      of the DUT rather than of the testbench
--   4  the ROTATED region and the PASS-THROUGH region tallied separately, so
--      a boundary off-by-one cannot be absorbed by the other region's count
--   5  hdr_valid stands BEFORE the first element (the ordering rule)
--   6  y_exp equals x_exp, since the rotation preserves the block exponent
--   7  a held valid does not change its data or its index
--   8  rope_sat matches the golden's saturation count, as a GOLDEN and not as
--      a flag hoped to stay clear
--   9  err stays low, and cfg_taken is exactly one cycle per job
--  10  done is HELD, not pulsed
--
-- COVERAGE ASSERTIONS FAIL, they do not warn -- and each one names a check it
-- would make vacuous.  Added after the coordinator's 2026-08-27 note that a
-- guard whose subject is a constant is a comment: the D owner's ordering guard
-- passed against a deliberately broken DUT because its three fields were
-- identically zero in all 491 descriptors.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_attn_rope is
  generic(
    VEC     : string  := "attn_rope_vec.txt";
    -- Cycles of gap the twiddle producer inserts between pairs.  0 = a
    -- producer that never stalls, which is the DEGENERATE case and is NOT
    -- strictly weaker: a stream offered every cycle is the only shape that
    -- exercises back-to-back acceptance.
    TW_GAP  : natural := 3;
    -- Cycles the consumer holds y_ready low after each valid.  0 = tied high.
    ACK_LAG : natural := 4
  );
end entity;

architecture tb of tb_attn_rope is

  constant HEAD_DIM : integer := 96;
  constant N_ROT    : integer := 64;
  constant NPAIR    : integer := N_ROT/2;
  constant MANT_W   : integer := 16;
  constant AW       : integer := clog2(HEAD_DIM);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal halt : boolean := false;

  signal start     : std_logic := '0';
  signal x_exp     : signed(7 downto 0) := (others => '0');
  signal cfg_taken : std_logic;
  signal busy      : std_logic;

  signal x_raddr : std_logic_vector(AW-1 downto 0);
  signal x_re    : std_logic;
  signal x_rdata : std_logic_vector(MANT_W-1 downto 0);

  signal tw_valid : std_logic := '0';
  signal tw_cos   : signed(MANT_W-1 downto 0) := (others => '0');
  signal tw_sin   : signed(MANT_W-1 downto 0) := (others => '0');
  signal tw_ready : std_logic;

  signal hdr_valid : std_logic;
  signal y_exp     : signed(7 downto 0);
  signal y_valid   : std_logic;
  signal y_data    : signed(MANT_W-1 downto 0);
  signal y_index   : unsigned(AW-1 downto 0);
  signal y_ready   : std_logic := '1';

  signal done       : std_logic;
  signal done_ack   : std_logic;
  signal done_ack_p : std_logic := '0';
  signal rope_sat : std_logic;
  signal err      : std_logic;

  -- the head-vector scratch, written by the testbench, read by the DUT
  type mem_t is array (0 to HEAD_DIM-1) of signed(MANT_W-1 downto 0);
  signal xmem : mem_t := (others => (others => '0'));
  signal xrd  : signed(MANT_W-1 downto 0) := (others => '0');

  -- the golden for the case in flight
  signal gold  : mem_t := (others => (others => '0'));
  signal gsat  : integer := 0;
  signal gexp  : integer := 0;
  signal case_live : boolean := false;

  -- tallies
  signal n_case : integer := 0;
  signal n_elem : integer := 0;
  signal n_rot_chk  : integer := 0;
  signal n_pass_chk : integer := 0;
  signal errs   : integer := 0;
  signal mon_err : integer := 0;
  signal ord_err : integer := 0;
  signal hld_err : integer := 0;
  signal n_tk    : integer := 0;
  signal tk_d    : std_logic := '0';

  -- coverage
  signal cov_sat, cov_nosat, cov_pos0 : integer := 0;
  signal cov_tail_nz, cov_hi, cov_lo  : integer := 0;
  signal cov_stall, cov_b2b, cov_twstall : integer := 0;

begin

  clk <= not clk after 5 ns when not halt else '0';

  -- Synchronous read with a real enable, so the DUT's x_re freeze is a REAL
  -- freeze.  A memory that ignored x_re would make attn_kv_quant's M6 -- the
  -- address held but the memory left enabled -- an equivalent mutant here too.
  process(clk) begin
    if rising_edge(clk) then
      if x_re = '1' then
        xrd <= xmem(to_integer(unsigned(x_raddr)));
      end if;
    end if;
  end process;
  x_rdata <= std_logic_vector(xrd);

  -- THE COMPLETION HANDSHAKE, as a property.  See sim/hsk_chk.vhd's header.
  -- P25 of sim/mutate_attn_rope.sh is a member of the same class that made an
  -- explicit `done_r` clear inside the ack branch an ABORT in five other
  -- harnesses and a detection in none: it was seen only as a deadlock in the
  -- degenerate configuration.
  -- DEADLINE = 12000.  MEASURED with hsk_chk's NOTE_MAX => true: the worst
  -- start-to-done latency on the clean design is 1453 cycles (configuration C
  -- of sim/mutate_attn_rope.sh, TW_GAP = 11; 717 in A, 144 in B); 12000 is
  -- 8.3x that.  Do not "tighten" it: this clause is a timeout, so its only job
  -- is to be finite.
  hsk : entity work.hsk_chk
    generic map ( NAME => "attn_rope", DEADLINE => 12000 )
    port map ( clk => clk, rst => rst, start_ev => cfg_taken,
               done => done, ack => done_ack );

  dut : entity work.attn_rope
    generic map(HEAD_DIM => HEAD_DIM, N_ROT => N_ROT, MANT_W => MANT_W,
                Q => 15, EXP_W => 8, STRICT_PRODUCER => true)
    port map(clk => clk, rst => rst,
             start => start, x_exp => x_exp, cfg_taken => cfg_taken,
             busy => busy,
             x_raddr => x_raddr, x_re => x_re, x_rdata => x_rdata,
             tw_valid => tw_valid, tw_cos => tw_cos, tw_sin => tw_sin,
             tw_ready => tw_ready,
             hdr_valid => hdr_valid, y_exp => y_exp,
             y_valid => y_valid, y_data => y_data, y_index => y_index,
             y_ready => y_ready,
             done => done, done_ack => done_ack,
             rope_sat => rope_sat, err => err);

  -- =====================================================================
  -- The consumer.  ACK_LAG = 0 ties y_ready high, which is the shape a
  -- non-stalling consumer presents and the only one that can tell a held
  -- valid from a pulsed one apart by NOT distinguishing them -- hence the
  -- separate hold monitor below, which runs in every configuration.
  -- =====================================================================
  gen_ack : if ACK_LAG > 0 generate
    process(clk)
      variable w : integer := 0;
    begin
      if rising_edge(clk) then
        if rst = '1' then
          y_ready <= '0'; w := 0;
        elsif y_valid = '1' and y_ready = '0' then
          if w >= ACK_LAG then y_ready <= '1'; w := 0;
          else w := w + 1; end if;
        else
          y_ready <= '0'; w := 0;
        end if;
      end if;
    end process;
  end generate;
  gen_noack : if ACK_LAG = 0 generate
    y_ready <= '1';
  end generate;

  -- The DEGENERATE configuration ties EVERY ack high, done_ack included.
  -- done_ack's port DEFAULT is '1', so a consumer that never stalls is exactly
  -- what this unit will meet in the field -- and it is the only shape that can
  -- catch an explicit `done_r <= '0'` inside the ack branch, which is a LATER
  -- assignment and therefore wins over the `done_r <= '1'` above it, deleting
  -- the completion outright.  With a PULSED ack that same mutation merely
  -- shortens done by one cycle and survives.  Caught here as P25.
  gen_dack : if ACK_LAG > 0 generate
    done_ack <= done_ack_p;
  end generate;
  gen_dack_hi : if ACK_LAG = 0 generate
    done_ack <= '1';
  end generate;

  -- =====================================================================
  -- Monitors.  Each drives its OWN error counter: two processes driving one
  -- unresolved signal is an elaboration failure whose message names no file
  -- or line, which cost a run on tb_attn_softmax.
  -- =====================================================================

  -- HOLD.  A valid that is not accepted must present the same data and the
  -- same index next cycle.  Runs in every configuration, including the one
  -- that can never exercise it, so the check is present rather than
  -- conditional.
  process(clk)
    variable pv : std_logic := '0';
    variable pd : signed(MANT_W-1 downto 0) := (others => '0');
    variable pi : unsigned(AW-1 downto 0) := (others => '0');
    variable pr : std_logic := '0';
  begin
    if rising_edge(clk) then
      if rst = '0' then
        if pv = '1' and pr = '0' then
          if y_valid /= '1' then
            report "HOLD: valid dropped without an accept" severity error;
            hld_err <= hld_err + 1;
          elsif y_data /= pd or y_index /= pi then
            report "HOLD: held data or index changed" severity error;
            hld_err <= hld_err + 1;
          end if;
          cov_stall <= cov_stall + 1;
        end if;
        if pv = '1' and pr = '1' and y_valid = '1' then
          cov_b2b <= cov_b2b + 1;
        end if;
      end if;
      pv := y_valid; pd := y_data; pi := y_index; pr := y_ready;
    end if;
  end process;

  -- ORDERING.  Three things, and they are different: the header must stand
  -- before the first element (subsystem B's gdn_conv defect), cfg_taken must
  -- fire exactly once per job (RULE 2), and err must stay low.
  --
  -- cfg_taken is COUNTED and compared at the end rather than policed against
  -- the start instant cycle by cycle.  It is a registered output, so it lands
  -- the cycle AFTER start; a per-job window that reset itself on start raced
  -- its own increment and reported a defect that was entirely the monitor's.
  -- Total = ncase is the invariant that actually means "once per job", and it
  -- catches both a missing pulse and a duplicated one.
  process(clk) begin
    if rising_edge(clk) then
      if rst = '0' then
        if y_valid = '1' and hdr_valid = '0' then
          report "ORDER: an element is offered while hdr_valid is low"
            severity error;
          ord_err <= ord_err + 1;
        end if;
        if cfg_taken = '1' then
          n_tk <= n_tk + 1;
          -- It must be a PULSE: two adjacent cycles is not one latch instant.
          if tk_d = '1' then
            report "ORDER: cfg_taken held for more than one cycle"
              severity error;
            ord_err <= ord_err + 1;
          end if;
        end if;
        tk_d <= cfg_taken;
        if err = '1' then
          report "ERR: the DUT raised err" severity error;
          ord_err <= ord_err + 1;
        end if;
      end if;
    end if;
  end process;

  -- ELEMENT CHECK.  Order is tracked with the testbench's OWN counter and
  -- y_index is compared against it, rather than the golden being indexed by
  -- y_index -- which would make any reordering invisible.
  process(clk)
    variable k : integer := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        k := 0;
      elsif case_live and y_valid = '1' and y_ready = '1' then
        if to_integer(y_index) /= k then
          report "ORDER: y_index " & integer'image(to_integer(y_index))
               & " but element " & integer'image(k) & " was expected"
            severity error;
          mon_err <= mon_err + 1;
        end if;
        if y_data /= gold(k) then
          report "VALUE: case " & integer'image(n_case)
               & " dim " & integer'image(k)
               & " got " & integer'image(to_integer(y_data))
               & " want " & integer'image(to_integer(gold(k)))
            severity error;
          mon_err <= mon_err + 1;
        end if;
        if to_integer(y_exp) /= gexp then
          report "EXP: y_exp not preserved" severity error;
          mon_err <= mon_err + 1;
        end if;
        -- The two regions are tallied separately: a boundary off-by-one moves
        -- an element from one region to the other, and a single total would
        -- absorb it.
        if k < N_ROT then n_rot_chk <= n_rot_chk + 1;
        else              n_pass_chk <= n_pass_chk + 1; end if;
        n_elem <= n_elem + 1;
        k := k + 1;
        if k = HEAD_DIM then k := 0; end if;
      end if;
    end if;
  end process;

  -- =====================================================================
  -- The stimulus.
  -- =====================================================================
  process
    file     fh   : text;
    variable ln   : line;
    variable st   : file_open_status;
    variable ncase, hd, nr : integer;
    variable ci, pos_v, nsat : integer;
    variable v : integer;
    variable tcos, tsin : mem_t;
    variable tail_nz : integer;
    variable ndist : integer;
    variable first_v : integer;

    procedure cyc(n : integer) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;
  begin
    file_open(st, fh, VEC, read_mode);
    assert st = open_ok report "cannot open " & VEC severity failure;
    readline(fh, ln); read(ln, ncase); read(ln, hd); read(ln, nr);
    assert hd = HEAD_DIM and nr = N_ROT
      report "geometry mismatch between the golden and this testbench"
      severity failure;

    cyc(4); rst <= '0'; cyc(2);

    for c in 0 to ncase-1 loop
      readline(fh, ln); read(ln, ci); read(ln, pos_v); read(ln, nsat);

      -- input vector
      tail_nz := 0; ndist := 0; first_v := 0;
      readline(fh, ln);
      for i in 0 to HEAD_DIM-1 loop
        read(ln, v);
        xmem(i) <= to_signed(v, MANT_W);
        if i = 0 then first_v := v;
        elsif v /= first_v then ndist := 1; end if;
        if i >= N_ROT and v /= 0 then tail_nz := tail_nz + 1; end if;
      end loop;
      -- A CONSTANT input vector makes the pass-through check and the pairing
      -- check both vacuous: every pairing of equal values gives equal
      -- products.  This is the coordinator's constant-field warning applied to
      -- this generator's own stimulus, and it FAILS rather than warns.
      assert ndist = 1
        report "COVERAGE: case " & integer'image(c) & "'s input vector is "
             & "constant, so the pairing and pass-through checks are vacuous"
        severity failure;
      if tail_nz > 0 then cov_tail_nz <= cov_tail_nz + 1; end if;

      -- golden output
      readline(fh, ln);
      for i in 0 to HEAD_DIM-1 loop
        read(ln, v); gold(i) <= to_signed(v, MANT_W);
        if v = 32767  then cov_hi <= cov_hi + 1; end if;
        if v = -32768 then cov_lo <= cov_lo + 1; end if;
      end loop;

      -- the twiddle stream, taken from the golden so the two units stay
      -- independent
      readline(fh, ln);
      for j in 0 to NPAIR-1 loop read(ln, v); tcos(j) := to_signed(v, MANT_W); end loop;
      readline(fh, ln);
      for j in 0 to NPAIR-1 loop read(ln, v); tsin(j) := to_signed(v, MANT_W); end loop;

      gsat <= nsat;
      -- The exponent is arbitrary and DELIBERATELY varied: a constant x_exp
      -- would make the y_exp check a check of a constant.
      gexp <= (c mod 7) - 3;
      x_exp <= to_signed((c mod 7) - 3, 8);
      if nsat > 0 then cov_sat <= cov_sat + 1; else cov_nosat <= cov_nosat + 1; end if;
      if pos_v = 0 then cov_pos0 <= cov_pos0 + 1; end if;

      n_case <= c;
      cyc(1);
      start <= '1'; cyc(1); start <= '0';
      -- RULE 2 IS ONLY TESTABLE IF THE INPUT MOVES.  x_exp is latched at
      -- start, so the moment start falls it is poisoned with a value that is
      -- never any case's exponent.  Held constant for the whole job -- as the
      -- first version of this file did -- reading it LIVE and reading the
      -- LATCH are the same thing, and a mutation that swapped one for the
      -- other survived every configuration.  That is the coordinator's
      -- constant-field warning in its exact form: a guard whose subject never
      -- changes is a comment.
      x_exp <= to_signed(-64, 8);
      case_live <= true;

      -- feed the NPAIR twiddle pairs
      for j in 0 to NPAIR-1 loop
        if TW_GAP > 0 then
          tw_valid <= '0';
          for g in 1 to TW_GAP loop
            wait until rising_edge(clk);
            if tw_ready = '1' then cov_twstall <= cov_twstall + 1; end if;
          end loop;
        end if;
        tw_cos <= tcos(j); tw_sin <= tsin(j); tw_valid <= '1';
        loop
          wait until rising_edge(clk);
          exit when tw_ready = '1';
        end loop;
        tw_valid <= '0';
      end loop;
      tw_valid <= '0';

      -- wait for completion
      while done = '0' loop wait until rising_edge(clk); end loop;
      -- RULE 1: done is HELD.  Sit on it for several cycles with the ack low
      -- and confirm it does not drop; a pulsed done would vanish here.
      -- Only meaningful where the ack is PULSED: the degenerate configuration
      -- ties done_ack high, so completion is consumed the instant it is
      -- offered and there is no unacked window to hold.  That configuration
      -- earns its keep on P25 instead, which is the mutation only it can see.
      if ACK_LAG > 0 then
        for i in 1 to 5 loop
          wait until rising_edge(clk);
          if done /= '1' then
            report "DONE: not held while unacked" severity error;
            errs <= errs + 1;
          end if;
        end loop;
      end if;

      if (rope_sat = '1') /= (nsat > 0) then
        report "SAT: case " & integer'image(c) & " rope_sat "
             & std_logic'image(rope_sat) & " but the golden saturates "
             & integer'image(nsat) & " times"
          severity error;
        errs <= errs + 1;
      end if;

      case_live <= false;
      done_ack_p <= '1'; cyc(1); done_ack_p <= '0';
      while busy = '1' loop wait until rising_edge(clk); end loop;
      cyc(2);
    end loop;
    file_close(fh);

    -- ================= COVERAGE.  THESE FAIL, THEY DO NOT WARN ==========
    assert n_elem = ncase * HEAD_DIM
      report "COVERAGE: " & integer'image(n_elem) & " elements accepted, "
           & integer'image(ncase*HEAD_DIM) & " expected -- the DUT dropped or "
           & "duplicated output" severity failure;
    assert n_rot_chk = ncase * N_ROT
      report "COVERAGE: the rotated region was checked "
           & integer'image(n_rot_chk) & " times, not "
           & integer'image(ncase*N_ROT) severity failure;
    assert n_pass_chk = ncase * (HEAD_DIM - N_ROT)
      report "COVERAGE: the pass-through region was checked "
           & integer'image(n_pass_chk) & " times, not "
           & integer'image(ncase*(HEAD_DIM-N_ROT)) severity failure;
    assert cov_sat > 0
      report "COVERAGE: no case saturated, so rope_sat and the int16 rails "
           & "are unexercised" severity failure;
    assert cov_nosat > 0
      report "COVERAGE: every case saturated, so a DUT that saturated "
           & "unconditionally would pass" severity failure;
    assert cov_pos0 > 0
      report "COVERAGE: no pos = 0 case, so the near-identity rotation -- the "
           & "one shape that pins the pairing without any arithmetic -- is "
           & "unexercised" severity failure;
    assert cov_tail_nz > 0
      report "COVERAGE: every case's unrotated tail is all zero, so the "
           & "pass-through check is vacuous -- a DUT that emitted zeros for "
           & "dims N_ROT.. would pass" severity failure;
    assert n_tk = ncase
      report "COVERAGE: cfg_taken fired " & integer'image(n_tk) & " times for "
           & integer'image(ncase) & " jobs -- RULE 2 says the latch instant is "
           & "observable exactly once per job" severity failure;
    assert cov_hi > 0 and cov_lo > 0
      report "COVERAGE: only one saturation rail was reached ("
           & integer'image(cov_hi) & " high, " & integer'image(cov_lo)
           & " low)" severity failure;
    -- The stall and back-to-back counters are configuration-dependent by
    -- construction, so each is required only where it is reachable.  Asserting
    -- both unconditionally would make the degenerate configuration
    -- unrunnable, and that configuration is the one that catches a pulsed
    -- valid.
    if ACK_LAG > 0 then
      assert cov_stall > 0
        report "COVERAGE: ACK_LAG > 0 but the output never actually stalled"
        severity failure;
    else
      assert cov_b2b > 0
        report "COVERAGE: ACK_LAG = 0 but no back-to-back accept was observed"
        severity failure;
    end if;
    if TW_GAP > 0 then
      assert cov_twstall > 0
        report "COVERAGE: TW_GAP > 0 but tw_ready was never high while the "
             & "producer was idle, so the twiddle back-pressure path is "
             & "unexercised" severity failure;
    end if;

    if errs + mon_err + ord_err + hld_err = 0 then
      report "tb_attn_rope PASS: " & integer'image(ncase) & " head vectors, "
           & integer'image(n_elem) & " elements bit-exact ("
           & integer'image(n_rot_chk) & " rotated, "
           & integer'image(n_pass_chk) & " passed through); "
           & "saturating cases " & integer'image(cov_sat)
           & ", clean " & integer'image(cov_nosat)
           & ", pos=0 " & integer'image(cov_pos0)
           & "; stalls " & integer'image(cov_stall)
           & ", back-to-back " & integer'image(cov_b2b)
           & ", twiddle waits " & integer'image(cov_twstall)
        severity note;
    else
      report "tb_attn_rope FAIL: value " & integer'image(mon_err)
           & " order " & integer'image(ord_err)
           & " hold " & integer'image(hld_err)
           & " other " & integer'image(errs) severity failure;
    end if;
    halt <= true;
    wait;
  end process;

end architecture;
