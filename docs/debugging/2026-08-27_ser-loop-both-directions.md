# The S_SER loop lost an element as well as duplicating one, and the check that found it could not fail

## 1. The question

2026-08-27, branch `fpga`, `rtl/gdn_emit_chain.vhd` at commit `b94e2f8`, GHDL
mcode `--std=08`, HEADS=4 DIM=16 BLOCKS=3 in the audit harness and
HEADS=24 DIM=128 in the real chain. No hardware.

`docs/debugging/2026-08-27_B-interface-audit.md` records finding **B-1** as
CONFIRMED: `gdn_emit_chain`'s `S_SER` branch delivers `DIM + 1` elements for a
head when `ye_ready` is low at entry. The question taken up here was simply:
**fix B-1.** The question that actually mattered turned out to be **is B-1 the
whole of what is wrong with those four lines.**

## 2. The answer

**No. The same four lines also DROP the last element of a head when the
consumer is not ready on the drain edge, and the audit did not name it.** Both
defects have one cause -- the loop gated on `ye_ready` rather than on whether
the output bus slot was free -- and one fix. Separately, the harness that
confirmed B-1 asserted at `severity note`, so the run that demonstrated the
defect printed it and exited 0.

## 3. The procedure

1. **Fix the named defect by finding its cause rather than its symptom.**
   `ye_o` is registered, so what the consumer sees this cycle was loaded last
   cycle. The bus slot is free in exactly two situations: nothing has been
   offered yet (`ye_valid = '0'`, the priming cycle on entry to `S_SER`), or
   what was offered has just been taken (`ye_ready = '1'`). The old loop
   advanced on `ye_ready` alone, which conflates those two with each other and
   with the case where neither holds.
2. **Re-read the whole branch against the corrected rule, not only the reported
   line.** The `else` arm drops `ye_valid` unconditionally when `ser_j` reaches
   `DIM`. But `ser_j` reaching `DIM` means `elem(DIM-1)` was just LOADED, not
   accepted. So the drain has the mirror-image bug.
3. **Count in both directions.** The harness counted heads that moved MORE than
   `DIM` elements. Counting only that direction makes a dropped element
   invisible. Added a short-head counter and a total-heads-seen counter, the
   latter because a head that moves ZERO elements is counted by neither.
4. **Raise the assertions to `severity failure`, then verify the harness fails
   on the pre-fix code before trusting it on the fixed code.**

## 4. The evidence

The pre-fix transcription, `HEAD_GAP=0`, with the strengthened counters. Note
the second number, which is new:

```
tb_b_audit_ser_handshake: HEAD_GAP=0  DIM=16
  heads that moved more than DIM elements: 1
  worst per-head transfer count: 17
  heads that moved FEWER than DIM: 1        <-- the defect the audit missed
  heads seen: 12
  S_SER entries with ye_ready low: 1
(assertion failure): the S_SER loop delivered MORE than DIM elements ...
```

Both directions occur in a single 12-head run. The tail drop is therefore not a
reading of the code, it is something that already happened in the run that was
used as evidence for B-1.

The fixed RTL, transcribed into the same harness, across the `HEAD_GAP` sweep
that previously bracketed the defect at 13 pass / 14 clean:

```
HEAD_GAP=0   more:0  worst:16  fewer:0  heads:12  ready_low_at_entry:1
HEAD_GAP=8   more:0  worst:16  fewer:0  heads:12  ready_low_at_entry:1
HEAD_GAP=13  more:0  worst:16  fewer:0  heads:12  ready_low_at_entry:1
HEAD_GAP=14  more:0  worst:16  fewer:0  heads:12  ready_low_at_entry:0
HEAD_GAP=40  more:0  worst:16  fewer:0  heads:12  ready_low_at_entry:0
```

Exactly `DIM` transfers per head at every gap, including the three gaps where
`ye_ready` is still low at entry. The precondition is still occurring; it no
longer has a consequence.

The real chain, unchanged testbench:

```
tb_gdn_emit_chain: PASS -- 6 blocks x 24 heads x 128 bit-exact,
                   OVERLAP=true COL_GAP=4 refused-column cycles=0
                   SILU_LANES=16 RMS_LANES=4
tb_gdn_emit_chain: PASS -- 6 blocks x 24 heads x 128 bit-exact,
                   OVERLAP=false COL_GAP=0 refused-column cycles=37716
```

The second is the interesting one: 37,716 refused-column cycles means the
consumer stalls constantly, which is the condition both defects need, and it is
bit-exact.

## 5. Measured and REJECTED -- do not retry

- **Advancing unconditionally on the first cycle and on `ye_ready` after,
  tracked with a `primed` flag.** Traced on paper and rejected before coding:
  it fixes the duplicate but keeps reloading `ye_o` every cycle while the
  consumer is stalled, so `elem(k+1)` overwrites `elem(k)` before `elem(k)` was
  ever accepted. That converts a duplicate into a loss. The load and the
  advance must be gated together, which is what the shipped form does.
- **`COL_GAP=2` with `STRICT=true` failing is NOT this defect and must not be
  "fixed".** It fails identically on the pre-fix RTL:
  `gdn_emit_chain: a column was offered and refused while STRICT_PRODUCER is
  set`. That is the per-head rate limit measured independently at **367
  cycles/head** at `DIM=128 SILU_LANES=16 RMS_LANES=4`. A column period of 2 is
  far inside it. Verified against the pre-fix file specifically so it could not
  be mistaken for a regression. Do not retry this as a bug.
- **`severity note` on the audit assertion.** It is why a confirmed defect
  produced a passing run. Now `failure`.

## 6. Measurement traps hit

- **A one-directional counter.** `xfer_head > DIM` was the only test, so the
  harness was structurally incapable of seeing a dropped element even though
  the drop was happening in the very runs quoted as evidence. Whenever a count
  can be wrong in two directions, check both, and check the zero case
  separately because a head that moves nothing is in neither bucket.
- **An assertion that cannot fail.** `severity note` prints and continues. The
  file was cited as confirming B-1, and it did print the right numbers, but it
  exited 0 the whole time. A check that cannot fail is a report.
- **The harness TRANSCRIBES the RTL branch rather than instantiating it.** That
  is deliberate, so the defect can be shown without the surrounding chain, but
  it means the copy can drift from the real file. Both were changed together
  here and the transcription now carries the pre-fix form in a comment. Anyone
  editing `S_SER` must edit both, and nothing enforces that.
- **A stalled consumer is the interesting case and the default configuration
  hides it.** `COL_GAP=4 OVERLAP=true` reports `refused-column cycles=0`. The
  configuration that exercises this defect class is the one where the consumer
  is starved, not the one that runs cleanly.

## 7. Open, not yet answered

- Nothing enforces that the transcription in `sim/tb_b_audit_ser_handshake.vhd`
  matches `rtl/gdn_emit_chain.vhd`. A drift check, or instantiating the real
  chain with a stallable consumer, would close that.
- `STRICT_PRODUCER` still defaults to `false`, so the chain silently tolerates
  refused columns unless a testbench turns the check on. That is audit item
  B-6's neighbourhood and is untouched here.
- The audit's other confirmed items are still open: B-6 (`w_taken` and
  `cfg_taken` are pulses with no back-pressure), and the unconsumed error
  outputs across B (B-10).
