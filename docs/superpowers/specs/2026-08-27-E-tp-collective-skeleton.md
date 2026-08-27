# Subsystem E: tensor-parallel collective -- skeleton and interface spec

Analysis + skeleton, 2026-08-27. Companion to
`docs/superpowers/specs/2026-08-21-tp-collective-design.md` (the numeric
contract, still normative for the arithmetic) and to
`rtl/tp_collective_skel.vhd` (this document's entity, analyzes clean, does
nothing).

**STATUS: analysis and a documented skeleton. Nothing here is verified. No
RTL is implemented, no simulation has run against E, and the single most
important input to every number below is UNMEASURED.** Read section 1 before
reading anything else, because if section 1 resolves the wrong way, sections 3
through 5 are answering a question that does not exist.

**What this document adds** over the 2026-08-21 spec: first-party evidence for
the physical link rather than a citation chain, the per-token traffic
arithmetic shown rather than tabulated, a bandwidth sensitivity table with the
cliff located, a synchronization design with a proof of the buffer count and
named detectors for every failure it admits, per-port back-pressure discipline,
and a "what I could not determine" section.

---

## 1. The physical link

### 1.1 Finding, in one sentence

**The only path off an FK33 is its PCIe card edge; the two-card transport is
therefore PCIe peer-to-peer or nothing, and whether PCIe P2P works at all
between two FK33s is UNKNOWN, because no FK33 has ever enumerated on PCIe on
this workstation and only one card exists.**

### 1.2 What is ESTABLISHED, with evidence

**(E1) The FK33 has no QSFP, no SFP, no expansion header and no cabled serial
connector.** Read in full from the only vendor board file that exists,
`~/GitHub/SQRL_FK33/board_files/sqrl_fk33/1.1/sqrl_fk33.xdc` (103 lines). The
complete non-PCIe pin list is:

```
SYSCLK0_200_P/N     BC26 / BC27   LVDS
MAIN_I2C_SCL/SDA    BB24 / BA24   LVCMOS18
GPIO_LED_0..6_LS    BD25 BE26 BD23 BF26 BC25 BB26 BB25
PCIE_PERST          BE24
PCIE_100MHZ_CLK_P/N AD9 / AD8
PCIE_RX_P/N[0..15], PCIE_TX_P/N[0..15]
```

Corroborated by `~/GitHub/SQRL_FK33/board_files/sqrl_fk33/1.1/part0_pins.xml`
(78 pins, part `xcvu33p-fsvh2104-2L-e`, pins 0-13 non-PCIe, pins 14-77 the 16
PCIe lanes), and by this repo's own copy at `hw/fk33/fk33_i2cprobe.xdc`, whose
`# MGT` heading sits above the PCIe lanes and nothing else.

**(E2) The die has 32 GTY lanes; 16 are spoken for by PCIe and the other 16 go
nowhere any file describes.** DS890 Table 17 (`docs/datasheets/
ds890-ultrascale-overview.pdf`) gives VU33P: 32 GTY, 4x PCIE4C, 0x PCIE4.
Corroborated from a real routed design in this repo,
`hw/fk33/fk33_firstlight_util.rpt:179-180`:

```
| GTYE4_CHANNEL |  0 | 0 | 0 | 32 | 0.00 |
| GTYE4_COMMON  |  0 | 0 | 0 |  8 | 0.00 |
```

Absence of the other 16 lanes from the board XDC is strong evidence that they
reach no connector, but it is **not schematic-level proof**: no FK33 schematic
exists on this machine. The MGT supplies are live and in spec on the card
(`hw/fk33/baseline_bench_2026-08-24.txt`: `VUSER0_MGTAVCC 0.9011 V`,
`VUSER1_MGTVCCAUX 1.8016 V`, `VUSER2_MGTAVTT 1.2041 V`), so the transceivers
are powered regardless of where they terminate.

**(E3) The PCIe block is `PCIE4C_X1Y0`, whose ceiling is Gen3 x16 or Gen4 x8.**
`board.xml` pins `block_location PCIE4C_X1Y0` and `preferred_ip
pcie4c_uscale_plus`. DS890 line 8060-8061: "PCIE4C blocks are compliant to the
PCI Express Base Specification v3.1 supporting up to 8.0 GT/s (Gen3) and
compatible with PCI Express Base Specification v4.0 supporting up to 16.0 GT/s
(Gen4). PCIE4C blocks support up to 16 lanes at Gen3 or up to 8 lanes at Gen4."
Both configurations give the same payload ceiling, **15.75 GB/s per direction**
(8 GT/s x 16 lanes x 128/130 / 8, and 16 GT/s x 8 lanes x 128/130 / 8).

**(E4) The main I2C bus holds six devices and none of them is an optical cage.**
Three JC42.4 temperature sensors at 0x18/0x19/0x1f and three MCP45X1-class
digital pots at 0x2c/0x2d/0x2e, from two consecutive identical full scans
(`docs/debugging/2026-08-24_fk33-sysmon-vccint-undervolt.md:336-341`). No
module EEPROM at 0x50/0x51, no I2C mux. Consistent with (E1), not independent
proof of it.

**(E5) The card has been physically installed in a host slot and has never
enumerated.** `docs/2026-08-25_single-card-fallback-decision.md:46-48`: "No
FK33 has ever appeared in `lspci` on this workstation; every result to date,
including tonight's 288 and 353 GB/s, went over JTAG." The reason is stated at
`docs/debugging/2026-08-24_fk33-sysmon-vccint-undervolt.md:264-266`: "Our
bitstream has no PCIe endpoint, so it never does." Every bitstream built here
sets `EnablePCIe 0` (`hw/fk33/gen_firstlight.py:31-33`,
`hw/fk33/build_fk33_i2cprobe.tcl:51`).

### 1.3 What is UNKNOWN, in those words, and what would settle each

| # | UNKNOWN | The measurement that settles it | Cost |
|---|---|---|---|
| U1 | **Whether an FK33 enumerates on PCIe at all.** | Build any bitstream with `EnablePCIe 1`, seat the card, boot, `lspci -d 1e24:1533`. | One build, ten minutes with the case open. No second card needed. |
| U2 | **The physical card-edge width.** The vendor's own files contradict each other: `sqrl_fk33.xdc` and `part0_pins.xml` constrain **16** lanes, and `board.xml`'s description says "PCIe x16 edge connector", but the same `board.xml:403` names the connector component **`pcie_8lane_edge`**. | Look at the card edge and count the finger groups; or read `lspci -vv` `LnkCap` after U1. | Free. The card is on the desk. |
| U3 | **The negotiated generation and width in practice.** The vendor example builds **x1 Gen3** with x16 commented out (`~/GitHub/SQRL_FK33/projects/fk33_example.tcl:158-159`, carried verbatim into `hw/fk33/build_fk33_i2cprobe.tcl:230-231`). Nothing has ever linked. | `lspci -vv` `LnkSta` after U1, on a build that requests x16. | Same build as U1. |
| U4 | **Whether FPGA-to-FPGA posted writes to a peer BAR are routed rather than bounced or dropped**, on any topology reachable here. | Two cards, two BARs, one card writes a pattern into the other's BAR, the other reads it back over JTAG. | A second card (~$300-650) plus a slot pair. |
| U5 | **Measured one-way P2P latency and effective payload bandwidth.** Every timing number in this document and in the 2026-08-21 spec is a model, not a measurement. | The U4 rig plus a free-running counter latched on the peer's flag write. | Same rig as U4. |
| U6 | **Whether this chassis can host the U4 test.** `docs/fpga-hardware-recon.md:688-698` proposes both cards in the two chipset x4 slots as "probably the better test", since the known `CNS` failure was **across** root complexes. `docs/2026-08-25_single-card-fallback-decision.md:57-59` asserts the opposite: "there is one CPU-connected x16 slot and the others are chipset x4. A second card in this chassis would reproduce the failure, not test around it." **These two project documents contradict each other and neither cites a measurement.** The board has PCIEX16 (CPU), PCIEX4_1 and PCIEX4_2 (both chipset), so two cards *can* both sit on the PCH side, which is the configuration recon calls favourable and which the 08-25 note appears not to have considered. | Resolve by doing U4 in the two chipset slots. | Included in U4. |
| U7 | **Where the other 16 GTY lanes terminate.** No schematic exists. | An FK33 schematic, or continuity probing of the PCB. | Vendor request, or hands on the board. |

### 1.4 The fallback if P2P does not work: host-mediated, and it is a real tax

If U4 resolves negative, the only remaining path is card -> host RAM -> card.
`docs/2026-08-27_direction-review-fable.md:295-300` records that "nobody has
computed the fallback cost". Section 4.5 computes it. Summary: **host-mediated
costs roughly 4x to 25x what P2P costs**, depending entirely on whether the
host side is a dedicated polling thread or an interrupt-driven driver, and it
converts 128 independent per-card operations per token into 128 host
serialization points. It is survivable at N=2 and structurally fatal at N=8.

### 1.5 Consequence for how confidently the rest of this document reads

Sections 2 and 5 (traffic, synchronization) are **independent of U1-U7**: the
byte counts follow from the model shape, and the synchronization argument
follows from the message pattern, whatever carries it. Sections 3 and 4 (time)
are **entirely conditional** on U4 and U5. That split is deliberate. Build the
skeleton against sections 2 and 5; do not commit to any schedule that depends
on section 4 until U5 has a number.

---

## 2. Bytes per token, derived

### 2.1 Model shape (verified against the specs, not taken on trust)

| Quantity | Value | Source, checked |
|---|---|---|
| `d_model` | 5120 | A spec 14 retarget table |
| Blocks | 64 = 48 GDN + 16 attention | A spec 14 retarget table |
| FFN dim | 17408 | A spec 14 |
| GDN value heads / key heads | 48 / 16, so 24 / 8 per card at N=2 | A spec 14; B spec 4.2 |
| `head_v_dim`, `d_inner` | 128, 6144 | B spec 4.1 |
| Cards | N=2 for v3.0, N=8 for v4.0 | recon ladder |

Two independent parameter-count checks that the block inventory is right, both
of which would fail if a projection were missing from the sharding table:

```
FFN   : 3 x 5120 x 17408 x 64 blocks             = 17.11 B   (A 14 says 17.11 B)
Attn  : (5120x12288 + 2x5120x1024 + 6144x5120)
        = 104.9 M x 16 blocks                    =  1.678 B  (A 14 says 1.68 B)
```

The attention figure closes **only** with `wq`'s output at 12,288 wide, i.e.
with the gate fused into `wq` as C spec 1.1(a) requires
(`[Q_h0(256), G_h0(256), Q_h1(256), ...]`). That matters here: the gated
attention output gate is **not** a separate matvec and therefore adds **no**
collective. Had it been separate and row-parallel it would have added 16
collectives per token, +12.5%. The check is why this document does not carry
that risk as an open item.

### 2.2 Collectives per token

From A spec 14.3's sharding table, the row-parallel matvecs -- the only ones
needing an all-reduce -- are:

| Matvec | Present in | Split | Output rows |
|---|---|---|---|
| FFN down | all 64 blocks | row (K = 17408, 8704/card) | 5120 |
| attn o (`wo`) | 16 attention blocks | row (K = 6144, 3072/card) | 5120 |
| GDN `ssm_out` | 48 GDN blocks | row (K = 6144, 3072/card) | 5120 |

Column-parallel matvecs (`wq/wk/wv`, GDN `wqkv`/`wqkv_gate`, FFN gate and up)
need nothing. B spec 4.2 confirms the GDN recurrence itself needs no collective
at all: state is per-value-head and never crosses heads.

```
per block            = 1 (attn o OR GDN ssm_out) + 1 (FFN down) = 2
per token            = 2 x 64 blocks                            = 128
```

**Every one of the 128 has the same shape: 5120 output rows.** That uniformity
is worth stating because it means E has exactly one message size and needs no
size negotiation. It is also why `MAXROWS` should be 5120, not 17408 -- see 7.1.

### 2.3 Bytes per message

A's partial mode (`out_mode = "10"`, A spec 14.2) emits the **unrounded s48
accumulator**, transported in 64-bit slots sign-extended. The 8-byte figure is
not a choice E made; it is A's corrected contract, and it doubled every byte
count in the 2026-08-21 spec when it landed on 2026-08-22.

```
payload  = 5120 rows x 8 B                                = 40,960 B
trailer  = y_exp (4) + out_shift (4) + seq flag (4)       =      12 B
message  =                                                  40,972 B
```

The trailer is 0.03% of the message. Every figure below uses 40,960 B and the
trailer is ignored except where its ordering matters (section 5.2).

### 2.4 Bytes per token per card

At **N=2** the all-to-all degenerates to one exchange. Each card sends its
partial to the one peer and receives the peer's. Both cards then hold both
partials and compute the identical full result locally, so **no broadcast phase
exists and no extra bytes are sent**.

```
sent per card per token     = 128 collectives x 1 peer x 40,972 B
                            = 5,244,416 B  =  5.244 MB  =  5.001 MiB
received per card per token = the same, concurrently (PCIe is full duplex)
```

At **N=8** with direct all-to-all, each card writes its full partial to all 7
peers:

```
sent per card per token     = 128 x 7 x 40,972 B
                            = 36,710,912 B = 36.71 MB = 35.01 MiB
```

> **Unit correction against the 2026-08-21 spec 2.4.** That table reads
> "5.12 MB" and "35.8 MB". Both are the payload-only byte counts divided by
> 1024 once and by 1000 once: 5,242,880 B is 5120 KiB, which is 5.00 MiB or
> 5.24 MB, not 5.12 MB. The exact byte counts are above. The error is 2.4% and
> changes no conclusion, but the mixed units should not survive into a third
> document.

### 2.5 Context: this traffic is not on the HBM budget

Weights live in on-card HBM: 7.57 GB read per card per token (A spec 15.4c).
E's 5.24 MB crosses **PCIe**, a link that carries nothing else during decode --
weights were loaded at boot, and the host's per-token I/O is one token id in
and one logit vector out. So E's bandwidth argument and A's are independent,
which is what makes the overlap requirement of the 2026-08-21 spec 2.5
structurally sound rather than merely hopeful. E's traffic is 0.069% of the
per-card weight read.

---

## 3. Time cost, with assumptions stated

### 3.1 The model

```
T_coll  = t_lat + S / BW_eff + t_tail
T_token = 128 x T_coll                     (fully serialized: pessimistic bound)
```

| Term | Value used | Assumption, and how it could be wrong |
|---|---|---|
| `S` | 40,960 B | Exact, from 2.3. Solid. |
| `t_lat` | 2 us default | **UNMEASURED (U5).** One-way posted-write latency from a card's AXI master to the peer's BAR, plus the receiver's flag-poll granularity. Recon 4b calls "under 2 us" a published-literature figure for FPGA-to-peer small messages, and calls its own earlier 2-3 us estimate "reasonable, possibly conservative". Could plausibly be 1 us behind a good switch or 5-20 us across an Intel PCH. |
| `BW_eff` | swept, 0.25 to 15.75 GB/s | **UNMEASURED (U5), and the ceiling itself is UNKNOWN (U2, U3).** 15.75 GB/s is the PCIE4C payload ceiling from (E3). Real effective bandwidth is lower: TLP header overhead on a posted write with 64-bit addressing costs ~24 B per MPS-sized packet, so ~91% at MPS 256 B and ~95% at MPS 512 B, before any switch or root-port inefficiency. |
| `t_tail` | 1.07 us | Derived, not measured. The BFP pack needs `amax` over all 5120 reduced rows, so pass 1 (align, sum, `round_shift`, `sat32`, `amax`) can overlap arrival but pass 2 (`ns`, `round_shift`, `sat16`) cannot start until the last row is summed. At `LANES = 16`, 5120/16 = 320 cycles = 1.07 us at 300 MHz. `LANES = 32` halves it to 0.53 us; `LANES = 8` doubles it to 2.13 us. LUT-only either way. |
| Budget | 39 ms/token | D spec 11, at N=2, 27B, `ROWS_IF ~ 58`, `MACS = 192`, 276-300 MHz. Itself derived and explicitly "informative, derived -- nothing here is measured". `docs/2026-08-27_direction-review-fable.md:253` notes the 0.717 V operating point makes it ~20-22 tok/s rather than ~26, i.e. the real budget is likely **larger** than 39 ms, which makes E's percentages **optimistic-conservative**: using 39 ms overstates E's share. |
| Serialization | assumed total | The 2026-08-21 spec 2.5 makes overlap normative, so a real system should beat these figures. They are the bound that holds even if overlap is never achieved. |

### 3.2 Sensitivity to link bandwidth (t_lat = 2 us, t_tail = 1.07 us, N=2)

| `BW_eff` GB/s | what it corresponds to | transfer us | `T_coll` us | `T_token` ms | % of 39 ms |
|---|---|---|---|---|---|
| 15.75 | PCIE4C ceiling, Gen3 x16 or Gen4 x8, 100% efficient | 2.60 | 5.67 | **0.726** | **1.9%** |
| 14.0 | the same at ~89% TLP efficiency | 2.93 | 5.99 | 0.767 | 2.0% |
| 7.88 | Gen3 x8, or Gen4 x4 (this box's chipset slots) | 5.20 | 8.27 | **1.058** | **2.7%** |
| 6.0 | Gen3 x8 at ~76%, or a congested x4 | 6.83 | 9.89 | 1.267 | 3.2% |
| 4.0 | Gen3 x4 | 10.24 | 13.31 | 1.704 | 4.4% |
| 2.0 | Gen3 x2, or a badly bounced path | 20.48 | 23.55 | **3.014** | **7.7%** |
| 1.0 | Gen3 x1 -- what the vendor example actually builds | 40.96 | 44.03 | **5.636** | **14.5%** |
| 0.5 | | 81.92 | 84.99 | 10.879 | 27.9% |
| 0.25 | | 163.84 | 166.91 | 21.364 | 54.8% |

### 3.3 Sensitivity to latency, at `BW_eff = 7.88 GB/s`

| `t_lat` us | `T_coll` us | `T_token` ms | % of 39 ms |
|---|---|---|---|
| 1 | 7.27 | 0.930 | 2.4% |
| 2 | 8.27 | 1.058 | 2.7% |
| 5 | 11.27 | 1.442 | 3.7% |
| 10 | 16.27 | 2.082 | 5.3% |
| 20 | 26.27 | 3.362 | 8.6% |
| 50 | 56.27 | 7.202 | 18.5% |
| 100 | 106.27 | 13.60 | 34.9% |

### 3.4 Where the cliff is

Solving `128 x (2 us + 40,960/BW + 1.07 us) = fraction x 39 ms`:

| E's share of the token budget | requires `BW_eff` at least |
|---|---|
| 2% (0.78 ms) -- "negligible" | **13.5 GB/s** |
| 5% (1.95 ms) | **3.37 GB/s** |
| 10% (3.90 ms) | **1.50 GB/s** |
| 25% (9.75 ms) | 0.56 GB/s |
| equal to B's entire 589,824-cycle state sweep (1.97 ms) | 3.32 GB/s |

**Read the table this way.** E is *comfortable* anywhere above ~3.4 GB/s and
*never negligible* below ~13.5 GB/s. The interesting consequence is that E's
cost is only weakly sensitive to bandwidth across the whole plausible range:
Gen3 x16 and Gen4 x4 differ by 2x in bandwidth and by 0.33 ms in token time,
which is 0.8% of the budget. **The design does not need a fast link. It needs a
link that exists.** All the risk is in U4, not in U5's bandwidth half.

### 3.5 The 2026-08-21 spec's "latency-bound" premise is stale, and the algorithm choice survives anyway

Spec 2.2 states: "At 20 KB per message, latency dominates transfer: a PCIe
Gen3 x16 hop moves 20 KB in ~1.3 us against ~2 us of P2P latency." That was
written when the partial was 4 B per value. A's 2026-08-22 correction made it
8 B, and spec 2.4's own correction note half-acknowledges the consequence
("drifts from latency-bound toward transfer-bound") without redoing spec 2.2's
table.

Redone: transfer equals a 2 us latency at `BW = 40,960 B / 2 us = 20.5 GB/s`,
which is **above** the PCIE4C ceiling of 15.75 GB/s. So on any link this card
can physically have, **transfer dominates latency**, by 1.3x at the ceiling and
by 2.6x on a Gen4 x4 chipset slot. The premise is inverted.

The conclusion it was used to justify -- direct all-to-all over ring -- happens
to survive. Break-even between the two at N=8, comparing `7S/BW + t_lat` for
all-to-all against `14 x (t_lat + S/(8 BW))` for a ring:

```
7S/BW + t_lat = 14 t_lat + 1.75 S/BW
5.25 S/BW     = 13 t_lat
t_lat         = 0.404 x S/BW      =  1.05 us at BW = 15.75 GB/s
```

All-to-all wins whenever `t_lat` exceeds ~1.05 us, and no credible estimate
puts it below that. At N=2 the question does not arise: both algorithms are one
exchange. **Right answer, wrong reason. The reason should be corrected in
place rather than the table left standing.**

### 3.6 N=8, briefly, and why it is a different problem

At N=8 each card must push 7 messages out through **one** PCIe link, so the
egress serializes:

```
egress per collective = 7 x 40,960 B = 286,720 B
at 15.75 GB/s         = 18.2 us,  T_coll ~ 21.3 us
T_token               = 128 x 21.3 us = 2.73 ms
```

Against a v4.0 compute budget of roughly 39/4 ~ 10 ms (the weight-bound term
falls ~1/N), that is ~28% unoverlapped. The 2026-08-21 spec 2.4 says ~63%
against a 4.1 ms budget carried over from the superseded bandwidth-bound model.
Either way the conclusion is the same and is worth restating plainly: **at N=8
the collective is a first-order cost and the overlap requirement is not
optional.** It is also where the buffer cost bites (section 7.2).

### 3.7 DSP cost: zero, and the justification

Every operation in the 2026-08-21 spec 2.1 pipeline is multiply-free:
`floor_shr` alignment (barrel shifter, LUT), the `ACC_W = 52` summation (carry
chain), `amax` (magnitude compare), `msb_pos` (priority encoder, and
`util_pkg.msb_pos` is already a bounded 32-iteration form), `round_shift` (add
then shift), `sat32`/`sat16` (compare and mux). There is no multiply anywhere
in E.

The one way DSP appears is synthesis electing to build a wide adder in a
DSP48E2. `rtl/tp_collective_skel.vhd` pins `attribute use_dsp of skel :
architecture is "no"` for exactly that reason, and any DSP in E's OOC report
should be treated as a defect rather than a cost. Whole-die DSP is the binding
resource at 90.5-91.9% of 2,880 (B spec 3.6), so E's zero is load-bearing:
it is the reason E can be added at all.

---

## 4. If P2P does not work: the host-mediated cost

Computed here because `docs/2026-08-27_direction-review-fable.md:295-300`
records that nobody has. **All of it is a model; none is measured.**

Path: card A's partial DMAs to host RAM, host software notices, host DMAs it
into card B, card B notices. Two link traversals plus one or two software
wakeups per collective per direction.

```
T_coll(host) = 2 x (S/BW) + t_sw + t_tail
```

| `t_sw` (host software round trip) | regime | `T_coll` us | `T_token` ms | % of 39 ms |
|---|---|---|---|---|
| 5 | dedicated spin-polling core, best case | 16.5 | 2.11 | 5.4% |
| 15 | spin-polling with cache-line ping-pong | 26.5 | 3.39 | 8.7% |
| 30 | polling thread, scheduler-visible | 41.5 | 5.31 | 13.6% |
| 60 | interrupt + thread wakeup, typical | 71.5 | 9.15 | 23.5% |
| 150 | interrupt + a scheduler miss | 161.5 | 20.7 | 53.0% |

(`BW_eff = 7.88 GB/s`, so `2 x S/BW = 10.4 us`; `t_tail = 1.07 us`.)

Three consequences beyond the number:

1. **It is survivable at N=2 with a spin-polling core, and only then.** The
   direction review's "+10-30% token time" guess is in the right band for
   `t_sw` in the 30-60 us range. Burning a full host core to poll 128 times per
   token is a real system cost, not a footnote.
2. **It destroys the overlap argument.** The 2026-08-21 spec 2.5 rests on the
   collective contending with nothing but PCIe. A host-mediated collective
   contends with the host scheduler, and 128 serialization points per token
   through one software path is a jitter source, not a pipelined one.
3. **It does not scale.** At N=8 the host becomes a 7x-fanout hub and the
   figures above multiply. Host-mediated is an N=2 fallback only.

---

## 5. Synchronization discipline

This section is independent of section 1's outcome: the same argument holds for
any transport where the peer's writes cannot be refused.

### 5.1 How the two cards agree that a collective has started

**They do not signal it. They compute it.** Both cards run the identical
descriptor program under subsystem D, so the collective index is a
deterministic function of position in that program:

```
seq = token_index x 128 + block_index x 2 + which_collective_in_block
```

`seq` must be **derived from the program counter, not from a free-running
counter incremented on each completion**. Those are the same value only while
nothing goes wrong; after any aborted or retried collective they diverge
permanently, and a counter-derived `seq` would then silently pair collective k
on one card with k+1 on the other. Since the payload is a plain vector of the
right length, that pairing produces a plausible wrong answer with no detector
anywhere in the system.

The sequence number is therefore both the start agreement and the only
identity a message carries. It is written **last** in the trailer, after the
payload, so its arrival implies the payload's arrival: PCIe posted writes to
one destination complete in order **per source-destination pair**. That
ordering does not hold between different sources, which is why every peer gets
its own region and its own flag rather than sharing one (2026-08-21 spec 2.3,
correct and retained).

### 5.2 Why the peer is a producer that cannot be back-pressured

`docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md` is this project's
worked example of what that costs. `gdn_head_emit` asserted `done` for one
cycle with no handshake, so when the consumer was busy the pulse was missed and
**an entire head was silently discarded**. The generalised lesson it ends on:
"in a design whose producer cannot be back-pressured, throughput margin is a
CORRECTNESS property, and it does not appear in any static report."

E sits on the same boundary, twice over, and worse:

| Producer into E | Can it be stalled? | Why | Failure if E is not ready |
|---|---|---|---|
| A's result port `y_we/y_addr/y_data/y_mask` | **No** | `rtl/matvec_int4.vhd:82-86` has no `y_ready` | Beat lost. Silent. |
| The peer's PCIe posted writes | **No, and no such path can be added** | The producer is a different device in a different slot. A posted write has no completion and cannot be refused by the receiving datapath | Buffer overwritten. Silent. |
| E's own outbound stream | **Yes** | The bridge's `s_ready` | This is the only back-pressure E must honour, and it must honour it |

The head_emit episode also supplies the metric warning that applies directly:
after the fix, COL_GAP=3 went from "0 refused columns" to "167 refused columns"
**as a result of a bug fix**, because the lossy path had been dropping data
instead of reporting pressure. Any E metric that rewards the absence of
overrun events will prefer the broken design.

### 5.3 The buffer count, with a proof

Single-buffered receive is the silent-corruption configuration, and it is
reachable in normal operation, not only under fault. Sketch: card A completes
collective k, computes the next segment, and sends its message for k+1. Card B
may still be waiting on A's message for k, because messages cross in flight.
A's k+1 payload then lands in the same buffer as k and replaces it. The flag
for k+1 arrives too, so a receiver testing only "a flag arrived" accepts the
wrong payload.

**Claim: `NBUF = 2`, indexed by `seq mod 2`, is sufficient at N=2.**

```
A can send k+2
  => A completed k+1
  => A received B's message for k+1
  => B sent k+1
  => B completed k
  => B CONSUMED A's message for k
```

So buffer `(k mod 2)` is free before anything can land in it again. The
argument generalises pairwise to N=8 under all-to-all, because each pair's
dependency chain is identical. It rests on one property that must be made
normative rather than left implicit:

> **A card must not initiate the send for collective k+1 until it has consumed
> the peer's payload for collective k.**

That holds automatically while E is a single non-pipelined unit, which is what
the skeleton is. A future pipelined E that prefetched the next send would break
the proof and would need `NBUF = 3` or an explicit credit.

### 5.4 What detects drift, and what happens

`NBUF = 2` prevents the ordinary case. Detection exists for the cases it does
not cover, because a structural argument that goes unchecked is a comment, not
a guarantee. Every row below is a named `err_code` in
`rtl/tp_collective_skel.vhd`:

| Condition | Detector | Code | Action |
|---|---|---|---|
| Peer flag never arrives | watchdog, `TIMEOUT_CYC` (300,000 at 300 MHz = 1 ms, ~170x the expected ~6 us) | `EC_TIMEOUT` | `err`, abort |
| Flag arrives with `seq /= seq_exp` | compare on the flag write | `EC_SEQ` | `err`, abort. A flag with `seq > seq_exp` is **not** a reason to proceed: it means a peer ran further ahead than 5.3 permits |
| Payload overwritten **during** the reduce | **seqlock recheck**: latch `r_tr_seq` when the flag arrives, re-read it after the last payload beat is consumed, compare | `EC_OVERRUN` | `err`, abort. This is the detector that converts a violation of 5.3 from silent corruption into a reported fault. One register and one comparator |
| Peer `out_shift` differs from ours | trailer compare | `EC_SHIFT` | `err`. Differing grids are legal and handled by alignment; a differing `out_shift` is not, because each card applies its own to the same reduced sum and the N copies of "the same" tensor then diverge downstream |
| `y_exp` spread > 17 | alignment stage | `EC_SPREAD` | `err`. Bound comes from A 14.2's packer policy (`ns` is 0..17); measured spread is <= 5 real, <= 6 adversarial |
| `out_exp` out of range after `- ns` | pack stage | `EC_OEXP` | `err` |
| `n_rows > MAXROWS` | at `start`, before any output | `EC_NROWS` | refuse |
| **A writes a new partial while E still owes the old one** | `p_we` asserted outside the states where it is legal | `EC_PWE` | `err`. This is the detector the head_emit doc's "open, not yet answered" section says should have existed and did not ("a watchdog that fires on `he_done` asserted while not in `S_IDLE` would have caught it on the first run; it does not exist") |

**What happens on any of them.** E raises sticky `err`; D's policy (D spec 10)
is to abort the token, latch `ERR_INFO`, and raise `token_done` with `err` so
the host never hangs. Recovery is `seq_init` replay.

**Both cards must abort or they diverge permanently.** There is no abort
message and there should not be one: a card whose peer has aborted simply never
receives the next flag and times out on its own. **Recovery is by mutual
timeout**, and the worst-case cost of one card aborting is one `TIMEOUT_CYC`
(1 ms) on the other. That is the reason `TIMEOUT_CYC` is a bounded number and
not "large": it is the resynchronization cost, not just a hang guard.

### 5.5 What is NOT detected

Stated so it is not mistaken for covered:

- **A correct `seq` with a corrupt payload.** PCIe covers link-level corruption
  with LCRC per TLP (and ECRC if enabled), so this requires a fault above the
  link -- a bridge address-decode bug, a BAR misprogramming, a buffer aliasing
  error. No checksum is proposed because the cost is real and the failure mode
  is not link-level. If one is ever wanted, a running XOR of the payload in the
  trailer is 64 bits of storage and one XOR per beat.
- **Two cards running different descriptor programs** whose `seq` values happen
  to coincide. Nothing in E can see this. It is D's and the host's problem, and
  the mitigation is that both cards load the same program image.
- **A peer that stops sending but keeps its link up.** Indistinguishable from a
  slow peer until `TIMEOUT_CYC`. That is what the watchdog is for and it is the
  correct answer, but it means a wedged peer costs 1 ms per collective until
  the host intervenes.

---

## 6. Entity and port sketch

The entity is `rtl/tp_collective_skel.vhd`, which analyzes clean under

```
ghdl -a --std=08 -frelaxed --workdir=<wd> rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
ghdl -a --std=08 -frelaxed --workdir=<wd> rtl/tp_collective_skel.vhd
```

(GHDL here is the mcode backend, so `ghdl -e` produces no binary and its
success means nothing. Analysis is the only claim being made.)

### 6.1 Ports and handshake discipline, per port

| Port group | Direction | Handshake | **Can the producer be stalled?** |
|---|---|---|---|
| `start`, `my_rank`, `n_rows`, `y_exp_l`, `out_shift`, `seq` | in, from D | level, sampled at `start`, held to `done` | n/a (D is master) |
| `p_we`, `p_addr`, `p_data` | in, from A's `y` port | **write strobe, NO ready** | **NO.** `matvec_int4.vhd:82-86` has no `y_ready`. E must accept unconditionally into BRAM and never gate. Buffer availability is D's obligation; E's job is `EC_PWE` detection |
| `r_we`, `r_peer`, `r_buf`, `r_addr`, `r_data` | in, from the PCIe bridge slave | **write strobe, NO ready, and none is possible** | **NO.** Producer is another PCIe device. Overrun is prevented by `NBUF=2` (5.3) and detected by the seqlock recheck (5.4) |
| `r_tr_we`, `r_tr_peer`, `r_tr_buf`, `r_tr_yexp`, `r_tr_shift`, `r_tr_seq` | in, trailer | same, and **`r_tr_seq` is written last by the peer** | **NO.** Same reason |
| `s_valid`, `s_ready`, `s_last`, `s_peer`, `s_addr`, `s_data` | out, to the PCIe bridge master | **valid/ready** | **YES, and this is the only one.** E must honour `s_ready` or lose beats into the fabric. The trailer beats must be issued after the last payload beat is **accepted**, not offered |
| `o_we`, `o_addr`, `o_data`, `o_exp` | out, to D's region memory | **write strobe, NO ready** | E is the producer and owns the rate, which is why the absence of a ready is safe here and unsafe on `p_*` |
| `done`, `o_ack` | out / in | **`done` is HELD until `o_ack`. It is NOT a pulse** | The head_emit fix, verbatim |
| `err`, `err_code` | out | sticky until `rst` or the next `start` (A 7.6 convention) | |

### 6.2 The receive region must be BRAM-backed, not HBM-backed

The stock FK33 example routes the PCIe BAR straight into HBM
(`xdma/M_AXI -> smartconnect pcie2hbm -> hbm/SAXI_00`, `hbm/SAXI_16`, per
recon 4b). Leaving it there would make every collective spend an HBM read of
40 KB, which at the measured 11.77 GB/s per port under a mixed R+W load (B spec
3.4) is ~3.5 us -- comparable to the transfer itself -- on a resource where
30 ports are shared across A, B, C and D and B alone already takes 4.

**Normative for E: the peer receive region is a distinct AXI slave backed by
E's own dual-port BRAM.** That is a block-design change (a second branch off
the XDMA master into a BRAM controller) and should be recorded as an obligation
on whoever builds the FK33 block design, not discovered later.

### 6.3 Generics

| Generic | Default | Note |
|---|---|---|
| `N_PEERS` | 2 | 8 for v4.0 |
| `MAXROWS` | **5120** | Not 17408. See 7.1 |
| `LANES` | 16 | Sets `t_tail = MAXROWS/LANES` cycles. LUT-only |
| `ACC_W` | 52 | `48 + clog2(N)`; s49 at N=2, s51 at N=8. Derived from A's interface bound, not the workload |
| `NBUF` | 2 | **Do not set 1.** 1 is the silent-corruption configuration (5.3) |
| `TIMEOUT_CYC` | 300000 | 1 ms at 300 MHz. Also the mutual-timeout resync cost (5.4) |
| `MAX_SPREAD` | 17 | A 14.2's packer-policy bound |

---

## 7. Resource notes

### 7.1 `MAXROWS` should be 5120, not 17408

The 2026-08-21 spec 2.6 declares `MAXROWS : positive := 17408 -- matches A's
MAXROWS_BFP`. **That is a bound on the wrong axis.** `MAXROWS_BFP` bounds A's
output rows across all jobs, including column-parallel ones. E only ever sees
row-parallel outputs, and section 2.2 shows every one of them has M = 5120; it
is their *input* dim K that reaches 17408, and K never crosses the link.

Cost of the mistake: 3.4x the buffer BRAM, for capacity that is unreachable by
construction.

### 7.2 BRAM, at `MAXROWS = 5120`

A BRAM36 in 512x72 mode holds 512 words of 64 bits, so 5120 rows = 10 BRAM36
per 64-bit buffer.

| Buffer | N=2 | N=8 |
|---|---|---|
| Local partial, 5120 x 64 | 10 | 10 |
| Receive, `(N_PEERS-1) x NBUF x 10` | 20 | 140 |
| `y32` intermediate, 5120 x 32 (can be aliased onto the local partial buffer) | 5 | 5 |
| **Total BRAM36** | **~35 of 672 (5.2%)** | **~155 of 672 (23%)** |

At `MAXROWS = 17408` those become ~119 (18%) and ~527 (78%), the latter being
simply infeasible.

> **This is worse at N=8 than the 2026-08-21 spec 2.4 states.** That section
> says "280 KB of receive buffers is ~70 BRAM36 at N=8", which is `NBUF = 1`.
> Section 5.3 makes `NBUF = 2` mandatory, so the honest N=8 figure is ~140
> BRAM36 of receive buffer, doubling that row. This is a real cost created by a
> correctness requirement and it should not be hidden. At N=8 the alternatives
> are: land peer payloads in HBM and pay a port (7.2 of B's measured 11.77 GB/s
> per port would be needed), or reduce incrementally as peers arrive so only
> one full-width accumulator is held rather than 7 payloads. The second is
> better and is not designed here.

### 7.3 DSP: 0. LUT and FF: not estimated

LUT and FF are deliberately left blank rather than guessed. The dominant terms
are the `LANES`-wide alignment barrel shifters (`ACC_W`-bit, shift 0..17), the
`ACC_W` adders, and the pack-stage comparators. A one-afternoon OOC skeleton
sweep over `LANES in {8, 16, 32}` would settle both and also settle the
`t_tail` term of section 3.1. It has not been run: **no Vivado was run for this
document**, by instruction.

---

## 8. What I could not determine

Required section. Ordered by how much of the above collapses if the item
resolves badly.

1. **Whether PCIe P2P works between two FK33s at all (U4).** Nothing in
   sections 3 or 4 has a measured input. This is the "$650 two-card question"
   the 2026-08-21 spec 3 already names, and it remains exactly as open as it
   was on 2026-08-21. **Only one FK33 exists.**
2. **Whether an FK33 enumerates on PCIe at all (U1).** Weaker than 1 and
   strictly prior to it. No PCIe-enabled bitstream has ever been built here.
   This is the cheapest open question in the entire project: one build and one
   `lspci`.
3. **The card-edge width (U2) and the negotiated link (U3).** The vendor's own
   board file names the connector `pcie_8lane_edge` while its XDC constrains 16
   lanes. Unresolved even though the card is physically present. It is a 2x
   bandwidth factor, which section 3.4 shows is worth ~0.33 ms of a 39 ms
   token, so it matters less than its prominence suggests.
4. **One-way P2P latency (U5).** Everything in section 3 uses 2 us from
   published literature via recon 4b. Section 3.3 shows E stays under 10% of
   budget up to ~25 us, so the design tolerates a bad answer; it does not
   tolerate no answer, because the overlap schedule of spec 2.5 cannot be
   designed against an unknown.
5. **Whether this chassis can host the two-card test (U6).** Two project
   documents disagree and neither measured. `docs/fpga-hardware-recon.md:688`
   says two chipset slots is "probably the better test";
   `docs/2026-08-25_single-card-fallback-decision.md:57-59` says a second card
   "would reproduce the failure". The board has two chipset x4 slots, so the
   configuration recon describes does exist. Unresolved.
6. **The real `t_tail`, and therefore `LANES`.** Derived at 5120/`LANES` cycles
   from the two-pass structure the BFP `amax` forces. Not synthesised, not
   simulated. Note the head_emit follow-on found that OOC area and Fmax numbers
   alone chose the wrong `RMS_LANES`, and only a refused-beat count exposed it;
   the same trap applies to choosing E's `LANES` from an OOC sweep alone.
7. **LUT and FF cost.** Not estimated. See 7.3.
8. **Whether the N=8 receive-buffer problem has a good answer.** Section 7.2
   names two options and designs neither. At N=2 it does not arise.
9. **Whether E's `done` can actually be awaited selectively by D**, which spec
   2.5 makes normative. D spec 11 budgets E at ~0.42 ms, implying serialization
   is assumed anyway. The two documents are not in conflict but they are not
   reconciled either, and the overlap has never been demonstrated.
10. **Whether the bounded, inexact reduction of spec 2.1 is acceptable at the
    27B model level.** It is bounded at "at most 1 count of `y32`, and 0 in
    most runs" against real A partials at N=2/4/8, which is a good bound, but it
    has had no end-to-end perplexity exposure of the kind that caught B's
    epsilon. Out of scope here; recorded because it is the numeric risk E
    carries and nobody owns it.

---

## 9. Files

| File | What it is |
|---|---|
| `docs/superpowers/specs/2026-08-27-E-tp-collective-skeleton.md` | this document |
| `rtl/tp_collective_skel.vhd` | port and handshake contract, analyzes clean, implements nothing |
| `docs/superpowers/specs/2026-08-21-tp-collective-design.md` | still normative for the numeric contract (its 2.1). Its 2.2 premise and its `MAXROWS`, unit and `NBUF` figures are corrected here |

---

## CORRECTION 2026-08-27, same day: the interconnect design already exists

This document's physical-link finding is **correct about the stock board and wrong to
treat the question as open**. The interconnect has already been designed and written up
in a separate repository, `~/GitHub/pcie-llm-hardware`, which should be read before any
further work on E.

**The mechanism.** The FK33's PCIe x16 edge pins ARE 16 GTY transceivers, and the PCIe
hard block is one possible consumer of them rather than a mandatory one. The design
gives **x4, one quad, to the host** for weight load, tokens and control, and runs the
remaining **12 lanes, three quads, as raw Aurora 64B/66B card to card**. So this
document's conclusion that the card has no I/O beyond the PCIe edge is right, and the
inference that the collective must therefore run over PCIe is wrong.

What this changes above:

- **The bandwidth sensitivity table is indexed by the wrong axis.** Aurora over 12 GTY
  lanes is not bounded by `PCIE4C_X1Y0`'s 15.75 GB/s. The document's own conclusion
  survives and strengthens: E's cost is only weakly sensitive to bandwidth, so what
  matters is that a link exists, and one is being built.
- **The "does PCIe P2P work between two FK33s" risk is retired by design, not resolved
  by measurement.** Aurora removes the PCIe switch, the ACS override, the root-complex
  question and the unmeasured P2P latency premise together. Latency becomes a design
  parameter of about 0.2 us.
- **The host-mediated fallback pricing (5.4% to 23.5% of budget) is not a fallback, it
  is the INTERIM PLAN.** Two FK33s run today over MCIO cables from one bifurcated x8/x8
  slot, with the host as a deliberate slow stand-in for the collective. That is enough
  to develop and test B, C and D on real hardware. The peer link is needed only for E.
- **N=4 is required, not an optimisation.** 262,144 context needs 8.59 GB of KV cache:
  11.86 GB per card at N=2 against 8 GB HBM, versus 5.94 GB at N=4. The GDN state is
  ~19 MB per card and constant in context, so the entire capacity problem is the 16
  attention layers. Any N=2 sizing in this document is therefore a stepping stone.

**Unchanged and still valid:** the per-token traffic derivation (5,244,416 B per card
per token at N=2), the sequencing design, the `MAXROWS` correction from 17408 to 5120,
the seqlock recheck, and the zero-DSP justification. None depend on the physical medium.
