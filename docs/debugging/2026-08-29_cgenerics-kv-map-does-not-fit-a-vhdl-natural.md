# Subsystem C's KV memory-map generics: five of six values verify, and the map still cannot be set

**Date** 2026-08-29. **Track** CGENERICS. **Base commit** `0e4f98d` ("kvsize:
both arenas were sized for the 27B, and the RTL says by 2.99x and 3.77x"),
pinned as its own step with `SHA=$(git rev-parse HEAD)` before any
`git archive`, because HEAD has moved about forty-five times today and a
straddled archive has already cost one track its first development round.
**Hardware** none. Nothing here opened `/dev/xdma*`, ran `xsdb`, `hw_server`,
or programmed a card. **Machine at start**, MEASURED with `df -h` / `free -g`:
root `/dev/nvme1n1p6` 39 G free at 97 percent, `/mnt/storage` 389 G free,
18 G of RAM available, 15 G of swap in use, with TRACK LUTDIET's Vivado
running `rms_n4096` throughout.

---

## 1. The question, verbatim

> **Your job: verify that table against the RTL yourself, then set the
> generics.** Oren's standing position is that the residency map owns these
> numbers, and the map now exists and is derived rather than asserted, so this
> is no longer a judgement call about placement. It is a verification job.

The table under verification, TRACK KVSIZE's section 11, reported not set:

    C_KV_BLOCK   32
    C_MAXPOS     131072        (ceiling 233,396; 262,144 does not fit)
    C_K_BASE     4,521,582,592
    C_V_BASE     C_K_BASE + 8704*C_MAXPOS
    C_KV_ADDR_W  33
    attn_block's LAYERS  8     (currently 16, the same defect)

---

## 2. The answer, up front

**Every arithmetic claim in that table is correct, and the map still cannot be
set, because `rtl/llama_top.vhd` declares `C_K_BASE` and `C_V_BASE` as
`natural` and the address is bigger than a VHDL `natural`.**

MEASURED, GHDL 1.0.0 mcode: `natural'high = 2147483647`. The KV base is
**4,521,582,592**, which is 2.11 times that. Passing it is refused before any
guard in the design runs:

```
$ ghdl -r --std=08 llama_top -gC_REAL=true -gC_KV_AXI=true \
      -gC_K_BASE=4521582592 -gC_V_BASE=5662433280 -gC_KV_ADDR_W=33 ...
/usr/bin/ghdl-mcode:error: value not in range for generic 'c_k_base'
/usr/bin/ghdl-mcode:error: error during elaboration
```

There is a **second, independent** 32-bit wall behind it. `util_pkg.clog2` is a
`while v < n loop v := v*2` doubling loop over `natural`, so it **overflows for
any argument above 2\*\*30**, and `llama_top:3812` and `:3834` both call it on
`maximum(C_K_BASE, C_V_BASE) + KVREG_B`. MEASURED: with `C_K_BASE = 0`, the
largest `C_MAXPOS` this file will accept is **61,680**, and 61,681 dies with an
unattributed `overflow detected`. The map needs 131,072.

So the correct statement is not "a value does not verify". It is:

**The values are right and the container is too small. `llama_top`'s generic
interface cannot express the address space its own RTL addresses, and the guard
that would check the width cannot evaluate at the width it is checking.**

`rtl/attn_kv_axi.vhd` itself needs no change: its bases are
`std_logic_vector(ADDR_W-1 downto 0)` **ports**, not integers, and it elaborates
clean at the full geometry (`HEAD_DIM 256, KV_BLOCK 32, N_KVH 4, LAYERS 8,
MAXCTX 131072, POS_W 18, ADDR_W 33`) and at `MAXCTX 233396` as well. The defect
is entirely in the caller's encoding.

**STOPPED, as briefed**, because the fix is in `rtl/llama_top.vhd`, which TRACK
BTOP1 owns right now. Section 7 gives the remediation, checked to the bit.

What WAS done, in files this track owns:

* `rtl/attn_block.vhd` -- the default shape set corrected to the real 9B
  one-card shape. Not only `LAYERS`; see section 6, which corrects the brief.
* `tools/pack_int4.py` -- the printed residency estimate no longer restates six
  Qwen3.8-27B literals; it calls `hbm_map.arena_sizes()`.

---

## 3. The procedure, in the order it was run, and what each step isolates

Every value was re-derived from the RTL. KVSIZE's document was read once, for
the claims, and then not consulted again until section 5 compared the two.

1. **Pin the tree.** `SHA=$(git rev-parse HEAD)` as its own step, then
   `git archive $SHA`. This isolates every measurement below from the other
   three running tracks.
2. **The shape, from the record and not the prose.** `rtl/model_cfg_pkg.vhd`'s
   `QWEN35_9B` aggregate, and the bodies of `attn_layers` and `gdn_layers`.
   Isolates the layer counts from everything downstream.
3. **The KV record, from the constants that build it.**
   `rtl/attn_kv_axi.vhd:365-370`. Isolates the per-record size from the extent.
4. **The GDN state extent, from PORT RANGES.** `rtl/gdn_block.vhd:307-322` and
   `rtl/gdn_recur.vhd:127,137`. Deliberately not the file's own header, which
   KVSIZE recorded as wrong; confirmed wrong again here.
5. **Every legality constraint on `KV_BLOCK`, enumerated from the asserts**, and
   then MEASURED as a sweep rather than reasoned. Isolates "what the RTL
   permits" from "what a comment says it permits".
6. **The address arithmetic, re-derived from the migrated manifest** rather than
   from KVSIZE's arithmetic, then compared. Isolates the placement from the
   derivation.
7. **The 32-bit walls, found by trying the values.** This is the step that
   produced the answer, and it produced it only because the values were
   actually passed to GHDL rather than checked on paper.
8. **A bisection of the `C_MAXPOS` wall**, 61,680 against 61,681, so the ceiling
   is a measured boundary and not an inferred one.
9. **Teeth on the guards**, each failing row paired with the row one generic
   away that must still pass.
10. **`attn_block`'s defaults**, with a poisoned-default negative control to
    settle whether anything reads them, and the whole `--only attn` gate either
    side.
11. **`tools/pack_int4.py`** re-pointed at `hbm_map.arena_sizes()` and exercised
    at 1, 2 and an illegal 3 cards.

---

## 4. The evidence, as raw output

### 4.1 The shape, re-derived (DERIVED, `rtl/model_cfg_pkg.vhd`)

```
constant QWEN35_9B : model_cfg_t := (
  blocks        => 32,   attn_interval => 4,
  lin_key_heads => 16,   lin_val_heads => 32,   lin_head_dim  => 128,
  attn_q_heads  => 16,   attn_kv_heads => 4,    attn_head_dim => 256,
  vocab         => 248320, max_context => 262144 );
constant MODEL : model_cfg_t := QWEN35_9B;

function attn_layers  return m.blocks / m.attn_interval   -> 32 / 4 = 8
function gdn_layers   return m.blocks - attn_layers(m)    -> 32 - 8 = 24
```

`rtl/llama_top.vhd:3496` sets `C_LAY := nlay(SHAPE)` and
`rtl/llama_map_pkg.vhd:334` defines `n_attn_blocks = blocks / attn_interval`,
so **`C_LAY` is already 8 at the top level** and always has been. `C_NKVH` is 4
and `C_HD` is 256, both straight from the record.

### 4.2 The KV record (DERIVED, `rtl/attn_kv_axi.vhd:365-370`)

```
constant NBLK   : integer := HEAD_DIM/KV_BLOCK;
constant CH_B   : integer := 16;                    -- the record granule
constant MANT_B : integer := HEAD_DIM*CM_W/8;
constant REC_B  : integer := CH_B + MANT_B;         -- 272 at the geometry
```

`CM_W` is 8 and an assert refuses anything else, so at `HEAD_DIM = 256`,
`REC_B = 16 + 256 = 272`. **`REC_B` does not depend on `KV_BLOCK`**, which is
why the choice of `C_KV_BLOCK` and the choice of the bases are independent
questions. One region per position is `C_LAY * C_NKVH * REC_B = 8 * 4 * 272 =
**8704**`, and both regions are `17408` bytes per token. That reproduces
KVSIZE's per-token figure exactly and from the same RTL, read separately.

### 4.3 The GDN state (DERIVED, `rtl/gdn_block.vhd` port ranges)

```
st_rhead : out integer range 0 to VAL_HEADS-1;
st_rcol  : out integer range 0 to DIM-1;
st_rgrp  : out integer range 0 to DIM/RECUR_LANES-1;
st_rdata : in  std_logic_vector(RECUR_LANES*16-1 downto 0);
se_rhead : out integer range 0 to VAL_HEADS-1;      -- se_j : signed(7 downto 0)
```

`VAL_HEADS * DIM * DIM` sixteen-bit words plus `VAL_HEADS * DIM` bytes. At
32 / 128: `32*128*128*2 = 1,048,576` + `32*128 = 4,096` = **1,052,672 B/layer**,
`x 24 = 25,264,128`. Confirms KVSIZE.

**`gdn_block.vhd:67` says "2 MiB at 9B" and is wrong by 2x**, confirming
KVSIZE's rejected note. The formula in the same sentence is right.

### 4.4 `KV_BLOCK`: the legal set, MEASURED not reasoned

`ghdl -r attn_kv_axi` at `HEAD_DIM 256, N_KVH 4, LAYERS 8, MAXCTX 131072,
POS_W 18, CM_W 8, EXP_W 8, AXI_DW 256, ADDR_W 33, MAXB 16, MAXOUT 4, RBUF 4`:

```
KV_BLOCK=4    NBLK=64   rc=1  bound check failure at rtl/attn_kv_axi.vhd:398
KV_BLOCK=8    NBLK=32   rc=1  bound check failure at rtl/attn_kv_axi.vhd:398
KV_BLOCK=16   NBLK=16   rc=0  (elaborated clean)
KV_BLOCK=32   NBLK=8    rc=0  (elaborated clean)
KV_BLOCK=64   NBLK=4    rc=0  (elaborated clean)
KV_BLOCK=128  NBLK=2    rc=0  (elaborated clean)
KV_BLOCK=256  NBLK=1    rc=1  attn_kv_axi.vhd:513: NBLK and N_KVH must be >= 2
```

**The legal set at `attn_head_dim` 256 is exactly {16, 32, 64, 128}**, which is
what KVSIZE stated, now measured rather than derived from the asserts. The
binding constraints, from `attn_kv_axi:479,487,513`, are
`NBLK*EXP_W/8 <= CH_B` (so `KV_BLOCK >= 16`),
`(KV_BLOCK*CM_W/8) mod CH_B = 0` (so a multiple of 16) and `NBLK >= 2` (so
`KV_BLOCK <= 128`). **`C_KV_BLOCK = 32` VERIFIES**, and it is also what
`attn_kv_axi`'s own header calls "the build geometry" at :29-32.

### 4.5 The address arithmetic, re-derived from the manifest

`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json`, read directly:

```
weights_end       4496318464   0x10C006000
gdn_state_base    4496318464   0x10C006000
gdn_state_bytes     25264128   0x1818000
kv_base           4521582592   0x10D81E000     <- weights_end + gdn_state_bytes
desc_arena_base   8584548352   0x1FFADD000     <- the first top-anchored block
```

DERIVED here, from `8704` computed in 4.2 and not taken from KVSIZE:

```
available for KV = 8584548352 - 4521582592 = 4,062,965,760
ceiling C_MAXPOS = 4062965760 / 17408       =   233,396

C_MAXPOS= 131072  region=1140850688  V=0x15181E000  end=0x19581E000  fits
C_MAXPOS= 233396  region=2031478784  V=0x18697C800  end=0x1FFADB000  fits
C_MAXPOS= 262144  region=2281701376  V=0x19581E000  end=0x21D81E000  SHORT BY 500,436,992 (477.25 MiB)
```

**Every figure in KVSIZE's section 11 reproduces exactly**: `C_V_BASE` at
131,072 is `0x1_5181_E000`, the pair ends at `0x1_9581_E000`, the ceiling is
233,396, at which the pair ends at `0x1_FFADB000`, **2,048 bytes** below the
descriptor arena, and 262,144 is short by 477 MiB. `clog2` of the pair's end
`6,803,283,968` is **33**, since `2**32 = 4.29e9 < 6.80e9 <= 2**33 = 8.59e9`.
**`C_KV_ADDR_W = 33` is arithmetically correct.**

### 4.6 The wall, MEASURED

```
$ ghdl -r --std=08 intrange
integer'low  = -2147483648
integer'high = 2147483647
natural'high = 2147483647
$ ghdl -r --std=08 intrange -gG=4521582592
/usr/bin/ghdl-mcode:error: value not in range for generic 'g'
```

`llama_top` with KVSIZE's table verbatim:

```
W1  -gC_K_BASE=4521582592 -gC_V_BASE=5662433280 -gC_KV_ADDR_W=33 -gC_MAXPOS=131072
    /usr/bin/ghdl-mcode:error: value not in range for generic 'c_k_base'
```

With the base removed entirely, to isolate the second wall from the first:

```
W2  -gC_K_BASE=0 -gC_V_BASE=1140850688 -gC_KV_ADDR_W=33 -gC_MAXPOS=131072   rc=1
    /usr/bin/ghdl-mcode:error: overflow detected
      from: work.llama_top(rtl).DECL_ELAB at llama_top.vhd:3811

W3  -gC_K_BASE=0 -gC_V_BASE=536862720  -gC_KV_ADDR_W=31 -gC_MAXPOS=61680    rc=0
W4  -gC_K_BASE=0 -gC_V_BASE=536871424  -gC_KV_ADDR_W=31 -gC_MAXPOS=61681    rc=1
    /usr/bin/ghdl-mcode:error: overflow detected
      from: work.llama_top(rtl).clog2 at llama_top.vhd:785
```

The boundary is exact and predicted: `util_pkg.clog2` is

```vhdl
function clog2(n : natural) return natural is
  variable r : natural := 0; variable v : natural := 1;
begin
  while v < n loop v := v*2; r := r+1; end loop;
```

so `v` must be able to reach the power of two **above** `n`, and `v := v*2` at
`v = 2**30` overflows. MEASURED directly: `clog2(1073741824) = 30`,
`clog2(1073741825)` overflows. With `C_K_BASE = 0` the argument is
`17408 * C_MAXPOS`, and `17408 * 61680 = 1,073,725,440 <= 2**30` while
`17408 * 61681 = 1,073,742,848 > 2**30`. **61,680 is the ceiling, to the
position.**

### 4.7 Teeth on the KV-map guards

Every failing row is paired with the row one generic away that must pass, so a
guard that refuses everything is excluded. All at `C_MAXPOS = 4096`, where one
region is 35,651,584 B and both bases are representable.

```
control_ok               rc=0  (elaborated clean)
addr_w_one_short         rc=1  bound check failure at rtl/llama_top.vhd:3812
k_base_overlaps_v        rc=1  llama_top.vhd:3845: the K and V KV regions
                               overlap.  Each is 35651584 bytes.
k_base_unaligned         rc=1  llama_top.vhd:3850: the KV bases must be 16-byte
                               aligned; that is the record granule ...
kv_block_illegal         rc=1  bound check failure at rtl/llama_top.vhd:3797
```

`sim/realshape_gate.sh`, unmodified, after this track's `attn_block` edit:

```
REALSHAPE GATE: PASS  rows 19 (10 of them guards that must refuse)
```

### 4.8 `attn_block`'s defaults, and whether anything reads them

Before, `rtl/attn_block.vhd:199-207`:

```vhdl
-- Shapes.  Defaults are Qwen3.8-27B on ONE of two cards, which is the
-- build target: 24 query heads / 4 KV heads / head_dim 256 across two
-- cards is 12 / 2 / 256 here.  9B on one card is N_QH = 16, N_KVH = 4.
HEAD_DIM  : positive := 256;
N_QH      : positive := 12;
N_KVH     : positive := 2;
LAYERS    : positive := 16;
```

The header's own justification is false: `constant MODEL := QWEN35_9B`, and
`rtl/gdn_block.vhd:187` already says "Defaults are Qwen3.5-9B on ONE card,
which is the current target" with `LAYERS := 24 = gdn_layers`. **`attn_block`
was the only shape-carrying block left at the 27B two-card set**, and
`sim/ooc_compose_bcd.tcl:64-73` already says so in as many words and passes
`{HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8}` to work around it.

Teeth, run in the pinned scratch tree with the default deliberately POISONED:

```
T1b  default N_KVH POISONED to 5 (illegal: 16 mod 5 /= 0), tb_attn_block runs:
     tb_attn_block: PASS -- 3 consumer configurations, 64 elements each, y
     stream bit-identical across all of them ... and BIT-EXACT against
     ref/attn_block_vec.c over 130 compared values

T2b  same poisoned file, attn_block STANDALONE with no overrides:
     rtl/attn_block.vhd:681: (assertion failure): attn_block: query heads must
     be a whole multiple of KV heads; that ratio IS the GQA group
```

T2b proves the default is genuinely used when nobody overrides it; T1b proves
**no consumer overrides is a thing that never happens** -- the bench stays
bit-exact against its C oracle with an illegal default in the file. Together
they say the change is a statement made true again, not a number that was being
computed with.

`sim/regress.sh --only attn`, both sides of the edit:

```
BEFORE  OVERALL PASS 15  FAIL 0  NOVERDICT 0  TIMEOUT 0  BUILD-ERROR 0  NOCHECK 1  SKIPPED 4
AFTER   OVERALL PASS 15  FAIL 0  NOVERDICT 0  TIMEOUT 0  BUILD-ERROR 0  NOCHECK 1  SKIPPED 4
```

`sim/regress.sh --only llama_top` after the edit, which is where `attn_block`
is composed with `attn_kv_axi` over a multi-token sequence:

```
sim:tb_llama_top          PASS  116
sim:tb_llama_top_normw    PASS   79
sim:tb_llama_top_real     PASS   84
sim:tb_llama_top_seq      PASS  295
sim:tb_llama_top_smp      PASS    1
sim:tb_llama_top_smp_beh  PASS    2
OVERALL  PASS 6  FAIL 0  NOVERDICT 0  TIMEOUT 0  BUILD-ERROR 0  NOCHECK 0  SKIPPED 0
```

### 4.9 `tools/pack_int4.py`

Before, at `:791-795`, six literals: `n_gdn, n_attn = 48, 16`,
`d_inner, state_size = 6144, 128`, and
`kv_tok = n_attn * kv_heads * head_dim * 2 * 2`. After, `hbm_map.arena_sizes()`.
The printed block, MEASURED at `--cards 1`:

```
  residency beyond weights, per card (DERIVED by tools/hbm_map.py from rtl/, not restated here):
    shape            24 GDN + 8 attention layers, 32 val heads, 4 kv heads
    GDN state/layer  1048576 B mantissas + 4096 B exponents = 1052672 B
    KV record        16 B header + 256 x 8/8 B mantissas = 272 B
    GDN recurrent state (persistent)      24.1 MB
    KV cache per token                    17.0 KiB
```

against the old code's 72.0 MB and 64.0 KiB: **2.988x and 3.765x over**, which
reproduces KVSIZE's two factors from a third place. `--cards 2` halves both
(12.0 MB, 8.5 KiB). `--cards 3` now REFUSES, where it used to print a fraction
of a head:

```
hbm_map: the head counts do not divide across 3 cards (lin_val_heads 32,
attn_kv_heads 4).  model_cfg_pkg's val_heads_per_card asserts the same thing.
```

---

## 5. Verdict on every row of KVSIZE's table

| generic | proposed | verified? | verdict |
|---|---|---|---|
| `C_KV_BLOCK` | 32 | YES, MEASURED sweep | **SETTABLE.** Legal set {16,32,64,128}; 32 is `attn_kv_axi`'s own stated build geometry. |
| `C_MAXPOS` | 131072 | Arithmetic YES | **NOT SETTABLE.** `llama_top` caps at 61,680 even with `C_K_BASE = 0`, from `util_pkg.clog2`'s 2\*\*30 ceiling. |
| `C_K_BASE` | 4,521,582,592 | Arithmetic YES, = manifest `kv_base` | **NOT SETTABLE.** 2.11x `natural'high`. |
| `C_V_BASE` | `C_K_BASE + 8704*C_MAXPOS` | Formula YES, 8704 re-derived | **NOT SETTABLE.** Same wall. |
| `C_KV_ADDR_W` | 33 | Arithmetic YES | **SETTABLE but UNCHECKED.** The value is right; the guard at `:3812/:3834` cannot evaluate above 2\*\*30. |
| `C_CTXLEN` | `<= C_MAXPOS` | YES, unchanged | Correct as stated. |
| `attn_block` `LAYERS` | 8 | YES | **SET, together with `N_QH` 16 and `N_KVH` 4.** See section 6. |

---

## 6. Corrections, appended not edited

1. **"REALFIX ... made every guard DETECT rather than pass silently, so a wrong
   value should now refuse BY NAME -- verify that it does." PARTLY TRUE, and
   the distinction matters.** MEASURED: the `assert ... severity failure`
   guards (`llama_top:3845` overlap, `:3850` alignment) refuse with a full
   message naming the fault and printing the region size. The **`natural`
   constants REALFIX added** -- `CHK_HDR_FITS`, `CHK_KV_NBLK`, `CHK_KV_GRAN`,
   `CHK_KV_CTX`, `CHK_KV_ADDR` -- refuse with `bound check failure at
   <file>:<line>` and **no message at all**, because a `natural` constant
   cannot carry a report string. That is the mechanism's ceiling, not a bug:
   REALFIX chose it precisely because it fires during declarative elaboration
   and survives Vivado, which an assert does not. File and line is
   attributable; "by name" it is not. A reader who lands on
   `bound check failure at rtl/llama_top.vhd:3812` must go read :3808-3812 to
   learn which generic is wrong.
2. **The `C_MAXPOS = 61,681` refusal is genuinely UNATTRIBUTED**, and it is the
   worst diagnostic found here: `overflow detected ... from
   work.llama_top(rtl).clog2 at llama_top.vhd:785`. Line 785 is a `clog2` call
   that has nothing to do with the KV map. Nothing names `C_MAXPOS`,
   `C_KV_ADDR_W` or the KV cache. The brief's expectation that a wrong value
   would "refuse by name rather than produce an unattributed overflow" is
   exactly inverted for this one.
3. **`attn_block`'s `LAYERS` is NOT "the same defect" as `KV_LAYERS`.**
   `KV_LAYERS` in `tools/pack_model_fk33.py` was a live literal that sized a
   real HBM arena, and being wrong wasted 3.8x the reservation.
   `attn_block`'s `LAYERS` is a generic default that **every single consumer
   overrides** -- `sim/tb_attn_block.vhd:405` (2),
   `sim/tb_attn_kv_seam.vhd:502`, `rtl/llama_top.vhd:3952` (`C_LAY` = 8), and
   `sim/ooc_compose_bcd.tcl:73` (8) -- so no number anywhere was computed from
   it. Proven, not assumed, by T1b in section 4.8. It is a documentation
   defect.
4. **It was not only `LAYERS`.** `N_QH` 12 and `N_KVH` 2 were the same 27B
   two-card figures. Correcting `LAYERS` alone would have produced a default
   set describing **no model at all**: eight attention layers is 9B-on-one-card
   while twelve query heads and two KV heads is 27B-on-two-cards. This track
   therefore set all four to the 9B one-card shape, which is an **extension of
   the brief**, taken because `rtl/gdn_block.vhd:187` is the direct precedent
   in a sibling file and because `ooc_compose_bcd.tcl` already passes exactly
   that set. It is one three-line hunk and trivially revertible.
5. **`sim/ooc_compose_bcd.tcl:64-65` is now stale** and this track does not own
   it. It says "rtl/attn_block.vhd's defaults are 27B on ONE OF TWO cards
   (N_QH 12, N_KVH 2, LAYERS 16), so all four shape generics move". The
   generics it passes are still exactly right; only the reason is now wrong.
   Flagged, not edited.
6. **KVSIZE's "233,396 to the limit" leaves less margin than its own note
   says.** Confirmed to the byte: the pair ends at `0x1_FFADB000`, **2,048
   bytes** below `desc_arena_base`. That is half of one 4 KB page. Its own
   phrase "leaves no margin at all" is if anything generous.

---

## 7. The remediation, for whoever owns `rtl/llama_top.vhd`

**Do not widen the integer type.** GHDL's `integer` is 32-bit and VHDL-2008
does not offer a wider standard one; `natural'high` is a language-level fact
here, not a tool setting.

**Encode the bases in the record's own unit: 16-byte chunks.** The format
already requires 16-byte alignment (`llama_top:3850`, `attn_kv_axi:44-50`), so
no representable address is lost. DERIVED and checked:

```
C_K_BASE_CH = 4,521,582,592 / 16 =  282,598,912     (natural: fits, 13% of range)
C_V_BASE_CH = 5,662,433,280 / 16 =  353,902,080     (natural: fits, 16% of range)
REC_CH      = REC_B_C / 16       =           17
KVREG_CH    = C_LAY*C_NKVH*C_MAXPOS*REC_CH = 544*C_MAXPOS = 71,303,168 at 131,072

CHK_KV_ADDR := (C_KV_ADDR_W - 4)
             - clog2(maximum(C_K_BASE_CH, C_V_BASE_CH) + KVREG_CH)

  maximum + KVREG_CH = 353,902,080 + 71,303,168 = 425,205,248
  425,205,248 <= 2**30, so clog2 EVALUATES, and returns 29
  C_KV_ADDR_W - 4 = 33 - 4 = 29  ->  the check is 29 <= 29, satisfied EXACTLY
```

**`C_KV_ADDR_W = 33` is exactly right with zero slack**, which is the strongest
possible confirmation of KVSIZE's value: one bit less and the check fails, one
bit more and it is a wasted pin. `KBASE_C` becomes
`std_logic_vector(shift_left(to_unsigned(C_K_BASE_CH, C_KV_ADDR_W), 4))`.

Nothing in `rtl/attn_kv_axi.vhd` changes.

The remaining values then are:

```
C_KV_BLOCK   32
C_MAXPOS     131072
C_K_BASE_CH  282598912          -- 0x10D81E000 / 16
C_V_BASE_CH  353902080          -- C_K_BASE_CH + 544*C_MAXPOS
C_KV_ADDR_W  33
C_CTXLEN     <= C_MAXPOS
```

---

## 8. Measured and REJECTED -- do not retry

* **Do not set `C_K_BASE` to a byte address above 2,147,483,647.** MEASURED:
  `value not in range for generic 'c_k_base'`, before any guard in the design
  runs. This is not something a wider `C_KV_ADDR_W` fixes.
* **Do not set `C_MAXPOS` above 61,680 in `llama_top` as it stands**, at any
  base. MEASURED at 61,680 ok / 61,681 fail. The diagnostic points at
  `llama_top.vhd:785`, an unrelated `clog2` call, so this one will burn time if
  you meet it without this note.
* **Do not "fix" `util_pkg.clog2` by raising its loop bound.** The overflow is
  `v := v*2` reaching `2**31`; the function is correct for every argument a
  32-bit `natural` can meaningfully hold, and it is used by the whole tree. The
  KV map should stop asking it for 33-bit answers, not the reverse. (Not
  attempted; stated so the next reader does not.)
* **Do not use `LAYERS = 1` as a poison to prove a generic default is
  unread.** MEASURED: it does NOT bite. `clog2(1) = 0` gives
  `unsigned(-1 downto 0)`, a legal null range, and `attn_block` standalone
  elaborated rc=0 with it. Use `N_KVH = 5`, which breaks the
  `N_QH mod N_KVH = 0` assert and names itself.
* **Do not read `gdn_block.vhd:67` for the GDN state size** ("2 MiB at 9B"; it
  is 1 MiB) or `model_cfg_pkg.vhd`'s KV-capacity comment. KVSIZE rejected both;
  both re-confirmed wrong here. Use the port ranges and the constants.
* **Do not run a real pack to exercise `tools/pack_int4.py --audit`.** The 9B
  BF16 GGUF is 17 G on a root at 97 percent. `--audit` on the 880 M
  `mmproj-BF16.gguf` in the same directory reaches the changed block in about
  a minute and is enough to exercise it; the weight totals it prints are
  meaningless (it is a vision projector) and only the residency block was being
  tested.

---

## 9. Measurement traps hit, including my own

* **I nearly reported "the values do not verify".** They do. Five of six are
  arithmetically correct against the RTL and the manifest, and the sixth
  (`C_KV_ADDR_W`) is correct to the bit with zero slack. Reporting them as
  wrong would have sent the next track to re-derive numbers that were already
  right, and buried the actual defect, which is a **type**, not a value. The
  distinction only appeared because the values were passed to GHDL rather than
  checked on paper.
* **`ghdl -r ... 2>&1 | head` reports `rc=0` for the pipeline, not for GHDL.**
  My first `C_K_BASE` run printed `rc=0` immediately under an error message
  because `$?` after a pipe is `head`'s. Every rc in this document is taken
  from `${PIPESTATUS[0]}` or from an unpiped run.
* **A poisoned default that does not bite reads exactly like a default nobody
  uses.** T2 with `LAYERS = 1` returned rc=0 and I briefly took that as
  evidence for the claim I wanted. It is evidence of nothing; the poison was
  inert. The claim only became measurable with a poison shown to bite (T2b).
  This is the section-4.8 pair, and it is the reason both rows are printed.
* **`ref/attn_block_vec.c` takes the OUTFILE FIRST.** `sim/regress.sh:1273`
  lists the arguments as `16 4 2 4 8 3 4 0` and it is tempting to pass exactly
  that; `argv[1]` is the output path, so the shape shifts by one and the tool
  refuses with a message about `N_KVH >= 2` that describes a shape you did not
  ask for.
* **`hbm_map.arena_sizes(ncards=3)` raises `SystemExit`, inside a print
  block.** That is the correct behaviour and it is the RTL's own constraint,
  but it turns `pack_int4.py --audit --cards 3` from "prints a wrong number"
  into "exits after the weight table". Intentional, documented at the call
  site, and worth knowing before someone reports it as a regression.
* **`REALSHAPE GATE: PASS rows 19` is not evidence about the KV map.** Every
  one of its rows runs at `C_MAXPOS <= 4096` with bases under 36 MB, so the
  entire 32-bit wall is outside its coverage and always was. A green
  realshape_gate is compatible with a KV map that cannot be expressed.

---

## 10. Open, not yet answered

* **`attn_kv_axi`'s own run-time ceiling is 246,723 positions** at
  `LAYERS 8, N_KVH 4`, DERIVED from `rec_addr`'s
  `idx := (lay*N_KVH + hd)*MAXCTX + ps; ... idx*REC_B`, where `idx_max` is
  `32*MAXCTX - 1` and `(32*MAXCTX-1)*272` must fit a 32-bit `integer`. That is
  **above** the 233,396 the arena affords, by 5.7 percent, so it does not bind
  today. **It is a RUN-TIME expression inside a function, so elaboration does
  not catch it**; a future shape with more attention layers would silently
  overflow at the first record beyond the wall. Nothing checks this.
* **Whether `C_MAXPOS` should be 131,072 or 233,396 is still a decision, not a
  derivation.** Both fit. 131,072 is a power of two with 44 percent headroom;
  233,396 is the ceiling with 2,048 bytes of margin against the descriptor
  arena. This track verified both and set neither.
* **Nothing here elaborated `llama_top` at any realistic KV map**, because
  nothing can. The largest configuration measured is `C_MAXPOS 4096` with
  bases under 36 MB. Whether the real map elaborates once the chunk encoding
  lands is **unverified**, and section 7 is arithmetic plus one measured
  `clog2`, not an elaboration.
* **No value was checked.** Everything in this document is shapes, widths,
  ranges and addresses. That the KV cache computes correct numbers at any of
  these geometries is the `sim/tb_attn_kv_seam` family's question, not this
  one.
* **Vivado was not run.** REALFIX established that the `natural`-constant
  guards survive synthesis and the asserts do not; that result was relied on,
  not re-measured, because TRACK LUTDIET held the tool throughout.
