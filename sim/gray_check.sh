#!/usr/bin/env bash
# sim/gray_check.sh -- is rtl/async_fifo.vhd's pointer encoding ACTUALLY a gray
# code?  Exhaustively, over the source text that synthesis will read.
#
# ===========================================================================
# THE DEFECT THIS EXISTS TO KILL, AND WHY THE TWO EXISTING CHECKS CANNOT
# ===========================================================================
# `sim/mutate_async_fifo.sh` row G1 replaces BOTH `bin2gray` and `gray2bin`
# with the identity, so the pointers cross the clock boundary as plain BINARY.
# That is the classic CDC defect: a binary pointer sampled mid-transition by a
# foreign clock can resolve to a value that is neither the old one nor the new
# one, and the FIFO then reports an occupancy that never existed.
#
# It is invisible to BOTH existing instruments, and one of them actively
# rewards it:
#
#   * SIMULATION cannot see it.  MEASURED (section 4.1 of the write-up): the
#     identity IS a bijection, so a binary-pointer FIFO computes the same
#     numbers as a gray-pointer one on every cycle of every clock ratio.  An
#     RTL simulator assigns a whole `unsigned` atomically, so the only event
#     gray coding exists to survive -- a multi-bit bus caught part-way through
#     a transition -- is not in the model at all.  G1 survives all eight clock
#     ratios in `sim/tb_async_fifo.vhd`.  No stimulus fixes this; the missing
#     thing is a per-bit skew model, not a testcase.
#
#   * `report_cdc` cannot see it, and reports the DEFECT as an IMPROVEMENT.
#     MEASURED, this track, `sim/cdc_teeth.sh` rows BASE and G1: the honest
#     RTL yields 6 rule rows and the binary-pointer mutant yields 4.  Vivado
#     classifies a crossing by TOPOLOGY -- width, depth, ASYNC_REG, fan-in --
#     and has no concept of an encoding.  With gray coding the 10-bit pointer
#     splits into a 9-bit bus plus its MSB (the gray MSB IS the binary MSB, so
#     synthesis sources that bit straight off the counter), giving one
#     multi-bit row and one 1-bit row per direction.  Remove the gray coding
#     and the ten bits merge into a single bus, so two rows DISAPPEAR.
#     Therefore any review rule phrased as "the CDC report must not get worse"
#     PASSES the binary-pointer design.  See section 4.2.
#
# So the missing check is neither functional nor topological.  It is a
# statement about a pure function, and it is decidable by exhaustion.
#
# ===========================================================================
# WHAT THIS DOES
# ===========================================================================
# It extracts the bodies of `bin2gray` and `gray2bin` VERBATIM out of
# rtl/async_fifo.vhd -- the same bytes synthesis reads, not a transcription --
# drops them unchanged into a standalone probe entity that supplies only
# `AW` and `ptr_t`, and evaluates them over EVERY value of the pointer for
# every width from 2 to 14 bits.  Four properties, all exhaustive:
#
#   P_GRAY   hamming(enc(b), enc(b+1 mod 2**N)) = 1 for every b, INCLUDING the
#            wrap.  This is the property gray coding IS, and the one the
#            identity violates on its second step (enc(1)=1 -> enc(2)=2, two
#            bits).  This is what kills G1.
#   P_BIJ    enc is injective over the whole pointer space.  P_GRAY alone does
#            not imply it, and a non-injective pointer aliases full to empty.
#   P_INV    dec(enc(b)) = b for every b.  Kills the encoder/decoder
#            disagreement class (G2) -- though see the ATTRIBUTION column in
#            sim/mutate_gray.sh: simulation already kills that one, and this
#            check is not credited with it.
#   P_ZERO   enc(0) = 0.  Not a property of gray codes in general; it is a
#            property THIS RTL requires, because reset and the four-phase clear
#            both park the binary pointer at 0 and its encoded copy at 0
#            independently (`wp <= (others=>'0'); wp_g <= (others=>'0')`).  An
#            encoding with enc(0) /= 0 makes those two assignments disagree.
#
# WHAT IT DELIBERATELY DOES NOT DO, and this is the resolution floor rather
# than an oversight: it does not require the STANDARD reflected gray code.  Any
# bijective single-bit-change encoding with enc(0)=0 is accepted, because any
# such encoding is correct here.  `sim/mutate_gray.sh` row `GY` replaces both
# functions with the BIT-REVERSED gray code and this check passes it -- on
# purpose.  A check that went red on GY would be matching the source text, not
# the property, and would go red on every legitimate refactor.
#
# ===========================================================================
# FOUR VERDICTS.  "COULD NOT RUN" IS NEVER "PASS".
# ===========================================================================
#   PASS     every property held at every width.                    exit 0
#   FAIL     a property was violated; the first violation is named. exit 1
#   NOSHAPE  rtl/async_fifo.vhd does not contain exactly one `bin2gray` and
#            one `gray2bin`.  RED, not skipped: a check that quietly passes
#            when the thing it checks has been deleted is worse than absent.
#                                                                   exit 3
#   VOID     ghdl could not analyse or elaborate the probe.  RED as a gate,
#            but reported separately in the teeth table, because "the mutant
#            did not compile" is not "the mutant was detected".  A mutation
#            harness once scored 7 of 7 CAUGHT because ghdl could not open a
#            file; that is what this verdict exists to prevent.     exit 4
#
# Usage: bash sim/gray_check.sh [--rtl <file>] [--quiet] [--max-aw N]
# Env:   SCRATCH=<dir>  GHDL=<ghdl>
set -uo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
RTL="$REPO/rtl/async_fifo.vhd"
GHDL="${GHDL:-ghdl}"
QUIET=0
MAXAW=13          # widths 2..14 bits of pointer; 2**14 = 16384 values

while [ $# -gt 0 ]; do
  case "$1" in
    --rtl)    RTL="$2"; shift 2 ;;
    --quiet)  QUIET=1; shift ;;
    --max-aw) MAXAW="$2"; shift 2 ;;
    -h|--help) sed -n '2,90p' "$0"; exit 0 ;;
    *) echo "gray_check.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

SCRATCH="${SCRATCH:-$(mktemp -d -t graycheck.XXXXXX)}"
mkdir -p "$SCRATCH/work" "$SCRATCH/run"

say() { [ "$QUIET" = 1 ] || echo "$@"; }

# ---------------------------------------------------------------------------
# 1. EXTRACT.  Verbatim, and the count is a hard gate in BOTH directions.
# ---------------------------------------------------------------------------
# Zero matches means the function is gone (someone inlined the xor, or renamed
# it) and the check no longer knows what it is checking.  Two matches means an
# `--only`-style ambiguity in which one copy is tested and the other is not --
# the same silent-duplicate trap that makes a mutation table look full while
# half of it never ran.  Both are NOSHAPE, both are loud.
python3 - "$RTL" "$SCRATCH/extract" <<'PY'
import re, sys
src, out = sys.argv[1], sys.argv[2]
try:
    s = open(src).read()
except OSError as e:
    sys.stderr.write("NOSHAPE: cannot read %s: %s\n" % (src, e)); sys.exit(3)

def grab(name):
    pat = re.compile(r"^[ \t]*function[ \t]+%s[ \t]*\(.*?^[ \t]*end[ \t]+function[ \t]*;"
                     % re.escape(name), re.S | re.M)
    m = pat.findall(s)
    if len(m) != 1:
        sys.stderr.write("NOSHAPE: %s: found %d definitions of `%s', expected exactly 1\n"
                         % (src, len(m), name))
        sys.exit(3)
    return m[0]

enc = grab("bin2gray")
dec = grab("gray2bin")
open(out + ".enc", "w").write(enc)
open(out + ".dec", "w").write(dec)
sys.stderr.write("extracted %d bytes of bin2gray, %d bytes of gray2bin\n"
                 % (len(enc), len(dec)))
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "GRAY_CHECK: NOSHAPE  ($RTL does not have the shape this check reads)"
  exit 3
fi
say "gray_check: source $RTL"

# ---------------------------------------------------------------------------
# 2. GENERATE THE PROBE.  The extracted text is dropped in UNCHANGED; the
#    wrapper supplies only what async_fifo's architecture supplied, which is
#    `AW` (here a generic) and `ptr_t`.  If the extracted body referenced
#    anything else it would fail to analyse and the verdict would be VOID, not
#    PASS -- that asymmetry is the whole point of having a VOID verdict.
# ---------------------------------------------------------------------------
{
cat <<'HDR'
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gray_probe is
  generic ( AW : natural := 9 );
end entity;

architecture rtl of gray_probe is
  subtype ptr_t is unsigned(AW downto 0);

  -- ================= VERBATIM FROM THE RTL, DO NOT EDIT =================
HDR
cat "$SCRATCH/extract.enc"; echo
cat "$SCRATCH/extract.dec"; echo
cat <<'TAIL'
  -- ======================= END VERBATIM FROM RTL ========================

  function ham(a, b : ptr_t) return natural is
    variable x : ptr_t   := a xor b;
    variable n : natural := 0;
  begin
    for i in x'range loop
      if x(i) = '1' then n := n + 1; end if;
    end loop;
    return n;
  end function;

begin
  chk : process
    constant N    : natural := AW + 1;
    constant NVAL : natural := 2**N;
    type seen_t is array(0 to NVAL-1) of boolean;
    variable seen  : seen_t := (others => false);
    variable e0, e1, dd : ptr_t;
    variable ng, nb, ni, nz : natural := 0;
    variable h, code : natural;
  begin
    -- P_ZERO first: it is the cheapest and it is the one that is a property of
    -- THIS RTL rather than of gray codes in general.
    e0 := bin2gray(to_unsigned(0, N));
    if e0 /= to_unsigned(0, N) then
      nz := 1;
      report "P_ZERO VIOLATED: bin2gray(0) = " & integer'image(to_integer(e0))
        severity error;
    end if;

    for b in 0 to NVAL-1 loop
      e0 := bin2gray(to_unsigned(b, N));
      e1 := bin2gray(to_unsigned((b+1) mod NVAL, N));

      -- P_GRAY.  The wrap (b = NVAL-1 -> 0) is INCLUDED and is not a
      -- formality: the FIFO pointer is a free-running counter that wraps, and
      -- an encoding that is gray everywhere except across the wrap is a
      -- multi-bit crossing exactly once per lap.
      h := ham(e0, e1);
      if h /= 1 then
        if ng = 0 then
          report "P_GRAY VIOLATED first at b=" & integer'image(b) &
                 " N=" & integer'image(N) &
                 ": enc(b)=" & integer'image(to_integer(e0)) &
                 " enc(b+1)=" & integer'image(to_integer(e1)) &
                 " hamming=" & integer'image(h)
            severity error;
        end if;
        ng := ng + 1;
      end if;

      -- P_BIJ
      code := to_integer(e0);
      if seen(code) then
        if nb = 0 then
          report "P_BIJ VIOLATED first at b=" & integer'image(b) &
                 " N=" & integer'image(N) &
                 ": code " & integer'image(code) & " already produced"
            severity error;
        end if;
        nb := nb + 1;
      end if;
      seen(code) := true;

      -- P_INV
      dd := gray2bin(e0);
      if dd /= to_unsigned(b, N) then
        if ni = 0 then
          report "P_INV VIOLATED first at b=" & integer'image(b) &
                 " N=" & integer'image(N) &
                 ": gray2bin(bin2gray(b)) = " & integer'image(to_integer(dd))
            severity error;
        end if;
        ni := ni + 1;
      end if;
    end loop;

    report "GRAY_PROBE N=" & integer'image(N) &
           " values=" & integer'image(NVAL) &
           " p_gray_viol=" & integer'image(ng) &
           " p_bij_viol=" & integer'image(nb) &
           " p_inv_viol=" & integer'image(ni) &
           " p_zero_viol=" & integer'image(nz)
      severity note;

    if ng = 0 and nb = 0 and ni = 0 and nz = 0 then
      report "GRAY_PROBE: PASS N=" & integer'image(N) severity note;
    else
      report "GRAY_PROBE: FAIL N=" & integer'image(N) severity note;
    end if;
    wait;
  end process;
end architecture;
TAIL
} > "$SCRATCH/gray_probe.vhd"

# ---------------------------------------------------------------------------
# 3. ANALYSE.  GHDL here is the MCODE backend: `ghdl -e` writes no binary and
#    exits 0, so nothing is ever elaborated separately; `ghdl -r` is run
#    directly and its status is read as ${PIPESTATUS[0]} would be if it were
#    piped.  It is not piped, for exactly that reason.
# ---------------------------------------------------------------------------
if ! "$GHDL" -a --std=08 -frelaxed --workdir="$SCRATCH/work" \
       "$SCRATCH/gray_probe.vhd" >"$SCRATCH/analyze.log" 2>&1; then
  echo "GRAY_CHECK: VOID  (the probe did not analyse -- nothing was tested)"
  sed -n '1,8p' "$SCRATCH/analyze.log"
  echo "  probe kept at $SCRATCH/gray_probe.vhd"
  exit 4
fi

# ---------------------------------------------------------------------------
# 4. RUN, one exhaustive sweep per pointer width.
# ---------------------------------------------------------------------------
NPASS=0; NFAIL=0; NVOID=0; FIRST=""
for aw in $(seq 1 "$MAXAW"); do
  ( cd "$SCRATCH/run" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$SCRATCH/work" gray_probe -gAW="$aw" ) \
      >"$SCRATCH/run/aw$aw.log" 2>&1
  rrc=$?
  log="$SCRATCH/run/aw$aw.log"
  if grep -q "GRAY_PROBE: PASS" "$log"; then
    NPASS=$((NPASS+1))
    say "  AW=$aw  $(grep -o 'GRAY_PROBE N=.*' "$log" | head -1)"
  elif grep -q "GRAY_PROBE: FAIL" "$log"; then
    NFAIL=$((NFAIL+1))
    [ -z "$FIRST" ] && FIRST=$(grep -o 'P_[A-Z]* VIOLATED[^\\]*' "$log" | head -1)
    say "  AW=$aw  $(grep -o 'GRAY_PROBE N=.*' "$log" | head -1)"
    say "        $(grep -o 'P_[A-Z]* VIOLATED.*' "$log" | head -1)"
  else
    # No verdict line at all: elaboration died, a bound check fired, or the run
    # never terminated.  NOT a pass and NOT a detection.
    NVOID=$((NVOID+1))
    say "  AW=$aw  VOID rc=$rrc: $(grep -m1 -E 'error|bound check|assertion' "$log" | cut -c1-90)"
  fi
done

say ""
if [ "$NVOID" -gt 0 ]; then
  echo "GRAY_CHECK: VOID  ($NVOID of $MAXAW widths produced no verdict; pass=$NPASS fail=$NFAIL)"
  echo "  scratch kept at $SCRATCH"
  exit 4
fi
if [ "$NFAIL" -gt 0 ]; then
  echo "GRAY_CHECK: FAIL  ($NFAIL of $MAXAW widths violate a property) $FIRST"
  echo "  scratch kept at $SCRATCH"
  exit 1
fi
echo "GRAY_CHECK: PASS  ($NPASS widths, pointer 2..$((MAXAW+1)) bits, all exhaustive) $RTL"
exit 0
