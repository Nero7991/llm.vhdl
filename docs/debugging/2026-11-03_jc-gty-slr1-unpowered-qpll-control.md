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
