# Prefill batching: can subsystem A compute K positions from one weight fetch?

TRACK PREFILL, 2026-09-20. Workstation, MAIN checkout, branch `fpga`.
**No hardware touched. No Vivado run. No RTL changed.** Peak RSS of anything
this track ran: **10,944 KiB MEASURED** (`/usr/bin/time -v` on the heaviest
step, the manifest parse); everything else was `awk`, `grep` and `sed`.

---

## 1. The question, verbatim

> On the card, prompt processing costs the same as generation: the 2026-09-20
> chat run MEASURED 34 GOs for 23 prompt tokens plus 11 generated, at 0.828 s
> each, so a 500-token prompt would take about seven minutes before the first
> output token. Every other inference stack amortises the weight fetch across
> the prompt by batching: one pass over W computes `Y = W X` for K positions at
> once. **Would that work here, what would it cost, and how much would it
> actually buy?** Give a defensible YES or NO with arithmetic, not an
> aspiration.

Hardware and build: SQRL FK33, `xcvu33p-fsvh2104-2L-e`, the shipped
`FK33_CARD=1` bitstream of 2026-09-20, engine core 75 MHz / HBM ACLK 250 MHz,
lane-striped image `qwen35-9b-mv4i-noembd-striped`.

---

## 2. The answer, up front

**NO. On the image the card runs today, batching subsystem A is worth 1.100x
of prefill and not one percent more at any K, because A's multiplier array is
already busy 65.4% of core cycles and the other 74% of the token is strictly
per-position. It cannot be built anyway: K = 2 needs 1,536 more DSP48E2 and
the part has 793 free, on a design placed at 99.81% CLB occupancy.**

Three findings, each independently sufficient to stop it:

1. **The batching ceiling is 1.53x of A's engine time and it is reached at
   K = 2.** The array accepts exactly one weight word per core cycle by
   construction (`NPORTS_W * AXI_DW = ROWS_IF * BLK * 4`, bit-exact), and
   MEASURED it takes 1.5298 cycles per word. K positions need K multiply
   passes per word, so per-position cycles per word go to 1.000 at K = 2 and
   stay there. K = 4, 8, 16 are all worth exactly what K = 2 is worth.
2. **That 1.53x applies to 26.3% of the token, so the whole lever is 1.100x.**
   B is 52.6% of the striped token and is a recurrent state update that cannot
   be batched at all; C, the three VEC ops and A's own card-side push and drain
   are per-position too. **Even a free, infinitely wide A engine gives only
   1.358x** (1.570x after the B lever). Batching gets 1.100x of that (1.144x
   after the B lever).
3. **The 1.100x it does buy is exactly the idle already sitting inside A, and
   closing that idle needs no extra multiplier.** The batching ceiling and the
   ceiling of a better weight prefetch inside A are the same number --
   5,184,256 cycles, one word per cycle -- because both are the same structural
   floor. One costs 1,536 DSPs that do not exist and helps prefill only; the
   other costs none and helps generation too.

**And the premise that the prompt is not amortised is half wrong.** Lane
striping already took the memory-amortisation win: it moved the token from
61.9 M to 30.1 M cycles, **2.056x, for zero DSPs**, by spreading the 27 read
masters across pseudo-channels. Batching is the second helping of a dish
already served, and the dish it is competing against is B.

The ranked answer to "what should be done instead" is in section 7. The
prefill-only lever worth having is **overlapping position t+1's A/C/VEC with
position t's B (1.899x today, 1.531x after the B lever)**, which also needs no
DSPs -- and even that is a distant second to finishing B.

---

## 3. The crux, settled from the RTL: what limits the 1.53 cycles per beat

This had to be settled before anything else, because batching amortises the
WEIGHT FETCH and a saturated datapath has nothing to give.

### 3.1 The array is exactly one weight word wide, and that is structural

`rtl/matvec_core.vhd:20-23` states the dataflow, and `:983-1008` is the
multiply:

```vhdl
-- s1: products.
for rr in 0 to ROWS_IF-1 loop
  for j in 0 to BLK-1 loop
    tr(0)(rr*BLK + j) <= resize(cb(...)(idx) * xw, 28);
```

`hw/fk33/gen_fk33_engine.py:84-98` fixes the card's geometry:

| constant | value | source |
|---|---:|---|
| `BLK` | 32 | `gen_fk33_engine.py:84` |
| `ROWS_IF` | 48 | `gen_fk33_engine.py:85` |
| `NPORTS_W` | 24 | `gen_fk33_engine.py:86` |
| `NPORTS_S` | 3 | `gen_fk33_engine.py:87` |
| `AXI_DW` | 256 | `gen_fk33_engine.py:88` |

**MEASURED (the manifest agrees):**
`/mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json` `geometry` reads
`{"rows_if": 48, "axi_dw": 256, "block": 32, "nports_w": 24, "n_scale_sub": 3,
"axi_read_masters": 27}`.

**DERIVED, and it is an identity, not a ratio:**

```
one weight word = ROWS_IF * BLK * 4 bits = 48 * 32 * 4 = 6,144 bits = 768 B
weight supply   = NPORTS_W * AXI_DW      = 24 * 256     = 6,144 bits
one scale  word = ROWS_IF * 16           = 48 * 16      =   768 bits
scale supply    = NPORTS_S * AXI_DW      =  3 * 256     =   768 bits
```

The generator says so itself (`gen_fk33_engine.py:225-228`): *"The duty
identity is `duty = f_core / f_hbm` exactly, because 27 x 256 bits is the
864 B the array consumes every core cycle"*. So:

- **`BEATS` is not an AXI beat count.** `rtl/matvec_int4_desc_axi.vhd:68-70`:
  *"weight words the array consumed. One word is `ROWS_IF*BLK*4` bits =
  `NPORTS_W` AXI beats, one from each weight port, so BEATS is NOT an AXI beat
  count."* Every "cycles per beat" figure in this project is **cycles per
  weight word**.
- **The structural floor is 1.000 cycles per word.** Not 1.53, not the 1.596
  the packer records. One word is one accept.
- **Per word the array performs `BLK * ROWS_IF = 1,536` products** of
  `int8 x int16` (the codebook entry times an activation), plus `ROWS_IF = 48`
  scale multiplies in their own stage (`matvec_core.vhd:1035-1040`). **That is
  the number batching multiplies by K**, because the weight nibble is shared
  across positions and the activation is not.

### 3.2 Independent check of the beat count (MEASURED, second source)

The 5,184,384 figure in `docs/2026-09-20_a-clock-domain-split.md` section 7 was
not inherited. Re-derived from the manifest's own `M`/`K` per tensor and the
249 distinct tensors the token-0 profile touches:

```
words = sum over the 249 tensors of ceil(M/48) * ceil(K/32)
      = 5,184,256           (this track, python3 over manifest.json)
ACLK doc                    5,184,384
agreement                   0.0025%
weight traffic per token    5,184,256 * 768 B = 3.98 GB
```

The 128-word difference is shard row-padding: the profile has 311 A_JOB steps
against 249 tensors, so some tensors are split and each shard rounds its row
count up to a 48-row tile. **Two sources, two methods, 0.0025% apart.** The
3.98 GB is the quantity batching would amortise and it is the right order for a
9B model at 4 bits.

---

## 4. Question 1: fetch-bound or datapath-bound, on each image

MEASURED, `hw/fk33/results/card_swg_2026-09-20/profile/`, summed with awk:

| image | A_JOB | B_JOB | C_JOB | VEC_* | token |
|---|---:|---:|---:|---:|---:|
| flat | 42,686,358 | 15,854,607 | 594,472 | 2,771,688 | 61,907,159 = 0.8254 s |
| striped | 10,894,638 | 15,854,448 | 594,472 | 2,771,688 | 30,115,246 = 0.4015 s |

Card-side share of A_JOB is 2,963,566 cycles (D pushing `K+2` x elements in
`S_XRD` and draining `M` rows in `S_DRAIN` at D's clock), DERIVED in
`docs/2026-09-20_a-clock-domain-split.md` section 7 and carried forward here
unchanged; it is identical on both images because D does not move.

| image | engine-side cycles | cycles per word | array busy | headroom to the floor |
|---|---:|---:|---:|---:|
| **striped** | 7,931,072 | **1.5298** | **65.4%** | **1.53x** |
| **flat** | 39,722,792 | **7.6622** | **13.1%** | **7.66x** |

**Striped: neither cleanly, but close enough to the datapath to matter.** The
array is idle 34.6% of core cycles. That idle is NOT memory supply: TRACK
STRIPE27 MEASURED the busiest pseudo-channel at 2 lanes supplying a 32 B beat
every 8.00 ns against a demand of one every 20.40 ns, i.e. **the memory is idle
61% of the time** (`docs/debugging/2026-09-20_stripe-width-after-the-kv-halved.md`
section 2). So the 0.53 cycles per word is per-job fixed overhead (descriptor
fetch, `S_CHECK`, pipeline fill and drain, burst boundaries) spread over 311
jobs -- about 8,832 cycles per job -- not starvation.

**Flat: supply-bound, and it is a MEAN over the job mix, not a constant.**
7.6622 cycles per word is 102.2 ns. The flat manifest has no `lane_stripe`
record, so the 27 masters read contiguous slices of one tensor and land on
whatever 256 MiB segments those slices fall in; a small tensor puts most of its
lanes on one pseudo-channel. At 4.00 ns per 32 B beat per PC, 24 weight lanes
on one PC is 96 ns and 27 lanes is 108 ns. **The measured 102.2 ns sits inside
that window**, which is why the figure is attributable to PC contention -- but
it is the average of a distribution across 249 tensors and **must not be
treated as a structural constant the way 1.000 cycles per word is.**

**Consequence for batching, and this is the part that decides it.** With K
positions per weight word the time per word is `max(K * 1.000, t_supply)`, so
per position it is `max(K, t_supply)/K`:

| image | K=1 | K=2 | K=4 | K=8 | K=16 | speedup ceiling | reached at |
|---|---:|---:|---:|---:|---:|---:|---|
| striped | 1.530 | **1.000** | 1.000 | 1.000 | 1.000 | **1.53x** | **K = 2** |
| flat | 7.662 | 3.831 | 1.916 | 1.000 | 1.000 | 7.66x | K = 8 |

**The conclusion is robust to where the 0.53 goes.** If it is per-job fixed
overhead, batching amortises it over K positions and the curve is
`1.000 + 0.530/K`, still capped at 1.53x. If it is a per-word stall, the K-1
extra compute cycles cover it and the curve is `max(K,1.530)/K`, the same cap.
Either way, **1.53x, at K = 2, and nothing beyond.**

**And the flat column is a historical curiosity, not an opportunity.** Striping
already collected 61,907,159 / 30,115,246 = **2.056x of it for zero DSPs.** The
remaining 1.53x is what is on the table, and the next three sections show it is
1.100x of the thing the user actually waits for.

---

## 5. Question 2: what is not batchable, and the Amdahl bound

### 5.1 Only A_JOB has a weight fetch to amortise (MEASURED from the RTL)

| opcode | cycles/token | per-position? | HBM weight fetch? | evidence |
|---|---:|---|---|---|
| A_JOB | 10,894,638 | engine part no, card part yes | **yes, 3.98 GB** | `matvec_int4_desc_axi.vhd:68-70` |
| B_JOB | 15,854,448 | **yes, strictly recurrent** | **no** | see 5.2 |
| C_JOB | 594,472 | **yes, and grows with position** | **no, KV cache only** | see 5.3 |
| VEC_NORM/RES/SWG | 2,771,688 | **yes** | **no** | see 5.4 |

### 5.2 B is a recurrent state update: state(t) = f(state(t-1))

Confirmed in the RTL, not assumed:

- old state read into the decay term, `rtl/gdn_recur_pipe.vhd:506`
  (`a_sf(k) <= signed(s_data(...))`, masked to zero only at `tk0`, `:503-505`)
- new state column formed `rtl/gdn_recur.vhd:595-600`, published `:632`
- write-back to state memory `rtl/gdn_block.vhd:889-894` (`if rp_ovalid = '1'
  then st_wen <= '1';`)

**B fetches no weight matrix from HBM at all.** Its projections arrive as
A-job outputs read from the on-chip region file -- `R_QKV`, `R_BETA`,
`R_ALPHA`, `R_Z` in `rtl/llama_top.vhd:5382, :5399, :5417, :5438` -- which is
why `ssm_beta`, `ssm_alpha` and `ssm_out` appear as separate A_JOBs in the
profile. The rest are learned constants with no region
(`llama_top.vhd:4575-4576`). B's only off-chip traffic is the recurrent state
itself, per-position by construction. **So there is nothing in B for batching
to amortise even if the recurrence permitted it, and it does not.**

### 5.3 C writes one position and sweeps the whole context

- one K record and one V record, both at the latched `cpos_r`:
  `rtl/attn_block.vhd:1433` and `:1454`
- the sweep visits `cpos_r + 1` positions in the order `[cur_pos, 0, 1, ...,
  cur_pos-1]` (`attn_block.vhd:1516-1521`, advance at `:1665-1673`)
- no large weight tensor: the only AXI master in the C path is
  `rtl/attn_kv_axi.vhd`, the KV cache. Q/K/V come from A's outputs in the
  region file (`llama_top.vhd:6580, :6598, :6616`); the QK-norm gains are an
  elaboration-time ROM (`llama_top.vhd:665-690, :6430`).

**"Amortising the weight fetch" does not apply to C at all.**

**C GROWS WITH POSITION, and the profile's 74,309 cycles is the value at
position 0.** DERIVED lower bound on the slope, from HBM traffic alone:
`kv_bytes_per_layer_per_token = 2,176` (manifest `hbm`), read over the
512-bit `r_rdata` port (`attn_kv_axi.vhd:339`) at 64 B per beat is 34 beats
per cached position per layer, times 8 C layers = **at least 272 cycles per
prompt position**. Over a 500-token prefill that adds
`272 * 500*499/2 = 33.9 M` cycles against a prefill of 15,058 M, i.e.
**0.23%.** Even at eight times the bandwidth floor it is under 2%. It does not
change any verdict here, but it does mean **the serial fraction grows with the
prompt, so the batching speedup at 500 tokens is slightly LOWER than the
position-0 figure, never higher.** The exact slope is in section 10 as open.

### 5.4 The vector ops touch no HBM weight

| op | RTL | weight source |
|---|---|---|
| `VEC_NORM` | `rtl/rmsnorm_bf_mem.vhd`, inst `llama_top.vhd:2732` | on-chip ROM, loaded by `llama_top.vhd:3295-3305`, declared `:3164-3167` |
| `VEC_RES` | `rtl/seq_vec_res.vhd`, inst `llama_top.vhd:1905` | none |
| `VEC_SWG` | `rtl/swiglu_mem.vhd`, inst `llama_top.vhd:3633` | none |

`llama_top.vhd:466-467` says it outright: *"The design still has no path by
which a gain reaches this unit from HBM."* All three are element-wise over one
position's activation vector. The norm gain is selected by `nidx`, which
advances on norm-op completion, so **a K-position batch would need K passes
through the norm regardless.**

### 5.5 A's card-side share is per-position too

`S_XRD` streams exactly `j_cols` elements for one vector
(`rtl/fk33_llama_top.vhd:4453-4464`, `xw_addr <= k-2` at `:4461`) and `S_DRAIN`
walks `r = 0 .. j_rows-1` for one result (`:4540, :4565`). Batching K positions
multiplies both by K. **2,963,566 cycles of the A_JOB total do not amortise.**

### 5.6 The Amdahl arithmetic (DERIVED)

Batchable = A engine-side only = 7,931,072 of 30,115,246 = **26.3%**.
Per-position cycles at batch K, with `cpw = max(K, 1.5298)`:

```
per_position(K) = (B + C + VEC + A_card) + WORDS * cpw / K
                = 22,184,174 + 5,184,256 * max(K, 1.5298) / K
```

| | K=1 | K=2 | K=4 | K=8 | K=16 | K -> inf |
|---|---:|---:|---:|---:|---:|---:|
| **B today (MEASURED)** | 30,115,246 | 27,368,430 | 27,368,430 | 27,368,430 | 27,368,430 | 27,368,430 |
| speedup | 1.000x | **1.100x** | **1.100x** | **1.100x** | **1.100x** | 1.100x |
| 500-token prefill | 200.8 s | **182.5 s** | 182.5 s | 182.5 s | 182.5 s | 182.5 s |
| **B after BENABLE (DERIVED)** | 21,835,246 | 19,088,430 | 19,088,430 | 19,088,430 | 19,088,430 | 19,088,430 |
| speedup | 1.000x | **1.144x** | 1.144x | 1.144x | 1.144x | 1.144x |
| 500-token prefill | 145.6 s | **127.3 s** | 127.3 s | 127.3 s | 127.3 s | 127.3 s |

**The hard ceiling, with A's engine time set to ZERO** (an infinitely wide
array, free): **1.358x today, 1.570x after the B lever.** That is the number
that ends the discussion: no amount of weight-fetch amortisation, by any
mechanism, at any cost, can do better than 1.36x of prefill on the image the
card runs, because 73.7% of the token is a per-position computation with no
weight fetch in it.

The B-after-BENABLE row uses `660,601 x 0.4778 = 315,633` per job, 24 jobs,
**8.28 M cycles off a token**, DERIVED by TRACK BENABLE (WORKLOG,
commit `14fa888`). Its own note records an additive alternative giving 8.07 M
and a 2.5% bench-to-card residual that is still unexplained. **The lever is
committed to RTL and has NOT been through a `FK33_CARD=1` build**, so every
"after BENABLE" row here is a projection of a projection and is labelled
DERIVED throughout.

---

## 6. Question 3: what it would cost

### 6.1 The real placed numbers, and the 109% figure is superseded

One track reported the design LUT-bound at 109%. That is
`docs/debugging/2026-09-16_card-build-is-lut-bound-at-109-percent.md`, and it
describes a build from **four days before** the shipped one, whose placer
refused to start at 479,919 LUT. **It is not the current state and must not be
quoted for this decision.** MEASURED, the shipped build's own report
`hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt`:

| resource | used | available | % | free |
|---|---:|---:|---:|---:|
| CLB LUTs | 363,095 | 439,680 | 82.58 | 76,585 |
| LUT as Logic | 297,323 | 439,680 | 67.62 | |
| LUT as Memory | 65,772 | 205,440 | 32.02 | |
| **CLB** | **54,854** | **54,960** | **99.81** | **106** |
| CLB Registers | 308,981 | 879,360 | 35.14 | 570,379 |
| **DSP48E2** | **2,087** | **2,880** | **72.47** | **793** |
| Block RAM Tile | 567 | 672 | 84.38 | 105 |
| URAM | 32 | 320 | 10.00 | 288 |
| CARRY8 | 12,592 | 54,960 | 22.91 | 42,368 |

**The binding number is CLB, at 99.81%: 106 empty CLBs on the part.** The
76,585 free LUTs are scattered inside CLBs that are already occupied, which is
exactly the state that makes a large new block unplaceable while the LUT
percentage still reads comfortable. Quote 99.81% CLB, not 82.58% LUT and not
109%.

### 6.2 Cost per extra position (DERIVED, structural)

| item | per extra position | free on the part | verdict |
|---|---:|---:|---|
| **product multipliers** (`BLK * ROWS_IF`) | **+1,536** | **793 DSP48E2** | **DOES NOT FIT** |
| scale multiplies | +48 | | |
| adder-tree levels 2..5 in fabric (`use_dsp "no"`, `matvec_core.vhd:400-401`) | `48 * (8+4+2+1) = 720` adders of 28-29 b, order 21,000 LUT + 2,600 CARRY8 | 106 free CLBs | **DOES NOT FIT** |
| accumulators `acc` (`matvec_core.vhd:407,412`) | +2,304 FF | 570,379 | fits |
| `sprod` + `contrib` tail if replicated | +3,552 FF | | fits |
| `ybuf` (`matvec_core.vhd:365-369`, `ram_style "block"`) | +557,568 b, about 22 RAMB36 | 105 tiles | fits at K=2 |
| `act_mem_striped` (`:67` `ram_style "block"`) | +278,528 b, about 15 RAMB36 | | fits at K=2 |
| `ybw` in the card top (`fk33_llama_top.vhd:4294-4299`) | +196,608 b, about 6 RAMB36 | | fits at K=2 |
| codebook | shared, 0 | | |

**K = 2 needs 1,536 DSP48E2 and 793 exist.** It is short by 743, i.e. it needs
1.94x the entire free DSP budget of the device, on a design whose CLBs are
99.81% occupied. There is no version of this that fits, and the LUT-based
alternative to the DSPs is worse: it wants CLBs, of which there are 106.

`rtl/act_mem_striped.vhd:56-63` carries a trap for whoever tries anyway:
flattening is load-bearing, and a nested `mem_t(0 to K-1)` does **not** infer
BRAM ([Synth 8-11357]) and builds registers instead. A batched activation
memory must stay one flat array with `waddr = k*n_cols + i`. The same note
appears on `ybuf` (`matvec_core.vhd:359-364`): nested, it becomes 557,056
registers.

One real piece of good news, recorded because it is the only part of the
proposal that is cheap: **at `n_cols = 4096` (qkv, gate, up, lm_head) K = 4
fits in the existing `ELEMS = 17408` activation memory with zero extra
storage.** `ffn_down` at `n_cols = 12288` admits K = 1 only
(`tools/gen_layer_program.py:390-410`). It does not rescue anything, because
the multipliers are the blocker, not the storage.

### 6.3 What would have to change, if the silicon existed

**Descriptor.** 312 bytes in a 512-byte slot
(`rtl/matvec_int4_desc_pkg.vhd:223-226`, `a_desc_adapter.vhd:60`). There are
**152 spare bits**, every one currently checked nonzero into `EC_DESC`:
word 7 all 64 (`ED_PAD_W7`, pkg `:167`), ext word 2 `[63:32]` and ext word 3
`[63:32]` (`ED_PAD_EXT`, `:168`), `ext_flags` 16 (`ED_EXT_FLAGS`, `:164`),
word 3 `[63:56]` (`ED_PAD_W3`, `:166`). Carrying K therefore needs
`MV4I_DESC_VER = 3` beside the existing v1/v2 arms (pkg `:30, :51`). **The slot
stride does not change**, so nothing already byte-pinned moves.

**And `x_exp` is the field that breaks.** Since 2026-09-18 the card does not
read the descriptor's `x_exp` at all: `USE_XEXP_PORT => true` under
`FK33_CARD=1` and the live value arrives on the wire, latched once per job in
`S_GO` at `rtl/fk33_llama_top.vhd:4486`
(`docs/debugging/2026-09-17_x-exp-is-baked-into-every-a-descriptor.md`, fourth
addendum). **One scalar exponent per job.** K positions each have their own BFP
exponent, so either `a_x_exp` widens to `K*32` on the seam or the K columns are
forced to share an exponent -- and forcing a shared exponent is a NUMERIC
change to a path that was proven bit-exact, not a plumbing change.

**`tools/gen_layer_program.py`.** `Step.__slots__` (`:315-318`) has no
position or batch field; `emit(opcode=OP_A_JOB, ...)` is called at 16 sites
(`:389-493`); `a_jobs_for()` (`:666`) builds one descriptor per A_JOB step with
`x_exp` as a **scalar argument applied to all of them** (`:774-799`). K becomes
a `Step` field threaded through both.

**Host.** `server/pl_backend.c`: `push_x_inner()` (`:1155`) writes one scalar
`FK33_SEAM_X_EXP` then does `n_embd` single-word MMIO writes of int16
mantissas (`:1175-1179`) -- **4,096 writes per position at the 9B shape**.
`run_chunk_inner()` (`:1206`) writes `SEQ_POS`, `N_STEP`, `CTRL = GO`
(`:1215-1227`).

**The seam, which refuses this in so many words.** `rtl/fk33_seam.vhd:934-935`:

```vhdl
if r_n_step /= 1 then bad := EC_NSTEP;  -- one position per GO in v2
```

mirrored by the host at `pl_backend.c:524-533`. The `ga_desc` FSM
(`rtl/fk33_llama_top.vhd:4357`) is `S_IDLE, S_XRD, S_GO, S_RUN, S_SDRAIN,
S_DRAIN, S_DONE` and `a_desc_adapter.vhd:111` is `S_IDLE, S_LO, S_HI, S_GO,
S_WAIT, S_DONE, S_REFUSE`, one GO per descriptor, strictly serialised by the
`u_ack` hold (`:302`). The wire widths are not the constraint --
`a_x_waddr`/`a_y_addr` at 16 bits carry K up to about 5 at `n_cols = 12288`
and 16 at 4,096. **What is sized for one position is the FSMs, `act_mem`
depth, `ybuf`/`ybw` depth and the single 32-bit `a_x_exp`.**

---

## 7. Question 4: cheaper routes to the same user-visible win, ranked

| # | lever | cycles/token | helps | change surface | cycles per line |
|---|---|---:|---|---|---|
| 1 | **overlap positions t / t+1 (A/C/VEC of t+1 against B of t)** | **14,260,798** | prefill only | D sequencer issues two opcodes; 2 activation/region sets | large but not small |
| 2 | **B mover levers (BENABLE, LANDED `14fa888`)** | **8,280,000** | **both** | **3 generic-map lines** | **2.76 M** |
| 3 | A clock split 75 -> 200 MHz (TRACK ACLK, designed, unbuilt) | 3,982,500 | both | generator + `rtl/fk33_eng_cdc.vhd`; needs a routed build | |
| 4 | close A's accept-port idle (prefetch the next job's descriptor and first bursts during the current drain) | 2,746,816 | **both** | inside `matvec_int4_desc_axi` / `weight_streamer`, **0 DSP** | |
| 5 | **full batching of A, any K >= 2** | **2,746,816** | **prefill only** | **+1,536 DSP (793 free); descriptor v3; seam `n_step`; host; program** | **does not fit** |

**Row 5 and row 4 save the identical number of cycles.** That is not a
coincidence and it is the sharpest way to state the result: both are capped by
the same structural floor of 5,184,256 cycles, one weight word per core cycle.
Row 4 reaches it by removing A's own per-job overhead and costs no multiplier;
row 5 reaches it by filling the same idle with a second position's arithmetic
and costs 1,536 multipliers that the device does not have. **Row 5 is row 4
with a DSP bill attached and half the applicability.**

**Row 1, the one worth scoping next if prefill is the goal.** B is a serial
resource of 15,854,448 cycles per position; A, C and the VEC ops are
14,260,798 on hardware that is not B. If position t+1's A/C/VEC ran while
position t's B ran, steady-state per position would be `max(15.85 M, 14.26 M)`:

| | serial today | overlapped | speedup | 500-token prefill |
|---|---:|---:|---:|---:|
| B today (MEASURED) | 30,115,246 | 15,854,448 | **1.899x** | 200.8 s -> 105.7 s |
| B after BENABLE (DERIVED) | 21,835,246 | 14,260,798 | **1.531x** | 145.6 s -> 95.1 s |

**It needs no DSPs.** The ordering argument is that both positions advance
monotonically through the same 32-layer program with t strictly ahead of t+1,
so every B job and every C KV write is still issued in position order without
any explicit interlock. The cost is that D must have two opcodes in flight and
the region file must hold two positions' intermediates -- a real change to the
sequencer, and one this track has NOT costed in LUTs. It is listed as the best
prefill-only lever, not as a recommendation.

**Row 1 and row 5 are equally prefill-only**, which is the fair comparison:
in generation position t+1's input is position t's output, so neither overlap
nor batching has anything to work with. That is worth stating because it is the
strongest argument for rows 2, 3 and 4: **they are the only ones that make the
11 generated tokens of that chat run faster as well as the 23 prompt tokens.**

---

## 8. Measured and REJECTED -- do not retry

- **Batching A at K = 4, 8 or 16 to get more than K = 2 gives.** It gives
  exactly the same 1.100x. The array is 1,536 products wide and K positions
  need K passes; per-position cycles per word is `max(K,1.53)/K`, which is
  1.000 for every K >= 2. **Do not propose a larger K as a way to buy more.**
- **Batching as a way to exploit "idle memory".** The memory idleness is real
  (61%, TRACK STRIPE27) and it is not the constraint. The card is at 65.4% of
  the datapath and 39% of the memory; the slack that batching converts is
  2,746,816 cycles, 9.1% of a token, and **that is the entire prize.**
- **One lane per pseudo-channel (the stripe-27 image) as a prefill lever.**
  Already REJECTED by TRACK STRIPE27 on its own terms: upper bound 3.2% of a
  token for 32.3% of the context, and `tools/check_kv_map.py` refuses the image
  against the shipped bitstream on 3 rows.
- **Quoting "LUT-bound at 109%" for this decision.** That is the
  2026-09-16 build, superseded. The shipped build places at 82.58% LUT and
  **99.81% CLB**.
- **Quoting the free-LUT count as headroom.** 76,585 LUTs are free and 106 CLBs
  are free. The second number is the one a new block has to fit in.
- **Treating the flat image's 7.66 cycles/word as a batching opportunity.**
  Striping already took 2.056x of it for zero DSPs and the card runs striped.

---

## 9. Measurement traps hit on the way

- **"Beats" in every prior document means WEIGHT WORDS, not AXI beats.**
  `matvec_int4_desc_axi.vhd:68-70` says so explicitly. Reading 5,184,384 as
  32 B AXI beats gives 166 MB of weight traffic per token for a 9B model, which
  is wrong by 24x and would have made the engine look memory-starved. The tell
  was that 5,184,256 * 768 B = 3.98 GB is the right size for the model, and the
  4 in 24 is `NPORTS_W`.
- **The profile's 74,309-cycle C_JOB is the value at position 0, not a
  constant.** `attn_block.vhd:1665-1673` sweeps `cpos_r + 1` positions.
  Projecting a 500-token prefill by multiplying the token-0 profile by 500 is
  optimistic; here it is optimistic by about 0.23% and so does not matter, but
  the same mistake on a longer context would.
- **`docs/debugging/2026-09-16_card-build-is-lut-bound-at-109-percent.md` is
  four days older than the shipped build and its filename reads like a current
  fact.** This is the recorded same-tree trap: the date is in the content, not
  in the name. The brief warned about exactly this and the warning was
  necessary.
- **`hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt` has
  no hierarchical section**, so DSPs cannot be attributed to A from it. The
  2026-09-16 OOC figure of 538 DSP for B+C+D would give A = 1,549 against a
  structural 1,536 + 48 = 1,584, but **CLAUDE.md is explicit that parts do not
  sum across synthesis contexts** and the two runs are four days apart. The
  attribution is NOT claimed. **It is not needed either**: the decisive
  arithmetic is "K = 2 needs 1,536 more DSPs and 793 are free", which uses only
  the structural product count and the placed total.
- **`hw/fk33/results/card_swg_2026-09-20/profile/striped_verify_after_token.log`
  is full of `FAIL ... the bytes on the card are NOT this tensor`.** It is a
  read-back of the HBM image and belongs to the 2026-09-20 silent-overwrite
  defect, not to the profile. It was read, recognised as another track's
  symptom and left alone; the cycle counts in the two `profile_*.txt` files are
  unaffected by it.

---

## 10. Open, not determined

- **The exact slope of C against position.** Section 5.3 gives a bandwidth
  lower bound of 272 cycles per prompt position across the 8 C layers, derived
  from `kv_bytes_per_layer_per_token = 2,176` over a 512-bit port. The FSM cost
  (`P_RECK` / `P_HDR` / `P_SCORE` / `P_POSN`) was not counted, so the true
  slope is somewhere between 272 and perhaps 8x that. At 500 tokens even the
  high end is under 2% of prefill, so no verdict here depends on it -- but
  **nobody has measured a C_JOB at a position other than 0**, and at a
  4,000-token context it would matter.
- **Where A's 0.53 cycles per word of overhead actually goes.** It is
  8,832 cycles per job over 311 jobs, and it has not been attributed to
  descriptor fetch, `S_CHECK`, pipeline fill/drain or burst boundaries. Row 4
  of section 7 cannot be sized until it is. **The card's own `CYCLES` and
  `BEATS` counters can be read per job and nobody has done it.**
- **Whether the overlap of section 7 row 1 fits.** Its LUT cost is not
  estimated. Two positions in flight needs a second set of region-file
  intermediates, and the region file is already a large part of the 99.81% CLB.
  **It could easily not fit either**, and this track did not attempt to find
  out.
- **B after BENABLE has not been built.** 8.28 M is DERIVED by ratio from a
  GHDL bench with a 2.5% unexplained bench-to-card residual; the additive
  alternative gives 8.07 M. Every "after BENABLE" number here inherits that.
- **The 2,963,566 card-side cycles are inherited from TRACK ACLK section 7,
  not re-derived here.** They are a DERIVED figure (`sum(K+2)` push plus
  `sum(M)` drain) and were not independently checked by this track, unlike the
  beat count, which was.
- **Whether a codebook-grouped reformulation changes the product count.** The
  codebook has only 16 entries, so per row-block one could accumulate the 32
  activations into 16 per-index sums and then do 16 multiplies instead of 32.
  That halves multiplies at the cost of 32 adds, and it is a redesign of the
  numeric contract, not batching. **It does not rescue batching** -- K
  positions need K sets of those sums, so the cost stays proportional to K --
  but it has never been priced as a lever in its own right and it is the only
  idea found here that attacks the 1,536 directly.
