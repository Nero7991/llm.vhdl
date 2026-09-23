#!/usr/bin/env bash
# Two-card oracle (Task 11 step 3): the same three prompts on the pair, judged on ids
# against the single card's p<i>_r1.ids.  Needs /dev/xdma1 and both cards loaded with
# build 18 and their per-card images (FK33_MODEL_DIR0/1).  MAIN session only.
set -uo pipefail
REP="${1:-1}"; S=/mnt/storage/fk33_builds/build18/oracle; cd /home/orencollaco/GitHub/llama.vhdl
[[ -e /dev/xdma1_user ]] || { echo "no /dev/xdma1_user: second card not present"; exit 1; }
i=0
while IFS= read -r Q; do
  i=$((i+1)); T=$S/pair_p${i}_r$REP
  date +%T > $T.start
  hw/fk33/host/fk33_chat2.sh "$Q" 128 --reference $S/p${i}_r1.ids --ids-out $T.ids 2> $T.err | python3 $S/tstamp.py $T.ts > $T.out
  echo "rc=$?" >> $T.start
  grep -E '^(prefill|decode|timing|hop|ids|MATCH|FIRST)' $T.out
done < $S/prompts.txt
echo "PAIR_R${REP}_DONE $(date +%T)"
