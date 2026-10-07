#!/usr/bin/env bash
# Mutation teeth for the Jungle Cat USER3 control executor (plan Task 3). Same harness
# shape as sim/mutate_jc_ctl_frame_core.sh: each row patches ONE anchor in rtl/jc_ctl_exec.vhd
# (the anchor must match exactly once), analyzes the closure into a fresh per-run
# directory and runs tb_jc_ctl_exec. KILLED = the bench reported FAIL or did not
# print its PASS line. Every row carries an EXPECTED outcome; the script exits 1 if any
# row mismatches (DID NOT ANALYZE always mismatches) or if Z0 does not report BADMUT.
# No rm anywhere: every row writes into a new directory under one per-run root.
#
# M1-M5 are the brief's required mutants; M6-M8 the dispatch's added ones (rulings (a)-(c));
# the rest are the other behaviours the bench claims to check (each named in its desc).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
GHDL=${GHDL:-ghdl}
RUNROOT=/mnt/storage/fk33_builds/scratch/mutate_jc_ctl_exec_$(date +%Y%m%d_%H%M%S)_$$
mkdir -p "$RUNROOT"
DEPS="rtl/jc_loader_pkg.vhd rtl/jc_ctl_pkg.vhd rtl/jc_ctl_exec.vhd sim/axil_slave_model.vhd sim/jc_axi3_mem.vhd"
TB=tb_jc_ctl_exec
F=rtl/jc_ctl_exec.vhd
NT=0; NMISMATCH=0; Z0SEEN=0; Z0OK=0
NCTRL=0; NCTRL_OK=0
NEQ=0;   NEQ_OK=0
NMUT=0;  NMUT_OK=0

run_row() {   # run_row <tag> <class> <rtlfile> <expected> <desc> <old> <new>
  local tag=$1 cls=$2 file=$3 exp=$4 desc=$5 old=$6 new=$7
  local dir=$RUNROOT/$tag
  NT=$((NT+1))
  mkdir -p "$dir/work" "$dir/run"
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
    EQUIV) NEQ=$((NEQ+1));;
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
      EQUIV) NEQ_OK=$((NEQ_OK+1));;
      VALUE|PROTO) NMUT_OK=$((NMUT_OK+1));;
      AUDIT) Z0OK=1;;
    esac
  fi
  printf '%-4s %-16s expected %-16s %-8s -- %-5s %s\n' "$tag" "$res" "$exp" "$verdict" "$cls" "$desc"
  if [ "$res" = KILLED ]; then
    # the first failing check (a value check), or the crash line if there is none
    local why
    why=$(grep -m1 -E '\(report error\): (CHECK FAILED|MONITOR|axil:|AXI3)' "$dir/log" | sed 's/.*(report error): //')
    [ -n "$why" ] || why="NO CHECK FAILED: $(grep -m1 -E 'error|failure' "$dir/log")"
    printf '       first: %s\n' "${why:0:150}"
  fi
}

run_row C   CTRL  $F SURVIVED "control, no change" "crc  <= crc32_word(crc, m_axil_rdata);" "crc  <= crc32_word(crc, m_axil_rdata);"
run_row Z0  AUDIT $F BADMUT   "self-teeth: anchor not in the file" "THIS TEXT IS NOT IN THE FILE" "x"
# --- the brief's required mutants ---
run_row M1  PROTO $F KILLED "execute on HDR instead of PASS (payloadless frames)" \
  "              have     <= '1';" \
  "              have     <= '1'; if unsigned(word(JC_H_NWORDS_HI downto JC_H_NWORDS_LO)) = 0 then st <= S_CHK; end if;"
run_row M1b PROTO $F KILLED "execute on FAIL as well as PASS" \
  "elsif tag = TAG_PASS then" "elsif tag(1) = '1' then"
run_row M2  VALUE $F KILLED "WR_FIX increments the address" \
  "if h_op = JC_OP_WR_INC then" "if is_wr(h_op) then"
run_row M3  VALUE $F KILLED "BRESP ignored" \
  "if m_axil_bresp /= \"00\" then" "if false then"
run_row M4  PROTO $F KILLED "no wait for the ack before a read" \
  "            if s_rvalid = '0' then" "            if true then"
run_row M5  PROTO $F KILLED "a burst crosses 4 KB" \
  "if to4k < n then n := to4k; end if;" "null;"
# --- the dispatch's added mutants ---
run_row M6  PROTO $F KILLED "NOP clears axi_err" \
  "          if h_op = JC_OP_NOP then
            st <= S_RX;" \
  "          if h_op = JC_OP_NOP then
            st <= S_RX; s_err <= '0'; s_resp <= \"00\"; s_eseq <= NONE;"
run_row M7  PROTO $F KILLED "same rsp_seq republished (repeated read seq not rejected)" \
  " or (is_rd(h_op) and h_seq = s_rseq) then" " then"
run_row M8  PROTO $F KILLED "ack applied after the op (a write does not wait for its frame's ack)" \
  "elsif not (h_ackv = '1' and h_ackseq = s_rseq and s_rvalid = '1') then" "elsif true then"
# --- the rest of what the bench claims ---
run_row M9  VALUE $F KILLED "no header validation (ruling e)" \
  "elsif not hdr_ok(h_op, h_cnt, h_nw, h_addr) then" "elsif false then"
run_row M9b VALUE $F KILLED "validation: nwords not checked" \
  "cnt >= 1 and nw = nw_exp;" "cnt >= 1;"
run_row M9c VALUE $F KILLED "validation: count 0 accepted" \
  "cnt >= 1 and nw = nw_exp;" "nw = nw_exp;"
run_row M9d VALUE $F KILLED "validation: MEM_RD alignment not checked" \
  "ok := ok and a(4 downto 0) = \"00000\" and cnt(2 downto 0) = \"000\"" "ok := ok"
run_row M9e VALUE $F KILLED "validation: invalid header reported as no error" \
  "e_f <= '1'; e_r <= \"10\";" "e_f <= '0'; e_r <= \"10\";"
run_row M10 PROTO $F KILLED "short/long payload executed (DATA count not checked at PASS)" \
  " and resize(nrx, 16) = h_nw then" " then"
run_row M11 PROTO $F KILLED "PASS seq not compared with the header's" \
  "word(31 downto 0) = h_seq and " ""
run_row M12 VALUE $F KILLED "rsp_crc without the final xor" \
  "s_rcrc   <= crc xor x\"FFFFFFFF\";" "s_rcrc   <= crc;"
run_row M12b VALUE $F KILLED "rsp_crc not restarted per response" \
  "          crc   <= (others => '1');" "          null;"
run_row M13 VALUE $F KILLED "HBM RRESP ignored" \
  "if m_axi_rresp /= \"00\" and e_f = '0' then" "if false then"
run_row M14 PROTO $F KILLED "an errored read still publishes" \
  "            s_eseq <= h_seq;" \
  "            s_eseq <= h_seq; if is_rd(h_op) then s_rvalid <= '1'; s_rseq <= h_seq; end if;"
run_row M15 PROTO $F KILLED "a NOP completes like an op (last_done_seq and errors updated)" \
  "          if h_op = JC_OP_NOP then
            st <= S_RX;" \
  "          if h_op = JC_OP_NOP then
            st <= S_DONE;"
run_row M16 PROTO $F KILLED "ack never applied" \
  "        s_rvalid <= '0';
      end if;" \
  "        null;
      end if;"
run_row M17 VALUE $F KILLED "RD_FIX increments the address" \
  "if h_op = JC_OP_RD_INC then" "if is_rd(h_op) then"
run_row M18 VALUE $F KILLED "payload item select off by one" \
  "l_wd  <= item(fr_q, it(2 downto 0));" "l_wd  <= item(fr_q, it(2 downto 0) + 1);"
run_row M19 VALUE $F KILLED "HBM beat words in the wrong order" \
  "          r_wd <= item(hold, k);" "          r_wd <= item(hold, 7 - k);"
run_row M20 PROTO $F KILLED "write continues after an error response" \
  "              e_f <= '1'; e_r <= m_axil_bresp;
              st  <= S_DONE;" \
  "              e_f <= '1'; e_r <= m_axil_bresp;
              st  <= S_LRD0; it <= it + 1; la <= la + 4; fr_ra <= resize(shift_right(it + 1, 3), 6);"
run_row M21 VALUE $F KILLED "success does not clear axi_err (not sticky-until-next)" \
  "            s_err  <= '0';" "            null;"
run_row M22 PROTO $F KILLED "burst length capped at 17 (16 beats exceeded)" \
  "    n := to_unsigned(16, 8);" "    n := to_unsigned(17, 8);"

# --- controller addendum: NOP / cut frame / FAIL change no status ---
run_row M23 PROTO $F KILLED "a new HDR does not restart an open (cut) frame" \
  "            if tag = TAG_HDR then" "            if tag = TAG_HDR and have = '0' then"
run_row M24 PROTO $F KILLED "a cut frame executes when the next HDR arrives" \
  "            if tag = TAG_HDR then" \
  "            if tag = TAG_HDR and have = '1' and resize(nrx, 16) = h_nw then st <= S_CHK; have <= '0';
            elsif tag = TAG_HDR then"
run_row M25 PROTO $F KILLED "a FAIL frame updates last_done_seq" \
  "            else
              have <= '0';
            end if;" \
  "            else
              have <= '0'; s_lastd <= h_seq;
            end if;"
run_row M26 PROTO $F KILLED "discarding a cut frame raises axi_err" \
  "              have     <= '1';" \
  "              have     <= '1'; if have = '1' then s_err <= '1'; end if;"
run_row M27 PROTO $F KILLED "a NOP's ack header clears axi_err (ack-only NOP not status-neutral)" \
  "          if h_op = JC_OP_NOP then
            st <= S_RX;" \
  "          if h_op = JC_OP_NOP then
            st <= S_RX; if h_ackv = '1' then s_err <= '0'; end if;"
run_row M28 VALUE $F KILLED "[383:213] not zero (rsp_crc copied into the st_crc field)" \
  "    s(JC_S_RSPCRC_HI downto JC_S_RSPCRC_LO)   := s_rcrc;" \
  "    s(JC_S_RSPCRC_HI downto JC_S_RSPCRC_LO)   := s_rcrc; s(383 downto 352) := s_rcrc;"

# --- review fix round 1: the reviewer's mutants, under the reviewer's ids ---
run_row R2  PROTO $F KILLED "WVALID held after its handshake until AW completes" \
  "if m_axil_wready = '1' then l_wv <= '0'; end if;" "if awd and wdn then l_wv <= '0'; end if;"
run_row R3  VALUE $F KILLED "INC wrap bound strict (addr + 4*count = 2^32 rejected)" \
  "ok := ok and bytes <= shift_left(to_unsigned(1, 65), 32);" \
  "ok := ok and bytes < shift_left(to_unsigned(1, 65), 32);"
run_row R4  VALUE $F KILLED "MEM_RD top bound strict (addr + 4*count = 2^ADDR_W rejected)" \
  "and bytes <= shift_left(to_unsigned(1, 65), ADDR_W);" \
  "and bytes < shift_left(to_unsigned(1, 65), ADDR_W);"
run_row R6  VALUE $F KILLED "a later RRESP overwrites the first error's code" \
  "if m_axi_rresp /= \"00\" and e_f = '0' then" "if m_axi_rresp /= \"00\" then"
run_row R15 VALUE $F KILLED "rsp_count not updated on publish" \
  "s_rcnt   <= h_cnt;" "s_rcnt   <= s_rcnt;"
run_row R18 PROTO $F KILLED "write ack-wait ignores ack_seq" \
  "elsif not (h_ackv = '1' and h_ackseq = s_rseq and s_rvalid = '1') then" \
  "elsif not (h_ackv = '1' and s_rvalid = '1') then"
run_row R20 PROTO $F KILLED "HBM error burst not drained (stop at the first bad beat)" \
  "            inb <= inb - 1;
            k   <= (others => '0');
            tmo <= 0;
            st  <= S_HW;" \
  "            inb <= inb - 1;
            k   <= (others => '0');
            tmo <= 0;
            st  <= S_HW;
            if m_axi_rresp /= \"00\" then st <= S_DONE; end if;"
run_row R21 PROTO $F KILLED "DATA count not saturated (65 extra words wrap to nwords)" \
  "if have = '1' and nrx /= 63 then" "if have = '1' then"
run_row R22 VALUE $F KILLED "write DECERR treated as OK" \
  "if m_axil_bresp /= \"00\" then" "if m_axil_bresp = \"10\" then"
run_row R23 VALUE $F KILLED "read DECERR treated as OK" \
  "if m_axil_rresp /= \"00\" then" "if m_axil_rresp = \"10\" then"
run_row R24 VALUE $F KILLED "AXI-Lite addr[63:32] not checked" \
  "ok := ok and a(63 downto 32) = 0 and a(1 downto 0) = \"00\";" "ok := ok and a(1 downto 0) = \"00\";"
run_row R25 VALUE $F KILLED "wrap check applied to FIX ops" \
  "      if is_inc(op) then
        ok := ok and bytes" \
  "      if true then
        ok := ok and bytes"
run_row R5  EQUIV $F SURVIVED "ack_prev reset to 0, not to the input (equivalent: see report)" \
  "ack_prev <= rsp_ack_tgl;
      end if;
    end if;
  end process;" \
  "ack_prev <= '0';
      end if;
    end if;
  end process;"

# --- review fix round 1, items 5 and 6 ---
run_row M29 PROTO $F KILLED "AXI-Lite B timeout never fires" \
  "if m_axil_bvalid = '0' and tmo = TMO_CYC - 1 then" "if false then"
run_row M29b PROTO $F KILLED "AXI-Lite R timeout never fires" \
  "if m_axil_rvalid = '0' and tmo = TMO_CYC - 1 then" "if false then"
run_row M29c PROTO $F KILLED "HBM beat timeout never fires" \
  "if m_axi_rvalid = '0' and tmo = TMO_CYC - 1 then" "if false then"
run_row M30 PROTO $F KILLED "owed HBM beats not recorded (late beats not drained)" \
  "            h_owe <= inb;" "            null;"
run_row M31 PROTO $F KILLED "MEM_RD not refused while beats are owed" \
  "                or (h_op = JC_OP_MEM_RD and h_owe /= 0) then" "                or false then"
run_row M32 PROTO $F KILLED "late B not drained after a timeout" \
  "            l_bowe <= '1';" "            null;"
run_row M32b PROTO $F KILLED "AXI-Lite op not refused while a late response is owed" \
  "          elsif (h_op /= JC_OP_MEM_RD and (l_bowe = '1' or l_rowe = '1'))" \
  "          elsif (false)"
run_row M33 PROTO $F KILLED "a write with seq 0xFFFFFFFF accepted" \
  "elsif h_seq = NONE or (is_rd(h_op) and h_seq = s_rseq) then" \
  "elsif is_rd(h_op) and (h_seq = NONE or h_seq = s_rseq) then"
run_row M34 PROTO $F KILLED "last_done_seq set to 0xFFFFFFFF by a seq-none frame" \
  "          if h_seq /= NONE then
            s_lastd <= h_seq;" \
  "          if true then
            s_lastd <= h_seq;"
run_row M35 VALUE $F KILLED "timeout code not OKAY (reported as SLVERR)" \
  "            l_bowe <= '1';
            e_f <= '1'; e_r <= \"00\";" \
  "            l_bowe <= '1';
            e_f <= '1'; e_r <= \"10\";"

printf 'mutants killed %d/%d; controls passed %d/%d; equivalents survived %d/%d; self-teeth %s; rows %d; mismatches %d\n' \
  "$NMUT_OK" "$NMUT" "$NCTRL_OK" "$NCTRL" "$NEQ_OK" "$NEQ" "$([ $Z0OK = 1 ] && echo ok || echo FAILED)" "$NT" "$NMISMATCH"
printf 'scratch: %s\n' "$RUNROOT"
if [ $((NCTRL + NMUT + NEQ + 1)) -ne "$NT" ]; then
  echo "HARNESS FAILURE: row classes do not add up to the row count"; exit 1
fi
[ $Z0SEEN = 1 ] && [ $Z0OK = 1 ] || { echo "HARNESS FAILURE: Z0 did not report BADMUT"; exit 1; }
[ $NMISMATCH = 0 ] || { echo "HARNESS FAILURE: $NMISMATCH row(s) MISMATCHED"; exit 1; }
