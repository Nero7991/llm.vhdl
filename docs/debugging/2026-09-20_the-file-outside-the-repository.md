# The file outside the repository: pinning the vendor input the build chain grows from

TRACK UPPIN, 2026-09-20. Workstation, branch `fpga`. No Vivado started, no
hardware, nothing removed. Scratch on `/mnt/storage/fk33_builds/scratch/uppin`.

Third in a series. `docs/debugging/2026-09-20_generated-files-record-their-inputs.md`
(TRACK GENSTAMP, extended by TRACK GENGATE) established that a generated file
must record its out-of-band inputs.
`docs/debugging/2026-09-20_the-tcl-nothing-builds-from.md` (TRACK TCLOWNER)
decided which committed build artefacts to keep, and found this while looking
for something else. **This file is separate because the answer here corrects
TCLOWNER's ordering of the risk**, and a correction buried as an appendix under
a closed retention decision is a correction nobody reads.

## The question, verbatim

TRACK TCLOWNER, in its own words:

> "the most load-bearing file is the one nobody was arguing about --
> `gen_firstlight.py:19` reads `~/GitHub/SQRL_FK33/projects/fk33_example.tcl`,
> **outside this repo**, at an unrecorded upstream revision (`4242680`)."

And the brief that followed: does that path still exist, is the upstream a git
repo with a recoverable revision, is `4242680` a commit in it, does the file at
that revision still produce the committed `build_fk33_firstlight.tcl`, and what
is the smallest durable fix.

## The answer, up front

**Everything TCLOWNER measured is correct, and its ordering of the danger is
backwards. There are TWO unpinned external inputs, not one, and the one it did
not find is the one read on every card build.**

- `gen_firstlight.py:19` reads `projects/fk33_example.tcl`. **Nothing runs
  `gen_firstlight.py`** -- TCLOWNER measured that itself. Its external read
  fires only when a human re-runs it.
- `gen_i2cprobe.py:42` reads `projects/fk33_example.xdc`, **a second external
  file that neither TCLOWNER nor GENSTAMP recorded**, and
  `hw/fk33/pcieep_build.sh:84` runs `gen_i2cprobe.py` **before every card
  build**. That generator copies every upstream constraint line verbatim into
  `fk33_i2cprobe.xdc`, which is `gen_pcieep.py`'s `XDC_SRC`, which becomes
  `fk33_pcieep.xdc`, **which Vivado reads in place from the repo**.

So the pin assignments and clock constraints that go into the bitstream are
read fresh, on every build, from a file outside the repository at a revision
nothing recorded. That is a stronger statement than the one in the question.

**`4242680` is a real commit and it is the right answer for the `.tcl` only.**
It is HEAD of the local clone and the last commit to touch that file. The
`.xdc` was last touched by `0737c22`, **2019-12-09, three years earlier**, so
"the SQRL_FK33 revision" is not one number and a single-commit pin would have
been a false record for one of the two files.

**Fixed, in the generators only: `tools/upstream_pin.py` pins the SHA-256 of
each external input and refuses to run when it differs.** Zero bytes change in
any committed generated file, for the reason in "why the fix is not a GENSTAMP"
below.

## The procedure, in the order run

Each step isolates one thing.

1. `free -g` first: 2 GiB free, 12 available, 13 GiB swap in use, build 11b
   holding the Vivado lane. Nothing here costs more than a Python process.
2. **Establish that the path exists and what it is.** `git remote -v`,
   `git log`, `git status --porcelain`, `git cat-file -t 4242680`.
3. **Pin the file's identity, not the repo's.** The blob hash and the
   last-commit-to-touch-it, separately for each of the two inputs. A repo HEAD
   moves when any file changes; a blob moves only when that file does.
4. **Reproduce the committed output** from a `git archive` scratch tree.
5. **Repeat the reproduction so that it must CHANGE something** -- truncate the
   target first -- because an untouched file compares equal to itself.
6. **Teeth: mutate the upstream in a way the generator's existing guards cannot
   see**, and run the attribution control (same generator, real upstream).
7. **Establish whether a fix may touch the generated output at all**, by
   reading what consumes it.
8. Build the pin, teeth-test it in both directions on both generators.

## The evidence

### The upstream is a real repo, clean, and `4242680` is real

```
origin  https://github.com/d953i/SQRL_FK33.git
HEAD    4242680 Update fk33_example.tcl      branch Vivado_2022_2, worktree CLEAN
git cat-file -t 4242680  ->  commit
        4242680b33dca856b2181c6d8fac952dd25c1946   2022-11-07 09:15:37 -0500
```

### The two inputs, and they are at DIFFERENT revisions

| generator | external input | last commit to touch it | blob | sha256 |
|---|---|---|---|---|
| `gen_firstlight.py:19` | `projects/fk33_example.tcl` | `4242680` **2022-11-07** | `157ea2dd` | `556343e3...1d7a89aa` |
| `gen_i2cprobe.py:42` | `projects/fk33_example.xdc` | `0737c22` **2019-12-09** | `750128ed` | `5db73327...b891cb40` |

### The committed output reproduces exactly, today

```
$ md5sum hw/fk33/build_fk33_firstlight.tcl     c55e310732c023c410250890ba445a48
$ cd $SCR/tree/hw/fk33 && python3 gen_firstlight.py
  guarded 76 exclude_bd_addr_seg calls
  wrote .../tree/hw/fk33/build_fk33_firstlight.tcl
  rc=0
$ md5sum .../build_fk33_firstlight.tcl         c55e310732c023c410250890ba445a48
  difflines=0
```

**That run proves less than it looks, and the second one is the real test.**
The md5 was the same before and after, which is exactly what a generator that
refused its input and wrote nothing would also produce. Repeated with the
target emptied first, so an untouched file cannot pass:

```
$ : > build_fk33_firstlight.tcl      md5 = d41d8cd98f00b204e9800998ecf8427e
$ python3 gen_firstlight.py          rc=0
$ md5sum build_fk33_firstlight.tcl   c55e310732c023c410250890ba445a48   RESTORED
```

### THE DEFECT: a load-bearing upstream change that no guard sees

Both generators already abort loudly when a substitution anchor stops matching.
That is real and it covers the handful of lines each one REWRITES -- six
substitutions in `gen_firstlight.py`, two iic lines in `gen_i2cprobe.py`. It
says nothing about the other four hundred, which are COPIED.

Mutant, built from the thing rather than from the guard's notion of it: one
upstream HBM parameter, touching no substitution anchor and no
`exclude_bd_addr_seg` call.

```
upstream:  CONFIG.USER_HBM_STACK {2}  ->  {1}

$ python3 <generator pointed at the mutated upstream>
  guarded 76 exclude_bd_addr_seg calls
  wrote .../build_fk33_firstlight.tcl
  rc=0                                  <-- no warning, no abort

$ diff <committed> <emitted>
86c86
< set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} ...
> set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {1} ...
  difflines=4

ATTRIBUTION CONTROL, same generator, real upstream:   difflines=0
```

The HBM stack count silently changed and the generator reported success.

### The pin, with teeth in both directions

```
TEETH A  gen_firstlight.py, mutated upstream .tcl
  gen_firstlight.py: ABORT -- the upstream input has CHANGED.
      expected  556343e3...  (SQRL_FK33 ... commit 4242680 ... blob 157ea2dd)
      observed  1f3fdbdb...
  rc=1
CONTROL A  same generator, real upstream                       rc=0

TEETH B  gen_i2cprobe.py, mutated upstream .xdc (PACKAGE_PIN AD8 -> AD7)
  gen_i2cprobe.py: ABORT -- the upstream input has CHANGED.
      expected  5db73327...  (SQRL_FK33 ... commit 0737c22 ... blob 750128ed)
      observed  07ea45bf...
  rc=1
CONTROL B  same generator, real upstream                       rc=0
```

The pin is checked before either output is written (`require` at :217, the
first write at :256), so a refusal leaves the tree untouched rather than
half-regenerated.

## Why the fix is a pin in the GENERATOR and not a GENSTAMP in the OUTPUT

This was the design decision, and it was made by measurement rather than taste.

GENSTAMP's thesis is that the file in front of you should answer the question,
which argues for stamping the upstream revision into
`build_fk33_firstlight.tcl` itself. **It cannot be done there without cascading
through four more committed files.** MEASURED: `gen_i2cprobe.py:40` and
`gen_hbmbw.py:91` both take `build_fk33_firstlight.tcl` as `SRC` and copy its
text wholesale, and `gen_pcieep.py:231` takes `build_fk33_i2cprobe.tcl` the
same way. Inserting lines at the top of the first file shifts the body of
`build_fk33_i2cprobe.tcl`, `build_fk33_hbmbw.tcl` and `build_fk33_pcieep.tcl`,
which together carry **83 human line-number citations**, plus the 11 into
`fk33_pcieep.xdc` that TRACK TCLOWNER had just measured being broken by exactly
this mechanism.

So: the pin lives in the generator's source, which is in this repository and
under version control, and the generated files are untouched. `git log
hw/fk33/gen_i2cprobe.py` now answers "which upstream did this come from",
which is what was actually wanted.

**There is deliberately no environment-variable override.** An override would
be one more piece of out-of-band input that changes what a generator emits,
which is the exact hazard GENSTAMP exists for. Re-pinning is a source edit that
lands in git as a dated record. The friction is the feature.

## Measured and REJECTED -- do not retry

- **"Vendor `fk33_example.tcl` and `fk33_example.xdc` into this repo."**
  REJECTED for now, and the reason is not size (417 + 162 lines, 45,711 bytes
  together, trivial). It is that `gen_firstlight.py`'s own docstring states the
  design intent outright: *"A GENERATOR rather than a checked-in fork, so that
  upstream fixes are not lost: SQRL_FK33 is a third-party repo we do not
  control, and a hand-edited copy would silently diverge the first time it
  changes."* Vendoring converts a detectable divergence into an invisible one,
  which is the failure mode the generator was built to avoid. It would also
  need a licence decision that is not a track's to make: the upstream ships a
  `LICENSE` (11,357 bytes) that nobody in this project has read into the record.
  **A hash pin gets the detection without the licensing question.**
- **"Make it a git submodule."** NOT REJECTED ON EVIDENCE, and not done. It is
  the structurally correct answer and it is bigger than this track: it changes
  how every checkout of this repo is cloned, and both generators hardcode
  `~/GitHub/SQRL_FK33` in paths they EMIT (`set scriptPath`, `set sourceRoot`)
  as well as in paths they READ, so the submodule path would have to replace
  both. Recorded as open below, with the pin as the cheap thing that makes the
  expensive thing optional rather than urgent.
- **"Record the revision in a GENSTAMP in `build_fk33_firstlight.tcl`."**
  REJECTED, MEASURED: it cascades into four committed files and 94 citations.
  See the section above.
- **"`4242680` is the SQRL_FK33 revision this build depends on."** REJECTED as
  a general statement. It is right for the `.tcl` and wrong for the `.xdc`,
  which is at `0737c22`. Pin per FILE, not per repo.
- **"The generators already abort on upstream changes."** REJECTED, MEASURED:
  they abort on changes to the lines they REWRITE. A one-line HBM change gave
  rc=0 and a silently different output, with the control at difflines=0.

## Measurement traps hit, including my own

- **THE MUTANT GENERATOR WROTE ITS OUTPUT SOMEWHERE ELSE, AND THE FIRST TEETH
  RESULT WAS `difflines=0`.** `gen_firstlight.py` derives `DST` from
  `os.path.dirname(os.path.abspath(__file__))`, so a copy of the generator
  placed in the scratch ROOT wrote `build_fk33_firstlight.tcl` into the scratch
  root, not into the tree under test. The diff was then run against a file
  nothing had touched, and an untouched file compares equal to itself. **It
  reported that a load-bearing mutation had no effect.** The only tell was the
  generator's own `wrote /...` line naming a path I was not comparing. This is
  CLAUDE.md's "let the generator print, and read its exit status" earning its
  place a second time, in a new form: the status was 0 AND correct, and the
  PATH was the thing that was wrong.
- **A MUTANT THAT DOES NOT MUTATE MAKES A TEETH ROW MEANINGLESS AND IT LOOKS
  LIKE A PASS.** Building the upstream `.xdc` mutant, the first `sed` matched
  nothing and produced a byte-identical "mutant". Caught only by an explicit
  `cmp -s ... && echo MUTANT IDENTICAL`, added because the same shape had
  already bitten once that hour. **Assert that the mutant differs from the
  control before running the check against it**, every time.
- **A `--check` TEETH ROW FAILED TO BITE AND THE CHECK WAS NOT AT FAULT.** Row
  7 mutated the committed `build_fk33_pcieep.tcl` with
  `s/^set_property BITSTREAM.GENERAL.COMPRESS TRUE/.../` -- an anchor that
  exists in the XDC and **does not appear anywhere in the TCL**, so the file
  was unchanged and the check correctly reported OK. The instinct was to
  suspect the new code. `grep -c` on the anchor settled it in one command.
  **A guard that does not fire is a claim about the mutant until you have shown
  the mutant landed.**
- **ONE OF THE ELEVEN CITATIONS WAS ALREADY WRONG BEFORE THE STAMP.**
  `docs/debugging/2026-08-28_fk33-spi-flash-boot.md` cites
  `fk33_pcieep.xdc:122` for a comment that was at **121** at `08cc17d^`. So
  TCLOWNER's "all 11 were correct at `08cc17d^`" is right for the three it
  verified and overstated for the set. Corrected to 126 here, which fixes both
  the off-by-one and the stamp shift.
- **`git grep` counts LINES, my census counted OCCURRENCES, and the two
  disagree by 50 on the same file.** TCLOWNER recorded 122 repo-prefix hits in
  `build_fk33_pcieep.tcl`; `--check` reports 171. Both are right: several lines
  carry the prefix twice. Neither number is wrong, and quoting one where the
  other was measured would look like drift.

## What changed in the tree

| file | change |
|---|---|
| `tools/upstream_pin.py` | NEW. `require(path, sha256, generator, upstream)`; absence and mismatch reported as different failures. |
| `hw/fk33/gen_firstlight.py` | pins `fk33_example.tcl` at `4242680` / blob `157ea2dd`; replaces the bare existence check. |
| `hw/fk33/gen_i2cprobe.py` | pins `fk33_example.xdc` at `0737c22` / blob `750128ed`; notes that this one is read on every build. |
| `tools/genstamp.py` | NEW `append_end()`, refuses a non-comment block. |
| `hw/fk33/gen_pcieep.py` | XDC stamp moved to the END behind a fixed 5-line banner; 10-line HEADER note that nothing builds from the committed tcl; `--emit-to` and `--check`. |
| `hw/fk33/fk33_pcieep.xdc` | regenerated: body back to +5 instead of +19. |
| `hw/fk33/build_fk33_pcieep.tcl` | regenerated: the 10-line header note only. |
| 5 documents | 9 citations corrected. |

Gates after the change, all rc=0: `SELFTEST PASS`, `PCIEEP_CHECK: PASS`,
`FK33_XDC_CHECK OK`, `FK33_CARD_CHECK: OK` x2, `GEN_CARDTOP_CHECK: OK`,
`HBMBW_CHECK: OK`, `COMPOSE4_CHECK ok`.

## Open, not determined

- **Whether `SQRL_FK33` should be a submodule.** The structurally right answer,
  not attempted. See REJECTED above for why it is bigger than a pin.
- **The upstream's licence has not been read into the record.** It gates
  vendoring and it gates nothing else. Nobody has looked.
- **Whether the pinned revisions are the ones anybody WANTS.** The pin records
  what the tree has been building against since August; it is a staleness
  detector, not an endorsement. Upstream `origin` was NOT queried -- no `git
  fetch` and no `ls-remote` was run, so **whether `4242680` is still upstream
  HEAD is unmeasured**, and the local clone could be years behind.
- **Whether the committed `build_fk33_pcieep.tcl` would build off this
  machine.** Unchanged from TCLOWNER: `set scriptPath` and `set sourceRoot`
  still name the upstream checkout absolutely. DERIVED from the text, not
  MEASURED.
- **The tcl's own GENSTAMP is still at the TOP**, so `build_fk33_pcieep.tcl`'s
  59 citations remain exposed to the shift-on-input-change mechanism that the
  XDC is now immune to. Not moved, because those 59 are already wrong by
  varying amounts (GENGATE) and re-anchoring them is a separate job.
- **75 of the 81 line-citations remain unaudited.** TCLOWNER audited 6; this
  track audited and fixed the 11 into `fk33_pcieep.xdc` and touched no others.
- **Nothing here is a silicon measurement.** No Vivado was started, no
  bitstream, no hardware, nothing deleted.
