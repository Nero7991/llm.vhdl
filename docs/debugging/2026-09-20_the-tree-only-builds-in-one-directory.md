# The tree only builds in one directory

**Date:** 2026-09-20
**Track:** PATHFREE
**Build under test:** working tree at `747d502` (branch `fpga`), no Vivado lane
available (workstation held by a `FK33_CARD=1` place-and-route at PID 3794716,
BC-250 held by TRACK LEVERCOST). No hardware touched.

---

## 1. The question, verbatim

> Enumerate every TRACKED file whose CONTENT contains
> `/home/orencollaco/GitHub/llama.vhdl`, split it into load-bearing code that a
> tool executes and documentation that is a historical record, and cure the
> first set so that the gate can be run from any checkout and the planned
> `llama.vhdl` -> `llm.vhdl` rename is nearly free.

The symptom that started it, MEASURED the same day by TRACK GATEDAY
(`3062aa4`, `747d502`): a full gate run from a `git worktree` pinned at
`e573f5d` reported `PASS 155 FAIL 3`, and two of the three reds
(`sim:runguard`, `sim:fk33card`) passed in `/home/orencollaco/GitHub/llama.vhdl`
and failed everywhere else.

---

## 2. The answer, up front

**199 tracked files contain the string. 36 are load-bearing; 163 are documents
and `results/` logs and were left alone.** Of the 36, **30 now derive the root
from the running script's own location** and **6 keep a literal deliberately**,
each for a stated reason.

The two path-dependent gate reds had **two different causes, and only one of
them was a path that should have been derived**:

- **`sim:runguard`** was a *matching* defect. `hw/fk33/gen_pcieep.py` built its
  substitution target from **its own** `__file__` and searched for it inside the
  **tracked** `build_fk33_i2cprobe.tcl`, which carried the workstation's path.
  Off-path the target was absent and `--selftest` aborted. Both ends now name
  the same literal text, `$tgRoot/hw/fk33/fk33_i2cprobe.xdc`.
- **`sim:fk33card`** was a *comparison* defect, not a path defect at all. The
  two hex-image generics **must** stay absolute -- `file_open` resolves them
  from Vivado's cwd at elaboration -- and the generator already computed them
  correctly, from its own location. What was wrong was `--check`, which asked
  "was this file generated in THIS directory". It now compares modulo the repo
  prefix of those two paths and **prints the prefix it saw**.

**The load-bearing finding, and the one that would have broken the card build:**
`$tgRoot` **cannot** be a bare `[file dirname [info script]]` derivation.
`hw/fk33/pcieep_build.sh:69` does `cp build_fk33_pcieep.tcl "$BUILD_ROOT/"` and
sources the **copy**, so during a card build the script's own location is
`/mnt/storage/fk33_builds/build10/root` and a location-derived root resolves to
`/mnt/storage/fk33_builds`. The obvious fix would have aborted the build that
produces the shipping bitstream.

---

## 3. The procedure, in the order it was run

Each step and what it isolates.

1. **Enumerate, then split.** `git grep -l` for the literal, then partition on
   `docs/`, `*/results/`, `build_artifacts_*`, `CLAUDE.md`. This separates
   *things a tool executes* from *things that record what a tool did*. The
   second set is deliberately not touched: rewriting 163 historical documents
   to claim a path that was not what ran would falsify the record.
2. **Capture the BEFORE state off-path, before changing anything.** A worktree
   at `747d502` and the ten candidate selfcheck commands run directly. This
   establishes which rows are genuinely path-dependent rather than assuming
   GATEDAY's two are the only ones.
3. **Control each generator before editing it.** For every generated output,
   run the generator first and confirm `git diff` is empty. This isolates *my*
   change from staleness that was already there. It fired twice (section 5).
4. **Read the consumer, not only the producer.** Before choosing `[info
   script]`, grep for how each script is actually launched. This is what found
   the `cp ... "$BUILD_ROOT/"` in `pcieep_build.sh`.
5. **Exercise the root derivation standalone under `tclsh`**, in six scenarios
   including two that must fail. `tclsh` can run the root block even though it
   cannot run the Vivado commands around it, so the arithmetic is testable
   without a Vivado lane.
6. **Check the insertion boundary, not only that the file parses.** For the
   bulk Tcl rewrite, `info complete` on the text *up to* the insertion point
   proves the block landed at top level. `info complete` on the *whole* file
   does not: a block inserted into the middle of a construct still balances.
   This fired (section 5).
7. **Teeth-test the loosened check.** Four mutations against the new
   `fk33card` comparison: one that must pass, three that must still bite.
8. **Prove it in a worktree pinned to the commit**, ten rows, side by side with
   the same ten in the main checkout.

---

## 4. The evidence

### 4.1 The two counts

```
TOTAL tracked files containing /home/orencollaco/GitHub/llama.vhdl : 199
  (b) docs/ + */results/ + build_artifacts_* + CLAUDE.md, untouched : 163
  (a) load-bearing code                                            :  36
```

The brief's prior count was 31; the true figure is 36. The five extra are
`hw/fk33/rtl/fk33_card.vhd` (a generated `.vhd`, not a `.tcl`),
`hw/fk33/gen_hbmbw.py`, `hw/fk33/host/fk33_bisect_layers.sh`, and two
`sim/ooc_*.tcl` with more than one occurrence.

### 4.2 The before state, off-path (step 2)

Ten selfchecks run from `/mnt/storage/.../wt_before`, a worktree at `747d502`:

```
runguard   rc=1   Refusing to emit a PCIe build whose width, IDs, CLKREQ polarity or smartconnect fan-out may be wrong.
ipsync     rc=1   IPSYNC: FAIL -- ip_repo/ is not the bytes of rtl/. Re-run the packagers (they need Vivado); do NOT hand-edit the copies.
descrule   rc=0   SELFTEST PASS
cardtop    rc=0   GEN_CARDTOP_CHECK: OK
bdports    rc=0   BD_PORTS PASS: 8 block-design module cells, 2163 ports, ...
gdnstale   rc=0   GDNADAPT_CHECK ok (1 outputs)
shapechk   rc=0   SHAPE_OK 13 literals agree with model_cfg_pkg ...
fk33card   rc=1   FK33_CARD_CHECK: OK fk33_bc_grant.vhd (11984 bytes)
kvmap      rc=0   check_kv_map: 40 rows, 0 refused, 0 not run
seamregs   rc=0   check_seam_regs: 62 rows, 0 refused (rtl=41 host_offsets=54)
```

Exactly GATEDAY's two, plus the genuine `ipsync`. The other seven rows were
already path-independent, which is worth recording: **the path problem was
narrow, and the reason to fix all 36 files is the rename, not the gate.**

The two failures, verbatim, off-path and then in the main checkout:

```
=== WT runguard ===
ABORT: the probe build script no longer contains:
add_files -fileset constrs_1 -norecurse /mnt/storage/fk33_builds/scratch/pathfree/wt_before/hw/fk33/fk33_i2cprobe.xdc
Refusing to emit a PCIe build whose width, IDs, CLKREQ polarity or smartconnect fan-out may be wrong.
=== WT fk33card ===
FK33_CARD_CHECK: STALE /mnt/storage/.../wt_before/hw/fk33/rtl/fk33_card.vhd -- rtl/fk33_llama_top.vhd or the configuration changed and this file was not regenerated.
=== MAIN runguard ===
SELFTEST PASS
=== MAIN fk33card ===
FK33_CARD_CHECK: OK fk33_card.vhd (19561 bytes)
```

Note what the `runguard` abort actually prints: **the worktree's own path**.
The generator was looking for a string it had built from its own location,
which is why the message reads as though the tracked file were wrong.

### 4.3 The mechanism chosen per family

| family | files | mechanism |
|---|---|---|
| `sim/ooc_*.tcl` | 21 | `set pfRoot [file normalize [file join [file dirname [info script]] ..]]`, probed against `rtl/util_pkg.vhd` |
| `hw/*.tcl` packagers | 2 | same, `..` |
| `ip_repo/package_llama_ip.tcl` | 1 | same, `..`; `set llama $pfRoot` keeps the file's own variable |
| `hw/fk33/ooc_*.tcl` | 2 | same, `.. ..` |
| shell scripts | 4 | `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)`; `run_volt_verdicts.sh` keeps its `$REPO` override and changes only the default |
| `gen_i2cprobe.py`, `gen_pcieep.py` | 2 | emit `$tgRoot` (three-candidate, below) instead of a literal |
| `gen_hbmbw.py` | 1 | emits a derived `set tgRoot` instead of a literal |
| `gen_fk33_card.py` | 1 | output stays absolute (required); `--check` compares modulo the prefix |

### 4.4 Why `$tgRoot` has three candidates

`hw/fk33/pcieep_build.sh`:

```
32:python3 gen_pcieep.py
69:cp build_fk33_pcieep.tcl "$BUILD_ROOT/"
73:cd "$BUILD_ROOT"
76:        -source build_fk33_pcieep.tcl
```

and the running card build confirms where that is, read from the kernel rather
than from a command line:

```
PID 3690648 cwd=/mnt/storage/fk33_builds/build10/root
PID 3794716 cwd=/mnt/storage/fk33_builds/build10/root/fk33_pcieep/fk33_pcieep.runs/impl_1 rss=14475612
```

So the emitted block tries, in order: `$::env(FK33_TGROOT)`, the script's own
location, then the generation-time literal -- and accepts a candidate only if
`rtl/util_pkg.vhd` exists under it.

Six scenarios under `tclsh`, each run against the block extracted verbatim from
the generated `build_fk33_i2cprobe.tcl`:

```
=== S1: sourced IN PLACE from the main checkout ===
FK33_TGROOT /home/orencollaco/GitHub/llama.vhdl
=== S2: COPIED out of the tree, the pcieep_build.sh case ===
FK33_TGROOT /home/orencollaco/GitHub/llama.vhdl
=== S3: OFF-PATH WORKTREE in place (must NOT pick the literal) ===
FK33_TGROOT /mnt/storage/fk33_builds/scratch/pathfree/wt_before
=== S4: FK33_TGROOT override wins over both ===
FK33_TGROOT /mnt/storage/fk33_builds/scratch/pathfree/wt_before
=== S5: TEETH -- bogus override, copied out of tree, literal renamed away ===
tgRoot: no candidate repo root contains rtl/util_pkg.vhd. ...
=== S6: TEETH -- the off-by-one literal that the probe rejected ===
tgRoot: no candidate repo root contains rtl/util_pkg.vhd. ...
```

S3 is the one that matters for ordering: the literal is also valid there (the
main checkout still exists), so a wrong order would silently have produced the
main checkout's path from inside a worktree.

### 4.5 The `fk33card` comparison, and what it gives up

The generic must stay absolute. `gen_fk33_card.py`'s own header says why, and
it predates this track:

> An ABSOLUTE path derived from this script's own location, because
> `NORM_W_IMAGE` is opened by file_open at elaboration from wherever Vivado's
> cwd happens to be.

So `--check` now canonicalises `"<anything>/hw/fk33/gen/<name>.hex"` to
`"@REPO@/hw/fk33/gen/<name>.hex"` on both sides. Four mutations:

```
=== M1: repo prefix only differs (the worktree case) -- expect OK ===
FK33_CARD_CHECK: OK fk33_card.vhd (19561 bytes, image repo prefix: /some/other/checkout/llm.vhdl)
=== M2: TEETH -- hex FILENAME changed -- expect STALE ===
FK33_CARD_CHECK: STALE ...
=== M3: TEETH -- subdirectory under the repo changed -- expect STALE ===
FK33_CARD_CHECK: STALE ...
=== M4: TEETH -- an ordinary non-path byte changed -- expect STALE ===
FK33_CARD_CHECK: STALE ...
=== CONTROL: restored -- expect OK ===
FK33_CARD_CHECK: OK fk33_card.vhd (19561 bytes, image repo prefix: /home/orencollaco/GitHub/llama.vhdl)
```

**The resolution that was given up, stated plainly:** a committed file whose
images sit under a *different* repo at the same relative path now compares
equal. That is why M1's output prints `/some/other/checkout/llm.vhdl` rather
than absorbing it. After the rename, that printed prefix is how a reader sees
that the committed file still names the old directory.

### 4.6 The worktree-versus-main gate comparison

Ten rows, run through `sim/regress.sh --only <row> --jobs 1`, both trees at
commit `3219cb0`. The worktree is `/mnt/storage/fk33_builds/scratch/pathfree/wt_after`.

| row | main checkout | worktree (off-path) | verdict |
|---|---|---|---|
| `sim:runguard` | PASS 1 FAIL 0 | PASS 1 FAIL 0 | **cured** (was ABORT off-path) |
| `sim:fk33card` | PASS 1 FAIL 0 | PASS 1 FAIL 0 | **cured** (was STALE off-path) |
| `sim:cardtop`  | PASS 3 FAIL 0 | PASS 3 FAIL 0 | was already path-independent |
| `sim:gdnstale` | PASS 1 FAIL 0 | PASS 1 FAIL 0 | was already path-independent |
| `sim:kvmap`    | PASS 1 FAIL 0 | PASS 1 FAIL 0 | was already path-independent |
| `sim:seamregs` | PASS 1 FAIL 0 | PASS 1 FAIL 0 | was already path-independent |
| `sim:bdports`  | PASS 1 FAIL 0 | PASS 1 FAIL 0 | was already path-independent |
| `sim:descrule` | PASS 1 FAIL 0 | PASS 1 FAIL 0 | was already path-independent |
| `sim:shapechk` | PASS 1 FAIL 0 | PASS 1 FAIL 0 | was already path-independent |
| `sim:ipsync`   | PASS 0 FAIL 1 | PASS 0 FAIL 1 | **real defect, not the path** -- section 8 |

`sim:ipsync` fails **identically in both**, which is the point: it is the one
row whose redness is a fact about the tree rather than about the directory.

**THE ATTRIBUTION CONTROL.** Nine green rows off-path is not by itself evidence
that the generator changes caused it -- something else about the worktree could
have. So the two **pre-fix** generators from `747d502` were dropped into the
**same** worktree at the **same** commit and run there:

```
-- OLD gen_fk33_card.py against the NEW tree, off-path:
FK33_CARD_CHECK: STALE /mnt/storage/.../wt_after/hw/fk33/rtl/fk33_card.vhd -- ...
-- OLD gen_pcieep.py against the NEW tree, off-path:
ABORT: the probe build script no longer contains:
add_files -fileset constrs_1 -norecurse /mnt/storage/.../wt_after/hw/fk33/fk33_i2cprobe.xdc
```

Both still fail. One variable, the generators, and it moves the verdict.

**AND THE `fk33card` ROW PASSES FOR THE RIGHT REASON, WHICH IS VISIBLE.** In the
worktree the row prints:

```
FK33_CARD_CHECK: OK fk33_card.vhd (19591 bytes, image repo prefix: /home/orencollaco/GitHub/llama.vhdl)
```

against the main checkout's

```
FK33_CARD_CHECK: OK fk33_card.vhd (19561 bytes, image repo prefix: /home/orencollaco/GitHub/llama.vhdl)
```

Two things to read here. The prefix is the **committed file's**, which off-path
is *not* the tree being checked -- reported rather than absorbed, exactly as
designed. And the byte counts differ by **30**, because the figure is the length
of the **regenerated** text, whose two image paths embed the worktree's longer
path: 2 x 15 characters. **Do not read a differing byte count on this line as
staleness**; it tracks the length of the checkout's own path.


---

## 5. Measured and REJECTED -- do not retry

**These are the things that were tried, measured, and abandoned. Each cost real
time and each looks reasonable at the moment you type it.**

### 5.1 `set tgRoot [file normalize [file join [file dirname [info script]] .. ..]]` alone -- REJECTED

The obvious fix, and it is **wrong for the build that makes the shipping
bitstream**. `pcieep_build.sh:69` copies `build_fk33_pcieep.tcl` to
`$BUILD_ROOT` and sources it there, so `[info script]` names
`/mnt/storage/fk33_builds/build10/root` and the derived root is
`/mnt/storage/fk33_builds`. It was caught by reading the consumer, not by any
test -- **no bench can see it, and the failure would have been an abort seconds
into a three-hour build.** Do not simplify the three-candidate block back to
this.

### 5.2 Rewriting the 127 absolute paths in `build_fk33_pcieep.tcl` -- REJECTED

Two independent reasons, either sufficient:

- **The file is already generated from derived paths.** Every one of the 127
  comes from `os.path.join(HERE, ...)` in `gen_pcieep.py`, and
  `pcieep_build.sh:32` runs `python3 gen_pcieep.py` on **every** build. After
  the rename they regenerate correctly with no manual step. **There is nothing
  to cure.**
- **60+ of them are inside `[get_files {...}]`.** Tcl braces suppress variable
  substitution, so `$tgRoot` inside them would stay a literal dollar sign,
  `get_files` would match nothing, and `set_property` would fail on an empty
  object list. Converting them means changing brace quoting on 60 lines with
  **no Vivado lane to test it.**

### 5.3 Regenerating `build_fk33_pcieep.tcl` at all -- REJECTED, and it fired

`python3 hw/fk33/gen_pcieep.py` with no environment produced **496 deletions**:
`CAPS_VOCAB 248320` became `CAPS_VOCAB 0`, and the whole `card`/`bcgrant`
section vanished. The committed file was generated with `FK33_CARD=1`.

Re-running with `FK33_CARD=1` was **still not clean** -- two more deltas:

```
-set_property -dict [list CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {75.000}] ...
+set_property -dict [list CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000}] ...
```

and the entire `FK33_CB_STYLE` lever block (`ENG_CB_STYLE =
os.environ.get("FK33_CB_STYLE", "regs")`, `gen_pcieep.py:517`) disappeared.

**The committed tcl is the artifact of an environment combination that is not
recorded anywhere in the file.** It was reverted both times and is left
untouched. This is CLAUDE.md's "enumerate what differs from the runs' own
recorded parameters, never from the intent of whoever launched them" in a new
place: here the run's parameters are **not** recorded, so the only safe action
is not to regenerate.

### 5.4 Regenerating `build_fk33_hbmbw.tcl` -- REJECTED, and it fired too

The control run before editing produced **287 deletions** against the committed
file. It is already stale against its own generator, for reasons that predate
this track and were not investigated. The generator's emitted literal was fixed
(so a future regeneration is path-free); **the output was restored byte for byte
and left as it was.** Fixing that staleness is someone else's track.

### 5.5 Inserting the root block at the first line that mentions the path -- REJECTED

The bulk rewrite placed each `set pfRoot` block immediately before the first
occurrence. For 24 of 26 files that is top level. For two it was not:

- `sim/ooc_gdn_conv_shapes.tcl` -- inside a `foreach` body.
- `sim/ooc_mover_paths.tcl` -- **in the middle of a line-continued `expr`**,
  splitting `set rtldir [expr {... ? ... \` from its continuation
  `: "$pfRoot/rtl"}]`. The backslash then continued into a comment line.

**Both files still returned `info complete` = 1 for the whole file**, because
the braces still balanced. Only `info complete` on the text *up to* the
insertion point distinguished them (`top_level=0`). Both were reverted and
re-placed against a known top-level anchor.

### 5.6 Rewriting the 163 documents and `results/` logs -- NOT DONE, deliberately

They record what ran, at a path that was real at the time. CLAUDE.md is
explicit that corrections are appended and never applied by editing history.
Two of the six remaining literals in load-bearing files are in the same
category -- `sim/regress.sh:447` and `hw/fk33/gen_i2cprobe.py:58` are
**comments describing the defect**, and they are correct as written.

---

## 6. Measurement traps hit

1. **`grep -E '^OVERALL'` found nothing.** `regress.sh` prints `` OVERALL`` with
   a leading space. The loop printed empty verdicts for two rows before the
   anchor was corrected, which reads exactly like a row that produced no
   verdict. Anchoring on `^` is right; anchoring on the wrong column is not.
2. **A generator that "succeeded" changed the configuration.** `gen_pcieep.py`
   exited 0 and printed `wrote ...` while emitting a completely different
   design. A clean exit from a generator says nothing about which variant it
   emitted.
3. **`info complete` on a whole file is not a boundary check.** See 5.5. The
   corrupted file parsed.
4. **My own off-by-one, caught by the probe rather than by me.** The first
   `REPO` in `gen_i2cprobe.py` was `os.path.join(HERE, "..")`, one level short,
   and emitted `"/home/orencollaco/GitHub/llama.vhdl/hw"` as the fallback. The
   `rtl/util_pkg.vhd` probe rejected it. **This is the argument for probing a
   derived root rather than trusting it**: the guard caught its author.
5. **`ps`/`pgrep` were not used to find the running Vivado.** Per CLAUDE.md the
   census read `/proc/PID/exe` and `/proc/PID/cwd`, which is also what produced
   the `$BUILD_ROOT` evidence in 4.4 as a *fact about the running build* rather
   than an inference from the script.
6. **Three other tracks had in-flight edits in the same tree** (`rtl/attn_block.vhd`,
   `sim/tb_csweep_rate.vhd`, `sim/tb_attn_block.vhd`, `sim/tb_attn_kv_seam.vhd`,
   `hw/design_mv_generated.tcl`). The commit used the pathspec form with 36
   explicit paths and never went through the index.

---

## 7. Open, not determined

- **No Vivado has executed any changed Tcl.** The root derivation is proven
  under `tclsh` in six scenarios, and the surrounding Vivado commands are
  unchanged, but `add_files -fileset constrs_1 -norecurse $tgRoot/...` has not
  been run by the tool. **The next `hw/fk33/pcieep_build.sh` is the first
  execution.** It fails loudly and within seconds if it fails at all.
- **The 23 `sim/ooc_*.tcl` and the three packagers have not been run either**,
  for the same reason. Each carries a probe that aborts with a clear message.
- **Why `build_fk33_hbmbw.tcl` is 287 lines stale** was not investigated.
- **Which environment produced the committed `build_fk33_pcieep.tcl`** is not
  recorded and was not reconstructed beyond `FK33_CARD=1` plus `FK33_CB_STYLE`
  plus something setting CLKOUT3 to 75 MHz.
- **`sim:ipsync`** is unchanged and still red. See section 8.
- **The clean `BASELINE_PASS` floor has not been measured**, only made
  measurable. See section 9.

---

## 8. `sim:ipsync` hand-off

Not this track's to fix; it needs Vivado. GATEDAY's bisection **re-confirmed
today**, by hashing both sides at each commit:

```
=== sizes now ===
20045 ip_repo/llama_engine_axi_1_0/src/llama_engine_axi.vhd
20328 rtl/llama_engine_axi.vhd
cb2600f  ip=0a448eba rtl=0a448eba  IDENTICAL
09f68a0  ip=0a448eba rtl=1e69a9fd  DIFFERS
HEAD     ip=0a448eba rtl=1e69a9fd  DIFFERS
```

The `ip_repo/` copy has **not moved since `cb2600f`** (same digest at `cb2600f`
and at HEAD); `rtl/` moved once, at `09f68a0` ("GHDL 6.0 portability",
2026-09-19), which added a `prompt_len_i` signal and rewired one port map:

```
-             prompt_mant => prompt_reg, prompt_len => prompt_len_reg,
+             prompt_mant => prompt_reg, prompt_len => prompt_len_i,
+  prompt_len_i <= prompt_len_reg;
```

**What the next owner must run**, on a free Vivado lane, from a checkout of the
tree:

```
vivado -mode batch -nojournal -source ip_repo/package_llama_ip.tcl
python3 ip_repo/check_ip_sync.py      # must print IPSYNC: ... PASS
```

That packager is one of the files this track made path-free (`set llama
$pfRoot`), so it no longer has to be run from
`/home/orencollaco/GitHub/llama.vhdl`. Do **not** hand-copy the file into
`ip_repo/`; `check_ip_sync.py:322` says so and the copy is a packaging artifact
with more than the one file in it.

---

## 9. What the clean floor would be, and the one command that establishes it

`BASELINE_PASS` is **left at 130**. GATEDAY left it there for three stated
reasons and a number taken from a red run is worthless.

GATEDAY's DERIVED figure was `155 - 4 optional + 2 path artefacts = 153`. Those
two artefacts are now cured, so **the derived floor is unchanged at 153** --
what changed is that it is now *observable*, because a checkout can at last be
both clean and off the canonical path. It is still DERIVED and must not be
written onto the `BASELINE_PASS` line from anything but a full run.

The single command that would establish it, in a worktree at the tip, with the
~18 untracked `sim/tb_*.vhd` absent by construction:

```
git worktree add --detach /mnt/storage/fk33_builds/scratch/floor <tip>
cd /mnt/storage/fk33_builds/scratch/floor && \
  MV4I_FK33_FILE=/nonexistent REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/floor_run \
  systemd-run --user --scope -p MemoryHigh=8G bash sim/regress.sh --jobs 1
```

MEASURED by TRACK GATEDAY today: a full both-suite gate is **82m09s** and peaks
at **3.30 GiB** (cgroup, under an 8G cap, so a real peak). Expect it to stay
red on `sim:ipsync` until section 8 is done; raise `BASELINE_PASS` only from a
run that is green.
