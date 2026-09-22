#!/usr/bin/env bash
# Long-prompt run: ~1000 words, 8 new tokens, to time prompt processing explicitly.
S=/mnt/storage/fk33_builds/scratch/b12b_char
cd /home/orencollaco/GitHub/llama.vhdl
for i in 1 2; do
  hw/fk33/host/fk33_chat.sh "$(cat $S/longprompt.txt)" 8 2> $S/prefill$i.err | python3 $S/tstamp.py $S/prefill$i.ts > $S/prefill$i.out
done
echo done > $S/PREFILL_DONE
