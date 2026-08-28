# Subsystem A post-route at 0.717 V is 172.6 MHz, not 237.8, and A binds the die clock

## 1. The question

2026-08-27, branch `fpga`. `matvec_core` at `BLK=32 ROWS_IF=58 MAXCOLS=17408
MAXROWS_BFP=17408`, 3.3 ns target, place-and-route on
`xcvu33p-fsvh2104-2LV-e`, VCCINT 0.717 V. Vivado 2023.2. Peak RSS 8.96 GB,
wall time about 1 h 50 m. No hardware.

Every budget in this project rests on A running at **237.812 MHz**, and every
document that compares subsystems compares that figure against B's. The
question, raised earlier today and left open in
`docs/debugging/2026-08-27_voltage-is-a-part-not-a-derate.md` section 7:

> A's 237.812 MHz is a SYNTHESIS figure with no placement. Every B number is
> POST-ROUTE. On this same unit that gap was 15.4% at 0.85 V. **A has NEVER
> been placed and routed at 0.717 V, or at any voltage at `ROWS_IF = 58`.**

So: **what does A actually reach post-route at the voltage the card runs at?**

## 2. The answer

**172.6 MHz. That is 27.4% below its synthesis figure, and 25.7% below B's
post-route 232.16 MHz. A binds the die clock, and it is not close.**

Every token-time figure in the repo that assumes 237.8 MHz is optimistic by
about 38% on A's term, and A is roughly 72% of the token.

The path is route-dominated, which matters for what to do about it:

```
startpoint: ns_r_reg[1]_rep__7/C
endpoint:   em_shv_reg[54][17]/D
slack: -2.495   logic 2.543   net 3.045      (54.5% ROUTE)
```

`_rep__7` on the startpoint means Vivado had already replicated that register
seven times and still could not reach its loads in time.

## 3. The procedure

1. **Notice that two numbers being compared are different KINDS of number.**
   A's 237.8 came from `ooc_core_sweep.tcl`, which synthesises and re-times
   with no placement. B's came from `ooc_micro_pnr.tcl`, which places and
   routes. Nothing in either file's output says which it is; the distinction
   lives in the harness, not the figure.
2. **Quantify the gap on a unit where both are known before assuming it
   transfers.** `gdn_emit_chain` measured 300.75 synthesis and 254.32
   post-route at 0.85 V, a 15.4% loss. That gave an expectation of roughly 200
   MHz for A.
3. **Measure rather than scale**, because today already produced two cases
   where scaling was wrong in opposite directions. The measured loss is 27.4%,
   not 15.4%, so even the informed expectation was 16% optimistic.
4. **Read the critical path, not only the frequency**, to know whether the
   remedy is logic or placement.

## 4. The evidence

```
PNR matvec_core_v0.717_BLK32_ROWS_IF58_MAXCOLS17408_MAXROWS_BFP17408
  DSP=1914 LUT=134874 FF=65811 CARRY8=7138
  WNS=-2.495  Fmax=172.6 MHz  (logic 2.543 / net 3.045 ns)
  Maximum resident set size: 8,960,212 kB
```

Against the synthesis figures for the same configuration, from
`sim/ooc_sweep/results.csv`:

| | Fmax | WNS | source |
|---|---|---|---|
| synthesis, 0.85 V | 284.90 | -0.210 | `results.csv:9` |
| synthesis, 0.717 V | 237.812 | -0.905 | `results.csv:7` |
| **post-route, 0.717 V** | **172.60** | **-2.495** | this run |

DSP and LUT match the synthesis run (1,914 and ~134.7k), so this is the same
design, not a different configuration.

For comparison, B's emit chain on the same day, same voltage, same harness:
**232.16 MHz post-route**. A is 25.7% below it.

## 5. Measured and REJECTED -- do not retry

- **Comparing A's synthesis figure to B's post-route figure.** This is what the
  budget documents do throughout, and it flatters A by 27.4%. Any table that
  ranks subsystems must state which kind of number each cell is, or it is not a
  ranking.
- **Assuming the synthesis-to-route loss measured on one unit transfers to
  another.** 15.4% on `gdn_emit_chain`, 27.4% here. Same direction, nearly
  double the magnitude. This is the same shape as the VCCINT derate finding
  earlier today, which measured 16.5% to 28.0% across unit classes: **neither
  ratio is a property of the die.**
- **Attacking this path as a logic-depth problem.** It is 54.5% route with the
  startpoint already replicated seven times by the tool. The remedies that
  worked on B's logic-bound paths -- MREG/PREG pairs, cascade hops -- do not
  apply to a path whose delay is mostly wire.

## 6. Measurement traps hit

- **The harness does not label its own output.** `ooc_core_sweep.tcl` prints an
  Fmax and so does `ooc_micro_pnr.tcl`; only one has been placed. Both write
  into documents as "Fmax". Every figure in this project should carry its
  flow, and most do not.
- **`ROWS_IF = 58` is not buildable anyway.** It needs 32.62 HBM ports of 30
  available (`NPORT = ROWS_IF x 9/16`). This measurement is still worth having
  because it is the only post-route A figure in existence and it settles the
  synthesis-versus-route question, but the number that matters for the design
  is `ROWS_IF = 48`, which is queued.
- **A long Vivado run is not a hung one.** This took about 1 h 50 m at 8.96 GB.
  Vivado's router works hardest exactly when it cannot close, so the runs that
  take longest are the ones reporting the worst news.

## 7. Open, not yet answered

- **`ROWS_IF = 48` post-route at 0.717 V.** Queued. 48 has 330 fewer DSP and
  27 rather than 33 HBM lanes, so it is a materially smaller and less congested
  design; whether that buys clock back is unknown and is the single most
  important open number in the project.
- **Every token-time and tok/s figure in the repo is now optimistic**,
  including today's own `die-allocation-at-rows-if-48.md`, which uses 236.128
  MHz for A. At 172.6 MHz, A's term inflates by 37.8%. Nothing has been
  re-derived yet, deliberately, because the 48 measurement will land first and
  re-deriving twice is waste.
- Whether the 54.5% route share is intrinsic to a 1,914-DSP array on this die
  or an artefact of an OOC run with no floorplan. An OOC block has no pblock,
  no I/O placement and no context, so its routing is not the routing it would
  get in a real design. That cuts both ways and is not evidence in either
  direction on its own.
