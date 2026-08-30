#!/usr/bin/env bash
# TRACK WRITEDEC teeth-check for attn_block's new write decode.
#
# Oracle: run sim/tb_attn_block against the PRE-change RTL and against the
# mutant, dump every signal GHDL's VCD reaches, and compare SIGNAL BY SIGNAL BY
# NAME with vcdcmp.py.  A plain diff of two VCDs is NOT an equivalence test --
# one added signal renumbers every identifier code after it -- which is why the
# comparison goes through vcdcmp.py and not through diff.
#
# NOTE ON DELETION.  Every deleted path below is written out LITERALLY.  A
# `rm -rf "$VAR"` whose variable is empty deletes from the filesystem root;
# this file does not contain that form.
set -u
SRC=/mnt/storage/writedec/src
NEWA=/home/orencollaco/GitHub/llama.vhdl/rtl/attn_block.vhd
BASEVCD=/mnt/storage/writedec/vcd_tb_attn_block_base.vcd

build(){   # $1 dir  $2 name
  local D="$1" M="$2"
  cp -r "$SRC" "$D"
  cp "$NEWA" "$D/rtl/attn_block.vhd"
  case $M in
    qplane_off) sed -i 's|           and qh = g then|           and qh = (g+1) mod G then|' "$D/rtl/attn_block.vhd" ;;
    krec_blkoff) sed -i "s|elsif rbv(2) = '1' and ph /= P_RECV and rbi = j/KV_BLOCK then|elsif rbv(2) = '1' and ph /= P_RECV and rbi = (j/KV_BLOCK + 1) mod NBLK then|" "$D/rtl/attn_block.vhd" ;;
    vrec_isv)   sed -i "s|          elsif kq_mv = '1' and kq_isv = '1'|          elsif kq_mv = '1' and kq_isv = '0'|" "$D/rtl/attn_block.vhd" ;;
    krec_nobyp) sed -i "s|          if ph = P_RECK and is_byp = '1' then|          if ph = P_RECK then|" "$D/rtl/attn_block.vhd" ;;
    qpl_nolsel) sed -i "s|        if rst = '0' and ph = P_ROPEW and rp_dn = '1' and lsel /= 0|        if rst = '0' and ph = P_ROPEW and rp_dn = '1'|" "$D/rtl/attn_block.vhd" ;;
  esac
  if diff -q "$NEWA" "$D/rtl/attn_block.vhd" >/dev/null; then
    echo "  VERDICT: VOID -- the sed matched nothing"; return 1; fi
  diff "$NEWA" "$D/rtl/attn_block.vhd" | sed -n '1,5p' | sed 's/^/  /'
  ( cd "$D" && REGRESS_SCRATCH="$D/rg" timeout 3000 bash sim/regress.sh --only tb_attn_block --keep >"$D/regress.out" 2>&1 )
  grep -E "^ OVERALL" "$D/regress.out" | sed 's/^/  /'
  return 0
}

score(){   # $1 dir
  local D="$1"
  local RD="$D/rg/sim_tb_attn_block/run"
  if [ ! -d "$RD" ]; then echo "  VERDICT: VOID -- the bench never built"; return; fi
  ( cd "$RD" && timeout 1800 ghdl -r --std=08 -frelaxed --workdir=../work -P../work \
      tb_attn_block --vcd="$D/vcd.vcd" --vcd-nodate >/dev/null 2>&1 )
  if [ ! -s "$D/vcd.vcd" ]; then echo "  VERDICT: VOID -- no VCD produced"; return; fi
  if python3 /mnt/storage/writedec/vcdcmp.py "$BASEVCD" "$D/vcd.vcd" | tail -3 | sed 's/^/  /' | grep -q "VCDCMP PASS"; then
    echo "  VERDICT: NOT CAUGHT -- resolution floor"
  else
    echo "  VERDICT: CAUGHT"
  fi
}

rm -rf /mnt/storage/writedec/mut_attn_qplane_off
rm -rf /mnt/storage/writedec/mut_attn_krec_blkoff
rm -rf /mnt/storage/writedec/mut_attn_vrec_isv
rm -rf /mnt/storage/writedec/mut_attn_krec_nobyp
rm -rf /mnt/storage/writedec/mut_attn_qpl_nolsel

echo "=== MUTANT qplane_off ==="
build /mnt/storage/writedec/mut_attn_qplane_off qplane_off && score /mnt/storage/writedec/mut_attn_qplane_off
rm -rf /mnt/storage/writedec/mut_attn_qplane_off

echo "=== MUTANT krec_blkoff ==="
build /mnt/storage/writedec/mut_attn_krec_blkoff krec_blkoff && score /mnt/storage/writedec/mut_attn_krec_blkoff
rm -rf /mnt/storage/writedec/mut_attn_krec_blkoff

echo "=== MUTANT vrec_isv ==="
build /mnt/storage/writedec/mut_attn_vrec_isv vrec_isv && score /mnt/storage/writedec/mut_attn_vrec_isv
rm -rf /mnt/storage/writedec/mut_attn_vrec_isv

echo "=== MUTANT krec_nobyp ==="
build /mnt/storage/writedec/mut_attn_krec_nobyp krec_nobyp && score /mnt/storage/writedec/mut_attn_krec_nobyp
rm -rf /mnt/storage/writedec/mut_attn_krec_nobyp

echo "=== MUTANT qpl_nolsel ==="
build /mnt/storage/writedec/mut_attn_qpl_nolsel qpl_nolsel && score /mnt/storage/writedec/mut_attn_qpl_nolsel
rm -rf /mnt/storage/writedec/mut_attn_qpl_nolsel
