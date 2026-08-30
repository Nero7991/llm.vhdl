#!/usr/bin/env bash
# sim/realshape_gate.sh -- TRACK REALFIX, 2026-08-29.
#
# THE REAL 9B SHAPE ELABORATES, AND EVERY GUARD AROUND IT HAS TEETH.
#
# WHAT THIS IS FOR.  `rtl/llama_top.vhd`'s DEFAULT generic set is
# `mk_shape(MODEL, NCARDS)` -- the real Qwen3.5-9B shape, hidden 4096, ffn
# 12288 -- and that expression occurs exactly once in the whole VHDL tree, as
# that default.  No bench passes it.  So until TRACK REALSHAPE ran it
# (docs/debugging/2026-08-29_realshape-9b-elaboration.md) the configuration
# that had never been elaborated anywhere was the top level's own, which is
# the one a synthesis run gets if nobody overrides anything.  It died with
# STORAGE_ERROR at 24.9 GB.  This script is the standing check that it does
# not any more, and it costs about 23 s over 19 rows.
#
# ELABORATING IS NOT COMPUTING.  Nothing here checks a value.  Every row is a
# shape, a width, an array bound or an integer range at the true dimensions.
# The value gates for this file are the `sim/tb_llama_top*` family.
#
# EVERY GUARD ROW COMES IN A PAIR.  A row that must FAIL is worthless without
# the neighbouring row, one generic away, that must PASS: without it a guard
# that refuses everything looks identical to a guard that works.  The pairs
# are marked below.
#
# NOT A `tb_*.vhd`, deliberately, and the name is outside the `elab9b_*`
# family so it cannot collide with TRACK REALSHAPE's investigation harness.
#
# IT IS NOT A GATE ROW AND IT CANNOT BE ONE.  `sim/regress.sh` runs VHDL
# testbenches, not scripts, and more to the point ten of the rows below must
# make the ELABORATOR REFUSE -- which no testbench can express, because a
# refused elaboration takes the whole bench down with it.  The half that CAN
# be a gate row is `sim/tb_realshape_9b.vhd`, which elaborates `llama_top` at
# its defaults and nothing else.  Run this by hand after touching any bound,
# width or generic default in `rtl/llama_top.vhd` or `rtl/attn_kv_axi.vhd`.
#
#   bash sim/realshape_gate.sh              # the whole matrix
#   bash sim/realshape_gate.sh --only vn    # one row (SUBSTRING, not regex)
#   REALSHAPE_CAP=8G bash sim/realshape_gate.sh
#
# MEMORY.  The heaviest row is the default shape at about 2.2 GB.  Every row
# runs under `systemd-run --user --scope -p MemoryMax=` and ONE AT A TIME, so
# a regression that reinstates the 46 GB signal array is killed at the cap
# instead of reaching systemd-oomd, which has taken down 275 processes on this
# box before.  If systemd-run is unavailable the rows run uncapped and the
# script says so rather than silently dropping the protection.
#
# GHDL here is the mcode backend: `ghdl -e` produces no binary and silently
# succeeds and `ghdl -m` can return 0 while printing hard errors, so every row
# is a `ghdl -r`.  A deep stack is NOT optional -- at the default 8 MB the
# real shape SEGFAULTS during elaboration, which reads as a GHDL bug rather
# than as the memory exhaustion it is.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP="${REALSHAPE_CAP:-8G}"
SCRATCH="${REALSHAPE_SCRATCH:-$(mktemp -d -t realshape.XXXXXX)}"
ONLY=""
[ "${1:-}" = "--only" ] && ONLY="${2:-}"

GHDL="${GHDL:-ghdl}"
STD="--std=08"
WORK="$SCRATCH/work"
mkdir -p "$WORK"

command -v "$GHDL" >/dev/null 2>&1 || { echo "realshape_gate: ghdl not on PATH" >&2; exit 2; }

ulimit -s unlimited 2>/dev/null || ulimit -s 1000000 2>/dev/null || true

CAPRUN=(systemd-run --user --scope -q -p MemoryMax="$CAP" -p MemorySwapMax=0)
if ! systemd-run --user --scope -q true >/dev/null 2>&1; then
  echo "realshape_gate: systemd-run unavailable, rows run UNCAPPED"
  CAPRUN=()
fi

echo "realshape_gate: $($GHDL --version | head -1)"
echo "realshape_gate: scratch $SCRATCH"

# `rtl/` has no duplicate entity or package names, so importing all of it into
# one library is safe -- unlike rtl+sim+tb, which the project rule forbids.
# ORDER MATTERS: `ghdl -i` only registers, and leaves every package marked
# obsolete until something analyses it.
"$GHDL" -i $STD --workdir="$WORK" "$REPO"/rtl/*.vhd >/dev/null || {
  echo "realshape_gate: ghdl -i failed"; exit 2; }
"$GHDL" -m $STD --workdir="$WORK" llama_top >/dev/null || {
  echo "realshape_gate: ghdl -m llama_top failed"; exit 2; }
"$GHDL" -m $STD --workdir="$WORK" attn_kv_axi >/dev/null || {
  echo "realshape_gate: ghdl -m attn_kv_axi failed"; exit 2; }

pass=0; fail=0; expected=0
declare -a failed_rows=()

# row <name> <expect: ok|fail> <unit> <ghdl generic args...>
row() {
  local name="$1" expect="$2" unit="$3"; shift 3
  if [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]]; then return 0; fi
  local out="$SCRATCH/$name.out" rc
  ( cd "$WORK" && "${CAPRUN[@]}" \
      /usr/bin/time -f 'RSSKB %M WALL %e' \
      "$GHDL" -r $STD --workdir="$WORK" "$unit" "$@" --stop-time=1ns \
  ) >"$out" 2>&1
  rc=$?
  local rss wall
  rss=$(awk '/^RSSKB/{print $2}' "$out" | tail -1)
  wall=$(awk '/^RSSKB/{print $4}' "$out" | tail -1)
  printf '%-18s rc=%-3s peakRSS=%8s kB  wall=%-6s expect=%s\n' \
         "$name" "$rc" "${rss:-?}" "${wall:-?}" "$expect"
  grep -v metavalue "$out" \
    | grep -iE "assertion (failure|error)|:error|overflow detected|bound check" \
    | sed 's/^/    /' | head -3
  if { [ "$expect" = ok ] && [ "$rc" -eq 0 ]; } \
     || { [ "$expect" = fail ] && [ "$rc" -ne 0 ]; }; then
    pass=$((pass+1)); [ "$expect" = fail ] && expected=$((expected+1))
  else
    fail=$((fail+1)); failed_rows+=("$name (expected $expect, rc=$rc)")
  fi
}

# ===========================================================================
# 1. THE HEADLINE.  No generic overrides at all.  This IS the real 9B shape,
#    because `mk_shape(MODEL, NCARDS)` is llama_top's own default: real
#    matvec_int4, real gdn_block, the real region file, at hidden 4096 and
#    ffn 12288.  Before TRACK REALFIX it needed ~46 GB and died.
# ===========================================================================
row default_9b        ok   llama_top

# ===========================================================================
# 2. R1, REGMAX.  Every region is REGMAX elements wide and `region_max` at
#    the 9B shape is 12288 (ffn).  The default now derives from SHAPE; the
#    PAIR below shows the guard bites when it is overridden short and does
#    not bite one element the other side of the boundary.
# ===========================================================================
row regmax_short      fail llama_top -gREGMAX=4096      # the OLD default
row regmax_edge_lo    fail llama_top -gREGMAX=12287     # one short
row regmax_edge_ok    ok   llama_top -gREGMAX=12288     # exactly enough

# ===========================================================================
# 3. R3, VN_W.  `seq_vec_issue` refuses a D-vec job with
#    `job_n_rows >= 2**VN_W` (EC_NROWS), and OP_VEC_SWG carries n_rows = ffn
#    = 12288, so the old fixed 13 refused every FFN of every block AT RUN
#    TIME with nothing rejecting it at elaboration.
# ===========================================================================
row vn_w_short        fail llama_top -gVN_W=13
row vn_w_ok           ok   llama_top -gVN_W=14

# ===========================================================================
# 4. R4, the KV header chunk.  NBLK = attn_head_dim / KV_BLOCK block
#    exponents must fit the record's 16-byte header chunk, i.e. NBLK <= 16.
#    attn_head_dim is 256 for BOTH 9B and 27B, so KV_BLOCK 16 sits exactly on
#    the bound and one step past it the diagnostic used to disappear
#    entirely: `overflow detected`, no file, no line, no message, raised
#    while attn_kv_axi's P_WR statement part was elaborated -- BEFORE its own
#    concurrent assert for this could run.  Rows 4a name the caller
#    (llama_top), rows 4b the module standing alone.
# ===========================================================================
CKV="-gA_BEHAV=true -gB_BEHAV=true -gC_REAL=true -gC_KV_AXI=true"
# shellcheck disable=SC2086
row kv_nblk_bad       fail llama_top $CKV -gC_KV_BLOCK=4 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176 -gC_KV_ADDR_W=20
# shellcheck disable=SC2086
row kv_nblk_ok        ok   llama_top $CKV -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176 -gC_KV_ADDR_W=20
# THE GRANULE CHECK IN ISOLATION, and the reason this row looks absurd.
# `CHK_KV_GRAN` is declared after `CHK_KV_NBLK`, so at every SENSIBLE
# geometry the NBLK check fires first and the granule one is never reached:
# attn_head_dim is 256, so every KV_BLOCK small enough to break the granule
# rule is also small enough to break the NBLK bound.  A check that is
# shadowed at every reachable input is a check nobody has shown to work, so
# this row uses KV_BLOCK 17, which is not a divisor of 256 and is not a
# geometry anybody would build: C_NBLK truncates to 15, the NBLK bound is
# satisfied, and the granule bound is the only thing left to refuse it.
# shellcheck disable=SC2086
row kv_gran_bad       fail llama_top $CKV -gC_KV_BLOCK=17 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176 -gC_KV_ADDR_W=20

KVG="-gN_KVH=4 -gLAYERS=8 -gMAXCTX=4 -gPOS_W=16 -gCM_W=8 -gEXP_W=8"
KVG="$KVG -gAXI_DW=256 -gADDR_W=16"
# shellcheck disable=SC2086
row kvaxi_nblk64_bad  fail attn_kv_axi -gHEAD_DIM=256 -gKV_BLOCK=4  $KVG
# shellcheck disable=SC2086
row kvaxi_nblk32_bad  fail attn_kv_axi -gHEAD_DIM=256 -gKV_BLOCK=8  $KVG
# shellcheck disable=SC2086
row kvaxi_nblk16_ok   ok   attn_kv_axi -gHEAD_DIM=256 -gKV_BLOCK=16 $KVG

# ===========================================================================
# 5. R5, the KV regions must FIT the address space.  The pre-existing check
#    verified only that K and V do not overlap EACH OTHER.  Two 34,816-byte
#    regions based at 0 and 34,816 need 69,632 bytes; in a 16-bit space that
#    elaborated CLEAN and the top 4,096 bytes of V wrapped onto the first
#    records of K.  The pair differs only in C_KV_ADDR_W.
# ===========================================================================
# shellcheck disable=SC2086
row kv_addr_wrap      fail llama_top $CKV -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176 -gC_KV_ADDR_W=16
# shellcheck disable=SC2086
row kv_addr_fits      ok   llama_top $CKV -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176 -gC_KV_ADDR_W=20
# and the overlap check itself still bites, one generic away
# shellcheck disable=SC2086
row kv_overlap        fail llama_top $CKV -gC_KV_BLOCK=32 -gC_KV_ADDR_W=20

# ===========================================================================
# 6. R6, the off-by-one at the cache maximum.  POS_W is now clog2(MAXPOS+1)
#    because `ctx_len` is a COUNT (1 .. MAXPOS) and not a position.  At a
#    power-of-two depth the old width could not represent the count, so the
#    LAST cache position could never be used: 256 failed and 255 passed.
#    `ctx_at_max` is the row that used to fail; `ctx_over_max` is the control
#    that must STILL fail, or the fix would have removed the check instead of
#    correcting it.
# ===========================================================================
KVC="-gC_KV_BLOCK=32 -gC_K_BASE_CH=0 -gC_V_BASE_CH=139264 -gC_KV_ADDR_W=24"
KVC="$KVC -gC_MAXPOS=256"
# shellcheck disable=SC2086
row ctx_at_max        ok   llama_top $CKV $KVC -gC_CTXLEN=256
# shellcheck disable=SC2086
row ctx_one_short     ok   llama_top $CKV $KVC -gC_CTXLEN=255
# shellcheck disable=SC2086
row ctx_over_max      fail llama_top $CKV $KVC -gC_CTXLEN=257

# ===========================================================================
# 7. THE WHOLE COMPOSITION AT THE REAL SHAPE.  Real A, real B fed from the
#    real regions, real C over three AXI masters against the real
#    attn_kv_axi, the real RMSNorm, the sampler on.  This is the row that
#    says a real-shape elaboration is affordable rather than merely possible.
# ===========================================================================
# shellcheck disable=SC2086
row all_real          ok   llama_top -gA_BEHAV=false -gB_BEHAV=false \
                             -gB_SRC_REAL=true -gNORM_REAL=true -gSMP_EN=true \
                             -gC_REAL=true -gC_KV_AXI=true -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=0 -gC_V_BASE_CH=2176 -gC_KV_ADDR_W=20

# ===========================================================================
# 8. THE REAL KV MAP.  TRACK CKVMAP, 2026-08-29.
#
#    Every row above runs at C_MAXPOS <= 256 with bases under 36 MB, so the
#    whole 32-bit wall was OUTSIDE this gate's coverage and a green run was
#    compatible with a KV map that could not be expressed at all.  It could
#    not: `C_K_BASE` was a byte-domain `natural` and the real K base is
#    4,521,582,592, which is 2.11x `natural'high`.  The generics now count
#    the record's own 16-byte chunks.
#
#    PROVENANCE OF EVERY NUMBER, all re-derived rather than restated:
#      C_K_BASE_CH 282598912  = hbm.kv_base 4521582592 / 16, from the
#                               residency manifest that tools/hbm_map.py
#                               derives (ARENA-MANIFEST made it the authority)
#      C_V_BASE_CH 353902080  = C_K_BASE_CH + C_LAY*C_NKVH*C_MAXPOS*REC_CH
#                               = 282598912 + 8*4*131072*17
#      C_MAXPOS    131072     Qwen3.5-9B's native context.  DECIDED, not
#                             derived: the arena affords 233,396 and anything
#                             past 131,072 needs RoPE extension work that does
#                             not exist.  See docs/WORKLOG.md.
#      C_KV_ADDR_W 33         clog2(353902080 + 71303168) = clog2(425205248)
#                             = 29, and 29 <= 33-4 EXACTLY.
#
#    THE PAIR IS THE POINT.  `real_kv_map` must pass and `real_kv_addr_short`
#    -- the same map with one address bit fewer -- must refuse, or a green
#    row would only prove the check cannot fail.
#
#    NOTE C_KV_ADDR_W IS PINNED BY THE BASE, NOT BY C_MAXPOS.  C_K_BASE_CH
#    alone is 282,598,912, already above 2**28, so clog2 is 29 for EVERY
#    C_MAXPOS from 1 to 233,705 -- which covers the arena ceiling of 233,396.
#    `real_kv_ceiling` runs the map at that ceiling to show 33 still holds.
# ===========================================================================
KVR="-gC_KV_BLOCK=32 -gC_K_BASE_CH=282598912 -gC_V_BASE_CH=353902080"
KVR="$KVR -gC_KV_ADDR_W=33 -gC_MAXPOS=131072 -gC_CTXLEN=131072"
# shellcheck disable=SC2086
row real_kv_map       ok   llama_top $CKV $KVR
# shellcheck disable=SC2086
row real_kv_addr_short fail llama_top $CKV -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=282598912 -gC_V_BASE_CH=353902080 \
                             -gC_KV_ADDR_W=32 -gC_MAXPOS=131072 -gC_CTXLEN=131072
# The V base one chunk low, so the K region's last record overlaps V's first.
# shellcheck disable=SC2086
row real_kv_overlap   fail llama_top $CKV -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=282598912 -gC_V_BASE_CH=353902079 \
                             -gC_KV_ADDR_W=33 -gC_MAXPOS=131072 -gC_CTXLEN=131072
# The arena ceiling.  Bases unchanged, C_MAXPOS at 233,396: still 33 bits.
# shellcheck disable=SC2086
row real_kv_ceiling   ok   llama_top $CKV -gC_KV_BLOCK=32 \
                             -gC_K_BASE_CH=282598912 -gC_V_BASE_CH=409566336 \
                             -gC_KV_ADDR_W=33 -gC_MAXPOS=233396 -gC_CTXLEN=233396
# C_CTXLEN past the cache, at the REAL depth.  The small-shape ctx rows above
# cannot reach this arithmetic because their C_MAXPOS is 256.
# shellcheck disable=SC2086
row real_kv_ctx_over  fail llama_top $CKV $KVR -gC_CTXLEN=131073

# ===========================================================================
# THE MANIFEST LINK.  TRACK KVVALUE, 2026-08-29.
#
# Every row above says the map ELABORATES.  Not one of them says the map
# points at the arena, and CKVMAP reported exactly that as a guard that does
# not bite: "there is no link from the RTL to `hbm.kv_base`, so a base one
# chunk -- or one megabyte -- off the manifest elaborates clean and would read
# and write real weights.  THE GATE ROW PINS THE CORRECT VALUE, AND THE GATE
# ROW IS THE ONLY THING THAT DOES."
#
# `tools/check_kv_map.py` is what makes the $KVR numbers above DERIVED rather
# than hand-copied: it reads `tools/hbm_map.py`'s shape (the authority TRACK
# ARENA-MANIFEST established), the packed model's manifest for `hbm.kv_base`,
# `rtl/llama_top.vhd` for the generic names and the chunk-to-byte shift, and
# THIS BLOCK for the values, and refuses on any mismatch.  Its own teeth are
# `python3 tools/check_kv_map.py --teeth`, 17 rows.
#
# It is run here rather than in `sim/regress.sh` because the values it checks
# are the $KVR block a few lines up: the check and the thing checked belong in
# one file, and a clone with no packed model must not turn the shared gate red.
# --no-manifest is passed only when the manifest is genuinely absent, and the
# row then prints NOT RUN for the placement side instead of passing quietly.
echo
MANI="${KV_MANIFEST:-/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json}"
if [ -f "$MANI" ]; then
  kvargs=(--manifest "$MANI")
else
  kvargs=(--manifest "$MANI" --no-manifest)
  echo "check_kv_map: NO MANIFEST at $MANI -- the rows that pin C_K_BASE_CH to"
  echo "              hbm.kv_base WILL NOT RUN.  Set KV_MANIFEST to a packed"
  echo "              model's manifest.json to close that."
fi
if python3 "$(dirname "$0")/../tools/check_kv_map.py" "${kvargs[@]}" \
     > "$SCRATCH/check_kv_map.log" 2>&1; then
  echo "row  kv_map_manifest_link  ok    $(grep -c '^  ok' "$SCRATCH/check_kv_map.log") rows against tools/hbm_map.py and the manifest"
  pass=$((pass+1))
else
  echo "row  kv_map_manifest_link  FAIL  -- the KV generics and the HBM address"
  echo "     map's authority DISAGREE.  This is not a style point: the cache"
  echo "     would read and write real weights."
  sed -n '1,40p' "$SCRATCH/check_kv_map.log" | sed 's/^/     /'
  fail=$((fail+1))
  failed_rows+=("kv_map_manifest_link")
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "REALSHAPE GATE: PASS  rows $pass ($expected of them guards that must refuse)"
else
  echo "REALSHAPE GATE: FAIL  $fail row(s):"
  for r in "${failed_rows[@]}"; do echo "   - $r"; done
fi
echo "realshape_gate: logs in $SCRATCH"
[ "$fail" -eq 0 ]
