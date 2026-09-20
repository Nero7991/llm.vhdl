# A token costs 2,793 cycles more for every position already in the context, and all of it is C

Date: 2026-09-20. Card: FK33, bitstream
`bitstreams/fk33_qwen35-9b_kvreg-striped_75mhz_2026-09-20.bit` (75 MHz core,
routed WNS +0.061 ns), image
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27` (lane-striped),
Qwen3.5-9B.

## The question

"Every token measured so far has been at a low position. TRACK PREFILL noted
that `attn_block.vhd:1665-1673` makes C sweep `cpos_r+1` positions, and that
no C job has ever been measured at a position other than 0. Does the token
cost depend on the sequence position, and if so by how much and where?"

## The answer

**Token cost is linear in position, `30,115,217 + 2,793.4 * p` core cycles,
and 100% of the slope is subsystem C.** At 75 MHz that is 0.402 s at position
0 and 37.2 us more per position already in the context. A and B are
position-independent to within 104 cycles of 10.9 M (0.001%), which is the
control that makes the attribution airtight.

Consequences, DERIVED from the fit: 2.49 tok/s at position 0, 2.09 at 2,048,
**1.42 at 8,192, 0.62 at 32,768 and 0.35 at 65,536** (`C_MAXPOS`). A token at
the end of the supported context costs **7.08x** the first one.

## Procedure

1. Four token-cycle counts at known final positions, three from the seam's
   `last job cycles` register after ordinary chat runs and one from the
   per-step profiler. The seam figure is the card's own cycle counter for the
   whole GO, so it needs no host timing and cannot be confused with wall time.
2. Fit the line **from the two endpoints only**, then test the two interior
   points against it. Fitting to all four and reporting the residuals would
   not have been a test: with two free parameters and four points a good fit
   is nearly guaranteed. The interior points are the prediction.
3. Attribute the growth by differencing two per-step profiles, one at position
   0 and one at position 238, opcode by opcode. The profiles have identical
   step counts (505 transitions, 310 A jobs, 24 B jobs, 8 C jobs), so the
   difference is per-step cost and not a different program.

## Evidence

Fit from the endpoints (positions 0 and 238), interior points as the test:

```
slope from the two endpoints: 2793.4 cycles per position
intercept: 30115217 cycles
  pos    0  measured   30115217  predicted   30115217  residual      +0 (+0.0000%)
  pos   34  measured   30211827  predicted   30210193  residual   +1634 (+0.0054%)
  pos  223  measured   30744226  predicted   30738145  residual   +6081 (+0.0198%)
  pos  238  measured   30780046  predicted   30780046  residual      +0 (+0.0000%)
```

Opcode attribution, position 0 against position 238:

```
opcode            pos 0         late      delta
B_JOB          15854364     15854408        +44
A_JOB          10890053     10889949       -104
C_JOB            594472      1259324    +664852
VEC_SWG         1967136      1967136         +0
VEC_NORM         736840       736840         +0
VEC_RES           67712        67712         +0
TOTAL          30115217     30780012    +664795
```

The two independent numbers agree: `664,852 / 8 C jobs / 238 positions =
349.2 cycles per position per job`, and `349.2 * 8 = 2,793.7` against the
fitted slope of 2,793.4, a 0.01% agreement between a differenced profile and
a fitted line that share no arithmetic.

DERIVED rate: one layer's KV record for one position is
`kv_bytes_per_layer_per_token = 2176 B` (manifest), which is 68 beats of 32 B,
so C is sweeping at **349.2 / 68 = 5.14 core cycles per beat**. The striped A
engine runs at 1.53 and its datapath floor is 1.00, so C's sweep is roughly
3.4x off the rate the same memory sustains elsewhere. That is the lever, and
it is the same shape as the narrow-mover findings in
`2026-09-20_b-job-660k-cycles.md` and `2026-09-20_d-side-vector-traffic.md`:
a wide memory reached through a one-item-per-cycle path.

## Measured and REJECTED, do not retry

- **Reading the growth off wall time.** The host's `run_chunk` seconds include
  the STATUS poll and the X push; the seam's own cycle counter does not. At
  these magnitudes they agree, but the poll interval was changed today
  (a 50 us `nanosleep` was added), so wall time is not comparable across
  this morning's runs and the card's counter is.
- **Attributing the growth to B.** B is the largest opcode at 51.5% and the
  obvious suspect on size alone. It moved by +44 cycles over 238 positions.
  The profile difference is what settles it; no argument from proportion
  would have.
- **Fitting all four points.** Done first, then discarded: it produces the
  same slope and proves nothing, because the model has two parameters and the
  residuals are not a test of a fit that was allowed to see them.

## Measurement traps hit

- **The profiler catches whichever token is running when it starts**, so the
  captured token's position is not chosen and must be recovered afterwards.
  It was recovered by matching the profile's total (30,780,012) against the
  seam's `last job cycles` (30,780,046) at `seq_pos 238`; the 34-cycle
  difference is the transitions the poll folded. Had those two not matched,
  the profile could not have been placed on the line at all.
- **`C_MAXPOS` is 65,536 on this bitstream but the striped image affords
  75,181 tokens**, so the position axis is bounded by the hardware, not the
  image. The 0.35 tok/s figure at 65,536 is the end of the supported range,
  not an asymptote.

## Open, not yet answered

- Whether C's 5.14 cycles per beat is a handshake, a burst length, or a
  per-position setup cost. The B mover's equivalent turned out to be a
  per-beat handshake, but that is a hypothesis here, not a finding.
- Whether the slope changes once the KV cache exceeds a pseudo-channel's
  working set, which it cannot at these positions: 238 positions is 4.1 MB.
- The intercept's own composition at position 0 is already profiled, but the
  8 C jobs at 74,309 cycles each have never been broken down by phase.
