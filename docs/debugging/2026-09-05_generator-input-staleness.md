# The gate went red on a file I never edited: generator INPUTS go stale too

**2026-09-05.** Full `sim/regress.sh` run, this tree, GHDL 1.0.0 mcode.

## The question

> Why did the full gate report `OVERALL PASS 131 FAIL 1` with
> `FAIL sim:cardtop  GEN_CARDTOP_CHECK: STALE`, when nothing in the session
> had touched any file carrying the "GENERATED ... DO NOT HAND-EDIT" banner?

## The answer

`rtl/fk33_llama_top.vhd` is generated from `rtl/llama_top.vhd` by
`tools/gen_cardtop.py`. Commit `a8ecfc4` appended a 13-line correction to a
comment in `llama_top.vhd` and did not regenerate.

**`llama_top.vhd` is hand-written, carries no banner, and is an entirely
ordinary file to edit. It is also a generator's INPUT, and nothing on the file
says so.** The project's existing rule -- *"MANY OF THIS PROJECT'S `.vhd`
FILES ARE GENERATED. CHECK LINE 2 BEFORE EDITING ANY OF THEM"* -- is about
editing the OUTPUT and is checkable by reading the file in front of you. This
is the same hazard from the other side, and **line 2 of the file you edit
cannot warn you**, because the derived file is elsewhere and the source holds
no back-pointer.

## The procedure that produced it

1. Full gate, quiet box (0 Vivado by `/proc/PID/exe` census, 0 GHDL,
   25 GiB available), under `MemoryHigh=10G`. Verdict `REGRESSION: FAIL`.
2. Located the row: `grep -nE 'FAIL' log` filtered of `FAIL 0` and the
   timing report's own `TNS Failing` column, which otherwise match.
3. Read the ROW'S OWN log, not the summary. It printed the unified diff and
   named the file outright: `STALE: rtl/fk33_llama_top.vhd differs from what
   the generator emits`, followed by the exact 13 added comment lines.
4. `python3 tools/gen_cardtop.py --bench` to regenerate.
5. Verified the regeneration was clean by a property, not by reading: **no
   added line falls outside a VHDL comment.**
6. Re-ran the single check, then the FULL gate, from a tree with no edits in
   flight.

## The evidence

Before, the one failing row among 132:

```
FAIL       sim:cardtop                            0s  GEN_CARDTOP_CHECK: STALE
 OVERALL     PASS 131   FAIL 1   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: FAIL
```

The row's own log, which is where the answer was:

```
STALE: /home/orencollaco/GitHub/llama.vhdl/rtl/fk33_llama_top.vhd differs from what the generator emits
--- checked-in
+++ generated
@@ -71,6 +71,19 @@
+--                     CORRECTED 2026-09-05: that rise is a property of the
+--                     STIMULUS, not of this generic.  MEASURED with the same
...
GEN_CARDTOP_CHECK: STALE
SELFCHECK_EXIT=1
```

After regenerating and committing, the full gate from a clean-edit tree:

```
 suite sim   PASS 106   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26    FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 132   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS

PASS       sim:cardtop                            0s  GEN_CARDTOP_CHECK: OK
PASS       sim:tb_fk33_cardtop_ident            108s  ... RESULT: PASS -- 64
```

`sim/tb_fk33_cardtop_ident.vhd` regenerated **byte-identical** and never
appeared in `git status`. That is the control: had the generator been
nondeterministic or drifted for any other reason, that file would have moved
too, and the diff would not have been attributable to my comment alone.

## Measured and REJECTED -- do not retry

- **`grep -rln "llama_top" tools/*.py hw/fk33/gen_*.py` as a DETECTOR.**
  MEASURED: **29 files.** Narrowing to those that also emit a `.vhd` gives
  **9**, and nine still over-reports -- `check_kv_map.py`, `hbm_map.py` and
  `pack_model_fk33.py` read `llama_top` for unrelated reasons. **It is a lead,
  not a check.** It turns "read every tool" into "read nine". Shipping the
  one-liner as a gate would be exactly the decoration this project warns
  about: a check nobody has shown can discriminate.
- **Raising `BASELINE_PASS` from this run.** The floor is 124 and the run
  passed 132, which looks like a raise is due. It is not, and `regress.sh`
  says so itself: this tree has **22 rows a clean checkout does not get**
  (untracked benches, ignored model-dependent rows). *"the floor is a
  CLEAN-CHECKOUT number, and a floor raised to include rows that depend on
  your working tree or your model set is unreachable for everybody else."*
  The guard printing the reason is what stopped this.

## Measurement traps hit

- **The waiter exited 0 on a FAILED gate.** The background waiter's status is
  a fact about the waiter. `REGRESSION: FAIL` was in its output while its exit
  code said 0. This is the project's recorded rule reached for the third time
  in one session; gate on the sentinel the work writes, never the harness.
- **A bounded poller's clean exit looked like completion.** A 12-iteration
  poll loop ended `exit code 0` at 122 rows with the gate still running.
  Nothing distinguishes "finished waiting" from "finished" except reading the
  output.
- **The log is block-buffered and its line count is not progress.** The gate
  log sat at **6 lines while 120 row directories existed**. `stdbuf -oL` did
  NOT fix it, because `regress.sh` batches per row. Count the scratch row
  directories, or read `/proc/PID/cwd` of the running `ghdl` -- which is how
  the two slow rows (`tb_llama_top_bstate_seq`, `tb_llama_top_seq`) were
  confirmed alive rather than hung.
- **A first "comment-only" verification failed open.** The check was a
  `grep` pipeline whose middle stage errored (`ugrep: invalid syntax`), and
  the final stage printed "(none: comment-only)" anyway. A pipeline that can
  error and still print the reassuring branch is not a check. Redone with
  `awk` over the added lines.

## Open, not yet answered

- **`hw/fk33/rtl/fk33_engine.vhd` remains UNGATED.** Its generator takes no
  arguments and writes unconditionally -- **even `--help` rewrites the repo
  file** -- so a `--check` row cannot be added without changing the generator
  first. `tools/gen_cardtop.py --help` does not have this problem (argparse
  exits first), which is precisely why it could be gated.
- Whether any OTHER hand-written file in this repo is a generator input with
  no back-pointer. Nine candidates identified above; not read.
