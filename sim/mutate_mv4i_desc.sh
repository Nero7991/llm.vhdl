#!/usr/bin/env bash
# Teeth for subsystem A's GATEKEEPER, rtl/matvec_int4_desc_axi.vhd.
#
# Every job in the design passes through this file's S_CHECK, and until
# 2026-08-29 it had NO mutation coverage at all -- 1,012 lines deciding what
# reaches the array, measured only by benches that fed it descriptors it was
# expected to accept.
#
# WHAT IS BEING MEASURED, AND WHY IT IS THE ACCEPT/REFUSE BOUNDARY.  A refused
# job is loud: nothing pulses `start`, `done` never sets, a driver polling for
# it hangs and someone looks.  An ACCEPTED job that should have been refused is
# silent -- the array reads whatever the bases point at and returns a number.
# So the mutation table (sim/mv4i_desc_mutations.py) is weighted toward rows
# that WEAKEN a check, and the case suite (sim/mv4i_desc_cases.py) is built so
# that each such row has a case whose expected verdict it moves.
#
# THREE VERDICTS, NOT TWO.  Each (mutation, case) run is classified by
# sim/mutverdict.py into PASS / KILLED / ABORT:<reason>.  An ABORT is a run the
# CHECKER never reached -- a language bound check, an elaboration failure, a
# wedge -- and counting one as a kill would publish a ratio that is not
# readable.  The per-mutation verdict below is:
#
#   KILLED    at least one case reached the bench's own FAIL verdict
#   ABORT     no case was killed but at least one aborted
#   SURVIVED  every case still passed: the mutation is INVISIBLE to this suite
#
# and the reason and the naming case are printed in every row, so a KILLED row
# says WHICH case did the killing and a SURVIVED row can be read against the
# note that says why nothing could have.
#
# BRANCH TAGS ARE NOT DECORATION.  sim/tb_mv4i_desc_image.vhd's 27 weight and
# scale slaves never assert arready, so an ACCEPTED descriptor stalls the core
# on its first read and NO JOB IN THIS HARNESS EVER COMPLETES.  Everything from
# S_WAIT onward -- the result buffer, the Y_IDX divider, the busy/done edge --
# is elaborated and never reached.  Those rows carry branch RUN and their
# survival measures THIS HARNESS, not the design.  Reading the table without
# the tag gives a kill rate that mixes the two.  Same for branch GEN, which is
# guarded by a generic (USE_XEXP_PORT, DUAL_CLK) this configuration does not
# set, so those lines are not even elaborated.
#
# SELF-ISOLATING.  Everything runs out of a scratch directory: this script, the
# sources it mutates and the case images are all copied there first, so editing
# the repository while a run is in flight cannot corrupt it and no mutation
# ever reaches a tracked file.
#
# Usage:
#   bash sim/mutate_mv4i_desc.sh [scratch-dir] [-j N] [--only PAT] [--cases]
#     --only PAT   run only mutations whose NAME contains PAT (substring, not
#                  a regex -- the same trap sim/regress.sh --only has)
#     --cases      run the case suite against the UNMUTATED design and stop.
#                  This is the harness's own teeth check: if a case does not
#                  pass here it is measuring nothing below.
set -uo pipefail

# SELF-ISOLATION.  bash reads a script lazily BY BYTE OFFSET, so editing this
# file while a run is in flight resumes the running shell mid-token.  Six
# tracks are editing this tree.  So the first thing this script does is copy
# ITSELF to a private path nobody else can name, syntax-check the copy (in case
# the original was caught mid-write), and re-exec that.  From then on the
# running process reads a file no editor is pointed at.  Same construction and
# same reason as sim/regress.sh section 0.
#
# The repository root is resolved BEFORE the re-exec and carried across in the
# environment: after it, $0 is the private copy in the temp directory and
# `dirname $0` would point at /tmp.
if [ -z "${MV4I_MUT_REEXEC:-}" ]; then
  cd "$(dirname "$0")/.." || exit 1
  MV4I_MUT_REPO="$PWD"
  MV4I_MUT_SELF=$(mktemp -t mv4i_mut.XXXXXX.sh) || exit 1
  cat "$0" > "$MV4I_MUT_SELF" || exit 1
  if ! bash -n "$MV4I_MUT_SELF"; then
    echo "the harness did not syntax-check as copied: it was probably being"
    echo "edited.  Nothing was run.  Re-run once the edit has landed."
    rm -f "$MV4I_MUT_SELF"; exit 1
  fi
  export MV4I_MUT_REEXEC=1 MV4I_MUT_REPO MV4I_MUT_SELF
  exec bash "$MV4I_MUT_SELF" "$@"
fi
# Unlinking a script bash already has open is safe on Linux: the inode survives
# for the open descriptor, so the copy disappears from /tmp the moment the run
# ends however it ends.
trap 'rm -f "$MV4I_MUT_SELF"' EXIT
cd "$MV4I_MUT_REPO" || exit 1
REPO="$PWD"

SCRATCH=""; JOBS=8; ONLY=""; CASES_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --cases) CASES_ONLY=1; shift ;;
    *) SCRATCH="$1"; shift ;;
  esac
done
[ -n "$SCRATCH" ] || SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH"

# The rtl closure of sim/tb_mv4i_desc_image.vhd, in analysis order.  Same list
# as tools/verify_mv4i_desc.py's RTL_FILES; kept here rather than imported so
# this script has no python dependency beyond its own two helpers.
FILES="rtl/util_pkg.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd
       rtl/stream_fifo.vhd rtl/axi_rd_port.vhd rtl/act_mem_striped.vhd
       rtl/mv4i_arith_pkg.vhd rtl/matvec_core.vhd rtl/weight_streamer.vhd
       rtl/matvec_int4.vhd rtl/matvec_int4_desc_pkg.vhd
       rtl/matvec_int4_desc_axi.vhd sim/tb_mv4i_desc_image.vhd"

TARGET="rtl/matvec_int4_desc_axi.vhd"

# POLL_MAX bounds a case that the mutation has made HANG.  20,000 status polls
# is about 1.2 ms of simulated time, which is comfortably past WDOG_LIMIT
# (65,536 core cycles = 655 us) so the watchdog cases still resolve, and it is
# what keeps a mutant that breaks GO from costing minutes per case.
POLL_MAX=20000
STOP_TIME=50ms
PER_CASE_TIMEOUT=600

# ------------------------------------------------------------------ set-up
SRC="$SCRATCH/src"
rm -rf "$SRC"; mkdir -p "$SRC/rtl" "$SRC/sim"
for f in $FILES; do cp "$REPO/$f" "$SRC/$f"; done
cp "$REPO/sim/mutverdict.py" "$SRC/sim/"
cp "$REPO/sim/mv4i_desc_cases.py" "$SRC/sim/"
cp "$REPO/sim/mv4i_desc_mutations.py" "$SRC/sim/"
cp "$REPO/sim/mv4i_desc_image.txt" "$SRC/sim/"

CASEDIR="$SCRATCH/cases"
rm -rf "$CASEDIR"
python3 "$SRC/sim/mv4i_desc_cases.py" "$CASEDIR" || exit 1
NCASE=$(wc -l < "$CASEDIR/cases.tsv")

# One runner per (mutation, case).  Written to disk rather than exported as a
# bash function because xargs -P and exported functions disagree about quoting
# in exactly the way that silently drops arguments -- MEASURED here: an earlier
# draft lost the classifier path and scored all 56 baseline cases as blank.
cat > "$SCRATCH/runcase.sh" <<'RUNNER'
#!/usr/bin/env bash
# $1 work-dir  $2 run-dir  $3 case-name  $4 generic-args  $5 poll  $6 stop
# $7 timeout    $8 path to sim/mutverdict.py
set -uo pipefail
w="$1"; rd="$2"; name="$3"; args="$4"; poll="$5"; stop="$6"; tmo="$7"; cls="$8"
# The bench opens -gDESC as a RELATIVE path, so the run must happen in the
# directory holding the case images.  Running it elsewhere gives
# "cannot open file" -> ABORT:ELAB on every case, which reads exactly like a
# broken design.
cd "$rd" || exit 1
# shellcheck disable=SC2086
timeout -k 5 "$tmo" ghdl -r --std=08 -frelaxed --workdir="$w" \
  tb_mv4i_desc_image $args -gPOLL_MAX="$poll" \
  --stop-time="$stop" --max-stack-alloc=0 > "$name.log" 2>&1
rc=$?
v=$(python3 "$cls" "$name.log" tb_mv4i_desc_image "$rc")
printf '%s\t%s\n' "$name" "$v"
RUNNER
chmod +x "$SCRATCH/runcase.sh"

analyze () {                      # $1 = tree, $2 = workdir -> rc
  local d="$1" w="$2" f
  rm -rf "$w"; mkdir -p "$w"
  for f in $FILES; do
    if ! ghdl -a --std=08 -frelaxed --workdir="$w" "$d/$f" \
         >> "$w/analyze.log" 2>&1; then
      return 1
    fi
  done
  return 0
}

run_suite () {                    # $1 = tree, $2 = tag -> writes $SCRATCH/$2.tsv
  local d="$1" tag="$2" w="$SCRATCH/$2.work" rd="$SCRATCH/$2.run"
  if ! analyze "$d" "$w"; then
    printf 'ANALYSIS\tABORT:ELAB\n' > "$SCRATCH/$tag.tsv"
    return
  fi
  rm -rf "$rd"; mkdir -p "$rd"
  cp "$CASEDIR"/*.hex "$rd/"
  # The classifier is passed by ABSOLUTE PATH.  A first draft resolved it
  # relative to the run directory and every case came back with an EMPTY
  # verdict, which the baseline gate then read as "not clean" -- the error was
  # on stderr and the verdict on stdout, so the two never met.
  awk -F'\t' '{printf "%s\t%s\n", $1, $2}' "$CASEDIR/cases.tsv" \
    | xargs -P "$JOBS" -d '\n' -I{} bash -c \
        'IFS=$'"'"'\t'"'"' read -r n a <<< "{}"; exec "$0" "$1" "$2" "$n" "$a" "$3" "$4" "$5" "$6"' \
        "$SCRATCH/runcase.sh" "$w" "$rd" "$POLL_MAX" "$STOP_TIME" \
        "$PER_CASE_TIMEOUT" "$SRC/sim/mutverdict.py" \
    | sort > "$SCRATCH/$tag.tsv"
}

# ------------------------------------------------------- the baseline first
echo "== rtl/matvec_int4_desc_axi.vhd mutation table =="
echo "   judge      sim/tb_mv4i_desc_image.vhd, FK33 geometry"
echo "   cases      $NCASE (sim/mv4i_desc_cases.py)"
echo "   classifier sim/mutverdict.py, three verdicts"
echo
run_suite "$SRC" base
BAD=$(awk -F'\t' '$2 != "PASS"' "$SCRATCH/base.tsv")
if [ -n "$BAD" ]; then
  echo "BASELINE IS NOT CLEAN -- these cases do not pass on the UNMUTATED"
  echo "design, so every verdict below them is unreadable:"
  echo "$BAD"
  echo
  [ "$CASES_ONLY" = 1 ] && exit 1
  exit 1
fi
echo "baseline: all $NCASE cases pass on the unmutated design"
echo
if [ "$CASES_ONLY" = 1 ]; then
  awk -F'\t' '{printf "  %-22s %s\n", $1, $3}' "$CASEDIR/cases.tsv"
  echo
  echo "scratch: $SCRATCH"
  exit 0
fi

# ---------------------------------------------------------- the mutations
printf '%-5s %-6s %-9s %-22s %s\n' NAME BRANCH VERDICT "NAMING CASE" NOTE
printf '%-5s %-6s %-9s %-22s %s\n' ----- ------ -------- ---------------------- ----
NK=0; NS=0; NA=0; NT=0
while IFS=$'\t' read -r name branch note; do
  case "$name" in *"$ONLY"*) ;; *) continue ;; esac
  NT=$((NT+1))
  d="$SCRATCH/m_$name"
  rm -rf "$d"; mkdir -p "$d/rtl" "$d/sim"
  for f in $FILES; do cp "$SRC/$f" "$d/$f"; done
  if ! python3 "$SRC/sim/mv4i_desc_mutations.py" --apply "$name" "$d/$TARGET" \
       2> "$SCRATCH/$name.apply.log"; then
    printf '%-5s %-6s %-9s %-22s %s\n' "$name" "$branch" "ANCHOR" "-" \
      "the anchor text is not in the file: the table is STALE"
    continue
  fi
  run_suite "$d" "r_$name"
  kills=$(awk -F'\t' '$2 == "KILLED"' "$SCRATCH/r_$name.tsv" | wc -l)
  aborts=$(awk -F'\t' '$2 ~ /^ABORT/' "$SCRATCH/r_$name.tsv" | wc -l)
  if [ "$kills" -gt 0 ]; then
    first=$(awk -F'\t' '$2 == "KILLED" {print $1; exit}' "$SCRATCH/r_$name.tsv")
    verdict="KILLED"; naming="$first ($kills/$NCASE)"; NK=$((NK+1))
  elif [ "$aborts" -gt 0 ]; then
    first=$(awk -F'\t' '$2 ~ /^ABORT/ {print $1"="$2; exit}' "$SCRATCH/r_$name.tsv")
    verdict="ABORT"; naming="$first"; NA=$((NA+1))
  else
    verdict="SURVIVED"; naming="-"; NS=$((NS+1))
  fi
  printf '%-5s %-6s %-9s %-22s %s\n' "$name" "$branch" "$verdict" "$naming" "$note"
  rm -rf "$d" "$SCRATCH/r_$name.work"
done < <(python3 "$SRC/sim/mv4i_desc_mutations.py" --list)

echo
echo "TOTAL $NT mutations: $NK KILLED, $NA ABORT, $NS SURVIVED"
echo "A SURVIVED row is a measurement of this suite's resolution, not a defect"
echo "on its own; read it against its branch tag and its note."
echo "scratch: $SCRATCH"
