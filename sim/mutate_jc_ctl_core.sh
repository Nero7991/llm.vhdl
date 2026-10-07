#!/usr/bin/env bash
# Mutation teeth for the Jungle Cat USER3 control core COMPOSITION (plan Task 4),
# rtl/jc_ctl_core.vhd, against sim/tb_jc_ctl_core.vhd (the end-to-end bench). Same harness
# as sim/mutate_jc_ctl_exec.sh: each row patches ONE anchor (it must match exactly once) in a
# scratch copy of one RTL file, analyzes the closure into a fresh per-run directory and runs
# the bench. KILLED = the bench failed or did not print its PASS line. Every row carries an
# EXPECTED outcome; the script exits 1 on any mismatch or if Z0 does not report BADMUT.
# No rm anywhere: every row writes into a new directory under one per-run root. The repo's
# files are never modified (the loader's frozen jc_status_sync is mutated only in scratch).
#
# K rows mutate the composition. EQUIV rows are CDC defects a zero-delay RTL simulation
# cannot see (a missing synchroniser or a wrong-clock read is functionally identical when
# every flop settles instantly); their check is structural, in hw/jc/ctl/ooc_ctl_core.tcl
# (^JCCTL_OOC_CDC unexpected 0, the ASYNC_REG census, the RAMB check), which the controller
# runs. S rows mutate jc_status_sync (scratch copy) to show the stress check (case S) has
# teeth. F and X rows are frame-core and executor mutants re-run end to end (attribution:
# the end-to-end bench sees them through the real crossings).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
GHDL=${GHDL:-ghdl}
RUNROOT=/mnt/storage/fk33_builds/scratch/mutate_jc_ctl_core_$(date +%Y%m%d_%H%M%S)_$$
mkdir -p "$RUNROOT"
DEPS="rtl/util_pkg.vhd rtl/jc_loader_pkg.vhd rtl/jc_ctl_pkg.vhd rtl/async_fifo.vhd rtl/jc_ctl_frame_core.vhd rtl/jc_ctl_exec.vhd rtl/jc_status_sync.vhd rtl/jc_ctl_core.vhd sim/axil_slave_model.vhd sim/jc_axi3_mem.vhd"
TB=tb_jc_ctl_core
F=rtl/jc_ctl_core.vhd
FC=rtl/jc_ctl_frame_core.vhd
EX=rtl/jc_ctl_exec.vhd
SS=rtl/jc_status_sync.vhd
NT=0; NMISMATCH=0; Z0SEEN=0; Z0OK=0
NCTRL=0; NCTRL_OK=0
NEQ=0;   NEQ_OK=0
NMUT=0;  NMUT_OK=0

run_row() {   # run_row <tag> <class> <rtlfile> <expected> <desc> <old> <new>
  local tag=$1 cls=$2 file=$3 exp=$4 desc=$5 old=$6 new=$7
  local dir=$RUNROOT/$tag
  NT=$((NT+1))
  mkdir -p "$dir/work" "$dir/run"
  ln -s "$REPO/sim/jc_ctl_core_vec.txt" "$dir/run/jc_ctl_core_vec.txt"
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
          --stop-time=200ms ) >"$dir/log" 2>&1
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
    why=$(grep -m1 -E '\(report (error|failure)\): (CHECK FAILED|STRESS|axil:|AXI3)' "$dir/log" | sed -E 's/.*\(report (error|failure)\): //')
    [ -n "$why" ] || why="NO CHECK FAILED: $(grep -m1 -E 'error|failure' "$dir/log")"
    printf '       first: %s\n' "${why:0:150}"
  fi
}

run_row C   CTRL  $F SURVIVED "control, no change" "      rak_s2 <= rak_s1;" "      rak_s2 <= rak_s1;"
run_row Z0  AUDIT $F BADMUT   "self-teeth: anchor not in the file" "THIS TEXT IS NOT IN THE FILE" "x"
# --- the composition ---
run_row K1  PROTO $F KILLED "FIFO depth 32 (less than one frame behind a waiting read)" \
  "generic map(W => JC_FIFO_W, DEPTH => 128)" "generic map(W => JC_FIFO_W, DEPTH => 32)"
# K1b MEASURED (first run): DEPTH 64 survives. Case D queues 66 words (a 62-word write's 64
# pushes and a NOP's 2) behind a waiting read, and 64 entries plus the FIFO's 2-word output
# stage hold exactly that. 128 (the loader's shape) is two frames of headroom, not a minimum.
run_row K1b EQUIV $F SURVIVED "FIFO depth 64 (holds case D's 66 words: 64 + 2 output stage)" \
  "generic map(W => JC_FIFO_W, DEPTH => 128)" "generic map(W => JC_FIFO_W, DEPTH => 64)"
run_row K2  PROTO $F KILLED "ack toggle never reaches the executor" \
  "             rsp_ack_tgl => rak_s2," "             rsp_ack_tgl => '0',"
run_row K3  PROTO $F KILLED "FIFO popped while the executor is in reset (queued frame lost)" \
  "  q_vx    <= q_valid and not rst_s2;
  q_ready <= q_rx and not rst_s2;" \
  "  q_vx    <= q_valid;
  q_ready <= q_rx;"
run_row K4  VALUE $F KILLED "response RAM write address off by one" \
  "rram(to_integer(unsigned(rsp_waddr))) <= rsp_wdata;" \
  "rram(to_integer(unsigned(rsp_waddr) + 1)) <= rsp_wdata;"
run_row K5  VALUE $F KILLED "response RAM read address off by one" \
  "rsp_q <= rram(to_integer(unsigned(rsp_addr)));" \
  "rsp_q <= rram(to_integer(unsigned(rsp_addr) + 1));"
run_row K8  PROTO $F KILLED "FIFO read side reset by arst (the loader's pattern: stale replay)" \
  "rclk => aclk, rrst => '0'," "rclk => aclk, rrst => rst_s2,"
run_row K9  VALUE $F KILLED "status crossing from the wrong source (TCK sees a zero status)" \
  "port map(aclk => aclk, live => st_live, tck => tck, st_tck => st_tck);" \
  "port map(aclk => aclk, live => (st_live'range => '0'), tck => tck, st_tck => st_tck);"
# --- CDC defects invisible to zero-delay RTL simulation (checked by the OOC audit) ---
run_row K6  EQUIV $F SURVIVED "no ack synchroniser (executor takes the TCK toggle raw)" \
  "             rsp_ack_tgl => rak_s2," "             rsp_ack_tgl => ack_tgl,"
run_row K7  EQUIV $F SURVIVED "status sync bypassed (frame core latches the live aclk status)" \
  "             st_in => st_tck," "             st_in => st_live,"
run_row K10 EQUIV $F SURVIVED "response RAM read on aclk instead of TCK" \
  "  rram_r : process(tck)
  begin
    if rising_edge(tck) then" \
  "  rram_r : process(aclk)
  begin
    if rising_edge(aclk) then"
run_row K11 EQUIV $F SURVIVED "reset synchroniser removed (executor takes arst raw)" \
  "      rst_s2 <= rst_s1;" "      rst_s2 <= arst;"
# --- jc_status_sync (scratch copy only): the stress check's teeth ---
run_row S1  PROTO $SS KILLED "snapshot retaken every aclk (no handshake hold)" \
  "      if ack_s2 = pub then
        snap <= live;" \
  "      snap <= live;
      if ack_s2 = pub then"
# S2 MEASURED (first run): survives. Capturing on tgl_s1 is one TCK earlier, still more than
# one TCK after the snap write, so the margin bound holds; the lost stage is a metastability
# defect, which zero-delay simulation cannot show.
run_row S2  EQUIV $SS SURVIVED "TCK captures on the first synchroniser stage (metastability only)" \
  "      if tgl_s2 /= ack then
        st_r <= snap;
        ack  <= tgl_s2;" \
  "      if tgl_s1 /= ack then
        st_r <= snap;
        ack  <= tgl_s1;"
# --- frame core and executor mutants, end to end ---
run_row F1  VALUE $FC KILLED "frame core: CRC compare dropped (the corrupted frame executes)" \
  "pass := crc_rx = (crc xor x\"FFFFFFFF\");" "pass := true;"
run_row F4  PROTO $FC KILLED "frame core: ack without the seq compare" \
  "h_ack_seq = lat_seq and " ""
# F5 and X8 are not reachable end to end with whole 16,384-bit slots at these clocks: the
# ack slot shifts 224 more bits after the ack, long enough for the clear to cross, so no
# stale status is ever latched, and a write's early start is not observable at the ports.
# tb_jc_ctl_frame_core (M5) and tb_jc_ctl_exec (M8) kill them at unit level.
run_row F5  EQUIV $FC SURVIVED "frame core: stale-status guard off (unreachable with whole slots)" "if stale then" "if false then"
run_row X4  PROTO $EX KILLED "executor: no wait for the ack before a read" \
  "            if s_rvalid = '0' then" "            if true then"
run_row X8  EQUIV $EX SURVIVED "executor: a write does not wait for its frame's ack (not observable)" \
  "elsif not (h_ackv = '1' and h_ackseq = s_rseq and s_rvalid = '1') then" "elsif true then"

printf 'mutants killed %d/%d; controls passed %d/%d; equivalents survived %d/%d; self-teeth %s; rows %d; mismatches %d\n' \
  "$NMUT_OK" "$NMUT" "$NCTRL_OK" "$NCTRL" "$NEQ_OK" "$NEQ" "$([ $Z0OK = 1 ] && echo ok || echo FAILED)" "$NT" "$NMISMATCH"
printf 'scratch: %s\n' "$RUNROOT"
if [ $((NCTRL + NMUT + NEQ + 1)) -ne "$NT" ]; then
  echo "HARNESS FAILURE: row classes do not add up to the row count"; exit 1
fi
[ $Z0SEEN = 1 ] && [ $Z0OK = 1 ] || { echo "HARNESS FAILURE: Z0 did not report BADMUT"; exit 1; }
[ $NMISMATCH = 0 ] || { echo "HARNESS FAILURE: $NMISMATCH row(s) MISMATCHED"; exit 1; }
