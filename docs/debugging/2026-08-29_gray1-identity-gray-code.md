# The gray code is now checked as a gray code, because neither existing instrument could be

**Date:** 2026-08-29
**Track:** GRAY1, row N10
**Tooling:** GHDL 1.0.0 (mcode backend) for everything that runs a design unit;
Vivado 2023.2 (lin64, build 4029153) `report_cdc` over out-of-context synthesis
at `xcvu33p-fsvh2104-2L-e`, **no place, no route, no hardware**.
**Pinned sha:** `b39c389a10a3581bc6b86330b6c8fc75fb2013aa` (re-read as its own
step; HEAD was `3853650` when this track started and had moved before the first
measurement, which is why every mutation below is applied to a `git archive` of
the pinned sha or to a copy, never to `rtl/`).
**Files added:** `sim/gray_check.sh`, `sim/mutate_gray.sh`,
`sim/gray_skew_demo.vhd`, this file.
**Files changed:** `sim/regress.sh` (one appended plan row `sim:graygate` and
one dispatch function, +60 lines, no existing row's code path altered).
**`rtl/async_fifo.vhd` IS NOT CHANGED.** It is in the datapath measured
computing bit-exactly on the FK33 tonight; this track delivers only checking.
Verified: `git status --porcelain -- rtl/` shows no line for it.

---

## 1. The question, verbatim

> TRACK CDC-STATIC (`be982b3`, `sim/cdc_teeth.sh`,
> `docs/debugging/2026-08-29_cdc-static-analysis.md`) closed two of three
> gray-coding defect classes: the encoder/decoder MISMATCH (`G2`) is caught by
> simulation, and the 2FF-vs-1FF MTBF class by `report_cdc`.
>
> **`G1` -- both gray functions replaced by identity -- is caught by NEITHER.
> And it is worse than uncaught:**
>
> > the binary-pointer design reports **TWO FEWER** `report_cdc` warnings than
> > the correct one, so any "the report must not get worse" rule **passes it**.
>
> **What to build.** A check that **kills G1**. Establish first, by
> measurement, why the existing two cannot: why simulation does not catch it (a
> synchronous testbench may never produce the multi-bit-transition case that
> gray coding exists to prevent -- if so, say what stimulus WOULD); why
> `report_cdc` reports *fewer* warnings, not more. Then close it. ... **Teeth
> are the entire deliverable.** ... **Build the attribution control in from the
> start.**

---

## 2. The answer, up front

### 2.1 `G1` is dead, and it is dead for the right reason

`sim/gray_check.sh` extracts the bodies of `bin2gray` and `gray2bin`
**verbatim** out of `rtl/async_fifo.vhd`, drops them unchanged into a
standalone probe entity that supplies only `AW` and `ptr_t`, and evaluates them
over **every value of the pointer at every width from 2 to 14 bits** -- 32,752
pointer values in total, exhaustive, deterministic, 1 second. Four properties:

| property | statement | why it is here |
|---|---|---|
| `P_GRAY` | `hamming(enc(b), enc(b+1 mod 2**N)) = 1` for every `b`, wrap included | this is what a gray code IS. The identity violates it at `b=1` |
| `P_BIJ`  | `enc` is injective over the whole pointer space | `P_GRAY` alone does not imply it, and a non-injective pointer aliases full to empty |
| `P_INV`  | `dec(enc(b)) = b` for every `b` | the encoder/decoder disagreement class |
| `P_ZERO` | `enc(0) = 0` | NOT a property of gray codes; a property **this RTL** requires, because reset and the four-phase clear each park `wp` at 0 and `wp_g` at 0 by two independent assignments |

MEASURED, the gate row on the pinned tree with `G1` applied and then reverted:

```
=== 1. GREEN before the mutation ===
PASS       sim:graygate     0s  GRAY_CHECK: PASS  (13 widths, pointer 2..14 bits, all exhaustive)
=== 2. APPLY G1 ===
FAIL       sim:graygate     1s  GRAY_CHECK: FAIL  (13 of 13 widths violate a property) P_GRAY VIOLATED first at b=1 N=2: enc(b)=1 enc(b+1)=2 hamming=2
=== 3. REVERT ===
PASS       sim:graygate     1s  GRAY_CHECK: PASS  (13 widths, pointer 2..14 bits, all exhaustive)
```

**The attribution control, at gate level, on the SAME mutated tree:**

```
PASS       sim:tb_async_fifo   1s  ...:@76031500ps:(report note): PASS: tb_async_fifo
```

So the kill belongs to the new check and to nothing else. That control is the
reason this section can say "dead" rather than "went red".

### 2.2 CORRECTION to the brief and to CDC-STATIC 2.1: it is not two fewer *warnings* any more, it is two fewer *Infos*, and that is WORSE

The brief and `docs/debugging/2026-08-29_cdc-static-analysis.md` both state
that `G1` produces **two fewer `report_cdc` warnings**. That was true of the
tree as it stood **before** CDC-STATIC's own `ASYNC_REG` fix, and it is no
longer true of the tree that fix produced. Re-measured first-hand, this track,
`sim/cdc_teeth.sh` rows `BASE`, `G1`, `G2` at the pinned sha:

| | CDC-3 Info | CDC-6 Warning | CDC-10 Critical | total detail rows | sequential cells |
|---|---|---|---|---|---|
| `BASE` (honest) | **5** | 2 | 1 | **8** | 577 |
| `G1` (binary pointers) | **3** | 2 | 1 | **6** | 559 |
| `G2` (decoder identity) | 5 | 2 | 1 | 8 | 577 |

**The Warning count and the Critical count are BIT-IDENTICAL between the honest
design and the defective one.** Only two `Info` rows disappear. So the trap the
brief names is not merely that a "must not get worse" rule passes `G1`: a rule
phrased on Warnings or Criticals -- which is how every CDC sign-off rule this
project would plausibly write is phrased -- sees **no change at all**. The
defect is invisible, not just unpunished. A rule phrased on the total row count
sees an improvement.

`G2` is byte-identical to `BASE` in every field of the signature, which is the
teeth-check for the claim: the static flow is blind to the pointer **encoding**
as such, and not merely to the identity case.

### 2.3 The mechanism, MEASURED rather than argued

The raw rows say exactly why (`rp` direction shown; `wp` is the mirror image):

```
BASE:
  2  CDC-6  Warning  Multi-bit synchronized with ASYNC_REG   2  g_dc.fifo/rp_g_reg[8:0]/C -> g_dc.fifo/rp_g_s1_reg[8:0]/D
  3  CDC-3  Info     1-bit synchronized with ASYNC_REG       2  g_dc.fifo/rp_reg[9]/C     -> g_dc.fifo/rp_g_s1_reg[9]/D
G1:
  2  CDC-6  Warning  Multi-bit synchronized with ASYNC_REG   2  g_dc.fifo/rp_reg[9:0]/C   -> g_dc.fifo/rp_g_s1_reg[9:0]/D
```

DERIVED from those two lines: with gray coding the MSB of the gray code IS the
MSB of the binary counter, so synthesis sources bit 9 straight off `rp_reg` and
the crossing splits into a 9-bit bus (`CDC-6`) plus one bit (`CDC-3`). Remove
the gray coding and all ten bits come off `rp_reg` as one bus, so the 1-bit row
merges into the multi-bit row and disappears. Twice, once per direction.

DERIVED, the sequential-cell count: 577 - 559 = 18 = 2 x 9. With the identity,
`wp_g` is bit-identical to `wp` and `rp_g` to `rp`, so synthesis merges each
pair and removes their nine non-MSB flops; the MSBs were already shared, which
is why the number is 18 and not 20.

One consequence worth naming because it looks like a way out and is not: a
reviewer *could* spot `G1` by noticing the source pin changed from `rp_g_reg`
to `rp_reg`. That is a signal-**name** heuristic, not a rule Vivado offers, and
it evaporates on any rename. It is not a check.

### 2.4 Why simulation cannot catch it, and what stimulus WOULD

Not "the testbench is too tame". `sim/tb_async_fifo.vhd` drives eight clock
ratios including 7000 ps against 6999 ps so the phase sweeps through every
alignment, and `G1` survives all eight. The reason is that **the event gray
coding exists to survive is not in the model**: an RTL simulator assigns a
whole `unsigned` in one delta, so a multi-bit bus is never observed part-way
through a transition. No sequence of writes and reads can produce an event the
model does not represent, and the identity is a bijection with `enc(0)=0`, so a
binary-pointer FIFO computes the same numbers as a gray-pointer one on every
cycle.

What WOULD catch it is a different **model**, not a different testcase: give
each bit of the crossing bus its own propagation delay. `sim/gray_skew_demo.vhd`
does exactly that, with the identical stimulus and identical per-bit skew run
twice. MEASURED (section 4.1): **0 corrupt samples of 2791 with gray coding,
160 corrupt of 2791 without** -- 5.7% of all samples decoding to a value the
write counter never held.

That file is deliberately **not** named `sim/tb_*.vhd`. `sim/regress.sh` globs
that pattern off the filesystem, so anything matching it becomes a permanent
gate row for every track. It is a demonstration of a hazard, not a check of the
design, and it is run by hand.

### 2.5 Why the STRUCTURAL check and not the simulation one

The brief offered three approaches and asked for a deliberate choice.

**Chosen: structural, exhaustive, over the RTL's own bytes.** It is total (not
sampled), it terminates in 1 second, its verdict does not depend on a clock
ratio or a seed, and it is a statement about a pure function -- which is what
the defect actually is. A gate row must be deterministic or tracks learn to
re-run it.

**Rejected: the adversarial-clock-ratio simulation** as the *gate*. The brief
itself names the problem -- it is a probabilistic check dressed as a
deterministic one -- and section 5 records the specific reason it cannot be
made deterministic here without becoming a different design. Kept as
`sim/gray_skew_demo.vhd`, run by hand, for what it demonstrates rather than
what it guards.

**Rejected: a `report_cdc` rule change.** 2.2 measures why: the metric moves
the wrong way, and no phrasing over rule IDs and severities separates `BASE`
from `G1` at all, because Vivado classifies a crossing by topology and has no
concept of an encoding.

---

## 3. The procedure, in the order it was run

Each step says what it controls for.

1. **Re-read the pinned sha as its own command** before anything else, and
   again before the archive export. HEAD moved between the two.
2. **Run the honest RTL through the new check first.** A table measured against
   a check that is not green on the honest RTL measures nothing.
3. **Re-measure `report_cdc` first-hand** on `BASE`, `G1` and `G2` rather than
   quoting the existing write-up. This is what found the correction in 2.2:
   the quoted claim was true of a tree that no longer exists.
4. **Run every mutation through BOTH columns** -- the new check and the
   pre-existing `sim/tb_async_fifo.vhd` -- on the SAME mutant bytes. The
   attribution control. Without it this table would claim five kills where it
   deserves one.
5. **Teeth the check's own failure modes, not only the defect.** Rows `NF`,
   `DUP` and `VD` exercise the shape gate and the VOID path. A harness in this
   repo once scored 7 of 7 CAUGHT because ghdl could not open a file.
6. **Teeth the check's RESOLUTION FLOOR.** Row `GY` replaces both functions
   with a *different but entirely valid* gray code and must PASS. A check that
   reddens there is matching the source text, not the property.
7. **Teeth the gate row, not just the script**, by applying `G1` to a
   `git archive` of the pinned sha and running `sim/regress.sh --only graygate`
   against it -- so what is shown red is the thing that will actually run.
8. **Prove the repo file was never touched.** `git status --porcelain -- rtl/`,
   and `diff` of the exported tree's `rtl/async_fifo.vhd` against the working
   copy after the revert.

---

## 4. The evidence, raw

### 4.1 `sim/gray_skew_demo.vhd` -- the same stimulus, the same skew, both encodings

```
=== USE_GRAY=true ===
gray_skew_demo.vhd:164:5:@12003450ps:(report note): GRAY_SKEW_DEMO use_gray=true N=12 samples=2791 corrupt=0 from_the_future=0 went_backwards=0
=== USE_GRAY=false ===
gray_skew_demo.vhd:147:11:@70950ps:(report note): SKEW SAMPLE FROM THE FUTURE: decoded 28 while the counter holds 24
gray_skew_demo.vhd:155:11:@75250ps:(report note): SKEW SAMPLE WENT BACKWARDS: decoded 25 after 28
gray_skew_demo.vhd:155:11:@131150ps:(report note): SKEW SAMPLE WENT BACKWARDS: decoded 40 after 42
gray_skew_demo.vhd:147:11:@359050ps:(report note): SKEW SAMPLE FROM THE FUTURE: decoded 124 while the counter holds 120
gray_skew_demo.vhd:164:5:@12003450ps:(report note): GRAY_SKEW_DEMO use_gray=false N=12 samples=2791 corrupt=160 from_the_future=49 went_backwards=111
```

`decoded 28 while the counter holds 24` is the textbook case in the wild:
24 = `011000`, 28 = `011100`; the counter was passing 23 -> 24 (`010111` ->
`011000`, five bits) and the receiver sampled a pattern that was neither. In
`rtl/async_fifo.vhd` that value lands in `rp_bin_w`, and `used_w <= wp -
rp_bin_w` then reports an occupancy that never existed -- in the direction that
makes the AR throttle believe there is space.

### 4.2 `sim/cdc_teeth.sh` signatures, `BASE` / `G1` / `G2`

```
BASE   ASYNC_REG=50/577 SRL=0 | rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2 | rows=CDC-10/d2/Asynch_Clock_Groups,CDC-3/d2/...x5,CDC-6/d2/...x2
G1     ASYNC_REG=50/559 SRL=0 | rules=CDC-10:Critical:1,CDC-3:Info:3,CDC-6:Warning:2 | rows=CDC-10/d2/Asynch_Clock_Groups,CDC-3/d2/...x3,CDC-6/d2/...x2
G2     ASYNC_REG=50/577 SRL=0 | rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2 | rows=CDC-10/d2/Asynch_Clock_Groups,CDC-3/d2/...x5,CDC-6/d2/...x2
```

`G2` is identical to `BASE` in every field. Peak RSS 3,588,532 KB per run, well
inside the 6 G scope cap.

### 4.3 `sim/mutate_gray.sh` -- the full table, with the attribution column

Every row landed as predicted; the harness prints
`<<< NOT AS PREDICTED` beside any that does not, and none did.

```
=== control: the UNMUTATED rtl/async_fifo.vhd ===
CTRL  gray=PASS     tb=SURV

---- class IDENTITY: the defect neither existing instrument reaches ----
G1    gray=FAIL     tb=SURV    NEW CHECK ONLY  BOTH functions become the identity -- pointers cross as plain BINARY
        gray: P_GRAY VIOLATED first at b=1 N=2: enc(b)=1 enc(b+1)=2 hamming=2
        tb  : 0 errors across 8 clock ratios
G1E   gray=FAIL     tb=KILL    both            only the ENCODER becomes the identity
        tb  : eq_ph90: w_level 7 UNDER-STATES occupancy 8
G2    gray=FAIL     tb=KILL    both            only the DECODER becomes the identity
        gray: P_INV VIOLATED
        tb  : eq_ph90: w_level 7 UNDER-STATES occupancy 8

---- class WRONG-CODE: bijective, invertible, but not single-bit-change ----
GZ    gray=FAIL     tb=KILL    both            the encoder shifts LEFT
        gray: P_GRAY VIOLATED
GX    gray=FAIL     tb=KILL    both            COMPLEMENT gray -- a real gray code, but enc(0) /= 0
        gray: P_ZERO VIOLATED
        tb  : eq_ph90: q_valid HIGH OUT OF RESET

---- THE RESOLUTION FLOOR: a DIFFERENT but entirely valid gray code ----
GY    gray=PASS     tb=SURV    NEITHER         BIT-REVERSED gray code -- correct, and must survive

---- class MTBF: NOT this check's business ----
G3    gray=PASS     tb=SURV    NEITHER         read pointer crosses through ONE flop, not two
G4    gray=PASS     tb=SURV    NEITHER         write pointer crosses through ONE flop, not two
C6    gray=PASS     tb=SURV    NEITHER         the clear request crosses through ONE flop, not two

---- class SHAPE and VOID: teeth for this check's own failure modes ----
NF    gray=NOSHAPE  tb=SURV    SHAPE GATE      bin2gray RENAMED to b2g -- functionally identical
        gray: found 0 definitions of `bin2gray', expected exactly 1
DUP   gray=NOSHAPE  tb=VOID    SHAPE GATE      a SECOND bin2gray is added
        gray: found 2 definitions of `bin2gray', expected exactly 1
VD    gray=VOID     tb=VOID    VOID-HOLE       encoder body made SYNTACTICALLY INVALID -- must be VOID, never a kill

=======================================================================
rows=12   NEW CHECK ALONE=1   both=4   old bench only=0   NEITHER=4   shape gate=2   VOID=1
```

**Read the summary honestly: this check earns exactly ONE kill of its own.**
Four more rows it reddens were already killed by `sim/tb_async_fifo.vhd`, and
without the attribution column the table would have claimed five. That one kill
is the whole justification for the file, and it is enough, because it is the
only instrument in the repository that reaches that class at all.

**Rows that do NOT bite, under their own names** -- the resolution floor:

- **`GY` (bit-reversed gray).** Green on both columns, **correctly**. It is
  bijective, single-bit-change, and `enc(0)=0`, so it is a perfectly valid
  encoding for this FIFO and reddening on it would mean the check is matching
  source text. This row is the reason 2.1 can claim the check tests the
  property rather than the expression.
- **`G3`, `G4`, `C6` (2FF cut to 1FF).** Green on both columns. These are MTBF
  statements about synchroniser depth, not statements about an encoding.
  `report_cdc` catches all three (`CDC-1 Critical` at depth 0 -- CDC-STATIC 2.1,
  not re-measured here). The table lists them so it says out loud which
  instrument owns them.
- **`NF` (a pure rename of `bin2gray` to `b2g`).** Reddens as `NOSHAPE` on a
  change that is functionally identical. This is a **false positive by
  construction** and the chief maintenance cost of extracting by name. It is
  loud, it names the file and the count, and it tells the reader to update the
  check. Traded deliberately against the alternative -- a check that silently
  passes when the thing it checks has been deleted, which is worse than no
  check.

### 4.4 The uniqueness gate on row names, teeth-checked

```
$ bash sim/mutate_gray.sh --selftest
=== selftest: the duplicate-row-name gate ===
mutate_gray.sh: DUPLICATE ROW NAME 'AA' -- one of the two edits would never be tested.  Refusing to run.
SELFTEST: PASS -- the uniqueness gate fires on a duplicate tag
```

### 4.5 The gate row

```
$ bash sim/regress.sh --list | grep graygate
RUN  sim:graygate    entity=-    1 files  vectors=none

$ bash sim/regress.sh --only graygate --jobs 1
PASS       sim:graygate    0s  GRAY_CHECK: PASS  (13 widths, pointer 2..14 bits, all exhaustive)
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

---

## 5. Measured and REJECTED -- do not retry

- **A "the `report_cdc` report must not get worse" review rule.** MEASURED
  (2.2): `G1` leaves Warnings and Criticals bit-identical and removes two Info
  rows. Every phrasing over rule IDs and severities either passes `G1` or calls
  it an improvement. Do not write this rule; it is worse than none, because it
  looks like coverage.
- **Making the adversarial-clock-ratio simulation the gate.** MEASURED (4.1):
  the skew model detects the binary pointer at a rate of 160 corrupt samples in
  2791, which is a *probability*, and it depends on the specific per-bit delays
  chosen. To make it deterministic you have to pin the delays -- at which point
  it is testing the delays you pinned, not the encoding. Keep it as a
  demonstration. `sim/gray_skew_demo.vhd` is committed for that purpose and is
  deliberately outside the `tb_*.vhd` glob so it never becomes a gate row.
- **A round trip as the oracle.** `dec(enc(b)) = b` alone is worth nothing here:
  it is the property the identity satisfies *perfectly*. `P_INV` is in the
  check for the `G2` class only, and 4.3 shows `G2` is already killed by
  simulation, so `P_INV` earns the check no credit at all. Recorded because a
  self-consistency check is the obvious first thing to write and would have
  produced a green gate over the exact defect this track exists to kill.
- **Editing `rtl/async_fifo.vhd` to make it checkable** -- for example lifting
  `bin2gray`/`gray2bin` into `rtl/util_pkg.vhd` so a normal testbench could
  call them. Not attempted, and should not be: that file is in the datapath
  measured bit-exact on the FK33 tonight, `util_pkg` is shared, and verbatim
  extraction gets the same result with a zero-line RTL diff.

---

## 6. Measurement traps hit, including my own

1. **The claim I was sent to reproduce had gone stale under its own fix.**
   The brief and CDC-STATIC both say "two fewer *warnings*". Measured today it
   is two fewer *Infos*, because CDC-STATIC's `ASYNC_REG` fix -- landed in the
   same commit as the sentence -- reclassified those five rows from
   `CDC-2 Warning` to `CDC-3 Info`. Quoting the write-up instead of re-running
   it would have put a wrong severity in this file and, worse, would have
   missed that the trap is now sharper than described.
2. **`GRAY_PROBE: PASS` had to be a printed line, not an exit status.** GHDL
   here is mcode; a run that dies during elaboration still exits in ways that
   are easy to read as success, so the verdict is a grep for a line the design
   unit itself prints, and its **absence** is `VOID`, never `PASS`. Row `VD`
   exists solely to prove that path is wired.
3. **My first `DUP` row used `bin2gray_alt` as the duplicate name and tested
   nothing.** The extractor anchors on `function<space>bin2gray<space>*(`, and
   `bin2gray_alt(` does not match it, so the "duplicate" was invisible to the
   very gate the row exists to exercise. Fixed to use the real name, which also
   made the row honest in the other column: two homograph functions with
   identical profiles are a VHDL error, so `tb` reports `VOID`.
4. **Attribution ordering inside the harness.** `NOSHAPE` has to be classified
   *before* `VOID`, or rows `NF` and `DUP` -- which also break the other
   column -- get filed as "a hole in the measurement" when they are the
   measurement.
5. **`git archive` of a pinned sha does not contain this track's own files.**
   The exported tree had to have `sim/gray_check.sh`, `sim/mutate_gray.sh` and
   the edited `sim/regress.sh` copied in, by full literal path on both sides,
   before the gate-row teeth-check meant anything.

---

## 7. What was NOT verified -- open, not answered

- **`report_cdc` in context.** Everything here is out-of-context synthesis of
  `axi_rd_port`. CDC-STATIC 2.1 records that every crossing it misses in
  subsystem A's port logic touches a **port**, which is a property of running
  OOC. This track did not run the in-context FK33 build and cannot say whether
  the in-context report separates `BASE` from `G1`. **ESTIMATE: it will not**,
  on the ground that the blindness is to the encoding and not to the context;
  that is a judgement, not a measurement.
- **`G3`/`G4`/`C6` were not re-measured through `report_cdc` by this track.**
  The "CAUGHT" claim for them in 4.3 is CDC-STATIC's, cited, not re-run. Only
  `BASE`, `G1` and `G2` were re-measured here.
- **The check says nothing about how the encoded pointer is USED.** It verifies
  the function pair in isolation. `GX` is the recorded case where that boundary
  matters: it is a genuine gray code and the check catches it only because
  `P_ZERO` happens to encode one of the RTL's usage assumptions. Other usage
  assumptions -- that `wp_g` is registered from `bin2gray(wp+1)` and not
  `bin2gray(wp)`, that both synchroniser stages exist -- are outside it, and
  belong to `sim/mutate_async_fifo.sh` (rows `G5`, `G6`) and `sim/cdc_teeth.sh`
  respectively.
- **Coverage of the input space is total; coverage of the output space is
  not.** `P_GRAY`, `P_BIJ`, `P_INV`, `P_ZERO` are exhaustive over every pointer
  value at widths 2..14. What that cannot reach: widths above 14 (the design
  uses 10; the sweep is `--max-aw`-adjustable and the cost is `2**N`), any
  property of the encoding not expressible over a single function evaluation
  and its successor, and anything about the *timing* of the crossing.
- **`BASELINE_PASS` was deliberately NOT raised.** It is 93; the clean-archive
  ceiling is now 94 with `sim:graygate`. The comparison at
  `sim/regress.sh:1968` is `-lt`, a floor, so leaving it at 93 cannot make any
  track's gate fail, and raising a shared constant while three tracks run is
  the coordination hazard this project has already paid for twice today.
  **Whoever next runs a clean full gate should raise it to 94.**
- **A full unfiltered `regress.sh` run was not made by this track.** See
  section 8 for what was run instead and why.

---

## 8. Corrections

*(none yet; append here, do not edit history above)*
