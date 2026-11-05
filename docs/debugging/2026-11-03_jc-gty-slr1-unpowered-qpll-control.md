# Jungle Cat: QPLL positive control never locked because SLR1's GTY quads are unpowered

## The question (2026-11-03)

Hardware: SQRL Jungle Cat carrier, both VU35P modules (xcvu35p-fsvh2104), loaded over the
BC-250 sqrl_bridge (CoE, XVC on 2542). One clock site populated by Oren (SiT9501 156.25 MHz
LVDS -> LMK1D1204 -> 0402 AC caps); the scope reads ~156 MHz at the cap outputs.

Symptom: the QPLL census (`hw/jc/census/jc_qpll_census.vhd`, build b2) showed no QPLL lock on
any of the 16 quads on either die. The positive control (build b3: MMCM 200*25/4/8 = 156.25 MHz
into GTGREFCLK0, QPLL0REFCLKSEL "111", quad 131 = GTYE4_COMMON_X0Y7) also never locked
(`ctl_qpll0_lock=0` in 8/8 samples per die, including after a VIO reset pulse), while
`mmcm_locked=1` and the control clock counted exactly 0.78125 x BC26. Why?

## The answer

Bank 131 is in SLR1, and SLR1's GTY analog supplies are off on these modules: MGTAVCC reads 0 V
on banks 128, 131 and 231, and MGTVCCAUX reads 0 V on banks 131 and 228. SLR0's quads (124-127,
224-227) are powered (AVCC 0.92-0.93 V, AVTT 1.23-1.24 V, MGTVCCAUX 1.80 V), and the same control
moved to bank 126 (SLR0) locks on both dies (8/8 samples each). The QPLL design is correct.

## Procedure

1. Reviewed the GTYE4_COMMON tie-offs against the GT Wizard 10GBASE-R preset (bandgap pins,
   LOCKEN, PD, SDM, REFCLKSEL, FBDIV 66 / REFCLK_DIV 1). Nothing wrong found; review alone
   could not separate design from power.
2. SYSMON rail probe v1 (`hw/jc/census/jc_sysmon_probe.vhd`, one SYSMONE4 per SLR, VUSER0-3 on
   GTY rails, read by VIO). VCCINT/VCCAUX/VCCBRAM channels are the control: the bridge measures
   them independently over JTAG.
3. Probe v2: SLR1 VUSERs moved to the south quadrant (b68 VCCAUX, b128 AVCC, b129 AVTT,
   b228 MGTVCCAUX) to check the slave VUSER path returns non-zero values.
4. QPLL census b4: control quad made a generic, set to bank 126 (SLR0), MMCM at MMCM_X0Y1.
   Everything else as b3. This is the one-variable test of "design vs. power".

## Evidence (MEASURED, VIO over XVC; raw in ~/regress_scratch/jc_sysmon/ and ~/regress_scratch/jc_qpll/)

Bridge (independent control), both dies, both SLRs: VCCINT 0.847-0.853, VCCAUX 1.790-1.802,
VCCBRAM 0.853-0.858.

Probe v1, 3 reads per die (volts = code/65536*3):

| SLR | channel | die 0 | die 1 |
|---|---|---|---|
| 0 | VCCINT | 0.853-0.855 | 0.850 |
| 0 | b126 AVCC | 0.926-0.928 | 0.924 |
| 0 | b126 AVTT | 1.243 | 1.232 |
| 0 | b226 AVCC | 0.926-0.928 | 0.924 |
| 0 | b226 MGTVCCAUX | 1.798-1.800 | 1.803 |
| 1 | VCCINT | 0.853-0.855 | 0.850 |
| 1 | b131 AVCC | 0.000-0.002 | 0.000 |
| 1 | b131 MGTVCCAUX | 0.001-0.002 | 0.002 |
| 1 | b231 AVCC | 0.000-0.001 | 0.000 |
| 1 | b231 AVTT | 0.000 | 0.000 |

Probe v2, SLR1:

| channel | die 0 | die 1 |
|---|---|---|
| b68 VCCAUX (intended control) | 1.279-1.281 | 1.259-1.261 |
| b128 AVCC | 0.000-0.002 | 0.000 |
| b129 AVTT | 1.280-1.282 | 1.259-1.261 |
| b228 MGTVCCAUX | 0.005-0.008 | 0.005-0.006 |

QPLL census b4 (control on 126), 8 samples per die:

```
xcvu35p_0 126 lock0=1 (8/8)   CTL mmcm_locked=1 ctl_qpll0_lock=1, clean ratio 0.78125
xcvu35p_1 126 lock0=1 (8/8)   CTL mmcm_locked=1 ctl_qpll0_lock=1, clean ratio 0.78125
all other quads, both dies: lock0=0 lock1=0
```

## Measured and REJECTED (do not retry)

- "QPLL attribute/reset/GTGREFCLK misconfiguration": the identical design locks on bank 126.
- "No lock on the board refclks means no clock reaches the FPGA" (2026-11-03 morning): withdrawn
  at the time because the control failed; now partly restored for SLR0 only (see open items).
- IBERT IP batch configuration for quads >= 8: fails in Vivado 2023.2 batch (`C_MGT_COORDINATE_Q0
  ... key "" not known`). Use the custom census instead.

## Measurement traps hit

- The refclk edge counters are not evidence of a clock. Control quad 126's REFCLK0 pin (AD38),
  which nothing drives in b4's design use, counted 14.9M-21.4M on die 0 and 0 on die 1. Undriven
  IBUFDS_GTE4 inputs in powered quads produce counts. In unpowered quads they read 0.
- The counter is not torn-read safe: clean-looking samples can be partial windows (ratio 0.34,
  0.19, 0.016 in the same run that reads 0.78125 exactly). Gate on equal sequence before/after.
- REFCLKLOST=0 is not evidence of a clock either: in unpowered SLR1 quads every LOST bit reads 0.
- v2's "control" b68 VCCAUX read 1.26-1.28 V, not the 1.8 V of VCCAUX, and tracks b129 AVTT to a
  few codes. Either the HP-bank VCCAUX VUSER is not what the name suggests or one channel aliases
  the other. The slave path is shown live (non-zero, varying codes), but the 1.27 V values are not
  confirmed as either rail.
- The bank-131 control was placed without checking which SLR had GT power; one cross-SLR check
  of the rails first would have saved a build.

## Open, not yet answered

- Is SLR1's GT power absent by design (depopulated regulators on the module) or switched off
  (enable from the module's power sequencer)? Oren reports no candidate parts on the carrier; the
  module side is under thermal pads.
- Which MGTREFCLK pins the populated clock site drives. In SLR0, die 0 bank 227 REFCLK0 (AB9)
  shows lost0=0 in 8/8 samples with counts 4.5M-17.6M and no lock; die 1 bank 127 REFCLK0 (AB38)
  shows lost0=0 with a stuck count. Neither locks.
- Whether the bank-129 AVTT 1.27 V reading is real (AVTT present without AVCC).

## ADDENDUM 2026-11-04: first board refclk lock (site 2, bank 126, die 0)

**Answer:** with clock site 2 populated, the board clock reaches bank 126 (die 0: AD38 and AC36;
die 1: AC36 only) at 156.2487 MHz (ratio to BC26 0.781243-0.781244, steady to 1 ppm, no extra
edges). It did not hold a QPLL lock until Oren replaced the LMK1D1204's VDD bypass cap (it
looked discoloured); after the swap the pin-fed QPLL locks 8/8 with no drops.

Procedure and evidence (MEASURED, VIO over XVC, raw in ~/regress_scratch/jc_qpll/):

| build | quad 126 QPLL0 | quad 126 QPLL1 | die 0 result |
|---|---|---|---|
| b2 (site 2 fitted) | AD38 pin, GTREFCLK00 sel 001 | AC36 pin, GTREFCLK11 sel 010 | no lock 8/8 |
| b5 | AD38 ODIV2 -> BUFG_GT -> GTGREFCLK0 sel 111 | AD38 pin, GTREFCLK01 sel 001 | QPLL0 never; QPLL1 drop=1 before reset (locked once, lost), no lock 8/8 |
| b6 | AD38 -> MMCM (BANDWIDTH LOW) -> GTGREFCLK0 | as b5 | QPLL0 locked 8/8, rise=0; QPLL1 no lock 8/8 |
| b6 after bypass-cap swap | as b6 | as b5 | QPLL0 and QPLL1 locked 8/8, rise=0, drop=0, before and after reset |

The b5/b6 pair isolates jitter: the same clock locks only after the low-bandwidth MMCM, on the
same GTGREFCLK path that the clean MMCM control locked on. The cap swap is the one board change
between the last two rows.

Traps: the lock-high fraction (in41-45) shares the torn-read problem of the edge counters; frac
0.15-0.62 rows coincide with torn samples and are not lock loss (rise=0 in the same rows).

Open: die 1 (AC36) not yet tested on a pin-fed QPLL; site 1's outputs still not located; the
fabric (GTGREFCLK) path's margin for a real link is unknown and should not be relied on.

### CORRECTION 2026-11-04 (later the same day): the cap swap did not cure it

The addendum's "after the swap the pin-fed QPLL locks 8/8" was true for one read and is
WITHDRAWN as a fix. About an hour later, with no board change reported:

- b7 (both QPLLs pin-fed: AD38 on GTREFCLK00, AC36 on GTREFCLK01, sel 001): die 0 lock0=0
  lock1=0 8/8; drop0=1 drop1=1 before the reset pulse (each locked once after configuration,
  then lost lock); no re-lock after the pulse. Counts still 13.50-13.52M, lost0=lost1=0.
- b6 reloaded as the control, same session: QPLL0 (via MMCM) locked 8/8; QPLL1 (AD38 pin) lock1=0
  8/8 with drop1=1 before the pulse, the pre-swap pattern.

So the same bitstream that locked 8/8 now fails: the variable is the board clock, which is
marginal (locks some of the time, holds only through the low-bandwidth MMCM). Still open: what
on site 2 makes the jitter marginal (joint, cap value or count, layout, temperature).

### CORRECTION 2026-11-04 13:50: the oscillator rework also did not hold

After Oren added oscillator decoupling and resoldered its GND pad, b7 at 13:27 locked both
die-0 QPLLs (AD38, AC36) and die 1's AC36 QPLL 8/8 with no drops. A read-only soak (no reset
pulse, drop flags sticky from the 13:27 pulse) at 13:28, 13:34, 13:39, 13:45 showed every one
of those QPLLs unlocked with drop=1 and rise=0 in every window: lock was lost within about a
minute and never re-acquired. At 13:50, with a reset pulse: die 0's AD38/AC36 counts are erratic
(1.1M-58M per window, the undriven-pin signature; they were 13.51M at 13:27), die 1's AC36 still
counts 13.41M but its QPLL does not re-lock after the pulse.

So the site-2 clock degrades within minutes of a rework: consistent with an intermittent joint
or a part that fails as it warms. Not yet separated. Any single "locked 8/8" read after a board
change is not evidence of a fix; gate on a soak of at least 15 min with sticky drop flags.

### 2026-11-04 15:05: die 0 holds lock for 15 min after the LMK VCC contact fix; die 1 does not lock

Oren found the LMK1D1204 VCC contact suspect and reworked it. b7 loaded at 14:47, reset pulsed
on read 1, then 28 reads with no pulse to 15:03 (drop flags sticky):
- die 0: QPLL0 (AD38) and QPLL1 (AC36) lock=1 in every sample, drop0=drop1=0 at the end. First
  pin-fed lock that held through a soak. Counts 13.42-13.60M with a few torn samples.
- die 1: AC36 counts a steady 13.38-13.43M (ratio to its own BC26 ~0.7812), but its QPLL1 locked
  once before the pulse (drop1=1 on read 1), then lock=0 in every sample after it.
The cold start at 14:15, before this fix, had erratic counts on every pin: the earlier failures
were the VCC contact, not heat. Die 1's own path (its cap pair, trace, connector) is now the open
item.

### 2026-11-04 15:50: first die-to-die IBERT run, and the clock fails again when the dies are warm

- 15:21-15:37, b7 soak after Oren's die-1 path rework: 116/116 samples locked on every clocked
  pin of both dies (die 0 AD38+AC36, die 1 AC36), drop=0. Die temps at load 36.6 / 39.1 C.
- 15:38 IBERT A (`/mnt/storage/fk33_builds/jc_ibert/A/out/jc_ibert_a.bit`, quads 124-127, 16 lanes,
  10.3125 Gb/s, QPLL0 refclk AC36 for every quad via GTREFCLK1 / GTSOUTH / GTNORTH) loaded on both.
  `run_link.tcl map` (raw: ~/regress_scratch/jc_ibert/map_2026-11-04.txt): die 1 lanes of quads
  124-125 ran (3.9e11 bits each); lanes 1,2,5,7 had 0 errors (RX_BER < 2.6e-12), lanes 0,3,4,6
  ~0.5; die 0 and die 1 quads 126-127 never left reset. 0/31 RXPRBSLOCKED. Not yet interpretable
  as a die-to-die result: die 0's TX was in reset during that window.
- IBERT QPLL0 DRP values equal the census b7 values (CFG0 331C, CFG1 D038, CFG2 0FC0, CFG3 0120,
  CFG4 0002, CP 0FF, LPF 23F, LOCK_CFG 25E8, FBDIV 0x40 = 66). After a QPLL+GT reset pulse only
  die 0 COMMON_X0Y3 held lock in 10 samples over 10 s.
- 15:49 b7 reloaded as the control: no lock on either die, die 1 AC36 erratic (1.6-16.8M), die 0
  drop1=1. Die temps at load 50.0 / 58.0 C (after ~25 min of all-GT IBERT).
So the clock that held 15 min at ~37 C failed at ~50-58 C. Correlation, one point: the cold start
earlier (14:15) failed while cold, but that was before the LMK VCC fix. Thermal dependence of
the site-2 joints or parts is now the leading hypothesis, not yet separated.

### 2026-11-04 ~17:00: die 0 near-end PMA loopback, 16 lanes error-free at 10.3125 Gb/s

Die 1's AC36 refclk stopped (16:30-16:39, after ~40 min on the light b7 image: counts 0.4-4.1M,
undriven signature, no lock); die 0 relocked 6/10 reads. So the die-to-die test was not possible
and a die-0-only loopback was run instead (`/mnt/storage/fk33_builds/jc_ibert/loopback.tcl`,
`lb_run.sh`): IBERT A loaded on both dies (temps at load 43.1 / 51.5 C), QPLL0 reset pulse, one
TX+RX link per GT with LOOPBACK "Near-End PMA", PRBS31 both ways, GT TX/RX reset, error counters
reset, 30 s, read (raw: ~/regress_scratch/jc_ibert/lb_die0.txt):

```
LB_PLL COMMON_X0Y0/QPLL0 LOCK=1   X0Y1 LOCK=1   X0Y2 LOCK=0   X0Y3 LOCK=1   (read at the end)
lanes MGT_X0Y0..X0Y15: ERR=0 on all 16, BITS 3.46e11..3.84e11 each (5.9e12 total), BER < 2.9e-12 each
```

So the GTY TX and RX paths, the QPLL settings and the IBERT flow work on die 0 at 10.3125 Gb/s.
Near-end PMA loopback does not exercise the package pins, the carrier or the other die. Quad 126's
QPLL0 read LOCK=0 at the end although its four lanes logged no errors: either the lock dropped
after the counters were read, or the lock read is stale; not separated. Trap hit: the script's
`kill; sleep 3` left the IBERT bridge holding port 2542, so the b7 reload failed and IBERT kept
heating the dies for ~5 min; the scripts now wait for the port to free.
