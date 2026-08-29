# Subsystem B's three emit units: an accuracy gate the regression can fail,
# and the defect class no accuracy gate can see

Date: 2026-08-29.  Repo `llama.vhdl`, branch `fpga`.
Simulator: ghdl-mcode, VHDL-2008, `-frelaxed`.  No hardware ran.  No Vivado ran.
Follows `docs/debugging/2026-08-29_b-accuracy-gates.md` (commit `728fcfe`), which
did `gdn_silu` and `rmsnorm_bf` and left these three scoped in its section 9.

## 1. The question

Verbatim, from the dispatch:

> **Five subsystem B units have no accuracy gate that `sim/regress.sh` can
> fail.**
>
> - `gdn_silu` and `rmsnorm_bf` PRINT their oracle figures from the generator;
>   nothing consults them.
> - `gdn_head_emit`, `gdn_y_emit` and `gdn_emit_chain` assert inside a
>   generator the gate never runs, because their vectors are committed.
>
> The flagship case, and the reason this matters: **a `rmsnorm_bf` mutation
> that reintroduces exactly the defect that unit exists to fix is bit-exact
> green and 1.7e10 output LSB wrong.** ...
>
> Two routes are already scoped in section 7 of
> `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md`.  **They are NOT
> equivalent and the choice matters** ... **Route A** ... **Route B** ...
> Choose per unit if that is the right answer, and justify each choice with
> what defect class it can and cannot see.
>
> **DO `gdn_silu` AND `rmsnorm_bf` FIRST** ... The other three have oracle
> blind spots that must be answered before any tolerance means anything:
> - `gdn_head_emit` / `gdn_y_emit` exclude on an OUTPUT property and EMPTY
>   their oracle at a narrowed rail (41 saturating + 7 all-zero = 48 of 48).
> - `gdn_emit_chain`'s metric is normalised by the very quantity that one BOTH
>   mutation changes, so it moved the WRONG WAY (1.1280 -> 0.8505).

## 2. The answer

**Route B for all three, and a fifth check that is not a tolerance at all.**

1. **The dispatch's count of five is TWO out of date.**  `gdn_silu` and
   `rmsnorm_bf` were done this morning at commit `728fcfe` (08:19), with the
   flagship `rmsnorm_bf` case closed and its write-up already at
   `docs/debugging/2026-08-29_b-accuracy-gates.md`.  The live number was
   **three**, and this track did those three.  Details in section 3.

2. **The right fix for the `sat_any` blind spot is to DELETE the exclusion, not
   to narrow it.**  Excluding only the SATURATED ELEMENTS, which is the obvious
   repair, is measurably just as blind: under the rail-narrowing mutation the
   element-excluded max is `0.750000` and the element-excluded count past
   0.5 LSB is `3492`, **both exactly the honest unit's figures, to every
   digit**.  Nothing needs excluding: on the honest unit saturation can only
   follow the requantize rounding `2^15 - 1/2` up to `2^15`, so its error obeys
   the same derived bound as every other element.  MEASURED, `gdn_head_emit`,
   honest: the worst goes `0.5000` case-excluded to `0.999985` with nothing
   excluded, and stays at `0.999985` at all 40 seeds swept.

3. **The `gdn_emit_chain` finding generalises to all three units and NO
   accuracy gate can close it, including the one added here.**  A grid
   coarsening -- site 12 or site 13 keeping 13 mantissa bits instead of 14 --
   doubles the absolute error and doubles the LSB it is divided by, so every
   LSB-normalised figure moves the SAFE way:

   | figure, `gdn_y_emit` | honest | msb-13 |
   |---|---|---|
   | worst, output LSB | 0.750000 | **0.500000** |
   | elements past 0.5 LSB, of 147456 | 3492 | **0** |
   | mean, output LSB | 0.155923 | 0.158819 |

   The answer is a claim on the **normalisation** rather than on the error:
   `sh > 0` implies `amax >= 2^(sh+14)`, hence `max|y| >= 2^14`.  DERIVED from
   the recipe's own shift, checked against the DUT's own outputs and its own
   exponent, and it fires on 41 of 48 cases of that mutant while the bit-exact
   comparison stays green.

4. **All three gates are demonstrated going red, each with a control.**
   `sim/regress.sh --only tb_gdn_head_emit` prints `REGRESSION: FAIL` on the
   rail-15 mutant while the SAME tree with the bench restored from `HEAD`
   prints `PASS`.  Raw output in section 5.

5. **`sim/regress.sh` is NOT touched and `BASELINE_PASS` is unchanged.**  All
   three units were already gate rows; the work is entirely inside the three
   benches and their three mutation harnesses.

## 3. Corrections to the brief

Every number in the dispatch came from a document rather than a measurement.
Four are wrong or stale.

**C1. "Five units", and "`gdn_silu` and `rmsnorm_bf` PRINT their oracle
figures; nothing consults them" -- FIXED THIS MORNING, before this track
started.**  MEASURED, `git log`:

```
728fcfe 08-29 08:19  gdn_silu, rmsnorm_bf: the accuracy oracle was printed, not gated,
                     and the rmsnorm_rs defect walked straight back in
81297ee 08-29 10:03  subsystem B: seven accuracy thresholds fire on the honest unit
```

`sim/tb_gdn_silu.vhd` has carried four accuracy asserts at severity error since
08:19, and `docs/debugging/2026-08-29_b-accuracy-gates.md` -- the exact filename
this track was asked to deliver -- has existed since 08:15.  The flagship
`rmsnorm_bf` B1 case is closed there, with its control.  This track therefore
wrote to `docs/debugging/2026-08-29_b-emit-accuracy-gates.md` instead, and did
the three units that were actually open.

**C2. "41 saturating + 7 all-zero = 48 of 48" is right for `gdn_y_emit` and is
NOT the honest unit.**  It is the figure under mutation B4 (rail 16 -> 15 bits
in both transcriptions).  MEASURED on the committed vectors, the honest unit has
`sat_any = 1` in **0 of 48** `gdn_y_emit` cases and **8 of 64** `gdn_head_emit`
cases.  The exclusion costs nothing today; it is a landmine, not a live wound.
The distinction matters because it is why the fix is free.

**C3. "`gdn_emit_chain`'s metric ... moved 1.1280 -> 0.8505" reproduces, but
1.1280 is not this generator's honest figure at any argument this track ran.**
MEASURED at `NB = 3`: honest **1.2057**, mutated **0.8505**.  At the committed
`NB = 6`: honest **1.5300** (the figure in the generator's own comment).  The
0.8505 is exact; the 1.1280 it is quoted against is from neither shape.  The
direction of the finding is unaffected and is confirmed.

**C4. The blind spot the dispatch attributes to `gdn_emit_chain` alone is
present in ALL THREE units**, and in `gdn_head_emit` and `gdn_y_emit` it
survives the fix the dispatch prescribes.  Porting the FLOOR mechanism (section
9.4 of the companion document) makes an EMPTIED oracle loud; it does nothing at
all about a grid that is uniformly one octave too coarse, because that oracle is
not emptied -- it is full, and reads better than the truth.  See section 6.

## 4. The procedure, in the order it was run

1. **Read the two commits that landed this morning before writing any code**,
   because a dispatch that names five units and a document that already exists
   are the two cheapest ways to redo finished work.
2. **Build both generators and prove they reproduce the committed vectors byte
   for byte** before treating any generator figure as a baseline.
3. **Write an INDEPENDENT oracle in Python over the committed vector files**,
   in exact rational arithmetic, sharing nothing with `ref/*.c` or the RTL, and
   report it three ways -- case-excluded (the generator's rule), element-excluded
   (the obvious repair), and nothing excluded.  This is what refuted the obvious
   repair, in one table, before a line of VHDL was written.
4. **Re-implement it a second time in integers** and check the two agree.  Then
   check the VHDL against both.  Three implementations, two languages.
5. **Calibrate on FORTY generator seeds, not on the committed one.**  The
   companion document's `rmsnorm_bf` finding -- honest worst moving 0.770 ->
   9.999 over nine seeds, with the committed seed the benign extreme -- is the
   reason.
6. **Teeth-check against REAL mutants from the committed harnesses**, never by
   lowering a threshold, and run the UNMUTATED design through the same path as
   the control at every point.
7. **Only then look for what the tolerance still cannot see**, by taking the
   one mutation the companion document recorded as an expected survivor of both
   oracles and asking what property it does move.

## 5. The evidence

### 5.1 The three-way oracle table, which decided the design

Independent Python oracle, exact `Fraction` arithmetic, over the committed
`sim/gdn_head_emit_vec.txt` and `sim/gdn_y_emit_vec.txt` and over the vectors of
the two BOTH-class mutants.  `A` = the generator's rule (skip the whole case if
any element saturated), `B` = skip only the saturated elements, `C` = skip
nothing.

```
head: 64 cases x 128, cases with sat_any=1: 8, rail [-32768,32767]
  A case-excl  n=   7168  max=0.500000  mean=0.060427  n>0.5=     0  n>1=     0
  B elem-excl  n=   8165  max=0.500000  mean=0.057904  n>0.5=     0  n>1=     0
  C no-excl    n=   8192  max=0.999985  mean=0.059422  n>0.5=    14  n>1=     0

--- head_emit B4 (rail 16 -> 15 bits, in BOTH) ---
head: 64 cases x 128, cases with sat_any=1: 49, rail [-16384,16383]
  A case-excl  n=   1920  max=0.000000  mean=0.000000  n>0.5=     0  n>1=     0
  B elem-excl  n=   6292  max=0.500000  mean=0.057575  n>0.5=     0  n>1=     0
  C no-excl    n=   8192  max=16384.999985  mean=449.897655  n>0.5=  1148  n>1=  1127

y: 48 cases x 3072, cases with sat_any=1: 0, rail [-32768,32767]
  A case-excl  n= 147456  max=0.750000  mean=0.155923  n>0.5=  3492  n>1=     0
  B elem-excl  n= 147456  max=0.750000  mean=0.155923  n>0.5=  3492  n>1=     0
  C no-excl    n= 147456  max=0.750000  mean=0.155923  n>0.5=  3492  n>1=     0

--- y_emit B4 (rail 16 -> 15 bits, in BOTH) ---
y: 48 cases x 3072, cases with sat_any=1: 41, rail [-16384,16383]
  A case-excl  n=  21504  max=0.000000  mean=0.000000  n>0.5=     0  n>1=     0
  B elem-excl  n= 112582  max=0.750000  mean=0.199326  n>0.5=  3492  n>1=     0
  C no-excl    n= 147456  max=15854.126068  mean=92.939430  n>0.5= 31428  n>1=  2522
```

Read row `B` of the `y_emit` mutant against row `A`/`B`/`C` of the honest one:
**`max` and `n>0.5` are IDENTICAL to the honest unit**, 0.750000 and 3492.  The
obvious repair -- exclude the saturated elements rather than the saturated
cases -- moves only the mean and the population size.  That is why the exclusion
was deleted rather than narrowed.

### 5.2 The honest envelope over 40 generator seeds

`ref/gdn_head_emit_vec` at seeds `100003*i + 7`, `ref/gdn_y_emit_vec` at
`100003*i + 11`, `i = 1..40`, oracle `C` (nothing excluded):

```
--- head_emit: 40 seeds ---
  max      min     0.999985  max     0.999985
  mean     min     0.058687  max     0.103475
  n>0.25   min   816.000000  max  1524.000000
  n>0.5    min     3.000000  max    24.000000
  n>1      min     0.000000  max     0.000000
--- y_emit: 40 seeds ---
  max      min     0.750000  max     0.750000
  mean     min     0.113755  max     0.204489
  n>0.25   min 31808.000000  max 54387.000000
  n>0.5    min   930.000000  max  5648.000000
  n>1      min     0.000000  max     0.000000
```

**The maxima do not move at all and the counts move by 6.1x.**  That is the
opposite of `rmsnorm_bf`, where the maximum was the heavy-tailed figure.  The
reason is that these two maxima are bounded by a DERIVED quantity -- the
alignment floor loses under `2^-sh` output LSB and the requantize round under
0.5, so the total is under `2^-sh + 0.5*[sh>0] <= 1.0` -- while the counts are
ordinary sample statistics.  A max threshold here is safe because the bound is
derived, not because 40 seeds agreed.

### 5.3 The thresholds, and what each one can and cannot separate

| unit | figure | honest, 40 seeds | gate | killed by |
|---|---|---|---|---|
| `gdn_head_emit` | max, output LSB | 0.999985 (all 40) | 1.500 | B1, B2, B4 |
| | elements past 0.5 LSB, of 8192 | 3 .. 24 | 120 | B1, B2, B3, B4 |
| | mean, output LSB | 0.058687 .. 0.103475 | 0.200 | B1, B2, B3, B4 |
| | floor on elements measured | 8192 | 8192 | (structural) |
| | **max\|o_mant\| when sh_h > 0** | **16384 (all 40)** | **16384** | **B5** |
| `gdn_y_emit` | max, output LSB | 0.750000 (all 40) | 1.500 | B1, B2, B4 |
| | elements past 0.5 LSB, of 147456 | 930 .. 5648 | 12000 | B1, B2, B3, B4 |
| | mean, output LSB | 0.113755 .. 0.204489 | 0.350 | B1, B2, B4 |
| | floor on elements measured | 147456 | 147456 | (structural) |
| | **max\|y\| when sh > 0** | **16384 (all 40)** | **16384** | **B4, B5** |
| `gdn_emit_chain` | **max\|y\| per block** | **18383 (120 blocks)** | **16384** | **B4** |

**Two thresholds have NO resolution and are documented as such rather than
tightened.**

- `gdn_head_emit`'s max cannot see B3.  MEASURED: honest `0.999985` against a
  mutated `1.000000`, a separation of **1.5e-5**.  Widening to catch it would
  put the gate under the honest figure.  The count separates the same mutation
  by 130x, 24 against 3127.
- `gdn_y_emit`'s mean cannot see B3.  MEASURED: honest worst over 40 seeds
  `0.204489` against a mutated `0.271581`.  A gate at 0.25 would be 1.22x above
  an observed honest seed, which is the calibration mistake `81297ee` spent a
  day undoing on four other harnesses.  It is left at 0.350 and the count does
  the work, 5648 against 28037.

### 5.4 The gates going red, with a control at every point

`gdn_head_emit`, mutation B4, unmutated design as the control through the same
path:

```
--- the mutant, with the bench as it stands now ---
(report note): gdn_head_emit accuracy vs the real-valued oracle, NOTHING excluded:
    worst 1.638499998474121e4 LSB at case 3 col 24; 1148 of 8192 elements past
    5.0e-1 LSB; mean 4.498976549590302e2 LSB
(report error): gdn_head_emit: OUT OF TOLERANCE -- worst accuracy error
    1.638499998474121e4 LSB exceeds 1.5 LSB (case 3 col 24)
(report error): gdn_head_emit: OUT OF TOLERANCE -- mean accuracy error
    4.498976549590302e2 LSB exceeds 2.0e-1 LSB
(report error): gdn_head_emit: OUT OF TOLERANCE -- 1148 elements past 5.0e-1 LSB,
    cap is 120

--- THE CONTROL: the SAME mutant, with sim/tb_gdn_head_emit.vhd from HEAD ---
tb_head.old.vhd:224: overlap phase: 4 heads back-to-back took 1202 cycles
tb_head.old.vhd:258: overlap phase: back-pressure asserted at least once: true
tb_head.old.vhd:262: tb_gdn_head_emit: PASS -- 64 cases x 128 bit-exact, plus 4
    heads back-to-back with no gap
```

The old bench passes the mutant and the new one fails it, on the same vectors
and the same mutated RTL.  **The failure is the new check and not the stimulus.**

`gdn_y_emit`, the grid-coarsening mutation (`msb_pos(amax) - 13` in the RTL and
the C together), which is the one both existing oracles were measured blind to:

```
(report error): case 0: NORMALISATION -- the requantize shifted by 16 yet the
    largest |y| is only 16042, under the floor of 16384. ...
(report error): case 3: NORMALISATION -- the requantize shifted by 17 yet the
    largest |y| is only 8192, under the floor of 16384. ...
(report note): overlap phase: 2 blocks back-to-back took 15390 cycles
(report note): gdn_y_emit accuracy vs the real-valued oracle, NOTHING excluded:
    worst 5.0e-1 LSB at case 4 elem 258; 0 of 147456 elements past 5.0e-1 LSB;
    mean 1.588187240777391e-1 LSB
(report error): gdn_y_emit: NORMALISATION failed on 41 of 48 cases
(report failure): tb_gdn_y_emit: FAIL -- 41 mismatches
```

Note what the accuracy oracle says on that same run: worst **0.5**, better than
the honest 0.75, and **zero** elements past 0.5 LSB against the honest 3492.
Every bit-exact claim is green, because both transcriptions were mutated
together.  The NORMALISATION check is the only thing in the file that fires, and
it fires on 41 of 48 cases.

### 5.5 The three implementations agree

The bench's own report, and the two independent Python oracles, on the committed
vectors:

```
VHDL   gdn_head_emit ... worst 9.999847412109375e-1 LSB at case 3 col 24;
                         14 of 8192 elements past 5.0e-1 LSB;
                         mean 5.9421903483711715e-2 LSB
py-int cross-he n=8192   max=0.999985 mean=0.059422 n>0.25=867 n>0.5=14 n>1=0
py-frac head             max=0.999985 mean=0.059422              n>0.5=14 n>1=0

VHDL   gdn_y_emit    ... worst 7.5e-1 LSB at case 4 elem 0;
                         3492 of 147456 elements past 5.0e-1 LSB;
                         mean 1.5592341918505562e-1 LSB
py-int cross-ye n=147456 max=0.750000 mean=0.155923 n>0.25=42012 n>0.5=3492
py-frac y                max=0.750000 mean=0.155923               n>0.5=3492
```

Agreement to every digit printed, across VHDL `real`, Python `float` over exact
integer numerators, and Python `Fraction`.

### 5.6 The mutation tables, before and after

`sim/mutate_gdn_head_emit.sh`, after (B5 is new in this track):

```
R1   SURVIVED bench PASS                        oracle pass 0.5000 LSB -- pass B ALIGNS BY ROUNDING instead of flooring (amax diverges)
R2   KILLED   bench FAIL [o_mant]               oracle pass 0.5000 LSB -- pass C aligns by ROUNDING, so the alignment is double-rounded
R3   KILLED   bench FAIL [o_sat]                oracle pass 0.5000 LSB -- sh_h keeps 15 mantissa bits, not 14
R4   KILLED   bench FAIL [o_sat]                oracle pass 0.5000 LSB -- e_h is the MAXIMUM of the column exponents, not the minimum
R5   KILLED   bench FAIL [o_sat]                oracle pass 0.5000 LSB -- the requantize round bias is dropped (truncate)
R6   KILLED   bench FAIL [e_head]               oracle pass 0.5000 LSB -- e_head is e_h PLUS sh_h, not minus (a power-of-two scale error)
R7   KILLED   bench FAIL [o_mant]               oracle pass 0.5000 LSB -- sat16's positive rail is 32766
R8   KILLED   bench FAIL [o_sat]                oracle pass 0.5000 LSB -- o_sat is never raised (the flag is tied low)
R9   KILLED   bench FAIL [o_sat]                oracle pass 0.5000 LSB -- o_sat is raised on every head (the flag is tied high)
R10  KILLED   bench FAIL [o_sat]                oracle pass 0.5000 LSB -- the absolute value is one's complement, not two's
R11  KILLED   bench FAIL [throughput]           oracle pass 0.5000 LSB -- the double buffer is collapsed: one bank at a time, consistently
R12  KILLED   bench FAIL [no verdict]           oracle pass 0.5000 LSB -- in_ready is tied high, so columns are dropped by a full bank
R13  KILLED   bench FAIL [no verdict]           oracle pass 0.5000 LSB -- an explicit done_r clear inside the o_ack branch
C1   KILLED   bench FAIL [o_mant]               oracle pass 0.5000 LSB -- sat16's positive rail is 32766 in the C model
C2   KILLED   bench FAIL [o_sat]                oracle pass 0.5000 LSB -- msb_pos_u returns one too many, so sh_h is one too large
C3   KILLED   bench FAIL [o_sat]                oracle pass 1.0000 LSB -- the model's o_sat is never set
B1   KILLED   bench FAIL [accuracy: worst]      oracle FAIL 32164.0993 LSB -- every column is aligned one bit too far (shj + 1)
B2   KILLED   bench FAIL [accuracy: worst]      oracle FAIL 1810530134129041.0000 LSB -- e_h is column 0's exponent, not the minimum
B3   KILLED   bench FAIL [accuracy: mean]       oracle FAIL 1.0000 LSB -- the requantize truncates instead of rounding, in BOTH
B4   KILLED   bench FAIL [accuracy: worst]      oracle pass 0.0000 LSB -- the output rail drops from 16 bits to 15, in BOTH
B5   KILLED   bench FAIL [normalisation]        oracle pass 0.5000 LSB -- site 12 keeps one bit less headroom (msb-13), in BOTH
kill ratio: 20 killed, 1 survived, of 21
```

**B4 moved from SURVIVED to KILLED and B5 is new and killed**, so the harness
goes from 18 killed / 2 survived of 20 to 20 killed / 1 survived of 21.  Read
the `oracle` column on the B4 and B5 rows: `pass 0.0000` and `pass 0.5000`.  The
generator's own check is still blind to both, exactly as before; the bench is
what changed.

R1 remains the only survivor and is the documented equivalent-at-this-interface
case: rounding the pass-B alignment changes `amax` in 2 of 64 cases and
`msb_pos(amax)` in none, and `amax` is not a port.

`sim/mutate_gdn_y_emit.sh`, after (B5 is new in this track):

```
R1   SURVIVED bench PASS                        oracle pass 0.7500 LSB -- pass B ALIGNS BY ROUNDING instead of flooring (amax only)
R2   KILLED   bench FAIL [y value]              oracle pass 0.7500 LSB -- pass C aligns by ROUNDING, so the alignment is double-rounded
R3   KILLED   bench FAIL [o_sat]                oracle pass 0.7500 LSB -- sh keeps 15 mantissa bits, not 14
R4   KILLED   bench FAIL [y_exp]                oracle pass 0.7500 LSB -- e_y_raw is the MAXIMUM of the head exponents, not the minimum
R5   KILLED   bench FAIL [y value]              oracle pass 0.7500 LSB -- the requantize round bias is dropped (truncate)
R6   KILLED   bench FAIL [y_exp]                oracle pass 0.7500 LSB -- y_exp is e_y_raw PLUS sh, not minus (a power-of-two scale error)
R7   KILLED   bench FAIL [y_exp]                oracle pass 0.7500 LSB -- the gate is dropped: the product is o*o, not o*z
R8   KILLED   bench FAIL [o_last]               oracle pass 0.7500 LSB -- o_last is taken one pipeline stage early
R9   KILLED   bench FAIL [o_sat]                oracle pass 0.7500 LSB -- the per-head exponent mux is stuck on head 0 in pass B
R10  SURVIVED bench PASS                        oracle pass 0.7500 LSB -- the absolute value is one's complement, not two's
R11  KILLED   bench FAIL [throughput]           oracle pass 0.7500 LSB -- the double buffer is collapsed: one bank at a time, consistently
R12  SURVIVED bench PASS                        oracle pass 0.7500 LSB -- in_ready is tied high, so elements are dropped by a full bank
R13  KILLED   bench FAIL [o_sat]                oracle pass 0.7500 LSB -- o_sat is raised on every block (the flag is tied high)
R14  SURVIVED bench PASS                        oracle pass 0.7500 LSB -- sat16's positive rail is 32766
C1   SURVIVED bench PASS                        oracle pass 0.7500 LSB -- sat16's positive rail is 32766 in the C model
C2   KILLED   bench FAIL [y_exp]                oracle pass 0.5000 LSB -- msb_pos_u returns one too many, so sh is one too large
C3   SURVIVED bench PASS                        oracle pass 0.7500 LSB -- the model's sat flag is never set
C4   KILLED   bench FAIL [y_exp]                oracle FAIL 1073741824.0000 LSB -- the model multiplies in int16, so the product wraps
B1   KILLED   bench FAIL [accuracy: worst]      oracle FAIL 32238.2521 LSB -- every element is aligned one bit too far (shj + 1)
B2   KILLED   bench FAIL [accuracy: worst]      oracle FAIL 2114046719395797.0000 LSB -- e_y_raw is head 0's exponent, not the minimum over the block
B3   KILLED   bench FAIL [accuracy: 28037 elements] oracle pass 1.0000 LSB -- the requantize truncates instead of rounding, in BOTH
B4   KILLED   bench FAIL [normalisation]        oracle pass 0.0000 LSB -- the output rail drops from 16 bits to 15, in BOTH
B5   KILLED   bench FAIL [normalisation]        oracle pass 0.5000 LSB -- site 13 keeps one bit less headroom (msb-13), in BOTH
kill ratio: 17 killed, 6 survived, of 23
```

**B3 and B4 moved from SURVIVED to KILLED and B5 is new and killed**, so the
harness goes from 14 killed / 8 survived of 22 to 17 killed / 6 survived of 23.
The 14/8 is DERIVED, not re-measured: the run above shows six survivors, the
harness's own header text records B3 and B4 as expected survivors before this
track, and 6 + 2 = 8 over 22 rows.

An intermediate run is worth recording because it shifts the attribution.  With
the accuracy gate in but BEFORE the normalisation check was added, B4 read
`KILLED bench FAIL [accuracy: worst]` -- the max caught it at 15854 LSB.  With
the normalisation check in, the normalisation branch is reported first because
it is the sharper diagnosis.  Both fire; the classifier picks one.

### 5.7 `gdn_emit_chain`: the documented survivor of BOTH oracles, killed

The chain's B4, at the gate's own generics (`OVERLAP=true COL_GAP=4
STRICT=false SILU_LANES=16 RMS_LANES=4 Z_DELAY=640`), 3 blocks x 24 heads:

```
--- the mutant, generator first ---
  worst end-to-end error vs the double oracle: 0.8505 LSB of the output grid (block 1)
--- the mutant, bench as it stands now ---
(report error): tb_gdn_emit_chain: block 0 NORMALISATION -- the largest |y| is only 11620, under the floor of 16384. ...
(report error): tb_gdn_emit_chain: block 1 NORMALISATION -- the largest |y| is only 12399, under the floor of 16384. ...
(report error): tb_gdn_emit_chain: block 2 NORMALISATION -- the largest |y| is only 12675, under the floor of 16384. ...
(report failure): tb_gdn_emit_chain: FAIL -- 0 mismatched elements and 3 blocks
    failing the normalisation floor, COL_GAP=4 refused-column cycles=7255

--- THE CONTROL: the SAME mutant, with sim/tb_gdn_emit_chain.vhd from HEAD ---
(report note): tb_gdn_emit_chain: PASS -- 3 blocks x 24 heads x 128 bit-exact,
    OVERLAP=true COL_GAP=4 refused-column cycles=7255 SILU_LANES=16 RMS_LANES=4
```

The generator's own end-to-end double oracle reads 0.8505 and prints OK on that
same tree, against an honest 1.2057 at the same shape.

**`0 mismatched elements` is the whole finding in one line.**  Every one of the
9216 elements matches the golden exactly, the golden's own double oracle says
the chain got BETTER, and the unit is one octave wrong.  The counters are split
in the bench for precisely this reason: reporting "3 mismatched elements" on a
run where nothing mismatched would have been a misleading verdict on the one
case the check exists to catch.

### 5.9 The gate, after

MEASURED, every row whose name contains `emit`, on the final tree:

```
 suite sim   PASS 4   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
 OVERALL     PASS 4   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

Those four are `tb_gdn_head_emit`, `tb_gdn_y_emit`, `tb_gdn_emit_chain` and
`tb_attn_emit`.  `sim/regress.sh` is not modified by this track -- `git diff --
sim/regress.sh` is empty -- and `BASELINE_PASS` is untouched, because no row was
added or removed.

### 5.8 Every threshold shown to fire, by generic override, on the HONEST unit

The five `gdn_head_emit` gates, each tightened one at a time past the honest
figure, with a sixth override as the negative control:

```
### -gACC_MIN_CHECK=9000     gdn_head_emit: OUT OF TOLERANCE -- the oracle saw only 8192 elements, floor is 9000.
### -gACC_NORM_FLOOR=20000   gdn_head_emit: NORMALISATION failed on 14 of 64 cases
### -gACC_NEAR_MAX=10        gdn_head_emit: OUT OF TOLERANCE -- 14 elements past 5.0e-1 LSB, cap is 10.
### -gACC_MEAN_M=50          gdn_head_emit: OUT OF TOLERANCE -- mean accuracy error 5.9421903483711715e-2 LSB exceeds 5.0e-2 LSB.
### -gACC_MAXLSB_M=900       gdn_head_emit: OUT OF TOLERANCE -- worst accuracy error 9.999847412109375e-1 LSB exceeds 9.0e-1 LSB (case 3 col 24).
### -gACC_NEAR_M=1500        tb_gdn_head_emit: PASS -- 64 cases x 128 bit-exact ... and within 1.5 LSB of the real-valued oracle on every one of 8192 elements
```

Every one of the five can be made to fail on the correct design, so none of
them is dead code.  The last row is the control: RAISING the counting threshold
from 0.5 to 1.5 LSB leaves the run green, which is what it must do -- the honest
unit has zero elements past 1.0 LSB.  `ACC_NORM_FLOOR=20000` firing on 14 of 64
cases also says the honest population is not miles above the 16384 floor; 14
cases sit in [16384, 20000).

## 6. Measured and REJECTED -- do not retry

- **Excluding the SATURATED ELEMENTS instead of the saturated CASES.**  This is
  the obvious repair and it is worthless on `gdn_y_emit`.  MEASURED, section
  5.1: under B4 the element-excluded max is `0.750000` and the element-excluded
  count past 0.5 LSB is `3492`, both identical to the honest unit to every
  printed digit.  Only the mean and the population size move.  Do not narrow
  the exclusion; delete it.
- **Porting the FLOOR mechanism alone, which is what section 9.4 of the
  companion document prescribes.**  It is necessary and it is not sufficient.
  MEASURED: on `gdn_y_emit` under B4 the case-excluded population collapses
  147456 -> 21504, so a floor DOES fire -- but the same floor is silent under
  the grid-coarsening mutation B5, where the population is the full 147456 and
  every figure in it reads better than the honest unit.  The floor makes an
  EMPTIED oracle loud; it says nothing about a FULL oracle that is measuring
  the wrong thing.
- **Any accuracy threshold, at any value, against a grid coarsening.**
  MEASURED on all three units.  `gdn_head_emit` msb-13: worst `0.999985 ->
  0.500000`, count past 0.5 LSB `14 -> 0`, mean `0.059422 -> 0.055006`.
  `gdn_y_emit` msb-13: worst `0.750000 -> 0.500000`, count `3492 -> 0`, mean
  `0.155923 -> 0.158819`.  `gdn_emit_chain` at NB=3: the generator's own
  end-to-end figure `1.2057 -> 0.8505`.  Every one of those moves the safe way
  or barely moves, because the numerator and the denominator double together.
  There is no tolerance to tune.  The claim has to be on a quantity the
  mutation does not also rescale.
- **`gdn_head_emit`'s max as a gate on the truncated requantize (B3).**
  MEASURED: honest `0.999985`, mutated `1.000000`.  1.5e-5 apart.  Any
  threshold that catches it is under the honest figure.  The count catches it
  by 130x and the mean by 3.7x.
- **`gdn_y_emit`'s mean as a gate on the truncated requantize (B3).**
  MEASURED: honest worst over 40 seeds `0.204489`, mutated `0.271581`.  1.33x
  apart, which is inside the honest seed-to-seed spread of 1.80x on the same
  figure.  Left wide deliberately.
- **A `real` tolerance generic anywhere in these benches.**  ghdl-mcode refuses
  the override (`unhandled type for generic override`) and elaboration dies, so
  no simulation runs at all.  Every threshold here is an integer in
  thousandths of an LSB for exactly that reason -- so it CAN be swept, and so
  the check can be shown to fail without editing the file.

## 7. Measurement traps hit

- **A brief's numbers are a snapshot of a document, not of the tree.**  Two of
  the five units in the dispatch had been fixed four hours earlier, and the
  document this track was asked to write already existed under that exact
  filename.  Reading `git log --format='%h %ad %s'` on the owned files before
  writing anything took one command and saved redoing a day's work.
- **A figure quoted from a mutation harness is at THAT harness's arguments.**
  The chain's `1.1280` is at neither `NB = 3` nor the committed `NB = 6`; the
  honest figures are `1.2057` and `1.5300`.  The `0.8505` it is quoted against
  is exact at `NB = 3`.  Comparing a mutated figure at one shape with an honest
  figure at another is how a 1.06x move gets read as a 1.33x move.
- **`sat_any` is a WHOLE-CASE flag whose name reads like an element flag**, and
  `nsat` in the same generator counts ELEMENTS.  The two are printed on the
  same line.  "saturated columns: 14" and "cases with sat_any = 1: 8" are both
  true of the same run and neither is derivable from the other.
- **The honest `gdn_y_emit` vectors have ZERO saturating cases**, so every
  measurement of the exclusion's cost on the committed file reads zero and the
  exclusion looks harmless.  It is only visible under a mutation.  A blind spot
  that costs nothing today is still a blind spot; the fix was free precisely
  because it costs nothing today.
- **A derived bound that is ATTAINED gives a gate zero margin.**  The
  normalisation floor of 16384 is hit exactly, at every one of 40 seeds, always
  on the saturation-shaped case.  That is correct for an identity of the
  recipe, but it means an off-by-one in the comparison direction is a false red
  rather than a silent pass, which is the failure mode `rmsnorm_bf`'s
  2026-08-26 assert shipped with.  The comparison is `<` and the constant is a
  generic so it can be moved and swept.
- **Two independent oracles agreeing is worth the twenty minutes.**  The
  Python `Fraction` version and the Python integer version were written
  separately and agreed; the VHDL then agreed with both to every printed digit.
  Had the VHDL disagreed, there would have been no way to tell which of the two
  was wrong.

## 8. What is NOT verified

- **`gdn_emit_chain` has no real-valued accuracy oracle in its bench, and this
  track did not write one.**  It gained the normalisation check only.  Writing
  the accuracy half means re-implementing the whole chain in double inside the
  bench -- the per-head minimum exponent, the mean square, the reciprocal square
  root, the `ssm_norm` weight product and the silu gate with `exp` -- which is a
  different size of job from the two emit units, whose oracle is one line of
  arithmetic.  The generator already computes exactly that oracle; what it
  lacks is a path from its exit code to `sim/regress.sh`, which is Route A and
  is listed as open below.
- **The `!sat_any` exclusion is still present in all three GENERATORS.**  It was
  deliberately not touched: removing it changes the generators' own exit-code
  semantics under a bound (`>= 1.0`) that the honest unit can reach at `sh = 1`
  by the same derivation that bounds it, so the change risks a false red for
  every track that runs a mutation harness.  The bench is now the authority and
  the harness headers say so.  This is recorded as a known-misleading figure,
  not as a fixed one.
- **Coverage of the input space is not coverage of the output space.**  The
  `gdn_head_emit` case set cannot reach `|o_acc| >= 2^36` (clamped by the
  generator to stay inside the RTL's own assert), `e_o` outside `[-8, 47]`, or
  any distribution of `e_o` other than the six named shapes.  The `gdn_y_emit`
  set cannot reach `e_p` outside `[-10, 39]`, and its "saturation" shape 5 does
  **not actually saturate** -- MEASURED, `nsat = 0` on the committed run,
  because the requantize normalises to 15 bits before the rail can be reached.
  Saturation in `gdn_y_emit` is reachable only through the rounding edge and is
  not reached at all by the committed seed.
- **Every figure is at the committed shape.**  `gdn_head_emit` at 64 x 128,
  `gdn_y_emit` at 48 x 24 x 128, `gdn_emit_chain` at 6 x 24 x 128.  The counts
  and the floors are ABSOLUTE counts; changing the shape changes what they mean
  and nothing enforces that.
- **The 40-seed envelopes bound the counts, not the tails.**  `gdn_y_emit`'s
  count past 0.5 LSB spans 930..5648 over 40 seeds -- 6.1x between its own
  extremes.  The gate at 12000 is 2.1x above the observed maximum.  Whether 40
  seeds bound that statistic is exactly the question `81297ee` answered NO to
  for `tb_gdn_recur`'s `TOL_S`, where two sweeps disagreed 2.08x on a maximum.
  The maxima here are safe because they are derived; the counts are not, and
  2.1x is the whole margin.
- **No hardware ran.  No Vivado ran.  No `rtl/` file was modified.**

## 9. Open, not yet answered

1. **`gdn_emit_chain`'s accuracy oracle.**  Either Route A (a `tb_vector_args`
   row so the gate regenerates the vectors and reads the generator's exit code,
   which certifies the C rather than the DUT) or a full double-chain oracle in
   the bench.  The chain is the one unit where Route A is arguably the right
   answer, because the oracle it would consult is genuinely end to end and the
   bench's own stimulus IS the generator's.
2. **`tb_vector_args` rows for all five committed B vectors.**  The stale-golden
   class that `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md` closed
   for `gdn_conv` is still open for `gdn_silu`, `rmsnorm_bf`, `gdn_head_emit`,
   `gdn_y_emit` and `gdn_emit_chain`.  Route A and Route B do not conflict.
3. **Whether the normalisation floor should be `sh > 0` conditional in the
   chain bench too.**  It is unconditional there, guarded only against an
   all-zero block, because the bench cannot recover `sh` from the vector file.
   MEASURED, 20 seeds x 6 blocks: `y_exp` is 10 on every one of 120 blocks and
   the minimum `max|y|` is 18383, so `sh > 0` always holds on this stimulus.
   Nothing enforces that it will keep holding if the stimulus changes.
4. **The same normalisation claim is missing from `gdn_recur`, `gdn_conv` and
   `rmsnorm_bf`**, all of which requantize to a data-dependent exponent.  This
   track measured it only where it was needed to kill a recorded survivor.
