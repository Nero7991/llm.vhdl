#!/usr/bin/env bash
# sim/elab9b_run.sh -- TRACK REALSHAPE, 2026-08-29.
#
# ELABORATE THE COMPOSED TOP LEVEL AT THE REAL 9B SHAPE.
#
# WHY THIS EXISTS.  Every composition measurement in this repository is at
# `mk_shape_scaled` -- hidden 64, ffn 128, one or two attention heads.  The
# real shape, `mk_shape(MODEL, NCARDS)` with hidden 4096 and ffn 12288, is
# `rtl/llama_top.vhd`'s own DEFAULT generic and had never been elaborated in
# any simulator.  The first full-shape elaboration was scheduled to happen
# inside Vivado, on the critical path, where the diagnostics are worse and the
# turnaround is hours rather than seconds.
#
# ELABORATING IS NOT COMPUTING.  Nothing here checks a value.  What it checks
# is that every generic, array bound, index expression and integer range is
# legal at the true dimensions -- which is the defect class this project's own
# record is full of (OI-7, OI-8, OI-10, and TRACK ORDINAL's `c_layer = -1`).
#
# NOT A GATE ROW, and deliberately not named `tb_*.vhd`: `sim/regress.sh`
# auto-discovers that glob and this would turn the shared gate red for every
# track the moment a bound moved.  Run it by hand.
#
#   bash sim/elab9b_run.sh                  # the whole matrix
#   bash sim/elab9b_run.sh --only vn        # one row (substring match)
#   ELAB9B_CAP=24G bash sim/elab9b_run.sh   # raise the memory cap
#
# MEMORY.  Row `default` deliberately reproduces the failure and needs more
# RAM than this box has; it is capped and expected to be killed.  Every row is
# run under `systemd-run --user --scope -p MemoryMax=` so a runaway cannot
# reach systemd-oomd, which has taken down 275 processes on this box before.
# Rows run ONE AT A TIME for the same reason.
#
# GHDL is the mcode backend here: `ghdl -e` produces nothing and `ghdl -m` can
# return 0 while printing hard errors, so every row is a `ghdl -r` with a
# 1 ns stop time.  A `real` generic cannot be overridden by ghdl-mcode; none
# of the generics below is one.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP="${ELAB9B_CAP:-20G}"
SCRATCH="${ELAB9B_SCRATCH:-$(mktemp -d -t elab9b.XXXXXX)}"
ONLY="${2:-}"
[ "${1:-}" = "--only" ] || ONLY=""

GHDL="${GHDL:-ghdl}"
STD="--std=08"
WORK="$SCRATCH/work"
mkdir -p "$WORK"

command -v "$GHDL" >/dev/null 2>&1 || { echo "elab9b: ghdl not on PATH" >&2; exit 2; }

# A deep stack is not optional.  ghdl-mcode elaborates the region file and the
# state store with aggregate initialisers and SEGFAULTS at the default 8 MB,
# which reads as a GHDL crash rather than as the memory exhaustion it is.
ulimit -s unlimited 2>/dev/null || ulimit -s 1000000 2>/dev/null || true

echo "elab9b: scratch $SCRATCH"
echo "elab9b: $($GHDL --version | head -1)"

# rtl/ has no duplicate entity or package names, so importing all of it into
# one library is safe -- unlike rtl+sim+tb, which the project rule forbids.
# ORDER MATTERS.  `ghdl -i` only registers; it leaves every package marked
# obsolete until something analyses it.  Analysing the probe FIRST fails with
# "package llama_map_pkg is obsoleted by package model_cfg_pkg", which reads
# like a source error and is not one.  Build llama_top's closure first.
"$GHDL" -i $STD --workdir="$WORK" "$REPO"/rtl/*.vhd >/dev/null || exit 2
"$GHDL" -m $STD --workdir="$WORK" llama_top >/dev/null || exit 2
"$GHDL" -a $STD --workdir="$WORK" "$REPO"/sim/elab9b_vn_probe.vhd || exit 2

pass=0; fail=0; expected=0

# row <name> <expect: ok|fail> <unit> <ghdl generic args...>
row() {
  local name="$1" expect="$2" unit="$3"; shift 3
  if [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]]; then return 0; fi
  local out="$SCRATCH/$name.out" err="$SCRATCH/$name.err" rc
  ( cd "$WORK" && systemd-run --user --scope -q \
      -p MemoryMax="$CAP" -p MemorySwapMax=0 \
      /usr/bin/time -v "$GHDL" -r $STD --workdir="$WORK" "$unit" "$@" \
      --stop-time=2us ) >"$out" 2>"$err"
  rc=$?
  local rss ela
  rss=$(awk '/Maximum resident set size/{print $6}' "$err")
  ela=$(awk '/Elapsed \(wall clock\)/{print $8}' "$err")
  printf '%-16s rc=%-3s peakRSS=%8s kB  wall=%-8s expect=%s\n' \
         "$name" "$rc" "${rss:-?}" "${ela:-?}" "$expect"
  grep -v metavalue "$out" \
    | grep -iE "assertion (failure|error)|:error|overflow detected|elab9b_vn_probe:" \
    | sed 's/^/    /' | head -6
  grep -E "Command terminated by signal" "$err" | sed 's/^/    /'
  if { [ "$expect" = ok ] && [ "$rc" -eq 0 ]; } \
     || { [ "$expect" = fail ] && [ "$rc" -ne 0 ]; }; then
    pass=$((pass+1)); [ "$expect" = fail ] && expected=$((expected+1))
  else
    fail=$((fail+1))
  fi
}

# The 9B shape, from rtl/model_cfg_pkg.vhd, for reference:
#   blocks 32, attn_interval 4  -> 24 GDN layers, 8 attention layers
#   hidden 4096, ffn 12288      -> region_max = 12288, NOT the REGMAX default
#   GDN: 16 key heads, 32 value heads, head dim 128
#   attention: 16 q heads, 4 kv heads, head dim 256
# SHAPE is a record generic and ghdl cannot override it; it does not need to,
# because `mk_shape(MODEL, NCARDS)` is already llama_top's default.

# ---- 1. the design exactly as it ships -------------------------------------
# EXPECTED TO DIE.  llama_top models subsystem B's per-layer recurrent state as
# a SIGNAL array of 24 x 32 x 128 x 128 x 16 = 201,326,592 bits.  ghdl-mcode
# costs about 223 bytes per scalar signal, so that one declaration wants ~45 GB.
row default          fail llama_top

# ---- 2. what stubbing each subsystem buys ----------------------------------
row stub_A_and_B     ok   llama_top -gA_BEHAV=true  -gB_BEHAV=true  -gREGMAX=12288
row real_A           ok   llama_top -gA_BEHAV=false -gB_BEHAV=true  -gREGMAX=12288
row real_B           fail llama_top -gA_BEHAV=true  -gB_BEHAV=false -gREGMAX=12288
row real_C           ok   llama_top -gA_BEHAV=true  -gB_BEHAV=true  -gREGMAX=12288 \
                             -gC_REAL=true
row real_norm        ok   llama_top -gA_BEHAV=true  -gB_BEHAV=true  -gREGMAX=12288 \
                             -gNORM_REAL=true
row real_smp         ok   llama_top -gA_BEHAV=true  -gB_BEHAV=true  -gREGMAX=12288 \
                             -gSMP_EN=true

# ---- 3. the KV cache in HBM at the real head dim ---------------------------
# C_KV_BLOCK's DEFAULT of 4 gives NBLK = HEAD_DIM/KV_BLOCK = 64, and
# attn_kv_axi's guard for that (NBLK*EXP_W/8 <= 16, attn_kv_axi.vhd:455) is
# UNREACHABLE at HEAD_DIM 256: elaboration overflows first, in P_WR, with no
# line and no message.  At HEAD_DIM 32 or 64 the same illegal value produces a
# named assertion failure instead, which is why no simulation has seen this.
row kv_default_block fail llama_top -gA_BEHAV=true -gB_BEHAV=true -gREGMAX=12288 \
                             -gC_REAL=true -gC_KV_AXI=true
# Legal block size, DEFAULT bases: the two 34,816-byte regions overlap because
# C_K_BASE 16 / C_V_BASE 4064 are scaled-shape values.
row kv_default_base  fail llama_top -gA_BEHAV=true -gB_BEHAV=true -gREGMAX=12288 \
                             -gC_REAL=true -gC_KV_AXI=true -gC_KV_BLOCK=32
# Non-overlapping, but the PAIR needs 69,632 bytes and C_KV_ADDR_W is 16, so
# the V region wraps onto the K region.  NOTHING checks this: it elaborates.
row kv_addr_wrap     ok   llama_top -gA_BEHAV=true -gB_BEHAV=true -gREGMAX=12288 \
                             -gC_REAL=true -gC_KV_AXI=true -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176
row kv_good          ok   llama_top -gA_BEHAV=true -gB_BEHAV=true -gREGMAX=12288 \
                             -gC_REAL=true -gC_KV_AXI=true -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176 -gC_KV_ADDR_W=20
# OFF BY ONE AT A MAXIMUM.  POS_W = clog2(MAXCTX), and the guard demands
# C_CTXLEN < 2**POS_W as well as <= C_MAXPOS.  At a power-of-two cache depth
# those contradict, so the last cache position can never be used.
row ctx_at_max       fail llama_top -gA_BEHAV=true -gB_BEHAV=true -gREGMAX=12288 \
                             -gC_REAL=true -gC_KV_AXI=true -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=139264 -gC_KV_ADDR_W=24 \
                             -gC_MAXPOS=256 -gC_CTXLEN=256
row ctx_one_short    ok   llama_top -gA_BEHAV=true -gB_BEHAV=true -gREGMAX=12288 \
                             -gC_REAL=true -gC_KV_AXI=true -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=139264 -gC_KV_ADDR_W=24 \
                             -gC_MAXPOS=256 -gC_CTXLEN=255

# ---- 4. everything real except B's state store -----------------------------
row all_but_B        ok   llama_top -gA_BEHAV=false -gB_BEHAV=true -gREGMAX=12288 \
                             -gB_SRC_REAL=true -gNORM_REAL=true -gSMP_EN=true \
                             -gC_REAL=true -gC_KV_AXI=true -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176 -gC_KV_ADDR_W=20

# ---- 5. the D-vec element count against the 9B FFN -------------------------
# VN_W defaults to 13, so seq_vec_issue refuses n_rows >= 8192.  The 9B
# schedule's OP_VEC_SWG carries n_rows = ffn = 12288.  This is a RUN-TIME
# refusal: nothing rejects the combination at elaboration.
row vn13_swg_9b      ok   elab9b_vn_probe -gVN_W=13
row vn14_swg_9b      ok   elab9b_vn_probe -gVN_W=14
row vn13_hidden      ok   elab9b_vn_probe -gVN_W=13 -gNROWS=4096

echo
echo "elab9b: rows PASS $pass FAIL $fail (of which $expected were expected failures)"
echo "elab9b: logs in $SCRATCH"
[ "$fail" -eq 0 ]
