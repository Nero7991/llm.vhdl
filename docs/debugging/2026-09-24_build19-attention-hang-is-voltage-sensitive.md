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
