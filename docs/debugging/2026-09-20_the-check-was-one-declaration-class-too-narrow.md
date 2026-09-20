# The gdnadapt seam check was one declaration class too narrow

TRACK GDNSYNTH, 2026-09-20. BC-250 (`cachyos-bc250`, `xcvu33p-fsvh2104-2L-e`,
Vivado 2023.2). Repo at `fc6472a` plus the regeneration this file describes.

## The question, verbatim

> PART 1 -- does `rtl/ooc_gdnadapt_top.vhd` actually synthesise now?
> TRACK IPSYNC (commit `de77c9a`) fixed a real defect [...] It explicitly left
> open whether the file now SYNTHESISES: "only the known error is gone; no
> Vivado was run against it."

## The answer, up front

**No, it did not.** MEASURED, first run, 23 seconds in:

```
ERROR: [Synth 8-36] 'bst_const_base' is not declared [rtl/ooc_gdnadapt_top.vhd:677]
```

`bst_const_base` is a **PORT** of `llama_top` (`llama_top:972`), added by the
**same 2026-09-18 commit** that added the `B_CONST_HBM` **generic** IPSYNC had
just repaired. IPSYNC's new closure check, `undeclared_generics()`, excludes
ports by construction -- its regex carries the negative lookahead
`(?!in\b|out\b|inout\b)` -- so it passed green over a file that does not
synthesise, for exactly the reason it had been written to prevent.

The extraction synthesises after adding the port to the generator's PROLOGUE
and widening the check to the whole entity header. **MEASURED: `grep -cE
'^ERROR'` = 0.**

## The reusable part

**The check stated its own limit honestly, and the limit was the bug.** Its
docstring read: *"It does NOT replace a compile step: it sees undeclared
GENERICS only, and is blind to every other way the extraction could fail to
analyse."* That sentence is true, was written in good faith, and describes the
hole the very next name fell through -- a name that was already in the tree,
from the same commit, arriving through the same mechanism.

The mechanism is not "generics are hardcoded". It is **"the prologue is a
hardcoded template"**, and the prologue hardcodes the generic clause *and the
port list*. Two lists, one mechanism, identical failure modes. **Covering one
of them is not half a check; it is a check with a hole the shape of the
other.**

So the operational rule: when you write a guard after a defect bites, ask what
OTHER declaration lists / config sites / code paths reach the same failure
through the same mechanism, and cover the mechanism rather than the instance.
The instance is the one you will not see again.

This is the project's recorded *"a teeth test whose mutant is built from the
same misconception as the check cannot detect that misconception"* in a
milder form: here the mutant was fine, the check worked on what it covered,
and the scope was drawn around the example instead of around the cause.

## The procedure, in the order it was run

1. **Stage clean inputs.** 114 `rtl/*.vhd` blobs from `git show HEAD:<path>`
   into a standalone remote root, because `rtl/llama_top.vhd`,
   `rtl/attn_block.vhd` and three others carried other tracks' in-flight
   edits. Isolates "does HEAD synthesise" from "does the working tree
   synthesise". Manifest sha256 compared on both boxes before the run.
2. **Run the OOC synthesis** at the shipping `B_RECUR_LANES = 4`. Isolates
   Part 1's question with the lever at its default, so the same run is also
   Part 2's baseline arm.
3. **Read the outcome with a LINE-ANCHORED grep** (`grep -cE '^ERROR'`). A
   Vivado log can contain the script that writes it; here `-notrace`
   suppressed the echo, but the anchor costs nothing and the unanchored form
   has twice reported a finished job seconds after launch in this project.
4. **Classify the undeclared name before fixing it.** `grep -n
   bst_const_base` in `llama_top` -- `:972`, in the PORT list, not the generic
   clause and not an architecture signal. This is the step that turned "add
   the missing name" into "the check is one class too narrow".
5. **Fix the GENERATOR, never the generated file.** `rtl/ooc_gdnadapt_top.vhd`
   line 2 reads `DO NOT EDIT`. Added the port to `PROLOGUE`, widened
   `undeclared_generics()` to parse the entity's port list too.
6. **Teeth table with an attribution control**, below.
7. **Regenerate and `git diff` the output**, confirming it contains the change
   and nothing else: 11 insertions, 0 deletions, all the new port and its
   comment.
8. **Re-sync and re-run.**

## The evidence, as raw output

First run, `B_RECUR_LANES=4`, tree at HEAD `fc6472a`:

```
Starting Synthesize : Time (s): cpu = 00:00:04 ; elapsed = 00:00:04 . Memory (MB): peak = 1735.637
ERROR: [Synth 8-36] 'bst_const_base' is not declared [/home/labuser/gdnsynth/tree/rtl/ooc_gdnadapt_top.vhd:677]
INFO: [Synth 8-11252] unit 'rtl' is ignored due to previous errors [.../ooc_gdnadapt_top.vhd:1308]
9 Infos, 0 Warnings, 0 Critical Warnings and 2 Errors encountered.
```

The use site, `rtl/ooc_gdnadapt_top.vhd:676-677`, verbatim from `llama_top`:

```vhdl
          layer => js_layer, state_base => bst_state_base,
          const_base => bst_const_base,
```

`llama_top:971-972`, the declaration that did not travel:

```vhdl
    -- hbm.gdn_const_base, B_CONST_HBM only: the per-layer constants images.
    bst_const_base : in  std_logic_vector(32 downto 0) := (others => '0');
```

### Teeth, with the attribution control

Run against the real `rtl/llama_top.vhd`. ROW 1 is the state IPSYNC left.

| row | check | output under test | result |
|---|---|---|---|
| 1 | old (generics only) | old (port missing) | **NOTHING** -- the defect, missed |
| 2 | NEW | old (port missing) | **`['bst_const_base']`** -- teeth |
| 3 | NEW | NEW (port added) | NOTHING -- clean |
| 4 | old | NEW | NOTHING -- **attribution control** |
| 5 | NEW | NEW, `B_CONST_HBM` generic deleted | `['B_CONST_HBM']` -- old half intact |
| 6 | NEW | NEW, `bst_state_base` port deleted | `['bst_state_base']` -- port half generalises |

**Row 4 is the row that matters.** The old check returns NOTHING on both
outputs, so it cannot discriminate in either direction: the kill in row 2 is
attributable entirely to the new port half and not to a pre-existing property.
Rows 5 and 6 are the pair that shows the widening did not trade one class for
the other.

### Measured and REJECTED -- do not retry

**Widening the check to the port list WITHOUT stripping port-map formals.**
MEASURED: the first widened version reported **four** names,
`['bst_const_base', 'busy', 'err', 'seq_rst']`, and three were false. `busy`,
`err` and `seq_rst` appear in the extracted body **only as port-map formals** --
`busy => b_busy` at `:522`, `err => js_err` at `:685`, `seq_rst => b_seq_rst`
at `:523`. A formal names a port of the *instantiated* entity, is resolved in
that entity's scope, and has nothing to do with `llama_top`'s port of the same
spelling. The generic-only version never met this because a generic name is
never a port-map formal, so widening the name set required widening the
exclusion set in the same edit. Fix: `re.sub(r"\b[A-Za-z]\w*\s*=>", "=>", body)`
before the search, which removes only the left-hand side and leaves an actual
of the same name intact.

Had this shipped, the check would have cried wolf on every run and the
rational response would have been to narrow it again -- back through the hole.

**A `--check` run against a COPY of `llama_top` at another path.** MEASURED:
`python3 sim/ooc_gdnadapt_extract.py --check /mnt/storage/.../chk/llama_top.vhd`
reports `GDNADAPT_STALE ... (10 diff lines)` on a tree that is not stale, because
the generator writes its INPUT PATH into the output banner:

```
--- block, subsystem B's data mover, copied verbatim from rtl/llama_top.vhd.
+++ block, subsystem B's data mover, copied verbatim from ../../../../mnt/storage/.../chk/llama_top.vhd.
```

So the staleness check cannot be run against a clean-tree copy to separate
"stale" from "another track edited `gb_real`". Run it against the repo path and
compare `git show HEAD:` separately, which is what was done here. Not fixed --
see OPEN below.

## Measurement traps hit

- **`--check` was green on both the working tree and HEAD the whole time.**
  `GDNADAPT_CHECK ok`, rc=0. It regenerates and diffs TEXT, so it compares the
  generator against itself: a round trip, not an oracle. The generator
  reproduced the same broken output it had written before, exactly as its own
  docstring already records for the two earlier instances. **A green
  `gdnstale` row is not evidence the extraction compiles**, and the only
  thing that settled Part 1 was running Vivado.
- **Vivado's memory figure at the point of the error is not the job's peak.**
  `peak = 1735.637` appears in the line *before* the error, four seconds in.
  Quoting it as the extraction's footprint would understate it by more than
  half; the completed run is recorded in the WORKLOG entry.
- **The first failing run's cgroup sample read `1196822528 0`** -- 1.20 GB
  resident, 0 swap. That is a crashed job's number and measures nothing about
  the real synthesis. Recorded here only so it is not mistaken for one later.

## Open, not determined

- **The enclosing-scope SIGNAL class is still uncovered**, and it is the
  obvious fourth instance. `llama_top`'s architecture declares hundreds of
  signals; the prologue re-declares by hand the ones `gb_real` reads; a new
  one is invisible to this check, which parses the entity header only. Also
  uncovered: types, subprograms, architecture constants, and every failure
  that is not an undeclared name (type mismatch, width mismatch, wrong port
  direction, unbound instance).
- **There is still no compile step in the gate.** The reason is recorded and
  unchanged: `gdn_block` and `gdn_state_store` do not analyse under this box's
  GHDL, so the row could not be made green. Until one exists, every class
  above reaches `synth_design` unannounced.
- **Whether `rtl/ooc_gdnadapt_ss_top.vhd` has the same hole.** It is frozen,
  deliberately out of `CANONICAL`, and nothing regenerates it. Not examined.
- **The `--check`-against-a-copy false positive** above is unfixed. A
  path-independent banner would fix it; not done, because changing the banner
  rewrites the committed file and that is a separate commit from this one.

---

## ADDENDUM, same day: the harness's DEFAULT arm is not the arm the card builds

Found while setting up Part 2's `B_RECUR_LANES` pair, and it retro-discounts
every figure this harness has produced at its defaults.

**MEASURED.** `hw/fk33/gen_fk33_card.py` passes:

```
149:    "--generic", "B_STATE_AXI=true",
171:    "--generic", "B_CONST_HBM=true",
```

`sim/ooc_gdnadapt.tcl` defaulted **both false**. `B_STATE_AXI` selects between
two mutually exclusive generates in the extraction -- `gen_st_flat` at
`:565` and `gen_st_tier` at `:602` -- so the harness was building the flat
all-layers state array and the card builds the tiered store over AXI.

The harness's own header already said so, in the comment block added when
`GDNADAPT_STATE_AXI` was introduced. It was accurate and it was not acted on.

**How much it matters, MEASURED on the same tree, `B_RECUR_LANES = 4`:**

| | flat (`B_STATE_AXI=false`) | tier (`=true`), the card's arm |
|---|---|---|
| CLB LUTs | 133,591 | 70,815 |
| LUT as Memory | 40,721 | 15,981 |
| RAMB36 | **5,472** | **33** |
| RAMB18 | 0 | 126 |
| URAM | 0 | **32** |
| DSPs | 191 | 171 |

The flat arm wants **5,472 RAMB36 on a 672-tile part**. That is this
project's recorded headline B blocker, and it is a property of the arm the
card does not build.

**Two things follow.**

First, the flat run reproduces the recorded 5,472 RAMB36 **and** the recorded
WNS **-4.008** to the digit, which is a good control that the harness is
behaving and that this track's edits did not perturb the default arm. It is
also the tell that those recorded numbers were taken in the flat
configuration. Any earlier figure from this harness quoted without a
`B_STATE_AXI` qualifier should be read as flat-arm until checked.

Second, the tier arm uses **32 URAM**. This project's standing note is that
"URAM cannot hold a constant table on this device" and that 320 idle URAM288
are unusable for any initialised table -- true, and the complement is visible
here: a store **written at run time** does get URAM, which is exactly what
`gdn_state_store` over AXI is. The note and this measurement agree; neither
generalises to the other case.

`GDNADAPT_CONST_HBM` was added alongside so a card-matching run is one
environment variable rather than a thing to remember.

### Measurement trap hit, and it nearly reached the report

The first `B_RECUR_LANES` pair in the flat arm was **not one-variable**. Its
`lanes=4` point ran against remote tree `5b6019f4` and its `lanes=16` point
against `864bb31e`; the two trees differ in the harness script only (an added
explicit `-generic B_CONST_HBM=false`, which equals the entity default, and
census lines that run after `synth_design`). Both differences are arguable as
inert and **the argument is not the point** -- the recorded failure here is a
pair compared as a one-variable experiment that differed in five, whose
controls were real but on the wrong axis. The `lanes=4` point was re-run on
the current tree before the pair was quoted. The tier pair never had this
problem: both its arms ran on `864bb31e`.

### And the WNS in this harness measures nothing about this lever

`RESULT ooc_gdnadapt wns=-4.008` is **identical to three decimals in all four
arms** -- across a 63,000-LUT difference and a 166x difference in RAMB36. Two
independent extractions agree (the summary-table regex and
`get_property SLACK [get_timing_paths ...]`), so -4.008 is a real property of
each netlist; it is simply pinned by a path common to every configuration.

**A metric that does not move when the design changes this much has not been
shown to have any resolution on the thing under test.** "WNS unchanged" is
therefore NOT evidence that `B_RECUR_LANES=16` is timing-neutral, and must not
be quoted as if it were. Compounding it: `create_clock` runs AFTER
`synth_design` in this script, so synthesis was never timing-driven, and
nothing here places or routes.
