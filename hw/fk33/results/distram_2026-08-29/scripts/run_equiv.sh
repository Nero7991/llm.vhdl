#!/usr/bin/env bash
# run_equiv.sh -- TRACK DISTRAM, 2026-08-29.
#
# One shadow-DUT equivalence run: the working-tree rtl/ (which carries the
# distributed-RAM vbuf) plus gdn_block_ref (the pinned gdn_block, renamed),
# plus tb_distram_gdn, which compares all 37 output ports every rising edge.
#
# GHDL here is the MCODE backend: `ghdl -e` emits no binary and silently
# succeeds, so this only ever calls `ghdl -a` and `ghdl -r`.
#
# NO HARDWARE.  Simulation only.
#
# usage: run_equiv.sh <workdir> <rtldir> [ghdl generic args ...]
set -u
REPO=/home/orencollaco/GitHub/llama.vhdl
RES=$REPO/hw/fk33/results/distram_2026-08-29
W="${1:?usage: run_equiv.sh <workdir> <rtldir> [-gX=Y ...]}"
RTLDIR="${2:?}"
shift 2 || true
mkdir -p "$W/obj" "$W/run"

# Fixed-point analysis: repeat until a pass adds nothing.  The rtl/ tree has no
# declared build order and hand-ordering it is how a file silently goes stale.
FILES=("$RTLDIR"/*.vhd "$RES"/rtl/gdn_block_ref.vhd "$RES"/rtl/tb_distram_gdn.vhd)
PEND=("${FILES[@]}")
for pass in 1 2 3 4 5 6 7 8; do
  NEXT=()
  for f in "${PEND[@]}"; do
    if ! ghdl -a --std=08 -frelaxed --workdir="$W/obj" "$f" >"$W/a.log" 2>&1; then
      NEXT+=("$f")
      cp "$W/a.log" "$W/a_last_$(basename "$f").log"
    fi
  done
  echo "pass $pass: ${#PEND[@]} in, ${#NEXT[@]} still failing"
  if [ "${#NEXT[@]}" -eq 0 ]; then break; fi
  if [ "${#NEXT[@]}" -eq "${#PEND[@]}" ]; then
    echo "ANALYSIS STUCK -- these never analysed:"
    printf '  %s\n' "${NEXT[@]}"
    for f in "${NEXT[@]}"; do echo "--- $(basename "$f")"; cat "$W/a_last_$(basename "$f").log"; done
    echo "VOID: analysis failure is NOT a result"
    exit 91
  fi
  PEND=("${NEXT[@]}")
done

cd "$W/run" || exit 92
timeout -k 5 3600 ghdl -r --std=08 -frelaxed --workdir="$W/obj" tb_distram_gdn \
    -gOUTFILE=distram_out.txt --stop-time=200ms --max-stack-alloc=0 "$@" 2>&1
echo "GHDL_EXIT=${PIPESTATUS[0]}"
