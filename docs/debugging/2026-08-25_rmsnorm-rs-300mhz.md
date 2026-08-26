# rmsnorm_rs: 138.4 -> 300.8 MHz, bit-exact, and MREG was NOT the fix

**Date:** 2026-08-25
**Part:** xcvu33p-fsvh2104-2L-e, OOC, 3.333 ns (300 MHz), Vivado 2023.2
**RTL:** `rtl/rmsnorm_rs.vhd`  **Test:** `sim/tb_rmsnorm_rs.vhd`
**Reference:** `rtl/rmsnorm.vhd` (unchanged, and instantiated as the golden)

## 1. The question

`rmsnorm.vhd` is correct and unusable at 27B scale: 78 DSP48E2 and **138.4 MHz**
at N=256. Two subsystems were blocked on it, and both had diagnosed the same
suspect:

- **C §3.13 item 1**: the narrowed skeleton reaches only 278.9 MHz; "`MREG` on
  the 34x32 Newton stage is the expected fix, unmeasured".
- **B §3.2/§3.6**: at 5 cycles per element the output norms and L2 norms are
  **4.10x** B's whole state sweep, so no schedule hides them, and B's budget is
  quoted at 300 MHz which no measured form of this unit reached.

`sim/micro/micro_rmsn_lanes.vhd` measured 278.9 MHz at 1, 2 AND 4 lanes --
identical across widths, so one fixed structure rather than a width or fanout
effect. Could a real, bit-exact unit reach 300 MHz, and how much does it cost?

## 2. The answer

**Yes: 300.8 MHz at LANES = 1 and at LANES = 4, bit-exact with `rmsnorm.vhd`
on 64 test cases, at 40 DSP48E2 for the 4-lane form.**

| `LANES` | DSP | LUT | FF | Fmax | cycles at N=128 |
|---|---|---|---|---|---|
| 1 | 22 | 7,258 | 3,307 | **300.8 MHz** | 430 |
| **4** | **40** | 8,494 | 3,655 | **300.8 MHz** | **142** |
| 8 | 64 | 11,038 | 4,205 | 200.0 MHz | 94 |

`DSP = 16 + 6 x LANES` exactly. **LANES = 8 does not close** -- the
lane-accumulate tree takes over -- so 4 is the operating point, and it is the
one B §3.3 asked for.

Against the shipped unit: **4.6x fewer cycles** (142 vs 651) and **2.2x the
clock** (300.8 vs 138.4), for 40 DSP against 78.

**`MREG` was NOT the fix, and pursuing it alone would have failed.** It was one
of six changes, and the smallest. The critical path was never in the Newton
multiplies to begin with -- the first version of this unit, written *with* the
MREG cadence already in it, measured **117.2 MHz**, worse than the original.

## 3. Procedure: bucket the endpoint, fix, re-measure, repeat

Every step below is `report_timing_summary` naming the actual failing path, not
a hypothesis. That is the whole method, and it is why the MREG hypothesis died
quietly instead of consuming the night.

| # | measured critical path | fix | Fmax |
|---|---|---|---|
| 0 | -- (first version, MREG cadence included) | -- | **117.2** |
| 1 | `xe_reg -> DSP A`, 40 levels, 16 CARRY8 | split `S_INV`: the mean divide, exponent shift, clamp, 63-bit MSB scan, normalising barrel shift and ROM lookup were ONE state | 205.2 |
| 2 | `mr_p_reg -> LUT sub -> DSP_MULTIPLIER -> DSP_ALU -> DSP_OUTPUT -> DSP A` | 3 steps per Newton multiply so operands are REGISTERED (AREG/BREG) -- this is the MREG fix, worth 26 MHz | 231.7 |
| 3 | `rq_E_reg -> DSP A`, 18 levels | split `S_RQ_FIN`'s barrel shift from its clamp | 219.6 (worse) |
| 4 | `sh_r_reg -> msq_r/R`, 26 levels, 14 CARRY8 | one operation per state across the whole mean/seed chain (6 states) and the rsqrt tail (3 states) | 253.2 |
| 5 | `shift_total_reg -> o_reg`, 22 levels, 12 CARRY8 | precompute the emit rounding bias once; split the add from the shift | 257.0 |
| 6 | `idx_reg -> MUXF7/F8 -> DSP A`, 13 levels | register the bus fetch: selecting an element from the `N*16` bus is a 128:1 mux and was in the same stage as the multiply | 260.1 |
| 7 | `idx_reg -> mux -> DSP square -> S accumulate` | same split in `S_ACC`: mux, square, accumulate become three stages | **300.8** |

**The rule that fell out of it, and it is the reusable part:** never put two of
{barrel shift, 64-bit add, wide compare, 128:1 bus mux, multiply} in series in
one state. Every violation appeared as the critical path in turn. The states
are free -- the fixed overhead is ~46 cycles against a 3N/LANES element loop
that is 96 at N=128, LANES=4 -- so there is no reason to fuse any of them.

Note step 3 made it **worse** (231.7 -> 219.6). It was kept because it removes a
path that would have re-emerged, and because the next step's measurement showed
the real blocker was elsewhere. A step that loses ground is not automatically
wrong, but it must be measured and not assumed.

## 4. Bit-exactness, and how much the test is actually worth

64 cases at each of LANES 1, 2, 4, 8, 16, all bit-identical in `o_mant` and
`o_exp` against `rmsnorm.vhd` instantiated side by side on the same stimulus.

**The test was nearly worthless at first and the mutation testing is what
showed it.** With 16 random and corner cases, a mutant that seeded the rsqrt
ROM at a **constant** still passed. That is structural, not luck:

> `o_mant[j] = raw[j] >> shift_total`, and `shift_total` comes from
> `max|raw|`, which is itself proportional to `inv`. **The rsqrt very nearly
> cancels out of the mantissas.** All of its precision lands in `o_exp`.

So a bit-exactness test built on random vectors and mantissa comparison is
close to blind to the Newton iteration -- the exact thing C §3.13 and B §3.6
were worried about. Fixed by adding a 30-point **magnitude sweep** and an
18-point **power-of-two straddle**, which walk `max|raw|`'s MSB across bit
positions and make `o_exp` a sharp probe of `inv`.

Mutation results after that (each mutation applied to a copy, verified to
change the file and to compile):

| mutation | caught |
|---|---|
| final Newton shift 31 -> 30 | 38 cases |
| accumulator narrowing broken (`xm*xm` halved) | 33 cases |
| parity fold dropped | 13 cases |
| seed ROM fixed at entry 0 | 7 cases |
| `shift_total` off by one | all |
| emit rounding bias dropped | 68 elements |
| lane-parallel max reduced through a signal (found a REAL bug, below) | LANES=16 |
| **`mean_sq_q` rounding term removed** | **NOT caught** |

The last one is reported rather than hidden: dropping `+N/2` before the mean
shift changes `mean_sq_q` by at most 1 LSB, which after the rsqrt almost never
moves `max|raw|`'s MSB. It is a near-equivalent mutant, and the test does not
distinguish it.

## 5. A real bug the LANES sweep caught

The per-cycle max was written as a loop of signal assignments:

```vhdl
for k in 0 to LANES-1 loop
  if araw > max_raw then max_raw <= araw; end if;   -- WRONG
end loop;
```

A signal holds its old value for every iteration, so the **last** qualifying
lane wins rather than the **largest** -- the running max is invisible to the
other lanes in the same cycle. Wrong at every `LANES > 1`; it passed at 2, 4
and 8 on the test vectors and failed at 16. Fixed by reducing through a
variable. **Testing one lane count would have shipped it.**

## 6. Measured and REJECTED -- do not retry

- **`MREG` as *the* fix.** It is worth 26 MHz of the 183 (step 2). C §3.13
  item 1 and B §3.6 both name it as "the expected fix"; both should be read as
  naming a contributor. The unit built around it measured 117.2 MHz.
- **Storing `raw` to fuse the RAW and EMIT passes** (5N -> 2N). Withdrawn
  earlier the same day: `rmsnorm.vhd`'s `S_RAW` comment records that the
  64x64 indexed array was inferred as UNINITIALIZED distributed RAM in the
  congested engine and produced non-deterministic hardware output. This unit
  keeps the recompute and reaches 3N by pipelining instead.
- **`LANES = 8`.** 64 DSP and 200.0 MHz. The extra throughput is not needed:
  at LANES = 4 the norms already hide under B's sweep with 47% margin.

## 7. Consequences

**B §3.3's budget, with the measured 142 cycles at LANES = 4:**

| term | cycles | ms @ 300 MHz |
|---|---|---|
| output rmsnorm, 1,152 invocations | 163,584 | 0.55 |
| L2 norms, 768 invocations (same unit, see caveat) | 109,056 | 0.36 |
| silu at 4/cycle | 98,304 | 0.33 |
| conv | 30,720 | 0.10 |
| **total, against a 589,824-cycle sweep** | **401,664** | **1.34 (+47% margin)** |

**Whole-die DSP: 2,546 of 2,880 = 88.4%**, from 87.6% -- B's row moves
148 -> 170 (the fixed 18 for a 1-lane `rmsnorm_rs` becomes 40 for the 4-lane
form). Still under the 90% congestion line.

## 8. Open, not yet answered

- **The L2 norm is a DIFFERENT function and this unit does not implement it.**
  B §2.1.3: divide by `sqrt(ssq)` not `sqrt(mean)`, two output quantizations
  per element, the `1/sqrt(128)` fold (not a pure shift), no weight multiply,
  and a deliberate divergence from `ggml_l2_norm` at zero input. The 109,056
  cycles above assume the same per-element cost, which is plausible and
  unverified. **`rmsnorm_rs` closes the rmsnorm half of B §3.6's norm line,
  not the line.**
- **300.8 MHz is OOC synthesis on a bare part.** Routed, in context, at 88.4%
  DSP with 30 HBM ports, at 0.717 V, it will be worse. The FK33 bandwidth
  bitstream closed at +0.017 ns for far simpler logic.
- **`N` is 128 throughout.** C uses N=128; D's layer norm at N=5120 is a
  different problem and D §7.3 already refuses the parallel-bus form.
- **The `mean_sq_q` rounding mutant is undetected** (§4).
- **No back-to-back invocation test.** Each case starts from idle, so
  cross-invocation pipelining is unmeasured and the per-invocation latency
  above is what the budget uses.
