#!/usr/bin/env python3
"""Separate the FIXED per-transfer cost of a C2H DMA read from the per-byte cost.

READ ONLY.  Uses dma_read only; never writes HBM.  fk33ctl's own `bench`
writes os.urandom into the offset first, which is fine for a scratch region
and not fine for a card holding 8 GiB of weights.

Why this exists.  A whole token cost 3,583,291 MMIO reads at 1.92 us = 6.885 s,
because there is no bulk result path.  Whether an HBM result path would help
depends entirely on the FIXED cost of a DMA call, since one job's Y is small:
96 rows x 4 B = 384 B.  A path that is fast per byte and expensive per call
loses at that size.  MB-scale throughput numbers cannot answer this.
"""
import sys, time
sys.path.insert(0, "hw/fk33/host")
import fk33ctl as C

# A weights region: read-only here, and known-mapped.
BASE = 0x38204000
SIZES = [64, 128, 256, 384, 512, 1024, 2048, 4096, 8192,
         16384, 65536, 262144, 1 << 20, 4 << 20]

print(f"{'bytes':>9} {'reps':>6} {'total s':>9} {'us/call':>9} {'MB/s':>9}")
for sz in SIZES:
    reps = max(4, min(2000, int(4e6 // sz)))
    C.dma_read(BASE, sz)                      # warm
    t0 = time.perf_counter()
    for _ in range(reps):
        C.dma_read(BASE, sz)
    el = time.perf_counter() - t0
    print(f"{sz:9d} {reps:6d} {el:9.3f} {el/reps*1e6:9.2f} "
          f"{sz*reps/el/1e6:9.1f}")

print()
print("The fixed cost is the us/call figure as bytes -> 0.  If it dominates at")
print("384 B (one 96-row job's Y), a per-job DMA readback cannot beat MMIO and")
print("the win has to come from batching many jobs' results into one transfer.")
