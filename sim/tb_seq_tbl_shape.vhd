-- sim/tb_seq_tbl_shape.vhd
-- Does the real Qwen3.5-9B descriptor table encode jobs the gateware will
-- ACCEPT, and does the lm_head's window set actually tile the vocabulary?
--
-- WHY THIS BENCH EXISTS.  `sim/seq_tbl_pkg.vhd` encoded the lm_head as a
-- single 248,320-row A job until 2026-08-29.  `matvec_int4_desc_axi`'s S_CHECK
-- refuses exactly that descriptor -- `n_rows > MAXROWS_BFP` with no out_mode
-- test, `rtl/matvec_int4_desc_axi.vhd:721-726` -- so the table encoded a
-- schedule the gateware would answer `err_code 0x3 err_info 1` on, and it did
-- so for as long as the table existed.  Nothing caught it, because the four
-- benches that walk this table (`tb_seq_desc_fetch`, `tb_seq_opdec`,
-- `tb_seq_region_lock`, `probe_abc_ports`) check the SEQUENCING and take
-- `TBL_STEPS` from the package itself, so the table is its own oracle for
-- every one of them.  Change the encoding and they all follow it silently.
--
-- So this bench asks the question those cannot: not "did the walker walk it"
-- but "is what it walked legal, and does it add up".
--
-- WHAT IS AND IS NOT AN INDEPENDENT CHECK, stated because it decides how much
-- the PASS is worth:
--
--   RESTATED, not independent.  Group 1 restates `matvec_int4_desc_axi`'s
--   shape bound in this bench's own words.  If the RTL's bound changes and
--   this file does not, the bench agrees with a stale rule.  The constants it
--   compares against are the same two literals `seq_tbl_pkg` derives the
--   window plan from, so group 1 cannot catch a WRONG MAXROWS_BFP; it catches
--   a table that ignores the one it was given.  Closing that properly needs
--   the real descriptor plane as judge, which is `sim/tb_mv4i_desc_image`'s
--   job and not this one.
--
--   INDEPENDENT.  Groups 2 and 3 are not restatements of anything.  Group 2
--   asks whether the windows COVER the vocabulary exactly once and start on
--   tile boundaries -- a property of the emitted `n_rows` fields read back out
--   of the table, which no other artefact in the tree asserts.  Group 3 checks
--   every job's write against `region_sizes`, a quantity derived from the
--   model on a completely separate path from the one that produced `n_rows`,
--   so a row count that disagrees with the region it writes is a genuine
--   disagreement between two derivations and not a tautology.
--
-- NO CLOCK, NO DUT.  The subject is a constant function of `model_cfg_pkg`, so
-- the whole bench is one process over `build_table`'s output.  It costs
-- milliseconds and is therefore cheap enough to gate on.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.seq_tbl_pkg.all;

entity tb_seq_tbl_shape is
  generic(
    -- Mutation hooks.  All default to "no mutation".  Each one makes a
    -- well-formed table that a walker would still walk happily, so a kill is
    -- this bench noticing and not GHDL noticing.
    -- BAD_LM_ROWS is a negative control for GROUP 2 ONLY: it corrupts the
    -- row count the cover arithmetic sees, after groups 1 and 3 have read the
    -- honest one, so a kill is the COVER check firing and not the bound check.
    BAD_LM_ROWS  : integer := -1;  -- window N contributes LM_STRIDE+1 rows
    -- BAD_FFN_ROWS is the negative control for groups 1 and 3: it corrupts
    -- step N's row count at the point every check reads it.
    BAD_FFN_ROWS : integer := -1
  );
end entity;

architecture sim of tb_seq_tbl_shape is

  constant TBL : tbl_t := build_table;

  -- Field accessors.  The byte positions are `mk_desc`'s, and they are read
  -- back out of the encoded words rather than taken from the emitter's
  -- arguments, so an encoder that writes the right value into the wrong byte
  -- is visible here.
  function f_opcode  (s : natural) return natural is
  begin return to_integer(unsigned(TBL(s*8+0)( 7 downto  0))); end function;
  function f_flags   (s : natural) return natural is
  begin return to_integer(unsigned(TBL(s*8+0)(15 downto  8))); end function;
  function f_dst     (s : natural) return natural is
  begin return to_integer(unsigned(TBL(s*8+0)(31 downto 24))); end function;
  function f_dst_off (s : natural) return natural is
  begin return to_integer(unsigned(TBL(s*8+0)(63 downto 32))); end function;
  function f_n_rows  (s : natural) return natural is
  begin return to_integer(unsigned(TBL(s*8+1)(31 downto  0))); end function;
  function f_n_cols  (s : natural) return natural is
  begin return to_integer(unsigned(TBL(s*8+1)(63 downto 32))); end function;
  function f_outmode (s : natural) return natural is
  begin return to_integer(unsigned(TBL(s*8+3)( 7 downto  0))); end function;

  -- `matvec_int4_desc_axi`'s MAXCOLS generic, the other half of the same
  -- S_CHECK clause (`rtl/matvec_int4_desc_axi.vhd:107`).
  constant A_MAXCOLS : natural := 17408;

  -- ceil(MAXROWS_BFP / ROWS_IF), which is `matvec_core`'s `TILES` and the
  -- depth of its `ybuf` (`rtl/matvec_core.vhd:120`).  Worklog OI-8 is an index
  -- one past the end when a job's tile count REACHES this.
  constant A_TILES : natural := (A_MAXROWS_BFP + A_ROWS_IF - 1) / A_ROWS_IF;

  constant RSZ : integer_vector(0 to NREGION-1) := region_sizes;

begin

  chk : process
    variable nfail : natural := 0;
    variable nchk  : natural := 0;
    variable nlm   : natural := 0;
    variable covered : natural := 0;
    variable start : natural := 0;
    variable rows  : natural;
    variable first_lm, last_lm : integer := -1;

    procedure bad(msg : string) is
    begin
      report "tb_seq_tbl_shape: " & msg severity error;
      nfail := nfail + 1;
    end procedure;

    -- Apply the mutation hooks to the value a step CLAIMS, so the mutations
    -- act on the checker's input exactly as a wrong encoder would.
    impure function rows_of(s : natural) return natural is
    begin
      if BAD_FFN_ROWS >= 0 and s = BAD_FFN_ROWS then
        return f_n_rows(s) + 1;
      end if;
      return f_n_rows(s);
    end function;

  begin
    report "tb_seq_tbl_shape: " & integer'image(TBL_STEPS) & " steps, "
         & integer'image(TBL_WORDS) & " words, LM_WINDOWS = "
         & integer'image(LM_WINDOWS) & ", LM_STRIDE = "
         & integer'image(LM_STRIDE) severity note;

    -- ---- group 0: the window plan itself ---------------------------------
    -- These are properties of the two build constants and the derivation, and
    -- they hold or fail before a single descriptor is read.
    nchk := nchk + 4;
    if LM_STRIDE mod A_ROWS_IF /= 0 then
      bad("LM_STRIDE " & integer'image(LM_STRIDE)
        & " is not a whole number of ROWS_IF tiles; a window that does not "
        & "start on a tile boundary cannot be expressed as a base offset");
    end if;
    if LM_STRIDE > A_MAXROWS_BFP then
      bad("LM_STRIDE " & integer'image(LM_STRIDE) & " exceeds MAXROWS_BFP "
        & integer'image(A_MAXROWS_BFP));
    end if;
    -- The OI-8 corner: flooring MAXROWS_BFP to a tile is exactly what removes
    -- the last tile, so a windowed job can never reach ybuf's TILES.
    if LM_STRIDE / A_ROWS_IF >= A_TILES then
      bad("a full window is " & integer'image(LM_STRIDE / A_ROWS_IF)
        & " tiles and matvec_core's ybuf is " & integer'image(A_TILES)
        & " deep; this is OI-8's corner");
    end if;
    if LM_WINDOWS * LM_STRIDE < VOCAB_SH then
      bad("LM_WINDOWS " & integer'image(LM_WINDOWS) & " x LM_STRIDE cannot "
        & "reach VOCAB_SH " & integer'image(VOCAB_SH));
    end if;

    -- ---- groups 1 and 3: every step ---------------------------------------
    for s in 0 to TBL_STEPS-1 loop
      if f_opcode(s) = OP_A_JOB then
        rows := rows_of(s);
        nchk := nchk + 2;

        -- GROUP 1, RESTATED from rtl/matvec_int4_desc_axi.vhd:721-726.
        if rows = 0 or rows > A_MAXROWS_BFP then
          bad("step " & integer'image(s) & " is an A job with n_rows "
            & integer'image(rows) & "; S_CHECK bounds it to 1 .. "
            & integer'image(A_MAXROWS_BFP)
            & " in EVERY out_mode, so this descriptor is refused "
            & "err_code 0x3 err_info 1");
        end if;
        if f_n_cols(s) = 0 or f_n_cols(s) > A_MAXCOLS then
          bad("step " & integer'image(s) & " is an A job with n_cols "
            & integer'image(f_n_cols(s)) & "; S_CHECK bounds it to 1 .. "
            & integer'image(A_MAXCOLS));
        end if;

        -- GROUP 3, INDEPENDENT: the write must fit the region it names, and
        -- `region_sizes` is derived from the model on a separate path.
        if f_dst(s) < NREGION then
          nchk := nchk + 1;
          if f_dst_off(s) + rows > RSZ(f_dst(s)) then
            bad("step " & integer'image(s) & " writes region "
              & integer'image(f_dst(s)) & " at offset "
              & integer'image(f_dst_off(s)) & " for "
              & integer'image(rows) & " rows, past its capacity "
              & integer'image(RSZ(f_dst(s))));
          end if;
        end if;

        -- Collect the lm_head windows: the A jobs routed to the sampler.
        if (f_flags(s) / FLG_TO_SMP) mod 2 = 1 then
          nlm := nlm + 1;
          if first_lm < 0 then first_lm := s; end if;
          last_lm := s;
          nchk := nchk + 3;
          if f_dst(s) /= R_NONE then
            bad("lm_head step " & integer'image(s) & " has dst "
              & integer'image(f_dst(s)) & ", not R_NONE; a window that names a "
              & "region is claiming a write nothing performs");
          end if;
          if f_outmode(s) /= 1 then
            bad("lm_head step " & integer'image(s) & " is out_mode "
              & integer'image(f_outmode(s)) & ", not raw (1).  In BFP the "
              & "per-job ns enters y_exp, so the windows would carry "
              & "different exponents into a sampler whose only input is a "
              & "bare 32-bit integer");
          end if;
          if f_dst_off(s) /= 0 then
            bad("lm_head step " & integer'image(s) & " has dst_off "
              & integer'image(f_dst_off(s)) & "; seq_opdec infers an exponent "
              & "SEGMENT from a non-zero dst_offset and a stream has none");
          end if;

          -- GROUP 2, INDEPENDENT: the cover, read back out of the table.
          if BAD_LM_ROWS >= 0 and nlm - 1 = BAD_LM_ROWS then
            rows := LM_STRIDE + 1;
          end if;
          -- THERE IS NO `start /= covered` CHECK HERE, and there was one until
          -- it was noticed to be decoration.  `row_start` is NOT a descriptor
          -- field (`tools/gen_layer_program.py` carries it outside the header,
          -- and `mk_desc` has no argument for it), so a window's start is not
          -- read back from anywhere -- it can only be the running cover, which
          -- makes "the start equals the cover" true by construction and
          -- unfalsifiable. What IS falsifiable is whether that running cover
          -- lands on a tile, which is the next check.
          nchk := nchk + 3;
          if start mod A_ROWS_IF /= 0 then
            bad("lm_head window " & integer'image(nlm-1) & " starts at row "
              & integer'image(start) & ", not a multiple of ROWS_IF "
              & integer'image(A_ROWS_IF));
          end if;
          if rows = 0 then
            bad("lm_head window " & integer'image(nlm-1) & " is empty");
          end if;
          if nlm < LM_WINDOWS and rows /= LM_STRIDE then
            bad("lm_head window " & integer'image(nlm-1) & " is "
              & integer'image(rows) & " rows; every window but the last must "
              & "be a whole LM_STRIDE " & integer'image(LM_STRIDE)
              & " or the next one does not begin on a tile");
          end if;
          covered := covered + rows;
          start := covered;
        end if;
      end if;
    end loop;

    -- ---- group 2, the cover as a whole -----------------------------------
    nchk := nchk + 4;
    if nlm /= LM_WINDOWS then
      bad("found " & integer'image(nlm) & " lm_head windows, LM_WINDOWS says "
        & integer'image(LM_WINDOWS));
    end if;
    if covered /= VOCAB_SH then
      bad("the lm_head windows cover " & integer'image(covered)
        & " rows; VOCAB_SH is " & integer'image(VOCAB_SH)
        & ".  Every uncovered row is a logit no sampler ever sees");
    end if;
    -- The windows are the LAST thing before END_TOKEN, contiguous, and nothing
    -- separates them.  A window issued after END_TOKEN, or interleaved with
    -- another job, breaks the sampler's single running argmax.
    if first_lm < 0 or last_lm - first_lm /= nlm - 1 then
      bad("the lm_head windows are not contiguous: first " & integer'image(first_lm)
        & ", last " & integer'image(last_lm) & ", count " & integer'image(nlm));
    end if;
    if last_lm /= TBL_STEPS - 2 or f_opcode(TBL_STEPS-1) /= OP_END_TOKEN then
      bad("the last lm_head window is step " & integer'image(last_lm)
        & " and the table is " & integer'image(TBL_STEPS)
        & " steps; the windows must be the last steps before END_TOKEN");
    end if;

    report "tb_seq_tbl_shape: " & integer'image(nchk) & " checks, "
         & integer'image(nlm) & " lm_head windows covering "
         & integer'image(covered) & " of " & integer'image(VOCAB_SH) & " rows"
         severity note;

    if nfail = 0 then
      report "tb_seq_tbl_shape: PASS" severity note;
    else
      report "tb_seq_tbl_shape: FAIL, " & integer'image(nfail)
           & " of " & integer'image(nchk) & " checks failed" severity failure;
    end if;
    wait;
  end process;

end architecture;
