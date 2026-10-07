-- rtl/a_util_ctr.vhd -- per-port read-beat counters for subsystem A.
-- Jungle Cat engine composition, Task 1, 2026-10-07.
--
-- WHAT IT MEASURES.  For each of NP read ports, the number of R-channel
-- handshakes (RVALID and RREADY, supplied by the instantiator as `rbeat`)
-- that happened while `in_job` was high; and, as counter index NP, the
-- number of cycles `in_job` was high.  Beats per port divided by job cycles
-- is that port's fraction of its one-beat-per-cycle ceiling, in THIS clock's
-- cycles.  So `clk` must be the clock the R handshakes are synchronous to.
--
-- 48 BITS.  At 450 MHz a 2**32 counter wraps in 9.5 s, which one long
-- prefill exceeds; 2**48 is 7.2 days at the same rate.
--
-- READ PORT.  `rd_data` is REGISTERED and changes only on a cycle with
-- `rd_en` high.  A read with rd_hi = '0' returns counter rd_idx bits [31:0]
-- and, in the same edge, copies bits [47:32] into `hi_q`; a read with
-- rd_hi = '1' returns `hi_q` zero-extended.  Low then high is therefore one
-- atomic 48-bit sample even while the counter keeps running.  An index above
-- NP reads zero.
--
-- INIT_HI is TEST ONLY: it starts counter 0 at 2**32 - 3 so a bench reaches
-- the carry into bit 32 in a few cycles.  Leave it false everywhere else.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity a_util_ctr is
  generic(
    NP      : positive := 27;
    INIT_HI : boolean  := false
  );
  port(
    clk, rst : in  std_logic;
    clr      : in  std_logic := '0';     -- clears the counters only
    in_job   : in  std_logic;                        -- '1' while an A job runs
    rbeat    : in  std_logic_vector(NP-1 downto 0);  -- RVALID and RREADY per port
    rd_idx   : in  unsigned(6 downto 0);  -- 0..NP-1 beats, NP job cycles
    rd_hi    : in  std_logic;             -- '0' reads [31:0] and latches [47:32]
    rd_en    : in  std_logic;
    rd_data  : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of a_util_ctr is
  -- an index wider than rd_idx could not be read back
  constant NP_FITS : natural range 0 to 127 := NP;

  type cnt_arr is array (0 to NP) of unsigned(47 downto 0);

  function init_cnt return cnt_arr is
    variable r : cnt_arr := (others => (others => '0'));
  begin
    if INIT_HI then r(0) := x"0000FFFFFFFD"; end if;
    return r;
  end function;

  signal cnt  : cnt_arr := init_cnt;
  signal hi_q : std_logic_vector(15 downto 0) := (others => '0');
  signal rd_q : std_logic_vector(31 downto 0) := (others => '0');
begin
  rd_data <= rd_q;

  count : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or clr = '1' then
        cnt <= init_cnt;
      elsif in_job = '1' then
        for i in 0 to NP-1 loop
          if rbeat(i) = '1' then cnt(i) <= cnt(i) + 1; end if;
        end loop;
        cnt(NP) <= cnt(NP) + 1;
      end if;
    end if;
  end process;

  rd : process(clk)
    variable ix : natural;
  begin
    if rising_edge(clk) then
      -- `clr` deliberately does NOT reach hi_q or rd_q: a clear between a
      -- low read and its high read must not tear the sample, and must not
      -- move rd_data under a read that has already been answered.
      if rst = '1' then
        hi_q <= (others => '0');
        rd_q <= (others => '0');
      elsif rd_en = '1' then
        ix := to_integer(rd_idx);
        if rd_hi = '1' then
          rd_q <= x"0000" & hi_q;
        elsif ix <= NP then
          rd_q <= std_logic_vector(cnt(ix)(31 downto 0));
          hi_q <= std_logic_vector(cnt(ix)(47 downto 32));
        else
          rd_q <= (others => '0');
          hi_q <= (others => '0');
        end if;
      end if;
    end if;
  end process;
end architecture;
