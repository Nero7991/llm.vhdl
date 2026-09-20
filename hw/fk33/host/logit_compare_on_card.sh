#!/usr/bin/env bash
# =====================================================================
#  A HUMAN RUNS THIS.  THIS SCRIPT TOUCHES NO HARDWARE, EVER.
# =====================================================================
#
# It PRINTS the exact command sequence for a token-0 logit comparison on the
# FK33 and exits.  It opens no /dev/xdma*, reloads no bitstream, issues no GO
# and never passes an operator token to anything.  `server/fk33_transport.h`
# is the tripwire: nothing in this repository may open the card without a
# person typing the word, and `run_prompt --allow-hardware HOST` exists so
# that the person types it.  A script that typed it for them would remove the
# only guard there is, so this one refuses -- see `guard_refuse()` below, which
# is the entire hardware path of this file.
#
# WHY A SCRIPT AND NOT A MARKDOWN FILE.  The commands below are DERIVED at run
# time from the manifest and the artefacts actually present on this box, so a
# path that has moved is reported here rather than pasted wrong at 3 a.m.  It
# is also the place the preconditions live: the wrong bitstream gives a
# perfectly well-formed answer to a different question.
#
# usage:   bash hw/fk33/host/logit_compare_on_card.sh [--check]
#          --check   verify the preconditions that can be checked WITHOUT the
#                    card (files exist, the reference is readable, the
#                    comparator's selftest passes) and print nothing else
#
# ---------------------------------------------------------------------------
# THE QUESTION, AND THE ANSWER THIS PROCEDURE CAN AND CANNOT GIVE
# ---------------------------------------------------------------------------
# On 2026-09-20 the card produced its first correct answer and the recorded
# next measurement is a LOGIT-LEVEL comparison at token 0.  The honest state of
# that measurement, MEASURED by reading the contract:
#
#   THE SHIPPING BITSTREAM CANNOT PRODUCE A LOGIT VECTOR.  Three independent
#   reasons, any one of which is sufficient:
#
#     1. `rtl/fk33_seam.vhd:91-94` -- the v2 window seam "returns the
#        sampler's ARGMAX and its shared exponent.  It does NOT return 248,320
#        s32 logits: there is no C2H path here".  `pl_backend.c:1243` refuses
#        the request rather than reading rubbish from address 0.
#     2. There is no HBM write-back for subsystem A's output.  `y_we/y_addr/
#        y_data` (rtl/matvec_int4_desc_axi.vhd:263) is a 16-bit local bus into
#        the region file; the lm_head's 248,320 rows never become bytes in HBM
#        that a host DMA could fetch.
#     3. The region read-back window (WIN_SEL 3, `hr_addr`/`hr_data`) is DEAD
#        on this silicon: `hw/fk33/gen_fk33_card.py` passes
#        `HOST_WINDOW=false`, and region_mem's own comment says that in this
#        configuration "hr_data reads zero".  It was set false deliberately --
#        a combinational full-range read port cannot be BRAM and cost 2.75
#        million registers in synthesis -- so this is not an oversight to
#        reverse casually.
#
#   Everything below is therefore in two parts, and the first is the one that
#   runs today.
#
# ---------------------------------------------------------------------------
# WHICH PROMPT, AND WHY IT IS NOT THE DC-DC ONE
# ---------------------------------------------------------------------------
# A comparison needs BOTH ENDS DRAWN FROM THE SAME INPUT.  The reference
# capture that exists is `ref/run9b --acts bfp` on the SINGLE id 248045:
# MEASURED in its own log, `TOKEN 0 id=248045 argmax=846 logit=12.782196`, and
# the capture's LOGITS record has max +12.7822 to the digit.  The DC-DC prompt
# is 23 ids and its token 0 is 1206; comparing the card on THAT prompt against
# THIS reference would be two different questions with one verdict, which is
# this project's most expensive recorded error.
#
# So: drive the card with the one-id prompt 248045.  It is also the cheapest
# possible run -- one prefill GO, no decode -- and the position at which card
# and reference provably start from identical state.
#
# A reference for any OTHER prompt costs `ref/run9b` about 30.9 s and ~4.5 GB
# PER TOKEN (MEASURED in the same log).  Generate it deliberately, on a quiet
# box, and never beside a Vivado.
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "$0")/../../.."
REPO="$PWD"

guard_refuse() {
    echo "REFUSED: $* is a hardware action.  This script prints commands; a" >&2
    echo "         human runs them.  server/fk33_transport.h owns that rule." >&2
    exit 3
}
# The only mentions of the hardware verbs in this file are inside the strings
# it prints.  If this script is ever edited to RUN one, the line below is what
# has to be deleted, and deleting it is the change a reviewer looks for.
[ "${FK33_ALLOW_HARDWARE:-}" = "" ] || guard_refuse "FK33_ALLOW_HARDWARE in the environment"

MANIFEST="${MANIFEST:-/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json}"
MV4I="${MV4I:-/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i}"
REF9BS="${REF9BS:-}"
WORK="${WORK:-$PWD/logitcmp_work}"
BIT="hw/fk33/bit/fk33_card_swg_75mhz_2026-09-20.bit"

# ------------------------------------------------------- precondition checks
ok=0; bad=0
chk() {  # chk <what> <path>
    if [ -e "$2" ]; then printf '  OK      %-26s %s\n' "$1" "$2"; ok=$((ok+1))
    else printf '  MISSING %-26s %s\n' "$1" "$2"; bad=$((bad+1)); fi
}
echo "PRECONDITIONS (checkable without the card)"
chk "bitstream"          "$REPO/$BIT"
chk "manifest"           "$MANIFEST"
chk "packed embedding"   "$MV4I"
chk "run_prompt"         "$REPO/server/run_prompt"
chk "comparator"         "$REPO/tools/ref9b/logit_compare.py"
chk "token check"        "$REPO/tools/ref9b/check_token.py"
if [ -n "$REF9BS" ]; then chk "reference capture" "$REF9BS"; else
    echo "  UNSET   reference capture       set REF9BS=<tok0.r9bs>, or regenerate:"
    echo "            ./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \\"
    echo "                        --acts bfp --tokens 248045 --out tok0.r9bs"
    echo "          (~31 s and ~4.5 GB for the one token; run it alone)"
    bad=$((bad+1))
fi
echo "  -- the comparator's own teeth (no card, no model):"
if python3 "$REPO/tools/ref9b/logit_compare.py" --selftest >/dev/null 2>&1; then
    echo "  OK      logit_compare --selftest  9 rows, 0 fail"
else
    echo "  FAIL    logit_compare --selftest  the comparator is not trustworthy;"
    echo "          run it directly and read the table before going near the card"
    bad=$((bad+1))
fi
echo "  $ok present, $bad missing or unset"
if [ "${1:-}" = "--check" ]; then exit $(( bad ? 1 : 0 )); fi
echo

cat <<'BANNER'
=============================================================================
 THE COMMANDS.  A HUMAN TYPES THESE.  NOTHING ABOVE OR BELOW RUNS THEM.
=============================================================================
BANNER

cat <<EOF
--- 0. THE BITSTREAM AND THE IMAGE --------------------------------------
    The card must hold the build whose numbers you mean to compare.  A
    different bitstream answers a different question with no symptom.

      bitstream : $BIT   (8dbe160, the 2026-09-20 first-inference build)
      weights   : the image \`fk33_load_weights.py\` places from
                  $MANIFEST
                  plus subsystem A's descriptor arena and B's constants at
                  the manifest's own hbm.desc_arena_base / gdn_const_base.

    Reload and load are OPERATOR actions (hw/fk33/host/fk33_reload.sh,
    fk33_load_weights.py).  This script will not run them and does not print
    their arguments, because a wrong argument there is destructive.  Follow
    docs/2026-09-18_seam-bringup-on-the-card.md steps 1-7.

    Afterwards, and before anything else:
      python3 hw/fk33/host/fk33ctl.py seam        # ID, VERSION, CAPS, STATUS
      python3 hw/fk33/host/fk33ctl.py thermal     # trip count must be 0

--- 1. THE PROGRAM FOR ONE TOKEN ----------------------------------------
    mkdir -p $WORK && cd $REPO
    python3 tools/gen_layer_program.py --token --shape 9b \\
        --manifest $MANIFEST \\
        --x-exp 0 \\
        --d-table $WORK/token.dtbl --rel-file $WORK/token.rel \\
        --arena-image $WORK/arena.bin
    # then load arena.bin at the offset the generator PRINTS.  Do not type
    # that offset from memory:
    #   python3 hw/fk33/host/fk33ctl.py load $WORK/arena.bin --offset <printed> --verify

--- 2. THE ONE-ID PROMPT ------------------------------------------------
    printf '248045  # the id ref/run9b was captured on; argmax 846\\n' \\
        > $WORK/prompt_tok0.txt

--- 3. SEQ-RESET, ONE GO, AND THE DUMP ----------------------------------
    server/run_prompt --allow-hardware HOST --v2 \\
        --seq-reset \\
        --dtbl $WORK/token.dtbl --rel $WORK/token.rel \\
        --prompt $WORK/prompt_tok0.txt \\
        --manifest $MANIFEST \\
        --mv4i $MV4I \\
        --max-new 1 \\
        --dump-logits $WORK/card_tok0.r9bs

    --seq-reset must print "seam AND engine positions cleared (TOK_POS read
    back 0)".  If it prints "SEAM ONLY (rc 1)" the engine's tok_pos is
    whatever the last run left, subsystem B runs the token as NOT-the-first,
    and the numbers are not a first token.  That exact defect cost 2026-09-19
    (docs/debugging/2026-09-19_b-ran-every-probe-token-as-not-the-first.md).
    STOP if it says SEAM ONLY.

    --max-new 1 is one prefill GO and no decode GO.  Token 0 is the ONLY
    position at which the card and the reference start from identical state.

    EXPECTED ON THE v2 BITSTREAM: one line reading
      dump  NOTE seam v2 publishes no logits row ...
    and a file carrying LOGIT_EXP and TOKEN and no LOGITS record.  That is
    the measurement being UNAVAILABLE, not the measurement passing.

--- 4. WHAT CAN BE COMPARED TODAY ---------------------------------------
    python3 tools/ref9b/check_token.py \\
        $WORK/card_tok0.r9bs \${REF9BS:-<tok0.r9bs>}

      Both rows are REPORTED (each producer's own argmax), so this is two
      independent argmax implementations -- the card's sampler_stream against
      run9b -- and not a round trip.  Expect token 846 on both, and read the
      MARGIN it prints: MEASURED on this capture the top logit is 12.782196,
      so the decision has room and an agreement here is an agreement about a
      decision with a margin, blind to every error below it.

    python3 tools/ref9b/logit_compare.py \\
        $WORK/card_tok0.r9bs \${REF9BS:-<tok0.r9bs>}

      On the v2 card this prints the TOKEN line and then
      "VECTOR UNAVAILABLE ... which is not the same as agreement", and exits
      2.  Exit 2 here is CORRECT and is the point: it records that the
      comparison did not happen.

    Also record, from the same run, the three numbers the seam does publish:
      python3 hw/fk33/host/fk33ctl.py seam    # LOGIT_EXP (0xE048), SMP_N
                                              # (0xE064), FAULTS (0xE068)
      SMP_N must read 248320 -- one fold per vocabulary row.  Anything less
      and the sampler did not see the whole lm_head, and FK33_FAULT_SMP_OVF
      in FAULTS says the logits FIFO lost beats.  An argmax taken over a
      short row is a plausible id with no fault raised anywhere.

--- 5. WHAT IT WOULD TAKE TO COMPARE THE VECTOR -------------------------
    A bitstream that publishes the logits row.  `pl_backend.c` already reads
    one (the v1 path: `l_base` in HBM, one 993,344-byte C2H burst per
    position, MEASURED at 1.11 GB/s = 894.9 us) and `run_prompt --dump-logits`
    already writes it -- the two halves exist and meet at a card that does
    not.  When such a build lands, step 3 is unchanged and step 4 becomes:

      python3 tools/ref9b/logit_compare.py \\
          $WORK/card_tok0.r9bs \${REF9BS:-<tok0.r9bs>} --topk 1,5,20

    and the VERDICT is read as the comparator's own header prescribes:
    the COMMON SCALE line against the 0.1252 relative-RMS INT4 baseline
    (NOT against zero), the PER lm_head WINDOW section against itself, and no
    magnitude quoted as a pass or a fail on its own.

--- 6. THE NEAREST AVAILABLE SUBSTITUTE, AND IT IS UNTESTED -------------
    ESTIMATE, not MEASURED, and offered as a design rather than a recipe.
    \`gen_layer_program.py --upto N --probe-smp\` sets FLG_TO_SMP on the last
    kept step, so the sampler's ARGMAX becomes a probe on any A job; the
    lm_head is 15 A jobs (rows 0, 17376, ... 243264 -- tools/gen_lmhead_
    windows.py owns the tiling).  Probing after window w should give the
    argmax over rows 0..end-of-window-w, because \`smp_base\` accumulates over
    every FLG_TO_SMP job since the GO (rtl/llama_top.vhd:3934) and resets on
    GO (:3827).  Fifteen runs would then give fifteen PREFIX argmaxes, each
    comparable against the same reference vector sliced the same way, which
    localises a divergence to one shard.

    IT IS INDICES, NOT VALUES.  It cannot measure how close the vector is; it
    can only say which shard first disagrees.  And nothing has run it: the
    smp_base behaviour under --upto is read from the RTL, not observed.  Do
    not quote a number from it until it has a clean control (window 14, whose
    prefix argmax must equal the full token's argmax).
EOF
echo
echo "END.  No hardware was touched by this script."
