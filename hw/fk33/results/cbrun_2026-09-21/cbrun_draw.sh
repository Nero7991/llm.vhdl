#!/usr/bin/env bash
# TRACK CBRUN, 2026-09-21 -- draw the four codebook arms on the BC-250.
#
# WHY ITS OWN DRIVER AND NOT sim/ooc_cbooc_run.sh.  That runner is TRACK
# CBOOC's, it is not this track's to edit, and it knows two arms (`old`, `new`).
# CBRAM's specification for the shelf arms is "one direct
# `vivado -mode batch -source sim/ooc_cbooc.tcl` against its own rtl/ tree" with
# the same CBO_GEN copied verbatim.  This driver does that for all FOUR arms
# through the SAME unedited tcl, so the four rows are drawn identically.  Mixing
# two launch paths would put a harness difference on the same axis as the RTL
# difference, which is the recorded "control on the wrong axis" failure.
#
# THE CAP IS VERIFIED FROM INSIDE THE CGROUP, BEFORE VIVADO IS EXEC'd.
# MEASURED by TRACK ELABCLASS hours earlier: `ssh host 'bash -s'` can carry no
# XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS, in which case
# `systemd-run --user` silently does nothing and Vivado runs UNCAPPED on a
# 14 GB box that is on no WoL watchdog.  `systemd-run`'s exit status is a fact
# about systemd-run.  So the wrapper reads back `memory.high` from its OWN
# cgroup and REFUSES TO EXEC if it is `max` or unreadable.
#
# NEVER above 11G on this box: a 12G cap made it unreachable and only a physical
# power-cycle recovered it.  This is 8G, CBOOC's figure.
#
# NOTHING IS DELETED.  No `rm` appears below and no path is interpolated into
# one.  Processes are identified by /proc/PID/exe, never by a command line.
set -u

RUN="${CBRUN_RUN:?CBRUN_RUN must be the imported run directory}"
CAP="${CBRUN_CAP:-8G}"
ARMS="${CBRUN_ARMS:-old new bcast fan}"
VIV="${CBRUN_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
TCL="$RUN/sim/ooc_cbooc.tcl"
TARGET=matvec_core
# COPIED VERBATIM from CBRAM's specification and from sim/ooc_cbooc_run.sh's
# CGEN.  CB_STYLE=distributed is load-bearing: at `regs`, CB_COPIES = CB_RANKS
# = 48 and cb_rank_of is the IDENTITY, so every arm would be the same netlist
# and the run would print four full rows measuring nothing.
GEN="BLK=32 ROWS_IF=48 MAXCOLS=17408 MAXROWS_BFP=17408 CB_ROWS_PER_COPY=1 CB_STYLE=distributed"
CLK="clk=13.333"

say() { echo "CBRUN $(date -Is) $*"; }
die() { echo "CBRUN_ABORT: $*" >&2; exit 9; }

[ -f "$TCL" ] || die "no tcl at $TCL"
[ -f "$RUN/CBRUN_MANIFEST.txt" ] || die "no CBRUN_MANIFEST.txt in $RUN"

say "HOST=$(hostname) run=$RUN cap=$CAP arms='$ARMS'"
free -m | head -3

# --- 1. THE PROVENANCE, RE-ASSERTED AFTER THE CROSSING.  The sync carries no
# .git, so sha256 against the manifest written where git lives is the only form
# of this check that survives.  A comparison needs both ends drawn from the same
# tree and the manifest is what makes that assertable rather than plausible.
for a in $ARMS; do
  want=$(sed -n "s/^sha256_${a}=//p" "$RUN/CBRUN_MANIFEST.txt")
  [ -n "$want" ] || die "manifest has no sha256_$a"
  got=$(sha256sum "$RUN/$a/rtl/matvec_core.vhd" | cut -d' ' -f1)
  [ "$want" = "$got" ] || die "arm $a sha256 $got != manifest $want"
  say "PROV arm=$a sha256=${got:0:16} ok"
done
wt=$(sed -n 's/^sha256_tcl=//p' "$RUN/CBRUN_MANIFEST.txt")
gt=$(sha256sum "$TCL" | cut -d' ' -f1)
[ "$wt" = "$gt" ] || die "tcl sha256 $gt != manifest $wt"
say "PROV tcl sha256=${gt:0:16} ok"

# --- 2. THE LANE.  Presence by /proc/PID/exe, never by a command line: this
# project has measured a command-line filter counting four bash processes and a
# grep as Vivado, and a /proc loop matching the script text searching for it.
# Presence is a lane check and not a queue; the arms below are serialised by
# being in one sequential loop, which is the queue.
vivado_present() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*) return 0;; esac
  done
  return 1
}
rss_gb() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*)
      awk -v p=$p '/VmRSS/{s+=$2} END{print s}' /proc/$p/status;; esac
  done | awk '{s+=$1} END {printf "%.2f", s/1048576}'
}
if vivado_present; then die "a Vivado is already present on this box ($(rss_gb) GB summed); this box holds ONE"; fi

[ -f "$VIV" ] || die "no $VIV"
. "$VIV"
command -v vivado >/dev/null || die "no vivado on PATH after sourcing settings64"

draw() {                        # $1 = arm
  local arm="$1" tag="cb_$1"
  local out="$RUN/out_$arm" log="$RUN/run_$arm.log"
  mkdir -p "$out"
  local t0; t0=$(date +%s)
  say "=== draw arm=$arm tag=$tag begin ==="
  # The wrapper is WRITTEN OUT rather than passed as a -c string, so no layer of
  # quoting sits between this script and the cap check it depends on.
  cat > "$out/wrap.sh" <<WRAP
cg=\$(sed -n 's/^0::\(.*\)\$/\1/p' /proc/self/cgroup)
echo "\$cg" > "$out/cgroup.txt"
hi=\$(cat "/sys/fs/cgroup\${cg}/memory.high" 2>/dev/null || echo MISSING)
mx=\$(cat "/sys/fs/cgroup\${cg}/memory.max"  2>/dev/null || echo MISSING)
echo "CBRUN_CAP_READBACK cgroup=\$cg memory.high=\$hi memory.max=\$mx"
if [ "\$hi" = "max" ] || [ "\$hi" = "MISSING" ]; then
  echo "CBRUN_CAP_ABORT the scope carries NO memory.high; refusing to exec vivado."
  echo "  An UNCAPPED Vivado on this 14 GB box, which is on no WoL watchdog, is"
  echo "  the failure TRACK ELABCLASS measured: systemd-run --user exited 0 and"
  echo "  did nothing because the ssh session carried no XDG_RUNTIME_DIR.  Its"
  echo "  exit status is a fact about systemd-run, not about the cap."
  exit 7
fi
exec vivado -mode batch -nojournal -log "$out/vivado_$tag.log" -source "$TCL"
WRAP
  (
    cd "$out" || exit 8
    CBO_TAG="$tag" CBO_TARGET="$TARGET" CBO_OUT="$out" \
    CBO_RTL="$RUN/$arm/rtl" CBO_GEN="$GEN" CBO_CLK="$CLK" \
    systemd-run --user --scope --quiet --unit="cbrun_${arm}_$$" \
      -p MemoryHigh="$CAP" -p MemoryMax=11G \
      bash "$out/wrap.sh"
  ) > "$log" 2>&1 &
  local pid=$!

  local peak=0 cur cgdir="" cgpeak=NA cgswap=NA s
  while kill -0 $pid 2>/dev/null; do
    cur=$(rss_gb); [ -z "$cur" ] && cur=0
    awk -v a="$cur" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$cur"
    if [ -z "$cgdir" ] && [ -s "$out/cgroup.txt" ]; then
      cgdir="/sys/fs/cgroup$(cat "$out/cgroup.txt")"
    fi
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.peak" ]; then
      cgpeak=$(cat "$cgdir/memory.peak")
      # memory.swap.current is a LEVEL and there is no memory.swap.peak, so it
      # must be MAXED here or the recorded figure is whatever sat in swap at the
      # last poll before exit.
      if [ -r "$cgdir/memory.swap.current" ]; then
        s=$(cat "$cgdir/memory.swap.current")
        if [ "$cgswap" = "NA" ] || [ "$s" -gt "$cgswap" ]; then cgswap="$s"; fi
      fi
    fi
    # BOX-LEVEL SWAP GUARD.  Swap in use is the leading indicator, not free RAM.
    local sw; sw=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print (t-f)/1024}' /proc/meminfo)
    if awk -v s="$sw" 'BEGIN{exit !(s>20000)}'; then
      say "SWAPGUARD box swap in use ${sw} MB > 20000; killing the scope"
      systemctl --user kill "cbrun_${arm}_$$.scope" 2>/dev/null || kill $pid
    fi
    sleep 10
  done
  wait $pid; local rc=$?
  local wall=$(( $(date +%s) - t0 ))
  local capb; capb=$(numfmt --from=iec "$CAP" 2>/dev/null || echo 0)
  local cgmb=NA swmb=NA atcap=no
  if [ "$cgpeak" != "NA" ]; then
    cgmb=$(( cgpeak / 1048576 ))
    [ "$capb" -gt 0 ] && [ $(( cgpeak * 100 )) -ge $(( capb * 99 )) ] && atcap=YES
  fi
  [ "$cgswap" != NA ] && swmb=$(( cgswap / 1048576 ))
  echo "arm=$arm tag=$tag peak_rss_gb=$peak cgroup_peak_mb=$cgmb cgroup_swap_mb=$swmb at_cap=$atcap wall_s=$wall rc=$rc" \
    | tee "$out/mem.txt"

  grep -E "^CBRUN_CAP_READBACK|^CBRUN_CAP_ABORT" "$log" || say "NO CAP READBACK LINE arm=$arm"

  # THE SENTINEL, LINE-ANCHORED.  The log contains the tcl's own source text, so
  # an unanchored grep matches the script that writes the line; that has twice
  # reported a finished synthesis seconds after launch in this project.  And
  # never gate on rc: a Vivado run can print full success and then die on a Tcl
  # error afterwards.
  if ! grep -qE "^CBOOC_DONE $tag\$" "$log"; then
    say "FAIL arm=$arm: no line-anchored CBOOC_DONE sentinel (rc=$rc wall=${wall}s)"
    grep -E "^ERROR|^CBOOC_ABORT" "$out/vivado_$tag.log" 2>/dev/null | head -10
    tail -20 "$log"
    return 1
  fi

  # --- THE PRIMARY RESULT: the recognizer, per arm, WITH ITS POSITIVE CONTROL.
  # An ABSENT message is a null result on its own; gdn_block's two rows are what
  # make it admissible, because they show the recognizer ran at all in this run.
  say "RECOG arm=$arm ---8-5859 lines, verbatim---"
  grep -E "Synth 8-5859" "$out/vivado_$tag.log" | sed 's/^/    /'
  say "RECOG arm=$arm cb_reg_rows=$(grep -c 'Synth 8-5859.*cb_reg' "$out/vivado_$tag.log") gdn_rows=$(grep -cE 'Synth 8-5859.*(qbuf|kbuf)_reg' "$out/vivado_$tag.log") total_8-5859=$(grep -c 'Synth 8-5859' "$out/vivado_$tag.log")"
  say "LOGMSG arm=$arm 8-10226=$(grep -c 'Synth 8-10226' "$out/vivado_$tag.log") 8-7186=$(grep -c 'Synth 8-7186' "$out/vivado_$tag.log")"
  grep -E "^CBOOC_(RESULT|SYNTH_VS_OPT|CENSUS|CB|FANOUT_TOP|FANOUT_CBW|CBW_PATH|INTRA|WORST_GLOBAL|WORST_CLK|ARM_MD5|GENERICS)" "$log"
  say "OK arm=$arm rc=$rc peak_rss=${peak}GB cgroup_peak=${cgmb}MB swap=${swmb}MB at_cap=$atcap wall=${wall}s"
  return 0
}

rc=0
first=1
for arm in $ARMS; do
  draw "$arm" || rc=1
  # FALSIFIER 1 FROM CBRAM'S SPECIFICATION, CHECKED BEFORE SPENDING THREE MORE
  # DRAWS: if the `old` arm shows cb_ram = 0 the geometry is wrong and NO number
  # in the run is admissible.
  if [ "$first" = 1 ] && [ "$arm" = "old" ]; then
    cbline=$(grep -E "^CBOOC_CB stage=opt " "$RUN/run_old.log" | head -1)
    say "FALSIFIER1 old :: ${cbline:-MISSING}"
    case "$cbline" in
      *"cb_ram=0 "*) die "the old arm shows cb_ram=0: the geometry is wrong and nothing drawn here is admissible (CBRAM falsifier 1)";;
    esac
  fi
  first=0
done
say "ALLDONE rc=$rc run=$RUN"
exit $rc
