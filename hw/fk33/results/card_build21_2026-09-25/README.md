# Build 21: build 20 + C's two attention levers ON. Closed at 75 MHz; it HANGS at position 32 (5 in 90)

The one-variable lever test Oren chose after build 20 exonerated NORM_HBM. Tree
`/mnt/storage/fk33_builds/wt21` = `8af98b8` with `FAST_POP => false` and `NWIDE => false`
(from `build12_levers_off.patch`) and `SWEEP_PIPE => true, SCORE_EARLY => true` in `u_attn`
(`wt21.patch`, 4 files). Against build 20's worktree it differs in exactly the `u_attn`
generic line of `rtl/llama_top.vhd` and `rtl/fk33_llama_top.vhd` (MEASURED by `diff`); the
engine and generator are identical. Launch environment identical to builds 18-20. LEVERGUARD
kills the unit on `FAST_POP|NWIDE bound to: 1`.

Pre-registered: same instrument as builds 19 and 20 (40-id prefill across position 32,
30 repeats, twice, both cards, 0.715 V). **A hang means C's levers cause it; 0 of 60 means
FAST_POP or NWIDE does** (build 19 at this voltage: 4 of 13; P(0 of 60 | that rate) =
2.6e-10). Either verdict is about the pair SWEEP_PIPE + SCORE_EARLY, not one of them.

## Result (MEASURED 2026-09-25)

Build: `FK33_BUILD_DONE` 11:17, default flow, WNS **+0.005** ns, WHS +0.009, 680,564 nets
routed, 0 errors, sha256 `39fb6f31...` (`BITSTREAM.sha256`). Worktree read back:
`SWEEP_PIPE => true, SCORE_EARLY => true`, `NWIDE => false`, `FAST_POP := false`.

Silicon, both cards, 0.715 V, same `-nh` halves and instrument as builds 19 and 20:

| build | levers | sequences crossing position 32 | hangs |
|---|---|---|---|
| 20 | none | **150** | **0** |
| 21 | SWEEP_PIPE + SCORE_EARLY | **90** | **5** |
| 19 | all four | 78 (every voltage) | 8 |

Every build 21 hang is `seq_pos 32`, D watchdog, in a C_JOB: steps 235 (b0-15 half), 85, 85,
85, 207 (b16-31 half) (`silicon/hung_*.txt`). One-sided Fisher, build 21 against build 20:
**p = 0.0069** (DERIVED, scipy). Build 21 against build 19: p = 0.39, the same rate.

**Verdict, as pre-registered: C's two attention levers cause the hang.** `FAST_POP` and `NWIDE`
are not needed for it. WHICH of the two (or their combination) is not separated.

Measurement trap hit: the first rate script matched `rate_1.out` (a file) instead of `rate_1/`
(a directory) and so never reloaded the wedged card; its batches 2 and 3 re-read the same
sticky error and were NOT counted (`silicon/rate_INVALID_batches2-3.log`, kept for the record).
