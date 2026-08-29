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

echo "== sim/tb_a_geom.vhd mutation table =="
d=$(mk base); v=$(run_case base "$d")
echo "M0  unmutated                                              $v  (must be PASS)"

# ---- the SCHEDULE side moves ------------------------------------------
d=$(mk m1)
sed -i 's/constant A_ROWS_IF     : natural := 48;/constant A_ROWS_IF     : natural := 32;/' "$d/sim/seq_tbl_pkg.vhd"
v=$(run_case m1 "$d")
echo "M1  seq_tbl_pkg A_ROWS_IF 48 -> 32                         $v  (want ANALYSIS or FAIL)"

d=$(mk m2)
sed -i 's/constant A_MAXROWS_BFP : natural := 17408;/constant A_MAXROWS_BFP : natural := 8192;/' "$d/sim/seq_tbl_pkg.vhd"
v=$(run_case m2 "$d")
echo "M2  seq_tbl_pkg A_MAXROWS_BFP 17408 -> 8192                $v  (want FAIL)"

d=$(mk m3)
sed -i 's/constant A_MAXROWS_BFP : natural := 17408;/constant A_MAXROWS_BFP : natural := 32768;/' "$d/sim/seq_tbl_pkg.vhd"
v=$(run_case m3 "$d")
echo "M3  seq_tbl_pkg A_MAXROWS_BFP 17408 -> 32768               $v  (want FAIL)"

# ---- the BUILD side moves, which is the direction that costs a card run --
d=$(mk m4)
sed -i 's/    MAXROWS_BFP : positive := 17408;/    MAXROWS_BFP : positive := 16384;/' "$d/rtl/matvec_int4_desc_axi.vhd"
v=$(run_case m4 "$d")
echo "M4  desc_axi default MAXROWS_BFP 17408 -> 16384            $v  (want FAIL)"

d=$(mk m5)
sed -i 's/    ROWS_IF     : positive := 48;/    ROWS_IF     : positive := 24;/' "$d/rtl/matvec_int4_desc_axi.vhd"
v=$(run_case m5 "$d")
echo "M5  desc_axi default ROWS_IF 48 -> 24                      $v  (want ANALYSIS: port width)"

# ---- predicted survivors, named ---------------------------------------
d=$(mk m6)
sed -i 's/    MAXCOLS     : positive := 17408;/    MAXCOLS     : positive := 8192;/' "$d/rtl/matvec_int4_desc_axi.vhd"
v=$(run_case m6 "$d")
echo "M6  desc_axi default MAXCOLS 17408 -> 8192                 $v  (PREDICTED SURVIVOR: seq_tbl_pkg has no MAXCOLS, and n_cols here is 4096)"

d=$(mk m7)
sed -i 's/    MAXOUT      : positive := 16;/    MAXOUT      : positive := 4;/' "$d/rtl/matvec_int4_desc_axi.vhd"
v=$(run_case m7 "$d")
echo "M7  desc_axi default MAXOUT 16 -> 4                        $v  (PREDICTED SURVIVOR: no weight traffic ever runs here)"

echo "scratch: $SCRATCH"
