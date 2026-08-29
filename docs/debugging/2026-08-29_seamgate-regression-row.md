# The seam comparison as a regression gate row

2026-08-29. `xcvu33p` project, but everything here is GHDL 1.0.0 (mcode) on the
workstation; no hardware was touched. Base revision **`5578132`**, measured on a
pristine `git archive 5578132 | tar -x` tree except where a working-tree run is
stated explicitly.

## The question, verbatim

> Deliver: **the seam comparison as a regression gate row**, so a wrong number
> at the top level fails the gate with the seam named, automatically, on every
> run.
>
> The hard part: `sim/regress.sh` has **no non-VHDL row type**. TRACK REF-TOKEN
> established this and used it to reject adding a different gate row: the
> planner globs `*.vhd` and `run_one` is GHDL-only. So this needs either a
> genuine extension to `regress.sh`'s row model, or a VHDL-shaped row that
> drives the comparison. Decide which, justify it, and say what you rejected.
>
> REF-TOKEN also rejected a golden-file gate row on empirical grounds worth
> heeding: the golden it examined was **already not provably current** [...] so
> a golden row added in the morning would have been RED all day with nothing
> actually wrong. Whatever you build must not have that property.

## The answer

**Done, as a genuine extension to `regress.sh`'s row model -- 3 rows,
`sim:seamgate_{real,stub,seq}`, `BASELINE_PASS` 94 -> 99.** A VHDL-shaped row
was considered and rejected: the models are Python and C, GHDL-mcode has no way
to call them, and re-implementing them in VHDL would create a second
implementation that drifts from the first, which is the `m7 mutant` failure this
project already has on record.

The extension is small and strictly additive: the three rows are **appended to
the plan file** after the planner has run, and `run_one` dispatches on the name
before doing anything else. No existing row changes code path, no field changes
meaning, the driver loop is untouched, and the summary, per-suite tallies,
`--only`, `--quick` and `BASELINE_PASS` all work on the new rows without knowing
they exist. MEASURED on the diff: **102 lines added, of which 35 are executable
shell** and the other 67 are the comment explaining why the row exists -- one
changed `BASELINE_PASS`, one `SLOW_TBS` entry, a four-line loop appending the
plan rows, a 26-line `run_seam`, and a three-line `case` at the top of
`run_one`.

**It does not have the golden's rot property, and the reason is structural, not
a mitigation.** Nothing committed is read. Both sides are recomputed at gate
time from the tree as it stands: the machine side is a live GHDL run of
`sim/tb_llama_top.vhd` with its seam capture on, and the model side is
`tools/ref9b/{scaled_plan,vec_oracle,attn_oracle}.py` plus
`ref/{matvec_int4,attn_block_cap_vec}.c` recomputing each step **from that run's
own captured inputs**. A legitimate `rtl/` change that moves every number stays
GREEN as long as the RTL still agrees with its independent model. The gate goes
red in exactly one case: RTL and model disagree.

MEASURED at `5578132`, all three green:

| row | tokens | seams checked against a model | not checked | wall |
|---|---|---|---|---|
| `sim:seamgate_real` | 1 | **61** | `R_Y-0/1/2` (subsystem B) | 38 s |
| `sim:seamgate_stub` | 1 | **60** | the above + `R_Y-3` (attention ramp) | 30 s |
| `sim:seamgate_seq`  | 3 | **59 per token** | `R_Y-0/2` (subsystem B) | 143 s |

And the row goes RED with the seam named, in the summary line itself, on an
injected defect:

```
FAIL       sim:seamgate_real                     38s  SEAMGATE FAIL (DIVERGENCE) -- real token 0: a modelled seam does not | FIRST DIVERGENCE: R_X.attn-0 at element 0 -- expected -32042, captured -32043 (exponent 11 vs 11, 32 of 64 mantissas differ)
 OVERALL     PASS 0   FAIL 1   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: FAIL
```

## How it distinguishes "the model changed" from "the machine is wrong"

Four verdicts, not two, because conflating them is what makes a gate get
ignored:

| verdict | means | who acts |
|---|---|---|
| **DIVERGENCE** | a modelled seam disagrees with its model, given the machine's own inputs. The seam and the element are named. | whoever moved the RTL or the model |
| **PLAN DRIFT** (`bisect_scaled.py` rc 2) | the model's mirror of the descriptor plan no longer describes the capture, so it **refused to compare**. THE MODEL IS STALE and the machine has not been judged at all. | whoever moved `sim/llama_sched_pkg.vhd` |
| **COVERAGE** | every compared seam matched, but fewer seams were compared than the recorded floor. | whoever removed a model |
| **HARNESS** | the comparator produced no verdict line (a Python traceback exits 1, which is also the divergence code). Nothing has been judged. | whoever broke `tools/ref9b` |

The residual, stated plainly because it is real: **landing a new fixed-point
recipe in `rtl/` turns these rows red until the model in `tools/ref9b/` follows
it.** That is deliberate and it is not the golden's failure mode. The golden went
red on a *correct* change with nothing to do about it but re-capture. This goes
red on a change whose oracle has not been updated, and the fix is to update the
oracle -- which is the project's own standing rule ("a per-unit evidence class
says nothing about the composition; ask whether an oracle exists at the level of
the thing's OUTPUT"). `l2norm_rs` shipped with a tolerance and no model once
already.

## One thing that is easy to misread

The capture runs `sim/tb_llama_top.vhd` through `capture_llama_top.sh`, which
passes the SHAPE generics and **not** the four `EXP_*` landmarks. So the capture
run prints `P14 -- NO VALUE GATE` and its own `RESULT: PASS` is a statement about
schedule, skew across latency points and degenerate residuals -- not about
values. That is deliberate: the landmarks are checked by `sim:tb_llama_top_real`
and its siblings, and these rows are the independent second instrument. MEASURED:
the S4 mutant fails the landmark row and reaches this comparison with a clean
`RESULT: PASS`. **Do not read the capture's PASS line as a value verdict.**

## The procedure, in the order it was run

1. **Establish the base.** `git rev-parse HEAD` -> `5578132`;
   `git status --porcelain --untracked-files=no` -> only `hw/design_mv_generated.tcl`,
   nothing under `rtl/`, `sim/` or `tools/`. Extracted `git archive 5578132` to
   scratch and worked there, so nothing another track was editing could be read
   or clobbered. (OI3B found `sim/tb_llama_top.vhd` carrying 204 uncommitted
   lines earlier the same day.)
2. **Does the comparison pass TODAY, on all three configurations?** If it does
   not, there is no gate to build and the finding is that instead. Ran
   `capture_llama_top.sh` + `bisect_scaled.py` by hand for `real`, `stub` and
   `seq`. All three green. This is the step that decides whether the rest of the
   work is possible, and it was done before any code was written.
3. **Read `regress.sh`'s actual row model** rather than trusting the brief's
   summary of it: the planner (`:783` `SUITE_DIRS`, the `tb_*.vhd` glob), the
   7-field tab-separated plan row, `run_one`'s contract (`ghdl -a` over a file
   list, then `ghdl -r` on a top entity), the `FAIL_RE`/`PASS_RE` judge, the
   driver loop, and the `$SCRATCH/res.<suite>_<name>` record the summary reads.
4. **Remove the duplicated shape.** The generics a configuration elaborates and
   the `bisect_scaled.py` arguments that describe it are one fact written twice,
   and `--norm` is the half no automatic check covers -- guessing it wrong makes
   every norm seam read as a defect (first-bisect trap T5, already paid for
   once). Put the bisect args one line under the generics in
   `capture_llama_top.sh`'s own `case`, readable with `LIST_BISECT=1`. Same rule
   `LIST_FILES=1` exists for.
5. **Write `tools/ref9b/seamgate.sh`**, one verdict per configuration, runnable
   standalone with the same meaning it has as a row.
6. **Teeth**, `tools/ref9b/mutate_seamgate.sh`, seven rows including the ones
   that do not bite.
7. **Wire it in**, and show the row PASS in the working tree and FAIL inside a
   mutated copy of the tree.
8. **Full unfiltered both-suite run** to confirm the shared gate is not red for
   anybody else.

## The evidence

### Clean, at `5578132`, on a `git archive` tree

```
$ SMP=1 CAPTURE_REV=5578132 bash tools/ref9b/capture_llama_top.sh real ...
tb_llama_top: seam capture wrote 65 records to cap.txt, capture/dump disagreements=0
tb_llama_top: logits capture: holes=0 out-of-range indices=0 count disagreements=0 design FIFO overflow='0'
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run, 1 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -16364 hash(R_X) = 91622
# HEAD 5578132  SMP=1
real	0m37.586s

$ python3 bisect_scaled.py cap_real.txt --blocks 4 --attn-int 4 --attn-hd 16 --norm real --w-image ...
# stepwise oracle, token 0, shape blocks=4 attn_interval=4 attn_hd=16 hidden=64 ffn=128
# 61 seams checked against a model, 3 NOT checked
    NOT CHECKED  R_Y-0          subsystem B has no integration-level model
    NOT CHECKED  R_Y-1          subsystem B has no integration-level model
    NOT CHECKED  R_Y-2          subsystem B has no integration-level model

EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT, given the machine's own inputs.
real	0m0.286s
```

`stub` is the same shape at `--attn-hd 32 --norm anchor`, 60 checked of 64, plus
`R_Y-3` unchecked because that configuration elaborates the attention ramp
(detected from the capture, not declared by a flag). `seq` is three tokens at
`--attn-int 2 --attn-hd 64 --kv-block 16 --n-rot 16`, 59 checked of 61 on each
of tokens 0, 1 and 2.

### The finished row, in the working tree

```
$ bash sim/regress.sh --only seamgate_stub --suite sim
PASS       sim:seamgate_stub                     30s  SEAMGATE PASS -- stub: 1 token(s), at least 60 seams per token
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

```
$ bash tools/ref9b/seamgate.sh seq
tb_llama_top RESULT: PASS -- 61 descriptors, 4 blocks, 3 tokens per run, ... R_X(0) = -14252 hash(R_X) = 7668
  token 0: 59 seams bit-exact against a model, 2 not checked
      NOT CHECKED  R_Y-0          subsystem B has no integration-level model
      NOT CHECKED  R_Y-2          subsystem B has no integration-level model
  token 1: 59 seams bit-exact against a model, 2 not checked
  token 2: 59 seams bit-exact against a model, 2 not checked

SEAMGATE PASS -- seq: 3 token(s), at least 59 seams per token
real	2m23.053s
```

### The mutation table

`bash tools/ref9b/mutate_seamgate.sh [S1..S7|all]`. Every mutant is a COPY of
`rtl/ sim/ tools/ ref/` under scratch; the working tree's `rtl/` is never
touched, because three other tracks were editing it while this ran.

| # | injected defect | seam gate | landmark row `tb_llama_top_real` |
|---|---|---|---|
| **S1** | `rtl/seq_vec_res.vhd`: output rounding bias deleted (truncate, not round) | **FAIL** `R_X.attn-0` elem 0 | FAIL (all four landmarks move) |
| **S2** | `rtl/seq_vec_res.vhd`: shift floor 0 -> 1, every residual under-normalised | **FAIL** `R_X-1` elem 0, exp 10 vs 9 | FAIL |
| **S3** | `rtl/sampler_stream.vhd`: argmax comparison inverted | **FAIL** `TOKEN` elem 0, 101 vs 77 | **blind** -- that row never elaborates `SMP_EN` |
| **S4** | `rtl/gdn_silu.vhd`: SiLU emit truncates | **SURVIVES** (61 seams still bit-exact) | FAIL, `EXP_STEPH` 17333 -> 34846 |
| **S5** | comparison run with `--no-a` (models silently removed) | **FAIL (COVERAGE)** 22 checked vs floor 61 | n/a |
| **S6** | comparison asked for `--blocks 8` (plan mirror drifted) | **FAIL (PLAN DRIFT)** rc 2, refused to compare | n/a |
| **S7** | S1's mutant with the four landmarks **re-pinned** to the mutant's own values | **FAIL**, unchanged | **PASS** |

Raw, S1:

```
SEAMGATE FAIL (DIVERGENCE) -- real token 0: a modelled seam does not
    FIRST DIVERGENCE: R_X.attn-0 at element 0 -- expected -32042, captured -32043 (exponent 11 vs 11, 32 of 64 mantissas differ)
SEAMGATE FAIL -- real
  [gate rc=1]
```

Raw, S2 -- an EXPONENT-rule defect, the family a mantissa-only comparison
misses, and the same family as the `ref/run9b` `reg_put` divergence:

```
    FIRST DIVERGENCE: R_X-1 at element 0 -- expected -16088, captured -8044 (exponent 10 vs 9, 64 of 64 mantissas differ)
```

Raw, S3 -- a defect after the last region write, which `tb_llama_top_real`
structurally cannot see because it leaves `SMP_EN` at its default `false` and so
never elaborates `rtl/sampler_stream.vhd` at all:

```
    FIRST DIVERGENCE: TOKEN at element 0 -- expected 101, captured 77 (exponent 0 vs 0, 1 of 1 mantissas differ)
```

Raw, S4 -- **the row that does not bite, kept under its own name because it is
the measurement of this gate's resolution floor.** The two instruments are
complementary here, in the direction opposite to the one the brief predicted:

```
-- the landmark row on this mutant:
    tb_llama_top: P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 34846   (1 of the pinned landmarks moved)
    ...tb_llama_top.vhd:2866:7:@52463500ps:(report failure): tb_llama_top RESULT: FAIL
-- the seam gate on this mutant:
  token 0: 61 seams bit-exact against a model, 3 not checked
SEAMGATE PASS -- real: 1 token(s), at least 61 seams per token
  [gate rc=0]
```

Raw, S5 -- the silent-coverage-loss case. `bisect_scaled.py` itself exits **0**
here and prints its full "EVERY MODELLED SEAM MATCHES" verdict while comparing
22 seams instead of 63. Without a floor the row would have printed PASS:

```
  bisect rc=0
    # stepwise oracle, token 0, shape blocks=4 attn_interval=4 attn_hd=16 hidden=64 ffn=128
    # 22 seams checked against a model, 41 NOT checked
        NOT CHECKED  R_QKV.q-0      --no-a
    -> checked 22 against the row's floor of 61: BELOW, so the COVERAGE branch fires
```

Raw, S7 -- **the whole argument for this row existing.** S1's mutant again, but
with the four landmarks replaced by the values the mutant itself prints, which is
precisely what a track does when an `rtl/` change legitimately moves them. The
landmark row is then satisfied by the defective design; the seam comparison is
not, and still names the seam:

```
-- the landmark row BEFORE re-pinning:
    tb_llama_top: P14 landmarks measured -- EXP_X0 => -16366, EXP_XSUM => 48408, EXP_XALL => 48408, EXP_STEPH => 20308   (4 of the pinned landmarks moved)
    ...tb_llama_top.vhd:2866:7:@52463500ps:(report failure): tb_llama_top RESULT: FAIL
-- re-pinning sim/tb_llama_top_real.vhd to: EXP_X0 => -16366, EXP_XSUM => 48408, EXP_XALL => 48408, EXP_STEPH => 20308
-- the landmark row AFTER re-pinning:
    tb_llama_top: P14 landmarks measured -- ... (0 of the pinned landmarks moved)
    tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run, 2 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -16366 hash(R_X) = 48408
-- the seam gate on the same mutant:
SEAMGATE FAIL (DIVERGENCE) -- real token 0: a modelled seam does not
    FIRST DIVERGENCE: R_X.attn-0 at element 0 -- expected -32042, captured -32043 (exponent 11 vs 11, 32 of 64 mantissas differ)
```

Nothing about the re-pin is dishonest or careless -- it is the correct response
to a landmark moving, and OI3B deliberately made the row print a paste-ready
generic line so it costs one run. That is exactly why a change detector cannot be
the only instrument: **its failure mode is a correct-looking action taken by a
careful person.**

Raw, S6 -- the model-stale case, reported as its own class so nobody reads it as
a value defect:

```
  bisect rc=2
    # THE PLAN MIRROR DOES NOT DESCRIBE THIS CAPTURE.  Refusing to compare, because a shifted plan reports a divergence at the wrong seam, and the seam is the whole output of a bisect.
      R_XN-4 is in the plan and not in the capture
      R_QKV.q-4 is in the plan and not in the capture
```

### The full gate, unfiltered, both suites

MEASURED at `a802780` (`5578132` plus two commits that touch only `docs/`, `hw/`,
`server/` and `tools/weights_*`, nothing under `rtl/` or `sim/`), `--jobs 3`, on
a box also running TRACK REALFIX's own full gate concurrently:

```
 suite sim   PASS 73   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 99   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 99 passing, above the recorded floor of 97
 REGRESSION: PASS
```

with the three new rows:

```
sim:seamgate_real	PASS	38	SEAMGATE PASS -- real: 1 token(s), at least 61 seams per token
sim:seamgate_stub	PASS	29	SEAMGATE PASS -- stub: 1 token(s), at least 60 seams per token
sim:seamgate_seq	PASS	143	SEAMGATE PASS -- seq: 3 token(s), at least 59 seams per token
```

**The floor is 99 and only three of the +5 are this track's.** The recorded floor
was 94 and the tree was already at 96 before these rows existed. MEASURED:
`git diff --diff-filter=A d570899 HEAD -- 'sim/tb_*.vhd' 'tb/tb_*.vhd'` is empty,
so no testbench was added since 94 was recorded; two rows that were red at that
point (its own commit message is "the full gate run, and why its one red row is
not this track's") have since been fixed by other tracks and nobody raised the
floor. Recorded rather than absorbed, because a floor two below the truth cannot
detect the disappearance of two testbenches, which is the only thing it exists
to detect.

**Added cost: 210 s of wall time** across three rows, all three in `SLOW_TBS` so
`--quick` skips them. DERIVED: 38 + 29 + 143.

## Measured and REJECTED -- do not retry

**A VHDL-shaped row.** The comparison's models are `tools/ref9b/*.py` and
`ref/*.c`. GHDL here is the mcode backend and `ghdl -r` has no route to either;
VHPIDIRECT would need a linked backend. The only VHDL-shaped alternative is to
re-implement `matvec_int4`, `seq_vec_res`, `rmsnorm_rs`, the SwiGLU stand-in and
`attn_block`'s token function in VHDL beside the RTL -- a second implementation,
maintained by the same people, that drifts from the first. That is the `m7
mutant` shape exactly: a packer plus a reversed decoder passing an entire
self-test suite. Rejected on principle, not on effort.

**A golden byte-identity row.** Already rejected by `golden_status.sh` with
three reasons; MEASURED again here and the third one still holds. Not retried.

**Making the plan generator emit the rows.** The planner's job is resolving VHDL
design units from a `tb_*.vhd` glob and emitting an analysis closure in
topological order. Putting a non-VHDL special case inside it would mean every
future reader of that Python has to hold two concepts. Appending after it costs
five lines and keeps the planner about VHDL.

**Widening `run_one` to take a shell command.** Rejected: `run_one` is on the
path of every one of the other 94 rows, and this file was edited by six tracks
on the day this was written. `run_seam` is a separate function; `run_one`'s only
change is a two-line `case` on the name, before it touches anything.

**A third suite (`SUITES="sim tb seam"`).** Rejected: it would have touched the
`--suite` parser, the per-suite tally initialisation and the `BASELINE_PASS`
guard's `[ "$(echo $SUITES)" = "sim tb" ]` condition, for no gain. These rows run
`sim/tb_llama_top.vhd`, so calling them `sim` rows is accurate, not a convenience.

**`m3`/`S4` as the demonstration defect.** The brief named it as "exactly the
defect a landmark cannot see and a seam comparison should". It is the opposite on
both halves; see Corrections. Do not use it as the teeth for this gate. It is in
the table as a survivor and must stay there.

**Building `mv_step_oracle` into `tools/ref9b/`.** That is where its own error
message tells you to put it, and it is `.gitignore`d, so it is not wrong -- but a
gate row must not write into the repository, and two concurrent runs of the row
would race over one path. `seamgate.sh` builds it into its own scratch and points
`bisect_scaled.py` at it with a new `MV_STEP_ORACLE` environment override.

## Measurement traps hit

**`local a="$1" b="$a/x"` dies under `set -u`.** Bash expands every word of the
`local` command before assigning any of them, so `$a` is unbound in the same
statement. This bit inside `mutate_seamgate.sh`'s `run_land`, and the error
printed *inside* the S3 and S4 reports where it read like a mutant that had
broken the landmark row rather than a bug in the harness. Two mutants' landmark
columns had to be re-run. Split the declaration.

**A Python traceback exits 1, and so does a divergence.** The first version of
`seamgate.sh` reported a crashed comparator as `SEAMGATE FAIL (DIVERGENCE)` and
printed a traceback under the heading "a modelled seam does not match its
model". Naming an innocent seam sends the next reader into the RTL. The verdict
line's ABSENCE is now the test, and that case is reported as `HARNESS`.

**`--w-image` is repo-relative and `bisect_scaled.py` was being run from
`tools/ref9b/`.** The first wiring `cd`'d into the tool directory (because the
README's examples do) and the weight image could not be opened. Run it from the
repository root; `python3 tools/ref9b/bisect_scaled.py` still resolves its
sibling imports because Python puts the *script's* directory on `sys.path`.

**`regress.sh --only <pattern>` that matches nothing prints `REGRESSION: PASS`.**
Hit while trying to show the row going red inside a mutant tree: the mutant's
copy of `sim/regress.sh` predated the edit, so the row did not exist, nothing was
selected, and the run reported PASS with `OVERALL PASS 0`. Already documented in
`CLAUDE.md`; recording that it fires in this shape too. **Read the `OVERALL PASS
n` count, never the verdict line alone.**

**A stale `BASELINE_PASS` hides itself.** The floor said 94; the tree passed 96
before this track added anything. `regress.sh` prints "above the recorded floor
-- raise BASELINE_PASS" and does NOT fail, which is correct (a rising count is
good news) but means the note is easy to leave for the next person. Two tracks
in a row apparently did. Anyone raising the floor should check
`git diff --diff-filter=A <the commit that set the old floor> HEAD -- 'sim/tb_*.vhd' 'tb/tb_*.vhd'`
before attributing the increment to their own rows.

**I edited `tools/ref9b/seamgate.sh` while a full gate that had not yet reached
its seam rows was running.** `regress.sh` protects itself by re-execing a private
copy; nothing it *invokes* has that protection. The edit was comment-only and
`bash -n` followed it, so nothing was damaged, but a syntax error would have made
three rows fail spuriously in a 50-minute run. Freeze the scripts a running gate
invokes, not only the gate.

**`( ... ) &` inside a backgrounded tool call does not survive.** A 2-minute
`seq` capture launched that way reported exit 0 immediately and produced no
file. Not a project trap, but it cost a run.

**`awk '{print $6}'` on a sentence.** The "not checked" count is field 8 of
`# 61 seams checked against a model, 3 NOT checked`, not field 6. It printed the
literal word `a` in two runs before it was noticed, which is exactly the class of
thing that turns into a wrong number in a table.

## Corrections to the brief -- verified, and both matter

**1. `m3` is NOT a defect the landmark cannot see, and it IS a defect the seam
comparison cannot see.** The brief said:

> CAPTURE's `m3` (a `gdn_silu` EMIT truncation) is a good candidate: OI3B
> measured that it leaves all three `R_X` landmarks bit-identical, so it is
> exactly the defect a landmark cannot see and a seam comparison should.

Both halves are wrong, and the evidence for each was already in the repository:

- `tools/ref9b/mutate_capture.sh`'s own header says, of `m3`: "Inside subsystem
  B, whose `R_Y` has NO integration-level model, so the reference stream OMITS
  it. **EXPECTED TO SURVIVE.**" MEASURED again here as S4: the gate passes with
  all 61 seams bit-exact.
- OI3B added `EXP_STEPH` *for this defect*. `sim/tb_llama_top_real.vhd:59-66`
  says so, and MEASURED here the landmark row FAILS on the S4 mutant with
  `EXP_STEPH` moving 17333 -> 34846. The three `R_X` landmarks are indeed blind;
  the fourth is not, and it was pinned before this track started.

The correct statement of the complementarity runs the other way: **S3 is the
defect the landmark row cannot see** (it is after the last region write, and
`tb_llama_top_real` does not elaborate the sampler), and **S4 is the defect the
seam gate cannot see** (subsystem B has no integration-level model). Neither
instrument dominates. That is the argument for having both, and it is a better
argument than the one the brief made.

**2. The brief's seam counts are from a different instrument.** It quoted
"59 seams bit-identical on the real path, 58 on the stub, 54 per token" from
TRACK CAPTURE and "61/61 and 59/59" from TRACK LOGITS. Those are
`seam_bisect.py --mode exact` comparing two `.r9bs` streams. This row uses
`bisect_scaled.py`, the STEPWISE oracle, whose denominator is the descriptor plan
and not a stream's record list. MEASURED at `5578132`: 61 of 64, 60 of 64, and
59 of 61 per token. Not a contradiction, but the numbers are not interchangeable
and a floor taken from the wrong one would be wrong by two.

**3. Commit hashes in the brief all verify.** `d23770c`, `fd4cc70`, `0503b38`,
`35e0ed0`, `5578132` are all present and their subjects match the descriptions.
No correction needed; recorded because the brief asked for the check.

**4. `tools/ref9b/**` has no owner row in `docs/WORKLOG.md`'s ownership table.**
The brief assigned it to this track and TRACK REF-TOKEN released it, which is
consistent, but a reader of the WORKLOG alone would not know that. Not fixed
here -- `docs/WORKLOG.md` is not this track's to edit.

## Open, not determined

- **Whether the `seq` row's 143 s is worth its place.** It is the only row that
  exercises the KV cache across tokens and it triples the comparison count (177
  seam comparisons against `real`'s 61), but it is also the most expensive row
  this track added. It is in `SLOW_TBS`, so `--quick` skips it. If the full gate
  becomes the bottleneck, this is the row to question first, and the answer
  should be measured rather than assumed.
- **Whether the floors are the right floors.** They are the counts measured at
  `5578132`. A subsystem B integration model would raise `real` from 61 to 64;
  nothing here checks that the floors are *achievable*, only that they are not
  silently lost.
- **The unmodelled seams are still unmodelled.** `R_Y` at every GDN block is
  passed forward AS GIVEN and every later seam still agrees. This row is not
  evidence that the token is right, and its own PASS text says so. Subsystem B's
  input includes a recurrent state no region holds, which is why
  `tools/ref9b/attn_oracle.py`'s approach does not transfer.
- **Not verified: behaviour when `tools/ref9b`'s Python is absent or a different
  version.** The row assumes `python3` and a working `cc`; it reports HARNESS if
  the oracle will not build, but no machine without them was tested.
- **Not verified: interaction with TRACK REALFIX.** That track is changing
  `rtl/llama_top.vhd` for the real 9B shape while this was written. The three
  configurations here are scaled shapes and were green at `5578132`; if REALFIX's
  changes move them, the gate will say so, and the seam it names is the answer to
  "did that change do what it was meant to".

## Files

| path | what |
|---|---|
| `tools/ref9b/seamgate.sh` | NEW. One verdict per configuration. Runnable standalone. |
| `tools/ref9b/mutate_seamgate.sh` | NEW. The teeth, S1..S7, including the survivors. |
| `tools/ref9b/capture_llama_top.sh` | `LIST_BISECT=1`, so the bisect args live one line under the generics they must agree with. |
| `tools/ref9b/bisect_scaled.py` | `MV_STEP_ORACLE` env override, so a gate row need not write a binary into the repository. |
| `sim/regress.sh` | SHARED. Three appended plan rows, `run_seam`, a two-line dispatch in `run_one`, three names in `SLOW_TBS`, `BASELINE_PASS` 94 -> 97. |
