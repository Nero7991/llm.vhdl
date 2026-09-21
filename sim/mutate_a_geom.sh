#!/usr/bin/env bash
# Teeth for sim/tb_a_geom.vhd.
#
# A check that has never been shown to fail has not been shown to work.  Each
# mutation below breaks the AGREEMENT the bench exists to police -- in both
# directions, and on both sides of it -- and the bench must fail.  Mutations
# that do NOT bite are reported under their own names: they measure the check's
# resolution floor and are the most useful rows here.
#
# SELF-ISOLATING.  Everything runs from a private copy of the tree, so editing
# this script (or the sources) while it runs cannot corrupt the run, and no
# mutation ever reaches the repository.
#
# Usage:  bash sim/mutate_a_geom.sh [scratch-dir]
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
SCRATCH="${1:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

FILES="rtl/util_pkg.vhd rtl/model_cfg_pkg.vhd rtl/act_mem_striped.vhd
       rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd rtl/matvec_int4_desc_pkg.vhd
       rtl/mv4i_arith_pkg.vhd rtl/stream_fifo.vhd sim/seq_tbl_pkg.vhd
       rtl/axi_rd_port.vhd rtl/matvec_core.vhd rtl/weight_streamer.vhd
       rtl/matvec_int4.vhd rtl/matvec_int4_desc_axi.vhd sim/tb_a_geom.vhd"

run_case () {                       # $1 = name, $2 = dir
  local nm="$1" d="$2" w="$2/work"
  rm -rf "$w"; mkdir -p "$w" "$d/run"
  for f in $FILES; do
    if ! ghdl -a --std=08 -frelaxed --workdir="$w" "$d/$f" \
         >> "$d/analyze.log" 2>&1; then
      echo "ANALYSIS"; return
    fi
  done
  ( cd "$d/run" && timeout -k 5 300 ghdl -r --std=08 -frelaxed \
      --workdir="../work" tb_a_geom --stop-time=200us > run.log 2>&1 )
  if grep -qa "RESULT: PASS" "$d/run/run.log"; then echo "PASS"; else echo "FAIL"; fi
}

mk () {                             # $1 = name -> prints the dir
  local d="$SCRATCH/$1"
  rm -rf "$d"; mkdir -p "$d/rtl" "$d/sim"
  for f in $FILES; do cp "$REPO/$f" "$d/$f"; done
  echo "$d"
}

NBAD=0; Z0SEEN=0

# msub <file> <sed program>  -- a substitution that must actually substitute.
#
# A `sed -i` WHOSE PATTERN MATCHES NOTHING EXITS 0 AND WRITES THE FILE BACK
# UNCHANGED.  Every row below used to call sed directly, so an anchor whose
# text had drifted under the RTL left the copied tree PRISTINE, run_case ran
# the unmutated design, and the row printed `PASS  (want FAIL)` with no
# diagnostic anywhere -- not on stdout, not on stderr, not in a log.
# MEASURED 2026-09-20 by TRACK MUTAUDIT: with an impossible pattern row M1
# printed PASS; with the real pattern it printed FAIL.  The two are
# indistinguishable in any committed copy of the table.
#
# The guard is the same one sim/mutate_rmsnorm_rs_mem.sh has always had: cmp
# the result against the input and refuse a no-op.  Returns 1 on a no-op.
msub () {
  local f="$1" prog="$2"
  cp -- "$f" "$f.pre" || return 1
  sed -i "$prog" "$f" || { rm -f -- "$f.pre"; return 1; }
  if cmp -s -- "$f" "$f.pre"; then rm -f -- "$f.pre"; return 1; fi
  rm -f -- "$f.pre"; return 0
}

# mrun <tag> <dir> -- run_case, unless the substitution above was a no-op.
# BADMUT is neither PASS nor FAIL: it says this row measured NOTHING.
#
# mrun IS CALLED IN A COMMAND SUBSTITUTION, so it runs in a SUBSHELL and
# cannot update a counter in this shell.  The tally is therefore done by
# `tally` in the PARENT, keyed on the word mrun printed.  A first draft
# incremented NBAD inside mrun and the increment was silently discarded --
# the same class of defect this whole fix is about, in the fix itself.
mrun () {
  local tag="$1" d="$2"
  if [ "${MSUB_RC:-0}" -ne 0 ]; then echo "BADMUT"; return; fi
  run_case "$tag" "$d"
}

tally () {   # tally <tag> <verdict>
  [ "$2" = BADMUT ] || return 0
  if [ "$1" = Z0 ]; then Z0SEEN=1; else NBAD=$((NBAD+1)); fi
}

echo "== sim/tb_a_geom.vhd mutation table =="
d=$(mk base); v=$(run_case base "$d")
echo "M0  unmutated                                              $v  (must be PASS)"

# ---------------------------------------------------------------------------
# Z0: THE TEETH OF THIS HARNESS ITSELF.  A sed pattern is TEXT and text
# drifts under the file it points into.  This pattern is deliberately
# impossible, so the only correct outcome is BADMUT.  If it ever prints
# PASS, every other row in this table is suspect, because it would mean an
# unapplied mutation is indistinguishable from an inert one.  It costs one
# file copy and no simulation.
# ---------------------------------------------------------------------------
d=$(mk z0)
msub "$d/sim/seq_tbl_pkg.vhd" 's/THIS TEXT IS NOT IN THE FILE AND MUST NOT BE PUT IN IT/nor this/'; MSUB_RC=$?
v=$(mrun Z0 "$d"); tally Z0 "$v"
echo "Z0  SELF-TEETH: impossible sed pattern                      $v  (MUST be BADMUT, never PASS)"

# ---- the SCHEDULE side moves ------------------------------------------
d=$(mk m1)
msub "$d/sim/seq_tbl_pkg.vhd" 's/constant A_ROWS_IF     : natural := 48;/constant A_ROWS_IF     : natural := 32;/'; MSUB_RC=$?
v=$(mrun m1 "$d"); tally m1 "$v"
echo "M1  seq_tbl_pkg A_ROWS_IF 48 -> 32                         $v  (want ANALYSIS or FAIL)"

d=$(mk m2)
msub "$d/sim/seq_tbl_pkg.vhd" 's/constant A_MAXROWS_BFP : natural := 17408;/constant A_MAXROWS_BFP : natural := 8192;/'; MSUB_RC=$?
v=$(mrun m2 "$d"); tally m2 "$v"
echo "M2  seq_tbl_pkg A_MAXROWS_BFP 17408 -> 8192                $v  (want FAIL)"

d=$(mk m3)
msub "$d/sim/seq_tbl_pkg.vhd" 's/constant A_MAXROWS_BFP : natural := 17408;/constant A_MAXROWS_BFP : natural := 32768;/'; MSUB_RC=$?
v=$(mrun m3 "$d"); tally m3 "$v"
echo "M3  seq_tbl_pkg A_MAXROWS_BFP 17408 -> 32768               $v  (want FAIL)"

# ---- the BUILD side moves, which is the direction that costs a card run --
d=$(mk m4)
msub "$d/rtl/matvec_int4_desc_axi.vhd" 's/    MAXROWS_BFP : positive := 17408;/    MAXROWS_BFP : positive := 16384;/'; MSUB_RC=$?
v=$(mrun m4 "$d"); tally m4 "$v"
echo "M4  desc_axi default MAXROWS_BFP 17408 -> 16384            $v  (want FAIL)"

d=$(mk m5)
msub "$d/rtl/matvec_int4_desc_axi.vhd" 's/    ROWS_IF     : positive := 48;/    ROWS_IF     : positive := 24;/'; MSUB_RC=$?
v=$(mrun m5 "$d"); tally m5 "$v"
echo "M5  desc_axi default ROWS_IF 48 -> 24                      $v  (want ANALYSIS: port width)"

# ---- predicted survivors, named ---------------------------------------
d=$(mk m6)
msub "$d/rtl/matvec_int4_desc_axi.vhd" 's/    MAXCOLS     : positive := 17408;/    MAXCOLS     : positive := 8192;/'; MSUB_RC=$?
v=$(mrun m6 "$d"); tally m6 "$v"
echo "M6  desc_axi default MAXCOLS 17408 -> 8192                 $v  (PREDICTED SURVIVOR: seq_tbl_pkg has no MAXCOLS, and n_cols here is 4096)"

d=$(mk m7)
msub "$d/rtl/matvec_int4_desc_axi.vhd" 's/    MAXOUT      : positive := 16;/    MAXOUT      : positive := 4;/'; MSUB_RC=$?
v=$(mrun m7 "$d"); tally m7 "$v"
echo "M7  desc_axi default MAXOUT 16 -> 4                        $v  (PREDICTED SURVIVOR: no weight traffic ever runs here)"

echo "scratch: $SCRATCH"

# THE HARNESS'S OWN VERDICT.  A run in which Z0 did not reach BADMUT has not
# shown that this script can tell an unapplied mutation from an inert one, and
# every PASS it printed is worth less than it looks.
if [ "${Z0SEEN:-0}" -ne 1 ]; then
  echo "Z0 SELF-TEETH DID NOT FIRE: a sed pattern that matched nothing is"
  echo "  indistinguishable here from a mutation the bench tolerates."
  exit 1
fi
if [ "${NBAD:-0}" -ne 0 ]; then
  echo "$NBAD row(s) BADMUT: their sed patterns matched nothing and they"
  echo "  tested nothing.  Fix the patterns before reading this table."
  exit 1
fi
echo "Z0 self-teeth: BADMUT as required; $NBAD other row(s) BADMUT."
