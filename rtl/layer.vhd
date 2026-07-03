-- rtl/layer.vhd
-- Single transformer layer: att-rmsnorm -> wq/wk/wv -> rope-Q, rope-K ->
-- attention -> wo -> residual1 -> ffn-rmsnorm -> w1/w3 -> swiglu -> w2 ->
-- residual2.
--
-- Self-contained: the layer computes its OWN current-position K[POS]/V[POS]
-- from the att-rmsnorm output xb (WK/WV matmul, rope applied to K only),
-- appends them to the K/V HISTORY supplied via ports (positions 0..POS-1)
-- to form the full 0..POS attention window, and exposes the computed
-- K[POS]/V[POS] on k_out/v_out so an external sequencer can cache them for
-- future positions. History ports carry POS slots (0..POS-1); at POS=0 this
-- is a null-range (zero-width) vector -- legal VHDL, and the unpack loop
-- ("for t in 0 to POS-1") naturally does not execute.
--
-- All weight matrices load at elaboration from mem/weights/L0/ as integer
-- constants. The full forward pass runs in a single clock cycle (start=1 ->
-- done=1 at the next rising edge), matching every other unit in this project.
--
-- Block-fp convention: value[j] = mant[j] * 2^(-exp).
-- Float-glue parts (att scores, softmax, V-weighted sum, residual adds,
-- BFP re-quant of matmul outputs) use VHDL real, matching the C oracle within
-- +/-4 LSB on the final output.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;
use work.fixed_pkg.all;
use work.util_pkg.all;

entity layer is
  generic(
    DIM       : integer := 64;
    HIDDEN    : integer := 172;
    NHEADS    : integer := 8;
    NKVH      : integer := 4;
    KVDIM     : integer := 32;
    HEAD_SIZE : integer := 8;    -- DIM/NHEADS
    POS       : integer := 3;    -- 0-based position being computed
    WEIGHT_DIR : string := "../mem/weights/L0/"
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    start : in  std_logic;
    -- Input residual (DIM int16 mantissas packed, one shared exponent)
    x_mant : in  std_logic_vector(DIM*16-1 downto 0);
    x_exp  : in  integer;
    -- KV HISTORY only: POS slots, positions 0..POS-1, time-major packed.
    -- (POS=0 => null-range/zero-width ports; no history to unpack.)
    -- k_mant[(t+1)*KVDIM*16-1 : t*KVDIM*16] = K[t] mantissas
    -- k_exp_packed[(t+1)*32-1  : t*32]       = K[t] exponent as signed 32-bit
    k_mant       : in  std_logic_vector(POS*KVDIM*16-1 downto 0);
    k_exp_packed : in  std_logic_vector(POS*32-1 downto 0);
    v_mant       : in  std_logic_vector(POS*KVDIM*16-1 downto 0);
    v_exp_packed : in  std_logic_vector(POS*32-1 downto 0);
    -- Output residual
    done   : out std_logic;
    y_mant : out std_logic_vector(DIM*16-1 downto 0);
    y_exp  : out integer;
    -- Layer's own computed current-position K[POS] (post-RoPE) / V[POS]
    -- (raw), for an external sequencer to cache for future positions.
    k_out_mant : out std_logic_vector(KVDIM*16-1 downto 0);
    k_out_exp  : out integer;
    v_out_mant : out std_logic_vector(KVDIM*16-1 downto 0);
    v_out_exp  : out integer
  );
end entity;

architecture rtl of layer is

  type intarr  is array(natural range <>) of integer;
  type realarr is array(natural range <>) of real;

  -- File loading helpers (impure: reads files at elaboration)
  impure function load_ints(fn : string; n : integer) return intarr is
    file   fh : text open read_mode is fn;
    variable L : line; variable v : integer;
    variable r : intarr(0 to n-1);
  begin
    for i in 0 to n-1 loop
      readline(fh, L); read(L, v); r(i) := v;
    end loop;
    return r;
  end function;

  impure function load_int(fn : string) return integer is
    file   fh : text open read_mode is fn;
    variable L : line; variable v : integer;
  begin
    readline(fh, L); read(L, v); return v;
  end function;

  -- Weight matrix constants (all paths relative to sim/ working directory)
  constant WQ_MANT : intarr(0 to DIM*DIM-1)    := load_ints(WEIGHT_DIR & "wq.mem",              DIM*DIM);
  constant WQ_MULT : intarr(0 to DIM-1)         := load_ints(WEIGHT_DIR & "wq_mult.mem",         DIM);
  constant WQ_SHFT : intarr(0 to DIM-1)         := load_ints(WEIGHT_DIR & "wq_shift.mem",        DIM);

  constant WK_MANT : intarr(0 to KVDIM*DIM-1)  := load_ints(WEIGHT_DIR & "wk.mem",              KVDIM*DIM);
  constant WK_MULT : intarr(0 to KVDIM-1)       := load_ints(WEIGHT_DIR & "wk_mult.mem",         KVDIM);
  constant WK_SHFT : intarr(0 to KVDIM-1)       := load_ints(WEIGHT_DIR & "wk_shift.mem",        KVDIM);

  constant WV_MANT : intarr(0 to KVDIM*DIM-1)  := load_ints(WEIGHT_DIR & "wv.mem",              KVDIM*DIM);
  constant WV_MULT : intarr(0 to KVDIM-1)       := load_ints(WEIGHT_DIR & "wv_mult.mem",         KVDIM);
  constant WV_SHFT : intarr(0 to KVDIM-1)       := load_ints(WEIGHT_DIR & "wv_shift.mem",        KVDIM);

  constant WO_MANT : intarr(0 to DIM*DIM-1)    := load_ints(WEIGHT_DIR & "wo.mem",              DIM*DIM);
  constant WO_MULT : intarr(0 to DIM-1)         := load_ints(WEIGHT_DIR & "wo_mult.mem",         DIM);
  constant WO_SHFT : intarr(0 to DIM-1)         := load_ints(WEIGHT_DIR & "wo_shift.mem",        DIM);

  constant W1_MANT : intarr(0 to HIDDEN*DIM-1) := load_ints(WEIGHT_DIR & "w1.mem",              HIDDEN*DIM);
  constant W1_MULT : intarr(0 to HIDDEN-1)      := load_ints(WEIGHT_DIR & "w1_mult.mem",         HIDDEN);
  constant W1_SHFT : intarr(0 to HIDDEN-1)      := load_ints(WEIGHT_DIR & "w1_shift.mem",        HIDDEN);

  constant W3_MANT : intarr(0 to HIDDEN*DIM-1) := load_ints(WEIGHT_DIR & "w3.mem",              HIDDEN*DIM);
  constant W3_MULT : intarr(0 to HIDDEN-1)      := load_ints(WEIGHT_DIR & "w3_mult.mem",         HIDDEN);
  constant W3_SHFT : intarr(0 to HIDDEN-1)      := load_ints(WEIGHT_DIR & "w3_shift.mem",        HIDDEN);

  constant W2_MANT : intarr(0 to DIM*HIDDEN-1) := load_ints(WEIGHT_DIR & "w2.mem",              DIM*HIDDEN);
  constant W2_MULT : intarr(0 to DIM-1)         := load_ints(WEIGHT_DIR & "w2_mult.mem",         DIM);
  constant W2_SHFT : intarr(0 to DIM-1)         := load_ints(WEIGHT_DIR & "w2_shift.mem",        DIM);

  constant ATT_W_MANT : intarr(0 to DIM-1) := load_ints(WEIGHT_DIR & "att_rmsnorm_w.mem",       DIM);
  constant ATT_W_EXP  : integer             := load_int (WEIGHT_DIR & "att_rmsnorm_w_exp.txt");
  constant FFN_W_MANT : intarr(0 to DIM-1) := load_ints(WEIGHT_DIR & "ffn_rmsnorm_w.mem",       DIM);
  constant FFN_W_EXP  : integer             := load_int (WEIGHT_DIR & "ffn_rmsnorm_w_exp.txt");

  -- RoPE twiddle ROMs
  constant ROPE_HALF  : integer := HEAD_SIZE / 2;
  constant ROPE_DEPTH : integer := 512 * ROPE_HALF;

  impure function load_rope_rom(fn : string) return intarr is
    file   fh : text open read_mode is fn;
    variable L : line; variable v : integer;
    variable r : intarr(0 to ROPE_DEPTH-1);
  begin
    for i in 0 to ROPE_DEPTH-1 loop
      readline(fh, L); read(L, v); r(i) := v;
    end loop;
    return r;
  end function;

  constant COS_ROM : intarr(0 to ROPE_DEPTH-1) := load_rope_rom("../mem/luts/rope_cos.mem");
  constant SIN_ROM : intarr(0 to ROPE_DEPTH-1) := load_rope_rom("../mem/luts/rope_sin.mem");

  -- Highest set bit index (0 for v<=0)
  function msb_pos(v : integer) return integer is
    variable u : integer := v;
    variable p : integer := 0;
  begin
    if u <= 0 then return 0; end if;
    while u > 1 loop u := u / 2; p := p + 1; end loop;
    return p;
  end function;

  -- Unconstrained array of 64-bit signed (mirrors rmsnorm.vhd raw64_arr)
  type s64arr is array(natural range <>) of signed(63 downto 0);

begin

  process(clk)
    -- Input residual
    variable x_v      : intarr(0 to DIM-1);
    variable x_e      : integer;
    -- After att rmsnorm
    variable xb_v     : intarr(0 to DIM-1);
    variable xb_e     : integer;
    -- Q vector (after wq + rope)
    variable q_v      : intarr(0 to DIM-1);
    variable q_e      : integer;
    -- KV cache (POS+1 positions, KVDIM values each): 0..POS-1 from history
    -- ports, POS computed internally (WK/WV + rope-K for position POS).
    variable kc_v     : intarr(0 to (POS+1)*KVDIM-1);
    variable vc_v     : intarr(0 to (POS+1)*KVDIM-1);
    variable kc_e     : intarr(0 to POS);
    variable vc_e     : intarr(0 to POS);
    -- Current-position K/V (after wk/wv; k_new further gets rope applied)
    variable k_new_v  : intarr(0 to KVDIM-1);
    variable k_new_e  : integer;
    variable v_new_v  : intarr(0 to KVDIM-1);
    variable v_new_e  : integer;
    -- Attention output (float accumulator + BFP convert for WO matmul input)
    variable xb_att_r : realarr(0 to DIM-1);  -- scratch real, reused after att
    variable xb_att_v : intarr(0 to DIM-1);
    variable xb_att_e : integer;
    -- Residual1 (BFP-encoded after x + wo_output in real)
    variable xm_v     : intarr(0 to DIM-1);
    variable xm_e     : integer;
    -- After ffn rmsnorm
    variable xf_v     : intarr(0 to DIM-1);
    variable xf_e     : integer;
    -- After w1, w3 matmuls
    variable h1_v     : intarr(0 to HIDDEN-1);
    variable h1_e     : integer;
    variable h3_v     : intarr(0 to HIDDEN-1);
    variable h3_e     : integer;
    -- After swiglu
    variable hb_q     : intarr(0 to HIDDEN-1);  -- Q12 int result
    variable hb_v     : intarr(0 to HIDDEN-1);  -- BFP mantissas
    variable hb_e     : integer;

    -- General computation temporaries
    variable acc64    : signed(63 downto 0);
    variable w16      : signed(15 downto 0);
    variable x16      : signed(15 downto 0);
    variable prod32   : signed(31 downto 0);
    variable res32    : signed(31 downto 0);
    variable result_v : intarr(0 to 172);   -- max(DIM,HIDDEN)
    variable max_abs  : integer;
    variable abs_v    : integer;
    variable p_msb    : integer;
    variable shift_o  : integer;

    -- RMSNorm temporaries (shared by att-rms and ffn-rms)
    variable S64      : signed(63 downto 0);
    variable num64    : signed(63 downto 0);
    variable msq      : signed(63 downto 0);
    variable inv32    : signed(31 downto 0);
    variable xm_ext   : signed(63 downto 0);
    variable inv_ext  : signed(63 downto 0);
    variable wm_ext   : signed(63 downto 0);
    variable raw64    : signed(63 downto 0);
    variable raws     : s64arr(0 to DIM-1);   -- 64-bit; mirrors rmsnorm.vhd raw64_arr
    variable max_raw  : signed(63 downto 0);
    variable abs_raw  : signed(63 downto 0);
    variable sh_rms   : integer;
    variable bias64   : signed(63 downto 0);
    variable om32     : signed(31 downto 0);
    variable p_bit    : integer;

    -- RoPE temporaries
    variable fcr_v, fci_v : signed(15 downto 0);
    variable q0_v, q1_v   : signed(15 downto 0);
    variable k0_v, k1_v   : signed(15 downto 0);
    variable rope_acc     : signed(63 downto 0);
    variable rope_r       : signed(63 downto 0);
    variable rom_idx      : integer;
    constant ROPE_BIAS    : signed(63 downto 0) := to_signed(16384, 64);

    -- Attention temporaries
    variable kv_h       : integer;
    variable q_head_m   : intarr(0 to HEAD_SIZE-1);
    variable k_head_m   : intarr(0 to HEAD_SIZE-1);
    variable q_head_max : integer;
    variable k_head_max : integer;
    variable q_extra    : integer;
    variable k_extra    : integer;
    variable qe_head    : integer;
    variable ke_head    : integer;
    variable dot_i64    : signed(63 downto 0);
    variable abs_dot64  : signed(63 downto 0);  -- |dot_i64| for safe to_integer
    variable dot_sh     : integer;              -- right-shift to bring into 30-bit range
    variable dot32      : signed(31 downto 0);  -- scale_mul output for dot
    variable qh16, kh16 : signed(15 downto 0);
    variable ph32       : signed(31 downto 0);
    variable scores     : realarr(0 to POS);
    variable probs      : realarr(0 to POS);
    variable score_max  : real;
    variable z_q32      : signed(31 downto 0);
    variable e_arr      : intarr(0 to POS);
    variable e_i32      : signed(31 downto 0);
    variable sum_e      : signed(63 downto 0);
    variable inv_qe     : real;
    variable inv_ke     : real;
    constant SQRT_HEAD_SIZE : real := 2.82842712474619;  -- sqrt(8)

    -- SwiGLU temporaries
    variable v_q32    : signed(31 downto 0);
    variable h2_q32   : signed(31 downto 0);
    variable sig32    : signed(31 downto 0);
    variable prod64   : signed(63 downto 0);
    variable silu32   : signed(31 downto 0);
    variable out32    : signed(31 downto 0);
    variable sh_sw    : integer;
    variable bias_sw  : signed(63 downto 0);
    variable mant64   : signed(63 downto 0);

    -- BFP-from-real scratch (used by att output, residual1, residual2 conversions)
    variable bfp_mx   : real;
    variable bfp_e    : integer;
    variable bfp_sc   : real;
    variable bfp_rv   : integer;

  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        y_exp      <= 0;
        y_mant     <= (others => '0');
        k_out_exp  <= 0;
        k_out_mant <= (others => '0');
        v_out_exp  <= 0;
        v_out_mant <= (others => '0');

      elsif start = '1' then

        -- ===================================================================
        -- 0. Unpack inputs
        -- ===================================================================
        x_e := x_exp;
        for j in 0 to DIM-1 loop
          x_v(j) := to_integer(signed(x_mant((j+1)*16-1 downto j*16)));
        end loop;
        -- History only: t = 0..POS-1 (POS=0 -> empty range, nothing to read)
        for t in 0 to POS-1 loop
          kc_e(t) := to_integer(signed(k_exp_packed((t+1)*32-1 downto t*32)));
          vc_e(t) := to_integer(signed(v_exp_packed((t+1)*32-1 downto t*32)));
          for j in 0 to KVDIM-1 loop
            kc_v(t*KVDIM+j) := to_integer(signed(k_mant((t*KVDIM+j+1)*16-1 downto (t*KVDIM+j)*16)));
            vc_v(t*KVDIM+j) := to_integer(signed(v_mant((t*KVDIM+j+1)*16-1 downto (t*KVDIM+j)*16)));
          end loop;
        end loop;

        -- ===================================================================
        -- 1. Attention RMSNorm: rmsnorm(x, att_w) -> xb  (Q=12)
        --    Mirrors rmsnorm.vhd step-by-step.
        -- ===================================================================
        S64 := (others => '0');
        for j in 0 to DIM-1 loop
          w16    := to_signed(x_v(j), 16);
          prod32 := w16 * w16;
          S64    := S64 + resize(prod32, 64);
        end loop;
        num64 := shift_left(S64, 12);
        msq   := (num64 + to_signed(DIM/2, 64)) / to_signed(DIM, 64);
        if x_e >= 0 then
          sh_rms := 2 * x_e;
          if sh_rms > 62 then sh_rms := 62; end if;
          if sh_rms > 0 then
            bias64 := shift_left(to_signed(1, 64), sh_rms - 1);
            msq    := shift_right(msq + bias64, sh_rms);
          end if;
        else
          sh_rms := -(2 * x_e);
          if sh_rms > 62 then sh_rms := 62; end if;
          msq := shift_left(msq, sh_rms);
        end if;
        if msq < 1 then msq := to_signed(1, 64); end if;
        inv32   := rsqrt_q(msq, 12);
        max_raw := (others => '0');
        inv_ext := resize(inv32, 64);
        for j in 0 to DIM-1 loop
          xm_ext  := resize(to_signed(x_v(j),         16), 64);
          wm_ext  := resize(to_signed(ATT_W_MANT(j),  16), 64);
          raw64   := resize(resize(xm_ext * inv_ext, 64) * wm_ext, 64);
          raws(j) := raw64;
          if raw64 < 0 then abs_raw := -raw64; else abs_raw := raw64; end if;
          if abs_raw > max_raw then max_raw := abs_raw; end if;
        end loop;
        p_bit := 0;
        for i in 0 to 62 loop
          if max_raw(i) = '1' then p_bit := i; end if;
        end loop;
        sh_rms := p_bit - 14; if sh_rms < 0 then sh_rms := 0; end if;
        xb_e   := x_e + ATT_W_EXP + 12 - sh_rms;
        for j in 0 to DIM-1 loop
          om32 := scale_mul(raws(j), to_signed(1, 32), sh_rms);
          if    om32 >  32767 then xb_v(j) :=  32767;
          elsif om32 < -32768 then xb_v(j) := -32768;
          else                     xb_v(j) := to_integer(om32);
          end if;
        end loop;

        -- ===================================================================
        -- 2. WQ matmul: xb -> q  (DIM x DIM)
        -- ===================================================================
        max_abs := 0;
        for i in 0 to DIM-1 loop
          acc64 := (others => '0');
          for j in 0 to DIM-1 loop
            w16    := to_signed(WQ_MANT(i*DIM+j), 16);
            x16    := to_signed(xb_v(j), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);
          end loop;
          res32       := scale_mul(acc64, to_signed(WQ_MULT(i), 32), WQ_SHFT(i));
          result_v(i) := to_integer(res32);
          abs_v := result_v(i); if abs_v < 0 then abs_v := -abs_v; end if;
          if abs_v > max_abs then max_abs := abs_v; end if;
        end loop;
        p_msb   := msb_pos(max_abs);
        shift_o := p_msb - 14; if shift_o < 0 then shift_o := 0; end if;
        q_e     := xb_e - shift_o;
        for i in 0 to DIM-1 loop
          res32 := scale_mul(to_signed(result_v(i), 64), to_signed(1, 32), shift_o);
          if    res32 >  32767 then q_v(i) :=  32767;
          elsif res32 < -32768 then q_v(i) := -32768;
          else                      q_v(i) := to_integer(res32);
          end if;
        end loop;

        -- ===================================================================
        -- 2b. WK matmul: xb -> k_new (KVDIM x DIM). RoPE applied in step 3b.
        --     Same per-row scale_mul + global-shift BFP pattern as WQ (2).
        -- ===================================================================
        max_abs := 0;
        for i in 0 to KVDIM-1 loop
          acc64 := (others => '0');
          for j in 0 to DIM-1 loop
            w16    := to_signed(WK_MANT(i*DIM+j), 16);
            x16    := to_signed(xb_v(j), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);
          end loop;
          res32       := scale_mul(acc64, to_signed(WK_MULT(i), 32), WK_SHFT(i));
          result_v(i) := to_integer(res32);
          abs_v := result_v(i); if abs_v < 0 then abs_v := -abs_v; end if;
          if abs_v > max_abs then max_abs := abs_v; end if;
        end loop;
        -- Unlike WQ's shift_o (clamped >=0; Q values already fill the int16
        -- range so a right-shift-only reduction suffices), K/V magnitudes
        -- vary a lot more, so shift_o may be NEGATIVE here (a left-shift /
        -- exponent increase) to fully use the mantissa's precision, matching
        -- the golden's max-precision BFP re-quantisation (fx_bfp_from_float).
        p_msb   := msb_pos(max_abs);
        shift_o := p_msb - 14;
        k_new_e := xb_e - shift_o;
        for i in 0 to KVDIM-1 loop
          if shift_o >= 0 then
            res32 := scale_mul(to_signed(result_v(i), 64), to_signed(1, 32), shift_o);
            if    res32 >  32767 then k_new_v(i) :=  32767;
            elsif res32 < -32768 then k_new_v(i) := -32768;
            else                      k_new_v(i) := to_integer(res32);
            end if;
          else
            acc64 := shift_left(to_signed(result_v(i), 64), -shift_o);
            if    acc64 >  32767 then k_new_v(i) :=  32767;
            elsif acc64 < -32768 then k_new_v(i) := -32768;
            else                      k_new_v(i) := to_integer(acc64);
            end if;
          end if;
        end loop;

        -- ===================================================================
        -- 2c. WV matmul: xb -> v_new (KVDIM x DIM). No RoPE (V is raw/BFP).
        -- ===================================================================
        max_abs := 0;
        for i in 0 to KVDIM-1 loop
          acc64 := (others => '0');
          for j in 0 to DIM-1 loop
            w16    := to_signed(WV_MANT(i*DIM+j), 16);
            x16    := to_signed(xb_v(j), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);
          end loop;
          res32       := scale_mul(acc64, to_signed(WV_MULT(i), 32), WV_SHFT(i));
          result_v(i) := to_integer(res32);
          abs_v := result_v(i); if abs_v < 0 then abs_v := -abs_v; end if;
          if abs_v > max_abs then max_abs := abs_v; end if;
        end loop;
        -- shift_o may be negative here too (see note in the WK block above).
        p_msb   := msb_pos(max_abs);
        shift_o := p_msb - 14;
        v_new_e := xb_e - shift_o;
        for i in 0 to KVDIM-1 loop
          if shift_o >= 0 then
            res32 := scale_mul(to_signed(result_v(i), 64), to_signed(1, 32), shift_o);
            if    res32 >  32767 then v_new_v(i) :=  32767;
            elsif res32 < -32768 then v_new_v(i) := -32768;
            else                      v_new_v(i) := to_integer(res32);
            end if;
          else
            acc64 := shift_left(to_signed(result_v(i), 64), -shift_o);
            if    acc64 >  32767 then v_new_v(i) :=  32767;
            elsif acc64 < -32768 then v_new_v(i) := -32768;
            else                      v_new_v(i) := to_integer(acc64);
            end if;
          end if;
        end loop;

        -- ===================================================================
        -- 3. RoPE on Q
        --    twiddle_idx = POS * ROPE_HALF + ((2*i) mod HEAD_SIZE) / 2
        -- ===================================================================
        for i in 0 to DIM/2-1 loop
          q0_v    := to_signed(q_v(2*i),   16);
          q1_v    := to_signed(q_v(2*i+1), 16);
          rom_idx := POS * ROPE_HALF + ((2*i) mod HEAD_SIZE) / 2;
          fcr_v   := to_signed(COS_ROM(rom_idx), 16);
          fci_v   := to_signed(SIN_ROM(rom_idx), 16);
          -- r0 = round((q0*cos - q1*sin) >> 15)
          rope_acc := resize(q0_v, 32) * resize(fcr_v, 32)
                    - resize(q1_v, 32) * resize(fci_v, 32)
                    + ROPE_BIAS;
          rope_r   := shift_right(rope_acc, 15);
          if    rope_r >  32767 then q_v(2*i)   :=  32767;
          elsif rope_r < -32768 then q_v(2*i)   := -32768;
          else                       q_v(2*i)   := to_integer(resize(rope_r, 32));
          end if;
          -- r1 = round((q0*sin + q1*cos) >> 15)
          rope_acc := resize(q0_v, 32) * resize(fci_v, 32)
                    + resize(q1_v, 32) * resize(fcr_v, 32)
                    + ROPE_BIAS;
          rope_r   := shift_right(rope_acc, 15);
          if    rope_r >  32767 then q_v(2*i+1) :=  32767;
          elsif rope_r < -32768 then q_v(2*i+1) := -32768;
          else                       q_v(2*i+1) := to_integer(resize(rope_r, 32));
          end if;
        end loop;
        -- q_e unchanged by RoPE (>>15 preserves scale)

        -- ===================================================================
        -- 3b. RoPE on K[POS] (first kv_dim elements only; same twiddle ROM
        --     and index formula as Q's rope, over KVDIM/2 pairs).
        --     k_new_e unchanged by RoPE (>>15 preserves scale).
        -- ===================================================================
        for i in 0 to KVDIM/2-1 loop
          k0_v    := to_signed(k_new_v(2*i),   16);
          k1_v    := to_signed(k_new_v(2*i+1), 16);
          rom_idx := POS * ROPE_HALF + ((2*i) mod HEAD_SIZE) / 2;
          fcr_v   := to_signed(COS_ROM(rom_idx), 16);
          fci_v   := to_signed(SIN_ROM(rom_idx), 16);
          rope_acc := resize(k0_v, 32) * resize(fcr_v, 32)
                    - resize(k1_v, 32) * resize(fci_v, 32)
                    + ROPE_BIAS;
          rope_r   := shift_right(rope_acc, 15);
          if    rope_r >  32767 then k_new_v(2*i)   :=  32767;
          elsif rope_r < -32768 then k_new_v(2*i)   := -32768;
          else                       k_new_v(2*i)   := to_integer(resize(rope_r, 32));
          end if;
          rope_acc := resize(k0_v, 32) * resize(fci_v, 32)
                    + resize(k1_v, 32) * resize(fcr_v, 32)
                    + ROPE_BIAS;
          rope_r   := shift_right(rope_acc, 15);
          if    rope_r >  32767 then k_new_v(2*i+1) :=  32767;
          elsif rope_r < -32768 then k_new_v(2*i+1) := -32768;
          else                       k_new_v(2*i+1) := to_integer(resize(rope_r, 32));
          end if;
        end loop;

        -- Append computed K[POS]/V[POS] into the KV cache (history was
        -- unpacked into indices 0..POS-1 in step 0).
        kc_e(POS) := k_new_e;
        vc_e(POS) := v_new_e;
        for j in 0 to KVDIM-1 loop
          kc_v(POS*KVDIM+j) := k_new_v(j);
          vc_v(POS*KVDIM+j) := v_new_v(j);
        end loop;

        -- Drive k_out/v_out ports with the computed current-position K/V.
        k_out_exp <= k_new_e;
        v_out_exp <= v_new_e;
        for j in 0 to KVDIM-1 loop
          k_out_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(k_new_v(j), 16));
          v_out_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(v_new_v(j), 16));
        end loop;

        -- ===================================================================
        -- 4. Multi-head attention: scores, softmax, V-weighted sum (float glue)
        -- ===================================================================
        for j in 0 to DIM-1 loop xb_att_r(j) := 0.0; end loop;

        for h in 0 to NHEADS-1 loop
          kv_h := h / (NHEADS / NKVH);  -- GQA mapping

          -- Q head slice: re-BFP to fill int16 range
          q_head_max := 0;
          for j in 0 to HEAD_SIZE-1 loop
            q_head_m(j) := q_v(h*HEAD_SIZE + j);
            abs_v := q_head_m(j); if abs_v < 0 then abs_v := -abs_v; end if;
            if abs_v > q_head_max then q_head_max := abs_v; end if;
          end loop;
          if q_head_max = 0 then q_extra := 0;
          else                   q_extra := 14 - msb_pos(q_head_max);
          end if;
          qe_head := q_e + q_extra;
          if q_extra >= 0 then
            for j in 0 to HEAD_SIZE-1 loop q_head_m(j) := q_head_m(j) * (2**q_extra); end loop;
          else
            for j in 0 to HEAD_SIZE-1 loop q_head_m(j) := q_head_m(j) / (2**(-q_extra)); end loop;
          end if;
          inv_qe := 2.0 ** (-qe_head);

          -- Attention scores for each position
          for t in 0 to POS loop
            k_head_max := 0;
            for j in 0 to HEAD_SIZE-1 loop
              k_head_m(j) := kc_v(t*KVDIM + kv_h*HEAD_SIZE + j);
              abs_v := k_head_m(j); if abs_v < 0 then abs_v := -abs_v; end if;
              if abs_v > k_head_max then k_head_max := abs_v; end if;
            end loop;
            if k_head_max = 0 then k_extra := 0;
            else                   k_extra := 14 - msb_pos(k_head_max);
            end if;
            ke_head := kc_e(t) + k_extra;
            if k_extra >= 0 then
              for j in 0 to HEAD_SIZE-1 loop k_head_m(j) := k_head_m(j) * (2**k_extra); end loop;
            else
              for j in 0 to HEAD_SIZE-1 loop k_head_m(j) := k_head_m(j) / (2**(-k_extra)); end loop;
            end if;
            inv_ke  := 2.0 ** (-ke_head);
            -- Integer dot Q.K
            dot_i64 := (others => '0');
            for j in 0 to HEAD_SIZE-1 loop
              qh16    := to_signed(q_head_m(j), 16);
              kh16    := to_signed(k_head_m(j), 16);
              ph32    := qh16 * kh16;
              dot_i64 := dot_i64 + resize(ph32, 64);
            end loop;
            -- Safe to_integer: max dot = HEAD_SIZE*32767^2 ~ 2^31 may overflow int32.
            -- Scale down to 30-bit range using scale_mul, then restore scale in real.
            abs_dot64 := dot_i64;
            if dot_i64 < 0 then abs_dot64 := -dot_i64; end if;
            dot_sh := 0;
            for k in 0 to 62 loop
              if abs_dot64(k) = '1' then dot_sh := k; end if;
            end loop;
            if dot_sh > 30 then dot_sh := dot_sh - 30; else dot_sh := 0; end if;
            dot32     := scale_mul(dot_i64, to_signed(1, 32), dot_sh);
            scores(t) := real(to_integer(dot32)) * (2.0 ** dot_sh) * inv_qe * inv_ke / SQRT_HEAD_SIZE;
          end loop;

          -- Softmax: max-subtract, exp_q Q12, normalise
          score_max := scores(0);
          for t in 1 to POS loop
            if scores(t) > score_max then score_max := scores(t); end if;
          end loop;
          sum_e := (others => '0');
          for t in 0 to POS loop
            z_q32    := to_signed(integer(round((scores(t) - score_max) * 4096.0)), 32);
            e_i32    := exp_q(resize(z_q32, 64), 12);
            e_arr(t) := to_integer(e_i32);
            sum_e    := sum_e + resize(e_i32, 64);
          end loop;
          if sum_e <= 0 then sum_e := to_signed(1, 64); end if;
          for t in 0 to POS loop
            probs(t) := real(e_arr(t)) / real(to_integer(sum_e));
          end loop;

          -- V-weighted sum
          for j in 0 to HEAD_SIZE-1 loop
            xb_att_r(h*HEAD_SIZE + j) := 0.0;
            for t in 0 to POS loop
              xb_att_r(h*HEAD_SIZE + j) :=
                xb_att_r(h*HEAD_SIZE + j) +
                probs(t) * real(vc_v(t*KVDIM + kv_h*HEAD_SIZE + j)) * (2.0 ** (-vc_e(t)));
            end loop;
          end loop;
        end loop;

        -- ===================================================================
        -- 5. BFP convert attention output reals -> xb_att_v / xb_att_e
        -- ===================================================================
        bfp_mx := 0.0;
        for j in 0 to DIM-1 loop
          if abs(xb_att_r(j)) > bfp_mx then bfp_mx := abs(xb_att_r(j)); end if;
        end loop;
        if bfp_mx = 0.0 then
          xb_att_e := 14;
          for j in 0 to DIM-1 loop xb_att_v(j) := 0; end loop;
        else
          bfp_e := -30;
          for ti in 0 to 60 loop
            bfp_e := 30 - ti;
            if bfp_e >= 0 then bfp_sc := bfp_mx * real(2**bfp_e);
            else               bfp_sc := bfp_mx / real(2**(-bfp_e)); end if;
            if integer(round(bfp_sc)) <= 32767 then exit; end if;
          end loop;
          xb_att_e := bfp_e;
          for j in 0 to DIM-1 loop
            if bfp_e >= 0 then bfp_sc := xb_att_r(j) * real(2**bfp_e);
            else               bfp_sc := xb_att_r(j) / real(2**(-bfp_e)); end if;
            bfp_rv := integer(round(bfp_sc));
            if bfp_rv >  32767 then bfp_rv :=  32767; end if;
            if bfp_rv < -32768 then bfp_rv := -32768; end if;
            xb_att_v(j) := bfp_rv;
          end loop;
        end if;

        -- ===================================================================
        -- 6+7. WO matmul + Residual add 1: xm = x + WO*xb_att
        --
        -- Mirrors C oracle: matmul_fx outputs float as result_i * 2^(-xb_att_e),
        -- then x[i] += that float.  We avoid a second BFP encoding of WO output
        -- so rounding matches the C oracle's float residual add.
        -- ===================================================================
        for i in 0 to DIM-1 loop
          acc64 := (others => '0');
          for j in 0 to DIM-1 loop
            w16    := to_signed(WO_MANT(i*DIM+j), 16);
            x16    := to_signed(xb_att_v(j), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);
          end loop;
          res32       := scale_mul(acc64, to_signed(WO_MULT(i), 32), WO_SHFT(i));
          result_v(i) := to_integer(res32);
          -- Real value: result_v(i) * 2^(-xb_att_e)  (matches matmul_fx xout[i])
          xb_att_r(i) := real(result_v(i)) * (2.0 ** (-xb_att_e));
        end loop;
        -- Residual add 1: x_float[j] + wo_float[j]  then BFP encode
        bfp_mx := 0.0;
        for j in 0 to DIM-1 loop
          bfp_sc      := real(x_v(j)) * (2.0 ** (-x_e)) + xb_att_r(j);
          xb_att_r(j) := bfp_sc;
          if abs(bfp_sc) > bfp_mx then bfp_mx := abs(bfp_sc); end if;
        end loop;
        -- BFP encode -> xm_v / xm_e
        if bfp_mx = 0.0 then
          xm_e := 14;
          for j in 0 to DIM-1 loop xm_v(j) := 0; end loop;
        else
          bfp_e := -30;
          for ti in 0 to 60 loop
            bfp_e := 30 - ti;
            if bfp_e >= 0 then bfp_sc := bfp_mx * real(2**bfp_e);
            else               bfp_sc := bfp_mx / real(2**(-bfp_e)); end if;
            if integer(round(bfp_sc)) <= 32767 then exit; end if;
          end loop;
          xm_e := bfp_e;
          for j in 0 to DIM-1 loop
            if bfp_e >= 0 then bfp_sc := xb_att_r(j) * real(2**bfp_e);
            else               bfp_sc := xb_att_r(j) / real(2**(-bfp_e)); end if;
            bfp_rv := integer(round(bfp_sc));
            if bfp_rv >  32767 then bfp_rv :=  32767; end if;
            if bfp_rv < -32768 then bfp_rv := -32768; end if;
            xm_v(j) := bfp_rv;
          end loop;
        end if;

        -- ===================================================================
        -- 8. FFN RMSNorm: rmsnorm(xm, ffn_w) -> xf  (same algorithm as step 1)
        -- ===================================================================
        S64 := (others => '0');
        for j in 0 to DIM-1 loop
          w16    := to_signed(xm_v(j), 16);
          prod32 := w16 * w16;
          S64    := S64 + resize(prod32, 64);
        end loop;
        num64 := shift_left(S64, 12);
        msq   := (num64 + to_signed(DIM/2, 64)) / to_signed(DIM, 64);
        if xm_e >= 0 then
          sh_rms := 2 * xm_e;
          if sh_rms > 62 then sh_rms := 62; end if;
          if sh_rms > 0 then
            bias64 := shift_left(to_signed(1, 64), sh_rms - 1);
            msq    := shift_right(msq + bias64, sh_rms);
          end if;
        else
          sh_rms := -(2 * xm_e);
          if sh_rms > 62 then sh_rms := 62; end if;
          msq := shift_left(msq, sh_rms);
        end if;
        if msq < 1 then msq := to_signed(1, 64); end if;
        inv32   := rsqrt_q(msq, 12);
        max_raw := (others => '0');
        inv_ext := resize(inv32, 64);
        for j in 0 to DIM-1 loop
          xm_ext  := resize(to_signed(xm_v(j),        16), 64);
          wm_ext  := resize(to_signed(FFN_W_MANT(j),  16), 64);
          raw64   := resize(resize(xm_ext * inv_ext, 64) * wm_ext, 64);
          raws(j) := raw64;
          if raw64 < 0 then abs_raw := -raw64; else abs_raw := raw64; end if;
          if abs_raw > max_raw then max_raw := abs_raw; end if;
        end loop;
        p_bit := 0;
        for i in 0 to 62 loop
          if max_raw(i) = '1' then p_bit := i; end if;
        end loop;
        sh_rms := p_bit - 14; if sh_rms < 0 then sh_rms := 0; end if;
        xf_e   := xm_e + FFN_W_EXP + 12 - sh_rms;
        for j in 0 to DIM-1 loop
          om32 := scale_mul(raws(j), to_signed(1, 32), sh_rms);
          if    om32 >  32767 then xf_v(j) :=  32767;
          elsif om32 < -32768 then xf_v(j) := -32768;
          else                     xf_v(j) := to_integer(om32);
          end if;
        end loop;

        -- ===================================================================
        -- 9. W1 matmul: xf -> h1  (HIDDEN x DIM)
        -- ===================================================================
        max_abs := 0;
        for i in 0 to HIDDEN-1 loop
          acc64 := (others => '0');
          for j in 0 to DIM-1 loop
            w16    := to_signed(W1_MANT(i*DIM+j), 16);
            x16    := to_signed(xf_v(j), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);
          end loop;
          res32       := scale_mul(acc64, to_signed(W1_MULT(i), 32), W1_SHFT(i));
          result_v(i) := to_integer(res32);
          abs_v := result_v(i); if abs_v < 0 then abs_v := -abs_v; end if;
          if abs_v > max_abs then max_abs := abs_v; end if;
        end loop;
        p_msb   := msb_pos(max_abs);
        shift_o := p_msb - 14; if shift_o < 0 then shift_o := 0; end if;
        h1_e    := xf_e - shift_o;
        for i in 0 to HIDDEN-1 loop
          res32 := scale_mul(to_signed(result_v(i), 64), to_signed(1, 32), shift_o);
          if    res32 >  32767 then h1_v(i) :=  32767;
          elsif res32 < -32768 then h1_v(i) := -32768;
          else                      h1_v(i) := to_integer(res32);
          end if;
        end loop;

        -- ===================================================================
        -- 10. W3 matmul: xf -> h3  (HIDDEN x DIM)
        -- ===================================================================
        max_abs := 0;
        for i in 0 to HIDDEN-1 loop
          acc64 := (others => '0');
          for j in 0 to DIM-1 loop
            w16    := to_signed(W3_MANT(i*DIM+j), 16);
            x16    := to_signed(xf_v(j), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);
          end loop;
          res32       := scale_mul(acc64, to_signed(W3_MULT(i), 32), W3_SHFT(i));
          result_v(i) := to_integer(res32);
          abs_v := result_v(i); if abs_v < 0 then abs_v := -abs_v; end if;
          if abs_v > max_abs then max_abs := abs_v; end if;
        end loop;
        p_msb   := msb_pos(max_abs);
        shift_o := p_msb - 14; if shift_o < 0 then shift_o := 0; end if;
        h3_e    := xf_e - shift_o;
        for i in 0 to HIDDEN-1 loop
          res32 := scale_mul(to_signed(result_v(i), 64), to_signed(1, 32), shift_o);
          if    res32 >  32767 then h3_v(i) :=  32767;
          elsif res32 < -32768 then h3_v(i) := -32768;
          else                      h3_v(i) := to_integer(res32);
          end if;
        end loop;

        -- ===================================================================
        -- 11. SwiGLU: swiglu_fx(h1, h3) -> hb_q (Q12 integers)
        --     v = h1[i] BFP->Q12, h2 = h3[i] BFP->Q12
        --     silu = (v * sigmoid(v)) >> 12, out = (silu * h2) >> 12
        -- ===================================================================
        for i in 0 to HIDDEN-1 loop
          mant64 := resize(to_signed(h1_v(i), 16), 64);
          sh_sw  := 12 - h1_e;
          if sh_sw >= 0 then
            v_q32 := resize(shift_left(mant64, sh_sw), 32);
          else
            bias_sw := shift_left(to_signed(1, 64), (-sh_sw) - 1);
            v_q32   := resize(shift_right(mant64 + bias_sw, -sh_sw), 32);
          end if;
          mant64 := resize(to_signed(h3_v(i), 16), 64);
          sh_sw  := 12 - h3_e;
          if sh_sw >= 0 then
            h2_q32 := resize(shift_left(mant64, sh_sw), 32);
          else
            bias_sw := shift_left(to_signed(1, 64), (-sh_sw) - 1);
            h2_q32  := resize(shift_right(mant64 + bias_sw, -sh_sw), 32);
          end if;
          sig32  := sigmoid_q(resize(v_q32, 64), 12);
          prod64 := v_q32 * sig32;
          silu32 := resize(shift_right(prod64, 12), 32);
          prod64 := silu32 * h2_q32;
          out32  := resize(shift_right(prod64, 12), 32);
          hb_q(i) := to_integer(out32);
        end loop;
        -- BFP convert hb_q: Q12 int, real value = hb_q[i] * 2^(-12)
        max_abs := 0;
        for i in 0 to HIDDEN-1 loop
          abs_v := hb_q(i); if abs_v < 0 then abs_v := -abs_v; end if;
          if abs_v > max_abs then max_abs := abs_v; end if;
        end loop;
        p_msb   := msb_pos(max_abs);
        shift_o := p_msb - 14; if shift_o < 0 then shift_o := 0; end if;
        hb_e    := 12 - shift_o;
        for i in 0 to HIDDEN-1 loop
          res32 := scale_mul(to_signed(hb_q(i), 64), to_signed(1, 32), shift_o);
          if    res32 >  32767 then hb_v(i) :=  32767;
          elsif res32 < -32768 then hb_v(i) := -32768;
          else                      hb_v(i) := to_integer(res32);
          end if;
        end loop;

        -- ===================================================================
        -- 12+13. W2 matmul + Residual add 2: y = xm + W2*hb
        --
        -- Same approach as steps 6+7: W2 output is result_i * 2^(-hb_e) in real;
        -- add directly to xm float without intermediate BFP encoding.
        -- ===================================================================
        for i in 0 to DIM-1 loop
          acc64 := (others => '0');
          for j in 0 to HIDDEN-1 loop
            w16    := to_signed(W2_MANT(i*HIDDEN+j), 16);
            x16    := to_signed(hb_v(j), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);
          end loop;
          res32       := scale_mul(acc64, to_signed(W2_MULT(i), 32), W2_SHFT(i));
          result_v(i) := to_integer(res32);
          xb_att_r(i) := real(result_v(i)) * (2.0 ** (-hb_e));
        end loop;
        -- Residual add 2: xm_float[j] + w2_float[j]  then BFP encode to output
        bfp_mx := 0.0;
        for j in 0 to DIM-1 loop
          bfp_sc      := real(xm_v(j)) * (2.0 ** (-xm_e)) + xb_att_r(j);
          xb_att_r(j) := bfp_sc;
          if abs(bfp_sc) > bfp_mx then bfp_mx := abs(bfp_sc); end if;
        end loop;
        if bfp_mx = 0.0 then
          y_exp  <= 14;
          y_mant <= (others => '0');
        else
          bfp_e := -30;
          for ti in 0 to 60 loop
            bfp_e := 30 - ti;
            if bfp_e >= 0 then bfp_sc := bfp_mx * real(2**bfp_e);
            else               bfp_sc := bfp_mx / real(2**(-bfp_e)); end if;
            if integer(round(bfp_sc)) <= 32767 then exit; end if;
          end loop;
          y_exp <= bfp_e;
          for j in 0 to DIM-1 loop
            if bfp_e >= 0 then bfp_sc := xb_att_r(j) * real(2**bfp_e);
            else               bfp_sc := xb_att_r(j) / real(2**(-bfp_e)); end if;
            bfp_rv := integer(round(bfp_sc));
            if bfp_rv >  32767 then bfp_rv :=  32767; end if;
            if bfp_rv < -32768 then bfp_rv := -32768; end if;
            y_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(bfp_rv, 16));
          end loop;
        end if;

        done <= '1';
      end if;  -- start
    end if;  -- rising_edge
  end process;

end architecture;
