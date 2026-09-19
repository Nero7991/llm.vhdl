# The first GO on the composed card runs seven steps and stops at the first B job with ERR_WDOG, and the watchdog cannot fit a 9B job by arithmetic

## The question, verbatim

> Step 8 of `docs/2026-09-18_seam-bringup-on-the-card.md`: one token on the
> card, argmax read from `BAR+0xE044`. What happened?

Date: 2026-09-18, 18:10 MDT. Bitstream `hw/fk33/bit/fk33_card_smp_bases_75mhz_2026-09-18.bit`
(24,880,718 B, routed 11:28, WNS +0.061, 75 MHz core clock). Card 1,
`153300000607A`, PCI `06:00.0`, VCCINT 0.715 V, die 38 C, trips 0 before and
after. HBM holds the FLAT `qwen35-9b-mv4i-noembd` image (250 objects,
4,487,442,432 B, written in 6.35 s, read back and digest-verified) and the
311-slot descriptor arena at `0x1_FFAD_D000` (159,232 B, verified). Program:
505 descriptors, streamed and read back (`OPEN_ONLY ... h2c 34340 B`).

Symptom: `run_prompt --max-new 1` returned `prefill returned -3 for 23 ids
(the descriptor program was refused)` on the FIRST GO. The seam afterwards:

```
STATUS     0x00000604   done=0 busy=0 err=1 err_code=6 (DESC)
ERR_INFO   0x00070074
CYCLES     0x0007F202   = 520,706
FAULTS     0x00000000
SEQ_POS    0            N_STEP 1     TBL_LEN 505
```

## The answer, up front

**The GO was ACCEPTED, subsystem D ran steps 0 to 6 (a VEC_NORM and six A
jobs through the card's descriptor plane) in about 320,000 cycles, then
issued step 7, the first B job (Gated DeltaNet, `blk.0`), waited exactly
`WDOG_LIMIT = 200,000` cycles for it, and reported `ERR_WDOG`.** ERR_INFO
decodes per `rtl/fk33_seam.vhd:921`: D's own code `[3:0] = 4 = ERR_WDOG`,
failing step `[14:4] = 7`, steps completed `[26:16] = 7`. The seam wraps any
D error as its code 6 (DESC), which is why `pl_backend` said "descriptor
program refused" for a job that was accepted and then timed out. That
message is wrong for this case and is noted below.

**`WDOG_LIMIT = 200,000` is too small for a 9B job on this card by
arithmetic, independently of whether B also has a defect:**

* **B, DERIVED from the RTL geometry.** At the card's shape
  (`VAL_HEADS = 32`, `DIM = 128`, `B_RECUR_LANES = 4`) one recurrent pass is
  `32 * (128/4) * 128 = 131,072` cycles (`sim/tb_gdn_block.vhd:129`: "a head
  arrives over DIM/RECUR_LANES * DIM cycles"). The tiered state store then
  moves `LAYER_STRIDE = 1,101,824` B in AND out over a 256-bit AXI port:
  34,432 beats each way, 68,864 beats, at best one beat per cycle. Compute
  plus transfer is at least 200,000 cycles with a zero-latency memory, and
  HBM is not that.
* **A, DERIVED from a MEASURED rate on this run.** Steps 1 to 6 are A jobs of
  2048 + 2048 + 4096 + 4096 + 32 + 32 rows x 4096 cols of INT4, about
  25.2 MB of weights, and steps 0 to 6 completed in about 320,000 cycles: on
  the order of 80 B/cycle, or 5.5 cycles per 16-byte beat across 27 lanes
  on the flat image. The FFN gate and up jobs (steps 11 and 12) are 12,288
  rows each, 25.2 MB EACH, so at the same rate they need about 320,000
  cycles apiece. **Even with B fixed, step 11 would fire the same watchdog.**

So the fix that is required in every case is to raise `WDOG_LIMIT` for the
card. The generic is `fk33_llama_top`'s (default 200,000, `rtl/llama_top.vhd:230`),
the counter is 32 bits (`rtl/seq_desc_fetch.vhd:321`), and `hw/fk33/gen_fk33_card.py`
sets the card's generics. Set to **4,000,000** (53 ms at 75 MHz): ten times
the largest derived job, and still a bound that reports a genuinely hung unit
within a human-visible interval.

**What this does NOT establish:** that B completes at all. A B job that
hangs and a B job that takes 250,000 cycles both produce this exact report.
The rebuild with the watchdog raised is the discriminator, and it is the same
rebuild in either case.

## What the run DID establish, which is most of the bring-up

Everything before step 7 is the first time these have happened on silicon:

1. The v2 seam accepted a GO: N_STEP 1, TBL_LEN 505 within bounds, bases
   non-zero, SEQ_POS 0 matched, X row streamed through WIN_XIN with X_EXP.
2. D fetched the program from the seam's windows and sequenced steps.
3. `VEC_NORM` ran (step 0).
4. **Six A jobs ran through the card's descriptor plane** -- `ga_desc`, the
   arm no whole-token bench covers -- with the job counter, `a_desc_adapter`'s
   three AXI-Lite writes, descriptor fetch from the arena at
   `0x1_FFAD_D000`, 27-lane weight fetch from the flat image, x streaming, y
   drain into the region file, and retire. Six times, in order, with no
   EC_DESC and no ED_JOB_INDEX. `FAULTS = 0`.
5. D's watchdog and error report work end to end: the seam latched the code,
   the step and the count, `done` stayed low, `pl_backend`'s `(done | err)`
   poll returned, and `busy` is low afterwards (D drained and released).
6. Trips 0 before and after; the thermal guard did not intervene.

Not established: any VALUE. No argmax was produced.

## The procedure

1. `fk33ctl.py thermal` (0 trips), `run_prompt --open-only --allow-hardware
   HOST ...` (step 4), registers read back: `TBL_LEN 0x1F9`, `ARENA
   0x1_FFADD000`, `BST 0x1_0C006000`, `WIN_ADDR 0x1F9`, `VERSION 2`.
2. `fk33_load_weights.py load <flat manifest> --verify`; `fk33ctl.py load
   arena.bin --offset 0x1FFADD000 --verify`.
3. `run_prompt --allow-hardware HOST --v2 ... --max-new 1`.
4. `fk33ctl.py seam` and a register dump of STATUS/ERR_INFO/CYCLES/FAULTS.
5. ERR_INFO decoded against `rtl/fk33_seam.vhd:921-929`; D's codes from
   `rtl/seq_desc_fetch.vhd:263-271`; step 7 identified from
   `gen_layer_program.py --print` (B_JOB QKV -> Y, `blk.0`).
6. The A rate from CYCLES minus the watchdog window; B's cycle floor from
   the RTL geometry and the store's stride.

## Evidence

```
$ server/run_prompt --allow-hardware HOST --v2 ... --max-new 1
transport  /dev/xdma0_user + h2c_0/c2h_0 (LIVE CARD, operator token supplied)
card       seam v2 @BAR+0xE000 vocab=248320 embd=4096 layer=32 ctx=131072 chunk=1 ...
run_prompt: prefill returned -3 for 23 ids (the descriptor program was refused)

$ fk33ctl.py seam
status     0x00000604  done=0 busy=0 err=1 err_code=6 (DESC)
  ERR is STICKY from a previous job.  ERR_INFO=0x00070074
faults     0x00000000  (none)
last job   seq_pos 0  cycles 520706  argmax 0  logit_exp 0
           tbl_len 505  smp_n 0

ERR_INFO 0x00070074: dcode=4 (ERR_WDOG)  dstep=7  dsteps=7
520,706 - 200,000 = 320,706 cycles for steps 0..6

step 7 in the program:
      7  B_JOB     QKV  -    Y    0        4096    0       0    00000000111100
```

## Measured and REJECTED -- do not retry

* **"The descriptor program was refused."** That is `pl_backend`'s wording
  for seam code 6 and it is wrong here: the program was accepted, seven
  steps ran. Seam code 6 means "D reported an error, see ERR_INFO[3:0]", and
  the host should decode ERR_INFO before saying anything. Reading the
  message as a program fault would send the next hour into the descriptor
  generator, which produced descriptors that six A jobs consumed correctly.
* **Re-running the GO at the same watchdog.** The bound is arithmetic; a
  second run would produce the same 0x00070074.
* **Loading the striped image for bandwidth.** Its weights end at
  `0x1_ABDE_4000`, above this bitstream's K-cache base `0x1_0D93_E000`. The
  flat image is the only one this bitstream can run.

## Measurement traps hit

* The seam's `err_code 6 (DESC)` is a wrapper for ALL of D's own codes
  (`rtl/fk33_seam.vhd:148-152` says so). `fk33ctl.py seam` prints the raw
  ERR_INFO and no decode; `pl_backend` prints a message that assumes one of
  the eight meanings. Both should decode `[3:0]`, `[14:4]`, `[26:16]`.
* `fk33ctl.py seam` prints `SEAM OK ... reports no sticky fault` beneath a
  STATUS line that says `err=1`. FAULTS is 0, which is what it means by
  "fault", but the summary line reads as a verdict on the whole block.

## Open, not yet answered

* Whether B completes at all at 9B on this card. Answered by the rebuild.
* B's real cycle count and A's real per-job cycle counts. D publishes only
  the token total; a per-step cycle register would have made this file one
  paragraph.
* Whether 5.5 cycles per beat on the flat image is representative or was
  helped by the first jobs being small.

---

## ADDENDUM 18:40: THE SECOND GO EXPOSED A SEAM DEFECT THAT MAKES ANY D ERROR PERMANENT, ROOT-CAUSED AND REPRODUCED IN SIMULATION

### The observation

To ask whether B had merely been slow, layer 0's state slot at
`0x1_0C00_6000` (1,101,824 B) was zeroed and the GO repeated. Two results:

1. **The slot stayed all zero** (mant, exp and conv regions, 0 of 1,101,824
   bytes non-zero, read back 3 s after the GO). Before zeroing it held a
   pattern of exactly 644 non-zero bytes in EVERY 4 KB page across all
   three regions (15.7% everywhere): an uninitialised-HBM pattern, not a
   saved state. So neither GO produced a state save. **But the second GO
   is not evidence about B at all**, because of the second result.
2. **The second GO reported the same error with `CYCLES = 1`.** D did not
   run the token. `fk33ctl.py seam`: `status 0x604 ... D's own code 4
   (WDOG) at step 7 ... cycles 1`.

### The cause, from the RTL

`rtl/seq_desc_fetch.vhd`: a watchdog raises `err_r` at the WDOG instant,
then spends up to another `WDOG_LIMIT` in `S_ABORT` draining the unit, then
`S_TOKDONE` raises `tok_r` (`tok_done`, a LEVEL held until `tok_ack`) and
returns to `S_IDLE`, which takes a `go` only while `tok_r = '0'` and clears
`tok_r` only on `tok_ack` (`:726-728`).

`rtl/fk33_seam.vhd` (before this fix) acked at the instant `d_err` rose:
`ack_r <= '1'` for ONE cycle, in the same branch that latched the error and
cleared `running`. That pulse came 200,000 cycles before `tok_done` existed.
D reached `S_IDLE` with `tok_r = '1'`, no ack ever arrived, and **every later
GO was accepted by the seam and ignored by D.** The seam then saw D's
still-sticky `err` on the first running cycle (D clears it only on a `go` it
takes) and re-reported the previous token's error: `CYCLES = 1`.

Every D error that reaches `S_TOKDONE` within a cycle of raising `err` (a
refused descriptor, the counting identity) happened to work, because the
seam's one-cycle ack landed while D was in `S_TOKDONE`/`S_IDLE`. Only the
watchdog path has the drain between the two, and no bench had ever driven
the seam with a watchdog error.

### The fix (`rtl/fk33_seam.vhd`, same commit)

* `ack_r <= d_tok_done`: the ack is a level equal to the level it answers.
* The error REPORT is latched when `d_err` rises, but only once `d_busy` is
  high or `d_tok_done` is high in the same cycle: for the one cycle between
  the seam raising `running` and D taking the `go`, the PREVIOUS token's
  sticky `err` is still on the wire and must not be latched.
* `running` clears, and the done/argmax/position publish happens, on
  `d_tok_done`; the publish is skipped if an error was latched. CYCLES now
  counts GO to `tok_done`, drain included.
* A GO is refused (EC_SEQ) while `d_tok_done` is still high.
* `server/pl_backend.c`: after seeing `err`, keep polling until `busy`
  drops (bounded by the GO timeout), because the seam now reports the error
  while D is still draining and refuses a GO until the drain ends.

### Reproduced and killed in simulation

`sim/tb_fk33_seam_wdog.vhd` (new gate row): `tb_fk33_seam` with
`WDOG_LIMIT = 64`, so step 0 (a VEC_NORM) cannot finish and every token ends
in ERR_WDOG after a drain. New check P7: after the seam reports completion
the DUT's `tok_done` must be low within 8 cycles, and `CYCLES >= WDOG_LIMIT`
(D ran the token).

| seam | result |
|---|---|
| before the fix (`98f6b8a`) | **FAIL**: `P7 -- the seam DUT still holds tok_done after ... token 0`, then `token 1 CYCLES = 1 < WDOG_LIMIT 64: D did not run this token` -- the silicon signature, exactly |
| after the fix | PASS: three tokens, each ERR_WDOG, `tok_done` released, CYCLES >= 64 |
| `sim:tb_fk33_seam` (default WDOG) | PASS, landmark `-17280 / 53529` unchanged |

Two read-only registers were added while the seam was open, because the
only per-token number the host could read was the total: `STEPS_ISS`
(`0x7C`, `job_issue` pulses since GO; a clean token reads TBL_LEN - 1
because END_TOKEN never issues -- MEASURED 34 of 35 on the first run of the
check) and `ISSUE_CYC` (`0x80`, CYCLES at the last issue). Polled with
CYCLES they give a per-step timeline; after a watchdog they say how long the
stuck unit had run. `fk33ctl.py seam` prints them as `progress`.

### A third finding, in the gate itself

The pre-fix run of the new row was judged **NOVERDICT** three times while
its log held six `(report error)` lines. `sim/regress.sh` tested the
failure regex with `printf '%s' "$scan" | grep -aqE`, under `set -o
pipefail`: `-q` exits at the first match, printf (13 MB still to write) dies
of SIGPIPE, the pipeline's status becomes printf's, and a match reads as no
match. Invisible on small logs. Replaced with `grep -c` compared to zero, in
all three places (failure scan, declared marker, PASS_RE). This is the
SIGPIPE-plus-pipefail theory `fk33_reload.sh` records as refuted for its own
case; it is real here, and the difference is the size of what printf still
had to write.

### What is still open after this addendum

* B on silicon: no evidence either way. Both GOs on the card so far are
  explained without B having done anything wrong -- the first by the
  watchdog, the second by the seam. The rebuild (x_exp + WDOG 4,000,000 +
  this seam fix + the progress registers, launched 18:38) is the first
  bitstream on which a B result can be read.
* On the 11:28 bitstream that is on the card now, any D error requires a
  bitstream reload to recover. Do not debug B on it.
