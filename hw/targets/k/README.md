# Composition derate k, per part and tier

`k = card clock the composed build achieved / the slowest rated block in that tier`
(tools/rate/tiers.py). `rate.py preflight` predicts a tier's clock as the WORST recorded
k times that tier's slowest block, so k is what turns standalone block ratings into a
card clock.

## Every VU33P k so far is a LOWER BOUND

Both entries come from card builds that MET their target (core `clk_out3`, 13.333 ns,
75 MHz): build 20 WNS +0.870, build 21 WNS +0.910 (MEASURED, each build's
`bd_wrapper_timing_summary_routed.rpt.gz`, Intra Clock Table). Vivado stops optimising
once a target is met, so the achieved 80.2 / 80.5 MHz is a floor on what the composed card
can do, and k is a floor with it. The prediction is therefore CONSERVATIVE until a card
build is launched at the predicted clock or above and misses.

- core: k >= 0.962 (build 20), >= 0.965 (build 21); slowest core block `v_swg`, 83.4 MHz.
- stream: k >= 0.433 / 0.434; A's engine runs on the same 75 MHz core clock in these builds
  (`FK33_ENG_CORE_MHZ=75`, no separate fast clock), so this k says only that A was never the
  limit. It becomes informative once a build clocks A on its own tier clock.

Not the 0.032 / 0.005 ns quoted as these builds' WNS elsewhere: those are the design-wide
minima and belong to `fk33_dmabram_BRAM_PORTA_CLK`, not the core.

The block ratings k used here are the current-tree records, admitted because their cache
keys equal the keys computed against the build trees `wt20` / `wt21` (the blocks' RTL is
byte-identical; only the tops differ, by the lever patches and `fk33_seam`).
