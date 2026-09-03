-- rtl/a_job_counter.vhd -- WHICH A descriptor, and nothing else.
--
-- ======================================================================
-- WHY THIS FILE IS SMALL, AND WHY AN EARLIER VERSION OF IT WAS WRONG
-- ======================================================================
-- The gap this closes is ONE signal: `rtl/a_desc_adapter.vhd` takes
-- `u_index : in std_logic_vector(15 downto 0)  -- which descriptor` and
-- NOTHING DRIVES IT.  That adapter already owns everything else --
--
--   * the address, `arena_base + u_index * DESC_STRIDE` (a_desc_adapter:213)
--   * the bound check, `u_index >= N_JOBS` (:230)
--   * the refusal of a non-power-of-two DESC_STRIDE (:127-137)
--   * the three AXI-Lite writes and the GO
--
-- -- so a module that computes an address here would be a SECOND model of
-- all four.  The first version of this file (`rtl/a_desc_ptr.vhd`, committed
-- e01c535 and removed in the commit that added this one) did exactly that: it
-- took an `arena_base`, emitted `BASE + n*STRIDE`, and re-derived the N_JOBS
-- bound and the stride alignment.  It was verified, it was correct, and it was
-- redundant.  `tools/hbm_map.py`'s header already records what that costs --
-- a hardcoded copy of the arena address in `server/fk33_seam.h` became "a
-- FOURTH model of the same address".
--
-- So: this counts.  The adapter addresses.
--
-- ======================================================================
-- IT ADVANCES ON RETIRE, NOT ON ISSUE, AND THAT IS THE DESIGN
-- ======================================================================
-- `a_desc_adapter:200-212` records a hazard against its own `u_index` port:
--
--     HAZARD, NOT YET A BUG, and it becomes one the moment `u_index` is
--     driven from D. [...] It is safe TODAY only because `u_index` is a
--     top-level input [...] When it is wired [...] it must be sampled one
--     cycle later, the same way `ep_take` defers the epoch.
--
-- That is a real hazard for any driver that changes `u_index` near `u_start`.
-- This counter DOES NOT: it advances on `job_retire`, which is the ack of a
-- COMPLETED job, so the index is constant from before one `u_start` until
-- after that job's completion has been acknowledged.  Sampling it at
-- `u_start` and sampling it one cycle later therefore give the SAME value,
-- and the adapter's deferral question does not arise rather than being
-- answered carefully.
--
-- This is the cheaper half of that hazard: the epoch genuinely must be
-- deferred, because D changes it per issue. The index need not be, because
-- nothing requires it to change there.
--
-- ======================================================================
-- WHAT IT DOES NOT DECIDE
-- ======================================================================
-- It does not know which D steps are A jobs.  Something that decodes the
-- program must pulse `job_retire` once per A job, in the order the host laid
-- the descriptors out.  That order is the ordering contract in its entirety,
-- and descriptor version 2 is what makes breaking it loud: the descriptor
-- stamps its own index and `matvec_int4_desc_axi` refuses a disagreement with
-- EC_DESC / ED_JOB_INDEX before starting the array.  See
-- `rtl/matvec_int4_desc_pkg.vhd` and `docs/2026-08-28_matvec-descriptor-format.md`.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity a_job_counter is
  generic(
    -- A jobs in one token program.  311 at the 9B shape.  Must match
    -- `a_desc_adapter`'s N_JOBS, which is what actually bound-checks the
    -- index; this one bounds the COUNT so an overrun is reported here too,
    -- where the cause is, rather than only where it lands.
    N_JOBS : positive := 311
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- Reload the count to zero at the start of each token.
    --
    -- A LEVEL OR A PULSE, EITHER IS ACCEPTED, and that is deliberate: the
    -- signal this is driven from is `seq_desc_fetch`'s `go`, whose own header
    -- says in as many words *"`go` is a level or a pulse; it is only read in
    -- S_IDLE"* (seq_desc_fetch.vhd:166).  D can afford to read a level because
    -- it leaves S_IDLE immediately; a counter that reloaded on the LEVEL would
    -- be pinned at zero for as long as the host held `go` high, and EVERY A
    -- job of that token would fetch descriptor 0 -- a well-formed descriptor
    -- for the wrong step, which is the exact failure this whole mechanism
    -- exists to prevent.
    --
    -- So the reload is on the RISING EDGE.  Taking the weaker contract here
    -- costs one flip-flop and means this module cannot be broken by a caller
    -- that is behaving correctly by D's rules.
    --
    -- PER TOKEN, NOT PER PROGRAM.  The A descriptor table belongs to the
    -- token PROGRAM and the program is the same every token; only the data
    -- changes.  A count that ran monotonically across tokens would index past
    -- the end of the table on token 1 and the adapter would refuse -- or, if
    -- N_JOBS were ever raised, would fetch a well-formed descriptor for a step
    -- that does not exist.
    tok_start : in std_logic;

    -- One pulse per A job RETIRED, in the host's layout order.  See the
    -- header for why this is retire and not issue.
    job_retire : in std_logic;

    -- The same number in the two widths its two consumers declare:
    -- `a_desc_adapter.u_index` is 16 bits, and the version-2 descriptor field
    -- compared by `matvec_int4_desc_axi.job_index` is 32.  Emitted as two
    -- ports rather than resized at each call site so there is one place where
    -- the widths are reconciled.
    u_index   : out std_logic_vector(15 downto 0);
    job_index : out std_logic_vector(31 downto 0);

    -- Sticky until the next `tok_start` or `rst`.  Raised by a retire PAST
    -- the last legal job; the count does NOT wrap, because a wrapped index is
    -- a valid descriptor for the wrong step, which is the failure the whole
    -- mechanism exists to prevent.
    err : out std_logic
  );
end entity;

architecture rtl of a_job_counter is
  -- A REFUSAL THAT RUNS DURING ELABORATION.  An out-of-range `natural`, not an
  -- assert, because Vivado silently ignores `assert ... severity failure` in
  -- synthesis.
  --
  -- MEASURED, so the claim is not overstated: GHDL reports these as
  -- `bound check failure at <file>:<line>` and does NOT print the constant's
  -- name, so the name serves whoever OPENS the file at that line rather than
  -- appearing in the log.
  --
  -- `u_index` is 16 bits, and the count reaches N_JOBS (one past the last
  -- job) before `err` is raised, so N_JOBS itself must be representable.
  constant bad_n_jobs_exceeds_u_index_width : natural := 65535 - N_JOBS;

  signal n   : natural range 0 to N_JOBS := 0;
  signal ovf : std_logic := '0';
  -- `tok_start` delayed one cycle, so the reload is edge-triggered.  See the
  -- port comment: the driver is allowed to hold it high.
  signal tok_d  : std_logic := '0';
  signal tok_re : std_logic;
begin
  tok_re <= tok_start and not tok_d;
  u_index   <= std_logic_vector(to_unsigned(n, 16));
  job_index <= std_logic_vector(to_unsigned(n, 32));
  err       <= ovf;

  p : process(clk) is
  begin
    if rising_edge(clk) then
      tok_d <= tok_start;
      if rst = '1' then
        n <= 0; ovf <= '0'; tok_d <= '0';
      elsif tok_re = '1' then
        -- Clears `err` as well as the count: one bad token must not poison
        -- every token after it.
        n <= 0; ovf <= '0';
      elsif job_retire = '1' then
        if n >= N_JOBS then
          ovf <= '1';
        else
          n <= n + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
