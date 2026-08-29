# The 8.955 LSB is not the d_m grid defect, and the gate that held it fires on the honest unit

Date: 2026-08-29
Track: B-RECUR (backlog item 8)
Units: `rtl/gdn_recur.vhd` (B 2.1.4), `rtl/gdn_exp_capture.vhd` (B 2.1.2)
Supersedes, in part: `docs/debugging/2026-08-26_gdn-first-token-dm-grid.md`

---

## 1. The question, verbatim

> **Part 1: mutation coverage for `gdn_recur` and `gdn_exp_capture`.** These are
> the two subsystem B units that TRACK B-MUT's sweep did not reach. Give them
> the treatment the rest of B has now had.
>
> **Part 2: the open `d_m` grid defect behind the 8.955 LSB worst case.** This
> is a REAL OPEN DEFECT, not a verification gap. Root-cause it. If it is an RTL
> defect, say so precisely and report it; fix it only if the fix is small and
> you can demonstrate teeth on the fix. If it is an oracle or a grid artefact,
> say that instead and show why.

The symptom, as it stood at the start: `sim/tb_gdn_recur.vhd` on the committed
`sim/gdn_recur_vec.txt` reports

```
gdn_recur: bit-exact with the C recipe on all 384 cases; over the 274 physically
realizable ones, worst vs the double ORACLE is 8.955004673607618 state LSB and
6.577674348402551e-5 of the output dot's term norm [worst at case 243, eg=32768,
term norm 3.852725748403052e4]
gdn_recur: worst state error splits by token index -- 8.955004673607618 LSB in
steady state, 1.1105957031722937 LSB at tk = 0.  The gap is the open d_m grid
defect, not noise.
```

against `TOL_S = 12.0` and `TOL_O = 1.0e-4`.

---

## 2. The answer, up front

**Three findings, in descending order of importance.**

**(a) The 8.955 is an ordinary sample, not a defect signature.** MEASURED over
52 seeds of the same generator with the same adopted recipe, the honest unit's
worst state error ranges **1.512 to 15.429 LSB**, median 5.030. The committed
seed's 8.955 sits at roughly the 65th percentile. No conclusion about a defect
can be drawn from it.

**(b) The gate that held it FIRES ON THE HONEST UNIT.** `TOL_S = 12.0` is
exceeded at 2 of those 52 seeds and `TOL_O = 1.0e-4` at 3, so **5 of 52 seeds
(9.6%) turn `sim/regress.sh` red with no defect present**. Both bounds were
derived from the committed seed alone and documented as carrying "~34%" and
"~52%" margin; the real margin is 2.5% and 21% against the honest distribution.
This is the same shape TRACK B-GATE measured on `rmsnorm_bf` the same day.

**(c) The label on the figure is wrong, and is WITHDRAWN.** The bench's own
report line calls the steady-state figure "the open d_m grid defect". At the
adopted defaults (`D_NORM`, `TK0_ED`, `EG0_ED` all true) `d_m` is already
normalized onto its own grid, and MEASURED by stagewise ablation, removing
`d_m`'s rounding entirely moves the worst case the **wrong way**, 8.955 to
9.182. **87% to 97% of the figure is stage 3's FLOOR of `skm` onto
`e_d = min(e_v, ske)`** -- a different site, one stage earlier in the same
`min`, and one the 2026-08-26 amendment never touched. That document's own
"Open, not yet answered" list asks whether the borrowed-grid pattern appears at
other sites; this is the answer for stage 3's alignment, and it is now the
dominant error term.

**Is (c) an RTL defect?** It is a **recipe** property, not a transcription
error: `rtl/gdn_recur.vhd` and `ref/gdn_recur_vec.c` agree bit for bit, and both
implement what 2.1.4 pins. It is real information loss and it is the largest
remaining accuracy term in the unit, but the correction is a change to a pinned
numerical contract. **A candidate correction was measured and REJECTED as
formulated** -- see section 6. Nothing in `rtl/gdn_recur.vhd` was changed.

**What DID change:** `sim/tb_gdn_recur.vhd`'s gates, set from the seed sweep
rather than from one seed, with two count gates and a floor added because a max
alone provably cannot see three of the recipe mutations; and
`sim/tb_gdn_exp_capture.vhd`, which gained a cross-entry read and a same-cycle
capture/read collision because two mutations survived without them. Two new
mutation harnesses, `sim/mutate_gdn_recur.sh` (33 rows) and
`sim/mutate_gdn_exp_capture.sh` (18 rows), are committed.

---

## 3. The procedure that produced it

Ordered as run. Each step names what it controls for.

1. **Reproduce the number and build an independent path to it.** A 60-line
   Python reader recomputes the bench's two oracle metrics straight out of the
   vector file. It agrees to every printed digit (8.955004673607618,
   6.577674348402551e-5), which is what licenses using it instead of a
   nine-minute GHDL run for the sweeps below. *Controls for: the bench's
   arithmetic being the thing under test.*

2. **Build a bit-exact model of the recipe, and PROVE it bit-exact.** The same
   Python mirrors the fixed path integer for integer. MEASURED: **0 of 384
   cases differ in `snew`, 0 differ in `se_new`.** Since the bench separately
   proves the RTL bit-exact with the C, a conclusion drawn on the mirror
   transfers to the RTL. *Controls for: reasoning about a model that is not the
   unit.*

3. **Ablate one quantization at a time.** Each of the six lossy steps in the
   column is replaced, alone, by exact real arithmetic, and the worst state
   error is remeasured. This is what identifies the site; no amount of reading
   the recipe does. *Controls for: attributing an error to the site one already
   suspects.*

4. **Repeat the ablation at the worst case of twelve DIFFERENT seeds** before
   believing the attribution. *Controls for: a mechanism that is really one
   case's coincidence.*

5. **Sweep 52 seeds and get the honest distribution BEFORE judging the 8.955.**
   The generator hardcodes `rs_ = 20260825`; a copy in scratch takes the seed as
   `argv[4]`. VERIFIED: run from the repo root with the default seed it
   reproduces the committed `sim/gdn_recur_vec.txt` **byte for byte**, so the
   only difference between the sweep and the gate is the seed. *Controls for:
   the committed seed being an outlier at either end -- the exact trap B-GATE
   hit at the benign end.*

6. **Measure the candidate correction on the SAME 20-seed set, not on the
   committed seed.** *Controls for: the D_NORM-alone mistake, where a fix
   validated on a vector set that could not see a neighbouring defect measured
   seven times better while being seven times worse.*

7. **Mutate, with a harness that has three verdicts.** RTL-only, C-only and
   BOTH-class mutations for `gdn_recur`; RTL-only for `gdn_exp_capture`, whose
   golden is a behavioural model in the bench. ABORT is separate from SURVIVED,
   counted as a kill and named, because "no failure line" is not "passed".

---

## 4. The evidence

### 4.1 The honest seed-to-seed range (52 seeds, MEASURED)

Generator: `ref/gdn_recur_vec.c` with `rs_` taken from `argv[4]`, `d_norm=1
tk0_ed=1`, 384 cases per seed. Metric: exactly the bench's, recomputed by the
independently written reader.

```
52 seeds
  nphys        min 271          median 276          max 279
  worst_state  min 1.51173      median 5.03012      max 15.4287
  worst_o      min 8.1239e-06   median 3.06125e-05  max 0.00079421
  med_state    min 0.5507       median 0.59745      max 0.6593
  n>1LSB       min 7            median 29           max 44
  n>4LSB       min 0            median 1            max 5
  worst_tk0    min 1.0004       median 1.0559       max 1.1248
  worst_ss     min 1.5117       median 5.0301       max 15.4287
  seeds with worst_state > 12.0 (the committed TOL_S): 2 of 52
  seeds with worst_o     > 1e-4 (the committed TOL_O): 3 of 52
  seeds failing EITHER committed gate: 5 of 52
```

Note `worst_tk0` never leaves [1.000, 1.125] while `worst_ss` spans a factor of
ten. The 2026-08-26 correction's claim that `tk = 0` is no longer the hard class
is confirmed across seeds, not just at one.

The two seeds that fail `TOL_S`: 135 at **15.429**, 139 at **14.622**. The three
that fail `TOL_O`: 130 at **7.942e-4**, 122 at 1.409e-4, 120 at 1.174e-4.

### 4.2 The ablation, at the committed seed's worst case

Case 243: `tk0=0 eg=32768 beta=18741 se_j=-2 e_v=-10`, and the derived scalars
`sh_sk=11 ske=4 e_d=-10 s1=0 s2=14 shd=9 e_dm=-3 e_kd=12 e_u=0 su=0 sk2=12 sh=2
se_new=-2`.

```
   full fixed worst = 8.95500 (elem 65)   [file says 8.95500]
   exact stage1 w18 round                       -> worst    8.95500  (removes  0.00000)
   exact stage2 skm round                       -> worst    8.95500  (removes  0.00000)
   exact stage3 diff FLOOR (v,skm onto e_d)     -> worst    0.57751  (removes  8.37750)
   exact stage3 FLOOR of v only                 -> worst    8.95500  (removes  0.00000)
   exact stage3 FLOOR of skm only               -> worst    0.57751  (removes  8.37750)
   exact stage3 alignment ROUNDED not floored   -> worst    1.91791  (removes  7.03710)
   exact stage3 d_m round                       -> worst    9.18248  (removes -0.22748)
   exact stage4 u floors (su,sk2)               -> worst    8.95500  (removes  0.00000)
   exact stage4 final requantize round          -> worst    8.68473  (removes  0.27027)
```

`d_m`'s own rounding removes **minus** 0.227: taking it out makes the figure
worse. The v-side floor removes nothing because `s1 = 0`. The single line that
matters is the `skm` floor, worth 8.378 of 8.955 = **93.6%**.

### 4.3 The same ablation at the worst case of twelve seeds

```
seed  case  full   exact-w  exact-s  exact-diffFLOOR exact-dm  exact-ufloor exact-requant
104       311   6.624    6.624    6.624    0.804    6.271    6.624    6.146
109       233   8.189    8.189    8.189    1.061    7.462    8.189    7.936
112       311   8.315    8.315    8.315    0.741    8.315    8.315    8.065
11         16  10.618   10.618   10.618    0.614   11.152   10.618   10.493
122       270   8.096    8.096    8.096    0.518    8.096    8.096    7.832
131        13   8.598    8.598    8.598    0.515    7.888    8.598    8.258
132       311   7.749    7.749    7.749    0.496    8.054    7.749    7.432
135       215  15.429   15.429   15.429    0.518   15.429   15.429   15.717
139       203  14.622   14.622   14.622    0.622   13.874   14.622   14.372
20260825  243   8.955    8.955    8.955    0.578    9.182    8.955    8.685
42        200   6.792    6.792    6.792    0.526    7.060    6.792    6.792
7         216  11.707   11.707   11.707    0.740   11.619   11.707   11.369
```

Twelve for twelve: removing the alignment floor collapses 6.6-15.4 LSB to
0.50-1.06 LSB -- it is worth 87.0% (seed 109) to 96.6% (seed 135) of the total,
93.6% at the committed seed -- and every other quantization moves the figure by
at most 0.31 LSB (three of them move it the wrong way). In all twelve `s1 = 0`, i.e. `e_v`
is the coarser exponent and `e_d = e_v`, so the floor that fires is always
`skm`'s.

**Mechanism, stated once.** Stage 3 forms `diff = v - sk` on
`e_d = min(e_v, ske)`, the COARSER of the two grids, which is what keeps `diff`
inside its `s18`. `skm >> (ske - e_d)` is a FLOOR, so it injects up to one full
LSB of the `e_d` grid into `diff`, biased in one direction. That error is
multiplied by `beta`, then by `k_n[i]`, and lands in `u` on the grid
`e_u = min(se_j + 2, e_kd)`, which at these cases is **2^10 finer than `e_d`**.
The amplification factor is `2^(e_u - e_d) * beta * |k_n[i]|`. It is the same
class as the `d_m` defect the 2026-08-26 amendment fixed -- a value quantized on
a grid unrelated to its own magnitude -- at a site that amendment did not reach.

### 4.4 `gdn_exp_capture`: 18 mutations, 15 killed

`bash sim/mutate_gdn_exp_capture.sh`, after the bench additions of section 5.2.

```
M0   SURVIVED 0    -- CONTROL: unmutated
M1   KILLED   214  -- the capture shifts the WRONG WAY: the new exponent lands in tap 0
M2   KILLED   141  -- the shift drops TWO taps per capture instead of one
M3   KILLED   141  -- the word is REPLACED rather than shifted (only the current tap survives)
M4   KILLED   185  -- the capture address transposes layer and segment
M5   KILLED   185  -- the READ address transposes layer and segment (capture does not)
M6   KILLED   85   -- mask_of is off by one: the oldest valid tap is dropped
M7   KILLED   49   -- mask_of is off by one the other way: one INVALID tap is declared valid
M8   KILLED   0    -- tvalid is built from the CAPTURE entry's count, not the read entry's
M9   KILLED   36   -- the tap counter saturates at K-1, so the oldest tap is never valid
M10  KILLED   85   -- the tap counter is never incremented (tvalid stays all-zero)
M11  ABORT    0    bound check failure  -- the counter's saturation guard is deleted
M12  KILLED   3    -- seq_rst does not clear the counters
M13  KILLED   218  -- rd_ack is asserted a cycle early, before e_t/tvalid are stable
M14  SURVIVED 0    -- the read is served straight out of the array, skipping the RMW settle
M15  KILLED   0    -- a READ wins over a capture in S_IDLE, so a capture can be dropped
M16  ABORT    0    stop-time, the FSM hangs  -- cap_ready never drops
M17  SURVIVED 0    -- the RMW's read-settle cycle is deleted (S_IDLE goes straight to S_CAP_WR)
```

**The two survivors, named, both TRUE EQUIVALENT MUTANTS rather than stimulus
gaps.**

- **M14** `e_t_r <= mem(rd_addr_r)` in place of `e_t_r <= mem_q`. `mem_q` is
  loaded from the same address one cycle earlier in `S_IDLE`, and `mem` is
  written only in `S_CAP_WR`, which cannot be reached while the FSM is in
  `S_RD`. No stimulus can separate them. Not a coverage hole; provable.
- **M17** deleting the `S_CAP_RD` hop. That state exists to give "one cycle for
  the synchronous read to land in `mem_q`" (the unit's own comment), but the
  assignment is made in `S_IDLE`, so `mem_q` is already stable at the start of
  whichever state follows. The finding is about the UNIT: **it spends one cycle
  per capture doing nothing.** Reported, not fixed -- a capture is not a hot
  path, and the cycle buys a clean separation between the array read and the
  shift.

Before the bench additions the survivor list was **five**: M8, M13, M14, M15,
M17. M13 as first written was a duplicate assignment in a state that already
made it, i.e. a harness bug, and was rewritten. M8 and M15 were genuine holes
and are closed in section 5.2.

### 4.5 The two worst honest seeds, run through the ACTUAL bench

Everything in 4.1 is the Python reader. The two seeds that failed the OLD gates
hardest were then run through `tb_gdn_recur` itself, with the new gates, as
`ghdl -r ... -gVECS=<seed file>`:

```
=== seed 135 ===
gdn_recur: 384 cases, 0 with a mismatch; over the 277 physically realizable ones,
worst vs the double ORACLE is 1.5428692937130108e1 state LSB and
6.989868735098331e-5 of the output dot's term norm [worst at case 215, eg=32768,
term norm 2.200060195655633e-6]
gdn_recur: columns past 1 LSB 29 (gate 66), past 4 LSB 4 (gate 12),
columns checked 277 (floor 240)
gdn_recur: bit-exact with the C recipe on all 384 cases, and inside every oracle gate

=== seed 130 ===
gdn_recur: 384 cases, 0 with a mismatch; over the 276 physically realizable ones,
worst vs the double ORACLE is 2.5366514440484025 state LSB and
7.942067313928669e-4 of the output dot's term norm [worst at case 24, eg=42,
term norm 7.974167222365781e-8]
gdn_recur: columns past 1 LSB 22 (gate 66), past 4 LSB 0 (gate 12),
columns checked 276 (floor 240)
gdn_recur: bit-exact with the C recipe on all 384 cases, and inside every oracle gate
```

15.429 against the former `TOL_S` of 12.0, and 7.942e-4 against the former
`TOL_O` of 1.0e-4. Both are green now and both were red before, on an honest
unit and the committed RTL. The bench's own `n_gt1` also agrees with the Python
reader case for case at the committed seed (29 and 29), which is the
cross-check that licenses the sweep numbers being used to set a bench gate.

### 4.6 `gdn_recur`: 33 mutations

See section 7 for the table as run against the NEW gates, and section 5.1 for
what changed between the two runs.

---

## 5. What was changed

### 5.1 `sim/tb_gdn_recur.vhd`: gates set from the sweep, plus counts and a floor

| gate | was | now | basis |
|---|---|---|---|
| `TOL_S` (max state LSB) | 12.0 | **24.0** | 1.56x the 52-seed max 15.429 |
| `TOL_O` (max output / term norm) | 1.0e-4 | **1.2e-3** | 1.51x the 52-seed max 7.942e-4 |
| `N_GT1_MAX` columns past 1 LSB | -- | **66** | 1.5x the 52-seed max 44 |
| `N_GT4_MAX` columns past 4 LSB | -- | **12** | 2.4x the 52-seed max 5 |
| `N_MIN` columns actually checked | -- | **240** | 0.89x the 52-seed min 271 |

The two maxima were RAISED, which weakens them, and that is the point: at 12.0
and 1.0e-4 the gate was red on the honest unit at 5 of 52 seeds, so it was not
measuring the unit. The counts carry the resolution the maxima gave up, and they
carry more than the maxima ever had: **B3 and B6 below are killed by the counts
and by nothing else.** `N_MIN` exists because every other gate here gets
HAPPIER as columns leave the checked set (`c_phys = 0` and `exp_err = 1` both
exclude silently), which is TRACK B-GATE's B7 lesson transplanted.

Two further changes, neither of them a gate:

- **The measurement summary is now printed unconditionally.** It used to sit
  behind `nexact = 0 and ntol = 0`, so the moment anything went red the numbers
  saying HOW red vanished from the log. The success sentence is separate, is the
  last thing printed, and is the only line carrying a phrase `regress.sh`'s
  `PASS_RE` matches -- so a truncated run is a NOVERDICT, not a pass.
- **The "d_m grid defect" claim is withdrawn in place**, with the ablation
  result and a pointer here.

### 5.2 `sim/tb_gdn_exp_capture.vhd`: two phases added

- **PHASE 2, a cross-entry read.** The token loop always read back the entry it
  had just written, so `cap_addr_r` and `rd_addr_r` were equal at every read.
  After a `seq_rst` (which is what makes two entries distinguishable at all --
  with every counter saturated at K the masks are identical whichever address is
  used) it captures into (0,0) and reads (1, SEGS-1), which must report no valid
  tap. Kills M8.
- **PHASE 3, a same-cycle capture/read collision.** `cap_req` and `rd_req` were
  never high together, so the arbitration the unit's header states as a
  correctness property was unexercised. Kills M15.

### 5.3 Nothing in `rtl/` was changed

`rtl/gdn_recur.vhd` and `rtl/gdn_exp_capture.vhd` are untouched. The stage-3
finding is a pinned-contract question (section 6); the `gdn_exp_capture` wasted
cycle is a cost question, not a correctness one.

`sim/regress.sh` was NOT edited: no test row is added or removed, so
`BASELINE_PASS` is unchanged at 83.

---

## 6. Measured and REJECTED -- do not retry

### 6.1 "Round the stage-3 alignment instead of flooring it." REJECTED as insufficient.

One extra adder and a bias constant, and it is what `round_shift` already does
two sites earlier. MEASURED over 20 seeds it helps, but inconsistently: worst
state error 8.955 -> 2.267 at the committed seed, 15.429 -> 3.843 at seed 135,
but **14.622 -> 9.378 at seed 139 and 11.707 -> 7.857 at seed 7**. Halving a
bound that spans a factor of ten is not a fix; the residual is still a half-LSB
of a grid up to 2^10 coarser than the one the result is accumulated on.

### 6.2 "Align on the FINER grid, `e_d = max(e_v, ske)`, with the shift clamped at 16 bits." REJECTED. It is 10,000x WORSE at 2 of 20 seeds.

This is the direction the mechanism points at, and on 18 of 20 seeds it looks
decisive -- worst state error collapses to 1.03-1.61 LSB everywhere and the
output figure falls 6-8x. Then:

```
seed      mode       n   worst_s   worst_o     med   n>1
130       base     276     2.537 7.942e-04   0.567    22
130       round    276     1.683 7.942e-04   0.563    16
130       wide     276 26227.794 1.611e-02   0.550    11
31337     base     277     6.216 2.868e-05   0.588    32
31337     round    277     4.272 1.739e-05   0.582    20
31337     wide     277  1163.862 5.563e-03   0.563     6
```

**26,227 LSB against a pinned 2.537.** Had this been measured on the committed
seed alone it would have read 1.111 against 8.955 and been reported as a clean
8x win. That is the D_NORM-alone trap from 2026-08-26 reproduced exactly, on a
different site, one document later.

**The cause is the CLAMP, not the idea, and that is the reusable part.** A
hardware `diff` has a fixed width, so the left shift that moves an operand onto
the finer grid must be bounded; the obvious bounding -- shift left by the
clamp, then floor away the remainder -- FLOORS THE OPERAND THAT WAS ALREADY
EXACT ON ITS OWN GRID, which the `min` formulation never does. Re-running the
same two seeds with the clamp lifted to 64 bits gives worst_s **1.454** and
**1.457**. So:

- the direction is sound and the pinned recipe is genuinely leaving 6-10x on
  the table at these cases;
- **no bounded implementation of it has been measured that is safe**, and the
  first one tried is four orders of magnitude worse than doing nothing;
- adopting it requires a wider `diff` and a wider `diff * beta` (likely one
  more DSP), a change to `ref/gdn_recur_vec.c` and `ref/gdn_err.c`, and an
  amendment to a pinned 2.1.4 contract that section 2.10 and section 3.3 both
  reference.

**Recommendation: do not adopt on this evidence.** File it as the successor to
the 2026-08-26 amendment, to be taken with a width analysis and a seed sweep in
hand, not one night's numbers.

### 6.3 "Tighten `TOL_S` instead of raising it, since 8.955 looks large." REJECTED.

8.955 is the 65th percentile of the honest distribution. Any bound that calls it
suspicious is red on the honest unit at more than half of all seeds.

### 6.4 "Gate on the median state error." REJECTED as redundant here.

MEASURED: the median moves 0.577 -> 1.062 under B3 and -> 0.914 under B6, so a
median gate at 0.90 would catch both. It catches nothing the count past 1 LSB
does not already catch (29 -> 199 and 29 -> 130 for the same two), while costing
a sort in the bench and sitting 1.5% from B6's value, which is fragile across
seeds. The counts are kept, the median is not.

### 6.5 "Set a count gate tight enough to catch B5." REJECTED, and this is the resolution floor.

B5 (d_m truncates instead of rounding, in the RTL and the C alike) moves the
count past 1 LSB from 29 to **49**, against an honest 52-seed maximum of **44**.
A gate that catches it must sit below 44 and would therefore be red on honest
seeds. **`gdn_recur`'s accuracy checking cannot resolve a rounding-mode change
at `d_m` on this vector set.** Same shape as B4 in `sim/mutate_gdn_scalar.sh`
and S1 in `2026-08-28_b-accuracy-transcription-vs-arithmetic.md`.

---

## 7. The `gdn_recur` mutation table

`bash sim/mutate_gdn_recur.sh`, seed 20260825, against the NEW gates of section
5.1. `exact` is bit-exactness against the C fixed path; `bench` is the bench's
four oracle gates, the only verdict `sim/regress.sh` can fail; `agg` is the
script's own state-side aggregate over the file's own oracle columns. The two
numbers after `bench` are the worst state LSB and the worst output-dot figure.

```
M0   CTRL SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- CONTROL: unmutated

---- class RTL: rtl/gdn_recur.vhd alone.  Must fail bit-exactness ----
R1   RTL  KILLED   exact FAIL bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- site 6's w18 rounding bias is dropped on the sk-dot path
R2   RTL  KILLED   exact FAIL bench FAIL agg pass  5200.729 / 1.14e-02  n>1LSB  29  -- ske is se_j + 16, not se_j + 17
R3   RTL  KILLED   exact FAIL bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- site 7 normalizes sk to 15 bits, not 16
R4   RTL  KILLED   exact FAIL bench FAIL agg pass 299576.527 / 1.70e-01 n>1LSB  29  -- stage 3 takes the MAX of the two exponents, not the min
R5   RTL  SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- the eg = 0 masked-operand arm is dropped at e_d (EG0_ED half off)
R6   RTL  KILLED   exact FAIL bench FAIL agg pass     8.955 / 1.10e+00  n>1LSB  29  -- the eg = 0 masked-operand arm is dropped at e_u (the other half)
R7   RTL  SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- sat16's positive rail is one low
R8   RTL  SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- sat16's negative rail is one high
R9   RTL  KILLED   exact FAIL bench pass agg pass     4.577 / 6.50e-05  n>1LSB  29  -- the final requantize keeps 14 bits, not 15
R10  RTL  KILLED   exact FAIL bench FAIL agg pass     9.270 / 6.66e-05  n>1LSB  29  -- the final requantize's rounding bias is dropped
R11  RTL  KILLED   exact FAIL bench FAIL agg pass     8.955 / 3.28e-01  n>1LSB  29  -- e_o is se_new + 17
R12  RTL  KILLED   exact FAIL bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- 2.1.6's range check drops the e_o arm (se_new only)
R13  RTL  KILLED   exact FAIL bench FAIL agg pass 8.02e+12 / 2.46e+00   n>1LSB  29  -- stage 3's two alignment shifts are swapped
R14  RTL  KILLED   exact FAIL bench FAIL agg pass    10.452 / 6.74e-05  n>1LSB  29  -- D_NORM keeps 11 bits of d, not 15
R15  RTL  KILLED   exact FAIL bench FAIL agg pass 1.40e+08 / 3.61e+02   n>1LSB  29  -- stage 4's two output shifts su and sk2 are swapped
R16  RTL  KILLED   exact FAIL bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- site 7's rounding bias is dropped (skm truncates)
R17  RTL  KILLED   exact FAIL bench FAIL agg pass 1.60e+06 / 2.23e+01   n>1LSB  29  -- tk0 no longer masks the STATE READ, so it enters the sk dot
R18  RTL  KILLED   exact FAIL bench FAIL agg pass     8.955 / 5.28e-01  n>1LSB  29  -- the output dot uses q BEFORE the pipeline aligns it (q2, not q3)
R19  RTL  SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  n>1LSB  29  -- the amax reduction keeps the later of two equal operands

---- class C: ref/gdn_recur_vec.c alone.  Must fail bit-exactness ----
C1   C    KILLED   exact FAIL bench pass agg pass  agg max     8.955 med 0.581 n>1LSB  29  -- the C normalizes sk to 15 bits against the RTL's 16
C2   C    KILLED   exact FAIL bench pass agg FAIL  agg max 32660.643 med 2786.773 n>1LSB 271  -- the C's e_kd is 16 + e_dm against the RTL's 15 + e_dm
C3   C    KILLED   exact FAIL bench pass agg FAIL  agg max 32660.643 med 2631.773 n>1LSB 264  -- the C's v is floored onto e_d one bit harder than the RTL's

---- class BOTH: the same recipe change in the C AND the RTL ---------
B1   BOTH KILLED   exact pass bench FAIL agg FAIL  2600.271 / 5.70e-03  med 56.815  n>1LSB 175  -- stage 3 floors skm ONE MORE BIT onto e_d (the site root-caused here)
B2   BOTH SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  med  0.599  n>1LSB  29  -- site 6's w18 rounding bias is dropped in BOTH (truncate)
B3   BOTH KILLED   exact pass bench FAIL agg FAIL     9.270 / 6.66e-05  med  1.062  n>1LSB 199  -- the final requantize truncates instead of rounding, in BOTH
B4   BOTH SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  med  0.579  n>1LSB  29  -- site 7's skm truncates instead of rounding, in BOTH
B5   BOTH SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  med  0.581  n>1LSB  49  -- d_m truncates instead of rounding, in BOTH
B6   BOTH KILLED   exact pass bench FAIL agg FAIL    10.452 / 6.74e-05  med  0.914  n>1LSB 130  -- D_NORM keeps 11 bits of d instead of 15, in BOTH
B7   BOTH KILLED   exact pass bench FAIL agg pass     8.955 / 1.10e+00  med  0.589  n>1LSB  31  -- EG0_ED is removed in BOTH: the eg = 0 masked operand is back in both grids
B8   BOTH KILLED   exact pass bench FAIL agg FAIL  1.17e+07 / 1.48e+31  med  0.582  n>1LSB  54  -- TK0_ED is removed at e_d in BOTH: the tk = 0 phantom grid is back
B9   BOTH KILLED   exact pass bench FAIL agg FAIL  2261.704 / 1.17e-02  med  0.652  n>1LSB  93  -- D_NORM is removed in BOTH: d_m goes back to the pinned e_d grid
B10  BOTH SURVIVED exact pass bench pass agg pass     8.955 / 6.58e-05  med  0.577  n>1LSB  29  -- stage 4 drops the min: e_u is always se_j + 2 when not masked

kill ratio: 24 killed (0 of them by ABORT), 9 survived, of 33
```

### 7.1 What the gate change bought, MEASURED

Same 33 mutations, the only difference being `sim/tb_gdn_recur.vhd`'s gates.

| | old gates (`TOL_S` 12.0, `TOL_O` 1e-4, no counts) | new gates |
|---|---|---|
| BOTH-class rows the BENCH kills | 4: B1, B7, B8, B9 | **6**: + B3, B6 |
| honest seeds the bench turns red | **5 of 52** | **0 of 52** |

B3 and B6 are killed by the count past 1 LSB and by nothing else: B3's worst
case is 9.270 against the control's 8.955, and B6's is 10.452, both far inside
any bound the honest distribution permits. That is the concrete instance of
B-GATE's "a max-only gate cannot be made honest for these units".

### 7.2 The eight survivors, named

None is discarded. Four are provable equivalences, four are stimulus gaps, and
the difference is stated per row.

- **R5** -- `eg = 0` arm deleted at `e_d`. **STIMULUS GAP.** Observable only when
  `eg = 0` AND `e_v > se_j + 17`; the generator draws `eg = 0` only in PHYS
  groups, where `e_v = se_j + rnd(-8, 8)`. No such column exists. Its twin R6,
  the same arm at `e_u`, is killed with an output figure of 1.10. Closing this
  needs a generator change and `ref/**` is another track's.
- **R7, R8** -- `sat16`'s rails moved by one, each way. **STIMULUS GAP.** The
  saturation path is never entered: `u` is normalized so that `max|u|` has its
  msb at bit 15 before the requantize, and no rounding in this file pushes an
  element past the rail.
- **R19** -- `>` becomes `>=` in the amax tree. **TRUE EQUIVALENT.** The tree
  reduces a maximum; the compare decides which of two EQUAL operands is kept and
  never what value is kept.
- **B2** -- `w18`'s rounding bias dropped in both languages. **RESOLUTION
  FLOOR.** Only the median moves, 0.577 to 0.599. Site 6 is 13 bits above the
  grid the error is measured on.
- **B4** -- `skm`'s rounding bias dropped in both. **RESOLUTION FLOOR.** Median
  0.577 to 0.579. `skm` is then floored again by up to 14 bits at stage 3
  (section 4.3), which swallows a half-LSB at its own grid entirely.
- **B5** -- `d_m`'s rounding bias dropped in both. **RESOLUTION FLOOR, and the
  closest miss.** Count past 1 LSB moves 29 to 49 against an honest maximum of
  44; see section 6.5 for why no honest gate can sit below that.
- **B10** -- stage 4's `min(se_j + 2, e_kd)` deleted. **EQUIVALENT ON THIS
  STIMULUS, and a finding in its own right:** every figure is bit-identical to
  the control, so `e_kd > se_j + 2` in all 274 physically realizable columns and
  the `min` never binds. It is the same statement, from the other side, as
  section 4.3's observation that `e_u` is 2^10 finer than `e_d`.

### 7.3 The one result worth extracting from the table

**B7 and R6, the two rows that reintroduce the `eg = 0` masked operand, leave
the state figure at exactly 8.955 and are caught only by the OUTPUT DOT.** R6's
output figure is 1.10 and B7's is 1.0985, a 110% error on the whole column's
contribution, while the state metric does not move by one part in 10^15. That
is the 2026-08-26 correction's central claim -- "the metric is LSB of the unit's
own grid and that grid is exactly what the phantom exponent coarsens, so it
structurally cannot see the loss" -- reproduced as a controlled experiment
rather than an argument. Anyone tempted to simplify this bench down to the
state metric should read those two rows first.

---

## 8. Measurement traps hit, including my own

1. **I wrote two mutations that changed only a threshold and not the value it
   guarded.** R3 ("normalize sk to 15 bits") and R9 ("requantize to 14 bits") as
   first written moved `if p - 14 > 0` to `if p - 13 > 0` while leaving
   `sk_sh <= p - 14` alone, so they were observable only at the single value
   `p = 14` and both SURVIVED. A survivor is a claim about the checker; these
   two were claims about my anchors. Both rewritten to change the threshold and
   the shift together. **Read what a mutation actually does to the arithmetic,
   not what its description says.**

2. **A mutation that duplicates an assignment the state already makes is not a
   mutation.** M13's first form added `rd_ack_r <= '1'` inside `S_RD`, which
   already assigns it. It read as a survivor and would have been written up as a
   coverage hole in the read handshake.

3. **The bench's summary was printed only on a clean run**, so every mutation
   that fired the oracle gate reported its figures as unavailable and the
   harness could not tell "bit-exact stayed green" from "the run died". Both
   look like a missing line. Fixed by printing the measurement unconditionally
   and giving the harness a separate liveness marker.

4. **The `TOL_O` outliers are a SMALL DENOMINATOR, not an accuracy loss, and I
   nearly filed them as undiagnosed.** `worst_o` at seed 130 is 7.942e-4 and
   does not move under any variant -- base, rounded alignment, wide alignment
   all report it -- which looked like a second undiagnosed mechanism. It is not.
   The bench prints the term norm at the worst case precisely so this can be
   checked, and MEASURED in the bench:

   ```
   committed seed  worst 6.578e-05 at case 243  term norm 3.853e+04
   seed 135        worst 6.990e-05 at case 215  term norm 2.200e-06
   seed 130        worst 7.942e-04 at case  24  term norm 7.974e-08
   ```

   Twelve orders of magnitude of denominator. The seeds that "fail" `TOL_O` are
   the seeds that happen to contain a column whose oracle output dot has almost
   no scale to be relative TO -- the metric's own trap, which this bench's
   header already warns about and guards only at 1e-300. **`TOL_O = 1.2e-3` is
   therefore 18x looser than it needs to be for a well-conditioned column, and
   the honest fix is a floor on the term norm, not a looser bound.** Not done
   here: choosing that floor needs its own sweep. VERIFIED that the looseness
   costs no kill -- the smallest output figure among the killed mutations is
   B1's 5.70e-3, still 4.75x above the bound.

5. **A 52-seed range is not a distribution.** 15.429 is the largest of 52
   samples, not a bound. `TOL_S = 24.0` is 1.56x that largest sample and could
   still be exceeded by a seed nobody has drawn. The count gates are what make
   that tolerable; a single unlucky max no longer decides the verdict alone.

6. **The long head is stratified onto one corner.** `ref/gdn_recur_vec.c` gives
   the 128-column long head `pick_eg(0) = 32768` unconditionally, so **128 of
   the ~274 physically realizable columns, 47%, sit at a fully open decay gate**
   and never sample the measured per-head distribution. Every worst case in
   section 4.3 that is in the long head inherits that. Not changed --
   `ref/**` belongs to another track -- but any conclusion about the eg
   distribution drawn from this vector set is weighted accordingly.

---

## 9. Open, NOT verified

- **The accumulation of the alignment bias over a sequence.** The floor at stage
  3 is one-sided, so in a recurrence it is a systematic drift, not noise. Every
  measurement here is **one column of one token**; `tb_gdn_recur` cannot see
  accumulation at all, and nothing else measures it either.
- **A term-norm floor on the output metric.** Diagnosed (trap 4) but NOT
  implemented: `TOL_O` currently absorbs a near-degenerate denominator instead
  of excluding it, which is the same shape as the `n_odeg` skip the bench
  already does at 1e-300, just at a threshold nobody has measured.
- **The `e_d` half of `EG0_ED` is untested by the vector set.** MEASURED:
  mutation R5, which deletes the `eg = 0` arm at `e_d` while leaving it at
  `e_u`, SURVIVES. It is only observable when `eg = 0` AND `e_v > se_j + 17`,
  and the generator draws `eg = 0` only in the PHYS groups, where
  `e_v = se_j + rnd(-8, 8)`. No column in the file satisfies both. The other
  half, R6 at `e_u`, is killed.
- **`sat16` never saturates on this vector set.** MEASURED: R7 and R8, which
  move each rail by one, both SURVIVE bit-exactness. The saturation path in
  `gdn_recur` is unexercised.
- **Stage 4's `min` never binds.** MEASURED: B10 deletes it in the RTL and the C
  together and is bit-identical to the control on every figure, so `e_kd` is
  above `se_j + 2` in every physically realizable column here.
- **Whether `beta` in the real model reaches the small range.** Still open from
  2026-08-26: `ref/gdn_eg_qwen3_27b.txt` exists for `exp(g)` and nothing
  equivalent exists for `beta`.
- **Everything above is at `DIM = 128, LANES = 8`.** `gdn_recur_pipe` is a
  separate unit with its own bench and was not mutated here.
- **No synthesis was run.** No area or timing claim is made.

---

## 10. The gate, after

Full unfiltered run, `bash sim/regress.sh --jobs 3`, 2026-08-29, with three
other tracks live on the box:

```
 suite sim   PASS 57   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 83   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS
```

**OVERALL PASS 83**, matching the recorded floor. No test row was added or
removed, so `BASELINE_PASS` is unchanged and `sim/regress.sh` was not edited at
all. `sim:tb_gdn_recur` PASS (7 s), `sim:tb_gdn_exp_capture` PASS (0 s).

## 11. How to re-run any of this

```bash
bash sim/mutate_gdn_recur.sh          # 33 rows, ~8 min; SCRATCH=<dir> to keep it
bash sim/mutate_gdn_exp_capture.sh    # 18 rows, ~1 min
```

The seed sweep is not committed as a script because it needs a one-line patch to
`ref/gdn_recur_vec.c`, which belongs to another track. To redo it:

```bash
sed 's/    rs_ = 20260825ULL;/    rs_ = (argc > 4) ? strtoull(argv[4], 0, 10) : 20260825ULL;/' \
    ref/gdn_recur_vec.c > /tmp/gen.c
cc -O2 -w -I ref -o /tmp/gen /tmp/gen.c -lm
/tmp/gen /tmp/v.txt 1 1 <SEED>          # MUST be run from the repo root
```

Run it once with no seed argument and `cmp` the result against
`sim/gdn_recur_vec.txt` before trusting anything it produces; that check is what
proves the patched copy is the committed generator.
