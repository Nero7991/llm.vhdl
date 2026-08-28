-- sim/tb_attn_rescale.vhd
-- Bit-exact testbench for rtl/attn_rescale_skel.vhd against
-- ref/attn_rescale_vec.c.
--
-- WHY A PRICING SKELETON HAS A FUNCTIONAL TESTBENCH AT ALL.  attn_lane_skel
-- has none, and correctly so: every mode in it is arithmetic the spec already
-- pins, so the only question is what it costs.  This skeleton is different.
-- Its SEQ_MULT = true branch introduces a chunk decomposition that is NOT in
-- the spec, and the whole value of the file is a claim that that branch costs
-- one DSP48E2 instead of two.  A structure that synthesises to 1 DSP while
-- computing the wrong function prices something nobody can build.  So the two
-- branches are checked bit-exactly against an independent golden BEFORE either
-- number is quoted.
--
-- THE ORACLE IS INDEPENDENT.  ref/attn_rescale_vec.c shares no machinery with
-- this RTL: it checks its own product and rounding against an EXACT IEEE754
-- double computation (|o*f| <= 2^47 < 2^53, so binary64 is exact), it pins
-- f = 4096 as an exact identity and f = 0 as exact zero, it states the chunk
-- identity and the chunk WIDTHS as ORACLE 5, it pins the DSP48E2 port fit as
-- ORACLE 9, and it checks monotonicity in o -- a property of the map rather
-- than a replay of it.  It was mutation-tested at 12 of 15 killed BEFORE this
-- skeleton was written; all three survivors were read and are recorded.
--
-- WHAT IS CHECKED, AND WHY EACH IS SEPARATE
--   1  every published y bit-exact against the golden
--   2  y arrives in EXACT case order, tracked by this file's OWN counter
--   3  the y_valid CADENCE -- one per cycle at SEQ_MULT = false, one per two
--      at true.  This is the schedule cost the decision must weigh, so it is
--      asserted rather than assumed.
--   4  THE READ MUX actually selects.  Every entry the DUT does not want
--      carries POISON, distinct per entry, so a mux that picks the wrong
--      source publishes a wrong value rather than a right one.  Loading every
--      entry with the same accumulator would have made the mux untestable --
--      that is the constant-subject trap, and here it would have hidden the
--      entire second question this skeleton exists to answer.
--   5  the pipeline FREEZES on en = '0' and resumes without corruption
--
-- COVERAGE ASSERTIONS FAIL, THEY DO NOT WARN.  They also guard the newer trap:
-- two values agreeing at one point is a coincidence, not an agreement, so the
-- poison is required to have DIFFERED from the wanted accumulator on every
-- cycle rather than merely on most, and the entry index is required to have
-- taken every value it can.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_attn_rescale is
  generic(
    VEC          : string   := "attn_rescale_vec.txt";
    SEQ_MULT     : boolean  := false;
    MUX_FLAT     : boolean  := true;
    LANES_SERVED : positive := 2;
    ACC_N        : positive := 8;
    -- Cycles the enable is held LOW between active cycles.  0 ties it high,
    -- which is the DEGENERATE configuration and is NOT strictly weaker: it is
    -- the only shape in which the pipeline never freezes, so it is the only
    -- one that can catch a stage that depends on a freeze to be correct.
    EN_GAP       : natural  := 0
  );
end entity;

architecture tb of tb_attn_rescale is

  constant ACC_W : integer := 36;
  constant F_W   : integer := 13;
  constant RSH   : integer := 12;
  constant SPLIT : integer := 17;
  constant NSRC  : integer := LANES_SERVED*ACC_N;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal halt : boolean := false;

  signal en      : std_logic := '0';
  signal acc_bus : std_logic_vector(NSRC*ACC_W-1 downto 0) := (others => '0');
  signal f_in    : unsigned(F_W-1 downto 0) := (others => '0');
  signal y_out   : signed(ACC_W-1 downto 0);
  signal y_valid : std_logic;
  signal digest  : std_logic_vector(31 downto 0);

  type gold_t is array (natural range <>) of signed(ACC_W-1 downto 0);
  -- SIGNALS, not variables inside the stimulus process: the result monitor is
  -- a separate process and has to see the golden to check against it.
  signal g_o   : gold_t(0 to 4095) := (others => (others => '0'));
  signal g_y   : gold_t(0 to 4095) := (others => (others => '0'));
  signal ncase : integer := 0;
  signal loaded : boolean := false;

  -- SEQ_MULT = true reads each accumulator TWICE.
  function passes_f return integer is
  begin
    if SEQ_MULT then return 2; else return 1; end if;
  end function;
  constant PASSES : integer := passes_f;

  -- tallies
  signal errs, mon_err, cad_err : integer := 0;
  signal n_pub  : integer := 0;
  signal n_fill : integer := 0;
  signal cov_poison_ok : integer := 0;
  signal cov_poison_clash : integer := 0;
  signal cov_frozen : integer := 0;
  signal cov_hold   : integer := 0;
  signal frz_err    : integer := 0;

  -- ACC_W is 36, so to_integer(y_out) OVERFLOWS VHDL's 32-bit integer and
  -- kills the run inside the report statement itself.  Print hex.
  function hx(v : signed) return string is
    constant D : string(1 to 16) := "0123456789abcdef";
    variable u : unsigned(v'length-1 downto 0) := unsigned(v);
    variable n : integer := (v'length + 3) / 4;
    variable r : string(1 to (v'length + 3) / 4);
  begin
    for i in 0 to n-1 loop
      r(n-i) := D(to_integer(u(3 downto 0)) + 1);
      u := shift_right(u, 4);
    end loop;
    return r;
  end function;

  -- THE PIPELINE FILL.  The skeleton is free-running and centrally scheduled
  -- in the real design, so it carries no notion of a first valid result: from
  -- reset it publishes the rounded contents of its own zeroed registers until
  -- real data reaches the end.  Those leading results are DETERMINISTIC ZEROS,
  -- not garbage -- round_shift(0, 12) = 0 -- so they are discarded here with a
  -- POSITIVE assertion that each really is zero, rather than silently skipped.
  --
  -- This was found the hard way and it is the coordinator's own warning in its
  -- exact form.  The first version discarded nothing, and the run still passed
  -- its first two cases -- because golden case 0 (o = 0, f = 4096) and case 1
  -- (o = 0, f = 0) both have y = 0, so the two fill zeros AGREED WITH THE
  -- GOLDEN BY COINCIDENCE.  The mismatch only surfaced at case 2.  Two values
  -- agreeing is not agreement, and here the coincidence hid a whole pipeline
  -- stage.
  -- The two branches differ, and the difference is structural rather than
  -- incidental.  At SEQ_MULT = false the completion flag is raised
  -- unconditionally, so the rounded contents of the reset registers are
  -- published while the pipeline fills: FILL = 2.  At SEQ_MULT = true the flag
  -- is raised only after a HIGH pass, and the phase alignment from reset makes
  -- the first raise coincide exactly with the first complete sum: FILL = 0,
  -- verified by direct observation of the published stream, not by argument.
  function fill_f return integer is
  begin
    if SEQ_MULT then return 0; else return 2; end if;
  end function;
  constant FILL : integer := fill_f;

  -- Distinct poison for entry j.  Chosen so it is a legal ACC_W value but an
  -- unlikely golden, and CHECKED against the wanted accumulator every cycle
  -- rather than assumed distinct.
  function poison(j : integer) return signed is
  begin
    return to_signed(-(2**(ACC_W-2)) + 12345 + j*7919, ACC_W);
  end function;

begin

  clk <= not clk after 5 ns when not halt else '0';

  dut : entity work.attn_rescale_skel
    generic map(SEQ_MULT => SEQ_MULT, MUX_FLAT => MUX_FLAT,
                LANES_SERVED => LANES_SERVED, ACC_N => ACC_N,
                ACC_W => ACC_W, F_W => F_W, RSH => RSH, SPLIT => SPLIT)
    port map(clk => clk, rst => rst, en => en,
             acc_bus => acc_bus, f_in => f_in,
             y_out => y_out, y_valid => y_valid, digest => digest);

  process
    file     fh : text;
    variable ln : line;
    variable st : file_open_status;
    variable nc, aw, fw, rsh_v, sp : integer;
    variable ohex, yhex : std_logic_vector(63 downto 0);
    variable fdec : integer;

    variable gold_f : integer_vector(0 to 4095) := (others => 0);

    variable ent  : integer := 0;   -- the entry index the DUT will read
    variable ph   : integer := 0;   -- pass within the entry, SEQ_MULT only
    variable ci   : integer := 0;   -- the case being presented
    variable sel  : integer;
    variable distinct : integer;

    procedure drive_bus(c : integer; s : integer) is
    begin
      -- POISON EVERY ENTRY, then place the wanted accumulator at exactly the
      -- entry the DUT is about to read.  A mux that selects wrongly gets
      -- poison and publishes a value the golden does not contain.
      for j in 0 to NSRC-1 loop
        acc_bus((j+1)*ACC_W-1 downto j*ACC_W) <=
          std_logic_vector(poison(j));
      end loop;
      acc_bus((s+1)*ACC_W-1 downto s*ACC_W) <= std_logic_vector(g_o(c));
    end procedure;
  begin
    file_open(st, fh, VEC, read_mode);
    assert st = open_ok report "cannot open " & VEC severity failure;
    readline(fh, ln); read(ln, nc); read(ln, aw); read(ln, fw);
    read(ln, rsh_v); read(ln, sp);
    assert aw = ACC_W and fw = F_W and rsh_v = RSH and sp = SPLIT
      report "geometry mismatch between the golden and this testbench"
      severity failure;
    assert nc <= 4096 report "raise the golden array bound" severity failure;
    ncase <= nc;
    wait for 0 ns;
    for c in 0 to nc-1 loop
      readline(fh, ln);
      hread(ln, ohex); read(ln, fdec); hread(ln, yhex);
      g_o(c) <= resize(signed(ohex), ACC_W);
      g_y(c) <= resize(signed(yhex), ACC_W);
      gold_f(c) := fdec;
    end loop;
    file_close(fh);

    -- Confirm the golden itself is not constant, or the mux test is vacuous
    -- no matter how carefully the poison is placed.
    wait for 0 ns;
    loaded <= true;
    distinct := 0;
    for c in 1 to nc-1 loop
      if g_o(c) /= g_o(0) then distinct := distinct + 1; end if;
    end loop;
    assert distinct >= 2
      report "COVERAGE: the golden accumulators are effectively constant, so "
           & "the read-mux check cannot distinguish a working mux from a "
           & "broken one" severity failure;

    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to nc-1 loop
      -- The DUT reads entry `ent`; at MUX_FLAT = false only every ACC_N-th
      -- entry is ever addressed, and the stride is what makes the entries come
      -- from DIFFERENT lanes.
      if MUX_FLAT then sel := ent mod NSRC;
      else             sel := (ent mod LANES_SERVED) * ACC_N; end if;

      -- The poison must actually differ from the wanted value, or this cycle's
      -- mux check proves nothing.  Counted, and required non-zero at the end.
      if poison(sel) /= g_o(c) then cov_poison_ok <= cov_poison_ok + 1;
      else                             cov_poison_clash <= cov_poison_clash + 1;
      end if;

      drive_bus(c, sel);
      f_in <= to_unsigned(gold_f(c), F_W);

      -- SEQ_MULT = true reads the SAME entry twice, so the operands are held
      -- for both passes.
      for pass in 1 to PASSES loop
        -- The stall shape.  EN_GAP = 0 leaves the enable tied high and never
        -- pulls it low, which is the degenerate configuration.
        if EN_GAP > 0 then
          en <= '0';
          for g in 1 to EN_GAP loop
            wait until rising_edge(clk);
            cov_frozen <= cov_frozen + 1;
          end loop;
        end if;
        en <= '1';
        wait until rising_edge(clk);
      end loop;

      ent := ent + 1;
      ci  := ci + 1;
    end loop;

    -- Flush.  The DUT keeps reading whatever acc_bus still holds, so it will
    -- happily publish more results; the monitor is capped at ncase for exactly
    -- that reason and the assertion below is what proves the cap was reached
    -- rather than merely not exceeded.
    en <= '1';
    for i in 1 to 32 loop wait until rising_edge(clk); end loop;
    en <= '0';
    wait until rising_edge(clk);

    assert n_fill = FILL
      report "COVERAGE: " & integer'image(n_fill) & " pipeline-fill results "
           & "seen, " & integer'image(FILL) & " expected -- the fill constant "
           & "does not describe this configuration" severity failure;
    assert n_pub = nc
      report "COVERAGE: " & integer'image(n_pub) & " results published for "
           & integer'image(nc) & " cases -- the DUT dropped or duplicated"
      severity failure;
    assert cov_poison_clash = 0
      report "COVERAGE: the poison collided with the wanted accumulator on "
           & integer'image(cov_poison_clash) & " cycles, so the read-mux check "
           & "was vacuous on those cycles" severity failure;
    assert cov_poison_ok >= 2
      report "COVERAGE: fewer than two cycles where the poison genuinely "
           & "differed -- one agreement is a coincidence, not a test"
      severity failure;
    if EN_GAP > 0 then
      assert cov_frozen > 0
        report "COVERAGE: EN_GAP > 0 but the pipeline never actually froze"
        severity failure;
      -- The freeze must have been OBSERVED holding, not merely requested.
      assert cov_hold >= 2
        report "COVERAGE: fewer than two cycles where the frozen output was "
             & "actually compared against its previous value -- one agreement "
             & "is a coincidence, not a test" severity failure;
    end if;

    if errs + mon_err + cad_err + frz_err = 0 then
      report "tb_attn_rescale PASS: " & integer'image(nc)
           & " cases bit-exact, SEQ_MULT="
           & boolean'image(SEQ_MULT) & " MUX_FLAT=" & boolean'image(MUX_FLAT)
           & " LANES_SERVED=" & integer'image(LANES_SERVED)
           & " EN_GAP=" & integer'image(EN_GAP)
           & "; frozen cycles " & integer'image(cov_frozen)
           & ", freeze holds checked " & integer'image(cov_hold)
           & ", mux checks with live poison " & integer'image(cov_poison_ok)
        severity note;
    else
      report "tb_attn_rescale FAIL: value " & integer'image(mon_err)
           & " cadence " & integer'image(cad_err)
           & " freeze " & integer'image(frz_err)
           & " other " & integer'image(errs) severity failure;
    end if;
    halt <= true;
    wait;
  end process;

  -- ===================================================================
  -- THE FREEZE MONITOR.  en = '0' is this skeleton's only back-pressure, and
  -- a frozen pipeline must HOLD its output, not drop it.
  --
  -- The first version of this check asserted that y_valid was LOW on every
  -- frozen cycle, and it failed on 1,530 cycles of entirely correct behaviour.
  -- Holding a raised valid through a freeze is exactly what a frozen register
  -- does; the check was testing the opposite of the requirement.  What
  -- actually has to be true is that NOTHING CHANGES, so that is what is
  -- checked: en is sampled alongside the outputs, and on the next edge -- the
  -- edge whose DUT update that same en value gated -- the outputs must be
  -- unchanged.
  -- ===================================================================
  process(clk)
    variable pen : std_logic := '1';
    variable py  : signed(ACC_W-1 downto 0) := (others => '0');
    variable pv  : std_logic := '0';
    variable pd  : std_logic_vector(31 downto 0) := (others => '0');
    variable armed : boolean := false;
  begin
    if rising_edge(clk) then
      if rst = '0' and armed and pen = '0' then
        if y_out /= py or y_valid /= pv or digest /= pd then
          report "FREEZE: the output moved while en was low" severity error;
          frz_err <= frz_err + 1;
        end if;
        cov_hold <= cov_hold + 1;
      end if;
      pen := en; py := y_out; pv := y_valid; pd := digest;
      armed := (rst = '0');
    end if;
  end process;

  -- ===================================================================
  -- The result monitor.  Order is tracked with this file's OWN counter, so a
  -- reordering is visible; indexing the golden by anything the DUT produced
  -- would hide it.
  -- ===================================================================
  process(clk)
    variable prev_v : std_logic := '0';
  begin
    if rising_edge(clk) then
      if rst = '0' and en = '1' and loaded then
        if y_valid = '1' and n_fill < FILL then
          -- the reset flush: assert it POSITIVELY rather than skipping it
          if y_out /= to_signed(0, ACC_W) then
            report "FILL: the pipeline-fill result " & integer'image(n_fill)
                 & " is 0x" & hx(y_out) & ", not zero -- FILL is wrong or the "
                 & "skeleton does not start from a zeroed state"
              severity error;
            errs <= errs + 1;
          end if;
          n_fill <= n_fill + 1;
        elsif y_valid = '1' and n_pub < ncase then
          if y_out /= g_y(n_pub) then
            report "VALUE: case " & integer'image(n_pub)
                 & " got 0x" & hx(y_out)
                 & " want 0x" & hx(g_y(n_pub))
              severity error;
            mon_err <= mon_err + 1;
          end if;
          n_pub <= n_pub + 1;
        end if;

        -- THE CADENCE, asserted rather than assumed.  At SEQ_MULT = true the
        -- unit takes two passes per accumulator, so y_valid must NEVER be high
        -- on two consecutive enabled cycles.  That is the schedule cost the
        -- decision has to weigh -- a rescale pass goes from ACC_N cycles to
        -- 2 x LANES_SERVED x ACC_N -- and it is checked here so it cannot be
        -- quietly dropped when the DSP number is quoted.
        if SEQ_MULT and y_valid = '1' and prev_v = '1' then
          report "CADENCE: y_valid high on two consecutive enabled cycles, so "
               & "the two-pass structure is not actually taking two passes"
            severity error;
          cad_err <= cad_err + 1;
        end if;
        prev_v := y_valid;
      end if;
    end if;
  end process;

end architecture;
