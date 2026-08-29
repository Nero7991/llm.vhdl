#!/usr/bin/env bash
# Mutation test for sim/tb_seq_tbl_shape.vhd, whose subject is the descriptor
# table `sim/seq_tbl_pkg.vhd` emits.
#
# THE MUTATIONS ARE ON THE GENERATOR, NOT ON THE BENCH.  A bench that checks a
# table it also builds proves nothing, so every mutation below edits
# `sim/seq_tbl_pkg.vhd` and asks whether the bench notices.  Each one is
# well-formed and elaborates, so a kill is the checker noticing and not GHDL
# noticing; a mutation that does not analyze is reported as such and counts as
# nothing, per the discipline in `sim/mutate_seq_desc_fetch.sh`.
#
# EVERY MUTATION IS TAGGED WITH THE BRANCH THAT ELABORATES IT.  `seq_tbl_pkg`
# has three `if NCARDS = 1 then ... else ... end if` sites, and this build is
# NCARDS = 1, so a mutation in an `else` arm is a PERMANENT non-biter for this
# configuration and says nothing about the bench.  N9 is exactly that, kept
# deliberately as the resolution floor: it measures what the mutation harness
# can reach, not what the checker can see.
#
# Usage:  bash sim/mutate_seq_tbl_shape.sh            # all rows
#         SCRATCH=/path bash sim/mutate_seq_tbl_shape.sh
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
SRC=sim/seq_tbl_pkg.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

npass=0; nkill=0; nsurv=0; nbad=0; nlang=0
lang_why=""

mutate() {
  local tag="$1" branch="$2" desc="$3" old="$4" new="$5" expect="$6"
  lang_why=""
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/seq_tbl_pkg.vhd" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then
    printf '%-4s %-7s %-58s ANCHOR FAILED\n' "$tag" "$branch" "$desc"
    nbad=$((nbad+1)); return
  fi
  for f in model_cfg_pkg util_pkg; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/seq_tbl_pkg.vhd" \
       > "$dir/analyze.log" 2>&1; then
    printf '%-4s %-7s %-58s DID NOT ANALYZE\n' "$tag" "$branch" "$desc"
    sed -n 1,2p "$dir/analyze.log"; nbad=$((nbad+1)); return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_seq_tbl_shape.vhd \
       >> "$dir/analyze.log" 2>&1
  ghdl -r --std=08 -frelaxed --workdir="$dir" tb_seq_tbl_shape \
       --max-stack-alloc=0 > "$dir/run.log" 2>&1
  local rcv=$? v
  # THE LANGUAGE CATCHING IT IS NOT THE CHECKER CATCHING IT.  This script was
  # already the only one in the tree that said so, but it recognised exactly
  # two spellings, "bound check failure" and "error during elaboration".  It is
  # now delegated to sim/mutverdict.py, which recognises the rest of them --
  # index, range, overflow and null-access checks, an assert inside the DUT
  # rather than the bench, a wedge to --stop-time, an external timeout -- and
  # reports WHICH.  The verdict name KILLED-LANG is kept so the expected-result
  # column in the mutation table below does not have to be rewritten.
  v=$(python3 "$MUTV" "$dir/run.log" tb_seq_tbl_shape "$rcv")
  case "$v" in
    PASS)   got=SURVIVED ;;
    KILLED) got=KILLED ;;
    *)      got=KILLED-LANG; lang_why="${v#ABORT:}" ;;
  esac
  local mark="  "
  if [ "$got" != "$expect" ]; then mark="<-"; fi
  printf '%-4s %-7s %-58s %-9s %s\n' "$tag" "$branch" "$desc" "$got" "$mark"
  case "$got" in
    KILLED)      nkill=$((nkill+1)) ;;
    KILLED-LANG) nlang=$((nlang+1)) ;;
    *)           nsurv=$((nsurv+1)) ;;
  esac
  if [ "$got" = KILLED ]; then
    grep -m1 "report error" "$dir/run.log" \
      | sed 's/.*report error.: /       first: /' | cut -c1-118
  elif [ "$got" = KILLED-LANG ]; then
    echo "       stopped by: $lang_why  (the checker never reached a verdict)"
  fi
}

echo "control: the unmutated package"
CTL="$SCRATCH/ctl"; rm -rf "$CTL"; mkdir -p "$CTL"
for f in model_cfg_pkg util_pkg; do
  ghdl -a --std=08 -frelaxed --workdir="$CTL" "rtl/$f.vhd" >/dev/null 2>&1
done
ghdl -a --std=08 -frelaxed --workdir="$CTL" "$SRC" >/dev/null 2>&1
ghdl -a --std=08 -frelaxed --workdir="$CTL" sim/tb_seq_tbl_shape.vhd >/dev/null 2>&1
if ghdl -r --std=08 -frelaxed --workdir="$CTL" tb_seq_tbl_shape \
     --max-stack-alloc=0 2>&1 | grep -q "tb_seq_tbl_shape: PASS"; then
  echo "control: PASS (a mutation table against a red control measures nothing)"
else
  echo "control: FAILED -- STOP.  Fix the tree before reading anything below."
  exit 1
fi
echo

printf '%-4s %-7s %-58s %s\n' TAG BRANCH MUTATION RESULT
printf '%-4s %-7s %-58s %s\n' ---- ------- -------- ------

# ---- the defect this bench exists for, in its several forms ---------------
mutate M1 "N=1" "the historical defect: one job over the whole vocabulary" \
  'n_rows => minimum(LM_STRIDE, VOCAB_SH - w*LM_STRIDE),' \
  'n_rows => VOCAB_SH,' KILLED

mutate M2 "always" "stride is MAXROWS_BFP, not floored to a tile" \
  'constant LM_STRIDE  : positive := (A_MAXROWS_BFP / A_ROWS_IF) * A_ROWS_IF;' \
  'constant LM_STRIDE  : positive := A_MAXROWS_BFP;' KILLED

mutate M3 "always" "stride rounded UP to a tile instead of down" \
  'constant LM_STRIDE  : positive := (A_MAXROWS_BFP / A_ROWS_IF) * A_ROWS_IF;' \
  'constant LM_STRIDE  : positive := ((A_MAXROWS_BFP + A_ROWS_IF - 1) / A_ROWS_IF) * A_ROWS_IF;' KILLED

mutate M4 "always" "window count floored, so the tail of the vocab is dropped" \
  'constant LM_WINDOWS : positive := (VOCAB_SH + LM_STRIDE - 1) / LM_STRIDE;' \
  'constant LM_WINDOWS : positive := VOCAB_SH / LM_STRIDE;' KILLED

# M5 is KILLED BY THE LANGUAGE, not by the bench: `VOCAB_SH - w*LM_STRIDE`
# goes negative in a `natural` and the emitter raises a bound check before the
# checker ever runs.  Kept, because "the generator physically cannot build an
# over-covering table" is worth knowing, but scored separately.
mutate M5 "always" "one window too many, running past the tensor" \
  'constant LM_WINDOWS : positive := (VOCAB_SH + LM_STRIDE - 1) / LM_STRIDE;' \
  'constant LM_WINDOWS : positive := (VOCAB_SH + LM_STRIDE - 1) / LM_STRIDE + 1;' KILLED-LANG

# ---- the fields that make the windows one comparable stream ----------------
mutate M6 "N=1" "windows emitted in BFP instead of raw" \
  'nsub_w => nsw, nsub_s => nss, out_mode => 1));
    end loop;' \
  'nsub_w => nsw, nsub_s => nss, out_mode => 0));
    end loop;' KILLED

mutate M7 "N=1" "windows given a destination region" \
  'emit(mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_XN, dst => R_NONE,' \
  'emit(mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_XN, dst => R_ER,' KILLED

mutate M8 "N=1" "windows given per-window dst_off, manufacturing segments" \
  'n_rows => minimum(LM_STRIDE, VOCAB_SH - w*LM_STRIDE),
                   n_cols => HID,' \
  'n_rows => minimum(LM_STRIDE, VOCAB_SH - w*LM_STRIDE),
                   dst_off => w*LM_STRIDE, n_cols => HID,' KILLED

mutate M9 "N=1" "the sampler route flag dropped from every window" \
  'emit(mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_XN, dst => R_NONE,
                   n_rows => minimum' \
  'emit(mk_desc(OP_A_JOB, flags => 0, src => R_XN, dst => R_NONE,
                   n_rows => minimum' KILLED

# ---- group 3, which is not about the lm_head at all ------------------------
mutate M10 "N=1" "FFN gate job overruns region R_G by one row" \
  'emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_G, n_rows => FFN,' \
  'emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_G, n_rows => FFN+1,' KILLED

mutate M11 "N=1" "the third QKV segment starts one element late" \
  'dst_off => 2*KEY_DIM, n_rows => VAL_DIM, n_cols => HID,' \
  'dst_off => 2*KEY_DIM + 1, n_rows => VAL_DIM, n_cols => HID,' KILLED

# ---- expected survivors, named ---------------------------------------------
mutate N1 "N=1" "nsub_w and nsub_s swapped on every A job" \
  'variable nsw : natural := 29;   -- weight bases per A job, D section 2.2-J
    variable nss : natural := 4;    -- scale bases per A job' \
  'variable nsw : natural := 4;    -- weight bases per A job, D section 2.2-J
    variable nss : natural := 29;   -- scale bases per A job' SURVIVED

mutate N2 "N=1" "the tail norm ordinal changed from 0 to 7" \
  'const_base => MODEL.blocks, ordinal => 0));' \
  'const_base => MODEL.blocks, ordinal => 7));' SURVIVED

mutate N3 "N=1" "the w_exp stamping sequence changed" \
  'ds(2)(31 downto 0)  := std_logic_vector(to_signed(((p * 7) mod 61) - 30, 32));' \
  'ds(2)(31 downto 0)  := std_logic_vector(to_signed(((p * 11) mod 61) - 30, 32));' SURVIVED

mutate N4 "N=1" "FFN gate and up destinations swapped (both size FFN)" \
  'emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_G, n_rows => FFN,
                   n_cols => HID, nsub_w => nsw, nsub_s => nss, out_mode => 0));
      emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_U, n_rows => FFN,' \
  'emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_U, n_rows => FFN,
                   n_cols => HID, nsub_w => nsw, nsub_s => nss, out_mode => 0));
      emit(mk_desc(OP_A_JOB, src => R_XN, dst => R_G, n_rows => FFN,' SURVIVED

mutate N9 "N>1" "the collective FFN down-projection's row count (DEAD BRANCH)" \
  'emit(mk_desc(OP_A_JOB, flags => FLG_TO_E + FLG_E_NEXT, src => R_H,
                     dst => R_NONE, n_rows => HID, n_cols => FFN,' \
  'emit(mk_desc(OP_A_JOB, flags => FLG_TO_E + FLG_E_NEXT, src => R_H,
                     dst => R_NONE, n_rows => HID + 1, n_cols => FFN,' SURVIVED

echo
echo "killed-by-checker $nkill   ABORTED-before-the-checker $nlang   survived $nsurv   not-a-measurement $nbad"
echo "  (the middle column is the old KILLED-LANG: the run never reached a"
echo "   verdict the checker owns, so it is NOT a checker kill)"
echo "scratch: $SCRATCH"
