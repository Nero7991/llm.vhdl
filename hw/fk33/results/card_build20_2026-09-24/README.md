# Build 20: NORM_HBM with the four levers OFF. Closed at 75 MHz, and it does NOT hang (2026-09-24)

Worktree `/mnt/storage/fk33_builds/wt20` at `8af98b8` (build 19's tree, plan Task 2) **plus
`build12_levers_off.patch`** (copied here), so the only design change from build 18 is
NORM_HBM. Launch environment identical to builds 18 and 19 (`launch.sh`):
`FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 FK33_SYNTH_THREADS=1`,
`MemoryHigh=24G`, swap guard, and a LEVERGUARD that kills the unit on any `FAST_POP|NWIDE|
SWEEP_PIPE|SCORE_EARLY bound to: 1` (teeth: 8 on build 19's log, 0 on build 18's; 0 here).

Why it exists: build 19 hung at position 32 in a C_JOB and was compared against build 18 as
a one-variable change. It was five
(`docs/debugging/2026-09-24_build19-attention-hang-is-voltage-sensitive.md`, CORRECTION 4).

## Build (MEASURED)

Launched 13:20, `FK33_BUILD_DONE` 20:46, default flow, first draw, no re-implementation.
Routed WNS **+0.032 ns**, WHS +0.009 ns, 680,386 nets fully routed, 0 routing errors.
`FK33_REGION0_WE OK` (4 of 4), `FK33_UNCONNECTED count=0`, `FAST_POP bound to: 0` x8.
The attention levers' bind lines appear in neither build 19's nor build 20's log, so the
worktree was read back instead: `SWEEP_PIPE => false, SCORE_EARLY => false` and `NWIDE =>
false` in both `llama_top.vhd` and `fk33_llama_top.vhd`, `FAST_POP : boolean := false` in
`fk33_engine.vhd`. Bitstream sha256 `1176b27148ee5849...` (`BITSTREAM.sha256`), also at
`hw/fk33/bit/fk33_card_build20_normhbm_leversoff_75mhz_2026-09-24.bit`.

## Silicon (MEASURED, both cards, VCCINT 0.715 V / wiper 68, `-nh` halves)

| test | result |
|---|---|
| reload + load --verify, both cards | 126/126 and 127/127 (`silicon/b20_*.log`) |
| 40-id prefill across position 32, 30 repeats, twice | **60 of 60 pass**, ids identical to builds 18 and 19 |
| standing N=500 pair (input + output, twice) | PASS, 500 GOs each, no seam error |
| standing N=500 single (full image on card 1) | PASS, 500 GOs each, no seam error |

Build 19 on the same instrument at the same voltage: 4 hangs in 13. Fisher one-sided p =
6.6e-4. NORM_HBM is not the cause of the hang; one of the four levers is.
