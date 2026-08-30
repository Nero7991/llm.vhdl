#!/usr/bin/env bash
# run_attribution.sh -- TRACK DISTRAM, 2026-08-29.  THE ATTRIBUTION CONTROL.
#
# A KILL DOES NOT SETTLE IT.  TRACK OI3MUT measured that in one of four pairs
# the kill belonged to an OLDER property, not to the new check.  So for each
# mutant this runs the PRE-EXISTING block-level value oracle -- sim/regress.sh
# --only gdn_block_vec, which compares gdn_block against ref/gdn_block_vec.c --
# on the SAME mutant, with the new shadow bench nowhere in the picture.
#
# A kill that this script ALSO produces belongs to the old property.  A kill
# only run_mutants.sh produces belongs to the shadow bench.
#
# regress.sh honours REGRESS_REPO, so the mutant lives in a private tracked-file
# copy of the repository and rtl/ is never touched.
#
# NO HARDWARE.  Simulation only.  Nothing is deleted by this script.
set -u
SEED=/mnt/storage/distram/attrib/repo         # git archive of the pinned tree
SRC="${1:?usage: run_attribution.sh <mutated gdn_block.vhd> <name>}"
NAME="${2:?}"
R=$(mktemp -d /mnt/storage/distram/attrib/r_"${NAME}"_XXXXXX)
cp -a "$SEED"/. "$R"/
cp "$SRC" "$R/rtl/gdn_block.vhd"
cmp "$SRC" "$R/rtl/gdn_block.vhd" || { echo "$NAME : VOID(copy)"; exit 1; }
S=$(mktemp -d /mnt/storage/distram/attrib/s_"${NAME}"_XXXXXX)
REGRESS_REPO="$R" REGRESS_SCRATCH="$S" \
  bash "$R/sim/regress.sh" --only gdn_block_vec > "$R/regress.log" 2>&1
printf '%-18s : %s\n' "$NAME" "$(grep -a '^ OVERALL' "$R/regress.log" | tail -1)"
echo "    log: $R/regress.log"
