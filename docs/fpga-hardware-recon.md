# FPGA Hardware Recon: on-fabric LLM inference

Recon notes for extending llama.vhdl beyond the AXU3EG (ZU3EG, 0.95 MB on-chip).
Date: 2026-08-19. **Revised 2026-08-21**: Jungle Cat re-characterised as a carrier plus
modules (section 3), Varium C1100 added as a fourth candidate, a standing skip rule
added for the VU9P/DDR4 class, and section 6 rewritten for AMD's 2026.1 licensing
tiers (the old $2,995 Enterprise figure was obsolete).

Goal: run a modern transformer with weights resident **on FPGA fabric** (BRAM/URAM)
rather than streamed from DRAM/HBM, to escape the memory-bandwidth wall that caps
batch-1 decode. Secondary goal: evaluate whether an HBM FPGA can host Qwen3.8-27B
directly.

---

## 0. Milestones

**Retargeted 2026-08-21.** The goal is now **Qwen3.8-27B at INT4 on FK33
hardware**, reached in two rungs. The earlier 0.8B/9B ladder is superseded: it
was built around the AXU3EG being the only owned hardware, which is no longer
the constraint.

| Tag | State | Milestone |
|---|---|---|
| `v1.0-silicon` | **done** | stories260K bit-exact on AXU3EG PL, promptable over AXI, ~95.6 tok/s @ 80 MHz |
| `v1.1-server` | **done** | OpenAI endpoint served from the PL engine. **End of the llama2 line.** |
| `v2.0` | planned | **Subsystem A**: INT4 streaming matvec, bit-exact vs C reference. **Validated on the AXU3EG** (136 of 360 DSP, free Vivado tier) before any FK33 work. |
| `v2.1` | planned | **Subsystem C**: gated attention (GQA 24:4, head_dim 256, QK-norm, fused gate) |
| `v2.2` | planned | **Subsystem B**: Gated DeltaNet (48 of 64 layers) |
| `v2.3` | planned | **Subsystem E**: tensor-parallel collectives over PCIe P2P. New. |
| `v2.4` | planned | **Subsystem D**: transformer sequencer |
| **`v3.0`** | **planned** | **Qwen3.8-27B INT4 on 2x FK33 (16 GiB HBM), ~43-61 tok/s.** The FIRST goal. |
| **`v4.0`** | **planned** | **Qwen3.8-27B INT4 on 8x FK33, ~140-170 tok/s.** The END goal. |

### Why two cards is the first rung

**It is the minimum configuration that runs the model at all.** One FK33 holds
8 GiB; the 27B at INT4 is 14.09 GiB. Two cards is not an arbitrary step, it is
the floor.

Per card, tensor-parallel across 2:

| | Per card |
|---|---|
| Weight shard | **7.04 GiB** |
| GDN state, 48 layers sharded by head (24 of 48) | ~38 MB |
| KV cache @ 2048 ctx, sharded (2 of 4 kv heads) | ~36 MB |
| **Total** | **~7.11 GiB of 8 GiB = 89%** |

11% headroom: sufficient, not comfortable. **Verify by quantizing the model to
subsystem A's exact format and measuring the packer output** before committing
hardware. 4.5 bpw includes the per-32 scale overhead but not real padding and
alignment.

**Sharding is exact at N=2 and needs replication at N=8:**

| Quantity | 27B | / 2 | / 8 |
|---|---|---|---|
| Query heads | 24 | 12 | 3 |
| **KV heads** | **4** | **2** | **0.5 -> 2x replication** |
| GDN value heads | 48 | 24 | 6 |
| GDN key heads | 16 | 8 | 2 |
| FFN dim | 17408 | 8704 | 2176 |

So N=2 is the clean case in every dimension, which makes it the right place to
prove the collective layer before the topology gets harder.

### Honest performance expectation for v3.0

Per card reads 7.57 GB per token; at 460 GB/s that is 16.5 ms, a **61 tok/s
ceiling**, and roughly **43 tok/s at 70% efficiency**. Collectives are
negligible at N=2 (a single peer exchange, 128 x 2 x ~1.5 us = 0.4 ms).

**That is slower than the 70 tok/s the workstation's two RTX 3090s already
deliver.** The wins are power (310 W of cards against 700 W at the wall, so
~1.2-1.6x better J/token) and cost ($650 of cards), plus it being the research
goal. Rung one is not a speed upgrade and should not be defended as one.
Tensor-parallel, not pipeline: PP at batch 1 runs cards sequentially and halves
throughput to ~30 tok/s.

### What the AXU3EG is still for

**Subsystem A validation only.** A alone is 136 of 360 DSP, fits trivially, and
runs on the **free** Vivado tier. It validates the INT4 matvec numeric contract
and its C reference on hardware that already produces bit-exact results. That is
cheap insurance against debugging a nine-review-round contract for the first
time on orphaned silicon behind a paid toolchain. It does not gate the FK33 path
and the earlier A+B+C co-fit question is now moot, since the full model never
runs there.

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

Prices updated 2026-08-21 from actual listings. All the SQRL/TUL cards are ex-mining
and need a paid Vivado tier (see section 6, **rewritten 2026-08-21** - the old
$2,995 Enterprise figure is obsolete). The Varium C1100 is a new fourth candidate
added 2026-08-21; it is the only one that is an official, still-documented product.

| | **SQRL Jungle Cat (JC35)** | **AMD Varium C1100** | **SQRL Forest Kitten 33** | VU9P/DDR4 class |
|---|---|---|---|---|
| **Price** | **$425** | ~$1,000 new | **$300** | $495-500 |
| What it is | **carrier + 2 modules** | single PCIe card | single PCIe card | single PCIe card |
| Device(s) | 2x XCVU35P | 1x XCU55N (VU35P class) | 1x XCVU33P | 1x XCVU9P |
| BRAM | 2x 47.3 Mb | 47.3 Mb | 23.6 Mb | 75.9 Mb |
| URAM | 2x 180.0 Mb | 180.0 Mb | 90.0 Mb | 270.0 Mb |
| **On-chip total** | **56.8 MB** | 28.4 MB | **14.2 MB** | 43.2 MB |
| LUTs | 2x 872K = ~1.74M | 872K | ~440K | 1,182,240 |
| DSP slices | 11,904 | 5,952 | **2,880** (measured) | 6,840 |
| **External memory** | **16 GB HBM2** | 8 GB HBM2 | **8 GB HBM2** | 64 GB DDR4 |
| **Ext. bandwidth** | **920 GB/s** | 460 GB/s | **460 GB/s** (see VCCHBM note) | ~38-77 GB/s |
| Host interface | **JCC2L Lite: Ethernet only, no PCIe** (confirmed from listing photos). Module reaches host only via BMC UART/I2C | PCIe Gen3 x16 / Gen4 x8 | PCIe (XDC routes x16) | PCIe |
| Off-card serial | Aurora refclk, no connector found | **2x QSFP28, 8x 25 Gb/s** | **none, PCIe only** | check |
| Power | 260W TDP **per module** | **75W max** | **~155W** | ~250W |
| Cooling | liquid / carrier fans | **passive, single slot, HHHL** | passive/liquid variants exist | water block |
| Availability | one-off listings | distributor stock | **abundant, lots of 100+** | common |
| Board support | **one XDC file, nothing else; not supported by TeamRedMiner** | DS1003, board files, XRT | **`d953i/SQRL_FK33` (dedicated, `fk33_example.tcl`)** | VCU1525 clone, official Xilinx files mostly apply |
| Vendor | **bankrupt 2021** | AMD, supported | **bankrupt 2021** | TUL / SQRL |
| **MB on-chip per $** | **0.134** | 0.028 | 0.047 | 0.087 |
| **GB/s per $** | **2.16** | 0.46 | 1.53 | 0.16 |

### Standing rule: skip the VU9P + DDR4 class on sight

BCU1525, BTU9P, VCU1525 and every other VU9P-with-DDR4 mining card is the same
decision, and these listings recur constantly. **The answer is always no**, at any
price in the $300-600 band, and it takes no re-evaluation:

- ~38-77 GB/s of DDR4 caps batch-1 decode at **~4-6 tok/s**. It is 12-24x short of
  the HBM cards on the one axis that governs decode.
- 64 GB sounds generous but is a mining artifact. It holds the model; it cannot feed
  the datapath.
- It carries the **same paid Vivado tier** as the HBM cards, so the board price is
  the small half of the decision either way.

The one thing the class has going for it: the **SQRL BCU1525 is a VCU1525 clone**, so
official Xilinx board files, XDC and the SDAccel/Vitis shell largely apply - better
documented than either orphaned SQRL HBM card. It does not matter. Bandwidth is what
kills it, not bring-up difficulty. Buy an HBM card instead.

### Jungle Cat is a carrier plus modules, not a card (found 2026-08-21)

This reframes the entry above and was not understood when the table was first written.
The sole file in `d953i/SQRL_JungleCat/constraints/` is named **`JCCL2-JCM35.xdc`**:
carrier `JCCL2` + module `JCM35`. The XDC confirms the split in its own comments:

```
sysclk_clk_p       # System Clock (onboard)    <- on the module
sysclk_ext_clk_p   # System Clock (on carrier)
sysclk_ext2_clk_p  # System Clock 2 (on carrier)
jcm_sync           # "GPIO chained across all modules to BMC"
uart_rx / uart_tx  # UART to BMC
```

"Chained across all **modules**" plus a BMC means the carrier holds N mezzanine
modules and a management controller. SQRL sold the same carriers with Intel Stratix 10
modules (JCM-M2116, JCM-G28), so **JCM is a module family and JCC is a carrier
family** - and the Jungle Cat name spans both Intel and Xilinx silicon. The 56.8 MB
and 920 GB/s in the table are therefore **a carrier populated with two VU35P modules**,
not one PCB.

**Confirmed for the $425 listing:** carrier populated with two
`XCVU35P-FSVH2104AAZ`. So the silicon figures hold.

**Open question #1 in the old text is now probably answered: yes, there is an
inter-FPGA path.** The XDC constrains an Aurora reference clock:

```
set_property PACKAGE_PIN AD38 [get_ports aur_ref_clk_p]
# MGT- don't need to set constraints- pinout is handled in the IP
```

A dedicated Aurora refclk means GTY serial links were designed in, so the modules are
likely linked directly rather than being independent islands. That argues for the full
**56.8 MB per coherent model**, not 28.4. Not proof - the XDC does not say what the
link terminates at - but it is the strongest evidence available.

### The carrier family, and why the XDC has no PCIe (resolved 2026-08-21)

Recovered from archived SQRL store pages (the store domain is dead; these came out of
the Wayback Machine). SQRL shipped **three** carriers:

| Carrier | Capacity | Modules | Host connectivity |
|---|---|---|---|
| **JCC4P Rev AB** | 1000W | up to 4, **connected in a high-speed ring** | PCIe, Ethernet, or USB. "Recommended for HBM JCMs" |
| **JCC2P Rev B** | 1000W | 2, connected at high speed | PCIe, Ethernet, or USB. "Recommended for compute intensive JCMs" |
| **JCC-Lite (JCC2L)** | 960-1000W | up to 2 | **Ethernet only.** "Requires mining computer or Raspberry Pi on network" |

Module spec from the same pages: **260W TDP, VCC up to 300A continuous** (the Stratix
GX module was 350W/350A, so the carriers are sized for far more than a VU35P draws).

**This explains the missing PCIe constraints.** The only public constraints file is
named `JCCL2-JCM35.xdc` - JCC-Lite, 2-slot. It has no `PCIE_PERST` and no PCIe refclk
because **that carrier has no PCIe**. The file is not incomplete; it is complete for an
Ethernet-only carrier. TeamRedMiner's platform list says the same thing from the other
direction: "JC33, JC35, JC13 on **JCC2L/F** carriers".

It also confirms the Aurora finding independently: "4 JCMs connected in a **high-speed
ring**" on the JCC4P is what `aur_ref_clk_p` is for. The inter-module link is real.

**The bind: you get the XDC or you get PCIe, not both.**

- **Listing is a JCC2L (Lite):** you have the one XDC, but the host path is Ethernet.
  **None of section 4b transfers** - no XDMA, no BAR-mapped HBM, no PCIe P2P. You would
  be writing a network stack or driving the carrier from a separate machine on the LAN.
- **Listing is a JCC2P or JCC4P:** you get PCIe (and on the 4P, a 4-module ring), but
  **no XDC exists for those carriers**. The carrier-side pins - `sysclk_ext`,
  `sysclk_ext2`, `jcm_sync`, the BMC UART, fan control - are precisely the ones that
  would differ between carriers.

Identifying the carrier is therefore not a detail; it decides which half of the problem
you inherit. **Ask for the carrier silkscreen marking and a photo of the rear bracket:
RJ45 only means Lite, a PCIe card edge means 2P or 4P.**

### CONFIRMED 2026-08-21: the $425 listing is a JCC2L Lite - Ethernet only, no PCIe

Listing photos show an Ethernet port and nothing else. That resolves the fork above to
the worse branch, and two further findings make this card a **skip**.

**1. The module has no host data path, only a control path.** The complete set of
module-to-outside connections in the XDC is:

```
uart_rx / uart_tx     # to BMC
IIC (local, to PMIC) + GIIC (global chain)
jcm_sync              # GPIO chained to BMC
aur_ref_clk_p         # Aurora MGT refclk
clocks in, LEDs, fan_ctl / fan_sense, err_vccint
```

No Ethernet pins, no PCIe pins. **The RJ45 is on the carrier, terminated by the BMC,
which relays to modules over UART and I2C.** That is why the store copy says "requires
mining computer or Raspberry Pi on network". For mining this is a sound design - an
ethash job header is ~80 bytes and a nonce is 8, so host bandwidth of ~zero is fine.
For anything that has to move weights it is a control channel, not a data channel.

**2. TeamRedMiner never supported the Jungle Cat.** TRM's `FPGA_GUIDE.txt` v1.2 (2022)
lists Varium C1100, FK33, U50C/ECU50, TH53/55 and Osprey E300 - **no Jungle Cat, no
JC35, no JCC carrier** - and states it "only communicates to FPGAs via the USB JTAG
ports available on the boards", which the Lite carrier does not have. The
`todxx/teamredminer` issue asking how to run JC35 on JCC2L is **still unanswered**.
The original owner's ethash setup ran on SQRL's proprietary stack (SQRL bitstreams,
SQRL BMC firmware, SQRL host software), all of which died with the company in 2021.
**No public programming path for this platform exists.**

**What would still work, and what would not.** Bandwidth is not the blocker for the
headline experiment: the on-fabric ternary path keeps weights in BRAM/URAM, and
prompt-in / token-out is a few hundred bytes, which a UART handles trivially - the same
shape as the current AXU3EG design. The **HBM path dies here**, since loading 13.5 GB
through a BMC UART is not viable.

**You cannot dodge the load by baking weights into the bitstream.** On UltraScale+,
**URAM cannot be initialized from the bitstream** the way BRAM can (verify against
UG573 before relying on this). Of 28.4 MB per module only 47.3 Mb (5.9 MB) is BRAM and
initializable; the 180 Mb (22.5 MB) of URAM must be written at runtime. At ~100 KB/s
over a 1 Mbaud UART that is ~4 minutes per module per power cycle - survivable, but a
real constraint, **and it applies to every card in this document, not just this one.**

**The actual blocker is configuring the FPGA at all.** You need JTAG. The BMC
presumably drives JTAG to each module (that is how SQRL loaded bitstreams over
Ethernet), but the protocol is undocumented, the firmware is proprietary, the vendor is
gone, and nobody has reverse-engineered it. The only escape is a **physical JTAG header
on the module or carrier** - a 2x7 0.1" Xilinx header or a 2x5 ARM 10-pin. If one is
present this is hard but tractable; if not, it is silicon that cannot be configured.

**Verdict: skip.** Not because the silicon is wrong - $425 for 2x VU35P and 16 GB of
HBM is the cheapest fabric per dollar in this document - but because the work would be
reverse-engineering a dead vendor's BMC rather than building a matvec engine. The FK33
(already ordered) has USB JTAG, a working `fk33_example.tcl`, and `fk33_jtagaxi.tcl`
for poking HBM with **no PCIe at all**, and it answers both section 4c experiments. Per
section 7, owned hardware is Stage 3 anyway, so there is no reason to buy a hard board
now.

**Hazard: the fan is under bitstream control.**

```
set_property PACKAGE_PIN G9 [get_ports fan_ctl]
set_property PULLDOWN TRUE  [get_ports fan_ctl]
set_property PACKAGE_PIN H9 [get_ports fan_sense]
```

Fan PWM and fan sense are fabric I/O and `fan_ctl` defaults low. A first-light
bitstream that does not drive `fan_ctl` can leave cooling off on a module rated at
260W TDP / 300A VCC. There is an `err_vccint` overtemp/overcurrent input from the PMIC
(marked "A3 only", so board revisions exist) but it is an input to the fabric, not a
hardware interlock. **Drive the fan and monitor `err_vccint` in the very first
design.** This is a burn-the-card-in-minutes failure mode, not a nuisance.

**Speed grade is unknown.** Catalog ordering part numbers for this package are
`XCVU35P-1FSVH2104E`, `-2FSVH2104E`, `-L2FSVH2104E`, `-3FSVH2104E`. The listing's
`XCVU35P-FSVH2104AAZ` has **no speed grade in the normal position** and a non-catalog
`AAZ` suffix, so it is either a package top-mark or a custom SKU. Vivado needs the
exact part including speed grade to close timing. Get a clear photo of the die
top-mark, or assume `-1` and treat any better result as upside.

**Rest of the board I/O** (complete, from the XDC): local I2C to the PMIC (voltage
tuning, same lever as the FK33 `vccint` note), a global I2C chain, a secondary SPI
flash, 4 discrete LEDs plus an RGB LED, and SPIx4 config at 127.5 MHz with
`SPI_FALL_EDGE` and bitstream compression - the same fast-config trick the FK33 uses so
the FPGA is up before PCIe enumeration.

### There is no bring-up documentation, and this was checked exhaustively

Searched 2026-08-21. The negative result is solid, so **do not spend time looking
again**:

| Source | Result |
|---|---|
| Wayback sweep of all `*.squirrelsresearch.com` (874 archived URLs) | **Zero PDFs, zero .zip, zero datasheets.** No Jungle Cat page on the main site at all - only Acorn, BCU1525, CVP-13, FK33 |
| `support.squirrelsresearch.com` (Freshdesk) | Archived but nearly empty: two categories still carrying template text ("A description of the overall category goes here") and **two articles, both about the Acorn** |
| `d953i/SQRL_JungleCat` | `README.md` (2 lines) + `constraints/JCCL2-JCM35.xdc`. That is the whole repo |
| GitHub search (JCM35 / JCCL2 / JungleCat) | No other repositories |
| Archived store product pages | Marketing blurbs only - but they are the source of the carrier table above, which is the single most useful artifact found |

SQRL's documentation was thin while the company was still trading, and it went
Chapter 11 in November 2021. **There is no manual to find.** The complete set of
available material is: the one XDC, the archived store blurbs, and TeamRedMiner's
`FPGA_GUIDE.txt`.

The entire `d953i/SQRL_JungleCat` repo is two files:

```
README.md                      (2 lines)
constraints/JCCL2-JCM35.xdc    (for the Ethernet-only Lite carrier)
```

No board files, no example block design, no build script, no JTAG-AXI helper. Compare
`d953i/SQRL_FK33`, which ships `board_files/sqrl_fk33/1.1/`, a working
`projects/fk33_example.tcl` (XDMA to HBM, 64-bit prefetchable BARs, two `jtag_axi`
masters) and `scripts/fk33_jtagaxi.tcl`. **That gap is the real cost of the Jungle Cat,
and it dwarfs the $125 price difference against the FK33.**

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
| Jungle Cat (2 modules) | **227M** (114M per module if the Aurora link is not usable) | **Full Qwen3.8-27B at INT4 (13.5 GB) fits in 16 GB** |
| Varium C1100 | 114M | 8 GB holds Qwen3.8-27B at 2-bit (6.72 GB) |
| FK33 | 57M | 8 GB holds Qwen3.8-27B at 2-bit (6.72 GB) |
| VU9P/DDR4 class | 173M | fits, but DDR4 bandwidth makes it useless for speed |

### HBM-path throughput ceilings (batch 1, bandwidth-bound)

| Card | Model | Size | Ceiling | Realistic (~70%) |
|---|---|---|---|---|
| Jungle Cat | Qwen3.8-27B INT4 | 13.5 GB | 68 tok/s | ~48 |
| Varium C1100 | Qwen3.8-27B 2-bit | 6.72 GB | 68 tok/s | ~48 |
| FK33 | Qwen3.8-27B 2-bit | 6.72 GB | 68 tok/s | ~48 |
| VU9P/DDR4 class | anything | - | ~4-6 tok/s | DDR4-bound |

All three HBM cards land at roughly the same ceiling for their best-fit quantization,
which is comparable to the current 2x3090 rig but at a fraction of the power. The
ceiling is set by bandwidth, so the Jungle Cat's extra silicon buys **capacity and
compute headroom, not decode speed**, once you are streaming from HBM.

---

## 4. Verdict on the cards

**Revised 2026-08-21.** The earlier verdict called the Jungle Cat "the best buy" on
per-dollar silicon alone. That still holds on the metrics, but the bring-up cost was
badly underestimated, and a fourth candidate now exists.

**Jungle Cat at $425 has the best silicon per dollar and the worst bring-up story.**
Most on-chip SRAM, most LUTs, most DSPs, 920 GB/s, and cheapest per MB and per GB/s by
a wide margin. It is the only option that can run **both** experiments: weight-stationary
on fabric, and full Qwen3.8-27B at INT4 out of HBM for a perf/watt comparison against
the 3090s. Against it: a two-line README and a single XDC, a dead vendor, an
**unconfirmed host interface** that may not be PCIe at all, an unknown speed grade, a
fan under bitstream control at 260W per module, and a carrier/module architecture with
no public documentation. This is the highest-ceiling and highest-risk option, and it
is not a first board.

**FK33 at $300 is the best fleet candidate.** Single die (no inter-FPGA problem
within a card), the best-documented of the SQRL cards (dedicated `d953i/SQRL_FK33` repo
with example designs and a build script), lowest power of the mining cards at ~155W,
and critically it is **abundant** - it sells in lots of 100+, whereas the Jungle Cat is
a one-off listing. A fabric needs N identical cards and one bring-up effort, so **you
cannot build a fleet from a card you can only buy once.** Against it: 14.2 MB is only
~57M ternary params per card, and the VCCHBM power limitation above directly threatens
the HBM path. **One is already ordered (2026-08-19); see section 4c.**

**Varium C1100 at ~$1,000 is the low-risk option, and the case for it is stronger
than the price suggests.** Same VU35P-class silicon as one Jungle Cat module
(`XCU55N-FSVH2892-2L-E`, 872K LUTs, 5,952 DSPs, 28.4 MB on-chip, 8 GB HBM2 at
460 GB/s), but as an official AMD product with a datasheet (DS1003), board files and
XRT support. Three things it has that no mining card does:

1. **2x QSFP28 (8x 25 Gb/s).** Section 4b concluded PCIe P2P is workable but needs a
   PCIe switch and ACS overrides, while noting "QSFP/Aurora would still be lower
   latency and avoids the switch requirement". The C1100 has exactly that, natively,
   with documented Aurora IP behind it. It removes the single load-bearing assumption
   of the whole fleet plan.
2. **75W max, passive, single-slot HHHL.** It drops into the one free chipset x4 slot
   on this workstation with no power or cooling project attached. Compare 155W (FK33)
   or 260W per module (Jungle Cat, liquid).
3. **A vendor that still exists.** Documentation, errata, forum answers.

Against it: 2-3x the price per card, half the on-chip memory of a Jungle Cat, and its
device does not always appear in stock Vivado part lists without the board file. Note
also that the free one-year Vivado Pro (Alveo tier) subscription goes with a **new**
purchase, not a used card.

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

**The VU9P/DDR4 class is the weakest and needs no further evaluation.** See the
standing rule in section 3. 64 GB of DDR4 sounds generous but at ~38-77 GB/s it is
useless for inference, and it costs more than the Jungle Cat for less of everything
that matters.

### Open questions to resolve before buying (updated 2026-08-21)

1. ~~**Jungle Cat: is there a direct FPGA-to-FPGA interconnect?**~~ **Probably yes.**
   The XDC constrains an Aurora reference clock (`aur_ref_clk_p`, AD38), so GTY serial
   links were designed in. Treat the on-fabric ceiling as **56.8 MB**, with 28.4 MB as
   the downside case if the link turns out to terminate somewhere useless.
2. ~~**Jungle Cat: which carrier is it?**~~ **ANSWERED: JCC2L Lite, Ethernet only.**
   Confirmed from listing photos 2026-08-21. This makes the card a skip - see the
   subsection in section 3. The remaining question, if anyone revisits it, is whether a
   **physical JTAG header** exists on the module or carrier; without one the FPGA cannot
   be configured at all.
3. **Jungle Cat: what speed grade?** `XCVU35P-FSVH2104AAZ` is not a catalog ordering
   part number and carries no speed grade. Vivado needs it to close timing.
4. **Production silicon or engineering sample?** Some mining cards shipped ES parts;
   ES errata will hurt during timing closure.
5. **QSFP present and populated?** Determines whether multi-board scaling is possible
   without a PCIe switch. FK33 is already ruled out (PCIe only). Jungle Cat has an
   Aurora refclk but **no QSFP connector has been confirmed**. The Varium C1100 is the
   only candidate with QSFP28 confirmed from a datasheet.

### Vendor risk

**Squirrels Research Labs filed Chapter 11 in November 2021.** Both SQRL cards are
orphaned: no vendor, no support, no official docs, no warranty. The only resource is
`github.com/d953i/SQRL_JungleCat` (board files, constraints, example designs), which
has 4 commits and 4 stars. Bring-up needs pinout, power sequencing, clock sources,
JTAG chain, and HBM controller config. This is the single largest practical risk.

---

### Fleet option: 8x FK33 at $2,400

FK33 abundance makes a fleet realistic in a way the other cards do not. (Price updated
2026-08-21: $300/card, so $2,400 not $2,600.)

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
rests on, for **$600**.

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

### JTAG-only bring-up: confirmed viable (2026-08-22)

Repo cloned to `~/GitHub/SQRL_FK33` (default branch `Vivado_2022_2`; an older
`Vivado_2019_2` branch also exists). **Both section 4c experiments are reachable over
JTAG alone**, so first light needs nothing resolved about PCIe, ACS or P2P. Four
independent confirmations:

**1. The example design has an explicit switch.** Line 5 of `projects/fk33_example.tcl`:

```tcl
set EnablePCIe 1
set HBMGlobalSwitch 1
```

Set `EnablePCIe 0` for a PCIe-free build.

**2. JTAG reaches HBM directly.** Despite the smartconnect being named `pcie2hbm`, its
only slave is the JTAG master:

```tcl
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_hbm
set_property CONFIG.M_AXI_DATA_WIDTH {64} CONFIG.M_AXI_ADDR_WIDTH {64} ...
jtag_hbm/M_AXI   -> pcie2hbm/S00_AXI
pcie2hbm/M00_AXI -> hbm/SAXI_00
pcie2hbm/M01_AXI -> hbm/SAXI_16
```

HBM IP is configured `USER_HBM_DENSITY 8GB`, `USER_HBM_STACK 2`, ref clk 200 MHz,
AXI input clk 250 MHz. Only 2 of 32 AXI ports are used; the rest are free.

**3. `fk33_jtagaxi.tcl` is a complete JTAG-only toolkit**, more than "a helper script":

| Proc | What it gives you |
|---|---|
| `axi256_write` / `axi256_read` | 256-bit HBM access at 64-bit addresses (4x 64-bit txns) |
| `fk33_read_sysmon` | die temp, **VCCINT / VCCHBM / VCCBRAM / VCCAUX / MGTAVCC / MGTAAUX / MGTAVTT volts, per-rail current, and computed watts**, plus LTC3636 regulator temps |
| `fk33_regulator_temps` | I2C temps at 0x18 / 0x19 / 0x1F |
| `fk33_set_vccint` | the undervolting lever (I2C 0x2C reg 0x00; 0x44 = 0.85V) |
| `fk33_set_led`, `axil_read0/write` | LEDs and AXI-Lite poking |

Per-rail current and watts over JTAG is exactly the instrumentation experiment #1
needs, and it means the VCCHBM 20A question can be measured directly rather than
inferred.

**4. This is how the card was actually deployed.** TRM talks to these boards only over
USB JTAG, and mining write-ups describe the FK33 as "installed in a PCIe riser **for
power delivery**, and only a USB cable has been required for communication."

**The catch is power, not data.** "Without PCIe" means no host link, no XDMA, no
driver, no BAR - **not** "no slot". The slot supplies at most 75 W and the card draws
~155 W across VCCINT 120A@0.85V, HBM_VCC 20A@1.2V and 1.8/3.3V aux, so it still needs
slot power from a real slot or a **powered PCIe riser fed from a PSU**. Upside: if you
seat it for power only and ignore the lanes, the "is the chipset x4 slot open-ended"
concern below stops mattering.

**udev gotcha - the existing cable driver rules will NOT match the FK33.** Drivers were
installed on this workstation in Feb 2024 for the AXU3EG, and the user is in `plugdev`
and `dialout`, but both FTDI rules gate on the manufacturer string:

```
# 52-xilinx-ftdi-usb.rules
ACTION=="add", ATTR{idVendor}=="0403", ATTR{manufacturer}=="Xilinx",   MODE:="666"
# 52-xilinx-digilent-usb.rules
ACTION=="add", ATTR{idVendor}=="0403", ATTR{manufacturer}=="Digilent", MODE:="666"
ATTR{idVendor}=="1443", MODE:="666"
```

The FK33's onboard FTDI is a third-party board and will report neither, so it comes up
root-only. **Re-running the Vivado driver installer does not fix this.** Add a rule once
the real VID/PID is visible:

```bash
lsusb                       # find the FTDI device the FK33 presents
echo 'ACTION=="add", ATTR{idVendor}=="0403", ATTR{idProduct}=="XXXX", MODE:="666"' \
  | sudo tee /etc/udev/rules.d/53-sqrl-fk33.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### Verify on arrival

1. **Cooling variant.** Passive datacenter heatsink, water block, or a modded active
   cooler? A bare passive fin stack at 155 W needs serious forced air and will cook
   in a quiet desktop. Many owners bolt on a Noctua.
2. **Card edge width.** Genuinely ambiguous, and **SQRL's own board files contradict
   each other**: `sqrl_fk33.xdc` constrains 16 lanes and `part0_pins.xml` carries 32
   PCIe RX entries (16 lanes, P and N), but `board.xml` names the edge-connector
   component **`pcie_8lane_edge`**. Check the physical connector; do not assume x16.
   Irrelevant for JTAG-only bring-up.
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

### Tooling status on this workstation (checked 2026-08-22)

**Nothing needs installing. The only gap is a license.** Vivado **2023.2** is installed
at `/tools/Xilinx/2023.2` (59 GB, with Vitis and Vitis_HLS), and the `virtexuplusHBM`
family is already present including the exact FK33 part. Verified by direct test:

```
get_parts xcvu33p-fsvh2104-2L-e   ->  xcvu33p-fsvh2104-2L-e        (present)
synth_design -top t (2 gates)     ->  ERROR: [Common 17-345] A valid license was not
                                      found for feature 'Synthesis' and/or device 'xcvu33p'
```

`board.xml` confirms the board file targets `xcvu33p-fsvh2104-2L-e`, matching.

Existing `~/.Xilinx/Xilinx-{1,2}.lic` are **IP-level, not tool-level**: ~100 permanent
free IP features plus ~370 evaluation IP features that expired March-May 2024, and a
PetaLinux eval lapsed Jan 2025. Nothing there unlocks a Virtex UltraScale+ device, and
the **Vivado tool evaluation appears unused** - worth confirming on the AMD account.

### Licensing route: AMD University Program (the $0 path)

**AUP is explicitly unchanged by the 2026.1 restructure.** It grants **Vivado Enterprise
Edition**, which "includes support for all AMD devices" - so VU33P, VU35P and VU9P, i.e.
every card in this document. Enterprise is **perpetual** under the new tiers, so it is a
durable asset rather than a renewing cost.

**The advising professor applies, not the student.** AMD's wording is that academics may
request multiple licenses "for teaching courses and **for their research teams**", so a
seat is in scope, but the request must come from faculty. Three steps, all faculty-side:

1. Create an AMD account, activate via the emailed token
2. Complete AUP enrollment: `amd.com/en/corporate/university-program/enroll.html`
3. On approval, submit a **Donation Request** from the AUP Members site:
   `amd.com/en/corporate/university-program/donation-program.html`

Portal `www.amd.com/AUP`. The same programme covers **hardware** donations, not only
software. Note node-locked licenses bind to a host MAC (this box is `5c80b67a481f`).

**Extra justification worth giving the advisor:** since 2026.1 the free Basic tier is
**Windows-only** and Linux requires a paid tier, so an AUP Enterprise grant is what
would allow moving past 2023.2 on Linux at all - for the AXU3EG work as much as the
FK33. See section 6.

### Do not start the license clock early

A 30-day node-locked evaluation is the fallback if AUP stalls. Do stage 1 on the AXU3EG
(free tools, and 2023.2 is grandfathered on Linux) and read through `fk33_example.tcl`
*before* activating it, so the eval window covers real work rather than orientation.
Board files reference 2019.2 install paths but should port forward to 2023.2.

**Stay on 2023.2.** Upgrading to 2026.1+ on Linux now costs money even for the
free-tier ZU3EG work.

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

## 6. The hidden cost: a paid Vivado tier

**REWRITTEN 2026-08-21. The old figure in this section ($2,995/yr ML Enterprise) is
obsolete.** AMD restructured Vivado licensing at the **2026.1** release, replacing
ML Standard / ML Enterprise with five tiers:

| Tier | Model | Covers |
|---|---|---|
| **Basic** | free, annual renewal | 7 Series, Spartan US+, Artix US+, selected Zynq US+ MPSoC, selected Kintex US/US+, Kria |
| **Core** | paid subscription, **~$1,200-1,800/yr** | adds UltraScale / **UltraScale+**, full simulation, full ChipScope |
| **Pro** | paid subscription | superset of Core; the Alveo-tier bundle is a Pro variant |
| **Enterprise** | perpetual | |
| **Gold** | perpetual + extended support | |

**Every card in section 3 is Virtex UltraScale+, which starts at Core, not Enterprise.**
So the license line is roughly **half** what this document previously assumed. The
AXU3EG (ZU3EG) remains free-tier.

This is still structural, not listing-specific: every AMD device with more than ~40 MB
of on-chip SRAM is Virtex UltraScale+ or Versal. Intel is the same (Quartus Lite covers
only small devices).

Because the license is a **fixed** cost, it argues for buying several cards at once
rather than one, if the project proceeds at all.

**Two riders, both worth tracking:**

- **Alveo/Varium cards come with a free one-year Vivado Pro (Alveo tier) subscription**
  that covers all Alveo devices. It goes with a **new** purchase, so a used card off
  eBay does not carry it. For a new Varium C1100 this effectively folds the first
  year's license into the card price, which narrows the gap against the mining cards
  considerably.
- **Reporting suggests future free-tier releases are becoming Windows-only.** That does
  not touch the paid tiers, but it would affect the **current free Linux flow used for
  the AXU3EG work**. Verify before upgrading Vivado on this workstation.

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

### Which card, by intent (revised 2026-08-21)

- **A fabric: standardize on FK33 ($300).** Availability is the deciding factor -
  Jungle Cats are one-off listings, FK33s move in lots of 100. Also the best
  documented of the mining cards and the lowest power. Buy **two first** and prove
  PCIe P2P between them before committing to eight. One is already ordered.
- **Lowest-risk single board: Varium C1100 (~$1,000).** Official product, DS1003,
  board files, XRT, 2x QSFP28, 75W passive single-slot, and a first-year Vivado Pro
  (Alveo tier) subscription if bought new. The QSFP28 ports directly retire the PCIe
  switch / ACS-override assumption in section 4b.
- **Highest ceiling, highest risk: Jungle Cat ($425).** 4x the fabric of an FK33 and
  2x the HBM bandwidth, no known VCCHBM problem. But: one XDC and nothing else, a
  bankrupt vendor, an **unconfirmed host interface**, an unknown speed grade, and a
  fan under bitstream control at 260W per module. **Do not make this the first board.**
- **VU9P/DDR4 class: skip on sight.** See the standing rule in section 3.

Note that the board price is no longer quite noise, but it is still the small half of
the decision: a Core-tier license at ~$1,200-1,800/yr means a $300 FK33 is a
~$1,500-2,100 decision and a $425 Jungle Cat is a ~$1,625-2,225 decision. **Pick on
capability, documentation and availability, not sticker price.** The one case where
sticker price flips the ranking is the Varium C1100, whose bundled first-year Alveo-tier
subscription can offset most of its premium if bought new.

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
- [SQRL_JungleCat board files](https://github.com/d953i/SQRL_JungleCat) (the whole repo is a README and one XDC)
- [JCCL2-JCM35.xdc](https://raw.githubusercontent.com/d953i/SQRL_JungleCat/master/constraints/JCCL2-JCM35.xdc) (carrier/module split, Aurora refclk, fan control, no PCIe constraints)
- [SQRL JCM-M2116 / JCM-G28 Intel Stratix modules](https://store.squirrelsresearch.com/jcm-m2116/) (**source of the JCC4P / JCC2P / JCC-Lite carrier table and the 260W/300A module spec**; store domain is dead, recovered via Wayback)
- [teamredminer issue #738](https://github.com/todxx/teamredminer/issues/738) ("JC35 on JCC2L carriers")
- [SQRL_FK33 board files](https://github.com/d953i/SQRL_FK33) (default branch `Vivado_2022_2`)
- [PG194 AXI Bridge AXIBAR2PCIEBAR registers](https://docs.amd.com/r/en-US/pg194-axi-bridge-pcie-gen3/AXI-Base-Address-Translation-Configuration-Registers-Offset-0x208-0x234)
- [Understanding the PCIe-to-AXI bridge (AXI_BARS vs PCI_BARS)](https://iriscores.com/2021/07/14/understanding-pcie-to-axi-bridge/)
- [Linux PCI P2PDMA docs](https://docs.kernel.org/driver-api/pci/p2pdma.html)
- [Disabling ACS for P2P](https://kubernetes.recipes/recipes/ai/disable-acs-pcie-gpu-direct-p2p/)
- [Vitis p2p_fpga2fpga example (the slow path, avoid)](https://xilinx.github.io/Vitis_Accel_Examples/2022.1/html/p2p_fpga2fpga.html)
- [Broadcom PCIe switches](https://www.broadcom.com/products/pcie-switches-retimers/pcie-switches)
- [FK33 specs](https://www.hashrate.no/fpgas/FK33/specs)
- [TeamRedMiner FPGA guide](https://github.com/todxx/teamredminer/blob/master/doc/FPGA_GUIDE.txt) (VCCHBM 20A / OC range, USB JTAG, voltage tuning; **supported list is C1100 / FK33 / U50C / TH53-55 / Osprey E300 - the Jungle Cat is absent**)
- [SQRL Chapter 11](https://www.bankruptcyobserver.com/bankruptcy-case/SQUIRRELS-RESEARCH-LABS)
- [Vivado edition device support](https://pcbsync.com/xilinx-vivado-editions/)
- [Vivado licensing](https://www.xilinx.com/products/design-tools/vivado/vivado-ml-buy.html)
- [Vivado 2026.1 licensing tiers](https://bard0.com/insights/vivado-2026-1-licensing.html) (Basic/Core/Pro/Enterprise/Gold; Virtex US+ starts at Core)
- [AMD Vivado licensing options](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html)
- [Varium C1100 product brief](https://www.xilinx.com/content/dam/xilinx/publications/product-briefs/varium-c1100-product-brief.pdf)
- [Varium C1100 data sheet DS1003](https://docs.amd.com/v/u/en-US/ds1003-varium-c1100)
- [Varium C1100 at DigiKey](https://www.digikey.com/en/products/detail/amd/V-C1100-P00G-PQ-G/15861191)
- [F4PGA supported architectures](https://symbiflow.readthedocs.io/en/latest/status.html)
- [Project U-Ray](https://prjuray.readthedocs.io/en/latest/)
- [nextpnr-xilinx](https://github.com/gatecat/nextpnr-xilinx)
- [AWS F2 instances](https://aws.amazon.com/ec2/instance-types/f2/)
- [f1.16xlarge specs](https://instances.vantage.sh/aws/ec2/f1.16xlarge)
- [Cerebras 2000 tok/s](https://www.businesswire.com/news/home/20250910137362/en/Cerebras-Sets-New-AI-Speed-Record-on-MBZUAI-and-G42%E2%80%99s-K2-Think-at-2000-TokensSecond-Inference-Performance)
- [FlightLLM](https://arxiv.org/html/2401.03868)
- [TeLLMe v2 ternary edge FPGA](https://arxiv.org/pdf/2510.15926)


## FK33 first light: bitstream built and ready, before the card arrived (2026-08-24)

**`write_bitstream` is licensed for `xcvu33p-fsvh2104-2L-e`.** Verified with a
trivial design before anything else, because it is a hard blocker that no amount
of RTL work routes around, and this document had recorded a license warning
naming that device. It produced a valid bitstream. The warning no longer applies.

**A JTAG-only first-light bitstream now builds and meets timing**, generated by
`hw/fk33/gen_firstlight.py` from SQRL's `fk33_example.tcl`:

```
FK33_TIMING WNS=5.063 ns  WHS=0.018 ns
FK33_BITSTREAM bd_wrapper.bit (9,845,026 bytes)
utilisation: 8,693 LUT (2.0%), 15,307 FF (1.7%), 10.5 BRAM, 0 DSP
part:        xcvu33p-fsvh2104-2L-e
```

The implementation run also **confirms the device has 2,880 DSP**, correcting the
2,976 figure derived earlier in this document and repeated into subsystem B's
budget.

**SQRL's `EnablePCIe 0` path was bit-rotted and had never been run.** Four
breakages, three of them upstream's and all three confined to the non-PCIe
branch, which is what makes the conclusion firm:

1. a hard version gate rejecting anything but Vivado 2022.2;
2. `util_ds_buf:2.1` requested in the else branch where the PCIe branch asks for
   `2.2` -- 2023.2 ships only 2.2, so the request yields a locked IP and the
   build dies on `Parameter IBUF_OUT.CLK_DOMAIN not found`;
3. 76 `exclude_bd_addr_seg` calls targeting `xdma/M_AXI`, not guarded by
   `EnablePCIe`, so with no XDMA the address space is empty and Vivado errors
   with `Please specify an address space when excluding slave segment`;
4. (ours) `scriptPath` is derived from `[info script]`, which only works while
   the script sits inside the upstream repo.

Fixes live in a **generator**, not a fork, so upstream changes are not lost, and
it aborts loudly if any anchor stops matching rather than emitting a file that
quietly lacks a change.

**Unresolved, and it needs the physical card: the speed grade is contradicted by
SQRL's own files.** `fk33_example.tcl` hardcodes `xcvu33p-fsvh2104-2-e`;
`board_files/sqrl_fk33/1.1/board.xml` says `-2L`. `-2` is the FASTER grade, so
building for it and deploying on `-2L` silicon signs timing off against hardware
we do not own. The generator forces `-2L` as the conservative direction.
**Settle it from the IDCODE**: Vivado's hardware manager reports the real part
within minutes of connecting. If it is genuinely `-2`, every sizing result in
`docs/superpowers/specs/` gains free headroom, since all of today's OOC sweeps
were run on `-2L`.

Note also that the board file's display name is **"Forest Kitten 33 (Active
Cooling)"**, so an active-cooling variant exists. There are no fan pins in the
FK33 XDC, so an added fan is not under bitstream control -- which is the safer
arrangement, and deliberately unlike the AXU3EG, where a fabric-controlled fan
ran wide open for an entire build because a scalar pin was never externalised.
