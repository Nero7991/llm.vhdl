#!/usr/bin/env bash
# jc_ctxtest.sh -- the context tests on the Jungle Cat, run after every JC card build.
# Port of hw/fk33/host/fk33_ctxtest.sh with the transport swapped to the JC broker
# (tools/jc/jc_broker.py over a Unix socket, server/fk33_transport_jc.c).
#
#     hw/jc/host/jc_ctxtest.sh pair   <outdir> [N] [--dry-run]   # die A = card 0, die B = card 1
#     hw/jc/host/jc_ctxtest.sh single <outdir> [N] [--dry-run]   # one die (JC_DIE, default A)
#
# Standing instruction (CLAUDE.md, "AFTER EVERY CARD BUILD"): N = 500, input and output,
# each run twice, gate on ^CTXTEST_PASS.  WHY the repeats and the dumps: see the header of
# hw/fk33/host/fk33_ctxtest.sh (build 19's position-32 hang, 2 in 15 passes).
#
# WHAT IT RUNS, each REPEATS times (default 2):
#   input   a real-text prompt of exactly N ids (tools/ctx_prompt.py), 1 id out.
#   output  a 16-id prompt, then generation with the stop token DISABLED (`--stop -1`)
#           until N GOs have run.
# WHAT IT CHECKS, per run: rc 0, run_prompt's `timing` line reports exactly N GOs, and every
# die's seam shows err=0 afterwards (hw/jc/host/jc_seam.py seam, fk33ctl.py's own report
# read through the broker).  Across the repeats: identical generated ids.  Stops at the
# first failure.
#
# DIFFERENCES FROM THE FK33 SCRIPT, and why:
#   - No fk33_chat2.sh.  That wrapper writes the token program's arena and zeroes the GDN
#     state through H2C DMA; the JC transport refuses every HBM write (mem_write is -EPERM,
#     server/fk33_transport_jc.c) and only coe_load.py writes HBM, on the BMC the broker
#     holds.  So the token programs are generated beforehand (JC_RUN0/JC_RUN1 hold
#     token.dtbl and token.rel) and the arena is loaded by coe_load.py beforehand
#     (docs/superpowers/plans/2026-10-09-jc-silicon-runbook.md).
#   - THE GDN STATE IS RE-ZEROED BEFORE EVERY RUN, as the FK33 does: fk33_ctxtest.sh runs
#     one fk33_chat2.sh per run, and chat2 zeroes hbm.gdn_state_bytes at gdn_state_base on
#     both cards before run_prompt (fk33_chat2.sh:131-135; fk33_chat.sh:168-173).  JC_PREP
#     is run before EVERY run and defaults to `bash hw/jc/host/jc_bc_lane.sh rezero` (stop
#     the broker, coe_load.py side_gdn.json on both dies, verify, restart the broker), which
#     needs that script's environment (JC_BC, JC_BMC, JC_BCW, JC_BC_MAN0/1).  JC_NO_REZERO=1
#     skips it, and the script then says the state is NOT re-zeroed.
#   - run_prompt is invoked directly with `--jc SOCK --jc-die D [--jc-die2 D2]` (added
#     2026-10-09, server/tests/test_run_prompt_jc.py).  A real run still refuses unless
#     `run_prompt --help` lists `--jc`; --dry-run does not need the binary.
#   - The broker serves ONE client: run_prompt and jc_seam.py take turns, never overlap.
#
# ENVIRONMENT
#   JC_SOCK              the broker's Unix socket as seen from THIS host (required)
#   JC_RUN0 / JC_RUN1    token program dirs (token.dtbl, token.rel) for card 0 / card 1
#   JC_MAN0 / JC_MAN1    the manifests of the images resident on card 0's / card 1's die
#   JC_DIE0 / JC_DIE1    pair mode dies (default A / B);  JC_DIE  single mode die (default A)
#   JC_EMBED             token embedding (default the 27B mv4i)
#   JC_QTK               tokenizer (default build_artifacts_tok/qwen35_9b.qtk: the 27B GGUF's
#                        tokens and merges hash identical to the 9B's, checked 2026-10-09)
#   JC_PREP              shell command run before every run (default: the GDN re-zero,
#                        `bash <repo>/hw/jc/host/jc_bc_lane.sh rezero`)
#   JC_NO_REZERO=1       run no JC_PREP at all (the GDN state carries over between runs)
#   RUN_PROMPT           default <repo>/server/run_prompt
#   REPEATS (2), TESTS ("input output")
#
# Sentinels, line-anchored: ^CTXTEST_RUN, ^CTXTEST_PASS, ^CTXTEST_FAIL.  --dry-run prints
# every command prefixed `DRYRUN ` and creates nothing; it never prints a sentinel.
# A real run drives the board through the broker: the main session or Oren runs it,
# never a subagent.
set -uo pipefail
DRY=0
ARGS=()
for a in "$@"; do
  if [[ "$a" == --dry-run ]]; then DRY=1; else ARGS+=("$a"); fi
done
MODE="${ARGS[0]:-}"
OUT="${ARGS[1]:-}"
NARG="${ARGS[2]:-}"
[[ -n "$MODE" && -n "$OUT" ]] || { echo "usage: jc_ctxtest.sh pair|single <outdir> [N] [--dry-run]" >&2; exit 2; }
REPEATS="${REPEATS:-2}"
TESTS="${TESTS:-input output}"
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SEAM="$REPO/hw/jc/host/jc_seam.py"
RUN_PROMPT="${RUN_PROMPT:-$REPO/server/run_prompt}"
QTK="${JC_QTK:-$REPO/build_artifacts_tok/qwen35_9b.qtk}"
EMB="${JC_EMBED:-/mnt/storage/llama-models/qwen38-27b-mv4i/token_embd.weight.mv4i}"
SOCK="${JC_SOCK:-}"
OUTPROMPT=16
LOG="$OUT/ctxtest.log"
if [[ "${JC_NO_REZERO:-0}" == 1 ]]; then
  JC_PREP=""
else
  JC_PREP="${JC_PREP:-bash $REPO/hw/jc/host/jc_bc_lane.sh rezero}"
fi

case "$MODE" in
  pair)   DIES="${JC_DIE0:-A} ${JC_DIE1:-B}" ;;
  single) DIES="${JC_DIE:-A}" ;;
  *) echo "jc_ctxtest.sh: mode must be pair or single" >&2; exit 2 ;;
esac
read -r -a DIE <<< "$DIES"
MANS=("${JC_MAN0:-}" "${JC_MAN1:-}")
RUNS=("${JC_RUN0:-}" "${JC_RUN1:-}")

if [[ $DRY == 1 ]]; then
  say() { echo "DRYRUN say $*"; }
else
  say() { echo "$*" | tee -a "$LOG"; }
fi
fail_early() { if [[ $DRY == 1 ]]; then echo "jc_ctxtest.sh: $*" >&2; else say "CTXTEST_FAIL $*"; fi; exit 1; }

# ex OUTFILE ERRFILE cmd...   ERRFILE "=" means 2>&1 into OUTFILE, "-" means no redirection.
ex() {
  local o="$1" e="$2"; shift 2
  local q; q=$(printf '%q ' "$@"); q="${q% }"
  if [[ $DRY == 1 ]]; then
    case "$e" in
      =) echo "DRYRUN $q > $o 2>&1" ;;
      -) echo "DRYRUN $q" ;;
      *) echo "DRYRUN $q > $o 2> $e" ;;
    esac
    return 0
  fi
  case "$e" in
    =) "$@" > "$o" 2>&1 ;;
    -) "$@" ;;
    *) "$@" > "$o" 2> "$e" ;;
  esac
}

[[ -n "$SOCK" ]] || fail_early "JC_SOCK is not set: give the broker's Unix socket path as seen from this host"
need=("$QTK" "$EMB")
for i in "${!DIE[@]}"; do
  [[ -n "${MANS[$i]}" && -n "${RUNS[$i]}" ]] || fail_early "JC_MAN$i and JC_RUN$i must be set for die ${DIE[$i]}"
  need+=("${MANS[$i]}" "${RUNS[$i]}/token.dtbl" "${RUNS[$i]}/token.rel")
done

if [[ $DRY == 0 ]]; then
  mkdir -p "$OUT"
  for f in "${need[@]}"; do [[ -e "$f" ]] || fail_early "missing $f"; done
  [[ -x "$RUN_PROMPT" ]] || fail_early "no run_prompt at $RUN_PROMPT (make -C server run_prompt)"
  "$RUN_PROMPT" --help 2>&1 | grep -qE -- '--jc[ ]' \
    || fail_early "$RUN_PROMPT has no --jc option: the JC transport is not reachable from run_prompt yet (see this script's header)"
  python3 "$SEAM" status --sock "$SOCK" > "$OUT/broker_status.txt" 2>&1 \
    && grep -qE '^JCSEAM_STATUS ok' "$OUT/broker_status.txt" \
    || fail_early "the broker at $SOCK does not answer, or is halted (see $OUT/broker_status.txt)"
else
  for f in "${need[@]}"; do echo "DRYRUN check exists $f"; done
  echo "DRYRUN $(printf '%q' "$RUN_PROMPT") --help | grep -qE -- '--jc[ ]'"
  echo "DRYRUN python3 $(printf '%q' "$SEAM") status --sock $(printf '%q' "$SOCK") > $OUT/broker_status.txt 2>&1"
fi

seams() {   # $1 = tag; dump every die's seam, return 1 if any has err=1
  local bad=0 i d f
  for i in "${!DIE[@]}"; do
    d="${DIE[$i]}"; f="$OUT/$1_seam_$d.txt"
    ex "$f" = timeout 300 python3 "$SEAM" seam --sock "$SOCK" --die "$d" --manifest "${MANS[$i]}"
    if [[ $DRY == 0 ]] && grep -qE '^status .* err=1' "$f"; then bad=1; fi
  done
  return $bad
}

# ---- N: the context capacity, from the dies and the manifests -----------------------
if [[ -z "$NARG" ]]; then
  N=0
  for i in "${!DIE[@]}"; do
    k=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['hbm']['max_context_tokens'])" "${MANS[$i]}" 2>/dev/null)
    if [[ $DRY == 1 ]]; then
      ex "$OUT/cap_seam_${DIE[$i]}.txt" = timeout 300 python3 "$SEAM" seam --sock "$SOCK" --die "${DIE[$i]}" --manifest "${MANS[$i]}"
      c="$k"   # the seam's CAPS_CTX is unknowable without the board
    else
      c=$(timeout 300 python3 "$SEAM" seam --sock "$SOCK" --die "${DIE[$i]}" --manifest "${MANS[$i]}" 2>/dev/null \
          | sed -n 's/^caps .* ctx \([0-9]*\) tokens.*/\1/p')
    fi
    [[ -n "$c" && -n "$k" ]] || fail_early "cannot read the context capacity of die ${DIE[$i]} (seam ctx '$c', manifest '${MANS[$i]}' max_context_tokens '$k')"
    v=$(( c < k ? c : k ))
    if [[ $N -eq 0 || $v -lt $N ]]; then N=$v; fi
    say "capacity die ${DIE[$i]}  seam ctx $c  manifest max_context_tokens $k  (${MANS[$i]})"
  done
  FULL=1
else
  N=$NARG; FULL=0
fi
[[ "$N" =~ ^[0-9]+$ && $N -gt $OUTPROMPT ]] || fail_early "N=$N is not above the $OUTPROMPT-id output prompt"
say "context test (JC): mode $MODE, dies ${DIES}, N $N ($([[ $FULL == 1 ]] && echo FULL || echo 'SHORT, not the full context')), $REPEATS repeats, $(date '+%F %T')"

ex "$OUT/ctx_prompt.log" = python3 "$REPO/tools/ctx_prompt.py" --qtk "$QTK" --n "$N" --out "$OUT/prompt_input.txt" \
  || fail_early "tools/ctx_prompt.py failed (see $OUT/ctx_prompt.log)"
if [[ $DRY == 1 ]]; then
  echo "DRYRUN head -n $OUTPROMPT $OUT/prompt_input.txt > $OUT/prompt_output.txt"
else
  cat "$OUT/ctx_prompt.log" >> "$LOG"
  head -n "$OUTPROMPT" "$OUT/prompt_input.txt" > "$OUT/prompt_output.txt"
fi

seams pre || fail_early "a die already holds a sticky error before the test (see $OUT/pre_seam_*.txt); clear or reload it first"
[[ -n "${JC_PREP:-}" ]] || say "NOTE JC_NO_REZERO=1: the GDN state is NOT re-zeroed between runs (SEQ_RESET only), unlike the FK33 flow"

# The run_prompt command for one run: $1 = test, $2 = max-new, $3 = tag
rp_cmd() {
  RP=("$RUN_PROMPT" --jc "$SOCK" --jc-die "${DIE[0]}")
  if [[ $MODE == pair ]]; then RP+=(--jc-die2 "${DIE[1]}"); fi
  RP+=(--seq-reset --v2 --dtbl "${RUNS[0]}/token.dtbl" --rel "${RUNS[0]}/token.rel")
  if [[ $MODE == pair ]]; then RP+=(--dtbl2 "${RUNS[1]}/token.dtbl" --rel2 "${RUNS[1]}/token.rel"); fi
  RP+=(--manifest "${MANS[0]}")
  if [[ $MODE == pair ]]; then RP+=(--manifest2 "${MANS[1]}"); fi
  RP+=(--prompt "$OUT/prompt_$1.txt" --qtk "$QTK" --stream --max-new "$2" --mv4i "$EMB" --quiet
       --stop -1 --ids-out "$OUT/$3.ids")
}

fail=0
for T in $TESTS; do
  if [[ $T == input ]]; then MAXNEW=1; else MAXNEW=$(( N - OUTPROMPT + 1 )); fi
  for r in $(seq 1 "$REPEATS"); do
    tag="${T}_r$r"
    if [[ -n "${JC_PREP:-}" ]]; then
      if [[ $DRY == 1 ]]; then echo "DRYRUN prep $JC_PREP"
      elif ! bash -c "$JC_PREP" >> "$OUT/${tag}.prep" 2>&1; then
        say "CTXTEST_FAIL $tag: JC_PREP failed (see $OUT/${tag}.prep)"; fail=1; break 2
      fi
    fi
    say "CTXTEST_RUN $tag start $(date +%T): prompt $([[ $DRY == 1 ]] && echo '?' || wc -l < "$OUT/prompt_$T.txt") ids, max-new $MAXNEW, want $N GOs"
    t0=$(date +%s)
    rp_cmd "$T" "$MAXNEW" "$tag"
    ex "$OUT/$tag.out" "$OUT/$tag.err" "${RP[@]}"
    rc=$?
    seams "$tag"; serr=$?
    [[ $DRY == 1 ]] && continue
    gos=$(sed -n 's/^timing *\([0-9]*\) GOs.*/\1/p' "$OUT/$tag.out" | tail -1)
    say "CTXTEST_RUN $tag end $(date +%T): rc $rc, $gos GOs, $(( $(date +%s) - t0 )) s, seam error $serr"
    if [[ $rc -ne 0 || "$gos" != "$N" || $serr -ne 0 ]]; then
      say "CTXTEST_FAIL $tag: rc $rc, GOs '$gos' (want $N), seam error $serr.  Evidence: $OUT/$tag.{out,err} and $OUT/${tag}_seam_*.txt"
      # Name each die by its IMAGE record, not by its letter alone.
      for d in "${DIE[@]}"; do
        say "  die $d"
        grep -h -E "^image|^status|D's own code|^last job|^progress" "$OUT/${tag}_seam_$d.txt" | sed 's/^/    /' | tee -a "$LOG"
      done
      fail=1; break 2
    fi
  done
  if [[ $REPEATS -gt 1 ]]; then
    for r in $(seq 2 "$REPEATS"); do
      if [[ $DRY == 1 ]]; then echo "DRYRUN cmp -s $OUT/${T}_r1.ids $OUT/${T}_r$r.ids"; continue; fi
      if ! cmp -s "$OUT/${T}_r1.ids" "$OUT/${T}_r$r.ids"; then
        say "CTXTEST_FAIL $T: run $r's generated ids differ from run 1's ($OUT/${T}_r1.ids vs ${T}_r$r.ids); the dies are not deterministic"
        fail=1; break 2
      fi
    done
    [[ $DRY == 1 ]] || say "$T: all $REPEATS runs produced identical ids ($(wc -l < "$OUT/${T}_r1.ids") ids)"
  fi
done

if [[ $DRY == 1 ]]; then
  echo "DRYRUN gate grep -qE '^CTXTEST_PASS' $LOG"
  echo "DRYRUN_DONE mode $MODE dies $DIES N $N repeats $REPEATS tests '$TESTS': nothing was run"
  exit 0
fi
if [[ $fail -eq 0 ]]; then
  say "CTXTEST_PASS mode $MODE dies $DIES N $N $([[ $FULL == 1 ]] && echo FULL || echo SHORT) repeats $REPEATS tests '$TESTS': every run reached $N GOs with no die error, ids identical across runs"
  grep -qE '^CTXTEST_PASS' "$LOG" || exit 1
  exit 0
fi
exit 1
