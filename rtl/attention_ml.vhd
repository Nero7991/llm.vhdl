-- rtl/attention_ml.vhd
-- MULTI-LAYER (banked KV) variant of rtl/attention.vhd for the SHARED-datapath
-- engine (rtl/engine_shared.vhd).
--
-- IDENTICAL compute (scores / softmax / V-weighted sum + all exponent
-- bookkeeping) to attention.vhd -- the ONLY change is that the on-chip KV cache
-- now holds NLAYERS independent banks, selected at RUNTIME by the `layer` port,
-- so ONE attention compute datapath is time-multiplexed across all 5 transformer
-- layers (each layer keeps its own persistent K/V history at bank[layer]).
--
--   write/read slot  = layer*MAXPOS + pos       (one KVDIM-wide word per pos)
--   per-slot exp     = layer*MAXPOS + pos        (K,V block exps)
--
-- `rst` clears the position/pointer state (NOT the BRAM banks -- see below).
--
-- KV cache is held in SYNCHRONOUS BRAM (rtl/kv_mem.vhd), not signal arrays, so
-- attention_ml fits the XCZU3EG.  Each cache uses ONE word per (layer,pos) that
-- is KVDIM*16 bits wide (a whole position's K or V vector), so a single BRAM
-- read returns everything needed for one position.  Depth = NLAYERS*MAXPOS.
-- Access is registered-read (1-cycle latency): the position-sequential score
-- (S_SCORE) and weighted-sum (S_WACC) loops issue the read address for the next
-- position and consume the registered data one cycle later (a read-ahead bubble,
-- like matmul_rt), so the math is bit-identical to the array version.
--
-- BRAM cannot be mass-reset, so there is NO (others=>0) cache clear.  Attention
-- only reads positions 0..cur_pos, and every one of those was written earlier in
-- THIS run (each token writes its own K/V at cur_pos in S_IDLE before the passes
-- read positions 0..cur_pos), so write-before-read holds and no clear is needed.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;   -- msb_pos, clog2

entity attention_ml is
  generic(
    DIM       : positive := 64;
    HEAD_SIZE : positive := 8;
    NHEADS    : positive := 8;
    NKVH      : positive := 4;
    KVDIM     : positive := 32;   -- = NKVH*HEAD_SIZE
    MAXPOS    : positive := 8;    -- static cache depth per bank (>= cur_pos+1)
    NLAYERS   : positive := 5;    -- number of independent KV banks
    Q         : integer  := 12    -- softmax Q-format (probs = prob_q / 2^Q)
  );
  port(
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
    layer      : in  integer;     -- which KV bank (0..NLAYERS-1)
    cur_pos    : in  integer;
    -- current-position post-rope query (BFP: q[i] = q_mant[i]*2^-q_exp)
    q_mant     : in  std_logic_vector(DIM*16-1 downto 0);
    q_exp      : in  integer;
    -- current-position K (post-rope) / V (pre-rope) to store at slot cur_pos
    k_new_mant : in  std_logic_vector(KVDIM*16-1 downto 0);
    k_new_exp  : in  integer;
    v_new_mant : in  std_logic_vector(KVDIM*16-1 downto 0);
    v_new_exp  : in  integer;
    done       : out std_logic;
    -- attention output xb (BFP: xb[i] = xb_mant[i]*2^-xb_exp)
    xb_mant    : out std_logic_vector(DIM*16-1 downto 0);
    xb_exp     : out integer;
    -- DEBUG taps (last-head values, for HW non-determinism localisation):
    dbg_sc     : out integer;   -- sum of packed scores (softmax input)
    dbg_sum    : out integer;   -- softmax sum_l (divider denominator)
    dbg_num    : out integer    -- sum of num_s lanes (weighted sum, divider numerator)
  );
end entity attention_ml;

architecture rtl of attention_ml is
  constant KV_MUL : integer := NHEADS / NKVH;
  -- round(2^15 / sqrt(8)) = 11585  (1/sqrt(HEAD_SIZE), HEAD_SIZE=8)
  constant INV_SQRT8_Q15 : integer := 11585;

  -- ---- banked KV cache in BRAM -------------------------------------------
  -- One KVDIM-wide word per (layer,pos): a whole position's K (or V) vector.
  constant KVWORDS  : integer := NLAYERS*MAXPOS;   -- depth (words)
  constant KVW      : integer := KVDIM*16;         -- word width (a full pos vec)
  constant KVADDR_W : integer := clog2(KVWORDS);

  component kv_mem is
    generic(WORDS : positive; W : positive := 16);
    port(clk : in std_logic; we : in std_logic;
         waddr, raddr : in std_logic_vector(clog2(WORDS)-1 downto 0);
         din  : in  std_logic_vector(W-1 downto 0);
         dout : out std_logic_vector(W-1 downto 0));
  end component;

  signal kv_we    : std_logic;
  signal kv_waddr : std_logic_vector(KVADDR_W-1 downto 0);
  signal kv_raddr : std_logic_vector(KVADDR_W-1 downto 0);
  signal fetch_pos: integer := 0;               -- clamped read position 0..MAXPOS-1
  signal kc_v_do  : std_logic_vector(KVW-1 downto 0);   -- K mantissa word out
  signal vc_v_do  : std_logic_vector(KVW-1 downto 0);   -- V mantissa word out
  signal kc_e_do  : std_logic_vector(31 downto 0);      -- K block-exp out
  signal vc_e_do  : std_logic_vector(31 downto 0);      -- V block-exp out
  signal kc_e_di  : std_logic_vector(31 downto 0);      -- K block-exp in
  signal vc_e_di  : std_logic_vector(31 downto 0);      -- V block-exp in

  -- ---- per-element attention accumulators (value = acc * 2^-(Q+vref)) -----
  type acc_arr is array(0 to DIM-1) of signed(63 downto 0);
  signal xb_acc : acc_arr := (others => (others => '0'));

  -- ---- latches / bookkeeping --------------------------------------------
  signal cp      : integer := 0;   -- latched cur_pos
  signal lyr     : integer := 0;   -- latched layer (bank select)
  signal hd      : integer := 0;   -- current head
  signal vref_s  : integer := 0;   -- min vc_e over 0..cp
  signal qmant_l : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal qexp_l  : integer := 0;

  -- ---- POSITION-SEQUENTIAL iteration state (registers, one t/cycle) -------
  -- t_idx now doubles as the BRAM read-ahead pointer: at t_idx it ISSUES the
  -- read for position t_idx (via the combinational kv_raddr) and CONSUMES the
  -- registered data for position t_idx-1 (see S_VREF/S_SCORE/S_WACC).
  signal t_idx     : integer := 0;                 -- read-ahead position pointer
  signal smax_s    : signed(63 downto 0) := (others => '0'); -- running |score| max
  type sfx_sig_arr is array(0 to MAXPOS-1) of signed(63 downto 0);
  signal sfx_s     : sfx_sig_arr := (others => (others => '0')); -- per-pos raw scores
  signal qhead_s   : integer_vector(0 to HEAD_SIZE-1) := (others => 0); -- re-BFP q head
  signal qe_head_s : integer := 0;                 -- q head block exp
  type num_arr is array(0 to HEAD_SIZE-1) of signed(63 downto 0);
  signal num_s     : num_arr := (others => (others => '0'));  -- per-j V-weighted sums
  signal amax_s    : signed(63 downto 0) := (others => '0');  -- running |xb_acc| max (S_PACK)

  -- Force these indexed arrays to REGISTERS (not distributed LUTRAM).  Under the
  -- 93%+ engine congestion Vivado inferred them as UNINITIALIZED LUTRAM (349
  -- cells), giving non-deterministic HW reads -> wrong tokens.  Registers carry
  -- their init and are deterministic.
  attribute ram_style : string;
  attribute ram_style of xb_acc : signal is "registers";
  attribute ram_style of sfx_s  : signal is "registers";
  attribute ram_style of num_s  : signal is "registers";

  -- ---- softmax interface -------------------------------------------------
  signal sm_start      : std_logic := '0';
  signal sm_done       : std_logic;
  signal sm_n          : integer := 0;
  signal sm_score_mant : std_logic_vector(MAXPOS*16-1 downto 0) := (others => '0');
  signal sm_score_exp  : integer := 0;
  signal sm_prob_q     : std_logic_vector(MAXPOS*32-1 downto 0);
  signal sm_e_out      : std_logic_vector(MAXPOS*32-1 downto 0);
  signal sm_sum_out    : std_logic_vector(63 downto 0);
  signal e_l           : std_logic_vector(MAXPOS*32-1 downto 0) := (others => '0');
  signal sum_l         : signed(63 downto 0) := to_signed(1, 64);

  -- Weighted-sum fixed-point headroom (see attention.vhd).
  constant WQ : integer := 16;

  -- Iterative restoring divider state (replaces the single-cycle 96-bit
  -- combinational '/' in S_WDIV, which synthesised to ~1273 CARRY8 and was both
  -- the u_att congestion hotspot and the engine Fmax limiter). One shift-subtract
  -- per cycle, 96 cycles per lane; bit-exact with signed truncate-toward-zero.
  signal div_absnum : unsigned(95 downto 0) := (others => '0');  -- |biased num|
  signal div_quo    : unsigned(95 downto 0) := (others => '0');  -- floor(|num|/den)
  signal div_rem    : unsigned(63 downto 0) := (others => '0');  -- running remainder (< den)
  signal div_den    : unsigned(63 downto 0) := (others => '0');  -- sum_l (positive)
  signal div_sign   : std_logic := '0';                         -- result sign
  signal div_i      : integer range 0 to 95 := 0;               -- current dividend bit

  -- DEBUG tap registers (last-head values); drive dbg_sc/dbg_sum/dbg_num ports.
  signal dsc_r  : integer := 0;
  signal dsum_r : integer := 0;
  signal dnum_r : integer := 0;

  -- FSM: the position loops of S_SETUP/S_HEAD/S_WSUM are multi-cycle sub-states
  -- iterating one position per clock (S_VREF, S_SCORE, S_SPACK, S_WACC), each
  -- with a 1-cycle BRAM read-ahead bubble (consume position t_idx-1).
  type state_t is (S_IDLE, S_SETUP, S_VREF, S_HEAD, S_SCORE, S_SCORE_B, S_SPACK,
                   S_SMWAIT, S_WSUM, S_WACC, S_WDIV, S_DIV_ITER, S_DIV_FIN,
                   S_PACK, S_PACK_EMIT);
  signal state : state_t := S_IDLE;

  component softmax is
    generic(NMAX : positive; Q : integer := 12);
    port(
      clk        : in  std_logic;
      rst        : in  std_logic;
      start      : in  std_logic;
      n          : in  integer;
      score_mant : in  std_logic_vector(NMAX*16-1 downto 0);
      score_exp  : in  integer;
      done       : out std_logic;
      prob_q     : out std_logic_vector(NMAX*32-1 downto 0);
      e_out      : out std_logic_vector(NMAX*32-1 downto 0);
      sum_out    : out std_logic_vector(63 downto 0)
    );
  end component;

  -- Highest set-bit index of a nonnegative signed value (0 for 0).
  function msb_pos64(v : signed) return integer is
    variable p : integer := 0;
  begin
    for i in 0 to v'length-2 loop
      if v(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;

  -- BFP shift g for a nonnegative max-abs (mirrors fx_bfp_from_float).
  function bfp_g(maxabs : signed) return integer is
    variable p : integer;
    variable g : integer;
    variable r : signed(63 downto 0);
    variable b : signed(63 downto 0);
    variable m : signed(63 downto 0);
  begin
    if maxabs = 0 then return 0; end if;
    m := resize(maxabs, 64);
    p := msb_pos64(m);
    g := 14 - p;
    if g >= 0 then
      r := shift_left(m, g);
    else
      b := shift_left(to_signed(1, 64), (-g) - 1);
      r := shift_right(m + b, -g);
    end if;
    if r > to_signed(32767, 64) then g := g - 1; end if;
    return g;
  end function;

  -- round(v * 2^g) saturated to int16.
  function pack1(v : signed; g : integer) return integer is
    variable r : signed(63 downto 0);
    variable b : signed(63 downto 0);
    variable m : signed(63 downto 0);
  begin
    m := resize(v, 64);
    if g >= 0 then
      r := shift_left(m, g);
    else
      b := shift_left(to_signed(1, 64), (-g) - 1);
      r := shift_right(m + b, -g);
    end if;
    if    r >  to_signed(32767, 64)  then return 32767;
    elsif r < to_signed(-32768, 64)  then return -32768;
    else                                  return to_integer(r);
    end if;
  end function;

begin
  -- ---- KV cache BRAMs (one KVDIM-wide word per (layer,pos)) --------------
  -- Read address is COMBINATIONAL from the read-ahead pointer t_idx (clamped so
  -- the trailing bubble read at t_idx=cp+1 stays in range); write address/enable
  -- are combinational off the ports so the S_IDLE write commits while the
  -- current-position K/V/exp inputs are still valid (start='1').
  fetch_pos <= t_idx when t_idx <= MAXPOS-1 else MAXPOS-1;
  dbg_sc  <= dsc_r;
  dbg_sum <= dsum_r;
  dbg_num <= dnum_r;
  kv_raddr  <= std_logic_vector(to_unsigned(lyr*MAXPOS + fetch_pos, KVADDR_W));
  kv_waddr  <= std_logic_vector(to_unsigned(layer*MAXPOS + cur_pos, KVADDR_W));
  kv_we     <= '1' when (state = S_IDLE and start = '1') else '0';
  kc_e_di   <= std_logic_vector(to_signed(k_new_exp, 32));
  vc_e_di   <= std_logic_vector(to_signed(v_new_exp, 32));

  u_kc_v : kv_mem generic map(WORDS => KVWORDS, W => KVW)
    port map(clk => clk, we => kv_we, waddr => kv_waddr, raddr => kv_raddr,
             din => k_new_mant, dout => kc_v_do);
  u_vc_v : kv_mem generic map(WORDS => KVWORDS, W => KVW)
    port map(clk => clk, we => kv_we, waddr => kv_waddr, raddr => kv_raddr,
             din => v_new_mant, dout => vc_v_do);
  u_kc_e : kv_mem generic map(WORDS => KVWORDS, W => 32)
    port map(clk => clk, we => kv_we, waddr => kv_waddr, raddr => kv_raddr,
             din => kc_e_di, dout => kc_e_do);
  u_vc_e : kv_mem generic map(WORDS => KVWORDS, W => 32)
    port map(clk => clk, we => kv_we, waddr => kv_waddr, raddr => kv_raddr,
             din => vc_e_di, dout => vc_e_do);

  -- Shared softmax datapath (BFP scores in, Q12 probs out).
  u_softmax: softmax
    generic map(NMAX => MAXPOS, Q => Q)
    port map(
      clk        => clk,
      rst        => rst,
      start      => sm_start,
      n          => sm_n,
      score_mant => sm_score_mant,
      score_exp  => sm_score_exp,
      done       => sm_done,
      prob_q     => sm_prob_q,
      e_out      => sm_e_out,
      sum_out    => sm_sum_out
    );

  -- Main FSM (compute identical to attention.vhd; cache in BRAM bank `lyr`).
  process(clk)
    -- q-head re-BFP
    variable qh       : integer;
    variable qmax     : integer;
    variable qextra   : integer;
    variable qe_head  : integer;
    variable qhead    : integer_vector(0 to HEAD_SIZE-1);
    -- k-head re-BFP
    variable khead    : integer_vector(0 to HEAD_SIZE-1);
    variable kmax     : integer;
    variable kextra   : integer;
    variable ke_head  : integer;
    variable av       : integer;
    variable kv_h     : integer;
    variable p        : integer;   -- position being CONSUMED this cycle (t_idx-1)
    -- dot / score
    variable dot      : signed(63 downto 0);
    variable pr       : signed(63 downto 0);
    variable prod     : signed(95 downto 0);
    variable bias96   : signed(95 downto 0);
    variable tsh      : integer;
    variable sc64     : signed(63 downto 0);   -- this position's raw score
    variable g        : integer;
    -- weighted sum
    variable term     : signed(63 downto 0);
    variable bias64   : signed(63 downto 0);
    variable sh       : integer;
    variable ei       : integer;
    variable vval     : integer;
    variable num96    : signed(95 downto 0);
    variable qd96     : signed(95 downto 0);
    variable rem_sh   : unsigned(63 downto 0);   -- (div_rem << 1) | next dividend bit
    variable dbg_acc  : integer;                  -- debug checksum accumulator
    variable amax     : signed(63 downto 0);
    variable gx       : integer;
  begin
    if rising_edge(clk) then
      done     <= '0';
      sm_start <= '0';
      if rst = '1' then
        state    <= S_IDLE;
        xb_mant  <= (others => '0');
        xb_exp   <= 0;
        t_idx    <= 0;
        -- NOTE: the KV BRAM banks are NOT cleared (BRAM can't mass-reset).
        -- Write-before-read holds: every position read (0..cur_pos) is written
        -- earlier this run, so stale contents are never observed.
      else
        case state is
          -- ------------------------------------------------------------
          when S_IDLE =>
            if start = '1' then
              cp      <= cur_pos;
              lyr     <= layer;
              qmant_l <= q_mant;
              qexp_l  <= q_exp;
              -- current K/V + block exps are written into bank[layer] at slot
              -- cur_pos by the combinational kv_we/kv_waddr, committing on this
              -- edge while the inputs are still valid.
              state <= S_SETUP;
            end if;

          -- ------------------------------------------------------------
          -- Prime the V-exp read-ahead scan for vref = min vc_e over 0..cp.
          when S_SETUP =>
            t_idx <= 0;
            state <= S_VREF;

          -- One position per cycle (read-ahead): at t_idx>=1 the data for
          -- position p=t_idx-1 is on vc_e_do; min-fold it into vref_s.
          when S_VREF =>
            if t_idx >= 1 then
              p := t_idx - 1;
              if p = 0 then
                vref_s <= to_integer(signed(vc_e_do));
              elsif to_integer(signed(vc_e_do)) < vref_s then
                vref_s <= to_integer(signed(vc_e_do));
              end if;
            end if;
            if t_idx = cp + 1 then
              hd    <= 0;
              state <= S_HEAD;
            else
              t_idx <= t_idx + 1;
            end if;

          -- ------------------------------------------------------------
          -- Per-head setup: q-head re-BFP (once, HEAD_SIZE-wide combinational),
          -- then prime the position-sequential score pass (read-ahead from 0).
          when S_HEAD =>
            qmax := 0;
            for j in 0 to HEAD_SIZE-1 loop
              qh := to_integer(signed(
                      qmant_l((hd*HEAD_SIZE+j+1)*16-1 downto (hd*HEAD_SIZE+j)*16)));
              qhead(j) := qh;
              av := qh; if av < 0 then av := -av; end if;
              if av > qmax then qmax := av; end if;
            end loop;
            if qmax = 0 then qextra := 0; else qextra := 14 - msb_pos(qmax); end if;
            qe_head := qexp_l + qextra;
            for j in 0 to HEAD_SIZE-1 loop
              if qextra >= 0 then qhead(j) := qhead(j) * (2**qextra);
              else                qhead(j) := qhead(j) / (2**(-qextra)); end if;
              qhead_s(j) <= qhead(j);     -- persist for the sequential score pass
            end loop;
            qe_head_s     <= qe_head;
            smax_s        <= (others => '0');
            sm_score_mant <= (others => '0');
            t_idx         <= 0;
            state         <= S_SCORE;

          -- (b) read-ahead over cached positions: at t_idx>=1 the whole K word
          -- for position p=t_idx-1 is on kc_v_do (block exp on kc_e_do); q.k dot
          -- -> raw score sfx_s(p), tracking the running |score| max for the BFP
          -- pack.  The HEAD_SIZE-wide inner dot stays combinational (small).
          when S_SCORE =>
            kv_h := hd / KV_MUL;
            if t_idx >= 1 then
              p := t_idx - 1;
              -- k-head re-BFP for this position (slice the KVDIM-wide word)
              kmax := 0;
              for j in 0 to HEAD_SIZE-1 loop
                khead(j) := to_integer(signed(
                  kc_v_do(((kv_h*HEAD_SIZE+j)+1)*16-1 downto (kv_h*HEAD_SIZE+j)*16)));
                av := khead(j); if av < 0 then av := -av; end if;
                if av > kmax then kmax := av; end if;
              end loop;
              if kmax = 0 then kextra := 0; else kextra := 14 - msb_pos(kmax); end if;
              ke_head := to_integer(signed(kc_e_do)) + kextra;
              -- DEBUG (head0, pos0): ke_head (score shift) + raw K-exp cache read.
              if hd = 0 and t_idx = 1 then
                dsc_r  <= ke_head;
                dsum_r <= to_integer(signed(kc_e_do));
              end if;
              for j in 0 to HEAD_SIZE-1 loop
                if kextra >= 0 then khead(j) := khead(j) * (2**kextra);
                else                khead(j) := khead(j) / (2**(-kextra)); end if;
              end loop;
              -- integer dot Q.K (int64) using the persisted re-BFP'd q head.
              -- Registered here; the dot*INV_SQRT8 scaling is done in S_SCORE_B so
              -- the two multiply LEVELS (q*k then dot*scale) are NOT a cascaded-DSP
              -- combinational cone (the timing tool under-counts those -> wrong/
              -- non-deterministic on HW; same fix as rmsnorm's rsqrt/S_RAW).
              dot := (others => '0');
              for j in 0 to HEAD_SIZE-1 loop
                pr  := to_signed(qhead_s(j), 32) * to_signed(khead(j), 32);
                dot := dot + pr;
              end loop;
              state <= S_SCORE_B;            -- ke_head, dot, p persist
            else
              if t_idx = cp + 1 then t_idx <= 0; state <= S_SPACK;
              else t_idx <= t_idx + 1; end if;
            end if;

          -- Scale + BFP-pack the score for position p (2nd multiply level).
          when S_SCORE_B =>
            prod := dot * to_signed(INV_SQRT8_Q15, 32);
            tsh  := 15 + ke_head;
            if tsh > 0 then
              bias96 := shift_left(to_signed(1, 96), tsh - 1);
              sc64   := resize(shift_right(prod + bias96, tsh), 64);
            elsif tsh = 0 then
              sc64   := resize(prod, 64);
            else
              sc64   := resize(shift_left(prod, -tsh), 64);
            end if;
            sfx_s(p) <= sc64;
            if sc64 >= 0 then
              if sc64 > smax_s then smax_s <= sc64; end if;
            else
              if -sc64 > smax_s then smax_s <= -sc64; end if;
            end if;
            if t_idx = cp + 1 then
              t_idx <= 0;
              state <= S_SPACK;
            else
              t_idx <= t_idx + 1;
              state <= S_SCORE;
            end if;

          -- (c) one position per cycle: BFP-pack sfx_s(t) with the now-final
          -- shift g -> score_mant; on the last, kick softmax (exp = qe_head+g).
          when S_SPACK =>
            g := bfp_g(smax_s);
            -- DEBUG: raw score for pos 0 (head0), the softmax input -> dnum_r.
            if hd = 0 and t_idx = 0 then dnum_r <= to_integer(resize(sfx_s(0), 32)); end if;
            sm_score_mant((t_idx+1)*16-1 downto t_idx*16) <=
              std_logic_vector(to_signed(pack1(sfx_s(t_idx), g), 16));
            if t_idx = cp then
              sm_score_exp <= qe_head_s + g;
              sm_n         <= cp + 1;
              sm_start     <= '1';        -- kick softmax (score signals settled)
              state        <= S_SMWAIT;
            else
              t_idx <= t_idx + 1;
            end if;

          -- ------------------------------------------------------------
          when S_SMWAIT =>
            if sm_done = '1' then
              e_l    <= sm_e_out;
              sum_l  <= signed(sm_sum_out);
              state  <= S_WSUM;
            end if;

          -- ------------------------------------------------------------
          -- V-weighted sum: zero the HEAD_SIZE lane accumulators, then prime
          -- the read-ahead scan.
          when S_WSUM =>
            for j in 0 to HEAD_SIZE-1 loop
              num_s(j) <= (others => '0');
            end loop;
            t_idx <= 0;
            state <= S_WACC;

          -- Read-ahead: at t_idx>=1 the whole V word for position p=t_idx-1 is
          -- on vc_v_do (block exp on vc_e_do); accumulate prob(p)*V(p) into all
          -- HEAD_SIZE lanes (the HEAD_SIZE-wide inner loop stays combinational).
          when S_WACC =>
            kv_h := hd / KV_MUL;
            if t_idx >= 1 then
              p    := t_idx - 1;
              ei   := to_integer(signed(e_l((p+1)*32-1 downto p*32)));
              sh   := to_integer(signed(vc_e_do)) - vref_s;   -- >= 0 by construction
              for j in 0 to HEAD_SIZE-1 loop
                vval := to_integer(signed(
                  vc_v_do(((kv_h*HEAD_SIZE+j)+1)*16-1 downto (kv_h*HEAD_SIZE+j)*16)));
                term := to_signed(ei, 32) * to_signed(vval, 32);
                if sh > 0 then
                  bias64 := shift_left(to_signed(1, 64), sh - 1);
                  term   := shift_right(term + bias64, sh);
                end if;
                num_s(j) <= num_s(j) + term;
                -- (V-cache value tap removed; taps now on ke_head/kc_e_do/score.)
              end loop;
            end if;
            if t_idx = cp + 1 then
              t_idx <= 0;               -- prime the per-lane S_WDIV counter
              state <= S_WDIV;
            else
              t_idx <= t_idx + 1;
            end if;

          -- Per-head finalise, one LANE per cycle (t_idx = lane 0..HEAD_SIZE-1):
          -- acc[j] = round(num*2^WQ / sum).  The divide is iterative (S_DIV_ITER):
          -- S_WDIV LOADS the biased dividend + sign, then 96 shift-subtract cycles,
          -- then S_DIV_FIN writes xb_acc and advances the lane/head.
          -- Per-head finalise, one LANE per cycle: acc[j] = round(num*2^WQ / sum).
          -- COMBINATIONAL divide (VHDL '/', a standard signed-divide macro that
          -- synthesises deterministically + bit-exact).  The iterative shift-divider
          -- was deterministic but WRONG on HW (score/sum/num_s all matched sim, only
          -- the divide output diverged); '/' at 3 MHz meets timing with huge margin.
          when S_WDIV =>
            -- DEBUG: expose num_s(0) directly (head 0 lane 0 = attOut element 0's
            -- numerator) to localize the deterministic error per-lane.
            -- (num_s tap removed; dnum_r now carries the raw score from S_SPACK.)
            num96 := shift_left(resize(num_s(t_idx), 96), WQ);
            if num96 >= 0 then num96 := num96 + resize(shift_right(sum_l, 1), 96);
            else               num96 := num96 - resize(shift_right(sum_l, 1), 96);
            end if;
            -- 64-bit divide (num96 < 2^48 always: num_s <= sum_l*2^15 <= ~3.2e9,
            -- <<WQ=16 -> ~2^48).  Bit-exact with the 96-bit divide but ~1/3 the
            -- CARRY -> cuts the u_att routing congestion the wide divide caused.
            xb_acc(hd*HEAD_SIZE + t_idx) <=
              resize(resize(num96, 64) / resize(sum_l, 64), 64);
            if t_idx = HEAD_SIZE-1 then
              t_idx <= 0;
              if hd = NHEADS-1 then
                amax_s <= (others => '0');   -- prime the S_PACK max scan
                state  <= S_PACK;
              else
                hd    <= hd + 1;
                state <= S_HEAD;
              end if;
            else
              t_idx <= t_idx + 1;            -- next lane, stay in S_WDIV
            end if;

          -- (iterative-divider states retained in the enum but never entered)
          when S_DIV_ITER => state <= S_PACK;
          when S_DIV_FIN  => state <= S_PACK;

          -- ------------------------------------------------------------
          -- BFP-pack acc vector (value = acc*2^-(Q+vref)) -> xb_mant/xb_exp.
          -- Max-abs scan: ONE element per cycle (t_idx = 0..DIM-1).
          when S_PACK =>
            if xb_acc(t_idx) >= 0 then
              if xb_acc(t_idx) > amax_s then amax_s <= xb_acc(t_idx); end if;
            else
              if -xb_acc(t_idx) > amax_s then amax_s <= -xb_acc(t_idx); end if;
            end if;
            if t_idx = DIM-1 then
              t_idx <= 0;
              state <= S_PACK_EMIT;
            else
              t_idx <= t_idx + 1;
            end if;

          -- Emit: pack ONE element per cycle with the now-final shift gx.
          when S_PACK_EMIT =>
            gx := bfp_g(amax_s);
            xb_mant((t_idx+1)*16-1 downto t_idx*16) <=
              std_logic_vector(to_signed(pack1(xb_acc(t_idx), gx), 16));
            xb_exp <= (vref_s + WQ) + gx;
            if t_idx = DIM-1 then
              done  <= '1';
              state <= S_IDLE;
            else
              t_idx <= t_idx + 1;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture rtl;
