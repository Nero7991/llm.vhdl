#!/usr/bin/env bash
# TRACK WRITEDEC teeth-check for rmsnorm_rs's new write decode.
#
# A checker never shown to FAIL has not been shown to work.  Each mutation below
# breaks the NEW write decode in a different way; the bench must catch it.  The
# ones that do NOT bite are reported under their own names, because they measure
# the bench's resolution floor and are the most useful rows here.
#
# TRAP THIS SCRIPT GUARDS AGAINST, hit on its first run.  An earlier version
# used relative source paths after a `cd`, so ghdl could not open a single file,
# every mutant exited non-zero, and all seven were scored CAUGHT without the
# bench ever running.  Analysis failure is VOID, never CAUGHT.
#
# usage: run_mutants_rms.sh <pinned-rtl-dir> <new-rmsnorm_rs.vhd> <ref.vhd> <tb.vhd> <scratch>
set -u
SRC="$(cd "${1:?}" && pwd)"; NEW="$(readlink -f "${2:?}")"
REF="$(readlink -f "${3:?}")"; TB="$(readlink -f "${4:?}")"; W="${5:?}"
N="${N:-256}"; LN="${LN:-4}"
mkdir -p "$W/mut"; cd "$W"

names=(idx_off lane_rev lastword no_v3 no_rst no_state sat_hi)
for M in "${names[@]}"; do cp "$NEW" "mut/$M.vhd"; done

# M1  word address off by one -- every word lands in its neighbour
sed -i 's|and idx3 = wi then|and idx3 = (wi+1) mod NB then|' mut/idx_off.vhd
# M2  lane order reversed inside the word -- the elements of each word swap
sed -i 's|o_wd((k+1)\*16-1 downto k\*16)|o_wd((LANES-k)*16-1 downto (LANES-1-k)*16)|g' mut/lane_rev.vhd
# M3  the LAST word of the generate is never instantiated, so elements
#     N-LANES .. N-1 are never written.  This is the index-N-1 corner.
sed -i 's|gow : for wi in 0 to NB-1 generate|gow : for wi in 0 to NB-2 generate|' mut/lastword.vhd
# M4  the valid qualifier dropped: the decode writes on every emit cycle
sed -i "s|and state = S_EMIT and v3 = '1' and idx3 = wi|and state = S_EMIT and idx3 = wi|" mut/no_v3.vhd
# M5  the reset qualifier dropped
sed -i "s|if rst = '0' and state = S_EMIT|if state = S_EMIT|" mut/no_rst.vhd
# M6  the state qualifier dropped
sed -i "s|and state = S_EMIT and v3 = '1'|and v3 = '1'|" mut/no_state.vhd
# M7  the positive saturation constant perturbed.  If this does NOT bite, the
#     stimulus never reaches the emit saturation branch, and that is a coverage
#     statement worth having on the record rather than an oversight.
sed -i 's|std_logic_vector(to_signed(32767, 16));|std_logic_vector(to_signed(32766, 16));|' mut/sat_hi.vhd

for M in "${names[@]}"; do
  echo "=== MUTANT $M ==="
  if diff -q "$NEW" "mut/$M.vhd" >/dev/null; then
    echo "  VERDICT: VOID -- the sed matched nothing, so no mutation was applied"
    continue
  fi
  diff "$NEW" "mut/$M.vhd" | sed -n '1,6p' | sed 's/^/  /'
  rm -rf workm; mkdir workm
  aout=$(ghdl -a --std=08 --workdir=workm -Pworkm \
    "$SRC/util_pkg.vhd" "$SRC/fixed_luts_pkg.vhd" "$SRC/fixed_pkg.vhd" \
    "$REF" "mut/$M.vhd" "$TB" 2>&1)
  arc=$?
  if [ $arc -ne 0 ]; then
    echo "$aout" | head -4 | sed 's/^/  ANALYZE /'
    echo "  VERDICT: VOID -- the mutant did not ANALYZE, so nothing was tested"
    continue
  fi
  out=$(ghdl -r --std=08 --workdir=workm -Pworkm tb_writedec_rms -gN=$N -gLN=$LN 2>&1)
  rc=$?
  echo "$out" | grep -E "WRITEDEC (FAIL|EQUIV|TOOTH)" | head -3 | sed 's/^/  /'
  if ! echo "$out" | grep -q "WRITEDEC"; then
    echo "  VERDICT: VOID -- the bench produced no output at all"
    continue
  fi
  if [ $rc -ne 0 ]; then echo "  VERDICT: CAUGHT (rc=$rc)"
  else echo "  VERDICT: NOT CAUGHT -- resolution floor"; fi
done
