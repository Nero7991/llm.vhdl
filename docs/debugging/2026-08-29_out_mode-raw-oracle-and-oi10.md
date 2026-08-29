# `out_mode` raw: the missing oracle, and OI-10 reproduced

Date: 2026-08-29. Branch `fpga`, base `a2b20f3`. GHDL 1.0.0 mcode, `--std=08`.
Track: OUTMODE. No hardware was touched.

## 1. The question, verbatim

> **`out_mode` 1 and 2 are never executed by anything.** TRACK A-PROGRAM said
> descriptors for them are "byte-checked but never run"; TRACK RANGE and
> TRACK D-PROG each independently listed them as unexercised.
>
> **OI-10 is the concrete consequence.** `rtl/matvec_core.vhd:779` writes
> `ybuf(re2_t)` whenever `out_mode /= "10"`, while `S_IDLE` bounds `n_rows`
> against `MAXROWS_BFP` **only when `out_mode = "00"`**. So `out_mode = "01"`
> can write past `TILES-1`.
>
> 1. Build the bench first. Drive `out_mode = "01"` and `out_mode = "10"`
>    through `matvec_core` and check the results bit-exactly against
>    `ref/matvec_int4.c`. 2. Then reproduce OI-10. 3. Then fix it minimally.
>    4. Teeth-check. 5. OI-11 if time allows.

## 2. The answer

**OI-10 reproduces, exactly as filed, and is fixed.** The premise it was filed
under is half right and the correction matters:

- `out_mode = "10"` (partial) was **already run and already value-checked**
  against `ref/matvec_int4.c` by `sim/tb_matvec_core.vhd` PASS 2, which
  compares `y_data` against the trace's `ACC` line. The claim that mode 2 is
  never executed is **wrong for the core bench** (it is true at the descriptor
  level, where `tools/verify_mv4i_desc.py` only byte-checks).
- `out_mode = "01"` (raw) **was** driven, by exactly one bench --
  `sim/tb_matvec_cb_lockstep.vhd`, at one tile of `ROWS_IF` rows -- and that
  bench compares four runs **against each other**, never against the C
  reference. So it is a round trip, not an oracle, and the mode had no
  numeric check anywhere in the tree.

The raw-mode oracle needed **no new vector**: `ref/matvec_int4.c` already
writes a `YDATA` line inside `mv4i_matvec` on every non-partial pass, and that
value IS the raw payload. `sim/tb_matvec_core.vhd`'s loader was dropping the
line.

**OI-10, MEASURED:** at `MAXROWS_BFP = 64 / ROWS_IF = 4` (so `TILES = 16`),
`out_mode = "01"` with `n_rows = 65`:

```
ghdl-mcode:error: index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:839
```

with the *same 65 rows in partial mode* passing in the pass immediately before
it. It needs `n_rows > MAXROWS_BFP`, which spec 7.6's mode table makes **legal**
in raw ("in raw mode `M` may exceed `MAXROWS_BFP`", the `lm_head` being the
caller that needs it) and which `S_IDLE` therefore does not reject. It is *not*
reachable at `n_rows = MAXROWS_BFP` -- that is OI-8's corner, on the read side.

**The fix narrows the write ENABLE (`out_mode = "00"`), it does not clamp the
address** the way OI-8's fix did. Reasoning in section 5.

**OI-11 is closed for the arm it was filed against, and that arm was already
fixed before it was filed.** See section 7. A residual gap on the *other* arm
is closed here.

## 3. The procedure, in the order it was run

Reproduction came before any RTL edit, and the bench came before the
reproduction, because a defect in a mode nothing drives cannot be seen.

1. **Read what each `out_mode` means from the RTL, then from the spec**, and
   record where they disagree (they do not, here).
2. **Baseline** `sim/tb_matvec_core.vhd` on untouched RTL, with element counts,
   so "nothing else moved" later has a number attached.
3. **Give the bench an oracle for raw** by parsing the `YDATA` line the trace
   already carries, and check `y_exp` for raw and partial from spec 7.6/14.2
   arithmetic on the trace's own `DIMS`, not from the BFP answer.
4. **Close the value hole above the trace's `M`.** Every masked row now carries
   an expectation; rows above `M` are fed index 0 with SCALE 0 and are scored
   against **zero** instead of being skipped. This is the specific hole TRACK
   DIVIDE's mutation M3 walked through: shapes that were run but only
   completion-checked.
5. **Walk the shape up to and past the bound, in both no-buffer modes**, with
   partial at the same illegal-for-BFP row count as the CONTROL. The control is
   what separates "anything above `MAXROWS_BFP` breaks" from "the ybuf write
   breaks"; without it PASS 8 does not localize.
6. **Fix, and state why that form rather than the alternative.**
7. **Teeth**: revert, confirm the new case fails, restore; plus four further
   mutations, one of which does NOT bite and is reported under its own name.

## 4. What each `out_mode` means, with citations

From `rtl/matvec_core.vhd` (the RTL wins where a document disagrees):

| mode | payload | buffer | `y_exp` | `n_rows` bound |
|---|---|---|---|---|
| `"00"` BFP | `sat16(round_shift(y_data, ns))`, one shared `ns` over all rows | `ybuf`, `:839` | `w_exp + x_exp - os_r - ns_r` (`:1006`) | `n_rows > MAXROWS_BFP` **rejected**, `:921` |
| `"01"` raw | `sat32(round_shift(acc, out_shift))` sign-extended to 64 (`:833`) | none | `w_exp + x_exp - os_r` (`:1007`) | **unbounded** -- `:921` gates the check on `out_mode = "00"` |
| `"10"` partial | the UNROUNDED s48 accumulator (`:829`), no `sat32` (`:817`) | none | `w_exp + x_exp` (`:1005`) | unbounded |

`S_EMIT` is reachable only through `S_SCAN`, and `:944` enters `S_SCAN` only
when `out_mode = "00"`. That is the line that makes the raw-mode `ybuf` write
dead as well as out of range.

Spec `docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md` 7.6
agrees on all three rows, and is the source for "in raw mode `M` may exceed
`MAXROWS_BFP`" and "`n_rows > MAXROWS_BFP` is legal in partial mode (no output
buffer is used)".

## 5. The evidence

### 5.1 Baseline, untouched RTL and untouched bench

```
sim/tb_matvec_core.vhd:427:@535ns: BFP: 64 stage values compared, 0 mismatches, ns=6 y_exp=-2
sim/tb_matvec_core.vhd:498:@1715ns: TOTAL: 184 stage + 24 output values compared, 0 mismatches (BFP, PARTIAL and the top of the row range at n_rows = 64)
sim/tb_matvec_core.vhd:506:@1715ns: RTL matches ref/matvec_int4.c at every stage
GHDL_EXIT=0
```

24 output values: 8 (BFP) + 8 (partial) + 8 (top-of-range, where only the rows
below the trace's `M = 8` were scored at all).

### 5.2 OI-10, reproduced on untouched RTL with the new bench

```
sim/tb_matvec_core.vhd:530:@535ns:  BFP: 64 stage values compared, 0 mismatches, ns=6 y_exp=-2
sim/tb_matvec_core.vhd:471:@1735ns: PASS 4 RAW: out_mode=01 n_rows=8
sim/tb_matvec_core.vhd:471:@2025ns: PASS 5 RAW ragged top tile: out_mode=01 n_rows=61
sim/tb_matvec_core.vhd:471:@2735ns: PASS 6 RAW full top tile: out_mode=01 n_rows=64
sim/tb_matvec_core.vhd:471:@3445ns: PASS 7 PARTIAL above MAXROWS_BFP: out_mode=10 n_rows=65
sim/tb_matvec_core.vhd:471:@4185ns: PASS 8 RAW above MAXROWS_BFP: out_mode=01 n_rows=65
/usr/bin/ghdl-mcode:error: index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:839
in process .tb_matvec_core(sim).dut@matvec_core(rtl).P6
/usr/bin/ghdl-mcode:error: simulation failed
GHDL_EXIT=1
```

Read the last three lines together. PASS 6 is raw at exactly `MAXROWS_BFP`, and
it passes -- so the write is fine everywhere the BFP bound admits. PASS 7 is
**partial** at 65 rows, one past the bound, and it passes -- so the row count
alone is not the problem. PASS 8 is the same 65 rows one mode over, and it
aborts. That triple is the localization.

### 5.3 With the fix

```
sim/tb_matvec_core.vhd:679:@4905ns: TOTAL: 464 stage + 343 output values compared, 0 mismatches (BFP, PARTIAL, RAW, the top of the row range at n_rows = 64 and both no-buffer modes above it at n_rows = 65)
sim/tb_matvec_core.vhd:688:@4905ns: RTL matches ref/matvec_int4.c at every stage, in all three out_mode values
GHDL_EXIT=0
```

343 output values, DERIVED and matching exactly:
`8 (BFP) + 8 (partial) + 64 (BFP top) + 8 (raw) + 61 (raw ragged top) +
64 (raw top) + 65 (partial above) + 65 (raw above) = 343`, against 24 before.
464 stage values, DERIVED: per job the taps score 24 PARTIAL + 24 CONTRIB + 8
ACC for the rows the trace describes, plus 8 YMANT in BFP mode only, so
`64 + 56 + 64 + 5*56 = 464`, against 184 before.

### 5.4 The fix

`rtl/matvec_core.vhd`, one line plus its comment:

```vhdl
-  if out_mode /= "10" then ybuf(re2_t) <= ynew; end if;
+  if out_mode = "00" then ybuf(re2_t) <= ynew; end if;
```

**Why the write enable and not OI-8's address clamp.** OI-8 clamped because
that access is a **read** which has to stay unconditional to infer the BRAM
read port -- the code says so at the line itself. This one is a **write**, and
its condition already IS the write enable, which is exactly how a BRAM write
port is inferred; narrowing an existing enable changes nothing about
inference. The alternative was measured, see M6 below: it also removes the
abort, and this bench cannot tell the two apart. The argument for the enable is
therefore not an experimental result, it is these three points:

- `ybuf` is the BFP output buffer and nothing else (spec 7.6's Buffering
  column: BFP into the output buffer, raw none, partial none), so a write in
  raw mode is dead by contract, not merely unread today.
- The clamped-address version keeps firing a dead write into tile `TILES-1` on
  every raw job past the bound, making the buffer's contents depend on a mode
  that is specified not to touch it.
- It puts a comparator in the BRAM write-address path for no gain.

Neither version needs the range on `re2_t` that OI-8 gave `rd_t`: with the
enable narrowed, `re2_t < TILES` is guaranteed by the `n_rows <= MAXROWS_BFP`
check `S_IDLE` **already** performs in that mode.

### 5.5 Teeth

Every mutation was applied to the FIXED RTL except M1, which is the fix
reverted. Restored and re-run green after each.

| # | mutation | result |
|---|---|---|
| **M1** | the fix reverted: `if out_mode /= "10" then ybuf(re2_t) <= ynew` | **BITES.** `index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:865`, at PASS 8 |
| **M2** | raw emits the UNROUNDED accumulator (`if out_mode = "10"` -> `/= "00"` at the `y_data` select) | **BITES.** `Y MISMATCH mode=01 r=0 got -6953700 want -869212`, and 7 more, at PASS 4 |
| **M3** | raw `y_exp` carries an `ns` term (`w_exp + x_exp - os_r - ns_r`) | **BITES.** `PASS 4 RAW: RAW y_exp got -2 want 4 -- raw carries out_shift and NO ns term` |
| **M4** | one row dropped from the last tile (`rbase + rr < n_rows - 1`) | **BITES.** `PASS 4 RAW COVERAGE: 7 rows out of the port, expected 8` |
| **M5** | the WRONG fix: suppress the output beat above the BFP tile capacity (`out_mode /= "00" and re2_t < TILES` on `y_we`) | **BITES**, and at the CONTROL: `PASS 7 PARTIAL above MAXROWS_BFP COVERAGE: 64 rows out of the port, expected 65` |
| **M6** | the ALTERNATIVE fix: `if out_mode /= "10" then ybuf(ybuf_addr(re2_t)) <= ynew` | **DOES NOT BITE.** `TOTAL: 464 stage + 343 output values compared, 0 mismatches`, `GHDL_EXIT=0` |

**M6 is the most useful row here.** It measures the bench's resolution floor:
this bench cannot distinguish narrowing the write enable from clamping the
write address, and it never will be able to, because neither is observable at
the output -- nothing reads `ybuf` in raw mode by construction. The choice
between them is an argument about the buffer's contract and about synthesis,
and it is settled in 5.4 by argument, not by measurement. Do not read the green
PASS as evidence for the form of the fix; it is evidence only that the
out-of-range access is gone.

**M5 is the second most useful.** The obvious wrong fix -- "clamp the job to
the buffer" -- is caught by the *partial* control, not by the raw case that
motivated the change.

## 6. Measured and REJECTED -- do not retry

- **`n_rows = MAXROWS_BFP` in raw mode does NOT reproduce OI-10.** PASS 6 runs
  exactly that and passes on unfixed RTL. The write pointer `re2_t` reaches
  `tiles - 1`, not `tiles`; only OI-8's read pointer runs one past. The
  worklog's phrase "on exactly the argument that produced OI-8" is therefore
  not right: OI-8 needs `n_rows` in the top `ROWS_IF` rows *of* the range, and
  OI-10 needs `n_rows` **above** the range. Do not look for OI-10 at the top
  corner; it is not there.
- **Partial mode above `MAXROWS_BFP` is not affected**, measured at the same
  65 rows (PASS 7), before and after the fix. `:839` already excluded `"10"`.
- **A new `sim/tb_*.vhd` was deliberately NOT added.** The gate auto-discovers
  one, which would have forced a `BASELINE_PASS` change in `sim/regress.sh` --
  a shared file with another track's edit in flight at the time. Everything
  here fits in the bench that already instantiates the unit.

## 7. OI-11, and a correction to it

OI-11 says the FK33 arm of `sim/tb_matvec_fk33_desc.vhd` "judges a legal shape
by checking `err` after a bounded poll", so a hang scores as an acceptance.

**MEASURED at HEAD: that is not what the FK33 arm does.** Its `k = 0` branch
is `if st(2) = '1' then ... REFUSED ... elsif st(0) /= '1' then ... "is LEGAL
and never completed (timeout N)"`, so a hang exits the poll with both bits
clear and is scored as a failure. `git log -S"is LEGAL and never completed"`
puts that line in `f693faf`, which **predates** `7ccc239`, the commit that
lifted the sweep ceilings and under which OI-11 was filed. So the FK33 arm was
already fixed when the issue was written, and OI-11 is withdrawn for that arm.

**The residual gap is the AXU3EG arm**, and it is real. That arm ties off the
weight masters, so an accepted descriptor never completes by design, and the
comment says so: "the verdict is read after a fixed, generous window rather
than by polling for done". Its `k = 0` branch tests only `bst(2) = '1'`. A
design that silently did nothing at all -- never started, never errored --
scores as an acceptance there, which is the same silent-success shape OI-11
names.

Closed by requiring the accepted descriptor to be **running**: after the
window, `busy` (STATUS bit 1) must be set and `done` (bit 0) clear. That is the
only completion-class statement available on an arm where completion cannot
happen, and it is exactly the one that separates "accepted and running" from
"accepted and inert".

**TEETH, MEASURED.** An RTL mutant that never raises `busy` on the accepted
path (`busy <= '1'` -> `busy <= '0'` in `matvec_int4_desc_axi`'s `S_IDLE` GO
branch), compiled from a scratch override so the repo file was never touched:

```
# HEAD's bench, mutant RTL -- the whole thing passes
tb_matvec_fk33_desc.vhd:1205: shape sweep, FK33 arm (ROWS_IF=48, GRP=1): 10 legal shapes accepted, 38 one-off beat-count mutations refused
tb_matvec_fk33_desc.vhd:1283: shape sweep, AXU3EG arm (ROWS_IF=4, GRP=2): 9 legal shapes accepted, 32 one-off beat-count mutations refused
tb_matvec_fk33_desc.vhd:1476: tb_matvec_fk33_desc: 22 cases run, 0 failures
GHDL_EXIT=0

# the new check, same mutant -- 9 of 9 legal AXU3EG shapes fail
tb_matvec_fk33_desc.vhd:1283:13:(report error): AXU3EG SHAPE n_rows=1 n_cols=32 w_beats=1 s_beats=1 was neither refused nor left RUNNING: busy='0' done='0' ...
```

Both shape sweeps and all 22 descriptor cases were blind to it. That is the
measurement that says the gap was real rather than theoretical.

## 8. Not determined

- **Whether any real `lm_head` descriptor reaches `n_rows > MAXROWS_BFP` in
  raw mode on the FK33 build.** Spec 7.6 names `lm_head` as the caller that
  needs it and `MAXROWS_BFP` is 17408 while the vocabulary is far larger, so it
  is expected, but no program in this repo was measured issuing one. The defect
  is fixed either way; what is unmeasured is whether it was latent or live.
- **Synthesis impact.** Nothing was run through Vivado for this change. The
  claim that narrowing an already-conditional write does not change BRAM
  inference is an argument from how write enables infer, labelled ESTIMATE, not
  a measured utilization delta.
- **`out_mode` at the DESCRIPTOR level.** This closes the core's contract for
  raw and partial. `rtl/matvec_int4_desc_axi.vhd` accepts `out_mode` 0..2 and
  refuses 3..255 (case 8 of `tb_matvec_fk33_desc`), but no descriptor-level
  bench runs a job with `out_mode` 1 or 2 end to end. That remains open.
- **`out_mode = "01"` through `matvec_int4` / `matvec_int4_axi` / the FK33
  weight streamer.** Only the core was driven in raw mode here.
