#!/usr/bin/env bash
# Build 15 chain 2: when draw 2 (card15-reimpl) ends, preserve its artefacts, then launch draw 2.
B=/mnt/storage/fk33_builds/build15; K=/mnt/storage/fk33_builds/KEEP_build15_dcp; I=$B/root/fk33_pcieep/fk33_pcieep.runs/impl_1
while systemctl --user is-active --quiet card15-reimpl2.service; do sleep 30; done
echo "$(date +%T) draw 2 unit ended" >> $B/chain3.log
systemctl --user reset-failed card15-reimpl2.service 2>/dev/null
cp $B/root/fk33_pcieep/fk33_pcieep.runs/synth_1/bd_wrapper.dcp $K/bd_wrapper_synth.dcp 2>/dev/null
for f in bd_wrapper.bit bd_wrapper_placed.dcp bd_wrapper_routed.dcp bd_wrapper_route_status.rpt bd_wrapper_timing_summary_routed.rpt bd_wrapper_utilization_placed.rpt runme.log; do cp $I/$f $K/draw2/ 2>/dev/null; done
cp $B/reimpl2.stdout $B/reimpl2.log $B/PREDICTION_congestion.md $K/draw2/ 2>/dev/null
(cd $K && sha256sum *.dcp draw2/*.dcp > SHA256SUMS)
echo "$(date +%T) draw 2 artefacts preserved: $(ls $K/draw2 | wc -l) files" >> $B/chain3.log
if grep -q "^REIMPL_BUILD_DONE" $B/reimpl2.stdout 2>/dev/null; then echo "$(date +%T) draw 2 wrote a bitstream: NOT launching draw 3" >> $B/chain3.log; exit 0; fi
n=0; for p in $(ls /proc | grep -E '^[0-9]+$'); do e=$(readlink /proc/$p/exe 2>/dev/null) || continue; case "$e" in *unwrapped/lnx64.o/vivado*) n=$((n+1));; esac; done
if [ "$n" -ne 0 ]; then echo "$(date +%T) vivado still present ($n): NOT launching draw 3" >> $B/chain3.log; exit 1; fi
systemd-run --user --unit=card15-reimpl3 -p MemoryHigh=24G -p MemoryMax=26G --working-directory=$B /usr/bin/bash -c "$B/reimpl3_run.sh > $B/reimpl3.stdout 2>&1"
date +%T > $B/REIMPL3_LAUNCHED
echo "$(date +%T) draw 3 launched" >> $B/chain3.log
nohup bash $B/reimpl3_guard.sh >/dev/null 2>&1 &
nohup bash $B/reimpl3_watch.sh >/dev/null 2>&1 &
