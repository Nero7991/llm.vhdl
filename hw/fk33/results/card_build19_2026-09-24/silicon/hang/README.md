# Build 19: an intermittent attention hang at position 32 (OPEN; narrowed to the build-19 bitstream)

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

## The discriminator: build 18 does not hang (MEASURED 2026-09-24 07:42-08:00)
Both cards JTAG-reloaded with `fk33_card_build18_elwin_75mhz_2026-09-23.bit`, then the same
`fk33_ctxtest.sh pair ... 256` with REPEATS=4, pad norms on in every arm (`pad.used`
`padnorms-v1 pad=1`), the same D program:

| bitstream | image | runs (4 prefill + 4 decode, 256 positions each) |
|---|---|---|
| build 19 | `-nh` | input r1 pass, input r2 HANG @32; after reload input r1 HANG @32 |
| build 18 | original (no norm rows) | **8 of 8 pass**, ids identical across repeats |
| build 18 | `-nh` (the build 19 image) | **8 of 8 pass**, ids identical, and equal to the row above |

So the image (norm rows, GDN constants moved down 532,480 B; the KV base is the SAME address in
both) is not the cause, and the hang arrived with the build 19 BITSTREAM. At 2 of 3 on build 19
against 0 of 16 on build 18, chance alone is not a credible explanation (DERIVED: at a 2/3 rate,
16 passes has probability (1/3)^16).

Between the two trees (`c6af925` -> `8af98b8`) the RTL change is plan Task 2 only (`llama_top`,
`seq_vec_issue`, `fk33_card`, regenerated tops); no hunk names a C signal. What Task 2 DOES change
on C's path, found by reading, NOT measured: `hw/fk33/gen_pcieep.py` drives `bc_port_grant`'s
`b_req` from `bst_arvalid OR bst_awvalid`, and B and C share the grant's two HBM ports (m0/m1).
On build 18 only the GDN state store raised `bst_arvalid`; on build 19 every VEC_NORM's gain fetch
does too, so B now requests the ports C uses in every block, attention blocks included. The grant
switches owners only when the owner is idle and `rd_out`/`wr_out` are zero, so any B-side burst
left owed would starve C for ever, which is exactly a C_JOB watchdog. What this does NOT explain:
the last norm before each hung C_JOB is three long A_JOBs earlier (step 48 before step 52), and a
permanently owed burst would hang every token, not only position 32. It is a lead, not a cause.
The grant's `owner_is_c`, `draining`, `err_switch_busy` and `err_len_ovf` outputs are
UNCONNECTED in the card build, so the seam cannot say whether C was waiting on the grant; wiring
them to a seam register is the cheapest instrument for the next card build.

**The 27B build 27B-1 carries NORM_HBM too**, so it should be expected to have the same hang.

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

## Timing context, recorded 2026-09-24 (data, not a cause)
Both builds are signed off at Vivado's 0.85 V speed data (no
`set_operating_conditions -voltage` in the flow) and run at 0.717 V. The 75 MHz
core clock (`clk_out3`) closed at **+0.225 ns on build 18** and **+0.013 ns on
build 19** (`/mnt/storage/fk33_builds/build19/reroute/timing_summary_rr.rpt`,
the shipped bitstream, sha 9366b396). Build 19's ten worst core paths are all
in A's engine (`eng/dut/core`: `xq_rd -> tr_reg` DSP inputs and `cb_data ->
cbw_d`), not in C, so the report does not point at the hang. A 0.72 V
re-analysis of C's paths on the routed DCP would settle whether C is marginal
at the real voltage; it has not been run.

## The 0.72 V re-analysis cannot be run on the routed DCPs (MEASURED 2026-09-24 10:20)
`vt72.tcl` opened the shipped build-18 routed DCP, reported per-subsystem
slack at 0.85 V, then `set_operating_conditions -voltage {VCCINT 0.72}`.
Vivado 2023.2 then threw `[Timing 38-246] Caught exception
'vector::_M_range_check ...' while reading timing library` and `Net delay
calculation threw an exception` on unrelated AXI GPIO drivers, plus `[Constraints
18-11797]` BRAM site-type errors, and SEGFAULTED (exit 139). A second attempt on
build 19 with the voltage set straight after `open_checkpoint`, before any 0.85 V
timing, crashed the same way. Not memory: 24G cap, box never below 1.8 GB.
**Do not retry this form.** The 2026-08-24 derate study only worked on a
post-synthesis OOC netlist. What remains: an OOC `attn_block` implemented at
0.72 V from the start (C's own paths, but not the card's placement), or a card
build signed off at 0.72 V from the start.

Per-subsystem worst setup slack of build 18 at 0.85 V, for reference
(`vt72_b18_085_slacks.txt`): core clock 0.225 (in A), C 0.853, C's KV mover
1.966, B 1.942, B's state store 3.028, D 4.714, the B/C port grant 9.036 ns.

## Build 19 lost 1.7 ns of margin in C's KV mover (MEASURED 2026-09-24 10:40, 0.85 V analysis)

| subsystem (sequential endpoints) | build 18 worst setup | build 19 worst setup |
|---|---|---|
| core clock overall (A's `eng/dut/core`) | 0.225 | 0.013 |
| C, `gcr.u_attn/*` | 0.853 | **0.311**, from `gcr.gkvaxi.u_kv/wb_full_reg` to `u_attn/kbyp_reg[1021]/CE` |
| C's KV mover, `gcr.gkvaxi.u_kv/*` | 1.966 | **0.254**, `GEN_RD[1].w_mm_reg -> GEN_RD[1].mbank_reg/CE` |
| B, `gb_real.u_gdn/*` | 1.942 | 1.943 |
| B's state store | 3.028 | 5.220 |
| D, `u_fetch` | 4.714 | 6.575 |
| B/C port grant | 9.036 | 8.822 |

The KV mover is the logic that starts reading a new KV block, and every
captured hang is at position 32, the first read of block 1. **This is a LEAD,
not a cause:** A's core path has even less slack (0.013 ns) on the same card
and does not fail, and both builds are signed off at 0.85 V while running at
0.717 V, where every one of these paths has less real margin than shown. The
discriminating test is on silicon: repeat `fk33_ctxtest.sh pair ... 256` on
build 19 with the die faster (slightly higher VCCINT, which CLAUDE.md fixes at
wiper 68, so it is Oren's call) or with the path fixed and rebuilt.

## The VCCINT-raise test (Oren approved 2026-09-24): STOPPED before any raise
Both cards reloaded with build 19 at 10:5x (card 1 = xdma0, card 2 = xdma1), the
`-nh` images loaded and verified 126/126 and 127/127.

Measurement traps hit, in order:
1. **`fk33ctl.py vccint` is NOT a read. It is the MMIO VCCINT STEPPER.** Run as
   a "check" with `| head -2`, it printed START and SAFETY PROBE, wrote wiper
   68 -> 69 (the safe direction, about -3 mV) and died on SIGPIPE at its next
   print. Both cards were left at wiper 69, 0.713-0.716 V, in spec. The
   read-only commands are `fk33ctl.py sysmon` (rail and die temperature) and a
   bare `I2C(Mmio()).pot_read(POT_ADDR)` for the wiper.
2. **The MMIO bit-banged I2C is intermittently unreliable.** One pot READ
   returned -1 (NACK) then 6 of 6 good reads; one pot WRITE (69 -> 68) was not
   acknowledged and did not land (read back 69 x5). A write that is garbled on
   the wire can land as any wiper value, and a low wiper is a HIGH rail, so the
   readback guard only detects it after the rail moved.
3. **`fk33ctl.py`'s `pot_write` hard-clamps at wiper 68** ("no future caller can
   route around it"), so a raise past 0.717 V through fk33ctl requires overriding
   that interlock deliberately. Stopped for Oren's decision rather than doing so.

## RESOLVED AT THE VOLTAGE LEVEL 2026-09-24 11:00
Build 19 at VCCINT 0.779/0.780 V (wiper 25 on both cards): 8 of 8 ctxtest runs pass, ids equal to build 18. See `docs/debugging/2026-09-24_build19-attention-hang-is-voltage-sensitive.md`.
