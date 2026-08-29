# Does subsystem B have defect C1's shape, and what closes the bench hole?

Date: 2026-08-29.  Track: B-LAYER.  No hardware was touched; every measurement
below is GHDL (mcode backend) at the benches' default shape
`KEY_HEADS=2 VAL_HEADS=4 DIM=32 KCONV=4 TOKENS=2`.

## The question, verbatim

> TRACK B-BLOCK just landed and named this as the top item on its NOT-verified
> list:
>
> > **`layer` is hardwired to 0 in both B benches** -- structurally the same
> > hole that hid defect C1 in `attn_block`, and `gdn_exp_capture` is
> > per-(layer, segment).
>
> Your job is to determine whether subsystem B has the same class of defect,
> and to close the bench hole that would hide it either way.
>
> 1. Establish which B state is per-(layer, ...) by specification and which is
>    per-(layer, ...) in the RTL.
> 2. Determine, with evidence, whether any of it is missing a layer dimension
>    while a single time-shared instance is driven across multiple layers.
> 3. Close the bench hole: exercise `layer` at more than one value.

## The answer, up front

**`rtl/gdn_block.vhd` is CLEAN of the C1 defect.  `rtl/llama_top.vhd` is NOT.**

1. `gdn_block`'s only internal per-layer state is `gdn_exp_capture`, and it
   IS layer-dimensioned: `NENT = LAYERS*SEGS`, addressed
   `cap_layer*SEGS + cap_seg` / `rd_layer*SEGS + rd_seg`
   (`rtl/gdn_exp_capture.vhd:187,194`).  MEASURED clean by a new
   non-interference property: two layers interleaved token-by-token against
   layer-qualified memories reproduce their solo runs bit for bit.

2. **`layer` is used in exactly ONE place inside `gdn_block`** --
   `rtl/gdn_block.vhd:572`, `rd_layer => layer`.  Nothing else in the block
   sees it.  Every other per-layer thing is OUTSIDE the block, on ports that
   carry no layer index at all: `st_*` (recurrent state) is
   `(head, col, group)`, `se_*` (state exponents) is `(head, col)`, `cv_*`
   (conv taps) is `(seg, group)`.  The port contract therefore puts the layer
   fold on the memory OWNER, and never says so.

3. **The one real owner does not do it.**  `rtl/llama_top.vhd`'s `gb_real`
   instantiates ONE `gdn_block` and drives `b_layer` across every GDN layer
   (`rtl/llama_top.vhd:2980`), while its `stmem` is addressed
   `st_whead*DM*NBR + st_wcol*NBR + st_wgrp` (`:2818`, `:2822`) and its
   `semem` `se_whead*DM + se_wcol` (`:2829`, `:2834`).  No layer term in
   either.  That is defect C1's shape exactly, one level up: a time-shared
   block, per-layer state with no layer index, and no bench that could see it.

4. **It is LATENT, not live, today.**  `b_tk0` is hardwired `'1'`
   (`rtl/llama_top.vhd:3114`, "one token only; there is no token loop yet"),
   and at `tk0` `gdn_recur_pipe` masks the state READ and `se_j` never enters
   the exponent minimum (`TK0_ED` defaults true, `rtl/gdn_recur_pipe.vhd:73`,
   `:503`, `:592`, `:722`).  So the shared regions are written and never read
   back.  The defect becomes a wrong number on the first day llama_top grows
   a token loop.  It is NOT fixed here: `rtl/llama_top.vhd` was dirty in the
   working tree with another track's edits.

5. The bench hole is closed on both halves, and each half was shown to fail:

   | mutation | tb_gdn_block NLAYER=1 | tb_gdn_block NLAYER=2 | tb_gdn_block_vec DUT_LAYER=0 | tb_gdn_block_vec DUT_LAYER=1 |
   |---|---|---|---|---|
   | `gdn_exp_capture` loses its layer dimension | PASS | **KILLED** | PASS (pre-change bench) / KILLED (with decoys) | **KILLED** |
   | the state MEMORY loses its layer dimension (llama_top's shape) | PASS | **KILLED** | n/a | n/a |
   | `rd_layer => layer` becomes `rd_layer => 0` | PASS | dies on gdn_conv's assert | PASS | **KILLED** |

   Every "PASS" row in that table is a hole that existed before 2026-08-29.

## Corrections to the brief

**"`gdn_exp_capture` is per-(layer, segment)" -- CONFIRMED.**
`rtl/gdn_exp_capture.vhd:88` `constant NENT : integer := LAYERS * SEGS;`, and
both accesses index by layer.  Also `cnt`, the tap-validity counter array, is
`0 to NENT-1`, so the validity state is per-(layer, segment) too.

**"`layer` is hardwired in exactly two B benches" -- CONFIRMED, with a
qualification.**  `sim/tb_gdn_block.vhd` and `sim/tb_gdn_block_vec.vhd` both
had `layer => 0`.  `sim/tb_gdn_exp_capture.vhd` is a third B bench that
mentions layers and it does NOT have the hole: it sweeps `cap_layer` and
`rd_layer` over `0 .. LAYERS-1` and has a dedicated cross-layer isolation
case (`sim/tb_gdn_exp_capture.vhd:98,108,195,226,234`).  The store's own unit
bench was never blind; only the two block-level benches were.

**"a single B block instance is in fact time-shared across layers at the real
shape" -- CONFIRMED.**  `rtl/llama_top.vhd` has one `u_gdn` inside
`gb_real`, and `b_layer <= j_blk - (j_blk + 1) / SHAPE.attn_interval;` maps
each B job's block ordinal onto a GDN layer index.

**One thing the brief implied that is NOT true.**  The brief framed this as
"is B's state missing a layer dimension".  Inside `gdn_block` the answer is
no, because almost none of B's per-layer state is inside `gdn_block` at all.
The interesting question turned out to be about the PORT CONTRACT: a block
whose memory ports carry no layer index has silently delegated the fold, and
the delegate did not do it.

## The procedure, in the order it was run

1. **Read what `layer` reaches.**  `grep -n layer rtl/gdn_*.vhd`, then the
   architecture of `gdn_block`.  One use, line 572.  This is the whole reason
   the rest of the investigation went to the ports rather than to the block.

2. **Enumerate every piece of retained state in the B path** and ask, for
   each, whether the spec makes it per-layer and whether the RTL indexes it
   that way:

   | state | per-layer by spec? | where it lives | layer-indexed? |
   |---|---|---|---|
   | conv slot exponents + tap-validity counters | yes | `gdn_exp_capture`, INSIDE the block | **yes** |
   | recurrent state S | yes (`DIM*DIM*VAL_HEADS` int16 per layer) | outside, `st_*` port | **no index on the port** |
   | state exponent table | yes (`VAL_HEADS*DIM` bytes per layer) | outside, `se_*` port | **no index on the port** |
   | conv taps `x_in` | yes | outside, `cv_*` port | **no index on the port** |
   | `ssm_norm` weight, `z`, scalars al/dt/a/b | yes | outside, level/handshake ports | re-presented per invocation |
   | `qbuf/kbuf/vbuf/knb/qsb`, `eg_b`, `beta_b`, `seg_e` | no | inside the block | per-invocation working registers |

3. **Find the real memory owner.**  `grep -rln gdn_block` -> `rtl/llama_top.vhd`.
   Read `gb_real`.  The address expressions have no layer term while `b_layer`
   sweeps.  That is the finding.

4. **Ask whether it is live.**  Follow `b_tk0` into `gdn_recur_pipe` and
   `gdn_recur`.  At `tk0` both the state read and `se_j` are masked, so with
   llama_top's single token the fold cannot move a number.  Latent.

5. **Close the value half of the hole.**  `sim/tb_gdn_block_vec.vhd` gets a
   `DUT_LAYER` generic defaulting to **1**, plus DECOY captures into every
   layer it is not running.  The decoys are the part that matters: without
   them a wrong layer index reads an entry that was never written, `tvalid`
   comes back all zero, and `gdn_conv`'s own "no valid taps" assertion fires
   -- which `sim/mutverdict.py` scores ABORT, not KILLED.  With them the same
   wrong index yields a legal exponent that is wrong by a power of two per
   tap, which is what a value oracle is for.

6. **Close the composition half.**  `sim/tb_gdn_block.vhd` grows a second
   phase.  Each layer's token sequence runs alone, then all layers run
   INTERLEAVED, and the bench asserts that every interleaved invocation
   reproduces its own solo run: y stream, `y_exp`, and the final per-layer
   state and state-exponent regions.  The external memories are
   layer-qualified in the bench, because the DUT's ports are not.

7. **Teeth.**  Three mutations, each run at both bench settings.  See the
   table above and the evidence below.

## The evidence, raw

### `layer` is used once

```
$ grep -n "rd_layer => layer" rtl/gdn_block.vhd
572:               rd_req => ec_rd_req, rd_layer => layer, rd_seg => ec_rd_seg,
```

### the store IS layer-dimensioned

```
$ grep -n "a := cap_layer \* SEGS\|a := rd_layer \* SEGS" rtl/gdn_exp_capture.vhd
187:              a := cap_layer * SEGS + cap_seg;
194:              a := rd_layer * SEGS + rd_seg;
```

### llama_top's memories are not

```
$ grep -n "b_layer  <= j_blk\|a := st_whead\*DM\|a := st_rhead\*DM\|se_rdata <= semem\|semem(se_whead\*DM" rtl/llama_top.vhd
2818:          a := st_whead*DM*NBR + st_wcol*NBR + st_wgrp;
2822:          a := st_rhead*DM*NBR + st_rcol*NBR + st_rgrp;
2829:    se_rdata <= semem(se_rhead*DM + se_rcol);
2834:          semem(se_whead*DM + se_wcol) <= se_wdata;
2980:            b_layer  <= j_blk - (j_blk + 1) / SHAPE.attn_interval;
```

### the clean design passes the new property

```
$ ghdl -r --std=08 -frelaxed tb_gdn_block -gOUTFILE=lay2.txt --stop-time=200ms
tb_gdn_block: CYCLES invocation 0 (layer 0 token 0) = 2267
tb_gdn_block: CYCLES invocation 1 (layer 0 token 1) = 2267
tb_gdn_block: CYCLES invocation 2 (layer 1 token 0) = 2267
tb_gdn_block: CYCLES invocation 3 (layer 1 token 1) = 2267
tb_gdn_block: CYCLES invocation 4 (layer 0 token 0) = 2267
tb_gdn_block: CYCLES invocation 5 (layer 1 token 0) = 2267
tb_gdn_block: CYCLES invocation 6 (layer 0 token 1) = 2267
tb_gdn_block: CYCLES invocation 7 (layer 1 token 1) = 2267
tb_gdn_block: layer non-interference OK, 4 interleaved invocations across 2 layers reproduce their own solo runs exactly
tb_gdn_block: PASS, 1024 elements, dump in lay2.txt

real    0m45.459s
```

### it is a strict extension: NLAYER=1 reproduces the pre-change dump

```
$ diff <(grep '^y ' base.txt) <(grep '^y ' n1.txt) | head -5 && echo "Y IDENTICAL"
Y IDENTICAL
$ diff <(grep '^s ' base.txt) <(grep '^s ' n1.txt) | head -3
$ diff <(grep '^e ' base.txt) <(grep '^e ' n1.txt) | head -3
S/E IDENTICAL
$ grep '^blk' base.txt ; grep '^blk' n1.txt
blk 0 n 128 yexp 18
blk 1 n 128 yexp 17
blk 0 lay 0 tok 0 n 128 yexp 18
blk 1 lay 0 tok 1 n 128 yexp 17
```

(`base.txt` is the dump from the bench as it stood at commit `be982b3`.)

### teeth 1: the store loses its layer dimension

`a := cap_layer * SEGS + cap_seg` -> `a := cap_seg`, and the same on the read
side.  This is defect C1's shape transplanted onto B's only internal per-layer
state.

```
=== T1 exp-store loses layer dimension, NLAYER=1 ===
tb_gdn_block: PASS, 256 elements

=== T1 exp-store loses layer dimension, NLAYER=2 ===
tb_gdn_block: LAYER FOLD.  interleaved invocation 5 (layer 1 token 0) element 0 is -1394, the same layer and token running ALONE gave 78
tb_gdn_block: LAYER FOLD.  interleaved invocation 6 y_exp 16, alone it was 17
```

Against the VALUE oracle, the same mutation, showing what the decoys bought:

```
=== FOLD vs PRE-CHANGE vec bench (layer 0, no decoys) ===
tb_gdn_block_vec: y mismatches 0 of 256, state mismatches 0 of 4096, state-exponent mismatches 0 of 128
tb_gdn_block_vec: PASS

=== FOLD vs value oracle WITH decoys, DUT_LAYER=0 ===
tb_gdn_block_vec: token 0 y_exp 12, expected 13     [assertion failure]
=== FOLD vs value oracle WITH decoys, DUT_LAYER=1 ===
tb_gdn_block_vec: token 0 y_exp 12, expected 13     [assertion failure]
```

Bit-exact green before, killed after.

### teeth 2: llama_top's own shape, injected into the bench's memory model

`cur_lay*NSTW` -> `0*NSTW` and `cur_lay*NCOL` -> `0*NCOL` in the bench's own
state and state-exponent memories, i.e. one shared region for every layer,
which is what `rtl/llama_top.vhd` does today.

```
=== T3 state memory loses layer dimension (llama_top's shape), NLAYER=1 ===
tb_gdn_block: PASS, 256 elements

=== T3 state memory loses layer dimension (llama_top's shape), NLAYER=2 ===
tb_gdn_block: LAYER FOLD.  interleaved invocation 6 (layer 0 token 1) element 0 is -11035, the same layer and token running ALONE gave -14301
tb_gdn_block: LAYER FOLD -- 256 of 512 interleaved y elements differ from the SAME layer and token run alone.
```

Half the interleaved output is wrong, and the bench as it stood on 2026-08-28
would have reported PASS.

### teeth 3: `rd_layer => 0`

```
=== M13 rd_layer=>0 vs tb_gdn_block, NLAYER=1 ===   PASS
=== M13 rd_layer=>0 vs tb_gdn_block, NLAYER=2 ===
gdn_conv: no valid taps -- e_ref would be undefined   [assertion failure]

=== M13 rd_layer=>0 vs tb_gdn_block_vec, DUT_LAYER=0 ===
tb_gdn_block_vec: y mismatches 0 of 256 ... PASS
=== M13 rd_layer=>0 vs tb_gdn_block_vec, DUT_LAYER=1 ===
tb_gdn_block_vec: token 0 y_exp 15, expected 13   [assertion failure]
```

### the whole mutation harness after the change

```
CONTROL (unmutated, same path): PASS
MUTATIONS 18   KILLED 16   SURVIVED 2   ABORT 0

SURVIVORS -- these are what the bench CANNOT see:
  M07  segment exponent captured LIVE instead of from the frozen copy
  M13Z  M13 again at DUT_LAYER=0 -- EXPECTED SURVIVOR, the floor
```

M07 is the pre-existing documented survivor.  M13Z is the same mutation as
M13 at `DUT_LAYER=0`, kept as a named survivor because the PAIR is the
measurement: it is the exact resolution floor that the old default sat on.

## Measured and REJECTED -- do not retry

**Comparing the layers against EACH OTHER under identical stimulus.**  The
first version of the interleave phase fed every layer the same numbers and
asserted that layer 1's output equalled layer 0's.  It is a bad property and
it was built and run before the flaw was seen.  Reason it is blind: with
identical inputs, a register carried across invocations without a layer index
holds, at layer 0's SECOND token, exactly the value it would have held in the
solo run, because the intervening layer-1 token produced the same value layer
0's first token did.  The fold cancels out of the comparison.  It caught the
`gdn_exp_capture` mutation only incidentally, through the saturating
tap-validity COUNTER, which does change when invocations are interleaved.
Do not rebuild this.  The correct property is per-layer stimulus plus a
per-layer SOLO reference, which is what shipped.

**Running the block at a non-zero layer WITHOUT decoy captures in the other
layers.**  Measured: `rd_layer => 0` at `DUT_LAYER=1` then trips
`gdn_conv.vhd:225` "no valid taps", because the wrongly-addressed entry has
never been captured.  `sim/mutverdict.py` classifies a design that dies as
ABORT, not KILLED, and that is the right call -- nothing was measured about
the checker's resolution.  A layer test whose only failure mode is a crash is
not a value test.  Decoys turn it into a wrong number.

**Assuming the C1 defect must be inside `gdn_block`.**  It is not, and two
hours could have gone into auditing the block's internals.  `layer` reaching
exactly one port inside the block is what redirects the search outward, and
that is a five-second grep.  Do the grep first.

**Putting the layer axis into `sim/run_gdn_block.sh`'s whole skew matrix.**
Measured: the phase takes the bench from 13 s to 45 s per point, and the
matrix is sixteen points.  The matrix asks whether a PRODUCER SKEW changes
the output; the layer phase asks something else.  It is `-gNLAYER=1` for the
matrix and gets its own two-point section, one clean and one with every skew
on at once.

## Measurement traps hit

**A GHDL workdir carries the analysis, and a relative path does not survive a
`cd`.**  Two mutant runs silently produced no output at all -- not a failure,
not a pass, nothing -- because the run was issued from inside the workdir and
`sim/tb_gdn_block.vhd` no longer resolved, leaving the library holding an
obsoleted architecture.  The tell was an EMPTY grep result rather than an
error line.  Always build the workdir from the repo root and pass absolute
paths to the mutated copies.

**`ghdl -a` of a second copy of the same entity does not replace the first,
it warns.**  Analysing a `git show HEAD:` copy of a testbench into a workdir
that already holds the current one produces
`entity "tb_gdn_block_vec" was also defined in file ...` and then RUNS one of
them.  The line numbers in the report are what tells you which.  Use a fresh
workdir per version rather than reading the warning.

**The regression row for `tb_gdn_block` does NOT pass
`--max-stack-alloc=0`** (`sim/run_gdn_block.sh` does).  Anything that grows a
function return value or a process variable in this bench has to stay under
ghdl-mcode's 128 KB default or the GATE fails while the manual script passes.
The layer-qualified memories and the solo-reference snapshots were sized
against that: 2 x 1024 words x 64 bits = 16 KB at the default shape.  The run
with the gate's exact arguments was made before committing, not assumed.

**The box was memory-tight throughout** -- `free -g` showed 0-3 GB free with
16 GB of swap in use and several Vivado runs in flight.  Every measurement
here is single-threaded GHDL at the small shape for that reason.  A
full-gate run was NOT attempted; see below.

## Open, not yet answered

- **`rtl/llama_top.vhd` is not fixed.**  `stmem` and `semem` in `gb_real`
  need a `b_layer*NSTW` / `b_layer*NCOL` term and the arrays need to grow by
  `NLY`.  At the 9B shape that is `NLY * VAL_HEADS * DIM * DIM` int16 of
  model state, which is why the real design puts it in HBM and why the fix is
  a design decision rather than a one-line edit.  The file was dirty with
  another track's work and was deliberately not touched.
- **The conv TAP port is the third un-layered port** and was not pursued.
  `cv_seg`/`cv_grp` carry no layer, and llama_top's `cvdata_p` is stand-in
  stimulus, so there is nothing to fold there YET.  When the taps become real
  per-layer history the same question applies to them.
- **No full `sim/regress.sh` run was made.**  The two rows this touches were
  each run with the gate's exact arguments and pass; the shared gate was left
  alone because the box had six other tracks on it and a full-gate run under
  contention is famously unreadable here.  `BASELINE_PASS` is unchanged
  because no new `sim/tb_*.vhd` was added.
- **The property is checked at `TOKENS=2` and `NLAYER=2`.**  Two layers is
  the smallest number at which interleaving exists; whether a three-layer
  rotation could expose something two cannot was not measured.
