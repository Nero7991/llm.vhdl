#!/usr/bin/env bash
# Mutation test for rtl/seq_region_lock.vhd.  Same discipline as
# sim/mutate_seq_desc_fetch.sh: every mutation is well-formed and in-bounds, so
# a kill is the checker noticing and not the language noticing, and a survivor
# is investigated by reading the code rather than assumed to be equivalent.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/seq_region_lock.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

cfg_name() { case "$1" in
  A) echo "clean walk, writes fast, job slow";;
  B) echo "late writes after every completion (WR_TAIL=3)";;
  C) echo "rogue exponent write into a HELD region (XW_AT=8)";;
  D) echo "dst_offset off by one (BAD_OFF_AT=3)";;
  E) echo "consumes a region nobody produced (BAD_CONS_AT=100)";;
  F) echo "writes slow, job instant";;
  G) echo "row count overruns the region (BAD_ROWS_AT=3)";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gWR_N=6 -gWR_GAP=0 -gJOB_LAT=12";;
  B) echo "-gWR_TAIL=3 -gJOB_LAT=20";;
  C) echo "-gXW_AT=8";;
  D) echo "-gBAD_OFF_AT=3";;
  E) echo "-gBAD_CONS_AT=100";;
  F) echo "-gWR_N=3 -gWR_GAP=3 -gJOB_LAT=0";;
  G) echo "-gBAD_ROWS_AT=3";;
esac; }
CFGS="A B C D E F G"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/seq_region_lock.vhd" "$old" "$new" <<'PY'
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
  for f in util_pkg model_cfg_pkg; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/seq_region_lock.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/seq_tbl_pkg.vhd >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_seq_region_lock.vhd >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if ghdl -r --std=08 -frelaxed --workdir="$dir" tb_seq_region_lock \
         $(cfg_args "$c") --max-stack-alloc=0 --stop-time=400ms \
         > "$dir/run_$c.log" 2>&1 && grep -q "PASS" "$dir/run_$c.log"; then
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
        | sed 's/^/        /' | cut -c1-160
    done
  else
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "=================== mutations of seq_region_lock ==================="

mutate N1 "the exponent write gate ignores the HELD state (hazard A3 undone)" \
'  xw_gate <= '"'"'0'"'"' when xw_we = '"'"'1'"'"'
                      and (xw_region >= NREG or xw_seg >= SEGS
                           or (lock(reg_idx(xw_region)) = L_HELD' \
'  xw_gate <= '"'"'0'"'"' when xw_we = '"'"'1'"'"'
                      and (xw_region >= NREG or xw_seg >= SEGS
                           or (lock(reg_idx(xw_region)) = L_FREE'

mutate N2 "the write gate no longer requires a live committed job (late writes land)" \
'  wr_gate <= '"'"'1'"'"' when wr_we = '"'"'1'"'"' and jb_live = '"'"'1'"'"' and jb_prod = '"'"'1'"'"'' \
'  wr_gate <= '"'"'1'"'"' when wr_we = '"'"'1'"'"' and jb_prod = '"'"'1'"'"''

mutate N3 "append-only is not enforced: any dst_offset is accepted" \
'        elsif iss_off /= fill_ptr(d) then
          ok := '"'"'0'"'"'; code := ERR_DESC;
        end if;' \
'        end if;'

mutate N4 "a consumer may take a FREE region (reads what nobody produced)" \
'        if lock(i) = L_FREE then
          ok := '"'"'0'"'"'; code := ERR_LOCK;
        elsif lock(i) = L_HELD then' \
'        if lock(i) = L_HELD then'

mutate N5 "the exponent is captured at ISSUE instead of at the producer done" \
'            exp_cap(jb_slot) <= cmp_y_exp;
            exp_vld(jb_slot) <= '"'"'1'"'"';' \
'            exp_vld(jb_slot) <= '"'"'1'"'"';'

mutate N6 "the release mask is ignored: every consumed region goes back to VALID" \
'              if jb_rel(i) = '"'"'1'"'"' then
                lock(i)     <= L_FREE;
                fill_ptr(i) <= (others => '"'"'0'"'"');
              else
                lock(i) <= L_VALID;
              end if;' \
'              lock(i) <= L_VALID;'

mutate N7 "the completion acts on the LIVE issue ports instead of the latched job" \
'          if jb_prod = '"'"'1'"'"' and jb_dst < NREG then' \
'          if iss_prod = '"'"'1'"'"' and jb_dst < NREG then'

echo
echo "scratch dir with every mutant and every log: $SCRATCH"
