#!/usr/bin/env python3
"""TRACK LUTDIET projection.  Reads the measured LUTDIET result CSVs and prints
the composition arithmetic.  EVERY number it prints that is not read from a CSV
is DERIVED and the arithmetic is shown; the two extrapolated rows are labelled
ESTIMATE and carry their assumption inline."""
import csv, glob, os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
r = {}
for f in glob.glob(os.path.join(OUT, "result_*.csv")):
    tag = os.path.basename(f)[len("result_"):-len(".csv")]
    with open(f) as fh:
        row = list(csv.DictReader(fh))[-1]
    r[tag] = {k: row[k] for k in row}

def i(tag, col):
    return float(r[tag][col])

print("== MEASURED, from result_*.csv ==")
hdr = ("tag", "top", "generics", "LUT", "FF", "BRAM", "URAM", "DSP", "F7", "F8", "WNS")
print("%-12s %-18s %-16s %9s %8s %6s %5s %5s %7s %6s %8s" % hdr)
for tag in sorted(r):
    d = r[tag]
    print("%-12s %-18s %-16s %9s %8s %6s %5s %5s %7s %6s %8s" % (
        tag, d["target"], d["gen"].strip('"'), d["lut"], d["ff"], d["bram_tile"],
        d["uram"], d["dsp"], d["f7"], d["f8"], d["wns_ns"]))

# ---- baselines, from hw/fk33/results/build_e2e_2026-08-29/*.rpt --------------
DEV = dict(lut=439680, ff=879360, bram=672, uram=320, dsp=2880)
USED = dict(lut=171458, ff=125006, bram=261.5, uram=0, dsp=1585)      # e2e_util_routed.rpt
PB = dict(lut=388800, ff=777600, bram=576, uram=320, dsp=2700)        # e2e_pblock_util_routed.rpt
PBUSED = dict(lut=155035, ff=98586, bram=225, uram=0, dsp=1585)
FREE = {k: DEV[k] - USED[k] for k in DEV}
PBFREE = {k: PB[k] - PBUSED[k] for k in PB}
print("\n== DERIVED, what the routed A build leaves free ==")
print("device : LUT %d  FF %d  BRAM %.1f  URAM %d  DSP %d" % (
    FREE["lut"], FREE["ff"], FREE["bram"], FREE["uram"], FREE["dsp"]))
print("pb_core: LUT %d  FF %d  BRAM %.1f  URAM %d  DSP %d" % (
    PBFREE["lut"], PBFREE["ff"], PBFREE["bram"], PBFREE["uram"], PBFREE["dsp"]))

# ---- COMPOSE's measured composition, unchanged -------------------------------
B, C, Dseq = 438340, 157200, 6614
Dnorm = int(i("rms_n4096", "lut")) if "rms_n4096" in r else 169746
tot = B + C + Dseq + Dnorm
print("\n== COMPOSE's composition, with D's norm row re-measured here ==")
print("B %d + C %d + D_seq %d + D_norm %d = %d LUT" % (B, C, Dseq, Dnorm, tot))
print("against %d free on device = %.2fx ; against %d free in pb_core = %.2fx" % (
    FREE["lut"], tot / FREE["lut"], PBFREE["lut"], tot / PBFREE["lut"]))
print("must lose %d LUT to fit the device, %d to fit pb_core" % (
    tot - FREE["lut"], tot - PBFREE["lut"]))

# ---------------------------------------------------------------------------
# The per-element cost of a flat whole-vector port, from the N sweep.
# MEASURED inputs, DERIVED ratios.
# ---------------------------------------------------------------------------
print("\n== DERIVED, cost per vector element of rmsnorm_rs's flat ports ==")
print("%-10s %6s %9s %8s %10s %8s" % ("tag", "N", "LUT", "FF", "LUT/elem", "FF/elem"))
for tag, N in (("rms_n256", 256), ("rms_n1024", 1024), ("rms_n4096", 4096)):
    if tag not in r: continue
    print("%-10s %6d %9d %8d %10.1f %8.1f" % (
        tag, N, i(tag, "lut"), i(tag, "ff"), i(tag, "lut") / N, i(tag, "ff") / N))

# ---------------------------------------------------------------------------
# The memory-backed trade, measured on the one real case.
# ---------------------------------------------------------------------------
if "mem_n4096" in r and "flat_n4096" in r:
    print("\n== MEASURED, the same-contract pair at N=4096 ==")
    for tag, what in (("flat_n4096", "flat vectors + rmsnorm_rs"),
                      ("mem_n4096",  "banked BRAM + rmsnorm_rs_mem")):
        print("%-12s %-30s LUT %8d  FF %7d  BRAM %5s  DSP %3d  WNS %s" % (
            tag, what, i(tag, "lut"), i(tag, "ff"), r[tag]["bram_tile"],
            int(i(tag, "dsp")), r[tag]["wns_ns"]))
    dl = i("flat_n4096", "lut") - i("mem_n4096", "lut")
    print("DERIVED: -%d LUT (%.1f%%), -%d FF, +%s BRAM tiles" % (
        dl, 100.0 * dl / i("flat_n4096", "lut"),
        i("flat_n4096", "ff") - i("mem_n4096", "ff"),
        float(r["mem_n4096"]["bram_tile"]) - float(r["flat_n4096"]["bram_tile"])))

if "hotw_n4096" in r and "rms_n4096" in r:
    print("\n== MEASURED, the no-memory no-interface-change variant ==")
    dl = i("rms_n4096", "lut") - i("hotw_n4096", "lut")
    print("rmsnorm_rs      %8d LUT" % i("rms_n4096", "lut"))
    print("rmsnorm_rs_hotw %8d LUT   -> -%d LUT (%.1f%%), BRAM %s, same ports" % (
        i("hotw_n4096", "lut"), dl, 100.0 * dl / i("rms_n4096", "lut"),
        r["hotw_n4096"]["bram_tile"]))

# ---------------------------------------------------------------------------
# THE PROJECTION.  This is an ESTIMATE and every assumption is named.
#
# Assumption 1 (MEASURED, one case): converting a flat whole-vector port to
#   banked block RAM removes 98.4% of its LUT cost -- 299,030 -> 4,798 at the
#   same interface, N=4096, LANES=4.  `r` below is that recovery fraction and it
#   is swept rather than assumed.
# Assumption 2 (MEASURED, census): the share of each subsystem's LUT that is
#   flat-vector storage plus variable-index access to it.  B and C shares are
#   read off census_gdn_none.txt and census_attn_none.txt by summing the roots
#   that name a flat staging vector or a read off one.
# Assumption 3 (NOT measured): that B's and C's buffers convert as cleanly as
#   D's did.  They may not.  gdn_block's qbuf/kbuf are read DIM=128 WORDS IN ONE
#   CYCLE and attn_block's qplane is read by the whole MAC array, so both need
#   the transform applied one level down as well.  This is the weakest link in
#   the chain and it is why `r` is swept instead of fixed.
# ---------------------------------------------------------------------------
B_LUT, C_LUT = 438328, 157560            # MEASURED here, -flatten_hierarchy none
B_SHARE, C_SHARE = 0.887, 0.576          # MEASURED, census root sums
D_AFTER = 6614 + 4798                    # MEASURED: seq_* unchanged + rmsnorm_rs_mem
print("\n== ESTIMATE: B+C+D after a flat-port-to-memory conversion ==")
print("assumption: r = fraction of the flat-storage LUT cost removed."
      "  MEASURED on the one converted case: r = 0.984")
print("%5s %10s %10s %10s %10s   %-24s %-24s" % (
    "r", "B", "C", "D", "total", "vs 268,222 free (device)", "vs 233,765 free (pb_core)"))
for rr in (0.5, 0.6, 0.7, 0.8, 0.9, 0.984):
    b = B_LUT * (1 - B_SHARE * rr)
    c = C_LUT * (1 - C_SHARE * rr)
    t = b + c + D_AFTER
    print("%5.3f %10d %10d %10d %10d   %-24s %-24s" % (
        rr, b, c, D_AFTER, t,
        ("FITS, %d spare" % (FREE["lut"] - t)) if t <= FREE["lut"] else ("%.2fx over" % (t / FREE["lut"])),
        ("FITS, %d spare" % (PBFREE["lut"] - t)) if t <= PBFREE["lut"] else ("%.2fx over" % (t / PBFREE["lut"]))))

# break-even r, DERIVED
for name, budget in (("device", FREE["lut"]), ("pb_core", PBFREE["lut"])):
    num = B_LUT + C_LUT + D_AFTER - budget
    den = B_LUT * B_SHARE + C_LUT * C_SHARE
    print("DERIVED break-even for %-7s: r >= %.3f   ((%d + %d + %d - %d) / (%d*%.3f + %d*%.3f))" % (
        name, num / den, B_LUT, C_LUT, D_AFTER, budget, B_LUT, B_SHARE, C_LUT, C_SHARE))

# ---------------------------------------------------------------------------
# THE TWO LEVERS, projected separately.  ESTIMATE.
#
# Lever 1, "hotw": decode the flat register's write with a per-word generate and
#   a constant index.  MEASURED on rmsnorm_rs at N=4096: the write-decode root
#   went 162,276 -> 1,052 LUT primitives, 99.4% removed, and the unit went
#   169,746 -> 40,804 CLB LUT (-76.0%) at IDENTICAL ports, IDENTICAL FF,
#   IDENTICAL WNS (+1.675) and ZERO BRAM.
# Lever 2, "mem": banked block RAM.  MEASURED at the same interface,
#   299,030 -> 4,798 CLB LUT (-98.4%) for +6 BRAM tiles.
#
# Assumption for both: B's and C's write-demux and read-mux roots respond as
# rmsnorm_rs's did.  NOT MEASURED on B or C.  The write-demux side is the more
# credible of the two because it is the same RTL idiom in all three modules
# (a slice assignment with a runtime base); the read side is less credible
# because B's and C's reads are WIDE (128 words, or a whole MAC-array plane)
# where rmsnorm_rs's is LANES words.
# ---------------------------------------------------------------------------
BW, BR = 0.798, 0.089                    # MEASURED shares, census_gdn_none.txt
CW, CR = 0.541, 0.035                    # MEASURED shares, census_attn_none.txt
HOTW_EFF = 0.994                         # MEASURED on rmsnorm_rs's write decode
print("\n== ESTIMATE: the two levers on B+C+D ==")
rows = [
    ("today, MEASURED",            B_LUT,                                C_LUT,                                6614 + 169746),
    ("lever 1 only (hotw)",        B_LUT * (1 - BW * HOTW_EFF),          C_LUT * (1 - CW * HOTW_EFF),          6614 + 40804),
    ("lever 1 + 2 (memory)",       B_LUT * (1 - (BW + BR) * 0.984),      C_LUT * (1 - (CW + CR) * 0.984),      6614 + 4798),
]
print("%-22s %9s %9s %9s %10s  %-22s %-22s" % (
    "", "B", "C", "D", "total", "device (268,222)", "pb_core (233,765)"))
for name, b, c, d in rows:
    t = b + c + d
    print("%-22s %9d %9d %9d %10d  %-22s %-22s" % (
        name, b, c, d, t,
        ("FITS +%d" % (FREE["lut"] - t)) if t <= FREE["lut"] else ("%.2fx OVER" % (t / FREE["lut"])),
        ("FITS +%d" % (PBFREE["lut"] - t)) if t <= PBFREE["lut"] else ("%.2fx OVER" % (t / PBFREE["lut"]))))
print("\nBRAM: lever 1 adds 0 tiles.  Lever 2 MEASURED 6 tiles for one N=4096 unit;")
print("B+C+D hold %d flat vector elements in total, which at 4096 x 16b per" % (2048*4 + 4096 + 4096*3))
print("RAMB18 is of order 30-60 tiles against %d free in pb_core and 320 free URAM." % PBFREE["bram"])
