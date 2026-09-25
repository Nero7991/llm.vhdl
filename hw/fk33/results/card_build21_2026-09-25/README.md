# Build 21: build 20 + C's two attention levers ON (IN FLIGHT, launched 2026-09-25 06:08)

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
