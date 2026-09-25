#!/usr/bin/env bash
# Build 21 launch (prepared 2026-09-25; wt21 = 8af98b8 + levers-off patch with SWEEP_PIPE and SCORE_EARLY put back ON (C only)). ONE Vivado on this box: refuse if any is present. Env is the recorded list.
B=/mnt/storage/fk33_builds/build21; W=/mnt/storage/fk33_builds/wt21
n=0; for p in $(ls /proc | grep -E '^[0-9]+$'); do e=$(readlink /proc/$p/exe 2>/dev/null) || continue; case "$e" in *unwrapped/lnx64.o/vivado*) n=$((n+1));; esac; done
if [ "$n" -ne 0 ]; then echo "vivado present ($n procs): NOT launching build 21"; exit 1; fi
cd $W && git log --oneline -1 && git diff --stat | tail -1
systemd-run --user --unit=card21-build -p MemoryHigh=24G -p MemoryMax=26G \
  --setenv=FK33_CARD=1 --setenv=FK33_CB_STYLE=distributed --setenv=FK33_ENG_CORE_MHZ=75 --setenv=FK33_SYNTH_THREADS=1 \
  --setenv=BUILD_ROOT=$B/root --working-directory=$W /usr/bin/bash -c "hw/fk33/pcieep_build.sh > $B/build.stdout 2>&1"
date +%T > $B/LAUNCHED
nohup bash $B/swapguard.sh >/dev/null 2>&1 &
nohup bash $B/watch.sh >/dev/null 2>&1 &
nohup bash $B/chain.sh >/dev/null 2>&1 &
echo "build 21 launched $(date +%T)"
