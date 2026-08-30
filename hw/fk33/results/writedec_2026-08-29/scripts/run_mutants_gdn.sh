#!/usr/bin/env bash
# TRACK WRITEDEC teeth-check for gdn_block's new write decode.
#
# The equivalence oracle for gdn_block is: run sim/tb_gdn_block against the
# PRE-change RTL and against the POST-change RTL and require the GHDL VCD of
# every top-level testbench signal -- which is every DUT port -- to be
# identical at every timestamp, plus the value dump gdn_block_out.txt to be
# identical.  A comparison never shown to FAIL proves nothing, so each mutation
# below breaks the decode differently and must turn it red.
#
# GUARD, and it is not theoretical: an earlier form of this comparison reported
# IDENTICAL over two files that did not exist.  No row is scored unless both
# VCDs exist and are non-empty.
#
# NOTE ON DELETION.  Every path deleted here is written out LITERALLY, per
# mutant, with nothing interpolated.  A `rm -rf "$VAR"` whose variable is empty
# deletes from the filesystem root; this file does not contain that form.
set -u
SRC=/mnt/storage/writedec/src
NEWG=/home/orencollaco/GitHub/llama.vhdl/rtl/gdn_block.vhd
BASEVCD=/mnt/storage/writedec/vcd_base.vcd
BASEDUMP=/mnt/storage/writedec/rg_gdn_base/sim_tb_gdn_block/run/gdn_block_out.txt
strip(){ grep -v -E '^\$scope module g(qbuf|kbuf|vbuf|qsb|knb)\(' "$1" | grep -v '^\$upscope \$end$'; }

score(){   # $1 = mutant dir, $2 = name
  local D="$1" M="$2"
  local RD="$D/rg/sim_tb_gdn_block/run"
  if [ ! -d "$RD" ]; then echo "  VERDICT: VOID -- the bench never built"; return; fi
  ( cd "$RD" && timeout 900 ghdl -r --std=08 -frelaxed --workdir=../work -P../work \
      tb_gdn_block --vcd="$D/vcd.vcd" --vcd-nodate >/dev/null 2>&1 )
  if [ ! -s "$D/vcd.vcd" ]; then echo "  VERDICT: VOID -- no VCD produced"; return; fi
  local DUMP=DIFFERS VCD=DIFFERS
  if [ -f "$RD/gdn_block_out.txt" ] && diff -q "$BASEDUMP" "$RD/gdn_block_out.txt" >/dev/null; then DUMP=IDENTICAL; fi
  if diff <(strip "$BASEVCD") <(strip "$D/vcd.vcd") >/dev/null; then VCD=IDENTICAL; fi
  echo "  gdn_block_out.txt $DUMP ; top-level VCD $VCD"
  if [ "$VCD" = DIFFERS ] || [ "$DUMP" = DIFFERS ]; then echo "  VERDICT: CAUGHT"
  else echo "  VERDICT: NOT CAUGHT -- resolution floor"; fi
}

build(){   # $1 = dir, $2 = name
  local D="$1" M="$2"
  cp -r "$SRC" "$D"
  cp "$NEWG" "$D/rtl/gdn_block.vhd"
  case $M in
    vbuf_off) sed -i 's|and cv_seg_i > 1 and obeat = wi then|and cv_seg_i > 1 and obeat = (wi+1) mod NBV then|' "$D/rtl/gdn_block.vhd" ;;
    qsb_off)  sed -i "s|and l2_qk = '0' and kh = h then|and l2_qk = '0' and kh = (h+1) mod KEY_HEADS then|" "$D/rtl/gdn_block.vhd" ;;
    no_seg)   sed -i 's|and cv_seg_i = 0 and obeat = wi then|and obeat = wi then|' "$D/rtl/gdn_block.vhd" ;;
    no_ph)    sed -i "s|and co_valid = '1' and ph /= P_IDLE|and co_valid = '1'|" "$D/rtl/gdn_block.vhd" ;;
    qk_swap)  sed -i "s|and l2_qk = '0' and kh = h then|and l2_qk = '1' and kh = h then|" "$D/rtl/gdn_block.vhd" ;;
  esac
  if diff -q "$NEWG" "$D/rtl/gdn_block.vhd" >/dev/null; then
    echo "  VERDICT: VOID -- the sed matched nothing"; return 1; fi
  diff "$NEWG" "$D/rtl/gdn_block.vhd" | sed -n '1,5p' | sed 's/^/  /'
  ( cd "$D" && REGRESS_SCRATCH="$D/rg" timeout 3000 bash sim/regress.sh --only gdn_block --keep >"$D/regress.out" 2>&1 )
  grep -E "^ OVERALL" "$D/regress.out" | sed 's/^/  /'
  return 0
}

rm -rf /mnt/storage/writedec/mut_gdn_vbuf_off
rm -rf /mnt/storage/writedec/mut_gdn_qsb_off
rm -rf /mnt/storage/writedec/mut_gdn_no_seg
rm -rf /mnt/storage/writedec/mut_gdn_no_ph
rm -rf /mnt/storage/writedec/mut_gdn_qk_swap

echo "=== MUTANT vbuf_off ==="
build /mnt/storage/writedec/mut_gdn_vbuf_off vbuf_off && score /mnt/storage/writedec/mut_gdn_vbuf_off vbuf_off
rm -rf /mnt/storage/writedec/mut_gdn_vbuf_off

echo "=== MUTANT qsb_off ==="
build /mnt/storage/writedec/mut_gdn_qsb_off qsb_off && score /mnt/storage/writedec/mut_gdn_qsb_off qsb_off
rm -rf /mnt/storage/writedec/mut_gdn_qsb_off

echo "=== MUTANT no_seg ==="
build /mnt/storage/writedec/mut_gdn_no_seg no_seg && score /mnt/storage/writedec/mut_gdn_no_seg no_seg
rm -rf /mnt/storage/writedec/mut_gdn_no_seg

echo "=== MUTANT no_ph ==="
build /mnt/storage/writedec/mut_gdn_no_ph no_ph && score /mnt/storage/writedec/mut_gdn_no_ph no_ph
rm -rf /mnt/storage/writedec/mut_gdn_no_ph

echo "=== MUTANT qk_swap ==="
build /mnt/storage/writedec/mut_gdn_qk_swap qk_swap && score /mnt/storage/writedec/mut_gdn_qk_swap qk_swap
rm -rf /mnt/storage/writedec/mut_gdn_qk_swap
