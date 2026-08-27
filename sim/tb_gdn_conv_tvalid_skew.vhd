-- tb_gdn_conv_tvalid_skew: demonstrates finding B-3 of
-- docs/debugging/2026-08-27_B-interface-audit.md.
--
-- THE DEFECT UNDER TEST.  gdn_conv latches e_ref and the four per-tap shifts
-- shf(t) ONCE, at S_PREP, but re-reads the live `tvalid` port combinationally
-- at pass-A stage 2 for every group.  If tvalid changes during pass A the mask
-- and the shifts disagree: a tap that was invalid at S_PREP carries shf(t)=0,
-- so if it turns valid mid-pass its product is summed UNSHIFTED, on the wrong
-- power-of-two grid; a tap that was valid at S_PREP and turns invalid simply
-- vanishes from the tail of the segment.
--
-- WHY THE EXISTING tb_gdn_conv CANNOT SEE IT.  sim/tb_gdn_conv.vhd assigns
-- tvalid once per case, before `start`, and never touches it again.  Its
-- producer is maximally quiescent.  That is precisely the testbench shape the
-- gdn_emit_chain w_mant note warns about: a stimulus that holds its inputs
-- constant cannot see a missing latch.
--
-- WHY THIS ONE CAN, WITHOUT CHEATING.  tvalid is NOT driven by this testbench.
-- It is driven by the real rtl/gdn_exp_capture.vhd, port-mapped straight into
-- the DUT, and the only thing this testbench does to it is issue a perfectly
-- ordinary `rd_req` for a DIFFERENT (layer, segment) entry while the conv is
-- streaming -- a sequencer prefetching the next segment's tap exponents.
-- gdn_exp_capture holds e_t/tvalid as free-running levels from one read until
-- the next, so that read reassigns tvalid under the running conv.  No value is
-- forced onto the port that the real producer could not produce, and every
-- capture/read this testbench performs obeys gdn_exp_capture's own handshake.
--
-- CONTROL.  Every case is run TWICE: once with the mid-pass read (SKEW) and
-- once without it (CONTROL), same data, same entry, same everything.  CONTROL
-- must be bit-exact against the in-testbench reference.  Without that pair the
-- run would only show that the testbench and the DUT disagree, not that the
-- skew is what makes them disagree.
--
-- The lane loop index is `ln`, not `k`: VHDL is case-insensitive and `for k`
-- would shadow the generic K.  Same trap as the DUT and the older testbench.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_gdn_conv_tvalid_skew is
  generic(
    CH_MAX   : positive := 256;  -- segment length driven (nch = CH_MAX)
    K        : positive := 4;
    LANES    : positive := 8;
    -- Group index at which the prefetching read is issued.  Chosen mid-pass so
    -- the segment has a clean head and a clean tail.
    RDREQ_AT : natural  := 16
  );
end entity;

architecture sim of tb_gdn_conv_tvalid_skew is

  constant CH    : positive := CH_MAX;
  constant NB    : integer  := CH / LANES;
  constant TCLK  : time     := 10 ns;

  -- gdn_exp_capture geometry.  Two layers, three segments, so a prefetch of a
  -- different entry is expressible.
  constant LAYERS : positive := 2;
  constant SEGS   : positive := 3;

  -- Entry A: the segment being convolved.  Four captures, so tvalid = 1111.
  constant A_LAY : integer := 0;
  constant A_SEG : integer := 2;
  -- Entry B: a different segment at the START of a sequence.  Its words are
  -- all written (before a seq_rst) but its counter is 1, so tvalid = 1000.
  constant B_LAY : integer := 1;
  constant B_SEG : integer := 0;

  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal running : boolean   := true;

  -- gdn_exp_capture ports
  signal seq_rst   : std_logic := '0';
  signal cap_req   : std_logic := '0';
  signal cap_layer : integer range 0 to LAYERS-1 := 0;
  signal cap_seg   : integer range 0 to SEGS-1 := 0;
  signal cap_exp   : signed(7 downto 0) := (others => '0');
  signal cap_ready : std_logic;
  signal rd_req    : std_logic := '0';
  signal rd_layer  : integer range 0 to LAYERS-1 := 0;
  signal rd_seg    : integer range 0 to SEGS-1 := 0;
  signal rd_ack    : std_logic;

  -- the shared seam: driven by gdn_exp_capture, consumed by gdn_conv
  signal e_t    : std_logic_vector(K*8-1 downto 0);
  signal tvalid : std_logic_vector(K-1 downto 0);

  -- gdn_conv ports
  signal start, s_valid, o_valid, o_done, err_seg, ready : std_logic := '0';
  signal cw_exp : signed(7 downto 0) := (others => '0');
  signal x_in, w_in : std_logic_vector(K*LANES*16-1 downto 0) := (others => '0');
  signal o_data : std_logic_vector(LANES*16-1 downto 0);
  signal e_seg  : signed(7 downto 0);
  signal sh_seg : integer range 0 to 63;

  type i_arr   is array (natural range <>) of integer;
  type s34_arr is array (natural range <>) of signed(33 downto 0);

  -- ---------------------------------------------------------------- helpers
  function to_str(v : std_logic_vector) return string is
    variable s : string(1 to v'length);
    variable i : integer := 1;
  begin
    for j in v'high downto v'low loop
      case v(j) is
        when '0' => s(i) := '0';
        when '1' => s(i) := '1';
        when 'U' => s(i) := 'U';
        when others => s(i) := 'X';
      end case;
      i := i + 1;
    end loop;
    return s;
  end function;

  function msb_pos(a : unsigned) return integer is
    variable p : integer := 0;
  begin
    for i in a'low to a'high loop
      if a(i) = '1' then p := i - a'low; end if;
    end loop;
    return p;
  end function;

  function sat16(v : signed) return integer is
  begin
    if    v >  32767 then return  32767;
    elsif v < -32768 then return -32768;
    else                  return to_integer(resize(v, 17)); end if;
  end function;

  -- xorshift32.  Plain `seed * 1103515245` overflows GHDL's 32-bit integer and
  -- aborts, which is trap 5 of the conv cycle-model note.
  function nextr(s : unsigned(31 downto 0)) return unsigned is
    variable v : unsigned(31 downto 0) := s;
  begin
    v := v xor shift_left(v, 13);
    v := v xor shift_right(v, 17);
    v := v xor shift_left(v, 5);
    return v;
  end function;

  -- The recipe of rtl/gdn_conv.vhd's header, transcribed once, with ONE extra
  -- knob: `gsplit` is the first GROUP whose stage-2 mask is m2 instead of m1.
  -- gsplit = NB means "mask never changed", i.e. the correct reference.  The
  -- SHIFTS are always shf, taken from m1 -- that asymmetry IS the defect.
  procedure model(constant xv, wv : in  i_arr;
                  constant shf    : in  i_arr;
                  constant m1, m2 : in  std_logic_vector;
                  constant gsplit : in  integer;
                  constant eref   : in  integer;
                  constant cw     : in  integer;
                  variable sm     : out i_arr;
                  variable sh_o   : out integer;
                  variable es_o   : out integer) is
    variable acc  : s34_arr(0 to CH-1);
    variable am   : unsigned(33 downto 0) := (others => '0');
    variable mag  : unsigned(33 downto 0);
    variable msk  : std_logic_vector(K-1 downto 0);
    variable sum  : signed(33 downto 0);
    variable prod : signed(31 downto 0);
    variable p, sh : integer;
    variable bias : signed(33 downto 0);
  begin
    for c in 0 to CH-1 loop
      if c / LANES < gsplit then msk := m1; else msk := m2; end if;
      sum := (others => '0');
      for t in 0 to K-1 loop
        if msk(t) = '1' then
          prod := resize(to_signed(xv(c*K+t), 16) * to_signed(wv(c*K+t), 16), 32);
          sum  := sum + resize(shift_right(prod, shf(t)), 34);
        end if;
      end loop;
      acc(c) := sum;
    end loop;
    for c in 0 to CH-1 loop
      if acc(c) < 0 then mag := unsigned(-acc(c)); else mag := unsigned(acc(c)); end if;
      if mag > am then am := mag; end if;
    end loop;
    p := msb_pos(am);
    if p - 14 > 0 then
      sh := p - 14;
      bias := shift_left(to_signed(1, 34), sh - 1);
    else
      sh := 0;
      bias := (others => '0');
    end if;
    for c in 0 to CH-1 loop
      sm(c) := sat16(shift_right(acc(c) + bias, sh));
    end loop;
    sh_o := sh;
    es_o := eref + cw - sh;
  end procedure;

begin

  clk <= not clk after TCLK/2 when running else '0';

  u_cap : entity work.gdn_exp_capture
    generic map(LAYERS => LAYERS, SEGS => SEGS, K => K)
    port map(clk => clk, rst => rst, seq_rst => seq_rst,
             cap_req => cap_req, cap_layer => cap_layer, cap_seg => cap_seg,
             cap_exp => cap_exp, cap_ready => cap_ready,
             rd_req => rd_req, rd_layer => rd_layer, rd_seg => rd_seg,
             rd_ack => rd_ack, e_t => e_t, tvalid => tvalid);

  dut : entity work.gdn_conv
    generic map(CH_MAX => CH_MAX, K => K, LANES => LANES)
    port map(clk => clk, rst => rst, start => start,
             nch => CH, tvalid => tvalid, e_t => e_t, cw_exp => cw_exp,
             s_valid => s_valid, x_in => x_in, w_in => w_in,
             o_valid => o_valid, o_data => o_data, o_done => o_done,
             e_seg => e_seg, sh_seg => sh_seg, err_seg => err_seg,
             ready => ready);

  -- Purely observational: drives nothing, asserts nothing.  Reports the cycle
  -- at which each group is fetched near the split, and the cycle at which
  -- tvalid is seen to change.
  --
  -- NOTE ON THE ONE-CYCLE OFFSET.  Reading tvalid at a rising edge yields its
  -- PRE-edge value, so a change assigned by gdn_exp_capture at edge E is first
  -- reported here at edge E+1.  gdn_conv's stage 2 reads tvalid the same way,
  -- so the number printed here is exactly the first edge at which the DUT
  -- would see the new mask.  This is the same registered-output off-by-one the
  -- conv cycle-model note lists as trap 4.
  mon : process(clk)
    variable c   : integer := 0;
    variable g   : integer := 0;
    variable tvp : std_logic_vector(K-1 downto 0) := (others => 'X');
    variable armed : boolean := false;
  begin
    if rising_edge(clk) then
      if armed then c := c + 1; end if;
      if start = '1' then c := 0; g := 0; armed := true; end if;
      if tvp /= tvalid then
        if armed then
          report "MON  cycle " & integer'image(c) & ": tvalid " & to_str(tvp)
               & " -> " & to_str(tvalid) & "   (first edge the DUT sees it)";
        end if;
        tvp := tvalid;
      end if;
      if s_valid = '1' and ready = '1' then
        if g >= RDREQ_AT-2 and g <= RDREQ_AT+2 then
          report "MON  cycle " & integer'image(c) & ": group " & integer'image(g)
               & " fetched (channels " & integer'image(g*LANES) & ".."
               & integer'image(g*LANES+LANES-1) & ")";
        end if;
        g := g + 1;
      end if;
    end if;
  end process;

  drive : process
    variable xv, wv : i_arr(0 to CH*K-1);
    variable got    : i_arr(0 to CH-1);
    variable refsm  : i_arr(0 to CH-1);
    variable mdl    : i_arr(0 to CH-1);
    variable shf    : i_arr(0 to K-1);
    variable tv_prep, tv_post : std_logic_vector(K-1 downto 0);
    variable et_prep : std_logic_vector(K*8-1 downto 0);
    variable sh_obs, es_obs : integer;
    variable ref_sh, ref_es : integer;
    variable m_sh, m_es     : integer;
    variable eref, emin, et : integer;
    variable have  : boolean;
    variable seed  : unsigned(31 downto 0) := x"1234abcd";
    variable nfail : integer := 0;
    variable first_bad, last_bad, nbad, best : integer;

    procedure step(constant n : in integer) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure do_cap(constant l, s, e : in integer) is
    begin
      assert cap_ready = '1'
        report "tb: capture issued while gdn_exp_capture busy" severity failure;
      cap_layer <= l; cap_seg <= s; cap_exp <= to_signed(e, 8); cap_req <= '1';
      wait until rising_edge(clk);
      cap_req <= '0';
      step(5);
    end procedure;

    procedure do_read(constant l, s : in integer) is
    begin
      rd_layer <= l; rd_seg <= s; rd_req <= '1';
      wait until rising_edge(clk);
      rd_req <= '0';
      step(3);
    end procedure;

    -- One conv invocation.  do_skew decides whether a prefetching READ of
    -- entry (l2,s2) is issued at group RDREQ_AT of pass A; cap_mid decides
    -- whether a CAPTURE into (l2,s2) is issued there instead.  The two are
    -- separated on purpose: a capture is the other thing a sequencer does to
    -- gdn_exp_capture while a conv runs, and it must be shown NOT to be a
    -- trigger before the finding can be stated as "a read of a different
    -- entry".
    procedure run_case(constant nm      : in string;
                       constant l1, s1  : in integer;
                       constant do_skew : in boolean;
                       constant l2, s2  : in integer;
                       constant cap_mid : in boolean := false) is
      variable g, cyc : integer;
    begin
      report "==== " & nm & " ====";
      do_read(l1, s1);
      tv_prep := tvalid;
      et_prep := e_t;
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      while ready /= '1' loop wait until rising_edge(clk); end loop;

      for gi in 0 to NB-1 loop
        for t in 0 to K-1 loop
          for ln in 0 to LANES-1 loop
            x_in((t*LANES+ln+1)*16-1 downto (t*LANES+ln)*16)
              <= std_logic_vector(to_signed(xv((gi*LANES+ln)*K + t), 16));
            w_in((t*LANES+ln+1)*16-1 downto (t*LANES+ln)*16)
              <= std_logic_vector(to_signed(wv((gi*LANES+ln)*K + t), 16));
          end loop;
        end loop;
        s_valid <= '1';
        if do_skew and gi = RDREQ_AT then
          rd_layer <= l2; rd_seg <= s2; rd_req <= '1';
        else
          rd_req <= '0';
        end if;
        if cap_mid and gi = RDREQ_AT then
          cap_layer <= l2; cap_seg <= s2; cap_exp <= to_signed(4, 8);
          cap_req <= '1';
        else
          cap_req <= '0';
        end if;
        wait until rising_edge(clk);
      end loop;
      s_valid <= '0'; rd_req <= '0'; cap_req <= '0';

      g := 0; cyc := 0;
      while o_done /= '1' loop
        if o_valid = '1' then
          for ln in 0 to LANES-1 loop
            got(g*LANES+ln) := to_integer(signed(o_data((ln+1)*16-1 downto ln*16)));
          end loop;
          g := g + 1;
        end if;
        wait until rising_edge(clk);
        cyc := cyc + 1;
        assert cyc < 20000 report "tb: gdn_conv never asserted o_done"
          severity failure;
      end loop;
      wait for 1 ns;
      sh_obs  := sh_seg;
      es_obs  := to_integer(e_seg);
      tv_post := tvalid;
      assert g = NB report "tb: collected " & integer'image(g) & " groups, want "
        & integer'image(NB) severity failure;
      assert err_seg = '0' report "tb: err_seg set; pick a smaller cw_exp"
        severity failure;
    end procedure;

    -- Compare `got` against the reference and against every gsplit hypothesis.
    procedure judge(constant nm : in string; constant expect_clean : in boolean) is
    begin
      -- shifts and e_ref exactly as S_PREP derived them, from the snapshot
      emin := 0; have := false;
      for t in 0 to K-1 loop
        if tv_prep(t) = '1' then
          et := to_integer(signed(et_prep((t+1)*8-1 downto t*8)));
          if not have or et < emin then emin := et; have := true; end if;
        end if;
      end loop;
      eref := emin;
      for t in 0 to K-1 loop
        if tv_prep(t) = '1' then
          et := to_integer(signed(et_prep((t+1)*8-1 downto t*8))) - emin;
          if et > 63 then et := 63; elsif et < 0 then et := 0; end if;
          shf(t) := et;
        else
          shf(t) := 0;
        end if;
      end loop;
      report "     S_PREP saw tvalid=" & to_str(tv_prep) & "  e_t(3..0)="
           & integer'image(to_integer(signed(et_prep(31 downto 24)))) & ","
           & integer'image(to_integer(signed(et_prep(23 downto 16)))) & ","
           & integer'image(to_integer(signed(et_prep(15 downto 8))))  & ","
           & integer'image(to_integer(signed(et_prep(7 downto 0))))
           & "  -> e_ref=" & integer'image(eref)
           & "  shf(3..0)=" & integer'image(shf(3)) & "," & integer'image(shf(2))
           & "," & integer'image(shf(1)) & "," & integer'image(shf(0));
      report "     tvalid at end of pass A = " & to_str(tv_post);

      model(xv, wv, shf, tv_prep, tv_post, NB, eref, 0, refsm, ref_sh, ref_es);

      nbad := 0; first_bad := -1; last_bad := -1;
      for c in 0 to CH-1 loop
        if got(c) /= refsm(c) then
          nbad := nbad + 1;
          if first_bad < 0 then first_bad := c; end if;
          last_bad := c;
        end if;
      end loop;
      report "     sh_seg got " & integer'image(sh_obs) & " reference "
           & integer'image(ref_sh) & ";  e_seg got " & integer'image(es_obs)
           & " reference " & integer'image(ref_es);
      report "     channels differing from the reference: " & integer'image(nbad)
           & " of " & integer'image(CH)
           & "   first=" & integer'image(first_bad)
           & "  last=" & integer'image(last_bad);
      if nbad > 0 then
        for c in first_bad to minimum(first_bad+2, CH-1) loop
          report "       head ch " & integer'image(c) & ": got "
               & integer'image(got(c)) & "  expected " & integer'image(refsm(c));
        end loop;
        -- also show the first channels of the group the read was issued at,
        -- which is where the mask actually switches
        for c in RDREQ_AT*LANES to minimum(RDREQ_AT*LANES+2, CH-1) loop
          report "       tail ch " & integer'image(c) & ": got "
               & integer'image(got(c)) & "  expected " & integer'image(refsm(c));
        end loop;
      end if;

      -- Which mask-switch group, if any, explains the DUT bit for bit.
      -- Only meaningful when the two masks actually differ: if m1 = m2 then
      -- EVERY gsplit is the same model and gsplit = 0 would match trivially,
      -- which reads as a corruption report on a clean run.  Guard it.
      if tv_prep = tv_post then
        report "     masks identical (" & to_str(tv_prep)
             & "); gsplit search not applicable";
      else
        best := -1;
        for gs in 0 to NB loop
          model(xv, wv, shf, tv_prep, tv_post, gs, eref, 0, mdl, m_sh, m_es);
          if mdl = got and m_sh = sh_obs and m_es = es_obs then
            best := gs; exit;
          end if;
        end loop;
        if best < 0 then
          report "     NO gsplit hypothesis reproduces the DUT" severity note;
        elsif best = NB then
          report "     DUT matches the CLEAN model (mask never switched)";
        else
          report "     DUT matches the CORRUPT model exactly, with the mask "
               & "switching at group " & integer'image(best) & " (channel "
               & integer'image(best*LANES) & ")";
          assert best = RDREQ_AT
            report "     NOTE: switch group " & integer'image(best)
                 & " is not the group the read was issued at ("
                 & integer'image(RDREQ_AT) & ")" severity note;
        end if;
      end if;

      if expect_clean then
        if nbad = 0 and sh_obs = ref_sh and es_obs = ref_es then
          report "     CONTROL OK: bit-exact with a quiescent producer";
        else
          report "     CONTROL FAILED -- the testbench or the reference is "
               & "wrong, not the DUT" severity error;
          nfail := nfail + 1;
        end if;
      else
        if nbad = 0 then
          report "     SKEW produced NO difference" severity note;
        else
          report "     SKEW DEMONSTRATED: " & integer'image(nbad)
               & " channels wrong" severity note;
        end if;
      end if;
    end procedure;

  begin
    -- ---------------------------------------------------------------- data
    for i in 0 to CH*K-1 loop
      seed := nextr(seed); xv(i) := to_integer(seed(13 downto 0)) - 8192;
      seed := nextr(seed); wv(i) := to_integer(seed(13 downto 0)) - 8192;
    end loop;

    cw_exp <= to_signed(0, 8);
    step(4); rst <= '0'; step(2);

    -- --------------------------------------------------- prime the producer
    -- Fill entry B's four tap words, then clear the counters, then give A four
    -- captures and B one.  Result: A has tvalid=1111, B has tvalid=1000 with
    -- all four of its tap bytes DEFINED (no 'U' can reach the conv).
    seq_rst <= '1'; step(1); seq_rst <= '0'; step(2);
    do_cap(B_LAY, B_SEG, 9);
    do_cap(B_LAY, B_SEG, 9);
    do_cap(B_LAY, B_SEG, 8);
    do_cap(B_LAY, B_SEG, 7);
    seq_rst <= '1'; step(1); seq_rst <= '0'; step(2);
    do_cap(A_LAY, A_SEG, 3);   -- becomes tap 0, the oldest
    do_cap(A_LAY, A_SEG, 5);   -- tap 1
    do_cap(A_LAY, A_SEG, 2);   -- tap 2
    do_cap(A_LAY, A_SEG, 6);   -- tap 3, the current token
    do_cap(B_LAY, B_SEG, 1);   -- B: one capture since seq_rst -> tvalid = 1000

    -- =====================================================================
    -- CASE 1: mid-pass NARROWING.  Convolve segment A (all four taps valid),
    -- and prefetch segment B (one tap valid) at group RDREQ_AT.
    -- =====================================================================
    run_case("CASE 1 CONTROL  segment A, no mid-pass read", A_LAY, A_SEG, false, 0, 0);
    judge("CASE 1 CONTROL", true);
    run_case("CASE 1 SKEW     segment A, prefetch B at group "
             & integer'image(RDREQ_AT), A_LAY, A_SEG, true, B_LAY, B_SEG);
    judge("CASE 1 SKEW", false);

    -- =====================================================================
    -- CASE 2: mid-pass WIDENING.  Convolve segment B (token 0 of a sequence,
    -- one valid tap, so shf = 0,0,0,0), and prefetch segment A (four valid
    -- taps) at group RDREQ_AT.  The three taps that turn valid are summed
    -- UNSHIFTED because their shf was latched at 0.  This is the wrong-grid
    -- half of the defect and it is the more damaging one.
    -- =====================================================================
    run_case("CASE 2 CONTROL  segment B, no mid-pass read", B_LAY, B_SEG, false, 0, 0);
    judge("CASE 2 CONTROL", true);
    run_case("CASE 2 SKEW     segment B, prefetch A at group "
             & integer'image(RDREQ_AT), B_LAY, B_SEG, true, A_LAY, A_SEG);
    judge("CASE 2 SKEW", false);

    -- =====================================================================
    -- CASE 3: a mid-pass read of the SAME entry.  This narrows the trigger.
    -- gdn_exp_capture reassigns e_t and tvalid on EVERY read, so this run
    -- rewrites the port under the conv exactly as cases 1 and 2 do -- but
    -- with the same value, so nothing changes.  It must come out clean.  If
    -- it did not, the finding would be "any read corrupts", which is a
    -- different and larger claim than the one being made.
    -- =====================================================================
    run_case("CASE 3 SAME-ENTRY  segment A, re-read A at group "
             & integer'image(RDREQ_AT), A_LAY, A_SEG, true, A_LAY, A_SEG);
    judge("CASE 3 SAME-ENTRY", true);

    -- =====================================================================
    -- CASE 4: a mid-pass CAPTURE into a different entry.  gdn_exp_capture
    -- assigns tvalid_r only in S_RD, so a capture should leave the seam
    -- untouched even though it drives the unit's FSM and drops cap_ready.
    -- Measured rather than asserted from reading the source: this is the
    -- alternative trigger hypothesis and it has to be killed explicitly.
    -- =====================================================================
    run_case("CASE 4 MID-CAPTURE  segment A, capture into B at group "
             & integer'image(RDREQ_AT), A_LAY, A_SEG, false, B_LAY, B_SEG, true);
    judge("CASE 4 MID-CAPTURE", true);

    if nfail = 0 then
      report "tb_gdn_conv_tvalid_skew: controls clean, see the SKEW blocks above";
    else
      report "tb_gdn_conv_tvalid_skew: " & integer'image(nfail)
           & " CONTROL case(s) failed -- results above are not interpretable"
        severity error;
    end if;

    running <= false;
    wait for 1 ns;
    finish;
  end process;

end architecture;
