#!/usr/bin/env bash
# Mutation test for rtl/attn_kv_axi.vhd.  Same discipline as
# sim/mutate_attn_emit.sh: every mutation is well-formed VHDL and in bounds, so
# a KILL is the checker noticing and not the language noticing, and a SURVIVOR
# is investigated by READING the code rather than assumed equivalent.
#
# Every mutation is of the ARCHITECTURE BODY.  A mutation of a generic DEFAULT
# tests nothing, because sim/tb_attn_kv_axi.vhd passes HEAD_DIM, KV_BLOCK,
# N_KVH, LAYERS, MAXCTX, AXI_DW, MAXB, MAXOUT and RBUF explicitly to both
# harness instances.
#
# The two harness instances differ in AXI_DW and RBUF, and they reach different
# mechanisms (see sim/kv_axi_harness.vhd's header), so a mutation that survives
# in one and dies in the other is REPORTED THAT WAY rather than averaged.  The
# bench runs both and fails if either fails, so the granularity here is the
# whole bench; the per-instance TAG in the failure line says which one bit.
#
# Usage:  bash sim/mutate_attn_kv_axi.sh
# Env:    SCRATCH=<dir>  VECS=<vector file>
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
SRC=rtl/attn_kv_axi.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_kv_axi_vec.txt}"
mkdir -p "$SCRATCH"

if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_kv_axi_vec" ref/attn_kv_axi_vec.c || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_kv_axi_vec" \
      "$(basename "$VECS")" ) || exit 2
fi

# The longest legitimate run is 13.4 us.  --stop-time is 3 ms, a 220x margin:
# a mutation that HANGS runs to the stop time, and the bench's own residency
# watchdog (100,000 cycles = 1 ms) fires first in every hang seen so far, so a
# larger stop time buys nothing and is paid for by every hung run.
STOP=3ms

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_kv_axi.vhd" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then echo "$tag: ANCHOR FAILED   -- $desc"; return; fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" rtl/util_pkg.vhd >/dev/null 2>&1
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_kv_axi.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)   -- $desc"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/kv_axi_harness.vhd \
       sim/tb_attn_kv_axi.vhd >/dev/null 2>&1
  ( cd "$dir" && ln -sf "$(cd "$(dirname "$VECS")" && pwd)/$(basename "$VECS")" \
        attn_kv_axi_vec.txt )
  ( cd "$dir" && ghdl -r --std=08 -frelaxed --workdir=. tb_attn_kv_axi \
        --max-stack-alloc=0 --stop-time="$STOP" > run.log 2>&1 )
  local rcv=$?
  local v
  # sim/kv_axi_harness.vhd is named as a SECOND checker file, and it is not
  # optional: sim/tb_attn_kv_axi.vhd is a verdict wrapper and every protocol
  # check -- the AXI3 burst cap, the 4 KB rule, beat alignment, the
  # burst-completion rule, the sub-region bound, the write strobes -- asserts
  # from inside the harness.  Without this, 13 of the 28 rows below read
  # ABORT:DUTASSERT when the assert that fired belonged to the checker.
  v=$(python3 "$MUTV" "$dir/run.log" tb_attn_kv_axi "$rcv" kv_axi_harness)
  case "$v" in
    PASS)
      NSURV=$((NSURV+1))
      echo "$tag  SURVIVED   -- $desc" ;;
    KILLED)
      NKILL=$((NKILL+1))
      echo "$tag  KILLED     -- $desc"
      grep -vE "metavalue" "$dir/run.log" \
        | grep -E "MISMATCH|assertion|report error|ABANDONED|CROSSES|AXI3|WITHDREW|never|vacuous|HIGH while" \
        | head -1 | sed 's/^/        /' | cut -c1-190 ;;
    *)
      NABORT=$((NABORT+1))
      echo "$tag  ABORT (${v#ABORT:})   -- $desc"
      echo "        the run DIED before the checker reached a verdict, so the"
      echo "        checker was NOT shown to catch this.  Not counted as a kill."
      tail -2 "$dir/run.log" | sed 's/^/        /' | cut -c1-190 ;;
  esac
}

echo "==================== mutations of attn_kv_axi ===================="
echo "golden: $VECS"

# ---- address generation, C spec 2.2 ---------------------------------------
# ---- THE CONTROL, run BEFORE any mutation ---------------------------------
# A mutation table read against a bench that fails on the CLEAN design measures
# nothing.  This harness had no control row; sim/mutate_attn_emit.sh had none
# either and MEASURED 2026-08-29 its config B wedges on the unmutated design,
# so every "kill" in that column was unearned.  The control goes through the
# SAME mutate() path as every other row, with the substitution deliberately an
# identity, so it exercises the same analyze, the same generics and the same
# classifier.  SURVIVED is its correct answer.
mutate CTL "CONTROL: the UNMUTATED design.  Must say SURVIVED" \
"entity attn_kv_axi is" \
"entity attn_kv_axi is"

mutate A1 "the LAYER term is dropped from the record index" \
"    idx := (lay*N_KVH + hd)*MAXCTX + ps;" \
"    idx := hd*MAXCTX + ps;"

mutate A2 "layer and kv_head are transposed in the record index" \
"    idx := (lay*N_KVH + hd)*MAXCTX + ps;" \
"    idx := (hd*LAYERS + lay)*MAXCTX + ps;"

mutate A3 "the record stride drops the 16-byte header (272 -> 256)" \
"    idx := (lay*N_KVH + hd)*MAXCTX + ps;
    return unsigned(base) + to_unsigned(idx*REC_B, ADDR_W);" \
"    idx := (lay*N_KVH + hd)*MAXCTX + ps;
    return unsigned(base) + to_unsigned(idx*MANT_B, ADDR_W);"

mutate A4 "the K and V read bases are swapped" \
"              if s = 0 then base := kb_r; else base := vb_r; end if;" \
"              if s = 0 then base := vb_r; else base := kb_r; end if;"

mutate A5 "the WRITE picks its base from the head instead of from K|V" \
"              if wb_sel = '0' then base := kb_r; else base := vb_r; end if;" \
"              if wb_hd = 0 then base := kb_r; else base := vb_r; end if;"

# ---- burst splitting, section 4 -------------------------------------------
mutate B1 "the AXI3 16-beat cap is removed (AXI4's 4 KB rule only)" \
"    if n > MAXB then n := MAXB; end if;" \
"    if n > 128 then n := 128; end if;"

mutate B2 "the 4 KB boundary split is removed" \
"    if n > to4k then n := to4k; end if;" \
"    null;"

mutate B3 "the 4 KB distance is one beat too long" \
"    to4k := (4096 - (to_integer(a) mod 4096))/BEAT_B;" \
"    to4k := (4096 - (to_integer(a) mod 4096))/BEAT_B + 1;"

mutate B4 "the cap is off by one: MAXB+1 beats per burst" \
"    if n > MAXB then n := MAXB; end if;" \
"    if n > MAXB+1 then n := MAXB+1; end if;"

# ---- the 16-byte record phase, section 5 ----------------------------------
mutate P1 "the record phase is forced to zero (no realignment)" \
"              ph_ch   <= (to_integer(a0) mod BEAT_B)/CH_B;" \
"              ph_ch   <= 0;"

mutate P2 "the AR is issued at the record address, not beat-aligned below it" \
"              ar_addr <= a0 - to_unsigned(to_integer(a0) mod BEAT_B, ADDR_W);" \
"              ar_addr <= a0;"

mutate P3 "the phase is ADDED to the chunk index instead of subtracted" \
"              kk   := r_beat*BEAT_CH + c - ph_ch;" \
"              kk   := r_beat*BEAT_CH + c + ph_ch;"

# ---- beat and chunk ordering ----------------------------------------------
mutate O1 "the chunk lanes within a beat are reversed" \
"              kk   := r_beat*BEAT_CH + c - ph_ch;
              lane := r_rdata(s*AXI_DW + (c+1)*CH_W-1
                              downto s*AXI_DW + c*CH_W);" \
"              kk   := r_beat*BEAT_CH + (BEAT_CH-1-c) - ph_ch;
              lane := r_rdata(s*AXI_DW + (c+1)*CH_W-1
                              downto s*AXI_DW + c*CH_W);"

mutate O2 "the beat counter advances by one record's worth, not one beat" \
"            r_beat <= r_beat + 1;" \
"            r_beat <= r_beat + BEAT_CH;"

# O3/O4 RE-ANCHORED 2026-09-07, when `recbuf` was split into MPB mantissa
# banks plus a small header register file to remove a 68-way multiplexer worth
# 48,388 LUT.  BOTH ANCHORS SILENTLY STOPPED MATCHING and the script reported
# them as "never ran (anchor failure)" -- the RTL change had disabled two of
# this block's own mutations without failing anything.  That is the hazard of
# anchoring a mutation on source TEXT, and the only tell is the never-ran
# count, which is easy to read past because the surviving rows all still pass.
#
# O3 keeps its INTENT -- the mantissa read reaching the wrong chunk -- in the
# form the banked code can express.  The old "+1" no longer exists, because
# the banking absorbed it, so the analogous defect is the two mantissa chunks
# arriving from swapped banks.  MPB-1-c is in bounds by construction.
mutate O3 "the mantissa chunks are read from swapped banks" \
"                <= mbank(c)(hit_slot*NBLK + to_integer(q_blk(s)));" \
"                <= mbank(MPB-1-c)(hit_slot*NBLK + to_integer(q_blk(s)));"

mutate O4 "the header is always read out of slot 0" \
"            q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0);" \
"            q_hdr(s) <= hdr_r(0)(NBLK*EXP_W-1 downto 0);"

# ---- partially filled records and the slot window -------------------------
mutate W1 "residency is declared on the FIRST chunk of a record, not the last" \
"                  elsif mm = CPR-1 then" \
"                  elsif mm = 0 then"

mutate W2 "the straddle headroom is removed (the defect this design had)" \
"              lim_rec := c_max + RBUF - 2;" \
"              lim_rec := c_max + RBUF - 1;"

mutate W3 "the fetch window ignores the consumer and runs the whole context" \
"              lim_rec := c_max + RBUF - 2;" \
"              lim_rec := to_integer(cpos_r) - 1 - to_integer(run_p0);"

mutate W4 "the capture accepts chunks of the CURRENT position's record" \
"                if rr <= c_max + RBUF - 1
                   and (to_integer(run_p0) + rr) < to_integer(cpos_r) then" \
"                if rr <= c_max + RBUF - 1 then"

# ---- the write path -------------------------------------------------------
mutate V1 "WSTRB is full on every beat (the record's neighbours are clobbered)" \
"        if bidx >= 0 and bidx < REC_B then
          w_wstrb(b) <= '1';
        else
          w_wstrb(b) <= '0';
        end if;" \
"        w_wstrb(b) <= '1';"

mutate V2 "the write ignores the record phase when placing bytes" \
"        bidx := bi*BEAT_B + b - phase;" \
"        bidx := bi*BEAT_B + b;"

mutate V3 "AW is issued as soon as the HEADER lands, not the whole record" \
"            if wb_full = '1' and err_w = '0' then" \
"            if wb_hgot = '1' and err_w = '0' then"

mutate V4 "wr_idle ignores the outstanding write count (no BRESP gate)" \
"  wr_idle   <= '1' when (w_outst = 0 and wb_full = '0' and wb_hgot = '0'" \
"  wr_idle   <= '1' when (wb_full = '0' and wb_hgot = '0'"

# ---- the drain rule, section 7 --------------------------------------------
mutate D1 "RREADY is gated on the flush (an accepted burst is stalled)" \
"  r_rready <= \"11\";" \
"  r_rready <= \"11\" when flushing = '0' else \"00\";"

mutate D2 "ARVALID is withdrawn when a flush starts" \
"          if flushing = '1' then
            if outst + dout = 0 and arv = '0' then" \
"          if flushing = '1' then
            arv <= '0';
            if outst + dout = 0 and arv = '0' then"

mutate D3 "the flush completes without waiting for the drain" \
"          if flushing = '1' then
            if outst + dout = 0 and arv = '0' then
              sv <= (others => '0'); run_v <= '0'; halted <= '0';" \
"          if flushing = '1' then
            if true then
              sv <= (others => '0'); run_v <= '0'; halted <= '0';"

mutate D4 "the job latches its new geometry before the engines are quiet" \
"        elsif flushing = '1' and rd_quiet = \"11\" and wr_quiet = '1' then" \
"        elsif flushing = '1' then"

echo "=================================================================="
cat <<'NOTE'

THE TWO SURVIVORS, READ RATHER THAN ASSUMED.  Both are EQUIVALENT MUTANTS in
this design, and each one names a piece of belt-and-braces that a future change
would make load-bearing.  Neither is a hole in the checker.

W4  "the capture accepts chunks of the CURRENT position's record"
    The capture guard `(run_p0 + rr) < cpos_r` is redundant GIVEN the issue-side
    cap `lim_rec <= cpos_r - 1 - run_p0`.  With that cap in place, the only
    chunk of the cur_pos record that can ever arrive is the straddle chunk at
    the very end of the run, and it lands in the slot of an already-consumed
    record with `mm = 0`, so `sv` for that slot stays low and nothing is ever
    served from it.  The consumer also never asks for cur_pos (`oor` refuses
    it).  So the mutant is observationally identical.
    WHAT IT PROVES THE CHECK CANNOT SEE: that the two bounds are independent.
    Remove the ISSUE-side cap and the capture guard becomes the only thing
    stopping a read of the record this job is writing -- W3 is the mutation
    that does exactly that, and W3 IS killed.

D3  "the flush completes without waiting for the drain"
    Clearing `sv` / `run_v` / the beat counters immediately on `flushing`
    instead of at `outst = 0` is invisible because the CAPTURE is separately
    gated on `flushing = '0'`, so an in-flight beat cannot be written into a
    slot during a flush however early the slot was cleared, and `rd_quiet` --
    which is what P_JOB actually waits on -- is computed from `outst` and `arv`
    directly rather than from this branch.
    WHAT IT PROVES THE CHECK CANNOT SEE: that the drain and the capture gate
    are two independent defences of the same property.  D4 removes the P_JOB
    side and IS killed; D1 and D2 remove the protocol side and ARE killed.
NOTE

echo
echo "--------------------------------------------------------------------"
echo "verdicts: $NKILL killed by the checker, $NABORT aborted before the"
echo "  checker reached a verdict, $NSURV survived, of $NTOT attempted."
echo "  An ABORT is NOT a kill: the run died and the checker never spoke."
echo "  $(( NTOT - NKILL - NABORT - NSURV )) mutation(s) never ran at all"
echo "  (anchor failure or did-not-analyze); those are printed above."
