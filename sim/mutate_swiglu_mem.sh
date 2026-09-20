#!/usr/bin/env bash
# sim/mutate_swiglu_mem.sh -- 2026-09-19; LANES axis added 2026-09-20 (SWGFAST).
#
# Teeth for sim/tb_swiglu_mem.vhd, WITH the attribution control.
# Modelled on sim/mutate_rmsnorm_bf_mem.sh.
#
# For every mutation the bench kills, the same mutant is re-run with the
# VALUE check disabled (CHK_VAL=false), and again with the exponent check
# also off, so the table can say which check earned the kill rather than
# crediting the newest one by default.
#
# EVERY ROW RUNS AT EACH LANES IN $SWGMEM_LANES (default "1 2 4"), because
# rtl/swiglu_mem.vhd's LANES generic elaborates DIFFERENT STRUCTURE: at
# LANES = 1 there is no bank decode, no read select and no S_MAX state, so
# a mutation of those lines is a no-op there and its "SURVIVES" at LANES = 1
# is the resolution floor of that configuration, not a missing check.  The
# expectation column says which: BITE = bite at every LANES, L1SURV = a
# no-op at LANES = 1 and a bite above it, UNKNOWN = planted to measure.
#
# Mutations that do NOT bite are reported under their own names and are the
# most valuable rows here: they measure the bench's resolution floor.
#
# NO HARDWARE.  GHDL only.  Never run against the card.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD="${SWGMEM_SCRATCH:-/mnt/storage/swgmem/mut}"
LANES_LIST="${SWGMEM_LANES:-1 2 4}"
mkdir -p "$SD"
SRC="$REPO/rtl/swiglu_mem.vhd"
TB="$REPO/sim/tb_swiglu_mem.vhd"
DEPS="util_pkg fixed_luts_pkg fixed_pkg vec_mem swiglu bfp_pack"

# name|sed program|what it breaks|expected
MUTS=(
"nosig|s@            b_sig(l) <= sigmoid_q(a_vq(l), Q);@            b_sig(l) <= to_signed(4096, 32);@|the sigmoid dropped: sig = 1.0, so out = g*u in Q12 -- the stand-in this unit replaces, at the unit's own grid|BITE"
"packrnd|s@                  r34    := shift_right(r34 + bias34, shift_o);@                  r34    := shift_right(r34, shift_o);@|the pack TRUNCATES instead of rounding half up (bfp_pack's rule dropped)|BITE"
"raskew|s@  ram_ra <= std_logic_vector(to_unsigned(idx, AB)) when idx < NB@  ram_ra <= std_logic_vector(to_unsigned(idx + 1, AB)) when idx + 1 < NB@|the input-bank read address advanced by one beat: the read latency the valid chain absorbs is off by one element (LANES elements above 1)|BITE"
"convrnd|s@        bias64 := shift_left(to_signed(1, 64), cr - 1);@        bias64 := (others => '0');@|the Qq conversion TRUNCATES instead of rounding half up for exp > Q (swiglu.vhd's S_CALC_A bias dropped)|BITE"
"opswap|s@            a_vq(l) <= to_qq(signed(g_bq(l)), Q - ge);@            a_vq(l) <= to_qq(signed(u_bq(l)), Q - ge);@;s@            a_hq(l) <= to_qq(signed(u_bq(l)), Q - ue);@            a_hq(l) <= to_qq(signed(g_bq(l)), Q - ue);@|g and u exchanged: silu(u)*g instead of silu(g)*u|BITE"
"expswap|s@              ge <= g_exp; ue <= u_exp;@              ge <= u_exp; ue <= g_exp;@|the two latched exponents exchanged|BITE"
"oexpsign|s@      o_exp    <= Q - s;@      o_exp    <= Q + s;@|the published exponent has the shift with the wrong sign (value = mant * 2^-exp convention broken)|BITE"
"silush|s@            c_silu(l) <= resize(shift_right(prod1, Q), 32);@            c_silu(l) <= resize(shift_right(prod1, Q - 1), 32);@|the silu product shifted by Q-1: silu doubled|BITE"
"nodrain|s@                    and vd = '0');@                    and true);@|the drain test ignores stage D, so the shift is computed on the edge the LAST beat's fold lands and that beat is excluded from the max.  Bites only when the max is in the last beat (trial one_big_last, added 2026-09-20; it SURVIVED before that)|BITE"
"nosat|s@                elsif r34 < to_signed(-32768, 34) then@                elsif r34 < to_signed(-32768, 34) and false then@;s@                if    r34 > to_signed( 32767, 34) then@                if    r34 > to_signed( 32767, 34) and false then@|the pack saturation dropped: only a mantissa that rounds up to exactly 32768 (or wraps below -32768) can show it|UNKNOWN"
"doneearly|s@            if o_we = '1' and unsigned(o_wa) = NB-1 then@            if vd = '1' and widx = NB-1 then@|done fires one cycle EARLY, before the last word lands.  The bench reads the output long after done and cannot see this; planted to measure that floor|UNKNOWN"
"wrot|s@              o_wa <= std_logic_vector(to_unsigned(widx, AB));@              o_wa <= std_logic_vector(to_unsigned((widx + 1) mod NB, AB));@|every output beat written one address late (a rotation by one beat), and done fires one beat early as a consequence|BITE"
"bankdec|s@      g_bwe(k) <= g_we when unsigned(g_waddr(LB-1 downto 0)) = k else '0';@      g_bwe(k) <= g_we when unsigned(g_waddr(LB-1 downto 0)) = (k + 1) mod LANES else '0';@|SWGFAST: the g write decode sends element i to bank (i+1) mod LANES, so lane l pairs g(i+1) with u(i).  A no-op at LANES = 1 (the line is not elaborated)|L1SURV"
"rselskew|s@        o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)),@        o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)) + 1,@|SWGFAST: the read-out lane select off by one: word i is read from bank (i+1) mod LANES.  A no-op at LANES = 1|L1SURV"
"bankswap|s@      g_bwe(k) <= g_we when unsigned(g_waddr(LB-1 downto 0)) = k else '0';@      g_bwe(k) <= g_we when unsigned(g_waddr(LOG2N-1 downto AB)) = k else '0';@;s@               waddr => g_waddr(LOG2N-1 downto LB), raddr => ram_ra,@               waddr => g_waddr(AB-1 downto 0), raddr => ram_ra,@|SWGFAST: the g bank/offset split EXCHANGED -- the HIGH LB bits of the write address pick the bank and the low AB bits are the offset, so g word i lands in bank (i / NB) at offset (i mod NB) instead of bank (i mod LANES) at offset (i / LANES).  The off-by-one decode is the bankdec row; this is the swap.  A no-op at LANES = 1, where the decode line is not elaborated and the two slices are the same bits|L1SURV"
"lanemax|s@      if a(l) > m then m := a(l); end if;@      if l > 0 and a(l) > m then m := a(l); end if;@|SWGFAST: the lane-max combine ignores lane 0, so the pack shift is wrong whenever the max element has an even index.  A no-op at LANES = 1 (max_of is not called)|L1SURV"
"p1lane|s@                if av_u > lmax(l) then lmax(l) <= av_u; end if;@                if av_u > lmax(l) then lmax(0) <= av_u; end if;@|SWGFAST: every lane's pass-1 fold lands in lane 0's register, so lanes above 0 stay at zero and a lane-0 element that is smaller than a later lane's overwrites it.  Identity at LANES = 1|L1SURV"
"wdlane|s@                o_wd(l) <= std_logic_vector(mant16);@                o_wd((l + 1) mod LANES) <= std_logic_vector(mant16);@|SWGFAST: pass 2 writes lane l's packed word into bank (l+1) mod LANES: elements rotate within each beat.  Identity at LANES = 1|L1SURV"
"smaxskip|s@                max_abs <= max_of(lmax);@                max_abs <= lmax(LANES-1);@|SWGFAST: S_MAX settles on the LAST lane's max alone.  A no-op at LANES = 1|L1SURV"
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

echo "=== swiglu_mem mutation table (LANES in: $LANES_LIST) ==="
printf '%-10s %-3s %-7s %-7s %-7s %-7s %-9s %s\n' MUTANT L FULL noVAL noVL+EX noALL VERDICT WHAT
for L in $LANES_LIST; do
  BASE=$(run "$SRC" "-gLANES=$L" "$SD/base.L$L.log")
  if [ "$BASE" != 0 ]; then
    echo "BASELINE FAILED at LANES=$L (rc=$BASE); see $SD/base.L$L.log"; exit 1
  fi
  echo "baseline LANES=$L rc=0 :: $(grep -o 'checks=.*' "$SD/base.L$L.log") :: $(grep -o 'SWGFAST_CYCLES [0-9]*' "$SD/base.L$L.log")"
done

fails=0
for m in "${MUTS[@]}"; do
  IFS='|' read -r name prog what exp <<< "$m"
  f="$SD/$name.vhd"
  sed -e "$(printf '%b' "$prog")" "$SRC" > "$f"
  if cmp -s "$f" "$SRC"; then
    printf '%-10s %-3s %-8s %-8s %-8s %-8s %s\n' "$name" "-" "-" "-" "-" "NOSUB" "$what"
    fails=$((fails+1)); continue
  fi
  for L in $LANES_LIST; do
    G="-gLANES=$L"
    a=$(run "$f" "$G" "$SD/$name.L$L.full.log")
    b=$(run "$f" "$G -gCHK_VAL=false" "$SD/$name.L$L.noval.log")
    # The third column turns the exponent check off as well, leaving only the
    # latency probe (which matches ONE reference element, so it is a value
    # check in disguise) and the non-degeneracy gate.
    c=$(run "$f" "$G -gCHK_VAL=false -gCHK_EXP=false" "$SD/$name.L$L.struct.log")
    # The fourth column turns the latency probe off too: only the
    # non-degeneracy gate and "a unit never asserted done" remain.  A mutant
    # that still fails here was killed by something other than a check this
    # bench credits.
    d=$(run "$f" "$G -gCHK_VAL=false -gCHK_EXP=false -gCHK_LAT=false" "$SD/$name.L$L.none.log")
    if [ "$a" != 0 ]; then v=BITE; else v=SURVIVES; fi
    case "$exp" in
      BITE)   want=BITE ;;
      L1SURV) if [ "$L" = 1 ]; then want=SURVIVES; else want=BITE; fi ;;
      *)      want= ;;
    esac
    if [ -n "$want" ] && [ "$v" != "$want" ]; then v="$v!EXP=$want"; fails=$((fails+1)); fi
    printf '%-10s %-3s %-7s %-7s %-7s %-7s %-9s %s\n' "$name" "$L" "rc=$a" "rc=$b" "rc=$c" "rc=$d" "$v" "$what"
  done
done
echo "=== end.  logs in $SD ==="
echo "NOSUB or an unexpected verdict is a FAILURE of this script: $fails"
exit $(( fails > 0 ))
