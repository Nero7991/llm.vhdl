#!/usr/bin/env bash
# THE TEETH-CHECK FOR THE LOGITS SEAM -- the one seam that decides a token.
#
# WHY IT IS SEPARATE FROM mutate_capture.sh.  That script prices the seam
# capture and the `--mode exact` comparison over the sixty-odd REGION seams.
# LOGITS is not a region seam and never was: the lm_head job carries
# `dst = R_NONE`, so `tb_llama_top`'s capture -- which snapshots
# `PLAN(step).dst` at each completion -- had nothing to snapshot, and the seam
# was absent from the capture, absent from the reference, and therefore
# absent from every verdict.  It reaches the stream only through
# `rtl/llama_top.vhd`'s FLG_TO_SMP route under `SMP_EN`, and what it carries is
# raw s32 plus `rtl/sampler_stream.vhd`'s argmax, not a BFP mantissa vector.
# Different route, different numeric kind, different failure modes; a separate
# table.
#
# WHAT IS BEING PRICED, in series:
#   1. sim/tb_llama_top.vhd collects the smp_* STREAM without losing a beat;
#   2. the s32 record survives tools/ref9b/capture_to_r9bs.py into .r9bs;
#   3. tools/ref9b/ref_stream_scaled.py models it from ref/matvec_int4.c in RAW
#      out_mode and takes the argmax of ITS OWN logits, not of the capture's;
#   4. seam_bisect.py --mode exact locates a difference at the right element.
#
# IT NEVER TOUCHES rtl/.  The tree is copied to scratch and the COPY mutated.
#
# THE SURVIVORS ARE THE POINT.  L5 and L6 are expected to survive and are in
# the table for that reason: each names a structural property of this shape
# that no capture at this shape can exercise, and both are properties the
# FK33 build depends on.  Never delete a non-biting mutation.
#
# usage:  bash tools/ref9b/mutate_logits.sh [L0..L7|all]
# env:    MUTBASE=<dir>   scratch root (NAMESPACE IT -- the session scratchpad
#                         is shared between agents and a bare `mut` is taken)
#         OUTDIR=<dir>    where captures and streams land
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
WHICH="${1:-all}"
BASE="${MUTBASE:-$(mktemp -d -t logitsmut.XXXXXX)}"
OUTDIR="${OUTDIR:-$BASE/streams}"
mkdir -p "$OUTDIR" "$BASE"

CLEAN_TXT="${CLEAN_TXT:-$OUTDIR/clean.txt}"
REFARGS="--blocks 4 --attn-int 4 --attn-hd 16 --norm real"

mut_desc() {
  case "$1" in
    L0) echo "the CAPTURE ITSELF: one logit moved by +1.  Not an RTL defect --
        it prices the comparator's RESOLUTION on a raw s32 seam.  EXPECT KILL
        at LOGITS element 0." ;;
    L1) echo "the CAPTURE ITSELF: the argmax index moved by +1, values
        untouched.  Prices the TOKEN comparison INDEPENDENTLY of the values,
        which matters because the two records fail for different reasons.
        EXPECT KILL at TOKEN only." ;;
    L2) echo "rtl/llama_top.vhd: the logits route takes the UPPER half of each
        64-bit y_data lane instead of the low half.  RAW out_mode sign-extends
        into that half, so every logit becomes 0 or -1.  EXPECT KILL." ;;
    L3) echo "rtl/llama_top.vhd: the serialiser stops at a beat's FIRST valid
        lane and retires the beat, so three of every four logits are never
        folded.  (Written as a lane-order change; what it actually produces is
        a LOST-LANE defect, and it is kept under that description because
        losing a lane is precisely the hazard the beat FIFO exists to prevent
        -- y_we has no ready.)  EXPECT KILL, and expect the BENCH's own hole
        counter to fire before the oracle does." ;;
    L4) echo "rtl/llama_top.vhd: the published logits exponent is one lower.
        Every value is unchanged and every SCALE is wrong by 2x.  EXPECT KILL
        at LOGITS on the EXPONENT, with zero values differing." ;;
    L5) echo "rtl/llama_top.vhd: the per-window base never advances, so window
        w numbers its rows from 0 instead of from w*n_rows.  EXPECTED TO
        SURVIVE: llama_sched_pkg's lm_windows() is 1 at every scaled shape, so
        there IS no second window here.  At the 9B shape it is 15 and this
        mutation would collapse fifteen windows onto one index space." ;;
    L6) echo "rtl/llama_top.vhd: the pad-row mask is ignored, so a masked lane
        is folded into the argmax.  EXPECTED TO SURVIVE: vocab_shard = 128 is
        a multiple of A_ROWS_IF = 4, so no beat of this job HAS a pad row.
        sim/tb_llama_top_smp.vhd uses 30 and 34 rows for exactly this." ;;
    L8) echo "rtl/llama_top.vhd: the serialiser files each value at the
        MIRRORED lane index within its beat.  Every logit still arrives, in the
        same order, so nothing is lost -- each value is merely recorded against
        the wrong vocabulary index.  MEASURED: LOGITS kills 128 of 128 with
        zero holes; TOKEN is EXACT, because sampler_stream counts ARRIVALS and
        the arrival order did not move, while the model takes the argmax of its
        OWN (unpermuted) logits.  So this defect is caught by the value record
        and is invisible to the argmax.  That is the reason both records exist
        and neither replaces the other." ;;
    L7) echo "the BENCH: SMP_FIFO back to rtl/llama_top.vhd's default 8.  Not
        an oracle mutation -- it prices the capture's own integrity counters,
        which must report the lost beats rather than emitting a record of the
        right length with zeros in it.  EXPECT the run to ABORT on
        err_smp_ovf." ;;
  esac
}

apply_mut() {
  local m="$1" tree="$2"
  case "$m" in
    L2) sed -i 's|^                <= y_data(rr\*64+31 downto rr\*64);|                <= y_data(rr*64+63 downto rr*64+32);  -- MUTANT L2|' \
            "$tree/rtl/llama_top.vhd"
        grep -q "MUTANT L2" "$tree/rtl/llama_top.vhd" || return 1 ;;
    L3) sed -i 's|^              if l >= lane and fm(rp)(l) = .1. then nxt := l; end if;|              if l >= lane and fm(rp)(l) = '"'"'1'"'"' then if nxt = A_ROWS_IF then nxt := l; end if; end if;  -- MUTANT L3|' \
            "$tree/rtl/llama_top.vhd"
        grep -q "MUTANT L3" "$tree/rtl/llama_top.vhd" || return 1 ;;
    L4) sed -i 's|^    smp_exp   <= smp_yexp_i;|    smp_exp   <= smp_yexp_i - 1;  -- MUTANT L4|' \
            "$tree/rtl/llama_top.vhd"
        grep -q "MUTANT L4" "$tree/rtl/llama_top.vhd" || return 1 ;;
    L5) sed -i 's|^                  smp_base <= smp_base + j_rows;|                  smp_base <= smp_base;  -- MUTANT L5|' \
            "$tree/rtl/llama_top.vhd"
        grep -q "MUTANT L5" "$tree/rtl/llama_top.vhd" || return 1 ;;
    L6) sed -i 's|^            smp_be_msk <= y_mask;|            smp_be_msk <= (others => '"'"'1'"'"');  -- MUTANT L6|' \
            "$tree/rtl/llama_top.vhd"
        grep -q "MUTANT L6" "$tree/rtl/llama_top.vhd" || return 1 ;;
    L8) sed -i 's|^              s_idx <= fi(rp) + nxt;|              s_idx <= fi(rp) + (A_ROWS_IF-1-nxt);  -- MUTANT L8|' \
            "$tree/rtl/llama_top.vhd"
        grep -q "MUTANT L8" "$tree/rtl/llama_top.vhd" || return 1 ;;
    L7) sed -i 's|^    SMP_FIFO  : positive := 64;|    SMP_FIFO  : positive := 8;  -- MUTANT L7|' \
            "$tree/sim/tb_llama_top.vhd"
        grep -q "MUTANT L7" "$tree/sim/tb_llama_top.vhd" || return 1 ;;
  esac
  return 0
}

score() {
  local m="$1" txt="$2"
  ( cd "$REPO/tools/ref9b" || exit 2
    python3 capture_to_r9bs.py "$txt" -o "$OUTDIR/cap_$m.r9bs" > /dev/null 2>&1 || exit 2
    # THE REFERENCE IS REBUILT FROM THE MUTANT'S OWN CAPTURE, which is the hard
    # case: every model reads the mutant's inputs, so only the step whose own
    # op is mutated can disagree.  For LOGITS that means the A oracle recomputes
    # the logits from the mutant's R_XN.final and the argmax from ITS OWN
    # logits -- so a route defect shows and an upstream one does not.
    python3 ref_stream_scaled.py "$txt" -o "$OUTDIR/ref_$m.r9bs" $REFARGS \
        --w-image "$REPO/sim/llama_top_w_b4_pool.hex" 2> /dev/null || exit 2
    python3 seam_bisect.py "$OUTDIR/ref_$m.r9bs" "$OUTDIR/cap_$m.r9bs" \
        --mode exact --tok 0 -v 2>&1 | grep -E "LOGITS|TOKEN|^# exact|^# coverage|FIRST|EVERY" )
}

run_rtl_mut() {
  local m="$1" tree="$BASE/$m"
  rm -rf "$tree"; mkdir -p "$tree"
  cp -r "$REPO/rtl" "$REPO/sim" "$REPO/tools" "$tree/"
  if ! apply_mut "$m" "$tree"; then
    echo "$m: SED DID NOT APPLY -- a harness failure, NOT a survival"
    return 2
  fi
  ( cd "$tree" && SCRATCH="$tree/work" SMP=1 \
      bash tools/ref9b/capture_llama_top.sh real "$OUTDIR/cap_$m.txt" ) \
      > "$BASE/$m.runlog" 2>&1
  # An empty capture compares equal to another empty capture.  ABORT, never
  # a survival.
  if [ ! -s "$OUTDIR/cap_$m.txt" ]; then
    echo "$m: NO CAPTURE (the run died).  ABORT, not a survival."
    tail -4 "$BASE/$m.runlog"; return 2
  fi
  grep -a "RESULT:\|logits capture:" "$BASE/$m.runlog" | tail -2
  if ! grep -aq "RESULT:" "$BASE/$m.runlog"; then
    echo "$m: the bench ABORTED before its verdict (see the capture counters"
    echo "    above).  That is the bench catching it, not the oracle."
    return 0
  fi
  score "$m" "$OUTDIR/cap_$m.txt"
}

edit_capture() {   # $1 = mutant, $2 = python snippet name
  python3 - "$CLEAN_TXT" "$OUTDIR/cap_$1.txt" "$2" <<'PY'
import sys
src, dst, what = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).read().splitlines()
out, mode, done = [], None, False
for ln in lines:
    if ln.startswith("SEAM LOGITS "):
        mode = "logits"; out.append(ln); continue
    if ln.startswith("SEAM TOKEN "):
        mode = "token"; out.append(ln); continue
    if ln.startswith("SEAM"):
        mode = None; out.append(ln); continue
    if not done and ln and not ln.startswith("#"):
        if what == "L0" and mode == "logits":
            f = ln.split(); f[0] = str(int(f[0]) + 1)
            out.append(" ".join(f)); done = True
            print("L0: LOGITS element 0 moved by +1"); continue
        if what == "L1" and mode == "token":
            out.append(str(int(ln.split()[0]) + 1)); done = True
            print("L1: TOKEN index moved by +1"); continue
    out.append(ln)
assert done, "%s found nothing to perturb" % what
open(dst, "w").write("\n".join(out) + "\n")
PY
}

echo "scratch: $BASE"
echo "streams: $OUTDIR"
if [ ! -s "$CLEAN_TXT" ]; then
  echo "clean capture:"
  ( cd "$REPO" && SCRATCH="$BASE/clean" SMP=1 \
      bash tools/ref9b/capture_llama_top.sh real "$CLEAN_TXT" ) \
      2>&1 | grep -a "RESULT:\|logits capture:"
fi
echo "clean control:"
score clean "$CLEAN_TXT"

for m in L0 L1 L2 L3 L4 L5 L6 L8 L7; do
  [ "$WHICH" != "all" ] && [ "$WHICH" != "$m" ] && continue
  echo
  echo "===================== $m ====================="
  mut_desc "$m"
  case "$m" in
    L0|L1) edit_capture "$m" "$m" && score "$m" "$OUTDIR/cap_$m.txt" ;;
    *)     run_rtl_mut "$m" ;;
  esac
done
