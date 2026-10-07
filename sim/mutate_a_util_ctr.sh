#!/usr/bin/env bash
# Mutation test for rtl/a_util_ctr.vhd: teeth for sim/tb_a_util_ctr.vhd.
# Jungle Cat engine composition, Task 1, 2026-10-07.
#
# Rows (each must be KILLED by the bench, judged by sim/mutverdict.py, so a
# run that dies before the checker reaches a verdict is ABORT, not a kill):
#   CTRL  unmutated                                       must PASS
#   MA    beats counted with in_job ignored               must be KILLED
#   MB    per-port counters count cycles, not beats       must be KILLED
#   MC    high read returns the LIVE high word, not hi_q  must be KILLED
#   MD    clr also clears hi_q and rd_q (fix round 1)     must be KILLED
#
# The sources are copied ONCE into the scratch tree before the first row, so
# every row is judged against the same text and a concurrent edit in the repo
# cannot reach a run.  Nothing here writes into the repository.
#
# Usage:  bash sim/mutate_a_util_ctr.sh        Env: SCRATCH=<dir>
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
SCRATCH="${SCRATCH:-$HOME/regress_scratch/mutate_a_util_ctr}"
mkdir -p "$SCRATCH/src" || exit 2
cp "$REPO/rtl/a_util_ctr.vhd" "$SCRATCH/src/a_util_ctr.vhd" || exit 2
cp "$REPO/sim/tb_a_util_ctr.vhd" "$SCRATCH/src/tb_a_util_ctr.vhd" || exit 2
MUTV="$REPO/sim/mutverdict.py"
TB=tb_a_util_ctr

# mutate <tag> : writes $SCRATCH/<tag>/a_util_ctr.vhd from the snapshot.
# Every replacement must match EXACTLY ONCE or the row is refused, so a
# drifted source cannot produce a silent no-op mutant that "survives".
mutate() {
  local tag="$1" dst="$SCRATCH/$1"
  mkdir -p "$dst"
  python3 - "$SCRATCH/src/a_util_ctr.vhd" "$dst/a_util_ctr.vhd" "$tag" <<'PY'
import sys
src, dst, tag = sys.argv[1:4]
s = open(src).read()
MUT = {
  "CTRL": [],
  "MA": [("""      elsif in_job = '1' then
        for i in 0 to NP-1 loop
          if rbeat(i) = '1' then cnt(i) <= cnt(i) + 1; end if;
        end loop;
        cnt(NP) <= cnt(NP) + 1;
      end if;""",
          """      else
        for i in 0 to NP-1 loop
          if rbeat(i) = '1' then cnt(i) <= cnt(i) + 1; end if;
        end loop;
        if in_job = '1' then cnt(NP) <= cnt(NP) + 1; end if;
      end if;""")],
  "MB": [("if rbeat(i) = '1' then cnt(i)", "if true then cnt(i)")],
  "MD": [("""      if rst = '1' then
        hi_q <= (others => '0');""",
          """      if rst = '1' or clr = '1' then
        hi_q <= (others => '0');""")],
  "MC": [("rd_q <= x\"0000\" & hi_q;",
          "rd_q <= x\"0000\" & std_logic_vector(cnt(ix)(47 downto 32));")],
}
for a, b in MUT[tag]:
    n = s.count(a)
    if n != 1:
        sys.stderr.write("REFUSED %s: pattern matched %d times\n" % (tag, n))
        sys.exit(3)
    s = s.replace(a, b)
open(dst, "w").write(s)
PY
}

run_row() {
  local tag="$1" want="$2" d="$SCRATCH/$1" rc v
  if ! mutate "$tag"; then
    echo "ROW $tag  REFUSED (mutation did not apply)"; BAD=1; return
  fi
  ( cd "$d" && rm -f work-obj08.cf &&
    ghdl -a --std=08 a_util_ctr.vhd "$SCRATCH/src/tb_a_util_ctr.vhd" &&
    ghdl -e --std=08 "$TB" ) > "$d/build.log" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ROW $tag  ABORT(ELAB)  see $d/build.log"; BAD=1; return
  fi
  ( cd "$d" && ghdl -r --std=08 "$TB" --stop-time=1ms ) > "$d/run.log" 2>&1
  rc=$?
  v="$(python3 "$MUTV" "$d/run.log" "$TB" "$rc" 2>/dev/null | head -1)"
  echo "ROW $tag  want=$want  verdict: $v"
  case "$want:$v" in
    PASS:PASS*)     ;;
    KILLED:KILLED*) ;;
    *) BAD=1 ;;
  esac
}

BAD=0
run_row CTRL PASS
run_row MA KILLED
run_row MB KILLED
run_row MC KILLED
run_row MD KILLED
if [ $BAD -eq 0 ]; then
  echo "MUTATE_A_UTIL_CTR: ALL ROWS AS EXPECTED"
else
  echo "MUTATE_A_UTIL_CTR: FAIL"
  exit 1
fi
