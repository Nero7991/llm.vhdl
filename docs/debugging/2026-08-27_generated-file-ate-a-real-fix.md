# A hand-written undefined-behaviour fix lived in a GENERATED file, and the build deleted it on every run

## 1. The question

2026-08-27, branch `fpga`. `ref/mv4i_arith.h`, `rtl/mv4i_arith_pkg.vhd`,
`tools/gen_arith.py`, `sim/run_matvec.sh`. No hardware.

Found while running `sim/run_matvec.sh` during unrelated work: **stage 1
regenerates `ref/mv4i_arith.h`, `--check` reported the tree STALE, and the
regeneration discarded a real correctness fix that had been hand-added to that
file.** The question is whether the fix was needed and where it belongs.

## 2. The answer

**The fix was needed and it belonged in the generator, not in its output. It is
now in `tools/gen_arith.py`, and it touches only the C emitter, not the VHDL
one, so no RTL numeric behaviour changes.** Regenerating is now a no-op:
`gen_arith.py --check` reports "generated files are in step", and running the
generator for real leaves both outputs byte-identical.

The fix itself: `mv4i_floor_shr` computes `(int64_t)1 << sh`, which is
undefined at `sh >= 63`, and `mv4i_round_shift` computes `1 << (sh - 1)`, which
is undefined at `sh >= 64`. Both are now stated directly, because `|v| < 2^63`
for any `int64_t` so a shift of 63 or more floors to 0 for `v >= 0` and to -1
for `v < 0`.

## 3. The procedure

1. **Read the diff a build produces, do not just look at its exit code.** The
   regeneration was reported as normal stage-1 behaviour. Only the diff showed
   that a hand-written guard with a nine-line comment had vanished.
2. **Establish whether the deleted code was real** by finding what motivated
   it. The comment names its own reproducer: UBSan flags it on `gdn_err.c` at
   `--tokens 32 --se-init 127 --eg 0 --wbits 32`.
3. **Establish the blast radius before editing the generator.** `gen_arith.py`
   emits BOTH `ref/mv4i_arith.h` and `rtl/mv4i_arith_pkg.vhd`, and the VHDL
   package is shared by subsystems A and B. A change that altered the VHDL
   would change RTL numeric behaviour under a place-and-route run that was in
   flight. Checking this is what made the edit safe to do immediately rather
   than later.
4. **Check the VHDL does not need the same guard.** It does not, and for a
   reason rather than by luck: VHDL's `shift_right` on a `signed` by a count at
   or past the vector length yields all sign bits, which is -1 for negative and
   0 for positive -- exactly what the C guard now returns. The two emitters stay
   in agreement without the VHDL changing.
5. **Verify by regenerating and diffing, not by reading.** `--check` clean plus
   `git status` empty on both outputs is the proof that the generator now
   reproduces the guard rather than merely containing something similar.

## 4. The evidence

The guard as it stands in the generator's C emitter, comment included, because
the comment is the part that explains why it is not a behaviour change:

```c
    /* |v| < 2^63 for any int64_t, so a shift of 63 or more floors to 0 for
     * v >= 0 and to -1 for v < 0.  Stating that directly is exact and removes
     * the UB; it is NOT a behaviour change on gcc x86-64, where the overflow
     * happened to produce INT64_MIN and the division then gave the same
     * answer.  That coincidence is the whole problem: it is correct today and
     * unowned by any standard. */
    if (sh >= 63) return (v < 0) ? -1 : 0;
```

After folding both guards in:

```
$ python3 tools/gen_arith.py --check
generated files are in step
$ python3 tools/gen_arith.py && git status --short ref/mv4i_arith.h rtl/mv4i_arith_pkg.vhd
(no output -- both outputs byte-identical)
$ git status --short tools/gen_arith.py
 M tools/gen_arith.py
```

Exactly one file changed, and it is the source rather than the artefact.

## 5. Measured and REJECTED -- do not retry

- **Leaving the guard in `ref/mv4i_arith.h` and relying on nobody running the
  build.** That is the state that produced this. `sim/run_matvec.sh` is the
  project's main end-to-end script; every run destroyed the fix.
- **Backing up the generated files and warning loudly instead of fixing the
  generator.** That mitigation was put in place first and is worth keeping, but
  it is not the fix: the guard was still overwritten on every run and the
  warning only told you afterwards. It converts a silent loss into a noisy one.
- **Adding the same guard to the VHDL emitter for symmetry.** Rejected on
  analysis, recorded so nobody adds it later thinking it was an oversight:
  VHDL's `shift_right` is already defined for counts past the vector length and
  yields the same values, so the guard would be dead code in the package that
  subsystems A and B both compile.

## 6. Measurement traps hit

- **A generated file looks exactly like a source file in a diff, in a review,
  and in an editor.** Nothing in `ref/mv4i_arith.h` stops an edit, and the edit
  was correct -- it was in the wrong place. If a file is generated, the only
  safe place to fix it is upstream, and the file itself should say so at the
  top loudly enough to stop a future edit.
- **"`--check` says STALE" reads as housekeeping.** A staleness report means
  the tree and the generator disagree, and it does not say WHICH is right. Here
  the tree was right and the generator was wrong, which is the opposite of the
  usual assumption.
- **The undefined behaviour was benign on this compiler**, which is what let it
  live. The overflow produced `INT64_MIN` and the subsequent division gave the
  correct answer on gcc x86-64. A test would not have caught it; only UBSan
  did.

## 7. Open, not yet answered

- Nothing prevents the next hand-edit to a generated file. `ref/mv4i_arith.h`,
  `rtl/mv4i_arith_pkg.vhd` and the third generated target carry a header
  naming the generator, but the project has no check that fails a build when a
  generated file is edited by hand rather than silently overwriting it. The
  backup-and-warn mitigation in `sim/run_matvec.sh` is the closest thing.
- Whether any other generated file in the repo carries a hand-edit that has not
  been noticed yet. Not swept.
