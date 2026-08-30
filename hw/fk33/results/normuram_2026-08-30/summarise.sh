#!/usr/bin/env bash
# TRACK NORMURAM -- unfiltered table of EVERY point attempted, failures included.
# Same extractor as TRACK NWFIX's, so the columns line up with its table.
#
# ITS TEETH: `nu_empty` must print 49654 / 25523 / 24131 / 133197 before any
# other row is read.  A results table that reads `-` in a column is a broken
# extractor, not a missing number (NWFIX section 7.9).
set -u
OUT=/mnt/storage/normuram/out
printf '%-12s %-16s %8s %9s %9s %8s %6s %6s %6s %7s %7s %8s %10s %12s %8s\n' \
  tag top lut own u_rms ff dsp bram uram carry8 f7 f8 wns fmax synth_s
for tag in $(ls $OUT/run_*.log 2>/dev/null | sed 's#.*/run_##; s#\.log##' | sort); do
  csv="$OUT/result_$tag.csv"
  if [ ! -s "$csv" ]; then
    err=$(grep -m1 -E "^ERROR" "$OUT/run_$tag.log" 2>/dev/null | cut -c1-96)
    printf '%-12s %s\n' "$tag" "${err:-NO CSV AND NO ERROR LINE}"
    continue
  fi
  h="$OUT/synthutil_hier_$tag.rpt"
  own=$(awk -F'|' '$2 ~ /^ *\(.*\) *$/ && $3 ~ /\(top\)/ {gsub(/ /,"",$4); print $4; exit}' "$h" 2>/dev/null)
  rms=$(awk -F'|' '$3 ~ /rmsnorm_rs/ {gsub(/ /,"",$4); print $4; exit}' "$h" 2>/dev/null)
  top=$(awk -F, 'NR==2{print $1}' "$csv")
  awk -F, -v t="$tag" -v tp="$top" -v o="${own:--}" -v r="${rms:--}" 'NR==2{
    printf "%-12s %-16s %8s %9s %9s %8s %6s %6s %6s %7s %7s %8s %10s %12s %8s\n",
      t, tp, $4, o, r, $7, $3, $10, $11, $12, $13, $14, $15, $16, $17 }' "$csv"
done
