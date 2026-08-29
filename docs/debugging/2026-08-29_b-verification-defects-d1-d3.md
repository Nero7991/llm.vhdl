# Subsystem B: the three defects B-MUT measured in the checking and did not fix

Date: 2026-08-29.  Repo `llama.vhdl`, branch `fpga`.
Simulator: ghdl-mcode, VHDL-2008, `-frelaxed`.  No hardware involved.
Companion to, and closure of, three of the open items in
`docs/debugging/2026-08-28_b-mutation-coverage-seven-units.md` (commit `c50a2b7`).

## 1. The question

Verbatim, from the dispatch:

> **D1.** `sim/gdn_conv_vec.txt` is a STALE GOLDEN. ... `cmp` differs at byte 13.
> Four tracks run against that golden, so regenerating it is a change with blast
> radius: do it deliberately, prove the only differences are the intended ones,
> and confirm `tb_gdn_conv` still passes.
>
> **D2.** `tb_gdn_emit_chain` is gated at the one setting that masks its own
> defect. ... Fix by driving a non-zero `Z_DELAY`, and prove the new setting
> kills the mutation while the unmutated chain still passes.
>
> **D3.** `gdn_scalar`'s accuracy oracle is SATURATED on the unmutated unit
> (`eg worst 3.2768e4 LSB(Q15)`, the entire output range). ... either find a
> formulation whose worst case is meaningful, or state plainly that no accuracy
> gate is possible for this unit and why.  **Do not invent a threshold that
> merely passes.**

## 2. The answer

All three are fixed, and D3's answer is not the one the dispatch expected.

1. **D1.** `sim/gdn_conv_vec.txt` regenerated.  MEASURED: 19 of 641 lines move,
   every one a case header, every one at `c % 7 == 0`, and only the `cw_exp`,
   `e_seg` and `err` fields within them.  No `x`, `w`, `sm` or oracle line moves
   at all and the bench's worst-vs-oracle figure is unchanged at
   `4.99999999998181e-1`.  Cases 56 and 126 now carry `err = 1`.  Mutation R13
   (delete the int8 overflow test) went from **pass** to **FAIL** against the
   committed golden.
2. **D2.** `sim/regress.sh` now passes `-gZ_DELAY=640` to `tb_gdn_emit_chain`.
   MEASURED at the gate's own generics: the `z_have` mutation passes at
   `Z_DELAY` 0, 7, 40 and **520**, and fails at **540**, 560, 580, 600, 640 and
   1024, with the unmutated chain passing at 640 as the control.  So the
   threshold is in **(520, 540]**, not "~512" as the earlier writeup estimated.
3. **D3.** A max-based gate on `eg` over the whole 320-case set is impossible,
   and **the reason recorded on 2026-08-28 is incomplete in a way that matters.**
   "Two sentinel terms cancel" explains 14 of the 17 cases past 100 LSB.  The
   JOINT-WORST case, 70, has **no sentinel saturation at all**: its softplus
   negative tail is flushed to exactly 0 below `arg = -16` and an `|a|` of
   3.09e14 multiplies the difference back up, giving 32767.9963 LSB.  A third
   mechanism truncates `arg` from ~1e12 with the SAME signs (cases 69, 258).
   What they share is the real statement: **the `eg` error is `|a|` times the
   softplus error, and the case set sweeps `|a|` over 2^-40..2^40 on purpose,
   because that is what makes the RTL's guard branches reachable.  Accuracy and
   guard coverage cannot be gated from one number over one case set.**
   So the gate is stated on a DOMAIN, and the domain is a predicate on the
   **inputs**, never on the outputs.  `sim/tb_gdn_scalar.vhd` now gates, at
   severity error, so `sim/regress.sh` can fail it.

`gdn_scalar` is therefore the SECOND of subsystem B's seven units (after
`gdn_conv`) whose real-valued check is inside the bench and reachable from the
gate.  The other five are unchanged and are scoped in section 7.

## 3. The procedure, in the order it was run

1. **D1 first, because it is a golden and a golden blocks everything else.**
   Regenerate privately, diff by ROLE (header / x / w / sm / oracle) rather than
   by byte, then by FIELD.  Only then install it.
2. **Teeth before and after, with the same mutation.**  R13 against the
   committed golden and against a fresh one, in both directions.
3. **D2 by bisection with a control at every point.**  A mutation that dies at
   one setting proves nothing unless the unmutated design is shown to pass at
   that setting.  Every value below was run for both.
4. **Cost measured, not assumed.**  A gate row that triples in wall time is a
   different decision from one that costs 17%.
5. **D3 by instrumenting the generator, not by reading it.**  A per-case probe
   counting to_q_wide sentinel firings and their sign relationship, then the
   error distribution partitioned on that probe.  This is what refuted the
   sentinel-only diagnosis.
6. **The D3 domain predicate is DERIVED from the recipe's own guards, and its
   exclusion is checked for the emptying trap** -- both by reporting the
   excluded set's own error distribution and by asserting a floor on the
   in-domain count.
7. **Every new gate teeth-checked against a REAL mutant**, not by lowering the
   threshold, because ghdl-mcode cannot override a `real` generic anyway.

## 4. The evidence

### 4.1 D1 -- the regeneration, by role and by field

```
$ cmp fresh.txt sim/gdn_conv_vec.txt
fresh.txt sim/gdn_conv_vec.txt differ: byte 13, line 2

nlines old/new 641 641
hdr ndiff 19 cases [0, 7, 14, 21, 28, 35, 42, 49, 56, 63, 70, 77, 84, 91, 98, 105, 112, 119, 126]
```

There is no `x`, `w`, `sm` or `orc` row in that list: only the 19 case headers,
and 0, 7, 14 ... 126 is exactly `c % 7 == 0`, the case class `9cfdbd2` added.

```
fields that changed anywhere: ['cw_exp', 'e_seg', 'err']
err committed: Counter({'0': 128})  err fresh: Counter({'0': 126, '1': 2})
cases with err=1 fresh: [56, 126]
$ git diff --stat -- sim/gdn_conv_vec.txt
 sim/gdn_conv_vec.txt | 38 +++++++++++++++++++-------------------
 1 file changed, 19 insertions(+), 19 deletions(-)
```

### 4.2 D1 -- teeth, both directions, verbatim

BEFORE the regeneration:

```
--- clean RTL vs COMMITTED golden (current gate) ---
gdn_conv: bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE 4.99999999998181e-1 LSB
--- clean RTL vs FRESH golden ---
gdn_conv: bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE 4.99999999998181e-1 LSB
--- R13 mutant vs COMMITTED golden ---
gdn_conv: bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE 4.99999999998181e-1 LSB
--- R13 mutant vs FRESH golden ---
case 56: NOT BIT-EXACT in 1 field(s)  (e_seg got -26 want -154, sh got 16 want 16)
case 126: NOT BIT-EXACT in 1 field(s)  (e_seg got -8 want -136, sh got 15 want 15)
gdn_conv is NOT bit-exact in 2 case(s)
```

AFTER:

```
--- clean RTL vs COMMITTED golden ---
gdn_conv: bit-exact with the C recipe on all 128 cases; worst vs the double ORACLE 4.99999999998181e-1 LSB
--- R13 mutant vs COMMITTED golden ---
case 56: NOT BIT-EXACT in 1 field(s)  (e_seg got -26 want -154, sh got 16 want 16)
case 126: NOT BIT-EXACT in 1 field(s)  (e_seg got -8 want -136, sh got 15 want 15)
gdn_conv is NOT bit-exact in 2 case(s)
```

`sim/mutate_gdn_conv.sh` still reports **15 killed, 5 survived of 20**, and the
"THE TWO GOLDENS DISAGREE" banner -- which fired on R13 and on four other rows
before -- now fires on nothing.  The banner was also narrowed to RTL-class rows
only: on a C or BOTH row the CMTD column is the mutated RTL against the
UNMUTATED golden, so a disagreement there is guaranteed by construction and says
nothing about staleness.  **The two columns are kept as a standing staleness
check**, not deleted: any future RTL-class disagreement means the golden has
drifted from its generator again.

**Blast radius, MEASURED:** `grep -l gdn_conv_vec.txt sim/*.vhd tb/*.vhd`
returns exactly one file, `sim/tb_gdn_conv.vhd`.
`sim/tb_gdn_conv_tvalid_skew.vhd` builds its own stimulus and opens no vector
file, and `sim/tb_gdn_conv_cycles` is a NOCHECK measurement row.  "Four tracks"
means four tracks run `sim/regress.sh`, not four consumers of the file.

### 4.3 D2 -- the Z_DELAY bisection, with its control at every point

At the gate's exact generics (`OVERLAP=true COL_GAP=4 STRICT=false
SILU_LANES=16 RMS_LANES=4`), 3 blocks x 24 heads, the vector `3 24 128`:

| Z_DELAY | unmutated (control) | R6 (`z_have` dropped from S_IDLE) | first divergence | wall |
|---|---|---|---|---|
| 0 | PASS | **PASS** | -- | 52 s / 53 s |
| 520 | PASS | **PASS** | -- | 53 s |
| 540 | -- | FAIL | block 0 element 1280 head 10 | 53 s |
| 560 | -- | FAIL | block 0 element 1030 head 8 | 53 s |
| 580 | -- | FAIL | block 0 element 768 head 6 | 54 s |
| 600 | PASS | FAIL | block 0 element 640 head 5 | 58 s |
| **640** | **PASS** | **FAIL** | block 0 element 512 head 4 | **61 s** |
| 1024 | PASS | FAIL | block 0 element 0 head 0 | 86 s |

Verbatim, the two rows that matter:

```
  clean  Z_DELAY=640  PASS  61.05 s
    tb_gdn_emit_chain: PASS -- 3 blocks x 24 heads x 128 bit-exact,
    OVERLAP=true COL_GAP=4 refused-column cycles=7255 SILU_LANES=16 RMS_LANES=4
  r6     Z_DELAY=640  FAIL  53.41 s
    block 0 element 512 head 4 lane 0 got 0 expected 23
```

**640 is DERIVED, not picked.** The run is 44394.5 ns at TCLK = 1 ns over
3 x 24 = 72 heads, so the per-head period is 616 cycles; 640 exceeds it, which
is what makes z late for EVERY head.  512 (the column pass alone, DIM=128 at
COL_GAP=4) is not enough, and the earlier writeup's "~512" was an estimate that
the bisection above corrects to (520, 540].  540 kills but is not a safe gate
value: the lag accumulates per head, so at 540 the mutant survives ten heads
before diverging, while at 640 it diverges at head 4.

**One side effect, and it costs nothing that was being gated.** `refused-column
cycles` goes 0 -> 7255, because making z late is exactly what backs the column
path up.  MEASURED against the bench source: `stall_cyc` appears at lines 206,
411 and 418 of `sim/tb_gdn_emit_chain.vhd` and is `report`ed at all three; it is
never compared, and the refusal-is-a-failure property is `STRICT=true`, which
this row does not use and did not use before.

`sim/mutate_gdn_emit_chain.sh`'s `Z_DELAY` default moved 0 -> 640 to follow the
gate, so R6 now dies in its main table instead of only in the cross-check at the
bottom.  `Z_DELAY=0` in the environment reproduces the old blind configuration.
Its kill ratio went **9 killed / 8 survived** to **10 killed / 7 survived of 17**,
and the one row that moved is R6.  The script's own cross-check still runs, with
its control, and still reads:

```
  CONTROL  unmutated at Z_DELAY=600 : PASS   (must be PASS)
  R6       mutant    at Z_DELAY=600 : FAIL   (must be FAIL)
```

### 4.4 D3 -- the sentinel diagnosis is incomplete, MEASURED

A copy of `ref/gdn_scalar_vec.c` instrumented with a per-case counter on
`to_q_wide`'s two sentinel returns, plus the sign relationship of the two terms:

```
predicate                                n     max err        p50   n>1   n>100
ALL 320                                320  32768.0000     0.0573    87      17
no to_q_wide saturation at all         270  32767.9963     0.0697    68       1
not (saturated AND opposite signs)     297  32767.9963     0.0489    73       3
saturated AND opposite signs            23  32768.0000 16386.9963    14      14
```

The third row is the refutation: excluding every sentinel cancellation still
leaves a case at 32767.9963 LSB.  It is case 70, and its probe reads
`nsat=0 opp=0`.

```
case  70: al=(  5200, 51) dt=(-31160, 10) a=( -4496,-36)
          true al+dt = -30.4297      arg_q/2^18 = -30.4297   (sat 00)
          true a     = -3.08963e+14  eg=32768  oracle=0.003688  err=32767.9963
case  69: al=( 16156,-26) dt=( 28525, 60) a=(-30740, 52)
          true al+dt = 1.08421e+12   arg_q/2^18 = 1.34218e+08 (sat 10)
          true a     = -6.82565e-12  eg=32739  oracle=20.020624 err=32718.9794
case 260: al=( 32767,-19) dt=(-32768,-23) a=(-32768,-20)
          true al+dt = -2.57699e+11  arg_q/2^18 = 0           (sat 11)
          true a     = -3.43597e+10  eg=0      oracle=32768.000000 err=32768.0000
```

Three mechanisms, one shared statement.  Case 70: `arg` is EXACT, the recipe
flushes softplus to 0 below -16 where the truth is `exp(-30.43) = 6.06e-14`, and
`|a| = 3.09e14` turns that into `g = -18.7` against the recipe's `g = 0`.  Case
69: one sentinel with the SAME sign truncates `arg` from 1.08e12 to
`2^45/2^18 = 1.34e8`, and a tiny `|a|` lands the product inside the `[-16, 0]`
window on one side only.  Case 260: two sentinels with OPPOSITE signs cancel.

Error by band, which is what makes the domain argument rather than asserts it:

| band | n | max | p50 | n>1 | n>100 |
|---|---|---|---|---|---|
| physical (real Qwen3 ranges) | 64 | 10.8405 | 0.4563 | 23 | 0 |
| wide-exp (`[-40, 60]`, for the guards) | 64 | **32767.9963** | 0.0037 | 14 | 6 |
| softplus threshold | 64 | 15.2885 | 0.2185 | 21 | 0 |
| g-clamp | 64 | 0.0037 | 0.0037 | 0 | 0 |
| named corners (for the guards) | 16 | **32768.0000** | 32757.0045 | 11 | 11 |
| degenerate | 48 | 2.8069 | 0.5447 | 18 | 0 |

Every case past 100 LSB is in one of the two bands the generator's own comments
say exist to reach the guards.  The wide-exp band's comment is explicit: the
range was widened to `[-40, 60]` because the old one "left EVERY wide-shift
guard dead in test ... Four RTL-vs-reference divergences hid in that gap."

### 4.5 D3 -- the domain, and why it is not the `sat_any` trap

Both conditions are DERIVED from the recipe, not fitted:

- **(i) neither softplus input reaches `to_q_wide`'s sentinel.**  The bench's
  `sentinel(m, e)` mirrors that function's TWO guards, and both matter: the
  `s > 40` cutoff fires on magnitude-innocent inputs.  Case 258 is `m = 1,
  e = -25`, whose true value `2^25` is far below the `2^27` the sentinel
  corresponds to, and it is slammed to the sentinel anyway.  A predicate written
  only on `|value|` keeps that case and carries an 11454 LSB error into the gate.
- **(ii) `|a| <= 256`.**  Below the clamp the recipe returns exactly 0 where the
  truth is `exp(arg) <= exp(-16) = 1.1254e-7`, so the `eg` error from the flush
  is at most `32768 * |a| * 1.1254e-7`; 256 is the largest power of two keeping
  that under one output LSB (0.944).

MEASURED with that predicate over the committed 320:

```
in-domain 259 cases   max 15.3271 LSB(Q15)   p50 0.0832   p90 3.9516   n>1 67   n>100 0
excluded   61 cases   max 32768.0000         p50 0.0037                 min 0.0000
in-domain by band: physical 64, softplus-thr 64, g-clamp 64, degenerate 48,
                   wide-exp 17, named 2
excluded  by band: wide-exp 47, named 14
```

The excluded set's OWN median is 0.0037 LSB and its minimum is 0.0000, so the
exclusion is plainly not error-driven -- which is the distinction from
`gdn_y_emit`'s `sat_any` exclusion, where excluding on an OUTPUT property
removed 41 of 48 cases and left the oracle reporting 0.0000 on nothing but the
all-zero cases.  Every case of the physical band, the band drawn from the real
Qwen3 weight ranges, is retained.

The VHDL predicate and an independent Python one agree exactly: the bench
reports `IN DOMAIN (259 of 320 cases): eg worst 1.5327066999998351e1`.

### 4.6 D3 -- the gates, and their teeth against real mutants

Four asserts, all at severity error so `sim/regress.sh`'s `FAIL_RE` catches
them, all set at 1.5x the measured figure (the convention `tb_gdn_conv`'s
`TOL = 0.75` against a measured 0.4999999 already uses):

| gate | measured baseline | value | killed by |
|---|---|---|---|
| in-domain `eg` max | 15.3271 LSB(Q15) | 23.0 | B1, B2, B3, R4, R6, R8 |
| in-domain cases past 1 LSB | 67 of 259 | 100 | **B5**, which the max cannot see |
| `beta` max, all 320 | 3.0880 LSB(Q16) | 4.65 | R3 |
| in-domain count floor | 259 of 320 | 250 | `-gMIN_IN_DOMAIN=300` |

The count gate exists because of a measurement, not a hunch.  B5 moves g's lower
clamp from -16 to -8 in BOTH the C and the RTL; below -8 the true `eg` is already
under 11 LSB, so the change cannot reach the worst case:

```
mutant      n_in     median          max    n>1
BASELINE     259     0.0832      15.3271     67
B5           259     2.2214      15.3271    151
B4           259     0.0779      15.2885     61
```

The count is gated rather than the median because it needs no sort in VHDL.

Verbatim, the gates firing:

```
B5: (assertion error): gdn_scalar: eg is OUT OF TOLERANCE vs the ORACLE in
    domain -- 151 of 259 in-domain cases are past one output LSB, gate is 100.
    The worst case did not move; the bulk of the distribution did.
B1: (assertion error): gdn_scalar: eg is OUT OF TOLERANCE vs the ORACLE in
    domain -- 1.904638484e4 LSB(Q15) against a gate of 2.3e1 over 259 cases
B3: (assertion error): ... 3.5269188700000086e2 LSB(Q15) against a gate of 2.3e1
R3: (assertion error): gdn_scalar: beta is OUT OF TOLERANCE vs the ORACLE --
    3.2768e4 LSB(Q16) against a gate of 4.65 over all 320 cases
    -gMIN_IN_DOMAIN=300: (assertion error): gdn_scalar: the accuracy DOMAIN
    COLLAPSED -- only 259 of 320 cases are in domain, floor is 300.
```

And not firing, on the correct unit:

```
vs double oracle: eg worst 3.2768e4 LSB(Q15), beta worst 3.088008999999147 LSB(Q16)
vs double oracle IN DOMAIN (259 of 320 cases): eg worst 1.5327066999998351e1
  LSB(Q15), gate 2.3e1; eg past 1 LSB 67, gate 100
PASS
```

The whole-set `eg worst 3.2768e4` line is DELIBERATELY still printed.  It is the
honest figure for the whole case set and removing it would hide the finding this
document exists to record.

`sim/mutate_gdn_scalar.sh`'s table gained a `bench` column, which is the only
one of its three verdicts that `sim/regress.sh` can fail.  BOTH class, before
and after:

| mutation | bench BEFORE | bench AFTER |
|---|---|---|
| B1 sentinel 2^45 -> 2^30 | (no gate existed) | **FAIL** 19046.3848 |
| B2 softplus positive tail clamped | (no gate existed) | **FAIL** 26491.3848 |
| B3 softplus negative tail at -4 | (no gate existed) | **FAIL** 352.6919 |
| B4 eg output round bias dropped | (no gate existed) | pass, deliberately |
| B5 g's lower clamp -16 -> -8 | (no gate existed) | **FAIL** 151 of 259 past 1 LSB |

### 4.7 The gate, before and after

MEASURED, full unfiltered run, both suites, on this box:

```
 suite sim   PASS 55   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 81   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 81 passing, matches the recorded floor of 81
 REGRESSION: PASS
```

`BASELINE_PASS` is unchanged at 81: no test was added or removed.  Three rows
changed what they check without changing whether they pass -- `tb_gdn_conv`
(new golden), `tb_gdn_emit_chain` (`-gZ_DELAY=640`, 52 s -> 61 s) and
`tb_gdn_scalar` (four new asserts).

## 5. Measured and did NOT bite -- do not retry

- **`gdn_scalar` B4, the eg output round bias dropped in BOTH, is still a
  survivor and the gate was NOT widened to catch it.**  MEASURED: it moves the
  in-domain worst 15.3271 -> 15.2885 and the in-domain count past 1 LSB
  67 -> 61, i.e. BOTH move the safe way.  A gate that caught it would have to be
  two-sided, and a two-sided accuracy gate fails on any improvement.  This is
  the same call as S1 in the B-ACCURACY writeup and the same call the
  2026-08-28 mutation report made.
- **A `|a|` bound alone does not define the domain.**  MEASURED, sweeping only
  `|a|`: at every threshold from 0.05 to 2^40 the max stays at 32767.9963,
  because cases 105 and 268-271 have `|a|` of 1e-13 to 1e-6 and an `arg` of 1e12
  to 1e14.  The sentinel condition is the one that does the work; `|a| <= 256`
  removes exactly case 70's class.
- **A bound on `|al|` and `|dt|` in real units alone does not define it either.**
  MEASURED: `|al|, |dt| <= 2^27` (the magnitude the 2^45 sentinel corresponds to)
  leaves case 258 in, at 11454.6735 LSB, because `to_q_wide`'s OTHER guard --
  the `s > 40` shift cutoff -- fires on `m = 1, e = -25` whose value is only
  `2^25`.  Both guards have to be mirrored.
- **`Z_DELAY = 540` kills R6 and is still the wrong gate value.**  It kills at
  head 10 of 24; the lag is accumulating, so the margin is one head's worth of
  slack, not 3.8%.
- **ghdl-mcode cannot override a `real` generic.**  `-gEG_TOL=10.0` dies with
  `unhandled type for generic override of 'eg_tol'` and `error during
  elaboration`, so no simulation runs at all.  A `real` tolerance in any of these
  benches cannot be swept from `sim/regress.sh` or teeth-checked by lowering it.
  `MIN_IN_DOMAIN` is an integer specifically so that one CAN be.

## 6. Measurement traps hit

- **`cmp` says "differ at byte 13" and stops.**  That is a fact about byte 13,
  not about the file.  Diffing by ROLE first (header / x / w / sm / oracle) and
  only then by FIELD is what turns "the golden is stale" into "19 header lines,
  three fields, at `c % 7 == 0`".  A byte offset would not have supported
  installing it.
- **The generator's RNG stream is position-stable under the `9cfdbd2` change**,
  because `rnd_range` consumes exactly one `rnd64()` regardless of its range.
  That is WHY only the derived fields moved.  Had it not been, the whole file
  would have changed and the regeneration would have needed a different argument.
- **A dual-column staleness report over-claims once the staleness is fixed.**
  `sim/mutate_gdn_conv.sh` printed "THE TWO GOLDENS DISAGREE" on C-class and
  BOTH-class rows where the disagreement is structural, not staleness.  Narrowed
  to RTL-class rows.
- **A mutation that dies at a raised generic still needs its control at that
  generic**, and the control has to be the FULL gate configuration, not the
  mutation script's cheaper one.  `sim/mutate_gdn_emit_chain.sh` defaults to
  NB=2; the gate row runs 3 blocks, and the per-head period that justifies 640
  was measured on the 3-block run.
- **Instrument, do not reason, about which mechanism fired.**  The sentinel-only
  diagnosis is a completely plausible reading of cases 260-262 and it is wrong
  about the worst case in the file.  A four-line probe settled it.
- **A max is blind to a distribution shift.**  B5 leaves the in-domain max
  identical to fifteen significant figures.  Any accuracy gate that is a single
  max has this hole; the count past 1 LSB is the cheapest second statistic.

## 7. Scoped, NOT done here: the general problem

`sim/regress.sh` cannot fail an accuracy check for five of B's seven units.
This track closed one of them (`gdn_scalar`) because D3 required it; the general
fix was deliberately not attempted.  Recording what it would be, for whoever
takes it.

**The shape of the problem, restated from the 2026-08-28 measurement.**
`gdn_silu` and `rmsnorm_bf` PRINT their double-oracle figures from the
GENERATOR and gate nowhere.  `gdn_head_emit`, `gdn_y_emit` and
`gdn_emit_chain` DO gate, in the generator's exit code -- and `sim/regress.sh`
never runs those generators, because their vectors are committed and it
regenerates a vector only when the file is absent.  So the gate consults none of
them.  The flagship consequence is that the `rmsnorm_bf` mutation which
reintroduces exactly the defect that unit exists to fix is bit-exact-green and
1.7e10 output LSB wrong.

**Two routes, and they are not equivalent.**

- **Route A: make the generator's exit code reachable from the gate.**  Add a
  `tb_vector_args` row for each committed vector so `sim/regress.sh` regenerates
  it unconditionally, the way `l2norm_rs_vec.txt` already does ("Pinned here
  rather than left to the generator's defaults so that committing
  `sim/l2norm_rs_vec.txt` later cannot silently freeze a stale golden: with a
  row present regress.sh regenerates unconditionally").  Cheap -- one table row
  per unit -- and it fixes the D1 staleness class for good as a side effect.
  **But it moves the accuracy claim OUT of the bench and into the C**, so it
  cannot see an RTL-only accuracy defect at all, and it makes every gate run pay
  the generator's cost.  It is a golden-freshness fix that happens to enable an
  accuracy gate, not an accuracy fix.
- **Route B: move the gate into the bench**, which is what was done for
  `gdn_scalar` here.  The vector file already carries the oracle columns for all
  five, so no generator change is needed and the check is against the DUT's own
  outputs rather than against the C's.  This is the stronger route and it is the
  one the two units that already do it (`gdn_conv`, and now `gdn_scalar`) use.

**What Route B costs, per unit, MEASURED on `gdn_scalar`:** one predicate
function, four asserts, three tolerance generics, and a measurement pass to set
them -- about 60 lines of bench and half a day, most of it the measurement.

**What Route B runs into, and it is NOT uniform across the five.**  Two of them
have oracle blind spots that a tolerance cannot fix and that must be answered
first:

- `gdn_head_emit` and `gdn_y_emit` exclude a whole case from the oracle when any
  element saturated, which is an exclusion on an OUTPUT property.  MEASURED:
  at a 15-bit rail, 41 of 48 y_emit cases would saturate and 7 are all-zero, so
  41 + 7 = 48 and the oracle is EMPTIED rather than made insensitive.  A bench
  gate on that figure would report 0.0000 and pass.  The in-domain-count FLOOR
  added to `tb_gdn_scalar` here is the mechanism that makes an emptied oracle
  loud, and it is the piece to port first.
- `gdn_emit_chain`'s oracle measures error "in LSB of the OUTPUT grid" and one
  BOTH mutation changes that grid, so the figure moved 1.1280 -> **0.8505**, in
  the wrong direction.  A metric normalised by the quantity being mutated cannot
  see the mutation.  That one needs an absolute-unit error or a separate
  assertion on `y_exp` against the oracle's own exponent, which is a change to
  what is measured and not just to where it is asserted.

`gdn_silu` and `rmsnorm_bf` have neither problem and are the two to do first.

## 8. Open, not yet answered

- Whether `gdn_scalar`'s excluded 61 cases are physically reachable from the
  real Qwen3.5-9B / 27B weights.  Still argued nowhere and measured nowhere.
  The gate deliberately does not claim they are unreachable; it claims only that
  they are the cases the recipe cannot represent, and it names them.
- Whether `gdn_scalar` SHOULD flag the sentinel the way it flags the g clamp
  with `err_g`.  That is an RTL change and this track did not touch `rtl/`.  It
  would convert every excluded case from "silently wrong" to "reported", which
  is a better answer than a domain predicate, and it would make the domain
  predicate redundant.
- Whether the `refused-column cycles = 7255` that `Z_DELAY = 640` introduces
  should be bounded.  It is not a regression -- nothing asserted it before -- but
  it is a number nobody has a model for.
- The five remaining units of section 7.  Not started.
- `gdn_recur` and `gdn_exp_capture` still have no mutation harness, and
  `gdn_conv` defect B-3b (`cw_exp` read live) still has no bench anywhere.
  Unchanged by this track.
