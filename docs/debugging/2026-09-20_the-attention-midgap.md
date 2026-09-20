# MIDGAP is not mostly the softmax. A quarter of it is attn_score_q12 walking its own header before a single partial is issued.

Date: 2026-09-20. TRACK MIDGAP. Simulation only; no hardware was touched and
no Vivado was run (both lanes were busy, so every AREA and TIMING claim below
is absent rather than estimated).
RTL at `rtl/attn_block.vhd`, `rtl/attn_score_q12.vhd`, `rtl/attn_softmax.vhd`,
`rtl/attn_mac_array.vhd`, `rtl/attn_recip.vhd`; bench `sim/tb_csweep_rate.vhd`;
mutation script `sim/mutate_attn_score_early.sh`. GHDL mcode.

## The question, verbatim

From `docs/debugging/2026-09-20_c-sweeps-at-5-cycles-per-beat.md`'s closing
open list, quoted in this track's brief:

> "MIDGAP's 56.42 cycles are unsplit; ~40 are the score drain plus softmax,
> DERIVED not measured. That is 84% of what remains. Overlapping position
> p+1's score with p's softmax is the next lever, not attempted."

and the brief's three instructions: split MIDGAP **by measurement**, say for
each span whether the cost is a fixed pipeline latency, a drain, a divide or
a handshake, and then establish from the data dependencies whether the named
overlap is legal.

The symptom it starts from, MEASURED on silicon the same day
(`docs/debugging/2026-09-20_token-cost-grows-2793-cycles-per-position.md`): a
token costs `30,115,217 + 2,793.4 * p` core cycles at 75 MHz, 100% of the
slope is subsystem C, and `664,852 / 8 C jobs / 238 positions = 349.2` cycles
per position per C job.

## The answer

**The DERIVED "~40 cycles of score drain plus softmax" is 26.00. Fourteen of
the forty are a fifth term the derivation did not know existed: P_SCORE sits
for 14.00 cycles with `ar_prdy` LOW before it issues anything, and that is
`attn_score_q12` walking the K record's header one exponent per cycle.** The
derivation counted P_SCORE as "8 score issues" because it reads as an issue
loop; it is an issue loop with a 14-cycle wait in front of it.

MEASURED, `sim/tb_csweep_rate.vhd` at the real 9B geometry, asymptotic slope
per position per KV head, RD_LAT 100:

| span | cycles | what it is | class |
|---|---|---|---|
| P_RECK | 12.79 | 2.79 waiting for the first beat, 8 beats, 2.00 capture tail | handshake + fetch |
| P_HDR | 3.00 | `sq_hdrv` up, `sq_taken` back | handshake |
| **P_SCORE** | **23.00** | **14.00 waiting for `ar_prdy`** + 9.00 issuing | **fixed serial latency** + issue |
| P_SCW | 13.00 | `attn_score_q12`'s accumulate drain and Q12 convert | fixed pipeline latency |
| P_EPW | 13.00 | one pass of `attn_softmax`'s exp cone | fixed pipeline latency |
| P_RSPASS + P_RSACK | **0.00** | the rescale pass | not a term in the slope |
| P_RECV | 11.00 | 1.00 wait, 8 beats, 2.00 tail | handshake + fetch |
| P_PV | 9.00 | 8 write-backs plus one | issue |
| P_POSN | 4.00 | "let the PV write-backs land" | fixed drain |
| **sum** | **88.79** | x N_KVH 4 = **355.17** | |

**And one number in the previous document needs correcting: the KV cache
does NOT contribute zero.** MEASURED here with the `IDEAL_CACHE` control
applied to the phase instrument, which CSWEEP's four-span instrument could
not do: the cache costs **7.17 cycles per position per C job** at RD_LAT 100
(355.17 against the ideal 348.00), of which 6.35 is read latency and 0.82 is
the residency answer. All of it sits in `rk_pre`, the wait for the FIRST K
beat of a record, which `krdy_low` cannot see because it counts only once a
record has started. **This does not overturn CSWEEP's finding**: 7.17 is
**2.0%** of the per-position cost against the 84% it attributed to the score
chain. It corrects one sentence and one arithmetic slip; see "Corrections"
at the end.

**Nothing in the sweep is a divide.** `attn_recip` and `rtl/divider_rs.vhd`
behind it were named as candidates in the brief and they are excluded by
measurement, not by argument: they run in P_RCP / P_RCW
(`rtl/attn_block.vhd:2068` and `:2078`), once per query head AFTER the whole
sweep, and the sum above accounts for the entire slope to the digit, so every
state outside the sweep contributes exactly 0.00 to it.

**The overlap CSWEEP named is NUMERICALLY LEGAL and is blocked by the
schedule in two places, neither of which is the dependency the sentence
suggests.** The score of position p+1 is `Q . K[p+1]` aligned by
`e_min(p+1)`; it reads `qrec`, `krec` and `khdr` and no softmax state, no
running maximum and no accumulator, so it does not depend on position p's
softmax at all. What blocks it:

1. **`krec` does not hold p+1 yet.** Even with `SWEEP_PIPE` the K record of
   p+1 is fetched during P_PV / P_POSN of p, which is *after* the softmax
   window. Moving it earlier puts it in the same window as the V record of p,
   through a capture path that is **one pipe wide** (`rbv` / `rbs`,
   `rtl/attn_block.vhd:1420-1424`).
2. **`attn_mac_array` has ONE multiplier and three mutually exclusive modes**
   (`rtl/attn_mac_array.vhd:339`, *"The lane has ONE multiplier; one of these
   operations is being dropped, not queued"*). P_PV needs it for 9 cycles
   immediately after P_EPW's 13, so a score issue moved into the softmax
   window buys nothing unless the PV moves too.

So the full lever is a depth-2 software pipeline with a 3-deep record queue,
and it was not built. **What was built is the part of it that needs neither:
the HEADER is complete on the record's FIRST beat and the header pass touches
no multiplier, so it can be hoisted on its own.** That is `SCORE_EARLY`, OFF
by default, and MEASURED:

| | per position per KV head | per position per job | saved |
|---|---|---|---|
| base | 88.79 | 355.17 | -- |
| `SWEEP_PIPE` | 68.77 | 275.11 | 80.06 |
| `SCORE_EARLY` | 80.79 | 323.17 | 32.00 |
| **both** | **57.79** | **231.17** | **124.00 (-34.9%)** |

**THE TWO ARE NOT ADDITIVE AND THE PAIR IS WORTH MORE THAN THE SUM.**
80.06 + 32.00 = 112.06; the measured combination is 124.00, i.e. **11.94
cycles per position per job MORE than the sum of the singles.** The mechanism
is visible in the split: with `SWEEP_PIPE` the K record of the next position
is captured during P_PV, so `SCORE_EARLY`'s hand-over happens a whole P_PV
and P_POSN earlier and hides 8.99 of the 14.00 instead of 6.00. **Quote the
pair; never add the two singles.**

## Procedure

1. **Split by measurement, which needed a port.** `attn_block`'s `ph` is a
   locally-declared enumeration, so no bench can name its type and no VHDL
   external name can reach it -- which is exactly why CSWEEP derived the
   split instead of measuring it. Two debug outputs were added:
   `dbg_sw_ph` (a decode of `ph` into NAMED codes, plus `is_byp` on bit 4)
   and `dbg_sw_aux` (`ar_prdy`, `ar_scv`, any `sq_busy`, `ar_pvv`). They are
   combinational decodes of registers that already exist; every instantiation
   in the tree leaves them unassociated, which is legal for mode `out` and
   needs no edit to `rtl/llama_top.vhd` or any generated top.
   **The codes are deliberately not `ph_t'pos`**, so inserting a state cannot
   silently shift a number a document has quoted.
2. **Charge every cycle to one code, exclude the bypass position, and report
   a SLOPE rather than a per-position figure.** A per-position figure still
   carries the once-per-KV-head costs (opening the cache run, the first
   record's read latency) divided over however many positions there happened
   to be; differencing two endpoints removes them exactly, because both runs
   have the same four head openings. This is the method the card's own
   2,793.4 was taken by.
3. **Check the new instrument against the old one before believing it.** The
   bench prints `MIDGAP_SLOPE_SUM` next to `CSWEEP_SLOPE_X100 / N_KVH`. They
   share no code -- one counts phase cycles from `dbg_sw_ph`, the other fits
   a line through two job totals -- and they agree **to the digit in all four
   generic combinations**. That is the check that made the split quotable.
4. **Read the units the FSM waits on and predict each span before looking.**
   `attn_score_q12`'s S_IDLE -> S_EMIN (NBLK-1 compares) -> S_SHIFTS (NBLK
   subtracts) is 15 cycles from the latch, of which 14 fall inside P_SCORE.
   Predicted 14; MEASURED 14.00.
5. **Implement `SCORE_EARLY`, then prove the values did not move**, against
   both independent C oracles, in all four generic combinations.
6. **Mutate it**, every row ON and OFF, with a two-sided test of the one new
   assert and an attribution control for each direction.

## Evidence

### The split, MEASURED, all four arms

Bench `sim/tb_csweep_rate.vhd`, generics
`hd=256 nqh=16 nkvh=4 kvblk=32 nblk=8 rec_b=272 axi_dw=256 maxb=16 maxout=4
rbuf=4 rd_lat=100 stall=0 spread=0 ideal=false`, positions 1/8/16/64.

```
### SWEEP_PIPE=false SCORE_EARLY=false            (the shipping schedule)
CSWEEP_SLOPE_X100 35517
MIDGAP_SLOPE RECK 1279
MIDGAP_SLOPE HDR 300
MIDGAP_SLOPE SCORE 2300
MIDGAP_SLOPE SCW 1300
MIDGAP_SLOPE EPW 1300
MIDGAP_SLOPE RSPASS 0
MIDGAP_SLOPE RSACK 0
MIDGAP_SLOPE RECV 1100
MIDGAP_SLOPE PV 900
MIDGAP_SLOPE POSN 400
MIDGAP_SLOPE_SUM 8879 expect_slope_over_nkvh=8879
MIDGAP_SLOPE_SUB sc_wait=1400 sc_iss=900 rk_pre=279 rk_post=200 rv_pre=100 rv_post=200
CSWEEP_STATUS err='0' kv_err='0' slv_bad=0
CSWEEP: PASS

### SWEEP_PIPE=true SCORE_EARLY=false
CSWEEP_SLOPE_X100 27511
MIDGAP_SLOPE RECK 277    HDR 300   SCORE 2300  SCW 1300  EPW 1300
MIDGAP_SLOPE RSPASS 0    RSACK 0   RECV 100    PV 900    POSN 400
MIDGAP_SLOPE_SUM 6877 expect_slope_over_nkvh=6877
MIDGAP_SLOPE_SUB sc_wait=1400 sc_iss=900 rk_pre=277 rk_post=0 rv_pre=100 rv_post=0
CSWEEP: PASS

### SWEEP_PIPE=false SCORE_EARLY=true
CSWEEP_SLOPE_X100 32317
MIDGAP_SLOPE RECK 1279   HDR 100   SCORE 1700  SCW 1300  EPW 1300
MIDGAP_SLOPE RSPASS 0    RSACK 0   RECV 1100   PV 900    POSN 400
MIDGAP_SLOPE_SUM 8079 expect_slope_over_nkvh=8079
MIDGAP_SLOPE_SUB sc_wait=800 sc_iss=900 rk_pre=279 rk_post=200 rv_pre=100 rv_post=200
CSWEEP: PASS

### SWEEP_PIPE=true SCORE_EARLY=true
CSWEEP_SLOPE_X100 23117
MIDGAP_SLOPE RECK 277    HDR 100   SCORE 1401  SCW 1300  EPW 1300
MIDGAP_SLOPE RSPASS 0    RSACK 0   RECV 100    PV 900    POSN 400
MIDGAP_SLOPE_SUM 5779 expect_slope_over_nkvh=5779
MIDGAP_SLOPE_SUB sc_wait=501 sc_iss=900 rk_pre=277 rk_post=0 rv_pre=100 rv_post=0
CSWEEP: PASS
```

`MIDGAP_SLOPE_SUM` equals `CSWEEP_SLOPE_X100 / 4` in every arm, to the digit.

### The cache control, which is where the correction comes from

Three more arms, `SWEEP_PIPE=false SCORE_EARLY=false`, only the memory moving.
`IDEAL_CACHE` replaces `attn_kv_axi` with a memory that cannot refuse; it is
CSWEEP's own control, applied here to the phase instrument instead of to the
four spans.

| arm | `rk_pre` | RECK | slope, per job | delta vs ideal |
|---|---|---|---|---|
| ideal cache, RD_LAT 0 | 1.00 | 11.00 | 348.00 | -- |
| ideal cache, RD_LAT 100 | 1.00 | 11.00 | 348.00 | 0.00 |
| real cache, RD_LAT 0 | **1.20** | 11.20 | **348.82** | **+0.82** |
| real cache, RD_LAT 100 | **2.79** | 12.79 | **355.17** | **+7.17** |

Every other span is identical to the digit across all four. **The entire cost
of the cache is the wait for the first K beat of a record**, it is 2.0% of
the position, and 6.35 of its 7.17 cycles scale with read latency. The ideal
arm is invariant in RD_LAT, which is the control that says the instrument is
measuring the memory and not itself.

### The measured MIDGAP against the derivation

MIDGAP as CSWEEP defines it -- the 8th `kr_en` to the 1st `vr_en` -- has a
slope of **56.00** cycles (`(14444 - 332) / 252`, from the base arm's
`CSWEEP_BREAK` lines at positions 64 and 1). Its parts, each now a counter
rather than a subtraction:

| part | cycles | share |
|---|---|---|
| the boundary cycle itself | 1.00 | 1.8% |
| P_RECK after the last beat (`rk_post`) | 2.00 | 3.6% |
| P_HDR | 3.00 | 5.4% |
| **P_SCORE waiting for `ar_prdy` (`sc_wait`)** | **14.00** | **25.0%** |
| P_SCORE issuing (`sc_iss`) | 9.00 | 16.1% |
| P_SCW | 13.00 | 23.2% |
| P_EPW | 13.00 | 23.2% |
| P_RSPASS + P_RSACK | 0.00 | 0% |
| P_RECV before the first beat (`rv_pre`) | 1.00 | 1.8% |
| total | 56.00 | |

**DERIVED was "about 40 for the score drain plus the softmax". MEASURED is
26.00, and the measurement wins.** 65% of the derived figure survives. The
missing 14 was charged by the derivation to "8 score issues", one of its
"countable parts"; P_SCORE is 23 cycles, not 8.

### What each span IS, from the RTL

* **P_SCORE's 14.00, a FIXED SERIAL LATENCY in another unit.**
  `rtl/attn_block.vhd:1916` issues a block only `if ar_prdy = '1'`, and
  `:991` is `ar_prdy <= '1' when all_ones(sq_prdy) else '0'` -- every score
  unit's `p_ready`. `rtl/attn_score_q12.vhd` raises it at the END of its
  header pass:

  ```vhdl
  when S_EMIN =>                       -- :343, NBLK-1 = 7 cycles
    if e_l(blk) < e_min then e_min <= e_l(blk); end if;
  when S_SHIFTS =>                     -- :357, NBLK = 8 cycles
    sv := to_integer(e_l(blk)) - to_integer(e_min);
    shb(blk) <= to_unsigned(sv, SHW);
    if blk = NBLK-1 then
      blk   <= 0;
      p_rdy <= '1';          -- ready BEFORE the first partial can come
  ```

  One narrow compare per cycle then one narrow subtract per cycle, plus the
  S_IDLE latch: 15 cycles, 14 of them inside P_SCORE. The unit's own header
  says why it is serial -- *"Precomputing the per-block shift in S_SHIFTS is
  what makes p_ready unconditional"* -- so this is a deliberate cost, not a
  defect. It is also **pure function of the header**, which is what makes it
  hoistable.
* **P_SCW's 13.00, a FIXED PIPELINE LATENCY.** `:1928` waits
  `all_zero(sq_busy)`. That is `attn_score_q12`'s three-stage accumulate
  emptying (`S_ACC`, capture / barrel shift / wide add, :374) then
  S_EXP1, S_EXP2, S_SH, S_Q1, S_Q2, S_DONE. Nothing elastic; no memory in it.
* **P_EPW's 13.00, a FIXED PIPELINE LATENCY.** `:1936` waits for every head's
  `e_p`. One pass of `attn_softmax`'s S_RUN -> S_CEIL -> S_TEST -> S_ZED and
  the exp cone. `sc_ready <= '1' when state = S_RUN` (`attn_softmax.vhd:402`)
  means the score is accepted the cycle it is produced, so **the score unit is
  already idle when P_EPW begins** -- that is the fact `SCORE_EARLY` uses.
* **P_HDR's 3.00, a HANDSHAKE.** `sq_hdrv` up, latched, `sq_taken` back.
* **P_RECK's 12.79 and P_RECV's 11.00**, 8 beats each plus a 2-cycle capture
  tail (`rbv(1)` -> `rbv(2)` -> the write, :1420-1424) plus a wait for the
  first beat. `rk_pre` is 2.79 per position and **the four-span instrument
  cannot see it**: `krdy_low` is counted only once a record has started, so a
  wait for the FIRST beat is invisible to it. That is a gap in CSWEEP's
  instrument, found here, and it is why the phase sum (88.79) and the
  four-span sum (87.42) differ -- and it is where the whole cost of the KV
  cache turned out to be hiding.
* **P_RSPASS / P_RSACK's 0.00.** The rescale fires in the first position or
  two of a head and never again at this stimulus. It is **not a term in the
  slope**. What this does NOT establish is the card's rescale rate; see the
  open list.
* **No divide anywhere in the sweep.** `attn_recip` is `NW + 7 = 51` cycles
  per invocation and runs at `:2068` / `:2078`, once per query head after
  P_SFW. Its own header books it at *"under 9,000 cycles of a 1.3-million
  cycle subsystem"*. The slope-sum identity above is the proof that it
  contributes nothing per position.

### `SCORE_EARLY`: what it changes

`rtl/attn_block.vhd`, generic `SCORE_EARLY : boolean := false`. It moves WHEN
`sq_hdrv` is raised and nothing else. Two signals, both inert with the
generic false: `se_rdy` (the K header of the position about to be scored has
been captured) and `se_sent` (every score unit has taken it, so P_HDR is a
no-op).

* The arm is set on the **first captured beat of a K record** and on no other
  (`pk_cnt = 0` under `SWEEP_PIPE`, `rbi = 0` otherwise).
* The hand-over runs **after** the phase case and is gated `ph /= P_HDR`, so
  it and P_HDR's own branch are DISJOINT drivers of `sq_hdrv` rather than two
  assignments in one delta where the later silently wins. This file already
  records that exact shape costing a real defect at the `vhdr` capture.
* The only other guard is `all_zero(sq_busy)`. A score unit takes a header
  only in S_IDLE, and the sweep does not leave P_SCW until every unit is back
  there, so from P_EPW of position p until the hand-over for p+1 every unit
  is idle. **The gate is a check of the thing itself, not a reading of the
  schedule**, so it survives the schedule moving -- which is the whole reason
  the same code works in both `SWEEP_PIPE` modes.
* P_HDR's old path is kept and is **not dead code**: the BYPASS position at
  every head reads no record, never arms, and goes down it.
* A score unit that has taken its header early sits in S_ACC with `p_ready`
  high and receives nothing, because `attn_mac_array` raises `p_valid` only
  in M_SCORE mode (`rtl/attn_mac_array.vhd:456`, `pv_r <= '1'` inside
  `when M_SCORE =>`) and the only issuer of M_SCORE is P_SCORE.

**One new assumption, and it is CHECKED rather than assumed.** The old path
read `khdr` only after beat NBLK-1, so it was indifferent to whether `kr_hdr`
stood for the whole record; this path is not. Both producers do stand it --
`rtl/attn_kv_axi.vhd:753` replays the slot header with every beat, and
`sim/tb_attn_block.vhd`'s model does the same -- and a `severity failure`
assert at the capture now makes that a property of the CONNECTION rather than
a reading of two files.

### Values are bit-identical, against two independent oracles

Not a round trip. Both oracles are C references sharing none of the RTL's
machinery. All four generic combinations, both benches:

```
tb_attn_block  SCORE_EARLY=false SWEEP_PIPE=false   @81465ns
tb_attn_block  SCORE_EARLY=true  SWEEP_PIPE=false   @80665ns
tb_attn_block  SCORE_EARLY=false SWEEP_PIPE=true    @79685ns
tb_attn_block  SCORE_EARLY=true  SWEEP_PIPE=true    @78755ns
  all four:
  tb_attn_block: PASS -- 3 consumer configurations, 64 elements each, y
  stream bit-identical across all of them, y_exp tracks vin_exp exactly, the
  current position was never read back, y_exp(run 0) = 15, and BIT-EXACT
  against ref/attn_block_vec.c over 130 compared values

tb_attn_kv_seam SCORE_EARLY=false SWEEP_PIPE=false  @457945ns
tb_attn_kv_seam SCORE_EARLY=true  SWEEP_PIPE=false  @456965ns
tb_attn_kv_seam SCORE_EARLY=false SWEEP_PIPE=true   @455905ns
tb_attn_kv_seam SCORE_EARLY=true  SWEEP_PIPE=true   @454935ns
  all four:
  tb_attn_kv_seam: PASS -- 4 tokens at cur_pos 0..3 x 2 layers INTERLEAVED
  token-major (8 jobs) through rtl/attn_kv_axi.vhd over AXI at 100-cycle read
  latency, BIT-EXACT against ref/attn_block_seq_vec.c over 2056 output values
  and 2176 record bytes in HBM, every returned beat matched to the layer and
  position it was requested for, k_base=16 v_base=4064 (neither 4 KB
  aligned), MAXCTX=8, longest quiet stretch 2137 cycles
```

The verdict text is identical in all eight runs and the WALL TIME falls
monotonically in the expected order, which is the cheap cross-check that the
generics did something at a geometry four times smaller than the card's.
`tb_attn_kv_seam` is the one that matters, because Q2 checks the record
IMAGE in HBM at C spec 2.2's address and Q3 matches every returned beat to
the `(layer, head, position, block)` it was requested for: a header taken
from the wrong record would be caught there even if it happened to produce a
plausible `y`.

## Teeth

`sim/mutate_attn_score_early.sh`, oracle `sim/tb_attn_kv_seam.vhd` against
`ref/attn_block_seq_vec.c`. Every row is run twice, ON and OFF, and the OFF
run is the attribution control. Verdicts are `sim/mutverdict.py`'s three:
**KILLED means the CHECKER noticed and said so; ABORT means the run never
reached a verdict the checker owns**, and an ABORT is NOT counted as a kill.

**THE TABLE IS THE ONE FROM THE HARDENED TREE.** An earlier run of the same
script, against `rtl/attn_block.vhd` before the `se_rdy <= '0'` clear was
added to P_HDR, killed `E6` and `E7` -- the two rows written to be inert --
and SURVIVED `E5`. That run is described under "The mutants changed the RTL"
below and is not quoted as a result; every number here is from the committed
tree.

| row | what it breaks | ON | OFF | reading |
|---|---|---|---|---|
| `A` | nothing, the anchors | PASS | PASS | both anchors clean |
| `E1` | `se_rdy` armed on every K beat -- **via an edit that also moved the new assert's own guard** | ABORT:DUTASSERT | PASS | **A BAD MUTANT. NOT A DETECTION.** See below. |
| `E1c` | `E1` with the new assert DISABLED | PASS | -- | the value oracle sees nothing in `E1` either |
| `E1b` | the same behaviour, assert guard left intact | PASS | PASS | **DID NOT BITE** |
| `E2` | the `all_zero(sq_busy)` guard dropped from the arm | PASS | PASS | **DID NOT BITE** |
| `E3` | `se_sent` never cleared at P_HDR | **KILLED** | PASS | clean, fully attributed |
| `E4` | P_HDR's fallback removed, so the bypass position gets no header | **KILLED** | PASS | clean, fully attributed |
| `E5` | the `ph /= P_HDR` disjointness gate removed | **KILLED** | PASS | clean, fully attributed (a hang, caught by the bench's watchdog) |
| `H0` | `kr_hdr` right only on beat 0, **K stream only** | KILLED | **KILLED** | |
| `H0c` | `H0` with the new assert DISABLED | **KILLED** | -- | **the assert is NOT a new detection** |
| `H7` | `kr_hdr` right only on the LAST beat, K stream only | KILLED | **KILLED** | |
| `H7c` | `H7` with the new assert DISABLED | **KILLED** | -- | same verdict from the other direction |
| `E6` | the arm delayed past P_RECK | PASS | -- | inert **after** the hardening; killed before it |
| `E7` | the arm held off while a capture lands | PASS | -- | inert **after** the hardening; killed before it |

```
 TOTAL 23   KILLED 9   SURVIVED 13   ABORT 1
   A_on PASS     A_off PASS
   E1_on ABORT:DUTASSERT(attn_block.vhd)   E1_off PASS   E1c_on PASS
   E1b_on PASS   E1b_off PASS
   E2_on PASS    E2_off PASS
   E3_on KILLED  E3_off PASS
   E4_on KILLED  E4_off PASS
   E5_on KILLED  E5_off PASS
   H0_on KILLED  H0_off KILLED  H0c_on KILLED
   H7_on KILLED  H7_off KILLED  H7c_on KILLED
   E6_on PASS    E7_on PASS
```

Row by row, including every row that does not bite:

* **`E1` IS A BADLY BUILT MUTANT AND ITS OWN RESULT IS WHAT SAYS SO.** It
  replaced the `if` that guards BOTH the arm and the new assert, so the
  assert then ran on beat 0 -- where `khdr` legitimately still holds the
  PREVIOUS record's header -- and fired for a reason that has nothing to do
  with the behaviour being mutated. **Its ABORT is not a detection and must
  not be counted as one.** This is this project's recorded "a teeth test
  whose mutant is built from the same misconception as the check" in a new
  form: here the mutant did not share the check's misconception, it
  physically moved the check.
* **`E1c` and `E1b` are what `E1` should have been, and neither bites.**
  `E1c` is `E1` with the assert disabled and it SURVIVES; `E1b` makes the
  same behavioural change with the assert's guard untouched and it SURVIVES
  in both modes. **So arming `se_rdy` more than once per record is
  value-neutral at this schedule**, and the "first beat and no other"
  restriction is a property of the assert's guard rather than of the
  hand-over. That is a smaller claim than the RTL comment implied and the
  comment should be read with it.
* **`E2` DID NOT BITE, and the honest reading is that `all_zero(sq_busy)` is
  defence in depth rather than a live check.** `se_rdy` only ever rises at an
  instant when the score units are already idle, so the guard is never the
  binding condition on the shipping schedule. It is kept because it is the
  condition that makes the hand-over correct independently of the schedule --
  but it has NOT been shown to discriminate, and by this project's own
  standard that means it is not yet earning its place.
* **`E3`, `E4` and `E5` are three clean attributed kills**, each SURVIVING
  with the generic off, so each kill belongs to `SCORE_EARLY`. `E4` is the
  one that proves P_HDR's old path is not dead code: remove it and the bypass
  position at every head runs its score against a header it never received.
  `E5` is a hang rather than a wrong number -- `tb_attn_kv_seam.vhd:637`,
  *"20000 cycles with the block busy and no cache traffic"* -- because a
  score unit that never latched a header never raises `p_ready` and P_SCORE
  waits for ever.
* **`H0` / `H7` fire the new assert, and the attribution controls say it is
  NOT a new detection.** Both `H0c` and `H7c` -- the same mutants with the
  assert disabled -- are KILLED by the value oracle. Worse for the assert's
  case: `tb_attn_kv_seam.vhd:1082` already checks that *"the K header
  returned with pos 0 is not that position's header"* and it fires in the
  SAME CYCLE as the assert in `H0_on` and `H7_on`. **So on every mutant that
  reaches it, something older gets there too.** The assert is kept because it
  states the assumption at the point of USE and names the cycle and the
  cause, which a value mismatch four tokens later does not -- but it must be
  recorded as a diagnostic, not as a detection, exactly as CSWEEP recorded
  its own `P5c`.
  A caveat on what `H0` / `H7` can test at all: they break the PRODUCER
  (`rtl/attn_kv_axi.vhd`), and the seam bench already polices the producer.
  A mutant that would exercise the assert without tripping an older property
  would have to break the block's own use of a correct header, and **no such
  mutant was constructed.**
* **`E6` and `E7` are the two honest non-biting rows, and they are only
  non-biting because the RTL was changed in response to them.** Both delay
  the arm; both were written as pure schedule changes; both were KILLED
  before the `se_rdy <= '0'` clear existed and both SURVIVE after it. That is
  the measurement the pair is worth: it says the value oracle cannot see a
  hand-over that happens seven cycles later with the same header, which is
  the resolution floor, AND it says the design now actually has that property
  instead of appearing to.

### The mutants changed the RTL, and that is reported rather than hidden

The first full run of this script, against the RTL as first written, returned
`E5_on PASS`, `E6_on KILLED` and `E7_on KILLED`. Two rows written to be inert
were not inert, which meant the design had a property nobody had stated:
**`se_rdy` is a level with no deadline.** If the arm had not consumed it by
the time P_HDR ran, the arm simply fired later -- at P_EPW, the next moment
the score units go idle -- and that hand-over carried the header of the
position just FINISHED while setting `se_sent`, so the NEXT position's P_HDR
skipped on it. On the shipping schedule the arm always fires inside P_RECK,
so this never happened; correctness rested on a timing coincidence rather
than on a structural guard.

The fix is one line at the top of P_HDR: `if SCORE_EARLY then se_rdy <= '0';
end if;`. **The whole A/B, both value oracles and every arm above were re-run
against the hardened file**, and it is free at the card geometry (all four
rate arms identical to the digit: 355.17 / 275.11 / 323.17 / 231.17) and
costs ONE CYCLE in one of the eight oracle runs (`tb_attn_kv_seam`,
`SCORE_EARLY` and `SWEEP_PIPE` both on, 454,925 ns -> 454,935 ns) with no
value changed. **That one cycle is the proof the line is not inert**, and it
is the difference between the arm firing late and not firing at all.

It also made `E5` load-bearing: before the hardening, removing the
disjointness gate was masked because `se_rdy` stayed set and the arm re-fired;
after it, the same removal hangs the block. **A guard that only becomes
testable once a neighbouring defect is fixed is the ordinary case, not a
strange one**, and it is the argument for re-running a whole mutant table
after any change rather than patching the rows that moved.


## The gate rows, every OVERALL line verbatim

All five groups were run AFTER the last edit to any RTL file, against the
committed tree, one `regress.sh` invocation per group with its own
`REGRESS_SCRATCH` under `/mnt/storage`.

**EVERY GROUP CARRIES AN md5 WINDOW, and the first attempt failed it.** TRACK
PATHFREE was editing `sim/regress.sh` and TRACK GSRWIDE `rtl/llama_top.vhd`
while this track ran, so the runner and every RTL file each group compiles
were hashed at the start of the run and again at the end. The first
five-group run came back GREEN on all five and its guard fired:
`rtl/llama_top.vhd` moved `4acda69a` -> `2ac7456b` and `rtl/fk33_llama_top.vhd`
with it, GSRWIDE's `SWG_LANES` / `SWG_WIDE` landing mid-run. `sim/regress.sh`
did NOT move in any window. **That run is VOID and is not quoted**; the three
groups that touch `llama_top` in any way were re-run in fresh windows:
`seamgate` and `tb_llama_top_kv` compile it, and `kvmap` PARSES it
(`tools/check_kv_map.py:102`). `tb_csweep_rate` and `tb_attn` were re-run as
well rather than argued about.

```
########## --only tb_csweep_rate          (window GATE4, md5 MATCH)
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## --only tb_attn                 (window GATE4, md5 MATCH)
 suite sim   PASS 16   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 16   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1   SKIPPED 4
 REGRESSION: PASS
########## --only seamgate                (window GATE2, md5 MATCH)
 suite sim   PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## --only tb_llama_top_kv          (window GATE2, md5 MATCH)
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
########## --only kvmap                    (window GATE3, md5 MATCH)
 suite sim   PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

Each window printed `GATE<n>_MD5_MATCH: every watched file byte-identical
start to end`. The GATE2 and GATE3 windows also hashed `rtl/llama_top.vhd`,
`rtl/fk33_llama_top.vhd` and `tools/check_kv_map.py`; the GATE4 window hashed
`sim/regress.sh` and the fourteen RTL files plus three benches those two
groups compile.

`--only` takes a SUBSTRING, not a regex, and `PASS 0` would mean the pattern
matched nothing; every group above has a non-zero PASS. `--only tb_attn`
reports `NOCHECK 1` and `SKIPPED 4`, which is its standing shape (the
`library beh` netlist-compare rows need xsim + UNISIM) and is unchanged by
this work -- the brief's instruction was not to let `PASS 16` regress, and it
did not.

## Measured and REJECTED -- do not retry

* **"MIDGAP is mostly the softmax; attack `attn_softmax`."** REJECTED by
  measurement. P_EPW is 13.00 of 56.00, i.e. 23%. Halving the exp cone's
  latency would buy 6.5 cycles of 88.79.
* **"The score drain is the big term."** REJECTED. P_SCW is also 13.00, the
  same 23%.
* **"A divide is in the per-position path."** REJECTED. `attn_recip` /
  `divider_rs` run once per query head after the sweep and contribute
  **0.00** to the slope, proved by the slope-sum identity rather than by
  reading the schedule.
* **"The rescale pass is a term in the slope."** REJECTED at this stimulus:
  0.00 at the asymptote in all four arms. Note this is a statement about the
  bench's stimulus, and CSWEEP's `SPREAD` control already showed the bench
  does not move that term -- so it is NOT a statement about the card.
* **"Add the two generics' savings."** REJECTED, and it errs in the
  PESSIMISTIC direction: 80.06 + 32.00 = 112.06 against a measured 124.00.
* **"The overlap is illegal because the softmax is serial."** REJECTED. The
  running maximum is serial; the SCORE is not, and the score is what the
  lever moves. The blockers are the one-wide capture pipe and the single
  multiplier array, both named above with line numbers.

## Measurement traps hit

1. **I wrote the combined-arm figures into `rtl/attn_block.vhd`'s comment
   table as 60.77 / 243.09 before that arm had finished running.** They were
   a prediction from the two singles, they were WRONG (57.79 / 231.17,
   because the generics are superadditive), and they were sitting in a
   committed-looking table for several minutes. Caught by checking the log
   before moving on, not by any process. **The rule that would have prevented
   it is the obvious one and it was not followed: do not write a number down
   until the run that produces it has printed it.**
2. **A per-position figure and a slope are different numbers and the
   difference is a per-HEAD constant.** The phase instrument's per-position
   RECK at position 64 is 12.76 and its slope is 12.79; the four-span
   MIDGAP's per-pair figure is 56.42 and its slope is 56.00. The gap is the
   once-per-head cache opening amortised over however many positions the run
   had. Quote the slope: it is what the card measured.
3. **CSWEEP's `krdy_low` cannot see a wait for the FIRST beat of a record.**
   It is counted only when `kc > 0`. MEASURED here as `rk_pre = 2.79` cycles
   per position -- real waiting that the residency counter reports as zero,
   and it turned out to be the entire cost of the KV cache. **"krdy_low = 0"
   is not "the block never waited for a beat"**, and it was read that way.
   The general form: **a counter with a start condition cannot measure the
   start condition.**
4. **TWO ROWS THAT I WROTE TO BE INERT WERE NOT, AND BOTH TIMES I BELIEVED
   THE DESCRIPTION OVER THE RESULT FOR A MINUTE.** `E6` and `E7` were
   constructed as pure schedule changes, were KILLED by the value oracle, and
   the first reaction in each case was to look for a flaw in the mutant. The
   flaw was in the RTL: delaying the arm did not delay the hand-over, it
   MOVED it to a point where the header had changed. **When a mutant you
   designed to be invisible is seen, the default hypothesis should be that
   the design has a property you did not know about**, not that the mutant is
   wrong. CSWEEP's `P7` is the same shape (an intended non-biting row that
   turned out to be unreachable) and it went the other way.
5. **A GATE RUN THAT OVERLAPPED ANOTHER TRACK'S EDIT WAS CAUGHT BY ITS OWN
   md5 GUARD, and two of its five green groups were void.** MEASURED: the
   five-group run started at `rtl/llama_top.vhd` = `4acda69a...` and ended at
   `2ac7456b...`, because TRACK GSRWIDE added `SWG_LANES` / `SWG_WIDE` to it
   while the run was live. `sim/regress.sh` itself did not move. The two
   groups that compile or read that file -- `seamgate` and `tb_llama_top_kv`,
   and `kvmap`, whose `tools/check_kv_map.py` PARSES `llama_top.vhd` for
   generic names -- were re-run in a fresh window rather than quoted.
   **The guard is worth more than the re-run it cost**: all five groups were
   GREEN in the void window, so nothing looked wrong, and without the md5 the
   verdict would have been reported as clean without anyone knowing which
   tree it was about. A green result from a moving tree is still a result
   about no particular tree.
6. **A bench's `grep` filter is part of the measurement.** The first two
   value-identity batches printed EIGHT headings and not one verdict, because
   the filter was anchored `^tb_attn_block:` while GHDL prefixes every report
   with `file:line:col:@time:(report note): `. An empty section under a
   heading that looks like it ran is this project's recorded trap in a new
   place; the fix is to check that each section is non-empty before reading
   the batch.
7. **A vector file's shape is a silent prerequisite.** The same batch also
   died once on `attn_block_vec.txt shape 64/4/2/16/16/3/4 does not match this
   bench's generics` because the generator arguments were copied from the
   SEAM bench's row. The arguments per vector file live in `sim/regress.sh`
   (`attn_block_vec.txt` is `16 4 2 4 8 3 4 0`); take them from there rather
   than from a neighbouring script.
8. **An added `out` port is free in VHDL and not free in a tree.** Adding
   `dbg_sw_ph` / `dbg_sw_aux` to `attn_block` is legal at every existing
   instantiation because an unassociated formal of mode `out` is legal -- but
   that had to be checked against FIVE instantiations
   (`rtl/llama_top.vhd:6621`, `rtl/fk33_llama_top.vhd:7245`,
   `rtl/ooc_cattnadapt_top.vhd:707`, `hw/fk33/rtl/compose4_top.vhd:2231`,
   and the benches) before it could be called free. It was; no instantiation
   was edited.

## The exact change for the dispatcher

**`rtl/llama_top.vhd` is NOT this track's file and was NOT edited.** It is
also the INPUT to `tools/gen_cardtop.py`, which emits
`rtl/fk33_llama_top.vhd`, and nothing on the source says so. So the sequence
is: edit `llama_top.vhd`, regenerate, `git diff` the generated file and
confirm it contains that change and nothing else, then
`sim/regress.sh --only cardtop`.

At `rtl/llama_top.vhd:6621`, the `u_attn : entity work.attn_block` instance:

```vhdl
        NORM_LANES => 1, STRICT_PRODUCER => true)     -- before

        NORM_LANES => 1, STRICT_PRODUCER => true,     -- after
        SWEEP_PIPE => true, SCORE_EARLY => true)
```

Either generic may be set alone. **Do not credit them separately**: the
measured pair is 124.00 cycles per position per job and the two singles sum
to 112.06.

## DERIVED on the card

Scaling the card's MEASURED 2,793.4 cycles per position by the MEASURED
per-position-per-head ratios (68.77 / 80.79 / 57.79 against 88.79), at the
75 MHz core clock the silicon measurement implies:

| | token slope, cycles/position | | |
|---|---|---|---|
| now | 2,793.4 | | |
| `SWEEP_PIPE` | 2,163.6 | | |
| `SCORE_EARLY` | 2,541.7 | | |
| both | **1,818.1** | | |

| position | now | `SWEEP_PIPE` | `SCORE_EARLY` | both |
|---|---|---|---|---|
| 0 | 2.4904 tok/s | 2.4904 | 2.4904 | 2.4904 |
| 2,048 | 2.0929 | 2.1710 (+3.7%) | 2.1234 (+1.5%) | 2.2164 (**+5.9%**) |
| 8,192 | 1.4151 | 1.5678 (+10.8%) | 1.4724 (+4.0%) | 1.6664 (**+17.8%**) |
| 65,536 | 0.3518 | 0.4363 (+24.0%) | 0.3813 (+8.4%) | 0.5025 (**+42.8%**) |

The intercept does not move: at p = 0 the sweep has only the bypass position
and reads no record.

A METHOD NOTE, because it produces a visible disagreement with the previous
document. CSWEEP derived its `SWEEP_PIPE` projection from the per-PAIR ratio
`67.37 / 87.42 = 0.77065` and got a slope of 2,152.7. This document uses the
per-position SLOPE ratio `68.77 / 88.79 = 0.77452` and gets 2,163.6. The
0.5% difference is entirely the method; both are DERIVED from the same bench
and the same card figure. The slope ratio is preferred here because the
phase instrument's slope is checked against the job-total slope to the digit,
and because the card's own 2,793.4 is itself a slope.

## Open, not determined

* **THE FULL OVERLAP IS NOT BUILT.** Issuing position p+1's score partials
  inside position p's P_EPW is resource-feasible on the numbers -- the array
  is idle for those 13 cycles and the issue is 9 -- and would remove up to
  26.00 more cycles per position per head. It needs a 3-deep record pipeline
  through a one-wide capture path and an arbitration between the score issue
  of p+1 and the PV issue of p. **That is a much larger change to a bit-exact
  block and it was not attempted.** The saving above is a DERIVED ceiling
  from the phase table, not a measurement of anything.
* **THE AREA AND TIMING COST OF `SCORE_EARLY` IS UNMEASURED.** No Vivado was
  run: the workstation's lane was on a card build and the BC-250's was on
  TRACK LEVERCOST. DERIVED from the diff, the added state is **2 flip-flops**
  (`se_rdy`, `se_sent`) plus a small amount of control logic, and the two
  debug ports are decodes that are trimmed when unassociated. That is an
  ESTIMATE and this project's record says an estimate of this kind has been
  wrong by 12 percentage points before. **Do not set either generic on a
  build without an OOC run.** `SWEEP_PIPE`'s area is likewise still
  unmeasured, from CSWEEP's own open list.
* **`SCORE_EARLY` WAS NOT RUN AT RD_LAT ABOVE 100.** CSWEEP established that
  the cache is transparent to about RD_LAT 150 and that `SWEEP_PIPE` shrinks
  that runway. `SCORE_EARLY` shrinks the per-position budget further, so it
  shrinks the runway further, and **the RD_LAT 200 / 400 rows with both
  generics on have not been run.** The card's real read latency in core
  cycles has never been measured either.
* **THE RESCALE TERM IS STILL NOT BOUNDED FOR THE CARD.** It measures 0.00 at
  the asymptote here, and CSWEEP's `SPREAD` control showed this bench cannot
  move it, so "the card's rescale rate is zero" is NOT established. If the
  card's data makes the running maximum rise often, P_RSPASS / P_RSACK become
  a term that none of these numbers include.
* **`pk_cnt` / `pv_cnt` STILL DO NOT SATURATE**, from CSWEEP's open list. It
  was not applied here either, for the same reason: applying it would have
  invalidated every A/B and oracle run in this document. It remains the first
  item of open work on `SWEEP_PIPE`.
* **No `llama_top` / `fk33_llama_top` row runs with either generic on**,
  because this track does not own those files.
* **`SCORE_EARLY` has not been run at any geometry between the seam bench's
  (HEAD_DIM 64, NBLK 4) and the card's (HEAD_DIM 256, NBLK 8).** Both were
  run; nothing in between was. In particular the header pass is `2*NBLK - 1`
  cycles, so its size is a function of NBLK and the 14.00 measured here is
  the NBLK = 8 figure, not a constant.
* **`rk_pre`'s remaining 1.00 cycle is STRUCTURAL and was not attacked.**
  Even with the cache deleted, P_RECK cannot issue in its first cycle because
  `kr_en` is registered. One cycle per position per head, 4.00 per job.
* **Shortening the header pass itself was NOT attempted.** `S_EMIN` is a
  7-cycle linear scan for a minimum over 8 int8s and `S_SHIFTS` is 8 serial
  subtracts; a 3-level tree and 8 parallel subtracts would be about 4 cycles
  instead of 15. That changes a verified unit's area and its critical path,
  **and with no Vivado available there is no way to say what it costs**, so
  it is named and not done.

## Corrections to `docs/debugging/2026-09-20_c-sweeps-at-5-cycles-per-beat.md`

Appended in place rather than by editing that file's history. Neither
correction overturns its headline -- the per-position cost is the sweep FSM,
the fix is a schedule fix, and the score chain is where the cycles are. Both
are about one secondary number.

**CORRECTION 1, 2026-09-20: "`rtl/attn_kv_axi.vhd` contributes ZERO cycles"
is WITHDRAWN. It contributes 7.17 cycles per position per C job at RD_LAT
100, which is 2.0%.** MEASURED, the table above. The claim was made on three
supports and each fails in a different way at this resolution:

* `krdy_low = vrdy_low = 0` is true and does not mean what it was read to
  mean. The counter is gated on `kc > 0`, so it starts counting only after a
  record's first beat has issued and is **structurally incapable of seeing a
  wait for that first beat**. That wait is the entire cost.
* the `IDEAL_CACHE` control reproduced `kspan / midgap / vspan / loop` to
  the integer, which is also true. Those four are per-PAIR figures and the
  cost is per-POSITION in a place the partition does not separate; the same
  control read through the phase instrument shows RECK 11.00 against 12.79.
* the RD_LAT sweep left all four spans unchanged from 0 to 100, also true,
  **while that same table's own slope column moved from 348.82 to 355.17.**
  Four spans that do not move and a slope that moves by 6.35 cannot both be
  the whole story, and nothing reconciled them.

**CORRECTION 2, same date: an arithmetic slip and the attribution that rested
on it.** That document says *"The endpoint slope differs by 0.7 cycles per
position (348.00 against 355.17)"*. The difference between 348.00 and 355.17
is **7.17**, not 0.7. It then attributes the gap to *"a per-JOB cost of about
8 x 100 cycles and not a per-position one"* -- and **a per-job constant
cannot appear in a slope at all**, because the slope is taken by differencing
two job totals, which cancels every per-job term exactly. The gap is
per-position and it is the first-beat wait.

The practical consequence is small and worth stating so nobody re-opens a
closed question: **7.17 cycles is still not a reason to widen the port, deepen
the burst, or raise MAXOUT or RBUF**, all of which remain REJECTED above and
in that document. It is a reason not to write "zero".
