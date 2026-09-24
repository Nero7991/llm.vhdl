#!/usr/bin/env bash
# Build 19 silicon sequence. MAIN SESSION ONLY (hardware). Run one step at a time: bash steps.sh <step>
# Steps: reload | seam | weights | control | tok0 | compare. Never --with-vccint (wiper 68 stays).
set -u
REPO=/home/orencollaco/GitHub/llama.vhdl; S=${S_OVERRIDE:-/mnt/storage/fk33_builds/build19/silicon}
BIT=${BIT_OVERRIDE:-$REPO/hw/fk33/results/card_build19_2026-09-24/bd_wrapper.bit}
IMG=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27-nh
RUN=$REPO/build_artifacts_tok/chat_run; EMB=/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i
case "${1:?step}" in
  reload)   date +%T > $S/RELOAD_START; bash $REPO/hw/fk33/host/fk33_reload.sh $BIT 2>&1 | tee $S/reload.log | tail -8 ;;
  seam)     python3 $REPO/hw/fk33/host/fk33ctl.py seam 2>&1 | tee $S/seam_after_reload.txt | grep -iE 'id|version|caps|flags|XEXP|fault' | head -8
            python3 $REPO/hw/fk33/host/fk33ctl.py sysmon 2>&1 | tee $S/sysmon_after_reload.txt | head -6 ;;
  weights)  python3 $REPO/hw/fk33/host/fk33_load_weights.py load $IMG/manifest.json --verify 2>&1 | tee $S/load_weights.log | tail -4 ;;
  control)  for i in 1 2 3; do bash $REPO/hw/fk33/host/fk33_chat.sh "What is a DC-DC converter?" 64 > $S/ctl_run$i.out 2> $S/ctl_run$i.err; grep -E '^(prefill|decode|timing)' $S/ctl_run$i.err $S/ctl_run$i.out | cut -c1-140; done ;;
  tok0)     # mirrors fk33_chat.sh's per-question pre-steps (arena load, GDN state zero), then one prompt id, one GO, dump R_X
            M=$IMG; ARENA=$(python3 -c "import json;print(hex(json.load(open('$M/manifest.json'))['hbm']['desc_arena_base']))")
            python3 $REPO/hw/fk33/host/fk33ctl.py load $RUN/token.arena --offset $ARENA --verify > $S/tok0_arena.log 2>&1 || { echo arena load failed; exit 1; }
            GB=$(python3 -c "import json;h=json.load(open('$M/manifest.json'))['hbm'];print(hex(h['gdn_state_base']), h['gdn_state_bytes'])"); set -- $GB
            python3 $REPO/hw/fk33/host/fk33ctl.py load $RUN/gdn_zero.bin --offset $1 --verify > $S/tok0_state.log 2>&1 || { echo state zero failed; exit 1; }
            printf '248045\n' > $S/prompt_tok0.txt
            $REPO/server/run_prompt --allow-hardware HOST --seq-reset --v2 --dev "${FK33_USER%_user}" --dtbl $RUN/token.dtbl --rel $RUN/token.rel \
               --prompt $S/prompt_tok0.txt --max-new 1 --manifest $M/manifest.json --mv4i $EMB --dump-xout $S/xout_card_tok0.txt \
               > $S/tok0.out 2> $S/tok0.err; grep -E '^(prefill|decode|timing|xout)' $S/tok0.out $S/tok0.err | cut -c1-140 ;;
  compare)  python3 /mnt/storage/fk33_builds/scratch/xout_vs_ref.py $S/xout_card_tok0.txt /mnt/storage/fk33_builds/refs/tok0.r9bs 31 ;;
esac
