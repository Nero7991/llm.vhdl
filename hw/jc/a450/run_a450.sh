#!/usr/bin/env bash
# hw/jc/a450/run_a450.sh -- run the a450 A+HBM timing design (build_a450.tcl) once, capped.
#
#   run_a450.sh [--dry-run] [--directives explore|default] [--overconstrain-ns <ns>] <root>
#
# --overconstrain-ns <ns> (a450 Task 7b fix round 1): time aclk_a's setup paths as if its
# period were <ns> (e.g. 2.15), by adding (2.222 - <ns>) of setup uncertainty on aclk_a ->
# aclk_a.  A margin measurement, not the gate: the slack it prints is the slack against
# <ns>.  The one-period CDC bounds and their read-back keep the real period.
#
# --directives explore (THE DEFAULT since Task 7b fix round 2): opt_design -directive
# ExploreWithRemap, place_design -directive ExtraTimingOpt, phys_opt_design -directive
# AggressiveExplore (after place and again after route), route_design -directive
# AggressiveExplore.  --directives default: Vivado's default directives, as every run
# before Task 7b group E.  Why explore is the default (MEASURED, same RTL, HEAD e0f86c57):
# a450_hbm_7b_r4 with default directives routed aclk_a at -0.146 ns (1,697 failing
# endpoints); a450_hbm_7b_r5 with explore met 2.15 ns at +0.010 (+0.082 at 2.222 DERIVED).
# Default directives land either side of zero on this design (r2 0.000, r4 -0.146).
#
# <root> must be a fresh directory under /mnt/storage/fk33_builds/ (never /tmp).  The
# TRACKED tree at HEAD is copied to <root>/src (git archive), so the run is reproducible
# from the commit.  Refuses if another Vivado runs (by /proc/PID/exe, never by command
# line) or if MemAvailable is below the cap plus 2 GiB.  Vivado runs under
# hw/jc/loader/run_capped.sh: MemoryHigh 24G, killed if its swap passes 8 GiB.
# The availability floor defaults to the cap plus 2 GiB; A450_MIN_AVAIL_GIB=<n> lowers it
# for a run the dispatcher has budgeted against the box (the value used is printed).
# The verdict is read from Vivado's own log: ^A450HBM_DONE after this run's nonce, then
# the A450HBM_WNS_ACLK value, gated also on A450HBM_WNS_CORE >= 0, A450HBM_WHS >= 0 and
# no ^A450HBM_CHECK_FAIL line.  Prints A450RUN_PASS <wns>, A450RUN_TIMING_FAIL <wns> or
# A450RUN_FAIL <reason>.  No hardware access of any kind.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
DIRS=explore
if [ "${1:-}" = "--directives" ]; then
  case "${2:-}" in explore|default) DIRS=$2 ;; *) echo "A450RUN_FAIL --directives takes: explore or default"; exit 1 ;; esac
  shift 2
fi
OC=none
if [ "${1:-}" = "--overconstrain-ns" ]; then
  echo "${2:-}" | grep -qE '^[0-9]+\.[0-9]+$' || { echo "A450RUN_FAIL --overconstrain-ns takes a period in ns, e.g. 2.15"; exit 1; }
  OC=$2; shift 2
fi
ROOT=${1:-}
fail() { echo "A450RUN_FAIL $1"; exit 1; }
[ -n "$ROOT" ] || fail "usage: $0 [--dry-run] <root>"
case "$ROOT" in /mnt/storage/fk33_builds/*) ;; *) fail "root $ROOT is not under /mnt/storage/fk33_builds/" ;; esac
if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then fail "root $ROOT exists and is not empty"; fi
MEM_HIGH=24G
SWAP_KILL=8589934592
NONCE="a450hbm_$(date +%s)_$$"
MEMAVAIL=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo)
if [ -n "${A450_MIN_AVAIL_GIB:-}" ]; then
  case "$A450_MIN_AVAIL_GIB" in *[!0-9]*|'') fail "A450_MIN_AVAIL_GIB must be a whole number of GiB" ;; esac
  MIN_AVAIL=$(( A450_MIN_AVAIL_GIB * 1073741824 ))
else
  MIN_AVAIL=$(( $(numfmt --from=iec $MEM_HIGH) + 2147483648 ))
fi
echo "A450RUN_BUDGET MemAvailable=$MEMAVAIL min_avail=$MIN_AVAIL cap=$MEM_HIGH swap_kill=$SWAP_KILL nonce=$NONCE directives=$DIRS overconstrain=$OC"
VIVADO_BIN=$(command -v vivado 2>/dev/null || true)
if [ "$DRY" = 1 ]; then
  echo "+ git -C $REPO archive HEAD | tar -x -C $ROOT/src"
  echo "+ bash $REPO/hw/jc/loader/run_capped.sh $NONCE $MEM_HIGH $SWAP_KILL $ROOT ${VIVADO_BIN:-vivado} -mode batch -nojournal -log $ROOT/build.log -source $ROOT/src/hw/jc/a450/build_a450.tcl -tclargs $ROOT/src $ROOT/proj -nonce $NONCE -directives $DIRS -overconstrain $OC"
  echo "A450RUN_DRY"
  exit 0
fi
[ -n "$VIVADO_BIN" ] || fail "vivado is not on PATH (source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh)"
[ "$MEMAVAIL" -ge "$MIN_AVAIL" ] \
  || fail "MemAvailable $MEMAVAIL is below $MIN_AVAIL (stop llama-server first: Oren's call)"
for p in /proc/[0-9]*; do
  e=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$e" in */unwrapped/lnx64.o/vivado*) fail "another Vivado is running (${p#/proc/}): one per box" ;; esac
done
mkdir -p "$ROOT/src" || fail "mkdir $ROOT/src"
git -C "$REPO" archive HEAD | tar -x -C "$ROOT/src" || fail "git archive"
bash "$REPO/hw/jc/loader/run_capped.sh" "$NONCE" "$MEM_HIGH" "$SWAP_KILL" "$ROOT" \
  "$VIVADO_BIN" -mode batch -nojournal -log "$ROOT/build.log" \
  -source "$ROOT/src/hw/jc/a450/build_a450.tcl" -tclargs "$ROOT/src" "$ROOT/proj" -nonce "$NONCE" -directives "$DIRS" -overconstrain "$OC"
NL=$(grep -nE "^A450HBM_NONCE ${NONCE}\$" "$ROOT/build.log" | head -1 | cut -d: -f1)
DL=$(grep -nE '^A450HBM_DONE' "$ROOT/build.log" | tail -1 | cut -d: -f1)
if [ -z "$NL" ] || [ -z "$DL" ] || [ "$DL" -le "$NL" ]; then
  R=$(grep -E '^A450HBM_FAIL' "$ROOT/build.log" | tail -1)
  fail "${R:-no A450HBM_DONE after the nonce of this run (see $ROOT/build.log and the swap guard log)}"
fi
W=$(grep -E '^A450HBM_WNS_ACLK ' "$ROOT/build.log" | tail -1 | awk '{print $2}')
WC=$(grep -E '^A450HBM_WNS_CORE ' "$ROOT/build.log" | tail -1 | awk '{print $2}')
WH=$(grep -E '^A450HBM_WHS ' "$ROOT/build.log" | tail -1 | awk '{print $2}')
num() { echo "$1" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; }
num "$W" && num "$WC" && num "$WH" || fail "unparsed timing: WNS_ACLK '$W' WNS_CORE '$WC' WHS '$WH'"
CF=$(grep -cE '^A450HBM_CHECK_FAIL' "$ROOT/build.log")
if [ "$CF" -gt 0 ]; then
  fail "$CF post-route check(s) failed, WNS_ACLK $W: $(grep -E '^A450HBM_CHECK_FAIL' "$ROOT/build.log" | head -1)"
fi
if awk -v w="$W" -v c="$WC" -v h="$WH" 'BEGIN { exit !(w >= 0 && c >= 0 && h >= 0) }'; then
  echo "A450RUN_PASS $W"
else
  echo "A450RUN_TIMING_FAIL $W (WNS_CORE $WC, WHS $WH)"
fi
