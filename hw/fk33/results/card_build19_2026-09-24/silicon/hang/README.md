# Build 19: an intermittent attention hang at position 32 (OPEN, not root-caused)

2026-09-24, both FK33s on build 19, 9B pair with the `-nh` halves, prompt
"What is a DC-DC converter in 10 words?" (25 ids; decode reaches positions 25..33).

## What was MEASURED
| run | result | failing card, step | position |
|---|---|---|---|
| Oren's run 1 | decode 8 returned -3 | not captured (overwritten) | 32 |
| Oren's run 2, and a probe after CLR_ERR | card 2 hung at step 85 (its first C_JOB) on EVERY token | card 2, C_JOB block 19 | 0 (unit already wedged) |
| after reload of card 2: `repro2`, then r1..r7 | 8 passes, stop token at 33 | - | - |
| r8 | decode 8 returned -3 | **card 1**, step 235 = C_JOB block 15, D WDOG, ERR_INFO 0x00EB0EB4 | **32** |
| ctxtest `n256_try1` input r1 (256-id real-text prompt, PREFILL) | pass, 256 GOs | - | 0..255 |
| ctxtest `n256_try1` input r2 (the same prompt, after `--seq-reset`) | prefill returned -3 | **card 1**, step 235, D WDOG, ERR_INFO **0x00EB0EB4** (identical to r8) | **32** |

- Both captured hangs are in the attention unit (C_JOB), and both first failures are at position 32,
  the first position of the second KV block (the 9B card is built at C_KV_BLOCK 32). Hundreds of
  other attention jobs tonight passed, including every position-64 crossing of the 64-token runs.
- It is not one card: card 2 and then card 1.
- Once wedged, the unit hangs every later token, even at position 0: CLR_ERR clears the flag only.
- `fk33_hotreset.sh` (secondary bus reset) DID reset the card logic (seam cycles 0, error clear) and
  HBM kept its contents (127/127 digests), BUT the card's host-to-card DMA then timed out on every
  write, 4 KB included, while reads and the other card worked. A JTAG reload fixed it. So the hot
  reset is NOT a usable recovery on this design; plan Task 4b must account for the write path.

- ADDED 03:42, MEASURED by `hw/fk33/host/fk33_ctxtest.sh pair ... 256` (evidence under
  `/mnt/storage/fk33_builds/card_build19/ctxtest/n256_try1/`): the hang is NOT decode-only. It hit
  in PREFILL, again at position 32, again on card 1 at step 235 with the identical ERR_INFO. Run 1
  of the same prompt had just crossed position 32 and six more block boundaries (64..224) cleanly,
  so a given position is not deterministically fatal. Third sample at position 32 out of three.
  Card 1 fails at its LAST attention layer (block 15); card 2 failed at its FIRST (block 19).
- Instrument trap hit on that run: `fk33ctl.py seam` with FK33_USER alone reads the image record
  through xdma0's DMA nodes, so the xdma1 dump's image block named card 2's image. Status lines
  were right. Fixed in the script (all three nodes set).

## NOT established
- That position 32 / the KV block boundary is the cause (two samples; a hypothesis).
- Whether build 18 has the same hang (its logged runs crossed 32 without failing, few samples).
- Whether NORM_HBM is involved: the attention unit's RTL did not change in build 19, but its
  placement and routing did (WNS +0.008 ns).
- What state the attention unit is stuck in: the seam exposes nothing inside C.
