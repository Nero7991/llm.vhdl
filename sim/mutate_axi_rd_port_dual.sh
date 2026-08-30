#!/usr/bin/env bash
# Mutation test for rtl/axi_rd_port.vhd's DUAL_CLOCK generate -- the `start`
# toggle synchroniser, the `run` level crossing back to the core domain, the
# `rst` synchroniser, and the two gates that hang off `run`.
#
# WHY THIS UNIT.  docs/debugging/2026-08-29_cdc-and-fifo-coverage.md benched the
# two units this port instantiates and then named the port's OWN generate as
# the next thing with no coverage.  Every gate row that instantiates
# axi_rd_port does so at DUAL_CLK = false, which takes the `g_sc` branch, so
# `g_dc` had never been elaborated on a gate run.
#
# ---------------------------------------------------------------------------
# THE FOUR ROWS THAT MATTER MOST ARE THE SURVIVORS
# ---------------------------------------------------------------------------
# P1, P4, P5, P8 and P9 all cut a synchroniser down -- to one flop, or to no
# flop at all -- and every one of them SURVIVES.  That is not a weakness of
# this bench: an RTL simulator samples atomically, so a level that crosses with
# no synchroniser at all crosses cleanly.  It is the same resolution floor that
# G1/G3/G4/C6 hit on rtl/async_fifo.vhd.
#
# sim/cdc_teeth.sh is the flow that reaches them, and it does: MEASURED
# 2026-08-29, removing the read-pointer synchroniser inside async_fifo turns
# report_cdc's summary from 5 Warnings into 12 Critical "1-bit unknown CDC
# circuitry" rows at synchroniser depth 0.  Read the two tables together; each
# one alone is a misleading picture of the coverage.
#
# ---------------------------------------------------------------------------
# THREE VERDICTS.  ABORT IS COUNTED AS A KILL BUT REPORTED SEPARATELY.
# ---------------------------------------------------------------------------
#   KILL   the bench's own counters or one of its checks.
#   ABORT  ghdl stopped the run: a bound check, an RTL assert, or a hang.
#   SURV   the bench printed "0 errors across N clock ratios".
#
# ---------------------------------------------------------------------------
# CORRECTION 2026-08-29 (TRACK A7).  P8 IS NOT A LOST-WORD DEFECT.
# ---------------------------------------------------------------------------
# docs/debugging/2026-08-29_asurv-subsystem-a-mutation-survivors.md finding 3
# said of this row's single-clock twin:
#
#   > an ungated `f_qr` pops those words while `q_valid` is suppressed and they
#   > are lost
#
# The "and they are lost" half is WITHDRAWN.  Its harm needs `f_qv = '1'` while
# `run_c` is still low at the RISE of a job, and that is unreachable at EVERY
# clock ratio: both are 2FF core-domain synchronisers, `run_c`'s starts from
# `run_f` at the aclk edge entering S_RUN, and `f_qv`'s starts from the FIFO
# write pointer, which cannot move until the first R beat lands at least two
# aclk edges LATER (rtl/async_fifo.vhd:360 syncs wp_g on rclk, :353 adds an
# output stage on top).  So `run_c` rises at or before `f_qv`, always.
#
# MEASURED: the exact 0d14a70 RTL plus P8, at a 20:1 aclk:clk ratio (the
# `awild` row added below), produced ZERO value errors.  The FK33's own ratio is
# 250:200 = 1.25.  Do not go looking for a ratio that makes it bite.
#
# P8 is still not an equivalent mutant -- it really does pop the FIFO while the
# output is suppressed -- but everything it pops is residue the flush is about
# to discard.  It is now caught by an INVARIANT in rtl/axi_rd_port.vhd rather
# than by a value oracle, and that invariant is a tautology of the correct
# design.  That is the reason to assert it, not a reason to discard it.
#
# Nothing under rtl/ is edited; every mutation is applied to a COPY.
#
# Usage: bash sim/mutate_axi_rd_port_dual.sh
# Env:   SCRATCH=<dir>   ONLY=<tag-substring>
set -uo pipefail

# SELF-ISOLATE -- see sim/regress.sh for why.  bash reads a script lazily by
# byte offset, so an edit while an instance runs resumes it mid-token.
if [ -z "${MUT_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_axi_rd_port_dual.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_axi_rd_port_dual.sh: the private copy does not parse -- the" \
         "original was probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUT_ISOLATED=1 MUT_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUT_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/axi_rd_port.vhd
TB=sim/tb_axi_rd_port_dual.vhd
DEPS="rtl/util_pkg.vhd rtl/stream_fifo.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
GHDL="${GHDL:-ghdl}"
mkdir -p "$SCRATCH"

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

score() {   # score <log> <rc>
  python3 - "$1" "$2" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
log = "\n".join(l for l in log.splitlines() if "metavalue detected" not in l)
# The ratio COUNT is read out of the bench rather than hardcoded: it was 3
# until TRACK A7 added `awild`, and a hardcoded 3 scored every row ABORT.
m = re.search(r"errors across (\d+) clock ratios", log)
NRATIO = m.group(1) if m else "?"

tot  = re.search(r"axi_rd_port_dual: (\d+) errors across \d+ clock ratios", log)
# THE CHECKER'S OWN DIAGNOSTICS COME FIRST.  A run that both reports an error
# and then aborts is a CAUGHT mutation, and reading the abort first would score
# it as the weaker verdict.
diag = re.search(r"tb_axi_rd_port_dual\.vhd:\d+:\d+:@[^:]*:\(report error\): (.+)", log)
rtlg = re.search(r"(?:async_fifo|axi_rd_fsm|axi_rd_port)\.vhd:\d+:\d+:@[^:]*:"
                 r"\((?:assertion|report) failure\): (.+)", log)
bound = re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)
lang = re.search(r"ghdl[^:]*:error: (.+)", log)
hung = re.search(r"simulation stopped (by --stop-time|@)", log)

if tot and int(tot.group(1)) == 0 and "PASS: tb_axi_rd_port_dual" in log:
    print("SURV|0 errors across %s clock ratios" % NRATIO)
elif diag:
    print("KILL|%s" % diag.group(1).strip()[:60])
elif tot and int(tot.group(1)) != 0:
    print("KILL|%s errors, no named diagnostic" % tot.group(1))
elif rtlg:
    print("ABORT|%s" % rtlg.group(1).strip()[:60])
elif bound:
    print("ABORT|%s" % bound.group(1).strip()[:60])
elif hung:
    print("ABORT|hung: reached --stop-time with no verdict")
elif rc == 124:
    print("ABORT|wall-clock timeout 600s -- never terminated")
elif lang:
    print("ABORT|%s" % lang.group(1).strip()[:60])
else:
    print("ABORT|no verdict line and no error at all")
PY
}

# ---------------------------------------------------------------------------
# 0. THE CONTROL.  A mutation table measured against a bench that does not pass
#    on the honest RTL measures nothing.
# ---------------------------------------------------------------------------
echo "=== control: the UNMUTATED RTL against sim/tb_axi_rd_port_dual ==="
mkdir -p "$SCRATCH/control/work" "$SCRATCH/control/run"
for f in $DEPS "$RTL" "$TB"; do
  "$GHDL" -a --std=08 -frelaxed --workdir="$SCRATCH/control/work" "$REPO/$f" \
    >>"$SCRATCH/control/analyze.log" 2>&1 || {
      echo "CONTROL DID NOT ANALYZE:"; sed -n 1,5p "$SCRATCH/control/analyze.log"
      exit 2; }
done
( cd "$SCRATCH/control/run" && timeout 600 "$GHDL" -r --std=08 -frelaxed \
    --workdir="$SCRATCH/control/work" tb_axi_rd_port_dual \
    --stop-time=40ms --stop-delta=2000000 ) >"$SCRATCH/control/log" 2>&1
grep -E "beats=|errors across|PASS|FAIL" "$SCRATCH/control/log" | grep -v metavalue
if ! grep -q "PASS: tb_axi_rd_port_dual" "$SCRATCH/control/log"; then
  echo "CONTROL FAILED -- the table below would measure nothing.  Stopping."
  exit 2
fi
echo

mutate() {   # mutate <tag> <class> <desc> <old> <new> [<old> <new> ...]
  local tag="$1" cls="$2" desc="$3"; shift 3
  [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]] && return
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir/work" "$dir/run"

  if ! patch_file "$RTL" "$dir/axi_rd_port.vhd" "$@" 2>"$dir/patch.log"; then
    printf '%-4s %-6s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$cls" "$desc"
    sed -n 1,2p "$dir/patch.log"; return
  fi

  local f ok=1
  for f in $DEPS; do
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$f" \
      >>"$dir/analyze.log" 2>&1 || ok=0
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$dir/axi_rd_port.vhd" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$TB" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  if [ "$ok" = 0 ]; then
    printf '%-4s %-6s DID NOT ANALYZE -- a mutation that will not compile has tested nothing -- %s\n' \
      "$tag" "$cls" "$desc"
    sed -n 1,3p "$dir/analyze.log"; return
  fi

  # The honest run finishes at 9.947 us of simulated time; --stop-time=40ms is
  # ~4000x, so a mutation that HANGS is caught by simulated time in seconds
  # rather than by the wall-clock backstop in minutes.
  ( cd "$dir/run" && timeout 600 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$dir/work" tb_axi_rd_port_dual \
      --stop-time=40ms --stop-delta=2000000 ) >"$dir/log" 2>&1
  local rc=$?

  local res; res=$(score "$dir/log" "$rc")
  local v="${res%%|*}"; local det="${res#*|}"
  case "$v" in
    KILL)  NKILL=$((NKILL+1)); v="KILLED  " ;;
    ABORT) NABORT=$((NABORT+1)); v="ABORT   " ;;
    *)     NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"; v="SURVIVED" ;;
  esac
  printf '%-4s %-6s %s %-60s -- %s\n' "$tag" "$cls" "$v" "$det" "$desc"
}

echo "======================================================================="
echo
echo "---- class TOG: the start pulse's toggle synchroniser ------------------"

mutate P1 TOG "the start toggle is read one flop EARLIER, so the edge detector sits on a 1FF crossing (MTBF only -- expected to survive)" \
"    start_f <= s_t2 xor s_t3;" \
"    start_f <= s_t1 xor s_t2;"

mutate P2 TOG "start_f becomes the synchronised LEVEL rather than its edge -- the FSM sees a start every cycle the toggle is high" \
"    start_f <= s_t2 xor s_t3;" \
"    start_f <= s_t2;"

mutate P3 TOG "s_tog is SET rather than toggled, so the second and every later job's start never crosses" \
"        elsif start = '1' then s_tog <= not s_tog;" \
"        elsif start = '1' then s_tog <= '1';"

mutate P4 TOG "the third toggle stage follows s_t1, so the edge detector compares two flops that are one apart in the WRONG order" \
"        s_t1 <= s_tog; s_t2 <= s_t1; s_t3 <= s_t2;" \
"        s_t1 <= s_tog; s_t2 <= s_t1; s_t3 <= s_t1;"

echo
echo "---- class RUN: the run level crossing back to the core domain ---------"

mutate P5 RUN "run_c is taken one flop early -- a 1FF crossing (MTBF only -- expected to survive)" \
"    run_c <= run_s2 and not abort_c;" \
"    run_c <= run_s1 and not abort_c;"

mutate P6 RUN "run_c is the AXI-domain run level with NO SYNCHRONISER AT ALL (MTBF only -- expected to survive, and that is the whole point of sim/cdc_teeth.sh)" \
"    run_c <= run_s2 and not abort_c;" \
"    run_c <= run_f and not abort_c;"

# THE TEETH-CHECK FOR THE 2026-08-29 FIX ITSELF.  A fix with no row that would
# have caught it leaves the next instance invisible, so this row IS the fix,
# reverted.  It restores exactly the 0d14a70 behaviour, which measured 2/3/4
# residue beats and passed the old RES_MAX = 8.
mutate PK RUN "the CORE-DOMAIN CLOSE is removed, so run_c falls only through the 2FF synchroniser and an abandoned job keeps streaming for ~5 core cycles" \
"    run_c <= run_s2 and not abort_c;" \
"    run_c <= run_s2;"

# And the other half of it: the close is applied but NEVER RELEASED on a run
# that was already low, which would wedge the gate shut for good if the release
# condition were wrong.
mutate PL RUN "abort_c is set on start and never released, so the output gate shuts on the first job and never re-opens" \
"          if start = '1' then abort_c <= '1';
          elsif run_s2 = '0' then abort_c <= '0';
          end if;" \
"          if start = '1' then abort_c <= '1';
          end if;"

mutate P7 RUN "q_valid loses its run_c gate, so the abandoned job's residue flows to the consumer until the flush lands" \
"  q_valid <= f_qv when run_c = '1' else '0';" \
"  q_valid <= f_qv;"

mutate P8 RUN "f_qr loses its run_c gate, so the FIFO is popped while the output is suppressed and those beats are lost" \
"  f_qr    <= q_ready when run_c = '1' else '0';" \
"  f_qr    <= q_ready;"

mutate P9 RUN "the run synchroniser loses its reset, so run_c can come out of reset high" \
"        if rst = '1' then run_s1 <= '0'; run_s2 <= '0';" \
"        if false then run_s1 <= '0'; run_s2 <= '0';"

echo
echo "---- class RST: the reset synchroniser into the AXI domain -------------"

mutate PA RST "frst is the RAW core-domain reset, crossing into the AXI domain unsynchronised (MTBF only -- expected to survive)" \
"    frst  <= rst_s2;" \
"    frst  <= rst;"

mutate PB RST "the reset crosses through ONE flop, not two (MTBF only -- expected to survive)" \
"        rst_s1 <= rst; rst_s2 <= rst_s1;" \
"        rst_s1 <= rst; rst_s2 <= rst;"

echo
echo "---- class GATE: the two R-channel gates that hang off run_f -----------"

mutate PC GATE "rready is no longer forced high outside S_RUN, so the drain cannot complete and the clear never happens" \
"  rready_i <= f_ir when run_f = '1' else '1';" \
"  rready_i <= f_ir;"

mutate PD GATE "f_iv is no longer gated on run_f, so beats DISCARDED by the drain are written into the FIFO instead" \
"  f_iv     <= rvalid when run_f = '1' else '0';" \
"  f_iv     <= rvalid;"

mutate PE GATE "beat_f counts an OFFERED beat rather than an ACCEPTED one, so the burst accounting retires promises that never landed" \
"  beat_f   <= rvalid and rready_i;" \
"  beat_f   <= rvalid;"

mutate PP GATE "PC AND PD TOGETHER: the drain neither forces rready high NOR discards the beat, so a drained beat is offered to a FIFO that may refuse it.  Each is individually unobservable -- read this row together with those two" \
"  rready_i <= f_ir when run_f = '1' else '1';
  rready   <= rready_i;
  f_iv     <= rvalid when run_f = '1' else '0';" \
"  rready_i <= f_ir;
  rready   <= rready_i;
  f_iv     <= rvalid;"

mutate PF GATE "q_valid is gated on the AXI-domain run level directly -- a combinational path straight across the CDC (expected to survive in simulation)" \
"  q_valid <= f_qv when run_c = '1' else '0';" \
"  q_valid <= f_qv when run_f = '1' else '0';"

echo
echo "---- class WIRE: the generate's own instantiation ----------------------"

mutate PG WIRE "TEETH-CHECK for LVL_MARGIN being passed to BOTH the FIFO and the FSM: the FIFO's margin is zeroed while the FSM keeps 3, so the throttle believes in space the read side's output stage is holding" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => LVL_MARGIN)" \
"      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => 0)"

mutate PJ WIRE "TEETH-CHECK for the five survivors that hinge on the port never refusing an R beat: the FSM is told the FIFO is always EMPTY, so the AR throttle over-issues and the FIFO really does fill" \
"      port map(clk => aclk, rst => frst, start => start_f,
               base => base, n_beats => n_beats,
               arvalid => arvalid, arready => arready,
               araddr => araddr, arlen => arlen,
               beat => beat_f, rlast => rlast,
               f_level => f_level," \
"      port map(clk => aclk, rst => frst, start => start_f,
               base => base, n_beats => n_beats,
               arvalid => arvalid, arready => arready,
               araddr => araddr, arlen => arlen,
               beat => beat_f, rlast => rlast,
               f_level => 0,"

mutate PH WIRE "the FSM is clocked by the CORE clock while the FIFO's write side is clocked by aclk -- the seam the RTL header says must never be a signal carrying one or the other" \
"      port map(clk => aclk, rst => frst, start => start_f," \
"      port map(clk => clk, rst => frst, start => start_f,"

mutate PI WIRE "the FIFO's two domains are SWAPPED: the AXI side writes on the core clock and the stream comes out on aclk" \
"      port map(wclk => aclk, wrst => frst," \
"      port map(wclk => clk, wrst => frst,"

echo
echo "======================================================================="
printf 'kill ratio: %d KILLED + %d ABORT = %d of %d;  %d SURVIVED\n' \
  "$NKILL" "$NABORT" "$((NKILL+NABORT))" "$NTOT" "$NSURV"
echo "survivors:$SURV_TAGS"
echo "scratch dir with every mutant and its log: $SCRATCH"
