#!/usr/bin/env bash
# Perplexity sweep for the subsystem B measurement.
#
# Every row is one gdn_probe run on the same tokens.  The rows are NOT
# independent samples of a noisy quantity: they are one deterministic pipeline
# perturbed in different ways, so the only thing that makes a difference
# interpretable is the noise ladder that shares this file with the substitution
# rows.  See docs/2026-08-27_epsilon-class-measurement-plan.md.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)/gdn_probe"
MODEL="${MODEL:-/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf}"
DATA="${DATA:-/mnt/storage/ppl-data/wikitext-2-raw/wiki.test.raw}"
CH="${CHUNKS:-20}"
OUT="${OUT:-/dev/stdout}"

row() {  # row <label> <args...>
  local label="$1"; shift
  local o
  o=$("$BIN" -m "$MODEL" -f "$DATA" --ctx 512 --chunks "$CH" "$@" 2>/dev/null)
  local ppl hits
  ppl=$(printf '%s\n' "$o" | awk '/^PPL/{print $3}')
  hits=$(printf '%s\n' "$o" | awk '/^callback hits/{print $4}')
  local rel
  rel=$(printf '%s\n' "$o" | awk '/^vs ggml/{print $6}')
  printf '%-34s ppl %-12s hits %-8s relRMS %s\n' "$label" "${ppl:-FAIL}" "${hits:-0}" "${rel:--}" >> "$OUT"
}

: > "$OUT"
echo "== chunks=$CH ==" >> "$OUT"
row "baseline"                      --mode baseline
row "identity(all sites)"           --mode identity
row "identity(z_gate only)"         --mode z_gate_mul
for s in 1 2 3 4 5 6; do
  row "noise 1e-8 seed $s"          --mode z_gate_mul --noise 1e-8 --noise-seed $s
done
for r in 1e-6 1e-4 1e-3 1e-2 3e-2 1e-1; do
  row "noise $r seed 1"             --mode z_gate_mul --noise $r --noise-seed 1
done
row "emit_dbl (chain control)"      --mode emit_dbl --report
row "emit_fx  fold 24"              --mode emit_fx --report --fold-heads 24
row "emit_fx  fold 48"              --mode emit_fx --report --fold-heads 48
echo "done" >> "$OUT"
