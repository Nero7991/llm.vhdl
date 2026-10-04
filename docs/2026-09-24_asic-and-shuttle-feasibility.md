# Could the engine be taped out? ASIC and shuttle feasibility, 2026-09-24

Written up 2026-10-04 from a discussion on 2026-09-24 (session `8558101f`).
Nothing here is measured. Every area, cost and bandwidth figure is an
ESTIMATE from rules of thumb, stated as such; shuttle and IP prices in
particular are rough and were not checked against vendor quotes.

## The question

Oren, 2026-09-24: "Assuming we have 4 cards running and the RTL thoroughly
tested, is there a way to tape it out (curiosity)? We only have to do something
about the card to card interconnects or could be 4 dies"

Follow-up: "I meant 4 die cuz I thought there are programs that let you tape
out but are limited in size and I'm not sure what the size would look like, so
we just pull out the interconnect and let them go to the other chip"

## The answer

One engine per die fits an affordable shuttle, and the die-to-die link is
easy. The memory interface is the blocker: a shuttle die has no DRAM PHY at
the hundreds of GB/s each engine needs, so four shuttle dies would be
memory-starved by an order of magnitude and slower than the FPGAs they
replace. A shuttle is worth it as a proof (measure the real clock, power and
area of the RTL as silicon, for a few hundred thousand dollars), not as a
deployment. A deployable chip is a $5-40M project, and nearly all of that cost
is feeding the die with memory bandwidth.

## What converts as-is

The datapaths: A's lanes, B's recurrence, C's array, D's sequencer, the BFP
arithmetic. BRAM, URAM and DSP inferences become SRAM macros and multipliers.
At 28 or 16 nm this RTL would run at 500 MHz to 1 GHz without the
re-pipelining fight, because a logic level that costs about 0.5 ns on the FPGA
costs about 50 ps there.

## What does not convert, and what it costs (ESTIMATE)

- **HBM.** The Xilinx controller and PHY are FPGA hard blocks. On an ASIC
  that means licensed HBM PHY IP (Rambus, Synopsys, Cadence), a silicon
  interposer and 2.5D assembly: several million dollars in IP, and a packaging
  flow only a few OSATs run. GDDR6 avoids the interposer at about 64 GB/s per
  chip, so eight chips give the ~512 GB/s one die needs today. LPDDR5X is
  cheaper and slower.
- **PCIe and any SerDes.** Licensed IP, about $1-2M per PHY at a mature node.
- **Physical design, DFT, verification sign-off.** About $2-5M in services
  without in-house experience.
- **Masks.** About $1-3M at 28 nm, $5-8M at 16 nm, tens of millions at 7 nm
  and below.

Total for a full chip: about **$5-15M and 18 months** at 28 nm with GDDR6, or
**$20-40M** at 16 nm with HBM on an interposer. For comparison, four VU35Ps
cost about $850 in carriers.

**The memory-bound trap.** At 1 GHz the four engines would want about 14.4 GB
of weights per token in about 6.8 ms, i.e. ~2.1 TB/s, which is three HBM3
stacks. Without that, a 28 nm GDDR6 part at 512 GB/s is a ~36 tok/s chip
whatever its logic runs at (figures corrected 2026-10-04, see Corrections).
A full-chip design would put all four engines and the all-reduce ring on one
die, where the ~6 ms per token the Jungle Cat link costs
becomes microseconds.

## One engine per shuttle die

**Size of one engine (ESTIMATE, from the resized-VU35P design row):** about
545K LUTs, 400K flops, 2,750 DSPs and ~52 Mb of SRAM, which is roughly 11-12
million gate equivalents of logic plus 6.5 MB of SRAM. SRAM dominates:

| node | logic | SRAM | one engine die |
|---|---|---|---|
| 65 nm | ~20 mm² | ~55 mm² | ~75 mm² |
| 28 nm | ~6 mm² | ~16 mm² | ~22 mm² |
| 16 nm | ~2.5 mm² | ~8 mm² | ~10 mm² |

**What the shuttle programmes allow:**
- **Tiny Tapeout and the open 130 nm shuttles:** square millimetres or less.
  They fit one subsystem-A lane group or B's recurrence pipe, not an engine.
- **Europractice (TSMC 28/16 nm) and Muse Semiconductor (TSMC):** sold by the
  mm², from about 1 mm² to tens of mm², so a 22 mm² engine at 28 nm is an
  ordinary block. Very roughly $5-10K per mm² at 28 nm and 2-3x that at 16 nm:
  **about $150-300K per engine die per run** before packaging, four times that
  for four dies unless they share a reticle. Academic pricing is lower than
  commercial.

**The die-to-die link is the easy part.** The all-reduce moves about 10 KB
per layer. A 32-pin source-synchronous parallel link at 500 Mb/s per pin
(plain GPIO with a DDR register, no licensed SerDes) carries that in about
5 µs. Four dies in a ring on a small carrier PCB is a solved problem, and on
the RTL side subsystem E's Aurora endpoint becomes that parallel link with
nothing above it changing.

**The memory interface is the blocker.** Each die streams ~3.6 GB per token
(corrected 2026-10-04, see Corrections),
which needs a DRAM PHY at hundreds of GB/s: HBM on an interposer or eight
GDDR6 channels, neither available on a shuttle. Without licensed IP a shuttle
die gets a hand-built DDR3-class interface at a few GB/s, or PSRAM at under
1 GB/s, putting a token at seconds to minutes. Licensed LPDDR5 PHY IP starts
around $0.5M per die design and still tops out near 100 GB/s per channel
group. Letting the FPGA feed the ASIC over the link just moves the bound back
to the FPGA's HBM, so the ASIC adds nothing.

## Expected performance and power (ESTIMATE, added 2026-10-04)

Qwen3.8-27B INT4, batch 1. Nothing here is measured; the method is stated so
each number can be re-derived.

**Method.**
- **Compute time per token:** the FPGA design's own model, the 4x VU35P
  4-way tensor-parallel row at 200 MHz in
  `docs/2026-09-24_jungle-cat-performance-estimate.md` (25 / 10 / 1.05 tok/s at
  position 0 / 16k / 262k), minus its ~6 ms per-token all-reduce (on one die it
  becomes microseconds), scaled linearly to the ASIC clock. Same RTL, no
  ASIC-specific widening.
- **Memory time per token:** 14.4 GB of weights (7.06 + 7.34 GB, the same
  doc's A_JOB rows) plus 34,816 B of KV per position, divided by the memory
  bandwidth.
- **Token time = the larger of the two.** Generation and prefill are the same
  per token today, because the design runs prompts token by token (no prompt
  batching).

**Generation (and today's prefill), tok/s:**

| option | logic clock | position 0 | 16k | 262k | bound by |
|---|---|---|---|---|---|
| 4x VU35P FPGA (reference, from the doc) | 200 MHz | 25 | 10 | 1.05 | compute + link |
| 28 nm, 8x GDDR6 (512 GB/s) | 0.5 GHz | ~36 | ~27 | ~2.6 | memory at short ctx, compute at long |
| 28 nm, 8x GDDR6 (512 GB/s) | 1 GHz | ~36 | ~34 | ~5.3 | memory, compute at 262k |
| 16 nm, 2x HBM3 (1.64 TB/s) | 1 GHz | ~114 | ~53 | ~5.3 | memory at 0, compute after |
| 16 nm, 3x HBM3 (2.46 TB/s) | 1 GHz | ~147 | ~53 | ~5.3 | compute |
| **ideal: TSMC N3 (2023), 6x HBM3 (4.9 TB/s)** | **2 GHz** | **~294** | **~106** | **~10.6** | **compute** |
| ideal at a conservative clock: N3, 4x HBM3 (3.3 TB/s) | 1.5 GHz | ~221 | ~80 | ~7.9 | compute |
| shuttle proof, 4 dies, DDR3-class (~3 GB/s each) | any | ~0.8 | | | memory |
| shuttle proof, 4 dies, PSRAM (~0.5 GB/s each) | any | ~0.14 | | | memory |

- **Long context is compute-bound in every option.** At 262k the token is
  ~190 ms of attention sweep at 1 GHz, so better memory buys nothing there.
  C's per-position cost is the long-context lever, as on the FPGA.
- **Prefill with prompt batching** (not built; scope in
  `docs/2026-09-20_prefill-batching-scope.md`): one weight pass serves many
  prompt tokens, so prefill becomes compute-bound at about **150 tok/s at
  1 GHz** (~74 at 0.5 GHz) on any of the full-chip options, short prompts.

**Power, ESTIMATE, at short-context generation:**

| option | memory interface | logic + SRAM | total | energy per token |
|---|---|---|---|---|
| 4x VU35P FPGA (reference, from the doc) | (included) | (included) | 600-800 W | ~24-32 J |
| 28 nm GDDR6, 1 GHz, ~36 tok/s | 25-40 W | 5-70 W | ~35-110 W | ~1-3 J |
| 16 nm 2x HBM3, 1 GHz, ~114 tok/s | 45-65 W | 15-220 W | ~65-290 W | ~0.6-2.5 J |
| **ideal: N3, 6x HBM3, 2 GHz, ~294 tok/s** | **120-150 W** | **5-190 W** | **~125-340 W** | **~0.4-1.2 J** |
| shuttle proof die, DDR3-class | 1-3 W | 1-5 W | < ~8 W per die | |

How each column was estimated:
- **Memory interface:** bandwidth actually used times energy per bit,
  including PHY and device: GDDR6 ~6-10 pJ/bit, HBM3 ~3.5-5 pJ/bit,
  DDR3-class ~15-25 pJ/bit. Short-context generation keeps the memory nearly
  saturated, so this is close to the interface's full-load power.
- **Logic + SRAM, low end:** the arithmetic alone. 27e9 MACs per token at
  ~0.3-1 pJ each including local SRAM reads is under 1 W at 36 tok/s, times
  ~5-10 for clock tree, control and data movement.
- **Logic + SRAM, high end:** the FPGA's own estimate (~680 W after its HBM,
  ~27 J per token) divided by ~14, the usual FPGA-to-ASIC dynamic power ratio
  for the same logic (Kuon and Rose, 2007).
- The range is wide because this RTL's efficiency as an ASIC is unknown, and
  the high end rests on an FPGA power figure that is itself unmeasured.
- Add a few watts of leakage per ~100 mm² at 28 nm.

**The ideal row (TSMC N3, 2023, with the HBM generation of the same year).**
- **Node:** N3 went into volume in 2023 (N3B, Apple A17 Pro). The memory of
  that year is HBM3 at ~0.82 TB/s per stack. HBM3E (~1.2 TB/s per stack) was
  sampling in 2023 and shipped in 2024; with it, 4 stacks replace 6.
- **Clock:** 2 GHz, the class of a current datacenter accelerator on a
  similar node; 1.5 GHz shown as the conservative case. Same RTL, scaled
  linearly, no ASIC-specific widening.
- **Stacks:** sized so memory is never the limit. At 2 GHz the compute-bound
  token is ~3.4 ms, which needs ~4.2 TB/s, so 6x HBM3 (4.9 TB/s); at 1.5 GHz,
  4 stacks.
- **Result:** ~294 tok/s generation at short context, ~106 at 16k, ~10.6 at
  262k, and ~294 tok/s prefill with prompt batching. About 12x the 4x-FPGA
  setup at short context and 10x at 262k, at roughly a third of its power.
- **Power:** HBM3 at ~3.5-4.5 pJ/bit carrying 4.2 TB/s is 120-150 W. Logic is
  5-190 W: arithmetic at ~0.1-0.3 pJ per MAC on N3 at the low end, the FPGA
  figure scaled by ~14x (FPGA to ASIC) and ~3x (16 nm to N3) at the high end.
- **What sets the die size is the HBM, not the logic.** Four engines are
  only ~15-20 mm² of logic and SRAM on N3, but six HBM3 PHYs need die edge,
  which puts the die in the hundreds of mm². That spare area could hold
  wider lanes or more SRAM.
- **Cost:** N3 masks alone run to tens of millions of dollars, and a CoWoS-
  class interposer with six stacks is the same packaging as a datacenter GPU.
  This is a well-funded-company project, far above the $20-40M of the 16 nm
  option. It is here to show the ceiling of this RTL, not as a plan.
- **Long context is still the attention sweep.** Even here, 262k is
  compute-bound at ~95 ms per token.

**The headline:** a GDDR6 chip at 28 nm would be roughly 1.4x the 4x-FPGA
setup's generation speed at short context, at a tenth or less of its power.
An HBM chip at 16 nm would be about 4.5x, still at a fraction of the power.
Neither helps at 262k until the attention sweep is reworked.

## Cheaper ways to answer the same curiosity

- **A multi-project shuttle as a proof:** one A lane group or B's recurrence
  pipe on Tiny Tapeout, or one whole engine at 28 nm with a modest DRAM
  interface run at a fraction of its bandwidth, to measure the real ASIC
  clock, power and area.
- **Structured ASIC:** Intel eASIC converts RTL at a fraction of full-mask
  NRE, still without HBM.
- **A bigger FPGA:** Alveo U55C (VU47P class, 16 GB HBM) or Versal HBM parts
  (32 GB HBM2e, hardened DDR and PCIe). Same RTL, a licence and a board, no
  masks.

## Open, not answered

- None of the area figures come from synthesis to a standard-cell library;
  a Yosys/OpenROAD run of one lane group on an open PDK (Sky130 or GF180,
  the Tiny Tapeout PDKs) would replace the rule of thumb with a number.
- Shuttle, IP and mask prices are unverified rough figures.

## Corrections

**CORRECTION 2026-10-04: the per-token weight traffic in the original
discussion was about half the real figure.** The 2026-09-24 discussion said
the four engines "would want 7 GB of weights per token in about 3 ms, which is
2.4 TB/s", that "a 28 nm GDDR6 part at 512 GB/s is a 70 tok/s chip", and that
"each die streams 1.8 GB per token". The 27B streams about **14.4 GB per token**
(7.06 + 7.34 GB, the A_JOB rows of
`docs/2026-09-24_jungle-cat-performance-estimate.md`), so **3.6 GB per die**
across four dies, matching that doc's "four hold 3.6 GB of weights" each.
1.8-1.9 GB is the 9B's per-die figure on two cards, which is the likely source
of the slip. Corrected above: ~2.1 TB/s at 1 GHz (three HBM3 stacks rather
than two), and **~36 tok/s, not 70**, for the GDDR6 chip. The "7 GB",
"2.4 TB/s", "70 tok/s" and "1.8 GB" figures are WITHDRAWN. The conclusions do
not change direction: the ASIC is memory-bound without HBM, and the shuttle
die is memory-starved by an order of magnitude.

