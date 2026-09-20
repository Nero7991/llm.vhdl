#!/usr/bin/env bash
# ooc_readconv_probe.sh -- TRACK READCONV, 2026-08-29.
# The read-port-width probe.  Same store, same write decode, four read shapes.
# ONE Vivado at a time.  NO HARDWARE.
set -u
# Sibling script, addressed relative to this one rather than by an
# absolute path (TRACK PATHFREE, 2026-09-20).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ooc_lutdiet_run.sh"
OUT=/mnt/storage/readconv/out
RTL=/mnt/storage/readconv/rtl_probe
TAG="${1:?}"; TOP="${2:?}"; shift 2
LUTDIET_NOOPT=1 LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
  bash "$R" "$TAG" "$TOP" "$OUT" "$RTL" "$@" >> "$OUT/DRIVE.log" 2>&1
echo "probe $TAG rc=$?"
