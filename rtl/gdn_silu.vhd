-- rtl/gdn_silu.vhd -- silu over a BFP segment, spec 2.1.3.
--
--   x_q12 = Q12(sm, e)                                 -- 2.1.3 site 3
--   sm'   = round_shift( sm * sigma_q15(x_q12), 15 )   -- exponent PRESERVED
--
-- The exponent is preserved because abs(silu(x)) <= abs(x) (sigma <= 1), so
-- sm' cannot leave int16 on the same grid: no re-scan, no saturation, and the
-- segment exponent passes through untouched.  That is asserted below rather
-- than assumed, because it is the property the whole no-rescan structure rests
-- on and it is one algebra slip away from being false.
--
-- WHY sigma IS Q12-IN / Q15-OUT, WHICH THE SHIPPED TABLE IS NOT.
-- fixed_pkg's sigmoid_q takes one Q for input and output.  2.1 pins silu's
-- ARGUMENT at Q12 -- silu's error does not compound, unlike the scalar path's,
-- which 2.1.3 moved to Q18 -- and the sigma OUTPUT at Q15.  B's reuse table
-- already records that the shipped Q12-in/Q12-out form must be regenerated for
-- this.  It is regenerated here as a mixed-precision READ of the same Q30
-- SIG_ROM, not as a second table: only the index grid and the final rounding
-- differ, so there is nothing to keep in step.
--
-- THE INDEX NEEDS NO MULTIPLY.  fx.h computes idx_fp = (z + 16*one_q) * 16 and
-- then k = idx_fp >> q, frac = idx_fp - (k << q).  At q = 12 that is exactly
-- k = offset >> 8 and frac = offset(7 downto 0) & "0000".  Bit-identical, and
-- it removes a multiply and a wide shift from every lane.
--
-- STRUCTURE.  One stage per hazard, per the project's rule that no two of
-- {barrel shift, wide add, wide compare, bus mux, multiply} may sit in series
-- in one state:
--
--   S0  barrel shift        Q12 conversion (both branches, saturating)
--   S1  index + range test  k, frac, and the two rails
--   S2  ROM read            lo and delta, registered
--   S3  multiply            delta * frac
--   S4  add + round         interp_q30 -> sigma_q15, clamped
--   S5  multiply            sm * sigma_q15
--   S6  round + emit        round_shift(.., 15)
--
-- Fully pipelined: one LANES-group per cycle, II = 1, latency 7.  sm is
-- carried alongside because stage 5 needs the ORIGINAL mantissa, not the
-- Q12-converted one -- using x_q12 there is the obvious wrong turn and would
-- be silently near-right whenever e happens to be 12.
--
-- swiglu.vhd's header records what NOT to do here: N parallel copies of the
-- sigmoid-plus-two-multiply chain cost 360 DSP and 100% of that device.  The
-- cost per lane here is 2 DSP and the ROM, and LANES is a generic precisely so
-- the trade is measured rather than argued.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_luts_pkg.all;

entity gdn_silu is
  generic(
    LANES : positive := 4;
    -- The argument grid.  2.1.3 pins 12; exposed so the cost of moving it can
    -- be measured the way SP_Q's was, not so it can be changed casually.
    ARG_Q : integer range 8 to 20 := 12
  );
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    -- Segment exponent, held stable across the segment's groups.
    e_seg   : in  signed(7 downto 0);
    s_valid : in  std_logic;
    s_data  : in  std_logic_vector(LANES*16-1 downto 0);
    o_valid : out std_logic;
    o_data  : out std_logic_vector(LANES*16-1 downto 0)
  );
end entity;

architecture rtl of gdn_silu is

  constant ONE_Q : integer := 2**ARG_Q;
  -- The table spans z in [-16, 16] over 512 intervals, so the rails are at
  -- +-16 in Q(ARG_Q) and the index step is 16 units of z per LSB of k.
  constant RAIL  : integer := 16 * ONE_Q;

  -- The interpolation delta is narrowed to 25 bits ON PURPOSE, and the bound
  -- is checked at elaboration rather than trusted.  A DSP48E2 multiplier is
  -- 27x18 signed; at 32 bits the delta*frac product needs TWO of them, which
  -- measured as 3 DSP per lane instead of 2 (12 against 8 at LANES = 4).  The
  -- table's largest adjacent difference is 16,771,757, just under 2^24, so 25
  -- bits signed is exact -- not a truncation, and the assert below fails the
  -- build rather than silently wrapping if the ROM is ever regenerated with a
  -- coarser grid or a wider Q.
  function sig_rom_max_delta return integer is
    variable m, d : integer := 0;
  begin
    for i in 0 to 511 loop
      d := SIG_ROM(i+1) - SIG_ROM(i);
      if d < 0 then d := -d; end if;
      if d > m then m := d; end if;
    end loop;
    return m;
  end function;
  constant SIG_DMAX : integer := sig_rom_max_delta;

  type s25_arr is array (0 to LANES-1) of signed(24 downto 0);
  -- sigma is narrowed for the SAME reason as the delta, and it is the one that
  -- actually cost the third DSP.  It only ever holds 0 .. 32768, but declared
  -- 32 bits wide the sm * sigma multiply is 16x32 and takes two DSP48E2s.
  -- At 18 bits it is 16x18, which is exactly the primitive's B port.
  -- Narrowing the delta alone moved LUT and FF and left DSP at 3 per lane;
  -- only after both is it 2, which is what 2.8's micro_silu_narrow measured
  -- and what this unit now confirms.
  type s18_arr is array (0 to LANES-1) of signed(17 downto 0);
  type s32_arr is array (0 to LANES-1) of signed(31 downto 0);
  type s16_arr is array (0 to LANES-1) of signed(15 downto 0);
  type s64_arr is array (0 to LANES-1) of signed(63 downto 0);
  type idx_arr is array (0 to LANES-1) of integer range 0 to 511;
  type frc_arr is array (0 to LANES-1) of unsigned(ARG_Q-1 downto 0);
  type rail_arr is array (0 to LANES-1) of integer range -1 to 1;

  -- Round-half-toward-+infinity right shift, the project's round_shift.
  function rsh_r(v : signed; sh : natural) return signed is
  begin
    if sh = 0 then return v; end if;
    return shift_right(v + shift_left(to_signed(1, v'length), sh-1), sh);
  end function;

  -- ---- THE PER-LANE SHIFT CONTROL, AND WHY IT IS SIXTEEN REGISTERS -------
  --
  -- MEASURED post-route on xcvu33p-fsvh2104-2LV-e at 0.717 V, gdn_emit_chain
  -- at HEADS=24 DIM=128 SILU_LANES=16 RMS_LANES=4, 3.3 ns target: the binding
  -- path is
  --
  --   si_e_seg_reg[4]_replica/C -> u_silu/xq_reg[7][22]/D
  --   Fmax 216.51, WNS -1.320, logic 1.753 ns, NET 2.812 ns
  --
  -- and it is the SAME path that binds at 0.85 V, so it is not a low-voltage
  -- artefact.  It is the third time this path has surfaced: it is already the
  -- recorded reason SILU_LANES went 32 -> 16 (gdn_emit_chain.vhd:82).
  --
  -- IT IS A ROUTING PROBLEM, NOT A DEPTH PROBLEM.  2.812 ns of net against
  -- 1.753 ns of logic, and the fanout report names the cause: the shift
  -- control net reaches fanout 783, and Vivado had already replicated the
  -- source register ON ITS OWN (`si_e_seg_reg[4]_replica`), which is what it
  -- does when one net cannot reach all its loads in time.  Eight bits of
  -- e_seg, through one subtract and four comparisons, were steering the shift
  -- of LANES lanes of 64-bit barrel shifter spread across the die.
  --
  -- So the control is decoded ONCE and then held in LANES SEPARATE COPIES,
  -- one per lane, each of which the placer can put next to the lane it
  -- drives.  One net of 783 loads becomes LANES nets of about 783/LANES.  The
  -- subtract and the four comparisons move off the critical path at the same
  -- time, because they are now in front of a register rather than behind one.
  --
  -- DONT_TOUCH IS LOAD BEARING.  Sixteen registers with identical inputs are
  -- exactly what equivalent-register-removal exists to merge, and a merged
  -- copy is the original 783-load net back again with extra area.  The
  -- tradeoff is real and is stated rather than hidden: DONT_TOUCH also stops
  -- Vivado doing its OWN further replication, so if 783/LANES per lane is
  -- still too many, this attribute is the thing standing in the way and the
  -- next step is either per-lane-per-stage copies or swapping it for
  -- MAX_FANOUT.  That is a measurement, and it has not been made.
  --
  -- THE COST IS ONE CYCLE OF LEAD ON e_seg, and it is CHECKED, not assumed.
  -- The control used at cycle T is decoded from e_seg at T-1, so a caller
  -- must have e_seg settled one cycle before the first beat and hold it for
  -- the segment.  The assertion below fails the simulation if it does not.
  -- Verified at all three call sites; see the lead table in
  -- docs/debugging/2026-08-27_gdn-silu-shift-control-fanout.md.
  --
  -- The mode encoding is the same five-way branch S0 always had, decoded once
  -- instead of once per lane.  Nothing about the arithmetic changes, which is
  -- why every existing vector is still bit-exact.
  constant M_ZERO : std_logic_vector(2 downto 0) := "000";  -- sh > 62
  constant M_RSH  : std_logic_vector(2 downto 0) := "001";  -- 0 < sh <= 62
  constant M_PASS : std_logic_vector(2 downto 0) := "010";  -- sh = 0
  constant M_RAIL : std_logic_vector(2 downto 0) := "011";  -- -sh > 40
  constant M_LSH  : std_logic_vector(2 downto 0) := "100";  -- -40 <= sh < 0

  type mode_arr is array (0 to LANES-1) of std_logic_vector(2 downto 0);
  type amt_arr  is array (0 to LANES-1) of integer range 0 to 62;
  signal c_mode : mode_arr := (others => M_PASS);
  signal c_amt  : amt_arr  := (others => 0);

  attribute dont_touch : string;
  attribute dont_touch of c_mode : signal is "true";
  attribute dont_touch of c_amt  : signal is "true";

  -- The previous cycle's e_seg, for the lead check only.  No fabric: it feeds
  -- nothing but an assertion.
  signal eseg_r : signed(7 downto 0) := (others => '0');

  signal v0, v1, v2, v3, v4, v5, v6 : std_logic := '0';
  signal xq   : s32_arr := (others => (others => '0'));
  signal sm0, sm1, sm2, sm3, sm4, sm5 : s16_arr := (others => (others => '0'));
  signal kk   : idx_arr := (others => 0);
  signal fr   : frc_arr := (others => (others => '0'));
  signal rl   : rail_arr := (others => 0);
  signal rl1, rl2, rl3 : rail_arr := (others => 0);
  signal lo   : s32_arr := (others => (others => '0'));
  signal dl   : s25_arr := (others => (others => '0'));
  signal fr2  : frc_arr := (others => (others => '0'));
  signal pr   : s64_arr := (others => (others => '0'));
  signal lo3  : s32_arr := (others => (others => '0'));
  signal sig  : s18_arr := (others => (others => '0'));
  signal prod : s64_arr := (others => (others => '0'));

begin

  assert SIG_DMAX < 2**24
    report "gdn_silu: SIG_ROM's largest adjacent delta is "
         & integer'image(SIG_DMAX) & ", which does not fit the 25-bit signed "
         & "interpolation path.  Widen dl and re-measure the DSP cost."
    severity failure;

  process(clk)
    variable sh   : integer;
    variable v    : signed(63 downto 0);
    variable offu : unsigned(31 downto 0);
    variable itp  : signed(63 downto 0);
    variable sg   : signed(63 downto 0);
    variable y    : signed(63 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        v0 <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0';
        v4 <= '0'; v5 <= '0'; v6 <= '0'; o_valid <= '0';
      else
        -- ---- S-1: decode the shift control, once, into LANES copies -------
        -- In FRONT of the pipeline, not inside it.  The subtract and the four
        -- comparisons that used to sit between e_seg and every lane's barrel
        -- shifter are here, and what crosses into S0 is a decoded mode and an
        -- amount, held per lane.  See the declaration of c_mode.
        sh := to_integer(e_seg) - ARG_Q;
        for k in 0 to LANES-1 loop
          if sh > 62 then
            c_mode(k) <= M_ZERO; c_amt(k) <= 0;
          elsif sh > 0 then
            c_mode(k) <= M_RSH;  c_amt(k) <= sh;
          elsif sh = 0 then
            c_mode(k) <= M_PASS; c_amt(k) <= 0;
          elsif -sh > 40 then
            c_mode(k) <= M_RAIL; c_amt(k) <= 0;
          else
            c_mode(k) <= M_LSH;  c_amt(k) <= -sh;
          end if;
        end loop;

        -- THE LEAD CONTRACT, CHECKED.  The control a beat uses was decoded
        -- from e_seg one cycle earlier, so e_seg must be settled before the
        -- first beat and held for the segment.  A caller that drives e_seg
        -- and s_valid on the same edge gets the PREVIOUS segment's exponent
        -- for its first beat -- a power-of-two error on part of a segment,
        -- with no error flag, which is the exact shape of the defect that
        -- gdn_conv's e_seg publication fixed one seam upstream.  Simulation
        -- only; it synthesizes to nothing.
        eseg_r <= e_seg;
        assert not (s_valid = '1' and e_seg /= eseg_r)
          report "gdn_silu: e_seg changed in the same cycle as a beat.  The "
               & "shift control is registered, so this beat is converted on "
               & "the PREVIOUS exponent's grid.  Present e_seg at least one "
               & "cycle before s_valid and hold it for the segment."
          severity failure;

        -- ---- S0: Q12 conversion, both branches ----------------------------
        -- e is data-dependent and unbounded in BOTH directions, so both the
        -- right-shift and the saturating left-shift branch are present.  A
        -- version with only the right branch is correct on every vector whose
        -- e happens to exceed ARG_Q and wrong on the rest.
        --
        -- Every lane now reads ONLY its own c_mode(k) / c_amt(k).  There is
        -- deliberately no reference to e_seg or to a shared `sh` in this
        -- loop: one such reference reintroduces the shared net this whole
        -- construction exists to remove, and it would still be bit-exact, so
        -- nothing but synthesis would catch it.
        v0 <= s_valid;
        for k in 0 to LANES-1 loop
          sm0(k) <= signed(s_data((k+1)*16-1 downto k*16));
          v := resize(signed(s_data((k+1)*16-1 downto k*16)), 64);
          case c_mode(k) is
            when M_ZERO =>
              xq(k) <= (others => '0');
            when M_RSH =>
              xq(k) <= resize(rsh_r(v, c_amt(k)), 32);
            when M_PASS =>
              xq(k) <= resize(v, 32);
            when M_RAIL =>
              if    v > 0 then xq(k) <= to_signed(2**30, 32);  -- past the rail
              elsif v < 0 then xq(k) <= to_signed(-(2**30), 32);
              else             xq(k) <= (others => '0'); end if;
            when others =>
              v := shift_left(v, c_amt(k));
              if    v >  to_signed(2**30, 64) then xq(k) <= to_signed(2**30, 32);
              elsif v < -to_signed(2**30, 64) then xq(k) <= to_signed(-(2**30), 32);
              else  xq(k) <= resize(v, 32); end if;
          end case;
        end loop;

        -- ---- S1: index, fraction, rails ------------------------------------
        v1 <= v0;
        for k in 0 to LANES-1 loop
          sm1(k) <= sm0(k);
          if xq(k) <= to_signed(-RAIL, 32) then
            rl(k) <= -1; kk(k) <= 0;   fr(k) <= (others => '0');
          elsif xq(k) >= to_signed(RAIL, 32) then
            rl(k) <=  1; kk(k) <= 511; fr(k) <= (others => '0');
          else
            rl(k) <= 0;
            -- UNSIGNED, deliberately.  Inside this branch xq is strictly
            -- between the rails, so off is in [0, 2*RAIL) and non-negative --
            -- but slicing a SIGNED and calling to_integer on it reads the top
            -- bit as a sign, which makes k negative for the whole upper half
            -- of the table.  That is a bound-check failure in simulation and
            -- would have been a silently wrong table index in hardware.
            offu := unsigned(xq(k) + to_signed(RAIL, 32));
            -- k = off >> (ARG_Q - 4), frac = off(ARG_Q-5 downto 0) << 4.
            -- Exactly fx.h's (off*16) >> ARG_Q with the multiply folded away:
            -- idx_fp = off*16, k = idx_fp >> ARG_Q = off >> (ARG_Q-4), and
            -- frac = idx_fp mod 2^ARG_Q = (off mod 2^(ARG_Q-4)) * 16.
            kk(k) <= to_integer(offu(ARG_Q+4 downto ARG_Q-4));
            fr(k) <= offu(ARG_Q-5 downto 0) & "0000";
          end if;
        end loop;

        -- ---- S2: ROM read --------------------------------------------------
        v2 <= v1;
        for k in 0 to LANES-1 loop
          sm2(k) <= sm1(k); rl1(k) <= rl(k); fr2(k) <= fr(k);
          lo(k)  <= to_signed(SIG_ROM(kk(k)), 32);
          dl(k)  <= to_signed(SIG_ROM(kk(k)+1) - SIG_ROM(kk(k)), 25);
        end loop;

        -- ---- S3: delta * frac ---------------------------------------------
        v3 <= v2;
        for k in 0 to LANES-1 loop
          sm3(k) <= sm2(k); rl2(k) <= rl1(k); lo3(k) <= lo(k);
          pr(k)  <= resize(dl(k) * signed('0' & fr2(k)), 64);
        end loop;

        -- ---- S4: interpolate, round to Q15, clamp --------------------------
        v4 <= v3;
        for k in 0 to LANES-1 loop
          sm4(k) <= sm3(k); rl3(k) <= rl2(k);
          itp := resize(lo3(k), 64) + shift_right(pr(k), ARG_Q);
          sg  := rsh_r(itp, 30 - 15);
          if    rl2(k) = -1 then sig(k) <= (others => '0');
          elsif rl2(k) =  1 then sig(k) <= to_signed(32768, 18);
          elsif sg < 0      then sig(k) <= (others => '0');
          elsif sg > 32768  then sig(k) <= to_signed(32768, 18);
          else                   sig(k) <= resize(sg, 18); end if;
        end loop;

        -- ---- S5: sm * sigma ------------------------------------------------
        -- sm, NOT xq: the multiplicand is the original mantissa on its own
        -- grid.  Using the Q12-converted value here is right only when
        -- e = ARG_Q, which is exactly often enough to pass a careless test.
        v5 <= v4;
        for k in 0 to LANES-1 loop
          sm5(k) <= sm4(k);
          prod(k) <= resize(sm4(k) * sig(k), 64);
        end loop;

        -- ---- S6: round and emit --------------------------------------------
        v6 <= v5;
        o_valid <= v5;
        for k in 0 to LANES-1 loop
          y := rsh_r(prod(k), 15);
          assert not (v5 = '1' and (y > 32767 or y < -32768))
            report "gdn_silu: silu left int16 on the input grid -- "
                 & "abs(silu(x)) <= abs(x) is violated, so the no-rescan "
                 & "structure is unsound"
            severity failure;
          o_data((k+1)*16-1 downto k*16) <= std_logic_vector(resize(y, 16));
        end loop;
      end if;
    end if;
  end process;

end architecture;
