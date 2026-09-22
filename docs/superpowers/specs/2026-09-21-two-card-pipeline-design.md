# Two-card pipeline inference over PCIe, host-mediated (subsystem E, phase 0)

Date: 2026-09-21. Status: design approved in conversation, spec for review.
Author of record: Oren Collaco, with the dispatcher session.

## 1. Goal and non-goals

**Goal.** Run one model across two FK33 cards on this workstation, both on
the host's PCIe (bifurcated x8/x8 slot, MCIO, each card at Gen3 x4), with the
host carrying the activation between them. Phase 0 proves the path on the
9B with the existing bitstream design; the purpose is the 27B, whose 13.5 GB
of INT4 weights do not fit one 8 GiB card.

**Non-goals for this spec.** Tensor parallelism (the `E_COLL` steps stay
inert), card-to-card PCIe peer-to-peer, the Aurora link
(`~/GitHub/pcie-llm-hardware`), any speedup on the 9B at batch 1, and the 27B
build's area fit, which is a separate question with its own build.

## 2. The split: by layer, never through a matrix

| card | 9B rehearsal | 27B | also holds |
|---|---|---|---|
| card 0 | blocks 0..15 | blocks 0..32 | nothing else; the embedding is on the host |
| card 1 | blocks 16..31 | blocks 33..63 | `output_norm`, `output.weight`, the sampler |

The 27B boundary is one block past half to offset the LM head's cost on
card 1 (DERIVED from the 9B profile: `output.weight` is 1.06 M cycles against
0.66 M for a block; the 27B ratio is similar). It is a parameter, not a law;
measure both cards' GO times and move it if they differ by more than a
block.

Per-card HBM at 27B, DERIVED from the config (64 layers, hidden 5120, FFN
17408, 48 GDN value heads, 24 query and 4 KV heads at head_dim 256) at INT4
plus scales: about 6.5 GB of blocks per card, plus 0.67 GB LM head on card 1,
leaving about 1.5 GB for KV at 17 KB per token per card. 32k context fits;
64k is the ceiling. GDN state is 38 MB per card and constant in context.

## 3. Images and manifests

One image and one manifest per card, produced by the existing
`tools/pack_model_fk33.py` with `--drop` of every tensor belonging to the
other card (and of `output_norm` and `output.weight` on card 0). Nothing
about placement changes: the descriptor arena, the KV base register, the GDN
state region and the 512-byte image record keep their meaning per card, so
`fk33_load_weights.py load --verify`, `fk33_imgfp.py` and `fk33_chat.sh`'s
resident-image refusal all work unchanged on each card. A `--blocks lo:hi`
convenience may be added to the packer as sugar over `--drop`; it must
refuse a range that leaves a block on neither card or on both.

Both cards carry the SAME bitstream. Card identity is a property of the
image and the program loaded, not of the build.

## 4. Token programs

`tools/gen_layer_program.py --token` emits per block; it gains
`--blocks lo:hi` and `--no-lmhead`. Card 0's program runs its blocks and ends
with `END_TOKEN`, leaving the residual in R_X with no norm, no LM head, no
sampler step. Card 1's program runs its blocks, then `output_norm`, the LM
head windows and the sampler exactly as today. Card 1's residual input is
whatever the host wrote into R_X through window 2, which today is the
embedding row and in this design is card 0's output; D cannot tell the
difference and does not need to.

`blk` numbering stays global on both cards, so per-layer KV and GDN state
addressing is unchanged and each card's manifest simply lacks the other's
layers. Generator self-check, required: card 0's steps followed by card 1's
steps must equal the single-card token program with one extra `END_TOKEN`
inserted at the boundary, byte for byte in the descriptor images.

## 5. The hop: host through the MMIO windows

Per position the host does, in order:

1. Write the embedding row into card 0's window 2 and `X_EXP`; GO; poll STATUS.
2. Read card 0's window 3 (the residual region, `hidden` int16 mantissas) and
   the new `X_EXP_OUT` register (section 6).
3. Write those into card 1's window 2 and `X_EXP`; GO; poll STATUS.
4. Take card 1's argmax (or the logits row) as today.

Cost: the X push measures 1.77 ms per token on the 9B today (MEASURED, 3.690 s
over 2,084 GOs). The readback is non-posted and is ESTIMATED at 2 to 3x that
until measured. Budget the hop at 3 to 5 ms per token against a 27B token of
about 0.8 s (ESTIMATE from the 9B rate scaled by parameters), under 1%. If it
ever matters, the recorded alternative is an HBM DMA hop (D store op plus an
HBM X load on card 1), not peer-to-peer.

**Prefill overlaps.** Every prompt position is known in advance, so card 0
runs position p+1 while card 1 runs p; prompt processing approaches 2x the
single-card rate. Decode is serial: the next token waits for card 1's
argmax. The driver must not reorder: card 1's GO for position p must
complete before card 0's GO for position p+1 is issued during decode.

## 6. RTL change: one register

The seam (`rtl/fk33_seam.vhd`) publishes D's captured block exponent for
region R_X as a read-only register `X_EXP_OUT`, valid after `tok_done`, next
to `LOGIT_EXP`. Today the only exponent readbacks are the host's own written
`X_EXP` (echoed) and `LOGIT_EXP`; window 3 gives mantissas without their
exponent. `server/fk33_seam.h` gains the offset and the seam's self-check
against the header covers it. Nothing in A, B, C or D changes. This is one
card build (build 14 or later) before the first exact hop; a build already
scheduled for other reasons should carry it.

The 27B afterwards is `MODEL := QWEN38_27B` in `rtl/model_cfg_pkg.vhd` plus
the per-card images and programs. Its fit (the attention MAC array grows 1.5x
at 24 query heads over 4 KV heads; the part is at 99% CLB) is outside this
spec.

## 7. Host driver

`server/pl_backend.c` already takes `dev_user`/`dev_h2c`/`dev_c2h` as
options, so card 1 is a second `pl_open` on `/dev/xdma1_*`. A new layer
`server/pl_pipeline.c` owns two `pl_ctx`, the hop, the prefill overlap and
the serial decode; `run_prompt` gains `--card2 <manifest>` and `--dtbl2/--rel2`.
`hw/fk33/host/fk33_chat2.sh` runs the existing per-card setup (arena load,
GDN state zero, KV base) once per card with its own manifest. Reload and
weight load remain per-card operations under the hardware rule: a human runs
them, never a subagent.

## 8. Testing

1. **Oracle, silicon.** The single-card 9B against the two-card 9B, same
   three prompts, 128 tokens each, argmax equal at every position. A wrong
   exponent or a wrong boundary diverges within a few tokens.
2. **Generator self-check** (section 4), a gate row.
3. **Seam bench** for `X_EXP_OUT` against the reference stream's residual
   exponent at the end of the token (`tools/ref9b` landmarks `R_XN.final`).
   The reference capture `tok0.r9bs` was lost with `/tmp` on 2026-09-20 and
   must be regenerated first.
4. **Hop cost, measured**, with the per-token timestamper used for build 12b,
   reported as a share of the token, not as an estimate.
5. **Prefill overlap, measured**: a 1,240-id prompt on two cards against the
   single-card 393.9 s.

## 9. Sequence

1. Seam register plus header plus bench (RTL, no hardware).
2. Generator block range and self-check; packer `--drop` per-card images
   for the 9B (host tools, no hardware).
3. `pl_pipeline` and `fk33_chat2.sh`, testable on ONE card by running both
   halves on the same device sequentially (the hop through the host is
   identical), which needs no second card and no new bitstream for the
   program and image work, only for the exact exponent.
4. Card build carrying the register; load both cards; oracle run.
5. 27B images, programs and build.

## 10. Open, not answered here

- Whether the 27B geometry fits the part; the attention array is the term.
- The window-3 readback rate on this host; it decides whether the HBM hop is
  ever needed.
- Whether the release-mask table (window 1) or any per-model window needs a
  per-card variant; it is emitted per program, so it should follow the
  program, but this has not been checked.
- How `fk33_reload.sh` and `fk33-pci` select a card when two enumerate.
