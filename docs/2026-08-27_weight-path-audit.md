# The weight path, host DRAM to subsystem A: what exists and what does not

**Date:** 2026-08-27
**Branch:** `fpga`, at `c87003b` (PCIe endpoint added in `aec2d85`)
**Target of this audit:** Qwen3.5-9B on one SQRL FK33 (XCVU33P, 8 GB HBM), N=1.
**Scope:** the chain a single model weight travels, from a buffer in host DRAM
to the cycle `rtl/matvec_core.vhd` multiplies it by an activation. Nothing else.

## The question

What is the complete path a model weight takes from host DRAM to the point
where subsystem A consumes it, and which links in that chain do not exist yet?

## The answer, up front

**Eleven hops. Six exist in some form and five do not exist at all.** Of the six
that exist, exactly zero have ever run on this card: one is a host program that
has never seen an endpoint, and five are a block design that has been validated
in Vivado but never synthesised, placed or powered. The five missing hops are all
on the card side of the DMA: there is no HBM reader, no descriptor source, no
port budget, no 64-bit addressing, and no FK33-shaped packed file.

**The format transformation is NOT the gap.** `tools/pack_int4.py` exists, reads
GGUF, and its output was checked against the C reference today for the first time
on a real tensor: they agree exactly. What is missing is not the transform but
the *target geometry* -- the packer is hard-wired to `AXI_DW = 128` and
`NPORTS_W = ROWS_IF`, which is right for the AXU3EG and cannot be right for the
FK33, where HBM AXI ports are 256 bits and there are 30 of them, not 58 or 80.
Spec A section 14.5 already records this as open. This audit adds the measurement
that the rest of the packer works on real weights.

---

# THE GAP LIST

Read this section alone if you read nothing else.

| # | Hop | Status | Evidence |
|---|---|---|---|
| 1 | Host buffer holding the packed image | **EXISTS** (partially) | `tools/pack_int4.py` emits one tensor per file. No whole-model image builder. |
| 2 | XDMA descriptor / `pwrite` into `/dev/xdma0_h2c_0` | **EXISTS, NEVER POWERED** | `hw/fk33/host/fk33ctl.py:178-187`, `hw/fk33/host/fk33_bringup.c`. No FK33 has ever enumerated on PCIe. |
| 3 | XDMA `M_AXI` master, 128 bit at 250 MHz | **EXISTS in the block design, not built** | `hw/fk33/build_fk33_pcieep.tcl:262-283`, `:317-318`. Bitstream deliberately not run. |
| 4 | `pcie2hbm` smartconnect | **EXISTS in the block design** | `build_fk33_pcieep.tcl:194-197`, `:316-318`, `:515-518` |
| 5 | HBM controller, 2 of 32 AXI ports wired | **EXISTS, but only 2 ports** | `build_fk33_pcieep.tcl:196-197`, `:547-578` |
| 6 | HBM pseudo-channels MEM00-31, 32 x 256 MB | **EXISTS, mapped flat 0 .. 0x1_FFFF_FFFF** | `build_fk33_pcieep.tcl:547-578` |
| 7 | **A fabric reader that pulls weights out of HBM** | **DOES NOT EXIST** | The `pcieep` build contains no project RTL at all (`build_fk33_pcieep.tcl:667-671` adds only an XDC and the BD wrapper). `rtl/hbm_tg.vhd` is a bandwidth instrument, not a weight path. |
| 8 | **28 more HBM AXI ports for A, and their address map** | **DOES NOT EXIST** | Proven buildable at 30 ports by `hw/fk33/build_fk33_hbmbw.tcl:443-472`, but that is a different design with a different address map. |
| 9 | **A descriptor source on the card (no PS exists on a VU33P)** | **DOES NOT EXIST** | `rtl/matvec_int4.vhd:14-20` says "the DESCRIPTOR is driven by the PS". There is no PS. `rtl/seq_desc_fetch.vhd:111-113` states the weight base array is explicitly not fetched. |
| 10 | **64-bit weight base addressing** | **DOES NOT EXIST** | `ADDR_W : positive := 32` at `rtl/axi_rd_port.vhd:31`, `rtl/matvec_int4_axi.vhd:56`, `rtl/matvec_int4_ip.vhd:28`. 32 bits reaches 4 GB of an 8 GB device. |
| 11 | **A packed file in FK33 geometry** | **DOES NOT EXIST, and is not yet definable** | `tools/pack_int4.py:203` hard-wires `nports = rows_if` "at BLOCK=32, AXI_DW=128". Spec A section 14.5 (line 1658) declares the `ROWS_IF=80` format undefined and says section 7.7's architecture "does not transfer to HBM". |

## The five things that block first bring-up, stated plainly

1. **Nothing in the FPGA reads HBM and hands bytes to subsystem A.** Not a stub,
   not a skeleton. `matvec_int4` has never been instantiated in any FK33 build.
   The only FK33 designs that exist are `firstlight`, `hbmbw`, `i2cprobe` and
   `pcieep`, and none of them contains a single file from `rtl/` except
   `hbm_tg.vhd` in `hbmbw`.

2. **The descriptor has no source.** Subsystem A's design assumes a Zynq PS
   parses the 4 KB header and writes the descriptor over AXI-Lite. The VU33P has
   no PS. On the FK33 the descriptor must come from the host over the AXI-Lite
   BAR or from subsystem D, and D's descriptor fetcher deliberately does not
   fetch the weight base array yet.

3. **A has two HBM ports available and needs about 30.** The `pcieep` design
   wires `SAXI_00` and `SAXI_16` and both are already spoken for by
   `jtag_hbm` and `xdma/M_AXI`. Every other `SAXI_nn` is turned off.

4. **`ADDR_W` is 32 bits.** Weight bases above 4 GB are unrepresentable, and
   the 9B image is 5.04 GB, so the top ~1 GB of the model would be
   unaddressable even if everything else worked.

5. **The FK33 packed format is genuinely undefined**, not merely unwritten. The
   section 6.5 invariant `NPORTS_W * AXI_DW = ROWS_IF * BLOCK * 4` and the
   physical port count cannot both be satisfied at any useful `ROWS_IF`, which
   is why A section 14.5 exists.

## What is NOT a gap, contrary to what a reader of the specs might assume

- **The quantisation and packing tool exists and works on real weights.**
  Measured today, see section 4.
- **The address map is coherent between host and fabric.** Measured by
  inspection, see section 3. One cosmetic discrepancy, no functional one.
- **PCIe bandwidth is not a constraint.** The cold load is ~1.5 s. See section 5.
- **HBM capacity is not a constraint for 9B weights.** 5.04 GB of 8.59 GB. The
  constraint is the KV cache, and only at long context. See section 5.

---

# 1. The chain, hop by hop

## Hop 1. Host buffer: the packed image

**Status: partially exists.**

`tools/pack_int4.py` reads one named tensor out of a GGUF
(`read_tensor`, `tools/pack_int4.py:63-83`), requantises it
(`quantize`, `:95-174`) and writes one `.mv4i` file per tensor
(`pack`, `:211-249`).

What does not exist is the **whole-model image builder**: something that walks
every tensor, decides where each lands in HBM, concatenates, and emits both the
blob and the manifest of per-tensor base addresses. `--audit`
(`tools/pack_int4.py:358-440`) sums the sizes but writes nothing. The host
bring-up plan calls this out as step 6 of a protocol sketch
(`docs/2026-08-27_pcie-host-bringup-plan.md:508-537`), not as code.

## Hop 2. XDMA descriptor, host side

**Status: exists as code, never run against hardware.**

`fk33ctl.py` writes HBM with `os.pwrite` in 8 MB chunks
(`hw/fk33/host/fk33ctl.py:178-187`) and reads back with `os.pread`
(`:189-203`). The XDMA character device's file offset **is** the AXI address, so
there is no descriptor vocabulary to get wrong; this is the reason XDMA was
chosen over QDMA (`docs/2026-08-27_pcie-host-bringup-plan.md:185-200`).

`hw/fk33/host/fk33_bringup.c` is the staged pass/fail program. Its constants
agree with the fabric exactly: `ID_BASE 0x0000A000`, `SCRATCH_BASE 0x00010000`,
`DMABRAM_BASE 0x200000000`, `HBM_TOP 0x200000000`
(`hw/fk33/host/fk33_bringup.c:53-68`).

Nothing here has touched a card. No FK33 has ever enumerated on PCIe
(`docs/2026-08-27_pcie-host-bringup-plan.md:5`).

## Hop 3. XDMA endpoint and its AXI master

**Status: exists in the block design, which has been validated but not built.**

Gen3 x4, 128-bit `M_AXI`, one DMA channel each way, 250 MHz AXI clock
(`hw/fk33/build_fk33_pcieep.tcl:262-283`). The comment at `:270-272` records the
sizing: 128 bits at 250 MHz is 4.0 GB/s against a 3.94 GB/s Gen3 x4 payload
ceiling, so the fabric is not the limit.

`FK33_STOP_AFTER_BD=1` has been run and `validate_bd_design` passes with the IP
parameters read back (`aec2d85` commit message). `./pcieep_build.sh` has
deliberately not been run.

## Hop 4. `pcie2hbm` smartconnect

**Status: exists in the block design.**

Two slaves (`jtag_hbm` at `S00`, `xdma/M_AXI` at `S01`) and three masters
(`SAXI_00`, `SAXI_16`, `fk33_dmabram`):
`build_fk33_pcieep.tcl:194-197`, `:316-318`, `:515-518`.

The whole AXI fabric is clocked by `xdma/axi_aclk`
(`build_fk33_pcieep.tcl:328-352`), which is why the JTAG-AXI masters are dead
until the link trains. This is the reason the bring-up order is probe bitstream,
raise VCCINT, then endpoint bitstream, and not the obvious order
(`docs/2026-08-27_pcie-host-bringup-plan.md:328-360`).

## Hop 5. HBM controller

**Status: exists, with 2 of 32 AXI ports wired.**

8 GB, 2 stacks, both `HBM_REF_CLK` at 200 MHz, AXI input clock 250 MHz
(`build_fk33_pcieep.tcl:138-142`). `HBMGlobalSwitch` is 1
(`build_fk33_pcieep.tcl:87`), so each connected port can reach any pseudo-channel
**within its own stack**; the switch is per stack and there is no cross-stack
path, which is exactly why two ports are used rather than one
(`hw/fk33/gen_hbmbw.py:340-343`).

Only `SAXI_00` and `SAXI_16` are connected. `SAXI_01` through `SAXI_15` and
`SAXI_17` through `SAXI_31` are set `false`
(`build_fk33_pcieep.tcl:149-150`).

## Hop 6. HBM pseudo-channels

**Status: exists, mapped flat.**

32 segments of 256 MB, `MEM00`-`MEM15` reached through `SAXI_00` at
`0x0_0000_0000 .. 0x0_FFFF_FFFF` and `MEM16`-`MEM31` through `SAXI_16` at
`0x1_0000_0000 .. 0x1_FFFF_FFFF` (`build_fk33_pcieep.tcl:547-578`). The
redundant cross-stack routes are excluded from both `xdma/M_AXI` and
`jtag_hbm/Data` so there is exactly one path to each segment
(`build_fk33_pcieep.tcl:580-643`).

## Hop 7. Whatever reads HBM and presents weights to A

**Status: DOES NOT EXIST.**

`rtl/weight_streamer.vhd` is the module that would do this, and its own header
says so: "it owns the AXI masters, so it is DDR4 on the AXU3EG and HBM on the
FK33" (`rtl/weight_streamer.vhd:5-6`). But as written it is DDR4-shaped:

- `AXI_DW : positive := 128` (`rtl/weight_streamer.vhd:33`). HBM SAXI ports are
  256 bits (`rtl/hbm_tg.vhd:92`).
- It instantiates exactly `NPORTS_W + 1` `axi_rd_port` masters and pops all
  weight FIFOs in lockstep (`:112-128`, `:149-163`). One FIFO per physical port.
- It asserts the section 6.5 invariant as a *failure*
  (`:100-103`) and asserts that the scale path fits a single port
  (`:107-110`), with the comment at `:104-106` stating outright that at
  `ROWS_IF=80` "this build does not implement it".

The `pcieep` bitstream contains no project RTL whatsoever. The only `add_files`
calls add the XDC and the generated block-design wrapper
(`build_fk33_pcieep.tcl:667-671`). Compare `build_fk33_hbmbw.tcl:327-328`,
which does add `rtl/hbm_tg.vhd` and `rtl/hbm_tg_ip.vhd` -- a read/write traffic
generator built to measure bandwidth (`rtl/hbm_tg.vhd:1-40`), not to feed A.

## Hop 8. Ports and the port budget

**Status: DOES NOT EXIST for A.**

The `hbmbw` build proves 30 ports can be instantiated and reached: `SAXI_01`
through `SAXI_15` and `SAXI_17` through `SAXI_31` all go to the traffic
generator (`build_fk33_hbmbw.tcl:443-472`), while `SAXI_00` and `SAXI_16` stay
with the host path (`:139-140`). That 2-plus-30 split is the topology A must
inherit, and it is the reason the measured supply figure is 288 GB/s and not
460 (spec A section 13, the 2026-08-25 correction block at line 1284).

No design exists in which those 30 ports carry weights.

## Hop 9. The descriptor

**Status: DOES NOT EXIST on this platform.**

`rtl/matvec_int4.vhd:14-20`:

> The DESCRIPTOR is driven by the PS, which parses the 4 KB header (6.4) and
> programs n_rows / n_cols / w_exp / out_shift / the sub-region bases / the
> codebook. Nothing in the fabric parses the header.

The AXU3EG has a PS and `hw/mv_driver.c` is that program: it slurps the file,
parses the header (`hw/mv_driver.c:112`), computes the sub-region bases and beat
counts, and writes them through `rtl/matvec_int4_axi.vhd`'s register map.

**The FK33 has no PS.** A VU33P is not a Zynq. So on the FK33 the descriptor has
to come from either the host over the AXI-Lite BAR, or subsystem D. D is the
intended answer (`docs/superpowers/specs/2026-08-24-transformer-sequencer-design.md:742-751`),
and D's descriptor fetcher exists and is verified -- but the part that carries
weight addresses is explicitly absent:

> The base array (`nsub_w + nsub_s` 64-bit words at offset 0x40) is NOT
> fetched here. Its length is open with A section 14.5 and the count is only
> RANGE-CHECKED against NSUB_MAX at the moment. Fetching it is remaining work.
> -- `rtl/seq_desc_fetch.vhd:111-113`

`rtl/seq_top_skel.vhd` contains no weight base signal at all.

## Hop 10. Address width

**Status: DOES NOT EXIST.**

`ADDR_W` defaults to 32 in `rtl/axi_rd_port.vhd:31`,
`rtl/matvec_int4.vhd:33`, `rtl/matvec_int4_axi.vhd:56` and
`rtl/matvec_int4_ip.vhd:28`. Spec A section 15.5 (line 2129) says the datapath is
already parameterised and only the AXI-Lite register map hardcodes 32 bits
(`rtl/matvec_int4_axi.vhd:121`, `:224-225`). That is correct as far as it goes,
but nothing has been built or simulated at any other width, and the packer's
header carries 64-bit offsets (`tools/pack_int4.py:239-242`) that no consumer
can currently hold.

## Hop 11. The packed file in FK33 geometry

**Status: DOES NOT EXIST, and section 14.5 says it cannot yet be specified.**

See section 4 below.

---

# 2. Where the weight actually gets consumed

Worth stating precisely, because everything upstream has to serve this.

One weight is a **4-bit index into a 16-entry int8 codebook**, not a
two's-complement int4. `rtl/matvec_core.vhd:388-397`:

```vhdl
idx := to_integer(unsigned(
         w_r((rr*BLK + j)*4 + 3 downto (rr*BLK + j)*4)));
xw  := signed(x_r(j*16+15 downto j*16));
k   := tg(0).blk * BLK + j;
if k < n_cols then
  tr(0)(rr*BLK + j) <= resize(cb(idx) * xw, 28);
```

From the RTL, not from prose:

| Property | Value | Source |
|---|---|---|
| Weight word width | `ROWS_IF * BLK * 4` = 512 bits at `ROWS_IF=4` | `rtl/matvec_core.vhd:78` |
| Nibble `j` of lane `rr` | bits `(rr*BLK+j)*4+3 downto (rr*BLK+j)*4` | `rtl/matvec_core.vhd:390-391` |
| So weight 0 of lane 0 | bits 3:0, i.e. the LOW nibble of byte 0 | same |
| Lane `rr` to port `p` | `p = rr`; `w_data((p+1)*128-1 downto p*128) <= qd(p)` | `rtl/weight_streamer.vhd:161` |
| Codebook | 16 x int8, runtime loaded via `cb_we/cb_addr/cb_data` | `rtl/matvec_core.vhd:71-73`, `:326` |
| Index 0 decodes to -127, never 0 | so padding must be MASKED, never zero filled | `rtl/matvec_core.vhd:383-385` |
| Scale | `ROWS_IF` x uint15 in 16-bit fields, MSB must be 0 | `rtl/matvec_core.vhd:81-82`, `:362` |
| Scale beat unpack | one 128-bit beat carries `128/(ROWS_IF*16)` = 2 cycles of scales, chunk 0 first | `rtl/weight_streamer.vhd:83`, `:169-175` |
| Consumption order | tile-major: for tile `t`, for block `b`, all `ROWS_IF` rows together | `rtl/matvec_core.vhd:19-23`, `:365-379` |

The critical asymmetry: `matvec_core` is device-independent and `weight_streamer`
is not (`rtl/matvec_int4.vhd:10-13`). The FK33 work is entirely below the core.

---

# 3. Address map coherence

**Verdict: the host-side and fabric-side views agree.** One cosmetic
discrepancy, described below, and no functional one.

| Region | Fabric (`build_fk33_pcieep.tcl`) | Host | Agree |
|---|---|---|---|
| SYSMON | `0x00003000`, 4K, line 531 | `SYSMON_TEMP 0x3400`, `fk33_bringup.c:58` | yes |
| GPIO | `0x00009000`, 4K, line 532 | `fk33ctl.py` GPIO ops | yes |
| ID | `0x0000A000`, 4K, line 537 | `ID_BASE 0x0000A000`, `fk33_bringup.c:53` | yes |
| Scratch | `0x00010000`, 8K, line 538 | `SCRATCH_BASE 0x00010000`, `SCRATCH_SIZE 0x2000`, `:56-57` | yes |
| HBM | `0x0_0000_0000 .. 0x1_FFFF_FFFF`, lines 547-578 | `HBM_SIZE 0x2_0000_0000`, `fk33ctl.py:48` | yes |
| DMA BRAM | `0x2_0000_0000`, 64K, line 543 | `DMABRAM_BASE 0x2_0000_0000`, `fk33_bringup.c:66` | yes |

The AXI-Lite BAR is sized at 128 KB (`build_fk33_pcieep.tcl:293`), so everything
on it must fit under `0x20000`. Scratch ends at `0x12000`. Fine.

**How many pseudo-channels are wired.** 32 pseudo-channels exist and all 32 are
address-mapped, but through only **2 AXI ports**. That is the whole story of the
current design: capacity is fully reachable, bandwidth is not. Two 256-bit ports
at 250 MHz is 16.0 GB/s (DERIVED: `2 x 32 B x 250e6`), against the 288.0 GB/s
MEASURED at 30 ports and 300 MHz
(`hw/fk33/results/hbmbw_30port_300mhz.txt`). Sufficient for a 3.9 GB/s PCIe load;
5.5% of what subsystem A needs.

**The one discrepancy.** `build_fk33_pcieep.tcl:539-541` and
`docs/2026-08-27_fk33-pcie-bringup-procedure.md:314` both say the DMA BRAM is
placed above HBM "so a bad host offset lands on nothing rather than silently in
memory". It is **immediately adjacent**: HBM ends at `0x1_FFFF_FFFF` and the
BRAM begins at `0x2_0000_0000` with no guard. A small overrun therefore lands in
the BRAM, not on nothing. This is harmless -- the BRAM drives nothing and is
JTAG-readable, which arguably makes an overrun *more* diagnosable -- but the
stated rationale is not what the map implements. `fk33ctl.py:205-208` rejects
host ranges past 8 GB independently, so the guard exists in software.

**A second address map exists and is different.** `build_fk33_hbmbw.tcl:483+`
assigns each of 30 ports its own 256 MB pseudo-channel-local window
(`rtl/hbm_tg.vhd:94-98` fixes pseudo-channel `n` at `n * 256 MB`). That is the
access pattern measured at 100% of the arithmetic ceiling, and it is the pattern
A will use ("A streams a contiguous weight shard per port",
`rtl/hbm_tg.vhd:20-25`). **When A's ports are added, the flat host view and the
port-local engine view have to be reconciled**, because the packer currently
emits sub-regions that are merely 4 KB aligned
(`tools/pack_int4.py:204-205`), not 256 MB aligned onto pseudo-channels. This is
a silent-wrong-answer class of bug and it is not yet designed.

---

# 4. The format question

## 4.1 The transformation exists

`tools/pack_int4.py` is a complete GGUF-to-MV4I packer. It implements spec A
sections 6.1, 6.4 and 6.5 and produces:

```
w[r][k] = codebook[idx[r][k]] * (scale[r][b] / 2^15) * 2^-w_exp
```

- 4 KB little-endian header, magic `0x4D563449` ("MV4I"), `w_exp` signed at
  0x10, codebook at 0x20, 64-bit sub-region offsets from 0x38
  (`tools/pack_int4.py:216-224`).
- `nports = ROWS_IF` weight sub-regions, each independently 4 KB aligned, then
  one scale region (`packed_layout`, `:191-208`).
- Nibble order: weight `j` even to the low nibble of byte `j/2`, odd to the high
  (`:231-240`, `lo | (hi << 4)`).
- Sub-region `rr` holds lane `rr` of every word, laid out tile-major then block
  (`:238-241`).
- Scales: for tile, for block, for `rr`, uint16 LE (`:243-247`).
- Pad fill pinned to `0x00`, including the deliberate suppression of the
  `0x88` bytes a naive least-squares search would emit in a ragged final block
  (`:132-140`).
- Per-block scale chosen by an 8-point least-squares search, not by amax
  (`:125-158`), which the comment at `:104-110` justifies with a measured ~10%
  relative error for the amax-anchored choice.

The C reference `ref/matvec_int4.c` parses the same layout
(`mv4i_parse`, `:97-137`; `get_widx`, `:142-151`; `get_scale`, `:154-162`) and
contains its own minimal emitter of the identical layout (`pack`, `:302-355`).

## 4.2 Has anything ever checked the packer against what the RTL reads?

**Partly, and the missing link was closed by measurement today.**

The chain has three links and they were verified in two places, not three:

| Link | Checked by | Automated |
|---|---|---|
| `pack_int4.py` emitter to `matvec_int4.c` parser | `--crosscheck` (`tools/pack_int4.py:296-347`) vs `ref/matvec_int4.c:423-461` | **no** |
| `matvec_int4.c` emitter to RTL reassembly | `sim/tb_matvec_int4.vhd` fed by `emit_trace`'s `IMG` words (`ref/matvec_int4.c:504-529`) | yes, `sim/run_matvec.sh` stage 6 |
| `pack_int4.py` emitter directly to RTL | nothing | **no** |

`sim/run_matvec.sh` does not invoke `--crosscheck` anywhere. Grepping the
repository, the only references to it are its own definition and
`hw/README.md:168-172`, which describes a *different* check (the `--dry-run`
beat-count comparison).

**MEASURED, 2026-08-27.** Packed a real tensor out of the shipped 27B GGUF and
ran both cross-checks:

```
$ python3 tools/pack_int4.py /mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf \
        blk.0.ssm_alpha.weight alpha.mv4i --rows-if 4 --verify
  shape M=48 K=5120  (0.2M weights)
  w_exp=9  out_shift=4  NB=160
  weight reconstruction: max 1.174e-02 (7.15% of max|w|), RMS 7.99% relative
  matvec vs float32:     RMS rel 7.31%, cosine 0.997269
wrote alpha.mv4i  0.15 MB  (4.93 bits/weight)

$ ./mv4i alpha.mv4i                                   # ref/matvec_int4.c
M=48 K=5120 w_exp=9 out_shift=4 ns=4 y_exp=1 mant_sum=120792 sat=0

$ python3 tools/pack_int4.py --crosscheck alpha.mv4i  # independent recompute
M=48 K=5120 w_exp=9 out_shift=4 ns=4 y_exp=1 mant_sum=120792 sat=0
```

Identical to the last digit, on weights that came out of a real model rather
than a self-test PRNG. Output kept at
`/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/alpha.mv4i`.

**What this does and does not prove.** It proves the Python emitter and the C
parser agree on header layout, sub-region placement, nibble order, lane-to-
sub-region mapping and scale interleave, on real data. Since `sim/run_matvec.sh`
stage 6 separately proves the C emitter and the RTL agree, and the C self-test
round-trips its own emitter through its own parser, the interpretation chain
closes transitively. It does **not** prove byte-identity between the Python and C
emitters, and **the RTL has never consumed a file that `pack_int4.py` wrote.**

Note the 7.99% RMS weight error on this tensor. That is expected and not a
defect: `ssm_alpha` is one of the tensors llama.cpp keeps at Q8_0 precisely
because it is quantisation-sensitive, and spec A section 6.1's measured
perplexity result (+1.69% on the whole model, +1.31% if applied to FFN only) is
the end-to-end answer to exactly this.

## 4.3 What is actually missing, taken from the RTL

The packer cannot produce an FK33 file, and it is not a matter of adding a flag.

`tools/pack_int4.py:203`:

```python
nports = rows_if                       # 6.5 invariant at BLOCK=32, AXI_DW=128
```

That identity holds only at `AXI_DW = 128`. Restating the invariant from
`rtl/weight_streamer.vhd:100-103`:

```
NPORTS_W * AXI_DW = ROWS_IF * BLOCK * 4
```

DERIVED, at `BLOCK = 32`:

| Platform | `AXI_DW` | `ROWS_IF` | Required `NPORTS_W` | Ports available |
|---|---|---|---|---|
| AXU3EG (built) | 128 | 4 | 4 | 4 HP ports, exists |
| FK33, naive | 128 | 80 | 80 | 30 |
| FK33, native HBM width | 256 | 80 | 40 | 30 |
| FK33, native HBM width | 256 | 58 | 29 | 30, plus scales |

At `ROWS_IF = 58` and `AXI_DW = 256`, weights need 29 ports and there are 30
after the host takes two, leaving one for scales. Scales at `ROWS_IF = 58` need
`58 x 16 = 928` bits per core cycle against 256 bits per port per HBM cycle, so
one port is not enough and `n_scale_sub` must exceed 1 -- which
`rtl/weight_streamer.vhd:104-110` explicitly asserts is not implemented.

**If it did exist, it would have to produce, per tensor:**

1. A 4 KB header as already specified (`tools/pack_int4.py:216-224`), with
   `NPORTS_W` and `n_scale_sub` set to the FK33 values rather than to `ROWS_IF`
   and 1.
2. `NPORTS_W` weight sub-regions, each aligned to whatever the port-to-
   pseudo-channel map demands. Today that is 4 KB
   (`tools/pack_int4.py:204`); on the FK33 with port-local addressing it is a
   256 MB pseudo-channel boundary, which changes the size arithmetic entirely.
3. Sub-region `p` holding **lane `p`** of every consumed word, tile-major then
   block, where a lane is now `AXI_DW = 256` bits and therefore **two rows'
   worth of nibbles at `BLOCK = 32`**, not one. The `ROWS_IF = 4` coincidence
   that makes one lane equal one row is explicitly flagged as load-bearing and
   not to be assumed (spec A section 6.5, line 630).
4. `n_scale_sub` scale sub-regions, interleaved so that the concatenation across
   sub-regions is exactly `ROWS_IF` uint16 per (tile, block) in row order.
5. Pad fill `0x00` everywhere, so two conforming packers produce byte-identical
   files (spec A section 6.4, line 590).

Items 2 and 3 cannot be pinned down until the `weight_streamer` replacement is
designed, because the file layout is defined by what that module pops. This is
the same statement spec A section 14.5 makes, and it is correct.

---

# 5. Bandwidth and capacity, with the arithmetic shown

## 5.1 Assumptions, stated

- Qwen3.5-9B, `rtl/model_cfg_pkg.vhd:64-70`: 32 blocks, `attn_interval` 4,
  hidden 4096, FFN 12288, 32 linear value heads x 128, 16 attention query heads,
  4 KV heads, head dim 256, vocab 248,320, max context 262,144.
- Format cost 4.5 bits per weight: 4 bits of index plus one uint16 scale per 32
  weights, i.e. `4 + 16/32 = 4.5` (spec A section 6.1).
- N=1, so no sharding and no shard padding penalty.
- FK33 HBM is 8 GiB = 8.590 GB (`tools/pack_int4.py:426`).

**No Qwen3.5-9B GGUF exists on this machine**, so the 9B parameter counts below
are DERIVED from `docs/2026-08-27_9b-single-card-resource-envelope.md:211-212`
and are not measured. The 27B figures in the same table ARE measured today.

## 5.2 Total weight bytes

DERIVED, 9B:

```
stored parameters (incl. embedding)   8.954e9
  x 0.5625 B/weight                =  5.0364 GB   =  4.6905 GiB
streamed per token (excl. embedding)  7.936e9
  x 0.5625 B/weight                =  4.4642 GB
```

MEASURED, 27B, today, `tools/pack_int4.py --audit` on the shipped
`Qwen3.8-27B-Q4_K_M.gguf` (output kept as
`scratchpad/audit_r4_c1.txt` and `scratchpad/audit_r58_r80.txt`):

| `ROWS_IF` | payload at 4.5 bpw | packed whole model | overhead | bits/weight |
|---|---|---|---|---|
| 4 | 14.089 GiB | **14.101 GiB** | +0.1% | 4.504 |
| 58 | 14.089 GiB | **14.228 GiB** | +1.0% | 4.545 |
| 80 | 14.089 GiB | **14.190 GiB** | +0.7% | 4.533 |

498 of 851 tensors are matvec weights, 26.893 B of 26.896 B parameters.

So the file-format overhead (4 KB header per tensor, 4 KB alignment on every
sub-region, K padded to a whole block) is **under 1% at every `ROWS_IF` tested**.
Applying the worst case to 9B: `5.0364 x 1.010 = 5.087 GB` stored.

Note the non-monotonicity between 58 and 80: alignment waste depends on how
`tiles * NB * 16` lands against 4 KB per sub-region, which is not monotone in
`ROWS_IF`. It is not an error.

## 5.3 How long the load takes over PCIe Gen3 x4

DERIVED:

```
raw payload rate = 8.0 GT/s x 4 lanes x 128/130 encoding
                 = 31.508 Gb/s = 3.938 GB/s
```

That is the ceiling before TLP overhead. The host plan expects 3.2-3.5 GB/s at a
256-byte MPS and ~3.0 at 128 bytes
(`docs/2026-08-27_pcie-host-bringup-plan.md:480-484`). ESTIMATE, because no link
has ever trained on this card.

| 9B blob | at 3.938 (ceiling) | at 3.3 (expected) | at 2.0 (pessimistic) |
|---|---|---|---|
| 5.087 GB, write only | 1.29 s | **1.54 s** | 2.54 s |
| with full read-back verify | 2.58 s | 3.08 s | 5.09 s |

**Cold load is a non-issue.** Even the pessimistic verified case is ~5 s, once.

The fabric does not bottleneck this: `xdma/M_AXI` is 128 bits at 250 MHz =
4.0 GB/s (DERIVED, `build_fk33_pcieep.tcl:270-272`), and the two HBM ports
supply 16.0 GB/s.

## 5.4 Does it fit in 8 GB of HBM?

DERIVED, 9B at N=1, from `rtl/model_cfg_pkg.vhd` dimensions:

```
attention layers  = blocks / attn_interval      = 32 / 4  = 8
GDN layers        = 32 - 8                                = 24
d_inner           = lin_val_heads x lin_head_dim = 32 x 128 = 4096

GDN recurrent state (persistent, int16):
  24 x 4096 x 128 x 2 B                         = 25.17 MB = 0.0252 GB

KV per token, C's on-HBM record is 272 B per 256-element head vector
(8 B block exponents + 8 B pad + 256 B mantissas):
  8 layers x 4 kv_heads x 2 (K and V) x 272 B   = 17,408 B/token

weights (worst-case packed)                     =  5.087 GB
HBM                                             =  8.590 GB
free for KV = 8.590 - 5.087 - 0.025             =  3.478 GB
max context = 3.478e9 / 17408                   =  199,793 tokens
```

**Weights fit with 3.5 GB to spare. Full 262,144 context does not.** The ceiling
lands at ~200k tokens, which corroborates the 202,621 in
`docs/2026-08-27_9b-single-card-resource-envelope.md:106` to within 1.4% (the
difference is that document using 5.0364 GB unpadded where this uses the
worst-case packed 5.087 GB).

## 5.5 The number that actually binds

DERIVED. The link is irrelevant after the first 1.5 s; HBM read bandwidth per
token is the constraint:

```
4.4642 GB streamed per token / 288.0 GB/s MEASURED  = 15.5 ms
                                                     = 64.5 tok/s hard ceiling
```

288.0 GB/s is MEASURED (`hw/fk33/results/hbmbw_30port_300mhz.txt`, 30 ports,
300 MHz, 96,000,000 beats, zero non-OKAY responses). Achieving it requires 30
HBM AXI ports; the current design has 2, which would give
`16.0 GB/s -> 279 ms/token -> 3.6 tok/s`.

---

# 6. The ordering constraint

**Loading is a one-time bulk operation, and subsystem D assumes exactly that.**

`docs/superpowers/specs/2026-08-24-transformer-sequencer-design.md:742-751`,
cold boot, in order:

1. Bitstream, PCIe and BAR up.
2. **Host loads the packed weights into HBM**, parses every tensor header, and
   generates the descriptor table for this card's rank and topology.
3. Host loads the descriptor table, norm weights and B constants into URAM.
4. Host releases reset. D sits in IDLE.

Then per token the host writes X and pulses `go`, and D walks a table of 546
descriptors at 9B (`rtl/seq_desc_fetch.vhd:148-149`). Weights are never touched
by the host again.

**Nothing streams per layer, and nothing is designed to.** The evidence:

- D's own weight-prefetch position is that there is none:
  "Weight prefetch across the collective is NOT provided"
  (`...sequencer-design.md:446-449`), and REQUEST R1 asks A for a preload
  mechanism that does not exist (`:921`). Both presuppose the weights are
  already in HBM; the question is only about overlapping AR issue.
- A's `weight_streamer` takes a base address and a beat count per job
  (`rtl/weight_streamer.vhd:53-57`) and issues plain sequential bursts from it.
  There is no concept of a residency check, a miss, or a fill.
- A's whole bandwidth model reads the entire weight set from HBM once per token
  (section 5.5 above). That is only sane if the weights are HBM-resident.

**Consequence for the missing hops.** Because loading is bulk and up front,
the ordering constraint "layer N resident before layer N is issued" is satisfied
trivially and is not a design problem. What it does mean is that **the host must
know every tensor's HBM base address before the first token**, and must
communicate it. That manifest is hop 1 plus hop 9 and neither exists: the packer
writes one file per tensor with no placement, and D's descriptor fetcher does not
read the base array.

---

# 7. Where a document and the RTL disagree

Recorded as findings, believing the RTL.

**F1. "The PS parses the header and is authoritative" does not survive the
retarget.** `rtl/matvec_int4.vhd:14-20` and spec A section 6.4 (line 596) both
assign header parsing to a PS. The FK33's VU33P has no PS. The statement is
still true of the AXU3EG build and false of every FK33 build. Nothing in the
FK33 documents contradicts it; nothing acknowledges it either.

**F2. `tools/pack_int4.py:203` asserts a platform constant as if it were the
invariant.** `nports = rows_if` is a consequence of `AXI_DW = 128`, and the
comment says so, but the parameter is not exposed and `--rows-if 80` will
silently emit an 80-sub-region file that no FK33 design can consume. It will not
fail; it will produce a plausible wrong file. Given that `--audit --rows-if 80`
runs happily today (measured, section 5.2), this is a live foot-gun.

**F3. The DMA BRAM guard rationale.** `build_fk33_pcieep.tcl:539-541` says a bad
offset "lands on nothing"; the BRAM is adjacent to the top of HBM with no gap, so
a small overrun lands in the BRAM. See section 3.

**F4. Spec A section 15.5 understates the 64-bit change.** It says the change is
"confined to `rtl/matvec_int4_axi.vhd` and `hw/mv_driver.c`". That is true for
the AXU3EG. On the FK33 there is no `mv_driver` and no AXI-Lite register map in
the loop, so the same change lands in whatever replaces them, which does not
exist, so the claim cannot be checked.

**F5. `rtl/model_cfg_pkg.vhd:82-83` says 9B is "about 4.5 GB against 8 GB HBM".**
Already corrected in
`docs/2026-08-27_9b-single-card-resource-envelope.md:638` (the real figure is
5.036 GB, and 4.5 GB drops the scales entirely). The comment in the RTL has not
been updated and is the one a future reader will hit first.

---

# 8. What was measured today, and how to repeat it

All from `/home/orencollaco/GitHub/llama.vhdl` at `c87003b`. `gguf-py` resolves
from `/mnt/storage/llama-dflash2-src/gguf-py` (`tools/pack_int4.py:32-39`).

```sh
# packer on a real GGUF tensor, plus its own reconstruction check
python3 tools/pack_int4.py /mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf \
        blk.0.ssm_alpha.weight alpha.mv4i --rows-if 4 --verify

# the two independent cross-checks of the same file
cc -O2 -o mv4i ref/matvec_int4.c && ./mv4i alpha.mv4i
python3 tools/pack_int4.py --crosscheck alpha.mv4i

# whole-model packed size, at three ROWS_IF
for r in 4 58 80; do
  python3 tools/pack_int4.py --audit \
      /mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf --rows-if $r --cards 1
done
```

Runtime is about 40 s for the pack (it dequantises the whole tensor through
`gguf-py`) and a few seconds each for the audits, which read shapes only.

**Measurement traps hit.**

- `read_tensor` returns `(M, K)` with `K = ne0`, so `blk.0.ssm_alpha.weight`
  listed as `5120x48` is `M=48, K=5120`, not the other way round
  (`tools/pack_int4.py:63-72`). Picking a tensor by its listed shape gets this
  backwards half the time.
- `--audit` prints "DOES NOT FIT" for the 27B at `--cards 1`. That is correct
  and not a fault: 27B needs 4 cards. It is not evidence about 9B.
- The `--verify` RMS of 7.99% on `ssm_alpha` looks alarming and is not a
  regression. It is a Q8_0-class tensor being taken to 4.5 bits, which is the
  known and measured cost in spec A section 6.1.

---

# 9. Open, not yet answered

- **What replaces `weight_streamer` on HBM.** Not designed. Spec A section 14.5
  lists three requirements (lane/port decoupling, multiple scale sub-regions, a
  CDC discipline between the ~450 MHz HBM ACLK and the core clock) and defers
  all three until the card is in hand.
- **Whether A's ports address HBM port-locally or through the global switch.**
  The 288 GB/s measurement used port-local addressing
  (`rtl/hbm_tg.vhd:20-25`); the packed file layout depends on the answer.
- **Where the descriptor comes from on a PS-less card.** Host over AXI-Lite, or
  D. Both are plausible; neither is built.
- **Whether the Python and C packers produce byte-identical files.** Spec A
  section 6.4 says a conforming pair must. Not tested. The cross-check above
  tests interpretation, not bytes.
- **The 9B parameter count has never been measured**, because no 9B GGUF is on
  this machine. Every 9B number here inherits that.
- **The `pcieep` bitstream has never been built or powered.** Timing, GT
  placement and everything about the card remain unknown.

---

# 10. What must be built next, shortest path first

Ordered by dependency, not by size. The split between "blocks first bring-up" and
"can wait" is the operative distinction.

## Blocks first bring-up

**N1. Build and power the `pcieep` bitstream.** `./pcieep_build.sh`, ~1-1.5 h,
12-20 GB peak. Then the staged checklist in
`docs/2026-08-27_fk33-pcie-bringup-procedure.md`. Until a link trains, every hop
downstream is unverifiable and hops 3 through 6 are only claims. Nothing else on
this list can be validated first.

**N2. Prove DMA into HBM and back, with the packed file as the payload.**
`fk33ctl.py load` / `verify` against a real `.mv4i`, not a random pattern. This
retires hops 2 through 6 in one step and measures the actual link throughput,
which is the only number in section 5.3 that is currently an estimate.

**N3. Decide and write down the HBM residency map.** Which pseudo-channel each
weight sub-region lands in, whether A's ports address port-locally or through
the global switch, and what alignment the packer must therefore honour. This is
a document plus a constant, not RTL, and it is on the critical path because both
N4 and N6 depend on it. Doing it after the packer is changed means changing the
packer twice.

**N4. Design the HBM `weight_streamer` replacement.** The section 14.5 work:
decouple `NPORTS_W` from physical ports, add multi-sub-region scales, define the
CDC. Fix `AXI_DW = 256` and pick a `ROWS_IF` that the port budget actually
admits. `ROWS_IF = 58` at `AXI_DW = 256` needs 29 weight ports of the 30
available, which is the tightest thing on this list and the reason it deserves
its own analysis rather than an assumption.

**N5. Widen `ADDR_W` to 64 and re-run `sim/run_matvec.sh`.** Small, mechanical,
and it must precede any FK33 build because 32 bits cannot address a 5 GB image.
The datapath already threads it (spec A section 15.5); only whatever replaces
the AXI-Lite register map hardcodes 32.

**N6. Extend `pack_int4.py` to the FK33 geometry**, once N3 and N4 fix the
target. Expose `AXI_DW` and `n_scale_sub` instead of deriving `nports` from
`rows_if`. Add `--crosscheck` to `sim/run_matvec.sh` so the Python-to-C link
stops being a manual step.

**N7. Build the whole-model image and its manifest.** A tool that walks every
tensor, places it, emits one contiguous blob plus a table of per-tensor bases,
shapes, `w_exp` and `out_shift`. Today this is a protocol sketch in prose
(`docs/2026-08-27_pcie-host-bringup-plan.md:508-537`).

**N8. Give the descriptor a source.** Minimum viable: an AXI-Lite register block
on the endpoint's BAR that holds one A descriptor, so the host can drive a single
matvec against HBM-resident weights and compare against `ref/matvec_int4.c`.
That is the FK33 equivalent of `hw/mv_driver.c` and it is what closes the chain
end to end for the first time.

**N9. Instantiate `matvec_int4` in an FK33 build.** One tensor, one matvec, one
comparison. The first bitstream in which a weight travels the whole path.

## Can wait

**N10. `seq_desc_fetch`'s base array fetch** (`rtl/seq_desc_fetch.vhd:111-113`).
Needed for D to drive A autonomously; not needed for N8's host-driven single
matvec. Blocked on N4 anyway, since `nsub_w` and `nsub_s` are undefined until the
port budget is fixed.

**N11. Weight preload / prefetch** (D REQUEST R1). Explicitly not needed at
N=2, let alone N=1. Worth ~1.3% of a token budget.

**N12. Byte-identity test between the Python and C packers.** A real hole in the
section 6.4 discipline, but the interpretation cross-check now covers the failure
modes that would actually corrupt a result.

**N13. Everything about sharding.** N=1 for 9B, so `--cards`, the shard
alignment penalty and subsystem E stay out of the path entirely.

The shortest honest statement of the critical path is: **N1, N2, N3, N4, N5, N6,
N7, N8, N9.** Six of those nine are design or tooling and need no card; two need
the card in the slot; one needs a bitstream that takes an hour and a half.
