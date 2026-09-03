-- sim/tb_a_desc_ptr.vhd -- the oracle is an INDEPENDENT address computation,
-- not the module's own recurrence.
--
-- The bench recomputes `base + n*STRIDE` from a count it keeps itself, from the
-- same pulses the DUT sees.  That is deliberately a different expression of the
-- same rule rather than a mirror of the DUT's adder: the defect worth catching
-- here is not the arithmetic, it is WHEN the count moves and when it reloads.
--
-- Three properties, in order of how quietly they fail:
--
--   1. THE COUNT RESETS PER TOKEN.  The A descriptor table belongs to the token
--      PROGRAM, and the program repeats every token.  A counter that ran
--      monotonically would walk off the end of the table on token 1 and read
--      whatever follows it -- a well-formed descriptor for a step that does
--      not exist.  Nothing raises.
--   2. THE BASE IS LATCHED, not read live.  A base that moves under a token
--      already in flight makes every pointer after the move well-formed and
--      wrong.
--   3. RUNNING PAST THE TABLE RAISES `err` AND DOES NOT WRAP.  A wrapped
--      pointer is a valid descriptor for the wrong step, which is precisely
--      what the whole mechanism exists to prevent.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_a_desc_ptr is
end entity;

architecture sim of tb_a_desc_ptr is
  constant ADDR_W : positive := 40;
  constant STRIDE : positive := 512;
  constant N_JOBS : positive := 11;   -- small, so the overflow edge is reachable

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal tok_start, a_dispatch : std_logic := '0';
  signal base : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal desc_ptr : std_logic_vector(ADDR_W-1 downto 0);
  signal job_index : std_logic_vector(31 downto 0);
  signal err : std_logic;

  signal fail_o : natural := 0;
begin
  clk <= not clk after 5 ns;

  dut : entity work.a_desc_ptr
    generic map(ADDR_W => ADDR_W, STRIDE => STRIDE, DESC_ALIGN => 512,
                N_JOBS => N_JOBS)
    port map(clk => clk, rst => rst, tok_start => tok_start,
             a_dispatch => a_dispatch, base => base,
             desc_ptr => desc_ptr, job_index => job_index, err => err);

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

    -- THE ORACLE.  Recomputed from the bench's own count, not read back from
    -- the DUT.
    procedure expect(n : natural; b : natural; what : string) is
      variable want : unsigned(ADDR_W-1 downto 0);
    begin
      want := to_unsigned(b, ADDR_W) + to_unsigned(n * STRIDE, ADDR_W);
      chk(unsigned(desc_ptr) = want,
          what & ": desc_ptr is "
        & integer'image(to_integer(unsigned(desc_ptr(31 downto 0))))
        & ", the table says "
        & integer'image(to_integer(want(31 downto 0))));
      chk(to_integer(unsigned(job_index)) = n,
          what & ": job_index is "
        & integer'image(to_integer(unsigned(job_index)))
        & ", the count is " & integer'image(n));
    end procedure;

    procedure tick is begin wait until rising_edge(clk); end procedure;

    procedure dispatch is
    begin
      a_dispatch <= '1'; tick; a_dispatch <= '0'; tick;
    end procedure;

    procedure token(b : natural) is
    begin
      base <= std_logic_vector(to_unsigned(b, ADDR_W));
      tok_start <= '1'; tick; tok_start <= '0'; tick;
    end procedure;
  begin
    rst <= '1'; for i in 0 to 4 loop tick; end loop; rst <= '0'; tick;

    -- ---- token 0: the whole table, one job at a time -------------------
    token(16#100000#);
    expect(0, 16#100000#, "after tok_start");
    chk(err = '0', "err must be low at the start of a token");
    for j in 1 to N_JOBS-1 loop
      dispatch;
      expect(j, 16#100000#, "token 0 job " & integer'image(j));
      chk(err = '0', "token 0 job " & integer'image(j) & " must not error");
    end loop;

    -- ---- PROPERTY 3: one dispatch past the table ------------------------
    -- The Nth dispatch moves the count to N_JOBS, which is one past the last
    -- legal descriptor.  `err` names the dispatch AFTER that.
    dispatch;
    chk(to_integer(unsigned(job_index)) = N_JOBS,
        "the count must advance to N_JOBS, not stop at N_JOBS-1");
    chk(err = '0', "the count reaching N_JOBS is not itself the error");
    dispatch;
    chk(err = '1',
        "dispatching past the end of the A descriptor table did not raise "
      & "err.  A wrapped pointer is a well-formed descriptor for the wrong "
      & "step and nothing downstream can tell.");
    chk(to_integer(unsigned(job_index)) /= 0,
        "the count WRAPPED to zero on overflow.  That is the exact failure "
      & "this module exists to prevent: index 0 is a real descriptor.");

    -- ---- PROPERTY 1: the count resets per token -------------------------
    token(16#100000#);
    expect(0, 16#100000#, "token 1 after tok_start");
    chk(err = '0', "tok_start must clear a latched err, or one bad token "
                 & "poisons every token after it");
    dispatch;
    expect(1, 16#100000#, "token 1 job 1");

    -- ---- PROPERTY 2: the base is LATCHED --------------------------------
    -- Move `base` mid-token.  A DUT reading it live tracks the new value.
    base <= std_logic_vector(to_unsigned(16#900000#, ADDR_W));
    tick; tick;
    expect(1, 16#100000#, "base moved mid-token");
    dispatch;
    expect(2, 16#100000#, "base moved mid-token, then a dispatch");

    -- and the NEXT tok_start does pick it up
    token(16#900000#);
    expect(0, 16#900000#, "token 2 picks up the new base");

    -- ---- a token with no jobs at all ------------------------------------
    token(16#200000#);
    expect(0, 16#200000#, "an empty token still points at descriptor 0");

    -- ---- reset ----------------------------------------------------------
    rst <= '1'; tick; tick; rst <= '0'; tick;
    chk(err = '0', "reset must clear err");
    chk(to_integer(unsigned(job_index)) = 0, "reset must clear the count");

    fail_o <= fail;
    report "TB_A_DESC_PTR checks=" & integer'image(checks)
         & " fail=" & integer'image(fail);
    if fail = 0 then
      report "TB_A_DESC_PTR PASS" severity note;
    else
      report "TB_A_DESC_PTR FAIL" severity failure;
    end if;
    wait;
  end process;
end architecture;
