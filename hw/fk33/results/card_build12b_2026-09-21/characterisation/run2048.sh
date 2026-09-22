#!/usr/bin/env bash
S=/mnt/storage/fk33_builds/scratch/b12b_char
cd /home/orencollaco/GitHub/llama.vhdl
date +%s > $S/run2048.start
$S/chat_nostop.sh "Write a long, detailed essay on the history of power electronics, from mercury-arc rectifiers to gallium nitride." 2048 \
  2> $S/run2048.err | python3 $S/tstamp.py $S/run2048.ts > $S/run2048.out
echo "rc=${PIPESTATUS[0]}" > $S/RUN2048_DONE
date +%s >> $S/RUN2048_DONE
