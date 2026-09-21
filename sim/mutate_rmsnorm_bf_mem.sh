#!/usr/bin/env bash
# sim/mutate_rmsnorm_bf_mem.sh -- 2026-09-19.
#
# Teeth for sim/tb_rmsnorm_bf_mem.vhd, WITH the attribution control.
# Modelled on sim/mutate_rmsnorm_rs_mem.sh (TRACK RMSMUX).
#
# For every mutation the bench kills, the same mutant is re-run with the
# VALUE check disabled (CHK_VAL=false), and again with the latency probe
# also off, so the table can say which check earned the kill rather than
# crediting the newest one by default.
#
# Mutations that do NOT bite are reported under their own names and are the
# most valuable rows here: they measure the bench's resolution floor.
#
# NO HARDWARE.  GHDL only.  Never run against the card.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD="${BFMEM_SCRATCH:-/mnt/storage/bfmem/mut}"
mkdir -p "$SD"
SRC="$REPO/rtl/rmsnorm_bf_mem.vhd"
TB="$REPO/sim/tb_rmsnorm_bf_mem.vhd"
DEPS="util_pkg fixed_luts_pkg fixed_pkg vec_mem rmsnorm_bf"

# name|sed program|what it breaks|expected
MUTS=(
"noeps|s@            if mean_smaller then msq_r <= align_r  + M_EPS_C;@            if mean_smaller then msq_r <= align_r;@|the epsilon add dropped on the mean-smaller branch: the unit becomes 1/sqrt(mean) with no floor, i.e. the very defect it exists to fix|BITE"
"noeps_big|s@            else                 msq_r <= m_mean_r + align_r;@            else                 msq_r <= m_mean_r;@|the epsilon add dropped on the eps-smaller branch, which is the branch the x_exp 19 embedding takes (mean = 1.5e-4 against eps 1e-6, a 0.33% gain term)|BITE"
"eout_q|s@            rq_d := rq_p - e_out_r;   -- e_out, NOT Q: msq_r is no@            rq_d := rq_p - Q;   -- MUTANT@|rsqrt exponent divided out against Q instead of e_out (rmsnorm_rs's recipe)|BITE"
"raskew|s@  ram_ra <= std_logic_vector(to_unsigned(idx, AB)) when idx < NB@  ram_ra <= std_logic_vector(to_unsigned(idx + 1, AB)) when idx + 1 < NB@|the element-pass read address advanced by one, i.e. an off-by-one in the RAM read latency the fetch register absorbs|BITE"
"bankswap|s@x_bwe(k) <= x_we when unsigned(x_waddr(LB-1 downto 0)) = k else '0';@x_bwe(k) <= x_we when unsigned(x_waddr(clog2(N)-1 downto clog2(N)-LB)) = k else '0';@|x bank index taken from the HIGH bits of the word index|BITE"
"addroff|s@o_wa <= std_logic_vector(to_unsigned(idx3, AB)) when idx3 < NB@o_wa <= std_logic_vector(to_unsigned(idx3 + 1, AB)) when idx3 + 1 < NB@|output bank write address off by one|BITE"
"selxor|s@o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)),@o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)) xor to_unsigned(1, LB),@|read-side lane select perturbed|BITE"
"wbank|s@w_bwe(k) <= w_we when unsigned(w_waddr(LB-1 downto 0)) = k else '0';@w_bwe(k) <= w_we when unsigned(x_waddr(LB-1 downto 0)) = k else '0';@|w bank enable driven from x_waddr (copy-paste class)|BITE"
"owe_norst|s@o_we <= '1' when (rst = '0' and state = S_EMIT and v3 = '1' and idx3 < NB)@o_we <= '1' when (state = S_EMIT and v3 = '1' and idx3 < NB)@|TRACK WRITEDEC's rst term dropped from the output write guard|UNKNOWN"
# RETIRED 2026-09-20, TRACK GATERED.  `xwswap` -- "x and w exchanged in the
# emit multiply" -- WAS THE IDENTITY, at every geometry, and it was sitting in
# the denominator of this table's kill ratio as though it measured something.
# Found by TRACK MUTWIRE, which observed it survive everywhere; DERIVED here
# from the RTL rather than inferred from the survival, because "survives at
# every geometry" is also what a real fault the bench cannot see looks like:
#
#   rtl/rmsnorm_bf_mem.vhd:408   signal x_q, w_q : s16a
#   s16a is an array of signed(15 downto 0), so BOTH operands are s16, and
#   :935   p1_xinv(k) <= resize(x_q(k) * inv32, 48);   s16*s32 IS 48 bits
#          p1_wm(k)   <= resize(w_q(k), 17);           s16 -> s17 widens
#
# Exchanging x and w gives w*inv*x for x*inv*w.  Multiplication commutes, no
# resize on either path truncates, and the product truncates to the same bits
# either way, so the mutated design is bit-identical to the baseline.  It is
# not a fault that the bench tolerates; it is not a fault.  No check anywhere
# could kill it, so it could never have been re-anchored, only removed.
#
# REPLACED, NOT WEAKENED, by `xwhalf` below: the same site, the same operand
# confusion, but only ONE of the two lines substituted.  A full swap of two
# commuting operands is no fault at all; the HALF swap is the copy-paste slip
# that site is actually exposed to, and it is a strictly harder target than the
# retired row rather than an easier one, because it has to be caught on values.
"xwhalf|s@              p1_xinv(k) <= resize(x_q(k) \* inv32, 48);@              p1_xinv(k) <= resize(w_q(k) * inv32, 48);@|the x operand of the emit multiply replaced by w, so the stage computes w*inv*w for x*inv*w.  The non-degenerate half of the retired xwswap, at the same site|BITE"
"obank_hi|s@               raddr => o_raddr(clog2(N)-1 downto LB),@               raddr => o_raddr(clog2(N)-LB-1 downto 0),@|output READ uses the low bits as the RAM address, i.e. bank and offset transposed on the read side ONLY|BITE"
"doneearly|s@               and v3 = '0' then@               then@|done fires one cycle EARLY.  Values are untouched, because the last bank write is combinational and still lands on the same edge, so this is a SCHEDULE-ONLY fault planted to show the done-cycle check discriminates|BITE"
"transpose_all|s@waddr => x_waddr(clog2(N)-1 downto LB),@waddr => x_waddr(clog2(N)-LB-1 downto 0),@;s@waddr => w_waddr(clog2(N)-1 downto LB),@waddr => w_waddr(clog2(N)-LB-1 downto 0),@;s@x_bwe(k) <= x_we when unsigned(x_waddr(LB-1 downto 0)) = k else '0';@x_bwe(k) <= x_we when unsigned(x_waddr(clog2(N)-1 downto clog2(N)-LB)) = k else '0';@;s@w_bwe(k) <= w_we when unsigned(w_waddr(LB-1 downto 0)) = k else '0';@w_bwe(k) <= w_we when unsigned(w_waddr(clog2(N)-1 downto clog2(N)-LB)) = k else '0';@;s@               raddr => o_raddr(clog2(N)-1 downto LB),@               raddr => o_raddr(clog2(N)-LB-1 downto 0),@;s@o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)),@o_rsel <= std_logic_vector(resize(unsigned(o_raddr(clog2(N)-1 downto clog2(N)-LB)),@|bank and offset transposed CONSISTENTLY on x, w and o|UNKNOWN"
"align_rnd|s@              align_r <= shift_right(m_mean_r, d_r);@              align_r <= shift_right(m_mean_r + shift_left(to_signed(1, 64), d_r - 1), d_r);@|the alignment shift ROUNDS instead of truncating (rmsnorm_bf's header records this as invisible at every Q tested)|UNKNOWN"
)

run() {   # $1 = rtl file  $2 = extra generics  $3 = log
  # A FRESH work directory per run and NO rm: CLAUDE.md forbids a shell
  # variable anywhere in a path passed to rm, and a stale GHDL work library
  # is the trap that a reused directory invites.  The scratch is disposable.
  local wd; wd="$(mktemp -d "$SD/wk.XXXXXX")" || return 9
  ( cd "$wd" || exit 9
    for d in $DEPS; do
      ghdl -a --std=08 -frelaxed --workdir=. "$REPO/rtl/$d.vhd" || exit 9
    done
    ghdl -a --std=08 -frelaxed --workdir=. "$1" || exit 8
    ghdl -a --std=08 -frelaxed --workdir=. "$TB" || exit 8
    # shellcheck disable=SC2086
    ghdl -r --std=08 -frelaxed --workdir=. tb_rmsnorm_bf_mem $2 --stop-time=200ms
  ) > "$3" 2>&1
  echo $?
}

echo "=== rmsnorm_bf_mem mutation table ==="
printf '%-14s %-7s %-7s %-7s %-9s %s\n' MUTANT FULL noVAL noVL+LT VERDICT WHAT
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
    printf '%-14s %-8s %-8s %-8s %s\n' "$name" "-" "-" "NOSUB" "$what"
    fails=$((fails+1)); continue
  fi
  a=$(run "$f" "" "$SD/$name.full.log")
  b=$(run "$f" "-gCHK_VAL=false" "$SD/$name.noval.log")
  # The latency probe matches o_rdata against ONE reference element, so it
  # is a value check in disguise.  The third column turns both off, leaving
  # only the done-cycle comparison and the non-degeneracy gate.
  c=$(run "$f" "-gCHK_VAL=false -gCHK_LAT=false" "$SD/$name.struct.log")
  if [ "$a" != 0 ]; then v=BITE; else v=SURVIVES; fi
  if [ "$exp" != UNKNOWN ] && [ "$v" != "$exp" ]; then v="$v!EXP=$exp"; fails=$((fails+1)); fi
  printf '%-14s %-7s %-7s %-7s %-9s %s\n' "$name" "rc=$a" "rc=$b" "rc=$c" "$v" "$what"
done
echo "=== end.  logs in $SD ==="
echo "NOSUB or an unexpected verdict is a FAILURE of this script: $fails"
exit $(( fails > 0 ))
