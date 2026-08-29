# Can subsystem A's 27 AXI read masters actually be served on the xcvu33p, and at what bandwidth?

**Date:** 2026-08-28. Branch `fpga`.
**Part:** `xcvu33p-fsvh2104-2L-e`, SQRL FK33, 8 GiB HBM (2 stacks).
**Geometry:** `ROWS_IF = 48`, `AXI_DW = 256`, `BLK = 32` -> 24 weight + 3 scale = 27 AXI read masters.
**Question asked:** subsystem A at the FK33 geometry needs 27 AXI read masters, proven bit-exact in
simulation (`sim/tb_matvec_fk33.vhd`) against 27 behavioural slaves. But
`hw/fk33/build_fk33_pcieep.tcl:219-220` enables only `SAXI_00` and `SAXI_16`, and `pcie2hbm` is
`NUM_SI 2 / NUM_MI 2`. Can 27 masters be served on this part, and at what bandwidth?

**No hardware was touched.** Vivado was run once, in `-mode batch`, to instantiate the HBM IP and
read back its interface list and properties. No programming, no `xsdb`, no `hw_server`.

Every quantity is labelled **MEASURED** (a named tool produced it), **DERIVED** (arithmetic shown)
or **ESTIMATE** (a judgement with its assumption stated).

---

## 0. The answer

**Yes. 27 is not close to the limit and never was. The part exposes 32 HBM AXI slave ports, 30 are
available to the engine after the host takes two, and a 30-port design has already been built,
routed and run on this exact card at 288.0 GB/s -- 100.0% of the arithmetic ceiling, zero non-OKAY
responses. Subsystem A needs 27 of those 30 for a demand of 204.0 GB/s against a 259.2 GB/s supply,
a 78.7% duty. Nothing about the port count invalidates the design and `ROWS_IF` does not have to
change.**

The two-port configuration in `gen_pcieep.py` is not a limit the tool imposes. It is correct for
what that bitstream is: a PCIe host-bringup shell with no engine in it. The HBM IP defaults every
one of its 32 `USER_SAXI_*` parameters to `true`; the pcieep script explicitly turns 30 of them off
because it has nothing to connect them to.

**What the analysis did turn up are three defects that are real and none of which is the port count:**

1. **The HBM SAXI ports are AXI3 with a 16-beat maximum burst.** MEASURED from the IP:
   `CONFIG.PROTOCOL = AXI3`, `CONFIG.MAX_BURST_LENGTH = 16`, i.e. a 4-bit `ARLEN`. The bit-exact
   FK33 bench ran at `MAXB = 128` (`sim/tb_matvec_fk33.vhd:90`), and `rtl/weight_streamer.vhd:175`
   asserts only the AXI4 4 KB rule (`MAXB * AXI_DW/8 <= 4096`), which 128 satisfies. Nothing in the
   RTL enforces 16. `rtl/hbm_tg_ip.vhd:1036-1039` already learned this the hard way and truncates
   `arlen(3 downto 0)` at the pin with a comment saying anything above 15 silently wraps. The A
   path has no equivalent. `docs/2026-08-27_hbm-weight-streamer-design.md:340` already specifies
   `MAXB = 16`; the RTL default is 256 and the verified bench used 128.
2. **`MAXOUT` must rise from 2 to about 12-16.** With bursts capped at 16 beats, sustaining line
   rate needs roughly `(L + 16)/16` bursts in flight. The MEASURED 288.0 GB/s run used
   `ARLEN 15 / OUTST 16` (`hw/fk33/tcl/hbmbw.tcl:136,138`). `rtl/axi_rd_port.vhd:34` defaults
   `MAXOUT = 2`, which is 32 outstanding beats; at an ESTIMATE of 100 ACLK cycles of HBM read
   latency that is about 28% of line rate, and A would get roughly 72 GB/s instead of 259.
3. **`weight_streamer` is single-clock and the FK33 needs it not to be.** `rtl/weight_streamer.vhd`
   header, verbatim: *"STILL OPEN (spec 14.5 item 3): this entity is SINGLE-CLOCK. The FK33's HBM
   AXI clock is not the core clock, and nothing here addresses that CDC."* This is the finding that
   actually costs something, because of the duty arithmetic in section 4.3: if ACLK is forced down
   to `f_core` to avoid the CDC, every port runs at exactly 100% duty with zero margin.

---

## 1. What the existing documents already settle

Read in full: `docs/2026-08-27_hbm-port-contention.md`, `docs/2026-08-27_hbm-residency-map.md`,
`docs/2026-08-27_hbm-weight-streamer-design.md`, `docs/2026-08-27_budgets-at-the-measured-clock.md`,
`docs/debugging/2026-08-28_fk33-subsystem-a-sim.md`.

**Settled, and I found nothing that overturns any of it:**

| claim | where | status |
|---|---|---|
| 30 engine SAXI ports available; `SAXI_00`/`SAXI_16` are the host's | residency map 1.1 | confirmed by IP query and by the pcieep script |
| Port count is a **width** budget, not a bandwidth budget: `NPORT = ROWS_IF x 9/16` | `2026-08-27_hbm-port-count-is-a-width-budget.md` | confirmed against RTL and against the packed model file |
| `ROWS_IF = 48` -> 24 + 3 = 27; `ROWS_IF = 58` -> 33, does not fit | residency map 2, budgets 7.0b | confirmed |
| 288.0 GB/s at 30 ports, 100.0% of ceiling, WNS +0.101 ns | `hw/fk33/results/hbmbw_30port_300mhz.txt:349` | MEASURED, and it is the single most decisive fact in this whole question |
| Per pseudo-channel the fabric access path is 32 B/cycle regardless of how many masters target it | same file, `:358` | MEASURED |
| A/B/C compute windows never overlap; the budget is `27 + max(B,C) = 30` | port contention 0, 2.2, 5.0 | MEASURED with a firing negative control |
| A's port windows probably DO overlap, and there is no drain interlock anywhere in shipping RTL | port contention 2.3, 6 | still open, still the highest-severity item |
| No crossbar, no width conversion, no scheduler is needed once lane count == port count | weight streamer 0, 7.4 | confirmed |
| SmartConnect between A and HBM was already rejected, on latency-skew grounds | weight streamer 6.1 | confirmed, and section 5 below prices it |

**Disagreements found. Where a doc and the RTL or a measurement disagree, the RTL or the
measurement wins.**

- **D1. "The HBM switch is per stack with no cross-stack path" is not what the IP reports.**
  `docs/2026-08-27_hbm-residency-map.md:0` states this as a hardware fact. MEASURED from the IP with
  both global switches enabled (which is this design's `HBMGlobalSwitch 1`): **every one of the 32
  SAXI ports exposes all 32 `HBM_MEM` segments**, i.e. the full 8 GiB, cross-stack included. The
  build scripts then *choose* to assign only 16 segments per engine port
  (`build_fk33_hbmbw.tcl:483-738`) and the pcieep script explicitly `exclude_bd_addr_seg`s the
  cross-stack half from the host masters. So the stack rule is a **design discipline the build
  enforces**, not a property of the silicon, and the residency map's stated reason is wrong.
  **The recommendation does not change** -- port-local (Map A) is what measured 288.0 GB/s and the
  cross-stack lateral path is not characterised on this card by anything -- but the argument for it
  has to be "unmeasured and Xilinx advises against it", not "impossible".
- **D2. The residency map's Map B feasibility check uses a supply figure its own neighbouring
  measurement refutes.** Map B assumes 14.4 GB/s of supply per pseudo-channel and concludes 12.1
  GB/s of demand "fits, with 16% margin". The oversubscription sweep two paragraphs earlier
  MEASURED 9.60 GB/s total into a single pseudo-channel, flat from 1 to 30 masters. Against 9.60,
  Map B does not fit. Map A was already the recommendation; this removes Map B as a fallback.
  (The 14.4 is the *DRAM* rate, `450 MHz x 32 B` -- MEASURED from the IP as
  `CONFIG.USER_AXI_CLK_FREQ = 450`. It is real, and it is unreachable from the fabric.)
- **D3. `weight_streamer` is single-clock; the weight-streamer design doc says "No separate CDC
  block. It is the FIFO."** The RTL header says the opposite in as many words. RTL wins. See 4.3.
- **D4. ACLK is stated as ~450 MHz in the A spec and in budgets 1.2, and as 300 MHz everywhere a
  number was measured.** MEASURED from the IP: `USER_AXI_INPUT_CLK_FREQ` (the fabric-side clock you
  drive) is a parameter, currently 250 in the pcieep script; `USER_AXI_CLK_FREQ` (the IP's internal
  memory-side clock) is 450. **450 is not a clock the user logic ever sees.** The fabric ACLK is
  whatever you drive, and the only value proven on this card is 300 MHz.
- **D5. `rtl/matvec_int4_ip.vhd:143` states `NPORTS_W = ROWS_IF` as "the 6.5 invariant".** That is
  the AXU3EG packaging wrapper at `AXI_DW = 128`, where it happens to be true. The general
  invariant, which `rtl/weight_streamer.vhd:156` asserts correctly, is
  `NPORTS_W * AXI_DW = ROWS_IF * BLK * 4`. At `AXI_DW = 256` that is `ROWS_IF/2`. The wrapper is not
  usable on FK33 for this and several other reasons (one scale base, 4-bit vs 8-bit `ARLEN`).
- **D6. The commit named in the task, `055b6ed`, is not the one the subsystem-A doc records
  (`674da7f`).** Not material to this question; recorded so it is not rediscovered.

---

## 2. The hardware facts, with their sources

### 2.1 MEASURED, from the HBM IP itself

Vivado 2023.2, `-mode batch`, in-memory project on `xcvu33p-fsvh2104-2L-e`, `xilinx.com:ip:hbm:1.0`
configured exactly as `build_fk33_pcieep.tcl:208-212` configures it
(`USER_HBM_DENSITY 8GB`, `USER_HBM_STACK 2`).

| fact | value | how |
|---|---|---|
| HBM AXI slave ports on the IP | **32** (`SAXI_00` .. `SAXI_31`) | `llength [get_bd_intf_pins hbm/SAXI_*]` |
| Default state of `USER_SAXI_nn` | **all 32 `true`** | `get_property CONFIG.USER_SAXI_nn` |
| Per-port data width | **256 bits** | `CONFIG.DATA_WIDTH` on `SAXI_00`, `SAXI_01`, `SAXI_31` |
| Per-port address width | **33 bits** (8 GiB) | `CONFIG.ADDR_WIDTH` |
| Per-port ID width | **6 bits** | `CONFIG.ID_WIDTH` |
| Per-port protocol | **AXI3** | `CONFIG.PROTOCOL` |
| Per-port max burst | **16 beats** | `CONFIG.MAX_BURST_LENGTH` |
| Internal (memory-side) AXI clock | **450 MHz** | `CONFIG.USER_AXI_CLK_FREQ` / `USER_AXI_CLK1_FREQ` |
| Fabric-side ACLK, as requested by this design | **250 MHz** | `CONFIG.USER_AXI_INPUT_CLK_FREQ`, and this is a *request*, not an answer |
| Global switches | both `TRUE` | `USER_SWITCH_ENABLE_00/01` |
| Address segments exposed per port | **32** (`HBM_MEM00`..`HBM_MEM31`, the whole 8 GiB) | `get_bd_addr_segs hbm/SAXI_nn/*`, checked on `SAXI_00`, `SAXI_01`, `SAXI_17` |

DERIVED per-port ceilings, `32 B x f`:

| ACLK | per port | 27 ports | 30 ports | 32 ports |
|---|---|---|---|---|
| 236.128 MHz (`f_core` at `ROWS_IF=48`) | 7.556 GB/s | 204.0 | 226.7 | 241.8 |
| 250 MHz (current IP request) | 8.00 | 216.0 | 240.0 | 256.0 |
| **300 MHz (the only value proven on card)** | **9.60** | **259.2** | **288.0** | 307.2 |
| 450 MHz (IP internal; not reachable from fabric here) | 14.40 | 388.8 | 432.0 | 460.8 |

### 2.2 MEASURED, on this card

`hw/fk33/results/hbmbw_30port_300mhz.txt`, run 2026-08-25, bitstream built from
`build_fk33_hbmbw.tcl`, read out over JTAG-AXI.

```
generator OK, NPORT=30, AXI clock 300.00 MHz
ceiling at NPORT ports = 288.0 GB/s
 ports      beats       cycles         GB/s   %ceiling    die_C stacks
     8   25600000      3200112         76.8     100.0%     29.2 29 29 30 30
    15   48000000      3200178        144.0     100.0%     27.2 30 30 31 31
    30   96000000      3200170        288.0     100.0%     28.2 29 29 31 31
```

- 30 masters, `SAXI_01..15` and `SAXI_17..31`, one per pseudo-channel, both stacks.
- `ARLEN 15` (16 beats, 512 B), `OUTST 16` -- `hw/fk33/tcl/hbmbw.tcl:136,138`.
- Exact beat counts at every point, **zero non-OKAY read responses**, cycle count flat at 3.2 M
  from 8 to 30 ports. Build WNS **+0.101 ns** at 300 MHz.
- Oversubscription sweep, all 30 masters onto one pseudo-channel: **9.60 GB/s total, flat** from
  1 master to 30.

**This is the fact that settles the question.** A 30-master, 30-port design on this exact part with
this exact HBM configuration has been synthesised, placed, routed, closed timing and run. 27 is a
strict subset of it.

### 2.3 What subsystem A needs, DERIVED and cross-checked three ways

Per core cycle, `matvec_core` consumes:

```
weights: ROWS_IF x BLK x 4 = 48 x 32 x 4 = 6,144 bits   (rtl/matvec_core.vhd:78)
scales : ROWS_IF x 16      = 48 x 16     =   768 bits   (rtl/matvec_core.vhd:81-82)
total                                     = 6,912 bits = 864 B = 27 x 256
```

- `NPORTS_W = ROWS_IF x 128 / AXI_DW = 24`
- `NPORTS_S = ROWS_IF x 16 / AXI_DW  =  3`
- `NPORT_A  = ROWS_IF x 144 / 256 = ROWS_IF x 9/16 = 27`, exact, **no clock in it**

Cross-checks:
- RTL: `rtl/weight_streamer.vhd:156` asserts `NPORTS_W * AXI_DW = ROWS_IF * BLK * 4`.
- Bench: `sim/tb_matvec_fk33.vhd:67-69` `NPW = 24`, `NPS = 3`, `AXI_DW = 256`.
- **The packed model file agrees**, which is the check that matters because it is the one thing
  the host and the gateware must both believe. MEASURED, `/mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json`:
  `{'rows_if': 48, 'axi_dw': 256, 'block': 32, 'nports_w': 24, 'n_scale_sub': 3, 'axi_read_masters': 27}`.

Demand, DERIVED at the measured core clock 236.128 MHz (`sim/ooc_sweep/results.csv:8`, OOC synthesis
at 0.717 V):

```
864 B/cycle x 236.128e6 = 204.0 GB/s
```

Against 27 ports at 300 MHz ACLK = 259.2 GB/s: **duty 78.7%, margin 27.1%**.

Ports needed on **bandwidth** alone at 300 MHz: `204.0 / 9.6 = 21.25` -> **22**.
Ports needed on **width** (the lockstep merge takes 27 x 256 bits every core cycle and there is no
drift mode -- `rtl/weight_streamer.vhd:157`, `pop_w <= all_v and w_ready`): **27**.
The binding constraint is width, and 27 < 30. This is the whole answer.

---

## 3. The current pcieep configuration, and why it is not evidence of a limit

`hw/fk33/build_fk33_pcieep.tcl:219-220` sets `USER_SAXI_01..15` and `USER_SAXI_17..31` to `false`.
`:266` sets `pcie2hbm` to `NUM_SI 1 / NUM_MI 2`, raised to `NUM_SI 2` at `:395` when the XDMA is
added. `SAXI_00` and `SAXI_16` carry the host, one per stack, so `xdma` reaches all 8 GiB
(`:269-270`).

**There is no engine in that block design.** `grep -in "llama\|engine" hw/fk33/build_fk33_pcieep.tcl`
returns only `fk33_aux.vhd` and `fk33_thermal.vhd`. The pcieep bitstream's entire purpose is to get
a PCIe link up and prove the host path; it has no AXI read masters to attach. Turning ports on
there would produce a design with 27 enabled `AXI_nn_ACLK` / `AXI_nn_ARESET_N` pins driving
nothing, which is exactly the failure `build_fk33_hbmbw.tcl:373-376` records:

> Every ENABLED SAXI port exposes its own ACLK and ARESET_N pin, and leaving them dangling fails
> hdl generation with 41-758.

So "the pcieep build enables two ports" is a statement about that build's scope, not about the part.

---

## 4. The structural options

### 4.1 Option (a) -- 27 dedicated HBM SAXI ports, one per lane. RECOMMENDED.

Lanes 0..26 map one-to-one onto 27 of the 30 engine ports, each port owning one pseudo-channel and
reading its own 4 KB-aligned sub-region as plain sequential bursts.

- **Bandwidth:** 259.2 GB/s supplied at 300 MHz ACLK against 204.0 GB/s demanded. 78.7% duty.
  MEASURED analogue: the 30-port run, which is this pattern with three more masters.
- **Byte layout:** **unchanged**. The 27 sub-region byte offsets come from the `.mv4i` header
  (`WSUB 0..23`, `SSUB 0..2`); which HBM port reads which sub-region is an arena-placement decision
  in the host loader, not a file-format decision. Spec 6.5a is untouched.
- **Bit-exactness:** **unchanged**. `sim/tb_matvec_fk33.vhd` already models exactly this -- 27
  independent per-port slaves, no shared bus.
- **Cost:** 3 engine ports left for B and C, which is what `docs/2026-08-27_hbm-port-contention.md`
  section 5.1 already sized (`27 + max(3,3) = 30`). Zero spare after that, and D's port
  requirement is still UNKNOWN.
- **What it still needs:** `MAXB = 16`, `MAXOUT ~= 12-16`, the CDC of 4.3, and the drain interlock
  the contention doc calls for.

### 4.2 Option (b) -- fewer HBM ports with a SmartConnect fanning out to 27 masters. REJECT.

- **Bandwidth:** fatal below 22 ports. At `N` ports the supply is `N x 9.6 GB/s` against 204.0
  demanded, so `N >= 22` on aggregate alone -- and 22 gives 211.2 GB/s, a 3.5% margin with an
  arbiter in the path. Saving at most 8 of 30 ports that are not needed.
- **Latency skew is the killer, not bandwidth.** `pop_w <= all_v and w_ready` pops only when all 27
  lanes have a beat. There is no drift mode. A shared arbiter delivers different lanes at different
  times by construction, and the rate is set by the slowest lane, always. The weight-streamer design
  doc already rejected borrowing the two host smartconnect ports for precisely this reason.
- **Structural:** `smartconnect` tops out at 16 SI / 16 MI, so 27 masters is a two-level tree, two
  arbitration hops of latency, on the highest-fanout 256-bit net in the design.
- **Area:** the rev-3 per-port width-conversion path this replaced was costed at ~8 BRAM36 per port
  for the read port alone (weight streamer 7.4). A 27-SI SmartConnect at 256 bits is larger.
- **Byte layout:** unchanged. **Bit-exactness:** unchanged in principle; the risk is throughput and
  the AXI3/AXI4 conversion, not correctness.

### 4.3 Option (b') -- the ONE interconnect question that is not settled: the clock domain

This is not really an option, it is a required decision, and it is the real open item.

`rtl/weight_streamer.vhd` is single-clock. Two ways out:

| | ACLK | supply at 27 ports | duty | verdict |
|---|---|---|---|---|
| run the HBM ports at `f_core`, no CDC | 236.128 MHz | 204.0 GB/s | **100.0%** | **not viable** |
| CDC in the per-lane FIFO, ports at 300 MHz | 300 MHz | 259.2 GB/s | 78.7% | viable, and is what every published number assumes |

DERIVED: at ACLK = `f_core` each lane needs exactly one beat per cycle and each port supplies at
most one beat per cycle. Duty is exactly 100% and every AR gap, refresh stall and latency underrun
is a direct core stall. `27 x 256 = 6,912 = 864 x 8` is not a coincidence; it is the same identity
seen from the other side.

So the CDC is not optional. The FIFO already exists per lane (`stream_fifo` inside `axi_rd_port`);
making it dual-clock is the change, and the RTL says explicitly that it has not been made. The
weight-streamer design doc's claim that "it is the FIFO" describes the intent, not the code.

**Unverified:** that 300 MHz ACLK closes with the *engine* present. The +0.101 ns WNS was measured
on `hbm_tg`, 30 trivial masters and nothing else. 27 masters plus `matvec_core`'s 6,144-bit `w_data`
net plus B, C and D on a monolithic single-SLR die is a materially different physical problem.

### 4.4 Option (c) -- narrower `ROWS_IF` or different `AXI_DW`. NOT REQUIRED, and expensive.

| `ROWS_IF` | weight | scale | ports | of 30 | 9B token (@237.8 MHz) |
|---|---|---|---|---|---|
| 32 | 16 | 2 | 18 | 12 spare | 41.05 ms, **24.4 tok/s** |
| **48** | **24** | **3** | **27** | **3 spare** | **30.49 ms, 32.80 tok/s** |
| 52 | 26 | 4 | 30 | 0 spare | -- |
| 58 | 29 | 4 | 33 | **does not fit** | -- |

- Dropping to 32 costs **26% of token rate** to free 9 ports that are not needed.
- **It changes the byte layout.** `nports_w` and `n_scale_sub` are recorded in the `.mv4i` header of
  every tensor and in `manifest.json`; all 250 tensors would be repacked and the bit-exact result
  re-established. That is the one option here that touches spec 6.5a.
- `AXI_DW` is not a free variable: it is 256 because the HBM SAXI port is 256 bits (MEASURED, 2.1).

### 4.5 Option (d) -- time-multiplex masters onto fewer ports. REJECT for A, ALREADY ADOPTED for B|C.

- **Within A: impossible.** All 27 lanes are consumed in lockstep on the same core cycle. There is
  no idle lane to give a turn to. Time-multiplexing A's lanes means one lane's beats arrive late,
  which by 4.2 stalls all 27.
- **A against B or C: this is already the recommendation** of the contention doc (option 1): the
  3 spare ports carry B's state sweep and C's KV, switched by a 2:1 grant, 16 switches per token,
  drain cost 0.015% of the token. Nothing is muxed off A.
- **Byte layout:** unchanged. **Bit-exactness:** unchanged *if and only if* the drain interlock is
  built. Without it, re-pointing a port with bursts outstanding delivers R beats to the wrong
  master and they look like valid data. That is a silent-wrong-answer, and it is still not in RTL.

---

## 5. Recommendation

**Option (a): 27 dedicated HBM SAXI ports, one arena per pseudo-channel, port-local addressing,
15 lanes on stack 0 and 12 on stack 1 so the three spare ports land together on stack 1.**
`ROWS_IF` stays 48. The packed model file stays as it is.

Numbers:

| | |
|---|---|
| A demand at 236.128 MHz | 204.0 GB/s (DERIVED) |
| Supply, 27 ports at 300 MHz ACLK | 259.2 GB/s (DERIVED from a MEASURED 9.60 GB/s/port) |
| Duty | 78.7% |
| Ports used | 27 of 30 engine ports; 3 left for B\|C |
| Nearest MEASURED point | 30 ports, 288.0 GB/s, 100.0% of ceiling, WNS +0.101 ns |
| Byte layout change | none |
| Bit-exact result change | none |

What it costs, in order of how likely it is to bite:

1. **`MAXB` must be 16, not 128 or 256.** AXI3, 4-bit `ARLEN`. Add the assert next to the existing
   4 KB one in `rtl/weight_streamer.vhd:175` and re-run `sim/tb_matvec_fk33.vhd` at `MAXB = 16` --
   the bit-exact result was established at an illegal burst length.
2. **`MAXOUT` must be ~12-16, not 2.** DERIVED `(L + 16)/16`; the MEASURED 288 GB/s used 16. This
   multiplies the per-lane FIFO depth requirement, and `DEPTH` is already flagged as un-budgeted at
   256 bits (27 FIFOs x 16 KB at `DEPTH = 512`).
3. **A dual-clock `weight_streamer`.** Section 4.3. Without it there is no margin at all.
4. **The drain interlock** of `docs/2026-08-27_hbm-port-contention.md` section 6. Unchanged by
   anything here, still the highest-severity open item, still a data-corruption class.
5. **The control plane.** `rtl/matvec_int4_axi.vhd:252,265` assert `NPORTS_W = 4` and
   `NPORTS_S = 1`. The FK33 needs 24 and 3, i.e. a different register map, plus `hw/mv_driver.c`.
6. **The block design.** 27 masters, 27 `AXI_nn_ACLK`/`ARESET_N`, and 432 `assign_bd_address` calls
   (27 ports x 16 segments) plus the cross-stack exclusions. `build_fk33_hbmbw.tcl:443-738` is the
   worked example; it is 300 lines of generated Tcl.

---

## 6. What was changed

**Nothing.** No RTL, no Tcl, no Python.

`hw/fk33/gen_pcieep.py` was deliberately left alone. The structural question is settled, but the
edit is not, for three named reasons:

- The pcieep block design contains **no engine**, so enabling 27 ports creates 27 undriven
  `AXI_nn_ACLK`/`ARESET_N` pins and fails HDL generation with 41-758.
- The engine's own AXI control plane does not exist at 24 + 3 (`matvec_int4_axi` asserts 4 + 1), so
  there is nothing to connect even if the ports were on.
- pcieep's job is the PCIe link. Breaking it to pre-stage ports for an engine that is not in it
  trades a working bringup bitstream for nothing.

The port enable belongs in the build that first instantiates `llama_top`, together with the address
map, the CDC and the burst-length fix, not ahead of them.

---

## 7. Measured and REJECTED -- do not retry

- **Map B, contiguous arenas crossing pseudo-channels through the stack switch.** REJECTED. Its
  own budget assumed 14.4 GB/s per channel; the MEASURED single-channel figure is 9.60 GB/s
  (`hbmbw_30port_300mhz.txt:358`), so the 12.1 GB/s hot-spot demand does not fit. Map A measured
  100.0% of ceiling; use Map A.
- **SmartConnect between A's lanes and HBM.** REJECTED on latency skew (4.2), not on bandwidth.
  Rejected once already in the weight-streamer design; this note adds the arithmetic and the
  16-SI structural cap.
- **`ROWS_IF = 58`.** REJECTED: 33 ports needed, 30 exist. The killing number was in
  `2026-08-24-transformer-sequencer-design.md` section 2.2 item J since 2026-08-24.
- **`ROWS_IF = 32` as a port-pressure fallback.** NOT REQUIRED: 26% of token rate to free ports
  that were never short.
- **Pricing ports in GB/s.** REJECTED as a category error (`2026-08-27_hbm-port-count-is-a-width-budget.md`).
  Three different GB/s-derived port counts are still in print (28/36, 26/34, 43/33) and all are
  wrong. The count is `ROWS_IF x 9/16` and has no clock in it.
- **`MAXOUT = 12` "is worse on HBM"** -- the weight-streamer doc at `:334` raises this concern about
  in-flight beats; the MEASURED 288 GB/s run used `OUTST 16` with no ill effect. Take 16 unless a
  measurement says otherwise.

## 8. Measurement traps hit

- **Reading `CONFIG.USER_AXI_INPUT_CLK_FREQ` looks like it tells you the ACLK. It does not.** It is
  a request to the IP's timing model. The clock the ports actually run at is whatever is wired to
  `AXI_nn_ACLK` -- in pcieep that is `xdma/axi_aclk` (`:414-415`), in the bandwidth build it is
  `clk_wiz_0/clk_out3` at 300 MHz. The 250 in the script is not a measurement of anything.
- **`USER_AXI_CLK_FREQ = 450` and `USER_AXI_INPUT_CLK_FREQ = 250` are different parameters** whose
  names differ by one word. 450 is the IP's internal memory-side clock and is the source of the
  "~450 MHz HBM AXI clock" claim in the A spec. User logic never sees it.
- **The IP exposing 32 address segments per port does not mean cross-stack traffic is free.** It
  means the decode allows it. The lateral path between the two stack switches is not characterised
  by any measurement on this card, and the 288.0 GB/s run was strictly port-local.
- **`assert ... severity failure` in `weight_streamer` is not a synthesis gate** (project-wide fact:
  Vivado silently ignores it). The `MAXB` rule needs an out-of-range `natural` constant if it is to
  fail a build, per `hw/fk33/rtl/fk33_thermal.vhd:345`.
- **A bit-exact simulation result can be bit-exact at an illegal burst length.** The FK33 bench
  passes at `MAXB = 128` because the behavioural slaves honour 8-bit `ARLEN`. Real HBM does not.

---

## 9. What this note does NOT establish

- **HBM read latency has still never been measured on this card.** Item 1 of the residency map's own
  list. `MAXOUT` sizing, the drain cost and the FIFO depth all scale with it. `hbm_tg` measured
  throughput and `arstall`, not latency (`rtl/hbm_tg.vhd:76-84`).
- **That 300 MHz ACLK closes with the engine present.** The +0.101 ns WNS is `hbm_tg` alone.
- **That 27 masters route.** No synthesis of A at `ROWS_IF = 48` with 27 masters has been run at
  all, in or out of context. The OOC sweep numbers are `matvec_core`, not the AXI front end.
- **Anything about writes.** `hbm_tg` had no write channel for the 30-port run; B's four-master
  pattern and C's 2R+1W are untested by every number in section 2.2. The 11.77 GB/s read/write
  figure is one port on one channel.
- **The cross-stack lateral path's bandwidth or latency.** Exposed by the IP, never measured here.
- **D's HBM port requirement.** Still UNKNOWN, still item 12 of the die-allocation list. The budget
  closes at exactly 30 with zero spare, so any port D needs breaks it. The 545.6 MiB embedding
  table still has no owner named anywhere in the repo.
- **Whether A's port windows overlap B's and C's compute windows.** Still not established, still
  probably yes, still with no interlock in RTL.

---

## 10. Corrections

None yet. Append here with a date; mark superseded claims withdrawn in place rather than deleting
them.

---

## CORRECTION, appended 2026-08-28 evening: the 300 MHz does not hold

**This document's headline answer is WITHDRAWN in its quantitative part.** The
structural answer stands: 27 masters can be served, 32 SAXI ports exist, and a
30-port design really did measure 288.0 GB/s on this card. What does not stand
is the margin.

Every bandwidth figure here rests on **ACLK = 300 MHz**, taken from an
`hbm_tg` build that closed at WNS +0.101 ns **with no engine present**. That
assumption is now measured with the engine present, by out-of-context synthesis
of the real subsystem A at the FK33 geometry
(`docs/debugging/2026-08-28_subsystem-a-ooc-synthesis-at-fk33-geometry.md`,
commit `bbe5e92`):

| | this document | MEASURED |
|---|---|---|
| ACLK | 300 MHz | **189.50 MHz** |
| core | 236.128 MHz | **221.83 MHz** |
| supply | 259.2 GB/s | **163.7 GB/s** |
| demand | 204.0 GB/s | **191.7 GB/s** |
| duty | 78.7%, "27.1% margin" | **117.1%** |

**The array cannot be fed at the measured clocks.** The weight-read phase is
1.246x longer than every figure in this document assumes.

**The design FITS**: 31.65% LUT, 55.03% DSP, 28.65% BRAM, 0 URAM. Area was
never the risk, and this document was right not to treat it as one.

### The reframing that matters

Because `27 x 256 bits = 864 B` exactly, the duty expression has no efficiency
term and reduces to **`duty = f_core / f_axi`**. So there is no absolute ACLK
requirement at all. The requirement is that **ACLK reach the CORE clock**, which
at the measured 221.83 MHz means **221.8 MHz, not 300**. That is 32.3 MHz above
what was measured, a 17.1% gap rather than the 58% that 300 MHz implied.

Chasing 300 MHz would have been over-engineering a safety-critical AR throttle
for headroom the design cannot use, because above `f_core` the core becomes the
binding constraint.

### Where the time goes (MEASURED)

The critical path is `async_fifo/rp_g_s2` -> gray2bin -> subtract -> the
throttle compare `f_level + promised + want <= DEPTH` -> `axi_rd_fsm/this_len`:
16 logic levels, 6 CARRY8, 5.115 ns, 45% logic so the level count is a floor
rather than a routing estimate. **The 6 CARRY8 exist because `f_level` and
`promised` are unconstrained 32-bit `integer`s** (`rtl/axi_rd_fsm.vhd:73-74`,
where `outst` on the very next line IS ranged). Single-clock is 11 levels /
3.095 ns, so the CDC costs 2.02 ns of it.

At 0.85 V it would still be only 243.6 MHz, so **0.773 ns of the miss is logic
depth rather than the undervolt** -- and raising VCCINT is forbidden on this
board regardless.

### Also withdrawn: two area estimates that cancelled

`docs/2026-08-27_die-allocation-at-rows-if-48.md` estimated the streamer at
~7,400 LUT (measured 15,076, **low by 2.04x**) and ~19,700 FF (measured 8,474,
**high by 2.32x**). The two errors nearly cancel, +7,676 LUT against -11,226 FF,
**which is why no total ever looked wrong.** Its BRAM 108 and DSP 0 were exact.

Also wrong in mechanism: `FIFO_DEPTH` is not a BRAM lever. A 256-bit port needs
`ceil(256/72) = 4` RAMB36E2 in SDP and depth is then free, so `DEPTH` 256 and
512 both cost 4 RAMB36.

### What OOC does not settle

No `opt_design`, `place_design` or `route_design`; no other subsystem, no HBM
IP, no XDMA shell, no congestion, no I/O. Congestion only makes timing worse, so
**189.50 MHz is an upper bound on the full build at this ACLK, not a prediction
of it.**

---

## CORRECTION, appended 2026-08-29: it is 28 masters, not 27

**Read at commit `abbd2ed`, working tree clean for `rtl/` and `hw/fk33/rtl/`.**

Everything above is about `rtl/matvec_int4.vhd`, which has
`NPORTS_W + NPORTS_S = 24 + 3 = 27` AXI read masters. That count is correct for
that entity and every bandwidth number above stands.

**But the entity that reaches the FK33's HBM is not that one.** The descriptor
control plane landed at `a4f7e17` as `rtl/matvec_int4_desc_axi.vhd`, and it
carries a **twenty-eighth** master that this document never counted: the
descriptor fetch. MEASURED:

- `rtl/matvec_int4_desc_axi.vhd:182-191` -- the `m_ar*` / `m_r*` arrays, width
  `NPORTS_W + NPORTS_S` = 27 at the FK33 generics (`:103-104`).
- `rtl/matvec_int4_desc_axi.vhd:169-174` -- `d_arvalid` / `d_arready` /
  `d_araddr` / `d_arlen` / `d_arsize` / `d_arburst`, a **separate** read master,
  driven at `:504-505`.
- `hw/fk33/rtl/fk33_engine.vhd:7-8`, the board-facing wrapper's own header:
  *"27 weight/scale AXI read masters + 1 descriptor master = 28 masters, each on
  its own HBM SAXI port, each 256 bits wide."* It instantiates
  `matvec_int4_desc_axi` at `:1156`.

**The consequence is a budget line, not a bandwidth line.** This document's
section 5 summary row reads *"Ports used: 27 of 30 engine ports; 3 left for
B|C"*. At `abbd2ed` that is **28 of 30, and 2 left for B and C.** The same
arithmetic error is carried by `docs/2026-08-28_token-io-path.md:37,323`.

**Not withdrawn:** the 288.0 GB/s at 30 ports measurement, the SmartConnect
rejection, the AXI3 16-beat cap, and the structural answer that the part can
serve this many masters. 28 is still below the 30 that were measured together.

**MEASURED separately and it is the reason this correction is not comfortable:**
the first shell build carrying these 28 masters **does not route**
(`[Route 35-3] global congestion level 7`, worklog OI-12,
`docs/debugging/2026-08-29_fk33-shell-integration-does-not-route.md`). This
document's own closing section says congestion only makes timing worse and that
its figures are an upper bound; that caveat is now a measured outcome rather
than a caveat.

**NOT verified here:** whether the descriptor master needs a dedicated HBM SAXI
port at all, or could share one with a scale port given its duty cycle. Nobody
has costed that, and it is the obvious way back to 3 free ports.
