#!/usr/bin/env bash
# sim/mutate_gray.sh -- teeth for sim/gray_check.sh, WITH AN ATTRIBUTION
# CONTROL.
#
# ===========================================================================
# WHY THIS FILE AND NOT JUST A KILL COUNT
# ===========================================================================
# A kill does not settle anything.  TRACK OI3MUT measured this on row N6:
# in one of four mutant pairs the kill belonged to an OLDER property, and
# without the control the table would have credited the new check with four
# detections when it deserved three.  So every row here is run TWICE:
#
#   COLUMN 1  sim/gray_check.sh          -- the new check
#   COLUMN 2  sim/tb_async_fifo.vhd      -- the pre-existing functional bench,
#                                           run on the SAME mutant bytes
#
# A row is credited to the new check ONLY when column 1 is red and column 2 is
# green.  Anything else is named for what it is.  Rows where BOTH are green are
# printed too and are the most informative lines in the table: they are either
# an honest resolution floor (`GY`, a different but valid gray code, which
# MUST pass) or a defect class that belongs to a third instrument (`G3`, `G4`,
# `C6` -- MTBF, which only `report_cdc` reaches).
#
# ===========================================================================
# VERDICTS.  "DID NOT COMPILE" IS NEVER "DETECTED".
# ===========================================================================
#   gray_check :  PASS | FAIL | NOSHAPE | VOID     (exit 0 | 1 | 3 | 4)
#   tb         :  SURV | KILL | ABORT   | VOID
#
# VOID is a hole in the measurement, not a detection, and it is counted
# separately in the summary.  A mutation harness in this repo once scored 7 of
# 7 CAUGHT because ghdl could not open a file; row `VD` below exists purely to
# prove that path is wired to VOID and not to a kill.
#
# Nothing under rtl/ is edited.  Every mutation is applied to a COPY.
#
# Usage: bash sim/mutate_gray.sh [--selftest]
# Env:   SCRATCH=<dir>   ONLY=<exact-tag>   GHDL=<ghdl>
set -uo pipefail

# SELF-ISOLATE -- bash reads a script lazily by byte offset, so an edit while
# an instance runs resumes it mid-token.  Same reason as sim/regress.sh:297.
if [ -z "${MUTG_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_gray.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_gray.sh: the private copy does not parse -- the original was" \
         "probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUTG_ISOLATED=1 MUTG_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUTG_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/async_fifo.vhd
TB=sim/tb_async_fifo.vhd
DEPS="rtl/util_pkg.vhd"
GHDL="${GHDL:-ghdl}"
SCRATCH="${SCRATCH:-$(mktemp -d -t mutgray.XXXXXX)}"
ONLY="${ONLY:-}"
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1
mkdir -p "$SCRATCH"

# ---------------------------------------------------------------------------
# THE UNIQUENESS GATE ON ROW NAMES, and it is checked at REGISTRATION, not at
# use.  A duplicate tag is otherwise SILENT: `--list` shows both rows, `ONLY=`
# returns on the first match, so one edit is never tested and the other is
# tested twice -- and the table looks full either way.  Teeth for this gate are
# `bash sim/mutate_gray.sh --selftest`.
# ---------------------------------------------------------------------------
SEEN_TAGS=""
register() {   # register <tag>
  local t="$1" s
  for s in $SEEN_TAGS; do
    if [ "$s" = "$t" ]; then
      echo "mutate_gray.sh: DUPLICATE ROW NAME '$t' -- one of the two edits" \
           "would never be tested.  Refusing to run." >&2
      exit 2
    fi
  done
  SEEN_TAGS="$SEEN_TAGS $t"
}

patch_file() {   # patch_file <src> <dst> <old> <new> [...]
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
    s = s.replace(old, new, 1)
open(dst, "w").write(s)
PY
}

# ---------------------------------------------------------------------------
# COLUMN 2, THE ATTRIBUTION CONTROL: the pre-existing functional bench, run on
# the same mutant bytes.  Implemented here rather than by shelling out to
# sim/mutate_async_fifo.sh so that the two columns provably see the SAME file
# and so that this file owns its own verdict parsing.
# ---------------------------------------------------------------------------
run_tb() {   # run_tb <dir-with-async_fifo.vhd>  -> prints "SURV|KILL|ABORT|VOID<TAB>detail"
  local dir="$1"
  mkdir -p "$dir/work" "$dir/run"
  local f ok=1
  for f in $DEPS; do
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$f" \
      >>"$dir/analyze.log" 2>&1 || ok=0
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$dir/async_fifo.vhd" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/$TB" \
    >>"$dir/analyze.log" 2>&1 || ok=0
  if [ "$ok" = 0 ]; then
    printf 'VOID\tdid not analyse\n'; return
  fi
  ( cd "$dir/run" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$dir/work" tb_async_fifo \
      --stop-time=4ms --stop-delta=2000000 ) >"$dir/tb.log" 2>&1
  local rc=$?
  python3 - "$dir/tb.log" "$rc" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
log = "\n".join(l for l in log.splitlines() if "metavalue detected" not in l)
tot  = re.search(r"async_fifo: (\d+) errors across 8 clock ratios", log)
diag = re.search(r"tb_async_fifo\.vhd:\d+:\d+:@[^:]*:\(report error\): (.+)", log)
rtlg = re.search(r"async_fifo\.vhd:\d+:\d+:@[^:]*:"
                 r"\((?:assertion|report) failure\): (async_fifo: .+)", log)
bound= re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                 r"value [-\d]+ out of range[^\n]*)", log)
lang = re.search(r"ghdl[^:]*:error: (.+)", log)
if tot and int(tot.group(1)) == 0 and "PASS: tb_async_fifo" in log:
    print("SURV\t0 errors across 8 clock ratios")
elif diag:                       print("KILL\t%s" % diag.group(1).strip()[:52])
elif tot and int(tot.group(1)):  print("KILL\t%s errors, no named diagnostic" % tot.group(1))
elif rtlg:                       print("ABORT\t%s" % rtlg.group(1).strip()[:52])
elif bound:                      print("ABORT\t%s" % bound.group(1).strip()[:52])
elif rc == 124:                  print("ABORT\twall-clock timeout 300s")
elif lang:                       print("VOID\t%s" % lang.group(1).strip()[:52])
else:                            print("ABORT\tno verdict line and no error")
PY
}

# ---------------------------------------------------------------------------
# COLUMN 1: the new check.
# ---------------------------------------------------------------------------
run_gray() {   # run_gray <dir-with-async_fifo.vhd> -> "PASS|FAIL|NOSHAPE|VOID<TAB>detail"
  local dir="$1" out rc
  out=$(SCRATCH="$dir/gc" bash "$REPO/sim/gray_check.sh" --quiet \
          --rtl "$dir/async_fifo.vhd" 2>&1)
  rc=$?
  local v det
  case "$rc" in
    0) v=PASS ;; 1) v=FAIL ;; 3) v=NOSHAPE ;; 4) v=VOID ;;
    *) v=VOID ;;
  esac
  det=$(printf '%s\n' "$out" | grep -m1 -E 'GRAY_CHECK:|NOSHAPE:' | sed 's/^ *//' | cut -c1-72)
  printf '%s\t%s\n' "$v" "$det"
}

NROW=0; NCRED=0; NBOTH=0; NNEITHER=0; NTBONLY=0; NVOIDROW=0; NSHAPE=0
ROWS=""

row() {   # row <tag> <expect_gray> <expect_tb> <desc> <old> <new> [...]
  local tag="$1" xg="$2" xt="$3" desc="$4"; shift 4
  register "$tag"
  [ -n "$ONLY" ] && [ "$tag" != "$ONLY" ] && return
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  NROW=$((NROW+1))

  if ! patch_file "$REPO/$RTL" "$dir/async_fifo.vhd" "$@" 2>"$dir/patch.log"; then
    printf '%-5s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$desc"
    sed -n '1,2p' "$dir/patch.log"
    NVOIDROW=$((NVOIDROW+1)); return
  fi

  local g t gv gd tv td
  g=$(run_gray "$dir"); gv="${g%%$'\t'*}"; gd="${g#*$'\t'}"
  t=$(run_tb   "$dir"); tv="${t%%$'\t'*}"; td="${t#*$'\t'}"

  local attr
  # ORDER MATTERS.  NOSHAPE is classified BEFORE VOID, because the two rows
  # that trip the shape gate (NF, DUP) also make the design ambiguous or
  # renamed for the OTHER column, and reading the VOID first would report the
  # shape gate as a hole in the measurement when it is the measurement.
  if [ "$gv" = NOSHAPE ]; then
    attr="SHAPE GATE"; NSHAPE=$((NSHAPE+1))
  elif [ "$gv" = VOID ] || [ "$tv" = VOID ]; then
    attr="VOID-HOLE"; NVOIDROW=$((NVOIDROW+1))
  elif [ "$gv" != PASS ] && [ "$tv" = SURV ]; then
    attr="NEW CHECK ONLY"; NCRED=$((NCRED+1))
  elif [ "$gv" != PASS ] && [ "$tv" != SURV ]; then
    attr="both"; NBOTH=$((NBOTH+1))
  elif [ "$gv" = PASS ] && [ "$tv" != SURV ]; then
    attr="OLD BENCH ONLY"; NTBONLY=$((NTBONLY+1))
  else
    attr="NEITHER"; NNEITHER=$((NNEITHER+1))
  fi

  local flag=""
  { [ "$gv" != "$xg" ] || [ "$tv" != "$xt" ]; } && flag="  <<< NOT AS PREDICTED (expected gray=$xg tb=$xt)"

  printf '%-5s gray=%-8s tb=%-6s  %-15s %s%s\n' "$tag" "$gv" "$tv" "$attr" "$desc" "$flag"
  printf '        gray: %s\n' "$gd"
  printf '        tb  : %s\n' "$td"
  ROWS="$ROWS$tag|$gv|$tv|$attr\n"
}

# ===========================================================================
# SELFTEST: teeth for the uniqueness gate itself.  A gate never shown to fire
# has not been shown to work.
# ===========================================================================
if [ "$SELFTEST" = 1 ]; then
  echo "=== selftest: the duplicate-row-name gate ==="
  ( register AA; register BB; register AA; echo "GATE DID NOT FIRE" ) \
    >"$SCRATCH/selftest.log" 2>&1
  rc=$?
  cat "$SCRATCH/selftest.log"
  if [ "$rc" = 2 ] && grep -q "DUPLICATE ROW NAME 'AA'" "$SCRATCH/selftest.log"; then
    echo "SELFTEST: PASS -- the uniqueness gate fires on a duplicate tag"; exit 0
  fi
  echo "SELFTEST: FAIL -- the uniqueness gate did NOT fire (rc=$rc)"; exit 1
fi

# ===========================================================================
# 0. THE CONTROL.  A table measured against a check that is not green on the
#    honest RTL measures nothing.
# ===========================================================================
echo "=== sim/mutate_gray.sh -- teeth for sim/gray_check.sh, with attribution"
echo "scratch: $SCRATCH"
echo
echo "=== control: the UNMUTATED rtl/async_fifo.vhd ==="
mkdir -p "$SCRATCH/CTRL"
cp "$REPO/$RTL" "$SCRATCH/CTRL/async_fifo.vhd"
cg=$(run_gray "$SCRATCH/CTRL"); ct=$(run_tb "$SCRATCH/CTRL")
printf 'CTRL  gray=%-8s tb=%-6s\n' "${cg%%$'\t'*}" "${ct%%$'\t'*}"
printf '        gray: %s\n        tb  : %s\n' "${cg#*$'\t'}" "${ct#*$'\t'}"
if [ "${cg%%$'\t'*}" != PASS ] || [ "${ct%%$'\t'*}" != SURV ]; then
  echo "CONTROL FAILED -- nothing below would mean anything"; exit 2
fi
echo

echo "---- class IDENTITY: the defect neither existing instrument reaches ----"

row G1 FAIL SURV "G1: BOTH functions become the identity -- pointers cross as plain BINARY" \
"    return b xor shift_right(b, 1);" \
"    return b;" \
"    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;" \
"    b := g;"

row G1E FAIL KILL "G1E: only the ENCODER becomes the identity" \
"    return b xor shift_right(b, 1);" \
"    return b;"

row G2 FAIL KILL "G2: only the DECODER becomes the identity (simulation already kills this)" \
"    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;" \
"    b := g;"

echo
echo "---- class WRONG-CODE: bijective, invertible, but not single-bit-change ----"

row GZ FAIL KILL "GZ: the encoder shifts LEFT -- still invertible, no longer a gray code" \
"    return b xor shift_right(b, 1);" \
"    return b xor shift_left(b, 1);"

row GX FAIL KILL "GX: COMPLEMENT gray -- a real gray code, but enc(0) /= 0, which this RTL's reset and clear both assume" \
"    return b xor shift_right(b, 1);" \
"    return not (b xor shift_right(b, 1));" \
"    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;" \
"    b(AW) := not g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor (not g(i));
    end loop;"

echo
echo "---- THE RESOLUTION FLOOR: a DIFFERENT but entirely valid gray code ----"
echo "     GY MUST pass both columns.  A check that reddens here is matching"
echo "     the source text, not the property, and would redden on any refactor."

row GY PASS SURV "GY: BIT-REVERSED gray code -- bijective, single-bit-change, enc(0)=0.  Correct, and must survive" \
"  function bin2gray(b : ptr_t) return ptr_t is
  begin
    return b xor shift_right(b, 1);
  end function;" \
"  function bin2gray(b : ptr_t) return ptr_t is
    variable g : ptr_t := b xor shift_right(b, 1);
    variable r : ptr_t := (others => '0');
  begin
    for i in 0 to AW loop
      r(i) := g(AW - i);
    end loop;
    return r;
  end function;" \
"    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;
    return b;" \
"    for i in 0 to AW loop
      u(i) := g(AW - i);
    end loop;
    b(AW) := u(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor u(i);
    end loop;
    return b;" \
"  function gray2bin(g : ptr_t) return ptr_t is
    variable b : ptr_t := (others => '0');" \
"  function gray2bin(g : ptr_t) return ptr_t is
    variable b : ptr_t := (others => '0');
    variable u : ptr_t := (others => '0');"

echo
echo "---- class MTBF: NOT this check's business, listed so the table says so ----"
echo "     These belong to report_cdc; see sim/cdc_teeth.sh rows G3/G4/C6."

row G3 PASS SURV "G3: read pointer crosses through ONE flop, not two" \
"  rp_bin_w <= gray2bin(rp_g_s2);" \
"  rp_bin_w <= gray2bin(rp_g_s1);"

row G4 PASS SURV "G4: write pointer crosses through ONE flop, not two" \
"  wp_bin_r <= gray2bin(wp_g_s2);" \
"  wp_bin_r <= gray2bin(wp_g_s1);"

row C6 PASS SURV "C6: the clear request crosses through ONE flop, not two" \
"      elsif clr_r_s2 = '1' then" \
"      elsif clr_r_s1 = '1' then"

echo
echo "---- class SHAPE and VOID: teeth for this check's own failure modes ----"

row NF NOSHAPE SURV "NF: bin2gray RENAMED to b2g -- functionally identical, and the check can no longer find what it checks" \
"  function bin2gray(b : ptr_t) return ptr_t is" \
"  function b2g(b : ptr_t) return ptr_t is" \
"          wp_g <= bin2gray(wp + 1);" \
"          wp_g <= b2g(wp + 1);" \
"          rp_g <= bin2gray(rp + 1);" \
"          rp_g <= b2g(rp + 1);"

row DUP NOSHAPE VOID "DUP: a SECOND bin2gray is added -- the silent-duplicate trap, in the RTL rather than in a table" \
"  function gray2bin(g : ptr_t) return ptr_t is" \
"  function bin2gray(b : ptr_t) return ptr_t is
  begin
    return b xor shift_right(b, 1);
  end function;

  function gray2bin(g : ptr_t) return ptr_t is"

row VD VOID VOID "VD: the encoder body is made SYNTACTICALLY INVALID -- must be VOID, never a kill" \
"    return b xor shift_right(b, 1);" \
"    return b xor shift_right(b);"

echo
echo "======================================================================="
printf 'rows=%d   NEW CHECK ALONE=%d   both=%d   old bench only=%d   NEITHER=%d   shape gate=%d   VOID=%d\n' \
  "$NROW" "$NCRED" "$NBOTH" "$NTBONLY" "$NNEITHER" "$NSHAPE" "$NVOIDROW"
echo
echo "A row where BOTH columns are green is either the deliberate resolution"
echo "floor (GY) or a defect class owned by report_cdc (G3/G4/C6).  Neither is"
echo "a miss, and neither is a pass either -- read the class heading."
echo "scratch: $SCRATCH"
