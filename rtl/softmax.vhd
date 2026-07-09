-- rtl/softmax.vhd
-- Softmax with integer exp (exp_q from fixed_pkg) and Q12 probability output.
-- Mirrors softmax_fx in ref/run_fx.c:
--   1. Convert BFP scores to Qq integers.
--   2. Find max over first n scores.
--   3. z_q[i] = score_q[i] - max_q  (always <= 0; required by exp_q).
--   4. e_i = exp_q(z_q[i], Q).
--   5. sum += e_i (int64).
--   6. prob_q[i] = (e_i << Q) / sum  (integer divide, Q12 probability).
--
-- Block-fp convention: score[j] = mant[j] * 2^(-score_exp).
-- Input: score_mant (16-bit mantissas), score_exp.
-- Output: prob_q (32-bit Q12 probabilities for the first n lanes).
--
-- AREA-EFFICIENT (element-SEQUENTIAL) implementation.
-- The prior version unrolled three `for i in 0 to NMAX-1` combinational loops
-- (BFP->Qq shift, exp_q + sum, and the normalise divide).  At NMAX=256 that
-- inferred 256 parallel exp_q LUT evaluators and 256 integer dividers
-- (~1.96M LUTs / 2772%, 227K CARRY8 / 2580%) -- the engine's fit blocker.
-- This FSM time-multiplexes ONE datapath over the elements, iterating the
-- RUNTIME `n` (n<=NMAX), so exactly ONE shared exp_q and ONE shared divider
-- are inferred (same element-sequential pattern as rmsnorm / attention_ml):
--   S_CONVMAX : convert score_mant[i] -> score_q[i] and fold running max_q,
--               one element per cycle.
--   S_EXP     : z_q=score_q[i]-max_q; e_i=exp_q(z_q,Q); store e_i; sum+=e_i,
--               one element per cycle (single exp_q instance).
--   S_NORM    : prob_q[i]=(e_i<<Q)/sum, one element per cycle (single divider).
-- Every width, shift, round and the integer divide are IDENTICAL to the
-- unrolled version, so prob_q / e_out / sum_out are BIT-EXACT.  Only timing
-- becomes multi-cycle; `done` pulses after the last element (consumers --
-- attention_ml S_SMWAIT, attention.vhd -- already wait on `done`).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_pkg.all;
use work.fixed_luts_pkg.all;   -- EXP_ROM for the pipelined exp

entity softmax is
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
    -- Additive outputs (do not affect prob_q): the raw integer exp weights
    -- e_i and their sum, so a consumer (attention.vhd) can form a
    -- full-precision weighted sum  Sum(e_i*v_i)/sum  instead of the coarser
    -- per-element Q-truncated prob_q.  Unconnected by tb_softmax.
    e_out      : out std_logic_vector(NMAX*32-1 downto 0);
    sum_out    : out std_logic_vector(63 downto 0)
  );
end entity softmax;

architecture rtl of softmax is
  type s32_arr is array(natural range <>) of signed(31 downto 0);
  -- exp is PIPELINED (S_EXP_A/B/C): the exp cone (257-entry EXP_ROM mux -> (hi-lo)
  -- -> *frac -> normalise shifts) was one deep combinational path whose DSP-multiply
  -- high bits the timing tool under-counts -> non-deterministic sum on HW (the sum
  -- swung ~5K vs ~369M = a high bit flipping).  One op-level per state, registered
  -- between.  e_i is STORED in e_arr (registers) so S_NORM does not re-run the cone.
  type state_t is (S_IDLE, S_CONVMAX, S_EXP_A, S_EXP_B, S_EXP_C, S_NORM);
  signal e_arr : s32_arr(0 to NMAX-1) := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of e_arr : signal is "registers";

  -- score_q[i] = round(mant[i] * 2^(Q - score_exp)) from a raw int16 mantissa.
  -- (round-half-up right shift for sh<0).  Recomputed on demand in both the
  -- max pass and the exp pass so score_q need not be stored (removes a
  -- NMAX*64-bit register file and its NMAX:1 read mux).
  function conv_q(raw : signed; sh : integer) return signed is
    variable sc_ext : signed(63 downto 0);
    variable bias   : signed(63 downto 0);
  begin
    sc_ext := resize(raw, 64);
    if sh >= 0 then
      return shift_left(sc_ext, sh);
    else
      bias := shift_left(to_signed(1, 64), (-sh) - 1);
      return shift_right(sc_ext + bias, -sh);
    end if;
  end function;
begin
  process(clk)
    -- Control
    variable state   : state_t := S_IDLE;
    variable idx     : integer range 0 to NMAX := 0;
    variable nreg    : integer := 0;
    variable sh      : integer := 0;
    -- Persistent exp-weight storage (registers).  e_i is small (<= exp(0) at
    -- Qq), so 32 bits is exact.
    -- Reduction accumulators (persist across cycles).
    variable max_q   : signed(63 downto 0);
    variable sum     : signed(63 downto 0);
    -- Per-cycle scratch.
    variable sc_raw  : signed(15 downto 0);
    variable sq_i    : signed(63 downto 0);
    variable z_q     : signed(63 downto 0);
    variable e_i     : signed(31 downto 0);
    variable num     : signed(63 downto 0);
    variable p_i     : signed(63 downto 0);
    -- Pipelined-exp registers (mirror fixed_pkg.exp_q, one op-level per state).
    variable ex_frac : signed(63 downto 0);
    variable ex_lo   : signed(63 downto 0);
    variable ex_hd   : signed(63 downto 0);   -- hi - lo
    variable ex_prod : signed(127 downto 0);
    variable ex_uf   : boolean;               -- underflow (z < -16<<q) -> exp=0
    variable ez      : signed(63 downto 0);
    variable eoff    : signed(63 downto 0);
    variable eidx    : signed(63 downto 0);
    variable ek      : integer;
    variable einterp : signed(63 downto 0);
    variable etmp    : signed(127 downto 0);
    variable er      : signed(63 downto 0);
    variable ebias   : signed(63 downto 0);
    variable esh     : integer;
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        state  := S_IDLE;
        idx    := 0;
        prob_q <= (others => '0');
      else
        case state is

          -- ----------------------------------------------------------------
          -- Wait for start; latch the BFP->Qq shift and n, clear the output
          -- tail (i>=n stays 0, matching the unrolled version), then convert.
          -- ----------------------------------------------------------------
          when S_IDLE =>
            if start = '1' then
              -- score_q[i] = round(mant[i] * 2^(Q - score_exp))
              sh     := Q - score_exp;
              nreg   := n;
              idx    := 0;
              prob_q <= (others => '0');
              e_out  <= (others => '0');
              state  := S_CONVMAX;
            end if;

          -- ----------------------------------------------------------------
          -- Steps 1+2: convert score_mant[idx] -> score_q[idx] (round-half-up
          -- right shift for sh<0) and fold the running max over 0..n-1.
          -- ----------------------------------------------------------------
          when S_CONVMAX =>
            sc_raw := signed(score_mant((idx+1)*16-1 downto idx*16));
            sq_i   := conv_q(sc_raw, sh);
            if idx = 0 then
              max_q := sq_i;
            elsif sq_i > max_q then
              max_q := sq_i;
            end if;
            if idx = nreg-1 then
              idx   := 0;
              sum   := (others => '0');
              state := S_EXP_A;
            else
              idx := idx + 1;
            end if;

          -- ----------------------------------------------------------------
          -- Steps 3+4+5: z_q = score_q[idx]-max_q (<=0); e_i = exp_q(z_q,Q);
          -- store e_i; accumulate sum.  ONE shared exp_q instance.
          -- ----------------------------------------------------------------
          -- exp stage A: score->z_q, then EXP_ROM lookup + frac (no multiply).
          when S_EXP_A =>
            sc_raw := signed(score_mant((idx+1)*16-1 downto idx*16));
            sq_i   := conv_q(sc_raw, sh);        -- recompute score_q[idx]
            z_q    := sq_i - max_q;
            ez     := z_q;
            ex_uf  := ez < shift_left(to_signed(-16, 64), Q);
            if ez > 0 then ez := to_signed(0, 64); end if;
            eoff   := ez + shift_left(to_signed(16, 64), Q);
            eidx   := shift_left(eoff, 4);
            ek     := to_integer(shift_right(eidx, Q));
            if ek > 255 then ek := 255; end if;
            if ek <   0 then ek :=   0; end if;
            ex_frac := eidx - shift_left(to_signed(ek, 64), Q);
            ex_lo   := to_signed(EXP_ROM(ek),     64);
            ex_hd   := to_signed(EXP_ROM(ek + 1), 64) - ex_lo;
            state   := S_EXP_B;
          -- exp stage B: the single (hi-lo)*frac multiply (registered).
          when S_EXP_B =>
            ex_prod := ex_hd * ex_frac;
            state   := S_EXP_C;
          -- exp stage C: normalise -> e_i; store e_arr(idx); accumulate sum.
          when S_EXP_C =>
            etmp    := shift_right(ex_prod, Q);
            einterp := ex_lo + etmp(63 downto 0);
            if Q <= 30 then
              esh := 30 - Q;
              if esh > 0 then
                ebias := shift_left(to_signed(1, 64), esh - 1);
                er    := shift_right(einterp + ebias, esh);
              else er := einterp; end if;
            else er := shift_left(einterp, Q - 30);
            end if;
            if    ex_uf                              then e_i := to_signed(0, 32);
            elsif er < 0                             then e_i := to_signed(0, 32);
            elsif er > to_signed(2147483647, 64)     then e_i := to_signed(2147483647, 32);
            else                                          e_i := resize(er, 32);
            end if;
            e_arr(idx) <= e_i;
            sum        := sum + resize(e_i, 64);
            if idx = nreg-1 then
              if sum <= 0 then sum := to_signed(1, 64); end if;
              sum_out <= std_logic_vector(sum);
              idx     := 0;
              state   := S_NORM;
            else
              idx   := idx + 1;
              state := S_EXP_A;
            end if;

          -- ----------------------------------------------------------------
          -- Step 6: prob_q[idx] = (e_i << Q) / sum.  ONE shared divider.
          -- Also expose the raw exp weight e_i for the full-precision path.
          -- ----------------------------------------------------------------
          when S_NORM =>
            -- read the stored (pipelined) e_i -- no re-run of the exp cone.
            e_i := e_arr(idx);
            num := shift_left(resize(e_i, 64), Q);
            p_i := num / sum;
            prob_q((idx+1)*32-1 downto idx*32) <=
              std_logic_vector(resize(p_i, 32));
            e_out((idx+1)*32-1 downto idx*32) <=
              std_logic_vector(e_i);
            if idx = nreg-1 then
              done  <= '1';
              idx   := 0;
              state := S_IDLE;
            else
              idx := idx + 1;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture rtl;
