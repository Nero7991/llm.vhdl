#!/usr/bin/env bash
# TRACK GWTWO -- teeth.  Does tb_llama_top_normw actually SEE a GW-dependent
# packing error?  A PASS at a new GW means nothing until this table exists.
set -u
SD=/mnt/storage/gwtwo
for J in gw1_M1 gw2_M1 gw4_M1 gw2_M2; do
  echo "=== MUT=$J start $(date -Is)"
  systemd-run --user --scope --quiet --unit="gwtwo-mut-$J" \
    -p MemoryHigh=4G -p MemoryAccounting=yes \
    -- env "REGRESS_SCRATCH=$SD/rs_$J" \
       bash "$SD/tree_$J/sim/regress.sh" --jobs 1 --only tb_llama_top_normw --keep \
    > "$SD/mut_$J.log" 2>&1
  echo "=== MUT=$J rc=$? $(date -Is)"
  grep -E "^ OVERALL" "$SD/mut_$J.log" || echo "NO OVERALL LINE"
  cat "$SD/rs_$J/res.sim_tb_llama_top_normw" 2>/dev/null || echo "NO RES"
done
echo GWTWO_MUT_ALL_DONE
