-- rtl/a_desc_ptr.vhd -- where a D step's subsystem A descriptor lives.
--
-- D's 64-byte step header has no field pointing at A's per-job data, and
-- `job_ordinal` cannot be that field: it is 8 bits, so it cannot address the
-- 311 A jobs of the 9B token program, and it already means the per-kind layer
-- index (defect ORD-1, docs/debugging/2026-08-29_ordinal-two-meanings.md).
-- `tools/gen_layer_program.py` states the gap outright: "which mechanism
-- delivers them to the card is an open integration decision, not a
-- derivation."
--
-- THE DECISION, taken 2026-09-03: the card COUNTS.  This module holds the
-- count of A jobs dispatched so far in the current token and emits
--
--     desc_ptr  = BASE + n * STRIDE
--     job_index = n
--
-- `job_index` goes to `matvec_int4_desc_axi`'s port of the same name, which
-- compares it against the descriptor's OWN claim in version-2 extension word 3
-- and refuses a mismatch before starting the array.  That is the whole reason
-- this is safe: an arithmetic pointer imposes an ORDERING CONTRACT on the
-- host, and an unchecked ordering contract produces a wrong token rather than
-- an error, because a well-formed descriptor for the wrong step passes every
-- other check in the descriptor plane.
--
-- WHY THE COUNTER RESETS PER TOKEN AND NOT PER PROGRAM.  The A descriptor
-- table is a property of the token PROGRAM, and the program is the same for
-- every token; only the data changes.  A counter that ran monotonically across
-- tokens would walk off the end of the table on token 1 and read whatever
-- follows it.  So `tok_start` reloads it, and running past `N_JOBS` within one
-- token raises `err` rather than wrapping.
--
-- WHAT THIS MODULE DOES NOT DECIDE.  It does not know which steps are A jobs.
-- Something that decodes the program has to pulse `a_dispatch`, once per A job,
-- in the order the host laid the descriptors out.  That pulse is the ordering
-- contract in its entirety, and the v2 index check is what makes breaking it
-- loud.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity a_desc_ptr is
  generic(
    ADDR_W : positive := 40;
    -- Bytes between consecutive A descriptors.  Must be a multiple of the
    -- descriptor plane's DESC_ALIGN (DESC_MAXB*AXI_DW/8, 512 at the FK33), or
    -- every pointer this module emits after the first is refused EC_ALIGN.
    STRIDE : positive := 512;
    DESC_ALIGN : positive := 512;
    -- A jobs in one token program.  311 at the 9B shape.  Exceeding it is an
    -- error and not a wrap: a wrapped pointer is a VALID descriptor for the
    -- wrong step, which is the failure this whole mechanism exists to make
    -- impossible.
    N_JOBS : positive := 311
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- one pulse at the start of each token: reload the count to zero
    tok_start  : in std_logic;
    -- one pulse per A job dispatched, in the host's layout order
    a_dispatch : in std_logic;

    -- byte address of the A descriptor table.  Latched on `tok_start`, so it
    -- cannot move under a token that has already begun.
    base : in std_logic_vector(ADDR_W-1 downto 0);

    desc_ptr  : out std_logic_vector(ADDR_W-1 downto 0);
    job_index : out std_logic_vector(31 downto 0);
    err       : out std_logic
  );
end entity;

architecture rtl of a_desc_ptr is
  -- REFUSALS THAT RUN DURING ELABORATION.  Out-of-range `natural`s, not
  -- asserts, because Vivado silently ignores `assert ... severity failure` in
  -- synthesis.
  --
  -- MEASURED, so the claim is not overstated: GHDL reports these as
  -- `bound check failure at <file>:<line>` and does NOT print the constant's
  -- name, so the name is a diagnostic for whoever OPENS the file at that line
  -- rather than one that appears in the log. That is still worth the naming
  -- effort -- the line number alone is useless six months later -- but it is
  -- not the self-describing error message the idiom is sometimes claimed to
  -- give.
  constant bad_stride_not_desc_aligned : natural := 0 - (STRIDE mod DESC_ALIGN);
  -- The whole table's offset must fit BELOW the top address bit.  Checked
  -- here and not left to the adder, because an ADDR_W-bit wrap produces a
  -- perfectly plausible pointer rather than a fault.  Expressed through
  -- clog2 so it holds at any ADDR_W without ever evaluating 2**ADDR_W, which
  -- overflows a VHDL integer at 32 and above.
  constant bad_table_exceeds_addr_space : natural :=
    (ADDR_W - 1) - clog2(N_JOBS * STRIDE);

  signal n     : natural range 0 to N_JOBS := 0;
  signal ovf   : std_logic := '0';
  signal b_q   : unsigned(ADDR_W-1 downto 0) := (others => '0');
begin
  -- Combinational, so the pointer is valid in the same cycle the fetch is
  -- programmed.  The multiply is by an elaboration CONSTANT, so it is shifts
  -- and adds and not a DSP.
  desc_ptr  <= std_logic_vector(b_q + to_unsigned(n * STRIDE, ADDR_W));
  job_index <= std_logic_vector(to_unsigned(n, 32));
  err       <= ovf;

  p : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        n <= 0; ovf <= '0'; b_q <= (others => '0');
      elsif tok_start = '1' then
        -- LATCH THE BASE HERE.  Reading it live would let it move under a
        -- token already in flight, and every pointer after the move would be
        -- well-formed and wrong.
        n   <= 0;
        ovf <= '0';
        b_q <= unsigned(base);
      elsif a_dispatch = '1' then
        if n >= N_JOBS then
          -- One dispatch PAST the last legal job.  `err` names that dispatch,
          -- not the last legal one.  It does not wrap: a wrapped pointer is a
          -- VALID descriptor for the wrong step, which is the exact failure
          -- this mechanism exists to make impossible.
          ovf <= '1';
        else
          n <= n + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
