#!/usr/bin/env bash
# Build 16 chain: let the DEFAULT flow run to its verdict; if the unit ends WITHOUT a bitstream
# and with a synth checkpoint, run the rescue re-implementation from that checkpoint.
B=/mnt/storage/fk33_builds/build18
while systemctl --user is-active --quiet card18-build.service; do sleep 60; done
echo "$(date +%T) build unit ended" >> $B/chain.log
if grep -q '^FK33_BUILD_DONE' $B/build.stdout 2>/dev/null; then echo "$(date +%T) default flow wrote a bitstream: NOT re-implementing" >> $B/chain.log; exit 0; fi
systemctl --user reset-failed card18-build.service 2>/dev/null
I=$B/root/fk33_pcieep/fk33_pcieep.runs/impl_1; K=/mnt/storage/fk33_builds/KEEP_build18_dcp; mkdir -p $K/draw1
for f in bd_wrapper_placed.dcp bd_wrapper_routed.dcp bd_wrapper_route_status.rpt bd_wrapper_timing_summary_routed.rpt bd_wrapper_utilization_placed.rpt runme.log; do cp $I/$f $K/draw1/ 2>/dev/null; done
cp $B/root/fk33_pcieep/fk33_pcieep.runs/synth_1/bd_wrapper.dcp $K/bd_wrapper_synth.dcp 2>/dev/null
n=0; for p in $(ls /proc | grep -E '^[0-9]+$'); do e=$(readlink /proc/$p/exe 2>/dev/null) || continue; case "$e" in *unwrapped/lnx64.o/vivado*) n=$((n+1));; esac; done
if [ "$n" -ne 0 ]; then echo "$(date +%T) vivado still present ($n): NOT launching reimpl" >> $B/chain.log; exit 1; fi
[ -f $B/root/fk33_pcieep/fk33_pcieep.runs/synth_1/bd_wrapper.dcp ] || { echo "$(date +%T) no synth dcp: NOT launching" >> $B/chain.log; exit 1; }
systemd-run --user --unit=card18-reimpl -p MemoryHigh=24G -p MemoryMax=26G --working-directory=$B /usr/bin/bash -c "$B/reimpl_run.sh > $B/reimpl.stdout 2>&1"
date +%T > $B/REIMPL_LAUNCHED; echo "$(date +%T) reimpl launched" >> $B/chain.log
nohup bash $B/reimpl_guard.sh >/dev/null 2>&1 &
nohup bash $B/reimpl_watch.sh >/dev/null 2>&1 &
