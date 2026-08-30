#!/usr/bin/env bash
# ooc_readconv_drive.sh -- TRACK READCONV, 2026-08-29.
#
# ONE Vivado at a time, deliberately: 31 GB box, gdn_block peaks ~14 GiB and
# the 2026-07-04 systemd-oomd incident is what two concurrent runs look like.
#
# NO HARDWARE.  It only ever calls sim/ooc_lutdiet_ports.tcl, which is
# synth_design / report_* and never opens a target.
#
# usage: ooc_readconv_drive.sh <tag> <top> [generic ...]
set -u
R=/home/orencollaco/GitHub/llama.vhdl/sim/ooc_lutdiet_run.sh
OUT=/mnt/storage/readconv/out
RTL=/mnt/storage/readconv/rtl_v
TAG="${1:?usage: ooc_readconv_drive.sh <tag> <top> [generics]}"
TOP="${2:?}"
shift 2
mkdir -p "$OUT"
echo "[$(date -Is)] begin $TAG top=$TOP gen='$*'" >> "$OUT/DRIVE.log"
LUTDIET_NOOPT=1 LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
  bash "$R" "$TAG" "$TOP" "$OUT" "$RTL" "$@" >> "$OUT/DRIVE.log" 2>&1
RC=$?
echo "[$(date -Is)] end $TAG rc=$RC" >> "$OUT/DRIVE.log"
exit $RC
