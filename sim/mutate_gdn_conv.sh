#!/usr/bin/env bash
# Mutation test for rtl/gdn_conv.vhd and ref/gdn_conv_vec.c.
#
# WHAT tb_gdn_conv ACTUALLY CHECKS, read out of the file before anything was
# mutated.  This is the STRONGEST of subsystem B's seven uncovered benches and
# the only one of them that gates accuracy itself:
#
#   1. BIT-EXACTNESS against ref/gdn_conv_vec.c -- every channel's sm, plus
#      e_seg, sh_seg and err_seg.  err_seg is checked LOW in the non-err
#      branch, which the file records as a deliberate fix ("a tied-high
#      err_seg was indistinguishable from a correct one").  Reported as
#      "NOT BIT-EXACT" / "gdn_conv is NOT bit-exact in N case(s)".
#   2. A REAL-VALUED check against the double oracle carried in the same
#      vector file, at TOL = 0.75 output LSB, skipped on err cases.  Reported
#      as "OUT OF TOLERANCE vs ORACLE" / "outside oracle tolerance".
#   3. TWO ORDERING PROPERTIES, in ord_chk, both at severity FAILURE: a
#      segment must produce at least one o_valid, and e_seg captured at the
#      first data beat must equal e_seg at o_done (the exponent must be
#      published before the data it describes).
#
# So unlike gdn_silu and gdn_scalar, a BOTH-class mutation here is caught by
# the BENCH, not by a gate this script had to invent.  That is a materially
# better position and it is worth saying which of the seven units are in it.
#
# ---------------------------------------------------------------------------
# THE COMMITTED GOLDEN WAS STALE.  IT IS NOT ANY MORE, AND THE TWO COLUMNS ARE
# WHAT KEEPS IT THAT WAY
# ---------------------------------------------------------------------------
# sim/gdn_conv_vec.txt was committed at c3d2fea.  Commit 9cfdbd2 then changed
# ref/gdn_conv_vec.c -- it added the `c % 7 == 0` wide-cw_exp case class whose
# stated purpose was to make the err_seg path reachable, because "err was 0 in
# all 128 cases ... so an err_seg tied high passed the whole suite".  The
# generator was fixed.  The committed golden was not regenerated for two days.
#
# MEASURED at the time, both directions:
#   $ cmp fresh.txt sim/gdn_conv_vec.txt
#     differ: byte 13, line 2
#   err column, committed:  128 cases with err = 0, none with err = 1
#   err column, fresh:      126 cases with err = 0,    2 with err = 1
#
# sim/regress.sh regenerates a vector file only when it is ABSENT, so for those
# two days the gate ran tb_gdn_conv against the OLD golden and the err_seg-high
# branch was unreachable in it.  R13 below -- deleting the int8 overflow test
# outright -- was caught on FRESH and passed on CMTD, and it was the only
# mutation of the twenty whose two columns disagreed, which is what identified
# the staleness as an err_seg coverage loss rather than general drift.
#
# FIXED 2026-08-29 by TRACK B-FIX: sim/gdn_conv_vec.txt is now the output of
# ref/gdn_conv_vec.c as it stands.  The regeneration moved 19 of 641 lines, all
# of them case headers, all of them at c % 7 == 0, and only the cw_exp, e_seg
# and err fields within them; no x, w, sm or oracle line moved at all, and the
# bench's reported worst-vs-oracle figure is unchanged at 4.99999999998181e-1.
# Cases 56 and 126 now carry err = 1, so the err_seg-high branch is reachable
# from the gate for the first time.
#
# THE TWO COLUMNS ARE KEPT, because they are now the standing staleness check
# rather than a report of one incident:
#   FRESH -- ref/gdn_conv_vec.c regenerated privately, right now.
#   CMTD  -- sim/gdn_conv_vec.txt exactly as committed, which is what
#            sim/regress.sh actually uses.
# For an RTL-class mutation the two columns are directly comparable and ANY
# disagreement means the committed golden has drifted from its generator again.
# All fourteen RTL rows agree as of this commit.  For a C-class or BOTH-class
# mutation the CMTD column is the MUTATED RTL against the UNMUTATED golden, so
# it degenerates to an RTL-only run and a disagreement there is structural, not
# staleness: those rows carry no banner.
#
# Nothing under rtl/, ref/ or sim/tb_*.vhd is edited.  Every mutation is
# applied to a COPY in a private scratch directory, and sim/gdn_conv_vec.txt
# is READ by this script, never rewritten.
#
# Usage: bash sim/mutate_gdn_conv.sh
# Env:   SCRATCH=<dir>
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/gdn_conv.vhd
REF=ref/gdn_conv_vec.c
CMTD=sim/gdn_conv_vec.txt
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

# MEASURED on the unmutated pair, on BOTH vector sets, identically:
#   gdn_conv: bit-exact with the C recipe on all 128 cases;
#   worst vs the double ORACLE 4.99999999998181e-1 LSB      (TOL = 0.75)
# The bench's own TOL is the gate; this script adds none.

NKILL=0; NSURV=0; NTOT=0

# Apply a list of old/new pairs to one file.  An anchor that does not match
# EXACTLY once aborts: a mutation applied zero times is a false survivor and a
# mutation applied twice is not the mutation described.
patch_file() {
  python3 - "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES, expected 1\n" % (i//2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
}

# Read one run log into a two-field verdict.  The bench states three different
# failures three different ways and they mean different things, so they are
# NOT collapsed into one word.
verdict() {
  python3 - "$1" <<'PY'
import sys
t = open(sys.argv[1], errors="replace").read()
prop = ("no o_valid at all" in t) or ("e_seg CHANGED after the first data beat" in t)
bx   = "is NOT bit-exact in" in t or "NOT BIT-EXACT in" in t
tol  = "outside oracle tolerance" in t or "OUT OF TOLERANCE vs ORACLE" in t
done = "bit-exact with the C recipe on all" in t
if prop:
    print("PROP/PROP")            # ordering assertion, severity failure
elif not (bx or tol or done):
    print("DEAD/DEAD")            # ran and reached no verdict at all
else:
    print(("FAIL" if bx else "pass") + "/" + ("FAIL" if tol else "pass"))
PY
}

# A SECOND BENCH, used only for the two mutations tb_gdn_conv cannot see.
# sim/tb_gdn_conv_tvalid_skew.vhd drives tvalid from the REAL
# rtl/gdn_exp_capture.vhd and issues an ordinary prefetching rd_req mid-pass,
# so it moves the config group under a running conv, which tb_gdn_conv never
# does.  Running the same mutant against it is what turns "coverage hole" from
# an argument into a measurement.
skew_check() {
  local tag="$1"
  local dir="$SCRATCH/${tag}_skew"
  rm -rf "$dir"; mkdir -p "$dir"
  ghdl -a --std=08 -frelaxed --workdir="$dir" rtl/gdn_exp_capture.vhd >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" "$SCRATCH/$tag/gdn_conv.vhd" >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_gdn_conv_tvalid_skew.vhd >/dev/null 2>&1
  ( cd "$dir" && timeout 300 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_gdn_conv_tvalid_skew --max-stack-alloc=0 --stop-time=900ms ) \
    >"$dir/run.log" 2>&1
  if grep -q "tb_gdn_conv_tvalid_skew: PASS" "$dir/run.log"; then
    echo "        $tag cross-check vs tb_gdn_conv_tvalid_skew: ALSO SURVIVES -- no bench in this repo covers it"
  else
    echo "        $tag cross-check vs tb_gdn_conv_tvalid_skew: KILLED there --"
    grep -m1 -o "FAIL -- .*" "$dir/run.log" | sed 's/^/           /'
  fi
}

# $1 tag, $2 class, $3 desc, then  --rtl old new ...  --c old new ...
mutate() {
  local tag="$1" cls="$2" desc="$3"; shift 3
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"

  local mode="" rtl_args=() c_args=()
  for a in "$@"; do
    case "$a" in
      --rtl) mode=rtl ;;
      --c)   mode=c ;;
      *) if [ "$mode" = rtl ]; then rtl_args+=("$a"); else c_args+=("$a"); fi ;;
    esac
  done

  if [ ${#rtl_args[@]} -gt 0 ]; then
    patch_file "$RTL" "$dir/gdn_conv.vhd" "${rtl_args[@]}" || {
      echo "$tag  RTL ANCHOR FAILED"; return; }
  else
    cp "$RTL" "$dir/gdn_conv.vhd"
  fi
  if [ ${#c_args[@]} -gt 0 ]; then
    patch_file "$REF" "$dir/gen.c" "${c_args[@]}" || {
      echo "$tag  C ANCHOR FAILED"; return; }
  else
    cp "$REF" "$dir/gen.c"
  fi

  if ! cc -O2 -w -I ref -o "$dir/gen" "$dir/gen.c" -lm 2>"$dir/cc.log"; then
    echo "$tag  DID NOT COMPILE -- a mutation that will not build has tested nothing"
    return
  fi
  ( cd "$dir" && ./gen fresh.txt ) >/dev/null 2>"$dir/gen.err"
  if [ ! -s "$dir/fresh.txt" ]; then
    echo "$tag  GENERATOR PRODUCED NOTHING (it may have tripped its own assert)"
    sed -n 1,3p "$dir/gen.err"; return
  fi
  cp "$CMTD" "$dir/cmtd.txt"

  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/gdn_conv.vhd" \
         >"$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_gdn_conv.vhd >/dev/null 2>&1

  local vf vc
  for which in fresh cmtd; do
    ( cd "$dir" && timeout 900 ghdl -r --std=08 -frelaxed --workdir="$dir" \
        tb_gdn_conv -gVECS=$which.txt --max-stack-alloc=0 --stop-time=900ms ) \
      >"$dir/run_$which.log" 2>&1
  done
  vf=$(verdict "$dir/run_fresh.log")
  vc=$(verdict "$dir/run_cmtd.log")

  local killed=0
  case "$vf" in pass/pass) ;; *) killed=1 ;; esac
  if [ $killed = 1 ]; then NKILL=$((NKILL+1)); else NSURV=$((NSURV+1)); fi

  local word; [ $killed = 1 ] && word=KILLED || word=SURVIVED
  printf '%-4s %-4s %-8s FRESH bx/orc %-9s  CMTD bx/orc %-9s  -- %s\n' \
    "$tag" "$cls" "$word" "$vf" "$vc" "$desc"
  # Only an RTL-class row can say anything about staleness.  On a C or BOTH
  # row the CMTD column is the mutated RTL against the UNMUTATED golden, so a
  # disagreement is guaranteed by construction and means nothing.
  if [ "$vf" != "$vc" ] && [ "$cls" = RTL ]; then
    echo "        ^^ THE TWO GOLDENS DISAGREE ON AN RTL-CLASS MUTATION."
    echo "           sim/gdn_conv_vec.txt has drifted from ref/gdn_conv_vec.c."
    echo "           Regenerate it; see the staleness note at the top of this file."
  fi
}

echo "=================== mutations of gdn_conv ==========================="
echo "FRESH = ref/gdn_conv_vec.c regenerated now;  CMTD = sim/gdn_conv_vec.txt"
echo "verdict is bit-exactness/oracle-tolerance; PROP = an ordering assertion"
echo "fired; DEAD = the run reached no verdict at all"
echo "the bench gates BOTH axes itself: TOL = 0.75 output LSB, baseline 0.5000"
echo
echo "---- class RTL: rtl/gdn_conv.vhd alone --------------------------------"

# R1 and C1 are the SAME change on opposite sides and BOTH are expected
# survivors.  MEASURED, by instrumenting a copy of the generator to compute the
# accumulator both ways over the real stimulus:
#
#   PROBE taps=76544  floor!=round on 19351 (25.3%)  max sh=63
#   PROBE elems=32768  sm changed by round-vs-floor alignment: 0
#                      max |acc delta| = 3
#   PROBE sh_seg histogram: 0:12  15:111  16:5
#
# So the mutation fires on a quarter of all tap alignments and moves the
# accumulator by up to 3 LSB of the ACCUMULATOR grid -- and then the segment
# requantizer shifts that grid right by 15 or 16 in 116 of the 128 cases, so 3
# accumulator LSB is at most 9.2e-5 of one OUTPUT LSB.  Not one of the 32,768
# output elements changed.  The remaining 12 cases have sh_seg = 0, and those
# are exactly the 12 all-zero cases the generator emits at c % 11 == 0, where
# every product is zero and there is no delta to propagate.
#
# This is a RESOLUTION FLOOR, not a coverage hole and not an equivalent
# mutant: neither the bit-exact check nor the 0.75-LSB oracle can see the
# rounding mode of the per-tap alignment, on either side, because the output
# grid is 2^15 times coarser than the place the decision is made.
mutate R1 RTL "the per-tap alignment ROUNDS where 2.1.3 floors" --rtl \
"                  p2(t)(ln) <= shift_right(p1(t)(ln), shf(t));" \
"                  if shf(t) = 0 then
                    p2(t)(ln) <= p1(t)(ln);
                  else
                    p2(t)(ln) <= shift_right(p1(t)(ln)
                      + shift_left(to_signed(1, 32), shf(t)-1), shf(t));
                  end if;"

mutate R2 RTL "sh_seg keeps 15 bits of headroom, not 14" --rtl \
"            if p - 14 > 0 then
              shv  := p - 14;" \
"            if p - 15 > 0 then
              shv  := p - 15;"

mutate R3 RTL "the segment requantize bias is dropped (truncate)" --rtl \
"              bias <= shift_left(to_signed(1, 34), p - 15);" \
"              bias <= (others => '0');"

mutate R4 RTL "e_ref minimises over ALL taps, valid or not (the 2.1.4 defect)" --rtl \
"              if tvalid(t) = '1' then
                et := to_integer(signed(e_t((t+1)*8-1 downto t*8)));
                if not have or et < emin then emin := et; have := true; end if;
              end if;" \
"              et := to_integer(signed(e_t((t+1)*8-1 downto t*8)));
              if not have or et < emin then emin := et; have := true; end if;"

mutate R5 RTL "invalid taps contribute their product instead of zero" --rtl \
"                if tv_r(t) = '1' then
                  p2(t)(ln) <= shift_right(p1(t)(ln), shf(t));" \
"                if true then
                  p2(t)(ln) <= shift_right(p1(t)(ln), shf(t));"

# R6 and R7 are the two halves of defect B-3 / B-3b and both SURVIVE
# tb_gdn_conv.  The reason is structural and is stated in tb_gdn_conv_tvalid_
# skew.vhd's own header: tb_gdn_conv assigns tvalid, e_t and cw_exp once per
# case, before `start`, and never touches them again, so a latch and a live
# port read cannot be told apart.  Each is then cross-checked against the
# bench that CAN move the config group, and the two answers differ:
#
#   R6 (live tvalid)  MEASURED: KILLED by tb_gdn_conv_tvalid_skew,
#                     "FAIL -- 2 case(s) not bit-exact at RDREQ_AT=16".
#                     A genuine COVERAGE HOLE in tb_gdn_conv, already covered
#                     elsewhere in the repo.
#   R7 (live cw_exp)  MEASURED: SURVIVES tb_gdn_conv_tvalid_skew TOO.  That
#                     bench drives cw_exp from a constant (line 520,
#                     `cw_exp <= to_signed(0, 8)`) and gdn_exp_capture has no
#                     cw_exp port at all, so nothing in this repo ever moves
#                     cw_exp under a running conv.  B-3b is UNCOVERED by every
#                     bench, not merely by this one.  Stated as a finding; no
#                     bench is added here to close it.
mutate R6 RTL "the tap mask is read LIVE, not from the S_PREP latch (defect B-3)" --rtl \
"                if tv_r(t) = '1' then" \
"                if tvalid(t) = '1' then"
skew_check R6

mutate R7 RTL "cw_exp is read at S_SH, not from its S_PREP latch (defect B-3b)" --rtl \
"            e_seg  <= resize(e_ref + cw_r - shv, 8);" \
"            e_seg  <= resize(e_ref + cw_exp - shv, 8);"
skew_check R7

mutate R8 RTL "amax is folded on v3, one stage early (the documented defect)" --rtl \
"            if v4 = '1' then
              for ln in 0 to LANES-1 loop
                if au(ln) > amp(ln) then amp(ln) <= au(ln); end if;
              end loop;
            end if;" \
"            if v3 = '1' then
              for ln in 0 to LANES-1 loop
                if au(ln) > amp(ln) then amp(ln) <= au(ln); end if;
              end loop;
            end if;"

# EXPECTED SURVIVOR, and a COVERAGE HOLE.  MEASURED by the same probe:
#   PROBE sat16 clipped: 0   sm==+32767: 0   sm==+32766: 0
# sh_seg = msb_pos(amax) - 14 puts the largest element's magnitude in
# [2^14, 2^15), so the requantized value can only reach 32768 if the rounding
# carries out of the top, and over 32,768 elements it never did.  The sat16
# rails are never exercised by this stimulus at all, in either direction.
mutate R9 RTL "sat16's positive rail is one low" --rtl \
"    if    v >  32767 then return to_signed( 32767, 16);" \
"    if    v >  32766 then return to_signed( 32766, 16);"

mutate R10 RTL "e_seg is published at S_FIN again, after the data (ordering)" --rtl \
"            e_seg  <= resize(e_ref + cw_r - shv, 8);
            sh_seg <= shv;" \
"            sh_seg <= shv;" \
  --rtl \
"          when S_FIN =>" \
"          when S_FIN =>
            e_seg <= resize(e_ref + cw_r - shq, 8);"

mutate R11 RTL "pass B emits no o_valid at all (the segment goes silent)" --rtl \
"            o_valid <= v2;" \
"            o_valid <= '0';"

mutate R12 RTL "err_seg is tied HIGH for every segment" --rtl \
"        state <= S_IDLE; o_valid <= '0'; o_done <= '0'; err_seg <= '0';" \
"        state <= S_IDLE; o_valid <= '0'; o_done <= '0'; err_seg <= '1';" \
  --rtl \
"              err_seg <= '0';
              -- synthesis translate_off" \
"              err_seg <= '1';
              -- synthesis translate_off"

mutate R13 RTL "err_seg is never raised: the int8 overflow test is deleted" --rtl \
"            if (e_ref + cw_r - shv) > 127 or (e_ref + cw_r - shv) < -128 then
              err_seg <= '1';
            end if;" \
"            if false then
              err_seg <= '1';
            end if;"

mutate R14 RTL "msb_pos returns one bit high" --rtl \
"      if a(i) = '1' then p := i - a'low; end if;" \
"      if a(i) = '1' then p := i - a'low + 1; end if;"

echo
echo "---- class C: ref/gdn_conv_vec.c alone.  Must fail bit-exactness ------"
echo "     (the CMTD column here is the unmutated RTL against the stale"
echo "      golden, so it is expected to stay green)"

# EXPECTED SURVIVOR, same resolution floor as R1 and for the identical
# measured reason; see the probe output above R1.
mutate C1 C "the per-tap alignment ROUNDS in the C where the RTL floors" --c \
"                a += floor_shr((int64_t)x[i][t] * (int64_t)w[i][t], sh);" \
"                a += round_shift((int64_t)x[i][t] * (int64_t)w[i][t], sh);"

mutate C2 C "the C's segment requantize truncates where the RTL rounds" --c \
"        for (int i = 0; i < CH; i++) sm[i] = mv4i_sat16(round_shift(acc[i], sh_seg));" \
"        for (int i = 0; i < CH; i++) sm[i] = mv4i_sat16(floor_shr(acc[i], sh_seg));"

echo
echo "---- class BOTH: the same recipe change in the C AND the RTL ----------"
echo "     (bit-exactness MUST stay green on FRESH; only the bench's own"
echo "      double oracle can see these)"

mutate B1 BOTH "the segment requantize bias is dropped in BOTH (truncate)" \
  --rtl \
"              bias <= shift_left(to_signed(1, 34), p - 15);" \
"              bias <= (others => '0');" \
  --c \
"        for (int i = 0; i < CH; i++) sm[i] = mv4i_sat16(round_shift(acc[i], sh_seg));" \
"        for (int i = 0; i < CH; i++) sm[i] = mv4i_sat16(floor_shr(acc[i], sh_seg));"

mutate B2 BOTH "sh_seg keeps 15 bits, not 14, in BOTH: the amax element saturates" \
  --rtl \
"            if p - 14 > 0 then
              shv  := p - 14;
              bias <= shift_left(to_signed(1, 34), p - 15);" \
"            if p - 15 > 0 then
              shv  := p - 15;
              bias <= shift_left(to_signed(1, 34), p - 16);" \
  --c \
"        int sh_seg = msb_pos_u(amax) - 14; if (sh_seg < 0) sh_seg = 0;" \
"        int sh_seg = msb_pos_u(amax) - 15; if (sh_seg < 0) sh_seg = 0;"

# The per-tap alignment clamp moves 63 -> 8, not 63 -> 31.  MEASURED reason
# for not using 31: every product is bounded by 2^30, and both 2^30 >> 31 and
# 2^30 >> 63 are 0 for a positive term and -1 for a negative one, so a clamp
# anywhere at or above 31 is an EQUIVALENT MUTANT and would have scored a
# meaningless survivor.  At 8 a tap that should have been shifted 40 places is
# shifted 8 and contributes up to 2^22, which is a real recipe error.
mutate B3 BOTH "the per-tap alignment shift is clamped at 8 in BOTH" \
  --rtl \
"                if et > 63 then et := 63; elsif et < 0 then et := 0; end if;" \
"                if et > 8 then et := 8; elsif et < 0 then et := 0; end if;" \
  --c \
"                int sh = e_t[t] - e_ref; if (sh > 63) sh = 63;" \
"                int sh = e_t[t] - e_ref; if (sh > 8) sh = 8;"

mutate B4 BOTH "e_ref is the MAXIMUM of the valid tap exponents, not the minimum" \
  --rtl \
"                if not have or et < emin then emin := et; have := true; end if;" \
"                if not have or et > emin then emin := et; have := true; end if;" \
  --c \
"            if (vmask & (1 << t)) { if (!have || e_t[t] < e_ref) { e_ref = e_t[t]; have = 1; } }" \
"            if (vmask & (1 << t)) { if (!have || e_t[t] > e_ref) { e_ref = e_t[t]; have = 1; } }"

echo
echo "kill ratio: $NKILL killed, $NSURV survived, of $NTOT   (scored on FRESH)"
echo "scratch dir with every mutant, both vector sets and both logs: $SCRATCH"
