# report_cdc catches every synchroniser cut and is blind to the gray code

**Date:** 2026-08-29
**Track:** CDC-STATIC
**Tooling:** Vivado 2023.2 (lin64, build 4029153), `xcvu33p-fsvh2104-2L-e`,
out-of-context synthesis only -- no place, no route, **no hardware**.
GHDL 1.0.0 mcode for the simulation half.
**Files added:** `sim/ooc_cdc.tcl`, `sim/run_ooc_cdc.sh`, `sim/cdc_teeth.sh`,
`sim/tb_axi_rd_port_dual.vhd`, `sim/mutate_axi_rd_port_dual.sh`
**Files changed:** `rtl/async_fifo.vhd` and `rtl/axi_rd_port.vhd` (ASYNC_REG,
see section 2.2), `sim/regress.sh` (one row, its stop-time, BASELINE_PASS
92 -> 93)

---

## 1. The question, verbatim

> TRACK CDC-BENCH just landed `f1c4b5b` ... It found a real defect and then
> stated, precisely, the limit of what any simulation can do here:
>
> > **No functional bench can test the gray coding.** `G1` replaces **both**
> > `bin2gray` and `gray2bin` with the identity -- binary pointers straight
> > across the CDC -- and **survives every one of the eight clock ratios**.
> > `G2` mutates only the decoder and dies instantly, which proves the bench
> > does watch the pointers. Same for `G3`/`G4`/`C6` (2FF synchroniser reduced
> > to 1FF). **Closing these needs Vivado `report_cdc`, `ASYNC_REG` and
> > asynchronous clock groups -- not simulation.**
>
> **Part 1 (priority): static CDC verification for what simulation cannot
> reach.** ... **Teeth are mandatory and are the deliverable.** Re-run your
> analysis against CDC-BENCH's own mutations -- `G1`, `G3`/`G4`/`C6` -- and show
> the static flow **catches what simulation could not**. If `report_cdc` also
> misses them, that is a critical finding ...
>
> **Part 2: `rtl/axi_rd_port.vhd`'s own dual-clock generate** ... the `start`
> toggle, the `run` level crossing, the `rst` synchroniser. Give it the same
> treatment.

---

## 2. The answer, up front

### 2.1 The static flow catches three of the four, and is BLIND to `G1`

MEASURED, `report_cdc -details` on an out-of-context synthesis of
`axi_rd_port` at `DUAL_CLK = true`, both clocks declared and grouped
asynchronous (`sim/cdc_teeth.sh`):

| CDC-BENCH mutation | what it does | static flow |
|---|---|---|
| `G3` | read pointer crosses through ONE flop | **CAUGHT** -- `CDC-4 Critical` "Multi-bit unknown CDC circuitry" at depth 0, plus `CDC-1 Critical` on the MSB |
| `G4` | write pointer crosses through ONE flop | **CAUGHT** -- same pair |
| `C6` | clear request crosses through ONE flop | **CAUGHT** -- `CDC-1 Critical` "1-bit unknown CDC circuitry" at depth 0 |
| `G1` | **both gray functions become the identity** | **NOT CAUGHT** |

**`G1` is worse than "not caught": the binary-pointer design reports FEWER
warnings than the correct one.** With gray coding the 10-bit pointer splits
into a 9-bit bus plus its MSB (the gray MSB IS the binary MSB, so synthesis
sources that bit from the counter directly), and `report_cdc` emits one
multi-bit row and one 1-bit row per direction. Remove the gray coding and the
ten bits merge into one bus, so two rows disappear. A reviewer diffing the two
reports sees the defective design as an improvement.

**Vivado has no concept of a gray code.** Its rule set classifies a crossing by
synchroniser topology -- width, depth, ASYNC_REG, combinational fan-in -- and
nothing in it inspects the encoding. So the honest statement is the one the
brief asked for in the negative case: **this project has no automated way at
all to detect that `rtl/async_fifo.vhd`'s pointers stopped being gray-coded.**
The only defences are code review and the fact that `G2` (encoder and decoder
disagreeing) is killed instantly in simulation -- which covers half the failure
space and not the half `G1` occupies.

The flow was proved to have teeth BEFORE any of that was believed: control
`N1` removes the read-pointer synchroniser entirely and produces **12
`CDC-1 Critical` rows at depth 0** where the baseline has none. See 4.3.

The same flow was then run against Part 2's own MTBF-class survivors, and the
result splits along a line worth knowing about:

| mutation | what it does | static flow |
|---|---|---|
| `P1` | start toggle's edge detector on a 1FF crossing | **CAUGHT**, `CDC-1 Critical` depth 0 |
| `P5` | `run_c` taken from `run_s1` -- 1FF | **CAUGHT**, `CDC-1 Critical` depth 0 |
| `P6` | `run_c` IS `run_f` -- no synchroniser at all | **CAUGHT**, 3x `CDC-1 Critical` depth 0 |
| `PA` | `frst` is the RAW core reset | **NOT CAUGHT out of context**; caught with port constraints, 165 Critical rows (4.9) |
| `PB` | reset through ONE flop | **NOT CAUGHT**, with or without port constraints |
| `PF` | `q_valid` gated on the AXI-domain `run_f` -- combinational across the CDC | **NOT CAUGHT out of context**, and this is the dangerous one (4.9) |

**Everything the flow misses in Part 2 is a path that touches a PORT.**
Out of context `rst` is an input port and `q_valid` is an output port, so those
crossings are not register-to-register and `report_cdc` skips them -- it says
so itself in an INFO on every run. That is a property of running out of
context, not of the tool, and it is the strongest argument in this file for
running `report_cdc` on the in-context FK33 build.

### 2.2 DEFECT: not one synchroniser flop in the weight path carried ASYNC_REG

MEASURED, netlist census over the same synthesis: **0 of the 577 cells Vivado
reports as `IS_SEQUENTIAL` carried `ASYNC_REG`** (577 rather than
`report_utilization`'s 277 CLB Registers, because `IS_SEQUENTIAL` also matches
the memory primitives), and `report_cdc`'s own summary counted **24 endpoints
under "No ASYNC_REG"**. `grep -rn -i async_reg` over `rtl/` and `hw/` found the
attribute only in `rtl/hbm_tg.vhd` and `hw/fk33/rtl/fk33_aux.vhd` -- never in
`rtl/async_fifo.vhd` or `rtl/axi_rd_port.vhd`.

`rtl/async_fifo.vhd`'s own comment said

```vhdl
  -- 2FF synchronisers.  Named, not inlined, so a constraint file can find them.
```

The comment is true and **no constraint file ever did**. A comment is not
evidence.

Why it matters, and it is not cosmetic: without `ASYNC_REG` the placer may put
the two stages of a synchroniser in different slices, so the settling time the
first stage gets is whatever the router happened to leave -- and that time is
the one quantity a 2FF pair exists to maximise. It also permits retiming or
absorption of the pair.

**FIXED**, in the two files, with the before/after measured rather than
predicted:

| | `ASYNC_REG` cells | report_cdc summary | "No ASYNC_REG" endpoints |
|---|---|---|---|
| before | 0 of 577 | `CDC-2 Warning x5`, `CDC-5 Warning x2` | 24 |
| after | 50 of 577 | `CDC-3 Info x5`, `CDC-6 Warning x2` | 0 |

`CDC-3` is Info, not Warning: those five 1-bit crossings are now classified
safe. The two `CDC-6` rows that remain are the gray pointer buses, and no
attribute closes them -- see 2.4.

Simulation is unaffected (attributes are inert to GHDL) and this was confirmed,
not assumed: `sim/tb_async_fifo`, `sim/tb_axi_rd_fsm`, `sim/tb_axi_rd_port` and
the new `sim/tb_axi_rd_port_dual` all pass as gate rows after the change.

### 2.3 DEFECT, reported and NOT fixed: `CDC-10 Critical` on the `run` crossing

The baseline report has one Critical row, and it is present on the **honest**
RTL at HEAD:

```
CDC-10  Critical  Combinational logic detected before a synchronizer
        Depth 2   g_dc.fsm/st_reg[2]/C  ->  g_dc.run_s1_reg/D
```

`rtl/axi_rd_fsm.vhd` drives `run <= '1' when st = S_RUN else '0'` -- a
combinational decode of a five-state register -- and `rtl/axi_rd_port.vhd`
feeds that decode straight into the `run_s1`/`run_s2` synchroniser. The state
bits do not change simultaneously at the receiving flop's input, so the decode
can produce a transient `S_RUN` pattern on a transition that never passes
through `S_RUN`; the core-domain flop can sample that glitch, and `run_c` then
opens the output gate for a cycle in a state where no job is running.

**Not fixed here, deliberately.** The fix is to register `run` in the AXI
domain before the crossing, which delays both the rise and the FALL of `run_c`
by one more `aclk`. The rise is the safe direction; the fall is not free --
MEASURED in 4.7, `run_c`'s fall is what bounds the residue an abandoned job can
leak, and this track measured that residue as 2 to 4 beats. Changing it is a
behaviour change to a file three tracks have touched today, and it belongs to
whoever owns the next `axi_rd_port` change, with the residue bound re-measured.
**Recorded as OPEN in section 7.**

### 2.4 GAP, reported and NOT fixed: no bus-skew constraint on the gray pointers

`hw/fk33/fk33_pcieep.xdc` DOES declare the asynchronous clock group subsystem A
needs, addressed through the engine's own pins, with a build-time check that it
matched something. That part is correct and is checked (section 3 step 5).

But the same file, forty lines earlier, states the rule its own subsystem-A
group then does not satisfy:

> Every crossing into this domain is a SINGLE BIT through a two-stage
> ASYNC_REG synchroniser -- there is deliberately no multi-bit CDC in
> rtl/fk33_aux.vhd ... That is why an asynchronous clock group is a complete
> constraint here and carries no bus-skew obligation. **A multi-bit crossing
> would need set_bus_skew and would NOT be allowed to rely on this line.**

Subsystem A's crossing IS multi-bit: a 10-bit gray pointer in each direction,
per port, on 28 ports. Gray coding means only one bit changes per source clock,
so the crossing is safe **provided the skew across the ten bits stays below one
source-clock period** -- and nothing in the design asks for that. There is no
`set_bus_skew`, no `set_max_delay -datapath_only`, and the asynchronous clock
group explicitly removes the only constraint that would otherwise have bounded
it. `report_cdc` flags exactly this as `CDC-6 Warning`, twice, and keeps
flagging it after the ASYNC_REG fix.

`hw/fk33/**` is TRACK PBLOCK's while a place-and-route is running, so nothing
there was edited. **Recorded as OPEN in section 7.**

### 2.5 Part 2: the port's dual-clock generate now has a bench, a gate row and
a mutation table

`sim/tb_axi_rd_port_dual.vhd` (three clock ratios, a value-and-order oracle
carrying each beat's own address, two abandons, a mid-flight reset and a
slow-consumer phase) plus `sim/mutate_axi_rd_port_dual.sh`.

MEASURED: **6 of 20 killed, 14 survivors, every one named in 4.7.** A low kill
ratio, and the reason is the point of this track: six of the fourteen are
MTBF-class rows that no simulation can reach, and five more are true
equivalents whose equivalence is now MEASURED rather than argued -- the port
NEVER refuses an offered R beat (`rrefuse = 0` at all three ratios), so every
mutation that only changes behaviour on a refused beat is inert on a conforming
design. That measurement has its own teeth-check (`PJ`), which is what turns it
from an excuse into a result.

---

## 3. The procedure, in the order it was run

Each step says what it controls for. This is the reusable part.

1. **Read the RTL for the attribute before running anything.**
   `grep -rn -i "async_reg\|set_clock_groups\|set_bus_skew\|report_cdc"` over
   `rtl/`, `hw/` and `sim/`. This alone found 2.2 and located the FK33 clock
   group. Controls for spending an hour building a flow to discover something a
   grep answers.

2. **Build the OOC flow on the existing precedent, not from scratch.**
   `sim/ooc_fk33_a.tcl` already synthesises `axi_rd_port` out of context at the
   FK33 geometry and already writes
   `set_clock_groups -asynchronous -group coreclk -group axiclk`. `sim/ooc_cdc.tcl`
   copies its three rules (constrain before `synth_design`; parse
   `report_utilization` not `get_cells -filter PRIMITIVE_TYPE`; cap threads) and
   adds the two things a teeth table needs: `rtldir` as an argument, so every
   mutation is a COPY and nothing under `rtl/` is edited, and `groups` as a
   switch, so "no clock group" is a measurement rather than an assumption.

3. **Guard the memory and capture the exit status, on every invocation.**
   `sim/run_ooc_cdc.sh` runs Vivado inside
   `systemd-run --user --scope -p MemoryMax=6G -p MemorySwapMax=0`, wraps it in
   `/usr/bin/time -v` for the peak RSS, and reports OK only when the exit status
   is 0 **and** the script's own `OOC_CDC_DONE` sentinel is in the log. That
   second condition is not paranoia: see 6.1, where it fired on the very first
   run.

4. **Prove the flow reports SOMETHING before believing that it reports
   nothing.** Control `N1` deletes the read-pointer synchroniser outright. If
   that had come back clean, every clean row below would have been worthless.

5. **Prove the clock group is live, and measure what its absence does.**
   Vivado 2023.2 has no `get_clock_groups` command (6.1), so the constraint
   cannot be read back directly. Two consequences can be:
   `report_cdc`'s Exception column, and `report_clock_interaction`'s
   Clock-Pair Classification. Control `N0` runs the identical netlist with the
   group omitted. Controls for the specific trap the brief names.

6. **Run the four survivors CDC-BENCH could not kill, with their anchors copied
   verbatim from `sim/mutate_async_fifo.sh`,** so the mutation the static flow
   sees is byte-for-byte the one simulation could not.

7. **Give `G1` its own teeth-check.** Simulation kills `G2` instantly, which is
   what proves its bench watches the pointers at all. The static flow needs the
   equivalent: if BASE, `G1` and `G2` all produce the same report, the flow is
   blind to the pointer encoding as such, and saying so IS the result.

8. **Only then write the Part 2 bench**, and write it so the FIFO is FULL as
   well as empty. The first version ran the consumer at 7-in-8 duty throughout,
   which makes the AXI side the bottleneck at every ratio; three mutations are
   invisible in that state (6.4).

9. **When a survivor's explanation is "that state never occurs", MEASURE that
   it never occurs, and give the measurement teeth.** `rrefuse` counts cycles
   where the port refused an offered R beat; it is 0 on the honest design, which
   explains five survivors at once, and mutation `PJ` makes it 1532 so the
   counter is shown to work.

10. **Run the mutation harness against the RTL AFTER the fix as well as
    before**, so "attributes are inert to simulation" is a measurement.

11. **When a mutation comes back identical to the baseline, ask whether the
    tool was ASKED the question before concluding it cannot answer it.**
    `PA`, `PB` and `PF` all came back identical, and `report_cdc`'s own INFO
    line names the reason for two of them: ports with no input delay are
    skipped. Adding `iodelay=1` separated "the tool is blind to this" (`PB`,
    `PF`) from "the tool was never asked" (`PA`). Without that step all three
    would have been written up as blind spots and one of them would have been
    wrong.

---

## 4. The evidence

### 4.1 The baseline, honest RTL at HEAD, clock groups declared (MEASURED)

`report_cdc -details`, `axi_rd_port`, `DUAL_CLK = true`, `AXI_DW = 256`,
`DEPTH = 512`, `MAXB = 16`, `MAXOUT = 16`, coreclk 3.300 ns, axiclk 3.333 ns.
This is the report BEFORE the ASYNC_REG fix of 2.2:

```
ID      Severity  Count  Description
------  --------  -----  ------------------------------------------------------
CDC-2   Warning       5  1-bit synchronized with missing ASYNC_REG property
CDC-5   Warning       2  Multi-bit synchronized with missing ASYNC_REG property
CDC-10  Critical      1  Combinational logic detected before a synchronizer

Source Clock: coreclk        Destination Clock: axiclk
  1  CDC-2  Warning  ... Depth 2  Asynch Clock Groups  g_dc.fifo/clr_ack_r_reg/C  -> g_dc.fifo/clr_a_s1_reg/D
  2  CDC-5  Warning  ... Depth 2  Asynch Clock Groups  g_dc.fifo/rp_g_reg[8:0]/C  -> g_dc.fifo/rp_g_s1_reg[8:0]/D
  3  CDC-2  Warning  ... Depth 2  Asynch Clock Groups  g_dc.fifo/rp_reg[9]/C      -> g_dc.fifo/rp_g_s1_reg[9]/D
  4  CDC-2  Warning  ... Depth 2  Asynch Clock Groups  g_dc.s_tog_reg/C           -> g_dc.s_t1_reg/D

Source Clock: axiclk         Destination Clock: coreclk
  1  CDC-2   Warning  ... Depth 2  Asynch Clock Groups  g_dc.fsm/clr_r_reg/C       -> g_dc.fifo/clr_r_s1_reg/D
  2  CDC-5   Warning  ... Depth 2  Asynch Clock Groups  g_dc.fifo/wp_g_reg[8:0]/C  -> g_dc.fifo/wp_g_s1_reg[8:0]/D
  3  CDC-2   Warning  ... Depth 2  Asynch Clock Groups  g_dc.fifo/wp_reg[9]/C      -> g_dc.fifo/wp_g_s1_reg[9]/D
  4  CDC-10  Critical ... Depth 2  Asynch Clock Groups  g_dc.fsm/st_reg[2]/C       -> g_dc.run_s1_reg/D
```

and the netlist census printed by `sim/ooc_cdc.tcl` in the same run:

```
CDC_ASYNC_REG_TOTAL_SEQ 577
CDC_ASYNC_REG_TRUE 0
CDC_SRL_COUNT 0
```

`CDC_SRL_COUNT 0` matters on its own: the three-deep `s_t1/s_t2/s_t3` toggle
chain was NOT absorbed into an SRL, which it could have been and which would
have destroyed the synchroniser silently. Measured, not assumed.

Summary line, which is where the ASYNC_REG count is easiest to read:

```
Severity  Source Clock  Destination Clock  CDC Type                 Exceptions           Endpoints  Safe  Unsafe  Unknown  No ASYNC_REG
Critical  axiclk        coreclk            No Common Primary Clock  Asynch Clock Groups         12    11       1        0            12
Warning   coreclk       axiclk             No Common Primary Clock  Asynch Clock Groups         12    12       0        0            12
```

### 4.2 The clock group, live and absent (MEASURED)

`report_clock_interaction`, identical netlist, the ONLY difference being
whether `sim/ooc_cdc.tcl` emitted the `set_clock_groups` line.

WITH the group:

```
From Clock  To Clock  WNS(ns)  Failing Endpoints  Total  Clock-Pair Classification  Inter-Clock Constraints
axiclk      axiclk       0.80                  0    476  Clean                      Timed
axiclk      coreclk                            0     12  Ignored                    Asynchronous Groups
coreclk     axiclk                             0     12  Ignored                    Asynchronous Groups
coreclk     coreclk      1.94                  0    969  Clean                      Timed
```

WITHOUT it:

```
axiclk      axiclk       0.80                  0    476  Clean                      Timed
axiclk      coreclk     -0.33                 12     12  No Common Clock            Timed (unsafe)
coreclk     axiclk      -0.26                 12     12  No Common Clock            Timed (unsafe)
coreclk     coreclk      1.94                  0    969  Clean                      Timed
```

**`report_cdc` itself is NOT dependent on the clock group.** MEASURED: the two
runs produce a byte-identical rule summary and identical rows; the ONLY
difference anywhere in the report is the Exception column, `None` against
`Asynch Clock Groups`. That is the opposite of what the brief's trap predicted,
and it is the useful direction: `report_cdc` finds the crossings whether or not
anyone remembered the constraint. The tool that notices the missing constraint
is `report_clock_interaction`, and what it shows is 24 endpoints failing at a
0.03 ns requirement -- which reads as a timing problem, not as a missing
exception, and is exactly what `hw/fk33/fk33_pcieep.xdc`'s own comment says
would happen in the real build where the two clocks share an MMCM reference.

**The signature this harness compares therefore INCLUDES the Exception
column.** The first version did not, and it scored `N0` as identical to the
baseline -- the wrong conclusion about a missing constraint, produced by a
checker that was looking at the wrong field.

### 4.3 `N1`, the known-bad control (MEASURED)

`rp_bin_w <= gray2bin(rp_g_s2)` becomes `gray2bin(rp_g)`: the read pointer
crosses with no synchroniser at all.

```
ID      Severity  Count  Description
CDC-1   Critical     12  1-bit unknown CDC circuitry
CDC-2   Warning       4  1-bit synchronized with missing ASYNC_REG property
CDC-5   Warning       1  Multi-bit synchronized with missing ASYNC_REG property
CDC-10  Critical      1  Combinational logic detected before a synchronizer

  2  CDC-1  Critical  1-bit unknown CDC circuitry   Depth 0   g_dc.fifo/rp_g_reg[9]/C -> g_dc.fifo/full_r_reg/D
  3  CDC-1  Critical  1-bit unknown CDC circuitry   Depth 0   g_dc.fifo/rp_g_reg[0]/C -> g_dc.fifo/w_level_r_reg[0]/D
  ... twelve rows, every one at Depth 0 ...
```

Twelve Critical rows where the baseline has none, all at synchroniser depth 0.
**The flow flags a real violation.** Everything else in this file is read
against that.

### 4.4 The four CDC-BENCH survivors under the static flow (MEASURED)

All rows are one `report_cdc -details` each, on the SAME baseline (the RTL at
HEAD after the ASYNC_REG fix of 2.2), same generics, same XDC, differing only
in the mutation applied to a COPY of `rtl/`. A row identical to `BASE` is a
mutation the static flow did NOT catch.

```
BASE   ASYNC_REG=50/577  rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2
N0     ASYNC_REG=50/577  rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2   (Exception column: None, not Asynch Clock Groups)
N1     ASYNC_REG=50/577  rules=CDC-1:Critical:12,CDC-10:Critical:1,CDC-3:Info:4,CDC-6:Warning:2
N2     ASYNC_REG=0/577   rules=CDC-10:Critical:1,CDC-2:Warning:5,CDC-5:Warning:2

G1     ASYNC_REG=50/559  rules=CDC-10:Critical:1,CDC-3:Info:3,CDC-6:Warning:2
G2     ASYNC_REG=50/577  rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2
G3     ASYNC_REG=50/577  rules=CDC-1:Critical:1,CDC-10:Critical:1,CDC-3:Info:4,CDC-4:Critical:1,CDC-6:Warning:1
G4     ASYNC_REG=50/577  rules=CDC-1:Critical:1,CDC-10:Critical:1,CDC-3:Info:4,CDC-4:Critical:1,CDC-6:Warning:1
C6     ASYNC_REG=50/577  rules=CDC-1:Critical:1,CDC-10:Critical:1,CDC-3:Info:4,CDC-6:Warning:2

P1     ASYNC_REG=50/576  rules=CDC-1:Critical:1,CDC-10:Critical:1,CDC-3:Info:4,CDC-6:Warning:2
P5     ASYNC_REG=50/577  rules=CDC-1:Critical:1,CDC-3:Info:5,CDC-6:Warning:2
P6     ASYNC_REG=50/577  rules=CDC-1:Critical:3,CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2
PA     ASYNC_REG=50/577  rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2
PB     ASYNC_REG=50/577  rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2
PF     ASYNC_REG=50/577  rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2
```

| tag | mutation | static flow | how it shows |
|---|---|---|---|
| `N1` | read pointer, NO synchroniser | **CAUGHT** | +12 `CDC-1 Critical` at depth 0 |
| `G3` | read pointer, 1FF | **CAUGHT** | +`CDC-4 Critical` (multi-bit unknown) and +`CDC-1 Critical`, both depth 0 |
| `G4` | write pointer, 1FF | **CAUGHT** | the same pair |
| `C6` | clear request, 1FF | **CAUGHT** | +`CDC-1 Critical` at depth 0 |
| `P1` | start toggle's edge detector on a 1FF crossing | **CAUGHT** | +`CDC-1 Critical` at depth 0 |
| `P5` | `run_c` from `run_s1`, 1FF | **CAUGHT** | +`CDC-1 Critical` at depth 0; note `CDC-10` DISAPPEARS, because the offending combinational path now ends at the 1FF |
| `P6` | `run_c` IS `run_f`, no synchroniser | **CAUGHT** | +3 `CDC-1 Critical` at depth 0 |
| `G1` | **both gray functions to identity** | **NOT CAUGHT** | severities unchanged; TWO FEWER warnings than the correct design |
| `G2` | decoder only to identity | **NOT CAUGHT** | byte-identical to `BASE`. Simulation kills this instantly; the static flow cannot see it at all |
| `PA` | `frst` is the RAW core reset | **NOT CAUGHT out of context** | identical to `BASE`; see 4.9 -- it IS caught once the ports are constrained |
| `PB` | reset through ONE flop | **NOT CAUGHT** | identical to `BASE`, with or without port constraints (4.9) |
| `PF` | `q_valid` gated on `run_f`: combinational straight across the CDC | **NOT CAUGHT** | identical to `BASE`, with or without port constraints (4.9) |

**`G1` and `G2` together are the complete statement.** Simulation kills `G2`
instantly and cannot touch `G1`; the static flow sees NEITHER. The two methods
are complementary on the synchroniser topology and are BOTH blind to the
pointer encoding. Nothing in this project covers a change that keeps encoder
and decoder consistent while making them not a gray code.

### 4.5 `G1` in full, and why it reads as an improvement (MEASURED)

```
ID      Severity  Count  Description
CDC-2   Warning       3  1-bit synchronized with missing ASYNC_REG property
CDC-5   Warning       2  Multi-bit synchronized with missing ASYNC_REG property
CDC-10  Critical      1  Combinational logic detected before a synchronizer

Source Clock: coreclk        Destination Clock: axiclk
  1  CDC-2  Warning  Depth 2  g_dc.fifo/clr_ack_r_reg/C  -> g_dc.fifo/clr_a_s1_reg/D
  2  CDC-5  Warning  Depth 2  g_dc.fifo/rp_reg[9:0]/C    -> g_dc.fifo/rp_g_s1_reg[9:0]/D
  3  CDC-2  Warning  Depth 2  g_dc.s_tog_reg/C           -> g_dc.s_t1_reg/D
```

Against the baseline's `CDC-2 x5 / CDC-5 x2`, `G1` reports `CDC-2 x3 /
CDC-5 x2`. Every severity is unchanged; the row that changes is
`rp_g_reg[8:0]` plus `rp_reg[9]` collapsing into one `rp_reg[9:0]` bus, because
with the identity encoder `rp_g` IS `rp` and synthesis merges them.

**Two fewer warnings for the defective design.** Any review rule of the form
"the CDC report must not get worse" passes `G1`.

### 4.6 The ASYNC_REG fix, before and after (MEASURED)

Identical flow, identical generics, the only change being the attribute
declarations added to `rtl/async_fifo.vhd` and `rtl/axi_rd_port.vhd`:

```
before  ASYNC_REG=0/577  SRL=0 | rules=CDC-10:Critical:1,CDC-2:Warning:5,CDC-5:Warning:2
after   ASYNC_REG=50/577 SRL=0 | rules=CDC-10:Critical:1,CDC-3:Info:5,CDC-6:Warning:2
```

`CDC-2 Warning` -> `CDC-3 Info` on all five 1-bit crossings; `CDC-5` ->
`CDC-6`, which stays a Warning because it is the multi-bit gray bus and no
attribute makes a multi-bit crossing safe in Vivado's eyes (2.4). The
"No ASYNC_REG" endpoint count goes 24 -> 0.

The harness keeps this measurable from the tree at any later date: control
`N2` STRIPS the attributes again and reproduces the pre-fix report, and it
refuses to run (exit 2) if it finds no attribute to strip -- so it cannot
silently test nothing after a future edit.

### 4.7 Part 2: `sim/tb_axi_rd_port_dual` on the honest RTL (MEASURED, 0.14 s)

```
anear: beats=384 stall=183 bp=1431 rrefuse=0 residue=3 err=0
aslow: beats=364 stall=260 bp=1417 rrefuse=0 residue=4 err=0
afast: beats=388 stall=164 bp=1431 rrefuse=0 residue=2 err=0
axi_rd_port_dual: 0 errors across 3 clock ratios
PASS: tb_axi_rd_port_dual
```

Three numbers there are worth more than the verdict.

**`rrefuse = 0`, at every ratio.** That is the count of cycles on which the port
had `rready` low while the slave was offering a beat. `rtl/async_fifo.vhd`'s
header asserts that the stale full flag "is unreachable in any case, because the
AR throttle above exists precisely so the FIFO never reaches DEPTH", and
`rtl/axi_rd_fsm.vhd`'s asserts that "an accepted burst can never overrun the
FIFO". Both reduce to this one observable, and it now holds end to end at
`DEPTH = 16 / MAXB = 8 / MAXOUT = 4` -- a second geometry alongside CDC-BENCH's
`wstall = 0` measurement at `DEPTH = 16`. It is asserted, not printed, and its
teeth-check is `PJ`.

**`bp` (cycles the consumer refused an offered beat) is ~1420.** That is the
slow-consumer phase doing its job. Without it the FIFO is empty-limited at every
ratio and three mutations are invisible (6.4).

**`residue` is 2 to 4.** That is how many beats of an abandoned job reach a
full-rate consumer before `run_c` falls. It bounds what section 2.3's fix would
change.

### 4.8 `sim/mutate_axi_rd_port_dual.sh`, final run (MEASURED)

```
---- class TOG: the start pulse's toggle synchroniser ------------------
P1   TOG    SURVIVED  the start toggle is read one flop EARLIER, so the edge detector sits on a 1FF crossing
P2   TOG    KILLED    anear: J1 STALLED -- 20 of 20 beats never arrived
P3   TOG    KILLED    anear: J2 STALLED -- 13 of 13 beats never arrived
P4   TOG    KILLED    anear: J1 STALLED -- 20 of 20 beats never arrived

---- class RUN: the run level crossing back to the core domain ---------
P5   RUN    SURVIVED  run_c is taken one flop early -- a 1FF crossing
P6   RUN    SURVIVED  run_c is the AXI-domain run level with NO SYNCHRONISER AT ALL
P7   RUN    SURVIVED  q_valid loses its run_c gate
P8   RUN    SURVIVED  f_qr loses its run_c gate
P9   RUN    SURVIVED  the run synchroniser loses its reset

---- class RST: the reset synchroniser into the AXI domain -------------
PA   RST    SURVIVED  frst is the RAW core-domain reset, crossing unsynchronised
PB   RST    SURVIVED  the reset crosses through ONE flop, not two

---- class GATE: the two R-channel gates that hang off run_f -----------
PC   GATE   SURVIVED  rready is no longer forced high outside S_RUN
PD   GATE   SURVIVED  f_iv is no longer gated on run_f
PE   GATE   SURVIVED  beat_f counts an OFFERED beat rather than an ACCEPTED one
PP   GATE   SURVIVED  PC AND PD TOGETHER
PF   GATE   SURVIVED  q_valid gated on the AXI-domain run level directly -- combinational across the CDC

---- class WIRE: the generate's own instantiation ----------------------
PG   WIRE   SURVIVED  the FIFO's OUT_MARGIN is zeroed while the FSM keeps 3
PJ   WIRE   KILLED    anear: THE PORT REFUSED AN OFFERED R BEAT on 1532 cycles
PH   WIRE   KILLED    aslow: J1 STALLED -- 20 of 20 beats never arrived
PI   WIRE   KILLED    aslow: BEAT got 1025 want 1026 -- a beat was DROPPED, DUPLICATED or REORDERED

=======================================================================
kill ratio: 6 KILLED + 0 ABORT = 6 of 20;  14 SURVIVED
survivors: P1 P5 P6 P7 P8 P9 PA PB PC PD PE PP PF PG
```

**Survivors, every one under its own name.** These are the most valuable rows in
the table: they measure the checker's resolution floor. None is discarded.

| tag | class | why it survives | closable? |
|---|---|---|---|
| `P1` | **unobservable by construction** | the toggle's edge detector moves onto `s_t1 xor s_t2`, so the crossing is 1FF. An MTBF statement. | **CAUGHT by `sim/cdc_teeth.sh`**, see 4.4 |
| `P5` | **unobservable by construction** | `run_c` is taken from `run_s1`: 1FF. | **CAUGHT by `sim/cdc_teeth.sh`** |
| `P6` | **unobservable by construction** | `run_c` IS `run_f`, an AXI-domain level read directly by core-domain logic with no synchroniser at all. An RTL simulator samples atomically, so it crosses cleanly. | **CAUGHT by `sim/cdc_teeth.sh`** |
| `PA` | **unobservable by construction** | `frst` is the raw core reset crossing into the AXI domain. | **CAUGHT by `sim/cdc_teeth.sh` ONLY with `iodelay=1`** -- 165 Critical rows; invisible without port constraints (4.9) |
| `PB` | **unobservable by construction** | the reset crosses through one flop. | **NOT CAUGHT by anything measured here.** Both stages are driven from the same input port, so it is not a register-to-register crossing at any setting (4.9) |
| `PF` | **unobservable by construction** | `q_valid` is gated on `run_f`, the AXI-domain level, so a combinational path runs straight across the CDC into the core domain's consumer. The most dangerous row in the table and the most invisible one in simulation. | **NOT CAUGHT out of context** -- the path ends at an output port, so there is no capturing register. Needs `report_cdc` on the IN-CONTEXT build (4.9, and section 7 item 5) |
| `PC` | **true equivalent, MEASURED** | `rready` is no longer forced high outside S_RUN. It differs only on a cycle where the port refuses a beat, and MEASURED `rrefuse = 0` on every ratio -- the AR throttle guarantees the FIFO can absorb every beat it has already promised, so `w_ready` never falls while a beat is being offered. Teeth for the measurement: `PJ`. | only by breaking the throttle, which is a different contract |
| `PD` | **true equivalent, MEASURED** | `f_iv` is no longer gated on `run_f`, so drained beats are written into the FIFO instead of discarded. They are thrown away by the clear that follows, and they cannot overrun for the same `rrefuse = 0` reason. | as `PC` |
| `PE` | **true equivalent, MEASURED** | `beat_f` counts an offered beat rather than an accepted one. The two differ only when `rvalid = 1` and `rready = 0`, which never happens. | as `PC` |
| `PP` | **true equivalent, MEASURED** | `PC` AND `PD` together, mutated as a PAIR because CDC-BENCH's `A7`/`D4` lesson says two guards covering one condition must be broken together. Here the pair is ALSO inert, and for the same measured reason -- which is a stronger statement than either singleton. | as `PC` |
| `PG` | **true equivalent for the OVERRUN property** | the FIFO's `OUT_MARGIN` is zeroed while the FSM keeps `LVL_MARGIN = 3`, so the throttle under-counts by three. It still cannot overrun the MEMORY: `w_level` is `used_w + 1`, which remains an over-estimate of the memory's own occupancy, and the margin only accounts for beats that have already LEFT the memory into the output stage. It costs capacity, not correctness. | needs a throughput oracle, not a value one |
| `P7` | **near-equivalent, precisely characterised** | `q_valid` loses its `run_c` gate. MEASURED: residue goes 2/3/4 -> 4/5/6 across the three ratios, so the gate is worth EXACTLY TWO BEATS and the four-phase flush does the rest. No constant bound separates them: the honest maximum (4) equals the mutant minimum (4). | only with a per-ratio bound, which is fitting the checker to the data |
| `P8` | **true equivalent** | `f_qr` loses its `run_c` gate. MEASURED: output byte-identical to the control at all three ratios. `run_c` is low only while the FIFO is being flushed or before the first beat of a job has been fetched, so there is never a beat for the ungated pop to take. | needs an AXI latency short enough to land a beat inside the 2-cycle `run_c` rise, which cannot happen with any AR round trip |
| `P9` | **true equivalent** | the `run` synchroniser loses its reset. MEASURED: output byte-identical. `run_s1`/`run_s2` track `run_f`, which the FSM's own reset holds at `0`, so they reach 0 anyway. Same shape as `R2` in `sim/mutate_async_fifo.sh`. | never |

### 4.9 Why `PA`, `PB` and `PF` are invisible, and what fixes one of them

`report_cdc` prints its own explanation on every run:

```
INFO: [Timing 38-314] The report_cdc command only analyzes and reports clock
domain crossing paths where clocks have been defined on both source and
destination sides.  Ports with no input delay constraint are skipped.
```

Out of context, `axi_rd_port`'s `rst` is an input PORT and its `q_valid` is an
output PORT. `PA` (the raw reset crossing), `PB` (a 1FF reset synchroniser) and
`PF` (`q_valid` gated combinationally on the AXI-domain `run_f`) all live on
port-to-register or register-to-port paths, which are not
register-to-register crossings and are skipped.

MEASURED, re-running the same three mutations with `iodelay=1`, which adds
`set_input_delay` / `set_output_delay` on every non-clock port against the
clock of its own domain:

```
BASEio  CDC-3:Info:5, CDC-6:Warning:2, CDC-10:Critical:1, CDC-15:Warning:72, CDC-26:Warning:1
PAio    CDC-1:Critical:129, CDC-13:Critical:36, CDC-3:Info:5, CDC-6:Warning:2,
        CDC-10:Critical:1, CDC-15:Warning:125, CDC-26:Warning:30
PBio    identical to BASEio
PFio    identical to BASEio
```

**`PA` goes from invisible to 165 Critical rows** once the ports are
constrained: the raw `rst` reaches every AXI-domain flop, and each one is a
`CDC-1` or `CDC-13`. So constraining the ports is worth doing, and
`sim/ooc_cdc.tcl` now has the switch.

**`PB` and `PF` stay invisible even then**, and that is the honest limit of an
out-of-context run. `PF` is the one that matters: it is a genuine combinational
path from an `axiclk` register through a gate into a `coreclk` consumer, and it
is invisible here only because out of context the consumer does not exist --
the path terminates at a port. **In the FK33 build the consumer is inside the
engine and this becomes a real register-to-register crossing, so
`report_cdc` on the in-context build is where `PF` would be found.** That build
was not run here (section 7 item 5).

Note also that `BASEio` itself gains `CDC-15 Warning x72` (clock-enable
controlled CDC) and `CDC-26 Warning x1`. Both are artefacts of constraining
the ports rather than findings about the design -- the `CDC-26` row names
`rst -> g_dc.rst_s1_reg/D`, which is not a LUTRAM at all. Not investigated
further; recorded in section 7.

---

## 5. Measured and REJECTED -- do not retry

- **Do NOT expect `report_cdc` to notice that a gray code was removed.**
  MEASURED, mutation `G1`: replacing both `bin2gray` and `gray2bin` with the
  identity leaves every severity unchanged and REDUCES the warning count from
  seven to five, because the ten pointer bits merge into one bus. Vivado's rule
  set classifies by width, depth, ASYNC_REG and combinational fan-in; nothing in
  it inspects an encoding. There is no `report_cdc` switch, no
  `-severity` filter and no property that changes this.

- **Do NOT assume `report_cdc` needs `set_clock_groups -asynchronous` to report
  anything.** MEASURED, control `N0`: the same netlist with the group omitted
  produces a byte-identical rule summary and identical detail rows, differing
  only in the Exception column. The report that DOES change is
  `report_clock_interaction`, which goes from "Ignored / Asynchronous Groups" to
  "No Common Clock / Timed (unsafe)" with 24 failing endpoints at a 0.03 ns
  requirement. Check the constraint there, not in `report_cdc`'s severities.

- **Do NOT try to read the clock groups back with `get_clock_groups`.**
  MEASURED on Vivado 2023.2: `invalid command name "get_clock_groups"`. The
  command does not exist in this version. Read the constraint's CONSEQUENCE
  instead -- the Exception column, or the clock-interaction classification.

- **Do NOT use `get_timing_paths -from clkA -to clkB` as the proof that an
  asynchronous clock group is live.** MEASURED: it returned one path in each
  direction on a design where `report_cdc` and `report_clock_interaction` both
  confirm the exception is applied. It is not a readback of the exception.

- **Do NOT run the residue check against an EMPTY FIFO.** The first version of
  `sim/tb_axi_rd_port_dual` abandoned a 60-beat job after 150 core cycles, by
  which time the consumer had finished it, so `res_cnt` was 0 on correct RTL at
  all three ratios and the whole abandon test passed vacuously. The coverage
  assert is what caught it. The job is now 400 beats and the consumer is stopped
  for 60 cycles before the abandon so the FIFO is full when it happens.

- **Do NOT expect a residue BOUND to separate an ungated `q_valid` from the
  gated one.** MEASURED: honest residue is 2 / 3 / 4 across the three ratios and
  mutation `P7`'s is 4 / 5 / 6 -- the honest maximum equals the mutant minimum,
  so no single constant separates them. The `run_c` gate is worth exactly two
  beats at every ratio; the four-phase flush does the rest of the work.

- **Do NOT read a clean OOC `report_cdc` as covering a reset crossing or an
  output gate.** MEASURED: `PA` (the raw core reset crossing into the AXI
  domain), `PB` (a 1FF reset synchroniser) and `PF` (`q_valid` gated
  combinationally on the AXI-domain `run_f`) are all byte-identical to the
  baseline out of context. Adding `set_input_delay`/`set_output_delay` on every
  port turns `PA` into 165 Critical rows and leaves `PB` and `PF` untouched.
  A port is not a register, and `report_cdc` says so in an INFO on every run.

- **Do NOT model the AXI slave's AR queue at MAXOUT depth.** It is 16 here
  against `MAXOUT = 4` on purpose: a model that backpressures AR absorbs an
  outstanding-burst defect instead of exposing it. Same lesson CDC-BENCH
  recorded for the FIFO model in `sim/tb_axi_rd_fsm.vhd`.

---

## 6. Measurement traps hit, including my own

**6.1 THE WORST ONE: I overwrote an existing, tracked, gate-row testbench.**
The brief said "`sim/tb_axi_rd_port.vhd` and `sim/mutate_axi_rd_port.sh`
(create them)". `sim/tb_axi_rd_port.vhd` **already existed**, tracked since
`562d33d`, and is a gate row with its own `tb_args` line
(`-gMAXOUT=2 -gDEPTH=64 -gSTALL=3`). `Write` reported "File created
successfully" and I did not check. It was noticed only when reading
`sim/regress.sh` to add a row and finding `sim:tb_axi_rd_port)` already there.
Recovered with `git checkout -- sim/tb_axi_rd_port.vhd`; the new bench is
`sim/tb_axi_rd_port_dual.vhd` with its own entity name, and the harness was
renamed to match. **`git ls-files <path>` before creating any file a brief
tells you to create.** A brief is not evidence that a file does not exist.

**6.2 A success line is not a result.** The first `sim/ooc_cdc.tcl` run printed
`synth_design completed successfully`, the full utilisation summary, the clock
list and `28 Infos, 15 Warnings, 0 Critical Warnings and 0 Errors` -- and then
died on `invalid command name "get_clock_groups"` and exited 1. Every visible
line said success. `sim/run_ooc_cdc.sh` requires BOTH `rc = 0` and its own
`OOC_CDC_DONE` sentinel, and that requirement fired on the very first
invocation it ever made.

**6.3 Two signals driven from two processes is an ELABORATION error in GHDL,
not a warning.** `several sources for unresolved signal
.tb_axi_rd_port_dual(sim).g(0).exp_word`. The sequencer and the consumer both
wanted to write the expectation. Every expectation now lives as a VARIABLE
inside the consumer and is loaded through a one-cycle `ld` handshake, with the
consumer publishing what the sequencer reads back. Costs nothing and is the only
shape that elaborates.

**6.4 A bench whose FIFO is always empty cannot see the AR throttle at all.**
With the consumer at 7-in-8 duty the AXI side is the bottleneck at every ratio,
`rready` never goes low, and `PC`, `PD`, `PE`, `PG` and the `PP` pair are all
invisible -- they change behaviour only on a refused beat. Adding a 1-in-8
slow-consumer phase raised `bp` from 0 to ~1420 and is what makes `rrefuse = 0`
a meaningful statement rather than an artefact of never testing the state.

**6.5 `q_ready` is a REGISTER, so relaxing the oracle in the same delta as
stopping the consumer produces a false failure.** Dropping `strict` and
`cons_en` together let a legitimate in-flight beat land in the window where the
oracle believed no job was running: "A BEAT WAS DELIVERED WHILE NO JOB WAS
RUNNING" on CORRECT RTL, at two of the three ratios. The consumer is now stopped
two core cycles before the oracle is relaxed. This is the same class of sampling
trap CDC-BENCH recorded in its 6.2 and 6.6.

**6.6 A teeth-check can itself be toothless, and the first one was.** `PJ` tells
the FSM the FIFO is always empty, so the AR throttle over-issues. It SURVIVED,
because the FIFO simply backpressures and the design stays functionally
CORRECT -- there is no value error to see. The mutation was right and the check
was missing. Adding `rrefuse /= 0` as an assertion turned `PJ` into a kill with
1532 refusals, and only then did the five survivors it exists to explain have a
measured explanation rather than an argument.

**6.7 A mixed baseline makes a teeth table unreadable.** The first
`sim/cdc_teeth.sh` sweep of the port-level mutations was launched minutes before
the ASYNC_REG fix landed, so some rows staged the pre-fix RTL and some the
post-fix, and their signatures differ for two unrelated reasons at once. The
whole table was re-run against one baseline. **Stage the sources for a whole
table at one instant, or record which instant each row used.**

**6.8 Vivado's OOC mode warns about `HD.CLK_SRC` on every clock port.** It
appears twice in every run here and is not a fault: out of context there is no
clock buffer to point at, so clock delay/skew is not estimated. It is noise in
the log, and it looks like a missing constraint.

---

## 7. What is NOT verified

An explicit list, because a tidy conclusion that overstates the evidence is
worth less than an honest gap.

1. **THE GRAY CODING ITSELF, BY ANY MEANS.** Simulation cannot see it (`G1`
   survives CDC-BENCH's eight clock ratios) and `report_cdc` cannot see it
   (`G1` reports fewer warnings than the correct design). This project has **no
   automated defence at all** against `rtl/async_fifo.vhd`'s pointers ceasing to
   be gray-coded. What partially covers the space: `G2`, which breaks encoder
   and decoder apart, IS killed instantly in simulation. What is not covered:
   any change that keeps them consistent.

2. **The `CDC-10` combinational-decode-before-synchroniser finding of 2.3 is
   REPORTED, NOT FIXED,** and it is on the honest RTL at HEAD. It is a real
   glitch path from `axi_rd_fsm`'s state decode into the core domain.

3. **The missing bus-skew constraint of 2.4 is REPORTED, NOT FIXED.**
   `hw/fk33/**` belongs to TRACK PBLOCK while a place-and-route is running.
   Nothing measures the actual skew across the ten pointer bits, and nothing
   asks the router to bound it.

4. **Nothing here is placed or routed.** Every number is from `synth_design
   -mode out_of_context`. `report_cdc`'s topology rules do not need placement,
   but `ASYNC_REG`'s actual effect -- the two flops ending up in the same slice
   -- is a PLACEMENT outcome and was not observed. The census proves the
   attribute is on the netlist, not that the placer honoured it.

5. **The FK33 build's own `report_cdc` was never run, and three findings
   depend on it.** Mutation `PF` -- a combinational path from an `axiclk`
   register into a `coreclk` consumer -- is invisible out of context because
   the consumer is outside the unit, and `PB` is invisible because both
   "synchroniser" stages hang off the same input port. Both would become
   ordinary register-to-register crossings inside `fk33_engine`. So would the
   28 ports' worth of crossings that this single-port analysis multiplies by. Everything here is
   `axi_rd_port` alone, one port, out of context. The real design has 28 of
   them inside `fk33_engine` under a block design, where cell names differ and
   where the clock group is written against the engine's pins. Running
   `report_cdc` on that build is the obvious next item and it is not closed
   here.

6. **`CDC-15` (72 rows) and `CDC-26` (1 row) appear on the baseline as soon as
   the ports are constrained (4.9) and were NOT investigated.** They are
   probably artefacts of `set_input_delay` on ports that feed enables -- the
   single `CDC-26` "LUTRAM read/write potential collision" row names
   `rst -> g_dc.rst_s1_reg/D`, which is not a LUTRAM -- but "probably" is not a
   measurement.

7. **`async_fifo` standalone was never run through the flow** -- only through
   `axi_rd_port`, which instantiates it. The two `CDC-6` gray-bus rows and the
   `CDC-3` clear-handshake rows are the FIFO's, so it is covered in substance,
   but a standalone run would also catch a crossing that only exists when the
   FIFO's ports are left unconnected.

8. **`DUAL_CLK = false` was not analysed.** It has no CDC by construction, but
   "by construction" is an argument.

9. **The Part 2 bench runs three clock ratios, all with a FIXED period and a 50%
   duty cycle.** A drifting ratio (spread spectrum, or a real MMCM's jitter) is
   not modelled, exactly as CDC-BENCH recorded for `sim/tb_async_fifo`.

10. **`AXI_DW = 32` and `DEPTH = 16` in the Part 2 bench, against the FK33's 256
   and 512.** The static analysis IS run at 256/512. The properties are
   width-independent, but that is an argument, not a measurement.

11. **No hardware was touched.** Nothing in this file has been observed on the
    card.

---

## 8. Machine cost

Every Vivado invocation ran inside
`systemd-run --user --scope -p MemoryMax=6G -p MemorySwapMax=0`, and
`/usr/bin/time -v` recorded the peak RSS of each. **MEASURED peak across all
21 invocations: 3,407,648 KB = 3.25 GiB**, against the 6 GiB cap and against
the 22.81 GiB a full shell build peaks at. No place and no route was run.
Wall clock is ~90 s per invocation on a quiet box and 3 to 5 minutes with seven
other agents on it.

---

## 9. Corrections

None yet. Append dated CORRECTION sections here rather than editing history.
