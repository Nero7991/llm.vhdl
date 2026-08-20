# Subsystem A: INT4 Streaming Matrix-Vector Engine

Design spec, 2026-08-20. Milestone `v2.0`. **Revision 5.**

## Revision history

**Rev 5** incorporates a fourth adversarial review. **§7.4's arithmetic core was
verified sound for the first time** - widths, all four rounding sites against
`fixed_pkg.scale_mul` and `bfp_pack` source, both `y_exp` derivations and the
scan domain all recomputed independently and confirmed. The defects found were in
a different half of the contract: the **packer-to-RTL format agreement**, which
earlier rounds never probed because lane-splitting only existed from rev 4.

| Ref | Defect in rev 4 | Resolution |
|---|---|---|
| C-A | §7.7 gives each port its own sub-region, but §6.4 says the unit never reads the header and §5 carried a single `w_base`. **Nothing told port *p* where sub-region *p* starts.** | §5: `w_sub_base` vector, one 32-bit base per sub-region, copied by the PS from the header. |
| C-B | Nibble order, byte order within a row-chunk, lane-to-word mapping, `x_rdata` element order and scale endianness were all unpinned. Two implementations could each conform to §7.4 and **disagree on every output bit**. | New **§6.5 Bit ordering (normative)**, plus the `NPORTS_W * AXI_DW = ROWS_IF * BLOCK * 4` invariant. |
| M-A | The §7.4 divergence table's third row was arithmetically wrong and vacuous: `(2^30-1) >> 15 = 32767`, not 32768, so both variants agreed and it demonstrated nothing. | Row corrected; it now shows that the **biased** path reaches 32768 and wraps to **-32768** without `sat16`. |
| M-B | Tail padding beats stay resident in the FIFOs at job end, misaligning the next job by a per-port-varying count. | Flush on `start`, stated in §7.7 along with the pop gate and scale unpack. |
| M-C | `out_shift` had no upper bound. `acc + 2^(out_shift-1)` wraps a 49-bit adder at `out_shift >= 48` while int64 C does not; `1 << (out_shift-1)` is C UB at `>= 64`. | `0 <= out_shift <= 40` normative, checked at `start`; all `round_shift` intermediates >= 64 bits. |
| M-D | `msb_pos(0)` undefined, i.e. the all-zero output vector, which is reachable. `63 - __builtin_clzll(0)` is C UB. | `msb_pos(0) = 0` stated, matching `bfp_pack.msb_pos_u`. |
| M-E | §9 and §7.4's own lead-in still said "three rounding modes" after rev 4 made it four; `sat16` was never mentioned as a C deliverable. | Both corrected. |
| M-F | `err` is cleared by a successful `start`, so an illegal-codebook violation raised during an idle load was wiped by the very job it invalidated. | Codebook legality **re-checked at every `start`** and treated as an abort, not a warning. |
| M-G | No range checks on `n_cols` (would wrap `x_rbaddr`), `n_cols <= 0`, `n_rows <= 0`. | Added to the §7.6 abort table. |

**Rev 4** incorporates a third adversarial review. §7.4 had now failed three
consecutive reviews, each time on a different missing piece of the same contract.

| Ref | Defect in rev 3 | Resolution |
|---|---|---|
| C-1 | The BFP mantissa shift is a **fourth** rounding site, written as a bare `y_data >> ns` (floor, no bias, no saturation). `bfp_pack.vhd` applies `+2^(ns-1)` when `ns > 0`, arithmetic-shifts, **then saturates to int16**. An RTL author following §7.4 literally would fail test 7, which requires matching `bfp_pack`. | §7.4: fourth rounding row added, with the three divergence cases tabulated. |
| M-1 | "msb_pos over all M values" left the scan domain unstated. Padded tile rows and stale buffer contents at indices >= `n_rows` would inflate `ns` and crush every real mantissa - the exact silicon failure `bfp_pack`'s header documents. | §7.4: scan covers `r < n_rows` only; `amax` held unsigned. |
| M-2 | "floor (arithmetic right shift, truncate)" is self-contradictory; floor and truncation differ on every negative inexact quotient, and C's `/` truncates. | §7.4: arithmetic right shift on int64, never C `/`. |
| M-3 | Rev 3's width-converting FIFOs need 512-bit read ports; RAMB36E2 tops out at 72 bits, so each costs ~8 BRAM36 for width alone - 32 across four ports, versus the 8 budgeted. | **Design changed**: §7.7 lane-split reassembly moves the interleave into the packer, eliminating width conversion, the merge mux, and the drain schedule. Back to ~22 BRAM36 total. |
| minor | §13 blamed DSP headroom for the FK33 gap; the real constraint is HBM ports (33 needed against 32 at `ROWS_IF=86`). | §13 corrected. |
| minor | `err` semantics were fragmented across §5, §7.4, §7.5 and §7.6. | Consolidated in §7.6. |

**Rev 3** incorporates a second adversarial review of rev 2, which found that
§7.4 -- the section whose entire purpose is to be the closed normative contract
-- still contained a sign error and an unresolved range contradiction, and that
§7.7 hid a 4x bandwidth trap.

| Ref | Defect in rev 2 | Resolution |
|---|---|---|
| CR-1 | BFP `y_exp = ... **+** ns` is a sign error. Under `real = mant * 2^-exp`, right-shifting the mantissa by `ns` requires `exp' = exp - ns`. `bfp_pack` (`o_exp = Q - shift_o`) and `matmul_rt` (`o_exp <= xexp_l - sh`) both establish minus. Packer and RTL could legally disagree on the output exponent. | §7.4: `- ns`, with `ns` defined as a non-negative right-shift magnitude and the derivation shown. |
| CR-2 | `scale` declared `uint16` while the accumulator argument asserted `scale < 2^15`. Contradictory: a packer emitting 40000 was legal and would overflow the annotated width. `contrib` annotated s28 but bounded at 2^28, which does not fit s28. | §7.4: `scale` normatively **uint15 (0..32767)**, `contrib` widened to **s29**, packer-enforced. |
| MA-1 | `int8` codebook admits **-128**. With `cb=-128, x=-32768` the block partial is exactly 2^27, overflowing s28 by one. Test 11 specified `+/-32767`, missing the true -32768 corner. | §7.4: `codebook[i]` constrained to `[-127, +127]`. Test 11 corrected to -32768. |
| MA-2 | Round-robin granule popping delivers **128 bits/cycle, not 512**, because the current granule sits in one FIFO. 4x array starvation. FIFO budget was one granule undoubled. | §7.7 rewritten: per-port 128->512 width conversion, drain one FIFO for 64 consecutive cycles, 8 KB double-buffered depth, region padded to `NPORTS_W x 4 KB`. |
| MA-3 | Three rounding modes coexisted; "ties away from zero" conflicts with `fixed_pkg.scale_mul` and `bfp_pack` ("half toward +infinity"). `>>15` floor left implicit. `out_shift` unconstrained, so `<= 0` undefined. | §7.4: all three pinned, `out_shift >= 0` normative. |
| MA-4 | §7.6 required an error flag absent from the §5 port list. | `err` port added. |
| MA-5 | §13 claimed the FK33 config "preserves the memory-bound regime", but 432 < 460 makes it **array-bound** at nominal HBM. `NPORTS_S` left at 1 despite 48 GB/s of scale demand. | §13 reworded honestly; scale port budget stated. |

**Rev 2** incorporated a first adversarial review that found five critical
defects in rev 1:

| Ref | Defect in rev 1 | Resolution |
|---|---|---|
| C1 | 48-bit accumulator analysed only the pre-scale partial; post-scale accumulation reaches ~2^49 and would wrap. The C reference specified the same wrong width, so both models would be bit-exact to each other **and wrong**. No output requant step existed at all. | Q15 scale with an immediate `>> 15`, bounding the accumulator at ~2^34. Full numeric contract in §7.4, explicit requant in §7.6. |
| C2 | The DSP `PCIN`/`PCOUT` cascade was described as "the standard systolic FIR structure". It is not applicable: in a systolic FIR the coefficients are static, but here weights **and** activations change every cycle, so DSP *j* would add a block-*b* product onto a partial containing block-(*b-j*) products, producing a diagonal smear rather than a block sum. | **Cascade abandoned.** Replaced by a pipelined LUT adder tree (§7.3). Rationale in §7.3. |
| C3 | `n_cols` port comment said "multiple of BLOCK" while §6 and test 9 required masking of partial blocks. | `n_cols` carries true K; the *layout* rounds up. §5, §6.3. |
| C4 | FK33 geometry gave 512 MACs against the ~2,730 required, and `P=128` violated the spec's own `COLS_PC = BLOCK` constraint. | §13 corrected; scaling is via `ROWS_IF` only. |
| C5 | The int16 scale had no stated Q-format and there was no `w_exp`, so `y_exp` was underivable and packer/reference/RTL could not agree. | Full value semantics in §7.4. `w_exp` and `out_shift` added to the descriptor. |
| M1 | "16-entry 1-bit ROM = exactly one LUT6" contradicted the runtime-loadable codebook; a ROM is fixed at configuration. | Distributed LUTRAM, SLICEM constraint and write-fanout mitigation stated (§7.5). |
| M2 | 28-bit partial x 16-bit scale does not fit the DSP48E2 27x18 multiplier. | Two DSP48E2 per row for the scale multiply; budget updated (§7.4). |
| M3 | Multi-port stream reassembly was unspecified. | §7.7: 4 weight ports round-robin by 4 KB granule, 1 dedicated scale port. |
| M5 | `M` not divisible by `ROWS_IF` produced garbage rows with no suppression specified. | Row masking (§7.6); `n_rows` bound for BFP mode. |
| M4 | The DDR bandwidth premise (8-12 GB/s) was asserted without citing the board's DDR width, and ignored HP-port sharing and PS contention. | §4 "DDR bandwidth premise, with its caveats", with the board citation and three named invalidation mechanisms. |
| M6 | The activation port claimed to follow `vec_mem` convention, but `vec_mem` is 32-bit single-port and cannot serve 512 bits/cycle. | New `act_mem_striped` entity specified (§7.8); `x_raddr` is a **block** address. |

Other minor corrections are folded in silently.

## 1. Context

`v1.1-server` closes the llama2 line: stories260K runs bit-exact on the AXU3EG PL
and serves an OpenAI endpoint. Work after that tag targets the **Qwen3.5 hybrid
architecture** with INT4 weights streamed from DDR (AXU3EG) and later HBM (FK33).

The ladder, all on one codebase (see `docs/fpga-hardware-recon.md`):

| Milestone | Hardware | Model | Size @ 4.5 bpw | Bandwidth | Ceiling | Derated est. |
|---|---|---|---|---|---|---|
| `v3.0` | AXU3EG (owned) | Qwen3.5-0.8B | ~450 MB | 8-12 GB/s DDR4 | 27 tok/s | 19-28 |
| `v4.0` | 1x FK33 | Qwen3.5-9B | ~5.1 GB | 460 GB/s HBM | 91 tok/s | 65-92 |
| `v5.0` | 2x FK33 | Qwen3.8-27B | ~15.1 GB | 2x 460 GB/s | 61 tok/s | 45-63 |

Ceiling is pure bandwidth; derated applies ~70% achieved efficiency. Both are
quoted because `docs/fpga-hardware-recon.md` uses the derated figures.

Three new subsystems stand between `v1.1` and `v3.0`:

- **A: INT4 streaming matvec** (this spec, `v2.0`) - everything depends on it
- **B: Gated DeltaNet** (`v2.2`) - 18 of 24 layers, largest architectural risk
- **C: Gated attention** (`v2.1`) - GQA 8:2, head_dim 256, QK-norm, fused output gate

## 2. Goal and scope

Compute `y = W . x`, where `W` is an INT4-quantized matrix streamed from external
memory and `x` is an activation vector resident on chip.

**In scope:** MAC array, codebook and block-scale dequantization, external-memory
burst streaming, accumulation, output requantization, the striped activation
memory, the offline weight packer, and a bit-exact C reference.

**Out of scope:** the transformer FSM, Gated DeltaNet, attention, normalization
units, and the weight *loader* (the PS writes the packed blob into DDR at boot;
this unit only reads it).

**Dimension-agnostic within stated bounds.** `M` and `K` are runtime inputs. The
unit therefore needs no knowledge of the GDN projection shapes subsystem B will
define, subject to `K <= MAXCOLS` and, in BFP mode, `M <= MAXROWS_BFP`.

## 3. Target model dimensions

Qwen3.5-0.8B (`config.json`, verified):

| Parameter | Value |
|---|---|
| hidden_size | 1024 |
| num_hidden_layers | 24 (18 linear GDN + 6 full attention) |
| intermediate_size | 3584 |
| vocab_size | 248,320 |
| num_attention_heads / kv_heads / head_dim | 8 / 2 / 256 |
| tie_word_embeddings | **true** |
| linear attention | 16 K heads, 16 V heads, dim 128, conv kernel 4 |
| rope_theta / partial_rotary_factor | 1e7 / 0.25 |

**The embedding table is a third of the model.** 248,320 x 1024 = 254M params,
tied, so the same tensor is the lm_head. That single matvec is ~32% of per-token
weight traffic (254M MACs against 264M for all 24 layers of FFN combined). The
existing streaming-argmax `lm_head` approach is load-bearing, not an optimization.

**`M` spans 512 to 248,320**, so it must never appear as a bus width.

| Matvec | K -> M | Instances |
|---|---|---|
| FFN gate / up | 1024 -> 3584 | 2 per layer x 24 |
| FFN down | 3584 -> 1024 | 24 |
| Attention q (+ fused gate) | 1024 -> 4096 | 6 layers |
| Attention k / v | 1024 -> 512 | 6 layers each |
| Attention o | 2048 -> 1024 | 6 layers |
| GDN projections | 1024 -> defined by subsystem B | 18 layers |
| **lm_head (tied)** | **1024 -> 248,320** | 1 per token, raw-stream mode |

`MAXCOLS = 3584`. `MAXROWS_BFP = 4096`.

**Model size is an estimate, not a computation.** Summing known tensors (embed
254M + FFN 264M + attention ~44M, the latter including the fused q-gate at
1024->4096) leaves ~170-240M for GDN projections whose
shapes subsystem B has not yet fixed. 450 MB assumes ~800M total params at
4.5 bpw. If the true count is ~730M the model is ~410 MB and throughput improves
~10%. Nothing in this design depends on the exact figure.

## 4. Sizing

At 4.5 bits per weight (4-bit index plus one 16-bit scale per 32 weights):

| | AXU3EG | FK33 |
|---|---|---|
| Bandwidth | 8-12 GB/s DDR4 | 460 GB/s HBM |
| Bytes per weight | 0.5625 | 0.5625 |
| Weights/s | 21.3 G/s | 818 G/s |
| Target clock | 200 MHz | 300 MHz |
| **MACs to saturate** | **~107, use 128** | **~2,730, use 2,560** |
| DSPs available | 360 | 2,976 |

**`ROWS_IF` is the single scaling generic**; `COLS_PC` is pinned to `BLOCK` (§7.2).

At `ROWS_IF=4` and 200 MHz the array demands 14.4 GB/s against ~12 GB/s
available, so **memory is the limiter by design**. That is the correct regime and
it holds on both platforms.

### DDR bandwidth premise, with its caveats

The AXU3EG core board carries five Micron MT40A512M16GE devices, **four on the PS
side forming a 64-bit bus, 4 GB total** (plus 1 GB 16-bit on the PL side). 64-bit
DDR4-2133 peaks at 17.06 GB/s, so 8-12 GB/s is a 47-70% efficiency assumption.

Three things could invalidate it, all measured at bring-up step 4 before the
datapath can mask them:

1. On Zynq UltraScale+ the HP ports do **not** map to independent DDR controller
   ports; HP1 and HP2 share one. Four masters do not guarantee four times the
   throughput.
2. The PS ARM cores run the server and contend for the same controller.
3. Refresh and page-miss overhead is workload dependent; the sequential packed
   layout of §6 is the primary defense.

If achieved bandwidth is ~6 GB/s rather than ~12, `ROWS_IF` drops to 2 and
throughput roughly halves. The design absorbs this by changing one generic.

## 5. Interface

Wide parallel buses are prohibited. At Qwen dimensions an `N*16` bus is 57,344
bits, the same wall that made the parallel `logits` port cost 39.5K LUT before it
was replaced with streaming.

```vhdl
entity matvec_int4 is
  generic(
    ROWS_IF     : positive := 4;      -- output rows in flight (the scaling knob)
    BLOCK       : positive := 32;     -- weights per scale block
    MAXCOLS     : positive := 3584;
    MAXROWS_BFP : positive := 4096;   -- BFP-mode row bound
    NPORTS_W    : positive := 4;      -- AXI read channels, weights
    NPORTS_S    : positive := 1;      -- AXI read channels, scales
    AXI_DW      : positive := 128
  );
  -- COLS_PC (columns per cycle) is PINNED to BLOCK, not a generic: see 7.2.
  -- MAC count is DERIVED: MACS = ROWS_IF * BLOCK.
  port(
    clk, rst : in  std_logic;
    -- job descriptor
    start     : in  std_logic;
    -- One base per weight sub-region (7.7 lane-split), 4KB aligned, copied by
    -- the PS from the header. Flattened: sub-region p occupies bits
    -- (p+1)*32-1 downto p*32. There is deliberately NO single w_base: the unit
    -- never reads the header, so sub-region placement must be told to it.
    w_sub_base : in std_logic_vector(NPORTS_W*32-1 downto 0);
    s_base    : in  std_logic_vector(31 downto 0);  -- scale region, 4KB aligned
    n_rows    : in  integer;                        -- M, true value
    n_cols    : in  integer;                        -- K, TRUE value (see 6.3)
    w_exp     : in  integer;                        -- per-matrix weight exponent
    out_shift : in  integer;                        -- output requant shift (7.6)
    out_mode  : in  std_logic;                      -- '0' = BFP, '1' = raw int32
    -- activation read port: BLOCK address, not element address (see 7.8)
    x_rbaddr  : out std_logic_vector(clog2(MAXCOLS/BLOCK)-1 downto 0);
    x_rdata   : in  std_logic_vector(BLOCK*16-1 downto 0);
    x_exp     : in  integer;
    -- codebook load, 16 x int8. Illegal while a job is in flight (7.5).
    cb_we     : in  std_logic;
    cb_addr   : in  std_logic_vector(3 downto 0);
    cb_data   : in  std_logic_vector(7 downto 0);
    -- result write port, one element per cycle
    y_we      : out std_logic;
    y_addr    : out std_logic_vector(clog2(MAXROWS_BFP)-1 downto 0);
    y_data    : out std_logic_vector(31 downto 0);
    y_exp     : out integer;
    done      : out std_logic;                      -- one-cycle pulse
    err       : out std_logic;                      -- job aborted, see 7.6
    -- AXI4 master read, NPORTS_W + NPORTS_S channels, standard AR/R signal set
    -- per channel. Enumerated in the implementation plan, not here.
    ...
  );
end entity;
```

`x_exp`, `y_exp`, `w_exp`, `out_shift`, `n_rows` and `n_cols` are `integer`
because they are descriptor and exponent values, not datapath signals. See §8.

### Two output modes

The BFP convention needs a shared exponent, known only after every output row is
computed. That requires buffering int32 results, impossible at `M = 248,320`
(993 KB).

| Mode | Buffering | `y_addr` | Used by |
|---|---|---|---|
| BFP (`'0'`) | int32 into the output buffer, then normalize to int16 + shared exp | valid row index | all layer matvecs, `M <= MAXROWS_BFP` |
| Raw (`'1'`) | none, emit int32 per row as computed | **undefined, must be ignored** | lm_head |

In raw mode `M` may exceed `MAXROWS_BFP`, so `y_addr` cannot represent the row
index and is not driven meaningfully. `sampler_stream` consumes `y_data` on
`y_we` alone, exactly as it consumes `logit_v`/`logit_valid` today.

## 6. Weight format and file layout

### 6.1 Quantization

- 4-bit index per weight into a **16-entry int8 codebook**
- One **int16 scale, unsigned Q15** per `BLOCK` consecutive weights within a row
- One `w_exp` per matrix, carried in the descriptor
- 4.5 bits per weight

The codebook is runtime-loadable, so quantization schemes can be swapped without
resynthesis. Default is the IQ4_NL table:

```
-127, -104, -83, -65, -49, -35, -22, -10, 1, 13, 25, 38, 53, 69, 89, 113
```

Measured perplexity on Qwen3.8-27B places non-uniform 4-bit ("IQ4_XS pure") at
98.5% of Q8_0, against ~97.5-98.5% expected for uniform INT4. Loading a linear
table yields uniform INT4 in the same hardware, so this is a runtime experiment.

NVFP4 is deliberately **not** implemented: measurement places it 3-5% behind
integer 4-bit at equal size, despite being the obvious hardware-friendly choice.

### 6.2 Padding hazard: the IQ4_NL codebook contains no zero

Entries run `-127 ... -10, 1, 13 ... 113`. **No index decodes to 0** (index 0 is
-127, index 8 is 1). Zero-padding a short row therefore contributes a nonzero
product and silently corrupts the result.

**Masking is chosen** over reserving a codebook entry: the array forces products
to zero for `col >= n_cols`. This mirrors how `matmul_rt` masks activations past
`IN_COLS`, keeps the codebook free for experiments, and does not depend on the
packer getting padding right.

### 6.3 K, blocks and masking

`n_cols` carries the **true** K. The packed layout rounds each row up to a whole
number of blocks: `NB = ceil(n_cols / BLOCK)`. Address generation uses `NB`. The
datapath masks products for `col >= n_cols`, which affects only the final block
of each row. Test 9 exercises this.

### 6.4 File layout (offline-permuted)

Weights are packed in exactly the order the array consumes them, so address
generation is a counter and every read is a long sequential burst.

```
header        : magic, M, K, w_exp, out_shift, ROWS_IF, NPORTS_W,
                w_sub_offset[0 .. NPORTS_W-1], scale_offset
weight region : for tile t in ceil(M/ROWS_IF):
                  for block b in 0..NB-1:
                    for r in 0..ROWS_IF-1:
                      w[t*ROWS_IF+r][b*BLOCK .. b*BLOCK+BLOCK-1]   (BLOCK*4 bits)
scale region  : for tile t: for block b: for r in 0..ROWS_IF-1: scale (16 bits)
```

**The PS parses the header and is authoritative**; it programs `n_rows`,
`n_cols`, `w_exp` and `out_shift` into the descriptor. The unit itself never
reads the header. A mismatch between header and descriptor is a PS-side bug, not
a hardware condition.

`weight_offset` and `scale_offset` must be **4 KB aligned**, because bursts are
256 beats x 16 bytes = exactly one AXI 4 KB boundary-to-boundary transfer and
AXI4 forbids bursts crossing a 4 KB boundary.

The layout is tied to `ROWS_IF`. Changing it means re-running the packer, a
Python script over a static model. That is the trade accepted in choosing the
permuted layout, and it buys purely sequential access, which is where the
bandwidth lives. Note this means **the model is re-packed per platform**, since
`ROWS_IF` differs between AXU3EG and FK33.

### 6.5 Bit ordering (normative)

The arithmetic contract of §7.4 is only half the agreement. Without a pinned
**format**, a packer, a C reference and an RTL implementation can each conform to
§7.4 and still disagree on every output bit. All of the following follow the
existing codebase convention (element `j` at bits `(j+1)*16-1 downto j*16`, as in
`matmul_rt`, `swiglu` and `bfp_pack`) and are normative here:

| Item | Rule |
|---|---|
| Weight nibble within a byte | weight index `k` even -> bits 3:0 (low nibble); `k` odd -> bits 7:4 |
| Weight within a row-chunk | weight `k` of a block occupies bits `4k+3 downto 4k` of the 128-bit chunk, so weight 0 is at bits 3:0 |
| Row-chunk within a 512-bit word | at `ROWS_IF = 4`, one word is exactly four row-chunks; **row `r` of the tile occupies lane `r`**, i.e. bits `(r+1)*128-1 downto r*128` |
| Lane to sub-region | **lane `p` lives in sub-region `p`**, so `W_t = { fifo[3], fifo[2], fifo[1], fifo[0] }` places sub-region 0 at bits 127:0 and row 0 of the tile is fed by port 0 |
| `x_rdata` element order | element `j` of the block at bits `(j+1)*16-1 downto j*16`; element 0 at bits 15:0 |
| Scale endianness | int16 little-endian; the scale for row `r` of a tile-block group sits at byte offset `2r` within that group |

**The `ROWS_IF = 4` coincidence is load-bearing and must not be assumed
elsewhere.** At `ROWS_IF = 4` one lane happens to equal one row's chunk, which is
why the mapping above is so simple. The general invariant is:

```
NPORTS_W * AXI_DW = ROWS_IF * BLOCK * 4
```

At `ROWS_IF = 4, BLOCK = 32, AXI_DW = 128` this gives `NPORTS_W = 4`. **The §4
bandwidth fallback to `ROWS_IF = 2` therefore also requires `NPORTS_W = 2`** (a
256-bit word), not `NPORTS_W = 4`; the packer and the wrapper must both follow.
The FK33 configuration (`ROWS_IF = 80`) gives a 10,240-bit word across
`NPORTS_W = 80` lanes, so the lane-to-row identity survives but the port count
does not - see §13.

## 7. Datapath architecture

### 7.1 Two modules, so the core is testable without AXI

```
matvec_int4 (wrapper)
├── weight_streamer   -- (NPORTS_W + NPORTS_S) x AXI4 master -> in-order streams
└── matvec_core       -- MAC array, dequant, tree, scale, accumulate, requant
```

`matvec_core` consumes **valid/ready streams**, not AXI, so GHDL can exercise it
from file-fed streams with no AXI model.

### 7.2 Array geometry

`COLS_PC` is **pinned to `BLOCK`**, so one cycle consumes exactly one scale block
of one row. Decoupling them would require multiple scale multiplies per row per
cycle and would let the array width silently change the quantization format.
Scaling is therefore via `ROWS_IF` alone.

| Per cycle at `ROWS_IF=4` | |
|---|---|
| Weights consumed | 4 x 32 = 128 |
| Weight bits | 512 |
| Scale bits | 4 x 16 = 64 |
| Activations read | 32, shared across all 4 rows |
| Memory demand @ 200 MHz | 14.4 GB/s |

Activation read width does **not** grow with `ROWS_IF`, which is why the design
scales to `ROWS_IF=80` on the FK33 without an activation-bandwidth problem.

### 7.3 Reduction: pipelined adder tree, NOT a DSP cascade

Rev 1 specified a DSP48E2 `PCIN`/`PCOUT` cascade, described as the standard
systolic FIR structure. **That is wrong for this dataflow.** In a systolic FIR
the coefficients are static and data slides past the taps. Here both weights and
activations change every cycle, so DSP *j* would add a block-*b* product onto a
partial containing block-(*b-j*) products: the result is a diagonal smear across
blocks, not a block sum.

Making the cascade correct requires per-tap input skew registers (tap *j* delayed
*j* cycles) on weights and activations, plus matching skew on the scale stream,
costing roughly 1.5K LUTs of SRL and introducing an off-by-one hazard that is
invisible in a naive testbench.

A **pipelined LUT adder tree** costs about the same and has no skew hazard:

```
32 x DSP48E2 multiply  ->  5-level pipelined adder tree  ->  block partial
16 adds @24b, 8 @25b, 4 @26b, 2 @27b, 1 @28b = 31 adders, ~775 LUT per row
```

Given the project's silicon history, "comparable cost, no subtle failure mode" is
the correct trade. **Per-cycle 32-way reduction is unavoidable** in any case,
because block-granular scaling requires the block sum before the scale can be
applied.

Products are int8 x int16 = 24 bits signed. Block partial max is
`32 x 127 x 32768 = 133,169,152 < 2^27`, so **28 bits signed** (s28). The
`32768` is deliberate: `x_mant` reaches -32768, not merely +32767. This bound
holds only because §7.4 forbids `codebook[i] = -128`.

### 7.4 Numeric contract

This section is normative. The packer, the C reference and the RTL must all
implement exactly this.

```
codebook[i]  : int8 CONSTRAINED to [-127, +127]   -- -128 is FORBIDDEN, see below
scale        : uint15, value 0..32767, interpreted Q15 (real = scale / 2^15)
             -- stored in a 16-bit field whose MSB must be 0
x_mant[k]    : int16, full range [-32768, +32767]
w_exp        : int, per matrix
x_exp        : int, per activation vector
out_shift    : int, per matrix, CONSTRAINED >= 0

real weight  w[r][k] = codebook[idx[r][k]] * (scale[r][b] / 2^15) * 2^-w_exp
real act     x[k]    = x_mant[k] * 2^-x_exp

partial[r][b] = sum over k in block b of (codebook[idx] * x_mant[k])   -- s28
                 with terms where k >= n_cols forced to 0
contrib[r][b] = floor( partial[r][b] * scale[r][b] / 2^15 )            -- s29
acc[r]        = sum over b of contrib[r][b]                            -- s48
```

**Two normative range constraints.** Both are enforced by the packer and checked
by the wrapper; violating either overflows a declared width.

1. **`codebook[i] != -128`.** With `cb = -128` and `x_mant = -32768` (both
   reachable: int8 includes -128, and `bfp_pack` saturates to -32768), a single
   product is `2^22` and a 32-term block partial is exactly `2^27`, which
   overflows s28 by one. IQ4_NL's minimum is -127, so the constraint costs
   nothing.
2. **`scale <= 32767`**, i.e. real scale in `[0, 1)`. Rev 2 declared `uint16`
   while simultaneously asserting `scale < 2^15`; those contradict, and a packer
   emitting `scale = 40000` would have been legal per the declared type and would
   have broken the RTL width.

**Worst-case partial.** `32 * 127 * 32768 = 133,169,152 < 2^27`, so s28 holds.
(Rev 2 wrote this product as `32 x 127 x 32767`, which equals 133,165,088; the
larger value is the true worst case because `x_mant` reaches -32768.)

**Accumulator bound.** With `scale <= 32767`,
`|contrib| <= 133,165,088 < 2^27` (the extreme quotient is exact:
`32 * 127 * 32768 = 4064 * 2^15`, so `4064 * 32767` has no fractional part and
floor adds nothing on either sign), so it would in fact fit s28; **s29 is declared for margin, not necessity**. Over `NB = 112` blocks at `K = 3584`, `acc` reaches at most
`2^27 x 112 ~= 2^33.8`. A 48-bit accumulator therefore has ~14 bits of headroom
and remains sufficient at the FK33's larger `K`. **Rev 1's error was analysing
the pre-scale partial and omitting the `/2^15`, which put the bound at ~2^49 and
would have wrapped.**

**Rounding, pinned to the existing codebase.** **Four** distinct operations
round. Each is specified separately; rev 2 left two implicit and rev 3 missed the
fourth entirely:

| # | Operation | Mode |
|---|---|---|
| 1 | `contrib` division by `2^15` | **floor**: arithmetic right shift by 15. **Never C `/`** - see below. |
| 2 | `round_shift(acc, out_shift)`, `out_shift > 0` | **round half toward +infinity**: `(acc + 2^(out_shift-1)) >> out_shift`, arithmetic |
| 3 | `round_shift(acc, 0)` | no shift, no bias term |
| 4 | `round_shift(y_data, ns)` then `sat16`, BFP mode | same as 2 and 3 with `ns` in place of `out_shift`, then saturate to [-32768, 32767] |

Rev 3 described site 1 as "floor (arithmetic right shift, truncate)", which is
**self-contradictory**: floor rounds toward -infinity, truncation toward zero,
and they differ on every negative inexact quotient (`floor(-5/2) = -3`,
`trunc(-5/2) = -2`). Since C's `/` truncates, a C author writing the natural
`(int64_t)partial * scale / 32768` would diverge from the RTL's `shift_right`.
**Site 1 is an arithmetic right shift on a signed 64-bit value, never a C
division.**

Round-half-toward-+infinity is `fixed_pkg.scale_mul`'s convention and
`bfp_pack`'s, and `matmul_rt` inherits it. Rev 2 said "ties away from zero",
which differs on negative ties (`-3 >> 1` gives `-1` here, not `-2`) and would
have diverged from any implementation reusing `scale_mul`. **`out_shift < 0` is
illegal**; rev 2 left it unconstrained while telling the packer to choose it
freely.

**Scale multiply width.** `partial` is s28 and `scale` is 15-bit unsigned. The
DSP48E2 A port is 27 bits, so a 28-bit operand does not fit. **Two DSP48E2 per
row** are allocated rather than pre-shifting the partial, so no precision is
lost. Total DSP budget:

```
ROWS_IF x (BLOCK multiplies + 2 scale) = 4 x (32 + 2) = 136 DSP of 360
```

**Output value semantics.** Derivation, using the codebase convention
`real = mant * 2^-exp` throughout:

```
real y[r] = acc[r] * 2^-(w_exp + x_exp)

raw mode:
  y_data[r] = sat32( round_shift(acc[r], out_shift) )
  y_exp     = w_exp + x_exp - out_shift

BFP mode. The scan covers ONLY rows r < n_rows (see below):
  amax      = max over r < n_rows of |y_data[r]|, held UNSIGNED (so -2^31 is
              representable and does not alias)
  msb_pos   = index of the most significant set bit of amax,
              with msb_pos(0) DEFINED AS 0            -- see note below
  ns        = max(0, msb_pos - 14)                    -- right-shift magnitude,
                                                      -- implicitly <= 17

  y_mant[r] = sat16( round_shift(y_data[r], ns) )     -- see rounding table
  y_exp     = w_exp + x_exp - out_shift - ns
```

**The BFP mantissa shift is a FOURTH rounding site and must not be a bare
shift.** Rev 3 wrote `y_mant = y_data >> ns`, i.e. floor with no bias and no
saturation. `bfp_pack.vhd` does neither: it applies `+2^(ns-1)` when `ns > 0`
(no bias when `ns = 0`), arithmetic-shifts, **then saturates to
[-32768, 32767]**. Divergences the rev-3 wording would have produced, all of
which fail test 7:

| `y_data` | `ns` | bare shift (rev 3) | `bfp_pack` | why |
|---|---|---|---|---|
| 32769 | 1 | 16384 | **16385** | missing bias |
| -32769 | 1 | -16385 | **-16384** | bias, negative tie |
| 2^30 - 1 | 15 | 32767 | **32767** | biased path gives 32768, which **wraps to -32768** in int16 without `sat16` |

Note the third row carefully: the *bare* shift cannot overflow, because
`ns = msb_pos - 14` bounds a floor shift to int16 by construction. It is the
**biased** path that reaches 32768 and therefore needs `sat16`. An implementation
that adds the bias but omits saturation produces **-32768** by int16 wraparound:
a full-scale positive value read as full-scale negative.

**The scan domain is normative.** §7.6 pads the final tile to `ROWS_IF` rows and
suppresses `y_we` for `r >= n_rows`, but in BFP mode results land in a buffer,
not through `y_we`. If padded-row garbage or stale contents from a prior job at
indices `>= n_rows` enter the max scan, `ns` inflates and **every real mantissa
is crushed** - which is the exact failure signature `bfp_pack`'s own header
documents from silicon. The scan therefore covers `r < n_rows` only.

**The `ns` term is subtracted, not added.** If `mant' = mant >> ns` then
preserving the value requires `exp' = exp - ns`. Rev 2 wrote `+ ns`, which is a
sign error: `bfp_pack` (`o_exp = Q - shift_o`) and `matmul_rt`
(`o_exp <= xexp_l - sh`) both establish the minus convention, and test 7 requires
matching `bfp_pack` exactly. `ns` is defined here as a **right-shift magnitude**,
always non-negative, matching `bfp_pack`'s `shift_o = max(0, msb_pos - 14)`.

`sat32` saturates rather than wraps. In BFP mode the int16 mantissa is
**sign-extended** into the 32-bit `y_data` port.

`out_shift` is chosen offline by the packer per matrix from the observed dynamic
range of a calibration set, carried in the header, and is normatively bounded
**`0 <= out_shift <= 40`**. The upper bound is not cosmetic: `acc` is s48, so an
RTL author computing `acc + 2^(out_shift-1)` in a 49-bit adder wraps once
`out_shift >= 48`, while an int64 C reference does not - a silent,
packer-triggerable divergence of exactly the class §7.4 exists to prevent. In C,
`1 << (out_shift-1)` is undefined behaviour at `out_shift >= 64`. **All
`round_shift` intermediates are computed in at least 64 bits** (s49 minimum;
int64_t in C).

**`msb_pos(0) = 0`, hence `ns = 0`, for an all-zero output vector.** This is
reachable (a zero `scale` row, zero activations, or a large `out_shift`) and
`bfp_pack.msb_pos_u` already returns 0 for 0. The natural C idiom
`63 - __builtin_clzll(amax)` is **undefined behaviour at zero**, so the
definition is stated rather than left to inference.

### 7.5 Dequantization

Rev 1 claimed a 16-entry lookup is "exactly one LUT6". That conflicts with the
codebook being runtime-loadable: a LUT6 ROM's contents are fixed at
configuration. The codebook must be **distributed LUTRAM** (RAM32X1D class,
**SLICEM only**), roughly 1 LUT per bit, so ~8 LUT per MAC and ~1,024 LUT for the
array at `ROWS_IF=4`. Two 16x1 functions fit one LUT6, so ~512 is achievable;
1,024 is the conservative budget.

Consequences to carry into implementation:

- Placement is constrained to SLICEM columns.
- The write network fans out to `MACS x 8 = 1,024` cells. Codebook loads happen
  once per model load, so the write path is **deeply registered and timed
  loosely**; it is not on the compute critical path.
- `cb_we` while a job is in flight is **illegal**. `done` is a one-cycle pulse
  in this codebase (see `matmul_rt`), so the interlock is against the wrapper's
  **idle state**, not a level on `done`. Writes arriving outside idle are
  ignored and raise `err`.

### 7.6 Requantization, row masking and output

Per row, once all `NB` blocks are accumulated:

1. `round_shift(acc, out_shift)`, saturate to int32.
2. **Row masking:** the layout pads the final tile to `ROWS_IF` rows. Rows with
   index `>= n_rows` are computed but `y_we` is suppressed. Without this, a
   matrix whose `M` is not a multiple of `ROWS_IF` emits garbage rows. All
   currently known shapes are divisible by 4 (248,320 = 4 x 62,080 included), but
   subsystem B's shapes are not yet fixed, so the mask is mandatory.
3. BFP mode buffers into the output buffer (`MAXROWS_BFP` x 32 bits = 16 KB);
   raw mode emits directly.

### `err` semantics (consolidated)

`err` is a **sticky flag, cleared by `rst` or by a successful `start`**. Two
classes, with different consequences:

All descriptor checks happen **at `start`, before any output**, and abort the
job with no `y_we` emitted; `done` still pulses so the caller's FSM cannot hang.

| Condition | Class | Behaviour |
|---|---|---|
| `n_rows > MAXROWS_BFP` with `out_mode = '0'` | descriptor | abort at `start` |
| `n_cols > MAXCOLS` | descriptor | abort at `start`. `x_rbaddr` is only `clog2(MAXCOLS/BLOCK)` bits and would otherwise wrap onto wrong activations. |
| `n_cols <= 0` or `n_rows <= 0` | descriptor | abort at `start`. A zero-length job emits nothing rather than an undefined `acc`. |
| `out_shift < 0` or `out_shift > 40` | descriptor | abort at `start` (§7.4 bound) |
| **an illegal codebook is resident** (`codebook[i] = -128`) | **descriptor, re-checked at every `start`** | abort at `start` |
| `scale` with MSB set, encountered mid-stream | data | **raise `err`, continue.** Cannot be detected before the job; results are undefined and the PS must discard them. |
| `cb_we` asserted outside idle | control | write ignored, raise `err`, in-flight job unaffected |

**The codebook check must be re-evaluated at each `start`, not only at load
time.** `err` is cleared by a successful `start`, so a violation raised during an
idle codebook write would be wiped by the very job it invalidates, and a PS
polling `err` after `done` would read 0 on a corrupt result. Rev 4 had exactly
this hole.

Rev 3 scattered these across four sections with inconsistent consequences.

### 7.7 Weight streaming and port reassembly

| Stream | Ports | Bits/cycle needed | Provided @ 200 MHz |
|---|---|---|---|
| Weights | `NPORTS_W = 4` | 512 | 4 x 128 = 512 |
| Scales | `NPORTS_S = 1` | 64 | 128 |

Scales get a **dedicated port** rather than sharing. Sharing would leave
`3 x 128 + 64 = 448` bits/cycle for weights, below the 512 required, and
interleaving scales into the weight region would break 4 KB alignment.

### Reassembly: lane-split, not granule round-robin

Rev 2 striped the weight region across ports in 4 KB granules, round-robin, and
popped granules in the same order. **That delivers 128 bits/cycle, not 512**,
because at any instant the current granule lives in exactly one port's FIFO.
Rev 3 patched it with per-port 128->512 width conversion and a 64-cycle drain
schedule, which works but is expensive: a FIFO *read* at 512 bits/cycle needs a
512-bit read port, and RAMB36E2 tops out at 72 bits per port, so each such FIFO
costs ~8 BRAM36 for width alone -- 32 BRAM36 across four ports, plus a 512-bit
4:1 merge mux and a drain-gating state machine.

**Rev 4 removes all of that by moving the interleave into the packer.**

The logical weight stream is a sequence of 512-bit words. Each word is split into
`NPORTS_W` lanes of `AXI_DW = 128` bits. The packer emits `NPORTS_W`
**contiguous sub-regions**; sub-region *p* holds lane *p* of every word, in word
order:

```
sub-region 0 : lane0(W0), lane0(W1), lane0(W2), ...
sub-region 1 : lane1(W0), lane1(W1), lane1(W2), ...
sub-region 2 : lane2(W0), lane2(W1), lane2(W2), ...
sub-region 3 : lane3(W0), lane3(W1), lane3(W2), ...
```

Each port reads **its own sub-region as plain sequential 4 KB bursts**, so DDR
locality is unchanged. Each cycle the merge pops one 128-bit word from **all four
FIFOs concurrently** and concatenates them into the 512-bit word:

```
W_t = { fifo3[t], fifo2[t], fifo1[t], fifo0[t] }
```

Consequences, all favourable:

- **No width conversion.** FIFOs are 128 bits wide, ~2 BRAM36 each.
- **No merge mux.** The concatenation is wiring.
- **No drain schedule and no drain-start gate**, so the rev-3 underrun hazard
  (a drain beginning before a full granule has landed) cannot occur.
- **In-order by construction**, with no reordering logic.
- FIFO depth need only cover DDR read latency and jitter, not a whole granule.
  Budget 512 beats (8 KB) per port for margin.

**Sub-region alignment and padding.** Each sub-region base must be 4 KB aligned,
and the packer pads each to a whole number of 4 KB bursts so no port needs an
end-of-region special case. Padding is never consumed because `n_rows`/`n_cols`
bound the job. The header therefore carries `NPORTS_W` sub-region offsets rather
than a single `weight_offset`; **the packed file is tied to `NPORTS_W` as well as
to `ROWS_IF`**.

**FIFOs are flushed on `start`.** Sub-regions are padded to whole 4 KB bursts,
so the burst carrying the final needed beat also delivers padding beats, which
remain resident when the job ends. The residue count differs per port, so
without a flush the next job's word stream would be misaligned by a
per-port-varying amount - silently, and differently on every matrix. The same
applies to the scale FIFO.

**Pop gate.** The merge pops only when **all** `NPORTS_W` weight FIFOs are
non-empty, and AR issue is throttled against FIFO free space. Both are obvious;
so was the rev-2 reassembly, which is why they are written down.

**Scale path width.** One 128-bit scale beat carries two cycles' worth of scales
at `ROWS_IF = 4` (64 bits needed per cycle), so the scale FIFO output passes
through a 2:1 unpack.

Double buffering **hides latency, not bandwidth**.  Since demand (14.4 GB/s)
exceeds supply (~12 GB/s) by design, the core stalls on memory in steady state;
that is intended and is what makes the unit memory-bound.

### 7.8 Activation memory: a new entity

`vec_mem.vhd` is 32 bits wide and single-read-port. It **cannot** serve
512 bits/cycle, so rev 1's claim that the activation port follows its convention
was wrong. A new entity is required:

```vhdl
entity act_mem_striped is
  generic(ELEMS : positive := 3584; BLOCK : positive := 32; W : positive := 16);
  port(clk    : in  std_logic;
       -- producer side: one 16-bit element per cycle (rmsnorm, swiglu, ...)
       we     : in  std_logic;
       waddr  : in  std_logic_vector(clog2(ELEMS)-1 downto 0);
       wdata  : in  std_logic_vector(W-1 downto 0);
       -- consumer side: one whole BLOCK per cycle
       rbaddr : in  std_logic_vector(clog2(ELEMS/BLOCK)-1 downto 0);
       rdata  : out std_logic_vector(BLOCK*W-1 downto 0));
end entity;
```

Internally 8 x BRAM36 in SDP mode (64 data bits each, 4 x 16-bit elements per
word). The full mapping, which "element k in bank k mod 8" alone does not pin
down: **bank = (k mod 32) div 4, word = k div 32, lane = k mod 4**. A block of 32
consecutive elements therefore occupies one word in each of the 8 banks, read in
a single cycle. Read access is strictly sequential by block index, so a plain
counter suffices and no muxing is needed.

**Read latency is 1 cycle** (registered read), matching `vec_mem` and `kv_mem`,
so the consumer issues `rbaddr` one cycle ahead exactly as `matmul_rt` does.

The write side uses 2-byte write-enable lanes, supported natively by SDP BRAM36,
because producers (`rmsnorm`, `swiglu`) emit one 16-bit element per cycle.

`x_rbaddr` is a **block address** of width `clog2(MAXCOLS/BLOCK)` = 7 bits, not
an element address. Rev 1 declared it `clog2(MAXCOLS)` = 12 bits, which was
ambiguous between two valid readings.

### 7.9 Resource budget

| Resource | Estimate at `ROWS_IF=4` | Available |
|---|---|---|
| DSP48E2 | 136 (128 multiply + 8 scale) | 360 |
| LUT, adder trees | ~3,100 | 70,560 |
| LUT, codebook LUTRAM | ~1,024 | (SLICEM) |
| LUT, control/addressing | ~2,000 est. | |
| BRAM36, activations | 8 | 216 |
| BRAM36, weight FIFOs (4 x 8 KB, 128b wide) | 8 | |
| BRAM36, scale FIFO | ~2 | |
| BRAM36, BFP output buffer (4096 x 32b) | 4 | |
| **BRAM36 total** | **~22** | 216 |

The lane-split reassembly of §7.7 is what keeps this at ~22. Rev 3's
width-converting FIFOs would have cost ~32 BRAM36 for the weight path alone
(512-bit read ports against RAMB36E2's 72-bit maximum), plus a 512-bit 4:1 merge
mux, for a total nearer 46.

## 8. Design rules inherited from v1.0-silicon

The `v1.0-silicon` tag names three rules earned through silicon-only failures
invisible to GHDL and to netlist funcsim. They are **design constraints here**.

| Rule | Compliance |
|---|---|
| At most one multiply per state | The array multiply, each adder-tree level, the scale multiply and the accumulate each occupy their own pipeline stage. **The scale multiply is the exact hazard class that broke `residual`, `swiglu` and `bfp_pack`** and must never share a state with the tree output. |
| Never route data through a VHDL `integer` | Mantissas, products, partial sums and accumulators are always `signed`/`unsigned`. `integer` is permitted only for loop counters, generics, descriptor fields (`n_rows`, `n_cols`, `out_shift`) and exponents (`x_exp`, `y_exp`, `w_exp`), matching `rmsnorm`/`residual`/`matmul_rt`. The `v1.0` failure was `bfp_pack` routing *data* through an integer, which Vivado sign-drops; exponents travelled the same way and were never implicated. |
| Constrain at the real clock | Constrain at 200 MHz from the first implementation run. `v1.0`'s 100 MHz failure came from analysing a 333 ns period against a 10 ns reality. |

Division is not used anywhere in this datapath. Where a reciprocal becomes
unavoidable in later subsystems, `rtl/divider_rs.vhd` is the only sanctioned
mechanism; the VHDL `/` operator is prohibited.

## 9. Validation

`ref/matvec_int4.c` implements **exactly the numeric contract of §7.4** in
integer arithmetic. Every VHDL test compares against it.

**Width discipline in C is mandatory, not incidental.** `partial * scale`
reaches `2^27 x 2^15 = 2^42` and overflows 32-bit `int`; `acc` reaches ~2^33.8.
The reference must use `int64_t` for `partial * scale`, for `acc`, and for every
`round_shift` intermediate, and must model **`sat32`, `sat16`, and all four
rounding sites** of §7.4 explicitly. The C model may assume the §7.4 range
constraints hold (valid codebook, `scale <= 32767`, `0 <= out_shift <= 40`), so a
fuzz harness must not compare RTL behaviour on contract violations against C.

C `>>` on a negative signed value is implementation-defined before C23. The
reference must either assert arithmetic shift on the build platform or use an
explicit floor idiom for rounding site 1. The entire value
of bit-exactness rests on the C model **not** sharing the RTL's failure modes --
rev 1 specified an int48 accumulator in both, which would have made them agree
and both be wrong.

| # | Test | Checks |
|---|---|---|
| 1 | Dequant | all 16 codebook indices produce the correct int8 |
| 2 | Single MAC | random weight/activation pairs against C |
| 3 | Single row | K=32 (one block), then K=3584 (112 blocks) |
| 4 | Small matvec | M=8, K=32, all outputs |
| 5 | Real shapes | 1024->3584, 3584->1024, 1024->4096, and an lm_head slice |
| 6 | Backpressure | randomized `valid`/`ready` stalls must not change results |
| 7 | BFP mode | shared-exponent normalization matches `bfp_pack` semantics |
| 8 | Raw mode | int32 logit stream matches C |
| 9 | Column masking | `K` not a multiple of `BLOCK` |
| 10 | **Row masking** | `M` not a multiple of `ROWS_IF` suppresses padded rows |
| 11 | **Accumulator bound** | adversarial input: all weights at codebook extremes (+/-127), all activations at **-32768** (not +/-32767: -32768 is the true corner and is reachable because `bfp_pack` saturates there), `scale = 32767`, K=3584. Must stay within s28/s29/s48 and match C |
| 12 | **Saturation** | `out_shift` too small drives `sat32`, matching C |

Tests 6, 10, 11 and 12 are not optional. Test 11 in particular is the direct
guard against the rev 1 defect: had it existed, the wrapping accumulator would
have been caught in simulation rather than agreeing with an equally wrong C
reference.

## 10. Bring-up sequence

1. **GHDL** - all twelve test levels pass bit-exact.
2. **OOC synthesis** - real LUT/DSP/BRAM and Fmax for `matvec_core` alone.
3. **Timing at 200 MHz** - positive WNS before touching hardware.
4. **AXI path in isolation** - the PS writes a known blob to DDR,
   `weight_streamer` reads it back, checksums compared. Validates DDR and HP
   ports with no datapath involved, and **measures achieved GB/s**, resolving the
   §4 bandwidth premise.
5. **End-to-end on board** - the PS writes packed weights and an activation
   vector, the PL computes, the PS compares against `ref/matvec_int4.c` compiled
   for and running on the board's own ARM cores. No host required.

## 11. Acceptance criteria for v2.0

- All twelve GHDL test levels pass bit-exact against the C reference
- A real FFN-shaped matvec (1024 -> 3584) is bit-exact **on hardware**
- **Sustained bandwidth measured and reported as a percentage of DDR peak** - the
  number every projection in `docs/fpga-hardware-recon.md` depends on
- Resource report at `ROWS_IF = 4`, compared against the §7.9 budget
- Timing closes at the constrained 200 MHz with positive WNS

## 12. Risks

1. **Achieved DDR bandwidth is unverified.** See §4 for the three mechanisms that
   could reduce it. Measured at step 4; absorbed by changing `ROWS_IF`.
2. **Adder tree Fmax at 200 MHz** on a -1 speed grade ZU3EG. Five pipelined
   levels should close comfortably; confirmed at step 2. DSP Fmax is not the
   risk (~480 MHz at this grade); fabric fanout is.
3. **The scale multiply** is the known silicon hazard class from `v1.0-silicon`,
   mitigated by its dedicated pipeline stage and verified by step 5 rather than
   by simulation alone.
4. **SLICEM placement pressure** from 1,024 LUTRAM cells plus the write fanout.
   Low risk at `ROWS_IF=4`; revisit at FK33 scale where it becomes ~20,000 cells.

## 13. Scaling to FK33

| | AXU3EG (`v3.0`) | FK33 (`v4.0`) |
|---|---|---|
| `ROWS_IF` | 4 | **80** |
| `COLS_PC` (= `BLOCK`) | 32 | 32 |
| **MACS** | **128** | **2,560** |
| DSP (multiply + scale) | 136 / 360 | 2,720 / 2,976 |
| Adder-tree LUT | ~3,100 | ~62,000 |
| Activation read | 32/cycle | 32/cycle (unchanged) |
| Weight source | 4x AXI HP -> DDR4 | HBM AXI ports (32 available) |
| Demand @ clock | 14.4 GB/s @ 200 MHz | 432 GB/s @ 300 MHz |
| Available | ~12 GB/s | 460 GB/s |

Rev 1 gave "R=16, P=32 or R=4, P=128", which yields 512 MACs against the ~2,730
required, and `P=128` violated `COLS_PC = BLOCK`. Both are corrected: **scaling
is via `ROWS_IF` only**.

**The FK33 config is near-balanced, not comfortably memory-bound.** At
`ROWS_IF=80` demand is 432 GB/s against 460 GB/s nominal, i.e. `demand < supply`
-- the opposite inequality from the AXU3EG (14.4 > 12). At nominal HBM the array
is the limiter; it becomes memory-bound only once realistic HBM efficiency
(~70%) is applied. Rev 2 claimed it "preserves the memory-bound regime", which is
false at nominal numbers.

**What blocks closing the gap is HBM ports, not DSPs.** `ROWS_IF=86` needs
`86 x 34 = 2,924` DSPs, which fits in 2,976, and would demand
`86 x 144 bits x 300 MHz = 464 GB/s`, just over nominal. But weights alone then
need `86 x 128 b x 300 MHz = 412.8 GB/s` = 29 ports, and scales need 51.6 GB/s
= 4 ports: **33 against the 32 available**. At `ROWS_IF=80` the split is 27 + 4
= 31 ports, which fits.

**Scale port budget.** At `ROWS_IF=80` the scale stream needs
`80 x 16 = 1,280` bits/cycle, about 48 GB/s at 300 MHz, so `NPORTS_S` must rise
to roughly 4 HBM ports. Weights need roughly 27 of the 32 available HBM AXI
ports. The port budget is tight and must be re-derived, not inherited.

**Addressing.** `w_base`/`s_base` are 32-bit, which cannot address the FK33's
8 GB of HBM. They widen to 64 bits at `v4.0`.

`matvec_core` and the packer are unchanged in structure. `weight_streamer` is
replaced for HBM. The model is re-packed because `ROWS_IF` differs.
