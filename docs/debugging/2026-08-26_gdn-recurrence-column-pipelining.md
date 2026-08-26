# The recurrence missed its schedule by 14.5x, and it was the control, not the
# arithmetic

Date: 2026-08-26
Units: `rtl/gdn_recur.vhd` (sequential), `rtl/gdn_recur_pipe.vhd` (pipelined)
Spec: B section 2.1.4 (the recurrence), section 3.1 (the sweep budget)

## The question

B section 3.1 budgets the state sweep at 589,824 cycles per token per card,
1.97 ms at 300 MHz, and section 3.3's whole "the nonlinearities hide under the
sweep" argument compares against it. The first real RTL for the recurrence
measured **58 cycles per column at LANES = 32 against an ideal of 4**, i.e.
28.5 ms. Is the budget wrong, is the recurrence infeasible, or is the
implementation wrong?

## The answer

The implementation. `gdn_recur_pipe` reaches an issue interval of **exactly
NB = DIM/LANES at every lane count** -- 4 cycles at LANES = 32 -- bit-identical
to the sequential unit on the same 192 vectors, **at the same 129 DSP**, with
LUT going DOWN from 8.59% of the die to 5.47% and Fmax 302.5 MHz.

The budget's arithmetic was self-consistent all along: 4 cycles for 128
elements at 32 lanes means every one of the four per-element multiplies is busy
every cycle. A unit that runs passes A, B and C sequentially for one column
cannot do that at ANY lane count, because each stage's multiplier idles while
the other stages run and the per-column scalar chain does not shrink with LANES
at all. That is why the miss got WORSE with more lanes: 3.3x at 1, 14.5x at 32.

## The procedure that produced it

1. **Measure cycles per column against the ARITHMETIC ideal, not against a
   wall-clock target.** `128 / LANES` is the floor implied by the DSP count.
   Reporting 58 cycles alone says nothing; reporting 58 against an ideal of 4
   immediately says the multipliers are idle 93% of the time, which points at
   control rather than at the datapath.
2. **Check whether the miss scales with LANES.** It got worse, which rules out
   a per-element cost and points at a fixed per-column overhead.
3. **Decompose the 58.** ~50 of it is the per-column scalar chain: two tree
   reductions, the site-7 normalize, the delta scalar, the `sh` derive. None of
   that shrinks with LANES.
4. **Exploit the property the design already rests on.** Section 2.4's
   column-locality says columns are independent. That is exactly the license to
   put several in flight.
5. **Verify bit-identically against the unit already verified**, so the
   pipelined version inherits the sequential one's two-way verification (against
   the C recipe AND against a double-precision oracle) rather than needing its
   own.

## The procedure that found the BUGS, which is the reusable part

**Drive the columns with an idle GAP between them, then shrink it.** A pipeline
that is arithmetically correct but has a resource shared between overlapping
columns is clean at a large gap and degrades as the gap closes. The bisect
localises the fault to "something is shared" in one run each:

```
GAP=200  mismatches in 60us = 0        <- serialised: arithmetic is right
GAP=64                        7
GAP=32                       20
GAP=16                       39
GAP=8                        73
GAP=4                        91
GAP=0                       133
```

Clean only when nothing overlaps. That single table turned "the pipelined unit
is wrong" into "a resource is shared between overlapping columns", which is a
much smaller search.

## The evidence

Final measurements, OOC on `xcvu33p-fsvh2104-2-e` at 3.322 ns:

| | sequential | pipelined |
|---|---|---|
| DSP at LANES=32 | 129 | **129** |
| cycles per column | 58 | **4** |
| Fmax | 318.9 MHz | 302.5 MHz |
| LUT | 37,748 (8.59%) | **24,037 (5.47%)** |
| FF | 25,109 | 23,213 |
| BRAM | 0 | **24.5 (3.65%)** |
| sweep, per token per card | 28.5 ms | **1.95 ms** |

## Measured and REJECTED -- do not retry

- **Cycle-exact stage alignment.** The first design computed each engine's
  start offset from the pipeline depths and aligned everything to it. One
  miscounted stage and a column reads the previous one's `d_m` silently. The
  shipped design gives each column a SLOT, has the scalar pipelines write their
  results into per-slot parameter files, and has the engines read by slot -- so
  the offsets only have to be large ENOUGH. The first run asserted immediately
  and showed the offsets were one interval short, which the cycle-exact version
  would have turned into wrong numbers instead.
- **A valid bit that is never cleared.** `par1_v`/`par2_v` guard "did the scalar
  chain finish before the engine started". Set but never cleared, the bit stays
  high from whichever column used the slot last and the assertion passes while
  the engine reads stale parameters. **A guard that cannot fail is not a
  guard.** Cleared on consume.
- **Letting Vivado map the reduction trees.** The 42-bit adds go to DSP48E2 by
  default: `2*(LANES-1)` of them, **62 at LANES = 32**, taking the unit from
  `4*LANES+1` to `6*LANES-1` -- 191 DSP, 62 of them for hardware that is not
  multiplying anything. `use_dsp = "no"` on the three trees puts them back in
  fabric. They are off the throughput path (one level per cycle) so CARRY8 is
  ample, and DSPs are the scarce resource on this die, not LUTs.

## Measurement traps hit

- **Single registers for pipeline intermediates.** The scalar chain held `ske`,
  `skm`, `diff`, `dmul` in single registers -- exactly as the sequential unit
  does, correctly, because it only ever has one column in flight. At II = 4 the
  8-stage chain holds two columns and the second overwrites the first
  mid-flight. **Signature: first column right, second half right, everything
  after it wrong.** Every intermediate now travels with its column in a record.
- **Deriving an index from the previous cycle's context.** Engine A read the
  group index back out of the previous cycle's context and added one, which is
  correct only if the previous cycle was the previous group of the same column.
  It is not, at a head boundary or after a gap.
- **Driving an engine off the start pulse AND its run state.** On the pulse
  cycle the group counter still holds the previous column's last index, so the
  engine emits NB+1 groups with the first mis-indexed.
- **THE TESTBENCH CHANGED `k_n`/`q_s` BEFORE DRAINING, not after.** The
  previous head's in-flight columns then finished against the NEXT head's
  vectors. The signature is distinctive and worth memorising: **only `o_acc`
  wrong, only on the last column of each head group, state perfect** -- because
  the state does not depend on `q_s` at all. It looked exactly like a unit bug
  and cost the most time of anything here.
- **Negative shift counts on invalid data.** Every stage of a pipeline
  evaluates on every cycle, including on the invalid context between columns,
  where an exponent difference can be negative. A negative `shift_right` is a
  bound-check FAILURE, not a wrong number, so the simulation dies somewhere
  unrelated. Clamp at both ends; the sequential unit only ever needed the upper
  clamp.

## Open, not yet answered

- **The head-boundary drain, 11.7%, measured and not eliminated.** `k_n` and
  `q_s` are read straight off the ports, so a head boundary needs a ~60-cycle
  drain: on a 128-column head that takes the sweep from 1.95 ms to **2.18 ms**.
  Double-buffering them with a select bit carried in the column context removes
  it for about 4 Kbit. **2.18 ms is the honest figure until then.**
- **24.5 BRAM tiles per unit** is a new entry in B's resource accounting, which
  had treated this unit as using none. 3.65% of the 672 on this part, so it is
  affordable, but it has not been added to section 3.4's totals.
- Whether the same pipelining applies to C's attention datapath, which has the
  same shape (a per-column scalar chain around streaming passes) and the same
  column independence. Not looked at.
