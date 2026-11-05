# Jungle Cat: searching for the slot-to-slot GTY link (2026-11-04)

## The question

Do the carrier's 16 slot-to-slot differential pairs connect the two VU35P modules on GTY quads
124-127 (the only quads with GT power, see 2026-11-03_jc-gty-slr1-unpowered-qpll-control.md)?

## Answer so far (NOT final)

At 10.3125 Gb/s with IBERT default TX swing and RX equalization: no PRBS31 reception on any of
the 32 RX, and the eye is closed (0/0) on three of four die-to-die RX scanned. Not yet separated:
not connected, versus connected but too lossy at 10 Gb/s, versus AC-coupling caps unpopulated.

## Procedure and evidence (MEASURED, raw in ~/regress_scratch/jc_ibert/)

1. IBERT G (MMCM 156.25 MHz on GTGREFCLK0, all four COMMONs, both dies): all 8 QPLL0 locked.
   `run_link.tcl ber 30` (g1_ber.txt): 32/32 RXCDRLOCK=1, 0/32 RXPRBSLOCKED, BER 0.48-0.54
   except die 0 MGT_X0Y0 0.950. With RXPOLARITY=1 on all RX (pol_scan.txt): die 0 MGT_X0Y0 0.050,
   others 0.45-0.52.
2. TX scan (txscan.txt): each of 32 TX switched PRBS31 -> PRBS7 in turn; die 0 MGT_X0Y0 BER stayed
   0.0500 in every case. Its stream is not from any IBERT TX.
3. 2D eye scans, DWELL_BER 1e-5, increments 8 (eyescan.txt, eyes/*.csv):

| RX | horiz | vert | open area | open % |
|---|---|---|---|---|
| die 1 MGT_X0Y4, near-end PMA loopback (control) | 49 | 137 | 6720 | 37 |
| die 0 MGT_X0Y0, no loopback | 65 | 121 | 8768 | 49 |
| die 0 MGT_X0Y8, no loopback | 0 | 0 | 0 | 0 |
| die 1 MGT_X0Y0, no loopback | 0 | 0 | 0 | 0 |
| die 1 MGT_X0Y8, no loopback | 0 | 0 | 0 | 0 |

## Measurement traps

- RXCDRLOCK=1 on every lane including ones with no correlated data: not evidence of a link.
- An open eye is not evidence of a link either: a static or slowly toggling input also scans open
  (the offset sample always agrees with the centre sample). Die 0 MGT_X0Y0 is open with a fixed
  BER no TX changes: DERIVED reading, a non-IBERT, mostly static input. Not confirmed.

## Open

- Low-rate IBERT (1.25 Gb/s, then the IP's floor, about 0.5 Gb/s) building.
- Whether the slot-to-slot pairs have unpopulated AC-coupling caps.
- Where the pairs land if not on 124-127 (SLR1 quads are unpowered; no refclk on the 2xx column).

## 2026-11-04: Oren reports unpopulated cap pads on the slot-to-slot pairs

Oren (visual, not measured): many unpopulated pads, probably 0201, along the slot-to-slot pairs.
If these are the series AC-coupling caps, every pair is open, which fits all measurements above
(no PRBS on any RX; closed eyes; die 0 MGT_X0Y0's open eye with a fixed BER read as a floating,
mostly static input). A lower line rate would not change an open pair. Plan: fit 100 nF 0201
X5R/X7R on 2-4 pairs, then IBERT G125 and G (10.3125) lane map and BER.

## 2026-11-04 evening: FIRST DIE-TO-DIE LINK after fitting AC caps on two pairs

Oren confirmed the unpopulated pads are the lane AC caps (32 pads, 0201) and fitted 100 nF X7R
0402 on two pairs (4 caps). IBERT G125 (1.25 Gb/s) and G (10.3125 Gb/s), both on the MMCM
GTGREFCLK refclk, PRBS31 on all 32 TX, loopback None (raw ~/regress_scratch/jc_ibert/g125_*,
g103_*):

| RX | 1.25 Gb/s, pol 0 | 1.25, pol 1 | 10.3125, pol 0 | 10.3125, pol 1 |
|---|---|---|---|---|
| die 1 MGT_X0Y0 | 8.0e-12 (0 errors, 1.25e11 bits) | 0.8875 | 1.7e-8 (1.01e12 bits, ~1.7e4 errors) | 0.8875 |
| die 1 MGT_X0Y4 | 0.465 (0.245 in a later run) | 0.887 | 0.0061 | 0.879 |

TX scan at 1.25 Gb/s against die 1 MGT_X0Y0 (g125ts_txscan.txt): baseline 0.0000; only die 0
Quad_124/MGT_X0Y0/TX switched to PRBS7 raised it (0.5039); every other TX 0.0000; final 0.0000.
So **die 0 lane 0 TX -> die 1 lane 0 RX** is a working link (MEASURED). The TX scan against die 1
MGT_X0Y4 was inconclusive (0.244-0.249 throughout, 0.2605 only when die 0 MGT_X0Y5 switched):
DERIVED reading, the second fitted pair lands on die 1 lane 4 with a marginal connection (one
cap joint?), source TX not confirmed. RXPRBSLOCKED reads 0 even on the error-free lane: the BER
is the evidence, not that flag. Die 0 MGT_X0Y0's fixed 0.0500/0.9500 is unchanged by any TX and
remains an artifact; die 0 MGT_X0Y14 and die 1 MGT_X0Y14 show the same fixed values.

Trap: the BITS counts are ~10x rate x the nominal window because counting runs from the error
reset to the slow XVC read, not for the 10 s alone. BER ratios are unaffected.

Open: 10.3125 Gb/s BER 1.7e-8 on lane 0 with default TX swing/emphasis and RX equalization, and
a jittery MMCM refclk: not tuned. Lane 4's joint. The remaining 14 pairs.
