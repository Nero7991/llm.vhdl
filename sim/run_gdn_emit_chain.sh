#!/usr/bin/env bash
# Build the reference vectors and run tb_gdn_emit_chain against them.
#
# The chain is four units and four seams deep, so it is the one place where a
# unit-level pass on each part still leaves the whole thing unverified.  Seam 4
# in particular (in_e = rn_exp + z_exp) is an exponent SUM: getting it wrong
# scales the entire block by a power of two, which reads as a plausible answer
# rather than a broken one, and only the y_exp check catches it.
#
# GHDL here is the mcode backend: `ghdl -e` produces no binary and silently
# succeeds, so `ghdl -r <entity>` is run directly.  Package analysis order is
# load bearing: fixed_luts_pkg -> fixed_pkg -> util_pkg.
set -euo pipefail
cd "$(dirname "$0")/.."
BLOCKS="${1:-3}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gcc -O2 -o "$WORK/gec" ref/gdn_emit_chain_vec.c -lm
( cd "$WORK" && "$WORK/gec" gdn_emit_chain_vec.txt "$BLOCKS" 24 128 )

for f in util_pkg fixed_luts_pkg fixed_pkg \
         gdn_head_emit rmsnorm_bf gdn_silu gdn_y_emit gdn_emit_chain; do
  ghdl -a --std=08 -frelaxed --workdir="$WORK" "rtl/$f.vhd"
done
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/tb_gdn_emit_chain.vhd

# --stop-time is a backstop only; the testbench drops `running` and ends on
# its own.  Four testbenches in this project once ran forever on an unguarded
# clock, one of them for 4h58m at 99.5% CPU.
# Both modes. OVERLAP=false drains between blocks; OVERLAP=true is how the
# chain actually runs and is the mode that catches the w_mant hazard -- with
# the weight latch removed it fails on head 23 of every block, and ONLY head
# 23, because that is the head whose norm runs after the producer has moved on.
for ov in false true; do
  echo "=== OVERLAP=$ov ==="
  ( cd "$WORK" && ghdl -r --std=08 -frelaxed --workdir="$WORK" \
      tb_gdn_emit_chain "-gOVERLAP=$ov" --stop-time=300ms )
done
