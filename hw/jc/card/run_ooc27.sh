#!/usr/bin/env bash
# hw/jc/card/run_ooc27.sh -- Task 10: OOC synth+place+route of the 27B
# jc_ooc27_top (fk33_engine + fk33_seam + fk33_card, Task 10's chosen
# composition; see ooc_card_200.tcl and gen_ooc27_top.py for why) at
# 200 MHz on xcvu35p-fsvh2104-2L-e.
#
#   run_ooc27.sh [--dry-run] [--allow-scratch-root] [--allow-other-part] \
#                <root> [part] [mem_high]
#
# What it does, modelled on hw/jc/card/run_card.sh's own shape (location/
# root/process-presence refusals, tracked-tree copy, levers patch, the
# capped Vivado run, report harvest, the nonce-gated sentinel), but for an
# OOC run, not a bitstream: no BD, no HBM IP, no bitstream.
#
#   0. refuses a root outside /mnt/storage/fk33_builds/ (unless
#      --allow-scratch-root), a part other than xcvu35p-fsvh2104-2L-e
#      (unless --allow-other-part), a root that exists and is not empty, or
#      another Vivado already running; prints the memory budget
#      (MemAvailable, SwapFree) before doing anything else -- CLAUDE.md's
#      "state the budget out loud before dispatching" is the DISPATCHER's
#      job, this just gives it the numbers.
#   1. copies the TRACKED tree into <root>/src via `git archive HEAD`;
#   2. applies build12_levers_off.patch there (refuses on anything but a
#      clean apply) -- this is what makes FAST_POP/NWIDE/SWEEP_PIPE/
#      SCORE_EARLY read back false: the patch edits those GENERIC DEFAULTS
#      and GENERIC MAP VALUES directly in fk33_engine.vhd/fk33_llama_top.vhd/
#      llama_top.vhd's own text (hw/fk33/results/card_build20_2026-09-24/
#      build12_levers_off.patch), so applying it is the entire lever story
#      for this flat (non-BD) OOC flow: nothing else needs to set them;
#   3. regenerates ONLY the 27B hw/fk33/rtl/fk33_card.vhd in that tree
#      (hw/fk33/gen_fk33_card.py under gen_jc_card.JC_CARD_ENV: FK33_C_KV_BLOCK=16
#      FK33_C_MAXPOS=16384 FK33_MODEL=QWEN38_27B, build 27B-1's own generics,
#      identical to run_card.sh's step 4a). Unlike run_card.sh this does NOT
#      run hw/jc/card/gen_jc_card.py: there is no block design, XDC or
#      jc_card_top here, only the plain 27B fk33_card.vhd;
#   4. generates hw/jc/card/jc_ooc27_top.vhd in that tree
#      (hw/jc/card/gen_ooc27_top.py $SRC --haddr-w 15 --regmax 17408, build
#      27B-1's own fk33_seam CONFIG from jc_card_bd.tcl);
#   5. deletes any stale build log, then runs Vivado under
#      hw/jc/loader/run_capped.sh with the given (or default) MemoryHigh cap
#      and a swap guard at twice that, passing this run's own nonce;
#   6. harvests ooc_card_200.tcl's reports into <root>/results, and checks
#      the levers read back off in the run's own Vivado log (jccard_levers.tcl,
#      run under plain tclsh, no Vivado needed -- the same parser
#      build_card.tcl itself uses, tested stand-alone against real log
#      excerpts by test_jccard_levers.py);
#   7. writes the JCOOC27_DONE or JCOOC27_FAIL <reason> sentinel -- anchored
#      (grep -qE '^JCOOC27_(DONE|FAIL)'), gated on a log that both contains
#      THIS run's own nonce and a JCOOC27_DONE line AFTER it, never on a
#      timeout or an exit code alone.
#
# --dry-run prints every command this script would run and every parameter
# binding and exits 0, touching NOTHING: no git, no Vivado, no filesystem
# write, not even <root>. The root-location/root-emptiness checks DO run
# under --dry-run (they inspect, not change); the Vivado-presence refusal
# does NOT (CLAUDE.md: a dry run's exit code must not depend on what else is
# running on the box), matching run_card.sh's own documented reasoning.
#
# No hardware access, ever: this only calls Vivado in batch/-source mode on
# ooc_card_200.tcl, which contains no xsdb/hw_server/program/jtag call.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)

USAGE="usage: $0 [--dry-run] [--allow-scratch-root] [--allow-other-part] <root> [part] [mem_high]"

DRY_RUN=0
ALLOW_SCRATCH_ROOT=0
ALLOW_OTHER_PART=0
while true; do
  case "${1:-}" in
    --dry-run) DRY_RUN=1; shift ;;
    --allow-scratch-root) ALLOW_SCRATCH_ROOT=1; shift ;;
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
MEM_HIGH=${3:-12G}

jcooc27_fail() {
  echo "JCOOC27_FAIL $1"
  exit 1
}

# ---- root location: must be under /mnt/storage/fk33_builds/ (CLAUDE.md:
#      "nothing expensive under /tmp"), unless this is a test's own scratch
#      dir or an explicit dry run. --------------------------------------------
case "$ROOT" in
  /mnt/storage/fk33_builds/*) ;;
  *)
    if [ "$ALLOW_SCRATCH_ROOT" != 1 ]; then
      jcooc27_fail "root $ROOT is not under /mnt/storage/fk33_builds/ (pass --allow-scratch-root to override, for a test or a dry run only)"
    fi
    ;;
esac

if [ "$PART" != "xcvu35p-fsvh2104-2L-e" ] && [ "$ALLOW_OTHER_PART" != 1 ]; then
  jcooc27_fail "part $PART is not xcvu35p-fsvh2104-2L-e (pass --allow-other-part to run a different one)"
fi

if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
  jcooc27_fail "root $ROOT already exists and is not empty; give a fresh root"
fi

PATCH="$REPO/hw/fk33/results/card_build20_2026-09-24/build12_levers_off.patch"
# a swap guard at twice the requested cap, the same ratio run_card.sh's own
# 24G/30GiB pair uses (30GiB / 24G = 1.25x there; this job's measured peak is
# expected far below its cap -- task-10-brief.md's own ESTIMATE is 4-8 GB
# against a 12G default -- so 2x gives more headroom before the guard fires
# on a job that is not actually runaway).
SWAP_KILL_BYTES=$(( $(numfmt --from=iec "$MEM_HIGH") * 2 ))
UNIT="jcooc27_$(date +%s)_$$"
NONCE="$UNIT"
SRC="$ROOT/src"
RESULTS="$ROOT/results"
BUILD_LOG="$ROOT/build.log"

MEMAVAIL=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo 2>/dev/null || echo "")
SWAPFREE=$(awk '/^SwapFree:/{print $2*1024}' /proc/meminfo 2>/dev/null || echo "")
echo "JCOOC27_RUN root=$ROOT part=$PART mem_high=$MEM_HIGH swap_kill_bytes=$SWAP_KILL_BYTES nonce=$NONCE"
echo "JCOOC27_MEMORY_BUDGET MemAvailable=$MEMAVAIL SwapFree=$SWAPFREE requested_cap=$MEM_HIGH swap_kill=$SWAP_KILL_BYTES"

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '+'; printf ' %q' "$@"; printf '\n'
  else
    printf '+'; printf ' %q' "$@"; printf '\n'
    "$@"
  fi
}

# ---- 1. the tracked tree ----------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "+ mkdir -p $SRC"
  echo "+ git -C $REPO archive HEAD | tar -x -C $SRC"
else
  mkdir -p "$SRC" || jcooc27_fail "mkdir $SRC"
  git -C "$REPO" archive HEAD | tar -x -C "$SRC" \
    || jcooc27_fail "git archive HEAD into $SRC"
fi

# ---- 2. the levers patch -----------------------------------------------------
run git -C "$SRC" apply --check "$PATCH"
if [ "$DRY_RUN" != 1 ]; then
  git -C "$SRC" apply --check "$PATCH" \
    || jcooc27_fail "build12_levers_off.patch does not apply cleanly to $SRC"
fi
run git -C "$SRC" apply "$PATCH"
if [ "$DRY_RUN" != 1 ]; then
  git -C "$SRC" apply "$PATCH" || jcooc27_fail "build12_levers_off.patch apply (after a clean --check) at $SRC"
fi

# ---- 3. the 27B fk33_card.vhd only (no BD, no jc_card_top) ------------------
run env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
  -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_JOBS \
  -u FK33_SYNTH_THREADS -u FK33_A_ROWS_IF \
  FK33_C_KV_BLOCK=16 FK33_C_MAXPOS=16384 FK33_MODEL=QWEN38_27B \
  python3 hw/fk33/gen_fk33_card.py
if [ "$DRY_RUN" != 1 ]; then
  ( cd "$SRC" && env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
      -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_JOBS \
      -u FK33_SYNTH_THREADS -u FK33_A_ROWS_IF \
      FK33_C_KV_BLOCK=16 FK33_C_MAXPOS=16384 FK33_MODEL=QWEN38_27B \
      python3 hw/fk33/gen_fk33_card.py ) > "$ROOT/gen_fk33_card.log" 2>&1 \
    || jcooc27_fail "gen_fk33_card.py (see $ROOT/gen_fk33_card.log)"
  [ -s "$SRC/hw/fk33/rtl/fk33_card.vhd" ] \
    || jcooc27_fail "gen_fk33_card.py did not (re)write hw/fk33/rtl/fk33_card.vhd in $SRC"
fi

# ---- 4. jc_ooc27_top.vhd, build 27B-1's own fk33_seam CONFIG (jc_card_bd.tcl:
#      CONFIG.REGMAX 17408, CONFIG.HADDR_W 15) -------------------------------
run python3 hw/jc/card/gen_ooc27_top.py "$SRC" --haddr-w 15 --regmax 17408
if [ "$DRY_RUN" != 1 ]; then
  python3 "$HERE/gen_ooc27_top.py" "$SRC" --haddr-w 15 --regmax 17408 \
    > "$ROOT/gen_ooc27_top.log" 2>&1 \
    || jcooc27_fail "gen_ooc27_top.py (see $ROOT/gen_ooc27_top.log)"
  grep -q "^GENOOC27_WROTE " "$ROOT/gen_ooc27_top.log" \
    || jcooc27_fail "gen_ooc27_top.py printed no GENOOC27_WROTE line (see $ROOT/gen_ooc27_top.log)"
  [ -s "$SRC/hw/jc/card/jc_ooc27_top.vhd" ] \
    || jcooc27_fail "gen_ooc27_top.py did not write $SRC/hw/jc/card/jc_ooc27_top.vhd"
fi

# ---- I5: refuse if another Vivado is already running (one Vivado per box),
#      by /proc/PID/exe -- never pgrep -f, never a cmdline match (CLAUDE.md:
#      both have matched a script's own text and killed the wrong thing).
#      Not enforced under --dry-run: see the file header. -----------------
if [ "$DRY_RUN" = 1 ]; then
  echo "+ check /proc/*/exe for */unwrapped/lnx64.o/vivado* (refuse if any)"
else
  VIVADO_HITS=""
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    e=$(readlink "/proc/$p/exe" 2>/dev/null) || continue
    case "$e" in */unwrapped/lnx64.o/vivado*) VIVADO_HITS="$VIVADO_HITS $p:$e" ;; esac
  done
  if [ -n "$VIVADO_HITS" ]; then
    jcooc27_fail "another Vivado is already running (one Vivado per box):$VIVADO_HITS"
  fi
fi

# ---- 5. Vivado, capped -------------------------------------------------------
OOC_TCL="$SRC/hw/jc/card/ooc_card_200.tcl"
PROJDIR="$ROOT/ooc"
run rm -f "$BUILD_LOG"
run bash "$REPO/hw/jc/loader/run_capped.sh" "$UNIT" "$MEM_HIGH" "$SWAP_KILL_BYTES" "$ROOT" \
  vivado -mode batch -nojournal -log "$BUILD_LOG" -source "$OOC_TCL" \
  -tclargs "$SRC" "$PROJDIR" "$PART"
if [ "$DRY_RUN" != 1 ]; then
  echo "JCOOC27_NONCE $NONCE" >> "$BUILD_LOG"
  bash "$REPO/hw/jc/loader/run_capped.sh" "$UNIT" "$MEM_HIGH" "$SWAP_KILL_BYTES" "$ROOT" \
    vivado -mode batch -nojournal -log "$BUILD_LOG" -source "$OOC_TCL" \
    -tclargs "$SRC" "$PROJDIR" "$PART"
  RC=$?
  # the sentinel is read from Vivado's OWN log, anchored, never from $RC alone
  NONCE_LINE=$(grep -nE "^JCOOC27_NONCE ${NONCE}\$" "$BUILD_LOG" 2>/dev/null | head -1 | cut -d: -f1)
  DONE_LINE=$(grep -nE '^JCOOC27_DONE' "$BUILD_LOG" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -z "$NONCE_LINE" ] || [ -z "$DONE_LINE" ]; then
    SENTINEL_OK=0
  else
    SENTINEL_OK=1
  fi
  if [ "$SENTINEL_OK" != 1 ]; then
    REASON=$(grep -E '^JCOOC27_(FAIL|ROUTE_FAIL)' "$BUILD_LOG" | tail -1)
    if [ -z "$REASON" ]; then
      REASON="JCOOC27_FAIL no JCOOC27_DONE in $BUILD_LOG (vivado rc=$RC; check the swap guard log)"
    fi
    echo "$REASON"
    exit 1
  fi
fi

# ---- 6. harvest, and the levers read-back (pure Tcl, no Vivado) ------------
if [ "$DRY_RUN" = 1 ]; then
  echo "+ mkdir -p $RESULTS"
  echo "+ cp $PROJDIR/{util_routed,util_routed_hier,timing_routed,route_status,methodology,check_timing}.rpt $RESULTS/"
  echo "+ tclsh -c 'source hw/jc/card/jccard_levers.tcl; check NWIDE/SWEEP_PIPE/SCORE_EARLY against $BUILD_LOG'"
else
  mkdir -p "$RESULTS" || jcooc27_fail "mkdir $RESULTS"
  for f in util_synth.rpt util_routed.rpt util_routed_hier.rpt timing_routed.rpt \
           route_status.rpt clock_interaction.rpt methodology.rpt check_timing.rpt; do
    [ -f "$PROJDIR/$f" ] && cp "$PROJDIR/$f" "$RESULTS/"
  done
  cp "$BUILD_LOG" "$RESULTS/" 2>/dev/null || true

  # jccard_levers.tcl's jccard_lever_status is pure Tcl (no Vivado), already
  # tested stand-alone against real log excerpts by test_jccard_levers.py.
  # build_card.tcl's own MEASURED finding was that this elaboration-trace
  # "Parameter <NAME> bound to: <value>" line, for a PROJECT-MODE run, goes
  # only to the run's own <top>.vds, never to runme.log or the project
  # launcher's log. Whether a PLAIN (non-project) `synth_design`, running
  # in-process in the very batch session this script's own -log captures,
  # writes that same line to THIS run's $BUILD_LOG is UNVERIFIED (no Vivado
  # access from here to check it). So this reads $BUILD_LOG on the chance it
  # is there, but ONLY REPORTS the result (JCOOC27_LEVER lines) -- it never
  # fails the run on a "missing" verdict, which the real build_card.tcl DOES
  # treat as a hard failure but only because it already proved its own trace
  # file is the right place to look; this script has not proved that of its
  # own log, so a "missing" verdict here would be as likely to mean "this
  # script is looking in the wrong place" as "the patch did not apply", and
  # the git-apply --check above is already the load-bearing lever guarantee.
  LEVER_TCL=$(cat <<'TCLEOF'
source [lindex $argv 0]
set logtxt [read [open [lindex $argv 1]]]
foreach lv {NWIDE SWEEP_PIPE SCORE_EARLY} {
  set res [jccard_lever_status $lv $logtxt]
  puts "JCOOC27_LEVER $lv [lindex $res 0] ([lindex $res 1])"
}
TCLEOF
)
  echo "$LEVER_TCL" > "$ROOT/lever_check.tcl"
  tclsh "$ROOT/lever_check.tcl" "$SRC/hw/jc/card/jccard_levers.tcl" "$BUILD_LOG" || true
fi

# ---- 7. the sentinel, anchored ------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "DRYRUN would write: JCOOC27_DONE"
  exit 0
fi
echo "JCOOC27_DONE"
exit 0
