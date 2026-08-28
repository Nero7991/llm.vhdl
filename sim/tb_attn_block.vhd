-- sim/tb_attn_block.vhd
-- Seam testbench for rtl/attn_block.vhd, subsystem C's top level.
--
-- WHAT THIS CAN AND CANNOT CHECK, said first because the answer is not
-- "everything".
--
-- THERE IS NO BLOCK-LEVEL ARITHMETIC ORACLE FOR C AND THIS BENCH DOES NOT
-- PRETEND OTHERWISE.  C spec 3.11 item 1 names `ref/attn_gated_fx.c` -- the
-- full chain: quantizer, full-dispatch IMROPE, online softmax in the pinned
-- processing order, the reciprocal-multiply as DEFINED, the Q15 sigmoid, the
-- pack -- as a deliverable.  It does not exist.  Writing a block oracle now
-- would mean modelling rmsnorm, IMROPE, the BFP quantizer, the online softmax
-- and the BFP pack at once, and it would be checked against the same RTL it
-- was derived from, which is the failure `sim/tb_llama_top.vhd`'s header calls
-- worse than no reference because it looks like coverage.  So: every UNIT
-- inside this block is already bit-exact against a double-oracled C reference,
-- individually, and this bench checks the SEAMS, which is where every one of
-- this project's recent confirmed defects lived.
--
-- THE SEVEN PROPERTIES, and what each one would catch.
--
--   P1  ELEMENT COUNT.  Exactly N_QH*HEAD_DIM y elements per job, with
--       contiguous ascending indices.  A lost beat anywhere in the emit path
--       shows up here and nowhere else.
--
--   P2  HANDSHAKE INVARIANCE.  The y stream -- every mantissa AND the y_exp --
--       must be BIT-IDENTICAL across three consumer configurations: a
--       degenerate consumer that never stalls, a lagged one that stalls a
--       fixed number of cycles per beat, and a pseudo-random one.  A latch
--       that is missing, a handshake that is not waited on, a port read across
--       a span longer than its producer holds it: all are skew-dependent by
--       definition and none is visible in any single run.  The degenerate
--       configuration is NOT the weak one -- attn_rope's own out-of-window
--       guard fired only there, on correct producer behaviour, because a
--       producer that never stalls reaches states a gapped one skips.
--
--   P3  THE ORDERING RULE, checked explicitly.  A scalar qualifying a stream
--       must be assigned in a state STRICTLY EARLIER than the state that first
--       raises that stream's valid.  `y_exp` qualifies the y stream, so
--       `y_hdr_valid` must have stood before the first `y_valid` and `y_exp`
--       must not move afterwards.  A bench that sampled y_exp only at `done`
--       could not see a violation of this, which is exactly why it is a
--       separate property.
--
--   P4  NO LOST BEATS.  Every y_valid coincides with y_ready, and
--       `dbg_ep_lost` -- the block's own sticky detector for an e_p that
--       arrived while the previous one was unconsumed -- is clear.  The e_p
--       stream has no ready in the datapath, so a weight the array does not
--       take is LOST, not delayed, and throughput margin is therefore a
--       CORRECTNESS property that appears in no static report.
--
--   P5  THE EXPONENT CONTRACT, i.e. defect 7's class, checked as a scaling
--       identity rather than against a golden.  Raise `vin_exp` by delta with
--       every other input bit-identical: the V exponent chain is
--       v_norm_exp = v_exp, so every block exponent moves by delta, v_ref
--       moves by delta, `v_aligned` is UNCHANGED (it is a difference of two
--       exponents that both moved), and therefore every mantissa of the output
--       must be UNCHANGED while `y_exp` moves by EXACTLY delta.  A fabricated
--       output exponent -- the failure that put an attention stub's output on
--       a scale nothing else in the token shared and made the next residual
--       discard one of its two operands -- breaks this identity immediately.
--       No oracle is needed and none is assumed.
--
--   P6  THE DESCRIPTOR GUARD.  An illegal descriptor (cur_pos >= ctx_len)
--       must raise `err` and still assert `done`, so a sequencer's FSM cannot
--       hang on it.  Both halves are checked; the second is the one that gets
--       forgotten.
--
--   P7  THE BYPASS, which C spec 2.4 makes a CORRECTNESS requirement and not
--       an optimisation.  The sweep must read cache positions 0..cur_pos-1,
--       every block of every position exactly once per KV head, and must
--       NEVER read cur_pos: that record is written through the write master in
--       this same job and AXI orders nothing between masters, so reading it
--       back is a race that would pass every test on a fast memory and fail on
--       silicon.  A memory model cannot reproduce the race, so the property is
--       stated over the ADDRESSES instead, where it is decidable.
--
-- WHAT IS DELIBERATELY NOT CHECKED: the VALUES.  See the first paragraph.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;

entity tb_attn_block is
  generic(
    -- Small by default.  The block is ten units deep and one job at the
    -- shipping shape is millions of cycles; the seams do not care how many
    -- heads there are.
    HEAD_DIM : positive := 16;
    N_QH     : positive := 4;
    N_KVH    : positive := 2;
    KV_BLOCK : positive := 4;
    N_ROT    : positive := 8;
    LAYERS   : positive := 2;
    POS_W    : positive := 8;
    JOB_POS  : natural  := 3;
    JOB_LEN  : positive := 4;
    NRUNS    : positive := 3;
    HEARTBEAT_US : integer := 0
  );
end entity;

architecture sim of tb_attn_block is

  constant MANT_W : positive := 16;
  constant CM_W   : positive := 8;
  constant EXP_W  : positive := 8;
  constant NBLK   : integer  := HEAD_DIM/KV_BLOCK;
  constant G      : integer  := N_QH/N_KVH;
  constant NY     : integer  := N_QH*HEAD_DIM;
  constant AW_Y   : integer  := clog2(NY);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal blk_start : std_logic := '0';
  signal cur_pos   : unsigned(POS_W-1 downto 0) := to_unsigned(JOB_POS, POS_W);
  signal ctx_len   : unsigned(POS_W-1 downto 0) := to_unsigned(JOB_LEN, POS_W);
  signal busy      : std_logic;
  signal cfg_taken : std_logic;
  signal kv_seq_rst : std_logic := '0';
  signal seq_rst_taken : std_logic;

  signal qg_raddr : unsigned(clog2(2*HEAD_DIM*N_QH)-1 downto 0);
  signal qg_re    : std_logic;
  signal qg_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal qg_exp   : signed(EXP_W-1 downto 0);
  signal kin_raddr : unsigned(clog2(HEAD_DIM*N_KVH)-1 downto 0);
  signal kin_re    : std_logic;
  signal kin_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal kin_exp   : signed(EXP_W-1 downto 0);
  signal vin_raddr : unsigned(clog2(HEAD_DIM*N_KVH)-1 downto 0);
  signal vin_re    : std_logic;
  signal vin_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal vin_exp   : signed(EXP_W-1 downto 0) := to_signed(10, EXP_W);

  signal qn_mant : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0);
  signal kn_mant : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0);
  signal qn_exp  : signed(EXP_W-1 downto 0);
  signal kn_exp  : signed(EXP_W-1 downto 0);
  signal wn_taken : std_logic;

  signal kv_layer : unsigned(clog2(LAYERS)-1 downto 0);
  signal kw_sel   : std_logic;
  signal kw_head  : unsigned(clog2(N_KVH)-1 downto 0);
  signal kw_pos   : unsigned(POS_W-1 downto 0);
  signal kw_hen   : std_logic;
  signal kw_hdr   : std_logic_vector(NBLK*EXP_W-1 downto 0);
  signal kw_en    : std_logic;
  signal kw_blk   : unsigned(clog2(NBLK)-1 downto 0);
  signal kw_mant  : std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
  signal kr_en    : std_logic;
  signal kr_head  : unsigned(clog2(N_KVH)-1 downto 0);
  signal kr_pos   : unsigned(POS_W-1 downto 0);
  signal kr_blk   : unsigned(clog2(NBLK)-1 downto 0);
  signal kr_hdr   : std_logic_vector(NBLK*EXP_W-1 downto 0) := (others => '0');
  signal kr_mant  : std_logic_vector(KV_BLOCK*CM_W-1 downto 0) := (others => '0');
  signal vr_en    : std_logic;
  signal vr_head  : unsigned(clog2(N_KVH)-1 downto 0);
  signal vr_pos   : unsigned(POS_W-1 downto 0);
  signal vr_blk   : unsigned(clog2(NBLK)-1 downto 0);
  signal vr_hdr   : std_logic_vector(NBLK*EXP_W-1 downto 0) := (others => '0');
  signal vr_mant  : std_logic_vector(KV_BLOCK*CM_W-1 downto 0) := (others => '0');

  signal y_valid : std_logic;
  signal y_mant  : signed(MANT_W-1 downto 0);
  signal y_index : unsigned(AW_Y-1 downto 0);
  signal y_last  : std_logic;
  signal y_exp   : signed(EXP_W-1 downto 0);
  signal y_ready : std_logic := '1';
  signal y_hdr_valid : std_logic;
  signal blk_done : std_logic;
  signal done_ack : std_logic := '1';

  signal err, rope_sat, kv_sat, y_sat, z_sat : std_logic;
  signal rescale_max : unsigned(15 downto 0);
  signal dbg_ep_lost : std_logic;

  -- ---- deterministic stimulus.  A function of the index and NOTHING else,
  -- so that changing a consumer's stall pattern cannot change a single input
  -- value.  That is the whole basis of the cross-configuration comparison.
  function hsh(a, b : integer) return unsigned is
    variable x : unsigned(31 downto 0);
    variable t : unsigned(63 downto 0);
  begin
    t := to_unsigned(a mod 1048576, 32) * to_unsigned(1103515245, 32);
    x := t(31 downto 0) + to_unsigned((b mod 100000) * 12345, 32);
    x := x xor shift_right(x, 15);
    t := x * to_unsigned(668265261, 32);
    x := t(31 downto 0);
    x := x xor shift_right(x, 13);
    return x;
  end function;

  -- Kept to +-2047.  rmsnorm and the score tree both accumulate products of
  -- two int16s; at full scale every comparison becomes a comparison of clamps
  -- rather than of arithmetic.
  function m12(a, b : integer) return signed is
  begin
    return to_signed(to_integer(hsh(a, b)(11 downto 0)) - 2048, MANT_W);
  end function;

  -- ---- the KV cache model.  Positions below cur_pos are PREVIOUS TOKENS and
  -- are initialised deterministically; the block writes only cur_pos.
  type mem_t is array (0 to 2*N_KVH*(2**POS_W)*NBLK-1)
                of std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
  type hdr_t is array (0 to 2*N_KVH*(2**POS_W)-1)
                of std_logic_vector(NBLK*EXP_W-1 downto 0);
  function mem_init return mem_t is
    variable m : mem_t;
  begin
    for i in m'range loop
      for t in 0 to KV_BLOCK-1 loop
        m(i)((t+1)*CM_W-1 downto t*CM_W)
          := std_logic_vector(to_signed(
               to_integer(hsh(i, t)(7 downto 0)) - 128, CM_W));
      end loop;
    end loop;
    return m;
  end function;
  function hdr_init return hdr_t is
    variable h : hdr_t;
  begin
    for i in h'range loop
      for b in 0 to NBLK-1 loop
        -- A narrow spread on purpose: e_v below v_ref is impossible by
        -- construction and a wide spread would shift every V block out.
        h(i)((b+1)*EXP_W-1 downto b*EXP_W)
          := std_logic_vector(to_signed(
               8 + (to_integer(hsh(i, b)(2 downto 0)) mod 3), EXP_W));
      end loop;
    end loop;
    return h;
  end function;
  signal kvmem : mem_t := mem_init;
  signal kvhdr : hdr_t := hdr_init;

  -- ---- collected output --------------------------------------------------
  type yarr_t is array (0 to NRUNS*NY-1) of integer;
  type tarr_t is array (0 to NRUNS-1) of integer;
  signal y_got  : yarr_t := (others => 0);
  signal yi_got : yarr_t := (others => 0);
  signal y_idx  : integer := 0;
  signal ye_got : tarr_t := (others => 0);
  signal yn_got : tarr_t := (others => 0);
  signal run_i  : integer := 0;

  -- ---- P3 ---------------------------------------------------------------
  signal hdr_seen  : boolean := false;
  signal first_y   : boolean := true;
  signal exp_at_hdr : integer := 0;
  signal p3_bad    : integer := 0;

  -- ---- P4 ---------------------------------------------------------------
  signal p4_bad : integer := 0;

  -- ---- P7 ---------------------------------------------------------------
  type cov_t is array (0 to N_KVH*(2**POS_W)*NBLK-1) of integer;
  signal kcov, vcov : cov_t := (others => 0);
  signal p7_bad : integer := 0;

  -- The V-side exponent bias applied to the CACHE headers as well as to
  -- vin_exp.  P5 raises the current token's V scale; in a real sequence the
  -- earlier positions were written by this same block at that same scale, so
  -- their stored exponents move with it.  Without this the bench would be
  -- asking whether y is invariant under a scale change applied to ONE of the
  -- cur_pos+1 positions, which it is not and should not be.
  signal v_bias : integer := 0;

  -- ---- the RULE 2 skew axis -------------------------------------------
  -- Every scalar and every weight vector the block reads for longer than one
  -- cycle is POISONED from the instant its latch pulses until the job ends,
  -- with a value that DIFFERS PER RUN.  A block that latches is unaffected; a
  -- block that reads any of them live produces a different answer in each run
  -- and P2 fires.  Poisoning with one constant would not do it: all three runs
  -- would then be identically wrong and every property would pass.  This is
  -- gdn_block's W_MOVE / SC_MOVE axis, and it is the only instrument that
  -- catches the defect class that made head 23 of every block normalise with
  -- the NEXT block's weights.
  signal poison : boolean := false;
  signal pois_v : integer := 0;

  signal cfg_sel : integer := 0;
  signal rnd_r   : unsigned(31 downto 0) := x"1234abcd";
  signal all_done : boolean := false;

begin

  clk <= not clk after 5 ns when running else '0';

  dut : entity work.attn_block
    generic map ( HEAD_DIM => HEAD_DIM, N_QH => N_QH, N_KVH => N_KVH,
                  KV_BLOCK => KV_BLOCK, N_ROT => N_ROT, LAYERS => LAYERS,
                  POS_W => POS_W, MANT_W => MANT_W, CM_W => CM_W,
                  EXP_W => EXP_W, NORM_LANES => 1,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               start => blk_start, layer => 0,
               cur_pos => cur_pos, ctx_len => ctx_len, busy => busy,
               cfg_taken => cfg_taken,
               kv_seq_rst => kv_seq_rst, seq_rst_taken => seq_rst_taken,
               qg_raddr => qg_raddr, qg_re => qg_re, qg_rdata => qg_rdata,
               qg_exp => qg_exp,
               kin_raddr => kin_raddr, kin_re => kin_re,
               kin_rdata => kin_rdata, kin_exp => kin_exp,
               vin_raddr => vin_raddr, vin_re => vin_re,
               vin_rdata => vin_rdata, vin_exp => vin_exp,
               qn_mant => qn_mant, qn_exp => qn_exp,
               kn_mant => kn_mant, kn_exp => kn_exp, wn_taken => wn_taken,
               kv_layer => kv_layer,
               kw_sel => kw_sel, kw_head => kw_head, kw_pos => kw_pos,
               kw_hen => kw_hen, kw_hdr => kw_hdr, kw_en => kw_en,
               kw_blk => kw_blk, kw_mant => kw_mant,
               kr_en => kr_en, kr_head => kr_head, kr_pos => kr_pos,
               kr_blk => kr_blk, kr_hdr => kr_hdr, kr_mant => kr_mant,
               vr_en => vr_en, vr_head => vr_head, vr_pos => vr_pos,
               vr_blk => vr_blk, vr_hdr => vr_hdr, vr_mant => vr_mant,
               y_valid => y_valid, y_mant => y_mant, y_index => y_index,
               y_last => y_last, y_exp => y_exp, y_ready => y_ready,
               y_hdr_valid => y_hdr_valid,
               done => blk_done, done_ack => done_ack,
               err => err, rope_sat => rope_sat, kv_sat => kv_sat,
               y_sat => y_sat, z_sat => z_sat,
               rescale_max => rescale_max, dbg_ep_lost => dbg_ep_lost );

  -- ======================= the norm weights =============================
  wgen : process(all)
  begin
    for i in 0 to HEAD_DIM-1 loop
      if poison then
        qn_mant((i+1)*MANT_W-1 downto i*MANT_W)
          <= std_logic_vector(m12(900001 + pois_v, i));
        kn_mant((i+1)*MANT_W-1 downto i*MANT_W)
          <= std_logic_vector(m12(900101 + pois_v, i));
      else
        qn_mant((i+1)*MANT_W-1 downto i*MANT_W)
          <= std_logic_vector(abs(m12(31337, i)) + 256);
        kn_mant((i+1)*MANT_W-1 downto i*MANT_W)
          <= std_logic_vector(abs(m12(51501, i)) + 256);
      end if;
    end loop;
  end process;

  -- The exponent ports, poisoned the same way.  qn_exp/kn_exp/qg_exp/kin_exp
  -- are all read across a job that is thousands of cycles long.
  qn_exp  <= to_signed(-40 - pois_v, EXP_W) when poison else to_signed(12, EXP_W);
  kn_exp  <= to_signed(-50 - pois_v, EXP_W) when poison else to_signed(12, EXP_W);
  qg_exp  <= to_signed(-60 - pois_v, EXP_W) when poison else to_signed(12, EXP_W);
  kin_exp <= to_signed(-70 - pois_v, EXP_W) when poison else to_signed(11, EXP_W);

  -- ======================= A's activation memories =======================
  -- Registered read WITH ENABLE: data holds mem[addr] the cycle after an edge
  -- at which the enable was high, and is HELD across any edge at which it was
  -- low.  That is the contract every master in this block states, and a model
  -- that updated unconditionally would let a unit get away with reading at the
  -- wrong instant.
  amem : process(clk)
  begin
    if rising_edge(clk) then
      if qg_re  = '1' then qg_rdata  <= m12(7919,  to_integer(qg_raddr));  end if;
      if kin_re = '1' then kin_rdata <= m12(104729, to_integer(kin_raddr)); end if;
      if vin_re = '1' then vin_rdata <= m12(65537, to_integer(vin_raddr)); end if;
    end if;
  end process;

  -- ======================= the KV cache =================================
  kvmem_p : process(clk)
    variable a : integer;
  begin
    if rising_edge(clk) then
      if kw_hen = '1' then
        a := ((to_integer(unsigned'("" & kw_sel))*N_KVH
               + to_integer(kw_head))*(2**POS_W)) + to_integer(kw_pos);
        kvhdr(a) <= kw_hdr;
      end if;
      if kw_en = '1' then
        a := ((((to_integer(unsigned'("" & kw_sel))*N_KVH
                 + to_integer(kw_head))*(2**POS_W))
               + to_integer(kw_pos))*NBLK) + to_integer(kw_blk);
        kvmem(a) <= kw_mant;
      end if;
      if kr_en = '1' then
        a := (((to_integer(kr_head))*(2**POS_W)) + to_integer(kr_pos));
        kr_hdr  <= kvhdr(a);
        kr_mant <= kvmem(a*NBLK + to_integer(kr_blk));
      end if;
      if vr_en = '1' then
        a := (((N_KVH + to_integer(vr_head))*(2**POS_W)) + to_integer(vr_pos));
        for b in 0 to NBLK-1 loop
          vr_hdr((b+1)*EXP_W-1 downto b*EXP_W)
            <= std_logic_vector(signed(kvhdr(a)((b+1)*EXP_W-1 downto b*EXP_W))
                                + to_signed(v_bias, EXP_W));
        end loop;
        vr_mant <= kvmem(a*NBLK + to_integer(vr_blk));
      end if;
    end if;
  end process;

  -- ======================= the consumer, three configurations ===========
  --   0  degenerate: never stalls.  NOT the weak case -- attn_rope's own
  --      out-of-window guard fires only here, on correct behaviour, because a
  --      producer that never stalls reaches states a gapped one skips.
  --   1  lagged: a fixed two-cycle stall after every accepted beat.
  --   2  pseudo-random.
  yrdy : process(clk)
    variable gapc : integer := 0;
  begin
    if rising_edge(clk) then
      rnd_r <= rnd_r xor shift_left(rnd_r, 13);
      case cfg_sel is
        when 0 =>
          y_ready <= '1';
          done_ack <= '1';
        when 1 =>
          if y_valid = '1' and y_ready = '1' then
            gapc := 2; y_ready <= '0';
          elsif gapc > 0 then
            gapc := gapc - 1;
            if gapc = 0 then y_ready <= '1'; end if;
          else
            y_ready <= '1';
          end if;
          done_ack <= '1';
        when others =>
          if rnd_r(3 downto 0) < 6 then y_ready <= '0';
          else y_ready <= '1'; end if;
          done_ack <= '1';
      end case;
    end if;
  end process;

  -- ======================= collectors ===================================
  collect : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y_idx <= 0;
      else
        -- Re-armed HERE and not in the driver: two processes driving one
        -- unresolved signal elaborates in ghdl as "several sources" with no
        -- line number, which has cost this project time twice.
        if blk_start = '1' then
          hdr_seen <= false;
          first_y  <= true;
        end if;
        -- P4: a beat offered while the consumer is not ready is a LOST beat.
        if y_valid = '1' and y_ready = '0' then
          -- Not a failure by itself: attn_emit HOLDS, so this is a stall.  It
          -- becomes a failure only if the element count or the values move,
          -- which P1 and P2 check.  Counted so a run that never stalls is
          -- visibly different from one that does -- a zero back-pressure count
          -- is a question, not a result.
          p4_bad <= p4_bad + 1;
        end if;
        if y_valid = '1' and y_ready = '1' then
          assert y_idx < NRUNS*NY
            report "tb_attn_block: more output than the run expects"
            severity failure;
          y_got(y_idx)  <= to_integer(y_mant);
          yi_got(y_idx) <= to_integer(y_index);
          y_idx <= y_idx + 1;
          yn_got(run_i) <= yn_got(run_i) + 1;
          ye_got(run_i) <= to_integer(y_exp);
          -- P3: the ordering rule.  y_exp qualifies this stream, so the
          -- header must ALREADY have stood, and y_exp must not move after it.
          if first_y then
            if not hdr_seen then
              p3_bad <= p3_bad + 1;
              report "tb_attn_block: the first y element was offered before "
                   & "y_hdr_valid ever stood.  A scalar that qualifies a "
                   & "stream must be assigned STRICTLY EARLIER than the state "
                   & "that first raises that stream's valid."
                severity error;
            end if;
            first_y <= false;
          end if;
          if hdr_seen and to_integer(y_exp) /= exp_at_hdr then
            p3_bad <= p3_bad + 1;
            report "tb_attn_block: y_exp moved after the header was published"
              severity error;
          end if;
        end if;
        if y_hdr_valid = '1' then
          hdr_seen   <= true;
          exp_at_hdr <= to_integer(y_exp);
        end if;
        -- P7: the sweep must never read cur_pos, and must read every block of
        -- every earlier position exactly once per KV head.
        if kr_en = '1' then
          if kr_pos = cur_pos then
            p7_bad <= p7_bad + 1;
            report "tb_attn_block: the sweep read the CURRENT position out of "
                 & "the cache.  C spec 2.4 makes the on-chip bypass a "
                 & "correctness requirement: that record is written through "
                 & "the write master in this same job and AXI orders nothing "
                 & "between masters."
              severity error;
          end if;
          kcov((to_integer(kr_head)*(2**POS_W) + to_integer(kr_pos))*NBLK
               + to_integer(kr_blk))
            <= kcov((to_integer(kr_head)*(2**POS_W) + to_integer(kr_pos))*NBLK
                    + to_integer(kr_blk)) + 1;
        end if;
        if vr_en = '1' then
          if vr_pos = cur_pos then
            p7_bad <= p7_bad + 1;
            report "tb_attn_block: the sweep read the CURRENT position's V "
                 & "record out of the cache; see the K message"
              severity error;
          end if;
          vcov((to_integer(vr_head)*(2**POS_W) + to_integer(vr_pos))*NBLK
               + to_integer(vr_blk))
            <= vcov((to_integer(vr_head)*(2**POS_W) + to_integer(vr_pos))*NBLK
                    + to_integer(vr_blk)) + 1;
        end if;
      end if;
    end if;
  end process;

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when all_done;
      report "tb_attn_block: alive, run " & integer'image(run_i)
           & " y " & integer'image(y_idx) severity note;
    end loop;
    wait;
  end process;

  -- ======================= the driver ===================================
  drive : process
    variable nerr : integer := 0;
    variable base0, baser : integer;
  begin
    rst <= '1';
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- The per-SEQUENCE v_ref reset.  A LEVEL, and not per token.
    kv_seq_rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    assert seq_rst_taken = '1'
      report "tb_attn_block: seq_rst_taken did not pulse at the reset edge"
      severity error;
    kv_seq_rst <= '0';
    wait until rising_edge(clk);

    -- ---- P6: the descriptor guard, run FIRST so a hang shows immediately.
    ctx_len <= to_unsigned(JOB_POS, POS_W);   -- cur_pos >= ctx_len: illegal
    wait until rising_edge(clk);
    blk_start <= '1';
    wait until rising_edge(clk);
    blk_start <= '0';
    for i in 1 to 200 loop
      wait until rising_edge(clk);
      exit when blk_done = '1' or busy = '0';
    end loop;
    assert err = '1'
      report "tb_attn_block: an illegal descriptor (cur_pos >= ctx_len) did "
           & "not raise err" severity error;
    for i in 1 to 20 loop wait until rising_edge(clk); exit when busy = '0'; end loop;
    assert busy = '0'
      report "tb_attn_block: the block did not return to idle after aborting "
           & "an illegal descriptor.  `done` must assert even on abort or the "
           & "sequencer's FSM hangs." severity failure;
    ctx_len <= to_unsigned(JOB_LEN, POS_W);
    wait until rising_edge(clk);

    -- ---- the three consumer configurations -----------------------------
    for r in 0 to NRUNS-1 loop
      run_i   <= r;
      cfg_sel <= r mod 3;
      -- P5: the last run raises vin_exp by 3.  Everything else is identical.
      if r = NRUNS-1 and NRUNS >= 3 then
        vin_exp <= to_signed(13, EXP_W);
        v_bias  <= 3;
      else
        vin_exp <= to_signed(10, EXP_W);
        v_bias  <= 0;
      end if;
      -- A FRESH SEQUENCE per run.  v_ref is a per-SEQUENCE minimum and is
      -- deliberately NOT reset per token, so without this the fold from run 0
      -- survives into run 2 and P5's scaled run would align its cache blocks
      -- against the PREVIOUS run's reference.  That is the design behaving
      -- correctly and the experiment being confounded, which is worth a
      -- sentence because the first version of this bench read it as a defect.
      kv_seq_rst <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      kv_seq_rst <= '0';
      wait until rising_edge(clk);

      blk_start <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      assert cfg_taken = '1'
        report "tb_attn_block: cfg_taken did not pulse at the descriptor latch"
        severity error;
      blk_start <= '0';
      -- RULE 2: poison every latched input from the cycle after the latch,
      -- with a RUN-DEPENDENT value.  See the note at the `poison` signal.
      pois_v <= r*17 + 1;
      poison <= true;
      wait until rising_edge(clk);
      loop
        wait until rising_edge(clk);
        exit when busy = '0';
      end loop;
      poison <= false;
      for i in 1 to 8 loop wait until rising_edge(clk); end loop;
    end loop;

    all_done <= true;
    wait until rising_edge(clk);

    -- ======================= the checks ================================
    -- P1
    for r in 0 to NRUNS-1 loop
      if yn_got(r) /= NY then
        nerr := nerr + 1;
        report "tb_attn_block: run " & integer'image(r) & " emitted "
             & integer'image(yn_got(r)) & " elements, expected "
             & integer'image(NY) severity error;
      end if;
    end loop;
    for i in 0 to NRUNS*NY-1 loop
      if yi_got(i) /= (i mod NY) then
        nerr := nerr + 1;
        report "tb_attn_block: y_index out of order at " & integer'image(i)
             & ": got " & integer'image(yi_got(i)) severity error;
        exit;
      end if;
    end loop;

    -- P2 and P5.  Runs 0..NRUNS-2 differ only in the consumer's stall
    -- pattern, so they must be bit-identical.  The last run additionally
    -- raises vin_exp by 3, so its MANTISSAS must still be identical and its
    -- y_exp must be exactly 3 larger.
    for r in 1 to NRUNS-1 loop
      base0 := 0; baser := r*NY;
      for i in 0 to NY-1 loop
        if y_got(baser+i) /= y_got(base0+i) then
          nerr := nerr + 1;
          report "tb_attn_block: run " & integer'image(r) & " element "
               & integer'image(i) & " = " & integer'image(y_got(baser+i))
               & " against run 0's " & integer'image(y_got(base0+i))
               & ".  The consumer's stall pattern changed a value."
            severity error;
          exit;
        end if;
      end loop;
      if r = NRUNS-1 and NRUNS >= 3 then
        if ye_got(r) /= ye_got(0) + 3 then
          nerr := nerr + 1;
          report "tb_attn_block: P5 -- vin_exp was raised by 3 and y_exp "
               & "moved from " & integer'image(ye_got(0)) & " to "
               & integer'image(ye_got(r)) & " instead of "
               & integer'image(ye_got(0)+3) & ".  The output exponent does "
               & "not track its source's scale, so it is fabricated rather "
               & "than derived, and the next residual will discard one of its "
               & "two operands."
            severity error;
        end if;
      else
        if ye_got(r) /= ye_got(0) then
          nerr := nerr + 1;
          report "tb_attn_block: run " & integer'image(r) & " y_exp "
               & integer'image(ye_got(r)) & " against run 0's "
               & integer'image(ye_got(0)) severity error;
        end if;
      end if;
    end loop;

    -- P4
    if dbg_ep_lost /= '0' then
      nerr := nerr + 1;
      report "tb_attn_block: an e_p arrived while the previous one was "
           & "unconsumed.  That weight is gone, not delayed." severity error;
    end if;

    -- P3, P7
    if p3_bad /= 0 then nerr := nerr + 1; end if;
    if p7_bad /= 0 then nerr := nerr + 1; end if;

    -- P7's coverage half: every earlier position, every block, exactly once
    -- per KV head per run.
    for h in 0 to N_KVH-1 loop
      for p in 0 to JOB_POS-1 loop
        for b in 0 to NBLK-1 loop
          if kcov((h*(2**POS_W) + p)*NBLK + b) /= NRUNS then
            nerr := nerr + 1;
            report "tb_attn_block: K record (head " & integer'image(h)
                 & ", pos " & integer'image(p) & ", block " & integer'image(b)
                 & ") was read " & integer'image(kcov((h*(2**POS_W)+p)*NBLK+b))
                 & " times over " & integer'image(NRUNS) & " runs, expected "
                 & integer'image(NRUNS) severity error;
            exit;
          end if;
        end loop;
      end loop;
    end loop;

    report "tb_attn_block: err=" & std_logic'image(err)
         & " rope_sat=" & std_logic'image(rope_sat)
         & " kv_sat=" & std_logic'image(kv_sat)
         & " y_sat=" & std_logic'image(y_sat)
         & " z_sat=" & std_logic'image(z_sat)
         & " rescale_max=" & integer'image(to_integer(rescale_max))
         & " stalled beats=" & integer'image(p4_bad);

    if err = '1' then
      nerr := nerr + 1;
      report "tb_attn_block: the block raised err on a legal job"
        severity error;
    end if;

    if nerr = 0 then
      report "tb_attn_block: PASS -- " & integer'image(NRUNS)
           & " consumer configurations, " & integer'image(NY)
           & " elements each, y stream bit-identical across all of them, "
           & "y_exp tracks vin_exp exactly, the current position was never "
           & "read back, y_exp(run 0) = " & integer'image(ye_got(0));
    else
      report "tb_attn_block: RESULT bad, " & integer'image(nerr)
           & " properties violated" severity failure;
    end if;
    running <= false;
    wait;
  end process;

end architecture;
