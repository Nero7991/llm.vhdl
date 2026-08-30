#!/usr/bin/env bash
# TRACK LUTDIET equivalence + mutation harness.  NOT a gate row: tb_lutdiet_rmsmem.vhd
# deliberately does NOT live in sim/, because a new sim/tb_*.vhd is auto-discovered
# into the shared regression and this bench needs an RTL variant that is not in rtl/.
#
# usage: run_equiv.sh <pinned-rtl-dir> <variant-dir> <scratch>
set -eu
SRC="${1:?pinned rtl dir}"; VAR="${2:?variant dir}"; W="${3:?scratch}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$W"; cd "$W"; rm -rf work; mkdir work
ghdl -a --std=08 --workdir=work -Pwork \
  "$SRC/util_pkg.vhd" "$SRC/fixed_luts_pkg.vhd" "$SRC/fixed_pkg.vhd" \
  "$SRC/vec_mem.vhd" "$SRC/rmsnorm_rs.vhd" \
  "$VAR/rmsnorm_rs_mem.vhd" "$HERE/rtl/tb_lutdiet_rmsmem.vhd"
# GHDL here is the mcode backend: `ghdl -e` produces no binary and silently
# succeeds, so run directly.
ghdl -r --std=08 --workdir=work -Pwork tb_lutdiet_rmsmem
