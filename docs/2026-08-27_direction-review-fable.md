# Direction review: where the next block of effort goes, and what kills this project

**Date:** 2026-08-27. Independent read by a different model (Fable), deliberately
not the one implementing. Nothing was synthesized, simulated, or edited for this
review; every number below is quoted from a spec, a `docs/debugging/*.md`
measurement, or `sim/*.csv`, or recomputed from those with the arithmetic shown.
Claims are labelled VERIFIED (read and recomputed) or INFERRED.

## The answer, up front

**Finish B's integration first (option a), scoped to include the block-level C
reference and a real-activation drive of the composed block.** Then C (option d),
then D (option c). Option (b) is mostly moot: C's aux row and D-vec are already
measured at micro level, and the residual unmeasured DSP spread is 42 of 2,880,
1.5% of the die; more skeletons cannot answer the question that matters, which is
whether the composed die routes at its clock.

The highest-probability project-killer is not the DSP ceiling, the clock, or the
latency denominator, all of which degrade gracefully. It is the class of defect
the project has already produced twice: a unit that is bit-exact against its
golden while computing the wrong function on the majority of real inputs. That
class is invisible to the project's verification method by construction, and most
of the numeric surface has never been driven by real model activations. The cheap
experiment is software-only: substitute B's (then C's) fixed-point reference into
the llama.cpp forward pass and measure perplexity, exactly as was already done
for A's weight format.

Also settled below: **the disputed 589,824-cycle sweep denominator is correct.**
The doubt is an artifact of a numeric coincidence, shown in full.

---

## 1. Where the next substantial block of effort goes

### Ranking: (a) > (d) > (c) > (b)

### First: (a) finish B's integration

Four reasons, in decreasing order of weight.

**1. It is the only candidate that retires standing correctness risk rather than
adding surface.** The state of B (VERIFIED from
`2026-08-26_gdn-emit-chain-integration.md` and B spec 3.6): 10 units bit-exact in
isolation; three of four output-chain seams need glue that does not exist; nothing
computes `gdn_y_emit.in_e`; the F1 epsilon fix exists as RTL (`rmsnorm_bf`) but
the epsilon's grid is still an open decision; both emit stores are single-buffered
and, as built, serialize the recurrence (F2: 605,952 cycles = 102.7% of the sweep,
bundle margin 0.52). Every one of these is a defect or a decision that only
integration forces. The project has already demonstrated, twice, that unit-level
certification does not compose (`l2norm` recipe collapse; rmsnorm epsilon); the
emit-chain document adds that even the handshakes did not compose. Ten verified
units that do not connect are not a subsystem.

**2. B's ports must be final before D can be designed, by B's own spec.** B §2.6
(VERIFIED): the recurrence is stall-intolerant by construction, "the real state
feed therefore needs a column-wide elastic buffer and a drain interlock in front
of this unit, and that integration piece is written down nowhere. It should be,
before D's sequencer is designed against this port." Starting D now (option c)
means designing control against ports that the seam decisions (widen `gdn_y_emit`
vs adapt `gdn_silu`; where `z_exp` rides; the elastic buffer) will change.

**3. The B block sequencer is a working prototype of D's GDN arm.** The unit the
emit-chain document says is missing (per-head loop, 24 heads, norm then gate then
fold, exponent bookkeeping) is exactly the shape of D §4.2's 18-step GDN layer at
smaller scale. The effort transfers; none of it is thrown away when D starts.

**4. It co-produces the killer experiment's instrument.** The integration needs a
block-level C reference to verify against; that same reference is what the
question-2 experiment plugs into llama.cpp. One deliverable, two payoffs.

**A guard on scope, from the arithmetic:** B is not the throughput lever and
should not be polished as one. Token time at N=2 is ~39 ms of which A+C are
~35.1 ms (VERIFIED, D §11); B's budget is ~2.0 ms. Even the worst case, nothing
overlapping and F2 unfixed, is

```
589,824 (sweep) + 529,440 (bundle) + 605,952 (emits) = 1,725,216 cycles
= 5.75 ms at 300 MHz  ->  +3.75 ms on a 39 ms token  ->  about -9% tok/s
```

So the ENTIRE remaining B schedule question is bounded at ~9% of throughput. The
reason to do (a) first is correctness and dependency order, not speed, and the
right scope is: the three seam adapters, the F2 double-banking (structurally
identical to the `k_n`/`q_s` fix that measured free), the epsilon grid decision,
the block sequencer, the elastic state feed, and the block reference. Not further
cycle-budget refinement.

### Second: (d) start C

C is the largest latency term with no RTL: ~4.6 ms/token at 300 MHz, 36% on top
of A's time, doubling at 4K context (VERIFIED, A §15.4c and D §11). Its two known
blocking items are C-internal and cannot be discharged by anything else: the
MACS lane-geometry quantum (64 is not divisible by the 27B's 6 query heads per KV
head; legal points are 96/192/288, A §15.4c) and the QK-norm's clock. Its numeric
contract has had none of the real-activation exposure that just caught B's
epsilon. C should start as soon as B's block testbench exists, and its KV/softmax
contract should go through the same perplexity harness before its RTL hardens.

### Third: (c) start D

Nothing runs without D, but D is almost entirely control (its DSP is D-vec's
measured 28), and its §13 is a list of REQUESTS to other subsystems. Writing it
before B's and C's port shapes are final converts every seam decision into D
rework. D's real deliverable now is cheap and useful: keep its obligations table
current as (a) and (d) pin ports.

### Last: (b) skeletons for measured DSP rows

The premise is stale (VERIFIED against `2026-08-25_whole-die-budget-
reconciliation.md`, C §3.8, D §12): C's aux row is measured unit by unit (50-54),
C's MAC array is a measured per-lane fit, D-vec is measured OOC at 10 sweep
points (28 shared / 52 unshared), E is 0 DSP by a construction argument. The
audit's own open list reduces the unmeasured die to two terms: C's QK-norm lane
count (+4 to +22) and D's phase sharing (+0 to +24). Total spread 42 DSP = 1.5%
of the die. A skeleton campaign tightens that and answers nothing else. The
question that actually hangs over the 90.5-91.9% figure is routability at that
density, and only a placed-and-routed composition experiment answers it (see
question 2, secondary risk).

---

## 2. The highest-probability project-killer

### First, the listed candidates, and why each degrades rather than kills

- **DSP ceiling (90.5-91.9%).** A's rows are the marginal consumer at a measured
  33.00 DSP/row. Over-budget by 100 DSP means dropping 3 of 58 rows, about -5% of
  A's rate (and a re-pack, since `ROWS_IF` sets the pack format). Graceful.
  VERIFIED: A §15.4a, B §3.6 die table.
- **The clock.** Every Fmax in every budget is Vivado's 0.85 V analysis; the card
  runs 0.717 V (wiper 68, deliberately, with droop margin); the 0.72 V timing
  library crashes on any HBM-facing design, so no analysis exists at the
  operating point; the measured bounds are -22.9% (OOC re-analysis of A's core)
  and no-worse-than -15.8% (one HBM design that passed on hardware). VERIFIED.
  Worst case ~300 -> ~231 MHz. That scales token time AND bandwidth (usable HBM
  is `32 B x 32 ch x f_ACLK` = 307.2 GB/s at 300 MHz, clock-bound, measured) by
  the same ~0.77-0.84. It makes v3.0 slower; it does not make it not work. The
  units that individually miss (rmsnorm at 8/16 lanes: 179.9/116.4 MHz,
  `sim/rmsnorm_bf_lanes.csv`) are not in the schedule; the schedule's chosen lane
  counts all close at 0.85 V.
- **The disputed 589,824 denominator: RESOLVED, the number is right.** VERIFIED
  by recomputation. §3.1 derives it at 27B per card: `128 x 128 x 24 v-heads =
  393,216 elements/layer/card, x 48 layers = 18,874,368, / 32 lanes = 589,824`.
  §2.5's body (line 1091) derives the SAME number for the 0.8B at LANES=8:
  `262,144 x 18 / 8 = 589,824`. The coincidence is exact because
  `(24/16) x (48/18) = 4 = 32/8`. Two independent derivations at two targets
  landing on one value is what manufactured the suspicion of a stale copy; both
  are self-consistent, and the 27B one is anchored by hardware-adjacent
  measurement: `gdn_recur_pipe`'s II is exactly NB at every lane count, so
  4 cycles/column at LANES=32 is measured, not assumed. The 393,216 figure in
  the framing is elements per LAYER per card, not cycles per token; no ratio
  built on 589,824 inherits any doubt. (The one caveat that stands: H=16 vs 24
  confusions are real elsewhere, audit F6, but not here.)
- **HBM bandwidth.** A's demand at the balanced point is 212-258 GB/s against
  307.2 usable at 300 MHz with 1.3x port provisioning already applied; B needs
  38.4 GB/s on 4 ports delivering 47.1 measured. Fits, with the whole margin
  riding on the clock (previous bullet). VERIFIED: A §15.1, B §3.1/§3.4,
  `2026-08-25_hbm-upper-bound-is-the-clock.md`.

### The actual killer: the epsilon class, at every site real activations have not reached

The project's verification method is bit-exactness against derived goldens plus
mutation testing. That method has now been beaten twice in two days, both times
by the same mechanism, both times certifying a unit that computes the wrong
function:

- `l2norm` recipe collapse: q path emitted all zeros for every `ssq >= 2^33`,
  k path up to 41% error, 55 test cases passing, because the golden shared
  `fixed_pkg.rsqrt_q` with the DUT. VERIFIED,
  `2026-08-25_l2norm-recipe-collapse.md`.
- rmsnorm epsilon (audit F1): no epsilon anywhere in subsystem B; on 2,741,760
  real 27B activations the model's `eps = 1e-6` DOMINATES `mean(x^2)` on 72.57%
  of samples and the RTL is 14x wrong at the median; the item was marked CLOSED
  because `rmsnorm_rs` is bit-exact with `rmsnorm.vhd`, which is wrong the same
  way. VERIFIED, `2026-08-26_rmsnorm-magnitude-window.md`.

Add the three first-token grid defects in §2.1.4 (one of which, applied alone,
made the recipe 7x WORSE while its own measurement table said it was improving),
and the base rate of spec-level numeric wrongness is roughly one instance per
audited unit-week. Every instance was invisible to bit-exact testing; the two
that were caught were caught by a different number system or by real
activations.

What has never been driven by real Qwen3.8-27B activations (VERIFIED from the
drift document's own open list and the audit): the L2 norm's k path ("no number
in either document can see a normalizer error of any size" -- flagged, still
open), the conv, silu and the z gate, the scalar path (whether the real `beta`
distribution reaches the non-contracting regime is explicitly "RATE UNKNOWN, SIZE
MEASURED"), the emit chain's exponent arithmetic, and the entirety of C's
contract. The drift bound itself is synthetic gaussians with real `exp(g)`
values only.

This is the one failure mode with (i) a demonstrated base rate, (ii) structural
invisibility to the existing test method, (iii) whole-model consequence -- a 14x
error in a per-head norm is not a perplexity tax, it is garbage output -- and
(iv) discovery, by default, only after the full engine is built and produces
wrong tokens on silicon.

**The cheap experiment that settles it soonest:** the A-format perplexity
harness already exists and already answered exactly this question for A
(+1.69% ppl, `2026-08-24_subsystem-a-format-perplexity.md`). Extend it: run the
composed B block reference (the §2.1 fixed-point contract end to end, which
option (a) has to build anyway) inside the llama.cpp forward pass for the 48 GDN
layers and measure wikitext perplexity against the shipped model. Pure software,
no Vivado, days not weeks. Do the same for C's contract before C's RTL hardens.
A passing number retires the largest risk in the project; a failing number is
worth more, found now.

**Secondary killer, worth one cheap experiment but not the next block of
effort:** whole-die routability at ~91% DSP with A's cascade-column geometry, at
the real clock. All resource evidence is OOC; the 90% line is folklore imported
from a 360-DSP part (traced, B §3.6); congestion on UltraScale+ binds on cascade
geometry and routing, not on the DSP percentage. The experiment is a
placed-and-routed fill: A's real 58-row array plus C-array and B-lane tiles as
dummy-loaded instances, one build, and read the routed WNS. It converts the
folklore threshold into a number and it prices the OOC-to-routed Fmax gap at the
same time.

---

## 3. What is being over-invested in

The double-oracle discipline itself is not the over-investment -- the
different-number-system oracle is what caught the recurrence defect, and the
mutation testing is what makes the l2norm closure mean anything. Keep both. The
misallocation is depth against breadth:

1. **Ten units at mutation-tested bit-exactness; zero pairs ever simulated
   together.** The integration document found three broken seams by reading port
   lists, meaning no two-unit co-simulation has ever existed. The marginal defect
   found by an eleventh unit-level test is now far smaller than the marginal
   defect found by the first composed test. VERIFIED.

2. **Cycle-budget refinement on a subsystem bounded at 9% of the token.** The
   +72% -> +36% -> +11.4% margin war in §3.3, three nested dated corrections,
   each internally rigorous -- on a bundle whose total possible impact on v3.0
   throughput is ~9% (arithmetic in section 1). Meanwhile the A+C 35.1 ms that is
   90% of the token has had no comparable scrutiny since §15.4c, and C has no
   RTL. The correction recursion has also itself produced errors (the ceiling
   that never followed from its own components, audit; F14's 19,200 orphan
   cycles), which is what happens when documentation carries more precision than
   its inputs.

3. **Single-DSP accounting against 42-DSP unknowns and a folklore threshold.**
   B's row is now known to the DSP (227, audit F12) while D's sharing spread is
   24, C's QK-norm spread is 18, and the 90% line those digits are compared
   against has never been tested on this part. Precision is being spent where it
   is cheapest, not where the decision lives.

4. **The tok/s ladder has not been re-derived and is now misleading by ~2-3x.**
   Recon still carries "v3.0 ~43-61 tok/s" from the 460 GB/s bandwidth-bound
   model. The design is compute-bound at the achievable `ROWS_IF`: D §11's sum is
   ~39 ms = ~26 tok/s at 0.85 V-analysis clocks, and ~20-22 tok/s at the 0.717 V
   operating point (INFERRED: applying the bounded -16 to -23% derate). Against
   the 2x3090 baseline of 70 tok/s, v3.0 is a ~3x slowdown, not the ~1x the
   ladder implies. The recon already says rung one is not a speed upgrade; the
   number should still be honest, because it changes what v4.0 has to deliver.

---

## 4. What has nobody checked

Specific, load-bearing, absent from every document read:

1. **Whole-engine power against the FK33's VCCINT regulator.** The rail is rated
   0.85 V at 120 A (~102 W); the card is a mining card being repurposed for a
   different duty cycle, deliberately parked at 0.717 V, 19 mV above its own
   alarm floor, with droop margin cited as the reason not to go lower. Nobody
   has estimated what ~2,600 active DSPs at ~300 MHz plus ~282K LUT plus 30 HBM
   ports draw. INFERRED order-of-magnitude: 50-80 W on VCCINT is 70-110 A at
   0.717 V -- the same order as the regulator's rating. If the rail droops under
   the real engine, the failure is functional and intermittent, and every
   timing-derate number gets worse nonlinearly. Cheap to check twice over: one
   `report_power` on any large build, and one PSU-side measurement of the
   existing 30-port hbmbw bitstream under sustained load (that bitstream is the
   worst HBM-side load the project owns). The recon's VCCHBM 20 A note covers
   the memory rail only; VCCINT is the unexamined one.

2. **No die-wide BRAM/URAM sum exists.** B §2.6 flags this itself and nobody has
   done it: B ~50-60 BRAM36 (including `gdn_recur_pipe`'s 24.5), D ~86 flat map
   plus ~44 URAM of 320, C ~43, A's weight-stream FIFOs unquantified, E's
   receive buffers. Against 672 BRAM36 it probably fits (INFERRED), but "every
   subsystem rounds its own tail to zero" is the exact mechanism that inflated
   the DSP confidence, in the spec's own words.

3. **No single clock frequency at which the composed engine closes has ever been
   named.** A closes 276.1-287.9 (OOC), B's units 299.04-300.75 with the 2-lane
   l2norm at exactly 300.0 and WNS -0.025, C's rope at 206.4, all OOC at 0.85 V,
   no two units ever synthesized together, no cross-unit path ever priced. The
   budgets mix 276, 288, 299 and 300 MHz. A composed, routed design runs at the
   minimum over all of it minus congestion, and units closing within 0.2% of
   target in OOC will not hold that number placed. The fill experiment in
   section 2 prices this for free.

4. **The two-card premise is entirely untested and only one card exists.** v3.0
   cannot run on one card (7.04 GiB shard against 8 GiB HBM); P2P feasibility is
   a documented-IP argument, not a measurement; and nobody has computed the
   fallback cost if peer writes do not work (host-bounce of 5.12 MB/token/card
   through the chipset slots). INFERRED: the fallback is survivable at N=2
   (order +10-30% token time) but nobody has done that arithmetic anywhere.

5. **The packed shard size against 8 GiB has not been verified by packing.** The
   89% capacity figure excludes padding and alignment; the recon's own
   instruction was "verify by quantizing the model to subsystem A's exact format
   and measuring the packer output before committing hardware". The perplexity
   work already quantized the full model to A's format, so the check is nearly
   free, and it has not been recorded anywhere.

6. Smaller, already flagged by their own documents but still open, listed so
   they are not lost: the real `beta` distribution from the GGUF (the drift
   document calls it its single highest-value follow-up; it decides whether the
   non-contracting regime is reachable); `exp_q`'s kernel error and the Q15
   quantization measured in the same run; the L2-norm k path through the fixed
   recipe with a real oracle.

Of these, item 1 is the most important: it is the only one that is absent from
every document rather than flagged-and-deferred, it sits under the voltage plane
that every timing number already depends on, and both halves of the check cost
hours.

---

## What I could not determine

- **The actual voltage derate of the engine at 0.717 V.** Bounded (<= 15.8% for
  one design, 22.9% for one OOC netlist), not measured, and unmeasurable by
  analysis for HBM designs. Only a failing hardware point brackets it.
- **Whether the four B phases overlap.** No schedule has been exhibited; the
  spec itself says treat +11.4% as an upper bound. The 9% token-level bound in
  section 1 caps the damage but does not answer the question.
- **The true cycle costs of the two emit stages.** F2's 270 and 6,144 are the
  units' own header estimates; no GHDL timing run exists. The 48x count error
  and the single-buffer serialization stand regardless.
- **Whether 0.85 V is a usable operating point on this card** (cooling, the
  wiper's 16 mV/step sensitivity near code 27-30, volatile writes). If it is,
  most of the clock discussion above relaxes; nothing read here settles it.
- **C's real aux behavior under its own schedule** (QK-norm lane count, the rope
  unit's clock path) -- identified, unresolved, C-internal.
- **Anything about E beyond arithmetic.** Zero RTL, zero hardware, and the
  0-DSP claim is a construction argument. At N=2 its budget is small enough
  that this is acceptable risk for now; at N=8 it is not.
