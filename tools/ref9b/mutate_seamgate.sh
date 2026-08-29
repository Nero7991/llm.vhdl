#!/usr/bin/env bash
# tools/ref9b/mutate_seamgate.sh -- THE TEETH FOR tools/ref9b/seamgate.sh.
#
#   bash tools/ref9b/mutate_seamgate.sh [S1|S2|S3|S4|S5|S6|S7|all]
#
# A checker never shown to fail has not been shown to work.  This injects
# defects and records which ones the seam gate bites, WITH the ones it does
# not, under their own names.  A mutation that survives is not a failure of
# this table; it is the table's measurement of the gate's resolution floor, and
# deleting it would be deleting the only honest number here.
#
# IT NEVER TOUCHES THE WORKING TREE'S rtl/.  Each mutant is a COPY under a
# scratch directory, mutated there, exactly as tools/ref9b/mutate_capture.sh
# and sim/mutate_llama_top_kv.sh do -- three other tracks are editing rtl/
# concurrently and a half-applied sed against a shared tree is unrecoverable.
#
# WHAT EACH ROW IS FOR
#
#   S1  a value defect at a MODELLED seam.  Does the gate name the seam?
#   S2  an EXPONENT-rule defect at a modelled seam -- the same family as the
#       ref/run9b reg_put divergence, and the one a mantissa-only comparison
#       would miss.
#   S3  a defect AFTER the last region write, in the argmax.  This is the one
#       sim/tb_llama_top_real.vhd structurally cannot see: that row leaves
#       SMP_EN at its default false, so rtl/sampler_stream.vhd is not even
#       elaborated there.
#   S4  a defect inside subsystem B, whose R_Y has no integration-level model.
#       EXPECTED TO SURVIVE.  Kept because it is the resolution floor.
#   S5  teeth for the COVERAGE branch: the comparison stops comparing while
#       every seam it still compares matches.
#   S6  teeth for the PLAN DRIFT branch: the model's mirror of the descriptor
#       plan no longer describes the capture.
#   S7  THE ARGUMENT FOR THE ROW EXISTING AT ALL.  Take S1's mutant, do what a
#       track does when numbers move -- re-pin the four landmarks to the new
#       values the bench itself prints -- and run both instruments again.
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
WHICH="${1:-all}"
BASE="${MUTBASE:-$(mktemp -d -t mutseam.XXXXXX)}"
mkdir -p "$BASE"
echo "scratch: $BASE"

# --------------------------------------------------------------- the mutations
apply_mut() {
  local m="$1" tree="$2"
  case "$m" in
    S1|S7)
      sed -i 's|^              bias_o <= shift_left(to_signed(1, ACC_W), sh_v - 1);|              bias_o <= (others => '"'"'0'"'"');  -- MUTANT S1|' \
          "$tree/rtl/seq_vec_res.vhd"
      grep -q "MUTANT S1" "$tree/rtl/seq_vec_res.vhd" ;;
    S2)
      sed -i 's|^            if sh_v < 0 then sh_v := 0; end if;|            if sh_v < 1 then sh_v := 1; end if;  -- MUTANT S2|' \
          "$tree/rtl/seq_vec_res.vhd"
      grep -q "MUTANT S2" "$tree/rtl/seq_vec_res.vhd" ;;
    S3)
      sed -i 's|^        elsif cur > best_v then|        elsif cur < best_v then  -- MUTANT S3|' \
          "$tree/rtl/sampler_stream.vhd"
      grep -q "MUTANT S3" "$tree/rtl/sampler_stream.vhd" ;;
    S4)
      sed -i 's|^          y := rsh_r(prod(k), 15);|          y := shift_right(prod(k), 15);  -- MUTANT S4|' \
          "$tree/rtl/gdn_silu.vhd"
      grep -q "MUTANT S4" "$tree/rtl/gdn_silu.vhd" ;;
    *) return 0 ;;
  esac
}

mktree() {
  local m="$1" tree="$BASE/$m"
  rm -rf "$tree"; mkdir -p "$tree"
  # Only what the capture and the oracles read.  A whole-repository copy would
  # drag in build_artifacts_* and the /mnt/storage symlinks.
  cp -r "$REPO/rtl" "$REPO/sim" "$REPO/tools" "$REPO/ref" "$tree/"
  if ! apply_mut "$m" "$tree" > /dev/null; then
    echo "$m: THE SED MATCHED NOTHING.  Reporting a HARNESS failure, not a"
    echo "    survival -- an unapplied mutation that 'passes' is the single"
    echo "    most misleading result this table can produce."
    return 1
  fi
  echo "$tree"
}

# Run sim/tb_llama_top_real.vhd -- the landmark row -- inside a tree, and print
# its RESULT line plus the paste-ready generic line it emits.
run_land() {
  # TWO LINES, NOT ONE.  `local a="$1" b="$a/x"` expands every word of the
  # `local` command BEFORE it assigns any of them, so under `set -u` the second
  # one dies with `a: unbound variable`.  This bit here on the first run and the
  # error printed INSIDE the mutant's report, where it read like a mutant that
  # broke the landmark row rather than a bug in this harness.
  local tree="$1"
  local W="$tree/land"
  rm -rf "$W"; mkdir -p "$W/run"
  local files; files="$(cd "$tree" && LIST_FILES=1 bash tools/ref9b/capture_llama_top.sh real)"
  local f
  for f in $files; do
    case "$f" in *.hex) continue ;; esac
    ghdl -a --std=08 -frelaxed --workdir="$W" "$tree/$f" >> "$W/a.log" 2>&1 || {
      echo "LANDMARK ROW DID NOT ANALYZE: $f"; return 2; }
  done
  ghdl -a --std=08 -frelaxed --workdir="$W" "$tree/sim/tb_llama_top_real.vhd" \
      >> "$W/a.log" 2>&1 || { echo "LANDMARK ROW DID NOT ANALYZE THE WRAPPER"; return 2; }
  ln -sfn "$tree/sim/llama_top_w_b4_pool.hex" "$W/run/" 2>/dev/null
  ( cd "$W/run" && timeout -k 5 1800 ghdl -r --std=08 -frelaxed --workdir=".." \
      tb_llama_top_real --max-stack-alloc=0 --stop-time=900ms ) > "$W/run.log" 2>&1
  grep -aE 'RESULT:|EXP_X0 =>|assertion (error|failure)' "$W/run.log" \
      | sed 's/^.*(report note): //' | head -4
}

run_gate() {   # run_gate <tree> [extra bisect args are NOT supported: use S5/S6]
  ( cd "$1" && KEEP=1 SEAMGATE_SCRATCH="$1/gate" bash tools/ref9b/seamgate.sh real ) \
      2>&1 | grep -aE 'SEAMGATE (PASS|FAIL)|FIRST DIVERGENCE|token 0:|^    (R_|LOGITS|TOKEN)'
  return "${PIPESTATUS[0]}"
}

hdr() { echo; echo "===================== $1 ====================="; echo "$2"; }

# ------------------------------------------------------------------- the table
for m in S1 S2 S3 S4 S5 S6 S7; do
  [ "$WHICH" != "all" ] && [ "$WHICH" != "$m" ] && continue
  case "$m" in

  S1) hdr S1 "rtl/seq_vec_res.vhd: the output rounding bias deleted, so the
    residual truncates instead of rounding to nearest.  A sub-LSB change at a
    MODELLED seam (OP_RES).  EXPECT: SEAMGATE FAIL (DIVERGENCE), naming an R_X
    seam and the element."
      t=$(mktree S1) || continue
      run_gate "$t"; echo "  [gate rc=$?]" ;;

  S2) hdr S2 "rtl/seq_vec_res.vhd: the shift floor raised from 0 to 1, so every
    residual is under-normalised by one bit.  An EXPONENT-rule defect, the
    family a mantissa-only comparison misses.  EXPECT: SEAMGATE FAIL."
      t=$(mktree S2) || continue
      run_gate "$t"; echo "  [gate rc=$?]" ;;

  S3) hdr S3 "rtl/sampler_stream.vhd: the argmax comparison inverted, so the
    design decides the MINIMUM logit.  EXPECT: SEAMGATE FAIL at TOKEN, and the
    landmark row sim/tb_llama_top_real.vhd blind to it -- it never elaborates
    SMP_EN, so the sampler is not in that row at all."
      t=$(mktree S3) || continue
      echo "-- the landmark row on this mutant:"
      run_land "$t" | sed 's/^/    /'
      echo "-- the seam gate on this mutant:"
      run_gate "$t"; echo "  [gate rc=$?]" ;;

  S4) hdr S4 "rtl/gdn_silu.vhd: the SiLU emit rounds by truncation.  Inside
    subsystem B, whose R_Y has NO integration-level model, so the stepwise
    oracle never compares it.  EXPECTED TO SURVIVE -- this row measures the
    gate's resolution floor and must never be deleted.  The landmark row DOES
    see it, via EXP_STEPH; both instruments are printed."
      t=$(mktree S4) || continue
      echo "-- the landmark row on this mutant:"
      run_land "$t" | sed 's/^/    /'
      echo "-- the seam gate on this mutant:"
      run_gate "$t"; echo "  [gate rc=$?]" ;;

  S5) hdr S5 "TEETH FOR THE COVERAGE BRANCH.  No RTL is mutated.  The
    comparison is run with --no-a, which silently stops comparing every
    subsystem A seam while every seam it still compares matches perfectly.
    EXPECT: SEAMGATE FAIL (COVERAGE), not PASS and not DIVERGENCE."
      SG="$BASE/S5"; mkdir -p "$SG"
      cc -O2 -Wall -DMV4I_LIB -I ref -o "$SG/mv" tools/ref9b/mv_step_oracle.c -lm
      SMP=1 SCRATCH="$SG/w" bash tools/ref9b/capture_llama_top.sh real "$SG/cap.txt" \
          > "$SG/cap.log" 2>&1
      MV_STEP_ORACLE="$SG/mv" python3 tools/ref9b/bisect_scaled.py "$SG/cap.txt" \
          $(LIST_BISECT=1 bash tools/ref9b/capture_llama_top.sh real) --no-a \
          > "$SG/b.txt" 2>&1
      echo "  bisect rc=$?"
      head -3 "$SG/b.txt" | sed 's/^/    /'
      chk=$(awk '/^# [0-9]+ seams checked/{print $2}' "$SG/b.txt")
      echo "    -> checked $chk against the row's floor of 61: $( [ "${chk:-0}" -lt 61 ] && echo 'BELOW, so the COVERAGE branch fires' || echo 'NOT below -- the floor has no teeth here') " ;;

  S6) hdr S6 "TEETH FOR THE PLAN DRIFT BRANCH.  No RTL is mutated.  The
    comparison is asked for a shape the capture does not have (--blocks 8),
    standing in for tools/ref9b/scaled_plan.py drifting out of step with
    sim/llama_sched_pkg.vhd.  EXPECT: rc 2, refusing to compare, NOT a
    divergence at some innocent seam."
      SG="$BASE/S6"; mkdir -p "$SG"
      [ -s "$BASE/S5/cap.txt" ] && cp "$BASE/S5/cap.txt" "$SG/cap.txt" || {
        SMP=1 SCRATCH="$SG/w" bash tools/ref9b/capture_llama_top.sh real "$SG/cap.txt" > "$SG/cap.log" 2>&1; }
      python3 tools/ref9b/bisect_scaled.py "$SG/cap.txt" --blocks 8 --attn-int 4 \
          --attn-hd 16 --norm real --w-image sim/llama_top_w_b4_pool.hex \
          > "$SG/b.txt" 2>&1
      echo "  bisect rc=$?"
      head -5 "$SG/b.txt" | sed 's/^/    /' ;;

  S7) hdr S7 "A LANDMARK RE-PINNED IS A LANDMARK SATISFIED.  S1's mutant again,
    but this time the four landmarks in sim/tb_llama_top_real.vhd are replaced
    with the values that mutant itself prints -- which is exactly what a track
    does when an rtl/ change legitimately moves them.  EXPECT: the landmark row
    PASSES on the mutated design, and the seam gate still FAILS.  That gap is
    the entire reason this row exists."
      t=$(mktree S7) || continue
      echo "-- the landmark row BEFORE re-pinning:"
      before="$(run_land "$t")"
      echo "$before" | sed 's/^/    /'
      newg="$(echo "$before" | grep -ao 'EXP_X0 => .*EXP_STEPH => [-0-9]*')"
      if [ -z "$newg" ]; then
        echo "    could not read the paste-ready generic line; S7 cannot proceed"
        continue
      fi
      echo "-- re-pinning sim/tb_llama_top_real.vhd to: $newg"
      python3 - "$t/sim/tb_llama_top_real.vhd" "$newg" <<'PY'
import re, sys
p, g = sys.argv[1], sys.argv[2]
vals = dict(re.findall(r'(EXP_\w+) => (-?\d+)', g))
s = open(p).read()
for k, v in vals.items():
    s2 = re.sub(r'(\n\s*%s\s*=>\s*)-?\d+' % k, lambda m: m.group(1) + v, s, count=1)
    assert s2 != s, "did not re-pin " + k
    s = s2
open(p, 'w').write(s)
print("re-pinned " + " ".join("%s=%s" % kv for kv in sorted(vals.items())))
PY
      echo "-- the landmark row AFTER re-pinning:"
      run_land "$t" | sed 's/^/    /'
      echo "-- the seam gate on the same mutant:"
      run_gate "$t"; echo "  [gate rc=$?]" ;;
  esac
done

echo
echo "scratch kept: $BASE"
