# Build 15: 14 + the R_X shadow. Three draws; the third ROUTES and misses timing by 0.254 ns.

Worktree `/mnt/storage/fk33_builds/wt15` at `f0fcb37` + `build12_levers_off.patch` (levers off); `FK33_CARD=1
FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75`. Synthesis 26 min, BRAM 569 = 567 + 2 (the shadow's predicted
cost). `COMPOSITION.md` is the pre-registered composition; every value verified from the log.

| draw | recipe | placed CLB | congestion (max Global % Tiles) | verdict |
|---|---|---|---|---|
| 1 | `Congestion_SpreadLogic_high` / place `ExtraNetDelay_high` / route `AlternateCLBRouting` (the recipe that rescued build 14) | 54,640 | 11.75 | **8,932 nets in resource conflict** |
| 2 | same strategy, place `AltSpreadLogic_high` | 54,584 | 11.92 | **12,438 nets in conflict** (A's core named as well as `u_arr`) |
| 3 | DEFAULT `Performance_RefinePlacement` (place `ExtraPostPlacementOpt`, route/phys_opt `Default`) | 54,537 | 9.15 | **ROUTED**, 681,010/681,010 nets, 0 routing errors; **WNS -0.254**, TNS -57.5, 597 failing endpoints, WHS +0.009 |

Router iterations ended at 530 / 0 / 0 / 0 overlaps (draw 3) against 18,103 (draw 1) and 33,201 (draw 2) at
their last. The rescue recipe is 2 for 4 on failed default draws; the default recipe is 1 for 3 on the
14/15 netlists. The CONGABORT separation stays withdrawn (draw 1 failed at 11.75, inside the old legal band).

## `bd_wrapper.bit` in this directory FAILS TIMING and must not be loaded

It is draw 3's image (25,859,554 bytes, `BITSTREAM.sha256`; the file itself is NOT committed, it lives at `/mnt/storage/fk33_builds/KEEP_build15_dcp/draw3/`), kept as the record of a legal route at
-0.254 ns. The card keeps build 14. The routed timing table:

```
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)
     -0.254      -57.509                    597              1529003        0.009        0.000
```

## Where the 0.254 ns is

All ten worst violated paths are `u_attn/gcr.gkvaxi.u_kv/GEN_RD[1].r_beat_reg[1]` to a `mbank_reg[..]/CE`
in `rtl/attn_kv_axi.vhd`: 33 logic levels, 14 CARRY8, data path 12.945 ns (route 9.070). The RTL divided
the 32-bit beat counter by CPR = 17 and took `rr mod RBUF` combinationally on every beat. The router's
Phase 12 physical synthesis took WNS from -0.610 to -0.254 by working 40 nets of this bank and could not
remove the divider. Root cause and the counter rewrite:
`docs/debugging/2026-09-22_the-kv-fetcher-divides-by-17-on-every-beat.md`.

## Files

`draw1/`, `draw2/`: route status, placed utilization, congestion, logs of the failed draws.
`draw3/`: `bd_wrapper_route_status_reimpl3.rpt`, `bd_wrapper_timing_summary_routed.rpt.gz` (the ten paths),
placed and routed utilization, `reimpl3.stdout.gz`. `reimpl.tcl`, `reimpl2.tcl`, `reimpl3.tcl` and the
three chain scripts are the exact recipes. DCPs (synth, and placed/routed per draw) at
`/mnt/storage/fk33_builds/KEEP_build15_dcp/` with `SHA256SUMS`.

Draw 3b (post-route `phys_opt_design -directive AggressiveExplore` on draw 3's routed DCP, `reimpl4.tcl`)
is recorded below when it lands.

## Draw 3b (post-route `phys_opt_design -directive AggressiveExplore` on draw 3's routed DCP): -0.028 ns

`reimpl4.tcl`, unit `card15-reimpl4`, 18:08 to 18:53. Route stays legal (681,011/681,011, 0 errors).

```
    WNS(ns)   TNS(ns)   TNS Failing Endpoints   WHS(ns)
     -0.028    -1.388                     103     0.000
```

Recovered 0.226 of the 0.254 ns and still not closed; **all 103 remaining endpoints are the same path
family**, `u_kv/GEN_RD[1].ph_ch_reg[0]` -> `mbank_reg[*]/CE`, 33-34 logic levels: the divider, which
phys_opt can only re-place and replicate, not remove. The census taken BEFORE the phys_opt
(`draw3b/failing_paths_before.rpt.gz`, `report_timing -slack_lesser_than 0 -max_paths 300`) names
`gcr.gkvaxi.u_kv/GEN_RD.mbank_reg` for **300 of 300** listed endpoints (the report's cap; the full 597 were
not enumerated). No bitstream was written (the script refuses on negative slack). DCP at
`/mnt/storage/fk33_builds/KEEP_build15_dcp/draw3b/`. The RTL fix (`f14121d`) is build 17.
