# Can the five descriptor emitters that PIECES left flat learn `pieces`, and can the stack checker be made to fail on the thing it guards?

**Date:** 2026-08-30. Branch `fpga`. **TRACK STRIPEPATH.** Base commit
`3a2d0d0`; landed at the sha in section 11.

**No hardware was touched.** Nothing below ran `xsdb`, `hw_server`,
`vivado ... program`, `hw/fk33/pcieep.sh`, `hw/fk33/jtag.sh`,
`hw/fk33/flash.sh`, anything under `hw/fk33/tcl/`, or any `hw/fk33/host/*`
against the card. Six offline commands were traced with
`strace -f -qq -e trace=openat,open`: **zero `/dev` opens of any kind**,
section 4.7. Section 9 is a command list for Oren with its card arm separated.

**Tools named:** `python3` over `tools/gen_layer_program.py`,
`tools/gen_lmhead_windows.py`, `tools/verify_mv4i_desc.py`,
`tools/check_hbm_stack.py`, `hw/fk33/host/fk33_run_layer.py`,
`tools/hbm_map.py`, `tools/gen_mv4i_desc.py`,
`hw/fk33/host/fk33_load_weights.py`, `hw/fk33/host/fk33_run_job.py`,
`tools/weights_residency.py`, `tools/check_mv4i_set.py`; `cc` building
`tools/mv4i_desc_ref.c` and `ref/mv_fk33_tr.c`; `strace`; `diff`;
`git show`, `git diff`, `git rev-parse`.

**Files read as the authority:**
`docs/debugging/2026-08-30_pieces-four-consumers.md` section 8 (the work
order), `docs/debugging/2026-08-30_packstripe-lane-arena-placement.md`,
`docs/debugging/2026-08-30_counters-cycles-beats-starved.md` sections 4.2-4.4
(the 21.67 cycles/beat and its derivation), `tools/hbm_map.py::file_pieces` and
`tools/gen_mv4i_desc.py::sub_base/piece_extents/load_manifest` at `263e0ee`,
`hw/fk33/host/fk33_run_job.py::make_plan` at `263e0ee` (the shape copied), and
the two live manifests under `/mnt/storage/llama-models/`.

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement with its assumption and its falsifier stated).

---

## 1. The question, verbatim

> 1. **`hw/fk33/host/fk33_run_layer.py:996`** builds a flat descriptor from
>    `json.load`ed entries, out of reach of the `load_manifest` guard. **On a
>    v2 manifest it would emit a wrong program SILENTLY.** ... It "needs the
>    same two lines `fk33_run_job.py` got."
> 2. **`tools/gen_layer_program.py`**: `pieces=G.piece_extents(ent)` at ~line
>    704 plus `allow_striped=True` at its two `load_manifest` sites.
> 3. **`tools/gen_lmhead_windows.py`** and **`tools/verify_mv4i_desc.py`**:
>    same shape, they refuse cleanly today.
> 4. **`tools/check_hbm_stack.py` WRONGLY PASSES a v2 manifest.** ... **That is
>    a guard passing for the wrong reason and it must be fixed, not merely
>    taught** -- ask what it would take for it to FAIL.
> 5. **`pack_model_fk33.expand_pieces()` is a SECOND PRODUCER** ... **report,
>    do not edit.**
>
> Deliver: the fixes; an inertness oracle; a discrimination control beside it;
> teeth with attribution; coverage stated as what was READ; and the command
> list to run the striping experiment on the card, with the prediction stated
> in advance.

---

## 2. The answers, up front

**All five are done and the flat path is provably inert, byte for byte.**
MEASURED by capturing every artefact BEFORE the edit and `diff`ing after:
**311 A-job descriptor images, 296 `fk33_run_layer` descriptors (11,544 words),
15 lm-head windows, 39 images against the C builder, and the `--json`, report
and `--mutate` text of every tool -- all identical.** Nine independent `diff`s,
section 4.1. The one intentional delta is a single added coverage line in
`check_hbm_stack`.

**The discrimination control says the feature is live, and by how much.**
MEASURED against the shipping striped manifest by an oracle that re-derives
every base from the .mv4i's own 0x38 table and the manifest's raw `pieces`
JSON, importing neither `gen_mv4i_desc` nor `hbm_map`:

| emitter | bases read | MOVED | wrong vs the manifest | segments FLAT -> STRIPED |
|---|---|---|---|---|
| `gen_layer_program --token` | 8,397 | 8,397 | 0 | 17 -> **25** |
| `fk33_run_layer` (32 layers) | 7,992 | 7,992 | 0 | 15 -> **25** |
| `gen_lmhead_windows` (15 windows) | 405 | 405 | 0 | 3 -> **25** |

Segments are read from **address bits [32:28]** (`addr // 256 MiB`), never from
a piece's `segment` label. The lm-head row is the clearest statement of the
whole project: `output.weight`'s 27 lane sub-regions go from **3 pseudo-channels
to 25**.

**`fk33_run_layer` was emitting a wrong program silently, and it is now
measured how wrong.** MEASURED on the pre-change file against the striped
manifest, all 32 layers: **296 descriptors emitted, 0 errors, and 7,992 of
7,992 sub-region bases wrong** -- every one of them `hbm_offset + <file offset>`
where `hbm_offset` names a 4 KB header.

**`check_hbm_stack.py` could not see the defect it exists to detect, and now
can.** MEASURED: with a piece deliberately straddling the 4 GiB HBM stack line
(teeth row **T9**), the pre-change program printed
`checked 7154 byte ranges ... PASS no range crosses a stack boundary`. The new
one prints
`blk.0.ffn_gate.weight.mv4i:w02: 4294443008 .. 4295491584 crosses 4294967296 (stack 0 -> 1); 524288 bytes on the wrong side`.
It earns **7 kills** across the teeth table and the pre-change file earns
**zero on every row**, with its control surviving -- so that attribution is
clean rather than a column in which everything dies.

**The range COUNT was never a discriminator and the identity is a coincidence
worth knowing.** Flat: 250 file ranges + 249x27 sub-region ranges = 6,973.
Striped, corrected: 249x28 piece ranges + 1 unstriped file = 6,973. **Both come
to the same 7,154 total.** A reader comparing the two runs by their count line
sees no change at all while every one of 6,723 ranges has been replaced.

**A SIXTH AND A SEVENTH CONSUMER EXIST AND ARE NOT MINE.**
`hw/fk33/host/fk33_run_token.py:1103` has the identical defect -- its own
`TailJob` class, its own bare `json.load`, `j.hbm_offset = int(ent["hbm_offset"])`,
and no guard in front of it -- and it emits the **lm-head's 15 window
descriptors on the token path**. Same one-line fix. Separately,
`tools/weights_residency.py` **FAILS loudly** on the striped manifest
(`stack_hole_bytes: manifest 0, the gaps between consecutive placements sum to
2690994176`), which is correct behaviour for the wrong reason: the gaps are the
segment-granular lane arenas and are by design. Both are in section 8.

**Two of my own new checks earn zero independent kills and are labelled as
such**: the extent presence/size rule inside `gen_lmhead_windows.check_byte_cover`
(NOEXT arm kills identically to NEW on all 13 rows), and the `pieces` threading
in `gen_layer_program`/`fk33_run_layer`, which detects nothing and is a
correctness fix measured by the oracle rather than by teeth.

**CORRECTION TO THE BRIEF, MEASURED.** The brief (from PIECES) says
`gen_layer_program --token` on a striped set emitted `311 of 311 A jobs, 0
refused` with all 6,723 bases **byte-identical to the flat program's**. Against
today's manifest neither half reproduces. Section 7, trap 1.

---

## 3. The procedure, in the order it was run

| # | step | what it isolates |
|---|---|---|
| 1 | capture every artefact of all five tools on the flat manifest BEFORE any edit -- 313 + 31 descriptor files, 3 JSON/report files, 2 text reports | the control. Every "identical" below is a `diff` against a file on disk, not a memory |
| 2 | run the PRE-change `fk33_run_layer` against the striped manifest and count wrong bases | establishes the size of the defect being fixed, before fixing it. Without this the fix has no measured value |
| 3 | read `fk33_run_job.py`'s landed change and copy its shape, not its text | the brief says "the same two lines". It is two lines plus a whole-map check, and the whole-map check turned out to be already present in `run_layer`'s path (section 4.6) |
| 4 | the five edits, each minimal | -- |
| 5 | re-run every capture from step 1 and `diff` | inertness. Nine diffs |
| 6 | an oracle that re-derives every striped base from the FILE HEADER plus the RAW manifest JSON | discrimination. Deliberately imports neither emitter module, so agreement is not self-agreement |
| 7 | 13 mutants x 4 consumers x 4 arms x 2 target tensors | which check bit, not merely that one did |
| 8 | two extra arms (`NOMAP`, `NOEXT`) with ONE of my new checks disabled each | attribution INSIDE one file. The OFF arm cannot do this: it refuses the control too |
| 9 | a source mutant of `gen_mv4i_desc` in scratch (`MUTG`) | teeth for the one arm no manifest mutation can reach |
| 10 | `strace` on six offline commands | the hardware boundary, as evidence rather than as a claim |
| 11 | grep every `build_descriptor` / `hbm_base_for` / `load_manifest` / `hbm_offset` caller in the tree | whether the list of consumers is finished. It was not: two more |

---

## 4. The evidence, raw

### 4.1 Inertness: nine diffs on the flat manifest

```
=========== FINAL INERTNESS SWEEP, flat manifest, all five files edited ===========
1  gen_layer_program --token report      IDENTICAL
2  gen_layer_program --json             IDENTICAL
3  313 descriptor images                IDENTICAL
4  gen_lmhead_windows report            IDENTICAL
5  gen_lmhead_windows --mutate          IDENTICAL
6  31 window artefacts                  IDENTICAL
7  fk33_run_layer 296 descriptors       IDENTICAL
layers 32  descriptors 296  words 11544  sub-region bases 7992
jobs with pieces 0  jobs flat 296
8  verify_mv4i_desc --cross --bytes     IDENTICAL
1a2
>   format 'llama.vhdl FK33 load manifest v1': 0 of 250 entries are LANE-STRIPED, contributing 0 piece ranges
9  check_hbm_stack: one added coverage line, nothing else
```

DERIVED word count for the three descriptor emitters:
`311 x 39 + 296 x 39 + 15 x 39 = 12,129 + 11,544 + 585 = 24,258 descriptor
words byte-identical`, plus 39 images byte-identical to the C builder.

The other command lines of `gen_layer_program`, also byte-identical to the
pre-change file:

```
--stamp manifest IDENTICAL to pre-change
--stamp seq_tbl IDENTICAL to pre-change
--stamp sched IDENTICAL to pre-change
--layer 0 IDENTICAL to pre-change
--shape sim IDENTICAL to pre-change
```

**Why this is not a round trip.** The comparison is between two REVISIONS of the
same program over the same input, with the artefacts of the first written to
disk before the second existed. It cannot be satisfied by a
wrong-but-consistent implementation of the new path, because the old path did
not have one.

**What it does NOT show.** It shows the flat path did not move. It says nothing
about whether the striped path is right; that is 4.2.

### 4.2 Discrimination: the striped bases, re-derived independently

`/mnt/storage/track-stripepath/stripepath_oracle.py` and `..._rl.py`, copied to
`docs/debugging/2026-08-30_stripepath-oracle.py` and
`docs/debugging/2026-08-30_stripepath-oracle_rl.py`.

```
STRIPEPATH DISCRIMINATION CONTROL -- gen_layer_program.py --token
  descriptors compared        311
  sub-region bases compared   8397
  bases that MOVED            8397
  bases unchanged             0
  bases WRONG vs the manifest 0 []
  distinct segments, FLAT     17  [0, 1, ... 16]
  distinct segments, STRIPED  25  [1, ... 15, 17, ... 26]
  -> PASS the pieces path is LIVE

STRIPEPATH DISCRIMINATION CONTROL -- fk33_run_layer.py make_layer
  layers                      32
  descriptors compared        296
  descriptors byte-identical  0 (must be 0)
  sub-region bases compared   7992
  bases that MOVED            7992
  bases WRONG vs the manifest 0 []
  distinct segments, FLAT     15 [2, ... 16]
  distinct segments, STRIPED  25 [1, ... 15, 17, ... 26]

STRIPEPATH DISCRIMINATION CONTROL -- gen_lmhead_windows.py
  windows compared            15
  sub-region bases compared   405
  bases that MOVED            405
  bases WRONG vs the manifest 0
  distinct segments FLAT      3 [0, 1, 2]
  distinct segments STRIPED   25 [1, ... 15, 17, ... 26]
```

**Why this is an oracle.** The `want` value is built by a program that opens the
.mv4i and unpacks its 0x38 table with `struct`, reads `pieces` out of raw JSON,
and adds the row-window skip **recovered as the residue of the FLAT program's
own base arithmetic** -- so the skip never comes from the striped side. It never
imports `gen_mv4i_desc`, so it cannot inherit `sub_base`'s join, and it never
imports `hbm_map`, so it cannot inherit `file_pieces`.

### 4.3 The size of the defect that was fixed

```
fk33_run_layer.py on the STRIPED manifest, PRE-change vs POST-change
  descriptors                    296
  descriptors byte-identical     0
  sub-region bases               7992
  bases the PRE-change file got WRONG  7992  (100.0%)
```

### 4.4 Teeth: 13 mutants, 4 consumers, 4 arms

Arms: `NEW` the working tree; `NOMAP` = NEW with
`gen_lmhead_windows`'s `hbm_map.plan().check()` removed; `OFF` = this track's
five files at `3a2d0d0` (PIECES landed, this track not); `PRE` = additionally
`gen_mv4i_desc`, `hbm_map`, `fk33_run_job`, `fk33_load_weights` at `263e0ee^`.

Target `blk.0.ffn_gate.weight.mv4i`:

```
mutant  what it does                                         killed by (NEW)            NOMAP (attribution)        OFF (attribution)          PRE (none)
control the striped manifest, untouched                      -- SURVIVES --             -- SURVIVES --             glp,lmhead                 glp,runlayer
T1      one weight piece moved a whole 256 MiB segment up    glp,lmhead,runlayer        glp,runlayer               glp,lmhead,runlayer        glp,runlayer
T2      one weight piece misaligned by 1 byte                glp,lmhead,stack,runlayer  glp,stack,runlayer         glp,lmhead,runlayer        glp,runlayer
T3      two pieces of one tensor given the SAME address      glp,lmhead,runlayer        glp,runlayer               glp,lmhead,runlayer        glp,runlayer
T4      a piece's segment LABEL changed, address untouched   glp,lmhead,runlayer        glp,runlayer               glp,lmhead,runlayer        glp,runlayer
T5      a piece moved INSIDE its own segment                 -- SURVIVES --             -- SURVIVES --             glp,lmhead                 glp,runlayer
T6      one piece 4096 B short, the file no longer tiled     glp,lmhead,stack,runlayer  glp,stack,runlayer         glp,lmhead,runlayer        glp,runlayer
T7      one weight piece deleted from the list               glp,lmhead,stack,runlayer  glp,stack,runlayer         glp,lmhead,runlayer        glp,runlayer
T8      a piece cut 4 KB off the header's own 0x38 table     glp,lmhead,stack,runlayer  glp,stack,runlayer         glp,lmhead,runlayer        glp,runlayer
T9      a piece straddling the 4 GiB HBM STACK boundary      glp,lmhead,stack,runlayer  glp,stack,runlayer         glp,lmhead,runlayer        glp,runlayer
T10     object hbm_offset points at piece 5, not the header  glp,lmhead,stack,runlayer  glp,stack,runlayer         glp,lmhead,runlayer        glp,runlayer
T11     one piece's nbytes doubled                           glp,lmhead,stack,runlayer  glp,stack,runlayer         glp,lmhead,runlayer        glp,runlayer
T12     ALL 27 lanes of one tensor put into ONE pseudo-chan  glp,lmhead,runlayer        glp,runlayer               glp,lmhead,runlayer        glp,runlayer
```

**THE `OFF` AND `PRE` COLUMNS CARRY NO ATTRIBUTION AND ARE PRINTED TO SAY SO.**
In both, the CONTROL row dies: `OFF` because `gen_mv4i_desc.load_manifest()`
refuses a v2 manifest to `glp` and `lmhead` wholesale, `PRE` because
`hbm_map` at `263e0ee^` models a striped object as one contiguous range and
reports an OVERLAP. A column in which every row including the control fails
cannot tell an old property from a new one. This is exactly the trap PIECES
recorded for its own `FLAT` column, hit again from a different direction.

**The one column in `OFF` that DOES attribute is `stack`.** `check_hbm_stack`
never appears in any `OFF` or `PRE` cell, including the control, so its NEW
kills are attributable outright.

The verbatim `stack` verdicts, NEW against OFF:

```
T2   NEW  rc=1  blk.0.ffn_gate.weight.mv4i:w02: piece is not 4 KB aligned in HBM
T2   OFF  rc=0  PASS no range crosses a stack boundary
T6   NEW  rc=1  blk.0.ffn_gate.weight.mv4i:w03: piece 4 starts at file +3149824, the pieces before it end at +3145728
T6   OFF  rc=0  PASS no range crosses a stack boundary
T7   NEW  rc=1  the manifest cuts this file at [0, 4096, 1052672, 3149824, ...] (27 pieces); its own sub-region table cuts ...
T7   OFF  rc=0  PASS no range crosses a stack boundary
T8   NEW  rc=1  the manifest cuts this file at [0, 4096, 1052672, 2105344, ...] (28 pieces); its own sub-region table cuts ...
T8   OFF  rc=0  PASS no range crosses a stack boundary
T9   NEW  rc=1  blk.0.ffn_gate.weight.mv4i:w02: 4294443008 .. 4295491584 crosses 4294967296 (stack 0 -> 1); 524288 bytes on the wrong side
T9   OFF  rc=0  PASS no range crosses a stack boundary
T10  NEW  rc=1  blk.0.ffn_gate.weight.mv4i: hbm_offset is 1377050624 and the first piece is at 57344
T10  OFF  rc=0  PASS no range crosses a stack boundary
T11  NEW  rc=1  blk.0.ffn_gate.weight.mv4i:w03: piece 4 starts at file +3149824, the pieces before it end at +4198400
T11  OFF  rc=0  PASS no range crosses a stack boundary
T12  NEW  rc=0  PASS no range crosses a stack boundary
T12  OFF  rc=0  PASS no range crosses a stack boundary
T1   NEW  rc=0  PASS no range crosses a stack boundary
T1   OFF  rc=0  PASS no range crosses a stack boundary
```

### 4.5 Attribution inside `gen_lmhead_windows`, one arm per check

`NOMAP` = the `hbm_map.plan().check()` call removed. `NOEXT` = the per-extent
presence/size rule inside `check_byte_cover` removed. Target
`output.weight.mv4i`, i.e. the tensor this tool actually windows:

```
mutant  what it does                                         NEW     NOMAP   NOEXT   OFF
control the striped manifest, untouched                      -       -       -       KILL
T1      one weight piece moved a whole 256 MiB segment up    KILL    -       KILL    KILL
T2      one weight piece misaligned by 1 byte                KILL    KILL    KILL    KILL
T3      two pieces of one tensor given the SAME address      KILL    -       KILL    KILL
T4      a piece's segment LABEL changed, address untouched   KILL    -       KILL    KILL
T5      a piece moved INSIDE its own segment                 -       -       -       KILL
T6      one piece 4096 B short, the file no longer tiled     KILL    KILL    KILL    KILL
T7      one weight piece deleted from the list               KILL    KILL    KILL    KILL
T8      a piece cut 4 KB off the header's own 0x38 table     KILL    KILL    KILL    KILL
T9      a piece straddling the 4 GiB HBM STACK boundary      KILL    -       KILL    KILL
T10     object hbm_offset points at piece 5, not the header  KILL    -       KILL    KILL
T11     one piece's nbytes doubled                           KILL    KILL    KILL    KILL
T12     ALL 27 lanes of one tensor put into ONE pseudo-chan  KILL    -       KILL    KILL
```

Reading it:

| check | independent kills | verdict |
|---|---|---|
| `hbm_map.plan().check()` in `gen_lmhead_windows` | **T1, T3, T4, T9, T10, T12** (6) | **earns its place.** Without it the tool emits a clean 15-window set off a manifest with a piece a whole segment out of place, colliding with another lane, or across the 4 GiB stack line. `check_byte_cover` structurally cannot see any of them: the placement is on both sides of it and cancels, which is the same defect PIECES found in `make_plan`'s base half |
| the extent presence/size rule in `check_byte_cover` | **NONE** | **earns zero.** `NOEXT` kills identically to `NEW` on all 13 rows. It is kept, and labelled, for one reason: it is the only rule anywhere that compares a piece's SIZE against `h.sub_bytes()` derived from the .mv4i header, so its kill would not depend on how densely the packer filled the segment. By this project's definition it is **not load-bearing** and nobody should credit it with a detection. Deleting it is an available judgement and this table is the input to it |
| `pieces` threading in `gen_layer_program` | **NONE** | credited with none. `glp` dies in every arm for a different reason (`OFF` at the guard, `PRE` at the overlap, `NEW` at `place_desc_arena`'s map check). Its value is 8,397 of 8,397 bases made right, MEASURED in 4.2, not a detection |
| `pieces` threading in `fk33_run_layer` | **NONE** | credited with none, same reasoning: `runlayer`'s kills all belong to `hbm_map` through `place_desc_arena`, which was already in that path. Its value is 7,992 of 7,992 bases made right |
| the piece model in `check_hbm_stack` | **T2, T6, T7, T8, T9, T10, T11** (7) | **earns its place outright.** Zero of them are killed by the pre-change file, whose control survives |
| the delta arm of `verify_mv4i_desc --bytes` | **MUTG** (1) | earns its place, 4.6. No manifest mutation can reach it |

### 4.6 The one arm no manifest mutation can reach, and its teeth

The delta arm of `check_bytes` asserts that turning `pieces` on perturbs exactly
the `nsub_w + nsub_s` base words of the 39 and nothing else. Both sides are
Python, so it cannot say a base is RIGHT and is not credited with that. What it
can say is which words moved. Its mutant is a source mutant in a scratch tree
(`MUTG`: `wb += 1` on the `pieces` branch of `build_descriptor`):

```
--- MUTG, striped set ---
PASS 15 images byte-identical to the C builder
FAIL 15 striped images move base words only    delta arm: NOT a check of the base VALUES, only of which words move
VERIFY: FAIL

--- MUTG, FLAT set: the delta arm must be silent ---
PASS 15 images byte-identical to the C builder
VERIFY: PASS
```

The offending word is reported as `words [36]`, which is `w_beats`.

**A trap I introduced and then measured out.** The first version shared one `ok`
flag between the format arm and the delta arm, so the format arm's line read
`FAIL 15 images byte-identical to the C builder` when the C comparison had
actually passed. A checker that misreports WHICH check bit is worse than one
that does not check. Split into `fmt_ok` and `ndelta_bad`; the run above is the
fixed version.

**And the arm had never run at all.** `verify_mv4i_desc.py` hard-codes
`MODEL = /mnt/storage/llama-models/qwen35-9b-mv4i`, a v1 set, with no override.
A striped arm that no invocation can reach is worse than a check never shown to
fail. `MODEL` now honours a `MV4I_MODEL` environment variable; that is the whole
of the plumbing, and the flat default is unchanged (4.1, diff 8).

### 4.7 The whole-map check `fk33_run_layer` did NOT need

`fk33_run_job.make_plan` gained `hbm_map.plan(mani).check()` at `263e0ee`
because its 69-field cross-check cannot see a misplacement. `fk33_run_layer`
already has that verdict: `make_layer` calls
`gen_layer_program.place_desc_arena()`, which runs `HM.plan(...).check()` and
raises `SystemExit` on any fault. A second copy would earn zero kills. This is
recorded in the code comment beside the change so the next reader does not add
one.

### 4.8 The hardware boundary, as evidence

`strace -f -qq -e trace=openat,open` on six offline commands:

```
glp_flat:    lines=752    /dev/xdma opens=0  any /dev opens=0
glp_strp:    lines=750    /dev/xdma opens=0  any /dev opens=0
lmhead_strp: lines=127    /dev/xdma opens=0  any /dev opens=0
stack_strp:  lines=350    /dev/xdma opens=0  any /dev opens=0
runlayer:    lines=947    /dev/xdma opens=0  any /dev opens=0
teeth:       lines=47511  /dev/xdma opens=0  any /dev opens=0
--- proof the tracer was working: real opens seen ---
"/home/orencollaco/GitHub/llama.vhdl/rtl/model_cfg_pkg.vhd"
"/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/output.weight.mv4i"
```

### 4.9 Neighbouring gates, re-run unchanged

```
tools/hbm_map.py       flat     PASS  every region is aligned, in range, in one stack, and disjoint across all 3 allocators
tools/hbm_map.py       striped  PASS  (same line)
gen_mv4i_desc --selftest        SELFTEST PASS
fk33_load_weights selfcheck     PASS  every check was shown to fail on a defect it claims to catch
fk33_run_job selfcheck          runs clean
check_mv4i_set on striped       249 FAILURES -- the correct refusal, untouched
```

---

## 5. Coverage, stated -- how many were READ, not how many passed

| thing | flat set | striped set |
|---|---|---|
| manifest objects read | 250 | 250 |
| of which lane-striped | 0 | 249 |
| `gen_layer_program` A jobs emitted | 311 | 311 |
| `gen_layer_program` descriptor artefacts diffed | 313 files | -- |
| `gen_layer_program` sub-region bases READ | 8,397 | 8,397 |
| `fk33_run_layer` layers walked | 32 | 32 |
| `fk33_run_layer` descriptors / words / bases | 296 / 11,544 / 7,992 | 296 / 11,544 / 7,992 |
| `gen_lmhead_windows` windows / bases | 15 / 405 | 15 / 405 |
| `verify_mv4i_desc` images against the C | 39 | 39 |
| `verify_mv4i_desc` delta-arm images | 0 (none striped) | 39 |
| `check_hbm_stack` byte ranges | 7,154 | 7,154 |
| of which PIECE ranges | 0 | **6,972** |
| descriptor words byte-identical, flat | **24,258** | -- |
| teeth tool invocations | 13 x 4 x 4 x 2 = 416, plus 104 in the lmhead attribution table |

**What this coverage does NOT reach, enumerated separately.**

1. **No striped image has ever been resident on the card**, so nothing here is a
   statement about silicon. Inherited from PIECES and unchanged.
2. **The RTL has never judged a STRIPED descriptor.** `verify_mv4i_desc --rtl`,
   `--teeth` and `--gate` were NOT run: they need GHDL, MEASURED elsewhere at
   20.9 GiB anon-RSS in one process, and two synthesis lanes were held by other
   tracks. Acceptance of a striped image by `matvec_int4_desc_axi` is asserted
   only by `rtl_would_reject`, which is Python restating the RTL's S_CHECK.
3. **One mv4i geometry family on real data** (ROWS_IF=48 AXI_DW=256 GRP=1), so
   `w_stride == s_stride` on all 249. Inherited from PIECES.
4. **Every teeth mutant perturbs ONE object.** Nothing says the fault lists stay
   readable, or that two faults do not mask each other.
5. **`verify_mv4i_desc`'s default set is a DIFFERENT packed set** (`qwen35-9b-mv4i`,
   251 files) from the noembd pair every other measurement uses. The striped arm
   was reached only by pointing `MV4I_MODEL` at the noembd-striped set.
6. **Nothing here checks that a lane's pieces land in the segment that lane's
   engine MASTER is wired to.** That needs `ENG_PORT_MAP`; it is
   `pack_model_fk33.check_lane_stripe()` check 1 and it is the load-bearing one.
   Teeth row **T12** is the proof of the hole: 27 lanes collapsed back into one
   pseudo-channel is caught only incidentally, by `hbm_map` noticing the
   resulting overlap, and `check_hbm_stack` passes it outright.
7. **`fk33_run_token.py` was not run.** Its `make_tail` path is unfixed
   (section 8) and running it needs the card.

---

## 6. Measured and REJECTED -- do not retry

| approach | how it died | do not retry |
|---|---|---|
| **Add `hbm_map.plan().check()` to `fk33_run_layer.make_layer`, copying `fk33_run_job.make_plan` literally** | It is already there. `make_layer` calls `place_desc_arena()`, which runs it and raises `SystemExit`. MEASURED: `runlayer` is killed by T1..T12 in the OFF arm, i.e. before this track existed | Read what the call chain already does. Copy the SHAPE of a landed change, not its text |
| **Take a striped sub-region's address from `f["w_extent_base"]` in `check_byte_cover`** | `build_descriptor` wrote that field from the same manifest, so the check would agree with the descriptor it is checking. The m7-mutant shape | Join the FILE OFFSET from `G.check_bases(h)` to the manifest's `pieces`, which is what `sub_base` does and what the oracle in 4.2 does independently |
| **Teach `check_hbm_stack` by importing `hbm_map.file_pieces()`** | Its entire value is that it shares nothing with the allocator or with the other consumers. Importing the one producer would delete the independence and with it the only rule that opens the .mv4i | Parse `e["pieces"]` as DATA, then cross-check the cuts against the file's own 0x38 table -- a rule `hbm_map` structurally cannot state |
| **Trust `check_hbm_stack`'s range COUNT to show that something changed** | MEASURED: 7,154 on both layouts. DERIVED why: `250 + 249x27 = 6,973` and `249x28 + 1 = 6,973`. The count is identical while every sub-region range has been replaced | Print the composition (`N of M entries are LANE-STRIPED, contributing P piece ranges`), which is the line that actually discriminates |
| **Compare Python's striped image against `tools/mv4i_desc_ref.c`** | The C computes `hbm_base + sub_offset + skip`, the v1 flat rule. Feeding it a striped base would make the "independent encoder" check a comparison of one encoder against itself | Keep the format arm flat, and add a separate delta arm that only claims WHICH words moved. Say in the output that it is not a check of the values |
| **Share one `ok` flag between the format arm and the delta arm of `check_bytes`** | MEASURED: the format arm printed `FAIL 15 images byte-identical to the C builder` when the C comparison had passed. A checker that misreports which check bit | One verdict per arm |
| **Use the `OFF` arm (this track's files at HEAD) to attribute a kill inside `gen_lmhead_windows`** | Its CONTROL dies -- `load_manifest` refuses a v2 manifest wholesale -- so every row is a kill and nothing is distinguishable | One arm per check, with that check and only that check disabled (`NOMAP`, `NOEXT`) |
| **Use the `PRE` arm (before PIECES) as "what the old world did"** | Its control dies too, and for an unrelated reason: `hbm_map` at `263e0ee^` reports an OVERLAP on the striped manifest because it models a striped object as one contiguous range | Printed, labelled as carrying no attribution, and read for nothing else |
| **Assume PIECES' measurement that the striped program's bases were byte-identical to the flat one's** | MEASURED today: 0 of 296 descriptors identical, 7,992 of 7,992 bases different. The striped manifest changed under both documents | Re-measure against the artefact. This is the second track to be caught by this manifest moving |
| **`git commit` with no pathspec while five tracks run** | Recorded in CLAUDE.md; a track lost six documents to it on 2026-08-29 | Pathspec form, on exclusively-owned files, which is what section 11 used |

---

## 7. Measurement traps hit, including my own

1. **The brief's headline number does not reproduce, in BOTH halves.** PIECES
   recorded `gen_layer_program --token` emitting `311 of 311 A jobs, 0 refused`
   off the striped set with all 6,723 bases byte-identical to the flat
   program's. MEASURED today against the same manifest path: the pre-PIECES
   world (`PRE` arm) does not emit anything -- it dies in `place_desc_arena`
   with `OVERLAP: blk.9.ssm_out.weight.mv4i 0xf_8000..0xa0_b000 ... and
   nonmatvec_f32.bin ... share 4571136 bytes` -- and the bases are not
   identical either: on `fk33_run_layer`, 7,992 of 7,992 differ from the flat
   program's, because the striped manifest's `hbm_offset` values are themselves
   different from the flat set's. **The defect PIECES described is real and I
   measured it directly (4.3); the specific numbers are not reproducible and
   should not be quoted.** PACKSTRIPE rewrote this manifest between the two
   tracks, which PIECES itself recorded as its trap 3 and which caught me from
   the other direction.
2. **My first teeth table tested `gen_lmhead_windows` against a tensor it never
   reads.** The mutants targeted `blk.0.ffn_gate.weight` and lmhead windows
   `output.weight`, so every lmhead cell was measuring the whole-map check and
   none was measuring the per-tensor one. It looked like a clean attribution
   result. Fixed by running the whole table twice, once per target, and both
   are reported.
3. **`TARGET` was read into a default argument at import time**, so setting the
   environment variable after `import teeth_stripepath` silently did nothing
   and produced a table for the wrong tensor that looked plausible. The tell was
   a column of dashes where the earlier run had kills.
4. **`check_hbm_stack`'s count line is not a coverage line.** It reports
   `n_obj`, the number of `chk()` calls, which is identical on both layouts by
   coincidence (see section 6). I added a second line reporting the
   composition; the original line is kept because removing it would break
   anyone diffing runs.
5. **A `diff` against the OFF tree reported a difference that was mine, not the
   code's.** The OFF tree is symlinks plus five overridden files and had no
   `sim/` directory, so `--stamp seq_tbl` raised `FileNotFoundError` there and
   the diff read as a behaviour change. Adding the one symlink made both
   identical. An arm built from symlinks must be complete or its failures are
   the harness's.
6. **The delta arm of `check_bytes` had never executed** before I added the
   `MV4I_MODEL` override, and it would have gone on never executing while
   `VERIFY: PASS` was printed. A striped arm behind a hard-coded flat path is
   not a weak check, it is zero check.

---

## 8. Open, not yet answered

1. **`hw/fk33/host/fk33_run_token.py:1103` is the SIXTH consumer and has the
   identical defect.** Its `make_tail` does `mani = json.load(open(mani_path))`
   at line 313 and `j.hbm_offset = int(ent["hbm_offset"])` at line 380, then
   builds the lm-head's 15 window descriptors at 1103 with no `pieces`. It is
   out of reach of `load_manifest`'s guard for exactly the reason
   `fk33_run_layer` was. **NOT MINE, and it is on the token path.** The fix is
   the same two lines: `j.pieces = G.piece_extents(ent)` in `make_tail`, and
   `pieces=j.pieces` in the `build_descriptor` call. Until it lands, a striped
   set will produce a correct 32-layer body and a wrong lm-head.
2. **`tools/weights_residency.py` FAILS on the striped manifest**, for a reason
   unrelated to what it guards:
   `FAIL stack_hole_bytes: manifest 0, the gaps between consecutive placements
   sum to 2690994176`. The 2.69 GiB of gaps are the segment-granular lane arenas
   and are by design; the manifest's `stack_hole_bytes` was computed for the
   flat layout. Either the packer should update that field or the checker should
   learn the striped model. **A guard that fails for a reason unrelated to what
   it guards is a guard that will be muted**, so this needs an owner. Not mine.
3. **`pack_model_fk33.expand_pieces()` is still a second producer** of the
   extent model, as PIECES recorded. `hbm_map.file_pieces()` is the one it
   should call. Reported, not edited: PACKSTRIPE owns that file. Nothing in
   this change depends on which of the two survives, because a pre-expanded
   list has no `pieces` key and reads as flat.
4. **`tools/check_mv4i_set.py` still refuses a v2 manifest** with 249 failures.
   That is the correct behaviour for a tool that has not been taught, and it is
   untouched.
5. **T12 is the hole nothing in this change closes.** Twenty-seven lanes placed
   back into ONE pseudo-channel is a structurally valid layout that
   `check_hbm_stack` passes outright. It is precisely the defect the striping
   exists to remove, and only `pack_model_fk33.check_lane_stripe()` check 1
   -- which reads `ENG_PORT_MAP` -- can see it. A layout that has been striped
   at the wrong granule, or onto the wrong segments, looks right to every
   consumer this track touched.
6. **T5 does not bite and should not.** A piece moved to a different 4 KB
   aligned address inside the segment its own lane already owns is a legal
   placement. A rule that refused it would fail on a correct configuration.
   Same class as PACKSTRIPE's M8/M10 and PIECES' M5.
7. **The extent presence/size rule in `check_byte_cover` earns zero kills.**
   Kept and labelled (4.5). Deleting it is an available judgement.
8. **Nothing here says the striped image is faster.** Section 10 states the
   prediction and what would falsify it; it has not been run.

---

## 9. Commands

### 9.1 Offline arm -- no card, no `/dev`, safe for anyone

```bash
cd /home/orencollaco/GitHub/llama.vhdl
SD=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd
SDS=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped
FLAT=$SD/manifest.json
STRP=$SDS/manifest.json

# 1  the whole token program, both layouts.  BOTH must end "311 of 311 A jobs
#    emitted, 0 refused".  Before this change the striped one was refused.
python3 tools/gen_layer_program.py --manifest "$FLAT" --token --x-exp -6 --print | tail -1
python3 tools/gen_layer_program.py --manifest "$STRP" --token --x-exp -6 --print | tail -1

# 2  the lm-head window set, both layouts.  Both "WINDOW SET PASS".
python3 tools/gen_lmhead_windows.py --mv4i $SD/output.weight.mv4i  --manifest "$FLAT" --x-exp -6 | tail -6
python3 tools/gen_lmhead_windows.py --mv4i $SDS/output.weight.mv4i --manifest "$STRP" --x-exp -6 | tail -6

# 3  the stack checker.  Read the SECOND line, not the first: the range COUNT
#    is 7,154 on both layouts and always was.
python3 tools/check_hbm_stack.py $SD  | tail -3
python3 tools/check_hbm_stack.py $SDS | tail -3

# 4  the descriptor encoder against the C, plus the striped delta arm.
python3 tools/verify_mv4i_desc.py --cross --bytes --sweep 12 | tail -4
MV4I_MODEL=$SDS python3 tools/verify_mv4i_desc.py --cross --bytes --sweep 12 | tail -4

# 5  the inertness oracle and its discrimination control (copies beside this
#    document).  Needs the artefacts of step 1 in --outdir form:
python3 tools/gen_layer_program.py --manifest "$FLAT" --token --x-exp -6 --outdir /tmp/glpf >/dev/null
python3 tools/gen_layer_program.py --manifest "$STRP" --token --x-exp -6 --outdir /tmp/glps >/dev/null
python3 docs/debugging/2026-08-30_stripepath-oracle.py /tmp/glpf /tmp/glps "$FLAT" "$STRP" $SD $SDS

# 6  the teeth, both target tensors.  22 kill rows; the control must SURVIVE
#    under NEW and NOMAP.
python3 docs/debugging/2026-08-30_stripepath-teeth.py
SP_TARGET=output.weight.mv4i python3 docs/debugging/2026-08-30_stripepath-teeth.py

# 7  the neighbours, unchanged
python3 tools/hbm_map.py "$STRP" --markdown | tail -1
python3 hw/fk33/host/fk33_load_weights.py selfcheck | tail -1
python3 tools/gen_mv4i_desc.py --selftest | tail -1

# 8  the hardware boundary, re-proved
strace -f -qq -e trace=openat,open -o /tmp/sp.strace \
  python3 tools/gen_layer_program.py --manifest "$STRP" --token --x-exp -6 --print >/dev/null 2>&1
grep -c '"/dev/' /tmp/sp.strace          # must be 0
```

The teeth harness writes only into `/mnt/storage/track-stripepath/mut/`, which
is a directory of symlinks to the striped model plus one `manifest.json` it
writes and removes. It never writes into the model directory.

### 9.2 Card arm -- OREN ONLY. NO AGENT RUNS THIS.

**Card state as of `d31ab02` (08:30 today): the FPGA IS configured**
(`fk33_pcieep_eng.bit`, three JTAG2AXI masters, wiper 64, VCCINT 0.7216 V) but
**PCIe is NOT enumerated** and needs one root rescan. That is the only blocking
step and it is not something this account can do.

**No new bitstream is required for this experiment.** The striping change is
entirely in the packer, the manifest and the host descriptors; the gateware
reads whatever base the descriptor gives it. `ENG_PORT_MAP` -- which engine
master sits on which SAXI port -- IS in the bitstream and is unchanged.

**HAZARD.** Writing the striped image puts bytes into segments 1..26, which
under the FLAT layout hold other tensors. After this the card holds a mixture
unless a flat image is reloaded.

```bash
cd /home/orencollaco/GitHub/llama.vhdl
SDS=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped
STRP=$SDS/manifest.json

# 0  the rescan, as root, then confirm.  Not runnable from this account.
#    (see docs/debugging/2026-08-30_restoring-the-card-after-a-power-cycle.md)
python3 hw/fk33/host/fk33ctl.py id
python3 hw/fk33/host/fk33ctl.py vccint      # wiper 68, ~0.717 V.  NEVER 0.85 V.

# 1  load the striped set with the read-back.  This is PIECES' section 9.2 and
#    is unchanged by this track.  Expect "extents 6973 of 6973 digested".
python3 hw/fk33/host/fk33_load_weights.py load "$STRP" --verify

# 2  THE MEASUREMENT.  Same four jobs as the counters document, so the
#    before/after is a comparison and not a new number.
python3 hw/fk33/host/fk33_run_job.py run --mv4i $SDS/blk.0.ffn_gate.weight.mv4i \
        --manifest "$STRP" --rows 100 --x-exp -6 --slot 0
python3 hw/fk33/host/fk33_run_job.py run --mv4i $SDS/blk.11.attn_k.weight.mv4i \
        --manifest "$STRP" --rows 64  --x-exp -6 --slot 0
python3 hw/fk33/host/fk33_run_job.py run --mv4i $SDS/blk.20.ffn_down.weight.mv4i \
        --manifest "$STRP" --rows 64  --x-exp -6 --slot 0

# 3  one layer, bit-exact against the reference.  DO NOT SKIP: this is the
#    check that the relocated bases point at the right BYTES, which no offline
#    measurement here can make.
python3 hw/fk33/host/fk33_run_layer.py run --manifest "$STRP" --layer 0

# 4  a whole token.  EXPECT THE LM-HEAD TO BE WRONG until open item 1 lands:
#    fk33_run_token.py's tail is still flat.  If the 32-layer body is bit-exact
#    and only the logits differ, that is item 1 and not a striping fault.
```

### 9.3 Failure modes

| what you see | reading |
|---|---|
| `311 of 311 A jobs emitted, 0 refused` on the STRIPED manifest | correct now, and it was correct-looking and wrong before. Check the base of job 0 against the oracle in 9.1 step 5 before believing it |
| `checked 7154 byte ranges ... PASS` with NO `format ... LANE-STRIPED` line beneath it | an old `check_hbm_stack.py`. The count is the same on both layouts; the composition line is the one that discriminates |
| `... :w02: N .. M crosses 4294967296 (stack 0 -> 1)` | a lane arena straddles the two HBM stacks. An AXI master reading across does not fault; it returns plausible wrong bytes. Stop and re-pack |
| `the manifest cuts this file at [...] (28 pieces); its own sub-region table cuts it at [...]` | the packer cut the file somewhere other than the header's 0x38 table. `hbm_map` cannot see this: it never opens the .mv4i. Do not adjust `check_bases` |
| `REFUSING to emit windows -- tools/hbm_map.py finds N placement fault(s)` from `gen_lmhead_windows` | the map does not hold together. `check_byte_cover` would still have said PASS; this is the check that can see it |
| `weight sub-region P is at file +N and the manifest places no piece there` | `sub_base`'s refusal. The manifest and the file disagree about what a sub-region IS |
| `stack_hole_bytes: manifest 0, the gaps ... sum to 2690994176` from `weights_residency` | expected on a striped set today, and it is open item 2. The gaps are the segment-granular arenas |
| the 32-layer body bit-exact and the LOGITS wrong | open item 1: `fk33_run_token.py`'s tail is still flat. Not a striping fault |
| `21.6` cycles/beat still, after loading the striped set | either the image on the card is not the striped one, or the descriptors are not the striped ones. Check `fk33_load_weights verify` first, then one descriptor's `w_base[0]` against the manifest |

---

## 10. The prediction, stated in advance so it can fail

**DERIVED, from `docs/debugging/2026-08-30_counters-cycles-beats-starved.md`
section 4.2.** One core weight word is 27 AXI beats of 32 B (24 weight + 3
scale). Under the flat layout all 27 land in ONE pseudo-channel, which retires
one beat per 250 MHz ACLK cycle:

```
27 beats / 250 MHz = 108.0 ns = 21.60 core cycles at 200 MHz
MEASURED least-squares slope over four card jobs: 21.67 cycles/beat
```

Under the striped layout PACKSTRIPE places at most **2 lanes per
pseudo-channel** (MEASURED: 27 lanes onto 25 segments; the discrimination
control in 4.2 reads 25 distinct segments out of address bits [32:28]). The
busiest pseudo-channel then retires 2 beats per core word:

```
2 beats / 250 MHz = 8.0 ns = 1.60 core cycles at 200 MHz
```

which is **exactly the 1.60 cycles/beat the shipping RTL reaches against an
ideal memory** in that document's section 5.

**PREDICTION: the A-job cycles/beat falls from 21.67 to between 1.60 and 3.0,
a 7x to 13.5x speedup, and the bound stops being the memory.** At the low end
the datapath itself becomes the limit and further striping buys nothing.

**What falsifies it:**

- **A measured 10 to 12 cycles/beat** means roughly half the lanes still share a
  channel. Look at `ENG_PORT_MAP` against the segments the packer chose --
  `pack_model_fk33.check_lane_stripe()` check 1 -- not at the host descriptors,
  which this track has already measured correct.
- **A measured ~21.6, unchanged**, means the striped image is not resident or
  the descriptors are not the striped ones. It is NOT evidence about the
  pseudo-channel theory.
- **A measured value well below 1.60** falsifies the counters document's
  ideal-memory floor, not this prediction.
- **A number between 3 and 8** means the 2-lanes-per-channel figure is wrong for
  the tensors measured; the striping is per-tensor and a specific tensor may
  have got a worse assignment.

**ESTIMATE, and the assumption is load-bearing:** the above assumes the HBM
global switch adds no per-access penalty when a master reaches a
pseudo-channel it is not directly wired to. The counters document records that
for two of its four jobs **not one of the 27 masters had the direct path**, and
the measured 21.67 still matched the direct-path derivation to 0.32%, which is
the evidence that the lateral crossing is free at this rate. **What would
falsify it:** a striped result that lands near 1.60 for tensors whose lanes
happen to sit on their own ports and materially worse for tensors whose lanes
do not.

---

## 11. Corrections to the brief, and the landing

- **"the same two lines `fk33_run_job.py` got"** -- `fk33_run_job` got THREE
  things: `allow_striped=True`, `pieces=G.piece_extents(entry)`, and
  `hbm_map.plan(mani).check()`. Only the first two apply to `fk33_run_layer`;
  the third is already in its path via `place_desc_arena` (4.7).
- **"`pieces=G.piece_extents(ent)` at ~line 704 plus `allow_striped=True` at its
  two `load_manifest` sites"** -- correct, and at `3a2d0d0` the line numbers are
  703/639/811. Both `load_manifest` sites were changed; the second
  (`check_against_manifest`) reads only `M`, `M_logical` and `K` and no address
  at all, so the flag there is a statement rather than a fix.
- **"`gen_lmhead_windows.py` and `verify_mv4i_desc.py` ... same one-line fix
  each"** -- neither was one line. `gen_lmhead_windows` threads `pieces` through
  `build_set`, `run_mutations`, `run_plan`, `run_checks`, `report` and
  `check_byte_cover`, because `check_byte_cover` computes where a sub-region
  starts and would otherwise raise a false alarm on a correct striped set.
  `verify_mv4i_desc` needed the `MV4I_MODEL` override before its striped path
  could be reached at all.
- **"they refuse cleanly today"** -- `verify_mv4i_desc` does not, in practice:
  its `MODEL` is hard-coded to a v1 set, so it never saw a v2 manifest to
  refuse.
- **The brief's count of consumers.** There are at least **seven**, not five:
  `fk33_run_token.py` and `weights_residency.py` are open items 1 and 2.
  `tools/lmhead_window_check.py` also calls `build_descriptor` but with
  `hbm_base=0` and no manifest, so it is unaffected -- checked, and named here
  so nobody re-checks it.
- **PIECES' measured numbers for the silent wrong program** do not reproduce
  against today's manifest. Section 7, trap 1. The defect is real and is
  measured directly in 4.3.

**Landed at:** see the commit that carries this file. Files changed:
`hw/fk33/host/fk33_run_layer.py`, `tools/gen_layer_program.py`,
`tools/gen_lmhead_windows.py`, `tools/verify_mv4i_desc.py`,
`tools/check_hbm_stack.py`, plus this document and the three harnesses beside
it.
