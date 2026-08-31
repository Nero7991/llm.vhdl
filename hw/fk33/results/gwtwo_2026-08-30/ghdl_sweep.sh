#!/usr/bin/env bash
# TRACK GWTWO -- the GHDL half.  One row at a time, capped, sequential.
set -u
SD=/mnt/storage/gwtwo
for G in 4 2 1 8; do
  for ROW in tb_rmswire_loadrace tb_llama_top_normw; do
    echo "=== GW=$G ROW=$ROW start $(date -Is)"
    systemd-run --user --scope --quiet --unit="gwtwo-ghdl-$G-$ROW" \
      -p MemoryHigh=4G -p MemoryAccounting=yes \
      -- env "REGRESS_SCRATCH=$SD/rs_gw$G" \
         bash "$SD/tree_gw$G/sim/regress.sh" --jobs 1 --only "$ROW" --keep \
      > "$SD/ghdl_${G}_${ROW}.log" 2>&1
    echo "=== GW=$G ROW=$ROW rc=$? $(date -Is)"
    grep -E "^ OVERALL" "$SD/ghdl_${G}_${ROW}.log" || echo "NO OVERALL LINE"
    cat "$SD/rs_gw$G/res.sim_$ROW" 2>/dev/null || echo "NO RES"
  done
done
echo GWTWO_GHDL_ALL_DONE
