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
