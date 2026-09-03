-- sim/tb_gdn_job_seq.vhd -- the ORACLE for rtl/gdn_job_seq.vhd is the
-- ORDERING, not the arithmetic.
--
-- The arithmetic this module does is trivial: split a flat group index into
-- (segment, group).  Checking only that would be checking the easy half.  The
-- part that can be wrong -- and that costs a wrong TOKEN rather than a hang --
-- is WHEN each thing happens relative to everything else:
--
--   * the taps must be refilled AFTER `gdn_block` has read them and BEFORE the
--     state is saved.  Either side of that window and the number is wrong
--     while every unit in the chain still reports success.
--   * `gdn_state_store` FAILS a bench if `cvw_en` is asserted while its mover
--     owns the memory (`guard` at gdn_state_store.vhd:629).  The model here
--     reproduces that busy window and that assertion, so a sequencer that
--     writes into the mover's window is caught HERE and not three levels up.
--   * the write must trail its read by EXACTLY one cycle.  The refill walk is
--     pipelined, so an off-by-one shifts the whole conv history by one group
--     and nothing else changes.  The data check is what catches it, which is
--     why the model returns a DISTINCT value per (seg, grp) rather than
--     something a shifted read could also produce.
--
-- WHAT THIS BENCH DELIBERATELY DOES NOT CHECK.  It does not check that
-- `gdn_block` computes anything, that the store moves the right bytes, or that
-- the qkv column is the right column.  Those have their own benches
-- (tb_gdn_block, tb_gdn_state_store, tb_gdn_conv_tap_mem).  Composition is
-- checked at the level of the thing's OUTPUT, and this module's output is a
-- schedule.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gdn_job_seq is
  -- MUT selects a MODEL mutation (see below).  DUT mutations are separate
  -- files under the scratch tree and are not selectable from here: mutating
  -- the DUT from inside the bench would mean the gate row runs mutated RTL if
  -- the generic ever defaulted wrong.
  generic(MUTSEL : natural := 0);  -- NOT `MUT`: VHDL identifiers are CASE-INSENSITIVE and `mut` is a signal below.
end entity;

architecture sim of tb_gdn_job_seq is
  constant VAL_HEADS  : positive := 4;
  constant DIM        : positive := 8;
  constant KEY_HEADS  : positive := 2;
  constant KCONV      : positive := 4;
  constant CONV_LANES : positive := 2;
  constant LAYERS     : positive := 4;

  constant KEY_CH : positive := KEY_HEADS * DIM;      -- 16
  constant VAL_CH : positive := VAL_HEADS * DIM;      -- 32
  constant QKVN   : positive := 2*KEY_CH + VAL_CH;    -- 64
  constant NG_K   : positive := KEY_CH / CONV_LANES;  -- 8
  constant NG_V   : positive := VAL_CH / CONV_LANES;  -- 16
  constant NG     : positive := QKVN / CONV_LANES;    -- 32

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal start : std_logic := '0';
  signal layer : integer range 0 to LAYERS-1 := 0;
  signal busy, done, err : std_logic;

  signal ss_load_start, ss_save_start : std_logic;
  signal ss_layer : integer range 0 to LAYERS-1;
  signal ss_done  : std_logic := '0';
  signal ss_err   : std_logic := '0';

  signal cvw_en   : std_logic;
  signal cvw_seg  : integer range 0 to 2;
  signal cvw_grp  : natural range 0 to NG_V-1;
  signal cvw_data : std_logic_vector(CONV_LANES*16-1 downto 0);

  signal b_start : std_logic;
  signal b_busy  : std_logic := '0';

  signal q_seg  : integer range 0 to 2;
  signal q_grp  : natural range 0 to NG_V-1;
  signal q_data : std_logic_vector(CONV_LANES*16-1 downto 0) := (others => '0');

  -- ---- the model's knobs ------------------------------------------------
  -- Every one of these is a schedule the DUT must not depend on.  A sequencer
  -- that only works when the store takes exactly N cycles is a sequencer that
  -- works in this bench and nowhere else.
  signal m_lat_load : natural := 7;   -- cycles the modelled store takes
  signal m_lat_save : natural := 5;
  signal m_run_lat  : natural := 3;   -- cycles before the modelled b_busy RISES
  signal m_run_len  : natural := 11;  -- cycles it stays high
  signal m_err_load : std_logic := '0';
  signal m_err_save : std_logic := '0';

  -- ---- MUTATION SWITCHES (teeth) ----------------------------------------
  -- Applied to the MODEL and to the observers, never to the DUT, so a mutant
  -- run exercises the real RTL.  M0 is the control.
  --   M1  the store's busy window is EXTENDED past `done`, so a sequencer that
  --       starts writing taps in the done cycle collides.
  --   M2  `b_busy` never rises (a unit that refuses the job).
  --   M3  `b_busy` rises on the SAME edge as `b_start` (latency 0), the case a
  --       rise-armed waiter must still handle.
  signal mut : natural := MUTSEL;

  -- ---- observation ------------------------------------------------------
  type seen_t is array (0 to NG-1) of integer;
  signal n_w      : natural := 0;      -- conv writes seen this job
  signal w_ord    : seen_t := (others => -1);   -- flat index per write, in order
  signal w_bad    : natural := 0;      -- writes whose data did not match
  signal w_incl   : natural := 0;      -- writes while the model claimed busy
  -- COUNTED IN VARIABLES, NOT SIGNALS.  A signal assigned twice in one delta
  -- keeps only the last value, so a run of consecutive `chk` calls with no
  -- `wait` between them collapses to ONE increment.  MEASURED here: the first
  -- green run of this bench reported `checks=13` for a body containing 60,
  -- and a check that does not count is indistinguishable from a check that
  -- did not run.
  signal fail_o   : natural := 0;

  signal t_load_done : integer := -1;  -- cycle stamps
  signal t_bfall     : integer := -1;
  signal t_w_first   : integer := -1;
  signal t_w_last    : integer := -1;
  signal t_save      : integer := -1;
  signal n_bstart    : natural := 0;
  signal cyc         : natural := 0;
  signal b_busy_d    : std_logic := '0';

  signal m_busy : std_logic := '0';
  -- ONE driver per signal.  The counters below are cleared by the observer on
  -- `clr`, never by `main`: two processes driving one unresolved signal is an
  -- elaboration error, and routing the clear through a request makes the
  -- ownership explicit rather than incidental.
  signal clr : std_logic := '0';
  signal ss_lay_seen : integer := -1;

  -- The modelled qkv source.  A DISTINCT value per (seg, grp): a walk shifted
  -- by one group, or one that visits the segments in the wrong order, cannot
  -- reproduce it.
  function qval(seg : integer; grp : natural) return std_logic_vector is
    variable r : std_logic_vector(CONV_LANES*16-1 downto 0);
  begin
    for l in 0 to CONV_LANES-1 loop
      r((l+1)*16-1 downto l*16) :=
        std_logic_vector(to_unsigned(((seg+1)*1000 + grp*7 + l*3) mod 65536, 16));
    end loop;
    return r;
  end function;

  -- the inverse the DUT must implement
  procedure model_split(g : in natural; seg : out integer; grp : out natural) is
  begin
    if    g < NG_K   then seg := 0; grp := g;
    elsif g < 2*NG_K then seg := 1; grp := g - NG_K;
    else                  seg := 2; grp := g - 2*NG_K;
    end if;
  end procedure;

  procedure chk(cond : boolean; msg : string;
                variable f : inout natural; variable c : inout natural) is
  begin
    c := c + 1;
    if not cond then
      f := f + 1;
      report "FAIL: " & msg severity error;
    end if;
  end procedure;
begin
  clk <= not clk after 5 ns;

  dut : entity work.gdn_job_seq
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM, KEY_HEADS => KEY_HEADS,
                KCONV => KCONV, CONV_LANES => CONV_LANES, LAYERS => LAYERS)
    port map(clk => clk, rst => rst,
             start => start, layer => layer,
             busy => busy, done => done, err => err,
             ss_load_start => ss_load_start, ss_save_start => ss_save_start,
             ss_layer => ss_layer, ss_done => ss_done, ss_err => ss_err,
             cvw_en => cvw_en, cvw_seg => cvw_seg, cvw_grp => cvw_grp,
             cvw_data => cvw_data,
             b_start => b_start, b_busy => b_busy,
             q_seg => q_seg, q_grp => q_grp, q_data => q_data);

  -- ---- the modelled qkv source: ONE CYCLE registered read --------------
  qsrc : process(clk) is
  begin
    if rising_edge(clk) then
      q_data <= qval(q_seg, q_grp);
    end if;
  end process;

  -- ---- the modelled gdn_state_store ------------------------------------
  -- Reproduces the real one's contract EXACTLY: `busy` rises the cycle after
  -- start, `done` is a one-cycle pulse, and busy is ALREADY LOW in the done
  -- cycle (gdn_state_store.vhd:334 with a registered done_q).  M1 breaks that
  -- last property on purpose.
  store : process(clk) is
    variable cnt   : natural := 0;
    variable armed : std_logic := '0';
    variable saving: std_logic := '0';
  begin
    if rising_edge(clk) then
      ss_done <= '0';
      if rst = '1' then
        armed := '0'; m_busy <= '0'; ss_err <= '0'; cnt := 0;
      else
        if armed = '0' then
          if ss_load_start = '1' or ss_save_start = '1' then
            armed := '1';
            saving := ss_save_start;
            cnt := 0;
            m_busy <= '1';
            ss_lay_seen <= ss_layer;
          end if;
        else
          cnt := cnt + 1;
          if (saving = '0' and cnt >= m_lat_load)
             or (saving = '1' and cnt >= m_lat_save) then
            armed := '0';
            ss_done <= '1';
            -- busy falls WITH done, matching the real store.  Under M1 it
            -- lingers one extra cycle, so a DUT that writes in the done cycle
            -- is caught by the guard below.
            if mut /= 1 then m_busy <= '0'; end if;
            if saving = '0' then ss_err <= m_err_load;
            else                 ss_err <= ss_err or m_err_save; end if;
          end if;
        end if;
        if mut = 1 and armed = '0' and ss_done = '0' then m_busy <= '0'; end if;
      end if;
    end if;
  end process;

  -- ---- the modelled gdn_block ------------------------------------------
  unit : process(clk) is
    variable armed : std_logic := '0';
    variable cnt   : natural := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        armed := '0'; b_busy <= '0'; cnt := 0;
      elsif b_start = '1' and armed = '0' then
        armed := '1'; cnt := 0;
        if mut = 3 then b_busy <= '1'; end if;   -- latency 0
      elsif armed = '1' then
        cnt := cnt + 1;
        if mut = 2 then
          null;                                   -- never rises
        elsif cnt = m_run_lat then
          b_busy <= '1';
        elsif cnt = m_run_lat + m_run_len then
          b_busy <= '0'; armed := '0';
        end if;
        if mut = 3 and cnt = m_run_len then
          b_busy <= '0'; armed := '0';
        end if;
      end if;
    end if;
  end process;

  -- ---- the observers ----------------------------------------------------
  obs : process(clk) is
    variable s : integer;
    variable g : natural;
    variable fl : integer;
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;

      if clr = '1' then
        n_w <= 0; w_bad <= 0; w_incl <= 0; n_bstart <= 0;
        t_load_done <= -1; t_w_first <= -1; t_w_last <= -1; t_save <= -1;
        t_bfall <= -1;
        w_ord <= (others => -1);
      else

      if b_start = '1' then n_bstart <= n_bstart + 1; end if;
      if ss_done = '1' and t_load_done < 0 then t_load_done <= cyc; end if;
      -- The cycle the unit RELEASED the taps.  Without this stamp the phase
      -- order is unchecked: a sequencer that refills before the unit runs, or
      -- one that never waits for the unit at all, satisfies every other
      -- ordering check in this bench.  Both are real mutants (D2, D4) and both
      -- survived until this line existed.
      if b_busy = '0' and b_busy_d = '1' then t_bfall <= cyc; end if;
      b_busy_d <= b_busy;
      if ss_save_start = '1' and t_save < 0 then t_save <= cyc; end if;

      if cvw_en = '1' then
        -- THE STORE'S OWN GUARD, reproduced.  A write inside the mover's
        -- window is lost in the real design and reports nothing.
        if m_busy = '1' then w_incl <= w_incl + 1; end if;

        if t_w_first < 0 then t_w_first <= cyc; end if;
        t_w_last <= cyc;

        -- reconstruct the flat index from what the DUT drove
        if    cvw_seg = 0 then fl := cvw_grp;
        elsif cvw_seg = 1 then fl := NG_K + cvw_grp;
        else                   fl := 2*NG_K + cvw_grp;
        end if;
        if n_w < NG then w_ord(n_w) <= fl; end if;
        n_w <= n_w + 1;

        -- THE ONE-CYCLE ALIGNMENT CHECK.  `qval` is distinct per (seg, grp),
        -- so a write paired with the neighbouring read cannot match.
        if cvw_data /= qval(cvw_seg, cvw_grp) then
          w_bad <= w_bad + 1;
        end if;
      end if;
      end if;
    end if;
  end process;

  main : process is
    variable fail   : natural := 0;
    variable checks : natural := 0;
    variable s : integer;
    variable g : natural;
    variable ok : boolean;
    variable guard : natural;
  begin
    rst <= '1';
    for i in 0 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- =================================================================
    -- CASE 1: one job, the nominal schedule.
    -- =================================================================
    chk(busy = '0', "busy must be low in idle", fail, checks);

    layer <= 2;
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until rising_edge(clk);
    chk(busy = '1', "busy must be high the cycle after start", fail, checks);

    -- CHANGE `layer` MID-JOB.  It was latched at start; a DUT reading the
    -- field live would send the store a different layer half way through and
    -- save this token's state over another layer's.
    layer <= 0;

    guard := 0;
    while done = '0' and guard < 4000 loop
      wait until rising_edge(clk); guard := guard + 1;
    end loop;
    chk(guard < 4000, "the job must finish", fail, checks);
    chk(busy = '0', "busy must be low in the done cycle", fail, checks);
    chk(err = '0', "no error was injected", fail, checks);
    chk(ss_lay_seen = 2, "the store must be told the LATCHED layer, not the "
                       & "live one", fail, checks);
    layer <= 2;

    -- ---- the schedule ----
    chk(n_bstart = 1, "gdn_block must be started exactly once", fail, checks);
    chk(n_w = NG, "every conv group must be written exactly once, got "
                & integer'image(n_w), fail, checks);
    chk(w_incl = 0, "no conv write may land while the store's mover owns the "
                  & "memory", fail, checks);
    chk(w_bad = 0, "the write must carry the data of ITS OWN group; "
                 & integer'image(w_bad) & " did not", fail, checks);
    chk(t_load_done >= 0 and t_w_first > t_load_done,
        "the refill must come after the load completes", fail, checks);
    chk(t_bfall >= 0,
        "gdn_block must actually have run (busy rose and fell)", fail, checks);
    chk(t_w_first > t_bfall,
        "the refill must come after gdn_block RELEASES the taps, not before: "
      & "the unit reads the previous KCONV-1 columns and this token's column "
      & "is not one of them", fail, checks);
    chk(t_save > t_w_last,
        "the save must come after the last refill write", fail, checks);

    -- ---- the order ----
    ok := true;
    for i in 0 to NG-1 loop
      if w_ord(i) /= i then ok := false; end if;
    end loop;
    chk(ok, "the refill must walk q then k then v in flat group order",
        fail, checks);

    -- the split, checked at the two boundaries the segments meet at
    model_split(0, s, g);      chk(s = 0 and g = 0, "split(0)", fail, checks);
    model_split(NG_K-1, s, g); chk(s = 0 and g = NG_K-1, "split(k-1)", fail, checks);
    model_split(NG_K, s, g);   chk(s = 1 and g = 0, "split(k)", fail, checks);
    model_split(2*NG_K, s, g); chk(s = 2 and g = 0, "split(2k)", fail, checks);
    model_split(NG-1, s, g);   chk(s = 2 and g = NG_V-1, "split(NG-1)", fail, checks);

    -- =================================================================
    -- CASE 2: back to back, and every layer.  A sequencer that leaves state
    -- behind fails the second job, not the first.
    -- =================================================================
    for lay in 0 to LAYERS-1 loop
      clr <= '1'; wait until rising_edge(clk); clr <= '0';
      wait until rising_edge(clk);

      layer <= lay;
      start <= '1'; wait until rising_edge(clk); start <= '0';
      guard := 0;
      while done = '0' and guard < 4000 loop
        wait until rising_edge(clk); guard := guard + 1;
      end loop;
      chk(guard < 4000, "job " & integer'image(lay) & " must finish", fail, checks);
      chk(n_w = NG, "job " & integer'image(lay) & " must write every group",
          fail, checks);
      chk(w_bad = 0, "job " & integer'image(lay) & " data", fail, checks);
      chk(w_incl = 0, "job " & integer'image(lay) & " collision", fail, checks);
      chk(n_bstart = 1, "job " & integer'image(lay) & " one b_start",
          fail, checks);
      chk(t_bfall >= 0 and t_w_first > t_bfall,
          "job " & integer'image(lay) & " refill after the unit", fail, checks);
      chk(ss_lay_seen = lay, "job " & integer'image(lay) & " layer", fail, checks);
      ok := true;
      for i in 0 to NG-1 loop
        if w_ord(i) /= i then ok := false; end if;
      end loop;
      chk(ok, "job " & integer'image(lay) & " order", fail, checks);
    end loop;

    -- =================================================================
    -- CASE 3: the DUT must not depend on the model's latencies.
    -- =================================================================
    for v in 0 to 3 loop
      case v is
        when 0 => m_lat_load <= 1;  m_lat_save <= 1;  m_run_lat <= 1; m_run_len <= 1;
        when 1 => m_lat_load <= 2;  m_lat_save <= 40; m_run_lat <= 8; m_run_len <= 2;
        when 2 => m_lat_load <= 60; m_lat_save <= 3;  m_run_lat <= 1; m_run_len <= 60;
        when others => m_lat_load <= 9; m_lat_save <= 9; m_run_lat <= 5; m_run_len <= 5;
      end case;
      clr <= '1'; wait until rising_edge(clk); clr <= '0';
      wait until rising_edge(clk);

      start <= '1'; wait until rising_edge(clk); start <= '0';
      guard := 0;
      while done = '0' and guard < 4000 loop
        wait until rising_edge(clk); guard := guard + 1;
      end loop;
      chk(guard < 4000, "latency set " & integer'image(v) & " must finish",
          fail, checks);
      chk(n_w = NG, "latency set " & integer'image(v) & " writes", fail, checks);
      chk(w_bad = 0, "latency set " & integer'image(v) & " data", fail, checks);
      chk(w_incl = 0, "latency set " & integer'image(v) & " collision",
          fail, checks);
      chk(t_save > t_w_last, "latency set " & integer'image(v) & " save order",
          fail, checks);
      chk(t_bfall >= 0 and t_w_first > t_bfall,
          "latency set " & integer'image(v) & " refill after the unit",
          fail, checks);
    end loop;
    m_lat_load <= 7; m_lat_save <= 5; m_run_lat <= 3; m_run_len <= 11;

    -- =================================================================
    -- CASE 4: a failure must not look like a success.
    -- =================================================================
    m_err_load <= '1';
    wait until rising_edge(clk);
    start <= '1'; wait until rising_edge(clk); start <= '0';
    guard := 0;
    while done = '0' and guard < 4000 loop
      wait until rising_edge(clk); guard := guard + 1;
    end loop;
    chk(err = '1', "a store error during load must reach `err`", fail, checks);
    m_err_load <= '0';

    -- and it must CLEAR on the next job, or one bad layer poisons the rest of
    -- the token
    wait until rising_edge(clk);
    start <= '1'; wait until rising_edge(clk); start <= '0';
    guard := 0;
    while done = '0' and guard < 4000 loop
      wait until rising_edge(clk); guard := guard + 1;
    end loop;
    chk(err = '0', "`err` must clear on the next job", fail, checks);

    m_err_save <= '1';
    wait until rising_edge(clk);
    start <= '1'; wait until rising_edge(clk); start <= '0';
    guard := 0;
    while done = '0' and guard < 4000 loop
      wait until rising_edge(clk); guard := guard + 1;
    end loop;
    chk(err = '1', "a store error during save must reach `err`", fail, checks);
    m_err_save <= '0';

    fail_o <= fail;
    report "TB_GDN_JOB_SEQ checks=" & integer'image(checks)
         & " fail=" & integer'image(fail)
         & " mut=" & integer'image(mut);
    if fail = 0 then
      report "TB_GDN_JOB_SEQ PASS" severity note;
    else
      report "TB_GDN_JOB_SEQ FAIL" severity failure;
    end if;
    wait;
  end process;
end architecture;
