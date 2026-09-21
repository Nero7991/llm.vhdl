#!/usr/bin/env bash
# sim/mutate_rmswire.sh -- TRACK RMSWIRE, 2026-08-30.
#
# TEETH FOR THE COMPOSED NORM PATH: `rtl/llama_top.vhd`'s `gvr` block after
# `rmsnorm_rs_mem` replaced `rmsnorm_rs`, plus the `w_active` tap the unit
# grew to make the composition checkable at all.
#
# WHAT CHANGED AND THEREFORE WHAT HAS TO BE RE-EARNED.  Three whole-vector
# ports became word streams:
#   x    written by the read pass, one word per cycle       (new address path)
#   w    written by the gain loader, one word per cycle     (new RATE, and a
#                                                            new race)
#   o    read back one word per cycle, ONE EDGE LATE        (new pipeline)
# Every one of those is a place a packer/unpacker pair can be wrong in
# mirror-image ways and agree with itself -- this project's recorded `m7
# mutant`.  Rows R4 to R8 are those faults, one per stream.
#
# THE ATTRIBUTION COLUMNS, AND WHY THERE ARE THREE.  A kill does not settle
# which check earned it.  Measured across five tracks on 2026-08-30 this
# changed the claim three times, including a check credited with four kills
# that earned zero.  So every row is run three ways:
#
#   FULL     everything on.
#   noWACT   this track's NEW assertion (`wact_chk`, which watches the unit's
#            `w_active` tap against `wbusy`) neutralised.
#   noASRT   that AND TRACK NORMURAM's pre-existing `wbusy`-at-`r_go`
#            assertion neutralised, leaving ONLY the token landmarks
#            `sim/tb_llama_top_normw` has always had.
#   onlyWA   the MIRROR of noWACT: NORMURAM's assertion neutralised and
#            `wact_chk` KEPT.  Without this column `wact_chk` can never be
#            shown to discriminate at all, because it is checked LATER than
#            NORMURAM's and the four-way verdict reports whichever fired
#            first.  MEASURED consequence, stated in this track's write-up:
#            `wbusy` only ever CLEARS within an operation, so `wbusy = 1` at
#            S_RAW implies `wbusy = 1` at `r_go` -- `wact_chk` cannot fire
#            where NORMURAM's does not, and today it earns NO kill of its
#            own.  It is kept because it is the only check written on the
#            REAL deadline, so it is what survives if the S_GO gate is ever
#            relaxed to reclaim the 1 + 1/LANES margin.
#
# A kill that survives into noASRT belongs to the landmarks and this track
# earns nothing for it.  A kill present in noWACT but not noASRT belongs to
# NORMURAM's assertion.  Only a kill that vanishes at noWACT is `wact_chk`'s.
#
# ROWS THAT DO NOT BITE ARE REPORTED UNDER THEIR OWN NAMES.  R1, R2 and R11
# are expected to survive and are the most useful lines here: R1 and R2 are
# how the S_GO gate is shown to be a STRUCTURAL guarantee rather than a
# cycle-count coincidence, and R11 is the resolution floor.
#
# Usage:  bash sim/mutate_rmswire.sh
# Env:    SCRATCH=<dir>   ONLY="<tag> <tag> ..."   (EXACT tags, space sep)
#
# NO HARDWARE.  GHDL only.  Nothing here opens a device, a cable or Vivado.
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it executes, so an
# edit under a running instance resumes it mid-token.  Same guard and the same
# reason as sim/mutate_llama_top_normuram.sh and sim/regress.sh:287.
if [ -z "${MUTRW_REPO:-}" ]; then
  MUTRW_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUTRW_REPO
fi
if [ -z "${MUTRW_SELF:-}" ] && [ -z "${MUTRW_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutrw-self.XXXXXXXX.sh)" || exit 2
  cat "${BASH_SOURCE[0]}" > "$_self" || { rm -f "$_self"; exit 2; }
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "mutate_rmswire.sh: the private copy does not parse -- it was" >&2
    echo "  probably being written as it was copied.  Try again." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUTRW_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi
trap 'rm -f "${MUTRW_SELF:-}"' EXIT

cd "$MUTRW_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"

# ---------------------------------------------------------------------------
# THE VANISHED-ROW LEDGER.  TRACK REANCHOR, 2026-09-20.
# ---------------------------------------------------------------------------
# A top-level `D=$(mut Rn) && sub "$D" ... && row Rn ...` chain SKIPS the row
# when the anchor count is wrong.  That is safe -- no false SURVIVES is
# printed -- and it is silent: the row VANISHES and a shorter table reads
# like a shorter table.  MEASURED 2026-09-20: R4, R7, R8 and R11 had been
# absent for up to twenty-one days and nothing said so.
#
# `sub` is also called from INSIDE `row()` to build the attribution columns,
# and those failures already show as `ANCHOR` in the table, so they are not
# recorded twice: `RW_INROW` marks that context.
RW_DEAD="$SCRATCH/.dead_anchors"
: > "$RW_DEAD"
RW_INROW=""
RW_TAG=""

# The source closure, read from the one file that owns it, for the reason that
# file states: two copies of a file list is how a row goes stale against a
# design nobody changed.
FILES=$(sed -n '/^FILES="/,/"$/p' sim/mutate_llama_top_kv.sh | sed 's/FILES="//; s/"$//')
[ -n "$FILES" ] || { echo "could not read FILES from sim/mutate_llama_top_kv.sh"; exit 2; }

# Spelled exactly as sim/tb_llama_top_normw.vhd spells it, so a kill here is a
# kill at the gate row.  It is the ONLY wrapper that populates NORM_W_IMAGE
# and therefore the only one that elaborates the gain loader at all.
G_NORMW="-gBLOCKS=4 -gATTN_INT=4 -gNRUNS=2 -gC_REAL=true -gATTN_HD=16
         -gNORM_REAL=true -gNORM_ANCHOR=false
         -gW_IMAGE=llama_top_w_b4_pool.hex
         -gNORM_W_IMAGE=llama_top_nw_b4_mean.hex"
LAND_NORMW="-gEXP_X0=-16350 -gEXP_XSUM=90889 -gEXP_XALL=90889 -gEXP_STEPH=18618"
STOP=900ms

# The two assertion neutralisers, applied on top of a mutant to make the
# attribution columns.  Both are `assert true`, not a deletion, so the line
# count and everything around them is untouched.
A_WACT="          assert not (rst = '0' and r_wact = '1' and wbusy = '1')"
A_LOAD="            assert not (r_go = '1' and wbusy = '1')"

mut() {
  local tag="$1"
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  cp rtl/llama_top.vhd "$dir/llama_top.vhd" || return 1
  echo "$dir"
}

# sub <dir> <old> <new> <required-count>.  The count is not decoration: an
# anchor matching a different number of sites than intended yields a design
# that is neither correct nor the defect, and a kill on that says nothing.
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
  local rc=$?
  if [ $rc -ne 0 ] && [ -z "$RW_INROW" ]; then
    echo "${RW_TAG:-<unnamed>}" >> "$RW_DEAD"
  fi
  return $rc
}

# sub_scope <dir> <scope_begin> <scope_end> <old> <new> <required-count>
#
# WHY A SCOPE AND NOT A LONGER ANCHOR.  TRACK REANCHOR, 2026-09-20.
# `rtl/llama_top.vhd` carries TWO textually IDENTICAL write-back state
# machines: `gvr`'s (the NORM_REAL adapter, which every row here is about)
# and `gsr`'s (the SWG_REAL adapter, added later).  At git HEAD they differ
# only in the COMMENT above them, so `if rav_d = '1' then` matches TWICE and
# `uw_addr(NUNIT+vi) <= kw;` matches twice, which is why R7 and R8 both went
# dead without either of them being touched.
#
# Anchoring on the distinguishing COMMENT would work today and is the
# mistake this project has recorded twice (a presence guard satisfied by a
# comment; a count guard inflated by a comment).  So the disambiguation is a
# SCOPE stated in CODE: two generate headers, each required exactly once,
# with the anchor required <count> times INSIDE them.
GVR_B="    gvr : if NORM_REAL and vi = V_NORM generate"
GVR_E="    gsr : if SWG_REAL and vi = V_SWG generate"
sub_scope() {
  local dir="$1" b="$2" e="$3" old="$4" new="$5" want="$6"
  python3 - "$dir/llama_top.vhd" "$b" "$e" "$old" "$new" "$want" <<'PY'
import sys
p, b, e, old, new, want = sys.argv[1:7]
s = open(p).read()
for name, mark in (("SCOPE BEGIN", b), ("SCOPE END", e)):
    if s.count(mark) != 1:
        sys.stderr.write("%s MATCHED %d TIMES, REQUIRED 1:\n  %r\n"
                         % (name, s.count(mark), mark[:70]))
        sys.exit(2)
i, j = s.index(b), s.index(e)
if not i < j:
    sys.stderr.write("SCOPE END precedes SCOPE BEGIN\n"); sys.exit(2)
mid = s[i:j]
n = mid.count(old)
if n != int(want):
    sys.stderr.write("ANCHOR MATCHED %d TIMES IN SCOPE, REQUIRED %s:\n  %r\n"
                     % (n, want, old[:70]))
    sys.exit(2)
open(p, "w").write(s[:i] + mid.replace(old, new) + s[j:])
PY
  local rc=$?
  if [ $rc -ne 0 ] && [ -z "$RW_INROW" ]; then
    echo "${RW_TAG:-<unnamed>}" >> "$RW_DEAD"
  fi
  return $rc
}

# one_run <srcdir|""> -- returns a one-word verdict on stdout.
one_run() {
  local mutdir="$1" dir="$2" f src
  rm -rf "$dir"; mkdir -p "$dir/run"
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "NOBUILD"; return
    fi
  done
  ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex"  "$dir/run/" 2>/dev/null
  ln -sfn "$PWD/sim/llama_top_nw_b4_mean.hex" "$dir/run/" 2>/dev/null
  ( cd "$dir/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed \
      --workdir=.. tb_llama_top $G_NORMW $LAND_NORMW --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  # FOUR-WAY, not two.  A run that DIED printed no RESULT line, and folding
  # that into "killed by the landmarks" credits the value gate with a
  # detection the SIMULATOR made.  The two assertions are named separately
  # because the whole point of the columns is to tell them apart.
  if   grep -aq "tb_llama_top RESULT: PASS" "$dir/run/run.log"; then echo "SURVIVES"
  elif grep -aq "gain-reading element" "$dir/run/run.log";       then echo "K:wact"
  elif grep -aq "gain load was" "$dir/run/run.log";              then echo "K:loadassert"
  elif ! grep -aq "tb_llama_top RESULT" "$dir/run/run.log";      then echo "K:abort"
  else echo "K:landmarks"; fi
}

row() {
  local tag="$1" desc="$2" mutdir="$3"
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local RW_INROW=1
  local a b c e
  a=$(one_run "$mutdir" "$SCRATCH/$tag.full")
  if [ "$a" = SURVIVES ] || [ "$a" = NOBUILD ]; then
    b="-"; c="-"; e="-"
  else
    # noWACT
    local d2="$SCRATCH/${tag}_noWACT_src"
    rm -rf "$d2"; mkdir -p "$d2"
    cp "${mutdir:-rtl}/llama_top.vhd" "$d2/llama_top.vhd" 2>/dev/null \
      || cp rtl/llama_top.vhd "$d2/llama_top.vhd"
    sub "$d2" "$A_WACT" "          assert true" 1 || { b="ANCHOR"; }
    [ -z "${b:-}" ] && b=$(one_run "$d2" "$SCRATCH/$tag.nowact")
    # noASRT = noWACT plus NORMURAM's assertion
    local d3="$SCRATCH/${tag}_noASRT_src"
    rm -rf "$d3"; mkdir -p "$d3"
    cp "$d2/llama_top.vhd" "$d3/llama_top.vhd"
    sub "$d3" "$A_LOAD" "            assert true" 1 || { c="ANCHOR"; }
    [ -z "${c:-}" ] && c=$(one_run "$d3" "$SCRATCH/$tag.noasrt")
    # onlyWA: the mirror of noWACT.  See the header.
    local d4="$SCRATCH/${tag}_onlyWA_src"
    rm -rf "$d4"; mkdir -p "$d4"
    cp "${mutdir:-rtl}/llama_top.vhd" "$d4/llama_top.vhd" 2>/dev/null \
      || cp rtl/llama_top.vhd "$d4/llama_top.vhd"
    sub "$d4" "$A_LOAD" "            assert true" 1 || { e="ANCHOR"; }
    [ -z "${e:-}" ] && e=$(one_run "$d4" "$SCRATCH/$tag.onlywa")
  fi
  printf '%-6s %-13s %-13s %-13s %-13s %s\n' "$tag" "$a" "$b" "$c" "${e:--}" "$desc"
  unset b c e
}

echo "=== TRACK RMSWIRE teeth: the composed norm path in rtl/llama_top.vhd ==="
echo "scratch: $SCRATCH"
echo
printf '%-6s %-13s %-13s %-13s %-13s %s\n' TAG FULL noWACT noASRT onlyWA WHAT
printf '%-6s %-13s %-13s %-13s %-13s %s\n' ------ ------------- ------------- ------------- ------------- ----

row R0 "CONTROL: clean tree.  A matrix whose control fails measures nothing." ""

# --- the gate, and the two rows that show what it is worth -----------------
RW_TAG=R1; D=$(mut R1) && sub "$D" \
  "                if wbusy = '0' then
                  r_go <= '1';
                  st   := S_RUN;
                end if;" \
  "                r_go <= '1';
                st   := S_RUN;" 1 \
  && row R1 "GATE REMOVED, load at full rate.  EXPECTED TO SURVIVE: the load finishes about 3 cycles before S_GO anyway, which is exactly why a 3-cycle margin is not a design." "$D"

mk_slow () {   # $1 = tag, $2 = divisor-1
  local d n; d=$(mut "$1") || return 1; n="$2"
  sub "$d" \
    "        signal wav   : std_logic := '1';   -- an address is being issued" \
    "        signal wav   : std_logic := '1';   -- an address is being issued
        signal wstl  : natural range 0 to $n := 0;" 1 || return 1
  sub "$d" \
    "            wdv   <= wav;" \
    "            if wstl = $n then wdv <= wav; else wdv <= '0'; end if;
            if wstl = $n then wstl <= 0; else wstl <= wstl + 1; end if;" 1 \
    || return 1
  sub "$d" \
    "            elsif wav = '1' then
              if wel = NN-1 then" \
    "            elsif wav = '1' and wstl = $n then
              if wel = NN-1 then" 1 || return 1
  echo "$d"
}

RW_TAG=R2; D=$(mk_slow R2 3) \
  && row R2 "LOAD 4x SLOWER, gate INTACT.  EXPECTED TO SURVIVE: the gate turns a blown budget into a stall instead of a wrong number.  This is the row that says the gate is structural." "$D"

RW_TAG=R3; D=$(mk_slow R3 3) && sub "$D" \
  "                if wbusy = '0' then
                  r_go <= '1';
                  st   := S_RUN;
                end if;" \
  "                r_go <= '1';
                st   := S_RUN;" 1 \
  && row R3 "LOAD 4x SLOWER AND THE GATE REMOVED.  The composition without its interlock.  Must be killed by something." "$D"

# --- one row per stream: the m7 hazard in each of the three ports ----------
# R4 RETIRED 2026-09-20, TRACK REANCHOR.  THE STRUCTURE IT MUTATED NO LONGER
# EXISTS.  R4 reversed the GW-to-1 sub-word select inside the ROM word.  TRACK
# GWTWO (21db25b) landed GW = 1 -- `gw_pick` now `return 1;` unconditionally --
# so there IS no sub-word, and TRACK GAIN16 (c094867) then replaced the value
# ROM with an index ROM plus a codebook and deleted the mux outright.  The RTL
# says so itself at rtl/llama_top.vhd's `wsubsel`: "THE GW SUB-WORD MUX IS GONE
# WITH THE STORE IT SELECTED FROM", and TRACK GWTWO had already reported under
# its own name that the mirror mutant DOES NOT BITE at GW = 1 because there it
# is a semantic no-op.
#
# The anchor matched ZERO times from c094867 until 2026-09-20 and the row
# VANISHED (it did not lie -- `sub` fails, `&& row` never runs).
#
# WHAT STILL COVERS THE PROPERTY: element ORDER within the w stream is covered
# by R5 (address off by one) and R5b (address reversed), both below, on the
# form that actually ships.  A future GW > 1 must bring this row back with it.

RW_TAG=R5; D=$(mut R5) && sub "$D" \
  "        nw_wa <= std_logic_vector(to_unsigned(wel_d, LOG2N));" \
  "        nw_wa <= std_logic_vector(to_unsigned((wel_d + 1) mod NN, LOG2N));" 1 \
  && row R5 "w STREAM: the bank write address off by one, so the gain is rotated by one element." "$D"

# R5b.  ADDED 2026-09-20, TRACK REANCHOR, to carry the ONE property that
# sim/mutate_llama_top_normuram.sh's retirement would otherwise have dropped.
# That harness's U3 was the m7 hazard's UNPACKER half -- "the shift runs the
# other way, so the WORDS land reversed" -- written against a `wreg` shift
# register that 47c9d9c deleted.  On the form that ships, element order in
# the w stream is the bank WRITE ADDRESS, so a reversal is `NN-1-wel_d`.
#
# IT IS NOT R5 WITH A BIGGER NUMBER.  R5 rotates by one element, which moves
# every element by the same amount; a reversal moves element k by NN-1-2k,
# leaves the middle element alone at odd NN, and is the mutation a packer and
# an unpacker can both make and agree on.  That is the recorded `m7 mutant`
# and it is why U3 existed.
RW_TAG=R5b; D=$(mut R5b) && sub "$D" \
  "        nw_wa <= std_logic_vector(to_unsigned(wel_d, LOG2N));" \
  "        nw_wa <= std_logic_vector(to_unsigned(NN-1-wel_d, LOG2N));" 1 \
  && row R5b "w STREAM, m7 hazard: the bank write address REVERSED, so the gain vector lands back to front.  Inherits sim/mutate_llama_top_normuram.sh's U3." "$D"

RW_TAG=R6; D=$(mut R6) && sub "$D" \
  "                  x_wa <= std_logic_vector(to_unsigned(k-2, LOG2N));" \
  "                  x_wa <= std_logic_vector(to_unsigned((k-1) mod NN, LOG2N));" 1 \
  && row R6 "x STREAM: the read pass writes each element one address high, so the residual stream is rotated going in." "$D"

# RE-ANCHORED 2026-09-20, TRACK REANCHOR.  The anchor was never edited; the
# `gsr` (SWG_REAL) adapter appeared carrying a byte-identical copy of this
# state machine, so the anchor went from 1 match to 2 and `sub`'s count guard
# voided the row.  Scoped to `gvr`, which is what every row here is about.
RW_TAG=R7; D=$(mut R7) && sub_scope "$D" "$GVR_B" "$GVR_E" \
  "                if rav_d = '1' then" \
  "                if rav = '1' then" 1 \
  && row R7 "o STREAM: the write-back consumes the bank output ONE CYCLE EARLY, which is exactly the latency the flat port did not have." "$D"

# RE-ANCHORED 2026-09-20, TRACK REANCHOR: same cause as R7, same fix.
RW_TAG=R8; D=$(mut R8) && sub_scope "$D" "$GVR_B" "$GVR_E" \
  "                  uw_addr(NUNIT+vi) <= kw;" \
  "                  uw_addr(NUNIT+vi) <= (kw + 1) mod NN;" 1 \
  && row R8 "o STREAM: the region write address off by one against the bank read address." "$D"

# --- the loader's own lifecycle, re-earned on the new form -----------------
RW_TAG=R9; D=$(mut R9) && sub "$D" \
  "            if rst = '1' or go = '1' or (dn = '1' and v_ack(vi) = '1') then
              wel   <= 0;" \
  "            if rst = '1' or go = '1' then
              wel   <= 0;" 1 \
  && row R9 "THE LOAD NEVER RESTARTS: correct at norm op 0, stale for every op after it.  TRACK NORMURAM's U5 re-asked of the rewritten loader." "$D"

# R11 RETIRED 2026-09-20, TRACK REANCHOR.  THE MUTATION IS NOW THE IDENTITY.
# R11 forced GW to 1 and was the harness's declared resolution floor: it MUST
# survive because the values do not move.  TRACK GWTWO (21db25b) then made
# GW = 1 the SHIPPING value -- `gw_pick` is `return 1;` -- so the mutation
# substitutes a design for itself.  A row that cannot differ from its baseline
# is not a resolution floor, it is a second copy of the control (R0).
#
# The anchor matched ZERO times from 21db25b until 2026-09-20 and the row
# VANISHED rather than reporting the SURVIVES it would have reported anyway --
# which is the sharper version of the point: a row whose expected verdict is
# SURVIVED is the hardest kind to notice has stopped running.  It is exactly
# the shape of mutate_attn_sweep_pipe's P7, the no-op TRACK MUTAUDIT found.

echo
if [ -s "$RW_DEAD" ]; then
  echo "=== ROWS THAT DID NOT RUN: $(wc -l < "$RW_DEAD") ========================"
  echo "    A zero-match anchor.  These rows are NOT survivors and NOT kills:"
  echo "    they measured NOTHING, and the table above is short by that many"
  echo "    rows.  Re-anchor them against the RTL as it stands, or retire them."
  sed 's/^/      /' "$RW_DEAD"
  RW_RC=1
fi

echo "=== the w_active tap, judged by sim/tb_rmswire_loadrace.vhd ==="
echo "The tap feeds an assertion that never fires in a correct design, so"
echo "tb_llama_top_normw cannot see it break.  The loadrace bench TIMES both"
echo "gain-reading passes off it, so a broken tap moves every boundary it"
echo "derives.  That is the only check with teeth on this pin."
echo
printf '%-6s %-11s %-11s %-11s %s\n' TAG FULL noVAL noEXP WHAT
printf '%-6s %-11s %-11s %-11s %s\n' ------ ----------- ----------- ----------- ----

TAPDEPS="util_pkg fixed_luts_pkg fixed_pkg vec_mem rmsnorm_rs"
tap_run() {   # $1 = rmsnorm_rs_mem.vhd  $2 = generics  $3 = workdir
  local wd="$3"
  rm -rf "$wd"; mkdir -p "$wd"
  ( cd "$wd" || exit 9
    for d in $TAPDEPS; do
      ghdl -a --std=08 --workdir=. "$MUTRW_REPO/rtl/$d.vhd" >/dev/null 2>&1 \
        || exit 9
    done
    ghdl -a --std=08 --workdir=. "$1" >a.log 2>&1 || exit 8
    ghdl -a --std=08 --workdir=. "$MUTRW_REPO/sim/tb_rmswire_loadrace.vhd" \
      >>a.log 2>&1 || exit 8
    # shellcheck disable=SC2086
    ghdl -r --std=08 --workdir=. tb_rmswire_loadrace $2 --stop-time=200ms \
      > r.log 2>&1
  )
  local rc=$?
  if [ $rc -eq 0 ] && grep -aq "tb_rmswire_loadrace: PASS" "$wd/r.log"; then
    echo SURVIVES
  elif [ $rc -eq 8 ] || [ $rc -eq 9 ]; then echo NOBUILD
  else echo KILLED; fi
}

taprow() {
  local tag="$1" desc="$2" f="$3"
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" $tag "*) ;; *) return ;; esac
  fi
  local a b c
  a=$(tap_run "$f" ""                "$SCRATCH/$tag.tap.full")
  if [ "$a" = SURVIVES ] || [ "$a" = NOBUILD ]; then b="-"; c="-"; else
    b=$(tap_run "$f" "-gCHK_VAL=false" "$SCRATCH/$tag.tap.noval")
    c=$(tap_run "$f" "-gCHK_EXP=false" "$SCRATCH/$tag.tap.noexp")
  fi
  printf '%-6s %-11s %-11s %-11s %s\n' "$tag" "$a" "$b" "$c" "$desc"
}

taprow T0 "CONTROL: the clean unit." "$MUTRW_REPO/rtl/rmsnorm_rs_mem.vhd"

sed "s@  w_active <= '1' when (state = S_RAW or state = S_EMIT) else '0';@  w_active <= '1' when (state = S_EMIT) else '0';@" \
    rtl/rmsnorm_rs_mem.vhd > "$SCRATCH/T1.vhd"
cmp -s "$SCRATCH/T1.vhd" rtl/rmsnorm_rs_mem.vhd && echo "T1 NOSUB" || \
  taprow T1 "TAP BLIND TO S_RAW: it reports only the later, slacker pass, so the derived safe boundary becomes about 1,030 cycles too generous." "$SCRATCH/T1.vhd"

sed "s@  w_active <= '1' when (state = S_RAW or state = S_EMIT) else '0';@  w_active <= '1';@" \
    rtl/rmsnorm_rs_mem.vhd > "$SCRATCH/T2.vhd"
cmp -s "$SCRATCH/T2.vhd" rtl/rmsnorm_rs_mem.vhd && echo "T2 NOSUB" || \
  taprow T2 "TAP TIED HIGH: no second rise, so neither pass is timed." "$SCRATCH/T2.vhd"

sed "s@  w_active <= '1' when (state = S_RAW or state = S_EMIT) else '0';@  w_active <= '0';@" \
    rtl/rmsnorm_rs_mem.vhd > "$SCRATCH/T3.vhd"
cmp -s "$SCRATCH/T3.vhd" rtl/rmsnorm_rs_mem.vhd && echo "T3 NOSUB" || \
  taprow T3 "TAP TIED LOW: no rise at all." "$SCRATCH/T3.vhd"

echo
echo "scratch kept at $SCRATCH"
exit ${RW_RC:-0}
