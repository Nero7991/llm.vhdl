#!/usr/bin/env bash
# run_mutants.sh -- TRACK NORMADAPT, 2026-08-29.
#
# Teeth-check for sim/ooc_normadapt/ooc_normadapt_equiv.vhd.
#
# A checker that has never been shown to FAIL has not been shown to work.  Each
# mutation below breaks the rewritten write path in a way the rewrite could
# plausibly have been got wrong, and the bench must kill it.  Mutations that do
# NOT bite are reported under their own names and kept: they are the measured
# resolution floor of this oracle and are the most useful rows here.
#
# THE TRAP THIS SCRIPT IS WRITTEN AROUND.  TRACK WRITEDEC's first mutant runner
# scored all seven CAUGHT because `ghdl -a` could not open a single file: every
# mutant exited non-zero and non-zero was read as a kill.  So an analysis
# failure here is VOID, never a kill, and a run that reaches no verdict line at
# all is VOID too.
#
# NO HARDWARE.  GHDL only.
#
# usage: run_mutants.sh <scratchdir>
#   <scratchdir> must already contain src/ (the pinned tree) and
#   gen/ooc_normadapt_before.vhd + gen/ooc_normadapt_after.vhd.
set -u

SCR="${1:?usage: run_mutants.sh <scratchdir>}"
BEFORE="$SCR/gen/ooc_normadapt_before.vhd"
AFTER="$SCR/gen/ooc_normadapt_after.vhd"
EQUIV="$(cd "$(dirname "$0")" && pwd)/ooc_normadapt_equiv.vhd"
MUT="$SCR/mut"
rm -rf "$MUT"; mkdir -p "$MUT"

# name : sed program applied to the AFTER harness
run_one () {
    local name="$1"; shift
    local d="$MUT/$name"
    mkdir -p "$d"
    cp "$AFTER" "$d/mut.vhd"
    python3 - "$d/mut.vhd" "$name" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
s = open(p).read()
def sub(a, b, n=1):
    global s
    assert s.count(a) == n, "%s: pattern count %d != %d" % (name, s.count(a), n)
    s = s.replace(a, b)

if name == "m_off1":
    sub("xw(k-2) <= std_logic_vector(el_rdata);",
        "xw(k-1) <= std_logic_vector(el_rdata);")
elif name == "m_flat_rev":
    sub("xv((i+1)*MANT_W-1 downto i*MANT_W) <= xw(i);",
        "xv((NN-i)*MANT_W-1 downto (NN-i-1)*MANT_W) <= xw(i);")
elif name == "m_flat_drop0":
    sub("gxflat : for i in 0 to NN-1 generate",
        "gxflat : for i in 1 to NN-1 generate")
elif name == "m_flat_rot":
    sub("xv((i+1)*MANT_W-1 downto i*MANT_W) <= xw(i);",
        "xv((i+1)*MANT_W-1 downto i*MANT_W) <= xw((i+1) mod NN);")
elif name == "m_firstdrop":
    sub("                if k >= 2 then\n"
        "                  -- A WHOLE-WORD target, not a runtime slice.  See `xw`.\n"
        "                  xw(k-2) <= std_logic_vector(el_rdata);",
        "                if k >= 3 then\n"
        "                  -- A WHOLE-WORD target, not a runtime slice.  See `xw`.\n"
        "                  xw(k-3) <= std_logic_vector(el_rdata);")
elif name == "m_zerodata":
    sub("xw(k-2) <= std_logic_vector(el_rdata);",
        "xw(k-2) <= (others => '0');")
elif name == "m_extracycle":
    sub("                if k = n+1 then", "                if k = n+2 then")
elif name == "m_wr_rot":
    # An IN-BOUNDS write-index error.  m_off1 leaves the array bounds and is
    # killed by GHDL's own index check rather than by this bench, so it says
    # nothing about the bench's resolution; this one stays in range.
    sub("xw(k-2) <= std_logic_vector(el_rdata);",
        "xw((k-1) mod NN) <= std_logic_vector(el_rdata);")
elif name == "m_uwaddr":
    sub("uw_addr(NUNIT+vi) <= k;", "uw_addr(NUNIT+vi) <= (k+1) mod NN;")
elif name == "m_uwreg":
    sub("uw_reg(NUNIT+vi)  <= to_integer(unsigned(v_reg_d(6 downto 0)));",
        "uw_reg(NUNIT+vi)  <= to_integer(unsigned(v_reg_a(6 downto 0)));")
elif name == "m_ssq":
    sub("ssq := ssq + unsigned(resize(sqp, 64));",
        "ssq := ssq + unsigned(resize(sqp, 64)) + 1;")
elif name == "m_nidx_at_accept":
    # advance the gain index at the ACCEPT instead of the completion -- the
    # off-by-one the RTL comment says was the first version.  At NW_N = 1 this
    # is expected NOT to bite; it is here to measure that blind spot, not to
    # be discarded when it survives.
    sub("          elsif dn = '1' and v_ack(vi) = '1' then",
        "          elsif tk = '1' then")
elif name == "m_none":
    pass
else:
    raise SystemExit("unknown mutation " + name)
open(p, "w").write(s)
PY
    local prc=$?
    if [ "$prc" -ne 0 ]; then
        printf '%-20s VOID   (mutation did not apply)\n' "$name"
        return
    fi

    local w="$d/work"; mkdir -p "$w"
    (
      cd "$w" || exit 1
      for f in util_pkg model_cfg_pkg llama_map_pkg fixed_luts_pkg fixed_pkg rmsnorm_rs; do
        ghdl -a --std=08 -frelaxed --workdir=. "$SCR/src/rtl/$f.vhd" || exit 3
      done
      ghdl -a --std=08 -frelaxed --workdir=. "$BEFORE"   || exit 3
      ghdl -a --std=08 -frelaxed --workdir=. "$d/mut.vhd" || exit 3
      ghdl -a --std=08 -frelaxed --workdir=. "$EQUIV"    || exit 3
    ) >"$d/analyse.log" 2>&1
    if [ $? -ne 0 ]; then
        printf '%-20s VOID   (ANALYSIS FAILED -- not a kill)\n' "$name"
        return
    fi

    ( cd "$w" && timeout 1800 ghdl -r --std=08 -frelaxed --workdir=. \
        ooc_normadapt_equiv -gNN_G=64 -gLANES_G=4 -gRESETMID=true \
        --max-stack-alloc=0 --stop-time=900ms ) >"$d/run.log" 2>&1

    # THREE outcomes, not two.  A mutant killed by GHDL's own array-bounds
    # check or by an assert INSIDE the design is dead, but it is not evidence
    # that THIS bench has teeth -- and neither bound exists in synthesis.  They
    # are reported separately so the bench's own resolution is not overstated.
    if grep -q "NORMADAPT_EQUIV PASS" "$d/run.log"; then
        printf '%-20s SURVIVED\n' "$name"
    elif grep -qE "MISMATCH|DEGENERATE|NORMADAPT_EQUIV FAIL|WRITE COUNT|TIMEOUT" "$d/run.log"; then
        printf '%-20s CAUGHT-BENCH   (%s)\n' "$name" \
          "$(grep -oE 'MISMATCH [a-z_/ ]*|DEGENERATE TRIAL|WRITE COUNT wrong|TIMEOUT[^ ]*' "$d/run.log" | head -1)"
    elif grep -qE "out of bounds|assertion failure" "$d/run.log"; then
        printf '%-20s CAUGHT-RTL     (%s)\n' "$name" \
          "$(grep -oE 'index \([0-9]+\) out of bounds[^ ]*|rmsnorm_rs: [a-z ]*' "$d/run.log" | head -1)"
    else
        printf '%-20s VOID   (no verdict line -- see %s)\n' "$name" "$d/run.log"
    fi
}

echo "== NORMADAPT mutants, $(date -Is)"
for m in m_none m_off1 m_wr_rot m_flat_rev m_flat_drop0 m_flat_rot m_firstdrop \
         m_zerodata m_extracycle m_uwaddr m_uwreg m_ssq m_nidx_at_accept; do
    run_one "$m"
done
echo "== done"
