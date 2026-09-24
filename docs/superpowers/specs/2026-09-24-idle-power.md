# Idle power on the FK33: core clock gating and an RTL VCCINT sequencer

2026-09-24. Status: **tasks P1 and P2 open, not started.** Requested by Oren:
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

The 75 MHz core domain (`clk_out3`, A/B/C/D, the regions) keeps its clock
trees and any free-running logic toggling between tokens. Put a `BUFGCE` on
it, owned by a small always-on controller in the seam's domain:

- **Open** on GO (and on any host access that needs the core, such as the
  window or region reads), before D leaves `S_IDLE`.
- **Close** after `tok_done` plus an idle timeout (a register, default e.g.
  100 ms), and only when D is in `S_IDLE`, no AXI transaction is outstanding
  on any core-domain port (HBM ports, grant, seam), and the host has not held
  a core access open.
- The seam, XDMA, the clock wizard, SYSMON and the HBM controller stay on
  their own clocks; nothing that answers the host is gated.
- A status bit and a counter of gate events in the seam, so a test can prove
  it gates, and a "never gate" register for debugging.

Risks to design for: a host access into a gated domain must not hang the
AXI-Lite bus (open the gate and stall the access, or refuse it); clock
enable must be glitch-free (BUFGCE is); CDC of the open request.

Acceptance: VCCINT_I measurably lower when gated (ratio from the aux
channel); the 500-token context test (`fk33_ctxtest.sh pair <out> 500`) passes
with gating on; first-token latency penalty measured (expected: one gate
open, microseconds).

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

Dependencies: P2's `V_RUN` needs the voltage question settled first (build
19's attention hang is voltage-sensitive, 2026-09-24,
`docs/debugging/2026-09-24_build19-attention-hang-is-voltage-sensitive.md`).
P1 is independent and can go first.

## Other levers, recorded, not tasks

- Card 2 idles 15 C hotter than card 1 (MCIO riser slot); leakage rises with
  temperature, so airflow there is free.
- Powering off for long idles costs a JTAG reload, the weight load (~15 s
  per card) and the pot reset to 0.678 V.
- HBM self-refresh / power-down: whether the HBM IP exposes it is unverified.
