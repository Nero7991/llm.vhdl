#!/usr/bin/env bash
# Mutation test for the KV SEAM AT THE INTEGRATION LEVEL -- rtl/llama_top.vhd
# with rtl/attn_kv_axi.vhd instantiated, over a multi-token sequence.
#
# WHAT IS UNDER TEST AND WHY IT IS NOT A FILE.  sim/mutate_attn_kv_seam.sh
# already mutates the attn_block <-> attn_kv_axi contract at the BLOCK level
# and does it against a bit-exact value oracle.  Nothing there says the
# INTEGRATION drives that contract correctly: llama_top has to publish the
# sequence position, the layer, the two bases and the sequence reset, it has
# to hold the four handshakes, and it has to do all of that across a token
# boundary that no block-level bench has.  Those are the mutations here.
#
# Three flavours, all reported:
#
#   Mx  a GENERIC on sim/tb_llama_top.vhd that perturbs the modelled HBM or
#       the driver -- a stale record served, a write burst dropped, the
#       tokens not actually sequenced.  These cannot be expressed as an edit
#       to any RTL file because they are properties of the composition.
#   Rx  a textual mutation of a scratch copy of rtl/llama_top.vhd -- the
#       integration's own wiring: a handshake ungated, a layer skewed, the
#       position counter frozen.
#   Cx  a CONTROL: the CLEAN design under the same unusual slave setting an
#       Rx needs.  A mutation that only dies under an unusual setting has
#       proved nothing unless the clean design passes under that same
#       setting.
#
# Every mutation is well-formed VHDL and in bounds, so a KILL is a checker
# noticing and not the language noticing.  A SURVIVOR is investigated by
# reading the code, never assumed equivalent, and is reported under its own
# name: survivors measure the resolution floor of the checks and are the most
# valuable rows in the table.
#
# Usage:  bash sim/mutate_llama_top_kv.sh
# Env:    SCRATCH=<dir>   ONLY="<tag> <tag> ..."   (exact tags, space separated)
#
# ONLY takes EXACT tags, not a substring: the tags are C0..C3, M1..M5 and
# R1..R7 with R2b/R2c, and a substring filter cannot select R2 without also
# selecting R2b and R2c.  It exists so the matrix can be split across several
# shells -- one case is about six minutes and there are 23 of them.
set -uo pipefail

# ---------------------------------------------------------------------------
# SELF-ISOLATION.  Run from a PRIVATE COPY, exactly as sim/regress.sh:287 does.
#
# NOT a precaution: MEASURED 2026-08-29.  This script was edited (one filename
# added to FILES) while an instance of it was running, and bash -- which reads
# a script by BYTE OFFSET as it executes -- resumed mid-token and died with
# `syntax error near unexpected token '('` at a line that is perfectly valid.
# The run had already completed two cases and looked healthy up to that point,
# so the failure reads as a defect in the last case rather than as an edit.
#
# The copy is syntax-checked before it is re-execed, because a copy taken
# mid-write is garbage and re-execing it reproduces the very failure this
# guards against.  MUTKV_NO_REEXEC=1 disables it, for debugging the guard.
# ---------------------------------------------------------------------------
if [ -z "${MUTKV_REPO:-}" ]; then
  MUTKV_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUTKV_REPO
fi
if [ -z "${MUTKV_SELF:-}" ] && [ -z "${MUTKV_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutkv-self.XXXXXXXX.sh)" || exit 2
  if ! cat "${BASH_SOURCE[0]}" > "$_self"; then
    rm -f "$_self"; echo "mutate_llama_top_kv.sh: no private copy" >&2; exit 2
  fi
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "mutate_llama_top_kv.sh: the private copy does not parse -- the" >&2
    echo "  script was probably being written as it was copied.  Try again." >&2
    exit 2
  fi
  chmod 0700 "$_self"
  export MUTKV_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
  rm -f "$_self"
  echo "mutate_llama_top_kv.sh: could not re-exec the private copy" >&2
  exit 2
fi
trap 'rm -f "${MUTKV_SELF:-}"' EXIT

cd "$MUTKV_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"

# TRACK RMSWIRE, 2026-08-30: `rtl/vec_mem.vhd` and `rtl/rmsnorm_rs_mem.vhd`
# added.  `llama_top`'s D-vec norm now instantiates the memory-backed unit
# instead of the flat `rmsnorm_rs`, so the source closure grew by two files.
#
# THIS LIST IS READ BY THREE HARNESSES, not one -- mutate_llama_top_normuram.sh
# and mutate_rmswire.sh both `sed` it out of this file, exactly so that a
# closure change lands in one place.  Without these two entries every row of
# all three, INCLUDING THE CONTROLS, reports NOBUILD with
# `unit "rmsnorm_rs_mem" not found in library "work"` buried in a per-row
# analyze log.  MEASURED: that is how mutate_rmswire.sh's first run came out,
# and the tell was that the CONTROL failed -- a matrix whose control fails
# measures nothing, which is why every one of them has a control row.
#
# `sim/regress.sh` was NOT affected: it computes the closure itself and the
# llama_top rows stayed green throughout.  So the gate cannot catch this class
# of staleness and the control rows are the only thing that can.
FILES="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
       rtl/model_cfg_pkg.vhd rtl/act_mem_striped.vhd rtl/async_fifo.vhd
       rtl/attn_emit.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd
       rtl/attn_mac_array.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
       rtl/attn_softmax.vhd rtl/axi_rd_fsm.vhd rtl/divider_rs.vhd
       rtl/gdn_conv.vhd rtl/gdn_exp_capture.vhd rtl/gdn_head_emit.vhd
       rtl/gdn_recur_pipe.vhd rtl/gdn_scalar.vhd rtl/gdn_silu.vhd
       rtl/gdn_y_emit.vhd rtl/imrope_pkg.vhd rtl/l2norm_rs.vhd
       rtl/llama_map_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/rmsnorm_bf.vhd
       rtl/rmsnorm_rs.vhd rtl/vec_mem.vhd rtl/rmsnorm_rs_mem.vhd rtl/rmsnorm_bf_mem.vhd rtl/swiglu_mem.vhd
       rtl/seq_desc_fetch.vhd rtl/seq_opdec.vhd
       rtl/seq_region_lock.vhd rtl/seq_vec_issue.vhd rtl/seq_vec_res.vhd
       rtl/stream_fifo.vhd sim/seq_tbl_pkg.vhd rtl/attn_recip.vhd
       rtl/attn_twiddle.vhd rtl/axi_rd_port.vhd rtl/gdn_emit_chain.vhd
       rtl/matvec_core.vhd rtl/weight_streamer.vhd sim/llama_sched_pkg.vhd
       rtl/gdn_conv_tap_mem.vhd rtl/gdn_exp_mem.vhd rtl/gdn_state_axi.vhd rtl/gdn_state_mem.vhd
       rtl/attn_block.vhd rtl/attn_kv_axi.vhd rtl/gdn_block.vhd
       rtl/gdn_state_store.vhd rtl/gdn_job_seq.vhd
       rtl/matvec_int4.vhd rtl/sampler_stream.vhd rtl/llama_top.vhd
       sim/tb_llama_top.vhd"

# The KV-cache configuration.  ATTN_HD 64 / KV_BLOCK 16 / N_ROT 16 is FORCED
# by the three-way geometry constraint; see the header of sim/tb_llama_top.vhd.
# BLOCKS 4 with ATTN_INT 2 gives TWO attention layers in one token, which is
# what makes the `layer` term of C spec 2.2's address equation observable --
# sim/tb_attn_kv_seam.vhd runs one layer and lists this as an open item.
# NTOK 3 rather than the 4 the manual run uses: 23 cases at 4 tokens x 2
# latency points is over two hours, and position 2 is already a position whose
# sweep reads TWO earlier records.  Raise it if a survivor needs a longer
# sequence to become a kill, and say so if you do.
BASE="-gBLOCKS=4 -gATTN_INT=2 -gNTOK=3 -gC_REAL=true -gATTN_HD=64
      -gKV_BLOCK=16 -gN_ROT=16 -gMAXPOS=8 -gKV_AXI=true"
# NRUNS 2 rather than 1: run 1 sweeps BOTH the descriptor-memory latency and
# the KV read latency, and the seam defects that produce a deterministic wrong
# answer at one timing are exactly the ones only a second timing can see.
NRUNS="-gNRUNS=2"
STOP=900ms

# ---------------------------------------------------------------------------
# run_case <tag> <desc> <mutdir|""> <extra ghdl -r args...>
# ---------------------------------------------------------------------------
# NOTE: run_case's exit status is meaningless (it ends in a grep that finds
# nothing on a clean kill), so it is NEVER used on the left of && or ||.
run_case() {
  local tag="$1" desc="$2" mutdir="$3"; shift 3
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir/run"
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
  ( cd "$dir/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed \
      --workdir=.. tb_llama_top $BASE $NRUNS "$@" --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  if grep -aq "tb_llama_top RESULT: PASS" "$dir/run/run.log"; then
    echo "$tag  SURVIVED   -- $desc"
  elif grep -aq "cycle cap reached" "$dir/run/run.log"; then
    echo "$tag  KILLED(HANG) -- $desc"
  elif ! grep -aq "tb_llama_top RESULT" "$dir/run/run.log"; then
    # A THIRD VERDICT, added 2026-08-29.  A run that DIED printed no RESULT
    # line at all, and folding that into KILLED credits the checkers with a
    # detection they did not make -- the simulator noticed, not the bench.  It
    # is still counted as a kill; it is just labelled honestly.
    echo "$tag  KILLED(ABORT) -- the run produced no RESULT line -- $desc"
  else
    echo "$tag  KILLED     -- $desc"
    grep -av "metavalue\|null detected" "$dir/run/run.log" \
      | grep -aE "KV faults=|token position faults=|never wrote|never read|was served|no token ever wrote|landed at|read the WHOLE|inside neither|not yet in memory|SKEW DIFFERENCE|bit-identical R_X|started with the DUT|moved ZERO" \
      | head -2 | sed 's/^/        /' | cut -c1-180
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
# run_row <tag> <desc> <mutdir|""> <entity> <extra ghdl -r args...>
# ---------------------------------------------------------------------------
# The same runner against a DIFFERENT gate row.  Two of the three rows exist
# precisely so a mutation can be shown to fail one and pass the others, and
# that is not demonstrable from inside one configuration.
run_row() {
  local tag="$1" desc="$2" mutdir="$3" top="$4"; shift 4
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir/run"
  local f src
  for f in $FILES sim/tb_llama_top_seq.vhd sim/tb_llama_top_real.vhd; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "$tag  DID NOT ANALYZE   -- $desc"
      sed -n 1,4p "$dir/analyze.log"; return
    fi
  done
  # the committed real-weight image, opened by bare name
  ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex" "$dir/run/" 2>/dev/null
  ( cd "$dir/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed \
      --workdir=.. "$top" "$@" --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  if grep -aq "tb_llama_top RESULT: PASS" "$dir/run/run.log"; then
    echo "$tag  SURVIVED   -- $desc"
  elif ! grep -aq "tb_llama_top RESULT" "$dir/run/run.log"; then
    echo "$tag  KILLED(ABORT) -- the run produced no RESULT line -- $desc"
  else
    echo "$tag  KILLED     -- $desc"
    grep -av "metavalue\|null detected" "$dir/run/run.log" \
      | grep -aE "KV faults=|token position faults=|degenerate residuals=|handshake was low|sticky error|RESULT: FAIL" \
      | head -2 | sed 's/^/        /' | cut -c1-180
  fi
}

echo "=== controls ==============================================="
run_case C0 "CONTROL: clean, the shipping KV configuration" ""
run_case C1 "CONTROL: clean, 4000-cycle BRESP latency" "" -gKV_WR_LAT=4000
run_case C2 "CONTROL: clean, write slave refuses AW for 3000 cycles" "" \
            -gKV_AW_LAT=3000
run_case C3 "CONTROL: clean, but the write slave commits at W (the WEAK slave, which is what makes P11 blind)" \
            "" -gMUT_KV_NO_BRESP=true

echo "=== M: mutations of the composition ========================"
run_case M1 "the read slaves serve the PREVIOUS position's bytes" "" \
            -gMUT_KV_STALE=true
run_case M2 "one record's write burst is dropped, BRESP still returned" "" \
            -gMUT_KV_DROP_REC=true
run_case M3 "the read slaves return zeros (also the control for P12)" "" \
            -gMUT_KV_ZERO=true
run_case M4 "the DUT is RESET between tokens, so every token runs at cur_pos 0 -- the pre-seam behaviour of this bench" \
            "" -gMUT_TOK_RESET=true
run_case M5 "the same embedding for every token, so every cached record is identical -- the DEGENERATE SEQUENCE this bench shipped with for one afternoon" \
            "" -gEMBED_VARY=false

echo "=== R: mutations of the integration's own wiring ============"
# TWO FORMS OF THE SAME DEFECT, and they are NOT equivalent from the checker's
# side.  R1 leaves the BLOCK ignoring an answer the cache still publishes;
# R1b leaves the cache's output unconnected so no answer exists at all.  The
# handshake property in rtl/llama_top.vhd can see the first and CANNOT see the
# second, because it watches the wire the mutation deletes.  Both rows are
# kept: the pair is what says where the property's resolution ends.
D=$(mutate_rtl R1 rtl/llama_top.vhd \
  "        kr_rdy => kr_rdy_s," \
  "        kr_rdy => Y_RDY,")
[ -n "$D" ] && run_case R1 "the BLOCK ignores the residency answer (its kr_rdy tied high), which is the PRE-SEAM design at the integration level" "$D"

D=$(mutate_rtl R1b rtl/llama_top.vhd \
  "          kr_head => kr_head, kr_pos => kr_pos, kr_rdy => kr_rdy_s," \
  "          kr_head => kr_head, kr_pos => kr_pos, kr_rdy => open,")
if [ -n "$D" ]; then
  python3 - "$D/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("    signal kr_rdy_s  : std_logic;",
            "    signal kr_rdy_s  : std_logic := '1';",1)
open(p,"w").write(s)
PY
  run_case R1b "the CACHE's kr_rdy output is left open, so the answer is never produced at all" "$D"
fi

D=$(mutate_rtl R2 rtl/llama_top.vhd \
  "          cfg_taken => kv_cfgt_s, busy => kv_busy_s, wr_idle => wr_idle_s," \
  "          cfg_taken => kv_cfgt_s, busy => kv_busy_s, wr_idle => open,")
if [ -n "$D" ]; then
  python3 - "$D/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("    signal wr_idle_s : std_logic;",
            "    signal wr_idle_s : std_logic := '1';",1)
open(p,"w").write(s)
PY
  run_case R2  "kv_wr_idle ungated -- done without waiting for BRESP, at WR_LAT 12" "$D"
  run_case R2b "the same, at a 4000-cycle BRESP latency" "$D" -gKV_WR_LAT=4000
  run_case R2c "the same, at a 4000-cycle BRESP latency AND the weak slave" "$D" \
               -gKV_WR_LAT=4000 -gMUT_KV_NO_BRESP=true
fi

D=$(mutate_rtl R3 rtl/llama_top.vhd \
  "          start => c_start, layer => c_layer," \
  "          start => c_start, layer => c_layer_mut,")
if [ -n "$D" ]; then
  # NO EXPRESSIONS IN THE PORT MAP: GHDL 1.0 mcode raised an INTERNAL ERROR
  # on a function call written as an actual in this file, so the skew is a
  # signal and a concurrent assignment, exactly like every other actual here.
  python3 - "$D/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("    signal kv_busy_s, kv_cfgt_s : std_logic;",
            "    signal kv_busy_s, kv_cfgt_s : std_logic;\n"
            "    signal c_layer_mut : integer range 0 to C_LAY-1 := 0;",1)
# `u_ready(U_C) <= rdy;` appears in BOTH the stub and the real C branch.
# Anchor on the line that only the real one has.
s=s.replace("    u_err(U_C)   <= uerr;",
            "    u_err(U_C)   <= uerr;\n"
            "    c_layer_mut <= (c_layer + 1) mod C_LAY;",1)
open(p,"w").write(s)
PY
  run_case R3 "attn_kv_axi is configured for the NEXT layer -- the records of layer 0 land at layer 1's addresses" "$D"
fi

D=$(mutate_rtl R4 rtl/llama_top.vhd \
  "        else
          tok_pos <= tok_pos + 1;
        end if;" \
  "        else
          tok_pos <= tok_pos;
        end if;")
[ -n "$D" ] && run_case R4 "the sequence position never advances -- every token writes over position 0" "$D"

D=$(mutate_rtl R5 rtl/llama_top.vhd \
  "            c_cpos  <= to_unsigned(tok_pos, POSW);" \
  "            c_cpos  <= to_unsigned(tok_pos + 1, POSW);")
[ -n "$D" ] && run_case R5 "the position published to BOTH the block and the cache is one too large -- the cache is asked to serve the record this job is writing" "$D"

D=$(mutate_rtl R6 rtl/llama_top.vhd \
  "          k_base => KBASE_C, v_base => VBASE_C," \
  "          k_base => VBASE_C, v_base => KBASE_C,")
[ -n "$D" ] && run_case R6 "the K and V bases are swapped" "$D"

D=$(mutate_rtl R7 rtl/llama_top.vhd \
  "        if rst = '1' then      c_seqrst <= '1';
        elsif c_srtk = '1' then c_seqrst <= '0'; end if;" \
  "        if rst = '1' or tok_done_i = '1' then c_seqrst <= '1';
        elsif c_srtk = '1' then c_seqrst <= '0'; end if;")
[ -n "$D" ] && run_case R7 "the v_ref sequence reset is issued per TOKEN, not per sequence (C spec 2.1.4)" "$D"

# R7b.  R7 DOES NOT DO WHAT ITS DESCRIPTION SAYS, MEASURED 2026-08-29 by
# TRACK C1 with a `report` on attn_block's fold and on its kv_seq_rst edge:
#
#   R7  as written  ->  VREFPROBE seqrst fires TWICE in a 3-token run: once
#                       from `rst`, once at the token 0->1 boundary, and never
#                       again.  `tok_done_i` is a LEVEL held until `tok_ack`,
#                       so `or tok_done_i = '1'` takes priority over the
#                       `elsif c_srtk = '1'` clear for the whole done window;
#                       c_seqrst never returns to '0', and attn_block's reset
#                       is a RISING-EDGE detect (`kv_seq_rst = '1' and
#                       seqrst_q = '0'`).  R7 is therefore "reset ONCE", not
#                       "reset per token".
#
# That mattered the day rtl/attn_block.vhd's v_ref fold gained its missing
# LAYER dimension: with a correct per-layer fold, the one reset R7 does issue
# lands where each layer's own minimum already equals the running minimum, so
# R7 produces a BYTE-IDENTICAL capture and SURVIVES.  Removing a defect must
# not silently remove a mutation's teeth, so R7b is the defect R7's own
# description names -- a genuine per-token-boundary reset, edge-detected so it
# cannot go sticky.
#
# R7b is KILLED at the existing 3-token stimulus and needs no new one.  It is
# killed by the DESIGN, not by a checker: a v_ref reset mid-sequence leaves
# cached V records from earlier tokens whose block exponents sit BELOW the
# re-folded reference, site 3's `e_v[b] - v_ref` goes negative,
# rtl/attn_block.vhd:1493 raises `err` on `vsh_neg`, and the walker reports
# ERR_UNIT (x1).  Verdict KILLED(ABORT), which run_case labels honestly.
D=$(mutate_rtl R7b rtl/llama_top.vhd \
  "    srp : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then      c_seqrst <= '1';
        elsif c_srtk = '1' then c_seqrst <= '0'; end if;
      end if;
    end process;" \
  "    srp : process(clk) is
      variable tdq : std_logic := '0';
    begin
      if rising_edge(clk) then
        if rst = '1' then      c_seqrst <= '1';
        elsif c_srtk = '1' then c_seqrst <= '0'; end if;
        if tok_done_i = '1' and tdq = '0' then c_seqrst <= '1'; end if;
        tdq := tok_done_i;
      end if;
    end process;")
[ -n "$D" ] && run_case R7b "R7's DESCRIPTION, actually implemented: the v_ref fold is reset at EVERY token boundary (edge-detected, so it cannot go sticky the way R7 does)" "$D"

# ---------------------------------------------------------------------------
# mutate_rtl_pair <tag> <fileA> <oldA> <newA> <fileB> <oldB> <newB>
# ---------------------------------------------------------------------------
# TWO files in one mutant.  R8 needs it: making the cache actually SERVE the
# current position takes an edit on BOTH sides -- the block has to ask for it
# and the cache has to stop refusing -- and either edit alone reaches a
# different state.  Same reasoning TRACK C-SEAM recorded for its R5b.
mutate_rtl_pair() {
  local tag="$1" fa="$2" oa="$3" na="$4" fb="$5" ob="$6" nb2="$7"
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$fa" "$dir/$(basename "$fa")" "$oa" "$na" <<'PY'
import sys
src,dst,old,new = sys.argv[1:5]
s=open(src).read(); n=s.count(old)
if n!=1:
    sys.stderr.write("ANCHOR A MATCHED %d TIMES\n"%n); sys.exit(2)
open(dst,"w").write(s.replace(old,new))
PY
  [ $? -ne 0 ] && { echo ""; return; }
  python3 - "$fb" "$dir/$(basename "$fb")" "$ob" "$nb2" <<'PY'
import sys
src,dst,old,new = sys.argv[1:5]
s=open(src).read(); n=s.count(old)
if n!=1:
    sys.stderr.write("ANCHOR B MATCHED %d TIMES\n"%n); sys.exit(2)
open(dst,"w").write(s.replace(old,new))
PY
  [ $? -ne 0 ] && { echo ""; return; }
  echo "$dir"
}

echo "=== R8: the one mutation that makes the cache SERVE the current position ==="
# P9 has two halves and only one of them had ever been shown to fire.  "Not
# fewer than {0..cur_pos-1}" fires on M4 and R4; "not MORE" needs a design
# that actually reads the record at cur_pos, and nothing does, because
# attn_block bypasses it.  Both sides have to be broken at once: the block
# stops bypassing AND the cache is told the current position is readable.
D=$(mutate_rtl_pair R8 \
  rtl/attn_block.vhd \
  "            if is_byp = '1' then
              krec <= kbyp;
              khdr <= kbh;
              ph <= P_HDR;
            elsif blk < NBLK then" \
  "            if false then
              krec <= kbyp;
              khdr <= kbh;
              ph <= P_HDR;
            elsif blk < NBLK then" \
  rtl/llama_top.vhd \
  "          start => c_start, layer => c_layer,
          cur_pos => c_cpos, ctx_len => c_ctx," \
  "          start => c_start, layer => c_layer,
          cur_pos => c_cpos_hi, ctx_len => c_ctx,")
if [ -n "$D" ]; then
  python3 - "$D/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("    signal kv_busy_s, kv_cfgt_s : std_logic;",
            "    signal kv_busy_s, kv_cfgt_s : std_logic;\n"
            "    signal c_cpos_hi : unsigned(POSW-1 downto 0)"
            " := (others => '0');",1)
s=s.replace("    u_err(U_C)   <= uerr;",
            "    u_err(U_C)   <= uerr;\n"
            "    c_cpos_hi <= c_cpos + 1;",1)
open(p,"w").write(s)
PY
  run_case R8 "attn_block stops bypassing AND the cache is told cur_pos is readable, so the sweep really does read the record this job is writing" "$D"
fi

echo "=== N: the NORM_REAL adapter, which only sim/tb_llama_top_real.vhd reaches ==="
# Every N row is run TWICE: once against the row that elaborates the mutated
# code and once against the DEFAULT gate row, which does not.  A row that only
# showed the kill would not show that the OTHER rows are blind to it, and the
# blindness is the reason the row had to be added.
# RE-ANCHORED 2026-08-29.  TRACK NORMW's 9f690a0 made the gain a SELECTED
# source (`wsel`) instead of the constant `W_CONST`, so this row's anchor
# stopped matching and `mutate_rtl` printed MUTATION ANCHOR MATCHED 0 TIMES and
# the row was SILENTLY DROPPED -- the loud message is the only thing between a
# stale anchor and a mutation table that has quietly shrunk.  The mutation
# itself is unchanged: the learned gain's exponent, 20 octaves out.
D=$(mutate_rtl N1 rtl/llama_top.vhd \
  "          w_mant => wsel,    w_exp => NORM_W_EXP," \
  "          w_mant => wsel,    w_exp => NORM_W_EXP + 20,")
if [ -n "$D" ]; then
  run_row N1  "the real rmsnorm's learned-gain exponent is 20 octaves out"          "$D" tb_llama_top_real
  run_row N1x "the SAME mutation against the DEFAULT gate row, which does not elaborate the NORM_REAL adapter at all" "$D" tb_llama_top
fi

D=$(mutate_rtl N2 rtl/llama_top.vhd \
  "                if k = n-1 then k := 0; st := S_DONE; else k := k + 1; end if;" \
  "                if k = n-2 then k := 0; st := S_DONE; else k := k + 1; end if;")
if [ -n "$D" ]; then
  run_row N2  "the real rmsnorm's writeback drops its last element"                 "$D" tb_llama_top_real
  run_row N2x "the SAME mutation against the DEFAULT gate row"                      "$D" tb_llama_top
fi

echo "=== X: the KV mutations against the rows that cannot see them ==="
D=$(mutate_rtl X1 rtl/llama_top.vhd \
  "          kr_head => kr_head, kr_pos => kr_pos, kr_rdy => kr_rdy_s," \
  "          kr_head => kr_head, kr_pos => kr_pos, kr_rdy => open,")
if [ -n "$D" ]; then
  python3 - "$D/llama_top.vhd" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("    signal kr_rdy_s  : std_logic;",
            "    signal kr_rdy_s  : std_logic := '1';",1)
open(p,"w").write(s)
PY
  run_row X1  "R1b's mutant (kr_rdy unconnected) against the DEFAULT gate row -- C_KV_AXI is false there, so the mutated branch does not elaborate" "$D" tb_llama_top
  run_row X1r "R1b's mutant against the REAL-PATH row, which also has C_KV_AXI false" "$D" tb_llama_top_real
fi

# ===========================================================================
# THE VALUE ROWS.  Added 2026-08-29 by TRACK BISECT.
#
# WHY THEY EXIST.  Every row above scores a mutant by whether the BENCH's own
# checkers fired, and the bench has no value oracle for a token.  Nine mutants
# survived that, and this file's own analysis named the reason twice: "no value
# oracle at integration" (R7) and "defends the MAGNITUDE behaviour, not the
# arithmetic" (N2).  These rows score the same mutants by what the machine
# COMPUTED, through `sim/tb_llama_top.vhd`'s CAPTURE generic.
#
# TWO VERDICTS PER ROW, AND THEY ARE NOT THE SAME CLAIM.
#
#   CAPTURE  the mutant's seam stream against a CLEAN run of the SAME
#            configuration, bit for bit, every record, via
#            tools/ref9b/seam_diff.py.  A CHARACTERISATION result: it says the
#            numbers moved and where they first moved.  It does NOT say the
#            clean numbers were right.
#
#   ORACLE   the mutant's seams against INDEPENDENT models of what each op
#            should compute, given the machine's own inputs, via
#            tools/ref9b/bisect_scaled.py -- ref/matvec_int4.c for the 26 A
#            jobs, ref/seq_vec_res_vec.c's recipe for the residuals, a
#            bit-exact rmsnorm_rs model for the norms.  A CORRECTNESS result,
#            and it covers 58 of the 63 seams.  The five it does not cover are
#            the four R_Y (subsystems B and C have no integration-level model)
#            and LOGITS (which the design cannot produce at all -- finding D1).
#
# A row that is CAPTURE-killed and ORACLE-clean is not a contradiction: it is
# the coverage hole, measured.  R7 is exactly that row.
#
# The clean baseline is generated HERE, per configuration, rather than read
# from a committed golden.  A committed golden goes stale the moment any track
# changes the numbers legitimately, and a stale golden turns every later row
# red for a reason that has nothing to do with the mutant.
# ===========================================================================

# cap_generics <cfg>  -- echoes the ghdl -r generics for a configuration
cap_generics() {
  case "$1" in
    real) echo "-gBLOCKS=4 -gATTN_INT=4 -gC_REAL=true -gATTN_HD=16
                -gNORM_REAL=true -gNORM_ANCHOR=false
                -gW_IMAGE=llama_top_w_b4_pool.hex" ;;
    seq)  echo "-gBLOCKS=4 -gATTN_INT=2 -gNTOK=3 -gC_REAL=true -gATTN_HD=64
                -gKV_BLOCK=16 -gN_ROT=16 -gMAXPOS=8 -gKV_AXI=true" ;;
    *) echo "" ;;
  esac
}

# cap_oracle_args <cfg>  -- the matching arguments for bisect_scaled.py
cap_oracle_args() {
  case "$1" in
    real) echo "--blocks 4 --attn-int 4 --attn-hd 16 --norm real
                --w-image ../../sim/llama_top_w_b4_pool.hex" ;;
    # --kv-block and --n-rot are NOT recorded in the capture and a wrong
    # LEGAL value is a small wrong answer rather than an error (RY-ORACLE's
    # trap T7).  They were omitted here while bisect_scaled.py had no R_Y
    # model, which made them harmless; with the model in place the defaults
    # (4 and 8) made the CLEAN control V0s report a divergence at R_Y-1.
    # These two numbers are `cap_generics seq`'s own -gKV_BLOCK / -gN_ROT.
    seq)  echo "--blocks 4 --attn-int 2 --attn-hd 64 --norm anchor
                --kv-block 16 --n-rot 16" ;;
    *) echo "" ;;
  esac
}

cap_ntok() { case "$1" in seq) echo 3 ;; *) echo 1 ;; esac; }

# cap_run <dir> <cfg> <mutdir|"">  -- analyze and run, leaving <dir>/run/cap.txt
cap_run() {
  local dir="$1" cfg="$2" mutdir="$3"
  rm -rf "$dir"; mkdir -p "$dir/run"
  local f src
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      return 2
    fi
  done
  ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex" "$dir/run/" 2>/dev/null
  ( cd "$dir/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed \
      --workdir=".." tb_llama_top $(cap_generics "$cfg") -gNRUNS=1 \
      -gCAPTURE=cap.txt --max-stack-alloc=0 --stop-time="$STOP" \
      > run.log 2>&1 )
  [ -s "$dir/run/cap.txt" ]
}

# cap_baseline <cfg>  -- the clean capture for a configuration, cached
cap_baseline() {
  local cfg="$1"
  local b="$SCRATCH/base_$cfg"
  if [ ! -s "$b/run/cap.txt" ]; then
    cap_run "$b" "$cfg" "" || { echo "BASELINE FOR $cfg DID NOT RUN"; return 2; }
  fi
  echo "$b/run/cap.txt"
}

# run_cap <tag> <desc> <mutdir|""> <cfg>
run_cap() {
  local tag="$1" desc="$2" mutdir="$3" cfg="$4"
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local base; base="$(cap_baseline "$cfg")" || { echo "$tag  NO BASELINE"; return; }
  local dir="$SCRATCH/$tag"
  if ! cap_run "$dir" "$cfg" "$mutdir"; then
    echo "$tag  KILLED(ABORT) -- no capture was written -- $desc"
    sed -n 1,3p "$dir/analyze.log" 2>/dev/null
    return
  fi
  local nt; nt="$(cap_ntok "$cfg")"
  local capv="clean" orav="clean" t line
  for (( t=0; t<nt; t++ )); do
    line=$( cd tools/ref9b && python3 seam_diff.py "$base" "$dir/run/cap.txt" \
              --tok "$t" 2>/dev/null | grep -a "^FIRST DIVERGENCE" )
    if [ -n "$line" ]; then capv="tok $t: $line"; break; fi
  done
  for (( t=0; t<nt; t++ )); do
    line=$( cd tools/ref9b && python3 bisect_scaled.py "$dir/run/cap.txt" \
              $(cap_oracle_args "$cfg") --tok "$t" 2>/dev/null \
              | grep -a "^FIRST DIVERGENCE" )
    if [ -n "$line" ]; then orav="tok $t: $line"; break; fi
  done
  if [ "$capv" = "clean" ] && [ "$orav" = "clean" ]; then
    echo "$tag  SURVIVED   -- $desc"
  else
    echo "$tag  KILLED     -- $desc"
  fi
  echo "        CAPTURE $capv" | cut -c1-200
  echo "        ORACLE  $orav" | cut -c1-200
}

echo "=== V: the same mutants, scored on the NUMBERS ==============="
run_cap V0r "CONTROL: the clean design, real-path configuration" "" real
run_cap V0s "CONTROL: the clean design, KV-cache configuration" "" seq

D=$(mutate_rtl VN2 rtl/llama_top.vhd \
  "                if k = n-1 then k := 0; st := S_DONE; else k := k + 1; end if;" \
  "                if k = n-2 then k := 0; st := S_DONE; else k := k + 1; end if;")
[ -n "$D" ] && run_cap VN2 "N2 again: the real rmsnorm's writeback drops its last element" "$D" real

D=$(mutate_rtl VR7 rtl/llama_top.vhd \
  "        if rst = '1' then      c_seqrst <= '1';
        elsif c_srtk = '1' then c_seqrst <= '0'; end if;" \
  "        if rst = '1' or tok_done_i = '1' then c_seqrst <= '1';
        elsif c_srtk = '1' then c_seqrst <= '0'; end if;")
[ -n "$D" ] && run_cap VR7 "R7 again: the v_ref sequence reset is issued per TOKEN, not per sequence" "$D" seq

# VR7 SURVIVES on the shipping design and that is CORRECT, not a regression of
# this file.  Until 2026-08-29 rtl/attn_block.vhd's v_ref fold had no layer
# index (defect C1), every attention layer folded into every other one, and
# R7's single reset disturbed that carry.  With C1 fixed there is nothing for
# it to disturb: MEASURED, `cmp` of the clean and the R7 capture is IDENTICAL,
# at NTOK 3, 5 and 8.  See the R7b comment above for why R7 only ever resets
# once, and docs/debugging/2026-08-29_c1-vref-layer.md for the whole chain.
D=$(mutate_rtl VR7b rtl/llama_top.vhd \
  "    srp : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then      c_seqrst <= '1';
        elsif c_srtk = '1' then c_seqrst <= '0'; end if;
      end if;
    end process;" \
  "    srp : process(clk) is
      variable tdq : std_logic := '0';
    begin
      if rising_edge(clk) then
        if rst = '1' then      c_seqrst <= '1';
        elsif c_srtk = '1' then c_seqrst <= '0'; end if;
        if tok_done_i = '1' and tdq = '0' then c_seqrst <= '1'; end if;
        tdq := tok_done_i;
      end if;
    end process;")
[ -n "$D" ] && run_cap VR7b "R7's description actually implemented: a genuine per-token-boundary v_ref reset" "$D" seq

D=$(mutate_rtl VA1 rtl/matvec_core.vhd \
  "            re2_shv(rr) <= round_shift(re1_acc(rr), os_rep(rr));" \
  "            re2_shv(rr) <= floor_shr(re1_acc(rr), os_rep(rr));")
[ -n "$D" ] && run_cap VA1 "subsystem A's spec 7.4 site 2 truncates instead of rounding -- one LSB, and the bench leaves R_X(0) unchanged" "$D" real

echo "=== scratch: $SCRATCH"
