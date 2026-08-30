#!/usr/bin/env bash
# TRACK READCONV equivalence run.  DUT vs the pinned pre-change copy.
# usage: run_equiv.sh <workdir> <N> <LANES>
set -u
REPO=/home/orencollaco/GitHub/llama.vhdl
RES=$REPO/hw/fk33/results/readconv_2026-08-29
WD="${1:?usage: run_equiv.sh <workdir> <N> <LANES>}"
NN="${2:?}"; LL="${3:?}"
mkdir -p "$WD" || exit 2
cd "$WD" || exit 2
rm -f "$WD"/*.cf 2>/dev/null
ghdl -a --std=08 --work=work \
  $REPO/rtl/fixed_luts_pkg.vhd $REPO/rtl/fixed_pkg.vhd $REPO/rtl/util_pkg.vhd \
  $REPO/rtl/l2norm_rs.vhd $RES/rtl/l2norm_rs_ref.vhd $RES/rtl/tb_readconv_l2.vhd
A=${PIPESTATUS[0]}
if [ "$A" -ne 0 ]; then echo "READCONV_VOID analysis failed (rc=$A)"; exit 3; fi
ghdl -r --std=08 --work=work tb_readconv_l2 -gN=$NN -gLANES=$LL --assert-level=error
R=$?
echo "READCONV_RUN_RC=$R N=$NN LANES=$LL"
exit $R
