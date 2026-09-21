#!/usr/bin/env bash
# congestion_guard.sh -- OPT-IN early abort for a card build that the router has
# already told us it cannot route.
#
# WHY THIS EXISTS.  Card build 11b (2026-09-20 19:00 to 23:25, 4h25m) failed at
# write_bitstream with 146,948 of 669,216 routable nets in resource conflict.
# MEASURED from its own log: the routing-side congestion numbers that predict
# that outcome are printed at route_design elapsed 00:07:48, and route_design
# then ran for a further 02:26:19 before the build gave up.  The verdict was
# never in doubt after minute eight; only the bill was.
#
#     route_design elapsed   event
#     00:07:48               INFO: [Route 35-449] Initial Estimated Congestion
#                            (the table this guard reads)
#     00:09:51               WARNING: [Route 35-447] Congestion is preventing
#                            the router from routing all nets
#     02:32:21               CRITICAL WARNING: [Route 35-162] 146948 signals
#                            failed to route
#     02:34:07               route_design "completed successfully" (it did not)
#     +00:00:23              ERROR: [DRC RTSTAT-13], Bitgen not run
#
# WHAT THIS IS NOT.  It is not a pass/fail check.  hw/fk33/pcieep_build.sh
# already fails a build by reading `^ERROR` from the log, and every route
# failure in this project's history ends in an `^ERROR` DRC line (RTSTAT-13 at
# 146,948 conflicted nets, RTSTAT-6 at 9,293 and at 209).  MEASURED: the
# existing check caught build 11b correctly.  This guard buys TIME, nothing
# else, and it can only ever be as trustworthy as the trigger below.
#
# THE TRIGGER, AND WHY THIS ONE.
# Scored against every card-build log on this box (12 implementation runs, 8 of
# which produced a legal route and 4 of which did not).  "G%Tiles" is the
# largest of the four per-direction Global Congestion "% Tiles" figures in the
# [Route 35-449] table.
#
#   log                          G%Tiles   route legal?
#   card_xexp_wdog_seam_09-18       6.96   yes
#   card_smp_bases_09-18            8.88   yes
#   card_swg_09-20_reimpl           9.33   yes
#   card_kvreg_09-20                9.39   yes
#   card_maxpos_grant_09-18        10.09   yes
#   card_seqrst_bfnorm_09-19       10.37   yes
#   card_bconst_qkn_09-19          10.91   yes
#   build10 (missed timing)        11.95   yes
#   ------------------------------------- the only gap, 0.83 points wide
#   card_seqrst_09-19 ROUTEFAIL    12.78   NO (9,293 nets conflicted)
#   card_swg_09-20 first impl      13.45   NO (209)
#   card_swg_09-20 altclbrouting   13.45   NO (209)
#   build11b                       17.36   NO (146,948)
#
# Separation is perfect on the sample.  THAT IS NOT A FALSE-POSITIVE BOUND.
# Twelve observations with one free threshold cannot bound anything: the
# admissible range from this evidence is the whole open interval (11.95, 12.78],
# and there is no principled way to place the threshold inside it.  The default
# below is the midpoint.  This is exactly why the guard is OPT-IN and default
# OFF: a build that would have closed must not be killed by a congestion
# number, and the cost of the two errors is wildly asymmetric.  A false
# positive destroys 4.5 hours of work AND a bitstream that would have shipped.
# A false negative costs 2.5 hours, which is precisely today's behaviour, so a
# miss leaves you no worse off than not running the guard at all.
#
# REJECTED TRIGGERS -- do not reintroduce these, each was MEASURED against the
# same 12 logs and each is worse:
#   [Route 35-447] alone          fires on 11 of 12, including 7 of the 8 LEGAL
#                                 routes.  Build 10 carries it.  Useless.
#   [Place 46-14] alone           fires on 12 of 12.  Zero discrimination.
#   [Route 35-448] level >= 6     2 false positives (smp_bases, maxpos_grant,
#                                 both legal) and misses seqrst_ROUTEFAIL,
#                                 which failed at level 5.  Wrong both ways.
#   [Route 35-581] level >= 6     fires on 9 of 12, 6 of them legal.
#   Effective congestion level    separates perfectly, but is printed at route
#                                 elapsed 02:32:18 of 02:34:07.  Correct verdict,
#                                 1m49s saved.  Worthless as an EARLY abort.
#   [Route 35-162] / RTSTAT-*     end of route_design.  Already caught by the
#                                 existing `^ERROR` grep.
#   Long or Short % Tiles         do NOT separate.  Highest legal Long is 21.00
#                                 against build11b's 20.76; highest legal Short
#                                 is 16.64 against swg_firstimpl's 15.35.  Only
#                                 the GLOBAL column orders these runs.
#   ANDing [Route 35-447] in      flips 0 of 12 verdicts.  Decoration.
#
# WHAT THE TRIGGER DOES NOT MEAN.  G%Tiles is a property of an IMPLEMENTATION
# RUN, not of a netlist.  MEASURED: card_swg_2026-09-20's first impl scored
# 13.45 and failed, and a re-implementation from the SAME synthesis checkpoint
# with ExtraNetDelay scored 9.33 and routed.  A trip says "this run is not going
# to route", never "this design cannot route".  Nor does G%Tiles order severity:
# 13.45 conflicted 209 nets while 12.78 conflicted 9,293.
#
# READS runme.log, NOT build.stdout.  build.stdout reaches disk through a pipe
# into tee and is therefore block-buffered -- CLAUDE.md records a full gate
# sitting at 0 rows for 20 minutes for exactly this reason.  impl_1/runme.log is
# written directly by the implementation run process and is current.
#
# EVERY MATCH IS LINE-ANCHORED.  Vivado echoes the sourced Tcl into the build
# log with a "#" prefix, and this is not hypothetical here: build 10's log --
# a LEGAL route -- contains
#     #     error "FK33_PBLK FAIL: ... caused the global congestion level 7
#     that stopped the router."
# so an unanchored grep for `congestion level 7` matches a comment in a healthy
# build's log and would have killed it.  MEASURED: 1 unanchored match, 0
# anchored.
#
# HOW IT STOPS THE BUILD.  `systemctl --user kill "$UNIT"`, the same mechanism
# swapguard.sh already uses.  It never greps a command line: no pkill -f, no
# pgrep -f, no loop over /proc/*/cmdline.  That pattern has killed the shell
# five times in this project, once via a /proc loop that matched the searching
# script's own text.
#
# THERE IS NO `rm` IN THIS FILE and there must never be one.
#
# USAGE
#   Armed, beside a running build (this is the only mode that kills anything):
#     FK33_ABORT_ON_CONGESTION=1 \
#     FK33_CONGABORT_UNIT=fastpop-build.service \
#     BUILD_ROOT=/mnt/storage/fk33_builds/build12 \
#       bash hw/fk33/congestion_guard.sh &
#
#   Evaluate a finished log and print the verdict, killing nothing.  This is how
#   the trigger is teeth-tested, and it needs no Vivado and no hardware:
#     bash hw/fk33/congestion_guard.sh --check <logfile>
#
#   Self-test the whole table above against the real logs:
#     bash hw/fk33/congestion_guard.sh --selftest
#
# EXIT STATUS of --check: 0 = would NOT abort, 3 = WOULD abort, 4 = no verdict
# (the 35-449 table is absent, e.g. a build that has not reached routing, or an
# engine-only build).  A missing table never aborts.

set -u

THRESH="${FK33_CONGABORT_GLOBAL_PCT:-12.5}"
POLL="${FK33_CONGABORT_POLL_S:-60}"

# ---------------------------------------------------------------------------
# max_global_pct <logfile>
#
# Prints the largest per-direction Global Congestion "% Tiles" from the
# [Route 35-449] table, or nothing if the table is absent.
#
# Both the live loop and --check go through this one function, so the teeth
# test exercises the code that runs in anger.  The inputs to that test are REAL
# build logs, never strings built from this function's idea of what a log looks
# like: a mutant constructed from the check's own misconception cannot detect
# that misconception.
#
# Table shape, verbatim from build 11b's runme.log:
#   | Direction | Size   | % Tiles  | Size   | % Tiles  | Size   | % Tiles  |
#   |      NORTH|   32x32|      4.81|   16x16|      5.22|   32x32|     14.10|
# awk -F'|' fields: $2 direction, $3 Global size, $4 Global % Tiles.
#
# ALL FOUR DIRECTIONS ARE REQUIRED, and this is not defensive padding -- the
# teeth test found the bug.  The guard polls a log that Vivado is still writing,
# so it can read the table half-printed.  Truncated one row in (NORTH only), the
# first version of this function returned a confident "OK 4.81" for build 11b,
# whose real figure is 17.36 in EAST.  NORTH is the LOWEST direction in that
# table, so a partial read is not merely incomplete, it is biased toward the
# wrong answer.  Fewer than four rows now yields no verdict at all, and the next
# poll gets the whole table.
#
# The last four rows are used, so a log carrying two implementation attempts
# (MEASURED: every card log on this box carries exactly one table and four rows,
# but a re-implementation appended to the same file would carry two) is judged on
# the most recent one rather than on the maximum across both.
max_global_pct() {
    local f="$1" reader=cat rows
    case "$f" in *.gz) reader=zcat ;; esac
    rows="$("$reader" "$f" 2>/dev/null \
        | grep -a -A 16 -E '^INFO: \[Route 35-449\] Initial Estimated Congestion' \
        | grep -a -E '^\| *(NORTH|SOUTH|EAST|WEST)\|' \
        | awk -F'|' '{ gsub(/ /, "", $4); if ($4 ~ /^[0-9]+(\.[0-9]+)?$/) print $4 }' \
        | tail -4)"
    [[ "$(printf '%s\n' "$rows" | grep -c .)" -eq 4 ]] || return 0
    printf '%s\n' "$rows" | sort -rn | head -1
}

# verdict <logfile> -> prints "ABORT <pct>" | "OK <pct>" | "NOVERDICT"
verdict() {
    local pct
    pct="$(max_global_pct "$1")"
    if [[ -z "$pct" ]]; then
        echo "NOVERDICT"
        return
    fi
    if awk -v p="$pct" -v t="$THRESH" 'BEGIN { exit !(p >= t) }'; then
        echo "ABORT $pct"
    else
        echo "OK $pct"
    fi
}

# ---------------------------------------------------------------------------
# --check <logfile>
if [[ "${1:-}" == "--check" ]]; then
    [[ -n "${2:-}" ]] || { echo "usage: $0 --check <logfile>" >&2; exit 2; }
    [[ -r "$2" ]] || { echo "unreadable: $2" >&2; exit 2; }
    v="$(verdict "$2")"
    printf 'threshold=%s  verdict=%s  log=%s\n' "$THRESH" "$v" "$2"
    case "$v" in
        ABORT*)     exit 3 ;;
        NOVERDICT*) exit 4 ;;
        *)          exit 0 ;;
    esac
fi

# ---------------------------------------------------------------------------
# --selftest: run the trigger over every card-build log on this box and check
# the verdict against the recorded ground truth (did the run produce a legal
# route, i.e. is [Route 35-162] absent).  Ground truth is read FROM THE LOG,
# not asserted here, so the test cannot agree with itself by construction.
if [[ "${1:-}" == "--selftest" ]]; then
    R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results"
    rows=(
      "$R/card_smp_bases_2026-09-18/build.stdout"
      "$R/card_xexp_wdog_seam_2026-09-18/build.stdout"
      "$R/card_maxpos_grant_2026-09-18/build.stdout"
      "$R/card_bconst_qkn_2026-09-19/build.stdout"
      "$R/card_seqrst_2026-09-19_ROUTEFAIL/build.stdout"
      "$R/card_seqrst_bfnorm_2026-09-19/build.stdout"
      "$R/card_swg_2026-09-20/build_synth_and_first_impl.stdout"
      "$R/card_swg_2026-09-20/reimpl_extranetdelay.stdout"
      "$R/card_swg_2026-09-20/runme_altclbrouting_FAILED.log"
      "$R/card_kvreg_2026-09-20/build.stdout"
      "$R/card_build10_FAILED_2026-09-20/build.stdout.full.gz"
      # The MUST-FIRE row.  It reads the REPO copy, not
      # /mnt/storage/fk33_builds/build11b/build.stdout, so the self-test is
      # reproducible on a fresh clone and does not depend on a build root that
      # is on no backup and that a drive cleanup has already destroyed once.
      "$R/card_build11b_FAILED_2026-09-20/build.stdout.full.gz"
    )
    printf '%-52s %-9s %-11s %-9s %s\n' LOG G%Tiles ROUTE_LEGAL VERDICT RESULT
    pass=0; fail=0; skip=0
    for f in "${rows[@]}"; do
        if [[ ! -r "$f" ]]; then
            printf '%-52s %-9s %-11s %-9s %s\n' "$(basename "$(dirname "$f")")/$(basename "$f")" - - - MISSING
            skip=$((skip + 1)); continue
        fi
        reader=cat; case "$f" in *.gz) reader=zcat ;; esac
        # Ground truth, from the log itself, line-anchored.
        if [[ "$("$reader" "$f" | grep -ac '^CRITICAL WARNING: \[Route 35-162\]')" -gt 0 ]]; then
            legal=no
        else
            legal=yes
        fi
        v="$(verdict "$f")"; act="${v%% *}"; pct="${v##* }"
        [[ "$act" == NOVERDICT ]] && pct=-
        # Correct behaviour: ABORT exactly when the route was not legal.
        if { [[ "$act" == ABORT" " || "$act" == ABORT ]] && [[ "$legal" == no ]]; } \
           || { [[ "$act" != ABORT ]] && [[ "$legal" == yes ]]; }; then
            res=PASS; pass=$((pass + 1))
        else
            if [[ "$legal" == yes ]]; then res="FAIL(false-positive)"; else res="FAIL(missed)"; fi
            fail=$((fail + 1))
        fi
        printf '%-52s %-9s %-11s %-9s %s\n' \
            "$(basename "$(dirname "$f")")/$(basename "$f")" "$pct" "$legal" "$act" "$res"
    done
    echo
    echo "CONGABORT_SELFTEST threshold=$THRESH PASS=$pass FAIL=$fail MISSING=$skip"
    [[ $fail -eq 0 ]] || exit 1
    exit 0
fi

# ---------------------------------------------------------------------------
# Live mode.
if [[ "${FK33_ABORT_ON_CONGESTION:-0}" != "1" ]]; then
    echo "congestion_guard: FK33_ABORT_ON_CONGESTION is not 1, not arming." >&2
    exit 0
fi

UNIT="${FK33_CONGABORT_UNIT:-}"
[[ -n "$UNIT" ]] || { echo "congestion_guard: set FK33_CONGABORT_UNIT" >&2; exit 2; }
[[ -n "${BUILD_ROOT:-}" ]] || { echo "congestion_guard: set BUILD_ROOT" >&2; exit 2; }

RUNLOG="$BUILD_ROOT/fk33_pcieep/fk33_pcieep.runs/impl_1/runme.log"
GUARDLOG="$BUILD_ROOT/congestion_guard.log"
VERDICTF="$BUILD_ROOT/FK33_CONGABORT.txt"

{
    echo "$(date +%H:%M:%S) congestion_guard armed"
    echo "$(date +%H:%M:%S)   unit      $UNIT"
    echo "$(date +%H:%M:%S)   runlog    $RUNLOG"
    echo "$(date +%H:%M:%S)   threshold $THRESH % Global Tiles (35-449)"
} >> "$GUARDLOG"

while systemctl --user is-active --quiet "$UNIT"; do
    if [[ -r "$RUNLOG" ]]; then
        v="$(verdict "$RUNLOG")"
        echo "$(date +%H:%M:%S) $v" >> "$GUARDLOG"
        if [[ "${v%% *}" == "ABORT" ]]; then
            # The verdict file first, so the reason is durable whether or not
            # the build's own EXIT trap survives the kill.
            {
                echo "FK33_CONGABORT tripped   $(date -Is)"
                echo "FK33_CONGABORT unit      $UNIT"
                echo "FK33_CONGABORT runlog    $RUNLOG"
                echo "FK33_CONGABORT metric    max Global % Tiles, [Route 35-449]"
                echo "FK33_CONGABORT value     ${v##* }"
                echo "FK33_CONGABORT threshold $THRESH"
                echo "FK33_CONGABORT note      This is an OPT-IN EARLY ABORT, not a"
                echo "FK33_CONGABORT note      routing result. The run was stopped before"
                echo "FK33_CONGABORT note      route_design finished, so this build has NO"
                echo "FK33_CONGABORT note      route status and NO timing result. Nothing"
                echo "FK33_CONGABORT note      here may be compared with a completed run."
                echo "FK33_CONGABORT note      Admissible threshold range from 12 logs is"
                echo "FK33_CONGABORT note      (11.95, 12.78]; a trip near the boundary is"
                echo "FK33_CONGABORT note      not strong evidence. Re-run with the guard"
                echo "FK33_CONGABORT note      disarmed to get a real verdict."
                echo
                echo "--- [Route 35-449] Initial Estimated Congestion, as captured ---"
                grep -a -A 16 -E '^INFO: \[Route 35-449\] Initial Estimated Congestion' "$RUNLOG"
            } > "$VERDICTF" 2>/dev/null
            echo "$(date +%H:%M:%S) CONGABORT KILL: Global %Tiles ${v##* } >= $THRESH" >> "$GUARDLOG"
            systemctl --user kill "$UNIT"
            exit 3
        fi
    else
        echo "$(date +%H:%M:%S) waiting for $RUNLOG" >> "$GUARDLOG"
    fi
    sleep "$POLL"
done
echo "$(date +%H:%M:%S) unit ended, guard never tripped" >> "$GUARDLOG"
exit 0
