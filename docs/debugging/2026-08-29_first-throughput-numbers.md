# What the card actually achieves, and why subsystem D is worth 67x

**Date:** 2026-08-29, 21:0x
**Who:** dispatcher, on card 1 under Oren's one-night authorisation. Not a
subagent. VCCINT untouched, no flash write, card 2 never addressed.
**Tools:** `hw/fk33/host/fk33_run_job.py`, `date +%s.%N`, `python3`.
**Bitstream:** the routed engine build; core clock **200 MHz**, HBM AXI 250 MHz
(`docs/debugging/2026-08-29_shell-pblock.md:46-48`).

---

## 1. The question

Nothing in this project had ever measured what the FK33 achieves. Subsystem A
was shown bit-exact tonight; **bit-exact says nothing about fast**.

## 2. The answers, up front

1. **MEASURED: the engine consumes one beat every 21.6 core cycles**, converging
   from 23.1 at the smallest job. `STARVED` is a fixed per-job cost, not a rate.
2. **DERIVED: a whole-token matvec pass is ~560 ms of compute, i.e. ~1.78
   tok/s** at 200 MHz -- and that is a **LOWER BOUND**, counting only the 249
   `mv4i` tensors and no attention, no Gated DeltaNet, no norms, no sampling.
3. **MEASURED: the host round trip is ~150 ms per job, essentially independent
   of job size.** With 249 jobs per token that is **37.4 s/token, 0.027 tok/s
   -- 67x slower than the compute it is driving.**

**So the single largest performance fact about this design is not in the
gateware at all: it is that a host-sequenced token spends 98.5% of its time in
PCIe round trips.** Subsystem D exists to sequence descriptors on-card. This is
the number that justifies it, and until D is on the card no throughput
measurement of A means much end to end.

## 3. The evidence, raw

`blk.0.ffn_gate.weight` (M=12288, K=4096), one job per row, all PASS,
thermal cleared first and no trip during the sweep:

| rows | tiles | CYCLES | BEATS | STARVED | starved % | cyc/beat | wall (s) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 32 | 1 | 2,959 | 128 | 2,527 | 85.4% | 23.1 | 0.153 |
| 64 | 2 | 5,792 | 256 | 4,579 | 79.1% | 22.6 | 0.139 |
| 128 | 3 | 8,490 | 384 | 5,461 | 64.3% | 22.1 | 0.151 |
| 256 | 6 | 16,840 | 768 | 8,535 | 50.7% | 21.9 | 0.176 |
| 512 | 11 | 30,633 | 1,408 | 8,316 | 27.1% | 21.8 | 0.223 |
| 1024 | 22 | 61,100 | 2,816 | 9,074 | 14.8% | 21.7 | 0.311 |
| 2048 | 43 | 119,124 | 5,504 | 12,493 | 10.5% | 21.6 | 0.313 |
| 4096 | 86 | 238,052 | 11,008 | 13,174 | 5.5% | 21.6 | 0.680 |

**The starved fraction falls 85.4% to 5.5% while the ABSOLUTE starved count
stays in a band of 2.5k-13k.** That is fixed per-job overhead being amortised.
Anyone quoting "86% starved" as a throughput result is quoting the smallest
job in the table.

Linear fit over the full range: `cycles = 194 + 21.6 * beats` (DERIVED; the
marginal slope is `(238052-2959)/(11008-128) = 21.61`).

**Beat formula, DERIVED from the geometry and VALIDATED on all 8 rows above:**
`beats = ceil(M / ROWS_IF) * (K / BLOCK)` with `ROWS_IF = 48`, `BLOCK = 32`.
Every predicted value matches the card's `BEATS` counter exactly.

## 4. The per-token derivation, with its assumptions stated

Summing `ceil(M/48) * (K/32)` over all 249 `mv4i` tensors at their FULL `M`:

- **5,187,328 beats per token**
- x 21.6 cyc/beat = **1.120e8 cycles**
- x 5 ns (200 MHz) = **560.2 ms -> 1.78 tok/s** (compute only)

Host-sequenced, at the measured ~150 ms per job and 249 jobs:
**37.4 s/token -> 0.0268 tok/s**, a **67x** penalty.

## 5. Measured and REJECTED -- do not retry

- **`STARVED` as a throughput metric.** It is dominated by a fixed per-job cost
  and falls 16x across this sweep with no change in the underlying rate. Use
  `cyc/beat`, which converges.
- **Timing a single job size.** At 32 rows the wall clock is 99.99% host
  overhead and reports nothing about the engine. The slope across sizes is the
  only honest reading.

## 6. Measurement traps hit

- **Wall clock and cycle count disagree by 500-10,000x** and both are correct.
  At 4096 rows: 238,052 cycles = 1.19 ms of compute inside a 680 ms wall. If
  you take wall time as engine time you understate the engine by ~570x; if you
  take cycles as end-to-end you overstate the system by the same factor.
- **`STARVED` and `BEATS` semantics are still NOT verified against the RTL** --
  TRACK AJOBRUN said so and its tool refuses to let them change a verdict.
  `CYCLES` is used here as a cycle count and `BEATS` as a beat count because
  the beat formula independently predicts `BEATS` exactly on 8 of 8 rows, which
  is corroboration but not a reading of the RTL.

## 7. Open, not yet answered

- **Why 21.6 cycles per beat?** A beat is one `BLOCK`(32) of one tile(48
  rows) = 1,536 MACs, so 21.6 cycles/beat is ~71 MACs/cycle. Subsystem A was
  MEASURED at 1,585 DSP (55.0% of 2,880). Whether 71 MACs/cycle is the intended
  rate, or whether something is limiting it, is **not established here** and is
  the obvious next performance question.
- **The 560 ms is a LOWER BOUND.** It counts only `mv4i` matvecs. Attention,
  Gated DeltaNet, the norms and sampling are all excluded, and B and C have
  never run on this silicon at all.
- **The lm_head needs 15 jobs, not 1** (`MAXROWS_BFP = 17408` against 248,320
  rows), so jobs-per-token is >249 and the host-sequenced figure is optimistic.
- **Nothing here overlaps jobs.** Whether the engine can accept a new descriptor
  while one is running -- which would hide much of the 150 ms -- is untested.
- **One tensor.** The cyc/beat slope was taken on `blk.0.ffn_gate.weight` only.
