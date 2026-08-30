#!/usr/bin/env bash
# TRACK READCONV teeth-check, 2026-08-29.
#
# Mutates the NEW write decode in rtl/l2norm_rs.vhd and re-runs the
# equivalence bench.  A mutation the bench does not catch is REPORTED UNDER ITS
# OWN NAME, never dropped: it measures the check's resolution floor.
#
# TWO RULES, both learned the expensive way by TRACK WRITEDEC:
#  - An ANALYSIS failure is VOID, never CAUGHT.  WRITEDEC's first version
#    scored all seven mutants CAUGHT because ghdl could not open a file.
#  - The unmutated control must PASS first, or every verdict is meaningless.
#
# usage: run_mutants_l2.sh <workdir>
set -u
REPO=/home/orencollaco/GitHub/llama.vhdl
RES=$REPO/hw/fk33/results/readconv_2026-08-29
WD="${1:?usage: run_mutants_l2.sh <workdir>}"
SRC=$REPO/rtl/l2norm_rs.vhd
NN=128; LL=4

mkdir -p "$WD" || exit 2
cp "$SRC" "$WD/l2norm_rs.orig.vhd" || exit 2

# run one variant: $1 = tag, $2 = path to the l2norm_rs source to use
run_one() {
  local tag="$1" src="$2" d="$WD/run_$1"
  rm -rf "$d"; mkdir -p "$d"; cd "$d" || return 90
  ghdl -a --std=08 --work=work \
    $REPO/rtl/fixed_luts_pkg.vhd $REPO/rtl/fixed_pkg.vhd $REPO/rtl/util_pkg.vhd \
    "$src" $RES/rtl/l2norm_rs_ref.vhd $RES/rtl/tb_readconv_l2.vhd \
    > "$d/analyse.log" 2>&1
  local a=$?
  if [ $a -ne 0 ]; then echo "VOID"; return; fi
  ghdl -r --std=08 --work=work tb_readconv_l2 -gN=$NN -gLANES=$LL \
    --assert-level=error > "$d/run.log" 2>&1
  local r=$?
  if [ $r -eq 0 ] && grep -q 'READCONV OVERALL PASS' "$d/run.log"; then
    echo "PASS"
  else
    echo "FAIL"
  fi
}

echo "== TRACK READCONV mutation table, $(date -Is)"
echo "== bench: tb_readconv_l2, N=$NN LANES=$LL, 16 trials, 15 live"
CTL=$(run_one control "$WD/l2norm_rs.orig.vhd")
echo "control (unmutated)            : $CTL   <- must be PASS or nothing below means anything"
if [ "$CTL" != "PASS" ]; then echo "ABORT: control did not pass"; exit 4; fi

mut() {
  local tag="$1"; shift
  local f="$WD/l2norm_rs.$tag.vhd"
  cp "$WD/l2norm_rs.orig.vhd" "$f"
  python3 - "$f" "$@" <<'PY'
import sys
p=sys.argv[1]; old=sys.argv[2]; new=sys.argv[3]
s=open(p).read()
if s.count(old)!=1:
    sys.stderr.write("MUTATION ANCHOR NOT UNIQUE (%d) for %r\n"%(s.count(old),old)); sys.exit(7)
open(p,'w').write(s.replace(old,new))
PY
  if [ $? -ne 0 ]; then printf '%-30s : %s\n' "$tag" "VOID(anchor)"; return; fi
  local v; v=$(run_one "$tag" "$f")
  local verdict
  case "$v" in
    FAIL) verdict="CAUGHT" ;;
    PASS) verdict="NOT CAUGHT" ;;
    *)    verdict="VOID" ;;
  esac
  printf '%-30s : %s\n' "$tag" "$verdict"
}

# ---- the write decode itself ------------------------------------------------
mut idx_off      'idx1 = wi then' 'idx1 = ((wi+1) mod NB) then'
mut lastword     'gkq : for wi in 0 to NB-1 generate' 'gkq : for wi in 0 to NB-2 generate'
mut no_rst       "if rst = '0' and state = S_EMIT and v1 = '1'" "if state = S_EMIT and v1 = '1'"
mut no_v1        "state = S_EMIT and v1 = '1' and idx1 = wi" "state = S_EMIT and idx1 = wi"
mut no_state     "if rst = '0' and state = S_EMIT and v1 = '1' and idx1 = wi then" "if rst = '0' and v1 = '1' and idx1 = wi then"
mut no_zero      "elsif rst = '0' and state = S_ZERO and idx = wi then" "elsif false then"
mut zero_off     "state = S_ZERO and idx = wi then" "state = S_ZERO and idx = ((wi+1) mod NB) then"
mut kq_swap      '          k_reg((wi+1)*LANES*16-1 downto wi*LANES*16) <= kq_wd_k;
          q_reg((wi+1)*LANES*16-1 downto wi*LANES*16) <= kq_wd_q;' '          k_reg((wi+1)*LANES*16-1 downto wi*LANES*16) <= kq_wd_q;
          q_reg((wi+1)*LANES*16-1 downto wi*LANES*16) <= kq_wd_k;'

# ---- the combinational datum ------------------------------------------------
mut lane_rev     'kq_wd_k((k+1)*16-1 downto k*16)' 'kq_wd_k((LANES-k)*16-1 downto (LANES-1-k)*16)'
mut shk_off      'ok := shift_right(pk(k) + bias_k, sh_k);' 'ok := shift_right(pk(k) + bias_k, sh_k + 1);'
mut nobias_k     'ok := shift_right(pk(k) + bias_k, sh_k);' 'ok := shift_right(pk(k), sh_k);'
mut nobias_q     'oq := shift_right(pq(k) + bias_q, sh_q);' 'oq := shift_right(pq(k), sh_q);'

# ---- the hoisted sat16 ------------------------------------------------------
mut sat_hi       'if    v >  32767 then return to_signed( 32767, 16);' 'if    v >  32767 then return to_signed( 32766, 16);'
mut sat_lo       'elsif v < -32768 then return to_signed(-32768, 16);' 'elsif v < -32768 then return to_signed(-32767, 16);'

echo "== end"
