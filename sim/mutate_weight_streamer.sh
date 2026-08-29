#!/usr/bin/env bash
# Mutation test for rtl/weight_streamer.vhd -- subsystem A's reassembly seam.
#
# WHY THIS UNIT, SECOND.  matvec_core is the arithmetic; weight_streamer is
# what decides WHICH bits reach it.  Spec 6.5a's sub-region layout is a SEAM
# between two programs -- tools/pack_int4.py writes it, this RTL reads it --
# and a seam that both sides get wrong the same way is a silently wrong
# answer, not a build failure.  The header of the RTL says so in as many
# words: "Break it and the packed file no longer describes what this merge
# produces, which is a silent wrong answer, not a build failure."
#
# ---------------------------------------------------------------------------
# WHAT sim/tb_weight_streamer ACTUALLY CHECKS
# ---------------------------------------------------------------------------
# It is a genuine two-encoding oracle, which is the strongest checker shape in
# this tree and rarer than it should be:
#
#   * the MEMORY is built from the SLICE definition -- walk the bits of
#     sub-region p, work out from the bit index which row, which weight and
#     which nibble bit it is, and fetch that;
#   * the EXPECTED value is built from the ROW definition -- walk rows and
#     weights and place each at its own bit offset.
#
# The DUT has to turn the first into the second, and the two derivations are
# written independently.  That is NOT a round trip: a packer plus a reversed
# decoder passes its own self-test while both are wrong (the m7 mutant, on the
# record in this project).  Here neither side is the inverse of the other.
#
# Comparison is BIT-EXACT with no tolerance, and the verdict is
# `assert b_a = 0` / `assert b_b = 0` at severity failure, so it has teeth.
#
# ---------------------------------------------------------------------------
# TWO GEOMETRIES, IN ONE RUN, AND THE BRANCH TAGGING THAT NEEDS
# ---------------------------------------------------------------------------
# tb_weight_streamer instantiates ws_check TWICE and both run concurrently:
#
#   A  ROWS_IF=48 BLK=32 AXI_DW=256  NPORTS_W=24 NPORTS_S=3  GRP=1  (FK33)
#   B  ROWS_IF=4  BLK=32 AXI_DW=128  NPORTS_W=4  NPORTS_S=1  GRP=2  (AXU3EG,
#                                                     already in a bitstream)
#
# These select DIFFERENT code, and an untagged table would be misleading in
# both directions:
#
#   * the scale-superword SLICE loop `for q in 0 to NPORTS_S-1` has ONE
#     iteration at geometry B, so any mutation that reorders or reindexes the
#     slices is a NO-OP there and can only ever be killed by A;
#   * the GRP chunking (`s_chunk`, `s_hold((s_chunk+1)*SW-1 downto ...)`) has
#     GRP=1 at geometry A, so `s_chunk` is always 0 and every chunk-pointer
#     mutation is a no-op there and can only be killed by B.
#
# So a mutation reported as killed by ONE geometry is not a weak result; for
# half of these it is the ONLY result available. The columns below say which.
#
#   FK33   killed by the ROWS_IF=48 / AXI_DW=256 instance
#   AXU    killed by the ROWS_IF=4  / AXI_DW=128 instance
#   both   killed by both
#
# ---------------------------------------------------------------------------
# THREE VERDICTS.  ABORT IS COUNTED AS A KILL BUT REPORTED SEPARATELY.
# ---------------------------------------------------------------------------
#   KILL   a nonzero reassembly-error count, or one of the bench's own
#          severity-failure asserts.
#   ABORT  ghdl stopped the run: an elaboration-time assert in the RTL, a
#          bound check, or a hang caught by --stop-time.  Counted as a kill --
#          the mutant did not survive -- but worth LESS, because it is the
#          language or an elaboration guard noticing rather than the value
#          checker.  Several of the RTL's own 6.5/6.5a asserts land here, and
#          that is the correct place for them: they are guards, not oracles.
#   SURV   the bench printed "0 reassembly errors across both geometries".
#
# Nothing under rtl/ is edited; every mutation is applied to a COPY in a
# private scratch directory.
#
# Usage: bash sim/mutate_weight_streamer.sh
# Env:   SCRATCH=<dir>   ONLY=<tag-substring>
set -uo pipefail

# SELF-ISOLATE -- see sim/regress.sh:287 for why.  bash reads a script lazily
# by byte offset, so an edit while an instance runs resumes it mid-token.
if [ -z "${MUT_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_weight_streamer.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_weight_streamer.sh: the private copy does not parse -- the" \
         "original was probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUT_ISOLATED=1 MUT_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUT_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/weight_streamer.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
GHDL="${GHDL:-ghdl}"
mkdir -p "$SCRATCH"

# The closure sim/regress.sh resolves for this row, minus the file under test.
DEPS="rtl/util_pkg.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd \
      rtl/stream_fifo.vhd rtl/axi_rd_port.vhd"
TB=sim/tb_weight_streamer.vhd

NKILL=0; NABORT=0; NSURV=0; NTOT=0
SURV_TAGS=""

patch_file() {
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

mutate() {   # mutate <tag> <branch> <desc> <old> <new> [<old> <new> ...]
  local tag="$1" br="$2" desc="$3"; shift 3
  [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]] && return
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir/work" "$dir/run"

  if ! patch_file "$RTL" "$dir/weight_streamer.vhd" "$@" 2>"$dir/patch.log"; then
    printf '%-5s %-6s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$br" "$desc"
    sed -n 1,2p "$dir/patch.log"; return
  fi

  local f ok=1
  for f in $DEPS; do
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$f" \
      >>"$dir/analyze.log" 2>&1 || ok=0
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$dir/weight_streamer.vhd" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$TB" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  if [ "$ok" = 0 ]; then
    printf '%-5s %-6s DID NOT ANALYZE -- a mutation that will not compile has tested nothing -- %s\n' \
      "$tag" "$br" "$desc"
    sed -n 1,3p "$dir/analyze.log"; return
  fi

  # The honest run finishes at 535 ns and takes 0.28 s of wall clock
  # (MEASURED), so --stop-time=100us is ~187x margin: a mutation that HANGS --
  # several of the scale-path ones do -- is caught by simulated time in under
  # a second rather than by a wall-clock timeout in minutes.  The wall-clock
  # timeout stays only as a backstop.
  ( cd "$dir/run" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$dir/work" tb_weight_streamer \
      --stop-time=100us --stop-delta=2000000 ) >"$dir/log" 2>&1
  local rc=$?

  local res
  res=$(python3 - "$dir/log" "$rc" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
# per-instance counters, so the branch that fired is named rather than guessed
per = dict((m.group(1), int(m.group(2)))
           for m in re.finditer(r"(ROWS_IF=\d+ AXI_DW=\d+):[^\n]*?, (\d+) wrong", log))
a = per.get("ROWS_IF=48 AXI_DW=256")
b = per.get("ROWS_IF=4 AXI_DW=128")
tot = re.search(r"weight_streamer: (\d+) reassembly errors across both geometries", log)
# Checker diagnostics FIRST: a severity-failure assert stops the run and ghdl
# then prints its own "assertion failed" epilogue.  Reading that epilogue
# before the bench's own line reports a CAUGHT mutation as an ABORT.
checker = re.search(r"tb_weight_streamer\.vhd:\d+:\d+:@[^:]*:"
                    r"\((?:assertion|report) failure\): (.+)", log)
wrongln = re.search(r"\(report error\): (ROWS_IF=[^\n]*reassembled wrong)", log)
bound = re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)
# The RTL's OWN elaboration guards (6.5, 6.5a, the 4 KB burst rule).  These
# are guards, not oracles, so they are reported as ABORT and named.
elab = re.search(r"weight_streamer\.vhd:\d+:\d+:@0ms:"
                 r"\((?:assertion|report) failure\): (weight_streamer: .+)", log)
lang = re.search(r"ghdl[^:]*:error: (.+)", log)

who = []
if a: who.append("FK33")
if b: who.append("AXU")
who = "+".join(who) if who else "?"

if tot and int(tot.group(1)) == 0 and a == 0 and b == 0:
    print("SURV|both|0 reassembly errors across both geometries")
elif (a or b):
    print("KILL|%s|FK33 %s wrong, AXU %s wrong" % (who, a, b))
elif checker:
    print("KILL|%s|%s" % (who, checker.group(1).strip()[:46]))
elif wrongln:
    # The checker fired but the run never reached its summary.  That is the
    # NORMAL shape for a mutation that DROPS words: the checker loop is
    # `while nw < NWORD or ns < NWORD`, so a dropped word means the loop never
    # completes and the run then hits --stop-time.  It is still a KILL -- the
    # checker named a wrong word before the hang -- and reading the hang first
    # would have downgraded a caught mutation to an ABORT.  The geometry is
    # taken from the diagnostic itself, since no summary line exists to read.
    g = "FK33" if "ROWS_IF=48" in wrongln.group(1) else "AXU"
    hung = " (then hung)" if re.search(r"simulation stopped", log) else ""
    print("KILL|%s|%s%s" % (g, wrongln.group(1).strip()[:38], hung))
elif elab:
    print("ABORT|elab|%s" % elab.group(1).strip()[:46])
elif bound:
    print("ABORT|-|%s" % bound.group(1).strip()[:46])
elif re.search(r"simulation stopped by --stop-time|simulation stopped @", log):
    print("ABORT|-|hung: reached --stop-time with no verdict")
elif rc == 124:
    print("ABORT|-|wall-clock timeout 300s -- never terminated")
elif lang:
    print("ABORT|-|%s" % lang.group(1).strip()[:46])
else:
    print("ABORT|-|no verdict line and no error at all")
PY
)
  local v="${res%%|*}"; local rest="${res#*|}"
  local who="${rest%%|*}"; local det="${rest#*|}"

  case "$v" in
    KILL)  NKILL=$((NKILL+1)); v="KILLED  " ;;
    ABORT) NABORT=$((NABORT+1)); v="ABORT   " ;;
    *)     NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"; v="SURVIVED" ;;
  esac
  printf '%-5s %-6s %s %-5s %-46s -- %s\n' "$tag" "$br" "$v" "$who" "$det" "$desc"
}

echo "======================================================================="
echo " mutations of rtl/weight_streamer.vhd, judged by sim/tb_weight_streamer"
echo " geometries, BOTH in every run:"
echo "   FK33  ROWS_IF=48 AXI_DW=256  NPORTS_W=24 NPORTS_S=3 GRP=1"
echo "   AXU   ROWS_IF=4  AXI_DW=128  NPORTS_W=4  NPORTS_S=1 GRP=2"
echo " the 'who' column names the geometry whose counter went nonzero."
echo " KILL = the value checker fired.  ABRT/elab = an RTL elaboration guard"
echo " or the language stopped the run (a kill, but worth less)."
echo "======================================================================="
echo
echo "---- class MERGE: the weight side, spec 6.5/6.5a ----------------------"

mutate M1 both "weight sub-region p is placed at slice NPORTS_W-1-p (the slice order is reversed)" \
"    w_data((p+1)*AXI_DW-1 downto p*AXI_DW) <= qd(p);" \
"    w_data((NPORTS_W-p)*AXI_DW-1 downto (NPORTS_W-1-p)*AXI_DW) <= qd(p);"

mutate M2 both "the weight merge takes its data from the SCALE ports" \
"    w_data((p+1)*AXI_DW-1 downto p*AXI_DW) <= qd(p);" \
"    w_data((p+1)*AXI_DW-1 downto p*AXI_DW) <= qd((p+1) mod NPORTS_W);"

mutate M3 both "the all-valid POP GATE is dropped: lanes may come from different words" \
"    for p in 0 to NPORTS_W-1 loop a := a and qv(p); end loop;" \
"    a := qv(0);"

mutate M4 both "the pop gate ORs the port valids instead of ANDing them" \
"    for p in 0 to NPORTS_W-1 loop a := a and qv(p); end loop;" \
"    for p in 0 to NPORTS_W-1 loop a := a or qv(p); end loop;"

mutate M5 both "w_valid is asserted whenever ANY beat is present, but the pop still needs all" \
"  pop_w   <= all_v and w_ready;
  w_valid <= all_v;" \
"  pop_w   <= all_v and w_ready;
  w_valid <= '1';"

mutate M6 both "the FIFOs are popped without waiting for w_ready, so words are dropped under backpressure" \
"  pop_w   <= all_v and w_ready;" \
"  pop_w   <= all_v;"

echo
echo "---- class SCALE: the 6.5a superword.  Read the branch column ---------"
echo "     the slice loop is 1-deep at AXU; the chunk pointer is 1-deep at FK33"

mutate S1 FK33 "the superword's slices are assembled in reverse sub-region order" \
"            s_hold((q+1)*AXI_DW-1 downto q*AXI_DW) <= qd(NPORTS_W+q);" \
"            s_hold((NPORTS_S-q)*AXI_DW-1 downto (NPORTS_S-1-q)*AXI_DW) <= qd(NPORTS_W+q);"

mutate S2 FK33 "every superword slice is filled from scale sub-region 0" \
"            s_hold((q+1)*AXI_DW-1 downto q*AXI_DW) <= qd(NPORTS_W+q);" \
"            s_hold((q+1)*AXI_DW-1 downto q*AXI_DW) <= qd(NPORTS_W);"

mutate S3 FK33 "the scale ports are popped INDEPENDENTLY, so slices of one superword come from different superwords" \
"    for q in 0 to NPORTS_S-1 loop a := a and qv(NPORTS_W+q); end loop;" \
"    a := qv(NPORTS_W);"

mutate S4 AXU "the scale chunk pointer never advances, so every group in a superword is group 0" \
"          if s_chunk = GRP-1 then
            s_chunk <= 0;
            s_hv    <= '0';
          else
            s_chunk <= s_chunk + 1;
          end if;" \
"          if s_chunk = GRP-1 then
            s_chunk <= 0;
            s_hv    <= '0';
          else
            s_chunk <= s_chunk;
          end if;"

mutate S5 AXU "s_data reads the chunk ABOVE the pointer" \
"  s_data  <= s_hold((s_chunk+1)*SW-1 downto s_chunk*SW);" \
"  s_data  <= s_hold((GRP-s_chunk)*SW-1 downto (GRP-1-s_chunk)*SW);"

mutate S6 AXU "the superword is refilled after every chunk, not after the last one" \
"  s_take <= '1' when s_allv = '1'
                 and (s_hv = '0' or (s_ready = '1' and s_chunk = GRP-1))
            else '0';" \
"  s_take <= '1' when s_allv = '1'
                 and (s_hv = '0' or s_ready = '1')
            else '0';"

mutate S7 both "s_take ignores s_ready, so a held superword is overwritten before it is consumed" \
"  s_take <= '1' when s_allv = '1'
                 and (s_hv = '0' or (s_ready = '1' and s_chunk = GRP-1))
            else '0';" \
"  s_take <= '1' when s_allv = '1' else '0';"

mutate S8 both "s_valid is tied high, so the consumer sees a scale group before one is held" \
"  s_valid <= s_hv;" \
"  s_valid <= '1';"

mutate S9 both "the chunk pointer is not reset when a new superword is taken" \
"        if s_take = '1' then" \
"        if s_take = '1' and false then"

echo
echo "---- class GUARD: the RTL's own 6.5 / 6.5a / AXI4 elaboration asserts --"
echo "     These are GUARDS, not oracles.  A guard that is removed should"
echo "     leave a CORRECT design correct, so a survivor here is the expected"
echo "     result and says nothing; what is being measured is whether the"
echo "     guard fires when the geometry it guards is actually violated."

mutate G1 GUARD "the 6.5 invariant NPORTS_W*AXI_DW = ROWS_IF*BLK*4 is no longer asserted" \
"  assert NPORTS_W * AXI_DW = ROWS_IF * BLK * 4" \
"  assert true or NPORTS_W * AXI_DW = ROWS_IF * BLK * 4"

mutate G2 GUARD "nss_min returns one too many, so the minimal-NPORTS_S guard rejects the correct geometry" \
"      if (n * dw) mod sw_bits = 0 then return n; end if;" \
"      if (n * dw) mod sw_bits = 0 then return n + 1; end if;"

mutate G3 GUARD "the 4 KB burst guard admits an 8 KB burst" \
"  assert MAXB * (AXI_DW / 8) <= 4096" \
"  assert MAXB * (AXI_DW / 8) <= 8192"

mutate G4 GUARD "the superword divisibility guard is inverted" \
"  assert SUPER mod SW = 0" \
"  assert SUPER mod SW /= 0"

# G1 and G3 REMOVE a guard, and a removed guard cannot change a design that
# does not violate it -- so their survival is the expected result and, on its
# own, says NOTHING about whether either assert works.  G5 and G6 are the
# teeth-check: they INVERT the same two conditions so the CORRECT geometry
# violates them.  If those abort at elaboration, the asserts are live,
# reachable and correctly wired to the generics; if they had survived, the
# guards would be decoration and G1/G3's survival would mean something quite
# different.  A checker never shown to fail has not been shown to work.
mutate G5 GUARD "TEETH-CHECK for G1: the 6.5 invariant is inverted, so the correct geometry violates it" \
"  assert NPORTS_W * AXI_DW = ROWS_IF * BLK * 4" \
"  assert NPORTS_W * AXI_DW /= ROWS_IF * BLK * 4"

mutate G6 GUARD "TEETH-CHECK for G3: the burst guard is tightened to 2 KB, which both geometries exceed" \
"  assert MAXB * (AXI_DW / 8) <= 4096" \
"  assert MAXB * (AXI_DW / 8) <= 2048"

echo
echo "======================================================================="
printf 'kill ratio: %d KILLED + %d ABORT = %d of %d;  %d SURVIVED\n' \
  "$NKILL" "$NABORT" "$((NKILL+NABORT))" "$NTOT" "$NSURV"
echo "survivors:$SURV_TAGS"
echo "scratch dir with every mutant and its log: $SCRATCH"
echo "======================================================================="
