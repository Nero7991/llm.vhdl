# The top-level benches could not fail on a wrong number, and now they can

**Date:** 2026-08-29. Branch `fpga`. Track OI3B.
**Design under test:** `sim/tb_llama_top.vhd` and its five wrappers, at
commit **`35e0ed0`** for the landmark measurements and **`4736950`** for the
reproduction of TRACK C-SEAM's two results. HEAD moved twice under this track
(`4736950` -> `35e0ed0` -> `729c9b8`); every number below names the tree it was
taken on, and every measurement was taken on a `git archive <sha>` snapshot,
never on the working tree, because three other tracks had uncommitted edits in
it throughout.

**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado ...
program`, nothing under `hw/fk33/`, nothing opening `/dev/xdma*`. No Vivado at
all: every number here comes from GHDL 1.0.0 (mcode).

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

From this track's brief:

> **THE TASK: the top-level benches cannot fail.**
> TRACK C-SEAM raised this as **OI-3b** and could not fix it because it does
> not own the file:
>
> - `sim/tb_llama_top_seq.vhd` **PASSES with defect C1 fully restored** in
>   `rtl/attn_block.vhd` (299 s, `OVERALL PASS 1 FAIL 0`).
> - As a negative control, because a PASS is otherwise indistinguishable from
>   a mutant that never reached the checker, it collapsed `v_ref` to a
>   **single register shared across every layer AND every KV head** -- strictly
>   worse than C1. **It PASSES again** (319 s).
> - Cause: the bench's `R_X` landmark is `report`ed, never `assert`ed. Its
>   actual gate is self-consistency across KV read latencies, and **a
>   deterministic defect is consistent with itself.**
>
> Your job:
> 1. **Reproduce both results first.**
> 2. Give the `tb_llama_top*` family gates that can actually fail.
> 3. **Teeth-check by construction**: every gate you add must be shown going
>    red on a named mutation, and C1-restored plus the shared-`v_ref` control
>    must BOTH be killed by the finished bench.
> 4. Audit the whole family for the same shape.

---

## 2. The answer, up front

**Both of C-SEAM's results reproduce exactly, and the numbers were sitting in
the PASS line the whole time.** MEASURED at `4736950`, three runs in parallel:

| tree | verdict | R_X(0) | hash(R_X) |
|---|---|---|---|
| clean | `OVERALL PASS 1 FAIL 0`, 295 s | **-14252** | **7668** |
| defect C1 restored, 4 sites | `OVERALL PASS 1 FAIL 0`, 293 s | **-14240** | **97483** |
| `v_ref` collapsed to one register | `OVERALL PASS 1 FAIL 0`, 295 s | **-14240** | **97483** |

**Both mutants moved both published numbers and the bench printed them and
compared them against nothing.** The gate was not blind to the defect; it was
holding the evidence in its hand and had no branch on it.

**The fix is a value gate, `P14`, with four landmarks that reach `fail`.**
`fail` already drives `report ... RESULT: FAIL severity failure`, which
`sim/regress.sh` scores red on three independent literals, so the new checks
ride a verdict path that was already proven rather than inventing one.

| landmark | what it hashes | reach |
|---|---|---|
| `EXP_X0` | `results(0)(NTOK-1)(0)` | the element-0 number this file's header has quoted since 2026-08-28 |
| `EXP_XSUM` | `hash(R_X)`, last token, run 0 | the other half of the published pair |
| `EXP_XALL` | the same hash over **every** token | a defect that moves token 1 and reconverges |
| `EXP_STEPH` | every completion's captured exponent and write hash | **seams the residual's alignment discards** |

**Teeth, MEASURED, `sim/mutate_llama_top_land.sh` at `35e0ed0`.** Which
landmarks moved is the column that matters, not the verdict:

| row | mutation | X0 | XSUM | XALL | STEPH | verdict |
|---|---|:-:|:-:|:-:|:-:|---|
| P0s | CONTROL, clean, KV configuration | . | . | . | . | **SURVIVED** |
| P0r | CONTROL, clean, real-path configuration | . | . | . | . | **SURVIVED** |
| P1 | defect C1 restored, all four `vref_r` sites | X | X | X | X | **KILLED** |
| P2 | the shared-`v_ref` negative control | X | X | X | X | **KILLED** |
| P3 | `gdn_silu`'s `rsh_r` truncates, all THREE sites | . | X | X | X | **KILLED** |
| P3x | P3 with `EXP_STEPH` unset | . | X | X | -- | **KILLED** |
| **P3b** | **only the SiLU EMIT truncates (CAPTURE's m3)** | **.** | **.** | **.** | **X** | **KILLED** |
| **P3bx** | **P3b with `EXP_STEPH` unset** | **.** | **.** | **.** | -- | **SURVIVED** |
| P4s | AXIS: clean, unpinned, `XALL` must differ from `XSUM` | . | . | . | . | SURVIVED |
| P4r | AXIS: clean, unpinned, the `NO VALUE GATE` note must fire | . | . | . | . | SURVIVED |

**P3b / P3bx is the pair that earns `EXP_STEPH` its place**, and it closes the
sixth OI-3 instance TRACK CAPTURE named: the `gdn_silu` emit truncation leaves
`R_X(0)`, `hash(R_X)` and the all-token hash **bit-identical** and moves the
step trace from 17333 to 34846. With `EXP_STEPH` unset it SURVIVES the other
three landmarks. Section 7.4.

**P3 was not the mutation its name claimed, and it is reported under its own
name rather than quietly replaced.** MEASURED: `rsh_r` has THREE call sites in
`rtl/gdn_silu.vhd` (`:275`, `:336`, `:358`) and P3 mutates the function BODY,
so it truncates all three and does move `R_X`. A broader mutation that kills
says nothing about whether the narrow one would. P3b is the narrow one and it
is the row that carries the claim.

**The per-bench audit, and it is not uniform.** Four of the six had no
falsifiable value gate; two already had one and it was already teeth-checked
by another track. Section 8.

---

## 3. Corrections to the brief and to the dispatcher's follow-up

Reported under their own heading because the brief asked for it.

1. **"the bench's `R_X` landmark is `report`ed, never `assert`ed" is true and
   is not the whole cause.** MEASURED: `fail` at `35e0ed0` is
   `n_bad_sched + n_bad_skew + n_bad_res + n_bad_pos + n_bad_kverr +
   kv_bad_wr + kv_bad_rd + kv_bad_dat + kv_bad_cov + kv_bad_bresp +
   n_bad_cap + n_smp_hole + n_smp_ovr + n_smp_cnt` -- fourteen counters, every
   one of them structural. Turning the `report` into an `assert` would have
   fixed it; so would any other branch. The cause is that **no quantity
   derived from the machine's arithmetic reached the verdict at all**, and
   that is a stronger statement than "one landmark was not asserted".

2. **The dispatcher's mid-task counts do not reproduce, and the third
   consequence drawn from them is a misreading.** MEASURED with
   `git show HEAD:<file> | grep -cE '\bassert\b'`:

   | file | dispatcher | measured at `35e0ed0` |
   |---|---|---|
   | `tb_llama_top.vhd` | asserts=45 reports=99 | **asserts=35 reports=85** |
   | `tb_llama_top_smp.vhd` | asserts=16 reports=23 | asserts=16 reports=23 |

   The working tree at the time held TRACK LOGITS' uncommitted +204 lines
   (asserts=36 reports=88), so neither number is the working tree either.
   More importantly: **"`tb_llama_top_seq` has zero reports, so it must be
   emitting its PASS marker through `write`/`writeline`" is wrong.**
   `sim/tb_llama_top_seq.vhd` is a 61-line WRAPPER whose whole body is one
   `entity work.tb_llama_top` instantiation; its own header says so and says
   why. The PASS marker is `report`ed by `sim/tb_llama_top.vhd:2490` (at
   `4736950`). MEASURED: `grep -c writeline` is 0 in all five wrappers and 4
   in `tb_llama_top.vhd`, none of them the verdict.

   The dispatcher's first two consequences stand and were both acted on:
   the mechanism chosen is a fault counter reaching the existing textual
   `RESULT: FAIL` path, and the three-way KILLED / KILLED(ABORT) / SURVIVED
   split is implemented so a run that DIED is never scored as a detection.

3. **C-SEAM's negative control is NOT strictly worse than defect C1 at this
   configuration; it is observationally IDENTICAL to it.** MEASURED, section
   2: collapsing `vref_r` to a single register shared across every layer AND
   every KV head produces `R_X(0) = -14240 hash(R_X) = 97483`, the same two
   numbers as C1, which keeps the head dimension. C-SEAM's reasoning that it
   is *more destructive* is sound in the abstract and does not hold here.
   It remains a valid control -- it establishes that the mutant reaches the
   checker -- but it does **not** establish a second, independent point on the
   defect axis. MEASURED again, and more strongly, once the gate existed: at
   `P1` and `P2` the two mutants agree on **all four** landmarks, not only the
   two published ones (`-14240`, `97483`, `15121`, `4794` in both rows). Both
   rows are kept and this is why.

4. **`sim/regress.sh` was NOT touched and `BASELINE_PASS` stays 94.** No
   `sim/tb_*.vhd` is added: `sim/mutate_llama_top_land.sh` is a script, not a
   testbench, so no gate row appears.

---

## 4. The procedure, in the order it was run

Each step says what it isolates.

1. **Reproduce before changing anything, on `git archive` snapshots.** Three
   trees from `4736950`: clean, C1, and the shared-`v_ref` control. The clean
   run is the control that says the machine is quiet and the mutants are the
   only variable. Isolates "is the claim true" from "is the box busy".
2. **Read the verdict, not the properties.** The useful question was not
   "which checks exist" but "what reaches `fail`". One `grep` on the `fail <=`
   assignment answered in a way that reading 35 asserts would not have.
3. **Harvest the landmark from the CLEAN mutants' logs before designing
   anything.** This is the step that decided the whole design: the two mutants
   print different numbers from the clean run, so a landmark comparison is
   sufficient and no new instrumentation is needed. Had they printed the same
   numbers, a landmark would have been useless and the fix would have had to
   be a seam-level oracle.
4. **Design the gate so the failure path is one that already works.**
   `n_bad_land` joins `fail`; `fail /= 0` already reports `RESULT: FAIL` at
   `severity failure`. Isolates "does the check fire" from "does the runner
   score it", which are different claims and this project has been bitten by
   the second one.
5. **Measure the landmarks on the unmutated tree, with the gate installed but
   unset.** Four rows, run in parallel. The bench prints its own four numbers
   in a paste-ready form precisely so nobody transcribes them out of prose.
6. **Pin them, and re-run the clean design as a control.** `P0s` and `P0r`.
   A matrix whose control does not pass measures the bench's own breakage.
7. **Teeth, and one of them deliberately paired.** `P1`/`P2` are the two
   mutants the old gate could not see. `P3`/`P3x` is the pair that asks
   whether `EXP_STEPH` earns its place: the same mutation with the landmark
   pinned and with it unset. If `P3x` had killed, `EXP_STEPH` would be
   redundant and should be deleted.
8. **Axis checks, not defect rows.** `P4s` asks whether the token axis is
   actually in `EXP_XALL`, because a hash computed over a dimension that
   happens to be constant would kill every mutant that moves anything and
   still be blind to that dimension. C-SEAM's `L7` pattern.
9. **Audit the other two family members against the recorded mutation
   evidence rather than re-running it.**
10. **Full gate.**

---

## 5. The design, and the three things it deliberately is not

**It is a GOLDEN LANDMARK, not an oracle.** A landmark is taken from a run of
this design, so it says "the numbers are what they were when a human last
looked", never "the numbers are attention". Written down because the
temptation to describe this as "the integration bench now has a value oracle"
is exactly the overstatement this project keeps paying for. The independent
oracles are elsewhere and stay there:

* `ref/attn_block_seq_vec.c` through `sim/tb_attn_kv_seam.vhd`, bit-exact, at
  the BLOCK level -- the thing that actually kills C1 on correctness.
* `tools/ref9b/bisect_scaled.py` through the `CAPTURE` generic, 58 of 63
  seams, driven by `sim/mutate_llama_top_kv.sh`'s V rows.

What a landmark does, and what nothing in this family did before, is **fail**.

**It is not in `sim/mutate_llama_top_kv.sh`.** That file's 23 rows and their
recorded verdicts are a measurement of the STRUCTURAL checkers' resolution
floor, taken over two days and quoted in two write-ups. Installing a value
gate in the entity changes what several of those rows would report, so folding
these rows in would silently re-base a table whose whole worth is that it is
comparable with its own history. The new rows live in
`sim/mutate_llama_top_land.sh`.

**It is not applied to the mutation harness's runs, and that was a design
constraint rather than an oversight.** `sim/mutate_llama_top_kv.sh` runs the
`tb_llama_top` ENTITY at the `seq` generic set with `-g` arguments and no
`EXP_*` overrides. Making the `EXP_*` defaults non-sentinel would therefore
have turned all 23 of its cases red, **controls included**, and every control
would have reported a kill it did not earn. That is why the default-shape
landmark is guarded by `AT_DEFAULT` rather than simply being the generic
default. See section 6.

---

## 6. `AT_DEFAULT`, and the one piece of machinery worth explaining

Three of the four gated rows are wrappers and can pin their landmarks in a
generic map. The fourth, the default `tb_llama_top` row, has no wrapper -- it
IS the entity, discovered by name -- and `sim/regress.sh` passes it no
generics, so there is nowhere to put four numbers for it.

`AT_DEFAULT` is a constant boolean comparing twenty generics against literal
copies of their own defaults. The default-shape landmark applies only when it
holds, so:

* the default gate row is gated;
* `sim/mutate_llama_top_kv.sh`, which overrides the shape, is not;
* a manual run at any unrecorded shape is not, and says so.

**The literals are copies and nothing enforces that they stay copies.** If a
generic default moves and that list does not, `AT_DEFAULT` goes false and the
default row **silently loses its gate**, which is the exact failure this whole
change exists to end. That is why the run prints a `NO VALUE GATE` note when
all four landmarks are unset: it is not decoration, it is the only thing that
would report this. MEASURED that the note fires: section 7.3.

---

## 7. The evidence, as raw output

### 7.1 REPRODUCED: both of C-SEAM's results, at `4736950`

Three `git archive 4736950` trees, one file replaced in two of them, run in
parallel on the shared box. The mutant writer refuses unless it matches
**3 + 1** occurrences, because `vref_r` is indexed at four sites spelled two
different ways and an anchor matching one spelling changes three of four:

    C1 mutant written at 3+1 sites
    NEG mutant written at 3+1 sites

    ########## base ##########
    PASS       sim:tb_llama_top_seq                 295s
     OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
     REGRESSION: PASS
    ########## repro_c1 ##########
    PASS       sim:tb_llama_top_seq                 293s
     OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
     REGRESSION: PASS
    ########## repro_neg ##########
    PASS       sim:tb_llama_top_seq                 295s
     OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
     REGRESSION: PASS

and the landmark each of them printed, which is the line that turns the
reproduction into a fix:

    base       R_X(0) = -14252 hash(R_X) = 7668
    repro_c1   R_X(0) = -14240 hash(R_X) = 97483
    repro_neg  R_X(0) = -14240 hash(R_X) = 97483

### 7.2 The verdict at `35e0ed0`, before the change

    fail <= n_bad_sched + n_bad_skew + n_bad_res + n_bad_pos + n_bad_kverr
          + kv_bad_wr + kv_bad_rd + kv_bad_dat + kv_bad_cov + kv_bad_bresp
          + n_bad_cap + n_smp_hole + n_smp_ovr + n_smp_cnt;

Fourteen counters. Schedule, skew across latency points, degenerate residuals,
token position, KV sticky error, five KV placement counters, capture
disagreement, three logits-stream counters. **Not one of them is a function of
what the machine computed.**

### 7.3 The four landmarks, MEASURED on the unmutated tree at `35e0ed0`

Taken with the gate installed and every `EXP_*` left at its sentinel, which is
why each run also printed the `NO VALUE GATE` note -- the note firing here is
its own teeth check:

    ### h_def
    ...P14 -- NO VALUE GATE.  None of EXP_X0, EXP_XSUM, EXP_XALL or EXP_STEPH is set...
    ...P14 landmarks measured -- EXP_X0 => -12739, EXP_XSUM => 38863, EXP_XALL => 38863, EXP_STEPH => 6432
    ...RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run, 4 descriptor-latency points
    ### h_seq
    ...P14 -- NO VALUE GATE...
    ...P14 landmarks measured -- EXP_X0 => -14252, EXP_XSUM => 7668, EXP_XALL => 96762, EXP_STEPH => 57526
    ...RESULT: PASS -- 61 descriptors, 4 blocks, 3 tokens per run, 2 descriptor-latency points
    ### h_real
    ...P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 17333
    ### h_normw
    ...P14 landmarks measured -- EXP_X0 => -16350, EXP_XSUM => 90889, EXP_XALL => 90889, EXP_STEPH => 18618

Three cross-checks were read off this table rather than assumed:

* **`h_seq` reproduces `-14252 / 7668` exactly**, the same pair the clean
  `4736950` snapshot printed in 7.1. So the two HEAD moves under this track
  did not move the seq numbers, and the reproduction and the landmark are the
  same measurement.
* **`h_seq` has `EXP_XALL` = 96762 and `EXP_XSUM` = 7668, which differ.** The
  token axis is genuinely in the hash. This is `P4s`'s question and the answer
  is structural rather than a mutation.
* **`h_real` and `h_normw` have `EXP_XALL` = `EXP_XSUM` by construction**,
  because both run `NTOK = 1` and the two hashes are then the same hash over
  the same one token. `EXP_XALL` adds **no** resolution at those two rows and
  is pinned anyway, so that raising `NTOK` there without re-measuring fails
  rather than silently widening the gate.
* **`h_real` prints `R_X(0) = -16364 hash(R_X) = 91622`**, which is the pair
  TRACK CAPTURE recorded for its **m3 mutant**. That is not a coincidence and
  it is the setup for 7.4: m3's residual is bit-identical to the clean one.

**An independent cross-check of `h_real`, and a live instance of the problem
this change fixes.** `sim/tb_llama_top_real.vhd`'s own header claims that row
"reproduces PART 6's published control landmark exactly: `R_X(0) = -16339
hash(R_X) = 92903`". MEASURED here: it does not, and has not for hours. TRACK
CAPTURE independently measured the same move and attributed it, from pristine
`git archive` trees at three commits:

| tree | `R_X(0)` | `hash(R_X)` | attribution |
|---|---|---|---|
| `0af42c7` | -16339 | 92903 | matches the committed golden |
| `a77d181` | **-16364** | **91622** | B-BLK-1's key-head mapping fix moved it |
| `2d10f76` | -16364 | 91622 | unchanged |
| `35e0ed0` (this track) | **-16364** | **91622** | unchanged |

So the number this track pins is corroborated by a second track's independent
capture, and **five committed places still quote the pre-`a77d181` pair**:
`sim/tb_llama_top_real.vhd`'s header, `rtl/llama_top.vhd:342` (which asserts
it "is unchanged"), `docs/WORKLOG.md` row 14, and two lines of
`docs/debugging/2026-08-29_logits-egress.md`. **A landmark quoted in five
files and compared in none is the whole of OI-3 in one sentence.** Only the
first of those five is this track's to fix, and it is fixed by the header this
change writes; the other four are raised in section 12.

### 7.4 THE TEETH

`sim/mutate_llama_top_land.sh`, at `35e0ed0`. Full raw output:

```
--- controls: the clean design must PASS with its landmarks pinned ---
P0s  SURVIVED   -- CONTROL: clean, the KV configuration, all four landmarks pinned
        sim/tb_llama_top.vhd:2775:5:@213646500ps:(report note): tb_llama_top: P14 landmarks measured -- EXP_X0 => -14252, EXP_XSUM => 7668, EXP_XALL =
P0r  SURVIVED   -- CONTROL: clean, the real-path configuration, all four landmarks pinned
        sim/tb_llama_top.vhd:2775:5:@52463500ps:(report note): tb_llama_top: P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL =

--- P1/P2: the two mutants the OLD gate could not see ---
P1  KILLED     -- defect C1 restored: the v_ref fold indexed by KV HEAD ALONE, at all four sites
        sim/tb_llama_top.vhd:2719:7:@213646500ps:(report error): tb_llama_top: P14 -- R_X(0) is -14240 and the recorded landmark for this configuratio
        sim/tb_llama_top.vhd:2729:7:@213646500ps:(report error): tb_llama_top: P14 -- hash(R_X) over the last token is 97483 and the recorded landmark
        sim/tb_llama_top.vhd:2736:7:@213646500ps:(report error): tb_llama_top: P14 -- hash(R_X) over ALL 3 tokens is 15121 and the recorded landmark i
        sim/tb_llama_top.vhd:2744:7:@213646500ps:(report error): tb_llama_top: P14 -- hash of the 61-completion step trace is 4794 and the recorded la
        sim/tb_llama_top.vhd:2775:5:@213646500ps:(report note): tb_llama_top: P14 landmarks measured -- EXP_X0 => -14240, EXP_XSUM => 97483, EXP_XALL 
P2  KILLED     -- C-SEAM's NEGATIVE CONTROL: one v_ref register shared across every layer AND every KV head
        sim/tb_llama_top.vhd:2719:7:@213646500ps:(report error): tb_llama_top: P14 -- R_X(0) is -14240 and the recorded landmark for this configuratio
        sim/tb_llama_top.vhd:2729:7:@213646500ps:(report error): tb_llama_top: P14 -- hash(R_X) over the last token is 97483 and the recorded landmark
        sim/tb_llama_top.vhd:2736:7:@213646500ps:(report error): tb_llama_top: P14 -- hash(R_X) over ALL 3 tokens is 15121 and the recorded landmark i
        sim/tb_llama_top.vhd:2744:7:@213646500ps:(report error): tb_llama_top: P14 -- hash of the 61-completion step trace is 4794 and the recorded la
        sim/tb_llama_top.vhd:2775:5:@213646500ps:(report note): tb_llama_top: P14 landmarks measured -- EXP_X0 => -14240, EXP_XSUM => 97483, EXP_XALL 

--- P3: the row that separates EXP_STEPH from the three R_X landmarks ---
P3  KILLED     -- gdn_silu's SiLU emit TRUNCATES instead of rounding, all four landmarks pinned
        sim/tb_llama_top.vhd:2729:7:@52463500ps:(report error): tb_llama_top: P14 -- hash(R_X) over the last token is 35386 and the recorded landmark 
        sim/tb_llama_top.vhd:2736:7:@52463500ps:(report error): tb_llama_top: P14 -- hash(R_X) over ALL 1 tokens is 35386 and the recorded landmark is
        sim/tb_llama_top.vhd:2744:7:@52463500ps:(report error): tb_llama_top: P14 -- hash of the 64-completion step trace is 29562 and the recorded la
        sim/tb_llama_top.vhd:2775:5:@52463500ps:(report note): tb_llama_top: P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 35386, EXP_XALL =
P3x  KILLED     -- the SAME mutation with EXP_STEPH unset -- the three R_X landmarks alone
        sim/tb_llama_top.vhd:2729:7:@52463500ps:(report error): tb_llama_top: P14 -- hash(R_X) over the last token is 35386 and the recorded landmark 
        sim/tb_llama_top.vhd:2736:7:@52463500ps:(report error): tb_llama_top: P14 -- hash(R_X) over ALL 1 tokens is 35386 and the recorded landmark is
        sim/tb_llama_top.vhd:2775:5:@52463500ps:(report note): tb_llama_top: P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 35386, EXP_XALL =

--- P4: the axis checks.  Not defect rows. ---
P4s  SURVIVED   -- AXIS: clean seq run, landmarks UNPINNED -- xall must differ from xsum, or the token axis is not in the hash

P3b  KILLED     -- TRACK CAPTURE's m3 EXACTLY: only the SiLU EMIT truncates, all four landmarks pinned
        sim/tb_llama_top.vhd:2744:7:@52463500ps:(report error): tb_llama_top: P14 -- hash of the 64-completion step trace is 34846 and the recorded la
        sim/tb_llama_top.vhd:2775:5:@52463500ps:(report note): tb_llama_top: P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL =
P3bx  SURVIVED   -- the SAME narrow mutation with EXP_STEPH unset -- the three R_X landmarks alone
```

**`P1` kills on all four landmarks and `P2` on all four**, which is the
headline: the two mutants that produced `OVERALL PASS 1 FAIL 0` in 7.1 now
produce `RESULT: FAIL`.

**`P3` / `P3x` is the pair that earns `EXP_STEPH` its place.** TRACK CAPTURE
measured that a `gdn_silu` truncation moves `R_Y-0/1/2` and `R_ER-0/1/2` and
leaves `R_X` bit-identical, because `R_ER` sits at exp 16 while `R_X.embed`
sits at exp 3 and the residual's alignment shift discards exactly the bits it
moved -- and called it the sixth instance of the OI-3 family. Reproduced here
from the other side: with `EXP_STEPH` unset, the three `R_X` landmarks let it
through; with it pinned, it dies. **Do not delete `EXP_STEPH` as redundant
with `EXP_XSUM`; `P3x` is the measurement that says it is not.**

### 7.5 The gate

The whole family, on a `git archive 729c9b8` tree with only this track's five
files replaced -- deliberately NOT the working tree, which carried three other
tracks' uncommitted edits throughout:

    PASS       sim:tb_llama_top                     109s
    PASS       sim:tb_llama_top_normw                75s
    PASS       sim:tb_llama_top_real                 75s
    PASS       sim:tb_llama_top_seq                 286s
    PASS       sim:tb_llama_top_smp                   1s
    PASS       sim:tb_llama_top_smp_beh               1s
     OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
     REGRESSION: PASS

`BASELINE_PASS` is untouched at 94 and `sim/regress.sh` was not edited: no
`sim/tb_*.vhd` is added, so no gate row appears.

**A PASS is not the evidence here; the evidence is that all four gated rows
are ARMED.** A landmark that quietly reverted to its sentinel would print
exactly this same green run, which is the whole failure mode. MEASURED, from
each row's own log:

    tb_llama_top        P14 landmarks measured -- EXP_X0 => -12739, EXP_XSUM => 38863, EXP_XALL => 38863, EXP_STEPH => 6432   (0 of the pinned landmarks moved)
    tb_llama_top_seq    P14 landmarks measured -- EXP_X0 => -14252, EXP_XSUM => 7668, EXP_XALL => 96762, EXP_STEPH => 57526   (0 of the pinned landmarks moved)
    tb_llama_top_real   P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 17333   (0 of the pinned landmarks moved)
    tb_llama_top_normw  P14 landmarks measured -- EXP_X0 => -16350, EXP_XSUM => 90889, EXP_XALL => 90889, EXP_STEPH => 18618   (0 of the pinned landmarks moved)

and NONE of the four printed the `NO VALUE GATE` note, which is the check that
`AT_DEFAULT` (section 6) actually resolves for the default row -- the one row
whose landmark could not come from a wrapper.

The two `smp` rows run in 1 s because they are a much smaller shape; they are
unchanged by this track and are in the run as the control that nothing in the
shared entity broke them.

**The gate was then re-run at a LATER HEAD, and that re-run is the first real
use of it.** Between the run above and this commit, TRACK ORDINAL landed
`a9792df`, which changes `rtl/llama_top.vhd`, `sim/llama_sched_pkg.vhd` and
`sim/seq_tbl_pkg.vhd` -- all three in the closure of every gated row, and
exactly the hazard section 12 was written to name. So the whole family was
re-run on a fresh `git archive 06f6793` tree:

    OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
    REGRESSION: PASS

    tb_llama_top        EXP_X0 => -12739, EXP_XSUM => 38863, EXP_XALL => 38863, EXP_STEPH => 6432   (0 of the pinned landmarks moved)
    tb_llama_top_seq    EXP_X0 => -14252, EXP_XSUM => 7668, EXP_XALL => 96762, EXP_STEPH => 57526   (0 of the pinned landmarks moved)
    tb_llama_top_real   EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 17333   (0 of the pinned landmarks moved)
    tb_llama_top_normw  EXP_X0 => -16350, EXP_XSUM => 90889, EXP_XALL => 90889, EXP_STEPH => 18618   (0 of the pinned landmarks moved)

**MEASURED: `a9792df` moved none of the sixteen numbers.** That is a real
result about that change, not a formality -- it says the per-kind layer index
it moved into the descriptor produces bit-identical arithmetic at all four
configurations -- and it is the kind of statement this family could not make
about ANY commit before today.

---

## 8. The per-bench audit

The brief asked for this explicitly: which of the six have a falsifiable value
gate and which do not. **At `35e0ed0`, before this change:**

| bench | falsifiable value gate? | mechanism | teeth |
|---|---|---|---|
| `tb_llama_top` | **NO** | 14 structural counters; `R_X(0)`/`hash(R_X)` printed, compared against nothing | -- |
| `tb_llama_top_seq` | **NO** | wrapper, inherits the above | -- |
| `tb_llama_top_real` | **NO** | wrapper, inherits the above | -- |
| `tb_llama_top_normw` | **NO** | wrapper, inherits the above | -- |
| `tb_llama_top_smp` | **YES**, partial | P4, the streamed logits against the SAME two jobs routed to a region -- a two-path comparison, not an independent model | M7 KILLED, "64 of 64 streamed logits DIVERGES from the region-routed twin" |
| `tb_llama_top_smp_beh` | **YES** | P3, every logit recomputed from the region contents and the behavioural closed form -- a genuine independent oracle | M15 KILLED, "26 of 64 logits DIVERGES from the oracle" |

**After this change the first four have one.** The `smp` pair is unchanged and
needed nothing: its teeth were already measured and recorded by another track
in `docs/debugging/2026-08-29_logits-egress.md` section 6, and re-running that
16-row matrix would have restated a result rather than establishing one.

**Two distinctions in that table are load-bearing and easy to blur.**

* `tb_llama_top_smp`'s P4 is a **round trip between two routes of the same
  computation**, and this project's own rule is that a round trip is not an
  oracle: a wrong-but-consistent A would satisfy both routes. It is still a
  falsifiable value gate -- M7 proves it fires -- and it is not a correctness
  argument. Its own header says the same thing.
* `tb_llama_top_smp_beh`'s P3 is the only genuinely independent value model in
  the family, and it exists only because the BEHAVIOURAL A has a published
  closed form. The real A has none at this level, which is exactly why the two
  rows check disjoint things.

---

## 9. Measured and REJECTED -- do not retry

**9.1 Turning the `R_X` `report` into an `assert` and stopping there.
REJECTED.** It fixes `tb_llama_top_seq` and leaves `EXP_STEPH`'s whole
coverage class open: MEASURED at `P3x`, the `gdn_silu` truncation passes all
three `R_X` landmarks. An `assert` on the printed pair would have closed OI-3b
and left the sixth OI-3 instance exactly where TRACK CAPTURE found it.

**9.2 Making the `EXP_*` generic defaults non-sentinel, so the default gate row
is gated without `AT_DEFAULT`. REJECTED, and the reason is measurable rather
than stylistic.** `sim/mutate_llama_top_kv.sh` runs the `tb_llama_top` ENTITY
at the `seq` generic set (`BASE=` at the top of that file) with no `EXP_*`
overrides. A default-shape landmark would fail on all 23 of its cases,
**including controls C0..C3**, and every control would report a kill it did not
earn. The same applies to every manual exploration at a new shape.

**9.3 Adding these rows to `sim/mutate_llama_top_kv.sh`. REJECTED.** Installing
a value gate in the entity changes what several of its 23 rows would report,
and those verdicts are quoted in two write-ups as a measurement of the
structural checkers' resolution floor. Re-basing that table would destroy the
comparison it exists to support. New file.

**9.4 Treating the shared-`v_ref` control as a second, more destructive point
on the defect axis. REJECTED, MEASURED.** It produces the identical pair
`-14240 / 97483` that defect C1 produces at this configuration. It is a valid
control -- it says the mutant reaches the checker -- and it is not a second
data point. Correction 3.

**9.5 Reading the assert count as the answer. REJECTED.** `sim/regress.sh`
judges a row TEXTUALLY (`FAIL_RE` / `PASS_RE` at `:1207`), so a bench with zero
asserts can fail correctly by printing, and a bench with 35 asserts can be
decoration if none of them covers the value -- which is precisely the case
here. The count is a lead. The verdict is `fail <= ...`.

**9.6 Mutating `rsh_r`'s FUNCTION BODY to stand in for TRACK CAPTURE's m3.
REJECTED, MEASURED, and this one nearly produced a wrong conclusion.** `rsh_r`
has THREE call sites in `rtl/gdn_silu.vhd` -- `:275` (the Q12 conversion),
`:336` (the interpolation) and `:358` (the emit) -- so a mutation of the body
truncates all three. It moves `hash(R_X)` from 91622 to 35386, so `P3x` KILLED
and the first reading of that table was **"`EXP_STEPH` is redundant"**. The
narrow mutation, `y := rsh_r(prod(k), 15)` -> `y := shift_right(prod(k), 15)`
at the emit alone, is the one CAPTURE measured, and it leaves all three `R_X`
landmarks bit-identical. **Do not evaluate a landmark's necessity with a
mutation broader than the defect class it is meant to catch**; the broader one
kills through a channel the narrow one never touches, and its kill is silently
about the wrong thing. Both rows are kept, P3 under its own name.

**9.7 Hashing all NRUNS into `EXP_STEPH`. REJECTED.** P2 already requires
`tr_exp` and `tr_sum` to be bit-identical across every run, so the extra runs
add no resolution and would tie the landmark to `NRUNS`, which the mutation
harness varies.

---

## 10. Measurement traps hit

1. **HEAD moved twice under this track, and once the file this track owns was
   being written by another one.** At the start, `sim/tb_llama_top.vhd` had
   204 uncommitted lines in it with an mtime 27 seconds old -- TRACK LOGITS
   mid-edit on a file the brief assigned to OI3B. Nothing was clobbered
   because every measurement was taken on a `git archive <sha>` snapshot and
   no working-tree edit was made until that track had committed (`35e0ed0`).
   **The standing rule earned its keep: compare against a pristine snapshot,
   not the working tree.**
2. **The dispatcher's assert counts were taken on the working tree, and the
   working tree was not any committed state.** See correction 2. A count of
   anything in this repo needs its tree named.
3. **A first-run PASS on a control proves less than it looks.** `P0s` and
   `P0r` pass, which is necessary and says nothing on its own; what makes the
   gate real is `P1`/`P2` failing and `P3`/`P3x` splitting.
4. **`--only` takes a SUBSTRING**, so `--only tb_llama_top_seq` was used
   rather than a pattern, and the `OVERALL PASS n` line was read on every run
   rather than the word PASS.
5. **`NTOK = 1` makes `EXP_XALL` and `EXP_XSUM` the same number.** Noticing
   that from the harvest table rather than assuming the two hashes were
   independent everywhere is what stopped `EXP_XALL` from being reported as
   covering four rows when it covers one.

---

## 11. Open, not yet answered

Stated plainly because a tidy conclusion that overstates its evidence is worth
less than an explicit list.

* **`EXP_XALL` has NOT been shown to fire independently of `EXP_XSUM`, and it
  is the one landmark of the four with no teeth of its own.** Every mutation
  run here that moved a non-final token also moved the final one: at `P1` and
  `P2` both hashes move, at `P3b` neither does, and at `P3`/`P3x` both move
  together. Its coverage claim is DERIVED from its definition, not MEASURED.
  Constructing a defect that moves token 1 and reconverges by the last token
  was not attempted. **What IS measured is that the axis reaches it:** `P4s`
  shows `EXP_XALL` = 96762 against `EXP_XSUM` = 7668 on the clean seq run, so
  the extra tokens genuinely contribute to the hash and the landmark is not
  accidentally a copy of `EXP_XSUM` at that row. That is C-SEAM's `L7`
  question and it is a weaker claim than a kill. Recorded rather than glossed:
  if a later track needs to cut a landmark, this is the one with the least
  evidence behind it.
* **`tr_exp` / `tr_sum` hold only the LAST token's trace**, because `n_cmp` is
  reset by `go` and `go` pulses per token. So an intermediate seam that is
  wrong only in a NON-final token, and whose error does not reach any token's
  `R_X`, is covered by nothing here.
* **A landmark cannot say the numbers are right.** Nothing in this change is a
  correctness argument. The nearest thing to one at the integration level is
  the `CAPTURE` + `bisect_scaled.py` path, which covers 58 of 63 seams and
  lives in the mutation harness rather than in the gate. **Promoting it into
  the gate is the follow-up this track did not do**, and it would require
  `tools/ref9b/**`, which another track owns.
* **Nothing was synthesised.** No Vivado ran, and no RTL was changed by this
  track: every mutation is a scratch copy.
* **The `smp` pair was audited from another track's recorded evidence, not
  re-run.** If that evidence is stale the audit row is stale with it.
* **The landmarks are pinned against `35e0ed0`'s RTL.** See section 12.

---

## 12. Raised for the dispatcher: the landmarks WILL go red, and that is the gate working

At the time of writing, `rtl/llama_top.vhd`, `sim/llama_sched_pkg.vhd` and
`sim/seq_tbl_pkg.vhd` carry **98 lines of another track's uncommitted edits**
(MEASURED, `git diff --stat`). All three are in the closure of every row gated
here. If those edits change the schedule or any computed value -- and a change
to `llama_sched_pkg` almost certainly changes `NSTEP`, which `EXP_STEPH`
hashes over -- **the four gated rows will go red the moment they land.**

That is the gate doing its job and not a defect in it. The correct response is
the one `b75d7a1` used: re-measure, and say in the commit message why the
numbers moved, recording both the old and the new values. Every row prints its
own four numbers in paste-ready form on every run, exactly so this costs one
run and not an investigation:

    tb_llama_top: P14 landmarks measured -- EXP_X0 => ..., EXP_XSUM => ...,
                  EXP_XALL => ..., EXP_STEPH => ...

**A landmark updated without an explanation is worth exactly as much as no
landmark**, which is the state this document exists to end.

**A second item, smaller, and evidence for the same point.** FOUR committed
places outside this track's ownership still quote `tb_llama_top_real`'s
pre-`a77d181` landmark `R_X(0) = -16339 hash 92903`, which has been wrong
since B-BLK-1's key-head mapping fix landed. MEASURED at `35e0ed0`, the row
prints `-16364 / 91622`, corroborated independently by TRACK CAPTURE's
three-commit table:

* `rtl/llama_top.vhd:342`, which states it "is unchanged" -- the strongest
  form of the error, an explicit claim of stability that is false;
* `docs/WORKLOG.md` row 14;
* `docs/debugging/2026-08-29_logits-egress.md`, two lines.

This track fixed only the fifth instance, `sim/tb_llama_top_real.vhd`'s own
header, which it owns. The number is now also PINNED there, so this particular
staleness cannot recur silently at that row. **A landmark quoted in five files
and compared in none is the whole of OI-3 in one sentence**, and it is worth
noting that the correct value was already sitting in another track's write-up
the entire time.
