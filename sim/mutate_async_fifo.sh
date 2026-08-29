#!/usr/bin/env bash
# Mutation test for rtl/async_fifo.vhd -- the clock domain crossing in the
# weight path that feeds subsystem A's whole INT4 array.
#
# WHY THIS UNIT.  Until 2026-08-29 this file and rtl/axi_rd_fsm.vhd had NO
# dedicated bench of any kind.  Both were reached only through
# rtl/axi_rd_port.vhd, and every gate row that instantiates axi_rd_port does so
# at DUAL_CLK = false, which selects rtl/stream_fifo.vhd instead -- so this
# architecture was never elaborated on a gate run at all, let alone clocked by
# two clocks.  A CDC is the worst class of defect to find on silicon: it is
# intermittent, it looks like everything else, and this project has already
# lost a day to one.
#
# ---------------------------------------------------------------------------
# WHAT sim/tb_async_fifo ACTUALLY CHECKS, read out of the file before anything
# was mutated
# ---------------------------------------------------------------------------
# Eight concurrent instances at eight clock ratios (write-fast, read-fast,
# exactly equal with coincident edges, equal with a quarter-period offset,
# 7000 ps against 6999 ps so the phase sweeps through every alignment, a deep
# 10.33x pair, a DEPTH-4 pair, and one instance whose writer is throttled on
# `w_level < DEPTH` exactly as rtl/axi_rd_fsm.vhd throttles AR issue).
#
# Per instance, in order:
#
#   * a VALUE AND ORDER oracle: the write side writes a strictly increasing
#     counter, the read side compares against its own independently maintained
#     counter, and a drop, a duplicate and a reorder are three distinct
#     diagnostics;
#   * `w_level >= true occupancy` at every write edge -- the safety guarantee
#     the AR throttle rests on, and it holds with EXACTLY zero slack
#     (MEASURED: minslack = 0 on SEVEN of the eight ratios and 1 on the eighth);
#   * occupancy never above DEPTH + OUT_MARGIN;
#   * no beat accepted while `clr` is high;
#   * the four-phase clear, entered with the writer STILL OFFERING, with
#     residue resident, followed by an emptiness check;
#   * write-domain-only reset, read-domain-only reset, and the SKEWED reset
#     rtl/axi_rd_port.vhd actually produces (rrst direct, wrst two flops late);
#   * a final drain in which every beat of the last segment is accounted for;
#   * COVERAGE ASSERTED, NOT PRINTED: a run in which the FIFO never reached its
#     full capacity of DEPTH + 2, or never presented an empty read interface,
#     FAILS.  DEPTH + 2 and not DEPTH: `do_rd` is gated on
#     `ocnt + inflight < 2`, so the read side holds two beats outside the
#     memory.  Asserting DEPTH alone let F3 and G6 survive.
#
# ---------------------------------------------------------------------------
# WHAT NO FUNCTIONAL BENCH CAN SEE, AND WHY THE SURVIVOR ROWS BELOW ARE THE
# MOST IMPORTANT ONES IN THE TABLE
# ---------------------------------------------------------------------------
# Gray coding exists so that a pointer sampled by a foreign clock mid-transition
# resolves to the old value or the new one and never to a third.  An RTL
# simulator samples atomically, so a BINARY pointer crosses just as cleanly.
# G1 below replaces BOTH bin2gray and gray2bin with the identity and SURVIVES.
# That is not a weakness of this bench in particular -- it is the resolution
# floor of every functional bench that could be written, and closing it needs
# Vivado `report_cdc` or an explicit skew model, not simulation.  The same
# applies to G3/G4, which cut the 2FF synchronisers to 1FF: that is an MTBF
# statement, not a functional one.
#
# G2 is the control that makes G1 readable: it mutates ONLY the decoder, so
# encoder and decoder disagree, and it is killed at once.  Without G2, G1's
# survival would be indistinguishable from "the bench does not check pointers".
#
# ---------------------------------------------------------------------------
# THREE VERDICTS.  ABORT IS COUNTED AS A KILL BUT REPORTED SEPARATELY.
# ---------------------------------------------------------------------------
#   KILL   the bench's own counters or one of its severity-failure asserts.
#   ABORT  ghdl stopped the run: a bound check, an RTL assert, or a hang caught
#          by --stop-time.  A kill, but worth less -- it is the language or a
#          guard noticing rather than the value checker.
#   SURV   the bench printed "0 errors across 8 clock ratios".
#
# Nothing under rtl/ is edited; every mutation is applied to a COPY in a
# private scratch directory.
#
# Usage: bash sim/mutate_async_fifo.sh
# Env:   SCRATCH=<dir>   ONLY=<tag-substring>
set -uo pipefail

# SELF-ISOLATE -- see sim/regress.sh:287 for why.  bash reads a script lazily
# by byte offset, so an edit while an instance runs resumes it mid-token.
if [ -z "${MUT_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_async_fifo.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_async_fifo.sh: the private copy does not parse -- the" \
         "original was probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUT_ISOLATED=1 MUT_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUT_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/async_fifo.vhd
TB=sim/tb_async_fifo.vhd
DEPS="rtl/util_pkg.vhd"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
GHDL="${GHDL:-ghdl}"
mkdir -p "$SCRATCH"

NKILL=0; NABORT=0; NSURV=0; NTOT=0
SURV_TAGS=""

# ---------------------------------------------------------------------------
# 0. THE CONTROL.  A mutation table measured against a bench that does not pass
#    on the honest RTL measures nothing.
# ---------------------------------------------------------------------------
echo "=== control: the UNMUTATED RTL against sim/tb_async_fifo ==="
mkdir -p "$SCRATCH/control/work" "$SCRATCH/control/run"
for f in $DEPS "$RTL" "$TB"; do
  "$GHDL" -a --std=08 -frelaxed --workdir="$SCRATCH/control/work" "$REPO/$f" \
    >>"$SCRATCH/control/analyze.log" 2>&1 || {
      echo "CONTROL DID NOT ANALYZE:"; sed -n 1,5p "$SCRATCH/control/analyze.log"
      exit 2; }
done
( cd "$SCRATCH/control/run" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
    --workdir="$SCRATCH/control/work" tb_async_fifo \
    --stop-time=2ms --stop-delta=2000000 ) >"$SCRATCH/control/log" 2>&1
if ! grep -q "PASS: tb_async_fifo" "$SCRATCH/control/log"; then
  echo "CONTROL FAILED -- nothing below would mean anything:"
  grep -v "metavalue detected" "$SCRATCH/control/log" | tail -12
  exit 2
fi
grep -v "metavalue detected" "$SCRATCH/control/log" | grep "report note" |
  sed 's/^.*(report note): //'
echo

# ---------------------------------------------------------------------------
# 1. THE PATCHER.  An anchor that is not unique has tested nothing, so a
#    non-unique or absent anchor is a hard error, never a silent skip.
# ---------------------------------------------------------------------------
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

mutate() {   # mutate <tag> <class> <desc> <old> <new> [<old> <new> ...]
  local tag="$1" cls="$2" desc="$3"; shift 3
  [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]] && return
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir/work" "$dir/run"

  if ! patch_file "$RTL" "$dir/async_fifo.vhd" "$@" 2>"$dir/patch.log"; then
    printf '%-4s %-6s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$cls" "$desc"
    sed -n 1,2p "$dir/patch.log"; return
  fi

  local f ok=1
  for f in $DEPS; do
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$f" \
      >>"$dir/analyze.log" 2>&1 || ok=0
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$dir/async_fifo.vhd" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$TB" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  if [ "$ok" = 0 ]; then
    printf '%-4s %-6s DID NOT ANALYZE -- a mutation that will not compile has tested nothing -- %s\n' \
      "$tag" "$cls" "$desc"
    sed -n 1,3p "$dir/analyze.log"; return
  fi

  # The honest run finishes at 76.03 us of simulated time in 0.42 s of wall
  # clock (MEASURED), so --stop-time=4ms is ~53x margin: a mutation that HANGS
  # is caught by simulated time in about a second rather than by a wall-clock
  # timeout in minutes.  The wall-clock timeout stays only as a backstop.
  ( cd "$dir/run" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$dir/work" tb_async_fifo \
      --stop-time=4ms --stop-delta=2000000 ) >"$dir/log" 2>&1
  local rc=$?

  local res
  res=$(python3 - "$dir/log" "$rc" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
log = "\n".join(l for l in log.splitlines() if "metavalue detected" not in l)

tot = re.search(r"async_fifo: (\d+) errors across 8 clock ratios", log)
# THE CHECKER'S OWN DIAGNOSTICS COME FIRST.  A severity-failure assert stops
# the run and ghdl then prints its own "assertion failed" epilogue; reading the
# epilogue first reports a CAUGHT mutation as an ABORT.  Five tracks have now
# independently needed this ordering.
diag = re.search(r"tb_async_fifo\.vhd:\d+:\d+:@[^:]*:\(report error\): (.+)", log)
# The RTL's own guards.  These are guards, not oracles, so they are ABORT and
# they are NAMED -- the write-into-full guard is the one this track fixed.
rtlg = re.search(r"async_fifo\.vhd:\d+:\d+:@[^:]*:"
                 r"\((?:assertion|report) failure\): (async_fifo: .+)", log)
bound = re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)
lang = re.search(r"ghdl[^:]*:error: (.+)", log)
hung = re.search(r"simulation stopped (by --stop-time|@)", log)

if tot and int(tot.group(1)) == 0 and "PASS: tb_async_fifo" in log:
    print("SURV|0 errors across 8 clock ratios")
elif diag:
    n = tot.group(1) if tot else "?"
    print("KILL|%s" % (diag.group(1).strip()[:56]))
elif tot and int(tot.group(1)) != 0:
    print("KILL|%s errors, no named diagnostic" % tot.group(1))
elif rtlg:
    print("ABORT|%s" % rtlg.group(1).strip()[:56])
elif bound:
    print("ABORT|%s" % bound.group(1).strip()[:56])
elif hung:
    print("ABORT|hung: reached --stop-time with no verdict")
elif rc == 124:
    print("ABORT|wall-clock timeout 300s -- never terminated")
elif lang:
    print("ABORT|%s" % lang.group(1).strip()[:56])
else:
    print("ABORT|no verdict line and no error at all")
PY
)
  local v="${res%%|*}"; local det="${res#*|}"
  case "$v" in
    KILL)  NKILL=$((NKILL+1)); v="KILLED  " ;;
    ABORT) NABORT=$((NABORT+1)); v="ABORT   " ;;
    *)     NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"; v="SURVIVED" ;;
  esac
  printf '%-4s %-6s %s %-56s -- %s\n' "$tag" "$cls" "$v" "$det" "$desc"
}

echo "======================================================================="
echo " mutations of rtl/async_fifo.vhd, judged by sim/tb_async_fifo.vhd"
echo " KILL = the bench's value/level/coverage checkers fired."
echo " ABRT = ghdl or an RTL guard stopped the run (a kill, worth less)."
echo "======================================================================="
echo
echo "---- class GRAY: the pointer encoding and its synchronisers -----------"

mutate G1 GRAY "BOTH bin2gray and gray2bin become the identity: the pointers cross as plain BINARY.  THE RESOLUTION FLOOR -- expected to survive, and it must" \
"    return b xor shift_right(b, 1);" \
"    return b;" \
"    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;" \
"    b := g;"

mutate G2 GRAY "TEETH-CHECK for G1: only the DECODER becomes the identity, so encoder and decoder disagree" \
"    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;" \
"    b := g;"

mutate G3 GRAY "the read pointer crosses through ONE flop, not two (MTBF only -- expected to survive)" \
"  rp_bin_w <= gray2bin(rp_g_s2);" \
"  rp_bin_w <= gray2bin(rp_g_s1);"

mutate G4 GRAY "the write pointer crosses through ONE flop, not two (MTBF only -- expected to survive)" \
"  wp_bin_r <= gray2bin(wp_g_s2);" \
"  wp_bin_r <= gray2bin(wp_g_s1);"

mutate G5 GRAY "the gray encode of the NEXT write pointer uses the CURRENT one, so the pointer the read side sees lags by a beat" \
"          wp_g <= bin2gray(wp + 1);" \
"          wp_g <= bin2gray(wp);"

mutate G6 GRAY "the read pointer's gray encode lags the same way" \
"          rp_g <= bin2gray(rp + 1);" \
"          rp_g <= bin2gray(rp);"

echo
echo "---- class FULL: the flag the +123.88 MHz restructuring rewrote --------"

mutate F1 FULL "full_r loses its LOOK-AHEAD arm, so it rises one cycle late and exactly one beat overruns the memory" \
"      elsif used_w = to_unsigned(DEPTH-1, AW+1) and wr_now = '1' then
        full_r <= '1';" \
"      elsif false then
        full_r <= '1';"

mutate F2 FULL "TEETH-CHECK for the write-into-full guard this track fixed: full asserts one slot LATE, so wr_now is high with used_w = DEPTH" \
"      if used_w >= to_unsigned(DEPTH, AW+1) then" \
"      if used_w >= to_unsigned(DEPTH+1, AW+1) then"

mutate F3 FULL "full asserts one slot EARLY: the FIFO silently holds DEPTH-1 and the coverage assert is the only thing that can see it" \
"      if used_w >= to_unsigned(DEPTH, AW+1) then" \
"      if used_w >= to_unsigned(DEPTH-1, AW+1) then"

mutate F4 FULL "w_ready forgets its clr term, so beats are accepted during the clear and thrown away" \
"  w_ready  <= '0' when clr = '1' or full_r = '1' else '1';" \
"  w_ready  <= '0' when full_r = '1' else '1';"

mutate F5 FULL "wr_now forgets its clr term while w_ready keeps it.  EXPECTED TO SURVIVE: the memory write lives in the branch the clear takes over, so during a clear it is not reached at all" \
"  wr_now   <= '1' when w_valid = '1' and clr = '0' and wrst = '0'
                   and full_r = '0' else '0';" \
"  wr_now   <= '1' when w_valid = '1' and wrst = '0'
                   and full_r = '0' else '0';"

mutate F6 FULL "the empty comparison drops the MSB of the pointer pair, so a FULL FIFO reads as EMPTY (the classic reason the pointers are AW+1 bits)" \
"  empty_r  <= '1' when rp = wp_bin_r else '0';" \
"  empty_r  <= '1' when rp(AW-1 downto 0) = wp_bin_r(AW-1 downto 0) else '0';"

echo
echo "---- class LVL: the registered occupancy the AR throttle reads ---------"

mutate L1 LVL "w_level_r loses the +1 that pays for its own staleness -- the exact unsafe direction the RTL header derives" \
"      w_level_r <= to_integer(used_w) + OUT_MARGIN + 1;" \
"      w_level_r <= to_integer(used_w) + OUT_MARGIN;"

mutate L2 LVL "w_level_r loses the OUT_MARGIN term entirely: the read side's output stage becomes invisible to the throttle" \
"      w_level_r <= to_integer(used_w) + OUT_MARGIN + 1;" \
"      w_level_r <= to_integer(used_w) + 1;"

mutate L3 LVL "w_level goes back to the COMBINATIONAL pre-2026-08-28 form.  Safe, and 123.88 MHz slower -- a functional bench cannot see timing" \
"  w_level  <= w_level_r;" \
"  w_level  <= to_integer(used_w) + OUT_MARGIN;"

mutate L4 LVL "the occupancy subtraction is reversed" \
"  used_w   <= wp - rp_bin_w;" \
"  used_w   <= rp_bin_w - wp;"

echo
echo "---- class CLR: the four-phase handshake ------------------------------"

mutate C1 CLR "clr_done is the caller's own clr fed straight back: the acknowledgement no longer proves the READ side saw anything" \
"  clr_done <= clr_a_s2;" \
"  clr_done <= clr;"

mutate C2 CLR "the read side acknowledges from the RUNNING branch as well, so the ack can precede the parking" \
"      else
        clr_ack_r <= '0';
        o := ocnt;" \
"      else
        clr_ack_r <= '1';
        o := ocnt;"

mutate C3 CLR "the clear no longer empties the read side's OUTPUT STAGE, so up to three beats of residue survive it" \
"        ob_wp     <= 0; ob_rp <= 0; ocnt <= 0;
        mem_q_v   <= '0';
        clr_ack_r <= '1';" \
"        clr_ack_r <= '1';"

mutate C4 CLR "the clear no longer parks the READ pointer" \
"        rp        <= (others => '0');
        rp_g      <= (others => '0');" \
"        null;"

mutate C5 CLR "the clear no longer parks the WRITE pointer" \
"      elsif clr = '1' then
        wp   <= (others => '0');
        wp_g <= (others => '0');" \
"      elsif clr = '1' then
        null;"

mutate C6 CLR "the clear request crosses through ONE flop into the read domain, not two (MTBF only -- expected to survive)" \
"      elsif clr_r_s2 = '1' then" \
"      elsif clr_r_s1 = '1' then"

echo
echo "---- class OUT: the read-side output stage ----------------------------"

mutate O1 OUT "the output stage is allowed a third beat in flight, one more than it can hold" \
"                   and (ocnt + inflight) < 2 else '0';" \
"                   and (ocnt + inflight) < 3 else '0';"

mutate O2 OUT "the in-flight memory read is not counted, so a read is issued against a stage that is already committed" \
"  inflight <= 1 when mem_q_v = '1' else 0;" \
"  inflight <= 0;"

mutate O3 OUT "the memory read is marked valid unconditionally, so every cycle pushes a beat into the output stage" \
"        mem_q_v <= do_rd;" \
"        mem_q_v <= '1';"

mutate O4 OUT "the output stage's read pointer follows its WRITE pointer, so beats come out in the wrong order once both are in use" \
"        if ocnt > 0 and q_ready = '1' then
          ob_rp <= (ob_rp + 1) mod 2;" \
"        if ocnt > 0 and q_ready = '1' then
          ob_rp <= ob_wp;"

mutate O5 OUT "q_valid is asserted whenever anything is in flight, one cycle before the data is in the stage" \
"  q_valid <= '1' when ocnt > 0 else '0';" \
"  q_valid <= '1' when ocnt > 0 or mem_q_v = '1' else '0';"

mutate O6 OUT "the read pointer advances on the memory read being ISSUED but the memory is addressed from the OLD pointer -- an off-by-one in the fetch" \
"        mem_q   <= mem(to_integer(rp(AW-1 downto 0)));" \
"        mem_q   <= mem(to_integer(rp(AW-1 downto 0) + 1));"

echo
echo "---- class RST: reset behaviour in each domain ------------------------"

mutate R1 RST "the read-domain reset no longer clears the output stage, so residue survives a reset" \
"        ob_wp <= 0; ob_rp <= 0; ocnt <= 0; mem_q_v <= '0';" \
"        null;"

mutate R2 RST "the write-domain reset no longer clears the synchronised read pointer (expected to survive: those two flops track rp_g, which the read reset holds at 0 anyway)" \
"        rp_g_s1 <= (others => '0'); rp_g_s2 <= (others => '0');
        clr_a_s1 <= '0'; clr_a_s2 <= '0';" \
"        clr_a_s1 <= '0'; clr_a_s2 <= '0';"

mutate R3 RST "the read-domain reset no longer parks the read pointer" \
"        rp <= (others => '0'); rp_g <= (others => '0');
        wp_g_s1 <= (others => '0'); wp_g_s2 <= (others => '0');" \
"        wp_g_s1 <= (others => '0'); wp_g_s2 <= (others => '0');"

echo
echo "---- class GUARD: the elaboration guard -------------------------------"

mutate D1 GUARD "TEETH-CHECK: the power-of-two guard is inverted, so the correct DEPTH violates it" \
"  assert 2**AW = DEPTH" \
"  assert 2**AW /= DEPTH"

mutate D2 GUARD "the power-of-two guard is REMOVED (expected to survive: a removed guard cannot change a conforming design -- read it together with D1)" \
"  assert 2**AW = DEPTH" \
"  assert true or 2**AW = DEPTH"

echo
echo "======================================================================="
printf 'kill ratio: %d KILLED + %d ABORT = %d of %d;  %d SURVIVED\n' \
  "$NKILL" "$NABORT" "$((NKILL+NABORT))" "$NTOT" "$NSURV"
[ -n "$SURV_TAGS" ] && echo "survivors:$SURV_TAGS"
echo "scratch dir with every mutant and its log: $SCRATCH"
