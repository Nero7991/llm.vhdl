#!/usr/bin/env bash
# Mutation test for THE LOGITS EGRESS SEAM -- rtl/llama_top.vhd's `SMP_EN`
# path, `rtl/sampler_stream.vhd`, and the descriptor route flag FLG_TO_SMP.
#
# WHAT IS UNDER TEST.  Until 2026-08-29 `rtl/llama_top.vhd` discarded the
# lm_head result: `FLG_TO_SMP` reached `job_flags` and was read by nobody, and
# the A adapter dropped every y beat on `j_dst < NREGION` alone.  The new code
# is a route -- a flag latched with the descriptor, a beat FIFO, a lane
# serialiser, a per-token vocabulary index, and one `sampler_stream`.  A route
# that is correctly WIRED is not a route that carries the right NUMBERS, so
# every mutation below is aimed at a way the numbers can be wrong while every
# handshake still completes and `err` stays clear.
#
# Two rows, and they are NOT interchangeable:
#
#   tb_llama_top_smp_beh   the BEHAVIOURAL A.  Has a full independent value
#                          oracle: every logit, its vocabulary index and the
#                          argmax are recomputed in the bench.
#   tb_llama_top_smp       the REAL `matvec_int4` in raw out_mode.  No
#                          arithmetic oracle; the value check is a ROUTE
#                          COMPARISON against the same job written to a
#                          region.  It sees serialiser defects and cannot see
#                          a defect inside `matvec_core`.
#
# A mutation is run against BOTH, because a mutation killed only by the
# behavioural row has not been shown to be visible on the path that ships.
#
# EVERY ROW IS TAGGED WITH THE GENERATE BRANCH IT EDITS, and reading the table
# without that tag will mislead you.  `ga_real` and `ga_behav` are mutually
# exclusive branches: a [ga_real] mutation is NOT PRESENT in the elaborated
# design of `tb_llama_top_smp_beh`, so its "SURVIVED" on that row measures
# nothing at all -- it is the mutation not being on the path the harness
# takes, which is the pattern that has produced three false clean sweeps in
# this project already.  Only [gsmp] and [sampler_stream] rows are shared by
# both, and M15/M16 are the [ga_behav] rows that give the behavioural
# producer its own teeth.
#
# Every mutation is well-formed VHDL and in bounds, so a KILL is a checker
# noticing and not the language noticing.  SURVIVORS ARE REPORTED UNDER THEIR
# OWN NAMES: they measure the resolution floor of the checks and are the most
# valuable rows in the table.  None is ever assumed equivalent without reading
# the code.
#
# Usage:  bash sim/mutate_llama_top_smp.sh
# Env:    SCRATCH=<dir>   ONLY="<tag> <tag> ..."   (EXACT tags, space separated)
set -uo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"

FILES="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
       rtl/model_cfg_pkg.vhd rtl/act_mem_striped.vhd rtl/async_fifo.vhd
       rtl/attn_emit.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd
       rtl/attn_mac_array.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
       rtl/attn_softmax.vhd rtl/axi_rd_fsm.vhd rtl/divider_rs.vhd
       rtl/gdn_conv.vhd rtl/gdn_exp_capture.vhd rtl/gdn_head_emit.vhd
       rtl/gdn_recur_pipe.vhd rtl/gdn_scalar.vhd rtl/gdn_silu.vhd
       rtl/gdn_y_emit.vhd rtl/imrope_pkg.vhd rtl/l2norm_rs.vhd
       rtl/llama_map_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/rmsnorm_bf.vhd
       rtl/rmsnorm_rs.vhd rtl/seq_desc_fetch.vhd rtl/seq_opdec.vhd
       rtl/seq_region_lock.vhd rtl/seq_vec_issue.vhd rtl/seq_vec_res.vhd
       rtl/stream_fifo.vhd sim/seq_tbl_pkg.vhd rtl/attn_recip.vhd
       rtl/attn_twiddle.vhd rtl/axi_rd_port.vhd rtl/gdn_emit_chain.vhd
       rtl/matvec_core.vhd rtl/weight_streamer.vhd sim/llama_sched_pkg.vhd
       rtl/gdn_conv_tap_mem.vhd rtl/gdn_exp_mem.vhd rtl/gdn_state_axi.vhd rtl/gdn_state_mem.vhd
       rtl/attn_block.vhd rtl/attn_kv_axi.vhd rtl/gdn_block.vhd
       rtl/gdn_state_store.vhd rtl/gdn_job_seq.vhd
       rtl/sampler_stream.vhd rtl/matvec_int4.vhd rtl/vec_mem.vhd rtl/rmsnorm_rs_mem.vhd rtl/rmsnorm_bf_mem.vhd
       rtl/llama_top.vhd
       sim/tb_llama_top_smp.vhd sim/tb_llama_top_smp_beh.vhd"

STOP=200ms

# ---------------------------------------------------------------------------
# run_one <tag> <desc> <mutdir|""> <entity>
# ---------------------------------------------------------------------------
run_one() {
  local tag="$1" desc="$2" mutdir="$3" top="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir/run"
  local f src
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "  $top  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
      sed -n 1,4p "$dir/analyze.log"; return
    fi
  done
  ( cd "$dir/run" && timeout -k 5 1800 ghdl -r --std=08 -frelaxed \
      --workdir=.. "$top" --max-stack-alloc=0 --stop-time="$STOP" \
      > run.log 2>&1 )
  if grep -aq "tb_llama_top_smp: PASS" "$dir/run/run.log"; then
    echo "  $top  SURVIVED"
  else
    echo -n "  $top  KILLED   "
    grep -av "metavalue\|null detected" "$dir/run/run.log" \
      | grep -aE "FAIL," | head -1 | sed 's/^.*FAIL, /-- /' | cut -c1-150
  fi
}

# ---------------------------------------------------------------------------
# mutate <tag> <file> <old> <new>   -- writes a scratch copy, echoes its dir
# ---------------------------------------------------------------------------
mutate() {
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

row() {   # row <tag> <desc> <mutdir>
  local tag="$1" desc="$2" mutdir="$3"
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  if [ -z "$mutdir" ] && [ "$tag" != "C0" ]; then
    echo "$tag  MUTATION DID NOT APPLY -- $desc"; return
  fi
  echo "$tag  -- $desc"
  run_one "${tag}_beh"  "$desc" "$mutdir" tb_llama_top_smp_beh
  run_one "${tag}_real" "$desc" "$mutdir" tb_llama_top_smp
}

echo "=== the logits egress seam: mutation matrix ==="
echo "scratch: $SCRATCH"

# --- C0: THE CONTROL.  A matrix whose control does not pass is measuring the
# --- bench's own breakage and nothing else.
row C0 "CONTROL, unmutated" ""

# --- M1: the vocabulary index loses its window base.  This is THE defect the
# --- 15-window lm_head invites: each window numbers its rows from zero, so
# --- the sampler returns a ROW and not a token.
row M1 "[ga_real] smp_be_idx drops the window base (per-job row index)" \
  "$(mutate M1 rtl/llama_top.vhd \
     'smp_be_idx <= smp_base + to_integer(unsigned(y_addr));' \
     'smp_be_idx <= to_unsigned(to_integer(unsigned(y_addr)), 32);')"

# --- M2: the pad rows of the last tile are folded.  `matvec_core.vhd:832-835`
# --- masks them; a row count that is not a multiple of ROWS_IF is every real
# --- vocabulary shard except by accident.
row M2 "[ga_real] the producer marks every lane valid, so pad rows are folded" \
  "$(mutate M2 rtl/llama_top.vhd \
     '            smp_be_msk <= y_mask;' \
     '            smp_be_msk <= (others => '"'"'1'"'"');')"

# --- M3: lane order reversed.  `sampler_stream.vhd:57` breaks ties on FIRST,
# --- so lane order is part of the answer and not a presentation choice.
row M3 "[gsmp] the serialiser walks lanes highest-first" \
  "$(mutate M3 rtl/llama_top.vhd \
     'if l > nxt and fm(rp)(l) = '"'"'1'"'"' then nx2 := l; end if;' \
     'if l < nxt and fm(rp)(l) = '"'"'1'"'"' then nx2 := l; end if;')"

# --- M4: the route flag read LIVE instead of latched at `job_issue`.  Seam
# --- rule (1) applied to a route: `job_flags` decodes the LIVE bank, so the
# --- tail of one job is routed by the next job's flags.
row M4 "[ga_real] j_smp read live from job_flags instead of latched" \
  "$(mutate M4 rtl/llama_top.vhd \
     'if y_we = '"'"'1'"'"' and j_smp = '"'"'1'"'"' then' \
     'if y_we = '"'"'1'"'"' and job_flags(1) = '"'"'1'"'"' then')"

# --- M5: the sampler cleared per JOB rather than per token, which returns the
# --- argmax of the LAST window.
row M5 "[gsmp] s_clr on every FLG_TO_SMP job instead of on go" \
  "$(mutate M5 rtl/llama_top.vhd \
     '          if go = '"'"'1'"'"' then
            s_clr  <= '"'"'1'"'"';' \
     '          if go = '"'"'1'"'"' or (run_q = '"'"'0'"'"' and smp_run = '"'"'1'"'"') then
            s_clr  <= '"'"'1'"'"';')"

# --- M6: push before pop.  This is a REGRESSION TEST for a defect this track
# --- actually shipped and measured; see the comment at the pop block.
row M6 "[gsmp] the FIFO pops off an occupancy that counts this cycle's push" \
  "$(mutate M6 rtl/llama_top.vhd \
     '          if o > 0 then
            nxt := A_ROWS_IF;' \
     '          if o > 0 or smp_be_we = '"'"'1'"'"' then
            nxt := A_ROWS_IF;')"

# --- M7: the wrong half of the 64-bit lane.  RAW puts a sign-extended s32 in
# --- the LOW half (`matvec_core.vhd:829`); the high half is sign extension.
row M7 "[ga_real] the logit is taken from the upper half of the y lane" \
  "$(mutate M7 rtl/llama_top.vhd \
     '                <= y_data(rr*64+31 downto rr*64);' \
     '                <= y_data(rr*64+63 downto rr*64+32);')"

# --- M8: the window base advances by the TILE-ROUNDED row count.  A silent
# --- off-by-(ROWS_IF - n_rows mod ROWS_IF) that is invisible whenever the
# --- window is a multiple of ROWS_IF -- which is why the bench's windows are
# --- not multiples of it.
row M8 "[ga_real] smp_base advances by the tile-rounded row count" \
  "$(mutate M8 rtl/llama_top.vhd \
     '                  -- renumber a window boundary
                  smp_base <= smp_base + j_rows;' \
     '                  -- renumber a window boundary
                  smp_base <= smp_base
                              + ((j_rows + A_ROWS_IF - 1) / A_ROWS_IF)
                                * A_ROWS_IF;')"

# --- M9: `done` no longer waits for the sampler.  The job reports complete
# --- with beats still in the FIFO, so the NEXT `go` clears them.
row M9 "[ga_real] S_SDRAIN does not wait for the FIFO to drain" \
  "$(mutate M9 rtl/llama_top.vhd \
     '              smp_run <= '"'"'0'"'"';
              if smp_empty = '"'"'1'"'"' then
                if j_dst < NREGION then st := S_DRAIN; else st := S_DONE; end if;
              end if;' \
     '              smp_run <= '"'"'0'"'"';
              if j_dst < NREGION then st := S_DRAIN; else st := S_DONE; end if;')"

# --- M10: the FIFO one beat deep.  `y_we` has no ready, so this is a LOST
# --- beat and not a stall -- the fault counter is the only thing that can
# --- say so, and this row is what shows it fires.
row M10 "[gsmp] SMP_FIFO reduced to 1 beat" \
  "$(mutate M10 rtl/llama_top.vhd \
     '    SMP_FIFO : positive := 8;' \
     '    SMP_FIFO : positive := 1;')"

# --- M11: the argmax tie-break.  `sampler_stream.vhd:57` uses a strict '>'
# --- so the FIRST max wins, matching the C oracle's sample_argmax().  Whether
# --- this bites depends on whether the stimulus produces a tie AT the maximum,
# --- which is a property of the DATA and not of the design.
row M11 "[sampler_stream] argmax ties broken on the LAST max" \
  "$(mutate M11 rtl/sampler_stream.vhd \
     'elsif cur > best_v then' \
     'elsif cur >= best_v then')"

# --- M12: the exponent taken from the DESCRIPTOR's w_exp rather than from A's
# --- published y_exp.  A logits exponent that omits x_exp and out_shift is
# --- wrong by a token-dependent amount and the argmax never notices, because
# --- a single shared exponent cancels out of a comparison.
row M12 "[ga_real] smp_exp published as the descriptor w_exp, not A's y_exp" \
  "$(mutate M12 rtl/llama_top.vhd \
     '            smp_yexp_i <= resize(signed(y_expv), EXP_W);' \
     '            smp_yexp_i <= to_signed(j_wexp, EXP_W);')"

# --- M13: the vocabulary index is not zeroed at the token boundary, so
# --- token 1's logits are numbered from where token 0's ended.  Only a
# --- MULTI-TOKEN run can see this, which is why NTOK is 2 and not 1.
row M13 "[ga_real] smp_base is not cleared on go, index runs across tokens" \
  "$(mutate M13 rtl/llama_top.vhd \
     '          if go = '"'"'1'"'"' then smp_base <= (others => '"'"'0'"'"'); end if;
          if job_issue = '"'"'1'"'"' and to_integer(job_unit) = U_A then
            j_src   := to_integer(job_src(6 downto 0));
            j_dst   := to_integer(job_dst(6 downto 0));
            j_off   := to_integer(job_dst_off(15 downto 0));
            j_rows  := to_integer(job_n_rows(15 downto 0));
            j_cols  := to_integer(job_n_cols(15 downto 0));
            j_shift := to_integer(job_out_shift(15 downto 0));
            j_wexp  := to_integer(job_w_exp(15 downto 0));
            j_mode  := job_out_mode(1 downto 0);' \
     '          if job_issue = '"'"'1'"'"' and to_integer(job_unit) = U_A then
            j_src   := to_integer(job_src(6 downto 0));
            j_dst   := to_integer(job_dst(6 downto 0));
            j_off   := to_integer(job_dst_off(15 downto 0));
            j_rows  := to_integer(job_n_rows(15 downto 0));
            j_cols  := to_integer(job_n_cols(15 downto 0));
            j_shift := to_integer(job_out_shift(15 downto 0));
            j_wexp  := to_integer(job_w_exp(15 downto 0));
            j_mode  := job_out_mode(1 downto 0);')"

# --- M14: the run window never opens, so `smp_done` never fires and nothing
# --- ever says the token's logits are complete.  A liveness mutation: the
# --- values are all still right.
row M14 "[ga_real] smp_run is never asserted, so smp_done never pulses" \
  "$(mutate M14 rtl/llama_top.vhd \
     '              if j_smp = '"'"'1'"'"' then smp_run <= '"'"'1'"'"'; end if;' \
     '              if false then smp_run <= '"'"'1'"'"'; end if;')"

# --- M15/M16 live in `ga_behav`, the branch the BEHAVIOURAL row elaborates.
# --- Every mutation above M15 that is tagged [ga_real] is UNREACHABLE from
# --- tb_llama_top_smp_beh by construction -- the branch does not elaborate --
# --- so its "SURVIVED" on that row is not a resolution measurement, it is the
# --- mutation not being on the path.  These two exist so the behavioural
# --- producer half is not left with zero teeth.
row M15 "[ga_behav] the streamed logit is narrowed to the region's 16 bits" \
  "$(mutate M15 rtl/llama_top.vhd \
     '                smp_be_dat(31 downto 0)
                  <= std_logic_vector(to_signed(sh, 32));' \
     '                smp_be_dat(31 downto 0)
                  <= std_logic_vector(resize(sat_m(sh), 32));')"

row M16 "[ga_behav] the beat index drops the window base" \
  "$(mutate M16 rtl/llama_top.vhd \
     '                smp_be_idx <= smp_base + r;' \
     '                smp_be_idx <= to_unsigned(r, 32);')"

echo "=== end ==="
