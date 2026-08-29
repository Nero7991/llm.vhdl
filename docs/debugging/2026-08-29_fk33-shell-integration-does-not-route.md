# Can subsystem A be put in the FK33 shell, and what does it cost after place and route?

**Date:** 2026-08-29. Branch `fpga`, baseline `54b3c1a`, built in a detached
`git worktree` so that the tracks editing `rtl/` concurrently could not
contaminate a netlist.
**Tool:** Vivado 2023.2, `-mode batch`, `hw/fk33/pcieep_build.sh`.
**Part:** `xcvu33p-fsvh2104-2L-e`, SQRL FK33, 8 GiB HBM as two 4 GiB stacks.
**Geometry:** the FK33 one -- `ROWS_IF=48`, `AXI_DW=256`, `NPORTS_W=24`,
`NPORTS_S=3`, `BLK=32`, `ADDR_W=40`, `MAXB=16`, `MAXOUT=16`, `FIFO_DEPTH=512`,
`MAXCOLS=MAXROWS_BFP=17408`, `DUAL_CLK=true`. 27 weight/scale AXI read masters
plus the descriptor fetch master = 28.

**NO HARDWARE WAS TOUCHED.** No `xsdb`, no `hw_server`, no programming, no
`pcieep.sh`, no `jtag.sh`, no `flash.sh`, no `/dev/xdma*`. **No bitstream
exists**, because the build did not get that far.

Predecessors, and the numbers this set out to test in context:
`docs/debugging/2026-08-28_ar-throttle-timing-close.md` (AXI 257.33 MHz) and
`docs/debugging/2026-08-28_matvec-divide-by-48-core-clock.md` (core 230.73 MHz,
LUT 134,534, FF 64,067, DSP 1,585, BRAM36 192.5). Both are **out-of-context**
figures: no `place_design`, no `route_design`, no shell.

Labels: **MEASURED** (a named tool produced the number), **DERIVED**
(arithmetic on measured inputs, shown), **ESTIMATE** (a judgement with its
assumption stated).

---

## 1. The question

Backlog item 2 of `docs/WORKLOG.md`, blocked all day and unblocked by
`a4f7e17` and `54b3c1a`: enable the 28 HBM SAXI ports the endpoint build turns
off, instantiate subsystem A behind them, keep the thermal guard and the
free-running aux domain intact, build, and report utilisation, WNS and the
achieved clocks **after place and route** against the out-of-context ceilings.

## 2. The answer

**The design does not route.** MEASURED, verbatim from
`impl_1/runme.log:3168`:

```
ERROR: [Route 35-3] Design is not routable as its global congestion level is 7.
ERROR: [Route 35-4445] route_design is terminated due to errors/critical
       warnings issued before and during initial routing.  The issues reported
       cannot be resolved later in route_design.
```

7 is the top of Vivado's congestion scale. The router made six attempts at
initial net routing over 7 min 28 s and abandoned the design; **there is no
routed checkpoint and no bitstream.**

**Area is not the reason, and it is comfortable.** MEASURED on the
post-`phys_opt` checkpoint at VCCINT 0.717 V, whole design:

| | used | available | util |
|---|---|---|---|
| CLB LUTs | 173,694 | 439,680 | **39.50%** |
| CLB Registers | 125,015 | 879,360 | 14.22% |
| CARRY8 | 6,448 | 54,960 | 11.73% |
| BRAM36 tiles | 261.5 | 672 | **38.91%** |
| URAM | 0 | 320 | 0% |
| DSP48E2 | 1,585 | 2,880 | **55.03%** |
| MMCM | 1 | 4 | 25% |
| HBM_SNGLBLI_INTF_AXI | 32 | 32 | 100% |

**The engine's own area in context is within 1.8% of the OOC figure on every
line**, which is the single most reassuring number here:

| | OOC, `54b3c1a` | in the shell, post-place+phys_opt | delta |
|---|---|---|---|
| CLB LUTs | 134,534 | **132,113** (30.05%) | -1.8% |
| CLB Registers | 64,067 | **63,797** | -0.4% |
| DSP48E2 | 1,585 | **1,585** | 0 |
| BRAM36 | 192.5 | **192.5** | 0 |
| URAM | 0 | 0 | 0 |

DERIVED: the shell (HBM IP, XDMA, four smartconnects, SYSMON, the aux domain,
the thermal guard, the bring-up peripherals) costs **41,581 LUT** and
**69 BRAM36** on top of the engine.

**Timing was heading toward closure and was never settled**, because the router
gave up before a final timing update. MEASURED, design-wide, in the order the
tool produced them:

| stage | WNS | WHS |
|---|---|---|
| post-place | **-0.763 ns** | -- |
| post-`phys_opt` | **-0.368 ns** | -- |
| router, last intermediate update before it quit | **-0.260 ns** | -0.460 ns |

The clocks asked for were **250 MHz** on the HBM AXI side (`xdma/axi_aclk`,
the clock that already drives `SAXI_00`/`SAXI_16`) and **200 MHz** on the core
(a third `clk_wiz_0` output). Both are MEASURED as constrained in the
implemented design: `clk_out3_bd_clk_wiz_0_0` period 5.000 ns, the AXI clock
period 4.000 ns.

**What the congestion means for the bandwidth arithmetic: nothing, yet.** The
duty identity is `duty = f_core / f_axi` exactly, because 27 x 256 bits = 864 B
is what the array consumes per core cycle and 32 B is what a port supplies per
AXI cycle. It has no absolute frequency in it. So a congestion-forced slowdown
that scales BOTH clocks costs token rate and does not cost feedability:

```
supply = 27 ports x 32 B x 250e6 = 216.0e9 B/s = 216.0 GB/s   (DERIVED)
demand = 864 B x 200e6           = 172.8e9 B/s = 172.8 GB/s   (DERIVED)
duty   = 172.8 / 216.0 = 0.800 = 200 / 250                     (the identity)
```

ESTIMATE, assuming the published 32.80 tok/s at 236.128 MHz scales with the
core clock and that A dominates the token: 200 MHz would be **27.8 tok/s**.
That number is worth nothing until something routes.

## 3. The procedure, and what each step isolates

Cheapest first. Every one of the first three steps caught something that would
otherwise have surfaced at the far end of a fifty-minute build.

| step | cost | isolates |
|---|---|---|
| GHDL analyse the wrapper against the real A sources | seconds | VHDL-93 legality, and that the engine's entity is what the wrapper thinks it is |
| a scratch GHDL bench on the wrapper, plus a negative control | ~1 min | **that the thermal halt actually blocks a GO** -- it did not, see 6.1 |
| `pcieep_build.sh --bd-only` | ~2 min, 2.95 GB | IP configuration, address map, port enables, clock association, BD validation. Caught three defects |
| full build | 07:41 wall, 22.8 GB peak | synthesis, placement, routing |
| `report_utilization -cells bd_i/eng` on the post-`phys_opt` checkpoint | ~2 min | the engine's area IN CONTEXT, without subtracting a remembered shell number from a design total |

**Why `report_utilization -cells` and not subtraction.** The predecessor
document records an area comparison that was 1,200 LUT out because two figures
from different commits were subtracted. Asking the tool for the sub-tree is one
command and cannot drift.

## 4. What was built, and the three decisions in it

`hw/fk33/gen_fk33_engine.py` (new) emits `hw/fk33/rtl/fk33_engine.vhd` (new,
generated, 1,903 lines), a board-facing wrapper around
`rtl/matvec_int4_desc_axi.vhd`. **No file under `rtl/` or `sim/` was touched.**

**Why a wrapper exists at all.** `matvec_int4_desc_axi` presents its 27
weight/scale masters as FLATTENED `std_logic_vector`s -- `m_araddr` is one
27x40-bit port -- and Vivado's block designer cannot see a flattened vector as
AXI, so it cannot be connected to `hbm/SAXI_nn`, which is an interface pin.
`rtl/hbm_tg_ip.vhd` solves the same problem for `hbm_tg`, and the port names
and widths here are copied from it deliberately: that shape has been
synthesised, placed, routed and RUN against this exact HBM IP configuration on
this exact card (30 masters, 288.0 GB/s,
`hw/fk33/results/hbmbw_30port_300mhz.txt`).

### 4.1 The thermal halt, and why it is applied where it is

`rtl/fk33_thermal.vhd`'s contract, verbatim from its port comment:

> `compute_halt` synchronous to `compute_clk`, active high, RESET VALUE '1'.
> Use it as `if compute_halt = '0' then <issue work> end if` ... Do NOT gate a
> clock with it and do NOT abandon an AXI burst that has already been accepted.

`matvec_int4_desc_axi` has no halt input and `rtl/` is not this track's file.
So the halt is applied at the one point in the interface where new work begins:
**the AXI-Lite write of GO** (register `0x08` bit 0), masked to '0' while
halted. A job already running is not disturbed and runs to completion, which is
what retires every burst it has issued. Nothing gates a clock; nothing touches
a reset.

`fk33_therm_0/compute_clk` moves from `xdma/axi_aclk` onto the engine's core
clock, because the contract says the halt is synchronous to `compute_clk` and
the datapath's clock is now a real thing rather than a stand-in. The canary
counter in that domain therefore now counts the ENGINE's clock, so
`THERM_CANARY` over JTAG answers "is the compute domain clocked and un-halted"
about the real datapath.

**A masked GO is RECORDED, not silently dropped.** `ENG_STAT` bit 1 is a sticky
"a GO was refused because the card was halted". A halt that swallows a command
without saying so is the silent-success family this project keeps finding, and
it costs one flip-flop to not have it.

### 4.2 The port assignment, and how it touches the open arena question

28 masters, one per SAXI port:

```
m00..m14  ->  SAXI_01..SAXI_15   (stack 0, 15 ports)
m15..m27  ->  SAXI_17..SAXI_29   (stack 1, 13 ports)
```

`SAXI_00`/`SAXI_16` stay with the host. `SAXI_30`/`SAXI_31` stay DISABLED as
the two spare engine ports `docs/2026-08-27_hbm-port-contention.md` budgets for
B and C.

**The split is forced, not chosen.** A stack offers at most 15 engine ports
after the host takes one, so no assignment of 28 masters fits in one stack.
TRACK HBM-PLACE already established the consequence
(`docs/debugging/2026-08-28_hbm-stack-boundary-straddle.md` section 3): under
the flat packed layout every one of a tensor's 27 sub-regions sits within a few
hundred MB of the others, i.e. in ONE stack, so at least 13 of the 28 masters
read cross-stack on every tensor. **The 27-lane arena layout is the answer and
it is a decision for Oren; it is NOT made here.**

What this build does is the only thing that keeps both options open: **every
engine master is given all 32 HBM_MEM segments**, i.e. the whole 8 GiB.
MEASURED, 896 assignments (28 x 32) in the address map read back from the tool.
Under the flat layout a master restricted to its own stack's 16 segments would
DECERR on more than half the tensors; an arena scheme would only ever REMOVE
segments from this. It costs nothing in the fabric because the engine connects
DIRECTLY to the HBM IP with no interconnect in the path.

### 4.3 The clocks

| | net | frequency | why |
|---|---|---|---|
| HBM AXI | `xdma/axi_aclk` | 250 MHz | the clock that ALREADY drives `SAXI_00`/`SAXI_16`. Using one clock for the whole HBM AXI side means this build asks no new question about mixed per-port clocks |
| core | `clk_wiz_0/clk_out3` | 200 MHz | a third MMCM output. Not a reuse of `clk_out2`, which is `HBM_REF_CLK_0/1` |

250/200 sits 2.8% and 13.3% below the OOC ceilings of 257.33 and 230.73 MHz.
Running the core AT the HBM clock would be 100% duty with zero margin, which
`docs/2026-08-28_can-27-read-masters-be-served.md` section 4.3 already
rejected.

`clk_out3`'s reference is `xdma/axi_aclk`, so the core clock stops when the
PCIe link drops. That is correct: with no host there is no job, and the thermal
guard is on the free-running aux domain and does not stop with it.

The engine's AXI-Lite slave is in the CORE domain (`s_axi_aclk` IS the core
clock) while `pcie2axil` is in xdma's, so a dedicated `smartconnect` with
`NUM_CLKS 2` bridges them -- the shape `build_fk33_hbmbw.tcl:334-341` used for
`axil2tg`, which built, routed and ran.

## 5. The evidence, raw

Board-free gate, MEASURED, `--bd-only`:

```
FK33_ENG ASSOCIATED_BUSIF eng/core_clk = s_axi:s_axix
FK33_ENG ASSOCIATED_BUSIF eng/hbm_aclk = m00_axi:...:m27_axi
FK33_ENG SAXI_30 = false (must be false: spare for B and C)
FK33_ENG SAXI_31 = false (must be false: spare for B and C)
FK33_ENG portcheck bad=0 (must be 0)
FK33_ENG masters=28 halt=1
FK33_BD_VALIDATE OK
--- unmatched constraints (should be ZERO now; any is a real error) ---
0
--- XDC commands Vivado silently skipped (must be ZERO) ---
0
--- address-overlap warnings AFTER the exclude sequence (must be zero) ---
0
```

`portcheck bad=0` is 28 x 3 checks: every enabled port's `USER_SAXI_nn` reads
back `true`, every `AXI_nn_ACLK` and `AXI_nn_ARESET_N` has a driver, and every
`eng/mNN_axi` interface has a net.

The placer's warning, 16 minutes before the router confirmed it:

```
WARNING: [Place 46-14] The placer has determined that this design is highly
congested and may have difficulty routing.
INFO: [Place 30-612] Post-Placement Estimated Congestion
 | Direction | Global | Long    | Short |
 |      North|  16x16 |   64x64 | 32x32 |
 |      South|  64x64 | 128x128 | 64x64 |
 |       East|  64x64 | 128x128 | 64x64 |
 |       West|  64x64 |   64x64 | 64x64 |
```

The router, six attempts:

```
WARNING: [Route 35-447] Congestion is preventing the router from routing all
nets.  The router will prioritize the successful completion of routing all
nets over timing optimizations.
Phase 3.4  Initial Net Routing
Phase 3.6  Initial Net Routing
Phase 3.8  Initial Net Routing
Phase 3.10 Initial Net Routing
ERROR: [Route 35-3] Design is not routable as its global congestion level is 7.
route_design: Time (s): cpu = 00:38:09 ; elapsed = 00:07:47
```

Control sets, which is the number most likely to be behind the congestion:

```
Total control sets                                          3887
   Minimum number of control sets                           3360
   Addition due to synthesis replication                     342
   Addition due to physical synthesis replication            185
Unused register locations in slices containing registers    5153
```

Clock spread, from `impl_1/clockInfo.txt`:

```
Clock 1: bd_i/clk_wiz_0/inst/clk_out3
	Clock source type: BUFGCE
	Clock source region: X4Y0
	initial rect ((0, 0), (7, 3))
```

i.e. the engine's core clock spans every clock region on the die.

Wall clock and memory, MEASURED by sampling `/proc/<pid>/status` for every
process whose cwd is the build root, every 10 s:

| | |
|---|---|
| total wall time | 07:41 (06:56:30 to 07:47:34, plus the gates) |
| `synth_design` | 11 min |
| `opt_design` | 3:26 |
| `place_design` | 16:33 |
| `phys_opt_design` | 8 min |
| `route_design` | 7:47, then terminated |
| **peak resident, all processes** | **22.81 GB** |
| single largest process | 11.30 GB (`route_design`) |

## 6. Measured and REJECTED -- do not retry

### 6.1 A COMBINATIONAL halt mask. It does not work, and simulation said so.

The first version derived the mask combinationally from `s_axi_awvalid`,
`s_axi_wvalid` and `s_axi_awaddr`, on the reasoning that the engine's AXI-Lite
slave requires address and data in the SAME cycle
(`rtl/matvec_int4_desc_axi.vhd:862`), so the target register is known when the
data is presented. That reasoning is correct and the implementation was still
wrong: the slave ARMS on that condition and performs the register write **one
cycle later**, reading `s_axi_wdata` at that later edge (`:868-882`). A master
that has dropped AWVALID by then takes the mask away with it, and the unmasked
GO reaches the engine.

MEASURED, before the fix, with the guard asserting halt:

```
ok   T3 X_ADDR after 2 writes
FAIL T4 STATUS busy stays 0 while halted got=1 want=0
ok   T5 GO_BLOCKED set
```

`T5` passing while `T4` failed is the diagnostic: the wrapper SAW the GO and
recorded it, and the engine started anyway.

Fixed by mirroring the engine's own arm condition and latching the CTRL decode,
then masking at the execute cycle. After:

```
ok T1 ENG_ID   ok T1b MV4I ID   ok T2 X_ADDR   ok T3 X_ADDR after 2 writes
ok T4 STATUS busy stays 0 while halted
ok T5 GO_BLOCKED set
ok T6 GO_BLOCKED cleared
ok T7 busy after GO with halt clear
ok T8 descriptor master issued AR
tb_fk33_engine: 8 checks, 0 failures
```

**Teeth-checked.** The same bench with `HALT_AT_GO=false` -- the halt
deasserted, everything else identical -- must see the opposite:

```
ok T4-neg STATUS busy is 1 when NOT halted
ok T5-neg GO_BLOCKED clear
```

So T4 and T5 discriminate; they are not checks that pass for any design.

**Generalise it:** a mask on an AXI-Lite write must be latched at the cycle the
SLAVE latches its address, not at the cycle the master presents it. Reading the
slave's handshake code is the only way to know which that is.

### 6.2 `get_timing_paths -from <clkA> -to <clkB>` as a CDC check on this design

The aux domain's constraint verification uses exactly this, and it is the right
check: an asynchronous clock group does not stop Vivado from ENUMERATING a
crossing path, it reports it with an empty slack, so "is any crossing path
still ANALYSED" is the real question.

**It does not terminate here.** MEASURED: `get_timing_paths -from <core> -to
<axi> -max_paths 8` on the post-`phys_opt` checkpoint ran for over 20 minutes
without returning and was killed. The aux check is cheap for the opposite
reason -- that domain is a handful of single-bit crossings -- while this one is
28 gray-pointer FIFOs plus 28 four-phase clear handshakes.

The build script now checks only that both clock lookups resolve, which is
what decides whether the XDC's `set_clock_groups` matched anything (an empty
group is a WARNING, not an error), and writes `report_clock_interaction` to a
file for a human. **That is weaker and it is labelled as weaker in the script.**
A check that hangs a fifty-minute build is worse than a weaker check that runs.

`report_timing_summary` on the same checkpoint also did not return within 15
minutes, which is why **this document has no per-clock WNS breakdown.** See
section 9.

### 6.3 `launch_runs synth_1 -jobs 8`

Reduced to 4. `-jobs` on SYNTHESIS launches concurrent out-of-context IP runs,
each its own Vivado process, on a 31 GB box that has OOM-killed unrelated
services before. Even at 4 the sum peaked at 22.81 GB, because the BD's own
IP-synthesis helper launches its own fan-out that `-jobs` does not govern:
MEASURED, ~8 concurrent processes at 0.88 to 1.03 GB each on top of the main
run. Implementation is left at 8, where `-jobs` is threads inside one process
and does not multiply the footprint.

A guard script was armed for the duration: it sums RSS over every process whose
cwd is under the build root and kills that set, and only that set, above 25 GB
or when the box's `MemAvailable` falls under 2 GB. It never fired.

### 6.4 `0x00011000` for the engine's register base

`fk33_scratch` is **8 KB** at `0x10000`, so it occupies `0x10000..0x11FFF`.
MEASURED, the `--bd-only` gate refused it in 90 seconds:

```
ERROR: [BD 41-1075] Cannot assign slave segment '/eng/s_axi/reg0' into address
space '/xdma/M_AXI_LITE' at address '0x0001_1000 [ 4K ]'.  The proposed address
overlaps with slave segment '/fk33_scratch/S_AXI/Mem0' ... at '0x0001_0000 [ 8K ]'
```

Now `0x12000` (engine) and `0x13000` (activation writer).

### 6.5 `%02d` for a port index in generated Tcl

Tcl reads a leading-zero integer literal as OCTAL. `{m07 08}` makes
`format "hbm/SAXI_%02d/..." $sx` fail with `expected integer but got "08"`,
**after 7 of the 28 masters have already been mapped**, so the failure looks
like a problem with master 7 rather than with the notation. The zero padding
belongs in the Tcl-side format string, applied to an integer, and nowhere else.

## 7. Measurement traps hit

- **Automatic top detection picks the engine over `bd_wrapper`, synthesis
  SUCCEEDS on the wrong design, and the only symptom is in the placer.**
  `add_files` on the engine RTL puts a second root module in the fileset and
  `update_compile_order` re-runs top detection. MEASURED:

  ```
  ERROR: [Place 30-415] IO Placement failed due to overutilization.
                        This design contains 18348 I/O ports
  ```

  because the engine's 28 AXI masters became top-level pins. `make_wrapper
  -top` sets the top once; it does not defend it. **`gen_hbmbw.py:360` wrote
  this trap down in full, including the "6009 I/O ports" symptom, and this
  build walked into it anyway** -- the note was in a generator for a different
  bitstream and nothing carried it across. `set_property top bd_wrapper` plus a
  read-back that errors is now in `gen_pcieep.py`, and `pcieep_build.sh` greps
  for `FK33_TOP`.

- **A module-reference cell with TWO clock ports gets no clock/interface
  association, and every inferred AXI interface silently defaults to 100 MHz.**
  `hbm_tg_ip` has ONE clock port, which is why `build_fk33_hbmbw.tcl` has no
  line like this and why its absence was easy to miss. MEASURED: 30 separate
  `BD 41-237 FREQ_HZ does not match` errors at HDL generation, not one of which
  names the missing association as the cause. Fixed with
  `CONFIG.ASSOCIATED_BUSIF` on both clock pins, read back and errored on,
  because Vivado silently ignores `set_property` on a CONFIG name an object
  does not have.

- **A process monitor that matches on the command line sees nothing.** The
  first RSS sampler filtered `ps` output for the build root; Vivado's command
  line does not contain it (it runs with cwd = the build root), so the monitor
  reported a peak of 0 through the entire first attempt. Match on
  `/proc/<pid>/cwd`.

- **`pkill -f` and `pgrep -f` on a pattern that appears in your own command
  line kill the shell.** CLAUDE.md says so; it happened anyway, once, and cost
  a relaunch. Iterate `/proc` and `kill` explicit pids.

- **The clock object for `xdma/axi_aclk` is named after an unrelated cell.**
  MEASURED: `get_clocks -of_objects [get_pins bd_i/eng/hbm_aclk]` returns
  `fk33_dmabram_BRAM_PORTA_CLK`, period 4.000 ns. The name is Vivado's, from
  whichever load it first attached the generated clock to; the period is the
  thing to read.

## 8. What this does NOT establish

- **Nothing about hardware.** No bitstream was produced and nothing was loaded.
  Every number here is a tool report.
- **Whether the design routes at all**, with a floorplan, with a different
  placer directive, at a lower clock, or with the engine constrained to a
  pblock. Only `Performance_RefinePlacement` at 250/200 MHz was tried, once.
- **Per-clock WNS.** Both `report_timing_summary` and the per-clock path query
  failed to terminate on this checkpoint (6.2). The three design-wide WNS
  figures in section 2 are what the implementation log reported on its own.
- **Which clock the critical path belongs to**, and therefore whether the
  duty identity is threatened. Follows from the above.
- **That the CDC clock group was APPLIED.** It was verified to MATCH (both
  lookups resolve) and never verified to have taken effect, for the reason in
  6.2. If it did not apply, the reported WNS figures are pessimistic rather
  than optimistic -- the tool would be timing a crossing the RTL handles.
- **Whether the activation writer or the halt mask behave under a real
  SmartConnect master.** They were exercised by a scratch bench driving the
  AXI-Lite handshake directly.
- **Anything about the arena layout.** Every master sees all 8 GiB, which makes
  the flat layout work and says nothing about the cross-stack traffic TRACK
  HBM-PLACE measured.
- **HBM read latency**, still never measured on this card, still what actually
  sizes `MAXOUT` and `FIFO_DEPTH`.

## 9. Open, not yet answered

1. **What is congested?** `report_design_analysis -congestion` was launched
   three times and never completed within the time available. Until it does,
   the 128x128 long-congestion regions south and east are the only localisation
   there is, and the plausible sources -- the 6,912-bit `w_data` merge into the
   DSP array, 3,887 control sets, 28 x 256-bit R channels landing on HBM BLI
   interfaces spread along one edge of the die -- are ESTIMATES, not findings.
2. **Does a floorplan fix it?** The HBM BLI interfaces are on the die edge and
   the engine's core clock currently spans all 8x4 clock regions. Constraining
   the engine to the regions nearest the HBM ports is the obvious first
   experiment and has not been run.
3. **Does it route at a lower clock?** Congestion is not directly a frequency
   problem, but `phys_opt` replication driven by timing pressure adds control
   sets, and 185 of the 3,887 came from physical synthesis. A 200/160 MHz build
   would separate the two.
4. **Per-clock WNS**, once a cheap way to get it on this design is found.
5. **`SAXI_30`/`SAXI_31`.** Left off. B and C are not in this bitstream, so
   the 30-port question the bandwidth measurement answered is still not the
   question this build asks.

## 10. Corrections

None yet. Append here with a date; mark superseded claims withdrawn in place
rather than deleting them.
