# `sim/realshape_gate.sh` had been red, and nothing said so

2026-09-02. Host: this workstation, GHDL 1.0.0 mcode, `sim/realshape_gate.sh`
at commit `8e22ff3` and with that day's working tree. No hardware involved.

## 1. The question, verbatim

"Does adding the conv tap history to the GDN arena break the real-shape
elaboration gate?" -- asked because `tools/hbm_map.py::arena_sizes()` had just
grown a third per-layer term and `sim/realshape_gate.sh` is the only harness
that checks the real 9B shape against the manifest.

## 2. The answer, up front

**No, and the question could not be answered as asked, because the script was
already failing 10 of its rows before the change.** Both failures were flag
mismatches between this script and `sim/regress.sh`, in a file neither the
arena work nor anything else that week had touched:

1. **No `-frelaxed`.** Ten rows -- every row expecting `ok` -- died on
   `rtl/attn_block.vhd:1065:24: constant "g" is not visible here`.
2. **No `--max-stack-alloc=0`.** The remaining row, `all_real`, died on
   `declaration of a too large object (256 > --max-stack-alloc=128 KB)`.

With both flags the script is **PASS, 25 rows, 13 of them guards that must
refuse** -- and all 13 still refuse, so the fix did not defang them.

The conv tap change itself is neutral here: `kv_map_manifest_link` reported
`ok 16 rows` against `tools/hbm_map.py` and the manifest both before and after.

## 3. The procedure

The whole point is the order, because the first reading was wrong.

1. Ran the script on the working tree. **FAIL, 10 rows.** The obvious reading
   was that the arena change had broken it.
2. **Ran the control before touching anything.** `git worktree add` at
   `8e22ff3`, ran the same script there. **FAIL, the same 10 rows, same
   names.** That is what converts "my change broke it" into "it was already
   broken", and it cost one command.
3. Reproduced one row directly, outside the script:
   `ghdl -r --std=08 --workdir=$WORK llama_top --stop-time=1ns` -> the
   `constant "g"` error, deterministically.
4. Re-ran the same command with `-frelaxed` -> **rc=0**. That named the cause
   without touching any RTL.
5. `grep -n "frelaxed" sim/regress.sh` -> the gate has passed it to both `-a`
   and `-r` unconditionally, with a comment, since long before this.
6. Applied the flag, re-ran: **FAIL, 1 row** (`all_real`).
7. **Ran the control again**, this time with the `-frelaxed` fix applied to the
   HEAD worktree too. `all_real` failed there as well, with output
   **byte-identical** down to the process path. Second pre-existing failure,
   different cause.
8. `grep -n "max-stack-alloc"` on both harnesses -> `regress.sh:2244` passes
   `=0`; this script passes nothing and takes GHDL's 128 KB default.
9. Applied that, re-ran the whole matrix: **PASS 25**, guards intact.

## 4. The evidence

Working tree, before any fix:

```
REALSHAPE GATE: FAIL  10 row(s):
   - default_9b (expected ok, rc=1)
   - regmax_edge_ok (expected ok, rc=1)
   - vn_w_ok (expected ok, rc=1)
   - kv_nblk_ok (expected ok, rc=1)
   - kv_addr_fits (expected ok, rc=1)
   - ctx_at_max (expected ok, rc=1)
   - ctx_one_short (expected ok, rc=1)
   - all_real (expected ok, rc=1)
   - real_kv_map (expected ok, rc=1)
   - real_kv_ceiling (expected ok, rc=1)
```

The control at `8e22ff3` printed that list with the same ten names.

The row itself, reproduced by hand:

```
$ ghdl -r --std=08 --workdir=$WORK llama_top --stop-time=1ns
rtl/attn_block.vhd:1065:24: constant "g" is not visible here
rtl/attn_block.vhd:1069:19: no function declarations for operator "="
rtl/attn_block.vhd:1070:50: no function declarations for operator "*"
rtl/attn_block.vhd:1070:20: no function declarations for operator "+"

$ ghdl -r --std=08 -frelaxed --workdir=$WORK llama_top --stop-time=1ns
... NUMERIC_STD metavalue warnings only ...
rc=0
```

`all_real`, working tree and HEAD, identical:

```
/usr/bin/ghdl-mcode:error: declaration of a too large object (256 > --max-stack-alloc=128 KB)
in process .llama_top(rtl).gen_vstub(0).gvr.u_rms@rmsnorm_rs_mem(rtl).P9
  from: work.llama_top(rtl).gen_vstub.gvr.B1.gwl.cb_map at llama_top.vhd:2584
```

After both flags:

```
row  kv_map_manifest_link  ok    16 rows against tools/hbm_map.py and the manifest
REALSHAPE GATE: PASS  rows 25 (13 of them guards that must refuse)
```

## 5. Measured and REJECTED -- do not retry

- **Do NOT "fix" `rtl/attn_block.vhd:1065`.** The `for g in 0 to G-1 generate`
  there is legal and `sim/regress.sh`'s `tb_attn_block` row PASSES on the same
  file in the same session (`PASS -- 3 consumer configurations`). The
  difference is entirely the dialect flag. Editing the RTL to satisfy a
  harness that disagrees with the project's own harness would have been a real
  change made for a fake reason.
- **Do NOT treat GHDL's `--max-stack-alloc` as the memory guard here.** It was
  tempting to leave the 128 KB default in place as protection. It is not
  protection: this script already runs every row under
  `systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0`, which is
  what stops a runaway row reaching systemd-oomd. Lifting the GHDL cap removes
  nothing; `all_real` peaks at 694 MB.
- **Do NOT conclude from the first run that the arena change was at fault.**
  It was the natural reading, it was wrong, and the only thing that showed it
  was wrong was running the unmodified tree.

## 6. Measurement traps hit

- **A failing script and a changed tree in the same session is not evidence
  about the change.** Both fixes here were one line and neither was in
  anything the session had touched. The control was cheap and was nearly
  skipped.
- **The two failures looked like one.** After `-frelaxed` the row count fell
  from 10 to 1, which reads like "almost fixed" -- and the survivor had a
  completely different cause. Running the control a SECOND time, after a
  partial fix, is what stopped `all_real` being blamed on the first fix's
  incompleteness.
- **A tail of interleaved output attributed the error to the wrong row.** The
  `bound check failure at llama_top.vhd:4867` line printed next to
  `real_kv_ctx_over rc=1 expect=fail` belongs to that row and is CORRECT
  behaviour: that row must refuse. Reading a terminal tail rather than the
  per-row `.out` file made it look like a new failure. Every row writes
  `$SCRATCH/<name>.out`; read that.

## 7. The general lesson

**This script is deliberately not a gate row and that is exactly why it
rotted.** Its own header explains the reason it cannot be one: ten of its rows
must make the ELABORATOR refuse, which no testbench can express, because a
refused elaboration takes the whole bench down with it. That reasoning is
sound. The consequence is that nothing runs it unless a person does, and the
project has no record of when it last passed -- so "weeks" is a guess and the
honest statement is that its last green run is unknown.

The two harnesses had drifted apart on dialect and on a resource limit.
Neither drift is visible from either file alone: `regress.sh` documents both
flags in comments, `realshape_gate.sh` documents neither, and each looks
internally consistent. **Where two harnesses run the same tree, the flag sets
are an interface between them, and an interface with no check is a place to
drift.** There is still no check; this file is the record, not a fix for that.

## 8. Open, not yet answered

- **When did it last pass?** Unknown. Not determined, and not determinable
  from the repository, because nothing records a run.
- **Nothing prevents the next divergence.** A row in `sim/regress.sh` that
  merely invoked this script would not work (its refusing rows are the
  point), but something that compares the two flag sets would. Not written.
- **Whether `-frelaxed` is masking a genuine defect in `attn_block.vhd`** is
  NOT settled here. It was not investigated: the argument above is only that
  the two harnesses must agree, and `regress.sh` is the one with 144 rows
  behind it. If `-frelaxed` is ever removed from the project, this is one of
  the places that will need a real answer.
