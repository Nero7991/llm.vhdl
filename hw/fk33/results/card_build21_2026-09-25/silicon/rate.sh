#!/usr/bin/env bash
# Build 21 hang rate: 40-id prefill runs, reloading the wedged card after each hang.
# Stops at 30 sequences or 4 hangs. Serial from the hung node's BDF (nodes swap on reload).
cd /home/orencollaco/GitHub/llama.vhdl
L=/mnt/storage/fk33_builds/card_build21/vtest
runs=4; hangs=2   # VALID so far: batch a 1/1 hung, rate_1 3 runs 1 hang; rate_2 and rate_3 were the sticky error of an un-reloaded card (script bug)
i=0
while [ $runs -lt 30 ] && [ $hangs -lt 4 ]; do
  i=$((i+1)); for s in 153300000607A 153300001366A; do :; done
  # recover every card whose seam says err=1 in the last failed run
  last=$(ls -dt $L/v0715*_n40x30/ $L/rate_*/ $L/rate2_*/ 2>/dev/null | head -1)
  for f in $(grep -l 'err=1' $(ls -t $last/*_seam_xdma*.txt | head -2) 2>/dev/null); do
    n=$(echo $f | grep -oP 'xdma\K[01]'); bdf=$(basename $(readlink -f /sys/class/xdma/xdma${n}_user/device))
    case $bdf in 0000:07:00.0) s=153300000607A;; 0000:06:00.0) s=153300001366A;; esac
    echo "RATE reload $s (was xdma$n, $bdf)"; $L/load_b21.sh $s || { echo "RATE_ABORT reload failed"; exit 1; }
  done
  O=$L/rate2_$i; left=$((30-runs))
  TESTS=input REPEATS=$left hw/fk33/host/fk33_ctxtest.sh pair $O 40 > $O.out 2>&1
  ok=$(grep -c '^CTXTEST_RUN.*rc 0' $O/ctxtest.log); bad=$(grep -c '^CTXTEST_FAIL' $O/ctxtest.log)
  runs=$((runs+ok+bad)); hangs=$((hangs+bad))
  echo "RATE batch $i: ok=$ok hang=$bad  totals runs=$runs hangs=$hangs $(grep -h -E 'D.s own code|ERR_INFO' $(grep -l 'err=1' $O/*_seam_*.txt 2>/dev/null | tail -1) 2>/dev/null | tr -s ' ' | cut -c1-120 | tr '\n' ' ')"
done
echo "RATE_DONE runs=$runs hangs=$hangs"
