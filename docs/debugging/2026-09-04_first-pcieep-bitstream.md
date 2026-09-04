# The first pcieep bitstream, and it misses 200 MHz by 0.203 ns

**Date:** 2026-09-04
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, `hw/fk33/pcieep_build.sh`
**Tree:** `3b6b117` (after the two blocker fixes of 2026-09-03)

## The question

Now that the block design validates again, does a full build produce a
bitstream, and is it usable?

## The answer

**A bitstream exists. It does not close timing.**

```
BITSTREAM .../impl_1/bd_wrapper.bit (20630206 bytes)
FK33_TIMING WNS=-0.203 ns  WHS=0.002 ns
errors: 0
```

`clk_out3_bd_clk_wiz_0_0` is the 200 MHz core clock (`FK33_ENGI clock
clk_out3_bd_clk_wiz_0_0  period 5.000 ns (200.00 MHz)`). WNS -0.203 ns means
the design closes at **192.2 MHz**, not 200. Hold is met (WHS +0.002).

| quantity | value |
|---|---|
| WNS | **-0.203 ns** |
| TNS | -956.901 ns |
| failing endpoints | **9,213 of 446,425 (2.06%)** |
| WHS | +0.002 ns (met) |
| ERROR count | 0 |
| unmatched constraints | 0 |

**This bitstream contains subsystem A only.** `hw/fk33/rtl/fk33_engine.vhd`
instantiates exactly one entity, `matvec_int4_desc_axi`. There is no B, no C,
no D and no state tier in it, so it cannot run inference. What it establishes
is that the PCIe/XDMA/HBM endpoint builds end to end again.

Utilisation, the whole endpoint:

| resource | used | avail | % |
|---|---|---|---|
| CLB LUTs | 182,271 | 439,680 | 41.46 |
| CLB Registers | 125,850 | 879,360 | 14.31 |
| CLB | 33,020 | 54,960 | **60.08** |
| Block RAM Tile | 261.5 | 672 | 38.91 |
| URAM | 0 | 320 | 0.00 |
| DSP | 1,585 | 2,880 | 55.03 |

## The comparison that matters, and it is the wrong way round

`compose4_top` -- subsystems A, B, C **and** D at the real 9B shape -- routes
at **-0.090 ns** with high-effort directives, i.e. 196.5 MHz. This endpoint,
carrying **only A** plus the PCIe/XDMA/HBM infrastructure, is **worse at
-0.203**.

So the shortfall is not the model subsystems. It is what the endpoint adds
around them: XDMA, the HBM controller, the interconnect and the seam. That is
a different problem from the one the compose4 census was characterising, and
the two must not be conflated.

**NOT YET ATTRIBUTED:** which hierarchy the 9,213 failing endpoints sit in. The
compose4 work established a method for this (a failing-endpoint census by
parent, which overturned the reading taken from the worst path alone) and it
has NOT been run here. Do not assume the worst path names the owner; on
compose4 the worst path was in `c_attn` while 76.1% of endpoints were in
`a_eng`.

## The procedure

1. `hw/fk33/pcieep_build.sh --bd-only` first, 3 min and 3.4 GB, to prove the
   block design still validates. It is 1/20th the cost of the full build and
   catches every class of error that is not a timing or placement result.
2. Full `pcieep_build.sh` under `systemd-run --user -p MemoryHigh=26G` so it
   throttles rather than hanging the box. MEASURED peak here **10.66 GB**, far
   under the 25.0 GiB the project's notes quote; `free physical` never went
   below 14.4 GB. **The 25.0 GiB figure did not reproduce on this build** --
   see the rejected section.
3. Read `^BITSTREAM `, `^FK33_TIMING` and `^ERROR` with LINE-ANCHORED greps,
   because this script echoes its own source into its log.

## Evidence

```
FK33_BD_VALIDATE OK
FK33_XDC_CHECK OK
FK33_HOST_COMPILE OK
FK33_HOST_SELFTEST OK
FK33CTL_TESTS OK
FK33_AUXCLK analysed paths crossing the aux boundary: 0 (must be 0)
FK33_HUBCLK OK dbg_hub is on sysref_clk
FK33_TIMING WNS=-0.203 ns  WHS=0.002 ns
FK33_BITSTREAM ./fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper.bit (20630206 bytes)
--- unmatched constraints (should be ZERO now; any is a real error) ---
0
PCIEEP_WRAPPER_EXIT 0
```

Intra-clock table, the failing row:

```
clk_out3_bd_clk_wiz_0_0   rise - rise   -0.20  -956.90   9213   446425   5.00  Clean  Partial False Path
```

## Measured and REJECTED -- do not retry

- **"A full pcieep build peaks at 25.0 GiB, so it cannot run beside anything."**
  MEASURED here: **10.66 GB peak**, `free physical` minimum 14,440 MB, on a
  build that produced a bitstream with 0 errors. The 25.0 GiB figure in
  CLAUDE.md is either from a different configuration or was never a peak of
  this script. **Do not quote 25.0 GiB for this build again without
  re-measuring**, and do not use it to justify refusing to run it.
  What remains true is that the peak is a property of the job and this is ONE
  observation of it; the cap is what made running it safe, not the sample.
- **"Nothing else can run alongside."** Given 10.66 GB, that was over-cautious
  in hindsight -- but it was the correct call on the information available,
  since the only figure on record was 25.0 GiB and the box has died once from
  exactly this arithmetic. The fix is the measurement above, not a change of
  policy.

## Measurement traps hit

- **The exit code is the wrapper's, not the build's.** `PCIEEP_WRAPPER_EXIT 0`
  and `errors: 0` are two different claims; the timing miss makes neither of
  them a statement that the bitstream is usable. A build can succeed
  completely and still produce something you must not run at the target clock.
- **`WNS=-0.203` alone does not say WHICH clock.** Five clock domains appear in
  the intra-clock table and four of them pass with large margins (the GT
  monitor clocks are at +6.9 to +998). Only `clk_out3` fails. Reading the
  headline WNS without the per-clock table would have left the impression that
  the whole design is marginal.

## Open, not yet answered

- **Which hierarchy owns the 9,213 failing endpoints.** Needs the
  failing-endpoint census by parent, run against the routed DCP. Not done.
- **Whether 200 MHz is required at all.** This has been an open question for
  some time and it is now load-bearing: at 192.2 MHz the bitstream is usable
  as built, and the entire timing problem disappears if the target moves.
- **Nothing here has run against the card.** `pcieep.sh` and `save_bitstream.sh`
  were NOT run; this is a build-only result.
