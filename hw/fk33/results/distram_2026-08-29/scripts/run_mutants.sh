#!/usr/bin/env bash
# run_mutants.sh -- TRACK DISTRAM, 2026-08-29.  TEETH.
#
# A checker never shown to fail has not been shown to work.  Each mutation
# below perturbs ONE thing the distributed-RAM conversion introduced -- a lane
# index, a bank index, a head address, a write enable -- and the shadow-DUT
# bench must kill it.  The UNMUTATED control is run first and must PASS or the
# table means nothing.
#
# SCORING, and the two rules that were learned the hard way on this project:
#   * an anchor that is not UNIQUE scores VOID(anchor), never CAUGHT -- a
#     replace with a non-unique anchor mutates more than intended and the
#     verdict is then about a different mutant than the one named;
#   * an ANALYSIS or ELABORATION failure scores VOID, never CAUGHT.  TRACK
#     WRITEDEC's first mutant script scored all seven CAUGHT because ghdl
#     could not open a file.
#
# NO HARDWARE.  Simulation only.
set -u
REPO=/home/orencollaco/GitHub/llama.vhdl
RES=$REPO/hw/fk33/results/distram_2026-08-29
SRC="${1:?usage: run_mutants.sh <gdn_block variant.vhd> <scratch>}"
SCR="${2:?}"
mkdir -p "$SCR"

# NEVER `rm` a path built from a shell variable (standing rule, 2026-08-29).
# Every run and every mutant tree therefore gets a FRESH mktemp directory and
# nothing is ever deleted by this script.
run_one () {   # name  rtldir
  local name="$1" rtl="$2" w
  w=$(mktemp -d "$SCR/w_${name}_XXXXXX")
  bash "$RES/scripts/run_equiv.sh" "$w" "$rtl" > "$SCR/log_$name.txt" 2>&1
  if grep -q 'ANALYSIS STUCK\|ANALYSIS_FAILED' "$SCR/log_$name.txt"; then
      echo "VOID(analysis)"; return
  fi
  if ! grep -q 'GHDL_EXIT=' "$SCR/log_$name.txt"; then echo "VOID(no-exit)"; return; fi
  if grep -q 'DISTRAM_OVERALL PASS' "$SCR/log_$name.txt"; then echo "NOT CAUGHT"; return; fi
  if grep -q 'DISTRAM MISMATCH\|DISTRAM: ' "$SCR/log_$name.txt"; then echo "CAUGHT"; return; fi
  # a bounds check or an unrelated hard assert is still a kill, but it is a
  # DIFFERENT kill and is named as such
  echo "CAUGHT(other: $(grep -m1 -aiE 'error|failure|bound check' "$SCR/log_$name.txt" | cut -c1-90))"
}

mutate () {    # name  needle  replacement
  local name="$1" needle="$2" repl="$3"
  local rtl
  rtl=$(mktemp -d "$SCR/rtl_${name}_XXXXXX")
  cp "$REPO"/rtl/*.vhd "$rtl"/
  cp "$SRC" "$rtl/gdn_block.vhd"
  # The uniqueness check MUST count SUBSTRING occurrences, not matching lines.
  # MEASURED trap, 2026-08-29: `grep -c -F` on a MULTI-LINE needle counts the
  # lines it matched, so a genuinely unique two-line anchor scored
  # VOID(anchor x3) and a real mutation was lost.
  local n
  n=$(python3 -c 'import sys;print(open(sys.argv[1]).read().count(sys.argv[2]))' "$rtl/gdn_block.vhd" "$needle")
  if [ "$n" != "1" ]; then printf '%-18s : VOID(anchor x%s)\n' "$name" "$n"; return; fi
  python3 - "$rtl/gdn_block.vhd" "$needle" "$repl" <<'PY'
import sys
p,a,b=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read(); assert s.count(a)==1
open(p,'w').write(s.replace(a,b))
PY
  printf '%-18s : %s\n' "$name" "$(run_one "$name" "$rtl")"
}

echo "== TRACK DISTRAM mutation table, src=$SRC"
# ---- the control.  Unmutated.  Must PASS. --------------------------------
CTL=$(mktemp -d "$SCR/rtl_control_XXXXXX")
cp "$REPO"/rtl/*.vhd "$CTL"/; cp "$SRC" "$CTL/gdn_block.vhd"
printf '%-18s : %s\n' "control" "$(run_one control "$CTL")"

# ---- lever 2a, vbuf ------------------------------------------------------
mutate v_lane_off  "vlane    := vidx mod CONV_LANES;" "vlane    := (vidx+1) mod CONV_LANES;"
mutate v_lane_zero "vlane    := vidx mod CONV_LANES;" "vlane    := 0;"
mutate v_word_off  "vword    := vidx / CONV_LANES;"   "vword    := (vidx / CONV_LANES + 1) mod NBV;"
mutate v_wr_seg    "and cv_seg_i > 1 and obeat < NBV then" "and cv_seg_i > 0 and obeat < NBV then"
mutate v_noguard   "and cv_seg_i > 1 and obeat < NBV then" "and cv_seg_i > 1 and obeat <= NBV-1 then"

# ---- lever 2b, knb / qsb -------------------------------------------------
mutate b_swap      "rp_kn      <= knb(vh mod KEY_HEADS);" "rp_kn      <= qsb(vh mod KEY_HEADS);"
mutate b_head_off  "rp_qs      <= qsb(vh mod KEY_HEADS);" "rp_qs      <= qsb((vh+1) mod KEY_HEADS);"
mutate b_wr_qk     "and l2_qk = '0' and kh < KEY_HEADS then" "and l2_qk = '1' and kh < KEY_HEADS then"

# ---- lever 2c, qbuf / kbuf ----------------------------------------------
mutate c_bank_off  "qbuf(j)(obeat / NBH) <= co_data;" "qbuf(j)((obeat / NBH + 1) mod KEY_HEADS) <= co_data;"
mutate c_kh_off    "khr := kh mod KEY_HEADS;" "khr := (kh+1) mod KEY_HEADS;"
mutate c_qk_swap   "                  <= qbuf(j)(khr);" "                  <= kbuf(j)(khr);"
mutate c_gather_rev "l2_x((j+1)*CONV_LANES*16-1 downto j*CONV_LANES*16)
                  <= qbuf(j)(khr);" "l2_x((NBH-j)*CONV_LANES*16-1 downto (NBH-1-j)*CONV_LANES*16)
                  <= qbuf(j)(khr);"

# ---- the guards the memory index needs, removed OUTRIGHT ----------------
# v_noguard above is a NO-OP BY CONSTRUCTION and is reported as such: it
# rewrites `obeat < NBV` as `obeat <= NBV-1`, which is the same condition.
# These two delete the guard instead, which is what the row was meant to test.
mutate v_noguard_real "and cv_seg_i > 1 and obeat < NBV then" "and cv_seg_i > 1 then"
mutate c_noguard_real "and cv_seg_i = 0 and obeat < NBQ and (obeat mod NBH) = j then" "and cv_seg_i = 0 and (obeat mod NBH) = j then"
echo "== end"
