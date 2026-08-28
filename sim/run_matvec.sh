#!/bin/sh
# Full subsystem A verification chain, from one source of truth.
#
#   tools/gen_arith.py  -->  ref/mv4i_arith.h  +  rtl/mv4i_arith_pkg.vhd
#                            + sim/arith_vectors.txt   (golden, both sides)
#   ref/matvec_int4     -->  sim/tr.txt                (every 7.4 intermediate)
#   sim/tb_arith        -->  VHDL primitives vs golden vectors
#   sim/tb_matvec_core  -->  RTL vs the C reference, STAGE BY STAGE
#
# The core is swept over shapes rather than run once, because the original
# single case (M=8 K=96 ROWS_IF=4) happened to make M a multiple of ROWS_IF and
# K a multiple of BLOCK, so it exercised neither pad rows nor the column mask.
set -e
cd "$(dirname "$0")/.."
mkdir -p sim/work_mv sim/work_arith sim/work_am sim/work_ws sim/work_ax

fail=0
echo "== 1. regenerate shared arithmetic (C + VHDL + vectors) =="
# THIS STEP OVERWRITES GENERATED FILES, AND IT HAS DESTROYED A REAL FIX.
#
# On 2026-08-27 a hand-added undefined-behaviour guard in ref/mv4i_arith.h
# (`if (sh >= 63) return (v < 0) ? -1 : 0;`, plus the sh=64 case one shift up)
# was silently deleted by this line: the file is generated, the generator does
# not emit that guard, so `--check` reported STALE and the regeneration threw
# the guard away.  It was recovered from git only because someone read the diff
# before committing.
#
# The real fix belongs in tools/gen_arith.py, which also emits
# rtl/mv4i_arith_pkg.vhd -- i.e. it changes RTL numeric behaviour and is not a
# change to make in passing.  Until then: back up first, and say so loudly
# enough that it cannot scroll past.
if ! python3 tools/gen_arith.py --check; then
  echo ""
  echo "  ####################################################################"
  echo "  #  GENERATED ARITHMETIC IS STALE AND IS ABOUT TO BE OVERWRITTEN.   #"
  echo "  #  If you hand-edited any of these files, YOUR EDIT IS BEING LOST. #"
  echo "  #  Backups: *.prechk next to each file.  Check 'git diff' after.   #"
  echo "  ####################################################################"
  for f in ref/mv4i_arith.h rtl/mv4i_arith_pkg.vhd sim/arith_vectors.txt; do
    [ -f "$f" ] && cp -p "$f" "$f.prechk"
  done
  python3 tools/gen_arith.py
  for f in ref/mv4i_arith.h rtl/mv4i_arith_pkg.vhd sim/arith_vectors.txt; do
    if [ -f "$f.prechk" ] && ! cmp -s "$f" "$f.prechk"; then
      echo "  CHANGED: $f   (previous contents in $f.prechk)"
    fi
  done
  echo ""
fi

echo "== 2. C reference self-test =="
cc -O2 -Wall -Wextra -o sim/work_mv/mv4i ref/matvec_int4.c
( cd ref && ../sim/work_mv/mv4i )

echo "== 3. VHDL primitives vs golden vectors =="
( cd sim/work_arith \
  && ghdl -a --std=08 --workdir=. ../../rtl/mv4i_arith_pkg.vhd ../tb_arith.vhd \
  && ghdl -e --std=08 --workdir=. tb_arith \
  && ghdl -r --std=08 --workdir=. tb_arith )

echo "== 4. activation memory mapping (7.8) =="
mkdir -p sim/work_am
( cd sim/work_am \
  && ghdl -a --std=08 --workdir=. ../../rtl/util_pkg.vhd \
        ../../rtl/act_mem_striped.vhd ../tb_act_mem.vhd \
  && ghdl -e --std=08 --workdir=. tb_act_mem )
for g in "544 32 4" "17408 32 4" "100 32 4" "64 16 2" "544 32 8"; do
  set -- $g
  ( cd sim/work_am && ghdl -r --std=08 --workdir=. tb_act_mem \
      -gELEMS=$1 -gBLK=$2 -gLANES=$3 --stop-time=500ms ) 2>&1 \
    | grep -oE 'act_mem_striped: .*' | sed 's/^/  /'
done

echo "== 4b. AXI read port, across outstanding depth (7.7) =="
# tb_axi_rd_port existed but was never wired into this script, so the read
# port's burst accounting was only ever exercised indirectly. MAXOUT is the
# reason it matters now: the AXU3EG sustains 0.664 beats/cycle per port with
# MAXOUT=2, and raising it is the leading candidate for the 33.6% starvation --
# but a port that miscounts outstanding bursts corrupts data rather than merely
# running slow, so sweep it here before spending a bitstream on it.
mkdir -p sim/work_rp
( cd sim/work_rp \
  && ghdl -a --std=08 --workdir=. ../../rtl/util_pkg.vhd \
        ../../rtl/stream_fifo.vhd ../../rtl/axi_rd_port.vhd ../tb_axi_rd_port.vhd \
  && ghdl -e --std=08 --workdir=. tb_axi_rd_port )
for g in "1 64 0" "2 64 3" "4 128 3" "4 128 0" "8 256 5" "2 64 7" "8 256 0"; do
  set -- $g
  out=$( cd sim/work_rp && ghdl -r --std=08 --workdir=. tb_axi_rd_port \
           -gMAXOUT=$1 -gDEPTH=$2 -gSTALL=$3 --stop-time=200ms 2>&1 )
  n=$(echo "$out" | grep -oE 'axi_rd_port: [0-9]+ bad beats' || true)
  if echo "$out" | grep -q "0 bad beats"; then
    printf "  MAXOUT=%-2s DEPTH=%-4s stall=%-2s  OK   %s\n" "$1" "$2" "$3" "$n"
  else
    printf "  MAXOUT=%-2s DEPTH=%-4s stall=%-2s  FAIL\n" "$1" "$2" "$3"
    echo "$out" | head -5
    fail=1
  fi
done

echo "== 4c. the board-facing wrapper elaborates =="
# matvec_int4_ip is the top the Vivado build instantiates as a module reference,
# and NOTHING else in this chain touches it -- so a generic added to the
# hierarchy but not threaded through it fails only at synthesis, ~2 min into a
# ~25 min build. That is exactly how MAXOUT broke: plumbed through
# weight_streamer, matvec_int4 and matvec_int4_ip but not matvec_int4_axi, and
# the block-design stage passed because the BD cell really does have the
# generic; the break was one level below it. This costs seconds.
#
# Two checks, because GHDL will not mix standards in one library: units
# analysed under --std=08 are invisible to a --std=93c analysis ("unit
# matvec_int4_axi not found in library work"), so the wrapper cannot be bound
# against its own hierarchy in 93 mode.
#
#   1. elaborate the whole hierarchy INCLUDING the wrapper under 2008. This is
#      what catches a generic or port that was not threaded through -- the real
#      bug class, and the one that cost a build.
#
# A standalone VHDL-93 check of the wrapper is NOT possible here and was tried:
# `ghdl -s --std=93c rtl/matvec_int4_ip.vhd` is documented as a syntax check but
# still resolves the direct entity instantiation, so it fails with "unit
# matvec_int4_axi not found in library work" no matter how 93-clean the file is.
# Binding it properly would need the hierarchy analysed under 93 too, which
# cannot happen because everything below it uses 2008. The wrapper being VHDL-93
# (Vivado refuses a 2008 module-reference top, [filemgmt 56-195]) is therefore
# enforced only by build_bringup.tcl's set_property file_type {VHDL} and by the
# build failing if it regresses.
rm -rf sim/work_ip && mkdir -p sim/work_ip
ipok=1
( cd sim/work_ip \
  && ghdl -a --std=08 --workdir=. ../../rtl/util_pkg.vhd \
        ../../rtl/mv4i_arith_pkg.vhd ../../rtl/stream_fifo.vhd \
        ../../rtl/axi_rd_port.vhd ../../rtl/weight_streamer.vhd \
        ../../rtl/act_mem_striped.vhd ../../rtl/matvec_core.vhd \
        ../../rtl/matvec_int4.vhd ../../rtl/matvec_int4_axi.vhd \
        ../../rtl/matvec_int4_ip.vhd \
  && ghdl -e --std=08 --workdir=. matvec_int4_ip ) >/dev/null 2>&1 \
  || { echo "  matvec_int4_ip FAILED to elaborate over its hierarchy"; ipok=0; fail=1; }
[ "$ipok" = "1" ] && echo "  matvec_int4_ip elaborates over its full hierarchy"

echo "== 5. RTL vs C reference, stage by stage, over shapes =="
( cd sim/work_mv \
  && ghdl -a --std=08 --workdir=. ../../rtl/util_pkg.vhd \
        ../../rtl/mv4i_arith_pkg.vhd ../../rtl/matvec_core.vhd \
        ../tb_matvec_core.vhd \
  && ghdl -e --std=08 --workdir=. tb_matvec_core )

#     M    K   ROWS_IF  STALL   what it covers beyond the baseline
#     ----------------------------------------------------------------------
#      8   96      4      0     baseline: both dims exact multiples
#      7  100      4      0     pad rows AND a partial last block
#      9   97      4      0     one valid column in the last block
#      8   96      1      0     degenerate ROWS_IF
#      8   96      2      0     ROWS_IF below the 4 the packer default uses
#     13  129      8      0     ROWS_IF above it, both dims ragged
#      1   33      4      0     single row, mostly pad
#      7  100      4      3     the ragged case under backpressure
#      9   97      4      2     heavier backpressure
#     13  129      8      5     wide and ragged under backpressure
#     16   32      4      7     exactly one block per row
#
# A 5th field selects the ADVERSARIAL vector (ref --trace ... 1): weights at
# the -127 codebook extreme, scales at 32767, activations at -32768,
# out_shift 0.  Every row saturates, so the BFP pass must report sat_event=1
# and the PARTIAL pass must report 0 on the SAME data -- the only case in the
# suite where that flag is anything but 0.
CASES="8:96:4:0 7:100:4:0 9:97:4:0 8:96:1:0 8:96:2:0 13:129:8:0 1:33:4:0
       7:100:4:3 9:97:4:2 13:129:8:5 16:32:4:7
       4:1024:4:0:1 13:1024:8:5:1"
# (fail initialised at the top, before stage 4b uses it)
for c in $CASES; do
  M=$(echo "$c" | cut -d: -f1); K=$(echo "$c" | cut -d: -f2)
  R=$(echo "$c" | cut -d: -f3); S=$(echo "$c" | cut -d: -f4)
  A=$(echo "$c" | cut -d: -f5); [ -n "$A" ] || A=0
  ( cd ref && ../sim/work_mv/mv4i --trace ../sim/tr.txt "$M" "$K" "$R" "$A" >/dev/null )
  # --stop-delta: the trace loader spends one delta per line and the K=1024
  # adversarial cases are ~5k lines, which trips ghdl's 5000 default and looks
  # exactly like a zero-delay loop.  It is not one.
  out=$( cd sim/work_mv && ghdl -r --std=08 --workdir=. tb_matvec_core \
           -gTRACE=../tr.txt -gRI="$R" -gSTALL="$S" --stop-time=50ms \
           --stop-delta=1000000 2>&1 )
  n=$(echo "$out" | grep -oE 'TOTAL: [0-9]+ stage \+ [0-9]+ output' || true)
  [ "$A" = 0 ] && sfx="" || sfx=" sat"
  if echo "$out" | grep -q "matches ref/matvec_int4.c"; then
    printf "  M=%-3s K=%-4s ROWS_IF=%-2s stall=%-2s%s  OK   %s\n" "$M" "$K" "$R" "$S" "$sfx" "$n"
  else
    printf "  M=%-3s K=%-4s ROWS_IF=%-2s stall=%-2s%s  FAIL\n" "$M" "$K" "$R" "$S" "$sfx"
    echo "$out" | head -5
    fail=1
  fi
done

echo "== 6. subsystem A end to end, from the REAL packed bytes =="
# Everything above compares one derivation against another.  This serves the
# packer's actual image over AXI to all NPORTS_W+1 masters and checks the result
# against the C reference, so a wrong sub-region layout, lane order, nibble
# order or scale interleave (6.4/6.5) shows up here and nowhere else.
mkdir -p sim/work_ws
( cd sim/work_ws \
  && ghdl -a --std=08 --workdir=. ../../rtl/util_pkg.vhd \
        ../../rtl/mv4i_arith_pkg.vhd ../../rtl/stream_fifo.vhd \
        ../../rtl/axi_rd_port.vhd ../../rtl/weight_streamer.vhd \
        ../../rtl/act_mem_striped.vhd ../../rtl/matvec_core.vhd \
        ../../rtl/matvec_int4.vhd ../tb_matvec_int4.vhd \
  && ghdl -e --std=08 --workdir=. tb_matvec_int4 )

# Fields are M:K:ROWS_IF:STALL[:ADDR_W[:BASE_HI]].  ADDR_W defaults to 32 so the
# historical rows are unchanged; the two 64-bit rows are appended below rather
# than replacing anything, because "it still works at 32" is half the claim.
E2E="8:96:4:3 7:100:4:3 9:97:4:2 16:32:4:5 1:33:4:0 13:129:8:3 8:96:2:7"
E2E_WIDE="8:96:4:3:64:0 8:96:4:3:64:1 7:100:4:3:64:1 13:129:8:3:64:1"
for c in $E2E $E2E_WIDE; do
  M=$(echo "$c" | cut -d: -f1); K=$(echo "$c" | cut -d: -f2)
  R=$(echo "$c" | cut -d: -f3); S=$(echo "$c" | cut -d: -f4)
  AW=$(echo "$c" | cut -d: -f5); [ -n "$AW" ] || AW=32
  BH=$(echo "$c" | cut -d: -f6); [ -n "$BH" ] || BH=0
  ( cd ref && ../sim/work_mv/mv4i --trace ../sim/tr.txt "$M" "$K" "$R" >/dev/null )
  out=$( cd sim/work_ws && ghdl -r --std=08 --workdir=. tb_matvec_int4 \
           -gTRACE=../tr.txt -gRI="$R" -gSTALL="$S" \
           -gADDR_W="$AW" -gBASE_HI="$BH" --stop-time=30ms 2>&1 )
  n=$(echo "$out" | grep -oE 'end to end: [0-9]+ rows compared[^,]*, [0-9]+ mismatches' || true)
  if echo "$out" | grep -q "from the packed bytes up"; then
    printf "  M=%-3s K=%-4s ROWS_IF=%-2s stall=%-2s aw=%-2s hi=%-1s  OK   %s\n" \
           "$M" "$K" "$R" "$S" "$AW" "$BH" "$n"
  else
    printf "  M=%-3s K=%-4s ROWS_IF=%-2s stall=%-2s aw=%-2s hi=%-1s  FAIL\n" \
           "$M" "$K" "$R" "$S" "$AW" "$BH"
    echo "$out" | head -5
    fail=1
  fi
done

echo "== 6b. the >4 GB base MUST FAIL at ADDR_W=32 (N5 negative control) =="
# A regression test that has never been seen to fail is not evidence.  This row
# is the same job as the 64-bit rows above with the address width narrowed, so
# the ONLY variable is whether the base can be represented.  If it passes, the
# truncation has become silent again and every 64-bit row above is vacuous.
( cd ref && ../sim/work_mv/mv4i --trace ../sim/tr.txt 8 96 4 >/dev/null )
# `set -e` is live and this command is SUPPOSED to fail, so the failure must
# be absorbed here or the script exits before it can be judged.
out=$( cd sim/work_ws && ghdl -r --std=08 --workdir=. tb_matvec_int4 \
         -gTRACE=../tr.txt -gRI=4 -gSTALL=3 -gADDR_W=32 -gBASE_HI=1 \
         --stop-time=30ms 2>&1 ) || true
if echo "$out" | grep -q "the base was truncated"; then
  echo "  ADDR_W=32 BASE_HI=1  correctly REFUSED: $(echo "$out" | grep -oE 'address high half is [0-9]+, expected [0-9]+' | head -1)"
else
  echo "  ADDR_W=32 BASE_HI=1  DID NOT FAIL -- the >4 GB wrap is silent again"
  echo "$out" | tail -3
  fail=1
fi


echo "== 7. the PS sequence over AXI-Lite (10 step 5, in simulation) =="
# Programs the descriptor, codebook and activations through the register map,
# starts, polls STATUS and reads the results back -- the same sequence the
# board-side C driver will follow, validated before any hardware exists.
mkdir -p sim/work_axi
( cd sim/work_axi \
  && ghdl -a --std=08 --workdir=. ../../rtl/util_pkg.vhd \
        ../../rtl/mv4i_arith_pkg.vhd ../../rtl/stream_fifo.vhd \
        ../../rtl/axi_rd_port.vhd ../../rtl/weight_streamer.vhd \
        ../../rtl/act_mem_striped.vhd ../../rtl/matvec_core.vhd \
        ../../rtl/matvec_int4.vhd ../../rtl/matvec_int4_axi.vhd \
        ../tb_matvec_axi.vhd \
  && ghdl -e --std=08 --workdir=. tb_matvec_axi )

for c in $E2E $E2E_WIDE; do
  M=$(echo "$c" | cut -d: -f1); K=$(echo "$c" | cut -d: -f2)
  R=$(echo "$c" | cut -d: -f3); S=$(echo "$c" | cut -d: -f4)
  AW=$(echo "$c" | cut -d: -f5); [ -n "$AW" ] || AW=32
  BH=$(echo "$c" | cut -d: -f6); [ -n "$BH" ] || BH=0
  [ "$R" = "4" ] || continue           # the register map is fixed at ROWS_IF=4
  ( cd ref && ../sim/work_mv/mv4i --trace ../sim/tr.txt "$M" "$K" "$R" >/dev/null )
  out=$( cd sim/work_axi && ghdl -r --std=08 --workdir=. tb_matvec_axi \
           -gTRACE=../tr.txt -gRI="$R" -gSTALL="$S" \
           -gADDR_W="$AW" -gBASE_HI="$BH" --stop-time=50ms 2>&1 )
  n=$(echo "$out" | grep -oE 'AXI: [0-9]+ rows read back, [0-9]+ mismatches' || true)
  e=$(echo "$out" | grep -oE 'ERR_ADDR correctly (latched|silent)' | head -1 || true)
  if echo "$out" | grep -q "through the AXI-Lite register map"; then
    printf "  M=%-3s K=%-4s stall=%-2s aw=%-2s hi=%-1s  OK   %s, %s\n" \
           "$M" "$K" "$S" "$AW" "$BH" "$n" "$e"
  else
    printf "  M=%-3s K=%-4s stall=%-2s aw=%-2s hi=%-1s  FAIL\n" \
           "$M" "$K" "$S" "$AW" "$BH"
    echo "$out" | grep -iE "error|mismatch|fail" | head -5
    fail=1
  fi
done

echo "== 7b. ERR_ADDR must latch when a base does not fit (N5 negative control) =="
# The register map accepts a 64-bit base at ANY ADDR_W, on purpose, so that a
# host driver is not a different program per bitstream.  What must never happen
# is that a base the fabric cannot reach is accepted quietly.  Here the wrapper
# is asked for a >4 GB base on a 32-bit build and must latch STATUS bit 4
# BEFORE any AXI transaction is issued.
( cd ref && ../sim/work_mv/mv4i --trace ../sim/tr.txt 8 96 4 >/dev/null )
out=$( cd sim/work_axi && ghdl -r --std=08 --workdir=. tb_matvec_axi \
         -gTRACE=../tr.txt -gRI=4 -gSTALL=3 -gADDR_W=32 -gBASE_HI=1 \
         --stop-time=50ms 2>&1 ) || true
if echo "$out" | grep -q "ERR_ADDR latched on a base this build can represent"; then
  echo "  ADDR_W=32 BASE_HI=1  correctly REFUSED by ERR_ADDR before start"
else
  echo "  ADDR_W=32 BASE_HI=1  DID NOT set ERR_ADDR -- a >4 GB base would wrap silently"
  echo "$out" | tail -3
  fail=1
fi

echo "== 8. the PACKER agrees with the C reference on the same bytes (N6) =="
# tools/pack_int4.py --crosscheck existed and was called from NOWHERE: not from
# this script, not from the Makefile, not from anything.  It was run by hand
# once, on 2026-08-27, and agreed exactly.  Nothing would have noticed if that
# stopped being true, which is the whole reason 6.4/6.5 are byte-pinned.
#
# BOTH DIRECTIONS, because each covers a different emitter:
#   8a  C emits, C and Python both read     -> the C packer's layout
#   8b  Python emits, C and Python both read -> the Python packer's layout
# 8a needs no model and always runs.  8b needs a GGUF and is skipped, loudly,
# when there is not one -- a skip that announces itself is not a silent pass.
mkdir -p sim/work_pk
for shape in "8 96 4" "13 129 4" "7 100 4" "1 33 4"; do
  set -- $shape
  f=sim/work_pk/c_${1}_${2}_${3}.mv4i
  sim/work_mv/mv4i --emit "$f" "$1" "$2" "$3" >/dev/null
  cline=$( sim/work_mv/mv4i "$f" )
  pline=$( python3 tools/pack_int4.py --crosscheck "$f" )
  if [ "$cline" = "$pline" ]; then
    printf "  8a C-packed M=%-3s K=%-4s  OK   %s\n" "$1" "$2" "$cline"
  else
    printf "  8a C-packed M=%-3s K=%-4s  FAIL\n" "$1" "$2"
    echo "     C      : $cline"
    echo "     python : $pline"
    fail=1
  fi
done

GGUF=${MV4I_GGUF:-/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf}
TENSOR=${MV4I_TENSOR:-blk.0.ssm_alpha.weight}
if [ -r "$GGUF" ] && python3 -c 'import tools.pack_int4' 2>/dev/null; then
  f=sim/work_pk/py_tensor.mv4i
  if python3 tools/pack_int4.py "$GGUF" "$TENSOR" "$f" --rows-if 4 >/dev/null 2>&1; then
    cline=$( sim/work_mv/mv4i "$f" )
    pline=$( python3 tools/pack_int4.py --crosscheck "$f" )
    if [ "$cline" = "$pline" ]; then
      echo "  8b python-packed $TENSOR  OK   $cline"
    else
      echo "  8b python-packed $TENSOR  FAIL"
      echo "     C      : $cline"
      echo "     python : $pline"
      fail=1
    fi
  else
    echo "  8b SKIPPED: $GGUF present but the packer could not read $TENSOR"
  fi
else
  echo "  8b SKIPPED: no readable GGUF at $GGUF (set MV4I_GGUF to run it)."
  echo "     8a still covers the layout; what 8b adds is the PYTHON emitter,"
  echo "     which is the one that will pack the real model."
fi

echo "== 9. the packer REFUSES geometries nothing implements (N6) =="
# --rows-if 80 used to succeed and emit an 80-sub-region file no design can
# consume: a plausible wrong file, not an error.  Each row below must exit
# non-zero AND write nothing.
for g in "80 128" "58 256" "8 256" "16 128"; do
  set -- $g
  out=sim/work_pk/refused.mv4i
  rm -f "$out"
  if python3 tools/pack_int4.py /dev/null t "$out" --rows-if "$1" --axi-dw "$2" \
       >/dev/null 2>&1; then
    printf "  ROWS_IF=%-3s AXI_DW=%-4s  ACCEPTED -- the foot-gun is back\n" "$1" "$2"
    fail=1
  elif [ -f "$out" ]; then
    printf "  ROWS_IF=%-3s AXI_DW=%-4s  refused but LEFT A FILE behind\n" "$1" "$2"
    fail=1
  else
    printf "  ROWS_IF=%-3s AXI_DW=%-4s  refused, no file written\n" "$1" "$2"
  fi
done
# and the geometries that ARE implemented must still be accepted, or the
# refusal above is just a broken packer rather than a guard.
for g in "1 128" "2 128" "4 128" "8 128"; do
  set -- $g
  if python3 -c "
import sys; sys.path.insert(0, 'tools')
import pack_int4 as P
P.check_geometry($1, $2, emitting=True)
" 2>/dev/null; then
    printf "  ROWS_IF=%-3s AXI_DW=%-4s  accepted, as it must be\n" "$1" "$2"
  else
    printf "  ROWS_IF=%-3s AXI_DW=%-4s  REFUSED but is implemented\n" "$1" "$2"
    fail=1
  fi
done

[ "$fail" -eq 0 ] || { echo "== FAILED =="; exit 1; }
echo "== all green =="
