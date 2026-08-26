-- gdn_recur: subsystem B's delta-rule recurrence, one column j of one head.
--
-- This is B 2.1.4 verbatim: stages 1-5, the whole loop that carries state
-- across tokens.  Everything else in B is feed-forward.
--
--   stage 1 decay      w[i]   = smant[i,j] * eg        w18 = round_shift(w,13)
--   stage 2 sk dot     sk_acc = sum w18[i] * k_n[i]    -> skm/ske (site 7)
--   stage 3 delta      e_d = min(e_v, ske)
--                      diff  = (v>>(e_v-e_d)) - (skm>>(ske-e_d))
--                      d_m   = round_shift(diff*beta, 16)
--   stage 4 update     kd[i] = k_n[i] * d_m            e_kd = 15 + e_d
--                      e_u   = tk0 ? e_kd : min(se_j+2, e_kd)
--                      u[i]  = tk0 ? kd[i] : (w18[i]>>su) + (kd[i]>>sk2)
--                      sh    = max(0, msb_pos(max|u|) - 14)
--                      smant_new = sat16(round_shift(u, sh))   se_new = e_u - sh
--   stage 5 out dot    o_acc  = sum smant_new[i] * q_s[i]      e_o = se_new + 18
--
-- WHY THE ACCUMULATORS ARE PER-LANE AND REDUCED ONCE, NOT PER CYCLE.  The
-- obvious form of stage 2 is one wide adder tree summing all LANES products
-- every cycle into a single sk_acc.  At LANES = 32 that is a 5-level tree of
-- s42 adds inside the throughput loop, and this project has already measured
-- what that costs: the same structure capped rmsnorm_rs at 200 MHz once it
-- reached 8 lanes.  Here each lane owns its own accumulator and nothing
-- crosses lanes during the sweep; the LANES partials are tree-reduced ONCE per
-- column, one level per cycle, off the throughput path.  Cost is
-- log2(LANES) cycles per reduction against 128/LANES cycles of work.  The same
-- shape is used for the o_acc sum and for the amax reduction.
--
-- WHY EVERY SHIFT IS A PER-INVOCATION SCALAR.  su, sk2, sh and their rounding
-- biases are computed once, in their own states, and held.  A per-element
-- shift amount would put a barrel shifter in the element loop; rmsnorm_rs's
-- history is that a barrel shift in series with anything else is what costs
-- the clock.  For the same reason no stage below performs two of {barrel
-- shift, wide add, compare, multiply} in one cycle -- the passes are longer
-- than they look precisely to keep those apart.
--
-- tk = 0 IS STRUCTURAL, NOT A CONSTANT.  At the first token of a sequence the
-- state read is skipped and the state term is dropped from the update AND from
-- e_u's minimum.  2.1.4 documents what happens if it is instead given an
-- exponent that participates in the min: e_u pins to ~2 against an e_kd of
-- ~28-32 and the entire first token's state is floored right by ~30 bits, a
-- ~1000x error that dilutes only as 1/t and is still visible at t ~ 1900.
-- Hence tk0 gates the term itself, and se_j never reaches the min.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;

entity gdn_recur is
  generic(
    DIM   : positive := 128;    -- state dimension; i and j both run over it
    LANES : positive := 8;      -- must be a power of two and divide DIM
    -- D_NORM normalizes d onto its OWN grid instead of inheriting e_d:
    --
    --   pinned      d_m = round_shift(diff*beta, 16)         e_dm = e_d
    --   normalized  shd = max(0, msb_pos(|diff*beta|) - 14)
    --               d_m = round_shift(diff*beta, shd)        e_dm = e_d+16-shd
    --
    -- The two are ONE code path: shd = 16 gives e_dm = e_d and reproduces the
    -- pinned form exactly, so the generic chooses shd and nothing else.  That
    -- is deliberate -- the pinned form is not a separate branch that could
    -- drift away from the one under test.
    --
    -- DEFAULT FALSE.  2.1.4 is a pinned contract that gdn_err.c, 2.10's
    -- precision result and 3.3's schedule all reference; this exists so the
    -- correction can be MEASURED end to end before anyone decides to adopt it.
    -- Measured over 224 physically realizable columns, state error in LSB:
    --                        median      p95       max   worst tk=0
    --   D_NORM = false        0.632     6.65   1218.04      1218.04
    --   D_NORM = true         0.600     1.29      3.47         1.11
    -- docs/debugging/2026-08-26_gdn-first-token-dm-grid.md
    D_NORM : boolean := false;
    -- TK0_ED: at tk = 0 the sk term is a MASKED ZERO, so ske is derived from a
    -- state that does not exist -- msb_pos(0) = 0 gives ske = se_j + 17 -- and
    -- it must not enter stage 3's grid minimum either.  That is the identical
    -- structural move 2.1.4 already makes for e_u at stage 4, applied one
    -- stage earlier, and the spec's own words demand it: "any future masked
    -- operand must leave the grid selection as well as the sum".
    --
    -- Left in, e_d = min(e_v, se_j + 17) floors v on a phantom grid BEFORE
    -- beta multiplies it, and D_NORM cannot recover that because normalizing
    -- zero is zero.
    --
    -- APPLY IT WITH D_NORM, NOT INSTEAD OF IT.  Measured over 288 physically
    -- realizable columns, worst state error in LSB and first tokens whose
    -- entire state is discarded:
    --                              p95        max   tk0 lost
    --   pinned                  4768.00    5189.00      3
    --   D_NORM alone           16558.63   37413.90      3   <- WORSE
    --   TK0_ED alone               9.92    1218.04      0
    --   both                       1.20       3.47      0
    -- D_NORM alone is worse than the pinned recipe: normalizing d amplifies
    -- the error the phantom grid already introduced.  The two are one
    -- amendment, not two independent ones.
    TK0_ED : boolean := false
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    -- per-column scalars
    tk0    : in  std_logic;                      -- first token of the sequence
    se_j   : in  signed(7 downto 0);             -- state column exponent
    eg     : in  unsigned(15 downto 0);          -- decay gate, <= 2^15
    beta   : in  unsigned(15 downto 0);          -- Q16
    -- v[j] is INT16 (2.1.3's format table).  The port is s16 rather than
    -- the s18 the delta stage works in, so the contract is carried by the
    -- TYPE: an out-of-range v cannot be presented at all, instead of
    -- silently overflowing diff's s18 several stages later.
    v_j    : in  signed(15 downto 0);            -- v[j]
    e_v    : in  signed(7 downto 0);
    -- vectors over i
    s_in   : in  std_logic_vector(DIM*16-1 downto 0);   -- state column mantissas
    k_n    : in  std_logic_vector(DIM*16-1 downto 0);   -- L2-normalised k, exp 15
    q_s    : in  std_logic_vector(DIM*16-1 downto 0);   -- scaled q, exp 18
    -- results
    s_out  : out std_logic_vector(DIM*16-1 downto 0);
    se_new : out signed(7 downto 0);
    o_acc  : out signed(39 downto 0);
    e_o    : out signed(7 downto 0);
    err_se : out std_logic;                      -- se_new outside int8, 2.1.6
    done   : out std_logic
  );
end entity;

architecture rtl of gdn_recur is

  constant NB    : integer := DIM / LANES;
  constant LOG2L : integer := integer(ceil(log2(real(LANES))));

  -- Structural requirements, asserted rather than assumed.  The lane reduction
  -- is a binary tree and the sweep is a whole number of groups.
  constant SHAPE_OK : boolean := (2**LOG2L = LANES) and (NB * LANES = DIM);

  type s16_arr  is array (natural range <>) of signed(15 downto 0);
  type s19_arr  is array (natural range <>) of signed(18 downto 0);
  type s33_arr  is array (natural range <>) of signed(32 downto 0);
  type s35_arr  is array (natural range <>) of signed(34 downto 0);
  type s42_arr  is array (natural range <>) of signed(41 downto 0);
  type u35_arr  is array (natural range <>) of unsigned(34 downto 0);

  -- w18 and u are the two arrays that must survive between passes.  w18 is
  -- written in pass A and read in pass B; u is written in pass B and read in
  -- pass C, because amax cannot be known until every u exists.
  signal w18a : s19_arr(0 to DIM-1) := (others => (others => '0'));
  signal ua   : s35_arr(0 to DIM-1) := (others => (others => '0'));

  -- per-lane accumulators, reduced once per column
  signal skp  : s42_arr(0 to LANES-1) := (others => (others => '0'));
  signal op   : s42_arr(0 to LANES-1) := (others => (others => '0'));
  signal amp  : u35_arr(0 to LANES-1) := (others => (others => '0'));

  -- pass pipelines
  signal sf, kf, qf     : s16_arr(0 to LANES-1) := (others => (others => '0'));
  signal k1, k2, q1, q2, q3 : s16_arr(0 to LANES-1) := (others => (others => '0'));
  signal m1   : s33_arr(0 to LANES-1) := (others => (others => '0'));
  signal w18r : s19_arr(0 to LANES-1) := (others => (others => '0'));
  signal m2   : s42_arr(0 to LANES-1) := (others => (others => '0'));
  signal mkd  : s35_arr(0 to LANES-1) := (others => (others => '0'));
  signal wf1  : s19_arr(0 to LANES-1) := (others => (others => '0'));
  signal ksr, wsr, ur : s35_arr(0 to LANES-1) := (others => (others => '0'));
  signal au   : u35_arr(0 to LANES-1) := (others => (others => '0'));
  signal uf   : s35_arr(0 to LANES-1) := (others => (others => '0'));
  signal ubr  : s35_arr(0 to LANES-1) := (others => (others => '0'));
  signal usr  : s35_arr(0 to LANES-1) := (others => (others => '0'));
  signal smr  : s16_arr(0 to LANES-1) := (others => (others => '0'));
  signal m3   : s42_arr(0 to LANES-1) := (others => (others => '0'));

  signal idx  : integer range 0 to DIM := 0;
  signal idxf, idx1, idx2, idx3, idx4 : integer range 0 to DIM := 0;
  signal vf, v1, v2, v3, v4, v5 : std_logic := '0';

  -- per-invocation scalars
  signal sk_acc : signed(41 downto 0) := (others => '0');
  signal skm    : signed(17 downto 0) := (others => '0');
  signal sk_abs : unsigned(41 downto 0) := (others => '0');
  signal sk_sh  : integer range 0 to 63 := 0;
  signal sk_bi  : signed(41 downto 0) := (others => '0');
  signal ske    : signed(15 downto 0) := (others => '0');
  signal e_d    : signed(15 downto 0) := (others => '0');
  signal ed_r   : signed(15 downto 0) := (others => '0');
  signal e_u    : signed(15 downto 0) := (others => '0');
  signal su, sk2, shq : integer range 0 to 63 := 0;
  signal bias_q : signed(34 downto 0) := (others => '0');
  signal diff   : signed(17 downto 0) := (others => '0');
  signal dmul   : signed(34 downto 0) := (others => '0');
  signal dabs   : unsigned(34 downto 0) := (others => '0');
  -- shd = 16 and dbias = 2^15 ARE the pinned recipe; D_NORM only overrides them
  signal shd    : integer range 0 to 63 := 16;
  signal dbias  : signed(34 downto 0) := to_signed(2**15, 35);
  signal d_m    : signed(17 downto 0) := (others => '0');
  signal red_n  : integer range 0 to LANES := LANES;
  signal s_reg  : std_logic_vector(DIM*16-1 downto 0) := (others => '0');

  type state_t is (S_IDLE,
                   S_A, S_ADR, S_SKRED, S_SKN1, S_SKN2, S_SKN3, S_SKN4,
                   S_D1, S_D2, S_D3, S_DN1, S_DN2, S_D4,
                   S_B, S_BDR, S_AMRED, S_SH,
                   S_C, S_CDR, S_ORED,
                   S_FIN);
  signal state : state_t := S_IDLE;

  -- msb position of an unsigned, 0 for zero: mv4i_msb_pos_u
  function msb_pos(a : unsigned) return integer is
    variable p : integer := 0;
  begin
    for i in a'low to a'high loop
      if a(i) = '1' then p := i - a'low; end if;
    end loop;
    return p;
  end function;

  function sat16(v : signed) return signed is
  begin
    if    v >  32767 then return to_signed( 32767, 16);
    elsif v < -32768 then return to_signed(-32768, 16);
    else                  return resize(v, 16); end if;
  end function;

begin

  process(clk)
    variable base  : integer;
    variable cmax  : unsigned(34 downto 0);
    variable amax  : unsigned(34 downto 0);
    variable half  : integer;
    variable p     : integer;
    variable ev_i, ske_i, ed_i, ekd_i, eu_i, sej_i : integer;
    variable q     : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; done <= '0'; err_se <= '0';
        vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0'; v5 <= '0';
      else
        done <= '0';

        case state is

          when S_IDLE =>
            if start = '1' then
              assert SHAPE_OK
                report "gdn_recur: LANES must be a power of two dividing DIM"
                severity failure;
              idx <= 0; idxf <= 0; idx1 <= 0; idx2 <= 0; idx3 <= 0; idx4 <= 0;
              vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0'; v5 <= '0';
              skp <= (others => (others => '0'));
              op  <= (others => (others => '0'));
              amp <= (others => (others => '0'));
              err_se <= '0';
              state <= S_A;
            end if;

          -- ============ pass A: decay, and the sk dot ======================
          -- F: fetch | 1: s*eg | 2: round to w18, store | 3: w18*k | 4: acc
          when S_A =>
            if idx < NB then
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                -- tk0 masks the state READ, so the decay product and w18 are
                -- structurally zero and the sk dot with them is zero too.
                if tk0 = '1' then
                  sf(k) <= (others => '0');
                else
                  sf(k) <= signed(s_in((base+k+1)*16-1 downto (base+k)*16));
                end if;
                kf(k) <= signed(k_n((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;

            v1 <= vf; idx1 <= idxf;
            for k in 0 to LANES-1 loop
              m1(k) <= resize(sf(k) * signed('0' & eg), 33);
              k1(k) <= kf(k);
            end loop;

            v2 <= v1; idx2 <= idx1;
            for k in 0 to LANES-1 loop
              -- site 6.  |w| <= 2^30 so w18 is s19, not s18: |w18| reaches
              -- exactly 2^17 at smant = -32768, eg = 32768.
              w18r(k) <= resize(shift_right(m1(k) + to_signed(2**12, 33), 13), 19);
              k2(k)   <= k1(k);
            end loop;
            if v1 = '1' then
              base := idx1 * LANES;
              for k in 0 to LANES-1 loop
                w18a(base+k) <= resize(shift_right(m1(k) + to_signed(2**12, 33), 13), 19);
              end loop;
            end if;

            v3 <= v2; idx3 <= idx2;
            for k in 0 to LANES-1 loop
              m2(k) <= resize(w18r(k) * k2(k), 42);
            end loop;

            v4 <= v3;
            if v3 = '1' then
              for k in 0 to LANES-1 loop
                skp(k) <= skp(k) + m2(k);
              end loop;
            end if;

            if idx >= NB and vf = '0' and v1 = '0' and v2 = '0' and v3 = '0' then
              state <= S_ADR; red_n <= LANES;
            end if;

          when S_ADR =>          -- drain the last accumulate
            state <= S_SKRED;

          -- one tree level per cycle, off the throughput path
          when S_SKRED =>
            half := red_n / 2;
            for k in 0 to LANES-1 loop
              if k < half then skp(k) <= skp(k) + skp(k + half); end if;
            end loop;
            if half <= 1 then state <= S_SKN1; else red_n <= half; end if;

          when S_SKN1 =>
            sk_acc <= skp(0);
            state  <= S_SKN2;

          -- Site 7: normalize sk to 16 bits, across THREE states.
          --
          -- Doing it in one costs the clock, measured: abs (a 42-bit negate),
          -- a 42-bit msb scan, a variable shift to build the rounding bias, a
          -- 42-bit add and a barrel shift, all in series -- 19 logic levels,
          -- 7 CARRY8, and the unit closed at 273 MHz instead of 300 with this
          -- as the single worst path at every LANES.  It is precisely the
          -- pattern this file's own header warns about, written anyway.
          -- Split: abs, then scan-and-derive, then shift.  Two extra cycles
          -- per column against 86.
          when S_SKN2 =>
            if sk_acc < 0 then sk_abs <= unsigned(-sk_acc);
            else               sk_abs <= unsigned( sk_acc); end if;
            state <= S_SKN3;

          when S_SKN3 =>
            p := msb_pos(sk_abs);
            if p - 14 > 0 then
              sk_sh <= p - 14;
              sk_bi <= shift_left(to_signed(1, 42), p - 15);
              ske   <= resize(se_j, 16) + 17 - (p - 14);
            else
              sk_sh <= 0;
              sk_bi <= (others => '0');
              ske   <= resize(se_j, 16) + 17;
            end if;
            state <= S_SKN4;

          when S_SKN4 =>
            skm   <= resize(shift_right(sk_acc + sk_bi, sk_sh), 18);
            state <= S_D1;

          -- ============ stage 3: the delta scalar ==========================
          when S_D1 =>
            ev_i  := to_integer(e_v);
            ske_i := to_integer(ske);
            if tk0 = '1' and TK0_ED then       ed_i := ev_i;
            elsif ev_i < ske_i then             ed_i := ev_i;
            else                                ed_i := ske_i; end if;
            e_d  <= to_signed(ed_i, 16);
            ed_r <= to_signed(ed_i, 16);
            state <= S_D2;

          when S_D2 =>
            -- Both shifts are right-only by construction (e_d is the min), and
            -- both are floor shifts: shift_right on signed is arithmetic.
            -- Counts clamped at 63 per 2.1.4.  For these operand widths a
            -- clamp changes no result -- anything past the width already
            -- yields 0 or -1 -- but the C reference MUST clamp, because there
            -- 1LL << 64 is undefined behaviour, so the clamp is stated on both
            -- sides rather than left implicit on one.
            -- Clamped at BOTH ends.  Upper: 2.1.4's rule, and the C reference
            -- must clamp because 1LL << 64 is undefined behaviour there.
            -- Lower: with TK0_ED the grid is e_v rather than the minimum, so
            -- ske - e_d goes NEGATIVE at tk = 0 -- and a negative shift_right
            -- is a bound-check FAILURE, not a wrong number, so it kills the
            -- simulation somewhere unrelated.  The C's floor_shr returns its
            -- operand unshifted for sh <= 0, which is what clamping to 0 does.
            p := to_integer(e_v - e_d);
            if p < 0 then p := 0; elsif p > 63 then p := 63; end if;
            q := to_integer(ske - e_d);
            if q < 0 then q := 0; elsif q > 63 then q := 63; end if;
            -- |v| <= 2^15 and |skm| <= 2^15, so |diff| <= 2^16 and s18 holds
            -- with a bit to spare.  Asserted rather than trusted: this is the
            -- off-by-one-bit class A's MA-1 documents, and w18 two stages back
            -- is s19 for exactly that reason.
            diff <= resize(shift_right(resize(v_j, 18), p), 18)
                  - resize(shift_right(skm, q), 18);
            state <= S_D3;

          when S_D3 =>
            assert diff < 131072 and diff > -131073
              report "gdn_recur: diff outside s18 -- v[j] exceeded int16?"
              severity failure;
            dmul <= resize(diff * signed('0' & beta), 35);
            if D_NORM then state <= S_DN1; else state <= S_D4; end if;

          when S_DN1 =>
            if dmul < 0 then dabs <= unsigned(-dmul);
            else             dabs <= unsigned( dmul); end if;
            state <= S_DN2;

          when S_DN2 =>
            -- Its own state, like site 7's: an msb scan in series with the
            -- round-shift that uses it is the pattern that costs the clock.
            p := msb_pos(dabs);
            if p - 14 > 0 then
              shd   <= p - 14;
              dbias <= shift_left(to_signed(1, 35), p - 15);
            else
              shd   <= 0;
              dbias <= (others => '0');
            end if;
            state <= S_D4;

          when S_D4 =>
            d_m <= resize(shift_right(dmul + dbias, shd), 18);
            -- e_u, and with it every shift pass B needs, is fixed here so the
            -- element loop carries no exponent arithmetic at all.
            sej_i := to_integer(se_j) + 2;
            -- e_kd = 15 + e_dm, and e_dm = e_d + 16 - shd.  With the pinned
            -- shd = 16 this is 15 + e_d, exactly as before.
            ekd_i := 15 + to_integer(ed_r) + 16 - shd;
            if tk0 = '1' then
              eu_i := ekd_i;                 -- the masked zero has no exponent
            elsif sej_i < ekd_i then
              eu_i := sej_i;
            else
              eu_i := ekd_i;
            end if;
            e_u <= to_signed(eu_i, 16);
            p := sej_i - eu_i; if p < 0 then p := 0; elsif p > 63 then p := 63; end if;
            q := ekd_i - eu_i; if q < 0 then q := 0; elsif q > 63 then q := 63; end if;
            su <= p; sk2 <= q;
            idx <= 0; idxf <= 0; idx1 <= 0; idx2 <= 0; idx3 <= 0;
            vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0'; v5 <= '0';
            state <= S_B;

          -- ============ pass B: the update, and amax =======================
          -- F: fetch | 1: k*d_m | 2: two shifts | 3: add, store u | 4: abs |
          -- 5: per-lane max
          when S_B =>
            if idx < NB then
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                kf(k) <= signed(k_n((base+k+1)*16-1 downto (base+k)*16));
                wf1(k) <= w18a(base+k);
              end loop;
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;

            v1 <= vf; idx1 <= idxf;
            for k in 0 to LANES-1 loop
              mkd(k) <= resize(kf(k) * d_m, 35);
              w18r(k) <= wf1(k);
            end loop;

            v2 <= v1; idx2 <= idx1;
            for k in 0 to LANES-1 loop
              ksr(k) <= shift_right(mkd(k), sk2);
              -- tk0: the state term is dropped entirely, not shifted.  With
              -- e_u = e_kd the shift su would be NEGATIVE, and a negative
              -- shift here is a left shift of a value that must not exist.
              if tk0 = '1' then wsr(k) <= (others => '0');
              else              wsr(k) <= shift_right(resize(w18r(k), 35), su); end if;
            end loop;

            v3 <= v2; idx3 <= idx2;
            for k in 0 to LANES-1 loop
              ur(k) <= ksr(k) + wsr(k);
            end loop;
            if v2 = '1' then
              base := idx2 * LANES;
              for k in 0 to LANES-1 loop
                ua(base+k) <= ksr(k) + wsr(k);
              end loop;
            end if;

            v4 <= v3;
            for k in 0 to LANES-1 loop
              if ur(k) < 0 then au(k) <= unsigned(-ur(k));
              else               au(k) <= unsigned( ur(k)); end if;
            end loop;

            v5 <= v4;
            if v4 = '1' then
              for k in 0 to LANES-1 loop
                if au(k) > amp(k) then amp(k) <= au(k); end if;
              end loop;
            end if;

            if idx >= NB and vf = '0' and v1 = '0' and v2 = '0'
               and v3 = '0' and v4 = '0' then
              state <= S_BDR; red_n <= LANES;
            end if;

          when S_BDR =>
            state <= S_AMRED;

          when S_AMRED =>
            half := red_n / 2;
            for k in 0 to LANES-1 loop
              if k < half then
                if amp(k + half) > amp(k) then amp(k) <= amp(k + half); end if;
              end if;
            end loop;
            if half <= 1 then
              state <= S_SH;
            else
              red_n <= half;
            end if;

          when S_SH =>
            amax := amp(0);
            p := msb_pos(amax);
            if p - 14 > 0 then
              shq    <= p - 14;
              bias_q <= shift_left(to_signed(1, 35), p - 15);
            else
              shq    <= 0;
              bias_q <= (others => '0');     -- bfp_pack: no bias when sh = 0
            end if;
            idx <= 0; idxf <= 0; idx1 <= 0; idx2 <= 0; idx3 <= 0;
            vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0'; v5 <= '0';
            state <= S_C;

          -- ============ pass C: requantize, and the output dot =============
          -- F: fetch | 1: +bias | 2: shift | 3: sat16, store | 4: *q | 5: acc
          when S_C =>
            if idx < NB then
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                uf(k) <= ua(base+k);
                qf(k) <= signed(q_s((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;

            v1 <= vf; idx1 <= idxf;
            for k in 0 to LANES-1 loop
              ubr(k) <= uf(k) + bias_q;
              q1(k)  <= qf(k);
            end loop;

            v2 <= v1; idx2 <= idx1;
            for k in 0 to LANES-1 loop
              usr(k) <= shift_right(ubr(k), shq);
              q2(k)  <= q1(k);
            end loop;

            v3 <= v2; idx3 <= idx2;
            for k in 0 to LANES-1 loop
              smr(k) <= sat16(usr(k));
              q3(k)  <= q2(k);
            end loop;
            if v2 = '1' then
              base := idx2 * LANES;
              for k in 0 to LANES-1 loop
                s_reg((base+k+1)*16-1 downto (base+k)*16)
                  <= std_logic_vector(sat16(usr(k)));
              end loop;
            end if;

            v4 <= v3;
            for k in 0 to LANES-1 loop
              -- stage 5 uses the REQUANTIZED mantissa, so the emitted output is
              -- bit-consistent with the stored state, as 2.1.4 requires.
              m3(k) <= resize(smr(k) * q3(k), 42);
            end loop;

            v5 <= v4;
            if v4 = '1' then
              for k in 0 to LANES-1 loop
                op(k) <= op(k) + m3(k);
              end loop;
            end if;

            if idx >= NB and vf = '0' and v1 = '0' and v2 = '0'
               and v3 = '0' and v4 = '0' then
              state <= S_CDR; red_n <= LANES;
            end if;

          when S_CDR =>
            state <= S_ORED;

          when S_ORED =>
            half := red_n / 2;
            for k in 0 to LANES-1 loop
              if k < half then op(k) <= op(k) + op(k + half); end if;
            end loop;
            if half <= 1 then state <= S_FIN; else red_n <= half; end if;

          when S_FIN =>
            s_out  <= s_reg;
            o_acc  <= resize(op(0), 40);
            se_new <= resize(e_u - shq, 8);
            e_o    <= resize(e_u - shq + 18, 8);
            -- 2.1.6: the column exponent is int8 and an out-of-range value is
            -- an error to be reported, never silently wrapped.
            -- e_o = se_new + 18 is a separate int8 output and was not
            -- checked: se_new in [110,127] is in range while e_o wraps.
            if (e_u - shq) > 127 or (e_u - shq) < -128
               or (e_u - shq + 18) > 127 or (e_u - shq + 18) < -128 then
              err_se <= '1';
            end if;
            done  <= '1';
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
