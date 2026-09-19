-- sim/tb_fk33_seam_wdog.vhd
-- THE SEAM BENCH AT A WATCHDOG EVERY TOKEN TRIPS.  Same pattern as
-- sim/tb_llama_top_seq.vhd: sim/regress.sh keys a test by NAME and cannot run
-- one testbench at two generic sets, so a configuration that has to be gated
-- gets its own top level, and every check stays in sim/tb_fk33_seam.vhd.
--
-- WHAT THIS CONFIGURATION ASKS.  With WDOG_LIMIT = 64, step 0 -- a VEC_NORM
-- over `hidden` elements -- cannot complete, so subsystem D raises `err`
-- (ERR_WDOG), spends a second watchdog window in S_ABORT draining the unit,
-- and only THEN raises `tok_done`.  That is the one D error whose `err` and
-- `tok_done` are separated by hundreds of cycles, and it is the shape the
-- seam had never been driven with: every other error path reaches S_TOKDONE
-- within a cycle of raising `err`.
--
-- MEASURED ON SILICON 2026-09-18, the first GO on the composed card
-- (docs/debugging/2026-09-18_first-token-on-silicon-stops-at-step-7.md): the
-- seam acked at the `err` instant, D's `tok_done` was never acknowledged, and
-- EVERY LATER GO was accepted by the seam and ignored by D -- reported one
-- cycle later as the previous token's error with CYCLES = 1.  One watchdog
-- made the card unusable until reset.
--
-- TEETH.  Against the seam as it was (rtl/fk33_seam.vhd before the fix in
-- the same commit as this file): token 0 passes every check, then P7 fires
-- (`tok_done` still high), and token 1 reports CYCLES = 1 -- the silicon
-- signature, reproduced.  Against the fixed seam: three tokens, each ending
-- in ERR_WDOG with CYCLES >= 64 and `tok_done` released.  Recorded in the
-- WORKLOG entry for the fix.
--
-- NTOK = 3, not 2: token 1 is the first GO after an unacknowledged
-- completion, and token 2 shows the recovery is not a one-off.

library ieee;
use ieee.std_logic_1164.all;

entity tb_fk33_seam_wdog is
end entity;

architecture tb of tb_fk33_seam_wdog is
begin
  u : entity work.tb_fk33_seam
    generic map(
      NTOK        => 3,
      WDOG_LIMIT  => 64,
      EXPECT_WDOG => true,
      -- No values are produced, so the landmarks are at their sentinels;
      -- EXPECT_WDOG skips P1 and P5 outright and this is belt and braces.
      EXP_X0      => integer'low,
      EXP_XSUM    => -1);
end architecture;
