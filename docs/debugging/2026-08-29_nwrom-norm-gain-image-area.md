# Is `NORM_W_IMAGE` bigger than what TRACK NORMADAPT just removed, and should the gain table be a ROM at all?

**Date:** 2026-08-29
**Track:** NWROM
**Baseline, pinned as its own step before `git archive`:**
`3853650d586f99feb5c8f617d08643fe28150acb`, extracted to
`/mnt/storage/nwrom/src`. The brief named `45981f0`; HEAD had already moved to
`3853650` (TRACK OI3MUT's commit) by the time the archive was taken.
`git diff 45981f0..3853650 -- rtl/llama_top.vhd` is EMPTY and
`md5sum` is `d55fa9024c14960449c8627234f76f67` in the archive and in the working
tree, so the one file that matters is identical across the brief's sha, the
pinned sha and the live tree.
**Tools:** Vivado 2023.2 for every area number, through TRACK LUTDIET's
`sim/ooc_lutdiet_run.sh` and `sim/ooc_lutdiet_ports.tcl` **unmodified**,
`xcvu33p-fsvh2104-2L-e`, 5.0 ns, `-mode out_of_context -flatten_hierarchy none`,
`LUTDIET_NOOPT=1`, `LUTDIET_CENSUS=1`. GHDL 1.0.0 (mcode) only to syntax-check
the generated probes. Python 3 + `gguf` to build the gain image.
**Configuration:** `NORM_REAL = true`, `SHAPE.hidden = 4096`, `NORM_LANES = 4`,
`NORM_Q = 12`, `NORM_W_EXP = 12`. **`NORM_REAL` defaults FALSE**, so none of
this path is in `sim/ooc_compose_bcd.tcl`'s default-generics synthesis; every
number below is for the `NORM_REAL = true` configuration a real build needs.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `program_hw_devices`,
nothing under `hw/fk33/host` or `hw/fk33/tcl`, nothing opening `/dev/xdma*`.
**Artefacts:** `hw/fk33/results/nwrom_2026-08-29/`

---

## 1. The question, verbatim

> TRACK NORMADAPT ... took `llama_top`'s D-vec norm adapter from 126,267 to
> **49,654 CLB LUT** (-76,613, -60.7%) at identical DSP, identical BRAM and WNS
> identical to 13 significant figures.
>
> **It then flagged a risk that could erase the entire gain, and labelled it
> ESTIMATE:**
>
> > **The `NORM_W_IMAGE` ROM is unmeasured and may be bigger than what I just
> > removed.** With a real gain image at 9B, `NW_TBL` is 65 entries of 65,536
> > bits with a 65:1 mux on `wsel`. ESTIMATE, flagged in section 9.
>
> **Measure it.** ... If populating it costs more than 76,613 LUT, NORMADAPT's
> win is notional and the schedule picture is worse than the board currently
> says.
>
> 1. What `NORM_W_IMAGE` actually is at the 9B shape ...
> 2. The measured LUT/FF/BRAM/DSP cost of a populated `NORM_W_IMAGE` at the real
>    9B shape, against the empty-image baseline NORMADAPT measured ...
> 3. Whether it should be a ROM at all. ... If the answer is "put it in memory",
>    say so with numbers.

---

## 2. The answer, up front

**Two answers, and the first one is not about area at all.**

**(a) MEASURED, and it is a hard defect: at the real 9B shape the committed
`NORM_W_IMAGE` loader does not synthesise. It fails ELABORATION.**

    ERROR: [Synth 8-403] loop limit (65536) exceeded [.../ooc_normadapt_top.vhd:187]
    ERROR: [Synth 8-421] mismatched array sizes in rhs and lhs of assignment [...:199]
    ERROR: [Synth 8-285] failed synthesizing module 'ooc_normadapt' [...:63]

Line 187 is `nw_count`'s `while not endfile(fh) loop`. The image format is one
4-hex-digit int16 **per line**, so 65 norm ops x 4096 elements is **266,240
lines** against Vivado's default elaboration loop limit of **65,536**. The
second error is the consequence of the first, not a second fault: `nw_count`
having failed, `NW_N` is wrong and the `hread` target no longer matches. The
threshold was bracketed by measurement, not assumed: `NW_N = 9` (36,864 lines)
elaborates, `NW_N = 17` (69,632 lines) does not.

**This is invisible to every check the project runs.** GHDL has no such limit,
so the `tb_llama_top_normw` gate row passes -- and that row's image is
`sim/llama_top_nw_b4_mean.hex`, **576 lines** (9 norm ops x 64 elements at the
scaled shape), three orders of magnitude under the limit. **A row that pins the
feature cannot reach the failure**, and the only configuration anyone has
synthesised has the generic empty.

The fix is one Tcl line, and it is measured to work
(`sim/ooc_nwrom_loopfix.tcl`):

    set_param synth.elaboration.rodinMoreOptions {rt::set_parameter maxLoopLimit 4000000}

**(b) MEASURED, with that limit raised: populating `NORM_W_IMAGE` costs
32,943 CLB LUT, which is 43.0% of the 76,613 NORMADAPT removed. The flagged
risk is REFUTED. NORMADAPT's win survives with 43,670 LUT still in hand.**

| tag | `NORM_W_IMAGE` | CLB LUT | adapter's own | `gvr.u_rms` | CLB FF | DSP | BRAM tile | URAM | CARRY8 | F7 | F8 | WNS | Fmax | synth s | peak RSS |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `nw_empty` | empty (`NW_N = 1`) | **49,654** | 25,523 | 24,131 | 133,197 | 41 | 0 | 0 | 268 | 18,208 | 8,944 | +1.675 | 300.752 | 172 | 11.87 GiB |
| `nw_lf65` | **real 9B, 65 ops** | **82,597** | 43,627 | 38,970 | 162,217 | 41 | 0 | 0 | 268 | 23,718 | 11,156 | +1.675 | 300.752 | 382 | 15.27 GiB |
| `nw_lfblk65` | real 9B, table in BRAM | 72,073 | 30,507 | 41,566 | 194,797 | 41 | **135** | 0 | 268 | 26,528 | 13,200 | +1.675 | 300.752 | 449 | 13.74 GiB |
| `nw_lfura65` | real 9B, `rom_style ultra` | 72,164 | 30,598 | 41,566 | 194,821 | 41 | **114** | **0** | 268 | 26,528 | 13,200 | +1.442 | 281.057 | 467 | 14.82 GiB |

**+32,943 CLB LUT, +29,020 CLB FF, DSP unchanged at 41, BRAM unchanged at ZERO,
CARRY8 unchanged at 268, and WNS bit-identical at `+1.675` /
`300.7518796992481 MHz`.** `nw_empty` reproduces NORMADAPT's `na_after` **exactly
on all eleven columns**, so the two tracks' numbers are on the same scale
without adjustment.

**(c) Almost half of that cost is NOT the ROM, and it is not in this file.**
Census, `nw_empty` -> `nw_lf65`:

| root | before | after | delta | where it lives |
|---|---:|---:|---:|---|
| `gvr.wsel` | 0 | 18,954 | **+18,954** | the adapter -- the 65-entry table and its select |
| `ARG` | 480 | 15,567 | **+15,087** | **inside `gvr.u_rms`, i.e. `rmsnorm_rs`** |
| `gvr.xw` | 5,425 | 5,936 | +511 | the adapter's input staging |
| `gvr.uw_data` | 20,192 | 19,872 | -320 | the adapter's output read mux |
| `sq` | 17,475 | 17,475 | 0 | `rmsnorm_rs` |

`ARG` is `rmsnorm_rs`'s own `w_mant` read mux. With the image empty the gain is
an elaboration-time constant and Vivado folds that mux to 480 LUT; with a real
image it is a real mux again. **That 15,087 is the price of having a real gain
AT ALL and is independent of where the table is stored** -- confirmed, not
assumed: in `nw_lfura65`, where the table is in BRAM and there is no mux left in
the adapter, `ARG` is **17,916**, which is *higher*, and is exactly the
standalone figure TRACK LUTDIET measured for `rmsnorm_rs` at N=4096.
**`rtl/rmsnorm_rs.vhd` is TRACK READCONV's file and this track did not touch
it.**

**(d) Whether it should be a ROM at all: MEASURED, and the answer is "memory
does not pay here."** Forcing the table into block RAM saves **10,524 LUT
(12.7%)** and costs **135 of the device's 672 BRAM tiles (20.1%)** and **32,580
extra flip-flops**. Trading a fifth of the device's block RAM for 10.5k LUT is a
bad rate in a design where B already uses 43 tiles and C 11. Two further
measured facts about that route:

- **`rom_style = "ultra"` does NOT produce URAM.** MEASURED: `nw_lfura65`
  reports **0 URAM** and 114 BRAM tiles (113 RAMB36E2 + 2 RAMB18E2). The 320
  URAMs sitting unused stay unused; the attribute was accepted and ignored.
- **The BRAM route costs timing in one of its two forms.** `nw_lfura65` drops
  WNS from +1.675 to **+1.442** (Fmax 300.752 -> 281.057, -6.5%), while
  `nw_lfblk65` holds +1.675. Same RTL apart from one attribute string.

**(e) The recommendation, stated as what it is.** The cheapest structure is
neither of the ones measured: **the gain is a learned WEIGHT and belongs in HBM
behind a region, like every other weight**, at which point `NW_TBL` does not
exist -- no 18,954 LUT of table, no 135 BRAM tiles -- and what remains is the
streaming write into the 65,536-bit `wsel` register. `nw_lfura65`'s census
prices that write at `gvr.wsw` = **5,532 LUT / 61,440 FF**, using exactly
NORMADAPT's whole-word target and not the runtime slice it removed.
**ESTIMATE, and the assumption is stated: ~72,000 LUT and 0 BRAM for this block,
plus whatever the region read path costs, which is not in any measurement
here.** `rtl/llama_top.vhd`'s own comment already says this gap is open --
"the design still has no way for a norm gain to reach this unit from HBM" -- and
these numbers are the first price on closing it.

**(f) The composition, MEASURED, replacing NORMADAPT's `D_norm`.** B, C and
`D_seq` are TRACK WRITEDEC's and COMPOSE's numbers used verbatim; this track
adds no independent evidence for them.

| booking | B | C | D_seq | D_norm | total | vs 268,222 free (device) | vs 233,765 free (`pb_core`) |
|---|---:|---:|---:|---:|---:|---|---|
| NORMADAPT's realistic, **`NORM_W_IMAGE` empty** | 131,760 | 85,816 | 6,614 | 49,654 | 273,844 | OVER by 5,622 (1.02x) | OVER by 40,079 (1.17x) |
| realistic, **real 9B gain image** | 131,760 | 85,816 | 6,614 | **82,597** | **306,787** | **OVER by 38,565 (1.14x)** | **OVER by 73,022 (1.31x)** |
| realistic, real image, table in BRAM | 131,760 | 85,816 | 6,614 | 72,073 | 296,263 | OVER by 28,041 (1.10x) | OVER by 62,498 (1.27x), **+135 BRAM** |

**So the board's current 273,844 is a number for a configuration no real build
can use**, and the honest figure for a build that actually normalises is
**306,787**. That is still 43,670 better than the 350,457 NORMADAPT started
from, and the READCONV read conversion is still the lever, exactly as WRITEDEC
and NORMADAPT both said.

---

## 3. Corrections to the brief and to NORMADAPT

| claim | verdict |
|---|---|
| NORMADAPT: "at 32 blocks that is 65 entries and **4.26 Mbit of constant plus a 65:1 mux of 65,536 bits, entirely unmeasured** ... potentially a bigger item than the one this track just removed" | **The SHAPE is exactly right and the SIZE is refuted.** 65 entries x 4096 elements x 16 bits = 4,259,840 bits is correct to the bit, and `NW_N = 2*BLOCKS+1 = 65` is confirmed from `tools/gen_llama_top_weights.py`'s `build_plan`. But MEASURED it costs **32,943 LUT, not more than 76,613** -- 43.0% of the saving, not 100%+ of it |
| the brief: "If populating it costs more than 76,613 LUT, NORMADAPT's win is notional" | **It does not. The win is real**, and 43,670 LUT of it survives populating the image |
| NORMADAPT: "`w_mant`'s read mux (17,916 LUT standalone) collapses to 480" | **CONFIRMED on both ends, in the same build.** 480 at `nw_empty`; and `nw_lfura65`, where the adapter's mux is gone entirely, reports `ARG` at **17,916** -- the standalone figure reproduced to the LUT |
| the brief: "A 65:1 mux over 65,536-bit entries is a shape that BRAM or URAM may absorb for almost nothing, exactly as LUTDIET measured (299,030 -> 4,798 LUT for +6 BRAM tiles)" | **Measured and NOT reproduced at this ratio.** LUTDIET's 62:1 return was on a port whose consumer reads a few elements per cycle; here the consumer's port is 65,536 bits wide and combinational, so the selected gain must stay resident in fabric registers no matter where the table lives. Measured return: **10,524 LUT for 135 BRAM tiles and +32,580 FF**, i.e. 78 LUT per tile against LUTDIET's 49,039 |
| the brief: "the device has BRAM and URAM sitting unused in every measurement taken tonight" | **True, and URAM stays unusable by this structure.** `rom_style = "ultra"` yields **0 URAM**; Vivado maps the table to BRAM regardless |
| NORMADAPT: "`m_nidx_at_accept` SURVIVES ... the gain sequencing is untested at the synthesis default and needs a `NORM_W_IMAGE` trial to be tested at all" | **RESTATED, NOT CLOSED.** This track is an AREA track: it synthesised `NW_N = 65` and never simulated it. The blind spot is unchanged and is still open. See section 8 |
| NORMADAPT: peak RSS 12.50 GiB, "budget for that" | **CORRECTED UPWARD. MEASURED 15.27 GiB** for `nw_lf65` on a 31 GB box. A populated table is 3 GiB more expensive to synthesise than an empty one |

---

## 4. The procedure, and what each step isolates

1. **Read the RTL, by content, for what `NORM_W_IMAGE` actually is.** `NW_TBL`
   is `array (0 to NW_N-1) of std_logic_vector(NN*MANT_W-1 downto 0)`;
   `NW_N = nw_count`, which counts the image's LINES and divides by `NN`;
   `wsel <= NW_TBL(nidx)` is a REGISTERED read of that constant; `wsel` feeds
   `rmsnorm_rs`'s flat `w_mant` port. *What this isolates:* the mux is on a
   65,536-bit word because the CONSUMER'S PORT is 65,536 bits, which is what
   makes the memory question different from LUTDIET's.
2. **Build the image from the real model, at the real width.**
   `sim/ooc_nwrom_gen_image.py` imports `build_plan`, `reduce_gain` and
   `quantize_gain` from `tools/gen_llama_top_weights.py` so the schedule order,
   the tensor names and the quantiser have exactly one definition, and asks for
   `--hidden 4096`, where `reduce_gain` is the identity. *What this isolates:*
   `--norm-out` on that tool reduces to hidden = 64 for the bench, and a
   64-wide image would have measured the wrong thing.
3. **Use REAL gain values, never random ones.** The area of a constant table is
   a function of its BITS. Measured on the real image: of the 65,536 bit
   positions, **8,640 are constant across the 65 ops and 56,896 vary**; bits 14
   and 15 are constant in all 4096 elements, because a trained RMSNorm gain sits
   near 1.0 and 2^12 is 4096. Random data would have made every bit vary and
   overstated the answer.
4. **Take the empty-image control in the SAME session, with the same script.**
   `nw_empty` is not quoted from NORMADAPT; it was re-measured and matched on
   all eleven columns.
5. **Measure the COMMITTED RTL, not a model.** The top is `ooc_normadapt`,
   generated by `sim/ooc_normadapt_extract.py` from the pinned `llama_top.vhd`,
   which copies the `gvr` block verbatim between content anchors and aborts
   unless each matches exactly once.
6. **When the committed RTL would not elaborate, fix the TOOL and not the RTL,
   and keep LUTDIET's script unmodified.** `sim/ooc_nwrom_loopfix.tcl` sets one
   parameter and then `source`s `sim/ooc_lutdiet_ports.tcl` untouched, so every
   flag, the part, the period and the census stay LUTDIET's.
   *What this isolates:* it keeps the measured design bit-for-bit the shipping
   one. The alternative -- editing `nw_count` -- was also built
   (`sim/ooc_nwrom_bounded.py`) and is reported in section 6.4 precisely because
   it does NOT give the same answer.
7. **Sweep `NW_N` rather than measuring one point**, because a single synthesis
   number on a design with this much constant folding is not a trend.
8. **`cmp` every pinned file into each synthesis tree before synthesising it**,
   and GHDL-analyse every generated probe before spending a Vivado run on it.
9. **One Vivado at a time**, on NORMADAPT's wait rule with its bounded patience.

---

## 5. The evidence, as raw output

### 5.1 The result CSVs, verbatim

    target,gen,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,synth_lut,synth_ff,synth_dsp,synth_bram
    ooc_normadapt,"",41,49654,49654,0,133197,0,0,0,0,268,18208,8944,1.675,300.7518796992481,172,-1,49654,133197,41,0
    ooc_normadapt,"NORM_W_IMAGE=/mnt/storage/nwrom/norm_w_9b.hex",41,82597,82597,0,162217,0,0,0,0,268,23718,11156,1.675,300.7518796992481,382,-1,82597,162217,41,0
    ooc_nwrom_memblk,"NORM_W_IMAGE=/mnt/storage/nwrom/norm_w_9b.hex",41,72073,72073,0,194797,135,0,135,0,268,26528,13200,1.675,300.7518796992481,449,-1,72073,194797,41,135
    ooc_nwrom_memura,"NORM_W_IMAGE=/mnt/storage/nwrom/norm_w_9b.hex",41,72164,72164,0,194821,113,2,114,0,268,26528,13200,1.442,281.0567734682406,467,-1,72164,194821,41,114
    ooc_normadapt,"NORM_W_IMAGE=/mnt/storage/nwrom/norm_w_n2.hex",41,62700,62700,0,162976,0,0,0,0,268,22546,9712,1.675,300.7518796992481,186,-1,62700,162976,41,0
    ooc_normadapt,"NORM_W_IMAGE=/mnt/storage/nwrom/norm_w_n5.hex",41,88383,88383,0,182502,0,0,0,0,268,24953,12230,1.675,300.7518796992481,199,-1,88383,182502,41,0
    ooc_normadapt,"NORM_W_IMAGE=/mnt/storage/nwrom/norm_w_n9.hex",41,71331,71331,0,158198,0,0,0,0,268,24893,12178,1.675,300.7518796992481,217,-1,71331,158198,41,0
    ooc_nwrom_bnd,"NORM_W_IMAGE=/mnt/storage/nwrom/norm_w_9b.hex NW_OPS=65",41,103081,103081,0,179156,0,0,0,0,268,24281,11632,1.675,300.7518796992481,422,-1,103081,179156,41,0

### 5.2 The elaboration failure, verbatim

    ERROR: [Synth 8-403] loop limit (65536) exceeded [/mnt/storage/nwrom/rtl/ooc_normadapt_top.vhd:187]
    ERROR: [Synth 8-421] mismatched array sizes in rhs and lhs of assignment [/mnt/storage/nwrom/rtl/ooc_normadapt_top.vhd:199]
    ERROR: [Synth 8-285] failed synthesizing module 'ooc_normadapt' [/mnt/storage/nwrom/rtl/ooc_normadapt_top.vhd:63]
    ERROR: [Common 17-69] Command failed: Vivado Synthesis failed

Line 187 is `while not endfile(fh) loop`; line 199 is
`r(k)((i+1)*MANT_W-1 downto i*MANT_W) := v;`. Five points failed identically:
`nw_n65` (266,240 lines), `nw_n33` (135,168), `nw_n17` (69,632), and both memory
variants at 65 ops. `nw_n9` (36,864) and everything smaller elaborated. The
bracket is therefore between 36,864 and 69,632, consistent with 65,536.

### 5.3 The hierarchical split

    | ooc_normadapt     |      (top) |      49654 | ... | 133197 | ... | 41 |   nw_empty
    |   (ooc_normadapt) |      (top) |      25523 | ... |  66006 | ... |  1 |
    |   gvr.u_rms       | rmsnorm_rs |      24131 | ... |  67191 | ... | 40 |

    | ooc_normadapt     |      (top) |      82597 | ... | 162217 | ... | 41 |   nw_lf65
    |   (ooc_normadapt) |      (top) |      43627 | ... |  95040 | ... |  1 |
    |   gvr.u_rms       | rmsnorm_rs |      38970 | ... |  67177 | ... | 40 |

**+18,104 in the adapter and +14,839 inside `rmsnorm_rs`**, on a preserved
boundary (`-flatten_hierarchy none`).

### 5.4 The census, `nw_empty` -> `nw_lf65` -> `nw_lfura65`

    nw_empty                                 LUT   MUXF7   MUXF8       FF  CARRY8
    gvr.uw_data                            20192    9504    4592       16       0
    sq                                     17475    8704    4352        0       0
    gvr.xw                                  5425       0       0    65536       0
    gow.o                                   2943       0       0        0       0
    max_raw                                 1046       0       0       63      56
    ARG                                      480       0       0        0      11
    # LUT primitives accounted: 50819 of 50819

    nw_lf65                                  LUT   MUXF7   MUXF8       FF  CARRY8
    gvr.uw_data                            19872    9328    4608       16       0
    gvr.wsel                               18954      44       0    28958       0
    sq                                     17475    8704    4352        0       0
    ARG                                    15567    5642    2196        0      11
    gvr.xw                                  5936       0       0    65536       0
    gow.o                                   2947       0       0        0       0
    # LUT primitives accounted: 85118 of 85118

    nw_lfura65                               LUT   MUXF7   MUXF8       FF  CARRY8
    gvr.uw_data                            19424    9120    4496       16       0
    ARG                                    17916    8704    4352        0      11
    sq                                     17475    8704    4352        0       0
    gvr.xw                                  5690       0       0    65536       0
    gvr.wsw                                 5532       0       0    61440       0
    gow.o                                   2943       0       0        0       0
    # LUT primitives accounted: 73433 of 73433

On this design a LUT primitive is very nearly a CLB LUT: 85,118 / 82,597 =
1.031, 50,819 / 49,654 = 1.023. **`gvr.wsel` carries 44 MUXF7 and ZERO MUXF8**,
so the 65:1 select is not built as a mux tree; Vivado folds each output bit into
logic of the seven `nidx` bits and then merges equivalent flops, which is why
`wsel` holds 28,958 flops rather than the 56,896 bits that vary.

### 5.5 The bit statistics of the real gain, which are why the answer is not the naive one

    k  varying_bit_positions_of_65536  distinct_non-constant_patterns
     2   29820        2
     5   49501       30
     9   51947      510
    17   52907    27391
    33   53133    39141
    65   56896    46594

    value range 16 .. 12256, mean 4471.8   (NORM_W_EXP = 12, so 4096 == 1.0)
    bit15 constant in 4096 of 4096 elements
    bit14 constant in 4096 of 4096 elements
    bit13 constant in  442 of 4096 elements
    bits 0..12 constant in 0..6 of 4096 elements

The FF count is predicted by the varying-bit count where Vivado does not merge:
`nw_n2` measured 162,976 against 133,197 + 29,820 = 163,017 (-41), `nw_n5`
measured 182,502 against 133,197 + 49,501 = 182,698 (-196). At `k = 9` and above
the merging kicks in and the prediction stops holding, which is the next point.

### 5.6 The `NW_N` sweep is NOT monotonic, and that is the measurement

| `NW_N` | CLB LUT | adapter's own | CLB FF | `gvr.wsel` LUT / FF |
|---:|---:|---:|---:|---|
| 1 (empty) | 49,654 | 25,523 | 133,197 | absent |
| 2 | 62,700 | 25,579 | 162,976 | absent (folded into the flop's D) |
| 5 | **88,383** | 50,114 | 182,502 | 49,343 / 49,343 |
| 9 | 71,331 | 33,045 | 158,198 | 15,348 / 25,032 |
| 65 | 82,597 | 43,627 | 162,217 | 18,954 / 28,958 |

**`NW_N = 5` is the most expensive point measured, and it is 5,786 LUT worse
than the real 65.** Do not read this table as a growth curve: past `NW_N = 5`
the cost is flat-to-falling and the ordering is set by whether Vivado's flop
merging fires, not by the table's size. At `k = 5` there are only 30 distinct
non-constant bit patterns and Vivado merged none of them; at `k = 9` there are
510 and it merged most; at `k = 65` there are 46,594 and there is little left to
merge. The practical consequence: **a `NORM_W_IMAGE` measurement taken at a
convenient small `NW_N` can be worse than the real one and must not be
extrapolated.**

### 5.7 The bounded probe's teeth-check: identical where both elaborate

`sim/ooc_nwrom_bounded.py` replaces `nw_count`'s counting loop with a generic
and changes nothing else. At `NW_N = 2`, where BOTH forms elaborate, the two
are indistinguishable:

    nw_n2     ooc_normadapt  62700  own 25579  u_rms 37121  ff 162976  dsp 41  bram 0  carry8 268  f7 22546  f8 9712
    nw_bnd2   ooc_nwrom_bnd  62700  own 25579  u_rms 37121  ff 162976  dsp 41  bram 0  carry8 268  f7 22546  f8 9712

Eleven columns, no difference. **So the 20,484 LUT gap between `nw_bnd65` and
`nw_lf65` is not a difference between two designs; it is the same design
synthesised twice down a slightly different elaboration path.** That is the
strongest statement this track can make about the confidence interval on any
one number here, and it is why 5.6's non-monotonic sweep should be read as
noise rather than as a curve.

### 5.8 Peak RSS, because the box is 31 GB

    tag=nw_empty    peak_rss_gib=11.87
    tag=nw_bnd65    peak_rss_gib=11.63
    tag=nw_lfblk65  peak_rss_gib=13.74
    tag=nw_lfura65  peak_rss_gib=14.82
    tag=nw_lf65     peak_rss_gib=15.27

---

## 6. Measured and REJECTED -- do not retry

- **`rom_style = "ultra"` to reach URAM.** MEASURED: `nw_lfura65` reports **0
  URAM** and 114 BRAM tiles (113 RAMB36E2 + 2 RAMB18E2). The attribute is
  accepted silently and Vivado maps the table to block RAM anyway. It also costs
  timing that the plain `"block"` form does not: WNS +1.442 against +1.675,
  Fmax 281.057 against 300.752. **`"block"` strictly dominates `"ultra"` here**
  -- 72,073 LUT / 135 tiles / no timing loss against 72,164 / 114 / -6.5% Fmax.
  Do not spend another run on URAM for this structure.
- **Putting the 4.26 Mbit table in block RAM as a way to pay for the gain
  image.** MEASURED: it buys **10,524 LUT for 135 of 672 BRAM tiles and +32,580
  FF**. That is 78 LUT per tile. LUTDIET's flat-port conversion returned 49,039
  LUT per tile on the same device, 629x better, and that is the comparison that
  matters when deciding where the next BRAM tile goes.
- **Widening the read so the gain arrives faster.** Not retried, and the reason
  is structural: `rmsnorm_rs`'s `w_mant` is a flat `NN*16` combinational port,
  so the SELECTED gain has to be resident in 65,536 fabric flops however it got
  there. Narrowing that port is TRACK READCONV's file and the only route to
  removing the residency requirement. DERIVED from the port declaration, not
  measured.
- **Editing `nw_count` and quoting the result as the shipping cost.** Built as
  `sim/ooc_nwrom_bounded.py` -- `NW_N` from a generic instead of from the
  line-counting loop, nothing else changed -- and MEASURED at **103,081 LUT**,
  which is 20,484 MORE than the committed RTL at the same 65 entries with the
  same image (82,597). **Quote `nw_lf65`, which is the committed RTL.**
  And the probe is NOT the thing that is wrong, which is the uncomfortable part:
  at `NW_OPS = 2` it is **bit-identical to the committed loader on all eleven
  columns** (see 5.7), so the two are the same design and Vivado produced
  results 24.8% apart on them at 65. Treat any single LUT number for this block
  as carrying a spread of that order.

---

## 7. Measurement traps hit, including this track's own

### 7.1 Editing a shell script while a batch was running it destroyed the batch's sentinel

**MEASURED, 21:52, and it was mine.** `sim/ooc_nwrom_run.sh` was being executed
by batch 1 when this track edited it to add a field to the spec parser. **Bash
reads a script incrementally from a file offset**, so the running instance
resumed at a byte offset that no longer meant what it did, and died with

    sim/ooc_nwrom_run.sh: line 91: syntax error: unexpected end of file

The eight synthesis points had all completed and their artefacts were intact,
but the loop never reached `echo "NWROM_SYNTH_ALL_DONE"`. Two batches were
queued behind that sentinel and both sat waiting on a string that would never be
written. This is the same shape as the `pgrep -f` self-match already recorded in
`CLAUDE.md`: **the guard does not fail loudly, it just never fires.** Fixed by
running long batches from a SNAPSHOT of the script in the scratch tree
(`/mnt/storage/nwrom/run_snapshot.sh`), and by adding an `NWROM_REPO` override
so a snapshot outside the repo can still find `sim/`.

### 7.2 The snapshot's first version silently pointed at the wrong repo

The immediate fix for 7.1 -- copy the script to `/mnt/storage/nwrom/` -- broke
`REPO="$(cd "$(dirname "$0")/.." && pwd)"`, which then resolved to
`/mnt/storage`. All six points of batch 2 "ran" and finished in **three
seconds**:

    bash: /mnt/storage/sim/ooc_lutdiet_run.sh: No such file or directory
    == nw_bnd65 rc=127

The sentinel was printed, so a caller gating only on the sentinel would have
believed the batch. **Gate on the RESULT, not on the runner's own claim of
completion** -- which is why `ooc_lutdiet_run.sh`'s `LUTDIET_DONE` sentinel is
checked per point and the summariser prints a row for every tag with no CSV.

### 7.3 A collection script run mid-batch writes empty evidence files

`sim/ooc_nwrom_collect.sh` writes `errors_<tag>.txt` for any tag with no result
CSV. Run while `nw_bnd2` was still synthesising, it produced an EMPTY
`errors_nw_bnd2.txt`, which reads exactly like "this point failed with no
message". Re-collected after the last batch. A zero-byte evidence file is worse
than a missing one.

### 7.4 A rename that silently did nothing, in a script that aborts loudly on everything else

`sim/ooc_nwrom_bounded.py` aborts unless each of its two content anchors matches
EXACTLY ONCE -- and then does its entity rename with a bare `str.replace` on
`entity ooc_normadapt is`, unchecked. Chaining it onto the output of
`sim/ooc_nwrom_memvariant.py`, whose entity is already `ooc_nwrom_memura`, that
replace matched nothing, the script printed `BOUNDED OK`, and Vivado reported

    ERROR: [Synth 8-439] module 'ooc_nwrom_bndura' not found

two runs later. **The anchors that were checked were fine; the one substitution
that was not checked is the one that broke.** A guard you do not apply to every
substitution is a guard on the substitutions you happened to worry about. The
two affected points (`nw_bndura65`, `nw_bndblk65`) are redundant -- the memory
question is answered on the COMMITTED loader by `nw_lfblk65` and `nw_lfura65` --
so they were dropped rather than re-run.

### 7.5 The gate row that pins this feature cannot reach its failure

`sim/tb_llama_top_normw.vhd` sets `NORM_W_IMAGE => "llama_top_nw_b4_mean.hex"`,
and that file is **576 lines**: `--blocks 4` gives 9 norm ops and
`mk_shape_scaled` gives hidden = 64. The synthesis failure needs 65,536. So the
one row that exercises the feature is 462x too small to see it, and GHDL has no
loop limit in any case. **A row that pins a value is not a row that tests the
value's range** -- the project already has "files that PIN a value are not the
same as files you EDIT"; this is the same lesson in the other direction.

### 7.6 `-generic` with an empty string is not a documented Vivado form

The empty-image control passes NO `-generic` at all and relies on the entity's
`NORM_W_IMAGE : string := ""` default, rather than passing `NORM_W_IMAGE=`.
That is why `nw_empty`'s `gen` column is `""` and not `"NORM_W_IMAGE="`. Untested
here whether the latter works; it was avoided rather than measured.

### 7.7 Counting `vivado` processes still overstates concurrency

Already recorded by NORMADAPT and hit again: `ps -eo comm,rss` shows four to six
`vivado` entries during one run, most of them at 0 RSS, because the entry point
forks `SYNTH_DESIGN_PARENT` workers. The wait rule counts them and is therefore
conservative, which is the safe direction on a 31 GB box.

---

## 8. What was NOT verified

**Nothing here is placed or routed.** Every caveat in
`sim/ooc_compose_bcd.tcl`'s header stands: no inter-subsystem routing, no
placement, no shell, no cross-subsystem resource merging. An OOC synthesis sum
is not a routability result and a pblock is a floorplan constraint rather than a
device.

**This track ran NO simulation of the populated table, so NORMADAPT's blind spot
is restated, not closed.** `m_nidx_at_accept` survives because at `NW_N = 1`
there is one gain and the index cannot matter. This track set `NW_N = 65` in
SYNTHESIS only. **The gain-index sequencing (`nsel`, `nidx`, `novf`) remains
untested by any bench**, and it is now known to be untestable through
`tb_llama_top_normw` at anything near the real shape without also confronting
the elaboration limit. Closing it needs a simulation at `NW_N > 1` that compares
which gain each norm op actually used -- that is an equivalence question, not an
area question, and it is not answered here.

**The 32,943 is an area delta and not a correctness statement.** No output of
the populated adapter was compared against anything. The image itself is
unvalidated beyond `quantize_gain`'s own overflow assert passing (max |q| =
12,256 against the int16 rail at `NORM_W_EXP = 12`, so no clipping) and the
element count being an exact multiple of 4096.

**The loop-limit fix is verified to make synthesis SUCCEED, not to be correct.**
`maxLoopLimit 4000000` was measured to elaborate and to produce a design whose
WNS, DSP, CARRY8 and BRAM match the empty-image build exactly. Nothing here
checks that the table Vivado loaded holds the values the file holds. That is the
same class of gap as `m7 mutant`: a self-consistent build is not an oracle.

**`rtl/rmsnorm_rs.vhd` was neither read from the working tree nor edited**, and
its `ARG` row is 45.8% of the cost measured here. A `rmsnorm_rs` that changes
under TRACK READCONV changes that row and therefore changes this track's total,
in a direction this track cannot predict.

**`nw_bndura65` and `nw_bndblk65` FAILED on a generation mistake of this
track's own (7.4) and were dropped, and `nw_bnd17` / `nw_bnd33` had not
completed when this was written.** All four are secondary: the memory question
is answered on the COMMITTED loader by `nw_lfblk65` and `nw_lfura65`, and the
bounded probe's `NW_N` sweep would only extend a curve that section 5.7 shows to
be noise. `hw/fk33/results/nwrom_2026-08-29/SUMMARY.txt` is the unfiltered table
of every point attempted, failures included.

**No full gate was run and none was needed: this track changed no RTL.**
`git status -- rtl/` shows only `rtl/l2norm_rs.vhd`, which is TRACK READCONV's.
Every file this track added is new and matches `sim/ooc_nwrom_*`; no new
`sim/tb_*.vhd` was created, so no gate row was added.
