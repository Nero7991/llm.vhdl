# `attn_score_q12`'s 14-cycle header pass was serial for two different reasons, and neither of them was a serial dependency in the hardware. A one-level-per-cycle tree plus parallel subtracts takes it from 16 cycles to 5 and the slope from 355.17 to 311.17.

Date: 2026-09-20. TRACK SCOREHDR. Simulation only; no hardware was touched and
**no Vivado was run** (the workstation's lane was on a card build and the
BC-250's was held by TRACK LEVERCOST), so every AREA and TIMING claim below is
an ESTIMATE with its structure shown, or absent.

RTL `rtl/attn_score_q12.vhd` (new generic `HDR_TREE`), `rtl/attn_block.vhd`
(one pass-through generic `SCORE_HDR_TREE` and one line in a generic map, and
nothing else). Benches `sim/tb_attn_score_q12.vhd`, `sim/tb_csweep_rate.vhd`,
`sim/tb_attn_block.vhd`, `sim/tb_attn_kv_seam.vhd` (a pass-through generic in
each). Mutation script `sim/mutate_attn_score_hdr.sh`, new. GHDL mcode.

## The question, verbatim

From `docs/debugging/2026-09-20_the-attention-midgap.md`'s open list, quoted in
this track's brief:

> "Shortening the header pass itself was NOT attempted. `S_EMIN` is a 7-cycle
> linear scan for a minimum over 8 int8s and `S_SHIFTS` is 8 serial subtracts;
> a 3-level tree and 8 parallel subtracts would be about 4 cycles instead of
> 15. That changes a verified unit's area and its critical path, **and with no
> Vivado available there is no way to say what it costs**, so it is named and
> not done."

and the brief's own first instruction, which is the part that had to be
settled before any code was written: say **with quoted code and line numbers**
whether each pass is one per cycle because of a serial dependency, a shared
comparator, or a loop written serially, *"because that distinction decides
whether this is cheap or structural"*.

The symptom it starts from, MEASURED on silicon
(`docs/debugging/2026-09-20_token-cost-grows-2793-cycles-per-position.md`): a
token costs `30,115,217 + 2,793.4 * p` core cycles at 75 MHz and 100% of the
slope is subsystem C. MIDGAP then measured 14.00 of the 88.79 cycles per
position per KV head as `attn_score_q12` walking its own header with
`ar_prdy` LOW.

## The answer

**The two passes are serial for two DIFFERENT reasons, and neither is a
hardware constraint.**

* **`S_EMIN` has a genuine loop-carried dependency AS WRITTEN** -- `e_min` is
  both the accumulator and an operand of the next compare -- **but the
  operation is `min`, which is associative and commutative, so the dependency
  is a property of the spelling and not of the function.** A balanced tree
  computes the identical value in `clog2(NBLK)` levels.
* **`S_SHIFTS` has NO dependency at all.** The `NBLK` subtracts
  `e_l(b) - e_min` share only `e_min`, which is already final when the state
  is entered. **It is simply a loop written serially**, and all `NBLK` of them
  fit in one cycle.
* **Neither is a shared-comparator or shared-subtractor argument.** Both
  operands are `EXP_W = 8` bits, so an entire tree level is `NBLK/2 = 4`
  8-bit compares and the entire shift pass is 8 8-bit subtracts.

So it is CHEAP in cycles and its only real cost is combinational depth, which
is why the fix is a DIAL and not a switch.

**MEASURED, `sim/tb_csweep_rate.vhd` at the real 9B geometry, asymptotic slope
per position per C job, RD_LAT 100:**

| `SWEEP_PIPE` | `SCORE_EARLY` | `HDR_TREE` | per KV head | per job | saved | `sc_wait` | P_SCORE |
|---|---|---|---|---|---|---|---|
| off | off | 0 | 88.79 | **355.17** | -- | 14.00 | 23.00 |
| off | off | **1** | 77.79 | **311.17** | **44.00** | **3.00** | 12.00 |
| off | off | 3 | 75.79 | 303.17 | 52.00 | 1.00 | 10.00 |
| off | on | 0 | 80.79 | 323.17 | 32.00 | 8.00 | 17.00 |
| off | on | **1** | 72.79 | **291.17** | **64.00** | 0.00 | 9.00 |
| on | off | 0 | 68.77 | 275.11 | 80.06 | 14.00 | 23.00 |
| on | off | **1** | 57.77 | **231.11** | **124.06** | 3.00 | 12.00 |
| on | on | 0 | 57.79 | 231.17 | 124.00 | 5.01 | 14.01 |
| on | on | **1** | 54.96 | **219.87** | **135.30** | **0.00** | 9.00 |
| on | on | 2 | 54.96 | 219.87 | 135.30 | 0.00 | 9.00 |
| on | on | 3 | 54.96 | 219.87 | 135.30 | 0.00 | 9.00 |

The four `HDR_TREE = 0` arms reproduce MIDGAP's 35517 / 32317 / 27511 / 23117
**to the digit**, which is the check that this track changed nothing with the
generic off.

**THREE THINGS IN THAT TABLE MATTER MORE THAN THE HEADLINE.**

1. **`HDR_TREE` and `SCORE_EARLY` are SUB-ADDITIVE and must never be summed.**
   32.00 + 44.00 = 76.00; the measured combination is **64.00**. They attack
   the same 14 cycles from opposite ends -- one moves the pass earlier, the
   other shortens it -- so 12.00 cycles are claimed twice. MIDGAP warned that
   its own pair was SUPER-additive and that the singles must not be summed;
   this pair errs in the other direction and the warning generalises rather
   than the sign.
2. **`HDR_TREE` and `SWEEP_PIPE` ARE additive, to the digit.** 80.06 + 44.00 =
   124.06 and the measured pair is **124.06**. Two levers on the same block
   can be additive or not, and which is which is a measurement, not a
   property of "being levers".
3. **`SWEEP_PIPE` + `HDR_TREE=1` (231.11) EQUALS `SWEEP_PIPE` +
   `SCORE_EARLY` (231.17) to within 0.06 cycles.** They are interchangeable
   at that point. `HDR_TREE` is the smaller change -- one generic inside one
   leaf unit, against `SCORE_EARLY`'s new state and new assert in the sweep
   FSM -- so where only one can be afforded, this is the cheaper way to buy
   the same 124 cycles.

**AND DEPTH BEYOND ONE LEVEL PER CYCLE IS MEASURABLY WORTH ZERO ON THE ARM
THIS TRACK RECOMMENDS.** With all three on, `sc_wait` is already **0.00** at
`HDR_TREE = 1`: the header pass is entirely hidden. `HDR_TREE` 2 and 3 return
**21987 in all three runs, identical to the digit**, while each added level is
another 8-bit compare and mux in series on a design that closed at
**WNS +0.061 ns** (the routed card build,
`docs/debugging/2026-09-18_first-token-on-silicon-stops-at-step-7.md:9`).
**Set it to 1.**

## Procedure

1. **Read the two states and classify each, before writing anything.** The
   brief's warning was specific: three tracks that day found "written
   serially" where a serial dependency had been assumed and one found the
   opposite. The classification is in "What the two passes compute" below and
   it is the whole basis for the design that follows.
2. **Build the replacement behind a generic defaulting to the OLD behaviour**,
   as a DIAL (levels folded per cycle) rather than a switch, because the cost
   being traded is combinational depth and the right amount of it is a timing
   question this track cannot answer.
3. **Derive the closed form for the cycle count, then test it at five values
   of `NBLK` and four of `HDR_TREE`** -- twenty points -- rather than fit
   anything. A quantity that is structural holds exactly and needs no fit.
4. **Prove the values did not move**, against two independent C oracles, in
   every combination of the three generics.
5. **Mutate the tree**, with an attribution control on every row, at a
   geometry where the odd-level path is REACHABLE as well as at the card's
   where it is not, and re-run every surviving row against ten off-golden
   vector sets.
6. **Run the five gate groups inside md5 windows** and quote only windows
   that matched.

## What the two passes compute, with line numbers

`rtl/attn_score_q12.vhd`, the `HDR_TREE = 0` branches, which are the code as
it shipped.

**`S_EMIN`, `:420`, the legacy branch at `:421-431`.** It computes
`e_min = min over b in 0..NBLK-1 of e_l(b)`. The accumulator is seeded in
`S_IDLE` at `:404` from block 0 --

```vhdl
              -- Seeded from block 0's exponent rather than a sentinel, so no
              -- exponent is unrepresentable.
              e_min  <= signed(e_k(EXP_W-1 downto 0));
              blk    <= 1;
```

-- and then one further block is folded in per cycle:

```vhdl
          when S_EMIN =>
            if HDR_TREE = 0 then
              if e_l(blk) < e_min then
                e_min <= e_l(blk);
              end if;
              if blk = NBLK-1 then
                blk   <= 0;
                state <= S_SHIFTS;
```

`blk` runs 1 to `NBLK-1`, so **`NBLK-1` = 7 cycles** at the card geometry.
**Classification: a loop-carried dependency as written, over an associative
and commutative operator.** `e_min` feeds the next compare, so the code as
spelled cannot be unrolled -- and `min` is a reduction, so the dependency does
not exist in the function being computed. This is the case the brief said to
distinguish carefully, and it is neither of the two obvious answers: it is a
real dependency in the text and no dependency in the mathematics.

**`S_SHIFTS`, `:513`, the legacy branch at `:514-528`.** It computes
`shb(b) = clamp(e_l(b) - e_min, 0, 63)` for every b, one per cycle:

```vhdl
          when S_SHIFTS =>
            if HDR_TREE = 0 then
              sv := to_integer(e_l(blk)) - to_integer(e_min);
              if sv < 0 then sv := 0; elsif sv > 63 then sv := 63; end if;
              shb(blk) <= to_unsigned(sv, SHW);
              if blk = NBLK-1 then
                blk   <= 0;
                p_rdy <= '1';        -- ready BEFORE the first partial can come
                state <= S_ACC;
```

`blk` runs 0 to `NBLK-1`, so **`NBLK` = 8 cycles**.
**Classification: no dependency of any kind. A loop written serially.** The
`NBLK` subtracts share only `e_min`, which is final on entry to the state.

**`NBLK` at the card geometry is 8**: `rtl/attn_block.vhd` computes it as
`HEAD_DIM / KV_BLOCK`, and the 9B card is `HEAD_DIM = 256`, `KV_BLOCK = 32`
(`CSWEEP_CONFIG ... kvblk=32 nblk=8`, printed by every run quoted here).

**Total from the `S_IDLE` accept edge to `p_rdy` rising: `1 + (NBLK-1) +
NBLK = 2*NBLK = 16` cycles.** MIDGAP measured 14.00 of them inside P_SCORE;
the other two are absorbed by the state transition and P_HDR, which is why
that document says 15 and this one says 16. The two are the same fact counted
from different edges, and the MEASURED span is what either of them rests on.

**Neither pass is a shared resource.** `EXP_W` is 8, so one tree level is
`NBLK/2 = 4` 8-bit compares and the whole shift pass is 8 8-bit subtracts with
a clamp. Nothing in the unit serialises them; the file's own header says why
the shifts are precomputed *at all* (*"Precomputing the per-block shift in
S_SHIFTS is what makes p_ready unconditional"*), and that argument requires
them to be ready before the first partial -- it says nothing about their
having to arrive one per cycle.

## The tree that was built, and its depth

`HDR_TREE : natural := 0` at `rtl/attn_score_q12.vhd:201`. **0 is the legacy
scan and is the default**, so every existing instantiation keeps its schedule
cycle for cycle. `L >= 1` folds `L` levels of a balanced minimum tree per
cycle and does all `NBLK` subtracts in one cycle.

**Cycles from the accept edge to `p_rdy`:**

```
  HDR_TREE = 0     2 * NBLK
  HDR_TREE = L     1 (the S_IDLE latch) + ceil(clog2(NBLK)/L) + 1 (S_SHIFTS)
```

**WHY ONE LEVEL PER CYCLE IS THE RIGHT DEPTH, and it is a timing argument
rather than a cycle-count one.** At `NBLK = 8` the depths are:

| `HDR_TREE` | cycles | combinational depth added per cycle |
|---|---|---|
| 0 | 16 | one 8-bit compare + mux (the legacy scan) |
| **1** | **5** | **one 8-bit compare + mux -- IDENTICAL to legacy** |
| 2 | 4 | two in series |
| 3 | 3 | three in series |

**`HDR_TREE = 1` buys 11 of the 13 available cycles at NO increase in
combinational depth over the code that is already in the build.** The tree's
compares and the parallel subtracts remain in SEPARATE cycles, so the
project's stage rule -- never two of {barrel shift, wide add, wide compare,
bus mux, multiply} in series in one stage -- holds in both modes, and a
subtract still never feeds a barrel shift. Going past 1 spends real depth for
1 or 2 cycles, and on the recommended arm (below) it buys **nothing at all**.

The odd-level carry (an entry with no partner when a level has an odd number
of live entries) is written out explicitly at `:481-489`. **It is UNREACHABLE
at any power-of-two `NBLK`, which is every geometry this design is built at**,
and that fact is not argued -- it is measured, in the teeth table.

## Evidence

### The cycle count is a CLOSED FORM, exact at twenty points, not a fit

`sim/tb_attn_score_q12.vhd` against `ref/attn_score_q12_vec.c`, 64 cases plus
a 2-header overrun phase = 66 headers per run at 10 ns per cycle, so a wall
time difference of `X` ns is `X/660` cycles per header. Vectors regenerated
per `NBLK` by the committed generator.

```
NBLK=3   T0=PASS@17745ns  T1=PASS@16425ns  T2=PASS@15765ns  T3=PASS@15765ns
NBLK=5   T0=PASS@21705ns  T1=PASS@18405ns  T2=PASS@17745ns  T3=PASS@17085ns
NBLK=6   T0=PASS@23685ns  T1=PASS@19065ns  T2=PASS@18405ns  T3=PASS@17745ns
NBLK=7   T0=PASS@25665ns  T1=PASS@19725ns  T2=PASS@19065ns  T3=PASS@18405ns
NBLK=8   T0=PASS@27645ns  T1=PASS@20385ns  T2=PASS@19725ns  T3=PASS@19065ns
```

| NBLK | clog2 | L=0 pred | L=1 pred / meas | L=2 pred / meas | L=3 pred / meas |
|---|---|---|---|---|---|
| 3 | 2 | 6 | 4 / **4** | 3 / **3** | 3 / **3** |
| 5 | 3 | 10 | 5 / **5** | 4 / **4** | 3 / **3** |
| 6 | 3 | 12 | 5 / **5** | 4 / **4** | 3 / **3** |
| 7 | 3 | 14 | 5 / **5** | 4 / **4** | 3 / **3** |
| 8 | 3 | 16 | 5 / **5** | 4 / **4** | 3 / **3** |

**Twenty of twenty exact.** This project's own rule applies: *"a quantity that
scatters is a mean; a quantity that is structural is a constant; neither is a
slope."* This one is structural, it holds exactly, and no fit was performed --
which is also why the `NBLK` dependence can be quoted for a geometry nobody
runs. All twenty runs PASS the value oracle, so the table is a cycle
measurement on a design that is also bit-exact at every one of those points.

### The rate A/B, all eleven arms, verbatim

Bench `sim/tb_csweep_rate.vhd`, generics
`hd=256 nqh=16 nkvh=4 kvblk=32 nblk=8 rec_b=272 axi_dw=256 maxb=16 maxout=4
rbuf=4 rd_lat=100 stall=0 spread=0 ideal=false`, positions 1/8/16/64.

```
### sweep_pipe=false score_early=false score_hdr_tree=0   (the shipping schedule)
CSWEEP_SLOPE_X100 35517
MIDGAP_SLOPE RECK 1279  HDR 300  SCORE 2300  SCW 1300  EPW 1300
MIDGAP_SLOPE RSPASS 0   RSACK 0  RECV 1100   PV 900    POSN 400
MIDGAP_SLOPE_SUM 8879 expect_slope_over_nkvh=8879
MIDGAP_SLOPE_SUB sc_wait=1400 sc_iss=900 rk_pre=279 rk_post=200 rv_pre=100 rv_post=200
CSWEEP_STATUS err='0' kv_err='0' slv_bad=0      CSWEEP: PASS

### sweep_pipe=false score_early=false score_hdr_tree=1
CSWEEP_SLOPE_X100 31117
MIDGAP_SLOPE RECK 1279  HDR 300  SCORE 1200  SCW 1300  EPW 1300
MIDGAP_SLOPE RSPASS 0   RSACK 0  RECV 1100   PV 900    POSN 400
MIDGAP_SLOPE_SUM 7779 expect_slope_over_nkvh=7779
MIDGAP_SLOPE_SUB sc_wait=300 sc_iss=900 rk_pre=279 rk_post=200 rv_pre=100 rv_post=200
CSWEEP_STATUS err='0' kv_err='0' slv_bad=0      CSWEEP: PASS

### sweep_pipe=false score_early=false score_hdr_tree=3
CSWEEP_SLOPE_X100 30317   MIDGAP_SLOPE SCORE 1000   MIDGAP_SLOPE_SUM 7579
MIDGAP_SLOPE_SUB sc_wait=100 sc_iss=900             CSWEEP: PASS

### sweep_pipe=false score_early=true  score_hdr_tree=0
CSWEEP_SLOPE_X100 32317   MIDGAP_SLOPE SCORE 1700   MIDGAP_SLOPE_SUM 8079
MIDGAP_SLOPE_SUB sc_wait=800 sc_iss=900             CSWEEP: PASS

### sweep_pipe=false score_early=true  score_hdr_tree=1
CSWEEP_SLOPE_X100 29117   MIDGAP_SLOPE SCORE 900    MIDGAP_SLOPE_SUM 7279
MIDGAP_SLOPE_SUB sc_wait=0 sc_iss=900               CSWEEP: PASS

### sweep_pipe=true  score_early=false score_hdr_tree=0
CSWEEP_SLOPE_X100 27511   MIDGAP_SLOPE SCORE 2300   MIDGAP_SLOPE_SUM 6877
MIDGAP_SLOPE_SUB sc_wait=1400 sc_iss=900            CSWEEP: PASS

### sweep_pipe=true  score_early=false score_hdr_tree=1
CSWEEP_SLOPE_X100 23111
MIDGAP_SLOPE RECK 277   HDR 300  SCORE 1200  SCW 1300  EPW 1300
MIDGAP_SLOPE RSPASS 0   RSACK 0  RECV 100    PV 900    POSN 400
MIDGAP_SLOPE_SUM 5777 expect_slope_over_nkvh=5777
MIDGAP_SLOPE_SUB sc_wait=300 sc_iss=900 rk_pre=277 rk_post=0 rv_pre=100 rv_post=0
CSWEEP_STATUS err='0' kv_err='0' slv_bad=0      CSWEEP: PASS

### sweep_pipe=true  score_early=true  score_hdr_tree=0
CSWEEP_SLOPE_X100 23117   MIDGAP_SLOPE SCORE 1401   MIDGAP_SLOPE_SUM 5779
MIDGAP_SLOPE_SUB sc_wait=501 sc_iss=900             CSWEEP: PASS

### sweep_pipe=true  score_early=true  score_hdr_tree=1   (this track's recommendation)
CSWEEP_SLOPE_X100 21987
MIDGAP_SLOPE RECK 496   HDR 100  SCORE 900   SCW 1300  EPW 1300
MIDGAP_SLOPE RSPASS 0   RSACK 0  RECV 100    PV 900    POSN 400
MIDGAP_SLOPE_SUM 5496 expect_slope_over_nkvh=5496
MIDGAP_SLOPE_SUB sc_wait=0 sc_iss=900 rk_pre=271 rk_post=66 rv_pre=100 rv_post=0
CSWEEP_STATUS err='0' kv_err='0' slv_bad=0      CSWEEP: PASS

### sweep_pipe=true  score_early=true  score_hdr_tree=2   -> 21987, identical to the digit
### sweep_pipe=true  score_early=true  score_hdr_tree=3   -> 21987, identical to the digit
```

`MIDGAP_SLOPE_SUM` equals `CSWEEP_SLOPE_X100 / 4` in **all eleven arms**,
which is MIDGAP's two-instrument identity holding across a change to a unit
neither instrument knows about.

**THE SAVING IS NOT ALL IN P_SCORE, AND SAYING SO IS THE POINT.** On the
recommended arm, P_SCORE falls 14.01 -> 9.00 (-5.01) and `sc_wait` reaches
0.00, but **P_RECK rises 2.77 -> 4.96 (+2.19)** and `rk_post` reappears at
0.66. The header pass finishing earlier moves the K fetch's tail across a
phase boundary. Net is still -2.83 per position per KV head, and the arithmetic
that matters is the SLOPE, not the span. This is the recorded "the saving is
not proportional to the parameter" shape: an exact relationship for one span
is not a licence to read the total off it.

### Values are bit-identical, against two independent C oracles

Not a round trip. Twenty runs -- both benches, every combination of the three
generics, plus `HDR_TREE = 3` on two arms.

`sim/tb_attn_block.vhd` vs `ref/attn_block_vec.c`. **All ten verdict strings
are BYTE-IDENTICAL**, and the wall time falls monotonically in the expected
order, which is the cheap cross-check that the generics did something:

```
  ht0  sp=F se=F @81465ns   ht1 @80435ns   ht3 @80215ns
  ht0  sp=F se=T @80665ns   ht1 @79755ns
  ht0  sp=T se=F @79685ns   ht1 @78855ns
  ht0  sp=T se=T @78755ns   ht1 @78065ns   ht3 @78005ns

  all ten:
  tb_attn_block: PASS -- 3 consumer configurations, 64 elements each, y
  stream bit-identical across all of them, y_exp tracks vin_exp exactly, the
  current position was never read back, y_exp(run 0) = 15, and BIT-EXACT
  against ref/attn_block_vec.c over 130 compared values
```

`sim/tb_attn_kv_seam.vhd` vs `ref/attn_block_seq_vec.c`, the bench that
matters most here because Q2 checks the record IMAGE in HBM at C spec 2.2's
address and Q3 matches every returned beat to the `(layer, head, position,
block)` it was requested for:

```
  ht0  sp=F se=F @457945ns  ht1 @456415ns  ht3 @456065ns
  ht0  sp=F se=T @456965ns  ht1 @455745ns
  ht0  sp=T se=F @455905ns  ht1 @454695ns
  ht0  sp=T se=T @454935ns  ht1 @453695ns  ht3 @453345ns

  all ten:
  tb_attn_kv_seam: PASS -- 4 tokens at cur_pos 0..3 x 2 layers INTERLEAVED
  token-major (8 jobs) through rtl/attn_kv_axi.vhd over AXI at 100-cycle read
  latency, BIT-EXACT against ref/attn_block_seq_vec.c over 2056 output values
  and 2176 record bytes in HBM, every returned beat matched to the layer and
  position it was requested for, k_base=16 v_base=4064 (neither 4 KB
  aligned), MAXCTX=8, longest quiet stretch <N> cycles against a watchdog of
  20000
```

**The ONLY difference across those ten strings is `<N>`**: 2137 at
`HDR_TREE = 0` in all four arms, 2133 at 1 in all four, 2132 at 3 in both.
That is a schedule statistic, it moves with the generic exactly as it should,
and every value claim in the sentence is identical. The four `HDR_TREE = 0`
wall times reproduce MIDGAP's 81465 / 80665 / 79685 / 78755 and 457945 /
456965 / 455905 / 454935 **to the nanosecond**, across an edit to
`attn_score_q12` and `attn_block` -- which is the same-tree control that says
the generic is genuinely off by default.

Both seam and block benches run at `NBLK = 4`, so these runs exercise a
two-level tree; the card's three-level one is exercised by
`tb_attn_score_q12` and `tb_csweep_rate`.

### Teeth

`sim/mutate_attn_score_hdr.sh`, oracle `sim/tb_attn_score_q12.vhd` against
`ref/attn_score_q12_vec.c`. Every row is run twice; **the OFF arm is
`HDR_TREE = 0`, where every mutated line sits in a dead branch, and it is the
attribution control.** Verdicts are `sim/mutverdict.py`'s.

| row | what it breaks | ON | OFF | off-golden seeds | reading |
|---|---|---|---|---|---|
| `A` | nothing, NBLK 8 both arms | PASS | PASS | 0/10 | anchors clean; the seed sweep does not false-red |
| `A5` | nothing, NBLK 5 | PASS | -- | | the odd geometry itself is clean |
| **`Z0`** | **an impossible anchor** | **BADMUT** | -- | | **the harness's own teeth; see below** |
| `T1` | tree compare reversed: min becomes max | **KILLED** | PASS | | clean, fully attributed |
| `T2` | the last leaf dropped from the tree | PASS | PASS | **5/10** | **DID NOT BITE at the committed golden, and it is detectable** |
| `T3` | off-by-one on the last partial level, NBLK 8 | PASS | PASS | | **UNREACHABLE. Measures nothing.** |
| `T3` | the same, NBLK 5 | **KILLED** | PASS | **7/10** | clean, fully attributed |
| `T4` | per-block subtracts rotated by one | **KILLED** | PASS | | clean, fully attributed |
| `T5` | the odd entry discarded, NBLK 8 | PASS | -- | | **UNREACHABLE. Measures nothing.** |
| `T5` | the same, NBLK 5 | **KILLED** | PASS | | clean, fully attributed |
| `T6` | `p_ready` raised one state early | PASS | PASS | 0/10 | **DID NOT BITE, and the reason is a real finding** |
| `T7` | the tie rule flipped (INTENDED INERT) | PASS | PASS (NBLK 5 too) | 0/10 | inert as designed |
| `T8` | `S_IDLE`'s `e_min` seed removed | PASS | **KILLED** | 0/10 | **POSITIVE CONTROL on the OFF arm** |

```
 TOTAL 23   KILLED 5   SURVIVED 17   ABORT 1
   A_on PASS      A_off PASS     A5_on PASS
   Z0_on BADMUT
   T1_on KILLED   T1_off PASS
   T2_on PASS     T2_off PASS
   T3_on PASS     T3_off PASS    T3_on5 KILLED   T3_off5 PASS
   T4_on KILLED   T4_off PASS
   T5_on PASS     T5_on5 KILLED  T5_off5 PASS
   T6_on PASS     T6_off PASS
   T7_on PASS     T7_on5 PASS
   T8_on PASS     T8_off KILLED
   seed sweep (kills at off-golden seeds):
   A 0/10   T2 5/10   T3 7/10   T6 0/10   T7 0/10   T7b 0/10   T8 0/10
```

Row by row, **including every row that does not bite**:

* **`T1`, `T3` (at NBLK 5), `T4` and `T5` (at NBLK 5) are four clean
  attributed kills.** Each SURVIVES with `HDR_TREE = 0`, so each kill belongs
  to the tree and not to an older property the edit happened to trip. `T4` is
  the one worth naming: rotating the destination of the parallel subtracts
  leaves the MULTISET of shifts unchanged, so a checker that compared only the
  set of alignments would not see it.
* **`T8` IS THE POSITIVE CONTROL AND IT IS THE REASON THE OFF COLUMN MEANS
  ANYTHING.** Removing `S_IDLE`'s `e_min <= e_k(0)` seed is invisible under the
  tree, which overwrites `e_min` wholesale, and FATAL under the legacy scan,
  which only ever compares blocks 1..NBLK-1 against that seed. It is KILLED
  with `HDR_TREE = 0` and SURVIVES with `HDR_TREE = 1`, exactly backwards from
  every other row. **Without it, thirteen `PASS`es in the OFF column would be
  compatible with a bench that was asleep in that configuration.**
* **`T3` AND `T5` AT NBLK = 8 ARE UNREACHABLE AND ARE REPORTED AS SUCH.** Every
  level of a power-of-two tree has an even number of live entries, so the
  odd-level carry never executes and the mutation cannot run. Their `PASS` at
  NBLK = 8 says NOTHING about the oracle. They are run at `NBLK = 5` with
  vectors regenerated at that shape, where both are KILLED. **An unreachable
  mutant reported as a resolution floor is the error this project has already
  recorded twice, and quoting the NBLK = 8 row alone would have repeated it.**
* **`T2` DID NOT BITE AT THE COMMITTED GOLDEN, AND THAT IS A STATEMENT ABOUT
  THE GOLDEN.** Dropping the last leaf from the reduction makes `e_min` the
  minimum over `NBLK-1` blocks. The committed vector file has **2 of 64 cases
  where block 7 holds the unique minimum** (counted directly), and even those
  do not move `s_q12`. **CONFIRMED BY A THIRD PATH, not inferred from the
  bench passing:** an independent Python model of the C reference's recipe,
  validated by reproducing all 64 committed golden values exactly, finds the
  dropped-leaf variant changes `s_q12` in **0 of 64** cases -- so the
  SURVIVED is a true statement about the vectors and not a blind spot in the
  checker. The mechanism is that `e_min` is a COMMON scale: an `e_min` larger
  by `d` shrinks every alignment shift by `d` and raises `score_exp` by `d`,
  and the two cancel in the Q12 conversion **up to the alignment's flooring
  residual**, which is the only thing this defect can move. **So it is NEARLY
  value-neutral -- and it is NOT value-neutral: it is KILLED at 5 of 10
  off-golden seeds.** The seed sweep is the only reason that is known rather
  than assumed, and a table without it would have recorded a detectable
  defect as an inert mutation.
* **`T6` DID NOT BITE, in 22 runs, and the mechanism is worth carrying.**
  Raising `p_rdy` at the end of `S_EMIN` instead of `S_SHIFTS` offers
  `p_ready` one cycle before the shifts exist. It is value-neutral at BOTH
  interfaces, and not by luck in the bench: `rtl/attn_block.vhd:1004` has
  `ar_prdy <= '1' when all_ones(sq_prdy) else '0'` combinationally, `:1951`
  reads it in a clocked process, and `rtl/attn_mac_array.vhd:455` registers
  `pv_r`, so a partial cannot arrive until at least two cycles after
  `p_ready` rises -- by which time the unit is in `S_ACC` with `shb` written.
  **So the unit's stated contract ("the shifts are known before the first
  partial") currently holds with one cycle of margin that comes from the
  CONSUMER's latency rather than from this unit's structure.** Nothing checks
  it. The honest reading is MIDGAP's own about `se_rdy`: correctness resting
  on a timing relationship nobody has stated. The RTL was NOT changed for it
  -- as written it is correct, and the margin is real -- but it is recorded,
  and a consumer that ever issued combinationally off `p_ready` would break
  this unit silently.
* **`T7` is the honest intended-inert row and it stayed inert**, at NBLK 8 and
  5 and across ten off-golden seeds. Flipping `<` to `<=` changes which of two
  equal exponents the tree keeps and cannot change the minimum's VALUE. It
  measures the resolution floor from the other direction: this oracle cannot
  see a tie rule, so nothing in the design may ever depend on one.

### The harness had the exact defect it exists to find, and `Z0` is the fix

**MEASURED, on the first run of this script's corrected `T2` row: the
mutation anchor matched 0 times, `mutate_rtl` echoed the empty string,
`run_case` read an empty mutdir as "use the repo file", and the PRISTINE
design was run and reported `T2_on SURVIVED` -- then swept over ten seeds and
reported `0/10`, i.e. an inert mutant.** The python diagnostic
(`MUTATION ANCHOR MATCHED 0 TIMES, expected 1`) was one line above the row in
the same log and read as noise. The cause was a shell-quoting mistake:
`'"'"'1'"'"'` is the escape for a literal quote inside SINGLE quotes, and the
anchor was inside DOUBLE quotes, where a single quote is already literal -- so
the anchor searched for `if tl0 = '"' then`.

This is "guards that pass for the wrong reason" inside a mutation harness,
which is the one place it is least visible, **and the shape is inherited: the
same `if [ $? -ne 0 ]; then echo ""; return; fi` is in
`sim/mutate_attn_score_early.sh` and its siblings.** Two changes:

* `mutate_rtl` now echoes `__ANCHOR_FAIL__` and `run_case` reports **BADMUT**,
  counted apart from a survival, with the text *"NOT a survival. Nothing was
  measured about the oracle."*
* **Row `Z0` is the guard's own teeth**: a deliberately impossible anchor whose
  only correct outcome is BADMUT. It costs one python invocation and no
  simulation, and **if it ever reports SURVIVED, every other SURVIVED in the
  table is suspect.** MEASURED: `Z0_on BADMUT`.

The corrected `T2` then survived the golden and died at 5 of 10 seeds, which
is the result quoted above.

### The gate rows, every OVERALL line verbatim

All five groups were run AFTER the last edit to any RTL file or bench, against
the committed tree, one `regress.sh` invocation per group with its own
`REGRESS_SCRATCH` under `/mnt/storage`. **Each group hashed 23 files at the
start and again at the end** -- `sim/regress.sh`, the fourteen RTL files these
rows compile, `rtl/llama_top.vhd`, `rtl/fk33_llama_top.vhd`,
`tools/check_kv_map.py` (which PARSES `llama_top.vhd`) and the four benches --
because TRACK GSRWIDE was editing `rtl/llama_top.vhd` throughout.

```
########## --only tb_attn          (window GA)
GA_MD5_MATCH: every watched file byte-identical start to end
 suite sim   PASS 16   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 16   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1   SKIPPED 4
 REGRESSION: PASS

########## --only tb_csweep_rate          (window GB)
GB_MD5_MATCH: every watched file byte-identical start to end
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS

########## --only seamgate          (window GC)
GC_MD5_MATCH: every watched file byte-identical start to end
 suite sim   PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS

########## --only tb_llama_top_kv          (window GD)
GD_MD5_MATCH: every watched file byte-identical start to end
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS

########## --only kvmap          (window GE)
GE_MD5_MATCH: every watched file byte-identical start to end
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

**Every window printed `MD5_MATCH`.** The FIRST five-group run of this same
script did NOT: `GD_MD5_MISMATCH` named `rtl/attn_score_q12.vhd` and
`rtl/attn_block.vhd` moving `6e4a945f`/`e25a368f` -> `3bd38bc9`/`c18be311`
mid-window, **and it was this track's own comment-only edit, not another
track's.** That run is VOID and is not quoted; all five groups were re-run
against the final bytes and the block above is the re-run.

`--only` takes a SUBSTRING, not a regex, and `PASS 0` would mean the pattern
matched nothing; every group above has a non-zero PASS. `--only tb_attn`
reports `NOCHECK 1` and `SKIPPED 4`, which is its standing shape (the
`library beh` netlist-compare rows need xsim + UNISIM) and is unchanged by this
work -- the brief's instruction was not to let `PASS 16` regress, and it did
not.

## Area and timing: UNMEASURED, and here is exactly what would settle it

**NO VIVADO WAS RUN.** The workstation's lane was on a card build and the
BC-250's was held by TRACK LEVERCOST, so there is no synthesis, no placement
and no routed number anywhere in this document. What follows is an **ESTIMATE
derived from the structure that was written**, and this project's record says
an estimate of this kind has been wrong by 12 percentage points before.

**ESTIMATE, per `attn_score_q12` unit at `NBLK = 8`, `EXP_W = 8`, `SHW = 6`,
`HDR_TREE = 1`:**

| what | delta | derivation |
|---|---|---|
| `tv` working set | **+32 FF** | `TW = ceil(NBLK/2) = 4` entries x 8 bits. Sized to 4 and not 8 deliberately: level 0 reads `e_l`, so the array only holds the result of the first fold onward |
| `tn`, `tl0` | **+5 FF** | a 0..8 counter and one flag |
| `blk` (trimmed) | **-3 FF** | dead in tree mode |
| the source mux | **+32 to +64 LUT** | `NBLK * EXP_W = 64` bits of 2:1 on `tl0` |
| one fold level | **+30 to +50 LUT** | `NBLK/2 = 4` signed 8-bit min = compare + 8-bit mux each |
| `NBLK` parallel subtracts + clamp | **+100 to +130 LUT** | 8 of what the legacy path had 1 of |
| the legacy scan, trimmed | **-35 to -50 LUT** | one compare, one mux, one subtract, one clamp, one write decode |
| **net per unit** | **+130 to +200 LUT, +34 FF** | |
| **per `attn_block`** | **+520 to +800 LUT, +136 FF** | `G = N_QH / N_KVH = 4` score units |

For scale, using TRACK LEVERCOST's MEASURED figures from the same day: that is
**0.7% to 1.0% of the card's 76,585 free LUT sites**, against `SWEEP_PIPE`'s
measured +64 LUT / +23 FF (0.08%) and `B_RECUR_LANES=16`'s +7,742 (10.1%). So
it is an order of magnitude more expensive than `SWEEP_PIPE` and an order of
magnitude less than the B lever. **It is NOT free and it should not be
described as free.**

**TIMING, ESTIMATE.** At `HDR_TREE = 1` the deepest new path is
register -> 2:1 mux -> signed 8-bit compare -> 8-bit 2:1 mux -> register,
against the legacy scan's register -> compare -> mux -> register: **about one
extra LUT level, with no increase in fan-in.** The parallel subtracts are the
same logic replicated, not deepened. At `HDR_TREE = 3` the path carries three
compares and three muxes in series, roughly 7 to 10 LUT levels; on a design
whose routed WNS is **+0.061 ns** that is a real risk, and the measurement
above says it buys **zero cycles** on the recommended arm.

**WHAT WOULD SETTLE IT, exactly.**

* **AREA: two new arms on `sim/ooc_levercost_run.sh`'s existing harness.**
  That script already draws `attn_block` at the card geometry
  (`cswp_off` / `cswp_on` at `:241-242`, `draw <tag> attn_block "$CGEN
  SCORE_HDR_TREE=0|1" "clk=13.333"`), it refuses to run without `LC_CGEN`
  so the generics cannot silently default, and it already emits the
  object-level `REF_NAME` census that this project requires over
  `report_utilization`. Two arms, same file, same `flatten_hierarchy`. **Read
  the census, not the utilization total.**
* **TIMING: that harness is NOT enough, and this is the one place this lever
  differs from `SWEEP_PIPE`.** `grep -cE 'route_design' sim/ooc_levercost.tcl`
  is **0** -- it is `synth_design` + `opt_design` only. This project's rule is
  that nothing before `route_design` orders two runs correctly (MEASURED twice,
  by 0.428 ns and 0.633 ns, once with the sign inverted). `SWEEP_PIPE` could
  be reported on a bound because it adds no depth; **`HDR_TREE`'s entire cost
  IS depth**, so it needs `place_design` + `route_design` on `attn_block`, and
  then a `report_timing -through` on the score unit's own cone rather than a
  top-N window. LEVERCOST recorded that **none of its top 200 paths was in the
  sweep FSM**, so a top-N list would report "unchanged" whatever this lever
  did.

## Measured and REJECTED -- do not retry

* **"Add `HDR_TREE`'s saving to `SCORE_EARLY`'s."** REJECTED, and it errs
  OPTIMISTIC: 44.00 + 32.00 = 76.00 against a measured 64.00. They attack the
  same 14 cycles.
* **"Fold more than one tree level per cycle."** REJECTED on the recommended
  arm by measurement: `HDR_TREE` 1, 2 and 3 all return `CSWEEP_SLOPE_X100
  21987`, identical to the digit, because `sc_wait` is already 0.00 at 1.
  Alone (both other generics off) 2 and 3 are worth 4.00 and 8.00 cycles per
  position per job, for two and three compares in series. Not worth it at
  +0.061 ns.
* **"The header pass is serial because the comparator is shared."** REJECTED
  by reading the widths: `EXP_W = 8`, so a whole level is four 8-bit compares.
  Nothing is shared.
* **"`S_EMIN` and `S_SHIFTS` are serial for the same reason."** REJECTED. One
  is a reduction with a loop-carried dependency as spelled; the other has no
  dependency whatever. The brief asked for this distinction and the two states
  give different answers.
* **"An unreachable mutant that survives measures the oracle's resolution."**
  REJECTED, and `T3`/`T5` at NBLK 8 are the demonstration: they cannot
  execute, and the same rows at NBLK 5 are both KILLED.
* **"A mutant that survives the committed golden is inert."** REJECTED by
  `T2`: it survives the committed vectors and is KILLED at 5 of 10 off-golden
  seeds.
* **"Removing the `S_IDLE` `e_min` seed is dead code now."** REJECTED. `T8`
  KILLS with `HDR_TREE = 0`; the legacy scan needs it.

## Measurement traps hit

1. **MY OWN MUTATION HARNESS REPORTED AN UNAPPLIED MUTATION AS A SURVIVING
   ONE, AND THEN SWEPT IT OVER TEN SEEDS AND REPORTED `0/10`.** Written up in
   full above. The general form is this project's own: a check whose failure
   path is indistinguishable from its success path. **The tell was available
   and was missed for one run: an earlier hand-run of the same mutant over the
   same ten seeds had given `5/10`, and the script gave `0/10`.** Two
   disagreeing measurements of the same thing is the cheapest possible
   detector and it only worked because the hand run happened to exist.
2. **A MUTANT THAT ABORTS ON A GHDL BOUND CHECK HAS TESTED THE LANGUAGE, NOT
   THE ORACLE.** `T3`'s first form was `2*i + 1 <= wn - 1` -> `<= wn`, which at
   NBLK = 5 reads `wv(5)` out of a 0..4 array: `ABORT:LANG`, reported by `sim/mutverdict.py` against a GHDL bound check
   inside the MUTATED copy (its line numbers are its own, not the repo
   file's). Counting it as a kill would have credited this
   bench with a detection it never made. The row was rewritten to stay in
   range (take the entry one BELOW the unpaired one) and then KILLS properly.
3. **EDITING THE RTL INVALIDATED A RUNNING BATCH'S WORKDIR AND THREE ARMS DIED
   WITH `has changed and must be reanalysed`.** Eight arms had already
   finished against the pre-edit file. **Those eight were discarded and the
   whole batch re-run**, not because the numbers differed -- the edit was
   proven simulation-identical at twenty points first -- but because
   "a comparison needs both ends drawn from the same tree" does not have a
   clause for "and I checked that it probably does not matter". The re-run
   cost twelve minutes.
4. **A PROCESS VARIABLE THAT IS NOT ASSIGNED ON EVERY PATH INFERS STORAGE, AND
   NO BENCH CAN SEE IT.** The tree's working bundle `wv` was first written with
   the level-0 load assigning all `NBLK` entries and the later-level load
   assigning only `TW` of them. Those `NBLK - TW` entries are never READ on
   that path, so it simulates identically -- and in synthesis it is
   read-before-write, which infers 32 flip-flops per unit feeding muxes that
   can never select them. Fixed by assigning every entry on every path with a
   named filler. **The twenty-point unit grid was identical to the picosecond
   before and after**, which is exactly why no bench would have found it.
5. **THE VECTOR GENERATOR'S ARGUMENT ORDER IS `<outfile> <ncase> <NBLK> <KQ>
   [seed]`, NOT `<ncase> ...`.** `./gen_sq 64 5 4` silently wrote a file named
   `64` containing 5 cases of 4 blocks and printed a cheerful OK. The tell was
   the shape line. `sim/regress.sh:2473` carries the arguments for the
   committed file (`64 8 4`); take them from there.
6. **I VOIDED MY OWN GATE RUN WITH A COMMENT-ONLY EDIT, AND THE md5 GUARD
   CAUGHT IT.** Three of the five groups had already reported GREEN when a
   comment table was added to `rtl/attn_block.vhd`'s new generic; the two
   still running hash that file, so their windows reported MISMATCH and were
   discarded, and the three that had finished were about the pre-comment
   bytes. **All five were re-run.** CLAUDE.md already says a comment-only edit
   is not exempt because bash and md5 both count bytes; this is that rule
   costing forty minutes to the person who had just written it into a brief.
   The rule that would have prevented it is also already written: **make every
   edit BEFORE starting a gate.**
7. **A BUFFERED LOG SHOWS NOTHING WHILE EIGHT SIMULATIONS RUN.** The rate
   batch's per-arm logs stayed empty for minutes with eight live
   `ghdl-mcode` processes. Counted by reading `/proc/PID/cwd` of each, which
   names the arm directly and which the kernel updates immediately. Same trap
   this project has already recorded for `regress.sh`.

## The exact change for the dispatcher

**`rtl/llama_top.vhd` is NOT this track's file and was NOT edited** (TRACK
GSRWIDE owns it today). It is also the INPUT to `tools/gen_cardtop.py`, which
emits `rtl/fk33_llama_top.vhd`, and nothing on the source says so. So the
sequence is: edit `llama_top.vhd`, regenerate, `git diff` the generated file
and confirm it contains that change and nothing else, then
`sim/regress.sh --only cardtop`.

At the `u_attn : entity work.attn_block` instance -- `rtl/llama_top.vhd:6914`
**as of this writing, and MIDGAP's write-up says `:6621` for the same
instance because TRACK GSRWIDE has edited that file in between. Find it by
the instance name, not by the line number.** The generic map ends at `:6919`:

```vhdl
        NORM_LANES => 1, STRICT_PRODUCER => true)     -- before

        NORM_LANES => 1, STRICT_PRODUCER => true,     -- after
        SWEEP_PIPE => true, SCORE_EARLY => true, SCORE_HDR_TREE => 1)
```

**`SCORE_HDR_TREE => 1`, not 2 or 3.** The three values are identical on that
arm to the digit and 2 and 3 cost combinational depth for nothing.

**TRACK LEVERCOST's standing warning applies to this generic too and it is the
first thing to check:** at HEAD, `SWEEP_PIPE` appears 24 times in
`rtl/attn_block.vhd` and **zero** times in `rtl/llama_top.vhd`,
`rtl/fk33_llama_top.vhd`, `tools/gen_cardtop.py` and
`hw/fk33/gen_fk33_card.py`. `SCORE_EARLY` and `SCORE_HDR_TREE` are in exactly
the same position. **Setting any of the three in a build today would be
silently ignored**; they have to be plumbed through `llama_top` and
`gen_cardtop.py` first, and that is one job for all three, not three jobs.

**Do not set any of them on a build without the OOC draw above.** The area is
an ESTIMATE and the timing is not even that.

## DERIVED on the card

Scaling the card's MEASURED 2,793.4 cycles per position by the MEASURED slope
ratios, at the 75 MHz core clock. **Only the SLOPE moves; the intercept does
not**, because at `p = 0` the sweep has only the bypass position and reads no
record.

| arm | bench slope / job | DERIVED card slope |
|---|---|---|
| now (shipping) | 355.17 | 2,793.4 |
| `SCORE_HDR_TREE=1` alone | 311.17 | **2,447.3** |
| `SCORE_EARLY` alone | 323.17 | 2,541.7 |
| `SWEEP_PIPE` alone | 275.11 | 2,163.7 |
| `SWEEP_PIPE` + `SCORE_HDR_TREE=1` | 231.11 | **1,817.7** |
| `SWEEP_PIPE` + `SCORE_EARLY` | 231.17 | 1,818.1 |
| **all three** | **219.87** | **1,729.3** |

| position | now | `HDR_TREE=1` alone | `SWEEP_PIPE`+`HDR_TREE=1` | `SWEEP_PIPE`+`SCORE_EARLY` | all three |
|---|---|---|---|---|---|
| 0 | 2.4904 tok/s | 2.4904 | 2.4904 | 2.4904 | 2.4904 |
| 2,048 | 2.0929 | 2.1351 (+2.0%) | 2.2165 (+5.9%) | 2.2164 (+5.9%) | **2.2284 (+6.5%)** |
| 8,192 | 1.4151 | 1.4951 (+5.7%) | 1.6665 (+17.8%) | 1.6663 (+17.8%) | **1.6937 (+19.7%)** |
| 65,536 | 0.3518 | 0.3937 (+11.9%) | 0.5026 (+42.8%) | 0.5024 (+42.8%) | **0.5228 (+48.6%)** |

The `SWEEP_PIPE` + `SCORE_EARLY` column reproduces MIDGAP's +5.9 / +17.8 /
+42.8 exactly, which is the check that the method is the same one.

## Open, not determined

* **THE AREA AND TIMING COST IS UNMEASURED AND THE TIMING RISK IS REAL.** No
  Vivado ran. The area is an ESTIMATE of +130 to +200 LUT and +34 FF per
  score unit, x4 in `attn_block`, derived from the structure and NOT from any
  tool. The timing claim is only that `HDR_TREE = 1` adds about one LUT level
  with no fan-in growth, which on a +0.061 ns design is a judgement and not a
  measurement. **The two OOC draws named above are the whole of what would
  settle it, and the timing one needs `route_design`, which no existing OOC
  harness in this repo performs on `attn_block`.**
* **THE FIRST FOLD COULD BE DONE IN `S_IDLE` AND WAS NOT.** The `S_IDLE` cycle
  already reads `e_k` to latch `e_l`; folding level 0 from `e_k` in the same
  cycle would remove the `tl0` flag, the whole 64-bit source mux (the largest
  single item in the area estimate) and **one more cycle** (5 -> 4 at
  `HDR_TREE = 1`), at the same combinational depth. DERIVED saving: 4 cycles
  per position per job, ~0.14% of the card slope, plus roughly 250 LUT. It was
  NOT built, deliberately: the structure above is the one that is measured and
  mutation-tested, and re-deriving all of it for 0.14% was the wrong trade
  late in a track. **It is the first thing to do if this lever is revisited.**
* **THE ODD-LEVEL CARRY IS UNREACHABLE IN EVERY SHIPPING GEOMETRY.** It is
  correct -- KILLED mutants at `NBLK = 5` prove the checker can see it and the
  anchors prove it computes the right answer at 3, 5, 6 and 7 -- but nothing
  in the build exercises it, so it is carried code. Removing it would make
  `NBLK` a power of two by contract; that contract is not stated anywhere
  today and was not added.
* **`T6` SAYS THE `p_ready` CONTRACT HOLDS ON THE CONSUMER'S LATENCY, NOT ON
  THIS UNIT'S STRUCTURE**, and nothing checks it. A consumer that issued
  combinationally off `p_ready` would break `attn_score_q12` silently. No
  assert was added because the obvious one is a tautology over the state
  variable; the right check is on the CONSUMER and was not attempted.
* **`HDR_TREE` HAS NOT BEEN RUN ABOVE RD_LAT 100.** It shrinks the
  per-position budget further, so it shrinks the cache's prefetch runway
  further, and CSWEEP's own runway figure (~RD_LAT 150) has not been
  re-measured with it on. The card's real read latency in core cycles has
  never been measured either.
* **NO `llama_top` / `fk33_llama_top` / `cardtop` ROW RUNS WITH THE GENERIC
  ON**, because this track does not own those files and `SWEEP_PIPE` /
  `SCORE_EARLY` / `SCORE_HDR_TREE` are all still unplumbed there.
* **THE SUB-ADDITIVITY WITH `SCORE_EARLY` IS MEASURED AT ONE STIMULUS.** 64.00
  against a summed 76.00 is a fact about this bench's schedule. Nothing says
  the 12-cycle overlap is the same on the card's data, and the rescale term
  (0.00 here, and CSWEEP showed this bench cannot move it) is still not
  bounded for the card.
* **THE HARNESS DEFECT IN "`mutate_rtl` echoes empty on failure" IS FIXED ONLY
  IN THIS SCRIPT.** `sim/mutate_attn_score_early.sh` and its siblings carry
  the same `echo ""`. They have not been audited for anchors that no longer
  match, and a drifted anchor there would look exactly like an inert mutant.
  **That audit is a real open item and it is cheap: add the `Z0` row and the
  `__ANCHOR_FAIL__` sentinel to each.**
