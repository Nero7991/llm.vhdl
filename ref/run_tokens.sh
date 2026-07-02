#!/bin/sh
# ref/run_tokens.sh [N=200]
# Compile run_fx.c, run fp and --fx paths, compare TOKID token streams.
# Pass:   prints "agree N / N" then "COHERENT EXACT", exits 0.
# Fail:   prints "agree K / N" + first divergent token, exits 1.
set -e
N=${1:-200}

REFDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REFDIR"

echo "building run_fx..."
gcc -O2 -o run_fx run_fx.c -lm

FP_LOG=/tmp/runtok_fp_$$.txt
FX_LOG=/tmp/runtok_fx_$$.txt
FP_IDS=/tmp/runtok_fp_ids_$$.txt
FX_IDS=/tmp/runtok_fx_ids_$$.txt

echo "running fp path (n=$N)..."
./run_fx stories260K.bin -z tok512.bin -t 0 -i "Once upon a time" -n "$N" \
    2>"$FP_LOG" >/dev/null

echo "running --fx path (n=$N)..."
./run_fx stories260K.bin -z tok512.bin -t 0 -i "Once upon a time" -n "$N" --fx \
    2>"$FX_LOG" >/dev/null

grep '^TOKID ' "$FP_LOG" | awk '{print $2}' >"$FP_IDS"
grep '^TOKID ' "$FX_LOG" | awk '{print $2}' >"$FX_IDS"

python3 - "$N" "$FP_IDS" "$FX_IDS" <<'PYEOF'
import sys
n_want = int(sys.argv[1])
fp = open(sys.argv[2]).read().split()
fx = open(sys.argv[3]).read().split()
n = min(len(fp), len(fx), n_want)
agree = sum(1 for i in range(n) if fp[i] == fx[i])
print(f"agree {agree} / {n}")
if agree == n and n == n_want:
    print("COHERENT EXACT")
    sys.exit(0)
else:
    for i in range(n):
        if fp[i] != fx[i]:
            print(f"first divergence at token {i}: fp={fp[i]} fx={fx[i]}")
            break
    if len(fp) < n_want or len(fx) < n_want:
        print(f"WARNING: fp={len(fp)} fx={len(fx)} tokens (expected {n_want})")
    sys.exit(1)
PYEOF

STATUS=$?
rm -f "$FP_LOG" "$FX_LOG" "$FP_IDS" "$FX_IDS"
exit $STATUS
