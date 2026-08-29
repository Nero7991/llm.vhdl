#!/usr/bin/env bash
# Mutation test for the COMPOSITION in rtl/gdn_block.vhd, against
# sim/tb_gdn_block_vec.vhd and ref/gdn_block_vec.c.
#
# WHAT THIS MEASURES, AND WHY IT IS NOT THE SAME AS THE UNIT HARNESSES.
# Subsystem B has eight mutation harnesses already (gdn_conv, gdn_recur,
# gdn_scalar, gdn_silu, gdn_emit_chain, gdn_head_emit, gdn_y_emit,
# gdn_exp_capture) and every one of them mutates a LEAF.  None of them can
# reach a wiring error, because a wiring error is not inside any leaf.  Every
# mutation below is a WIRE: which buffer feeds which unit, which head reads
# which operand, which exponent describes which segment, which of two L2
# outputs is kept.
#
# THREE VERDICTS, NOT TWO.  sim/mutverdict.py classifies each run as PASS,
# KILLED or ABORT:<reason>, so a mutant that DIED -- an elaboration error, a
# VHDL bound check, the design's own assert, a wedge to --stop-time -- is not
# counted as a kill.  Every harness in this repo scored those as kills until
# 2026-08-29, and a harness that cannot tell a kill from a crash has not been
# shown to measure anything.
#
# THE CONTROL ROW IS NOT DECORATION.  The first row is the UNMUTATED design
# through the identical path: same copy, same generator invocation, same
# analysis order, same ghdl arguments.  A bench configuration that wedges on
# clean RTL makes every "kill" in the column unearned, and the only way to see
# that is to run the clean design through the mutate path rather than through
# sim/regress.sh.
#
# DEFECT B-BLK-1 IS FIXED, so this harness no longer runs quarantined.  The
# vectors are generated at kmap=mod -- the model's mapping, which is now also
# the RTL's -- and the bench runs at its KMAP_DIV=false default, exactly as
# sim/regress.sh's gate row does.  Row M01 is the REGRESSION: it puts the
# contiguous grouping back, and it must be KILLED, which is what shows this
# harness can see the mapping at all.
# See docs/debugging/2026-08-29_gdn-block-oracle.md.
#
# Nothing under rtl/, ref/ or sim/ is edited.  Every mutation is applied to a
# COPY in a private scratch directory.
#
# Usage: bash sim/mutate_gdn_block.sh
# Env:   SCRATCH=<dir>   KEEP=1   ONLY=<tag>
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

RTL=rtl/gdn_block.vhd
REF=ref/gdn_block_vec.c
TB=sim/tb_gdn_block_vec.vhd
TBE=tb_gdn_block_vec
VEC=gdn_block_vec.txt
# The shape and the kmap, kept identical to sim/regress.sh's tb_vector_args row.
GENARGS="2 4 32 2 2 mod"
RUNARGS="--stop-time=200ms --max-stack-alloc=0"

# The transitive closure of the design under test, in analysis order.  Taken
# from sim/regress.sh's own plan for this testbench rather than hand-listed, so
# it cannot drift: the plan row is
#   rtl/fixed_luts_pkg rtl/fixed_pkg rtl/util_pkg rtl/gdn_conv
#   rtl/gdn_exp_capture rtl/gdn_head_emit rtl/gdn_recur_pipe rtl/gdn_scalar
#   rtl/gdn_silu rtl/gdn_y_emit rtl/l2norm_rs rtl/rmsnorm_bf
#   rtl/gdn_emit_chain rtl/gdn_block
DEPS="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
      rtl/gdn_conv.vhd rtl/gdn_exp_capture.vhd rtl/gdn_head_emit.vhd
      rtl/gdn_recur_pipe.vhd rtl/gdn_scalar.vhd rtl/gdn_silu.vhd
      rtl/gdn_y_emit.vhd rtl/l2norm_rs.vhd rtl/rmsnorm_bf.vhd
      rtl/gdn_emit_chain.vhd"

GHDL="${GHDL:-ghdl}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"
echo "scratch: $SCRATCH"

NKILL=0; NSURV=0; NABORT=0; NTOT=0
CONTROL_VERDICT="NOT RUN"
declare -a SURVIVORS=()
declare -a ABORTED=()

# Apply old/new pairs to one file.  An anchor that does not match EXACTLY once
# aborts the row: a mutation applied zero times is a false survivor, and one
# applied twice is not the mutation described.
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
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES, expected 1\n" % (i//2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
}

# $1 tag, $2 class (rtl|c|control), $3 desc, then any of
#   --rtl  old new ...      mutate rtl/gdn_block.vhd
#   --c    old new ...      mutate ref/gdn_block_vec.c
#   --depf <path>           name a DEPENDENCY of gdn_block to mutate instead
#   --dep  old new ...      the pairs applied to that dependency
#   --run  <ghdl generic>   extra run arguments for THIS row only
#
# --depf exists because the layer index does not live in gdn_block.vhd: the
# store it addresses is rtl/gdn_exp_capture.vhd, and a harness that can only
# mutate the top level cannot ask whether the store has a layer dimension.
# --run exists because a mutation's verdict can DEPEND on how the bench is
# configured, and the pair of verdicts is the measurement -- see M13/M13Z.
mutate() {
  local tag="$1" cls="$2" desc="$3"; shift 3
  if [ -n "$ONLY" ] && [ "$tag" != "$ONLY" ]; then return; fi
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"

  local mode="" depf="" rtl_args=() c_args=() dep_args=() run_args=()
  for a in "$@"; do
    case "$a" in
      --rtl)  mode=rtl ;;
      --c)    mode=c ;;
      --dep)  mode=dep ;;
      --depf) mode=depf ;;
      --run)  mode=run ;;
      *) case "$mode" in
           rtl)  rtl_args+=("$a") ;;
           c)    c_args+=("$a") ;;
           dep)  dep_args+=("$a") ;;
           depf) depf="$a" ;;
           run)  run_args+=("$a") ;;
         esac ;;
    esac
  done

  if [ -n "$depf" ]; then
    if [ ${#dep_args[@]} -gt 0 ]; then
      if ! patch_file "$depf" "$dir/$(basename "$depf")" "${dep_args[@]}" \
             2>"$dir/anchor.log"; then
        printf '%-10s %-7s ANCHOR-FAILED  %s\n' "$tag" "$cls" "$desc"
        sed 's/^/             /' "$dir/anchor.log"
        NABORT=$((NABORT+1)); ABORTED+=("$tag ANCHOR"); return
      fi
    else
      cp "$depf" "$dir/$(basename "$depf")"
    fi
  fi

  if [ ${#rtl_args[@]} -gt 0 ]; then
    if ! patch_file "$RTL" "$dir/gdn_block.vhd" "${rtl_args[@]}" 2>"$dir/anchor.log"; then
      printf '%-10s %-7s ANCHOR-FAILED  %s\n' "$tag" "$cls" "$desc"
      sed 's/^/             /' "$dir/anchor.log"
      NABORT=$((NABORT+1)); ABORTED+=("$tag ANCHOR"); return
    fi
  else
    cp "$RTL" "$dir/gdn_block.vhd"
  fi
  if [ ${#c_args[@]} -gt 0 ]; then
    if ! patch_file "$REF" "$dir/gen.c" "${c_args[@]}" 2>"$dir/anchor.log"; then
      printf '%-10s %-7s ANCHOR-FAILED  %s\n' "$tag" "$cls" "$desc"
      sed 's/^/             /' "$dir/anchor.log"
      NABORT=$((NABORT+1)); ABORTED+=("$tag ANCHOR"); return
    fi
  else
    cp "$REF" "$dir/gen.c"
  fi

  if ! cc -O2 -w -I "$REPO/ref" -o "$dir/gen" "$dir/gen.c" -lm 2>"$dir/cc.log"; then
    printf '%-10s %-7s ABORT:CC       %s\n' "$tag" "$cls" "$desc"
    NABORT=$((NABORT+1)); ABORTED+=("$tag CC"); return
  fi
  # shellcheck disable=SC2086
  ( cd "$dir" && ./gen "$VEC" $GENARGS ) >/dev/null 2>"$dir/gen.err"
  if [ ! -s "$dir/$VEC" ]; then
    printf '%-10s %-7s ABORT:GEN      %s\n' "$tag" "$cls" "$desc"
    sed -n 1,3p "$dir/gen.err" | sed 's/^/             /'
    NABORT=$((NABORT+1)); ABORTED+=("$tag GEN"); return
  fi

  local ok=1
  for f in $DEPS; do
    if [ -n "$depf" ] && [ "$f" = "$depf" ]; then
      "$GHDL" -a --std=08 -frelaxed --workdir="$dir" \
        "$dir/$(basename "$depf")" >>"$dir/analyze.log" 2>&1 || ok=0
    else
      "$GHDL" -a --std=08 -frelaxed --workdir="$dir" "$REPO/$f" >>"$dir/analyze.log" 2>&1 || ok=0
    fi
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir" "$dir/gdn_block.vhd" >>"$dir/analyze.log" 2>&1 || ok=0
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir" "$REPO/$TB" >>"$dir/analyze.log" 2>&1 || ok=0
  if [ "$ok" = 0 ]; then
    cp "$dir/analyze.log" "$dir/run.log"
    local v
    v=$(python3 "$REPO/sim/mutverdict.py" "$dir/run.log" "$TBE" 1 "$REPO/$TB")
    printf '%-10s %-7s %-14s %s\n' "$tag" "$cls" "$v" "$desc"
    NABORT=$((NABORT+1)); ABORTED+=("$tag $v"); return
  fi

  local rc=0
  # shellcheck disable=SC2086
  ( cd "$dir" && timeout 900 "$GHDL" -r --std=08 -frelaxed --workdir="$dir" \
      "$TBE" $RUNARGS "${run_args[@]+"${run_args[@]}"}" ) \
      >"$dir/run.log" 2>&1 || rc=$?
  # ghdl prints a metavalue warning per cycle on this design; it is noise and
  # would swamp the log and the classifier alike.
  grep -v 'metavalue detected' "$dir/run.log" > "$dir/run.clean" && \
    mv "$dir/run.clean" "$dir/run.log"

  local v
  v=$(python3 "$REPO/sim/mutverdict.py" "$dir/run.log" "$TBE" "$rc" "$REPO/$TB")
  # The control is NOT a mutation and must never be counted as a survivor: it
  # is the row that says whether the other rows mean anything at all.
  if [ "$cls" = control ]; then
    CONTROL_VERDICT="$v"
    NTOT=$((NTOT-1))
  else
    case "$v" in
      PASS)   NSURV=$((NSURV+1));  SURVIVORS+=("$tag  $desc") ;;
      KILLED) NKILL=$((NKILL+1)) ;;
      *)      NABORT=$((NABORT+1)); ABORTED+=("$tag $v") ;;
    esac
  fi
  local detail
  detail=$(grep -m1 -E 'y mismatches|y_exp |disagree with the oracle|is 1, the oracle says' "$dir/run.log" \
           | sed 's/.*tb_gdn_block_vec: //' | cut -c1-72)
  printf '%-10s %-7s %-14s %s\n' "$tag" "$cls" "$v" "$desc"
  [ -n "$detail" ] && printf '%-33s %s\n' "" "$detail"
}

echo
printf '%-10s %-7s %-14s %s\n' TAG CLASS VERDICT DESCRIPTION
printf '%-10s %-7s %-14s %s\n' --- ----- ------- -----------

# ---------------------------------------------------------------------------
# THE CONTROL.  Unmutated, through the identical path.  If this is not PASS,
# every other row in the table is meaningless and the table is not a
# measurement.
# ---------------------------------------------------------------------------
mutate CONTROL control "UNMUTATED design through the same mutate path"

# ---------------------------------------------------------------------------
# The wiring.  Every one of these is invisible to sim/tb_gdn_block, which
# compares the block's dump against ITSELF across producer skews.
# ---------------------------------------------------------------------------

# M01 REINTRODUCES defect B-BLK-1: value head h fed from key head
# h/(VAL_HEADS/KEY_HEADS), the contiguous grouping the RTL carried until
# 2026-08-29, against kmap=mod vectors.  It must be KILLED.  If it ever
# survives, the harness has stopped seeing the key-head mapping and every
# other row in this table is suspect.
#
# Note the mutation writes the divisor out rather than naming VPK: that
# constant was DELETED with the defect, so an anchor mentioning it would fail
# to compile rather than fail to match, which is a much less useful signal.
mutate M01 rtl "key-head map h mod KH -> h/(VH/KH) (REINTRODUCES B-BLK-1)" \
  --rtl 'base := (vh mod KEY_HEADS)*DIM*16;' \
        'base := (vh/(VAL_HEADS/KEY_HEADS))*DIM*16;'

mutate M02 rtl "L2 input: the q head is normed from the k segment buffer" \
  --rtl '              l2_x <= qbuf(base+DIM*16-1 downto base);' \
        '              l2_x <= kbuf(base+DIM*16-1 downto base);'

mutate M03 rtl "L2 output: q_s takes the exp-15 output instead of exp-18" \
  --rtl 'qsb(base+DIM*16-1 downto base) <= l2_q;   -- q path, 1/sqrt(DIM)' \
        'qsb(base+DIM*16-1 downto base) <= l2_k;   -- q path, 1/sqrt(DIM)'

mutate M04 rtl "L2 output: k_n takes the exp-18 output instead of exp-15" \
  --rtl 'knb(base+DIM*16-1 downto base) <= l2_k;   -- k path' \
        'knb(base+DIM*16-1 downto base) <= l2_q;   -- k path'

mutate M05 rtl "silu output routing: the q buffer is filled from segment 1" \
  --rtl '          if    cv_seg_i = 0 then
            qbuf(base+CONV_LANES*16-1 downto base) <= co_data;' \
        '          if    cv_seg_i = 1 then
            qbuf(base+CONV_LANES*16-1 downto base) <= co_data;'

mutate M06 rtl "e_v taken from the k segment instead of the v segment" \
  --rtl 'rp_cev   <= seg_e(2);' \
        'rp_cev   <= seg_e(1);'

# M07 SURVIVES, and it is reported under its own name because a mutation that
# does not bite measures the check's resolution floor.  MEASURED at CV_GAP = 0,
# 1, 3 and 7, with the unmutated CONTROL re-run at each: 0 of 256 y mismatches
# every time, both columns.
#
# It is not a hole in this bench so much as a statement about the schedule.
# gdn_block's phases are strictly sequential, so by the time `seg_e(seg)` is
# taken gdn_conv is back in S_IDLE and its live `e_seg` still holds the right
# value -- rtl/gdn_block.vhd's own comment at that line says exactly this.  The
# frozen copy is defence against the OVERLAPPED schedule the file's closing
# note describes and does not implement.  To make this mutation observable you
# would have to start segment s+1 before segment s's exponent is consumed, and
# nothing in this block can currently do that.
mutate M07 rtl "segment exponent captured LIVE instead of from the frozen copy" \
  --rtl 'seg_e(seg) <= cs_eseg;' \
        'seg_e(seg) <= cv_eseg;'

mutate M08 rtl "tk0 dropped: the first token reads the resident state" \
  --rtl 'rp_ctk0  <= tk0;' \
        "rp_ctk0  <= '0';"

mutate M09 rtl "the decay gate and beta are swapped into the recurrence" \
  --rtl 'rp_eg      <= eg_b(vh);
            rp_beta    <= beta_b(vh);' \
        'rp_eg      <= beta_b(vh);
            rp_beta    <= eg_b(vh);'

mutate M10 rtl "the scalar group is stored one value head late" \
  --rtl 'eg_b(vh)   <= sp_eg;' \
        'eg_b((vh+1) mod VAL_HEADS)   <= sp_eg;'

mutate M11 rtl "v column index off by one within the head" \
  --rtl 'base     := (st_rh_i*DIM + st_rc_i)*16;' \
        'base     := (st_rh_i*DIM + ((st_rc_i+1) mod DIM))*16;'

mutate M12 rtl "the state column exponent is read as a constant" \
  --rtl 'rp_cse   <= se_rdata;' \
        'rp_cse   <= to_signed(10, 8);'

# ---------------------------------------------------------------------------
# THE LAYER DIMENSION.  One gdn_block is time-shared across every GDN layer
# (rtl/llama_top.vhd:2980 sweeps b_layer), and `layer` is used in exactly ONE
# place inside rtl/gdn_block.vhd: gdn_exp_capture's rd_layer.  Both benches
# drove layer => 0 until 2026-08-29, which made that one use untestable.
# ---------------------------------------------------------------------------

# M13 and M13Z are the SAME MUTATION at two bench configurations, and the PAIR
# is the measurement.  KILLED at DUT_LAYER=1, PASS at DUT_LAYER=0 -- because at
# layer 0 a DUT that ignores the port reads exactly the entry it should.  M13Z
# is therefore an EXPECTED SURVIVOR and is reported as one rather than hidden:
# it is this bench's resolution floor on the layer index, and it is the reason
# sim/tb_gdn_block_vec.vhd defaults DUT_LAYER to 1.
mutate M13 rtl "exponent-store read layer hardwired to 0 (layer index ignored)" \
  --rtl 'rd_layer => layer,' \
        'rd_layer => 0,'

mutate M13Z rtl "M13 again at DUT_LAYER=0 -- EXPECTED SURVIVOR, the floor" \
  --run '-gDUT_LAYER=0' \
  --rtl 'rd_layer => layer,' \
        'rd_layer => 0,'

# M14 is defect C1's shape transplanted onto B: the store loses its layer
# dimension entirely, so every layer's tap exponents fold into every other
# layer's.  It is killed here only because the bench now writes DECOY captures
# into every layer it is not running; with the pre-2026-08-29 bench, which
# captured layer 0 and nothing else, this mutation was bit-exact green --
# MEASURED, 0 of 256 y mismatches.  See
# docs/debugging/2026-08-29_b-layer-dimension.md.
mutate M14 rtl "gdn_exp_capture loses its layer dimension (defect C1's shape)" \
  --depf rtl/gdn_exp_capture.vhd \
  --dep 'a := cap_layer * SEGS + cap_seg;' \
        'a := cap_seg;' \
        'a := rd_layer * SEGS + rd_seg;' \
        'a := rd_seg;'

# ---------------------------------------------------------------------------
# C-class rows.  These mutate the ORACLE, not the design, and exist to show
# that the comparison is two-sided: a bench that only ever saw the RTL move
# would be measuring half of what it claims to.
# ---------------------------------------------------------------------------
mutate C01 c "oracle: silu dropped from the conv output (spec 1.1(e))" \
  --c '            silu[s*CHMAX + c] = (int)mv4i_round_shift((int64_t)sm * sig, 15);' \
      '            silu[s*CHMAX + c] = (int)sm; (void)sig;'

mutate C02 c "oracle: masked conv taps are included in the products" \
  --c '                if (!tv[t]) continue;                 /* spec 1.6 masking */' \
      '                if (0) continue;                      /* spec 1.6 masking */'

mutate C03 c "oracle: the z gate multiplies before the norm, not after" \
  --c '            prod_o[h*D+j] = r.o[j];' \
      '            prod_o[h*D+j] = o_head[j];'

echo
echo "CONTROL (unmutated, same path): $CONTROL_VERDICT"
if [ "$CONTROL_VERDICT" != PASS ]; then
  echo
  echo "  ####################################################################"
  echo "  #  THE CONTROL DID NOT PASS.  EVERY OTHER ROW IN THIS TABLE IS     #"
  echo "  #  MEANINGLESS: a bench configuration that fails on clean RTL      #"
  echo "  #  scores every mutation as a kill it did not earn.                #"
  echo "  ####################################################################"
fi
echo "MUTATIONS $NTOT   KILLED $NKILL   SURVIVED $NSURV   ABORT $NABORT"
if [ "${#SURVIVORS[@]}" -gt 0 ]; then
  echo
  echo "SURVIVORS -- these are what the bench CANNOT see:"
  for s in "${SURVIVORS[@]}"; do echo "  $s"; done
fi
if [ "${#ABORTED[@]}" -gt 0 ]; then
  echo
  echo "ABORTED -- counted apart from kills, because nothing was measured about"
  echo "the checker's resolution in these rows:"
  for s in "${ABORTED[@]}"; do echo "  $s"; done
fi
if [ "${KEEP:-0}" = 0 ] && [ -z "${SCRATCH_KEPT:-}" ]; then
  echo
  echo "(scratch kept at $SCRATCH; set KEEP=0 has no effect, remove it by hand)"
fi
