#!/usr/bin/env bash
# Teeth for the REAL NORM GAIN path: rtl/llama_top.vhd's NORM_W_IMAGE loader
# and selector, judged by tools/norm_w_bisect.py.
#
# WHY THE JUDGE IS THE ORACLE AND NOT THE BENCH.  `sim/tb_llama_top_normw.vhd`
# has NO value oracle -- it checks that R_X is bit-identical across descriptor
# latencies and prints a hash.  Every mutation below leaves it PASSING with a
# moved hash, which is the whole reason the seam oracle exists.  Both verdicts
# are printed on every row so that difference is visible rather than asserted.
#
# SELF-ISOLATING: a private copy of the tree per mutation, so editing this
# script or the sources while it runs cannot corrupt the run, and no mutation
# ever reaches the repository.
#
# Usage:  bash sim/mutate_normw.sh [scratch-dir]
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
SCRATCH="${1:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

FILES="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
       rtl/model_cfg_pkg.vhd rtl/act_mem_striped.vhd rtl/async_fifo.vhd
       rtl/attn_emit.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd
       rtl/attn_mac_array.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
       rtl/attn_softmax.vhd rtl/axi_rd_fsm.vhd rtl/divider_rs.vhd
       rtl/gdn_conv.vhd rtl/gdn_exp_capture.vhd rtl/gdn_head_emit.vhd
       rtl/gdn_recur_pipe.vhd rtl/gdn_scalar.vhd rtl/gdn_silu.vhd
       rtl/gdn_y_emit.vhd rtl/imrope_pkg.vhd rtl/l2norm_rs.vhd
       rtl/llama_map_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/rmsnorm_bf.vhd
       rtl/rmsnorm_rs.vhd rtl/seq_desc_fetch.vhd rtl/seq_opdec.vhd
       rtl/seq_region_lock.vhd rtl/seq_vec_issue.vhd rtl/seq_vec_res.vhd
       rtl/stream_fifo.vhd sim/seq_tbl_pkg.vhd rtl/attn_recip.vhd
       rtl/attn_twiddle.vhd rtl/axi_rd_port.vhd rtl/gdn_emit_chain.vhd
       rtl/matvec_core.vhd rtl/weight_streamer.vhd sim/llama_sched_pkg.vhd
       rtl/gdn_conv_tap_mem.vhd rtl/gdn_exp_mem.vhd rtl/gdn_state_axi.vhd rtl/gdn_state_mem.vhd
       rtl/attn_block.vhd rtl/attn_kv_axi.vhd rtl/gdn_block.vhd
       rtl/gdn_state_store.vhd rtl/gdn_job_seq.vhd
       rtl/matvec_int4.vhd rtl/sampler_stream.vhd rtl/vec_mem.vhd rtl/rmsnorm_rs_mem.vhd rtl/rmsnorm_bf_mem.vhd
       rtl/llama_top.vhd
       sim/tb_llama_top.vhd"

G="-gBLOCKS=4 -gATTN_INT=4 -gC_REAL=true -gATTN_HD=16
   -gNORM_REAL=true -gNORM_ANCHOR=false -gNRUNS=1
   -gW_IMAGE=llama_top_w_b4_pool.hex
   -gNORM_W_IMAGE=llama_top_nw_b4_mean.hex"

mk () {                              # $1 = name -> prints the dir
  local d="$SCRATCH/$1"
  rm -rf "$d"; mkdir -p "$d/rtl" "$d/sim" "$d/run"
  for f in $FILES; do cp "$REPO/$f" "$d/$f"; done
  cp "$REPO/sim/llama_top_w_b4_pool.hex"  "$d/run/"
  cp "$REPO/sim/llama_top_nw_b4_mean.hex" "$d/run/"
  echo "$d"
}

run_case () {                        # $1 = dir -> prints "<bench> <oracle>"
  local d="$1" w="$1/work" bench oracle
  rm -rf "$w"; mkdir -p "$w"
  for f in $FILES; do
    if ! ghdl -a --std=08 -frelaxed --workdir="$w" "$d/$f" \
         >> "$d/analyze.log" 2>&1; then
      echo "ANALYSIS -"; return
    fi
  done
  # shellcheck disable=SC2086
  ( cd "$d/run" && timeout -k 5 1800 ghdl -r --std=08 -frelaxed \
      --workdir="../work" tb_llama_top $G -gCAPTURE=cap.txt \
      --max-stack-alloc=0 --stop-time=900ms > run.log 2>&1 )
  if grep -qa "RESULT: PASS" "$d/run/run.log"; then bench=PASS; else bench=FAIL; fi
  if [ ! -s "$d/run/cap.txt" ]; then
    echo "$bench NOCAPTURE"; return
  fi
  python3 "$REPO/tools/norm_w_bisect.py" "$d/run/cap.txt" \
      --gains "$REPO/sim/llama_top_nw_b4_mean.hex" > "$d/bisect.log" 2>&1
  oracle=$(grep -o "^# [0-9]* of [0-9]* R_XN seams match the model" "$d/bisect.log" \
           | head -1 | awk '{print $2"/"$4}')
  [ -z "$oracle" ] && oracle="ERROR"
  echo "$bench $oracle"
}

row () { printf "%-4s %-56s bench %-9s R_XN oracle %s\n" "$1" "$2" "$3" "$4"; }

echo "== rtl/llama_top.vhd NORM_W_IMAGE mutation table =="
echo "   'bench' is sim/tb_llama_top_normw's own verdict; 'R_XN oracle' is"
echo "   tools/norm_w_bisect.py, seams matching / seams checked."
echo

d=$(mk n0);  set -- $(run_case "$d"); row M0 "unmutated" "$1" "$2"

# ---- the selector -----------------------------------------------------
d=$(mk n1)
python3 - "$d/rtl/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="          elsif dn = '1' and v_ack(vi) = '1' then\n            if nidx + 1 < NW_N then"
new="          elsif tk = '1' then\n            if nidx + 1 < NW_N then"
assert old in s, "M1 anchor not found"
open(p,'w').write(s.replace(old,new,1))
PY
set -- $(run_case "$d"); row M1 "gain advances at the ACCEPT, not the completion" "$1" "$2"

d=$(mk n2)
python3 - "$d/rtl/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="            r(k)((i+1)*MANT_W-1 downto i*MANT_W) := v;"
new="            r(k)((NN-i)*MANT_W-1 downto (NN-1-i)*MANT_W) := v;"
assert old in s, "M2 anchor not found"
open(p,'w').write(s.replace(old,new,1))
PY
set -- $(run_case "$d"); row M2 "the gain image is loaded element-REVERSED" "$1" "$2"

d=$(mk n3)
python3 - "$d/rtl/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="          wsel <= NW_TBL(nidx);"
new="          wsel <= NW_TBL(0);"
assert old in s, "M3 anchor not found"
open(p,'w').write(s.replace(old,new,1))
PY
set -- $(run_case "$d"); row M3 "every norm uses gain 0 (the index is ignored)" "$1" "$2"

d=$(mk n4)
python3 - "$d/rtl/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="            hread(l, v);"
new="            hread(l, v); v(0) := not v(0);"
assert old in s, "M4 anchor not found"
open(p,'w').write(s.replace(old,new,1))
PY
set -- $(run_case "$d"); row M4 "ONE LSB flipped in every loaded gain element" "$1" "$2"

d=$(mk n5)
python3 - "$d/rtl/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="          if rst = '1' or go = '1' then\n            nidx <= 0;"
new="          if rst = '1' then\n            nidx <= 0;"
assert old in s, "M5 anchor not found"
open(p,'w').write(s.replace(old,new,1))
PY
set -- $(run_case "$d"); row M5 "PREDICTED SURVIVOR: the per-token reset removed" "$1" "$2"

d=$(mk n6)
python3 - "$d/rtl/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="      constant W_CONST : std_logic_vector(NN*MANT_W-1 downto 0) := norm_w_const;"
new="      constant W_CONST : std_logic_vector(NN*MANT_W-1 downto 0) := (others => '0');"
assert old in s, "M6 anchor not found"
open(p,'w').write(s.replace(old,new,1))
PY
set -- $(run_case "$d"); row M6 "PREDICTED SURVIVOR: W_CONST zeroed (image overwrites it)" "$1" "$2"

echo
echo "scratch: $SCRATCH"
