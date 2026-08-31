#!/usr/bin/env bash
# summarise.sh -- TRACK RMSWIRE, 2026-08-30.  Reads the two result CSVs the
# LUTDIET flow writes and prints the composed comparison, INCLUDING the BRAM
# total, which is the number the dispatcher asked to be first-class.
#
# NO HARDWARE.  Reads text files.
set -u
D="${1:-$(dirname "$0")}"
printf '%-10s %8s %8s %8s %6s %6s %7s %7s %8s %8s\n' \
       tag lut lut_mem ff dsp bram uram f7 f8 wns
for t in ctl_flat mem_bank; do
  f="$D/result_$t.csv"
  [ -r "$f" ] || { echo "$t: NO CSV"; continue; }
  tail -1 "$f" | awk -F, -v t="$t" '{
    printf "%-10s %8s %8s %8s %6s %6s %7s %7s %8s %8s\n",
           t, $4, $6, $7, $3, $10, $11, $13, $14, $15 }'
done
echo
echo "-- BRAM in context.  672 Block RAM Tiles on xcvu33p-fsvh2104-2L-e."
echo "-- pb_core holds 576 of them and 203.5 are non-assigned shell cells,"
echo "-- so 372.5 are available to this design (DERIVED, dispatcher"
echo "-- 2026-08-30, from hw/fk33/results/build_e2e_2026-08-29/"
echo "-- e2e_pblock_util_routed.rpt).  The composed A+B+C+D already uses"
echo "-- 246.5 (hw/fk33/results/compose4_2026-08-29/util_c4_synth.rpt) with"
echo "-- NO gain image and the FLAT norm unit, so the gvr figures below are"
echo "-- what has to be ADDED to that 246.5."
