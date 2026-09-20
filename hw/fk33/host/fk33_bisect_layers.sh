#!/usr/bin/env bash
# For each block L in "$@": run the token program up to and including the FIRST A job of block L
# (reads XN = norm(X after block L-1)) with FLG_TO_SMP, and compare its argmax with the reference
# A job over the reference R_XN-L record.  Match => everything before block L is right (to argmax).
SD=/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/4d84bf97-4b0d-407d-ac40-96158eb597e1/scratchpad/xexp
M=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd
# Repo root DERIVED from this script's own location, not written in as a
# literal, so the script survives the repo directory being renamed
# (TRACK PATHFREE, 2026-09-20).  host/ is three levels below the root.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || exit 1
python3 tools/gen_layer_program.py --token --shape 9b --manifest $M/manifest.json --x-exp 0 --print --d-table $SD/probe/x.dtbl --rel-file $SD/probe/x.rel --arena-image $SD/probe/x.arena 2>&1 | sed -n '/step  opcode/,/END_TOKEN/p' > $SD/probe/steps.txt
for L in "$@"; do
  line=$(awk -v t="blk.$L.attn_qkv.weight" '$2=="A_JOB" && $3=="XN" && $NF==t && $6==0 {print; exit}' $SD/probe/steps.txt)
  [ -n "$line" ] || line=$(awk -v t="blk.$L.attn_q.weight" '$2=="A_JOB" && $3=="XN" && $NF==t {print; exit}' $SD/probe/steps.txt)
  step=$(echo "$line" | awk '{print $1}'); nrows=$(echo "$line" | awk '{print $7}'); tensor=$(echo "$line" | awk '{print $NF}')
  N=$((step+1))
  python3 hw/fk33/host/fk33ctl.py load $SD/gdn_zero.bin --offset 0x10c006000 --verify 2>&1 | grep -q PASS || { echo "L=$L state zero FAILED"; continue; }
  out=$(TAG=bis$L bash $SD/probe.sh $N 2>&1)
  card=$(echo "$out" | grep -oE "argmax [0-9]+" | tail -1 | awk '{print $2}'); faults=$(echo "$out" | grep -oE "faults +0x[0-9a-f]+" | tail -1)
  python3 - "$L" <<PY
import sys; sys.path.insert(0,'tools/ref9b'); import r9bs, numpy as np
L=int(sys.argv[1]); SD='$SD'
for r in r9bs.read(SD+'/tok0.r9bs'):
    if r.name=='R_XN-%d'%L and r.tok==0:
        open(SD+'/probe/xn_ref_%d.i16'%L,'wb').write(np.asarray(r.raw,dtype=np.int16).tobytes()); break
PY
  ref=$($SD/probe_ref $M/$tensor.mv4i $SD/probe/xn_ref_$L.i16 $nrows 2>&1 | grep -oE "argmax=[0-9]+" | cut -d= -f2)
  echo "L=$L step=$step tensor=$tensor rows=$nrows card=$card ref=$ref $faults $([ "$card" = "$ref" ] && echo MATCH || echo DIFF)"
done
