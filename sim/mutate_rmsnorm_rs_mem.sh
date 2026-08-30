#!/usr/bin/env bash
# sim/mutate_rmsnorm_rs_mem.sh -- TRACK RMSMUX, 2026-08-30.
#
# Teeth for sim/tb_rmsnorm_rs_mem.vhd, WITH the attribution control.
#
# For every mutation the bench kills, the same mutant is re-run with the
# VALUE check disabled (CHK_VAL=false), so the table can say which check
# earned the kill rather than crediting the newest one by default.  TRACK
# LEVERC's control denied credit for thirteen of fifteen apparent detections;
# a kill with no control behind it is not evidence about the check.
#
# Mutations that do NOT bite are reported under their own names and are the
# most valuable rows here: they measure the bench's resolution floor.
#
# NO HARDWARE.  GHDL only.  Never run against the card.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD="${RMSMUX_SCRATCH:-/mnt/storage/rmsmux/mut}"
mkdir -p "$SD"
SRC="$REPO/rtl/rmsnorm_rs_mem.vhd"
TB="$REPO/sim/tb_rmsnorm_rs_mem.vhd"
DEPS="util_pkg fixed_luts_pkg fixed_pkg vec_mem rmsnorm rmsnorm_rs"

# name|sed program|what it breaks|expected
MUTS=(
"bankswap|s@x_bwe(k) <= x_we when unsigned(x_waddr(LB-1 downto 0)) = k else '0';@x_bwe(k) <= x_we when unsigned(x_waddr(clog2(N)-1 downto clog2(N)-LB)) = k else '0';@|x bank index taken from the HIGH bits of the word index|BITE"
"addroff|s@o_wa <= std_logic_vector(to_unsigned(idx3, AB)) when idx3 < NB@o_wa <= std_logic_vector(to_unsigned(idx3 + 1, AB)) when idx3 + 1 < NB@|output bank write address off by one|BITE"
"selxor|s@o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)),@o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)) xor to_unsigned(1, LB),@|read-side lane select perturbed|BITE"
"raskew|s@  ram_ra <= std_logic_vector(to_unsigned(idx, AB)) when idx < NB@  ram_ra <= std_logic_vector(to_unsigned(idx + 1, AB)) when idx + 1 < NB@|the element-pass read address advanced by one, i.e. the fetch register absorbing a DIFFERENT amount of latency than the one cycle the RAM has|BITE"
"wbank|s@w_bwe(k) <= w_we when unsigned(w_waddr(LB-1 downto 0)) = k else '0';@w_bwe(k) <= w_we when unsigned(x_waddr(LB-1 downto 0)) = k else '0';@|w bank enable driven from x_waddr (copy-paste class)|BITE"
"owe_norst|s@o_we <= '1' when (rst = '0' and state = S_EMIT and v3 = '1' and idx3 < NB)@o_we <= '1' when (state = S_EMIT and v3 = '1' and idx3 < NB)@|TRACK WRITEDEC's rst term dropped from the output write guard|UNKNOWN"
"xwswap|s@              p1_xinv(k) <= resize(x_q(k) \* inv32, 48);@              p1_xinv(k) <= resize(w_q(k) * inv32, 48);@;s@              p1_wm(k)   <= resize(w_q(k), 17);@              p1_wm(k)   <= resize(x_q(k), 17);@|x and w exchanged in the emit multiply|UNKNOWN"
"obank_hi|s@               raddr => o_raddr(clog2(N)-1 downto LB),@               raddr => o_raddr(clog2(N)-LB-1 downto 0),@|output READ uses the low bits as the RAM address, i.e. bank and offset transposed on the read side ONLY|BITE"
"doneearly|s@ and v3 = .0. then@ then@|done fires one cycle EARLY.  Values are untouched, because the last bank write is combinational and still lands on the same edge, so this is a SCHEDULE-ONLY fault planted to show the done-cycle check discriminates|BITE"
"transpose_all|s@waddr => x_waddr(clog2(N)-1 downto LB),@waddr => x_waddr(clog2(N)-LB-1 downto 0),@;s@waddr => w_waddr(clog2(N)-1 downto LB),@waddr => w_waddr(clog2(N)-LB-1 downto 0),@;s@x_bwe(k) <= x_we when unsigned(x_waddr(LB-1 downto 0)) = k else '0';@x_bwe(k) <= x_we when unsigned(x_waddr(clog2(N)-1 downto clog2(N)-LB)) = k else '0';@;s@w_bwe(k) <= w_we when unsigned(w_waddr(LB-1 downto 0)) = k else '0';@w_bwe(k) <= w_we when unsigned(w_waddr(clog2(N)-1 downto clog2(N)-LB)) = k else '0';@;s@               raddr => o_raddr(clog2(N)-1 downto LB),@               raddr => o_raddr(clog2(N)-LB-1 downto 0),@;s@o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)),@o_rsel <= std_logic_vector(resize(unsigned(o_raddr(clog2(N)-1 downto clog2(N)-LB)),@|bank and offset transposed CONSISTENTLY on x, w and o|UNKNOWN"
)

run() {   # $1 = rtl file  $2 = extra generics  $3 = log
  local wd; wd="$SD/wk"
  rm -rf "$SD/wk"; mkdir -p "$SD/wk"
  ( cd "$wd" || exit 9
    for d in $DEPS; do
      ghdl -a --std=08 --workdir=. "$REPO/rtl/$d.vhd" || exit 9
    done
    ghdl -a --std=08 --workdir=. "$1" || exit 8
    ghdl -a --std=08 --workdir=. "$TB" || exit 8
    # shellcheck disable=SC2086
    ghdl -r --std=08 --workdir=. tb_rmsnorm_rs_mem $2 --stop-time=200ms
  ) > "$3" 2>&1
  echo $?
}

echo "=== RMSMUX mutation table ==="
printf '%-14s %-7s %-7s %-7s %-9s %s\n' MUTANT FULL noVAL noVL+LT VERDICT WHAT
BASE=$(run "$SRC" "" "$SD/base.log")
if [ "$BASE" != 0 ]; then
  echo "BASELINE FAILED (rc=$BASE); see $SD/base.log"; exit 1
fi
echo "baseline rc=0 :: $(grep -o 'SUMMARY.*' "$SD/base.log")"

fails=0
for m in "${MUTS[@]}"; do
  IFS='|' read -r name prog what exp <<< "$m"
  f="$SD/$name.vhd"
  sed -e "$(printf '%b' "$prog")" "$SRC" > "$f"
  if cmp -s "$f" "$SRC"; then
    printf '%-14s %-8s %-8s %-8s %s\n' "$name" "-" "-" "NOSUB" "$what"
    fails=$((fails+1)); continue
  fi
  a=$(run "$f" "" "$SD/$name.full.log")
  b=$(run "$f" "-gCHK_VAL=false" "$SD/$name.noval.log")
  # The latency probe matches o_rdata against ONE golden element, so it is a
  # value check in disguise: with CHK_VAL off it still killed bankswap and
  # addroff.  The third column turns both off, leaving only the done-cycle
  # comparison and the non-degeneracy gate -- the genuinely structural checks.
  c=$(run "$f" "-gCHK_VAL=false -gCHK_LAT=false" "$SD/$name.struct.log")
  if [ "$a" != 0 ]; then v=BITE; else v=SURVIVES; fi
  if [ "$exp" != UNKNOWN ] && [ "$v" != "$exp" ]; then v="$v!EXP=$exp"; fails=$((fails+1)); fi
  printf '%-14s %-7s %-7s %-7s %-9s %s\n' "$name" "rc=$a" "rc=$b" "rc=$c" "$v" "$what"
done
echo "=== end.  logs in $SD ==="
echo "NOSUB or an unexpected verdict is a FAILURE of this script: $fails"
exit $(( fails > 0 ))
