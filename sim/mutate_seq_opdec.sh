#!/usr/bin/env bash
# Mutation test for rtl/seq_opdec.vhd.  Same discipline as the two sibling
# scripts: every mutation is well-formed VHDL and in-bounds, so a kill is the
# checker noticing and not the language noticing, and a survivor is
# INVESTIGATED BY READING THE CODE rather than assumed to be equivalent.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/seq_opdec.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

cfg_name() { case "$1" in
  A) echo "prefetch far ahead, y_exp valid one cycle";;
  B) echo "units instant";;
  C) echo "done is a one-cycle pulse";;
  D) echo "dense writes, y_exp valid 3 cycles";;
  E) echo "rogue exponent write into a HELD region (XW_AT=8)";;
  F) echo "src2 names a region the opcode does not read (SRC2_BAD_AT=200)";;
  G) echo "REL_NAIVE, must fail ERR_LOCK at step 2";;
  H) echo "write strobes that outlive their job (WR_TAIL=2)";;
  I) echo "QKV offset not a segment boundary (OFF_SEG_AT=2)";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gURAM_LAT=1 -gJOB_LAT=40";;
  B) echo "-gJOB_LAT=0 -gLAT_SKEW=0";;
  C) echo "-gDONE_STYLE=1";;
  D) echo "-gEXP_DECAY=3 -gWR_N=8 -gWR_GAP=0";;
  E) echo "-gXW_AT=8";;
  F) echo "-gSRC2_BAD_AT=200";;
  G) echo "-gREL_NAIVE=true";;
  H) echo "-gWR_TAIL=2";;
  I) echo "-gOFF_SEG_AT=2";;
esac; }
CFGS="A B C D E F G H I"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/seq_opdec.vhd" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then echo "$tag: ANCHOR FAILED"; return; fi
  for f in util_pkg model_cfg_pkg seq_desc_fetch seq_region_lock; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/seq_opdec.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/seq_tbl_pkg.vhd >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_seq_opdec.vhd >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if timeout 900 ghdl -r --std=08 -frelaxed --workdir="$dir" tb_seq_opdec \
         $(cfg_args "$c") --max-stack-alloc=0 --stop-time=400ms \
         > "$dir/run_$c.log" 2>&1 && grep -q "tb_seq_opdec: PASS" "$dir/run_$c.log"; then
      survivors="$survivors $c"
    else
      killers="$killers $c"
    fi
  done
  if [ -n "$killers" ]; then
    echo "$tag  KILLED by:$killers   survived:${survivors:- -}   -- $desc"
    for c in $killers; do
      echo "      [$c $(cfg_name "$c")]"
      grep -E "report error" "$dir/run_$c.log" | head -1 \
        | sed 's/^/        /' | cut -c1-170
    done
  else
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "====================== mutations of seq_opdec ======================"

# ---- class (a): the check and the commit must see the SAME descriptor ----
mutate O1 "the commit reads the LIVE chk_* port instead of the latch (a1)" \
'  iss_prod   <= '"'"'1'"'"'                              when tstate = T_REQ or tstate = T_CMT
                else c_prod when chk_req = '"'"'1'"'"' else l_prod;
  iss_dst    <= to_unsigned(HOST_REG, 8)         when tstate = T_REQ or tstate = T_CMT
                else c_dst  when chk_req = '"'"'1'"'"' else l_dst;
  iss_seg    <= "00"                             when tstate = T_REQ or tstate = T_CMT
                else c_seg  when chk_req = '"'"'1'"'"' else l_seg;
  iss_off    <= to_unsigned(0, ADDR_W)           when tstate = T_REQ or tstate = T_CMT
                else c_off  when chk_req = '"'"'1'"'"' else l_off;
  iss_n_rows <= to_unsigned(HOST_ROWS, ADDR_W)   when tstate = T_REQ or tstate = T_CMT
                else c_rows when chk_req = '"'"'1'"'"' else l_rows;
  iss_cons   <= (NREG-1 downto 0 => '"'"'0'"'"')         when tstate = T_REQ or tstate = T_CMT
                else c_cons when chk_req = '"'"'1'"'"' else l_cons;
  iss_rel    <= (NREG-1 downto 0 => '"'"'0'"'"')         when tstate = T_REQ or tstate = T_CMT
                else c_rel  when chk_req = '"'"'1'"'"' else l_rel;' \
'  iss_prod   <= '"'"'1'"'"'                              when tstate = T_REQ or tstate = T_CMT
                else c_prod;
  iss_dst    <= to_unsigned(HOST_REG, 8)         when tstate = T_REQ or tstate = T_CMT
                else c_dst;
  iss_seg    <= "00"                             when tstate = T_REQ or tstate = T_CMT
                else c_seg;
  iss_off    <= to_unsigned(0, ADDR_W)           when tstate = T_REQ or tstate = T_CMT
                else c_off;
  iss_n_rows <= to_unsigned(HOST_ROWS, ADDR_W)   when tstate = T_REQ or tstate = T_CMT
                else c_rows;
  iss_cons   <= (NREG-1 downto 0 => '"'"'0'"'"')         when tstate = T_REQ or tstate = T_CMT
                else c_cons;
  iss_rel    <= (NREG-1 downto 0 => '"'"'0'"'"')         when tstate = T_REQ or tstate = T_CMT
                else c_rel;'

mutate O2 "the produced exponent is captured at job_cmp, not at first done (a3)" \
'        if x_armed = '"'"'1'"'"' and x_taken = '"'"'0'"'"' and u_done(x_unit) = '"'"'1'"'"' then' \
'        if x_armed = '"'"'1'"'"' and x_taken = '"'"'0'"'"' and job_cmp = '"'"'1'"'"' then'

mutate O3 "the captured exponent is re-latched every cycle done stays high" \
'        if x_armed = '"'"'1'"'"' and x_taken = '"'"'0'"'"' and u_done(x_unit) = '"'"'1'"'"' then' \
'        if x_armed = '"'"'1'"'"' and u_done(x_unit) = '"'"'1'"'"' then'

# ---- the decode itself ----
mutate O4 "the consume mask forgets the opcode's implied regions (B's four, C's three)" \
'    cons := opc_mask(chk_opcode);' \
'    cons := (others => '"'"'0'"'"');'

mutate O5 "the release mask is dropped: nothing is ever returned to FREE" \
'      c_rel <= rel_mask;' \
'      c_rel <= (others => '"'"'0'"'"');'

mutate O6 "n_rows is passed through even when the step has no destination region" \
'    else
      c_rows <= (others => '"'"'0'"'"');
    end if;' \
'    else
      c_rows <= resize(chk_n_rows(ADDR_W-1 downto 0), ADDR_W);
    end if;'

mutate O7 "the exponent segment is always 0: q, k and v share one capture slot" \
'      if    chk_dst_off = 0                                       then seg := "00";
      elsif chk_dst_off = to_unsigned(MSEG_OFF1, 32)              then seg := "01";
      elsif chk_dst_off = to_unsigned(MSEG_OFF2, 32)              then seg := "10";
      else' \
'      if    chk_dst_off = 0                                       then seg := "00";
      elsif chk_dst_off = to_unsigned(MSEG_OFF1, 32)              then seg := "00";
      elsif chk_dst_off = to_unsigned(MSEG_OFF2, 32)              then seg := "00";
      else'

mutate O8 "the src2 consistency check is removed" \
'            elsif extra(reg_idx(job_src2)) = '"'"'0'"'"' then' \
'            elsif false then'

# ---- token start ----
mutate O9 "the host-written X region is never published (the fourth finding, undone)" \
'  iss_prod   <= '"'"'1'"'"'                              when tstate = T_REQ or tstate = T_CMT' \
'  iss_prod   <= '"'"'0'"'"'                              when tstate = T_REQ or tstate = T_CMT'

mutate O10 "the locks are not reset between tokens" \
'  lock_rst <= '"'"'1'"'"' when rst = '"'"'1'"'"' or tstate = T_RST else '"'"'0'"'"';' \
'  lock_rst <= rst;'

mutate O11 "a mid-job lock violation is not forced into the next check (b2)" \
'                       and (c_bad = '"'"'1'"'"' or iss_ok = '"'"'0'"'"' or s_err = '"'"'1'"'"')' \
'                       and (c_bad = '"'"'1'"'"' or iss_ok = '"'"'0'"'"')'

echo
echo "scratch dir with every mutant and every log: $SCRATCH"
