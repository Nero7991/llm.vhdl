#!/usr/bin/env bash
# hw/jc/card/run_card.sh -- Jungle Cat 27B card: the full build, orchestrated.
#
#   run_card.sh [--dry-run] [--allow-scratch-root] [--allow-llama-server] \
#               [--allow-other-part] <root> [part] [allow_neg]
#
# What it does (Task 9 brief, plus fix round 1):
#   0. refuses a root outside /mnt/storage/fk33_builds/ (unless --allow-scratch-root),
#      a part string other than xcvu35p-fsvh2104-2L-e (unless --allow-other-part),
#      a root that already exists and is not empty, another Vivado already running,
#      or llama-server running (unless --allow-llama-server); prints the memory
#      budget (MemAvailable, SwapFree) before doing anything else;
#   1. copies the TRACKED tree into <root>/src via `git archive HEAD`;
#   2. applies build12_levers_off.patch there, refusing if it does not apply cleanly;
#   3. records HEAD, the patch's sha256 and (once regenerated) the sha256 of the four
#      regenerated files into <root>/PROVENANCE.txt;
#   4. regenerates the 27B card wrapper and the Jungle Cat BD/XDC/top IN THAT TREE
#      (hw/fk33/gen_fk33_card.py under the pinned JC_CARD_ENV, then
#      hw/jc/card/gen_jc_card.py in place) and checks both ran;
#   5. deletes any stale build log, then runs Vivado under
#      hw/jc/loader/run_capped.sh: MemoryHigh=24G, a 30 GiB swap guard (CLAUDE.md's
#      measured card-build shape: ~47 GB including swap under a tighter cap, so this
#      one is watched the same way), passing this run's own nonce on -tclargs;
#   6. harvests the utilisation, timing, CDC and hierarchical utilisation reports,
#      and the bitstream, into <root>/results;
#   7. writes the JCCARD_DONE or JCCARD_FAIL <reason> sentinel -- anchored
#      (grep -qE '^JCCARD_(DONE|FAIL)'), gated on a log that both contains THIS
#      run's own nonce (JCCARD_NONCE, printed by build_card.tcl before anything
#      else) AND a JCCARD_DONE line AFTER it, never on a timeout or an exit code
#      alone (CLAUDE.md: "a completion signal that also fires on failure is not
#      one") and never on a stale JCCARD_DONE left by an earlier run in a reused log.
#
# --dry-run prints every command this script would run and every parameter binding
# (part, CLK_CORE_MHZ, the memory cap, the swap guard, the nonce, the memory budget)
# and exits 0. It touches NOTHING: no git, no Vivado, no filesystem write, not even
# <root>. The read-only validation checks (root location, root emptiness) DO run
# under --dry-run, since they inspect rather than change anything, and a dry run
# that hides a refusal the real run would hit is not proving what would run. The
# process-presence refusals (another Vivado, llama-server) do NOT run under
# --dry-run: enforcing them would make a dry run's exit code depend on whatever
# else happens to be running on the box at the moment, which is not what a dry run
# is for.
#
# No hardware access, ever: this script only calls Vivado in batch/-source mode on
# a Tcl file that contains no xsdb/hw_server/program/jtag call (global-constraints.md).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)

USAGE="usage: $0 [--dry-run] [--allow-scratch-root] [--allow-llama-server] [--allow-other-part] <root> [part] [allow_neg]"

DRY_RUN=0
ALLOW_SCRATCH_ROOT=0
ALLOW_LLAMA_SERVER=0
ALLOW_OTHER_PART=0
while true; do
  case "${1:-}" in
    --dry-run) DRY_RUN=1; shift ;;
    --allow-scratch-root) ALLOW_SCRATCH_ROOT=1; shift ;;
    --allow-llama-server) ALLOW_LLAMA_SERVER=1; shift ;;
    --allow-other-part) ALLOW_OTHER_PART=1; shift ;;
    *) break ;;
  esac
done
if [ $# -lt 1 ]; then
  echo "$USAGE" >&2
  exit 2
fi
ROOT=$1
PART=${2:-xcvu35p-fsvh2104-2L-e}
ALLOW_NEG=${3:-}
if [ -n "$ALLOW_NEG" ] && [ "$ALLOW_NEG" != "allow_neg" ]; then
  echo "$USAGE" >&2
  exit 2
fi

jccard_fail() {
  echo "JCCARD_FAIL $1"
  exit 1
}

# ---- I4: the root must live on the project's build-root tree, never /tmp or
#      anywhere else (CLAUDE.md: "nothing expensive under /tmp"; every other fk33
#      build's root, swap guard and results sit under /mnt/storage/fk33_builds/,
#      and this one is no exception). --allow-scratch-root exists for this
#      script's own tests, which must use a scratch directory, never a real build
#      root. --------------------------------------------------------------------
case "$ROOT" in
  /mnt/storage/fk33_builds/*) ;;
  *)
    if [ "$ALLOW_SCRATCH_ROOT" != 1 ]; then
      jccard_fail "root $ROOT is not under /mnt/storage/fk33_builds/ (pass --allow-scratch-root to override, for a test or a dry run only)"
    fi
    ;;
esac

# ---- minor 7: the part is pinned to the silicon in hand unless told otherwise. ----
if [ "$PART" != "xcvu35p-fsvh2104-2L-e" ] && [ "$ALLOW_OTHER_PART" != 1 ]; then
  jccard_fail "part $PART is not xcvu35p-fsvh2104-2L-e (pass --allow-other-part to build for a different part)"
fi

# ---- I3: refuse a root that already exists and is not empty. A stale build.log
#      left in a reused root can otherwise read as JCCARD_DONE when Vivado never
#      starts this run at all (the nonce gate below is the second line of defence;
#      this is the first -- never let it happen in the first place). ---------------
if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
  jccard_fail "root $ROOT already exists and is not empty; give a fresh root (a stale build.log in a reused root can read as done when Vivado never ran)"
fi

PATCH="$REPO/hw/fk33/results/card_build20_2026-09-24/build12_levers_off.patch"
# fix round 2: a stub run_capped.sh for tests, honoured by this env override;
# the default is unchanged (the real script). fix round 3, IMPORTANT: a BARE
# `RUN_CAPPED` (e.g. a stray `export RUN_CAPPED=...` left over in a shell)
# must not silently launch the real card build without the 24G cap and the
# 30 GiB swap guard -- that guard exists because of the 2026-08-30 hard hang
# (CLAUDE.md: "THE MEMORY BUDGET IS GLOBAL"). A non-default value is refused
# unless JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE=1 is ALSO set, which only this
# script's own tests set.
RUN_CAPPED_DEFAULT="$REPO/hw/jc/loader/run_capped.sh"
RUN_CAPPED="${RUN_CAPPED:-$RUN_CAPPED_DEFAULT}"
if [ "$RUN_CAPPED" != "$RUN_CAPPED_DEFAULT" ] && [ "${JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE:-}" != 1 ]; then
  jccard_fail "RUN_CAPPED=$RUN_CAPPED overrides the real $RUN_CAPPED_DEFAULT; this is refused unless JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE=1 is also set (test-only: a bare override would launch Vivado with no memory cap and no swap guard)"
fi
CLK_CORE_MHZ=200
MEM_HIGH=24G
SWAP_KILL_BYTES=32212254720   # 30 GiB, the project's standing card-build swap guard
UNIT="jccard_$(date +%s)_$$"
NONCE="$UNIT"                 # this run's identity, printed first by build_card.tcl
SRC="$ROOT/src"
PROJDIR="$ROOT/proj"
RESULTS="$ROOT/results"
BUILD_LOG="$ROOT/build.log"

# ---- I5 (print only; the budget itself is a read, never a refusal): state the
#      memory numbers out loud before doing anything, exactly as CLAUDE.md's THE
#      MEMORY BUDGET IS GLOBAL section requires of every Vivado dispatch. ---------
MEMAVAIL=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo 2>/dev/null || echo "")
SWAPFREE=$(awk '/^SwapFree:/{print $2*1024}' /proc/meminfo 2>/dev/null || echo "")

echo "JCCARD_RUN root=$ROOT part=$PART clk_core_mhz=$CLK_CORE_MHZ mem_high=$MEM_HIGH swap_kill_bytes=$SWAP_KILL_BYTES allow_neg=${ALLOW_NEG:-no} nonce=$NONCE"
echo "JCCARD_MEMORY_BUDGET MemAvailable=$MEMAVAIL SwapFree=$SWAPFREE requested_cap=$MEM_HIGH swap_kill=$SWAP_KILL_BYTES run_capped=$RUN_CAPPED"

# ---- fix round 2, CRITICAL: run() now ONLY PRINTS. The original version
# executed "$@" here AND the caller then executed the same command AGAIN in
# its own `if [ "$DRY_RUN" != 1 ]` block -- so every real (non-dry) run
# double-executed every step that used `run`: `git apply` twice (the second
# fails outright), both generators once in THIS SCRIPT'S OWN CALLER'S CWD
# (via run()'s unguarded "$@", with no `cd "$SRC"` at all -- a real
# invocation from the repo root would have overwritten the LIVE repo's
# hw/fk33/rtl/fk33_card.vhd, hw/jc/card/jc_card_bd.tcl/.xdc/jc_card_top.vhd
# with the 27B regeneration) and once more, correctly, in the companion
# block, and Vivado launched twice under one unit name. Every command below
# now has EXACTLY ONE execution site, inside the single `if/else` that both
# prints (via `run`, for an accurate --dry-run transcript) and, in the real
# branch only, executes.
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
}

# ---- 1. the tracked tree -----------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "+ mkdir -p $SRC"
  echo "+ git -C $REPO archive HEAD | tar -x -C $SRC"
else
  mkdir -p "$SRC" || jccard_fail "mkdir $SRC"
  git -C "$REPO" archive HEAD | tar -x -C "$SRC" \
    || jccard_fail "git archive HEAD into $SRC"
fi

# ---- 2. the levers patch, refusing on anything but a clean apply -------------------
if [ "$DRY_RUN" = 1 ]; then
  run git -C "$SRC" apply --check "$PATCH"
  run git -C "$SRC" apply "$PATCH"
else
  run git -C "$SRC" apply --check "$PATCH"
  git -C "$SRC" apply --check "$PATCH" \
    || jccard_fail "build12_levers_off.patch does not apply cleanly to $SRC"
  run git -C "$SRC" apply "$PATCH"
  git -C "$SRC" apply "$PATCH" \
    || jccard_fail "build12_levers_off.patch apply (after a clean --check) at $SRC"
fi

# ---- 3. provenance: HEAD and the patch's sha256 (the four regenerated files' own
#      sha256 are appended after step 4, once they exist -- minor 8) ---------------
if [ "$DRY_RUN" = 1 ]; then
  run git -C "$REPO" rev-parse HEAD
  run sha256sum "$PATCH"
else
  run git -C "$REPO" rev-parse HEAD
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD) || jccard_fail "git rev-parse HEAD"
  run sha256sum "$PATCH"
  PATCH_SHA=$(sha256sum "$PATCH" | awk '{print $1}')
  {
    echo "head=$HEAD_SHA"
    echo "patch=$PATCH"
    echo "patch_sha256=$PATCH_SHA"
    echo "part=$PART"
    echo "clk_core_mhz=$CLK_CORE_MHZ"
    echo "nonce=$NONCE"
  } > "$ROOT/PROVENANCE.txt"
fi

# ---- 4. regenerate the 27B card wrapper and the JC card BD/XDC/top, in $SRC -------
# JC_CARD_ENV (hw/jc/card/gen_jc_card.py), build 27B-1's generics: FK33_A_ROWS_IF
# unset, FK33_C_KV_BLOCK=16, FK33_C_MAXPOS=16384, FK33_MODEL=QWEN38_27B. This makes
# hw/fk33/rtl/fk33_card.vhd's GENSTAMP equal JC_CARD_ENV, which gen_jc_card.py then
# runs IN PLACE (card_is_jc() becomes true) instead of its scratch-copy path.
# Both generators run with cwd=$SRC (never the caller's cwd: each writes its
# output relative to its OWN cwd, not an argument, so the wrong cwd here is
# exactly what would regenerate the LIVE repo's committed files instead).
GEN_FK33_CARD_CMD=(env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
  -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_JOBS \
  -u FK33_SYNTH_THREADS -u FK33_A_ROWS_IF \
  FK33_C_KV_BLOCK=16 FK33_C_MAXPOS=16384 FK33_MODEL=QWEN38_27B \
  python3 hw/fk33/gen_fk33_card.py)
GEN_JC_CARD_CMD=(env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
  -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_THREADS \
  -u FK33_A_ROWS_IF -u FK33_C_KV_BLOCK -u FK33_C_MAXPOS -u FK33_MODEL \
  JC_CLK_CORE_MHZ="$CLK_CORE_MHZ" python3 hw/jc/card/gen_jc_card.py)
if [ "$DRY_RUN" = 1 ]; then
  echo "+ ( cd $SRC && $(printf '%q ' "${GEN_FK33_CARD_CMD[@]}")) > $ROOT/gen_fk33_card.log 2>&1"
  echo "+ ( cd $SRC && $(printf '%q ' "${GEN_JC_CARD_CMD[@]}")) > $ROOT/gen_jc_card.log 2>&1"
else
  echo "+ ( cd $SRC && $(printf '%q ' "${GEN_FK33_CARD_CMD[@]}")) > $ROOT/gen_fk33_card.log 2>&1"
  ( cd "$SRC" && "${GEN_FK33_CARD_CMD[@]}" ) > "$ROOT/gen_fk33_card.log" 2>&1 \
    || jccard_fail "gen_fk33_card.py (see $ROOT/gen_fk33_card.log)"
  echo "+ ( cd $SRC && $(printf '%q ' "${GEN_JC_CARD_CMD[@]}")) > $ROOT/gen_jc_card.log 2>&1"
  ( cd "$SRC" && "${GEN_JC_CARD_CMD[@]}" ) > "$ROOT/gen_jc_card.log" 2>&1 \
    || jccard_fail "gen_jc_card.py (see $ROOT/gen_jc_card.log)"
  GENERATED_FILES="hw/jc/card/jc_card_bd.tcl hw/jc/card/jc_card.xdc hw/jc/card/jc_card_top.vhd hw/fk33/rtl/fk33_card.vhd"
  for f in $GENERATED_FILES; do
    [ -s "$SRC/$f" ] || jccard_fail "gen_jc_card.py did not (re)write $f in $SRC"
  done
  grep -q "^wrote " "$ROOT/gen_jc_card.log" \
    || jccard_fail "gen_jc_card.py printed no 'wrote' line (see $ROOT/gen_jc_card.log)"
  # minor 8: the regenerated files' own sha256, so a later diff of two builds'
  # PROVENANCE.txt can tell "same patch, same HEAD" apart from "same patch, same
  # HEAD, but a different generated card" (a non-deterministic generator, or one
  # run with a different JC_CLK_CORE_MHZ, would otherwise look identical).
  {
    for f in $GENERATED_FILES; do
      echo "$(basename "$f")_sha256=$(sha256sum "$SRC/$f" | awk '{print $1}')"
    done
  } >> "$ROOT/PROVENANCE.txt"
fi

# ---- I5: refuse if another Vivado is already running (one Vivado per box) or if
#      llama-server is running (a full build needs it stopped, unless overridden),
#      identified by /proc/PID/exe -- NEVER pgrep -f or a /proc loop matching
#      cmdline (CLAUDE.md: both have matched a script's own text on this project
#      and killed the wrong thing; a presence CHECK built the same way would
#      equally match this very script's text in `ps`/`pgrep -f` output and refuse
#      itself for no reason). Not enforced under --dry-run: see the file header. --
_exe_matches() {
  # prints "<pid> <exe>" for every process whose /proc/PID/exe resolves to a path
  # matching the glob $1; silently skips a PID that raced away mid-scan.
  local pat="$1" p e
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    e=$(readlink "/proc/$p/exe" 2>/dev/null) || continue
    case "$e" in $pat) echo "$p $e" ;; esac
  done
}
if [ "$DRY_RUN" = 1 ]; then
  echo "+ check /proc/*/exe for */unwrapped/lnx64.o/vivado* (refuse if any) and */llama-server (refuse unless --allow-llama-server)"
else
  VIVADO_HITS=$(_exe_matches '*/unwrapped/lnx64.o/vivado*')
  if [ -n "$VIVADO_HITS" ]; then
    jccard_fail "another Vivado is already running (one Vivado per box): $VIVADO_HITS"
  fi
  LLAMA_HITS=$(_exe_matches '*/llama-server')
  if [ -n "$LLAMA_HITS" ] && [ "$ALLOW_LLAMA_SERVER" != 1 ]; then
    jccard_fail "llama-server is running (a full build needs it stopped; pass --allow-llama-server to override): $LLAMA_HITS"
  fi
fi

# ---- 5. Vivado, capped -------------------------------------------------------------
BUILD_CARD_TCL="$SRC/hw/jc/card/build_card.tcl"
VIVADO_ARGS=("$PROJDIR" "$PART")
if [ -n "$ALLOW_NEG" ]; then VIVADO_ARGS+=(allow_neg); fi
VIVADO_ARGS+=(-nonce "$NONCE")
# I3: delete (never append to) any stale log before this run's Vivado writes one.
# The non-empty-root refusal above already makes this unreachable in the normal
# case; this is the second, independent layer, and it is unconditional because a
# log Vivado is about to overwrite with -log is not one worth preserving anyway.
VIVADO_CMD=(bash "$RUN_CAPPED" "$UNIT" "$MEM_HIGH" "$SWAP_KILL_BYTES" "$ROOT" \
  vivado -mode batch -nojournal -log "$BUILD_LOG" -source "$BUILD_CARD_TCL" \
  -tclargs "${VIVADO_ARGS[@]}")
if [ "$DRY_RUN" = 1 ]; then
  run rm -f "$BUILD_LOG"
  run "${VIVADO_CMD[@]}"
else
  rm -f "$BUILD_LOG"
  run "${VIVADO_CMD[@]}"
  "${VIVADO_CMD[@]}"
  RC=$?
  # The sentinel is read from Vivado's OWN log, anchored, never from $RC alone: a
  # killed unit (the swap guard) and a timed-out waiter both exit non-zero with no
  # JCCARD_DONE line, and that absence is what this gates on, not the number.
  # I3: ALSO gated on the log carrying THIS run's own nonce, with JCCARD_DONE
  # appearing AFTER it -- a log that somehow survived from an earlier run (or was
  # concatenated with one) cannot satisfy both conditions in order.
  NONCE_LINE=$(grep -nE "^JCCARD_NONCE ${NONCE}\$" "$BUILD_LOG" 2>/dev/null | head -1 | cut -d: -f1)
  DONE_LINE=$(grep -nE '^JCCARD_DONE' "$BUILD_LOG" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$NONCE_LINE" ] && [ -n "$DONE_LINE" ] && [ "$DONE_LINE" -gt "$NONCE_LINE" ]; then
    SENTINEL_OK=1
  else
    SENTINEL_OK=0
  fi
  if [ "$SENTINEL_OK" != 1 ]; then
    REASON=$(grep -E '^JCCARD_FAIL' "$BUILD_LOG" | tail -1)
    if [ -z "$REASON" ]; then
      REASON="JCCARD_FAIL no JCCARD_DONE after this run's JCCARD_NONCE ($NONCE) in $BUILD_LOG (vivado rc=$RC; check the swap guard log)"
    fi
    echo "$REASON"
    exit 1
  fi
fi

# ---- 6. harvest ---------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "+ mkdir -p $RESULTS"
  echo "+ cp $PROJDIR/reports/{utilization,utilization_hier,timing_summary,cdc,cdc_summary}.rpt $RESULTS/"
  echo "+ cp $PROJDIR/jc_card.bit $PROJDIR/jc_card.ltx $RESULTS/"
else
  mkdir -p "$RESULTS" || jccard_fail "mkdir $RESULTS"
  for f in utilization.rpt utilization_hier.rpt timing_summary.rpt cdc.rpt cdc_summary.rpt \
           route_status.rpt clock_interaction.rpt clocks.rpt exceptions.rpt \
           exceptions_ignored.rpt bus_skew.rpt methodology.rpt drc.rpt pulse_width.rpt \
           check_timing.rpt; do
    [ -f "$PROJDIR/reports/$f" ] && cp "$PROJDIR/reports/$f" "$RESULTS/"
  done
  [ -f "$PROJDIR/jc_card.bit" ] && cp "$PROJDIR/jc_card.bit" "$RESULTS/"
  [ -f "$PROJDIR/jc_card.ltx" ] && cp "$PROJDIR/jc_card.ltx" "$RESULTS/"
  cp "$BUILD_LOG" "$RESULTS/" 2>/dev/null || true
fi

# ---- 7. the sentinel, anchored ------------------------------------------------------
# minor 9: a dry run must never print a line beginning with JCCARD_DONE -- that
# string, at the start of a line, is this script's OWN completion sentinel, and an
# automated caller greping for it must never read a dry run as a real one.
if [ "$DRY_RUN" = 1 ]; then
  echo "DRYRUN would write: JCCARD_DONE"
  exit 0
fi
echo "JCCARD_DONE"
exit 0
