# TRACK ATTNTEETH -- why `tb_attn_block` passed a deliberately broken tree

Date: 2026-08-30. Repo SHA at the start of this track:
`da06d96326a73c6c76e90c93ed8cdb146f7d3b1d`. HEAD when the fix was written:
`2c66e896366568a12251558ffdd3ac294b67c94c`.

Tools: GHDL mcode (`sim/regress.sh`, `sim/mutate_attn_block.sh`), gcc for the
C oracle. **NO HARDWARE, NO VIVADO at any point.** Everything below ran under
`systemd-run --user --scope -p MemoryHigh=6G -p MemoryMax=8G`.

---

## The question, verbatim

> `tb_attn_block`, the bench named after the unit and carrying C's bit-exact
> oracle, **passes a deliberately broken tree** -- a guard passing for the
> wrong reason, found only by running the mutant.
>
> 1. **Reproduce it.** [...] **If you cannot reproduce it, say so plainly and
>    stop.**
> 2. **Root-cause WHY it passes.** Not "the bench is weak". The specific
>    mechanism [...] **Name the line.**
> 3. **Fix the bench so it discriminates**, then **prove the fix has teeth**.
> 4. **Run the attribution control on every kill.**
> 5. **Report mutations that do NOT bite, under their own names.**
> 6. **Ask what ELSE this mechanism hides.**

---

## The answer, up front

**REPRODUCED, and the mechanism is not in the bench at all. It is one line of
the ORACLE'S STIMULUS, and the bench was never able to be right.**

`ref/attn_block_vec.c`, as it stood:

```c
for (i = 0; i < N * N_KVH; i++)    vin[i] = m12(65537  + SEED, i);
```

Every V element drawn uniformly on `[-2048, 2047]`, with no per-block magnitude
structure. Each block is `KV_BLOCK` = 4 such draws, so every block's peak lands
in the top binade and `kv_quant()` gives **all NBLK blocks the same exponent**.

MEASURED, an instrumented copy of `rtl/attn_block.vhd` reporting at the SEAM 2
fold site (`rtl/attn_block.vhd:1471`):

```
PROBE lay=0 kvh=0 NBLK=4 e0=6 e1=6 e2=6 e3=6 full=6 prev=127 new=6
PROBE lay=0 kvh=1 NBLK=4 e0=6 e1=6 e2=6 e3=6 full=6 prev=127 new=6
PROBE lay=0 kvh=0 NBLK=4 e0=6 e1=6 e2=6 e3=6 full=6 prev=127 new=6
PROBE lay=0 kvh=1 NBLK=4 e0=6 e1=6 e2=6 e3=6 full=6 prev=127 new=6
PROBE lay=0 kvh=0 NBLK=4 e0=9 e1=9 e2=9 e3=9 full=9 prev=127 new=9
PROBE lay=0 kvh=1 NBLK=4 e0=9 e1=9 e2=9 e3=9 full=9 prev=127 new=9
```

Six folds -- three runs, two KV heads -- and **every one of them is a minimum
over a constant vector.** (Run 3 is P5's deliberately rescaled run, `vin_exp`
+3, which moves all four exponents together and so is equally degenerate.)

**`v_ref` is the MINIMUM over those exponents. A minimum over a constant vector
is that constant.** So the fold had nothing to fold, and P8 -- the bit-exact
oracle comparison, no tolerance, the bench's headline property -- compared
exactly the right numbers and **could not have disagreed whatever the reduction
did**. It was not scoped too narrowly, the oracle does not share a source with
the design, there is no tolerance, the vector file is regenerated on every gate
run, and the bench does not exit early. Every one of those hypotheses was
checked and every one is wrong. The defect is in the stimulus.

**The fix is therefore in the stimulus, and the new bench check kills nothing.**
`ref/attn_block_vec.c` now applies a deliberate per-block magnitude taper, so
the written V header carries `9 8 7 6` on head 0 and `7 6 9 8` on head 1 --
distinct exponents, a unique minimum, at a DIFFERENT index on each head. With
that stimulus the pre-existing P8 kills four of the eight fold mutants that it
previously passed. The new **P9** is a gate on P8's RESOLUTION -- it asserts at
the write port that the header being folded can tell a right fold from a wrong
one -- and the attribution control confirms it is credited with **zero** kills.

**One of the four new kills is a defect NOTHING in this repo caught before.**
`M8`, the fold silently dropping the last block exponent of the header, passed
both `tb_attn_block` AND `tb_attn_kv_seam` before this change.

---

## 1. Reproduction

`git archive HEAD` into `/mnt/storage/attnteeth/tree_orig`, a second copy with
TRACK TIMING's one-line mutant (`for s in 0 to LG-1` -> `LG-2` in `emin_tree`),
and `REGRESS_SCRATCH=... bash sim/regress.sh --only tb_attn_block --keep` on
each. Note the trap in CLAUDE.md: `--only` is a SUBSTRING, so `--list` was run
first and confirmed it selects exactly one row.

```
== plan ==
RUN  sim:tb_attn_block   entity=tb_attn_block   17 files  vectors=attn_block_vec.txt
```

MEASURED:

```
ORIGINAL   OVERALL  PASS 1  FAIL 0
MUTANT     PASS  sim:tb_attn_block  1s
             tb_attn_block: PASS -- 3 consumer configurations, 64 ele...
           OVERALL  PASS 1  FAIL 0
```

**Reproduced independently.** TRACK TIMING's report is exactly right.

## 2. Root cause -- the line

`ref/attn_block_vec.c:864` (pre-fix numbering):

```c
    for (i = 0; i < N * N_KVH; i++)    vin[i] = m12(65537  + SEED, i);
```

`m12(a,b)` returns `(hsh(a,b) & 0xFFF) - 2048`, i.e. uniform on `[-2048, 2047]`.
`kv_quant()` at `ref/attn_block_vec.c:376` sets, per block,

```c
        sh = msb_pos_u((uint64_t)amax) - (CM_W - 2);
        e[b] = src_exp - sh;
```

so the exponent is a function of the block's PEAK MAGNITUDE ALONE. Four uniform
draws on `[-2048, 2047]` put the peak in `[1024, 2047]` with probability
`1 - (1/2)^4` = 15/16 per block, so all four blocks share a binade almost
always, and at SEED 0 they do.

**The generator's author had already understood this for the CACHE and not for
the written token.** `ref/attn_block_vec.c:643` fills the cached V headers as
`vref[h] + (int)(hsh(9013 + SEED, ...))` -- an explicitly randomised per-block
exponent -- and those DO have spread (MEASURED from the vector file:
`9 7 9 7 9 8 6 7 8 6 8 8 ...`). The one header that reaches the SEAM 2 fold is
the only one that does not.

**Why the whole rest of the bench cannot cover for it.** `sim/tb_attn_block.vhd`
writes exactly ONE token per sequence, so `vref_r` is seeded from its reset 127
and folded exactly once per (head, run). Its own header says as much
("the fold is checked at its first value and never across an append"), and that
sentence was read as a limitation on the SEQUENCE dimension. It is not: at one
token, the fold's ENTIRE input is that single header, so a degenerate header
makes the fold entirely unobservable, not merely under-covered.

## 3. The fix

**Two parts, in `ref/attn_block_vec.c` (stimulus) and `sim/tb_attn_block.vhd`
(a gate on the stimulus). `rtl/attn_block.vhd` is NOT touched.**

**(a) the taper**, in `main()` only -- `ref/attn_block_vec.c`'s `main` is
guarded by `#ifndef ATTN_BLOCK_VEC_NO_MAIN` and both of its includers
(`ref/attn_block_seq_vec.c:114`, `ref/attn_block_cap_vec.c:109`) define that
macro, so their stimulus is untouched and only `attn_block_vec.txt` moves:

```
taper(h,b) = ((NBLK-1-b) + h*(NBLK/N_KVH)) mod NBLK, capped at 4
vin[h*N + b*KVB + d] = m12(...) / (1 << taper)      (truncating toward zero)
vin[h*N + b*KVB + 0] = 2047 >> taper                (the anchor)
```

The anchor is what turns a lucky draw into a property: it fixes each block's
peak at exactly `2047 >> taper`, so the exponent is a function of the taper
alone. MEASURED output of the generator at the gate's arguments
`16 4 2 4 8 3 4 0`:

```
attn_block_vec: head 0 v block exponents 9 8 7 6  argmin=3 nmin=1 ndistinct=4
attn_block_vec: head 1 v block exponents 7 6 9 8  argmin=1 nmin=1 ndistinct=4
```

DERIVED and confirmed: `amax = 2047 >> t` gives `msb = 10 - t`, `sh = 4 - t`,
`e = src_exp - sh = 6 + t`, and the tapers are `(3,2,1,0)` on head 0 and
`(1,0,3,2)` on head 1.

The two heads are tapered DIFFERENTLY on purpose. Head 0 puts the minimum at
the LAST block, which is what makes `M8` (drop the last element) visible; head 1
puts it at an INTERIOR block, which is what makes a fold returning the last
element visible. One head cannot do both.

**What the taper costs, stated rather than hidden:** the deepest-tapered block's
input peak is `2047 >> t` instead of ~2047, so its INPUT has fewer distinct
levels. It does NOT cost mantissa coverage, because `kv_quant` normalises each
block to `CM_W` bits against its own peak -- the taper moves the exponent, not
the packed mantissa's range. The cap at 4 is the exponent range: `sh` is clamped
at 0 and a 12-bit draw tapered by more than 4 has `msb <= 6`, so two blocks
would collide. **All-distinct therefore holds for `NBLK <= 5`; a UNIQUE MINIMUM
holds at every `NBLK`, because exactly one block has taper 0.** Both are
asserted by the generator, which returns 3 and writes NO FILE if they fail.

**(b) P9, a check on the INPUT.** `sim/tb_attn_block.vhd` captures the V header
at the write port (`kw_sel = '1'`, `kw_hen = '1'` -- the fold's entire input in
this bench) and asserts (a) the NBLK exponents are not all equal, (b) the
minimum is UNIQUE so that WHICH element the fold returns is decidable and not
only its value, and (c) the KV heads do not put the minimum at the same index.

## 4. The mutation table, and the attribution control

`sim/mutate_attn_block.sh`, added by this track. Nine mutations, every one
well-formed VHDL and in bounds, each anchor required to match EXACTLY ONCE (an
anchor matching zero times would run the honest design and score as a survivor,
which is the easiest way to fake a resolution floor).

MEASURED, `bash sim/mutate_attn_block.sh`, both before and after:

| tag | mutation | `tb_attn_block` BEFORE | `tb_attn_block` AFTER | `tb_attn_kv_seam` |
|---|---|---|---|---|
| A0 | none (anchor) | PASS | PASS | PASS |
| M1 | `emin_tree` drops its last combining stage (TIMING's) | **PASS** | KILLED | KILLED |
| M2 | `emin_tree` does not reduce -- returns block 0 | **PASS** | KILLED | KILLED |
| M3 | `emin_tree` computes the MAXIMUM | **PASS** | KILLED | KILLED |
| M4 | the power-of-two PAD repeats 127, not element 0 | PASS | **SURVIVED** | **SURVIVED** |
| M5 | the fold's result is never folded in (`v_ref` stays 127) | KILLED | KILLED | KILLED |
| M6 | `v_ref` becomes a per-TOKEN minimum | **PASS** | **SURVIVED** | KILLED |
| M7 | defect C1: one `v_ref` SHARED across layers | **PASS** | **SURVIVED** | KILLED |
| M8 | the fold drops the LAST block exponent | **PASS** | KILLED | **SURVIVED** |

**Before the fix `tb_attn_block` killed 1 of 8. After, it kills 5 of 8.**

**M8 is the row that matters most: it survived BOTH benches before this change.**
It is a genuine wrong answer whenever the last block holds the minimum, and
nothing in this repo could see it. It is caught now only because head 0's taper
deliberately puts the argmin there.

### The attribution control

Every mutant re-run with **P9's verdict disabled** -- the reports left in, the
four `nerr := nerr + 1` sites neutered, so the control still prints what P9 saw
while no longer able to fail the bench. Built mechanically by the harness, which
refuses to run if it does not find exactly four sites.

```
C1M1  KILLED     C1M2  KILLED     C1M3  KILLED     C1M4  SURVIVED
C1M5  KILLED     C1M6  SURVIVED   C1M7  SURVIVED   C1M8  KILLED
```

**Identical to the P9-enabled column in all eight rows. P9 is credited with
ZERO kills.** Every kill belongs to P8, the property that was already there.

That is the honest reading and it is the reason P9 is justified as a **gate on
P8's resolution** and not as a detector. Had the control been skipped, this
document would have claimed four new detections for a check that makes none.

### P9's own teeth-check

A check never shown to fail has not been shown to work. Row `C2`: honest RTL,
the taper reverted to the flat draw, the generator's refusal removed so the flat
file is actually written.

```
C2  KILLED  -- honest RTL, flat V stimulus -- P9 must fire
      tb_attn_block: P9 -- head 0 wrote 4 V block exponents with 1 distinct
      value(s).  The SEAM 2 min fold is UNOBSERVABLE on this stimulus: P8
      would pass any reduction, including none at all.
```

Full output of that run, and note that **P8 passes it** -- both sides read the
same file, so a degenerate stimulus is not an arithmetic error and no oracle
comparison can ever see one:

```
P9 -- head 0 written V block exponents: 9 9 9 9 argmin=0 nmin=4 ndistinct=1
P9 -- head 0 wrote 4 V block exponents with 1 distinct value(s).  The SEAM 2
      min fold is UNOBSERVABLE on this stimulus: P8 would pass any reduction,
      including none at all.  Fix the taper in ref/attn_block_vec.c, not this
      assertion.
P9 -- head 0 has 4 blocks at the minimum exponent.  A fold that drops one of
      them is bit-exact by accident.
P9 -- head 1 written V block exponents: 9 9 9 9 argmin=0 nmin=4 ndistinct=1
P9 -- head 1 wrote 4 V block exponents with 1 distinct value(s). ...
P9 -- head 1 has 4 blocks at the minimum exponent. ...
P9 -- every KV head puts the minimum V block exponent at block 0.  A fold that
      returns that fixed element is bit-exact on every head at once.
```

The generator's own assert has teeth too. MEASURED with the taper reverted and
the assert kept:

```
attn_block_vec: head 0 v block exponents 6 6 6 6  argmin=0 nmin=4 ndistinct=1
attn_block_vec: head 0 has 4 blocks at the minimum exponent; the SEAM 2 fold is
                unobservable with a non-unique minimum
attn_block_vec: head 0 argmin is block 0, the taper puts it at 3
attn_block_vec: head 0 has 1 distinct block exponents of 4; NBLK <= 5 must give
                all distinct
attn_block_vec: head 1 v block exponents 6 6 6 6  argmin=0 nmin=4 ndistinct=1
   ... (the same three for head 1, argmin wanted at 1) ...
attn_block_vec: heads 0 and 1 both put the minimum V block exponent at block 0
attn_block_vec: the V taper does not hold at this shape.  REFUSING to write a
                vector file that cannot falsify the SEAM 2 fold.
RC=3, and no file written.
```

## 5. Mutations that do NOT bite, under their own names

**These are the most valuable rows in the table and none has been discarded.**

**M4 -- the power-of-two pad. UNREACHABLE, not a missed defect.** `emin_tree`
pads its array to `PW = 2**clog2(NBLK)` by repeating element 0, and `M4` makes
it pad with 127 instead. It survives both benches because `PW = NBLK` at every
shape this repo uses: `HEAD_DIM/KV_BLOCK` is 4 at `tb_attn_block`'s shape, 4 at
`tb_attn_kv_seam`'s (64/16), and 8 at the 9B build shape (256/32). **The else
branch has never executed anywhere.** It is correct code -- a minimum is
idempotent, so repeating an element cannot change it -- and it is untested
because it is dead. Reported, not fixed: nothing in the RTL is wrong.

**M6 -- the per-SEQUENCE carry-in.** `tb_attn_block` writes ONE token per
sequence, so the carry-in term is always the reset 127 and dropping it changes
nothing. This is STRUCTURAL and cannot be fixed inside this bench without
turning it into a different bench. `sim/tb_attn_kv_seam.vhd` owns it, runs four
tokens, and KILLS it -- and `sim/regress.sh`'s `tb_vector_args()` records that
its SEED = 2 was CHOSEN for exactly this, moving 358 integers where most seeds
move none.

**M7 -- the layer index.** `tb_attn_block` runs one layer, so `lay_r` is always
0 and `vref_r(lay_r*N_KVH + kvh)` is `vref_r(kvh)`. Also structural.
`tb_attn_kv_seam` at `NLAY = 2` owns it and KILLS it.

**M6 and M7 together are the reason `tb_attn_kv_seam` must not be treated as
redundant with this bench**, and M8 is the reason the reverse also holds. The
two benches have DISJOINT blind spots on the same structure.

## 6. What else this mechanism hides

The general shape is: **a reduction over per-block exponents, driven by an
oracle whose stimulus is a flat uniform draw over every element, is
unobservable however bit-exact the comparison is.** `grep -l 'emin\|e_min'
rtl/*.vhd` gives four units carrying such a reduction:

    rtl/attn_block.vhd     -- diagnosed and fixed here
    rtl/attn_emit.vhd
    rtl/attn_score_q12.vhd
    rtl/gdn_conv.vhd

A separate enumeration of the other three is in section 10. **It is an
enumeration, not a fix**, and the three are not claimed to be defective -- only
to share the shape that has to be checked.

Within `tb_attn_block` itself, the same question was asked of the K side and
answered: the K-side `emin` in `attn_score_q12` runs over records READ FROM THE
CACHE, and the cache headers are generated with an explicit random per-block
exponent (`ref/attn_block_vec.c:640-643`), so they carry real spread
(MEASURED from the vector file: `8 8 9 7 7 7 9 8 ...`). The K-side fold is
observable on this stimulus. The V side was the only degenerate one, and only
because the WRITTEN token's header is the one input `kv_quant` derives rather
than the generator setting it directly.

## 7. Measured and REJECTED -- do not retry

- **"Change the SEED."** `sim/regress.sh:1478` passes `16 4 2 4 8 3 4 0` and a
  seed search would find one where a block happens to fall a binade low
  (DERIVED: `P(a block is low) = 1/16`, so `P(at least one of the 8 blocks)
  ~= 40%`). REJECTED for two reasons, both decisive. First, `sim/regress.sh` is
  TRACK GATEGREEN's file and this track does not own it. Second and more
  important, **it is the same defect class one level up**: a property that holds
  because of a lucky draw is exactly the "one-parameter model fitted to one
  point" failure CLAUDE.md records, and it would silently evaporate the next
  time anyone changed a shape. The anchored taper makes the property hold BY
  CONSTRUCTION at any seed, and the generator asserts it.
- **"Add assertions to the bench until something fails."** REJECTED by the
  brief and by the measurement: the attribution control shows that no assertion
  added to this bench could have made the difference. The stimulus was the
  binding constraint, and no amount of checking a degenerate input distinguishes
  a right fold from a wrong one.
- **"Derive the expected `v_ref` in the bench and compare it."** REJECTED: the
  bench would then compute the minimum the same way the design does, from the
  same header, which is the `m7` round-trip failure CLAUDE.md records. P9
  deliberately does NOT compute the expected `v_ref`; it only asserts that the
  INPUT can discriminate, and leaves the value to the independent C oracle.
- **"Fix `rtl/attn_block.vhd`."** Not attempted, and there is nothing to fix.
  The RTL is correct; `emin_tree` is bit-exact against the serial fold it
  replaced, which is what TRACK TIMING claimed and what M1..M8 now confirm from
  the other side.

## 8. Measurement traps hit, including my own

- **`ghdl -e` produces no binary under mcode.** Known and avoided; everything
  here goes through `sim/regress.sh` or `ghdl -r` directly.
- **`--only` is a substring.** `--list` was run first on every new pattern, and
  the `OVERALL PASS n` line read on every run, never the `REGRESSION: PASS`
  line alone.
- **VHDL has no `declare` block.** The first cut of P9 used `declare ... begin
  ... end;` inside a `for` loop, which is Ada. GHDL's diagnostic for it
  (`'begin' is expected instead of 'report'`, 27 lines later) points nowhere
  near the cause. The variables are now in the process declarative part.
- **A `report` inside a mutated RTL file is invisible to `regress.sh`'s
  one-line verdict.** The probe output only appears in the scratch `log`, which
  is why `--keep` and `REGRESS_SCRATCH` were used throughout.
- **My own trap, and it is worth stating.** The first hypothesis was "the bench
  never reaches the divergent output" and the second was "the oracle shares the
  fold's source". Both are plausible, both are the kind of thing this bench
  could have had, **and both are wrong.** They were killed in ten minutes by
  instrumenting the fold site and printing its input, which should have been
  the FIRST action rather than the third. When a check does not discriminate,
  print the check's INPUT before theorising about the check.
- **The anchor row must not be labelled SURVIVED.** The first version of
  `sim/mutate_attn_block.sh` printed `A0 SURVIVED` for the honest tree, which
  reads exactly like a miss in a table whose entire value is its survivor
  column. It now prints `PASS (anchor)` and is not counted.

## 9. Open, not yet answered

- **The reassociation is exercised at `NBLK = 4`, never at `NBLK = 8`.** Both
  benches run scaled shapes (`HEAD_DIM` 16/4 and 64/16); the 9B build shape is
  256/32 = 8, a THREE-stage tree rather than two. `emin_tree` is
  shape-independent by construction and the taper's unique-minimum property
  holds at any `NBLK`, but its ALL-DISTINCT property does not survive past
  `NBLK = 5` and nothing has run at 8. TRACK TIMING recorded the same gap.
- **`M4`'s pad branch is dead code at every shape in the repo.** Whether to
  keep it is an RTL question this track did not touch.
- **The taper is applied to V only.** K is drawn flat by the same generator
  (`kin[i] = m12(104729 + SEED, i)`), and the K-side fold is covered only
  through the CACHED records. Whether the BYPASSED K record's own header being
  degenerate hides anything in `attn_score_q12` was not measured here.
- **Sibling benches (section 6) are enumerated, not fixed, and only the
  `attn_block` one has been measured end to end.**
