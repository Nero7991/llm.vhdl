# Idle power on the FK33: core clock gating and an RTL VCCINT sequencer

2026-09-24. Status: **P1 PARKED 2026-09-24** (Oren: "Park P1, not worth a build for 0.9 W"): the
model puts it at about 0.47 W per card. P2 open, not started. **The 22 W idle figure below
is NOT a measurement**: 17.78 W of it is the HBM IP's power model at `TRAFFIC_OPTION
{Random}` on all 16 memory controllers, which `set_switching_activity` does not move. Requested by Oren:
"I was wondering if we could lower the static power draw when there's no
inference going", then choosing core clock gating and asking "Can idle VCCINT
drop not be implemented in RTL?" It can, and it is also where "we can
interlock to there in the bitstream once we verify" belongs.

## What is measured today

- The card exposes VCCINT, VCCHBM and VCCBRAM current on SYSMON aux channels
  (DRP 0x15, 0x1c, 0x1d, `hw/fk33/tcl/telemetry.tcl`) with an **uncalibrated**
  scale. Good for idle-vs-load and voltage-vs-voltage ratios, not watts.
- Idle, both cards on build 19 at 0.78 V (2026-09-24 11:10, raw, median of 9):

| card | VCCINT | VCCINT_I | VCCHBM_I | VCCBRAM_I | die |
|---|---|---|---|---|---|
| card 1 | 0.7801 V | 2,687 | 5,831 | 9,948 | 38.2 C |
| card 2 | 0.7793 V | 2,843 | 6,238 | 9,708 | 53.4 C |

- No split of idle power by source exists. Calibrating the channels against a
  wall meter or the UPS is what turns every number below into watts.

## Task P1: gate the core clock when idle

### What it saves (MEASURED model, 2026-09-24)

**About 0.47 W per card at 0.715 V, about 0.9 W for the pair.** Vivado `report_power` on
build 18's routed DCP, idle with every non-clock net at zero toggle, then the same with
`clk_out3` stopped: **22.154 -> 21.494 W, a 0.660 W saving at 0.85 V**, which is
0.660 x (0.715/0.85)^2 = 0.467 W at the cards' voltage (DERIVED; the 0.72 V power run
crashes Vivado 2023.2). Evidence and procedure:
`hw/fk33/results/power_build18_2026-09-24/README.md`.

| saved when the core is gated (0.85 V) | W |
|---|---|
| the 75 MHz clock tree (331,575 loads) | 0.277 |
| block RAM clocked with its enable held high | 0.199 |
| DSP clock pins | 0.157 |
| URAM | 0.015 |
| **total** | **0.660** |

For scale, the modelled non-HBM idle is 4.37 W, so P1 removes about 15% of it. What it
cannot touch: PCIe's 250 MHz core clock (0.322 W), the GTYs (1.203 W), leakage (1.6 W) and
the HBM stacks (the model's 17.78 W is the IP's configured-traffic figure, not idle HBM).
**No figure here is card watts**: nothing is calibrated against the wall, and the SYSMON
current channels have unknown scale and offset. Whether 0.9 W is worth a build is Oren's
call; the design below is small, but it touches the host's path into the card.

### The design

**Buffer.** Put a `BUFGCE` on `clk_out3` (the clock wizard's `CLKOUT3_DRIVES BUFGCE` and its
`clk_out3_ce` pin), and add a second, ungated copy of the same MMCM output on a plain `BUFG`
for a small always-on controller (`clk_aon`, 75 MHz; 9 of 32 global buffers are in use).
BUFGCE is glitch-free; drive CE from a `clk_aon` flop so Vivado times it.

**The seam is on the core clock** (`gen_pcieep.py:2591`), and so are `axil2eng`'s and
`engctl`'s master sides. So a gated core also means **a host that cannot see the card**, and
the controller must open the gate on any host access. It does that on the ungated side:

- **Open** when any AXI-Lite request (`AWVALID` or `ARVALID`) appears on the `xdma/axi_aclk`
  side of a clock converter whose master side is in the core (`axil2eng`, `engctl`, and the
  seam's path). The request waits in the converter until the clock returns: 2 `clk_aon`
  cycles to synchronise plus the BUFGCE's own latency, **about 50-100 ns on the first access
  after idle** (ESTIMATE). GO is a seam write, so GO opens the gate through the same rule;
  nothing special is needed for it.
- **Close** only when a `quiescent` level from the core has been true for `IDLE_TIMEOUT`
  cycles (a register, default 100 ms = 7,500,000 cycles). `quiescent` = D in `S_IDLE`, and zero
  outstanding transactions on every core-side AXI port (A's 27 read masters, B's and C's ports
  through `bc_port_grant`, the descriptor master, the KV write port), and no host request
  pending in any converter. It is synchronised into `clk_aon` with 2 FFs. It freezes at 1 when
  the clock stops, which is the state it was in when the gate closed.
- **Race, by construction:** a host request that arrives in the cycle the gate closes stays
  pending in the converter; the controller sees it on the ungated side and reopens. Nothing is
  lost and nothing needs resetting: a stopped clock holds every flop.
- The seam, XDMA, the HBM controller and the async FIFOs' 250 MHz side stay on their own
  clocks. The HBM side is quiescent by the rule above, so no response can arrive into a
  stopped FIFO.

**Status that does not open the gate.** A gate counter read through the seam would count its
own read. So `gate_events`, `gated_cycles` (in `clk_aon` cycles) and a `gated` bit go on an
aux GPIO on `xdma/axi_aclk`, the pattern `aux_stat` and `aux_clkst` already use, with
`never_gate` and `IDLE_TIMEOUT` as its writable registers.

**What defeats it:** any host poll of a core-side register more often than `IDLE_TIMEOUT`.
The web server does not poll (`/health` does not touch the card); `fk33ctl.py seam` and any
monitoring script do, and must read the aux GPIO instead.

### Acceptance, pre-registered

1. `gated=1` and `gate_events` counting, from the aux GPIO, after 100 ms of idle.
2. **The raw VCCINT_I code FALLS when gated.** The model predicts VCCINT current falls 24%
   (3.169 -> 2.404 A at 0.85 V). The raw code cannot be converted until the sense offset is
   known, so the test is the sign plus the size recorded as found, not a pass on 24%.
3. `fk33_ctxtest.sh pair <out> 500` passes with gating on, and the same test passes
   with `never_gate=1` (the control).
4. First-token latency with gating against `never_gate`: measured, expected under 1 us.
5. A mutant that closes the gate while a read is outstanding must be caught by a bench
   (a stopped core with an HBM response in flight), or the `quiescent` rule is untested.

### Not in P1, recorded

- The engine's `hbm_aclk` loads share PCIe's 250 MHz `CLK_CORECLK` (0.322 W for the whole
  net). A separate gated copy for the engine's side could save part of that. It is
  unmeasured: the net's split between XDMA and the engine has not been drawn.
- PCIe link power states (ASPM L1) against the GTYs' 1.2 W: unverified whether the XDMA
  configuration and the host allow it.

## Task P2: an RTL VCCINT sequencer (and the interlock in the bitstream)

The pot (MCP45xx at I2C 0x2c) hangs off FPGA pins BB24/BA24; the host
bit-bangs it today over MMIO through the GPIO at 0x9000, slowly (the safe
host stepper needs 20 us per edge and ~0.3 s per step, so 1-2 minutes for
0.715 <-> 0.78 V) and unreliably when fast (MEASURED 2026-09-24: one read NACK
and one lost write at full MMIO speed). SYSMON is on-chip. So:

- An I2C master in the always-on domain (100-400 kHz, ~100 us per wiper
  write) with a closed loop on SYSMON: step one wiper at a time, read the pot
  back, read VCCINT, abort on any wrong-direction move, on a per-step change
  above a limit, or on exceeding the ceiling. The same guards as
  `hw/fk33/host/fk33_vccint_test.py`, in hardware. A step-and-settle of ~1 ms
  makes a 0.715 -> 0.78 V move ~50 ms (ESTIMATE; the regulator's settling time
  is unmeasured).
- **The interlock:** the minimum wiper (the maximum voltage) is a constant in
  the bitstream, not a host setting. The GPIO path to the pot is removed or
  arbitrated so no host code can drive the bus behind the sequencer.
- **Two setpoints:** `V_RUN` (today's verified value) and `V_IDLE`. Order
  of operations with P1: on idle, gate the core clock first, THEN lower
  VCCINT; on GO, raise VCCINT, confirm on SYSMON, THEN open the gate. The core
  never runs at `V_IDLE`.
- **`V_IDLE` floor:** the always-on logic (seam, XDMA at 250 MHz, HBM
  controller) is also signed off at 0.85 V and runs below it. `V_IDLE` must
  not go below a value that domain has run at for a long time; 0.715 V has
  weeks of operation, so start there, not lower.
- Power-up: the pot resets to 128 (0.678 V) on every power cycle; the
  sequencer can bring it to `V_RUN` at configuration, which also removes the
  manual raise step.

Dependencies: P2's `V_RUN` needed the voltage question settled first. It is
settled, negatively: build 19's hang persists at 0.85 V (CORRECTION 3,
`docs/debugging/2026-09-24_build19-attention-hang-is-voltage-sensitive.md`), so no
build needs more than the standing 0.715 V and `V_RUN` = wiper 68 until one does.
P1 is independent and can go first.

## Other levers, recorded, not tasks

- Card 2 idles 15 C hotter than card 1 (MCIO riser slot); leakage rises with
  temperature, so airflow there is free.
- Powering off for long idles costs a JTAG reload, the weight load (~15 s
  per card) and the pot reset to 0.678 V.
- HBM self-refresh / power-down: whether the HBM IP exposes it is unverified.
