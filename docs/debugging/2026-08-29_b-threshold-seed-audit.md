# Subsystem B: every accuracy threshold against its honest seed-to-seed range

Date: 2026-08-29.  Repo `llama.vhdl`, branch `fpga`.
Simulator: ghdl-mcode, VHDL-2008, `-frelaxed`.  No hardware involved.
Follows `docs/debugging/2026-08-29_b-accuracy-gates.md` (TRACK B-GATE) and
`docs/debugging/2026-08-29_gdn-recur-coverage-and-dm.md` (TRACK B-RECUR), both
of which found the same defect on different units on the same day.

## 1. The question

Verbatim, from the dispatch:

> Two independent tracks, on two different units, today found the SAME defect
> and neither was looking for it.
>
> **TRACK B-GATE, on `rmsnorm_bf`:** the committed vector seed is the benign
> extreme of a 13x range. ... The pre-existing `ACC_LSB=1.0` in
> `sim/mutate_rmsnorm_bf.sh`, documented in the file as "a baseline with
> headroom", **fires on the HONEST unit at eight of nine seeds.**
>
> **TRACK B-RECUR, on `gdn_recur`:** ... **5 of 52 seeds, 9.6%, turn
> `sim/regress.sh` red with no defect present.** ...
>
> **Two for two.** Every accuracy threshold in subsystem B that was calibrated
> against a single committed seed is now suspect, and nobody has checked how
> many there are.
>
> **Part 1, the priority: audit EVERY accuracy threshold in subsystem B against
> its honest seed-to-seed range.** ... For each threshold, establish the honest
> unit's range across a decent number of seeds and report: the committed seed's
> value and its PERCENTILE within the honest range; the honest range, min to
> max; the threshold, and the **fraction of seeds at which it fires with no
> defect present**; the margin as documented in the file versus the real
> margin.
>
> **Part 2, if Part 1 leaves room: retune what you found, and do the three
> remaining item-11 units.**

## 2. The answer

**Thirty-five accuracy thresholds exist in subsystem B.  NINE of them fire on
the HONEST unit, and three of the nine were set or left in place TODAY by the
two tracks that discovered this class of defect.**

| threshold | file | honest false-red |
|---|---|---|
| `ACC_LSB = 1.0` | `sim/mutate_rmsnorm_bf.sh` | **39 of 40 (98%)** |
| `ACC_LSB = 2.0` | `sim/mutate_gdn_silu.sh` | **33 of 40 (82%)** |
| `ACC_GAIN = 3.0e-5` | `sim/mutate_rmsnorm_bf.sh` | **23 of 40 (58%)** |
| `TOL_S = 12.0` | `sim/tb_gdn_recur_pipe.vhd` | **5 of 30 (17%)** |
| `EG_N100_TOL = 17` | `sim/mutate_gdn_scalar.sh` | **4 of 40 (10%)** |
| `TOL_O = 1.0e-4` | `sim/tb_gdn_recur_pipe.vhd` | **2 of 30 (7%)** |
| `ACC_NEAR_MAX = 800` | `sim/tb_rmsnorm_bf.vhd` | **2 of 40 (5%)** |
| `TOL_S = 24.0` | `sim/tb_gdn_recur.vhd` | **1 of 30 (3%)** |
| `AGG_WS = 24.0` | `sim/mutate_gdn_recur.sh` | **1 of 40 (3%)** |

The other twenty-six are clean at 0 of 30-to-40 seeds and are listed by name in
section 4, because a report listing only the broken ones cannot be
distinguished from an incomplete audit.  The nine and the twenty-six are 21
bench-side, 11 harness-side and 3 generator-side; sections 4.1, 4.2 and 4.3
enumerate them in that order.

**Three findings that are worth more than the table.**

1. **`sim/tb_gdn_recur_pipe.vhd` was still carrying the exact two numbers
   TRACK B-RECUR retuned away from this morning**, and its own comment said
   they were "the SAME values as tb_gdn_recur's, because ... a different bound
   here would be a second standard for one recipe".  For a day the tree HAD
   that second standard, and the weaker of the two was the live gate row.  A
   retune that lands on one of two benches sharing a recipe is half a retune.
2. **B-RECUR's retuned `TOL_S = 24.0` is ITSELF false-red.**  Its 52-seed sweep
   put the honest maximum at 15.429; a 30-seed sweep with a different seed set
   found 32.122 at seed 20260101, **2.08x higher**.  Two independent sweeps
   disagreeing by 2.08x on the maximum of a statistic is the measurement: this
   tail is heavy, no feasible seed count bounds it, and a max-only gate on it
   is worth very little.  The two COUNTS are what carry that bench.
3. **Two thresholds have no resolution left at all, and widening them is
   therefore the honest move.**  `mutate_rmsnorm_bf.sh`'s `ACC_GAIN` would have
   to sit below 7.953e-05 to catch mutation B5 and above 7.759e-05 to clear an
   honest seed -- a 2.5% window.  `mutate_gdn_scalar.sh`'s `EG_N100_TOL` would
   have to sit below 20 to catch mutation B3 and above 20 to clear an honest
   seed -- a window of zero.  Both mutations are killed by the corresponding
   BENCH gate with margin, so nothing is lost, but neither figure can ever be
   made load bearing again.

**Retuned, each measured both ways** (section 6 carries the raw output):
`tb_gdn_recur.vhd` `TOL_S` 24.0 -> 48.0; `tb_gdn_recur_pipe.vhd` `TOL_S`
12.0 -> 48.0 and `TOL_O` 1.0e-4 -> 1.2e-3, plus the two counts and the floor
PORTED from `tb_gdn_recur` because that bench had neither;
`tb_rmsnorm_bf.vhd` `ACC_NEAR_MAX` 800 -> 1300; `mutate_rmsnorm_bf.sh`
`ACC_LSB` 1.0 -> 20.0 and `ACC_GAIN` 3.0e-5 -> 1.2e-4; `mutate_gdn_silu.sh`
`ACC_LSB` 2.0 -> 3.5; `mutate_gdn_scalar.sh` `EG_N100_TOL` 17 -> 30;
`mutate_gdn_recur.sh` `AGG_WS` 24.0 -> 48.0.

**A separate reporting defect, fixed:** `sim/mutate_gdn_recur.sh` declared
`SEED="${SEED:-20260825}"`, advertised `SEED=<n>` in its usage block and
printed `seed $SEED` in its header, but `ref/gdn_recur_vec.c` takes no seed
argument and the script never passed it one.  `SEED=42 bash
sim/mutate_gdn_recur.sh` ran the committed seed and reported seed 42.  The
knob is removed and the header now says where the seed actually lives.

**Part 2's three item-11 units (`gdn_head_emit`, `gdn_y_emit`,
`gdn_emit_chain`) were NOT given bench gates.**  They were measured, and the
measurement is in section 4: their generator-side bounds are clean at 0 of 40
seeds.  Section 8 says why the blind spots documented in section 7 of
`2026-08-29_b-verification-defects-d1-d3.md` are still open and what answering
them would take.

## 3. The procedure, in the order it was run

### 3.1 Enumerate before measuring

Three greps, each over a named file set, so the next person can tell whether
anything was missed:

```
# (a) harness-side constants
grep -nE '^[A-Z_0-9]+="\$\{[A-Z_0-9]+:-' sim/mutate_gdn_*.sh sim/mutate_rmsnorm_bf.sh
# (b) bench-side generics and constants
grep -nE '^\s*(constant|  *)[A-Za-z_]*(TOL|LSB|EPS|MAX|MIN|NEAR|CHECK|THRESH)[A-Za-z_0-9]*\s*:' \
     sim/tb_gdn_*.vhd sim/tb_rmsnorm_bf.vhd sim/tb_l2norm_rs.vhd
# (c) generator-side exit-code bounds
grep -nE 'FAIL|exit\(1\)|tol|TOL|worst' ref/gdn_*_vec.c ref/l2norm_rs_vec.c ref/rmsnorm_bf_vec.c
```

Plus one negative check, because a bench with no tolerance is a real answer and
not a gap: `grep -nE 'assert|severity (error|failure)'` over
`tb_gdn_emit_chain`, `tb_gdn_head_emit`, `tb_gdn_y_emit`, `tb_gdn_block`,
`tb_gdn_exp_capture`, `tb_gdn_conv_cycles` and `tb_gdn_conv_tvalid_skew`
confirms all seven are BIT-EXACT ONLY and carry no accuracy threshold.

**What this enumeration cannot see, stated so the next person does not assume
otherwise:** a magic number written inline in a comparison rather than as a
named constant or generic.  Every threshold found here is named, and the
negative check above covers the benches that have none, but a bare `if err >
0.75 then` inside a bench body would have been missed by (b).

### 3.2 Make each generator take a seed, and PROVE the copy is faithful first

`gdn_silu_vec`, `rmsnorm_bf_vec` and `l2norm_rs_vec` already take a seed on the
command line.  The other six do not, so a copy of each was patched in the
scratchpad -- never in the tree, `ref/**` belongs to TRACK REF9B -- to read
`VSEED` from the environment, defaulting to the same literal:

```
python3 patch_seed.py ref/gdn_conv_vec.c       $S/gen/gdn_conv_vec.c       literal 'rs_ = 20260826ULL;'
python3 patch_seed.py ref/gdn_recur_vec.c      $S/gen/gdn_recur_vec.c      literal 'rs_ = 20260825ULL;'
python3 patch_seed.py ref/gdn_scalar_vec.c     $S/gen/gdn_scalar_vec.c     literal 'uint64_t st = 0x9E3779B97F4A7C15ULL;'
python3 patch_seed.py ref/gdn_head_emit_vec.c  $S/gen/gdn_head_emit_vec.c  inmain rs
python3 patch_seed.py ref/gdn_y_emit_vec.c     $S/gen/gdn_y_emit_vec.c     inmain rs
python3 patch_seed.py ref/gdn_emit_chain_vec.c $S/gen/gdn_emit_chain_vec.c inmain crs
```

**The faithfulness check ran BEFORE any sweep**, per B-RECUR's method, and it
is the step that makes everything after it worth reading (raw output in 5.1):
each patched generator was run with no `VSEED` set and its output compared byte
for byte against both the pristine generator's output and the committed vector
in `sim/`.

### 3.3 Sweep, cheapest class first

- **Generator-side figures** need no simulator: build the generator, run it at
  N seeds, read the figure off stderr.  40 seeds each, seconds per unit.
- **Bench-side figures** need `ghdl -r`.  Rather than re-deriving each bench's
  analysis order, `sim/regress.sh --only <tb> --keep` was run once per bench
  with `REGRESS_SCRATCH` pointed at the scratchpad, and its GHDL work library
  and run directory were then REUSED: the sweep replaces one vector file and
  re-runs `ghdl -r` against the already-analysed library.  40 seeds for the
  cheap benches, 30 for `tb_gdn_recur` / `tb_gdn_recur_pipe`.

### 3.4 For every retune, measure BOTH ways

Widening a threshold until it stops firing is not a fix if it also stops
killing.  Each mutation harness was run at the committed thresholds first, its
per-mutation figures captured, and re-run at the proposed thresholds; the kill
ratio is compared, and the per-row figures say WHICH row would have been lost
and what else still kills it.

## 4. The evidence: every threshold, with its committed percentile

Seeds are the same list throughout, minus per-unit shape differences:
`20260826 20260827 1 2 3 5 7 11 13 17 42 99 123 256 512 999 1234 4242 31337
65537 123456 777777 20260101 20260829 20261231 88888 31415926 27182818 161803
1414213 20250101 20240229 500009 700001 900007 1000003 1100011 1200007 1300009
1400017`.  The `tb_gdn_recur` pair used the first 30 with 20260825 in place of
20260826.

### 4.1 Bench-side, i.e. thresholds `sim/regress.sh` can actually fail

MEASURED, `ghdl -r` per seed.  "committed pct" is the committed seed's
percentile within the honest range.

```
threshold                                committed     pct   honest range              gate      false-red
tb_gdn_conv        TOL                    0.5           15   0.499995 .. 0.50004       0.75      0/40
tb_l2norm_rs       TOL                    0.497589      32   0.497589 .. 0.499956      0.75      0/40
tb_gdn_silu        ACC_MAXLSB_M/1000      1.84416        5   1.81583 .. 2.72712        3.5       0/40
tb_gdn_silu        ACC_NEAR_MAX          14             30   2 .. 46                   60        0/40
tb_gdn_silu        ACC_MEAN_M/1000        0.118579      20   0.111571 .. 0.150466      0.2       0/40
tb_gdn_silu        ACC_MIN_CHECK      32768            n/a   32768 .. 32768 (flat)     32768     0/40
tb_rmsnorm_bf      ACC_MAXLSB_M/1000      0.770359       2   0.770359 .. 12.0688       20.0      0/40
tb_rmsnorm_bf      ACC_NEAR_MAX          49              2   49 .. 866                 800       2/40  <-- FIRES
tb_rmsnorm_bf      ACC_MEAN_M/1000        0.210763       2   0.210763 .. 0.283413      0.3       0/40
tb_rmsnorm_bf      ACC_MIN_CHECK      24960            n/a   24960 .. 24960 (flat)     24000     0/40
tb_gdn_scalar      EG_TOL                15.3271       >95   12.0467 .. 15.7106        23.0      0/40
tb_gdn_scalar      BETA_TOL               3.0880        35   2.64274 .. 3.67869        4.65      0/40
tb_gdn_scalar      EG_N1_TOL             67             62   50 .. 75                  100       0/40
tb_gdn_scalar      MIN_IN_DOMAIN        259             35   254 .. 266 (floor)        250       0/40
tb_gdn_recur       TOL_S                  8.955         73   2.6825 .. 32.1217         24.0      1/30  <-- FIRES
tb_gdn_recur       TOL_O                  6.578e-05     80   1.008e-05 .. 2.205e-04    1.2e-3    0/30
tb_gdn_recur       N_GT1_MAX             29             63   12 .. 44                  66        0/30
tb_gdn_recur       N_GT4_MAX              1             63   0 .. 3                    12        0/30
tb_gdn_recur       N_MIN                274             50   271 .. 280 (floor)        240       0/30
tb_gdn_recur_pipe  TOL_S                  8.955         73   2.6825 .. 32.1217         12.0      5/30  <-- FIRES
tb_gdn_recur_pipe  TOL_O                  6.578e-05     80   1.008e-05 .. 2.205e-04    1.0e-4    2/30  <-- FIRES
```

`tb_gdn_scalar`'s row needs a caveat, and it is a measurement trap: its
generator seeds a splitmix state with the literal `0x9E3779B97F4A7C15`, so
`VSEED=20260826` is NOT the committed point the way it is for the other five.
The committed figures above are from a separate default-seed run, and the
percentile is that value's rank within the 40 swept seeds.

### 4.2 Harness-side, i.e. thresholds only `sim/mutate_*.sh` applies

MEASURED.  `ACC_GAIN` / `ACC_LSB` / `ACC_REL` / the `AGG_*` triple / the
`gdn_scalar` triple are all computed from the generator's stderr or from the
vector file's own oracle columns, so these needed no simulator.

```
threshold                                committed     pct   honest range              gate      false-red
mutate_rmsnorm_bf  ACC_LSB                0.7704         2   0.7704 .. 12.0688         1.0       39/40 <-- FIRES
mutate_rmsnorm_bf  ACC_GAIN               1.8019e-05    18   8.028e-06 .. 7.7593e-05   3.0e-5    23/40 <-- FIRES
mutate_gdn_silu    ACC_LSB                1.8442         5   1.8158 .. 2.7271          2.0       33/40 <-- FIRES
mutate_gdn_silu    ACC_REL                4.9488e-02    95   4.1592e-02 .. 4.9710e-02  5.5e-2    0/40
mutate_gdn_emit_chain ACC_LSB (NB=2)      1.1280        20   1.0243 .. 1.5663          2.5       0/40
mutate_gdn_recur   AGG_WS                 8.955         72   1.498 .. 32.12            24.0      1/40  <-- FIRES
mutate_gdn_recur   AGG_MED                0.577         15   0.5303 .. 0.6362          0.90      0/40
mutate_gdn_recur   AGG_N1                29             65   12 .. 44                  66        0/40
mutate_gdn_scalar  BETA_TOL               3.0880        35   2.6427 .. 3.6787          4.0       0/40
mutate_gdn_scalar  EG_MED_TOL             0.0553        55   0.0196 .. 0.0928          0.10      0/40
mutate_gdn_scalar  EG_N100_TOL           17             90   12 .. 20                  17        4/40  <-- FIRES
```

`sim/mutate_gdn_conv.sh`, `sim/mutate_gdn_head_emit.sh`,
`sim/mutate_gdn_y_emit.sh` and `sim/mutate_gdn_exp_capture.sh` declare NO
accuracy threshold of their own; they report the bench's or the generator's.
That is a clean row, not a gap.

### 4.3 Generator-side, i.e. bounds in a `ref/` exit code

MEASURED, 40 seeds each, no simulator.  These are the three units section 7 of
the D1-D3 document lists as gating in the generator, which `sim/regress.sh`
never runs.

```
threshold                                committed     honest range              gate     false-red
ref/gdn_head_emit_vec.c  worst_rel        0.5000        0.5000 .. 0.5000 (flat)   1.0      0/40
ref/gdn_y_emit_vec.c     worst            0.7500        0.7500 .. 0.7500 (flat)   1.0      0/40
ref/gdn_emit_chain_vec.c worst (NB=6)     1.5300        1.1313 .. 1.6995          8.0      0/40
ref/gdn_emit_chain_vec.c worst (NB=3)     1.2057        1.0243 .. 1.5663          8.0      0/40
```

The first two are DERIVED bounds (alignment floor `< 2^-sh` plus a requantize
round `<= 0.5`, so `< 1.0` always) rather than fitted baselines, and they
behave like it: dead flat across 40 seeds.  That flatness is also the warning.
A statistic that does not move cannot report a distribution shift, and the D1-D3
document already records a `gdn_y_emit` mutation landing on exactly 1.0.  These
two bounds are honest and nearly blind at the same time.

### 4.4 Documented margin versus real margin

The gap between what a file claims and what the sweep says.

```
threshold                      documented                             real
mutate_rmsnorm_bf ACC_LSB      "BASELINES with headroom"              -12x (honest max 12.07 vs gate 1.0)
mutate_rmsnorm_bf ACC_GAIN     "BASELINES with headroom"              -2.6x (7.76e-5 vs 3.0e-5)
mutate_gdn_silu   ACC_LSB      "the gate sits just above each"        -1.4x (2.727 vs 2.0)
mutate_gdn_silu   ACC_REL      "so a mutation ... is caught"          1.11x
mutate_gdn_scalar EG_N100_TOL  "# baseline 17"                        0.85x (honest max 20 vs gate 17)
mutate_gdn_scalar BETA_TOL     "MEASURED baselines with headroom"     1.09x
mutate_gdn_scalar EG_MED_TOL   "MEASURED baselines with headroom"     1.08x
tb_gdn_scalar     EG_TOL       "1.5x the MEASURED in-domain worst"    1.46x
tb_gdn_scalar     BETA_TOL     "1.5x the MEASURED worst"              1.26x
tb_gdn_scalar     EG_N1_TOL    "1.5x the measured 67"                 1.33x
tb_gdn_recur      TOL_S        "52-seed max 15.429, 1.56x"            0.75x (30-seed max 32.12)
tb_gdn_recur      TOL_O        "52-seed max 7.942e-04, 1.51x"         5.44x
tb_gdn_recur      N_GT1_MAX    "52-seed maxima 44"                    1.50x
tb_gdn_recur_pipe TOL_S        "the SAME values as tb_gdn_recur's"    0.37x, and NOT the same values
tb_gdn_recur_pipe TOL_O        "the SAME values as tb_gdn_recur's"    0.45x, and NOT the same values
tb_rmsnorm_bf     ACC_NEAR_MAX "honest worst 465"                     0.92x (40-seed max 866)
tb_rmsnorm_bf     ACC_MAXLSB_M "honest worst 9.999"                   1.66x (40-seed max 12.07)
tb_gdn_silu       ACC_MAXLSB_M "honest worst 2.621"                   1.28x (40-seed max 2.727)
tb_gdn_silu       ACC_NEAR_MAX "honest worst 45"                      1.30x (40-seed max 46)
tb_gdn_conv       TOL          bench's own 0.75 on a derived 0.5      1.50x
tb_l2norm_rs      TOL          0.75 on a derived 0.5                  1.50x
```

**The pattern across the whole table:** every threshold set as "1.5x a measured
maximum" survived a wider sweep, and every threshold set as "just above the
committed value" did not.  The two that were retuned TODAY from a 9-seed and a
52-seed sweep both moved again at 40 and 30 seeds respectively -- by 1.9x on
`rmsnorm_bf`'s count and 2.08x on `gdn_recur`'s state maximum -- which says
that even a careful multi-seed calibration buys margin, not a bound.

## 5. Raw captured output

### 5.1 The faithfulness check, before any sweep

```
=== patched-vs-orig at default seed
IDENTICAL gdn_conv_vec.txt
IDENTICAL gdn_emit_chain_vec.txt
IDENTICAL gdn_head_emit_vec.txt
IDENTICAL gdn_scalar_vec.txt
IDENTICAL gdn_y_emit_vec.txt
IDENTICAL patched-vs-orig gdn_recur_vec.txt
=== patched-vs-COMMITTED tree vectors
IDENTICAL-to-tree gdn_conv_vec.txt
IDENTICAL-to-tree gdn_recur_vec.txt
IDENTICAL-to-tree gdn_scalar_vec.txt
IDENTICAL-to-tree gdn_head_emit_vec.txt
IDENTICAL-to-tree gdn_y_emit_vec.txt
DIFFERS-from-tree gdn_emit_chain_vec.txt
```

The last line is not a failure of the patch and is worth recording on its own:
`sim/gdn_emit_chain_vec.txt` is committed at `NB=6` (its header reads
`6 24 128`) while `sim/regress.sh`'s `tb_vector_args` row for it is `3 24 128`,
so the gate REGENERATES it at three blocks and the committed six-block file is
what `sim/mutate_gdn_emit_chain.sh` reads at its own default of `NB=2`.  Three
different shapes, one filename.  Nothing is wrong, but the generator's header
comment quotes the NB=3 and NB=6 figures while the harness runs NB=2.

### 5.2 The seeds that fire, named

```
===== tb_gdn_recur (TOL_S 24.0, TOL_O 1.2e-3)
 SEED 20260101 -> case 300: OUT OF TOLERANCE vs ORACLE in 38 state element(s), o rel err 1.227e-04
===== tb_gdn_recur_pipe (TOL_S 12.0, TOL_O 1.0e-4)
 SEED 17       -> column 230: OUT OF TOLERANCE vs ORACLE in 22 state element(s), o rel err 2.405e-06
 SEED 99       -> column 284: OUT OF TOLERANCE vs ORACLE in 57 state element(s), o rel err 1.953e-05
 SEED 777777   -> column 276: OUT OF TOLERANCE vs ORACLE in 19 state element(s), o rel err 2.436e-05
 SEED 20260101 -> column 300: OUT OF TOLERANCE vs ORACLE in 82 state element(s), o rel err 1.227e-04
 SEED 31415926 -> column 288: OUT OF TOLERANCE vs ORACLE in 28 state element(s), o rel err 2.205e-04
===== tb_rmsnorm_bf (ACC_NEAR_MAX 800)
 SEED 99       -> OUT OF TOLERANCE -- 819 elements past 5.0e-1 LSB, cap is 800.
 SEED 20240229 -> OUT OF TOLERANCE -- 866 elements past 5.0e-1 LSB, cap is 800.
```

### 5.3 The two benches print the same figures, digit for digit

This is what licenses carrying one distribution across both, and it is why the
`tb_gdn_recur_pipe` comment's claim of a single standard was checkable:

```
tb_gdn_recur      seed 20260825: worst ... 8.955004673607618 state LSB and 6.577674348402551e-5
tb_gdn_recur_pipe seed 20260825: worst 8.955004673607618 state LSB (TOL_S 1.2e1) and 6.577674348402551e-5
tb_gdn_recur      seed 2:        worst ... 3.7255390322716266 state LSB and 1.0681937993922309e-5
tb_gdn_recur_pipe seed 2:        worst 3.7255390322716266 state LSB (TOL_S 1.2e1) and 1.0681937993922309e-5
```

### 5.4 The honest distributions, as computed

```
== tb_gdn_silu n=40, gate fires on honest at 0
  worst LSB (ACC_MAXLSB 3.5)   n=40 min=1.81583   max=2.72712   median=2.27675   fires=0
  count>1.5 (ACC_NEAR_MAX 60)  n=40 min=2         max=46        median=22        fires=0
  nchecked (MIN_CHECK 32768)   n=40 min=32768     max=32768     median=32768
  mean LSB (ACC_MEAN 0.200)    n=40 min=0.111571  max=0.150466  median=0.127317  fires=0

== tb_rmsnorm_bf n=40, bench gate fires on honest at 2
  worst LSB (ACC_MAXLSB 20.0)  n=40 min=0.770359  max=12.0688   median=5.19026   fires=0
  count>0.5 (ACC_NEAR_MAX 800) n=40 min=49        max=866       median=450       fires=2
  nchecked (MIN_CHECK 24000)   n=40 min=24960     max=24960     median=24960     fires=0
  mean LSB (ACC_MEAN 0.300)    n=40 min=0.210763  max=0.283413  median=0.227374  fires=0

== tb_gdn_recur / tb_gdn_recur_pipe n=30
  worst state LSB   min=2.6825      max=32.1217    median=5.26515   >12.0: 5   >24.0: 1
  worst out rel     min=1.00818e-05 max=2.20498e-4 median=3.53442e-5 >1.0e-4: 2  >1.2e-3: 0
  n>1LSB            min=12          max=44         median=27        gate 66: 0
  n>4LSB            min=0           max=3          median=1         gate 12: 0
  columns checked   min=271         max=280        median=275       floor 240: 0

== mutate-side generator figures, 40 seeds
  mutate_gdn_silu ACC_LSB      thr=2.0     fires 33/40 (82%)  worst=2.7271
  mutate_gdn_silu ACC_REL      thr=0.055   fires  0/40  (0%)  worst=0.04971
  mutate_rmsnorm_bf ACC_GAIN   thr=3e-05   fires 23/40 (58%)  worst=7.7593e-05
  mutate_rmsnorm_bf ACC_LSB    thr=1.0     fires 39/40 (98%)  worst=12.0688
  mutate_gdn_scalar AGG-style: med thr=0.10 fires 0/40, n100 thr=17 fires 4/40, beta thr=4.0 fires 0/40
  mutate_gdn_recur  AGG_WS 24.0 fires 1/40, AGG_MED 0.90 fires 0/40, AGG_N1 66 fires 0/40
```

### 5.5 Mutation kill ratios, before and after the retune

Same harness, same tree, committed thresholds versus retuned thresholds.  The
only difference between the two columns is the threshold values.

```
harness                     BEFORE                                  AFTER
sim/mutate_rmsnorm_bf.sh    18 killed, 6 survived, of 24            18 killed, 6 survived, of 24
sim/mutate_gdn_silu.sh      15 killed, 4 survived, of 19            15 killed, 4 survived, of 19
sim/mutate_gdn_scalar.sh    15 killed, 4 survived, of 19            15 killed, 4 survived, of 19
sim/mutate_gdn_recur.sh     24 killed (0 by ABORT), 9 of 33         24 killed (0 by ABORT), 9 of 33
```

**Unchanged on all four.**  Which rows changed COLUMN rather than verdict, read
off the per-mutation figures in the BEFORE run:

```
row  figure that moved out of the widened gate      what still kills it
B5   mutate_rmsnorm_bf ACC_GAIN 7.953e-05 < 1.2e-4  bench count, 2572 vs cap 1300
B6   mutate_rmsnorm_bf ACC_LSB  1.3440    < 20.0    bench mean, 0.4027 vs 0.300
C2   mutate_gdn_silu   ACC_LSB  2.7431    < 3.5     bit-exactness, 2041 mismatches
B1   mutate_gdn_scalar EG_N100  23        < 30      bench EG_TOL, eg_in 19046 vs 23.0
B2   mutate_gdn_scalar EG_N100  25        < 30      bench EG_TOL, eg_in 26491 vs 23.0
B3   mutate_gdn_scalar EG_N100  20        < 30      bench EG_TOL, eg_in 352.7 vs 23.0
```

### 5.6 The honest seed sweep, re-run at the retuned thresholds

```
recur_after.log          n=30  fired=0
recurpipe_after.log      n=30  fired=0
rms_after.log            n=40  fired=0
```

Was 1/30, 5/30 and 2/40 respectively.

### 5.7 Teeth check on the counts PORTED into `tb_gdn_recur_pipe`

A gate added and never shown to fail has not been shown to work, so the port
was checked against a real BOTH-class defect rather than against a lowered
generic: `rtl/gdn_recur_pipe.vhd`'s final-requantize bias
(`par2(sc2(0).c.slot).bias <= shift_left(to_signed(1, 35), p - 15);` ->
`(others => '0')`) AND the matching line in `ref/gdn_recur_vec.c`
(`round_shift` -> `floor_shr`), which is the `gdn_recur_pipe` analogue of
`sim/mutate_gdn_recur.sh`'s row B3.  Bit-exactness stays green by
construction, so only the oracle can see it.

```
--- WITH the ported counts (working tree)
sim/tb_gdn_recur_pipe.vhd:341:5:(assertion error): gdn_recur_pipe: 199 physical
  columns are past 1 state LSB, over the gate of 66. ...
sim/tb_gdn_recur_pipe.vhd:358:5:(report note): gdn_recur_pipe: columns past
  1 LSB 199 (gate 66), past 4 LSB 1 (gate 12), columns checked 274 (floor 240)

--- CONTROL: the same mutant, the same vectors, HEAD's tb_gdn_recur_pipe
tb_head.vhd:304:7:(report note): gdn_recur_pipe: within the oracle bounds on all
  274 physically realizable columns -- worst 9.269675397204992 state LSB
  (TOL_S 1.2e1) and 6.65712233629025e-5 ... (TOL_O 1.0e-4) ...
tb_head.vhd:316:7:(report note): gdn_recur_pipe: bit-identical to the reference
  on all 384 columns; ...
assertion/report errors in the control run: 0
```

The control is the load-bearing half.  HEAD's bench passes this mutation
CLEANLY -- and note the state figure it prints, 9.2697, is inside `TOL_S` at
12.0 and would be inside it at any value that also clears the honest 32.12, so
this defect was invisible to that bench at every honest tolerance.  It is the
count, not the bound, that sees it.

## 6. Measured and REJECTED -- do not retry

- **Do NOT tighten `sim/mutate_rmsnorm_bf.sh`'s `ACC_GAIN` back below
  1.2e-4.**  MEASURED: mutation B5 (one Newton iteration instead of two, in
  both) reads 7.953e-05 and the honest 40-seed maximum is 7.759e-05.  Any value
  that catches B5 fires on honest seeds.  B5 is killed by the bench's count
  (2572 against a cap of 1300), which is where its detection now lives.
- **Do NOT restore `sim/mutate_gdn_scalar.sh`'s `EG_N100_TOL = 17`.**  MEASURED:
  honest range 12 to 20, mutation B3 reads exactly 20.  The separation is zero,
  in the strict sense that no integer threshold exists that clears the honest
  range and catches B3.  B1, B2 and B3 are all killed by the bench gate
  (`eg_in` 19046, 26491 and 352.7 against 23.0), so the figure was already
  redundant at 17 and only contributed a 10% false-red rate.
- **Do NOT widen `sim/mutate_gdn_silu.sh`'s `ACC_REL` past 5.5e-2**, even
  though 1.11x looks uncomfortably thin.  MEASURED: it is the ONLY remaining
  detection of mutation B4 once `ACC_LSB` moves to 3.5, and B4 reads 5.7289e-2,
  15% above the honest maximum.  Widening it deletes a kill.
- **Do NOT treat a max-only bound on `gdn_recur`'s state error as calibratable
  by more seeds.**  MEASURED twice: 52 seeds gave a maximum of 15.429, 30
  different seeds gave 32.122.  The estimate moved 2.08x when the seed count
  went DOWN, which is the signature of a tail that no sample size will pin.
  The two counts, `N_GT1_MAX` and `N_GT4_MAX`, are stable (44 and 3 against 44
  and 5 from the 52-seed sweep) and are the gates to trust.
- **Do NOT add a bench-side accuracy gate to `gdn_head_emit` or `gdn_y_emit`
  by porting the four-figure recipe verbatim.**  Their oracle EXCLUDES a case
  when any element saturated, and the D1-D3 measurement is that at a narrowed
  rail 41 of 48 `y_emit` cases saturate and 7 are all-zero, i.e. 48 of 48: the
  oracle empties rather than loosens.  A floor makes that loud, but a floor
  alone does not give the max anything to measure -- see section 8.
- **Do NOT read `sim/mutate_gdn_recur.sh`'s old `SEED` variable as evidence
  that anything was ever swept through it.**  It was inert.  Any historical
  claim of the form "measured at SEED=n via the harness" is a claim about the
  committed seed.

## 7. Measurement traps hit, including my own

1. **`VSEED` is not the committed seed for `gdn_scalar`.**  Five of the six
   patched generators seed a variable whose literal IS the committed seed, so
   `VSEED=<that literal>` reproduces the committed vectors exactly.
   `gdn_scalar_vec.c` seeds a splitmix state with `0x9E3779B97F4A7C15`, so
   `VSEED=20260826` is an ordinary sweep point and NOT the committed one.  The
   first pass of the `gdn_scalar` table quietly reported a "committed" value of
   13.389 against the real 15.3271 for exactly this reason.  The committed
   figures in 4.1 come from a separate no-`VSEED` run.
2. **A bench that reports a per-case error at severity `error` still prints its
   summary.**  `tb_gdn_recur` at seed 20260101 fired the gate AND printed the
   summary line, so a sweep that counts "seeds with a parsed summary" reports
   30 of 30 and misses the failure entirely.  `tb_gdn_recur_pipe` does the
   opposite -- its summary sits behind `nfail = 0 and ntol = 0`, so a fired
   seed produces no figure at all and the parse silently drops it.  **Two
   benches on one recipe, opposite reporting conventions, and the naive parse
   is wrong on both.**  The counts in 4.1 come from matching the failure text,
   not from the absence of a summary.
3. **`ref/gdn_recur_vec.c` opens `ref/gdn_eg_qwen3_27b.txt` by a path relative
   to the cwd** and `exit(1)`s if it is not there, printing one line to stderr.
   The first faithfulness run produced no vector file at all and the comparison
   reported `DIFFER`, which reads as "the patch changed the output" and is
   actually "there is no output".  A `cmp` against a nonexistent file is not a
   measurement.  Fixed by symlinking `ref` into each run directory.
4. **`ghdl -a` on the retuned benches emits `warning: type of a shared variable
   must be a protected type` for every shared variable.**  Pre-existing, on
   every bench in this set, and not caused by the edits.  Do not chase it.
5. **My own seed list is not independent of the units.**  The same 40 integers
   were used for every unit, so a pathological value would show up everywhere
   at once rather than in one row.  Nothing in the results looks like that --
   the firing seeds differ per unit (99 and 20240229 for `rmsnorm_bf`; 17, 99,
   777777, 20260101, 31415926 for `gdn_recur_pipe`) -- but it is not something
   this study controlled for.

## 8. Open, NOT verified

Stated as a list rather than folded into prose, because these are the parts a
reader would otherwise assume were covered.

- **A seed sweep varies the STIMULUS DISTRIBUTION, not the RECIPE.**  Every
  number in this document is the honest unit's error under a different draw
  from the SAME generator's shape mix.  It says nothing about what happens if
  the shape mix itself changes -- `NCASE`, `N`, `DIM`, `HEADS`, `SP_Q`, `ARG_Q`,
  `Q`, `EPS`, `NB` -- and several of the thresholds audited here are ABSOLUTE
  COUNTS at a committed shape (`ACC_NEAR_MAX`, `ACC_MIN_CHECK`, `EG_N1_TOL`,
  `N_GT1_MAX`, `AGG_N1`), so changing a shape changes what they mean.  NOT
  verified at any other shape.
- **`gdn_head_emit`, `gdn_y_emit` and `gdn_emit_chain` still have no gate
  `sim/regress.sh` can fail.**  Their generator bounds are clean (4.3) but the
  gate never runs the generator.  This track deliberately did not add bench
  gates, and the reason is the blind spot, not the effort: for the first two,
  the oracle's exclusion is on an OUTPUT property, so the honest max is dead
  flat at 0.5000 and 0.7500 across 40 seeds and a max-gate on it would be a
  gate on a constant.  The piece that would make it real is a floor on the
  number of ELEMENTS entering the oracle -- `tb_gdn_scalar`'s `MIN_IN_DOMAIN`
  and `tb_rmsnorm_bf`'s `ACC_MIN_CHECK` are the working precedents -- plus a
  count and a mean, which is the four-figure recipe B-GATE established.  For
  `gdn_emit_chain` the metric is normalised by the output grid that one BOTH
  mutation changes and moved the WRONG WAY (1.1280 -> 0.8505); that needs an
  absolute-unit error or a separate assertion on `y_exp`, which is a change to
  WHAT is measured.  NOT done, NOT estimated in cost beyond B-GATE's measured
  "about 60 lines of bench and half a day per unit".
- **`ref/gdn_recur_vec.c` genuinely wants a seed argument**, the way
  `gdn_silu_vec.c` and `rmsnorm_bf_vec.c` already have one.  Every sweep of
  that unit -- B-RECUR's 52 seeds and this track's 30 -- has gone through a
  patched scratch copy, twice now.  `ref/**` is TRACK REF9B's, so this is
  reported and not done.  The same applies to `gdn_conv_vec.c`,
  `gdn_scalar_vec.c`, `gdn_head_emit_vec.c`, `gdn_y_emit_vec.c` and
  `gdn_emit_chain_vec.c`.
- **Whether `gdn_recur`'s 32.12 LSB at seed 20260101 is purely the stimulus or
  is telling us something about the recipe was NOT investigated.**  B-RECUR
  root-caused the committed seed's 8.955 to stage 3's alignment floor and
  explicitly not to the `d_m` grid; whether the same mechanism scales to 32.12
  is unexamined here.  The retune assumes it does.
- **The `l2norm_rs` and `gdn_conv` bounds were swept but their DERIVATION was
  not re-checked.**  Both sit at 0.75 against a metric pinned near 0.5 by a
  half-LSB rounding argument.  0/40 is a real measurement; "0.75 is the right
  number" is not something this study establishes.
- **No claim is made about subsystems A, C, D or E.**  The enumeration greps
  were scoped to subsystem B's files.  `sim/mutate_attn_*.sh` and
  `sim/mutate_seq_*.sh` carry thresholds of their own and were NOT audited.

## 9. Corrections

**2026-08-29, appended the same day, arithmetic in section 2.**  The first
version of this document, and commit `81297ee`'s message with it, said
"twenty-six accuracy thresholds exist" and "the other seventeen are clean".
**Twenty-six is the count of CLEAN thresholds, not the total.**  The total is
THIRTY-FIVE: 21 bench-side (4.1), 11 harness-side (4.2) and 3 generator-side
(4.3), of which NINE fire on the honest unit.  Section 2 is corrected in place
above; the commit message cannot be and is wrong on this one number.  Nothing
else changes -- the nine firing rows, their false-red rates and every retune
are as measured, and the per-threshold tables in section 4 were always the
authoritative list.
