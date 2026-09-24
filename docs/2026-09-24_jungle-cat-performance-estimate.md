# Jungle Cat (2x XCVU35P) performance estimate for the 9B, 2026-09-24

Written before the unit arrives (expected Tuesday 2026-09-29). Nothing here is
measured on a Jungle Cat. Companion to the Jungle Cat sections of
`docs/fpga-hardware-recon.md`, and to task H1 in
`~/GitHub/pcie-llm-hardware/docs/04-host-offload-task.md`.

## The question

Oren: "can you do a quick estimation of prefill and gen on that assuming same
75MHz clock?", then "Hopefully the part is the highest speed grade. What would
the perf be on that?"

## The answer

At the same 75 MHz and the same RTL, the Jungle Cat runs the 9B at the **same
speed per die as the FK33 pair**: about **7 tok/s prefill and 3.4 tok/s
generation** at short context. Each VU35P has the same 8 GB HBM and HBM port
count as the FK33's VU33P, and the design is bound by clock and overheads, not
by fabric or bandwidth. The bigger die pays off only through the levers that do
not fit on the FK33: then about **15 tok/s prefill and 7 tok/s generation**
(about 14 with tensor parallelism). A **-3** part is worth roughly **+15%** on
top, not a multiple, and only if it runs at the voltage its grade is specified
at.

## Basis (the model, and what it was checked against)

MEASURED 2026-09-24 on the FK33 pair (build 18,
`hw/fk33/results/card_build18_2026-09-23/profile_pair_2026-09-24/`): one token
at position ~0 costs card 0 (blocks 0-15) **139.8 ms** and card 1 (blocks 16-31
plus the LM head) **159.0 ms** at 75 MHz. Attention's cost grows 2,793.4
cycles per position per token on one card
(`docs/debugging/2026-09-20_token-cost-grows-2793-cycles-per-position.md`),
i.e. **0.0186 ms per position per die** when split over two (DERIVED).

Model: prefill per token = the slower die + 0.0186 ms x (mean position);
generation per token = both dies in series + 0.0186 ms x 2 x position (+ the
host hop today). It reproduces four measured points:

| run | model | measured |
|---|---|---|
| prefill, 2,320-id prompt | 180.6 ms/token | 182.6 |
| prefill, 256-id ctxtest | 161.4 | ~164 |
| decode near position 25 | 308 | ~310 |
| decode at positions 2,320-3,255 | 411 | 413 |

Every cost in it is core cycles, so rates scale linearly with the core clock
while the HBM is not binding. It is not: card 0's A streams about 1.9 GB in
65.5 ms (~29 GB/s) against a port ceiling of 24 x 32 B x 75 MHz = 57.6 GB/s
and an HBM peak of ~460 GB/s.

## Assumptions per column

- **as built**: build 18's design, the two dies linked on the carrier instead
  of through a host, H1 (prompt in, ids out), the LM head skipped on prompt
  positions, pad norms gone (the NORM_HBM fix). DERIVED from the model.
- **levers** (ESTIMATE): per die, B's state double-buffered plus 16 recurrence
  lanes (B 52 -> ~7 ms), SwiGLU lanes (13 -> ~5 ms), overlapped A jobs (A 65/80
  -> ~45/58 ms), norms ~2.5 ms. About 64 ms per die (77 ms on the die with the
  head). These are the levers the FK33's 99.75% CLB excludes; none is built.
- A's hard floor at 75 MHz is ~33 ms per die (1.9 GB at 57.6 GB/s), so the
  levers column is about half of what 75 MHz allows.

## The estimates

Prefill in tok/s by prompt length; generation in tok/s by position, pipelined
across the two dies.

| grade and clock | design | prefill 256 | prefill 2,320 | prefill 8,192 | gen @0 | gen @8,192 | gen @32,768 |
|---|---|---|---|---|---|---|---|
| -1, ~64 MHz if 75 does not close | as built | 6.0 | 5.3 | 3.9 | 2.89 | 1.42 | 0.56 |
| -1, ~64 MHz | levers | 12.4 | 9.7 | 6.0 | 6.03 | 1.91 | 0.63 |
| **-2 / FK33-equivalent, 75 MHz** | as built | **7.0** | 6.2 | 4.6 | **3.40** | 1.67 | 0.66 |
| -2 / FK33-equivalent, 75 MHz | levers | **14.6** | 11.4 | 7.0 | **7.09** | 2.24 | 0.74 |
| -3, ~86 MHz | as built | 8.1 | 7.1 | 5.3 | 3.91 | 1.92 | 0.76 |
| -3, ~86 MHz | levers | 16.8 | 13.1 | 8.1 | 8.16 | 2.58 | 0.85 |

Tensor parallelism across the two dies (subsystem E over the on-carrier link)
instead of the pipeline roughly doubles generation at short context: about 14
tok/s in the levers column at 75 MHz (ESTIMATE, all-reduce cost taken as ~3 ms
per token). Prefill is about the same either way.

## The speed-grade assumption, and why it is only +15%

- **The step between grades is an ESTIMATE**: UltraScale+ fabric Fmax typically
  improves on the order of 10-20% per speed grade. -1 at 0.85x and -3 at 1.15x
  of the FK33 are that rule of thumb, not a Vivado run. **Settle it by
  re-running the card's timing for `xcvu35p-fsvh2104-3-e` and `-1-e`** once a
  VU35P build exists; that is a Vivado analysis, not hardware.
- **The FK33's reference is subtle.** It is `-2L`, every build is signed off
  against Vivado's 0.85 V speed data (no build sets `set_operating_conditions
  -voltage`), and the card runs at **0.717 V** (never 0.85 V, CLAUDE.md). The
  voltage derate MEASURED on hardware for one design is no worse than about
  -16% (`docs/debugging/2026-08-25_voltage-derate-on-hardware.md`), while Vivado
  predicts -23%. So today's 75 MHz already runs on silicon margin below its
  sign-off voltage.
- **A -3 part is specified at a HIGHER VCCINT (0.90 V nominal for UltraScale+
  -3, to be confirmed against DS923), not 0.72 V.** Run under-volted the way
  the FK33 is, it gives up much of its grade advantage, and only the -2L/-1L
  grades are characterised at 0.72 V. Running it at 0.90 V costs power and heat
  on a module whose cooling is a water block.
- **The clock is set by the design's deep paths as much as by the grade.**
  Build 10 failed timing by 5.8 ns at 82% LUT; a faster grade shortens such a
  path by ~15%, pipelining it can shorten it by far more. The bigger die fixes
  congestion-driven detours, not logic depth.
- **The speed grade is not electronically readable** (IDCODE names the device,
  not the grade), and the top mark does not carry it. Tuesday's way to find it
  is empirical: run a known design at rising clocks until it breaks and compare
  with the FK33's breaking point, as the 2026-08-25 derate measurement did.

## What limits all of this

- **Long context is attention's per-position cost.** At 8k and beyond it
  dominates every row, and neither the grade nor the bigger die changes it.
  Fixing C's slope (349 cycles per position per C job; `sim/tb_csweep_rate.vhd`
  reproduces it) is the long-context lever.
- **The JCC-Lite carrier has no fast host path** (USB and 10/100 Ethernet on
  the BMC only), so serving needs H1: token ids in and out suit a slow link.
- **Weight loading**: HBM is volatile and ~2.5 GB per die must go in through
  JTAG or the BMC at every power-up. ESTIMATE: tens of minutes. Unmeasured.
- **The link between the modules** is seen in photos, not demonstrated.

## The 27B, roughly

The Jungle Cat's real draw is 16 GB for the 27B at INT4 (13.5 GB). ESTIMATE,
not modelled (the 27B's layer mix differs): roughly 3 to 3.5x the 9B's per-die
cost, so about 1-2 tok/s generation and 2-4 tok/s prefill with today's design.

## Open, not yet answered

- The actual speed grade and whether 75 MHz closes on it.
- The module's VCCINT range and what the BMC sets it to.
- Whether the on-carrier link carries Aurora at a usable rate.
- A's bound: lanes or weight feed. It decides whether prompt batching can pay.
