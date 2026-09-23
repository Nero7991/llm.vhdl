# The R_X shadow zeroes the residual on silicon (builds 15 and 17), while every bench passes

## The question

2026-09-22 23:37. Build 17 (build 15's tree + the KV fetcher counters, `FK33_CARD=1 CB_STYLE=distributed 75 MHz`,
routed WNS +0.373 on the core clock, 0 routing errors) loaded on the FK33 (VCCINT 0.715 V, seam `LLM2` v2, cap
flags 0x7D, no fault, image verified 251 of 251) gives, on the 12b control prompt (20 ids, `--max-new 64`):
`prefill 20 ids, pos 20, first argmax 0, exp 44`, 64 tokens of `!` (id 0), `run_chunk 24.521 s` three times
identical. Builds 12b and 14 give `first argmax 32, exp 15`, the DC-DC answer, 24.578 s. Token 0 (`--prompt
248045 --max-new 1 --dump-xout`): `argmax 0, exp 43`, `XEXP_OUT 14`, all 4,096 window mantissas zero; the
reference (`tok0.r9bs` `R_X-31`) is argmax 846, exp 8, and build 14 reproduces the argmax and the exponent.
Which of build 17's two RTL changes over build 14 is it, and why does no bench see it?

## The answer (attribution MEASURED, mechanism OPEN)

**The R_X shadow in `rtl/region_mem.vhd` (commit f0fcb37, build 15), not the KV counters (f14121d).** The
attribution is a one-variable silicon control: build 15 draw 3b's checkpoint (shadow, no counters, WNS -0.028)
written to a diagnostic bitstream reproduces build 17's numbers to the digit (argmax 0 / exp 44 / 24.521 s /
token 0 argmax 0 / exp 43 / XEXP_OUT 14 / window zero), and the host-side control (build 14 reloaded on the same
host, image and cached program) reproduces build 14's (argmax 32 / exp 15 / 24.579 s / token 0 argmax 846 /
exp 8). `git log 330b70f..f0fcb37 -- rtl hw/fk33/rtl tools/gen_cardtop.py` lists exactly one commit.

The mechanism is not yet known. The symptom shape is an ALL-ZERO residual: zero window mantissas under a
nonsense exponent, argmax 0 (the first index of an all-equal logit row), and a token 0.23% SHORTER than
build 14's (57x the 0.004% silicon floor: the engine did less work, which a zero-valued stream can cause and a
wrong-valued one cannot). A residual that is zero after 32 layers starting from a host-pushed embedding means
region 0 is not taking its writes, the host's X push included. What synthesis did to that path is what the
running netlist census (build 17 against build 14 routed checkpoints, `build17/census/`) is for.

## The procedure

1. Build 17 on silicon: reload, seam readback, image verify, three control runs, token 0 with `--dump-xout`,
   compare against `tok0.r9bs` with `scratch/xout_vs_ref.py` (which FAILS on build 14's all-zero window, so it
   has teeth). WRONG, deterministic (three identical traces).
2. Host-side control: build 14 reloaded, same host, same image, same cached program, same steps. RIGHT. So the
   image is the defect.
3. RTL delta enumeration from git, not from memory: 330b70f..f0fcb37 has one RTL commit (the shadow); f0fcb37..f14121d
   has one (the counters). Two suspects.
4. One-variable silicon control on the OTHER suspect: draw 3b's checkpoint carries the shadow without the counters;
   `write_bitstream` from it (28 ps short at the slow corner, stated, not hidden), loaded, same steps. WRONG,
   identical to build 17. The counters are exonerated; the shadow is the defect.
5. Simulation evidence weighed AFTER the attribution, not instead of it: `tb_fk33_seam` P1 (card top, card
   configuration, shadow present) reproduces the reference residual through the seam; the same row FAILED on the
   pre-shadow RTL (`R_X(0) reference -17280, seam 0`). `tb_llama_top_real` PASS is irrelevant to both suspects
   (it runs with `C_KV_AXI` off and `llama_top`, which has no shadow). `tb_llama_top_kvport` (real fetcher, pinned
   landmarks) PASS covers the counters only.
6. Synthesis-side census (running): what region 0's `bank` and `shadow` became, and what drives the shadow BRAM's
   write-enable and address pins, in build 17's and build 14's routed netlists.

## The evidence

```
build 17   control: prefill 20 ids, pos 20, first argmax 0, exp 44 | run_chunk 24.521 / 24.520 / 24.521 s
           token 0: prefill 1 ids, pos 1, first argmax 0, exp 43 | xout exp 14, 4096 mantissas, nonzero 0
build 14   control: prefill 20 ids, pos 20, first argmax 32, exp 15 | run_chunk 24.579 s   (same host, 23:42)
           token 0: prefill 1 ids, pos 1, first argmax 846, exp 15 | xout exp 8 (window zero by construction)
draw 3b    control: prefill 20 ids, pos 20, first argmax 0, exp 44 | run_chunk 24.521 s   (shadow, no counters, 23:47)
           token 0: prefill 1 ids, pos 1, first argmax 0, exp 43 | xout exp 14, 4096 mantissas, nonzero 0
```

Synthesis, build 15 and build 17 (`Report RAM Utilization`, the naming table):

```
|region_mem | g_region[0].g_shadow.shadow_reg | 512 x 128(READ_FIRST) | W | | 512 x 128(WRITE_FIRST) | | R | Port A and B | 0 | 2 |
INFO: [Synth 8-3971] The signal "region_mem/g_region[0].bank_reg" was recognized as a true dual port RAM template.   (builds 14, 15, 17 alike)
```

Placed, build 14 rescue against build 15 draw 3 (one RTL change): LUT 362,014 -> 362,286, FF 310,560 -> 310,573,
LUT as Memory 65,904 -> 65,904, BRAM 567 -> 569.

## Measured and REJECTED -- do not retry

- **Blaming the KV counters because they were the newest change.** They were the newest change and the first
  suspect; the diagnostic image without them fails identically. The order of suspicion was the order of recency,
  not of evidence.
- **Reading GHDL's pass as evidence about silicon.** Every bench that could see the shadow passed and the shadow
  is the defect; the RTL is right and the netlist is not the RTL. A bench cannot see what synthesis did.
- **Using `tb_llama_top_real` as an oracle for either suspect.** Its own header says it does not cover the KV
  cache, and its top has no shadow.

## Measurement traps hit

- A 0.23% throughput change was almost read as an improvement from the counters. It is present without the
  counters, and it is the engine doing less work on zeros.
- The seam's window read zeros on build 14 (`HOST_WINDOW=false` ties it) and on build 17 (the shadow); the same
  reading, two different mechanisms. The XEXP_OUT register (8 on build 14 against 14 here) was the tell.

## Open, not yet answered

- The synthesis mechanism: what happened to region 0's write path or storage when the shadow was added.
- Whether the defect is in the shadow's BRAM inference interacting with `bank` (two RAMs written from one port),
  or something in `region_mem` that GHDL and Vivado read differently.
- Corrections are appended below when the census lands.

## CORRECTION / MECHANISM, 23:57 (MEASURED: netlist census of region 0, routed checkpoints of builds 17 and 14)

**Region 0's storage has its write enables tied to ground in build 17.** `census_region0_routed.txt`
(`hw/fk33/results/card_build17_2026-09-22/`, produced by `census.tcl` on the two routed DCPs):

```
build 14  *u_regmem/g_region[0].bank_reg*   n=164  RAMB36E2 4  LUT4 124 LUT5 20 LUT6 11 LUT2 3 LUT3 2   (the write decode lives here)
          bank_reg_1_0  WEBWE[7..0] = bank_reg_1_0_i_77_n_0 / _i_78 / _i_79 / _i_80   (real write enables, two bits each)
build 17  *u_regmem/g_region[0].bank_reg*   n=13   RAMB36E2 4  GND 1  LUT6 2 LUT3 2 LUT5 2 LUT4 1 LUT2 1
          bank_reg_1_0  WEBWE[7..0] = <const0>  (ALL EIGHT), WEA[3..0] = <const0>, ENARDEN = p_124_out
          *u_regmem/g_region[0].g_shadow*     n=159  RAMB36E2 2  FDRE 4  LUT4 123 LUT5 18 LUT6 9 LUT2 3   (the write decode moved HERE)
          shadow_reg_0/1  WEBWE[7..0] = shadow_reg_0_i_76.._79 (real), ENBWREN = g_region[0].wr_en,
                          ADDRBWRADDR = g_region[0].wr_addr[8..0], ADDRARDADDR = hr_addr[11..3] from fk33_seam xr_addr_reg
```

So the shadow BRAM is written and addressed exactly as designed, and the engine's own storage of R_X (the four
`bank_reg` BRAMs that `el_word_r` and `g_word_r` read from) can never be written: the write-enable decode
that build 14 has on `bank_reg` (155 LUTs) exists in build 17 only on `shadow_reg`, and `bank_reg`'s enables
are constants. Every read of R_X returns the BRAM's initial zeros, the X push included, which is the all-zero
residual measured on silicon, the garbage exponent, argmax 0 and the 0.23% shorter token.

**The tool merged the write decode of two RAMs fed by one write port and kept it on the wrong one.** Which
stage (synth_design's RAM inference against opt_design / power_opt) is settled by the same census on the
synthesis checkpoint, appended below. Whatever the stage, the RTL construct "a second array written from the
same `wr_*` signals as the first, both `ram_style = block`" is what invited it, and no simulation can see a
netlist transformation.

Trap for the record: `tb_fk33_seam` P1 reads R_X through the seam (the shadow) AND through the reference
`llama_top`, and both were right in GHDL because in GHDL both arrays are written. On silicon the shadow was also
written, so a window-only test on the shadow would have PASSED while the engine read zeros; the discriminator
was the engine's own output (argmax, XEXP_OUT), never the window.

## APPENDED 23:59: the stage is SYNTHESIS (MEASURED, `census_synth.tcl` on `KEEP_build17_dcp/bd_wrapper_synth.dcp`)

```
synth17  bank_reg_1_0 / _1_1 / _2_0 / _2_1 (RAMB36E2 x4):  ENBWREN=<const1>  WEA[3..0]=<const0>  WEBWE[7..0]=<const0>
synth17  g_shadow.shadow_reg_0 / _1 (RAMB36E2 x2):        ENBWREN=g_region[0].wr_en  WEBWE[7..0]=shadow_reg_*_i_76.._79 (real)
```

Straight out of `synth_design`, before opt_design or power optimisation, the engine's four R_X BRAMs have no
write path and the two shadow BRAMs have the only one. `report_ram_utilization` listed only the shadow for
region 0 in builds 15 and 17 and the log said `bank_reg` "was recognized as a true dual port RAM template" in
every build; neither line says whether the template's write port survived. **Two arrays written from one
`wr_*` port, both `ram_style = "block"`, in the same generate scope: Vivado 2023.2 synthesis kept the write
logic on one and tied the other's enables to ground.** Whether that is a defect or a consequence of some
inference rule is not settled here and does not need to be: the construct is withdrawn.

## Measured and REJECTED -- do not retry (appended)

- **A shadow copy of a region written from the region's own write signals.** This construct. Any fix that keeps
  two RTL arrays with one writer re-invites the same inference, `DONT_TOUCH` or not, and the only proof would be
  a netlist census on every build.

## What the fix must do (the replacement, to be measured)

Serve the seam's window from the engine's EXISTING element read port of `region_mem` (`el_ren/el_reg/el_addr ->
el_rdata`, one registered cycle) whenever that port is idle, in `llama_top`'s `elmux`, with engine reads keeping
priority and the window data gated to zero on any cycle the engine held the port. No new array, no new RAM
port, no new seam pin; the host reads R_X after `tok_done`, when the port is idle by construction. Then a
build-flow refusal that reads region 0's bank write-enable nets after synthesis and errors if they are constant,
so that this class cannot reach place-and-route again.

## APPENDED 2026-09-23 00:10: the replacement, its teeth, and the flow refusal

**Replacement (RTL):** `rtl/region_mem.vhd` reverted to its pre-shadow text (f0fcb37^) with a header note;
`rtl/llama_top.vhd`'s `elmux` hands the element read port to `(hr_reg, hr_addr)` on every cycle no unit
requests it (a unit's request always wins) and a one-bit `hr_win_q` marks the cycles on which `el_rdata`
carries the host's word; `tools/gen_cardtop.py` drops the `SHADOW_REGION` generic and emits the card's window
as `hr_data <= el_rdata when hr_win_q = '1' else 0` (region_mem's own window stays zero when `HOST_WINDOW`
is false). One registered cycle of latency, inside `fk33_seam`'s `rd_wait`. No second array, no new RAM port,
no new seam pin. `GEN_CARDTOP_CHECK: OK`.

**Teeth, MEASURED:** `tb_fk33_seam` (the card top in the card configuration, `HOST_WINDOW => false`) PASS
with the new window and **FAIL** with mutant `M_WINCUT` (`hr_win_q` held at '0' in the generated top: P1 at
`tb_fk33_seam.vhd:1377`); `tb_region_mem`, `tb_fk33_cardtop_ident`, `tb_fk33_cardtop_adesc`, `sim:cardtop`
PASS. The remaining `llama_top` rows are appended below.

**Flow refusal:** `hw/fk33/gen_pcieep.py` emits, after `wait_on_run synth_1`, an `open_run synth_1` census of
region 0's block RAMs: `FK33_REGION0_WE bram <name> live_write_pins=<n>` per BRAM, `FK33_REGION0_WE OK` or
`error FK33_REGION0_WE FAIL` if any BRAM has every `WEBWE`/`WEA` pin on a `GROUND`/`POWER` net, and
`FK33_REGION0_WE NOT CHECKED` plus an error if the census itself fails (an unchecked netlist is not
implemented). Regenerated `hw/fk33/build_fk33_pcieep.tcl` with the stamp's environment: 44 insertions, 0
deletions. Its validation on build 17's synthesis checkpoint (expected FAIL) and build 14's routed netlist
(expected OK) is appended below when it lands.

## APPENDED 00:14: the refusal validated on both checkpoints (MEASURED, `r0check2.tcl`, `r0check_validation.txt`)

```
synth17   bank_reg_1_0 / 1_1 / 2_0 / 2_1  live_write_pins=0 0 0 0
          R0CHECK synth17 RESULT: FK33_REGION0_WE FAIL: 4 of 4 region-0 block RAMs have every write enable on a constant net
routed14  bank_reg_1_0 / 1_1 / 2_0 / 2_1  live_write_pins=8 8 8 8
          R0CHECK routed14 RESULT: FK33_REGION0_WE OK: 4 region-0 block RAMs, every one with live write enables
```

The first draft of the check judged synth17 correctly and then crashed Vivado (`close_design` followed by
`error` inside the `catch`: "Called UpdateStringOfFsPath with invalid object, Abnormal program termination
(6)"), which in the build flow would have read as a mysterious synthesis-stage crash rather than the refusal
it was. The census now only records inside the catch; the design is closed and the verdict pronounced
afterwards. This is the same shape as every other "a check that fails for the wrong reason" entry: a refusal
that takes the tool down with it is not a refusal, it is a crash with a good excuse.

## CLOSED 2026-09-23 04:36: build 18 on silicon

Build 18 (the replacement window + the counters, levers off) routed on its first default draw (core clock
+0.225, 0 failing, 0 routing errors), passed `FK33_REGION0_WE` with 8 live write pins on each of the four
region-0 BRAMs, and on the card reproduces build 14 exactly: control `argmax 32, exp 15`, 24.578 s three
times, token 0 `argmax 846`, `XEXP_OUT 8`. Window 3 reads 4,093 non-zero mantissas under exponent 8,
correlation 0.9965 with the llama.cpp anchor's `R_X-31`. The question this document opened is answered
in full: attribution (the shadow), mechanism (synthesis grounded the bank's write enables), fix (no second
array; the window on the element read port), and the refusal that keeps the class out. Open, carried to
Task 11: whether the window is bit-identical to the card's internal R_X, which only the pair-versus-single
oracle can say.
