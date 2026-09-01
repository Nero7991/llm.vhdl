# TRACK ROUTE3: the composed A+B+C+D routes with the real norm gain image in. Does it still fit, and what does timing say?

**Date:** 2026-08-31. **Tree:** `bebd952` (GAIN16 codebook `c094867`,
generator option `45cd94e`, floor raise `0c16b27`, board catch-up), archived
clean to `/mnt/storage/route3_2026-08-31/tree`. **Hardware:** Vivado 2023.2 on
the workstation, `xcvu33p-fsvh2104-2L-e`, one tool at a time. **No hardware
was touched by this track.** Run by the dispatcher in session (no subagents
for RTL tracks; see the WORKLOG's CARDTOP recall).

---

## 1. The question, verbatim

> **Does the composed A+B+C+D route with a NON-EMPTY `NORM_W_IMAGE`?** Every
> composed draw before this one carried the synthetic ramp, so the composed
> BRAM figure never included the gain store. GAIN16 put the store in as an
> 11-bit codebook index (99 RAMB36, MEASURED OOC as `cbland`) plus a
> 1,567-entry table, at zero DSP and zero WNS cost. The composed margin on
> paper is 253.5 + 99 = 352.5 against 372.5 in `pb_core`. Nobody has asked
> the router.

## 2. The answer, up front

**IT ROUTES, with the second pre-registered branch firing: routes but WNS
negative.**

- **`C4_ROUTE_STATUS nets=3,526,125 errors=0 unrouted=0 partial=0`** and
  `# of nets with routing errors: 0` in `route_status_c3img.rpt`.
- **BRAM 351.5 against 372.5 available in `pb_core`: +21.0 headroom.** The
  OOC +20 margin SURVIVES composition -- one tile better than the paper sum,
  because the codebook's 99 replaces the ramp's residue. DSP unmoved at
  2,177. LUT +109, FF +344 against ROUTE2's ramp run.
- **WNS -0.815 ns (hold clean at +0.010).** Against ROUTE2's -0.575 that is
  -0.240 ns, and the breadth moved more than the depth: failing endpoints
  9,056 -> 25,860 (2.86x), TNS -876 -> -7,437 ns (8.5x). The worst single
  path is in `a_eng`'s `matvec_core` (the lever-C LUTRAM neighbourhood, the
  `CB_BCAST` suspect LEVERC48 named), **NOT** in `d_norm` -- the gain
  codebook is not the binding structure.

The fit question ROUTE3 was dispatched on is **closed**: the composition
fits with the gain store in, and it routes. Timing is the separate lever
hunt it always was, now with a measured price for the image.

| | ROUTE2 `c4lev` (ramp) | ROUTE3 `c3img` (codebook) | delta |
|---|---:|---:|---:|
| route errors | 0 | **0** | 0 |
| BRAM (synth) | 253.5 | **351.5** | **+98** |
| DSP | 2,177 | 2,177 | 0 |
| LUT (synth) | 265,658 | 265,767 | +109 |
| FF (synth) | 237,832 | 238,176 | +344 |
| placed CLB | 46,713 | 46,550 | -163 |
| WNS (routed) | -0.575 | **-0.815** | **-0.240** |
| failing endpoints | 9,056 | **25,860** | **2.86x** |
| TNS | -876.045 | -7,437.004 | 8.5x |
| WHS | +0.010 | +0.010 | 0 |

## 3. The procedure

The mirror of ROUTE2's accepted configuration, one variable changed:

- `hw/fk33/gen_compose4_top.py --norm-w-image <hex>` (`45cd94e`) bakes the
  real image into `d_norm`'s generic map; the default regeneration is
  byte-identical to the committed `compose4_top.vhd` (MEASURED before
  committing), so no existing number moves.
- Image `/mnt/storage/nwfix/img/norm_w_9b.hex`, md5
  `69f614a1515e1160f5dc9e8a9e72fdc3`, 266,240 lines.
- `ooc_normadapt_top.vhd` extracted from the SAME tree's `llama_top.vhd`
  (the record-free codebook form).
- `C4_PBLOCK=1` in the card's real `pb_core` (CLOCKREGION_X0Y0:X6Y3),
  CB_STYLE="distributed", core 5.0 ns / hbm 4.0 ns, 8 threads.
- Stages: `elab` (sentinel `C4_DONE elab c3img`), `synth`, `impl`
  (place + route), each gated on the sentinel, not the waiter.
- Memory: `MemoryHigh=22G` for synth/impl per ROUTE2's precedent; the impl
  stage ran ALONE on the box (the final-tree gate had already finished).

## 4. The evidence

Stage timings and the route verdict, verbatim:

```
C4_ELAB_CELLS 429733          (ROUTE2 ramp: 429778)
Finished RTL Elaboration : elapsed = 00:07:55   (ROUTE2 ramp: 00:01:34)
C4_SYNTH_SECONDS 1108         (ROUTE2 ramp: 456)
C4_UTIL c3img synth lut 265767 lut_logic 237925 lut_mem 27842 ff 238176
      carry8 12176 f7 20235 f8 3970 bram 351.5 uram 0 dsp 2177
C4_PLACE_SECONDS 1450
C4_PLACED placed  clb_sites_used 46550  wns -0.331  failing_endpoints_max 295
C4_PLACED physopt clb_sites_used 46573  wns -0.069  failing_endpoints_max 134
C4_ROUTE_SECONDS 2522
C4_ROUTE_STATUS nets=3526125 errors=0 unrouted=0 partial=0
C4_TIMING wns=-0.815 whs=0.010
C4_DONE impl c3img
```

The timing summaries (core_clk group first, hbm_aclk second):

```
ROUTE2 c4lev:  Setup :  9056 failing, worst -0.575ns, TNS  -876.045ns
               Hold  :     0 failing, worst +0.010ns
               hbm   :     0 failing, worst +0.080ns
ROUTE3 c3img:  Setup : 25860 failing, worst -0.815ns, TNS -7437.004ns
               Hold  :     0 failing, worst +0.010ns
               hbm   :     0 failing, worst +0.037ns
```

The worst path (ROUTE3):

```
Slack (VIOLATED) : -0.815ns
  Source:      a_eng/eng/dut/core/xq_rd_reg[0]_rep/C
  Destination: a_eng/eng/dut/core/tr_reg[1][1007]/DSP_A_B_DATA_INST/A[6]
  Logic Levels: 1  (RAMD32=1)
```

The `pb_core` BRAM occupancy, routed
(`out/pbutil_c3img_routed.rpt`, composition only; the shell's 203.5 is
reserved by convention, which is why the comparison is against 372.5):

```
| Block RAM Tile | 351.5 used | 576 available in region | 61.02% |
|   RAMB36/FIFO* |   330      |                         |        |
|   RAMB18       |    43      |                         |        |
| URAM           |     0      |                         |        |
```

## 5. Measured and REJECTED -- do not retry

- **Quoting Vivado's `Memory (MB): peak` as a footprint.** Elaboration
  reported `peak = 31156.000` MB while the externally measured RSS stayed
  ~8 GiB. The allocation figure counts what swap and overcommit absorb; the
  honest pair is summed `/proc` RSS (or cgroup `memory.peak` from a run that
  never reached its cap). ROUTE3's elab RSS: ~8 GiB.
- **The `errors=93489` misread is FIXED at this tcl.** ROUTE2's
  `C4_ROUTE_STATUS` printed `errors=93489` on a design with 0 errors (the
  hierport property read as errors). The current
  `sim/ooc_compose4_pnr.tcl` prints `C4_ROUTE_HIERPORT 93489
  (out-of-context port nets, NOT errors)` on its own line and
  `C4_ROUTE_STATUS ... errors=0`. Do not resurrect the old reading.
- **`ghdl`-side nothing.** No simulation was run by this track; the question
  was routability.

## 6. Measurement traps hit

- **`sim/ooc_compose4_pnr.tcl`'s impl stage refuses an empty `C4_DCP`** and
  ROUTE2's driver never exported one (its chain passed it out of band).
  ROUTE3's driver exports `C4_DCP=$C4_OUT/${TAG}_synth.dcp` for the impl
  stage. Recorded so the next track does not rediscover it.
- **`systemd-run --user --scope` attaches the scope's lifetime to the
  client.** ROUTE3's stages ran as transient SERVICES
  (`systemd-run --user --unit=...`), which return immediately and survive
  the launcher. Same lesson the WORKLOG carries for teeth Run B.
- **The box was shared for the synth stage** (the final-tree gate, 2.13 GiB,
  still running): `C4_SYNTH_SECONDS 1108` against ROUTE2's 456 is part
  codebook ROM initialisation and part contention. The impl stage ran alone;
  its figures are the clean ones.

## 7. Open, not yet answered

- **The timing lever hunt.** `CB_BCAST` is the named suspect (LEVERC48
  CORRECTION 2: WNS reverses with lane count, -0.269 at 1,536; the worst
  path here is one RAMD32 in the lever-C read path). Whether the 2.86x
  endpoint breadth is the same lever-C families at greater depth or a new
  structure is the census result appended below.
- **Whether -0.815 ns is recoverable by directives alone** (a placement
  directive sweep is the cheap first move), or whether `CB_BCAST` is
  genuinely load-bearing and wants a pipeline stage.
- **STEP 3 (the card top, row N3) is unblocked on fit and blocked on
  nothing else.** It owns the remaining critical path.

## 8. The endpoint census

MEASURED on the routed checkpoint (`c3img_routed.dcp`), the 200 worst setup
paths grouped by structure root (`log/census2.log`):

```
162  a_eng/eng/dut        -> a_eng/eng/dut        (matvec_core, 81%)
 20  c_attn/u_arr/acc     -> c_attn/u_arr/er_r    (attention MAC array)
 12  c_attn/ar_rdi_reg    -> c_attn/u_arr/od_r
  4  c_attn/u_quant       -> c_attn/gvrec/gkrec
  2  a_eng/eng/dw_reg     -> a_eng/eng/dut
  0  d_norm               (NOWHERE in the 200 worst)
```

**The gain codebook is in none of the 200 worst paths.** The -0.240 ns of
WNS and the 2.86x endpoint breadth are placement-level pressure from the +98
BRAM and +109 LUT reshaping the floorplan, landing on the structures that
were already the binding ones -- 81% in A's `matvec_core` (the lever-C
read-path family, `CB_BCAST` suspect) and 16% in C's attention array. The
gain store costs area and placement pressure; it does not itself become a
critical path. That is the best possible shape for the timing lever hunt:
the quarry is the same one LEVERC48 already named.
