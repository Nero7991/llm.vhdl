# The rmsnorm_bf max-reduction tree is correct and measures WORSE. Reverted.

**Date:** 2026-08-27. Part `xcvu33p-fsvh2104-2L-e`, 3.3 ns, Vivado 2023.2,
post-**route** (not synthesis). DUT `gdn_emit_chain`, HEADS=24 DIM=128.

## The question

The assembled chain closes 300.75 MHz at synthesis but only 254.3 MHz after
place and route, against subsystem B's 299.04 MHz target. The post-route
critical path was `u_rms/p2_raw_reg[0][9] -> u_rms/max_raw_reg[33]`, which is
`rmsnorm_bf`'s running-max reduction: a linear chain of `LANES` 63-bit
comparisons in one cycle, each fed by a 63-bit negate. That is this project's
own "never two of {wide add, wide compare, mux} in series" rule violated four
times over, and applying that rule took `rmsnorm_rs` from 117.2 to 300.8 MHz.

So: does restructuring it into a registered balanced tree recover the clock?

## The answer

**No. It removes that path and makes the overall result 10.6 MHz worse.**
Reverted. The binding constraint is a different path, `DSP -> mr_m`, and it has
to be fixed first or the two have to be fixed together.

## The evidence

All four points are post-route, same flow, same target:

| config | slack ns | Fmax MHz | critical path |
|---|---|---|---|
| SILU=32 RMS=4, linear chain | -0.726 | 248.4 | `p2_raw -> max_raw` |
| SILU=16 RMS=4, linear chain | -0.632 | **254.3** | `p2_raw -> max_raw` |
| SILU=16 RMS=2, linear chain | -0.538 | 260.6 | `DSP -> mr_m` |
| SILU=16 RMS=4, **registered tree** | -0.803 | **243.7** | `DSP -> mr_m` |

The tree did exactly what it was designed to do: `p2_raw -> max_raw` is gone
from the critical path. But `DSP -> mr_m` then binds at -0.803, against the
-0.538 the same logical path showed in the RMS_LANES=2 build. That spread,
0.265 ns on one logical path, is placement variance, and it swamped the gain.

**The reduction was never the ceiling.** RMS_LANES=2 shortens the chain the
same way the tree does, and it also lands on `DSP -> mr_m`. Two independent
routes to the same second path put the real ceiling somewhere in
244 to 261 MHz regardless of what the reduction looks like.

## What the tree DID establish, and why it is kept

The restructure is not wrong, it is premature. Verified bit-exact against
`ref/rmsnorm_bf_vec.c` at **LANES 1, 2, 4, 8, 16, 32 and 64** (the agent swept
1 to 16; 32 and 64 were run separately), and the full chain passes at HEADS=4
and HEADS=24 in both OVERLAP modes with 0 refused columns. Added latency is
`log2(LANES) + 1` cycles, measured rather than derived, so +3 at RMS_LANES=4,
taking the unit from ~142 to ~145 cycles against a 780-cycle consume budget.

Preserved verbatim at `docs/wip/rmsnorm_bf.tree-restructure.vhd.txt`. Re-apply
it together with the `mr_m` fix and measure both at once.

Structural argument for keeping it eventually, which the measurement does not
refute: one 63-bit register was the sink of a cone fed by all `LANES*64` bits of
`p2_raw` plus its own feedback, and the placer cannot sit it next to every lane
at once. After the split every level has exactly two 63-bit sources. It also
takes a 63-bit negate out of series with a compare, which is two CARRY8 chains
back to back on a dedicated route that placement cannot shorten. That reasoning
still holds; it is simply not what is binding today.

## The path that IS binding

```
  u_rms/ARG__20/DSP_A_B_DATA_INST/CLK  ->  u_rms/mr_m_reg[54]/D
  logic 2.677 ns, net 1.289 ns   (72% LOGIC, unlike the reduction's 67% route)
```

`mr_m` is the shared Newton MREG in `S_RQ`. One 66-bit register is the target of
**four different multiplies** selected by the `rq_step` case (`rq_y*rq_y`,
`rq_smant*rq_y2`, `rq_diff*rq_y`), so there is a wide operand and result mux on
the DSP path. Separately `rq_diff` is `signed(33 downto 0)`, so `rq_diff*rq_y`
is 34x32 and does not fit one DSP48E2 (27x18); it spans a cascade whose partial
product add appears to have landed in fabric.

Two candidate fixes, cheapest first, neither attempted:
1. give each distinct multiply its **own** MREG rather than sharing `mr_m`,
   which takes the mux off the DSP output;
2. narrow `rq_diff` to 32 bits. It is s34 only because `|diff| < 3*2^30`, so a
   biased or pre-shifted form makes it a plain 32x32.

## Measured and REJECTED -- do not retry

- **Restructuring the max reduction alone.** Correct, verified, and a 10.6 MHz
  regression. Do not re-apply without the `mr_m` work.
- **Reading the synthesis critical path as the thing to fix.** Synthesis named
  `DSP -> mr_m` (84.9% logic) and post-route named the reduction (67% route).
  They disagree, and the post-route one is the real one. Every Fmax in the
  master spec was synthesis-only until today.

## Measurement traps hit

- **Fixing the named critical path can lower Fmax**, because the next path may
  place worse once the first is gone. A single before/after pair is the minimum
  honest evidence for a timing change; a synthesis number alone is not evidence.
- **The same logical path moved 0.265 ns between two builds** that differ only
  in an unrelated generic. Treat any post-route delta under ~0.3 ns on this
  design as noise unless it repeats.

## Open, not yet answered

- Whether the tree plus the `mr_m` fix together beat the linear chain plus the
  `mr_m` fix. That is the experiment this file exists to set up.
- Whether 299.04 MHz is reachable at all here, or whether B's target clock
  should be lowered deliberately. At 9B the sweep is 393,216 cycles, which is
  1.51 ms even at 260 MHz, so the target may simply be wrong rather than missed.
- No repeat runs. Every figure above is a single sample.
