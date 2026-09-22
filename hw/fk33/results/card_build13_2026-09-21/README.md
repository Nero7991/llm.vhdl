# Build 13: FAILED TO ROUTE. The congestion prediction hit, and no lever is attributable.

FK33_CARD=1 card build, worktree `/mnt/storage/fk33_builds/wt13` at `9de6ee4`
(build 12b's RTL and generators, NO patch: every lever as committed at HEAD),
launched 2026-09-21 19:16, `impl_1` FAILED 23:33. Roughly 4h17m; `route_design`
alone 2h54m wall. Composition stated before launch in `COMPOSITION.md`.

## The verdict, from the authority

`bd_wrapper_route_status.rpt`:

```
# of routable nets..................... :      682717 :
    # of fully routed nets............. :      671156 :
# of nets with routing errors.......... :       11561 :
    # of nets with resource conflicts.. :       11561 :
```

`ERROR: [DRC RTSTAT-6] Partial route conflicts: 11561 net(s)`, `Bitgen not run`,
`write_bitstream failed`, `Failed runs(s) : 'impl_1'`. **No bitstream exists.**
Phase 8 of the router: `[Route 35-162] 11561 signals failed to route due to
routing congestion`, the same message that opened build 11b's Phase 8 with
146,948. Build 12b's Phase 8 printed nothing.

The routed timing summary reads WNS **-1.789** ns (11,792 failing endpoints of
1,525,232) with the worst paths in `gcr.gkvaxi.u_kv` (`ph_ch_reg` to the
`mbank_reg` CE fan-out, route 11.25 of 15.02 ns). **That is the timing of a
design 11,561 nets short of routed and is NOT a timing result**; it is recorded
because the object it names is the same critical path the 12b characterisation
named, at the same clock.

## Composition, every value verified from Vivado's own output

| lever | build 12b | **build 13** | evidence |
|---|---|---|---|
| `NWIDE` | 0 | **1** | `Parameter NWIDE bound to: 1` |
| `FAST_POP` | 0 | **1** | `Parameter FAST_POP bound to: 1` x8 |
| `SWEEP_PIPE` | 0 | **1** | `Parameter SWEEP_PIPE bound to: 1` |
| `SCORE_EARLY` | 0 | **1** | `Parameter SCORE_EARLY bound to: 1` |
| `CB_STYLE` | distributed | distributed | `Parameter CB_STYLE bound to: distributed` x4 |
| `ENG_CORE_MHZ` | 75 | 75 | `FK33_CORE_MHZ 75.000`, Clock Summary 13.333 ns |
| codebook | reverted | reverted | same `matvec_core.vhd` md5 |
| `XEXP_OUT` register | absent | absent | `9de6ee4` predates dbf3ea5; `fk33_card.vhd` has no `x_exp_out` |

**Four levers changed at once, by choice** (the launch question offered it and
Oren picked it), so this failure is attributable to the SET and to no member of
it. Every one of the four had routed OOC at the card generics with positive WNS.

## The pre-registered congestion prediction: HIT (second live use, first failure predicted)

`PREDICTION_congestion.md`, written 20:50 while Phase 4 was running, recorded
max Global `% Tiles` **13.09** (WEST 32x32; SOUTH 10.65, EAST 5.57, NORTH 3.14)
against CONGABORT's separation (legal 6.96-11.95, failures 12.78-17.36,
threshold 12.5) and predicted NOT a legal route. Build 12b had scored 11.95 and
routed. Both live uses of the trigger have now been correct, one each way; the
0.83-point gap and the unbounded false-positive rate stand as recorded there.

Global Iteration 2 reported `Number of Nodes with overlaps` falling 653,292 ->
84,277 across its passes and still did not converge; the router then wrote
`[Route 35-447] Congestion is preventing the router from routing all nets`,
which fires on 7 of 8 legal routes too and carried no information here either.

## Where, not why

All 8 named nets at the top ten overlap nodes in Phase 8 are in
`bd_i/card/inst/u/gcr.u_attn/u_arr` (`phase8_nets.txt`), the attention MAC
array. The RTSTAT-6 list names `gcr.u_attn/u_arr/ARG__1[*]` and
`eng/dut/core/ARG__1[*]` alternately, and the first conflict listed in the
route status report is `GLOBAL_LOGIC0`. That bounds WHERE the conflicts are
(C's array and the codebook region of A) and says nothing about WHY: with four
levers changed, the object named is not the lever named. Build 10 (NWIDE on,
the other three off) failed with 98.08% of its failing endpoints in C, which is
the same subsystem, and is also a multi-variable comparison against this one.

## Area, placed, against 12b

| metric | build 12b | **build 13** | delta |
|---|---|---|---|
| CLB tiles | 54,451 (99.07%) | **54,802 (99.71%)** | +351 |
| CLB free tiles | 509 | **158** | -351 |
| CLB LUTs | 367,495 | 363,226 | -4,269 |
| CLB Registers | 310,570 | 308,920 | -1,650 |
| F7 Muxes | 28,125 | 28,536 | +411 |
| F8 Muxes | 5,979 | 6,078 | +99 |
| CARRY8 | 12,596 | 12,546 | -50 |
| Block RAM tiles | 567 | 595 | +28 |
| DSPs | 2,087 | 2,087 | 0 |

Fewer LUTs and registers, MORE CLB tiles: the placer packed the four-lever
netlist less densely (351 tiles for -4,269 LUTs), which is the shape of a
netlist with more, wider fan-out nets and is consistent with the congestion
figure, not evidence of its cause.

## Memory

Never binding. Synthesis peaked at Vivado's own 32.3 GB virtual with 8.3 GB
free physical; implementation 14.9 GB peak; swap 7 GB for the whole of place
and route (`watch.log`), guard threshold 30 GB never approached. `MemoryHigh=24G`
verified at launch.

## What this build establishes, and what it does not

**ESTABLISHES:** the four levers together, on 12b's tree, do not route at 75
MHz on this part with `Performance_RefinePlacement`. The congestion trigger's
second live verdict was correct.

**DOES NOT ESTABLISH:** which lever, or which pair, is responsible; whether a
different implementation strategy would route this netlist (`card_swg` once
re-implemented from the same checkpoint from 13.45 to 9.33 and routed);
anything about timing.

**NEXT (branched on the board before the verdict):** build 14 is 12b's lever
state plus the two-card `XEXP_OUT` register (17 flops and a mux entry), so the
two-card rehearsal does not wait on the lever question. The lever question needs
one-variable builds or, cheaper, re-implementation of `KEEP_build13_dcp`'s
synthesis checkpoint under other directives, since synthesis cannot read them.

## Files

Route status; placed utilization (flat and hierarchical); routed timing summary,
DRC, methodology, clock utilization, control sets, IO (gzipped where large);
`runme.log.gz`; `build.stdout.gz`; `PHASE_TIMES.txt`; `INTERMEDIATE_TIMING.txt`;
`SENTINELS.txt`; `PROVENANCE.txt`; `COMPOSITION.md`; `PREDICTION_congestion.md`;
`phase8_nets.txt`; `watch.log`. Synth, placed and routed DCPs are preserved at
`/mnt/storage/fk33_builds/KEEP_build13_dcp/` with `SHA256SUMS`.
