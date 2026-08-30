# OI-3's two named mutations, run against the gate that should catch them

TRACK OI3MUT, backlog row **N6**. 2026-08-29.
Worked against `git rev-parse HEAD` = **`3d5cba9614d41f454f3d080cdf93968335adee28`**
for the first two rounds and re-confirmed at **`f257466b8a36146b26166016a4dd39d31cef3696`**.
GHDL 1.0.0 mcode. **No hardware was touched. GHDL only.**

## The question, verbatim

> **OI-3's two named mutations have never been run against the gate that is
> supposed to catch them.**
>
> TRACK OI3B (`5578132`) gave `tb_llama_top` a real value gate, `P14`, pinning
> `L_X0`. The two defects OI-3 names live in `rtl/llama_top.vhd`:
> `c_exp_region <= to_unsigned(R_VIN, 8)` (an exponent claim re-aimed at `R_X`)
> and `if k >= 2 then qg_buf(k-2) <= el_rdata` (a prefetch consuming at k-3).
> Both sit inside the configuration `tb_llama_top_real` exercises, and both
> move `R_X(0)`. **So the gate SHOULD kill them.** But MEASURED by TRACK
> BOARDAUDIT: no mutate script and no line of OI3B's teeth table names either
> one.
>
> The two outcomes are both valuable and you must not prefer either. If the
> gate kills them, OI-3's two defect classes are closed and the board says so
> with evidence. **If the gate does NOT kill them, that is the bigger
> finding.**

## The answer, up front

**The gate kills both, and P14 is the sole detector in three of the four
mutant-by-configuration pairs.** MEASURED, ten runs:

* **P5r / P6r**, the two mutations in the real-path configuration
  (`tb_llama_top_real`'s exact generics): **both KILLED, on all four
  landmarks**, with every structural counter reading zero -- `schedule
  mismatches=0 skew differences=0 degenerate residuals=0 token position
  faults=0`. The kill is P14's alone.
* **P5rx / P6rx**, the identical mutants with all four landmarks left at their
  sentinels -- which is the pre-OI3B bench exactly: **both SURVIVED**, printing
  `RESULT: PASS`. So **OI-3's original "PASSES BROKEN" finding is reproduced at
  today's commit**, not merely quoted, and the difference between PASS and FAIL
  on the same mutant is P14 and nothing else.
* **P6s** kills in the KV configuration too, cleanly and on P14 alone.
* **One row does NOT belong to P14 and is reported under its own name.**
  **P5s**: in the KV configuration the exponent-claim mutant ALSO trips the
  degenerate-residual property, `degenerate residuals=10`, and its unpinned
  twin **P5sx is KILLED**. In that one configuration an existing structural
  check already saw the defect. Crediting P14 with that detection would have
  been the error this table exists to prevent.

So **backlog row N6 closes and backlog row 7 ("OI-3 proper") closes with it**
for these two defects: the classes the bench structurally could not see are now
seen, by a value landmark, with the attribution measured rather than assumed.

**What this does NOT say.** A landmark is a change detector, not an oracle.
P14 proves the numbers moved away from a recorded value; it does not prove the
recorded value is right. `-16364 / 91622 / 91622 / 17333` is what this design
computes, not what Qwen3.5-9B computes. Nothing here touches that.

## The procedure, in the order it was run

Each step isolates one thing.

1. **Verify BOARDAUDIT's premise independently, rather than inheriting it.**
   `grep -rn 'c_exp_region\|qg_buf\|R_VIN\|k-3' sim/mutate_*.sh` and the same
   grep over `docs/debugging/2026-08-29_oi3b-top-level-value-gate.md` both
   returned **zero hits**. The premise held: neither mutation had ever been run
   against P14.
2. **Locate both defects BY CONTENT.** Line numbers in `rtl/llama_top.vhd` were
   measured moving `:782 -> :789 -> :835` inside one hour on 2026-08-29, and
   three tracks landed in that file the same night. Both anchors were checked
   for a count of exactly 1 before anything ran; `mutate_n` enforces the count
   at run time so a future edit that duplicates a line fails the row rather
   than silently mutating one of two sites.
3. **Pin the sha as its own step, then `git archive` it.** `SHA=$(git rev-parse
   HEAD)` printed `3d5cba9614d41f454f3d080cdf93968335adee28`; the archive was
   taken with that literal. HEAD had already moved off the sha named in the
   brief before the first command ran, and moved again to `f257466` during the
   session.
4. **Mutate the ARCHIVE tree, never the repository copy.** `rtl/llama_top.vhd`
   is owned by TRACK CLOG2TOP. Nothing in this track wrote to it.
5. **Run the clean-design controls first.** `P0s` and `P0r` -- the unmutated
   design with all four landmarks pinned -- must PASS, or a red mutant row is
   measuring the harness.
6. **Run the two mutations in both configurations with the landmarks pinned**
   (`P5r`, `P5s`, `P6r`, `P6s`).
7. **Read the run logs for what ELSE failed.** A KILL says the RUN failed, not
   which check failed. This step is what found `degenerate residuals=10` on
   `P5s`.
8. **Run the attribution control**: the same four mutants with all four
   landmarks UNSET (`P5rx`, `P5sx`, `P6rx`, `P6sx`). That configuration is the
   pre-OI3B bench. A SURVIVE there means the kill above was P14's; a KILL means
   an older property already covered it.
9. **Re-confirm the committed form of the script** against a fresh archive of
   the new HEAD `f257466`, because the repository moved twice during the runs.
   `P0r`, `P5r`, `P5rx`, `P6r`, `P6rx` reproduced **byte-identical** numbers.

## The evidence, raw

### The mutations, exactly

```
P5:  c_exp_region <= to_unsigned(R_VIN, 8);
  -> c_exp_region <= to_unsigned(R_X, 8);                       (1 occurrence)

P6:  if k >= 2 then qg_buf(k-2) <= el_rdata; end if;
  -> if k >= 3 then qg_buf(k-3) <= el_rdata; end if;            (1 occurrence)
```

### The controls, and the two mutants with the landmarks pinned

```
--- controls: the clean design must PASS with its landmarks pinned ---
P0s  SURVIVED   -- CONTROL: clean, the KV configuration, all four landmarks pinned
        P14 landmarks measured -- EXP_X0 => -732, EXP_XSUM => 86454, EXP_XALL => 79978, EXP_STEPH => 50729   (0 of the pinned landmarks moved)
P0r  SURVIVED   -- CONTROL: clean, the real-path configuration, all four landmarks pinned
        P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 17333   (0 of the pinned landmarks moved)

--- P5/P6: THE TWO MUTATIONS OI-3 NAMED.  Backlog row N6. ---
P5r  KILLED     -- OI-3 mutation 1: unit C's R_VIN exponent claim re-aimed at R_X, the real-path configuration
        P14 -- R_X(0) is -16592 and the recorded landmark for this configuration is -16364.  The machine computed different numbers.
        P14 -- hash(R_X) over the last token is 64581 and the recorded landmark is 91622.
        P14 -- hash(R_X) over ALL 1 tokens is 64581 and the recorded landmark is 91622.
        P14 -- hash of the 64-completion step trace is 8005 and the recorded landmark is 17333.
        P14 landmarks measured -- EXP_X0 => -16592, EXP_XSUM => 64581, EXP_XALL => 64581, EXP_STEPH => 8005   (4 of the pinned landmarks moved)
P5s  KILLED     -- the SAME mutation in the KV configuration
        P14 -- R_X(0) is 22046 and the recorded landmark for this configuration is -732.
        P14 -- hash(R_X) over the last token is 81092 and the recorded landmark is 86454.
        P14 -- hash(R_X) over ALL 3 tokens is 10029 and the recorded landmark is 79978.
        P14 -- hash of the 61-completion step trace is 23708 and the recorded landmark is 50729.
        P14 landmarks measured -- EXP_X0 => 22046, EXP_XSUM => 81092, EXP_XALL => 10029, EXP_STEPH => 23708   (4 of the pinned landmarks moved)
P6r  KILLED     -- OI-3 mutation 2: the R_QG prefetch consumes at k-3 instead of k-2, the real-path configuration
        P14 -- R_X(0) is -16028 and the recorded landmark for this configuration is -16364.
        P14 -- hash(R_X) over the last token is 12318 and the recorded landmark is 91622.
        P14 -- hash(R_X) over ALL 1 tokens is 12318 and the recorded landmark is 91622.
        P14 -- hash of the 64-completion step trace is 94599 and the recorded landmark is 17333.
        P14 landmarks measured -- EXP_X0 => -16028, EXP_XSUM => 12318, EXP_XALL => 12318, EXP_STEPH => 94599   (4 of the pinned landmarks moved)
P6s  KILLED     -- the SAME mutation in the KV configuration
        P14 -- R_X(0) is -1439 and the recorded landmark for this configuration is -732.
        P14 -- hash(R_X) over the last token is 56703 and the recorded landmark is 86454.
        P14 -- hash(R_X) over ALL 3 tokens is 56334 and the recorded landmark is 79978.
        P14 -- hash of the 61-completion step trace is 4778 and the recorded landmark is 50729.
        P14 landmarks measured -- EXP_X0 => -1439, EXP_XSUM => 56703, EXP_XALL => 56334, EXP_STEPH => 4778   (4 of the pinned landmarks moved)
```

### The attribution control -- the same four mutants with the landmarks UNSET

```
P5rx  SURVIVED   -- ATTRIBUTION: OI-3 mutation 1, real path, landmarks UNSET -- the pre-OI3B gate
        P14 landmarks measured -- EXP_X0 => -16592, EXP_XSUM => 64581, EXP_XALL => 64581, EXP_STEPH => 8005   (0 of the pinned landmarks moved)
P5sx  KILLED     -- ATTRIBUTION: OI-3 mutation 1, KV path, landmarks UNSET -- the pre-OI3B gate
        P14 landmarks measured -- EXP_X0 => 22046, EXP_XSUM => 81092, EXP_XALL => 10029, EXP_STEPH => 23708   (0 of the pinned landmarks moved)
P6rx  SURVIVED   -- ATTRIBUTION: OI-3 mutation 2, real path, landmarks UNSET -- the pre-OI3B gate
        P14 landmarks measured -- EXP_X0 => -16028, EXP_XSUM => 12318, EXP_XALL => 12318, EXP_STEPH => 94599   (0 of the pinned landmarks moved)
P6sx  SURVIVED   -- ATTRIBUTION: OI-3 mutation 2, KV path, landmarks UNSET -- the pre-OI3B gate
        P14 landmarks measured -- EXP_X0 => -1439, EXP_XSUM => 56703, EXP_XALL => 56334, EXP_STEPH => 4778   (0 of the pinned landmarks moved)
```

### What else failed in each run -- the step that separates P14 from its neighbours

Every mutant's own `run.log`, grepped for the structural summary and for
error-severity lines that are not P14's:

```
=== P0r ===  schedule mismatches=0 skew differences=0 degenerate residuals=0 token position faults=0 KV sticky errors=0 KV faults=0
             RESULT: PASS -- R_X(0) = -16364 hash(R_X) = 91622
             (no error-severity lines)
=== P5r ===  schedule mismatches=0 skew differences=0 degenerate residuals=0 token position faults=0 KV sticky errors=0 KV faults=0
             RESULT: FAIL      (no error-severity line other than P14's four and the verdict itself)
=== P6r ===  schedule mismatches=0 skew differences=0 degenerate residuals=0 token position faults=0 KV sticky errors=0 KV faults=0
             RESULT: FAIL      (no error-severity line other than P14's four and the verdict itself)
=== P0s ===  schedule mismatches=0 skew differences=0 degenerate residuals=0 ...
             RESULT: PASS -- R_X(0) = -732 hash(R_X) = 86454
=== P5s ===  schedule mismatches=0 skew differences=0 degenerate residuals=10 ...
             RESULT: FAIL, and ALSO:
             tb_llama_top.vhd:2041: the residual at step 39 has operand exponents -12 and 5,
               17 apart against a 16-bit mantissa.  One operand shifts out ENTIRELY.
             tb_llama_top.vhd:2041: the residual at step 58 has operand exponents -19 and -2, 17 apart ...
             (6 such lines across the latency points)
=== P6s ===  schedule mismatches=0 skew differences=0 degenerate residuals=0 ...
             RESULT: FAIL      (no error-severity line other than P14's four and the verdict itself)
```

### The re-confirmation at the newer HEAD

`git archive f257466b8a36146b26166016a4dd39d31cef3696` plus the committed form
of the script, five rows, byte-identical numbers to the run against `3d5cba9`:

```
P0r  SURVIVED   -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 17333   (0 moved)
P5r  KILLED     -- EXP_X0 => -16592, EXP_XSUM => 64581, EXP_XALL => 64581, EXP_STEPH => 8005    (4 moved)
P5rx SURVIVED   -- EXP_X0 => -16592, EXP_XSUM => 64581, EXP_XALL => 64581, EXP_STEPH => 8005    (0 moved)
P6r  KILLED     -- EXP_X0 => -16028, EXP_XSUM => 12318, EXP_XALL => 12318, EXP_STEPH => 94599   (4 moved)
P6rx SURVIVED   -- EXP_X0 => -16028, EXP_XSUM => 12318, EXP_XALL => 12318, EXP_STEPH => 94599   (0 moved)
```

### Summary table

| row | mutation | config | landmarks | verdict | detector |
|---|---|---|---|---|---|
| P0s | none (control) | KV | pinned | SURVIVED (PASS) | -- |
| P0r | none (control) | real | pinned | SURVIVED (PASS) | -- |
| P5r | R_VIN claim -> R_X | real | pinned | **KILLED**, 4/4 moved | **P14 alone** |
| P5rx | R_VIN claim -> R_X | real | unset | SURVIVED | -- (pre-OI3B gate is blind) |
| P5s | R_VIN claim -> R_X | KV | pinned | **KILLED**, 4/4 moved | P14 **and** the degenerate-residual property |
| P5sx | R_VIN claim -> R_X | KV | unset | **KILLED** | the degenerate-residual property |
| P6r | qg prefetch at k-3 | real | pinned | **KILLED**, 4/4 moved | **P14 alone** |
| P6rx | qg prefetch at k-3 | real | unset | SURVIVED | -- (pre-OI3B gate is blind) |
| P6s | qg prefetch at k-3 | KV | pinned | **KILLED**, 4/4 moved | **P14 alone** |
| P6sx | qg prefetch at k-3 | KV | unset | SURVIVED | -- (pre-OI3B gate is blind) |

Coverage statement, explicit rather than left to subtraction: **10 rows run, 10
rows produced a RESULT line, 0 rows aborted, 0 rows failed to analyze.** Two
configurations were exercised, `tb_llama_top_real`'s and `tb_llama_top_seq`'s;
the other four `tb_llama_top*` wrappers were not run here.

## Measured and REJECTED -- do not retry

* **`qg_buf(k-1)` as the prefetch mutation.** It indexes `qg_buf(QGN)` at
  `k = QGN+1` and aborts with an index-out-of-bounds. That is a broken mutant,
  not a result: the design never computes and the gate never judges. PART 7 of
  `2026-08-28_llama-top-first-seams.md` recorded this and it was not
  re-attempted here. **The useful mutation moves the index the other way,
  `k-3`, and the guard has to move with it or `k = 2` writes `qg_buf(-1)`.**
* **Re-aiming the R_VIN claim at R_ALPHA.** Also recorded by PART 7 and not
  retried: the two regions happen to carry the same captured exponent in that
  run, so the mutation is a **no-op**, the hash is bit-identical, and the row
  reads as "the guard has no teeth" when it is really "nothing was mutated".
  R_X's exponent is far away, which is why R_X is the mutation.
* **Reading a KILL as evidence about P14.** Rejected as a method. `P5s` kills
  and `P5sx` kills, so in the KV configuration the exponent-claim defect was
  already covered before OI3B existed. Without the unpinned twin this table
  would have credited P14 with four detections instead of three.
* **Running the mutation table against the live repository tree.** Not done and
  should not be. `rtl/llama_top.vhd` had three landings in one night and
  `rtl/attn_block.vhd` was being rewritten by TRACK WRITEDEC during these runs;
  a mutation run against that tree measures the other track. Every row here ran
  against a `git archive` of a named sha.

## Measurement traps hit, including my own

* **HEAD moved between reading the brief and the first command.** The brief
  named a sha; `git rev-parse HEAD` as its own step printed `3d5cba9`, and by
  the time the runs finished HEAD was `f257466`. This is exactly the trap the
  brief warns about, and it fired within one minute of starting. The response
  was to name the sha in the archive command literally and, at the end, to
  re-run the headline rows against a fresh archive of the new HEAD -- which is
  the only reason this document can claim its numbers hold at HEAD rather than
  at a tree that no longer exists.
* **A three-way verdict is not a two-way one.** `row` distinguishes SURVIVED,
  KILLED and KILLED(ABORT). No row aborted here, but the distinction is what
  makes the `k-1` rejection above a rejection rather than a kill.
* **The `row` helper prints the landmark line on a SURVIVED row too, and that
  is the load-bearing half of the attribution control.** `P5rx` survived while
  printing `EXP_X0 => -16592` against the clean `-16364`. Without that line a
  reader could not tell "the mutant reached the checker and the numbers did not
  move" from "the mutant never ran". Both would print SURVIVED.
* **`nohup ... &` reports the launcher's exit code.** Every run here was
  launched with `setsid nohup ... < /dev/null &` and waited on by reading the
  log, never by trusting a returned status.

## What was NOT verified

* **The full gate was not run.** Three other tracks were live and one was
  running Vivado; a `sim/regress.sh` run under that contention measures the
  contention. **This change cannot move `BASELINE_PASS`:** it adds no
  `sim/tb_*.vhd`, and `sim/regress.sh` does not auto-discover `mutate_*.sh`
  (MEASURED: `grep -n mutate sim/regress.sh` shows them referenced only as
  named vector generators in comments). `sim/regress.sh` was not edited by this
  track and `git diff -- sim/regress.sh` was empty at commit time.
* **KVVALUE's claimed floor move 93 -> 94 was not measured**, for the same
  contention reason. It remains that track's claim, unconfirmed here.
* **Whether the landmarks are RIGHT.** P14 compares against recorded numbers
  produced by this same design. Nothing in this track is an oracle. The
  standing open item from PART 7 is unchanged: nothing establishes that
  `attn_block` computes attention.
* **The other four `tb_llama_top*` wrappers.** `_normw`, `_smp`, `_smp_beh`
  and `_seq` were not run with these mutations. `_seq`'s configuration was
  covered through the `G_SEQ` generics inside this harness, which is the same
  shape, not the same wrapper.
* **`sim/tb_llama_top.vhd` was not edited.** TRACK KVVALUE owns it. The one
  bench file touched here is `sim/tb_llama_top_real.vhd`, header comment only,
  no generic and no landmark changed.

## Corrections to the brief

* The brief says the two defects "sit inside the configuration
  `tb_llama_top_real` exercises, and both move `R_X(0)`. **So the gate SHOULD
  kill them.**" That is right, and it is now MEASURED -- but the brief's
  implicit model, that a kill would settle it, was incomplete. **In one of the
  four pairs the kill is not P14's**, and only the unpinned control separates
  the two. A future row of this kind should be dispatched with the attribution
  control written into the brief.
* The brief's line numbers warning was correct and load-bearing: the anchors
  `c_exp_region <= to_unsigned(R_VIN, 8);` and
  `if k >= 2 then qg_buf(k-2) <= el_rdata; end if;` are each unique in the file
  at both shas, and neither is at any line number quoted anywhere in `docs/`.
