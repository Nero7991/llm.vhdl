# Two-card 9B pipeline on silicon, 2026-09-23: the pair equals the single card id for id, prefill 1.84x

Hardware: card 1 (JTAG 153300000607A) at PCI 0000:07:00.0 as `/dev/xdma0`, card 2 (153300001366A) on
the MCIO riser from the free chipset x4 slot at 0000:06:00.0 as `/dev/xdma1`, both Gen3 x4, both
build 18, VCCINT 0.716 / 0.713 V. Images: `qwen35-9b-card0-b0-15` on xdma0 (blocks 0..15, no head),
`qwen35-9b-card1-b16-31` on xdma1 (blocks 16..31 + `output.weight`), both verified 126 / 127 of 127
objects. Reference: `single_card_build18/` (the same three prompts on one card with the full image).

## The oracle (Task 11 step 3), MEASURED

| prompt | single-card ids | pair, first run | pair, with the fix |
|---|---|---|---|
| What is a DC-DC converter? | 128 | FIRST DIVERGENCE at 7 (318 vs 369) | **MATCH all 128** |
| Explain how a hash table works. | 128 | FIRST DIVERGENCE at 28 | **MATCH all 128** |
| Write a short poem about the ocean. | 70, stop token | FIRST DIVERGENCE at 0 (760 vs 32) | **MATCH all 70** |

The first run's divergence was root-caused the same morning: the RMSNorm gain table on the card is
indexed by a per-token counter of norm ops, so card 1's program, which starts at block 16, normalised
every block with the gains from 16 blocks earlier. `docs/debugging/2026-09-23_the-norm-gain-is-indexed-
by-a-per-token-counter.md` has the whole chain, ending in card 1 reproducing the full card's token 0
and final residual bit for bit once 32 throwaway norms precede block 16 (`gen_layer_program.py
--pad-norms`, applied by `fk33_chat2.sh` as `2*lo`). `pair_build18/rootcause/` holds the dumps.

## Timing (Task 11 step 4), MEASURED from `tstamp.py`'s per-read clock and run_prompt's own lines

| | single card (build 18) | pair (build 18, padded) |
|---|---|---|
| 20-id prefill to first token | 6.15 s (0.308 s/pos) | 3.9 s (0.19 s/pos), 1.58x |
| **1,240-id prompt** (`--max-new 8`), wall | **398.1 s** (12b characterisation, 396.3 s card time) | **215.9 s**, 1.84x; card time 417.7 s summed over both cards |
| decode, median s/token at positions 20..147 | 0.2988 (3.35 tok/s) | 0.311 (3.21 tok/s) |
| hop per token | none | read R_X 6.8 ms + push+GO 1.0 ms (147 hops: 0.999 s + 0.146 s) |
| padding per token on card 1 | none | ~5.5 ms (run_chunk 44.52 vs 43.71 s over 147 GOs) |

Prefill overlaps as designed (card 0 runs position p+1 while card 1 runs p): 1.84x on the long prompt,
against a 2x ceiling. Decode is serial through the hop by construction, so the pair is 4% slower per
token than one card, which is the cost of the hop and the padding and is what the spec predicted. No
divergence at any position on any prompt.

Not chased: the first prompt of a session pays about 16 s extra before its first token (both pair
runs, prompt 1 only: 19.9 and 20.4 s against 3.9 s for prompts 2 and 3); the pair's `prefill` line
prints `exp 0` because `plp_prefill` does not return the logit exponent (cosmetic).

## What is established and what is not

ESTABLISHED: the host-mediated layer split computes exactly what the single card computes, at every
position of three prompts, and prompt processing is 1.84x faster on two cards. The card window, the
XIN push, the position alignment and the argmax hand-off are all correct.

NOT ESTABLISHED: any decode speed-up (none is designed in at batch 1); behaviour past position 1,247;
the 27B fit (a separate build).

OPEN, with the fix known: the norm-gain indexing belongs in the RTL (index `NW_TBL` by the step's
`const_base`, 2 per block plus the tail) so no card needs the padding; that is a card build. Until it
lands every split program must carry `--pad-norms 2*lo`, and `fk33_chat2.sh` does.

## Files

`single_card_build18/` (the reference recordings, from earlier today); `pair_build18/`: three prompts
x 2 runs (`pair_p<i>_r1` diverging, `pair_p<i>_r2` matching), `long/` the 1,240-id run, both cards'
reload and load logs, `run_pair.sh`; `pair_build18/rootcause/`: the loopback probes, the comparator,
and the bit-exact dumps (full card's block-15 and block-16 residuals, card 1's block-16 residual
without and with the padding, card 1's final residual with the padding, the two XN dumps).
