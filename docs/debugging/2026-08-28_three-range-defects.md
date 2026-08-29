# Three latent range defects: `matvec_core` OI-8, `l2norm_rs` OI-7, `attn_emit` OI-2

Date: 2026-08-28. Branch `fpga`, base `61d010d`. GHDL 1.0.0 mcode, `--std=08`.
Track: RANGE. No hardware was touched.

## 1. The question, verbatim

> Three latent off-by-one defects, all the same shape. All three are
> synthesis-benign and simulation-fatal: the hardware would be fine, GHDL kills
> the run. All three were found while doing something else, none is fixed, and
> each sits in a unit something else now depends on.
>
> - OI-8, `rtl/matvec_core.vhd:835`. `ybuf` is `array(0 to TILES-1)`, `rd_t` is
>   an unconstrained integer that `S_EMIT` advances to `tiles_r`, and `:835`
>   reads `ybuf(rd_t)` unconditionally every cycle.
> - OI-7, `rtl/l2norm_rs.vhd:245`. `:97` states the bound INCLUSIVELY;
>   `:245` asserts it STRICTLY against `SSQ_BITS = 30 + LOG2N`.
> - OI-2, `rtl/attn_emit.vhd:400`. Assigns `grp <= 1` unconditionally where
>   `:263` declares `grp : integer range 0 to NGRP-1`.
>
> For each: reproduce it first, fix it minimally, prove the fix, add the case
> to the permanent vector set, teeth-check.

## 2. The answer

All three reproduced exactly as reported, all three are fixed, and all three
now have a permanent case in the gate that fails without the fix.

- **OI-8** is fixed by clamping the ybuf read ADDRESS, not by gating the read
  and not by growing the array. `rd_t` is additionally given the range
  `0 to TILES` it actually holds.
- **OI-7** is fixed by making the compare `<=`, NOT by widening `SSQ_BITS` to
  `31 + LOG2N`. `SSQ_BITS` sizes nothing -- it appears only in the assert and
  its message -- so both fixes were available, and `<=` is the one that keeps
  the bound tight. Widening the constant would have admitted everything up to
  `2^38 - 1`, discarding a factor of two of overflow detection to fix an
  off-by-one.
- **OI-2** is fixed by moving `grp <= 1` inside the `NGRP > 1` branch and
  assigning `grp <= 0` in the `NGRP = 1` branch. It is not only a range
  violation: had the range been wider, the `NGRP = 1` path would then have
  entered `S_SHIFTS` reading `e_l(1)` of a one-element array.

None of the three needed a structural change, so the STOP-and-report branch did
not fire.

## 3. The procedure, in the order it was run

Each defect was taken through the same five steps, and the reproduction was
always first. Nothing was fixed that had not been seen to fail.

1. **Establish the passing baseline** for the unit's own bench on untouched
   RTL, so "unchanged" later has a number attached to it.
2. **Drive the corner the defect names**, on untouched RTL, and capture the
   abort verbatim. What each corner isolates:
   - OI-8: `n_rows` swept through the top `ROWS_IF` rows of the declared
     `MAXROWS_BFP`, with `n_rows` just BELOW that band as the control. The
     control is what separates "the emit pass is broken" from "the emit pass is
     broken only where `tiles_r = TILES`".
   - OI-7: the unique vector at `msb(ssq) = 30 + log2 N`. It is unique:
     `2^37` is the maximum ssq, so reaching that exponent forces
     `|x[i]| = 32768` for every `i`.
   - OI-2: the bench's own `NGRP` generic driven to 1, with the default
     `NGRP = 2` run alongside as the control.
3. **Fix, and state why that fix rather than the alternative.**
4. **Prove nothing else moved**: the same bench, the same shapes, the same
   element counts and the same worst-case error as the baseline. For OI-8 this
   was done as a matrix -- old bench against new RTL, compared line for line
   against old bench against old RTL -- so the RTL change is isolated from the
   bench change.
5. **Teeth**: revert the fix, run the NEW permanent case, confirm it fails,
   restore.

## 4. The evidence

### 4.1 OI-8, `rtl/matvec_core.vhd`

Reproduction, untouched RTL, `MAXROWS_BFP = 64` / `ROWS_IF = 4` so `TILES = 16`,
`ref/matvec_int4 --trace tr.txt M 96 4`:

```
=== M=60 ===
  BFP: 480 stage values compared, 0 mismatches, ns=7 y_exp=-3
  TOTAL: 900 stage + 120 output values compared, 0 mismatches (BFP and PARTIAL)
  RTL matches ref/matvec_int4.c at every stage
=== M=61 ===
/usr/bin/ghdl-mcode:error: index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:835
in process .tb_matvec_core(sim).dut@matvec_core(rtl).P6
=== M=64 ===
/usr/bin/ghdl-mcode:error: index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:835
```

`M = 60` gives `tiles_r = 15 < TILES`; `M = 61` and `M = 64` both give
`tiles_r = 16 = TILES`. That is the reported rule confirmed at a second
geometry (the finder measured it at 192/48), and the control at `M = 60` is
what makes it a rule rather than a coincidence.

Fix, `rtl/matvec_core.vhd`:

- `:122` new `function ybuf_addr(t : integer) return integer` returning
  `TILES - 1` for `t >= TILES`.
- `:400` `signal rd_t, rd_td : integer range 0 to TILES := 0;` (was
  unconstrained).
- `:855` `ybuf_q <= ybuf(ybuf_addr(rd_t));` (was `ybuf(rd_t)`).

**Why the address clamp and not the alternatives.**

- *Gating the read* (`if rd_t < TILES then ybuf_q <= ...`) is what the code's
  own note at that line warns against: the read is unconditional precisely so
  it infers a BRAM read port.
- *Growing `ybuf` to `array(0 to TILES)`* costs one word. That is free at a
  ragged depth and can cost a whole BRAM when `TILES` is a power of two, which
  it is at the bench's own geometry (16) and could be in a shipping build.
- *Restructuring `S_EMIT`* so `rd_t` never leaves the array -- stop the
  increment at `TILES-1` and carry a separate done flag -- is the version with
  no logic in the BRAM address path, but it changes the FSM's counting in a
  unit four subsystems depend on. The brief said to stop and report rather than
  restructure, so it was not done.

The clamp changes the value read on exactly the cycles where `rd_v = '0'`, so
no consumer can observe the difference. That is the same argument that makes
the defect synthesis-benign, used in the other direction.

Proof nothing moved -- the 13-shape sweep from `sim/run_matvec.sh` stage 5,
OLD bench, old RTL versus new RTL:

```
diff sweep_orig.txt sweep_fixed.txt
IDENTICAL: 13/13 cases, same element counts, same verdicts
```

Permanent case: `sim/tb_matvec_core.vhd` gains **PASS 3, the top of the row
range**, run after the existing BFP and PARTIAL passes with `n_rows = MAXR`,
which makes `ceil(n_rows/RI) = TILES` at every `RI`. It needs no new fixture:
rows at and above the trace's `M` carry index 0 and SCALE 0, so their
contribution is identically zero and `ns`/`y_exp` may not move. It asserts
`err = '0'`, that the port emitted exactly `MAXR` rows, and that `ns` and
`y_exp` are unchanged from PASS 1.

Two bench changes were needed to make it honest and are worth naming:

- `n_rows` and `tiles_s` now have two sources (the trace's `DIMS` line and
  PASS 3), and a VHDL signal may have one driver, so the loader writes a `_tr`
  pair and a concurrent mux selects on `top_pass`.
- the stage checkers gate on `n_rows_tr`, not `n_rows`. **This was found by
  the check failing**: the first version assumed pad rows produce zero
  everywhere, and they do not -- the PARTIAL tap is the pre-scale dot product
  and `cb(0) = -127`, so it reads 3,328,416 where the trace has no expectation
  at all. The scale is what zeroes the row, one stage later. So the value
  checkers score only rows the trace scored, and a separate ungated counter
  (`nemit`, incremented on every `y_mask`'d beat before the expectation gate)
  carries the property PASS 3 actually turns on -- that every row still comes
  OUT.

Teeth, fix reverted, NEW bench, at the gate's own configuration (`M=8 K=96
RI=4`, not a special shape):

```
  BFP: 64 stage values compared, 0 mismatches, ns=6 y_exp=-2
/usr/bin/ghdl-mcode:error: index (16) out of bounds (0 to 15) at matvec_core_orig.vhd:835
/usr/bin/ghdl-mcode:error: simulation failed
```

Restored:

```
M=8   K=96   R=4  S=0  A=0  OK  TOTAL: 184 stage + 24 output values compared, 0 mismatches
... 13/13 OK
```

The count rises from 120+16 to 184+24 because PASS 3 re-scores the trace's own
rows a third time; the 120+16 from passes 1 and 2 is unchanged.

### 4.2 OI-7, `rtl/l2norm_rs.vhd`

Baseline, untouched RTL, committed generator:

```
l2norm_rs: bit-exact with ref/l2norm_rs_vec.c on all 182 cases -- 46592
elements over both paths, 1 case(s) with ssq = 0 -- and within tolerance of
x/||x|| on every case -- worst 4.999352950867433e-1 output LSB at case 133,
bound TOL = 7.5e-1
```

Reproduction: a scratch copy of the generator with `x[i] = -32768` for all `i`
added, run against untouched RTL:

```
rtl/l2norm_rs.vhd:245:13:@30969ns:(assertion failure): l2norm_rs: ssq outside the u37 bound implied by N
/usr/bin/ghdl-mcode:error: assertion failed
in process .tb_l2norm_rs(sim).dut@l2norm_rs(rtl).P3
```

`SSQ_BITS` sizes nothing. MEASURED by grep: it occurs at `:128` (declaration),
`:245` (the compare) and `:246` (the message), and nowhere else. So the
structural question the brief raised -- whether `SSQ_BITS` sizes a signal --
is answered NO, and both candidate fixes were legal.

Fix: `:253` `assert ssq >= 0 and ssq <= shift_left(to_signed(1,64), SSQ_BITS)`,
and the message now names `SSQ_BITS + 1` so it prints "u38", agreeing with the
comment at `:90`.

**Why `<=` and not `SSQ_BITS = 31 + LOG2N`.** The exact maximum is
`N * 2^30 = 2^(30 + log2 N)`, so `<= 2^SSQ_BITS` is the bound the header states
and is tight. `< 2^(31 + LOG2N)` also admits the vector, but admits everything
below `2^38` with it: an accumulator that doubled would pass. The constant is
the exponent of the maximum, not a width; `2^37` needs 38 bits to represent,
which is why the author's comment and the author's constant disagreed by one
in the first place.

Permanent case: `ref/l2norm_rs_vec.c` section 6b, replacing the comment block
that carried the defect. Two cases -- the rail itself, and the value one below
it (`x[0] = -32767`, rest `-32768`) so the compare is bracketed from both
sides rather than only touched from the top.

After: 184 cases, `msb(ssq)` now covering `0..37` with both parities:

```
l2norm_rs: bit-exact with ref/l2norm_rs_vec.c on all 184 cases -- 47104
elements over both paths, 1 case(s) with ssq = 0 -- and within tolerance of
x/||x|| on every case -- worst 4.999352950867433e-1 output LSB at case 135,
bound TOL = 7.5e-1
```

The worst real-valued error is **the same number to every digit**
(4.999352950867433e-1); only the case index moved, by 2, which is the insertion.

Teeth, fix reverted, 184-case set:

```
l2norm_rs_orig.vhd:245:13:@30969ns:(assertion failure): l2norm_rs: ssq outside the u37 bound implied by N
/usr/bin/ghdl-mcode:error: simulation failed
```

### 4.3 OI-2, `rtl/attn_emit.vhd`

Baseline at the default `NGRP = 2`: PASS, 40 layers x 96 elements.

Reproduction at `-gNGRP=1`, untouched RTL:

```
/usr/bin/ghdl-mcode:error: bound check failure at rtl/attn_emit.vhd:400
in process .tb_attn_emit(sim).dut@attn_emit(rtl).P13
```

Fix: `grp <= 1` moved out of the straight-line part of `S_IDLE` and into the
`else` of the branch that already existed there, with `grp <= 0` in the
`NGRP = 1` arm. The branch was already present -- the author had thought about
`NGRP = 1` for the state, just not for the counter.

**Why this and not widening the range.** Widening `grp` would silence the abort
and leave a second, quieter defect: `S_SHIFTS` is entered directly at
`NGRP = 1` and reads `e_l(grp)`, so `grp = 1` would index element 1 of a
one-element array. `grp <= 0` is what the state actually needs.

Permanent case: `sim/tb_attn_emit.vhd` gains a SECOND instance, `dut1`, at
`NGRP => 1, GRP_N => NTOT`, started on every case alongside the main DUT.

**Why a second instance and not a second vector file.** `ref/attn_emit_vec.c`
gates its own output on a coverage table that requires "e_grid values that
DIFFER", and at one group that counter is structurally zero. So the generator
exits non-zero at `ngrp = 1` and `regress.sh` would read that as a failed
vector generation. Its GOLDEN at `ngrp = 1` is correct -- measured directly,
40 layers x 48 elements bit-exact after the fix -- so it is the coverage gate,
not the model, that cannot be met at one group. `ref/attn_emit_vec.c` belongs
to TRACK C-ORACLE and was not edited.

What `dut1` proves: on every case, `NTOT` mantissas in index order with `err`
low, which is all the bound violation needs since it aborts the run. On the
subset whose `e_grid` entries are all EQUAL, the one-group answer must be
bit-identical to the golden -- `e_min` is that common exponent, every alignment
shift is zero on both sides, and pass A scans the same `NTOT` elements, so
grouping cannot change `amax`, `shp`, any mantissa or `y_exp`. That subset is 8
of the 40 cases in the committed vector set, and the bench asserts at
`severity failure` if a future vector set makes it zero.

After:

```
tb_attn_emit: PASS -- 40 layers x 96 elements bit-exact ... A second instance
at NGRP=1 -- one KV head, a legal generic that used to be an immediate bound
violation -- ran the same 40 layers as ONE group of 96, in order and with err
low on every one, and matched the golden exactly on the 8 of them whose e_grid
entries are all equal.  M_GAP=3 ACK_LAG=4
```

and at `-gNGRP=1` (both instances at one group), 40 of 40 value-checked.

Teeth, fix reverted, NEW bench, at the gate's own DEFAULT generics:

```
/usr/bin/ghdl-mcode:error: bound check failure at attn_emit_orig.vhd:400
in process .tb_attn_emit(sim).dut1@attn_emit(rtl).P13
```

## 5. Measured and REJECTED -- do not retry

- **`SSQ_BITS = 31 + LOG2N` for OI-7.** It works, and it is the fix the issue
  text offered first. Rejected on measurement of what `SSQ_BITS` is used for:
  nothing but the assert, so there is no width forcing the choice, and the
  strict-`<`-at-38 form admits `2^38 - 1` where the true maximum is `2^37`.
  Half the detection for no benefit.
- **Growing `ybuf` to `array(0 to TILES)` for OI-8.** One extra word. Rejected
  because `TILES` is a power of two at the bench's own geometry (16), where
  going to 17 words rounds the inferred BRAM up a full step. Free at a ragged
  depth, not free at the depths that matter.
- **Gating the ybuf read on `rd_t < TILES`.** Rejected on the file's own
  recorded evidence: the read is unconditional so that it infers a BRAM read
  port, and that note is in the source at the line being changed.
- **Widening `grp`'s range for OI-2.** Rejected: it silences the abort and
  leaves `S_SHIFTS` reading `e_l(1)` of a one-element array at `NGRP = 1`.
- **Assuming pad rows are zero at every stage of `matvec_core`.** MEASURED
  false. The PARTIAL tap of a row whose weights are all index 0 is
  `sum(cb(0) * x)`, and `cb(0) = -127` in this trace, so it reads 3,328,416.
  It is the SCALE, one stage later, that zeroes the row. A bench that scores
  pad rows against a zero expectation reports 168 mismatches on a correct DUT.

## 6. Measurement traps hit

- **`cc ... 2>&1 | head -5` hides a compile failure.** The generator was
  rebuilt through a pipe, so `$?` was `head`'s, `set -e` did not fire, and the
  run used the STALE binary. It reported 182 cases -- the old count -- and
  looked exactly like "the new cases were not added". Rebuild without a pipe
  and check `rc` explicitly.
- **`ghdl -a` file order.** `rtl/fixed_pkg.vhd` uses `fixed_luts_pkg`, so
  analysing them in declaration-name order fails with "unit not found in
  library work" and then the run fails with "cannot find entity", which reads
  like a missing testbench rather than a missing dependency.
- **The full gate's plan generation raced a concurrent track.** The first full
  run died with `KeyError: 'sim/tb_attn_kv_axi.vhd'` / `plan generation
  failed`; both that file and `rtl/attn_kv_axi.vhd` had been written by
  TRACK C-KV in the same minute. Not a defect in anything here. Re-run.
- **A generator that exits non-zero can still have written a correct file.**
  `ref/attn_emit_vec.c` closes its output before running its coverage gate, so
  the `ngrp = 1` vectors are valid despite `rc = 1`. Reading only the exit code
  would have concluded, wrongly, that the one-group golden does not exist.

## 7. Not determined

- **Whether `ssq = 2^37` is reachable from `gdn_block`'s real activations.**
  Unchanged from OI-7 as filed. Spec 2.1.3's requantizer argues against it;
  that is an argument, not a measurement, and nothing here measured it. The
  fix makes the question moot for the assert, not for the design.
- **Synthesis cost of any of the three fixes.** No Vivado run was made. The
  ybuf address clamp adds a comparator against a constant plus a mux on
  `ceil(log2 TILES)` bits between the `rd_t` register and the BRAM address
  port; that path is timing-relevant in a file whose comments record it being
  timing-critical elsewhere. ESTIMATE only. The other two fixes add no logic
  (an assert, and a mux on a constant already selected at elaboration).
- **`matvec_core` writes `ybuf(re2_t)` at `:779` whenever `out_mode /= "10"`,
  and `S_IDLE` bounds `n_rows` against `MAXROWS_BFP` only when
  `out_mode = "00"`.** So `out_mode = "01"` can write past `TILES-1` on the
  same argument that produced OI-8. NOT reproduced and NOT fixed here: it is a
  different mode, no bench drives it, and it is outside the three defects
  assigned. Recorded so it is not rediscovered from scratch.
- ~~Whether the `MAXROWS_BFP = 192 / ROWS_IF = 48` geometry the finder used now
  passes.~~ **Answered in section 8 below, MEASURED.**

## 8. Appended -- lifting the two ceilings OI-8 imposed

TRACK A-SHAPE built the descriptor shape sweep in `sim/tb_matvec_fk33_desc.vhd`
and had to keep it BELOW the OI-8 trap, so the top corner of the row range was
unverified -- and that corner is exactly where an off-by-one in `tiles` would
show. Lifted after `cbb0457` landed, per the coordinator's direction:

- FK33 arm, `SH_ROWS`: `144 -> 192` and `144 -> 145`.
- AXU3EG arm, `BS_ROWS`: `57 -> 61` and `60 -> 64`.

**Two shapes were raised on each arm, not one.** `192 = 4*ROWS_IF` and
`64 = 16*B_RI` are exact multiples; `145` and `61` are not. Both give
`tiles = TILES`, and a ceil/floor error in `tiles` separates them, so raising
only the round one would have re-created a smaller version of the same gap.
`145` and `192` are also the two values the finder originally measured aborting.

`w_beats = tiles*nblk` must still stay within `MAXBEAT = 384` on the FK33 arm,
which at `tiles = 4` caps `n_cols` at `96*BLK = 3072`; the new pairings are
`(192, 1024)` at 128 beats and `(145, 32)` at 4 beats.

**Result: every legal shape in the newly-reachable top corner is ACCEPTED.**
No legal shape is refused, so there is no off-by-one in the shape check at its
top corner.

```
shape sweep, FK33 arm (ROWS_IF=48, GRP=1): 10 legal shapes accepted,
    38 one-off beat-count mutations refused
shape sweep, AXU3EG arm (ROWS_IF=4, GRP=2): 9 legal shapes accepted,
    32 one-off beat-count mutations refused
tb_matvec_fk33_desc: 22 cases run, 0 failures
subsystem A is bit-exact with ref/matvec_int4.c through the descriptor control
    plane, and every checked mutation is refused
```

The case counts are unchanged by the lift, which is what says no case was lost
in the swap. DERIVED and consistent with the numbers: 10 shapes x 5 variants
minus the 2 skips that only shape `(1, 32)` can produce (`wbx = sbx = 1`, so
`k = 1` and `k = 3` land on zero) is `10 + 38`; 9 x 5 minus the 4 skips from
`(1, 32)` and `(3, 32)` is `9 + 32`. Neither skip count depends on the top
entries.

**Teeth on the lift, and it answers section 7's open item.** The lifted bench
was run against `cbb0457^`'s `matvec_core`, i.e. with the OI-8 fix reverted, at
the FK33 geometry `MAXROWS_BFP = 192 / ROWS_IF = 48`:

```
/usr/bin/ghdl-mcode:error: index (4) out of bounds (0 to 3) at matvec_core.vhd:835
/usr/bin/ghdl-mcode:error: simulation failed
```

That is the finder's original message, verbatim, at the finder's original
geometry. So the new shapes genuinely reach the trap, the lift has teeth, and
the fix is now MEASURED at `192/48` and not merely derived from `64/4`.

**One weakness in that sweep, pre-existing and NOT introduced here.** The FK33
arm's accept test polls for `done or err` with a 40,000-iteration timeout and
then judges on `err`. A shape that HANGS therefore scores as accepted, because
neither bit is set. So "10 legal shapes accepted" is not by itself proof that
the top-corner jobs completed. What proves it here is that the run finished at
all: with the defect present, GHDL kills the process. Worth closing if the
sweep is ever relied on for liveness rather than for the shape check.
