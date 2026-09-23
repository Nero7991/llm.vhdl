#!/usr/bin/env bash
# Build 15 chain 4: when draw 3 (card15-reimpl3) ends, preserve its artefacts (collect3.sh), then launch draw 3b
# (post-route phys_opt_design on draw 3's routed checkpoint, reimpl4.tcl) if the Vivado lane is free.
B=/mnt/storage/fk33_builds/build15
while [ ! -f $B/REIMPL3_ENDED ]; do sleep 20; done
echo "$(date +%T) draw 3 unit ended: $(tail -1 $B/reimpl3_watch.log)" >> $B/chain4.log
systemctl --user reset-failed card15-reimpl3.service 2>/dev/null
bash $B/collect3.sh >> $B/chain4.log 2>&1
n=0; for p in $(ls /proc | grep -E '^[0-9]+$'); do e=$(readlink /proc/$p/exe 2>/dev/null) || continue; case "$e" in *unwrapped/lnx64.o/vivado*) n=$((n+1));; esac; done
if [ "$n" -ne 0 ]; then echo "$(date +%T) vivado still present ($n): NOT launching draw 3b" >> $B/chain4.log; exit 1; fi
systemd-run --user --unit=card15-reimpl4 -p MemoryHigh=24G -p MemoryMax=26G --working-directory=$B /usr/bin/bash -c "$B/reimpl4_run.sh > $B/reimpl4.stdout 2>&1"
date +%T > $B/REIMPL4_LAUNCHED
echo "$(date +%T) draw 3b launched" >> $B/chain4.log
nohup bash $B/reimpl4_guard.sh >/dev/null 2>&1 &
nohup bash $B/reimpl4_watch.sh >/dev/null 2>&1 &
