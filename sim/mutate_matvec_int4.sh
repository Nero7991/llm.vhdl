#!/usr/bin/env bash
# Mutation test for rtl/matvec_int4.vhd -- subsystem A's top level.
#
# WHY THIS FILE, WHICH LOOKS LIKE IT HAS NOTHING IN IT.  matvec_int4 is 205
# lines and almost all of them are structural: three instantiations, seven
# scalar conversions, two address slices and two debug taps.  It was named in
# row N8 of docs/WORKLOG.md as the one file in subsystem A with no mutation
# script at all -- every other mutate_*.sh that mentions it lists it as a
# DEPENDENCY, compiled and never edited.  That is exactly the shape of thing a
# per-unit evidence class misses: matvec_core is verified, weight_streamer is
# verified, act_mem_striped is verified, and NOTHING was checking that the
# right wire goes to the right port between them.
#
# On 2026-08-29 this became the part of the design that has run on silicon, so
# the glue is worth a table of its own.
#
# ---------------------------------------------------------------------------
# TWO JUDGES, AND THE SECOND ONE IS NOT REDUNDANT
# ---------------------------------------------------------------------------
#   small  sim/tb_matvec_int4  ROWS_IF=4  AXI_DW=128 NPORTS_W=4  NPORTS_S=1
#                              MAXCOLS=512 MAXROWS_BFP=64 ADDR_W=64
#                              M=8 K=96 from ref/matvec_int4.c --trace
#   fk33   sim/tb_matvec_fk33  ROWS_IF=48 AXI_DW=256 NPORTS_W=24 NPORTS_S=3
#                              MAXCOLS=4096 MAXROWS_BFP=192 ADDR_W=64 BASE_HI=1
#                              100 rows of a REAL .mv4i tensor over 27 masters
#
# NPORTS_S is the reason both are run.  It DEFAULTS TO 1, and at 1 every port
# range in this file collapses to the expression it was before the generic
# existed -- so the `small` judge cannot distinguish `NPORTS_S` from the
# literal 1 anywhere.  Only `fk33` has three scale sub-regions.  Symmetrically,
# GRP = NPORTS_S*AXI_DW/(ROWS_IF*16) is 2 in `small` and 1 in `fk33`, so
# s_beats and w_beats are DIFFERENT numbers only in `small` -- which is why
# swapping them (row C7) is caught there and survives at the FK33 shape.  Two
# judges, two disjoint blind spots, and the caught-by column says which.
#
# `fk33` needs a real packed tensor that is NOT in git.  Its path comes from
# MV4I_FK33_FILE, defaulting to the same one sim/regress.sh uses.  If it is
# missing the judge is SKIPPED and every row says so -- a missing judge is
# never silently scored as a survival.
#
# ---------------------------------------------------------------------------
# FOUR VERDICTS.  ONLY TWO OF THEM ARE EVIDENCE ABOUT THE BENCHES.
# ---------------------------------------------------------------------------
#   KILL   a bench's own diagnostic fired -- a row mismatch, a wrong y_exp, a
#          wrong row count, a rejected descriptor.
#   ABORT  ghdl stopped the run: an RTL assert, a bound check, or a hang.
#          Counted as caught, reported separately.
#   SURV   both judges printed their success line.
#   VOID   the anchor did not match, or the mutant did not analyze or did not
#          ELABORATE.  A mutation that will not build has tested NOTHING and
#          is never counted as a kill -- that is the specific error that once
#          made a script report seven of seven CAUGHT while ghdl could not
#          open a file.  Generic forwarding is mutated here, and several of
#          those edits change a port WIDTH, so VOID is a routine outcome and
#          not a script bug; it is printed in full and listed at the bottom.
#
# Nothing under rtl/ or ref/ is edited; every mutation is applied to a COPY.
#
# Usage: bash sim/mutate_matvec_int4.sh
# Env:   SCRATCH=<dir>  ONLY=<tag-substring>  MV4I_FK33_FILE=<path>
set -uo pipefail

# SELF-ISOLATE -- see sim/regress.sh for why.  bash reads a script lazily by
# byte offset, so an edit while an instance runs resumes it mid-token.
if [ -z "${MUT_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_matvec_int4.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_matvec_int4.sh: the private copy does not parse -- the" \
         "original was probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUT_ISOLATED=1 MUT_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUT_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/matvec_int4.vhd
DEPS="rtl/util_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/stream_fifo.vhd
      rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd rtl/axi_rd_port.vhd
      rtl/weight_streamer.vhd rtl/act_mem_striped.vhd rtl/matvec_core.vhd"
TB_SMALL=sim/tb_matvec_int4.vhd
TB_FK33=sim/tb_matvec_fk33.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
GHDL="${GHDL:-ghdl}"
MV4I="${MV4I_FK33_FILE:-/mnt/storage/llama-models/qwen35-9b-mv4i/blk.11.attn_k.weight.mv4i}"
mkdir -p "$SCRATCH"

NKILL=0; NABORT=0; NSURV=0; NVOID=0; NTOT=0
SURV_TAGS=""; VOID_TAGS=""

# ---------------------------------------------------------------------------
# THE UNIQUENESS GATE.  MEASURED 2026-08-29: sim/mv4i_desc_mutations.py's
# --apply returns on the FIRST row whose name matches, so a duplicated tag
# tests one edit twice and another never, and the table looks full either way.
# TRACK ERRINFO hit it.  Teeth-checked immediately below.
# ---------------------------------------------------------------------------
uniq_gate() {
  python3 - "$1" <<'PY'
import re, sys, collections
tags = re.findall(r'^\s*mutate\s+([A-Za-z0-9_]+)\s', open(sys.argv[1]).read(), re.M)
dup = [t for t, n in collections.Counter(tags).items() if n > 1]
if dup:
    sys.stderr.write("DUPLICATE MUTATION TAGS: %s\n" % " ".join(sorted(dup)))
    sys.exit(3)
print("%d tags, all distinct" % len(tags))
PY
}
SELF="${MUT_REAL_DIR}/mutate_matvec_int4.sh"
if ! UG=$(uniq_gate "$SELF" 2>&1); then echo "REFUSING TO RUN: $UG"; exit 3; fi
echo "tag uniqueness gate: $UG"
sed 's/^mutate W2 /mutate W1 /' "$SELF" >"$SCRATCH/teeth_dup.sh"
if uniq_gate "$SCRATCH/teeth_dup.sh" >/dev/null 2>&1; then
  echo "TEETH FAILED: the uniqueness gate accepted a duplicated tag"; exit 3
fi
echo "tag uniqueness gate TEETH: a duplicated W1 is refused -- the gate bites"

# ---------------------------------------------------------------------------
# VECTORS.  Both judges are fed by a GENERATED trace, never by a file left in
# sim/ -- see the tr.txt note in sim/regress.sh for why a golden nothing
# regenerates is a golden anything can replace in silence.
# ---------------------------------------------------------------------------
VEC="$SCRATCH/vec"
mkdir -p "$VEC"
if ! cc -O2 -w -I "$REPO/ref" -o "$VEC/gen_tr" "$REPO/ref/matvec_int4.c" -lm \
     >"$VEC/build.log" 2>&1; then
  echo "REFUSING TO RUN: ref/matvec_int4.c did not build"; tail -5 "$VEC/build.log"; exit 2
fi
if ! "$VEC/gen_tr" --trace "$VEC/tr.txt" 8 96 4 0 >/dev/null 2>&1; then
  echo "REFUSING TO RUN: ref/matvec_int4 --trace 8 96 4 0 failed"; exit 2
fi

HAVE_FK33=1
if [ ! -r "$MV4I" ]; then
  HAVE_FK33=0
  echo "NOTE: the fk33 judge is SKIPPED -- MV4I_FK33_FILE is not readable:"
  echo "      $MV4I"
  echo "      Every row below is judged by 'small' ALONE.  NPORTS_S > 1 and"
  echo "      ROWS_IF = 48 are then untested and a SURVIVED verdict means"
  echo "      less than it looks like it means."
else
  if ! cc -O2 -w -I "$REPO/ref" -o "$VEC/gen_fk" "$REPO/ref/mv_fk33_tr.c" -lm \
       >>"$VEC/build.log" 2>&1; then
    echo "REFUSING TO RUN: ref/mv_fk33_tr.c did not build"; tail -5 "$VEC/build.log"; exit 2
  fi
  if ! ( cd "$VEC" && "$VEC/gen_fk" mv_fk33_tr.txt "$MV4I" 100 5 ) >/dev/null 2>&1; then
    echo "REFUSING TO RUN: ref/mv_fk33_tr failed on $MV4I"; exit 2
  fi
fi

analyze_into() {   # analyze_into <workdir> <mutated-rtl> <logfile>
  local wd="$1" mut="$2" log="$3" f
  for f in $DEPS; do
    "$GHDL" -a --std=08 -frelaxed --workdir="$wd" "$REPO/$f" >>"$log" 2>&1 || return 1
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$wd" "$mut" >>"$log" 2>&1 || return 1
  "$GHDL" -a --std=08 -frelaxed --workdir="$wd" "$REPO/$TB_SMALL" >>"$log" 2>&1 || return 1
  if [ "$HAVE_FK33" = 1 ]; then
    "$GHDL" -a --std=08 -frelaxed --workdir="$wd" "$REPO/$TB_FK33" >>"$log" 2>&1 || return 1
  fi
  return 0
}

# run_judge <workdir> <rundir> <judge>  -> KILL|... ABORT|... SURV|... VOID|...
run_judge() {
  local wd="$1" rd="$2" j="$3" rc
  mkdir -p "$rd"
  case "$j" in
    small)
      cp "$VEC/tr.txt" "$(dirname "$rd")/tr.txt"
      ( cd "$rd" && timeout 600 "$GHDL" -r --std=08 -frelaxed --workdir="$wd" \
          tb_matvec_int4 -gTRACE=../tr.txt -gRI=4 -gSTALL=3 \
          --stop-time=30ms --stop-delta=1000000 ) >"$rd/log" 2>&1
      rc=$? ;;
    fk33)
      cp "$VEC/mv_fk33_tr.txt" "$rd/mv_fk33_tr.txt"
      ( cd "$rd" && timeout 900 "$GHDL" -r --std=08 -frelaxed --workdir="$wd" \
          tb_matvec_fk33 --stop-time=50ms --stop-delta=1000000 ) >"$rd/log" 2>&1
      rc=$? ;;
  esac
  python3 - "$rd/log" "$rc" "$j" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc, j = int(sys.argv[2]), sys.argv[3]
log = "\n".join(l for l in log.splitlines()
                if "metavalue detected" not in l and "shared variable" not in l)
tb   = "tb_matvec_int4" if j == "small" else "tb_matvec_fk33"
good = ("subsystem A matches ref/matvec_int4.c from the packed bytes up"
        if j == "small" else
        "subsystem A is bit-exact with ref/matvec_int4.c from the real .mv4i bytes up")

# ELABORATION comes first and is VOID, not a kill.  Several generic-forwarding
# mutations change a port width, and ghdl reports that at run time on the mcode
# backend, so it arrives in this log looking exactly like a failure.
if re.search(r"^[^\n]*:error:[^\n]*(width|length|port|bound of|not constrained)", log, re.M | re.I) \
   and "(assertion" not in log and "(report" not in log:
    m = re.search(r"^[^\n]*:error:([^\n]*)", log, re.M)
    print("VOID|elaboration: %s" % m.group(1).strip()[:52]); raise SystemExit

# THE CHECKER'S OWN DIAGNOSTICS NEXT.  A run that reports its own error and
# then aborts is a CAUGHT mutation; reading the abort first scores it as the
# weaker verdict, which is the mistake A-MUT made and paid a run for.
diag = re.search(r"%s\.vhd:\d+:\d+:@[^:]*:\(report error\): (.+)" % tb, log)
tbf  = re.search(r"%s\.vhd:\d+:\d+:@[^:]*:\((?:assertion|report) failure\): (.+)" % tb, log)
rtlg = re.search(r"(?:matvec_core|weight_streamer|act_mem_striped|axi_rd_port|"
                 r"axi_rd_fsm|stream_fifo|async_fifo|matvec_int4)\.vhd:\d+:\d+:@[^:]*:"
                 r"\((?:assertion|report) failure\): (.+)", log)
# The path in "bound check failure at /some/scratch/dir/x.vhd:123" is noise
# that fills the detail column and differs on every run, so it is dropped.
bound = re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*|overflow[^\n]*)", log)
if bound:
    bd = re.sub(r"\s+at\s+\S+\.vhd:\d+(:\d+)?", "", bound.group(1))
hung = re.search(r"simulation stopped (by --stop-time|@)", log)
lang = re.search(r"[^\s:]+:error: (.+)", log)

if good in log and rc == 0:
    print("SURV|ok")
elif diag:
    print("KILL|%s" % diag.group(1).strip()[:52])
elif tbf:
    print("KILL|%s" % tbf.group(1).strip()[:52])
elif rtlg:
    print("ABORT|%s" % rtlg.group(1).strip()[:52])
elif bound:
    print("ABORT|%s" % bd.strip()[:52])
elif hung:
    print("ABORT|hung: reached --stop-time with no verdict")
elif rc == 124:
    print("ABORT|wall-clock timeout -- never terminated")
elif lang:
    print("ABORT|%s" % lang.group(1).strip()[:52])
else:
    print("ABORT|no success line and no error at all")
PY
}

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

# ---------------------------------------------------------------------------
# THE CONTROL.  A red table under a broken control is a statement about the
# harness, not about the RTL.
# ---------------------------------------------------------------------------
echo
echo "=== control: the UNMUTATED rtl/matvec_int4.vhd ==="
mkdir -p "$SCRATCH/control/work"
if ! analyze_into "$SCRATCH/control/work" "$REPO/$RTL" "$SCRATCH/control/analyze.log"; then
  echo "CONTROL DID NOT ANALYZE -- nothing below would mean anything:"
  grep -m5 -i error "$SCRATCH/control/analyze.log"; exit 2
fi
JUDGES="small"
[ "$HAVE_FK33" = 1 ] && JUDGES="small fk33"
for j in $JUDGES; do
  cres=$(run_judge "$SCRATCH/control/work" "$SCRATCH/control/$j/run" "$j")
  printf '  %-6s %s\n' "$j" "$cres"
  if [ "${cres%%|*}" != "SURV" ]; then
    echo "CONTROL FAILED under judge $j -- nothing below would mean anything:"
    grep -v "metavalue detected" "$SCRATCH/control/$j/run/log" | tail -12; exit 2
  fi
done

mutate() {   # mutate <tag> <class> <desc> <old> <new> [<old> <new> ...]
  local tag="$1" cls="$2" desc="$3"; shift 3
  if [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]]; then return; fi
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$SCRATCH/$tag"
  mkdir -p "$dir/work"

  if ! patch_file "$REPO/$RTL" "$dir/matvec_int4.vhd" "$@" 2>"$dir/patch.log"; then
    NVOID=$((NVOID+1)); VOID_TAGS="$VOID_TAGS $tag"
    printf '%-4s %-5s VOID     ANCHOR FAILED -- TESTED NOTHING         by[--] -- %s\n' \
      "$tag" "$cls" "$desc"
    sed -n 1,2p "$dir/patch.log"; return
  fi
  if ! analyze_into "$dir/work" "$dir/matvec_int4.vhd" "$dir/analyze.log"; then
    NVOID=$((NVOID+1)); VOID_TAGS="$VOID_TAGS $tag"
    printf '%-4s %-5s VOID     DID NOT ANALYZE -- TESTED NOTHING       by[--] -- %s\n' \
      "$tag" "$cls" "$desc"
    grep -m2 -i error "$dir/analyze.log" | sed 's/^/         /'; return
  fi

  local worst="SURV" det="ok" caught="" j res v void=0
  for j in $JUDGES; do
    res=$(run_judge "$dir/work" "$dir/$j/run" "$j"); v="${res%%|*}"
    case "$v" in
      VOID) void=1; det="$j: ${res#*|}" ;;
      SURV) : ;;
      *) caught="$caught $j"
         if [ "$worst" = "SURV" ] || { [ "$worst" = "ABORT" ] && [ "$v" = "KILL" ]; }; then
           worst="$v"; det="${res#*|}"
         fi ;;
    esac
  done

  if [ "$void" = 1 ]; then
    NVOID=$((NVOID+1)); VOID_TAGS="$VOID_TAGS $tag"
    printf '%-4s %-5s VOID     %-40s by[--] -- %s\n' "$tag" "$cls" "$det" "$desc"
    return
  fi
  case "$worst" in
    KILL)  NKILL=$((NKILL+1));  v="KILLED  " ;;
    ABORT) NABORT=$((NABORT+1)); v="ABORT   " ;;
    *)     NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"; v="SURVIVED" ;;
  esac
  printf '%-4s %-5s %s %-40s by[%s] -- %s\n' \
    "$tag" "$cls" "$v" "$det" "${caught:- none}" "$desc"
}

echo
echo "======================================================================="
echo " mutations of rtl/matvec_int4.vhd, judged by sim/tb_matvec_int4.vhd"
echo " (small) and sim/tb_matvec_fk33.vhd (fk33)"
echo "======================================================================="
echo "tag  class verdict  detail                                   caught-by -- what was changed"

# --- class TAP: the two performance taps ------------------------------------
# Both are left `open` by every bench in the tree, so both are expected to
# survive.  They are here to SAY SO in executable form: spec 11 asks for
# sustained bandwidth as a percentage of DDR peak, these two signals are the
# only measurement of it, and nothing checks either one.
mutate T1 TAP "dbg_wbeat counts an OFFERED word, not an accepted one" \
  '  dbg_wbeat   <= wv and wr;' \
  '  dbg_wbeat   <= wv;'

mutate T2 TAP "dbg_wstarve inverted -- starvation reported as flow" \
  '  dbg_wstarve <= not wv;' \
  '  dbg_wstarve <= wv;'

# --- class CONV: the seven scalar conversions -------------------------------
# signed vs unsigned is the interesting axis.  For a quantity that is never
# negative on any trace the two are the same function, so a SURVIVED row here
# names a port no bench ever drives negative -- which is a statement about the
# stimulus, not about the RTL.
mutate C1 CONV "n_rows read as unsigned -- identical unless a bench drives it negative" \
  '  i_rows   <= to_integer(signed(n_rows));' \
  '  i_rows   <= to_integer(unsigned(n_rows));'

mutate C2 CONV "out_shift read as unsigned -- identical unless out_shift < 0" \
  '  i_osh    <= to_integer(signed(out_shift));' \
  '  i_osh    <= to_integer(unsigned(out_shift));'

# C3 AND C4 SURVIVE AND THAT IS THE MEASUREMENT.  For a value that is never
# negative on any trace, signed and unsigned are the same function.  MEASURED
# 2026-08-29 from the two traces these judges use: the DIMS line gives
# w_exp = 2, x_exp = 5 in `small` and w_exp = 8, x_exp = 5 in `fk33` -- all
# four non-negative.  So NO BENCH IN THIS TREE DRIVES A NEGATIVE w_exp OR
# x_exp into subsystem A, even though the SAME run emits y_exp = -2, i.e. the
# output side of the same arithmetic is routinely negative.  That is a
# statement about the stimulus, not about the RTL, and it stays open.
mutate C3 CONV "w_exp read as unsigned -- no trace drives it negative, see above" \
  '  i_wexp   <= to_integer(signed(w_exp));' \
  '  i_wexp   <= to_integer(unsigned(w_exp));'

mutate C4 CONV "x_exp read as unsigned -- same, and same open question" \
  '  i_xexp   <= to_integer(signed(x_exp));' \
  '  i_xexp   <= to_integer(unsigned(x_exp));'

mutate C5 CONV "y_exp emitted one too large -- the exponent, not the mantissas" \
  '  y_exp    <= std_logic_vector(to_signed(i_yexp, 32));' \
  '  y_exp    <= std_logic_vector(to_signed(i_yexp + 1, 32));'

mutate C6 CONV "n_cols and n_rows swapped on the way into the core" \
  '  i_rows   <= to_integer(signed(n_rows));
  i_cols   <= to_integer(signed(n_cols));' \
  '  i_rows   <= to_integer(signed(n_cols));
  i_cols   <= to_integer(signed(n_rows));'

mutate C7 CONV "w_beats and s_beats swapped -- GRP=2 in small, GRP=1 at the FK33" \
  '             w_base => w_base, w_beats => i_wbeats,
             s_base => s_base, s_beats => i_sbeats,' \
  '             w_base => w_base, w_beats => i_sbeats,
             s_base => s_base, s_beats => i_wbeats,'

mutate C8 CONV "the integer signals lose their initialisation -- INTEGER'LOW at delta 0" \
  '  signal i_rows, i_cols, i_osh, i_wexp, i_xexp : integer := 0;
  signal i_wbeats, i_sbeats, i_yexp            : integer := 0;' \
  '  signal i_rows, i_cols, i_osh, i_wexp, i_xexp : integer;
  signal i_wbeats, i_sbeats, i_yexp            : integer;'

# --- class WIRE: the streams between the three submodules -------------------
# W1 AND W2 SURVIVE TOGETHER, and the reason is structural rather than a hole
# in the stimulus: weight_streamer emits one w_data (ROWS_IF*BLK*4 bits) and
# one s_data (ROWS_IF*16 bits) PER BLOCK, so wv and sv rise on the same cycle
# and wr and sr fall on the same cycle.  Two signals that are equal on every
# trace cannot be told apart by swapping them.  Do not add stimulus for these:
# breaking the lockstep would require changing weight_streamer, which is a
# different unit with its own bench (sim/tb_weight_streamer).
mutate W1 WIRE "the weight stream is popped when the SCALE consumer is ready" \
  '             w_valid => wv, w_data => wd, w_ready => wr,
             s_valid => sv, s_data => sd, s_ready => sr);' \
  '             w_valid => wv, w_data => wd, w_ready => sr,
             s_valid => sv, s_data => sd, s_ready => wr);'

mutate W2 WIRE "the two stream VALIDs are swapped where the core reads them" \
  '             w_valid => wv, w_data => wd, w_ready => wr,
             s_valid => sv, s_data => sd, s_ready => sr,' \
  '             w_valid => sv, w_data => wd, w_ready => wr,
             s_valid => wv, s_data => sd, s_ready => sr,'

mutate W3 WIRE "the activation WRITE address is halved by a shifted slice" \
  '  xw_addr  <= x_waddr(XA-1 downto 0);' \
  '  xw_addr  <= x_waddr(XA downto 1);'

mutate W4 WIRE "the activation BLOCK read address is halved by a shifted slice" \
  '  xr_baddr <= x_rbaddr(XB-1 downto 0);' \
  '  xr_baddr <= x_rbaddr(XB downto 1);'

mutate W5 WIRE "the core's start is tied high -- it restarts every cycle" \
  '    port map(clk => clk, rst => rst, start => start,
             n_rows => i_rows, n_cols => i_cols, out_shift => i_osh,' \
  "    port map(clk => clk, rst => rst, start => '1',
             n_rows => i_rows, n_cols => i_cols, out_shift => i_osh,"

mutate W6 WIRE "out_mode forced to 01 rather than passed through" \
  '             w_exp => i_wexp, x_exp => i_xexp, out_mode => out_mode,' \
  '             w_exp => i_wexp, x_exp => i_xexp, out_mode => "01",'

# --- class SIZE: the two derived constants ----------------------------------
# XB's ceiling is the load-bearing half.  It is written as a ceiling divide
# because MAXCOLS need not be a multiple of BLK -- and if no bench ever picks
# such a MAXCOLS, the ceiling is untested and the plain divide survives.  That
# is the row, and it is the point of writing it down.
mutate S1 SIZE "XB drops the ceiling: clog2(MAXCOLS/BLK), not clog2(ceil)" \
  '  constant XB : positive := clog2((MAXCOLS + BLK - 1) / BLK);' \
  '  constant XB : positive := clog2(MAXCOLS / BLK);'

mutate S2 SIZE "XA one bit narrow -- the top activation address bit is dropped" \
  '  constant XA : positive := clog2(MAXCOLS);' \
  '  constant XA : positive := clog2(MAXCOLS) - 1;'

# --- class GEN: what each submodule is TOLD about the shape -----------------
# Several of these change a port width and are expected to come back VOID.
# They are kept because a VOID row is a real statement -- it says the mutation
# is not expressible, i.e. the width itself is the check -- and deleting them
# would make the surviving set look more discriminating than it is.
mutate G1 GEN "the core is told half the column bound it is given" \
  '    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => MAXCOLS,
                MAXROWS_BFP => MAXROWS_BFP)' \
  '    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => MAXCOLS / 2,
                MAXROWS_BFP => MAXROWS_BFP)'

mutate G2 GEN "the core is told half the BFP row bound it is given" \
  '    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => MAXCOLS,
                MAXROWS_BFP => MAXROWS_BFP)' \
  '    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => MAXCOLS,
                MAXROWS_BFP => MAXROWS_BFP / 2)'

mutate G3 GEN "the activation memory is sized for half the columns" \
  '    generic map(ELEMS => MAXCOLS, BLK => BLK, LANES => 4, W => 16)' \
  '    generic map(ELEMS => MAXCOLS / 2, BLK => BLK, LANES => 4, W => 16)'

mutate G4 GEN "the activation memory is striped two ways rather than four" \
  '    generic map(ELEMS => MAXCOLS, BLK => BLK, LANES => 4, W => 16)' \
  '    generic map(ELEMS => MAXCOLS, BLK => BLK, LANES => 2, W => 16)'

mutate G5 GEN "the streamer is told there is exactly one scale sub-region" \
  '    generic map(NPORTS_W => NPORTS_W, NPORTS_S => NPORTS_S,' \
  '    generic map(NPORTS_W => NPORTS_W, NPORTS_S => 1,'

mutate G6 GEN "the streamer's FIFOs are built a quarter of the asked depth" \
  '                ROWS_IF => ROWS_IF, BLK => BLK, DEPTH => FIFO_DEPTH,' \
  '                ROWS_IF => ROWS_IF, BLK => BLK, DEPTH => FIFO_DEPTH / 4,'

mutate G7 GEN "the streamer keeps one burst in flight per port, not MAXOUT" \
  '                MAXB => MAXB, MAXOUT => MAXOUT, DUAL_CLK => DUAL_CLK)' \
  '                MAXB => MAXB, MAXOUT => 1, DUAL_CLK => DUAL_CLK)'

mutate G8 GEN "the streamer runs its masters on aclk -- DUAL_CLK forced true" \
  '                MAXB => MAXB, MAXOUT => MAXOUT, DUAL_CLK => DUAL_CLK)' \
  '                MAXB => MAXB, MAXOUT => MAXOUT, DUAL_CLK => true)'

echo
echo "======================================================================="
printf ' %d mutations: %d KILLED, %d ABORT (%d caught), %d SURVIVED, %d VOID\n' \
  "$NTOT" "$NKILL" "$NABORT" "$((NKILL+NABORT))" "$NSURV" "$NVOID"
if [ -n "$SURV_TAGS" ]; then
  echo " SURVIVORS (the resolution floor of these benches, do not delete):$SURV_TAGS"
fi
if [ -n "$VOID_TAGS" ]; then
  echo " VOID (tested nothing -- see each row's reason):$VOID_TAGS"
fi
[ "$HAVE_FK33" = 0 ] && echo " WARNING: the fk33 judge was SKIPPED -- see the note at the top."
echo " scratch: $SCRATCH"
echo "======================================================================="
