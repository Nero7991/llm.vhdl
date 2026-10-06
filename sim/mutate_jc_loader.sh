#!/usr/bin/env bash
# Mutation teeth for the Jungle Cat loader (plan Task 7). Each row patches ONE anchor in
# ONE rtl file (the anchor must match exactly once), analyzes the closure into a fresh
# per-run directory and runs the named bench. KILLED = the bench reported FAIL or did not
# print its PASS line. Attribution rows (class ATTR) run a mutant against a bench that
# should NOT see it, to show which bench owns the kill.
# No rm anywhere: every row writes into a new directory under one per-run root.
#
# Rows added 2026-10-05 beyond the plan's Task 7 brief (reviews killed these by hand; the
# harness now owns them -- see the per-row desc strings for what each one is):
#   C_tb_jc_loader_ovf  the unmutated tree against the new end-to-end overflow bench.
#   M15  jc_hbm_writer's lost-verdict branch keeps the OLD header instead of reloading.
#   M16  jc_hbm_writer's lost-verdict branch does not count the failure.
#   M17  jc_frame_core never sets ovf_seen.
#   M18  jc_loader_core wires live(177) to a constant instead of the trip_s2 sync output.
#   M19  jc_hbm_crc never sets its rresp error flag.
#   A3   M18 against tb_jc_hbm_crc, which never elaborates jc_loader_core at all --
#        EXPECTED SURVIVED, same shape as A1.
#   A4   M19 against tb_jc_loader_core, whose vector never injects a bad RRESP on the
#        range-CRC path (sim/jc_loader_vec.txt has no BAD_RRESP_ADDR case) -- EXPECTED
#        SURVIVED, showing tb_jc_hbm_crc (which does inject one) is the bench that owns
#        this kill, not the end-to-end bench.
#
# Rows added by Task 9b (DNA_PORTE2 die identity, 384-bit status):
#   C_tb_jc_dna_reader  the unmutated tree against the new reader bench.
#   M20  jc_dna_reader assembles the bits in the reversed order (first bit out -> dna(95)).
#   M21  jc_dna_reader never raises dna_valid (owning bench: tb_jc_dna_reader).
#   M22  the same mutant seen end to end by tb_jc_loader_core.
#   M23  jc_loader_core ties the status DNA field to zero instead of the reader's value.
#   M24  jc_dna_reader changes READ/SHIFT on the dna_clk RISING edge instead of the
#        falling one; the values still come out right, so only sim/jc_dna_model.vhd's
#        setup/hold counter can kill it.
#   M25  jc_dna_reader's default DIV drops to 4 (dna_clk 56 MHz at a 450 MHz aclk).
#   M26  jc_frame_core drops status bits 383:256 (shifts a 256-bit word as before).
#   M27  jc_frame_core shifts ones in behind the status (TDO past bit 383 not zero).
#   M28  jc_loader_core ties live(352) (dna_valid) to '1' (fix round 1, M4: killed by
#        tb_jc_loader_core's first-status check, dna_valid clear before the read ends).
#   M29  jc_dna_reader presents the assembly register instead of the latched value
#        (dna non-zero before dna_valid; reviewer's R3 shape).
#   A5   M23 against tb_jc_dna_reader, which never elaborates jc_loader_core --
#        EXPECTED SURVIVED.
#   A6   M20 against tb_jc_loader_core: the end-to-end bench must see a reversed DNA
#        too -- EXPECTED KILLED.
#
# Fix round 1 (2026-10-05, review): every row now carries an EXPECTED outcome and the row
# is printed as "<tag> <result> expected <exp> OK|MISMATCH". A check nothing refuses on is
# decoration in this project, so a mismatched row is not just noted -- the script exits 1
# if ANY row mismatches (DID NOT ANALYZE is always a mismatch, whatever was expected) and
# still exits 1 if Z0 does not report BADMUT. The PASS grep is anchored to GHDL's own
# "(report note): PASS: <tb> checks=" text as a fixed string, so it cannot be fooled by a
# vector file or patch log that happens to contain the substring "PASS: <tb>" elsewhere.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
GHDL=${GHDL:-ghdl}
RUNROOT=/mnt/storage/fk33_builds/scratch/mutate_jc_loader_$(date +%Y%m%d_%H%M%S)_$$
mkdir -p "$RUNROOT"
DEPS="rtl/util_pkg.vhd rtl/jc_loader_pkg.vhd rtl/async_fifo.vhd rtl/jc_frame_core.vhd rtl/jc_hbm_writer.vhd rtl/jc_hbm_crc.vhd rtl/jc_status_sync.vhd rtl/jc_dna_reader.vhd rtl/jc_loader_core.vhd sim/jc_axi3_mem.vhd sim/jc_dna_model.vhd"
NT=0; NMISMATCH=0; Z0SEEN=0; Z0OK=0
NCTRL=0; NCTRL_OK=0
NMUT=0;  NMUT_OK=0
NATTR=0; NATTR_OK=0

run_row() {   # run_row <tag> <class> <rtlfile> <bench> <expected> <desc> <old> <new>
  local tag=$1 cls=$2 file=$3 tb=$4 exp=$5 desc=$6 old=$7 new=$8
  local dir=$RUNROOT/$tag
  NT=$((NT+1))
  mkdir -p "$dir/work" "$dir/run"
  cp "$REPO/sim/"jc_*_vec.txt "$dir/run/"
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
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/sim/$tb.vhd" >>"$dir/analyze.log" 2>&1 || ok=0
    if [ $ok = 0 ]; then
      res="DID NOT ANALYZE"
    else
      ( cd "$dir/run" && timeout 900 "$GHDL" -r --std=08 -frelaxed --workdir="$dir/work" "$tb" \
          --stop-time=40ms ) >"$dir/log" 2>&1
      # Fixed-string match on GHDL's own report line, not a bare substring: the real line
      # reads "<file>:<line>:<col>:@<time>:(report note): PASS: <tb> checks=<n>" and nothing
      # else in a bench's output or a vector file can produce that exact "(report note):
      # PASS: <tb> checks=" text.
      if grep -qF "(report note): PASS: $tb checks=" "$dir/log"; then
        res=SURVIVED
      else
        res=KILLED
      fi
    fi
  fi

  case "$cls" in
    CTRL) NCTRL=$((NCTRL+1));;
    VALUE|PROTO|CDC) NMUT=$((NMUT+1));;
    ATTR) NATTR=$((NATTR+1));;
  esac

  # DID NOT ANALYZE tested nothing, so it is always a mismatch no matter what was expected.
  if [ "$res" = "DID NOT ANALYZE" ]; then
    mismatch=1
  elif [ "$res" = "$exp" ]; then
    mismatch=0
  else
    mismatch=1
  fi

  local verdict
  if [ $mismatch = 1 ]; then
    verdict=MISMATCH
    NMISMATCH=$((NMISMATCH+1))
  else
    verdict=OK
    case "$cls" in
      CTRL)  NCTRL_OK=$((NCTRL_OK+1));;
      VALUE|PROTO|CDC) NMUT_OK=$((NMUT_OK+1));;
      ATTR)  NATTR_OK=$((NATTR_OK+1));;
      AUDIT) Z0OK=1;;
    esac
  fi

  printf '%-4s %-16s expected %-16s %-8s -- %-5s %-18s %s\n' \
    "$tag" "$res" "$exp" "$verdict" "$cls" "$tb" "$desc"
}

# control: the unmutated tree must pass every bench (a no-op patch on a unique anchor)
for tb in tb_jc_crc32 tb_jc_frame_core tb_jc_hbm_writer tb_jc_hbm_crc tb_jc_loader_core tb_jc_loader_ovf tb_jc_dna_reader; do
  run_row "C_$tb" CTRL rtl/jc_loader_pkg.vhd "$tb" SURVIVED "control, no change" "x\"EDB88320\"" "x\"EDB88320\""
done

run_row Z0 AUDIT rtl/jc_loader_pkg.vhd tb_jc_crc32 BADMUT "self-teeth: anchor not in the file" "THIS TEXT IS NOT IN THE FILE" "x"
run_row M1 VALUE rtl/jc_loader_pkg.vhd tb_jc_crc32 KILLED "CRC polynomial one bit off" "x\"EDB88320\"" "x\"EDB88321\""
run_row M2 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core KILLED "verdict ignores the CRC" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"
run_row M3 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core KILLED "magic not checked" "if word(31 downto 0) = JC_MAGIC_FRAME" "if true"
run_row M4 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core KILLED "one payload word too many" "widx <= to_integer(nwords)" "widx <= to_integer(nwords) + 1"
run_row M5 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core KILLED "desync not counted" "desync <= desync + 1;" "null;"
run_row M6 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer KILLED "commit on FAIL" "if tag = TAG_PASS and unsigned" "if unsigned"
run_row M7 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer KILLED "seq check removed" "elsif diff = 0 then" "elsif true then"
run_row M8 PROTO rtl/jc_hbm_writer.vhd tb_jc_hbm_writer KILLED "17-beat bursts" "n := to_unsigned(16, 8);" "n := to_unsigned(17, 8);"
run_row M9 PROTO rtl/jc_hbm_writer.vhd tb_jc_hbm_writer KILLED "4 KB rule off" "if to4k < n then n := to4k; end if;" "null;"
run_row M10 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer KILLED "BRESP errors not counted" "n_bresp <= n_bresp + 1;" "null;"
run_row M11 VALUE rtl/jc_hbm_crc.vhd tb_jc_hbm_crc KILLED "CRC unit skips the last 32-bit lane" "if k = 7 then" "if k = 6 then"
run_row M12 PROTO rtl/jc_hbm_crc.vhd tb_jc_hbm_crc KILLED "read bursts ignore 4 KB" "if to4k < n then n := to4k; end if;" "null;"
run_row M13 CDC   rtl/jc_status_sync.vhd tb_jc_loader_core KILLED "status never updates in TCK" "st_r <= snap;" "null;"
run_row M14 VALUE rtl/jc_loader_core.vhd tb_jc_loader_core KILLED "range result not in status" "live(223 downto 192) <= res_crc;" "live(223 downto 192) <= (others => '0');"
# attribution: the writer bench must NOT see a frame-core mutant (it bypasses the core)
run_row A1 ATTR rtl/jc_frame_core.vhd tb_jc_hbm_writer SURVIVED "M2 against a bench without the core" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"
# attribution: the end-to-end bench must also kill the frame-core CRC mutant on its own
run_row A2 ATTR rtl/jc_frame_core.vhd tb_jc_loader_core KILLED "M2 seen end to end" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"

# --- rows added 2026-10-05: reviewed by hand, now owned by the harness (see header) ---
run_row M15 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer KILLED "lost-verdict branch keeps the OLD header instead of reloading" \
"              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart
                n_crc <= n_crc + 1;
                h_seq <= unsigned(d(63 downto 32)); h_addr <= unsigned(d(103 downto 64));
                h_nw <= unsigned(d(119 downto 104)); h_flags <= d(135 downto 120);
                h_rlen <= unsigned(d(175 downto 136)); cnt <= (others => '0');" \
"              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart
                n_crc <= n_crc + 1;
                cnt <= (others => '0');"
run_row M16 VALUE rtl/jc_hbm_writer.vhd tb_jc_loader_ovf KILLED "lost-verdict branch does not count the failure" \
"              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart
                n_crc <= n_crc + 1;" \
"              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart"
run_row M17 VALUE rtl/jc_frame_core.vhd tb_jc_loader_ovf KILLED "ovf_seen never set" "        ovf <= '1';" "        null;"
run_row M18 VALUE rtl/jc_loader_core.vhd tb_jc_loader_core KILLED "live(177) wired to a constant instead of the trip sync" "  live(177)            <= trip_s2;" "  live(177)            <= '0';"
run_row M19 VALUE rtl/jc_hbm_crc.vhd tb_jc_hbm_crc KILLED "rresp error flag never set" "              if rresp /= \"00\" then rerr <= '1'; end if;" "              null;"
# attribution: tb_jc_hbm_crc never elaborates jc_loader_core, so it cannot see M18
run_row A3 ATTR rtl/jc_loader_core.vhd tb_jc_hbm_crc SURVIVED "M18 against a bench without the core" "  live(177)            <= trip_s2;" "  live(177)            <= '0';"
# attribution: tb_jc_loader_core's vector never injects a bad RRESP on the range-CRC path,
# so the end-to-end bench cannot see M19; tb_jc_hbm_crc (above) is the bench that owns it.
run_row A4 ATTR rtl/jc_hbm_crc.vhd tb_jc_loader_core SURVIVED "M19 against the end-to-end bench, which never injects a bad RRESP" "              if rresp /= \"00\" then rerr <= '1'; end if;" "              null;"

# --- rows added by Task 9b (see header) ---
run_row M20 VALUE rtl/jc_dna_reader.vhd tb_jc_dna_reader KILLED "DNA bits assembled in reversed order" "nxt := dna_dout & sr(95 downto 1);" "nxt := sr(94 downto 0) & dna_dout;"
run_row M21 VALUE rtl/jc_dna_reader.vhd tb_jc_dna_reader KILLED "dna_valid never set" "                vld <= '1';" "                null;"
run_row M22 VALUE rtl/jc_dna_reader.vhd tb_jc_loader_core KILLED "dna_valid never set, end to end" "                vld <= '1';" "                null;"
run_row M23 VALUE rtl/jc_loader_core.vhd tb_jc_loader_core KILLED "status DNA field tied to zero" "  live(351 downto 256) <= dna;" "  live(351 downto 256) <= (others => '0');"
run_row M24 PROTO rtl/jc_dna_reader.vhd tb_jc_dna_reader KILLED "READ/SHIFT change on the dna_clk rising edge" "  constant STEP_PH : natural := 2 * DIV - 1;" "  constant STEP_PH : natural := DIV - 1;"
run_row M25 PROTO rtl/jc_dna_reader.vhd tb_jc_dna_reader KILLED "default DIV 4: dna_clk over 25 MHz at 450 MHz" "  generic(DIV : positive := 10);" "  generic(DIV : positive := 4);"
run_row M26 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core KILLED "status bits 383:256 dropped" "    variable v : std_logic_vector(JC_STATUS_BITS-1 downto 0) := st;" "    variable v : std_logic_vector(JC_STATUS_BITS-1 downto 0) := (JC_STATUS_BITS-1 downto 256 => '0') & st(255 downto 0);"
run_row M27 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core KILLED "ones shifted in behind the status" "        st_sr <= '0' & st_sr(JC_STATUS_BITS-1 downto 1);" "        st_sr <= '1' & st_sr(JC_STATUS_BITS-1 downto 1);"
run_row M28 VALUE rtl/jc_loader_core.vhd tb_jc_loader_core KILLED "dna_valid tied to 1 in the status" "  live(352)            <= dna_valid;" "  live(352)            <= '1';"
run_row M29 VALUE rtl/jc_dna_reader.vhd tb_jc_dna_reader KILLED "dna shows the partial shift register before valid" "  dna       <= val;" "  dna       <= sr;"
run_row A5 ATTR rtl/jc_loader_core.vhd tb_jc_dna_reader SURVIVED "M23 against a bench without the core" "  live(351 downto 256) <= dna;" "  live(351 downto 256) <= (others => '0');"
run_row A6 ATTR rtl/jc_dna_reader.vhd tb_jc_loader_core KILLED "M20 seen end to end" "nxt := dna_dout & sr(95 downto 1);" "nxt := sr(94 downto 0) & dna_dout;"

printf 'mutants killed %d/%d; controls passed %d/%d; attribution as expected %d/%d; self-teeth %s; rows %d; mismatches %d\n' \
  "$NMUT_OK" "$NMUT" "$NCTRL_OK" "$NCTRL" "$NATTR_OK" "$NATTR" \
  "$([ $Z0OK = 1 ] && echo ok || echo FAILED)" "$NT" "$NMISMATCH"
printf 'scratch: %s\n' "$RUNROOT"
# NT/Z0 arithmetic: every row is exactly one of CTRL, VALUE/PROTO/CDC (mutant), ATTR or the
# single AUDIT row (Z0) -- NCTRL + NMUT + NATTR + 1 must equal NT.
if [ $((NCTRL + NMUT + NATTR + 1)) -ne "$NT" ]; then
  echo "HARNESS FAILURE: row classes do not add up to the row count ($NCTRL+$NMUT+$NATTR+1 != $NT)"
  exit 1
fi
[ $Z0SEEN = 1 ] && [ $Z0OK = 1 ] || { echo "HARNESS FAILURE: Z0 did not report BADMUT"; exit 1; }
[ $NMISMATCH = 0 ] || { echo "HARNESS FAILURE: $NMISMATCH row(s) MISMATCHED"; exit 1; }
