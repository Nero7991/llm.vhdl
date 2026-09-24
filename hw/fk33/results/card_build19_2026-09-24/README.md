# Build 19 on silicon: the norm gain from HBM, selected by the descriptor (2026-09-24)

Bitstream `bd_wrapper.bit` (sha256 9366b396...c18), tree `8af98b8`, plan Task 2. Both FK33s,
loaded by the main session with `hw/fk33/host/fk33_reload.sh` (VCCINT untouched, 0.716 V).

## Results (MEASURED; raw output in `silicon/`)

| test | result |
|---|---|
| seam after reload | id LLM2, cap flags 0x7D, faults 0, 36.4 C |
| image `qwen35-9b-mv4i-noembd-striped-seg27-nh` (norm rows appended) | load --verify PASS, 251 of 251 objects |
| control "What is a DC-DC converter?" 64, three runs | identical to each other and to build 18's text; 19.399 s per 83 GOs |
| token 0 (`--prompt 248045`), `--dump-xout` | **bit-identical to build 18's capture**: exponent 8 and all 4,096 mantissas, 0 differ |
| token 0 against `tok0.r9bs` (llama.cpp float) | exact FAIL / anchor PASS, the same verdict and first mantissas as build 18 (cross-format) |
| pair, both cards build 19, `-nh` halves, **no pad norms** (card 1 program 261 descriptors) | 64-token text == single card; 19.408 s |
| pair, same, with 32 pad norms (294 descriptors), control | == single card; 19.849 s |

So on silicon: the HBM path serves the same gains as the ROM path (token-0 residual identical to
build 18), and the two-card split is exact WITHOUT the `--pad-norms` workaround, which is the
defect `docs/debugging/2026-09-23_the-norm-gain-is-indexed-by-a-per-token-counter.md` is about.
The pads' removal saves 0.44 s per 83 GOs (2.2%).

The kill case for the pad-free pair is the original measurement of that note (build 18: the pair
diverged from the single card at its first step); it was not re-run on build 18 here.

## Not changed, on purpose
`fk33_chat2.sh` still pads by default (`FK33_PAD_NORMS=1`). On a build 18 card a pad-free program
reproduces the bug silently, and nothing on the card says which bitstream it runs. Flip the default
when CAPS_FLAGS carries a NORM_HBM bit (plan Task 2).

## Traps hit
- **xdma numbering follows the reload, not the card.** After reloading card 1, `xdma0` was
  06:00.0 (card 2); after reloading card 2 it swapped back. Identify a card by its seam state and
  image record (`fk33ctl.py seam`, `fk33_imgfp.py which`), never by the node number.
- **`fk33_chat.sh` split its devices**: the Python tools followed `FK33_USER=/dev/xdma1_user` and
  `run_prompt` opened its default `/dev/xdma0`. The image lock refused it before any GO. Fixed:
  `FK33_USER` now also sets `run_prompt --dev`.
- The build 19 control run is 19.399 s against build 18's recorded 24.578 s for the same 83 GOs.
  NOT attributed: the norm path cannot plausibly save 5 s, and the conditions of build 18's run are
  not recorded. Re-measure both on one box state before quoting a speed change.
