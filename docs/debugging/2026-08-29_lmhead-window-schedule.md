# The last refused subsystem A job: the LM head

**Date:** 2026-08-29
**Track:** LMHEAD
**Build under test:** FK33 `xcvu33p-fsvh2104-2L-e`, `ROWS_IF = 48`,
`AXI_DW = 256`, `NPORTS_W = 24`, `NPORTS_S = 3`, `MAXROWS_BFP = 17408`,
`MAXCOLS = 17408`. Model set
`/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/manifest.json` (Qwen3.5-9B,
250 packed tensors, `attn_qkv` segment-padded by `e28083f`).
**Tree:** `b65d9ad` plus this track's changes. No hardware was touched: no
`xsdb`, no `hw_server`, no `vivado ... program`, no `/dev/xdma*`.

---

## 1. The question, verbatim

> TRACK QKV-PAD just landed commit `e28083f` and took the refused A jobs of one
> token from **49 down to 1**. Verify that yourself, then close the survivor.
>
> ```
> step 489  output.weight   REFUSED: ERR_DESC: shape
> 296 of 297 A jobs emitted, 1 refused
> ```
>
> `output.weight` (the LM head) is M = 248,320 rows against K = 4096.
> `MAXROWS_BFP` is 17,408. **Your job is to make that job expressible and prove
> the result is right.**
>
> **Route 1: split into row windows.** ~15 BFP jobs at a 17,376-row stride
> [...] **Route 2: one raw job.** TRACK OUTMODE landed `0ff6828` today and
> established, from the RTL, that `out_mode = "01"` (raw) has an **unbounded**
> `n_rows` [...] So the whole LM head might be ONE job. [...] **OUTMODE also
> flagged as NOT verified whether any real lm_head descriptor actually reaches
> `n_rows > MAXROWS_BFP` -- you are the track that finds out.**
>
> QKV-PAD flagged that this needs "a destination region nobody has decided".
> [...] D-PROG established a byte-identity of the D table against two VHDL
> generators, and adding ~15 steps takes the token from 491 to 505 steps.
> **Measure whether your change breaks that byte-identity.**

---

## 2. The answer, up front

**Route 2 is not available and it is not a close call.** `out_mode = "01"` has
an unbounded `n_rows` in `rtl/matvec_core.vhd:947`, exactly as OUTMODE found, but
**nothing reaches `matvec_core` except through `rtl/matvec_int4_desc_axi.vhd`,
whose `S_CHECK` bounds `n_rows` against `MAXROWS_BFP` in EVERY mode** and must,
because `sh_rows` is declared `integer range 0 to MAXROWS_BFP`. MEASURED with
the RTL itself as judge: a 248,320-row descriptor is refused
`err_code 0x3 err_info 1` in raw and in BFP alike. So OUTMODE's open question
is answered **NO** -- no real lm_head descriptor can reach
`n_rows > MAXROWS_BFP`, because the descriptor plane refuses it first. Route 2
is an RTL change, not a schedule choice.

**Route 1 is taken, in RAW mode, at 15 windows of stride 17,376.** Raw is
load-bearing rather than inherited: raw's `y_exp = w_exp + x_exp - out_shift`
has no per-job term, so all 15 windows report ONE exponent and their s32
payloads are directly comparable; BFP's `ns` is a max over the job's rows, so
15 BFP windows carry 15 different exponents into `rtl/sampler_stream.vhd`,
whose only input is a bare 32-bit integer.

**`311 of 311 A jobs emitted, 0 refused.`** (Not "297 of 297": the lm_head is
now 15 steps instead of 1, so the token's A-job count is 296 + 15 = 311.)

**Numerically: 248,320 of 248,320 logits bit-identical** to a single
whole-tensor job computed by `ref/matvec_int4.c`, over three activation
vectors, with all 15 windows reporting `y_exp = 5`. 9 of 10 mutations of the
emitted descriptors are killed; the tenth is named below and no value-level
check can ever kill it.

**No destination region is needed and the memory map does not move.** The
lm_head step has carried `dst = R_NONE` with `FLG_TO_SMP` since the schedule
was written; the result is a STREAM to the sampler, not a region write, and all
15 windows carry the same encoding. QKV-PAD's flag does not apply. What IS
open is the `clr` pulse and the sampler instantiation, which is an integration
gap `rtl/llama_top.vhd:133` already states in its own banner.

**The D-table byte-identity survives where it is executed and breaks where it
is not.** MEASURED against the VHDL generators directly, not against the
tool's own previous output: all 10 scaled shapes -- including the 491-step
`blocks=32` one that `sim/tb_llama_top` actually runs -- are byte-identical
table AND release mask, unchanged, because `vocab_shard = 128` is one window.
`sim/seq_tbl_pkg.build_table` (real 9B, 491 steps, 3928 words) now differs:
the correct program is 505 steps / 4040 words. That is a defect in the two
VHDL generators, which encode a job the gateware refuses, and the tool keeps
`--one-lmhead-job` so the comparison stays reproducible.

---

## 3. The procedure, in the order it was run

Each step names what it isolates.

1. **Reproduce the refusal.** `gen_layer_program.py --token --print` on the
   qkvpad manifest. Isolates: is the reported state still the state.
2. **Read the two `MAXROWS_BFP` checks.** `rtl/matvec_core.vhd:947` (gated on
   `out_mode = "00"`) against `rtl/matvec_int4_desc_axi.vhd:721-726` (not
   gated) and the `sh_rows` declaration at `:309`. Isolates: which of the two
   is on the path a descriptor takes. This is the whole route decision and it
   is a source question, not a measurement.
3. **Make the RTL judge it.** `sim/tb_mv4i_desc_image`, unmodified, on three
   hand-built descriptors: whole-tensor raw, whole-tensor BFP, and window 0.
   Isolates: prediction versus entity. `tools/gen_mv4i_desc.rtl_would_reject`
   is a re-statement of `S_CHECK` in Python and would agree with a wrong
   reading of it just as happily.
4. **Read the consumer.** `rtl/sampler_stream.vhd` ports, and
   `rtl/llama_map_pkg.vhd`'s region table. Isolates: raw versus BFP, and
   whether a destination region is required.
5. **Emit the windows from the SHIPPING schedule**, by calling
   `gen_lmhead_windows.plan` from `gen_layer_program.build_plan` rather than
   re-deriving the stride. Isolates: one place for the arithmetic to be wrong.
6. **Put the emitted bytes back through the RTL.** All 15 window descriptors
   through `sim/tb_mv4i_desc_image` with `EXPECT=-1`. Isolates: the generator
   changed and the gateware still accepts.
7. **Compute the logits.** `tools/lmhead_window_oracle.c` +
   `tools/lmhead_window_check.py`: one whole-tensor `mv4i_matvec` over all
   248,320 rows, then one per window with the 27 sub-region offsets taken
   verbatim out of the emitted DESCRIPTOR's base words, compared row by row.
   Isolates: the numbers, and specifically the base arithmetic that the byte
   cover cannot see.
8. **Run the same thing in BFP mode.** Isolates: whether the raw choice is
   real. It is: 832 of 1024 mantissas move and 5 of 6 windows report a
   different exponent.
9. **Mutate the descriptors.** Ten single-field edits. Isolates: the check's
   resolution floor.
10. **Dump the two VHDL generators and diff.** A scratch `dump_tables` entity
    in the scratchpad, never in the repository. Isolates: byte-identity
    against the generators themselves, not against yesterday's tool output.
11. **Full unfiltered gate.** MEASURED, `sim/regress.sh` with no filter:

    ```
     suite sim   PASS 57   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
     suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
     OVERALL     PASS 83   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
     baseline: 83 passing, matches the recorded floor of 83
     REGRESSION: PASS
    ```

    No gate row was added and `BASELINE_PASS` was not touched by this track;
    the floor read 82 when the run started and 83 when it finished, because
    another track raised it and `regress.sh` re-execs a private copy of
    itself at startup. Two other tracks' gates ran concurrently on the same
    box throughout, which is why the run took 20 minutes.

---

## 4. The evidence, as captured output

### 4.1 The refusal, reproduced (MEASURED, `tools/gen_layer_program.py` at `b65d9ad`)

```
step 489  output.weight                REFUSED: ERR_DESC: shape
  296 of 297 A jobs emitted, 1 refused
```

### 4.2 The two checks are not the same check (source, `b65d9ad`)

`rtl/matvec_core.vhd:945-947` (`S_IDLE`) -- gated:

```vhdl
              if n_rows <= 0 or n_cols <= 0 or n_cols > MAXCOLS
                 or out_shift < 0 or out_shift > 40
                 or (out_mode = "00" and n_rows > MAXROWS_BFP) then
```

`rtl/matvec_int4_desc_axi.vhd:721-726` -- NOT gated, and one `elsif` arm of
the same `S_CHECK` chain that has already tested `out_mode` two arms earlier:

```vhdl
            elsif unsigned(lo32(dw(1))) = 0
               or unsigned(lo32(dw(1))) > MAXROWS_BFP
               or unsigned(hi32(dw(1))) = 0
               or unsigned(hi32(dw(1))) > MAXCOLS then
              err_code <= EC_DESC;                     -- shape
              err_info <= std_logic_vector(to_unsigned(1, 16));
```

and it cannot be relaxed in place, because `:309` is

```vhdl
  signal sh_rows : integer range 0 to MAXROWS_BFP := 0;
```

and `:752` does `sh_rows <= to_integer(unsigned(lo32(dw(1))))` under the
comment "to_integer on a 32-bit field is only ever evaluated on a value the
range check has already passed".

### 4.3 The RTL as judge (MEASURED, `sim/tb_mv4i_desc_image`, unmodified)

`ghdl -r --std=08 -frelaxed tb_mv4i_desc_image -gDESC=... -gEXPECT=... -gEXPECT_INFO=...`

```
--- DESC=whole_raw.txt EXPECT=3 EXPECT_INFO=1        (n_rows=248320, out_mode="01")
sim/tb_mv4i_desc_image.vhd:316:5:@1ns:(report note): loaded 39 descriptor words from whole_raw.txt
sim/tb_mv4i_desc_image.vhd:365:7:@685ns:(report note): RESULT reject: err_code 0x3 err_info 1
sim/tb_mv4i_desc_image.vhd:371:7:@685ns:(report note): PASS: descriptor image judged as expected (3)
GHDL_EXIT=0

--- DESC=whole_bfp.txt EXPECT=3 EXPECT_INFO=1        (n_rows=248320, out_mode="00")
sim/tb_mv4i_desc_image.vhd:365:7:@685ns:(report note): RESULT reject: err_code 0x3 err_info 1
sim/tb_mv4i_desc_image.vhd:371:7:@685ns:(report note): PASS: descriptor image judged as expected (3)
GHDL_EXIT=0

--- DESC=win0_raw.txt EXPECT=-1 EXPECT_INFO=-1       (n_rows=17376,  out_mode="01")
sim/tb_mv4i_desc_image.vhd:363:7:@4525ns:(report note): RESULT accept: S_CHECK passed and the core started
sim/tb_mv4i_desc_image.vhd:371:7:@4525ns:(report note): PASS: descriptor image judged as expected (-1)
GHDL_EXIT=0
```

**This is the answer to OUTMODE's open question.** Raw mode's unbounded
`n_rows` in `matvec_core` is real and unreachable from a descriptor. The two
whole-tensor refusals are identical, so the mode does not enter.

### 4.4 The 15 emitted window descriptors, judged by the same entity (MEASURED)

```
a489_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a490_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a491_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a492_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a493_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a494_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a495_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a496_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a497_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a498_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a499_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a500_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a501_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a502_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
a503_output.weight.hex  RESULT accept: S_CHECK passed and the core started  PASS (-1)
15 of 15 lm_head window descriptors ACCEPTED by rtl/matvec_int4_desc_axi
```

This also closes item 2 of `docs/2026-08-28_token-io-path.md` section 10:
"The 15 descriptors were never executed by the RTL."

### 4.5 The job count (MEASURED)

```
token     505 steps (24 GDN x 16, 8 attn x 13, +2, +15 lm_head windows)
...
  step 489  output.weight                rows 0..17375 of 248320  w_exp=8 out_shift=3 w_beats=46336 s_beats=46336  @0x1FFFFE000
  step 490  output.weight                rows 17376..34751 of 248320  ...
  ...
  step 502  output.weight                rows 225888..243263 of 248320  w_exp=8 out_shift=3 w_beats=46336 s_beats=46336  @0x1FFFFFA00
  step 503  output.weight                rows 243264..248319 of 248320  w_exp=8 out_shift=3 w_beats=13568 s_beats=13568  @0x1FFFFFC00
  311 of 311 A jobs emitted, 0 refused
```

The stride is confirmed rather than trusted: `17408 // 48 * 48 = 17376`,
`14 * 17376 + 5056 = 248320`, which is `706a2a4`'s number.

### 4.6 The logits (MEASURED, `tools/lmhead_window_check.py`)

Real `output.weight.mv4i`, 572,207,104 bytes, at the production
`MAXROWS_BFP = 17408`. 7.6 s wall.

```
tensor    /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/output.weight.mv4i
geometry  M=248320 K=4096 ROWS_IF=48 AXI_DW=256 nports_w=24 n_scale_sub=3
windows   MAXROWS_BFP=17408 stride=17376 -> 15 windows
mode      raw (1)   x_exp=0

all 15 descriptors pass rtl_would_reject at MAXROWS_BFP=17408
GEOM rows_if=48 axi_dw=256 nports_w=24 n_scale_sub=3 grp=1 nb=128
DIMS M=248320 K=4096 w_exp=8 out_shift=3 x_exp=0 mode=1
WHOLE rows=248320 y_exp=5 ns=0 sat=0 fnv1a=6E35566FD54EAD81
WIN 0  rows       0..  17375  y_exp=5    ns=0   sat=0  mismatch=0
WIN 1  rows   17376..  34751  y_exp=5    ns=0   sat=0  mismatch=0
WIN 2  rows   34752..  52127  y_exp=5    ns=0   sat=0  mismatch=0
WIN 3  rows   52128..  69503  y_exp=5    ns=0   sat=0  mismatch=0
WIN 4  rows   69504..  86879  y_exp=5    ns=0   sat=0  mismatch=0
WIN 5  rows   86880.. 104255  y_exp=5    ns=0   sat=0  mismatch=0
WIN 6  rows  104256.. 121631  y_exp=5    ns=0   sat=0  mismatch=0
WIN 7  rows  121632.. 139007  y_exp=5    ns=0   sat=0  mismatch=0
WIN 8  rows  139008.. 156383  y_exp=5    ns=0   sat=0  mismatch=0
WIN 9  rows  156384.. 173759  y_exp=5    ns=0   sat=0  mismatch=0
WIN 10 rows  173760.. 191135  y_exp=5    ns=0   sat=0  mismatch=0
WIN 11 rows  191136.. 208511  y_exp=5    ns=0   sat=0  mismatch=0
WIN 12 rows  208512.. 225887  y_exp=5    ns=0   sat=0  mismatch=0
WIN 13 rows  225888.. 243263  y_exp=5    ns=0   sat=0  mismatch=0
WIN 14 rows  243264.. 248319  y_exp=5    ns=0   sat=0  mismatch=0
TOTAL windows=15 rows=248320 mismatch=0 exp_mismatch=0
VERDICT PASS
```

Three activation vectors (`--seeds 3`), three different whole-tensor
checksums, all PASS -- so the comparison is data-dependent and not vacuous:

```
WHOLE rows=248320 y_exp=5 ns=0 sat=0 fnv1a=6E35566FD54EAD81   TOTAL mismatch=0  VERDICT PASS
WHOLE rows=248320 y_exp=5 ns=0 sat=0 fnv1a=B2FDCE35EAFF4BD3   TOTAL mismatch=0  VERDICT PASS
WHOLE rows=248320 y_exp=5 ns=0 sat=0 fnv1a=05BB79A76EF1C05D   TOTAL mismatch=0  VERDICT PASS
```

**Why a whole-tensor run is a legitimate oracle for a set of windows, and only
in raw mode.** `ref/matvec_int4.c:396` is
`y_data[r] = sat32(round_shift(acc_r, out_shift))` and `:436` is
`out->y_exp = f->h.w_exp + x_exp - f->h.out_shift`. Neither expression reads
any row but `r`, so raw mode has no cross-row term and slicing the row range
cannot change a value. That is the condition the task asked to be checked, and
it holds by inspection of the two lines plus the measurement above.

### 4.7 BFP mode fails the same check, and that is the route decision (MEASURED)

Same tensor family, `blk.11.attn_k.weight.mv4i` (M = 1024) with
`--maxrows-bfp 200` to force 6 windows, `--mode bfp`:

```
DIMS M=1024 K=4096 w_exp=8 out_shift=3 x_exp=0 mode=0
WHOLE rows=1024 y_exp=0 ns=5 sat=0 fnv1a=E2C93D6D7CA4FCFA
WIN 0  rows       0..    191  y_exp=0    ns=5   sat=0  mismatch=0
WIN 1  rows     192..    383  y_exp=1    ns=4   sat=0  mismatch=192  first row 192 got -15254 want -7627
WIN 2  rows     384..    575  y_exp=1    ns=4   sat=0  mismatch=192  first row 384 got -28334 want -14167
WIN 3  rows     576..    767  y_exp=1    ns=4   sat=0  mismatch=192  first row 576 got 7717 want 3858
WIN 4  rows     768..    959  y_exp=1    ns=4   sat=0  mismatch=192  first row 768 got -7843 want -3922
WIN 5  rows     960..   1023  y_exp=1    ns=4   sat=0  mismatch=64  first row 960 got -2980 want -1490
TOTAL windows=6 rows=1024 mismatch=832 exp_mismatch=5
VERDICT FAIL
```

832 of 1024 mantissas move and 5 of 6 windows report a different exponent.
Window 0 matches only because it happens to contain the global maximum, so its
`ns` coincides with the whole-tensor `ns`. Every `got` is exactly `2 x want`,
which is `ns` one lower and `y_exp` one higher -- the windowed values are not
WRONG, they are on a different grid, and a consumer that ignores `y_exp` reads
them as wrong. `rtl/sampler_stream.vhd`'s only data input is
`in_v : in std_logic_vector(31 downto 0)`; it has no exponent port and no
rescale.

### 4.8 The mutation table (MEASURED, on the real 248,320-row tensor)

Every mutation edits ONE field of ONE emitted descriptor -- a base word, a
`n_rows`, or the issue order -- and the check must fail.

| mutation | verdict | how it is killed, and why it was tried |
|---|---|---|
| m1 window 1 bases one TILE high | KILL | 17,376 of 248,320 values wrong. The OI-3 family: a well-formed base at the wrong bytes, which the byte cover structurally cannot see |
| m2 `MAXROWS_BFP` rounded UP to a tile | KILL | **by an ABORT, not a mismatch**: `ref/matvec_int4.c:360: mv4i_matvec: Assertion 'sc <= 32767' failed` -- the misaimed scale base reads bytes that are not a scale. `gen_lmhead_windows`' own header names this as the form that "is not loud at all"; against the reference it is loud, against the gateware it would not be |
| m3 windows 1 and 2 bases swapped | KILL | 34,752 values wrong. Row cover still exact, byte cover still exact, values transposed |
| m4 ONE weight sub-region (7) misaimed | KILL | **724 of 248,320 values wrong, 0.29%**, all inside window 0. OI-1 case 19 at lm_head scale: sub-region 7 carries one bit slice of the tile word, so only some rows of some tiles move |
| m5 ONE scale sub-region (1) misaimed | KILL | 5,792 values wrong. The scale plane has its own bases and its own skip arithmetic (`s_skip`, a different expression from `w_skip`) |
| m6 last window rounded up one tile | KILL | 16 values wrong AND a row total of 248,368 against M = 248,320. The 5,056-row remainder read as 5,104 |
| m7 window 0 short by one tile | KILL | **`mismatch=0`, `rows=248272`.** Killed by the ROW-COUNT arm of the verdict alone; 48 rows are simply never computed and a value-only check would score it PASS. Recorded because it is the one case where the coverage arm is load-bearing |
| m8 weight sub-regions 0 and 1 swapped | KILL | 20,696 values wrong. A permuted base ARRAY; `check_bases` only ever sees a permutation inside the file's own header table, never in the descriptor |
| m9 window 1 bases one BEAT high | KILL | 17,376 values wrong. The smallest base error expressible: 32 bytes, sub-tile |
| **m10 windows issued DESCENDING** | **PASS** | **NON-BITER BY CONSTRUCTION.** `TOTAL windows=15 rows=248320 mismatch=0`. Every window carries its own `row_start`, so the comparison is order-independent and no value check can ever see the issue order. It is a SAMPLER INDEX property: `sampler_stream`'s `idx` counts from `clr`, so descending order gives every logit the wrong index. `706a2a4` measured this directly on `rtl/sampler_stream.vhd` under GHDL (8 of 8 cases fail when the order or the `clr` discipline is violated). This bench's floor, permanently |

**9 of 10 killed.** m10 is the resolution floor and it is structural, not a
gap that more cases would close.

Two further non-biters worth recording because they were considered and
rejected as mutations rather than measured:

* **`ordinal`.** All 15 windows carry `ordinal = 0`. Nothing in
  `matvec_int4_desc_axi` reads it on an A job and nothing in `seq_opdec`
  distinguishes A steps by it, so any value would pass. It is left at 0 rather
  than set to the window index, because a window index is not what `ordinal`
  means anywhere else in the format.
* **`dst_offset`.** All 15 carry 0. `seq_opdec` infers an exponent SEGMENT
  from `dst_offset`, and with `dst = R_NONE` there is no region and no segment,
  so no value is observable. Setting it to `row_start` would look more
  informative and mean nothing.

### 4.9 The D table byte-identity, against the VHDL generators themselves (MEASURED)

Dumped with a scratch `dump_tables` entity written into the session
scratchpad, analysed into a private GHDL workdir against
`rtl/model_cfg_pkg.vhd`, `rtl/util_pkg.vhd`, `rtl/llama_map_pkg.vhd`,
`sim/seq_tbl_pkg.vhd`, `sim/llama_sched_pkg.vhd`. **No repository file was
touched and nothing was added to `sim/`.**

`sim/llama_sched_pkg.build_table` + `build_plan` release mask, the generator
`sim/tb_llama_top` actually executes, with the windowing ON by default:

```
blocks=1  attn_int=4 hd=32  steps=19   table_diff=0  rel_diff=0
blocks=2  attn_int=4 hd=32  steps=35   table_diff=0  rel_diff=0
blocks=4  attn_int=4 hd=32  steps=64   table_diff=0  rel_diff=0
blocks=8  attn_int=4 hd=32  steps=125  table_diff=0  rel_diff=0
blocks=16 attn_int=4 hd=32  steps=247  table_diff=0  rel_diff=0
blocks=32 attn_int=4 hd=32  steps=491  table_diff=0  rel_diff=0
blocks=4  attn_int=4 hd=16  steps=64   table_diff=0  rel_diff=0
blocks=32 attn_int=4 hd=16  steps=491  table_diff=0  rel_diff=0
blocks=8  attn_int=2 hd=32  steps=119  table_diff=0  rel_diff=0
blocks=9  attn_int=3 hd=32  steps=138  table_diff=0  rel_diff=0
```

**Unchanged, all ten, table and release mask.** The reason is arithmetic, not
luck: `mk_shape_scaled` sets `vocab_shard = 128`, one stride is 17,376, so
`plan(128, 48, 17408)` returns exactly one window at row 0 and the emitted
step sequence is bit-for-bit what it was.

`sim/seq_tbl_pkg.build_table` (real 9B dimensions):

```
dump_tables.vhd:52:7:@0ms:(report note): seq_tbl_pkg: 491 steps, 3928 words

--one-lmhead-job : BYTE IDENTICAL to seq_tbl_pkg.build_table
windowed (default): DIFFERS -- 4040 words vs 3928; first differing line 3914
```

`cmp` says `differ: byte 66533, line 3914`. Line 3914 is word 3913, and
`3913 = 489*8 + 1` -- step 489, word 1, the `n_rows | n_cols` word of the
lm_head step:

```
seq_tbl_pkg   000010000003CA00     n_cols = 0x1000 = 4096,  n_rows = 0x3CA00 = 248320
windowed      00001000000043E0     n_cols = 0x1000 = 4096,  n_rows = 0x43E0  = 17376
```

So the divergence is exactly and only the lm_head, and it starts at the first
field that carries the row count. Everything before word 3913 -- all 489
preceding steps, 3,913 words -- is identical.

**This is a defect in the two VHDL generators, not in the schedule.**
`seq_tbl_pkg` encodes a single 248,320-row lm_head job, and section 4.3 above
is the gateware refusing precisely that descriptor. `seq_tbl_pkg`'s 491
descriptors have never been executed by anything (its own header says a real
run is "tens of millions of element-cycles, which GHDL will not finish inside
a working day"), which is why the defect has been invisible. Fixing it is an
edit to `sim/seq_tbl_pkg.vhd`, a file this track does not own.

### 4.10 The cost of the route, stated

| | Route 1, raw, 15 windows (TAKEN) | Route 1, BFP, 15 windows | Route 2, one raw job |
|---|---|---|---|
| expressible on the FK33 build | **yes** (MEASURED, 4.4) | yes | **NO** (MEASURED, 4.3) |
| D steps in the token | 505 (+14, +2.85%) | 505 | 491 |
| A descriptors | 15 x 312 B = 4,680 B | 4,680 B | 312 B |
| weight bytes read | 572,203,008 B. DERIVED identical: `14 x tiles(17376) + tiles(5056) = 14 x 362 + 106 = 5174 = tiles(248320)`, so the windows read each tile exactly once | identical | identical |
| result bytes to the consumer | 248,320 x 4 = **993,280 B** | 248,320 x 2 = 496,640 B + 15 exponents | 993,280 B |
| exponents | **one** (MEASURED: `y_exp = 5` on all 15) | 15, different (MEASURED, 4.7) | one |
| consumer works today | `sampler_stream` takes s32 with no exponent port | **no**: needs a per-window rescale nothing implements | would |
| destination region | none: `R_NONE` + `FLG_TO_SMP` | none | none |

The +14 steps cost 14 extra descriptor fetches (312 B each) and 14 extra
job start/drain latencies. The 4,368 extra descriptor bytes are 0.00076% of
the 572 MB of weight traffic the lm_head reads either way. **The per-job
start/drain latency was NOT measured** -- it needs a cycle-level run of
`matvec_int4_desc_axi` with a real slave, which no bench in the tree does.

### 4.11 The destination region: not a decision (source)

`rtl/llama_map_pkg.vhd:80-87` declares 14 regions, `R_X` through `R_ER`, and
`R_NONE = 255`. There is no logits region and none is needed: the lm_head step
has carried `dst = R_NONE` with `flags = FLG_TO_SMP` since the schedule was
first written, and `rtl/llama_top.vhd:133` states the consequence in its own
banner --

> There is no sampler and no lm_head output. The final A job is issued with
> dst = R_NONE and its result is discarded.

All 15 windows carry the identical encoding, so windowing adds nothing to
decide. QKV-PAD's "a destination region nobody has decided" does not apply to
this job. **`rtl/llama_map_pkg.vhd` was read and not edited** (TOP-KV owns it
and has uncommitted work in it).

---

## 5. Measured and REJECTED -- do not retry

1. **Route 2, one raw job over all 248,320 rows.** MEASURED refused by
   `matvec_int4_desc_axi` with `err_code 0x3 err_info 1`, identically in raw
   and BFP (4.3). Do not re-derive this from `matvec_core.vhd:947`: that check
   IS gated on `out_mode = "00"` and OUTMODE read it correctly, but it is one
   level below the only path a descriptor takes. **The RTL wins over the spec
   here**: spec 7.6 permits `M > MAXROWS_BFP` in raw, and the descriptor plane
   does not implement that permission. On the FK33 the permission is therefore
   unreachable, whatever the document says.

2. **Relaxing the descriptor-plane check as a one-line edit.** Rejected on
   reading: `sh_rows` is `integer range 0 to MAXROWS_BFP` (`:309`) and
   `sh_racc`/`sh_t` accumulate against `TILES`, so widening the check without
   widening those declarations converts a clean `ERR_DESC` into a bound
   violation. It is a real RTL change with its own verification, and this
   track does not own that file.

3. **BFP windows.** MEASURED to disagree with the whole-tensor result on 832
   of 1024 rows with 5 of 6 exponents differing (4.7). The values are not
   wrong, they are on 6 different grids, and the sampler has no exponent
   input. Do not "fix" this by comparing mantissas with a tolerance -- the
   discrepancy is exactly `2^(y_exp difference)` and a tolerance would hide a
   real grid mismatch.

4. **`ref/matvec_int4.c --emit` as the source of a synthetic test tensor.**
   MEASURED rejected by `gen_mv4i_desc.check_bases`:

   ```
   the file's offset table and spec 6.5a's layout DISAGREE.
     header w=[4096, 8192, 12288, 16384, ...]
     layout w=[4096, 6784, 9472, 12160, ...]
   ```

   `pack_geom` (`ref/matvec_int4.c:474-480`) 4 KB-aligns every sub-region via
   `align4k`; `gen_mv4i_desc.sub_offsets_from_layout` encodes the TIGHT layout
   as "the offsets spec 6.5a's layout implies". Both are legal -- the file
   names its own offsets and the reference reads them -- but the Python refuses
   any C-packed file. Real `tools/pack_int4.py` tensors were used instead. See
   the open list: this is a finding about the two packers, not about this
   track.

5. **Stride = `MAXROWS_BFP` = 17,408.** Not retried, because `706a2a4`
   already measured `build_descriptor` refusing it outright (17,408 is not a
   multiple of 48), and this track re-derived the number rather than trusting
   it: `17408 // 48 * 48 = 17376`, `14 * 17376 + 5056 = 248320`. The dangerous
   variant -- rounding UP to 17,424 without re-deriving the count -- is
   mutation m2 and it is killed.

---

## 6. Measurement traps hit, including my own

1. **I nearly took OUTMODE's finding at face value.** "Raw has an unbounded
   `n_rows`, spec 7.6 says M may exceed `MAXROWS_BFP`" is true of the unit they
   were working in and false of the system. The trap is that both statements
   are about `MAXROWS_BFP` and `out_mode` and read as the same statement. What
   caught it was `docs/2026-08-28_token-io-path.md`'s own contradiction list,
   which had already recorded the same asymmetry in the other direction:
   `llama_top:737-741` claims `MAXROWS_BFP` is "checked only in BFP mode",
   which is true of `matvec_core`'s `S_IDLE` and FALSE of
   `matvec_int4_desc_axi`'s `S_CHECK` (the line numbers in that note are from
   `706a2a4` and have since moved; the code has not). **A per-unit property is
   not a system property**, and a check one level up can be strictly stronger.

2. **My first m2 was a no-op and reported PASS.** It advanced each window's
   bases by `(MAXROWS_BFP - floor_stride) // ROWS_IF` tiles, which is
   `32 // 48 = 0` at the production geometry and `8 // 48 = 0` at the reduced
   one. It scored as a non-biter and I nearly wrote it up as the resolution
   floor. The mutation was wrong, not the check. **A mutation that does not
   bite must be shown to have CHANGED SOMETHING before it can be called a
   floor** -- the fix was to express it as the round-UP form, which moves one
   whole tile per window, and it kills immediately.

3. **`ghdl -r` on a `--keep`'d regress workdir needs the same flags regress
   used.** Without `--std=08 -frelaxed` mcode says `cannot find entity or
   configuration tb_mv4i_desc_image`, which reads as a missing build rather
   than a language-standard mismatch. `sim/regress.sh:983` is the reference
   invocation.

4. **`use work.llama_map_pkg.all` plus `use work.seq_tbl_pkg.all` conflicts.**
   Both re-export `OP_END_TOKEN` and `NREGION`, and GHDL says
   `no declaration for "op_end_token" (due to conflicts)` -- which reads as a
   missing declaration, not an ambiguity. The fix is the selected name
   `work.llama_map_pkg.OP_END_TOKEN`.

5. **The comparison against "yesterday's tool output" would have been weaker
   than it looked.** Diffing the new tool against HEAD's tool and citing
   D-PROG's claim that HEAD matched the VHDL is a transitive argument through a
   document. The VHDL generators were dumped and diffed directly (4.9), which
   is why the 491-vs-505 divergence can be attributed to `seq_tbl_pkg` rather
   than to a drift in either tool.

6. **The whole-tensor `sat_event`/`sat_count` are per-JOB aggregates, not
   per-row.** `ref/matvec_int4.c` accumulates them in file-scope globals across
   the row loop, so 15 windows report 15 flags where one job reports one. The
   oracle deliberately does not compare them; every run read 0 here, so the
   distinction never bit, but a saturating model would make the comparison look
   like a mismatch when it is a difference in aggregation granularity.

---

## 7. NOT verified -- the explicit list

1. **No hardware.** Nothing in this file ran on the FK33.
2. **The RTL was never made to COMPUTE a windowed lm_head.**
   `sim/tb_mv4i_desc_image`'s 27 slaves never assert `arready`, so an accepted
   descriptor proves `S_CHECK` passed and `start` pulsed, and nothing about
   arithmetic. The 248,320 bit-exact logits are `ref/matvec_int4.c` judging the
   DESCRIPTOR, not the gateware. Closing this needs a data-serving bench at the
   lm_head's beat counts -- 46,336 beats per sub-region per window across 27
   masters -- and no bench in the tree serves data at that volume. How far
   that is beyond what the existing benches drive was NOT measured.
3. **The activation vector is one deterministic LCG sequence per seed**, three
   seeds. A defect that needs a particular x pattern is out of reach, and in
   particular `sat_event` was 0 in every run, so the **saturating** corner of
   raw mode is untested at lm_head scale.
4. **`x_exp` was 0 throughout.** It enters raw's `y_exp` additively and nothing
   else, so it cannot change the window/whole comparison, but it was not swept.
5. **The per-job start/drain latency of 14 extra jobs was not measured** (4.10).
   The step-count and byte figures are DERIVED; the time cost is not stated.
6. **The `clr` pulse has no descriptor field and no owner.** `706a2a4`
   measured that 15 windows share one running argmax provided `clr` is pulsed
   once per token and the windows are issued ascending. This track emits them
   ascending. Nothing in the descriptor format expresses the `clr`, no unit in
   `llama_top` instantiates `sampler_stream`, and `rtl/llama_top.vhd:133` says
   so. **Not a memory-map decision, an integration gap.**
7. **The 32 pad rows of the last window** (5,056 rows = 106 tiles = 5,088 row
   slots) were not shown to produce no logit. `n_rows` bounds the emit and the
   whole-tensor comparison covers exactly 248,320 rows, but that is the
   reference's behaviour, not the RTL's. Same open item as
   `docs/2026-08-28_token-io-path.md` section 10 item 9.
8. **`token_embd.weight` was not re-checked here.** It is the same shape and
   `706a2a4` covered its window set; only `output.weight` is on this token's
   critical path.
9. **The two packers' sub-region alignment disagreement** (section 5 item 4) is
   recorded, not resolved. Nobody has decided which layout spec 6.5a means, and
   `check_bases` currently makes that decision by refusing one of them.
10. **`--qkv-fused` is incompatible with the SEGMENT-PADDED manifest, and was
    before this track.** MEASURED on `qwen35-9b-mv4i-qkvpad`: at `b65d9ad`
    it emits `224 of 249 A jobs, 25 refused`; with the windowing it emits
    `239 of 263, 24 refused`. The delta is exactly +14 emitted and -1 refused,
    i.e. the lm_head, so the 24 survivors are untouched. They are the fused
    qkv job asking for `row_start = 0, n_rows = 8192` against a manifest whose
    `attn_qkv` declares padded segments and `M = 8224`; the segment lookup
    finds no match and the tool says so. `--qkv-fused` is the pre-`e28083f`
    fallback and the padded set is what replaced it, so this is expected --
    recorded because the count moved and someone will diff it.

11. **`tools/gen_layer_program.mk_shape_scaled` and
    `rtl/llama_map_pkg.mk_shape_scaled` have diverged at `attn_hd > 32`.**
    TOP-KV added an `attn_hd = 64` branch to the VHDL in the working tree
    (uncommitted at the time of writing); the Python has no such branch. The
    ten shapes measured in 4.9 all use `attn_hd` 16 or 32 and are unaffected.
    Reported, not fixed: it is that track's landing.

---

## 8. Corrections

None yet. A later finding that overturns anything above should be appended
here with a date, and the superseded claim marked withdrawn in place rather
than deleted.
