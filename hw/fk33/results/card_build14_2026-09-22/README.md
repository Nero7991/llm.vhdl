# Build 14: first draw FAILED TO ROUTE by 11 nets inside the trigger's legal band; the re-implementation from the same checkpoint CLOSED at 75 MHz with a bitstream

FK33_CARD=1 card build, worktree `/mnt/storage/fk33_builds/wt14` at `330b70f`
plus `build12_levers_off.patch` (build 12b's exact 4-file lever-off patch), so
this is **build 12b's design plus only the two-card `XEXP_OUT` register**
(commits 863d173..f0b5412: `seq_region_lock` capture ports, `llama_top`
`x_exp_out`, seam register 0xA4 and caps bit 6, `fk33_card` pin, one
`SEAM_FROM_CARD` entry). Launched 2026-09-21 23:41, `impl_1` FAILED 2026-09-22
05:5x. Roughly 6h10m; `route_design` alone **4h49m** wall (12b: about 2h).

## The verdict, from the authority

`bd_wrapper_route_status.rpt`:

```
# of routable nets..................... :      680703 :
    # of fully routed nets............. :      680692 :
# of nets with routing errors.......... :          11 :
    # of nets with resource conflicts.. :          11 :
```

`ERROR: [DRC RTSTAT-6] Partial route conflicts: 11 net(s)`, `Bitgen not run`.
**No bitstream.** Eleven nets of 680,703. The routed WNS -2.577 (16,718 failing
endpoints) is the timing of a design the router gave up on and is NOT a result.

## Composition, verified from the log

`Parameter NWIDE bound to: 0`, `FAST_POP bound to: 0` x8, `SWEEP_PIPE bound to:
0`, `SCORE_EARLY bound to: 0`, `CB_STYLE bound to: distributed` x4, 75 MHz
(`FK33_CORE_MHZ 75.000`). `FK33_SEAMWIRE 41` seam-card pins (build 13: 40; the
new one is `x_exp_out`), `FK33_UNCONNECTED count=0`, `FK33_CARDPINS 53`.
`git diff --stat` in the worktree after the patch: 4 files, 6 insertions, 6
deletions. `PROVENANCE.txt` says 7 modified paths because the build script
regenerates `build_fk33_pcieep.tcl` and `build_fk33_i2cprobe.tcl` and writes
its results directory into the tree.

## The pre-registered prediction: MISSED, and that is the finding

`PREDICTION_congestion.md` (written 00:57 during Global Iteration 0) recorded
max Global `% Tiles` **11.73** (WEST; SOUTH 10.60, EAST 5.22, NORTH 3.84)
and, since CONGABORT's calibration had every legal route at 6.96-11.95 and
every failure at 12.78-17.36, predicted a LEGAL route. **It did not route.**

So a run at 11.73 has now failed while a run at 11.95 (build 12b, a design
17 flops smaller) routed. **The 0.83-point gap that separated twelve runs is
gone**: the bands overlap, and the trigger document's own open item ("a fifth
failure could fall below 11.95 and destroy the separation") is answered, from
a thirteenth run rather than from the lost fifth. The `% Tiles` figure remains
a run property with no ordering of severity (11 conflicts here, 11,561 in
build 13 at 13.09, 209 at 13.45, 146,948 at 17.36). What survives: a figure
above ~12.5 has still never routed; a figure below it is now NOT a promise.

Note also the router's shape: Iteration 1 alone ran about two hours and got
overlaps down to 43 before giving up in Iteration 2, and `route_design` took
2.4x build 12b's wall time. A router that nearly converges is the same
verdict as one that fails by 11,561 nets, and reads very differently in the
log.

## Where, not why

The eleven conflicting nets: seven in `gcr.u_attn/u_arr` (`acc[*]`, `av[*]`,
`p_reg_reg[33]0_i_*`), one `gcr.u_attn/ar_pve_reg[1]`, one
`eng/inst/eng/cb_data_reg_n_0_[2]`, one `u_regmem/g_region[11].wr_addr[5]`,
plus one truncated. **The same attention MAC array build 13's overlap nodes
named, on a design with none of build 13's levers.** So `u_attn/u_arr` is
where this design is tight regardless of the levers, and build 12b routed it
at the margin (its own Phase 8 was clean, its % Tiles 11.95). Location only.

## Area, placed

| metric | build 12b | build 13 | **build 14** |
|---|---|---|---|
| CLB tiles | 54,451 (99.07%) | 54,802 (99.71%) | **54,884 (99.86%)** |
| CLB free tiles | 509 | 158 | **76** |
| CLB LUTs | 367,495 | 363,226 | **361,887** |
| CLB Registers | 310,570 | 308,920 | **310,544** |
| F7 / F8 Muxes | 28,125 / 5,979 | 28,536 / 6,078 | 28,190 / 5,966 |
| Block RAM tiles | 567 | 595 | 567 |
| DSPs | 2,087 | 2,087 | 2,087 |

Fewer LUTs than 12b, 433 more CLB tiles. The register is not 433 tiles; this
is the per-draw packing scatter the project has already measured
(`docs/debugging/2026-08-30_scatter-per-draw-area-variance.md`), and it is
the plausible mechanism for a design at 99+% CLB routing on one draw and not
the next. That is a hypothesis, not a measurement.

## The re-implementation: CLOSED (`reimpl/`)

`reimpl.tcl`: `impl_1` again from build 14's OWN `synth_1` checkpoint with the
recipe that rescued `card_swg_2026-09-20` from its own checkpoint: strategy
`Congestion_SpreadLogic_high`, `place_design -directive ExtraNetDelay_high`,
`route_design -directive AlternateCLBRouting`, phys_opt `AggressiveExplore`,
all four read back from the run (`REIMPL_STRATEGY` sentinel). No synthesis:
`opt_design`'s checksums are byte-identical to the first draw's, so this is
one netlist under two implementation recipes. Launched 05:54, bitstream 07:46,
**1h52m** against the first draw's 6h10m; `route_design` 1h15m against 4h49m.

`reimpl/bd_wrapper_route_status.rpt`:

```
# of routable nets..................... :      681069 :
    # of fully routed nets............. :      681069 :
# of nets with routing errors.......... :           0 :
```

Routed timing summary, `clk_out3_bd_clk_wiz_0_0` 13.333 ns / 75.000 MHz:

```
WNS 0.056  TNS 0.000  failing endpoints 0 of 1,528,825  WHS 0.009  THS 0.000  hold failing 0
```

Phase 8 printed `Verification completed successfully` and nothing else. The
router reached zero overlapping nodes in Iteration 3 and ran a fourth,
timing-driven iteration; the first draw never reached zero.

| metric, placed | first draw (default recipe) | **re-implementation** | build 12b |
|---|---|---|---|
| CLB tiles | 54,884 (99.86%) | **54,607 (99.36%)** | 54,451 |
| CLB LUTs | 361,887 | 362,014 | 367,495 |
| CLB Registers | 310,544 | 310,560 | 310,570 |
| max Global % Tiles | 11.73 | **10.37** | 11.95 |
| route_design wall | 4h49m | **1h15m** | ~2h |
| routing errors | 11 | **0** | 0 |
| routed WNS | (unrouted) | **+0.056** | +0.046 |

Same netlist, 277 fewer CLB tiles under the spread-logic placer, 1.36 points
less estimated congestion, and a legal route. **This is the first
one-variable implementation control on the card build**, and the variable is
the recipe. It does NOT say the default recipe cannot route this netlist on
another draw; it says this recipe did, once.

Memory: swap never above 5 GB, peak 15.2 GB resident (Vivado's own figure),
guard never fired.

**Bitstream:** `bd_wrapper.bit` (25,771,342 bytes), sha256 `d9f0cb13...` in
`BITSTREAM.sha256`; loadable copy at
`hw/fk33/bit/fk33_card_build14_xexp_75mhz_2026-09-22.bit` (gitignored).
Synth, first-draw placed and routed, and re-implementation placed and routed
DCPs plus the bitstream at `/mnt/storage/fk33_builds/KEEP_build14_dcp/`.

**What it carries:** build 12b's design (all levers off, codebook reverted,
`CB_STYLE=distributed`, 75 MHz) plus the two-card `XEXP_OUT` register at seam
0xA4 with capability bit 6, so `fk33ctl.py seam` must read `CAPS_FLAGS
0x7D`. Throughput is predicted identical to 12b to the 0.004% floor.

## Files

Route status; placed utilization (flat and hierarchical); routed timing
summary, DRC, methodology, clock utilization, control sets, IO; `runme.log.gz`;
`build.stdout.gz`; `PHASE_TIMES.txt`; `INTERMEDIATE_TIMING.txt`;
`SENTINELS.txt`; `PROVENANCE.txt`; `COMPOSITION.md`; `PREDICTION_congestion.md`;
`phase8_nets.txt`; `reimpl.tcl`; `watch.log`. Synth, placed and routed DCPs at
`/mnt/storage/fk33_builds/KEEP_build14_dcp/` with `SHA256SUMS`.
