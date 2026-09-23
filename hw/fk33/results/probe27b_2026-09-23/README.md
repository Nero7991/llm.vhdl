# 27B area probe on the BC-250 (2026-09-23)

Synthesis-only OOC draws of the two blocks the 27B shape grows, each with its
9B control on the SAME tree and SAME script, one Vivado at a time under
`MemoryHigh=11G`. No hardware. Runner: `run27b.sh` (arms `attn27`, `attn9`,
`gdn27`, `gdn9`); `rerun_gdn27.sh` is the chained rerun of the 27B GDN arm
after its first draft died on a script-location refusal (see traps). Raw
reports and logs are under `out/`; `run27b.log` holds the per-arm sentinel
lines.

Every figure here is post-`opt_design` OOC (the `ooc_scorehdr.tcl` harness
runs `synth_design` and `opt_design`, no place or route). Both attention arms
reached the 11G cap (`memory.peak` == cap), so the wall times are throttled
and are not speeds.

## C: `attn_block` at the card's generics

`sim/ooc_scorehdr.tcl`, `HEAD_DIM=256 N_KVH=4 KV_BLOCK=32 N_ROT=64 POS_W=17
MANT_W=16 CM_W=8 EXP_W=8 NORM_LANES=1 STRICT_PRODUCER=true SWEEP_PIPE=false
SCORE_EARLY=false SCORE_HDR_TREE=0`, period 13.333 ns, one variable per arm:
`N_QH=16 LAYERS=8` (9B) against `N_QH=24 LAYERS=16` (27B).

| | 9B control (`attn9`) | 27B (`attn27`) | delta |
|---|---|---|---|
| CLB LUTs | 86,827 | 116,949 | +30,122 (+34.7%) |
| CLB registers | 101,221 | 130,927 | +29,706 |
| CARRY8 | 2,741 | 3,984 | +1,243 |
| F7 muxes | 16,374 | 24,819 | +8,445 |
| F8 muxes | 2,992 | 4,959 | +1,967 |
| block RAM tiles | 11 | 15.5 | +4.5 |
| DSPs | 298 | 430 | +132 |
| wall (throttled at the cap) | 982 s | 1,522 s | |

Per cell (`optutil_hier_*.rpt`, LUT / FF / DSP):

| cell | 9B | 27B |
|---|---|---|
| `u_arr` (`attn_mac_array`) | 50,531 / 39,465 / 256 | 76,535 / 58,871 / 384 |
| `(attn_block)` own logic | 24,618 / 50,824 / 0 | 26,623 / 59,432 / 0 |
| `u_norm` (`rmsnorm_rs`) | 5,471 / 5,306 / 22 | 5,471 / 5,306 / 22 |
| `u_gate`, `u_emit`, `u_rope`, per-head score and softmax | unchanged to within a few LUT | |

Reading: the growth is the MAC array and it is the structural one. DSP is
exactly `2 x G x KV_BLOCK` with G the query heads per KV head (4 -> 6):
256 -> 384, DERIVED and MEASURED equal. `u_arr` LUT grows 51.5% for a 50%
wider array; the block's own logic (the score header and the per-head
plumbing) grows 8%. Nothing else moves.

Against the card: build 18's in-context `gcr.u_attn` is 84,287 LUT / 298 DSP,
and the same-tree OOC 9B control is 86,827 / 298, so the OOC harness
over-counts C by about 2,500 LUT in this configuration. The +30,122 delta is
the number to carry, not the OOC total.

## B: `gdn_block` at the card's generics

`sim/ooc_gdn_block.tcl` (9B: `KEY_HEADS=16 VAL_HEADS=32 DIM=128 KCONV=4
LAYERS=24`, lanes 4/4) against a sed copy at `VAL_HEADS=48 LAYERS=48`.

Both arms bound the generics they claim (`Parameter VAL_HEADS bound to: 32`
/ `48`, `LAYERS 24` / `48`, everything else identical, read from the logs).
Neither reached the cap (`memory.peak` 10.45 GB and 9.57 GB under 11.81 GB),
so these peaks are real and the wall times are unthrottled.

| | 9B control (`gdn9`) | 27B (`gdn27`) | delta |
|---|---|---|---|
| CLB LUTs | 56,713 | 58,216 | +1,503 (+2.7%) |
| CLB registers | 33,687 | 33,998 | +311 |
| CARRY8 | 1,525 | 1,528 | +3 |
| F7 / F8 muxes | 4,355 / 816 | 4,399 / 732 | +44 / -84 |
| block RAM tiles | 22 | 22 | 0 |
| URAM | 0 | 2 | +2 |
| DSPs | 141 | 141 | 0 |
| post-synthesis WNS at 5.0 ns | 0.483 | 0.483 | (synthesis estimate, not a timing result) |
| wall | 311 s | 312 s | |

Reading: `gdn_block` walks its heads sequentially through the same 4/4-lane
datapath, so value heads and layers only widen counters and the per-layer
exponent memory; the compute does not grow. The +2 URAM is a depth-dependent
mapping flip (the same `acc_mem`/`u_mem` objects are named "will be
implemented using URAM" in BOTH logs while the 9B row reads URAM 0; the
utilisation row is the census, the message is not). B's real 27B cost is
elsewhere: the state store (`gdn_state_store`, 28 BRAM + 32 URAM in build 18)
scales with value heads, DERIVED x1.5, and the per-token state sweep time
scales the same way.

The identical WNS is not an artefact of an arm that cannot differ: the two
netlists differ in LUT, FF, mux and URAM counts, and the bound generics
differ. It says the critical path is in the shared datapath.

## Fit at 27B, DERIVED from build 18 plus these deltas

| resource | build 18 | + C | + B block | + B state (x1.5) | + D regions/swiglu | + norm ROM | total | of | note |
|---|---|---|---|---|---|---|---|---|---|
| LUT | 358,846 | +30,122 | +1,503 | ~0 | ~+1,500 | 0 | ~392,000 | 439,680 | 89% |
| block RAM | 567 | +4.5 | 0 | +14 | +50 | +132 | 767.5 | 672 | does not fit |
| block RAM without the norm ROM (Task 2) | 567 - 99 | +4.5 | 0 | +14 | +50 | 0 | ~536 | 672 | 80% |
| URAM | 32 | 0 | +2 | +16 | 0 | +27 to +40 (the moved gains) | ~90 | 320 | fits |
| DSP | 2,087 | +132 | 0 | 0 | 0 | 0 | 2,219 | 2,880 | 77% |

The D figures are the plan's DERIVED scalings (`region_mem` x 17408/12288,
`swiglu_mem` x FFN), not measurements. With `FK33_C_KV_BLOCK=16` (MEASURED on
the 9B: -14,383 LUT net, -112 DSP) the LUT total is about 377,600 (86%).
Build 18 routed at 81.6% on its first default draw; builds 14 and 15 failed
to route near that count on congestion, so 86 to 89% is a risk to be drawn,
not a fit to be assumed. The block RAM line is the hard one: the norm-gain
store must move before any 27B draw.

## The per-card 27B images (Task 3), MEASURED by the packer

`pack_cards.sh` (final flags inside). Base set `/mnt/storage/llama-models/qwen38-27b-mv4i/`
(498 `.mv4i`, Q4_K_M dequantised to INT4, 4.50 to 4.53 bits per weight);
per-card sets symlink those files and place them:
`qwen38-27b-card0-b0-32` (blocks 0..32, no head, `--desc-arena-jobs 607`) and
`qwen38-27b-card1-b33-63` (33..63 plus `output.weight`), both
`--model QWEN38_27B --stripe-lanes --stripe-all-segments --drop token_embd.weight
--card-maxpos 16384 --stripe-min-context 16384`, plus
`pack_gdn_consts.py --shape 27b` (3,956,736 B, 48 layers, PASS, same digest on
both cards).

| | card 0 | card 1 |
|---|---|---|
| weights | 7,095,816,192 B | 7,378,014,208 B |
| stack-1 segments | 13 (17..28, 16) | 13 (17..28, 16) |
| peak segment fill | 92.1% | 95.9% |
| `gdn_state_base` / bytes / layers | 0x1D0000000 / 78,741,504 / 48 | same |
| `kv_base` / bytes per token / layers | 0x1D4B18000 / 34,816 / 16 | same |
| `max_context_tokens` | 20,868 | 20,868 |
| `card_c_maxpos` / `card_kv_fits` | 16,384 / true | 16,384 / true |
| `gdn_const_base`, `desc_arena_base` (607 jobs) | 0x1FF5F8000, 0x1FFA10000 | same |

**Why 16,384 and not the plan's 32,768.** B and C index their HBM arenas by
the descriptor's GLOBAL per-kind layer ordinal (`job_ordinal`, descriptor
word 3, `rtl/llama_top.vhd` at `c_layer <= j_lay` and `b_layer <= j_lay`;
`docs/debugging/2026-08-29_ordinal-two-meanings.md`), so a card's arena must
span the whole model's layers exactly as the 9B cards' did: 16 KV layers
(34,816 B per token, not the plan's per-card 17,408) and 48 GDN layers
(78.7 MB). The width search then tops out at 20,679 tokens for either card
(the 33/31 split puts both `weights_end` in segment 28), and 32,768 does not
fit. 16,384 fits with 0.15 GB to spare on card 1.

**The way back to 32k+, not taken today:** the KV and state bases are
host-programmed registers (`A_KVK_LO/HI`, `A_KVV_LO/HI`, `bst_state_base`),
so a card could be given an arena sized for ITS layers only and a base offset
by `-(first ordinal x layer stride)`, so that ordinals 8..15 land at the
arena's start; the untouched lower ordinals would address below the arena and
are never issued on that card. Host and packer change only (`kv_layers_used`,
the offset in the manifest, the loader computing the programmed bases,
`check_kv_map` understanding it); no RTL. It roughly doubles the context per
card at the 27B.

`tools/check_kv_map.py` against a card generated at `FK33_MODEL=QWEN38_27B
FK33_C_MAXPOS=16384` refuses 12 rows, all of them because the checker sizes
its KV extent from the package's 9B binding and the 9B KVR block (it computes
a 65,536 x 17,408 extent that runs past HBM); it does not yet take `--model`.
The image's real extent, 16,384 x 34,816 = 570,425,344 B from `kv_base`, ends
at 0x1F6B18000, below `gdn_const_base`. That checker change is open.

## Traps hit

- **A copied Tcl script must live where its `pfRoot` derivation expects.**
  `sim/ooc_gdn_block.tcl` derives the repo root from its own location and
  refuses elsewhere (`pfRoot: derived repo root ... does not contain
  rtl/util_pkg.vhd`). The first `gdn27` draft wrote the sed copy into the
  output directory and the arm died in 12 s with rc=1, sentinel 0. The fix
  is `$ROOT/sim/ooc_gdn_block_27b_probe.tcl`; `run27b.sh` now does that and
  `rerun_gdn27.sh` chains the arm on the first run's `PROBE27_DONE`.
- **A row window that is legal at K = 4096 is illegal at K = 5120.** The
  first 27B programs refused 50 (card 0) and 53 (card 1) A jobs with
  `ERR_ALIGN: base word 8`: every padded qkv segment start (rows 2064, 4128)
  and every lm_head window start (17,376-row stride). A lane tile is
  `nb x 32` bytes, 4096 at K = 4096 and 5120 at K = 5120, and the gateware
  refuses a port base with [11:0] nonzero, so at 5120 only every fourth tile
  boundary is a legal window start. `gen_mv4i_desc.window_granule` (48 at
  4096, 192 at 5120) now sizes the qkv pad (starts 0 / 2112 / 4224) and the
  lm_head stride (17,280); the 9B numbers are unchanged. The qkv tensors had
  to be re-packed.
- **A base pack at a new shape can refuse at its manifest after packing every
  tensor.** The first 27B base pack packed all 498 tensors in 87 minutes and
  then refused at `a_descriptor_jobs`, which compared `output.weight` against
  the 9B shape (fixed: it takes `--model`). The files were fine and the
  per-card packs KEEP them; only the base manifest is missing, and nothing
  loads the base set.
- **The BC-250's login home is not the tree's home.** `ROOT` defaults to
  `$HOME/GitHub/llama.vhdl`, which is `/home/labuser/...` there, while the
  synced tree is at `/home/orencollaco/GitHub/llama.vhdl`. The rerun was
  first launched without `ROOT` and produced an empty 27B script
  (`PROBE27_GDN27_SED_HITS 0`); it was killed by its argv[1], never by a
  substring of the command line, and relaunched with `ROOT` set.
- **`memory.peak` at the cap is the cap.** Both attention arms show
  `memory.peak` 1 to 4 MB above `memory.high`; the true appetite of an
  `attn_block` OOC at 27B is unknown and at least 11 GB. `swap.peak` was
  10.2 GB (27B) and 7.0 GB (9B).
