# bitstreams/ -- milestone bitstreams, committed on purpose

Every other bitstream in this repo is ignored (`hw/fk33/bit/`,
`build_artifacts_*/`) because they are large and reproducible. The ones here
are the exceptions: a bitstream is committed when it marks a result that
should stay reachable without a 4-5 hour build and a placement draw that may
not reproduce (two of five card implementations on 2026-09-19/20 failed to
route from the same netlist; see `hw/fk33/results/card_swg_2026-09-20/`).

Load one with the sudoless reload (`hw/fk33/host/fk33_reload.sh`, absolute
path), then reload the weight image, `gdn_const.bin` and the descriptor arena:
HBM does not survive a reconfiguration (MEASURED 2026-09-19).

## fk33_qwen35-9b_first-answer_75mhz_2026-09-20.bit

The first bitstream on which the card produced a comprehensible, correct
answer. Qwen3.5-9B INT4, prompt "In what cases is DC-DC converters better
than transformers": 23-token prefill, 160 generated tokens, no faults, first
generated token equal to the BF16 reference (1206). Transcript:
`hw/fk33/results/card_swg_2026-09-20/dcdc_prompt_160.txt`.

| | |
|---|---|
| source commit | `8dbe160` (merge of the SwiGLU adapter; WORKLOG at `e40067f`) |
| tag | `v3.0-first-answer` |
| size | 25894366 bytes |
| sha256 | `8257e25cf854c895855712ad4b283f583c34f97612df21d92934852b298193f2` |
| md5 | `996a093d2e2060f92341d9a29b495cbb` |
| part | xcvu33p-fsvh2104-2L-e, SQRL FK33 card 153300000607A |
| generator | `FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 hw/fk33/pcieep_build.sh` |
| card generics | `hw/fk33/gen_fk33_card.py` at that commit: A_DESC, B_SRC_REAL, B_STATE_AXI, B_CONST_HBM, C_REAL, C_KV_AXI, NORM_REAL, SWG_REAL, SMP_EN, NORM_W_IMAGE, C_QKN_IMAGE |
| synthesis | `synth_1` from `8dbe160`, 362,195 CLB LUT (82.4%), 547.5+ BRAM, 2,088 DSP (see the placed utilization report beside the transcript) |
| implementation | strategy `Congestion_SpreadLogic_high` with `place_design -directive ExtraNetDelay_high`, `phys_opt_design -directive AggressiveExplore`, `route_design -directive AlternateCLBRouting`; the Tcl is `hw/fk33/results/card_swg_2026-09-20/reimpl.tcl` |
| timing | WNS +0.050 ns, WHS +0.009 ns at 75 MHz core (13.333 ns), fully routed |
| failed draws | the default placement left 209 unrouted / 121 overlaps, with and without AlternateCLBRouting |
| seam | v2, CAPS_FLAGS 0x1D (windows, sampler, logits, engine seq reset); `A_TOK_POS` at 0x8C |
| model image | `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json`, `gdn_const.bin` blake2b `ec3eda1ae15abf20326541ceacdeb917` |
| host | `server/run_prompt --allow-hardware HOST --seq-reset --v2 --dtbl <token.dtbl> --rel <token.rel> ...` with the token program from `tools/gen_layer_program.py --token --shape 9b` |
| throughput | about 0.8 s per token (61.2 M core cycles per token at 75 MHz), not yet optimised |

What it does NOT do: agree with the BF16 reference token for token past
token 0 (INT4 weights and Q12 fixed point under greedy decoding diverge at
token 1 to an equally sensible continuation). The logit-level gap at token 0
has not been measured yet.

## fk33_qwen35-9b_kvreg-striped_75mhz_2026-09-20.bit

sha256 `f1caefe86b1f463200d97b769c5770760d97048935682ff5f58c38f7909a15f5`,
25,745,854 bytes. Build 9, `FK33_CARD=1 FK33_CB_STYLE=distributed
FK33_ENG_CORE_MHZ=75 FK33_IMPL_STRATEGY=Congestion_SpreadLogic_high`,
routed WNS +0.061 ns, WHS +0.009 ns.

THE FIRST BITSTREAM THAT RUNS THE LANE-STRIPED IMAGE. C's KV cache base is
a seam register (`A_KVK/A_KVV` at 0x90..0x9C, caps bit 5) that the host
programs from the loaded manifest, instead of a generic compiled from the
FLAT manifest; `C_MAXPOS` is 65,536. On the previous bitstream the striped
image ran 2.05x faster and produced a wrong argmax, because C wrote its KV
records into 41 weight objects at the compiled flat address.

MEASURED on the card, image
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27`:
token 0 argmax **846** (the BF16 reference value) with `smp_n 248320`;
**0.4058 s/token = 2.46 tok/s over 182 GOs, 2.04x** the flat image's
0.828 s; `fk33_load_weights.py verify` 251 of 251 objects PASS after 34
tokens and again after 182.

Requires a lane-striped image whose KV extent fits `2 * 65536 * 8704` and
whose GDN state sits on a segment boundary. The flat image still works;
`hw/fk33/host/fk33_chat.sh` defaults to it, so set `FK33_MODEL_DIR` to use
the striped one.
