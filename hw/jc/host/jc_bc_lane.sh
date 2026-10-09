#!/usr/bin/env bash
# jc_bc_lane.sh -- the BC-250 side of a Jungle Cat run: start or stop the broker, and re-zero
# the GDN state between sequences, from the workstation over ssh.
#
#     hw/jc/host/jc_bc_lane.sh start  [--dry-run]   # broker up, gate ^JCBROKER_READY
#     hw/jc/host/jc_bc_lane.sh stop   [--dry-run]   # SIGINT the broker (clean close)
#     hw/jc/host/jc_bc_lane.sh rezero [--dry-run]   # stop, zero GDN state on both dies, start
#
# WHY REZERO EXISTS (runbook gap 4, 2026-10-09).  The FK33 host zeroes the WHOLE GDN state
# region (hbm.gdn_state_base, hbm.gdn_state_bytes: recurrent mantissas, exponents and the
# conv-tap reservation, tools/hbm_map.py:437-439) before EVERY question: fk33_chat.sh:168-173
# and fk33_chat2.sh:131-135, which fk33_ctxtest.sh (one chat2 per run) and
# server/llmvhdl_server.py (one chat2 per question) both go through.  run_prompt's
# --seq-reset clears only the seam's and the engine's positions (run_prompt.c, the
# `seq-reset` comment).  The JC must do the same as the FK33, but the JC transport refuses
# HBM writes and the spec keeps HBM writes with the USER4 loader alone
# (docs/superpowers/specs/2026-10-07-jc-engine-composition-design.md, CORRECTION 2026-10-07
# (second)), so the zero goes in through coe_load.py with the broker stopped (one BMC owner,
# spec section 4: "The broker and coe_load.py are separate lanes and never hold the BMC at
# once").  The ssh socket forward on the workstation survives this: it connects to the
# remote path per connection.
#
# ENVIRONMENT (nothing here is committed: addresses and DNAs live outside the repo)
#   JC_BC            ssh target for the BC-250, user@address (required)
#   JC_BMC           the board BMC's address (required)
#   JC_BCW           absolute, non-/tmp work dir on the BC-250 holding card0/ and card1/
#                    (side_gdn.json + gdn_zero.bin from hw/jc/host/jc_side_image.py) (required)
#   JC_BC_MAN0/1     the manifests on the BC-250 of the images on card 0's / card 1's die,
#                    e.g. ~/jc_models/qwen38-27b-card0-b0-32/manifest.json and
#                    ~/jc_models/qwen38-27b-card1-b33-63/manifest.json (required for start)
#   JC_DIE0 / JC_DIE1   card 0's / card 1's die (default A / B)
#   JC_CHAIN         default AB;  JC_BC_DIES  die record on the BC-250 (default ~/jc_dies.json)
#   JC_BC_REPO       the repo on the BC-250 (default /home/orencollaco/GitHub/llama.vhdl)
#
# Sentinels, line-anchored: ^JCLANE_DONE <cmd>, ^JCLANE_FAIL.  --dry-run prints the remote
# script with every line prefixed `DRYRUN| ` and runs nothing; it never prints a sentinel.
# A real run drives the board: the main session or Oren runs it, never a subagent.
set -uo pipefail
DRY=0; CMD=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    start|stop|rezero) CMD="$a" ;;
    *) echo "usage: jc_bc_lane.sh start|stop|rezero [--dry-run]" >&2; exit 2 ;;
  esac
done
[[ -n "$CMD" ]] || { echo "usage: jc_bc_lane.sh start|stop|rezero [--dry-run]" >&2; exit 2; }
need() { [[ -n "${!1:-}" ]] || { echo "jc_bc_lane.sh: $1 is not set" >&2; exit 2; }; }
need JC_BC; need JC_BMC; need JC_BCW
[[ "$JC_BCW" == /* && "$JC_BCW" != /tmp* ]] || { echo "jc_bc_lane.sh: JC_BCW must be absolute and not under /tmp" >&2; exit 2; }
if [[ $CMD != stop ]]; then need JC_BC_MAN0; need JC_BC_MAN1; fi
DIE0="${JC_DIE0:-A}"; DIE1="${JC_DIE1:-B}"; CHAIN="${JC_CHAIN:-AB}"
[[ "$DIE0" =~ ^[AB]$ && "$DIE1" =~ ^[AB]$ && "$DIE0" != "$DIE1" ]] || { echo "jc_bc_lane.sh: JC_DIE0/JC_DIE1 must be A and B in some order" >&2; exit 2; }
[[ "$CHAIN" =~ ^(AB|BA)$ ]] || { echo "jc_bc_lane.sh: JC_CHAIN must be AB or BA" >&2; exit 2; }
BREPO="${JC_BC_REPO:-/home/orencollaco/GitHub/llama.vhdl}"
DIESF="${JC_BC_DIES:-\$HOME/jc_dies.json}"
q() { printf '%q' "$1"; }
# A remote path: a leading ~/ becomes the BC-250's "$HOME"/ (a quoted ~ would not expand there).
rq() { if [[ "$1" == "~/"* ]]; then printf '"$HOME"/%q' "${1#\~/}"; else q "$1"; fi; }

# ---- the remote script (bash on the BC-250; its login shell is fish, hence `bash -s`) ----
remote() {
cat <<EOF
set -uo pipefail
REPO=$(rq "$BREPO"); W=$(q "$JC_BCW"); BMC=$(q "$JC_BMC"); CHAIN=$CHAIN; DIES="$DIESF"
cd "\$REPO" || { echo "JCLANE_FAIL no repo at \$REPO"; exit 1; }
# The broker is identified by its pid file AND by /proc/PID/exe (python) AND /proc/PID/cwd
# (the repo), never by a command-line match (CLAUDE.md).
broker_pid() {
  local p; p=\$(cat "\$W/broker.pid" 2>/dev/null) || return 1
  [[ "\$p" =~ ^[0-9]+\$ && -d /proc/\$p ]] || return 1
  [[ "\$(readlink /proc/\$p/exe)" == *python* && "\$(readlink /proc/\$p/cwd)" == "\$REPO" ]] || return 1
  echo "\$p"
}
stop_broker() {
  local p; p=\$(broker_pid) || { echo "broker: none running (pid file \$W/broker.pid)"; return 0; }
  kill -INT "\$p"
  for i in \$(seq 1 30); do [[ -d /proc/\$p ]] || break; sleep 1; done
  if [[ -d /proc/\$p ]]; then echo "JCLANE_FAIL broker pid \$p did not exit 30 s after SIGINT"; exit 1; fi
  echo "broker: pid \$p stopped"
}
start_broker() {
  if broker_pid > /dev/null; then echo "JCLANE_FAIL a broker is already running (pid \$(broker_pid))"; exit 1; fi
  nohup python3 tools/jc/jc_broker.py serve --bmc "\$BMC" --chain \$CHAIN --dies "\$DIES" \\
      --sock "\$W/broker.sock" --manifest $DIE0=$(rq "$JC_BC_MAN0") --manifest $DIE1=$(rq "$JC_BC_MAN1") \\
      > "\$W/broker.out" 2> "\$W/broker.err" < /dev/null &
  echo \$! > "\$W/broker.pid"
  for i in \$(seq 1 30); do grep -qE '^JCBROKER_(READY|ABORT)' "\$W/broker.out" && break; sleep 1; done
  cat "\$W/broker.out"
  grep -qE '^JCBROKER_READY ' "\$W/broker.out" || { echo "JCLANE_FAIL the broker did not print JCBROKER_READY (see \$W/broker.out, broker.err)"; exit 1; }
}
zero_die() {   # \$1 = card number, \$2 = die
  local s="\$W/card\$1/side_gdn.json"
  [[ -f "\$s" ]] || { echo "JCLANE_FAIL missing \$s (hw/jc/host/jc_side_image.py, runbook 3.2)"; exit 1; }
  python3 tools/jc/coe_load.py load "\$s" --bmc "\$BMC" --chain \$CHAIN --die \$2 --dies "\$DIES" \\
      > "\$W/rezero_load_\$2.log" 2>&1
  grep -hE '^(JCLOAD_DONE|JCLOAD_ABORT)' "\$W/rezero_load_\$2.log"
  grep -qE '^JCLOAD_DONE ' "\$W/rezero_load_\$2.log" || { echo "JCLANE_FAIL GDN zero load on die \$2 (see \$W/rezero_load_\$2.log)"; exit 1; }
  python3 tools/jc/coe_load.py verify "\$s" --bmc "\$BMC" --chain \$CHAIN --die \$2 --dies "\$DIES" \\
      > "\$W/rezero_verify_\$2.log" 2>&1
  grep -hE '^JCVERIFY_(PASS|FAIL)' "\$W/rezero_verify_\$2.log"
  grep -qE '^JCVERIFY_PASS [0-9]+ pieces, 0 bad' "\$W/rezero_verify_\$2.log" || { echo "JCLANE_FAIL GDN zero verify on die \$2 (see \$W/rezero_verify_\$2.log)"; exit 1; }
}
EOF
case "$CMD" in
  start)  echo "start_broker" ;;
  stop)   echo "stop_broker" ;;
  rezero) printf '%s\n' "stop_broker" "zero_die 0 $DIE0" "zero_die 1 $DIE1" "start_broker" ;;
esac
echo "echo \"JCLANE_DONE $CMD\""
}

if [[ $DRY == 1 ]]; then
  echo "DRYRUN ssh $(q "$JC_BC") bash -s <<REMOTE"
  remote | sed 's/^/DRYRUN| /'
  echo "DRYRUN REMOTE"
  exit 0
fi
OUT=$(remote | ssh "$JC_BC" 'bash -s' 2>&1)
printf '%s\n' "$OUT"
if grep -qE "^JCLANE_DONE $CMD\$" <<< "$OUT" && ! grep -qE '^JCLANE_FAIL' <<< "$OUT"; then
  exit 0
fi
grep -qE '^JCLANE_FAIL' <<< "$OUT" || echo "JCLANE_FAIL $CMD: the remote script ended without JCLANE_DONE (ssh or bash failed)"
exit 1
