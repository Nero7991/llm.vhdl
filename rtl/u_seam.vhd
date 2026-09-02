-- rtl/u_seam.vhd
-- THE GENERIC D-TO-UNIT SEAM.  TRACK CARDTOP, 2026-09-02.
--
-- Subsystems B (`gdn_block`) and C (`attn_block`) are NEARLY the same shape,
-- and the differences are exactly what this file is parameterised over.
-- MEASURED from the RTL, not assumed:
--   B  rtl/gdn_block.vhd:625   `done <= ec_done`, a PULSE from a submodule.
--                              THREE error bits (err_conv, err_g, err_se).
--                              No ack input; nothing to acknowledge.
--   C  rtl/attn_block.vhd:1799 `done` is a LEVEL held until `done_ack`
--                              (its own "RULE 1: done is HELD until acked"),
--                              and ONE `err`.
-- So `unit_done` is latched -- covering a pulse -- and `unit_ack` is emitted
-- for a unit that holds.  A unit with no ack input simply leaves it open.
-- Subsystem A does NOT use this: it has a descriptor plane and an AXI-Lite
-- control map, and its seam is rtl/a_desc_adapter.vhd.
--
-- THE EPOCH IS LATCHED ONE CYCLE AFTER ISSUE, NOT AT ISSUE.  This is the
-- whole reason the file has an S_PULSE state rather than driving the unit
-- straight out of S_IDLE.  `job_epoch <= epoch_r` (seq_desc_fetch.vhd:932)
-- and `epoch_r <= epoch_r + 1` fires ON the issue edge (:790), so during the
-- issue cycle `job_epoch` still carries the OLD value, while S_COMPLETE
-- compares the echo against the NEW one (:834).  A seam that latched at issue
-- would be off by one on EVERY job and D would reject every completion as
-- stale.  llama_top's seven proven adapters all avoid this by latching on
-- `job_issue`, which seq_desc_fetch raises one cycle later; latching in
-- S_PULSE is the same instant reached without adding a port.
--
-- WHAT D REQUIRES (rtl/seq_desc_fetch.vhd:238-246):
--   * u_start is a LEVEL held until the unit shows ready; D refuses to issue
--     while u_done is high.  `u_ready` is synthesised from the idle state.
--   * u_done is a LEVEL held until u_ack.
--   * u_done_epoch must carry the epoch D bumped at S_ISSUE, or D rejects the
--     completion as stale at S_COMPLETE.  LATCHED, never generated: an epoch
--     computed here would agree with itself and defeat the check it feeds.
--
-- `unit_done` IS LATCHED WHILE RUNNING, so it works whether the unit emits a
-- one-cycle pulse or a held level.  gdn_block's own header records that
-- segment completion "is no longer `o_done`" and that its FSM captures
-- `o_done` into a register "because it is a pulse" -- so a seam that only
-- sampled a level would miss it, and one that only caught an edge would miss
-- a level.  Latching covers both and costs one flip-flop.
--
-- THE STALE-DONE HAZARD IS ASSERTED, NOT ASSUMED.  If a unit still asserts
-- `done` from its previous job at the instant this seam issues the next one,
-- the seam would take that as the new job's completion and D would advance a
-- job early.  Nothing in this file can prevent that; it can only refuse to
-- hide it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity u_seam is
  generic (
    EPOCH_W : positive := 4          -- must match seq_desc_fetch's EPOCH_W
  );
  port (
    clk          : in  std_logic;
    rstn         : in  std_logic;

    -- the D side
    u_start      : in  std_logic;
    u_ready      : out std_logic;
    u_done       : out std_logic;
    u_err        : out std_logic;
    u_ack        : in  std_logic;
    job_epoch    : in  unsigned(EPOCH_W-1 downto 0);
    u_done_epoch : out std_logic_vector(EPOCH_W-1 downto 0);

    -- the unit side
    unit_start   : out std_logic;    -- ONE cycle
    unit_busy    : in  std_logic;
    unit_done    : in  std_logic;    -- pulse or level; latched either way
    unit_ack     : out std_logic;    -- one cycle, for a unit that HOLDS done
    unit_err     : in  std_logic := '0'  -- OR the unit's error bits outside
  );
end entity;

architecture rtl of u_seam is
  type st_t is (S_IDLE, S_PULSE, S_RUN, S_DONE);
  signal st    : st_t := S_IDLE;
  signal ep_q  : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  signal err_q : std_logic := '0';
begin

  u_ready      <= '1' when st = S_IDLE else '0';
  u_done       <= '1' when st = S_DONE else '0';
  -- Latched with the completion, for the same reason seq_desc_fetch latches
  -- its own copy (:643): a unit that clears `err` when it returns to idle
  -- must not be able to erase what it already reported.
  u_err        <= err_q;
  unit_start   <= '1' when st = S_PULSE else '0';
  unit_ack     <= '1' when st = S_DONE and u_ack = '1' else '0';
  u_done_epoch <= std_logic_vector(ep_q);

  process(clk) is
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        st <= S_IDLE; ep_q <= (others => '0'); err_q <= '0';
      else
        case st is
          when S_IDLE =>
            if u_start = '1' then
              err_q <= '0';
              st    <= S_PULSE;
            end if;

          when S_PULSE =>
            -- exactly one cycle of unit_start, and the epoch is taken HERE,
            -- one cycle after issue, where epoch_r has already been bumped.
            -- LATCHED, never generated: an epoch computed here would agree
            -- with itself and defeat the staleness check it feeds.
            ep_q <= job_epoch;
            st   <= S_RUN;

          when S_RUN =>
            if unit_done = '1' then
              err_q <= unit_err;
              st    <= S_DONE;
            end if;

          when S_DONE =>
            -- HOLD until D consumes it.  Leaving early would let the next
            -- job start on top of a completion D has not seen.
            if u_ack = '1' then
              st <= S_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

  -- Simulation guards.  Vivado ignores `severity failure` in synthesis, so
  -- these bound what the seam ASSUMES rather than what it enforces.
  guards : process(clk) is
  begin
    if rising_edge(clk) then
      if rstn = '1' then
        -- A completion standing at issue time would be read as this job's.
        assert not (st = S_PULSE and unit_done = '1')
          report "u_seam: the unit still asserts done as the next job is "
               & "issued; that completion would be credited to the new job "
               & "and D would advance a job early"
          severity failure;
        -- Issuing to a unit that is still working is the same defect seen
        -- from the other side.
        assert not (st = S_PULSE and unit_busy = '1')
          report "u_seam: the unit is still busy as the next job is issued"
          severity failure;
      end if;
    end if;
  end process;

end architecture;
