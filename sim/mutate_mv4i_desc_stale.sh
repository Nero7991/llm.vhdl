#!/usr/bin/env bash
# Teeth for the STALE-DONE check added to sim/tb_matvec_fk33_desc.vhd on
# 2026-08-29 (TRACK DONE1).  Separate from sim/mutate_mv4i_desc.sh, and it has
# to be:
#
#   THAT HARNESS CANNOT RUN THIS CHECK AT ALL.  Its 27 weight and scale slaves
#   (sim/tb_mv4i_desc_image.vhd) never assert arready, so an accepted
#   descriptor stalls the core on its first read and NO JOB IN THAT HARNESS
#   EVER COMPLETES.  A stale `done` is by definition a completion that belongs
#   to a PREVIOUS job, so a harness in which nothing completes has nothing to
#   be stale about.  That is its branch RUN, stated in its own header.
#
# So the mutants here are run against the FULL bench, which reads a real packed
# tensor and does complete jobs.  Each combination is (RTL variant) x (bench
# variant), because the point is not "the mutant dies" -- it is "the mutant
# dies BECAUSE OF THE NEW CHECK AND NOT SOMETHING ELSE".  A kill without the
# no-new-check control is not a measurement (TRACK GRAY1, 2026-08-29: its table
# came out NEW CHECK ALONE=1, both=4, NEITHER=4, and without the control it
# would have claimed five kills).
#
# SELF-ISOLATING.  A private repo of symlinks is built in the scratch dir, with
# real files ONLY for the two files a row mutates, so no mutation ever reaches a
# tracked file and four other tracks can keep editing this tree while it runs.
# Symlinked entry by entry rather than `cp -r`: see the note at the loop.
#
# The per-row trees are NOT cleaned up automatically -- a KILLED row's log is
# the evidence -- so delete them yourself once the table is read.
#
# Usage:  bash sim/mutate_mv4i_desc_stale.sh <scratch-dir> [--only NAME]
#         NAME is a substring of the row name, not a regex.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
SCRATCH="${1:?usage: mutate_mv4i_desc_stale.sh <scratch-dir> [--only NAME]}"
shift
ONLY=""
[ "${1:-}" = "--only" ] && { ONLY="${2:?}"; shift 2; }

RTL=rtl/matvec_int4_desc_axi.vhd
TB=sim/tb_matvec_fk33_desc.vhd
mkdir -p "$SCRATCH" || exit 2

# ---------------------------------------------------------------- the variants
# The two BASELINES come out of git, not out of a hand-written patch: HEAD is
# the tree as it was before this track touched it, so "the defect" is the real
# historical file and not a reconstruction of it.
mkdir -p "$SCRATCH/src"
git -C "$REPO" show HEAD:$RTL > "$SCRATCH/src/rtl.prefix"  || exit 2
git -C "$REPO" show HEAD:$TB  > "$SCRATCH/src/tb.old"      || exit 2
cp "$REPO/$RTL" "$SCRATCH/src/rtl.fixed"
cp "$REPO/$TB"  "$SCRATCH/src/tb.new"

# M2 -- the fix as the brief literally worded it: clear done_l "on the CTRL
# write", taken to mean the REGISTERED go, which asserts one clock after the
# handshake.  Window shrinks 3 -> 1 rather than 3 -> 0.  This row measures the
# new check's RESOLUTION: a check that only bites at 3 cycles and not at 1 is
# not checking the invariant, it is checking a magnitude.
sed 's|^\(        if go = .1. then go_p <= .1.; end if;\)$|        if go = '"'"'1'"'"' then go_p <= '"'"'1'"'"'; done_l <= '"'"'0'"'"'; end if;|' \
    "$SCRATCH/src/rtl.prefix" > "$SCRATCH/src/rtl.go1"
cmp -s "$SCRATCH/src/rtl.prefix" "$SCRATCH/src/rtl.go1" && {
  echo "mutate_mv4i_desc_stale: M2 patch matched nothing -- the prefix file moved" >&2; exit 2; }

# M3 -- the STATUS register masked but the job_done PORT left stale.  A
# register-only check passes this; the cycle-accurate monitor watches the port
# and does not.  It is here to say WHICH of the two new checks does the work,
# which a single combined verdict cannot.
python3 - "$SCRATCH/src/rtl.fixed" "$SCRATCH/src/rtl.portstale" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = "job_done <= done_l and not go_now;"
assert s.count(old) == 1, "M3 anchor moved"
open(dst, "w").write(s.replace(old, "job_done <= done_l;"))
PY
[ -s "$SCRATCH/src/rtl.portstale" ] || exit 2

# name              rtl variant     bench variant   what it is
ROWS='
BASE|fixed|new|the fix and the new check: must PASS or nothing below is readable
DEFECT|prefix|new|THE DEFECT, verbatim from HEAD.  The kill this track exists for
CONTROL|prefix|old|THE ATTRIBUTION CONTROL: the same defect with the new check absent
FIXOLD|fixed|old|the fix under the OLD bench: the single-job path must be unchanged
GO1|go1|new|clear on the REGISTERED go -- a ONE-cycle window.  Resolution floor
PORTSTALE|portstale|new|STATUS masked, job_done port left stale.  Which check bites
'

printf '%-12s %-9s %-6s %-9s %s\n' NAME RTL BENCH VERDICT DETAIL
printf '%s\n' "-------------------------------------------------------------------------------"

echo "$ROWS" | while IFS='|' read -r name rtlv tbv note; do
  [ -z "$name" ] && continue
  [ -n "$ONLY" ] && case "$name" in *"$ONLY"*) : ;; *) continue ;; esac

  run="$SCRATCH/run.$name"
  rm -rf "$run"
  mkdir -p "$run"
  # A private repo: symlinks everywhere, and REAL FILES only for the two files
  # this row mutates.
  #
  # SYMLINK sim/ ENTRY BY ENTRY, DO NOT COPY IT.  MEASURED 2026-08-30, the hard
  # way: `cp -r sim/` is 3.6 GB, because sim/ holds ooc_mv, e2_funcsim, gate2,
  # xsim.dir and friends.  Six rows plus a spare tree took the scratch to 26 GB
  # and root to 93% with a composed place-and-route running.  Symlinking the
  # entries costs kilobytes and regress.sh cannot tell the difference: it
  # analyses "$REPO/$f" by path.
  mkdir -p "$run/rtl" "$run/sim"
  for e in $(ls -A "$REPO"); do
    case "$e" in
      rtl|sim) : ;;
      *)       ln -s "$REPO/$e" "$run/$e" ;;
    esac
  done
  for e in $(ls -A "$REPO/rtl"); do ln -s "$REPO/rtl/$e" "$run/rtl/$e"; done
  for e in $(ls -A "$REPO/sim"); do ln -s "$REPO/sim/$e" "$run/sim/$e"; done
  rm -f "$run/$RTL" "$run/$TB"
  cp "$SCRATCH/src/rtl.$rtlv" "$run/$RTL"
  cp "$SCRATCH/src/tb.$tbv"   "$run/$TB"

  log="$SCRATCH/log.$name"
  REGRESS_SCRATCH="$run/w" bash "$run/sim/regress.sh" \
      --only tb_matvec_fk33_desc --keep > "$log" 2>&1
  last=$(grep -aE '^ OVERALL' "$log" | tail -1)
  pass=$(printf '%s' "$last" | sed -n 's/.*PASS \([0-9]*\).*/\1/p')
  fail=$(printf '%s' "$last" | sed -n 's/.*FAIL \([0-9]*\).*/\1/p')
  berr=$(printf '%s' "$last" | sed -n 's/.*BUILD-ERROR \([0-9]*\).*/\1/p')

  if [ "${berr:-9}" != 0 ]; then    v=ABORT
  elif [ "${fail:-9}" != 0 ]; then  v=KILLED
  elif [ "${pass:-0}" = 3 ]; then   v=SURVIVED
  else                              v=ABORT
  fi
  # what actually did the killing, read out of the bench's own reports
  why=""
  grep -aq 'STATUS reported DONE on the first read after its own GO' "$run"/w/*/log 2>/dev/null \
      && why="$why first-STATUS-read"
  grep -aq 'job_done stayed asserted for' "$run"/w/*/log 2>/dev/null \
      && why="$why per-job-window"
  grep -aq 'the WORST window over' "$run"/w/*/log 2>/dev/null \
      && why="$why global-worst"
  [ -z "$why" ] && why=" --"
  printf '%-12s %-9s %-6s %-9s %s |%s\n' "$name" "$rtlv" "$tbv" "$v" "$note" "$why"
done
