#!/usr/bin/env bash
# Build 15 draw 3: preserve artefacts to KEEP and copy the reports into the repo results dir. Run AFTER ^REIMPL_BUILD_DONE.
B=/mnt/storage/fk33_builds/build15; K=/mnt/storage/fk33_builds/KEEP_build15_dcp; I=$B/root/fk33_pcieep/fk33_pcieep.runs/impl_1
R=/home/orencollaco/GitHub/llama.vhdl/hw/fk33/results/card_build15_2026-09-22
mkdir -p $K/draw3 $R/draw3
for f in bd_wrapper.bit bd_wrapper_placed.dcp bd_wrapper_routed.dcp bd_wrapper_route_status.rpt bd_wrapper_route_status_reimpl3.rpt bd_wrapper_timing_summary_routed.rpt bd_wrapper_utilization_placed.rpt bd_wrapper_utilization_routed_reimpl3.rpt runme.log; do cp $I/$f $K/draw3/ 2>/dev/null; done
cp $B/reimpl3.stdout $B/reimpl3.log $B/reimpl3.tcl $K/draw3/ 2>/dev/null
(cd $K && sha256sum *.dcp draw3/*.dcp draw3/*.bit > SHA256SUMS)
for f in bd_wrapper_route_status_reimpl3.rpt bd_wrapper_utilization_placed.rpt bd_wrapper_utilization_routed_reimpl3.rpt; do cp $I/$f $R/draw3/; done
gzip -c $I/bd_wrapper_timing_summary_routed.rpt > $R/draw3/bd_wrapper_timing_summary_routed.rpt.gz
gzip -c $B/reimpl3.stdout > $R/draw3/reimpl3.stdout.gz
cp $I/bd_wrapper.bit $R/bd_wrapper.bit && (cd $R && sha256sum bd_wrapper.bit > BITSTREAM.sha256)
echo "collected: KEEP $(ls $K/draw3 | wc -l) files, repo $(ls $R/draw3 | wc -l) files, bit $(stat -c %s $R/bd_wrapper.bit) bytes"
