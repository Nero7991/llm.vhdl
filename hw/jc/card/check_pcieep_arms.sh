#!/usr/bin/env bash
# hw/jc/card/check_pcieep_arms.sh -- prove that hw/fk33/gen_pcieep.py emits the same
# build_fk33_pcieep.tcl and fk33_pcieep.xdc at two revisions, under four environment arms:
#   A  the committed GENSTAMP (FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75)
#   B  every FK33_* unset (engine-only)
#   C  A plus FK33_ENG=0
#   D  A plus FK33_ENG_SPLIT_CLK=1
# and that arm A equals the NEW revision's committed build_fk33_pcieep.tcl.
#
#   check_pcieep_arms.sh <scratch_dir> <base_rev> [<new_rev>|WORKTREE]
#
# Each revision is `git archive`d into its own directory under <scratch_dir> (which must
# not exist) and runs ITS OWN generator, so a change elsewhere in the tree that changes
# the output shows up as a difference.  WORKTREE means HEAD's tree with the working
# copy of hw/fk33/gen_pcieep.py on top (for checking a refactor before committing).
# Absolute paths are folded: each tree's root becomes @REPO@.  No Vivado.
# Prints ^ARMS_PASS or ^ARMS_FAIL <reason>; exit 0 only on ARMS_PASS.
set -u
if [ $# -lt 2 ]; then echo "usage: $0 <scratch_dir> <base_rev> [<new_rev>|WORKTREE]"; exit 2; fi
S=$1; BASE=$2; NEW=${3:-HEAD}
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
if [ -e "$S" ]; then echo "ARMS_FAIL $S exists; give a new directory"; exit 1; fi
mkdir -p "$S/base" "$S/new" "$S/out" || { echo "ARMS_FAIL mkdir"; exit 1; }
PATHS=(rtl tools hw/fk33 hw/jc server sim ':!hw/fk33/results' ':!hw/fk33/bit'
       ':!hw/jc/loader/results' ':!hw/jc/pinfinder/results')
git -C "$REPO" archive "$BASE" -- "${PATHS[@]}" | tar -x -C "$S/base" \
  || { echo "ARMS_FAIL archive $BASE"; exit 1; }
if [ "$NEW" = WORKTREE ]; then
  git -C "$REPO" archive HEAD -- "${PATHS[@]}" | tar -x -C "$S/new" \
    && cp "$REPO/hw/fk33/gen_pcieep.py" "$S/new/hw/fk33/gen_pcieep.py" \
    || { echo "ARMS_FAIL archive HEAD"; exit 1; }
  COMMITTED=$(git -C "$REPO" show HEAD:hw/fk33/build_fk33_pcieep.tcl)
else
  git -C "$REPO" archive "$NEW" -- "${PATHS[@]}" | tar -x -C "$S/new" \
    || { echo "ARMS_FAIL archive $NEW"; exit 1; }
  COMMITTED=$(git -C "$REPO" show "$NEW":hw/fk33/build_fk33_pcieep.tcl)
fi
UNSET=(-u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ -u FK33_ENG_FAST_MHZ
       -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_MODEL -u FK33_SYNTH_JOBS -u FK33_SYNTH_THREADS)
CARD=(FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75)
fail=0
for side in base new; do
  for arm in A B C D; do
    case $arm in
      A) e=("${CARD[@]}");;
      B) e=();;
      C) e=("${CARD[@]}" FK33_ENG=0);;
      D) e=("${CARD[@]}" FK33_ENG_SPLIT_CLK=1);;
    esac
    o="$S/out/$side/$arm"; mkdir -p "$o"
    (cd "$S/$side" && env "${UNSET[@]}" "${e[@]}" python3 hw/fk33/gen_pcieep.py --emit-to "$o" \
       > "$o/stdout.log" 2>&1) || { echo "ARMS_FAIL generator $side arm $arm (see $o/stdout.log)"; fail=1; }
    for f in build_fk33_pcieep.tcl fk33_pcieep.xdc; do
      [ -f "$o/$f" ] && sed -i -e "s#$S/$side#@REPO@#g" -e "s#$REPO#@REPO@#g" "$o/$f"
    done
  done
done
[ $fail = 0 ] || exit 1
for arm in A B C D; do
  for f in build_fk33_pcieep.tcl fk33_pcieep.xdc; do
    if cmp -s "$S/out/base/$arm/$f" "$S/out/new/$arm/$f"; then
      echo "ARMS_SAME arm $arm $f ($(wc -c < "$S/out/new/$arm/$f") bytes)"
    else
      echo "ARMS_DIFF arm $arm $f"; diff "$S/out/base/$arm/$f" "$S/out/new/$arm/$f" | head -20; fail=1
    fi
  done
done
if [ "$(printf '%s\n' "$COMMITTED" | sed "s#$REPO#@REPO@#g")" = "$(cat "$S/out/new/A/build_fk33_pcieep.tcl")" ]; then
  echo "ARMS_SAME arm A equals the committed build_fk33_pcieep.tcl"
else
  echo "ARMS_DIFF arm A differs from the committed build_fk33_pcieep.tcl"; fail=1
fi
if [ $fail = 0 ]; then echo "ARMS_PASS $BASE vs $NEW"; exit 0; fi
echo "ARMS_FAIL outputs differ"; exit 1
