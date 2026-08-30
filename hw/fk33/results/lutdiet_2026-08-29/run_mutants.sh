#!/usr/bin/env bash
# TRACK LUTDIET teeth-check.  A checker never shown to FAIL has not been shown
# to work.  Three mutations of rmsnorm_rs_mem, each breaking the banked-memory
# addressing in a different way, must all be caught by tb_lutdiet_rmsmem.
# usage: run_mutants.sh <pinned-rtl-dir> <variant-dir> <scratch>
set -u
SRC="${1:?}"; VAR="${2:?}"; W="${3:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$W/mut"; cd "$W"
for M in bankswap addroff selxor; do cp "$VAR/rmsnorm_rs_mem.vhd" "mut/$M.vhd"; done
# M1 write-bank index taken from the HIGH bits of the word index, not the low
sed -i "s|x_bwe(k) <= x_we when unsigned(x_waddr(clog2(LANES)-1 downto 0)) = k else '0';|x_bwe(k) <= x_we when unsigned(x_waddr(clog2(N)-1 downto clog2(N)-clog2(LANES))) = k else '0';|" mut/bankswap.vhd
# M2 output bank write address off by one
sed -i 's|o_wa <= std_logic_vector(to_unsigned(idx3, clog2(NB)));|o_wa <= std_logic_vector(to_unsigned((idx3+1) mod NB, clog2(NB)));|' mut/addroff.vhd
# M3 read-side lane select perturbed
sed -i 's|o_rsel <= o_raddr(clog2(LANES)-1 downto 0);|o_rsel <= o_raddr(clog2(LANES)-1 downto 0) xor "01";|' mut/selxor.vhd
for M in bankswap addroff selxor; do
  echo "=== MUTANT $M ==="
  diff "$VAR/rmsnorm_rs_mem.vhd" "mut/$M.vhd" | sed -n '2,5p'
  rm -rf workm; mkdir workm
  ghdl -a --std=08 --workdir=workm -Pworkm \
    "$SRC/util_pkg.vhd" "$SRC/fixed_luts_pkg.vhd" "$SRC/fixed_pkg.vhd" \
    "$SRC/vec_mem.vhd" "$SRC/rmsnorm_rs.vhd" "mut/$M.vhd" \
    "$HERE/rtl/tb_lutdiet_rmsmem.vhd" 2>&1 | head -4
  ghdl -r --std=08 --workdir=workm -Pworkm tb_lutdiet_rmsmem 2>&1 \
    | grep -E "EQUIV (PASS|FAIL)|FAIL trial" | head -4
done
