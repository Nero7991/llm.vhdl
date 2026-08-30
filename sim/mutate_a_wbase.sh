#!/usr/bin/env bash
# sim/mutate_a_wbase.sh -- the teeth table for sim/tb_a_wbase.vhd.
#
# TRACK BASEFAB, 2026-08-30.
#
# WHAT THIS MEASURES.  `sim/tb_a_wbase.vhd` is a checker, and a checker never
# shown to fail has not been shown to work.  This mutates the ONE thing it
# claims to watch -- `rtl/llama_top.vhd`'s fabricated weight address block --
# and records which mutants it kills.
#
# AND THE ATTRIBUTION CONTROL, WHICH IS THE HALF THAT IS USUALLY MISSING.
# A kill by the new row proves nothing on its own: the old rows may already
# have caught it, in which case the new row is decoration with a maintenance
# cost.  So every mutant is ALSO run against the six pre-existing llama_top
# rows (`--only tb_llama_top` is a SUBSTRING and matches tb_llama_top,
# tb_llama_top_smp and tb_llama_top_seq, six rows in total), and the table
# below reports BOTH columns.  A row is credited to the new bench only where
# the control column is PASS.
#
# Mutants that do NOT bite are reported under their own names.  They measure
# the resolution floor of the checker and are the most valuable line here.
#
# USAGE
#   bash sim/mutate_a_wbase.sh <snapshot-dir> <scratch-dir> [mutant ...]
#
# The snapshot directory must be a `git archive HEAD`-style tree with THIS
# track's hunks applied and nothing else in it.  Running against a live
# working tree is how TRACK DSEAM lost 14 of 17 rows to another track's
# transient edit of a file it did not own.
#
# NO HARDWARE.  Nothing here opens /dev/xdma*, runs xsdb, hw_server or any
# Vivado programming flow.  GHDL only.

set -u

SNAP="${1:?snapshot dir}"
SCR="${2:?scratch dir}"
shift 2

SRC="$SNAP/rtl/llama_top.vhd"
PRISTINE="$SNAP/rtl/llama_top.vhd.basefab_pristine"

if [ ! -f "$PRISTINE" ]; then
  cp "$SRC" "$PRISTINE"
fi

# ---------------------------------------------------------------- mutants
# Each is a python3 string replacement against the pristine file.  A
# replacement that does not match is a HARD ERROR, not a silent no-op: a
# mutation that was never applied looks exactly like a mutation that
# survived, and this table's whole value is in telling those apart.
mut_py() {
  python3 - "$PRISTINE" "$SRC" "$1" <<'PY'
import sys
src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()

BASE   = "base  := A_MEM_BASE + j_step * A_JOB_STRIDE;"
WLOOP  = "<= std_logic_vector(to_unsigned(base + p*A_SUB_BYTES, 32));"
SBASE  = "to_unsigned(base + A_ROWS_IF*A_SUB_BYTES, 32));"
WBEAT  = "r_wbeat <= std_logic_vector(to_signed(wb, 32));"
SBEXPR = "sb := (tiles * nb * A_ROWS_IF * 2 + 15) / 16;"
GUARD  = "if wb > A_SUB_BEATS or sb > A_SCL_BEATS then"

M = {
  # ---- the address itself
  "M1_no_step":    (BASE,  "base  := A_MEM_BASE;"),
  "M2_no_port":    (WLOOP, "<= std_logic_vector(to_unsigned(base + 0*A_SUB_BYTES, 32));"),
  "M3_half_pitch": (WLOOP, "<= std_logic_vector(to_unsigned(base + p*(A_SUB_BYTES/2), 32));"),
  "M4_scale_on_p0":(SBASE, "to_unsigned(base + 0*A_SUB_BYTES, 32));"),
  "M5_step_plus1": (BASE,  "base  := A_MEM_BASE + (j_step+1) * A_JOB_STRIDE;"),
  "M6_unaligned":  (BASE,  "base  := A_MEM_BASE + 16 + j_step * A_JOB_STRIDE;"),
  "M11_port_rev":  (WLOOP, "<= std_logic_vector(to_unsigned(base + (A_ROWS_IF-1-p)*A_SUB_BYTES, 32));"),
  # ---- the extent
  "M7_wbeat_short":(WBEAT, "r_wbeat <= std_logic_vector(to_signed(wb-1, 32));"),
  "M8_sbeat_half": (SBEXPR,"sb := (tiles * nb * A_ROWS_IF + 15) / 16;"),
  # ---- the capacity guard itself
  "M9_guard_off":  (GUARD, "if false and (wb > A_SUB_BEATS or sb > A_SCL_BEATS) then"),
  "M10_guard_ge":  (GUARD, "if wb >= A_SUB_BEATS or sb > A_SCL_BEATS then"),
}

if name not in M:
    sys.exit("unknown mutant " + name)
old, new = M[name]
n = s.count(old)
if n != 1:
    sys.exit("mutant %s: pattern occurs %d times, expected exactly 1" % (name, n))
open(dst, "w").write(s.replace(old, new))
PY
}

ALL="M1_no_step M2_no_port M3_half_pitch M4_scale_on_p0 M5_step_plus1 \
M6_unaligned M7_wbeat_short M8_sbeat_half M9_guard_off M10_guard_ge M11_port_rev"

if [ "$#" -gt 0 ]; then
  LIST="$*"
else
  LIST="$ALL"
fi

# One row of the table.  $1 mutant, $2 the --only pattern, $3 a tag for the
# scratch directory.  Prints PASS (the mutant SURVIVED that column) or FAIL
# (it was KILLED), plus BUILD-ERROR / TIMEOUT verbatim when they happen --
# a mutant that will not analyse is not a detection and must not be counted
# as one.
# The counters are printed as P= / F= / NV= / TO= / BE= rather than the words
# regress.sh uses.  Deliberate: CLAUDE.md records that regress.sh's own
# FAIL_RE matches a bare \bFAIL\b, so a table containing the word inside a
# log this script's output is ever pasted into would read as a failure.
run_one() {
  local mutant="$1" pat="$2" tag="$3"
  cd "$SNAP" && REGRESS_SCRATCH="$SCR/$mutant.$tag" \
    timeout 4000 bash sim/regress.sh --only "$pat" 2>&1 | \
    awk '/^ OVERALL/ {printf "P=%s F=%s NV=%s TO=%s BE=%s", $3, $5, $7, $9, $11}'
}

printf '%-16s %-34s %-34s\n' MUTANT "NEW tb_a_wbase (1 row)" "CONTROL llama_top (6 rows)"
for m in $LIST; do
  if ! mut_py "$m"; then
    printf '%-16s %s\n' "$m" "MUTATION DID NOT APPLY -- table row is void"
    cp "$PRISTINE" "$SRC"
    continue
  fi
  a=$(run_one "$m" tb_a_wbase new)
  if [ "${CTL:-1}" = "1" ]; then
    b=$(run_one "$m" tb_llama_top ctl)
  else
    b="(control not run)"
  fi
  printf '%-16s %-34s %-34s\n' "$m" "$a" "$b"
  cp "$PRISTINE" "$SRC"
done
cp "$PRISTINE" "$SRC"
