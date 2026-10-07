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
#   5. a FATAL grep of the patched sources (fix round 1, I6) for FAST_POP's
#      generic default, NWIDE/SWEEP_PIPE/SCORE_EARLY's generic-map values,
#      and PIPE/WIDE/MAXOUT 8's own (unpatched) values, BEFORE Vivado runs
#      at all -- the load-bearing lever check, independent of whether
#      Vivado's own elaboration trace ever reaches this run's log;
#   6. deletes any stale build log, then runs Vivado under
#      hw/jc/loader/run_capped.sh with the given (or default) MemoryHigh cap
#      and a 4 GiB swap guard, passing this run's own nonce on -tclargs
#      (fix round 1, I2: NOT appended to the log file by this script, which
#      Vivado's own -log truncates/rotates before writing anything -- the
#      Tcl prints its own nonce first instead, build_card.tcl's own pattern);
#   7. harvests ooc_card_200.tcl's reports into <root>/results, and reads
#      back the levers from the run's own Vivado log too (jccard_levers.tcl,
#      run under plain tclsh, no Vivado needed) as a second opinion -- FATAL
#      on "on" or "mixed" (fix round 1, I6), non-fatal only on "missing"
#      (this script's own log may simply not be where Vivado's elaboration
#      trace lands for a plain, non-project synth_design; see the comment
#      at the check itself);
#   8. writes the JCOOC27_DONE or JCOOC27_FAIL <reason> sentinel -- anchored
#      (grep -qE '^JCOOC27_(DONE|FAIL)'), gated on a log that both contains
#      THIS run's own nonce and a JCOOC27_DONE line strictly AFTER it (line
#      number, not just both present), never on a timeout or an exit code
#      alone.
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
# fix round 1, I3: the memory basis was wrong. The ORIGINAL default (12G
# cap, 2x/24GiB swap guard) was an ESTIMATE extrapolated from "2.58 GiB for
# fk33_card OOC" in task-10-brief.md -- but that number is from a DIFFERENT,
# smaller OOC (fk33_card alone, no engine). Vivado's own log from the real
# reference runs reports a peak of 11780 MB for the 27B fk33_card OOC ALONE
# and 9008 MB for fk33_engine OOC ALONE (ooc27_vu35/{fk33_card,fk33_engine}/
# build.log); this composition adds both together in one placement, so
# ESTIMATE 16-20 GB, not 4-8. 22G leaves headroom above that without
# reaching the 24G/30GiB card-build shape; the swap guard is a FIXED 4 GiB,
# not scaled to the cap (swap in use at all, this early in the project's own
# measured shape, is already the leading indicator CLAUDE.md names, not a
# multiple of whatever cap was requested).
MEM_HIGH=${3:-22G}
SWAP_KILL_BYTES=4294967296   # fixed 4 GiB (fix round 1, I3)

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
# fix round 2: a stub run_capped.sh for tests, honoured by this env override;
# the default is unchanged (the real script). fix round 3, IMPORTANT: a BARE
# `RUN_CAPPED` (e.g. a stray `export RUN_CAPPED=...` left over in a shell)
# must not silently launch the real build without the 24G cap and the swap
# guard -- that guard exists because of the 2026-08-30 hard hang (CLAUDE.md:
# "THE MEMORY BUDGET IS GLOBAL"). A non-default value is refused unless
# JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE=1 is ALSO set, which only this script's
# own tests set.
RUN_CAPPED_DEFAULT="$REPO/hw/jc/loader/run_capped.sh"
RUN_CAPPED="${RUN_CAPPED:-$RUN_CAPPED_DEFAULT}"
if [ "$RUN_CAPPED" != "$RUN_CAPPED_DEFAULT" ] && [ "${JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE:-}" != 1 ]; then
  jcooc27_fail "RUN_CAPPED=$RUN_CAPPED overrides the real $RUN_CAPPED_DEFAULT; this is refused unless JC_TEST_ALLOW_RUN_CAPPED_OVERRIDE=1 is also set (test-only: a bare override would launch Vivado with no memory cap and no swap guard)"
fi
UNIT="jcooc27_$(date +%s)_$$"
NONCE="$UNIT"
SRC="$ROOT/src"
RESULTS="$ROOT/results"
BUILD_LOG="$ROOT/build.log"

MEMAVAIL=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo 2>/dev/null || echo "")
SWAPFREE=$(awk '/^SwapFree:/{print $2*1024}' /proc/meminfo 2>/dev/null || echo "")
echo "JCOOC27_RUN root=$ROOT part=$PART mem_high=$MEM_HIGH swap_kill_bytes=$SWAP_KILL_BYTES nonce=$NONCE"
echo "JCOOC27_MEMORY_BUDGET MemAvailable=$MEMAVAIL SwapFree=$SWAPFREE requested_cap=$MEM_HIGH swap_kill=$SWAP_KILL_BYTES run_capped=$RUN_CAPPED"

# ---- fix round 1, I3: refuse if MemAvailable is below cap+2G. Not enforced
#      under --dry-run (same reasoning as the Vivado-presence refusal below:
#      a dry run's exit code must not depend on what else the box is doing
#      right now). numfmt turns "22G" into bytes the same way the swap-kill
#      arithmetic elsewhere in this project's scripts does. ---------------
if [ "$DRY_RUN" != 1 ] && [ -n "$MEMAVAIL" ]; then
  CAP_BYTES=$(numfmt --from=iec "$MEM_HIGH")
  HEADROOM_BYTES=2147483648   # 2 GiB
  if [ "$MEMAVAIL" -lt "$((CAP_BYTES + HEADROOM_BYTES))" ]; then
    jcooc27_fail "MemAvailable=$MEMAVAIL is below cap ($MEM_HIGH = $CAP_BYTES bytes) + 2 GiB headroom"
  fi
fi

# ---- fix round 2, CRITICAL: run() now ONLY PRINTS. The original version
# executed "$@" here AND the caller then executed the same command AGAIN in
# its own `if [ "$DRY_RUN" != 1 ]` block -- so every real (non-dry) run
# double-executed every step that used `run`: `git apply` twice (the second
# fails outright), the two generators once in THIS SCRIPT'S OWN CALLER'S
# CWD (via run()'s unguarded "$@", with no `cd "$SRC"` at all -- a real
# invocation from the repo root would have overwritten the LIVE repo's
# hw/fk33/rtl/fk33_card.vhd with the 27B regeneration) and once more,
# correctly, in the companion block, and Vivado launched twice under one
# unit name. Every command below now has EXACTLY ONE execution site, inside
# the single `if/else` that both prints (via `run`, for an accurate --dry-run
# transcript) and, in the real branch only, executes.
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
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
if [ "$DRY_RUN" = 1 ]; then
  run git -C "$SRC" apply --check "$PATCH"
  run git -C "$SRC" apply "$PATCH"
else
  run git -C "$SRC" apply --check "$PATCH"
  git -C "$SRC" apply --check "$PATCH" \
    || jcooc27_fail "build12_levers_off.patch does not apply cleanly to $SRC"
  run git -C "$SRC" apply "$PATCH"
  git -C "$SRC" apply "$PATCH" \
    || jcooc27_fail "build12_levers_off.patch apply (after a clean --check) at $SRC"
fi

# ---- 3. the 27B fk33_card.vhd only (no BD, no jc_card_top) ------------------
# Runs with cwd=$SRC (never the caller's cwd: gen_fk33_card.py writes its
# output relative to its OWN cwd, not an argument, so the wrong cwd here is
# exactly what would regenerate the LIVE repo's committed file instead).
GEN_FK33_CARD_CMD=(env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
  -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_JOBS \
  -u FK33_SYNTH_THREADS -u FK33_A_ROWS_IF \
  FK33_C_KV_BLOCK=16 FK33_C_MAXPOS=16384 FK33_MODEL=QWEN38_27B \
  python3 hw/fk33/gen_fk33_card.py)
if [ "$DRY_RUN" = 1 ]; then
  echo "+ ( cd $SRC && $(printf '%q ' "${GEN_FK33_CARD_CMD[@]}")) > $ROOT/gen_fk33_card.log 2>&1"
else
  echo "+ ( cd $SRC && $(printf '%q ' "${GEN_FK33_CARD_CMD[@]}")) > $ROOT/gen_fk33_card.log 2>&1"
  ( cd "$SRC" && "${GEN_FK33_CARD_CMD[@]}" ) > "$ROOT/gen_fk33_card.log" 2>&1 \
    || jcooc27_fail "gen_fk33_card.py (see $ROOT/gen_fk33_card.log)"
  [ -s "$SRC/hw/fk33/rtl/fk33_card.vhd" ] \
    || jcooc27_fail "gen_fk33_card.py did not (re)write hw/fk33/rtl/fk33_card.vhd in $SRC"
fi

# ---- 4. jc_ooc27_top.vhd, build 27B-1's own fk33_seam CONFIG (jc_card_bd.tcl:
#      CONFIG.REGMAX 17408, CONFIG.HADDR_W 15) -------------------------------
# gen_ooc27_top.py itself takes <repo_root> as an explicit argument (it does
# not rely on cwd to find anything), but the exactly-once rule still applies:
# this must run no more than once per invocation of this script. fix round
# 3: the GENERATOR ITSELF must be read from the archived $SRC, never from
# $HERE (the live checkout) -- otherwise a run against an older/different
# commit's $SRC would still execute THIS session's live gen_ooc27_top.py,
# silently breaking the provenance this whole tracked-tree-copy step exists
# to establish (step 1's own comment: "copies the TRACKED tree into
# <root>/src via `git archive HEAD`" is pointless if a later step reads the
# generator from outside that tree anyway).
GEN_OOC27_TOP_CMD=(python3 "$SRC/hw/jc/card/gen_ooc27_top.py" "$SRC" --haddr-w 15 --regmax 17408)
if [ "$DRY_RUN" = 1 ]; then
  run "${GEN_OOC27_TOP_CMD[@]}"
else
  run "${GEN_OOC27_TOP_CMD[@]}"
  "${GEN_OOC27_TOP_CMD[@]}" > "$ROOT/gen_ooc27_top.log" 2>&1 \
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

# ---- fix round 1, I6: a FATAL grep of the patched sources, BEFORE Vivado
#      runs at all. This is the LOAD-BEARING lever check -- the post-run
#      log-based one further down is a second opinion of unverified
#      reliability, not a substitute for this. Exact text, taken directly
#      from build12_levers_off.patch's own diff hunks (fix round 1 report). --
LEVERS_PRE_CHECKS=(
  "hw/fk33/rtl/fk33_engine.vhd|FAST_POP : boolean := false|FAST_POP default false"
  "rtl/fk33_llama_top.vhd|NWIDE        => false,|NWIDE => false"
  "rtl/fk33_llama_top.vhd|SWEEP_PIPE => false, SCORE_EARLY => false)|SWEEP_PIPE/SCORE_EARLY => false"
  "rtl/fk33_llama_top.vhd|PIPE         => true,|PIPE => true (unpatched, must stay on)"
  "rtl/fk33_llama_top.vhd|WIDE         => true)|WIDE => true (unpatched, must stay on)"
  "rtl/fk33_llama_top.vhd|MAXOUT       => 8,|MAXOUT => 8 (unpatched, must stay on)"
)
if [ "$DRY_RUN" = 1 ]; then
  for row in "${LEVERS_PRE_CHECKS[@]}"; do
    IFS='|' read -r f pat label <<< "$row"
    echo "+ grep -qF $pat $SRC/$f  # $label"
  done
else
  for row in "${LEVERS_PRE_CHECKS[@]}"; do
    IFS='|' read -r f pat label <<< "$row"
    grep -qF -- "$pat" "$SRC/$f" \
      || jcooc27_fail "levers (pre-Vivado): $label not found in $SRC/$f -- build12_levers_off.patch did not take effect as expected"
  done
  echo "JCOOC27_LEVERS_PRE_CHECK_OK ${#LEVERS_PRE_CHECKS[@]} patterns"
fi

# ---- 5. Vivado, capped -------------------------------------------------------
OOC_TCL="$SRC/hw/jc/card/ooc_card_200.tcl"
PROJDIR="$ROOT/ooc"
# fix round 1, I2: the nonce goes on -tclargs, and ooc_card_200.tcl prints it
# FIRST, before anything else -- build_card.tcl's own pattern. The original
# version instead appended "JCOOC27_NONCE $NONCE" to $BUILD_LOG before
# launching Vivado, but Vivado's own -log truncates/rewrites the file it is
# given from scratch, so that line never survived for the gate below to find,
# and every run therefore read as JCOOC27_FAIL regardless of what Vivado did.
VIVADO_CMD=(bash "$RUN_CAPPED" "$UNIT" "$MEM_HIGH" "$SWAP_KILL_BYTES" "$ROOT" \
  vivado -mode batch -nojournal -log "$BUILD_LOG" -source "$OOC_TCL" \
  -tclargs "$SRC" "$PROJDIR" "$PART" -nonce "$NONCE")
if [ "$DRY_RUN" = 1 ]; then
  run rm -f "$BUILD_LOG"
  run "${VIVADO_CMD[@]}"
else
  rm -f "$BUILD_LOG"
  run "${VIVADO_CMD[@]}"
  "${VIVADO_CMD[@]}"
  RC=$?
  # the sentinel is read from Vivado's OWN log, anchored, never from $RC
  # alone, and DONE must come STRICTLY AFTER the nonce by LINE NUMBER (a
  # stale JCOOC27_DONE surviving from an earlier run in a reused log cannot
  # satisfy both conditions in order; two bare "both present" checks could).
  NONCE_LINE=$(grep -nE "^JCOOC27_NONCE ${NONCE}\$" "$BUILD_LOG" 2>/dev/null | head -1 | cut -d: -f1)
  DONE_LINE=$(grep -nE '^JCOOC27_DONE' "$BUILD_LOG" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -n "$NONCE_LINE" ] && [ -n "$DONE_LINE" ] && [ "$DONE_LINE" -gt "$NONCE_LINE" ]; then
    SENTINEL_OK=1
  else
    SENTINEL_OK=0
  fi
  if [ "$SENTINEL_OK" != 1 ]; then
    REASON=$(grep -E '^JCOOC27_FAIL' "$BUILD_LOG" | tail -1)
    if [ -z "$REASON" ]; then
      REASON="JCOOC27_FAIL no JCOOC27_DONE after this run's JCOOC27_NONCE ($NONCE) in $BUILD_LOG (vivado rc=$RC; check the swap guard log)"
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
  # This is a SECOND OPINION, read from THIS run's own Vivado log, on top of
  # step 5's load-bearing pre-Vivado source grep -- not a replacement for
  # it. build_card.tcl's own MEASURED finding was that this elaboration-
  # trace "Parameter <NAME> bound to: <value>" line, for a PROJECT-MODE run,
  # goes only to the run's own <top>.vds, never to runme.log or the project
  # launcher's log. Whether a PLAIN (non-project) `synth_design`, running
  # in-process in the very batch session this script's own -log captures,
  # writes that same line to THIS run's $BUILD_LOG at all is UNVERIFIED (no
  # Vivado access from here to check it) -- which is exactly why "missing"
  # stays non-fatal (fix round 1, I6): it is as likely to mean "this log is
  # not where the trace lands" as "the patch did not apply", and the
  # pre-Vivado source grep above already covers that case. "on" or "mixed"
  # are a DIFFERENT finding: the trace line IS present and says the lever is
  # bound wrong, which is not an ambiguous result, so those ARE fatal here.
  LEVER_TCL=$(cat <<'TCLEOF'
source [lindex $argv 0]
set logtxt [read [open [lindex $argv 1]]]
set bad {}
foreach lv {NWIDE SWEEP_PIPE SCORE_EARLY} {
  set res [jccard_lever_status $lv $logtxt]
  set status [lindex $res 0]
  puts "JCOOC27_LEVER $lv $status ([lindex $res 1])"
  if {$status eq "on" || $status eq "mixed"} { lappend bad "$lv:$status" }
}
if {[llength $bad] > 0} {
  puts "JCOOC27_LEVER_FAIL [join $bad {,}]"
  exit 1
}
TCLEOF
)
  echo "$LEVER_TCL" > "$ROOT/lever_check.tcl"
  if ! tclsh "$ROOT/lever_check.tcl" "$SRC/hw/jc/card/jccard_levers.tcl" "$BUILD_LOG"; then
    jcooc27_fail "levers (post-run log read-back): NWIDE/SWEEP_PIPE/SCORE_EARLY read 'on' or 'mixed' (see JCOOC27_LEVER lines above)"
  fi
fi

# ---- 7. the sentinel, anchored ------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "DRYRUN would write: JCOOC27_DONE"
  exit 0
fi
echo "JCOOC27_DONE"
exit 0
