#!/usr/bin/env bash
# TRACK GWTWO -- the object-level BRAM census, one Vivado at a time.
set -u
REPO=/home/orencollaco/GitHub/llama.vhdl
SCR=/home/labuser/gwtwo
IMG=/home/labuser/rmswire/img/norm_w_9b.hex
VIVADO=/tools/Xilinx/2023.2/Vivado/2023.2/bin/vivado
vivado_rss_kib () {
    local s=0 p exe rss
    for p in /proc/[0-9]*; do
        exe=$(readlink -f "$p/exe" 2>/dev/null) || continue
        case "$exe" in */unwrapped/lnx64.o/vivado)
            rss=$(awk '/^VmRSS:/{print $2}' "$p/status" 2>/dev/null); s=$((s+${rss:-0}));; esac
    done
    echo "$s"
}
[ "$(vivado_rss_kib)" -eq 0 ] || { echo "GWTWO_ABORT: Vivado already present"; exit 9; }
for G in "$@"; do
  tag="gw$G"
  echo "== census $tag start $(date -Is) avail=$(free -g | awk '/^Mem:/{print $7}')G"
  GWC_RTL="$SCR/rtl_gw$G" GWC_OUT="$SCR/out" GWC_TAG="$tag" \
  GWC_GEN="NORM_W_IMAGE=$IMG" \
  systemd-run --user --scope --quiet --unit="gwtwo-cen-$tag" \
      -p MemoryHigh=11G -p MemoryAccounting=yes \
      -- "$VIVADO" -mode batch -nojournal -notrace \
           -log "$SCR/out/census_vivado_$tag.log" \
           -source "$REPO/sim/ooc_gwtwo_bramcensus.tcl" \
      > "$SCR/out/census_run_$tag.log" 2>&1
  echo "== census $tag rc=$? $(date -Is)"
  if grep -q "^GWTWO_CENSUS_DONE $tag\$" "$SCR/out/census_run_$tag.log"; then
      echo "SENTINEL OK $tag"
      grep "^GWTWO_CENSUS tag=" "$SCR/out/census_run_$tag.log"
  else
      echo "SENTINEL MISSING $tag -- run did not reach the end"
  fi
done
echo GWTWO_CENSUS_ALL_DONE
