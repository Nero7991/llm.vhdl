#!/usr/bin/env bash
# ooc_nwrom_summarise.sh -- TRACK NWROM, 2026-08-29.
#
# Collate the NWROM synthesis points into one table: the CSV row, the
# hierarchical split (adapter's own logic vs `gvr.u_rms`), and the top census
# roots.  Points that FAILED are listed with the first ERROR line, because a
# missing row and a failed row are different facts and the failure is a result
# here, not an accident.
#
# NO HARDWARE.  Reads files.
set -u
OUT="${1:?usage: ooc_nwrom_summarise.sh <outdir> [tag ...]}"
shift
TAGS=("$@")
if [ "${#TAGS[@]}" -eq 0 ]; then
    mapfile -t TAGS < <(ls "$OUT"/vivado_*.log 2>/dev/null \
                        | sed 's#.*/vivado_##; s#\.log$##' | sort)
fi

printf '%-14s %9s %9s %9s %8s %7s %6s %6s %6s %9s %9s\n' \
       tag lut own u_rms ff dsp bram uram carry8 f7 f8
for t in "${TAGS[@]}"; do
    csv="$OUT/result_$t.csv"
    if [ ! -f "$csv" ]; then
        e=$(grep -m1 -E "^ERROR" "$OUT/vivado_$t.log" 2>/dev/null | cut -c1-96)
        printf '%-14s %s\n' "$t" "${e:-(no result yet -- still running or never started)}"
        continue
    fi
    read -r lut ff dsp bram uram c8 f7 f8 < <(tail -1 "$csv" | awk -F, \
        '{print $4, $7, $3, $10, $11, $12, $13, $14}')
    own=$(awk -F'|' '/\((ooc_[a-z0-9_]*)\)/ && NF>3 {gsub(/ /,"",$4); print $4; exit}' \
          "$OUT/synthutil_hier_$t.rpt" 2>/dev/null)
    rms=$(awk -F'|' '/rmsnorm_rs/ && NF>3 {gsub(/ /,"",$4); print $4; exit}' \
          "$OUT/synthutil_hier_$t.rpt" 2>/dev/null)
    printf '%-14s %9s %9s %9s %8s %7s %6s %6s %6s %9s %9s\n' \
           "$t" "$lut" "${own:--}" "${rms:--}" "$ff" "$dsp" "$bram" "$uram" \
           "$c8" "$f7" "$f8"
done
