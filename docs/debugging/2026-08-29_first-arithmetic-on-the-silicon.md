# The first arithmetic on this silicon, and it is bit-exact

**Date:** 2026-08-29, 20:12-20:13
**Who:** dispatcher. **Not a subagent.** Oren authorised load-and-run on card 1
for 2026-08-29; the no-hardware rule for agents is absolute and unchanged.
TRACK AJOBRUN wrote the runner and was forbidden to execute it.
**Hardware:** FK33 card 1, endpoint `06:00.0`. VCCINT untouched (wiper 68),
no flash write, card 2 never addressed.
**Tools:** `hw/fk33/host/fk33_run_job.py` (`836b802`, `1fdf42e`),
`hw/fk33/host/fk33ctl.py`, `ref/matvec_int4.c`, `sg fk33 -c`.

---

## 1. The question, verbatim

Board row N1:

> **NOTHING HAS VERIFIED WHAT THE CARD COMPUTES, AND NO TOOL IN THIS
> REPOSITORY CAN.** [...] This is the first arithmetic on this silicon and
> every schedule below it is unfalsifiable until it happens.

## 2. The answer, up front

**Subsystem A computes correctly on the FK33. Four jobs, four different
shapes, every mantissa and every exponent bit-identical to
`ref/matvec_int4.c`.**

| tensor | rows | M x K | tiles | verdict |
|---|---|---|---|---|
| `blk.0.ssm_alpha.weight` | 32 | 32 x 4096 | 1 | **PASS** 32/32 |
| `blk.11.attn_k.weight` | 100 | -- x 4096 | 3 | **PASS** 100/100 |
| `blk.0.ffn_gate.weight` | 64 | 12288 x 4096 | 2 | **PASS** 64/64 |
| `blk.20.ffn_down.weight` | 64 | 4096 x 12288 | 2 | **PASS** 64/64 |

`err_code=0x0 (EC_NONE)` on all four. `BEATS` matched `tiles*nblk` exactly on
all four. `y_exp card=6 oracle=6` throughout.

**Every result is unconfounded by THERM-255:** the trip counter was cleared at
20:12:27 and read **0** before and after every job, and at 20:13:03 the guard
still reported `LATCHED TRIP none since the last clear`. A trip halts the
compute domain, so this had to be established rather than assumed.

The second row is the load-bearing one: `blk.11.attn_k.weight --rows 100` is
the **exact argv `sim/regress.sh:1428` feeds `sim/tb_matvec_fk33`**, on a
byte-identical file. So the card and the simulator agree on the same job.

## 3. The procedure

TRACK AJOBRUN's section 8, run in order. Each step removes one class of
explanation before the next.

1. `gen_fk33_regs.py --check` -- the register header is GENERATED; a
   hand-edited one is silently reverted. Confirms header and generator agree
   before any address is trusted. Result: `fk33_regs.h is in step with
   gen_pcieep.py`.
2. `fk33_run_job.py selfcheck` (no card, no model) -- 32 mutations, 17
   expected-refusal rows bit, 0 disagreements. Establishes the runner refuses
   what it should BEFORE it is pointed at silicon.
3. `fk33_run_job.py plan` (no card) -- 42 of 42 descriptor fields agree between
   `tools/gen_mv4i_desc.py` (Python) and `ref/mv_fk33_tr` (C), image digest
   matches the manifest. Separates "the descriptor is wrong" from "the card is
   wrong" in advance.
4. `fk33ctl.py thermal --clear` -- so any trip during the job is attributable.
5. The runs.
6. `fk33ctl.py thermal` -- confirms nothing tripped.

## 4. The evidence, raw

```
identity    FK33 0x464B3333 | MV4I 0x4D563449 | ENG1 0x454E4731
caps        NPORTS_W=24 NPORTS_S=3 ROWS_IF=48 AXI_DW=256 ADDR_W=40 DESC_WORDS=39  (all read from the card)
thermal     STATUS=0x8000001C trips=0 cause=0 trip_cause=0 temps=0x2348927A
descriptor  312 bytes written to 0x1FFADD000 and read back identical
activations 4096 elements written in 0.00 s; the engine's own X_ADDR counter agrees (4096)
job         STATUS=0x00000001 done=1 busy=0 err=0 err_code=0x0 (EC_NONE) after 9 polls / 0.000 s
thermal     STATUS=0x8000001C trips=0 (was 0)
counters    CYCLES=2992 BEATS=128 STARVED=2567  (expected BEATS = tiles*nblk = 128)
result      read 32 of 32 rows, compared 32 of 32 against ref/matvec_int4.c, 0 differ
            y_exp card=6 oracle=6

VERDICT     PASS -- 32 of 32 mantissas and y_exp are bit-identical to ref/matvec_int4.c
```

The runner is careful about what its own descriptor read-back proves, and the
wording is worth preserving:

> a ROUND TRIP through one path -- it proves the DMA moved bytes, NOT that the
> bytes are the right descriptor. What checks the bytes is the Python/C
> cross-check above and the gateware's own `S_CHECK`.

## 5. STARVED: measured, and NOT the steady-state figure it first looks like

| job | CYCLES | BEATS | STARVED | starved % | BEATS/CYCLES |
|---|---|---|---|---|---|
| 32 rows, K=4096, 1 tile | 2,992 | 128 | 2,567 | **85.8%** | 4.28% |
| 100 rows, K=4096, 3 tiles | 8,582 | 384 | 7,530 | **87.7%** | 4.47% |
| 64 rows, K=4096, 2 tiles | 5,724 | 256 | 3,872 | **67.6%** | 4.47% |
| 64 rows, K=12288, 2 tiles | 16,847 | 768 | 8,132 | **48.3%** | 4.56% |

**The starved fraction FALLS as the job grows, 85.8% to 48.3%, which is the
signature of fixed per-job overhead being amortised rather than of a starved
data path.** Anyone quoting the 86% figure as a throughput result would be
wrong. Note `BEATS/CYCLES` is nearly constant at 4.3-4.6% across a 5.6x range
of job size, i.e. ~22 cycles per beat, and that is the number to reason about.

**DO NOT BUILD ON THIS SECTION YET.** TRACK AJOBRUN states explicitly that it
**did not verify `BEATS` and `STARVED` semantics against the RTL**, which is
why its own tool reports them and refuses to let them change a verdict. The
percentages above are arithmetic on counters whose meaning is unconfirmed.
Treat the shape of the trend as a lead, not as a measurement.

## 6. Measured and REJECTED -- do not retry

- **Judging the run by `done=1` / `err=0`.** A job that completes is not a job
  that computed. The verdict here is 32 of 32 and 100 of 100 mantissas against
  an independent C implementation; the status word is not the evidence.
- **Treating the descriptor read-back as verification.** It is a round trip
  through one path. See the runner's own note in section 4.
- **Running without clearing the thermal counter first.** THERM-255 means a
  trip halts the compute domain; a wrong answer with a moved counter is not
  evidence about subsystem A. The clear at 20:12:27 is why these four results
  can be believed.

## 7. Measurement traps hit

- **`id -nG` describes the PROCESS, `getent group` the ACCOUNT.** Group
  membership is read at login, so `fk33` was absent from this shell while the
  account had it. `sg fk33 -c` bridges it. Without this the whole run reads as
  a permissions fault on the card.
- **`blk.0.attn_q.weight` and `blk.5.attn_v.weight` do not exist** under those
  names in the packed set; the sweep silently skipped them because the loop
  guarded on the file existing. Two of four sweep rows are absent above for
  that reason and NOT because they failed. QKV is presumably fused; not
  chased.

## 8. Open, not yet answered

- **`BEATS`/`STARVED` semantics are unverified against the RTL** (section 5).
- **This is subsystem A alone.** `hw/fk33/rtl/fk33_engine.vhd` instantiates
  `matvec_int4_desc_axi` and nothing else. B, C and D have never run on this
  silicon, and board row N3 records that no RTL top composes them for the card.
- **One activation vector per job**, supplied by the host. Nothing here
  exercises a layer, a sequence, or the KV cache.
- ~~Four tensors of roughly 250.~~ **CLOSED, see section 9.** All eight
  distinct geometries now pass.
- **Why THERM-255 was quiet for this window** is not established; see the
  companion note on the trip-burst measurement. A quiet window is not a fixed
  defect.


---

## 9. Geometry coverage is COMPLETE: 8 of 8

Added 20:14-20:16. The 249 `mv4i` objects have only **eight distinct
`(M, K)` shapes**, so complete coverage of the geometry space is eight runs,
not 249. Enumerated from the manifest, then all eight run:

| M x K | objects with this shape | tensor run | verdict |
|---|---:|---|---|
| 12288 x 4096 | 64 | `blk.0.ffn_gate.weight` | **PASS** 64/64 |
| 4096 x 4096 | 56 | `blk.0.attn_gate.weight` | **PASS** 64/64 |
| 32 x 4096 | 48 | `blk.0.ssm_alpha.weight` | **PASS** 32/32 |
| 4096 x 12288 | 32 | `blk.20.ffn_down.weight` | **PASS** 64/64 |
| 8224 x 4096 | 24 | `blk.0.attn_qkv.weight` | **PASS** 64/64 |
| 1024 x 4096 | 16 | `blk.11.attn_k.weight` | **PASS** 100/100 |
| 8192 x 4096 | 8 | `blk.11.attn_q.weight` | **PASS** 64/64 |
| 248320 x 4096 | 1 | `output.weight` | **PASS** 64/64 |

**The two worth calling out are the ones chosen because they are awkward, not
because they are typical:**

- **`M = 8224` is not a multiple of 32**, unlike every other shape in the
  table. `8224 = 8192 + 32`, the fused QKV with its padding. Row-count
  arithmetic that assumes a `BLOCK`-aligned `M` would break here and nowhere
  else in the model.
- **`M = 248320` is the lm_head**, the tensor `MAXROWS_BFP = 17408` forces into
  **15 descriptor jobs**, and which TRACK LMHEAD proved the gateware REFUSES as
  a single 248,320-row job. **This run does not contradict that**: it asks for
  64 rows, i.e. one window well inside the cap. What it establishes is that the
  windowing geometry computes correctly, not that the refusal is gone.

**Zero thermal trips across the entire session.** `LATCHED TRIP none since the
last clear` still held at 20:16, with the counter cleared at 20:12:27 and
twelve jobs run in between.

### What this still does not cover

- **One row-count per geometry.** `--rows` was 32, 64 or 100; nothing swept the
  row count within a shape, so an off-by-one at a window boundary is not
  excluded. The lm_head is the place that matters and it was run at 64 of a
  17,408 cap.
- **Only `slot` 0..3 of the descriptor arena**, and one activation vector per
  job supplied by the host.
- **Still subsystem A alone.** B, C and D have never run on this silicon.


---

## 10. Row-count sweep, exponent sweep, and the teeth I could NOT get

Added 20:36-20:42. Section 9 left "one row-count per geometry, so an off-by-one
at a window boundary is not excluded" as an open gap. Closed.

### Row counts: 18 of 18 PASS

`blk.0.ffn_gate.weight`, every `BLOCK`(32) and `ROWS_IF`(48) boundary and its
neighbours: **1, 2, 3, 31, 32, 33, 47, 48, 49, 63, 64, 65, 95, 96, 97, 127,
128, 129.** All PASS, bit-identical, `n of n` mantissas at every n. `rows=1`
works. Thermal cleared at 20:36:45; `LATCHED TRIP none since the last clear`
afterwards, so the whole sweep is unconfounded.

### Activation exponent: 3 of 3 PASS

`--x-exp` 3, 5, 6 all bit-exact. Note this is NOT a teeth-check -- the value
goes into the descriptor AND into the oracle, so both sides move together. It
broadens numeric coverage; it does not test discrimination.

### THE HONEST LIMIT: I could not make the on-card comparison FAIL

**Thirty-plus card jobs have now passed and I have NOT shown the card-vs-oracle
numeric comparison failing on real silicon.** Three attempts, all refused
BEFORE reaching the card, which is good tool behaviour and bad teeth:

| attempt | intent | outcome |
|---|---|---|
| `--no-cb-load` after loading another tensor's codebook | make the card compute with the wrong codebook | **REFUSED by the tool**, `0x3 ERR_DESC: cb_load clear (only if no codebook was ever loaded)`, rc=2 |
| unwritable `oracle.txt` pre-seeded with `y_exp=99` | make a STALE oracle slip through as PASS | **REFUSED loudly**, `ref/mv_fk33_tr failed (rc=2): Permission denied`, rc=2. It does not silently reuse a stale oracle. This one is a genuine hazard that bit. |
| `--addr-w 33` | mis-address the weights | **REFUSED**, `ADDR_CAP reports ADDR_W = 40 and the descriptor was built for 33` |

**So the claim "this comparison would catch a wrong card result" rests on TRACK
AJOBRUN's 32-mutation `selfcheck` against a SIMULATED card, not on any
measurement against silicon.** That is a real resolution floor and it is stated
here rather than left implied. What would close it: a deliberate corruption of
the resident weight bytes at a known offset, then a run expecting FAIL -- not
attempted tonight because it perturbs a verified 4.49 GB image and the restore
cost is a full reload.

The `--addr-w` refusal is worth keeping for a second reason: the tool reads
`ADDR_CAP` **from the card** and compares, rather than assuming. That is this
project's own "select by what a thing ANSWERS, refuse rather than guess"
principle, implemented.

### Correction to TRACK AJOBRUN's write-up

Its `selfcheck` lists `--addr-w 33` as **"a correct non-refusal"**. On the real
card it IS refused, because the card answers `ADDR_W = 40`. The simulated card
must report something else, so that row is a statement about the simulator, not
about the card. Minor, but it is exactly the class of difference a simulated
plane is there to expose and this one went the other way.
