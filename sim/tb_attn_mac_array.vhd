-- sim/tb_attn_mac_array.vhd
-- Bit-exact check of rtl/attn_mac_array.vhd against ref/attn_mac_array_vec.c.
--
-- WHAT IS CHECKED, and it is two different things.
--
--   VALUES.  Every score partial and every final accumulator, bit for bit,
--   against a C reference that is itself checked against six oracles sharing
--   none of its integer machinery (double precision, __int128 in reverse
--   order, the width bound attn_score_q12's s32 argument rests on, a full
--   independent replay by FLOOR DIVISION rather than by an arithmetic shift,
--   the f = 2^Q identity, and the DSP48E2 port fit).  No tolerance anywhere.
--
--   THE PHASE SEPARATION, which no value check can see.  The array's rescale
--   mode READS the accumulator file in S0 and WRITES it in S2, so it is the
--   one mode whose own input depends on the file.  Issue a rescale of block b
--   while block b's previous write is still in the pipeline and it multiplies
--   the stale value and then overwrites the pending write -- a plausible
--   number, on the right grid, with nothing to say it happened.  GAP is the
--   axis: at GAP = 0 the phases abut and the pipeline hazard is REACHABLE at
--   small ACC_N; at GAP >= 2 it is not.  The unit's own index-aware assertion
--   is what fires, and the run is required to be BIT-IDENTICAL across the
--   whole GAP sweep, which is the property a hazard would break.
--
-- WHY GAP AND NOT A READY.  There is deliberately no ready on any of the three
-- operand modes: the array runs on a fixed position slot driven by the KV beat
-- rate and cannot pause mid-slot without desynchronising from the K stream.
-- That makes throughput margin a CORRECTNESS property (the 2026-08-27 lesson
-- from gdn_recur_pipe and gdn_head_emit), and the only instrument for a
-- correctness property with no handshake is a schedule sweep plus an
-- assertion.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_attn_mac_array is
  generic(
    -- Defaults MUST match ref/attn_mac_array_vec.c's defaults, because
    -- sim/regress.sh builds the generator with its own defaults when the
    -- vector file is absent.
    QH_TILE  : positive := 2;
    DIM_TILE : positive := 8;
    ACC_N    : positive := 4;
    NPOS     : positive := 6;
    NCASE    : positive := 24;
    -- Idle cycles inserted between the score, rescale and PV phases of one
    -- position.  0 abuts them; see the header.
    GAP      : natural  := 2;
    -- Edges from the edge that samples sc_valid to the edge the collector sees
    -- the partial.  3 before the 2026-09-26 S2 split, 4 after it.
    P_LAT    : positive := 4;
    VECS     : string   := "attn_mac_array_vec.txt";
    HEARTBEAT_US : integer := 0;
    -- attn_mac_array's lanes-per-control-copy.  4 at QH_TILE=2/DIM_TILE=8
    -- gives four groups, so a lane mapped to the wrong group's copy shows.
    CTL_GRP  : positive := 4
  );
end entity;

architecture sim of tb_attn_mac_array is

  constant Q_W   : positive := 16;
  constant K_W   : positive := 8;
  constant E_W   : positive := 13;
  constant ACC_W : positive := 36;
  constant P_W   : positive := 32;
  constant QS    : natural  := 12;
  constant N     : integer  := ACC_N*DIM_TILE;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal acc_clr : std_logic := '0';

  signal sc_valid : std_logic := '0';
  signal sc_blk   : unsigned(clog2(ACC_N)-1 downto 0) := (others => '0');
  signal sc_k     : std_logic_vector(DIM_TILE*K_W-1 downto 0) := (others => '0');
  signal sc_q     : std_logic_vector(QH_TILE*DIM_TILE*Q_W-1 downto 0) := (others => '0');

  signal p_valid : std_logic;
  signal p_blk   : unsigned(clog2(ACC_N)-1 downto 0);
  signal p_data  : std_logic_vector(QH_TILE*P_W-1 downto 0);

  signal pv_valid : std_logic := '0';
  signal pv_blk   : unsigned(clog2(ACC_N)-1 downto 0) := (others => '0');
  signal pv_v     : std_logic_vector(DIM_TILE*K_W-1 downto 0) := (others => '0');
  signal pv_e     : std_logic_vector(QH_TILE*E_W-1 downto 0) := (others => '0');

  signal rs_valid : std_logic := '0';
  signal rs_blk   : unsigned(clog2(ACC_N)-1 downto 0) := (others => '0');
  signal rs_f     : std_logic_vector(QH_TILE*E_W-1 downto 0) := (others => '0');

  signal rd_valid : std_logic := '0';
  signal rd_head  : unsigned(clog2(QH_TILE)-1 downto 0) := (others => '0');
  signal rd_idx   : unsigned(clog2(ACC_N*DIM_TILE)-1 downto 0) := (others => '0');
  signal o_valid  : std_logic;
  signal o_data   : signed(ACC_W-1 downto 0);

  signal ovr, err : std_logic;

  type int_arr is array (natural range <>) of integer;
  -- The partial stream is collected by an always-on process, because p_valid
  -- has no ready and a stimulus process that looked for it at a chosen instant
  -- would be reading a stream it is also driving.
  signal par_got : int_arr(0 to QH_TILE*ACC_N-1) := (others => 0);
  signal par_n   : integer := 0;
  signal sc_hist : std_logic_vector(7 downto 0) := (others => '0');
  signal lat_bad : integer := 0;
  signal nerr    : integer := 0;

  -- ACC_W = 36 exceeds a VHDL integer, so accumulator goldens are carried as
  -- reals and the DUT's output is converted to one.  Same workaround and same
  -- reason as tb_attn_score_q12's s32 handling and tb_gdn_head_emit's s40.
  function to_real_s(v : signed) return real is
    variable hi : integer := to_integer(v(v'high downto 16));
    variable lo : integer := to_integer(unsigned(v(15 downto 0)));
  begin
    return real(hi) * 65536.0 + real(lo);
  end function;

begin

  clk <= not clk after 5 ns when running else '0';

  dut : entity work.attn_mac_array
    generic map ( QH_TILE => QH_TILE, DIM_TILE => DIM_TILE, ACC_N => ACC_N,
                  Q_W => Q_W, K_W => K_W, E_W => E_W, ACC_W => ACC_W,
                  P_W => P_W, Q => QS, STRICT_PRODUCER => true,
                  CTL_GRP => CTL_GRP )
    port map ( clk => clk, rst => rst, acc_clr => acc_clr,
               sc_valid => sc_valid, sc_blk => sc_blk, sc_k => sc_k,
               sc_q => sc_q,
               p_valid => p_valid, p_blk => p_blk, p_data => p_data,
               p_ready => '1',
               pv_valid => pv_valid, pv_blk => pv_blk, pv_v => pv_v,
               pv_e => pv_e,
               rs_valid => rs_valid, rs_blk => rs_blk, rs_f => rs_f,
               rd_valid => rd_valid, rd_head => rd_head, rd_idx => rd_idx,
               o_valid => o_valid, o_data => o_data,
               ovr => ovr, err => err );

  -- The partial collector.  Indexed by (head, p_blk) taken from the STREAM's
  -- own qualifier, not from a counter in the stimulus process: if p_blk ever
  -- came out of step with p_data this indexing is what notices, and a counter
  -- would silently re-label the data instead.
  collect : process(clk)
    variable b : integer;
  begin
    if rising_edge(clk) then
      sc_hist <= sc_hist(6 downto 0) & sc_valid;
      if rst = '1' then
        par_n <= 0;
      elsif p_valid = '1' then
        -- The latency contract, measured on every partial: the score that
        -- produced it was sampled exactly P_LAT edges earlier.  sc_hist(k)
        -- holds sc_valid as sampled k+1 edges before this one.
        if sc_hist(P_LAT-1) /= '1' then
          lat_bad <= lat_bad + 1;
          report "tb_attn_mac_array: a partial arrived without a score "
               & integer'image(P_LAT) & " edges earlier" severity error;
        end if;
        b := to_integer(p_blk);
        for h in 0 to QH_TILE-1 loop
          par_got(h*ACC_N + b) <= to_integer(signed(p_data((h+1)*P_W-1 downto h*P_W)));
        end loop;
        par_n <= par_n + 1;
      end if;
    end if;
  end process;

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: partials " & integer'image(par_n) severity note;
    end loop;
    wait;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nq, nd, na, np : integer;
    variable qp : int_arr(0 to QH_TILE*N-1);
    variable kb : int_arr(0 to N-1);
    variable vb : int_arr(0 to N-1);
    variable ev : int_arr(0 to QH_TILE-1);
    variable fv : int_arr(0 to QH_TILE-1);
    variable pg : int_arr(0 to QH_TILE*ACC_N-1);
    variable ag : real;
    variable dors : integer;
    variable got : real;
    -- FWD phase (see below).  Golden accumulators as integers: every value
    -- in that phase is far inside the 32-bit range.
    variable fx    : int_arr(0 to QH_TILE*N-1);
    variable fe, fv1, fv2, fv3, fv4, fv5 : integer;
    variable fchk  : integer := 0;
    variable ferr  : integer := 0;
    constant FF    : integer := 3000;     -- rescale factor, u13, below 2^Q
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln);
    read(ln, nc); read(ln, nq); read(ln, nd); read(ln, na); read(ln, np);
    assert nc = NCASE and nq = QH_TILE and nd = DIM_TILE
           and na = ACC_N and np = NPOS
      report "tb_attn_mac_array: vector file shape mismatch -- file says "
           & integer'image(nc) & " " & integer'image(nq) & " "
           & integer'image(nd) & " " & integer'image(na) & " "
           & integer'image(np)
      severity failure;

    rst <= '1';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      -- "<case index> <shape>".  Numeric, with no words in it: textio's
      -- string read takes EXACTLY the declared length and a "case 0 shape 3"
      -- line silently misaligns every field after it.
      readline(fh, ln);
      read(ln, iv); read(ln, iv);

      for h in 0 to QH_TILE-1 loop
        readline(fh, ln);
        for i in 0 to N-1 loop read(ln, iv); qp(h*N + i) := iv; end loop;
      end loop;

      acc_clr <= '1';
      wait until rising_edge(clk);
      acc_clr <= '0';
      wait until rising_edge(clk);

      for p in 0 to NPOS-1 loop
        readline(fh, ln);
        read(ln, iv); read(ln, dors);
        readline(fh, ln);
        for i in 0 to N-1 loop read(ln, iv); kb(i) := iv; end loop;
        readline(fh, ln);
        for i in 0 to QH_TILE*ACC_N-1 loop read(ln, iv); pg(i) := iv; end loop;
        readline(fh, ln);
        for h in 0 to QH_TILE-1 loop read(ln, iv); fv(h) := iv; end loop;
        readline(fh, ln);
        for h in 0 to QH_TILE-1 loop read(ln, iv); ev(h) := iv; end loop;
        readline(fh, ln);
        for i in 0 to N-1 loop read(ln, iv); vb(i) := iv; end loop;

        -- ---- score phase: one block per cycle, back to back -------------
        for b in 0 to ACC_N-1 loop
          for h in 0 to QH_TILE-1 loop
            for t in 0 to DIM_TILE-1 loop
              sc_q((h*DIM_TILE + t + 1)*Q_W-1 downto (h*DIM_TILE + t)*Q_W)
                <= std_logic_vector(to_signed(qp(h*N + b*DIM_TILE + t), Q_W));
            end loop;
          end loop;
          for t in 0 to DIM_TILE-1 loop
            sc_k((t+1)*K_W-1 downto t*K_W)
              <= std_logic_vector(to_signed(kb(b*DIM_TILE + t), K_W));
          end loop;
          sc_blk   <= to_unsigned(b, clog2(ACC_N));
          sc_valid <= '1';
          wait until rising_edge(clk);
        end loop;
        sc_valid <= '0';
        -- Drain the three-stage pipeline, then check.  Also poison the score
        -- operand ports, so a unit that read them live instead of from its own
        -- registered copy produces garbage rather than the right answer.
        sc_q <= (others => '1');
        sc_k <= (others => '1');
        -- drain P_LAT stages plus the collector's edge
        for i in 1 to P_LAT + 1 loop wait until rising_edge(clk); end loop;

        for h in 0 to QH_TILE-1 loop
          for b in 0 to ACC_N-1 loop
            if par_got(h*ACC_N + b) /= pg(h*ACC_N + b) then
              nerr <= nerr + 1;
              report "tb_attn_mac_array: case " & integer'image(c)
                   & " pos " & integer'image(p)
                   & " head " & integer'image(h) & " block " & integer'image(b)
                   & " partial got " & integer'image(par_got(h*ACC_N + b))
                   & " want " & integer'image(pg(h*ACC_N + b))
                severity error;
            end if;
          end loop;
        end loop;

        for i in 1 to GAP loop wait until rising_edge(clk); end loop;

        -- ---- rescale phase, when the position had a maximum rise --------
        if dors /= 0 then
          for h in 0 to QH_TILE-1 loop
            rs_f((h+1)*E_W-1 downto h*E_W)
              <= std_logic_vector(to_unsigned(fv(h), E_W));
          end loop;
          for b in 0 to ACC_N-1 loop
            rs_blk   <= to_unsigned(b, clog2(ACC_N));
            rs_valid <= '1';
            wait until rising_edge(clk);
          end loop;
          rs_valid <= '0';
          for i in 1 to GAP loop wait until rising_edge(clk); end loop;
        end if;

        -- ---- PV phase ---------------------------------------------------
        for h in 0 to QH_TILE-1 loop
          pv_e((h+1)*E_W-1 downto h*E_W)
            <= std_logic_vector(to_unsigned(ev(h), E_W));
        end loop;
        for b in 0 to ACC_N-1 loop
          for t in 0 to DIM_TILE-1 loop
            pv_v((t+1)*K_W-1 downto t*K_W)
              <= std_logic_vector(to_signed(vb(b*DIM_TILE + t), K_W));
          end loop;
          pv_blk   <= to_unsigned(b, clog2(ACC_N));
          pv_valid <= '1';
          wait until rising_edge(clk);
        end loop;
        pv_valid <= '0';
        for i in 1 to GAP + 3 loop wait until rising_edge(clk); end loop;
      end loop;

      -- ---- the accumulator file, read back one element per cycle --------
      for h in 0 to QH_TILE-1 loop
        readline(fh, ln);
        for i in 0 to N-1 loop
          read(ln, ag);
          rd_head  <= to_unsigned(h, clog2(QH_TILE));
          rd_idx   <= to_unsigned(i, clog2(ACC_N*DIM_TILE));
          rd_valid <= '1';
          wait until rising_edge(clk);
          rd_valid <= '0';
          -- o_valid/o_data are registered AT the edge that sampled rd_valid,
          -- so they stand 1 ns past THAT edge and are gone one edge later.
          -- Checking after a second edge reads the idle cycle, which was the
          -- first version of this loop and reported o_valid = '0' on a
          -- perfectly good unit.
          wait for 1 ns;
          assert o_valid = '1'
            report "tb_attn_mac_array: readback produced no o_valid"
            severity failure;
          got := to_real_s(o_data);
          if got /= ag then
            nerr <= nerr + 1;
            report "tb_attn_mac_array: case " & integer'image(c)
                 & " head " & integer'image(h) & " elem " & integer'image(i)
                 & " acc got " & real'image(got) & " want " & real'image(ag)
              severity error;
          end if;
          wait until rising_edge(clk);
        end loop;
      end loop;
    end loop;

    file_close(fh);

    -- ==================== FWD: the read-forward schedules ====================
    -- attn_mac_array reads the accumulator for a PV in S1 (rdq) and writes it
    -- in S2.  The S1 read must see the S2 write of the SAME block on the same
    -- edge, which only happens when two writes to one block are ADJACENT: a
    -- PV right behind a PV, or a PV right behind a rescale.  The vector
    -- schedule above never does that (blocks step 0..ACC_N-1), so this phase
    -- does, against goldens computed here:
    --   c0 PV b1 v1   c1 PV b1 v2  (PV -> PV forward)
    --   c2,c3 idle    (the rescale hazard assertion needs b1 out of S1/S2)
    --   c4 RS b1 f    c5 PV b1 v3  (RS -> PV forward)
    --   c6 PV b0 v5   c7 PV b1 v4  (adjacent, DIFFERENT blocks: no forward)
    -- Without the forward, c1 reads acc(b1) before c0's write and the c0
    -- contribution is lost; the c5 PV adds to the pre-rescale value.
    acc_clr <= '1';
    wait until rising_edge(clk);
    acc_clr <= '0';
    wait until rising_edge(clk);
    for h in 0 to QH_TILE-1 loop
      pv_e((h+1)*E_W-1 downto h*E_W) <= std_logic_vector(to_unsigned(100 + 7*h, E_W));
      rs_f((h+1)*E_W-1 downto h*E_W) <= std_logic_vector(to_unsigned(FF, E_W));
    end loop;
    for cyc in 0 to 7 loop
      pv_valid <= '0'; rs_valid <= '0';
      for t in 0 to DIM_TILE-1 loop
        case cyc is
          when 0 => fv1 := (t mod 5) + 1;  pv_v((t+1)*K_W-1 downto t*K_W) <= std_logic_vector(to_signed(fv1, K_W));
          when 1 => fv2 := (t mod 3) + 2;  pv_v((t+1)*K_W-1 downto t*K_W) <= std_logic_vector(to_signed(fv2, K_W));
          when 5 => fv3 := (t mod 4) - 2;  pv_v((t+1)*K_W-1 downto t*K_W) <= std_logic_vector(to_signed(fv3, K_W));
          when 6 => fv5 := 3;              pv_v((t+1)*K_W-1 downto t*K_W) <= std_logic_vector(to_signed(fv5, K_W));
          when 7 => fv4 := (t mod 2) + 1;  pv_v((t+1)*K_W-1 downto t*K_W) <= std_logic_vector(to_signed(fv4, K_W));
          when others => null;
        end case;
      end loop;
      case cyc is
        when 0 | 1 | 5 | 7 => pv_valid <= '1'; pv_blk <= to_unsigned(1, clog2(ACC_N));
        when 6             => pv_valid <= '1'; pv_blk <= to_unsigned(0, clog2(ACC_N));
        when 4             => rs_valid <= '1'; rs_blk <= to_unsigned(1, clog2(ACC_N));
        when others        => null;
      end case;
      wait until rising_edge(clk);
    end loop;
    pv_valid <= '0'; rs_valid <= '0';
    for i in 1 to 6 loop wait until rising_edge(clk); end loop;

    -- goldens.  Site 5d: (x*f + 2^(Q-1)) >> Q, floor; every x*f here is >= 0
    -- before the c5 add, so integer division IS the floor.
    for h in 0 to QH_TILE-1 loop
      fe := 100 + 7*h;
      for i in 0 to N-1 loop fx(h*N + i) := 0; end loop;
      for t in 0 to DIM_TILE-1 loop
        fv1 := (t mod 5) + 1; fv2 := (t mod 3) + 2; fv3 := (t mod 4) - 2;
        fv4 := (t mod 2) + 1; fv5 := 3;
        fx(h*N + 1*DIM_TILE + t) :=
          (fe*(fv1 + fv2)*FF + 2**(QS-1)) / 2**QS + fe*fv3 + fe*fv4;
        fx(h*N + 0*DIM_TILE + t) := fe*fv5;
      end loop;
    end loop;

    for h in 0 to QH_TILE-1 loop
      for i in 0 to N-1 loop
        rd_head  <= to_unsigned(h, clog2(QH_TILE));
        rd_idx   <= to_unsigned(i, clog2(ACC_N*DIM_TILE));
        rd_valid <= '1';
        wait until rising_edge(clk);
        rd_valid <= '0';
        wait for 1 ns;
        fchk := fchk + 1;
        if o_valid /= '1' or to_real_s(o_data) /= real(fx(h*N + i)) then
          ferr := ferr + 1;
          report "tb_attn_mac_array: FWD head " & integer'image(h)
               & " elem " & integer'image(i) & " got "
               & real'image(to_real_s(o_data)) & " want "
               & integer'image(fx(h*N + i)) severity error;
        end if;
        wait until rising_edge(clk);
      end loop;
    end loop;
    assert fchk = QH_TILE*N
      report "tb_attn_mac_array: FWD phase ran " & integer'image(fchk)
           & " checks, expected " & integer'image(QH_TILE*N) severity failure;
    if ferr /= 0 then
      nerr <= nerr + ferr;
      wait for 0 ns;
    end if;

    assert err = '0'
      report "tb_attn_mac_array: the partial overflowed s32, so the premise "
           & "attn_score_q12's own width argument rests on is violated"
      severity error;

    if nerr = 0 and lat_bad = 0 then
      report "tb_attn_mac_array: PASS -- " & integer'image(NCASE)
           & " cases, QH_TILE=" & integer'image(QH_TILE)
           & " DIM_TILE=" & integer'image(DIM_TILE)
           & " ACC_N=" & integer'image(ACC_N)
           & " GAP=" & integer'image(GAP)
           & " CTL_GRP=" & integer'image(CTL_GRP)
           & ", FWD " & integer'image(fchk) & " checks"
           & ", every partial and every accumulator bit-exact, ovr="
           & std_logic'image(ovr);
    else
      report "tb_attn_mac_array: RESULT bad, " & integer'image(nerr)
           & " mismatches, " & integer'image(lat_bad)
           & " partials off the P_LAT contract" severity failure;
    end if;
    running <= false;
    wait;
  end process;

end architecture;
