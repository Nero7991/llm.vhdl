#!/usr/bin/env bash
# sim/mutate_swiglu_mem.sh -- 2026-09-19.
#
# Teeth for sim/tb_swiglu_mem.vhd, WITH the attribution control.
# Modelled on sim/mutate_rmsnorm_bf_mem.sh.
#
# For every mutation the bench kills, the same mutant is re-run with the
# VALUE check disabled (CHK_VAL=false), and again with the exponent check
# also off, so the table can say which check earned the kill rather than
# crediting the newest one by default.
#
# Mutations that do NOT bite are reported under their own names and are the
# most valuable rows here: they measure the bench's resolution floor.
#
# NO HARDWARE.  GHDL only.  Never run against the card.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD="${SWGMEM_SCRATCH:-/mnt/storage/swgmem/mut}"
mkdir -p "$SD"
SRC="$REPO/rtl/swiglu_mem.vhd"
TB="$REPO/sim/tb_swiglu_mem.vhd"
DEPS="util_pkg fixed_luts_pkg fixed_pkg vec_mem swiglu bfp_pack"

# name|sed program|what it breaks|expected
MUTS=(
"nosig|s@          b_sig <= sigmoid_q(a_vq, Q);@          b_sig <= to_signed(4096, 32);@|the sigmoid dropped: sig = 1.0, so out = g*u in Q12 -- the stand-in this unit replaces, at the unit's own grid|BITE"
"packrnd|s@                r34    := shift_right(r34 + bias34, shift_o);@                r34    := shift_right(r34, shift_o);@|the pack TRUNCATES instead of rounding half up (bfp_pack's rule dropped)|BITE"
"raskew|s@  ram_ra <= std_logic_vector(to_unsigned(idx, LOG2N)) when idx < N@  ram_ra <= std_logic_vector(to_unsigned(idx + 1, LOG2N)) when idx + 1 < N@|the input-bank read address advanced by one: the read latency the valid chain absorbs is off by one element|BITE"
"convrnd|s@        bias64 := shift_left(to_signed(1, 64), cr - 1);@        bias64 := (others => '0');@|the Qq conversion TRUNCATES instead of rounding half up for exp > Q (swiglu.vhd's S_CALC_A bias dropped)|BITE"
"opswap|s@          a_vq <= to_qq(signed(g_bq), Q - ge);@          a_vq <= to_qq(signed(u_bq), Q - ge);@;s@          a_hq <= to_qq(signed(u_bq), Q - ue);@          a_hq <= to_qq(signed(g_bq), Q - ue);@|g and u exchanged: silu(u)*g instead of silu(g)*u|BITE"
"expswap|s@              ge <= g_exp; ue <= u_exp;@              ge <= u_exp; ue <= g_exp;@|the two latched exponents exchanged|BITE"
"oexpsign|s@              o_exp    <= Q - sh;@              o_exp    <= Q + sh;@|the published exponent has the shift with the wrong sign (value = mant * 2^-exp convention broken)|BITE"
"silush|s@          c_silu <= resize(shift_right(prod1, Q), 32);@          c_silu <= resize(shift_right(prod1, Q - 1), 32);@|the silu product shifted by Q-1: silu doubled|BITE"
"nodrain|s@                    and vd = '0');@                    and true);@|the drain test ignores stage D, so the shift is computed on the edge the LAST element's fold lands and that element is excluded from max_abs.  Bites only when the max is element N-1|UNKNOWN"
"nosat|s@              elsif r34 < to_signed(-32768, 34) then@              elsif r34 < to_signed(-32768, 34) and false then@;s@              if    r34 > to_signed( 32767, 34) then@              if    r34 > to_signed( 32767, 34) and false then@|the pack saturation dropped: only a mantissa that rounds up to exactly 32768 (or wraps below -32768) can show it|UNKNOWN"
"doneearly|s@            if o_we = '1' and unsigned(o_wa) = N-1 then@            if vd = '1' and widx = N-1 then@|done fires one cycle EARLY, before the last word lands.  The bench reads the output long after done and cannot see this; planted to measure that floor|UNKNOWN"
"wrot|s@              o_wa <= std_logic_vector(to_unsigned(widx, LOG2N));@              o_wa <= std_logic_vector(to_unsigned((widx + 1) mod N, LOG2N));@|every output word written one address late (a rotation by one), and done fires one word early as a consequence|BITE"
)

run() {   # $1 = rtl file  $2 = extra generics  $3 = log
  local wd; wd="$(mktemp -d "$SD/wk.XXXXXX")" || return 9
  ( cd "$wd" || exit 9
    for d in $DEPS; do
      ghdl -a --std=08 -frelaxed --workdir=. "$REPO/rtl/$d.vhd" || exit 9
    done
    ghdl -a --std=08 -frelaxed --workdir=. "$1" || exit 8
    ghdl -a --std=08 -frelaxed --workdir=. "$TB" || exit 8
    # shellcheck disable=SC2086
    ghdl -r --std=08 -frelaxed --workdir=. tb_swiglu_mem $2 --stop-time=200ms
  ) > "$3" 2>&1
  echo $?
}

echo "=== swiglu_mem mutation table ==="
printf '%-10s %-7s %-7s %-7s %-7s %-9s %s\n' MUTANT FULL noVAL noVL+EX noALL VERDICT WHAT
BASE=$(run "$SRC" "" "$SD/base.log")
if [ "$BASE" != 0 ]; then
  echo "BASELINE FAILED (rc=$BASE); see $SD/base.log"; exit 1
fi
echo "baseline rc=0 :: $(grep -o 'checks=.*' "$SD/base.log")"

fails=0
for m in "${MUTS[@]}"; do
  IFS='|' read -r name prog what exp <<< "$m"
  f="$SD/$name.vhd"
  sed -e "$(printf '%b' "$prog")" "$SRC" > "$f"
  if cmp -s "$f" "$SRC"; then
    printf '%-10s %-8s %-8s %-8s %-8s %s\n' "$name" "-" "-" "-" "NOSUB" "$what"
    fails=$((fails+1)); continue
  fi
  a=$(run "$f" "" "$SD/$name.full.log")
  b=$(run "$f" "-gCHK_VAL=false" "$SD/$name.noval.log")
  # The third column turns the exponent check off as well, leaving only the
  # latency probe (which matches ONE reference element, so it is a value
  # check in disguise) and the non-degeneracy gate.
  c=$(run "$f" "-gCHK_VAL=false -gCHK_EXP=false" "$SD/$name.struct.log")
  # The fourth column turns the latency probe off too: only the non-degeneracy
  # gate and "a unit never asserted done" remain.  A mutant that still fails
  # here was killed by something other than a check this bench credits.
  d=$(run "$f" "-gCHK_VAL=false -gCHK_EXP=false -gCHK_LAT=false" "$SD/$name.none.log")
  if [ "$a" != 0 ]; then v=BITE; else v=SURVIVES; fi
  if [ "$exp" != UNKNOWN ] && [ "$v" != "$exp" ]; then v="$v!EXP=$exp"; fails=$((fails+1)); fi
  printf '%-10s %-7s %-7s %-7s %-7s %-9s %s\n' "$name" "rc=$a" "rc=$b" "rc=$c" "rc=$d" "$v" "$what"
done
echo "=== end.  logs in $SD ==="
echo "NOSUB or an unexpected verdict is a FAILURE of this script: $fails"
exit $(( fails > 0 ))
