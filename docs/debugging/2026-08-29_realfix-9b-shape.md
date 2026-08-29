# Can the real 9B shape be made to elaborate, and can each of its six defects be made to BITE?

TRACK REALFIX, 2026-08-29.  The fix half of TRACK REALSHAPE's investigation
(`docs/debugging/2026-08-29_realshape-9b-elaboration.md`).

Measured against a pristine `git archive` of **`bfa1e2a`** for the elaboration
matrix (`rtl/` is byte-identical at `bfa1e2a`, `06f6793` and `5578132` --
MEASURED, `git diff --name-only bfa1e2a 5578132 -- rtl/` is empty), and against
a pristine `git archive` of **`5578132`** for the `tb_llama_top` value family,
because that commit is what gave the family a falsifiable verdict.  The full
gate ran on **`9d7a9e5`** plus this track's files.  HEAD moved four times while
this ran; nothing below depends on a working tree.

Tooling: `GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6) [Dunoon edition]`, **mcode**
backend, `--std=08`; `Vivado 2023.2`, `xczu3eg-sfvc784-1-e`, out of context.
Host 31 GiB / 24 threads, shared with three other tracks.

## The question, verbatim

> TRACK REALSHAPE just landed [...] Six defects, five of them invisible at
> `mk_shape_scaled`.  Fix them, in REALSHAPE's stated fix order.
>
> **R2 is the wall and is the one to think hardest about.**  REALSHAPE
> explicitly did NOT establish that `stmem` can legally become a variable --
> its probe SHRANK the array, it did not convert it.  Converting a signal to a
> process variable changes visibility and scheduling semantics.  Establish
> whether it is legal AND whether it preserves behaviour, and if it cannot be a
> variable, find another way.  **Do not just make the change and report that it
> elaborates.**
>
> [...] For each of the six, show the defect being DETECTED after your change,
> not merely absent.

## The answer, up front

**All six are fixed, and `ghdl -r llama_top` with no generic overrides -- the
real 9B shape, which is that file's own default -- now elaborates in 2.12 s and
2.20 GB.**  Before: killed at the 20 GB cap after 10.77 s, MEASURED here on a
pristine `bfa1e2a` tree, and `STORAGE_ERROR` at 24.9 GB uncapped, which is
REALSHAPE's number and was NOT re-measured by this track.  The whole composition
with real A, real B fed from the real regions, real C over three AXI masters
against the real `attn_kv_axi`, the real RMSNorm and the sampler on is
**2.54 s and 2.45 GB**.

**R2 is behaviour-preserving, and that is now proved rather than argued.**
`stmem` had exactly two accesses in the whole file, both inside one clocked
process, and no concurrent statement read it, so visibility and scheduling
cannot change.  The one thing a signal-to-variable conversion CAN change is
read-during-write at the same address on the same edge -- and the fix is
statement order, not the conversion.  `sim/tb_stmem_equiv.vhd` runs the signal
form, the variable read-first form and the variable **write-first** form
against one stimulus stream: read-first differs from the signal on **0 of
20,064 cycles** and write-first differs on **2,488 of them**.  The control is
what makes the first number mean anything.

**Independently, none of the sixteen `tb_llama_top` landmarks moved.**  A shape
and bound fix that alters no arithmetic should move nothing, and nothing moved.

**And the technique the whole fix rests on is now MEASURED rather than
ESTIMATED.**  Three Vivado runs of the same file, same tool, same part:

| invariant, how it is expressed | Vivado result |
|---|---|
| `NBLK*EXP_W/8 <= CH_B` as an out-of-range `natural` constant | **`ERROR: [Synth 8-11323] assigned value '-48' out of range`, synthesis FAILS** |
| the granule rule as `assert ... severity failure` | **rc=0, synthesis COMPLETES.**  Ignored. |
| the legal geometry, as a control | rc=0, synthesises |

So the two forms are not interchangeable, and an assert-only guard in this
repository is a simulation check wearing a build check's clothes.

## Corrections to the brief

The brief's six-row table was checked line by line.  All six reproduce.  Three
things it said, or implied, need correcting.

- **`rtl/llama_top.vhd:157` claimed this file "is not in any synthesis flow".**
  That is FALSE as written and it matters, because it is the premise under
  which an assert-only guard would have been acceptable here.  `hw/` is indeed
  empty of it, but `sim/ooc_compose_bcd.tcl:91` has `set GEN(llama_top) {}` and
  synthesises this entity out of context at its own defaults.  MEASURED, `grep
  -n llama_top sim/ooc_compose_bcd.tcl`.  Corrected in place at that line.
- **Therefore R1's fix changes an existing area number, and TRACK COMPOSE owns
  it.**  `REGMAX` now defaults to `region_max(SHAPE)`, which at the default 9B
  shape is 12288 rather than 4096.  Any `llama_top` OOC area figure taken
  before today was of a design whose flat region file could not address its own
  widest region; the new figure will be about 3x on that array.  That is a
  correction, not a regression, but it is not mine to re-measure:
  `sim/ooc_compose_bcd.tcl` and `hw/fk33/results/compose_*` are TRACK COMPOSE's.
- **The brief's framing "R1 ... ESTIMATED silent 12-bit truncation in
  synthesis" is not what happens now and was never quite the risk.**  With
  `REGMAX` 4096 and a `natural range 0 to REGMAX-1` port, the 12288th element
  is not silently truncated by Vivado; it is a value outside a declared range,
  which is the same class of error the new checks raise deliberately.  What
  WAS silent is that **nothing computed the two numbers and compared them**, at
  any stage, in either tool.  That is what `CHK_REGMAX` fixes.

One thing REALSHAPE left open that this track closes in the opposite direction
to its own suggestion: its item 5 offered either `POSW := clog2(C_MAXPOS + 1)`
**or** dropping the `C_CTXLEN < 2**POSW` clause.  Dropping the clause is wrong.
`attn_kv_axi:542` range-checks with `to_integer(ctx_len) > MAXCTX`, so
`ctx_len` is a COUNT and must be representable; at `C_MAXPOS = 256` and
`POSW = 8`, `to_unsigned(256, 8)` is 0 and the check would pass a wrapped
value.  The width had to grow.

## The procedure

Each step isolates one thing, and every step that shows a guard REFUSING is
paired with the neighbouring configuration, one generic away, that must still
be ACCEPTED.  A guard shown only to refuse is indistinguishable from a guard
that refuses everything.

1. **Reproduce REALSHAPE's matrix unchanged**, on a pristine `bfa1e2a` tree,
   before touching anything.  `bash sim/elab9b_run.sh`.  This is the control
   for every "after" number below.
2. **Record the sixteen `tb_llama_top` landmarks BEFORE the change**, on a
   pristine `5578132` tree.  `bash sim/regress.sh --only llama_top`.  These are
   the only value oracles that reach this file, and they became falsifiable
   only at `5578132`; before that a wrong number could not fail the family.
3. **R2 first**, because it is the wall and because nothing else at the real
   shape can be measured until the design elaborates at all.  Convert `stmem`
   to a process variable with the read block ordered before the write block.
4. **Prove R2 rather than assert it**: `sim/tb_stmem_equiv.vhd`, three memories
   on one stimulus stream, with the write-first variant as the negative
   control and a forced same-address collision on half the cycles.  This is an
   oracle for the transformation itself and does not depend on whether the
   integration bench happens to exercise a read-during-write -- which, as it
   turns out, it does not (see "Measurement traps").
5. **R1 and R3 as generic defaults derived from `SHAPE`, plus two `natural`
   constants that go negative.**  The defaults make the shipped configuration
   correct; the constants make an override that breaks the invariant fail.
   Then a THREE-row pair for R1 -- the old default, one element short, and
   exactly enough -- because a boundary check that is only tested far from the
   boundary is not tested.
6. **R4 in two places**: `attn_kv_axi`'s own declarative part, so the module
   names itself, and `llama_top`'s mirror, so the caller is named.  The control
   that matters is running the same illegal `KV_BLOCK` at HEAD_DIM 64, where
   the old named assert IS reachable, to confirm the fix did not replace a good
   diagnostic with a worse one.
7. **R5 and R6 as `natural` constants in the `gkvaxi` generate's declarative
   part**, which required giving that generate a declarative part and a `begin`
   it did not have.  R6's control is `ctx_over_max`, which must STILL refuse --
   otherwise the fix removed the check instead of correcting it.
8. **The dead behavioural cache** moved inside `if not C_KV_AXI generate`,
   measured as a before/after RSS delta at two different `C_MAXPOS` so the
   per-position figure is a slope and not one point.
9. **Vivado, three times**, on `attn_kv_axi` out of context: the illegal
   geometry that the new constant catches, the legal control, and the
   geometry that violates only an assert.  This is the step that turns "Vivado
   ignores asserts" from a repository rule into a measurement.
10. **Re-run the sixteen landmarks and then the whole gate.**

## The evidence

### 1. The baseline, reproduced verbatim on `bfa1e2a`

`ELAB9B_SCRATCH=... bash sim/elab9b_run.sh`, cap 20G:

```
default          rc=137 peakRSS=20937688 kB  wall=0:10.77  expect=fail
    Command terminated by signal 9
real_B           rc=137 peakRSS=20936148 kB  wall=0:10.57  expect=fail
    Command terminated by signal 9
kv_default_block rc=1   peakRSS=  812032 kB  wall=0:00.77  expect=fail
    /usr/bin/ghdl-mcode:error: overflow detected
    /usr/bin/ghdl-mcode:error: error during elaboration
kv_addr_wrap     rc=0   peakRSS= 1378120 kB  wall=0:01.47  expect=ok
ctx_at_max       rc=1   peakRSS= 8892848 kB  wall=0:07.04  expect=fail
    rtl/llama_top.vhd:3657:7:@0ms:(assertion failure): llama_top: C_CTXLEN
    must fit in the cache and in POS_W.
ctx_one_short    rc=0   peakRSS= 8892816 kB  wall=0:07.07  expect=ok

elab9b: rows PASS 17 FAIL 0 (of which 5 were expected failures)
```

Identical to REALSHAPE's published matrix on every rc and within 0.03% on every
RSS.  `kv_addr_wrap` rc=0 is R5: the design elaborated clean with the V region
wrapped onto K.

### 2. The same matrix after the fix

`bash sim/elab9b_run.sh` against the fixed `rtl/`.  FOUR rows now disagree with
REALSHAPE's expectations, all in the intended direction, so that harness now
reports `PASS 13 FAIL 4` **by design**.  A fifth, `kv_default_block`, still
fails as it expects but for a different and attributable reason:

```
default          rc=0   peakRSS= 2202880 kB  wall=0:02.06  expect=fail   <- R2
real_B           rc=0   peakRSS= 1954588 kB  wall=0:01.90  expect=fail   <- R2
kv_default_block rc=1   peakRSS=  661008 kB  wall=0:00.70  expect=fail
    bound check failure at rtl/llama_top.vhd:3750                        <- R4
kv_addr_wrap     rc=1   peakRSS=  660392 kB  wall=0:00.71  expect=ok
    bound check failure at rtl/llama_top.vhd:3765                        <- R5
ctx_at_max       rc=0   peakRSS= 1259552 kB  wall=0:01.31  expect=fail   <- R6
```

`sim/elab9b_run.sh` is TRACK REALSHAPE's and this track did not edit it; it is
left stating the pre-fix world, which it will now say loudly rather than
silently.  Its replacement is `sim/realshape_gate.sh`, below.

### 3. The standing matrix, `sim/realshape_gate.sh`, 19 rows in about 23 s

Every refusing row is followed by its accepting neighbour.  Verbatim, on the
final RTL:

```
default_9b         rc=0   peakRSS= 2203356 kB  wall=2.81   expect=ok
regmax_short       rc=1   peakRSS=   44544 kB  wall=0.39   expect=fail
    bound check failure at rtl/llama_top.vhd:805        <- CHK_REGMAX
regmax_edge_lo     rc=1   peakRSS=   44736 kB  wall=0.38   expect=fail
    bound check failure at rtl/llama_top.vhd:805
regmax_edge_ok     rc=0   peakRSS= 2203316 kB  wall=2.08   expect=ok
vn_w_short         rc=1   peakRSS=   44544 kB  wall=0.45   expect=fail
    bound check failure at rtl/llama_top.vhd:813        <- CHK_VN_W
vn_w_ok            rc=0   peakRSS= 2203168 kB  wall=2.49   expect=ok
kv_nblk_bad        rc=1   peakRSS=  661152 kB  wall=0.92   expect=fail
    bound check failure at rtl/llama_top.vhd:3796       <- CHK_KV_NBLK
kv_nblk_ok         rc=0   peakRSS= 1259880 kB  wall=1.46   expect=ok
kv_gran_bad        rc=1   peakRSS=  661000 kB  wall=0.70   expect=fail
    bound check failure at rtl/llama_top.vhd:3799       <- CHK_KV_GRAN
                                                        (see section 10)
kvaxi_nblk64_bad   rc=1   peakRSS=   13824 kB  wall=0.06   expect=fail
    bound check failure at rtl/attn_kv_axi.vhd:394      <- CHK_HDR_FITS
kvaxi_nblk32_bad   rc=1   peakRSS=   13824 kB  wall=0.06   expect=fail
    bound check failure at rtl/attn_kv_axi.vhd:394
kvaxi_nblk16_ok    rc=0   peakRSS=   17280 kB  wall=0.07   expect=ok
kv_addr_wrap       rc=1   peakRSS=  661032 kB  wall=0.70   expect=fail
    bound check failure at rtl/llama_top.vhd:3811       <- CHK_KV_FIT
kv_addr_fits       rc=0   peakRSS= 1260128 kB  wall=1.33   expect=ok
kv_overlap         rc=1   peakRSS= 1259928 kB  wall=1.33   expect=fail
    rtl/llama_top.vhd:3844:7:@0ms:(assertion failure): llama_top: the K and
    V KV regions overlap.  Each is 34816 bytes.
ctx_at_max         rc=0   peakRSS= 1259908 kB  wall=1.33   expect=ok
ctx_one_short      rc=0   peakRSS= 1260104 kB  wall=1.37   expect=ok
ctx_over_max       rc=1   peakRSS=  661036 kB  wall=0.74   expect=fail
    bound check failure at rtl/llama_top.vhd:3802       <- CHK_KV_CTX
all_real           rc=0   peakRSS= 2452524 kB  wall=2.30   expect=ok

REALSHAPE GATE: PASS  rows 19 (10 of them guards that must refuse)
```

GHDL names a file and a line for a range violation but not the constant, so
the arrows above are the mapping.  Grep the constant NAME, not the line
number: the numbers move whenever this file does, and it moves often.

`all_real` is the row that answers REALSHAPE's headline claim: the whole
composition at the true 9B dimensions, 2.45 GB and 2.30 s.

### 4. R2, the equivalence proof

`sim/tb_stmem_equiv.vhd`, one stimulus stream into three memories:

```
tb_stmem_equiv: cycles compared 20064, forced same-address collisions 10084
tb_stmem_equiv: A(signal) vs B(variable, read-first) differing cycles = 0
                (must be 0)
tb_stmem_equiv: A(signal) vs C(variable, write-first) differing cycles = 2488
                (must be > 0, this is the resolution check)
STMEM EQUIV: PASS -- the process-variable read-first form is cycle-identical
to the signal form over 20064 cycles, and the write-first control differs on
2488 of them.
```

The static half of the argument, MEASURED with
`grep -n 'stmem\|semem' rtl/llama_top.vhd` on the pre-change file: `stmem`
appeared at four lines, the declaration and three inside `stmem_p`.  No
concurrent statement and no second process touched it.  That is why the
conversion is legal at all; the ordering is why it is correct.

`semem` is **deliberately still a signal**, and the reason is in the same grep:
line 2846 (pre-change) is `se_rdata <= semem(...)`, a CONCURRENT combinational
read outside every process, because `gdn_block`'s `se_rdata` port contract is a
combinational read.  Converting it would mean registering that read, which is a
design change to a port timing contract and not a modelling change.  DERIVED
cost of leaving it: `NLY*VH*DM = 24*32*128 = 98,304` entries of 8 bits =
786,432 scalar signals, at the ~228 B/signal REALSHAPE measured = **179 MB**,
i.e. 8% of the 2.20 GB the default row now costs.  Affordable; not free.

### 5. R2 did not move a single value

Sixteen landmarks, pristine `5578132` for the "before" and the same tree with
only `rtl/llama_top.vhd` + `rtl/attn_kv_axi.vhd` replaced for the "after".
`bash sim/regress.sh --only llama_top`, `OVERALL PASS 6 FAIL 0` both times.

| bench | EXP_X0 | EXP_XSUM | EXP_XALL | EXP_STEPH | moved? |
|---|---|---|---|---|---|
| `tb_llama_top` | -12739 | 38863 | 38863 | 6432 | no |
| `tb_llama_top_seq` | -14252 | 7668 | 96762 | 57526 | no |
| `tb_llama_top_real` | -16364 | 91622 | 91622 | 17333 | no |
| `tb_llama_top_normw` | -16350 | 90889 | 90889 | 18618 | no |

Both columns are byte-identical, so only one is printed.  **This is weaker
evidence than it looks, and the reason is the third entry under "Measured and
REJECTED" below**: at
`b_tk0` hardwired '1' the state read is masked, so the family cannot
distinguish read-first from write-first.  It is a strong check that the OTHER
five fixes changed no arithmetic, and only a weak one about R2 -- which is
exactly why `tb_stmem_equiv` exists.

### 6. R4, the guard that was unreachable, and the one that still speaks

`attn_kv_axi` standalone, all other generics fixed at
`N_KVH 4, LAYERS 8, MAXCTX 4, POS_W 16, CM_W 8, EXP_W 8, AXI_DW 256, ADDR_W 16`:

```
HEAD_DIM  KV_BLOCK  NBLK   before                    after
   256        4      64    overflow detected,        bound check failure at
                           no file, no line          attn_kv_axi.vhd:394
   256        8      32    overflow detected         bound check failure at :394
   256       16      16    ok                        ok
    64        4      16    named assertion failure   named assertion failure
                           (the granule rule)        (unchanged)
    64       16       4    ok                        ok
```

The `HEAD_DIM 64 / KV_BLOCK 4` row is the control that matters: it violates a
DIFFERENT invariant, one the new constant does not cover, and it still produces
the named message.  The fix added a diagnostic where there was none; it did not
replace a good one.

### 7. Vivado, three runs, the whole basis of the technique

OOC synthesis of `attn_kv_axi` on `xczu3eg-sfvc784-1-e`, Vivado 2023.2:

```
--- HEAD_DIM=256 KV_BLOCK=4   (CHK_HDR_FITS = 16 - 64 = -48)
BADRC=1
ERROR: [Synth 8-11323] assigned value '-48' out of range
       [/home/.../rtl/attn_kv_axi.vhd:394]
ERROR: [Synth 8-285] failed synthesizing module 'attn_kv_axi'
       [/home/.../rtl/attn_kv_axi.vhd:361]
ERROR: [Common 17-69] Command failed: Vivado Synthesis failed

--- HEAD_DIM=256 KV_BLOCK=16  (legal control)
=== good rc=0
SYNTH_GOOD_COMPLETED

--- HEAD_DIM=64  KV_BLOCK=4   (violates only `assert ... severity failure`)
=== assertonly rc=0
SYNTH_ASSERTONLY_COMPLETED
```

The third run is the measurement: a geometry GHDL refuses with a named
assertion failure synthesises to completion in Vivado, in the same file, in the
same tool invocation shape as the run that failed.  This is why every new guard
in this change is a constant and not an assert.

### 8. The behavioural KV cache that was elaborated when it was not used

`kvhdr`/`kvmem` were declared one level above the `if not C_KV_AXI generate`
that is their only user, so they existed even with the real AXI cache in their
place.  MEASURED, `C_KV_AXI` true throughout, before vs after:

| `C_MAXPOS` | before | after | delta | per position |
|---|---|---|---|---|
| 4 (default) | 1,378,356 kB | 1,259,892 kB | 118,464 kB | 29.6 MB |
| 256 | 8,892,848 kB | 1,259,552 kB | 7,633,296 kB | 30.3 MB |

Two points, one slope, agreeing with REALSHAPE's 29.8 MB/position to within 2%.
At `C_MAXPOS = 256` this is **7.63 GB of GHDL storage that nothing read**.

### 9. Every existing gate row still passes

Full unfiltered `bash sim/regress.sh` on a `git archive 9d7a9e5` tree with only
this track's five files added:

```
 suite sim   PASS 63   FAIL 3   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 89   FAIL 3   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 6
   - sim:tb_matvec_axi
   - sim:tb_matvec_core
   - sim:tb_matvec_int4
 REGRESSION: FAIL
```

**The three failures are not this change and not a value: they are a MISSING
FILE.**  All three read `cannot open file "../tr.txt"`, none of the three has
`llama_top` or `attn_kv_axi` anywhere in its closure, and `sim/tr.txt` is
UNTRACKED -- `git ls-files sim/tr.txt` is empty and `git log -- sim/tr.txt` is
empty -- so it is absent from every `git archive` tree by construction.
Copying the working tree's `sim/tr.txt` in and re-running exactly those rows:

```
PASS       sim:tb_matvec_axi     1s
PASS       sim:tb_matvec_core    0s
PASS       sim:tb_matvec_int4    1s
 OVERALL     PASS 10   FAIL 0 ...   REGRESSION: PASS
```

So the tree's real total is **92 PASS, 0 FAIL**, of which 2 are this track's new
rows.  Both benches whose closure contains `attn_kv_axi` beside the
`tb_llama_top` family -- `tb_attn_kv_axi` and `tb_attn_kv_seam` -- passed in the
full run.

### 11. The `tb_llama_top` family CANNOT tell the two orderings apart

The family agreeing before and after is only evidence if the family could have
disagreed.  MEASURED: a third run of the same four benches, on the same
pristine `5578132` tree with the same two `rtl/` files, but with `stmem_p`
mutated to the WRONG ordering -- write before read, the memory
`tb_stmem_equiv` catches on 2,488 of 20,064 cycles:

| bench | EXP_X0 | EXP_XSUM | EXP_XALL | EXP_STEPH |
|---|---|---|---|---|
| `tb_llama_top` | -12739 | 38863 | 38863 | 6432 |
| `tb_llama_top_seq` | -14252 | 7668 | 96762 | 57526 |
| `tb_llama_top_real` | -16364 | 91622 | 91622 | 17333 |
| `tb_llama_top_normw` | -16350 | 90889 | 90889 | 18618 |

`OVERALL PASS 6 FAIL 0`, and **all sixteen numbers are identical to both the
before and the after columns in section 5**.  The mutant is green.

So the family's agreement in section 5 is worth exactly nothing as evidence
about R2, and the DERIVED reason holds: `b_tk0` is hardwired '1' and
`gdn_recur_pipe` masks the state read at tk0, so the recurrent state is written
and never read back and the read-during-write case cannot arise.  The
sixteen-landmark result is a real check on the other five fixes -- REGMAX,
VN_W, POSW, the two KV bounds and the moved cache -- and a vacuous one on this.
`sim/tb_stmem_equiv.vhd` is not belt and braces; it is the only oracle R2 has.

### 10. Checks that do NOT bite, reported under their own names

A check nobody has seen fail has not been shown to work, so the ones that
could not be made to fail at any reachable input are listed here rather than
counted as coverage.

- **`CHK_KV_GRAN` is SHADOWED at every sensible geometry.**  It is declared
  after `CHK_KV_NBLK`, and `attn_head_dim` is 256, so every `C_KV_BLOCK` small
  enough to break the granule rule is also small enough to break the NBLK
  bound and the NBLK check refuses first.  To show it works at all the matrix
  has to use `C_KV_BLOCK = 17`, which is not a divisor of 256 and is a
  geometry nobody would build: `C_NBLK` truncates to 15, the NBLK bound is
  satisfied, and the granule bound is the only thing left.  MEASURED,
  `bound check failure at rtl/llama_top.vhd:3799`.  At every geometry a real
  build could reach, this check contributes NOTHING.
- **`attn_kv_axi`'s concurrent `assert NBLK*EXP_W/8 <= CH_B` at `:455` is
  still unreachable**, and it was left in place deliberately.  The new
  constant fires during declaration elaboration, so the assert can never run
  at an illegal NBLK.  It is documentation now, not a check.
- **The `tb_llama_top` family cannot distinguish read-first from write-first**
  (see the "Measured and REJECTED" entry).  Its sixteen landmarks are
  therefore a check on the other five fixes and a vacuous one on R2.
- **`EXP_W` in `attn_kv_axi` is asserted `= 8` and `CHK_HDR_FITS` divides by a
  literal 8 alongside it.**  If that assert were ever relaxed the constant
  would need rewriting; nothing in this track exercises `EXP_W /= 8`.

## Measured and REJECTED -- do not retry

- **Converting `semem` to a process variable as well.**  Line 2846 is
  `se_rdata <= semem(...)`, a concurrent combinational read that `gdn_block`'s
  port contract requires.  A variable cannot be read by a concurrent statement,
  so the conversion means registering the read, which changes a port's timing.
  179 MB is not worth a design change to a seam.
- **A mechanical `<=` to `:=` edit that keeps the original statement order.**
  That is the write-first memory, and it is a DIFFERENT memory: 2,488 differing
  cycles out of 20,064 in `tb_stmem_equiv`.  This is the specific mistake the
  bench exists to catch, and it is the one a hurried R2 fix would make.
- **Relying on the `tb_llama_top` family to validate R2.**  MEASURED, not
  argued: the family was run a THIRD time with `stmem` mutated to the
  write-first ordering -- the wrong memory, the one `tb_stmem_equiv` catches on
  2,488 cycles -- and the result is in section 11.  DERIVED reason: `b_tk0` is
  hardwired '1' and `gdn_recur_pipe` masks the state read at tk0
  (`rtl/gdn_recur_pipe.vhd:503,722`), so the recurrent state is written and
  never read back and the read-during-write case cannot arise.  The family is a
  good check on the other five fixes and, on R2, exactly as strong as its
  mutant score says.
- **Expressing R1's or R3's check as `assert ... severity failure`.**
  MEASURED above: Vivado completes synthesis with the assert violated.  And
  `llama_top` IS read by Vivado, via `sim/ooc_compose_bcd.tcl`.
- **`CHK_VN_W := (2**VN_W - 1) - region_max(SHAPE)`.**  Correct for every VN_W
  anyone will use and wrong at VN_W 31, where `2**VN_W` overflows a 32-bit
  integer and the check fails on a LEGAL width.  Written as
  `VN_W - clog2(region_max(SHAPE) + 1)`, which is the same claim.  The same
  trap applies to `2**C_KV_ADDR_W` in R5, and the constant there is written
  with `clog2` for the same reason.
- **Dropping the `C_CTXLEN < 2**POSW` clause instead of widening POSW**
  (REALSHAPE's item 5, first alternative).  `attn_kv_axi:542` range-checks
  `to_integer(ctx_len) > MAXCTX`, so the count must be representable; at
  MAXPOS 256 and POSW 8 the wrapped value is 0 and the check would pass it.
- **Setting `REGMAX`'s default to a bare `region_max(SHAPE)` without checking
  what that does at the scaled shape.**  It is in fact the right value -- both
  benches that instantiate this file already compute exactly that expression
  (`sim/tb_llama_top.vhd:606`, `sim/tb_llama_top_smp.vhd:112`) -- but that had
  to be checked, not assumed, because a scaled `region_max` is 128 and the old
  default was 4096.  `VN_W` is the case where it was NOT safe: the shape-derived
  value at the scaled shape is 8, so its default is
  `maximum(13, clog2(region_max(SHAPE)+1))` and the scaled shape keeps its 13.
- **`ghdl -e` and `ghdl -m`.**  The project's recorded mcode trap fired again:
  `ghdl -m llama_top` returns 0 and prints nothing on the design that needed
  46 GB to elaborate.  Every row in this file is `ghdl -r`.

## Measurement traps hit

- **`ghdl -i` leaves every package obsolete, and it bit exactly where
  REALSHAPE said it would.**  Analysing `sim/tb_realshape_9b.vhd` after
  `ghdl -i rtl/*.vhd` but before `ghdl -m llama_top` gives
  `package "llama_map_pkg" is obsoleted by package "model_cfg_pkg"`, which
  reads as a source error in the new bench and is purely an ordering artefact.
  `sim/regress.sh` builds closures in dependency order and never sees this.
- **The first `--only llama_top` baseline run and this track's own
  `tb_llama_top_real` run collided on the same box.**  `ps` showed another
  track's `tb_llama_top_real` running from a different scratch directory at the
  same moment.  It changes wall times and it cannot change a landmark, because
  every run is in its own `REGRESS_SCRATCH`.
- **`nohup ... &` inside a backgrounded tool call returns immediately and the
  harness reports the job "completed".**  Three progress checks read an empty
  log and could have been mistaken for a finished run with no output.  The tell
  is `pgrep -c ghdl-mcode`, not the notification.
- **A gate row that only ELABORATES must say so in its own report string.**
  `tb_realshape_9b` prints `REALSHAPE 9B: PASS` and the sentence "No value was
  checked and none is claimed" in the same report, because a bare PASS in a
  gate log is exactly how "structure is not values" gets forgotten.
- **A FULL GATE RUN ON A `git archive` TREE FAILS THREE ROWS THAT HAVE NOTHING
  TO DO WITH THE CHANGE.**  `sim/tr.txt` is untracked, three `tb_matvec_*` rows
  read it as `../tr.txt`, and a `git archive` tree cannot contain it.  The
  first read of that verdict is `REGRESSION: FAIL` with three failures in
  `rtl/matvec_int4`'s neighbourhood, which is a plausible-looking regression
  and is not one.  The tell is `cannot open file`, not an assertion.  Copy the
  working tree's `sim/tr.txt` in before believing a full-run verdict on an
  archive tree, and note that the same absence silently lowers the achievable
  `BASELINE_PASS` (see "The gate").
- **`git ls-files <path>` exits 0 whether or not the path is tracked**, so
  `git ls-files sim/tr.txt; echo rc=$?` prints `rc=0` for an untracked file and
  reads as confirmation that it IS tracked.  The answer is whether it printed
  the PATH, which it did not.
- **`regress.sh --only` is a SUBSTRING match**, so `--only llama_top` also
  pulled in `tb_llama_top_smp` and `_smp_beh`.  That is six rows, not four, and
  the extra two have no landmarks -- which looks like two missing measurements
  until you notice they are different benches.

## STOPPED, because it is a decision and not a fix

**Subsystem C's KV memory-map generics are still scaled-shape values, and every
one of them is ILLEGAL at the real `attn_head_dim` 256.**  As they ship:

| generic | default | at attn_head_dim 256 |
|---|---|---|
| `C_KV_BLOCK` | 4 | NBLK 64, refused by `CHK_KV_NBLK` |
| `C_K_BASE` / `C_V_BASE` | 16 / 4064 | two 34,816-byte regions that overlap |
| `C_KV_ADDR_W` | 16 | 65,536 bytes for a pair that needs 69,632 |
| `C_MAXPOS` | 4 | a four-position cache |

This track did NOT change them, and the reason is that they are not a bound to
be corrected -- they are a memory map.  Picking `C_K_BASE`, `C_V_BASE`,
`C_KV_ADDR_W` and `C_MAXPOS` means placing the KV cache in HBM against
everything else that lives there, which is
`docs/2026-08-27_hbm-residency-map.md` and TRACK WEIGHTS' territory, and
picking `C_KV_BLOCK` between the two legal values (16, exactly on the header
bound, and 32, with one bit of margin) is a bandwidth-versus-header-overhead
trade nobody has costed.  `C_REAL` and `C_KV_AXI` both default FALSE, so none
of these is read on the default path and nothing is broken by leaving them;
they become live the moment somebody turns the real C on at the real shape,
and they will then be refused BY NAME rather than silently wrong, which is the
whole point of the five new constants.

**This is the one item in the brief's list this track deliberately did not
decide.**  It needs Oren, or TRACK WEIGHTS' residency map, not another agent.

## What was NOT determined

- **No value at the real shape was checked, and none can be yet.**  Everything
  here is elaboration and static ranges.  The composed design elaborating at
  9B says nothing about whether it computes at 9B, and the `err_unit_stub` /
  attention-stub position is exactly where REALSHAPE left it.
- **No simulation was RUN at the real shape.**  `tb_realshape_9b` drives no
  clock.  Whether the 9B token schedule can be walked is open.
- **The exact expression that used to overflow in R4 was still not pinned
  down.**  The new constant fires first, so the overflow is now unreachable and
  the question is moot rather than answered.  The suspected site remains
  `wbuf(0)(NBLK*EXP_W-1 downto 0)` at `attn_kv_axi.vhd:829` against a 128-bit
  element.
- **The `llama_top` OOC area figures were NOT re-measured after the REGMAX
  default change.**  `sim/ooc_compose_bcd.tcl` is TRACK COMPOSE's file.  The
  change is expected to grow the flat region array roughly 3x at the real
  shape, and the old figure was of a design that could not address its widest
  region.
- **`EPOCH_W` is still unexercised**, as REALSHAPE left it.
- **Nothing was measured about `stmem` as INFERRED HARDWARE.**  A read-first
  variable array in a clocked process is the standard inferred-RAM template and
  `llama_top` is a modelling file whose region store is explicitly behavioural,
  but no synthesis run was done on this entity as part of this track, and the
  store is HBM-resident in the design
  (`docs/2026-08-27_hbm-residency-map.md:177`), so nothing should infer it at
  all.

## What changed, file by file

`rtl/llama_top.vhd`

- `REGMAX` default `4096` -> `region_max(SHAPE)`.  (R1)
- `VN_W` default `13` -> `maximum(13, clog2(region_max(SHAPE) + 1))`.  (R3)
- New architecture constants `CHK_REGMAX`, `CHK_VN_W`.  (R1, R3)
- `stmem` moved from an architecture-level signal to a `stmem_p` variable, and
  the read block moved BEFORE the write block.  (R2)
- `POSW` `clog2(C_MAXPOS)` -> `clog2(C_MAXPOS + 1)`, and the
  `C_CTXLEN < 2**POSW` clause dropped as now-implied.  (R6)
- `gkvaxi` given a declarative part with `CHK_KV_NBLK`, `CHK_KV_GRAN`,
  `CHK_KV_CTX`, `KVREG_B`, `CHK_KV_FIT`, plus a new concurrent assert for the
  address-space bound with a readable message.  (R4 mirror, R5, R6)
- `kvhdr`/`kvmem` moved inside `gkvmem`.  (the dead cache)
- The banner's attention line made conditional on `C_REAL`; it contradicted the
  `:3673` report in the same log.
- Two stale comments corrected in place: the `tb_llama_top_real` landmark pair
  (`-16339 / 92903` -> `-16364 / 91622`, wrong since `a77d181`) and "not in any
  synthesis flow".

`rtl/attn_kv_axi.vhd`

- New constant `CHK_HDR_FITS`.  The concurrent assert at `:455` is kept: where
  it is reachable its message is better than a range error.  (R4)

New files, all owned by this track:

- `sim/tb_stmem_equiv.vhd` -- the R2 equivalence oracle with its control.
- `sim/tb_realshape_9b.vhd` -- the default-shape elaboration, as a gate row.
- `sim/realshape_gate.sh` -- the 19-row matrix including the ten guards that
  must refuse, which cannot live in a testbench.

## The gate

`BASELINE_PASS` +2, for `sim/tb_realshape_9b` and `sim/tb_stmem_equiv`.  Both
were verified as gate rows individually (`--only realshape`, `--only
stmem_equiv`, `OVERALL PASS 1 FAIL 0` each) and in the full run above.

**THE FLOOR CANNOT BE VALIDATED ON A COMMITTED TREE, and that is a finding
about `sim/regress.sh` rather than about this change.**  A `git archive
9d7a9e5` checkout plans 102 rows, of which 4 are NOCHECK and 6 are SKIPPED, so
its ceiling is **92 PASS** -- 90 without this track's two.  `BASELINE_PASS` was
94 before this change, i.e. FOUR above what a clean checkout of the tree it was
written against can produce.  The difference is that the working tree carries
about twenty UNTRACKED `sim/tb_*.vhd` files from in-flight tracks, and
`regress.sh` auto-discovers that glob, so the floor is being calibrated against
whatever happens to be lying in `sim/` rather than against the repository.  A
fresh clone therefore reports `BASELINE DROP` and `REGRESSION: FAIL` today,
before and after this change, by the same margin.

This track did not fix that: `sim/regress.sh` is shared, six tracks edited it
today, and the number is other tracks' bookkeeping.  +2 keeps the invariant
those tracks are maintaining.  Raised here so somebody owns it.
