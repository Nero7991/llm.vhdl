# What P1 (core clock gating) saves: build 18, Vivado power model plus a silicon read (2026-09-24)

Question (Oren): "spec out P1 clock gating, how much power would that save?"

## Answer

**About 0.47 W per card at the cards' 0.715 V, about 0.9 W for the pair** (ESTIMATE, from a
MEASURED Vivado model). Vivado puts the saving at **0.660 W at 0.85 V**, and dynamic power
scales with V^2: 0.660 x (0.715/0.85)^2 = 0.467 W (DERIVED). That is about 15% of the
modelled non-HBM idle power (4.37 W). It is small against the card, because the idle budget
is dominated by things P1 does not touch: HBM, the PCIe GTYs, the PCIe core clock, and
leakage.

## Procedure

Build 18's routed DCP (`/mnt/storage/fk33_builds/KEEP_build18_dcp/bd_wrapper_routed.dcp`),
`report_power` on the BC-250 (Vivado 2023.2, `MemoryHigh=11G`, cap read back 11811160064).

1. `power.tcl`: the vectorless default (12.5% toggle) as the "active" reference.
2. `power2.tcl`: every non-clock net forced to toggle 0 (`set_switching_activity -toggle_rate 0
   -static_probability 0` on 4,394,773 nets): **idle, all clocks running**. Then `clk_out3`
   re-defined at 300 Hz (period 3,333,337 ns, sentinel `PWR2_CLK3_PERIOD`): **the core gated**.
   The difference between those two is P1.
3. Silicon (`isample.py`, read-only MMIO): SYSMON's VCCINT/VCCHBM/VCCBRAM current-sense aux
   codes at idle and during a 120-token generation (`silicon_isample.txt`).

## Evidence (0.85 V, 38.7 C junction, W)

| component | active (vectorless) | idle, clocks on | idle, core gated | P1 saves |
|---|---|---|---|---|
| Clocks | 0.812 | 0.730 | 0.453 | 0.277 |
| Block RAM | 0.679 | 0.312 | 0.113 | 0.199 |
| DSPs | 0.767 | 0.157 | <0.001 | 0.157 |
| URAM | 0.022 | 0.015 | <0.001 | 0.015 |
| CLB logic + signals | 2.389 | 0.004 | 0.003 | 0.001 |
| HBM (the IP's traffic model) | 17.780 | 17.780 | 17.780 | 0 |
| GTY (PCIe x4) | 1.203 | 1.203 | 1.203 | 0 |
| PCIe hard IP | 0.219 | 0.219 | 0.219 | 0 |
| MMCM | 0.099 | 0.099 | 0.098 | 0 |
| static | 1.674 | 1.618 | 1.608 | 0.010 |
| **total** | 25.661 | **22.154** | **21.494** | **0.660** |
| Vccint (A) | 7.349 | 3.169 | 2.404 | 0.765 |

By clock domain (idle, clocks on): PCIe `CLK_CORECLK` 250 MHz 0.322 W, **`clk_out3` 75 MHz
0.291 W** (331,575 loads, 42,672 sites), `fk33_freeclk` 200 MHz 0.079 W, `CLK_PCLK` 0.018 W.
Gated, `clk_out3` falls to 0.021 W.

Why BRAM and DSP fall with the clock even at zero toggle: their power is per clocked cycle
with the enable held (the design ties many BRAM enables high), so an idle core that is still
clocked keeps reading. Gating the clock is the only way that goes to zero.

## Measured and REJECTED, do not retry

- **`set_switching_activity -default_toggle_rate 0` is not an idle model.** It changed the
  total from 25.770 to 25.834 W (`p_idle_clocks_on.rpt`, not kept): the default applies only
  where no activity is otherwise derived. Set the rate on the nets.
- **`set_operating_conditions -voltage {VCCINT 0.72}` on this routed DCP**, for power: the same
  `[Timing 38-246] vector::_M_range_check` exceptions as the timing re-analysis
  (`power_sentinels.txt`). Scale by V^2 instead.

## What this does NOT establish

- **Watts on the card.** The HBM row is the IP's configured-traffic model, not the idle HBM,
  and nothing here is calibrated against the wall or the UPS. The SYSMON current channels have
  unknown scale AND offset, so the silicon codes rank states but do not give watts.
- **The silicon share.** Pre-registered for P1's acceptance: the model says VCCINT current
  falls 24% (3.169 -> 2.404 A) when gated. On silicon the raw VCCINT_I code must FALL; its
  size is only interpretable once the sense offset is known.
- Leakage at 0.715 V and at card 2's 53 C (the model is at 0.85 V, 38.7 C).
