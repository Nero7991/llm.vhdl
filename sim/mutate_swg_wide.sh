#!/usr/bin/env bash
# TEETH FOR THE SwiGLU ON THE REGION FILE'S GROUP PORTS -- rtl/llama_top.vhd's
# SWG_WIDE arm, the two muxes it turns the group ports into, and the `greq`
# check that watches them.
#
# TRACK GSRWIDE, lever L2 of docs/2026-09-20_d-side-vector-traffic.md.
#
# THE QUESTION THIS FILE ANSWERS.  `sim/tb_llama_top_swgw.vhd` is a new gate
# row that runs the integration top with the SwiGLU adapter's load and
# write-back on the group ports and holds it to the NARROW row's four pinned
# landmarks.  A checker never shown to fail has not been shown to work.
#
# EVERY ROW HAS TWO ATTRIBUTION CONTROLS, because a kill proves nothing about
# WHO made it:
#
#   <tag>_N   the SAME mutation with SWG_WIDE FALSE and SWG_LANES STILL 8.
#             ONE variable.  If it still bites, an EXISTING row
#             (sim:tb_llama_top_swg) catches it and the new row gets no
#             credit.  SWG_LANES is held at 8 deliberately: a control that
#             also moved the unit's lane count would be on two axes, which
#             is the recorded `c4nd`/`c4kv4` error.
#   <tag>_X   the SAME mutation, wide, with the four landmarks UNSET.  If it
#             still bites, the kill belongs to a STRUCTURAL property (the
#             region lock, `greq`, a constrained range), not to the value
#             gate.
#
# AND FOR THE TWO MUX-SELECTOR ROWS, A THIRD:
#
#   <tag>_G   the same mutation, wide, landmarks unset, AND `greq`'s
#             assertions downgraded to `note`.  This is the attribution
#             control for the NEW CHECK: if _X bites and _G does not, `greq`
#             is what caught it; if both bite, something older did.
#
# A row that does NOT bite is reported under its own name and kept.  It
# measures the resolution floor, which is the most valuable line in the table
# and the easiest one to delete.
#
# Usage:  bash sim/mutate_swg_wide.sh
# Env:    SCRATCH=<dir>   ONLY="<tag> <tag> ..."   (EXACT tags, space separated)
#
# NO HARDWARE.  GHDL only.  Nothing here opens a device, a cable or Vivado.
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it executes, so an
# edit under a running instance resumes it mid-token.  Same guard, same
# reason, as sim/mutate_a_drain_wide.sh and sim/regress.sh.
if [ -z "${MUTSW_REPO:-}" ]; then
  MUTSW_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUTSW_REPO
fi
if [ -z "${MUTSW_SELF:-}" ] && [ -z "${MUTSW_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutsw-self.XXXXXXXX.sh)" || exit 2
  cat "${BASH_SOURCE[0]}" > "$_self" || { rm -f "$_self"; exit 2; }
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "mutate_swg_wide.sh: the private copy does not parse." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUTSW_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi
trap 'rm -f "${MUTSW_SELF:-}"' EXIT

cd "$MUTSW_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"

FILES=$(sed -n '/^FILES="/,/"$/p' sim/mutate_llama_top_kv.sh | sed 's/FILES="//; s/"$//')
[ -n "$FILES" ] || { echo "could not read FILES from sim/mutate_llama_top_kv.sh"; exit 2; }
# The same stale-list workaround sim/mutate_a_drain_wide.sh documents: the
# shared list predates subsystem B's constants path and omits gdn_conv_w_mem,
# so reading it verbatim gives `unit "gdn_conv_w_mem" not found` and every row
# reports DID NOT ANALYZE, which looks like a mutation result and is not.
# INSERTED, not appended: GHDL analyses in order.
FILES=${FILES/rtl\/gdn_conv_tap_mem.vhd/rtl\/gdn_conv_tap_mem.vhd rtl\/gdn_conv_w_mem.vhd}

# `sim/tb_llama_top_swg.vhd`'s generic set, spelled exactly as that wrapper
# and as `sim/tb_llama_top_swgw.vhd` spell it.  The two gate rows differ in
# SWG_LANES and SWG_WIDE and in nothing else.
G_SWG="-gBLOCKS=4 -gATTN_INT=4 -gNRUNS=1 -gNTOK=3 -gC_REAL=true -gATTN_HD=16
       -gNORM_REAL=true -gNORM_ANCHOR=false -gMAXPOS=8 -gSWG_REAL=true
       -gW_IMAGE=llama_top_w_b4_pool.hex"
WIDE="-gSWG_LANES=8 -gSWG_WIDE=true"
NARROW="-gSWG_LANES=8 -gSWG_WIDE=false"
# SWG_LANES 4 with LANES 8: the SUB-GROUP geometry, where `lane0` is not
# identically zero and `w_be` genuinely masks half the group.  Several
# mutants are UNREACHABLE at SWG_LANES = 8 and reachable here, and saying so
# is the point of running it.
QUART="-gSWG_LANES=4 -gSWG_WIDE=true"
# MEASURED 2026-09-19 by TRACK SWGREAL on the NARROW tree, and reproduced by
# the wide arm on 2026-09-20.  Duplicated from the wrappers deliberately: a
# row that read them out of the wrapper would move with the wrapper.
LAND="-gEXP_X0=10238 -gEXP_XSUM=87031 -gEXP_XALL=65159 -gEXP_STEPH=35900"
STOP=900ms

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
# mutate_n <tag> <old> <new> <count> [<old2> <new2> <count2>]
# REQUIRED occurrence count, so a partial edit is an error and not a verdict.
# ---------------------------------------------------------------------------
mutate_n() {
  local tag="$1"; shift
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - rtl/llama_top.vhd "$dir/llama_top.vhd" "$@" <<'PY'
import sys
src, dst = sys.argv[1:3]
rest = sys.argv[3:]
s = open(src).read()
while rest:
    old, new, want = rest[0], rest[1], int(rest[2]); rest = rest[3:]
    n = s.count(old)
    if n != want:
        sys.stderr.write("ANCHOR MATCHED %d TIMES, REQUIRED %d\n" % (n, want))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
  [ $? -ne 0 ] && { echo ""; return; }
  echo "$dir"
}

# ---------------------------------------------------------------------------
# row <tag> <desc> <mutdir|""> <generics...>
# THE VERDICT IS THREE-WAY.  A run that DIED printed no RESULT line, and
# folding that into KILLED credits the value gate with a detection the
# SIMULATOR made.
# ---------------------------------------------------------------------------
row() {
  local tag="$1" desc="$2" mutdir="$3"; shift 3
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir/run"
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
    | head -1 | sed 's/^/        /' | cut -c1-200
  grep -a "group WRITE port\|group READ port\|region lock" "$dir/run/run.log" \
    | head -1 | sed 's/^/        GUARD: /' | cut -c1-160
  grep -a "token 2 descriptor" "$dir/run/run.log" | head -1 \
    | sed 's/^.*completions, /        cycles(3 tokens) /' | cut -c1-80
}

# ---- the anchors, each written once so a row and its controls cannot drift.
S_BE_OLD="                         and (kw*SWG_GRP + i - lane0) < n then"
S_BE_NEW="                         and (kw*SWG_GRP + i - lane0) <= n then"
S_BEALL_OLD="                      if i >= lane0 and i < lane0 + SWG_GRP
                         and (kw*SWG_GRP + i - lane0) < n then"
S_BEALL_NEW="                      if true then"
S_RDA_OLD="                    swr_addr <= to_unsigned((k*SWG_GRP)/LANES, GA_W);"
S_RDA_NEW="                    swr_addr <= to_unsigned(k, GA_W);"
S_WRA_OLD="                    sw_addr <= to_unsigned((kw*SWG_GRP)/LANES, GA_W);"
S_WRA_NEW="                    sw_addr <= to_unsigned(kw, GA_W);"
S_GWA_OLD="                                 to_unsigned((k-2)*SWG_GRP, LOG2N));"
S_GWA_NEW="                                 to_unsigned(k-2, LOG2N));"
S_SKEW_OLD="                        <= x_rdata((lane0+i+1)*MANT_W-1
                                   downto (lane0+i)*MANT_W);"
S_SKEW_NEW="                        <= x_rdata((lane0+i+2)*MANT_W-1
                                   downto (lane0+i+1)*MANT_W);"
S_GU_OLD="                      gw_u((i+1)*MANT_W-1 downto i*MANT_W)
                        <= e_rdata((lane0+i+1)*MANT_W-1"
S_GU_NEW="                      gw_u((i+1)*MANT_W-1 downto i*MANT_W)
                        <= x_rdata((lane0+i+1)*MANT_W-1"
S_TAG_OLD="      w_we   <= sw_we;
      wg_reg <= v_reg_d;"
S_TAG_NEW="      w_we   <= sw_we;
      wg_reg <= aw_reg;"
S_WSEL_OLD="    elsif SWG_WIDE and act_unit = U_V and act_vop = V_SWG then"
S_WSEL_NEW="    elsif SWG_WIDE and act_unit = U_V then"
S_RSEL_OLD="    if SWG_WIDE and act_unit = U_V and act_vop = V_SWG then
      r_en   <= swr_en;"
S_RSEL_NEW="    if SWG_WIDE and act_unit = U_V then
      r_en   <= swr_en;"
S_LAST_OLD="                    if kw = ng-1 then kw := 0; st := S_DONE;"
S_LAST_NEW="                    if kw = ng-2 then kw := 0; st := S_DONE;"
S_ORA_OLD="                    o_ra <= std_logic_vector(to_unsigned(k*SWG_GRP, LOG2N));"
S_ORA_NEW="                    o_ra <= std_logic_vector(to_unsigned(k, LOG2N));"
S_NG_OLD="                  ng   := n / SWG_GRP;"
S_NG_NEW="                  ng   := n / LANES;"
# `greq` DISABLED WHOLE, for the _G attribution control ONLY.  Defanging one
# assert would be the wrong control: the six properties catch different
# clients, so a mutant that trips the fourth would still die with the first
# downgraded and the table would credit an older guard.  The clock edge is
# replaced instead, so the process never runs at all.
S_GREQ_OLD="  greq : process(clk) is
    variable nw : natural;
    variable a_sel, s_sel : boolean;
  begin
    if rising_edge(clk) then"
S_GREQ_NEW="  greq : process(clk) is
    variable nw : natural;
    variable a_sel, s_sel : boolean;
  begin
    if false then"

trio() {   # trio <tag> <desc> <old> <new> <count>
  local tag="$1" desc="$2" old="$3" new="$4" want="$5"
  local D
  D=$(mutate_n "$tag" "$old" "$new" "$want")
  [ -n "$D" ] || { echo "$tag  ANCHOR FAILED -- $desc"; return; }
  row "$tag"     "$desc"                                        "$D" $G_SWG $WIDE   $LAND
  row "${tag}_N" "  control: same mutation, SWG_WIDE FALSE, SWG_LANES still 8" "$D" $G_SWG $NARROW $LAND
  row "${tag}_X" "  control: same mutation, wide, landmarks UNSET" "$D" $G_SWG $WIDE
}

quart() {  # quart <tag> <desc> <old> <new> <count> -- the SWG_LANES = 4 arm
  local tag="$1" desc="$2" old="$3" new="$4" want="$5"
  local D
  D=$(mutate_n "${tag}_q" "$old" "$new" "$want")
  [ -n "$D" ] || { echo "${tag}_Q  ANCHOR FAILED -- $desc"; return; }
  row "${tag}_Q" "  SWG_LANES = 4 (sub-group): $desc" "$D" $G_SWG $QUART $LAND
}

echo "=== teeth for the SwiGLU on the group ports (lever L2) ==="
echo "scratch: $SCRATCH"
build_base
echo "base library analysed"
echo
echo "--- controls: the clean design must PASS on all three configurations ---"
row S0w "CONTROL: clean, SWG_LANES 8 SWG_WIDE true,  four landmarks pinned" "" $G_SWG $WIDE   $LAND
row S0n "CONTROL: clean, SWG_LANES 8 SWG_WIDE false, four landmarks pinned" "" $G_SWG $NARROW $LAND
row S0q "CONTROL: clean, SWG_LANES 4 SWG_WIDE true,  four landmarks pinned" "" $G_SWG $QUART  $LAND

echo
echo "--- the lane enables ---"
trio M1_be_tail "w_be enabled one element PAST the vector (kw*GRP+i-lane0 <= n)" \
     "$S_BE_OLD" "$S_BE_NEW" 1
quart M1_be_tail "w_be one element past the vector" "$S_BE_OLD" "$S_BE_NEW" 1
trio M2_be_all "every lane of the group enabled: the mask removed entirely" \
     "$S_BEALL_OLD" "$S_BEALL_NEW" 1
quart M2_be_all "the lane mask removed entirely" "$S_BEALL_OLD" "$S_BEALL_NEW" 1

echo
echo "--- the address stride, load side ---"
trio M3_rd_stride "the group READ address drops the SWG_GRP/LANES stride" \
     "$S_RDA_OLD" "$S_RDA_NEW" 1
quart M3_rd_stride "the group READ address drops the stride" "$S_RDA_OLD" "$S_RDA_NEW" 1

echo
echo "--- the address stride, store side ---"
trio M4_wr_stride "the group WRITE address drops the SWG_GRP/LANES stride" \
     "$S_WRA_OLD" "$S_WRA_NEW" 1
quart M4_wr_stride "the group WRITE address drops the stride" "$S_WRA_OLD" "$S_WRA_NEW" 1

echo
echo "--- swiglu_mem's own bank offset ---"
trio M5_gw_addr "gw_addr drops the SWG_GRP factor: every beat writes bank offset k-2" \
     "$S_GWA_OLD" "$S_GWA_NEW" 1

echo
echo "--- the lane slice out of the group read ---"
trio M6_lane_skew "the x_rdata lane slice skewed by one mantissa" \
     "$S_SKEW_OLD" "$S_SKEW_NEW" 1

echo
echo "--- the operand pairing ---"
trio M7_swap_gu "gw_u fed from x_rdata: U is loaded with G" \
     "$S_GU_OLD" "$S_GU_NEW" 1

echo
echo "--- the region tag on the group write port ---"
trio M8_region_tag "wg_reg reads aw_reg in the SwiGLU arm: the write is TAGGED as A's" \
     "$S_TAG_OLD" "$S_TAG_NEW" 1

echo
echo "--- the mux selectors: the DROPPED-REQUEST class `greq` was written for ---"
D=$(mutate_n M9_wmux_sel "$S_WSEL_OLD" "$S_WSEL_NEW" 1)
if [ -n "$D" ]; then
  row M9_wmux_sel   "the group WRITE mux selects on act_unit alone, dropping act_vop" "$D" $G_SWG $WIDE $LAND
  row M9_wmux_sel_N "  control: same mutation, SWG_WIDE FALSE" "$D" $G_SWG $NARROW $LAND
  row M9_wmux_sel_X "  control: same mutation, wide, landmarks UNSET" "$D" $G_SWG $WIDE
else echo "M9_wmux_sel  ANCHOR FAILED"; fi
D=$(mutate_n M9g_wmux_sel "$S_WSEL_OLD" "$S_WSEL_NEW" 1 "$S_GREQ_OLD" "$S_GREQ_NEW" 1)
if [ -n "$D" ]; then
  row M9_wmux_sel_G "  control: same mutation, wide, landmarks UNSET, greq DISABLED WHOLE" "$D" $G_SWG $WIDE
else echo "M9_wmux_sel_G  ANCHOR FAILED"; fi

D=$(mutate_n M10_rmux_sel "$S_RSEL_OLD" "$S_RSEL_NEW" 1)
if [ -n "$D" ]; then
  row M10_rmux_sel   "the group READ mux selects on act_unit alone, dropping act_vop" "$D" $G_SWG $WIDE $LAND
  row M10_rmux_sel_N "  control: same mutation, SWG_WIDE FALSE" "$D" $G_SWG $NARROW $LAND
  row M10_rmux_sel_X "  control: same mutation, wide, landmarks UNSET" "$D" $G_SWG $WIDE
else echo "M10_rmux_sel  ANCHOR FAILED"; fi
D=$(mutate_n M10g_rmux_sel "$S_RSEL_OLD" "$S_RSEL_NEW" 1 "$S_GREQ_OLD" "$S_GREQ_NEW" 1)
if [ -n "$D" ]; then
  row M10_rmux_sel_G "  control: same mutation, wide, landmarks UNSET, greq DISABLED WHOLE" "$D" $G_SWG $WIDE
else echo "M10_rmux_sel_G  ANCHOR FAILED"; fi

echo
echo "--- the final beat ---"
trio M11_last_beat "the write-back ends one beat early (kw = ng-2)" \
     "$S_LAST_OLD" "$S_LAST_NEW" 1

echo
echo "--- the read-back address ---"
trio M12_ora_stride "o_ra drops the SWG_GRP factor on the read-back" \
     "$S_ORA_OLD" "$S_ORA_NEW" 1

echo
echo "--- the beat count: a no-op at SWG_GRP = LANES by construction ---"
trio M13_ng "ng computed from LANES rather than SWG_GRP" \
     "$S_NG_OLD" "$S_NG_NEW" 1
quart M13_ng "ng from LANES rather than SWG_GRP" "$S_NG_OLD" "$S_NG_NEW" 1

echo
echo "done.  scratch: $SCRATCH"
