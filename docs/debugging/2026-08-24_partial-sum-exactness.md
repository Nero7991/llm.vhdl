# Is the cross-card partial-sum reduction exact, and what width does E need?

Date: 2026-08-24
Build: `ref/matvec_int4.c` (extended this date), gcc -O2, x86-64; RTL chain
re-verified with `sh sim/run_matvec.sh` (all green, 0 mismatches).
Defect: subsystem A spec §15.4b, "OPEN DEFECT. Blocks subsystem E's datapath
width, which cannot be settled until this is."

## The question

§14.2 of the A spec stated, nineteen lines apart:

> 3. The reduction is therefore **not exact**: alignment is a floor-mode
>    rounding site.

> ... sums (**exactly**, since integer addition of the same terms is
> associative) ... **bit-identical** to the full-K path.

Both cannot hold, because each card BFP-packs its own `x` slice and so carries
its own `x_exp`. The C reference validated only the equal-`x_exp` case, which
production never hits. Two candidate resolutions: (1) align to min `y_exp`,
floor, accept and bound the loss; (2) align to max `y_exp` with a widened
accumulator, keeping the reduction exact.

## The answer

**Option 1. Align to the minimum `y_exp` with a floor right shift, sum in an
`s(48 + clog2(N))` accumulator, and drop the bit-identity claim -- which was
unsalvageable under either option.**

- **E's accumulator width: `ACC_W = 48 + clog2(N_PEERS)` -- s49 at N=2, s50 at
  N=4, s51 at N=8; s52 covers N <= 16.** E §2.1's old `s36` was wrong twice
  over (derived from an s32 partial A stopped emitting on 2026-08-22, and from
  a shared-grid premise that never held); it is corrected in place.
- The alignment loss is bounded below `N-1` ulp of the coarsest partial's grid
  (linear in N) and **measured at 0 counts of the post-round s32 at N=2 and
  N=8, 1 count at N=4, and 0 at the contractual worst-case exponent spread of
  17**. Against the yardstick of A's own weight format (+1.69% perplexity from
  ~8% relative weight error), this is zero.
- **Bit-identity to the single-card full-K path is dead under BOTH options**,
  because the per-card `x` packs upstream already consume a different
  quantization of `x` than a single card would. Measured: the sharded path is
  ~19x *closer* to the exact unquantized oracle than the single-card path on
  slice-disparate data (7.2e-5 vs 1.4e-3 max relative error). Option 2
  preserves only the exactness of the reduction *step*, a property with no
  observable consequence, at the price of an s68 accumulator at N=8.

No subsystem A change is required. A's frozen RTL already emits the unrounded
s48 partial on 64-bit `y_data` lanes and the per-job `y_exp`. What the
resolution adds on A's side is **policy only**: the packer gives all shards of
one row-parallel matvec the same `w_exp`, and the PS programs one `out_shift`
everywhere. Both are offline/software choices.

Spec edits made the same date: A §14.2 (contradiction corrected, superseded
claim marked), A §15.4b (RESOLVED), E §1.3 / §2.1 / §2.3 / §2.4 / §2.6.

## The procedure

Every step is executable; the reference was extended rather than argued with
(`ref/matvec_int4.c`, the "15.4b" test blocks; `cc -O2 -Wall -Wextra`, then run
from `sim/` so the golden vectors resolve).

1. **Construct the differing-`x_exp` case production actually hits.** Raw
   "previous-op" outputs `u[k]` on a common grid, with a real magnitude
   disparity between K-slices (2^27 vs 2^19). Each shard's slice is packed with
   `bfp_pack` semantics over the slice alone -- its own amax, its own `ns` --
   exactly as `bfp_pack.vhd` does per card. This isolates the mechanism: the
   spread comes only from the per-slice packs.
2. **Run both candidate E reductions on the SAME partials.** Option 1 in
   int64; option 2 in `__int128` (it does not fit int64 -- itself a datum).
   Both then take the same single `round_shift(out_shift)` + `sat32`, landing
   on the same grid, so their outputs are directly comparable integers.
3. **Check the derived bound by execution, not by prose:** per row,
   `0 <= s2 - (s1 << D) < (N-1) << D`, where `s2 >> D` is the exact sum on the
   min grid. This is the (N-1)-ulp floor-loss bound as an assertion.
4. **Compare both to an exact oracle** -- same quantized weights, unquantized
   activations, `__int128` integer bilinear form -- and to the single-card
   full-K job with a single global `x` pack. The oracle is what separates
   "option 1 vs option 2" (alignment loss) from "sharded vs single-card"
   (upstream input-quantization divergence). Without it the two effects blur.
5. **Scale N: 2, 4, 8**, with a per-slice magnitude ramp so every slice packs
   to a different grid, re-checking bound, accumulator width, and post-round
   divergence at each N.
6. **Drive the spread to its contractual maximum (17)** with a full-scale s32
   value in one slice and a tiny slice beside it, and re-check everything.
7. **Measure typical spread at production shapes** (K=17408 contiguous slices;
   K=6144 as 24 heads x 256 split by head as §14.3 shards it), 200 trials x
   four distributions -- no matvec needed, spread is a property of the packs.
8. **Measure spread on real activations.** Instrumented a scratchpad copy of
   `ref/run.c` (untouched in the repo) to dump the two row-parallel inputs of
   stories260K -- `hb` (FFN down, K=172) and pre-`wo` `xb` (attn o, K=64,
   split by head) -- over a 256-token generation: 1,280 real vectors per
   tensor, per-slice `ns` spread at N=2/4/8.
9. **Re-run the full RTL-vs-C chain** (`sh sim/run_matvec.sh`) to confirm the
   reference extension broke nothing the RTL validates against.

## The evidence

Self-test output (verbatim, abridged to the new tests):

```
  14.4 partial-sum: 2 half-K shards == 1 full-K job, BIT-EXACT PASS
  15.4b shards land on DIFFERENT grids (spread 8) PASS
  15.4b option-1 error < (N-1) ulp of min grid   PASS
     measured option1-vs-option2 max divergence: 0 s32 count(s)
  15.4b option1 vs option2 post-round: <= 1 count PASS
     rel err vs exact oracle: single-card 0.00138  opt1 7.19e-05  opt2 7.19e-05
  15.4b sharded != single-card under EITHER option PASS
  15.4b opt1 within 2x opt2 error (alignment loss negligible) PASS
     N=2: y_exp spread 8   opt1 err bound 1 ulp  measured post-round divergence 0
     N=4: y_exp spread 12  opt1 err bound 3 ulp  measured post-round divergence 1
     N=8: y_exp spread 12  opt1 err bound 7 ulp  measured post-round divergence 0
  15.4b N-scaling: bound, width, <=1 count at N=2/4/8 PASS
  15.4b-adv spread reaches the contractual max 17 PASS
  15.4b-adv option-1 bound holds at spread 17    PASS
  15.4b-adv option-1 sum fits s49 at N=2         PASS
     measured divergence at spread 17: 0 s32 count(s)
  15.4b-adv post-round divergence <= 1 count     PASS
     x_exp spread, 200 trials:  shape/dist         N=2 N=4 N=8 (max)
       17408 uniform                      0   0   0
       17408 gaussian                     0   0   0
       17408 heavy-tail                   0   1   6
        6144 head-scaled                  2   5   6
  15.4b spread stats within contractual bound 17 PASS
OK (0 failures)
```

Real activations, stories260K, 1,280 vectors per tensor (max / mean spread):

```
W2 (FFN down input, K=172, contiguous slices)
  N=2: max=4 mean=1.27    N=4: max=5 mean=1.87    N=8: max=5 mean=2.59
WO (attn o input, K=64, split by head)
  N=2: max=3 mean=1.07    N=4: max=4 mean=1.62    N=8: max=4 mean=2.28
```

RTL chain after the extension: `sim/run_matvec.sh` == all green == (steps 4c
through 7, 0 bad beats, 0 stage mismatches, 0 output mismatches, 0 AXI
readback mismatches).

### Derivation the measurements confirm

Only shifted cards err, each by less than 1 ulp of the min grid, always toward
-infinity (floor), and at least one card has `d_c = 0`. So the pre-round sum
errs by `e in [0, N-1)` ulp, a downward bias of mean ~(N-1)/2 ulp. After
`round_shift(out_shift)` the divergence is at most `floor((N-1)/2^out_shift)+1`
counts of the s32, and after the BFP `ns` shift at most 1 count of the final
int16 mantissa -- a mantissa the pipeline already re-rounds by up to 0.5 ulp at
every layer boundary. Relative to operand scale, `(N-1)` ulp against partials
of ~2^30-2^36 ulp magnitude is ~2^-27 at N=8: five orders below the ~8%
relative weight error that costs +1.69% perplexity.

Error scaling with N: linear, `< N-1` ulp -- N=2 (near-term, second card on
the way) is the best case, and N=8 is still measured at 0 post-round counts.

Accumulator: A's contract asserts `|y_acc| < 2^47`; alignment only shrinks
magnitude (floor adds at most 1). N summands: `48 + clog2(N)` bits. The
value-level bound is far smaller (~2^36 when slices partition K <= 17408) but
E cannot verify its peers partition anything, so the width derives from A's
interface contract.

### Resource cost, stated rather than assumed

| item | option 1 (chosen) | option 2 (rejected) |
|---|---|---|
| accumulator / row-sum width | s49 (N=2) .. s51 (N=8), declare s52 | s66 (N=2) .. s68 (N=8): 48 + 17 spread + clog2(N) |
| sum buffer at MAXROWS=17408 | 17408 x 52 b ~= 905 Kb ~= 25 BRAM36 | 17408 x 68 b ~= 1.18 Mb ~= 33 BRAM36 |
| alignment hardware | right shifter, 0..17 | left shifter, 0..17, into the wide adder |
| transport per value | 8 B (A §14.2, unchanged by this choice) | 8 B, but summation domain > 64 b |
| `y_exp` in trailer | required | required |

The `y_exp` transport (one i32 per message trailer) is common to both options
and is not a discriminator; E's spec had omitted it entirely and now carries
it. Message size doubling (20 KB -> 40 KB) comes from A's earlier s48
correction, not from this decision; E §2.4 was still priced at 4 B/value and
is corrected -- receive buffers at N=8 go 140 KB -> 280 KB (~70 BRAM36), and
the estimated unoverlapped collective time at N=8 roughly doubles, which
tightens §2.5's overlap requirement.

## Measured and REJECTED - do not retry

**Option 2 (max-align, exact reduction).** Measured against option 1 on
identical partials: 0 post-round counts of difference at N=2/N=8 and at spread
17, 1 count at N=4; identical 7.19e-5 oracle error to three digits. It cannot
restore single-card bit-identity (see next item), so its exactness buys
nothing observable, and its width must be sized at the contractual spread of
17 -- s68 at N=8, wider than int64, `__int128` in C, a >64-bit adder and a 33%
wider row buffer in RTL. Sizing it at the *measured* spread (<= 6) instead
would be exactly the "agrees with itself and is wrong" trap this project's C1
defect documented. Do not reopen unless a consumer appears that needs the
reduced sum at more than int16-mantissa precision.

**Chasing bit-identity between the N-card and single-card systems.** Measured
dead: with slice-disparate inputs the sharded path (either option) lands
7.2e-5 from the oracle and the single-card path 1.4e-3, because the per-card
`x` packs keep 8 more mantissa bits on the quiet slice. The paths diverge
*upstream* of E at the `bfp_pack` on each card; no reduction policy can
reconcile them, and reconciling them would make the result worse. The
verifiable property is bit-exactness against the C reference (floor alignment
is deterministic), and that is what the corrected specs pin. The 24/24
token-identical acceptance style of the AXU3EG rung does not transfer to
multi-card, independently of the format-perplexity finding that it already
does not transfer to 27B.

**Sizing anything from the spread statistics.** 200-trial synthetic max was 6
and the real-activation max was 5, but the contractual bound is 17 and it is
reachable (one full-scale s32 in one slice, a tiny neighbour). The statistics
justify *error* claims (typical loss ~0) but not *width* claims; E's err check
uses 17.

## Measurement traps hit

**The 14.4 test's PASS was the trap this defect names.** It shares one `x_exp`
across shards, so the partials happen to land on one grid and sum exactly, and
"BIT-EXACT PASS" prints while proving only the special case. The new tests
gate on `ra.y_exp != rb.y_exp` first, so a future refactor that accidentally
re-equalizes the exponents fails loudly instead of proving nothing again.

**Comparing option 1 to option 2 requires landing both on the same grid.**
Option 2's single round is by `out_shift + D`, not `out_shift`; rounding at
`out_shift` and then shifting by `D` double-rounds and manufactures fake
divergence. The test rounds once by the combined shift.

**The option-2 emulation silently overflows int64.** An s48 partial left-
shifted by spread 17 is 65 bits before the first add. gcc's `__int128` with a
divide-based floor (mirroring `mv4i_floor_shr`, since `>>` on negative
signed values is implementation-defined pre-C23) was used throughout; an
int64 version would have wrapped and "measured" garbage divergence.

**The oracle must exclude the per-block floor.** The exact comparator is the
integer bilinear form `sum cb*sc*u[k]` (no `>>15` per block); folding site 1
into the oracle charges the format's own rounding to the reduction under test.

**`pow`/`ldexp` would not link.** The reference builds with no `-lm`
(`cc -O2 -Wall -Wextra`, also inside `sim/run_matvec.sh`); a local `pow2i`
avoids adding a link dependency to every harness that compiles this file.

**Real-activation slicing dropped a tail at N=8.** K=172 is not divisible by
8; the analysis sliced `floor(K/N)` per card and ignored the last 4 elements
at N=8. Negligible for a spread statistic, but stated rather than hidden.

## Open, not yet answered

- **Real 27B activation spread is unmeasured.** The real-activation numbers
  are stories260K (dim 64, hidden 172, 5 layers) -- real dynamics, toy scale.
  Qwen3.8-27B per-head and per-slice disparity could be larger (attention
  head magnitude disparity grows with model size in the literature). The
  contractual bound of 17 and the err check make this a robustness question,
  not a correctness one, but the *typical* 27B spread should be measured when
  a forward pass with activation taps exists.
- **End-to-end model-quality cost of option 1 is asserted from magnitude, not
  measured as perplexity.** At <= 1 count of the final int16 mantissa per
  collective, ~2^-27 relative at N=8, it sits five orders below the format's
  measured +1.69%; a perplexity A/B of the reduction alone is not currently
  runnable (no multi-card system exists) and would measure noise.
- **E §2.4's timing table remains estimate-grade.** The 40 KB message doubles
  transfer time per hop; whether the collective is still effectively
  latency-bound depends on the unmeasured P2P numbers §3 already gates on.
- **`out_shift` calibration headroom across the full K range** (A §14.2's
  existing requirement) is unchanged by this resolution but also still
  unvalidated against real 27B tensors; `sat_event` remains the runtime
  detector.
- The E spec's §3 (transport bring-up) remains deliberately unwritten; this
  resolution feeds its C-reference bullet but does not write it.
