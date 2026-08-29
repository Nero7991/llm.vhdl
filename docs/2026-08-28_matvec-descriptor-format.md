# Subsystem A: the descriptor-in-memory control plane

**Date:** 2026-08-28
**Status:** specification, then implemented in `rtl/matvec_int4_desc_axi.vhd`
**Supersedes for the FK33:** the fixed AXI-Lite register map of
`rtl/matvec_int4_axi.vhd` (which is retained, unchanged, for the AXU3EG DDR
build -- see "What happens to the old map").

---

## 1. The question this answers

`rtl/matvec_int4_axi.vhd:252,265` asserts `NPORTS_W = 4` and `NPORTS_S = 1`,
because its register map holds exactly four `W_BASE`/`W_BASE_HI` pairs and one
`S_BASE`/`S_BASE_HI` pair. The FK33 geometry (spec 6.5a, `ROWS_IF = 48`,
`AXI_DW = 256`) needs **24 weight sub-region bases and 3 scale sub-region
bases**. Its own header states the objection to simply widening the map:

> a map whose shape moves with a synthesis generic is a map no host driver can
> parse

Oren's decision is the **descriptor-in-memory** shape. The AXI-Lite map stays
constant at any geometry; everything that grows with geometry lives in a block
of memory that the fabric fetches itself.

---

## 2. What was NOT invented here

Subsystem D already has a descriptor dialect and it is byte-pinned, so this is
written to **fit inside it rather than beside it**. From
`rtl/seq_desc_fetch.vhd` (its header, and the checks at `:462-535`):

* 64-bit words, **little-endian**, byte-pinned.
* A **64-byte header** at offset `0x00`, eight 64-bit words.
* The **base array at offset `0x40`**: `nsub_w` 64-bit weight bases followed by
  `nsub_s` 64-bit scale bases. `seq_desc_fetch` deliberately does not fetch it
  ("The base array (`nsub_w + nsub_s` 64-bit words at offset 0x40) is NOT
  fetched here"), which is precisely the hole subsystem A fills.
* **Pad bytes are `0x00` and that is CHECKED**, on the stated grounds that two
  conforming generators must produce byte-identical tables.
* Checks run **before** any unit is started (`S_CHECK` is a state of its own).
* Error codes are a 4-bit field; D uses `0x0..0x8`.

Everything above is reproduced verbatim below. The header layout of words 0..7
is D's, unchanged.

### 2.1 The one thing D's header cannot carry, and where it went

Subsystem A needs three values that D's 64-byte header has no field for:

| value | why D has no slot | why A needs it |
|---|---|---|
| `w_beats` | derivable in principle from `n_rows`, `n_cols` and the build's `ROWS_IF`/`BLK` | the derivation is `ceil(n_rows/ROWS_IF) * ceil(n_cols/BLK)`; `ROWS_IF = 48` is not a power of two, so in hardware it is a divide, on a path that has no reason to own one |
| `s_beats` | same | same, further divided by `GRP` |
| `x_exp` | it is a **per-token runtime** value in the integrated system (the BFP exponent of the activation vector the previous stage produced), not a per-matrix table constant | the standalone bring-up path has no previous stage, so it must come from somewhere |

They are therefore placed in an **A extension block that begins immediately
after D's base array**, i.e. at

```
E = 0x40 + 8 * (nsub_w + nsub_s)
```

This is the one placement that costs D nothing: `seq_desc_fetch` reads bytes
`0x00..0x3F` only, so **anything at or after `0x40` is invisible to it**. The
alternative -- putting the fields in D's reserved word 7 -- would have been
rejected by `seq_desc_fetch`'s own pad check at `:479`
(`pf_w(7) /= x"00000000_00000000"` is `ERR_DESC`), and changing that file is
not this track's to make.

**Consequence, stated plainly:** a descriptor written to this specification is
accepted by `seq_desc_fetch` unchanged. A descriptor written for
`seq_desc_fetch` alone (64 bytes, no base array, no extension) is **not**
accepted by subsystem A -- A needs the bases and the extension. That asymmetry
is deliberate and is the intended direction: D issues, A consumes.

---

## 3. The AXI-Lite map -- constant at every geometry

Word-addressed, `reg = addr[7:2]`, `C_S_AXI_ADDR_WIDTH = 8`.

| offset | reg | name | acc | meaning |
|---|---|---|---|---|
| `0x00` | 0 | `DESC_PTR_LO` | RW | descriptor byte address, low 32 bits |
| `0x04` | 1 | `DESC_PTR_HI` | RW | descriptor byte address, high 32 bits |
| `0x08` | 2 | `CTRL` | W | bit0 = `GO` (self-clearing) |
| `0x0C` | 3 | `STATUS` | R | see below |
| `0x10` | 4 | `ERR_INFO` | R | `[15:0]` failing descriptor word index; `0xFFFF` = the pointer itself |
| `0x14` | 5 | `ID` | R | `0x4D563449` ("MV4I") |
| `0x18` | 6 | `ADDR_CAP` | R | `ADDR_W` this build was synthesised with, in bits |
| `0x1C` | 7 | `CAPS` | R | `[7:0]` `NPORTS_W`, `[15:8]` `NPORTS_S`, `[23:16]` `ROWS_IF`, `[31:24]` `AXI_DW/8` |
| `0x20` | 8 | `DESC_WORDS` | R | descriptor length this build expects, in 64-bit words |
| `0x24` | 9 | `Y_IDX` | W | result row to present |
| `0x28` | 10 | `Y_LO` | R | `y[Y_IDX][31:0]` |
| `0x2C` | 11 | `Y_HI` | R | `y[Y_IDX][63:32]` |
| `0x30` | 12 | `Y_EXP` | R | block exponent |
| `0x34` | 13 | `CYCLES` | R | cycles busy, `GO` to done |
| `0x38` | 14 | `BEATS` | R | weight words the array consumed |
| `0x3C` | 15 | `STARVED` | R | cycles busy with no weight word available |

`STATUS`:

| bit | meaning |
|---|---|
| 0 | `done` (latched; cleared by the next `GO`) |
| 1 | `busy` |
| 2 | `err` (sticky until reset) |
| 3 | `sat_event` (sticky) |
| 4 | `err_addr` (sticky; an address did not fit `ADDR_W`) |
| 11:8 | `err_code` |

**Nothing in this table moves with `NPORTS_W`, `NPORTS_S`, `ROWS_IF`, `AXI_DW`
or `ADDR_W`.** `CAPS`, `ADDR_CAP` and `DESC_WORDS` are how a driver discovers
the build it is talking to instead of assuming it, which is the same argument
`ADDR_CAP` was added for on the old map.

**Not in the map, on purpose:**

* `N_ROWS`, `N_COLS`, `OUT_SHIFT`, `W_EXP`, `X_EXP`, `OUT_MODE`, `W_BASE*`,
  `S_BASE*`, `W_BEATS`, `S_BEATS`, `CB` -- all now descriptor fields.
* `X_IDX` / `X_DATA`. Activations arrive on the `x_we`/`x_waddr`/`x_wdata`
  port, one element per cycle, from the previous stage. An AXI-Lite
  element-at-a-time load of a 4096-element vector is a bring-up crutch that the
  FK33 has no use for, and keeping a register that nothing exercises is how a
  map grows a second dialect.

---

## 4. The descriptor block

All fields little-endian. Word `i` occupies bytes `8i .. 8i+7`. Within a beat
of `AXI_DW` bits, descriptor word `j` of that beat is bits
`[64j+63 : 64j]` -- the ordinary AXI little-endian lane mapping.
`AXI_DW mod 64 = 0` is asserted at elaboration.

### 4.1 Header, words 0..7 (bytes `0x00..0x3F`) -- D's layout, unchanged

```
word 0 : [7:0] opcode  [15:8] flags (u8)  [23:16] src_region
         [31:24] dst_region  [63:32] dst_offset
word 1 : [31:0] n_rows (u32)          [63:32] n_cols (u32)
word 2 : [31:0] w_exp (i32)           [63:32] out_shift (i32)
word 3 : [7:0] out_mode (u8)  [15:8] ordinal  [31:16] nsub_w (u16)
         [47:32] nsub_s  [55:48] src_region2  [63:56] PAD, must be 0
word 4 : [31:0] const_base            [63:32] const_exp (i32)
word 5 : codebook bytes 0..7   (entry j at bits 8j+7:8j, signed)
word 6 : codebook bytes 8..15
word 7 : PAD, must be 0
```

Subsystem A reads `opcode`, `flags`, `n_rows`, `n_cols`, `w_exp`, `out_shift`,
`out_mode`, `nsub_w`, `nsub_s` and the codebook. It ignores `src_region`,
`dst_region`, `dst_offset`, `ordinal`, `src_region2`, `const_base` and
`const_exp` -- those are D's routing fields and belong to whoever moves the
result, which on the FK33 is not this entity.

`opcode` must be `0` (`OP_A_JOB`). `flags` bit 2 is D's `cb_load`: when set,
words 5 and 6 are written into the codebook; when clear, the codebook already
in the core is reused.

### 4.2 Base array, words 8 .. 8+nsub_w+nsub_s-1 (from byte `0x40`) -- D's layout

```
word 8 + p                 = w_base[p], p = 0 .. nsub_w-1   (64-bit byte address)
word 8 + nsub_w + q        = s_base[q], q = 0 .. nsub_s-1
```

Each base is a byte address into the weight store (HBM on the FK33). Each must
be **4096-byte aligned**: `rtl/axi_rd_port.vhd`'s contract is "base must be
4 KB aligned", and the sub-region layout of spec 6.4 pads to whole 4 KB bursts
precisely so that it is.

### 4.3 Subsystem A extension, four words at `E = 0x40 + 8*(nsub_w+nsub_s)`

```
ext word 0 (E + 0x00) : [31:0]  ext_magic   = 0x4D563449  ("MV4I")
                        [47:32] ext_version = 0x0001
                        [63:48] ext_flags (u16), reserved, must be 0 in v1
ext word 1 (E + 0x08) : [31:0]  w_beats (u32)   beats per weight sub-region
                        [63:32] s_beats (u32)   beats per scale sub-region
ext word 2 (E + 0x10) : [31:0]  x_exp (i32)
                        [63:32] PAD, must be 0
ext word 3 (E + 0x18) : PAD, must be 0
```

`ext_magic` and `ext_version` sit here rather than in word 0 because word 0 is
D's and has no room. They are what makes "this block was written by a generator
that agrees with this gateware" a checked property rather than an assumption:
the extension's offset depends on `nsub_w + nsub_s`, so a generator that
disagrees with the build about the geometry lands the magic somewhere else and
is caught by `ERR_MAGIC` even before the geometry check fires.

### 4.4 Total size

```
DESC_WORDS = 8 + nsub_w + nsub_s + 4          (64-bit words)
DESC_BYTES = 8 * DESC_WORDS
```

| geometry | `nsub_w` | `nsub_s` | `DESC_WORDS` | `DESC_BYTES` | beats at that `AXI_DW` |
|---|---|---|---|---|---|
| AXU3EG, `ROWS_IF=4`, `AXI_DW=128` | 4 | 1 | 17 | 136 | 9 |
| FK33, `ROWS_IF=48`, `AXI_DW=256` | 24 | 3 | 39 | 312 | 10 |

The fetch reads `ceil(DESC_BYTES / (AXI_DW/8))` beats and ignores any trailing
words in the last beat.

**The fetch master is an `axi_rd_port`, not a hand-rolled one.** It was
hand-rolled first, in the core clock domain, and that MEASURABLY failed the
moment `DUAL_CLK` was switched on: the weight path had a clock-domain crossing
and the control path did not, so 17 of the 22 cases in
`sim/tb_matvec_fk33_desc.vhd` came back as `ERR_WDOG` or `ERR_MAGIC`. Reusing
`axi_rd_port` gives the descriptor the same crossing, the same burst splitting
and the same flush-on-start as a weight sub-region, and adds no new crossing to
reason about.

**Alignment of the pointer itself:** `DESC_PTR` must be aligned to
`DESC_MAXB * AXI_DW/8` bytes -- **512 bytes** at the FK33's `DESC_MAXB = 16`
and `AXI_DW = 256`. The RTL checks `DESC_PTR[8:0] = 0` there and raises
`ERR_ALIGN` otherwise.

That is stronger than the 64 bytes an earlier draft of this document asked for,
and the reason is worth recording. The descriptor is fetched by an ordinary
`rtl/axi_rd_port.vhd` instance -- the same entity, with the same clock-domain
crossing, that reads a weight sub-region. That port caps a burst at `MAXB`
beats but does **not** split at 4 KB. Aligning the pointer to
`DESC_MAXB * AXI_DW/8` makes every burst start at a multiple of that size and
be at most that long, so it lies inside one such block, and one such block lies
inside one 4 KB page because `DESC_MAXB * AXI_DW/8` divides 4096 (asserted at
elaboration). Alignment replaces a splitter.

The cost is 512 bytes of alignment padding per descriptor. At 250 packed
tensors that is 128 KB out of 8 GB of HBM, and it does not apply to subsystem
D's own 64-byte descriptor table, which A does not fetch.

---

## 5. What the hardware does with a malformed descriptor

**Every check runs before `start` reaches `matvec_int4`.** That ordering is
`seq_desc_fetch`'s S_CHECK discipline and the reason for it is the same: a
descriptor that is rejected after the array has begun consuming weights has
already read the wrong memory.

On any failure the wrapper: does **not** pulse `start`, drops `busy`, sets
`STATUS.err`, latches `err_code` and `ERR_INFO`, and stays latched until reset.
`done` is **not** set. A driver that polls `STATUS` for `done` therefore hangs
rather than reading stale results; a driver that polls for `done or err` gets
the code.

| code | name | condition | `ERR_INFO` |
|---|---|---|---|
| `0x0` | `ERR_NONE` | -- | -- |
| `0x3` | `ERR_DESC` | descriptor-class malformation: `opcode /= 0`; any pad field nonzero (word 3 `[63:56]`, word 7, ext word 2 `[63:32]`, ext word 3, `ext_flags`); `out_mode > 2`; `n_rows = 0` or `> MAXROWS_BFP`; `n_cols = 0` or `> MAXCOLS`; `w_beats = 0`; `s_beats = 0`; a job started with `cb_load = 0` before any codebook was ever loaded | word index |
| `0x4` | `ERR_WDOG` | the descriptor fetch did not complete within `WDOG_LIMIT` cycles | `0xFFFF` |
| `0x9` | `ERR_GEOM` | `nsub_w /= NPORTS_W` or `nsub_s /= NPORTS_S` | `3` |
| `0xA` | `ERR_MAGIC` | `ext_magic /= 0x4D563449` | ext word 0 index |
| `0xB` | `ERR_VER` | `ext_version /= 1` | ext word 0 index |
| `0xC` | `ERR_ALIGN` | `DESC_PTR` not aligned to `DESC_MAXB*AXI_DW/8`, or a base has `[11:0] /= 0` | `0xFFFF` for the pointer, else the base's word index |
| `0xD` | `ERR_ADDR` | `DESC_PTR` or a base has a bit set at or above `ADDR_W` | as above |
| `0xE` | `ERR_CORE` | `matvec_int4` raised `err` after a clean descriptor | `0xFFFF` |

Codes `0x1, 0x2, 0x5..0x8` are left unused so that D's own `ERR_UNIT`,
`ERR_LOCK`, `ERR_GRANT`, `ERR_CTX`, `ERR_EPOCH`, `ERR_ABORT` keep their
meanings if the two error spaces are ever merged.

`ERR_ADDR` also keeps the old map's **write-time** behaviour for the one
address register that survives: writing `DESC_PTR_HI` with a bit at or above
`ADDR_W` latches `STATUS` bit 4 immediately, before any `GO`, exactly as
`rtl/matvec_int4_axi.vhd` did for `W_BASE*_HI`/`S_BASE_HI`. That is deliberate:
"a driver that reads STATUS after programming the descriptor sees it before it
runs anything" is one of the few teeth the old wrapper had.

### 5.1 What is deliberately NOT checked

Stated so the next reader does not assume coverage that is not there:

* **A base that points at the wrong sub-region** but is well-formed (4 KB
  aligned, inside `ADDR_W`). Nothing in the descriptor says what a sub-region
  should contain, so the fabric cannot tell. This is detectable only by the
  weight store's own hash, which is a different mechanism at a different time.
* **`w_beats` / `s_beats` too small or too large** for the `n_rows`/`n_cols`
  they accompany. Checking would need the `ceil(n_rows/ROWS_IF)` divide that
  section 2.1 explains is why the fields exist at all. A too-small value
  starves the array; a too-large one reads padding. Both produce a wrong
  answer, not an error.
* `dst_region`, `dst_offset`, `src_region` -- A does not route its own result.

**And one liveness gap, measured rather than argued.** `WDOG_LIMIT` covers the
descriptor FETCH only. A `w_beats` that is too small starves the array, and the
design then waits forever: `sim/tb_matvec_fk33_desc.vhd` case 20 halves
`w_beats` and the job never completes and never errors. That is not a silent
wrong answer -- which is why it is not a correctness defect -- but a driver
polling `STATUS` for `done or err` hangs. Extending the watchdog over the
compute phase would close it; the limit is a per-geometry number and is
deliberately not chosen here.

---

## 6. What happens to the old map

`rtl/matvec_int4_axi.vhd` is **retained, byte-for-byte unchanged**, as a
separate entity. It is not folded into the new one behind a boolean generic.

The reason is the objection its own header raises. A `LEGACY_MAP : boolean`
generic would put both register decodes and both base-storage shapes in one
file, and the shape of that file's map would then move with a synthesis
generic -- which is the exact thing the old header refuses to do. Two entities,
one map each, is the honest expression of "there are two control planes".

Practical consequences:

* The AXU3EG DDR build and `hw/mv_driver.c` are untouched.
* `sim/tb_matvec_axi.vhd` keeps passing and keeps covering the old map,
  including its `ERR_ADDR` and `ADDR_CAP` behaviour.
* The FK33 build instantiates `matvec_int4_desc_axi`.
* Neither map is a superset of the other, and no code path chooses between them
  at run time.

---

## 7. Reference: building a descriptor (host side)

Pseudo-code, little-endian, for the FK33 geometry. This is the shape
`OI-4`'s descriptor-program generator will need; it is written here because the
format is now settled, not because the generator exists.

```c
uint64_t d[39] = {0};
d[0]  = 0;                                   /* opcode A_JOB, flags 0 ...   */
d[0] |= (uint64_t)(1u << 2) << 8;            /* ... flags bit2 = cb_load    */
d[1]  = (uint64_t)n_rows | ((uint64_t)n_cols << 32);
d[2]  = (uint32_t)w_exp  | ((uint64_t)(uint32_t)out_shift << 32);
d[3]  = (uint64_t)out_mode
      | ((uint64_t)24 << 16)                 /* nsub_w */
      | ((uint64_t)3  << 32)                 /* nsub_s */
      | ((uint64_t)0xFF << 48);              /* src_region2 = none          */
d[5]  = cb_lo8;  d[6] = cb_hi8;              /* 16 signed bytes             */
for (int p = 0; p < 24; p++) d[8 + p]      = w_sub_addr[p];
for (int q = 0; q <  3; q++) d[8 + 24 + q] = s_sub_addr[q];
int E = 8 + 24 + 3;                          /* = 35 */
d[E + 0] = 0x4D563449ull | (1ull << 32);     /* magic, version 1            */
d[E + 1] = (uint64_t)w_beats | ((uint64_t)s_beats << 32);
d[E + 2] = (uint32_t)x_exp;
d[E + 3] = 0;
```

`src_region2 = 0xFF` ("no region") in word 3 bits `[55:48]` is written because
A ignores the field but `seq_desc_fetch` range-checks it (`:509`); `0xFF` and
any value below `NREG` are both legal there, so this is a convention, not a
requirement. Likewise `dst_region = 0` above is legal for D only because
region 0 exists; a table meant to be walked by D must set the routing fields
to whatever that token's schedule actually needs. **A reads none of them.**

---

## 8. Open, not settled here

* **`x_exp` in the integrated system.** Carried in the extension because the
  standalone path needs it. When `llama_top` drives A, the activation
  producer's block exponent is a per-token value and the descriptor's copy is
  stale by construction. The wrapper therefore also exposes an `x_exp` port
  and a `USE_XEXP_PORT` generic; which one the FK33 build uses is an
  integration decision, not this document's.
* **Merging the two error spaces.** A's `0x9..0xE` and D's `0x1..0x8` are
  disjoint by construction but nothing enforces it across the two files.
* **`seq_desc_fetch` fetching the base array.** Still remaining work in D. Once
  it does, the base array has exactly one reader in the integrated system, and
  this document's section 4.2 is where the layout is written down.
