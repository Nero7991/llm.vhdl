#!/usr/bin/env bash
# sim/mutate_ws_fastpop.sh -- teeth for the FAST_POP RENDEZVOUS coverage that
# TRACK POPPORT added to sim/tb_weight_streamer.vhd on 2026-09-20.
#
# ---------------------------------------------------------------------------
# WHY A SECOND HARNESS AND NOT ROWS IN sim/mutate_weight_streamer.sh
# ---------------------------------------------------------------------------
# That harness mutates ONE file, rtl/weight_streamer.vhd, and its result
# parser reads the two original ws_check instances by name.  The defect class
# here spans FOUR files -- the lever is threaded weight_streamer ->
# axi_rd_port -> {stream_fifo, async_fifo} -- and the most interesting rows
# are the ones where the generic is dropped at an INTERMEDIATE site, which is
# what "a generic dropped anywhere between fk33_engine and async_fifo" means
# in practice.  Bolting a four-file mutator onto a one-file harness would
# have meant rewriting its parser, and a rewritten parser is a rewritten
# oracle.
#
# This is a .sh and not a sim/tb_*.vhd, so it adds NO gate row.
#
# ---------------------------------------------------------------------------
# THE STANDING ATTRIBUTION CONTROL, ON EVERY ROW, IN TWO LAYERS
# ---------------------------------------------------------------------------
# CLAUDE.md: "A KILL DOES NOT SETTLE IT.  Run the attribution control."  Two
# things were added on 2026-09-20 and a row can be credited to either, so
# every mutation is run against THREE benches:
#
#   OLD    the newest COMMITTED revision of sim/tb_weight_streamer.vhd that
#          does not carry POPPORT's extension -- found by walking back until
#          the marker string is gone, never by assuming HEAD~, because a
#          fixed offset would make OLD equal to NEW the day POPPORT's own
#          commit lands and every cadence row would then read as
#          "pre-existing".  Two value instances, single clock, FAST_POP at
#          its default false.
#   NOCAD  the new bench with the four cadence bounds neutralised
#          (FAST_MAX raised out of reach, SLOW_MIN dropped to 0).  This is
#          the new bench MINUS its new instrument: the card's arm is
#          instantiated and its values are checked, but nothing times it.
#   NEW    the new bench entire.
#
# The credit column then reads:
#
#   pre-existing   OLD already killed it.  POPPORT's work is worth nothing
#                  on this row, and saying so is the point of the control.
#   card-arm       OLD survived, NOCAD killed.  Instantiating DUAL_CLK=true
#                  and FAST_POP=true at all was enough; no cadence needed.
#   cadence        NOCAD survived, NEW killed.  ONLY the two-sided cadence
#                  probe sees this one.  These are the rows that justify the
#                  probe existing, and POPCOVER's table says what they look
#                  like: defects that change no value anywhere.
#   SURVIVES       nothing killed it.  Reported under its own name, never
#                  discarded -- it measures the resolution floor.
#
# ---------------------------------------------------------------------------
# HOW TO READ A SURVIVOR
# ---------------------------------------------------------------------------
# A surviving mutation is not automatically a gap.  Some of these are PROOFS:
# a mutation of the FAST_POP arm cannot be seen by a bench that never selects
# it, and a mutation at a geometry this bench does not build cannot be seen at
# all.  The table below says which, per row, in the DESC text.  Do not add a
# check for a survivor without first deciding which of the two it is.
#
# Usage:  bash sim/mutate_ws_fastpop.sh                 (from the repo root)
#         SCRATCH=/mnt/storage/... ONLY=T3 bash sim/mutate_ws_fastpop.sh
set -u

REPO="$PWD"
GHDL="${GHDL:-ghdl}"
ONLY="${ONLY:-}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

TB=sim/tb_weight_streamer.vhd
# The closure sim/regress.sh resolves for this row.  All four mutable files
# are in it; the harness copies every one of them per mutation and patches
# whichever the row names, so a row never sees another row's patch.
SRCS="rtl/util_pkg.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd \
      rtl/stream_fifo.vhd rtl/axi_rd_port.vhd rtl/weight_streamer.vhd"

# OLD: the pre-POPPORT bench.  Taken from git rather than from a copy in the
# tree, so it cannot silently drift into agreement with the new one.
# The OLD bench is "the newest committed revision of this file that does NOT
# carry POPPORT's extension", found by walking back until the marker is gone
# rather than by assuming a fixed number of commits.  Hardcoding HEAD~ would
# silently make OLD equal to NEW the moment POPPORT's own commit lands, which
# would report every cadence row as pre-existing -- the control failing open.
OLDTB="$SCRATCH/tb_old.vhd"
OLDREV=""
for rev in HEAD HEAD~1 HEAD~2 HEAD~3 HEAD~4 HEAD~5 HEAD~6 HEAD~7 HEAD~8; do
  if git -C "$REPO" show "$rev":"$TB" >"$OLDTB" 2>/dev/null; then
    if ! grep -q "TRACK POPPORT" "$OLDTB"; then OLDREV="$rev"; break; fi
  fi
done
if [ -z "$OLDREV" ]; then
  echo "CANNOT FIND A PRE-POPPORT $TB IN THE LAST 9 COMMITS -- the OLD column" >&2
  echo "would not be a control.  Refusing to run rather than reporting a" >&2
  echo "credit line that cannot be trusted." >&2
  exit 2
fi
git -C "$REPO" show "$OLDREV":"$TB" >"$OLDTB"
echo "OLD bench = $OLDREV:$TB"

NROW=0; NCAD=0; NARM=0; NPRE=0; NSURV=0; SURV_TAGS=""

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

# Neutralise the new instrument without removing it, so NOCAD differs from
# NEW in exactly one thing.  The probe instances still run and still check
# values; only the four two-sided bounds stop being reachable.
make_nocad() {
  sed -e 's|constant FAST_MAX : natural  := PNW - 1;|constant FAST_MAX : natural  := 1000000;|' \
      -e 's|constant SLOW_MIN : natural  := PNW + 4;|constant SLOW_MIN : natural  := 0;|' \
      "$REPO/$TB" >"$1"
  grep -qE 'FAST_MAX : natural  := 1000000' "$1" || { echo "NOCAD ANCHOR LOST" >&2; return 2; }
  grep -qE 'SLOW_MIN : natural  := 0'        "$1" || { echo "NOCAD ANCHOR LOST" >&2; return 2; }
}

# Run one (mutated sources, bench) pair.  Prints KILL or SURV.
run_one() {   # run_one <dir> <srcdir> <benchfile>
  local dir="$1" srcdir="$2" bench="$3"
  mkdir -p "$dir/work" "$dir/run"
  local f ok=1
  for f in $SRCS; do
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$srcdir/$(basename "$f")" \
      >>"$dir/analyze.log" 2>&1 || ok=0
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$bench" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  if [ "$ok" = 0 ]; then echo "NOBUILD"; return; fi

  # The honest run ends at 725 ns.  --stop-time=200us is ~275x, so a mutation
  # that HANGS -- several of the rendezvous ones do -- is caught by simulated
  # time in about a second, not by a wall-clock timeout in minutes.
  ( cd "$dir/run" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$dir/work" tb_weight_streamer \
      --stop-time=200us --stop-delta=2000000 ) >"$dir/log" 2>&1
  local rc=$?

  python3 - "$dir/log" "$rc" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
tot = re.search(r"weight_streamer: (\d+) reassembly errors across both geometries", log)
# A clean run is: the marker at zero AND rc 0.  Anything else is a kill of
# some kind; the detail string names which, so a row is never credited to a
# check that did not fire.
if tot and int(tot.group(1)) == 0 and rc == 0:
    print("SURV|clean")
    raise SystemExit
fail = re.search(r"tb_weight_streamer\.vhd:\d+:\d+:@[^:]*:"
                 r"\((?:assertion|report) failure\): (.+)", log)
wrong = re.search(r"\(report error\): ([^\n]*reassembled wrong)", log)
elab  = re.search(r"\.vhd:\d+:\d+:@0ms:\((?:assertion|report) failure\): (.+)", log)
bound = re.search(r"(bound check failure[^\n]*|index \([-\d]+\) out of bounds[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)
if tot and int(tot.group(1)) > 0:
    print("KILL|values: %s wrong" % tot.group(1))
elif elab:
    print("KILL|elab: %s" % elab.group(1).strip()[:52])
elif fail:
    print("KILL|%s" % fail.group(1).strip()[:52])
elif wrong:
    hung = " (then hung)" if re.search(r"simulation stopped", log) else ""
    print("KILL|%s%s" % (wrong.group(1).strip()[:40], hung))
elif bound:
    print("KILL|%s" % bound.group(1).strip()[:52])
elif re.search(r"simulation stopped by --stop-time|simulation stopped @", log):
    print("KILL|hung: reached --stop-time with no verdict")
elif rc == 124:
    print("KILL|wall-clock timeout 300s")
else:
    print("KILL|rc=%d, no diagnostic matched" % rc)
PY
}

mutate() {   # mutate <tag> <file> <desc> <old> <new> [...]
  local tag="$1" rel="$2" desc="$3"; shift 3
  [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]] && return 0
  NROW=$((NROW+1))
  local dir="$SCRATCH/$tag"
  mkdir -p "$dir/src"

  local f
  for f in $SRCS; do cp "$REPO/$f" "$dir/src/$(basename "$f")"; done
  if ! patch_file "$REPO/$rel" "$dir/src/$(basename "$rel")" "$@" 2>"$dir/patch.log"; then
    printf '%-4s %-22s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$(basename "$rel")" "$desc"
    sed -n 1,2p "$dir/patch.log"
    return 0
  fi

  local nocad="$dir/tb_nocad.vhd"
  make_nocad "$nocad" || return 0

  local r_old r_nocad r_new credit
  r_old=$(run_one "$dir/old"   "$dir/src" "$OLDTB")
  r_nocad=$(run_one "$dir/noc" "$dir/src" "$nocad")
  r_new=$(run_one "$dir/new"   "$dir/src" "$REPO/$TB")

  case "${r_old%%|*}${r_nocad%%|*}${r_new%%|*}" in
    *NOBUILD*)
      printf '%-4s %-20s DID NOT ANALYZE -- a mutation that will not compile has tested nothing\n' \
        "$tag" "$(basename "$rel")"
      sed -n 1,3p "$dir/new/analyze.log" 2>/dev/null
      return 0 ;;
  esac

  if   [ "${r_old%%|*}"   = KILL ]; then credit="pre-existing"; NPRE=$((NPRE+1))
  elif [ "${r_nocad%%|*}" = KILL ]; then credit="card-arm";     NARM=$((NARM+1))
  elif [ "${r_new%%|*}"   = KILL ]; then credit="CADENCE";      NCAD=$((NCAD+1))
  else credit="SURVIVES"; NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"
  fi

  printf '%-4s %-20s %-8s %-8s %-8s %-12s %s\n' \
    "$tag" "$(basename "$rel")" "${r_old%%|*}" "${r_nocad%%|*}" "${r_new%%|*}" \
    "$credit" "${r_new#*|}"
  printf '     %s\n' "$desc"
}

echo "========================================================================="
echo " FAST_POP rendezvous mutations, judged by sim/tb_weight_streamer"
echo " OLD   = $OLDREV bench (no card arm, no cadence)"
echo " NOCAD = new bench, cadence bounds neutralised (card arm only)"
echo " NEW   = new bench entire"
echo "========================================================================="
printf '%-4s %-20s %-8s %-8s %-8s %-12s %s\n' \
  TAG FILE OLD NOCAD NEW CREDIT DETAIL

echo "---- class T: the lever's THREADING, which no value oracle can see ------"

# T1/T2 are the RTL comment's own worry made concrete: "forwarded to EVERY one
# of the NPORTS_W + NPORTS_S ports ... a rate lever applied to some of them and
# not the others buys nothing at all."  Dropping the generic at a forwarding
# site is exactly what a defaulted-false generic looks like in this tree.
mutate T1 rtl/weight_streamer.vhd \
"gen_w loses the lever: the 24 WEIGHT ports default to false while the 3 scale ports keep it.  The composite rate is then the weight side's, i.e. the lever bought nothing" \
"                  FAST_POP => FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => w_base" \
"                  FAST_POP => false)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => w_base"

mutate T2 rtl/weight_streamer.vhd \
"gen_s loses the lever: the 3 SCALE ports default to false while the 24 weight ports keep it.  Caught only because the two rendezvous are TIMED SEPARATELY" \
"                  FAST_POP => FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => s_base" \
"                  FAST_POP => false)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => s_base"

mutate T3 rtl/axi_rd_port.vhd \
"THE CARD'S BRANCH: the g_dc (async_fifo) instantiation at :397 drops the generic.  Single-clock builds are untouched, so a bench that never sets DUAL_CLK sees nothing at all" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => LVL_MARGIN,
                  FAST_POP => FAST_POP)" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => LVL_MARGIN,
                  FAST_POP => false)"

mutate T4 rtl/axi_rd_port.vhd \
"the OTHER branch: g_sc (stream_fifo) at :276 drops the generic.  Not the card, and it is here because the two sites are not textually identical and can be broken one at a time" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, FAST_POP => FAST_POP)" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, FAST_POP => false)"

mutate T5 rtl/weight_streamer.vhd \
"THE LEVER IS INVERTED at the fan-out: every one of the 27 ports gets NOT FAST_POP.  Both forwarding sites, so this is the whole rendezvous inverted and not one side of it" \
"                  FAST_POP => FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => w_base" \
"                  FAST_POP => not FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => w_base" \
"                  FAST_POP => FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => s_base" \
"                  FAST_POP => not FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => s_base"

mutate T6 rtl/weight_streamer.vhd \
"THE LEVER IS WIRED ON at the fan-out: all 27 ports get true whatever the caller asked for, so every non-FK33 build silently changes cadence.  This is the one a one-sided 'is it fast' check cannot see" \
"                  FAST_POP => FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => w_base" \
"                  FAST_POP => true)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => w_base" \
"                  FAST_POP => FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => s_base" \
"                  FAST_POP => true)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => s_base"

echo "---- class R: the rendezvous itself -------------------------------------"

mutate R1 rtl/weight_streamer.vhd \
"the 24-way weight AND drops port 0, so a word can be popped while one slice is absent.  A VALUE defect; the pre-existing oracle should own this row and the control says whether it does" \
"    for p in 0 to NPORTS_W-1 loop a := a and qv(p); end loop;" \
"    for p in 1 to NPORTS_W-1 loop a := a and qv(p); end loop;"

mutate R2 rtl/weight_streamer.vhd \
"the weight ports pop on all_v instead of pop_w, i.e. they ignore the consumer's back-pressure entirely" \
"  pop_w   <= all_v and w_ready;" \
"  pop_w   <= all_v;"

mutate R3 rtl/weight_streamer.vhd \
"the 3-way scale AND drops the first slice, so a superword can be assembled from two different superwords" \
"    for q in 0 to NPORTS_S-1 loop a := a and qv(NPORTS_W+q); end loop;" \
"    for q in 1 to NPORTS_S-1 loop a := a and qv(NPORTS_W+q); end loop;"

mutate R4 rtl/weight_streamer.vhd \
"s_take loses its s_ready term, so the scale superword is refilled whether or not the group in the holding register was consumed" \
"  s_take <= '1' when s_allv = '1'
                 and (s_hv = '0' or (s_ready = '1' and s_chunk = GRP-1))" \
"  s_take <= '1' when s_allv = '1'
                 and (s_hv = '0' or (s_chunk = GRP-1))"

echo "---- class P: the FAST_POP arm inside the FIFOs, seen from here ---------"

mutate P1 rtl/async_fifo.vhd \
"SHAPEAUDIT's mutant, unchanged: the FAST_POP arm of async_fifo commits FOUR beats instead of two.  It passed five benches including tb_async_fifo while every bench ran the other arm" \
"                   and ((FAST_POP and after_e < 2) or" \
"                   and ((FAST_POP and after_e < 4) or"

mutate P3 rtl/async_fifo.vhd \
"POPCOVER's P3: the FAST_POP arm of async_fifo commits only ONE.  Values correct, safe, and STRICTLY SLOWER than the shipping arm it exists to beat -- the whole lever silently undone" \
"                   and ((FAST_POP and after_e < 2) or" \
"                   and ((FAST_POP and after_e < 1) or"

mutate P5 rtl/stream_fifo.vhd \
"the same silent undoing in the OTHER FIFO: stream_fifo's FAST_POP arm commits only one.  Single-clock builds only, so it is invisible at the card's DUAL_CLK" \
"                      ((FAST_POP and after_e < 2) or" \
"                      ((FAST_POP and after_e < 1) or"

mutate P6 rtl/async_fifo.vhd \
"the SHIPPING arm of async_fifo is widened to three.  NOT a FAST_POP row -- it is here as the control that says the harness can still see a defect in the arm the bench always ran" \
"                        ((not FAST_POP) and (ocnt + inflight) < 2))" \
"                        ((not FAST_POP) and (ocnt + inflight) < 3))"

echo "---- class S: DELIBERATE RESOLUTION-FLOOR PROBES ------------------------"
# CLAUDE.md: "Report mutations that do NOT bite under their own names -- they
# measure your check's resolution floor and are the most valuable line in the
# table.  Never discard one."  The twelve rows above all bite, and a table with
# no survivor has not measured where the instrument stops.  These three are
# chosen to sit at or just past the edge, so the floor is a measurement rather
# than an assumption.

mutate S1 rtl/async_fifo.vhd \
"POPCOVER's P2: the FAST_POP arm commits THREE beats, one more than the output stage holds.  One beat of over-commit rather than two -- if the cadence check is the thing catching it, the margin it needs is what this row reports" \
"                   and ((FAST_POP and after_e < 2) or" \
"                   and ((FAST_POP and after_e < 3) or"

mutate S2 rtl/axi_rd_port.vhd \
"OUT_MARGIN is raised by one in the g_dc branch ONLY.  It is the other generic that :397 carries and :276 does not, so it is the nearest neighbour of T3 that is not FAST_POP at all" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => LVL_MARGIN,
                  FAST_POP => FAST_POP)" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => LVL_MARGIN + 1,
                  FAST_POP => FAST_POP)"

mutate S3 rtl/async_fifo.vhd \
"the SHIPPING arm is made SLOWER, not faster: it commits one beat instead of two.  EXPECTED TO SURVIVE BY CONSTRUCTION -- the two-sided check asks 'is the shipping arm FAST', never 'is it exactly 1.5', so a slower-than-shipping default is outside it on purpose.  A check that killed this would be asserting a cadence nobody has argued for" \
"                        ((not FAST_POP) and (ocnt + inflight) < 2))" \
"                        ((not FAST_POP) and (ocnt + inflight) < 1))"

echo "========================================================================="
printf ' rows %d   pre-existing %d   card-arm %d   CADENCE %d   SURVIVED %d\n' \
  "$NROW" "$NPRE" "$NARM" "$NCAD" "$NSURV"
[ -n "$SURV_TAGS" ] && echo " survivors:$SURV_TAGS  -- read each one's DESC before adding any check"
echo "========================================================================="
