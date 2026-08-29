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
       rtl/attn_block.vhd rtl/attn_kv_axi.vhd rtl/gdn_block.vhd
       rtl/matvec_int4.vhd rtl/llama_top.vhd sim/tb_llama_top.vhd"

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
D=$(mutate_rtl N1 rtl/llama_top.vhd \
  "          w_mant => W_CONST, w_exp => NORM_W_EXP," \
  "          w_mant => W_CONST, w_exp => NORM_W_EXP + 20,")
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

echo "=== scratch: $SCRATCH"
