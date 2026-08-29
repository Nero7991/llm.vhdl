# Does the regenerated FK33 build script reproduce PBLOCK's result from sources?

**Date:** 2026-08-29
**Build:** `hw/fk33/pcieep_build.sh`, full, from sources, no checkpoint.
Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, 250 MHz HBM AXI / 200 MHz core,
`ROWS_IF = 48`. Repo at `f0645b8` (one worklog commit past PBLOCK's `ed1ffe2`).
**Track:** BUILD-E2E. No RTL was changed. No hardware was touched at any point.

---

## 1. The question, verbatim

> **THE TASK: close PBLOCK's own top NOT-verified item**
>
> Its words: **"The regenerated build script has not been run end to end -- the
> bitstream came from a checkpoint flow, so `used_in_synthesis false` and the
> new `FK33_PBLK` gate are unproven in a project run."**
>
> 1. Run the FK33 build end to end from the regenerated script, from sources,
>    no checkpoint shortcuts.
> 2. Establish whether it reproduces PBLOCK's numbers. Report routed/unrouted
>    nets, WNS, TNS, WHS, THS, report_drc, and utilization, as raw tool output.
> 3. Specifically prove or disprove that `used_in_synthesis false` and the
>    `FK33_PBLK` gate behave correctly in a project run, since those are the two
>    named unknowns.
> 4. If it does NOT reproduce, that is the finding. Say exactly where it
>    diverges. Do not patch around it silently.

---

## 2. The answer, up front

**The build runs end to end from the script, and it reproduces the result.**
55 min 36 s wall, `rc=0`, `FK33_BUILD_DONE` emitted exactly once:

| | PBLOCK `DX`, checkpoint flow | **this run, project flow** |
|---|---|---|
| routable nets | 282,090 | **283,868** |
| fully routed | 282,090 | **283,868** |
| nets with routing errors | **0** | **0** |
| WNS / TNS | +0.045 / 0.000 | **+0.069 / 0.000** |
| setup failing endpoints | 0 of 576,171 | **0 of 575,895** |
| WHS / THS | +0.010 / 0.000 | **+0.009 / 0.000** |
| hold failing endpoints | 0 of 576,123 | **0 of 575,847** |
| WPWS | 0.000 | **0.000** |
| `report_drc` | 0 error, 0 critical | **0 error, 0 critical** (1,595 warnings) |
| CLB LUTs | 169,818 (38.62%) | **171,458 (39.00%)** |
| CLB Registers | 124,971 (14.21%) | **125,006 (14.22%)** |
| BRAM tile | 261.5 (38.91%) | **261.5 (38.91%)** |
| DSP | 1,585 (55.03%) | **1,585 (55.03%)** |
| URAM | 0 | **0** |
| bitstream | 22,568,402 bytes | **20,654,242 bytes** |

**It is a reproduction, not a repeat, and the difference is REAL and
identified.** PBLOCK started from TRACK SHELL's `bd_wrapper_opt.dcp`, synthesised
at `928ad9f`. Two of this build's RTL inputs have changed since: `f1c4b5b` added
`ASYNC_REG` attributes to **`rtl/async_fifo.vhd`** (8 synchroniser signals) and
**`rtl/axi_rd_port.vhd`** (6 more), instantiated once per HBM read master.
`ASYNC_REG` is synthesis-affecting: it stops the tools splitting or absorbing a
2FF pair. So **the netlists are not the same netlist**, +1,640 LUTs and
+1,778 routable nets is the size of that, and no claim of bit-identity is
available or was ever possible. Everything that should be invariant is:
DSP 1,585, BRAM 261.5, URAM 0, and the `report_drc` rule table identical rule for
rule (DPIP-2 1536, DPOP-4 49, PDCN-1569 3, REQP-1774 2, REQP-1852 1, REQP-1857 1,
REQP-1858 2, RTSTAT-10 1, total 1,595, every one Warning).

**The two named unknowns, both settled, and one of them settled against its own
documentation:**

- **`used_in_synthesis false` works, and its stated REASON was wrong.** MEASURED
  in the project run: `fk33_pblock.xdc` appears **0 times** in
  `synth_1/runme.log`, with `Parsing XDC File [.../fk33_pcieep.xdc]` at line 422
  of that same log as the control that a user XDC *is* read. Then the teeth
  check, which is the part that had never been done: the property's **default is
  1**, so the line does real work -- but running the control, the same XDC with
  the property left at its default, **synthesis COMPLETED**
  (`PROGRESS=100% STATUS=synth_design Complete!`). It does **not** error. The
  sole consequence is
  `WARNING: [Vivado 12-180] No cells matched 'bd_i/eng/inst/eng/dut/core'`.
  `add_cells_to_pblock` does not error on an empty object. The claim in
  `fk33_pblock.xdc`'s header, in `gen_pcieep.py`'s comment and in the build
  script's own error string -- "would error out synthesis" -- is false, and all
  three are corrected in this commit. **Keep the property**: an unmatched
  constraint leaving an empty `pb_core` behind is exactly the silent class this
  build's other checks exist for. It buys a clean log, not a rescued build.

- **The `FK33_PBLK` gate fires correctly, and it has teeth on all three arms.**
  It passed in the run (`FK33_PBLK pblocks in the implemented design: pb_core`,
  `FK33_PBLK pb_core CLOCKREGION_X0Y0:CLOCKREGION_X6Y3`), and passing is not
  evidence. Four mutations against the routed checkpoint the run produced:
  wrong expected range **FIRED**, absent pblock name **FIRED**, `pblock_bd_i`
  injected back into the design **FIRED**, and the restore control **PASSED**
  again. **Every mutation bit. None failed to bite.**

**Two defects found by running the script, which is the only way they could have
been found:**

1. **`pcieep_build.sh` raised a false alarm on a healthy build.** It printed
   `^^ AN ENGINE PORT IS NOT ENABLED, NOT DRIVEN OR NOT CONNECTED`. The engine is
   fine. `FK33_ENG portcheck bad=` is emitted from **inside** the
   `if {[info exists ::env(FK33_STOP_AFTER_BD)]}` block, so a full build never
   prints it and the alarm's `|| echo` arm is reached by **absence**. MEASURED
   both ways on the same tree: the full build alarmed, and `--bd-only` printed
   `FK33_ENG portcheck bad=0 (must be 0)`. Fixed and teeth-checked.
2. **The `used_in_synthesis` rationale above.** Three files said something the
   tool does not do.

**Nothing here says the design computes anything.** It routes, it meets every
timing constraint it has, it passes DRC, and no one has simulated this netlist at
this geometry or loaded this bitstream.

---

## 3. The procedure

One command, plus three cheap follow-ups that the run itself made possible. Every
Vivado session ran alone, inside its own memory-capped transient systemd unit,
and a non-zero RSS was verified before each long step. **No hardware was
touched**: synthesis, implementation, `report_*` and `write_bitstream` only.

| # | step | what it isolates |
|---|---|---|
| 0 | re-run all three generators, compare md5 against the committed files | **that the committed script IS what the generator emits.** If this failed, nothing downstream would mean anything |
| 1 | `./pcieep_build.sh` full, from sources | the question |
| 2 | grep `synth_1/runme.log` for both user XDC files | **`used_in_synthesis false` in the real run**, with `fk33_pcieep.xdc` as the control |
| 3 | teeth check: the same XDC at the property's default, on a trivial top | **whether the property is load-bearing, and for the stated reason.** This is the one that overturned the documentation |
| 4 | teeth check: 4 mutations of `FK33_PBLK` against the routed checkpoint | **whether the gate can fail**, including a restore control |
| 5 | `./pcieep_build.sh --bd-only` | whether the port alarm was a real fault or an absent line |

Three controls worth naming, because without them the corresponding measurement
is worthless:

- **`fk33_pcieep.xdc` is the control for `fk33_pblock.xdc`.** "0 occurrences in
  the synthesis log" is equally consistent with "the property worked" and with
  "no user XDC is read during synthesis at all". The second is refuted by line
  422.
- **`M4_restored` is the control for `M3_bd_i_reintroduced`.** "The gate fired
  after I injected a pblock" is consistent with the injection having broken the
  gate. M4 removes the injection and the gate passes again.
- **`--bd-only` is the control for the port alarm.** "The alarm fired" is
  consistent with a real port fault. `bad=0` on the identical sources is not.

**Step 0 is not ceremony.** Had the generators not reproduced the committed
files byte for byte, "the build script works" would have been a claim about a
script nobody has.

---

## 4. The evidence

### 4.1 The generators reproduce the committed files exactly (MEASURED)

`python3 gen_i2cprobe.py && python3 gen_fk33_engine.py && python3 gen_pcieep.py`,
md5 before and after, in a tree with no tracked modifications under `hw/fk33`:

```
f5b9bd099dade5501eb036603a3ec315  hw/fk33/build_fk33_pcieep.tcl
e96b4ea92c76af98ba79186b34e8bf53  hw/fk33/fk33_pcieep.xdc
41158a3df56872dfe04e4f80c748fd58  hw/fk33/fk33_pblock.xdc
6c97c2035561ae68941cc7ae538050b0  hw/fk33/build_fk33_i2cprobe.tcl
47d5843fccb693e11cfc7eb6b4057ea3  hw/fk33/fk33_i2cprobe.xdc
bf6aee7939e59415eaf34510060c8418  hw/fk33/rtl/fk33_engine.vhd
```

All six identical before and after; `git status` reported nothing modified.
`grep -c 'REMOVED, see fk33_pblock.xdc' fk33_pcieep.xdc` = **13**, and live
(uncommented) `pblock_bd_i` lines = **0**.

### 4.2 The run completed, and the sentinel says so (MEASURED)

```
==== E2E_BUILD_BEGIN 2026-08-29T14:51:56-06:00 ====
==== E2E_BUILD_END   2026-08-29T15:47:32-06:00 rc=0 ====
E2E_INPUTS_STABLE yes -- no input file changed under the build
E2E_FK33_BUILD_DONE_count=1
E2E_LOG_LAST3:
FK33_BUILD_DONE
E2E_CGROUP_MEMORY_PEAK_BYTES 26844352512
E2E_WRAPPER_DONE rc=0 2026-08-29T15:47:32-06:00
```

`FK33_BUILD_DONE` is the last line of the emitted Tcl, so it can only be reached
if every post-implementation check ran. PBLOCK lost a whole session to a Vivado
run that printed success and then died on a Tcl error after `route_design`; that
is the failure mode this sentinel exists for and it did not occur.

The 21 md5-summed inputs were re-hashed after the build and none had changed, so
no concurrent track edited a source under the run.

### 4.3 `used_in_synthesis false`, in the project run and as a control (MEASURED)

In the run. `grep -c fk33_pblock synth_1/runme.log`:

```
0
```

and the control, from the same log, that a user XDC is read at all:

```
422:Parsing XDC File [/home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pcieep.xdc]
423:Finished Parsing XDC File [/home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pcieep.xdc]
```

`grep -i pblock synth_1/runme.log` is empty, and synthesis reported 0 `ERROR` and
0 `CRITICAL WARNING`.

**The teeth check, which is the finding.** `results/build_e2e_2026-08-29/teeth_uis.tcl`:
a throwaway project on the same part with a one-line Verilog top, the real
`fk33_pblock.xdc` added to `constrs_1`, synthesised twice.

```
TEETH_UIS default used_in_synthesis   = 1
TEETH_UIS default used_in_implementation = 1
TEETH_UIS === control: synthesising WITH the pblock XDC in synthesis ===
TEETH_UIS control PROGRESS=100% STATUS=synth_design Complete!
TEETH_UIS control| WARNING: [Vivado 12-180] No cells matched 'bd_i/eng/inst/eng/dut/core'. [/home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pblock.xdc:73]
TEETH_UIS === treatment: used_in_synthesis false, same design ===
TEETH_UIS treatment used_in_synthesis = 0
TEETH_UIS treatment PROGRESS=100% STATUS=synth_design Complete!
TEETH_UIS_DONE
```

Two things follow and they point in opposite directions. **The default is 1**, so
the `set_property` is not decoration -- without it the file *is* read during
synthesis. **And synthesis completes anyway**, with a warning, so the documented
justification ("`add_cells_to_pblock` errors on an empty object", "would error out
synthesis") is wrong.

### 4.4 The `FK33_PBLK` gate, in the run and under mutation (MEASURED)

From the run, on the implemented design:

```
FK33_PBLK fk33_pblock.xdc added, implementation only
FK33_PBLK pblocks in the implemented design: pb_core
FK33_PBLK pb_core CLOCKREGION_X0Y0:CLOCKREGION_X6Y3
```

`pblocks = pb_core` is the whole list, so `pblock_bd_i` is absent. Independently,
`grep -c "Place 30-640" impl_1/runme.log` = **0**: the nine oversubscription
warnings that were the whole story of the unroutable build do not occur.

The mutations, against `impl_1/bd_wrapper_routed.dcp` from this run:

```
TEETH_PBLK pblocks present: pb_core
TEETH_PBLK M0_as_built          expect=PASSED got=PASSED OK
TEETH_PBLK M0_as_built detail: pblocks=pb_core pb_core=CLOCKREGION_X0Y0:CLOCKREGION_X6Y3
TEETH_PBLK M1_wrong_range       expect=FIRED  got=FIRED  OK
TEETH_PBLK M1_wrong_range detail: FK33_PBLK FAIL: pb_core range is 'CLOCKREGION_X0Y0:CLOCKREGION_X6Y3', not CLOCKREGION_X0Y0:CLOCKREGION_X5Y3.
TEETH_PBLK M2_missing_pblock    expect=FIRED  got=FIRED  OK
TEETH_PBLK M2_missing_pblock detail: FK33_PBLK FAIL: pb_core_typo is not in the implemented design.
TEETH_PBLK M3_bd_i_reintroduced expect=FIRED  got=FIRED  OK
TEETH_PBLK M3_bd_i_reintroduced detail: FK33_PBLK FAIL: pblock_bd_i is in the implemented design.
TEETH_PBLK after cleanup: pb_core
TEETH_PBLK M4_restored          expect=PASSED got=PASSED OK
TEETH_PBLK_DONE
```

**Every mutation bit, and there is no "did not bite" row to report.** That is the
strongest statement available about this gate and it is a narrow one: it says the
three assertions are real comparisons against a design read back from the tool.
It says nothing about whether those three assertions are the right three.

### 4.5 Route status (MEASURED, `bd_wrapper_route_status.rpt`)

```
Design Route Status
                                               :      # nets :
   ------------------------------------------- : ----------- :
   # of logical nets.......................... :     1739169 :
       # of nets not needing routing.......... :     1455301 :
           # of internally routed nets........ :     1249589 :
           # of nets with no loads............ :      205712 :
       # of routable nets..................... :      283868 :
           # of fully routed nets............. :      283868 :
       # of nets with routing errors.......... :           0 :
   ------------------------------------------- : ----------- :
```

### 4.6 Timing (MEASURED, `bd_wrapper_timing_summary_routed.rpt`)

```
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
    -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
      0.069        0.000                      0               575895        0.009        0.000                      0               575847        0.000        0.000                       0                148744
```

`All user specified timing constraints are met.` (line 158 of that report), and
from the build script's own read-back of the engine's pins rather than the
clk_wiz request:

```
FK33_ENGI clock clk_out3_bd_clk_wiz_0_0        period 5.000 ns (200.00 MHz)
FK33_ENGI clock fk33_dmabram_BRAM_PORTA_CLK    period 4.000 ns (250.00 MHz)
FK33_TIMING WNS=0.069 ns  WHS=0.009 ns
```

So `duty = f_core / f_axi = 0.80` is achieved, not assumed, in a from-sources
build.

**Bus skew, which PBLOCK listed as reported and never read.** It is read now.
From `bd_wrapper_bus_skew_routed.rpt`: **31 constraints, 31 MET, 0 VIOLATED,
worst slack +2.718 ns.** `report_timing_summary` does not cover bus skew
(`[Timing 38-436]`), so this is a separate result and not part of the
"0 failing endpoints" above.

### 4.7 DRC (MEASURED, `bd_wrapper_drc_routed.rpt`)

```
             Violations found: 1595
+-----------+----------+--------------------------------------------+------------+
| Rule      | Severity | Description                                | Violations |
+-----------+----------+--------------------------------------------+------------+
| DPIP-2    | Warning  | Input pipelining                           | 1536       |
| DPOP-4    | Warning  | MREG Output pipelining                     | 49         |
| PDCN-1569 | Warning  | LUT equation term check                    | 3          |
| REQP-1774 | Warning  | RAMB36E2_WRITE_WIDTH_A_18_doesnt_use_WEA32 | 2          |
| REQP-1852 | Warning  | BUFGCE_cascade_from_clock_buf              | 1          |
| REQP-1857 | Warning  | RAMB18E2_writefirst_collision_advisory     | 1          |
| REQP-1858 | Warning  | RAMB36E2_writefirst_collision_advisory     | 2          |
| RTSTAT-10 | Warning  | No routable loads                          | 1          |
+-----------+----------+--------------------------------------------+------------+
```

Severity tally over the whole report: **1595 Warning, 0 Critical Warning,
0 Error.** This table is **identical, rule for rule and count for count**, to
PBLOCK's `DX_drc_routed.rpt`. Given that the netlists differ (section 4.9), that
is a stronger agreement than the LUT count.

### 4.8 Utilization (MEASURED, `report_utilization` on the implemented design)

```
| CLB LUTs                   | 171458 |     0 |          0 |    439680 | 39.00 |
| CLB Registers              | 125006 |     0 |          0 |    879360 | 14.22 |
| CARRY8                     |   6435 |     0 |          0 |     54960 | 11.71 |
| LUT as Logic               | 160083 |     0 |          0 |    439680 | 36.41 |
| LUT as Memory              |  11375 |     0 |          0 |    205440 |  5.54 |
| Block RAM Tile             |  261.5 |     0 |          0 |       672 | 38.91 |
| URAM                       |      0 |     0 |          0 |       320 |  0.00 |
| DSPs                       |   1585 |     0 |          0 |      2880 | 55.03 |
```

The engine alone, `report_utilization -cells [get_cells bd_i/eng]`, against the
out-of-context ceilings the build script's own comment records
(LUT 134,534, FF 64,067, DSP 1,585, BRAM36 192.5, both at VCCINT 0.717 V):

```
| CLB LUTs          | 131132 |  29.82 |
| CLB Registers     |  63720 |   7.25 |
| CARRY8            |   6015 |  10.94 |
| Block RAM Tile    |  192.5 |  28.65 |
| DSPs              |   1585 |  55.03 |
```

Inside `pb_core`, `report_utilization -pblocks`:

```
| CLB LUTs       | assigned 117257 | non-assigned 37780 | total 155035 | avail 388800 |
| DSPs           | assigned   1584 | non-assigned     1 | total   1585 | avail   2700 |
| Block RAM Tile | assigned   21.5 | non-assigned 203.5 | total   225  | avail    576 |
```

DERIVED: the core sits at **117,257 / 388,800 = 30.16% LUT** and
**1,584 / 2,700 = 58.67% DSP** inside its pblock, against PBLOCK's measured
30.49% and 58.67%. The `Non-Assigned` column is other cells that happen to be in
the region, not a leak; it is not an answer to "did the assigned cells land
inside" (see the trap PBLOCK recorded and section 6 here).

### 4.9 Where it diverges, and why (MEASURED + DERIVED)

`git log 928ad9f..HEAD` over the exact file list this build compiles:

```
ed1ffe2 fk33: the shell routes and closes timing, and the congestion was an inherited pblock
d570899 docs/debugging: the full gate run, and why its one red row is not this track's
f1c4b5b the weight path's CDC had no bench, and its full guard fired on backpressure
```

`git diff 928ad9f..HEAD --stat` restricted to that list:

```
 rtl/async_fifo.vhd  | 65 ++++++++++++++++++++++++++++++++++++++++++++++++++++-
 rtl/axi_rd_port.vhd | 15 +++++++++++++
```

Of which the synthesis-affecting part is `attribute async_reg ... is "TRUE"` on
`wp_g_s1/s2`, `rp_g_s1/s2`, `clr_r_s1/s2`, `clr_a_s1/s2` in `async_fifo` and
`run_s1/s2`, `rst_s1/s2`, `s_t1/s_t2` in `axi_rd_port`. The rest is an assertion
condition, which synthesis ignores.

DERIVED: `ASYNC_REG` prevents the tools from absorbing, retiming or splitting a
2FF synchroniser pair, and these modules are instantiated once per HBM read
master. That is the mechanism by which the netlist changed; **the exact
attribution of +1,640 LUTs to it was NOT measured**, because doing so needs a
control synthesis at `928ad9f` and that is a second full build.

**The bitstream size difference is not a divergence at all.**
`fk33_pcieep.xdc:127` sets `BITSTREAM.GENERAL.COMPRESS TRUE`, so the file length
is content-dependent. DERIVED from the header parse the build script already
does: 20,654,112 data bytes here against ~22,568,272 for PBLOCK's, i.e.
**324.0 ms** of configuration time at the nominal 127.5 MHz against ~354 ms.
Both are over the 200 ms budget, which is a known, separately-tracked problem and
not a finding of this track.

### 4.10 Congestion (MEASURED, `report_design_analysis -congestion`)

Placer's own table: **6 windows, worst level 6** (South Long), local LUT 63-80%,
`matvec_core` 75-87% of every window. Router initial congestion: **5 windows**,
worst **Global 6** (South, core 90%) and **Long 7** (South, core 73%). PBLOCK's
`DX` was 5 placer windows worst 6, and router South Global 6 / South Long 7.
Same shape, same owner, same worst levels.

The router did emit, once, during initial routing:

```
WARNING: [Route 35-447] Congestion is preventing the router from routing all nets.
The router will prioritize the successful completion of routing all nets over
timing optimizations.
```

It then routed all of them and met timing. `[Route 35-3]`, the error that
stopped every build before PBLOCK, did not occur.

### 4.11 The false alarm, both directions (MEASURED)

The full build's own report section printed:

```
--- subsystem A: ports enabled, clocked, reset and connected ---
FK33_ENG ASSOCIATED_BUSIF eng/core_clk = s_axi:s_axix
FK33_ENG ASSOCIATED_BUSIF eng/hbm_aclk = m00_axi:...:m27_axi
  ^^ AN ENGINE PORT IS NOT ENABLED, NOT DRIVEN OR NOT CONNECTED
```

`grep -c '^FK33_ENG portcheck bad=' build.log` on that log = **0**.
`./pcieep_build.sh --bd-only` on the identical sources:

```
FK33_ENG portcheck bad=0 (must be 0)
FK33_BD_ONLY_DONE
```

The fixed gate, extracted from `pcieep_build.sh` and run against three logs:

```
=== case full        : 0 portcheck line(s) ===
OUTPUT:   (portcheck is emitted only by an FK33_STOP_AFTER_BD run; run ./pcieep_build.sh --bd-only for it)
=== case bdonly      : 1 portcheck line(s) ===
OUTPUT: <none>
=== case mutant_bad3 : 1 portcheck line(s) ===
OUTPUT:   ^^ AN ENGINE PORT IS NOT ENABLED, NOT DRIVEN OR NOT CONNECTED
```

The mutant is the bd-only log with `bad=0` rewritten to `bad=3`. **It bites**, so
the fix removed the false positive without removing the alarm.

### 4.12 Everything else the script checks, in this run (MEASURED)

```
FK33_TOP bd_wrapper
FK33_PCIE_IDS vendor=10EE device=9034
FK33_LNKLED OK: LED 6 follows NOT(user_lnk_up)
FK33_AUX LNK user_lnk_up wired into the aux status word
FK33_AUXCLK clocks=sysref_clk / period=5.000 ns / analysed paths crossing the aux boundary: 0 (must be 0)
FK33_HUBCLK OK dbg_hub is on sysref_clk
FK33_THERMCLK OK the thermal guard runs on the free-running oscillator
FK33_THERM hbm/DRAM_0_STAT_TEMP connected  (and DRAM_1_STAT_TEMP, both CATTRIP)
FK33_SYSMONI INIT_50 = 0xBA51 -> 90.00 C   INIT_54 = 0xB2C0 -> 75.00 C
FK33_SYSMONI OT limit = 0xBFD0 -> 100.90 C ; OT automatic shutdown is ARMED
unmatched constraints (12-584)            : 0
XDC commands Vivado silently skipped      : 0
address-overlap warnings after the excludes: 0
GTYE4_CHANNEL 4, GTYE4_COMMON 1, PCIE4CE4 1
```

---

## 5. Measured and REJECTED -- do not retry

- **"`used_in_synthesis false` is what stops synthesis failing."** MEASURED
  (4.3): with the property at its default, synthesis **completes**, emitting
  `[Vivado 12-180] No cells matched`. `add_cells_to_pblock` does **not** error on
  an empty object. Do not restate the old rationale; it was in three files and
  all three are now corrected. The property is still correct and should stay.

- **Expecting the project run to reproduce PBLOCK's LUT count.** It cannot, and
  the reason is not the flow. `rtl/async_fifo.vhd` and `rtl/axi_rd_port.vhd`
  gained `ASYNC_REG` attributes in `f1c4b5b`, after the synthesis PBLOCK's
  checkpoint came from. Do not spend a run chasing the 1,640-LUT delta as if it
  were a flow difference; if it ever matters, the experiment is a control
  synthesis at `928ad9f`, and it is a full build.

- **Reading the bitstream size difference as a divergence.**
  `BITSTREAM.GENERAL.COMPRESS TRUE` makes the length content-dependent, so two
  different placements of the same design give two different sizes by
  construction. 20,654,242 against 22,568,402 says nothing about correctness.

- **A guard armed at 18.0 GB, which is what PBLOCK used and what this track was
  briefed to use.** MEASURED: this run's cgroup reached **25.0 GiB**. PBLOCK's
  8.62 GB peak was a checkpoint flow that skipped synthesis entirely; a
  from-sources run has a parallel out-of-context IP phase that PBLOCK never ran.
  An 18 GB cap would have killed this build about six minutes in.

- **`MemorySwapMax=0` together with a `MemoryHigh` the run will actually reach.**
  With no swap the cgroup cannot reclaim anonymous pages, so `MemoryHigh` stops
  being a throttle and becomes a stall. See section 6; this was my own error and
  I had to change it mid-run.

---

## 6. Measurement traps hit, including my own

- **My own, in this document's own bus-skew number.** I first computed "worst
  bus-skew slack" as the minimum last-numeric-field over
  `bd_wrapper_bus_skew_routed.rpt` and got **-5.958**, which reads as a violated
  constraint. It is not a slack at all: line 3771 of that report is
  `Reference Relative Delay:  -5.958ns`. The report interleaves per-path detail
  with per-constraint verdicts and a positional extraction cannot tell them
  apart. The correct form greps the verdict token, and gives 31 MET, 0 VIOLATED,
  worst +2.718. **A number that agrees with the answer you feared is exactly the
  one to re-derive before writing it down.**

- **My own, and it nearly cost the build.** I armed the guard as briefed and then
  tightened `MemoryHigh` from 25G to 20G while the cgroup was at 24 GiB, with
  `MemorySwapMax` still 0 and then 8G. The kernel pushed **8 GiB to swap within
  seconds** and hit the swap cap. `memory.events` stayed `max 0, oom_kill 0`, so
  nothing died, but the margin was mine to lose and I created it. The correct
  setting for a from-sources Vivado run on this box is a `MemoryHigh` above the
  parallel-IP peak with real swap headroom behind it, not a tight `MemoryHigh`
  with no reclaim path.

- **The reported peak is a lower bound, not the demand.** `memory.peak` came back
  as 26,844,352,512 bytes, and `MemoryHigh` was 26,843,545,600 at the time. The
  cgroup was **pinned at the watermark**, so 25.0 GiB is where I clipped it, not
  where it would have stopped. An unconstrained run may want more. Do not quote
  25 GiB as "what this build needs".

- **A grep that decides something must be reachable in the run being checked, not
  merely anchored.** `pcieep_build.sh` already documents the `^`-anchoring trap
  (Vivado echoes the sourced Tcl prefixed with `#`, so an unanchored grep matches
  the `puts` that would print the line). The port alarm was correctly anchored and
  still fired on every healthy full build, because the line it looks for is
  emitted only under `FK33_STOP_AFTER_BD`. **Anchoring fixes false matches;
  it does nothing about a condition reached by absence.**

- **`git status --porcelain -- hw/fk33` at the start showed only untracked files,
  and that did not stay true.** `hw/fk33/host/fk33_reload.sh` (15:53) and
  `hw/fk33/tcl/pcieep_jtag.tcl` (15:57) were modified during this session by
  something that is not this track, while the worklog assigns `hw/fk33/**` here.
  They are left alone and are NOT in this commit. A ownership snapshot taken once
  at dispatch is a snapshot, not a lease.

- **`report_utilization -pblocks` "Non-Assigned" is location, not assignment.**
  Recorded by PBLOCK and hit again here: `pb_core` shows 37,780 non-assigned LUTs
  and 203.5 non-assigned BRAM tiles inside its region. Those are other cells that
  happen to sit there. Neither column answers "did every assigned cell land
  inside".

- **A Vivado log's phase timings are not a cost model.** `place_design` took
  10 min 37 s elapsed against 31 min 27 s of CPU, on a box whose load average
  ranged 2.83 to 15.23 during the run. PBLOCK measured the same placement shape
  at 14 min and at 71 min on the same machine. Quote CPU time or quote nothing.

---

## 7. What was changed in the repo

- **`hw/fk33/pcieep_build.sh`** -- the unconditional port alarm becomes
  conditional on the line existing, with the measurement and the mechanism in a
  comment. Teeth-checked three ways (4.11).
- **`hw/fk33/fk33_pblock.xdc`** -- a dated CORRECTION block in the header. The
  superseded claim is quoted rather than deleted. Includes a note that the `:73`
  in the captured warning has since shifted, because adding the note moved it.
- **`hw/fk33/gen_pcieep.py`** -- the same correction in the comment above the
  `used_in_synthesis` block, and the `FK33_PBLK FAIL` error string now says what
  Vivado actually does.
- **`hw/fk33/build_fk33_pcieep.tcl`** -- regenerated. The diff is **one line**,
  that error string, on a path a passing build never takes. The build validated
  above is therefore still the build in the tree.
- **`hw/fk33/results/build_e2e_2026-08-29/`** -- every report quoted here, both
  teeth-check scripts, the wrapper, and the 15-second cgroup memory trace.

`hw/fk33/bit/` is gitignored, so the artefact is on disk only:
`impl_1/bd_wrapper.bit`, **20,654,242 bytes**, sha256
`8250f01906872b2e61923c717fab6d240bb2a883bd6408fdda13b5606d4e23b8`. It is **not**
copied over `hw/fk33/bit/fk33_pcieep_eng.bit` (sha256 `6b12b3c4...`), which stays
PBLOCK's. Two reasons: PBLOCK's is the one whose numbers the project has recorded
and reviewed, and choosing between them is a decision about which RTL revision to
put on silicon, not a build result.

---

## 8. Machine discipline

Every Vivado session ran in its own transient systemd unit
(`systemd-run --user --unit=... --collect`) with explicit `MemoryHigh`,
`MemoryMax` and `MemorySwapMax`, and **no two ran at once**. A 15-second poller
recorded `memory.current` and the load average throughout.

| session | what | wall | cgroup peak | rc |
|---|---|---|---|---|
| `fk33-e2e` | the full build, gates through `write_bitstream` | **55 min 36 s** | **25.0 GiB** (clipped, see section 6) | 0 |
| `fk33-teeth` | `FK33_PBLK` mutations on the routed checkpoint | ~5 min | not captured (unit collected) | 0 |
| `fk33-teethuis` | `used_in_synthesis` control + treatment | ~2 min | not captured | 0 |
| `fk33-bdonly` | `--bd-only`, for the port check | ~3 min | not captured | 0 |

`memory.events` at the last sample taken, which was **mid-run** at 14:57 during
the parallel-IP phase and not at the end (the unit was `--collect`, so it and its
cgroup files were gone by the time the build finished): `max 0, oom 0,
oom_kill 0, oom_group_kill 0`, with `high 162273` throttling events. So: no
hard-limit hit and nothing killed **up to that point**, and the build's own
`rc=0` plus the sentinel say nothing was killed after it either. The final
`memory.peak` reading, 26,844,352,512 bytes, IS authoritative -- the wrapper read
it from inside the unit before exiting.

Phase timings, from `impl_1/runme.log`, CPU first because it is the stable one:

```
opt_design        cpu 00:10:20   elapsed 00:03:09   peak 10267 MB
place_design      cpu 00:31:27   elapsed 00:10:37   peak 10281 MB
phys_opt_design   cpu 00:02:03   elapsed 00:00:22   peak 10281 MB
route_design      cpu 00:58:38   elapsed 00:19:50   peak 10605 MB
write_bitstream   cpu 00:02:55   elapsed 00:01:39   peak 10959 MB
```

Synthesis of the top was 19 s at 3,559 MB; the cost is the 35 out-of-context IP
runs launched at `-jobs 4`, which is where the 25 GiB goes and what makes a
from-sources build a different memory problem from PBLOCK's checkpoint flow.

`phys_opt_design` took **22 seconds** here against 7 min 48 s in TRACK SHELL's
unroutable build. That is the visible signature of placement already meeting
timing (post-placement WNS +0.103) rather than phys_opt having to rescue it.

---

## 9. NOT verified

1. **Nothing has verified what this bitstream computes.** It routes, meets
   timing, passes DRC, and was produced from a netlist nobody has simulated at
   this geometry. Structure is not values.
2. **The bitstream was never loaded and no hardware was touched.**
3. **This is not a bit-identical reproduction and cannot be** (4.9). The claim
   proved is "the script, from sources, produces a routed, timing-clean,
   DRC-clean design with the same resource shape and the same DRC rule table",
   not "the same netlist".
4. **The +1,640 LUT delta was attributed but not measured.** `ASYNC_REG` is the
   identified mechanism; a control synthesis at `928ad9f` was not run.
5. **The `FK33_PBLK` gate was shown to have teeth on the three things it
   checks.** Whether those are the right three is a separate question nobody has
   asked. In particular it does not check that cells actually landed inside
   `pb_core`; PBLOCK measured 0.49% outside on `ASX` and that measurement was not
   repeated here.
6. **The `used_in_synthesis` control ran on a trivial top, not on
   `bd_wrapper`.** That Vivado emits `12-180` and continues for an unmatched
   `get_cells` in a synthesis XDC is MEASURED there and DERIVED for the real
   design. The real design's synthesis was never run with the property left true.
7. **`report_power` and `report_methodology` ran and nobody read them.** Both are
   in `impl_1/`. The design is spread over the whole die rather than packed into
   the bottom quarter, on a card whose thermal guard is documented as absent in
   silicon.
8. **The 324 ms configuration time is over the 200 ms budget** and this track did
   nothing about it. It is a pre-existing, separately-tracked problem; the number
   moved because compression is content-dependent, not because anything improved.
9. **`[Route 35-447]` fired and was not investigated.** The router said
   congestion would make it prioritise routing over timing optimisation. It then
   met timing with +0.069 ns of margin. Whether that warning predicts a fragile
   result on a rerun is unknown; this build was run once.
10. **One run is not a distribution.** Placement and routing are not
    deterministic across tool invocations in general, and WNS +0.069 is 24 ps
    from PBLOCK's +0.045 and 69 ps from failing. Nothing here measures run-to-run
    spread.

---

## 10. Corrections to the dispatching brief

The brief said its numbers were copied from another track's report. Checked
against the artefacts:

- **All of PBLOCK's headline numbers are correct as quoted**: 282,090 of 282,090
  routed with 0 errors, WNS +0.045, TNS 0.000, 0 failing of 576,171, WHS +0.010,
  THS 0.000, `report_drc` 0 errors and 0 critical warnings, and the
  `fk33_pcieep.xdc:133-140` line range for the live `pblock_bd_i` block (the
  emitted file now carries 13 commented lines, 133-145, of which 141-145 were
  already commented upstream). Commit `ed1ffe2`, the write-up path and the
  evidence directory all exist as stated.
- **"PBLOCK armed a guard at 18.0 GB and peaked at 8.62 GB" is correct, and
  wrong to carry forward.** Those figures are from a flow that starts at
  `opt.dcp`. This run peaked at 25.0 GiB and would have been killed by an 18 GB
  cap. The brief's machine-cost paragraph should not be reused verbatim for a
  from-sources build.
- **`MemorySwapMax=0`, as briefed, is unsafe for this build** for the reason in
  section 6, and I did not follow it. Recorded because the brief will be reused.

---

## 11. Corrections

*(Appended in place. Nothing above is deleted.)*
