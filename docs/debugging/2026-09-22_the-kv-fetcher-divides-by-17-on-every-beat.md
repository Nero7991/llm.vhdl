# The KV fetcher divides by 17 on every beat, and that is the routed card's worst path

## The question

2026-09-22, build 15 draw 3 (build 14 + the R_X shadow BRAM; worktree f0fcb37 with the 12b lever patch;
`FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75`; the DEFAULT card recipe
`Performance_RefinePlacement`, placer `ExtraPostPlacementOpt`, router and phys_opt `Default`, re-implemented
from build 15's synthesis checkpoint as `card15-reimpl3`, launched 14:08). Draws 1 and 2 of the same checkpoint
had failed to route (8,932 and 12,438 nets in resource conflict). Draw 3 ROUTED: `report_route_status`
681,010 of 681,010 nets fully routed, 0 routing errors, Phase 8 opened and closed with nothing between. But
the routed timing is

```
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)
     -0.254      -57.509                    597              1529003        0.009        0.000
```

at 75 MHz (13.333 ns). Which path, and why?

## The answer

Every one of the ten worst violated paths is `u_attn/gcr.gkvaxi.u_kv/GEN_RD[1].r_beat_reg[1]/C` to a
`GEN_RD[1].mbank_reg[*][*][*]/CE` in `rtl/attn_kv_axi.vhd`: 33 logic levels (14 CARRY8, 19 LUTs), data path
12.945 ns of which 9.070 ns is route. The RTL computes, combinationally from the 32-bit beat counter on
EVERY arriving beat,

```vhdl
kk   := r_beat*BEAT_CH + c - ph_ch;
rr   := kk / CPR;        -- CPR = REC_B/CH_B = 17
mm   := kk mod CPR;
slot := rr mod RBUF;     -- RBUF = 4 on the card (3 on the dw128 harness arm)
```

A 32-bit division by 17 is a restoring divider: a chain of subtract-compare stages, one CARRY8 group per
stage, which is exactly the alternating LUT / CARRY8 signature the timing report shows, and its result
fans out to the write enable of every mantissa-bank register (RBUF x NBLK x 128 bits per bank). The router's
own Phase 12 physical synthesis worked 40 of its 41 improved nets in this bank and took WNS from -0.610 to
-0.254; it could not remove a divider.

The fix is to keep `(rr, mm, slot)` for chunk 0 of the next beat as three registered counters advanced by
`BEAT_CH` per beat with a single wrap at `CPR` (`BEAT_CH < CPR` is already asserted), and per chunk do at most
one more wrap. Invariant: `w_rr*CPR + w_mm = r_beat*BEAT_CH - ph_ch`, `w_slot = w_rr mod RBUF`, with
`w_mm = -ph_ch` at beat 0 so the `kk < 0` chunks of a phase-shifted run are still skipped. No division
remains on the beat path. Committed in `rtl/attn_kv_axi.vhd` (this document's commit).

## The procedure

1. `report_route_status` and the routed `report_timing_summary` of draw 3 (the authority, not the completion
   line): legal route, WNS -0.254, 597 failing endpoints, all in the `clk_out3` (75 MHz) group.
2. The ten violated paths of that group, their sources, destinations and logic levels: all ten are
   `r_beat_reg[1]` to `mbank_reg[..]/CE`, 33 levels. Cells along the worst path: LUT, CARRY8, CARRY8, LUT,
   CARRY8, LUT, LUT, CARRY8, ... fourteen CARRY8 groups.
3. The router's Phase 12 log (`[Physopt 32-952] Improved path group WNS ... Processed net: ...u_kv/GEN_RD[1].mbank_reg...`)
   x40, plus one A streamer net: what the tool could still move was this bank's fanout, not the arithmetic.
4. `rtl/attn_kv_axi.vhd:785-790`: the division, on `r_beat : integer` (unconstrained, so 32 bits).
5. The rewrite, then the bit-exact oracle bench `sim/tb_attn_kv_axi` (C oracle vectors; dw128 and dw256; the
   flush placed after records 3, 6 and 8 so the ARVALID-under-flush axis is non-vacuous at both geometries,
   commit 9f34d00) at KV_BLOCK 32 (the gate row) and 16 (scratch, vectors generated at 16), and mutants.
6. OOC synthesis of `attn_kv_axi` at the card's generics (`sim/ooc_attn_kv_axi_card.tcl`, synthesis only,
   200 MHz target, `report_timing -from *r_beat_reg*`) on the BC-250, counters against the divider: the
   structural depth of the path before place-and-route. Results appended below when they land.

## The evidence

Draw 3, routed, the worst path (`bd_wrapper_timing_summary_routed.rpt`):

```
Slack (VIOLATED) :        -0.254ns  (required time - arrival time)
  Source:                 bd_i/card/inst/u/gcr.gkvaxi.u_kv/GEN_RD[1].r_beat_reg[1]/C
  Destination:            bd_i/card/inst/u/gcr.gkvaxi.u_kv/GEN_RD[1].mbank_reg[1][2][81]/CE
  Path Group:             clk_out3_bd_clk_wiz_0_0
  Requirement:            13.333ns
  Data Path Delay:        12.945ns  (logic 3.875ns (29.934%)  route 9.070ns (70.066%))
  Logic Levels:           33  (CARRY8=14 LUT1=2 LUT2=1 LUT3=5 LUT4=5 LUT5=2 LUT6=4)
  Clock Path Skew:        -0.494ns (DCD - SCD + CPR)
```

All ten reported violated paths of the group:

```
-0.254 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][2][81]/CE
-0.254 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][2][86]/CE
-0.252 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][18][80]/CE
-0.252 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][18][81]/CE
-0.252 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][18][85]/CE
-0.252 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][18][92]/CE
-0.250 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][4][91]/CE
-0.248 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][2][82]/CE
-0.248 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][2][83]/CE
-0.248 33 GEN_RD[1].r_beat_reg[1]/C -> GEN_RD[1].mbank_reg[1][2][91]/CE
```

Router Phase 12 (`reimpl3.stdout`):

```
INFO: [Physopt 32-668] Current Timing Summary | WNS=-0.569 | TNS=-71.738 | WHS=0.009 | THS=0.000 |
WARNING: [Physopt 32-745] ... Post-Route Physical Optimization is most effective when WNS is above -0.5ns
INFO: [Physopt 32-952] Improved path group WNS = -0.517. ... Processed net: bd_i/card/inst/u/gcr.gkvaxi.u_kv/GEN_RD[1].mbank_reg_n_0_[1][13][105].
  (40 such lines naming GEN_RD[1].mbank_reg, 1 naming eng/dut/streamer/gen_w[21].port_p/g_dc.fsm/this_len_reg)
INFO: [Physopt 32-669] Post Physical Optimization Timing Summary | WNS=-0.254 | TNS=-57.509 | WHS=0.009 | THS=0.000 |
```

The bench, counters, MEASURED 18:03 (identical AR counts to the divider version's runs of 15:19):

```
KV=16 dw256 84 records, 1344 headers-with-beat, 21504 mantissas, 69712 image bytes; AR 59/60 AW 4; mismatches 0
      dw128 84 records, 1344 headers-with-beat, 21504 mantissas, 69712 image bytes; AR 101/102 AW 8; mismatches 0   PASS
KV=32 dw256 84 records,  672 headers-with-beat, 21504 mantissas, 69712 image bytes; AR 58/60 AW 4; mismatches 0
      dw128 84 records,  672 headers-with-beat, 21504 mantissas, 69712 image bytes; AR 97/100 AW 8; mismatches 0   PASS
gate row sim:tb_attn_kv_axi PASS (KV_BLOCK 32)
```

Mutants of the new logic, KV_BLOCK 32, both KILLED:

```
M1  chunk wrap `if mm >= CPR` -> `if mm > CPR`     dw256: HEADER MISMATCH req 0 ... oracle=82, run aborted (rc 1)
M2  beat-0 phase `w_mm <= -ph_ch` -> `w_mm <= 0`   dw256: 10,522 mismatches; dw128: 0 (dw128 has ph_ch = 0 always) FAIL
```

M2's dw128 zero is the resolution floor of that arm, not a survival: with one chunk per beat the phase is
always zero and the mutant is the design.

## Measured and REJECTED -- do not retry

- **Reading the ten worst paths from the top of the timing summary.** The summary lists max-delay paths for
  EVERY clock group, passing ones first; the first ten paths in the file are `hbm_reset` to HBM XPM memories
  at +3.854 ns, 1 logic level, in the `clk_out1` group. Filter on `Slack (VIOLATED)` and read the path group.
- **Expecting post-route phys_opt to fix it.** The router's own Phase 12 already ran that class of
  optimisation on exactly these nets and recovered 0.356 ns of the 0.610 by moving fanout; the remaining
  3.875 ns of logic is the divider and does not move. Draw 3b (`phys_opt_design -directive AggressiveExplore`
  on the routed DCP) is running as the cheap control of this claim; its result is appended below.

## Measurement traps hit

- `Slack (VIOLATED)` lines are 161 lines apart; a `grep -A` window that stops short never reaches the path's
  `Logic Levels`, and a per-path awk must reset on `Slack (MET)` or it attributes passing paths' endpoints
  to the violated slack values (this happened once here, producing a list of HBM endpoints under -0.254).
- Vivado's `Number of Nodes with overlaps` restarts each router iteration; the number that matters is where an
  iteration ENDS (draw 3: 530, 0, 0, 0 for iterations 1-4; draws 1 and 2: 18,103 and 33,201 at their last).

## Open, not yet answered

- Whether the 597 failing endpoints are ALL in `u_kv` (only the group's worst 10 are in the summary; draw 3b's
  `report_timing -slack_lesser_than 0 -max_paths 300` census answers it).
- The synthesis-level depth of the path before and after (BC-250 arms, appended below).
- Whether `c_max` (also an unconstrained `integer`) and `run_p0 + rr < cpos_r` leave a 32-bit compare on the
  same CE path; the OOC report will show the residual depth.

## APPENDED 18:12: the OOC arms on the BC-250 (synthesis only, 5.0 ns target, card generics MAXCTX 131072 / POS_W 18 / ADDR_W 33)

`sim/ooc_attn_kv_axi_card.tcl`, one Vivado per arm under `MemoryHigh=9G`, same script, same box, the only
difference the `rtl/attn_kv_axi.vhd` file (HEAD's divider against the counters). **A synthesis-estimate is
not a timing result** (this file's own rule); what is quotable is the STRUCTURAL depth and the LUT delta,
both of which place-and-route cannot change.

| arm | LUT | FF | DSP | synth WNS at 5.0 ns | synth "fmax" | worst path | levels |
|---|---|---|---|---|---|---|---|
| divider (HEAD, build 15) | 33,259 | 20,653 | 27 | -3.090 | 123.6 MHz | `ph_ch_reg[0]` -> `mbank_reg[1][3][*]/CE`, logic 3.163 ns | **37 (CARRY8 = 17)** |
| divider, from `r_beat_reg` | | | | -3.040 | | `r_beat_reg[0]` -> `mbank_reg[1][3][*]/CE`, logic 2.983 ns | 35 (CARRY8 = 15) |
| counters | **29,217** | 20,660 | 27 | -1.262 | 159.7 MHz | (report-only rerun pending, appended below) | |

DERIVED: the divider costs **4,042 LUT** in this block (33,259 - 29,217) and +7 FF buys it back. The
routed card's 33-level path is the same path the OOC arm names (r_beat / ph_ch -> mbank CE, 35-37 levels
here because OOC keeps `ph_ch` in the cone). At 75 MHz the routed card has 13.333 ns and needed 12.945; the
counter arm's whole block closes at an estimated 6.26 ns period in isolation, i.e. the write path is no
longer a candidate for the card's worst path at 75 MHz by a margin of two.

Trap hit in the first counters run: the wrapper asked `report_timing -from *r_beat_reg*` and Vivado errored
`[Vivado 12-4739] No valid object(s) found` because, with the counters in place, `r_beat` is written and never
read, so synthesis removed it; batch mode aborted on the error and the overall report never ran. `r_beat`
is therefore dead RTL and is removed in the commit after the gate rows finish (edit-after-rows, never
mid-run).

## APPENDED 18:14: the counters arm's paths (report-only rerun `counters2`, same synthesis, 90 `w_*` cells, 0 `r_beat_reg`)

| path | slack at 5.0 ns | data path | levels |
|---|---|---|---|
| worst to any `mbank_reg[*]/CE` (from `w_mm_reg[5]`) | **+0.590 (MET)** | 4.306 ns (logic 1.324, route 2.982) | **17 (CARRY8 = 6)** |
| worst from any `w_*` counter | +0.590 | same path | 17 |
| block's new worst overall: `run_p0_reg[1]` -> `alen_reg[*]/D` (the AR issuer's `lim_beat` arithmetic) | -1.262 | 6.244 ns (logic 2.696) | 29 (CARRY8 = 18) |

MEASURED, same script, same box, one file differing: the beat-to-bank-enable path went from 37 levels /
17 CARRY8 / 7.986 ns to 17 levels / 6 CARRY8 / 4.306 ns, and from the block's worst path to 0.59 ns of
positive slack at a 200 MHz target. The residual six carry chains are the `rr <= c_max + RBUF - 1` and
`run_p0 + rr < cpos_r` compares on 32-bit `integer` operands plus the `w_rr + 1` increment; at 75 MHz they
have 9 ns of margin in isolation and are not worth a second pass now. The block's worst path is now the AR
issuer at 6.244 ns, which is also comfortable at 13.333 ns; it would be the next thing at 150 MHz.

## APPENDED 19:40: draw 3b, the control for "phys_opt cannot remove it"

`phys_opt_design -directive AggressiveExplore` on draw 3's routed checkpoint (45 min): WNS -0.254 -> **-0.028**,
TNS -57.5 -> -1.388, failing endpoints 597 -> **103**, route still legal, WHS 0.000. Every one of the 103 is
`GEN_RD[1].ph_ch_reg[0]` -> `GEN_RD[1].mbank_reg[*]/CE` at 33-34 levels. The pre-phys_opt census
(`report_timing -slack_lesser_than 0 -max_paths 300`) put 300 of 300 listed failing endpoints in
`u_kv/GEN_RD.mbank_reg`. So the rejected path above stands with its number: post-route physical optimisation
moves 0.226 ns of route and replication and leaves the 3.9 ns of divider logic, 28 ps short. The answer to
the question is the RTL, and build 17 (15 + f14121d, launched 19:38) is its test. Second-pass phys_opt on the
3b checkpoint is untested and is a backlog item, not a plan: the lane is build 17's.
