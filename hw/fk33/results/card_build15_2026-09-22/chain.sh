#!/usr/bin/env bash
# Build 15 chain: wait for synthesis to complete (the sentinel the work writes, line-anchored),
# stop the default implementation, and run the rescue re-implementation from the synth checkpoint.
B=/mnt/storage/fk33_builds/build15
while :; do
  if grep -q '^FK33_RUNDONE synth_1' $B/build.stdout 2>/dev/null; then break; fi
  if ! systemctl --user is-active --quiet card15-build.service; then echo "$(date +%T) unit ended before synth_1 done: NOT chaining" >> $B/chain.log; exit 1; fi
  sleep 60
done
echo "$(date +%T) synth_1 done; stopping the default implementation" >> $B/chain.log
systemctl --user kill card15-build.service
for i in $(seq 1 60); do systemctl --user is-active --quiet card15-build.service || break; sleep 5; done
systemctl --user reset-failed card15-build.service 2>/dev/null
n=0; for p in $(ls /proc | grep -E '^[0-9]+$'); do e=$(readlink /proc/$p/exe 2>/dev/null) || continue; case "$e" in *unwrapped/lnx64.o/vivado*) n=$((n+1));; esac; done
if [ "$n" -ne 0 ]; then echo "$(date +%T) vivado still present ($n): NOT launching reimpl" >> $B/chain.log; exit 1; fi
[ -f $B/root/fk33_pcieep/fk33_pcieep.runs/synth_1/bd_wrapper.dcp ] || { echo "$(date +%T) no synth dcp: NOT launching" >> $B/chain.log; exit 1; }
systemd-run --user --unit=card15-reimpl -p MemoryHigh=24G -p MemoryMax=26G --working-directory=$B /usr/bin/bash -c "$B/reimpl_run.sh > $B/reimpl.stdout 2>&1"
date +%T > $B/REIMPL_LAUNCHED
echo "$(date +%T) reimpl launched" >> $B/chain.log
nohup bash $B/reimpl_guard.sh >/dev/null 2>&1 &
nohup bash $B/reimpl_watch.sh >/dev/null 2>&1 &
