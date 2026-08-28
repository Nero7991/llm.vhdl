# `RESCALE_ON_LANE` priced, and the skeleton could not synthesise the branch that mattered

**Date:** 2026-08-27. Part `xcvu33p-fsvh2104-2L-e`, 3.333 ns target, OOC
synthesis via `sim/ooc_micro.tcl`, run on the BC-250 (results are bit-identical
to the workstation and were verified so earlier today). Vivado 2023.2.

## 0. The answer

**`RESCALE_ON_LANE = false` halves the per-lane DSP cost, 2 to 1**, and is
cheaper on every other axis too. **But the saving cannot be multiplied by the
lane count**, and the shared rescale unit it implies has never been priced. The
decision is not yet available; the measurement is.

MEASURED, both branches, both voltages, DSP census reconciled against the
utilisation count in every run:

| `RESCALE_ON_LANE` | DSP | census | LUT | FF | CARRY8 | Fmax 0.85 V | Fmax 0.717 V | derate |
|---|---|---|---|---|---|---|---|---|
| **true** (current) | **2** | 2 | 72 | 41 | 5 | 448.4 | **345.9** | 22.86% |
| **false** | **1** | 1 | 45 | 32 | 0 | 646.0 | **507.4** | 21.46% |
| delta per lane | **-1** | | **-27** | -9 | -5 | | +161.5 | |

**The acceptance test passed.** The skeleton's own header sets it: "The true
branch must reproduce the measured 2 DSP; if it does not, the skeleton is wrong
and the false branch's number means nothing." It reproduces 2, and the census
agrees with the utilisation count, so the false branch's 1 is trustworthy as a
per-lane figure.

**Timing does not enter this decision.** Both branches clear the die clock by a
wide margin: A binds at 172.6 MHz post-route at 0.717 V, and the slower of these
two is 345.9 MHz at the same voltage. The `true` branch's extra DSP tile is not
buying frequency that anything needs.

## 1. What the number does NOT license

The skeleton says so itself, and it is worth repeating because the naive
arithmetic is tempting: at `MACS = 128` a per-lane saving of 1 DSP reads as 128
DSP, and 128 DSP is a fifth of the headroom the forced `ROWS_IF = 48` returned.

That figure is wrong for a reason already recorded at the generic: **a rescale
unit may serve at most 2 lanes' files**, so moving the rescale off the lane
means instantiating roughly `MACS/2` shared rescale units plus the mux that
feeds them. Neither is in this skeleton. The net saving is

```
  MACS x 1 DSP  -  (MACS/2) x (cost of one shared rescale unit)  -  mux
```

and the middle term is UNMEASURED. If a shared rescale unit costs 2 DSP the
saving is exactly zero. **Do not quote 128 DSP, or 96, as a saving.**

The LUT column is the more interesting one and points the same way: -27 LUT per
lane is 3,456 LUT at `MACS = 128`, against a mux that costs LUT. The die is at
about 65% LUT, so LUT is not scarce, which weakens the case for the change
rather than strengthening it.

## 2. The defect that made this measurement impossible until today

**The skeleton could only ever synthesise the configuration that was already
known.** Every `RESCALE_ON_LANE = false` run failed:

```
ERROR: [Synth 8-11324] array index 31 out of range
       [rtl/attn_lane_skel.vhd:196]
ERROR: [Synth 8-285] failed synthesizing module 'attn_lane_skel'
```

Line 196 was `resize(unsigned(r_v(31 downto 0)), 32)`. `r_v` is derived from
`p_reg`, whose width follows the A operand: at `true` that is `ACC_W = 36` and
the slice is legal; at `false` it is `Q_W = 16`, `p_reg` is 24 bits, and bit 31
does not exist. **The false branch is the entire reason the generic exists**, so
a pricing skeleton written to answer one question could not run the half of it
that was open. Fixed by `resize(unsigned(r_v), 32)`, which is width-agnostic and
bit-identical wherever the slice was legal, since `resize` on an `unsigned`
drops leftmost bits when narrowing.

## 3. Measured and REJECTED -- do not retry

- **Quoting the per-lane DSP delta as a subsystem saving.** See section 1. The
  shared rescale unit and its mux are unpriced and can consume the whole of it.
- **Justifying `RESCALE_ON_LANE = true` on timing.** Both branches clear the
  binding clock by more than 170 MHz at the real voltage. Whatever the reason to
  keep it, frequency is not it.
- **Reading the derate difference as meaningful.** 22.86% against 21.46% between
  two variants of the same unit. The derate has been measured today from 16.5%
  to 28.0% across unit classes, so a 1.4 point difference here is inside the
  spread and carries no information.

## 4. Measurement traps hit

- **A skeleton that cannot build one of its own branches looks exactly like a
  skeleton that can**, because the branch that works is the one anyone runs
  first as a sanity check. The acceptance test was well designed and it passed;
  it just could not detect that the other half never ran.
- **The failing run still printed pages of plausible Vivado output** before the
  error, including a full DSP report for the previous configuration. Only the
  two `ERROR` lines distinguish it.

## 5. Open

- The shared rescale unit's DSP, LUT and FF cost, and the mux to feed 2 lanes
  from one. Until that exists this decision cannot be made.
- Whether `MACS/2` is the right ratio at `MACS = 128`, or whether the "at most 2
  lanes" bound is itself a function of something that has moved since it was
  written.
- Everything here is OOC synthesis of ONE lane with no array context, no
  broadcast fanout and no accumulator file. C spec 3.13 item 2 already names the
  broadcast of `k`, `v_aligned`, `e` and `f` at 192 lanes as the unmeasured
  Fmax risk, and subsystem A's binding path today turned out to be exactly that
  class of problem. A per-lane number is a floor.
