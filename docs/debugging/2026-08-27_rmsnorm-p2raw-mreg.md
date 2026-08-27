# rmsnorm_bf: the second multiply gets its MREG, and the two consumers that made it awkward

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`, on top of `e9f7e6c`. Changed:
`rtl/rmsnorm_bf.vhd` only.
**Tools:** GHDL 1.0.0 mcode, `ghdl -r` direct, `--stop-time` on every run,
`-frelaxed` at BOTH analysis and elaboration for `tb_rmsnorm_bf`.
**Vivado was NOT run.** The post-route numbers quoted are the coordinator's
measurements. No Fmax claim is made here.

---

## The question

Verbatim, from the coordinator, 2026-08-27, after the per-lane silu
replication was measured (232.16 MHz, net on the binding path 2.812 -> 0.530 ns):

> THE NEXT PATH [...]
> `u_rms/ARG__21/DSP_A_B_DATA_INST/CLK -> u_rms/p2_raw_reg[2][63]/D`
> slack -1.007   logic 3.600   net 0.530
> [...] `p2_raw` is the ONLY register on that multiply, so the path is the
> DSP's own A/B input register, through the whole 32x32 multiply, through a
> resize, into a flop -- one stage for the lot. [...]
> **`p2_raw` has two consumers on different schedules.** `:772-773` feeds the
> max tree `mt(0)(k)` through an absolute value, and `:859` feeds
> `p3_sum(k) <= p2_raw(k) + emit_bias`. Adding a stage shifts both, and the
> second site at `:850` is a different pass. Getting the consumers' timing
> wrong here is silent.

---

## The answer

**Done, and the two consumers were not in fact awkward, because of where the
new stage was inserted.**

`p2_m` is the MREG and `p2_raw` stays the PREG, back to back with nothing
between them -- the same idiom already used three times for the Newton
multiplies and a fourth time for the `1/sqrt(2)` fold.

**The insight that made the consumer problem disappear: insert the new stage
BEFORE the `(p2_raw, v2, idx2)` triple, not after it.** Both consumers pair the
data with `v2`, and the pass-3 consumer also pairs it with `idx2`:

* pass 2, stage 2a: `vt(0) <= v2` and reads `p2_raw`
* pass 3, stage 3: `v3 <= v2`, `idx3 <= idx2`, reads `p2_raw`

Keeping those three names on the LAST of the two new stages means every
consumer keeps the identical pairing it already had and shifts by exactly one
cycle automatically. Nothing downstream was re-timed by hand. Renaming the far
end instead, and adjusting each consumer, is precisely how a value from the
wrong pass reaches a correct-looking consumer.

Complete list of what had to change beyond the two multiply sites, and it is
short for the same reason:

* `v2m` / `idx2m` declared, cleared in the reset arm and at both pass entries
  (`S_RQ_CLAMP` before `S_RAW`, `S_SHIFT2` before `S_EMIT`);
* `v2m = '0'` added to BOTH drain conditions. A beat still inside the MREG has
  not reached the abs stage, so leaving `S_RAW` without it truncates the max
  reduction by one beat and reads `max_raw` while the tail is in flight.

**Cost: 2 cycles per rmsnorm invocation, one per pass. The measured per-head
deadline moves 369 -> 370, and `RECUR_LANES=32` still clears with 142 cycles
(27.7%) of margin.**

---

## The procedure

1. Read both sites and enumerate every reference to `p2_raw` rather than
   trusting the two the brief named. `grep` gives exactly two consumers,
   `:806-807` and `:902` in the current file, which matches.
2. Insert `p2_m` as an MREG stage in front of the existing `p2_raw`, keeping
   `p2_raw`, `v2` and `idx2` as the names of the second stage.
3. Add `v2m` to both drain conditions and all three clear sites.
4. `tb_rmsnorm_bf` on all 200 cases, and at FIVE lane counts, not one. This
   file has a recorded LANES-dependent defect that passed at 2, 4 and 8 and
   failed at 16, so a single-lane-count pass is not evidence here.
5. `tb_gdn_emit_chain` in both overlap modes.
6. The eleven-way `gdn_block` skew matrix.
7. Re-measure the per-head deadline by bisection. It cannot be inferred from an
   aggregate finish time; see the correction in
   `2026-08-27_gdn-block-silu-straight-through.md`.

---

## The evidence

### rmsnorm_bf, bit-exact at every lane count

```
rmsnorm_bf: bit-exact ... all 200 cases (25600 elements + 200 exponents), N=128 LANES=1  Q=12
rmsnorm_bf: bit-exact ... all 200 cases (25600 elements + 200 exponents), N=128 LANES=2  Q=12
rmsnorm_bf: bit-exact ... all 200 cases (25600 elements + 200 exponents), N=128 LANES=4  Q=12
rmsnorm_bf: bit-exact ... all 200 cases (25600 elements + 200 exponents), N=128 LANES=8  Q=12
rmsnorm_bf: bit-exact ... all 200 cases (25600 elements + 200 exponents), N=128 LANES=16 Q=12
```

### gdn_emit_chain, both overlap modes

```
tb_gdn_emit_chain: PASS -- 3 blocks x 24 heads x 128 bit-exact, OVERLAP=false COL_GAP=4 refused-column cycles=0
tb_gdn_emit_chain: PASS -- 3 blocks x 24 heads x 128 bit-exact, OVERLAP=true  COL_GAP=4 refused-column cycles=0
```

### The cost is 2 cycles per invocation, and the finish times prove where it surfaces

| mode | before | after | delta |
|---|---|---|---|
| `OVERLAP=false` | 57,818,500 ps | 57,824,500 ps | **+6 cycles** |
| `OVERLAP=true` | 44,392,500 ps | 44,394,500 ps | **+2 cycles** |

72 invocations at +2 cycles each is +144 cycles, and neither number is
anywhere near it. The split is exact and explains itself: `OVERLAP=false`
drains between blocks, so the LAST invocation of each of the 3 blocks surfaces,
3 x 2 = 6. `OVERLAP=true` never drains until the end, so only the final
invocation surfaces, 1 x 2 = 2.

That is the same arrival-bound-regime effect written up in
`2026-08-27_gdn-block-silu-straight-through.md`, now visible in both of its
regimes at once, and it is exactly why the deadline has to be bisected rather
than read off these numbers.

### Requirement 2: the per-head deadline, re-measured

Same bisection, same shape (`DIM=128 SILU_LANES=16 RMS_LANES=4`,
`RECUR_LANES=64` plus `HEAD_GAP`):

```
arrival 369 cycles/head: COLUMN DROPPED
arrival 370 cycles/head: no column refused
```

**369 dropped / 370 passing, up from 368 / 369.** The measured boundary moved
by **1 cycle**.

| `RECUR_LANES` | arrival | deadline | margin |
|---|---|---|---|
| 32 | 512 | 370 | **+142 cycles, 27.7%** (was +143, 27.9%) |
| 64 | 256 | 370 | -114 cycles (was -113) |

**`RECUR_LANES=32` still clears, and the cost against the margin is one
cycle.** Note that the invocation got 2 cycles longer while the boundary moved
1: the bisection is integer-quantized and the pre-change boundary was not
sitting exactly on the service time, so an increase anywhere in (0, 2] lands
where this one did. Do not read the 1 as evidence that only one of the two
added cycles is on the chain -- the measurement cannot separate those, and the
finish-time split above shows both passes did get longer.

### The eleven-way gdn_block skew matrix, and what a token costs

All eleven configurations bit-identical to the reference:

```
  z1: identical to ref        cvgap1:  identical to ref
  z7: identical to ref        cvgap3:  identical to ref
  z31: identical to ref       all:     identical to ref
  wmove: identical to ref     fastall: identical to fastref
  scmove: identical to ref
  cwmove: identical to ref
  capbusy: identical to ref
```

Cycles per token, against the same configurations before this change:

| config | before | after | delta |
|---|---|---|---|
| `ref` / `z*` / `wmove` / `scmove` / `cwmove` / `capbusy` | 2,217 | 2,219 | +2 |
| `cvgap1` | 2,278 | 2,280 | +2 |
| `cvgap3` | 2,400 | 2,402 | +2 |
| `all` | 2,339 | 2,341 | +2 |
| `fastref` / `fastall` | 1,806 | 1,811 | **+5** |
| `w2` (double conv width) | 4,053 | 4,055 | +2 |

Almost everything is +2, one surfacing invocation. `fastref` is +5 and it is
the one configuration where the column producer is fast enough that the chain
is near the arrival bound (`RECUR_LANES=8`, `ISSUE_GAP=1`), so more than one
invocation surfaces. **The odd number is worth noticing rather than smoothing
over: it means the block-level cost is not a whole number of invocations, so
the emit chain and the sweep interleave rather than serialise.** No further
claim is made about it; it was not investigated.

---

## Measured and REJECTED -- do not retry

### Do not put anything between `p2_m` and `p2_raw`

The two flops are back to back so the tool can place them in the DSP48's own
MREG and PREG. Any logic between them -- a resize, a select, an abs -- puts one
of them back in fabric and the change buys nothing while still costing the
cycle. The `resize(..., 64)` stays on the `p2_m` assignment, where it was, so
the truncation behaviour is unchanged and the value is bit-identical.

### Do not rename `p2_raw` to the new first stage

The tempting edit is `p2_raw(k) <= resize(p1_xinv(k) * p1_wm(k), 64)` followed
by a new `p2_reg(k) <= p2_raw(k)`, then repointing both consumers at `p2_reg`.
It is one more line changed, it looks equivalent, and it is the version that
can go silently wrong: the two consumers sit in different passes with different
valid and index chains, and each has to be re-timed by hand. Keeping the
existing names on the downstream stage means neither consumer is touched at
all.

---

## Measurement traps hit

* **`tb_rmsnorm_bf` needs `-frelaxed` at elaboration as well as analysis**, not
  just analysis -- the testbench uses non-protected shared variables. Carried
  forward from the coordinator's note; it would otherwise look like a
  compilation failure of the RTL.
* **One lane count is not evidence in this file.** The recorded max-reduce
  defect passed at LANES 2, 4 and 8 and failed at 16. The sweep is cheap and it
  is the reason five rows appear above.
* **The aggregate finish time cannot give the deadline.** +6 and +2 cycles for
  a change costing +144 across the run is not a contradiction, it is the
  arrival-bound regime hiding per-head service. Bisect.

---

## Open, not yet answered

* **No synthesis.** Whether the tool actually absorbs `p2_m`/`p2_raw` into
  MREG/PREG, and what that does to the 3.600 ns of logic, is unmeasured and
  handed over. The evidence that it CAN is that the same idiom in this file
  already produced the DSP-internal path the current report names as a
  startpoint.
* **DSP count.** Nothing here should add DSPs -- the pair is absorbed into the
  existing DSP48 -- but that is a prediction, not a measurement, and the FF
  count will rise by `LANES * 64` plus two bits if the tool leaves them in
  fabric instead.
* Carried forward from the previous note: `DONT_TOUCH` on `gdn_silu`'s per-lane
  control blocks Vivado's own further replication, so if a later path is
  routing-bound again, that attribute is the first thing to reconsider.
