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
--   write/read slot  = layer*MAXPOS*KVDIM + pos*KVDIM + j   (K,V mantissas)
--   per-slot exp     = layer*MAXPOS       + pos            (K,V block exps)
--
-- `rst` clears ALL banks (drives the engine's kv_reset at run start).  Debug
-- ports were dropped (unused by the engine); everything else is line-for-line
-- attention.vhd, so xb_mant/xb_exp are bit-identical for a given (layer) bank.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;   -- msb_pos

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
    xb_exp     : out integer
  );
end entity attention_ml;

architecture rtl of attention_ml is
  constant KV_MUL : integer := NHEADS / NKVH;
  -- round(2^15 / sqrt(8)) = 11585  (1/sqrt(HEAD_SIZE), HEAD_SIZE=8)
  constant INV_SQRT8_Q15 : integer := 11585;

  -- ---- banked cache (NLAYERS independent K/V histories) ------------------
  type i16_cache is array(0 to NLAYERS*MAXPOS*KVDIM-1) of integer range -32768 to 32767;
  signal kc_v : i16_cache := (others => 0);
  signal vc_v : i16_cache := (others => 0);
  type iexp_arr is array(0 to NLAYERS*MAXPOS-1) of integer;
  signal kc_e : iexp_arr := (others => 0);
  signal vc_e : iexp_arr := (others => 0);

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
  -- The per-position work (vref min, q.k scores, prob*V weighted sum) is
  -- time-multiplexed over ONE position per clock instead of the old MAXPOS-wide
  -- combinational unroll, so area is O(1) in MAXPOS (see FSM below).
  signal t_idx     : integer := 0;                 -- current position 0..cp
  signal smax_s    : signed(63 downto 0) := (others => '0'); -- running |score| max
  type sfx_sig_arr is array(0 to MAXPOS-1) of signed(63 downto 0);
  signal sfx_s     : sfx_sig_arr := (others => (others => '0')); -- per-pos raw scores
  signal qhead_s   : integer_vector(0 to HEAD_SIZE-1) := (others => 0); -- re-BFP q head
  signal qe_head_s : integer := 0;                 -- q head block exp
  type num_arr is array(0 to HEAD_SIZE-1) of signed(63 downto 0);
  signal num_s     : num_arr := (others => (others => '0'));  -- per-j V-weighted sums

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

  -- FSM: the position loops of S_SETUP/S_HEAD/S_WSUM are now multi-cycle sub-
  -- states iterating one position t per clock (S_VREF, S_SCORE, S_SPACK, S_WACC),
  -- preserving the per-HEAD outer sequencing.
  type state_t is (S_IDLE, S_SETUP, S_VREF, S_HEAD, S_SCORE, S_SPACK,
                   S_SMWAIT, S_WSUM, S_WACC, S_WDIV, S_PACK);
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

  -- Main FSM (compute identical to attention.vhd; cache indexed by bank `lyr`).
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
    variable kbase    : integer;   -- bank base for K/V mantissas
    variable ebase    : integer;   -- bank base for K/V block exps
    -- dot / score
    variable dot      : signed(63 downto 0);
    variable pr       : signed(63 downto 0);
    variable prod     : signed(95 downto 0);
    variable bias96   : signed(95 downto 0);
    variable tsh      : integer;
    variable sc64     : signed(63 downto 0);   -- this position's raw score
    variable g        : integer;
    -- weighted sum
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
  begin
    if rising_edge(clk) then
      done     <= '0';
      sm_start <= '0';
      if rst = '1' then
        state    <= S_IDLE;
        xb_mant  <= (others => '0');
        xb_exp   <= 0;
        -- Clear ALL persistent KV banks (engine's kv_reset routes here).
        kc_v <= (others => 0);
        vc_v <= (others => 0);
        kc_e <= (others => 0);
        vc_e <= (others => 0);
      else
        case state is
          -- ------------------------------------------------------------
          when S_IDLE =>
            if start = '1' then
              cp      <= cur_pos;
              lyr     <= layer;
              qmant_l <= q_mant;
              qexp_l  <= q_exp;
              -- write current K/V into bank[layer] at slot cur_pos
              for j in 0 to KVDIM-1 loop
                kc_v(layer*MAXPOS*KVDIM + cur_pos*KVDIM + j) <=
                  to_integer(signed(k_new_mant((j+1)*16-1 downto j*16)));
                vc_v(layer*MAXPOS*KVDIM + cur_pos*KVDIM + j) <=
                  to_integer(signed(v_new_mant((j+1)*16-1 downto j*16)));
              end loop;
              kc_e(layer*MAXPOS + cur_pos) <= k_new_exp;
              vc_e(layer*MAXPOS + cur_pos) <= v_new_exp;
              state <= S_SETUP;
            end if;

          -- ------------------------------------------------------------
          -- vref = min vc_e over 0..cp within this bank.  Sequentialised:
          -- seed with slot 0, then S_VREF folds one position per cycle.
          when S_SETUP =>
            ebase  := lyr*MAXPOS;
            vref_s <= vc_e(ebase + 0);
            if cp = 0 then
              hd    <= 0;
              state <= S_HEAD;
            else
              t_idx <= 1;
              state <= S_VREF;
            end if;

          -- One position per cycle: min-fold vc_e(t) into vref_s.
          when S_VREF =>
            ebase := lyr*MAXPOS;
            if vc_e(ebase + t_idx) < vref_s then
              vref_s <= vc_e(ebase + t_idx);
            end if;
            if t_idx = cp then
              hd    <= 0;
              state <= S_HEAD;
            else
              t_idx <= t_idx + 1;
            end if;

          -- ------------------------------------------------------------
          -- Per-head setup: q-head re-BFP (once, HEAD_SIZE-wide combinational),
          -- then launch the position-sequential score pass.
          when S_HEAD =>
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
              qhead_s(j) <= qhead(j);     -- persist for the sequential score pass
            end loop;
            qe_head_s     <= qe_head;
            smax_s        <= (others => '0');
            sm_score_mant <= (others => '0');
            t_idx         <= 0;
            state         <= S_SCORE;

          -- (b) one cached position per cycle: q.k dot -> raw score sfx_s(t),
          -- while tracking the running |score| max for the BFP pack.  The
          -- HEAD_SIZE-wide inner dot stays combinational (it is small).
          when S_SCORE =>
            kv_h  := hd / KV_MUL;
            kbase := lyr*MAXPOS*KVDIM;
            ebase := lyr*MAXPOS;
            -- k-head re-BFP for this position
            kmax := 0;
            for j in 0 to HEAD_SIZE-1 loop
              khead(j) := kc_v(kbase + t_idx*KVDIM + kv_h*HEAD_SIZE + j);
              av := khead(j); if av < 0 then av := -av; end if;
              if av > kmax then kmax := av; end if;
            end loop;
            if kmax = 0 then kextra := 0; else kextra := 14 - msb_pos(kmax); end if;
            ke_head := kc_e(ebase + t_idx) + kextra;
            for j in 0 to HEAD_SIZE-1 loop
              if kextra >= 0 then khead(j) := khead(j) * (2**kextra);
              else                khead(j) := khead(j) / (2**(-kextra)); end if;
            end loop;
            -- integer dot Q.K (int64) using the persisted re-BFP'd q head
            dot := (others => '0');
            for j in 0 to HEAD_SIZE-1 loop
              pr  := to_signed(qhead_s(j), 32) * to_signed(khead(j), 32);
              dot := dot + pr;
            end loop;
            -- score_fixed = round( dot * 11585 * 2^-ke_head / 2^15 )
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
            sfx_s(t_idx) <= sc64;
            -- running max|sfx| (feeds the common BFP shift g)
            if sc64 >= 0 then
              if sc64 > smax_s then smax_s <= sc64; end if;
            else
              if -sc64 > smax_s then smax_s <= -sc64; end if;
            end if;
            if t_idx = cp then
              t_idx <= 0;
              state <= S_SPACK;
            else
              t_idx <= t_idx + 1;
            end if;

          -- (c) one position per cycle: BFP-pack sfx_s(t) with the now-final
          -- shift g -> score_mant; on the last, kick softmax (exp = qe_head+g).
          when S_SPACK =>
            g := bfp_g(smax_s);
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
          -- V-weighted sum, position-sequential: zero the HEAD_SIZE lane
          -- accumulators, then S_WACC folds one position per cycle.
          when S_WSUM =>
            for j in 0 to HEAD_SIZE-1 loop
              num_s(j) <= (others => '0');
            end loop;
            t_idx <= 0;
            state <= S_WACC;

          -- One position per cycle: accumulate prob(t)*V(t) into all HEAD_SIZE
          -- lanes (the HEAD_SIZE-wide inner loop stays combinational).
          when S_WACC =>
            kv_h  := hd / KV_MUL;
            kbase := lyr*MAXPOS*KVDIM;
            ebase := lyr*MAXPOS;
            ei    := to_integer(signed(e_l((t_idx+1)*32-1 downto t_idx*32)));
            sh    := vc_e(ebase + t_idx) - vref_s;   -- >= 0 by construction
            for j in 0 to HEAD_SIZE-1 loop
              vval := vc_v(kbase + t_idx*KVDIM + kv_h*HEAD_SIZE + j);
              term := to_signed(ei, 32) * to_signed(vval, 32);
              if sh > 0 then
                bias64 := shift_left(to_signed(1, 64), sh - 1);
                term   := shift_right(term + bias64, sh);
              end if;
              num_s(j) <= num_s(j) + term;
            end loop;
            if t_idx = cp then
              state <= S_WDIV;
            else
              t_idx <= t_idx + 1;
            end if;

          -- Per-head finalise: acc[j] = round(num*2^WQ / sum) for each lane,
          -- then advance to the next head (or pack).
          when S_WDIV =>
            for j in 0 to HEAD_SIZE-1 loop
              num96 := shift_left(resize(num_s(j), 96), WQ);
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
