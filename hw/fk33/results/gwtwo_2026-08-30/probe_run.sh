#!/usr/bin/env bash
# TRACK GWTWO -- the real-shape (NN=4096) rate probe, one point at a time.
set -u
SD=/mnt/storage/gwtwo
IMG=/mnt/storage/nwfix/img/norm_w_9b.hex
for V in gw1 gw2 gw4 gw8 gw4slow; do
  W="$SD/probe/w_$V"
  mkdir -p "$W"
  echo "=== $V build $(date -Is)"
  ghdl -i --std=08 --workdir="$W" "$SD/rtl_$V"/*.vhd "$SD/gwtwo_rateprobe.vhd" > "$SD/probe_${V}_build.log" 2>&1
  ghdl -m --std=08 --workdir="$W" gwtwo_rateprobe >> "$SD/probe_${V}_build.log" 2>&1
  echo "=== $V run $(date -Is)"
  ( ulimit -s unlimited
    ghdl -r --std=08 --workdir="$W" gwtwo_rateprobe \
         "-gNORM_W_IMAGE=$IMG" --max-stack-alloc=0 --stop-time=5ms
  ) > "$SD/probe_${V}.out" 2>&1
  # rc taken off the SUBSHELL, never off a pipeline: an rc read off a pipeline
  # is the pipeline's rc, and that trap already hid a SIGSEGV once in this run.
  echo "=== $V rc=$?"
  grep -E "GWTWO_RATEPROBE NN=" "$SD/probe_${V}.out" || echo "=== $V NO RESULT LINE"
done
echo GWTWO_PROBE_ALL_DONE
