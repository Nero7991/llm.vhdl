#!/usr/bin/env bash
# summarise.sh -- TRACK GWTWO.  Pulls the points into one table and puts the
# object-level RAMB census beside report_utilization's row, because CLAUDE.md's
# rule is that the two must be cross-checked and the census wins on
# disagreement.  Here they agree exactly at every point.
set -u
D="${1:-.}"
printf '%-8s %8s %8s %8s %7s %7s %6s %6s %8s %9s\n' \
  GW LUT FF RAMB36 RAMB18 TILE URAM DSP WNS FMAX
for G in 1 1land 2 4 8; do
  f="$D/result_gw$G.csv"
  [ -r "$f" ] || continue
  tail -1 "$f" | awk -F, -v g="gw$G" '{printf "%-8s %8s %8s %8s %7s %7s %6s %6s %8s %9.1f\n", g,$4,$7,$8,$9,$10,$11,$3,$15,$16}'
done
echo
echo "== object-level get_cells census vs report_utilization =="
grep -h "^GWTWO_CENSUS tag=" "$D"/census.log 2>/dev/null || true
echo
echo "== where the primitives live (from bramcensus_*.txt) =="
for G in 1 2 4 8; do
  c="$D/bramcensus_gw$G.txt"
  [ -r "$c" ] || continue
  echo "-- gw$G"
  grep -E "^== RAMB|^  \(top\)|^  gvr" "$c"
done
