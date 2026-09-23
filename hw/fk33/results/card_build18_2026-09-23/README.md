# Build 18: the window rides the element read port, the KV counters stay. CLOSED at 75 MHz, CORRECT on silicon, window alive.

Worktree `/mnt/storage/fk33_builds/wt18` at `c6af925` (the shadow withdrawn; `llama_top`'s `elmux` hands the element
read port to the host window on idle cycles; `attn_kv_axi` with per-beat counters) + `build12_levers_off.patch`.
`FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75`, and **`FK33_SYNTH_THREADS=1`** (the one launch
parameter that differs from build 17: the first attempt at the card default of 2 was killed by the swap guard at
30G ten minutes into synthesis, from a 7-8G stale-swap baseline; at one thread synthesis peaked at 29G). Default
recipe, first draw. Composition from the log: `CB_STYLE distributed` x4, levers `bound to: 1` count 0,
`HOST_WINDOW 0`, `C_KV_BLOCK 32`, no `SHADOW_REGION` anywhere. `COMPOSITION.md` holds the pre-registered
predictions, scored in place.

## The refusal, on its first live netlist

```
FK33_REGION0_WE bram g_region[0].bank_reg_1_0 live_write_pins=8   (and _1_1, _2_0, _2_1: 8, 8, 8)
FK33_REGION0_WE OK: 4 region-0 block RAMs, every one with live write enables
```

Build 17's netlist had 0 / 0 / 0 / 0 at the same pins. The engine's R_X has its write port back, proven on the
nets before place-and-route. Prediction HIT.

## The verdict, from the authority

```
# of routable nets..................... :      677082 :    fully routed 677082    routing errors 0
    WNS      TNS  Failing  Total      WHS    THS  Failing
  0.096    0.000        0  1527886  0.009  0.000        0        (75 MHz core clock clk_out3: +0.225, 0 of 1,292,476)
```

Phase 8 clean, zero `[Route 35-162]`, iterations 0 / 1 / 1 / 0 overlaps, router congestion 10.47% SOUTH
(build 17: 9.64; the failed draws 11.73 to 11.92). Bitstream 25,667,150 bytes, `BITSTREAM.sha256`
8825f8cb..., loadable copy `hw/fk33/bit/fk33_card_build18_elwin_75mhz_2026-09-23.bit`. Placed: LUT 358,846
(build 17: 361,488), FF 310,214, CARRY8 12,252, CLB 54,726 (99.57%), **BRAM 567** (the shadow's two tiles gone,
predicted), DSP 2,087.

## On silicon (2026-09-23 04:36, `silicon/`), MEASURED

Reload with no VCCINT change (0.7165 V, die 40.5 C), seam `LLM2` v2, cap flags 0x7D, `XEXP_OUT yes`, no fault;
image verified 251 of 251.

| check | build 18 | build 14 (control) | reference |
|---|---|---|---|
| control prefill line, 3 runs | `first argmax 32, exp 15` x3 | same | 12b's trace |
| control `run_chunk`, 3 runs | **24.578 / 24.578 / 24.578 s** | 24.578 / 24.579 | within the 0.004% floor: the counters change no cycle and the window adds none |
| token 0 (`--prompt 248045 --max-new 1`) | `argmax 846, exp 15`, `XEXP_OUT 8` | same | `tok0.r9bs` argmax 846, `R_X-31` exp 8 |
| window 3 (`--dump-xout`) | **4,093 of 4,096 mantissas non-zero**, exp 8 | 4,096 zeros (tied) | see below |

**The window against the reference stream.** `tok0.r9bs` is the llama.cpp float anchor (tools/ref9b rung 1),
quantised to BFP16 per seam; the card computes in int4/BFP16, so bit-for-bit equality is the wrong instrument
here (docs/debugging/2026-09-20, section 6, says so for exactly this cross-format case). The cross-format
metrics: **exponent equal (8), correlation 0.9965, relative RMS deviation 0.084, sign agreement 96.95%**, first
six mantissas 62/734/1010/-60/87/547 against 44/753/999/-100/69/536. The `xout_vs_ref.py` comparator now prints
both verdicts and names them: `exact: FAIL   anchor: PASS`. What this establishes: the window returns R_X's real
mantissas under R_X's real exponent. What it does NOT establish: that the window is bit-identical to the card's
internal R_X. No RTL-simulation capture of a full 9B token exists to compare against (the 2026-09-20
`sim_tok0.r9bs` was the host's simulated transport and carried logits only); the two-card oracle (Task 11: the
pair against the single card, same prompt, same tokens) is the test that settles it, and it needs the second
card in the slot.

**The card holds build 18.** Rollback: build 14 (`hw/fk33/results/card_build14_2026-09-22/bd_wrapper.bit`).

## What this build establishes

- The hop's mantissa path exists on silicon for the first time (window 3 carries R_X), at zero throughput cost.
- The KV fetcher counters (f14121d) run on silicon at bit-identical throughput and correct output, so the
  divide-by-17 fix stands and build 15's -0.254 / 3b's -0.028 timing miss is closed at the source.
- The class "a second array written from one write port" is unbuildable: `FK33_REGION0_WE` refuses it at synthesis.

## Files

`bd_wrapper.bit`, `BITSTREAM.sha256`, route status, gzipped routed timing summary, placed utilization, gzipped
build log, `sentinels.txt`, `region0_we.txt`, `COMPOSITION.md`, `launch.sh`, `chain.sh` (unused), `silicon/`
(reload, seam, sysmon, weights, three control runs, token 0 and its window dump, `steps.sh`, `xout_vs_ref.py`).
DCPs and the bitstream at `/mnt/storage/fk33_builds/KEEP_build18_dcp/` with `SHA256SUMS`.
