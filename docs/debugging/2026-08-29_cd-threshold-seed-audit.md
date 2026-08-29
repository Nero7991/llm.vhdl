# Subsystems C and D: every accuracy threshold against its honest seed range

Date: 2026-08-29.  Repo `llama.vhdl`, branch `fpga`.
Simulator: ghdl-mcode 1.0.0, VHDL-2008, `-frelaxed`.  No hardware involved.
Generators built with `cc -O2 -w -I ref ... -lm`, the same line `sim/regress.sh`
uses at `:985`.

Follows `docs/debugging/2026-08-29_b-threshold-seed-audit.md` (TRACK B-SEED),
whose closing note names this task verbatim.

## 1. The question

Verbatim, from the dispatch:

> Its closing note names your task verbatim:
>
> > **`sim/mutate_attn_*.sh` and `sim/mutate_seq_*.sh` were NOT audited.  Same
> > class of threshold, different subsystems.**
>
> That is subsystem C (gated attention) and subsystem D (the transformer
> sequencer).  Nobody has looked.
>
> **Part 1, the priority: audit every accuracy threshold in subsystems C and
> D.**  Enumerate first, and say how. ... For each threshold report: the
> committed seed's value and its **percentile** in the honest range, the honest
> range, the **fraction of seeds at which it fires with no defect present**, and
> the documented margin against the real one.
>
> **Report the thresholds that are FINE under their own names.**
>
> **Part 2, if Part 1 leaves room: retune what you found, measured BOTH ways.**

Plus, specific to subsystem C:

> `attn_block` is the unit that **passed seven properties and 13 of 17 wiring
> mutations while computing entirely wrong numbers** ... If you find a C
> threshold that never fires on anything, consider that the threshold may be
> measuring nothing at all, and say so.

## 2. The answer

**Sixty seed-sensitive gates exist in subsystems C and D.  ZERO of them fire on
the honest unit, at 40 stimulus seeds each.  There is nothing to retune.**

That is not the interesting half.  Three findings are:

**1. Subsystem C and D benches contain NO accuracy tolerance at all.**  Not one
`TOL`, `ACC_*`, `EPS` or `NEAR_MAX` generic or constant exists in any of the 25
`sim/tb_attn_*.vhd` / `sim/tb_seq_*.vhd` files, and not one of the 19
`sim/mutate_attn_*.sh` / `sim/mutate_seq_*.sh` / `sim/mutate_ref_*.sh`
harnesses declares one either.  Every C and D bench is **bit-exact against a
vector file**; the only real-typed variables in them (`to_real_s32`,
`to_real_s`) are wide-integer carriers compared with `/=`, not tolerances.  So
the defect class B-SEED found -- a fitted bound calibrated against one committed
seed -- **structurally cannot exist on the bench side here**.  All 60 gates live
in `ref/attn_*_vec.c`, `ref/seq_*_vec.c` and in two benches' coverage
assertions.

**2. C's bounds are DERIVED, not fitted, and they behave completely differently
from B's.**  Eighteen of them print a statistic as a ratio against a bound whose
gate is exactly 1.0.  The honest maxima over 40 seeds:

| bound | honest max | gate | headroom |
|---|---|---|---|
| `attn_gate` oracle 1, `\|t - o*2^14/s\| / bnd` | **1.0000** | > 1.0 | **zero** |
| `attn_score_q12` oracle 1, chain / derived | 0.9996 | > 1.0 | 0.04% |
| `attn_gate` oracle 5, chain / composed | 0.9999 | > 1.0 | 0.01% |
| `attn_softmax` oracle 2, `\|e_p - exp\| / bnd` | 0.9969 | > 1.0 | 0.31% |
| `attn_recip` oracle 4, `\|t - o*2^14/s\| / bnd` | 0.9981 | > 1.0 | 0.19% |
| `attn_emit` oracle 1, `\|y_mant - true\| / bnd` | 0.9961 | > 1.0 | 0.39% |
| `attn_rope` oracle 1, `\|y - true rot\| / bnd` | 0.9939 | > 1.0 | 0.61% |

**A derived bound the honest unit sits exactly on is the OPPOSITE of B's
problem.**  It cannot false-red -- the derivation makes `ratio <= 1` a theorem,
and the strict `>` lets equality through -- and it fires on any defect that adds
a single ulp.  These are the most sensitive gates in the tree, and the reason
none of B's retuning applies is that not one of them was fitted to a seed.

**3. The real defect in C is a different one, and it is FIXED here.**
`sim/attn_kv_quant_vec.txt` and `sim/attn_score_q12_vec.txt` are committed and
had no `tb_vector_args` row, so `sim/regress.sh:983`'s
`[ -e "$SIM/$v" ] && [ -z "$args" ] && continue` skipped generation entirely.
**MEASURED: no `gen_attn_kv_quant_vec` and no `gen_attn_score_q12_vec` binary
exists in either run directory**, while the other seven subsystem C benches all
have one.  Five checks were therefore unreachable from the gate:
`attn_kv_quant`'s 0.5-LSB residual bound, its `>= 128.0` and `< 64.0` peak
window halves, `attn_score_q12`'s whole-chain derived bound, and
`attn_score_q12`'s right/left/saturating coverage gate.  Commit `e27a9ad` adds
the two rows.  The bound is not decorative: a BOTH-class mutation that floors in
the integer path AND in the double oracle reads **0.998047 LSB against the 0.5
gate** and is invisible to every equality oracle (section 5.5).

**Found while verifying that fix, and it is the more urgent item: at 10:46
today a stray generator run with `cwd = sim/` OVERWROTE both working-tree
golden vectors** with different data (476 and 366 changed lines).  `git show
HEAD:` still matches the generator's default output byte for byte, so nothing
is lost, but before `e27a9ad` the skip above would have fed the foreign file
straight to `tb_attn_kv_quant` and `tb_attn_score_q12` without a word.  A golden
that nothing regenerates is a golden anything can replace in silence.  See
section 7 trap 2; this is an open item for whoever owns those two files.

**Two thresholds with no resolution left**, in the sense B-SEED means, i.e. the
honest value sits exactly on the gate:

- `attn_kv_quant` oracle 2's lower half, `worst_lo < 64.0`, reads **exactly
  64.0000 at 40 of 40 seeds**.
- `attn_gate` oracle 1 reads **exactly 1.0000 at 20 of 40 seeds**.

Neither is a fault.  Both are structural windows attained exactly, and both use
a strict inequality on the correct side.  But neither has any margin left to
give, and a future change that widens either bound deletes it.

**Six statistics are dead flat across 40 seeds** and therefore cannot report a
distribution shift, the same warning B-SEED recorded for `gdn_head_emit` and
`gdn_y_emit`: `attn_gate` oracle 3a (0.4992), `attn_gate` oracle 3b's exhaustive
sweep (2.0292), `attn_twiddle` oracle 1 (0.4988), `attn_kv_quant` oracle 1
(0.5000), oracle 2 max (127.9961) and oracle 2 min (64.0000).  The first three
are flat **by construction** -- they check a ROM against libm and sweep the
whole s32 domain, so they have no stimulus dependence at all -- which is the
right answer, not a blind spot.

**Nothing was retuned.**  Section 6 says why widening any of the seven bounds
above would be a deletion rather than a fix.

## 3. The procedure, in the order it was run

### 3.1 Enumerate before measuring

Four greps and one negative check, each over a named file set:

```
# (a) harness-side default-value constants
grep -nE '^[A-Z_0-9]+="?\$\{[A-Z_0-9]+:-' sim/mutate_attn_*.sh sim/mutate_seq_*.sh \
     sim/mutate_ref_attn_*.sh sim/mutate_ref_seq_*.sh
# (a2) any threshold-NAMED variable anywhere in those harnesses
grep -nE '(TOL|LSB|EPS|ACC|MAX|MIN|THRESH|MARGIN|WORST|GATE|BOUND|REL|ULP)[A-Z_0-9]*=' \
     sim/mutate_attn_*.sh sim/mutate_seq_*.sh sim/mutate_ref_*.sh
# (b) bench-side generics and constants
grep -nE '^\s*(constant|[A-Za-z_])[A-Za-z_0-9]*[^;]*\b[A-Za-z_]*(TOL|LSB|EPS|MAX|MIN|NEAR|CHECK|THRESH|MARGIN|ULP|WORST|BOUND)[A-Za-z_0-9]*\s*:' \
     sim/tb_attn_*.vhd sim/tb_seq_*.vhd
# plus every generic block read in full:
sed -n '/^ *generic *(/,/^ *) *;/p' sim/tb_attn_*.vhd sim/tb_seq_*.vhd
# (c) generator-side bounds and coverage gates
grep -nB4 'FAIL' ref/attn_*_vec.c ref/seq_*_vec.c
grep -nE '^\s*(#define|static const|const)\s+[A-Za-z_]' ref/attn_*_vec.c ref/seq_*_vec.c
```

**The negative check is the load-bearing one here**, because "no threshold" is
the answer for the entire bench side and that is a claim, not an absence of
evidence.  Three independent forms of it:

1. `grep -nE '\b(abs|real|to_real|e-[0-9]|[0-9]\.[0-9])'` over all 25 C and D
   benches returns only clock periods (`0.5 ns`), `to_real_s32` helpers, and
   comment text.  Every one of those helpers feeds a `/=`, never a `>`.
2. Reading all 25 generic blocks in full: every generic is a shape (`NCASE`,
   `HEAD_DIM`, `NBLK`), a timing knob (`ACK_LAG`, `TW_GAP`, `JOB_LAT`) or a
   mutation switch (`MUT_*`, `*_AT`).  None is a tolerance.
3. `grep -nE '\b(diff|err|delta|ulp|dev)[a-z_0-9]* *[<>]|> *[0-9]+ then'` over
   the same 25 files returns only `ACK_LAG > 0`-style timing tests and coverage
   counters.

**What this enumeration cannot see**, stated so the next person does not assume
otherwise, and it is the same blind spot B-SEED named plus two more:

- A magic number written inline in a comparison inside a bench body.  Greps (b)
  and the generic sweep would both miss `if err > 0.75 then`.  The three
  negative checks above are what cover it, and they are text searches, not
  proofs.
- A coverage counter that is GATED but never PRINTED.  Three exist and are named
  in 4.2: `attn_rope`'s `n_adj_differs`, `attn_twiddle`'s `j = max`, and
  `attn_rescale`'s `yv[0] != 0 && yv[1] != 0`.  For those the only measurement
  is the generator's exit code, so the honest range is unknown and only the
  false-red rate is established.
- Anything in `sim/tb_llama_top*`, `sim/tb_e2e`, `sim/tb_attn_block` /
  `tb_attn_kv_seam`'s SEAM properties beyond their vector comparison, and all of
  subsystems A and E.  Out of scope.

### 3.2 Make each C generator take a seed, and PROVE the copy is faithful first

`seq_vec_res_vec.c` and `seq_vec_chain_vec.c` already take a seed on the command
line, and `sim/regress.sh` pins them (`64 12345`, `250 8 20260827`).  The ten C
generators do not, so a copy of each was patched **in the scratchpad, never in
the tree** -- `ref/**` is TRACK RY-ORACLE's -- to read `VSEED` from the
environment at the top of `main`, defaulting to the same literal:

```
patch_seed.py ref/attn_recip_vec.c     $S/gen/attn_recip_vec.c     rs   # 20260830
patch_seed.py ref/attn_rope_vec.c      $S/gen/attn_rope_vec.c      rp   # 20260903
patch_seed.py ref/attn_gate_vec.c      $S/gen/attn_gate_vec.c      gs   # 20260831
patch_seed.py ref/attn_emit_vec.c      $S/gen/attn_emit_vec.c      es   # 20260901
patch_seed.py ref/attn_rescale_vec.c   $S/gen/attn_rescale_vec.c   rs   # 0x5eed5eed
patch_seed.py ref/attn_softmax_vec.c   $S/gen/attn_softmax_vec.c   rs   # 20260829
patch_seed.py ref/attn_twiddle_vec.c   $S/gen/attn_twiddle_vec.c   ts   # 20260902
patch_seed.py ref/attn_kv_quant_vec.c  $S/gen/attn_kv_quant_vec.c  rs   # 20260827
patch_seed.py ref/attn_score_q12_vec.c $S/gen/attn_score_q12_vec.c rs   # 20260828
patch_seed.py ref/attn_mac_array_vec.c $S/gen/attn_mac_array_vec.c rs   # 0xC0FFEE
```

Two files are textually included by another (`attn_recip_vec.c` into
`attn_gate_vec.c`, `attn_twiddle_vec.c` into `attn_rope_vec.c`), so the patcher
targets the file's OWN named seed variable and the include still resolves to the
pristine `ref/` copy through `-I ref`.

**The faithfulness check ran BEFORE any sweep** (raw output in 5.1): each
patched generator with no `VSEED` set, compared byte for byte against the
pristine generator's output.  All ten identical.  Then, separately, `VSEED=<the
decimal of that literal>` was checked to reproduce the pristine output, because
B-SEED's trap 1 is that this does NOT hold when the literal is a splitmix
constant rather than the seed itself.  Nine of ten reproduce; the tenth is a
measurement trap of my own and is in section 7.

### 3.3 Sweep, cheapest class first

- **Generator-side**, both classes: build, run at 40 seeds, read the statistic
  off stderr and the verdict off the exit code.  `sim/regress.sh:989` turns a
  non-zero generator exit into `VECTORGEN_RUN_FAILED` and the row into `ERROR`,
  so for the twelve vectors the gate DOES regenerate, a generator bound is a
  live gate row.  Seconds per unit.
- **Bench-side**: `sim/regress.sh --only <tb> --keep` once per bench with
  `REGRESS_SCRATCH` in the scratchpad, then the GHDL work library and run
  directory are REUSED -- the sweep replaces the one vector file and re-runs
  `ghdl -r` against the already-analysed library.  Nine benches x 40 seeds.

The seed list is B-SEED's, unchanged, so the two audits are comparable:

```
20260826 20260827 1 2 3 5 7 11 13 17 42 99 123 256 512 999 1234 4242 31337
65537 123456 777777 20260101 20260829 20261231 88888 31415926 27182818 161803
1414213 20250101 20240229 500009 700001 900007 1000003 1100011 1200007 1300009
1400017
```

## 4. The evidence: every gate, with its committed percentile

### 4.1 Generator-side numeric bounds that print a statistic (18)

MEASURED, 40 seeds each, no simulator.  "committed" is the pristine generator's
own default run; "pct" is that value's rank within the 40 swept seeds.

```
threshold                      committed pct   honest range (40 seeds)  gate      false-red
recip o4 |t-o*2^14/s|/bound    0.9952    30    0.9916 .. 0.9981         1         0/40
gate o1 |t-o*2^14/s|/bound     1         75    0.6843 .. 1              1         0/40
gate o3a SIG_ROM ulp           0.4992    50    0.4992 .. 0.4992         0.5       0/40
gate o3b exhaustive counts     2.0292    50    2.0292 .. 2.0292         2.0396    0/40
gate o3b per-case counts       1.6817    30    1.4406 .. 2.0292         2.0396    0/40
gate o5 chain/composed         0.7513    12    0.674  .. 0.9999         1         0/40
emit o1 |y_mant-true|/bound    0.9922    59    0.9845 .. 0.9961         1         0/40
softmax o1 |s-batch|/bnd       0.8394    58    0.5971 .. 0.9235         1         0/40
softmax o2 |e_p-exp|/bnd       0.9896    66    0.9497 .. 0.9969         1         0/40
twiddle o1 table ulp           0.4988    50    0.4988 .. 0.4988         0.5       0/40
twiddle o4 |v-32767t|/bnd      0.8617    72    0.844  .. 0.9046         1         0/40
twiddle o6 pythag/derived      0.7313    44    0.7313 .. 0.8007         1         0/40
rope o1 |y-true rot|/bound     0.935     61    0.8591 .. 0.9939         1         0/40
rope o2 norm/derived           0.6976    58    0.5672 .. 0.875           1         0/40
kvq o1 worst LSB               0.5       50    0.5    .. 0.5            0.5       0/40
kvq o2 peak/LSB max            127.996   50    127.996 .. 127.996       128       0/40
kvq o2 peak/LSB min            64        50    64     .. 64             64        0/40
sq12 o1 err/derived            0.9475    50    0.7426 .. 0.9996         1         0/40
```

`gate o1`'s max of 1 is not a rounding artefact of the `%.4f` print: the gate is
`ratio > 1.0` and the generator exited 0 at every seed, so the value is in
[0.99995, 1.0] and 20 of the 40 seeds print it.  The seeds that do are listed in
5.3.

`kvq o2 peak/LSB min` fires on `worst_lo < 64.0`, i.e. the false-red column is
counted in the other direction for that one row.

### 4.2 Generator-side numeric bounds with no printed statistic (8)

MEASURED as a verdict only: the generator's exit code at 40 seeds.  The honest
range is NOT established for these, which is stated rather than glossed.

```
threshold                                                        false-red
attn_recip   oracle 3, r on the correct side of 1/s (slack, +1e-18)   0/40
attn_score_q12 oracle 3, aligned sum within NBLK of the unfloored     0/40
attn_softmax oracle 3, e_p >= true_ep - 1.0                           0/40
attn_softmax batch check, |batch - s_true| > 1e-6*(batch+1)           0/40
attn_gate    oracle 3c, chord side, t30 - 1.5 / t30 + 0.5             0/40
attn_emit    oracle 4, alignment is a floor, +/- 1e-9                 0/40
attn_rope    oracle 6, rounding half toward +inf, +1e-9               0/40
attn_rescale oracle 9, operand widths hi_w<=27 lo_w<=27 f_w<=18       0/40
```

### 4.3 Generator-side coverage gates (22)

MEASURED, 40 seeds each.  A coverage gate fires when a counter it names reaches
zero, so what matters is the honest MINIMUM.  The margin column is that minimum
against the gate.

```
generator        gate                                     honest min .. max      margin
attn_recip       7 counters, all non-zero
                   s a power of two                        36 .. 56              36x
                   exact divisions                         36 .. 56              36x
                   inexact divisions                      232 .. 252            232x
                   r = 2^15 (top of the u16 window)        36 .. 56              36x
                   r = 2^14 (bottom)                       76 .. 101             76x
                   p = 11                                  47 .. 72              47x
                   p = 25                                  40 .. 61              40x
attn_rope        `pos` distinct >= 2                        8 .. 9                4x
attn_rope        every case's x distinct >= 2               2 .. 2       ZERO MARGIN
attn_rope        11 counters, all non-zero
                   saturations                            122 .. 136
                   saturations high / low                   58 .. 68 / 62 .. 72
                   pos = 0 cases                            6 (flat)              6x
                   phases wrapped                         174 .. 195
                   x neg / pos / zero              274..313 / 263..302 / 320
                   x at an s16 rail                       128 .. 129
                   non-zero tail elements                  704 (flat)
                   adjacent-pairing-would-differ          NOT PRINTED (blind)
attn_emit        oracle 5, mantissa at +32767               7 .. 9                7x
attn_emit        oracle 5, mantissa at -32768               8 .. 9                8x
attn_emit        10 counters, all non-zero
                   shp = 0 / shp > 0               11..14 / 26..29
                   shp > 8                                  5 (flat)              5x
                   amax = 0                                 5 (flat)              5x
                   grids equal / differing          8..9 / 31..32
                   aligned neg / pos       1495..1593 / 1256..1403
                   floored to -1                          150 .. 296
                   inputs at the s24 rails                485 (flat)
attn_softmax     7 counters, all non-zero
                   rescales                                71 .. 139
                   of which f = 0                           9 .. 24
                   heads with NO rescale                   12 .. 23
                   rescale at the LAST position             3 .. 17    <-- THINNEST
                   e_p = 0                                125 .. 315
                   e_p = 4096                              48 .. 193
                   scores at the s32 rail                  10 .. 102
attn_twiddle     `pos` distinct >= 2                        7 .. 8                3.5x
attn_twiddle     7 counters, all non-zero
                   pos = 0 pairs                          160 .. 192
                   frac = 0 (exact grid)                   160 .. 192
                   sin neg / cos neg                62..80 / 63..82
                   phase wrapped a whole turn              91 .. 111
                   j = max                                NOT PRINTED (blind)
attn_gate        21 counters, all non-zero
                   right / left branch              12..15 / 20..23
                   sh = 0                                   5 .. 7                5x
                   sat32                                  287 .. 290
                   zg = 0 / on-grid                502..538 / 635..764
                   low clamp / high clamp          413..495 / 386..469
                   32767 from the interpolation            73 .. 110
                   k = 0 / k = 511                  30..42 / 60..84
                   o neg / pos / zero      790..850 / 779..845 / 578..625
                   t zero                                 768 .. 825
                   y neg / pos             529..577 / 518..573
                   g_mant -32768 / +32767            210 / 210 (both flat)
                   round witnesses w1 / w2          30..42 / 30..42
attn_score_q12   3 counters, all non-zero
                   right-shift branch                      26 .. 47
                   LEFT-shift branch                       17 .. 38
                   saturating                              15 .. 30
attn_rescale     8 COV() conditions
                   o takes all three signs         256 / 192 / 64 (all flat)
                   f reaches 4096 and 0                96 / 32 (both flat)
                   negative o with non-zero low chunk >= 2 160 (flat)            80x
                   hi chunk set >= 2 / clear >= 2    416 / 96 (both flat)
                   exact ties positive >= 2 / negative >= 2  32 / 32 (flat)      16x
                   low partial carries >= 2               159 .. 160             80x
                   a case at an ACC_W rail                 64 (flat)             64x
                   y != 0 at cases 0 and 1                NOT PRINTED (blind)
seq_vec_res      7 counters, all non-zero
                   sh = 0 / sh > 0                   7..14 / 50..57
                   saturating clamp                         1 (flat)   ZERO MARGIN
                   SHMAX clamp                             25 .. 38
                   negative align shift                    25 .. 38
                   n not a multiple of 8                   40 .. 49
                   all-zero accumulator                     3 (flat)              3x
seq_vec_chain    7 counters, all non-zero
                   sh = 0                                   1 (flat)   ZERO MARGIN
                   sh > 0                                   7 (flat)
                   saturating clamp                         1 (flat)   ZERO MARGIN
                   SHMAX clamp                              2 (flat)
                   ee above ex / below ex             2 / 4 (both flat)
                   output exponent moved                    5 .. 6                5x
```

**The D generators' coverage is seed-INSENSITIVE by construction.**
`seq_vec_chain_vec.c` walks a fixed `DELTA[]` schedule and `seq_vec_res_vec.c`
enumerates case shapes deterministically, so six of seven counters do not move
at all across 40 seeds even though the seed IS live (the vector files differ:
md5 `df49ee16`, `203146b8`, `14c7a3ca`, `7b27bea1` at seeds 20260827, 1, 42,
999).  That is the opposite of an inert knob -- the stimulus varies, the shape
coverage does not -- and it means those gates cannot false-red on a seed but
also say nothing about the draw.  The three counters sitting at exactly 1 are
the ones a shape change would silently zero.

### 4.4 Bench-side coverage assertions (12)

The only seed-sensitive bench-side gates in C and D.  MEASURED with `ghdl -r`,
40 seeds.

```
bench              assertion                            honest min .. max   false-red
tb_attn_rope       cov_sat > 0        (saturating cases)   7 .. 9              0/40
tb_attn_rope       cov_nosat > 0      (clean cases)       19 .. 21             0/40
tb_attn_rope       cov_pos0 > 0                            6 (flat)            0/40
tb_attn_rope       cov_tail_nz > 0                        not printed          0/40
tb_attn_rope       cov_hi > 0 and cov_lo > 0              not printed          0/40
tb_attn_rope       cov_stall > 0      (ACK_LAG > 0)    13440 (flat)            0/40
tb_attn_rope       cov_b2b > 0        (ACK_LAG = 0)     2604 (flat)            0/40
tb_attn_rope       cov_twstall > 0    (TW_GAP > 0)      2660 (flat)            0/40
tb_attn_rescale    cov_poison_clash = 0                    0 (flat)            0/40
tb_attn_rescale    cov_poison_ok >= 2                    512 (flat)            0/40
tb_attn_rescale    cov_frozen > 0     (EN_GAP > 0)      NOT RUN BY THE GATE
tb_attn_rescale    cov_hold >= 2      (EN_GAP > 0)      NOT RUN BY THE GATE
```

The last two are guarded by `if EN_GAP > 0`, and `sim/regress.sh` has no
`tb_args` row for `tb_attn_rescale`, so the bench runs at its generic default
`EN_GAP = 0` and both asserts are skipped on every gate run.  They are NOT dead:
`sim/mutate_attn_rescale.sh` configurations A and C run `EN_GAP=3` and
`EN_GAP=11`.  MEASURED at five seeds x `EN_GAP` in {1, 3}: `cov_frozen` 512 and
1536, `cov_hold` 513 and 1537, against gates of 1 and 2.  Comfortable, and
exercised only by the mutation harness.

### 4.5 The negative check: benches that carry no threshold at all

Named, because "no threshold" is a result and a report that lists only the
gates found cannot be told from an incomplete audit.  All 25 C and D benches are
**bit-exact only**:

```
tb_attn_beh          tb_attn_block        tb_attn_cmp          tb_attn_cmp2
tb_attn_emit         tb_attn_fix_beh      tb_attn_gate         tb_attn_kv_axi
tb_attn_kv_quant     tb_attn_kv_seam      tb_attn_mac_array    tb_attn_probe_cmp
tb_attn_recip        tb_attn_replay       tb_attn_replay_beh   tb_attn_rescale
tb_attn_rope         tb_attn_score_q12    tb_attn_softmax      tb_attn_twiddle
tb_seq_desc_fetch    tb_seq_opdec         tb_seq_region_lock   tb_seq_vec_res
tb_seq_vec_seam
```

and all 19 mutation harnesses declare no accuracy threshold of their own:

```
mutate_attn_emit   mutate_attn_gate      mutate_attn_kv_axi   mutate_attn_kv_seam
mutate_attn_recip  mutate_attn_rescale   mutate_attn_rope     mutate_attn_softmax
mutate_attn_twiddle
mutate_seq_desc_fetch mutate_seq_opdec   mutate_seq_region_lock
mutate_seq_vec_issue  mutate_seq_vec_res
mutate_ref_attn_rescale mutate_ref_attn_rope mutate_ref_attn_twiddle
mutate_ref_seq_vec_chain mutate_ref_seq_vec_res
```

Four generators carry no accuracy bound and no coverage gate either -- only
shape guards that reject an illegal geometry before generating:
`ref/attn_block_vec.c`, `ref/attn_block_seq_vec.c`, `ref/attn_kv_axi_vec.c`,
`ref/attn_mac_array_vec.c`.  `attn_mac_array_vec.c`'s two `ORACLE 6` messages
are DSP-tile-fit assertions on the declared widths, not error bounds, and it
prints nothing at all on a clean run.

### 4.6 Documented margin versus real margin

The gap between what a file claims and what the sweep says.  Subsystem C's
files make far fewer numeric claims than B's, because a derived bound is stated
as a derivation rather than as a calibration.

```
threshold                      documented                                  real
attn_gate o3a                  "Half an ulp, exactly, not a tolerance"     0.4992, flat: TRUE
attn_gate o3b                  "measured worst over the whole s32 domain
                                is 2.0292, inside it [2.0396]"             2.0292 at 40/40: TRUE
attn_twiddle o1                "half is the claim"                         0.4988, flat: TRUE
attn_kv_quant o1               "> 0.5 and not >= 0.5: a tie rounds to
                                exactly half an LSB"                       0.5 at 40/40: TRUE,
                                                                           and the tie is the mode
attn_kv_quant o2               "every block's peak in [64, 128)"           127.996 / 64.000: both
                                                                           attained exactly
attn_recip o4                  "the derived bound"                         0.9981 max, 1.002x
attn_gate o1                   "the derived bound"                         1.0000 max, 1.000x
attn_gate o5                   "composed bound"                            0.9999 max, 1.000x
attn_emit o1                   "the derived bound"                         0.9961 max, 1.004x
attn_softmax o2                "the interpolation bound"                   0.9969 max, 1.003x
attn_score_q12 o1              "NBLK alignment floors plus one Q12 round"  0.9996 max, 1.000x
attn_rope o1                   "the derived bound"                         0.9939 max, 1.006x
attn_twiddle o4                "ea(W) + eb(chord) + ec(table+floor)"       0.9046 max, 1.105x
attn_rope o2                   "the orthogonality bound"                   0.8750 max, 1.143x
attn_softmax o1                "a batch double sum"                        0.9235 max, 1.083x
seq_vec_res coverage           "Any zero below is a hole"                  three counters sit at 1 or 3
seq_vec_chain coverage         "reached by no step, so nothing tests it"   four counters sit at 1 or 2
```

**The pattern, and it is the exact inverse of B's.**  Every C bound is a
derivation whose ratio the honest unit drives to within 1% of 1.0, and none of
them moved when the seed did, because the bound MOVES WITH THE STIMULUS -- it is
recomputed per case from `|o|`, `p`, `score_exp`, `pos`.  B's failing thresholds
were absolute numbers fitted to one draw; C has no absolute numbers to fit.
Where C is thin, it is thin on COVERAGE COUNTS, and that is where a shape change
rather than a seed change would bite.

## 5. Raw captured output

### 5.1 The faithfulness check, before any sweep

```
IDENTICAL patched-vs-orig attn_twiddle
IDENTICAL patched-vs-orig attn_emit
IDENTICAL patched-vs-orig attn_rope
IDENTICAL patched-vs-orig attn_kv_quant
IDENTICAL patched-vs-orig attn_score_q12
IDENTICAL patched-vs-orig attn_rescale
IDENTICAL patched-vs-orig attn_mac_array
IDENTICAL patched-vs-orig attn_softmax
IDENTICAL patched-vs-orig attn_gate
IDENTICAL patched-vs-orig attn_recip
```

And `VSEED = <the literal, in decimal>` reproducing the committed vectors:

```
VSEED=20260830 reproduces committed: attn_recip
VSEED=20260831 reproduces committed: attn_gate
VSEED=20260901 reproduces committed: attn_emit
VSEED=20260829 reproduces committed: attn_softmax
VSEED=20260902 reproduces committed: attn_twiddle
VSEED=20260903 reproduces committed: attn_rope
VSEED=1590182125 does NOT reproduce: attn_rescale     <-- my arithmetic, see 7.1
VSEED=20260827 reproduces committed: attn_kv_quant
VSEED=20260828 reproduces committed: attn_score_q12
VSEED=12648430 reproduces committed: attn_mac_array
```

### 5.2 The committed run of every C and D generator

The baseline the percentiles in 4.1 are measured against.

```
attn_recip_vec: 24 layers x 12 heads -> attn_recip_vec.txt
  oracle 4  worst |t - o*2^14/s| / derived bound: 0.9952 (case 2)
  p in [11, 25]; s a power of two 50, exact divisions 50, inexact 238
  r at the top of the u16 window 50, at the bottom 94; p = 11 57, p = 25 54

  oracle 3a  worst table entry error: 0.4992 Q30 ulp (k = 227)
  oracle 3b  worst over the EXHAUSTIVE domain sweep: 2.0292 counts at zg -5239, against the derived 2.0396
attn_gate_vec: 35 heads x 64 elements -> attn_gate_vec.txt
  oracle 1  worst |t - o*2^14/s| / derived bound: 1.0000
  oracle 3b worst |g15 - sigmoid*2^15|: 1.6817 counts against the derived 2.0396 (at zg 6291)
  oracle 5  worst chain error / composed bound: 0.7513
  branches: right 15 left 20 sh=0 5 sat32 290

attn_emit_vec: 40 layers x 2 groups x 48 elements -> attn_emit_vec.txt
  oracle 1  worst |y_mant - true| / derived bound: 0.9922 (case 7)
  shp = 0 12, shp > 0 28, shp > 8 5, amax = 0 5

attn_softmax_vec: 44 cases x up to 24 positions -> attn_softmax_vec.txt
  oracle 1  worst |s - batch| / derived bound: 0.8394 (case 36)
  oracle 2  worst |e_p - exp| / derived bound: 0.9896 (case 41)
  rescales 84 (of which f = 0: 14), heads with NO rescale 19, rescale at the last position 9

attn_twiddle_vec: 24 positions x 32 pairs -> attn_twiddle_vec.txt
  oracle 1  worst table entry error: 0.4988 ulp (half is the claim)
  oracle 4  worst |value - 32767*trig| / derived bound: 0.8617 (pos 308 j 19)
  oracle 6  worst |sin^2+cos^2 - 32767^2| / derived: 0.7313

attn_rope_vec: 28 head vectors x 96 dims (64 rotated) -> attn_rope_vec.txt
  oracle 1  worst |y - true rotation| / derived bound: 0.9350 (case 23)
  oracle 2  worst | |y|^2 - |x|^2 | / derived: 0.6976
  saturations 127 (high 64, low 64); pos = 0 cases 6; phases that wrapped 187

attn_rescale_vec: 512 cases -> attn_rescale_vec.txt
  o neg 256 pos 192 zero 64, at an ACC_W rail 64
  exact ties: positive 32 negative 32; f = 4096 cases 96, f = 0 cases 32

attn_kv_quant_vec: 64 cases x 256 (8 blocks of 32) -> attn_kv_quant_vec.txt
  oracle 1  worst value error: 0.500000 LSB of the block grid (case 2)
  oracle 2  peak/LSB ratio: max 127.9961 (case 5), min where sh>0 64.0000 (case 4)

attn_score_q12_vec: 64 cases x 8 blocks, kq_shift 4 -> attn_score_q12_vec.txt
  oracle 1  worst error / derived bound: 0.9475 (case 32)
  right-shift branch 43, LEFT-shift branch 21, saturating 17

seq_vec_res_vec: 64 cases, 6 oracles clean
  coverage: sh=0 10 | sh>0 54 | saturating clamp 1 | SHMAX clamp 32 | negative align shift 32 | n not a multiple of 8 42 | all-zero accumulator 3

seq_vec_chain_vec: n=250, 8 chained residual steps, 6 per-step oracles + C1 + C2 clean
  coverage: sh=0 1 | sh>0 7 | saturating clamp 1 | SHMAX clamp 2 | ee above ex 2 | ee below ex 4 | output exponent moved 5 | n not a multiple of 16 1
```

### 5.3 The 20 seeds where `attn_gate`'s oracle 1 sits exactly on its bound

```
20260827 1 7 11 13 17 123 256 512 4242 31337 65537 123456 777777
20260829 20261231 31415926 20250101 20240229 700001
    oracle 1  worst |t - o*2^14/s| / derived bound: 1.0000
```

The other twenty range 0.6843 to 0.9942.  Every one of the 40 exits 0.

### 5.4 Bench sweeps, 40 seeds each

```
tb_attn_rope        40/40 rc=0, 40/40 PASS, 2688 elements bit-exact every seed
tb_attn_recip       40/40 rc=0, 40/40 PASS  (asserterrs=1 is the expected
                                             `attn_recip: s = 0 offered`, which
                                             sim/regress.sh:901 allows by name)
tb_attn_gate        40/40 rc=0, 40/40 PASS
tb_attn_emit        40/40 rc=0, 40/40 PASS
tb_attn_twiddle     40/40 rc=0, 40/40 PASS
tb_attn_softmax     40/40 rc=0, 40/40 PASS
tb_attn_rescale     40/40 rc=0, 40/40 PASS
tb_attn_score_q12   40/40 rc=0, 40/40 PASS
tb_attn_kv_quant    40/40 rc=0, 40/40 PASS
tb_seq_vec_res      40/40 rc=0, 40/40 PASS
```

Sample lines:

```
SEED 20260826 rc=0 :: PASS: 28 head vectors, 2688 elements bit-exact (1792 rotated,
  896 passed through); saturating cases 9, clean 19, pos=0 6; stalls 13440,
  back-to-back 2604, twiddle waits 2660
SEED 20260826 rc=0 :: PASS: 512 cases bit-exact, SEQ_MULT=false MUX_FLAT=true
  LANES_SERVED=2 EN_GAP=0; frozen cycles 0, freeze holds checked 1,
  mux checks with live poison 512
SEED 20260826 rc=0 :: tb_seq_vec_res: PASS -- 64 cases bit-exact on every element,
  on o_exp, o_shift and o_sat, with i_taken pulsing at every accept
```

This is a stronger statement than the false-red count alone: at every one of 40
different stimulus draws the RTL reproduces the reference bit for bit, so
subsystem C's units are exact against their oracle across the swept stimulus
space and not only at the committed vector.

### 5.5 The dead generator gates, and the teeth check that shows one matters

Before `e27a9ad` -- which run directories contained a generator binary:

```
sim_tb_attn_emit:      gen_attn_emit_vec
sim_tb_attn_gate:      gen_attn_gate_vec
sim_tb_attn_kv_quant:  (none)          <-- generator never built, never run
sim_tb_attn_recip:     gen_attn_recip_vec
sim_tb_attn_rescale:   gen_attn_rescale_vec
sim_tb_attn_rope:      gen_attn_rope_vec
sim_tb_attn_score_q12: (none)          <-- generator never built, never run
sim_tb_attn_softmax:   gen_attn_softmax_vec
sim_tb_attn_twiddle:   gen_attn_twiddle_vec
sim_tb_seq_vec_res:    gen_seq_vec_res_vec
```

Teeth check on `attn_kv_quant`'s 0.5-LSB bound.  The control half is what makes
it worth reading.  A mutation of the INTEGER path alone is caught by the
equality oracle and says nothing about the bound:

```
--- integer path only: round_shift -> arithmetic shift
rc=1
  FAIL oracle 1: case 2 elem 128 integer path -128, double oracle -127
  FAIL oracle 1: case 2 elem 132 integer path 7, double oracle 8
```

A BOTH mutation -- floor in the integer path AND `floor(ideal)` instead of
`floor(ideal + 0.5)` in the double oracle -- keeps equality and is visible ONLY
to the bound:

```
--- BOTH: round_shift -> shift, and floor(ideal + 0.5) -> floor(ideal)
rc=1
  oracle 1  worst value error: 0.998047 LSB of the block grid (case 4)
  FAIL oracle 1: over 0.5 LSB, which a single round-half cannot explain --
    the integer recipe is wrong, not the grid
```

0.998047 against a gate of 0.5, on a mutation no equality check can see.  That
bound was unreachable from `sim/regress.sh` until `e27a9ad`.

`attn_score_q12`'s oracle 1 is checked the same way, with a BOTH mutation that
shifts one extra bit in the alignment:

```
  oracle 1  worst error / derived bound: 18687.8750 (case 26)
  FAIL oracle 1: over the derived bound of NBLK alignment floors plus one Q12 round
  FAIL oracle 3: case 2 aligned sum 216401 is more than NBLK below the unfloored sum 455207.931654
```

Both oracle 1 and oracle 3 fire, so on THIS mutation the bound is redundant with
oracle 3.  Recorded under its own name rather than dropped: a mutation that does
not bite alone is the measurement of a check's resolution floor.

### 5.6 After `e27a9ad`: the two rows regenerate the golden byte for byte

```
PASS       sim:tb_attn_kv_quant       1s
PASS       sim:tb_attn_score_q12      1s
kvq  regenerated vs `git show HEAD:sim/attn_kv_quant_vec.txt`  -> IDENTICAL
sq12 regenerated vs `git show HEAD:sim/attn_score_q12_vec.txt` -> IDENTICAL
gen_attn_kv_quant_vec now built in the run directory
```

### 5.7 The working-tree golden clobber

```
$ ls -l --time-style=full-iso sim/attn_kv_quant_vec.txt sim/attn_score_q12_vec.txt
-rw-rw-r-- 115628 2026-08-29 10:46:33 sim/attn_kv_quant_vec.txt
-rw-rw-r--   5944 2026-08-29 10:46:23 sim/attn_score_q12_vec.txt
$ git status --porcelain sim/attn_kv_quant_vec.txt sim/attn_score_q12_vec.txt
 M sim/attn_kv_quant_vec.txt
 M sim/attn_score_q12_vec.txt
$ git diff --stat
 sim/attn_kv_quant_vec.txt  | 476 ++++++++++++++++-----------------
 sim/attn_score_q12_vec.txt | 366 +++++++++++++++-----------
$ git show HEAD:sim/attn_kv_quant_vec.txt  | md5sum   1624e80a34699a9b45d7cabbab4b1360
$ generator default output                 md5sum    1624e80a34699a9b45d7cabbab4b1360
$ md5sum sim/attn_kv_quant_vec.txt                   efd13114c3e02dedea3de4f52a7c9758
```

HEAD's golden and the generator's default output agree exactly; the working-tree
file is neither.  My faithfulness check at 10:37 compared against the tree and
reported IDENTICAL; the same comparison at 10:52 reported DIFFERS.  Nothing
about the generator changed in between.  See 7.2.

### 5.8 Full unfiltered gate run, after every edit

`bash sim/regress.sh`, no `--only`, no `--quick`, both suites, started after
`e27a9ad` was committed:

```
 suite sim   PASS 60   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 86   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 86 passing, matches the recorded floor of 86
 REGRESSION: PASS
```

Every subsystem C and D row green, including the two whose generators now run
for the first time:

```
PASS  sim:tb_attn_block       2s      PASS  sim:tb_seq_desc_fetch    1s
PASS  sim:tb_attn_emit        0s      PASS  sim:tb_seq_opdec         1s
PASS  sim:tb_attn_gate        1s      PASS  sim:tb_seq_region_lock   1s
PASS  sim:tb_attn_kv_axi      2s      PASS  sim:tb_seq_tbl_shape     0s
PASS  sim:tb_attn_kv_quant    0s  <-- PASS  sim:tb_seq_vec_res       1s
PASS  sim:tb_attn_kv_seam     6s      PASS  sim:tb_seq_vec_seam      1s
PASS  sim:tb_attn_mac_array   2s      PASS  sim:tb_attn_rope         1s
PASS  sim:tb_attn_recip       0s      PASS  sim:tb_attn_score_q12    0s  <--
PASS  sim:tb_attn_rescale     0s      PASS  sim:tb_attn_softmax      0s
PASS  sim:tb_attn_fix_beh     2s      PASS  sim:tb_attn_twiddle      0s
PASS  sim:tb_attn_replay_beh  2s      PASS  sim:tb_llama_top_seq   309s
NOCHECK sim:tb_attn_beh       0s      (observation only, by design)
```

**Read the 86 correctly.**  This track added NO gate row, and its
`sim/regress.sh` edit is inside `tb_vector_args` and does not touch
`BASELINE_PASS`.  The floor reads 86 rather than the 85 the dispatch quoted
because ANOTHER track's working-tree edit adds `sim/tb_seq_tbl_shape` and raises
the floor to match; that edit is uncommitted and was deliberately left in place
and out of `e27a9ad` (`git apply --cached` of a single hunk, then a commit with
no pathspec).  What this run establishes for this track is FAIL 0 with both new
generator rows live, not the value of the counter.

## 6. Measured and REJECTED -- do not retry

- **Do NOT widen any of the seven derived-bound ratios in 4.1 that sit within 1%
  of 1.0.**  MEASURED: 0 of 40 honest seeds fire on every one of them, so there
  is nothing to fix, and the derivation makes `ratio <= 1` a theorem rather than
  a fitted maximum.  Widening `attn_gate`'s oracle 1 past 1.0 in particular
  would delete the tightest check in subsystem C: the honest unit ATTAINS the
  bound at 20 of 40 seeds, which means any defect adding one ulp of error is
  caught.  B-SEED's rule -- widen a threshold the honest unit exceeds -- does not
  transfer, because the honest unit here never exceeds one.
- **Do NOT "fix" `attn_kv_quant`'s `worst_lo < 64.0` because the honest value is
  exactly 64.0000.**  MEASURED: 64.0000 at 40 of 40 seeds, and the gate is a
  strict `<`.  The value is 64 because a block whose peak reached exactly half
  the int8 range is what `sh` is chosen to produce; the window `[64, 128)` is
  the requantizer's definition, not a calibration.  Moving the bound to 63.9
  admits a real defect (one magnitude bit thrown away) and buys nothing, since
  the current figure cannot go below 64 without one.
- **Do NOT add a bench-side accuracy tolerance to any C or D bench.**  MEASURED:
  all 25 are bit-exact against a vector file and all 10 swept benches reproduce
  the reference exactly at 40 different stimulus draws.  A tolerance added to a
  bit-exact bench can only LOOSEN it.  Where C needs more, it needs a property
  the vector file does not carry -- which is what `tb_attn_block`'s seven
  properties were, and they are the documented case of passing while the numbers
  were wrong.
- **Do NOT read `seq_vec_res_vec.c` / `seq_vec_chain_vec.c`'s flat coverage as
  evidence that their seed argument is inert.**  MEASURED: the vector files
  differ at every seed (four distinct md5s at four seeds, both generators).  The
  counters are flat because the SHAPE schedule is deterministic, not because the
  seed is ignored.  This is not B-SEED's inert-`SEED` defect and must not be
  "fixed" by removing the knob.
- **Do NOT attempt to bound `attn_gate`'s oracle 3b by more seeds.**  MEASURED:
  the per-case statistic reaches 2.0292 at some seeds, which is EXACTLY the
  maximum the generator's own exhaustive s32 domain sweep reports at every seed.
  The exhaustive sweep already establishes the maximum over the whole input
  domain; a stimulus sweep cannot improve on it and cannot exceed it.
- **Do NOT count a mutation-harness "KILL" in `sim/mutate_attn_*.sh` as
  detection without reading the log.**  Their judging is
  `ghdl -r ... && grep -q "PASS"`, so a run that DIED scores as a kill.  This is
  the mirror of the trap the brief names, and the `mutate_ref_*` harnesses do it
  correctly (`grep -q "FAIL oracle"`), so the two conventions differ inside one
  directory.  Not changed here -- it is not an accuracy threshold and the files
  are shared with other work -- but it is not a safe reading.

## 7. Measurement traps hit, including my own

1. **A hex seed literal converted by hand is a silent sweep point.**
   `attn_rescale_vec.c` seeds with `0x5eed5eed`.  I wrote 1590182125 and the
   faithfulness check said "does NOT reproduce", which reads as "the patch
   changed something".  It did not: `0x5eed5eed` is **1592614637**, and with the
   correct decimal it reproduces exactly.  This is B-SEED's trap 1 in a second
   form -- there, the literal was not the seed; here, my arithmetic was wrong --
   and both produce the same symptom.  Convert with `python3 -c 'print(0x...)'`,
   never by hand.
2. **A golden file compared against the WORKING TREE is not a measurement of the
   golden.**  My faithfulness check at 10:37 reported
   `IDENTICAL-to-tree attn_kv_quant`; the identical comparison at 10:52 reported
   DIFFERS, because another track overwrote the file at 10:46.  Nothing about my
   generator changed.  **Compare against `git show HEAD:<path>`, not against the
   tree, whenever four agents are live.**  I had the right answer and would have
   reported the wrong one if the regress.sh work had not forced a second look.
3. **`sim/regress.sh --only` builds a generator only for vectors it regenerates,
   so the absence of a `gen_*` binary is the measurement.**  I first tried to
   establish "the gate never runs this generator" by reading the skip condition
   at `:983`, which is an argument, not evidence.  Listing `gen_*` in all ten
   run directories is the evidence, and it is what section 5.5 records.
4. **`attn_gate_vec.c` textually includes `attn_recip_vec.c`, and
   `attn_rope_vec.c` includes `attn_twiddle_vec.c`.**  A seed patcher that
   targets "the first static seed in the file" would patch the wrong variable in
   two of ten cases and produce a copy that silently ignores `VSEED`.  The
   patcher takes the variable name explicitly, and the faithfulness check in 5.1
   is what would have caught it.
5. **A ratio printed as `1.0000` is not proof the gate fired or did not.**  Four
   decimal places cannot separate 0.99995 from 1.00004, and the second would
   have fired.  The exit code is the measurement; the printed figure is a label.
   Section 4.1's "false-red 0/40" comes from the exit code on all 18 rows.
6. **My seed list is not independent of the units.**  The same 40 integers were
   used everywhere, so a pathological value would show up in every row rather
   than one.  Nothing here looks like that -- every distribution is smooth and
   the flat ones are flat for structural reasons that were read in the source --
   but this study did not control for it.  It is B-SEED's trap 5, inherited
   deliberately so the two seed lists match.
7. **`ghdl -a` on these benches emits `warning: type of a shared variable must
   be a protected type`.**  Pre-existing across the whole tree, not caused by
   anything here.  Do not chase it.

## 8. Open, NOT verified

- **A seed sweep varies the STIMULUS DISTRIBUTION, not the RECIPE and not the
  SHAPE.**  Every number here is the honest unit's behaviour under a different
  draw from the same generator at a fixed geometry (`NCASE`, `HEAD_DIM`,
  `NBLK`, `N_ROT`, `KV_BLOCK`, `NPAIR`, `NPOS`, `GRP_N`, `NRES`).  Most of the
  22 coverage gates are ABSOLUTE COUNTS at a committed shape, so changing a
  shape changes what they mean, and the three counters sitting at exactly 1 are
  precisely the ones a shape change would zero.  NOT verified at any other
  shape, and that -- not seeds -- is where subsystem C's coverage gates are
  fragile.
- **The eight bounds in 4.2 have a false-red rate but no honest range.**  They
  print no statistic, so the only measurement is the exit code.  Establishing a
  range would mean patching each generator to print its worst case, which is a
  change to `ref/**` and belongs to TRACK RY-ORACLE.
- **Three gated coverage counters are never printed** and so were measured only
  through the exit code: `attn_rope`'s `n_adj_differs`, `attn_twiddle`'s
  `j = max`, `attn_rescale`'s `yv[0] != 0 && yv[1] != 0`.
- **`tb_attn_block`, `tb_attn_kv_seam`, `tb_attn_kv_axi`, `tb_seq_desc_fetch`,
  `tb_seq_opdec`, `tb_seq_region_lock` and `tb_seq_vec_seam` were NOT swept.**
  They carry no accuracy threshold (4.5), which is why, and the four `tb_seq_*`
  ones take `TBL_STEPS` from `sim/seq_tbl_pkg.vhd`, which TRACK TOKIO is editing
  right now (491 -> 505, uncommitted in the tree at the time of writing).  Any
  measurement of those four today would be a measurement of a file in flight.
  `tb_attn_block` is the unit the brief names as the documented case of passing
  seven properties while computing wrong numbers; nothing here re-examines that,
  and its `attn_block_vec.c` oracle carries no bound to audit.
- **Ten C generators still want a `seed` argument** the way
  `seq_vec_res_vec.c` and `seq_vec_chain_vec.c` already have one:
  `attn_recip`, `attn_rope`, `attn_gate`, `attn_emit`, `attn_rescale`,
  `attn_softmax`, `attn_twiddle`, `attn_kv_quant`, `attn_score_q12`,
  `attn_mac_array`.  Every sweep in this document went through a patched scratch
  copy.  `ref/**` is TRACK RY-ORACLE's, so this is reported and not done.  With
  B-SEED's six, sixteen generators now want the same one-line change.
- **The working-tree clobber of `sim/attn_kv_quant_vec.txt` and
  `sim/attn_score_q12_vec.txt` is NOT resolved.**  `e27a9ad` makes the gate
  immune to it, but the two files are still modified in the tree with foreign
  content and this track does not own them.  Whoever committed a generator run
  with `cwd = sim/` should `git checkout --` them.
- **Whether `sim/mutate_attn_*.sh`'s died-run-counts-as-kill convention has
  inflated any published kill ratio was NOT checked.**  Only the judging line
  was read.
- **No claim is made about subsystems A, B or E.**  B is
  `docs/debugging/2026-08-29_b-threshold-seed-audit.md`.

## 9. Corrections

None yet.
