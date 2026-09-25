# 2026-09-24: build 19's attention hang is a timing failure at the card's real VCCINT

## The question

Build 19 (plan Task 2, NORM_HBM, bitstream sha256 `9366b396...c18`, both FK33s,
Qwen3.5-9B split 0-15 / 16-31 with the `-nh` images) hangs intermittently in a
C_JOB: D watchdog (ERR_INFO `0x00EB0EB4`, D code 4 at step 235, or step 52),
always first seen at **position 32**, the first read of KV block 1. Once
wedged, every later token hangs until a JTAG reload. Measured rate with
`hw/fk33/host/fk33_ctxtest.sh pair ... 256`: **2 of 3 runs**. Build 18 on the
same cards, same D program, same images: **0 of 16**. Why?

## The answer

**It is a timing failure at the voltage the cards actually run at.** Every
build is signed off against Vivado's 0.85 V speed data, and the cards run at
0.715 V (wiper 68). Raising VCCINT to **0.779-0.780 V (wiper 25)** on both
cards, same bitstream, same images, same test: **8 of 8 runs pass**, and the
ids are identical to build 18's. At a 2/3 hang rate, 8 consecutive passes has
probability (1/3)^8 = 1.5e-4 (DERIVED). Which path fails is NOT established;
the lead is C's KV mover, whose slack fell from 1.966 ns (build 18) to 0.254
ns (build 19) at the 0.85 V analysis.

## The procedure

1. **Context tests as the reproducer.** `fk33_ctxtest.sh pair ... 256`: a
   256-id real-text prefill, then a 16-id prompt decoded to 256 GOs, each
   repeated, seams dumped after every run. Ordinary 25-id prompts caught the
   hang 2 times in ~15; this caught it 2 in 3.
2. **Bitstream vs image.** Build 18 with its original image, then with build
   19's `-nh` image: isolates the bitstream (0 of 16 and 0 of 16 hangs).
3. **Where the two bitstreams differ in margin.** Per-subsystem worst setup
   slack from both shipped routed DCPs (`get_timing_paths -to` sequential cells
   of `u_attn`, `u_kv`, `u_gdn`, `u_state`, `u_fetch`, `bcgrant`, `eng/dut/core`),
   0.85 V: controls for "which unit lost margin", at the sign-off voltage only.
4. **The silicon discriminator.** Same bitstream, faster die: VCCINT raised on
   both cards (`hw/fk33/host/fk33_vccint_test.py raise`), then the same
   ctxtest. Controls for everything but the die's speed.

## The evidence

Hang history (`hw/fk33/results/card_build19_2026-09-24/silicon/hang/README.md`):

| build | image | VCCINT | runs | hangs |
|---|---|---|---|---|
| 19 | `-nh` | 0.715 V | 3 (n256 ctxtest) | **2**, both @32, card 1 |
| 18 | original | 0.715 V | 8 | 0 |
| 18 | `-nh` | 0.715 V | 8 | 0 |
| 19 | `-nh` | **0.779 / 0.780 V** | 8 | **0** |

The 0.78 V run (`/mnt/storage/fk33_builds/card_build19/vtest/n256_r4_b19_078V/ctxtest.log`):

```
CTXTEST_RUN input_r1 end 10:53:07: rc 0, 256 GOs, 34 s, seam error 0
...
CTXTEST_RUN output_r4 end 10:59:01: rc 0, 256 GOs, 63 s, seam error 0
output: all 4 runs produced identical ids (242 ids)
CTXTEST_PASS mode pair N 256 SHORT repeats 4
```

and `cmp` of its input and output ids against build 18's at 0.715 V: equal.

Slack at the 0.85 V sign-off (ns, worst setup to sequential endpoints):

| | build 18 | build 19 |
|---|---|---|
| core clock (A's engine) | 0.225 | 0.013 |
| C `u_attn` | 0.853 | 0.311 (from `u_kv/wb_full_reg`) |
| C's KV mover `u_kv` | 1.966 | **0.254** |
| B `u_gdn` | 1.942 | 1.943 |

VCCINT raise, card 1 (`raise078_xdma0.log`, `raise078b_xdma0.log`): wiper 69
-> 25 one step at a time, ~1.2 mV per step near 68 growing to ~3 mV near 30,
largest single step +3.6 mV, die 36-39 C. Card 2 (`raise078b_xdma1.log`):
wiper 68 -> 25, largest step +5.4 mV, die 51-53 C.

## Measured and REJECTED -- do not retry

- **Re-timing the routed card DCP at 0.72 V in Vivado 2023.2.**
  `set_operating_conditions -voltage {VCCINT 0.72}` on the routed DCP, after or
  before any 0.85 V timing, throws `[Timing 38-246] Caught exception
  'vector::_M_range_check'` and `Net delay calculation threw an exception`,
  then SEGFAULTS (exit 139). Twice. Not memory.
- **"The image causes it."** 0 of 8 hangs with the `-nh` image on build 18.
- **"State left from a previous sequence causes it."** It hung on the first
  sequence after a fresh JTAG reload.
- **"A single job at position 32 hangs in simulation."** `tb_csweep_rate` at
  positions 31/32/33/64 with STALL 0/5/3 completes every job.
- **A slack number ranks nothing here on its own.** A's engine has the least
  slack of all (0.013 ns) and does not fail.

## Measurement traps hit

- **`fk33ctl.py vccint` is not a read**; it is the MMIO stepper. Used as a
  check with `| head -2`, it moved both pots 68 -> 69 and died. (CLAUDE.md.)
- **The stock MMIO I2C bit-bang is too fast for the pot**: one read NACK and
  one write that did not land. The test script's `SlowI2C` flushes each GPIO
  write with a read and holds each edge 20 us; 100 of 100 reads clean on both
  cards afterwards, every write acknowledged.
- **Card 2's SYSMON swings about +/-3 mV**, which tripped a 2 mV "rail fell"
  guard with a median of 3 reads. The guard did its job (stepped back to 68);
  a median of 9 and a 3.5 mV threshold ran clean.
- **The "~24 ms of host time" in prefill** was attention's per-position growth
  (corrected in the pair profile README the same day).

## Open, not yet answered

- **Which path fails.** The KV mover is a lead from margin and position, not
  a measurement. A 0.72 V analysis needs a design timed at 0.72 V from
  synthesis (`set_operating_conditions` before `place_design`), not a re-time.
- **Whether 0.78 V holds at full context.** Only N=256 has run. The
  full-context test (65,536, ~17.5 h) has not.
- **Build 18 at 0.715 V is not proven safe either**: all its paths are signed
  off at 0.85 V too, and it passed only because it happened to have margin.
- **0.78 V is between characterised points** (-2L low-voltage window 0.698 to
  0.742 V, 0.85 V window from 0.825 V). Long-term reliability there is unknown.
- **Next, per Oren 2026-09-24: "We can interlock to there in the bitstream
  once we verify"**: move the VCCINT clamp (today `fk33ctl.py`'s wiper-68
  floor) to the verified wiper, in the tooling and the bitstream, after the
  full-context test passes.

## CORRECTION 2026-09-24 11:05: 0.78 V does NOT remove the hang. "The answer" above is WITHDRAWN as stated.

The next test at the same 0.779/0.780 V, `fk33_ctxtest.sh pair ... 500`
(`hw/fk33/results/card_build19_2026-09-24/silicon/hang/ctxtest_n500_b19_078V.log`):
input r1 and r2 PASS (500 GOs each), then **output r1 HUNG at decode 17 =
position 32, card 2, step 146 = C_JOB block 23, D WDOG**, the same signature
as every earlier hang.

| build 19 | runs | hangs |
|---|---|---|
| 0.715 V | 3 | 2 |
| 0.78 V | 11 | 1 |

**What survives:** the hang is voltage-SENSITIVE. P(at most 1 hang in 11 | the
0.715 V rate of 2/3) = (1/3)^11 + 11 (2/3)(1/3)^10 = 1.3e-4 (DERIVED), so the
rate fell. **What is withdrawn:** "it is a timing failure at the voltage the
cards run at" as a sufficient explanation, and "0.78 V fixes it". Either a
path is still failing occasionally at 0.78 V, or the mechanism is a race whose
odds depend on speed. It is still always position 32, always a C_JOB.

## CORRECTION 2 2026-09-24 12:25: the voltage effect is NOT established either. Withdrawn.

The sweep's first level, both cards at 0.800/0.802 V: `n256` input r4 HUNG at
position 32, card 1, step 52 (C_JOB), after three passes
(`hw/fk33/results/card_build19_2026-09-24/silicon/hang/ctxtest_sweep_v080_n256.log`).

**The error in CORRECTION 1 and in "The answer":** the 0.715 V rate was taken
from the THREE ctxtest runs alone (2 of 3). Every fresh sequence that crosses
position 32 is one trial, and the ordinary runs on build 19 at 0.715 V were
already in the hang README: Oren's run 1 (hang), repro2 and r1-r7 (pass), r8
(hang). Counted properly:

| build 19, VCCINT | sequences crossing position 32 | hangs |
|---|---|---|
| 0.715 V | 13 (2 Oren, 8 ordinary, 3 ctxtest) | 4 |
| 0.78 V | 11 | 1 |
| 0.80 V | 4 | 1 |

One-sided Fisher exact, 4/13 against 2/15: **p = 0.26** (DERIVED). No voltage
effect is demonstrated. The two probabilities quoted above (1.5e-4, 1.3e-4)
were computed against a rate estimated from three trials, which is the error.

**What still stands:** build 19 hangs and build 18 does not (0 of 16 ctxtest
runs plus the whole of 2026-09-23's pair work); always position 32, always a
C_JOB, on either card, at any voltage tried from 0.715 to 0.80 V.

**The better instrument:** the hang is at position 32 in prefill too, so a
40-id prefill (`TESTS=input fk33_ctxtest.sh pair <out> 40`, ~10 s per trial)
tests it at a fraction of the cost of n256/n500. The rate needs tens of trials
per condition, not four.

## CORRECTION 3 2026-09-24 12:40 (header first committed as "14:10", a clock error; the v085b log closed at 12:34): it hangs at the 0.85 V sign-off voltage. No threshold exists to find.

Oren asked for the threshold below which it glitches, and chose "Sweep UP
toward 0.85 V". Instrument: `TESTS=input REPEATS=30 fk33_ctxtest.sh pair <out> 40`
(a 40-id prefill crosses position 32 once per run, ~10 s per trial), both pots
raised with `fk33_vccint_test.py raise <target>`.

| build 19, VCCINT | sequences crossing position 32 | hangs |
|---|---|---|
| 0.715 V | 13 | 4 |
| 0.78 V | 11 | 1 |
| 0.80 V | 18 (4 n256 + 14 n40) | 2 |
| **0.85 V** (wiper 3, 0.8503 V) | **36** (30 + 6 n40) | **1** |

The 0.85 V hang (`ctxtest_v085b_n40x30.log`, run 6 of the second batch after
30/30 clean in the first): the `b16-31` half, **D WDOG at step 268, seq_pos 32**,
ERR_INFO `0x010c10c4`, the same signature as every earlier hang
(`v085b_input_r6_seam_hung.txt`).

One-sided Fisher (DERIVED, scipy): 0.85 V against 0.715 V p = 0.014; against
everything at or below 0.80 V pooled (7/42) p = 0.046; 0.80 V against 0.715 V
p = 0.12. These comparisons were chosen after seeing the data, so read them as
a possible trend in the RATE, not as a demonstrated effect.

**What this settles:** a static setup failure at the operating voltage is not
the mechanism, because the design is timed clean at exactly 0.85 V and still
hangs there. **The voltage question is closed: raising VCCINT is not a fix at
any value up to the sign-off voltage, and there is no threshold.** The P2
interlock has no verified V_RUN to carry for build 19.

**What stands:** build 18 does not hang; build 19 does, always position 32,
always a C_JOB, on either half, at every voltage from 0.715 to 0.85 V. The
leading hypotheses are now a race or CDC in what build 19 changed (NORM_HBM:
B's norm fetch on `bst_arvalid` requesting the grant C's KV ports share), or a
path Vivado does not time (an unconstrained crossing). Neither is measured.

Both pots returned to wiper 68 afterwards (`restore68_xdma1.log`,
`restore68b_xdma0.log`). Trap hit on the restore: the 2 mV "rail rose" guard on
an upward step tripped on SYSMON noise (+2.2 mV at wiper 53) and stopped there,
in spec; raised to 3.5 mV to match the raise path, then it completed.

## CORRECTION 4 2026-09-24 13:15: build 19 is a FIVE-variable change from build 18, not one. Every "only NORM_HBM changed" statement above is WITHDRAWN.

MEASURED by diffing the two build worktrees (`/mnt/storage/fk33_builds/wt18`,
`wt19`) and the committed trees. Build 18 is `c6af925` **plus
`build12_levers_off.patch`** (README line 3), as were builds 12b, 14, 15 and
17. Build 19 is `8af98b8` with NO patch. Since `a95017c` (2026-09-20, "build
11's two attention levers reach the card") the levers are ON in the committed
tree, so dropping the patch turned four of them on silently:

| lever | where | build 18 | build 19 |
|---|---|---|---|
| NORM_HBM (the change under test) | `fk33_card.vhd` | off (ROM) | on |
| `FAST_POP` | `gen_fk33_engine.py` `FAST_POP_DEFAULT`, A's FIFOs | false | **true** |
| `NWIDE` | `llama_top` B's norm | false | **true** |
| `SWEEP_PIPE` | `llama_top` `u_attn` (C) | false | **true** |
| `SCORE_EARLY` | `llama_top` `u_attn` (C) | false | **true** |

Build 18's log carries `Parameter FAST_POP bound to: 0` x8 and `NWIDE`,
`SWEEP_PIPE`, `SCORE_EARLY bound to: 0`; build 19's carries `FAST_POP bound to:
1` x8. Neither build 19's README nor its COMPOSITION.md mentions the patch.
`docs/debugging/2026-09-21_the-revert-and-the-lever-that-was-never-set.md:421`
records that `SWEEP_PIPE` and `SCORE_EARLY` had never been in a card build:
**build 19 is the first silicon they have run on, and the hang is always in a
C_JOB.** That is a lead, not an attribution.

This is the recorded CLAUDE.md trap ("enumerate what differs between two runs
from the runs' own recorded parameters, never from the intent of whoever
launched them") in the same shape as build 11b: the comparison was made from
what the build was FOR.

Simulation with the levers ON (`sim/tb_csweep_rate.vhd`, gate library, `-gP0=31
-gP1=32 -gP2=33 -gP3=64 -gSWEEP_PIPE=true -gSCORE_EARLY=true`): every job
completes, 67,407 / 67,743 / 67,967 / 74,911 cycles, slope 227.39 per position
(off: 351.42). The 04:10 simulation above ran at the bench defaults, i.e.
levers OFF, so it simulated build 18's C, not build 19's. A slave-timing matrix
with the levers on is running (`/mnt/storage/fk33_builds/card_build19/sim_levers/`).

**The silicon discriminator is a build:** `8af98b8` + `build12_levers_off.patch`
(NORM_HBM alone). Clean means NORM_HBM is exonerated and one of the four levers
causes the hang; hanging means NORM_HBM does.

### Slave-timing matrix with the levers ON (MEASURED 13:45, `sim_levers_on_matrix.txt`)

`tb_csweep_rate`, positions 31/32/33/64, `SWEEP_PIPE=true SCORE_EARLY=true`:
`STALL` 2, 3, 7; `RD_LAT` 20, 300; `SPREAD=3` (rescale pass firing), with and
without `STALL=3`; `MAXOUT=8` with and without `STALL=3`; `WR_LAT=200`. **Every
job completes** (position 32: 67,419 to 76,523 cycles). No hang reproduced.

**Trap hit, do not retry: `STALL=1` is a DEAD slave, not a slow one.** It
"hung" with the levers on, and looked like the reproduction. The bench gates a
beat when `(lfsr + s) mod STALL = 0`, which is always true for `STALL=1`, so no
read data is ever returned. Attribution control (`sim_stall1_control.txt`):
levers off, `SWEEP_PIPE` alone, `SCORE_EARLY` alone and both all hang at the
identical 2,000,155 ns. `RBUF=1` is refused by `attn_kv_axi`'s own assert and
is not a data point either.

So this bench, which has C alone against one modelled slave, does not
reproduce the hang with the levers either on or off. It has no B, no
`bc_port_grant`, and no second KV port. Build 20 decides which of NORM_HBM or
the levers a better bench has to model.

## CORRECTION 5 2026-09-24 21:10: NORM_HBM is EXONERATED. The hang comes with the levers.

Build 20 = `8af98b8` + `build12_levers_off.patch`: NORM_HBM on, `FAST_POP`, `NWIDE`,
`SWEEP_PIPE`, `SCORE_EARLY` off (worktree lines read back; synthesis log `FAST_POP bound to:
0` x8; the LEVERGUARD never fired). Default flow closed on the first draw: WNS +0.032, WHS
+0.009, 680,386 nets routed, 0 errors, sha256 `1176b271...`
(`hw/fk33/results/card_build20_2026-09-24/`). Both cards, the same `-nh` halves, the same
instrument, VCCINT 0.715 V (wiper 68), where build 19 hung most:

| build | VCCINT | sequences crossing position 32 | hangs |
|---|---|---|---|
| 19 (NORM_HBM + 4 levers) | 0.715 V | 13 | 4 |
| 19 | 0.78-0.85 V | 65 | 4 |
| **20 (NORM_HBM alone)** | **0.715 V** | **60** (2 x 30, n40) | **0** |

One-sided Fisher, build 20 0/60 against build 19 at 0.715 V 4/13: **p = 6.6e-4**; against
build 19 at every voltage (8/78): p = 8.8e-3 (DERIVED, scipy). The ids are byte-identical to
build 18's and build 19's for the same prompt. The standing N=500 pair test also PASSES (input
and output, twice each, 500 GOs, no seam error).

**What this settles:** the norm gain from HBM, selected by the descriptor, is not the cause.
**What it does not settle:** WHICH lever. `SWEEP_PIPE` and `SCORE_EARLY` are the leads (the
hang is always a C_JOB, and they are C's), but `FAST_POP` (A's FIFOs) and `NWIDE` (B's norm)
share the HBM ports with C through the same switch and are not excluded by anything measured.
Each earlier hypothesis in this file (static timing at 0.715 V, a voltage threshold, a
NORM_HBM race) was about the wrong variable; the constant across them is that build 19 was
compared with build 18 as if it differed in one thing.

**Next, if the levers are wanted:** one card build per lever group, C's two first (build 20 +
`SWEEP_PIPE`/`SCORE_EARLY` on), with the same n40 x 30 instrument. Until then the levers stay
off on the card, and `build12_levers_off.patch` is load-bearing: a card build without it
reproduces build 19.

**Correction to CORRECTION 4 and 5 (2026-09-25):** `NWIDE` was labelled "B's norm" in the
table and the text above. It is a generic of **`gdn_state_store`**, B's state-store movers
(MEASURED: `grep -lE '^\s*NWIDE\s*:\s*boolean' rtl/*.vhd` returns only that file). The
conclusions do not change.
