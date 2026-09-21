#!/usr/bin/env python3
# TRACK CBRUN, 2026-09-21.  Build the `fan` (R3a) and `bcast` (R3b) arm trees
# from the `new` arm, by exact anchored substitution on rtl/matvec_core.vhd.
#
# WHY SUBSTITUTION ON `new` AND NOT ON `old`.  The question is which single
# property of the write statement the `[Synth 8-5859]` recognizer reads, so
# each shelf arm must differ from `new` in exactly the property it is testing
# and in nothing else.  Building them from `old` instead would reintroduce
# every one of 0b34200's four hunks and make any verdict unattributable -- the
# recorded five-variable "one-variable experiment".
#
# EVERY ANCHOR IS ASSERTED TO MATCH EXACTLY ONCE.  A substitution that silently
# matched nothing would produce an arm identical to `new`, which would then read
# as a real measurement of the shelf option.  That is the same shape as a
# get_cells filter matching nothing and printing a census of zero.
import sys, os, shutil, hashlib

RUN = sys.argv[1]
SRC = os.path.join(RUN, "new", "rtl", "matvec_core.vhd")

def sub1(text, old, new, what):
    n = text.count(old)
    if n != 1:
        raise SystemExit("MAKE_ARMS_ABORT: anchor %r matched %d times, expected 1" % (what, n))
    return text.replace(old, new)

base = open(SRC).read()

# ===========================================================================
# ARM `fan` -- CBRAM's R3a.  `cbw_*` stay CB_RANKS wide; a per-copy
# COMBINATIONAL alias carries the rank command to each copy, and the RAM write
# statement indexes that alias with the bare loop variable.  No registers are
# added, CB_WR_LAT stays 1, and the -19,344 flop saving is untouched.
#
# `cbx_*` deliberately carry NO dont_touch: matvec_core.vhd:423-425 states that
# a dont_touch signal is not a RAM inference candidate, and these wires sit
# directly on the RAM's address/data/enable ports.
# ===========================================================================
fan = base

fan = sub1(fan,
"""  signal cbw_d : cbd_arr := (others => (others => '0'));
""",
"""  signal cbw_d : cbd_arr := (others => (others => '0'));

  -- TRACK CBRUN arm `fan` (CBRAM option R3a).  Per-COPY combinational aliases
  -- of this copy's rank command.  WIRES, not registers: no dont_touch, no
  -- clocked process drives them, so they cost nothing and the command net's
  -- fanout profile is identical to `new`'s.
  type cbx_a_arr is array(0 to CB_COPIES-1) of std_logic_vector(3 downto 0);
  type cbx_d_arr is array(0 to CB_COPIES-1) of std_logic_vector(7 downto 0);
  signal cbx_v : std_logic_vector(CB_COPIES-1 downto 0);
  signal cbx_a : cbx_a_arr;
  signal cbx_d : cbx_d_arr;
""", "fan: cbx declarations")

fan = sub1(fan,
"""begin

  -- LEVER C IS SILENT WHEN IT IS OFF AND LOUD WHEN IT IS ON.
""",
"""begin

  -- TRACK CBRUN arm `fan`: the rank-to-copy fan, CONCURRENT and outside P_CB.
  -- The function call lives here, in a wire assignment, and NOT in the RAM's
  -- address/data/enable expressions.
  gen_cbfan : for c in 0 to CB_COPIES-1 generate
    cbx_v(c) <= cbw_v(cb_rank_of(c));
    cbx_a(c) <= cbw_a(cb_rank_of(c));
    cbx_d(c) <= cbw_d(cb_rank_of(c));
  end generate;

  -- LEVER C IS SILENT WHEN IT IS OFF AND LOUD WHEN IT IS ON.
""", "fan: gen_cbfan")

fan = sub1(fan,
"""      for c in 0 to CB_COPIES-1 loop
        if cbw_v(cb_rank_of(c)) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(cb_rank_of(c)))))
            <= signed(cbw_d(cb_rank_of(c)));
        end if;
      end loop;
""",
"""      for c in 0 to CB_COPIES-1 loop
        if cbx_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbx_a(c)))) <= signed(cbx_d(c));
        end if;
      end loop;
""", "fan: P_CB write statement")

# The announcement must identify the arm, so a log read on its own cannot
# mistake one arm for another.  (The runner's GHDL gate keys on CB_COPIES and
# CB_RANKS, which are identical in `new`, `fan` and `bcast`; without this the
# three announcements would be indistinguishable.)
fan = sub1(fan,
"""           & "  CB_WR_LAT=" & integer'image(CB_WR_LAT)""",
"""           & "  CB_WR_LAT=" & integer'image(CB_WR_LAT)
           & "  CBRUN_ARM=fan\"""", "fan: announcement")

# ===========================================================================
# ARM `bcast` -- CBRAM's R3b.  `cbw_*` go back to CB_COPIES wide so the RAM
# write statement's index expressions are the bare loop variable exactly as in
# `old`, and a NEW CB_RANKS-wide stage `cbr_*` sits between the ports and
# `cbw_*`.  Fanout cb_addr -> 48 (cbr) -> 32 each (cbw) -> 16 bels each.
# CB_WR_LAT goes 1 -> 2, which is the cost and which is why this arm is on the
# shelf rather than in a build.
#
# ITS WRITE LOOP IS `new`'s LOOP WITH THE FUNCTION CALL REMOVED, NOT `old`'s
# COMBINED LOOP.  `new` differs from `old` in TWO ways -- the W1 write and the
# W0 capture were split into separate loops, AND the index expressions became
# cb_rank_of(c).  Keeping `new`'s split and changing only the indices is what
# makes this arm attribute the verdict to the index expression.  An arm that
# restored both at once could not tell the two apart.
# ===========================================================================
bc = base

bc = sub1(bc,
"""  type cba_arr is array(0 to CB_RANKS-1) of std_logic_vector(3 downto 0);
  type cbd_arr is array(0 to CB_RANKS-1) of std_logic_vector(7 downto 0);
  signal cbw_v : std_logic_vector(CB_RANKS-1 downto 0) := (others => '0');
  signal cbw_a : cba_arr := (others => (others => '0'));
  signal cbw_d : cbd_arr := (others => (others => '0'));
""",
"""  -- TRACK CBRUN arm `bcast` (CBRAM option R3b).  cbw_* are per-COPY again, so
  -- the RAM write statement is byte-identical to the pre-0b34200 one.
  type cba_arr is array(0 to CB_COPIES-1) of std_logic_vector(3 downto 0);
  type cbd_arr is array(0 to CB_COPIES-1) of std_logic_vector(7 downto 0);
  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_a : cba_arr := (others => (others => '0'));
  signal cbw_d : cbd_arr := (others => (others => '0'));

  -- the NEW rank stage, between the ports and cbw_*.  This is what keeps
  -- cb_addr's fanout at CB_RANKS rather than CB_COPIES.
  type cbr_a_arr is array(0 to CB_RANKS-1) of std_logic_vector(3 downto 0);
  type cbr_d_arr is array(0 to CB_RANKS-1) of std_logic_vector(7 downto 0);
  signal cbr_v : std_logic_vector(CB_RANKS-1 downto 0) := (others => '0');
  signal cbr_a : cbr_a_arr := (others => (others => '0'));
  signal cbr_d : cbr_d_arr := (others => (others => '0'));
""", "bcast: declarations")

bc = sub1(bc,
"""  constant CB_WR_LAT : positive := 1;
""",
"""  -- TRACK CBRUN arm `bcast`: TWO command stages, so TWO cycles.  This is the
  -- cost of R3b and the reason CBRAM puts a drain state between S_CB and
  -- S_START in rtl/matvec_int4_desc_axi.vhd on the shelf beside it.
  constant CB_WR_LAT : positive := 2;
""", "bcast: CB_WR_LAT")

bc = sub1(bc,
"""  attribute dont_touch of cbw_d : signal is "true";
""",
"""  attribute dont_touch of cbw_d : signal is "true";
  attribute dont_touch of cbr_v : signal is "true";
  attribute dont_touch of cbr_a : signal is "true";
  attribute dont_touch of cbr_d : signal is "true";
""", "bcast: dont_touch")

bc = sub1(bc,
"""      for c in 0 to CB_COPIES-1 loop
        if cbw_v(cb_rank_of(c)) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(cb_rank_of(c)))))
            <= signed(cbw_d(cb_rank_of(c)));
        end if;
      end loop;
      -- stage W0: capture the command, one register per RANK.  No term in
      -- this loop depends on r, which is what makes the ranks peers.
      for r in 0 to CB_RANKS-1 loop
        if cb_we = '1' and st = S_IDLE and rst = '0' then
          cbw_v(r) <= '1';
        else
          cbw_v(r) <= '0';
        end if;
        cbw_a(r) <= cb_addr;
        cbw_d(r) <= cb_data;
      end loop;
""",
"""      for c in 0 to CB_COPIES-1 loop
        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;
      end loop;
      -- stage W0b: fan the RANK command out to the per-copy command
      -- registers.  The function call lives HERE, one stage above the RAM.
      for c in 0 to CB_COPIES-1 loop
        cbw_v(c) <= cbr_v(cb_rank_of(c));
        cbw_a(c) <= cbr_a(cb_rank_of(c));
        cbw_d(c) <= cbr_d(cb_rank_of(c));
      end loop;
      -- stage W0: capture the command, one register per RANK.  No term in
      -- this loop depends on r, which is what makes the ranks peers.
      for r in 0 to CB_RANKS-1 loop
        if cb_we = '1' and st = S_IDLE and rst = '0' then
          cbr_v(r) <= '1';
        else
          cbr_v(r) <= '0';
        end if;
        cbr_a(r) <= cb_addr;
        cbr_d(r) <= cb_data;
      end loop;
""", "bcast: P_CB three stages")

bc = sub1(bc,
"""      if rst = '1' then
        cbw_v <= (others => '0');
      end if;
    end if;
  end process;
""",
"""      if rst = '1' then
        cbw_v <= (others => '0');
        cbr_v <= (others => '0');
      end if;
    end if;
  end process;
""", "bcast: reset")

bc = sub1(bc,
"""           & "  CB_WR_LAT=" & integer'image(CB_WR_LAT)""",
"""           & "  CB_WR_LAT=" & integer'image(CB_WR_LAT)
           & "  CBRUN_ARM=bcast\"""", "bcast: announcement")

for arm, text in (("fan", fan), ("bcast", bc)):
    dst = os.path.join(RUN, arm)
    if os.path.exists(dst):
        raise SystemExit("MAKE_ARMS_ABORT: %s already exists; this script never overwrites" % dst)
    shutil.copytree(os.path.join(RUN, "new"), dst,
                    ignore=shutil.ignore_patterns("ghdlwork", "*.log"))
    p = os.path.join(dst, "rtl", "matvec_core.vhd")
    with open(p, "w") as f:
        f.write(text)
    h = hashlib.sha256(text.encode()).hexdigest()
    print("MAKE_ARMS %-5s sha256=%s lines=%d" % (arm, h, text.count("\n")))

print("MAKE_ARMS_DONE")
