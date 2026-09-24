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
| JTAG reload of card 1 (03:45), weights verified 126/126; ctxtest `n256_r4_after_reload` input r1, the FIRST sequence on the fresh card | prefill returned -3 | **card 1**, step **52** (its FIRST attention layer, block 3), D WDOG | **32** |

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

- ADDED 03:47: the fourth sample is also at position 32, and it was the first sequence after a
  fresh JTAG reload, so no state carried across sequences caused it. The layer is not fixed:
  card 1 has now hung at block 3 and at block 15, card 2 at block 19. The N=256 prefill has
  hung 2 of its 3 runs, which makes it a usable reproducer, unlike the 25-id prompt.
- Card 2's link has trained at 2.5 GT/s on the MCIO riser since build 18 (every reload log);
  not new, and not related.

## Simulation at position 32 (MEASURED 2026-09-24 04:10, GHDL, no hang)
`sim/tb_csweep_rate.vhd` is the only bench that runs `attn_block` + `attn_kv_axi` at the real 9B
geometry and KV_BLOCK 32, and its gate row visits positions 1/8/16/64 only, with a slave that
never stalls. Re-run from the gate's compiled library with `-gP0=31 -gP1=32 -gP2=33 -gP3=64` and
`-gSTALL=0/5/3`: every job completed, cycles 71,194 / 71,655 / 72,003 / 82,791 at STALL 0 and
within 20 cycles of that at 5 and 3 (`csweep_pos32_stalls.txt`). So a single C job at position 32
does not hang against this bench's slave model. Limits of that result: one job per position
rather than a 32-position sequence of KV writes, one modelled slave rather than the card's two
kv ports into the HBM switch, and an RVALID-gap pattern rather than ARREADY or write-response
back-pressure. The silicon failure is intermittent at a fixed position, which points at a
timing- or arbitration-dependent handshake the model does not produce.

## NOT established
- That position 32 / the KV block boundary is the cause (two samples; a hypothesis).
- Whether build 18 has the same hang (its logged runs crossed 32 without failing, few samples).
- Whether NORM_HBM is involved: the attention unit's RTL did not change in build 19, but its
  placement and routing did (WNS +0.008 ns).
- What state the attention unit is stuck in: the seam exposes nothing inside C.
