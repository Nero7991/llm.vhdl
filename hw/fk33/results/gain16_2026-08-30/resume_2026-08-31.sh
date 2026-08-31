#!/usr/bin/env bash
# resume_2026-08-31.sh -- DISPATCHER, 2026-08-31.  SNAPSHOT of what was run.
#
# The overnight session died on the weekly API limit at 00:42:52 MDT, one
# message after resuming TRACK GAIN16 with "Block on swcb properly, then
# land".  This script resumes the three verification jobs that were in
# flight or missing at that moment:
#
#   1. gate-floor teeth RUN B.  Run A (floor 103 on a clean archive of
#      93ddac7) PASSed at 00:41; Run B (floor 104, which must FAIL to prove
#      the floor bites) was killed at 01:05 mid-run.  The tree at
#      /mnt/storage/llama-gatefloor/tree is a byte-clean archive of 93ddac7
#      (verified: only four stray .pyc cache files) with BASELINE_PASS=104
#      already sed-edited in place.  Expected: OVERALL PASS 103 and
#      REGRESSION: FAIL -- a floor set above reality must fire.
#
#   2. GAIN16 oracle on the RECORD-FREE codebook as installed in
#      rtl/llama_top.vhd (cb2_recordfree_contingency.vhd + the restored
#      ixw_of comment).  GAIN16 ran it as tag cb_clean off its own scratch
#      copy; this run is against the actual working-tree file.
#
#   3. cbland: the Vivado OOC draw of the shipping record-free form.  THE
#      missing measurement: the +20.0 tile margin rests on the sw11 LOSSY
#      probe (99 RAMB36 for an 11-bit store), never on the codebook itself,
#      because the record form sat in Vivado elaboration > 15 min pinned at
#      its MemoryHigh=11G cap and was never drawn.  MemoryHigh=14G here
#      against a gw1-measured 11.59 GiB family, so the peak is honest
#      (a capped memory.peak is the cap, not the peak).
#
# MEMORY BUDGET, STATED BEFORE DISPATCH: box 31 GiB, ~25 GiB available, no
# llama-server resident.  Peaks: gate 2.13 GiB (GATEGREEN, MEASURED) +
# oracle < 1 GiB + Vivado <= 14 GiB cap = ~17 GiB worst case.  ONE Vivado
# on the box; the BC-250 lane is untouched.
#
# NO HARDWARE.  synth_design / report_* / GHDL only.
set -u
REPO=/home/orencollaco/GitHub/llama.vhdl
GS=/mnt/storage/gain16
GF=/mnt/storage/llama-gatefloor

vivado_present () {
    local p exe
    for p in /proc/[0-9]*; do
        exe=$(readlink -f "$p/exe" 2>/dev/null) || continue
        case "$exe" in */unwrapped/lnx64.o/vivado) return 0 ;; esac
    done
    return 1
}
if vivado_present; then echo "RESUME_ABORT: a Vivado is already present"; exit 9; fi

# --- 1. teeth Run B -------------------------------------------------------
# scratch104 holds the partial results of the killed run; they are not
# evidence.  Deleted by full literal path, nothing interpolated.
rm -rf /mnt/storage/llama-gatefloor/scratch104
mkdir -p "$GF/scratch104"
systemd-run --user --scope --quiet --unit=gatefloor-teethB \
    -p MemoryHigh=8G -p MemoryAccounting=yes \
    -- bash -c 'MV4I_FK33_FILE=/nonexistent REGRESS_SCRATCH=/mnt/storage/llama-gatefloor/scratch104 bash /mnt/storage/llama-gatefloor/tree/sim/regress.sh --jobs 1 > /mnt/storage/llama-gatefloor/teethB.log 2>&1'
echo "RESUME launched gatefloor-teethB"

# --- 2. oracle on the installed record-free form --------------------------
systemd-run --user --scope --quiet --unit=gain16-oracle-cbland \
    -p MemoryHigh=4G -p MemoryAccounting=yes \
    -- bash -c 'SD=/mnt/storage/gain16 bash /home/orencollaco/GitHub/llama.vhdl/hw/fk33/results/gain16_2026-08-30/oracle_run.sh cbland /home/orencollaco/GitHub/llama.vhdl/rtl/llama_top.vhd > /mnt/storage/gain16/oracle_cbland.log 2>&1'
echo "RESUME launched gain16-oracle-cbland"

# --- 3. cbland Vivado draw -------------------------------------------------
mkdir -p "$GS/rtl_cbland" "$GS/out"
cp "$REPO"/rtl/*.vhd "$GS/rtl_cbland/"
rm -f "$GS/rtl_cbland/llama_top.vhd"
python3 "$REPO/sim/ooc_normadapt_extract.py" \
    "$REPO/rtl/llama_top.vhd" "$GS/rtl_cbland/ooc_normadapt_top.vhd" \
    || { echo "RESUME_ABORT: extract failed"; exit 9; }
systemd-run --user --scope --quiet --unit=gain16-cbland \
    -p MemoryHigh=14G -p MemoryAccounting=yes \
    -- bash -c 'LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 bash /home/orencollaco/GitHub/llama.vhdl/sim/ooc_lutdiet_run.sh cbland ooc_normadapt /mnt/storage/gain16/out /mnt/storage/gain16/rtl_cbland "NORM_W_IMAGE=/mnt/storage/nwfix/img/norm_w_9b.hex" > /mnt/storage/gain16/cbland_run.log 2>&1'
echo "RESUME launched gain16-cbland"
echo "RESUME_ALL_LAUNCHED $(date -Is)"
