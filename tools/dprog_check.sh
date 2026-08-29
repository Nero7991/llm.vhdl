#!/usr/bin/env bash
# tools/dprog_check.sh -- the standing check on the descriptor PROGRAM.
#
# WHY THIS EXISTS.  `tools/dprog_oracle.py` (TRACK D-PROG, 98755cb) is the only
# check on the layer program that is not an agreement check against the
# schedule itself: it decodes the emitted BYTES and judges them against
# `tools/ref9b/seam_map.py` (llama.cpp's execution order), `manifest.json`, and
# each packed `.mv4i` file's own 4 KB header.  It landed as a tool with a
# reproduce recipe in a write-up, which means it runs when somebody remembers
# the recipe.  This is the recipe, as one command, so it runs when somebody
# does not.
#
# WHAT IT CHECKS, and this is the whole point:
#
#   PROGRAM   `gen_layer_program.py --stamp manifest`, the thing a host would
#             actually write into HBM.  MUST pass, 0 FAIL.
#
#   CONTROL   `--stamp sched`, the field stamping of `sim/llama_sched_pkg.vhd`.
#             MUST FAIL, and the count is printed.  A directional control:
#             those two VHDL tables are stimulus, deliberately carrying
#             index-derived `w_exp` / `out_shift`, and if this run ever starts
#             PASSING then either the oracle has lost its teeth or somebody has
#             turned a testbench table into a program.  Either is a finding.
#
# THE TRAP, propagated from D-PROG's write-up: `gen_layer_program.py` defaults
# to the PRE-QKV-PAD packed set, where 48 of 311 A jobs are refused.  ALWAYS
# pass --manifest.  This script does, and refuses to guess.
#
# NOT A GATE ROW.  `sim/regress.sh` discovers rows from `sim/tb_*.vhd` only,
# and this needs the 6.7 GB packed model, which a fresh clone does not have.
# It exits 0 with a SKIP line when the packed set is absent, so it is safe to
# put in front of a commit hook or a CI step that may not have the weights.
#
# The half of this question that needs NO model is `tools/check_a_geometry.py`
# (every source site that states A's geometry) and `sim/tb_a_geom.vhd` (the
# same numbers, with the RTL as judge).  Run all three.
#
# ONE DEPENDENCY THAT IS NOT THIS TRACK'S: the oracle imports
# `tools/ref9b/seam_map.py`, which belongs to whichever track is working on the
# 9B reference.  MEASURED 2026-08-29: an uncommitted edit there moved the graph
# from 504 seams to 505 and this script went red on `C1-count` with the program
# unchanged.  A C1-count failure alone, with every other check clean, is a
# seam_map question and not a program question -- confirm with
# `git diff -- tools/ref9b/seam_map.py` before believing it.
#
# Usage: tools/dprog_check.sh [MANIFEST]
set -u
here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(dirname "$here")
mani=${1:-/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json}

if [ ! -f "$mani" ]; then
  echo "dprog_check: SKIP -- no packed set at $mani"
  echo "dprog_check: pass the manifest path as \$1 to check a set elsewhere."
  exit 0
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
rc=0

echo "=== PROGRAM: --stamp manifest, must PASS ==============================="
python3 "$here/gen_layer_program.py" --token --x-exp 5 --no-hash \
        --manifest "$mani" --outdir "$out/prog" \
        --d-table "$out/prog/d_table.hex" || rc=1
python3 "$here/dprog_oracle.py" --d-table "$out/prog/d_table.hex" \
        --adir "$out/prog" --manifest "$mani" || rc=1

echo
echo "=== CONTROL: --stamp sched, must FAIL ================================="
python3 "$here/gen_layer_program.py" --token --x-exp 5 --no-hash \
        --manifest "$mani" --stamp sched --outdir "$out/sched" \
        --d-table "$out/sched/d_table.hex" || rc=1
python3 "$here/dprog_oracle.py" --d-table "$out/sched/d_table.hex" \
        --adir "$out/sched" --manifest "$mani" > "$out/sched.log" 2>&1
ctl=$?
tail -2 "$out/sched.log"
# NOT `oracle | tail`: a pipeline's status is the LAST command's, so `tail`
# would report success for every run and this control would never fire.
if [ "$ctl" -eq 0 ]; then
  echo "dprog_check: FAIL -- the sched-stamped table PASSED the oracle."
  echo "  It is a testbench stimulus table with index-derived w_exp/out_shift"
  echo "  and it is not supposed to pass.  Either the oracle lost its teeth or"
  echo "  sim/llama_sched_pkg.vhd has been turned into a program."
  rc=1
else
  echo "dprog_check: control FAILED as required."
fi

echo
if [ "$rc" -eq 0 ]; then
  echo "DPROG_CHECK: PASS"
else
  echo "DPROG_CHECK: FAIL"
fi
exit "$rc"
