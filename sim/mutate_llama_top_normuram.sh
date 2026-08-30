#!/usr/bin/env bash
# TEETH FOR THE NORM-GAIN STORE -- rtl/llama_top.vhd's `gwm` generate.
# TRACK NORMURAM, 2026-08-30.
#
# WHAT THIS EXISTS TO ANSWER.  On 2026-08-30 the gain store moved out of LUT
# fabric: `wsel <= NW_TBL(nidx)`, a 65,536-bit register folded into logic of a
# 7-bit index over a 65-entry elaboration-time constant, became an inferred
# memory reshaped to `GW` elements per word and shifted into a plain register.
# The claim being made is NOT that the new store is correct in isolation -- it
# is that THE VALUES rmsnorm_rs SEES DID NOT MOVE.  `sim/tb_llama_top_normw`
# already reports that: it PASSES with all four EXP_* landmarks unchanged.
#
# A CHECKER NEVER SHOWN TO FAIL HAS NOT BEEN SHOWN TO WORK.  The reshape
# introduces exactly the failure class this project has recorded as the `m7
# mutant`: a packer and an unpacker that are wrong in mirror-image ways and
# agree with each other.  Packing four elements into a 64-bit word and reading
# them back in the wrong order permutes every gain vector in groups of four,
# which is a wrong number with no structural symptom whatsoever.  Rows U2 and
# U3 are that mutation in its two directions.  Nothing below is decoration:
# each row asks whether the landmarks discriminate on the thing they are now
# being trusted to guard.
#
# ROWS THAT DO NOT BITE ARE REPORTED UNDER THEIR OWN NAMES.  U7 is expected to
# survive and is the more useful half of the table: it fixes what this harness
# cannot see.
#
# Usage:  bash sim/mutate_llama_top_normuram.sh
# Env:    SCRATCH=<dir>   ONLY="<tag> <tag> ..."   (EXACT tags, space separated)
#
# NO HARDWARE.  GHDL only.  Nothing here opens a device, a cable or Vivado.
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it executes, so an
# edit under a running instance resumes it mid-token.  Same guard, and the
# same reason, as sim/mutate_llama_top_land.sh and sim/regress.sh:287.
if [ -z "${MUTNU_REPO:-}" ]; then
  MUTNU_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUTNU_REPO
fi
if [ -z "${MUTNU_SELF:-}" ] && [ -z "${MUTNU_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutnu-self.XXXXXXXX.sh)" || exit 2
  cat "${BASH_SOURCE[0]}" > "$_self" || { rm -f "$_self"; exit 2; }
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "mutate_llama_top_normuram.sh: the private copy does not parse -- it" >&2
    echo "  was probably being written as it was copied.  Try again." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUTNU_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi
trap 'rm -f "${MUTNU_SELF:-}"' EXIT

cd "$MUTNU_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"

# Read the source closure from the one file that owns it, for the reason that
# file states: two copies of a file list is how a row goes stale against a
# design nobody changed.
FILES=$(sed -n '/^FILES="/,/"$/p' sim/mutate_llama_top_kv.sh | sed 's/FILES="//; s/"$//')
[ -n "$FILES" ] || { echo "could not read FILES from sim/mutate_llama_top_kv.sh"; exit 2; }

# THE CONFIGURATION, spelled exactly as sim/tb_llama_top_normw.vhd spells it,
# so a kill here is a kill at the gate row.  This is the ONLY wrapper in the
# tree that populates NORM_W_IMAGE, hence the only one that elaborates `gwm`
# at all; every other tb_llama_top row runs `gwc` and is blind to this file.
G_NORMW="-gBLOCKS=4 -gATTN_INT=4 -gNRUNS=2 -gC_REAL=true -gATTN_HD=16
         -gNORM_REAL=true -gNORM_ANCHOR=false
         -gW_IMAGE=llama_top_w_b4_pool.hex
         -gNORM_W_IMAGE=llama_top_nw_b4_mean.hex"

# MEASURED 2026-08-29 by TRACK NORMW at commit 35e0ed0, and re-MEASURED
# unchanged by this track after the store moved.  Duplicated from the wrapper
# deliberately: a row that read them out of the wrapper would move with the
# wrapper and could never notice a wrapper that had been widened.
LAND_NORMW="-gEXP_X0=-16350 -gEXP_XSUM=90889 -gEXP_XALL=90889 -gEXP_STEPH=18618"
STOP=900ms

# ---------------------------------------------------------------------------
# mut <tag> -- start a mutant tree for rtl/llama_top.vhd; prints the dir.
# sub <dir> <old> <new> <count>  -- REQUIRED occurrence count, in place.
# ---------------------------------------------------------------------------
# The count is not decoration.  An anchor that matches a different number of
# sites than intended yields a design that is neither correct nor the defect,
# and a kill on that says nothing.
mut() {
  local tag="$1"
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  cp rtl/llama_top.vhd "$dir/llama_top.vhd" || return 1
  echo "$dir"
}
sub() {
  local dir="$1" old="$2" new="$3" want="$4"
  python3 - "$dir/llama_top.vhd" "$old" "$new" "$want" <<'PY'
import sys
p, old, new, want = sys.argv[1:5]
s = open(p).read(); n = s.count(old)
if n != int(want):
    sys.stderr.write("ANCHOR MATCHED %d TIMES, REQUIRED %s:\n  %r\n"
                     % (n, want, old[:70]))
    sys.exit(2)
open(p, "w").write(s.replace(old, new))
PY
}

# ---------------------------------------------------------------------------
# row <tag> <desc> <mutdir|"">
# ---------------------------------------------------------------------------
# THREE-WAY VERDICT.  A run that DIED printed no RESULT line, and folding that
# into KILLED credits the landmarks with a detection the SIMULATOR made.  This
# matters more here than usual: several rows below can trip the RTL's own
# `wbusy` assertion, which is a `severity failure` and aborts -- that is a
# KILL by the assertion, not by the value gate, and the two are reported apart.
row() {
  local tag="$1" desc="$2" mutdir="$3"
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir/run"
  local f src
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)  -- $desc"
      sed -n 1,4p "$dir/analyze.log"; return
    fi
  done
  ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex"  "$dir/run/" 2>/dev/null
  ln -sfn "$PWD/sim/llama_top_nw_b4_mean.hex" "$dir/run/" 2>/dev/null
  ( cd "$dir/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed \
      --workdir=.. tb_llama_top $G_NORMW $LAND_NORMW --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  if grep -aq "tb_llama_top RESULT: PASS" "$dir/run/run.log"; then
    echo "$tag  SURVIVED   -- $desc"
  elif grep -aq "gain load was" "$dir/run/run.log"; then
    echo "$tag  KILLED(wbusy ASSERTION, not the landmarks) -- $desc"
  elif ! grep -aq "tb_llama_top RESULT" "$dir/run/run.log"; then
    echo "$tag  KILLED(ABORT) -- no RESULT line: the SIMULATOR noticed, not the gate -- $desc"
  else
    echo "$tag  KILLED(landmarks) -- $desc"
  fi
  grep -a "P14 --" "$dir/run/run.log" | grep -av "NO VALUE GATE" \
    | head -4 | sed 's/^/        /' | cut -c1-190
  grep -a "P14 landmarks measured" "$dir/run/run.log" \
    | head -1 | sed 's/^/        /' | cut -c1-190
}

echo "=== teeth for the norm-gain store (rtl/llama_top.vhd, gwm) ==="
echo "scratch: $SCRATCH"
echo

echo "--- U0: the control.  A matrix whose control fails measures nothing. ---"
row U0 "CONTROL: clean tree, tb_llama_top_normw's exact generics and landmarks" ""

echo
echo "--- U1-U5: the reshape's own failure modes ---"

D=$(mut U1) && sub "$D" \
  "            wrd <= nwrom(nidx*NWORD + wptr);" \
  "            wrd <= nwrom(nidx*NWORD + ((wptr+1) mod NWORD));" 1 \
  && row U1 "ROTATED BY ONE WORD: the gain vector is cyclically shifted by GW elements" "$D"

D=$(mut U2) && sub "$D" \
  "              r(k*NWORD + w) := NW_TBL(k)((w+1)*WW-1 downto w*WW);" \
  "              r(k*NWORD + w) := NW_TBL(k)(w*WW+MANT_W-1 downto w*WW)
                                 & NW_TBL(k)((w+1)*WW-1 downto w*WW+MANT_W);" 1 \
  && row U2 "THE m7 HAZARD, packer half: elements rotated INSIDE the GW-element word" "$D"

D=$(mut U3) && sub "$D" \
  "              wreg <= wrd & wreg(NN*MANT_W-1 downto WW);" \
  "              wreg <= wreg(NN*MANT_W-WW-1 downto 0) & wrd;" 1 \
  && row U3 "THE m7 HAZARD, unpacker half: the shift runs the other way, so the WORDS land reversed" "$D"

D=$(mut U4) && sub "$D" \
  "            wrd <= nwrom(nidx*NWORD + wptr);" \
  "            wrd <= nwrom(wptr);" 1 \
  && row U4 "NORM OP IGNORED: every norm op is served norm op 0's gain" "$D"

D=$(mut U5) && sub "$D" \
  "            if rst = '1' or go = '1' or (dn = '1' and v_ack(vi) = '1') then" \
  "            if rst = '1' or go = '1' then" 1 \
  && row U5 "THE LOAD NEVER RESTARTS: correct at norm op 0, stale for every op after it" "$D"

echo
echo "--- U6/U6x: the CYCLE BUDGET, and the attribution control for wbusy ---"
# U6 makes the load eight times slower than the budget allows.  U6x is the
# SAME mutant with the wbusy assertion neutralised, and it is the only row
# that can say whether that assertion earns its maintenance: if U6x still
# kills, the landmarks would have caught the budget failure on their own.
mk_u6 () {
  local d n
  d=$(mut "$1") || return 1
  n="$2"
  sub "$d" \
    "        signal wbusy : std_logic := '1';" \
    "        signal wbusy : std_logic := '1';
        signal wstl  : natural range 0 to $n := 0;" 1 || return 1
  sub "$d" \
    "            wdv <= wav;" \
    "            if wstl = $n then wdv <= wav; else wdv <= '0'; end if;
            if wstl = $n then wstl <= 0; else wstl <= wstl + 1; end if;" 1 \
    || return 1
  sub "$d" \
    "            elsif wav = '1' then
              if wptr = NWORD-1 then" \
    "            elsif wav = '1' and wstl = $n then
              if wptr = NWORD-1 then" 1 || return 1
  echo "$d"
}
# U6 is a MARGIN failure and NOT a wrong number: 8x slower is 129 cycles
# against the ~68 the budget allows, so `wbusy` is still high at `r_go` --
# but rmsnorm_rs's pass 2 is later still, so the gain is resident by the time
# it is actually read.  U6b is 64x, which is late enough to be read half
# shifted.  The pair is the whole point: the assertion is a MARGIN check and
# the landmarks are a VALUE check, and they see different faults.
D=$(mk_u6 U6 7) \
  && row U6 "MARGIN GONE: one word every 8 cycles, so the load outlasts S_RD" "$D"
D=$(mk_u6 U6x 7) && sub "$D" \
  "            assert not (r_go = '1' and wbusy = '1')" \
  "            assert true" 1 \
  && row U6x "ATTRIBUTION CONTROL: the SAME margin failure with the wbusy assertion disabled" "$D"
D=$(mk_u6 U6b 63) \
  && row U6b "BUDGET BLOWN OUTRIGHT: one word every 64 cycles, so the gain is read half shifted" "$D"
D=$(mk_u6 U6bx 63) && sub "$D" \
  "            assert not (r_go = '1' and wbusy = '1')" \
  "            assert true" 1 \
  && row U6bx "ATTRIBUTION CONTROL: the SAME outright failure with the wbusy assertion disabled" "$D"

echo
echo "--- U7: expected NOT to bite.  This is the resolution floor. ---"
D=$(mut U7) && sub "$D" \
  "          if n mod 4 = 0 then return 4; else return 1; end if;" \
  "          return 1;" 1 \
  && row U7 "GW forced to 1, so the reshape is one element per word: the VALUES are unchanged and this MUST survive" "$D"
