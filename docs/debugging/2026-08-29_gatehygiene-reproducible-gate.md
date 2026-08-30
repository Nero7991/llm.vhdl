# The regression gate was not reproducible from a clean checkout

2026-08-29. TRACK GATEHYGIENE. Base tree `9ad4c14` (`git archive`), GHDL 1.0.0
(Ubuntu 1.0.0+dfsg-6, mcode backend), `sim/regress.sh --jobs 2`, workstation
`Oren-Dell-Ubuntu` (root 97% full, 39 G free; a Vivado synthesis competing for
the box for the whole session, load average 2.7 to 8.4).

## 1. The question, verbatim

> Make the gate reproducible from a clean checkout, and make `BASELINE_PASS`
> mean something a clone can verify.
>
> The defect, as reported: "`BASELINE_PASS` cannot be validated on a committed
> tree. `sim/tr.txt` is **untracked**, so three `tb_matvec_*` rows fail `cannot
> open file` on any `git archive` tree; supplying it makes them pass. A `git
> archive 9d7a9e5` tree plans 102 rows, ceiling **92 PASS** -- the floor was 94
> then and 99 now, calibrated against ~20 untracked `sim/tb_*.vhd` lying in the
> working tree."
>
> Verified independently by the dispatcher at HEAD: `sim/tr.txt` is UNTRACKED;
> 18 untracked `sim/tb_*.vhd` against 75 tracked; `sim/regress.sh:387` now reads
> `BASELINE_PASS=101`.

## 2. The answer

**Confirmed, and worse than reported in one specific way: `BASELINE_PASS=101`
was unreachable on EVERY tree, including the working tree it was calibrated
against.** The working tree plans 104 rows of which 5 are NOCHECK, so its
ceiling is 99. From `e788a0e` until this commit, every full unfiltered run by
every track reported `BASELINE DROP` and `REGRESSION: FAIL`.

The root cause is not carelessness by either track involved. `sim/regress.sh`'s
planner globs `sim/tb_*.vhd` off the **filesystem**, so an untracked testbench
is a full gate row for whoever holds it and does not exist for anybody else, and
**nothing in the output distinguished a row backed by a committed file from a
row backed by a private one**. TRACK SEAMGATE measured `OVERALL PASS 99` at
17:30:26 and recorded 99. TRACK REALFIX committed `sim/tb_realshape_9b.vhd` and
`sim/tb_stmem_equiv.vhd` at 17:34:32, four minutes later, and raised the floor
by +2 for them. Those two files were already lying untracked in the shared tree
at 17:30, so SEAMGATE's 99 had already counted them and 101 counted them twice.

Three defects were fixed and the floor is now a measured, clone-verifiable
number:

1. **`sim/tr.txt` was not merely untracked, it was `.gitignore`d** (`.gitignore`
   line 63), so `git status` never mentioned that a load-bearing gate input was
   missing from the repository. `sim/regress.sh` now **generates** it from the
   committed `ref/matvec_int4.c`, byte-identically, into each test's own scratch
   directory. The file is also now committed, because
   `sim/mutate_matvec_core.sh` refuses to run without it.
2. **The two FK33 rows read a `.mv4i` file from a GGUF model set that is not in
   git**, and produced a BUILD-ERROR when it was absent. They are now SKIPPED
   with the path, which is this script's existing contract for a row that cannot
   be run.
3. **The gate now reports rows and sources git does not have** ("NOT IN GIT"),
   and when that list is non-empty it **declines to suggest raising the floor**.
   That is the specific advice whose blind following produced 101.

**`BASELINE_PASS` is now 93, MEASURED on `git archive 9ad4c14` plus this
track's patch, with `FAIL 0`.** 93 is the ceiling, not merely the score: 97 rows
planned, 4 NOCHECK, nothing red.

**No untracked testbench was committed or deleted.** All 18 predate this work by
five to eight weeks and belong to the xsim post-synthesis compare flow; see the
triage in section 5 and the open items in section 9.

## 3. The procedure, in the order it was run

Each probe is listed with what it isolates. The whole investigation cost one
full gate run; everything else is `--list`, which plans the suite and runs no
simulation.

1. **`git diff -- sim/regress.sh` as its own step.** Isolates a concurrent
   track's in-flight edit from mine, before touching a file six tracks edited
   today. Empty, so the file was mine to take.
2. **`git ls-files --others --exclude-standard -- 'sim/tb_*.vhd'` with `stat`
   mtimes, plus `git log --all -- <path>` per file.** Isolates *in-flight work
   by a live track* from *stale local files*. The brief warned several might be
   another track's in-flight work; the mtimes say otherwise and the history says
   none was ever tracked.
3. **`git check-ignore -v sim/tr.txt`.** Isolates *untracked* from *ignored*.
   This is the probe that changed the shape of the problem: the file is ignored,
   which is why nobody ever saw it in `git status`.
4. **`grep -rn 'tr\.txt' --include=*.sh` and `.gitignore`'s own comment.**
   Establishes the producer, without guessing: `ref/matvec_int4.c` built as
   `mv4i`, invoked `--trace <file> M K RI sat`.
5. **`sim/regress.sh --list` on the working tree versus on a pristine
   `git archive 9ad4c14` tree, diffed.** Isolates *how many rows the untracked
   files add* from *how many pass*. This is the measurement the floor needed and
   nobody had: 104 RUN / 19 SKIP against 99 RUN / 6 SKIP.
6. **Arithmetic against the NOCHECK table, then `git log` on the two floor
   commits.** Isolates *a floor that is merely too high* from *a floor that is
   arithmetically unreachable*, and then dates the two commits four minutes
   apart to explain how.
7. **`cc` the generator, run it twice, `cmp` and `md5sum` both against the
   working-tree `sim/tr.txt`.** Isolates *deterministic artefact* from
   *machine-specific one*. Byte-identical both times.
8. **Teeth check on the pristine tree: the same row before and after the patch.**
   A checker never shown to fail has not been shown to work. `FAIL ... cannot
   open file "../tr.txt"` becomes `PASS`.
9. **Teeth check on the NOT IN GIT report via `.git/info/exclude`.** Isolates
   *the UNTRACKED branch works* from *the IGNORED branch works*, which nothing
   had exercised. `.git/info/exclude` is local-only, so this perturbs no shared
   file.
10. **One full unfiltered both-suite run** on the pristine tree with
    `MV4I_FK33_FILE` pointed at a nonexistent path, which is the clone-faithful
    configuration. This produces the number on the line.

## 4. The evidence

### 4.1 `sim/tr.txt` is ignored, not merely untracked

```
$ git ls-files --error-unmatch sim/tr.txt
error: pathspec 'sim/tr.txt' did not match any file(s) known to git
$ git check-ignore -v sim/tr.txt
.gitignore:63:sim/tr.txt	sim/tr.txt
$ git status --porcelain --ignored -- sim/tr.txt
!! sim/tr.txt
```

`.gitignore:62` states the producer in its own comment: "subsystem A: stage
traces are regenerated per case by `sim/run_matvec.sh`".

### 4.2 The row set differs between the two trees

```
worktree: RUN=104  SKIP=19
archive : RUN=99   SKIP=6

rows present in WORKTREE plan but NOT in archive plan
< RUN sim:tb_attn_fix_beh      < SKIP sim:tb_attn_cmp2       < SKIP sim:tb_rmsnorm_ps
< RUN sim:tb_attn_replay_beh   < SKIP sim:tb_attn_probe_cmp  < SKIP sim:tb_rms_real
< RUN sim:tb_engine_dump       < SKIP sim:tb_attn_replay     < SKIP sim:tb_sm_cmp
< RUN sim:tb_rms_sweep         < SKIP sim:tb_divprobe_cmp    < SKIP sim:tb_sm_cmp24
< RUN sim:tb_rope_ps           < SKIP sim:tb_embed_ps        < SKIP sim:tb_softmax_ps
                               < SKIP sim:tb_lm_head_ps      < SKIP sim:tb_swiglu_ps
                               < SKIP sim:tb_matmul_rt_ps
```

### 4.3 The floor was above the working tree's own ceiling

DERIVED, from the counts above and the `tb_nocheck_reason` table:

| tree | rows planned | NOCHECK | ceiling | floor at HEAD |
|---|---|---|---|---|
| this workstation's working tree | 104 | 5 | **99** | 101 |
| `git archive 9ad4c14`, as committed | 99 | 4 | 95, and 92 with the `tr.txt` defect | 101 |
| `git archive 9ad4c14` + this patch, clone-faithful | 97 | 4 | **93** | 93 |

MEASURED confirmation that 99 is the working tree's real number, not just an
upper bound: a full run captured in `docs/debugging/2026-08-29_cd-threshold-seed-audit.md`
earlier the same day recorded `OVERALL PASS 86 ... NOCHECK 5 SKIPPED 19`, and 13
rows have been added since; 86 + 13 = 99.

### 4.4 The four minutes that produced 101

```
$ git log --format='%h %ad %s' --date=iso -1 77e5f50
77e5f50 2026-08-29 17:30:26 -0600 seamgate: the files table said 97, the floor is 99
$ git log --format='%h %ad %s' --date=iso -1 3e93bed
3e93bed 2026-08-29 17:34:32 -0600 realfix: the real 9B shape elaborates, ...
$ git diff --diff-filter=A --name-only a802780 HEAD -- 'sim/tb_*.vhd' 'tb/tb_*.vhd'
sim/tb_realshape_9b.vhd
sim/tb_stmem_equiv.vhd
```

SEAMGATE measured at 17:30:26 a tree that already contained both files as
untracked; REALFIX committed them at 17:34:32 and added +2 for them.

### 4.5 The generated trace is byte-identical and deterministic

```
$ cc -O2 -w -I ref -o mv4i ref/matvec_int4.c -lm
$ ./mv4i --trace tr_gen.txt 8 96 4 0
$ cmp tr_gen.txt sim/tr.txt && echo BYTE-IDENTICAL
BYTE-IDENTICAL
3864d53068abeb0ec6b570d2a6f54353  tr_gen.txt
3864d53068abeb0ec6b570d2a6f54353  sim/tr.txt
$ head -2 sim/tr.txt
# GENERATED by ref/matvec_int4 --trace -- DO NOT EDIT
DIMS 8 96 3 3 2 5 4
$ ./mv4i --trace tr_gen2.txt 8 96 4 0 && cmp tr_gen.txt tr_gen2.txt && echo DETERMINISTIC
DETERMINISTIC
```

`8 96 4 0` is not a fresh choice: it is the argv `sim/mutate_matvec_core.sh`
calls trace A, the column whose entire claim is that it is the trace the gate
runs on, and which that script regenerates and `cmp`s on every run. The header
`DIMS 8 96 3 3 2 5 4` is the shape that script documents.

### 4.6 Teeth: the fix on the pristine tree, before and after

```
############ BEFORE: pristine tree, ORIGINAL regress.sh ############
FAIL  sim:tb_matvec_core          0s  exit 1: /usr/bin/ghdl-mcode:error: cannot open file "../tr.txt"
PASS  sim:tb_matvec_core_ragsat   3s  ... BFP: 396 stage va

############ AFTER: same tree, PATCHED regress.sh ############
PASS  sim:tb_matvec_core          1s  ... BFP: 64 stage valu
PASS  sim:tb_matvec_core_ragsat   3s  ... BFP: 396 stage va
```

`tb_matvec_core_ragsat` is the control: it reads the committed
`sim/tr_ragsat.txt`, was green before, and is unmoved.

### 4.7 Teeth: the NOT IN GIT report, both branches

With nothing locally excluded, on this workstation's tree:

```
-- NOT IN GIT (these rows/inputs are yours alone) ------------------------------
UNTRACKED  row    sim:tb_attn_cmp2      not in git: a gate row for you, absent for a clone
   ... 18 rows ...
UNTRACKED  source sim/attention_ml_fix.vhd    compiled by some row; absent, that row goes SKIPPED
UNTRACKED  source sim/attention_ml_probe.vhd  compiled by some row; absent, that row goes SKIPPED
UNTRACKED  source sim/engine_shared_dump.vhd  compiled by some row; absent, that row goes SKIPPED
```

Then, with two of those files added to `.git/info/exclude` (local only, no
shared file touched), they must move from the UNTRACKED class to the IGNORED
class and the counts must drop by one each:

```
IGNORED    row    sim:tb_sm_cmp24              .gitignore hides it -- git status will NEVER mention it
IGNORED    source sim/attention_ml_fix.vhd     .gitignore hides it -- git status will NEVER mention it
untracked rows: 17 (was 18)
untracked sources: 2 (was 3)
```

Both branches bite. Restored afterwards; `.git/info/exclude` is never committed.

### 4.8 The external prerequisite skips cleanly, both ways

```
=== prereq present (this box) ===
RUN  sim:tb_matvec_fk33        entity=tb_matvec_fk33       11 files  vectors=mv_fk33_tr.txt
RUN  sim:tb_matvec_fk33_desc   entity=tb_matvec_fk33_desc  13 files  vectors=mv_fk33_tr.txt
=== prereq absent (clone-faithful) ===
SKIP sim:tb_matvec_fk33        external prerequisite not in this tree and not in git: /nonexistent/none.mv4i
SKIP sim:tb_matvec_fk33_desc   external prerequisite not in this tree and not in git: /nonexistent/none.mv4i
```

### 4.9 The number on the line

Full unfiltered both-suite run, pristine `git archive 9ad4c14` plus this
track's patch, `MV4I_FK33_FILE=/nonexistent/none.mv4i`, `--jobs 2`, 2026-08-29
17:49:41 to 18:14:

```
 suite sim   PASS 67   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 93   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 8
```

`REGRESSION: FAIL` on that run, and only because 93 was below the then-current
floor of 101. Nothing was red. 97 rows planned minus 4 NOCHECK is 93, so this is
the ceiling and not merely the score.

### 4.10 The working tree after the fix, MEASURED (appended after `5154518`)

The 99 in section 4.3 was DERIVED (104 planned, 5 NOCHECK, plus 86 + 13). It is
now MEASURED directly: a full unfiltered both-suite run on this workstation's
working tree at `5154518`, `--jobs 2`.

```
 suite sim   PASS 73   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 99   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS
```

Three things this establishes that nothing else did:

1. **The derived ceiling of 99 is exact.** The working tree passes 99 and cannot
   pass more.
2. **The gate is green again.** At the old floor of 101 this identical run would
   have printed `BASELINE DROP: 99 passing, expected at least 101` and
   `REGRESSION: FAIL`, which is what every track was getting.
3. **The new no-raise guard has teeth, on the branch that had never been
   exercised.** Verbatim:

```
 baseline: 99 passing, above the floor of 93 -- but this tree has rows a clean
 checkout does not get: sim:tb_attn_cmp2 sim:tb_attn_fix_beh ... sim:tb_swiglu_ps
 sim:tb_matvec_fk33 sim:tb_matvec_fk33_desc.  DO NOT raise BASELINE_PASS from
 this run: the floor is a CLEAN-CHECKOUT number, and a floor raised to include
 rows that depend on your working tree or your model set is unreachable for
 everybody else, including you after a clean clone.
```

All 20 rows a clean checkout does not get are named: the 18 untracked
testbenches and the 2 rows that ran only because this box holds the model set.
The 99 - 93 = 6 gap decomposes as 4 passing untracked rows plus the 2 FK33 rows.

## 5. Triage of the 18 untracked testbenches

None is a live track's work. MEASURED: every one has an mtime between 2026-07-05
and 2026-07-25, and `git log --all -- <path>` returns zero commits for all 18, so
none was ever tracked and then deleted.

| bench | plan status | why | untracked companion it needs |
|---|---|---|---|
| `tb_attn_cmp2`, `tb_attn_probe_cmp`, `tb_attn_replay`, `tb_divprobe_cmp`, `tb_rms_real`, `tb_sm_cmp`, `tb_sm_cmp24` | SKIP | declares `library beh`: xsim netlist-vs-behavioural compare | -- |
| `tb_embed_ps`, `tb_lm_head_ps`, `tb_matmul_rt_ps`, `tb_rmsnorm_ps`, `tb_softmax_ps`, `tb_swiglu_ps` | SKIP | needs a `*_ps` design unit only a post-synthesis netlist file provides | `sim/post_*_net.vhd`, `sim/*_ps_wrap*.vhd` |
| `tb_attn_fix_beh` | RUN, passes | behavioural half of an xsim compare | `sim/attention_ml_fix.vhd` |
| `tb_attn_replay_beh` | RUN, passes | behavioural half of an xsim compare | `sim/attention_ml_probe.vhd` |
| `tb_engine_dump` | RUN, passes | register-dump harness | `sim/engine_shared_dump.vhd` |
| `tb_rms_sweep` | RUN, NOCHECK | already declared observation-only in `tb_nocheck_reason` | -- |
| `tb_rope_ps` | RUN, passes | its RTL stand-in `sim/rope_ps_rtl.vhd` **is** tracked | none |

**Judgement: none were committed and none were deleted.** Reasons, in order of
weight:

- **Thirteen of the eighteen cannot pass under GHDL at all.** They are halves of
  the xsim post-synthesis compare flow and are SKIPPED by design. Committing them
  would add thirteen SKIP rows and zero coverage.
- **Three of the five that do run drag an untracked RTL companion**
  (`attention_ml_fix.vhd`, `attention_ml_probe.vhd`, `engine_shared_dump.vhd`).
  Committing a bench without its provider converts a passing row into a SKIPPED
  one with an unresolved design unit, which is strictly worse than leaving it.
  Committing the providers means committing RTL variants whose provenance I
  cannot establish and which are outside this track's ownership.
- **Committing any of them changes the shared row set and the floor while three
  other tracks are running**, which is the exact harm this track exists to
  remove.
- **Deleting them is also wrong.** `docs/debugging/2026-08-29_cd-threshold-seed-audit.md`,
  written today and tracked, cites five of them by name and captures a gate run
  in which two of them passed. They are a live debugging flow, not litter.

`sim/regress.sh`'s own header, `SLOW_TBS` and `tb_nocheck_reason` reference
`tb_engine_dump`, `tb_rms_sweep` and the seven `_ps` names directly, and the
suite-qualified `<suite>:<name>` keying exists **because** of the seven `_ps`
files. The gate is documented against a file set the repository does not
contain. That is recorded here rather than resolved, because resolving it means
deciding the fate of the xsim flow, which is an owner's decision and not a gate
hygiene decision.

## 6. Measured and REJECTED -- do not retry

- **Do NOT set `BASELINE_PASS` to 99, or to anything measured on this
  workstation's working tree.** MEASURED: this tree plans 104 rows against a
  clean checkout's 97, and 4 of its passing rows come from files that are not in
  the repository. 99 is not reachable by a clone and never was. This is the exact
  step that produced 101; the gate now refuses to suggest it.
- **Do NOT "fix" the three `tb_matvec_*` rows by committing `sim/tr.txt` alone
  and leaving the gate reading it from `sim/`.** It would have worked today and
  rotted immediately: `sim/run_matvec.sh` REWRITES `sim/tr.txt` at whatever M/K/RI
  its current case asks for, so whichever shape was last left in the tree is the
  shape the gate would measure, silently. That is the hazard the
  `attn_kv_quant_vec.txt` row in `tb_vector_args` already documents from a real
  incident earlier the same day. The gate generates its own copy; the committed
  file exists only for `sim/mutate_matvec_core.sh`.
- **Do NOT make the FK33 rows fail when the `.mv4i` is missing.** They did, as
  BUILD-ERROR, and that is a false claim: it says the tree is broken when an
  optional input is absent, and it made the floor unreachable for anyone without
  an 18 GB GGUF. They SKIP with the path now. The accepted cost is stated in
  `tb_prereq`: those two rows could disappear on a box that has the model set
  without the floor noticing. A floor nobody else can reach detects nothing at
  all, so a floor that misses two optional rows is strictly the better failure.
- **Do NOT make `BASELINE_PASS` count only tracked rows by asking git at gate
  time.** Considered and rejected before implementation: a `git archive` tree has
  no `.git`, and that is precisely the tree the floor is a statement about, so
  the check would be absent exactly where it matters. The reporting is
  git-dependent and skipped in silence without it; the floor is a plain count.
- **Do NOT read `MV_STEP_ORACLE` in `tools/ref9b/seamgate.sh` as an inert
  export.** See correction 10.2. It is load bearing.

## 7. Measurement traps hit

- **`--list` exits before the summary, so it did not print the new NOT IN GIT
  section, and the first teeth check on the IGNORED branch reported `0` rows
  where it should have reported 17.** That reads exactly like a broken detector.
  It was a broken *probe*: `--list` returns at its own `exit 0`. Re-run without
  `--list` and both branches bit. The section is now printed from `--list` too,
  which is the cheap way to run this check, but the trap is that any future probe
  of a summary-section behaviour must not use `--list` unless the section is
  wired into that path.
- **`git ls-files --others --exclude-standard` HIDES ignored files.** This is the
  trap that let `sim/tr.txt` stay invisible for as long as it did, and it very
  nearly did the same to this investigation: the first inventory of untracked
  files under `sim/` listed thirteen `.txt` files and `sim/tr.txt` was not among
  them, which reads as "the brief is wrong, the file is tracked". The ignored
  class needs its own `--ignored` query, and the reporting added here makes both
  queries.
- **`du -sh` on a hardlinked tree under-reports; `git ls-files | xargs du -ch` was
  used instead.** Minor here, but it is the same class as the BC-250 Vivado copy
  trap already recorded in the workstation notes.
- **The mtimes and `git log --all` had to be checked together.** Either alone is
  weak evidence about whether a file is a live track's work: a fresh mtime can be
  a stale file that was merely touched, and a zero-commit history is also what a
  brand-new in-flight file looks like. Both together, on all 18, are conclusive.
- **Load average moved from 2.7 to 8.4 during the full run** because other tracks
  were active. It produced no failures here (FAIL 0), but a run in these
  conditions that HAD shown failures in untouched files would have needed
  re-running on a quiet box before being believed.

## 8. What was NOT verified

- **The 93 was measured on `git archive 9ad4c14` plus this patch, not on an
  archive of the final commit.** Four commits landed while the run was in flight
  (`01a9e95`, `b28e92b`, `78e0e4a`, `0e4f98d`). MEASURED that none of them adds
  or removes a gate row: `git diff --diff-filter=AD --name-only 9ad4c14 HEAD --
  'sim/tb_*.vhd' 'tb/tb_*.vhd'` is empty, so the row count and therefore the
  ceiling are unchanged. What is NOT verified by my run is the three `seamgate_*`
  rows at their RAISED floors: TRACK RY-MODEL moved them from 61/60/59 to 64/63/61
  in `78e0e4a`, and my run used the old `tools/ref9b/seamgate.sh`. Those rows
  passed at the old floors here and RY-MODEL measured them at the new ones, but no
  single run has covered both.

  **CLOSED, appended 2026-08-29 after commit `1399425`.** Re-measured on a true
  `git archive 1399425` tree, which carries RY-MODEL's raised floors:

  ```
  PASS  sim:seamgate_real  38s  SEAMGATE PASS -- real: 1 token(s), at least 64 seams per token
  ```

  and the three formerly broken rows, on the same tree, clone-faithful:

  ```
  PASS     sim:tb_matvec_core      2s      PASS     sim:tb_matvec_int4     1s
  PASS     sim:tb_matvec_axi       1s      PASS     sim:tb_matvec_core_ragsat  3s
  SKIPPED  sim:tb_matvec_fk33      external prerequisite not in this tree and not in git: ...
  SKIPPED  sim:tb_matvec_fk33_desc external prerequisite not in this tree and not in git: ...
  ```

  That tree plans `RUN=97 SKIP=8`, identical to the tree the 93 was measured on,
  so the ceiling is unchanged and `seamgate_real` holds at the raised floor.
  `seamgate_stub` and `seamgate_seq` were NOT re-run at the new floors here; `seq`
  is a three-token capture at roughly 110 s plus bisect and there was one full-run
  budget for this track. They passed at the old floors and RY-MODEL measured them
  at the new ones.
- **`--quick` was not re-timed** after the prerequisite skip moved two rows out of
  it on a box without the model set.
- **Whether the xsim compare flow should live in the repository at all** is not
  answered here. See section 9.

## 9. Open, not yet answered

1. **The 18 untracked benches need an owner's decision**, not a gate decision.
   Three outcomes are possible per file: commit it with its RTL companion, delete
   it, or record it as deliberately local. This track deliberately did none of
   them, for the reasons in section 5. They are now VISIBLE in every gate run
   instead of silently shaping the row set, which was the actual defect.
2. **`sim/tr.txt` is now a tracked file that `sim/run_matvec.sh` overwrites.**
   That is an improvement over ignored-and-invisible, but it means a sweep run
   leaves a modified tracked file in the shared tree, one careless pathspec-free
   commit away from landing. Restoring it is `git checkout -- sim/tr.txt`. The
   cleaner fix, not taken here because `sim/run_matvec.sh` is outside this track's
   ownership, is for that script to write its per-case traces to a scratch path.
3. **`sim/mutate_matvec_core.sh`'s `cmp` against `sim/tr.txt` is now
   belt-and-braces.** The gate generates its trace with the same argv that script
   uses for column A, so trace A is the gate trace by construction rather than by
   working-tree coincidence. The `cmp` can be dropped by whoever owns that script;
   it is harmless meanwhile and it is why the file is committed.
4. **`sim/regress.sh`'s header, `SLOW_TBS` and `tb_nocheck_reason` document
   `tb_engine_dump`, `tb_rms_sweep` and the seven `_ps` names**, none of which the
   repository contains. Those tables are correct for this workstation and
   misleading for a clone. Resolving them depends on item 1.

## 10. Corrections

### 10.1 To the dispatching brief

- **"`sim/tr.txt` is untracked" understates it: it is `.gitignore`d**
  (`.gitignore:63`), so `git status` was silent about it. That is why it survived
  as a load-bearing gate input, and it changes the fix: an ignored file needs a
  separate `--ignored` query to be seen at all.
- **"Several of the 18 may be other tracks' in-flight work" is false for all 18.**
  MEASURED: mtimes 2026-07-05 to 2026-07-25, and zero commits in `git log --all`
  for every one. The brief's caution was reasonable and the measurement
  contradicts it.
- **"A `git archive` tree plans 102 rows, ceiling 92" was correct at `9d7a9e5` and
  is 99 rows at `9ad4c14`.** The ceiling-92 figure reproduces: 99 planned, 4
  NOCHECK, 3 rows lost to `tr.txt`, giving 92.
- **The floor being "calibrated against ~20 untracked benches" is right in
  mechanism but understates the consequence.** 101 was above even the working
  tree's ceiling of 99, so the gate was failing for everyone, not merely
  unreachable for a clone.

### 10.2 To the coordinator's mid-task message

- **Item 1 confirmed and fixed.** `sim/regress.sh` carried 61/60/59 in two places;
  `tools/ref9b/seamgate.sh`'s `case "$CFG"` block reads `real) FLOOR=64`,
  `stub) FLOOR=63`, `seq) FLOOR=61`. Both sites now read 64/63/61 and both now say
  that `seamgate.sh` is the authority and that these are a copy, because a copy is
  what went stale.
- **Item 2 is a misreading, and there is nothing to fix.** `MV_STEP_ORACLE` is NOT
  inert. `tools/ref9b/bisect_scaled.py:175` reads:
  ```python
  exe = os.environ.get("MV_STEP_ORACLE") or os.path.join(HERE, "mv_step_oracle")
  ```
  The environment variable takes precedence; `os.path.join(HERE, ...)` is the
  fallback half of an `or`, not the resolution. The export is deliberate and its
  reason is documented in that function's own comment: `seamgate.sh` builds the
  binary into its scratch directory so a gate row does not write into the working
  tree and two concurrent runs do not race over one file.
  `tools/ref9b/mutate_seamgate.sh:206,217` depends on the override working.
- **"`BASELINE_PASS` is now 101, check rather than trust me" confirmed** at
  `sim/regress.sh:387` before this change, and it is the value this track
  measured as unreachable.
</content>
