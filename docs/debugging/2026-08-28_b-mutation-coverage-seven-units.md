# Subsystem B: mutation coverage for the seven units that had none

Date: 2026-08-28.  Repo `llama.vhdl`, branch `fpga`.
Simulator: ghdl-mcode, VHDL-2008, `-frelaxed`.  No hardware involved.
Companion to `docs/debugging/2026-08-28_b-accuracy-transcription-vs-arithmetic.md`,
whose closing line was "No mutation coverage exists for the other seven B units."

## 1. The question

Verbatim, from the dispatch:

> **Subsystem B has SEVEN units with zero mutation coverage.**  The completeness
> audit rates them V- ("bit-exact against an independent oracle, mutation
> testing performed and recorded in prose only, with no committed harness that
> reproduces it").  Prose is not a harness.
>
> The seven: `gdn_conv`, `gdn_silu`, `gdn_head_emit`, `gdn_y_emit`,
> `gdn_emit_chain`, `rmsnorm_bf`, `gdn_scalar`.
>
> For each unit: say what its bench actually checks before mutating anything;
> design mutations that target what that bench claims to cover, including at
> least one BOTH mutation applied to the C reference AND the RTL; run it and
> record the outcome INCLUDING the passes; commit a re-runnable
> `sim/mutate_<unit>.sh`.

## 2. The answer

All seven now have a committed harness.  **103 of 140 mutations are killed.**
Every one of the 37 survivors has a measured explanation, and the survivors are
where the value is: they located **three defects in the verification itself**,
none of which is an RTL bug and all three of which mean the gate is weaker than
it reads.

1. **`sim/gdn_conv_vec.txt` is STALE.**  It was committed at `c3d2fea`; `9cfdbd2`
   then changed `ref/gdn_conv_vec.c` specifically to make gdn_conv's `err_seg`
   path reachable, and the golden was never regenerated.  `sim/regress.sh` never
   regenerates a committed vector, so the gate still runs the OLD golden, in
   which `err = 0` in all 128 cases.  MEASURED: an RTL mutation that deletes the
   int8-overflow test entirely is **caught on a fresh golden and passes on the
   committed one**.
2. **`tb_gdn_emit_chain` is run by the gate at the one setting that masks its
   own documented defect.**  `Z_DELAY` defaults to 0 and `sim/regress.sh` does
   not override it.  MEASURED: dropping the `z_have` term from S_IDLE's
   condition -- the exact defect the RTL comment says that term exists for --
   PASSES at `Z_DELAY` 0, 7 and 40 and FAILS at 600 and 2000, with the
   unmutated chain passing at 600 as the control.
3. **`gdn_scalar`'s printed accuracy oracle is already saturated on the
   unmutated unit.**  MEASURED, independently, twice:
   `vs double oracle: eg worst 3.2768e4 LSB(Q15)` -- 32768 is the entire output
   range.  A threshold on that figure is vacuous, so `gdn_scalar` has no usable
   accuracy signal at all, not merely an ungated one.

A fourth result is structural rather than a defect: **four of the seven units
have no accuracy gate anywhere in the suite.**  `gdn_silu`, `rmsnorm_bf` and
`gdn_scalar` only PRINT their double-oracle figures.  `gdn_head_emit`,
`gdn_y_emit` and `gdn_emit_chain` do gate, but in the GENERATOR'S EXIT CODE --
and `sim/regress.sh` never runs those generators, because their vectors are
committed.  So as the gate stands, **no BOTH-class mutation in this whole
report would fail it.**  All 21 of them are recorded below and every one leaves
bit-exactness green.

**No RTL was changed and no bench was widened.**  Where a bench cannot see a
defect class, that is recorded as a blind spot.

## 3. The procedure, in the order it was run

Each step is a control for the one after it.

1. **Read each bench and write down what it asserts, BEFORE designing any
   mutation.**  A mutation aimed at something a bench never claimed to cover
   scores a meaningless survivor.  This step is what produced the table in
   section 4.1 and the correction in section 8.
2. **Verify each generator reproduces its committed vector byte for byte.**
   Six of seven do.  The seventh is finding 1.  This step is not optional: it
   is the step B-ACCURACY skipped and paid four wasted runs for.
3. **Build one private harness per unit** that regenerates vectors into its own
   workdir and analyses into its own GHDL library, because every one of these
   seven vector files is COMMITTED and `sim/regress.sh` therefore never
   regenerates it -- so a C-side mutation run through regress.sh changes
   nothing at all.
4. **Validate the harness pattern on the simplest unit first** (`gdn_silu`,
   3 files, 6 s a run) before spending it on the composed ones.
5. **Three mutation classes per unit**, because one class cannot separate the
   two checks:
   - **RTL only** -> must fail bit-exactness.
   - **C only** -> must fail bit-exactness; whether the oracle ALSO moves is a
     measurement of what the oracle can resolve.
   - **BOTH**, the same recipe change in each -> must LEAVE bit-exactness green
     and can only be caught by a real-valued oracle.
6. **Every anchor must match exactly once or the mutation aborts.**  An anchor
   that matches zero times is a false survivor; one that matches twice is not
   the mutation described.
7. **For every survivor, MEASURE which of three things it is** -- an equivalent
   mutant, a coverage hole, or below the resolution floor -- by instrumenting a
   copy of the generator or of the RTL and running it.  Not by reading the code
   and forming an opinion.
8. **Where a survivor is a configuration artefact, re-run it in the other
   configuration WITH A CONTROL.**  A mutation that dies at `Z_DELAY = 600`
   proves nothing unless the unmutated design passes there too.

## 4. The evidence

### 4.1 What each bench actually checks (MEASURED, by reading the file)

| unit | bit-exact | real-valued oracle | other properties |
|---|---|---|---|
| `gdn_conv` | yes, asserted | **yes, IN THE BENCH**, `TOL = 0.75` output LSB, asserted | `err_seg` low in the non-err branch, `e_seg`, `sh_seg`; plus two ordering properties at severity failure |
| `gdn_silu` | yes, asserted | no -- printed by the generator, gated nowhere | none |
| `gdn_head_emit` | yes, asserted | in the GENERATOR's exit code, `>= 1.0` LSB | `e_head`, `o_sat` both directions, overlap throughput bound |
| `gdn_y_emit` | yes, asserted | in the GENERATOR's exit code, `>= 1.0` LSB | `y_exp`, `o_sat`, element count, `o_last` coincidence, throughput bound |
| `gdn_emit_chain` | yes, asserted | in the GENERATOR's exit code, `> 8.0` LSB | element count, `y_exp`, refused-column count (only asserted with `STRICT=true`) |
| `rmsnorm_bf` | yes, asserted | no -- printed by the generator, gated nowhere | vector shape / `Q` / `E_EPS`+`M_EPS` header asserts |
| `gdn_scalar` | yes, at severity FAILURE | no -- printed by the BENCH, **"reported, not asserted"**, and vacuous (see 4.6) | `err_g` |

### 4.2 Kill ratios

| unit | script | killed | survived | total |
|---|---|---|---|---|
| `gdn_conv` | `sim/mutate_gdn_conv.sh` | 15 | 5 | 20 |
| `gdn_silu` | `sim/mutate_gdn_silu.sh` | 15 | 4 | 19 |
| `gdn_head_emit` | `sim/mutate_gdn_head_emit.sh` | 18 | 2 | 20 |
| `gdn_y_emit` | `sim/mutate_gdn_y_emit.sh` | 14 | 8 | 22 |
| `gdn_emit_chain` | `sim/mutate_gdn_emit_chain.sh` | 9 | 8 | 17 |
| `rmsnorm_bf` | `sim/mutate_rmsnorm_bf.sh` | 17 | 6 | 23 |
| `gdn_scalar` | `sim/mutate_gdn_scalar.sh` | 15 | 4 | 19 |
| **total** | | **103** | **37** | **140** |

### 4.3 The BOTH class: 21 mutations, none of which the gate can see

`RTL` and `C` columns omitted; every row below leaves bit-exactness GREEN and
is caught only by a real-valued oracle.

| unit | mutation | oracle verdict |
|---|---|---|
| gdn_conv | requantize bias dropped in both | FAIL (bench's own TOL) |
| gdn_conv | `sh_seg` keeps 15 bits in both | FAIL (bench's own TOL) |
| gdn_conv | per-tap alignment clamped at 8 in both | FAIL (bench's own TOL) |
| gdn_conv | `e_ref` is the MAX of valid tap exponents | FAIL (bench's own TOL) |
| gdn_silu | output round-shift 16 not 15 | FAIL 16380 LSB |
| gdn_silu | LUT interpolation slope halved | FAIL 253.5 LSB |
| gdn_silu | sigma rail moves from \|x\|=16 to \|x\|=8 | FAIL 5.2488 LSB |
| gdn_silu | output round bias dropped (truncate) | FAIL 2.5702 LSB |
| gdn_head_emit | every column aligned one bit too far | FAIL 32164 LSB |
| gdn_head_emit | `e_h` = column 0's exponent, not the min | FAIL 1.81e15 LSB |
| gdn_head_emit | requantize truncates | FAIL 1.0000 LSB |
| gdn_head_emit | output rail 16 bits -> 15 | **pass, did not bite** |
| gdn_y_emit | `shj` one too large | FAIL 32238 LSB |
| gdn_y_emit | `e_y_raw` = head 0, not the min | FAIL 2.11e15 LSB |
| gdn_y_emit | requantize truncates | **pass, by 1.2e-14** |
| gdn_y_emit | output rail 16 -> 15 bits | **pass, oracle emptied** |
| gdn_emit_chain | seam 4 exponent sum one too large | FAIL 24799 LSB |
| gdn_emit_chain | seam 1 head exponent one too large | FAIL 5025 LSB |
| gdn_emit_chain | seam 3 gate grid one octave off | FAIL 1364 LSB |
| gdn_emit_chain | site 13 keeps one bit less headroom | **pass, oracle blind** |
| rmsnorm_bf | rsqrt exponent divided out against Q, not e_out | FAIL 1.68e10 LSB |
| rmsnorm_bf | the SMALLER of mean and eps dropped | FAIL 6519 LSB |
| rmsnorm_bf | emit shift keeps one bit less headroom | FAIL 38.5 LSB |
| rmsnorm_bf | `rq_E` one too small (gain halved) | FAIL 32091 LSB |
| rmsnorm_bf | ONE Newton iteration instead of two | FAIL 2.2809 LSB |
| rmsnorm_bf | emit round bias dropped (truncate) | FAIL 1.3440 LSB |
| gdn_scalar | sentinel 2^45 -> 2^30 | FAIL (harness aggregate) |
| gdn_scalar | softplus positive tail clamped | FAIL (harness aggregate) |
| gdn_scalar | softplus negative tail clamped at -4 | FAIL (harness aggregate) |
| gdn_scalar | `g`'s lower clamp -16 -> -8 | FAIL (harness aggregate) |
| gdn_scalar | eg output round bias dropped | **pass, did not bite** |

The rmsnorm_bf flagship is worth naming: **the first row reintroduces exactly
the defect `rmsnorm_bf` was written to fix.**  `rmsnorm_rs.vhd` divides the
rsqrt exponent out against `Q` because it assumes a fixed `2^-Q` grid; this
unit's `msq` is on `2^-e_out`.  Applied to the C and the VHDL together it is
bit-exact-green and 1.7e10 output LSB wrong.

### 4.4 Finding 1, verbatim: the stale gdn_conv golden

```
$ cmp fresh/gdn_conv_vec.txt sim/gdn_conv_vec.txt
gdn_conv_vec.txt sim/gdn_conv_vec.txt differ: byte 13, line 2

$ awk 'NR>1 && (NR-2)%5==0 {print $9}' sim/gdn_conv_vec.txt | sort | uniq -c
    128 0
$ awk 'NR>1 && (NR-2)%5==0 {print $9}' fresh/gdn_conv_vec.txt | sort | uniq -c
    126 0
      2 1
```

`$9` is the `err` field.  `git log` shows `sim/gdn_conv_vec.txt` last touched at
`c3d2fea` and `ref/gdn_conv_vec.c` last touched at `9cfdbd2`, whose message
says:

> gdn_conv's err path was structurally unreachable ... One case class in seven
> now draws cw_exp wide enough to leave int8, and the low assertion is added.

The generator change landed.  The golden did not.  The consequence, MEASURED as
mutation R13 in `sim/mutate_gdn_conv.sh`, scored against both vector sets:

| mutation | FRESH golden | COMMITTED golden |
|---|---|---|
| R13, `err_seg` is never raised | **FAIL** (caught) | **pass** (not caught) |

R13 is the only mutation of the twenty whose two columns disagree, which is
what identifies the staleness as an `err_seg` coverage loss specifically rather
than a general drift.

**Deliberately NOT fixed here.**  Regenerating `sim/gdn_conv_vec.txt` changes a
golden that four other tracks are running against today, and a verification
track does not land that silently.

### 4.5 Finding 2, verbatim: the chain gate runs at the masking setting

`sim/regress.sh` line for this bench:

```
sim:tb_gdn_emit_chain)   echo "-gOVERLAP=true -gCOL_GAP=4 -gSTRICT=false -gSILU_LANES=16 -gRMS_LANES=4 --stop-time=300ms" ;;
```

`Z_DELAY` is not among them, so it takes the bench default, which is 0.  The
bench's own header says what that costs:

> Z_DELAY: 0 makes it run maximally ahead, which is what MASKED the z_have
> defect: z was always already latched, so a chain that never checked z_have
> still passed.

MEASURED, for the mutation that removes `z_have` from S_IDLE's condition:

```
Z_DELAY     0  PASS      7  PASS     40  PASS
Z_DELAY   600  FAIL   2000  FAIL

at Z_DELAY=600:
  tb_gdn_emit_chain: block 0 element 640 head 5 lane 0 got -6541 expected 179
CONTROL, unmutated chain at Z_DELAY=600:
  tb_gdn_emit_chain: PASS -- 2 blocks x 24 heads x 128 bit-exact
```

40 is not enough because `gdn_head_emit` needs DIM columns at `COL_GAP = 4`, so
512 cycles, before it raises `done`; a z that is 40 cycles late is still 470
cycles early.  The threshold is therefore a property of the column rate, not a
magic number.  `sim/mutate_gdn_emit_chain.sh` carries the control and the
mutant re-run as a `zdelay_check` block so the result reproduces.

### 4.6 Finding 3, verbatim: gdn_scalar's oracle is saturated at baseline

Unmutated `rtl/gdn_scalar.vhd`, unmutated `ref/gdn_scalar_vec.c`:

```
sim/tb_gdn_scalar.vhd:105: bit-exact vs fixed reference: eg mismatches 0, beta mismatches 0, err_g mismatches 0
sim/tb_gdn_scalar.vhd:108: vs double oracle: eg worst 3.2768e4 LSB(Q15), beta worst 3.088008999999147 LSB(Q16)
```

32768 is the full Q15 output range.  Per-case: median 0.0553 LSB, 87 cases over
1 LSB, 17 over 100 LSB.  Case 262 computes `eg = 0` where the truth is 32768;
case 270 computes 32768 where the truth is 0.0037.  Both are the two
`to_q_wide` terms saturating at the `+-2^45` sentinel and CANCELLING -- the same
failure mode the unit's header claims to have corrected, relocated from the s32
rail to the sentinel rather than removed.

Whether that band is reachable from the real 27B weights is **NOT determined**.
The consequence for this report is narrower and is certain: a max-based gate on
the printed `eg` figure cannot exist, so `sim/mutate_gdn_scalar.sh` gates on the
`beta` figure plus an aggregate it computes over the same two oracle columns.

## 5. Measured and did NOT bite -- do not retry

The most valuable rows.  Each is labelled with WHICH of the three kinds it is,
because the three call for different responses and only one of them is a gap a
wider sweep could close.

### Equivalent mutants -- no stimulus can ever separate these

- **`rmsnorm_bf` R6, normalising S to bit 31 instead of bit 30.**  Doubling
  `m_mean` and raising `e_mean` by one leaves the represented value unchanged;
  when mean is the smaller term `align = (2m) >> (d+1) = m >> d` EXACTLY,
  truncation included, and when eps is the smaller term `msq` doubles while
  `e_out` rises, leaving `rq_d = rq_p - e_out` unchanged.  The normalisation
  point of this block-floating form is a free parameter.
- **`rmsnorm_bf` R7 and R10.**  R7 moves the `e_mean == E_EPS` tie, and at
  `d = 0` both branches compute `m_mean + M_EPS` with the same `e_out`; the
  generator already argues this in a comment.  R10 changes the `om > 32767`
  compare while leaving the emitted constant at 32767, so the only input whose
  behaviour changes emits the same value.  R13 is the same site done properly
  and it dies.  **Lesson for writing rail mutations: move the VALUE, not just
  the compare.**
- **`gdn_silu` R9**, `-sh > 40` -> `> 41`.  At `-sh = 41` the M_LSH branch
  computes `v << 41` with `|v| <= 2^15`, so at most `2^56` -- no overflow of the
  64-bit temporary -- and then clamps to `+-2^30`, which is what M_RAIL emits.
- **`gdn_emit_chain` R8**, `in_hfirst` asserted on every element.  `in_hfirst`
  has one consumer (`rtl/gdn_y_emit.vhd:276-282`): it latches `in_e` into
  `ep(head)` and folds it into a running minimum.  The chain holds `ye_e` at
  `ep_r` for the whole head, so the extra assertions re-latch the same value and
  re-run the minimum against itself.  Idempotent.
- **`gdn_scalar` R5**, the negative-tail compare boundary.  `arg == -LIM` occurs
  in 6 of 320 cases and at that point the mutant's table path yields
  `SP_ROM(0) = 121` in Q30, `rsh_r(121, 12) = 0`, identical to the compare.

### Equivalent under the shipped timing -- not a stimulus gap

MEASURED with an instrumented copy of `gdn_emit_chain.vhd`, identical at
`COL_GAP = 1` and `COL_GAP = 4` over 2 blocks x 24 heads:

```
PROBE ye_stall=0 ser_entry_stall=0 rms_gate_late=0 he_mant_changed_during_rms=0
```

- **`gdn_emit_chain` R9**, releasing `he_ack` before the norm has read
  `he_mant`.  `he_mant_changed_during_rms = 0`: the register is never
  overwritten while `rmsnorm_bf` reads it, because the next head needs DIM
  columns to arrive first.  The `CONSUME_BUDGET` watchdog, not the data check,
  is what would catch a real violation of that margin.
- **`gdn_emit_chain` R10**, leaving S_RMS without `si_rd = SI_BEATS`.
  `rms_gate_late = 0`: the gate has always drained, because the norm at ~142
  cycles is the long pole against `SI_BEATS = 8` plus latency.  Widening
  `COL_GAP` does not change this.

### Coverage holes -- a different stimulus WOULD kill these

- **`gdn_emit_chain` R7, the B-1 phantom advance.**  `ye_stall = 0` and
  `ser_entry_stall = 0`: **`gdn_y_emit`'s `in_ready` never falls in this
  bench.**  Independently, the same hole was measured in `tb_gdn_y_emit` itself
  by inserting a back-pressure probe into an otherwise untouched DUT:
  `PROBE BACKPRESSURE` fired **0 times**.  Two benches, one conclusion:
  **gdn_y_emit's back-pressure path is unexercised anywhere in subsystem B**,
  and the port its own comment calls "MANDATORY, not a convenience" is
  unverified.  Closing it needs a y consumer that can stall or a third block;
  neither bench has the knob.
- **`gdn_emit_chain` R5, reading the gate exponent live.**
  `ref/gdn_emit_chain_vec.c:73` is `int we = 12, z_e = 12;` and neither ever
  changes, for any block or head.  `z_exp` is constant, so reading it live is
  reading the held copy.  The defect needs a `z_exp` that MOVES between heads
  and no vector in this repo produces one.
- **`gdn_silu` R8 and C3**, the `sh > 62` flush-to-zero guard on both sides.
  MEASURED `PROBE sh range [-42,28]`: `sh` never exceeds 28, so neither
  transcription ever evaluates that comparison.  The generator's comment calls
  `e = 40` a "deep right shift, flushes to 0" -- it does flush, but through
  M_RSH, not through the guard.
- **`gdn_silu` R10**, the LOW rail boundary.  `PROBE xq==-RAIL 0  xq==+RAIL 6`:
  one-sided.  R12 is the same mutation on the side that IS reached and it dies.
- **`gdn_conv` R6, defect B-3 (the tap mask read live).**  Survives
  `tb_gdn_conv` and is **KILLED by `sim/tb_gdn_conv_tvalid_skew.vhd`**, which
  drives `tvalid` from the real `gdn_exp_capture`: "FAIL -- 2 case(s) not
  bit-exact at RDREQ_AT=16".  The cross-check is wired into the committed
  script.
- **`gdn_conv` R7, defect B-3b (`cw_exp` read live).**  Survives every bench in
  the repo.  MEASURED why: the skew bench sets `cw_exp <= to_signed(0, 8)` once
  and `gdn_exp_capture` has no `cw_exp` port, so nothing anywhere moves `cw_exp`
  under a running conv.  **This defect class has no bench at all.**
- **`gdn_conv` R9, `gdn_scalar` R7, `gdn_y_emit` R14/C1, `gdn_emit_chain` C1,
  `rmsnorm_bf` R14** -- saturation rails and guard branches that the stimulus
  never reaches.  Counters: `gdn_conv` `sat16 clipped: 0`; `gdn_scalar`
  `a_m > 0` in 0 of 320 so the `min(0, .)` guard is structurally unreachable;
  `gdn_y_emit` `elements landing exactly on a 16-bit rail: 0`;
  `gdn_emit_chain` `saturated elements: 0`; `rmsnorm_bf` `emit saturates at
  -32768  NOT REACHED`.
- **`rmsnorm_bf` R7** is BOTH -- `PROBE e_mean == E_EPS ties: 0` over 200 cases,
  and equivalent anyway.  Worth separating the two, because only one of them
  would be fixed by a wider sweep.

### Below the resolution floor -- widening the check would not help

- **`gdn_silu` B4 and `rmsnorm_bf` B6 DID bite** (2.5702 and 1.3440 LSB against
  gates of 2.0 and 1.0), which is the opposite of the B-ACCURACY S1 result on
  `gdn_recur_pipe`.  Recorded so the difference is not mistaken for a rule: a
  half-LSB rounding change is visible when the unit's own error is comparable to
  an LSB and invisible when it is 18x larger.
- **`rmsnorm_bf` R12 and C2, rounding the alignment instead of truncating.**
  Both survive both checks, on both sides, and this CONFIRMS the prose claim at
  `rtl/rmsnorm_bf.vhd:95-98` rather than exposing a weak bench.  The term
  shifted there is by construction the negligible one, so a 1-LSB perturbation
  of it is far below the output grid.  Do not widen either check to catch it.
- **`gdn_conv` R1 and C1, rounding the per-tap alignment.**  MEASURED:
  `taps=76544, floor != round on 19351 (25.3%)`, `max |acc delta| = 3`, and
  **`sm changed: 0` of 32,768 elements**.  `sh_seg` histogram `0:12  15:111
  16:5` -- in 116 of 128 cases the output grid is 2^15 to 2^16 coarser than
  where the decision is made, and the 12 cases at `sh_seg = 0` are exactly the
  12 all-zero cases.  Neither check can see the alignment rounding mode, on
  either side, and no tolerance could.
- **`gdn_head_emit` R1 and `gdn_y_emit` R1/R10.**  These change `amax`, whose
  only consumer is `msb_pos`.  Probes: head_emit `round-aligned amax differs in
  2 of 64 cases; its msb_pos differs in 0`; y_emit `differs in 0 of 48`, and
  one's-complement abs `differs in 10 of 48; msb_pos differs in 0`.  Not
  equivalent in general, unobservable at this interface.  The identical
  one's-complement mutation KILLS in head_emit, so this is a property of the
  case set, not of the recipe.
- **`gdn_scalar` B4, dropping the eg output round bias in both.**  The mutation
  demonstrably fires -- **78 of 320 eg values change** -- and every aggregate
  moves the safe way: median 0.0553 -> 0.0440, n>1 LSB 87 -> 81, n>100
  unchanged at 17, max pinned at 32768.  The mean is +803 because 17 cases are
  wrong by hundreds to tens of thousands of LSB, so a half-LSB bias is four
  orders of magnitude below the recipe's own error.  **The gate was not widened
  to catch it**, which is the same discipline as S1 in the B-ACCURACY writeup.

### Blind spots of the oracles themselves -- neither widened

- **The output-grid normalisation.**  `gdn_emit_chain` B4 (site 13 keeps one bit
  less headroom, in the C and the RTL) takes `y_exp` from 10 to 9 on both
  blocks, i.e. it makes the output grid one octave coarser -- and the oracle
  measures error "in LSB of the OUTPUT grid".  The absolute error doubles and
  the LSB doubles with it, so the figure moved 1.1280 -> **0.8505**, in the
  wrong direction.  **A metric normalised by the quantity being mutated cannot
  see the mutation.**  Catching it needs an absolute-unit error or a separate
  assertion on `y_exp` against the oracle's own exponent.
- **The whole-case `sat_any` exclusion.**  Both `gdn_head_emit` and
  `gdn_y_emit` skip a case entirely from the oracle when any element saturated.
  A mutation that narrows the output rail from 16 bits to 15 therefore
  *removes* cases from the oracle rather than failing it.  MEASURED, y_emit:
  `cases that would saturate at a 15-bit rail: 41 of 48`, and the generator
  reports `all-zero cases: 7`; 41 + 7 = 48, so the oracle is evaluated on
  nothing but the all-zero cases and reports 0.0000.  head_emit: 49 + 15 = 64,
  identical shape.  **The oracle is not insensitive here, it is emptied.**
- **A gate at `>= 1.0` decided by double representability.**  `gdn_y_emit` B3
  (requantize truncates, in both) survives at
  `0.99999999999998757 LSB` -- the table's "1.0000" is `%.4f` rounding, not a
  pass at 1.0.  The SAME mutation in `gdn_head_emit` lands on exactly `1` and
  fails.  One recipe error, two opposite verdicts, separated by 1.2e-14.

## 6. Measurement traps hit

- **A committed vector file means the generator is never run.**  All seven of
  these are committed.  A C-side or BOTH-class mutation driven through
  `sim/regress.sh` therefore does nothing at all, and the generator's own
  accuracy gate -- which for three of the seven is the ONLY accuracy gate -- is
  never consulted by the gate.  This is the same trap B-ACCURACY recorded for
  `gdn_recur_vec.txt`, and it applies far more widely than that one file.
- **A rail mutation that moves only the COMPARE is equivalent.**
  `rmsnorm_bf` R10 changed `om > 32767` to `om > 32766` and left the emitted
  constant at 32767, so the one input whose branch changed still emitted the
  same value.  It read as a survivor on a well-covered rail (640 saturations
  measured).  Move the value.
- **A mutation of a generic DEFAULT tests nothing** when the bench's generic map
  overrides it.  Inherited from `sim/mutate_attn_gate.sh`'s header and
  re-checked here.
- **`--stop-time` is paid by every HUNG mutant.**  `tb_gdn_emit_chain`'s honest
  run is 44.4 us of simulated time and 53 s of wall time at 3 blocks;
  `sim/regress.sh` runs it with `--stop-time=300ms`, which for a deadlocked
  mutant is hours.  The scripts use a stop time a few multiples above the real
  run and rely on `timeout` as the real bound.
- **A survivor that dies in another configuration needs its control.**  R6's
  FAIL at `Z_DELAY = 600` means nothing until the unmutated chain is shown to
  PASS at `Z_DELAY = 600`.  It does.
- **`ghdl -a` of a modified entity obsoletes the architecture that instantiated
  it**, so a probe inserted into an RTL copy requires re-analysing the bench
  afterwards.  Symptom: `architecture "sim" ... is obsoleted by entity
  "gdn_emit_chain"` and no simulation at all.
- **`%.4f` in a generator's report can hide a 1.2e-14 margin.**  See the
  `gdn_y_emit` B3 row above.

## 7. Corrections

- **CORRECTION to the dispatch, 2026-08-28.**  The dispatch said "`gdn_scalar`
  is a special case worth reporting carefully: its double oracle is reported,
  not asserted".  That is true, and it is not special: `gdn_silu` and
  `rmsnorm_bf` have exactly the same shape (their figures are printed by the
  generator instead of by the bench, which is a difference of location, not of
  kind), and `gdn_head_emit`, `gdn_y_emit` and `gdn_emit_chain` do assert but
  only inside a generator the gate never runs.  **Six of the seven units have
  no accuracy gate that `sim/regress.sh` can fail.**  `gdn_conv` is the only one
  whose real-valued check is inside the bench.
- **CORRECTION to the dispatch, 2026-08-28.**  The brief stated that
  `tb_gdn_head_emit` checks that back-pressure was asserted at least once.  It
  does not.  `ready_fell` is printed at line 258 at `severity note` and is never
  compared or counted into `nerr`, so a DUT whose `in_ready` never falls passes.
  Reported, not asserted.

## 8. Open, not yet answered

- Whether `sim/gdn_conv_vec.txt` should be regenerated, and what else that
  changes.  It restores the `err_seg` coverage `9cfdbd2` added, but it changes a
  golden four tracks are running against today.  Not done here.
- Whether `sim/regress.sh` should pass `-gZ_DELAY` to `tb_gdn_emit_chain`.  The
  measurement says the gate is blind to the `z_have` defect without it.  Adding
  it is a change to a SHARED file and was not made.
- Whether `gdn_scalar`'s sentinel-cancellation band (cases 262 and 270) is
  reachable from the real Qwen3.5-9B / 27B weights.  Argued nowhere, measured
  nowhere.
- Back-pressure on `gdn_y_emit`'s `in_ready` is unexercised by every bench in
  the repo.  Closing it needs a stallable y consumer, which is a bench change.
- `gdn_conv` defect B-3b (`cw_exp` read live rather than latched) has no bench
  anywhere.
- `gdn_recur` and `gdn_exp_capture` still have no mutation harness.  They were
  explicitly deprioritised and are NOT covered by this work.
- Whether any of the 37 survivors would change verdict at generic settings other
  than the shipped one.  Only `gdn_emit_chain` was swept (`Z_DELAY`, `COL_GAP`,
  `OVERLAP`, block count).
