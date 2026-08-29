-- ===========================================================================
-- hsk_chk -- the done / done_ack COMPLETION HANDSHAKE, checked as a property
--            rather than inferred from whether the bench deadlocked.
--
-- WHY THIS FILE EXISTS.
--
-- MEASURED 2026-08-29 (TRACK ATTN-HARNESS, then re-measured here): ONE
-- mutation is an ABORT in FIVE separate mutation harnesses and is detected by
-- no check in any of them.  "An explicit `done_r` clear inside the ack branch"
-- is sim/mutate_attn_emit.sh E18, sim/mutate_attn_gate.sh M21,
-- sim/mutate_attn_twiddle.sh N19, sim/mutate_attn_softmax.sh M5 and
-- sim/mutate_attn_recip.sh N14.  Five units share one handshake idiom, five
-- benches shared one blind spot, and the ONLY reason anybody noticed is that
-- this particular member of the class happens to HANG: the clear is a later
-- assignment that wins, so with done_ack tied high `done` never rises at all
-- and every bench's `while done /= '1' loop wait until rising_edge(clk)` waits
-- forever.
--
-- A DEADLOCK IS NOT A DETECTION.  It is the absence of one.  Nothing was
-- learned about what the checker would have said, and a sibling defect that
-- did not hang would have been invisible.  That sibling is not hypothetical:
-- see clause 3 below and sim/mutate_attn_emit.sh's H-row.
--
-- THE CONTRACT, derived from the RTL and not from a sketch.  Read off
-- rtl/attn_emit.vhd's S_DONE branch, which is the shape all five units share:
--
--     when S_DONE =>
--       if <output drained> then
--         done_r <= '1';
--         if done_ack = '1' then
--           state <= S_IDLE;          -- and NOT done_r <= '0' here
--         end if;
--       end if;
--       ...
--     if state /= S_DONE then done_r <= '0'; end if;
--
-- so the four things a consumer is entitled to are:
--
--   1. LIVENESS.  Once a layer has been accepted, `done` eventually rises.
--      Bounded here by DEADLINE cycles, so the failure is a NAMED contract
--      violation reported by the bench instead of a wedge to --stop-time.
--      Be honest about what this clause is: it is still a timeout.  It says
--      the unit never completed; it does not say the answer was wrong.  Its
--      value is that the verdict now comes from the bench and names the
--      contract, not from the simulator running out of clock.
--
--   2. HOLD (RULE 1).  `done`, once raised, stands until it is ACKED.  Stated
--      as: `done` may only fall on an edge at or after one where `done` and
--      `done_ack` were BOTH high.  A consumer busy at that instant must not
--      lose the layer.  Vacuous when the ack is tied high, which is exactly
--      why the degenerate configuration is not strictly stronger than the
--      shipped one.
--
--      DO NOT restate this as "done high and ack low at edge k implies done
--      high at edge k+1".  MEASURED 2026-08-29: that is what the first draft
--      said, and it FALSE-FIRES on the CLEAN rtl/attn_rope.vhd in
--      configurations A and C.  sim/tb_attn_rope.vhd acks with a ONE-CYCLE
--      PULSE (`done_ack_p <= '1'; cyc(1); done_ack_p <= '0';`), so the ack is
--      already back low on the edge where done falls, and the draft read a
--      correct handshake as a violation.  An ack is an EVENT to be remembered,
--      not a level to be required.  A property that fires on the clean design
--      is worth exactly as much as a configuration that wedges on it.
--
--   3. RELEASE.  The ack must be OBSERVABLE IN `done`.  Once a rising edge is
--      seen with `done` and `done_ack` both high, `done` must fall within
--      REL_MAX further edges.  This is the clause that catches the member of
--      the class that does NOT hang -- a unit that raises done, holds it, and
--      then ignores the ack entirely, so the next layer starts against a done
--      that is already high.  No amount of polling for `done = '1'` can see
--      that, because the poll is satisfied by the stale level.
--
--   4. NO SPURIOUS DONE.  `done` must be low at the edge on which a new layer
--      is accepted.  A layer that has not run cannot be complete.  This is the
--      same defect as 3 seen from the other end, and it is kept separate
--      because a unit can satisfy 3 by falling late and still be high at the
--      next start.
--
-- EVERY CLAUSE IS `severity failure`, DELIBERATELY.  sim/mutverdict.py checks
-- for the bench's PASS line FIRST, so a clause reported at severity error
-- would be followed by the bench's own PASS and the mutant would score as a
-- SURVIVOR with the violation printed above it.  Failure also stops a wedged
-- run at once instead of burning the whole --stop-time.
--
-- THIS FILE IS PART OF THE CHECKER, NOT PART OF THE DESIGN.  Name it to
-- sim/mutverdict.py as an extra bench file (the harnesses do), or a clause
-- firing is classified ABORT:DUTASSERT instead of KILLED.
--
-- NOTE_MAX = true makes it print each new worst start-to-done latency at
-- severity note.  That is how DEADLINE was set for each bench: run once with
-- NOTE_MAX true in the slowest configuration, read the largest number, and
-- give the generic several times that.  It is false in the committed benches
-- because it is measurement scaffolding, not a check.
-- ===========================================================================
library ieee;
use ieee.std_logic_1164.all;

entity hsk_chk is
  generic (
    -- Appears in every message.  Five benches instantiate this entity and a
    -- bare "done fell before it was acked" says nothing about which unit.
    NAME     : string  := "unit";
    -- Cycles from an accepted layer to `done` rising.  MEASURE it, do not
    -- guess it; see NOTE_MAX above.
    DEADLINE : natural := 100000;
    -- Cycles from the acked edge to `done` falling.  MEASURED on all five
    -- clean units in all three configurations of their harnesses: the worst
    -- ack-to-release is 2 EVERYWHERE (1 in the degenerate configuration, where
    -- the ack already stands when done rises).  That is structural, not a
    -- timing accident -- the ack edge sets state <= S_IDLE, the next edge
    -- clears done_r, and the edge after that is the first that reads done low.
    -- 3 therefore permits a release twice as slow as anything the design does.
    --
    -- DO NOT RAISE THIS TO 4 "for slack".  MEASURED 2026-08-29: at 4,
    -- sim/mutate_attn_softmax.sh's H1 -- the non-hanging sibling, whose done is
    -- released by the NEXT head's start rather than by the ack -- releases at
    -- age 5 and SURVIVES all three configurations with the property in place.
    -- It is killed at 3.  The other four units release H1's done never at all,
    -- so they are insensitive to the value; softmax is the one that pins it.
    REL_MAX  : natural := 3;
    NOTE_MAX : boolean := false
  );
  port (
    clk      : in std_logic;
    rst      : in std_logic;
    -- The instant a new layer is ACCEPTED by the unit: cfg_taken where the
    -- unit has one, the input accept pulse where it does not.  Re-arming on
    -- every element accept is harmless -- it only makes clause 1 measure
    -- "cycles since the last accepted input", which is stricter, not looser.
    start_ev : in std_logic;
    done     : in std_logic;
    ack      : in std_logic
  );
end entity;

architecture sim of hsk_chk is
begin
  p : process(clk)
    variable armed     : boolean := false;
    variable age       : natural := 0;
    variable worst     : natural := 0;
    variable acked     : boolean := false;
    variable rel_age   : natural := 0;
    variable worst_rel : natural := 0;
    variable prev_done : std_logic := '0';
  begin
    if rising_edge(clk) then
      if rst = '1' then
        armed := false; acked := false; age := 0; rel_age := 0;
        prev_done := '0';
      else

        -- ---- clause 2: HOLD -------------------------------------------
        -- `acked` is read here BEFORE clause 3 updates it below, so on the
        -- edge where done falls it still carries whether an ack was ever
        -- observed while done stood.  That ordering is the whole clause.
        if prev_done = '1' and done /= '1' and not acked then
          report "HANDSHAKE HOLD [" & NAME & "]: done fell without ever having "
               & "been acked -- no edge had done and done_ack both high.  "
               & "RULE 1 says done is HELD until it is acked, never pulsed: a "
               & "consumer busy at that instant loses the layer outright"
            severity failure;
        end if;

        -- ---- clause 4: NO SPURIOUS DONE -------------------------------
        if start_ev = '1' and done = '1' then
          report "HANDSHAKE SPURIOUS [" & NAME & "]: done was ALREADY HIGH at "
               & "the edge a new layer was accepted.  Either the previous "
               & "layer's done was never released by its ack, or this layer "
               & "is being reported complete before it has run.  A consumer "
               & "that polls for done = '1' is satisfied by the stale level "
               & "and reads the PREVIOUS layer's result" severity failure;
        end if;

        -- ---- clause 1: LIVENESS ---------------------------------------
        if done = '1' then
          if armed and age > worst then
            worst := age;
            if NOTE_MAX then
              report "hsk_chk [" & NAME & "]: new worst start-to-done latency "
                   & integer'image(worst) & " cycles" severity note;
            end if;
          end if;
          armed := false; age := 0;
        elsif start_ev = '1' then
          armed := true; age := 0;
        elsif armed then
          age := age + 1;
          if age > DEADLINE then
            armed := false;
            report "HANDSHAKE LIVENESS [" & NAME & "]: done did not rise "
                 & "within " & integer'image(DEADLINE) & " cycles of the "
                 & "layer being accepted.  THIS IS A TIMEOUT, reported by the "
                 & "bench and named: the unit never completed, which says "
                 & "nothing about whether its values would have been right.  "
                 & "The usual cause is a done_r that is cleared in the same "
                 & "cycle it is raised, which is invisible whenever the ack "
                 & "is late and fatal whenever it is early"
              severity failure;
          end if;
        end if;

        -- ---- clause 3: RELEASE ----------------------------------------
        if acked then
          if done = '0' then
            acked := false;
            if rel_age + 1 > worst_rel then
              worst_rel := rel_age + 1;
              if NOTE_MAX then
                report "hsk_chk [" & NAME & "]: new worst ack-to-release "
                     & integer'image(worst_rel) & " cycles" severity note;
              end if;
            end if;
          else
            rel_age := rel_age + 1;
            if rel_age > REL_MAX then
              acked := false;
              report "HANDSHAKE RELEASE [" & NAME & "]: done was still high "
                   & integer'image(REL_MAX) & " cycles after the edge on "
                   & "which done and done_ack were both high.  The ack is not "
                   & "observable in done, so a consumer cannot tell this "
                   & "layer's completion from the next one's" severity failure;
            end if;
          end if;
        elsif done = '1' and ack = '1' then
          acked := true; rel_age := 0;
        end if;

        prev_done := done;
      end if;
    end if;
  end process;
end architecture;
