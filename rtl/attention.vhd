-- rtl/attention.vhd
-- Synthesizable INTEGER multi-head attention with an on-chip KV cache.
--
-- Re-implements, in pure integer arithmetic, the float "glue" of
-- layer.vhd:559-705 (scores / softmax / V-weighted sum) and the oracle
-- forward_fx attention (ref/run_fx.c ~946-990).  No `real`, no TEXTIO.
--
-- GEOMETRY (defaults): DIM=64, HEAD_SIZE=8, NHEADS=8, NKVH=4, KVDIM=32,
--   kv_mul = NHEADS/NKVH = 2.  head h reads kv head (h/kv_mul).
--
-- DATA FLOW (one `start` = one decode position):
--   1. WRITE the current position's K (post-rope) and V (pre-rope) into the
--      internal cache at slot cur_pos.  History (slots 0..cur_pos-1) was left
--      by earlier `start` calls (call the block once per position, in order).
--   2. For each head h:
--        a. Re-BFP the q-head slice to fill int16 (max-normalise, exp bookkeep).
--        b. For each cached t in 0..cur_pos: re-BFP the k-head slice, integer
--           dot Q.K (int64), then
--             score_fixed(t) = round( dot * INV_SQRT8_Q15 * 2^(-ke_head) >> 15 )
--           so score_fixed(t) ~= dot(t) * 2^(-ke_head(t)) / sqrt(HEAD_SIZE),
--           dropping ONLY the per-head 2^(-qe_head) common factor (folded into
--           the block exponent -- softmax is shift-invariant but NOT scale-
--           invariant, so this common factor must survive in the exponent).
--        c. BFP-pack score_fixed over t (msb_pos rule, same as matmul.vhd) ->
--           score_mant + pack shift g;  score_exp = qe_head + g.
--        d. softmax.vhd (BFP scores in -> Q12 probs out).
--        e. V-weighted sum (integerised layer.vhd:654-663):
--             acc[j] = sum_t round( prob_q(t)*v(t,j) >> (vc_e(t)-vref) )
--           with vref = min_t vc_e(t) (>=0 shifts); value = acc[j]*2^-(Q+vref).
--   3. BFP-pack the DIM-length acc vector -> xb_mant, xb_exp = (Q+vref)+gx.
--
-- EXPONENT BOOKKEEPING (verified against the goldens):
--   * scores : score(t) = score_mant(t) * 2^-(qe_head + g),  g = 14-msb(smax).
--   * weighted sum : xb[j] = xb_mant[j] * 2^-((Q+vref) + gx),  gx = 14-msb(amax).
--
-- Debug ports expose head-0 scores/probs and a selectable cache slot so the
-- testbench can grade against fx_softmax_l0_h0 / fx_layer0_kv / fx_att_out_l0.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;   -- msb_pos, clog2 (msb_pos64 defined locally for signed)

entity attention is
  generic(
    DIM       : positive := 64;
    HEAD_SIZE : positive := 8;
    NHEADS    : positive := 8;
    NKVH      : positive := 4;
    KVDIM     : positive := 32;   -- = NKVH*HEAD_SIZE
    MAXPOS    : positive := 8;    -- static cache depth (>= cur_pos+1)
    Q         : integer  := 12    -- softmax Q-format (probs = prob_q / 2^Q)
  );
  port(
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
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
    -- debug: head-0 pre-softmax scores + post-softmax probs
    dbg_score_mant : out std_logic_vector(MAXPOS*16-1 downto 0);
    dbg_score_exp  : out integer;
    dbg_prob_q     : out std_logic_vector(MAXPOS*32-1 downto 0);
    -- debug: selectable cache slot read-back
    dbg_slot   : in  integer;
    dbg_k_mant : out std_logic_vector(KVDIM*16-1 downto 0);
    dbg_k_exp  : out integer;
    dbg_v_mant : out std_logic_vector(KVDIM*16-1 downto 0);
    dbg_v_exp  : out integer
  );
end entity attention;

architecture rtl of attention is
  constant KV_MUL : integer := NHEADS / NKVH;
  -- round(2^15 / sqrt(8)) = 11585  (1/sqrt(HEAD_SIZE), HEAD_SIZE=8)
  constant INV_SQRT8_Q15 : integer := 11585;

  -- ---- cache -------------------------------------------------------------
  type i16_cache is array(0 to MAXPOS*KVDIM-1) of integer range -32768 to 32767;
  signal kc_v : i16_cache := (others => 0);
  signal vc_v : i16_cache := (others => 0);
  type iexp_arr is array(0 to MAXPOS-1) of integer;
  signal kc_e : iexp_arr := (others => 0);
  signal vc_e : iexp_arr := (others => 0);

  -- ---- per-element attention accumulators (value = acc * 2^-(Q+vref)) -----
  type acc_arr is array(0 to DIM-1) of signed(63 downto 0);
  signal xb_acc : acc_arr := (others => (others => '0'));

  -- ---- latches / bookkeeping --------------------------------------------
  signal cp      : integer := 0;   -- latched cur_pos
  signal hd      : integer := 0;   -- current head
  signal vref_s  : integer := 0;   -- min vc_e over 0..cp
  signal qmant_l : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal qexp_l  : integer := 0;

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

  -- Weighted-sum fixed-point headroom: xb[j] ~= (Sum e_i*v_i * 2^-shift)
  -- * 2^WQ / sum, giving a value at exponent (vref + WQ).  WQ=16 keeps the
  -- per-prob quantisation floor at ~2^-16 (vs prob_q's coarse 2^-Q).
  constant WQ : integer := 16;

  type state_t is (S_IDLE, S_SETUP, S_HEAD, S_SMWAIT, S_WSUM, S_PACK);
  signal state : state_t := S_IDLE;

  -- Component (not direct entity) so this unit analyses before softmax.vhd
  -- regardless of the file-analysis order in sim/Makefile.
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

  -- BFP shift g for a nonnegative max-abs: g = 14 - msb, adjusted down by one
  -- if round(maxabs*2^g) would exceed 32767 (mirrors fx_bfp_from_float).
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

  -- round(v * 2^g) saturated to int16 (round half toward +inf on right shift).
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
  -- --------------------------------------------------------------------
  -- Shared softmax datapath (BFP scores in, Q12 probs out).
  -- --------------------------------------------------------------------
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

  -- --------------------------------------------------------------------
  -- Debug cache read-back (combinational).
  -- --------------------------------------------------------------------
  dbg_rd: process(all)
    variable base : integer;
  begin
    base := dbg_slot * KVDIM;
    for j in 0 to KVDIM-1 loop
      dbg_k_mant((j+1)*16-1 downto j*16) <=
        std_logic_vector(to_signed(kc_v(base + j), 16));
      dbg_v_mant((j+1)*16-1 downto j*16) <=
        std_logic_vector(to_signed(vc_v(base + j), 16));
    end loop;
    dbg_k_exp <= kc_e(dbg_slot);
    dbg_v_exp <= vc_e(dbg_slot);
  end process;

  -- --------------------------------------------------------------------
  -- Main FSM.
  -- --------------------------------------------------------------------
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
    -- dot / score
    variable dot      : signed(63 downto 0);
    variable pr       : signed(63 downto 0);
    variable prod     : signed(95 downto 0);
    variable bias96   : signed(95 downto 0);
    variable tsh      : integer;
    type sfx_arr is array(0 to MAXPOS-1) of signed(63 downto 0);
    variable sfx      : sfx_arr;
    variable smax     : signed(63 downto 0);
    variable g        : integer;
    -- weighted sum (full-precision numerator/sum, mirrors the oracle's
    -- float att[t]=e_i/sum ratio: num[j]=Sum_t e_i*v_ij>>shift ; then
    -- acc[j]=round(num[j]*2^WQ / sum), value = xb[j]*2^(vref+WQ))
    variable num      : signed(63 downto 0);
    variable term     : signed(63 downto 0);
    variable bias64   : signed(63 downto 0);
    variable sh       : integer;
    variable ei       : integer;
    variable vval     : integer;
    variable num96    : signed(95 downto 0);
    variable qd96     : signed(95 downto 0);
    variable amax     : signed(63 downto 0);
    variable gx       : integer;
    variable vr       : integer;
  begin
    if rising_edge(clk) then
      done     <= '0';
      sm_start <= '0';
      if rst = '1' then
        state    <= S_IDLE;
        xb_mant  <= (others => '0');
        xb_exp   <= 0;
      else
        case state is
          -- ------------------------------------------------------------
          when S_IDLE =>
            if start = '1' then
              cp      <= cur_pos;
              qmant_l <= q_mant;
              qexp_l  <= q_exp;
              -- write current K/V into the cache at slot cur_pos
              for j in 0 to KVDIM-1 loop
                kc_v(cur_pos*KVDIM + j) <=
                  to_integer(signed(k_new_mant((j+1)*16-1 downto j*16)));
                vc_v(cur_pos*KVDIM + j) <=
                  to_integer(signed(v_new_mant((j+1)*16-1 downto j*16)));
              end loop;
              kc_e(cur_pos) <= k_new_exp;
              vc_e(cur_pos) <= v_new_exp;
              state <= S_SETUP;
            end if;

          -- ------------------------------------------------------------
          when S_SETUP =>
            -- vref = min vc_e over 0..cp (cache now includes cur_pos slot)
            vr := vc_e(0);
            for t in 1 to MAXPOS-1 loop
              if t <= cp then
                if vc_e(t) < vr then vr := vc_e(t); end if;
              end if;
            end loop;
            vref_s <= vr;
            hd     <= 0;
            state  <= S_HEAD;

          -- ------------------------------------------------------------
          when S_HEAD =>
            kv_h := hd / KV_MUL;

            -- (a) q-head re-BFP to fill int16
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
            end loop;

            -- (b) scores per cached position
            for t in 0 to MAXPOS-1 loop
              sfx(t) := (others => '0');
              if t <= cp then
                kmax := 0;
                for j in 0 to HEAD_SIZE-1 loop
                  khead(j) := kc_v(t*KVDIM + kv_h*HEAD_SIZE + j);
                  av := khead(j); if av < 0 then av := -av; end if;
                  if av > kmax then kmax := av; end if;
                end loop;
                if kmax = 0 then kextra := 0; else kextra := 14 - msb_pos(kmax); end if;
                ke_head := kc_e(t) + kextra;
                for j in 0 to HEAD_SIZE-1 loop
                  if kextra >= 0 then khead(j) := khead(j) * (2**kextra);
                  else                khead(j) := khead(j) / (2**(-kextra)); end if;
                end loop;
                -- integer dot Q.K (int64)
                dot := (others => '0');
                for j in 0 to HEAD_SIZE-1 loop
                  pr  := to_signed(qhead(j), 32) * to_signed(khead(j), 32);
                  dot := dot + pr;
                end loop;
                -- score_fixed = round( dot * 11585 * 2^-ke_head / 2^15 )
                prod := dot * to_signed(INV_SQRT8_Q15, 32);
                tsh  := 15 + ke_head;
                if tsh > 0 then
                  bias96 := shift_left(to_signed(1, 96), tsh - 1);
                  sfx(t) := resize(shift_right(prod + bias96, tsh), 64);
                elsif tsh = 0 then
                  sfx(t) := resize(prod, 64);
                else
                  sfx(t) := resize(shift_left(prod, -tsh), 64);
                end if;
              end if;
            end loop;

            -- (c) BFP-pack scores over t -> score_mant + g;  exp = qe_head + g
            smax := (others => '0');
            for t in 0 to MAXPOS-1 loop
              if t <= cp then
                if sfx(t) >= 0 then
                  if sfx(t) > smax then smax := sfx(t); end if;
                else
                  if -sfx(t) > smax then smax := -sfx(t); end if;
                end if;
              end if;
            end loop;
            g := bfp_g(smax);
            sm_score_mant <= (others => '0');
            for t in 0 to MAXPOS-1 loop
              if t <= cp then
                sm_score_mant((t+1)*16-1 downto t*16) <=
                  std_logic_vector(to_signed(pack1(sfx(t), g), 16));
              end if;
            end loop;
            sm_score_exp <= qe_head + g;
            sm_n         <= cp + 1;

            if hd = 0 then
              dbg_score_exp <= qe_head + g;
              for t in 0 to MAXPOS-1 loop
                if t <= cp then
                  dbg_score_mant((t+1)*16-1 downto t*16) <=
                    std_logic_vector(to_signed(pack1(sfx(t), g), 16));
                else
                  dbg_score_mant((t+1)*16-1 downto t*16) <= (others => '0');
                end if;
              end loop;
            end if;

            sm_start <= '1';       -- kick softmax (score signals settle same edge)
            state    <= S_SMWAIT;

          -- ------------------------------------------------------------
          when S_SMWAIT =>
            if sm_done = '1' then
              e_l    <= sm_e_out;
              sum_l  <= signed(sm_sum_out);
              if hd = 0 then dbg_prob_q <= sm_prob_q; end if;
              state  <= S_WSUM;
            end if;

          -- ------------------------------------------------------------
          when S_WSUM =>
            kv_h := hd / KV_MUL;
            for j in 0 to HEAD_SIZE-1 loop
              num := (others => '0');
              for t in 0 to MAXPOS-1 loop
                if t <= cp then
                  ei   := to_integer(signed(e_l((t+1)*32-1 downto t*32)));
                  vval := vc_v(t*KVDIM + kv_h*HEAD_SIZE + j);
                  term := to_signed(ei, 32) * to_signed(vval, 32);
                  sh   := vc_e(t) - vref_s;   -- >= 0 by construction
                  if sh > 0 then
                    bias64 := shift_left(to_signed(1, 64), sh - 1);
                    term   := shift_right(term + bias64, sh);
                  end if;
                  num := num + term;
                end if;
              end loop;
              -- acc[j] = round(num * 2^WQ / sum)  (round-to-nearest divide)
              num96 := shift_left(resize(num, 96), WQ);
              if num96 >= 0 then num96 := num96 + resize(shift_right(sum_l, 1), 96);
              else               num96 := num96 - resize(shift_right(sum_l, 1), 96);
              end if;
              qd96 := num96 / resize(sum_l, 96);
              xb_acc(hd*HEAD_SIZE + j) <= resize(qd96, 64);
            end loop;
            if hd = NHEADS-1 then
              state <= S_PACK;
            else
              hd    <= hd + 1;
              state <= S_HEAD;
            end if;

          -- ------------------------------------------------------------
          when S_PACK =>
            -- BFP-pack acc vector (value = acc*2^-(Q+vref)) -> xb_mant/xb_exp
            amax := (others => '0');
            for j in 0 to DIM-1 loop
              if xb_acc(j) >= 0 then
                if xb_acc(j) > amax then amax := xb_acc(j); end if;
              else
                if -xb_acc(j) > amax then amax := -xb_acc(j); end if;
              end if;
            end loop;
            gx := bfp_g(amax);
            for j in 0 to DIM-1 loop
              xb_mant((j+1)*16-1 downto j*16) <=
                std_logic_vector(to_signed(pack1(xb_acc(j), gx), 16));
            end loop;
            xb_exp <= (vref_s + WQ) + gx;
            done   <= '1';
            state  <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture rtl;
