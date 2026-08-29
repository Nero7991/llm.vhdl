-- sim/tb_attn_emit.vhd
-- Bit-exactness of rtl/attn_emit.vhd (subsystem C, site 6f) against
-- ref/attn_emit_vec.c.
--
-- NO TOLERANCE.  The C generator's five oracles establish that the integer
-- recipe means the right thing -- the pack reconstructed in floating point
-- inside a bound DERIVED per case, the peak window as an exact inequality,
-- e_min and the non-negativity of every alignment shift as exact statements,
-- the DIRECTION of the alignment separated from a round by an inequality, and
-- the mantissa range derived from the peak window.  This file's job is the
-- narrower one of proving the RTL reproduces that recipe exactly.
--
-- WHAT IS CHECKED:
--   y_mant     every mantissa, exactly, in order, with its index.
--   y_exp      SEPARATELY from the mantissas, and that separation is the whole
--              reason the check is diagnosable.  A shp one too small makes
--              every mantissa exactly twice too large AND y_exp exactly one too
--              high, which denotes the same real value: a testbench that
--              reconstructed mant * 2^-exp and compared against a tolerance
--              sees NOTHING.  attn_kv_quant's write-up records that failure
--              verbatim, in the unit that does this same job per 32-element
--              block.
--   ORDERING   y_exp captured at the FIRST mantissa beat must already equal
--              its value at done.  From subsystem B's 2026-08-27 gdn_conv
--              defect, where a segment exponent was assigned in the FINAL
--              state and so described beats that had already gone past: the
--              value was right and only its time was wrong, and every value
--              check sampled at done passed.
--   hdr_valid  high before the first mantissa, and y_exp stable from there.
--   m_valid    HELD when m_ready is low, with m_data and m_index UNCHANGED
--              across the hold.  A valid held while the data moves underneath
--              it loses the element just as completely as a pulse and is much
--              quieter, because the COUNT still comes out right.
--   x_re       LOW while the emit pass is frozen.  A stall that froze x_raddr
--              but left the memory enabled makes the memory overwrite its
--              output register with the element still in flight, and on resume
--              the capture stage takes the wrong element with the right index.
--              The memory model below implements the enable for that reason;
--              a testbench memory that ignores x_re does not test it.
--   cfg_taken  pulses at start, and e_grid is POISONED immediately afterwards.
--              It is read across BOTH passes, so a DUT that read it live
--              aligns pass B differently from pass A -- every value in range,
--              the count right, and the peak window quietly wrong.
--   done       HELD across ACK_LAG (RULE 1) and raised only after the LAST
--              mantissa has been ACCEPTED.
--   o_sat      matches the golden exactly.  The pack's top rail is REACHABLE
--              -- the peak can round to exactly 2^15 -- so it is a value to
--              check, not a flag to hope stays clear.
--   err        must stay clear: e_min is the minimum of the same latched
--              array, so no alignment shift can be negative.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_attn_emit is
  generic( NCASE : positive := 40;
           NGRP  : positive := 2;
           GRP_N : positive := 48;
           IN_W  : positive := 24;
           MANT_W: positive := 16;
           EXP_W : positive := 8;
           TARGET_MSB : natural := 14;
           -- Period of the consumer's ready.  0 = tie it high, which is the
           -- DEGENERATE configuration and the default a consumer that never
           -- stalls presents.  Non-zero must exceed the 7-stage emit pipeline
           -- or a DUT that lets the pipeline run under a held valid is
           -- indistinguishable from one that freezes it.
           M_GAP   : natural := 3;
           ACK_LAG : natural := 4;
           HEARTBEAT_US : natural := 0;
           VECS  : string := "attn_emit_vec.txt" );
end entity;

architecture sim of tb_attn_emit is
  constant NTOT : integer := NGRP * GRP_N;
  constant AW   : integer := clog2(NTOT);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal start     : std_logic := '0';
  signal e_grid    : std_logic_vector(NGRP*EXP_W-1 downto 0)
                   := (others => '0');
  signal cfg_taken : std_logic;
  signal busy      : std_logic;

  signal x_raddr : std_logic_vector(AW-1 downto 0);
  signal x_re    : std_logic;
  signal x_rdata : std_logic_vector(IN_W-1 downto 0) := (others => '0');

  signal hdr_valid : std_logic;
  signal y_exp     : signed(EXP_W-1 downto 0);

  signal m_valid : std_logic;
  signal m_data  : std_logic_vector(MANT_W-1 downto 0);
  signal m_index : std_logic_vector(AW-1 downto 0);
  signal m_ready : std_logic;

  signal done     : std_logic;
  signal done_ack : std_logic := '1';
  signal o_sat, err : std_logic;

  type int_arr is array (natural range <>) of integer;
  -- Written by stim only.
  signal mem : int_arr(0 to NTOT-1) := (others => 0);
  -- Written by the monitor only, so there is exactly one driver each.
  signal m_got : int_arr(0 to 4095) := (others => 0);
  signal i_got : int_arr(0 to 4095) := (others => 0);
  signal m_cnt : integer := 0;
  signal clr   : std_logic := '0';

  signal mon_err : integer := 0;
  signal ord_err : integer := 0;
  -- Captured by ord_chk only, read by stim: the exponent as it stood at the
  -- FIRST mantissa beat, which is the value a consumer would actually use.
  signal ord_lat  : signed(EXP_W-1 downto 0) := (others => '0');
  signal ord_seen : std_logic := '0';
  -- and as it stood at the rising edge of hdr_valid, which is the instant the
  -- unit CLAIMS it is valid.
  signal ord_hlat : signed(EXP_W-1 downto 0) := (others => '0');
  signal ord_hdr  : std_logic := '0';
  signal nerr    : integer := 0;
  signal tick    : integer := 0;

  -- ==================================================================
  -- THE ONE-GROUP CONFIGURATION, run alongside the main DUT.
  --
  -- NGRP is a `positive` generic and NGRP = 1 -- a card holding one KV head --
  -- is a legal value of it.  It was ALSO an immediate bound violation:
  -- rtl/attn_emit.vhd's S_IDLE assigned `grp <= 1` unconditionally into a
  -- signal declared `range 0 to NGRP-1`, and had the range been wider the
  -- NGRP = 1 path would then have entered S_SHIFTS reading e_l(1) of a
  -- one-element array.  MEASURED before the fix, driving this bench at
  -- -gNGRP=1:
  --     ghdl:error: bound check failure at rtl/attn_emit.vhd:400
  --     in process .tb_attn_emit(sim).dut@attn_emit(rtl).P13
  -- Worklog OI-2.  Nothing hit it because every configuration anywhere in the
  -- tree uses NGRP >= 2, and regress.sh's own vector row carries the comment
  -- "N_KVH >= 2 is REQUIRED" naming this defect as the reason.
  --
  -- WHY A SECOND INSTANCE RATHER THAN A SECOND VECTOR FILE.  ref/attn_emit_vec
  -- gates its own output on a coverage table that includes "e_grid values that
  -- DIFFER", and at one group that counter is structurally zero -- there is
  -- only one exponent -- so the generator exits non-zero at ngrp = 1 and
  -- regress.sh would read that as a failed vector generation.  Its GOLDEN at
  -- ngrp = 1 is correct (checked directly: 40 layers x 48 elements bit-exact);
  -- it is the coverage gate, not the model, that cannot be met.  So the
  -- one-group case rides on the vectors already here.
  --
  -- WHAT IT PROVES.  Every case: NTOT mantissas come out, in index order, with
  -- err low -- which is enough for the bound violation, since it aborts the
  -- run outright.  Additionally, on every case whose e_grid entries are all
  -- EQUAL, the one-group answer must be bit-identical to the golden: e_min is
  -- that common exponent, every alignment shift is zero on both sides, and
  -- pass A scans the same NTOT elements, so grouping cannot change amax, shp,
  -- any mantissa, or y_exp.  That subset is checked against the same file.
  signal start1   : std_logic := '0';
  signal e_grid1  : std_logic_vector(EXP_W-1 downto 0) := (others => '0');
  signal cfg_tk1  : std_logic;
  signal busy1    : std_logic;
  signal x_raddr1 : std_logic_vector(AW-1 downto 0);
  signal x_re1    : std_logic;
  signal x_rdata1 : std_logic_vector(IN_W-1 downto 0) := (others => '0');
  signal hdr_v1   : std_logic;
  signal y_exp1   : signed(EXP_W-1 downto 0);
  signal m_valid1 : std_logic;
  signal m_data1  : std_logic_vector(MANT_W-1 downto 0);
  signal m_index1 : std_logic_vector(AW-1 downto 0);
  signal done1    : std_logic;
  signal o_sat1, err1 : std_logic;
  signal m_got1 : int_arr(0 to 4095) := (others => 0);
  signal i_got1 : int_arr(0 to 4095) := (others => 0);
  signal m_cnt1 : integer := 0;
  signal n_eqc  : integer := 0;   -- cases with an all-equal e_grid
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.attn_emit
    generic map ( NGRP => NGRP, GRP_N => GRP_N, IN_W => IN_W,
                  MANT_W => MANT_W, EXP_W => EXP_W,
                  TARGET_MSB => TARGET_MSB, SH_MAX => 63,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               start => start, e_grid => e_grid, cfg_taken => cfg_taken,
               busy => busy,
               x_raddr => x_raddr, x_re => x_re, x_rdata => x_rdata,
               hdr_valid => hdr_valid, y_exp => y_exp,
               m_valid => m_valid, m_data => m_data, m_index => m_index,
               m_ready => m_ready,
               done => done, done_ack => done_ack,
               o_sat => o_sat, err => err );

  -- The one-group instance.  GRP_N is the FLAT length, so both instances see
  -- the same NTOT elements and the same address width.
  dut1 : entity work.attn_emit
    generic map ( NGRP => 1, GRP_N => NTOT, IN_W => IN_W,
                  MANT_W => MANT_W, EXP_W => EXP_W,
                  TARGET_MSB => TARGET_MSB, SH_MAX => 63,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               start => start1, e_grid => e_grid1, cfg_taken => cfg_tk1,
               busy => busy1,
               x_raddr => x_raddr1, x_re => x_re1, x_rdata => x_rdata1,
               hdr_valid => hdr_v1, y_exp => y_exp1,
               m_valid => m_valid1, m_data => m_data1, m_index => m_index1,
               m_ready => m_ready,
               done => done1, done_ack => done_ack,
               o_sat => o_sat1, err => err1 );

  -- THE COMPLETION HANDSHAKE, as a property.  See sim/hsk_chk.vhd's header for
  -- the contract and for why a `done_r` clear inside the ack branch was an
  -- ABORT in five harnesses and a detection in none.  Both instances are
  -- covered: they share done_ack, and it is the ack's timing relative to each
  -- unit's own completion that the class of defect turns on.
  --
  -- DEADLINE = 12000.  MEASURED with NOTE_MAX => true: the worst start-to-done
  -- latency on the clean design is 1267 cycles (configuration C, M_GAP = 11,
  -- the slow-consumer column; 497 in A, 211 in B); 12000 is 9.5x that.  Do not
  -- "tighten" it -- a deadline near the real latency turns a wider vector set
  -- into a red gate, and this clause is a timeout, so its only job is to be
  -- finite.
  hsk : entity work.hsk_chk
    generic map ( NAME => "attn_emit", DEADLINE => 12000 )
    port map ( clk => clk, rst => rst, start_ev => cfg_taken,
               done => done, ack => done_ack );

  hsk1 : entity work.hsk_chk
    generic map ( NAME => "attn_emit NGRP=1", DEADLINE => 12000 )
    port map ( clk => clk, rst => rst, start_ev => cfg_tk1,
               done => done1, ack => done_ack );

  memp1 : process(clk)
  begin
    if rising_edge(clk) then
      if x_re1 = '1' then
        x_rdata1 <= std_logic_vector(
                      to_signed(mem(to_integer(unsigned(x_raddr1))), IN_W));
      end if;
    end if;
  end process;

  -- Accepted-beat capture for the one-group instance.  Deliberately thinner
  -- than mon below: the handshake properties are the SAME RTL and are already
  -- proved on the main instance, so this one carries only what the grouping
  -- can change -- how many elements come out, in what order, and their values.
  mon1 : process
  begin
    loop
      wait until rising_edge(clk);
      exit when not running;
      if clr = '1' then
        m_cnt1 <= 0;
      elsif m_valid1 = '1' and m_ready = '1' then
        if m_cnt1 < 4096 then
          m_got1(m_cnt1) <= to_integer(signed(m_data1));
          i_got1(m_cnt1) <= to_integer(unsigned(m_index1));
        end if;
        m_cnt1 <= m_cnt1 + 1;
      end if;
    end loop;
    wait;
  end process;

  -- THE MEMORY IMPLEMENTS x_re.  A model that ignored the enable would make
  -- mutation "x_re tied high" an EQUIVALENT MUTANT, which is exactly what
  -- happened to attn_kv_quant's M6 at M_GAP = 0.
  memp : process(clk)
  begin
    if rising_edge(clk) then
      if x_re = '1' then
        x_rdata <= std_logic_vector(
                     to_signed(mem(to_integer(unsigned(x_raddr))), IN_W));
      end if;
    end if;
  end process;

  -- A FREE-RUNNING ready pattern, not one keyed off the accepted count.
  -- tb_attn_kv_quant's write-up records that a ready derived from the accepted
  -- count DEADLOCKS: nothing is accepted while it is low, so the condition
  -- that lowered it never clears, and the run looks like a DUT hang.
  tickp : process(clk)
  begin
    if rising_edge(clk) then tick <= tick + 1; end if;
  end process;
  m_ready <= '1' when M_GAP = 0 else
             '1' when (tick mod (M_GAP + 1)) = M_GAP else '0';

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: busy=" & std_logic'image(busy)
           & " m_valid=" & std_logic'image(m_valid)
           & " m_ready=" & std_logic'image(m_ready)
           & " done=" & std_logic'image(done) severity note;
    end loop;
    wait;
  end process;

  -- ==================================================================
  -- MONITOR.  Samples at the rising edge, which reads the PRE-edge value.
  -- Sampling after the edge reads the post-edge value and, on the last item of
  -- a burst, fires on correct behaviour; that trap cost a run in
  -- tb_attn_score_q12 and is recorded in the kv-quant write-up.
  -- ==================================================================
  mon : process
    variable mv_d, mr_d : std_logic := '0';
    variable dn_d       : std_logic := '0';
    variable d_d, i_d   : integer := 0;
  begin
    loop
      wait until rising_edge(clk);
      exit when not running;
      if clr = '1' then
        m_cnt <= 0; mv_d := '0'; mr_d := '0'; dn_d := '0';
      else
        if m_valid = '1' and m_ready = '1' then
          if m_cnt < 4096 then
            m_got(m_cnt) <= to_integer(signed(m_data));
            i_got(m_cnt) <= to_integer(unsigned(m_index));
          end if;
          m_cnt <= m_cnt + 1;
        end if;

        if mv_d = '1' and mr_d = '0' then
          if m_valid /= '1' then
            report "m_valid FELL without a ready -- the mantissa is a pulse, "
                 & "and a consumer busy at that instant loses it entirely"
              severity error;
            mon_err <= mon_err + 1;
          elsif to_integer(signed(m_data)) /= d_d
                or to_integer(unsigned(m_index)) /= i_d then
            report "m_data/m_index CHANGED while m_valid was held and m_ready "
                 & "was low -- the emit pass advanced under a blocked output, "
                 & "so the mantissa standing there is lost while the COUNT "
                 & "still comes out right" severity error;
            mon_err <= mon_err + 1;
          end if;
        end if;

        -- The read enable must fall WITH the freeze, in the SAME cycle, or the
        -- memory overwrites its output register with the element in flight.
        -- Checked on the current sample and not on the delayed one: emit_en is
        -- combinational, so the cycle in which m_valid is high and m_ready is
        -- low is the cycle in which x_re must already be low.  Written against
        -- the delayed sample first, which fired on correct behaviour -- the
        -- same off-by-one-cycle trap as tb_attn_score_q12's p_ready check.
        if m_valid = '1' and m_ready = '0' and x_re = '1' then
          report "x_re was high while the emit pass was frozen -- the memory "
               & "will overwrite its output register with the element still "
               & "in flight, and on resume the capture stage takes the wrong "
               & "element with the RIGHT index" severity error;
          mon_err <= mon_err + 1;
        end if;

        -- `done` means the LAYER is finished, which includes the last
        -- mantissa having been ACCEPTED.  Mutation E19 -- done raised at
        -- production rather than at acceptance -- SURVIVED without this,
        -- because the held m_valid means the element is eventually taken
        -- anyway in this testbench.  It is still a defect: a consumer that
        -- acks done and issues the next start on the following cycle takes the
        -- unit out of S_DONE with that mantissa still standing, and it is then
        -- lost.  The rising edge is the only instant at which the claim can be
        -- checked.
        if dn_d = '0' and done = '1' and m_valid = '1' then
          report "done ROSE while a mantissa was still unaccepted -- the layer "
               & "is not finished, and a consumer that acks and restarts on "
               & "the next cycle loses that element" severity error;
          mon_err <= mon_err + 1;
        end if;
        dn_d := done;

        mv_d := m_valid;
        mr_d := m_ready;
        d_d  := to_integer(signed(m_data));
        i_d  := to_integer(unsigned(m_index));
      end if;
    end loop;
    wait;
  end process;

  -- ==================================================================
  -- ORDERING GUARD.  See the header.  Capture y_exp at the FIRST mantissa
  -- beat and require it to already equal the value at done.
  --
  -- to_string, NOT integer'image(to_integer(...)): on a DUT with the defect
  -- the scalar is still metavalued at the first beat, and to_integer then
  -- raises INSIDE the report expression, so the run dies at
  -- numeric_std-body.vhdl with no message at all and the guard looks like a
  -- testbench bug.
  -- ==================================================================
  ord_chk : process
    variable first : boolean := true;
    variable hv_d  : std_logic := '0';
  begin
    loop
      wait until rising_edge(clk);
      exit when not running;
      if clr = '1' then
        first := true;
        ord_seen <= '0';
        ord_hdr  <= '0';
        hv_d := '0';
      else
        -- hdr_valid RISING is the instant the unit says "y_exp is valid now",
        -- and it is captured separately from the first mantissa beat because
        -- the two are different claims.  Mutation E16 -- hdr_valid raised at
        -- START, before the scan pass has even run -- SURVIVED when only the
        -- first-beat capture existed: y_exp was still published in time, so
        -- every value check passed while the flag that announces it had become
        -- a lie for the whole scan.  A consumer that latched on the rising
        -- edge would take the PREVIOUS layer's exponent.
        if hv_d = '0' and hdr_valid = '1' then
          ord_hlat <= y_exp;
          ord_hdr  <= '1';
        end if;
        hv_d := hdr_valid;

        if m_valid = '1' and first then
          first := false;
          if hdr_valid /= '1' then
            report "ORDERING: the first mantissa was offered while hdr_valid "
                 & "was still low -- y_exp reads " & to_string(y_exp)
                 & ".  A scalar that qualifies a stream must be assigned "
                 & "STRICTLY EARLIER than the state that first raises that "
                 & "stream's valid" severity error;
            ord_err <= ord_err + 1;
          end if;
          ord_lat <= y_exp;
          ord_seen <= '1';
        end if;
      end if;
    end loop;
    wait;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, ng, gn, iw, mw, tm : integer;
    variable c_id, c_emin, c_shp, c_yexp, c_nsat : integer;
    variable v_e : int_arr(0 to 15);
    variable v_m : int_arr(0 to 4095);
    variable ok  : boolean;
    variable eq_grid, ok1 : boolean;
    variable d_seen, d1_seen : boolean;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln);
    read(ln, nc); read(ln, ng); read(ln, gn); read(ln, iw);
    read(ln, mw); read(ln, tm);
    assert nc = NCASE and ng = NGRP and gn = GRP_N and iw = IN_W
           and mw = MANT_W and tm = TARGET_MSB
      report "tb_attn_emit: vector file shape mismatch" severity failure;

    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, c_id);
      for g in 0 to NGRP-1 loop read(ln, iv); v_e(g) := iv; end loop;
      read(ln, c_emin); read(ln, c_shp); read(ln, c_yexp); read(ln, c_nsat);
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); mem(i) <= iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_m(i) := iv; end loop;

      clr <= '1';
      wait until rising_edge(clk);
      clr <= '0';
      wait until rising_edge(clk);

      if ACK_LAG > 0 then done_ack <= '0'; else done_ack <= '1'; end if;

      for g in 0 to NGRP-1 loop
        e_grid((g+1)*EXP_W-1 downto g*EXP_W)
          <= std_logic_vector(to_signed(v_e(g), EXP_W));
      end loop;
      -- the one-group instance takes the SAME elements under group 0's
      -- exponent; see its declaration for why that is the golden's answer
      -- exactly when every entry of e_grid is the same value
      eq_grid := true;
      for g in 1 to NGRP-1 loop
        if v_e(g) /= v_e(0) then eq_grid := false; end if;
      end loop;
      e_grid1 <= std_logic_vector(to_signed(v_e(0), EXP_W));
      wait until rising_edge(clk);
      start <= '1'; start1 <= '1';
      wait until rising_edge(clk);
      -- 1 ns past the edge, not at it: `wait until rising_edge(clk)` resumes
      -- in the SAME delta as the edge, so a pulse the DUT assigns on that edge
      -- still reads as '0' and looks exactly like a missing pulse.  Carried
      -- over from tb_attn_kv_quant; it has now been the right call five times.
      wait for 1 ns;
      assert cfg_taken = '1'
        report "case " & integer'image(c)
             & ": cfg_taken did not pulse at start" severity error;
      start <= '0'; start1 <= '0';
      -- RULE 2: poison e_grid the instant it has been taken.  It is read
      -- across BOTH passes; a DUT that reads it live aligns pass B by the
      -- poison and pass A by the truth, which leaves every value in range.
      e_grid  <= (others => '1');
      e_grid1 <= (others => '1');

      -- BOTH instances' done, waited for JOINTLY rather than one after the
      -- other.  At ACK_LAG = 0 done_ack already stands high when the unit
      -- completes, so the ack is present the instant done rises and `done` is
      -- legally high for exactly ONE cycle: RULE 1 says HELD UNTIL ACKED, and
      -- an ack that is already there is satisfied immediately.  The two
      -- instances do NOT finish together -- MEASURED 2026-08-29 by
      -- instrumenting a scratch copy of this bench at -gM_GAP=0 -gACK_LAG=0:
      --     DBG done1=1 tick=217   @2175ns
      --     DBG done=1  tick=219   @2195ns
      -- the one-group instance has no S_EMIN pass, so it reaches S_DONE two
      -- cycles EARLIER, every case.  Waiting for `done` first therefore
      -- consumed done1's whole pulse, and the second loop then waited for a
      -- signal that would never rise again until the next start that this
      -- process itself was supposed to issue.
      --
      -- That deadlock is why configuration B of sim/mutate_attn_emit.sh
      -- (-gM_GAP=0 -gACK_LAG=0) WEDGED ON THE UNMUTATED DESIGN, and under the
      -- old two-way judging its silence scored as a KILL on every row of that
      -- harness.  The defect was in this bench, not in rtl/attn_emit.vhd.
      -- Latch each pulse as it is seen instead.  At ACK_LAG > 0 both done
      -- signals are HELD, so this is exactly equivalent to the two sequential
      -- loops and configurations A and C are unchanged.
      d_seen  := done  = '1';
      d1_seen := done1 = '1';
      while not (d_seen and d1_seen) loop
        wait until rising_edge(clk);
        if done  = '1' then d_seen  := true; end if;
        if done1 = '1' then d1_seen := true; end if;
      end loop;
      for k in 1 to ACK_LAG loop
        wait until rising_edge(clk);
        if done /= '1' then
          report "case " & integer'image(c)
               & ": done fell before done_ack -- it is a pulse, and a consumer "
               & "busy at that instant loses the layer" severity error;
          nerr <= nerr + 1;
          exit;
        end if;
      end loop;

      -- ---- the exponent, SEPARATELY from the mantissas ---------------
      if to_integer(y_exp) /= c_yexp then
        report "case " & integer'image(c) & ": y_exp got "
             & integer'image(to_integer(y_exp)) & " want "
             & integer'image(c_yexp) & "  (e_min " & integer'image(c_emin)
             & " shp " & integer'image(c_shp) & ")" severity error;
        nerr <= nerr + 1;
      end if;
      if ord_hdr /= '1' then
        report "case " & integer'image(c)
             & ": hdr_valid never rose during this layer" severity error;
        nerr <= nerr + 1;
      elsif to_integer(ord_hlat) /= c_yexp then
        report "case " & integer'image(c) & ": y_exp read "
             & to_string(ord_hlat) & " at the RISING EDGE of hdr_valid and "
             & to_string(y_exp) & " at done.  hdr_valid means the exponent is "
             & "valid NOW; raising it before the scan pass has produced one "
             & "hands a consumer that latches on that edge the PREVIOUS "
             & "layer's exponent" severity error;
        nerr <= nerr + 1;
      end if;
      if ord_seen = '1' and to_integer(ord_lat) /= c_yexp then
        report "case " & integer'image(c) & ": y_exp read "
             & to_string(ord_lat) & " at the first mantissa and "
             & to_string(y_exp) & " at done -- the exponent moved DURING the "
             & "stream it describes" severity error;
        nerr <= nerr + 1;
      end if;
      if hdr_valid /= '1' then
        report "case " & integer'image(c)
             & ": hdr_valid is low at done" severity error;
        nerr <= nerr + 1;
      end if;

      -- ---- the mantissas ---------------------------------------------
      if m_cnt /= NTOT then
        report "case " & integer'image(c) & ": " & integer'image(m_cnt)
             & " mantissas came out, want " & integer'image(NTOT)
             & " -- elements were dropped, not delayed" severity error;
        nerr <= nerr + 1;
      end if;
      ok := true;
      for i in 0 to NTOT-1 loop
        if i < m_cnt then
          if i_got(i) /= i then
            if ok then
              report "case " & integer'image(c) & " beat " & integer'image(i)
                   & ": m_index got " & integer'image(i_got(i)) & " want "
                   & integer'image(i) & " -- the stream is out of order"
                severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
          if m_got(i) /= v_m(i) then
            if ok then
              report "case " & integer'image(c) & " elem " & integer'image(i)
                   & ": mant got " & integer'image(m_got(i)) & " want "
                   & integer'image(v_m(i)) & "  (y_pre "
                   & integer'image(mem(i)) & " shp " & integer'image(c_shp)
                   & " y_exp " & integer'image(c_yexp) & ")" severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
        end if;
      end loop;

      if (c_nsat > 0 and o_sat /= '1') or (c_nsat = 0 and o_sat /= '0') then
        report "case " & integer'image(c) & ": o_sat is "
             & std_logic'image(o_sat) & " but the golden says "
             & integer'image(c_nsat) & " mantissas saturated" severity error;
        nerr <= nerr + 1;
      end if;
      -- ---- the one-group instance ------------------------------------
      -- Count, order and err on EVERY case; values only where the grouping
      -- provably cannot change them.  See the declaration block.
      ok1 := true;
      if m_cnt1 /= NTOT then
        report "case " & integer'image(c) & ": NGRP=1 emitted "
             & integer'image(m_cnt1) & " mantissas, want "
             & integer'image(NTOT) severity error;
        nerr <= nerr + 1; ok1 := false;
      end if;
      if err1 /= '0' then
        report "case " & integer'image(c) & ": NGRP=1 raised err -- with one "
             & "group e_min IS the only exponent, so no alignment shift can "
             & "be negative" severity error;
        nerr <= nerr + 1; ok1 := false;
      end if;
      for i in 0 to NTOT-1 loop
        if i < m_cnt1 and i_got1(i) /= i and ok1 then
          report "case " & integer'image(c) & " beat " & integer'image(i)
               & ": NGRP=1 m_index got " & integer'image(i_got1(i))
               & " want " & integer'image(i) severity error;
          nerr <= nerr + 1; ok1 := false;
        end if;
      end loop;
      if eq_grid then
        n_eqc <= n_eqc + 1;
        if to_integer(y_exp1) /= c_yexp then
          report "case " & integer'image(c) & ": NGRP=1 y_exp got "
               & integer'image(to_integer(y_exp1)) & " want "
               & integer'image(c_yexp) & " -- every e_grid entry is equal "
               & "here, so grouping cannot move the exponent" severity error;
          nerr <= nerr + 1;
        end if;
        if (c_nsat > 0 and o_sat1 /= '1') or (c_nsat = 0 and o_sat1 /= '0') then
          report "case " & integer'image(c) & ": NGRP=1 o_sat is "
               & std_logic'image(o_sat1) & " but the golden says "
               & integer'image(c_nsat) & " mantissas saturated" severity error;
          nerr <= nerr + 1;
        end if;
        for i in 0 to NTOT-1 loop
          if i < m_cnt1 and m_got1(i) /= v_m(i) and ok1 then
            report "case " & integer'image(c) & " elem " & integer'image(i)
                 & ": NGRP=1 mant got " & integer'image(m_got1(i)) & " want "
                 & integer'image(v_m(i)) & " -- all e_grid entries equal, so "
                 & "one group of " & integer'image(NTOT) & " must give the "
                 & "same answer as " & integer'image(NGRP) & " groups of "
                 & integer'image(GRP_N) severity error;
            nerr <= nerr + 1; ok1 := false;
          end if;
        end loop;
      end if;

      if err /= '0' then
        report "case " & integer'image(c) & ": err fired -- an alignment shift "
             & "came out negative, which e_min being the minimum of the same "
             & "latched array makes impossible" severity error;
        nerr <= nerr + 1;
      end if;

      done_ack <= '1';
      wait until rising_edge(clk);
      while busy = '1' or busy1 = '1' loop wait until rising_edge(clk); end loop;
    end loop;
    file_close(fh);

    wait until rising_edge(clk);
    -- The one-group value check is only as good as the number of cases whose
    -- e_grid entries happen to be equal.  If a future vector set has none, the
    -- check silently becomes a count-and-order test, so say so loudly instead.
    assert n_eqc > 0
      report "tb_attn_emit: no case in this vector set has an all-equal "
           & "e_grid, so the NGRP=1 instance was never value-checked -- only "
           & "its element count and ordering were" severity failure;
    if nerr = 0 and mon_err = 0 and ord_err = 0 then
      report "tb_attn_emit: PASS -- " & integer'image(NCASE) & " layers x "
           & integer'image(NTOT) & " elements bit-exact on the mantissas AND "
           & "separately on y_exp, with the exponent already published and "
           & "stable at the first mantissa beat, e_grid poisoned immediately "
           & "after cfg_taken, m_valid and its data held across a blocked "
           & "ready with x_re low throughout, indices in order, done raised "
           & "only after the last mantissa was accepted, and o_sat matching "
           & "the golden.  A second instance at NGRP=1 -- one KV head, a legal "
           & "generic that used to be an immediate bound violation -- ran the "
           & "same " & integer'image(NCASE) & " layers as ONE group of "
           & integer'image(NTOT) & ", in order and with err low on every one, "
           & "and matched the golden exactly on the "
           & integer'image(n_eqc) & " of them whose e_grid entries are all "
           & "equal.  M_GAP=" & integer'image(M_GAP) & " ACK_LAG="
           & integer'image(ACK_LAG) severity note;
    else
      report "tb_attn_emit: FAIL -- "
           & integer'image(nerr + mon_err + ord_err) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
