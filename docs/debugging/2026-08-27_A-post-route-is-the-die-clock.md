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

---

## UPDATE, same day: the buildable configuration, and the first fix measured

Three more place-and-route runs at 0.717 V on `-2LV`, same 3.3 ns target:

| config | commit | DSP | LUT | Fmax | WNS | logic | net | binding path |
|---|---|---|---|---|---|---|---|---|
| `ROWS_IF=58` | pre-fix | 1,914 | 134,874 | 172.6 | -2.495 | 2.543 | 3.045 | `ns_r_reg[1]_rep__7/C -> em_shv_reg[54][17]/D` |
| `ROWS_IF=48` | pre-fix | 1,584 | 112,989 | **179.7** | -2.265 | 2.487 | 3.032 | same shape |
| `ROWS_IF=48` | **post-fix** | 1,584 | 115,766 | **187.2** | -2.041 | 2.212 | **2.775** | `cb_reg[4][6]_replica_1/C -> tr_reg[0][1220]/DSP_OUTPUT_INST/ALU_OUT[10]` |

**Two findings, and the first one is the more important.**

**1. Dropping from 58 to 48 bought almost nothing: +7.1 MHz for 330 fewer DSP
and 22,000 fewer LUT.** The critical path barely moved (logic 2.543 to 2.487,
net 3.045 to 3.032) and kept its identity. **So A's clock problem was never die
congestion.** A 17% smaller design on the same die runs 4% faster. That is the
signature of a structural path, not a crowded one, and it is what licensed
attacking the broadcast rather than the floorplan.

**2. The `ns` fix is worth about the same as removing a fifth of the design:
+7.5 MHz.** Narrowing `ns_r` from a full `integer` to `natural range 0 to 63`
and giving each of the 48 emit lanes its own registered copy took logic 2.487
to 2.212 and net 3.032 to 2.775. Both terms improved, which is what a fix that
removes width AND shortens the haul should do.

**And the path moved, to the same defect shape one level up.** The new binding
path starts at `cb_reg[4][6]_replica_1/C` -- `replica_1` again, so Vivado is
again replicating a broadcast source on its own initiative. `cb` is the
**16-entry runtime-loadable codebook** (`matvec_core.vhd:120`), and every lane
reads it: `tr(0)(rr*BLK + j) <= resize(cb(idx) * xw, 28)` at `:478`. At
`ROWS_IF = 48, BLK = 32` that is **1,536 consumers of one 16-entry table**.

So the same shape has now bound the clock three times in one day, in three
different units: `si_e_seg` into `gdn_silu`'s 16 lanes, `ns_r` into
`matvec_core`'s 48 emit lanes, and now `cb` into 1,536 multiply lanes. The
common form is a small shared value read by a wide array, and the tool signals
it every time by replicating the source and still missing.

Still 55.6% route, so this remains a placement and fanout problem rather than a
logic-depth one.

---

## UPDATE 2, 2026-08-28: the codebook replication measured, and where A now stands

| step | commit | DSP | LUT | Fmax | WNS | logic | net |
|---|---|---|---|---|---|---|---|
| `ROWS_IF=58`, pre-fix | -- | 1,914 | 134,874 | 172.6 | -2.495 | 2.543 | 3.045 |
| `ROWS_IF=48`, pre-fix | -- | 1,584 | 112,989 | 179.7 | -2.265 | 2.487 | 3.032 |
| + `ns` narrowed and replicated | `0666c90`/`d2b4a6a` | 1,584 | 115,766 | 187.2 | -2.041 | 2.212 | 2.775 |
| **+ codebook per row** | `fe0d3c8` | 1,584 | 121,162 | **208.8** | -1.490 | **1.313** | 3.170 |
| codebook per 2 rows | `fe0d3c8` | 1,584 | 117,154 | 198.1 | -1.749 | 1.426 | 3.097 |

**+21.0% overall, 172.6 to 208.8 MHz, and the codebook replication alone is
worth +21.6 MHz** -- three times what dropping a fifth of the design bought.

**Per row wins, and per two rows is 10.7 MHz worse**, which settles the
granularity question the generic was left open for. The defence given for per-row
(the `BLK` lanes of a row already share an adder tree, so the placer keeps a row
together for reasons unrelated to `cb`) is consistent with the measurement: the
boundary that respects existing structure is the one that pays.

**The logic term collapsed, 2.212 to 1.313 ns**, which is the 16:1 codebook mux
leaving the path. Net rose 2.775 to 3.170, so the path is now **70.7% route** and
the binding constraint has fully migrated from logic depth into wire. That is
worth stating because it means the next fix is not another narrowing.

For comparison, `ROWS_IF = 32` measured on the BC-250 at the `ns`-fix commit:
**201.5 MHz**, DSP 1,056, LUT 77,557. So before the codebook fix a 33% smaller
design was 14 MHz faster; after it, the full-size `ROWS_IF = 48` is 7 MHz faster
than the smaller one was. The fallback configuration lost its remaining
justification.

### Subsystem B, the same night

Post-route at 0.717 V, after the `p2_raw` MREG and the `mr_m2` cascade hop:

| `SILU_LANES` | DSP | LUT | FF | Fmax | logic | net |
|---|---|---|---|---|---|---|
| 8 | 57 | 22,008 | 14,956 | 231.9 | 3.605 | 0.538 |
| 16 | 73 | 29,876 | 16,154 | 233.9 | 3.605 | 0.538 |

**This is the post-route confirmation that was recorded as owed.** The synthesis
equality across 8/16/32 lanes survives routing: 2.0 MHz apart, with an identical
critical path in both. So `SILU_LANES = 8` costs 2 MHz and returns 16 DSP and
7,868 LUT, and the decision taken on synthesis evidence holds.

**A still binds, but the gap has closed from 59.6 MHz to 25.1** (208.8 against
233.9). Every token-time figure in the repo still needs re-deriving, and now
against 208.8 rather than the 172.6 this document first reported.
