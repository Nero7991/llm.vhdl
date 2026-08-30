# Get the norm gain image out of LUT fabric. Is the one-line initialiser fix real, and is URAM or HBM the right home?

**Date:** 2026-08-30
**Track:** NORMURAM
**Baseline, pinned as its own step:** `SHA=$(git rev-parse HEAD)` returned
`0b4c7b2abd64706b67d416342f2bfdb190b834e2`; HEAD had already moved from the
`9e3348e` this track read at start-up. Everything synthesised comes from
`git archive 0b4c7b2 rtl`, at `/mnt/storage/normuram/pin/rtl`, md5 of
`llama_top.vhd` `25948360cb01365aabf14213e18b1dc1`. **The working tree was NOT
used for any area number** and the reason is in section 9.1: another track had
foreign uncommitted hunks in the same file.
**Tools:** GHDL 1.0.0 (mcode) for every value result. Vivado 2023.2 for every
area number, through TRACK LUTDIET's `sim/ooc_lutdiet_run.sh` and
`sim/ooc_lutdiet_ports.tcl` **unmodified**, `xcvu33p-fsvh2104-2L-e`, 5.0 ns,
`-mode out_of_context -flatten_hierarchy none`, `LUTDIET_NOOPT=1`,
`LUTDIET_CENSUS=1`, no `maxLoopLimit` anywhere.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `program_hw_devices`,
nothing under `hw/fk33/host` or `hw/fk33/tcl`, nothing opening `/dev/xdma*`.
**Image:** `/mnt/storage/nwfix/img/norm_w_9b.hex`, md5
`69f614a1515e1160f5dc9e8a9e72fdc3` -- byte-for-byte the file TRACK NWFIX
measured on, so the before-side and the after-side are on the same numbers.
**Artefacts:** `/mnt/storage/normuram/`

---

## 1. The question, verbatim

> Get the norm gain image out of LUT fabric. **PICK WITH EVIDENCE** between:
>
> **(a) The one-line candidate nobody has drawn even once.** TRACK SCATTER
> section 11 records Vivado's own `Synth 8-6040` warning: the table fails
> BRAM/URAM inference ONLY because of an initial value on the address register.
> If that is right, removing the initial value lets Vivado infer memory by
> itself and the whole 32,943 LUT problem evaporates for one line. **Try this
> FIRST.**
>
> **(b) Explicit URAM.** The image is 4.26 Mb = 14.4 of 320 free URAM288.
>
> **(c) HBM-streamed.** MEASURED by TRACK NWFIX: +17,405 LUT over the empty
> adapter, n=2, bit-identical across draws.
>
> **Dropping the norm image is NOT the same as moving it.** Your job is to MOVE
> it. Any area number for a constant-table structure must be drawn at least
> TWICE and reported as a range.

---

## 2. The answer, up front

**Six answers. Four of them are corrections to premises that three documents
carry, and they matter more than the route choice.**

1. **Route (a) cannot work, and the initialiser is not why.** DERIVED before
   any tool ran, and then MEASURED: the ROM as written is 65 deep by **65,536
   bits WIDE** and must present all of them in one cycle. A RAMB36 is at most
   72 bits wide (512x72) and a URAM288 is 4096x72, so a successful inference
   would need `ceil(65536/72) = 911` primitives against the **672 RAMB36 and
   320 URAM288** `report_utilization` reports for `xcvu33p-fsvh2104-2L-e`
   (MEASURED, `/mnt/storage/nwfix/out/synthutil_nf_empty.rpt` lines 73-79 --
   672 Block RAM Tile, 1344 RAMB18, 320 URAM). `Synth 8-6040` names a real obstacle -- it is just
   not the binding one. Section 3 has the message and what Vivado does instead.
2. **"+32,943 LUT" is the DROP saving, not the MOVE saving, and no route that
   keeps the image can reach it.** It is `82,597 - 49,654`, the populated ROM's
   best draw minus the EMPTY adapter -- and the empty adapter is cheap
   precisely because a constant gain lets `rmsnorm_rs` fold `w_mant` away.
   NWFIX MEASURED that fold at **17,367 LUT** and it is paid by any real gain
   wherever the table lives. That is why NWFIX's own HBM probe is
   `49,654 + 17,405 = 67,059` and not 49,654.
3. **The URAM route as previously probed is WORSE than HBM, and the reason is a
   write decoder rather than the store.** NWROM's `ooc_nwrom_memura` MEASURED
   72,164 LUT / 114 URAM, i.e. **+22,510** over empty against HBM's +17,405.
   The 5,105 LUT gap is a 4,096-way write decoder its probe used and NWFIX's
   HBM probe did not.
4. **THE STORE CANNOT BE URAM AT ALL, AND THE "114 URAM" THREE DOCUMENTS QUOTE
   IS A MISREAD OF THE BRAM COLUMN.** MEASURED, and the message has been in
   TRACK NWROM's own log since 2026-08-29 (`vivado_nw_lfura65.log:412`):

       WARNING: [Synth 8-10226] The ram_style = ultra set on ROM
       "ooc_nwrom_memura__GCB101/gvr.nwrom" can not be honored for this device.
       The URAM primitives on this device do not support initializations to any
       non 0 values.  This ROM will be implemented using BRAMs

   Both of that track's memory probes report `uram=0`:
   `ooc_nwrom_memura` is `ramb36=113 ramb18=2 bram=114 uram=0`, and
   `ooc_nwrom_memblk` is `ramb36=135 bram=135 uram=0`. **The 320 idle URAM288
   on this part are unavailable to any constant table** -- only to a store
   written at run time, which is what makes the HBM route the only
   URAM-capable way to serve this gain, and is a point in its favour that no
   brief made. The landing therefore asks for `rom_style = "block"` and says
   so, with the message quoted in the RTL.
5. **THE LANDING IS MEASURED AT 67,318 CLB LUT AND 171 BRAM, TWICE, AND THE
   TWO DRAWS ARE BIT-IDENTICAL.** A BRAM ROM read four elements at a time and
   shifted into a plain register. The saving over the ROM is
   **`+15,279 to +60,747 LUT`, and the whole of that interval belongs to the
   before-side** -- `nu_u1` and `nu_u2` agree on the entire
   `report_utilization` and their cell censuses are byte-identical. It lands
   **within 259 LUT of NWFIX's HBM floor** while spending no HBM bandwidth, no
   AXI master, no schedule and no dependency on TRACK PACKSTRIPE's
   pseudo-channel fix, and `WNS +1.675` is unchanged from the control.
   **It is not free: 171 RAMB36E2 of 672, 25.45%**, and that is a resource
   other levers want.
6. **The values did not move, and that is MEASURED at the OUTPUT.**
   `sim/tb_llama_top_normw` reports `0 of the pinned landmarks moved` -- all
   four token-level hashes bit-identical -- and a ten-row mutation matrix shows
   the landmarks discriminate on exactly the failure this reshape introduces.

---

## 3. Route (a), attempted first, and it is refuted for a better reason than predicted

**The point:** `nu_a` is the PINNED RTL -- the 65:1 select, untouched -- with
exactly one line changed, `signal nidx : natural range 0 to NW_N-1 := 0;`
becoming `signal nidx : natural range 0 to NW_N-1;`. `diff` over the two trees
is that one line and nothing else.

**MEASURED: `Synth 8-6040` FIRES ANYWAY, WORD FOR WORD, WITH THE INITIALISER
DELETED.** From `/mnt/storage/normuram/out/vivado_nu_a.log:56`:

    WARNING: [Synth 8-6040] Register gvr.nidx_reg_rep driving address of a ROM
    cannot be packed in BRAM/URAM because of presence of initial value.

`grep -c '8-6040'`: **1** on `nu_a` (initialiser deleted), 1 on `nu_rom`
(initialiser present), 0 on `nu_empty` and `nu_ec`. **The message does not
change, because the thing it names cannot be removed from VHDL.** A signal of
subtype `natural range 0 to NW_N-1` has an initial value whether or not one is
written: the language gives it `subtype'left`, which is `0`, which is exactly
what `:= 0` said. There is no way to spell "no initial value" for this signal,
so the one-line experiment is not a one-line experiment -- it is a no-op that
happens to compile.

And the result confirms it end to end:

    nu_a   83,709 CLB LUT   ramb36=0   uram=0   WNS +1.675
    nu_rom 89,970 CLB LUT   ramb36=0   uram=0   WNS +1.675

**Zero BRAM and zero URAM in both.** Vivado's own ROM report for `nu_a` lists
one ROM and maps it to LUTs (`RSQRT_ROM[0] 64x32 LUT`, inside `rmsnorm_rs`);
the gain table is not in the table at all. 83,709 sits inside the populated
ROM's known scatter band, so **route (a) did not move the number either**.

**And even if the initialiser could have been removed, the width would still
have refused it.** DERIVED, and it is the reason to stop looking here: the ROM
is 65 deep by 65,536 bits WIDE and must present all of them in one cycle. A
RAMB36 is at most 72 bits wide (512x72) and a URAM288 is 4096x72, so a
successful inference needs `ceil(65536/72) = 911` primitives against 672 and
320. `Synth 8-6040` names a real obstacle; **it is not the binding one, and it
was never actionable.** The fix has to change the ASPECT RATIO, which is what
`gwm` does.

---

## 4. What was built

`rtl/llama_top.vhd`, inside the `gvr` generate and nowhere else. Three edits:

1. `wsel`'s initialiser `NW_TBL(0)` becomes `W_CONST`. **The same value**:
   `nw_load` returns `(others => W_CONST)` unchanged when `NORM_W_IMAGE` is
   empty, which is the only configuration in which `wsel` is a register with a
   power-up value at all. Written this way so `NW_TBL` is referenced nowhere
   outside `gwc` and the elaboration-time reshape.
2. `wsel <= NW_TBL(nidx)` is removed from `nsel`. `nsel` is otherwise
   character-identical: `nidx`, `novf`, the advance-at-completion rule and the
   overflow assert are untouched.
3. Two mutually exclusive generates drive `wsel`:
   * **`gwc`, `NORM_W_IMAGE = ""`** -- the old clocked `wsel <= NW_TBL(nidx)`,
     deliberately unchanged. With `NW_N = 1` that is a constant and Vivado
     folds it, which is what keeps `rmsnorm_rs`'s 17,367 LUT constant fold and
     keeps the `nw_empty` control comparable with every track that has quoted
     it.
   * **`gwm`, populated** -- an inferred ROM plus a shift register.

`nw_count`, `nw_load`, `NW_TBL`, the image, its format and its producer
(`tools/gen_llama_top_weights.py --norm-out`) are **unchanged**. The reshape is
an elaboration-time function over `NW_TBL`, so the verified reader is still the
only reader of the file.

### 4.1 The reshape, and why `GW = 4`

`NW_TBL` is 65 x 65,536 bits. Reshaped to `GW` elements per word it is
`NW_N*NN/GW` words of `GW*16` bits: at the 9B shape **66,560 x 64**, and it
reads in `NWORD + 1 = 1,025` cycles.

`GW = 4` rather than 1 shortens the load 4x and makes the shift register 1,024
stages deep instead of 4,096. `gw_pick` returns 4 when `hidden mod 4 = 0` and 1
otherwise, so no shape can produce a non-integral word.

**It is `rom_style = "block"` and not `"ultra"`, and that is not a preference.**
See answer 4 in section 2: this device's URAM288 cannot be initialised to a
non-zero value, so no constant table can live there. Asking for `ultra` still
WORKS, because Vivado falls back -- and it leaves a WARNING claiming a resource
the design never gets, which is precisely how "114 URAM" entered three
documents.

The two loops in `nwrom_flat` are **nested**, and that is a synthesis
requirement rather than a style: Vivado's elaboration loop limit is 65,536 PER
LOOP STATEMENT (MEASURED, TRACK NWFIX) and `NW_N*NWORD` is 66,560. A single
loop over the flat index would have reintroduced the `[Synth 8-403]` failure
`nw_count` was restructured to remove. **This trap was hit in design, not in
the tool: it is the same file family and the same limit, one commit later.**

### 4.2 The staging register is a shift register, and that is worth 5,105 LUT

NWROM's memory probe wrote `wsw(wptr_d) <= wrd` into an array of `NN` words and
measured 72,164 LUT. NWFIX's HBM probe shifted the same bits in and measured
67,059, recording that "the shift-register write contributes no LUT row at all
-- it is 65,536 flops and an enable". The difference is a `NN`-way write
decoder that buys nothing here, because the words arrive strictly in order.
A version that ever needed them out of order would pay TRACK WRITEDEC's
barrel-shifter penalty instead, and that is stated in the RTL.

---

## 5. The latency statement, and it is shape-invariant

**A URAM read has latency that LUT fabric does not, and here it is absorbed
entirely by the adapter's own read pass. Nothing downstream sees it.**

MEASURED from the RTL, not asserted. `nidx` moves at exactly three instants
(`rst`, `go`, and `dn and v_ack`) and the load restarts at the same three. From
a restart the adapter runs:

| phase | cycles |
|---|---|
| `S_IDLE` before the next `v_start` | >= 1 |
| `S_RD`, the region read pass, `k = 0 .. n+1` | `n + 2` |
| `S_GO`, one cycle of `start` into `rmsnorm_rs` | 1 |
| `rmsnorm_rs` `S_ACC`, pass 1 of 3, `LANES` per cycle | `N/LANES + 3` |
| the rsqrt chain, `S_INV1..6`, `S_SEED1/2`, `S_RQ*` | ~15 |
| **`S_RAW`, the FIRST read of `w_mant`** (`rtl/rmsnorm_rs.vhd:547`) | -- |

The load needs `NN/GW + 1` cycles. Counting only as far as `r_go`, which is
where the assertion checks and is strictly earlier than any `w_mant` read:

| shape | budget to `r_go` | load | margin |
|---|---:|---:|---:|
| `tb_llama_top_normw`, `hidden = 64` | >= 68 | 17 | **4.0x** |
| Qwen3.5-9B, `hidden = 4096` | >= 4,100 | 1,025 | **4.0x** |

**The margin is `GW` and does not depend on the shape**, because the read pass
and the gain load are both linear in `hidden`. That is the one property worth
carrying forward: a bench at `hidden = 64` exercises the same margin ratio a
build at 4,096 has.

`wbusy` and its assertion turn that from an argument into a check, and section
7 measures that the check catches something nothing else does.

**Timing:** MEASURED, `WNS +1.675` and `Fmax 300.7518796992481` on all six
points including both draws of the new structure -- bit-identical to the
control and to every draw NWROM and NWFIX took. TRACK TIMING MEASURED that only
3 memory cells appear among the 3,000 worst paths; this structure did not
become one. See section 6.7 for Vivado's `[Synth 8-7052]` pipelining note and
why the extra stage is not taken.

---

## 6. The area, drawn twice, as a range

**The unfiltered table of every point attempted.** All six, one Vivado at a
time, `sim/ooc_lutdiet_run.sh` unmodified, no `maxLoopLimit`.

    tag          top                   lut       own     u_rms       ff    dsp   bram   uram  carry8      f7       f8      wns      fmax  synth_s
    nu_empty     ooc_normadapt       49654     25523     24131   133197     41      0      0     268   18208     8944    1.675  300.7519      183
    nu_ec        ooc_normadapt       49654     25523     24131   133197     41      0      0     268   18208     8944    1.675  300.7519      166
    nu_a         ooc_normadapt       83709     44044     39665   164750     41      0      0     268   23877    11224    1.675  300.7519      371
    nu_rom       ooc_normadapt       89970     49615     40355   174741     41      0      0     268   24578    11457    1.675  300.7519      369
    nu_u1        ooc_normadapt       67318     25812     41506   191664     41    171      0     268   26736    13296    1.675  300.7519      641
    nu_u2        ooc_normadapt       67318     25812     41506   191664     41    171      0     268   26736    13296    1.675  300.7519      656

### 6.1 The control reproduces, so the rest of the table is readable

`nu_empty` is the pinned RTL with no image and it reproduces TRACK NWFIX's
`nf_empty` -- and through it TRACK NWROM's `nw_empty` -- **on all eleven
columns**: 49,654 / 25,523 / 24,131 / 133,197 / 41 / 0 / 0 / 268 / 18,208 /
8,944 / +1.675. These numbers are on the same scale as NORMADAPT's, NWROM's and
NWFIX's without adjustment.

### 6.2 The empty branch is unchanged, and that is measured rather than argued

`nu_ec` is the NEW RTL with no image. It is **bit-identical to `nu_empty` on
every column**, so `gwc` costs exactly what the code it replaced cost and the
`nw_empty` = 49,654 anchor four tracks quote is not retired. Only the wall
clock moved, 166 s against 183 s.

### 6.3 THE AFTER-SIDE HAS NO RANGE, AND THAT IS THE RESULT

`nu_u1` and `nu_u2` are the SAME COMMAND run twice, back to back, same
directory, same image, same hour, same box.

    nu_u1  67318 LUT  171 BRAM  191664 FF  WNS +1.675  synth 641 s
    nu_u2  67318 LUT  171 BRAM  191664 FF  WNS +1.675  synth 656 s

and the equality is not just the twelve CSV columns:

    the whole report_utilization, excluding its own Date and Command lines: IDENTICAL
    1b341a7384f1eca3501452183ea0705b  census_nu_u1.txt
    1b341a7384f1eca3501452183ea0705b  census_nu_u2.txt

**The cell census is byte-identical and only wall time moved.** TRACK SCATTER's
rule for this structure was "NOT SAFE ... report the range or nothing"; the
structure that had no value now has one, because the thing that scattered is
gone. `gvr.wsel` appears as a census root in `nu_a` and `nu_rom` (26,287 LUT
and 41,507 FF in `nu_rom`) and **does not appear at all** in `nu_u1`/`nu_u2`.

### 6.4 The saving, and the range belongs entirely to the before-side

Every draw of the populated ROM, all eight, from three tracks:

    82,597  NWROM  nw_lf65     |  103,081  NWROM  nw_bnd65
    83,709  NORMURAM nu_a      |  103,302  NWFIX  nf_pre65lf
    87,254  NWFIX  nf_fix65    |  103,435  NWFIX  nf_fix65lf
    89,970  NORMURAM nu_rom    |  128,065  NWFIX  nf_fix65b

| against | LUT saved |
|---|---:|
| the ROM's BEST draw, 82,597 | **15,279** |
| this track's own same-session before-side, `nu_rom` 89,970 | **22,652** |
| the ROM's median, ~103,192 | **~35,874** |
| the ROM's WORST draw, 128,065 | **60,747** |

**So: `+15,279 to +60,747 LUT`, and the width of that interval is a property of
the thing being removed, not of the thing replacing it.** If one number has to
be carried, carry the saving against the median with the range attached -- and
note that the more valuable half of the result is that the budget loses its
only termless-than-a-value.

### 6.5 It lands within 259 LUT of the HBM floor and spends no HBM bandwidth

| way to serve the gain | LUT | delta over `nu_empty` | reproducible | HBM cost |
|---|---:|---:|---|---|
| ROM in LUTs (before) | 82,597 .. 128,065 | +32,943 .. +78,411 | **no**, 8 draws | none |
| NWROM's addressed-array memory probe | 72,164 | +22,510 | n = 1 | none |
| NWFIX's HBM probe | 67,059 | +17,405 | yes, n = 2 | **the read path, unmeasured** |
| **this landing** | **67,318** | **+17,664** | **yes, n = 2 bit-identical** | **none** |

DERIVED from the census, and it closes: of the +17,664, **17,367 is
`rmsnorm_rs` losing its constant fold** (`gvr.u_rms` 24,131 to 41,506, which is
within 8 LUT of the 41,498 NWFIX measured on the HBM probe with no table
anywhere in the design), and the ENTIRE gain store, its address generator, its
shift register and its busy logic together are **313 LUT and 58,453 FF**:

    gvr.gwm.wptr    83 LUT     81 FF
    gvr.gwm.wreg    57 LUT  58,368 FF
    (177 gwm roots in total)  313 LUT  58,453 FF

The adapter's own row moves 25,523 to 25,812, **+289 LUT**. NWFIX measured +38
for the same structure fed from AXI. The 4,846 LUT this landing recovers over
NWROM's memory probe is the write decoder that probe used and this one does not
-- PREDICTED at 5,105 from the two probes' difference, MEASURED at 4,846.

### 6.6 What it costs, and it is not LUTs

**171 RAMB36E2 of 672, 25.45%. Zero URAM, zero RAMB18.** That is the honest
price and it is a resource other levers want: TRACK RMSMUX's vectors need 6
tiles and the KV cache needs its own.

**171 is more than NWROM's probes reported (114 and 135) and the difference is
`GW`.** Its probes were one element per word, 266,240 x 16; this is four per
word, 66,560 x 64, which packs a RAMB36 less efficiently. The trade is bought
deliberately: `GW = 1` would cost fewer tiles and would reduce the load margin
from 4.0x to 1.0x at the 9B shape, which is no margin at all. **A `GW = 2`
point was not drawn and is the obvious next measurement if BRAM turns out to
bind.**

### 6.7 Timing did not move

**`WNS +1.675` and `Fmax 300.7518796992481` on every one of the six points,
bit-identical, including both draws of the new structure.** The BRAM read did
not become a critical path in OOC synthesis at 5.0 ns.

That said, Vivado flags the pipelining, once per RAM primitive
(`vivado_nu_u1.log:636`):

    INFO: [Synth 8-7052] The timing for the instance
    i_57/gvr.gwm.wrd_reg_0_0 (implemented as a Block RAM) might be sub-optimal
    as no optional output register could be merged into the ram block.
    Providing additional output register may help in improving timing.

That is accurate and by design: this loader carries exactly ONE register
between address and datum, which is the RAM's core register, and it has no
optional output register to give. Adding a second stage costs 64 flops and one
cycle of a 1,025-cycle load, so it is cheap insurance **if a routed run ever
shows this path**. It is not taken here because the OOC number does not
motivate it and an unmeasured pipeline stage is an unmeasured pipeline stage.

**And an OOC WNS is not a routing result.** TRACK TIMING measured
`[Route 35-447]` congestion on the composed design at a LOOSER density than the
one its fit arithmetic now assumes. "Fits by CLB count" and "builds" are
different claims and nothing here touches the second.

---

## 7. The values, and the teeth

### 7.1 The output oracle

`sim/tb_llama_top_normw` is `tb_llama_top_real` plus `NORM_W_IMAGE` and nothing
else, with four landmarks pinned by TRACK NORMW at commit `35e0ed0`. It is a
hash of the TOKEN, not of the table, which is the level the brief asks for:
a ROM that reads back correctly is not a norm that computes correctly.

    sim/tb_llama_top.vhd:2801: tb_llama_top: P14 landmarks measured --
      EXP_X0 => -16350, EXP_XSUM => 90889, EXP_XALL => 90889, EXP_STEPH => 18618
      (0 of the pinned landmarks moved)

    sim/tb_llama_top.vhd:2846: tb_llama_top RESULT: PASS -- 64 descriptors,
      4 blocks, 1 tokens per run, 2 descriptor-latency points, R_X bit-identical
      across all of them, R_X(0) = -16350 hash(R_X) = 90889

and the whole family, `REGRESS_SCRATCH=... bash sim/regress.sh --only tb_llama_top`:

     suite sim   PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
     OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0

**Read the `PASS 6`, not the word PASS.** Five of those six rows run `gwc` and
are structurally blind to this change; the sixth, `normw`, is the only wrapper
in the tree that populates `NORM_W_IMAGE` and therefore the only one that
elaborates `gwm` at all.

**A landmark is a change detector, not an oracle**, and that is the right
instrument for this job specifically: the claim is not that the gain is
correct, it is that the gain is UNCHANGED. Its correctness rests on TRACK
NORMW's original pinning and on NWFIX's `nw_load` oracle, neither of which this
track moved.

### 7.2 The mutation matrix, `sim/mutate_llama_top_normuram.sh`

Ten rows, control first, at `tb_llama_top_normw`'s exact generics and
landmarks. Raw output in `/mnt/storage/normuram/mut2` and `mut3`.

| id | mutation | verdict | landmarks moved |
|---|---|---|---:|
| U0 | CONTROL: clean tree | **SURVIVED** (required) | 0 of 4 |
| U1 | address rotated by one word: gain cyclically shifted by `GW` elements | KILLED (landmarks) | 4 of 4 |
| U2 | **the m7 hazard, packer half**: elements rotated INSIDE the `GW`-element word | KILLED (landmarks) | 4 of 4 |
| U3 | **the m7 hazard, unpacker half**: the shift runs the other way, so the WORDS land reversed | KILLED (landmarks) | 4 of 4 |
| U4 | norm op ignored: every op served op 0's gain | KILLED (landmarks) | 3 of 4 |
| U5 | the load never restarts: correct at op 0, stale after | KILLED (landmarks) | 3 of 4 |
| U6 | margin gone: one word every 8 cycles | KILLED (**`wbusy` assertion**) | -- |
| U6x | **ATTRIBUTION CONTROL**: U6 with the assertion disabled | **SURVIVED** | **0 of 4** |
| U6b | budget blown outright: one word every 64 cycles | KILLED (**`wbusy` assertion**) | -- |
| U6bx | **ATTRIBUTION CONTROL**: U6b with the assertion disabled | KILLED (landmarks) | 4 of 4 |

**U2 and U3 are the whole reason this matrix exists.** Packing four elements
into a 64-bit word and reading them back in the wrong order permutes every gain
vector in groups of four, with no structural symptom at all -- this project's
recorded `m7 mutant` failure class. Both are caught on all four landmarks.

**The attribution control earned its place, and it changed a claim.** Without
U6x the `wbusy` assertion would have been credited with catching a budget
failure the landmarks would have caught anyway. U6x says otherwise and in the
direction that FAVOURS the new check: **a margin failure that still produces
CORRECT VALUES is invisible to the landmarks and visible only to the
assertion.** U6 is 8x too slow, so `wbusy` is still high at `r_go` -- but
`rmsnorm_rs`'s `S_RAW` is later still, so the gain is resident by the time it
is actually read, and the token comes out bit-identical. U6b is 64x, late
enough to be read half-shifted, and there both checks fire.

So the two checks see different faults and the pair is the honest statement:
**the landmarks are a VALUE check and the assertion is a MARGIN check.** A
design that ate its margin without eating its values would ship silently
otherwise, and the next change to `S_RD`, `LANES` or `GW` is exactly what would
do it.

### 7.3 The row that did NOT bite, under its own name

| id | mutation | verdict |
|---|---|---|
| U7 | `gw_pick` forced to return 1, so the reshape is one element per word | **SURVIVED**, 0 of 4 landmarks moved |

This is the correct verdict and it is reported because it fixes the harness's
resolution floor: **the landmarks cannot see the reshape's WORD WIDTH, only its
element ORDER.** A `GW` that changed the URAM count, the load length or the
timing while leaving the values alone would pass this gate in silence. That is
what section 6's area draw is for, and it is the only instrument that sees it.

**Also on the floor:** U4 and U5 move only 3 of 4 landmarks -- `EXP_X0`, the
first element of `R_X`, is unchanged in both, because both serve norm op 0's
gain correctly and only go wrong later in the token. A gate holding `EXP_X0`
alone would have scored them survivors.

---

## 8. Measured and REJECTED -- do not retry

* **Route (a), removing the initialiser so Vivado infers the ROM itself.**
  DERIVED and then MEASURED (section 3). Do not retry it in any form -- not on
  `nidx`, not on `wsel`, not with `rom_style` added on top. The obstacle
  `Synth 8-6040` names is real and is not the binding one: **a ROM 65 deep by
  65,536 bits WIDE needs `ceil(65536/72) = 911` RAMB36 or URAM288 against 672
  and 320 available**, so no attribute and no initialiser edit can make that
  shape fit. The fix is to change the ASPECT RATIO, which is what `gwm` does.
  This one-liner was named as the cheapest thing on the board by two separate
  readers of TRACK SCATTER section 11; it is not a thing at all.
* **Quoting `+32,943 LUT` as the saving from moving the gain image.** MEASURED
  arithmetic, not opinion: `82,597 - 49,654` is the ROM's BEST draw minus the
  EMPTY adapter, and the empty adapter is cheap because a constant gain lets
  `rmsnorm_rs` fold `w_mant` away -- NWFIX MEASURED that fold at 17,367 LUT and
  every real gain pays it wherever the table lives. `+32,943` is the saving
  from DROPPING the image, which the brief forbids and which would forfeit
  comparing 9 of the 63 captured seams against the model. **The reachable floor
  for MOVING it is about `+17,405`, i.e. NWFIX's HBM number**, and the point of
  this track is to reach it without spending HBM bandwidth.
* **An addressed write array for the staging vector.** MEASURED by NWROM at
  72,164 LUT against NWFIX's 67,059 for the shift-register form on the same
  bits. The `NN`-way write decoder buys nothing when the words arrive in order.
  Do not reintroduce it; if the order ever stops being strict, WRITEDEC's
  barrel-shifter penalty is the price, not this.
* **`maxLoopLimit`.** Not used, not needed, and rejected on the record by TRACK
  NWFIX. `nwrom_flat`'s two loops are nested for the same reason `nw_count`'s
  are: `NW_N*NWORD` is 66,560 and the limit is 65,536 PER LOOP STATEMENT.
* **Pointing this loader at `rtl/rmsnorm_rs_mem.vhd`'s `w_we`/`w_waddr`/
  `w_wdata` bank port as part of THIS change.** Evaluated against the unit and
  against TRACK RMSMUX's section 12, and deferred rather than rejected -- the
  lever is real and the composition is right, but it is a redesign of `gvr`'s
  datapath and not a wiring change. Four coupled consequences, and the first is
  new information that section 12 did not have:
  1. **The bank port is ONE 16-bit word per cycle, so the gain load rate drops
     to 1 element per cycle and the margin becomes a function of `NORM_LANES`.**
     Today the budget to `r_go` is `NN+4` against a load of `NN/GW+1`, so the
     margin is `GW = 4.0x` and does not depend on the shape. Composed, the load
     is `NN+2` and the first `w` read is `S_RAW`, so the margin is about
     `1 + 1/LANES`: **1.26x at the shipping `NORM_LANES = 4` and 1.07x at
     `LANES = 16`**, which that unit's own sweep covers.
  2. **`S_RAW` reads `LANES` elements per cycle against the loader's one**, both
     ascending from 0, so residency stops being a phase separation and becomes
     a race -- and the deadline moves from `r_go`, which `gvr` can see and which
     `wbusy` checks, to the unit's internal `S_RAW`, which it cannot.
     Section 7.2's U6/U6x pair is the evidence that this exact fault class
     leaves the values CORRECT and is invisible to the landmarks.
  3. **`gwc` has no flat port to drive**, so the synthetic ramp would have to be
     generated in hardware, and either way the `nw_empty = 49,654` anchor that
     NORMADAPT, NWROM, NWFIX and this track all quote stops being comparable.
  4. `S_WR` must become a two-stage pipeline for `o_rdata`'s one-edge latency.
  The URAM count is NOT a consequence: `GW = 4` can be kept and demultiplexed
  over four cycles, so the store stays 17 URAM288 either way.

---

## 9. Measurement traps hit, including this track's own

### 9.1 The file has two tracks in it, and only the pinned copy is safe to measure

`git status` was clean for `rtl/llama_top.vhd` when this track started. By the
time the baseline was pinned, `git diff HEAD -- rtl/llama_top.vhd` showed
**four foreign hunks** that were not this track's and not committed: a new
`A_SUB_BYTES` generic near line 630, `CHK_A_BLOCK` near 880, and
`A_BEAT_B`/`A_SUB_BEATS`/`A_SCL_BEATS` with a capacity refusal inside
`ga_real` near 2485 and 2563. That is a subsystem-A capacity check, a different
region of the same file.

The consequence for measurement is direct: **an area comparison taken from the
working tree would have carried another track's in-flight edits on both sides
and attributed the difference to this one.** Every synthesis tree here is built
from `git archive 0b4c7b2` plus this track's three edits transplanted
explicitly, and `diff` over the two trees shows exactly three hunks, all inside
`gvr`, 225 changed lines and nothing else.

The consequence for committing is the one CLAUDE.md names: this is a SHARED
file, so the pathspec form would capture their work.

### 9.2 `local a=... b=$a` under `set -u`

`sim/mutate_llama_top_normuram.sh` opened with
`local tag="$1" dir="$SCRATCH/${tag}_src"` and every row after the control
printed `tag: unbound variable`. Split into two `local` statements. The
symptom was that the CONTROL row passed and every mutation row failed, which
reads exactly like a harness that cannot build mutants -- **a matrix whose
control passes is not a matrix that works.**

### 9.3 An argv filter found 3,532 KiB of Vivado with zero Vivados on the box

The synthesis waiter gated on
`ps -eo rss=,args= | awk '/[u]nwrapped\/lnx64.o\/vivado/ {s+=$1}'`. **The first
launch of point 1 then sat in `sleep 10` for ELEVEN MINUTES against a lane that
was already free**, because a long-lived tool-wrapper shell carried the
unwrapped path **in its own command line** and was summed as 3,532 KiB of
Vivado.

This is the CLAUDE.md self-match trap, which is written for `pgrep -f` and
applies identically to any `ps ... args=` filter. **The `[u]nwrapped` bracket
trick does not save you**: the bracket stops the filter matching its OWN argv,
and the text that matched belonged to a sibling process. The failure is silent
and looks exactly like a busy lane, so it costs time rather than raising
anything.

Fixed by reading `/proc/PID/exe` and summing `VmRSS`, which a command line
cannot spoof. The dispatcher reproduced it independently with five real Vivado
workers running and found the argv form also matching four `bash` processes and
a `ugrep`; it is now in CLAUDE.md. The stuck scope was stopped by unit name,
`systemctl --user stop`, and not by any pattern kill.

### 9.4 `MemoryHigh` bounds the peak you measure, not just the peak you cause

`nu_empty` ran alone under `MemoryHigh=11G` and the cgroup's `memory.peak` was
**10.54 GiB**, which is a real peak because it never reached the ceiling. The
five-point batch ran under `MemoryHigh=13G` and reported `memory.peak` =
13,959,782,400 bytes -- **1.1 MB above the 13G ceiling**, i.e. pinned AT it.

**That second number is not the job's peak. It is the cap.** `MemoryHigh` is a
soft limit: the cgroup is throttled and reclaimed rather than killed, so it
sits just above the ceiling for as long as it wants more. Quoting 13.00 GiB as
"the peak of a populated point" would be quoting the cap back. What can honestly
be said is: **a populated point wants MORE than 13 GiB and runs correctly when
throttled to it**, and the only unthrottled peak here is `nu_empty`'s 10.54.

### 9.5 HEAD moved under the track, again

`git rev-parse HEAD` as its own step returned `0b4c7b2`, not the `9e3348e`
read at start-up. This is the third track to record it in two days.

---

## 10. Open, not yet answered

* **Nothing here is placed or routed.** Every caveat in
  `sim/ooc_compose_bcd.tcl`'s header stands. An OOC synthesis sum is not a
  routability result, and a URAM that fits the count can still fail to place
  where the rest of the block wants to be.
* **The Vivado half of the values oracle is still OPEN**, exactly as NWFIX left
  it. GHDL is shown to load the file's values and the TOKEN is shown to be
  bit-identical; nothing reads back what Vivado's `hread` put in the URAM.
  The reshape does not change that either way -- `nwrom_flat` is a pure
  function of `NW_TBL` -- but it adds one more elaboration-time transform
  between the file and the silicon, and that transform is checked only in GHDL.
* **The landmarks cannot see the reshape's WORD WIDTH.** Section 7.3, row U7.
  `GW` is fixed by area and margin arguments, not by any value check.
* **`NORM_LANES` is not swept here.** Every number is at the default 4. The
  cycle budget in section 5 counts `S_ACC` as `N/LANES + 3`, so a larger
  `LANES` shortens the budget -- though the assertion's checkpoint is `r_go`,
  which is BEFORE `S_ACC`, so the 4.0x margin this design has is
  `LANES`-independent. That would stop being true under the composition in
  section 8.
* **One image, one shape.** `NW_N = 65`, `hidden = 4096` for the area; `NW_N =
  9`, `hidden = 64` for the values. NWROM MEASURED that the `NW_N` sweep is not
  monotonic, so no number here should be extrapolated to another `NW_N`.
* **The mutation matrix runs one wrapper.** `tb_llama_top_normw` is the only
  bench in the tree that populates `NORM_W_IMAGE`, so it is the only bench that
  elaborates `gwm` at all. There is no second, independent configuration in
  which this structure has been exercised.
* **Whether the URAM inference survives place-and-route timing.** The ROM is
  17 URAM288 cascaded at the 9B shape and this design carries only ONE register
  between the address and the datum. If a cascade needs more pipelining than
  that, the cost appears as WNS and not as area. Section 6 reports the OOC WNS;
  a routed number is not available here.
