# What is the composed design's real baseline, and do directives help it?

Date: 2026-09-05, evening. Part `xcvu33p-fsvh2104-2L-e`. Written because the
audit earlier the same day found that the baseline every composed run was told
to compare against does not exist.

## The question

`sim/ooc_compose4_pnr.tcl` instructed every directive run to compare against
`impl_pb` = **-0.402** (2026-09-04, all four directives empty). No `impl_pb`
artifact survives, so its netlist cannot be identified, and the tree changed the
following day. `c4nd`'s -0.422 had been called a directive **loss** on that
basis.

> What is the composed design's routed WNS with all four directives empty on the
> **current** tree, and do directives help or hurt?

## The answer, up front

**Baseline -0.637 (177.4 MHz). Directives HELP by 0.215 ns. The recorded
"directives lose" verdict is REFUTED.**

Three runs, all routes clean. The first two share a netlist fingerprint
(`bram=253.5 dsp=2177`); the third is the `KV_BLOCK=4` variant.

| run | KV | directives | routed WNS | fmax | fingerprint |
|---|---|---|---|---|---|
| **`c4base`** | 32 | **all four empty** | **-0.637** | **177.4 MHz** | `bram=253.5 dsp=2177 lut=263184` |
| **`c4nd`** | 32 | `''`/`ExtraNetDelay_high`/`AggressiveExplore`/`NoTimingRelaxation` | **-0.422** | **184.4 MHz** | `bram=253.5 dsp=2177 lut=263544` |
| `c4kv4c` | **4** | *(same as `c4nd`)* | -1.731 | 148.6 MHz | `bram=253.5 dsp=1953` |

```
c4base   C4_ROUTE_STATUS nets=3532979 errors=0 unrouted=0 partial=0
c4nd     C4_ROUTE_STATUS nets=3535996 errors=0 unrouted=0 partial=0
c4kv4c   C4_ROUTE_STATUS nets=3264841 errors=0 unrouted=0 partial=0
```

Two controlled one-variable results now stand on the same netlist:

- **directives: +0.215 ns** (`c4base` -> `c4nd`, KV held at 32)
- **`KV_BLOCK` 32 -> 4: -1.309 ns** (`c4nd` -> `c4kv4c`, directives held)

**The best reproducible composed figure is -0.422 (184.4 MHz), and the distance
to 200 MHz is 0.422 ns.**

## Directives are also what moves the congestion. `KV_BLOCK` is not.

Maximum routed congestion level per direction:

| run | South | East | North | West |
|---|---|---|---|---|
| `c4base` (no directives) | **L6** | L6 | **L6** | *(none reported)* |
| `c4nd` (directives) | **L5** | L6 | **L5** | L5 |
| `c4kv4c` (directives, KV=4) | L5 | L6 | L5 | L5 |

**`ExtraNetDelay_high` placement drops South and North from Level 6 to Level 5.
Cutting `u_arr`'s DSPs 8x drops nothing at all.**

This is the first positive evidence about the congestion since the DSP-density
hypothesis was refuted. It does not identify a *cause*, but it does locate the
lever: **the congestion here responds to how the design is placed, not to how
much arithmetic is in the block that sits inside the congested windows.** Any
further work aimed at shrinking `c_attn` to relieve congestion is aimed at the
wrong variable, and that is now measured twice rather than argued.

## The withdrawn -0.402 is now quantitatively suspicious

`impl_pb` claimed **-0.402 with all directives empty**. The current tree with
all directives empty measures **-0.637**. So the vanished baseline was
**0.235 ns better** than anything reproducible today under the same conditions.

Two possibilities and **this experiment cannot separate them**:

1. The composed design **regressed ~0.235 ns** between 2026-09-04 and
   2026-09-05, or
2. `impl_pb` was a **different netlist** and the comparison was never valid.

Its artifacts are gone, so neither can be checked. **If (1) is true, the design
lost 0.235 ns in a day and nothing detected it** -- which is the more expensive
possibility and the reason this is recorded rather than shrugged off. The
`C4_TIMING` fingerprint added today makes this specific ambiguity impossible in
future: a WNS now carries the netlist it belongs to.

## Measured and REJECTED, do not retry

- **"Directives lose on this design."** Refuted. They are worth **+0.215 ns** in
  a controlled pair on one netlist. The original verdict compared -0.422 against
  an unrecoverable -0.402.
- **Do not use -0.402 as the baseline.** Use **-0.637**, measured today on the
  current tree with a recorded fingerprint.
- **Do not attack congestion by shrinking `c_attn`.** An 8x DSP cut in the block
  owning 65-95% of the congested windows moved congestion by zero levels;
  changing the placer directive moved two directions by a full level.

## Measurement traps hit

1. **The fix landed in time to prove itself.** `c4base` is the first run to emit
   the new `C4_TIMING ... bram=253.5 dsp=2177 lut=263184 dirs='||||'` line, and
   confirming it shares `c4nd`'s netlist took **one grep** instead of the
   cross-referencing that had previously failed four times. The two older runs
   still print the short form, so this document had to look their fingerprints
   up separately -- which is exactly the friction the change removes.
2. **`c4base` reports no West congestion row at all**, while the other two
   report `West=L5`. An absent row is not a zero and is not a Level 5; it means
   nothing crossed the reporting threshold in that direction, or the table shape
   differs. Do not fill it in with a guess. It does not affect the South/North
   L6 -> L5 finding, which is present in both tables.
3. **LUT differs slightly between `c4base` and `c4nd`** (263,184 against
   263,544) on what is provably the same netlist. That is the placer packing
   differently under a different directive and is exactly why **LUT and CLB
   cannot be used to test netlist identity**, while BRAM and DSP can.

## Open, not yet answered

- **Whether the design regressed 0.235 ns on 2026-09-04/05.** Unanswerable from
  surviving artifacts. Only a rebuild of that day's tree would settle it.
- **What causes the Level 5/6 congestion.** Placement responds to it; the cause
  is still unidentified. DSP density is eliminated.
- **Whether other directive combinations beat -0.422.** Only two points exist on
  the current tree, and per the recorded LEVERC48 result two points do not give
  the shape of anything.
- **The 0.422 ns to 200 MHz.** Nothing here closes it.
