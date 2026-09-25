#!/usr/bin/env bash
# Build 21 watcher.  Gates on the SENTINEL THE WORK ITSELF WRITES
# (^FK33_BUILD_DONE), line-anchored, and reports "UNIT ENDED WITHOUT SENTINEL"
# as a FAILURE rather than treating the unit ending as completion.
B=/mnt/storage/fk33_builds/build21
U=card21-build.service
while :; do
  d=$(grep -c '^FK33_BUILD_DONE' $B/build.stdout 2>/dev/null)
  a=$(systemctl --user is-active $U)
  printf "%s active=%s done=%s swap=%sG stgfree=%s\n" "$(date +%H:%M)" "$a" "$d" \
    "$(free -g | awk '/Swap/{print $3}')" \
    "$(df -BG --output=avail /mnt/storage | tail -1 | tr -dc '0-9')G" >> $B/watch.log
  # LEVERGUARD: build 21 has C's two levers ON and FAST_POP, NWIDE OFF; either of those bound to 1 is a wrong build.
  lv=$(grep -acE 'Parameter (FAST_POP|NWIDE) bound to: 1' $B/build.stdout 2>/dev/null)
  if [ "$lv" -ge 1 ]; then echo "LEVERGUARD KILL: $lv lever(s) bound to 1" >> $B/watch.log; systemctl --user kill $U; touch $B/ENDED; exit 1; fi
  if [ "$d" -ge 1 ] || [ "$a" != active ]; then
    if [ "$d" -ge 1 ]; then echo "BUILD SENTINEL PRESENT"; else echo "UNIT ENDED WITHOUT SENTINEL: FAILURE"; fi >> $B/watch.log
    grep -E "^(FK33_TIMING|FK33_CB_STYLE|ERROR)" $B/build.stdout 2>/dev/null | head -6 >> $B/watch.log
    touch $B/ENDED; exit 0
  fi
  sleep 120
done
