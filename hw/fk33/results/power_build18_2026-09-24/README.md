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

## Why the modelled idle is 22 W, and why that is not the card's idle (added same day)

17.780 of the 22.154 W is the HBM instance: **8.305 W in the FPGA die** (controllers,
switch, PHY, HBM clocks) and **9.474 W in the two stacks** (report section 3.3.11). It is
computed from the IP's configuration, `CONFIG.USER_MC0..15_TRAFFIC_OPTION {Random}`
(`hw/fk33/build_fk33_pcieep.tcl:409`), i.e. sustained random traffic on all 16 channels.
It did not move when every net was forced to zero toggle, so the model never saw the design
being idle. The rest, 4.37 W, is the fabric: leakage 1.61, GTY 1.20, clocks 0.73, BRAM 0.31,
PCIe 0.22, DSP 0.16, MMCM 0.10.

The silicon codes disagree with a flat 17.78 W: raw VCCHBM_I is 5,839/6,219 at idle and
reaches 11,719/13,334 during generation (`silicon_isample.txt`), so the HBM rail's draw does
move with traffic. Its idle watts are unknown until the channel is calibrated.

The card has NO calibrated telemetry: its I2C bus holds three JC42.4 temperature sensors
and three MCP45xx pots, no PMBus regulator
(`docs/debugging/2026-08-24_fk33-sysmon-vccint-undervolt.md`, Bus map). The UPS reports
apparent power for the whole box in ~12 VA steps.

## A guessed calibration of the SYSMON current channels (ESTIMATE, added same day)

Oren: "Can you not guess the current channels?" Assumption, stated so it can be falsified:
**code 65,536 (1 V on the aux input) = the rail's rated current, and zero offset.** Ratings
from the board's community documentation: VCCINT 120 A, HBM_VCC 20 A, VCCINT_IO 20 A.

**The channel labelled `VCCBRAM_I` is taken to be VCCINT_IO + VCCBRAM.** The model puts
VCCBRAM alone at 0.03-0.08 A, and this channel reads the largest code of the three. On
HBM-equipped UltraScale+ parts VCCBRAM is tied to VCCINT_IO, and VCCINT_IO is the third
documented rail. SYSMON's own VCCBRAM reads 0.759 / 0.754 V (MEASURED), so that rail runs
below its 0.85 V nominal too. HBM_VCC is taken at its nominal 1.2 V (not measured).

| rail | card 1 idle | card 2 idle | card 1 / 2 generation MAX |
|---|---|---|---|
| VCCINT | 4.20 A x 0.717 V = **3.01 W** | 4.51 A x 0.713 V = **3.22 W** | 7.39 / 8.63 A |
| VCCINT_IO + VCCBRAM | 3.04 A x 0.759 V = **2.31 W** | 2.96 A x 0.754 V = **2.23 W** | 4.96 / 4.85 A |
| HBM_VCC | 1.78 A x 1.2 V = **2.14 W** | 1.90 A x 1.2 V = **2.28 W** | 3.58 / 4.07 A |
| **sensed total** | **7.45 W** | **7.73 W** | |

Rails with no sense channel, from the model: VCCAUX 0.79 W, the GTY rails 1.1 W, VCCAUX_HBM
0.29 W, and VCC_IO_HBM, which is 5.4 W in the model at Random traffic; scaled by HBM_VCC's
guessed-over-modelled ratio (1.78 / 4.84) it is about 2.0 W. That puts the rails at
**about 12 W per card at idle**, and with an 85-90% regulator efficiency **about 13-14 W per
card at the 12 V input, about 27 W for the pair.** All ESTIMATE, and the calibration
assumption alone could move it by +/-50%.

Consistency checks, none of them a calibration:
- HBM_VCC's generation peak (3.6-4.1 A) sits just under the model's full-Random-traffic
  4.84 A, which is where a heavily streaming token should be.
- VCCINT's idle guess (4.2 A) is 1.7x the model's idle at 0.715 V (2.1 A dynamic + ~0.45 A
  leakage, DERIVED by V scaling). Either full scale is nearer 75 A than 120 A, or the real
  idle has activity and leakage (ES1 die, card 2 at 53 C) the zero-toggle model lacks.
- Card 2 reads 7.5% more VCCINT current than card 1 at the same voltage, and runs 14 C
  hotter: the right sign for leakage.

Cheapest falsifier of the zero-offset part, no hardware: step VCCINT 0.715 -> 0.80 V at idle.
Dynamic current alone scales with V (+12%) and leakage adds more, so the code must rise at
least 12%. A much smaller rise means a large offset.
