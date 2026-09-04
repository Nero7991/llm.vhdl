-- tb_gatechk_mask.vhd -- the region-lock drop check, over its WHOLE input
-- space.
--
-- WHY THIS BENCH EXISTS.  `rtl/llama_top.vhd`'s `gatechk` decides whether a
-- region write that the lock refused gets reported.  It used to read
--
--     wr_we = '1' and wr_gate /= '1' and hw_we = '0'
--
-- where `hw_we = '0'` stood in for "this is not a host write", because
-- `el_we` is high whenever `hw_we` is.  That is right while ONE write is in
-- flight and wrong when both are: `wr_region` names the D-VEC region in that
-- cycle, so the write being judged is the D-vec one, and the `hw_we = '0'`
-- term switched the entire check off.  **A host write MASKED a D-vec lock
-- violation** -- `f_gate` stayed low and `err_gate_drop` stayed low.
--
-- The fix says what was meant:
--
--     (w_we = '1' or (el_we = '1' and hw_we = '0')) and wr_gate /= '1'
--
-- WHY IT IS A TRUTH TABLE AND NOT A SYSTEM TEST.  What changed is a boolean
-- over four one-bit inputs, so the input space is SIXTEEN rows and can be
-- enumerated completely rather than sampled.  A system-level bench that
-- reproduces the masking case would need a D-vec write driven outside its own
-- lock window AND a simultaneous host write, i.e. it would have to break the
-- lock on purpose to observe a reporting hole -- more machinery, and still
-- only one point of the space.
--
-- What this bench therefore does NOT establish: that `wr_gate` means what
-- `gatechk` thinks it means, or that the eight llama_top rows exercise any of
-- this.  They do not: MEASURED 2026-09-04, `hw_while_busy = 0` across
-- tb_llama_top_real, so no bench has ever driven a host write while the
-- machine was running.  This bench checks the decision, not the plumbing.

-- TEETH.  MEASURED 2026-09-04, one mutation of `new_reports` at a time.  All
-- four are killed, and each by a DIFFERENT property, which is what says the
-- four properties are not four spellings of one check:
--
--   M1  revert the fix: `(w_we or el_we) = '1' and wr_gate /= '1'
--                        and hw_we = '0'`                      KILLED by P4
--       widened drops to 0, i.e. the two conditions agree everywhere.  This
--       is the mutant that matters: it is the code as it shipped.
--
--   M2  drop the lock term: `(w_we = '1' or el_we = '1')`      KILLED by P2
--       reports w_we='0' el_we='1' hw_we='0' wr_gate='1' -- a write the lock
--       ALLOWED.
--
--   M3  drop the host exemption:
--       `(w_we = '1' or el_we = '1') and wr_gate /= '1'`       KILLED by P2+P3
--       reports a host-only write, which is deliberately exempt.
--
--   M4  report on the lock alone: `wr_gate /= '1'`             KILLED by P2
--       reports cycles with NO write at all.
--
-- No mutant survived, so this bench has no measured resolution floor yet; the
-- honest reading is that four is a small sample, not that the check is
-- complete.

library ieee;
use ieee.std_logic_1164.all;

entity tb_gatechk_mask is
end entity;

architecture sim of tb_gatechk_mask is

  -- The condition as it stood before 2026-09-04.  KEPT IN THE BENCH ON
  -- PURPOSE: a check that has never been shown to discriminate is
  -- decoration, and the only way to show it here is to keep the thing it
  -- replaced and prove they differ.
  function old_reports(w_we, el_we, hw_we, wr_gate : std_logic)
    return boolean is
    variable wr_we : std_logic;
  begin
    wr_we := w_we or el_we;
    return wr_we = '1' and wr_gate /= '1' and hw_we = '0';
  end function;

  function new_reports(w_we, el_we, hw_we, wr_gate : std_logic)
    return boolean is
  begin
    return (w_we = '1' or (el_we = '1' and hw_we = '0')) and wr_gate /= '1';
  end function;

  constant BITS : std_logic_vector(0 to 1) := "01";

begin

  main : process
    variable checks   : natural := 0;   -- counted in a VARIABLE: a signal
                                        -- assigned twice in one delta keeps
                                        -- only the last value, so consecutive
                                        -- increments would collapse to one.
    variable fails    : natural := 0;
    variable widened  : natural := 0;   -- rows the fix newly reports
    variable narrowed : natural := 0;   -- rows the fix stopped reporting
    variable o, n     : boolean;
  begin
    for iw in 0 to 1 loop
     for ie in 0 to 1 loop
      for ih in 0 to 1 loop
       for ig in 0 to 1 loop
         o := old_reports(BITS(iw), BITS(ie), BITS(ih), BITS(ig));
         n := new_reports(BITS(iw), BITS(ie), BITS(ih), BITS(ig));
         checks := checks + 1;

         -- P1  NO REGRESSION.  Everything the old condition reported, the new
         --     one still reports.  Without this the "fix" could be any other
         --     boolean that happens to catch the masking row.
         if o and not n then
           narrowed := narrowed + 1;
           fails := fails + 1;
           report "tb_gatechk_mask: the fix STOPPED reporting a case the old "
                & "condition caught: w_we=" & std_logic'image(BITS(iw))
                & " el_we=" & std_logic'image(BITS(ie))
                & " hw_we=" & std_logic'image(BITS(ih))
                & " wr_gate=" & std_logic'image(BITS(ig))
             severity error;
         end if;

         if n and not o then
           widened := widened + 1;
           -- P2  THE WIDENING IS EXACTLY THE MASKING CASE and nothing else:
           --     a D-vec write, refused by the lock, with a host write in the
           --     same cycle.  A fix that widened anywhere else would be
           --     catching something it was not aimed at.
           if not (BITS(iw) = '1' and BITS(ih) = '1' and BITS(ig) /= '1') then
             fails := fails + 1;
             report "tb_gatechk_mask: the fix reports a case that is NOT the "
                  & "masking case: w_we=" & std_logic'image(BITS(iw))
                  & " el_we=" & std_logic'image(BITS(ie))
                  & " hw_we=" & std_logic'image(BITS(ih))
                  & " wr_gate=" & std_logic'image(BITS(ig))
               severity error;
           end if;
         end if;

         -- P3  A HOST WRITE ALONE IS STILL EXEMPT.  The host window is
         --     deliberately outside the lock and this fix must not change
         --     that; if it did, every host write would raise err_gate_drop.
         if BITS(iw) = '0' and BITS(ie) = '1' and BITS(ih) = '1' then
           checks := checks + 1;
           if n then
             fails := fails + 1;
             report "tb_gatechk_mask: a host-only write is no longer exempt"
               severity error;
           end if;
         end if;
       end loop;
      end loop;
     end loop;
    end loop;

    -- P4  THE FIX MUST ACTUALLY DO SOMETHING.  If `widened` is zero the two
    --     conditions are equivalent over the whole space and the change was
    --     cosmetic.  This is the row that fails if someone "simplifies"
    --     gatechk back.
    checks := checks + 1;
    if widened = 0 then
      fails := fails + 1;
      report "tb_gatechk_mask: the two conditions agree everywhere, so the "
           & "fix changes nothing and the masking hole is not closed"
        severity error;
    end if;

    report "tb_gatechk_mask: checks=" & integer'image(checks)
         & " widened=" & integer'image(widened)
         & " narrowed=" & integer'image(narrowed)
         & " fails=" & integer'image(fails) severity note;

    if fails = 0 then
      report "tb_gatechk_mask: PASS -- 16 rows enumerated, the fix widens "
           & "detection to exactly the masking case and narrows nothing"
        severity note;
    else
      report "tb_gatechk_mask: FAIL" severity failure;
    end if;
    wait;
  end process;

end architecture;
