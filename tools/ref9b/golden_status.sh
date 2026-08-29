#!/usr/bin/env bash
# tools/ref9b/golden_status.sh -- is a committed golden capture STALE, and if
# so, because of what?
#
# THE PROBLEM THIS SOLVES, and it has already cost an hour.
# `tools/ref9b/golden/llama_top_*.txt` are committed captures of
# `sim/tb_llama_top.vhd`.  Nothing gates on them, so they rot on every `rtl/`
# commit that reaches the real path, and on 2026-08-29 a track diffed a fresh
# capture against a stale golden and published a wrong finding, blaming an
# innocent commit.  TRACK LOGITS fixed HALF of that by stamping the revision
# and the tree's dirtiness into every capture, so the two readings are
# separated in the file.  This is the other half: given the stamp, answering
# "has anything this capture READS changed since?" WITHOUT running the
# 80-second simulation, and naming what moved when the answer is yes.
#
# WHY NOT A GATE ROW, which is what the dispatcher asked for first.  Measured,
# not assumed -- three reasons, any one of them sufficient:
#
#  1. `sim/regress.sh` has NO non-VHDL row type.  Its plan is built by globbing
#     `sim/*.vhd` and `tb/*.vhd` (`SUITE_DIRS`, :783), and `run_one` (:1212) is
#     `ghdl -a` over a file list then `ghdl -r` on a top entity.  A shell or
#     Python row needs new machinery in the planner, in `run_one` and in the
#     judging -- in a file five tracks edited on the day this was written.
#
#  2. A VHDL-shaped row would have to live at `sim/tb_llama_top_*.vhd`, which
#     TRACK OI-3B owns and had UNCOMMITTED EDITS IN at the time
#     (`git status --porcelain -- sim/tb_llama_top.vhd sim/tb_llama_top_real.vhd`
#     showed both ` M`).  Adding a row there was not this track's to do.
#
#  3. THE STRONGEST ONE.  A gate that diffs a fresh capture against a committed
#     golden goes RED on every legitimate `rtl/` change on the real path.  The
#     next track then has to decide whether the new numbers are right -- which
#     is exactly the judgement that cost the hour -- except now it blocks
#     everybody instead of one reader.  That MOVES the cost into the gate; it
#     does not remove it.  A byte-identity gate is the right instrument for an
#     artefact that must not change, and the real-path capture is not one:
#     subsystems B and C are still landing recipes that legitimately move it.
#
# So the golden stays COMMITTED, and what is added is the ability to know, in
# about a second, whether it is current -- which is strictly cheaper than the
# 80 s the gate row would have cost and strictly more informative, because it
# names the files rather than the bytes.
#
# WHAT IT CANNOT TELL YOU, stated because a checker's blind spot is the part
# that gets forgotten.  A closure file changing does NOT prove the capture
# changed: most `rtl/` edits are comments or are on a path this configuration
# does not reach.  This script says STALE meaning "not provably current", which
# is the safe direction, and the only way to convert that into an answer is to
# re-capture.  It also cannot see a change in anything OUTSIDE the closure that
# the run nonetheless reads -- if `capture_llama_top.sh`'s FILES list ever goes
# out of step with what the bench actually opens, this goes blind with it.
# That is why the list is read FROM that script (`LIST_FILES=1`) and not copied.
#
# Usage:  bash tools/ref9b/golden_status.sh [real|seq|stub]...   (default: all)
# Exit:   0 every golden is provably current;  1 at least one is not.
set -uo pipefail
cd "$(dirname "$0")/../.."

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "golden_status: not a git tree, so 'changed since' has no meaning here."
  exit 1
fi

CFGS="${*:-real seq stub}"
rc=0

for CFG in $CFGS; do
  G="tools/ref9b/golden/llama_top_${CFG}.txt"
  echo "=== $CFG ============================================================"
  if [ ! -f "$G" ]; then
    echo "  ABSENT: $G is not committed.  Nothing to be stale; regenerate with"
    echo "    SMP=1 bash tools/ref9b/capture_llama_top.sh $CFG"
    continue
  fi

  # The stamp.  `# HEAD <rev> [note]  SMP=<n>` -- take the FIRST token after
  # HEAD, because captures on a `git archive` tree stamp `<rev> + TRACK NAME`.
  stamp=$(grep -am1 '^# HEAD ' "$G" | awk '{print $3}')
  recs=$(grep -ac '^SEAM' "$G")
  dirty=$(grep -ac '^# TREE WAS DIRTY' "$G")
  echo "  $recs record(s), stamped rev '${stamp:-none}'"
  if [ "$dirty" != "0" ]; then
    echo "  CAPTURED FROM A DIRTY TREE.  It is not a capture of any commit, so"
    echo "  'stale' is not even the right question -- re-capture it clean."
    rc=1
    continue
  fi
  if [ -z "$stamp" ]; then
    echo "  NO PROVENANCE STAMP.  Predates the stamping added on 2026-08-29,"
    echo "  so nothing can say what it is a capture OF.  Re-capture it."
    rc=1
    continue
  fi
  if ! git rev-parse --verify --quiet "${stamp}^{commit}" >/dev/null; then
    echo "  STAMPED REVISION $stamp IS NOT IN THIS REPOSITORY.  It may be from"
    echo "  a branch that was never pushed, or the stamp may be wrong."
    rc=1
    continue
  fi

  # The closure comes from the capture script itself, never from a copy here.
  files=$(LIST_FILES=1 bash tools/ref9b/capture_llama_top.sh "$CFG") || {
    echo "  could not read the file closure from capture_llama_top.sh"; rc=1
    continue; }

  # shellcheck disable=SC2086
  moved=$(git diff --name-only "$stamp" HEAD -- $files)
  # shellcheck disable=SC2086
  local_edits=$(git status --porcelain -- $files | grep -v '^??' | awk '{print $2}')

  if [ -z "$moved" ] && [ -z "$local_edits" ]; then
    echo "  CURRENT: no file in the ${CFG} capture's closure has changed"
    echo "  between $stamp and HEAD ($(git rev-parse --short HEAD)), and none"
    echo "  is edited in the working tree.  A fresh capture should therefore"
    echo "  be identical -- 'should', because that rests on the closure being"
    echo "  complete and the run being deterministic, neither of which this"
    echo "  script can check.  It is the strongest statement available without"
    echo "  spending the 80 seconds."
    continue
  fi
  rc=1
  echo "  NOT PROVABLY CURRENT.  Re-capture before diffing anything against it:"
  echo "    SMP=1 bash tools/ref9b/capture_llama_top.sh $CFG"
  if [ -n "$moved" ]; then
    echo "  changed between $stamp and HEAD:"
    printf '    %s\n' $moved
  fi
  if [ -n "$local_edits" ]; then
    echo "  edited in the WORKING TREE right now (so a capture taken here is"
    echo "  a capture of nobody's commit):"
    printf '    %s\n' $local_edits
  fi
done

echo
if [ "$rc" = 0 ]; then
  echo "GOLDEN STATUS: every checked capture is provably current."
else
  echo "GOLDEN STATUS: at least one capture is not provably current.  That is"
  echo "NOT the same as knowing it is wrong -- most rtl/ edits do not reach"
  echo "this configuration -- but it means a diff against it cannot be read as"
  echo "evidence about anything until it is re-captured."
fi
exit $rc
