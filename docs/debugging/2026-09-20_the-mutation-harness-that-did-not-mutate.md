# The mutation harness that did not mutate

**Date:** 2026-09-20.  **Track:** MUTAUDIT.  **Tree:** `fpga` at `56d13e3`.
**Tools:** `ghdl-mcode` 6.0.0, `python3`, `git`.  No Vivado, no hardware.

---

## 1. The question, verbatim

> TRACK SCOREHDR (commit `56d13e3`) just discovered that its own mutation
> harness **had the exact defect the harness exists to find**.  A quoting bug
> made one mutant's anchor match **zero** times; `mutate_rtl` echoed `""`; and
> **the PRISTINE design was then built, run, and reported `SURVIVED`** -- after
> which a ten-seed sweep dutifully reported `0/10`.  A row that never mutated
> anything is indistinguishable in the output from a row whose mutation the
> checks genuinely tolerate.
>
> SCOREHDR fixed this in its own new script only [...] It reported that
> `sim/mutate_attn_score_early.sh` and its siblings carry the same `echo ""`
> construct and are NOT audited.
>
> 1. Enumerate every mutation harness.  2. Classify each one by whether a
> zero-match anchor is detectable from its output.  3. Teeth, and this is the
> core of the track [...] demonstrate it [...] in both directions.  4. Fix the
> vulnerable ones.  5. THE RETROSPECTIVE QUESTION [...] can you tell from the
> committed tables and logs whether any historical SURVIVED row was actually a
> no-op?  6. Consider whether `sim/regress.sh` should gain a row [...]

---

## 2. The answer, up front

**There are 62 mutation harnesses (`sim/mutate_*.sh`).  FIVE of them report a
zero-match anchor as an ordinary row, and all five are now fixed.  FIFTY-SEVEN
are safe, by six different mechanisms, none of which is the sentinel SCOREHDR
built.**  The five, each MEASURED by running it with an impossible anchor:

| harness | what an impossible anchor printed | what the real anchor printed |
|---|---|---|
| `sim/mutate_attn_block.sh` | `M1  SURVIVED` | `M1  KILLED` |
| `sim/mutate_attn_score_early.sh` | `E1_on  SURVIVED` | `E1_on  ABORT (DUTASSERT)` |
| `sim/mutate_attn_sweep_pipe.sh` | `P1_on  SURVIVED` | `P1_on  ABORT (LANG)` |
| `sim/mutate_normw.sh` | `bench PASS  R_XN oracle 9/9` | `bench PASS  R_XN oracle 8/9` |
| `sim/mutate_a_geom.sh` | `M1 ... PASS  (want ANALYSIS or FAIL)` | `M1 ... FAIL` |

**And the defect is not hypothetical: one row is a no-op TODAY.**
`sim/mutate_attn_sweep_pipe.sh`'s **P7** anchor has matched zero times since
commit `4e9915b` (TRACK MIDGAP, 2026-09-20 -- the same day).  Since then the
row has been running the PRISTINE design and printing `P7_on  SURVIVED`, and
the script's own legend explains that survival as *"a pure schedule change; the
value oracle CANNOT see it, by construction"*.  The explanation is plausible,
it is written down, and it is attached to a row that measured nothing.

**The retrospective question, answered honestly: from the committed tables and
logs alone, NO -- it cannot be determined.**  The tables record only the
verdict word; the one diagnostic (`MUTATION ANCHOR MATCHED 0 TIMES`) goes to
stderr, above the row and detached from it; and no raw run log from any of the
five is committed anywhere in `docs/`.  **But the question is answerable by a
different route that runs no simulation at all** -- replay the anchors against
the RTL as both stood at the commit in question -- and that replay, teeth-
tested against the single historically recorded anchor failure, says:

- every anchor in all five scripts matched exactly once at the commit each
  table was published, **except** `attn_sweep_pipe`'s P7 as above;
- and it found **five MORE harnesses whose anchors are dead today**, in the
  SAFE class, where the rows do not print SURVIVED -- they vanish:
  `mutate_llama_top_kv.sh` (9), `mutate_llama_top_normuram.sh` (9, which is
  most of its table), `mutate_attn_kv_seam.sh` (rows R3, R4, R5, R5b, L1),
  `mutate_rmswire.sh` (2), `mutate_fk33_seam.sh` (1).

**A third, separate finding.** Three harnesses could not run at all:
`mutate_normw.sh`, `mutate_fk33_seam.sh` and `mutate_llama_top_smp.sh` omit
`rtl/gdn_conv_w_mem.vhd` from their `FILES`, which `rtl/gdn_state_store.vhd`
needs since `748ff91`, so **every row of all three reported `ANALYSIS` / did
not analyze**.  One word each; fixed and verified.

---

## 3. The procedure, in the order it was run

1. **Enumerate.** `ls sim/mutate_*.sh` -> 62.  (Also checked for non-`sh`
   harnesses: `sim/mv4i_desc_mutations.py` is a mutation TABLE driven by two
   of the 62, not a harness of its own.)
2. **Classify by mechanism, not by spelling.**  The question is not whether a
   script contains `echo ""`; it is whether the OUTPUT of a no-op substitution
   differs from the output of a survivor.  Six safe mechanisms were found and
   each is named per script in `sim/mutation_harness_audit.tsv`.
3. **Teeth, both directions.**  For a representative of every mechanism, and
   for all five vulnerable scripts individually: insert an impossible anchor,
   run the row, read what it prints; then run the same row with its real
   anchor.  A classification not demonstrated in both directions is a guess.
4. **Fix**, in SCOREHDR's shape where the shape fits, and in the shape the
   script already had where it does not.  Re-run each to prove Z0 now BADMUTs
   and that no other row moved.
5. **Retrospect** by anchor replay, not by re-running benches.  The replay
   stubs the row functions, so only the substitution executes; a silent run
   means every anchor matched exactly once at that commit.  **Its positive
   control is the one anchor failure this project has already recorded**
   (`docs/debugging/2026-08-29_c1-vref-layer.md`, row N1 of
   `mutate_llama_top_kv.sh`, broken by `9f690a0`): the replay reproduces it
   exactly, at that commit, in seconds.
6. **Gate.** Write `sim/check_mutation_harness.py` with its own selftest
   against the MEASURED states, and the manifest it reads.  Do NOT edit
   `sim/regress.sh` while gates may be live; state the exact lines instead.

---

## 4. The evidence, as raw output

### 4.1 The five, with an impossible anchor (MEASURED)

`sim/mutate_a_geom.sh`, two runs differing only in the `sed` pattern:

```
== sim/tb_a_geom.vhd mutation table ==
M0  unmutated                                              PASS  (must be PASS)
M1  seq_tbl_pkg A_ROWS_IF 48 -> 32                         PASS  (want ANALYSIS or FAIL)   <-- impossible pattern
M1  seq_tbl_pkg A_ROWS_IF 48 -> 32                         FAIL  (want ANALYSIS or FAIL)   <-- real pattern
```

There is no diagnostic of any kind in the first case.  `sed -i` with a pattern
that matches nothing exits 0 and writes the file back unchanged.

`sim/mutate_attn_block.sh`:

```
A0  PASS (anchor)   -- honest rtl/attn_block.vhd, tapered stimulus
MUTATION ANCHOR MATCHED 0 TIMES, expected 1
M1  SURVIVED   -- emin_tree drops its LAST combining stage (TRACK TIMING's mutant)
```

against the control with the real anchor:

```
M1  KILLED     -- emin_tree drops its LAST combining stage (TRACK TIMING's mutant)
        sim/tb_attn_block.vhd:946:15:@81465ns:(report error): tb_attn_block: P8 -- run 0
        element 0 = 4688, the oracle says 2271.  MISMATCH against ref/attn_block_vec.c.
```

`sim/mutate_attn_score_early.sh` and `sim/mutate_attn_sweep_pipe.sh`:

```
A_on  SURVIVED   -- ANCHOR: unmutated, SCORE_EARLY=true  (must SURVIVE)
A_off  SURVIVED   -- ANCHOR: unmutated, SCORE_EARLY=false (must SURVIVE)
MUTATION ANCHOR MATCHED 0 TIMES, expected 1
E1_on  SURVIVED   -- E1 se_rdy armed on every K beat, SCORE_EARLY=true
                                        (control, real anchor: E1_on  ABORT (DUTASSERT(attn_block.vhd)))

A_on  SURVIVED   -- ANCHOR: unmutated, SWEEP_PIPE=true  (must SURVIVE)
A_off  SURVIVED   -- ANCHOR: unmutated, SWEEP_PIPE=false (must SURVIVE)
MUTATION ANCHOR MATCHED 0 TIMES, expected 1
P1_on  SURVIVED   -- P1 capture destination from ph, SWEEP_PIPE=true
                                        (control, real anchor: P1_on  ABORT (LANG))
```

`sim/mutate_normw.sh` is the sharpest of the five, because the broken row is
byte for byte the unmutated baseline:

```
M0   unmutated                                                bench PASS      R_XN oracle 9/9
Traceback (most recent call last):
  File "<stdin>", line 5, in <module>
AssertionError: M1 anchor not found
M1   gain advances at the ACCEPT, not the completion          bench PASS      R_XN oracle 9/9   <-- impossible
M1   gain advances at the ACCEPT, not the completion          bench PASS      R_XN oracle 8/9   <-- real
```

Note the real M1 is NOT caught by the bench at all -- only by the `R_XN`
oracle, at 8 of 9 seams.  So the difference between "mutated" and "not mutated"
lives in one digit of one column.

### 4.2 The safe mechanisms, demonstrated in both directions (MEASURED)

| mechanism | representative | impossible anchor | real anchor |
|---|---|---|---|
| rc read inside the row fn, C mutator | `mutate_ref_seq_vec_res.sh` | `Z0  ANCHOR FAILED` | `R1  KILLED by the accumulator-overflow trap` |
| rc read inside the row fn, RTL mutator | `mutate_attn_rope.sh` | `Z0: ANCHOR FAILED` | `CTL  SURVIVED EVERY CONFIG` |
| `if ! patch_file` gate | `mutate_async_fifo.sh` | `Z0   AUDIT  ANCHOR FAILED -- tested nothing` | `G1 ... 1 SURVIVED` |
| `grep -qF` presence check | `mutate_eng_cdc.sh` | `Z0   VOID   expect SURV   <== UNEXPECTED` | `rows-as-expected=1 unexpected=0` |
| consumer refuses an empty mutdir | `mutate_fk33_seam.sh` | `Z0  ANCHOR FAILED (the mutation was not applied)` | `Z1  DID NOT ANALYZE` |
| consumer refuses an empty mutdir | `mutate_llama_top_smp.sh` | `Z0  MUTATION DID NOT APPLY` | (rows run normally) |
| `[ -n "$D" ]` guard at the call site | `mutate_swg_wide.sh` | `Z0  ANCHOR FAILED` | (rows run normally) |
| `cmp -s` against the source | `mutate_rmsnorm_rs_mem.sh` | prints `NOSUB`, counts a failure, exits nonzero | -- |

The remaining 49 are classified **DERIVED**, from the guard text quoted per
file in `sim/mutation_harness_audit.tsv`; each of those guards returns before
any `ghdl` or `cc` runs.  They were NOT individually run.  That is stated
rather than hidden: see the open list.

### 4.3 The fixes, re-validated (MEASURED)

```
Z0  BADMUT (anchor matched 0 times -- the mutation was NOT applied)   -- SELF-TEETH: impossible anchor
        Z0 is the SELF-TEETH row: BADMUT here is the REQUIRED outcome.
Z0SEEN=1 NBAD=0                       (attn_block, attn_score_early, attn_sweep_pipe)

Z0   SELF-TEETH: impossible anchor (MUST report BADMUT)       bench BADMUT    R_XN oracle BADMUT
Z0SEEN=1 NBAD=0                       (normw)

Z0  SELF-TEETH: impossible sed pattern                      BADMUT  (MUST be BADMUT, never PASS)
Z0 self-teeth: BADMUT as required; 0 other row(s) BADMUT.    (a_geom)
```

`sim/mutate_a_geom.sh` and `sim/mutate_attn_block.sh` were then run IN FULL and
every pre-existing row is unchanged:

```
== sim/tb_a_geom.vhd mutation table ==
M0 PASS   Z0 BADMUT   M1 FAIL  M2 FAIL  M3 FAIL  M4 FAIL  M5 FAIL  M6 PASS  M7 PASS

A0 PASS(anchor)  Z0 BADMUT
M1 KILLED  M2 KILLED  M3 KILLED  M4 SURVIVED  M5 KILLED  M6 SURVIVED  M7 SURVIVED
M8 KILLED  M9 KILLED  M10 KILLED
C1M1 KILLED  C1M2 KILLED  C1M3 KILLED  C1M4 SURVIVED  C1M5 KILLED  C1M6 SURVIVED
C1M7 SURVIVED  C1M8 KILLED  C1M9 KILLED  C1M10 KILLED   C2 KILLED
 TOTAL 23   KILLED 15   SURVIVED 6   ABORT 0   BADMUT 0
```

which reproduces `docs/debugging/2026-08-30_attnteeth-tb_attn_block-passes-a-broken-tree.md`'s
table row for row.

### 4.4 The anchor replay, and its positive control (MEASURED)

The replay stubs the row functions and runs nothing but the substitution.  Its
control is the anchor failure already recorded in
`docs/debugging/2026-08-29_c1-vref-layer.md`:

```
### POSITIVE CONTROL: mutate_llama_top_kv.sh at 9f690a0
mutate_llama_top_kv   9f690a0   stubbed=run_case,run_row,run_cap   anchor-failure lines: 1
      === N: the NORM_REAL adapter, which only sim/tb_llama_top_real.vhd reaches ===
      MUTATION ANCHOR MATCHED 0 TIMES, expected 1
```

Exactly the one line the document quotes, at the commit it names.  The same
script at `56d13e3` gives **nine**.

`sim/mutate_attn_sweep_pipe.sh` across its whole history:

```
mutate_attn_sweep_pipe   bc4156f   anchor-failure lines: 0      <- the commit that added it
mutate_attn_sweep_pipe   4e9915b   anchor-failure lines: 1      <- TRACK MIDGAP broke P7's anchor
      ROW P6_off
      MUTATION ANCHOR MATCHED 0 TIMES, expected 1
mutate_attn_sweep_pipe   56d13e3   anchor-failure lines: 1      <- still dead
```

The whole sweep over the eleven replayable harnesses at `56d13e3`:

```
mutate_a_drain_wide         0     mutate_attn_kv_seam         7
mutate_a_wbase              0     mutate_attn_score_hdr       1   (its OWN Z0 row -- by design)
mutate_attn_block           0     mutate_attn_sweep_pipe      1   (P7)
mutate_attn_score_early     0     mutate_fk33_seam            1
mutate_llama_top_land       0     mutate_llama_top_kv         9
mutate_llama_top_smp        0     mutate_llama_top_normuram   9
                                  mutate_rmswire              2
```

`mutate_llama_top_normuram.sh` names its own dead anchors:

```
--- U1-U5: the reshape's own failure modes ---
ANCHOR MATCHED 0 TIMES, REQUIRED 1:
  '            wrd <= nwrom(nidx*NWORD + wptr);'
ANCHOR MATCHED 0 TIMES, REQUIRED 1:
  '              r(k*NWORD + w) := NW_TBL(k)((w+1)*WW-1 downto w*WW);'
--- U6/U6x: the CYCLE BUDGET, and the attribution control for wbusy ---
ANCHOR MATCHED 0 TIMES, REQUIRED 1:
  "        signal wbusy : std_logic := '1';"
```

### 4.5 The three dead harnesses (MEASURED)

```
.../n0/rtl/gdn_state_store.vhd:903:24: unit "gdn_conv_w_mem" not found in library "work"
M0   unmutated     bench ANALYSIS  R_XN oracle -
```

`rtl/gdn_conv_w_mem.vhd` was added by `748ff91`.  With it in `FILES`:

```
M0   unmutated     bench PASS      R_XN oracle 9/9
```

### 4.6 The gate's own teeth (MEASURED)

```
--- selftest: the detector against MEASURED states at 56d13e3 ---
  sim/mutate_attn_block.sh           want VULNERABLE   got VULNERABLE     OK
  sim/mutate_attn_score_early.sh     want VULNERABLE   got VULNERABLE     OK
  sim/mutate_attn_sweep_pipe.sh      want VULNERABLE   got VULNERABLE     OK
  sim/mutate_fk33_seam.sh            want SAFE         got SAFE           OK
  sim/mutate_llama_top_smp.sh        want SAFE         got SAFE           OK
  sim/mutate_attn_kv_seam.sh         want SAFE         got SAFE           OK
  sim/mutate_llama_top_kv.sh         want SAFE         got SAFE           OK
  sim/mutate_a_drain_wide.sh         want SAFE         got SAFE           OK
--- selftest PASS ---
checked 62 harnesses; 0 finding(s)
```

`attn_kv_seam` and `llama_top_kv` are the load-bearing negatives: they carry
the SAME `echo ""` helper as the three positives and are saved only by their
call sites, so a detector that keyed on the helper alone would name them too.

R1 and R2 were teeth-checked separately, against a manifest mutated three ways:

```
=== R1: drop sim/mutate_gray.sh from the manifest
FAIL R1: sim/mutate_gray.sh is not in sim/mutation_harness_audit.tsv. ...
=== R1: a manifest row naming a file that does not exist
FAIL R1: the manifest names sim/mutate_ghost.sh, which does not exist.
=== R2: claim SELFTEETH for a script with no Z0 row
FAIL R2: sim/mutate_gray.sh is recorded SELFTEETH but has no Z0 row.
FAIL R2: ... never prints BADMUT, so its Z0 row has nothing distinct to report.
FAIL R2: ... does not check that its Z0 row fired.  A self-teeth row whose
         result nothing reads is decoration.
=== restore
checked 62 harnesses; 0 finding(s)
```

---

## 5. Measured and REJECTED -- do not retry

- **"Classify by grepping for `echo \"\"`."**  REJECTED.  Nine harnesses
  contain it and only three of them are vulnerable; the other six are saved by
  a guard at the call site or in the consumer.  The construct is not the
  defect; the reachable path from it to a printed verdict is.
- **"Classify by grepping for a guard token anywhere in the file."**
  REJECTED, MEASURED.  `[ -n "$mutdir" ]` appears in `mutate_attn_block.sh`'s
  `run_case` -- as the FILE SELECTION test, `[ -n "$mutdir" ] && [ -r ... ] &&
  src=...`, not as a guard.  A token search called it safe.  The classification
  has to be per call site.
- **"`.*\"\\$(\\w+)\"` finds the mutdir argument."**  REJECTED, MEASURED.  The
  greedy `.*` matches the LAST such argument, which on `mutate_attn_block.sh`'s
  rows is `"$GEN"`, the oracle source.  The detector's first draft reported the
  file SAFE against a MEASURED vulnerability, and its own selftest is what
  caught it.  Find every `"$VAR"` on the line.
- **"Run the replay with `MUT_REPO` pointed at a historical tree."**
  REJECTED, MEASURED, and it produced a whole table of false findings.  Most
  of these scripts resolve the repo with `cd "$(dirname "$0")/.."` and ignore
  `MUT_REPO`, so they cd'd into the scratch directory, could not open their
  own sources, and reported EVERY row as `ANCHOR FAILED`.  Twenty-four
  harnesses were briefly "failing".  Run the copy from INSIDE the historical
  tree instead.
- **"A replay that stubs nothing is still a replay."**  REJECTED.  Fifty of
  the 62 apply the mutation INSIDE the row function, so stubbing that function
  stops the mutation running at all and the run comes back clean for the wrong
  reason.  The replay now reports NOT-REPLAYABLE rather than a verdict.
- **"Hand-transcribe the anchor text out of the script to bisect it."**
  REJECTED, MEASURED.  A hand-typed copy of `attn_sweep_pipe`'s P7 anchor said
  the anchor was already dead at `bc4156f`, the commit that ADDED the harness,
  which contradicted the replay.  The replay was right; the transcription had
  lost a line of context.  Bisect by running the script's own mutator.
- **"Increment the counter inside the function."**  REJECTED, MEASURED, in the
  fix itself.  `v=$(mrun ...)` runs `mrun` in a SUBSHELL, so `NBAD=$((NBAD+1))`
  inside it was discarded and `a_geom`'s Z0 gate would have passed with
  `Z0SEEN=0`.  The tally is done in the parent, keyed on the word the subshell
  printed.
- **"One shared helper for all five fixes."**  REJECTED as a design, on the
  brief's own condition.  The five have three different shapes (a helper that
  returns a directory; inline python whose rc nobody read; `sed -i` with no
  check).  A shared library would cover three of five, and it would add a
  shared mutable input to scripts whose main structural feature is a private
  self-copy taken precisely to avoid one.  The three same-shape fixes are
  textually identical instead.

---

## 6. Measurement traps hit, including my own

1. **The sweep that measured the sweep.**  See section 5.  Twenty-four
   harnesses were reported as having dead anchors because the replay could not
   find their sources.  This is the project's recorded *"the harness is
   reporting a fact about the harness"* shape for the sixth time, and the tell
   was that `stubbed:` came back EMPTY on the scripts with the biggest counts.
   **A diagnostic field that is empty is a result, not a blank.**
2. **A grep that matched the script's own legend.**  The first sweep counted
   lines matching `ANCHOR FAILED`, and several scripts print that string in
   their explanatory footer.  Same family as this project's recorded
   `C4_DONE`-in-the-echoed-source trap: anchor the match or pick a needle the
   haystack cannot hold.
3. **A detector whose own selftest found its bug.**  Twice: the greedy `.*`
   above, and the missing `[ -n "$D" ] || { ...; return; }` guard form, which
   made the first draft call `mutate_a_drain_wide.sh` VULNERABLE against a
   MEASURED SAFE.  Both were caught only because the selftest asserts against
   states that were RUN, not against the detector's own notion.
4. **A plausible narrative attached to a row that measured nothing.**  The P7
   row of `mutate_attn_sweep_pipe.sh` prints SURVIVED and the script's legend
   explains it as a schedule-only change the oracle cannot see by construction.
   The explanation is correct as a statement about schedule-only changes and
   irrelevant as a statement about that row, which has not mutated anything
   since `4e9915b`.  **The more reasonable the expected-survivor story, the
   less likely anyone checks that the mutant exists.**
5. **A fix whose validation was the thing it fixed.**  `a_geom`'s first `mrun`
   incremented `NBAD` in a subshell.  Had the Z0 row not been the validation
   step, the gate would have been a no-op and would have looked fine.

---

## 7. Open, not determined

- **Forty-nine harnesses are classified DERIVED, not MEASURED.**  Their guard
  text is quoted per file in `sim/mutation_harness_audit.tsv` and returns
  before any tool runs, but they were not individually run with an impossible
  anchor.  Fifty of 62 apply the mutation inside their row function, which is
  exactly what makes the cheap replay unavailable for them; the only route is
  a full run each, and a full run of the `llama_top`-class harnesses is
  minutes apiece.
- **Which committed tables, if any, contain the P7 no-op.**  P7's anchor died
  at `4e9915b` and only five commits have landed since.  No document in
  `docs/` was found quoting a P7 row after that commit, but the search was a
  grep for `P7` in `docs/`, not an exhaustive audit.
- **The dead rows are NOT re-anchored.**  `attn_sweep_pipe` P7,
  `attn_kv_seam` R3/R4/R5/R5b/L1, `llama_top_kv` (9), `llama_top_normuram`
  (9), `rmswire` R3/R9, `fk33_seam` (1).  Re-anchoring each one means deciding
  what the mutation should now mean against refactored RTL, which belongs to
  whoever owns those semantics.  `mutate_attn_sweep_pipe.sh` now exits
  NONZERO on P7 rather than printing SURVIVED, so the decay is loud.
- **Whether the eight fixed/audited scripts' OTHER rows are still meaningful.**
  This track checked that a no-op is distinguishable.  It did not re-derive
  whether each mutation is still the mutation its description claims.
- **`sim/regress.sh` has NOT been edited** (a gate may be live; editing the
  runner mid-run corrupts its tail).  The three lines are in section 8.
- **The Vivado-adjacent harnesses were not considered** -- this audit covers
  `sim/mutate_*.sh` only.  If a `hw/fk33/*.py` selftest applies textual
  mutations, it is unaudited.

---

## 8. The gate row, written but NOT wired

`sim/check_mutation_harness.py --selftest` runs in about 1.5 s, needs no GHDL,
no Vivado and no card, and reads `sim/mutation_harness_audit.tsv`.  It is worth
having for one reason: **the way this defect arrives is a new harness written
by copying an existing one**, and three of the five vulnerable scripts are
copies of each other.  R1 makes an unaudited new harness a red row on the day
it lands.

Apply these three edits to `sim/regress.sh` when no gate is running:

```
1.  beside the other selfcheck plan rows (near the `imglock` one, ~line 2107):
      printf 'mutaudit\tsim\tRUN\t-\t-\t-\t-\n' >> "$PLAN"

2.  in `declare -A SELFCHECK_CMD=(` (~line 2894):
      [mutaudit]="python3 $REPO/sim/check_mutation_harness.py --selftest"

3.  in `run_one`'s dispatch case (~line 2977), add `mutaudit` to the list:
      runguard|ipsync|...|imglock|mutaudit) run_selfcheck "$key"; return ;;
```

**What it is not.**  It is a static detector and therefore a LEAD.  The only
proof that a harness can tell an unapplied mutation from an inert one is a Z0
row inside that harness, run -- which is why `SELFTEETH` is a manifest class
and why R2 requires such a script to actually contain the row, print BADMUT,
and **branch on whether the row fired**.  `sim/mutate_attn_score_hdr.sh` had
the row and printed the verdict but nothing read it; that gate was added here.

---

## 9. What changed

| file | change |
|---|---|
| `sim/mutate_attn_block.sh` | `__ANCHOR_FAIL__` sentinel, BADMUT verdict, Z0 row, `Z0SEEN`/`NBAD` exit gate |
| `sim/mutate_attn_score_early.sh` | the same |
| `sim/mutate_attn_sweep_pipe.sh` | the same |
| `sim/mutate_normw.sh` | `mrow` reads the mutation's rc, BADMUT row, Z0 row, exit gate; `rtl/gdn_conv_w_mem.vhd` added to `FILES` |
| `sim/mutate_a_geom.sh` | `msub` refuses a no-op `sed` (`cmp` against the pre-image), `mrun`/`tally`, Z0 row, exit gate |
| `sim/mutate_attn_score_hdr.sh` | its existing Z0 row's verdict is now branched on (`Z0SEEN`, `NBAD`, nonzero exit) |
| `sim/mutate_fk33_seam.sh` | `rtl/gdn_conv_w_mem.vhd` added to `FILES` |
| `sim/mutate_llama_top_smp.sh` | `rtl/gdn_conv_w_mem.vhd` added to `FILES` |
| `sim/check_mutation_harness.py` | new: R1 manifest completeness, R2 SELFTEETH structure, R3 the call-site detector, `--selftest` |
| `sim/mutation_harness_audit.tsv` | new: all 62, class, MEASURED/DERIVED, and the guard mechanism per file |
