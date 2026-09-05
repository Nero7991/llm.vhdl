# B's mover extraction broke LOUDLY and nobody heard it for two days

**2026-09-05.** `sim/ooc_gdnadapt_extract.py`, `rtl/ooc_gdnadapt_top.vhd`,
`rtl/ooc_gdnadapt_ss_top.vhd`. Workstation, Vivado 2023.2, GHDL 1.0.0 mcode.

## The question

> `sim/ooc_gdnadapt_extract.py` regenerates B's data mover from
> `rtl/llama_top.vhd`. Is the committed generated file still what the
> generator emits, and if not, what does that do to `-4.008 ns` (111 MHz),
> the project's headline blocker for subsystem B?

## The answer

**No. It has been stale since `5f1db1a` (2026-09-03 16:20), and the generator
has been REFUSING TO RUN for exactly as long.** The B state tier added nested
`generate` blocks inside `gb_real`; the extractor's `END_RE` was pinned to a
literal two-space indent, so its depth count never returned to zero and it
exited 1 with `no matching 'end generate;' for gb_real`.

**The failure was loud, correct, and unheard, because nothing ever ran the
tool.** This is not a silent-corruption bug. Anyone who had invoked it would
have been told precisely what was wrong. There was no gate row, so nobody
invoked it.

**`-4.008` was NOT wrong when it was measured.** It was taken at `e9beec9`
(2026-09-03 13:11), when the extraction was genuinely in sync. It stopped
describing the tree three hours later. The correct statement is not "the
headline blocker was measured wrong", it is **"the headline blocker is
unverified against any tree from the last two days, and the drift since is
large enough that it must be re-measured."**

## The procedure that produced it

1. `git log -1` on all three files: every one last touched at `e9beec9`.
   `git log e9beec9..HEAD -- rtl/llama_top.vhd`: **five** commits since.
2. Ran the COMMITTED extractor against the `llama_top.vhd` of each commit, to
   find the failure mode rather than assume it:

   ```
   extractor@HEAD  vs  llama_top@e9beec9  ->  wrote 614 lines, EXIT=0
   extractor@HEAD  vs  llama_top@5f1db1a  ->  no matching `end generate;`, EXIT=1
   ```

   This is the step that overturned the working hypothesis. "Stale generated
   file" reads as a silent-drift bug; the tool was in fact refusing outright.
3. Fixed `END_RE` from `^  end generate;\s*$` (two literal spaces) to
   `^\s*end generate(\s+\w+)?\s*;\s*$`, which also admits a labelled
   `end generate <label>;`.
4. Added `--check`, which regenerates in memory and diffs rather than writing.
5. **Found `main()`'s return was discarded** -- `main(sys.argv)` with no
   `sys.exit`, so `--check` would have exited 0 whether stale or not. A gate
   row on that is decoration. Changed to `sys.exit(main(sys.argv))`.
6. Teeth-tested the check in four states (below).
7. Measured the drift, split by attribution (below).

## The evidence

### Drift, body lines only (everything below `^entity`)

Comparing the committed generated file against what the generator emits:

| generated file                | pre-existing at HEAD | added by tonight's tap edit |
|-------------------------------|----------------------|-----------------------------|
| `rtl/ooc_gdnadapt_top.vhd`    | **225**              | 106                         |
| `rtl/ooc_gdnadapt_ss_top.vhd` | **60**               | 82                          |

The 225 and 60 predate this session entirely and are the real staleness. The
106 and 82 are this session's conv-tap wiring and are expected.

**The `--state-store` variant UNDERSTATES staleness by construction.** That
mode substitutes memories 1 and 2, so drift inside them is masked. Do not read
60 as "this one was nearly fine"; read it as "this instrument cannot see part
of the block".

### Teeth, four states

| # | state | result |
|---|---|---|
| 1 | committed files vs current generator | `GDNADAPT_STALE`, exit 1 |
| 2 | freshly regenerated into scratch | `GDNADAPT_CHECK ok`, exit 0 |
| 3 | output file absent | `GDNADAPT_STALE`, exit 1 |
| 4 | **attribution control**: prologue stripped, body compared alone | still differs, 317 / 142 lines |

**Control 4 is the one that matters and it nearly went unrun.** State 1's first
diff hunk lands at line 17, inside the PROLOGUE -- text edited in this same
session. Without stripping it, the row would have been credited with detecting
RTL drift when it might only have been detecting its own comment. The rule this
project already carries is *a kill does not settle it, run the attribution
control*; this is that rule applied to a staleness check.

## Measured and REJECTED -- do not retry

- **Chaining the two checks in one `SELFCHECK_CMD` entry with `&&`.**
  `run_selfcheck` runs the string UNQUOTED and NOT through a shell:
  `timeout -k 5 "$TIMEOUT" ${SELFCHECK_CMD[$tb]}`. `&&` would be handed to
  python as `argv[4]`; `main()` reads `ent = argv[3]` and ignores the tail, so
  the row would have checked ONLY the plain file, passed, and never looked at
  the `--state-store` one. **A guard passing for the wrong reason, introduced
  at the point of installation rather than in the check.** Every existing
  `SELFCHECK_CMD` entry is a single command; none chains. The fix is a
  `--check` form taking no `out` argument that checks both canonical outputs
  in one process.
- **Raising `BASELINE_PASS` 132 -> 133.** 132 is the pass count on THIS working
  tree, which carries untracked vectors and benches. The floor is deliberately
  a CLEAN-CHECKOUT number: `regress.sh:403` reads `BASELINE_PASS=124`, measured
  on a `git archive` of the index tree with `MV4I_FK33_FILE=/nonexistent`,
  `--jobs 1`, and only from a run whose NOT IN GIT section says `(none)`.
  The correct move is 124 -> 125.

## Measurement traps hit

- **I assumed silent drift and would have written that up.** The failure mode
  was loud from the first commit. Running the historical tool against the
  historical inputs cost two commands and overturned the framing. *A hypothesis
  about how something failed is not evidence about how it failed.*
- **I nearly credited the check with teeth it had not earned**, because the
  first diff hunk was in prose I had myself edited hours earlier.
- **`--check` would have exited 0 forever** because a return value was
  discarded. The check was correct and completely inert. This is the project's
  "a check that does not count is indistinguishable from a check that did not
  run", one layer up: at the process exit code rather than at a bench counter.
- **`sim/ooc_gdnadapt_extract.py:69` still claimed "this script has no
  `--check` and no gate row".** True when written, false once `--check`
  landed. A comment describing the absence of a feature becomes a lie the
  moment the feature is added, and nothing checks comments.

## Open, not yet answered

- **B's mover has not been re-measured yet.** A run against a fresh extraction
  is queued (`bmover-chain.scope`, gated on Vivado PRESENCE via
  `/proc/PID/exe`, both `ooc_gdnadapt` and `ooc_gdnadapt_ss`, period 5.0 ns).
  Until it returns, the honest figure for B's mover is **unknown**, not
  `-4.008`.
- **`sim/ooc_cattnadapt_extract.py` is ungated.** It has no `--check`, so
  nothing would notice if it drifted. See the CORRECTION below for what its
  drift actually measures.
- **`sim/ooc_normadapt_extract.py` is in sync** but carries the same
  four-space `END_RE` latent bug. It has not broken because the norm adapter
  has no nested generate yet. It will break the day one is added, loudly, and
  nothing will hear it either.
- **`hw/fk33/gen_fk33_engine.py` takes no arguments and writes
  unconditionally**, so it can be neither checked nor invoked safely. Recorded
  in `regress.sh` at the `c4stale` block; still true.


---

## CORRECTION, 2026-09-05, same session

**WITHDRAWN: "C's `151.3 MHz` has the same exposure as B's `-4.008`."** I wrote
that in the "open, not yet answered" list above by analogy, before measuring it.
Then I measured it:

```
rtl/ooc_cattnadapt_top.vhd    whole-file differing lines: 2
                              body-only differing lines : 0
```

**C's extracted body is in sync. The 2 differing lines are header text.** So
C's `151.3 MHz` does NOT carry B's staleness exposure, and re-deriving it is
not required for the same reason.

**And the reason is structural, not luck.** The two extractors bound the block
differently:

| script | how it finds the block's `end generate` | survives nested generates |
|---|---|---|
| `ooc_gdnadapt_extract.py` (B) | counts `generate` depth, with an END pattern pinned to a literal indent | **no** -- this is the bug |
| `ooc_cattnadapt_extract.py` (C) | first `end generate` at the block's OWN indentation, computed from the start line | **yes**, by construction |

C measures the start line's indentation at run time and matches it; nested
generates are deeper, so they cannot be mistaken for the block's own end. That
is strictly more robust than a depth counter whose END pattern is a fixed
string, and it is why C survived `5f1db1a` untouched while B did not.

**The lesson is the one this project keeps relearning: an analogy between two
files is a hypothesis about them, not a measurement of them.** "B's extractor
broke, C's is the same kind of script, therefore C is exposed too" is exactly
the shape of reasoning that produced the `gdn_block` BRAM misattribution --
ruling something in by resemblance rather than by reading it. Reading C's
twelve lines of end-detection cost less than writing the sentence that was
wrong.

**Still true and still open:** C's extractor is ungated. Being in sync today is
not a property that anything maintains. `sim/ooc_normadapt_extract.py` is in
sync too and carries the fixed four-space `END_RE`
(`^    end generate;\s*$`), so it has B's fragility and C's luck: it will break
the day the norm adapter gains a nested generate, loudly, and nothing will hear
it. Neither has a `--check`; the `CANONICAL` table in
`sim/ooc_gdnadapt_extract.py` is the pattern to copy when they get one.
