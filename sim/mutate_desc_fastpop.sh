#!/usr/bin/env bash
# sim/mutate_desc_fastpop.sh -- teeth for the FAST_POP coverage TRACK DESCARM
# added to sim/tb_matvec_fk33_desc_dual.vhd on 2026-09-20.
#
# ---------------------------------------------------------------------------
# WHAT THIS HARNESS IS FOR, AND WHY IT IS NOT sim/mutate_ws_fastpop.sh
# ---------------------------------------------------------------------------
# TRACK POPCOVER (fbac64e) cleared FAST_POP inside rtl/async_fifo.vhd.  TRACK
# POPPORT (62dc777) cleared the 27-way rendezvous in rtl/weight_streamer.vhd
# and closed by naming the one site neither had reached:
#
#   "the descriptor port's own FAST_POP at matvec_int4_desc_axi:628 and :690
#    is outside every bench's cone so far."
#
# That is this harness.  :628 is the DESCRIPTOR read master `dfetch`; :690 is
# the core.  POPPORT's harness judges with sim/tb_weight_streamer, whose cone
# contains neither: weight_streamer is INSIDE matvec_int4, so nothing it can
# see tells you whether the descriptor master got the lever.
#
# This is a .sh and not a sim/tb_*.vhd, so it adds NO gate row.
#
# ---------------------------------------------------------------------------
# THE STANDING ATTRIBUTION CONTROL, ON EVERY ROW, IN TWO LAYERS
# ---------------------------------------------------------------------------
# CLAUDE.md: "A KILL DOES NOT SETTLE IT.  Run the attribution control."  Two
# things were added on 2026-09-20 -- the second (FAST_POP = true) arm, and the
# drain probe that times it -- and a row can be credited to either, so every
# mutation is run against THREE benches:
#
#   OLD    the newest COMMITTED revision of the two bench files that does not
#          carry TRACK DESCARM's extension, found by walking back until the
#          marker string is gone.  NEVER a fixed HEAD~n: a fixed offset makes
#          OLD equal to NEW the day this track's own commit lands, and every
#          cadence row would then read "pre-existing" -- the control failing
#          open.  One arm, DUAL_CLK = true, FAST_POP at its default false.
#   NOCAD  the NEW bench with -gCADENCE=false.  Both arms are instantiated and
#          both value oracles run; only the three timing bounds stop firing.
#          This costs no source edit at all, because CADENCE is a generic of
#          the wrapper rather than a constant inside it -- so unlike a sed'd
#          control there is no anchor here that can silently go stale.
#   NEW    the new bench entire.
#
# The credit column then reads:
#
#   pre-existing   OLD already killed it.  This track's work is worth nothing
#                  on that row, and saying so is the point of the control.
#   card-arm       OLD survived, NOCAD killed.  Merely INSTANTIATING the
#                  FAST_POP = true arm was enough; no timing involved.
#   CADENCE        NOCAD survived, NEW killed.  Only the drain probe sees it.
#                  These are the rows that justify the probe existing.
#   SURVIVES       nothing killed it.  Reported under its own name, never
#                  discarded -- it measures the resolution floor.
#
# ---------------------------------------------------------------------------
# HOW TO READ A SURVIVOR
# ---------------------------------------------------------------------------
# A surviving mutation is not automatically a gap.  Some are PROOFS: a
# mutation of a generate arm this bench never builds cannot be seen by it, and
# a mutation of a port that carries no data in this configuration changes
# nothing that exists.  The DESC text on each row says which.  Do not add a
# check for a survivor without first deciding which of the two it is.
#
# AND ONE SURVIVOR PAIR IS A GAP THAT WAS MEASURED AND DELIBERATELY LEFT OPEN.
# C1 and C2 mutate the CORE's forwarding site, :690, and survive every column.
# The obvious repair -- time the weight path as well as the descriptor drain --
# was BUILT AND MEASURED and does not work: shipping 342 ns against FAST_POP
# 366 ns over the identical 27 beats, i.e. the card's arm is the SLOWER of the
# two there.  The weight slaves stall on an LFSR that advances once per AXI
# edge from reset, and the arms enter that window 42 ns apart because of the
# descriptor drain, so they meet different stall realisations.  A "the arms
# differ" check would pass on that head start alone and would credit :690 for
# something :628 did.  The bench prints the window and asserts nothing about
# it; the beats COUNT is asserted, because a count is not a time.
#
# Usage:  bash sim/mutate_desc_fastpop.sh                (from the repo root)
#         SCRATCH=/mnt/storage/... ONLY=D1 bash sim/mutate_desc_fastpop.sh
#
# COST.  Each row is three full runs of a bench that instantiates subsystem A
# twice and walks 23 descriptor cases: MEASURED about 7 minutes per row on the
# workstation, one core, no Vivado beside it.  It is not a gate row and is not
# meant to be run casually.
set -u

REPO="$PWD"
GHDL="${GHDL:-ghdl}"
ONLY="${ONLY:-}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

# The two bench files.  BOTH are needed for the OLD column: the wrapper gained
# the second arm and the architecture gained the generic that feeds it, and an
# OLD wrapper against a NEW architecture is neither revision.
TB_ARCH=sim/tb_matvec_fk33_desc.vhd
TB_WRAP=sim/tb_matvec_fk33_desc_dual.vhd
TOP=tb_matvec_fk33_desc_dual

# The compile closure sim/regress.sh resolves for this row, in its order.
SRCS="rtl/util_pkg.vhd rtl/act_mem_striped.vhd rtl/async_fifo.vhd \
      rtl/axi_rd_fsm.vhd rtl/matvec_int4_desc_pkg.vhd rtl/mv4i_arith_pkg.vhd \
      rtl/stream_fifo.vhd rtl/axi_rd_port.vhd rtl/matvec_core.vhd \
      rtl/weight_streamer.vhd rtl/matvec_int4.vhd rtl/matvec_int4_desc_axi.vhd"

# The vector directory.  This bench reads mv_fk33_tr.txt, which ref/mv_fk33_tr
# builds from a REAL packed tensor, and ../mem through a symlink.  Point
# RUNDIR at a kept sim/regress.sh workdir for this row
# (REGRESS_SCRATCH=<dir> bash sim/regress.sh --only tb_matvec_fk33_desc_dual)
# rather than rebuilding the vector here: the generator is regress.sh's and
# duplicating its arguments is duplicating its oracle.
RUNDIR="${RUNDIR:-}"
if [ -z "$RUNDIR" ] || [ ! -f "$RUNDIR/mv_fk33_tr.txt" ]; then
  echo "RUNDIR must name a directory holding mv_fk33_tr.txt and a mem symlink." >&2
  echo "Make one with:" >&2
  echo "  REGRESS_SCRATCH=<dir> bash sim/regress.sh --only tb_matvec_fk33_desc_dual" >&2
  echo "then RUNDIR=<dir>/sim_tb_matvec_fk33_desc_dual/run" >&2
  exit 2
fi

# ---------------------------------------------------------------- OLD bench
OLD_ARCH="$SCRATCH/old_arch.vhd"
OLD_WRAP="$SCRATCH/old_wrap.vhd"
OLDREV=""
for rev in HEAD HEAD~1 HEAD~2 HEAD~3 HEAD~4 HEAD~5 HEAD~6 HEAD~7 HEAD~8; do
  if git -C "$REPO" show "$rev":"$TB_WRAP" >"$OLD_WRAP" 2>/dev/null; then
    if ! grep -q "TRACK DESCARM" "$OLD_WRAP"; then OLDREV="$rev"; break; fi
  fi
done
if [ -z "$OLDREV" ]; then
  echo "CANNOT FIND A PRE-DESCARM $TB_WRAP IN THE LAST 9 COMMITS -- the OLD" >&2
  echo "column would not be a control.  Refusing to run rather than printing" >&2
  echo "a credit line that cannot be trusted." >&2
  exit 2
fi
git -C "$REPO" show "$OLDREV":"$TB_WRAP" >"$OLD_WRAP"
git -C "$REPO" show "$OLDREV":"$TB_ARCH" >"$OLD_ARCH"
# Two-sided: the OLD pair must NOT carry the marker and the NEW pair MUST.  A
# control that silently equals the treatment is the failure mode this guards.
grep -q "TRACK DESCARM" "$REPO/$TB_WRAP" || {
  echo "THE WORKING TREE'S $TB_WRAP DOES NOT CARRY THE MARKER -- OLD and NEW" >&2
  echo "cannot be told apart, so no credit column is meaningful." >&2; exit 2; }
echo "OLD bench = $OLDREV ($TB_ARCH + $TB_WRAP)"

NROW=0; NCAD=0; NARM=0; NPRE=0; NSURV=0; NANCH=0; SURV_TAGS=""

patch_file() {  # patch_file <src> <dst> <old> <new> ...
  python3 - "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES, expected 1\n" % (i // 2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
}

# Build a work library from a source list plus a bench pair.  Returns 1 if any
# analysis failed, so a mutation that does not compile is reported as having
# tested nothing rather than as a kill.
build_lib() {   # build_lib <dir> <srcdir> <archfile> <wrapfile>
  local dir="$1" srcdir="$2" arch="$3" wrap="$4" f ok=0
  mkdir -p "$dir/work"
  for f in $SRCS; do
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" \
      "$srcdir/$(basename "$f")" >>"$dir/analyze.log" 2>&1 || ok=1
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$arch" \
    >>"$dir/analyze.log" 2>&1 || ok=1
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$wrap" \
    >>"$dir/analyze.log" 2>&1 || ok=1
  return $ok
}

# Run one prepared library.  Prints KILL|<detail> or SURV|clean.
#
# --stop-time=3ms against an honest end of 730 us.  A mutation that DEADLOCKS
# is then caught by SIMULATED time in a minute rather than by a wall-clock
# timeout in five, and 4.1x leaves room for a mutation that merely makes the
# design slower (several of these do) to still finish and be judged on values.
run_one() {   # run_one <dir> <top> [ghdl -g args...]
  local dir="$1"; shift
  local top="$1"; shift
  ( cd "$RUNDIR" && timeout 900 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$dir/work" "$top" "$@" \
      --stop-time=3ms --stop-delta=1000000 --max-stack-alloc=0 ) \
      >"$dir/log" 2>&1
  local rc=$?
  python3 - "$dir/log" "$rc" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
# The marker sim/regress.sh itself greps for.  A clean run is that phrase AND
# rc 0; anything else is a kill, and the detail names WHICH check fired so a
# row is never credited to a check that did not.
clean = "every checked mutation is refused" in log and rc == 0
if clean:
    print("SURV|clean")
    raise SystemExit
drain = re.search(r"\(report error\): (FAST_POP DRAIN IS NOT [^\n]*)", log)
inv   = re.search(r"\(report error\): (THE LEVER IS NOT PRESENT[^\n]*)", log)
sup   = re.search(r"\(report error\): (THE SUPPLY MOVED[^\n]*)", log)
arm   = re.search(r"\(report error\): (DRAIN PROBE DID NOT ARM[^\n]*)", log)
cases = re.search(r"(\d+) cases run, (\d+) failures", log)
fail  = re.search(r":\d+:\d+:@[^:]*:\((?:assertion|report) failure\): (.+)", log)
bound = re.search(r"(bound check failure[^\n]*|index \([-\d]+\) out of bounds[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)
# Values first: a value failure is the strongest statement the bench makes and
# must never be reported as a timing kill.
vals = [int(m.group(2)) for m in re.finditer(r"(\d+) cases run, (\d+) failures", log)]
if any(v > 0 for v in vals):
    print("KILL|values: %d case failure(s)" % max(vals))
elif bound:
    print("KILL|%s" % bound.group(1).strip()[:56])
elif sup:
    print("KILL|%s" % sup.group(1).strip()[:56])
elif arm:
    print("KILL|%s" % arm.group(1).strip()[:56])
elif drain:
    print("KILL|%s" % drain.group(1).strip()[:56])
elif inv:
    print("KILL|%s" % inv.group(1).strip()[:56])
elif fail:
    print("KILL|%s" % fail.group(1).strip()[:56])
elif re.search(r"simulation stopped by --stop-time", log):
    print("KILL|hung: reached --stop-time with no verdict")
elif rc == 124:
    print("KILL|wall-clock timeout 900s")
else:
    print("KILL|rc=%d, no diagnostic matched" % rc)
PY
}

mutate() {   # mutate <tag> <file> <desc> <old> <new> [...]
  local tag="$1" rel="$2" desc="$3"; shift 3
  [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]] && return 0
  local dir="$SCRATCH/$tag"
  mkdir -p "$dir/src"

  local f
  for f in $SRCS; do cp "$REPO/$f" "$dir/src/$(basename "$f")"; done
  # An anchor that did not match tested NOTHING, so it is counted in its own
  # column and never in NROW.  A row that silently becomes a no-op reports
  # SURVIVES and is indistinguishable from a design with no defect -- the
  # failure POPCOVER found in its own row O1, dead since the commit that added
  # the lever and noticed only when the same edit killed it twice.
  if ! patch_file "$REPO/$rel" "$dir/src/$(basename "$rel")" "$@" 2>"$dir/patch.log"; then
    NANCH=$((NANCH+1))
    printf '%-4s %-24s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$(basename "$rel")" "$desc"
    sed -n 1,2p "$dir/patch.log"
    return 0
  fi
  NROW=$((NROW+1))

  local r_old r_nocad r_new credit
  if build_lib "$dir/old" "$dir/src" "$OLD_ARCH" "$OLD_WRAP"; then
    r_old=$(run_one "$dir/old" "$TOP")
  else
    r_old="NOBUILD|old"
  fi
  # NOCAD and NEW share ONE library: they are the same sources run with one
  # generic different, so there is nothing that can differ between them except
  # the thing under control.
  if build_lib "$dir/new" "$dir/src" "$REPO/$TB_ARCH" "$REPO/$TB_WRAP"; then
    mkdir -p "$dir/noc"; cp -a "$dir/new/work" "$dir/noc/work"
    r_nocad=$(run_one "$dir/noc" "$TOP" -gCADENCE=false)
    r_new=$(run_one "$dir/new" "$TOP")
  else
    r_nocad="NOBUILD|new"; r_new="NOBUILD|new"
  fi

  case "${r_old%%|*}${r_nocad%%|*}${r_new%%|*}" in
    *NOBUILD*)
      printf '%-4s %-24s DID NOT ANALYZE -- a mutation that will not compile has tested nothing\n' \
        "$tag" "$(basename "$rel")"
      grep -aiE 'error' "$dir/new/analyze.log" 2>/dev/null | head -3
      grep -aiE 'error' "$dir/old/analyze.log" 2>/dev/null | head -3
      return 0 ;;
  esac

  if   [ "${r_old%%|*}"   = KILL ]; then credit="pre-existing"; NPRE=$((NPRE+1))
  elif [ "${r_nocad%%|*}" = KILL ]; then credit="card-arm";     NARM=$((NARM+1))
  elif [ "${r_new%%|*}"   = KILL ]; then credit="CADENCE";      NCAD=$((NCAD+1))
  else credit="SURVIVES"; NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"
  fi

  printf '%-4s %-24s %-8s %-8s %-8s %-12s %s\n' \
    "$tag" "$(basename "$rel")" "${r_old%%|*}" "${r_nocad%%|*}" "${r_new%%|*}" \
    "$credit" "${r_new#*|}"
  printf '     %s\n' "$desc"
}

echo "========================================================================="
echo " FAST_POP mutations in the DESCRIPTOR plane, judged by sim:$TOP"
echo " OLD   = $OLDREV bench (one arm, FAST_POP false, no probe)"
echo " NOCAD = new bench, -gCADENCE=false (both arms, values only)"
echo " NEW   = new bench entire"
echo " RUNDIR= $RUNDIR"
echo "========================================================================="
printf '%-4s %-24s %-8s %-8s %-8s %-12s %s\n' \
  TAG FILE OLD NOCAD NEW CREDIT DETAIL

echo "---- class D: the DESCRIPTOR master's own lever (matvec_int4_desc_axi:628)"
echo "     The site TRACK POPPORT named as reached by no bench in the tree."

mutate D1 rtl/matvec_int4_desc_axi.vhd \
"THE DESCRIPTOR MASTER LOSES THE LEVER while the core keeps it.  This is what a generic dropped at one forwarding site looks like, and it is the exact defect POPPORT could not reach: the card asks for FAST_POP and its descriptor fetch quietly runs the shipping arm" \
"                MAXB => DESC_MAXB, MAXOUT => 2, DUAL_CLK => DUAL_CLK,
                FAST_POP => FAST_POP)" \
"                MAXB => DESC_MAXB, MAXOUT => 2, DUAL_CLK => DUAL_CLK,
                FAST_POP => false)"

mutate D2 rtl/matvec_int4_desc_axi.vhd \
"THE DESCRIPTOR MASTER IS WIRED ON: it ignores FAST_POP and always runs the fast arm, so every default instance in the tree changes cadence without asking" \
"                MAXB => DESC_MAXB, MAXOUT => 2, DUAL_CLK => DUAL_CLK,
                FAST_POP => FAST_POP)" \
"                MAXB => DESC_MAXB, MAXOUT => 2, DUAL_CLK => DUAL_CLK,
                FAST_POP => true)"

mutate D3 rtl/matvec_int4_desc_axi.vhd \
"THE DESCRIPTOR MASTER'S LEVER IS INVERTED.  Values cannot see it in either direction; only a bench that runs BOTH arms and times them can" \
"                MAXB => DESC_MAXB, MAXOUT => 2, DUAL_CLK => DUAL_CLK,
                FAST_POP => FAST_POP)" \
"                MAXB => DESC_MAXB, MAXOUT => 2, DUAL_CLK => DUAL_CLK,
                FAST_POP => not FAST_POP)"

echo "---- class C: the CORE's lever (matvec_int4_desc_axi:690) ---------------"

mutate C1 rtl/matvec_int4_desc_axi.vhd \
"THE CORE LOSES THE LEVER while the descriptor master keeps it.  The whole 27-port weight path reverts to the shipping cadence.  PREDICTED SURVIVOR and a REAL GAP, registered before the run: the probe window closes at the job's first weight AR, before one weight beat has moved, and the only window that reaches :690 is confounded by the weight slaves' stall LFSR (see the WEIGHT WINDOW note the bench prints).  POPPORT's bench proves weight_streamer HONOURS the lever; nothing proves matvec_int4_desc_axi FORWARDS it" \
"                DUAL_CLK => DUAL_CLK, CB_STYLE => CB_STYLE,
                FAST_POP => FAST_POP)" \
"                DUAL_CLK => DUAL_CLK, CB_STYLE => CB_STYLE,
                FAST_POP => false)"

mutate C2 rtl/matvec_int4_desc_axi.vhd \
"THE CORE IS WIRED ON: the 27 weight ports take the fast arm whatever the generic says.  C1's twin and the same PREDICTED SURVIVOR for the same reason" \
"                DUAL_CLK => DUAL_CLK, CB_STYLE => CB_STYLE,
                FAST_POP => FAST_POP)" \
"                DUAL_CLK => DUAL_CLK, CB_STYLE => CB_STYLE,
                FAST_POP => true)"

echo "---- class A: the INTERMEDIATE forwarding site (axi_rd_port) ------------"

mutate A1 rtl/axi_rd_port.vhd \
"THE DUAL-CLOCK ARM LOSES IT: axi_rd_port forwards false into async_fifo.  Every port of every master in this bench's DUAL configuration -- descriptor and weight alike -- runs the shipping arm" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => LVL_MARGIN,
                  FAST_POP => FAST_POP)" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => LVL_MARGIN,
                  FAST_POP => false)"

mutate A2 rtl/axi_rd_port.vhd \
"THE SINGLE-CLOCK ARM LOSES IT: axi_rd_port forwards false into stream_fifo.  The two sites are NOT textually identical, so a generic dropped at one is invisible at the other's DUAL_CLK -- and in this bench only the AXU3EG arm is single-clock" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, FAST_POP => FAST_POP)" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, FAST_POP => false)"

echo "---- class F: async_fifo's read-issue arm, reached through the plane ----"
echo "     POPCOVER's rows P1/P3/P4/P5/P6 re-asked at the descriptor plane's"
echo "     level: the question is not whether async_fifo's bench sees them --"
echo "     it does -- but whether subsystem A's own gate row does."

mutate F1 rtl/async_fifo.vhd \
"TRACK SHAPEAUDIT's mutant: the fast arm allows FOUR beats committed against an output stage that holds two.  It passed five benches before POPCOVER" \
"and ((FAST_POP and after_e < 2) or" \
"and ((FAST_POP and after_e < 4) or"

mutate F2 rtl/async_fifo.vhd \
"POPCOVER's P3: the fast arm allows only ONE.  SAFE, every value correct, and STRICTLY SLOWER than the shipping arm it exists to beat -- the whole lever silently undone.  This is the row an inequality would pass and an equality must not" \
"and ((FAST_POP and after_e < 2) or" \
"and ((FAST_POP and after_e < 1) or"

mutate F3 rtl/async_fifo.vhd \
"THE LEVER IS NOT THREADED: do_rd ignores FAST_POP and always takes the shipping arm.  This is what a generic dropped ANYWHERE between fk33_engine and async_fifo looks like from the bottom, and it is the defect the card would actually suffer" \
"and ((FAST_POP and after_e < 2) or
                        ((not FAST_POP) and (ocnt + inflight) < 2))" \
"and ((ocnt + inflight) < 2)"

mutate F4 rtl/async_fifo.vhd \
"THE LEVER IS WIRED ON: do_rd ignores FAST_POP and always takes the fast arm, so rtl/fk33_eng_cdc.vhd's two default instances change cadence without asking" \
"and ((FAST_POP and after_e < 2) or
                        ((not FAST_POP) and (ocnt + inflight) < 2))" \
"and (after_e < 2)"

mutate F5 rtl/async_fifo.vhd \
"THE TWO ARMS ARE SWAPPED.  Every value is still correct in both arms and each arm runs at the other's rate" \
"and ((FAST_POP and after_e < 2) or
                        ((not FAST_POP) and (ocnt + inflight) < 2))" \
"and ((FAST_POP and (ocnt + inflight) < 2) or
                        ((not FAST_POP) and after_e < 2))"

echo "---- class S: stream_fifo's arm, which this bench reaches only via ------"
echo "     the AXU3EG DUT (DUAL_CLK = false, and it is served no weight byte)."

mutate S1 rtl/stream_fifo.vhd \
"stream_fifo's fast arm allows FOUR committed -- F1's twin in the other FIFO.  Predicted SURVIVOR and a SCOPED GAP, not a proof: the only single-clock DUT here has its weight masters tied off, so its stream_fifos carry descriptor beats and nothing else, and the probe is not armed on it" \
"                      ((FAST_POP and after_e < 2) or" \
"                      ((FAST_POP and after_e < 4) or"

echo "---- class Z: teeth on the harness itself -------------------------------"
# Z0 must report ANCHOR FAILED.  A harness whose anchors have rotted reports
# every row SURVIVES and looks exactly like a design with no defects -- the
# failure mode POPCOVER found in its own row O1, dead since the commit that
# added the lever.
mutate Z0 rtl/async_fifo.vhd \
"SELF-TEETH: an anchor that cannot match.  This row MUST print ANCHOR FAILED; if it prints a verdict instead, the harness is patching something it did not mean to" \
"and ((FAST_POP and after_e < 99999) or" \
"and ((FAST_POP and after_e < 2) or"

echo "========================================================================="
printf ' rows %-4s pre-existing %-4s card-arm %-4s CADENCE %-4s SURVIVED %-4s anchor-failed %s\n' \
  "$NROW" "$NPRE" "$NARM" "$NCAD" "$NSURV" "$NANCH"
[ -n "$SURV_TAGS" ] && echo " survivors:$SURV_TAGS"
echo " scratch: $SCRATCH"
echo "========================================================================="
# THE EXIT CONTRACT, BOTH WAYS.
#
# A harness that kills nothing has not been shown to work.  And Z0, the
# self-teeth row, MUST fail its anchor: if the anchor-failed count is not
# exactly one on a full run, either Z0 matched something (the harness is
# patching text it did not mean to) or a real row stopped matching (that row
# is silently testing nothing and reports SURVIVES, which is indistinguishable
# from a design with no defect).
rc=0
if [ "$NROW" -gt 0 ] && [ $((NPRE + NARM + NCAD)) -eq 0 ]; then
  echo "HARNESS FAILURE: not one of $NROW rows was killed by any column." >&2
  rc=1
fi
if [ -z "$ONLY" ] && [ "$NANCH" != 1 ]; then
  echo "HARNESS FAILURE: $NANCH anchors failed, expected exactly 1 (row Z0)." >&2
  rc=1
fi
exit $rc
