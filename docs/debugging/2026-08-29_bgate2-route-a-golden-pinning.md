# Backlog item 11 was already closed; what was left was Route A, and it bites

Date: 2026-08-29.  TRACK BGATE2.  Repo `llama.vhdl`, branch `fpga`.
Base tree `66a2e2e` (`git archive`), GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6, mcode
backend), VHDL-2008 `-frelaxed`.  Workstation `Oren-Dell-Ubuntu`: root 97% full
with 39 G free, `/mnt/storage` 388 G free, RAM 31 G total with 0 free and 17 G
available, load average 3.36/5.18/6.45 at start, a Vivado synthesis and three
other tracks competing for the box throughout.
**No hardware ran.  No Vivado ran.  No `rtl/` file in the repository was
modified** -- every mutation below was applied to a throwaway `git archive`
tree under the session scratchpad.

## 1. The question, verbatim

> **Five of subsystem B's seven units have no accuracy gate `sim/regress.sh`
> can fail.** `gdn_silu` and `rmsnorm_bf` PRINT their oracle figures from the
> generator and assert nothing.  `gdn_head_emit`, `gdn_y_emit` and
> `gdn_emit_chain` assert inside a generator the gate never runs, because their
> vectors are committed.
>
> **The flagship case, and the reason this is not a chore:** a mutation to
> `rmsnorm_bf` that reintroduces **exactly the defect that unit exists to fix**
> is bit-exact-green through the gate and **1.7e10 output LSB wrong.**
>
> **Do `gdn_silu` and `rmsnorm_bf` FIRST.** ... Section 7 of
> `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md` scopes two routes
> and they are **NOT equivalent** -- read it and choose deliberately, stating
> why. ... **Every gate you add must be shown to fail.**

## 2. The answer

**The count of five is FIVE out of date.  All five units were gated by two
earlier tracks today, hours before this brief was written, and this track
verified that independently rather than taking the documents' word.**  What
remained genuinely open was **Route A**, which both earlier write-ups list as
their own open item, and which this track measured, teeth-checked and landed.

1. **Backlog item 11 is closed and was closed at 14:28.**  `728fcfe` (08:19)
   put Route B into `tb_gdn_silu` and `tb_rmsnorm_bf`; `81297ee` (10:03)
   re-calibrated seven thresholds that fired on the honest unit; `2868f6b`
   (14:28) put Route B into `tb_gdn_head_emit`, `tb_gdn_y_emit` and
   `tb_gdn_emit_chain`.  All three are ancestors of HEAD.
2. **The flagship is dead, reproduced independently here.**  Mutation B1 of
   `sim/mutate_rmsnorm_bf.sh` applied to both transcriptions with the golden
   regenerated is still **bit-exact green** and is killed by three of the
   bench's four accuracy gates at **1.682481463580507e10 LSB**.  Control on the
   same tree: `worst 7.703593954793178e-1 LSB`, PASS.
3. **Route A was the open item, and it was open for four of the five vectors.**
   `gdn_emit_chain_vec.txt` has had a `tb_vector_args` row since `f45c4fe`
   (2026-08-27), so the chain's generator HAS been running on every gate run
   and its exit code HAS been consulted -- which corrects both the brief and
   section 7 of the D1-D3 document on that unit specifically.  The other four
   had no row, so their generators never ran on a gate run at all.
4. **Both halves of that gap were MEASURED to be real, not theoretical.**
   - *A stray file silently becomes the standard.*  A seed-999 rebuild of
     `sim/gdn_silu_vec.txt` dropped into the tree is **bit-exact green** and
     moves the bench's own accuracy report from `worst 1.8442 LSB / 14 elements
     past 1.5 LSB` to `2.4503 / 38`, against an `ACC_NEAR_MAX` of 60.  Nothing
     went red; the gate simply verified the RTL on a different 256 cases and
     reported different numbers.
   - *The generator's exit code was unreachable.*  With
     `ref/gdn_head_emit_vec.c` mutated so its own 1.0 LSB bound fires at 4.0000
     and the binary exits 1, `--only tb_gdn_head_emit` printed
     `REGRESSION: PASS`.
5. **Route A is ADDITIVE to Route B and cannot replace it, and this is
   MEASURED twice, not argued.**  `gdn_y_emit` B5 (msb-13 in BOTH) and
   `gdn_silu` B3 (rail 16 -> 8) each leave their generator **exiting 0** -- B5's
   generator even prints `OK: below the 1.0 LSB bound` while its own worst-case
   figure IMPROVES to 0.5000 -- and both are killed only by the bench.

Landed as `f3cb87a`, four rows in `sim/regress.sh`, +40 lines, no row added or
removed, `BASELINE_PASS` untouched.

## 3. The procedure, in the order it was run, and what each step isolates

1. **`git log --format='%h %ad %s' --date=iso` on the five owned benches, before
   reading anything else.**  Isolates *the brief's snapshot* from *the tree*.
   One command; it turned a day of work into a verification pass.  This is the
   same trap `2868f6b` records in its own section 7, hit again by the next
   brief, so it is now recorded twice.
2. **`git merge-base --is-ancestor` on all three claimed commits.**  Isolates
   *a commit that exists* from *a commit that is in the line HEAD sits on*.
3. **Regenerate all five vectors at generator defaults and `cmp` against
   `git show HEAD:sim/<file>`.**  Isolates *a golden that matches its generator*
   from *a golden that has drifted*, and it is the precondition for any Route A
   row: if the row's arguments do not reproduce the committed file byte for
   byte, adding the row silently changes what every bench is measured on.
   Deliberately against `git show HEAD:`, not the working tree, for the reason
   the `attn_kv_quant_vec.txt` row already records.
4. **The flagship mutation applied by hand on a `git archive` tree, with a
   control run first.**  Not by running `sim/mutate_rmsnorm_bf.sh`, because a
   harness verdict is the harness's own claim; the question was whether
   `sim/regress.sh` fails, so `sim/regress.sh` is what was run.
5. **`SHA=$(git rev-parse HEAD)` as its OWN step before every `git archive`.**
   It caught a concurrent commit: HEAD was `bf99d39` when this track started
   reading and `66a2e2e` when the SHA was taken.
6. **Route A teeth in both directions, each with its control.**  The
   exit-code branch (a generator that fails) and the stray-file branch (a
   generator that succeeds but a foreign golden is present) are different code
   paths in `run_one` and neither exercises the other.
7. **Two BOTH-class mutations chosen specifically for generators that return
   ZERO.**  A Route A teeth check on a mutation the generator also catches
   proves nothing about the boundary between the two routes.

## 4. The evidence

### 4.1 The five units are already gated, and by whom

```
$ git log --oneline -5 -- sim/tb_gdn_silu.vhd sim/tb_rmsnorm_bf.vhd
81297ee subsystem B: seven accuracy thresholds fire on the honest unit, two of them set today
728fcfe gdn_silu, rmsnorm_bf: the accuracy oracle was printed, not gated, and the rmsnorm_rs defect walked straight back in
a2c3f88 sim: four testbenches never terminated, and two vector files were untracked
$ git log --oneline -1 -- sim/tb_gdn_head_emit.vhd sim/tb_gdn_y_emit.vhd sim/tb_gdn_emit_chain.vhd
2868f6b subsystem B emit units: the accuracy claim moved into the bench, and the defect class no accuracy claim can see
$ for c in 728fcfe 81297ee 2868f6b; do git merge-base --is-ancestor $c HEAD && echo "$c YES"; done
728fcfe YES
81297ee YES
2868f6b YES
```

### 4.2 The flagship, reproduced independently

`rtl/rmsnorm_bf.vhd` and `ref/rmsnorm_bf_vec.c` both patched with B1, the golden
regenerated from the mutated C so bit-exactness cannot be what fails.

```
--- CONTROL, unmutated, same tree ---
(report note): rmsnorm_bf accuracy vs the real-valued oracle: worst
  7.703593954793178e-1 LSB at case 79 element 116; 49 of 24960 unsaturated
  elements past 5.0e-1 LSB; mean 2.1076343595974778e-1 LSB; 640 saturated and excluded
(report note): rmsnorm_bf: bit-exact with the C reference on all 200 cases
  (25600 elements + 200 exponents), N=128 LANES=4 Q=12; and within 2.0e1 LSB of
  the real-valued oracle on every unsaturated element
 OVERALL     PASS 1   FAIL 0 ...
 REGRESSION: PASS

--- B1, "the rsqrt exponent is divided out against Q, not e_out" ---
(report note): rmsnorm_bf accuracy vs the real-valued oracle: worst
  1.682481463580507e10 LSB at case 175 element 14; 21130 of 24960 unsaturated
  elements past 5.0e-1 LSB; mean 2.7467056474507885e9 LSB; 640 saturated and excluded
(report error): rmsnorm_bf: OUT OF TOLERANCE -- worst accuracy error
  1.682481463580507e10 LSB exceeds 2.0e1 LSB (case 175 element 14)
(report error): rmsnorm_bf: OUT OF TOLERANCE -- mean accuracy error
  2.7467056474507885e9 LSB exceeds 3.0e-1 LSB. ...
(report error): rmsnorm_bf: OUT OF TOLERANCE -- 21130 elements past 5.0e-1 LSB,
  cap is 1300. ...
 OVERALL     PASS 0   FAIL 1 ...
 REGRESSION: FAIL
```

**No `mismatch` line appears in the mutant's log.**  Bit-exactness is green and
three of the four accuracy gates fire.  That is the whole claim of `728fcfe`,
re-measured by a track that did not write it.

### 4.3 Every Route A row reproduces its committed golden byte for byte

```
$ ./gen_gdn_silu      a_silu.txt 256 128 20260826 12
$ ./gen_rmsnorm_bf    a_rms.txt  200 128 20260826 12 1e-6
$ ./gen_gdn_head_emit a_head.txt 64 128 20260826
$ ./gen_gdn_y_emit    a_y.txt    48 24 128 20260827
$ cmp a_silu.txt cmtd_gdn_silu.txt && ...
gdn_silu       args -> BYTE-IDENTICAL to git show HEAD:
rmsnorm_bf     args -> BYTE-IDENTICAL to git show HEAD:
gdn_head_emit  args -> BYTE-IDENTICAL to git show HEAD:
gdn_y_emit     args -> BYTE-IDENTICAL to git show HEAD:
```

All five also reproduce at bare defaults, `gdn_emit_chain_vec.txt` included, so
none of the five committed B goldens has drifted from its generator.  That is
the D1 staleness question asked of the whole subsystem and answered: **clean at
`66a2e2e`.**

### 4.4 Route A teeth, branch 1: the stray generator run

A seed-999 rebuild of `sim/gdn_silu_vec.txt` dropped into a pristine tree, which
is exactly the incident the `attn_kv_quant_vec.txt` row records.

```
--- UNPATCHED tree, COMMITTED golden ---
gdn_silu accuracy vs the real-valued oracle: worst 1.8441562729658472 LSB at
  case 31 element 93; 14 of 32768 elements past 1.5 LSB; mean 1.1857914794993378e-1 LSB
 REGRESSION: PASS

--- UNPATCHED tree, FOREIGN seed-999 golden in sim/ ---
gdn_silu accuracy vs the real-valued oracle: worst 2.4503119567143585 LSB at
  case 143 element 36; 38 of 32768 elements past 1.5 LSB; mean 1.3063661410670865e-1 LSB
 REGRESSION: PASS

--- PATCHED tree, SAME foreign golden in sim/ ---
gdn_silu accuracy vs the real-valued oracle: worst 1.8441562729658472 LSB at
  case 31 element 93; 14 of 32768 elements past 1.5 LSB; mean 1.1857914794993378e-1 LSB
```

**Both unpatched runs are green.**  That is the point: the hazard is not a red
gate, it is a gate that quietly changed what it verified.  The count moved
14 -> 38 against a cap of 60 on a seed change alone, which is the same false-red
mechanism `81297ee` measured when it audited 26 thresholds.

### 4.5 Route A teeth, branch 2: the generator's exit code

`ref/gdn_head_emit_vec.c` mutated at the ORACLE only -- `double lsb =
ldexp(1.0, -e_head)` becomes `ldexp(1.0, -e_head - 3)` -- so the emitted vector
bytes are unchanged and only the generator's own verdict moves.

```
$ ./gen_a2a out.txt
  worst error vs double oracle: 4.0000 LSB of the output grid (case 0)
  FAIL: reaches 1.0 LSB, which the alignment floor plus the requantize rounding
        cannot explain -- the integer recipe is wrong, not the grid
generator rc=1
$ cmp out.txt cmtd_gdn_head_emit.txt
vector bytes: IDENTICAL to committed

--- BEFORE the row ---
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0 ...
 REGRESSION: PASS

--- AFTER the row ---
ERROR      sim:tb_gdn_head_emit   1s  reference vector generator failed:
                                      VECTORGEN_RUN_FAILED .../ref/gdn_head_emit_vec.c
 OVERALL     PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 1 ...
 REGRESSION: FAIL

--- AFTER the row, C reverted (control) ---
 OVERALL     PASS 1   FAIL 0 ...
 REGRESSION: PASS
```

### 4.6 Route A cannot replace Route B, measured on two mutations

**`gdn_y_emit` B5, "site 13 keeps one bit less headroom (msb-13), in BOTH".**
Applied to `rtl/gdn_y_emit.vhd` and `ref/gdn_y_emit_vec.c`, golden regenerated:

```
    shape 4 worst: 0.5000 LSB
    shape 5 worst: 0.5000 LSB
    shape 6 worst: 0.4999 LSB
  OK: below the 1.0 LSB bound (align floor + requantize round)
gen rc=0
```

The generator PASSES, and its own accuracy figure has IMPROVED -- the honest
unit reaches 0.75 -- because the metric is normalised by the grid the mutation
coarsens.  The bench kills it anyway, on the normalisation claim rather than on
a tolerance:

```
(error): case 0: NORMALISATION -- the requantize shifted by 16 yet the largest
  |y| is only 16042, under the floor of 16384.  sh > 0 means amax >= 2^(sh+14),
  so the result must fill the grid.  A grid one octave too coarse is INVISIBLE
  to any error measured in LSB of that same grid, which is why this check is
  not a tolerance.
 OVERALL     PASS 0   FAIL 1 ...
 REGRESSION: FAIL
```

**`gdn_silu` B3, "the sigma saturation rail moves from |x| = 16 to |x| = 8".**

```
  worst abs err vs double oracle: 5.2488 LSB (case 13)
  Q12 saturations: 13228   nonzero flushed to zero: 7510
gen rc=0

(note):  gdn_silu accuracy vs the real-valued oracle: worst 5.248832271875376
         LSB at case 13 element 101; 47 of 32768 elements past 1.5 LSB; mean
         1.2208471622770863e-1 LSB
(error): gdn_silu: OUT OF TOLERANCE -- worst accuracy error 5.248832271875376
         LSB exceeds 3.5 LSB (case 13 element 101)
 REGRESSION: FAIL
```

`ref/gdn_silu_vec.c` measures the same 5.2488 and returns 0, because its
accuracy figure is printed and never compared.  Route A makes the file
trustworthy; it does not make the C's opinion a gate, because the C has no
opinion to express.

### 4.7 The five rows, green, on both trees

`git archive 66a2e2e` plus the patch:

```
PASS  sim:tb_gdn_silu         3s
PASS  sim:tb_rmsnorm_bf       7s
PASS  sim:tb_gdn_head_emit    1s
PASS  sim:tb_gdn_y_emit       7s
PASS  sim:tb_gdn_emit_chain  61s
```

This workstation's working tree, same five, same times, and
`git status --porcelain` on all five committed vectors is empty afterwards:
generation goes into the per-test run directory and never touches `sim/`.

### 4.8 Cost

MEASURED on this box, per row, with `/usr/bin/time`:

| generator | `cc -O2` | run |
|---|---|---|
| `gdn_silu_vec.c` | 0.06 s | 0.00 s |
| `rmsnorm_bf_vec.c` | 0.12 s | 0.01 s |
| `gdn_head_emit_vec.c` | 0.12 s | 0.00 s |
| `gdn_y_emit_vec.c` | 0.10 s | 0.01 s |

Against row wall times of 1, 3, 7 and 7 seconds.  The `tb_gdn_head_emit` row is
the worst case at roughly 12% and it is the shortest row in the set.

## 5. Measured and REJECTED -- do not retry

- **Do NOT read the brief's "five units have no accuracy gate" as current.**
  MEASURED: all five had one, landed at 08:19 and 14:28, and the document the
  brief asked for already existed under a neighbouring filename.  The check is
  `git log` on the owned files and it costs one command.
- **Do NOT add a `tb_vector_args` row without first proving the arguments
  reproduce the committed golden byte for byte.**  A row whose arguments differ
  changes what the bench measures with no diff and no message.  For `gdn_silu`
  a seed change alone moves the bench's count from 14 to 38 against a cap of
  60; a shape change would move far more.
- **Do NOT treat Route A as a substitute for Route B, on any of these five.**
  MEASURED twice, sections 4.6: `gdn_y_emit` B5 and `gdn_silu` B3 both leave
  the generator exiting 0.  B5 is the stronger case because its generator's own
  figure moves the SAFE way, 0.75 -> 0.50, so a Route A gate would have been
  actively reassuring about a real defect.
- **Do NOT add a `cmp` of the regenerated vector against the committed one to
  `sim/regress.sh`.**  Considered and rejected: the `gdn_emit_chain_vec.txt`
  row deliberately regenerates at `NB = 3` while the committed file is at the
  generator default `NB = 6`, so a blanket comparison is a guaranteed false red
  on a row that has been correct since 2026-08-27.  The property wanted is
  "the row's args reproduce the committed file", which is a claim about the
  ROW and not about the run, and the place for it is a one-off check like
  section 4.3 rather than a per-run cost.
- **Do NOT conclude from "the golden was replaced and the gate went green" that
  the bit-exact check is weak.**  It is doing exactly what it says: comparing
  the DUT to the file it was given.  The defect is that nothing said which file
  that should be.
- **Do NOT run `sim/mutate_*.sh` to answer "does `sim/regress.sh` fail".**  The
  harnesses have their own verdict columns at their own generics; `2868f6b`
  records a 1.1280-vs-0.8505 comparison that was made across two different
  shapes for exactly this reason.  Run the gate.

## 6. Measurement traps hit, including this track's own

- **`git archive HEAD` straddles a concurrent commit.**  HEAD was `bf99d39`
  when this track began reading and `66a2e2e` when `git rev-parse` ran, five
  minutes later.  Taking the SHA as its own step and reusing the variable is
  what makes the six archive trees in this document the SAME tree.  The trap is
  already recorded by TRACK GATEHYGIENE and it fired again the same evening.
- **`nohup ... &` returns instantly and the harness reports the task
  "completed" with exit code 0.**  That is the exit code of the shell that
  launched it, not of the gate.  The log was zero bytes and five `ghdl-mcode`
  processes were live.  Check `pgrep` and the log size before believing a
  background completion.
- **A generator's accuracy figure IMPROVING is not evidence of correctness.**
  `gdn_y_emit` B5's generator prints three shape lines at 0.5000 and an `OK`,
  where the honest unit prints 0.75.  Read as a diagnostic it says the mutant is
  better than the design.
- **`cmp` against the WORKING TREE copy of a golden would have been the wrong
  control here.**  This track's own probes wrote foreign goldens into scratch
  trees; had any of them been the repository, a later `cmp` would have compared
  a foreign file against a foreign file and reported agreement.  `git show
  HEAD:` is the only stable reference and it is what section 4.3 uses.
- **`ghdl -r ... | head` reports the PIPELINE's rc.**  Not hit here because
  every generator invocation used `${PIPESTATUS[0]}` explicitly, but the first
  draft of the section 4.5 probe did not and reported `rc=0` on a generator that
  exits 1.

## 7. Corrections to the dispatching brief

Recorded under their own heading because the brief asked for it.

1. **"Five of subsystem B's seven units have no accuracy gate `sim/regress.sh`
   can fail" is false at `66a2e2e`, and was false when the brief was written.**
   All five were gated by `728fcfe` (08:19) and `2868f6b` (14:28).  The brief
   was dispatched at about 18:50.
2. **"`gdn_head_emit`, `gdn_y_emit` and `gdn_emit_chain` assert inside a
   generator the gate never runs" is wrong for `gdn_emit_chain`.**
   `gdn_emit_chain_vec.txt` has had a `tb_vector_args` row since `f45c4fe`
   (2026-08-27 18:24), so its generator runs on every gate run and its exit
   code is consulted by `run_one`'s `VECTORGEN_RUN_FAILED` branch.  Section 7 of
   `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md` carries the same
   error, which is presumably where the brief got it.  The claim is correct for
   the other four.
3. **"Do `gdn_silu` and `rmsnorm_bf` FIRST.  They are clean" -- they were done
   first, twelve hours earlier, by `728fcfe`.**  The instruction was right about
   the order and out of date about the state.
4. **The `gdn_emit_chain` normalisation figure quoted as "1.1280 -> 0.8505" is
   at the mutation harness's `NB = 3`, not at the gate's shape.**  `2868f6b`
   already corrected this; repeating it here because the brief re-quoted the
   uncorrected pair.
5. **`BASELINE_PASS` is 93 and this track did not change it,** because no row
   was added or removed.  The brief's warning was still worth having: the four
   rows change what four existing rows read, and had any argument been wrong the
   effect would have been silent rather than a count change.

## 8. What was NOT verified

- **No claim is made that the five Route B gates are correctly CALIBRATED.**
  This track re-measured that three specific mutations die and that the honest
  unit passes at the committed seed.  The nine-seed and forty-seed envelopes
  behind the thresholds are `728fcfe`'s and `2868f6b`'s measurements and were
  not re-run.  `81297ee`'s own finding -- that two sweeps of the same statistic
  disagreed by 2.08x on a maximum -- applies to them and is unresolved.
- **The `gdn_emit_chain` row's arguments were not changed and its committed
  golden is at a different shape from the one the gate uses.**  `NB = 6`
  committed, `NB = 3` in the row.  That is deliberate and predates this track;
  it is recorded here only because it is the reason section 5 rejects a blanket
  `cmp`.
- **Only three mutations were run.**  `rmsnorm_bf` B1, `gdn_y_emit` B5,
  `gdn_silu` B3, plus the two synthetic Route A probes.  The remaining BOTH-class
  mutations in the five harnesses were not re-measured by this track.
- **The four new rows were exercised only at the committed shapes.**  Nothing
  enforces that a future change to a bench's `NCASE`/`DIM` generic is mirrored
  into its row; the vector file's shape header would make the mismatch loud, but
  that is the file's property and not the row's.
- **No `tb_vector_args` row was added for `gdn_conv_vec.txt` or
  `gdn_scalar_vec.txt`,** the two units that were already gated before today.
  Both were verified byte-identical to their generators in section 4.3, so
  neither is stale now, but neither is pinned either.
- **No hardware ran.  No Vivado ran.  No `rtl/` file in the repository was
  modified.**

## 9. Open, not yet answered

1. **`gdn_conv_vec.txt` and `gdn_scalar_vec.txt` have no row.**  Same argument
   as the four landed here, and `gdn_conv` is the unit where the staleness class
   was actually observed to mask a mutation.  Not done here because both files
   are consumed by mutation harnesses this track does not own and the D1
   write-up's blast-radius argument should be re-run before touching them.
2. **`gdn_emit_chain` still has no real-valued accuracy oracle in its bench.**
   `2868f6b` gave it the normalisation check only.  Its generator's end-to-end
   oracle IS now reachable from the gate, and has been since 2026-08-27, so the
   chain is the one unit where Route A already carries a genuine accuracy claim
   -- which is worth stating plainly because the earlier documents say the
   opposite.
3. **Whether the row arguments should be asserted against the committed golden
   somewhere.**  Rejected as a per-run cost in section 5, but the property is
   real and a `--slow` row or a one-off script could hold it.
4. **The `!sat_any` exclusion is still present in all three emit GENERATORS**,
   as `2868f6b` records.  Now that those generators run on every gate run, their
   printed figures are read more often, and they are the known-misleading ones.
