#!/usr/bin/env bash
# Teeth for sim/tb_attn_kv_map.vhd -- the value oracle for subsystem C's KV
# path AT THE REAL 9B MAP.
#
# Two kinds of row, and the distinction is the point of the file:
#
#   GENERIC rows perturb what the bench hands ACROSS the DUT port: the base,
#     the chunk-to-byte shift, the K/V assignment.  They are the model of
#     rtl/llama_top.vhd:3715-3720, which is the one place the chunk domain
#     becomes the byte domain and therefore the one place a silent 16x address
#     error can be introduced.  llama_top itself cannot be run on values at
#     this scale, so this is how that seam gets a teeth check at all -- see
#     the write-up for what that does and does not transfer.
#
#   RTL rows perturb rtl/attn_kv_axi.vhd's own address arithmetic in a scratch
#     copy.  They measure whether the ORACLE can see the address equation,
#     rather than whether the port map was typed correctly.
#
# THREE VERDICTS, NOT TWO, via sim/mutverdict.py: KILLED means the checker
# noticed and said so; ABORT means the run died before the checker reached a
# verdict it owns and so the checker was NOT shown to catch it; SURVIVED means
# the mutation is invisible to this bench and is a measured hole in it.
#
# EVERY SURVIVOR IS REPORTED UNDER ITS OWN NAME AND NONE IS DISCARDED.  A
# survivor is the resolution floor of the check and is the most valuable row
# in the table.
#
# Usage:  bash sim/mutate_kv_map.sh
# Env:    SCRATCH=<dir>
set -uo pipefail

if [ -z "${MUT_REPO:-}" ]; then
  MUT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUT_REPO
fi
# SELF-ISOLATION: bash reads a script by byte offset as it runs, so an edit
# under a running instance corrupts that run silently.  Same guard, same
# reasons, as sim/regress.sh:307 and sim/mutate_attn_kv_axi.sh:30.
if [ -z "${MUT_SELF:-}" ] && [ -z "${MUT_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutkvmap.XXXXXXXX.sh)" || exit 2
  if ! cat "${BASH_SOURCE[0]}" > "$_self"; then
    rm -f "$_self"; echo "could not take a private copy" >&2; exit 2
  fi
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "the private copy does not parse -- this script was probably being" >&2
    echo "  written at the instant it was copied.  Try again." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUT_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi
trap 'if [ -n "${MUT_SELF:-}" ]; then rm -f "$MUT_SELF"; fi' EXIT

cd "$MUT_REPO"
MUTV="$MUT_REPO/sim/mutverdict.py"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
# The clean run is 99 us of modelled time and ~40 s of wall.  --stop-time is
# 20 ms, a 200x margin, so a mutation that HANGS ends rather than runs forever;
# the bench's own residency watchdog (200,000 cycles) normally fires first.
STOP=20ms
NKILL=0; NABORT=0; NSURV=0; NTOT=0

# Analyse the unmutated closure once; every generic row reuses it.
BASEW="$SCRATCH/_base"
rm -rf "$SCRATCH/_base"; mkdir -p "$BASEW"
ghdl -a --std=08 --workdir="$BASEW" rtl/util_pkg.vhd rtl/attn_kv_axi.vhd \
     sim/tb_attn_kv_map.vhd > "$BASEW/analyze.log" 2>&1 || {
  echo "the UNMUTATED tree does not analyse -- nothing below measures anything"
  sed -n 1,10p "$BASEW/analyze.log"; exit 2; }

verdict() {   # $1 tag  $2 desc  $3 dir  $4 rc
  local tag="$1" desc="$2" dir="$3" rcv="$4" v
  v=$(python3 "$MUTV" "$dir/run.log" tb_attn_kv_map "$rcv")
  case "$v" in
    PASS)
      NSURV=$((NSURV+1)); echo "$tag  SURVIVED   -- $desc" ;;
    KILLED)
      NKILL=$((NKILL+1)); echo "$tag  KILLED     -- $desc"
      grep -vE "metavalue" "$dir/run.log" \
        | grep -E "MISMATCH|FAULT|STRAY|assertion|CROSSES|AXI3|never|abandoned|exercised" \
        | head -1 | sed 's/^/        /' | cut -c1-200 ;;
    *)
      NABORT=$((NABORT+1)); echo "$tag  ABORT (${v#ABORT:})   -- $desc"
      echo "        the run DIED before the checker reached a verdict, so the"
      echo "        checker was NOT shown to catch this.  Not counted as a kill."
      grep -vE "metavalue" "$dir/run.log" | tail -3 \
        | sed 's/^/        /' | cut -c1-200 ;;
  esac
}

# ---- a row that perturbs only what crosses the DUT port -------------------
gmut() {      # $1 tag  $2 desc  $3.. -g flags
  local tag="$1" desc="$2"; shift 2
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  ghdl -a --std=08 --workdir="$dir" rtl/util_pkg.vhd rtl/attn_kv_axi.vhd \
       sim/tb_attn_kv_map.vhd > "$dir/analyze.log" 2>&1 || {
    echo "$tag  DID NOT ANALYSE   -- $desc"; return; }
  ghdl -r --std=08 --workdir="$dir" tb_attn_kv_map "$@" \
      --max-stack-alloc=0 --stop-time="$STOP" > "$dir/run.log" 2>&1
  verdict "$tag" "$desc" "$dir" $?
}

# ---- a row that perturbs rtl/attn_kv_axi.vhd itself -----------------------
rmut() {      # $1 tag  $2 desc  $3 old  $4 new
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - rtl/attn_kv_axi.vhd "$dir/attn_kv_axi.vhd" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then
    echo "$tag: ANCHOR FAILED   -- $desc"
    echo "        a moved anchor is a SILENT LOSS of a mutation row, not a pass"
    return
  fi
  ghdl -a --std=08 --workdir="$dir" rtl/util_pkg.vhd >/dev/null 2>&1
  if ! ghdl -a --std=08 --workdir="$dir" "$dir/attn_kv_axi.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYSE (a mutation that will not compile has tested nothing)   -- $desc"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 --workdir="$dir" sim/tb_attn_kv_map.vhd >/dev/null 2>&1
  ghdl -r --std=08 --workdir="$dir" tb_attn_kv_map \
      --max-stack-alloc=0 --stop-time="$STOP" > "$dir/run.log" 2>&1
  verdict "$tag" "$desc" "$dir" $?
}

echo "============ teeth for sim/tb_attn_kv_map.vhd (the REAL 9B map) ======="

# THE CONTROL, RUN FIRST.  A mutation table read against a bench that fails on
# the clean design measures nothing.
gmut control "the unmutated bench, unmutated RTL -- MUST survive"

echo "---- the chunk-to-byte seam (the model of llama_top.vhd:3715-3720) ----"
gmut shift_0  "BASE_SHIFT 0: the chunk count handed over AS a byte address" \
     -gBASE_SHIFT=0
gmut shift_3  "BASE_SHIFT 3: half the real base"   -gBASE_SHIFT=3
gmut shift_5  "BASE_SHIFT 5: twice it, and bit 33 falls off the 33-bit port" \
     -gBASE_SHIFT=5

echo "---- the bases themselves ---------------------------------------------"
gmut k_one_chunk_hi "K base one 16-byte CHUNK high" -gMUT_K_CH=1
gmut k_one_chunk_lo "K base one 16-byte CHUNK low"  -gMUT_K_CH=-1
gmut v_one_chunk_hi "V base one 16-byte CHUNK high" -gMUT_V_CH=1
gmut k_one_byte     "K base one BYTE high -- a value C_K_BASE_CH cannot even express" \
     -gMUT_K_BY=1
gmut k_one_rec_hi   "K base one whole 272-byte RECORD high" -gMUT_K_CH=17
gmut kv_swapped     "the two bases handed over SWAPPED" -gMUT_SWAP=true

echo "---- the address equation inside rtl/attn_kv_axi.vhd -------------------"
rmut lay_stride_gone "C spec 2.2's layer term dropped" \
  "    idx := (lay*N_KVH + hd)*MAXCTX + ps;" \
  "    idx := (0*N_KVH + hd)*MAXCTX + ps;"
rmut lay_head_swap "layer and kv head swapped in the sub-region index" \
  "    idx := (lay*N_KVH + hd)*MAXCTX + ps;" \
  "    idx := (hd*N_KVH + lay)*MAXCTX + ps;"
rmut ctx_stride_off "the per-(layer,head) stride one position short" \
  "    idx := (lay*N_KVH + hd)*MAXCTX + ps;" \
  "    idx := (lay*N_KVH + hd)*(MAXCTX-1) + ps;"
rmut pos_off_by_one "the position term one record high" \
  "    idx := (lay*N_KVH + hd)*MAXCTX + ps;" \
  "    idx := (lay*N_KVH + hd)*MAXCTX + ps + 1;"
rmut rec_b_off "the record stride one 16-byte chunk short" \
  "    return unsigned(base) + to_unsigned(idx*REC_B, ADDR_W);" \
  "    return unsigned(base) + to_unsigned(idx*(REC_B-16), ADDR_W);"

echo "---- the fix this track landed, put back the way it was -----------------"
rmut revert_to_integer_read \
  "the read engine's phase back to to_integer(a0) mod BEAT_B" \
  "              ph_ch   <= low_bits(a0, BEAT_LW)/CH_B;" \
  "              ph_ch   <= (to_integer(a0) mod BEAT_B)/CH_B;"
rmut revert_to_integer_write \
  "the write engine's phase back to to_integer(a0) mod BEAT_B" \
  "              phase  := low_bits(a0, BEAT_LW);" \
  "              phase  := to_integer(a0) mod BEAT_B;"
rmut revert_to_integer_4k \
  "burst_len's 4 KB term back to to_integer(a) mod 4096" \
  "    to4k := (4096 - low_bits(a, 12))/BEAT_B;" \
  "    to4k := (4096 - (to_integer(a) mod 4096))/BEAT_B;"

echo "======================================================================="
echo "MUTATIONS $NTOT   KILLED $NKILL   SURVIVED $NSURV   ABORT $NABORT"
echo "scratch: $SCRATCH"
echo
echo "A SURVIVOR IS NOT A FAILURE OF THE RUN, IT IS THE MEASURED RESOLUTION"
echo "FLOOR OF THE CHECK.  Read every one of them; do not delete any."
