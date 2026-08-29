# Subsystem B: two places the benches checked transcription and not arithmetic

Date: 2026-08-28.  Repo `llama.vhdl`, branch `fpga`, at `19a7ad1`.
Simulator: ghdl-mcode, VHDL-2008, `-frelaxed`, via `sim/regress.sh`.
No hardware involved.

## 1. The question

Verbatim, from the completeness audit
(`docs/2026-08-28_9b-completeness-audit.md` section 1.3) and the dispatch:

> **HOLE 1** -- `gdn_recur_pipe` is the SHIPPING recurrence and has no accuracy
> check at all.  `sim/tb_gdn_recur_pipe.vhd:147-148` reads the oracle's `u` and
> `o` columns and explicitly discards them.  The unit is checked only for
> equality with `gdn_recur`'s recipe, so the two units agreeing proves
> transcription, and a shared error in the recipe is invisible to both.
>
> **HOLE 2** -- `l2norm_rs` is tolerance-checked and has no C model.
> `sim/tb_l2norm_rs.vhd` compares against `x/||x||` computed in `math_real`,
> within 0.75 output LSB.  `ref/` contains no l2norm model at all.

Both confirmed exactly as stated, at those line numbers, before any edit.

## 2. The answer

Both holes are closed and **both units pass**.  `gdn_recur_pipe` reproduces
`gdn_recur`'s accuracy figures to sixteen significant digits, so the shipping
recurrence is as accurate as the one that was already asserted.  `l2norm_rs` is
bit-exact with a new independent C model on 182 cases and is inside 0.5 output
LSB against real arithmetic, which is the bound correct round-half-up implies.

One **new defect** was found on the way, in shipping RTL, and is NOT fixed here:
`rtl/l2norm_rs.vhd:245` rejects a legal input.  See section 6.

## 3. The procedure, in the order it was run

Each step isolates one thing.  The order matters: every conclusion below rests
on the control immediately above it.

1. **Confirm the holes against the files, not the audit.**  `readline` with no
   `read` is the discard; `ls ref/l2norm*` is the missing model.  Cheap, and it
   is the step that would have caught a stale audit.
2. **Baseline both benches before touching them**, so "it passed after" means
   something.  `tb_gdn_recur_pipe` PASS in 7 s, `tb_l2norm_rs` PASS in 2 s.
3. **HOLE 1: consume the oracle columns rather than dropping them.**  The
   accuracy check is applied to `v_got`, the state the DUT actually emitted,
   not to `v_snew` from the vector file.  Checking the C model's own output for
   accuracy and calling the result a DUT result is the same substitution the
   hole is made of.  An assertion guards the ordering assumption that makes
   this possible (`o_res_valid` lands after the data stream).
4. **Cross-check against `tb_gdn_recur`.**  The two units are required to be
   bit-identical, so the two accuracy reports must agree to the last digit.
   They do.  A near-miss would have meant the new check was measuring something
   else.
5. **HOLE 2: write `ref/l2norm_rs_vec.c` and check bit-exactly, WITHOUT
   deleting the tolerance check.**  A second transcription of the recipe is
   exactly the construction that certified the collapse in
   `2026-08-25_l2norm-recipe-collapse.md`.  It is added for the errors the
   tolerance is blind to, never in place of it.
6. **Verify the generator reproduces the committed golden.**  `ref/gdn_recur_vec.c`
   run into a private workdir produced a file bit-identical to
   `sim/gdn_recur_vec.txt`.  Without this, every "shared mutation" below would
   have been silently RTL-only -- and for the first four attempts it was.
7. **Mutate, in three separate classes**, because a single class cannot
   separate the two checks:
   - **RTL only**   -> must fail bit-exactness (the pre-existing check).
   - **C only**     -> must fail bit-exactness and NOT the tolerance
                       (proves the new C model is actually consumed).
   - **C and RTL together** -> must PASS bit-exactness and fail the accuracy
                       check (this is the shared-recipe class, the whole point).
8. **Full both-suite regression** before and after.

## 4. The evidence

### HOLE 1, after

```
tb_gdn_recur_pipe: within the oracle bounds on all 274 physically realizable
columns -- worst 8.955004673607618 state LSB (TOL_S 1.2e1) and
6.577674348402551e-5 of the output dot's term norm (TOL_O 1.0e-4) [worst dot at
column 243, term norm 3.852725748403052e4; 0 columns had an identically-zero
oracle dot].  State error splits 8.955004673607618 LSB steady state /
1.1105957031722937 LSB at tk = 0.
tb_gdn_recur_pipe: bit-identical to the reference on all 384 columns
```

`tb_gdn_recur`, same vectors, unchanged file, for comparison:

```
gdn_recur: bit-exact with the C recipe on all 384 cases; over the 274
physically realizable ones, worst vs the double ORACLE is 8.955004673607618
state LSB and 6.577674348402551e-5 of the output dot's term norm
[worst at case 243, eg=32768, term norm 3.852725748403052e4]
```

Identical to every digit, including which column is worst and its term norm.

### HOLE 2, after

```
l2norm_rs: bit-exact with ref/l2norm_rs_vec.c on all 182 cases -- 46592
elements over both paths, 1 case(s) with ssq = 0 -- and within tolerance of
x/||x|| on every case -- worst 4.999352950867433e-1 output LSB at case 133,
bound TOL = 7.5e-1
```

0.49994 LSB is inside the 0.5 that correct round-half-up implies, so the
2-iteration Newton residual is not visible at 16-bit output width.  Truncation
would reach 1.0, so the check still separates the two.

`msb(ssq)` coverage of the 182 cases: **0 through 36, every value**.  37 is
absent and that absence is the defect in section 6, not a gap.

### Mutations

`RTL` = `rtl/*` only, `C` = `ref/*` only, `BOTH` = the same recipe change
applied to each.  A shared mutation must leave bit-exactness green.

| # | unit | class | mutation | bit-exact | accuracy |
|---|---|---|---|---|---|
| S1 | gdn_recur_pipe | BOTH | `w18` round-half-up -> truncate | PASS | **PASS (did not bite)** |
| S2 | gdn_recur_pipe | BOTH | `e_o = se_new + 18` -> `+ 17` | PASS | FAIL 273 of 274 |
| S3 | gdn_recur_pipe | BOTH | `e_kd = 15 + e_dm` -> `14 + e_dm` | PASS | FAIL 265 of 274 |
| G2 | gdn_recur_pipe | RTL | drop the `w18` rounding bias | FAIL | pass |
| G3 | gdn_recur_pipe | RTL | double the `w18` rounding bias | FAIL | FAIL 41 of 274 |
| G4 | gdn_recur_pipe | RTL | `o_e_o` claim `+18` -> `+17` | FAIL | FAIL 273 of 274 |
| L1 | l2norm_rs | RTL | round instead of truncate the final Newton `y` | **pass (did not bite)** | pass |
| L2 | l2norm_rs | RTL | `RSQRT_ROM` index `mant(29:24)` -> `mant(30:25)` | FAIL 131 | FAIL 122 |
| L3 | l2norm_rs | RTL | `bias_k` forced to 0 (truncate the k emit) | FAIL 86 | FAIL 73 |
| L4 | l2norm_rs | RTL | `if ssq = 0` -> `if ssq < 0` (kill the divergence) | n/a | RTL assert fires |
| L5 | l2norm_rs | RTL | q fold `ssq << LOG2N` -> `<< LOG2N+1` | FAIL 181 | FAIL 181 |
| L6 | l2norm_rs | **C** | `sat16` limit 32767 -> 32766 | FAIL 57 | **pass** |
| L7 | l2norm_rs | BOTH | q fold `1/sqrt(N)` -> `1/sqrt(2N)` | **PASS** | FAIL 181 |

S2, S3 and L7 are the ones that matter: a recipe error present in the model AND
the RTL, invisible to every bit-exact check, caught only by the real-valued
oracle.  L6 is the converse: a defect the tolerance cannot see at all.

## 5. Measured and REJECTED -- do not retry

- **S1: dropping the `w18` round-half-up bias in both the C and the RTL does
  NOT move the accuracy verdict.**  The worst state error stayed at
  8.955004673607618 LSB and the worst output dot at 6.577674348402551e-5,
  identical to sixteen digits, even though the generated vectors demonstrably
  changed.  Reason: the unit's existing worst case is the open `d_m` grid
  defect at ~9 LSB, and a half-LSB perturbation two stages upstream cannot
  reach it.  **The oracle check at `TOL_S = 12.0` cannot resolve a half-LSB
  rounding change in this unit** and no bound short of ~1 LSB could, because
  the unit's own error is 18x larger.  Do not treat the oracle check as
  rounding-sensitive; the bit-exact check is what covers that (G2 caught it).
- **L1: rounding instead of truncating the final Newton `y` (`mr_p >> 31`) is
  invisible to BOTH checks.**  A 1-ulp change in a Q30 mantissa is a relative
  2^-30, i.e. ~3e-5 of an output LSB, and it flipped no output integer in
  46,592 elements.  Neither check can see below about 1 ulp of the Q30
  intermediate.  This is expected and is not worth re-testing.
- **`sim/gdn_recur_vec.txt` is COMMITTED, so `sim/regress.sh` never regenerates
  it** (`if [ -e "$SIM/$v" ] && [ -z "$args" ]; then continue`).  Mutating
  `ref/gdn_recur_vec.c` and running regress.sh therefore changes NOTHING.  Four
  mutation runs were wasted before this was noticed; they were labelled
  "shared" and were RTL-only.  A shared mutation on this unit must regenerate
  the vectors into a private workdir.  Note also that `ref/gdn_recur_vec.c`
  opens `ref/gdn_eg_qwen3_27b.txt` by a path relative to the CWD, so it must be
  run from the repo root, which is NOT where regress.sh would run it.
- **The first version of `ref/l2norm_rs_vec.c` drove `1 << 15` = 32768 as a
  stimulus element.**  `x[]` is a C `int`, so the model scored +32768 while
  VHDL's `to_signed(...,16)` handed the DUT -32768.  Two cases failed
  bit-exactness with a clean sign flip on two elements, which reads exactly
  like a DUT sign bug.  The only tell was a `NUMERIC_STD.TO_SIGNED: vector
  truncated` warning buried above the errors.  The generator now refuses any
  element outside int16 and says so.

## 6. NEW DEFECT: `l2norm_rs` rejects a legal input (NOT fixed)

`rtl/l2norm_rs.vhd:97` states the bound as

> `ssq <= N * 32768^2 = N * 2^30, so the bound is 2^(30 + log2 N)`

and `:245` asserts it as

```vhdl
assert ssq >= 0 and ssq < shift_left(to_signed(1, 64), SSQ_BITS)
```

with `SSQ_BITS = 30 + LOG2N`.  The compare is **strict**, so it excludes the
maximum the comment says is included.  `x[i] = -32768` for all `i` is a legal
int16 vector giving `ssq = 128 * 2^30 = 2^37` exactly.  MEASURED, driving that
vector into an otherwise untouched `l2norm_rs`:

```
rtl/l2norm_rs.vhd:245:13:@89ns:(assertion failure):
    l2norm_rs: ssq outside the u37 bound implied by N
ghdl-mcode:error: assertion failed
```

Severity FAILURE, so the unit kills the run rather than saturating.  It is off
by one: `SSQ_BITS` should be `31 + LOG2N`, or the compare should be `<=`.

**Deliberately not fixed.**  `l2norm_rs` is instantiated under `gdn_block` and
`llama_top` as of `3246046`, and an RTL change under a just-integrated top is
not something a verification track lands silently.  Adding the case to
`ref/l2norm_rs_vec.c` instead would make the regression FAIL, which is not the
same thing as reporting the defect, so the generator carries the case as a
comment naming the measurement.

Reachability in the real design is **NOT determined**.  `x_mant` here is a
post-silu head mantissa and 2.1.3's requantizer normalises amax to msb 14, so
all-lanes-at-full-scale is not a shape the pipeline is expected to produce.
That is an argument, not a measurement.

## 7. Measurement traps hit

- `--only` takes a simple pattern, not an alternation, and a pattern matching
  nothing still prints `REGRESSION: PASS` on zero tests.  Always read
  `OVERALL PASS n`.
- `git commit -m ... -- <paths>` commits the **working tree** content of those
  paths, not the index.  Staging one hunk of `sim/regress.sh` with
  `git apply --cached` and then naming the file on the `git commit` line
  committed another track's unstaged edits along with it.  Caught by the
  `--stat` disagreeing with the staged `--stat` (22 lines vs 7) and amended.
  On a SHARED file, stage the hunk and commit **without** naming the path.
- `sim/regress.sh` re-execs itself from a private `/tmp/regress-self.*.sh`
  copy, so `pgrep -f regress-self` matches OTHER agents' runs too.  A
  wait-loop keyed on that name never terminates while any track is running.
- Without `--keep`, regress.sh deletes its scratch tree on exit, so a run whose
  stdout is lost leaves no evidence at all.

## 8. Open, not yet answered

- Whether `ssq = 2^37` is reachable from `gdn_block`'s real activations
  (section 6).  Argued, not measured.
- Whether `gdn_recur_pipe`'s accuracy holds at LANES other than 32.  Only the
  shipped configuration was measured.
- The `d_m` grid defect that puts the worst state error at 8.955 LSB is still
  open (`2026-08-26_gdn-first-token-dm-grid.md`); nothing here touches it.
- No mutation coverage exists for the other seven B units.  These two now have
  it; the rest do not.
