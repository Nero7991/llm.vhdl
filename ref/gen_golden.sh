#!/bin/sh
set -e
# Run from repo root: sh ref/gen_golden.sh
cd "$(dirname "$0")/.."
mkdir -p mem/golden mem/weights
gcc -O3 -DLLAMAVHDL_DUMP -o ref/runq_dump ref/runq.c -lm
./ref/runq_dump ref/stories260K_q.bin -z ref/tok512.bin -t 0 -i "Once upon a time" -n 40
echo "--- golden written to mem/golden/ ---"
ls mem/golden/
ls mem/weights/
