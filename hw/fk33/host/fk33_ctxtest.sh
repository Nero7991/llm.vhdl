#!/usr/bin/env bash
# fk33_ctxtest.sh -- the FULL-CONTEXT tests, run after every card build.
#
#     hw/fk33/host/fk33_ctxtest.sh pair   <outdir> [N]    # both cards, the split model
#     hw/fk33/host/fk33_ctxtest.sh single <outdir> [N]    # one card (FK33_USER picks it; default xdma0)
#
# Standing instruction from Oren, 2026-09-24: "full input context and full
# output context length tests after every build, ran two times, so issues
# surface better."  WHY, MEASURED the same day: build 19 hung intermittently in
# the attention unit at position 32 (the first KV-block boundary), about 2 in
# 15 passes, and every earlier silicon test was a 20..25-id prompt with 64
# tokens out, which crosses one boundary once.  A context test crosses every
# boundary the card has, twice.
#
# WHAT IT RUNS, each REPEATS times (default 2):
#   input   a real-text prompt of exactly N ids (tools/ctx_prompt.py), 1 id out:
#           N GOs at positions 0..N-1, all of them prefill.
#   output  a 16-id prompt, then generation with the stop token DISABLED
#           (`--stop -1`) until N GOs have run: positions 16..N-1 are decode.
# N defaults to the FULL context: the smaller of the seam's CAPS_CTX and the
# resident manifest's hbm.max_context_tokens, over every card involved.
#
# WHAT IT CHECKS, per run: rc 0, the `timing` line reports exactly N GOs, and
# every card's seam shows err=0 afterwards.  Across the repeats: the generated
# ids are IDENTICAL (`--ids-out`), since the card is deterministic and a
# difference is a defect.  Each card's seam is dumped to <outdir> straight
# after EVERY run, before anything else can overwrite a sticky error record.
# Stops at the first failure: a wedged unit fails every later token anyway.
#
# COST.  About 0.24 s per GO on the 9B (MEASURED, pair and single), so one
# full run at N = 65,536 is ~4.4 h and the default four runs ~17.5 h, with the
# cards unusable meanwhile.  Pass a smaller N for a quick pass; the verdict
# line says which N was run, so a short run is never mistaken for the full one.
#
# Sentinels, line-anchored: ^CTXTEST_RUN, ^CTXTEST_PASS, ^CTXTEST_FAIL.
# Opens /dev/xdma* -- a human or the main session runs this, never a subagent.
set -uo pipefail
MODE="${1:?usage: fk33_ctxtest.sh pair|single <outdir> [N]}"
OUT="${2:?usage: fk33_ctxtest.sh pair|single <outdir> [N]}"
NARG="${3:-}"
REPEATS="${REPEATS:-2}"
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CTL="$REPO/hw/fk33/host/fk33ctl.py"
IMGFP="$REPO/hw/fk33/host/fk33_imgfp.py"
QTK="${FK33_QTK:-$REPO/build_artifacts_tok/qwen35_9b.qtk}"
OUTPROMPT=16
mkdir -p "$OUT"
LOG="$OUT/ctxtest.log"
say() { echo "$*" | tee -a "$LOG"; }

case "$MODE" in
  pair)   NODES="/dev/xdma0 /dev/xdma1"; CHAT="$REPO/hw/fk33/host/fk33_chat2.sh" ;;
  single) NODES="${FK33_USER:-/dev/xdma0_user}"; NODES="${NODES%_user}"; CHAT="$REPO/hw/fk33/host/fk33_chat.sh" ;;
  *) echo "fk33_ctxtest.sh: mode must be pair or single" >&2; exit 2 ;;
esac

# All THREE nodes, always: fk33ctl.py reads BAR registers through FK33_USER
# but the image record through FK33_H2C/FK33_C2H, which default to xdma0.
# MEASURED 2026-09-24 on this script's first run: with FK33_USER alone, the
# seam dump of xdma1 (card 1, blocks 0-15) printed card 2's image record, so
# the status lines were card 1's and the image block beside them was not.
node_env() { echo "FK33_USER=${1}_user FK33_H2C=${1}_h2c_0 FK33_C2H=${1}_c2h_0"; }
seams() {   # $1 = tag; dump every node's seam, return 1 if any has err=1
  local bad=0 n
  for n in $NODES; do
    env $(node_env "$n") timeout 60 python3 "$CTL" seam > "$OUT/$1_seam_$(basename "$n").txt" 2>&1
    if grep -qE '^status .* err=1' "$OUT/$1_seam_$(basename "$n").txt"; then bad=1; fi
  done
  return $bad
}

# ---- N: the full context, from the cards themselves -------------------------
if [[ -z "$NARG" ]]; then
  N=0
  for n in $NODES; do
    c=$(env $(node_env "$n") timeout 60 python3 "$CTL" seam 2>/dev/null | sed -n 's/^caps .* ctx \([0-9]*\) tokens.*/\1/p')
    m=$(env $(node_env "$n") timeout 60 python3 "$IMGFP" which 2>/dev/null | tail -1)
    k=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['hbm']['max_context_tokens'])" "$m" 2>/dev/null)
    [[ -n "$c" && -n "$k" ]] || { say "CTXTEST_FAIL cannot read the context capacity of $n (seam ctx '$c', manifest '$m')"; exit 1; }
    v=$(( c < k ? c : k ))
    if [[ $N -eq 0 || $v -lt $N ]]; then N=$v; fi
    say "capacity $n  seam ctx $c  manifest max_context_tokens $k  ($m)"
  done
  FULL=1
else
  N=$NARG; FULL=0
fi
[[ $N -gt $OUTPROMPT ]] || { say "CTXTEST_FAIL N=$N is not above the $OUTPROMPT-id output prompt"; exit 1; }
say "context test: mode $MODE, N $N ($([[ $FULL == 1 ]] && echo FULL || echo 'SHORT, not the full context')), $REPEATS repeats, $(date '+%F %T')"

python3 "$REPO/tools/ctx_prompt.py" --qtk "$QTK" --n "$N" --out "$OUT/prompt_input.txt" | tee -a "$LOG" || exit 1
head -n "$OUTPROMPT" "$OUT/prompt_input.txt" > "$OUT/prompt_output.txt"

seams pre || { say "CTXTEST_FAIL a card already holds a sticky error before the test (see $OUT/pre_seam_*.txt); clear or reload it first"; exit 1; }

fail=0
for T in input output; do
  if [[ $T == input ]]; then MAXNEW=1; else MAXNEW=$(( N - OUTPROMPT + 1 )); fi
  for r in $(seq 1 "$REPEATS"); do
    tag="${T}_r$r"
    say "CTXTEST_RUN $tag start $(date +%T): prompt $(wc -l < "$OUT/prompt_$T.txt") ids, max-new $MAXNEW, want $N GOs"
    t0=$(date +%s)
    FK33_PROMPT_IDS="$OUT/prompt_$T.txt" bash "$CHAT" "context test" "$MAXNEW" \
        --stop -1 --ids-out "$OUT/$tag.ids" > "$OUT/$tag.out" 2> "$OUT/$tag.err"
    rc=$?
    seams "$tag"; serr=$?
    gos=$(sed -n 's/^timing *\([0-9]*\) GOs.*/\1/p' "$OUT/$tag.out" | tail -1)
    say "CTXTEST_RUN $tag end $(date +%T): rc $rc, $gos GOs, $(( $(date +%s) - t0 )) s, seam error $serr"
    if [[ $rc -ne 0 || "$gos" != "$N" || $serr -ne 0 ]]; then
      say "CTXTEST_FAIL $tag: rc $rc, GOs '$gos' (want $N), seam error $serr.  Evidence: $OUT/$tag.{out,err} and $OUT/${tag}_seam_*.txt"
      # Name the card by its IMAGE: node numbers swap on every JTAG reload.
      for n in $NODES; do
        say "  $n holds $(env $(node_env "$n") timeout 60 python3 "$IMGFP" which 2>/dev/null | tail -1)"
        grep -h -E "^status|D's own code|^last job|^progress" "$OUT/${tag}_seam_$(basename "$n").txt" | sed 's/^/    /' | tee -a "$LOG"
      done
      fail=1; break 2
    fi
  done
  if [[ $REPEATS -gt 1 ]]; then
    for r in $(seq 2 "$REPEATS"); do
      if ! cmp -s "$OUT/${T}_r1.ids" "$OUT/${T}_r$r.ids"; then
        say "CTXTEST_FAIL $T: run $r's generated ids differ from run 1's ($OUT/${T}_r1.ids vs ${T}_r$r.ids); the card is not deterministic"
        fail=1; break 2
      fi
    done
    say "$T: all $REPEATS runs produced identical ids ($(wc -l < "$OUT/${T}_r1.ids") ids)"
  fi
done

if [[ $fail -eq 0 ]]; then
  say "CTXTEST_PASS mode $MODE N $N $([[ $FULL == 1 ]] && echo FULL || echo SHORT) repeats $REPEATS: input and output, every run reached $N GOs with no card error, ids identical across runs"
  exit 0
fi
exit 1
