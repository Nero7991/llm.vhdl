#!/usr/bin/env bash
# Mutation test for the attn_block <-> attn_kv_axi SEAM.
#
# The thing under test is not a file, it is the CONTRACT between two files, so
# the mutations come in two flavours and both are here on purpose:
#
#   Sx  a GENERIC on sim/tb_attn_kv_seam.vhd that perturbs the wires between
#       the two units -- a residency answer forced high, withdrawn mid-record,
#       or a request quietly aimed at the neighbouring record.  These are
#       mutations OF THE SEAM and they cannot be expressed as an edit to
#       either file, because neither file contains the seam.
#   Rx  a textual mutation of a scratch copy of rtl/attn_block.vhd, the way
#       every other mutate_*.sh in this tree works.  These test the half of
#       the fix that lives in the block: the gate, and the request being
#       driven a state earlier than the issue.
#   Lx  the LAYER dimension, added 2026-08-29 with the interleaved schedule.
#       NOTE the tags Ln here and the PROPERTY tags LPn in the header of
#       sim/tb_attn_kv_seam.vhd are different lists and do not line up.
#       Mixed flavour: L2/L3 are seam wires, L1/L6 edit the block and L4/L5
#       edit the cache.  EVERY ONE of them is bit-exact green on the
#       single-layer stream this bench ran until then -- MEASURED for L1, the
#       restored defect C1, which the pre-change bench passes while reporting
#       "BIT-EXACT ... 1028 output values".  They are grouped because what
#       they have in common is not where they live but what makes them
#       visible.
#
# Same discipline as sim/mutate_attn_kv_axi.sh: every mutation is well-formed
# VHDL and in bounds, so a KILL is the checker noticing and not the language
# noticing, and a SURVIVOR is investigated by READING the code rather than
# assumed equivalent.  A hang is reported as a hang and NOT as a kill of the
# same weight as a value mismatch, because a bench that only ever hangs on a
# defect class has not been shown to be able to SEE that class.
#
# Usage:  bash sim/mutate_attn_kv_seam.sh
# Env:    SCRATCH=<dir>
set -uo pipefail

# ---------------------------------------------------------------------------
# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it runs, so editing
# this file while an instance of it is running corrupts that run silently.
# Several agents share this repo and the one who gets hit is not the one who
# edited the file.  So take a private copy, refuse it if it does not parse
# (which is what a half-written source looks like), and re-exec that.  Same
# guard, same reasons, as sim/regress.sh:307.  MUT_NO_REEXEC=1 disables it.
if [ -z "${MUT_REPO:-}" ]; then
  MUT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUT_REPO
fi
if [ -z "${MUT_SELF:-}" ] && [ -z "${MUT_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutself.XXXXXXXX.sh)" || exit 2
  if ! cat "${BASH_SOURCE[0]}" > "$_self"; then
    rm -f "$_self"; echo "could not take a private copy" >&2; exit 2
  fi
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "the private copy does not parse -- this script was probably being" >&2
    echo "  written at the instant it was copied.  Try again." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUT_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi
trap 'if [ -n "${MUT_SELF:-}" ]; then rm -f "$MUT_SELF"; fi' EXIT

# THREE VERDICTS, NOT TWO.  This harness used to judge a mutation with
#   ghdl -r ... && grep -q PASS
# under which a run that DIED -- an elaboration error, a language bound check,
# the DUT's own assert, a wedge to --stop-time -- scored as a KILL even though
# the checker never ran.  sim/mutverdict.py separates the two: KILLED means the
# CHECKER noticed and said so, ABORT means the run never reached a verdict the
# checker owns.  An ABORT is reported under its own name and counted apart.
# Read the header of sim/mutverdict.py for the full rule.
MUTV="$MUT_REPO/sim/mutverdict.py"
NKILL=0; NABORT=0; NSURV=0; NTOT=0
cd "$MUT_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
VECARGS="64 4 2 16 16 4 2 2"   # ... NTOK NLAY SEED; NLAY=2 is load bearing

FILES="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
       rtl/attn_emit.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd
       rtl/attn_mac_array.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
       rtl/attn_softmax.vhd rtl/divider_rs.vhd rtl/imrope_pkg.vhd
       rtl/rmsnorm_rs.vhd rtl/attn_recip.vhd rtl/attn_twiddle.vhd
       rtl/attn_kv_axi.vhd rtl/attn_block.vhd sim/tb_attn_kv_seam.vhd"

# The clean run is 458 us -- it was 229 us until 2026-08-29, when the schedule
# gained a second interleaved LAYER and so twice the jobs.  --stop-time 40 ms
# keeps the same 87x margin the 20 ms figure bought at the old length; the
# bench's own WDOG (20,000 cycles of dead air, against a measured worst
# legitimate stretch of 2,137) fires long before that in every stall seen so
# far, so a larger stop time buys nothing and every hung run pays for it.
# The rows that raise RD_LAT to 2000 or AW_LAT to 4000 are the ones this
# actually protects: doubling the job count doubled their sim time too.
STOP=40ms

cc -O2 -w -I ref -o "$SCRATCH/genseq" ref/attn_block_seq_vec.c -lm || exit 2

# ---------------------------------------------------------------------------
# run <tag> <desc> <extra-ghdl-args...>   -- with an optional mutated RTL dir
# ---------------------------------------------------------------------------
# NOTE: run_case's exit status is meaningless (it ends in a grep that finds
# nothing on a clean kill), so it is NEVER used on the left of `&&` or `||`.
# Doing that printed a spurious "R1 ANCHOR FAILED" after a correct KILL.
run_case() {
  local tag="$1" desc="$2" mutdir="$3"; shift 3
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir/run"
  ( cd "$dir/run" && "$SCRATCH/genseq" attn_block_seq_vec.txt $VECARGS ) \
      >/dev/null 2>&1 || { echo "$tag  VECGEN FAILED"; return; }
  local f src
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)   -- $desc"
      sed -n 1,4p "$dir/analyze.log"; return
    fi
  done
  ( cd "$dir/run" && timeout -k 5 900 ghdl -r --std=08 -frelaxed \
      --workdir=.. tb_attn_kv_seam "$@" --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  local rcv=$?
  local v
  v=$(python3 "$MUTV" "$dir/run/run.log" tb_attn_kv_seam "$rcv")
  # The HANG row is kept and is NOT folded into ABORT.  It is the BENCH's own
  # residency watchdog firing, at severity failure, from sim/tb_attn_kv_seam.vhd
  # -- the checker noticing, not the run dying underneath it.  mutverdict.py
  # classifies it KILLED for exactly that reason (the diagnostic's source file
  # is the testbench); the extra grep here only says WHICH check bit.
  if [ "$v" = PASS ]; then
    NSURV=$((NSURV+1))
    echo "$tag  SURVIVED   -- $desc"
  elif [ "$v" = KILLED ] \
       && grep -q "cycles with the block busy" "$dir/run/run.log"; then
    NKILL=$((NKILL+1))
    echo "$tag  KILLED(HANG) -- $desc"
    grep -vE "metavalue" "$dir/run/run.log" | grep -E "seam is stalled|WDOG" \
      | head -1 | sed 's/^/        /' | cut -c1-170
  elif [ "$v" = KILLED ]; then
    NKILL=$((NKILL+1))
    echo "$tag  KILLED     -- $desc"
    grep -vE "metavalue" "$dir/run/run.log" \
      | grep -E "MISMATCH|Q1 --|Q2 --|Q5 --|Q8 --|sweep read pos|kr_en was|vr_en was|record write beat|beat \(head|was read|RESULT bad" \
      | head -1 | sed 's/^/        /' | cut -c1-170
  else
    NABORT=$((NABORT+1))
    echo "$tag  ABORT (${v#ABORT:})   -- $desc"
    echo "        the run DIED before the checker reached a verdict, so the"
    echo "        checker was NOT shown to catch this.  Not counted as a kill."
    tail -2 "$dir/run/run.log" | sed 's/^/        /' | cut -c1-170
  fi
}

# ---------------------------------------------------------------------------
# mutate_rtl <tag> <file> <old> <new>   -- writes a scratch copy, echoes its dir
# ---------------------------------------------------------------------------
mutate_rtl() {
  local tag="$1" file="$2" old="$3" new="$4"
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$file" "$dir/$(basename "$file")" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then echo ""; return; fi
  echo "$dir"
}

# ---------------------------------------------------------------------------
# mutate_rtl2 <tag> <file> <old1> <new1> <old2> <new2>   -- two edits, one file
# ---------------------------------------------------------------------------
mutate_rtl2() {
  local tag="$1" file="$2" o1="$3" n1="$4" o2="$5" n2="$6"
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$file" "$dir/$(basename "$file")" "$o1" "$n1" "$o2" "$n2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
for i in (3, 5):
    old, new = sys.argv[i], sys.argv[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("MUTATION ANCHOR %d MATCHED %d TIMES, expected 1\n"
                         % (i, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
  if [ $? -ne 0 ]; then echo ""; return; fi
  echo "$dir"
}

# ---------------------------------------------------------------------------
# add_mut <dir> <file> <old> <new>   -- one more mutation INTO an existing dir,
# so several files can be mutated together for one run.
# ---------------------------------------------------------------------------
add_mut() {
  local dir="$1" file="$2" old="$3" new="$4"
  local base; base="$(basename "$file")"
  local src="$file"
  [ -r "$dir/$base" ] && src="$dir/$base"
  python3 - "$src" "$dir/$base" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
}

# ---------------------------------------------------------------------------
# mutate_rtl_n <tag> <file> <count> <old> <new>   -- like mutate_rtl, but the
# anchor is expected EXACTLY <count> times and every one is replaced.
# ---------------------------------------------------------------------------
# Needed because defect C1 is not a single site: `attn_block` indexes its
# v_ref fold at FOUR places, and a mutation that removed the layer term from
# only one of them would be a design neither correct nor the defect, so a kill
# would say nothing about whether the bench can see C1.  The count is required
# rather than "replace all" so that a future edit which adds or removes a site
# turns this into a loud anchor failure instead of a quietly partial mutation.
mutate_rtl_n() {
  local tag="$1" file="$2" cnt="$3" old="$4" new="$5"
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$file" "$dir/$(basename "$file")" "$cnt" "$old" "$new" <<'PY'
import sys
src, dst, cnt, old, new = (sys.argv[1], sys.argv[2], int(sys.argv[3]),
                           sys.argv[4], sys.argv[5])
s = open(src).read()
n = s.count(old)
if n != cnt:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected %d\n"
                     % (n, cnt))
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then echo ""; return; fi
  echo "$dir"
}

echo "============ mutations of the attn_block <-> attn_kv_axi seam ============"

# ---- the seam wires -------------------------------------------------------
run_case S1 "kr_rdy ignored: the block issues a beat whether or not the record is resident.  This IS the pre-seam design." "" -gMUT_EARLY_BEAT=true
run_case S2 "kr_rdy withdrawn in the middle of a record instead of being held" "" -gMUT_DROP_RDY=true
run_case S3 "the cache is asked for the NEXT POSITION's record, when that one is also readable" "" -gMUT_REORDER=true
run_case S4 "the cache is asked for the neighbouring BLOCK inside the record" "" -gMUT_BLK_SWAP=true
run_case S5 "done is not gated on the write master's BRESP (C spec 2.7)" "" -gMUT_NO_WRIDLE=true
run_case S6 "v_ref is reset per TOKEN instead of per SEQUENCE (C spec 2.1.4)" "" -gMUT_SEQRST_TOK=true

# ---- the block's half of the fix ------------------------------------------
D=$(mutate_rtl R1 rtl/attn_block.vhd \
"            elsif blk < NBLK then
              if kr_rdy = '1' then
                kr_en   <= '1';" \
"            elsif blk < NBLK then
              if true then
                kr_en   <= '1';")
if [ -n "$D" ]; then run_case R1 "the kr_rdy gate removed from P_RECK in the RTL (S1 done as an edit rather than a wire)" "$D"
else echo "R1  ANCHOR FAILED"; fi

D=$(mutate_rtl R2 rtl/attn_block.vhd \
"            elsif blk < NBLK then
              if vr_rdy = '1' then
                vr_en   <= '1';" \
"            elsif blk < NBLK then
              if true then
                vr_en   <= '1';")
if [ -n "$D" ]; then run_case R2 "the vr_rdy gate removed from P_RECV" "$D"
else echo "R2  ANCHOR FAILED"; fi

# The OTHER half of the fix, isolated.  The gate STAYS; only the request moves
# back inside the issue cycle, exactly where it was before 2026-08-28.  A
# residency answer is only meaningful about a question that is already being
# asked, and this is the mutation that says whether that sentence is load
# bearing or decorative.
D=$(mutate_rtl2 R3 rtl/attn_block.vhd \
"  kr_head <= to_unsigned(kvh, AW_H);
  kr_pos  <= pos_i;
  vr_head <= to_unsigned(kvh, AW_H);" \
"  vr_head <= to_unsigned(kvh, AW_H);" \
"              if kr_rdy = '1' then
                kr_en   <= '1';
                kr_blk  <= to_unsigned(blk, AW_B);" \
"              if kr_rdy = '1' then
                kr_en   <= '1';
                kr_head <= to_unsigned(kvh, AW_H);
                kr_pos  <= pos_i;
                kr_blk  <= to_unsigned(blk, AW_B);")
if [ -n "$D" ]; then run_case R3 "the K request driven from the ISSUE cycle again, with the kr_rdy gate left in place" "$D"
else echo "R3  ANCHOR FAILED"; fi

D=$(mutate_rtl R4 rtl/attn_block.vhd \
"            if kv_wr_idle = '1' then
              done_r <= '1';" \
"            if true then
              done_r <= '1';")
if [ -n "$D" ]; then run_case R4 "the kv_wr_idle gate removed from P_DONE in the RTL (S5 as an edit)" "$D"
else echo "R4  ANCHOR FAILED"; fi

# The bypass, at the seam.  C-ORACLE's m14 was invisible to its value oracle
# and caught only by the address property; here the cache REFUSES the read, so
# the outcome is different in kind and is reported as such.
D=$(mutate_rtl R5 rtl/attn_block.vhd \
"          when P_RECK =>
            if is_byp = '1' then
              krec <= kbyp;
              khdr <= kbh;
              ph <= P_HDR;" \
"          when P_RECK =>
            if is_byp = '1' and false then
              krec <= kbyp;
              khdr <= kbh;
              ph <= P_HDR;")
if [ -n "$D" ]; then run_case R5 "the K bypass removed: the sweep asks the cache for cur_pos (C spec 2.4)" "$D"
else echo "R5  ANCHOR FAILED"; fi

# ---- the cache's half -----------------------------------------------------
# R5 hangs because the CACHE refuses cur_pos, and a hang is a weaker result
# than a wrong answer.  R5b removes the block's bypass AND hands the cache a
# cur_pos one larger, so the refusal no longer covers that record and the read
# is SERVED -- from memory this job wrote earlier in the same job, i.e. with
# the RIGHT VALUES.  That is C-ORACLE's m14 reproduced at the seam: invisible
# to a value oracle, and caught only by the property stated over the ADDRESSES.
D=$(mutate_rtl R5b rtl/attn_block.vhd \
"          when P_RECK =>
            if is_byp = '1' then
              krec <= kbyp;
              khdr <= kbh;
              ph <= P_HDR;" \
"          when P_RECK =>
            if is_byp = '1' and false then
              krec <= kbyp;
              khdr <= kbh;
              ph <= P_HDR;")
if [ -n "$D" ]; then run_case R5b "the K bypass removed AND the cache told cur_pos is readable, so the read is SERVED with the right values" "$D" -gMUT_CACHE_CPOS_HI=true
else echo "R5b  ANCHOR FAILED"; fi

D=$(mutate_rtl R6 rtl/attn_kv_axi.vhd \
"    q_rdy(s) <= hit and (not flushing) and (not oor);" \
"    q_rdy(s) <= hit and (not flushing);")
if [ -n "$D" ]; then run_case R6 "attn_kv_axi stops refusing pos >= cur_pos" "$D"
else echo "R6  ANCHOR FAILED"; fi

D=$(mutate_rtl R7 rtl/attn_kv_axi.vhd \
"  kw_rdy    <= '1' when (wb_full = '0' and flushing = '0') else '0';" \
"  kw_rdy    <= '1' when (wb_full = '0') else '0';")
if [ -n "$D" ]; then run_case R7 "kw_rdy stops covering the flush, so a record written during drain-then-flush is dropped" "$D"
else echo "R7  ANCHOR FAILED"; fi
if [ -n "$D" ]; then run_case R7b "the same, with the read latency raised to 2000 so the flush outlasts the block's prologue" "$D" -gRD_LAT=2000 -gWDOG=200000; fi

# R7c removes kw_rdy ENTIRELY, both terms.  R7 only removed the flush term; the
# other one says the record buffer is free, and whether THAT is load bearing is
# a question about the block's write schedule, not about the flush.
D=$(mutate_rtl R7c rtl/attn_kv_axi.vhd \
"  kw_rdy    <= '1' when (wb_full = '0' and flushing = '0') else '0';" \
"  kw_rdy    <= '1';")
if [ -n "$D" ]; then run_case R7c "kw_rdy tied high: neither the record buffer nor the flush holds the writer off" "$D"
else echo "R7c  ANCHOR FAILED"; fi
if [ -n "$D" ]; then run_case R7d "the same, with the write slave refusing AW for 4000 cycles so the record buffer really does back up" "$D" -gAW_LAT=4000 -gWDOG=200000; fi

# ---- the LAYER dimension.  Every row below is bit-exact green on the
# ---- single-layer stream this bench ran until 2026-08-29, so each one
# ---- measures the interleaved schedule and nothing else.
run_case L2 "the CACHE is configured for layer 0 while the block runs the schedule's layer: the two masters agree with each other and disagree with the block" "" -gMUT_KV_LAY0=true
run_case L3 "the BLOCK is run at layer 0 while the cache is configured for the schedule's layer" "" -gMUT_BLK_LAY0=true

# DEFECT C1 ITSELF, put back.  rtl/attn_block.vhd holds ONE v_ref fold array
# and time-shares it across every attention layer; indexing it by head alone
# lets each layer's write-time minimum leak into every other layer's alignment
# shift.  Four sites, mutated together -- see mutate_rtl_n.
D=$(mutate_rtl_n L1a rtl/attn_block.vhd 3 \
    'vref_r(lay_r*N_KVH + kvh)' 'vref_r(kvh)')
if [ -n "$D" ]; then
  add_mut "$D" rtl/attn_block.vhd 'vref_r(lay_r*N_KVH + h)' 'vref_r(h)'
  run_case L1 "defect C1 restored: the v_ref fold indexed by KV HEAD ALONE, with no layer term, at all four sites" "$D"
else echo "L1 ANCHOR FAILED"; NTOT=$((NTOT+1)); fi

# The address equation's layer term, in the CACHE, where both masters share
# it.  L4 drops it; L5 keeps it and mirrors the layer.  L5 is the one that
# only Q2 can catch: every read is served, every returned beat matches the
# record the bench asked for, and the records are simply in the wrong region.
D=$(mutate_rtl L4 rtl/attn_kv_axi.vhd \
    'idx := (lay*N_KVH + hd)*MAXCTX + ps;' \
    'idx := hd*MAXCTX + ps;')
if [ -n "$D" ]; then run_case L4 "the address equation's layer term DROPPED in attn_kv_axi, for both masters at once (C spec 2.2)" "$D"
else echo "L4 ANCHOR FAILED"; NTOT=$((NTOT+1)); fi

D=$(mutate_rtl L5 rtl/attn_kv_axi.vhd \
    'lay_r    <= layer;' \
    'lay_r    <= LAYERS-1-layer;')
if [ -n "$D" ]; then run_case L5 "attn_kv_axi MIRRORS the layer: both masters agree, every read is served, and every record is in the wrong layer's region" "$D"
else echo "L5 ANCHOR FAILED"; NTOT=$((NTOT+1)); fi

# L6 exists because L2..L5 all die on Q5 before Q8 is ever consulted, so
# without it Q8 would be a check never shown to fail.  This is the one shape
# Q8 owns: the block's records go to the right place, its own arithmetic is
# right, and only the layer ordinal it PUBLISHES is wrong -- which is exactly
# what rtl/llama_top.vhd's assert watches for, because a cache that believed
# it would put a whole layer's records at another layer's addresses and every
# read would still be served.
D=$(mutate_rtl L6 rtl/attn_block.vhd \
    'kv_layer    <= to_unsigned(lay_r, clog2(LAYERS));' \
    'kv_layer    <= to_unsigned(0, clog2(LAYERS));')
if [ -n "$D" ]; then run_case L6 "attn_block publishes kv_layer = 0 regardless of the layer it was configured for (Q8's own shape)" "$D"
else echo "L6 ANCHOR FAILED"; NTOT=$((NTOT+1)); fi

# L7 is the teeth check for the per-layer QK-norm weight AXIS itself, not for
# a defect.  If the bench had wired layer 0's weights to every job, L3 would
# still kill, the axis would be dead and nothing in this harness would say so.
run_case L7 "the block is handed the OTHER layer's QK-norm weights, everything else correct (does the per-layer weight axis reach the DUT at all?)" "" -gMUT_WN_SWAP=true

# ---- controls.  A mutation that is only killed under an unusual slave
# setting has proved nothing unless the CLEAN design passes under that same
# setting.  These three must all say SURVIVED, which for a control is the
# right word: the design survives, because there is nothing wrong with it.
run_case C1 "CONTROL: the clean design with the write slave refusing AW for 4000 cycles" "" -gAW_LAT=4000 -gWDOG=200000
run_case C2 "CONTROL: the clean design at 2000-cycle read latency" "" -gRD_LAT=2000 -gWDOG=200000
run_case C3 "CONTROL: the clean design at 4000-cycle BRESP latency" "" -gWR_LAT=4000 -gWDOG=200000
run_case C4 "CONTROL: the clean design with the cache told cur_pos is readable (R5b's other half, alone)" "" -gMUT_CACHE_CPOS_HI=true

# ---- C spec 2.7 again, at a BRESP latency that actually reaches `done` -----
run_case S5b "done not gated on BRESP, at a 4000-cycle BRESP latency" "" -gMUT_NO_WRIDLE=true -gWR_LAT=4000 -gWDOG=200000
D=$(mutate_rtl R4b rtl/attn_block.vhd \
"            if kv_wr_idle = '1' then
              done_r <= '1';" \
"            if true then
              done_r <= '1';")
if [ -n "$D" ]; then run_case R4b "the kv_wr_idle gate removed in the RTL, at a 4000-cycle BRESP latency" "$D" -gWR_LAT=4000 -gWDOG=200000
else echo "R4b  ANCHOR FAILED"; fi

echo
echo "--------------------------------------------------------------------"
echo "verdicts: $NKILL killed by the checker, $NABORT aborted before the"
echo "  checker reached a verdict, $NSURV survived, of $NTOT attempted."
echo "  An ABORT is NOT a kill: the run died and the checker never spoke."
echo "  Note the CONTROL rows C1..C4 are counted in NSURV, where SURVIVED is"
echo "  the correct answer: the clean design survives because it is clean."
echo "  $(( NTOT - NKILL - NABORT - NSURV )) row(s) never ran at all"
echo "  (anchor failure, vecgen failure or did-not-analyze); printed above."
echo "SCRATCH=$SCRATCH"
