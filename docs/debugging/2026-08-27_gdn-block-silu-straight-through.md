# gdn_block: silu goes straight through the conv, and what the second pass was worth

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`, on top of `3c2789e`. Changed:
`rtl/gdn_block.vhd`, `sim/tb_gdn_block.vhd`, `sim/run_gdn_block.sh`.
No other RTL touched.
**Tools:** GHDL 1.0.0 mcode, `ghdl -r` direct, `--stop-time` and
`--max-stack-alloc=0` on every run.
**Vivado was NOT run.** Every cycle figure below is a simulated count. Nothing
here is a synthesis or place-and-route result.

---

## The question

Verbatim, from the coordinator, 2026-08-27:

> Rework `rtl/gdn_block.vhd` so silu is a STRAIGHT-THROUGH connection off
> `gdn_conv`'s output stream rather than a second pass over the staging buffer.
> [...] Report the cycle saving as a MEASURED number, not an estimate. [...]
> Keep the five-independent-producer skew testbench passing in every
> configuration it already passes in, and add a configuration that specifically
> stresses the new straight-through path.

Background: `docs/debugging/2026-08-27_gdn-block-top-level.md` found that
`gdn_conv` published `e_seg` at `S_FIN`, after the data it described, so the
conv output could not be piped into `u_silu_conv` at all. `gdn_block` buffered
each segment and made a second pass. `b94e2f8` moved the publication to `S_SH`,
three cycles ahead of the first `o_valid`.

And, added mid-task, a second question:

> Your 367 cycles/head deadline is now stale. [...] Please re-run that sweep
> and report the new boundary as a fresh pair of numbers.

---

## The answer

**The second pass is gone, the output is bit-identical, and the saving is one
pass over the conv width plus 4 cycles of state per segment:**

```
saving per layer = sum over the 3 segments of (nch / CONV_LANES) + 12
```

Measured at three conv widths, one token, every other generic held:

| conv width | beats | old (buffered) | new (straight) | saved | beats + 12 |
|---|---|---|---|---|---|
| 256 ch (`KEY_HEADS=2 VAL_HEADS=4 DIM=32`) | 64 | 2,293 | 2,217 | **76** | 76 |
| 512 ch (`KEY_HEADS=4 VAL_HEADS=8 DIM=32`) | 128 | 4,193 | 4,053 | **140** | 140 |
| 1,024 ch (`KEY_HEADS=2 VAL_HEADS=4 DIM=128`) | 256 | 5,200 | 4,932 | **268** | 268 |

The model is exact at every point measured, not approximate.

**At the 9B shipping shape that is 2,060 cycles per layer, 49,440 per token**
(conv width q 2,048 + k 2,048 + v 4,096 = 8,192 channels, `CONV_LANES=4`, so
2,048 beats + 12, times 24 GDN layers). That figure is DERIVED from the model
above, not measured: a single layer at the full 9B width is a ~400,000-cycle
simulation. The three points the model is fitted on are measured.

Against the state sweep that is 2,060 cycles removed from a 16,384-cycle
layer, **12.6%**. The absolute conv-path total before and after is NOT quoted
here: the measurement is whole-block cycles per token, and decomposing it into
per-phase totals would be an inference, not a measurement.

**The dumps are bit-identical between the buffered and straight-through forms
at every shape measured.** This is a pure schedule change.

---

## The procedure

1. Re-read the three files that changed under this work rather than working
   from memory: `rtl/gdn_conv.vhd` (`b94e2f8`), `rtl/gdn_emit_chain.vhd`
   (`1b8baf3`), `rtl/rmsnorm_bf.vhd` (`3c2789e`).
2. Wire `cs_valid <= cv_ovalid; cs_data <= cv_odata;` and delete the
   `P_CVDONE` / `P_SIFEED` / `P_SIDRAIN` states, replacing them with a single
   `P_CVDRAIN`.
3. Latch the segment exponent, because the straight wire changes how it is
   read. See "the two hazards" below.
4. Instrument the testbench with a per-token cycle count taken from the
   `start` edge to `busy` falling, which is exactly one layer for one token.
5. Build TWO libraries from the SAME current RTL, differing only in
   `gdn_block.vhd` -- the committed `5750c37` version against the new one --
   and run the same stimulus through both. This is the step that makes the
   number a measurement of the change rather than of the week.
6. Re-run the full skew matrix, with two new `CV_GAP` configurations.
7. Re-run the per-head deadline bisection, which two other commits invalidated.

---

## The two hazards the straight wire creates, and what was done about them

Both are instances of the class this block has already been bitten by twice.
Removing a buffering stage is exactly where they appear.

### 1. `e_seg` goes from read-once to read-across-the-whole-segment

The buffered form read `cv_eseg` at ONE instant (`P_CVDONE`) and copied it into
a register. The straight-through form has `gdn_silu` reading `e_seg`
combinationally at stage S0 for EVERY beat of the segment. That is the
`w_mant` / `tvalid` / `cw_exp` shape, for the third time.

It would in fact be safe as a bare wire -- `gdn_conv` holds `e_seg` from one
`S_SH` to the next, and the next `S_SH` is a whole invocation away. That is a
latency argument, and this project has a written rule against those. So:

* `cs_eseg` tracks `cv_eseg` and **freezes on the segment's first output
  beat**. Tracking up to that edge is what makes the copy right for beat 0 as
  well, since the register then already holds what `e_seg` has held since
  `S_SH` three cycles earlier.
* `eseg_taken` is a new output port pulsing at the freeze instant, so the
  latch has an observable edge rather than a timing contract.
* An assertion fails the simulation if `cv_eseg` ever moves while the frozen
  copy is in use.

### 2. `o_done` stops meaning "the segment is done"

The last silu output lands `gdn_silu`'s latency after the last conv beat, which
is after `o_done`. `o_done` is a one-cycle pulse and it now fires while the
tail of the segment is still inside the gate. A `P_CVDRAIN` that waited on it
would truncate every segment by the silu latency and leave the last beats of
q, k and v holding whatever the buffer had before.

`P_CVDRAIN` therefore waits on `obeat = nbeat`, a level, AND on a sticky
capture of the `o_done` pulse. An assertion fires if the collector ever runs
past `nbeat`.

---

## The evidence

### Cross-skew comparison, all eleven configurations

Every dump is compared against the reference run, in which every producer is
maximally ahead and nothing moves after it is taken:

```
  z1: identical to ref
  z7: identical to ref
  z31: identical to ref
  wmove: identical to ref
  scmove: identical to ref
  cwmove: identical to ref
  capbusy: identical to ref
  cvgap1: identical to ref
  cvgap3: identical to ref
  all: identical to ref
  fastall: identical to fastref
```

`all` is `Z_DELAY=5 W_MOVE SC_MOVE CW_MOVE CAP_BUSY CV_GAP=2` together.

### Cycles per token, measured on both blocks against the same libraries

```
--- conv width 64 beats (KEY_HEADS=2 VAL_HEADS=4 DIM=32)
[old_a] CYCLES token 0 = 2293
[new_a] CYCLES token 0 = 2217
--- conv width 128 beats (KEY_HEADS=4 VAL_HEADS=8 DIM=32)
[old_b] CYCLES token 0 = 4193
[new_b] CYCLES token 0 = 4053
--- conv width 256 beats (KEY_HEADS=2 VAL_HEADS=4 DIM=128, RECUR_LANES=32)
[old_d128] CYCLES token 0 = 5200
[new_d128] CYCLES token 0 = 4932

64-beat OUTPUT IDENTICAL
128-beat OUTPUT IDENTICAL
d128 OUTPUT IDENTICAL
```

### The per-head deadline, RE-MEASURED after `1b8baf3` and `3c2789e`

Same bisection as before: `HEAD_GAP` moves the column arrival period one cycle
at a time, at `DIM=128 SILU_LANES=16 RMS_LANES=4 RECUR_LANES=64`.

```
arrival 365 cycles/head: COLUMN DROPPED
arrival 366 cycles/head: COLUMN DROPPED
arrival 367 cycles/head: COLUMN DROPPED
arrival 368 cycles/head: COLUMN DROPPED
arrival 369 cycles/head: no column refused
```

**The deadline is now 369 cycles per head, up from 367.** The boundary pair is
368 DROPPED / 369 no column refused.

Consequences at the shipping shape:

| `RECUR_LANES` | arrival | deadline | margin |
|---|---|---|---|
| 32 | 512 | 369 | **+143 cycles, 27.9%** (was +145, 28.3%) |
| 64 | 256 | 369 | **-113 cycles** (was -111) |

`RECUR_LANES=32` still has margin and the conclusion for `RECUR_LANES=64` is
unchanged: it is short by a sustained per-head amount, so no finite elastic
buffer fixes it.

---

## Correction to the coordinator's inference: rmsnorm_bf is NOT off the chain

The brief said, of `3c2789e`:

> `tb_gdn_emit_chain`'s finish time moved 82,058.5 ns to 82,060.5 ns across the
> rmsnorm change. That is 2 ns, not the 288 ns that 2 cycles x 144 invocations
> would cost if rmsnorm sat on the per-head critical chain. So rmsnorm appears
> to have slack and the column bank is still the binding resource.

**Half of that holds and half does not.** The deadline moved 367 -> 369, which
is the rmsnorm change's 2 cycles landing on the per-head chain ONE FOR ONE.
`rmsnorm_bf` is on the chain, not off it.

The two observations do not conflict, and the reason is worth writing down
because the same reasoning will be applied again. `tb_gdn_emit_chain` runs at
`COL_GAP=4`, i.e. 512 cycles per head, which is far ABOVE the deadline. In
that regime the chain is arrival-bound and its per-head service time is hidden
entirely; the only rmsnorm invocation that can show up in the finish time is
the LAST one, whose drain nothing hides. Two cycles is exactly one rmsnorm's
increase. So a 2 ns move in that aggregate is what you would see whether
rmsnorm is on the per-head chain or not, and it cannot distinguish the two
cases.

**An aggregate finish time taken in the arrival-bound regime says nothing about
the per-head deadline.** Only the boundary bisection does, which is why it had
to be re-run rather than inferred.

The other half of the inference is confirmed: the column bank is still the
binding resource, and `RECUR_LANES=32` still has 143 cycles of margin.

---

## Measured and REJECTED -- do not retry

### The stress the coordinator asked for is not constructible, and here is why

The request was for "a conv output arriving while the silu input side is
stalled", on the grounds that the straight-through form removes a buffer that
was absorbing exactly that.

**There is no such state, and it is structural rather than lucky.**
`gdn_silu` has no ready in either direction -- it is a fixed-latency II = 1
pipeline that accepts one group per cycle unconditionally, which
`2026-08-27_B-interface-audit.md` records as the one place in B where "no
back-pressure anywhere" is the right answer. `gdn_conv`'s pass B emits at most
one beat per cycle. Two streams at one beat per cycle with no ready on either
side cannot stall against each other, so the buffer was never absorbing a rate
mismatch. It was only ever absorbing the EXPONENT ORDERING, which is the thing
`b94e2f8` fixed.

`CV_GAP` was added instead and is the honest stress for this path: it stretches
`gdn_conv`'s pass A, which moves the `S_SH` edge that publishes `e_seg` and the
first output beat that freezes the block's copy of it, relative to the block's
own sequencing and to all five other producers. `CV_GAP` 1, 2 and 3 all produce
bit-identical dumps.

### Putting the cycle counts in the comparison dump -- do not retry

The first version of the instrumentation wrote the per-token cycle counts into
the same file the cross-skew diff compares. That file exists to compare
VALUES; every skew axis changes timing by design, so `z7`, `capbusy` and
`cvgap3` would all have "failed" a comparison whose whole point is that they
must not. Cycle counts are reported, never dumped.

---

## Measurement traps hit

* **A before/after measurement across a week of commits is not a measurement of
  the change.** The first old-block baseline was taken against a library built
  before `3c2789e` (which makes `rmsnorm_bf` two cycles longer per
  invocation). Both sides were rebuilt from the same current RTL, differing
  only in `gdn_block.vhd`. The numbers happened to be unchanged -- 2,293 and
  2,217 either way, so `rmsnorm_bf` has slack at the block level and is not on
  the per-token critical chain -- but that is a result, not something that was
  known in advance.
* **Editing an RTL file while a `ghdl -r` matrix is running kills the run** with
  `file "..." has changed and must be reanalysed`, several minutes in and with
  no partial results. Two runs were lost to this. Finish edits, then start the
  sweep.
* `cs_valid` and `cs_data` became concurrent assignments, so their old
  process-driven defaults had to be deleted in the same edit or they are two
  drivers -- which ghdl reports with no line number.

---

## Note on the critical path, which this change touches but does not measure

The 0.717 V post-route run puts the binding path inside `rmsnorm_bf`'s DSP at
3.674 logic / 0.932 net, where the 0.85 V run had it route-dominated in the
gate silu. The guidance is therefore to prefer logic depth over locality.

Structurally, and NOT measured: the buffered form fed `u_silu_conv` through a
`(VCH/CONV_LANES):1` slice mux off the staging buffer -- 1,024:1 at 9B --
registered into `cs_data`. The straight-through form feeds it directly from
`gdn_conv`'s registered `o_data`. That removes a wide mux from the silu input
path, which is a logic-depth reduction in the direction the 0.717 V report
asks for. It is offered as a structural observation only; no synthesis was run
and no Fmax claim is made.

---

## Open, not yet answered

* **No block-level bit-exactness against a C reference.** Still no
  `ref/gdn_block_vec.c`. The claim here is that the straight-through form is
  bit-identical to the buffered form and that the block is skew-invariant --
  not that either computes the right numbers end to end.
* **The 9B per-layer saving of 2,060 cycles is derived from a fitted model,**
  exact at three points but not measured at the full width.
* The 4 cycles per segment of fixed state overhead in the saving were not
  attributed to individual states.
