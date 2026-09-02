# The epoch echo was latched one cycle too early, and a 2,496-check bench passed anyway

TRACK CARDTOP, 2026-09-02.

## The question, verbatim

While writing `rtl/u_seam.vhd`, the reusable D-to-unit seam for subsystems B
(`gdn_block`) and C (`attn_block`), the first run of its new bench reported:

```
CHECK FAILED: echoed epoch 3 /= issued epoch 4
CHECK FAILED: echoed epoch 4 /= issued epoch 5
CHECK FAILED: echoed epoch 5 /= issued epoch 6
```

Every job, off by exactly one. **Which side was wrong: the seam, or the bench?**

## The answer

**The seam.** And so was `rtl/a_desc_adapter.vhd`, which had shipped at
`3a145fd` behind a bench reporting *2,496 checks, 0 mismatches*.

`seq_desc_fetch` drives `job_epoch <= epoch_r` combinationally
(`rtl/seq_desc_fetch.vhd:932`) and bumps `epoch_r` **on** the issue edge
(`:790`). So during the issue cycle `job_epoch` still carries the OLD value,
while `S_COMPLETE` compares the echo against the NEW one (`:834`). A unit that
latches `job_epoch` at issue echoes an epoch one less than D expects, **on
every job**, and D rejects every completion as `ERR_EPOCH`.

`llama_top`'s seven existing adapters all avoid this, by latching on
`job_issue` (`rtl/llama_top.vhd:3059,3375,3623,4118,4402,5117,5299`), which D
raises one cycle later. That is why the full-model bench is green and neither
new component's bench caught it.

**And the rule was already written down.** `rtl/llama_top.vhd:3047-3048`, in
the A adapter, immediately above the latch:

```
-- Latch at job_issue.  NOT at u_start: u_start leads job_issue by
-- one cycle and job_* still decodes the previous live bank there.
```

So this was not an unknown. It was a known constraint, recorded at the point it
mattered, that was lost when two new components were written against the port
list rather than against the working code. Both new files now carry the same
warning at their own latch, for the next author who writes a third seam.

Both are fixed by latching one cycle after issue: `u_seam` takes the epoch in
`S_PULSE`, `a_desc_adapter` arms `ep_take` and latches on the next edge.

## Why the adapter's bench could not see it

**Not because the check was missing. The check was there and it was correct.**
`sim/tb_a_desc_adapter.vhd` compared `u_done_epoch` against `job_epoch` on
every job. It could not fail, because the bench bumped `job_epoch` **two cycles
before** asserting `u_start` and then held it constant for the whole job. With
the epoch static across the job, latching at issue and latching a cycle later
read the *same value*, and no latch-timing error could be expressed.

MEASURED, and this is the whole point of the file:

| adapter | bench | verdict |
|---|---|---|
| epoch latched at issue (the bug) | bench as shipped at `3a145fd` | **PASS -- 2496 checks, 0 mismatches** |
| epoch latched one cycle later (fixed) | bench as shipped | PASS -- 2496 checks, 0 mismatches |
| epoch latched at issue (the bug) | bench with foreign bumps | **FAIL -- 312 mismatches of 2496** |
| epoch latched one cycle later (fixed) | bench with foreign bumps | PASS -- 2496 checks, 0 mismatches |

The first two rows are the finding. A bench that returns the same verdict for
the bug and the fix is measuring something else.

## The second, deeper version of the same fault

The new seam's bench was written with a hand-computed expectation,
`ep_issued := job_epoch + 1` at the issue instant. That expression encoded my
reading of `seq_desc_fetch`, and the seam encoded the same reading, so once
both were "fixed" to agree they would have agreed with each other and not with
D. The bench was rebuilt as a **register-level mirror** of D's issue / wait /
complete path -- `epoch_r` bumped on the issue edge, `job_epoch <= epoch_r`
combinational, a sticky capture of the echo at the first `done` (`:641-644`),
and the compare against `epoch_r` at ack -- with the line numbers it is copied
from. The bench now states no expected epoch of its own.

## The check that was true, correct, and unreachable

Even after the mirror was in place, mutation **M8** -- replace the latch with a
locally generated counter, `ep_q <= ep_q + 1` -- **SURVIVED**, on both
completion styles.

It survived because D's `epoch_r` is **global across all five units** and the
bench only ever issued to one. With one job at a time, a per-job counter and
D's global epoch advance in lockstep and agree on every comparison. The epoch
exists precisely to catch a completion belonging to a *different* job, and the
bench had removed the only way for that to happen.

`D_FOREIGN` now bumps `epoch_r` between our jobs, exactly as a job to A, C or V
would. M8 then dies with 187 of 200 completions stale. (187 and not 200 because
`EPOCH_W = 4`: a generated counter still coincides with the global epoch
sometimes. That number is the check's resolution, and it is honest.)

The same defect class hit the error latch: mutation **M5**, `u_err` hardwired
to `'0'`, survived, because no job in the stimulus ever reported an error. An
error stimulus was added; M5 now dies.

**Both were true checks, correctly computed, over a stimulus that could not
reach them.** The bench now refuses to pass a run where either
`foreign_bumps = 0` or `err_jobs = 0`, so this exact hole cannot silently
reopen.

## The mutation table

DUT = `rtl/u_seam.vhd`, bench = `sim/tb_u_seam.vhd` (both completion styles,
11,914 checks each, 23,828 total).

| # | mutation | verdict | killed by |
|---|---|---|---|
| M0 | none (control) | SURVIVES | -- (the control that proves the rest are real) |
| M1 | epoch latched at issue | KILLED | epoch verdict, 200/200 stale |
| M2 | `done` not held to `u_ack` | KILLED | C5 `u_done dropped without an ack` |
| M3 | `unit_start` held two cycles | KILLED | C3 `unit_start while unit_busy` |
| M4 | `u_ready` also high in `S_DONE` | KILLED | C1 `ready and done both high` |
| M5 | `u_err` hardwired `'0'` | KILLED (after the err stimulus; **SURVIVED** before) | err echo |
| M6 | `unit_ack` never asserted | KILLED **on the ack style only** | the seam's own stale-done guard |
| M7 | `S_RUN` completes immediately | KILLED | four independent checks |
| M8 | epoch generated, not latched | KILLED (after foreign bumps; **SURVIVED** before) | epoch verdict, 187/200 |
| M9 | `err` sampled at ack, not at `done` | KILLED | err echo |

### Attribution controls -- every kill re-run with the credited check disabled

| control | result | what it actually proves |
|---|---|---|
| AC1 | M1 with the epoch verdict off -> **SURVIVES** | the epoch verdict is the SOLE detector. Nothing else sees it. Full credit. |
| AC2 | M2 with C5 off -> pulse SURVIVES, ack KILLED | C5 earns credit on the **pulse** style only; on ack the seam's own guard catches it. |
| AC3 | M3 with C3 off -> KILLED by `unit_start twice in one job` | **C3 does NOT earn sole credit for M3.** The redundant check would have caught it anyway. |
| AC5 | M7 with C3 off -> KILLED by the seam's busy guard | M7 is over-determined. |
| AC6 | M7 with C3 AND the busy guard off -> KILLED by the err echo | M7 is caught four ways. |

AC3 is the row worth keeping: without the control, C3 would have been credited
with two kills instead of one.

### M6 is also the proof that the style generic does anything

The two styles produce **identical counts and identical end times** (both
finish at 27,836 ns), because the seam sets the job length and the unit's
lingering `done` does not. So the counts alone cannot show that `DONE_STYLE`
changes anything. M6 -- `unit_ack` tied off -- kills the ack style and leaves
the pulse style untouched. That asymmetry is the evidence the two
configurations are genuinely different.

## Measured and REJECTED -- do not retry

- **Do not gate the bench clock on a `running` flag.** The first version did
  (`clk <= (not clk) after TCK/2 when running else '0'`). When `running`
  cleared, the monitor's `wait until rising_edge(clk)` never returned, so its
  ENTIRE summary -- every count and every end-of-run check -- was unreachable.
  The bench printed **nothing at all and exited 0**. A free-running clock plus
  `std.env.finish` is the fix. A silent rc=0 is the worst possible failure mode
  and it looked exactly like a pass.
- **Do not parameterise a gate row over a generic and expect the gate to cover
  both values.** `sim/regress.sh`'s planner globs `sim/tb_*.vhd` and runs each
  with its DEFAULT generics, so `DONE_STYLE` would have put only "pulse" in the
  gate and left C's real shape permanently unexercised. Both styles are now
  instantiated inside one top-level bench.
- **Do not assume B and C have the same interface.** They nearly do, and the
  differences are exactly the ones that matter: B's `done` is a one-cycle pulse
  with THREE error bits (`gdn_block.vhd:625,162-164`); C's is a level held
  until its own `done_ack` with ONE `err` (`attn_block.vhd:1799`, its "RULE 1").
  A seam written for either alone is wrong for the other.
- **Do not GHDL-elaborate the wired `compose4_top`.** It instantiates BUFG and
  needs UNISIM; the check is `C4_STAGE=elab` under Vivado. Also: analysing
  `rtl/*.vhd` and `hw/fk33/rtl/*.vhd` in repeated passes does NOT converge --
  re-analysing a package obsoletes every unit that depends on it, so the pass
  count plateaus at a nonzero number that looks like a dependency error and is
  not. Analyse packages to a fixed point first, then entities, never touching a
  package again.

## Measurement traps hit

- **A bench and the thing it checks written by the same author are not an
  oracle for the interface between them.** Both encoded the same misreading of
  `seq_desc_fetch` and agreed with each other. The fix that worked was to stop
  the bench stating an expectation at all and make it mirror D's registers with
  the line numbers copied in.
- **`2,496 checks, 0 mismatches` is a fact about the checks, not about the
  design.** The count was real and the checks ran. They just could not
  discriminate the defect they existed to guard.
- **Verify the fix by reinstating the bug.** The adapter bench passing after
  the fix proved nothing; it also passed *before* the fix, and it also passed
  with the bug deliberately restored. Only the mutant run distinguished them.

## Open, not yet answered

- **The seam is proven against a MIRROR of D, not against D.** The mirror is
  faithful to the lines it cites, but a mirror is still a model. The composed
  bench that drives the real `seq_desc_fetch` through the real seam into the
  real `gdn_block` and `attn_block` does not exist yet, and until it runs, the
  claim is "the seam matches my reading of D's RTL", not "the seam works with
  D".
- **B's three error bits are ORed in the compose4 glue, and that OR is
  unchecked.** Which bits exist is a property of the unit, so the OR does not
  belong in the seam -- but nothing currently tests it.
- **`u_seam` has never been synthesised.** Area and timing are unknown.

## A related hazard, found from the same comment, NOT yet a bug

`llama_top:3047` says `u_start` leads `job_issue` by one cycle and that at
`u_start` "job_* still decodes the PREVIOUS live bank". That applies to **every**
`job_*` field, not only the epoch.

`a_desc_adapter` also latches `u_index` at the `u_start` edge. That is safe
**today** only because `u_index` is a top-level input of the composed top and
is not sourced from D's decode at all. The moment it is wired to a D field it
becomes the same defect, one field over, and it would produce a descriptor
pointer for the previous job -- an entirely plausible wrong number with no
error bit anywhere. A warning is now at that latch.

## Why `a_job_index` is exported rather than wired

The obvious source is D's `job_ordinal`, and it is **wrong twice over**:

1. It is `unsigned(7 downto 0)` (`seq_desc_fetch.vhd:214`), so it cannot
   address the 311 A jobs of the 9B token program at all.
2. `llama_top` uses it as `wsyn(r, c, j_ord)` -- a synthetic weight selector in
   the simulation model, not a descriptor pointer.

Wiring it would have elaborated cleanly and produced wrong descriptors on the
card. Nothing in the RTL currently decides which descriptor a given D job
selects, so `a_job_index` is a top-level input of the composed top and the
decision stays visible instead of being buried in a plausible-looking wire.
