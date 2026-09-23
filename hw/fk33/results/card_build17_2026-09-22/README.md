# Build 17: build 15 + the KV fetcher counters. CLOSED at 75 MHz on the first default draw, WNS +0.373 on the core clock.

Worktree `/mnt/storage/fk33_builds/wt17` at `f14121d` (HEAD: build 15's tree + `rtl/attn_kv_axi.vhd` keeping
(record, chunk, slot) as per-beat counters instead of dividing the beat counter by 17) plus
`build12_levers_off.patch`. `FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75`, default recipe
(`Performance_RefinePlacement`), launched 19:38, `FK33_BUILD_DONE` 23:35. Composition read from the log:
`CB_STYLE bound to: distributed` x4, `NWIDE/FAST_POP/SWEEP_PIPE/SCORE_EARLY bound to: 1` count **0**,
`HOST_WINDOW 0`, `SHADOW_REGION 0`, `C_KV_BLOCK 32`, `FK33_CORE_MHZ 75.000`. Every prediction is in
`COMPOSITION.md`, written before launch and scored in place.

## The verdict, from the authority

```
# of routable nets..................... :      678393 :
    # of fully routed nets............. :      678393 :
# of nets with routing errors.......... :           0 :
```

```
    WNS(ns)  TNS(ns)  Failing  Total      WHS(ns)  THS(ns)  Failing  Total      WPWS  Failing
      0.118    0.000        0  1527254      0.009    0.000        0  1527206    0.000        0
```

Per clock (Intra Clock Table): **`clk_out3` 75 MHz core clock WNS +0.373, 0 failing of 1,291,859**; `pipe_clk`
+0.118 (the design's WNS, inside the PCIe IP); `sysref_clk` +0.286; `clk_out1` +5.112; `pcie_refclk` +6.820.
Zero `[Route 35-162]` warnings; Phase 8 opened and closed with nothing between; global iterations ended at
0 / 0 / 0 overlaps (three iterations against draw 3's four, which ended 530 / 0 / 0 / 0).

The worst 75 MHz path is now `gen_vstub[2].gsr.u_swg/a_vq_reg -> u_swg DSP B input` in B, 31 levels,
+0.373. Nothing in `u_kv` appears among the reported worst paths: the pre-registered prediction that the
`r_beat / ph_ch -> mbank CE` cone would no longer be the worst path HIT. Closure itself was deliberately not
predicted. **This is the largest 75 MHz margin of any card build** (12b +0.046, 14's rescue +0.056, 15 draw 3
-0.254, 15 draw 3b -0.028).

## Area, placed, against build 15 draw 3

| metric | build 15 draw 3 | **build 17** | delta |
|---|---|---|---|
| CLB LUTs | 362,286 | **361,488** | -798 |
| CLB Registers | 310,573 | 310,004 | -569 |
| CARRY8 | 12,539 | **12,232** | **-307** (the divider's chains) |
| F7 Muxes | 28,176 | 28,609 | +433 |
| F8 Muxes | 5,966 | 6,046 | +80 |
| CLB tiles | 54,537 | 54,746 (99.61%) | +209 |
| Block RAM tiles | 569 | 569 | 0 |
| DSPs | 2,087 | 2,087 | 0 |

The OOC pair had the block itself lose 4,042 LUT; composed, the top lost 798. The parts do not sum across
synthesis contexts (pre-registered), and the CARRY8 delta is the structural signature that survives.
Congestion: the router's table read max Global % Tiles 9.64 SOUTH (draw 3, routed: 9.15; the failed draws
11.73 to 11.92); the trigger remains withdrawn and this is a data point, not a prediction.

## Memory

`MemoryHigh=24G MemoryMax=26G` read back from the cgroup; swap peaked 26 GB in synthesis (guard at 30 GB),
10 to 11 GB through placement and routing; Vivado 12.4 GB resident at 148% CPU (`maxThreads = 2`).

## Files

`bd_wrapper.bit` (25,744,310 bytes, `BITSTREAM.sha256` e339881c...), loadable copy
`hw/fk33/bit/fk33_card_build17_kvctr_75mhz_2026-09-22.bit`; route status; gzipped routed timing summary; placed
utilization; gzipped build log; `sentinels.txt`; `COMPOSITION.md`; `launch.sh` and `chain.sh` (the exact
launch and the unused rescue chain). DCPs (synth, placed, routed) and the bitstream at
`/mnt/storage/fk33_builds/KEEP_build17_dcp/` with `SHA256SUMS`.

## On silicon

Appended below after the load (main session): caps 0x7D, weights verified, three control runs against 24.578 s,
and `run_prompt --dump-xout` on token 248045 against `tok0.r9bs` `R_X-31` (exponent AND all 4,096 mantissas).

**2026-09-22 23:37 to 23:43, MEASURED: BUILD 17 COMPUTES WRONG VALUES ON SILICON.** Reload clean (VCCINT 0.715 V,
die 42.0 C, seam `LLM2` v2, cap flags 0x7D with `XEXP_OUT yes`, no fault), image verified 251 of 251. The control
(`fk33_chat.sh "What is a DC-DC converter?" 64`, three runs):

| build | prefill line | run_chunk | output |
|---|---|---|---|
| 12b / 14 | `20 ids, pos 20, first argmax 32, exp 15` | 24.578 / 24.579 s | the DC-DC answer |
| **17** | `20 ids, pos 20, first argmax 0, exp 44` (x3, traces identical) | **24.521 s** x3 | 64 x `!` (token 0) |

Token 0 (`run_prompt --prompt 248045 --max-new 1 --dump-xout`): build 17 `argmax 0, exp 43`, `XEXP_OUT 14`, window
mantissas all zero; the reference is argmax 846, `R_X-31` exp 8 (build 14 reproduces the argmax and the exponent;
its window is zero by construction). **Host-side control, same host, same image, same cached program: build 14
reloaded at 23:41 gives argmax 32 / exp 15 / 24.579 s and token 0 argmax 846 / exp 8** (`silicon_ctl14/`). So the
defect is in build 17's image. It carries exactly two RTL changes over build 14: the R_X shadow in `region_mem`
(build 15's change, never on silicon before) and the KV fetcher counters (f14121d). The 0.23% throughput change
(24.521 against 24.578, 57x the silicon noise floor) is a real difference in the token's cycle count and is
itself evidence that the attention path does something different, not faster.

**The card holds build 14 again.** Build 17's bitstream is NOT to be loaded except as a diagnostic.
Attribution in progress: draw 3b's checkpoint (the shadow WITHOUT the counters, WNS -0.028) written to a
diagnostic bitstream, and `tb_llama_top_real` (real weights against the reference stream) on the counters RTL.

**ATTRIBUTED 23:48 (MEASURED): THE R_X SHADOW, NOT THE KV COUNTERS.** Draw 3b's checkpoint (build 15: the shadow
WITHOUT the counters, WNS -0.028) was written to a DIAGNOSTIC bitstream and loaded (`silicon_diag3b/`): control
`first argmax 0, exp 44`, run_chunk **24.521 s**, token 0 `argmax 0, exp 43`, XEXP_OUT 14, window zero: the same
numbers as build 17 to the digit. The only RTL commit between build 14's tree (330b70f) and build 15's (f0fcb37) is
the shadow itself (`rtl/region_mem.vhd` + the `SHADOW_REGION => R_X` generic in the card top). The KV counters
(f14121d) are exonerated on silicon by this control; in simulation they were already bit-exact on the fetcher's
oracle bench and left `tb_llama_top_kvport`'s pinned landmarks unchanged. The card holds build 14 again (23:49,
weights verified 251 of 251).

Mechanism: OPEN. In GHDL the card top with the shadow reproduces the reference residual through the seam
(`tb_fk33_seam` P1, and P1 FAILED on the pre-shadow RTL with `R_X(0) reference -17280, seam 0`), so the RTL is
right and the difference is synthesis. Synthesis made the shadow a 512 x 128 block RAM (`READ_FIRST`, +2 tiles,
as predicted) and still recognised region 0's `bank_reg` as a "true dual port RAM template" in both builds. A
netlist census of region 0 in the build 17 and build 14 routed checkpoints is running (`census/`). The
symptom shape (an all-zero residual with a garbage exponent, argmax 0, a 0.23% SHORTER token) says region 0
never receives its writes on silicon, the host's X push included; what synthesis did to that write path is the
question.
