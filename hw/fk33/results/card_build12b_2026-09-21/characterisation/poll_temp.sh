#!/usr/bin/env bash
# Poll SYSMON die temperature over PCIe MMIO every 15 s until the sentinel appears.
S=/mnt/storage/fk33_builds/scratch/b12b_char
cd /home/orencollaco/GitHub/llama.vhdl
while [ ! -f "$S/RUN2048_DONE" ]; do
  t=$(python3 hw/fk33/host/fk33ctl.py sysmon 2>/dev/null | awk '/die temperature/{print $3}')
  echo "$(date +%s) $t" >> "$S/temp2048.log"
  sleep 15
done
echo "$(date +%s) poller-exit" >> "$S/temp2048.log"
