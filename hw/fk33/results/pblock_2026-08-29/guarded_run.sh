#!/bin/bash
# guarded_run.sh <tag> <tcl-file> <limit_kb>
# Launches vivado -mode batch in its OWN session/process group, records the
# pgid, and polls the SUM of RSS over that pgid.  Kills the whole group if the
# sum exceeds <limit_kb>.  Prints the peak RSS it observed.
#
# Traps this works around (CONGEST, 2026-08-29):
#   - `ps -o rss= -g <pgid>` does NOT select by process group.  Use
#     `ps -eo pgid=,rss=` and filter in awk.
#   - `setsid bash -c 'exec vivado ...'` does not give $! the vivado pgid.
#     So the inner script records its own $$ AFTER setsid has made it the
#     session/group leader, and then execs vivado into that same pid.
set -uo pipefail
TAG="$1"; TCL="$2"; LIMIT_KB="$3"
DIR="$(cd "$(dirname "$TCL")" && pwd)"
RUNDIR="$DIR/run_$TAG"
mkdir -p "$RUNDIR"
PGIDFILE="$RUNDIR/pgid"
rm -f "$PGIDFILE"

cat > "$RUNDIR/inner.sh" <<INNER
#!/bin/bash
echo \$\$ > "$PGIDFILE"
cd "$RUNDIR"
exec vivado -mode batch -nojournal -log "$RUNDIR/vivado.log" -source "$TCL"
INNER
chmod +x "$RUNDIR/inner.sh"

setsid bash "$RUNDIR/inner.sh" > "$RUNDIR/stdout.txt" 2>&1 &
for i in $(seq 1 100); do [ -s "$PGIDFILE" ] && break; sleep 0.2; done
PGID=$(cat "$PGIDFILE" 2>/dev/null || echo "")
if [ -z "$PGID" ]; then echo "GUARD FATAL: no pgid recorded"; exit 90; fi
echo "GUARD tag=$TAG pgid=$PGID limit_kb=$LIMIT_KB"

PEAK=0
SAW_NONZERO=0
while kill -0 -"$PGID" 2>/dev/null; do
  RSS=$(ps -eo pgid=,rss= | awk -v g="$PGID" '$1==g {s+=$2} END{print s+0}')
  [ "$RSS" -gt 0 ] && SAW_NONZERO=1
  [ "$RSS" -gt "$PEAK" ] && PEAK=$RSS
  if [ "$RSS" -gt "$LIMIT_KB" ]; then
    echo "GUARD TRIP: rss_kb=$RSS > $LIMIT_KB -- killing pgid $PGID"
    kill -9 -"$PGID" 2>/dev/null
    echo "GUARD peak_kb=$PEAK saw_nonzero=$SAW_NONZERO"
    exit 91
  fi
  sleep 5
done
wait %1
RC=$?
echo "GUARD done tag=$TAG rc=$RC peak_kb=$PEAK peak_gb=$(awk -v p=$PEAK 'BEGIN{printf "%.2f", p/1048576}') saw_nonzero=$SAW_NONZERO"
exit $RC
