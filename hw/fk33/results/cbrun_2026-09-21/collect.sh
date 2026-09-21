#!/usr/bin/env bash
# TRACK CBRUN -- extract the four-arm table from the run directory.
#
# EVERY NUMBER IS TAKEN FROM ONE STAGE.  CBRAM's own measurement trap #1 was
# mixing the synth-stage and placed-stage primitive tables, which turned an
# exact 1,536 x 14 fit into a miss by 622 while staying self-consistent.  The
# `opt` stage is quoted throughout here because the tcl's result row and CSV
# come from the post-opt_design utilization report; the `synth` stage is printed
# in its own separate block and never mixed into the same row.
set -u
R="${1:?usage: collect.sh <run dir>}"
ARMS="${2:-old new bcast fan}"

echo "############ 1. THE RECOGNIZER, [Synth 8-5859], PER ARM ############"
echo "# The PRIMARY result.  An ABSENT message is a NULL result on its own, so"
echo "# gdn_block's two rows are the positive control that makes it admissible:"
echo "# they show the recognizer ran in this very run."
for a in $ARMS; do
  f="$R/out_$a/vivado_cb_$a.log"
  [ -f "$f" ] || { echo "arm=$a NO LOG"; continue; }
  echo "--- arm=$a ---"
  grep -E "^INFO: \[Synth 8-5859\]" "$f" | sed 's/^/    /' || true
  echo "  counts: total=$(grep -cE '^INFO: \[Synth 8-5859\]' "$f") cb_reg=$(grep -cE '^INFO: \[Synth 8-5859\].*cb_reg' "$f") gdn_control=$(grep -cE '^INFO: \[Synth 8-5859\].*(qbuf|kbuf)_reg' "$f")"
done

echo
echo "############ 2. THE cb CENSUS, opt STAGE ############"
for a in $ARMS; do
  grep -hE "^CBOOC_CB stage=opt " "$R/run_$a.log" 2>/dev/null | sed "s/^/$a: /"
done
echo "-- synth stage, kept SEPARATE and never mixed into the row above --"
for a in $ARMS; do
  grep -hE "^CBOOC_CB stage=synth " "$R/run_$a.log" 2>/dev/null | sed "s/^/$a: /"
done

echo
echo "############ 3. THE PRIMITIVE CENSUS, opt STAGE (get_cells, exact REF_NAME) ############"
for a in $ARMS; do
  grep -hE "^CBOOC_CENSUS stage=opt " "$R/run_$a.log" 2>/dev/null | sed "s/^/$a: /"
done

echo
echo "############ 4. report_utilization ROW, opt STAGE ############"
for a in $ARMS; do
  grep -hE "^CBOOC_RESULT " "$R/run_$a.log" 2>/dev/null | sed "s/^/$a: /"
done

echo
echo "############ 5. THE FANOUT ON THE COMMAND NET ############"
for a in $ARMS; do
  grep -hE "^CBOOC_FANOUT_CBW stage=opt " "$R/run_$a.log" 2>/dev/null | sed "s/^/$a: /"
  grep -hE "^CBOOC_FANOUT_TOP stage=opt " "$R/run_$a.log" 2>/dev/null | head -3 | sed "s/^/$a: /"
done

echo
echo "############ 6. MEMORY, PER ARM, WITH THE CAP READBACK ############"
for a in $ARMS; do
  [ -f "$R/out_$a/mem.txt" ] && sed "s/^/$a: /" "$R/out_$a/mem.txt"
  grep -hE "^CBRUN_CAP_READBACK|^CBRUN_CAP_ABORT" "$R/run_$a.log" 2>/dev/null | sed "s/^/$a: /"
done

echo
echo "############ 7. TIMING, PER ARM (OOC, synthesis+opt only -- NOT a routed number) ############"
for a in $ARMS; do
  grep -hE "^CBOOC_(INTRA|WORST_GLOBAL|CBW_PATH) " "$R/run_$a.log" 2>/dev/null | sed "s/^/$a: /"
done

echo
echo "############ 8. THE SENTINELS, LINE-ANCHORED ############"
for a in $ARMS; do
  echo "$a: CBOOC_DONE=$(grep -cE "^CBOOC_DONE cb_$a\$" "$R/run_$a.log" 2>/dev/null) errors=$(grep -cE '^ERROR' "$R/out_$a/vivado_cb_$a.log" 2>/dev/null)"
done

echo
echo "############ 9. THE DISTRIBUTED RAM MAPPING REPORT -- THE INSTRUMENT THAT ############"
echo "############    ACTUALLY DISCRIMINATES AT CBO_TARGET=matvec_core         ############"
echo "# [Synth 8-5859] does not fire for cb_reg in EITHER direction at this target -- see"
echo "# the CBRUN section of the CBRAM document.  gdn_block is not in matvec_core's"
echo "# closure, so the positive control CBRAM specified does not exist here either, and"
echo "# an absent 8-5859 is therefore uninterpretable rather than informative.  The"
echo "# mapping report NAMES THE OBJECT, and CLAUDE.md's rule is that when a report names"
echo "# the object no argument about a total is admissible.  It is quoted here and the"
echo "# get_cells census in section 2 is the cross-check."
for a in $ARMS; do
  f="$R/out_$a/vivado_cb_$a.log"
  [ -f "$f" ] || { echo "arm=$a NO LOG"; continue; }
  echo "--- arm=$a ---"
  echo "  cb_reg RAM32M16 mapping rows      = $(grep -cE '^\|.*cb_reg\[[0-9]+\]\[[0-9]+\].*RAM32M16' "$f")"
  echo "  distinct cb_reg indices named     = $(grep -oE 'cb_reg\[[0-9]+\]' "$f" | sort -u | wc -l)"
  echo "  max cb_reg index named            = $(grep -oE 'cb_reg\[[0-9]+\]' "$f" | grep -oE '[0-9]+' | sort -n | tail -1)"
  echo "  xq_reg rows (in-entity control)   = $(grep -cE '^\|.*xq_reg.*RAM32M16' "$f")"
  echo "  8-7186 (ANCHORED; unanchored over-counts by the tcl source line in the log)"
  echo "      count = $(grep -cE '^WARNING: \[Synth 8-7186\]' "$f")"
  echo "  8-10226 anchored count            = $(grep -cE '^WARNING: \[Synth 8-10226\]' "$f")"
  echo "  8-11357 anchored count            = $(grep -cE '^WARNING: \[Synth 8-11357\]' "$f")"
  echo "  first mapping row, verbatim:"
  grep -m1 -E '^\|.*cb_reg\[[0-9]+\]\[[0-9]+\]' "$f" 2>/dev/null | sed 's/^/      /' || grep -m1 -E '^\|.*cb_reg' "$f" | sed 's/^/      /'
done
