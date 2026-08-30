#!/usr/bin/env bash
# TEETH FOR THE TOP-LEVEL VALUE GATE (P14) -- sim/tb_llama_top.vhd's four
# EXP_* landmarks.
#
# WHY THIS IS A SEPARATE FILE AND NOT MORE ROWS IN sim/mutate_llama_top_kv.sh.
# That file's 23 rows and their recorded verdicts are a measurement of the
# STRUCTURAL checkers' resolution floor, taken over two days and quoted in two
# write-ups.  Adding a value gate to the entity changes what several of those
# rows would report, so folding these rows in would silently re-base a table
# whose whole worth is that it is comparable with its own history.  This file
# asks one question instead: DOES THE NEW GATE FIRE, AND ON WHAT.
#
# THE QUESTION IT EXISTS TO ANSWER.  Before 2026-08-29 the whole
# `tb_llama_top*` family scored a run on STRUCTURE -- schedule, skew across
# latency points, degenerate residuals, KV placement -- and printed the
# numbers without comparing them.  MEASURED, and reproduced by this track at
# commit 4736950: `tb_llama_top_seq` PASSES with `rtl/attn_block.vhd`'s v_ref
# fold reverted to defect C1, and PASSES again with the fold collapsed to a
# single register shared across every layer AND every KV head.  A checker
# never shown to fail has not been shown to work.
#
# EVERY ROW BELOW IS EITHER A KILL THE GATE MUST MAKE OR A CONTROL, and the
# rows that do NOT bite are reported under their own names, because they are
# what fixes the gate's resolution floor.
#
# Usage:  bash sim/mutate_llama_top_land.sh
# Env:    SCRATCH=<dir>   ONLY="<tag> <tag> ..."   (EXACT tags, space separated)
#
# NO HARDWARE.  GHDL only.  Nothing here opens a device, a cable or Vivado.
set -uo pipefail

# SELF-ISOLATION, for the reason sim/regress.sh:287 and
# sim/mutate_llama_top_kv.sh both record: bash reads a script by BYTE OFFSET
# as it executes, so an edit under a running instance resumes it mid-token.
if [ -z "${MUTLD_REPO:-}" ]; then
  MUTLD_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUTLD_REPO
fi
if [ -z "${MUTLD_SELF:-}" ] && [ -z "${MUTLD_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutld-self.XXXXXXXX.sh)" || exit 2
  cat "${BASH_SOURCE[0]}" > "$_self" || { rm -f "$_self"; exit 2; }
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "mutate_llama_top_land.sh: the private copy does not parse -- it was" >&2
    echo "  probably being written as it was copied.  Try again." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUTLD_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi
trap 'rm -f "${MUTLD_SELF:-}"' EXIT

cd "$MUTLD_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"

FILES=$(sed -n '/^FILES="/,/"$/p' sim/mutate_llama_top_kv.sh | sed 's/FILES="//; s/"$//')
[ -n "$FILES" ] || { echo "could not read FILES from sim/mutate_llama_top_kv.sh"; exit 2; }

# The two configurations, spelled exactly as the wrappers spell them so a
# landmark measured here is the landmark the GATE ROW checks.  Kept in one
# place because two copies of a generic set is how a landmark goes stale
# against a shape nobody changed.
G_SEQ="-gBLOCKS=4 -gATTN_INT=2 -gNRUNS=2 -gNTOK=3 -gC_REAL=true
       -gATTN_HD=64 -gKV_BLOCK=16 -gN_ROT=16 -gMAXPOS=8 -gKV_AXI=true"
G_REAL="-gBLOCKS=4 -gATTN_INT=4 -gNRUNS=2 -gC_REAL=true -gATTN_HD=16
        -gNORM_REAL=true -gNORM_ANCHOR=false
        -gW_IMAGE=llama_top_w_b4_pool.hex"
STOP=900ms

# THE LANDMARKS, spelled here exactly as the wrappers pin them.  MEASURED
# 2026-08-29 at commit 35e0ed0 on the unmutated tree.  Duplicated from the
# wrappers deliberately: a row that read them out of the wrapper would move
# with the wrapper and could never notice a wrapper that had been widened.
# RE-PINNED 2026-08-29 by TRACK BTOP1 with sim/tb_llama_top_seq.vhd, which
# holds the same four values as generics.  BOTH COPIES HAVE TO MOVE TOGETHER:
# re-pinning only the bench leaves P0s -- the control that says the CLEAN
# design passes -- red, which is the most misleading state this table can be
# in.  Old values: -14252 / 7668 / 96762 / 57526.  Why they moved: defect
# B-TOP-1, docs/debugging/2026-08-29_btop1-b-recurrence.md.
LAND_SEQ="-gEXP_X0=-732 -gEXP_XSUM=86454 -gEXP_XALL=79978 -gEXP_STEPH=50729"
LAND_REAL="-gEXP_X0=-16364 -gEXP_XSUM=91622 -gEXP_XALL=91622 -gEXP_STEPH=17333"
# The same three R_X landmarks with EXP_STEPH left at its sentinel.  This is
# P3x's whole point; see the comment on P3.
LAND_REAL_NOSTEP="-gEXP_X0=-16364 -gEXP_XSUM=91622 -gEXP_XALL=91622"

# ---------------------------------------------------------------------------
# mutate_n <tag> <file> <old> <new> <count>  -- REQUIRED occurrence count.
# ---------------------------------------------------------------------------
# The count is not decoration.  `vref_r` is indexed at FOUR sites spelled TWO
# different ways -- three as `lay_r*N_KVH + kvh` and one as `lay_r*N_KVH + h`
# -- so an anchor matching one spelling changes three of four and yields a
# design that is neither correct nor the defect.  A kill on that says nothing.
# TRACK C-SEAM added the same guard to its own harness for the same reason.
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
# THE VERDICT IS THREE-WAY AND THE THIRD ONE MATTERS.  A run that DIED printed
# no RESULT line, and folding that into KILLED credits the gate with a
# detection it did not make -- the simulator noticed, not the landmark.  This
# project has already been bitten by a harness that scored a dead run as a
# survivor; `sim/mutate_llama_top_kv.sh` records the same three-way split.
row() {
  local tag="$1" desc="$2" mutdir="$3"; shift 3
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir/run"
  local f src
  for f in $FILES; do
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
  # Always print which landmarks moved, kill or not.  On a SURVIVED row this
  # is the interesting half: it says the mutant reached the checker and the
  # numbers did not move, which is a different claim from "nothing ran".
  grep -a "P14 --" "$dir/run/run.log" | grep -av "NO VALUE GATE" \
    | head -4 | sed 's/^/        /' | cut -c1-190
  grep -a "P14 landmarks measured" "$dir/run/run.log" \
    | head -1 | sed 's/^/        /' | cut -c1-190
}

echo "=== teeth for the top-level value gate ==="
echo "scratch: $SCRATCH"
echo
echo "--- controls: the clean design must PASS with its landmarks pinned ---"
# A matrix whose control does not pass is measuring the bench's own breakage.
row P0s "CONTROL: clean, the KV configuration, all four landmarks pinned" "" \
    $G_SEQ  $LAND_SEQ
row P0r "CONTROL: clean, the real-path configuration, all four landmarks pinned" "" \
    $G_REAL $LAND_REAL

echo
echo "--- P1/P2: the two mutants the OLD gate could not see ---"
# Both are reproduced in docs/debugging/2026-08-29_oi3b-top-level-value-gate.md
# against commit 4736950's bench, where each printed OVERALL PASS 1 FAIL 0.
D=$(mutate_n P1 rtl/attn_block.vhd "vref_r(lay_r*N_KVH + kvh)" "vref_r(kvh)" 3)
if [ -n "$D" ]; then
  # the fourth site, spelled with `h` and not `kvh`
  python3 - "$D/attn_block.vhd" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
n = s.count("vref_r(lay_r*N_KVH + h)")
if n != 1:
    sys.stderr.write("FOURTH SITE MATCHED %d TIMES, REQUIRED 1\n" % n); sys.exit(2)
open(p, "w").write(s.replace("vref_r(lay_r*N_KVH + h)", "vref_r(h)"))
PY
  [ $? -eq 0 ] && row P1 "defect C1 restored: the v_ref fold indexed by KV HEAD ALONE, at all four sites" \
      "$D" $G_SEQ $LAND_SEQ
fi

D=$(mutate_n P2 rtl/attn_block.vhd "vref_r(lay_r*N_KVH + kvh)" "vref_r(0)" 3)
if [ -n "$D" ]; then
  python3 - "$D/attn_block.vhd" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
n = s.count("vref_r(lay_r*N_KVH + h)")
if n != 1:
    sys.stderr.write("FOURTH SITE MATCHED %d TIMES, REQUIRED 1\n" % n); sys.exit(2)
open(p, "w").write(s.replace("vref_r(lay_r*N_KVH + h)", "vref_r(0)"))
PY
  [ $? -eq 0 ] && row P2 "C-SEAM's NEGATIVE CONTROL: one v_ref register shared across every layer AND every KV head" \
      "$D" $G_SEQ $LAND_SEQ
fi

echo
echo "--- P3: the row that separates EXP_STEPH from the three R_X landmarks ---"
# TRACK CAPTURE measured this one and named it the SIXTH instance of OI-3: a
# gdn_silu truncation moves R_Y-0/1/2 and R_ER-0/1/2 and leaves R_X
# bit-identical, because R_ER sits at exp 16 while R_X.embed sits at exp 3 and
# the residual's alignment shift discards exactly the bits it moved.  So the
# pair below is the whole argument for EXP_STEPH existing:
#   P3   all four landmarks pinned      -> must KILL, on EXP_STEPH
#   P3x  EXP_STEPH deliberately UNSET   -> must SURVIVE
# If P3x killed, EXP_STEPH would be redundant with the R_X hashes and should
# be deleted.  If P3 survived, EXP_STEPH would not reach that seam either and
# the sixth OI-3 instance would still be open at the gate.
D=$(mutate_n P3 rtl/gdn_silu.vhd \
    "    return shift_right(v + shift_left(to_signed(1, v'length), sh-1), sh);" \
    "    return shift_right(v, sh);" 1)
if [ -n "$D" ]; then
  row P3  "gdn_silu's SiLU emit TRUNCATES instead of rounding, all four landmarks pinned" \
      "$D" $G_REAL $LAND_REAL
  row P3x "the SAME mutation with EXP_STEPH unset -- the three R_X landmarks alone" \
      "$D" $G_REAL $LAND_REAL_NOSTEP
fi

# P3b IS THE NARROW FORM, and P3 was NOT the mutation its name claimed.
# MEASURED: `rsh_r` in rtl/gdn_silu.vhd has THREE call sites (:275 the Q12
# conversion, :336 the interpolation, :358 the emit), and P3 mutates the
# FUNCTION BODY, so it truncates all three.  TRACK CAPTURE's m3 is the emit
# alone.  A broader mutation that kills says nothing about whether the narrow
# one would, so the narrow one is its own row rather than an edit to P3.
# P3 is kept: a three-site truncation is a real defect class and its verdict
# is a real measurement.
D=$(mutate_n P3b rtl/gdn_silu.vhd \
    "          y := rsh_r(prod(k), 15);" \
    "          y := shift_right(prod(k), 15);" 1)
if [ -n "$D" ]; then
  row P3b  "TRACK CAPTURE's m3 EXACTLY: only the SiLU EMIT truncates, all four landmarks pinned" \
      "$D" $G_REAL $LAND_REAL
  row P3bx "the SAME narrow mutation with EXP_STEPH unset -- the three R_X landmarks alone" \
      "$D" $G_REAL $LAND_REAL_NOSTEP
fi

echo
echo "--- P4: the axis checks.  Not defect rows. ---"
# C-SEAM's L7 pattern: ask whether an axis reaches the gate at all, because a
# landmark computed over a dimension that is constant would kill every mutant
# that moves anything and would still be blind to that dimension.  These are
# reported as MEASUREMENTS, in the P14 line, not as kills.
row P4s "AXIS: clean seq run, landmarks UNPINNED -- xall must differ from xsum, or the token axis is not in the hash" \
    "" $G_SEQ
row P4r "AXIS: clean real run, landmarks UNPINNED -- the NO VALUE GATE note must appear" \
    "" $G_REAL

echo
echo "=== scratch: $SCRATCH"
