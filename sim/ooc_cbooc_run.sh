#!/usr/bin/env bash
# sim/ooc_cbooc_run.sh -- TRACK CBOOC, 2026-09-20.
#
# THE TWO-ARM A/B FOR THE PER-ROW CODEBOOK (`0b34200`, LEVERBOARD lever L-CB),
# whose scope column reads "no synthesis at all" and whose `-19,344 FF` is
# DERIVED.  Build 11b is the first time that RTL has met a synthesiser, and it
# placed at WNS -5.136 / TNS -236,998 against build 9's +0.533 / 0.000.
#
# THE ARMS DIFFER IN EXACTLY ONE FILE AND THE REVERTED ARM IS THE REAL
# PRE-CHANGE RTL, NOT AN IMITATION.  `old/rtl/matvec_core.vhd` is
# `git show 0b34200^:rtl/matvec_core.vhd` verbatim; everything else in both
# trees is `git archive HEAD rtl`.  A mutant built from this track's NOTION of
# the change could not detect a misconception in that notion -- the recorded
# `seam_tieoff_teeth` failure, where a check and its own mutant were wrong in
# the same direction and four green rows were insensitive to a dead build.
#
# `0b34200^` IS ONLY VALID AS THE OLD ARM WHILE `matvec_core.vhd` HAS NOT MOVED
# SINCE.  MEASURED at `08cc17d`: md5 `c3325ea1f418dcbcaa85f33e47e8c901` at
# `0b34200`, at `HEAD` and in the working tree, so `0b34200^` IS
# HEAD-minus-those-four-hunks exactly.  This script ASSERTS that rather than
# assuming it, and ABORTS with the alternative recipe if another track has
# landed on the file since.
#
# WHAT IT MEASURES AND WHAT IT CANNOT.  `synth_design` + `opt_design`, out of
# context, no place, no route.  It answers the FF delta, the LUT/LUTRAM/DSP/
# BRAM deltas and the FANOUT on the codebook command net, all of which are
# netlist facts fixed at synthesis.  It CANNOT exonerate or convict the change
# on build 11b's WNS: that is a placement outcome at 99.8% CLB occupancy, and
# OOC congestion is not the card's congestion.  See the header of
# sim/ooc_cbooc.tcl for the full argument and for why a post-`opt_design`
# checkpoint is written anyway.
#
# NO HARDWARE.  `synth_design` / `opt_design` / `report_*` only.
#
# USAGE
#   bash sim/ooc_cbooc_run.sh                    # prepare, validate, then draw
#   CBO_PREPARE_ONLY=1 bash sim/ooc_cbooc_run.sh # prepare and validate only
#
#   CBO_ROOT      scratch root   (default /mnt/storage/fk33_builds/scratch/cbooc)
#   CBO_TARGET    entity         (default matvec_int4_desc_axi; matvec_core also
#                                 valid and cheaper -- see the tcl header for
#                                 why desc_axi is the one that closes the PATH)
#   CBO_CAP       MemoryHigh     (default 8G.  DO NOT RAISE ABOVE 11G on the
#                                 BC-250: a 12G cap on that 14 GB box made it
#                                 unreachable and it is on no WoL watchdog.)
#   CBO_ONLY      "old new"      which arms to draw
#   CBO_FASTPOP   true|false     held IDENTICAL across arms; it is build 11b's
#                                OTHER change and must not float
#
# NOTHING IS EVER DELETED BY THIS SCRIPT.  Each invocation makes its own
# timestamped run directory, which is both the recorded scratch discipline
# ("NAME SCRATCH DIRECTORIES PER RUN") and the reason no `rm` with a shell
# variable in its path appears anywhere below.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${CBO_ROOT:-/mnt/storage/fk33_builds/scratch/cbooc}"
TARGET="${CBO_TARGET:-matvec_int4_desc_axi}"
CAP="${CBO_CAP:-8G}"
ONLY="${CBO_ONLY:-old new}"
FASTPOP="${CBO_FASTPOP:-true}"
VIV="${CBO_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
BASECOMMIT="${CBO_BASECOMMIT:-0b34200}"

say() { echo "$@"; }
die() { echo "CBOOC_ABORT: $*" >&2; exit 9; }

# ---------------------------------------------------------------------------
# IMPORT MODE EXISTS BECAUSE THE SECOND LANE HAS NO GIT HISTORY.
# `~/GitHub/DevOps/bc250-sync-llama-vhdl.sh` rsyncs the git-TRACKED FILES only
# (~1,829 files, 21 MB) and copies NO `.git`, so on the BC-250 both
# `git archive HEAD` and `git show 0b34200^:...` fail.  A harness that can only
# build its arms where git lives is a harness that can only run on the busy
# box.
#
# So: PREPARE on the workstation (where git is), rsync the run directory over,
# and DRAW there with CBO_IMPORT.  The provenance that git would have asserted
# is written into MANIFEST.txt at prepare time and RE-CHECKED at import time by
# sha256, which is the only form of the check that survives the crossing.
# A comparison needs both ends drawn from the same tree, and the manifest is
# what makes "the same tree" assertable rather than plausible.
# ---------------------------------------------------------------------------
IMPORT="${CBO_IMPORT:-}"
if [ -n "$IMPORT" ]; then
  RUN="$IMPORT"
  [ -d "$RUN/old/rtl" ] && [ -d "$RUN/new/rtl" ] \
    || die "CBO_IMPORT=$RUN does not hold old/rtl and new/rtl"
  [ -f "$RUN/MANIFEST.txt" ] \
    || die "CBO_IMPORT=$RUN has no MANIFEST.txt; its arms have no provenance
  and a draw from them would be two unlabelled trees.  Re-prepare with
  CBO_PREPARE_ONLY=1 where git is available."
else
  RUN="$ROOT/run_$(date +%Y%m%d_%H%M%S)_$$"
  mkdir -p "$RUN" || die "cannot create $RUN"
fi

say "CBOOC_ENV host=$(hostname) repo=$REPO run=$RUN target=$TARGET cap=$CAP\
 import=${IMPORT:-no}"
free -m | head -2

# ===========================================================================
# 1. THE TWO TREES.
# ===========================================================================
if [ -n "$IMPORT" ]; then
  say "CBOOC_SHA (import mode: taken from the manifest, not from git here)"
  sed 's/^/CBOOC_MANIFEST /' "$RUN/MANIFEST.txt"
  MOLD=$(sed -n 's/^sha256_old=//p' "$RUN/MANIFEST.txt")
  MNEW=$(sed -n 's/^sha256_new=//p' "$RUN/MANIFEST.txt")
  MHUNK=$(sed -n 's/^hunks=//p' "$RUN/MANIFEST.txt")
  GOLD=$(sha256sum "$RUN/old/rtl/matvec_core.vhd" | cut -d' ' -f1)
  GNEW=$(sha256sum "$RUN/new/rtl/matvec_core.vhd" | cut -d' ' -f1)
  [ "$GOLD" = "$MOLD" ] || die "old arm sha256 $GOLD does not match the manifest's $MOLD"
  [ "$GNEW" = "$MNEW" ] || die "new arm sha256 $GNEW does not match the manifest's $MNEW"
  NDIFF=$(diff -rq "$RUN/old/rtl" "$RUN/new/rtl" | wc -l)
  [ "$NDIFF" = "1" ] || die "the imported arm trees differ in $NDIFF files, expected 1"
  HUNK_ARM=$(diff -u "$RUN/old/rtl/matvec_core.vhd" "$RUN/new/rtl/matvec_core.vhd" | grep -c '^@@')
  [ "$HUNK_ARM" = "$MHUNK" ] || die "imported arms differ by $HUNK_ARM hunks,\
 the manifest recorded $MHUNK"
  say "CBOOC_TREES ok (imported) files_differing=1 hunks=$HUNK_ARM sha256 both match"
else
say "CBOOC_SHA $(git -C "$REPO" rev-parse --short HEAD)"
mkdir -p "$RUN/old" "$RUN/new"
git -C "$REPO" archive HEAD rtl | tar -x -C "$RUN/old" || die "git archive failed"
git -C "$REPO" archive HEAD rtl | tar -x -C "$RUN/new" || die "git archive failed"
git -C "$REPO" show "${BASECOMMIT}^:rtl/matvec_core.vhd" > "$RUN/old/rtl/matvec_core.vhd" \
  || die "cannot read ${BASECOMMIT}^:rtl/matvec_core.vhd"

# ---- THE PROVENANCE ASSERTION.  If matvec_core.vhd has moved since the
# change, `${BASECOMMIT}^` is no longer HEAD-minus-the-change and the "old" arm
# would silently carry someone else's revert as well.  That is the recorded
# same-tree failure: a comparison whose two ends come from different trees
# passes every arithmetic check, because staleness does not break arithmetic.
A=$(git -C "$REPO" show "${BASECOMMIT}:rtl/matvec_core.vhd" | sha256sum | cut -d' ' -f1)
B=$(git -C "$REPO" show "HEAD:rtl/matvec_core.vhd"          | sha256sum | cut -d' ' -f1)
if [ "$A" != "$B" ]; then
  die "rtl/matvec_core.vhd has CHANGED since $BASECOMMIT ($A at the commit,
  $B at HEAD).  '${BASECOMMIT}^' is therefore NOT HEAD-minus-this-change and
  using it would fold another track's edits into the 'old' arm.  Build the old
  arm instead by reverting only these hunks:
      cd '$RUN/old' && git -C '$REPO' show $BASECOMMIT -- rtl/matvec_core.vhd | git apply -R
  and re-run with CBO_SKIP_PROVENANCE=1 once you have checked the result."
fi

# ---- EXACTLY ONE FILE MAY DIFFER, AND BY EXACTLY THE COMMIT'S HUNKS.
NDIFF=$(diff -rq "$RUN/old/rtl" "$RUN/new/rtl" | wc -l)
DIFFLINE=$(diff -rq "$RUN/old/rtl" "$RUN/new/rtl" | head -1)
[ "$NDIFF" = "1" ] || die "the two arm trees differ in $NDIFF files, expected 1:
$(diff -rq "$RUN/old/rtl" "$RUN/new/rtl")"
echo "$DIFFLINE" | grep -q "matvec_core.vhd" \
  || die "the one differing file is not matvec_core.vhd: $DIFFLINE"

HUNK_ARM=$(diff -u "$RUN/old/rtl/matvec_core.vhd" "$RUN/new/rtl/matvec_core.vhd" | grep -c '^@@')
HUNK_GIT=$(git -C "$REPO" show "$BASECOMMIT" -- rtl/matvec_core.vhd | grep -c '^@@')
[ "$HUNK_ARM" = "$HUNK_GIT" ] || die "hunk count mismatch: arms differ by\
 $HUNK_ARM hunks, $BASECOMMIT changed $HUNK_GIT"

say "CBOOC_TREES ok files_differing=1 hunks=$HUNK_ARM (matches $BASECOMMIT)"
say "CBOOC_TREE_SHA old=$(sha256sum "$RUN/old/rtl/matvec_core.vhd" | cut -c1-16)\
 new=$(sha256sum "$RUN/new/rtl/matvec_core.vhd" | cut -c1-16)"

# THE MANIFEST.  Written where git exists so that import mode can re-assert the
# provenance where it does not.
{
  echo "prepared_on=$(hostname)"
  echo "prepared_at=$(date -Is)"
  echo "repo_head=$(git -C "$REPO" rev-parse HEAD)"
  echo "base_commit=$BASECOMMIT"
  echo "sha256_old=$(sha256sum "$RUN/old/rtl/matvec_core.vhd" | cut -d' ' -f1)"
  echo "sha256_new=$(sha256sum "$RUN/new/rtl/matvec_core.vhd" | cut -d' ' -f1)"
  echo "hunks=$HUNK_ARM"
} > "$RUN/MANIFEST.txt"
say "CBOOC_MANIFEST_WRITTEN $RUN/MANIFEST.txt"
fi

# ===========================================================================
# 2. THE CARD'S GEOMETRY.
#
# Read from the GENERATORS, not from prose: hw/fk33/gen_fk33_engine.py lines
# 84-96 (BLK 32, ROWS_IF 48, NPORTS_W 24, NPORTS_S 3, AXI_DW 256, ADDR_W 40,
# MAXCOLS/MAXROWS_BFP 17408, FIFO_DEPTH 512, MAXB/MAXOUT/DESC_MAXB 16), plus
# DUAL_CLK and USE_XEXP_PORT true from the card's engine cell.
#
# `CB_STYLE=distributed` IS THE LOAD-BEARING ONE AND IS NOT THE ENGINE
# DEFAULT.  The card build is `FK33_CB_STYLE=distributed`
# (docs/WORKLOG.md:17; :147 quotes the 1,536 -> 48 fanout).  At the default
# `regs`, CB_COPIES = CB_RANKS = 48 and `cb_rank_of(c) = c` is the IDENTITY, so
# BOTH ARMS ARE THE SAME NETLIST and the experiment measures nothing while
# printing two full result rows.  sim/ooc_levercost_run.sh's own `AGEN` carries
# `CB_STYLE=regs`, which is correct for ITS question and fatal for this one.
# The tcl refuses `regs` unless CBO_ALLOW_REGS=1.
#
# `FAST_POP` IS HELD CONSTANT, NOT LEFT TO DEFAULT.  It is build 11b's OTHER
# change; a float between arms would reproduce the recorded five-variable
# "one-variable experiment" exactly.
# ===========================================================================
AGEN="BLK=32 ROWS_IF=48 NPORTS_W=24 NPORTS_S=3 AXI_DW=256 ADDR_W=40 \
MAXCOLS=17408 MAXROWS_BFP=17408 FIFO_DEPTH=512 MAXB=16 MAXOUT=16 DESC_MAXB=16 \
DUAL_CLK=true USE_XEXP_PORT=true CHECK_JOB_INDEX=false CB_STYLE=distributed \
FAST_POP=$FASTPOP"
ACLK="s_axi_aclk=13.333 m_aclk=4.000"

CGEN="BLK=32 ROWS_IF=48 MAXCOLS=17408 MAXROWS_BFP=17408 CB_ROWS_PER_COPY=1 \
CB_STYLE=distributed"
CCLK="clk=13.333"

case "$TARGET" in
  matvec_int4_desc_axi) GEN="$AGEN"; CLK="$ACLK";;
  matvec_core)          GEN="$CGEN"; CLK="$CCLK";;
  *) die "CBO_TARGET=$TARGET is not one of matvec_int4_desc_axi / matvec_core.
  Any other entity needs its own generic set written down here first; an entity
  drawn on its DEFAULTS is the recorded 'wrong shape' failure." ;;
esac
say "CBOOC_GEOMETRY target=$TARGET gen=\"$GEN\" clk=\"$CLK\""

# ===========================================================================
# 3. THE GHDL ELABORATION GATE, which is everything this can be validated on
#    without a synthesiser.
#
# GATE ON THE ANNOUNCEMENT THE RTL ITSELF PRINTS, NEVER ON AN EXIT CODE.
# MEASURED 2026-09-20 on GHDL 1.0.0 mcode: both arms elaborate and then fail at
# time 0 with `overflow detected in process P7`, because `matvec_core` is being
# run as a TOP with unstimulated `integer` ports (n_cols et al. sit at
# integer'left).  That is a property of running a datapath unit with no
# stimulus, it is IDENTICAL in both arms, and it is not an elaboration failure.
# `matvec_int4_desc_axi` exits 0 with only NUMERIC_STD metavalue warnings.
#
# THE TEETH ARE IN THE ANNOUNCEMENT'S CONTENT, and they discriminate the two
# arms directly: `0b34200` ADDED `CB_RANKS=` to that report line, so
#     new  ->  CB_COPIES=1536  AND  CB_RANKS=48
#     old  ->  CB_COPIES=1536  AND  NO CB_RANKS AT ALL
# A run where both arms print the same line is two copies of one arm, which is
# the failure this gate exists to catch.
# ===========================================================================
ghdl_arm() {           # $1 = arm dir   $2 = unit   $3 = generics
  local dir="$1" unit="$2" gen="$3" gl=() g
  local wd="$dir/ghdlwork" log="$dir/ghdl_${unit}.log"
  mkdir -p "$wd"
  for g in $gen; do gl+=("-g$g"); done
  ( cd "$dir" \
    && ghdl -i --std=08 --workdir=ghdlwork rtl/*.vhd \
    && ghdl -m --std=08 --workdir=ghdlwork "$unit" \
    && ghdl -r --std=08 --workdir=ghdlwork "$unit" "${gl[@]}" --stop-time=0ns \
  ) > "$log" 2>&1
  echo "$log"
}

say "=== CBOOC GHDL elaboration gate ==="
GHDL_RC=0
UNITS="matvec_core"
[ "$TARGET" = "matvec_core" ] || UNITS="matvec_core $TARGET"
for arm in old new; do
  for unit in $UNITS; do
    case "$unit" in
      matvec_core)          ugen="$CGEN";;
      matvec_int4_desc_axi) ugen="$AGEN";;
      *) continue;;
    esac
    log=$(ghdl_arm "$RUN/$arm" "$unit" "$ugen")
    ann=$(grep -m1 "LEVER C ACTIVE" "$log" || true)
    if [ -z "$ann" ]; then
      say "CBOOC_GHDL FAIL arm=$arm unit=$unit: no 'LEVER C ACTIVE' announcement"
      sed -n '1,15p' "$log"; GHDL_RC=1; continue
    fi
    if ! echo "$ann" | grep -q "CB_COPIES=1536"; then
      say "CBOOC_GHDL FAIL arm=$arm unit=$unit: CB_COPIES is not 1536 -- the"
      say "  geometry is wrong and nothing drawn at it would mean anything"
      say "  $ann"; GHDL_RC=1; continue
    fi
    if [ "$arm" = "new" ]; then
      echo "$ann" | grep -q "CB_RANKS=48" \
        || { say "CBOOC_GHDL FAIL arm=new unit=$unit: no CB_RANKS=48 in the"
             say "  announcement -- the 'new' tree does not carry $BASECOMMIT"
             say "  $ann"; GHDL_RC=1; continue; }
    else
      echo "$ann" | grep -q "CB_RANKS" \
        && { say "CBOOC_GHDL FAIL arm=old unit=$unit: the announcement DOES"
             say "  carry CB_RANKS -- the 'old' tree is not the pre-change RTL"
             say "  $ann"; GHDL_RC=1; continue; }
    fi
    say "CBOOC_GHDL PASS arm=$arm unit=$unit :: $ann"
  done
done
[ "$GHDL_RC" = 0 ] || die "the GHDL elaboration gate failed; nothing was drawn"

if [ "${CBO_PREPARE_ONLY:-0}" = "1" ]; then
  say "CBOOC_PREPARED run=$RUN (CBO_PREPARE_ONLY=1, no Vivado started)"
  say "CBOOC_NEXT  CBO_ROOT='$ROOT' CBO_TARGET=$TARGET CBO_CAP=$CAP bash sim/ooc_cbooc_run.sh"
  exit 0
fi

# ===========================================================================
# 4. THE DRAWS.
# ===========================================================================
# THE PRESENCE GATE, by /proc/PID/exe and NEVER by a command line.  A command
# line matches siblings: this project has measured `ps -eo args | grep
# unwrapped/lnx64.o/vivado` counting four bash processes and a grep as Vivado,
# and a /proc loop matching the script text that was searching for it.
#
# PRESENCE IS A LANE CHECK, NOT A QUEUE: two waiters on it both start.  If
# another CBOOC job is queued, chain it on the LINE-ANCHORED `CBOOC_DONE`
# sentinel of the job ahead and keep this only as the safety net.
vivado_present() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*) return 0;; esac
  done
  return 1
}
rss_now() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*)
      awk -v p=$p '/VmRSS/{s+=$2} END{print s}' /proc/$p/status;; esac
  done | awk '{s+=$1} END {printf "%.2f", s/1048576}'
}

while vivado_present; do
  say "CBOOC_WAIT $(date -Is): a Vivado is present on this box ($(rss_now) GB\
 summed); re-check in 120 s"
  sleep 120
done

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || die "no vivado on PATH"

USE_SD=0
if systemd-run --user --scope --quiet -p MemoryHigh=1G true 2>/dev/null; then
  USE_SD=1; say "CBOOC_CGROUP systemd-run --user scope available, cap $CAP"
else
  say "CBOOC_CGROUP systemd-run --user unavailable; plain run, RSS sampler only"
fi

draw() {   # $1 = arm (old|new)
  local arm="$1" tag="cb_$1"
  local out="$RUN/out_$arm" log="$RUN/run_$arm.log" peak=0 cur unit="cbooc_${arm}_$$"
  mkdir -p "$out"
  local t0; t0=$(date +%s)
  say "=== CBOOC draw $tag arm=$arm target=$TARGET begin $(date -Is) ==="
  if [ "$USE_SD" = 1 ]; then
    ( cd "$out" && CBO_TAG="$tag" CBO_TARGET="$TARGET" CBO_OUT="$out" \
        CBO_RTL="$RUN/$arm/rtl" CBO_GEN="$GEN" CBO_CLK="$CLK" \
        systemd-run --user --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
        bash -c "cat /proc/self/cgroup > '$out/cgroup.txt'; exec vivado -mode batch -nojournal -log '$out/vivado_$tag.log' -source '$REPO/sim/ooc_cbooc.tcl'" ) > "$log" 2>&1 &
  else
    ( cd "$out" && CBO_TAG="$tag" CBO_TARGET="$TARGET" CBO_OUT="$out" \
        CBO_RTL="$RUN/$arm/rtl" CBO_GEN="$GEN" CBO_CLK="$CLK" \
        vivado -mode batch -nojournal -log "$out/vivado_$tag.log" \
               -source "$REPO/sim/ooc_cbooc.tcl" ) > "$log" 2>&1 &
  fi
  local pid=$!
  local cgpeak="NA" cgswap="NA" cgdir=""
  while kill -0 $pid 2>/dev/null; do
    cur=$(rss_now); [ -z "$cur" ] && cur=0
    awk -v a="$cur" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$cur"
    if [ -z "$cgdir" ] && [ -s "$out/cgroup.txt" ]; then
      cgdir="/sys/fs/cgroup$(sed -n 's/^0::\(.*\)$/\1/p' "$out/cgroup.txt")"
    fi
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.peak" ]; then
      cgpeak=$(cat "$cgdir/memory.peak")
      # `memory.swap.current` is a LEVEL and the kernel offers no
      # `memory.swap.peak`, so it must be MAXED here or the figure recorded is
      # whatever happened to be in swap at the last poll before exit.  MEASURED
      # by LEVERCOST: 1,024 MB recorded against 3,891 MB observed mid-run.
      if [ -r "$cgdir/memory.swap.current" ]; then
        s=$(cat "$cgdir/memory.swap.current")
        if [ "$cgswap" = "NA" ] || [ "$s" -gt "$cgswap" ]; then cgswap="$s"; fi
      fi
    fi
    sleep 5
  done
  wait $pid; local rc=$?
  local wall=$(( $(date +%s) - t0 ))
  local capb; capb=$(numfmt --from=iec "$CAP" 2>/dev/null || echo 0)
  local cgmb="NA" swmb="NA" atcap="no"
  if [ "$cgpeak" != "NA" ]; then
    cgmb=$(( cgpeak / 1048576 ))
    [ "$capb" -gt 0 ] && [ $(( cgpeak * 100 )) -ge $(( capb * 99 )) ] && atcap="YES"
  fi
  [ "$cgswap" != "NA" ] && swmb=$(( cgswap / 1048576 ))
  echo "arm=$arm tag=$tag target=$TARGET peak_rss_gb=$peak cgroup_peak_mb=$cgmb cgroup_swap_mb=$swmb at_cap=$atcap wall_s=$wall rc=$rc" > "$out/mem.txt"
  # THE SENTINEL, LINE-ANCHORED: this log contains the tcl's own source text,
  # so an unanchored grep matches the script that writes the line.  Twice in
  # this project an unanchored form reported a finished synthesis seconds after
  # launch.  And never gate on rc: a Vivado run can print full success and then
  # die on a Tcl error afterwards.
  if ! grep -qE "^CBOOC_DONE $tag\$" "$log"; then
    say "CBOOC_FAIL $tag: no CBOOC_DONE sentinel (rc=$rc, peak ${peak} GB,\
 cgroup ${cgmb} MB, swap ${swmb} MB, wall ${wall} s)"
    grep -E "^ERROR|^CRITICAL WARNING" "$out/vivado_$tag.log" 2>/dev/null | head -10
    tail -25 "$log"
    return 1
  fi
  say "CBOOC_OK $tag rc=$rc peak_rss=${peak}GB cgroup_peak=${cgmb}MB\
 swap=${swmb}MB at_cap=$atcap wall=${wall}s"
  grep -E "^CBOOC_(RESULT|SYNTH_VS_OPT|CENSUS|CB|FANOUT_TOP|FANOUT_CBW|CBW_PATH|INTRA|WORST_GLOBAL|WORST_CLK|CLKMADE|CLKMISS|READ|GENERICS|ARM_MD5)" "$log"
  say "CBOOC_LOGMSG $tag synth_8-10226=$(grep -c 'Synth 8-10226' "$out/vivado_$tag.log")\
 synth_8-7186=$(grep -c 'Synth 8-7186' "$out/vivado_$tag.log")"
  return 0
}

rc=0
for arm in $ONLY; do
  case "$arm" in
    old|new) draw "$arm" || rc=1;;
    *) die "unknown arm '$arm' (expected old and/or new)";;
  esac
done

# ---------------------------------------------------------------------------
# THE DELTA TABLE.  Printed only when BOTH arms produced a sentinel; a
# one-armed table is not a comparison and must not look like one.
# ---------------------------------------------------------------------------
say "=== CBOOC_TABLE (per arm; the census is authoritative over report_utilization) ==="
for arm in $ONLY; do
  [ -f "$RUN/out_$arm/result_cb_$arm.csv" ] && tail -1 "$RUN/out_$arm/result_cb_$arm.csv" | sed "s/^/$arm: /"
  [ -f "$RUN/out_$arm/mem.txt" ] && sed "s/^/$arm: /" "$RUN/out_$arm/mem.txt"
done
if [ -f "$RUN/out_old/result_cb_old.csv" ] && [ -f "$RUN/out_new/result_cb_new.csv" ]; then
  python3 - "$RUN/out_old/result_cb_old.csv" "$RUN/out_new/result_cb_new.csv" <<'PY'
import csv, sys
def row(p):
    with open(p) as f: return list(csv.DictReader(f))[0]
o, n = row(sys.argv[1]), row(sys.argv[2])
print("CBOOC_DELTA  field            old            new          new-old")
for k in ("lut","lut_logic","lut_mem","ff","bram_tile","ramb36","ramb18",
          "uram","dsp","carry8","f7","f8"):
    try:
        a, b = float(o[k]), float(n[k])
    except (ValueError, KeyError):
        print("CBOOC_DELTA  %-14s %14s %14s   (not numeric)" % (k, o.get(k), n.get(k)))
        continue
    print("CBOOC_DELTA  %-14s %14g %14g %+14g" % (k, a, b, b - a))
for k in ("cb_synth","cb_opt","fan_synth","fan_opt","timing_per_clk",
          "cbw_worst_slack"):
    print("CBOOC_DELTA  %-14s old=%s | new=%s" % (k, o.get(k), n.get(k)))
PY
else
  say "CBOOC_NODELTA: both arms are needed for a comparison and at least one is\
 missing.  A one-armed result is not a measurement of a change."
fi
say "CBOOC_ALLDONE rc=$rc run=$RUN"
exit $rc
