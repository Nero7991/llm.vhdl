# The attention mutation harnesses could not tell a kill from a crash, and sixteen generators had no seed

2026-08-29. TRACK ATTN-HARNESS. GHDL 1.0.0 mcode, `Oren-Dell-Ubuntu`, repo
`/home/orencollaco/GitHub/llama.vhdl` at branch `fpga`.

---

## 1. The question, verbatim

> **PART 1 (PRIORITY): published kill ratios in subsystem C may be inflated**
>
> TRACK CD-SEED measured this and did not change it:
>
> > `sim/mutate_attn_*.sh` judge with `ghdl -r ... && grep -q PASS`, so **a run
> > that DIED scores as a KILL**. The `mutate_ref_*` harnesses do it correctly.
> > **This makes published kill ratios from the attn harnesses unsafe to read at
> > face value.**
>
> A mutation that makes the simulator abort -- an out-of-range index, a failed
> assert, an elaboration error -- produces no PASS line, so the harness records
> it as caught by the checker. But **the checker never ran.** The mutation was
> caught by the language, or by nothing at all if the abort is unrelated to what
> the checker watches.
>
> **What I want:**
>
> 1. **Fix the judging** in every `sim/mutate_attn_*.sh`, with ABORT as a third
>    verdict counted separately.
> 2. **RE-MEASURE the published ratios** and report the difference.
> 3. **Report any mutation that moves from KILLED to SURVIVED**, because that is
>    a coverage hole that has been hidden.
> 4. Check whether the same pattern exists in `sim/mutate_seq_*.sh`, and fix it
>    there too if so.
>
> **PART 2: sixteen generators want a seed argument** [...] Give them a seed
> argument, **one uniform convention**, and say what it is. **THE ABSOLUTE
> REQUIREMENT: each generator MUST reproduce its committed vector file
> byte-identically at the default seed.**

---

## 2. The answer, up front

**PART 1.** The defect is real, it is in all nine `sim/mutate_attn_*.sh` and in
four of six `sim/mutate_seq_*.sh`, and it cost **11 rows across 8 harnesses**
their status as checker kills. No published ratio was off by more than 2, but
two of the moves matter far more than their size:

- **`sim/mutate_attn_rope.sh` P18 is killed by the LANGUAGE, in all three
  configurations.** `ghdl-mcode:error: index (32) out of bounds (0 to 31)` at
  `rtl/attn_rope.vhd:482`, before `tb_attn_rope` prints a single line. The
  published claim is "RTL **30/30**, no survivors". It is 28 of 30, one killed
  by VHDL, one seen only as a deadlock.
- **`sim/mutate_attn_emit.sh`'s configuration B WEDGES ON THE UNMUTATED
  DESIGN.** MEASURED: `-gM_GAP=0 -gACK_LAG=0` on the clean `rtl/attn_emit.vhd`
  produces **zero lines of output** and runs to the 20 ms stop time. Under the
  old judging that silence scored as a KILL on all 22 rows, and **two rows,
  E18 and E19, had no other evidence at all**. That harness had no control row,
  so nothing ever asked the question.

Three further findings fell out:

- **The same mutation is an ABORT in five separate harnesses.** "An explicit
  `done_r` clear inside the ack branch (the gdn_head_emit shape)" is `attn_emit`
  E18, `attn_gate` M21, `attn_twiddle` N19, `attn_softmax` M5 and `attn_recip`
  N14. In every one of the five it is detected **only as a deadlock**, never by
  a value or protocol check. That is one systematic hole in subsystem C's
  auxiliary benches, not five coincidences.
- **`sim/mutate_attn_kv_axi.sh` B1 and B4 are killed by a `bound check failure`
  inside the mutated RTL** (`attn_kv_axi.vhd:765`), against that harness's own
  header claim that "every mutation is well-formed VHDL and in bounds, so a KILL
  is the checker noticing and not the language noticing". It was false for 2 of
  its 28 rows.
- **No mutation moved from KILLED to SURVIVED.** It cannot: the fix only
  reclassifies runs that previously scored as kills, and a run that printed PASS
  was already a survivor. The nearest thing to a hidden coverage hole is
  `attn_emit` E18/E19, whose only killer was a column that fails on the clean
  design; they are survivors in all but name.

**PART 2.** All sixteen generators now take a seed, under one convention:
**the seed is the LAST optional positional argument, `$VEC_SEED` is the
fallback, and the committed default is used when neither is given.** Every one
of the sixteen reproduces byte-identically at the default seed --
**8 verified with `cmp` against `git show HEAD:sim/<name>_vec.txt`**, the other
8 (which have no committed golden) against the output of the **HEAD build of
their own generator**. The knob was demonstrated to arrive by running each at
seeds 7 and 99 and confirming three distinct outputs.

**Doing that found a seventeenth inert knob.** `ref/attn_mac_array_vec.c`
re-seeds `rs = 0xC0FFEEu` inside its mutant loop ("same stimulus for every
mutant"), which silently discarded the new seed argument: the generator printed
`seed 7 [argv]` and emitted a byte-identical file at every seed. Fixed by
capturing the seed in `rs0` and resetting to that. This is the same defect
`sim/mutate_gdn_recur.sh` carried, in a different file.

---

## 3. The procedure, in the order it was run

Each step isolates one thing. The order matters: the classifier had to be
written and teeth-checked against *existing* logs before any harness was
edited, so that a change in the numbers could not be a change in the runner.

1. **Read one harness's judging idiom and reproduce it unchanged.**
   `SCRATCH=... bash sim/mutate_attn_recip.sh`, 41 s, 15 rows. This is the
   BEFORE picture and it is taken from the committed script, not from memory.
2. **Write the classifier and run it over those existing logs**
   (`sim/mutverdict.py`). Nothing is re-simulated. Any difference between its
   verdicts and the harness's is therefore a difference of JUDGEMENT, with the
   simulation held fixed. This is what isolates the judging defect from every
   other cause.
3. **Confirm the classifier has teeth in both directions** on the same logs:
   it must find PASS where the harness found a survivor (it did, 8 of 45 runs)
   and ABORT where the harness found a kill (it did, `N14/run_B`).
4. **Patch the eleven uniform harnesses mechanically**, from one script, so all
   eleven get the identical judging rather than eleven hand edits. Syntax-check
   every one with `bash -n`.
5. **Patch the four irregular ones by hand** (`attn_kv_axi`, `attn_kv_seam`,
   `seq_tbl_shape`, `seq_vec_issue`), each of which had a different shape.
6. **Add a CONTROL row to twelve harnesses**: the unmutated design through the
   same `mutate()` path with an identity substitution. This is the step that
   caught `attn_emit` config B. `sim/mutate_seq_tbl_shape.sh` and
   `sim/mutate_attn_kv_seam.sh` already had controls; the rest did not.
7. **Re-run all fifteen harnesses** (3 at a time, to keep the wall-clock
   `timeout` rows in `seq_opdec` and `seq_vec_res` off a loaded box).
8. **PART 2, before touching any generator:** build every generator from
   `git show HEAD:ref/<g>_vec.c` and record its output. That is the baseline the
   byte-identity claim is made against, and it is taken from git rather than
   from `sim/`, because a working-tree golden is not a golden.
9. Patch the sixteen, rebuild, re-run at the same arguments, `cmp` both ways.
10. Sweep seeds 7 and 99 **with every shape argument supplied explicitly**, so
    the seed lands at the index it is supposed to. The first attempt did not,
    and it is what exposed `attn_mac_array` (below, section 6).
11. Re-run the three `sim/mutate_ref_attn_*.sh` harnesses, which mutate the
    generator sources by text anchor, to prove no anchor was broken.
12. Full unfiltered `sim/regress.sh`.

The self-isolation guard from `sim/regress.sh:307` was added to all fifteen
harnesses **first**, before any of them was run, because this track edits
mutation harnesses while other tracks may run them, and bash reads a script by
byte offset.

---

## 4. The evidence

### 4.1 The classifier, run over the pre-existing `attn_recip` logs

Simulation held fixed; only the judgement changes.

```
N12/run_B.log          PASS
N13/run_B.log          PASS
N14/run_A.log          PASS
N14/run_B.log          ABORT:WEDGE
N14/run_C.log          PASS
N15/run_B.log          PASS
```

`N14` is the whole point. Old judging: `ghdl -r` returned non-zero or no PASS in
config B, so `killers=" B"`, so `N14 KILLED`. New judging: config B ran to
`--stop-time=900ms` and printed nothing.

```
$ tail -1 N14/run_B.log
/usr/bin/ghdl-mcode:info: simulation stopped by --stop-time @900ms
```

### 4.2 `sim/mutate_attn_emit.sh` config B on the CLEAN design

```
$ ghdl -r --std=08 -frelaxed --workdir=$D tb_attn_emit \
    -gNCASE=40 -gNGRP=2 -gGRP_N=48 -gVECS=$V \
    -gM_GAP=0 -gACK_LAG=0 --max-stack-alloc=0 --stop-time=20ms
cfg A -> PASS
cfg B -> ABORT:WEDGE
cfg C -> PASS

$ wc -l ctl_B.log
1 ctl_B.log
$ cat ctl_B.log
/usr/bin/ghdl-mcode:info: simulation stopped by --stop-time @20ms
```

One line. Not the heartbeat, not a report, not an assertion. The mechanism is in
`sim/tb_attn_emit.vhd:455`: at `ACK_LAG = 0` the bench sets `done_ack <= '1'`
once, before `start`, and holds it. The DUT's `done_r` is then cleared in the
same cycle it is raised, and the bench's `while done /= '1' loop wait until
rising_edge(clk); end loop` at `:486` never observes it. **This is a defect in
`sim/tb_attn_gate.vhd`'s sibling, `sim/tb_attn_emit.vhd`, not in
`rtl/attn_emit.vhd`.** It is REPORTED, not fixed: this track does not own that
file. The control row now prints it on every run.

The control row's output, from the committed harness:

```
CTL  ABORT   aborted: B(WEDGE)   survived: A C   -- CONTROL: the UNMUTATED design.  Every config must say SURVIVED
```

### 4.3 `sim/mutate_attn_rope.sh` P18, killed by VHDL

```
$ tail -4 P18/run_A.log
/usr/bin/ghdl-mcode:error: index (32) out of bounds (0 to 31) at .../P18/attn_rope.vhd:482
in process .tb_attn_rope(tb).dut@attn_rope(rtl).P15
  from: process work.attn_rope(rtl).P15 at attn_rope.vhd:482
/usr/bin/ghdl-mcode:error: simulation failed
$ wc -l P18/run_A.log
4
```

All three configurations, identically. `tb_attn_rope` never reached a verdict.

### 4.4 `sim/mutate_attn_kv_axi.sh` B1 and B4, killed by VHDL

```
/usr/bin/ghdl-mcode:error: bound check failure at .../B1/attn_kv_axi.vhd:765
in process .tb_attn_kv_axi(sim).h128@kv_axi_harness(sim).dut@attn_kv_axi(rtl).gen_rd(1).p_rd
/usr/bin/ghdl-mcode:error: simulation failed
```

### 4.5 Published against re-measured

Mutation rows only; the CONTROL row is excluded from every "of N" below.
"Published" is the figure in `docs/2026-08-28_9b-completeness-audit.md:229-235`,
the harness's own header, or the named debugging note.

| harness | published | re-measured (killed / ABORT / survived) | moved |
|---|---|---|---|
| `mutate_attn_twiddle` | RTL **22/22**, no survivors | 21 / 1 / 0, of 22 | N19 -> ABORT(WEDGE) |
| `mutate_attn_rope` | RTL **30/30**, no survivors | 28 / 2 / 0, of 30 | P18 -> ABORT(**LANG**), P25 -> ABORT(WEDGE) |
| `mutate_attn_softmax` | 14 of 16, 2 survivors | 13 / 1 / 2, of 16 | M5 -> ABORT(WEDGE) |
| `mutate_attn_recip` | **13/15**, 2 survivors | 12 / 1 / 2, of 15 | N14 -> ABORT(WEDGE) |
| `mutate_attn_gate` | 3 survivors of 26, i.e. 23 killed | 22 / 1 / 3, of 26 | M21 -> ABORT(WEDGE, **all 3 configs**) |
| `mutate_attn_emit` | RTL **21/22** | 20 / 2 / 0, of 22 | E18, E19 -> ABORT(WEDGE); **control RED** |
| `mutate_attn_rescale` | none published | 25 / 0 / 0, of 25 | none |
| `mutate_attn_kv_axi` | "the two survivors", i.e. 26 of 28 | 24 / 2 / 2, of 28 | B1, B4 -> ABORT(**LANG**) |
| `mutate_attn_kv_seam` | none published as a ratio | 12 / 0 / 7, of 19 (+4 controls) | none |
| `mutate_seq_desc_fetch` | 6 of 8 | 6 / 0 / 2, of 8 | none |
| `mutate_seq_opdec` | **11 of 11** | 11 / 0 / 0, of 11 | none |
| `mutate_seq_region_lock` | 7 of 7 | 7 / 0 / 0, of 7 | none |
| `mutate_seq_vec_res` | 19 of 20 | 19 / 0 / 1, of 20 | none |
| `mutate_seq_vec_issue` | 11 of 16 | 11 / 0 / 5, of 16 | none |
| `mutate_seq_tbl_shape` | 10 checker + 1 language + 5 survived | 10 / 1 / 5, of 16 | none (it already scored this way) |

**Totals: 11 rows across 8 harnesses moved from KILLED to ABORT. Zero moved to
SURVIVED.** Every `mutate_seq_*` harness except `seq_tbl_shape` had the same
two-way judging defect in its code and was fixed, but **none of them produced a
single ABORT**, so no published sequencer figure changes. That is worth saying
plainly: the defect was everywhere, the damage was concentrated in subsystem C.

### 4.6 The five-harness pattern

| harness | tag | configs that abort | configs that PASS |
|---|---|---|---|
| `attn_emit` | E18 | B (WEDGE) | A, C |
| `attn_gate` | M21 | A, B, C (WEDGE) | none |
| `attn_twiddle` | N19 | B (WEDGE) | A, C |
| `attn_softmax` | M5 | B (WEDGE) | A, C |
| `attn_recip` | N14 | B (WEDGE) | A, C |

One mutation, "an explicit `done_r` clear inside the ack branch", five units,
and **not one of the five benches detects it with a check**. Four of the five
pass it outright in the shipped configuration and only deadlock in the
degenerate one -- and for `attn_emit`, the degenerate one is the column that
fails on the clean design too, so `attn_emit` has no evidence at all.

### 4.7 PART 2, byte-identity at the default seed

```
GENERATOR          vs HEAD    vs git show HEAD:sim/...     seed line
gdn_recur          IDENTICAL  IDENTICAL to committed       seed 20260825  [committed default]
gdn_conv           IDENTICAL  IDENTICAL to committed       seed 20260826  [committed default]
gdn_scalar         IDENTICAL  IDENTICAL to committed       seed 11400714819323198485  [committed default]
gdn_head_emit      IDENTICAL  IDENTICAL to committed       seed 20260826  [committed default]
gdn_y_emit         IDENTICAL  IDENTICAL to committed       seed 20260827  [committed default]
gdn_emit_chain     IDENTICAL  IDENTICAL to committed       seed 20260827  [committed default]
attn_recip         IDENTICAL  (not committed)              seed 20260830  [committed default]
attn_rope          IDENTICAL  (not committed)              seed 20260903  [committed default]
attn_gate          IDENTICAL  (not committed)              seed 20260831  [committed default]
attn_emit          IDENTICAL  (not committed)              seed 20260901  [committed default]
attn_rescale       IDENTICAL  (not committed)              seed 1592614637  [committed default]
attn_softmax       IDENTICAL  (not committed)              seed 20260829  [committed default]
attn_twiddle       IDENTICAL  (not committed)              seed 20260902  [committed default]
attn_kv_quant      IDENTICAL  IDENTICAL to committed       seed 20260827  [committed default]
attn_score_q12     IDENTICAL  IDENTICAL to committed       seed 20260828  [committed default]
attn_mac_array     IDENTICAL  (not committed)              seed 12648430  [committed default]
```

`attn_rescale`'s `0x5eed5eed` prints as **1592614637**, which is the trap this
track was warned about and which the printed line now removes: the seed a run
used is no longer something anyone has to convert by hand.

`git status --short sim/` after the whole exercise showed **no committed golden
in `sim/` modified**. Every generator ran either in the scratchpad or, for
`gdn_recur` (which opens `ref/gdn_eg_qwen3_27b.txt` by a relative path), from
the repo root with an absolute output path.

### 4.8 PART 2, the knob demonstrably arrives

Seeds 7 and 99, every shape argument supplied explicitly:

```
GENERATOR          stderr at default        stderr at seed 7      def-vs-7  7-vs-99  VEC_SEED=7 == argv 7
attn_twiddle       seed 20260902 [committe  seed 7  [argv]        DIFF      DIFF     YES
attn_emit          seed 20260901 [committe  seed 7  [argv]        DIFF      DIFF     YES
attn_rope          seed 20260903 [committe  seed 7  [argv]        DIFF      DIFF     YES
attn_kv_quant      seed 20260827 [committe  seed 7  [argv]        DIFF      DIFF     YES
attn_score_q12     seed 20260828 [committe  seed 7  [argv]        DIFF      DIFF     YES
attn_rescale       seed 1592614637 [commit  seed 7  [argv]        DIFF      DIFF     YES
attn_softmax       seed 20260829 [committe  seed 7  [argv]        DIFF      DIFF     YES
gdn_emit_chain     seed 20260827 [committe  seed 7  [argv]        DIFF      DIFF     YES
attn_gate          seed 20260831 [committe  seed 7  [argv]        DIFF      DIFF     YES
gdn_conv           seed 20260826 [committe  seed 7  [argv]        DIFF      DIFF     YES
gdn_y_emit         seed 20260827 [committe  seed 7  [argv]        DIFF      DIFF     YES
gdn_head_emit      seed 20260826 [committe  seed 7  [argv]        DIFF      DIFF     YES
attn_recip         seed 20260830 [committe  seed 7  [argv]        DIFF      DIFF     YES
gdn_scalar         seed 11400714819323198485 [committed default] / seed 7 [argv]
                                                                  DIFF      DIFF     YES
gdn_recur          seed 20260825 [committed default] / seed 7 [argv]
                                                                  DIFF      DIFF     YES
attn_mac_array     seed 12648430 [committe  seed 7  [argv]        DIFF      DIFF     YES   (after the rs0 fix)
```

`attn_mac_array` before the fix, at one fixed shape and three seeds:

```
$ for s in "" 7 99; do bin/attn_mac_array y_${s:-d}.txt 64 4 128 32 24 $s; done
seed 12648430  [committed default]
seed 7  [argv]
seed 99  [argv]
765697aa9a6cb1d3fa00c05f07fd7bcc  y_d.txt
765697aa9a6cb1d3fa00c05f07fd7bcc  y_7.txt
765697aa9a6cb1d3fa00c05f07fd7bcc  y_99.txt
```

and after:

```
a2b9e76b8970607cf2d4a5fa71636d0c  v_d.txt
b68bc6b18ba6e7b7312f853a68544319  v_7.txt
1b77f39a4b21c2d4a993a133582f9081  v_99.txt
```

with `v_d.txt` still `cmp`-identical to the HEAD build's output.

### 4.9 The convention

Stated once, in `ref/vec_seed.h`, and identical for all sixteen:

1. The seed is the **LAST optional positional argument** the generator accepts,
   after every shape argument, so no existing caller moves and no
   `tb_vector_args` row in `sim/regress.sh` changes.
2. If it is absent or empty, **`$VEC_SEED`** is used.
3. If that is absent or empty, the **committed default** is used, and the output
   is byte-identical to the committed golden.
4. Both accept decimal, `0x` hex and octal (`strtoull` base 0).
5. **The seed is always printed to stderr**, with whether it was the default or
   an override. stdout is where two of these generators write their vector file.
6. **A zero seed is refused** and falls back to the default, saying so: zero is
   a fixed point of `x ^= x<<13; x ^= x>>7; x ^= x<<17`, so a zero seed produces
   an infinite run of zeros, which does not look like an error -- it looks like
   a suspiciously clean pass.

Per-generator seed argument index (argv, 1-based, `argv[1]` is the output file
except for `gdn_scalar` which writes to stdout and takes `SP_Q` as `argv[1]`):

| generator | index | default |
|---|---|---|
| `gdn_recur` | 4 | 20260825 |
| `gdn_conv` | 2 | 20260826 |
| `gdn_scalar` | 2 | 0x9E3779B97F4A7C15 |
| `gdn_head_emit` | 4 | 20260826 |
| `gdn_y_emit` | 5 | 20260827 |
| `gdn_emit_chain` | 5 | 20260827 |
| `attn_recip` | 4 | 20260830 |
| `attn_rope` | 5 | 20260903 |
| `attn_gate` | 4 | 20260831 |
| `attn_emit` | 5 | 20260901 |
| `attn_rescale` | 3 | 0x5eed5eed |
| `attn_softmax` | 4 | 20260829 |
| `attn_twiddle` | 4 | 20260902 |
| `attn_kv_quant` | 5 | 20260827 |
| `attn_score_q12` | 5 | 20260828 |
| `attn_mac_array` | `ai`+6 | 0xC0FFEE |

**What a seed sweep therefore cannot see.** It varies the STIMULUS
DISTRIBUTION and nothing else. It does not vary the recipe, the shape arguments
(`ncase`, `DIM`, `NBLK`, `N_ROT`), or the checks. Three classes stay invisible
however many seeds are run: a defect present at every input; a coverage hole in
the SHAPE, i.e. a branch no value of any input reaches at this `ncase`/`DIM`;
and an oracle that is wrong in the same way as the design. `attn_gate`'s
"2 points out of 131,071" sigmoid witness set is a concrete case: it comes from
an EXHAUSTIVE domain sweep inside the generator and is identical at seed 7 and
at the committed seed, so no amount of seed sweeping touches it.

---

## 5. Measured and REJECTED -- do not retry

- **Do NOT classify a run by `ghdl -r`'s exit status.** It is 1 for a checker
  assertion, 1 for an elaboration failure, 1 for a bound check, and **0 for a
  wedge to `--stop-time`**. `attn_recip` N14 config B and `attn_emit`'s whole
  config B exit 0 with no output. Exit status cannot separate any of the three
  cases this exercise exists to separate. The verdict must come from the LOG.
- **Do NOT key the kill on the absence of a PASS line alone.** That is the
  original defect and it is what makes a crash read as a kill. It must be the
  presence of a FAIL verdict or of a diagnostic whose SOURCE FILE is the
  checker.
- **Do NOT key the kill on `grep -q "PASS"` unanchored.** It is what all nine
  attn harnesses did. `sim/mutate_attn_rope.sh` mutates a state named `S_PASS`
  and `tb_attn_rope` prints "the pass-through region" in its coverage line; a
  bench that ever printed either in upper case would have handed every mutant a
  free survival. The classifier anchors on `<tb_entity>[:] PASS`.
- **Do NOT assume the testbench file is the only checker.** `sim/tb_attn_kv_axi.vhd`
  is a verdict wrapper; all 6 protocol checks live in `sim/kv_axi_harness.vhd`.
  Classifying only on the `tb_` file gave `mutate_attn_kv_axi` **11 killed / 15
  ABORT / 2 survived** of 28, against the true **24 / 2 / 2**. The classifier
  takes extra checker files as arguments for exactly this.
- **Do NOT sweep a seed without supplying every shape argument.** The first
  sweep passed `<outfile> <seed>` to generators whose seed is `argv[4]` or
  `argv[5]`, so the seed landed on `ncase` or `head_dim`. Five generators
  reported `[committed default]` while their output changed -- which is the
  worst possible reading, because the output moving looks like proof the knob
  works. The printed `[argv]`/`[committed default]` tag is what caught it.
- **Do NOT read `attn_mac_array`'s seed sensitivity at only one shape.** The
  first check compared a default-shape run against an explicit-shape run and
  concluded the seed worked. It did not; the SHAPE had changed. Hold every other
  argument fixed.
- **Do NOT "fix" `sim/mutate_attn_emit.sh` config B by changing its generics.**
  It was considered and rejected: retuning `-gM_GAP` / `-gACK_LAG` to something
  that runs would hide the bench defect instead of reporting it, and this track
  does not own `sim/tb_attn_emit.vhd`. The control row exposes it on every run
  and the defect is written down here instead.
- **Do NOT fold `KILLED(HANG)` in `sim/mutate_attn_kv_seam.sh` into ABORT.**
  That row is `sim/tb_attn_kv_seam.vhd`'s own residency watchdog firing at
  severity failure, from the bench file. It is the checker noticing. The
  classifier gets this right for free because it keys on the source file, and
  the harness's extra grep only says which check bit.

---

## 6. Measurement traps hit, including my own

1. **A `.*?` in a multi-line regex started at the wrong `if`.** The first
   mechanical patch of the eleven harnesses matched from the FIRST `if ` in
   `mutate()` -- the anchor-failure check, 30 lines earlier -- and swallowed the
   analyze block. `bash -n` caught it on all eleven; the fix was to anchor the
   pattern at `for c in $CFGS; do`. **Nothing was committed in that state and
   `git checkout --` restored all eleven.** A mechanical patch across many files
   needs a syntax gate per file, not a spot check on one.
2. **`index (32) out of bounds (0 to 31)` does not contain the substring
   `index out of bounds`.** The first classifier draft matched that literal and
   returned `NOVERDICT` for `attn_rope` P18, which is the single most important
   row in this whole exercise. The spellings in `sim/mutverdict.py` are now
   MEASURED against real `ghdl-mcode` output, not guessed.
3. **My own classifier was wrong in the "safe" direction and that is still
   wrong.** Calling `kv_axi_harness.vhd`'s asserts `DUTASSERT` made
   `mutate_attn_kv_axi` look far worse than it is (11/28 rather than 24/28). A
   pessimistic classifier is not a conservative one; it manufactures a false
   alarm that costs the next reader a day.
4. **A "different output" is not proof a seed arrived.** See section 5. The
   printed provenance tag is the only cheap defence.
5. **`gdn_recur_vec.c` opens `ref/gdn_eg_qwen3_27b.txt` by a relative path**, so
   it must be run from the repo root. Run anywhere else it prints
   `gdn_eg_qwen3_27b.txt missing` and exits 1, which in a loop that discards
   stderr looks exactly like a generator that produced nothing.
6. **`gdn_emit_chain`'s committed golden is at the generator's DEFAULTS
   (`NB=6`), not at `sim/regress.sh`'s `tb_vector_args` row (`3 24 128`).**
   417,845 bytes against 209,303. Comparing the regress arguments against the
   committed file would have read as a corrupted golden.
7. **Two generators `#include` another generator's `.c`** -- `attn_rope_vec.c`
   includes `attn_twiddle_vec.c`, `attn_gate_vec.c` includes
   `attn_recip_vec.c`. Both inner PRNGs and both inner `main`s sit inside
   `#ifndef ATTN_TWIDDLE_INCLUDE` / `#ifndef ATTN_RECIP_INCLUDE`, so nothing is
   duplicated and exactly one `seed` line is printed per run (verified by
   `grep -c '^seed '`). Had the guards not been there, seeding the outer
   generator would have left the inner one on its committed seed silently.
8. **The totals printed by the patched harnesses include the CONTROL row.**
   `attn_twiddle` reports "of 23" for 22 mutations. The summary now says so in
   as many words, and every "of N" in section 4.5 excludes it.

---

## 7. Explicitly NOT verified

- **`sim/tb_attn_emit.vhd`'s `ACK_LAG = 0` deadlock is DIAGNOSED, not fixed and
  not proven.** The mechanism given in 4.2 is read off `:455` and `:486` and is
  consistent with the observed silence; it was not confirmed by instrumenting
  the bench, because this track does not own that file.
- **Whether the 11 ABORT rows would SURVIVE if their abort were removed.**
  Answering that means changing the mutation or the bench so the checker gets to
  run, which is a different exercise. What is established is only that the
  checker was never shown to see them.
- **`sim/mutate_attn_kv_seam.sh`'s numbers may reflect an in-flight file.** It
  builds against `rtl/attn_block.vhd`, which TRACK C1 was editing during this
  run. Its 12 / 0 / 7 should be re-taken once C1 lands.
- **No control row was added to `sim/mutate_seq_vec_issue.sh`.** Its mutants come
  from a Python manifest rather than from a `mutate()` call, so the identity-row
  trick does not apply. It is the one multi-config harness still without a
  control.
- **`sim/mutate_gdn_*.sh` were not re-run.** They are not this track's files.
  Their generators changed (a seed argument and an extra stderr line), and the
  three `sim/mutate_ref_attn_*.sh` harnesses were re-run to prove text anchors
  survived, but the six `mutate_gdn_*` harnesses were not.
- **`sim/mutate_gdn_recur.sh`'s SEED knob is still absent.** Its header now
  describes a limitation that no longer exists (`ref/gdn_recur_vec.c` takes a
  seed as `argv[4]`), but that file belongs to another track.
- **The published `attn_rescale` ratio.** No prior figure was found to compare
  against; 25 / 0 / 0 of 25 is recorded here as the first one.
- **Nothing here says the surviving mutants are equivalent.** The pre-existing
  prose in each harness that reads each survivor was not re-audited.

---

## 8. Files changed

- `sim/mutverdict.py` (new) -- the three-way classifier, one implementation for
  all fifteen harnesses.
- `ref/vec_seed.h` (new) -- the seeding convention.
- `sim/mutate_attn_{emit,gate,kv_axi,kv_seam,recip,rescale,rope,softmax,twiddle}.sh`
- `sim/mutate_seq_{desc_fetch,opdec,region_lock,tbl_shape,vec_issue,vec_res}.sh`
- `ref/{gdn_recur,gdn_conv,gdn_scalar,gdn_head_emit,gdn_y_emit,gdn_emit_chain}_vec.c`
- `ref/{attn_recip,attn_rope,attn_gate,attn_emit,attn_rescale,attn_softmax,attn_twiddle,attn_kv_quant,attn_score_q12,attn_mac_array}_vec.c`

No RTL and no testbench was changed. `sim/regress.sh` was not changed.

---

## 9. The gate, full and unfiltered

Run at `ec1ec41` with every harness and generator change in place, no `--only`,
no `--quick`:

```
 suite sim   PASS 62   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 88   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 88 passing, matches the recorded floor of 88
 REGRESSION: PASS
```

That is the LAST `OVERALL` line in the log, and `BASELINE_PASS` was 88 at the
moment of the run. `sim/regress.sh` was not edited by this track; the floor was
raised to 88 earlier the same day by the `tb_llama_top_normw` track.

The gate exercises the sixteen patched generators directly: `tb_vector_args`
regenerates `attn_emit_vec.txt`, `attn_gate_vec.txt`, `attn_recip_vec.txt`,
`attn_softmax_vec.txt`, `attn_twiddle_vec.txt`, `attn_kv_quant_vec.txt`,
`attn_score_q12_vec.txt` and `gdn_emit_chain_vec.txt` on every run, and no row
passes a seed, so all eight came out at the committed default.

**Caveat on this number: the box was NOT quiet.** Three `tb_llama_top` runs
belonging to another track were in flight during it (`ps` showed them at 3 min
elapsed). Nothing failed, so the contention did not matter here, but a FAIL in
this log would have had to be re-run on a quiet box before being believed.

---

## 10. Corrections

None yet. Append dated CORRECTION sections here rather than editing the above.
