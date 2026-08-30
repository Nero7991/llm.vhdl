-- ooc_normadapt_equiv.vhd -- TRACK NORMADAPT, 2026-08-29.
--
-- THE ORACLE FOR THE D-VEC NORM ADAPTER REWRITE.
--
-- `ooc_normadapt_ref` is `rtl/llama_top.vhd`'s `gvr` block extracted from the
-- PINNED PRE-CHANGE tree; `ooc_normadapt` is the same block extracted from the
-- changed tree.  Both are produced by `sim/ooc_normadapt_extract.py`, which
-- copies the block verbatim, so the only difference between the two entities
-- is the edit under test.
--
-- WHAT IS COMPARED.  Every output of the adapter, on EVERY rising edge, by
-- name: the seq_vec_issue handshake (`v_ready`/`v_done`/`v_taken`/`v_err`/
-- `v_y_exp`), the region-file read port (`ur_en`/`ur_reg`/`ur_addr`), the
-- region-file write port (`uw_en`/`uw_reg`/`uw_addr`/`uw_data`) and the four
-- observation taps.  A cycle-shifted `done`, a shifted write, a permuted
-- write, a wrong address and a wrong value all fail this, which is the point:
-- `done` is what `llama_top` and the pinned `seq` landmarks wait on, so an
-- equivalence that only compared the emitted VECTOR would pass a rewrite that
-- moved the schedule.
--
-- NON-TRIVIALITY IS A HARD FAILURE, NOT A NOTE.  `rmsnorm_rs` has a silent
-- all-zeros rail: outside its 19-octave reciprocal window it emits an all-zero
-- vector, and two all-zero vectors compare equal.  TRACK WRITEDEC recorded
-- three of six trials degenerate on this unit before it retuned `x_exp`.  So
-- every trial here asserts that the emitted vector has a non-zero element AND
-- at least two DISTINCT element values, and a trial that does not is a
-- FAILURE of the bench rather than evidence about the design.
--
-- The region file is modelled with the SAME latency the real one has: the
-- adapter registers `ur_addr` (one edge) and the region file registers
-- `el_rdata` under `el_ren` (one edge).  Two edges, which is READ_LATENCY in
-- `rtl/llama_top.vhd`'s region-file header and what the adapter's `k-2`
-- indexing depends on.
--
-- NO HARDWARE.  Simulation only.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;

entity ooc_normadapt_equiv is
  generic(
    NN_G     : positive := 64;    -- SHAPE.hidden the adapter is elaborated at
    LANES_G  : positive := 4;     -- NORM_LANES
    Q_G      : integer  := 12;    -- NORM_Q
    WEXP_G   : integer  := 12;    -- NORM_W_EXP
    VN_W_G   : positive := 14;
    RESETMID : boolean  := false; -- take a reset in the middle of trial 2
    VERBOSE  : boolean  := false
  );
end entity;

architecture tb of ooc_normadapt_equiv is

  -- A shape whose ONLY significant field is `hidden`: the adapter reads
  -- `SHAPE.hidden` and nothing else off this record.  Built by hand rather
  -- than by `mk_shape_scaled` so `hidden` can be swept independently, which
  -- is what covers the generate's index corners at more than one N.
  function shp(h : positive) return shape_t is
  begin
    return (blocks        => 4,  attn_interval => 2,
            hidden        => h,  ffn           => 2*h,
            key_heads     => 2,  val_heads     => 4,
            head_dim      => 32, conv_kernel   => 4,
            attn_q_heads  => 2,  attn_kv_heads => 1,
            attn_head_dim => 32, vocab_shard   => 256);
  end function;

  constant NN     : positive := NN_G;
  constant MANT_W : positive := 16;
  constant EXP_W  : positive := 16;
  constant REGMAX : positive := NN;
  constant NREG   : positive := 4;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal go  : std_logic := '0';
  signal run : boolean := true;

  signal v_start, v_ack : std_logic := '0';
  signal v_n     : unsigned(VN_W_G-1 downto 0) := (others => '0');
  signal v_exp_a : signed(EXP_W-1 downto 0) := (others => '0');
  signal v_reg_a, v_reg_d : unsigned(7 downto 0) := (others => '0');

  signal el_a, el_b : signed(MANT_W-1 downto 0) := (others => '0');

  -- DUT outputs, A = reference (pre-change), B = changed
  signal ard, brd, adn, bdn, atk, btk, aer, ber : std_logic;
  signal aye, bye : std_logic_vector(EXP_W-1 downto 0);
  signal aren, bren, awen, bwen : std_logic;
  signal arreg, brreg, awreg, bwreg : std_logic_vector(15 downto 0);
  signal aradr, bradr, awadr, bwadr : std_logic_vector(31 downto 0);
  signal awd, bwd : std_logic_vector(MANT_W-1 downto 0);
  signal apub, bpub : std_logic;
  signal aexp, bexp : signed(EXP_W-1 downto 0);
  signal assq, bssq : unsigned(63 downto 0);
  signal an, bn : unsigned(15 downto 0);

  type mem_t is array (0 to NREG*REGMAX-1) of signed(MANT_W-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));

  -- what the DUTs wrote back, captured off the write port
  type vec_t is array (0 to NN-1) of signed(MANT_W-1 downto 0);
  signal wa_v, wb_v : vec_t := (others => (others => '0'));
  signal wa_n, wb_n : natural := 0;
  signal wclr : std_logic := '0';

  signal nfail : natural := 0;
  signal ncmp  : natural := 0;

  procedure chk(signal f : inout natural;
                constant nm : string; a, b : std_logic) is
  begin
    if a /= b then
      report "MISMATCH " & nm & " ref=" & std_logic'image(a)
           & " new=" & std_logic'image(b) severity error;
      f <= f + 1;
    end if;
  end procedure;

begin

  clk <= not clk after 5 ns when run else '0';

  -- ------------------------------------------------------------------
  -- The two adapters.  Identical generics; the entities differ only by the
  -- edit under test.
  -- ------------------------------------------------------------------
  u_ref : entity work.ooc_normadapt_ref
    generic map(SHAPE => shp(NN), MANT_W => MANT_W, EXP_W => EXP_W,
                VN_W => VN_W_G, NORM_LANES => LANES_G, NORM_Q => Q_G,
                NORM_W_EXP => WEXP_G, NORM_W_IMAGE => "", SHOUT => false,
                NORM_REAL => true)
    port map(clk => clk, rst => rst, go => go,
             i_v_start => v_start, i_v_ack => v_ack, i_v_n => v_n,
             i_v_exp_a => v_exp_a, i_v_reg_a => v_reg_a, i_v_reg_d => v_reg_d,
             i_el_rdata => el_a,
             o_v_ready => ard, o_v_done => adn, o_v_taken => atk,
             o_v_err => aer, o_v_y_exp => aye,
             o_ur_en => aren, o_ur_reg => arreg, o_ur_addr => aradr,
             o_uw_en => awen, o_uw_reg => awreg, o_uw_addr => awadr,
             o_uw_data => awd,
             obs_norm_pub => apub, obs_norm_exp => aexp,
             obs_norm_ssq => assq, obs_norm_n => an);

  u_new : entity work.ooc_normadapt
    generic map(SHAPE => shp(NN), MANT_W => MANT_W, EXP_W => EXP_W,
                VN_W => VN_W_G, NORM_LANES => LANES_G, NORM_Q => Q_G,
                NORM_W_EXP => WEXP_G, NORM_W_IMAGE => "", SHOUT => false,
                NORM_REAL => true)
    port map(clk => clk, rst => rst, go => go,
             i_v_start => v_start, i_v_ack => v_ack, i_v_n => v_n,
             i_v_exp_a => v_exp_a, i_v_reg_a => v_reg_a, i_v_reg_d => v_reg_d,
             i_el_rdata => el_b,
             o_v_ready => brd, o_v_done => bdn, o_v_taken => btk,
             o_v_err => ber, o_v_y_exp => bye,
             o_ur_en => bren, o_ur_reg => brreg, o_ur_addr => bradr,
             o_uw_en => bwen, o_uw_reg => bwreg, o_uw_addr => bwadr,
             o_uw_data => bwd,
             obs_norm_pub => bpub, obs_norm_exp => bexp,
             obs_norm_ssq => bssq, obs_norm_n => bn);

  -- ------------------------------------------------------------------
  -- Two INDEPENDENT region-file read models, one per DUT.  Independent so a
  -- divergence in the read ADDRESS shows up as divergent data as well as a
  -- divergent address, rather than being masked by a shared model.
  -- ------------------------------------------------------------------
  rfa : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      if aren = '1' then
        a := (to_integer(unsigned(arreg)) mod NREG) * REGMAX
             + (to_integer(unsigned(aradr)) mod REGMAX);
        el_a <= mem(a);
      end if;
    end if;
  end process;

  rfb : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      if bren = '1' then
        a := (to_integer(unsigned(brreg)) mod NREG) * REGMAX
             + (to_integer(unsigned(bradr)) mod REGMAX);
        el_b <= mem(a);
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- The write-back capture.  Indexed by the DUT's OWN address, so a permuted
  -- write is captured as permuted rather than being straightened out.
  -- ------------------------------------------------------------------
  cap : process(clk) is
  begin
    if rising_edge(clk) then
      if wclr = '1' then
        wa_n <= 0; wb_n <= 0;
      else
        if awen = '1' then
          wa_v(to_integer(unsigned(awadr)) mod NN) <= signed(awd);
          wa_n <= wa_n + 1;
        end if;
        if bwen = '1' then
          wb_v(to_integer(unsigned(bwadr)) mod NN) <= signed(bwd);
          wb_n <= wb_n + 1;
        end if;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- THE COMPARISON.  Every output, every rising edge, by name.
  -- ------------------------------------------------------------------
  cmpp : process(clk) is
  begin
    if rising_edge(clk) then
      ncmp <= ncmp + 1;
      chk(nfail, "v_ready", ard, brd);
      chk(nfail, "v_done",  adn, bdn);
      chk(nfail, "v_taken", atk, btk);
      chk(nfail, "v_err",   aer, ber);
      chk(nfail, "ur_en",   aren, bren);
      chk(nfail, "uw_en",   awen, bwen);
      chk(nfail, "obs_pub", apub, bpub);
      if aye /= bye then
        report "MISMATCH v_y_exp" severity error; nfail <= nfail + 1;
      end if;
      if aren = '1' and (arreg /= brreg or aradr /= bradr) then
        report "MISMATCH ur addr/reg" severity error; nfail <= nfail + 1;
      end if;
      if awen = '1' and (awreg /= bwreg or awadr /= bwadr or awd /= bwd) then
        report "MISMATCH uw addr/reg/data at addr "
             & integer'image(to_integer(unsigned(awadr)))
             & " ref=" & integer'image(to_integer(signed(awd)))
             & " new=" & integer'image(to_integer(signed(bwd)))
          severity error;
        nfail <= nfail + 1;
      end if;
      if apub = '1' and (aexp /= bexp or assq /= bssq or an /= bn) then
        report "MISMATCH obs_norm payload" severity error; nfail <= nfail + 1;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- The stimulus.
  -- ------------------------------------------------------------------
  drv : process is
    variable seed : integer := 12345;
    variable nz, ndist : natural;

    -- Deterministic, class-dependent element pattern.
    impure function elem(cls, i : natural) return integer is
      variable v : integer;
    begin
      case cls is
        when 0 => v := ((i * 37) mod 251) - 125;              -- dense ramp
        when 1 => v := 2047 - (i mod 3) * 11;   -- top of the rms window
        when 2 => if i mod 7 = 0 then v := -8000 + (i mod 5);   -- large negative
                  else v := (i mod 19) - 9; end if;
        when 3 => if i = 0 then v := 4000;
                  elsif i = NN-1 then v := -4000;
                  else v := 1; end if;                        -- index corners
        when 4 => v := ((i*i*7 + i*31 + 13) mod 4001) - 2000;  -- scrambled
        when others => v := (i mod 2) * 600 - 300;            -- alternating
      end case;
      return v;
    end function;

    procedure load(cls : natural; reg : natural) is
    begin
      for i in 0 to NN-1 loop
        mem(reg*REGMAX + i) <= to_signed(elem(cls, i), MANT_W);
      end loop;
      wait for 1 ns;
    end procedure;

    procedure one_op(cls : natural; xe : integer;
                     rega, regd : natural; mid_reset : boolean) is
      variable guard : natural := 0;
    begin
      load(cls, rega);
      wclr <= '1';
      wait until rising_edge(clk);
      wclr <= '0';
      wait until rising_edge(clk);
      v_n     <= to_unsigned(NN, VN_W_G);
      v_exp_a <= to_signed(xe, EXP_W);
      v_reg_a <= to_unsigned(rega, 8);
      v_reg_d <= to_unsigned(regd, 8);
      v_start <= '1';
      wait until rising_edge(clk) and atk = '1';
      v_start <= '0';

      if mid_reset then
        for i in 0 to 3*NN/LANES_G + 20 loop
          wait until rising_edge(clk);
        end loop;
        rst <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);
        return;                       -- the operation is abandoned by design
      end if;

      guard := 0;
      while adn = '0' loop
        wait until rising_edge(clk);
        guard := guard + 1;
        assert guard < 200000
          report "TIMEOUT waiting for v_done" severity failure;
      end loop;
      v_ack <= '1';
      wait until rising_edge(clk);
      v_ack <= '0';
      wait until rising_edge(clk);

      -- NON-TRIVIALITY.  A hard failure: an all-zero or constant emitted
      -- vector compares equal against anything and proves nothing.
      nz := 0; ndist := 0;
      for i in 0 to NN-1 loop
        if wa_v(i) /= 0 then nz := nz + 1; end if;
        if wa_v(i) /= wa_v(0) then ndist := ndist + 1; end if;
      end loop;
      assert wa_n = NN and wb_n = NN
        report "WRITE COUNT wrong: ref=" & integer'image(wa_n)
             & " new=" & integer'image(wb_n)
             & " expected " & integer'image(NN)
        severity failure;
      assert nz > 0 and ndist > 0
        report "DEGENERATE TRIAL cls=" & integer'image(cls)
             & " xe=" & integer'image(xe)
             & " nonzero=" & integer'image(nz)
             & " distinct-from-elem0=" & integer'image(ndist)
             & " -- rmsnorm_rs's all-zeros rail.  Retune x_exp; this trial "
             & "proves nothing."
        severity failure;
      if VERBOSE then
        report "trial cls=" & integer'image(cls) & " xe=" & integer'image(xe)
             & " nonzero=" & integer'image(nz)
             & " distinct=" & integer'image(ndist)
             & " y_exp=" & integer'image(to_integer(signed(aye)));
      end if;
    end procedure;

  begin
    rst <= '1';
    for i in 0 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    go <= '1'; wait until rising_edge(clk); go <= '0';
    wait until rising_edge(clk);

    -- Six input classes, each with an x_exp that keeps the unit off its
    -- all-zeros rail.  The exponents are TUNED, not assumed: a class that
    -- rails fails the assertion above rather than passing quietly.
    one_op(0, 0, 0, 1, false);
    one_op(1, 0, 0, 2, false);
    one_op(2, 0, 1, 2, false);
    one_op(3, 0, 2, 3, false);
    one_op(4, 0, 0, 3, false);
    one_op(5, 0, 3, 0, false);
    -- back to back on the same regions, so `nidx`/`rdy` sequencing is covered
    one_op(0, 4, 0, 1, false);
    one_op(4, 2, 1, 0, false);

    if RESETMID then
      one_op(0, 0, 0, 1, true);
      -- and the unit must recover and produce a correct result afterwards
      one_op(4, 0, 0, 1, false);
    end if;

    wait until rising_edge(clk);
    if nfail = 0 then
      report "NORMADAPT_EQUIV PASS NN=" & integer'image(NN)
           & " LANES=" & integer'image(LANES_G)
           & " Q=" & integer'image(Q_G)
           & " cycles=" & integer'image(ncmp);
    else
      report "NORMADAPT_EQUIV FAIL NN=" & integer'image(NN)
           & " LANES=" & integer'image(LANES_G)
           & " mismatches=" & integer'image(nfail)
        severity failure;
    end if;
    run <= false;
    wait;
  end process;

end architecture;
