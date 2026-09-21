# A generated file's banner says THAT it was generated, not WITH WHAT

TRACK GENSTAMP, 2026-09-20. Workstation, branch `fpga`, no Vivado, no hardware.

## The question, verbatim

> "Enumerate the class. Which generators in this repository read environment
> variables (or any other out-of-band input) that change what they emit? ...
> Make each generated-and-committed file record the inputs that produced it, in
> its own header, so the file in front of you answers the question."

Raised by TRACK BUILDREPORT the same evening, in its own words:

> "`hw/fk33/build_fk33_pcieep.tcl` is generated, and its committed form was
> produced with env I could not reconstruct (`FK33_CARD=1` **plus**
> `FK33_CB_STYLE=distributed` **plus** a 75 MHz `CLKOUT3`). Regenerating it with
> the default environment silently changed its *configuration* (**497
> deletions, the whole lever-C block**) ... **'Regenerate and diff the output'
> is not safe when the generator reads the environment.**"

## The answer, up front

**Exactly two generators in this tree read the ENVIRONMENT, but seven committed
generated files depend on out-of-band input of some kind, and only ONE of them
has ever recorded it.** That one, `rtl/hbm_tg_ip.vhd`, is the proof of the whole
idea: its header line `Regenerate with: python3 tools/gen_hbm_tg_ip.py 30` makes
`30` recoverable, and MEASURED, that exact command reproduces the committed file
**byte-for-byte**, while the generator's own default (`16`) deletes **1,025 of
its 1,028 lines**. Its sibling `hw/fk33/build_fk33_hbmbw.tcl` records nothing,
and recovering its `30 300` took three attempts and produced one false positive.

The fix is `tools/genstamp.py`: a deterministic `GENSTAMP` block, emitted by the
generator into its own output, naming every out-of-band input and its value,
plus the command that reproduces the file. It carries no time, no user, no
hostname and no working directory, so it does not break the five gate rows that
regenerate a file and compare it against the committed bytes.

Applied to `hw/fk33/gen_fk33_card.py` (environment), `tools/gen_hbm_tg_ip.py`
(argv) and `hw/fk33/gen_hbmbw.py` (argv). **NOT applied to
`hw/fk33/gen_pcieep.py`, the case that prompted the track**, because TRACK
BUILDREPORT owns that file tonight; the patch is written out below for its
owner.

## The class, enumerated

MEASURED: `grep -o 'environ.get("[A-Z0-9_]*"' hw/fk33/gen_*.py tools/gen_*.py`
and `grep -nE 'add_argument\(|sys\.argv'` over the same 27 generators.

| generator | output | committed? | out-of-band input | stamped |
|---|---|---|---|---|
| `hw/fk33/gen_pcieep.py` | `hw/fk33/build_fk33_pcieep.tcl`, `hw/fk33/fk33_pcieep.xdc` | **COMMITTED** | **env**: `FK33_CARD`, `FK33_CB_STYLE`, `FK33_ENG`, `FK33_ENG_CORE_MHZ`, `FK33_ENG_FAST_MHZ`, `FK33_ENG_SPLIT_CLK`, `FK33_FLATTEN`, `FK33_SYNTH_JOBS`, `FK33_SYNTH_THREADS` (9) | **NO -- owner is TRACK BUILDREPORT** |
| `hw/fk33/gen_fk33_card.py` | `hw/fk33/rtl/fk33_card.vhd`, `hw/fk33/rtl/fk33_bc_grant.vhd` | **COMMITTED** | **env**: `FK33_C_KV_BLOCK`, `FK33_A_ROWS_IF` | **YES** |
| `tools/gen_hbm_tg_ip.py` | `rtl/hbm_tg_ip.vhd` | **COMMITTED** | **argv**: `NPORT` (default 16, committed is 30) | **YES** (upgraded from its own ad-hoc line) |
| `hw/fk33/gen_hbmbw.py` | `hw/fk33/build_fk33_hbmbw.tcl` | **COMMITTED** | **argv**: `NPORT` (default 15, committed is 30), `FCLK_MHZ` (default 300) | **YES** |
| `hw/fk33/gen_compose4_top.py` | `hw/fk33/rtl/compose4_top.vhd` | **COMMITTED** | **argv**: 13 switches (`--wire`, `--mem`, `--cb-style`, `--norm-entity`, `--norm-w-image`, `--instances`, ...) | **no -- TRACK GATERED owns the file** |
| `tools/gen_cardtop.py` | `rtl/fk33_llama_top.vhd`, `sim/tb_fk33_cardtop_ident.vhd` | **COMMITTED** | `--check`/`--bench` only; neither changes the body | not needed |
| `hw/fk33/gen_fk33_engine.py` | `hw/fk33/rtl/fk33_engine.vhd` | **COMMITTED** | none | not needed (but see "open") |
| `hw/fk33/gen_firstlight.py`, `gen_i2cprobe.py` | `build_fk33_firstlight.tcl`, `build_fk33_i2cprobe.tcl` | **COMMITTED** | none (derive from a file) | not needed |
| `hw/fk33/gen_fk33_regs.py`, `tools/gen_arith.py`, `tools/gen_shape_mirror.py`, `tools/gen_tokenizer_unicode_tables.py`, `tools/gen_*_rom_pkg.py`, `tools/gen_weights_pkg.py`, `tools/gen_weight_mem.py`, `tools/gen_fixed_luts_pkg.py`, `tools/gen_imrope_pkg.py` | headers / VHDL packages | **COMMITTED** | file inputs only (`--src`/`--out` paths, defaulted) | not needed |
| `tools/gen_layer_program.py` (24 switches), `tools/gen_mv4i_desc.py` (16), `tools/gen_lmhead_windows.py` (11), `tools/gen_llama_top_weights.py`, `tools/gen_qkn_image.py`, `tools/gen_bd_wrapper.py` | descriptors, hex images, wrappers | **TRANSIENT** (written to a scratch or build dir, or consumed by another generator) | many | **not needed -- the hazard is only real for committed output** |

**The committed-versus-transient split is the load-bearing line.** A generator
with 24 switches whose output nobody commits cannot mislead anyone: the file and
the command that made it die together. A generator with ONE switch whose output
is committed can, and did.

## The procedure

Each step isolates one thing. Every generator run below had its exit status and
its stdout read, for the reason in the traps section.

1. **`free -g` before starting.** 14 GiB available, build 11b holding the Vivado
   lane. Nothing in this track costs more than a Python process.
2. **Prove the live build is not exposed.** `/proc/PID/exe` identified two
   Vivado processes (one 12.8 GiB, cwd `.../fk33_pcieep.runs/impl_1`), and
   `ls -l /proc/PID/fd | grep -c llama.vhdl` returned **0** for both. So
   regenerating committed RTL cannot disturb it. Identification by `exe` and
   `fd`, never by a command line.
3. **Baseline every staleness self-check BEFORE touching anything**, so a later
   red is attributable. All seven green (raw output below).
4. **Enumerate by grep, over the entity/argument surface rather than over
   prose:** `environ.get("NAME"` and `add_argument(`/`sys.argv` across all 27
   `gen_*.py`.
5. **For each committed output, ask whether the DEFAULT reproduces it.** Copy
   the committed file aside, run the generator, `git diff --numstat`, restore
   with `git checkout --`. This is the only measurement that tells you whether a
   file is already in the hazardous state.
6. **Recover the true arguments where the default does not reproduce**, and
   confirm by byte-identity, not by eye.
7. **Write the stamp, then prove determinism** (three consecutive regenerations,
   `sha256sum` each time) **and prove the gate rows still pass**.
8. **Teeth**: generate under two configurations, show the stamp AND the body
   differ, and show the check fails.

## The evidence

### Baseline, before any edit

```
rc=0  python3 hw/fk33/gen_fk33_card.py --check
FK33_CARD_CHECK: OK fk33_card.vhd (19561 bytes, image repo prefix: /home/orencollaco/GitHub/llama.vhdl)
FK33_CARD_CHECK: OK fk33_bc_grant.vhd (11984 bytes, image repo prefix: none)
rc=0  python3 tools/gen_cardtop.py --check --bench          GEN_CARDTOP_CHECK: OK
rc=0  python3 hw/fk33/gen_compose4_top.py --check           COMPOSE4_CHECK ok (123590 bytes)
rc=0  python3 sim/ooc_gdnadapt_extract.py --check ...       GDNADAPT_CHECK ok (1 outputs)
rc=0  python3 ip_repo/check_ip_sync.py                      IPSYNC: PASS
rc=0  python3 tools/gen_shape_mirror.py --check             SHAPE_MIRROR_CHECK: OK
rc=0  python3 hw/fk33/gen_pcieep.py --selftest              SELFTEST PASS
```

### The hazard, reproduced on `build_fk33_pcieep.tcl` and then undone

```
$ python3 hw/fk33/gen_pcieep.py          # DEFAULT environment
wrote .../hw/fk33/build_fk33_pcieep.tcl
rc=0
$ git diff --numstat -- hw/fk33/build_fk33_pcieep.tcl
145	496	hw/fk33/build_fk33_pcieep.tcl
$ git checkout -- hw/fk33/build_fk33_pcieep.tcl
restored byte-identical to the committed copy
```

**496 deletions**, confirming TRACK BUILDREPORT's 497 to within one line, and
the first hunk of that diff is a comment about `tgRoot`. Nothing in the 641
changed lines says "you changed `FK33_CARD` from 1 to unset". Nothing in the
file said what `FK33_CARD` had been.

### The one file that already recorded its input, and what that bought

```
$ head -10 rtl/hbm_tg_ip.vhd          # the COMMITTED copy, before this track
-- rtl/hbm_tg_ip.vhd -- GENERATED by tools/gen_hbm_tg_ip.py, do not hand-edit.
-- 30 read/write masters exposed as individually NAMED AXI interfaces,
-- Regenerate with:  python3 tools/gen_hbm_tg_ip.py 30

$ python3 tools/gen_hbm_tg_ip.py 30
wrote rtl/hbm_tg_ip.vhd, NPORT=30
rc=0
$ git diff --numstat -- rtl/hbm_tg_ip.vhd
(no output -- BYTE-IDENTICAL)

$ python3 tools/gen_hbm_tg_ip.py        # the generator's own default, 16
$ git diff --numstat -- rtl/hbm_tg_ip.vhd
3	1025	rtl/hbm_tg_ip.vhd
```

### Recovering the unrecorded one

`hw/fk33/build_fk33_hbmbw.tcl` records nothing. `git log` on the file names
commit `4dc20ee` ("fk33: enable stack 1, **30 generator ports**"), and the
committed text's own `CLKOUT3_REQUESTED_OUT_FREQ {300.000}` gives the clock:

```
$ python3 hw/fk33/gen_hbmbw.py 30 300
hbmbw: datapath clock 300 MHz (VCO 600.0 MHz = 200 x 3.000, divide 2)
guard: all 12 edits present
rc=0
$ git diff -- hw/fk33/build_fk33_hbmbw.tcl
-set tgRoot /home/orencollaco/GitHub/llama.vhdl
+set tgRoot [file normalize [file join [file dirname [info script]] .. ..]]
+if {![file exists $tgRoot/rtl/util_pkg.vhd]} { error ... }
```

So `30 300` is the configuration, and the file's ONLY real staleness is one
hunk: the derived-root fix from `3219cb0` (TRACK PATHFREE, the same day) that
was never regenerated into it. Against the defaults the same file shows **288
deletions**, and the two causes are indistinguishable in that diff.

### The stamp, and determinism

```
$ head -13 hw/fk33/build_fk33_hbmbw.tcl
# GENERATED by hw/fk33/gen_hbmbw.py from build_fk33_firstlight.tcl
# -- do not hand-edit; regenerate so first-light fixes are not lost.
# See that script's header for the four changes and what is deliberately
# left alone.
# GENSTAMP -- the out-of-band inputs that produced THIS file, and
# the only record of them.  This generator's output DEPENDS on the
# values below: regenerating with different ones changes the
# CONFIGURATION, not the formatting, and the diff looks like
# ordinary drift.  Reproduce this exact file with
#     python3 hw/fk33/gen_hbmbw.py 30 300
# inputs ((unset) means the generator's own default was taken):
#     argv FCLK_MHZ = 300
#     argv NPORT    = 30
```

Three consecutive regenerations of the card pair, `sha256sum` each time:

```
run1 card=dc4c6e4f3e113e3d9b52 grant=b9c8567d9fcb975f5407
run2 card=dc4c6e4f3e113e3d9b52 grant=b9c8567d9fcb975f5407
run3 card=dc4c6e4f3e113e3d9b52 grant=b9c8567d9fcb975f5407
```

`hbm_tg_ip` and `hbmbw` likewise identical across two runs each. The stamp block
is also **order-independent**: it sorts by `(kind, name)`, so two callers
assembling the same values in different orders emit the same bytes (MEASURED).

### The gate rows, after the change

```
--only fk33card     OVERALL PASS 1  FAIL 0
--only stale        OVERALL PASS 2  FAIL 0   (sim:c4stale, sim:gdnstale)
--only ipsync       OVERALL PASS 1  FAIL 0
--only runguard     OVERALL PASS 1  FAIL 0
--only shapemirror  OVERALL PASS 1  FAIL 0
--only cardtop      OVERALL PASS 3  FAIL 0   (incl. sim:tb_fk33_cardtop_ident, 108s)
python3 tools/check_kv_map.py -> check_kv_map: 40 rows, 0 refused, 0 not run
```

Nine rows, zero failures, at `--jobs 1`. Every `OVERALL` line was read, and
every one has a non-zero PASS count.

### Teeth -- the stamp discriminates

Same generator, two environments:

```
$ diff card.default.vhd card.kv16.vhd
8c8
< --     python3 hw/fk33/gen_fk33_card.py
> --     FK33_C_KV_BLOCK=16 python3 hw/fk33/gen_fk33_card.py
11c11
< --     env  FK33_C_KV_BLOCK = (unset)
> --     env  FK33_C_KV_BLOCK = 16
244c244
<       C_KV_BLOCK               => 32,
>       C_KV_BLOCK               => 16,
$ python3 hw/fk33/gen_fk33_card.py --check     # default env, KV16 file on disk
FK33_CARD_CHECK: STALE ... rc=1
```

The stamp moves with the body, and the check bites.

And the failure it prevents, on `rtl/hbm_tg_ip.vhd`: regenerating with the
default now puts the cause in **line 12 of the diff** --

```
-    python3 tools/gen_hbm_tg_ip.py 30
+    python3 tools/gen_hbm_tg_ip.py 16
```

-- where before a reviewer had 1,025 deleted port declarations and a single
changed word ("30" to "16") buried in the prose of line 4.

Teeth on the helper itself: `genstamp.insert_after` RAISES when its marker is
absent (`ValueError: genstamp: marker 'DO NOT HAND-EDIT' not found`) rather than
appending somewhere plausible.

## Measured and REJECTED -- do not retry

- **`python3 hw/fk33/gen_hbmbw.py 31 300` DOES NOT reproduce the committed file,
  and it looked like it did.** The generator REFUSES 31 ("NPORT must be 15 or
  30; SAXI_00 and SAXI_16 are reserved for jtag_hbm") and exits **without
  writing**. Its output was going to `/dev/null`, so the untouched file compared
  equal to itself and `sha256sum` agreed **twice in a row**. Reported to myself
  as a byte-identical reproduction before being caught. Do not use "the diff is
  empty" as a reproduction test when the generator can refuse.
- **"The `tgRoot` hunk is upstream drift from `gen_firstlight.py`."** REJECTED:
  `build_fk33_firstlight.tcl` was never modified, and the hunk is present at
  every `NPORT`. It is `3219cb0`'s change to `gen_hbmbw.py` itself, never
  regenerated.
- **Putting the stamp in `tools/gen_bd_wrapper.py`.** REJECTED: it is a library
  with several callers and knows nothing about `FK33_*`; a stamp written there
  would be either empty or a claim it cannot support. The stamp belongs to the
  generator that reads the inputs.
- **One shared reproduce command for both of `gen_fk33_card.py`'s outputs.**
  REJECTED after measurement, and this is the trap the whole track is about in
  miniature. `fk33_bc_grant.vhd` does not depend on `FK33_*` and is stamped
  `inputs: NONE` -- yet under `FK33_C_KV_BLOCK=16` it grew by exactly **19
  bytes**, the width of the `FK33_C_KV_BLOCK=16 ` prefix, because the stamp had
  smuggled the environment into a file that is supposed to be independent of it.
  **A stamp that claims no dependence while varying with the environment is
  worse than no stamp.** The reproduce line is now DERIVED from the same list
  the rows are printed from, so the claim and the evidence are one object.
  After the fix, `diff` of the two `fk33_bc_grant.vhd` is empty.
- **Adding a `--check` staleness row for `rtl/hbm_tg_ip.vhd` or
  `build_fk33_hbmbw.tcl`.** NOT DONE, deliberately: `sim/regress.sh` is owned by
  another track tonight, and a `--check` that nothing schedules is the
  "regenerated by a script nothing runs" defect already catalogued in CLAUDE.md.
  Left as an open item with the exact row text.
- **Regenerating `hw/fk33/rtl/fk33_engine.vhd` to stamp it.** NOT DONE: it has
  no out-of-band inputs, so the stamp would be empty, and CLAUDE.md records that
  its generator "writes unconditionally and even `--help` rewrites the repo
  file". Touching it buys nothing and risks a file the card build reads.

## Measurement traps hit

1. **A generator that refuses its argument leaves the file untouched, and an
   untouched file compares equal to itself.** See the `31 300` entry above. This
   is CLAUDE.md's "a completion signal that also fires on failure" in a new
   place: `git diff` was reporting a fact about the harness. **Check the exit
   status and let the generator print.** Prefer a reproduction test that must
   CHANGE something (regenerate under a different value, then back) over one
   that must change nothing.
2. **The same trap fired a second time, on a Python `SyntaxError`.** A
   determinism loop printed the same `sha256sum` twice while
   `hw/fk33/gen_hbmbw.py` was failing to parse at line 386. Identical hashes from
   a generator that never ran.
3. **`gen_pcieep.py` writes TWO committed files.** Restoring only
   `build_fk33_pcieep.tcl` would have left `hw/fk33/fk33_pcieep.xdc` modified.
   `git status --porcelain hw/fk33/` after the experiment, not just a targeted
   `git diff`, is what caught it.
4. **A stamp is a change to every generated file, so it is a change to every
   staleness gate.** That is why determinism was measured before the commit and
   not after. A timestamp or a `$PWD` in the stamp would have turned five rows
   red on every machine -- `rtl/ooc_cattnadapt_top.vhd` is the recorded
   counter-example in this tree: its "Regenerate with" line embeds
   `/tmp/claude-.../scratchpad/...`, a path from the session that made it, which
   is both non-reproducible and now deleted.

## Environment dependence judged a DEFECT and left alone (not fixed -- it has an owner)

1. **`hw/fk33/pcieep_build.sh:89` runs `python3 gen_pcieep.py` unconditionally
   before every build, and line 130 copies the result into `BUILD_ROOT`.** So
   the COMMITTED `build_fk33_pcieep.tcl` is never the file that builds: the
   build always regenerates it from whatever environment the script was invoked
   with. The committed copy's only consumer is a human reading it, which is
   exactly the reader the missing stamp misled. Whether that file should be
   committed at all is a design decision.
2. **`gen_pcieep.py` reads NINE environment variables and none is an
   argument.** An env var is invisible in shell history, in a `ps` listing and
   in any log that does not print it. `FK33_CARD` in particular selects between
   two builds with different memory budgets (CLAUDE.md: 10.66 GB engine-only
   versus ~47 GB card).
3. **`hw/fk33/rtl/fk33_card.vhd`'s banner names the WRONG generator**:
   `GENERATED by tools/gen_bd_wrapper.py`, which is the library, not the driver
   (`hw/fk33/gen_fk33_card.py`). Following the banner cannot reproduce the file.
   The stamp's reproduce line now names the driver; the banner itself is
   `gen_bd_wrapper.py`'s text and was left alone.
4. **`gen_fk33_card.py`'s `FK33_C_KV_BLOCK` trim is documented to make
   `check_kv_map.py` validate the DEFAULT geometry while the build uses the
   trimmed one.** The generator says so itself and prints a stderr banner. The
   stamp now also puts the trimmed value in the file, which is a second,
   durable tell -- but the underlying split between what is checked and what is
   built is unchanged and is not mine to change.

## Open, not determined

- **`hw/fk33/gen_pcieep.py` is UNSTAMPED.** It is the case that prompted the
  track and it is owned by TRACK BUILDREPORT tonight. Patch handed over below.
- **`hw/fk33/rtl/compose4_top.vhd` is UNSTAMPED.** Thirteen argv switches,
  committed output, `sim:c4stale` checks it against the DEFAULT arguments only,
  and its header's `Regenerate with: python3 hw/fk33/gen_compose4_top.py`
  carries no switches. Whether the committed file was made with `--wire --mem`
  has not been determined here. TRACK GATERED owns the file.
- **`rtl/hbm_tg_ip.vhd` and `hw/fk33/build_fk33_hbmbw.tcl` have no staleness
  gate.** Both are now stamped, so their inputs are recoverable, but nothing
  notices if a generator change leaves them behind -- which is exactly what
  happened to `hbmbw` across `3219cb0`. The row text, for whoever owns
  `sim/regress.sh`: `[hbmtgstale]="python3 $REPO/tools/gen_hbm_tg_ip.py --check"`
  would need a `--check` mode written first; neither generator has one.
- **`hw/fk33/build_fk33_hbmbw.tcl` was regenerated in this commit**, which
  carries one hunk that is NOT the stamp: `3219cb0`'s derived-`tgRoot` fix,
  landing about eight hours late. It is an improvement and it is what the
  generator says, but it is a second change in one commit and is called out
  rather than absorbed.
- **Whether `rtl/hbm_tg_ip.vhd` at `NPORT=30` is the configuration anything
  currently builds** was not checked. The stamp records what made the file; it
  does not claim the file is wanted.
- **The `tgRoot` line's behaviour across `NPORT` was not chased.** An early
  reading of the default diff suggested the derived-root block depended on the
  port count; the `30 300` reproduction shows it does not. The early reading is
  withdrawn, and the branch was not read line by line.

## Handover patch for `hw/fk33/gen_pcieep.py` (NOT applied -- TRACK BUILDREPORT owns the file)

This is the case that prompted the track, and it is the only one left unstamped
for a reason that is not technical. Applying it is two edits and one
regeneration. **Regenerate under the environment the committed file was made
with** -- `FK33_CARD=1 FK33_CB_STYLE=distributed` plus whatever set `CLKOUT3` to
75 MHz -- **not under the defaults**, or the commit lands the 496-line
configuration change this file exists to document. Verify with
`git diff --numstat`: a correct first application shows roughly `+12 -0`, the
stamp alone. Anything larger is a configuration change riding along.

```python
# near the top, after REPO/HERE are computed
sys.path.insert(0, os.path.join(REPO, "tools"))
import genstamp

# beside the nine os.environ.get calls, as ONE list so the stamp and the
# behaviour cannot drift apart.  Value = None where the default was taken.
def _env(name, default=None):
    return os.environ.get(name) or None

STAMP_INPUTS = [("env", n, _env(n)) for n in (
    "FK33_CARD", "FK33_CB_STYLE", "FK33_ENG", "FK33_ENG_CORE_MHZ",
    "FK33_ENG_FAST_MHZ", "FK33_ENG_SPLIT_CLK", "FK33_FLATTEN",
    "FK33_SYNTH_JOBS", "FK33_SYNTH_THREADS")]
STAMP_CMD = ([f"{n}={v}" for (_, n, v) in sorted(STAMP_INPUTS) if v]
             + ["python3", "hw/fk33/gen_pcieep.py"])

# at gen_pcieep.py:6107, which today reads
#     open(DST, "w").write(HEADER + text)
open(DST, "w").write(
    HEADER + genstamp.stamp(STAMP_CMD, STAMP_INPUTS, comment="#") + text)
```

`hw/fk33/fk33_pcieep.xdc` (written at `gen_pcieep.py:6229`) is the generator's
SECOND committed output and wants the same block. Whether the XDC's content
actually depends on the environment was not determined here; if it does not,
stamp it with `[]`, which states that positively rather than leaving the reader
to guess.

`gen_pcieep.py --selftest` should be extended with a row asserting that two runs
under DIFFERENT environments produce DIFFERENT stamps and two runs under the
SAME environment produce identical bytes. Build the mutant from a real
environment difference, not from the string the check looks for: this tree's
recorded `seam_tieoff_teeth()` failure was a check and a mutant wrong in the
same direction, and it passed green every day the build was dead.

---

# 2026-09-20, TRACK GENGATE: the handover applied, and the three unchecked generators gated

Workstation, branch `fpga`, no Vivado, no hardware. Appended to GENSTAMP's file
rather than started as a new one, because this is the same defect class and the
same evidence chain.

## The question, verbatim

> "Apply GENSTAMP's prepared handover for `hw/fk33/gen_pcieep.py` ... Give
> `rtl/hbm_tg_ip.vhd` and `build_fk33_hbmbw.tcl` a staleness gate ...
> `hw/fk33/gen_fk33_engine.py` is ungated and rewrites the repo file even on
> `--help`."

## The answer, up front

**The recovered environment is `FK33_CARD=1 FK33_CB_STYLE=distributed
FK33_ENG_CORE_MHZ=75`, all three load-bearing, and under it the stamp costs
`+16 -0`.** The committed `build_fk33_pcieep.tcl` was ALSO **117 lines behind its
own generator** before this track touched it, in three unrelated blocks, so the
full regeneration is `+133 -6`. The handover's estimate of "roughly `+12 -0`"
was right about the stamp and did not know about the drift, and **the drift is
the exact failure the whole track exists to make visible** -- it sat in the one
generated file nobody could regenerate safely.

**Three `--check` modes now exist and all three are gated** (row text handed to
`sim/regress.sh`'s owner, not applied). Two of them recover their argument from
the committed file's own GENSTAMP block, which is what makes them possible at
all: with the generators' defaults, both report STALE on a current tree.

## The procedure

1. **`free -g`, and identify the live Vivado by `/proc/PID/exe`, never by a
   command line.** Build 11b: PID 493310, `cwd=.../build11b/root/fk33_pcieep/
   fk33_pcieep.runs/impl_1`, RSS 12.4 GiB; PID 387741 the launcher. **`ls -l
   /proc/PID/fd | grep -c llama.vhdl` = 0 for both**, so regenerating committed
   files in the repo cannot disturb it.
2. **Recover the environment in a SCRATCH COPY, never the shared checkout.**
   `git archive HEAD | tar -x -C /mnt/storage/fk33_builds/scratch/gengate/tree1`
   -- 181 MB, tracked files only, no `.git` mutation, so no other track's index
   or worktree is touched.
3. **Run the DEFAULT first, as a reproduction test that must CHANGE something.**
   GENSTAMP's trap is that an unwritten file compares equal to itself; a run
   whose only evidence is an empty diff cannot distinguish "reproduced" from
   "refused". Exit status read, generator allowed to print, every time.
4. **Normalise the embedded absolute paths before diffing** (see trap 1) and
   sweep the candidate environments, one variable at a time.
5. **Apply the patch in the scratch copy, run `--selftest`, mutate the
   selftest's own rows, restore.** Only then copy into the checkout.
6. **For each `--check`: control green, three mutants red, tree restored and
   md5-verified.** Then the same at the GATE level in the scratch tree, with the
   two pre-existing `*stale` rows as the control that should NOT move.

## The evidence

### Recovering the environment: which variables are load-bearing

Path-normalised (`@ROOT@`), against the committed file, pre-stamp generator:

```
env                                                          changed lines
FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75       123
FK33_CARD=1 FK33_CB_STYLE=distributed                            125
FK33_CARD=1                           FK33_ENG_CORE_MHZ=75       137
(default)                                                        641   (145 +, 496 -)
```

`CLKOUT3_REQUESTED_OUT_FREQ {75.000}` in the committed file is
`ENG_CORE_MHZ` at `gen_pcieep.py:3667`, which is the read that pins 75.

### The 123 residual lines are NOT configuration. They are three pending generator changes

```
+24  the tgRoot block and 6 lines of $tgRoot substitution   (3219cb0, TRACK PATHFREE)
+70  the post-place report hook (STEPS.PLACE_DESIGN.TCL.POST) (TRACK BUILDREPORT, today)
+23  report_utilization -hierarchical after open_run          (TRACK BUILDREPORT, today)
```

Zero lever-C lines move, zero clock lines move, and the six deletions are the
`add_files` of the XDC and the pblock becoming `$tgRoot/...`. So the environment
is settled and the rest is drift.

### The stamp, and the final diff

```
$ FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 python3 hw/fk33/gen_pcieep.py
rc=0
$ git diff --numstat
133  6  hw/fk33/build_fk33_pcieep.tcl      # 16 stamp + 117 drift
 19  0  hw/fk33/fk33_pcieep.xdc            # 3 banner + 16 stamp, body unchanged
```

```
# GENERATED from hw/fk33/build_fk33_i2cprobe.tcl by hw/fk33/gen_pcieep.py
# -- do not hand-edit; regenerate so the probe build's fixes are not lost.
# GENSTAMP -- the out-of-band inputs that produced THIS file, and
# ...
#     FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 python3 hw/fk33/gen_pcieep.py
# inputs ((unset) means the generator's own default was taken):
#     env  FK33_CARD          = 1
#     env  FK33_CB_STYLE      = distributed
#     env  FK33_ENG           = (unset)
#     env  FK33_ENG_CORE_MHZ  = 75
#     env  FK33_ENG_FAST_MHZ  = (unset)
#     env  FK33_ENG_SPLIT_CLK = (unset)
#     env  FK33_FLATTEN       = (unset)
#     env  FK33_SYNTH_JOBS    = (unset)
#     env  FK33_SYNTH_THREADS = (unset)
```

Three consecutive regenerations, byte-identical each time
(`tcl=e8b5109068c4ee8476e0 xdc=10ba221c862eb8fe00d8`).

### The XDC gets the SAME nine rows, not an empty stamp

The handover said "if it does not [depend on the environment], stamp it with
`[]`". MEASURED: it does.

```
FK33_ENG=0           35 body lines change (ENG_XDC selects the other block)
FK33_ENG_SPLIT_CLK=1  8 body lines added  (ENG_SPLIT_XDC)
FK33_CARD / FK33_CB_STYLE / FK33_ENG_CORE_MHZ   0 body lines, sha256 identical
```

So the honest statement is "these nine were the environment", not "this file has
no inputs". The XDC also had **no banner at all** before this -- its first line
is SQRL's, inherited from `fk33_i2cprobe.xdc`, so nothing said it was generated.

### `gen_pcieep.py --selftest` gained `genstamp_teeth()`, and it bites three ways

Control: `GENSTAMP env names read=9 stamped=9`, both teeth lines, `SELFTEST PASS`.

| mutant | built from | result |
|---|---|---|
| `FK33_FLATTEN` dropped from `STAMP_ENV_NAMES` | a real read site left unstamped | `FAIL ... read-but-not-stamped=['FK33_FLATTEN']` rc=1 |
| `FK33_PHANTOM` added to `STAMP_ENV_NAMES` | a real name nothing reads | `FAIL ... stamped-but-not-read=['FK33_PHANTOM']` rc=1 |
| `os.getcwd()` spliced into the reproduce command | a real non-determinism | `FAIL: the stamp carries '/mnt/storage/...'` rc=1 |

Attribution control: all three mutants are edits to code that did not exist
before this change, so no pre-existing selftest row could have caught any of
them, and none is being credited to an existing property.

### The three new `--check` modes

| check | committed argument | default | MEASURED runtime |
|---|---|---|---|
| `python3 tools/gen_hbm_tg_ip.py --check` | `NPORT=30` from its own stamp | 16 | **0.025 s** |
| `python3 hw/fk33/gen_hbmbw.py --check` | `NPORT=30 FCLK_MHZ=300` from its own stamp | 15, 300 | **0.017 s** |
| `python3 hw/fk33/gen_fk33_engine.py --check` | none; the generator has no out-of-band input | -- | **0.017 s** |

**THE ATTRIBUTION CONTROL IS THE HEADLINE HERE, because it shows reading the
stamp is load-bearing and not decoration.** The same check, on the same current
tree, with the generator's DEFAULT argument instead of the stamped one:

```
$ python3 tools/gen_hbm_tg_ip.py --check 16
HBMTG_CHECK: STALE rtl/hbm_tg_ip.vhd (NPORT=16 ...)          rc=1
$ python3 hw/fk33/gen_hbmbw.py --check 15 300
HBMBW_CHECK: STALE build_fk33_hbmbw.tcl (NPORT=15 FCLK_MHZ=300 ...)  rc=1
```

A row that is red on a correct tree gets muted, and a muted row is the
"regenerated by a script nothing runs" defect with extra steps.

### Teeth, per check, with the tree restored and md5-verified after each

`HBMTG_CHECK` (`rtl/hbm_tg_ip.vhd` back to `1fa271d7b976f236b8f0fe79c68e3e60`):

```
control                                     OK   rc=0   (also from a foreign cwd)
one body line changed                       STALE rc=1, diff names the line
the stamp says NPORT=16, body still 30      STALE rc=1  <- proves the stamp is READ
the stamp removed entirely                  ABORT rc=1  <- refuses, does not default
```

`HBMBW_CHECK` (`263544372deca43966575c887c0e3ad6`): same four rows, same
verdicts, the body mutant's diff naming `set_property top bd_wrapperX`.

`GEN_FK33_ENGINE_CHECK` (`0da4b4b6e20897e146eb23ec02cf7b77`):

```
control                                     OK   rc=0
FAST_POP default flipped true -> false      STALE rc=1, diff names FAST_POP
the file deleted                            STALE rc=1 "the file does not exist"
```

`FAST_POP` is the mutant on purpose: it is the lever build 11b carries, and it
is the reason an ungated `fk33_engine.vhd` was worth closing tonight.

**None of the three writes anything under `--check`** -- `git status --porcelain`
empty on the target after every run, in both the OK and the STALE direction.

### The `--help` write, MEASURED before and after

`hw/fk33/gen_fk33_engine.py` parsed nothing and called `main()` unconditionally.
In the pristine scratch tree, with the file's mtime pinned to 2000-01-01:

```
$ python3 hw/fk33/gen_fk33_engine.py --help
wrote .../hw/fk33/rtl/fk33_engine.vhd (91191 bytes, 28 masters)
$ stat -c '%y' hw/fk33/rtl/fk33_engine.vhd
2026-09-20 20:48:21            <- --help rewrote the repo file
```

After: `--help` prints usage and returns 0 writing nothing; `--chek` prints
usage and returns **2** rather than silently regenerating; the file's md5 is
unchanged across all three. It was a small change (argument handling before the
side effect, plus `sys.exit(main())`), so it was done rather than deferred.

### The gate rows, at the gate

Dry-run in the scratch tree with the handover lines applied to a COPY of
`sim/regress.sh` (the live runner was never edited):

```
--only stale --jobs 1   OVERALL PASS 5 FAIL 0     REGRESSION: PASS
  sim:c4stale     PASS  COMPOSE4_CHECK ok
  sim:gdnstale    PASS  GDNADAPT_CHECK ok
  sim:hbmtgstale  PASS  HBMTG_CHECK: OK rtl/hbm_tg_ip.vhd (NPORT=30 from its own GENSTAMP, 104184 bytes)
  sim:hbmbwstale  PASS  HBMBW_CHECK: OK build_fk33_hbmbw.tcl (NPORT=30 FCLK_MHZ=300 from its own GENSTAMP, 88840 bytes)
  sim:engstale    PASS  GEN_FK33_ENGINE_CHECK: OK hw/fk33/rtl/fk33_engine.vhd (91191 bytes, 28 masters)
```

Then one line appended to each of the three targets in the scratch tree:

```
--only stale --jobs 1   OVERALL PASS 2 FAIL 3     REGRESSION: FAIL
  sim:c4stale     PASS   <- control, did not move
  sim:gdnstale    PASS   <- control, did not move
  sim:hbmtgstale  FAIL
  sim:hbmbwstale  FAIL
  sim:engstale    FAIL
```

In the real checkout, six self-check rows green after the change, `--jobs 1`,
each `--only` read for its `OVERALL` line: `runguard`, `ipsync`, `c4stale`,
`gdnstale`, `shapemirror`, `fk33card`, all `OVERALL PASS 1 FAIL 0`. Plus
`hw/fk33/check_pcieep_xdc.py` -> `FK33_XDC_CHECK OK` against the restamped XDC.

## The `sim/regress.sh` block, to be applied by that file's owner

NOT applied here: three tracks were gating, and bash re-seeks a running script
by byte offset. Verified end to end against a copy, as above.

After the `printf 'c4stale\t...` line:

```bash
printf 'hbmtgstale\tsim\tRUN\t-\t-\t-\t-\n' >> "$PLAN"
printf 'hbmbwstale\tsim\tRUN\t-\t-\t-\t-\n' >> "$PLAN"
printf 'engstale\tsim\tRUN\t-\t-\t-\t-\n' >> "$PLAN"
```

In `declare -A SELFCHECK_CMD`, after the `[c4stale]=` line:

```bash
  [hbmtgstale]="python3 $REPO/tools/gen_hbm_tg_ip.py --check"
  [hbmbwstale]="python3 $REPO/hw/fk33/gen_hbmbw.py --check"
  [engstale]="python3 $REPO/hw/fk33/gen_fk33_engine.py --check"
```

In `run_one`'s dispatch case, extend the existing alternation:

```bash
    runguard|ipsync|descrule|cardtop|srvseam|srve2e|bdports|srvstories|c4stale|hbmtgstale|hbmbwstale|engstale|shapechk|gdnstale|shapemirror|fk33card|kvmap|seamregs|normimage|gdnconst|constimage|qknimage|logitcmp|imglock) run_selfcheck "$key"; return ;;
```

**And one comment correction, in the `c4stale` block around line 2046:** it says
`gen_fk33_engine.py` "still does not" have a `--check` and that "even `--help`
rewrites the repo file". Both statements are now false.

## Measured and REJECTED -- do not retry

- **Regenerating `build_fk33_pcieep.tcl` in a scratch tree and diffing it
  against the committed file.** The generator writes ABSOLUTE `add_files` paths
  for 104 sources plus the XDC and the pblock, so a scratch regeneration differs
  from the committed file in ~110 lines that are pure path. The scratch run is
  still the right place to DEVELOP; the comparison has to be either
  path-normalised or done in the real checkout.
- **Stamping `fk33_pcieep.xdc` with `[]`**, as the handover suggested as an
  option. REJECTED on measurement: `FK33_ENG=0` moves 35 body lines. An empty
  stamp there would have been a false claim of independence, which GENSTAMP's
  own `fk33_bc_grant.vhd` incident says is worse than no stamp.
- **A `--check` for `gen_pcieep.py` itself.** NOT DONE, and this is the one
  place where the mechanism exists but the case is not closed -- see "open".
  It would have to read its nine values back out of the stamp (the reader is
  written and works) AND cope with the absolute paths above, which makes it
  checkout-specific in a way the other three are not.
- **Putting the stamp marker in the MIDDLE of the XDC's banner.**
  `genstamp.insert_after` splits after the FIRST matching line, so the banner's
  own third line ended up BELOW the stamp. Marker on the last line.
- **Leaving `gen_hbmbw.py`'s output guards after the write.** They were, and the
  gate row's detail line then read `guard: all 12 edits present` and never named
  the check, because `run_selfcheck` reports the LAST non-empty line. Guards
  moved ahead of the write, which also means the file is no longer written when
  a guard fires.

## Measurement traps hit

1. **THE SELF-MATCH TRAP FIRED A FOURTH TIME, INSIDE THE FUNCTION WHOSE
   DOCSTRING SAYS THE HAYSTACK CANNOT HOLD THE NEEDLE.** `genstamp_teeth()`
   scans `gen_pcieep.py`'s own source for `os.environ.get("FK33_...` read sites.
   The scanner's pattern is escaped (`os\.environ`) so it cannot match itself --
   that reasoning is correct and was written down. Then the MUTANT was spelled
   out as one literal, `'\nos.environ.get("FK33_MUTANT_NEVER_STAMPED", "")\n'`,
   which put a real-looking read site in the file being scanned. The control run
   reported `read=10 stamped=9` and exited 1 on a clean tree. Split so the
   pattern is never contiguous in the source. **Escaping the needle is not
   enough if you also write an unescaped copy of it nearby.**
2. **`diff -u | grep -c '^+[^+]'` under-counts by the number of blank added
   lines**, because a blank addition is a bare `+`. It disagreed with
   `git diff --numstat` by exactly 3 and the gap was briefly read as a real
   difference between the scratch and the checkout. Use `numstat`.
3. **Three comments in this repo cite `build_fk33_pcieep.tcl` by LINE NUMBER,
   and all three were ALREADY WRONG at HEAD.** `host/fk33_run_token.py:86` cites
   `:781-782` for `DRAM_0_STAT_TEMP`, which at HEAD is line 902 (781 is an
   `add_files`); `tcl/axi_select.tcl:45` cites `:251` for a `M_AXI_DATA_WIDTH
   {64}` that is at 372. Checked BEFORE attributing anything to this
   regeneration, which moves them a further +40. **A line-number citation into a
   generated file is stale by construction**; they are recorded, not fixed,
   because they belong to other files.

## Open, not determined

- **`hw/fk33/gen_pcieep.py` STILL HAS NO `--check`, and it is now the only
  committed generator in this class without one.** The stamp makes it possible
  (`genstamp.read_inputs` on the committed file returns all nine rows, MEASURED)
  but the absolute `add_files` paths mean such a check passes only in the
  checkout that wrote the file. That is a design decision about whether the
  generator should emit `$tgRoot`-relative sources, which is TRACK PATHFREE's
  territory and half-done already.
- **Whether `NPORT=30` is the configuration anything currently wants** is still
  not established -- GENSTAMP flagged it, this track deliberately did not answer
  it, and the `--check` is explicitly a staleness test and not an endorsement.
  The same question applies to `FCLK_MHZ=300`.
- **The 117 lines of drift now committed into `build_fk33_pcieep.tcl` have never
  been through a build.** They are three changes by two other tracks that their
  authors regenerated into no committed file; the committed copy's only consumer
  is a human reader, because `pcieep_build.sh:89` regenerates before every
  build. Called out rather than absorbed, exactly as GENSTAMP called out the
  `tgRoot` hunk in `build_fk33_hbmbw.tcl`.
- **Nothing here is a silicon measurement, and no build was run.** The claim is
  that the committed files now match their generators under a recorded
  environment, not that any of them builds.
- **`hw/fk33/rtl/compose4_top.vhd` remains UNSTAMPED** (13 argv switches,
  `sim:c4stale` checks it against the DEFAULTS only). TRACK GATERED owns it.
  Unchanged from GENSTAMP's open list.
