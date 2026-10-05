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
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
GHDL=${GHDL:-ghdl}
RUNROOT=/mnt/storage/fk33_builds/scratch/mutate_jc_loader_$(date +%Y%m%d_%H%M%S)_$$
mkdir -p "$RUNROOT"
DEPS="rtl/util_pkg.vhd rtl/jc_loader_pkg.vhd rtl/async_fifo.vhd rtl/jc_frame_core.vhd rtl/jc_hbm_writer.vhd rtl/jc_hbm_crc.vhd rtl/jc_status_sync.vhd rtl/jc_loader_core.vhd sim/jc_axi3_mem.vhd"
NK=0; NS=0; NB=0; NT=0; Z0SEEN=0

run_row() {   # run_row <tag> <class> <rtlfile> <bench> <desc> <old> <new>
  local tag=$1 cls=$2 file=$3 tb=$4 desc=$5 old=$6 new=$7
  local dir=$RUNROOT/$tag
  NT=$((NT+1))
  mkdir -p "$dir/work" "$dir/run"
  cp "$REPO/sim/"jc_*_vec.txt "$dir/run/"
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
    if [ "$tag" = Z0 ]; then Z0SEEN=1; printf '%-4s %-5s BADMUT   (required for the self-teeth row)\n' "$tag" "$cls"
    else NB=$((NB+1)); printf '%-4s %-5s BADMUT   THIS ROW TESTED NOTHING -- %s\n' "$tag" "$cls" "$desc"; fi
    return
  fi
  local f ok=1
  for f in $DEPS; do
    if [ "$f" = "$file" ]; then f="$dir/$(basename "$file")"; else f="$REPO/$f"; fi
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$f" >>"$dir/analyze.log" 2>&1 || ok=0
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/sim/$tb.vhd" >>"$dir/analyze.log" 2>&1 || ok=0
  if [ $ok = 0 ]; then
    printf '%-4s %-5s DID NOT ANALYZE -- %s\n' "$tag" "$cls" "$desc"; return
  fi
  ( cd "$dir/run" && timeout 900 "$GHDL" -r --std=08 -frelaxed --workdir="$dir/work" "$tb" \
      --stop-time=40ms ) >"$dir/log" 2>&1
  if grep -q "PASS: $tb" "$dir/log"; then
    NS=$((NS+1)); printf '%-4s %-5s SURVIVED %s -- %s\n' "$tag" "$cls" "$tb" "$desc"
  else
    NK=$((NK+1)); printf '%-4s %-5s KILLED   %s -- %s\n' "$tag" "$cls" "$tb" "$desc"
  fi
}

# control: the unmutated tree must pass every bench (a no-op patch on a unique anchor)
for tb in tb_jc_crc32 tb_jc_frame_core tb_jc_hbm_writer tb_jc_hbm_crc tb_jc_loader_core tb_jc_loader_ovf; do
  run_row "C_$tb" CTRL rtl/jc_loader_pkg.vhd "$tb" "control, no change" "x\"EDB88320\"" "x\"EDB88320\""
done

run_row Z0 AUDIT rtl/jc_loader_pkg.vhd tb_jc_crc32 "self-teeth: anchor not in the file" "THIS TEXT IS NOT IN THE FILE" "x"
run_row M1 VALUE rtl/jc_loader_pkg.vhd tb_jc_crc32 "CRC polynomial one bit off" "x\"EDB88320\"" "x\"EDB88321\""
run_row M2 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core "verdict ignores the CRC" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"
run_row M3 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core "magic not checked" "if word(31 downto 0) = JC_MAGIC_FRAME" "if true"
run_row M4 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core "one payload word too many" "widx <= to_integer(nwords)" "widx <= to_integer(nwords) + 1"
run_row M5 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core "desync not counted" "desync <= desync + 1;" "null;"
run_row M6 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "commit on FAIL" "if tag = TAG_PASS and unsigned" "if unsigned"
run_row M7 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "seq check removed" "elsif diff = 0 then" "elsif true then"
run_row M8 PROTO rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "17-beat bursts" "n := to_unsigned(16, 8);" "n := to_unsigned(17, 8);"
run_row M9 PROTO rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "4 KB rule off" "if to4k < n then n := to4k; end if;" "null;"
run_row M10 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "BRESP errors not counted" "n_bresp <= n_bresp + 1;" "null;"
run_row M11 VALUE rtl/jc_hbm_crc.vhd tb_jc_hbm_crc "CRC unit skips the last 32-bit lane" "if k = 7 then" "if k = 6 then"
run_row M12 PROTO rtl/jc_hbm_crc.vhd tb_jc_hbm_crc "read bursts ignore 4 KB" "if to4k < n then n := to4k; end if;" "null;"
run_row M13 CDC   rtl/jc_status_sync.vhd tb_jc_loader_core "status never updates in TCK" "st_r <= snap;" "null;"
run_row M14 VALUE rtl/jc_loader_core.vhd tb_jc_loader_core "range result not in status" "live(223 downto 192) <= res_crc;" "live(223 downto 192) <= (others => '0');"
# attribution: the writer bench must NOT see a frame-core mutant (it bypasses the core)
run_row A1 ATTR rtl/jc_frame_core.vhd tb_jc_hbm_writer "M2 against a bench without the core" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"
# attribution: the end-to-end bench must also kill the frame-core CRC mutant on its own
run_row A2 ATTR rtl/jc_frame_core.vhd tb_jc_loader_core "M2 seen end to end" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"

# --- rows added 2026-10-05: reviewed by hand, now owned by the harness (see header) ---
run_row M15 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "lost-verdict branch keeps the OLD header instead of reloading" \
"              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart
                n_crc <= n_crc + 1;
                h_seq <= unsigned(d(63 downto 32)); h_addr <= unsigned(d(103 downto 64));
                h_nw <= unsigned(d(119 downto 104)); h_flags <= d(135 downto 120);
                h_rlen <= unsigned(d(175 downto 136)); cnt <= (others => '0');" \
"              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart
                n_crc <= n_crc + 1;
                cnt <= (others => '0');"
run_row M16 VALUE rtl/jc_hbm_writer.vhd tb_jc_loader_ovf "lost-verdict branch does not count the failure" \
"              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart
                n_crc <= n_crc + 1;" \
"              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart"
run_row M17 VALUE rtl/jc_frame_core.vhd tb_jc_loader_ovf "ovf_seen never set" "        ovf <= '1';" "        null;"
run_row M18 VALUE rtl/jc_loader_core.vhd tb_jc_loader_core "live(177) wired to a constant instead of the trip sync" "  live(177)            <= trip_s2;" "  live(177)            <= '0';"
run_row M19 VALUE rtl/jc_hbm_crc.vhd tb_jc_hbm_crc "rresp error flag never set" "              if rresp /= \"00\" then rerr <= '1'; end if;" "              null;"
# attribution: tb_jc_hbm_crc never elaborates jc_loader_core, so it cannot see M18
run_row A3 ATTR rtl/jc_loader_core.vhd tb_jc_hbm_crc "M18 against a bench without the core" "  live(177)            <= trip_s2;" "  live(177)            <= '0';"
# attribution: tb_jc_loader_core's vector never injects a bad RRESP on the range-CRC path,
# so the end-to-end bench cannot see M19; tb_jc_hbm_crc (above) is the bench that owns it.
run_row A4 ATTR rtl/jc_hbm_crc.vhd tb_jc_loader_core "M19 against the end-to-end bench, which never injects a bad RRESP" "              if rresp /= \"00\" then rerr <= '1'; end if;" "              null;"

printf 'kill ratio: %d KILLED of %d rows; %d SURVIVED; %d BADMUT\n' "$NK" "$NT" "$NS" "$NB"
printf 'scratch: %s\n' "$RUNROOT"
[ $Z0SEEN = 1 ] || { echo "HARNESS FAILURE: Z0 did not report BADMUT"; exit 1; }
