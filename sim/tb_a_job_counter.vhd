-- sim/tb_a_job_counter.vhd -- the oracle is a count kept independently by the
-- bench, from the same pulses the DUT sees.
--
-- The arithmetic is trivial. What can be wrong, and what costs a wrong TOKEN
-- rather than a hang, is WHEN the count moves:
--
--   1. IT MUST RELOAD PER TOKEN.  The A descriptor table belongs to the token
--      PROGRAM and the program repeats. A count that ran monotonically would
--      index past the table on token 1.
--   2. IT MUST BE STABLE ACROSS AN ISSUE.  `a_desc_adapter:200-212` records
--      that its `u_index` port must be sampled one cycle after `u_start` if
--      the driver changes it there. This counter advances on RETIRE, so both
--      samples agree -- and the bench CHECKS that, by holding the index across
--      a modelled issue and only advancing it at the ack.
--   3. RUNNING PAST THE TABLE MUST RAISE, NOT WRAP. A wrapped index is a
--      valid descriptor for the wrong step.
--
-- AND ONE WIDTH PROPERTY: `u_index` (16 bits) and `job_index` (32 bits) are
-- the same number for two different consumers. They are checked against each
-- other on every sample, because two ports carrying one value is exactly the
-- shape that drifts.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_a_job_counter is
end entity;

architecture sim of tb_a_job_counter is
  constant N_JOBS : positive := 11;   -- small, so the overflow edge is reached

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal tok_start, job_retire : std_logic := '0';
  signal u_index   : std_logic_vector(15 downto 0);
  signal job_index : std_logic_vector(31 downto 0);
  signal err : std_logic;

  signal fail_o : natural := 0;
begin
  clk <= not clk after 5 ns;

  dut : entity work.a_job_counter
    generic map(N_JOBS => N_JOBS)
    port map(clk => clk, rst => rst, tok_start => tok_start,
             job_retire => job_retire,
             u_index => u_index, job_index => job_index, err => err);

  main : process is
    variable fail   : natural := 0;
    variable checks : natural := 0;

    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then
        fail := fail + 1;
        report "FAIL: " & msg severity error;
      end if;
    end procedure;

    -- THE ORACLE: a count the bench keeps itself.
    procedure expect(want : natural; what : string) is
    begin
      chk(to_integer(unsigned(u_index)) = want,
          what & ": u_index is "
        & integer'image(to_integer(unsigned(u_index)))
        & ", the bench's own count is " & integer'image(want));
      -- TWO PORTS, ONE VALUE.  Checked every time, not once.
      chk(unsigned(job_index) = resize(unsigned(u_index), 32),
          what & ": job_index and u_index disagree ("
        & integer'image(to_integer(unsigned(job_index))) & " vs "
        & integer'image(to_integer(unsigned(u_index)))
        & ").  They are the same number in two widths.");
    end procedure;

    procedure tick is begin wait until rising_edge(clk); end procedure;

    procedure retire is
    begin
      job_retire <= '1'; tick; job_retire <= '0'; tick;
    end procedure;

    procedure token is
    begin
      tok_start <= '1'; tick; tok_start <= '0'; tick;
    end procedure;

    -- A MODELLED JOB, the way `a_desc_adapter` would drive it: an issue, some
    -- cycles of work, then the ack.  The index must not move until the ack.
    procedure job(want : natural; what : string; worklen : natural) is
    begin
      -- the `u_start` edge, and the cycle after it: both must read `want`
      expect(want, what & " at issue");
      tick;
      expect(want, what & " one cycle after issue (the adapter's deferral)");
      for i in 1 to worklen loop
        tick;
        expect(want, what & " mid-job");
      end loop;
      retire;
    end procedure;
  begin
    rst <= '1'; for i in 0 to 4 loop tick; end loop; rst <= '0'; tick;

    -- ---- token 0: the whole table, as modelled jobs -------------------
    token;
    expect(0, "after tok_start");
    chk(err = '0', "err must be low at the start of a token");
    for j in 0 to N_JOBS-2 loop
      job(j, "token 0 job " & integer'image(j), 2);
      chk(err = '0', "token 0 job " & integer'image(j) & " must not error");
    end loop;
    expect(N_JOBS-1, "token 0, the last legal job");

    -- ---- running past the table ----------------------------------------
    retire;                                  -- the count reaches N_JOBS
    expect(N_JOBS, "one retire past the last job");
    chk(err = '0', "reaching N_JOBS is not itself the error");
    retire;                                  -- one past that
    chk(err = '1',
        "retiring past the end of the A descriptor table did not raise err.  "
      & "A wrapped index is a well-formed descriptor for the wrong step and "
      & "nothing downstream can tell.");
    chk(to_integer(unsigned(u_index)) /= 0,
        "the count WRAPPED to zero on overflow.  Index 0 is a real "
      & "descriptor, so a wrap is the exact failure this prevents.");

    -- ---- the count reloads per token, and clears err --------------------
    token;
    expect(0, "token 1 after tok_start");
    chk(err = '0', "tok_start must clear a latched err, or one bad token "
                 & "poisons every token after it");
    job(0, "token 1 job 0", 3);
    expect(1, "token 1 job 1");

    -- ---- a token with no jobs -------------------------------------------
    token;
    expect(0, "an empty token still names descriptor 0");

    -- ---- retire and tok_start in the same cycle -------------------------
    -- tok_start WINS.  A token boundary that also retires a job must not
    -- leave the count at 1, or every token after the first is off by one.
    job_retire <= '1'; tok_start <= '1'; tick;
    job_retire <= '0'; tok_start <= '0'; tick;
    expect(0, "tok_start must win over a simultaneous retire");

    -- ---- tok_start HELD HIGH, the case that motivated the edge detect ----
    -- `seq_desc_fetch.vhd:166`: "`go` is a level or a pulse; it is only read
    -- in S_IDLE."  D can read a level because it leaves S_IDLE at once.  A
    -- counter that reloaded on the LEVEL would be pinned at zero for as long
    -- as the host held `go` high and every A job of that token would fetch
    -- descriptor 0.
    --
    -- MEASURED: this bench PASSED both before and after the edge detect was
    -- added, because it had no such case.  A green bench across a real fix is
    -- the tell that the fix is untested, not that it was unnecessary.
    tok_start <= '1'; tick; tick;          -- rises, and STAYS high
    expect(0, "held tok_start: the rising edge reloads");
    retire;
    expect(1, "held tok_start: a retire must still advance while it is high");
    retire;
    expect(2, "held tok_start: and again");
    tok_start <= '0'; tick; tick;
    expect(2, "held tok_start: falling must not reload");
    retire;
    expect(3, "after tok_start fell");
    -- and a fresh rise still reloads
    tok_start <= '1'; tick; tok_start <= '0'; tick;
    expect(0, "a new rising edge reloads");

    -- ---- reset -----------------------------------------------------------
    rst <= '1'; tick; tick; rst <= '0'; tick;
    chk(err = '0', "reset must clear err");
    expect(0, "reset must clear the count");

    fail_o <= fail;
    report "TB_A_JOB_COUNTER checks=" & integer'image(checks)
         & " fail=" & integer'image(fail);
    if fail = 0 then
      report "TB_A_JOB_COUNTER PASS" severity note;
    else
      report "TB_A_JOB_COUNTER FAIL" severity failure;
    end if;
    wait;
  end process;
end architecture;
