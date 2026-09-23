#!/usr/bin/env bash
# Single-card oracle recording for Task 11 step 3 (build 18 on the card).
# usage: run_single.sh <rep>     writes p<i>_r<rep>.{out,err,ts,ids,xout} per prompt line.
# Opens /dev/xdma0 through fk33_chat.sh: the MAIN session runs this, never a subagent.
set -uo pipefail
REP="${1:?rep}"; S=/mnt/storage/fk33_builds/build18/oracle; cd /home/orencollaco/GitHub/llama.vhdl
i=0
while IFS= read -r Q; do
  i=$((i+1)); T=$S/p${i}_r$REP
  date +%T > $T.start
  hw/fk33/host/fk33_chat.sh "$Q" 128 --ids-out $T.ids --dump-xout $T.xout 2> $T.err | python3 $S/tstamp.py $T.ts > $T.out
  echo "rc=$?" >> $T.start
  grep -E '^(prefill|decode|timing|ids|xout)' $T.out
done < $S/prompts.txt
echo "SINGLE_R${REP}_DONE $(date +%T)"
