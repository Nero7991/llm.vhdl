#!/usr/bin/env bash
# The SECOND JUDGE for the same mutation table sim/mutate_mv4i_desc.sh drives.
#
# WHY A SECOND SCRIPT AND NOT A SECOND CASE.  sim/tb_mv4i_desc_image.vhd's 27
# weight and scale slaves never assert arready, so no job in that harness ever
# completes: everything from S_WAIT onward in rtl/matvec_int4_desc_axi.vhd --
# the busy/done edge, the result buffer, the Y_IDX repeated-subtraction divider,
# the CYCLES/BEATS/STARVED counters and the S_DONE re-arm -- is ELABORATED and
# NEVER REACHED there.  Those rows are tagged RUN in sim/mv4i_desc_mutations.py
# and they survive that harness by construction.
#
# sim/tb_matvec_fk33_desc.vhd does complete jobs, bit-exactly against
# ref/matvec_int4.c, so it is the judge that can see them.  It is used
# UNMODIFIED and this script does not own it.
#
# THE COST OF THE SECOND JUDGE, STATED: it needs the packed tensor at
# $MV4I_FK33_FILE (default the same path sim/regress.sh uses), which is not in
# git, and one run is MEASURED at 75 s against the image bench's 0.5 s.  That is
# why it is a separate script run at a lower mutation count rather than a column
# of the main table.
#
# Usage: bash sim/mutate_mv4i_desc_run.sh [scratch-dir] [-j N] [--only PAT]
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

SCRATCH=""; JOBS=6; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    *) SCRATCH="$1"; shift ;;
  esac
done
[ -n "$SCRATCH" ] || SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH"

MV4I="${MV4I_FK33_FILE:-/mnt/storage/llama-models/qwen35-9b-mv4i/blk.11.attn_k.weight.mv4i}"
if [ ! -f "$MV4I" ]; then
  echo "SKIP: $MV4I is not present.  This judge needs the packed tensor that"
  echo "      sim/regress.sh builds mv_fk33_tr.txt from; it is not in git."
  echo "      Set MV4I_FK33_FILE to point at one."
  exit 0
fi

FILES="rtl/util_pkg.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd
       rtl/stream_fifo.vhd rtl/axi_rd_port.vhd rtl/act_mem_striped.vhd
       rtl/mv4i_arith_pkg.vhd rtl/matvec_core.vhd rtl/weight_streamer.vhd
       rtl/matvec_int4.vhd rtl/matvec_int4_desc_pkg.vhd
       rtl/matvec_int4_desc_axi.vhd sim/tb_matvec_fk33_desc.vhd"
TARGET="rtl/matvec_int4_desc_axi.vhd"
TB=tb_matvec_fk33_desc

SRC="$SCRATCH/src"
rm -rf "$SRC"; mkdir -p "$SRC/rtl" "$SRC/sim"
for f in $FILES; do cp "$REPO/$f" "$SRC/$f"; done
cp "$REPO/sim/mutverdict.py" "$SRC/sim/"
cp "$REPO/sim/mv4i_desc_mutations.py" "$SRC/sim/"

# The trace, built ONCE and shared by every mutation.  It is a function of the
# tensor and of ref/mv_fk33_tr, neither of which any mutation touches.
TR="$SCRATCH/mv_fk33_tr.txt"
if [ ! -s "$TR" ]; then
  cc -O2 -w -I "$REPO/ref" -o "$SCRATCH/mv_fk33_tr" "$REPO/ref/mv_fk33_tr.c" -lm \
    || { echo "cannot build ref/mv_fk33_tr"; exit 1; }
  ( cd "$SCRATCH" && ./mv_fk33_tr mv_fk33_tr.txt "$MV4I" 100 5 >/dev/null ) \
    || { echo "cannot build the trace"; exit 1; }
fi

cat > "$SCRATCH/runmut.sh" <<'RUNNER'
#!/usr/bin/env bash
# $1 scratch  $2 name  $3 files  $4 target  $5 trace
#
# ONLY THE MUTATION NAME CROSSES THE xargs BOUNDARY, and that is not tidiness.
# A first draft passed the NOTE too, substituted into the `bash -c` script text
# by xargs -I{}.  Two notes in sim/mv4i_desc_mutations.py contain backticks
# (E1's "`start` is never pulsed"), so the shell ran `start` as a command:
# MEASURED 2026-08-29 as "runmut.sh: line 1: start: command not found" on
# stderr, with E1's printed note silently truncated.  Nothing else was
# corrupted this time.  Names are [A-Z][0-9]+ and cannot do that; the branch
# and note are looked up HERE, out of the table, where no shell sees them.
set -uo pipefail
S="$1"; name="$2"; FILES="$3"; TARGET="$4"; TR="$5"
if [ "$name" = "BASE" ]; then
  branch="-"; note="unmutated baseline"
else
  line=$(python3 "$S/src/sim/mv4i_desc_mutations.py" --list \
         | awk -F'\t' -v n="$name" '$1 == n {print; exit}')
  branch=$(printf '%s' "$line" | cut -f2)
  note=$(printf '%s' "$line" | cut -f3)
fi
d="$S/m_$name"; w="$d/work"; rd="$d/run"
rm -rf "$d"; mkdir -p "$d/rtl" "$d/sim" "$w" "$rd"
for f in $FILES; do cp "$S/src/$f" "$d/$f"; done
if [ "$name" != "BASE" ]; then
  if ! python3 "$S/src/sim/mv4i_desc_mutations.py" --apply "$name" "$d/$TARGET" \
       2> "$d/apply.log"; then
    printf '%-5s %-6s %-9s %s\n' "$name" "$branch" "ANCHOR" "$note"; exit 0
  fi
fi
ok=1
for f in $FILES; do
  ghdl -a --std=08 -frelaxed --workdir="$w" "$d/$f" >> "$d/analyze.log" 2>&1 || ok=0
done
if [ "$ok" = 0 ]; then
  printf '%-5s %-6s %-9s %s\n' "$name" "$branch" "ABORT:ELAB" "$note"; exit 0
fi
cp "$TR" "$rd/mv_fk33_tr.txt"
cd "$rd" || exit 1
timeout -k 5 1800 ghdl -r --std=08 -frelaxed --workdir="$w" tb_matvec_fk33_desc \
  --stop-time=200ms --stop-delta=1000000 --max-stack-alloc=0 > run.log 2>&1
rc=$?
# The bench prints a count, not a PASS token, so the two clean outcomes are
# recognised here rather than by rewriting a bench this script does not own.
if grep -qaE 'tb_matvec_fk33_desc: [0-9]+ cases run, 0 failures' run.log; then
  v=PASS
elif grep -qaE 'tb_matvec_fk33_desc: [0-9]+ cases run, [1-9][0-9]* failures' run.log; then
  v=KILLED
else
  v=$(python3 "$S/src/sim/mutverdict.py" run.log tb_matvec_fk33_desc "$rc")
fi
printf '%-5s %-6s %-9s %s\n' "$name" "$branch" "$v" "$note"
RUNNER
chmod +x "$SCRATCH/runmut.sh"

echo "== rtl/matvec_int4_desc_axi.vhd mutation table, SECOND JUDGE =="
echo "   judge  sim/tb_matvec_fk33_desc.vhd (unmodified), FK33 + AXU3EG arms"
echo "   tensor $MV4I"
echo
printf '%-5s %-6s %-9s %s\n' NAME BRANCH VERDICT NOTE
printf '%-5s %-6s %-9s %s\n' ----- ------ -------- ----
{
  printf 'BASE\t-\tunmutated baseline\n' 
  python3 "$SRC/sim/mv4i_desc_mutations.py" --list \
    | awk -F'\t' -v p="$ONLY" 'index($1,p)>0'
} | cut -f1 \
  | xargs -P "$JOBS" -d '\n' -I{} \
      "$SCRATCH/runmut.sh" "$SCRATCH" {} "$FILES" "$TARGET" "$TR" \
  | sort -k1,1

echo
echo "scratch: $SCRATCH"
