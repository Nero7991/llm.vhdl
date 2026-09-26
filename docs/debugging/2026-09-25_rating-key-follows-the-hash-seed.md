# The rating cache key followed PYTHONHASHSEED for two-clock rows

## The question

2026-09-25, workstation, `tools/rate/rate.py status` (block-ratings plan, Task 8),
tree at 3559dc6 plus the uncommitted `status` subcommand. The a_engine rating record
(`hw/targets/ratings/vu33p_fk33/a_engine.QWEN35_9B.json`, key `aaf1aa7175fa...`) read
STALE on one `status` call and FRESH on the next identical call, with no file changed.

## The answer

`tools/rate/shell.py:gen_shell` iterated `set(row["clocks"])`. A set of strings iterates
in an order fixed by the per-process hash seed, so a row with TWO clocks (a_engine:
`s_axi_aclk`, `m_aclk`) got its shell text in a random order, and the shell text is an
input to the key. Single-clock rows were unaffected, which is why c_kv and calib never
flapped. Fixed with `sorted(...)`.

## The procedure

1. `status` three times from the repo: FRESH, FRESH, FRESH. Earlier call: STALE.
2. `status` from `/tmp`: STALE. From the repo again: FRESH. (Looked like a cwd effect.)
3. `current_key` computed in-process, three times: all equal to the record.
4. GHDL `--elab-order` with the persistent probe library vs a fresh one: identical lists.
5. Instrumented `key.rating_key` to print every input (deps, shell hash, harness, tree),
   ran it 8 times in 8 processes, from one directory: 5 gave `aaf1aa71`, 3 gave
   `a3082427`. `diff` of an `aaf1` dump against an `a308` dump: ONLY the `SHELL` line.
   This controls for cwd (same directory throughout) and for the library (same workdir).
6. `grep -n clocks tools/rate/shell.py` -> line 66 `clocks = set(row["clocks"])`.

## The evidence

```
      3 a3082427722c
      5 aaf1aa7175fa
13c13
< SHELL ffb698d7d0c8
---
> SHELL 22a1c2b6380b
```

Test `test_shell_text_does_not_depend_on_the_hash_seed` (8 values of PYTHONHASHSEED):
FAIL before the fix, PASS after.

## Measured and REJECTED -- do not retry

- **Working directory.** STALE-from-/tmp and FRESH-from-repo was a coincidence of two
  draws; step 5 ran from one directory and still split 5/3.
- **Stale state in the persistent GHDL probe library.** `--elab-order` output was
  identical from the persistent and a fresh library, and a test seeding the library with
  a stale copy of `util_pkg.vhd` passed before any change. A "fresh library per call"
  change was written on this hypothesis and then reverted.

## Measurement traps hit

- A fresh-library change was made and the very next `status` read STALE, which looked
  like evidence that library state mattered. It was one more coin toss.
- Every observation came from a separate `python3` process, so each was a new seed.
  In-process repeats (step 3) all agreed, which hid the defect.

## Consequence

The fix changes `shell.py`, which is part of the harness hash, so every rating record
was re-keyed and re-rated. The earlier a_engine rating (192.7 MHz on -2LV) was taken
with one of the two shell orders; the design is the same netlist either way (only the
order of register declarations differs), so it is not suspected wrong, only mis-keyed.

## Open

- ~~Whether the two shell orders produce identical routed results was not measured.~~
  Answered below.

## CORRECTION 2026-09-25 (same evening): the two shell orders do NOT route identically

Re-rated after the fix (MEASURED, `_t8/chain.sh`): the eight calib depths and c_kv, all
single-clock, reproduced their earlier `achieved_mhz` to the printed digit. a_engine,
whose shell order was the only thing that changed, went from **192.7 to 185.5 MHz**
(-2LV, both routed, over-constrained at 3.0 ns): 0.20 ns, inside the 0.4-0.75 ns routed
noise floor. So the claim above that the old rating was "not suspected wrong, only
mis-keyed" stands only in the sense that neither draw is more right than the other: a
declaration-order change is enough to move a routed result by 0.2 ns, which is one more
measurement of the floor, not of the design.
