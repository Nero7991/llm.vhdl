#!/usr/bin/env bash
# Mutation test for `rtl/fk33_seam.vhd`, the host seam in front of subsystem D.
# TRACK DSEAM, 2026-08-30.  Teeth for `sim/tb_fk33_seam.vhd`.
#
# WHAT IS BEING TESTED IS THE CHECKER, NOT THE DESIGN.  Every mutation below
# is well-formed VHDL and in bounds, so a KILL is the bench noticing and not
# the language noticing, and a SURVIVOR is investigated by READING rather than
# assumed equivalent.
#
# THREE VERDICTS, NOT TWO, via `sim/mutverdict.py`: KILLED means the CHECKER
# said so, ABORT means the run never reached a verdict the checker owns.  A
# mutation that makes the design refuse to elaborate has tested nothing.
#
# AND A FOURTH COLUMN, THE ATTRIBUTION CONTROL.  A kill does not settle it.
# For every KILLED row this script also asks whether the run produced a
# diagnostic that did NOT come from `sim/tb_fk33_seam.vhd` -- a DUT assertion,
# a `seq_region_lock` violation, a bound check.  If it did, the kill is
# credited to the PRE-EXISTING property and reported as `KILLED(PRIOR)`, not
# to anything this track added.  Measured 2026-08-29 elsewhere in this project:
# without that control a table credits its new check with detections an older
# property would have made anyway.
#
# THE ROWS THAT DO NOT BITE ARE REPORTED UNDER THEIR OWN NAMES AND ARE THE
# MOST VALUABLE LINE IN THE TABLE.  They measure the bench's resolution floor.
# Never delete one because it is not a kill.
#
# Usage:  bash sim/mutate_fk33_seam.sh
# Env:    SCRATCH=<dir>   ONLY=<tag prefix, e.g. M3>
set -uo pipefail

# ---------------------------------------------------------------------------
# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it runs, so editing
# this file while an instance of it is running corrupts that run silently.
# Several agents share this repo and the one who gets hit is not the one who
# edited it.  Same guard, same reasons, as sim/mutate_attn_kv_seam.sh:38.
if [ -z "${MUT_REPO:-}" ]; then
  MUT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUT_REPO
fi
if [ -z "${MUT_SELF:-}" ] && [ -z "${MUT_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutseam.XXXXXXXX.sh)" || exit 2
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

cd "$MUT_REPO" || exit 2
MUTV="$MUT_REPO/sim/mutverdict.py"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
ONLY="${ONLY:-}"
TB=tb_fk33_seam

# The analysis closure, taken from `sim/regress.sh`'s own planner output for
# this row (plan.tsv, field 5) rather than retyped, and in its order.
FILES="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
 rtl/model_cfg_pkg.vhd rtl/act_mem_striped.vhd rtl/async_fifo.vhd
 rtl/attn_emit.vhd rtl/attn_gate.vhd rtl/attn_kv_axi.vhd rtl/attn_kv_quant.vhd
 rtl/attn_mac_array.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
 rtl/attn_softmax.vhd rtl/axi_rd_fsm.vhd rtl/divider_rs.vhd rtl/fk33_seam.vhd
 rtl/gdn_conv.vhd rtl/gdn_exp_capture.vhd rtl/gdn_head_emit.vhd
 rtl/gdn_recur_pipe.vhd rtl/gdn_scalar.vhd rtl/gdn_silu.vhd rtl/gdn_y_emit.vhd
 rtl/imrope_pkg.vhd rtl/l2norm_rs.vhd rtl/llama_map_pkg.vhd
 rtl/mv4i_arith_pkg.vhd rtl/rmsnorm_bf.vhd rtl/rmsnorm_rs.vhd
 rtl/sampler_stream.vhd rtl/seq_desc_fetch.vhd rtl/seq_opdec.vhd
 rtl/seq_region_lock.vhd rtl/seq_vec_issue.vhd rtl/seq_vec_res.vhd
 rtl/stream_fifo.vhd sim/seq_tbl_pkg.vhd rtl/attn_recip.vhd
 rtl/attn_twiddle.vhd rtl/axi_rd_port.vhd rtl/gdn_emit_chain.vhd
 rtl/matvec_core.vhd rtl/weight_streamer.vhd sim/llama_sched_pkg.vhd
       rtl/gdn_conv_tap_mem.vhd rtl/gdn_conv_w_mem.vhd rtl/gdn_exp_mem.vhd rtl/gdn_state_axi.vhd rtl/gdn_state_mem.vhd
 rtl/attn_block.vhd rtl/gdn_block.vhd rtl/matvec_int4.vhd
       rtl/gdn_state_store.vhd rtl/gdn_job_seq.vhd
 rtl/vec_mem.vhd rtl/rmsnorm_rs_mem.vhd rtl/rmsnorm_bf_mem.vhd rtl/swiglu_mem.vhd rtl/llama_top.vhd
 sim/tb_fk33_seam.vhd"

# The clean run is ~27 s of wall clock and reaches ~14.4 us of simulated time,
# and the bench's own poll cap (20,000 STATUS reads, ~100 us) fires before this
# does on every hang seen so far -- which is the point: a bench that hits its
# own cap produces a P3 KILL, while one that runs to --stop-time produces a
# WEDGE, and a WEDGE is an ABORT that says nothing about the checker.
# MEASURED: at STOP=400us with a 200,000-poll cap the table cost about seven
# minutes per hung row and returned ABORTs instead of verdicts.
STOP=100us

NKILL=0; NPRIOR=0; NABORT=0; NSURV=0; NTOT=0

# ---------------------------------------------------------------------------
# THE SNAPSHOT.  Take a PRIVATE COPY of every source before the first run and
# analyse from that, never from the repository.
#
# WHY, MEASURED 2026-08-30: the first full run of this table returned
#     M12  DID NOT ANALYZE ... rtl/matvec_core.vhd:216:12: identifier
#     "cb_lanes_per_copy" already used for a declaration
# on six consecutive rows, in a file this track had not touched and cannot
# touch.  A concurrent track was mid-edit in `rtl/matvec_core.vhd` and the
# analysis read it between two writes.  The table reported ABORT 14 of 17 and
# every one of those was the machine, not the mutation -- which is exactly the
# reading a mutation table must never invite, because ABORT and SURVIVED are
# the two verdicts a reader is most likely to over-interpret.
#
# One copy, at the start, is also the only way the table is INTERNALLY
# consistent: without it row M1 and row F2 can be judged against different
# trees.  Copying is one direction only, repo -> scratch, and nothing in this
# script ever writes into the repository.
#
# AND THE SNAPSHOT COMES FROM `git show HEAD:`, NOT FROM THE WORKING TREE.
# MEASURED, immediately after the working-tree snapshot was added: it captured
# a `rtl/matvec_core.vhd` that DOES NOT ANALYSE --
#     matvec_core.vhd:216:12: identifier "cb_lanes_per_copy" already used
#     matvec_core.vhd:211:12: previous declaration: function "cb_lanes_per_copy"
# because a concurrent track's uncommitted edit declares a FUNCTION
# `cb_lanes_per_copy` and a CONSTANT `CB_LANES_PER_COPY` in the same scope, and
# VHDL identifiers are CASE-INSENSITIVE.  That is not a transient half-written
# file; it is a broken edit sitting in the shared tree, and a snapshot of the
# working tree faithfully preserves it.  HEAD is the shared COMMITTED state and
# is self-consistent by construction.
#
# Files this track OWNS are new and untracked, so `git show HEAD:` has nothing
# for them; those fall back to the working tree, which is where they must come
# from -- the whole point is to test the mutation against them.
SNAP="$SCRATCH/tree"
mkdir -p "$SNAP"
for f in $FILES; do
  if git -C "$MUT_REPO" cat-file -e "HEAD:$f" 2>/dev/null; then
    if ! git -C "$MUT_REPO" show "HEAD:$f" > "$SNAP/$(basename "$f")"; then
      echo "could not snapshot HEAD:$f" >&2; exit 2
    fi
  elif ! cp -- "$MUT_REPO/$f" "$SNAP/$(basename "$f")"; then
    echo "could not snapshot $f" >&2; exit 2
  fi
done
echo "snapshot: $(ls "$SNAP" | wc -l) files under $SNAP"
echo "          sources from git HEAD $(git -C "$MUT_REPO" rev-parse --short HEAD), except this track's own untracked files"

# ---------------------------------------------------------------------------
# mutate <tag> <old> <new>  -- write a mutated copy of rtl/fk33_seam.vhd into
# $SCRATCH/<tag>_src and echo that directory.  Refuses an anchor that does not
# match EXACTLY ONCE: a mutation applied twice, or not at all, is a mutation
# nobody can reason about.
# ---------------------------------------------------------------------------
mutate() {
  local tag="$1" old="$2" new="$3"
  local dir="$SCRATCH/${tag}_src"
  mkdir -p "$dir"
  python3 - "$SNAP/fk33_seam.vhd" "$dir/fk33_seam.vhd" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
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
# run_case <tag> <desc> <mutdir>
# ---------------------------------------------------------------------------
run_case() {
  local tag="$1" desc="$2" mutdir="$3"
  if [ -n "$ONLY" ] && [ "${tag#"$ONLY"}" = "$tag" ]; then return; fi
  NTOT=$((NTOT+1))
  if [ -z "$mutdir" ] && [ "$tag" != "M0" ]; then
    echo "$tag  ANCHOR FAILED (the mutation was not applied)   -- $desc"
    NABORT=$((NABORT+1)); return
  fi
  local dir="$SCRATCH/$tag"
  mkdir -p "$dir/run"
  : > "$dir/analyze.log"
  local f src
  for f in $FILES; do
    src="$SNAP/$(basename "$f")"
    if [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ]; then
      src="$mutdir/$(basename "$f")"
    fi
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)   -- $desc"
      sed -n 1,4p "$dir/analyze.log"
      NABORT=$((NABORT+1)); return
    fi
  done
  ( cd "$dir/run" && timeout -k 5 900 ghdl -r --std=08 -frelaxed \
      --workdir=.. "$TB" --max-stack-alloc=0 --stop-time="$STOP" \
      > run.log 2>&1 )
  local rcv=$?
  local v
  v=$(python3 "$MUTV" "$dir/run/run.log" "$TB" "$rcv")

  # THE ATTRIBUTION CONTROL.  A diagnostic whose source file is NOT this
  # bench is a property that predates it.
  local prior
  prior=$(grep -avE 'metavalue' "$dir/run/run.log" \
          | grep -aE '\(assertion (error|failure)\)|\(report (error|failure)\)' \
          | grep -av 'tb_fk33_seam' | head -1)

  local pline
  pline=$(grep -a 'P1 value' "$dir/run/run.log" | head -1 | sed 's/.*note): //')

  if [ "$v" = PASS ]; then
    NSURV=$((NSURV+1))
    echo "$tag  SURVIVED   -- $desc"
    [ -n "$pline" ] && echo "        $pline"
  elif [ "$v" = KILLED ] && [ -n "$prior" ]; then
    NPRIOR=$((NPRIOR+1))
    echo "$tag  KILLED(PRIOR) -- $desc"
    echo "        an OLDER property fired too, so this kill is NOT credited"
    echo "        to sim/tb_fk33_seam.vhd:"
    echo "        $(printf '%s' "$prior" | cut -c1-150)"
    [ -n "$pline" ] && echo "        $pline"
  elif [ "$v" = KILLED ]; then
    NKILL=$((NKILL+1))
    echo "$tag  KILLED     -- $desc"
    grep -avE 'metavalue' "$dir/run/run.log" \
      | grep -a 'tb_fk33_seam' | grep -aE 'error|: FAIL' \
      | head -1 | sed 's/^/        /' | cut -c1-170
    [ -n "$pline" ] && echo "        $pline"
  else
    NABORT=$((NABORT+1))
    echo "$tag  ABORT (${v#ABORT:})   -- $desc"
    echo "        the run DIED before the checker reached a verdict, so the"
    echo "        checker was NOT shown to catch this.  Not counted as a kill."
    tail -2 "$dir/run/run.log" | sed 's/^/        /' | cut -c1-170
  fi
}

echo "=== mutate_fk33_seam.sh -- teeth for sim/tb_fk33_seam.vhd ==="
echo "scratch $SCRATCH"

# M0 -- THE ANCHOR.  An unmutated run.  If this is not a PASS nothing below
# means anything, and the table says so rather than quietly reporting kills.
run_case M0 "ANCHOR: no mutation at all.  Must SURVIVE." ""

# ---------------------------------------------------------------------------
# THE RELEASE-MASK PATH.  This is the mechanism that closes N2, so it gets
# the most rows: the mask is the one per-step quantity that used to come from
# a host, and an index that is off by one is exactly the failure a host-side
# loop would have made silently.
# ---------------------------------------------------------------------------
run_case M1 "rel index starts at 1: every step gets the NEXT step's mask" \
  "$(mutate M1 '        rel_idx <= 0;
        rel_end <= '"'"'0'"'"';' '        rel_idx <= 1;
        rel_end <= '"'"'0'"'"';')"

run_case M2 "rel index never advances: every step gets step 0's mask" \
  "$(mutate M2 '        if rel_idx = REL_ENT-1 then
          rel_end <= '"'"'1'"'"';
        else
          rel_idx <= rel_idx + 1;
        end if;' '        if rel_idx = REL_ENT-1 then
          rel_end <= '"'"'1'"'"';
        else
          rel_idx <= rel_idx;
        end if;')"

run_case M3 "rel mask published as all zeros: nothing is ever released" \
  "$(mutate M3 '  d_rel_mask <= rel_ram(rel_idx) when rel_end = '"'"'0'"'"'' \
                '  d_rel_mask <= (rel_ram(rel_idx) and (rel_ram(rel_idx)'"'"'range => '"'"'0'"'"')) when rel_end = '"'"'0'"'"'')"

# ---------------------------------------------------------------------------
# THE DESCRIPTOR PATH.
# ---------------------------------------------------------------------------
run_case M4 "descriptor 32-bit halves swapped on the write path" \
  "$(mutate M4 '                    if idx mod 2 = 0 then
                      desc_ram(idx/2)(31 downto 0)  <= dat;
                    else
                      desc_ram(idx/2)(63 downto 32) <= dat;
                    end if;' '                    if idx mod 2 = 0 then
                      desc_ram(idx/2)(63 downto 32) <= dat;
                    else
                      desc_ram(idx/2)(31 downto 0)  <= dat;
                    end if;')"

run_case M5 "descriptor read one 64-bit word early" \
  "$(mutate M5 '        a := to_integer(d_raddr);
        if a < DESC_WORDS then' '        a := to_integer(d_raddr) + 1;
        if a < DESC_WORDS then')"

run_case M6 "TBL_LEN latched one short: the walker runs out before END_TOKEN" \
  "$(mutate M6 '            when A_TBL_LEN   => r_tbl_len <= resize(unsigned(dat), STEP_W);' \
                '            when A_TBL_LEN   => r_tbl_len <= resize(unsigned(dat), STEP_W) - 1;')"

# ---------------------------------------------------------------------------
# THE ACTIVATION PATH.
# ---------------------------------------------------------------------------
run_case M7 "the X window writes one element high" \
  "$(mutate M7 '                    xw_we   <= '"'"'1'"'"';
                    xw_addr <= idx;' '                    xw_we   <= '"'"'1'"'"';
                    xw_addr <= (idx + 1) mod REGMAX;')"

run_case M8 "host_x_exp forced to zero: the row is published at the wrong scale" \
  "$(mutate M8 '            when A_X_EXP     => r_x_exp   <= resize(signed(dat), EXP_W);' \
                '            when A_X_EXP     => r_x_exp   <= (others => '"'"'0'"'"');')"

# ---------------------------------------------------------------------------
# THE COMPLETION PATH.
# ---------------------------------------------------------------------------
run_case M9 "tok_ack never raised: D holds tok_done and the position sticks" \
  "$(mutate M9 '            running  <= '"'"'0'"'"';
            ack_r    <= '"'"'1'"'"';
            if cur_pos < MAXPOS then' '            running  <= '"'"'0'"'"';
            ack_r    <= '"'"'0'"'"';
            if cur_pos < MAXPOS then')"

run_case M10 "STATUS.done wired high: a done-only poller returns immediately" \
  "$(mutate M10 '              rv(0) := st_done;' '              rv(0) := '"'"'1'"'"';')"

run_case M11 "steps_done reported one short in ERR_INFO" \
  "$(mutate M11 '              rv(16+STEP_W-1 downto 16) := std_logic_vector(st_dsteps);' \
                 '              rv(16+STEP_W-1 downto 16) := std_logic_vector(st_dsteps - 1);')"

# ---------------------------------------------------------------------------
# THE GO-TIME CHECKS.  Each of these deletes a refusal, so the seam accepts a
# request it should not.  P6 is the only thing that can see them.
# ---------------------------------------------------------------------------
run_case M12 "the TBL_LEN = 0 refusal is deleted" \
  "$(mutate M12 '                elsif r_tbl_len = 0
                   or to_integer(r_tbl_len) > REL_ENT' \
                 '                elsif false
                   or to_integer(r_tbl_len) > REL_ENT')"

run_case M13 "the reserved-HBM-pointer refusal is deleted" \
  "$(mutate M13 '                elsif unsigned(r_x_base) /= 0
                   or unsigned(r_l_base) /= 0
                   or unsigned(r_desc_ptr) /= 0 then' \
                 '                elsif false then')"

run_case M14 "the SEQ_POS refusal is deleted" \
  "$(mutate M14 '                elsif r_seq_pos /= cur_pos then' \
                 '                elsif false then')"

# ---------------------------------------------------------------------------
# THE FLOOR.  These two are EXPECTED to survive and are here to measure what
# the bench cannot see.  Do not delete them because they are not kills; a
# checker that has never been shown NOT to fire has no measured resolution.
# ---------------------------------------------------------------------------
run_case F1 "CYCLES counter frozen.  EXPECTED SURVIVOR: nothing reads it." \
  "$(mutate F1 '          r_cycles <= r_cycles + 1;' '          r_cycles <= r_cycles;')"

run_case F2 "the FAULTS bit order is permuted.  EXPECTED SURVIVOR: this shape raises none of them." \
  "$(mutate F2 '              rv(0) := f_smp_ovf;
              rv(1) := f_lost_beat;' '              rv(1) := f_smp_ovf;
              rv(0) := f_lost_beat;')"

echo
echo "=== TOTAL $NTOT   KILLED $NKILL   KILLED(PRIOR) $NPRIOR   SURVIVED $NSURV   ABORT $NABORT ==="
echo "KILLED(PRIOR) rows were caught by a property that predates this bench;"
echo "they are NOT evidence that sim/tb_fk33_seam.vhd works.  SURVIVED rows"
echo "are the measured resolution floor -- read them, do not delete them."
