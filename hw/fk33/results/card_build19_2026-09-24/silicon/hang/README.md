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

- Both captured hangs are in the attention unit (C_JOB), and both first failures are at position 32,
  the first position of the second KV block (the 9B card is built at C_KV_BLOCK 32). Hundreds of
  other attention jobs tonight passed, including every position-64 crossing of the 64-token runs.
- It is not one card: card 2 and then card 1.
- Once wedged, the unit hangs every later token, even at position 0: CLR_ERR clears the flag only.
- `fk33_hotreset.sh` (secondary bus reset) DID reset the card logic (seam cycles 0, error clear) and
  HBM kept its contents (127/127 digests), BUT the card's host-to-card DMA then timed out on every
  write, 4 KB included, while reads and the other card worked. A JTAG reload fixed it. So the hot
  reset is NOT a usable recovery on this design; plan Task 4b must account for the write path.

## NOT established
- That position 32 / the KV block boundary is the cause (two samples; a hypothesis).
- Whether build 18 has the same hang (its logged runs crossed 32 without failing, few samples).
- Whether NORM_HBM is involved: the attention unit's RTL did not change in build 19, but its
  placement and routing did (WNS +0.008 ns).
- What state the attention unit is stuck in: the seam exposes nothing inside C.
