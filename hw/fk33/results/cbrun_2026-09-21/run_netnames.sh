#!/usr/bin/env bash
# TRACK CBRUN -- run cbrun_netnames.tcl over the four post-opt checkpoints, one
# at a time, capped and verified exactly as the draws were.
set -u
RUN="${CBN_RUN:?CBN_RUN required}"
CAP="${CBN_CAP:-8G}"
ARMS="${CBN_ARMS:-old new bcast fan}"
TCL="$RUN/../cbrun_netnames.tcl"
VIV=/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh

say() { echo "CBN $(date -Is) $*"; }
die() { echo "CBN_ABORT: $*" >&2; exit 9; }

[ -f "$TCL" ] || die "no tcl at $TCL"

vivado_present() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*) return 0;; esac
  done
  return 1
}
if vivado_present; then die "a Vivado is present on this box; it holds ONE"; fi
. "$VIV"
command -v vivado >/dev/null || die "no vivado on PATH"

for a in $ARMS; do
  dcp="$RUN/out_$a/post_opt_cb_$a.dcp"
  out="$RUN/netnames_$a"
  log="$RUN/netnames_$a.log"
  [ -f "$dcp" ] || { say "SKIP arm=$a: no checkpoint"; continue; }
  mkdir -p "$out"
  cat > "$out/wrap.sh" <<WRAP
cg=\$(sed -n 's/^0::\(.*\)\$/\1/p' /proc/self/cgroup)
hi=\$(cat "/sys/fs/cgroup\${cg}/memory.high" 2>/dev/null || echo MISSING)
echo "CBN_CAP_READBACK cgroup=\$cg memory.high=\$hi"
if [ "\$hi" = "max" ] || [ "\$hi" = "MISSING" ]; then
  echo "CBN_CAP_ABORT no memory.high on this scope; refusing to exec vivado"
  exit 7
fi
exec vivado -mode batch -nojournal -log "$out/vivado.log" -source "$TCL"
WRAP
  say "=== netnames arm=$a begin ==="
  ( cd "$out" && CBN_DCP="$dcp" CBN_TAG="cb_$a" \
      systemd-run --user --scope --quiet --unit="cbn_${a}_$$" \
      -p MemoryHigh="$CAP" -p MemoryMax=11G bash "$out/wrap.sh" ) > "$log" 2>&1
  rc=$?
  grep -E "^CBN_CAP_READBACK|^CBN_CAP_ABORT" "$log" || say "NO CAP READBACK arm=$a"
  if ! grep -qE "^CBN_DONE cb_$a\$" "$log"; then
    say "FAIL arm=$a rc=$rc (no line-anchored CBN_DONE)"
    grep -E "^ERROR|^CBN_ABORT" "$log" | head -5
    tail -15 "$log"
    continue
  fi
  say "OK arm=$a rc=$rc"
  grep -E "^CBN_(BEGIN|CBWCELLS|DNETS|NET|CBCELLS|RAMIN|TOTAL|CENSUS) " "$log"
done
say "NETNAMES_ALLDONE"
