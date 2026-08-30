#!/usr/bin/env bash
# TRACK CBINFER.  Build the RTL variants that sim/ooc_cbinfer.tcl synthesises.
#
# WHY VARIANTS AND NOT -generic.  The lever-C question and the attribute
# question are two different failures that look identical from the utilization
# table:
#
#   (a) Vivado will not infer LUTRAM from cb's array-of-array-of-signed SHAPE.
#   (b) Vivado will not accept an ATTRIBUTE VALUE that is a constant returned
#       by a function of a generic, so the ram_style never reached the tool.
#
# In both cases the answer is "no LUTRAM", and only in case (a) is lever C
# dead.  Separating them needs a variant whose attribute values are string
# LITERALS, which cannot be edited in by a command-line generic.  So each
# variant is a whole copy of the three RTL files, edited in place, and the
# synthesis script is told which directory to read.
#
# Each edit is verified by grep AFTER it is made and the script HARD-FAILS if
# the expected line is not present, because a sed that matched nothing is
# indistinguishable from a variant that is a duplicate of the baseline -- and a
# duplicate baseline would make every comparison below read "no change", which
# is exactly the flattering answer this exercise must not produce by accident.
#
# USAGE   bash sim/cbinfer_variants.sh <destroot>
# The destroot is created if absent.  Existing variant dirs are overwritten.

set -euo pipefail

DESTROOT="${1:?usage: cbinfer_variants.sh <destroot>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../rtl"

FILES="util_pkg.vhd mv4i_arith_pkg.vhd matvec_core.vhd"

mkdir -p "$DESTROOT"

mkvar () {
  d="$DESTROOT/$1"
  mkdir -p "$d"
  for f in $FILES; do cp "$RTL/$f" "$d/$f"; done
  echo "$d"
}

# Assert a literal string is present in a file, else die.  This is the teeth on
# every sed below.
must () {  # must <file> <fixed-string> <what>
  if ! grep -qF "$2" "$1"; then
    echo "CBINFER VARIANT BUILD FAILED: $3 -- expected to find in $1:" >&2
    echo "    $2" >&2
    exit 3
  fi
}
mustnot () {
  if grep -qF "$2" "$1"; then
    echo "CBINFER VARIANT BUILD FAILED: $3 -- still present in $1:" >&2
    echo "    $2" >&2
    exit 3
  fi
}

SRC_STYLE='CB_STYLE : string := "regs"'
SRC_DT='attribute dont_touch of cb    : signal is CB_DT;'
SRC_RS='attribute ram_style  of cb   : signal is CB_RS;'

# The baseline must look the way this script thinks it does BEFORE any variant
# is cut.  If matvec_core.vhd has been reworded, every sed below silently
# no-ops and the whole run measures nothing.
must "$RTL/matvec_core.vhd" "$SRC_STYLE" "baseline CB_STYLE default"
must "$RTL/matvec_core.vhd" "$SRC_DT"    "baseline dont_touch of cb"
must "$RTL/matvec_core.vhd" "$SRC_RS"    "baseline ram_style of cb"

# --------------------------------------------------------------- v_regs
# The shipping design, byte for byte.  Every number below is read against this.
d=$(mkvar v_regs)
cmp -s "$RTL/matvec_core.vhd" "$d/matvec_core.vhd" || { echo "v_regs is not a copy" >&2; exit 3; }

# --------------------------------------------------------- v_regs_noattr
# The shipping design with the ram_style attribute on cb DELETED.  This is the
# attribution control for question 3: it is what matvec_core.vhd was before
# LEVERC added the attribute, so any area difference between v_regs and this is
# caused by ram_style = "registers" and by nothing else.
d=$(mkvar v_regs_noattr)
sed -i "/$(printf '%s' "$SRC_RS" | sed 's/[]\/$*.^[]/\\&/g')/d" "$d/matvec_core.vhd"
mustnot "$d/matvec_core.vhd" "$SRC_RS" "v_regs_noattr ram_style deletion"
must    "$d/matvec_core.vhd" "$SRC_DT" "v_regs_noattr must still carry dont_touch"

# --------------------------------------------------------------- v_dist
# Lever C exactly as LEVERC wrote it: CB_STYLE = "distributed", with both
# attribute values still coming from functions of the generic.  A "no LUTRAM"
# here is ambiguous between causes (a) and (b) above; v_distlit resolves it.
d=$(mkvar v_dist)
sed -i 's/CB_STYLE : string := "regs"/CB_STYLE : string := "distributed"/' "$d/matvec_core.vhd"
must "$d/matvec_core.vhd" 'CB_STYLE : string := "distributed"' "v_dist style default"

# ------------------------------------------------------------ v_distlit
# Lever C with the attribute values written as STRING LITERALS.  This is the
# discriminator: if v_distlit infers LUTRAM and v_dist does not, the defect is
# Vivado's attribute reader (question 2) and the fallback LEVERC names -- two
# sibling architectures -- is required.  If NEITHER infers, the shape does not
# infer and lever C is dead regardless of the attribute.
d=$(mkvar v_distlit)
sed -i 's/CB_STYLE : string := "regs"/CB_STYLE : string := "distributed"/' "$d/matvec_core.vhd"
sed -i 's/attribute dont_touch of cb    : signal is CB_DT;/attribute dont_touch of cb    : signal is "false";/' "$d/matvec_core.vhd"
sed -i 's/attribute ram_style  of cb   : signal is CB_RS;/attribute ram_style  of cb   : signal is "distributed";/' "$d/matvec_core.vhd"
must "$d/matvec_core.vhd" 'CB_STYLE : string := "distributed"'                     "v_distlit style default"
must "$d/matvec_core.vhd" 'attribute dont_touch of cb    : signal is "false";'     "v_distlit dont_touch literal"
must "$d/matvec_core.vhd" 'attribute ram_style  of cb   : signal is "distributed";' "v_distlit ram_style literal"

# --------------------------------------------------------- v_distlit_nodt
# As v_distlit but with the dont_touch on cb REMOVED ENTIRELY rather than set
# to "false".  dont_touch = "false" SHOULD be identical to no attribute, and
# that is exactly the kind of should this project does not get to assume: a
# signal carrying any dont_touch may be excluded from RAM inference by the
# attribute's presence rather than its value.
d=$(mkvar v_distlit_nodt)
sed -i 's/CB_STYLE : string := "regs"/CB_STYLE : string := "distributed"/' "$d/matvec_core.vhd"
sed -i "/$(printf '%s' "$SRC_DT" | sed 's/[]\/$*.^[]/\\&/g')/d" "$d/matvec_core.vhd"
sed -i 's/attribute ram_style  of cb   : signal is CB_RS;/attribute ram_style  of cb   : signal is "distributed";/' "$d/matvec_core.vhd"
mustnot "$d/matvec_core.vhd" "$SRC_DT" "v_distlit_nodt dont_touch deletion"
must    "$d/matvec_core.vhd" 'attribute ram_style  of cb   : signal is "distributed";' "v_distlit_nodt ram_style literal"

# ------------------------------------------------------------ v_dist_noattr
# Lever C with NO ram_style attribute at all and no dont_touch on cb.  Measures
# whether the shape infers LUTRAM on its own, which is what decides whether the
# attribute is doing any work or is merely along for the ride.
d=$(mkvar v_dist_noattr)
sed -i 's/CB_STYLE : string := "regs"/CB_STYLE : string := "distributed"/' "$d/matvec_core.vhd"
sed -i "/$(printf '%s' "$SRC_DT" | sed 's/[]\/$*.^[]/\\&/g')/d" "$d/matvec_core.vhd"
sed -i "/$(printf '%s' "$SRC_RS" | sed 's/[]\/$*.^[]/\\&/g')/d" "$d/matvec_core.vhd"
mustnot "$d/matvec_core.vhd" "$SRC_DT" "v_dist_noattr dont_touch deletion"
mustnot "$d/matvec_core.vhd" "$SRC_RS" "v_dist_noattr ram_style deletion"

echo "--- variants built under $DESTROOT ---"
for v in v_regs v_regs_noattr v_dist v_distlit v_distlit_nodt v_dist_noattr; do
  printf '%-16s %s\n' "$v" "$(md5sum "$DESTROOT/$v/matvec_core.vhd" | cut -d' ' -f1)"
done
# Six distinct md5s are expected.  Two identical ones mean an edit did nothing
# and the pair of runs that follow would agree for a reason that is not a
# finding.
n=$(for v in v_regs v_regs_noattr v_dist v_distlit v_distlit_nodt v_dist_noattr; do
      md5sum "$DESTROOT/$v/matvec_core.vhd" | cut -d' ' -f1; done | sort -u | wc -l)
echo "distinct variant md5 count: $n (expect 6)"
[ "$n" -eq 6 ] || { echo "CBINFER VARIANT BUILD FAILED: variants are not all distinct" >&2; exit 3; }
echo "CBINFER_VARIANTS_OK"
