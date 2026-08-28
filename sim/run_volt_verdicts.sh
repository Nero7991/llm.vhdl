#!/usr/bin/env bash
# Re-measure, at 0.717 V, every unit whose "does it close the clock" verdict was
# decided by a 0.85 V synthesis Fmax against a 0.85 V-era 299.04 MHz target.
# The correct comparison is a 0.717 V Fmax against the MEASURED 237.8 MHz
# (sim/ooc_sweep/results.csv line 7).  See
# docs/2026-08-27_budgets-at-the-measured-clock.md section 7.1 for the list.
#
# Every point re-measures its own default-voltage number in the same run rather
# than quoting the committed one, so a failure to reproduce the published Fmax
# is caught before it is carried into a derate.
#
# Runs on the BC-250.  Sequential on purpose: 15.2 GB of RAM, and these are
# small units, so the wall time is Vivado startup plus synthesis, not memory.
set -u
REPO=${REPO:-/home/orencollaco/GitHub/llama.vhdl}
VOLT=${VOLT:-0.717}
PART=xcvu33p-fsvh2104-2L-e
LOGDIR=$REPO/sim/ooc_micro/voltlogs
mkdir -p "$LOGDIR"
cd "$REPO/sim" || exit 1

run() {  # run <logname> <period> <top> <args...>
  local name=$1; shift
  local period=$1; shift
  local top=$1; shift
  echo "### $(date +%H:%M:%S) $name"
  vivado -mode batch -nojournal -notrace \
    -log "$LOGDIR/$name.log" \
    -source "$REPO/sim/ooc_micro.tcl" \
    -tclargs "$PART" "$period" "$top" "volt=$VOLT" "$@" \
    > "$LOGDIR/$name.stdout" 2>&1
  grep -E '^(MICRO |MICROVOLT|VOLTCHECK)' "$LOGDIR/$name.stdout"
}

PKG="$REPO/rtl/util_pkg.vhd $REPO/rtl/fixed_luts_pkg.vhd $REPO/rtl/fixed_pkg.vhd"

# l2norm_rs.  Published: LANES=4 -> 285.8 MHz at 0.85 V, period 3.333.
for L in 1 2 4; do
  run "l2norm_rs_L$L" 3.333 l2norm_rs g:N=128 g:LANES=$L $PKG "$REPO/rtl/l2norm_rs.vhd"
done

# rmsnorm_rs at C's head_dim.  Published: N=256 LANES=2 and 4 -> 281.8 MHz,
# LANES=1 -> 300.8 MHz, period 3.322.
for L in 1 2 4; do
  run "rmsnorm_rs_N256_L$L" 3.322 rmsnorm_rs g:N=256 g:LANES=$L $PKG "$REPO/rtl/rmsnorm_rs.vhd"
done

# micro_rmsn_lanes.  Published: 278.9 MHz at 1/2/4, 200.9 at 8, period 3.333.
for L in 1 2 4 8; do
  run "micro_rmsn_lanes_L$L" 3.333 micro_rmsn_lanes g:LANES=$L "$REPO/sim/micro/micro_rmsn_lanes.vhd"
done

# gdn_emit_chain across SILU_LANES.  Its own harness, because that table was
# produced with the clock created AFTER synthesis and reproducing the published
# 295.77 / 300.75 / 288.68 / 266.81 requires the same flow.
echo "### $(date +%H:%M:%S) gdn_emit_chain_silu"
vivado -mode batch -nojournal -notrace \
  -log "$LOGDIR/gdn_emit_chain_silu.log" \
  -source "$REPO/sim/ooc_gdn_emit_chain_silu.tcl" \
  -tclargs "$VOLT" 8 16 32 64 \
  > "$LOGDIR/gdn_emit_chain_silu.stdout" 2>&1
grep -E '^(RESULT |RESULTVOLT|VOLTCHECK)' "$LOGDIR/gdn_emit_chain_silu.stdout"

echo "### $(date +%H:%M:%S) ALL_VOLT_VERDICTS_DONE"
