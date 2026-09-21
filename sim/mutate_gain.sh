#!/usr/bin/env bash
# sim/mutate_gain.sh -- TRACK GAINTEETH, 2026-09-20.
#
# TEETH FOR THE NORM-GAIN CODEBOOK: `rtl/llama_top.vhd`'s `gvr` generate, the
# pair TRACK GAIN16 (`c094867`) put there -- an INDEX ROM `ixrom` plus a VALUE
# CODEBOOK `cbrom` -- which had NO mutation coverage anywhere in the tree.
#
# WHICH CODEBOOK THIS IS, BECAUSE THERE ARE TWO AND THEY ARE NOT RELATED.
#
#   THIS one      rtl/llama_top.vhd, inside `gvr : if NORM_REAL and
#                 vi = V_NORM generate`.  An ELABORATION-TIME constant pair
#                 built from the `NORM_W_IMAGE` generic: `ixrom` is
#                 NW_N*NWORD x IXW with `rom_style = "block"`, `cbrom` is
#                 NCB x MANT_W with `rom_style = "distributed"`.  NO PORTS AT
#                 ALL -- nothing writes it at run time.  At the 9B shape
#                 IXW = 11 and NCB = 1,567; at this bench's shape NCB = 406
#                 and IXW = 9.
#
#   SUBSYSTEM A's rtl/matvec_core.vhd, the IQ4_NL codebook: 16 entries of
#                 int8, addressed by a 4-bit weight nibble, and RUNTIME
#                 LOADABLE through the ports `cb_we`/`cb_addr`/`cb_data`.
#                 It already has teeth -- `sim/mutate_matvec_cb.sh` and
#                 `sim/mutate_matvec_core.sh`'s class CB -- and it belongs to
#                 another track.  NOTHING HERE TOUCHES IT.
#
# The discriminators are the PORTS (A's has three, this has none), the index
# width (4 fixed against IXW derived from the image), the table size (16
# against NCB) and the writer (a descriptor at run time against VHDL
# elaboration).  Two things called "the codebook" in one tree is how a track
# ends up testing the wrong one, so they are named by file and by port here
# rather than by the word.
#
# ---------------------------------------------------------------------------
# WHY A ROUND TRIP IS NOT THE TEST, AND WHAT IS
# ---------------------------------------------------------------------------
# The obvious check on a packer/unpacker pair is `decode(encode(v)) = v`.
# CLAUDE.md's recorded `m7 mutant` is exactly a pair that passed an entire
# self-test suite while being wrong, because self-consistency is preserved by
# any mirror-image error.  Here the mirror is built on purpose: `CBMAP` and
# `cb_rom` are derived from ONE source, `NORM_W_IMAGE`, at elaboration, and
# the RTL's own comment argues from that that they cannot drift.
#
# Row G2 MEASURES that argument rather than repeating it: it relabels BOTH
# halves consistently and the design is unchanged.  Row G1 breaks the mirror
# on one side only.  And rows G3, G4, G7 and G9 are the faults a round trip
# over the codec CANNOT see at all, because the codec is fine and the
# COMPOSITION is wrong -- the wrong element is packed, the wrong value is
# marked, the wrong norm op is addressed.
#
# THE ORACLE IS `tools/norm_w_bisect.py`, and it is independent in both
# halves: the arithmetic is transcribed from `ref/rmsnorm_bf_vec.c` via
# `tools/ref9b/vec_oracle.norm_bf`, and the GAIN is read from the image file
# by its own reader.  It compares the machine's `R_XN` seams BIT FOR BIT
# against `rmsnorm_bf(machine's own R_X, machine's own x_exp, the image's
# gain)`.  It is shown to discriminate on the gain by `--also-ramp`, which
# repeats the comparison with the old synthetic ramp: MEASURED 2026-09-20 on
# the clean tree, 9 of 9 seams match the image and 0 of 9 match the ramp.
#
# ---------------------------------------------------------------------------
# THE ATTRIBUTION CONTROL IS AN ABLATION, NOT A CLASSIFICATION
# ---------------------------------------------------------------------------
# Every row is run TWICE against the SAME mutant:
#
#   struct   `tb_llama_top` with the four P14 landmarks UNSET.  This is the
#            pre-existing STRUCTURAL gate alone -- schedule, descriptor-latency
#            skew, degenerate residuals, token positions.
#   land     the same design with the gate row's landmarks pinned exactly as
#            `sim/tb_llama_top_normw.vhd` pins them.  The difference between
#            this column and `struct` is what the landmark earns.
#
# and the ORACLE column is computed from the `struct` run's capture, so a
# kill that appears only there is a kill no part of the existing bench makes.
# Reporting "which check spoke first" from one run would be cheaper and is
# what TRACK REANCHOR listed under "open, not determined"; two runs settle it.
#
# G1R IS THE ROW THAT SAYS WHAT A LANDMARK IS WORTH.  It re-runs G1's mutant
# with the landmarks RE-PINNED to the values that mutant itself printed --
# which is what anyone would have done had the codebook been wrong on the day
# it landed.  The bench then PASSES and the oracle still fails.  A landmark is
# a change detector; it cannot say the design was ever right.
#
# ROWS THAT DO NOT BITE ARE REPORTED UNDER THEIR OWN NAMES and are the most
# valuable lines here: G2, G3 and G6 measure the resolution floor of this
# whole table.
#
# Usage:  bash sim/mutate_gain.sh
# Env:    SCRATCH=<dir>    ONLY="<tag> <tag> ..."   (EXACT tags, space sep)
#
# NO HARDWARE.  GHDL (mcode) only.  Nothing here opens a device or Vivado.
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it executes, so an
# edit under a running instance resumes it mid-token.  Same guard and the same
# reason as sim/mutate_rmswire.sh and sim/regress.sh:287.  The private copy
# goes in SCRATCH when the caller named one, so that on this project's boxes
# it lands on /mnt/storage and not under /tmp, which gets cleaned.
if [ -z "${MUTG_REPO:-}" ]; then
  MUTG_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUTG_REPO
fi
if [ -z "${MUTG_SELF:-}" ] && [ -z "${MUTG_NO_REEXEC:-}" ]; then
  _sd="${SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$_sd" || exit 2
  _self="$(mktemp "$_sd/mutgain-self.XXXXXXXX.sh")" || exit 2
  cat "${BASH_SOURCE[0]}" > "$_self" || { rm -f "$_self"; exit 2; }
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "mutate_gain.sh: the private copy does not parse -- it was probably" >&2
    echo "  being written as it was copied.  Try again." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUTG_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi

# THE PRIVATE COPY IS NOT DELETED ON EXIT, DELIBERATELY.  The obvious
# `trap 'rm -f "$MUTG_SELF"' EXIT` puts a shell variable in an `rm` path,
# which this project forbids outright after an agent was caught doing it ten
# times and getting away with it because the variable happened to be set on
# the same line each time.  The copy is a few kilobytes in the scratch
# directory and is named `mutgain-self.*`; delete it by hand if it bothers
# you.  NOTHING IN THIS SCRIPT DELETES ANYTHING: every working directory is
# created fresh under a per-run root instead (see RUNDIR below), so a rerun
# never needs to clear a path built from a variable.

cd "$MUTG_REPO" || exit 2
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH" || exit 2
RUNDIR="$SCRATCH/run-$$-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUNDIR" || exit 2

# The source closure, read from the one file that owns it, for the reason that
# file states: two copies of a file list is how a row goes stale against a
# design nobody changed.  Same import sim/mutate_rmswire.sh makes.
FILES=$(sed -n '/^FILES="/,/"$/p' sim/mutate_llama_top_kv.sh | sed 's/FILES="//; s/"$//')
[ -n "$FILES" ] || { echo "could not read FILES from sim/mutate_llama_top_kv.sh"; exit 2; }

# Spelled as sim/tb_llama_top_normw.vhd spells it -- the only wrapper that
# populates NORM_W_IMAGE and therefore the only gate row that elaborates the
# codebook at all -- except that CAPTURE is added (the wrapper cannot pass it)
# and the landmarks are separated out so they can be ablated.
G_BASE="-gBLOCKS=4 -gATTN_INT=4 -gNRUNS=2 -gC_REAL=true -gATTN_HD=16
        -gNORM_REAL=true -gNORM_ANCHOR=false
        -gW_IMAGE=llama_top_w_b4_pool.hex
        -gNORM_W_IMAGE=llama_top_nw_b4_mean.hex"
G_LAND="-gEXP_X0=-16350 -gEXP_XSUM=90889 -gEXP_XALL=90889 -gEXP_STEPH=18618"
STOP=900ms

# ---------------------------------------------------------------------------
# THE VANISHED-ROW LEDGER.  Inherited from sim/mutate_rmswire.sh, which
# inherited the problem: a `D=$(mut X) && sub ... && row X` chain SKIPS the row
# when an anchor count is wrong, and a shorter table reads like a shorter
# table.  Here every failure is recorded BY TAG and the script exits nonzero.
# ---------------------------------------------------------------------------
MG_DEAD="$RUNDIR/.dead_anchors"
: > "$MG_DEAD"
MG_TAG=""
NBAD=0
Z0SEEN=0
Z1SEEN=0

# THE SCOPE, STATED IN CODE.  TRACK REANCHOR MEASURED five dead rows whose
# anchors were never edited: `rtl/llama_top.vhd` grew a second, byte-identical
# copy of a block (`gsr` against `gvr`) distinguished only by the comment above
# it.  Every anchor below is therefore required exactly once BETWEEN two
# generate headers, each of which is itself required exactly once.  The
# codebook lives in `gvr` and TRACK GSRWIDE is editing `gsr` as this is
# written, so the hazard is live and not hypothetical.
GVR_B="    gvr : if NORM_REAL and vi = V_NORM generate"
GVR_E="    gsr : if SWG_REAL and vi = V_SWG generate"

mut() {                       # mut <tag> -> prints the mutant source dir
  # TWO `local` STATEMENTS, NOT ONE, AND THIS COST A RUN.  Written as
  # `local tag="$1" dir="$RUNDIR/${tag}_src"`, bash declares BOTH names local
  # before evaluating either right-hand side, so `${tag}` in the second is the
  # NEW empty local and `set -u` aborts the function.  MEASURED 2026-09-20:
  # every mutant directory was `/llama_top.vhd`, every row reported BADMUT --
  # and Z0, whose REQUIRED verdict is BADMUT, reported it for a reason that
  # had nothing to do with its anchor.  A self-teeth row passing for the wrong
  # reason is the failure class this project already has four instances of.
  local tag="$1"
  local dir="$RUNDIR/${tag}_src"
  mkdir -p "$dir" || return 1
  cp rtl/llama_top.vhd "$dir/llama_top.vhd" || return 1
  echo "$dir"
}

# sub_scope <dir> <old> <new> <required-count-inside-the-scope>
sub_scope() {
  local dir="$1" old="$2" new="$3" want="$4"
  MG_WHY="$RUNDIR/.why.${MG_TAG:-unnamed}"
  python3 - "$dir/llama_top.vhd" "$GVR_B" "$GVR_E" "$old" "$new" "$want" 2>> "$MG_WHY" <<'PY'
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
  # THE DIAGNOSTIC IS KEPT PER TAG, and that is not tidiness.  MEASURED
  # 2026-09-20: Z0 reported the BADMUT its legend REQUIRES while the real
  # cause was a missing mutant directory and not its impossible anchor.
  # The mutator's stderr is the only thing that tells those apart, and on
  # a terminal it is detached from the row it belongs to.
  if [ -s "$MG_WHY" ]; then cat "$MG_WHY" >&2; fi
  [ $rc -ne 0 ] && echo "${MG_TAG:-<unnamed>}" >> "$MG_DEAD"
  return $rc
}

# run_one <mutdir|""> <workdir> <extra generics> <capture 0|1>
# Prints ONE word.  Leaves run.log (and cap.txt) in <workdir>/run.
run_one() {
  local mutdir="$1" dir="$2" extra="$3" cap="$4" f src capg=""
  mkdir -p "$dir/run" || { echo "NOBUILD"; return; }
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "NOBUILD"; return
    fi
  done
  ln -sfn "$MUTG_REPO/sim/llama_top_w_b4_pool.hex"  "$dir/run/" 2>/dev/null
  ln -sfn "$MUTG_REPO/sim/llama_top_nw_b4_mean.hex" "$dir/run/" 2>/dev/null
  [ "$cap" = 1 ] && capg="-gCAPTURE=cap.txt"
  # shellcheck disable=SC2086
  ( cd "$dir/run" && timeout -k 5 1800 ghdl -r --std=08 -frelaxed \
      --workdir=.. tb_llama_top $G_BASE $extra $capg --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  # FOUR-WAY, not two.  A run that DIED printed no RESULT line at all, and
  # folding that into "the landmarks caught it" credits a value gate with a
  # detection the SIMULATOR made.
  if   grep -aq "tb_llama_top RESULT: PASS" "$dir/run/run.log"; then echo "SURVIVES"
  elif ! grep -aq "tb_llama_top RESULT" "$dir/run/run.log";     then echo "K:abort"
  elif grep -aq "of the pinned landmarks moved" "$dir/run/run.log" \
       && ! grep -aq "(0 of the pinned landmarks moved)" "$dir/run/run.log"
                                                              then echo "K:land"
  else echo "K:struct"; fi
}

# oracle <workdir> -> "m/n" over the R_XN seams, or a word saying why not.
oracle() {
  local dir="$1"
  [ -s "$dir/run/cap.txt" ] || { echo "NOCAP"; return; }
  python3 "$MUTG_REPO/tools/norm_w_bisect.py" "$dir/run/cap.txt" \
      --gains "$MUTG_REPO/sim/llama_top_nw_b4_mean.hex" \
      > "$dir/bisect.log" 2>&1
  local o
  o=$(grep -o "^# [0-9]* of [0-9]* R_XN seams match the model" "$dir/bisect.log" \
      | head -1 | awk '{print $2"/"$4}')
  [ -z "$o" ] && o="ERROR"
  echo "$o"
}

selected() {                  # selected <tag>
  [ -z "$ONLY" ] && return 0
  case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

pr() { printf '%-5s %-9s %-9s %-7s %s\n' "$1" "$2" "$3" "$4" "$5"; }

# row <rc-of-the-mutation> <tag> <mutdir> <desc>
#
# A MUTATION THAT DID NOT APPLY MUST NOT LOOK LIKE A SURVIVOR.  BADMUT is
# neither a kill nor a survival: it says the row measured NOTHING.  MEASURED
# by TRACK MUTAUDIT on sim/mutate_normw.sh, whose unread rc let an impossible
# anchor print `bench PASS  R_XN oracle 9/9` -- byte for byte the unmutated
# row.
row() {
  local rc="$1" tag="$2" d="$3" desc="$4"
  selected "$tag" || return 0
  if [ "$rc" -ne 0 ]; then
    pr "$tag" BADMUT BADMUT BADMUT "$desc"
    if [ -s "$RUNDIR/.why.$tag" ]; then
      echo "        WHY: $(head -1 "$RUNDIR/.why.$tag")"
    else
      echo "        WHY: no diagnostic was written -- the mutation never ran."
    fi
    case "$tag" in
      Z0) echo "        Z0 is a SELF-TEETH row: BADMUT here is the REQUIRED outcome."
          Z0SEEN=1 ;;
      Z1) echo "        Z1 is a SELF-TEETH row: BADMUT here is the REQUIRED outcome."
          Z1SEEN=1 ;;
      *)  echo "        the anchor has drifted under rtl/llama_top.vhd; this row tested nothing."
          NBAD=$((NBAD+1)) ;;
    esac
    return 0
  fi
  # AN rc OF 0 IS NOT EVIDENCE THAT A MUTANT EXISTS, AND A MUTANT IS NOT
  # EVIDENCE THAT IT DIFFERS.  Two guards, each with a verdict of its own:
  #   NOMUT   the mutant source is missing -- the copy failed, and every
  #           column below would silently have measured the CLEAN tree.
  #   NOEDIT  the mutant is byte-identical to the clean file, i.e. the
  #           substitution replaced text with itself.  That row is a second
  #           copy of the control wearing another row's name, which is the
  #           no-op row TRACK MUTAUDIT found in mutate_attn_sweep_pipe.
  if [ -n "$d" ]; then
    if [ ! -r "$d/llama_top.vhd" ]; then
      pr "$tag" NOMUT NOMUT NOMUT "$desc"
      echo "        the mutant source was never written; this row tested nothing."
      NBAD=$((NBAD+1)); return 0
    fi
    if cmp -s "$d/llama_top.vhd" rtl/llama_top.vhd; then
      pr "$tag" NOEDIT NOEDIT NOEDIT "$desc"
      echo "        the mutant is byte-identical to the clean file: a no-op row."
      NBAD=$((NBAD+1)); return 0
    fi
  fi
  local s l o
  s=$(run_one "$d" "$RUNDIR/$tag.struct" ""        1)
  o=$(oracle "$RUNDIR/$tag.struct")
  if [ "$s" = NOBUILD ]; then l=NOBUILD; else
    l=$(run_one "$d" "$RUNDIR/$tag.land"   "$G_LAND" 0)
  fi
  pr "$tag" "$s" "$l" "$o" "$desc"
}

echo "=== TRACK GAINTEETH: the norm-gain codebook in rtl/llama_top.vhd gvr ==="
echo "repo:    $MUTG_REPO"
echo "scratch: $RUNDIR"
echo
echo "struct = tb_llama_top with the P14 landmarks UNSET (the structural gate"
echo "         alone).  land = the same mutant with sim/tb_llama_top_normw's"
echo "         landmarks pinned.  oracle = tools/norm_w_bisect.py on the"
echo "         struct run's capture, R_XN seams matching the model / checked."
echo "A kill in the oracle column and nowhere else is a kill the whole"
echo "existing bench misses."
echo
pr TAG struct land oracle WHAT
pr ----- --------- --------- ------- ----

# --- the control ----------------------------------------------------------
MG_TAG=G0; row 0 G0 "" "CONTROL: clean tree.  A table whose control fails measures nothing."

# The oracle's own teeth, on the control's capture.  A comparison that passes
# with EITHER gain is not checking the gain.
if selected G0 && [ -s "$RUNDIR/G0.struct/run/cap.txt" ]; then
  python3 "$MUTG_REPO/tools/norm_w_bisect.py" "$RUNDIR/G0.struct/run/cap.txt" \
      --gains "$MUTG_REPO/sim/llama_top_nw_b4_mean.hex" --also-ramp \
      > "$RUNDIR/G0.ramp.log" 2>&1
  echo "        ORACLE TEETH: $(grep -c 'match the model' "$RUNDIR/G0.ramp.log" >/dev/null && \
        grep -o '# [0-9]* of [0-9]* R_XN seams match the model' "$RUNDIR/G0.ramp.log" | head -1) / $(grep -o '# [0-9]* of [0-9]* R_XN seams match the ramp' "$RUNDIR/G0.ramp.log" | head -1)"
fi

# --- the harness's own teeth, both kinds ----------------------------------
# Z0: an ordinary anchor that cannot match.  Z1: a SCOPE that cannot match.
# The second is not redundant: sub_scope fails in two different places and a
# scope guard that silently fell through would take every row with it.
MG_TAG=Z0; D=$(mut Z0)
sub_scope "$D" "THIS TEXT IS NOT IN THE FILE AND MUST NOT BE PUT IN IT" "x" 1
row $? Z0 "$D" "SELF-TEETH: impossible anchor inside a real scope (MUST be BADMUT)"

MG_TAG=Z1; D=$(mut Z1)
GVR_B_SAVE="$GVR_B"; GVR_B="    gvr : THIS SCOPE HEADER DOES NOT EXIST generate"
sub_scope "$D" "        constant IXW : positive := ixw_of(NCB);" "x" 1
Z1RC=$?; GVR_B="$GVR_B_SAVE"
row $Z1RC Z1 "$D" "SELF-TEETH: impossible SCOPE header, real anchor (MUST be BADMUT)"

# --- the m7 pair: break the mirror, then restore it ------------------------
# G1 reverses the UNPACKER's index convention and leaves the packer alone.
# This is the recorded m7 shape with the two halves drifted apart.
MG_TAG=G1; D=$(mut G1) && sub_scope "$D" \
  "                r(CBMAP(a*256 + b)) := std_logic_vector(to_unsigned(a*256 + b, MANT_W));" \
  "                r(NCB-1-CBMAP(a*256 + b)) := std_logic_vector(to_unsigned(a*256 + b, MANT_W));" 1
row $? G1 "$D" "m7, UNPACKER HALF ONLY: cbrom's index convention reversed against CBMAP's."

# G2 reverses BOTH halves.  EXPECTED TO SURVIVE, and that is the measurement:
# it is the RTL's single-source argument made falsifiable.  A codebook
# relabelling is unobservable at the store's output, so there is nothing about
# the labelling itself for any test to check -- which is exactly why a round
# trip over the codec is not the test.
MG_TAG=G2; D=$(mut G2) && sub_scope "$D" \
  "                r(CBMAP(a*256 + b)) := std_logic_vector(to_unsigned(a*256 + b, MANT_W));" \
  "                r(NCB-1-CBMAP(a*256 + b)) := std_logic_vector(to_unsigned(a*256 + b, MANT_W));" 1 \
  && sub_scope "$D" \
  "                CBMAP(to_integer(unsigned(" \
  "                NCB-1-CBMAP(to_integer(unsigned(" 1
row $? G2 "$D" "m7, BOTH HALVES: the same relabelling applied to packer and unpacker.  EXPECTED TO SURVIVE."

# --- the faults a round trip over the codec cannot see ---------------------
# G3 permutes the elements cb_mark walks.  EXPECTED TO SURVIVE: cb_mark builds
# a SET, and a set is invariant under permutation of the order it is filled
# in.  The row exists to say that out loud -- it is a site that LOOKS like the
# packing-order hazard and provably is not one.
MG_TAG=G3; D=$(mut G3) && sub_scope "$D" \
  "              v := to_integer(unsigned(NW_TBL(k)((i+1)*MANT_W-1 downto i*MANT_W)));" \
  "              v := to_integer(unsigned(NW_TBL(k)((NN-i)*MANT_W-1 downto (NN-1-i)*MANT_W)));" 1
row $? G3 "$D" "cb_mark walks the gain vector element-REVERSED.  EXPECTED TO SURVIVE: it builds a set."

# G4 is the same reversal where it DOES matter: the index store's packing
# order.  The codec is untouched and `decode(encode(v)) = v` still holds for
# every value; the STORE holds the wrong element at every address.
MG_TAG=G4; D=$(mut G4) && sub_scope "$D" \
  "                  NW_TBL(k)((w+1)*MANT_W-1 downto w*MANT_W)))), IXW));" \
  "                  NW_TBL(k)((NWORD-w)*MANT_W-1 downto (NWORD-1-w)*MANT_W)))), IXW));" 1
row $? G4 "$D" "ixrom_flat packs the gain vector element-REVERSED.  The codec is intact; the composition is not."

# G5 attacks the WIDTH derived from the codebook size.  to_unsigned truncates
# silently at a warning, so indices above 2**(IXW-1) alias onto other entries.
MG_TAG=G5; D=$(mut G5) && sub_scope "$D" \
  "        constant IXW : positive := ixw_of(NCB);" \
  "        constant IXW : positive := ixw_of(NCB) - 1;" 1
row $? G5 "$D" "IXW one bit too narrow: the index truncates and high codewords alias."

# G6 over-counts the codebook.  EXPECTED TO SURVIVE: the extra entries are
# never addressed, so the store is larger and the values identical.  This is
# the resolution floor for anything that reasons from NCB.
MG_TAG=G6; D=$(mut G6) && sub_scope "$D" \
  "              if CBMARK(a*256 + b) then n := n + 1; end if;" \
  "              if CBMARK(a*256 + b) then n := n + 2; end if;" 1
row $? G6 "$D" "cb_count returns 2*NCB: a codebook twice the size it needs.  EXPECTED TO SURVIVE."

# G7 narrows the marked domain to the low byte.  Most distinct values are no
# longer marked, CBMAP returns 0 for them, and the store collapses.
MG_TAG=G7; D=$(mut G7) && sub_scope "$D" \
  "              r(v) := true;" \
  "              r(v mod 256) := true;" 1
row $? G7 "$D" "cb_mark marks v mod 256: the codebook loses most of its values and CBMAP collides on 0."

# G8 is the read port itself: the decode ignores the index it was handed.
MG_TAG=G8; D=$(mut G8) && sub_scope "$D" \
  "          nw_wd <= cbrom(to_integer(unsigned(wix)));" \
  "          nw_wd <= cbrom(0);" 1
row $? G8 "$D" "the codebook lookup ignores wix: every element decodes to codeword 0."

# G9 CARRIES sim/mutate_normw.sh's M3, whose anchor `wsel <= NW_TBL(nidx);`
# was deleted by 47c9d9c (TRACK RMSWIRE) and which has reported BADMUT ever
# since.  Its property -- "every norm op uses gain 0, the index is ignored" --
# now lives in the index store's ADDRESS, which is where `nidx` entered the
# gain path when `wsel` left it.
MG_TAG=G9; D=$(mut G9) && sub_scope "$D" \
  "            wix   <= ixrom(nidx*NWORD + (wel / GW));" \
  "            wix   <= ixrom(0*NWORD + (wel / GW));" 1
row $? G9 "$D" "every norm op reads gain 0 (nidx ignored).  Carries sim/mutate_normw.sh's dead M3."

# --- what a landmark is worth ---------------------------------------------
# G1R re-runs G1's mutant with the landmarks RE-PINNED to the numbers that
# mutant itself printed.  That is what would have happened had the codebook
# been wrong on the day it landed: the landmarks would have been measured
# against the wrong design and pinned to it.
if selected G1R; then
  D="$RUNDIR/G1_src"
  if [ -r "$D/llama_top.vhd" ] && [ -r "$RUNDIR/G1.struct/run/run.log" ]; then
    NEWLAND=$(grep -ao "P14 landmarks measured -- .*" "$RUNDIR/G1.struct/run/run.log" \
      | head -1 \
      | sed 's/.*EXP_X0 => \([-0-9]*\).*EXP_XSUM => \([-0-9]*\).*EXP_XALL => \([-0-9]*\).*EXP_STEPH => \([-0-9]*\).*/-gEXP_X0=\1 -gEXP_XSUM=\2 -gEXP_XALL=\3 -gEXP_STEPH=\4/')
    case "$NEWLAND" in
      -gEXP_X0=*)
        l=$(run_one "$D" "$RUNDIR/G1R.land" "$NEWLAND" 0)
        o=$(oracle "$RUNDIR/G1.struct")
        pr G1R "(G1)" "$l" "$o" "G1's mutant with the landmarks RE-PINNED to its own output: $NEWLAND"
        echo "        A landmark is a change detector, not an oracle: re-pinning makes"
        echo "        the gate green over a design the oracle still refuses." ;;
      *) pr G1R "(G1)" NOLAND - "could not read G1's own landmarks from its run.log" ;;
    esac
  else
    pr G1R "(G1)" SKIPPED - "G1 did not run, so there is nothing to re-pin"
  fi
fi

echo
if [ -s "$MG_DEAD" ]; then
  echo "=== ROWS WHOSE ANCHOR DID NOT MATCH: $(wc -l < "$MG_DEAD") ================="
  echo "    Z0 and Z1 are SUPPOSED to be here.  Any other tag is a row that"
  echo "    measured NOTHING: it is not a survivor and not a kill, and the"
  echo "    table above is short by that many rows."
  sed 's/^/      /' "$MG_DEAD"
else
  echo "=== every anchor matched ==="
fi

RC=0
if [ -z "$ONLY" ] || selected Z0; then
  if [ "$Z0SEEN" -ne 1 ]; then
    echo "Z0 SELF-TEETH DID NOT FIRE: an anchor matching nothing is"
    echo "  indistinguishable here from a mutation the checks tolerate."
    RC=1
  fi
fi
if [ -z "$ONLY" ] || selected Z1; then
  if [ "$Z1SEEN" -ne 1 ]; then
    echo "Z1 SELF-TEETH DID NOT FIRE: the SCOPE guard fell through, so every"
    echo "  scoped anchor in this table is unverified."
    RC=1
  fi
fi
if [ "$NBAD" -ne 0 ]; then
  echo "$NBAD row(s) BADMUT: their anchors have drifted and they tested nothing."
  RC=1
fi
echo "scratch kept at $RUNDIR"
exit $RC
