#!/usr/bin/env bash
# =====================================================================
#  A HUMAN RUNS THIS.  THIS SCRIPT TOUCHES NO HARDWARE, EVER.
# =====================================================================
#
# It PRINTS the command sequence for the lm_head PREFIX-ARGMAX sweep and
# exits.  It opens no /dev/xdma*, reloads no bitstream, issues no GO, and
# never passes an operator token to anything.  `server/fk33_transport.h` is
# the tripwire: nothing in this repository may open the card without a person
# typing the word.  `guard_refuse()` below is the entire hardware path of this
# file, and deleting that line is the change a reviewer looks for.
#
# usage:  bash hw/fk33/host/smpwin_sweep_on_card.sh [--check]
#         --check   verify only what can be checked WITHOUT the card
#
# ---------------------------------------------------------------------------
# THE ANSWER FIRST, BECAUSE IT DECIDES WHETHER TO RUN ANY OF THIS
# ---------------------------------------------------------------------------
# NO: the shipping bitstream cannot publish any part of the token-0 LOGIT
# VECTOR through the seam window.  The registers at 0x58/0x5C/0x60 are
# WIN_SEL / WIN_ADDR / WIN_DATA and they are the DESC, REL, XIN and XOUT
# windows (rtl/fk33_seam.vhd:378-380, :513-517).  There is no sampler value
# window.  XOUT reads ZERO on this silicon (HOST_WINDOW=false ->
# rtl/region_mem.vhd:414 `hr_data <= (others => '0')`), and the logits are not
# in a region to begin with: every FLG_TO_SMP job has dst = R_NONE, enforced
# in hardware at rtl/seq_desc_fetch.vhd:502.  The card says so about itself --
# CAPS_FLAGS = 0x3D has bit 2 SAMPLER set and bit 3 LOGITS CLEAR.
#
# WHAT THIS PROCEDURE MEASURES INSTEAD is the PREFIX-ARGMAX CHAIN: run the
# token truncated after lm_head window k, for k = 1..15, and read the running
# argmax each time.  It is INDICES, never values.
#
# ---------------------------------------------------------------------------
# AND IT IS A LOCALISER, NOT A ROUTINE CHECK.  MEASURE THE HEADROOM FIRST.
# ---------------------------------------------------------------------------
# MEASURED 2026-09-20 on the only 9B reference that exists (prompt id 248045):
# the winner 846 is in WINDOW 1 and beats every later window's maximum by 5.17
# to 10.21 logits, which is 16 to 33 INT4 error scales.  The reference chain
# is therefore the CONSTANT 846, and a 15-GO sweep is predicted to return the
# same number fifteen times.
#
#   RUN THE SWEEP WHEN THE CARD'S FULL-TOKEN ARGMAX ALREADY DISAGREES WITH
#   THE REFERENCE.  Then it names the window that introduced the wrong
#   maximum, and `smpwin_sweep.py next` bisects it in 4 GOs instead of 15.
#
#   DO NOT RUN IT TO CONFIRM AN AGREEMENT.  `smpwin_sweep.py expect --ref`
#   prints the per-window headroom; if the chain is constant it has nothing
#   to add to the argmax the shipping program already reports.
#
# ---------------------------------------------------------------------------
# THE TRAP THIS PROCEDURE EXISTS TO SURVIVE
# ---------------------------------------------------------------------------
# `gen_layer_program.py --probe-smp` REFUSES when the last kept step is not an
# A job, and exits non-zero having written no program.  An operator who misses
# that runs the PREVIOUS program and then reads a seam still holding the
# PREVIOUS run's registers -- a complete, plausible, wrong answer with nothing
# raised anywhere.  It has bitten twice on silicon.
#
# `smpwin_sweep.py ingest` refuses such a step rather than recording it, on
# FOUR independent grounds, and step 4 below is the operator-visible half:
#   G1_PROBE   the generator's own PROBE line must name step 489+k-1 on
#              output.weight with this window's row count.  (The PROGRAM.)
#   G2_TBLLEN  the card's A_TBL_LEN must read 490+k.  (The SILICON.  G1 and
#              G2 are the two halves: a right program that never ran fires G2
#              and not G1.)
#   G3_SMPN    A_SMP_N must equal the number of rows this prefix folds.  This
#              is not a statistic: the published argmax is the sampler's own
#              FOLD COUNT (rtl/sampler_stream.vhd:50-62), and `smp_idx` is
#              wired to nothing, so a wrong fold count makes the index a
#              well-formed number for the wrong row.
#   G9         two steps may not be the same captured bytes.
set -uo pipefail
cd "$(dirname "$0")/../../.."
REPO="$PWD"

guard_refuse() {
    echo "REFUSED: $* is a hardware action.  This script prints commands; a" >&2
    echo "         human runs them.  server/fk33_transport.h owns that rule." >&2
    exit 3
}
[ "${FK33_ALLOW_HARDWARE:-}" = "" ] || guard_refuse "FK33_ALLOW_HARDWARE in the environment"

MANIFEST="${MANIFEST:-/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json}"
MV4I="${MV4I:-/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i}"
QTK="${QTK:-$REPO/build_artifacts_tok/qwen35_9b.qtk}"
REF9BS="${REF9BS:-}"
WORK="${WORK:-$PWD/smpwin_work}"
BIT="hw/fk33/bit/fk33_card_swg_75mhz_2026-09-20.bit"

ok=0; bad=0
chk() {
    if [ -e "$2" ]; then printf '  OK      %-26s %s\n' "$1" "$2"; ok=$((ok+1))
    else printf '  MISSING %-26s %s\n' "$1" "$2"; bad=$((bad+1)); fi
}
echo "PRECONDITIONS (checkable without the card)"
chk "bitstream"          "$REPO/$BIT"
chk "manifest"           "$MANIFEST"
chk "packed embedding"   "$MV4I"
chk "tokenizer"          "$QTK"
chk "run_prompt"         "$REPO/server/run_prompt"
chk "sweep tool"         "$REPO/tools/ref9b/smpwin_sweep.py"
chk "seam reader"        "$REPO/hw/fk33/host/fk33ctl.py"
if [ -n "$REF9BS" ]; then chk "reference capture" "$REF9BS"; else
    echo "  UNSET   reference capture       set REF9BS=<tok0.r9bs>, or regenerate:"
    echo "            ./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \\"
    echo "                        --acts bfp --tokens 248045 --out tok0.r9bs"
    bad=$((bad+1))
fi
echo "  -- the sweep tool's own teeth (no card, no model):"
if python3 "$REPO/tools/ref9b/smpwin_sweep.py" --selftest >/dev/null 2>&1; then
    echo "  OK      smpwin_sweep --selftest  14 mutants, 0 fail"
else
    echo "  FAIL    smpwin_sweep --selftest  the tool is not trustworthy; run it"
    echo "          directly and read the table before going near the card"
    bad=$((bad+1))
fi
if python3 "$REPO/tools/ref9b/logit_compare.py" --partial-selftest >/dev/null 2>&1; then
    echo "  OK      logit_compare --partial-selftest  5 rows, 0 fail"
else
    echo "  FAIL    logit_compare --partial-selftest"
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
--- 0. DECIDE WHETHER TO RUN AT ALL -------------------------------------
    python3 tools/ref9b/smpwin_sweep.py expect --ref \${REF9BS:-<tok0.r9bs>}

    Read the gap/err column.  If the chain is constant and the gaps are tens
    of error scales, STOP: the sweep is predicted to return one number
    fifteen times and the shipping program already reports it.  Run the
    sweep only to localise a disagreement you have already seen.

--- 1. THE CARD AND THE IMAGE -------------------------------------------
      bitstream : $BIT
      weights   : as placed by fk33_load_weights.py from
                  $MANIFEST

    Reload and weight load are OPERATOR actions and this script prints
    neither their arguments nor their flags, because a wrong argument there
    is destructive.  Follow docs/2026-09-18_seam-bringup-on-the-card.md
    steps 1-7.  Then, and before anything else:

      python3 hw/fk33/host/fk33ctl.py seam      # ID, VERSION, CAPS, STATUS
      python3 hw/fk33/host/fk33ctl.py thermal   # trip count must be 0

    CAPS must show bit 2 SAMPLER set.  If bit 3 LOGITS is ALSO set you are
    on a DIFFERENT bitstream that publishes the whole row, and this whole
    procedure is the wrong one -- use tools/ref9b/logit_compare.py directly.

--- 2. THE ONE-ID PROMPT ------------------------------------------------
    mkdir -p $WORK/prog $WORK/cap && cd $REPO
    printf '248045  # the id ref/run9b was captured on; argmax 846\\n' \\
        > $WORK/prompt_tok0.txt

--- 3. THE UNTRUNCATED CONTROL, FIRST AND NOT LAST ----------------------
    The whole sweep is unattributable without it: k=15 IS the whole
    vocabulary, so the k=15 prefix argmax and the shipping program's argmax
    must be the same number.  Guard G11_ANCHOR checks exactly that.

    python3 tools/gen_layer_program.py --token --shape 9b \\
        --manifest $MANIFEST --x-exp 0 \\
        --d-table $WORK/prog/full.dtbl --rel-file $WORK/prog/full.rel \\
        --arena-image $WORK/prog/full.arena
    # load full.arena at the offset the generator PRINTS (do not type it
    # from memory):
    #   python3 hw/fk33/host/fk33ctl.py load $WORK/prog/full.arena \\
    #       --offset <printed> --verify
    server/run_prompt --allow-hardware HOST --v2 --seq-reset \\
        --dtbl $WORK/prog/full.dtbl --rel $WORK/prog/full.rel \\
        --prompt $WORK/prompt_tok0.txt --manifest $MANIFEST \\
        --mv4i $MV4I --qtk $QTK --max-new 1 | tee $WORK/cap/full.txt
    python3 hw/fk33/host/fk33ctl.py seam | tee -a $WORK/cap/full.txt

    --seq-reset must print "seam AND engine positions cleared (TOK_POS read
    back 0)".  If it prints "SEAM ONLY (rc 1)" STOP: subsystem B then runs
    the token as NOT-the-first and it is not a first token
    (docs/debugging/2026-09-19_b-ran-every-probe-token-as-not-the-first.md).

    Record the argmax that run reports; it is <FULL> below.
    SMP_N on that run must read 248320.

--- 4. THE SWEEP, ONE k AT A TIME ---------------------------------------
    The arena does NOT change between steps: --upto keeps the SAME A jobs in
    the SAME order, so the full arena image loaded in step 3 serves every k.
    Do not reload it; a reload is an HBM write for no reason.

    for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 ; do
      N=\$(( 489 + k ))
      python3 tools/gen_layer_program.py --token --shape 9b \\
          --manifest $MANIFEST --x-exp 0 \\
          --upto \$N --probe-smp --close-token \\
          --d-table $WORK/prog/k\$k.dtbl --rel-file $WORK/prog/k\$k.rel \\
          2>&1 | tee $WORK/cap/k\$k.txt
      # --- READ THE PROBE LINE BEFORE GOING ON.  This is the trap.
      #     No "PROBE step ..." line means the generator REFUSED and wrote
      #     nothing; running the card now reads the PREVIOUS program's
      #     registers and every number will look ordinary.
      server/run_prompt --allow-hardware HOST --v2 --seq-reset \\
          --dtbl $WORK/prog/k\$k.dtbl --rel $WORK/prog/k\$k.rel \\
          --prompt $WORK/prompt_tok0.txt --manifest $MANIFEST \\
          --mv4i $MV4I --qtk $QTK --max-new 1 \\
          2>&1 | tee -a $WORK/cap/k\$k.txt
      python3 hw/fk33/host/fk33ctl.py seam 2>&1 | tee -a $WORK/cap/k\$k.txt
      python3 tools/ref9b/smpwin_sweep.py ingest \\
          --sweep $WORK/sweep.json --k \$k --capture $WORK/cap/k\$k.txt \\
          --full-token-argmax <FULL>
    done

    \`ingest\` REFUSES a step rather than recording it, and prints which guard
    refused.  A refused step is a step to re-run, not a step to override.

    COST, MEASURED from hw/fk33/results/card_swg_2026-09-20/profile/
    profile_striped_tok0.txt at 75 MHz: one full token is 30,115,246 cycles
    = 0.4015 s, and the fifteen prefixes sum to 444,629,945 cycles = 5.93 s
    of card time.  Each step also re-uploads 7,856..8,080 32-bit descriptor
    halves plus the 4,096-write activation row; at the MEASURED 1.92 us per
    MMIO access the register reads are noise beside the 0.4 s of compute.

    TO BISECT INSTEAD OF SWEEP (4 GOs, and the right choice when you already
    know the full-token argmax is wrong):
      python3 tools/ref9b/smpwin_sweep.py next \\
          --sweep $WORK/sweep.json --ref-argmax 846
    Run the k it names, ingest it, ask again.

--- 5. THE VERDICT ------------------------------------------------------
    python3 tools/ref9b/smpwin_sweep.py pack \\
        --sweep $WORK/sweep.json --out $WORK/card_prefix.r9bs
    python3 tools/ref9b/smpwin_sweep.py compare \\
        $WORK/card_prefix.r9bs \${REF9BS:-<tok0.r9bs>}

    \`pack\` refuses a sweep that is not complete; --allow-partial packs
    anyway and \`compare\` then says PARTIAL SWEEP and names which k are
    present.  An uncaptured window is not an agreeing window.

    Exit 0 agree, 1 diverge (with the window named), 2 not measured.

    logit_compare.py on the packed file reports NO LOGITS record and names
    this tool; that is correct and is not a comparison of the vector.

--- 6. WHAT IS STILL NOT MEASURED, AFTER ALL OF THE ABOVE ---------------
    Every logit VALUE.  The margin between the top logit and its
    neighbours, the top-2 gap, the relative RMS against the 0.1252 INT4
    baseline, the per-window RMS -- none of them, on any bitstream that
    reads CAPS bit 3 clear.  A per-window ARGMAX is also out of reach
    without rewriting the HBM arena so that only one window carries
    FLG_TO_SMP; the chain gives record holders, not window maxima.

    What would change that is a logits path, costed in
    docs/debugging/2026-09-20_the-card-cannot-publish-a-logit-vector.md
    (TRACK SMPWIN section, 2026-09-20).
EOF
echo
echo "END.  No hardware was touched by this script."
