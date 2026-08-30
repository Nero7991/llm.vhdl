#!/usr/bin/env bash
# sim/mutate_attn_block.sh -- does sim/tb_attn_block.vhd's P8, the block-level
# bit-exact oracle comparison, actually DISCRIMINATE on the SEAM 2 v_ref fold?
#
# WHY THIS EXISTS.  On 2026-08-30 TRACK TIMING reassociated the SEAM 2
# write-time min fold in rtl/attn_block.vhd, teeth-checked the change, and
# found that THIS UNIT'S OWN BENCH -- the one carrying subsystem C's bit-exact
# C oracle, its header saying "P8 THE VALUES, BIT-EXACTLY" -- PASSED a
# deliberately broken tree.  TRACK ATTNTEETH reproduced that and named the
# mechanism: it was never in the bench.  `ref/attn_block_vec.c` drew every V
# element uniformly on [-2048, 2047], so every block of a head had its peak in
# the top binade, `kv_quant` gave all NBLK blocks THE SAME EXPONENT (MEASURED:
# 6 6 6 6 on both heads), and v_ref is the MINIMUM over those exponents.  A
# minimum over a constant vector is that constant.  P8 compared the right
# numbers with no tolerance and could not have disagreed whatever the fold did.
#
# This is the second time this unit's evidence has been shown not to
# discriminate -- see CLAUDE.md on `attn_block` passing seven properties and 13
# of 17 wiring mutations while computing wrong numbers -- so the mutation table
# lives in the tree from now on instead of in one track's write-up.
#
# WHAT IT MEASURES.  Nine one-line mutations of the fold and its surroundings,
# every one well-formed VHDL and in bounds, so a KILL is the checker noticing
# and not the language noticing.  Plus TWO CONTROLS that are the point of the
# exercise:
#
#   C1  the ATTRIBUTION control: every mutant re-run with P9's verdict
#       DISABLED.  P9 is the new check and it must not be credited with kills
#       that P8 makes on its own.  MEASURED 2026-08-30: it is credited with
#       NONE.  P9 kills nothing; the stimulus does the work and P8 does the
#       killing.  That is the honest reading and it is why P9's justification
#       is stated as a stimulus GATE and not as a detector.
#   C2  P9's OWN teeth-check: the taper in ref/attn_block_vec.c reverted to the
#       flat draw, with the RTL honest.  P9 must FAIL there, or it is
#       decoration.  A check never shown to fail has not been shown to work.
#
# SURVIVORS ARE REPORTED UNDER THEIR OWN NAMES and are the most valuable rows
# here: they are this bench's resolution floor.  Do not delete one.
#
# Usage:  bash sim/mutate_attn_block.sh
# Env:    SCRATCH=<dir>   MUT_NO_REEXEC=1
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it runs, so editing
# this file while an instance is running corrupts that run silently, and the
# one who gets hit is not the one who edited it.  Same guard, same reasons, as
# sim/regress.sh and sim/mutate_attn_kv_seam.sh.
if [ -z "${MUT_REPO:-}" ]; then
  MUT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUT_REPO
fi
if [ -z "${MUT_SELF:-}" ] && [ -z "${MUT_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutself.XXXXXXXX.sh)" || exit 2
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

MUTV="$MUT_REPO/sim/mutverdict.py"
cd "$MUT_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

# Must match sim/tb_attn_block.vhd's generic defaults and sim/regress.sh's
# tb_vector_args row; the vector file carries a shape header the bench asserts
# against them, so a mismatch is loud rather than a wrong answer.
VECARGS="16 4 2 4 8 3 4 0"

FILES="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
       rtl/attn_emit.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd
       rtl/attn_mac_array.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
       rtl/attn_softmax.vhd rtl/divider_rs.vhd rtl/imrope_pkg.vhd
       rtl/rmsnorm_rs.vhd rtl/attn_recip.vhd rtl/attn_twiddle.vhd
       rtl/attn_block.vhd sim/tb_attn_block.vhd"

STOP=900ms
NKILL=0; NABORT=0; NSURV=0; NTOT=0

# ---------------------------------------------------------------------------
# mutate <tag> <file> <old> <new>  -- scratch copy of ONE file, echoes its dir.
# The anchor must match EXACTLY ONCE or the mutation is refused: an anchor that
# matched zero times would run the honest design and score as a SURVIVOR, which
# is the single easiest way to fake a resolution floor.
# ---------------------------------------------------------------------------
mutate() {
  local tag="$1" file="$2" old="$3" new="$4"
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$file" "$dir/$(basename "$file")" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  [ $? -ne 0 ] && { echo ""; return; }
  echo "$dir"
}

# ---------------------------------------------------------------------------
# run_case <tag> <desc> <mutdir-or-empty> <genc>  -- <genc> is the oracle
# source to build the vector generator from, so C2 can swap the STIMULUS while
# leaving the RTL honest.
# ---------------------------------------------------------------------------
run_case() {
  local tag="$1" desc="$2" mutdir="$3" genc="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir/run"
  if ! cc -O2 -w -I ref -o "$dir/gen" "$genc" -lm >"$dir/cc.log" 2>&1; then
    echo "$tag  ORACLE DID NOT BUILD   -- $desc"; return
  fi
  if ! ( cd "$dir/run" && "$dir/gen" attn_block_vec.txt $VECARGS ) \
       >"$dir/gen.log" 2>&1; then
    echo "$tag  VECGEN REFUSED (rc=$?)   -- $desc"
    tail -2 "$dir/gen.log" | sed 's/^/        /'; return
  fi
  local f src
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)   -- $desc"
      sed -n 1,4p "$dir/analyze.log"; return
    fi
  done
  ( cd "$dir/run" && timeout -k 5 900 ghdl -r --std=08 -frelaxed \
      --workdir=.. tb_attn_block --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  local rcv=$? v
  v=$(python3 "$MUTV" "$dir/run/run.log" tb_attn_block "$rcv")
  if [ "$v" = PASS ]; then
    # The ANCHOR is not a mutant, so it is reported as PASS and not counted as
    # a survivor.  A row labelled SURVIVED next to an honest tree reads like a
    # miss, and the whole value of this table is in its survivor column.
    if [ "$tag" = A0 ]; then
      echo "$tag  PASS (anchor)   -- $desc"; return
    fi
    NSURV=$((NSURV+1)); echo "$tag  SURVIVED   -- $desc"
  elif [ "$v" = KILLED ]; then
    NKILL=$((NKILL+1)); echo "$tag  KILLED     -- $desc"
    grep -vE "metavalue" "$dir/run/run.log" \
      | grep -E "P8 --|P9 --|RESULT bad" | grep -E "MISMATCH|differ|UNOBSERVABLE|by accident|fixed element|not observed" \
      | head -1 | sed 's/^/        /' | cut -c1-170
  else
    NABORT=$((NABORT+1)); echo "$tag  ABORT (${v#ABORT:})   -- $desc"
    echo "        the run DIED before the checker reached a verdict, so the"
    echo "        checker was NOT shown to catch this.  Not counted as a kill."
    tail -2 "$dir/run/run.log" | sed 's/^/        /' | cut -c1-170
  fi
}

GEN="ref/attn_block_vec.c"

# ---- the P9-disabled build of the bench, used by every C1 row ---------------
# It removes only P9's contribution to `nerr`; the reports stay, so the control
# run still prints what P9 saw while no longer being able to fail the bench.
CTL="$SCRATCH/ctl_src"; rm -rf "$CTL"; mkdir -p "$CTL"
python3 - sim/tb_attn_block.vhd "$CTL/tb_attn_block.vhd" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
out, n = [], 0
for i, l in enumerate(lines):
    if l.strip() == "nerr := nerr + 1;" and 'P9 --' in '\n'.join(lines[i+1:i+4]):
        out.append(l.replace("nerr := nerr + 1;",
                             "null;  -- ATTRIBUTION CONTROL: P9 disabled"))
        n += 1
    else:
        out.append(l)
if n != 5:
    sys.stderr.write("expected 5 P9 verdict sites, neutered %d\n" % n)
    sys.exit(2)
open(dst, 'w').write('\n'.join(out))
PY
[ $? -ne 0 ] && { echo "could not build the P9-disabled control"; exit 2; }

# ---- the flat-stimulus oracle, used by C2 ----------------------------------
# The taper reverted to what stood before 2026-08-30, with the generator's own
# refusal REMOVED so the flat file is actually written.  Everything else,
# including the arithmetic, is untouched.
FLAT="$SCRATCH/flat_gen.c"
python3 - ref/attn_block_vec.c "$FLAT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
a = s.index("    for (h = 0; h < N_KVH; h++) {\n        for (b = 0; b < NBLK; b++) {\n            t = ((NBLK - 1 - b)")
b = s.index("    /* ------------------------------------------------------------------\n     * The taper's PROPERTY")
c = s.index("    /* One token, with a SYNTHETIC cache and no append.")
s = (s[:a]
     + "    for (i = 0; i < N * N_KVH; i++) vin[i] = m12(65537 + SEED, i);\n"
       "    (void)t; (void)d; (void)j;\n\n"
     + s[c:])
open(dst, 'w').write(s)
PY
[ $? -ne 0 ] && { echo "could not build the flat-stimulus oracle"; exit 2; }

echo "=========================================================================="
echo " ANCHOR -- the honest tree.  Must PASS, or every row below is meaningless."
echo "=========================================================================="
run_case A0 "honest rtl/attn_block.vhd, tapered stimulus" "" "$GEN"

echo
echo "=========================================================================="
echo " THE FOLD MUTANTS, against sim/tb_attn_block.vhd as it now stands"
echo "=========================================================================="

M1=$(mutate M1 rtl/attn_block.vhd \
  "    for s in 0 to LG-1 loop" "    for s in 0 to LG-2 loop")
run_case M1 "emin_tree drops its LAST combining stage (TRACK TIMING's mutant)" "$M1" "$GEN"

M2=$(mutate M2 rtl/attn_block.vhd \
  "    return a(0);
  end function;

  function all_ones" "    return e_of(v,0);
  end function;

  function all_ones")
run_case M2 "emin_tree does not reduce at all -- returns block 0's exponent" "$M2" "$GEN"

M3=$(mutate M3 rtl/attn_block.vhd \
  "        if a(i + 2**(LG-1-s)) < a(i) then" \
  "        if a(i + 2**(LG-1-s)) > a(i) then")
run_case M3 "emin_tree computes the MAXIMUM instead of the minimum" "$M3" "$GEN"

M4=$(mutate M4 rtl/attn_block.vhd \
  "      else             a(i) := e_of(v, 0);" \
  "      else             a(i) := to_signed(127, EXP_W);")
run_case M4 "the power-of-two PAD repeats 127 rather than element 0" "$M4" "$GEN"

M5=$(mutate M5 rtl/attn_block.vhd \
  "              if evh < ev then ev := evh; end if;
              vref_r(lay_r*N_KVH + kvh) <= ev;" \
  "              vref_r(lay_r*N_KVH + kvh) <= ev;")
run_case M5 "the fold's result is never folded IN -- v_ref stays at its reset 127" "$M5" "$GEN"

M6=$(mutate M6 rtl/attn_block.vhd \
  "              ev  := vref_r(lay_r*N_KVH + kvh);
              if evh < ev then ev := evh; end if;" \
  "              ev  := evh;")
run_case M6 "v_ref becomes a per-TOKEN minimum, not a per-SEQUENCE one" "$M6" "$GEN"

M7=$(mutate M7 rtl/attn_block.vhd \
  "              ev  := vref_r(lay_r*N_KVH + kvh);
              if evh < ev then ev := evh; end if;
              vref_r(lay_r*N_KVH + kvh) <= ev;" \
  "              ev  := vref_r(kvh);
              if evh < ev then ev := evh; end if;
              vref_r(kvh) <= ev;")
run_case M7 "defect C1 restored: one v_ref SHARED across layers" "$M7" "$GEN"

M8=$(mutate M8 rtl/attn_block.vhd \
  "      if i < NBLK then a(i) := e_of(v, i);" \
  "      if i < NBLK-1 then a(i) := e_of(v, i);")
run_case M8 "the fold silently drops the LAST block exponent of the header" "$M8" "$GEN"

M9=$(mutate M9 rtl/attn_emit.vhd \
  "            if e_l(grp) < e_min then" \
  "            if e_l(grp) > e_min then")
run_case M9 "attn_emit takes the MAXIMUM over e_grid, not the minimum" "$M9" "$GEN"

M10=$(mutate M10 rtl/attn_emit.vhd \
  "            sh_v := to_integer(e_l(grp)) - to_integer(e_min);" \
  "            sh_v := 0;")
run_case M10 "attn_emit's per-group alignment shift is forced to zero" "$M10" "$GEN"

echo
echo "=========================================================================="
echo " C1 -- ATTRIBUTION CONTROL.  Every kill above, re-run with P9's verdict"
echo " DISABLED.  A kill that stands here belongs to P8, NOT to P9."
echo "=========================================================================="
for t in M1 M2 M3 M4 M5 M6 M7 M8 M9 M10; do
  src="$SCRATCH/${t}_src"
  [ -d "$src" ] || continue
  cp "$CTL/tb_attn_block.vhd" "$src/tb_attn_block.vhd"
  run_case "C1$t" "$t with P9 disabled" "$src" "$GEN"
done

echo
echo "=========================================================================="
echo " C2 -- P9's OWN teeth-check.  Honest RTL, FLAT stimulus (the pre-2026-08-30"
echo " draw).  P9 must KILL this, or P9 is decoration.  P8 will pass: both sides"
echo " read the same file, so a degenerate stimulus is not an arithmetic error."
echo "=========================================================================="
run_case C2 "honest RTL, flat V stimulus -- P9 must fire" "" "$FLAT"

echo
echo "=========================================================================="
printf " TOTAL %d   KILLED %d   SURVIVED %d   ABORT %d\n" \
       "$NTOT" "$NKILL" "$NSURV" "$NABORT"
echo
echo " SURVIVORS ARE THE POINT.  Read them, do not delete them.  As of"
echo " 2026-08-30 the expected survivors and WHY are:"
echo "   M4  the pad branch is UNREACHABLE: NBLK = HEAD_DIM/KV_BLOCK is a power"
echo "       of two at every shape in this repo (4, 4, 8), so PW = NBLK and the"
echo "       else-branch never executes.  Dead code, not a missed defect."
echo "   M6  one token per sequence in this bench, so the carry-in term is"
echo "       always the reset 127 and dropping it changes nothing."
echo "       sim/tb_attn_kv_seam.vhd owns this one and KILLS it."
echo "   M7  one layer per run in this bench, so lay_r is always 0."
echo "       sim/tb_attn_kv_seam.vhd owns this one too (NLAY = 2) and KILLS it."
echo "   every C1 row that KILLED -- that is the control working: the kill"
echo "       belongs to P8.  P9 is credited with none of them."
echo "=========================================================================="
[ "$NABORT" -eq 0 ] || exit 1
exit 0
