# FPGA Hardware Recon: on-fabric LLM inference

Recon notes for extending llama.vhdl beyond the AXU3EG (ZU3EG, 0.95 MB on-chip).
Date: 2026-08-19.

Goal: run a modern transformer with weights resident **on FPGA fabric** (BRAM/URAM)
rather than streamed from DRAM/HBM, to escape the memory-bandwidth wall that caps
batch-1 decode. Secondary goal: evaluate whether an HBM FPGA can host Qwen3.8-27B
directly.

---

## 0. Milestones

Git tags mark shipped state; unshipped rows are the plan.

| Tag | State | Milestone |
|---|---|---|
| `v1.0-silicon` | **done** | stories260K bit-exact on AXU3EG PL, promptable over AXI, ~95.6 tok/s @ 80 MHz |
| `v1.1-server` | **done** | OpenAI endpoint served from the PL engine; 6 prompts byte-identical to `ref/run_fx`, 0 CPU tokens. **End of the llama2 line.** |
| `v2.0` | planned | **Subsystem A**: INT4 streaming matvec on AXU3EG, bit-exact vs C reference |
| `v2.1` | planned | **Subsystem C**: gated attention (GQA 8:2, head_dim 256, QK-norm) |
| `v2.2` | planned | **Subsystem B**: Gated DeltaNet (conv1d k=4, recurrent state, gating) |
| `v3.0` | planned | **Qwen3.5-0.8B end-to-end on AXU3EG**, INT4 from DDR4, ~19-28 tok/s |
| `v4.0` | planned | Qwen3.5-9B on one FK33, INT4 from HBM, ~65-92 tok/s |
| `v5.0` | planned | Qwen3.8-27B on two FK33s, ~45-63 tok/s |

v2.x are the three new subsystems; v3.0 is their integration on hardware already
owned; v4.0 and v5.0 are ports that change the weight streamer and the generics,
not the datapath.

---

## 1. Target model facts (read from the local GGUF, not from docs)

`Qwen3.8-27B-Q4_K_M.gguf`, arch `qwen35`. Verified against the official model card.

| Property | Value |
|---|---|
| Params | 26.896 B (dense, **not** MoE) |
| File size | 18.96 GB (Q4_K_M) |
| Layers | 64, hybrid 3:1 |
| - SSM / Gated DeltaNet layers | **48** (`ssm_*`, `attn_qkv`, `attn_gate`, `ssm_out`) |
| - Full attention layers | **16** (GQA 24:4, head dim 256) |
| Embedding dim | 5120 |
| FFN dim | 17408 |
| Vocab | 248,320 |
| Context | 262,144 native |
| `full_attention_interval` | 4 |
| `ssm_state_size` / `ssm_group_count` | 128 / 16 |

Quantization is **mixed**, which is why the file is 18.96 GB rather than ~13.5 GB:

| Tensor group | Quant | Size |
|---|---|---|
| `ffn_gate/up/down` (all 64 layers) | Q4_K | 9.63 GB |
| SSM path (`attn_qkv`, `attn_gate`, `ssm_out`) | Q8_0 | 5.88 GB |
| `output` (lm_head) | Q6_K | 1.04 GB |
| `token_embd` | Q4_K | 0.72 GB |
| `attn_output` | Q6_K | 0.41 GB |

**Uniform INT4 re-quantization gives ~13.5 GB** (13.87 GB with group-128 fp16 scales).
2-bit gives 6.72 GB. Ternary at 1.58 bits gives 5.31 GB, or 6.72 GB packed as 2 bits.

Per-token weight traffic at batch 1 is ~18.25 GB as-is (everything except the
`token_embd` gather), or ~13.5 GB at uniform INT4.

### Benchmarks (why this model is the target)

| Benchmark | Score |
|---|---|
| Terminal-Bench 2.1 | 73.0 |
| SWE-bench Pro | 61.7 |
| LiveCodeBench v6 | 90.3 |
| OSWorld-Verified | 84.3 |
| GPQA Diamond | 89.2 |

Apache 2.0, released 2026-08-14.

---

## 2. Measured baseline (this workstation, 2x RTX 3090)

Sampled with `nvidia-smi` during a 400-token completion against the running
llama-cpp-server.

| Metric | Value |
|---|---|
| GPU idle, model resident | **61 W** (both cards, range 51-85) |
| GPU during decode | **427 W** mean, 583 W peak |
| Wall during decode | **700 W** (measured at the UPS) |
| Throughput | 46.9 tok/s (this run), 70 tok/s benchmarked with DFlash2 |
| **Energy per token** | **14.9 J/tok** at 46.9, **10.0 J/tok** at 70 |

Efficiency anchor: 39.0 tok/s measured against a 51.3 tok/s theoretical ceiling for
one 3090 = **76% of peak bandwidth achieved**. Useful when projecting FPGA numbers.

---

## 3. eBay finds

All three are ex-mining cards. All require **Vivado ML Enterprise** (see section 6).

| | **SQRL Jungle Cat (JC35)** | **TUL BTU9P** | **SQRL Forest Kitten 33** |
|---|---|---|---|
| **Price** | **$450** | **$500** | **$325** |
| Device(s) | 2x XCVU35P | 1x XCVU9P | 1x XCVU33P |
| BRAM | 2x 47.3 Mb | 75.9 Mb | 23.6 Mb |
| URAM | 2x 180.0 Mb | 270.0 Mb | 90.0 Mb |
| **On-chip total** | **56.8 MB** | **43.2 MB** | **14.2 MB** |
| LUTs (derived) | ~1.74M | 1,182,240 | ~440K |
| DSP slices | 11,904 | 6,840 | 2,976 (derived) |
| **External memory** | **16 GB HBM2** | 64 GB DDR4 | **8 GB HBM2** |
| **Ext. bandwidth** | **920 GB/s** | ~38-77 GB/s | **460 GB/s** (see VCCHBM note) |
| Host interface | PCIe | PCIe | PCIe **x8** |
| Power | check (SQRL designed 300W/chip) | ~250W | **~155W** |
| Cooling | direct liquid | water block | passive/liquid variants exist |
| Ethernet / QSFP | check | check | **none, PCIe only** |
| Availability | one-off listings | one-off listings | **abundant, lots of 100+** |
| Board support repo | `d953i/SQRL_JungleCat` (4 commits, 3 boards) | community | **`d953i/SQRL_FK33` (dedicated, `fk33_example.tcl`)** |
| **MB on-chip per $** | **0.126** | 0.086 | 0.044 |
| **GB/s per $** | **2.04** | ~0.15 | 1.42 |

**FK33 VCCHBM limitation - REVISED 2026-08-20, less severe than first assessed.**
The HBM2 voltage regulator is rated for only **20A**, and TeamRedMiner caps the HBM
clock at **1000 MHz** because of it. An earlier version of this note called that
"power-limited well below rated bandwidth". That was wrong. TRM's own wording is that
the limit constrains "the allowed **overclocking** range":

> "Due to limited voltage regulator capacity for the HBM2 memory parts of the fpga on
> FK33 (20A) and U50C (24A), TRM limits the allowed overclocking range on both these
> cards to what we believe are sensible max values..."

Stock HBM2 on VU33P runs at **900 MHz DDR (1.8 Gbps/pin)**, which is exactly the
460 GB/s spec (2 stacks x 1024 bits x 1.8 Gbps / 8). The 1000 MHz cap is therefore
**above stock**, permitting full rated bandwidth plus ~11% headroom. Stock `vccmem`
is 1200 mV and TRM treats that as fine.

So: **460 GB/s is achievable; the unreachable number is the "up to 610 GB/s"
marketing figure**, which requires OC beyond the regulator's capacity. Plan around
460 GB/s and this is a non-issue. Still worth measuring under sustained 100% HBM duty
cycle, which is a different power profile from a mining bitstream.

Device is the low-power speed grade (`xcvu33p-fsvh2104-2L-e`).

**Voltage tuning (from TRM).** Stock `vccint` 850 mV is "much too high" for typical
silicon; 750-800 mV is common and saves 7-10 W per card. `vccbram` 850-885 mV,
`vccmem` 1200 mV. Relevant for a fleet's power budget.

Derived values: LUT counts computed from system logic cells using the VU9P ratio
(2.1876 LC per LUT); VU33P DSP count halved from VU35P per the die structure.
BRAM/URAM figures are from DS890 and are exact.

Note the family structure: **VU35P = VU33P die + VU11P die**, and the HBM family
scales cleanly 1:2:3 in memory (VU33P 23.6/90, VU35P 47.3/180, VU37P 70.9/270 Mb).

### What each card can hold

Ternary weights packed at 2 bits (preferred over true 1.58-bit; entropy-packed trits
cost a decoder in the critical path for only 26% more capacity).

| Card | On-fabric ternary params | INT4 model in external mem |
|---|---|---|
| Jungle Cat | **227M** (114M per FPGA if no inter-chip link) | **Full Qwen3.8-27B at INT4 (13.5 GB) fits in 16 GB** |
| BTU9P | 173M | fits, but DDR4 bandwidth makes it useless for speed |
| FK33 | 57M | 8 GB holds Qwen3.8-27B at 2-bit (6.72 GB) |

### HBM-path throughput ceilings (batch 1, bandwidth-bound)

| Card | Model | Size | Ceiling | Realistic (~70%) |
|---|---|---|---|---|
| Jungle Cat | Qwen3.8-27B INT4 | 13.5 GB | 68 tok/s | ~48 |
| FK33 | Qwen3.8-27B 2-bit | 6.72 GB | 68 tok/s | ~48 |
| BTU9P | anything | - | ~4-6 tok/s | DDR4-bound |

Both HBM cards land at roughly the same ceiling for their best-fit quantization,
which is comparable to the current 2x3090 rig but at a fraction of the power.

---

## 4. Verdict on the three cards

**Jungle Cat at $450 is the best buy.** Most on-chip SRAM, most LUTs, most DSPs,
HBM instead of DDR4, and cheapest per MB and per GB/s. It is the only card that can
run **both** experiments: weight-stationary on fabric, and full Qwen3.8-27B at INT4
out of HBM for a perf/watt comparison against the 3090s.

**FK33 at $325 is the best fleet candidate.** Single die (no inter-FPGA problem
within a card), the best-documented of the three (dedicated `d953i/SQRL_FK33` repo
with example designs and a build script), lowest power at ~155W, and critically it
is **abundant** - it sells in lots of 100+, whereas the other two are one-off
listings. A fabric needs N identical cards and one bring-up effort, so **you cannot
build a fleet from a card you can only buy once.** Against it: 14.2 MB is only ~57M
ternary params per card, and the VCCHBM power limitation above directly threatens
the HBM path.

### Correction: PCIe-only does NOT prevent a multi-card fabric

An earlier version of this note claimed the FK33's lack of QSFP ruled out multi-board
scaling. That is wrong. Activation handoff between layer groups is tiny (a 2560-wide
hidden state at fp16 is 5 KB), and FPGA-to-FPGA **PCIe peer-to-peer** runs about
2-3 us per hop on x8 Gen3. Across 8 cards that is ~20 us per token against 100+ us of
compute, i.e. under 20% overhead. Workable.

The real requirement is that all cards sit behind a **common PCIe switch**. Crossing
root complexes kills P2P - the same `CNS` (Chipset Not Supported) problem this
workstation already has between GPU0 (CPU PEG) and GPU1 (chipset). So a fleet needs a
PCIe expansion chassis or a server board with a switch, not consumer motherboard
slots. At x8 per card, 8 cards is 64 lanes.

QSFP/Aurora would still be lower latency and avoids the switch requirement, so it
remains preferable where available.

**BTU9P at $500 is the weakest.** Its 64 GB of DDR4 sounds generous but at
~38-77 GB/s it is useless for inference, and it costs more than the Jungle Cat for
less of everything that matters.

### Open questions to resolve before buying

1. **Jungle Cat: is there a direct FPGA-to-FPGA interconnect?** Mining is
   embarrassingly parallel, so mining cards usually leave each FPGA independent.
   If there is no chip-to-chip link, the on-fabric ceiling is **28.4 MB per coherent
   model (114M ternary params)**, not 56.8 MB, because layer handoff would route
   through the PCIe switch and host at ~10-20 us per crossing. Check the XDC in
   `github.com/d953i/SQRL_JungleCat` (covers JC33/JC35/JC13).
2. **Production silicon or engineering sample?** Some mining cards shipped ES parts;
   ES errata will hurt during timing closure.
3. **QSFP present and populated?** Determines whether multi-board scaling is possible
   at all. FK33 is already ruled out (PCIe only).

### Vendor risk

**Squirrels Research Labs filed Chapter 11 in November 2021.** Both SQRL cards are
orphaned: no vendor, no support, no official docs, no warranty. The only resource is
`github.com/d953i/SQRL_JungleCat` (board files, constraints, example designs), which
has 4 commits and 4 stars. Bring-up needs pinout, power sequencing, clock sources,
JTAG chain, and HBM controller config. This is the single largest practical risk.

---

### Fleet option: 8x FK33 at $2,600

FK33 abundance makes a fleet realistic in a way the other two cards do not.

| | Value |
|---|---|
| On-chip fabric | 8 x 14.2 MB = **113.6 MB** (454M ternary params at 2 bits) |
| HBM | 8 x 8 GB = **64 GB**, ~3.68 TB/s nominal aggregate |
| LUTs / DSP | ~3.5M / 23,808 |
| Power | 8 x 155W = **1,240 W**, at the limit of one 15A/120V circuit |
| PCIe | 64 lanes total; needs a switch or expansion chassis |

Both research paths become viable on one fleet:

**HBM path - the real Qwen3.8-27B at INT4, tensor-parallel across 8 cards.**
13.5 GB / 8 = 1.69 GB per card, 3.67 ms per token at 460 GB/s = **272 tok/s ceiling**,
~180 realistic after HBM efficiency and 64 layers of all-reduce (64 x ~3 us = ~192 us,
about 5% overhead). That is 2.6x the current 70 tok/s at ~45% better perf/watt, and it
beats a $2,500 RTX 5090's ~105 tok/s. **The VCCHBM limit could knock this to ~130.**

**On-fabric path - ternary, 454M params across the fleet.** Per-card work is
57M weights at 10.7 T-weights/s = 5.3 us, times 8 sequential plus 7 hops at ~3 us =
~63 us per token, so **~16,000 tok/s theoretical**. At a realistic 5-10% of peak that
is **800-1,600 tok/s**. This is the publishable result.

Recommended fleet entry: **buy two FK33s first and prove PCIe P2P between them**
before committing to eight. That de-risks the single assumption the whole fabric
rests on, for $650.

---

## 4b. FK33 PCIe peer-to-peer feasibility (the load-bearing assumption)

The whole fleet plan rests on FPGA-to-FPGA activation handoff over PCIe being fast
enough. Investigated 2026-08-19. **Verdict: feasible, using standard documented
Xilinx IP.** Details below.

### What the board actually exposes (from `board_files/sqrl_fk33/1.1/sqrl_fk33.xdc`)

The complete board I/O is:

```
SYSCLK0_200_P/N (LVDS 200 MHz)
MAIN_I2C_SCL / MAIN_I2C_SDA
GPIO_LED_0..6_LS
PCIE_PERST, PCIE_100MHZ_CLK_P/N
PCIE_RX_P/N[15:0], PCIE_TX_P/N[15:0]
```

Two conclusions, both from the board file rather than from listings:

1. **16 PCIe lanes are routed**, not 8. Listings say x8; the XDC says x16.
   Confirm against the physical card edge on arrival.
2. **There is no other high-speed I/O.** No QSFP, no SFP, no expansion header, no
   spare GTY brought to a connector. PCIe is definitively the only path off the card.
   (HBM is in-package and needs no pins.)

### The reference design already does most of the work

`projects/fk33_example.tcl` builds a block design using **stock `xilinx.com:ip:xdma:4.1`**
(the standard DMA/Bridge Subsystem, PG195), not a proprietary mining shell. Relevant
config already set:

```tcl
CONFIG.xdma_pcie_64bit_en      {true}
CONFIG.xdma_pcie_prefetchable  {true}   # P2P requires 64-bit prefetchable BARs
CONFIG.axil_master_64bit_en    {true}
CONFIG.axil_master_prefetchable{true}
CONFIG.pcie_blk_locn           {PCIE4C_X1Y0}
CONFIG.axisten_freq            {250}
CONFIG.vendor_id {1E24} / pf0_device_id {1533}
# present but commented out in the example:
# CONFIG.pl_link_cap_max_link_width {X16} ... {8.0_GT/s} ... axi_data_width {512_bit}
```

- **64-bit prefetchable BARs are the two hard prerequisites for P2P, and both are
  already enabled.**
- **HBM is already mapped into the PCIe BAR space**: `xdma/M_AXI` -> smartconnect
  `pcie2hbm` -> `hbm/SAXI_00` and `hbm/SAXI_16`. So a peer writing to this card's BAR
  lands **directly in its HBM**. That is exactly the inbound half of the handoff.
- x16 Gen3 (15.75 GB/s) is a documented config, merely commented out in the example.
- Two `jtag_axi` masters are wired to HBM and AXI-Lite, so HBM can be poked over
  **JTAG with no PCIe at all** during bring-up. Very useful.
- Only 2 of HBM's 32 AXI ports are used in the example; the rest are available.

### The outbound half: AXI Bridge mode + AXIBAR2PCIEBAR

The example uses XDMA in **DMA mode**. For a pipeline you want the FPGA to *initiate*
writes to a peer. Two documented routes:

1. **AXI Bridge mode** (PG194). The IP becomes a bidirectional bridge: it translates
   inbound PCIe into AXI4-MM, **and outbound AXI4-MM into PCIe reads/writes**. The
   `AXIBAR2PCIEBAR_nL/nU` registers (config offsets **0x208-0x234**) substitute the
   PCIe address for the AXI address on outbound transactions. So the datapath issues
   an AXI write to a local aperture and the bridge emits a PCIe posted write to the
   peer's BAR. Constraint: the low 24 bits of `AXIBAR2PCIEBAR_0L` are hardwired to 0,
   so **the aperture must be 16 MB aligned**. Irrelevant here - activations are ~5 KB.
2. **Stay in DMA mode** and program a C2H descriptor whose destination is the peer's
   physical BAR address instead of host RAM. Same mechanism GPUDirect-style P2P uses.

Either way this is standard IP with register-level documentation, not a hack.
**Only one-way posted writes are needed** (card N writes to card N+1, which polls a
doorbell), so no round-trip latency is incurred.

### Expected latency

Published measurements put small-message one-way PCIe latency between an FPGA and a
peer device at **under 2 us**. A posted write through a single switch hop should be
~1-2 us. The earlier 2-3 us per-hop estimate is reasonable, possibly conservative.
Across 8 cards that is ~7-14 us per token against 100+ us of compute.

**Do not use the Vitis/XRT P2P flow.** The official `p2p_fpga2fpga` example measures
116 MB/s and 537 ms for 262 KB on a U200 - that is XRT synchronization overhead, not
PCIe, and it requires a Vitis shell with Resizable BAR that the FK33 does not have.
Bare-metal P2P is both simpler and vastly faster.

### System requirements

- Cards must be **behind a common PCIe switch, or under the same root port**. ACS
  flags on the switch's downstream ports must be cleared, or peer TLPs get bounced
  upstream.
- Linux: `pcie_acs_override=downstream,multifunction` on the kernel command line
  (may need a patched kernel on stock Ubuntu; it is a standard Proxmox patch), or
  disable VT-d in BIOS. Note this collapses IOMMU groups and removes isolation.
- `CONFIG_PCI_P2PDMA` exists in-kernel, but a bare-metal design can simply use the
  peer's physical BAR address directly.
- For 8 cards: a real Broadcom/PLX switch (PEX 8747 48-lane 5-port, PEX 8780 80-lane
  20-port, PEX 8532 8-port; PLX8748-based x16 switch cards are sold commercially).
  These explicitly document peer-to-peer port configurations.

### The 2-card test is possible on THIS workstation

No switch purchase needed to answer the question. Two options on the Z790 AERO G:

- **Both cards in the chipset slots** (PCIEX4_1, PCIEX4_2, Gen4 x4 each = 7.88 GB/s).
  Both sit behind the PCH, which is the closest thing to a common switch on this
  board. Probably the better test.
- **Bifurcate PCIEX16 to x8/x8.** Requires first moving the Samsung root NVMe off
  `M2C_CPU` to a chipset M.2 (#3/#4/#5, Gen4 x4, ample for a Gen3 SM981), which
  restores the CPU slot to x16. The two cards then sit on sibling CPU root ports.

Note the known `CNS` (Chipset Not Supported) result on this box was between GPU0 (CPU
PEG) and GPU1 (chipset), i.e. **across** root complexes - the worst case. Two devices
on the same side is a different and more favourable configuration.

Power: 2 x 155 W = ~310 W added to a 700 W system.

### Residual risks

1. Reference design is DMA mode; AXI Bridge mode is a real (documented) change.
2. ACS override may require a patched kernel on Ubuntu.
3. Intel root-port P2P latency is unmeasured here; could be 2-5 us rather than 1.
4. 8-card scaling still needs a PEX switch or a used server with one.
5. **The VCCHBM 20A limit still threatens the HBM path independently of P2P.**

---

## 4c. Single-card bring-up checklist

**Status: one FK33 ordered 2026-08-19.** One card cannot test P2P (that needs two),
but it *can* answer the two largest open questions in this whole document.

### Programming path

**The FK33 has an onboard USB JTAG port.** TeamRedMiner states it "only communicates
to FPGAs via the USB JTAG ports available on the boards", so no external programming
cable is required for normal use. There is additionally a **JTAG debug header** for
recovering the satellite controller (SC) if an SC firmware flash is interrupted -
openocd-compatible. A failed SC flash makes the board fail to power up but is
recoverable, not bricked.

The FPGA configures from onboard SPI flash (`CONFIG_MODE SPIx4`, `CONFIGRATE 127.5`,
per `sqrl_fk33.xdc`). The repo's `scripts/fk33_jtagaxi.tcl` plus the two `jtag_axi`
masters in the example design let you read/write HBM and AXI-Lite over JTAG with **no
PCIe involvement at all**, which is the safest first step.

### Verify on arrival

1. **Cooling variant.** Passive datacenter heatsink, water block, or a modded active
   cooler? A bare passive fin stack at 155 W needs serious forced air and will cook
   in a quiet desktop. Many owners bolt on a Noctua.
2. **Card edge width.** The XDC routes 16 lanes but listings say x8. Check the
   physical connector.
3. **Aux power connectors.** Confirm count and type before planning the PSU.
4. **USB JTAG enumerates** on the host.
5. **PCIe enumeration with factory bitstream**: `lspci -d 1e24:` (vendor 1E24 SQRL,
   device 1533 in the reference design). May not enumerate if flash is blank.
6. **Silicon grade**: confirm `xcvu33p-fsvh2104-2L-e`, and production vs engineering
   sample.

### Host-side constraints on this workstation

- **Free slot.** Z790 AERO G has one CPU x16 (currently x8, see PCIe topology notes)
  plus PCIEX4_1 and PCIEX4_2 (chipset Gen4 x4). With both GPUs installed only one
  chipset x4 slot is likely free. **Check that slot is open-ended** - a closed x4 slot
  will not physically accept an x16 card.
- **Power.** +155 W on top of a measured 700 W decode load = ~855 W. Check PSU
  headroom, and note the UPS already reports 62% load.
- x4 Gen4 (7.88 GB/s) is fine for bring-up; lane width only matters for P2P later.

### The two experiments that matter

Both are single-card, and between them they govern every downstream decision.

1. **Sustained HBM bandwidth under 100% duty cycle.** Drive all 32 HBM pseudo-channels
   continuously and measure achieved GB/s against the 460 GB/s spec. Mining bitstreams
   have a different power profile, so this needs measuring rather than assuming. Sets
   the ceiling for the HBM path (~180 tok/s projection for an 8-card fleet).
2. **Sustained on-chip read bandwidth with a real MAC array.** Read BRAM+URAM in
   parallel into a ternary multiply-accumulate tree and measure sustained weights/s
   against the ~10.7 T-weights/s theoretical for VU33P. **This is the single number the
   entire on-fabric thesis rests on.** Projections in section 5 assume 5-10% of peak;
   if the real figure is 1%, the fabric plan changes shape entirely.

### Do not start the license clock early

Vivado ML Enterprise offers a 30-day evaluation. Do stage 1 on the AXU3EG (free tools)
and read through `fk33_example.tcl` *before* activating it, so the eval window covers
real work rather than orientation. Repo default branch is `Vivado_2022_2`; board files
reference 2019.2 install paths but should port forward.

---

## 5. Why on-fabric, and what it actually buys

Batch-1 decode is bandwidth-bound: `tok/s = bandwidth / model_size`. On-chip SRAM is
the only escape, which is exactly what Groq and Cerebras built.

Per-device on-chip read bandwidth, reading BRAM and URAM in parallel at 300 MHz
(BRAM is bandwidth-dense, URAM is capacity-dense, so use both):

- VU35P: (1,344 BRAM + 640 URAM) x 72 bits x 300 MHz = **42.8 Tb/s = 21 T-weights/s** at 2 bits
- VU9P: (2,160 + 960) x 72 x 300 MHz = 67.4 Tb/s = 33.7 T-weights/s
- VU33P: (672 + 320) x 72 x 300 MHz = 21.4 Tb/s = 10.7 T-weights/s

To consume 33.7 T-weights/s you need ~112K parallel ternary MACs, roughly 340K LUTs
at ~3 LUT6 each (select/negate plus adder tree). That is under 30% of a VU9P, so
**the fabric can keep up with its own memory**, which is the whole point and the
opposite of every DRAM-based system.

A 227M-param ternary model on the Jungle Cat: 227M / 42 T-weights/s (both dies) =
**5.4 us/token, ~185,000 tok/s theoretical**. Real designs lose heavily to
floorplanning, clock closure, SLR crossings and the sequential layer dependency at
batch 1. At a pessimistic 5% that is still **~9,000 tok/s**; at 1%, ~1,900.

**The unknown that governs everything is what fraction of peak on-chip read
bandwidth a real design sustains.** Answer that before spending anything.

### Why Qwen3.8-27B cannot go on fabric

| Format | Size | VU35P dies needed | Jungle Cat cards |
|---|---|---|---|
| INT4 | 13.5 GB | 475 | 238 |
| 2-bit | 6.72 GB | 237 | 119 |
| Ternary 1.58b | 5.31 GB | 187 | 94 |

At $450/card that is $42k-107k in silicon, ~30-60 kW of power, and a multi-year
build. For reference, Groq needs **576 chips** at 230 MB each for Llama2-70B, and the
only single device that could hold this model on-chip is the **Cerebras WSE-3 at
44 GB of SRAM** (21 PB/s, ~$2-3M). Cerebras runs K2 Think (32B) at exactly
2,000 tok/s and has publicly committed to hosting Qwen3.8-27B on its Shared Tier.

Practical home power ceiling is ~4-8 cards on a dedicated circuit, which caps a
coherent on-fabric model at roughly **1.4B ternary params**. That is
Qwen3-0.6B to 1.5B class, and it must be a **ternary-native** model (BitNet style),
not a post-hoc quantization of Qwen3.8-27B.

---

## 6. The hidden cost: Vivado ML Enterprise

**All three cards are Virtex UltraScale+, which the free Vivado ML Standard edition
does not support.** Enterprise is ~**$2,995/yr node-locked** (tier quoted from
$4,395). The AXU3EG (ZU3EG) is free-tier, so this is a new cost.

This is structural, not listing-specific: every AMD device with more than ~40 MB of
on-chip SRAM is Virtex UltraScale+ or Versal. Intel is the same (Quartus Lite covers
only small devices).

Because the license is a **fixed** cost, it argues for buying several cards at once
rather than one, if the project proceeds at all.

### Open source does not cover these devices

| Project | Covers | Status for VU9P/VU35P |
|---|---|---|
| Yosys | synthesis | Verilog yes; **VHDL only via the incomplete ghdl-yosys-plugin** |
| Project X-Ray | 7-series bitstream | mature, wrong family |
| Project U-Ray | UltraScale/US+ bitstream | **documentation only, not a flow** |
| F4PGA | end-to-end toolchain | **7-series, iCE40, ECP5, EOS-S3 only. No UltraScale.** |
| nextpnr-xilinx | xcup experimental | has URAM288E/DSP48E2 primitives, "experimental flows" |

Three additional blockers: these are **SSI devices** (multiple dies with Laguna
SLR crossings, deep Vivado territory); nextpnr targets ~85K-LUT devices, not 1M+;
and llama.vhdl is **VHDL**, which Yosys handles poorly.

### The way around it: AWS

**EC2 F1/F2 include a licensed Vivado in the FPGA Developer AMI, free for use on
those instances.**

| Instance | FPGAs | Device | Per-FPGA memory | Relevance |
|---|---|---|---|---|
| f1.2xlarge | 1 | **VU9P** | 64 GB DDR4 | same chip as BTU9P; ~$1.65/hr |
| f1.16xlarge | 8 | VU9P | ring interconnect between FPGAs | the 8-board fabric, rentable |
| f2.6xlarge | 1 | **VU47P** | **16 GB HBM** + 64 GB DDR4 | **same HBM family as VU35P** |
| f2.48xlarge | 8 | VU47P | 128 GB HBM total | |

f1.2xlarge at ~$1.65/hr is roughly **1,800 hours of licensed VU9P development for the
price of one Enterprise seat**. F1 is still available (5 regions, no retirement
notice); F2 expanded to four more regions in Nov 2025.

The FPGA-to-FPGA ring is documented for **F1**; the F2 page does not mention an
inter-FPGA interconnect, so do not assume it.

Restriction: the AMI license covers AWS use only. It cannot legally be used to build
bitstreams for a desk board. So it is F1/F2 **or** owned hardware, not a way to
license the SQRL cards.

**If buying the Jungle Cat, develop on F2 (VU47P), not F1.** Same Virtex
UltraScale+ HBM family, so HBM controller config, AXI structure and floorplanning
transfer directly.

---

## 7. Recommended sequencing

1. **Stage 1: AXU3EG, $0, free tools.** Build the ternary weight-stationary datapath
   at 0.95 MB (~4M ternary params) as an evolution of llama.vhdl. This answers the
   sustained-bandwidth question that governs the entire project, at zero cost.
2. **Stage 2: AWS f2.6xlarge (VU47P).** Licensed Vivado, HBM, same family as the
   Jungle Cat. Measure achieved fraction of peak on-chip read bandwidth on a real
   device. A few hundred dollars of instance time.
3. **Stage 3: bring up owned hardware** with a design already known to work.
4. **Stage 4: multi-card**, only if stage 2 efficiency justifies it and the
   interconnect question is resolved favourably.

### Which card, by intent

- **One card to learn on: Jungle Cat ($450).** 4x the fabric, 2x the HBM bandwidth,
  no known VCCHBM problem. Best single device by a wide margin.
- **A fabric: standardize on FK33 ($325).** Availability is the deciding factor -
  Jungle Cats are one-off listings, FK33s move in lots of 100. Also the best
  documented and the lowest power. Buy **two first** and prove PCIe P2P between them
  before committing to eight.
- **BTU9P: skip.** More expensive than the Jungle Cat for less of everything.

Note that at this point the board price is nearly noise: all three carry the same
$2,995/yr license, so a $325 FK33 is a $3,325 decision and a $450 Jungle Cat is a
$3,445 decision. **Pick on capability and availability, not sticker price.**

Buy now regardless of timing - orphaned mining stock does not get restocked - but do
not let a purchase start the clock on a license before stage 1 is done.

### Model side

The on-fabric path needs a **ternary-native** model, co-designed rather than shrunk.
BitNet b1.58 2B4T is the flagship candidate at 2.4B params (600 MB at 2 bits, so
~11 VU13P-class dies, out of reach for a single card). A ~200-500M ternary model is
the realistic single-card target. Whether one exists at usable quality, or needs
training on the 2x3090 rig, is an open question.

---

## Sources

- [Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B)
- [DS890 UltraScale Architecture Product Overview](https://www.mouser.com/datasheet/2/903/ds890_ultrascale_overview-1591529.pdf)
- [Virtex UltraScale+ HBM family](https://www.amd.com/en/products/adaptive-socs-and-fpgas/fpga/virtex-ultrascale-plus-hbm.html)
- [XCVU35P at DigiKey](https://www.digikey.com/en/products/detail/amd-xilinx/XCVU35P-1FSVH2892E/10445746)
- [SQRL_JungleCat board files](https://github.com/d953i/SQRL_JungleCat)
- [SQRL_FK33 board files](https://github.com/d953i/SQRL_FK33) (default branch `Vivado_2022_2`)
- [PG194 AXI Bridge AXIBAR2PCIEBAR registers](https://docs.amd.com/r/en-US/pg194-axi-bridge-pcie-gen3/AXI-Base-Address-Translation-Configuration-Registers-Offset-0x208-0x234)
- [Understanding the PCIe-to-AXI bridge (AXI_BARS vs PCI_BARS)](https://iriscores.com/2021/07/14/understanding-pcie-to-axi-bridge/)
- [Linux PCI P2PDMA docs](https://docs.kernel.org/driver-api/pci/p2pdma.html)
- [Disabling ACS for P2P](https://kubernetes.recipes/recipes/ai/disable-acs-pcie-gpu-direct-p2p/)
- [Vitis p2p_fpga2fpga example (the slow path, avoid)](https://xilinx.github.io/Vitis_Accel_Examples/2022.1/html/p2p_fpga2fpga.html)
- [Broadcom PCIe switches](https://www.broadcom.com/products/pcie-switches-retimers/pcie-switches)
- [FK33 specs](https://www.hashrate.no/fpgas/FK33/specs)
- [TeamRedMiner FPGA guide](https://github.com/todxx/teamredminer/blob/master/doc/FPGA_GUIDE.txt) (VCCHBM 20A / OC range, USB JTAG, voltage tuning)
- [SQRL Chapter 11](https://www.bankruptcyobserver.com/bankruptcy-case/SQUIRRELS-RESEARCH-LABS)
- [Vivado edition device support](https://pcbsync.com/xilinx-vivado-editions/)
- [Vivado licensing](https://www.xilinx.com/products/design-tools/vivado/vivado-ml-buy.html)
- [F4PGA supported architectures](https://symbiflow.readthedocs.io/en/latest/status.html)
- [Project U-Ray](https://prjuray.readthedocs.io/en/latest/)
- [nextpnr-xilinx](https://github.com/gatecat/nextpnr-xilinx)
- [AWS F2 instances](https://aws.amazon.com/ec2/instance-types/f2/)
- [f1.16xlarge specs](https://instances.vantage.sh/aws/ec2/f1.16xlarge)
- [Cerebras 2000 tok/s](https://www.businesswire.com/news/home/20250910137362/en/Cerebras-Sets-New-AI-Speed-Record-on-MBZUAI-and-G42%E2%80%99s-K2-Think-at-2000-TokensSecond-Inference-Performance)
- [FlightLLM](https://arxiv.org/html/2401.03868)
- [TeLLMe v2 ternary edge FPGA](https://arxiv.org/pdf/2510.15926)
