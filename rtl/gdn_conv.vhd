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
-- THE CONFIG GROUP IS SAMPLED ONCE, AT S_PREP, AND cfg_taken SAYS WHEN.
-- tvalid, e_t and cw_exp are latched together at S_PREP and no port among them
-- is read again for the rest of the invocation.  cfg_taken pulses on the edge
-- that leaves S_PREP: after it the caller may change all three.  This is
-- defect B-3 (and B-3b) of docs/debugging/2026-08-27_B-interface-audit.md,
-- reproduced against the real gdn_exp_capture in
-- sim/tb_gdn_conv_tvalid_skew.vhd and written up in
-- docs/debugging/2026-08-27_gdn-conv-tvalid-skew.md.  See the tv_r declaration.
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
    -- CH_MAX is the LARGEST segment this instance can serve, not the segment
    -- it does serve.  B's three per-card segments are different sizes -- q
    -- 1,024, k 1,024, v 3,072 (3.2's derivation of conv width 5,120) -- so a
    -- compile-time channel count would need three separate instances, and the
    -- measured 16-DSP row would really be 48.  The actual length arrives on
    -- `nch` per invocation.  (2.1.3's "over its 2048 acc values" is the 0.8B's
    -- key_dim, the same stale dimensioning already corrected in 2.6's BRAM
    -- table; the 27B's segments are 1,024/1,024/3,072.)
    CH_MAX : positive := 256;  -- max channels in any segment on this instance
    K     : positive := 4;     -- ssm.conv_kernel
    LANES : positive := 8      -- channels per cycle; must divide CH_MAX
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    -- per segment
    nch    : in  integer range 0 to CH_MAX;        -- channels THIS segment
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
    ready   : out std_logic;                       -- pass A can accept a group
    -- ONE CYCLE, on the edge that leaves S_PREP.  The instant after which the
    -- per-segment config group (tvalid, e_t, cw_exp) may legally change.
    -- Before this existed the unit published NO such instant: `ready` is high
    -- for the whole of pass A, so it means "can accept a group", not "config
    -- taken", and o_done is a whole invocation late.  A sequencer that wants
    -- to prefetch the next segment's tap exponents had no observable safe
    -- edge, which is how B-3 became reachable in the first place.  Safe to
    -- leave unconnected.
    cfg_taken : out std_logic
  );
end entity;

architecture rtl of gdn_conv is

  constant NB    : integer := CH_MAX / LANES;    -- storage bound
  -- Group count for the segment in flight.  Latched at start so a caller
  -- changing nch mid-pass cannot split the two passes across two lengths --
  -- the same interface hazard tvalid already has.
  signal nbr : integer range 0 to NB := 0;
  constant LOG2L : integer := integer(ceil(log2(real(LANES))));
  constant SHAPE_OK : boolean := (2**LOG2L = LANES) and (NB * LANES = CH_MAX);

  type s34_arr is array (natural range <>) of signed(33 downto 0);
  type s16_arr is array (natural range <>) of signed(15 downto 0);
  type s32_arr is array (natural range <>) of signed(31 downto 0);
  type u34_arr is array (natural range <>) of unsigned(33 downto 0);
  type amem_t  is array (0 to NB-1) of std_logic_vector(LANES*34-1 downto 0);

  signal acc_mem : amem_t := (others => (others => '0'));

  -- per-invocation scalars, computed once
  signal shf   : integer_vector(0 to K-1) := (others => 0);
  signal e_ref : signed(15 downto 0) := (others => '0');
  -- THE MASK IS LATCHED, and this is defect B-3.  Pass-A stage 2 used to read
  -- the `tvalid` PORT combinationally, once per group, for the whole of pass A
  -- (384 cycles for the v segment) while shf and e_ref were derived once at
  -- S_PREP.  The natural producer, gdn_exp_capture, drives tvalid as a
  -- free-running level that is rewritten by any rd_req, so an ordinary
  -- prefetch of the NEXT segment's tap exponents moved the mask under the
  -- running conv: a tap invalid at S_PREP carries shf(t) = 0, and if it turned
  -- valid mid-pass its product was summed UNSHIFTED, on a grid up to 2^8 away.
  -- Reproduced end-to-end against the real producer in
  -- sim/tb_gdn_conv_tvalid_skew.vhd and written up in
  -- docs/debugging/2026-08-27_gdn-conv-tvalid-skew.md: the widening direction
  -- drags the segment amax, moves sh_seg 11 -> 13 and returns ALL 256 channels
  -- as the reference divided by four, with err_seg low and a legal e_seg.
  -- Latching here makes the mask and the shifts come from the same instant BY
  -- CONSTRUCTION, which is the entire fix.
  signal tv_r  : std_logic_vector(K-1 downto 0) := (others => '0');
  -- Same class, B-3b, and cheaper to close here than to argue about: cw_exp
  -- used to be read at S_FIN, hundreds of cycles after start.  A port read
  -- once at the END of a long operation is the least visible member of the
  -- class -- nothing in the unit's own behaviour changes if it moves, only the
  -- reported exponent.
  signal cw_r  : signed(7 downto 0) := (others => '0');
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

  -- synthesis translate_off
  -- The latch makes the LONG window (start .. last stage-2 read) safe.  It
  -- cannot make the SHORT one safe: the config group is still sampled across
  -- two edges, the `start` edge in S_IDLE and the S_PREP edge, and a producer
  -- that moves tvalid between them still splits the mask from the shifts.  No
  -- amount of latching fixes that; only a handshake would, and B-6 already
  -- records that cfg_taken is a pulse with no back-pressure.  So the residual
  -- window is CHECKED rather than closed, and checked loudly.
  signal chk_tv : std_logic_vector(K-1 downto 0);
  signal chk_et : std_logic_vector(K*8-1 downto 0);
  -- synthesis translate_on

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
        cfg_taken <= '0';
        vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0';
      else
        o_valid <= '0'; o_done <= '0'; cfg_taken <= '0';

        case state is

          when S_IDLE =>
            if start = '1' then
              assert SHAPE_OK
                report "gdn_conv: LANES must be a power of two dividing CH_MAX"
                severity failure;
              assert tvalid /= (tvalid'range => '0')
                report "gdn_conv: no valid taps -- e_ref would be undefined"
                severity failure;
              assert nch > 0 and (nch / LANES) * LANES = nch
                report "gdn_conv: nch must be a non-zero multiple of LANES"
                severity failure;
              nbr <= nch / LANES;          -- latched for BOTH passes
              amp <= (others => (others => '0'));
              err_seg <= '0';
              -- synthesis translate_off
              chk_tv <= tvalid; chk_et <= e_t;
              -- synthesis translate_on
              state <= S_PREP;
            end if;

          -- Its own state, and the whole point of the unit's shape: e_ref and
          -- the four alignment shifts are per SEGMENT, so they are derived
          -- once here and held.  A per-element derivation would put a min-tree
          -- and a subtract in front of every multiply.
          when S_PREP =>
            -- synthesis translate_off
            assert tvalid = chk_tv
              report "gdn_conv: tvalid moved between the start edge and "
                   & "cfg_taken -- the mask and the shifts now come from "
                   & "different instants (defect B-3's residual window)"
              severity failure;
            assert e_t = chk_et
              report "gdn_conv: e_t moved between the start edge and cfg_taken"
              severity failure;
            -- synthesis translate_on
            -- THE LATCH.  tvalid, e_t and cw_exp are all consumed HERE, at one
            -- instant, and nothing downstream reads the ports again.
            tv_r <= tvalid;
            cw_r <= cw_exp;
            cfg_taken <= '1';            -- observable on the edge leaving S_PREP
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
            if s_valid = '1' and idx < nbr then
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
                -- tv_r, NOT the tvalid PORT: see the tv_r declaration.  This
                -- one substitution is defect B-3's fix.
                if tv_r(t) = '1' then
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

            if idx >= nbr and vf = '0' and v1 = '0' and v2 = '0' and v3 = '0'
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
            if idx < nbr then
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

            if idx >= nbr and vf = '0' and v1 = '0' and v2 = '0' then
              state <= S_BDR;
            end if;

          when S_BDR =>
            state <= S_FIN;

          when S_FIN =>
            -- cw_r, NOT the cw_exp PORT: B-3b.
            e_seg  <= resize(e_ref + cw_r - shq, 8);
            sh_seg <= shq;
            -- 2.1.6: an out-of-int8 segment exponent is an ERROR to report,
            -- never a silent wrap.
            if (e_ref + cw_r - shq) > 127 or (e_ref + cw_r - shq) < -128 then
              err_seg <= '1';
            end if;
            o_done <= '1';
            state  <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
