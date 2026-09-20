#!/usr/bin/env bash
# TEETH FOR UNIT A's WIDE DRAIN -- rtl/llama_top.vhd's A_DRAIN_WIDE arm and
# the three group-write sites it made into a shared resource.
#
# TRACK WIDEDRAIN, lever L1 of docs/2026-09-20_d-side-vector-traffic.md.
#
# THE QUESTION THIS FILE ANSWERS.  `sim/tb_llama_top_wdrain.vhd` is a new gate
# row that runs the integration top with the drain on the region file's group
# write port and checks it against the NARROW tree's four pinned landmarks.  A
# checker never shown to fail has not been shown to work, and this project has
# on record a top-level row that passed with a real defect in place for
# exactly as long as nobody mutated it.
#
# EVERY ROW HAS TWO ATTRIBUTION CONTROLS, because a kill proves nothing about
# WHO made it:
#
#   <tag>_N   the SAME mutation with A_DRAIN_WIDE FALSE.  If it still bites,
#             an EXISTING row (sim:tb_llama_top_real) would have caught it and
#             the new row deserves no credit for it.
#   <tag>_X   the SAME mutation with A_DRAIN_WIDE TRUE and the four landmarks
#             UNSET.  If it still bites, the kill belongs to a STRUCTURAL
#             property (the schedule check, the region lock, a range error),
#             not to the value gate.
#
# A row that does NOT bite is reported under its own name and kept.  It
# measures the resolution floor, which is the most valuable line in the table
# and the easiest one to delete.
#
# Usage:  bash sim/mutate_a_drain_wide.sh
# Env:    SCRATCH=<dir>   ONLY="<tag> <tag> ..."   (EXACT tags, space separated)
#
# NO HARDWARE.  GHDL only.  Nothing here opens a device, a cable or Vivado.
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it executes, so an
# edit under a running instance resumes it mid-token.  Same guard, same
# reason, as sim/mutate_llama_top_land.sh and sim/regress.sh.
if [ -z "${MUTAW_REPO:-}" ]; then
  MUTAW_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUTAW_REPO
fi
if [ -z "${MUTAW_SELF:-}" ] && [ -z "${MUTAW_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutaw-self.XXXXXXXX.sh)" || exit 2
  cat "${BASH_SOURCE[0]}" > "$_self" || { rm -f "$_self"; exit 2; }
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "mutate_a_drain_wide.sh: the private copy does not parse." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUTAW_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi
trap 'rm -f "${MUTAW_SELF:-}"' EXIT

cd "$MUTAW_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"

FILES=$(sed -n '/^FILES="/,/"$/p' sim/mutate_llama_top_kv.sh | sed 's/FILES="//; s/"$//')
[ -n "$FILES" ] || { echo "could not read FILES from sim/mutate_llama_top_kv.sh"; exit 2; }
# THAT LIST IS STALE AND IT FAILS LOUDLY, WHICH IS THE ONLY REASON THIS IS A
# NOTE AND NOT A DEFECT.  MEASURED 2026-09-20: reading it verbatim gives
# `rtl/gdn_state_store.vhd:903: unit "gdn_conv_w_mem" not found in library
# "work"`, because subsystem B's constants path (commit e212f04) added
# memories that nothing added to this list.  `sim/regress.sh` builds its own
# order and is unaffected; every `sim/mutate_llama_top*.sh` reading this list
# is NOT, so those harnesses currently analyse nothing and report
# DID NOT ANALYZE on every row.  Fixed HERE rather than in
# `sim/mutate_llama_top_kv.sh` only because TRACK BNARROW holds those files
# right now; the shared list still needs the same three names.
# INSERTED, not appended: GHDL analyses in order and `gdn_state_store` uses
# these, so a name added at the end is a name analysed too late.
FILES=${FILES/rtl\/gdn_conv_tap_mem.vhd/rtl\/gdn_conv_tap_mem.vhd rtl\/gdn_conv_w_mem.vhd}

# `sim/tb_llama_top_real.vhd`'s generic set, spelled exactly as that wrapper
# and as `sim/tb_llama_top_wdrain.vhd` spell it.  The two gate rows differ in
# A_DRAIN_WIDE and in nothing else, which is what makes the cycle difference
# attributable; the same must hold here or the controls are on the wrong axis.
G_REAL="-gBLOCKS=4 -gATTN_INT=4 -gNRUNS=2 -gC_REAL=true -gATTN_HD=16
        -gNORM_REAL=true -gNORM_ANCHOR=false
        -gW_IMAGE=llama_top_w_b4_pool.hex"
WIDE="-gA_DRAIN_WIDE=true"
NARROW="-gA_DRAIN_WIDE=false"
# MEASURED 2026-08-29 at 35e0ed0 on the NARROW tree, and reproduced by the
# wide arm on 2026-09-20.  Duplicated from the wrappers deliberately: a row
# that read them out of the wrapper would move with the wrapper.
LAND="-gEXP_X0=-16364 -gEXP_XSUM=91622 -gEXP_XALL=91622 -gEXP_STEPH=17333"
STOP=900ms

# The only two files any mutation here touches.  Everything ahead of them is
# analysed once into $BASE and copied per row.
TAIL_FILES="rtl/llama_top.vhd sim/tb_llama_top.vhd"
BASE_FILES=$(printf '%s\n' $FILES | grep -vx -e rtl/llama_top.vhd -e sim/tb_llama_top.vhd)
BASE="$SCRATCH/_base"
build_base() {
  rm -rf "$BASE"; mkdir -p "$BASE"
  local f
  for f in $BASE_FILES; do
    if ! ghdl -a --std=08 -frelaxed --workdir="$BASE" "$f" \
         >> "$BASE/analyze.log" 2>&1; then
      echo "BASE LIBRARY DID NOT ANALYSE at $f -- every row below would be a"
      echo "DID NOT ANALYZE, which looks like a mutation result and is not."
      sed -n 1,6p "$BASE/analyze.log"; exit 2
    fi
  done
}

# ---------------------------------------------------------------------------
# mutate_n <tag> <file> <old> <new> <count>  -- REQUIRED occurrence count.
# ---------------------------------------------------------------------------
mutate_n() {
  local tag="$1" file="$2" old="$3" new="$4" want="$5"
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$file" "$dir/$(basename "$file")" "$old" "$new" "$want" <<'PY'
import sys
src, dst, old, new, want = sys.argv[1:6]
s = open(src).read(); n = s.count(old)
if n != int(want):
    sys.stderr.write("ANCHOR MATCHED %d TIMES, REQUIRED %s\n" % (n, want))
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  [ $? -ne 0 ] && { echo ""; return; }
  echo "$dir"
}

# ---------------------------------------------------------------------------
# row <tag> <desc> <mutdir|""> <generics...>
# ---------------------------------------------------------------------------
# THE VERDICT IS THREE-WAY.  A run that DIED printed no RESULT line, and
# folding that into KILLED credits the value gate with a detection the
# SIMULATOR made.
row() {
  local tag="$1" desc="$2" mutdir="$3"; shift 3
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir/run"
  # THE BASE LIBRARY, ANALYSED ONCE.  Only the last two files can carry a
  # mutation this harness makes, and re-analysing the other ~60 per row costs
  # about four minutes each.  A 29-row matrix at that rate is two and a half
  # hours, which is long enough that a table gets trimmed to fit the time --
  # and the rows that get trimmed are the controls.
  cp -a "$BASE"/. "$dir"/ 2>/dev/null
  local f src
  for f in $TAIL_FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)  -- $desc"
      sed -n 1,4p "$dir/analyze.log"; return
    fi
  done
  ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex"  "$dir/run/" 2>/dev/null
  ln -sfn "$PWD/sim/llama_top_nw_b4_mean.hex" "$dir/run/" 2>/dev/null
  ( cd "$dir/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed \
      --workdir=.. tb_llama_top "$@" --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  if grep -aq "tb_llama_top RESULT: PASS" "$dir/run/run.log"; then
    echo "$tag  SURVIVED   -- $desc"
  elif ! grep -aq "tb_llama_top RESULT" "$dir/run/run.log"; then
    echo "$tag  KILLED(ABORT) -- no RESULT line: the SIMULATOR noticed, not the gate -- $desc"
  else
    echo "$tag  KILLED     -- $desc"
  fi
  grep -a "P14 landmarks measured" "$dir/run/run.log" \
    | head -1 | sed 's/^/        /' | cut -c1-190
  grep -a "cycles elapsed" "$dir/run/run.log" | head -1 \
    | sed 's/^/        /' | cut -c1-190
}

# The five anchors, each written once so a row and its two controls cannot
# drift apart.
A_BE_OLD="                     and (r + i - lane0) < j_rows then"
A_BE_NEW="                     and (r + i - lane0) <= j_rows then"
A_ADDR_OLD="                aw_addr <= to_unsigned((j_off + r) / LANES, GA_W);"
A_ADDR_NEW="                aw_addr <= to_unsigned(r / LANES, GA_W);"
A_LAST_OLD="                if r + A_DW_GRP >= j_rows then"
A_LAST_NEW="                if r + A_DW_GRP > j_rows then"
A_SKEW_OLD="                      <= ybw(rword)((rlane+i-lane0+1)*MANT_W-1
                                    downto (rlane+i-lane0)*MANT_W);"
A_SKEW_NEW="                      <= ybw(rword)((rlane+i-lane0+2)*MANT_W-1
                                    downto (rlane+i-lane0+1)*MANT_W);"
A_GUARD_OLD="              if A_DRAIN_WIDE and (j_off mod A_DW_GRP) = 0 then"
A_GUARD_NEW="              if A_DRAIN_WIDE then"
A_LOCK_OLD="  wr_region <= wg_reg when w_we = '1'"
A_LOCK_NEW="  wr_region <= v_reg_d when w_we = '1'"
A_MEMP_OLD="            a := to_integer(unsigned(wg_reg(6 downto 0)))*REGMAX"
A_MEMP_NEW="            a := to_integer(unsigned(v_reg_d(6 downto 0)))*REGMAX"
A_WSUM_OLD="            h := h + to_unsigned(to_integer(unsigned(wg_reg(6 downto 0)))*8191"
A_WSUM_NEW="            h := h + to_unsigned(to_integer(unsigned(v_reg_d(6 downto 0)))*8191"
A_RST_OLD="              if r = 0 then rword := 0; rlane := 0; end if;"
A_RST_NEW="              null;"

trio() {   # trio <tag> <desc> <old> <new> <count>
  local tag="$1" desc="$2" old="$3" new="$4" want="$5"
  local D
  D=$(mutate_n "$tag" rtl/llama_top.vhd "$old" "$new" "$want")
  [ -n "$D" ] || { echo "$tag  ANCHOR FAILED -- $desc"; return; }
  row "$tag"     "$desc"                                  "$D" $G_REAL $WIDE   $LAND
  row "${tag}_N" "  control: same mutation, A_DRAIN_WIDE FALSE" "$D" $G_REAL $NARROW $LAND
  row "${tag}_X" "  control: same mutation, wide, landmarks UNSET" "$D" $G_REAL $WIDE
}

echo "=== teeth for unit A's wide drain ==="
echo "scratch: $SCRATCH"
build_base
echo "base library analysed"
echo
echo "--- controls: the clean design must PASS on both arms ---"
row W0w "CONTROL: clean, A_DRAIN_WIDE TRUE,  four landmarks pinned" "" $G_REAL $WIDE   $LAND
row W0n "CONTROL: clean, A_DRAIN_WIDE FALSE, four landmarks pinned" "" $G_REAL $NARROW $LAND

echo
echo "--- the lane enables ---"
trio M1_be_tail "w_be enabled one row PAST the vector (r+i-lane0 <= j_rows)" \
     "$A_BE_OLD" "$A_BE_NEW" 1

echo
echo "--- the group address ---"
trio M2_addr_no_off "the group address drops j_off: to_unsigned(r / LANES)" \
     "$A_ADDR_OLD" "$A_ADDR_NEW" 1

echo
echo "--- the final partial group ---"
trio M3_last_group "off by one on the last group: r + A_DW_GRP > j_rows" \
     "$A_LAST_OLD" "$A_LAST_NEW" 1

echo
echo "--- the lane slice ---"
trio M4_lane_skew "the ybw lane slice skewed by one mantissa" \
     "$A_SKEW_OLD" "$A_SKEW_NEW" 1

echo
echo "--- the region lock: the hunk that fails in the GUARD, not in the data ---"
trio M5_wr_region "wr_region reads v_reg_d again: A's wide write policed against the D-vec region" \
     "$A_LOCK_OLD" "$A_LOCK_NEW" 1

echo
echo "--- the region file's own group-write address ---"
trio M6_memp_region "memp reads v_reg_d again: A's wide write lands in the D-vec region" \
     "$A_MEMP_OLD" "$A_MEMP_NEW" 1

echo
echo "--- the observability write hash ---"
trio M7_wsum_region "the write hash reads v_reg_d again: the INSTRUMENT names the wrong region" \
     "$A_WSUM_OLD" "$A_WSUM_NEW" 1

echo
echo "--- the alignment fallback: expected NOT to bite here, and why ---"
trio M8_no_fallback "the misaligned fallback removed (j_off mod A_DW_GRP guard dropped)" \
     "$A_GUARD_OLD" "$A_GUARD_NEW" 1

echo
echo "--- the path-independent cursor reset: shared by BOTH arms ---"
trio M9_no_reset "the r = 0 cursor reset removed (a property the NARROW arm has too)" \
     "$A_RST_OLD" "$A_RST_NEW" 1

echo
echo "done.  scratch: $SCRATCH"
