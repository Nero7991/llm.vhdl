# Subsystem B: moving `gdn_silu`'s and `rmsnorm_bf`'s accuracy claims into the gate

Date: 2026-08-29.  Repo `llama.vhdl`, branch `fpga`.
Simulator: ghdl-mcode, VHDL-2008, `-frelaxed`.  No hardware involved.
Follows section 7 of `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md`,
which scoped this work and deliberately did not do it.

## 1. The question

Verbatim, from the dispatch:

> Two of subsystem B's units have NO accuracy gate that `sim/regress.sh` can
> fail. Their oracle figures are PRINTED by a vector generator that the gate
> never consults, so an RTL accuracy defect is invisible to the regression.
>
> **Do `gdn_silu` and `rmsnorm_bf`, and ONLY those two.** ...
>
> **The flagship case, and your acceptance test:** there is a mutation of
> `rmsnorm_bf` that reintroduces exactly the defect that unit exists to fix. It
> is currently bit-exact-green in the gate and is 1.7e10 output LSB wrong. When
> you are done, that mutation must FAIL the gate. If it does not, you have not
> finished.
>
> Section 7 ... scopes two routes and they are NOT equivalent ... Pick per
> unit, with the reason stated.

## 2. The answer

**Route B for both units.**  Neither took Route A, and the reason is the same
for both: Route A moves the claim into the generator's exit code, so it can
only ever certify the C.  Both benches already compare the DUT against the C
bit-exactly, so the ONLY thing left for an accuracy gate to add is a claim the
C cannot make -- and a claim routed through the C is exactly that claim.

Each bench now carries its own real-valued oracle, written as the definition
and sharing nothing with either integer transcription, and gates FOUR figures
at severity error:

| | `gdn_silu` | `rmsnorm_bf` |
|---|---|---|
| max abs err, LSB | 3.5 | 20.0 |
| count past | 1.5 LSB, cap 60 | 0.5 LSB, cap 800 |
| MEAN abs err, LSB | 0.200 | 0.300 |
| floor on elements checked | 32768 | 24000 |

**The flagship is closed.**  MEASURED end to end, with a control: mutation B1
(`rq_d := rq_p - Q` in the RTL *and* the C, golden regenerated so bit-exactness
is green by construction) now makes `sim/regress.sh --only tb_rmsnorm_bf` print
`REGRESSION: FAIL`, and the SAME tree with `sim/tb_rmsnorm_bf.vhd` restored from
`HEAD` prints `REGRESSION: PASS`.  Raw output in section 5.

**No new gate rows and no `BASELINE_PASS` change.**  `sim:tb_gdn_silu` and
`sim:tb_rmsnorm_bf` were already rows; the work was entirely inside the two
benches.  `sim/regress.sh` is NOT touched by this track.

**Three findings that were not asked for and that change how the numbers should
be read:**

1. **The committed `rmsnorm_bf` seed is an outlier at the benign end.**  Over
   nine generator seeds the honest unit's worst error moves **0.770 -> 9.999
   LSB** and its count past 0.5 LSB moves **49 -> 465**.  The committed
   20260826 is the lowest of both by an order of magnitude.
2. **Therefore `sim/mutate_rmsnorm_bf.sh`'s `ACC_LSB=1.0`, in the tree before
   today, fires on the HONEST unit at eight of those nine seeds.**  It was
   fitted to one seed and reported as a "baseline with headroom"; it has none.
3. **A max-only gate could not have been made honest for either unit.**  For
   `gdn_silu`, mutation B4's worst case (2.570 LSB) sits INSIDE the honest
   seed-to-seed range (1.844 - 2.621).  For `rmsnorm_bf`, B5 (2.281) and B6
   (1.344) both sit inside the honest range (0.770 - 9.999).  Those three are
   caught only because the count and the mean are gated as well.

## 3. The procedure, in the order it was run

Each step isolates one thing and each one changed a decision.

1. **Read the two benches and both generators before writing anything.**
   Established that `gdn_silu`'s vector file carries `sm` and `y` only, and
   `rmsnorm_bf`'s carries `x`, `w` and `o` only.  **Neither carries an oracle
   column.**  Section 7 of the companion document says "the vector file already
   carries the oracle columns for all five"; for these two it does not, and
   where a document and the artefact disagree the artefact wins.  This is what
   forced the oracle to be transcribed INTO the bench rather than read from a
   column, which turned out to be the stronger form anyway.
2. **Reproduced the committed vectors byte for byte** from the generators at
   their defaults, so that any later difference is attributable.
3. **Wrote the in-bench oracle and checked it against the generator's own
   double path**, on the figure they both compute.  Agreement to every digit
   printed, at the same case and element, is the evidence that the VHDL
   transcription of the definition is the same definition.
4. **Checked the one place the VHDL oracle could differ from the C's:
   `2.0 ** n` against `ldexp`.**  MEASURED: zero deviations from repeated
   exact halving/doubling over n in [-120, 120] (`tb_pw`, section 5.1).  Both
   oracles therefore scale exponents exactly, which matters because every
   figure here is quoted in LSB of a block-floating grid.
5. **Extended both `mutate_*.sh` to print a `bench` column** beside the
   existing `oracle` column, so the two claims can be compared per mutation
   rather than argued about.
6. **Measurement pass with the bench gate WIDENED to infinity** (`BACC`), to
   collect raw max/count/mean per mutation with nothing failing.
7. **Nine-seed sweep of the UNMUTATED unit.**  This is the step that changed
   the design.  A gate fitted to step 6 alone would have been tuned to one
   draw of the input distribution.
8. **Set every threshold to clear all nine honest seeds AND kill every
   BOTH-class mutation**, then re-ran both suites at the committed generics.
9. **Added `mutate_rmsnorm_bf.sh` B7 to give the FLOOR teeth**, because no
   existing mutation empties the oracle and an ungated floor is decoration.
10. **End-to-end demonstration through `sim/regress.sh` itself**, in a
    throwaway `git archive` tree, with the pre-change bench as the control.
    Running the bench directly is not the same as failing the gate; the gate
    has its own `FAIL_RE`, its own pass markers and its own verdict logic, and
    only a run through it proves the message is matched.

### What each gated figure controls for

- **max** -- a single catastrophic element.  Blind to a systematic shift.
- **count past a threshold** -- a shift in the tail.  This is what catches
  `gdn_silu` B4 and `rmsnorm_bf` B5, neither of which the max can see.
- **mean** -- a systematic bias across every element.  This is what catches
  `rmsnorm_bf` B6, and it is the most seed-stable of the three (10% spread over
  nine seeds against the max's 13x).
- **floor on elements checked** -- an EMPTIED oracle.  `rmsnorm_bf` excludes
  saturated elements, which is an exclusion on an OUTPUT property, so a
  mutation that saturates everything makes every other figure look BETTER than
  the honest unit.  B7 does exactly that: max 0.4375 against the honest 0.7704,
  count 0 against the honest 49.

## 4. Route A vs Route B, decided per unit

**`gdn_silu`: Route B.**  Route A would have made `sim/regress.sh` regenerate
`gdn_silu_vec.txt` and read the generator's exit code -- but the generator does
not gate on accuracy at all today (its only non-zero return is the int16
overflow check), so Route A would first have required adding a threshold to the
C.  That threshold would then certify the C's `y` array.  The bench already
proves the DUT equals that array bit-exactly, so the composition would be a
valid accuracy claim about the DUT -- but ONLY while bit-exactness holds, and
it would say nothing on the day someone regenerates the golden from a changed
C.  Route B is one strictly stronger statement in the same place.

**`rmsnorm_bf`: Route B.**  Same argument, plus the flagship: B1 is a change to
BOTH transcriptions, so under Route A the mutated C would be gated by the
mutated C's own printed figure.  The generator's figure does move under B1
(1.68e10 LSB), so Route A would in fact have caught THIS mutation -- but only
because the mutation is in the C as well.  An RTL-only accuracy defect, with
the C left correct, moves the generator's figure by exactly zero.  MEASURED:
mutation R3 is the RTL-only form of the same defect, and its `oracle` column
reads `pass 1.8019e-05 gain / 0.7704 LSB` -- the unmutated numbers -- while the
`bench` column reads `FAIL 1.682e+10 LSB`.  That row is the whole argument for
Route B in one line.

**What Route A would ALSO have fixed and Route B does not.**  Route A kills the
stale-golden class (defect D1) for good, by regenerating unconditionally.
Route B leaves `sim/gdn_silu_vec.txt` and `sim/rmsnorm_bf_vec.txt` committed and
un-regenerated, so a future edit to either generator that is not accompanied by
a regenerated vector still goes unnoticed by the gate.  **That is an open item,
not something this track closed**, and it is listed in section 9.  The two
routes are complementary and a later track can add the `tb_vector_args` rows on
top of this work without conflict.

## 5. The evidence, as captured output

### 5.1 The oracle transcription is the same definition

Generator, unmutated, at its defaults:

```
gdn_silu_vec: 256 cases x 128 -> gdn_silu_vec.txt (ARG_Q=12)
  worst abs err vs double oracle: 1.8442 LSB (case 31)

rmsnorm_bf_vec: 200 cases x 128 -> rmsnorm_bf_vec.txt (Q=12 eps=1.000e-06 E_EPS=50 M_EPS=1125899907)
  worst abs err of the OUTPUT vs double: 0.7704 LSB (case 79)
  saturated elements: 640   nonzero flushed to zero: 643
```

The two benches, on the committed vectors, through `sim/regress.sh`:

```
sim/tb_gdn_silu.vhd:195:5:@115565ns:(report note): gdn_silu accuracy vs the real-valued
  oracle: worst 1.8441562729658472 LSB at case 31 element 93; 14 of 32768 elements past
  1.5 LSB; mean 1.1857914794993378e-1 LSB

sim/tb_rmsnorm_bf.vhd:323:5:@60815ns:(report note): rmsnorm_bf accuracy vs the real-valued
  oracle: worst 7.703593954793178e-1 LSB at case 79 element 116; 49 of 24960 unsaturated
  elements past 5.0e-1 LSB; mean 2.1076343595974778e-1 LSB; 640 saturated and excluded
```

Same value, same case, same element, and the same 640 saturations, from an
implementation that shares no line of code with the C.

`2.0 ** n` against exact repeated halving/doubling, ghdl-mcode:

```
tb_pw.vhd:23:5:@0ms:(report note): 2.0**n exactness: 0 deviations over n in [-120,120]
```

### 5.2 The honest unit over nine generator seeds, AT THE COMMITTED GATE

`gdn_silu`, 256 x 128, ARG_Q 12:

```
seed 20260826  OUT_OF_TOLERANCE_reports=0  max=1.8441562729658472 near=14 mean=1.1857914794993378e-1
seed 1         OUT_OF_TOLERANCE_reports=0  max=1.93233387197688   near=5  mean=1.1915712060263299e-1
seed 2         OUT_OF_TOLERANCE_reports=0  max=2.621296394507226  near=30 mean=1.1953619262799789e-1
seed 7         OUT_OF_TOLERANCE_reports=0  max=2.4370628488741204 near=26 mean=1.1867094891600176e-1
seed 42        OUT_OF_TOLERANCE_reports=0  max=2.3076734720725653 near=45 mean=1.3787980595664234e-1
seed 123       OUT_OF_TOLERANCE_reports=0  max=2.288562238907616  near=22 mean=1.1815922690082242e-1
seed 999       OUT_OF_TOLERANCE_reports=0  max=2.4503119567143585 near=38 mean=1.3063661410670865e-1
seed 31337     OUT_OF_TOLERANCE_reports=0  max=2.2032682050667063 near=34 mean=1.1927901695668368e-1
seed 20260829  OUT_OF_TOLERANCE_reports=0  max=2.0305958677963645 near=20 mean=1.3686703413515536e-1
```

`rmsnorm_bf`, 200 x 128, Q 12, eps 1e-6:

```
seed 20260826  OUT_OF_TOLERANCE_reports=0  max=7.703593954793178e-1 near=49  mean=2.1076343595974778e-1
seed 1         OUT_OF_TOLERANCE_reports=0  max=3.176389313834079    near=465 mean=2.2054337356499007e-1
seed 2         OUT_OF_TOLERANCE_reports=0  max=2.8184066890935355   near=264 mean=2.1476100717199947e-1
seed 7         OUT_OF_TOLERANCE_reports=0  max=5.19025911387871     near=388 mean=2.2440648102993474e-1
seed 42        OUT_OF_TOLERANCE_reports=0  max=3.8668691747916455   near=292 mean=2.1890423870614825e-1
seed 123       OUT_OF_TOLERANCE_reports=0  max=4.705713698054751    near=403 mean=2.206362086498075e-1
seed 999       OUT_OF_TOLERANCE_reports=0  max=9.999342733121011    near=375 mean=2.3220033422426228e-1
seed 31337     OUT_OF_TOLERANCE_reports=0  max=2.419368669307005    near=209 mean=2.149885667264564e-1
seed 20260829  OUT_OF_TOLERANCE_reports=0  max=4.548491643909074    near=416 mean=2.2785620741655965e-1
```

18 honest runs, zero false positives.  `near` is the count past 1.5 LSB for
`gdn_silu` and past 0.5 LSB for `rmsnorm_bf`, i.e. each unit's own gated
threshold.

### 5.3 The flagship, through `sim/regress.sh`, with its control

Throwaway tree from `git archive HEAD`; mutation B1 applied to
`rtl/rmsnorm_bf.vhd` AND `ref/rmsnorm_bf_vec.c`; `sim/rmsnorm_bf_vec.txt`
regenerated by the mutated C, so bit-exactness is green by construction.

```
B1 applied to BOTH transcriptions in the throwaway tree
golden REGENERATED by the mutated C, so bit-exactness is green by construction:
  differs from the committed golden, as it must

--- with this track's sim/tb_rmsnorm_bf.vhd
FAIL       sim:tb_rmsnorm_bf   8s  .../sim/tb_rmsnorm_bf.vhd:344:7:@60815ns:(report error
 OVERALL     PASS 0   FAIL 1   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: FAIL

--- NEGATIVE CONTROL: same mutated RTL+C+golden, sim/tb_rmsnorm_bf.vhd from HEAD
PASS       sim:tb_rmsnorm_bf   9s  .../sim/tb_rmsnorm_bf.vhd:182
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

The failing message:

```
rmsnorm_bf: OUT OF TOLERANCE -- worst accuracy error 1.682481463580507e10 LSB
exceeds 2.0e1 LSB (case 175 element ...)
```

The same demonstration for `gdn_silu`, using B4, which is the SUBTLE one -- its
max is inside the honest seed range, so it is killed by the count alone:

```
silu B4 applied to BOTH transcriptions
--- NEW bench (this track):
FAIL       sim:tb_gdn_silu   3s  .../sim/tb_gdn_silu.vhd:231:7:@115565ns:(report error
 OVERALL     PASS 0   FAIL 1 ...
--- NEGATIVE CONTROL, same mutation under the HEAD bench:
PASS       sim:tb_gdn_silu   3s  .../sim/tb_gdn_silu.vhd:98:7:@115
 OVERALL     PASS 1   FAIL 0 ...
```

### 5.4 `gdn_silu` mutation table, at the committed gate

`bash sim/mutate_gdn_silu.sh`, 256 x 128, seed 20260826, ARG_Q 12.  Honest
baseline: max 1.844 LSB, 14 past 1.5 LSB, mean 0.1186, n 32768.

| tag | what it changes | bit-exact | bench gate | which figure fired, and the margin |
|---|---|---|---|---|
| R1 | S4 Q30->Q15 sigma round truncated | FAIL | **FAIL** | count 69 vs 60 (1.15x) |
| R2 | S6 output round truncated | FAIL | **FAIL** | count 85 vs 60 (1.42x) |
| R3 | S0 M_RSH branch truncates | FAIL | **FAIL** | count 363 vs 60 (6.1x) |
| R4 | S1 ROM index one bit low | FAIL | **FAIL** | max 3.18e4 vs 3.5 (9086x) |
| R5 | S1 interpolation fraction dropped | FAIL | **FAIL** | max 506.5 vs 3.5 (145x) |
| R6 | S2 table delta negated | FAIL | **FAIL** | max 1014 vs 3.5 (290x) |
| R7 | S4 sigma high clamp one low | FAIL | pass | bit-exactness only (47 mismatches) |
| **R8** | S-1 flush-to-zero threshold 61 not 62 | pass | pass | **SURVIVES, see below** |
| **R9** | S-1 left-shift rail threshold 41 not 40 | pass | pass | **SURVIVES** |
| **R10** | S1 LOW rail compare excludes boundary | pass | pass | **SURVIVES** |
| R12 | S1 HIGH rail compare excludes boundary | FAIL | **FAIL** | max 32.0 vs 3.5 (9.1x) |
| R11 | S5 mantissa one pipeline stage late | FAIL | **FAIL** | max 6.49e4 vs 3.5 (18531x) |
| C1 | sigma unity clamp 32767 | FAIL | pass | bit-exactness only |
| C2 | Q12 right-shift branch truncates | FAIL | pass | bit-exactness only |
| **C3** | deep-right-shift cutoff 61 not 62 | pass | pass | **SURVIVES** |
| B1 | output round-shift 16 not 15, BOTH | pass | **FAIL** | max 1.638e4 vs 3.5 (4680x) |
| B2 | LUT interpolation slope halved, BOTH | pass | **FAIL** | max 253.5 vs 3.5 (72x) |
| B3 | sigma saturation rail 16 -> 8, BOTH | pass | **FAIL** | max 5.249 vs 3.5 (1.50x) |
| B4 | output round bias dropped, BOTH | pass | **FAIL** | count 85 vs 60 (1.42x); **max 2.570 is INSIDE the honest range and cannot fire** |

kill ratio 15 killed, 4 survived, of 19.  Every BOTH-class mutation is killed by
the bench.

### 5.5 `rmsnorm_bf` mutation table, at the committed gate

`bash sim/mutate_rmsnorm_bf.sh`, 200 x 128, seed 20260826, Q 12, eps 1e-6.
Honest baseline: max 0.7704 LSB, 49 past 0.5 LSB, mean 0.2108, n 24960, 640
saturated.

| tag | what it changes | bit-exact | bench gate | which figure fired, and the margin |
|---|---|---|---|---|
| R1 | S_SEED2 rsqrt ROM indexed one bit high | FAIL | **FAIL** | max 75.43 vs 20 (3.8x) |
| R2 | second Newton iteration never updates y | FAIL | **FAIL** | count 2572 vs 800 (3.2x); max 2.281 is inside the honest range |
| R3 | **rq_d against Q not e_out (RTL ONLY)** | FAIL | **FAIL** | max 1.682e10 vs 20; the `oracle` column reads the UNMUTATED `0.7704 LSB` |
| R4 | emit round bias dropped | FAIL | **FAIL** | mean/count; max 1.344 is inside the honest range |
| R5 | emit shift one bit less headroom | FAIL | **FAIL** | max 38.5 vs 20 (1.9x) |
| **R6** | S renormalises to bit 31 not 30 | pass | pass | **SURVIVES, equivalent mutant** |
| **R7** | e_mean = E_EPS tie flips branch | pass | pass | **SURVIVES, dead branch and equivalent** |
| R8 | rq_E one too small | FAIL | **FAIL** | max 3.278e4 vs 20 |
| R9 | odd-rq_d 1/sqrt2 fold dropped | FAIL | **FAIL** | max 9531 vs 20 |
| **R10** | +32767 rail compare one low | pass | pass | **SURVIVES, equivalent by construction** |
| R11 | epsilon term dropped when mean smaller | **ABORT** | (no figures) | killed by the DUT's own Q30 normalisation assert, severity failure |
| R13 | +32767 rail EMITS 32766 | FAIL | **FAIL** | max 75 vs 20 |
| **R14** | -32768 rail EMITS -32767 | pass | pass | **SURVIVES, structurally dead branch** |
| **R12** | alignment rounds instead of truncating | pass | pass | **SURVIVES, confirms a documented claim** |
| C1 | emit saturation limit 32766 | FAIL | pass | bit-exactness only; the generator's figure DOES move (75.0 LSB) |
| **C2** | alignment rounds (mirror of R12) | pass | pass | **SURVIVES** |
| C3 | rsqrt ROM indexed one bit high | FAIL | pass | bit-exactness only; generator's figure moves (75.43 LSB) |
| B1 | **rq_d against Q not e_out, BOTH** | pass | **FAIL** | max 1.682e10 vs 20 (8.4e8x) |
| B2 | smaller of mean and eps dropped, BOTH | pass | **FAIL** | max 6519 vs 20 (326x) |
| B3 | emit shift one bit less headroom, BOTH | pass | **FAIL** | max 38.5 vs 20 (1.9x) |
| B4 | rq_E one too small, BOTH | pass | **FAIL** | max 3.209e4 vs 20 (1605x) |
| B5 | ONE Newton iteration, BOTH | pass | **FAIL** | count 2572 vs 800 (3.2x); **max 2.281 is inside the honest range** |
| B6 | emit round bias dropped, BOTH | pass | **FAIL** | **mean 0.4027 vs 0.300 (1.34x)**; max 1.344 inside the honest range |
| B7 | 30 bits of emit headroom, BOTH | pass | **FAIL** | **floor: 5113 elements vs 24000** |

Note the C-only rows.  C1 and C3 mutate the generator alone, so the DUT is
unchanged and the `bench` column correctly reads the unmutated 0.7704 LSB while
the `oracle` column moves.  That is the mirror image of R3 and is what shows the
two columns are measuring different things rather than duplicating each other.

kill ratio 18 killed, 6 survived, of 24.  Every BOTH-class mutation is killed by
the bench.

**B7 is the row to read twice.**  Its captured line:

```
B7   KILLED   bit-exact PASS  oracle pass 1.8019e-05 gain / 0.4375 LSB
     bench FAIL 0.4375 LSB / 0 past / n=5113
     rmsnorm_bf: OUT OF TOLERANCE -- the oracle saw only 5113 unsaturated
     elements, floor is 24000 (20487 were excluded as saturated)
```

Max 0.4375 against the honest 0.7704, and ZERO elements past the counting
threshold against the honest 49.  **On every gated figure except the floor, a
mutation that destroys the unit looks strictly BETTER than the correct one.**

### 5.6 The floor's teeth on `gdn_silu`

`gdn_silu` excludes nothing, so no mutation can empty its oracle; the floor
there guards only against a truncated run, which `sim/regress.sh` catches
separately as TIMEOUT or NOVERDICT.  The assert itself was still teeth-checked
by forcing the floor one element above the true count:

```
-gACC_MIN_CHECK=32769 -> gdn_silu: OUT OF TOLERANCE -- the oracle saw only 32768
                        elements, floor is 32769.  The accuracy figures below
                        are NOT evidence.
-gACC_MIN_CHECK=32768 -> 0 OUT OF TOLERANCE reports  (control)
```

## 6. Measured and REJECTED -- do not retry

- **A max-only accuracy gate on either unit.**  MEASURED: `gdn_silu` B4 (2.570
  LSB) and `rmsnorm_bf` B5 (2.281) and B6 (1.344) all sit INSIDE the honest
  unit's seed-to-seed max range.  A max threshold tight enough to kill them
  fires on the honest unit at another seed.  Do not "simplify" the gate to one
  number.
- **`ACC_LSB = 1.0` for `rmsnorm_bf`, the value already in
  `sim/mutate_rmsnorm_bf.sh` and described there as a baseline with headroom.**
  MEASURED: the honest unit exceeds it at eight of nine seeds (up to 9.999 LSB).
  It happens to work only because that script pins one seed.  Do not lift it
  into the bench.
- **Calibrating from the committed vector file alone.**  It is one draw.  For
  `rmsnorm_bf` it is the benign extreme of a 13x range.  Any future retune must
  re-run the nine-seed sweep; the commands are in section 3 step 7.
- **Gating the MEAN on `gdn_silu` tightly enough to catch B4.**  MEASURED:
  honest mean over nine seeds 0.1182 - 0.1379, B4 0.1789.  A threshold that
  separates them has 1.12x margin on one side and 1.30x on the other.  The
  count separates the same pair at 1.42x / 1.33x, so the count carries B4 and
  `ACC_MEAN_M` is set as a coarse net (0.200) instead.  The mean is still gated
  because it is the only figure that catches `rmsnorm_bf` B6.
- **Gating the generator's RELATIVE error figures.**  Both generators print one
  (`|y| >= 16 LSB` for silu, `|o| >= 1024 LSB` for rmsnorm) and neither is
  gated here.  MEASURED for silu: the honest figure is 4.95e-2, which is what a
  Q12 argument grid costs at 16 LSB of output; it reports the output word
  length back as if it were an error in the recipe.  Section 5's absolute-LSB
  figures say the same thing without the trap.
- **Reading the oracle out of the vector file** instead of transcribing it into
  the bench.  Rejected on inspection, not measured: the columns in both files
  are the C's integer output, so a check against them is a golden-freshness
  check.  Section 7 of the companion document says those files carry oracle
  columns; for these two units they do not.

## 7. Measurement traps hit, including my own

- **`2.0 ** n` had to be checked, not assumed.**  Every figure here is in LSB of
  a block-floating grid, so the oracle multiplies by a power of two whose
  exponent reaches 104.  The C uses `ldexp`, which is exact by definition;
  VHDL's `**` is not specified to be.  It IS exact on ghdl-mcode over the range
  used (section 5.1), but the gate would have been quietly wrong at the last
  ulp if it were not, and the error would have looked like a real one.
- **I broke the mutation harness's own verdict while improving it.**  Changing
  bit-exactness detection from "the success line is present" to "no MISMATCH
  line is present" made a run that DIED read as PASS: mutation R11 kills the
  DUT with its own Q30 normalisation assert, prints no mismatch, and was
  reported `SURVIVED bit-exact PASS`.  Caught by reading `R11/run.log` rather
  than the table.  Both harnesses now have a third state, ABORT, counted as a
  kill.  **The general form: replacing a positive marker with a negative one
  turns "did not finish" from a failure into a pass.**
- **`exp()` overflows before the gate does.**  `gdn_silu`'s `e` reaches -30, so
  the oracle's argument reaches 3.5e13 and `exp(-x)` overflows.  C returns +inf
  and the division silently gives the right answer; `ieee.math_real` is not
  required to.  The bench guards at |x| >= 40 and the guard's cost is DERIVED
  in the source: under 1.4e-13 LSB, thirteen orders below the measured worst
  case.
- **The first `near` threshold I chose was calibrated on the committed seed and
  would have been wrong.**  At 1.0 LSB for `gdn_silu` the committed count is 117
  and B3's is 160 -- a 1.37x separation that looked adequate until the seed
  sweep showed the honest count ranges 5 to 45 at 1.5 LSB and B3 is 47.  The
  final gate does not rely on that pair at all; B3 is killed by the max.
- **Trap NOT hit but worth recording:** `sim/regress.sh --only` takes a
  substring.  Every run here was checked on its `OVERALL PASS n` line, not on
  the word PASS.

## 8. What is NOT verified

- **The gate is calibrated, not derived.**  No threshold here is a bound proved
  from the recipe.  Each is a measurement over nine seeds with the margins
  stated per mutation in sections 5.4 and 5.5.  A tenth seed could exceed the
  honest range; the mean is the figure least likely to (10% spread), the count
  the most (9x).
- **Coverage of the input space is not coverage of the output space.**  The
  `gdn_silu` case set sweeps `e` over [-30, 40] with a structured selector and
  random mantissas.  It cannot reach: any `e` outside that band; any `sm`
  distribution other than "uniform int16, one in four small"; and it never
  drives two different `e` values inside one segment, because the bench drains
  between cases.  The `rmsnorm_bf` set never reaches the `-32768` emit rail
  (structurally unreachable, argued in the generator), `rq_E >= 0`,
  `rq_E > 32`, or either `inv32` clamp -- all four are reported NOT REACHED by
  the generator's own branch table and none is closed here.
- **`gdn_silu`'s ARG_Q is only gated at 12.**  The generator takes it as a
  parameter and the bench has it as a generic, but the committed vectors and
  every figure above are at 12.
- **`rmsnorm_bf`'s gate is only exercised at N=128, Q=12, eps=1e-6.**  The
  count thresholds are ABSOLUTE counts at that shape.
- **The stale-golden class is still open for these two units** (section 4).
  Neither has a `tb_vector_args` row, so `sim/regress.sh` still consumes a
  committed vector without regenerating it.
- **No claim is made about the three units section 7 of the companion document
  excluded.**  `gdn_head_emit`, `gdn_y_emit` and `gdn_emit_chain` were not
  touched.  B7 above is the first measurement of the FLOOR mechanism those two
  emit units will need, on a unit where the rest already works.
- **No hardware ran.  No Vivado ran.**

## 9. Open, not yet answered

1. Add `tb_vector_args` rows for `gdn_silu_vec.txt` and `rmsnorm_bf_vec.txt`
   (Route A), on top of this work, to close the stale-golden class.  The two
   routes do not conflict.
2. `sim/mutate_rmsnorm_bf.sh`'s `ACC_GAIN`/`ACC_LSB` are still fitted to one
   seed.  They are now a second opinion rather than the gate, so this is
   cosmetic, but the header should say so numerically.
3. The nine-seed sweep is a script that was run by hand and not committed.
   Whether it should become a `--slow` gate row is a judgement about runtime
   (18 runs, about 2 minutes) that this track did not make.
4. Port the floor mechanism to `gdn_head_emit` and `gdn_y_emit`, where the
   oracle is not merely at risk of being emptied but MEASURED as empty at a
   15-bit rail (41 of 48 cases saturate, 7 are all-zero).
