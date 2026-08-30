#!/usr/bin/env bash
# ooc_readconv_probe.sh -- TRACK READCONV, 2026-08-29.
# The read-port-width probe.  Same store, same write decode, four read shapes.
# ONE Vivado at a time.  NO HARDWARE.
set -u
R=/home/orencollaco/GitHub/llama.vhdl/sim/ooc_lutdiet_run.sh
OUT=/mnt/storage/readconv/out
RTL=/mnt/storage/readconv/rtl_probe
TAG="${1:?}"; TOP="${2:?}"; shift 2
LUTDIET_NOOPT=1 LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
  bash "$R" "$TAG" "$TOP" "$OUT" "$RTL" "$@" >> "$OUT/DRIVE.log" 2>&1
echo "probe $TAG rc=$?"
