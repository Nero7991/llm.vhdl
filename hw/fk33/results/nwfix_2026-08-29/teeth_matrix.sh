#!/usr/bin/env bash
# TRACK NWFIX -- the oracle's teeth matrix, re-runnable.  Base first.
set -u
cd /mnt/storage/nwfix/ghdl
run(){ ( ulimit -s unlimited; ghdl -r --std=08 nwfix_oracle -gNORM_W_IMAGE="$1" -gNN=4096 --max-stack-alloc=0 2>&1 | grep -v "report note" ); }
IMG=/mnt/storage/nwfix/img/norm_w_9b.hex
python3 nwfix_oracle.py "$IMG" 4096 > py_9b.txt
run "$IMG" > v_base.txt
if diff -q v_base.txt py_9b.txt >/dev/null; then
  echo "BASE PASS  VHDL NW_TBL == independent python reader, $(wc -l < py_9b.txt) rows each"
else
  echo "BASE FAIL -- every mutation below is meaningless.  Stop."; diff v_base.txt py_9b.txt | head; exit 1
fi
for t in t1 t2 t3 t6; do
  run /mnt/storage/nwfix/ghdl/m_$t.hex > v_$t.txt
  if diff -q v_$t.txt v_base.txt >/dev/null; then echo "$t NOT CAUGHT"
  else echo "$t CAUGHT  ($(diff v_$t.txt v_base.txt | grep -c '^<') row(s) differ)"; fi
done
for t in t4 t5; do
  ( ulimit -s unlimited; ghdl -r --std=08 nwfix_oracle -gNORM_W_IMAGE=/mnt/storage/nwfix/ghdl/m_$t.hex -gNN=4096 -gSKIP_OLD=true --max-stack-alloc=0 >/dev/null 2>&1 )
  rc=$?
  if [ $rc -ne 0 ]; then echo "$t REFUSED by the shipping nw_count (rc=$rc)"; else echo "$t NOT REFUSED -- the refusal has no teeth"; fi
done
