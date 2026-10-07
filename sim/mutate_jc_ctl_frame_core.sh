#!/usr/bin/env bash
# Mutation teeth for the Jungle Cat USER3 control frame core (plan Task 2). Same harness
# shape as sim/mutate_jc_loader.sh: each row patches ONE anchor in rtl/jc_ctl_frame_core.vhd
# (the anchor must match exactly once), analyzes the closure into a fresh per-run
# directory and runs tb_jc_ctl_frame_core. KILLED = the bench reported FAIL or did not
# print its PASS line. Every row carries an EXPECTED outcome; the script exits 1 if any
# row mismatches (DID NOT ANALYZE always mismatches) or if Z0 does not report BADMUT.
# No rm anywhere: every row writes into a new directory under one per-run root.
#
# M1-M3 and M4/M4b/M4c are the required mutants (fix round 1 moved the ack to the host:
# the old "ack before the last bit" row became the three host-ack rows plus M4d); the rest
# are the other behaviours the bench claims to check (each named in its desc string).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
GHDL=${GHDL:-ghdl}
RUNROOT=/mnt/storage/fk33_builds/scratch/mutate_jc_ctl_frame_core_$(date +%Y%m%d_%H%M%S)_$$
mkdir -p "$RUNROOT"
DEPS="rtl/jc_loader_pkg.vhd rtl/jc_ctl_pkg.vhd rtl/jc_ctl_frame_core.vhd"
TB=tb_jc_ctl_frame_core
F=rtl/jc_ctl_frame_core.vhd
NT=0; NMISMATCH=0; Z0SEEN=0; Z0OK=0
NCTRL=0; NCTRL_OK=0
NMUT=0;  NMUT_OK=0

run_row() {   # run_row <tag> <class> <rtlfile> <expected> <desc> <old> <new>
  local tag=$1 cls=$2 file=$3 exp=$4 desc=$5 old=$6 new=$7
  local dir=$RUNROOT/$tag
  NT=$((NT+1))
  mkdir -p "$dir/work" "$dir/run"
  cp "$REPO/sim/jc_ctl_frame_vec.txt" "$dir/run/"
  local res mismatch=0
  if ! python3 - "$REPO/$file" "$dir/$(basename "$file")" "$old" "$new" <<'PY' 2>"$dir/patch.log"
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("ANCHOR MATCHED %d TIMES\n" % n); sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  then
    res=BADMUT
    [ "$tag" = Z0 ] && Z0SEEN=1
  else
    local f ok=1
    for f in $DEPS; do
      if [ "$f" = "$file" ]; then f="$dir/$(basename "$file")"; else f="$REPO/$f"; fi
      "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$f" >>"$dir/analyze.log" 2>&1 || ok=0
    done
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/sim/$TB.vhd" >>"$dir/analyze.log" 2>&1 || ok=0
    if [ $ok = 0 ]; then
      res="DID NOT ANALYZE"
    else
      ( cd "$dir/run" && timeout 900 "$GHDL" -r --std=08 -frelaxed --workdir="$dir/work" "$TB" \
          --stop-time=100ms ) >"$dir/log" 2>&1
      # fixed-string match on GHDL's own report line (see mutate_jc_loader.sh)
      if grep -qF "(report note): PASS: $TB checks=" "$dir/log"; then
        res=SURVIVED
      else
        res=KILLED
      fi
    fi
  fi
  case "$cls" in
    CTRL) NCTRL=$((NCTRL+1));;
    VALUE|PROTO) NMUT=$((NMUT+1));;
  esac
  if [ "$res" = "DID NOT ANALYZE" ] || [ "$res" != "$exp" ]; then mismatch=1; fi
  local verdict
  if [ $mismatch = 1 ]; then
    verdict=MISMATCH; NMISMATCH=$((NMISMATCH+1))
  else
    verdict=OK
    case "$cls" in
      CTRL)  NCTRL_OK=$((NCTRL_OK+1));;
      VALUE|PROTO) NMUT_OK=$((NMUT_OK+1));;
      AUDIT) Z0OK=1;;
    esac
  fi
  printf '%-4s %-16s expected %-16s %-8s -- %-5s %s\n' "$tag" "$res" "$exp" "$verdict" "$cls" "$desc"
}

run_row C   CTRL  $F SURVIVED "control, no change" "(crc xor x\"FFFFFFFF\");" "(crc xor x\"FFFFFFFF\");"
run_row Z0  AUDIT $F BADMUT   "self-teeth: anchor not in the file" "THIS TEXT IS NOT IN THE FILE" "x"
# --- the brief's required mutants (M4 re-targeted in fix round 1: the ack is host-driven) ---
run_row M1  VALUE $F KILLED "CRC compare dropped (every verdict PASS)" \
  "pass := crc_rx = (crc xor x\"FFFFFFFF\");" "pass := true;"
run_row M2  VALUE $F KILLED "response shifted by one bit" \
  "rsp_sr <= rsp_q;" "rsp_sr <= rsp_q(30 downto 0) & '0';"
run_row M3  VALUE $F KILLED "count 497 accepted" \
  "unsigned(word(JC_H_COUNT_HI downto JC_H_COUNT_LO)) <= JC_CTL_MAX_ITEMS" \
  "unsigned(word(JC_H_COUNT_HI downto JC_H_COUNT_LO)) <= JC_CTL_MAX_ITEMS + 1"
run_row M4  PROTO $F KILLED "ack without the seq compare" \
  "h_ack_seq = lat_seq and " ""
run_row M4b PROTO $F KILLED "ack on a FAIL frame" \
  "if pass and h_ack_v = '1'" "if h_ack_v = '1'"
run_row M4c PROTO $F KILLED "ack ignores ack_valid" \
  "h_ack_v = '1' and " ""
run_row M4d PROTO $F KILLED "ack of a seq not being presented (lat_v ignored)" \
  " and lat_v = '1' then" " then"
# --- bounds truncations (fix round 1, minor 2) ---
run_row M3b VALUE $F KILLED "count bound compared on 9 bits" \
  "unsigned(word(JC_H_COUNT_HI downto JC_H_COUNT_LO)) <= JC_CTL_MAX_ITEMS" \
  "unsigned(word(JC_H_COUNT_LO + 8 downto JC_H_COUNT_LO)) <= JC_CTL_MAX_ITEMS"
run_row M6  VALUE $F KILLED "nwords 63 accepted" \
  "<= JC_CTL_MAX_PAYLOAD then" "<= JC_CTL_MAX_PAYLOAD + 1 then"
run_row M6b VALUE $F KILLED "nwords bound compared on 6 bits" \
  "unsigned(word(JC_H_NWORDS_HI downto JC_H_NWORDS_LO)) <= JC_CTL_MAX_PAYLOAD" \
  "unsigned(word(JC_H_NWORDS_LO + 5 downto JC_H_NWORDS_LO)) <= JC_CTL_MAX_PAYLOAD"
# --- the rest of what the bench claims ---
run_row M5  PROTO $F KILLED "stale-status guard off (re-presents, accepts a re-ack)" "if stale then" "if false then"
run_row M7  VALUE $F KILLED "rsp_count over 496 not clamped to 496" \
  "n := JC_CTL_MAX_ITEMS;" "n := to_integer(cnt) mod 497;"
run_row M8  VALUE $F KILLED "CRC failures not counted" "crcf <= crcf + 1;" "null;"
run_row M9  PROTO $F KILLED "no read lookahead (rsp_addr = word being loaded)" \
  "rsp_a <= to_unsigned(k + 1, JC_CTL_RSP_AW);" "rsp_a <= to_unsigned(k, JC_CTL_RSP_AW);"
run_row M10 VALUE $F KILLED "ovf not merged into the status" \
  "r(JC_S_OVF)                            := o;" "r(JC_S_OVF)                            := '0';"
run_row M11 VALUE $F KILLED "desync not counted" "desync <= desync + 1;" "null;"
run_row M12 PROTO $F KILLED "sel ignored while shifting (another instruction's scan)" \
  "elsif sel = '1' and shift = '1' then" "elsif shift = '1' then"
run_row M13 VALUE $F KILLED "rsp_valid shown unmasked on a stale slot" \
  "        st_sr   <= merged(st_in, desync, ovf, crcf, v, n);" \
  "        st_sr   <= merged(st_in, desync, ovf, crcf, st_in(JC_S_RSPVALID), n);"
run_row M14 VALUE $F KILLED "rsp_count on TDO not the shifted count (passed through)" \
  "r(JC_S_RSPCNT_HI downto JC_S_RSPCNT_LO) := std_logic_vector(to_unsigned(n, 16));" \
  "r(JC_S_RSPCNT_HI downto JC_S_RSPCNT_LO) := st(JC_S_RSPCNT_HI downto JC_S_RSPCNT_LO);"
run_row M15 VALUE $F KILLED "[383:213] passed through instead of forced to zero" \
  "r(JC_CTL_STATUS_BITS-1 downto JC_S_ZERO_LO) := (others => '0');" "null;"
run_row M16 VALUE $F KILLED "rsp_crc not passed through (zeroed with the top)" \
  "r(JC_CTL_STATUS_BITS-1 downto JC_S_ZERO_LO) := (others => '0');" \
  "r(JC_CTL_STATUS_BITS-1 downto JC_S_RSPCRC_LO) := (others => '0');"

printf 'mutants killed %d/%d; controls passed %d/%d; self-teeth %s; rows %d; mismatches %d\n' \
  "$NMUT_OK" "$NMUT" "$NCTRL_OK" "$NCTRL" "$([ $Z0OK = 1 ] && echo ok || echo FAILED)" "$NT" "$NMISMATCH"
printf 'scratch: %s\n' "$RUNROOT"
if [ $((NCTRL + NMUT + 1)) -ne "$NT" ]; then
  echo "HARNESS FAILURE: row classes do not add up to the row count"; exit 1
fi
[ $Z0SEEN = 1 ] && [ $Z0OK = 1 ] || { echo "HARNESS FAILURE: Z0 did not report BADMUT"; exit 1; }
[ $NMISMATCH = 0 ] || { echo "HARNESS FAILURE: $NMISMATCH row(s) MISMATCHED"; exit 1; }
