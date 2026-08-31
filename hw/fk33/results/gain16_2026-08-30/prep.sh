#!/usr/bin/env bash
# prep.sh -- TRACK GAIN16, 2026-08-30.  Build one rtl/ directory per shape.
#
# Each directory is the repo's rtl/ MINUS llama_top.vhd PLUS the `gvr` block
# extracted out of a variant llama_top.vhd by sim/ooc_normadapt_extract.py.
# That is TRACK GWTWO's harness unchanged, so a number drawn here is on the
# same scale as gw1/gw2/gw4/gw8 and can be quoted beside them.
#
# `head` is the SHIPPING FILE extracted with no rewrite at all.  It exists to
# prove this harness reproduces GWTWO's gw1 (135 RAMB36 / 141 tile / 5,073 LUT
# / 41 DSP / WNS +0.971).  If it does not, no delta drawn against it means
# anything and the sweep is thrown away.
#
# NO HARDWARE.  Text files only.
set -eu
REPO=${REPO:-/home/orencollaco/GitHub/llama.vhdl}
SCR=${SCR:-/home/labuser/gain16}
MKV=${MKV:-$SCR/mkvariant.py}

mkdir -p "$SCR"
echo "PREP llama_top $(md5sum "$REPO/rtl/llama_top.vhd")"

mk_rtldir () {                 # $1 tag, $2 source llama_top.vhd
    local tag=$1 src=$2 d="$SCR/rtl_$1"
    rm -rf "$d"; mkdir -p "$d"
    cp "$REPO"/rtl/*.vhd "$d"/
    rm -f "$d/llama_top.vhd"
    python3 "$REPO/sim/ooc_normadapt_extract.py" "$src" "$d/ooc_normadapt_top.vhd"
    echo "PREP $tag top $(md5sum "$d/ooc_normadapt_top.vhd" | cut -d' ' -f1) files=$(ls "$d" | wc -l)"
}

mk_rtldir head "$REPO/rtl/llama_top.vhd"
for spec in "$@"; do
    tag="sw$(echo "$spec" | tr ',' '_')"
    python3 "$MKV" "$REPO/rtl/llama_top.vhd" "$SCR/lt_$tag.vhd" "$spec"
    mk_rtldir "$tag" "$SCR/lt_$tag.vhd"
done
echo PREP_DONE
