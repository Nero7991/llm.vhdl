-- sim/tb_seq_desc_fetch.vhd
-- Testbench for rtl/seq_desc_fetch.vhd, subsystem D's descriptor walker.
--
-- WHAT THIS TESTBENCH IS FOR, AND WHY IT IS SHAPED THIS WAY.
--
-- The two defects found in subsystem B on 2026-08-27 were both invisible to
-- the obvious testbench.  The `w_mant` latch defect only appeared once blocks
-- were allowed to OVERLAP; the serialized configuration passed 6 blocks x 24
-- heads x 128 bit-exact and proved nothing about it.  The `done`-pulse defect
-- only appeared once the two producers were DECOUPLED; while a single process
-- fed z and then columns, the z handshake throttled the column path and a
-- COL_GAP sweep down to one column per cycle reported zero refused columns --
-- "a clean, confident, meaningless result".
--
-- So the design rule for this file is: **every producer has its own skew
-- generic, and no configuration is privileged.**  There are two producers
-- here and they are skewed independently:
--
--   URAM_LAT   how many cycles the descriptor memory takes to answer a read.
--              This sets how far AHEAD the prefetch runs.
--   JOB_LAT    how long a unit takes to finish.  This sets how far BEHIND the
--              consumer runs, and it is skewed PER UNIT by LAT_SKEW so the
--              five units do not move in lockstep.
--
-- The counter-intuitive part, and the reason a sweep is mandatory: for the
-- two-bank shadow the DANGEROUS configuration is a FAST memory and a SLOW
-- unit, because that is when the prefetch of step n+1 completes while step n
-- is still live.  A testbench tuned for throughput -- short jobs, quick
-- turnaround -- never gets the prefetch ahead at all and reports a clean pass
-- on a single-bank design.  That is the same shape as "maximally ahead
-- producers cannot see a missing wait", pointing the other way.
--
-- WHAT IS CHECKED, beyond "it terminated":
--
--   1. Every unit latches the WHOLE job shadow at the issue instant and then
--      re-compares it against the live ports on EVERY cycle of its job.  This
--      is the class (a) detector: if the prefetch reaches the live bank, or
--      the epoch moves mid-job, or any field is driven from a live counter,
--      the mismatch is reported with the step index and the field digest.
--   2. The counting identity: `steps_done` must equal the table length, and
--      the number of jobs the five stub units were actually STARTED for must
--      equal the table length minus one (END_TOKEN starts nobody).  This is
--      the accounting argument that named the head-emit cause; no throughput
--      metric would have.
--   3. Error injection with the expected code AND the expected failing step:
--      a stale epoch echo, a unit `err`, an external region-check rejection,
--      and a host abort.
--   4. A `done` that is a one-cycle pulse, and a `done` that stays asserted
--      past its ack, both of which must still produce exactly one completion.
--
-- HEARTBEAT.  A run producing no output is ambiguous between wedged and slow,
-- and that ambiguity cost about an hour on the emit chain.  `HEARTBEAT` prints
-- the full observable state on a fixed cycle interval; identical consecutive
-- reports mean frozen, not slow.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.seq_tbl_pkg.all;

entity tb_seq_desc_fetch is
  generic(
    -- ---- producer skew, the whole point of this file --------------------
    -- Cycles from `d_ren` to `d_rvalid`.  Small = prefetch runs far ahead.
    URAM_LAT   : natural := 1;
    -- Cycles a unit runs before asserting `done`.  0 means it finishes on the
    -- cycle after the shadow goes live.
    JOB_LAT    : natural := 40;
    -- Unit u runs for JOB_LAT + u*LAT_SKEW cycles, so the five units are not
    -- in lockstep with each other or with the memory.
    LAT_SKEW   : natural := 7;
    -- Cycles a unit stays un-ready after its ack, before it will accept a new
    -- start.  Exercises the held-`start` path.
    READY_GAP  : natural := 0;
    -- 0 = `done` is a level held until `u_ack` (the required discipline)
    -- 1 = `done` is a ONE-CYCLE PULSE (the withdrawn convention)
    -- 2 = `done` is a level held for DONE_HOLD cycles regardless of the ack
    DONE_STYLE : natural := 0;
    DONE_HOLD  : natural := 3;
    -- Extra cycles `done` stays high AFTER its ack.  Non-zero exercises the
    -- stale-done guard in S_ISSUE: without it the sticky capture would read a
    -- leftover `done` as an instant completion of the NEXT job.
    STALE_HOLD : natural := 0;
    -- A unit that re-arms as soon as its completion is ACKNOWLEDGED, while
    -- still driving `done` for STALE_HOLD more cycles.  Realistic for anything
    -- double-buffered, and it is the ONLY way to reach D's stale-done guard:
    -- with the default stub, `ready` and `done` are coupled (ready rises only
    -- after done falls) and the guard is unreachable.  That coupling is the
    -- same defect the head-emit testbench had, where one process fed both
    -- producers and the column path was never stressed.
    READY_EARLY : boolean := false;

    -- ---- fault injection, one at a time ---------------------------------
    ERR_AT       : integer := -1;   -- step index whose unit reports `err`
    LATE_ERR     : boolean := false;-- `err` for one cycle only, then dropped
    EPOCH_BAD_AT : integer := -1;   -- step index whose unit echoes a stale epoch
    CHK_BAD_AT   : integer := -1;   -- step index the region checker rejects
    ABORT_AT     : integer := -1;   -- step index at which the host aborts
    -- Corrupt the reserved pad byte of one descriptor.  Not a fault the
    -- hardware causes: it is a HOST GENERATOR fault, and the format's whole
    -- discipline is that two conforming generators produce byte-identical
    -- tables.  A pad byte that is not 0x00 means one of them is writing a
    -- field the decoder does not know about.
    PAD_BAD_AT   : integer := -1;
    -- A unit that hangs past D's watchdog bound and then completes anyway,
    -- with a ONE-CYCLE `done` pulse that lands while D is in its abort-drain
    -- state.  This is the only configuration that exercises S_ABORT's wait,
    -- and writing it is what found that the watchdog counter was never reset
    -- on entry to S_ABORT.
    HANG_AT      : integer := -1;
    HANG_CYC     : natural := 5000;

    TOKENS     : natural := 2;
    HEARTBEAT  : natural := 0;      -- cycles between state reports, 0 = off
    STRICT     : boolean := false;
    MAXCYC     : natural := 8000000
  );
end entity;

architecture sim of tb_seq_desc_fetch is

  constant EPOCH_W : positive := 4;
  constant NUNIT   : positive := 5;
  constant STEP_W  : positive := 11;

  constant TBL : tbl_t := build_table;

  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal running : boolean   := true;
  signal cyc     : natural   := 0;

  -- ---- DUT ports --------------------------------------------------------
  signal go, abort, busy, tok_done, tok_ack, err : std_logic := '0';
  signal tbl_len_s : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal err_code  : std_logic_vector(3 downto 0);
  signal err_step  : unsigned(STEP_W-1 downto 0);
  signal steps_done: unsigned(STEP_W-1 downto 0);

  signal d_raddr  : unsigned(15 downto 0);
  signal d_ren    : std_logic;
  signal d_rdata  : std_logic_vector(63 downto 0) := (others => 'X');
  signal d_rvalid : std_logic := '0';

  signal job_valid, job_issue, job_cmp : std_logic;
  signal job_epoch  : unsigned(EPOCH_W-1 downto 0);
  signal job_unit   : unsigned(2 downto 0);
  signal job_opcode : unsigned(3 downto 0);
  signal job_flags  : std_logic_vector(7 downto 0);
  signal job_src, job_src2, job_dst : unsigned(7 downto 0);
  signal job_dst_off, job_n_rows, job_n_cols : unsigned(31 downto 0);
  signal job_w_exp, job_out_shift : signed(31 downto 0);
  signal job_out_mode : std_logic_vector(7 downto 0);
  signal job_ordinal  : unsigned(7 downto 0);
  signal job_const_base : unsigned(31 downto 0);
  signal job_const_exp  : signed(31 downto 0);
  signal job_step     : unsigned(STEP_W-1 downto 0);

  signal chk_req  : std_logic;
  signal chk_bad  : std_logic := '0';
  signal chk_code : std_logic_vector(3 downto 0) := x"2";
  signal chk_opcode : unsigned(3 downto 0);
  signal chk_src, chk_dst : unsigned(7 downto 0);
  signal chk_dst_off, chk_n_rows : unsigned(31 downto 0);

  signal u_start, u_ready, u_done, u_ack, u_err : std_logic_vector(NUNIT-1 downto 0);
  signal u_done_epoch : std_logic_vector(NUNIT*EPOCH_W-1 downto 0);

  -- ---- the job digest ---------------------------------------------------
  -- Everything a unit is entitled to read for the duration of its job, in one
  -- vector.  A unit latches it at the issue instant and compares it every
  -- cycle afterwards; that single comparison covers all seven class (a) sites
  -- this unit is responsible for at once.
  constant DIG_W : natural := 4+8+8+8+8+32+32+32+32+32+8+8+32+32+STEP_W+EPOCH_W;
  signal job_digest : std_logic_vector(DIG_W-1 downto 0);

  -- ---- observation ------------------------------------------------------
  -- Per-unit counters, NOT shared signals.  Five processes writing one
  -- `natural` would be five drivers on an unresolved type, which GHDL reports
  -- as an elaboration error with no line number -- a trap this project has
  -- hit before.  Each generate drives only its own element, which is a
  -- distinct driver per VHDL's longest-static-prefix rule.
  type nat_arr is array (0 to NUNIT-1) of natural;
  signal n_start_a   : nat_arr := (others => 0);
  signal n_bad_a     : nat_arr := (others => 0);
  signal n_started   : natural;        -- jobs the stubs were started for
  signal n_completed : natural := 0;   -- job_cmp strobes seen
  signal n_digest_bad: natural;        -- class (a) violations
  signal n_stall_pf  : natural := 0;   -- cycles busy with no live job
  signal chk_step    : natural := 0;   -- which step the checker is looking at
  signal tok_start   : std_logic := '0';
  signal tok_idx     : natural := 0;
  signal hb_dig      : natural := 0;

  function to_nat(v : unsigned) return natural is
  begin return to_integer(v); end function;

  function sl2i(v : std_logic) return integer is
  begin if v = '1' then return 1; else return 0; end if; end function;

  function sum(a : nat_arr) return natural is
    variable s : natural := 0;
  begin
    for i in a'range loop s := s + a(i); end loop;
    return s;
  end function;

begin

  -- Guarded clock: four testbenches in this project once ran forever on an
  -- unguarded one, and --stop-time is a backstop, not the terminator.
  clk <= not clk after 0.5 ns when running else '0';

  cycles : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      if busy = '1' and job_valid = '0' then
        n_stall_pf <= n_stall_pf + 1;
      end if;
      assert cyc < MAXCYC
        report "tb_seq_desc_fetch: cycle cap reached, the run is wedged"
        severity failure;
    end if;
  end process;

  dut : entity work.seq_desc_fetch
    generic map(
      NREG => NREGION, EPOCH_W => EPOCH_W, NUNIT => NUNIT,
      NSUB_MAX => 64, STEP_W => STEP_W,
      WDOG_LIMIT => 4096, STRICT_PROTO => STRICT)
    port map(
      clk => clk, rst => rst,
      go => go, tbl_len => tbl_len_s, abort => abort,
      busy => busy, tok_done => tok_done, tok_ack => tok_ack,
      err => err, err_code => err_code, err_step => err_step,
      steps_done => steps_done,
      d_raddr => d_raddr, d_ren => d_ren, d_rdata => d_rdata,
      d_rvalid => d_rvalid,
      job_valid => job_valid, job_issue => job_issue, job_cmp => job_cmp,
      job_epoch => job_epoch, job_unit => job_unit, job_opcode => job_opcode,
      job_flags => job_flags, job_src => job_src, job_src2 => job_src2,
      job_dst => job_dst, job_dst_off => job_dst_off,
      job_n_rows => job_n_rows, job_n_cols => job_n_cols,
      job_w_exp => job_w_exp, job_out_shift => job_out_shift,
      job_out_mode => job_out_mode, job_ordinal => job_ordinal,
      job_const_base => job_const_base, job_const_exp => job_const_exp,
      job_step => job_step,
      chk_req => chk_req, chk_bad => chk_bad, chk_code => chk_code,
      chk_opcode => chk_opcode, chk_src => chk_src, chk_dst => chk_dst,
      chk_dst_off => chk_dst_off, chk_n_rows => chk_n_rows,
      u_start => u_start, u_ready => u_ready, u_done => u_done,
      u_ack => u_ack, u_err => u_err, u_done_epoch => u_done_epoch);

  n_started    <= sum(n_start_a);
  n_digest_bad <= sum(n_bad_a);

  job_digest <= std_logic_vector(job_opcode) & job_flags
              & std_logic_vector(job_src) & std_logic_vector(job_src2)
              & std_logic_vector(job_dst) & std_logic_vector(job_dst_off)
              & std_logic_vector(job_n_rows) & std_logic_vector(job_n_cols)
              & std_logic_vector(job_w_exp) & std_logic_vector(job_out_shift)
              & job_out_mode & std_logic_vector(job_ordinal)
              & std_logic_vector(job_const_base)
              & std_logic_vector(job_const_exp)
              & std_logic_vector(job_step) & std_logic_vector(job_epoch);

  -- ======================================================================
  -- PRODUCER 1: the descriptor memory.
  --
  -- Deliberately hostile between reads: `d_rdata` is driven to 'X' whenever
  -- `d_rvalid` is low, so a DUT that samples the bus on the wrong cycle poisons
  -- its shadow instead of silently getting the right answer by luck.  The same
  -- trap caught a `gdn_exp_capture` testbench that compared unwritten 'U' taps
  -- and passed because to_integer returns 0 for both sides.
  -- ======================================================================
  uram : process(clk) is
    type pipe_t is array (0 to 63) of natural;
    variable addr_p : pipe_t := (others => 0);
    variable vld_p  : std_logic_vector(0 to 63) := (others => '0');
    variable L      : natural;
  begin
    if rising_edge(clk) then
      L := URAM_LAT;
      if L < 1 then L := 1; end if;
      for i in 63 downto 1 loop
        addr_p(i) := addr_p(i-1);
        vld_p(i)  := vld_p(i-1);
      end loop;
      -- Guarded: `d_raddr` is only meaningful while `d_ren` is high, and
      -- reading it otherwise produces metavalue warnings at time zero that
      -- would mask a real one later.
      if d_ren = '1' then
        addr_p(0) := to_integer(d_raddr);
      else
        addr_p(0) := 0;
      end if;
      vld_p(0)  := d_ren;

      if vld_p(L-1) = '1' then
        d_rvalid <= '1';
        if addr_p(L-1) < TBL_WORDS then
          if PAD_BAD_AT >= 0 and addr_p(L-1) = PAD_BAD_AT*8 + 3 then
            d_rdata <= TBL(addr_p(L-1))(63 downto 57) & '1'
                     & TBL(addr_p(L-1))(55 downto 0);
          else
            d_rdata <= TBL(addr_p(L-1));
          end if;
        else
          -- Past the end of the table.  Real URAM would return whatever is
          -- there; 'X' makes a walk that runs long fail loudly instead of
          -- reading a plausible zero descriptor.
          d_rdata <= (others => 'X');
        end if;
      else
        d_rvalid <= '0';
        d_rdata  <= (others => 'X');
      end if;
    end if;
  end process;

  -- ======================================================================
  -- The external region/lock checker.  A stub here: `seq_region_lock` is the
  -- real one and has its own testbench.  Counting `chk_req` cycles gives the
  -- step index because S_CHECK is exactly one cycle wide.
  -- ======================================================================
  checker : process(clk) is
  begin
    if rising_edge(clk) then
      if tok_start = '1' then
        chk_step <= 0;
      elsif chk_req = '1' then
        chk_step <= chk_step + 1;
      end if;
    end if;
  end process;

  chk_bad <= '1' when chk_req = '1' and CHK_BAD_AT >= 0
                      and chk_step = CHK_BAD_AT else '0';

  -- ======================================================================
  -- PRODUCER 2: five stub units, each with its own latency.
  --
  -- Each one latches the ENTIRE job digest at the issue instant and then
  -- re-checks it on every cycle it holds the job.  That is the class (a)
  -- detector, and it is the reason a mutation that lets the prefetch reach
  -- the live bank fails here instead of producing a plausible wrong number
  -- 400 steps later.
  -- ======================================================================
  gen_units : for u in 0 to NUNIT-1 generate
    signal held    : std_logic_vector(DIG_W-1 downto 0) := (others => '0');
    signal have    : std_logic := '0';
    signal ep      : unsigned(EPOCH_W-1 downto 0) := (others => '0');
    signal lat     : integer := 0;
    signal dhold   : integer := 0;
    signal gap     : integer := 0;
    signal rdy     : std_logic := '1';
    signal dn      : std_logic := '0';
    signal er      : std_logic := '0';
    signal dn_age  : natural := 0;
    signal my_step : integer := -1;
  begin
    u_ready(u) <= rdy;
    u_done(u)  <= dn;
    u_err(u)   <= er;
    u_done_epoch((u+1)*EPOCH_W-1 downto u*EPOCH_W) <= std_logic_vector(ep);

    stub : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then
          have <= '0'; rdy <= '1'; dn <= '0'; er <= '0';
          lat <= 0; dhold <= 0; gap <= 0; dn_age <= 0; my_step <= -1;
          n_start_a(u) <= 0; n_bad_a(u) <= 0;
        elsif tok_start = '1' then
          n_start_a(u) <= 0; n_bad_a(u) <= 0;
        else
          -- ---- pick up a job at the ONE instant the shadow goes live ----
          if job_issue = '1' and to_nat(job_unit) = u then
            held    <= job_digest;
            ep      <= job_epoch;
            my_step <= to_integer(job_step);
            have    <= '1';
            rdy     <= '0';
            if HANG_AT >= 0 and to_integer(job_step) = HANG_AT then
              lat <= HANG_CYC;
            else
              lat <= JOB_LAT + u*LAT_SKEW;
            end if;
            dn_age  <= 0;
            n_start_a(u) <= n_start_a(u) + 1;
            -- A stale epoch echo, injected at one step.  The unit is otherwise
            -- honest: it reports the epoch it was given, minus one.
            if EPOCH_BAD_AT >= 0 and to_integer(job_step) = EPOCH_BAD_AT then
              ep <= job_epoch - 1;
            end if;
          end if;

          -- ---- the class (a) check, every cycle the job is held ---------
          -- Gated on `job_valid`, which is D's own statement that the shadow
          -- belongs to the running job.  Without that gate a unit whose
          -- completion has already been ACKNOWLEDGED, but which is still
          -- driving `done` for a few more cycles (READY_EARLY + STALE_HOLD),
          -- keeps comparing against a shadow it no longer owns and reports a
          -- false "shadow moved" on every subsequent step.  The check must
          -- cover the window the unit actually owns and not one cycle more.
          if have = '1' and job_valid = '1' then
            if job_digest /= held then
              n_bad_a(u) <= n_bad_a(u) + 1;
              report "tb_seq_desc_fetch: JOB SHADOW MOVED under unit "
                   & integer'image(u) & " at step " & integer'image(my_step)
                   & ", cycle " & integer'image(cyc)
                   & ".  A value a consumer reads for the duration of its job "
                   & "changed while it was reading it -- this is the w_mant "
                   & "defect class."
                severity error;
              have <= '0';   -- report once per job, not once per cycle
            end if;
          end if;

          -- ---- run down the latency and raise `done` -------------------
          if have = '1' and dn = '0' then
            if lat > 0 then
              lat <= lat - 1;
            else
              dn <= '1';
              dn_age <= 0;
              dhold <= DONE_HOLD;
              if ERR_AT >= 0 and my_step = ERR_AT then
                er <= '1';
              end if;
            end if;
          end if;

          -- ---- release `done` per the configured style ------------------
          if dn = '1' then
            dn_age <= dn_age + 1;
            if LATE_ERR then
              -- `err` for EXACTLY ONE cycle, coincident with the first cycle
              -- of `done`.  A D that re-samples `err` on later cycles while
              -- `done` stays high would read a zero and lose the error
              -- entirely; freezing at first observation is what survives it.
              -- Two cycles is not enough to test this: it leaves D exactly one
              -- cycle of slack and a re-sampling D still passes.
              er <= '0';
            end if;
            case DONE_STYLE is
              when 1 =>
                dn <= '0'; er <= '0'; have <= '0';
                gap <= READY_GAP;
              when 2 =>
                if dhold > 0 then
                  dhold <= dhold - 1;
                else
                  dn <= '0'; er <= '0'; have <= '0';
                  gap <= READY_GAP;
                end if;
              when others =>
                if u_ack(u) = '1' then
                  -- The job is over AT THE ACK, by definition, so ownership of
                  -- the shadow ends here even if `done` is still being driven
                  -- for a few more cycles.  Keeping `have` set past the ack is
                  -- what produced 257 spurious "shadow moved" reports: the
                  -- unit was checking a shadow that had legitimately been
                  -- handed to the next job.
                  have <= '0';
                  if READY_EARLY then
                    rdy <= '1';
                  end if;
                  if STALE_HOLD = 0 then
                    dn <= '0'; er <= '0';
                    gap <= READY_GAP;
                  else
                    dhold <= STALE_HOLD;
                  end if;
                elsif dhold > 0 then
                  dhold <= dhold - 1;
                  if dhold = 1 then
                    dn <= '0'; er <= '0';
                    gap <= READY_GAP;
                  end if;
                end if;
            end case;
          end if;

          -- ---- turnaround ---------------------------------------------
          if dn = '0' and have = '0' and rdy = '0' then
            if gap > 0 then
              gap <= gap - 1;
            else
              rdy <= '1';
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- Completion accounting.
  -- ======================================================================
  acct : process(clk) is
  begin
    if rising_edge(clk) then
      if tok_start = '1' then
        n_completed <= 0;
      elsif job_cmp = '1' then
        n_completed <= n_completed + 1;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- Heartbeat.  Identical consecutive reports mean frozen, not slow -- the
  -- single cheapest way to settle an ambiguity that cost an hour once.
  -- ======================================================================
  hb : process(clk) is
  begin
    if rising_edge(clk) and HEARTBEAT > 0 then
      if (cyc mod HEARTBEAT) = 0 and cyc > 0 then
        report "HB cyc=" & integer'image(cyc)
             & " busy=" & std_logic'image(busy)
             & " jvalid=" & std_logic'image(job_valid)
             & " step=" & integer'image(to_integer(job_step))
             & " steps_done=" & integer'image(to_integer(steps_done))
             & " unit=" & integer'image(to_integer(job_unit))
             & " u_ready=" & integer'image(to_integer(unsigned(u_ready)))
             & " u_done=" & integer'image(to_integer(unsigned(u_done)))
             & " tok_done=" & std_logic'image(tok_done)
             & " err=" & std_logic'image(err);
      end if;
    end if;
  end process;

  -- ======================================================================
  -- Stimulus and the assertions that matter.
  -- ======================================================================
  main : process is
    variable fail   : natural := 0;
    variable expect_err : boolean;
    variable want_code  : std_logic_vector(3 downto 0);
    variable want_step  : integer;

    procedure chk(name : string; got, want : integer) is
    begin
      if got /= want then
        report "tb_seq_desc_fetch: " & name & " is " & integer'image(got)
             & ", expected " & integer'image(want) severity error;
        fail := fail + 1;
      else
        report "  ok  " & name & " = " & integer'image(got);
      end if;
    end procedure;
  begin
    report "tb_seq_desc_fetch: model=" & integer'image(MODEL.blocks)
         & " blocks, NCARDS=" & integer'image(NCARDS)
         & ", table = " & integer'image(TBL_STEPS) & " descriptors ("
         & integer'image(gdn_layers(MODEL)) & " GDN x "
         & integer'image(NSTEP_GDN) & " + "
         & integer'image(attn_layers(MODEL)) & " attn x "
         & integer'image(NSTEP_ATTN) & " + 3)";
    report "  skew: URAM_LAT=" & integer'image(URAM_LAT)
         & " JOB_LAT=" & integer'image(JOB_LAT)
         & " LAT_SKEW=" & integer'image(LAT_SKEW)
         & " READY_GAP=" & integer'image(READY_GAP)
         & " DONE_STYLE=" & integer'image(DONE_STYLE)
         & " STALE_HOLD=" & integer'image(STALE_HOLD);

    tbl_len_s <= to_unsigned(TBL_STEPS, STEP_W);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    expect_err := (ERR_AT >= 0) or (EPOCH_BAD_AT >= 0)
               or (CHK_BAD_AT >= 0) or (ABORT_AT >= 0) or (PAD_BAD_AT >= 0)
               or (HANG_AT >= 0);

    for t in 0 to TOKENS-1 loop
      tok_idx <= t;
      tok_start <= '1';
      wait until rising_edge(clk);
      tok_start <= '0';
      go <= '1';
      wait until rising_edge(clk);
      go <= '0';

      -- Host abort, timed against the step counter rather than a raw cycle
      -- count so it lands in the same place regardless of the skew generics.
      if ABORT_AT >= 0 then
        while to_integer(steps_done) < ABORT_AT loop
          wait until rising_edge(clk);
        end loop;
        abort <= '1';
        wait until rising_edge(clk);
        abort <= '0';
      end if;

      wait until tok_done = '1' for 40 ms;
      if tok_done /= '1' then
        report "tb_seq_desc_fetch: token " & integer'image(t)
             & " never completed -- the walk is wedged" severity failure;
      end if;
      wait until rising_edge(clk);

      report "---- token " & integer'image(t) & " ----";
      report "  steps_done=" & integer'image(to_integer(steps_done))
           & " started=" & integer'image(n_started)
           & " completed=" & integer'image(n_completed)
           & " err=" & std_logic'image(err)
           & " code=" & integer'image(to_integer(unsigned(err_code)))
           & " step=" & integer'image(to_integer(err_step))
           & " prefetch-stall cycles=" & integer'image(n_stall_pf);

      if not expect_err then
        chk("err", sl2i(err), 0);
        -- THE COUNTING IDENTITY.  Present from the first run, not added after
        -- a hang: this is the assertion that named the head-emit cause.
        chk("steps_done", to_integer(steps_done), TBL_STEPS);
        chk("jobs started", n_started, TBL_STEPS-1);
        chk("jobs completed", n_completed, TBL_STEPS-1);
      else
        chk("err", sl2i(err), 1);
        if HANG_AT >= 0 then
          want_code := x"4"; want_step := HANG_AT;
        elsif PAD_BAD_AT >= 0 then
          want_code := x"3"; want_step := PAD_BAD_AT;
        elsif EPOCH_BAD_AT >= 0 then
          want_code := x"7"; want_step := EPOCH_BAD_AT;
        elsif ERR_AT >= 0 then
          want_code := x"1"; want_step := ERR_AT;
        elsif CHK_BAD_AT >= 0 then
          want_code := x"2"; want_step := CHK_BAD_AT;
        else
          want_code := x"8"; want_step := -1;
        end if;
        chk("err_code", to_integer(unsigned(err_code)),
            to_integer(unsigned(want_code)));
        if want_step >= 0 then
          chk("err_step", to_integer(err_step), want_step);
        end if;
      end if;

      chk("shadow-moved events", n_digest_bad, 0);

      tok_ack <= '1';
      wait until rising_edge(clk);
      tok_ack <= '0';
      wait until rising_edge(clk);
    end loop;

    if fail = 0 then
      report "tb_seq_desc_fetch: PASS -- " & integer'image(TOKENS)
           & " token(s) x " & integer'image(TBL_STEPS) & " descriptors";
    else
      report "tb_seq_desc_fetch: FAIL -- " & integer'image(fail)
           & " check(s) failed" severity failure;
    end if;

    running <= false;
    wait;
  end process;

  -- ======================================================================
  -- ORDERING GUARD (`ord_chk`).  A SCALAR THAT QUALIFIES A STREAM MUST BE
  -- PUBLISHED IN A STATE STRICTLY EARLIER THAN THE STATE THAT FIRST RAISES
  -- THAT STREAM'S VALID.
  --
  -- The defect shape this catches was found in `gdn_conv` on 2026-08-27
  -- (`docs/debugging/2026-08-27_gdn-conv-eseg-published-late.md`): the segment
  -- exponent was assigned in the unit's FINAL state, so every data beat it
  -- described had already been handed over.  The VALUE was right and only its
  -- TIME was wrong, and every existing testbench sampled the scalar at `done`,
  -- which is exactly the instant at which a late scalar looks correct.
  --
  -- Here the scalars are `job_w_exp`, `job_out_shift` and `job_const_exp`.
  -- They are CONTINUOUS decodes of `lv_w`, which is a concurrent alias of
  -- `dw(live_bank)`, and `live_bank` is written in `S_ISSUE` on the SAME
  -- clocked assignment that raises `jvalid_r`.  So the decode is already the
  -- new descriptor on the FIRST cycle of `job_valid`.  That is the property
  -- asserted below, and it is not readable off the port map, which is why it
  -- is asserted rather than argued.
  --
  -- The existing per-unit `job_digest` check is stronger in one direction (it
  -- compares every cycle) and weaker in another (it is gated on `job_valid`,
  -- so it stops one cycle before `job_cmp`, and it is a digest that names no
  -- field).  This guard closes that last cycle and names the three scalars.
  -- ======================================================================
  ord_chk : process(clk) is
    variable seen : boolean := false;
    variable at_v : std_logic_vector(95 downto 0) := (others => '0');
    -- to_string, NOT integer'image(to_integer(...)).  On a unit that publishes
    -- the decode late the scalar can be metavalued at the first beat, and
    -- to_integer then raises INSIDE the report expression: the run dies in
    -- numeric_std with no message at all.  A guard whose failure message
    -- cannot be built reports the wrong thing.
    impure function sc return std_logic_vector is
    begin
      return std_logic_vector(job_w_exp) & std_logic_vector(job_out_shift)
           & std_logic_vector(job_const_exp);
    end function;
  begin
    if rising_edge(clk) then
      if job_issue = '1' then seen := false; end if;
      if job_valid = '1' and not seen then
        seen := true;
        at_v := sc;
      end if;
      if job_cmp = '1' then
        assert seen
          report "tb_seq_desc_fetch: a job completed with no cycle of "
               & "job_valid at all -- the shadow was never published"
          severity failure;
        assert at_v = sc
          report "tb_seq_desc_fetch: a job scalar CHANGED after the first "
               & "cycle of job_valid -- " & to_string(at_v)
               & " at the first job_valid, " & to_string(sc)
               & " at job_cmp.  w_exp/out_shift/const_exp qualify every beat "
               & "the started unit produces, so they must be final before "
               & "job_valid rises, not after."
          severity failure;
      end if;
    end if;
  end process;

end architecture;
