-- sim/tb_swiglu_mem.vhd -- 2026-09-19.
--
-- THE IDENTITY BENCH FOR THE MEMORY-BACKED SwiGLU + PACK.
--
-- WHAT IS COMPARED.  The REFERENCE is the shipping FFN chain of
-- rtl/engine_shared.vhd, instantiated here exactly as it is wired there:
-- rtl/swiglu.vhd (flat N*16 ports, verified against ref/test_swiglu.c) writing
-- its Q12 int32 results one per cycle into a 32-bit rtl/vec_mem.vhd, then
-- rtl/bfp_pack.vhd reading them back twice (max pass, pack pass) and emitting
-- N 16-bit mantissas under one exponent.  The DUT is rtl/swiglu_mem.vhd, which
-- does the same arithmetic behind word-stream ports with the pack folded in
-- and the intermediate recomputed rather than stored.  The bench drives both
-- with the SAME stimulus and asserts, per trial and with NO tolerance:
--   * every element of the packed mantissa, DUT read out word by word against
--     bfp_pack's flat o_mant register;
--   * o_exp against bfp_pack's o_exp;
--   * the READ LATENCY of o_raddr -> o_rdata, measured rather than assumed.
-- It does NOT compare `done` cycles: the DUT is pipelined (one element per
-- cycle, two passes) and the reference is 4 cycles per element plus two
-- read-ahead passes, so the schedules differ by design.  Both are printed.
--
-- WHY THIS IS NOT A ROUND TRIP.  The DUT writes its inputs into RAMs and
-- reads its output out of one; a bench checking only "what went in came out"
-- passes a packer plus a reversed decoder (the recorded `m7 mutant`).  The
-- reference here shares no storage, no addressing, no pipeline and no pack
-- code with the DUT, and its own correctness is established elsewhere
-- (tb_swiglu against the C model; tb_engine_shared 24/24 across bfp_pack's
-- extraction).
--
-- WHICH INPUT REGIMES, AND WHY THESE.  The 9B block-3 case that found the
-- stand-in (docs/debugging/2026-09-19_the-swiglu-on-the-card-is-a-product-
-- with-no-gate.md) has G at exp 14 and U at exp 13, so the Q12 conversion
-- is a ROUNDING right shift on both; that is `blk3`.  `left` puts both
-- exponents below Q so the conversion is a left shift (the other branch of
-- swiglu.vhd's S_CALC_A).  `wrap` drives exp 0 with full-scale mantissas so
-- v_q and h2_q reach 2**27 and the second product exceeds 32 bits: the
-- `resize` truncation is part of the recipe and must match.  `packsh` makes
-- max|out_v| exceed 2**15 so the pack shift is non-zero and rounds.
-- `wild` sweeps the exponents across the whole signed-8-bit range, including
-- the values where a 64-bit shift count reaches or passes the word width
-- (exp = 76 is the one distinct count; 77..127 and -52..-128 are the
-- clamped ones) -- an all-zero or all-minus-one result there is still a
-- result, and it is asserted equal.  The rest are the structural trials the
-- rmsnorm_*_mem benches carry (one big element, all zero, ramp, powers of
-- two, saturation) because the RAM addressing faults they catch are the
-- same faults this port shape invites.
--
-- NON-DEGENERACY IS A HARD FAILURE.  Two all-zero vectors compare equal, so
-- every trial is classified and the run fails unless at least MIN_LIVE were
-- non-degenerate (a non-zero element AND two distinct element values).
--
-- CHECKS ARE COUNTED IN VARIABLES, never in signals (CLAUDE.md, MEASURED).
--
-- THE VERDICT LINE.  sim/regress.sh's FAIL_RE matches a bare `\bFAIL\b`, so
-- a passing summary must not contain that word; the house form
-- `tb_swiglu_mem: PASS -- ` is what sim/mutverdict.py wants too.
--
-- NO HARDWARE.  Simulation only.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_swiglu_mem is
  generic(N : positive := 128; Q : integer := 12;
          -- Seventeen value trials are run and one is all-zero; MIN_LIVE is
          -- the rest.  Lower it only with a stated reason.
          MIN_LIVE : natural := 16;
          -- The wild-exponent sweep is NWILD trials on top of the thirteen.
          -- Most of them rail (all-zero) by construction and are counted as
          -- RAIL, not LIVE; they are here for identity, not for liveness.
          NWILD    : natural := 12;
          -- PER-CHECK SWITCHES, for the ATTRIBUTION CONTROL.  A mutation
          -- killed by this bench proves nothing about which check earned the
          -- kill until the same mutant is re-run with the other checks off.
          CHK_VAL : boolean := true;    -- mantissas against bfp_pack
          CHK_EXP : boolean := true;    -- o_exp against bfp_pack
          CHK_LAT : boolean := true;    -- o_raddr -> o_rdata latency
          -- The DUT's LANES generic (elements per cycle in both passes).
          -- 1 is the 2026-09-19 unit; TRACK SWGFAST added 2 and 4.
          LANES   : positive := 1;
          -- TRACK GSRWIDE.  Drive the DUT through swiglu_mem's WIDE face
          -- (`gw_*` in, `o_gdata` out, LANES elements a beat) instead of the
          -- one-word face.  The reference chain is UNCHANGED and so is every
          -- value check, so a WIDE_IO run is the same identity claim through
          -- a different pair of ports -- which is the point: the wide face
          -- has to be held to `swiglu -> vec_mem -> bfp_pack` and not to the
          -- narrow face, or it is a round trip against a sibling.
          WIDE_IO : boolean := false;
          -- The wide read-out check: every lane of `o_gdata` against
          -- bfp_pack's flat o_mant.  Its own switch, so the attribution
          -- control can turn it off alone.
          CHK_GRD : boolean := true;
          -- TRACK SWGFAST.  When non-empty, every trial's DUT read-out
          -- (o_exp, then the N mantissas as read through o_raddr) is
          -- appended to this file, one integer per line, so two runs of the
          -- bench -- e.g. LANES=1 against LANES=2 -- can be `cmp`ed as
          -- FILES rather than trusted to the in-bench equality alone.
          DUMP    : string := "");
end entity;

architecture sim of tb_swiglu_mem is
  constant AW : natural := clog2(N);

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal done_sim : boolean := false;

  -- stimulus, held flat so the reference and the DUT load are fed from ONE
  -- source and a bench bug cannot give the two sides different numbers
  signal gm, um : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal ge, ue : integer := 0;

  -- reference chain: swiglu -> vec_mem(32) -> bfp_pack
  signal r_start  : std_logic := '0';
  signal sw_done  : std_logic;
  signal sw_we    : std_logic;
  signal sw_wa    : std_logic_vector(AW-1 downto 0);
  signal sw_wd    : std_logic_vector(31 downto 0);
  signal hbp_ra   : std_logic_vector(AW-1 downto 0);
  signal vm_dout  : std_logic_vector(31 downto 0);
  signal hbp_start : std_logic := '0';
  signal hbp_done : std_logic;
  signal r_om     : std_logic_vector(N*16-1 downto 0);
  signal r_oe     : integer;

  -- DUT
  signal d_start : std_logic := '0';
  signal g_we, u_we : std_logic := '0';
  signal g_wa, u_wa : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal g_wd, u_wd : std_logic_vector(15 downto 0) := (others => '0');
  signal d_done  : std_logic;
  signal o_ra    : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal o_rd    : std_logic_vector(15 downto 0);
  -- the wide face
  signal gw_we   : std_logic := '0';
  signal gw_addr : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal gw_g    : std_logic_vector(LANES*16-1 downto 0) := (others => '0');
  signal gw_u    : std_logic_vector(LANES*16-1 downto 0) := (others => '0');
  signal o_gd    : std_logic_vector(LANES*16-1 downto 0);
  signal d_oe    : integer;
  signal d_sh    : integer;
  signal d_mx    : unsigned(31 downto 0);

  -- done latches and cycle counts (one-cycle pulses, so latched)
  signal r_l, d_l : std_logic := '0';
  signal r_c, d_c : natural := 0;
  signal cyc : natural := 0;
  signal counting : std_logic := '0';

  signal checks : natural := 0;
  signal bad    : natural := 0;
  signal live   : natural := 0;
  signal rail   : natural := 0;
  signal rdlat  : integer := -1;
begin
  clk <= '0' when done_sim else not clk after 1 ns;

  -- ---- the reference chain, wired as rtl/engine_shared.vhd wires it
  ref_sw : entity work.swiglu
    generic map(N => N, Q => Q)
    port map(clk => clk, rst => rst, start => r_start,
             hb_mant => gm, hb_exp => ge, hb2_mant => um, hb2_exp => ue,
             done => sw_done, out_q => open,
             o_we => sw_we, o_waddr => sw_wa, o_wdata => sw_wd);
  ref_vm : entity work.vec_mem
    generic map(WORDS => N, W => 32)
    port map(clk => clk, we => sw_we, waddr => sw_wa, raddr => hbp_ra,
             din => sw_wd, dout => vm_dout);
  ref_pk : entity work.bfp_pack
    generic map(N => N, Q => Q)
    port map(clk => clk, rst => rst, start => hbp_start,
             o_raddr => hbp_ra, i_rdata => vm_dout, done => hbp_done,
             o_mant => r_om, o_exp => r_oe);
  -- engine_shared's L_SW_W -> L_HBPACK_S: the pack starts the cycle after
  -- swiglu's done.  swiglu's last o_we is registered one cycle after its
  -- done, and bfp_pack's read-ahead consumes element 0 two cycles after
  -- start and element N-1 far later, so the last write is resident in time.
  hbp_start <= sw_done;

  dut : entity work.swiglu_mem
    generic map(N => N, Q => Q, LANES => LANES, WIDE_IO => WIDE_IO)
    port map(clk => clk, rst => rst, start => d_start,
             g_we => g_we, g_waddr => g_wa, g_wdata => g_wd, g_exp => ge,
             u_we => u_we, u_waddr => u_wa, u_wdata => u_wd, u_exp => ue,
             gw_we => gw_we, gw_addr => gw_addr, gw_g => gw_g, gw_u => gw_u,
             o_gdata => o_gd,
             done => d_done,
             o_raddr => o_ra, o_rdata => o_rd, o_exp => d_oe,
             o_shift => d_sh, o_maxabs => d_mx);

  lat : process(clk) is
  begin
    if rising_edge(clk) then
      if d_start = '1' then
        r_l <= '0'; d_l <= '0';
        r_c <= 0; d_c <= 0; cyc <= 0; counting <= '1';
      else
        if counting = '1' then cyc <= cyc + 1; end if;
        if hbp_done = '1' and r_l = '0' then r_l <= '1'; r_c <= cyc; end if;
        if d_done = '1' and d_l = '0' then d_l <= '1'; d_c <= cyc; end if;
      end if;
    end if;
  end process;

  drv : process
    variable seed1, seed2 : positive := 11;
    variable r : real;
    variable rm, dm : signed(15 downto 0);
    variable nbadel : natural;
    variable nbadg  : natural;
    variable nz : natural;
    variable first_v : signed(15 downto 0);
    variable seen2 : boolean;
    variable nlive, nrail : natural := 0;
    variable nchk, nbad : natural := 0;
    variable lat_v : integer;
    -- TRACK SWGFAST: the unit's start -> done count on the LAST live trial,
    -- printed as SWGFAST_CYCLES so a log grep can read it.
    variable last_dut_cyc : natural := 0;
    file dumpf : text;
    variable dl : line;

    procedure setg(i : natural; v : integer) is
    begin
      gm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;
    procedure setu(i : natural; v : integer) is
    begin
      um((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;

    -- Load the DUT's banks with the SAME words the flat vectors hold, one
    -- word per cycle in ascending element order, g and u in SEPARATE passes
    -- so a "u enable decoded from g_waddr" fault is not a no-op.
    procedure load is
    begin
      if WIDE_IO then
        -- THE WIDE FACE.  One beat carries LANES consecutive elements of
        -- BOTH operands, which is how the region file's group read delivers
        -- them; there is no separate u pass here and no u address, so the
        -- "u enable decoded from g_waddr" fault the narrow load is shaped
        -- against cannot exist.  What CAN exist instead is a lane shuffle,
        -- and that is what the o_gdata read-out below is shaped against.
        for b in 0 to N/LANES - 1 loop
          wait until rising_edge(clk);
          gw_we   <= '1';
          gw_addr <= std_logic_vector(to_unsigned(b*LANES, AW));
          for k in 0 to LANES-1 loop
            gw_g((k+1)*16-1 downto k*16) <= gm((b*LANES+k+1)*16-1
                                               downto (b*LANES+k)*16);
            gw_u((k+1)*16-1 downto k*16) <= um((b*LANES+k+1)*16-1
                                               downto (b*LANES+k)*16);
          end loop;
        end loop;
        wait until rising_edge(clk);
        gw_we <= '0';
      else
        for i in 0 to N-1 loop
          wait until rising_edge(clk);
          g_we <= '1'; u_we <= '0';
          g_wa <= std_logic_vector(to_unsigned(i, AW));
          g_wd <= gm((i+1)*16-1 downto i*16);
        end loop;
        wait until rising_edge(clk);
        g_we <= '0';
        for i in 0 to N-1 loop
          wait until rising_edge(clk);
          u_we <= '1';
          u_wa <= std_logic_vector(to_unsigned(i, AW));
          u_wd <= um((i+1)*16-1 downto i*16);
        end loop;
        wait until rising_edge(clk);
        u_we <= '0';
      end if;
    end procedure;

    procedure trial(tag : string; wild : boolean := false) is
    begin
      load;
      wait until rising_edge(clk);
      r_start <= '1'; d_start <= '1';
      wait until rising_edge(clk);
      r_start <= '0'; d_start <= '0';
      -- swiglu is 4N cycles, bfp_pack 2N+, the DUT 2N+: bound generously.
      for t in 0 to 8*N + 400 loop
        wait until rising_edge(clk);
        exit when r_l = '1' and d_l = '1';
      end loop;
      assert r_l = '1' and d_l = '1'
        report "tb_swiglu_mem " & tag & ": a unit never asserted done (ref "
             & std_logic'image(r_l) & " dut " & std_logic'image(d_l) & ")"
        severity failure;

      -- ---- the exponent
      if CHK_EXP then
        nchk := nchk + 1;
        if d_oe /= r_oe then
          report "tb_swiglu_mem BAD " & tag & ": o_exp ref " & integer'image(r_oe)
               & " dut " & integer'image(d_oe) severity error;
          nbad := nbad + 1;
        end if;
      end if;

      -- ---- the VALUES, element for element, DUT read out word by word
      nbadel := 0; nz := 0; seen2 := false;
      if DUMP /= "" then
        write(dl, integer'image(d_oe)); writeline(dumpf, dl);
      end if;
      for i in 0 to N-1 loop
        o_ra <= std_logic_vector(to_unsigned(i, AW));
        wait until rising_edge(clk);
        -- ONE EDGE of latency, sampled after the delta settles (the RAM's
        -- dout resolves one delta after the edge).
        wait for 1 ns;
        dm := signed(o_rd);
        rm := signed(r_om((i+1)*16-1 downto i*16));
        if DUMP /= "" then
          write(dl, integer'image(to_integer(dm))); writeline(dumpf, dl);
        end if;
        if CHK_VAL then
          nchk := nchk + 1;
          if dm /= rm then
            if nbadel < 4 then
              report "tb_swiglu_mem BAD " & tag & " i " & integer'image(i)
                   & " ref " & integer'image(to_integer(rm))
                   & " dut " & integer'image(to_integer(dm)) severity error;
            end if;
            nbadel := nbadel + 1; nbad := nbad + 1;
          end if;
        end if;
        if rm /= 0 then nz := nz + 1; end if;
        if i = 0 then first_v := rm;
        elsif rm /= first_v then seen2 := true; end if;
      end loop;

      -- ---- THE WIDE READ-OUT, AGAINST THE SAME INDEPENDENT REFERENCE.
      -- WIDE_IO only.  Every lane of `o_gdata` is compared with bfp_pack's
      -- flat o_mant at the element that lane is supposed to hold -- NOT with
      -- `o_rdata`, which is a sibling of the same banks and would make this
      -- a round trip.  The loop waits EXACTLY ONE rising edge between
      -- presenting `o_raddr` and sampling, so it is also the wide face's
      -- one-edge latency check: a two-edge port fails it on element 0.
      nbadg := 0;
      if WIDE_IO and CHK_GRD then
        for b in 0 to N/LANES - 1 loop
          o_ra <= std_logic_vector(to_unsigned(b*LANES, AW));
          wait until rising_edge(clk);
          wait for 1 ns;
          for k in 0 to LANES-1 loop
            nchk := nchk + 1;
            dm := signed(o_gd((k+1)*16-1 downto k*16));
            rm := signed(r_om((b*LANES+k+1)*16-1 downto (b*LANES+k)*16));
            if dm /= rm then
              if nbadg < 4 then
                report "tb_swiglu_mem BAD " & tag & " o_gdata b "
                     & integer'image(b) & " lane " & integer'image(k)
                     & " (element " & integer'image(b*LANES+k) & ") ref "
                     & integer'image(to_integer(rm)) & " dut "
                     & integer'image(to_integer(dm)) severity error;
              end if;
              nbadg := nbadg + 1; nbad := nbad + 1;
            end if;
          end loop;
        end loop;
      end if;

      -- ---- NON-DEGENERACY
      if nz > 0 and seen2 then
        nlive := nlive + 1;
        last_dut_cyc := d_c;
        report "tb_swiglu_mem live " & tag & " g_exp " & integer'image(ge)
             & " u_exp " & integer'image(ue)
             & " o_exp " & integer'image(r_oe) & " shift " & integer'image(d_sh)
             & " nonzero " & integer'image(nz) & "/" & integer'image(N)
             & " ref_cyc " & integer'image(r_c) & " dut_cyc " & integer'image(d_c)
             & " badel " & integer'image(nbadel)
             & " badgrp " & integer'image(nbadg) severity note;
      else
        nrail := nrail + 1;
        report "tb_swiglu_mem RAIL " & tag & " g_exp " & integer'image(ge)
             & " u_exp " & integer'image(ue) & ": output is all-zero or "
             & "constant, so this trial proves identity and nothing about "
             & "the values" severity note;
      end if;
      live <= nlive; rail <= nrail; checks <= nchk; bad <= nbad;
    end procedure;

    -- A bell-shaped draw (sum of three uniforms), rms a.
    procedure drawg(i : natural; a : real) is
      variable r2, r3 : real;
    begin
      uniform(seed1, seed2, r); uniform(seed1, seed2, r2); uniform(seed1, seed2, r3);
      setg(i, integer(((r - 0.5) + (r2 - 0.5) + (r3 - 0.5)) * 2.0 * a));
    end procedure;
    procedure drawu(i : natural; a : real) is
      variable r2, r3 : real;
    begin
      uniform(seed1, seed2, r); uniform(seed1, seed2, r2); uniform(seed1, seed2, r3);
      setu(i, integer(((r - 0.5) + (r2 - 0.5) + (r3 - 0.5)) * 2.0 * a));
    end procedure;
  begin
    if DUMP /= "" then file_open(dumpf, DUMP, write_mode); end if;
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- ---- 1. the 9B block-3 regime: G exp 14 (rms mantissa ~3300, absmax
    -- ~25000), U exp 13 (rms ~1470, absmax ~24000).  Both conversions are
    -- rounding right shifts (by 2 and by 1).
    for i in 0 to N-1 loop drawg(i, 3300.0); drawu(i, 1470.0); end loop;
    ge <= 14; ue <= 13; trial("blk3");

    -- ---- 2. exp = Q on both: the conversion is the identity
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setg(i, integer(r*16000.0) - 8000);
      uniform(seed1, seed2, r); setu(i, integer(r*16000.0) - 8000);
    end loop;
    ge <= 12; ue <= 12; trial("ident");

    -- ---- 3. exponents BELOW Q: the left-shift branch of the conversion
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setg(i, integer(r*2000.0) - 1000);
      uniform(seed1, seed2, r); setu(i, integer(r*2000.0) - 1000);
    end loop;
    ge <= 9; ue <= 10; trial("left");

    -- ---- 4. exp 0 with full-scale mantissas: v_q, h2_q reach 2**27 and the
    -- second product's resize to 32 WRAPS.  Part of the recipe.
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setg(i, integer(r*65000.0) - 32500);
      uniform(seed1, seed2, r); setu(i, integer(r*65000.0) - 32500);
    end loop;
    ge <= 0; ue <= 0; trial("wrap");

    -- ---- 5. a non-zero PACK SHIFT with rounding: exp 8 on both puts
    -- |out_v| up to ~2**22, so shift_o is ~8 and every mantissa rounds.
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setg(i, integer(r*30000.0) - 15000);
      uniform(seed1, seed2, r); setu(i, integer(r*30000.0) - 15000);
    end loop;
    ge <= 8; ue <= 8; trial("packsh");

    -- ---- 6. G deeply negative: sigmoid rails at 0 for most elements, so
    -- the output is mostly zero with a few live ones (the k-clamp branches).
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setg(i, -integer(r*30000.0));
      uniform(seed1, seed2, r); setu(i, integer(r*20000.0) - 10000);
    end loop;
    ge <= 8; ue <= 12; trial("gneg");

    -- ---- 7. G large positive: sigmoid rails at one_q
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setg(i, integer(r*30000.0));
      uniform(seed1, seed2, r); setu(i, integer(r*20000.0) - 10000);
    end loop;
    ge <= 8; ue <= 12; trial("gpos");

    -- ---- 8. one large element against zeros: max_abs from ONE element.
    -- FOUR trials, the element at N/2 + 0..3, so that at LANES = 2 and 4
    -- (TRACK SWGFAST) EVERY lane is the one holding the max exactly once.
    -- MEASURED 2026-09-20: with the element at N/2 + 1 alone, a mutant that
    -- dropped lane 0 from the lane-max combine (`lanemax` in
    -- sim/mutate_swiglu_mem.sh) SURVIVED at LANES = 4 -- the pack shift only
    -- moves when lane 0's max sits in a higher power-of-two bin than every
    -- other lane's, which the random draws over 128 elements rarely give and
    -- the one planted element at index N/2 + 1 (lane 1) never gives.
    for k in 0 to 3 loop
      for i in 0 to N-1 loop setg(i, 0); setu(i, 0); end loop;
      setg(N/2 + k, 30000); setu(N/2 + k, 30000);
      ge <= 8; ue <= 8; trial("one_big" & integer'image(k));
    end loop;
    -- And at the LAST element, so the max lands in the last beat of pass 1
    -- and the drain test (`drained`) is what includes it.  MEASURED
    -- 2026-09-20: the `nodrain` mutant survived every trial above.
    for i in 0 to N-1 loop setg(i, 0); setu(i, 0); end loop;
    setg(N-1, 30000); setu(N-1, 30000);
    ge <= 8; ue <= 8; trial("one_big_last");

    -- ---- 9. all zero: max_abs = 0, msb 0, shift 0, exp Q.  RAIL by
    -- construction; the exponent check still bites.
    for i in 0 to N-1 loop setg(i, 0); setu(i, 0); end loop;
    ge <= 12; ue <= 12; trial("all_zero");

    -- ---- 10. a RAMP: every element distinct and ordered, so any
    -- reordering of the readout is visible element for element
    for i in 0 to N-1 loop
      setg(i, ((i * 131) mod 4001) - 2000);
      setu(i, ((i * 977) mod 4001) - 2000);
    end loop;
    ge <= 11; ue <= 11; trial("ramp");

    -- ---- 11. powers of two: max|out_v| lands exactly on a bit boundary
    for i in 0 to N-1 loop
      setg(i, 2**((i mod 10) + 4));
      setu(i, 2**((i mod 7) + 5));
    end loop;
    ge <= 10; ue <= 10; trial("pow2");

    -- ---- 12. saturated inputs
    for i in 0 to N-1 loop
      if i mod 2 = 0 then setg(i, 32767); else setg(i, -32768); end if;
      if i mod 3 = 0 then setu(i, 32767); else setu(i, -32768); end if;
    end loop;
    ge <= 12; ue <= 12; trial("sat");

    -- ---- 13. the block-3 regime again with a DIFFERENT draw, so the
    -- read-latency probe has a live vector whose element 0 and N-1 differ
    for i in 0 to N-1 loop drawg(i, 3300.0); drawu(i, 1470.0); end loop;
    ge <= 14; ue <= 13; trial("latref");

    -- ---- the READ LATENCY, MEASURED on the trial just run
    lat_v := -1;
    o_ra <= std_logic_vector(to_unsigned(0, AW));
    wait until rising_edge(clk);
    wait for 1 ns;
    o_ra <= std_logic_vector(to_unsigned(N-1, AW));
    for e in 1 to 4 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      if lat_v < 0
         and signed(o_rd) = signed(r_om(N*16-1 downto (N-1)*16))
         and r_om(N*16-1 downto (N-1)*16) /= r_om(16-1 downto 0) then
        lat_v := e;
      end if;
    end loop;
    rdlat <= lat_v;
    if CHK_LAT then
      nchk := nchk + 1;
      if lat_v /= 1 then
        report "tb_swiglu_mem BAD: o_raddr -> o_rdata latency measured "
             & integer'image(lat_v) & " edges, contract is 1"
          severity error;
        nbad := nbad + 1;
      end if;
    end if;
    checks <= nchk; bad <= nbad;

    -- ---- 14+. the WILD exponent sweep: identity across the whole signed
    -- 8-bit exponent range, including the shift-count clamps.  The
    -- mantissas are a fixed live draw; only the exponents move.
    for i in 0 to N-1 loop drawg(i, 3300.0); drawu(i, 1470.0); end loop;
    for w in 0 to NWILD-1 loop
      case w is
        when 0  => ge <= 76;   ue <= 13;   -- right count exactly 64
        when 1  => ge <= 77;   ue <= 13;   -- right count 65 (clamped)
        when 2  => ge <= 127;  ue <= 13;   -- right count 115 (clamped)
        when 3  => ge <= 14;   ue <= 76;
        when 4  => ge <= 14;   ue <= 100;
        when 5  => ge <= -52;  ue <= 13;   -- left count exactly 64
        when 6  => ge <= -51;  ue <= 13;   -- left count 63: sign-bit only
        when 7  => ge <= -128; ue <= 13;   -- left count 140 (clamped)
        when 8  => ge <= 14;   ue <= -40;  -- left count 52
        when 9  => ge <= -30;  ue <= -30;
        when 10 => ge <= 40;   ue <= 12;   -- right count 28: rounds to 0
        when others => ge <= 12; ue <= 30;
      end case;
      trial("wild" & integer'image(w), true);
    end loop;

    -- ---- the VERDICT
    if DUMP /= "" then file_close(dumpf); end if;
    -- TRACK SWGFAST.  The unit's own start -> done cycle count at this N
    -- and LANES (the last live trial's; every trial's is the same by
    -- construction, the schedule is data-independent).  The card's VEC_SWG
    -- step is this plus llama_top's serial G load, U load and write-back;
    -- see docs/debugging/2026-09-20_vec-swg-5-cycles-per-element.md.
    report "SWGFAST_CYCLES " & integer'image(last_dut_cyc)
         & " N=" & integer'image(N) & " LANES=" & integer'image(LANES)
         & " WIDE_IO=" & boolean'image(WIDE_IO)
      severity note;
    -- TRACK GSRWIDE.  The LOAD and the STORE the parent has to run, in
    -- beats, at this face.  The narrow face is N beats per operand and N
    -- back; the wide face is N/LANES for BOTH operands together and N/LANES
    -- back, because the region file's group read carries two regions at one
    -- address.  Printed rather than derived so the write-up quotes a
    -- measurement.
    report "GSRWIDE_BEATS load " & integer'image(2*N) & " store "
         & integer'image(N) & " narrow, load "
         & integer'image(N/LANES) & " store " & integer'image(N/LANES)
         & " wide   N=" & integer'image(N) & " LANES=" & integer'image(LANES)
      severity note;
    report "tb_swiglu_mem: checks=" & integer'image(nchk)
         & " bad=" & integer'image(nbad)
         & " live=" & integer'image(nlive) & " rail=" & integer'image(nrail)
         & " rdlat=" & integer'image(lat_v) & " N=" & integer'image(N)
      severity note;
    if nbad = 0 and nlive >= MIN_LIVE then
      report "tb_swiglu_mem: PASS -- swiglu_mem is bit-identical to "
           & "swiglu -> vec_mem -> bfp_pack in every mantissa and o_exp over "
           & integer'image(nlive) & " live trials (" & integer'image(nchk)
           & " checks); read latency " & integer'image(lat_v) & " edge"
        severity note;
    elsif nbad /= 0 then
      report "tb_swiglu_mem: FAIL -- " & integer'image(nbad) & " of "
           & integer'image(nchk) & " checks disagree" severity error;
    else
      report "tb_swiglu_mem: FAIL -- only " & integer'image(nlive)
           & " live trials of the " & integer'image(MIN_LIVE)
           & " required; the values were not exercised" severity error;
    end if;
    -- GHDL 1.0 exits 0 on a `severity error` report; the non-zero exit the
    -- mutation script and any rc-gated caller need comes from this
    -- `failure`, exactly as sim/tb_rmsnorm_bf_mem.vhd ends.
    assert nbad = 0 and nlive >= MIN_LIVE
      report "tb_swiglu_mem: FAIL -- see above" severity failure;
    done_sim <= true;
    wait;
  end process;
end architecture;
