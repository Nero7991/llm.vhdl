#!/usr/bin/env bash
# THE TEETH-CHECK for the llama_top seam capture and its `--mode exact`
# comparison.  A checker never shown to fail has not been shown to work.
#
# WHAT IS BEING PRICED.  Three things in series, and a mutation that bites
# proves all three at once:
#
#   1. sim/tb_llama_top.vhd's CAPTURE actually observes the arithmetic, rather
#      than re-emitting something the bench already held;
#   2. tools/ref9b/capture_to_r9bs.py carries it into .r9bs without flattening
#      the difference;
#   3. tools/ref9b/ref_stream_scaled.py's reference and seam_bisect.py --mode
#      exact locate it, at the right SEAM and the right ELEMENT.
#
# IT NEVER TOUCHES rtl/.  The tree is copied to a scratch directory and the
# copy is mutated, which is the same self-isolation sim/mutate_llama_top_kv.sh
# uses and for the same reason: a sed against the working tree that dies
# halfway leaves a repository nobody can trust, and three other tracks are
# editing rtl/ concurrently.
#
# REPORT THE MUTATIONS THAT DO NOT BITE UNDER THEIR OWN NAMES.  m3 is expected
# to survive and is in the table for exactly that reason: it measures the
# harness's resolution floor, which is the most useful row here.  Never delete
# a non-biting mutation.
#
# usage:  bash tools/ref9b/mutate_capture.sh [m0|m1|m2|m3|all]
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
WHICH="${1:-all}"
BASE="${MUTBASE:-$(mktemp -d)}"
OUTDIR="${OUTDIR:-/mnt/storage/ref9b-capture}"
mkdir -p "$OUTDIR"

CLEAN_TXT="$OUTDIR/llama_top_real_HEAD.txt"
CLEAN_R9="$OUTDIR/llama_top_real_HEAD.r9bs"
REF_R9="$OUTDIR/ref_scaled_real_HEAD.r9bs"
REFARGS="--blocks 4 --attn-int 4 --attn-hd 16 --norm real"

# ------------------------------------------------------------------ mutations
# Each is `file|sed-expression|what it breaks|what is expected`.
mut_desc() {
  case "$1" in
    m0) echo "the CAPTURE ITSELF, one mantissa of R_XN-0 moved by one LSB.  Not
        an RTL defect -- it prices the comparator's RESOLUTION, which is the
        floor everything else is measured against." ;;
    m1) echo "rtl/seq_vec_res.vhd: the output rounding bias deleted, so the
        residual truncates instead of rounding to nearest.  A sub-LSB change
        at a MODELLED seam (OP_RES)." ;;
    m2) echo "rtl/seq_vec_res.vhd: the shift floor raised from 0 to 1, so every
        residual is under-normalised by one bit.  This is the SAME FAMILY as
        the ref/run9b reg_put divergence: an exponent rule that disagrees." ;;
    m3) echo "rtl/gdn_silu.vhd: the SiLU emit rounds by truncation.  Inside
        subsystem B, whose R_Y has NO integration-level model, so the
        reference stream OMITS it.  EXPECTED TO SURVIVE." ;;
  esac
}

apply_mut() {
  local m="$1" tree="$2"
  case "$m" in
    m1) sed -i 's|^              bias_o <= shift_left(to_signed(1, ACC_W), sh_v - 1);|              bias_o <= (others => '"'"'0'"'"');  -- MUTANT m1|' \
            "$tree/rtl/seq_vec_res.vhd"
        grep -q "MUTANT m1" "$tree/rtl/seq_vec_res.vhd" || { echo "m1 sed matched nothing"; return 1; } ;;
    m2) sed -i 's|^            if sh_v < 0 then sh_v := 0; end if;|            if sh_v < 1 then sh_v := 1; end if;  -- MUTANT m2|' \
            "$tree/rtl/seq_vec_res.vhd"
        grep -q "MUTANT m2" "$tree/rtl/seq_vec_res.vhd" || { echo "m2 sed matched nothing"; return 1; } ;;
    m3) sed -i 's|^          y := rsh_r(prod(k), 15);|          y := shift_right(prod(k), 15);  -- MUTANT m3|' \
            "$tree/rtl/gdn_silu.vhd"
        grep -q "MUTANT m3" "$tree/rtl/gdn_silu.vhd" || { echo "m3 sed matched nothing"; return 1; } ;;
  esac
  return 0
}

# ------------------------------------------------------------------- the runs
run_rtl_mut() {
  local m="$1"
  local tree="$BASE/$m"
  rm -rf "$tree"; mkdir -p "$tree"
  # Only what capture_llama_top.sh reads.  A full copy of the repository would
  # drag in build_artifacts_* and /mnt/storage symlinks.
  cp -r "$REPO/rtl" "$REPO/sim" "$REPO/tools" "$tree/"
  if ! apply_mut "$m" "$tree"; then
    echo "$m: SED DID NOT APPLY -- reporting as a harness failure, not a survival"
    return 2
  fi
  ( cd "$tree" && SCRATCH="$tree/work" bash tools/ref9b/capture_llama_top.sh \
      real "$OUTDIR/cap_$m.txt" ) > "$BASE/$m.runlog" 2>&1
  if [ ! -s "$OUTDIR/cap_$m.txt" ]; then
    echo "$m: NO CAPTURE.  A run that died has captured nothing, and an empty"
    echo "    file compares equal to another empty file.  ABORT, not a survival."
    tail -5 "$BASE/$m.runlog"
    return 2
  fi
  grep -a "RESULT:" "$BASE/$m.runlog" | tail -1
  score "$m" "$OUTDIR/cap_$m.txt"
}

score() {
  local m="$1" txt="$2"
  ( cd "$REPO/tools/ref9b" || exit 2
    python3 capture_to_r9bs.py "$txt" -o "$OUTDIR/cap_$m.r9bs" --check-names \
        > /dev/null || exit 2
    # THE REFERENCE IS REBUILT FROM THE MUTANT'S OWN CAPTURE.  That is the
    # point of a stepwise oracle and it is also the hard case: every model
    # reads the mutant's inputs, so only a step whose OWN op is mutated can
    # disagree.  Comparing against the CLEAN reference instead would flag
    # every downstream seam and prove nothing about localisation.
    python3 ref_stream_scaled.py "$txt" -o "$OUTDIR/ref_$m.r9bs" $REFARGS \
        --w-image "$REPO/sim/llama_top_w_b4_pool.hex" 2> /dev/null || exit 2
    python3 seam_bisect.py "$OUTDIR/ref_$m.r9bs" "$OUTDIR/cap_$m.r9bs" \
        --mode exact --tok 0 | tail -4 )
}

run_m0() {
  # Perturb one mantissa of the CLEAN capture, leaving everything else alone.
  python3 - "$CLEAN_TXT" "$OUTDIR/cap_m0.txt" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines()
out, armed, done = [], False, False
for ln in lines:
    if ln.startswith("SEAM R_XN-0 "):
        armed = True
        out.append(ln); continue
    if armed and not done and ln and not ln.startswith(("#", "SEAM")):
        f = ln.split()
        f[0] = str(int(f[0]) + 1)          # one LSB, one element, one seam
        out.append(" ".join(f)); done = True; continue
    out.append(ln)
assert done, "m0 found no R_XN-0 payload to perturb"
open(dst, "w").write("\n".join(out) + "\n")
print("m0: R_XN-0 element 0 moved by +1 LSB")
PY
  score m0 "$OUTDIR/cap_m0.txt"
}

# ---------------------------------------------------------------------- driver
echo "scratch: $BASE"
echo "clean control:"
( cd "$REPO/tools/ref9b" && python3 seam_bisect.py "$REF_R9" "$CLEAN_R9" \
    --mode exact --tok 0 | tail -3 )
for m in m0 m1 m2 m3; do
  [ "$WHICH" != "all" ] && [ "$WHICH" != "$m" ] && continue
  echo
  echo "===================== $m ====================="
  mut_desc "$m"
  if [ "$m" = m0 ]; then run_m0; else run_rtl_mut "$m"; fi
done
