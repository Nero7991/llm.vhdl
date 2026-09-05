# B's mover fits at last, and its -4.008 is 31 logic levels, not routing

**2026-09-05.** `sim/ooc_gdnadapt_extract.py` at commit `f2bbd50`, OOC
synthesis, `xcvu33p-fsvh2104-2L-e`, 5.000 ns constraint, Vivado 2023.2.

## The question

> B's data mover is the project's headline blocker at `-4.008 ns` (111 MHz
> against a 200 MHz target). That figure was taken at `e9beec9` against an
> extraction that went stale three hours later and then would not build at
> all. Does it still hold, does the block fit, and what actually limits it?

## The answers, up front

1. **`-4.008` REPRODUCES EXACTLY**, five commits and 225 body lines later.
2. **The mover FITS** once the state tier is enabled: BRAM **5,472 tiles
   (814% of the device) -> 50 (7.44%)**, via a generic, not a text hack.
3. **The critical path is LOGIC DEPTH, not routing: 31 levels, 77.7% logic.**
   No implementation directive can fix it, and the arithmetic says so.
4. **It is invariant to the memory architecture** -- bit-identical `-4.008` in
   all three configurations -- but failing endpoints collapse **110,298 -> 858**,
   so it is now nearly isolated instead of pervasive.

## The matrix

`GDNADAPT_MAXROWS` at the sizes the original figure was taken at, crossed with
the generic that `5f1db1a` introduced:

| | 64, flat | **64, state tier** | 256, flat |
|---|---|---|---|
| CLB LUTs | 127,260 | **65,044** | 129,224 |
| LUT as Logic | 91,883 | 52,931 | 93,751 |
| LUT as Memory | 35,377 | 12,113 | 35,473 |
| CLB Registers | 46,279 | 37,997 | 49,317 |
| CARRY8 | 2,074 | 2,125 | 2,074 |
| **Block RAM tile** | **5,472 (814%)** | **50 (7.44%)** | **5,472 (814%)** |
| URAM | 0 | **32** | 0 |
| DSP | 191 | 194 | 191 |
| **WNS** | **-4.008** | **-4.008** | **-4.008** |
| TNS | -16,291.768 | **-2,627.843** | -16,291.755 |
| failing endpoints | 110,298 | **858** | 110,298 |
| total endpoints | 688,996 | 198,064 | 693,024 |

Against the 2026-09-03 record (`MAXROWS` 64: 127,260 / 91,883 / 46,279 / 5,472
/ -4.008; 256: 129,224 / 93,751 / 49,317 / 5,472 / -4.008) every figure agrees.

**The URAM row confirms the project's existing rule from the other side.**
`CLAUDE.md` records that URAM cannot hold an initialised table, so a ROM
request is refused and silently served from BRAM. Here the state store is
written at RUN TIME, and it takes 32 URAM without complaint. URAM is available
to a store, not to a constant.

## The critical path

```
Slack (VIOLATED):  -4.008ns
Source:       a0/DSP_A_B_DATA_INST/CLK
Destination:  gb_real.u_gdn/u_conv/p1_reg[3][3]/DSP_A_B_DATA_INST/A[24]
Data Path Delay: 8.674ns  (logic 6.739ns = 77.692%,  route 1.935ns = 22.308%)
Logic Levels: 31  (CARRY8=4 DSP_A_B_DATA=2 DSP_ALU=5 DSP_M_DATA=3
                   DSP_MULTIPLIER=3 DSP_OUTPUT=5 DSP_PREADD_DATA=3
                   LUT1=1 LUT2=2 LUT5=2 LUT6=1)
```

Five DSP tiles chained COMBINATIONALLY through `PCOUT`, inside `gdn_conv`:

```
0.585  1.507 f  a0/DSP_ALU_INST/ALU_OUT[47]
0.122  1.629 r  a0/DSP_OUTPUT_INST/PCOUT[47]
0.546  2.189 r  a/DSP_ALU_INST/ALU_OUT[7]
...
0.505  3.303 f  ARG__17/DSP_MULTIPLIER_INST/U[28]
0.585  3.935 f  ARG__17/DSP_ALU_INST/ALU_OUT[47]
0.122  4.057 r  ARG__17/DSP_OUTPUT_INST/PCOUT[47]
0.546  4.617 r  ARG__18/DSP_ALU_INST/ALU_OUT[2]
0.037  5.026 r  gb_real.u_gdn/u_conv/ARG__16_i_22/O          (LUT1)
0.170  5.228 r  gb_real.u_gdn/u_conv/ARG__16_i_18/CO[7]      (CARRY8)
0.505  6.504 f  ARG__16/DSP_MULTIPLIER_INST/U[18]
```

## Why this matters more than the number

**77.7% of the delay is LOGIC.** Every timing lever this project has pulled --
`Performance_NetDelay_high`, `ExtraTimingOpt`, `AggressiveExplore`,
`NoTimingRelaxation`, the post-route phys_opt chain -- moves ROUTING. Routing
is 1.935 ns of an 8.674 ns path. **Even driving route delay to zero leaves
6.739 ns against a 5.000 ns period, i.e. WNS -1.739 and still failing.**

That is a closed-form refutation, not an estimate: no directive, no seed, no
strategy and no placement can close this gap. It has to be pipelined.

`gdn_conv` IS pipelined at the RTL level -- `xf/wf` -> `p1` (multiply) -> `p2`
(shift) -> `accr` (sum), four stages, `rtl/gdn_conv.vhd:280-325`. The cascade
above is Vivado chaining the adder tree at :320-324 (`sum := sum + resize(...)`)
into DSP ALUs through PCOUT, together with the exponent/shift arithmetic at
:263-270, and arriving at `p1`'s A input. The stages exist; the work BETWEEN
two of them is five DSPs deep.

## Measured and REJECTED -- do not retry

- **Implementation directives on this block.** Refuted by arithmetic above, not
  by trial. Route is 22% of the path.
- **Blaming the 5,472-tile array for the timing.** The BRAM count changes by a
  factor of 109 between columns and WNS does not move one picosecond.
- **`--state-store` to get the fitting configuration.** Superseded; it emits
  unbalanced generates and now refuses. Use `-generic B_STATE_AXI=true`.
- **Running the extraction without `GDNADAPT_MAXROWS`.** Vivado dies with
  SIGNAL 11, not an error: `[Synth 8-3391] ... number of bits (196608) is too
  large`. Measured again today by forgetting it, twice.

## Measurement traps hit

- **A waiter's status is not the job's.** Two waiters were killed by the
  harness; both times the job was fine and finished. Gated on
  `BMOVER2_DONE`, a sentinel the work writes, and on `rc`.
- **`memory.peak` of a capped job is the cap.** The cgroup read
  `memory.current = memory.peak = memory.high = 13.00 GB` exactly. That says
  the throttle works, not what the job wants.
- **I explained the reproduction with a mechanism I had not checked.** I wrote
  that the 225 lines of drift "were almost entirely the inactive state tier".
  MEASURED: of 172 added CODE lines, **49%** are state-tier or tap; the rest
  are real logic from three other commits (a `min4` function, a `gb_start`
  signal). **Why those cost exactly zero LUT, zero FF and zero picoseconds is
  NOT established.** The tidy explanation was wrong and the invariance is more
  surprising than it made it sound.

## Open, not yet answered

- **Which expression to pipeline.** The path crosses the adder tree and the
  exponent/shift arithmetic; attributing the 31 levels to specific source
  lines needs an object-level census, not inference from one report.
- **What the fix costs.** Adding a stage changes `gdn_conv`'s latency, and
  every consumer of its handshake has to tolerate that. Not free.
- **Whether 858 failing endpoints are one path or many.**
  `report_timing_summary` printed one. `-max_paths` would say.
- **Subsystem C's 151.3 MHz** has had no equivalent analysis. Its extractor is
  in sync (measured, body drift 0) so the measurement is available cheaply.
