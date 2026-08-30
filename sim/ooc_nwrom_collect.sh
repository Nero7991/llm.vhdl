#!/usr/bin/env bash
# ooc_nwrom_collect.sh -- TRACK NWROM, 2026-08-29.
#
# Copy the NWROM synthesis artefacts out of the scratch tree into
# `hw/fk33/results/nwrom_2026-08-29/`: the result CSVs, the utilization and
# hierarchical utilization reports, the censuses, the peak-RSS records and the
# Vivado logs of the runs that FAILED (a failure is a result here).
#
# The 4.26 Mbit gain image itself is NOT copied -- it is 1.3 MB of derived data
# reproducible in 6 s from `sim/ooc_nwrom_gen_image.py` and the gguf.
#
# NO HARDWARE.  Copies files.
set -u
SCR="${1:-/mnt/storage/nwrom}"
DST="${2:-$(cd "$(dirname "$0")/.." && pwd)/hw/fk33/results/nwrom_2026-08-29}"
mkdir -p "$DST"
cp -v "$SCR"/PINNED_SHA.txt "$SCR"/bit_entropy.txt "$DST"/ 2>/dev/null
cp -v "$SCR"/norm_w_9b_stats.csv "$DST"/ 2>/dev/null
for f in "$SCR"/out/result_*.csv "$SCR"/out/census_*.txt "$SCR"/out/mem_*.txt \
         "$SCR"/out/synthutil_*.rpt; do
    [ -f "$f" ] && cp "$f" "$DST"/
done
# the failing runs: keep only their ERROR lines, not the 10 MB log
for l in "$SCR"/out/vivado_*.log; do
    t=$(basename "$l" .log); t=${t#vivado_}
    if [ ! -f "$SCR/out/result_$t.csv" ]; then
        grep -E "^(ERROR|CRITICAL WARNING)" "$l" > "$DST/errors_$t.txt" 2>/dev/null
    fi
done
ls -la "$DST" | tail -n +2 | wc -l
