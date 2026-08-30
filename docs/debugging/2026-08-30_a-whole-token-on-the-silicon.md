# A whole token's matvecs on the card, in order, bit-exact

**Date:** 2026-08-30, 01:00-01:20
**Card:** SQRL FK33, `xcvu33p-fsvh2104-2L-e`, the bitstream loaded 2026-08-29.
**Tool:** `hw/fk33/host/fk33_run_token.py` (TRACK TOKENRUN, `c309572`).
**Raw log:** `hw/fk33/results/token_2026-08-30/token_chained.log`.

## The question, verbatim

Tonight both a Gated DeltaNet layer and an attention layer ran in sequence on
the card and produced bit-exact outputs. Nothing had run a whole token. Can the
FPGA execute every subsystem-A matvec of one Qwen3.5-9B token, in program
order, on one open device, with each activation after the input being the
card's own output, and does the argmax over the card's own logits pick the
token `ref/run9b` picks?

## The answer, up front

**Yes. 311 of 311 jobs PASS, 1,675,264 result rows compared element for element
against `ref/run9b`'s stream with zero differing, and `TOKEN card argmax 2614,
reference 2614`.** Wall time 17.814 s for the token.

**This is the matvec skeleton of a token, not a token the card computed by
itself.** The chain was re-anchored 32 times, once per layer, because
subsystems B and C are not on this silicon. That is stated in full below and
the tool prints it as part of its own verdict rather than leaving it to a
reader.

## The procedure

Seven steps, of which the first four need no card and each of which is a gate
on the next. Running them in order is the point: every card claim below rests
on a checker that was shown to bite **before** the card was opened.

| step | what it establishes | card |
|---|---|---|
| 0 | the 32-layer reference stream from `ref/run9b` | no |
| 1 | `selfcheck` -- 13 checks that need no model, card or `/dev` | no |
| 2 | `teeth` -- 9 mutations against the real program | no |
| 3 | `plan` -- the whole token re-run on the host, numerically | no |
| 4 | `run --dry-run` -- the sequencing, with no FPGA | no |
| 5 | `run --mode anchored` -- the card, every job fed the reference input | **yes** |
| 6 | `run --mode chained` -- the card, every input the card's own output | **yes** |

Step 5 before step 6 is deliberate and it is the control: anchored isolates
each job, so if anchored passes and chained fails, the fault is in the
composition and not in any single matvec. Both passed.

## The evidence, raw

**Step 1**, 13 checks, all `ok`, ending:

```
selfcheck   PASS over 13 checks, none of which needs a model, a card or /dev
coverage    this covers the TAIL and the WITNESSES only.
```

**Step 2**, every one of nine mutations produced its stated verdict:

```
mutation                                             want           got            verdict
control (clean)                                      PASS           PASS           ok
one wrong mantissa in job 5                          FAIL           FAIL           ok
wrong y_exp in job 9                                 FAIL           FAIL           ok
job 4 reports job 3's counters                       INCONCLUSIVE   INCONCLUSIVE   ok
job 6 completes on its FIRST poll -- the DONE-1 race INCONCLUSIVE   INCONCLUSIVE   ok
a trip across job 2 whose numbers still match -> PASS, halt column only PASS      ok
job 0's GO swallowed once, then retried -> PASS      PASS           PASS           ok
job 1's halt never clears -> the token aborts        INCONCLUSIVE   INCONCLUSIVE   ok
job 3 never completes -- A7's AR-starved port        FAIL           FAIL           ok
```

Three of those nine are the defects found on this project tonight, wired in as
mutations: the DONE-1 race, the THERM-255 halt, and A7's AR-starved port.

**Step 3**, host-only, whole token:

```
coverage    32 of 32 layers checked, 296 of 296 jobs re-run, 0 differ, 0 host-step faults (31.2 s)
final norm  R_X-31 -> R_XN.final: 0 of 4096 mantissas differ, exp d=0 -> PASS
compared    248320 of 248320 logits, 0 differ
TOKEN       the oracle's argmax is 2614 and the reference's TOKEN record is 2614 -> PASS
```

**Step 6, the card, chained.** Every layer:

```
layer 0   gdn  10/10 jobs PASS   45120 rows   0.383 s  out MATCH
layer 3   attn  7/ 7 jobs PASS   43008 rows   0.340 s  out MATCH
...
layer 31  attn  7/ 7 jobs PASS   43008 rows   0.342 s  out MATCH
```

The lm_head as 15 raw windows, all PASS, and the tail:

```
compared    248320 of 248320 logits, 0 differ
resolution  0 of 248320 have |s32| >= 2^24, where s32 -> f32 is many-to-one
            and this comparison cannot see a low-bit error
```

The result block:

```
result      32 of 32 layers run; 311 of 311 jobs; 311 PASS, 0 FAIL/REFUSED, 0 INCONCLUSIVE
            1675264 result rows compared against ref/run9b's stream, element for element
            token wall 17.814 s
            RE-ANCHORED 32 times (the chain was broken here):
               24 x  the Gated DeltaNet block -- subsystem B, which is not on this silicon
                8 x  the gated attention block -- subsystem C, which is not on this silicon
            DONE-1 poll witness: 0 of 311 jobs completed on their FIRST STATUS read
            THERM-255 trip counter 0 -> 0
            GUARD       0 refused GO(s) waited out and retried (0.00 s waiting, 0
                        unrecovered); 0 trip(s) across a job that ran
```

```
VERDICT     PASS -- every one of the 311 matvecs in the token reproduced ref/run9b's
            stream bit-exactly, in program order, on one open device, and the argmax
            over the card's OWN 248320 logits is token 2614
```

## The PCIe cost, MEASURED

```
MMIO reads     3583291      6.885 s     1.92 us each
MMIO writes    3212819      1.493 s     0.46 us each
```

8.38 s of the 17.8 s token is register traffic, and reads are 82% of it. Setup
is amortised into a single process with one open device and one compiled
oracle, so **what is left is the PCIe cost and not the tool's.** A read costs
4.2x a write, which is why the Y readback dominates: there is no bulk path for
results, `Y_IDX`/`Y_LO`/`Y_HI` is the whole map.

**This is the number to attack, and it is not compute.** The weight beats the
engine actually multiplies are a small fraction of the wall time.

## What this does NOT establish

Stated plainly because the headline invites the opposite reading.

* **B, C and D did not run.** The 64 RMS norms, the final norm, the 64 residual
  adds, the 32 SwiGLUs and the entire Gated DeltaNet or attention block of
  every layer ran on the **host**. The chain was broken and re-anchored 32
  times, once at each layer's B or C gap.
* **One token, one position, one prompt.** Coverage of the input space is not
  coverage of the output space. This reaches the exponents this prompt happens
  to produce, no saturation corner, and no row count other than the shapes the
  model has.
* **The logits comparison has a stated blind spot, which happened to be empty
  here.** `s32 -> f32` is many-to-one above 2^24 and 0 of 248,320 logits were
  that large on this token. On another prompt it will not be zero, and that row
  will then see less than it does here.
* **The bitstream predates four fixes landed tonight** -- A7's `outst` clamp,
  DONE1's `done_l` race, and THERMFIX's two thermal-guard defects. This run is
  evidence about the RTL that was built, not about the RTL in the tree.

## Measured and REJECTED -- do not retry

* **Reading the trip count at job boundaries as a complete halt census.**
  REJECTED, and the tool says so itself. MEASURED earlier tonight: 400 such
  samples taken while compute was active caught nothing while an idle read
  afterwards caught a trip. The `THERM-255 trip counter 0 -> 0` line above is a
  **lower bound**, not a statement that the guard was quiet.
* **Treating a thermal trip as evidence of a compute fault.** REJECTED by
  design in this tool: a trip across a job whose numbers still compare
  bit-exact is PASS with a GUARD column, and only a trip on a job that *also*
  disagreed is INCONCLUSIVE. Teeth rows 6 and 8 are deliberately opposite and
  both bite.
* **Running chained without running anchored first.** REJECTED as a procedure.
  Without the anchored control, a chained failure cannot be attributed between
  a single matvec and the composition.

## Measurement traps hit

* **The guard was quiet for this run purely by luck of the thermal operating
  point.** Between 00:24 and 00:49 the same card took **253 trips and saturated
  its 8-bit counter at 255**; at 01:15 it took zero across the whole token. The
  difference is whether the HBM temperature is sitting on a code boundary. **A
  clean GUARD column on one run is not a property of the run.**
* **`sg fk33 -c` is not decoration.** Group membership is read at login, so
  `id -nG` describes the process while `getent group fk33` describes the
  account, and a long-lived shell is not in the group even though the account
  is.
* **`--timeout 5` is load-bearing.** A GO the guard swallows costs one full
  timeout before it is diagnosed, and a token is 311 chances to pay it.

## Open, not yet answered

* **What a second token costs.** Nothing here exercises the KV cache growing, a
  changing position, or a prompt of more than one token.
* **Whether the 8.38 s of MMIO can be reduced.** There is no bulk result path
  today. Whether one is worth building is undecided and it is now the largest
  single term in the wall time.
* **Everything about B, C and D on silicon.** They have never run there.
* **Whether this still passes on a bitstream carrying tonight's four fixes.**
  It must be re-run after the rebuild; TRACK BITPREP is preparing it.
