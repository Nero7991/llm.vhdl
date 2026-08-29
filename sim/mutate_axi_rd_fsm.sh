#!/usr/bin/env bash
# Mutation test for rtl/axi_rd_fsm.vhd -- the AR-issue and burst-accounting FSM
# behind all 27 of the FK33's read masters.
#
# WHY THIS UNIT.  It had no dedicated bench before 2026-08-29; it was reached
# only through rtl/axi_rd_port.vhd, whose own bench runs four jobs at
# MAXOUT = 2 / DEPTH = 64 against one well-behaved slave.  This FSM owns two
# limits that decide whether the weight path is correct at all -- the FIFO-space
# throttle, whose failure is a silently overrun FIFO, and MAXOUT, whose failure
# is an AXI protocol violation the slave is entitled to punish however it likes.
#
# ---------------------------------------------------------------------------
# WHAT sim/tb_axi_rd_fsm ACTUALLY CHECKS
# ---------------------------------------------------------------------------
# The FIFO it models NEVER BACKPRESSURES -- `rready` is tied high -- and its
# occupancy is asserted never to exceed DEPTH.  That is deliberate and it is
# the single most important decision in the bench: a modelled FIFO that pushed
# back would absorb an overrun and the throttle property would pass by
# construction.  With no backpressure the throttle is the ONLY thing keeping
# the level inside DEPTH, so a wrong throttle is a numbered diagnostic.
#
# Alongside that: address tiling against an independently maintained
# expectation (every AR must carry the next address and exactly
# min(beats left, MAXB) beats), arlen decoded back and compared, the AXI rule
# that arvalid is held until arready with a stable payload, MAXOUT, and the
# four-phase clear checked as an ORDERED sequence -- drain complete, clr rises,
# clr_done rises, clr falls, clr_done falls, run rises, in that order and no
# other.  Two instances differ only in the clear acknowledgement latency
# (1 cycle = the single-clock configuration, 7 = a stand-in for the CDC) and in
# which of the two limits can bind:
#
#   ack1  DEPTH=64  MAXOUT=16  MAXB=16   MAXOUT*MAXB=256 > DEPTH, so the
#                                        FIFO-SPACE throttle binds and MAXOUT
#                                        is inert
#   ack7  DEPTH=512 MAXOUT=16  MAXB=16   MAXOUT*MAXB=256 < DEPTH, so MAXOUT
#                                        binds and the space throttle is inert
#
# That split is not decoration: rtl/axi_rd_port.vhd's own MAXOUT comment says
# MAXOUT "simply stops being reachable once MAXOUT*MAXB > DEPTH", so a single
# instance can only ever test one of the two, and asserting coverage of the
# inert one is noise.  Each instance asserts only the limit that CAN bind for
# it.  MEASURED on the honest RTL: ack1 peaks at 61 of 64 modelled beats,
# ack7 peaks at 16 of 16 outstanding bursts, and both see 9 clears.
#
# ---------------------------------------------------------------------------
# THREE VERDICTS.  ABORT IS COUNTED AS A KILL BUT REPORTED SEPARATELY.
# ---------------------------------------------------------------------------
#   KILL   one of the bench's counters or asserts fired.
#   ABORT  ghdl stopped the run: a range or bound check, or a hang caught by
#          --stop-time.  A kill, but worth less -- it is the language noticing
#          rather than the checker, and several of these mutations walk a
#          RANGED signal out of its declared range, which is exactly what those
#          ranges were narrowed for.
#   SURV   the bench printed "0 errors across 2 acknowledgement latencies".
#
# Nothing under rtl/ is edited; every mutation is applied to a COPY in a
# private scratch directory.
#
# Usage: bash sim/mutate_axi_rd_fsm.sh
# Env:   SCRATCH=<dir>   ONLY=<tag-substring>
set -uo pipefail

# SELF-ISOLATE -- see sim/regress.sh:287 for why.
if [ -z "${MUT_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_axi_rd_fsm.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_axi_rd_fsm.sh: the private copy does not parse -- the" \
         "original was probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUT_ISOLATED=1 MUT_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUT_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/axi_rd_fsm.vhd
TB=sim/tb_axi_rd_fsm.vhd
DEPS=""
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
GHDL="${GHDL:-ghdl}"
mkdir -p "$SCRATCH"

NKILL=0; NABORT=0; NSURV=0; NTOT=0
SURV_TAGS=""

echo "=== control: the UNMUTATED RTL against sim/tb_axi_rd_fsm ==="
mkdir -p "$SCRATCH/control/work" "$SCRATCH/control/run"
for f in $RTL $TB; do
  "$GHDL" -a --std=08 -frelaxed --workdir="$SCRATCH/control/work" "$REPO/$f" \
    >>"$SCRATCH/control/analyze.log" 2>&1 || {
      echo "CONTROL DID NOT ANALYZE:"; sed -n 1,5p "$SCRATCH/control/analyze.log"
      exit 2; }
done
( cd "$SCRATCH/control/run" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
    --workdir="$SCRATCH/control/work" tb_axi_rd_fsm \
    --stop-time=20ms --stop-delta=2000000 ) >"$SCRATCH/control/log" 2>&1
if ! grep -q "PASS: tb_axi_rd_fsm" "$SCRATCH/control/log"; then
  echo "CONTROL FAILED -- nothing below would mean anything:"
  grep -v "metavalue detected" "$SCRATCH/control/log" | tail -12
  exit 2
fi
grep -v "metavalue detected" "$SCRATCH/control/log" | grep "report note" |
  sed 's/^.*(report note): //'
echo

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

  if ! patch_file "$RTL" "$dir/axi_rd_fsm.vhd" "$@" 2>"$dir/patch.log"; then
    printf '%-4s %-6s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$cls" "$desc"
    sed -n 1,2p "$dir/patch.log"; return
  fi

  local ok=1
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$dir/axi_rd_fsm.vhd" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$TB" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  if [ "$ok" = 0 ]; then
    printf '%-4s %-6s DID NOT ANALYZE -- a mutation that will not compile has tested nothing -- %s\n' \
      "$tag" "$cls" "$desc"
    sed -n 1,3p "$dir/analyze.log"; return
  fi

  # The honest run finishes at 25.396 us of simulated time in 0.06 s of wall
  # clock (MEASURED), so --stop-time=40ms is ~1500x margin: a mutation that
  # HANGS -- several of the clear ones do -- is caught by simulated time in
  # under a second.  The wall-clock timeout is only a backstop.
  ( cd "$dir/run" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$dir/work" tb_axi_rd_fsm \
      --stop-time=40ms --stop-delta=2000000 ) >"$dir/log" 2>&1
  local rc=$?

  local res
  res=$(python3 - "$dir/log" "$rc" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
log = "\n".join(l for l in log.splitlines() if "metavalue detected" not in l)

tot = re.search(r"axi_rd_fsm: (\d+) errors across 2 acknowledgement latencies", log)
# THE CHECKER'S OWN DIAGNOSTICS FIRST.  A severity-failure assert stops the run
# and ghdl prints its own epilogue afterwards; reading that epilogue first
# scores a CAUGHT mutation as an ABORT.  A-MUT hit exactly this and it cost a
# whole run, so the ordering here is copied from its fix rather than rederived.
diag = re.search(r"tb_axi_rd_fsm\.vhd:\d+:\d+:@[^:]*:\(report error\): (.+)", log)
bound = re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)
lang = re.search(r"ghdl[^:]*:error: (.+)", log)
hung = re.search(r"simulation stopped (by --stop-time|@)", log)

if tot and int(tot.group(1)) == 0 and "PASS: tb_axi_rd_fsm" in log:
    print("SURV|0 errors across 2 acknowledgement latencies")
elif diag:
    print("KILL|%s" % diag.group(1).strip()[:56])
elif tot and int(tot.group(1)) != 0:
    print("KILL|%s errors, no named diagnostic" % tot.group(1))
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
echo " mutations of rtl/axi_rd_fsm.vhd, judged by sim/tb_axi_rd_fsm.vhd"
echo " KILL = the bench's address / MAXOUT / throttle / clear-order checkers"
echo " fired.  ABRT = ghdl stopped the run (a kill, worth less)."
echo "======================================================================="
echo
echo "---- class AR: address arithmetic and burst length --------------------"

mutate A1 AR "a full burst is MAXB-1 beats, so the bursts no longer tile the sub-region" \
"          if ar_left > MAXB then want := MAXB; else want := ar_left; end if;" \
"          if ar_left > MAXB then want := MAXB-1; else want := ar_left; end if;"

mutate A2 AR "the address advances by a FULL burst even when the burst was short" \
"            ar_addr <= ar_addr + to_unsigned(this_len * BYTES, ADDR_W);" \
"            ar_addr <= ar_addr + to_unsigned(MAXB * BYTES, ADDR_W);"

mutate A3 AR "the address advances in BEATS, not bytes -- the AXI_DW scaling is dropped" \
"            ar_addr <= ar_addr + to_unsigned(this_len * BYTES, ADDR_W);" \
"            ar_addr <= ar_addr + to_unsigned(this_len, ADDR_W);"

mutate A4 AR "the beats-remaining counter is decremented by a full burst" \
"            ar_left <= ar_left - this_len;" \
"            ar_left <= ar_left - MAXB;"

mutate A5 AR "arlen carries the beat count itself, not count-1" \
"  arlen   <= std_logic_vector(to_unsigned(this_len - 1, 8));" \
"  arlen   <= std_logic_vector(to_unsigned(this_len, 8));"

mutate A6 AR "the AR guard admits ar_left = 0, so a zero-beat burst is issued" \
"        elsif st = S_RUN and ar_left > 0 and os < MAXOUT then" \
"        elsif st = S_RUN and ar_left >= 0 and os < MAXOUT then"

mutate A7 AR "AR issue is no longer gated on S_RUN, so the port asks for beats while it is draining" \
"        elsif st = S_RUN and ar_left > 0 and os < MAXOUT then" \
"        elsif ar_left > 0 and os < MAXOUT then"

echo
echo "---- class THR: the two limits this FSM exists to enforce --------------"

mutate T1 THR "the throttle forgets beats ALREADY REQUESTED, which is the whole point of promised" \
"          if f_level + pr + want <= DEPTH then" \
"          if f_level + want <= DEPTH then"

mutate T2 THR "the throttle forgets the FIFO's own occupancy" \
"          if f_level + pr + want <= DEPTH then" \
"          if pr + want <= DEPTH then"

mutate T3 THR "the throttle is one whole burst too generous" \
"          if f_level + pr + want <= DEPTH then" \
"          if f_level + pr + want <= DEPTH + MAXB then"

mutate T4 THR "the throttle is one beat too CONSERVATIVE (expected to survive: it costs one slot and cannot overrun)" \
"          if f_level + pr + want <= DEPTH then" \
"          if f_level + pr + want < DEPTH then"

mutate T5 THR "the outstanding-burst limit is off by one, so MAXOUT+1 bursts are in flight" \
"        elsif st = S_RUN and ar_left > 0 and os < MAXOUT then" \
"        elsif st = S_RUN and ar_left > 0 and os <= MAXOUT then"

mutate T6 THR "an accepted burst no longer adds to promised" \
"            pr := pr + this_len;" \
"            pr := pr;"

mutate T7 THR "a retiring beat no longer removes its promise" \
"          if st = S_RUN then pr := pr - 1; end if;" \
"          if false then pr := pr - 1; end if;"

mutate T8 THR "the negative clamp on promised is removed -- the transient the header names is then written to a 0..DEPTH+MAXB signal" \
"        if pr < 0 then pr := 0; end if;      -- drained promises never go negative" \
"        null;"

mutate T9 THR "an accepted burst no longer counts as outstanding" \
"            os := os + 1;" \
"            os := os;"

mutate TA THR "a burst retires on EVERY beat, not on rlast" \
"          if rlast = '1' then os := os - 1; end if;" \
"          os := os - 1;"

echo
echo "---- class DRN: the drain that 7.7's flush rule is not sufficient without"

mutate D1 DRN "a start goes straight to S_RUN: no drain, no clear -- 7.7's flush alone, which the FSM's own comment calls necessary but NOT sufficient" \
"          st <= S_DRAIN;" \
"          st <= S_RUN;"

mutate D2 DRN "the drain ends without waiting for an AR already asserted to be accepted" \
"              if arv = '0' and os = 0 then" \
"              if os = 0 then"

mutate D3 DRN "the drain ends without waiting for outstanding bursts to return" \
"              if arv = '0' and os = 0 then" \
"              if arv = '0' then"

mutate D4 DRN "a start no longer stops the OLD job's AR issue (expected to survive: AR issue is gated on S_RUN and S_CLR2 reloads ar_left anyway)" \
"          ar_left <= 0;              -- issue nothing more for the old job" \
"          null;"

mutate D5 DRN "a start no longer zeroes promised (expected to survive for the same reason: S_CLR2 zeroes it again)" \
"          p_beats <= n_beats;
          ar_left <= 0;              -- issue nothing more for the old job
          pr := 0;" \
"          p_beats <= n_beats;
          ar_left <= 0;              -- issue nothing more for the old job"

echo
echo "---- class CLR: the four phases, and the order they must happen in ----"

mutate C1 CLR "S_CLR does not wait for the acknowledgement: phase 2 is skipped" \
"              if clr_done = '1' then
                clr_r <= '0';
                st    <= S_CLR2;" \
"              if true then
                clr_r <= '0';
                st    <= S_CLR2;"

mutate C2 CLR "S_CLR2 does not wait for clr_done to FALL: the port runs while the read side may still be parked" \
"              if clr_done = '0' then
                ar_addr <= unsigned(p_base);" \
"              if true then
                ar_addr <= unsigned(p_base);"

mutate C3 CLR "the clear request is never dropped, so phase 4 never happens" \
"                clr_r <= '0';
                st    <= S_CLR2;" \
"                st    <= S_CLR2;"

mutate C4 CLR "S_CLR2 forgets to reload the base address, so the new job reads the old one's" \
"                ar_addr <= unsigned(p_base);" \
"                null;"

mutate C5 CLR "S_CLR2 forgets to reload the beat count, so the new job asks for nothing" \
"                ar_left <= p_beats;" \
"                null;"

mutate C6 CLR "the job parameters are never latched at start, so every job runs the first one's base" \
"          p_base  <= base;
          p_beats <= n_beats;" \
"          null;"

mutate C7 CLR "the clear is requested from S_DRAIN but the state does not move, so the request is re-issued forever" \
"                clr_r <= '1';
                st    <= S_CLR;" \
"                clr_r <= '1';"

mutate AD PAIR "A7 AND D4 TOGETHER: AR issue is not gated on S_RUN *and* a start no longer stops the old job.  Each is unobservable ALONE (both survive above); the pair is not" \
"        elsif st = S_RUN and ar_left > 0 and os < MAXOUT then" \
"        elsif ar_left > 0 and os < MAXOUT then" \
"          ar_left <= 0;              -- issue nothing more for the old job" \
"          null;"

echo
echo "---- class RST: what the FSM comes out of reset as ---------------------"

mutate R1 RST "reset enters S_CLR instead of S_IDLE -- exactly what the RTL comment says would run the port into S_RUN before any job was programmed" \
"        st <= S_IDLE;" \
"        st <= S_CLR;"

mutate R2 RST "reset leaves arv set, so an AR is offered out of reset with no job" \
"        ar_left <= 0; promised <= 0; outst <= 0; arv <= '0';" \
"        ar_left <= 0; promised <= 0; outst <= 0; arv <= '1';"

mutate R3 RST "reset enters S_CLR *with the request already asserted*, which is the scenario the RTL comment describes -- unlike R1, this one really does reach S_RUN with no job" \
"        st <= S_IDLE;
        ar_left <= 0; promised <= 0; outst <= 0; arv <= '0';
        clr_r <= '0';" \
"        st <= S_CLR;
        ar_left <= 0; promised <= 0; outst <= 0; arv <= '0';
        clr_r <= '1';"

echo
echo "======================================================================="
printf 'kill ratio: %d KILLED + %d ABORT = %d of %d;  %d SURVIVED\n' \
  "$NKILL" "$NABORT" "$((NKILL+NABORT))" "$NTOT" "$NSURV"
[ -n "$SURV_TAGS" ] && echo "survivors:$SURV_TAGS"
echo "scratch dir with every mutant and its log: $SCRATCH"
