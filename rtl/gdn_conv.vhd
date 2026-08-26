-- gdn_conv: subsystem B's depthwise causal convolution, spec 2.1.3.
--
-- Depthwise, kernel 4, no bias, no fused activation (1.4(e)).  One segment per
-- invocation; the three segments per layer (q, k, v) are separate calls.
--
--   e_ref  = min over VALID t of e_t                    -- per segment, scalar
--   p_t    = x_t * w_t                                  -- s32, |p| <= 2^30
--   acc[c] = sum over VALID t of ( p_t >> (e_t - e_ref) )   -- floor, s34
--   e_acc  = e_ref + cw_exp
--   then bfp_pack over the segment: amax, sh_seg = max(0, msb_pos(amax) - 14),
--        sm[c] = sat16(round_shift(acc[c], sh_seg)),  e_seg = e_acc - sh_seg
--
-- WHY THE TAP EXPONENTS ARE SCALARS.  e_t is a property of the conv state
-- SLOT, not of the channel, so every channel of a segment shares all four --
-- which is what lets the segment carry a single e_seg, and what lets e_ref and
-- the four alignment shifts be computed ONCE per invocation instead of per
-- element.  No barrel shifter appears in the channel loop.
--
-- INVALID TAPS LEAVE THE MINIMUM AS WELL AS THE SUM.  At the start of a
-- sequence the older slots hold no token (1.6), and 2.1.3 requires those taps
-- to be excluded from BOTH the products AND e_ref's minimum.  This is not a
-- detail: 2.1.4 violated the same rule twice, once by letting a masked zero's
-- exponent into e_u's minimum (found 2026-08-25, ~1000x error on the first
-- token) and once by letting a masked sk's phantom exponent into e_d's
-- (found 2026-08-26, the first token's state discarded entirely).  An invalid
-- tap's exponent describes nothing, so a minimum over it is arbitrary rather
-- than conservative.
--
-- The unit is two passes because amax cannot be known until every acc exists:
-- pass A streams the channels and accumulates, pass B requantizes.  acc is
-- held in a group-wide memory rather than a per-element register file, for the
-- same reason gdn_recur_pipe does it -- a DIM-element file behind a wide mux
-- is what cost rmsnorm_rs 257 MHz.
-- NOTE ON NAMING, learned the hard way here: the lane loop index is `ln`, not
-- `k`.  VHDL is case-insensitive, so a `for k in ...` loop SHADOWS the generic
-- `K` (the conv kernel), and every `0 to K-1` tap loop nested inside it then
-- runs to the LANE index instead.  At LANES = 16 that overruns the tap arrays
-- and dies; at LANES = 4 it silently sums FEWER TAPS and returns wrong numbers
-- with no error at all.  GHDL warns (-Whide) and the warning is easy to miss
-- among the others.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;

entity gdn_conv is
  generic(
    CH    : positive := 256;   -- channels in this segment
    K     : positive := 4;     -- ssm.conv_kernel
    LANES : positive := 8      -- channels per cycle; must divide CH
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    -- per segment
    tvalid : in  std_logic_vector(K-1 downto 0);   -- tap t valid (1.6)
    e_t    : in  std_logic_vector(K*8-1 downto 0); -- per-slot exponents, int8
    cw_exp : in  signed(7 downto 0);
    -- channel stream: LANES channels per cycle, K taps each
    s_valid : in  std_logic;
    x_in    : in  std_logic_vector(K*LANES*16-1 downto 0);
    w_in    : in  std_logic_vector(K*LANES*16-1 downto 0);
    -- output stream, same order
    o_valid : out std_logic;
    o_data  : out std_logic_vector(LANES*16-1 downto 0);
    -- per segment, valid with o_done
    o_done  : out std_logic;
    e_seg   : out signed(7 downto 0);
    sh_seg  : out integer range 0 to 63;
    err_seg : out std_logic;
    ready   : out std_logic                        -- pass A can accept a group
  );
end entity;

architecture rtl of gdn_conv is

  constant NB    : integer := CH / LANES;
  constant LOG2L : integer := integer(ceil(log2(real(LANES))));
  constant SHAPE_OK : boolean := (2**LOG2L = LANES) and (NB * LANES = CH);

  type s34_arr is array (natural range <>) of signed(33 downto 0);
  type s16_arr is array (natural range <>) of signed(15 downto 0);
  type s32_arr is array (natural range <>) of signed(31 downto 0);
  type u34_arr is array (natural range <>) of unsigned(33 downto 0);
  type amem_t  is array (0 to NB-1) of std_logic_vector(LANES*34-1 downto 0);

  signal acc_mem : amem_t := (others => (others => '0'));

  -- per-invocation scalars, computed once
  signal shf   : integer_vector(0 to K-1) := (others => 0);
  signal e_ref : signed(15 downto 0) := (others => '0');
  signal amax  : unsigned(33 downto 0) := (others => '0');
  signal amp   : u34_arr(0 to LANES-1) := (others => (others => '0'));
  signal shq   : integer range 0 to 63 := 0;
  signal bias  : signed(33 downto 0) := (others => '0');

  -- pass pipelines
  type pk_arr is array (0 to K-1) of s32_arr(0 to LANES-1);
  type xk_arr is array (0 to K-1) of s16_arr(0 to LANES-1);
  signal xf, wf : xk_arr := (others => (others => (others => '0')));
  signal p1     : pk_arr := (others => (others => (others => '0')));
  signal p2     : pk_arr := (others => (others => (others => '0')));
  signal accr   : s34_arr(0 to LANES-1) := (others => (others => '0'));
  signal au     : u34_arr(0 to LANES-1) := (others => (others => '0'));
  signal uf, ub, us : s34_arr(0 to LANES-1) := (others => (others => '0'));

  signal idx : integer range 0 to NB := 0;
  signal idxf, idx1, idx2, idx3 : integer range 0 to NB := 0;
  signal vf, v1, v2, v3, v4 : std_logic := '0';
  signal red_n : integer range 0 to LANES := LANES;

  type state_t is (S_IDLE, S_PREP, S_A, S_ADR, S_AMRED, S_SH, S_B, S_BDR, S_FIN);
  signal state : state_t := S_IDLE;

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

  ready <= '1' when state = S_A else '0';

  process(clk)
    variable base : integer;
    variable half : integer;
    variable p    : integer;
    variable emin : integer;
    variable have : boolean;
    variable et   : integer;
    variable pk   : std_logic_vector(LANES*34-1 downto 0);
    variable sum  : signed(33 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; o_valid <= '0'; o_done <= '0'; err_seg <= '0';
        vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0';
      else
        o_valid <= '0'; o_done <= '0';

        case state is

          when S_IDLE =>
            if start = '1' then
              assert SHAPE_OK
                report "gdn_conv: LANES must be a power of two dividing CH"
                severity failure;
              assert tvalid /= (tvalid'range => '0')
                report "gdn_conv: no valid taps -- e_ref would be undefined"
                severity failure;
              amp <= (others => (others => '0'));
              err_seg <= '0';
              state <= S_PREP;
            end if;

          -- Its own state, and the whole point of the unit's shape: e_ref and
          -- the four alignment shifts are per SEGMENT, so they are derived
          -- once here and held.  A per-element derivation would put a min-tree
          -- and a subtract in front of every multiply.
          when S_PREP =>
            emin := 0; have := false;
            for t in 0 to K-1 loop
              if tvalid(t) = '1' then
                et := to_integer(signed(e_t((t+1)*8-1 downto t*8)));
                if not have or et < emin then emin := et; have := true; end if;
              end if;
            end loop;
            e_ref <= to_signed(emin, 16);
            for t in 0 to K-1 loop
              if tvalid(t) = '1' then
                et := to_integer(signed(e_t((t+1)*8-1 downto t*8))) - emin;
                if et > 63 then et := 63; elsif et < 0 then et := 0; end if;
                shf(t) <= et;
              else
                shf(t) <= 0;
              end if;
            end loop;
            idx <= 0; idxf <= 0; idx1 <= 0; idx2 <= 0; idx3 <= 0;
            vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0';
            state <= S_A;

          -- ===== pass A: the MACs =========================================
          -- F: fetch | 1: K multiplies | 2: K aligns | 3: sum, store | 4: amax
          when S_A =>
            if s_valid = '1' and idx < NB then
              for t in 0 to K-1 loop
                for ln in 0 to LANES-1 loop
                  base := (t*LANES + ln) * 16;
                  xf(t)(ln) <= signed(x_in(base+15 downto base));
                  wf(t)(ln) <= signed(w_in(base+15 downto base));
                end loop;
              end loop;
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;

            v1 <= vf; idx1 <= idxf;
            for t in 0 to K-1 loop
              for ln in 0 to LANES-1 loop
                p1(t)(ln) <= resize(xf(t)(ln) * wf(t)(ln), 32);
              end loop;
            end loop;

            v2 <= v1; idx2 <= idx1;
            for t in 0 to K-1 loop
              for ln in 0 to LANES-1 loop
                -- INVALID TAPS CONTRIBUTE NOTHING.  Zeroed here rather than
                -- skipped in the sum so the adder tree is a fixed shape.
                if tvalid(t) = '1' then
                  p2(t)(ln) <= shift_right(p1(t)(ln), shf(t));
                else
                  p2(t)(ln) <= (others => '0');
                end if;
              end loop;
            end loop;

            v3 <= v2; idx3 <= idx2;
            for ln in 0 to LANES-1 loop
              sum := (others => '0');
              for t in 0 to K-1 loop
                sum := sum + resize(p2(t)(ln), 34);
              end loop;
              accr(ln) <= sum;
              pk((ln+1)*34-1 downto ln*34) := std_logic_vector(sum);
            end loop;
            if v2 = '1' then
              acc_mem(idx2) <= pk;
            end if;

            v4 <= v3;
            for ln in 0 to LANES-1 loop
              if accr(ln) < 0 then au(ln) <= unsigned(-accr(ln));
              else                 au(ln) <= unsigned( accr(ln)); end if;
            end loop;
            -- Gated on v4, NOT v3: au is assigned from accr in this same
            -- block, so it becomes valid one stage LATER, together with v4.
            -- Gating on v3 folded the previous group's magnitudes in against
            -- this group's valid flag and dropped the last group entirely --
            -- visible only on the all-zero cases, where a stale magnitude
            -- from the PREVIOUS case survived into amax and produced
            -- sh_seg = 15 where the answer is 0.  Same pipeline-index class as
            -- l2norm_rs's emit gating, and again invisible to the cases that
            -- happen to have similar magnitudes throughout.
            if v4 = '1' then
              for ln in 0 to LANES-1 loop
                if au(ln) > amp(ln) then amp(ln) <= au(ln); end if;
              end loop;
            end if;

            if idx >= NB and vf = '0' and v1 = '0' and v2 = '0' and v3 = '0'
               and v4 = '0' then
              state <= S_ADR; red_n <= LANES;
            end if;

          when S_ADR =>
            state <= S_AMRED;

          when S_AMRED =>
            half := red_n / 2;
            for ln in 0 to LANES-1 loop
              if ln < half then
                if amp(ln + half) > amp(ln) then amp(ln) <= amp(ln + half); end if;
              end if;
            end loop;
            if half <= 1 then state <= S_SH; else red_n <= half; end if;

          when S_SH =>
            amax <= amp(0);
            p := msb_pos(amp(0));
            if p - 14 > 0 then
              shq  <= p - 14;
              bias <= shift_left(to_signed(1, 34), p - 15);
            else
              -- bfp_pack: no rounding bias at all when sh = 0
              shq  <= 0;
              bias <= (others => '0');
            end if;
            idx <= 0; idxf <= 0; idx1 <= 0; idx2 <= 0;
            vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0';
            state <= S_B;

          -- ===== pass B: the segment requantizer ==========================
          -- F: fetch | 1: +bias | 2: shift | 3: sat16 out
          when S_B =>
            if idx < NB then
              for ln in 0 to LANES-1 loop
                uf(ln) <= signed(acc_mem(idx)((ln+1)*34-1 downto ln*34));
              end loop;
              vf <= '1'; idx <= idx + 1;
            else
              vf <= '0';
            end if;

            v1 <= vf;
            for ln in 0 to LANES-1 loop
              ub(ln) <= uf(ln) + bias;
            end loop;

            v2 <= v1;
            for ln in 0 to LANES-1 loop
              us(ln) <= shift_right(ub(ln), shq);
            end loop;

            v3 <= v2;
            o_valid <= v2;
            if v2 = '1' then
              for ln in 0 to LANES-1 loop
                o_data((ln+1)*16-1 downto ln*16) <= std_logic_vector(sat16(us(ln)));
              end loop;
            end if;

            if idx >= NB and vf = '0' and v1 = '0' and v2 = '0' then
              state <= S_BDR;
            end if;

          when S_BDR =>
            state <= S_FIN;

          when S_FIN =>
            e_seg  <= resize(e_ref + cw_exp - shq, 8);
            sh_seg <= shq;
            -- 2.1.6: an out-of-int8 segment exponent is an ERROR to report,
            -- never a silent wrap.
            if (e_ref + cw_exp - shq) > 127 or (e_ref + cw_exp - shq) < -128 then
              err_seg <= '1';
            end if;
            o_done <= '1';
            state  <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
