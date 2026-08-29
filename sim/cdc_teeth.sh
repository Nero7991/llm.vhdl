#!/usr/bin/env bash
# sim/cdc_teeth.sh -- does the STATIC flow catch what simulation could not?
#
# THE QUESTION.  docs/debugging/2026-08-29_cdc-and-fifo-coverage.md closed
# rtl/async_fifo.vhd with 24 of 33 mutations killed and named its nine
# survivors.  Four of those nine are survivors BY CONSTRUCTION -- no functional
# bench can ever kill them, because they change an MTBF property and an RTL
# simulator samples atomically:
#
#   G1  BOTH bin2gray and gray2bin become the identity  (binary pointers)
#   G3  the read pointer crosses through ONE flop, not two
#   G4  the write pointer crosses through ONE flop, not two
#   C6  the clear request crosses through ONE flop, not two
#
# That write-up's own closing list says the way to reach them is Vivado
# report_cdc plus ASYNC_REG plus asynchronous clock groups.  This harness runs
# exactly that, on the same four mutations, and reports CAUGHT or NOT CAUGHT
# per mutation rather than asserting either.
#
# TWO CONTROLS, and they are the point of the harness rather than decoration:
#
#   N0   NO set_clock_groups at all.  report_cdc on a design whose clocks are
#        not declared asynchronous is the "reports nothing and looks clean"
#        trap.  Run it so the log says what actually happens.
#   N1   the read pointer crosses with NO synchroniser at all.  If the flow
#        does not flag THIS, the flow is measuring nothing and every clean
#        result below is worthless.
#   N2   ASYNC_REG applied to every synchroniser flop.  The proposed remedy for
#        the finding this harness makes; run so that "the report changes" is a
#        measurement and not a prediction.
#
# Nothing under rtl/ is edited.  Every mutation is applied to a COPY.
#
# Usage: bash sim/cdc_teeth.sh
# Env:   SCRATCH=<dir>  ONLY=<tag-substring>  MEMMAX=6G
set -uo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
export MEMMAX="${MEMMAX:-6G}"
mkdir -p "$SCRATCH/out"

SRCS="util_pkg.vhd stream_fifo.vhd async_fifo.vhd axi_rd_fsm.vhd axi_rd_port.vhd"

patch_file() {   # patch_file <src> <dst> <old> <new> [<old> <new> ...]
  python3 - "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES, expected 1\n" % (i // 2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
}

# Reduce one report_cdc run to a comparable signature: the rule-ID summary, the
# per-row synchroniser DEPTH, and the ASYNC_REG census.  Comparing signatures
# rather than whole files is what makes "did the report change" answerable.
signature() {   # signature <runlog> <cdcrpt>
  python3 - "$1" "$2" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rpt = open(sys.argv[2], errors="replace").read()

ar_true = re.search(r"CDC_ASYNC_REG_TRUE (\d+)", log)
ar_tot  = re.search(r"CDC_ASYNC_REG_TOTAL_SEQ (\d+)", log)
srl     = re.search(r"CDC_SRL_COUNT (\d+)", log)

rules = re.findall(r"^(CDC-\d+)\s+(\w+)\s+(\d+)\s+(.+?)\s*$", rpt, re.M)
# the per-crossing detail rows: "  1  CDC-2  Warning  <desc>  <depth>  <exc> ..."
rows = re.findall(
    r"^\s*\d+\s+(CDC-\d+)\s+(\w+)\s+(.+?)\s{2,}(\d+|N/A)\s{2,}(\S.*?)\s{2,}(\S+)\s{2,}(\S+)\s*$",
    rpt, re.M)

parts = []
parts.append("ASYNC_REG=%s/%s SRL=%s" % (
    ar_true.group(1) if ar_true else "?",
    ar_tot.group(1) if ar_tot else "?",
    srl.group(1) if srl else "?"))
if rules:
    parts.append("rules=" + ",".join("%s:%s:%s" % (a, b, c) for a, b, c in
                                     sorted((r[0], r[1], r[2]) for r in rules)))
else:
    parts.append("rules=NONE")
if rows:
    # The EXCEPTION column belongs in the signature.  MEASURED 2026-08-29: the
    # no-clock-groups control N0 produced a byte-identical rule summary to the
    # baseline and differed ONLY here, "None" against "Asynch Clock Groups".
    # A signature without this column reports the two runs as identical, which
    # is exactly the wrong conclusion to draw about a missing constraint.
    d = sorted("%s/d%s/%s" % (r[0], r[3], r[4].strip().replace(" ", "_"))
               for r in rows)
    parts.append("rows=" + ",".join(d))
else:
    parts.append("rows=NONE")
print(" | ".join(parts))
PY
}

run_variant() {   # run_variant <tag> <groups> <desc>
  local tag="$1" grp="$2" desc="$3"
  local dir="$SCRATCH/$tag"
  local log="$SCRATCH/out/${tag}.log"
  if ! RUNDIR="$dir/run" bash "$REPO/sim/run_ooc_cdc.sh" "$log" axi_rd_port \
        rtldir="$dir/rtl" outdir="$SCRATCH/out" tag="$tag" \
        groups="$grp" dual=1 2>"$SCRATCH/out/${tag}.runner"; then
    printf '%-6s FLOW FAILED -- tested nothing -- %s\n' "$tag" "$desc"
    tail -3 "$SCRATCH/out/${tag}.runner"
    return 1
  fi
  local sig
  sig=$(signature "$log" "$SCRATCH/out/cdc_${tag}.rpt")
  local peak
  peak=$(awk '/Maximum resident set size/{print $NF}' "$log.time" 2>/dev/null)
  echo "$sig" > "$SCRATCH/out/${tag}.sig"
  printf '%-6s peakRSS=%sKB  %s\n' "$tag" "${peak:-?}" "$sig"
  printf '       %s\n' "$desc"
}

stage() {   # stage <tag>  -- copy the honest sources into <tag>/rtl
  local tag="$1"
  rm -rf "$SCRATCH/$tag/rtl"; mkdir -p "$SCRATCH/$tag/rtl"
  local f
  for f in $SRCS; do cp "$REPO/rtl/$f" "$SCRATCH/$tag/rtl/$f"; done
}

want() { [ -z "$ONLY" ] || [[ "$1" == *"$ONLY"* ]]; }

echo "=== sim/cdc_teeth.sh -- static CDC flow against CDC-BENCH's own mutations"
echo "scratch: $SCRATCH"
echo

# ---------------------------------------------------------------------------
# BASE.  The honest RTL, clocks declared asynchronous.  Every row below is read
# against this one; a table with no baseline measures nothing.
# ---------------------------------------------------------------------------
if want BASE; then
  stage BASE
  run_variant BASE 1 "the HONEST RTL at HEAD, clock groups declared -- THE BASELINE"
fi

# ---------------------------------------------------------------------------
# CONTROLS
# ---------------------------------------------------------------------------
if want N0; then
  stage N0
  run_variant N0 0 "CONTROL: honest RTL, set_clock_groups NOT emitted -- the 'reports nothing and looks clean' trap, measured"
fi

if want N1; then
  stage N1
  patch_file "$REPO/rtl/async_fifo.vhd" "$SCRATCH/N1/rtl/async_fifo.vhd" \
"  rp_bin_w <= gray2bin(rp_g_s2);" \
"  rp_bin_w <= gray2bin(rp_g);" || echo "N1 ANCHOR FAILED"
  run_variant N1 1 "CONTROL, KNOWN BAD: the read pointer crosses with NO synchroniser at all.  If this is not flagged, nothing below means anything"
fi

if want N2; then
  stage N2
  # THE FIX, RUN BACKWARDS.  Until 2026-08-29 neither file carried ASYNC_REG on
  # any synchroniser flop; this track added it (see the declaration block in
  # rtl/async_fifo.vhd for the measurement).  N2 STRIPS it again, so the row
  # below reproduces the pre-fix report and the before/after stays measurable
  # from the tree at any later date rather than only from this session's logs.
  python3 - "$SCRATCH/N2/rtl/async_fifo.vhd" "$SCRATCH/N2/rtl/axi_rd_port.vhd" <<'PYX'
import re, sys
for p in sys.argv[1:]:
    s = open(p).read()
    n = len(re.findall(r'^\s*attribute async_reg\b.*$', s, re.M))
    if n == 0:
        sys.stderr.write("N2: %s carries NO async_reg attribute -- the strip "
                         "would test nothing\n" % p)
        sys.exit(2)
    s = re.sub(r'^\s*attribute async_reg\b.*\n', '', s, flags=re.M)
    open(p, 'w').write(s)
PYX
  run_variant N2 1 "CONTROL, THE FIX RUN BACKWARDS: ASYNC_REG STRIPPED from every synchroniser flop in both files -- the state of the tree before 2026-08-29"
fi

# ---------------------------------------------------------------------------
# THE FOUR SURVIVORS.  Anchors copied verbatim from sim/mutate_async_fifo.sh so
# that the mutation the static flow sees is byte-for-byte the one simulation
# could not kill.
# ---------------------------------------------------------------------------
if want G1; then
  stage G1
  patch_file "$REPO/rtl/async_fifo.vhd" "$SCRATCH/G1/rtl/async_fifo.vhd" \
"    return b xor shift_right(b, 1);" \
"    return b;" \
"    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;" \
"    b := g;" || echo "G1 ANCHOR FAILED"
  run_variant G1 1 "G1: BOTH bin2gray and gray2bin become the identity -- the pointers cross as plain BINARY"
fi

if want G3; then
  stage G3
  patch_file "$REPO/rtl/async_fifo.vhd" "$SCRATCH/G3/rtl/async_fifo.vhd" \
"  rp_bin_w <= gray2bin(rp_g_s2);" \
"  rp_bin_w <= gray2bin(rp_g_s1);" || echo "G3 ANCHOR FAILED"
  run_variant G3 1 "G3: the read pointer crosses through ONE flop, not two"
fi

if want G4; then
  stage G4
  patch_file "$REPO/rtl/async_fifo.vhd" "$SCRATCH/G4/rtl/async_fifo.vhd" \
"  wp_bin_r <= gray2bin(wp_g_s2);" \
"  wp_bin_r <= gray2bin(wp_g_s1);" || echo "G4 ANCHOR FAILED"
  run_variant G4 1 "G4: the write pointer crosses through ONE flop, not two"
fi

if want C6; then
  stage C6
  patch_file "$REPO/rtl/async_fifo.vhd" "$SCRATCH/C6/rtl/async_fifo.vhd" \
"      elsif clr_r_s2 = '1' then" \
"      elsif clr_r_s1 = '1' then" || echo "C6 ANCHOR FAILED"
  run_variant C6 1 "C6: the clear request crosses through ONE flop into the read domain, not two"
fi

# ---------------------------------------------------------------------------
# THE PORT'S OWN GENERATE.  sim/mutate_axi_rd_port.sh has its own MTBF-class
# survivors -- six mutations that cut or delete a synchroniser in
# rtl/axi_rd_port.vhd's g_dc block and are invisible to sim/tb_axi_rd_port for
# exactly the reason G1/G3/G4/C6 are invisible to sim/tb_async_fifo.  They are
# run through the static flow here for the same reason.
# ---------------------------------------------------------------------------
if want P5; then
  stage P5
  patch_file "$REPO/rtl/axi_rd_port.vhd" "$SCRATCH/P5/rtl/axi_rd_port.vhd" \
"    run_c <= run_s2;" \
"    run_c <= run_s1;" || echo "P5 ANCHOR FAILED"
  run_variant P5 1 "P5: run_c is taken one flop early -- a 1FF crossing"
fi

if want P6; then
  stage P6
  patch_file "$REPO/rtl/axi_rd_port.vhd" "$SCRATCH/P6/rtl/axi_rd_port.vhd" \
"    run_c <= run_s2;" \
"    run_c <= run_f;" || echo "P6 ANCHOR FAILED"
  run_variant P6 1 "P6: run_c is the AXI-domain run level with NO SYNCHRONISER AT ALL"
fi

if want PA; then
  stage PA
  patch_file "$REPO/rtl/axi_rd_port.vhd" "$SCRATCH/PA/rtl/axi_rd_port.vhd" \
"    frst  <= rst_s2;" \
"    frst  <= rst;" || echo "PA ANCHOR FAILED"
  run_variant PA 1 "PA: frst is the RAW core-domain reset, crossing unsynchronised"
fi

if want PB; then
  stage PB
  patch_file "$REPO/rtl/axi_rd_port.vhd" "$SCRATCH/PB/rtl/axi_rd_port.vhd" \
"        rst_s1 <= rst; rst_s2 <= rst_s1;" \
"        rst_s1 <= rst; rst_s2 <= rst;" || echo "PB ANCHOR FAILED"
  run_variant PB 1 "PB: the reset crosses through ONE flop, not two"
fi

if want PF; then
  stage PF
  patch_file "$REPO/rtl/axi_rd_port.vhd" "$SCRATCH/PF/rtl/axi_rd_port.vhd" \
"  q_valid <= f_qv when run_c = '1' else '0';" \
"  q_valid <= f_qv when run_f = '1' else '0';" || echo "PF ANCHOR FAILED"
  run_variant PF 1 "PF: q_valid gated on the AXI-domain run level directly -- combinational straight across the CDC"
fi

if want P1; then
  stage P1
  patch_file "$REPO/rtl/axi_rd_port.vhd" "$SCRATCH/P1/rtl/axi_rd_port.vhd" \
"    start_f <= s_t2 xor s_t3;" \
"    start_f <= s_t1 xor s_t2;" || echo "P1 ANCHOR FAILED"
  run_variant P1 1 "P1: the start toggle's edge detector sits on a 1FF crossing"
fi

# ---------------------------------------------------------------------------
# TEETH-CHECK FOR G1 ITSELF.  Simulation kills G2 instantly, which is what
# proved its bench watched the pointers.  The static flow needs its own
# equivalent: if G2 and G1 and BASE all produce the SAME report, then the
# static flow is blind to the pointer ENCODING as such, and saying so is the
# result.
# ---------------------------------------------------------------------------
if want G2; then
  stage G2
  patch_file "$REPO/rtl/async_fifo.vhd" "$SCRATCH/G2/rtl/async_fifo.vhd" \
"    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;" \
"    b := g;" || echo "G2 ANCHOR FAILED"
  run_variant G2 1 "G2: only the DECODER becomes the identity -- simulation kills this at once.  Does the static flow see it?"
fi

echo
echo "======================================================================="
echo "signatures, side by side"
for f in "$SCRATCH"/out/*.sig; do
  printf '%-6s %s\n' "$(basename "$f" .sig)" "$(cat "$f")"
done
echo
echo "A row IDENTICAL to BASE is a mutation the static flow did NOT catch."
echo "scratch: $SCRATCH"
