# Measuring FK33 card power with the bench supply (procedure, not yet run)

2026-09-24. Oren: "Instead of buying, I could just power it with my lab supply right?", then
"Write it but I'll come back to it". Status: **written, not run.** Run it after build 20
has landed and had its silicon test, because rewiring needs the PC off.

## Why

The card has no calibrated power telemetry. Its SYSMON current channels (VCCINT_I 0x15,
VCCHBM_I 0x1c, and 0x1d, labelled VCCBRAM_I but most likely VCCINT_IO + VCCBRAM) have unknown
scale. The zero-offset part of the guessed calibration survived a voltage step on card 1; the
SCALE did not resolve: VCCINT full scale is 60-70 A or 120 A, a 2x ambiguity
(`hw/fk33/results/power_build18_2026-09-24/README.md`). A calibrated current on the 12 V input
settles it, because the ambiguity (2x) is far larger than the regulator efficiency's
uncertainty (~0.85-0.92).

## Equipment

- Kiprim DC310S, 0-30 V / 0-10 A, USB serial (`~/GitHub/DevOps/docs/notes/bench-instruments.md`).
- A PCIe 6-pin pigtail: **pins 1-3 +12 V, pins 4-6 ground/sense.** Short, heavy leads (16 AWG
  or better); twist the pair.
- The card: **card 1** (serial 153300000607A, bus 07:00.0), in the main slot. Card 2 is on
  an MCIO riser whose power path is undocumented.

## Wiring and sequencing

1. Wait for: build 20 landed, its silicon test run, nothing on either card that matters.
2. Stop `server/llmvhdl_server.py`. Shut the PC down.
3. **Unplug the PC PSU's 6-pin from card 1 entirely. Never parallel two supplies onto one input.**
4. Supply set, output OFF: **12.00 V, current limit 5.0 A** (60 W; idle is expected near 1 A
   and generation a few amps). Connect the pigtail.
5. Grounding: the supply's negative becomes tied to PC ground through the slot. A floating
   output is fine; an earth-bonded negative is fine too (same earth as the PC).
6. **Supply output ON first, then boot the PC.** At the end: shut the PC down first, then
   the supply off. Never remove or cut the 6-pin while the host runs: a card dropping off
   the bus can hang the host.

## Recovery after the power cycle (main session; opens `/dev/xdma*`)

A power cycle loses the bitstream, the HBM contents and the VCCINT setting (the pot returns
to wiper 128, 0.678 V).

1. `FK33_CARD=153300000607A hw/fk33/host/fk33_reload.sh hw/fk33/bit/fk33_card_build18_elwin_75mhz_2026-09-23.bit`
   (or build 20's bitstream if it has replaced 18), then find its node:
   `readlink -f /sys/class/xdma/xdma*_user/device` must show `0000:07:00.0`.
2. Bring VCCINT to wiper 68 with the standard stepper, `fk33ctl.py vccint` (it steps up in
   voltage from 128 and stops at 68 by design).
3. Load its half and verify: `fk33_load_weights.py load <image>/manifest.json --verify`, as in
   `/mnt/storage/fk33_builds/card_build19/vtest/back_to_b18.sh`.
4. Card 2 stays on the PC PSU but is power-cycled with the PC, so it needs the same
   recovery (serial 153300001366A, 06:00.0, the `b16-31` image). Then restart the server.

## The measurement

`hw/fk33/host/fk33_powerlog.py` logs the supply's `MEASure:VOLTage?` / `MEASure:CURRent?`
beside the three SYSMON current codes, VCCINT and VCCBRAM. Read-only on both ends; it refuses
any serial port whose `*IDN?` is not the DC310S. From a directory under
`/mnt/storage/fk33_builds/power_labsupply/`:

```bash
export FK33_USER=/dev/xdmaN_user                       # card 1's node
P=/home/orencollaco/GitHub/llama.vhdl/hw/fk33/host
python3 $P/fk33_powerlog.py idle_0715 30
python3 $P/fk33_vccint_test.py raise 0.752; python3 $P/fk33_powerlog.py idle_0750 30
python3 $P/fk33_vccint_test.py raise 0.802; python3 $P/fk33_powerlog.py idle_0800 30
python3 $P/fk33_vccint_test.py restore;     python3 $P/fk33_powerlog.py idle_0715b 30
# then a generation through the server, logging during it:
python3 $P/fk33_powerlog.py gen 30
```

There is no known zero-current state to baseline against (the card cannot be held powered
but drawing nothing), which is why the calibration below uses DIFFERENCES.

## The arithmetic (to be applied, not yet)

- VCCINT scale, from the voltage step, with the other two channels as the control (they did
  not move in the 2026-09-24 step):
  `k_VCCINT [A per code] = eta * dP_12V / (V1*c1 - V0*c0)`, eta = 0.85-0.92 (ESTIMATE).
  120 A full scale is k = 0.00183 A/code; 65 A is 0.00099.
- Absolute 6-pin power at idle and during generation: read directly.
- HBM and VCCINT_IO channels: from generation minus idle, after subtracting VCCINT's
  now-calibrated share. Two unknowns from one difference is underdetermined; report them as
  a bound unless a second state separates them.

## What this will NOT establish

- **Slot power.** The slot can supply 12 V and 3.3 V, and the supply sees only the 6-pin. The
  card stays dark without the 6-pin (2026-08-24 notes), which suggests the main regulators hang
  off it, but the split is unmeasured. Report 6-pin watts as a LOWER bound on the card.
- Card 2 (different slot, riser, 14 C hotter).
