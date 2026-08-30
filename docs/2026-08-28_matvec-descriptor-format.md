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

**`w_beats` and `s_beats` are carried AND checked, and those are different
things.** As of the 2026-08-28 revision the wrapper verifies both against
`n_rows`/`n_cols` before starting anything (section 5.2). That does not make
the fields redundant: the check runs once per job in its own state and costs
`max(tiles, nblk)` cycles, whereas deriving the values would put a divide by
`ROWS_IF` on the path that issues them. Carrying the number is the cheap thing;
verifying it is the safe thing; deriving it is the expensive thing.

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
| `0x10` | 4 | `ERR_INFO` | R | `[10:0]` failing descriptor word index, `[15:11]` sub-case within `err_code`; `0xFFFF` = the pointer itself. See section 5.4 |
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

| code | name | condition | `ERR_INFO` sub-case | word |
|---|---|---|---|---|
| `0x0` | `ERR_NONE` | -- | -- | -- |
| `0x3` | `ERR_DESC` | `ext_flags` nonzero | 1 `ED_EXT_FLAGS` | ext word 0 |
| `0x3` | `ERR_DESC` | `opcode /= 0` | 2 `ED_OPCODE` | 0 |
| `0x3` | `ERR_DESC` | word 3 `[63:56]` nonzero (D's pad) | 3 `ED_PAD_W3` | 3 |
| `0x3` | `ERR_DESC` | word 7 nonzero (D's reserved word) | 4 `ED_PAD_W7` | 7 |
| `0x3` | `ERR_DESC` | ext word 2 `[63:32]` nonzero, or ext word 3 nonzero | 5 `ED_PAD_EXT` | ext word 2 **or** ext word 3, whichever it was |
| `0x3` | `ERR_DESC` | `out_mode > 2` | 6 `ED_OUT_MODE` | 3 |
| `0x3` | `ERR_DESC` | `n_rows = 0` | 7 `ED_ROWS_ZERO` | 1 |
| `0x3` | `ERR_DESC` | `n_rows > MAXROWS_BFP` | 8 `ED_ROWS_MAX` | 1 |
| `0x3` | `ERR_DESC` | `n_cols = 0` | 9 `ED_COLS_ZERO` | 1 |
| `0x3` | `ERR_DESC` | `n_cols > MAXCOLS` | 10 `ED_COLS_MAX` | 1 |
| `0x3` | `ERR_DESC` | `w_beats = 0` | 11 `ED_WBEATS_ZERO` | ext word 1 |
| `0x3` | `ERR_DESC` | `s_beats = 0` | 12 `ED_SBEATS_ZERO` | ext word 1 |
| `0x3` | `ERR_DESC` | a job started with `cb_load = 0` before any codebook was ever loaded | 13 `ED_CB_UNLOADED` | 0 |
| `0x4` | `ERR_WDOG` | the descriptor fetch did not complete within `WDOG_LIMIT` cycles | 31 (the pointer) | -- |
| `0x9` | `ERR_GEOM` | `nsub_w /= NPORTS_W` | 1 `EG_NSUB_W` | 3 |
| `0x9` | `ERR_GEOM` | `nsub_s /= NPORTS_S` | 2 `EG_NSUB_S` | 3 |
| `0xA` | `ERR_MAGIC` | `ext_magic /= 0x4D563449` | 0 | ext word 0 |
| `0xB` | `ERR_VER` | `ext_version /= 1` | 0 | ext word 0 |
| `0xC` | `ERR_ALIGN` | `DESC_PTR` not aligned to `DESC_MAXB*AXI_DW/8` | 31 (the pointer) | -- |
| `0xC` | `ERR_ALIGN` | a base has `[11:0] /= 0` | 0 | that base's word |
| `0xD` | `ERR_ADDR` | `DESC_PTR` has a bit at or above `ADDR_W` | 31 (the pointer) | -- |
| `0xD` | `ERR_ADDR` | a base has a bit at or above `ADDR_W` | 0 | that base's word |
| `0xE` | `ERR_CORE` | `matvec_int4` raised `err` after a clean descriptor | 31 (the pointer) | -- |
| `0xF` | `ERR_SHAPE` | `w_beats /= tiles*nblk` -- section 5.2 | 1 `ES_WBEATS` | ext word 1 |
| `0xF` | `ERR_SHAPE` | `s_beats*GRP < tiles*nblk` | 2 `ES_SBEATS_LO` | ext word 1 |
| `0xF` | `ERR_SHAPE` | `(s_beats-1)*GRP >= tiles*nblk` | 3 `ES_SBEATS_HI` | ext word 1 |

First match wins, in the order the rows appear above, which is the order the
`elsif` chain in `rtl/matvec_int4_desc_axi.vhd` has them.

Codes `0x1, 0x2, 0x5..0x8` are left unused so that D's own `ERR_UNIT`,
`ERR_LOCK`, `ERR_GRANT`, `ERR_CTX`, `ERR_EPOCH`, `ERR_ABORT` keep their
meanings if the two error spaces are ever merged.

**The 4-bit field is FULL and stays full.** `0x0`, `0x3`, `0x4` and `0x9..0xF`
are all assigned and `0x1, 0x2, 0x5..0x8` are D's.

**CORRECTION, 2026-08-29.** The line that stood here said "a further A-specific
code needs the field widened, not another value found." That was acted on and
is now withdrawn: a further A-specific *condition* takes a **sub-case** under an
existing code. Oren chose that route on 2026-08-29 over widening the field or
taking one of D's reserved values, and the reason is the constraint this whole
document exists to state -- **the descriptor's byte layout must not move.**
`ERR_INFO` is a register field, so subdividing it moves no descriptor byte and
invalidates no builder. See section 5.4.

### 5.4 `ERR_INFO`: a word index and a sub-case

    ERR_INFO[15:11]  sub-case, namespaced per err_code   (0 = none, 31 = the pointer)
    ERR_INFO[10:0]   failing descriptor word index

The two meanings **coexist**; the sub-case does not replace the word index. A
host decodes the PAIR `(err_code, sub-case)` for the diagnosis and reads
`[10:0]` for the word. That is load-bearing at the sites where one descriptor
word carries several checks -- word 3 holds `out_mode`, `nsub_w`, `nsub_s` and a
pad, and ext word 1 holds both beat counts -- and it is what lets `ED_PAD_EXT`
stay one sub-case while naming ext word 2 or ext word 3, whichever was nonzero.

`0xFFFF` is unchanged and now falls out of the scheme: sub-case 31 with word
2047. Sub-case 31 is reserved and means **the report is about `DESC_PTR`, not
about a descriptor word**; `[10:0]` carries nothing in that case.

**What this cost.** The word index is capped at 2047. `desc_words(24,3) = 39` at
the FK33, so the cap is 52x the longest descriptor this build produces and it
binds only past `NPORTS_W + NPORTS_S = 2036`. `matvec_int4_desc_axi` carries an
elaboration guard (`EI_WORD_FITS`, a `natural`, because Vivado ignores
`assert ... severity failure` in synthesis). Thirty sub-cases per code are
available; `ERR_DESC` uses thirteen.

**Sub-case 0 leaves `ERR_INFO` numerically unchanged** from the old
word-index-only encoding. Every site that is not subdivided still reports the
same integer it always did, so a host that has not been taught the split still
reads the right word for those -- and reads a conspicuously large number for the
subdivided ones, which is visible rather than silently wrong.

**WHY THIS WAS WORTH DOING, MEASURED.** At `3d5cba9`, seven distinct
`(err_code, ERR_INFO)` values were each reported by two or more different
checks, so a refusal at any of them could not be attributed. The two that were
on record in OI-9 -- `(3,0)` and `(3,3)` -- were a third of the real total. The
gate that found the rest is `check_sites()` in `sim/mv4i_desc_cases.py`, which
refuses to emit a case suite in which two different SITES expect the same pair.

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
  `sim/tb_matvec_fk33_desc.vhd` case 19 is this, in executable form: it aims
  weight sub-region 7's base at sub-region 8's bytes, and the design accepts,
  computes and reports success with 4 of 100 elements wrong.
* `dst_region`, `dst_offset`, `src_region` -- A does not route its own result.

**CORRECTION, 2026-08-28.** This section used to carry a third bullet --
"`w_beats` / `s_beats` too small or too large ... Checking would need the
`ceil(n_rows/ROWS_IF)` divide that section 2.1 explains is why the fields exist
at all" -- and a closing paragraph naming the resulting hang as an accepted
liveness gap. **Both are WITHDRAWN.** The claim that the fields cannot be
checked without a divide was wrong: the divide is only one way to compare a
quotient against a dividend, and multiplying up is another. The check is now
implemented and is section 5.2. What was right in that paragraph, and is worth
keeping, is why it mattered more than the other undetectable case: a too-small
`w_beats` is not a silent wrong answer, it is a **hang** -- the array starves,
`WDOG_LIMIT` covers the descriptor FETCH only, and a driver polling `STATUS`
for `done or err` waits for ever.

Three alternatives were weighed and rejected before the check was written:

* **A compute-phase watchdog.** Needs a per-geometry cycle limit, i.e. a tuned
  constant, and reports that something starved without saying why.
* **Both.** Doubles the verification surface for a defect the exact check makes
  unreachable.
* **A host-side timeout only.** A starved core still holds accepted AXI reads,
  and abandoning an accepted burst hangs the HBM channel permanently, which is
  worse than the bug.

### 5.2 The shape identity, and how it is checked without a divide

The identity, stated once, in the form the checker uses:

```
tiles   = ceil(n_rows / ROWS_IF)
nblk    = ceil(n_cols / BLK)
GRP     = NPORTS_S * AXI_DW / (ROWS_IF * 16)     synthesis constant
w_beats = tiles * nblk                           beats per WEIGHT sub-region
s_beats = ceil(tiles * nblk / GRP)               beats per SCALE  sub-region
```

**Where it comes from, and what it assumes.** Not from this document: from the
RTL and from the two independent host-side implementations that already agree
with it.

* `matvec_core.vhd:857-858` computes `nb_r = ceil(n_cols/BLK)` and
  `tiles_r = ceil(n_rows/ROWS_IF)`, and its issue FSM (`:617-620`) accepts
  exactly one weight word per `(tile, block)` step. So the core consumes
  `tiles * nblk` weight words, full stop.
* `matvec_core.vhd:517-518` drives `w_ready` and `s_ready` from the **same**
  signal, so exactly one scale GROUP is consumed per weight word.
* `weight_streamer.vhd` pops one beat from **every** weight port per delivered
  word (all-valid lockstep), so each weight sub-region owes one beat per word.
* `weight_streamer.vhd` pops one beat from **every** scale port per SUPERWORD,
  and a superword carries `GRP` groups, so each scale sub-region owes one beat
  per `GRP` words.
* `GRP` is an integer because `NPORTS_S*AXI_DW mod ROWS_IF*16 = 0` is asserted
  at elaboration (spec 6.5a). `matvec_int4_desc_axi` restates that assert AND
  gates it with a `natural` constant that goes negative if it is violated,
  because Vivado silently ignores `assert ... severity failure` and a
  truncated `GRP` would refuse every legal descriptor on the card.
* `tools/pack_int4.py:406-411` (`sub_sz`, `nsuper`) and `ref/mv_fk33_tr.c:136,138`
  compute the same two numbers independently. Three implementations, one
  identity.

**MULTIPLY UP, NEVER DIVIDE.** The check must not divide by `ROWS_IF`, which is
48 on the FK33 and is the whole reason the fields are carried. There is no
closed form that avoids it: the two inequalities

```
ROWS_IF * w_beats      >= n_rows * nblk
ROWS_IF * (w_beats - nblk) <  n_rows * nblk
```

are necessary but pin `w_beats` only to an interval of `nblk` consecutive
integers, of which exactly one is the right multiple of `nblk`; recovering
*which* is a divide again. So `tiles` and `nblk` are instead found by repeated
addition of the two synthesis constants -- a multiply written out longhand:

```
smallest t with t*ROWS_IF >= n_rows      accumulate ROWS_IF
smallest b with b*BLK     >= n_cols      accumulate BLK
```

both accumulators advancing in the same state, then **one** multiply
`prod = t*b`, then two verdicts:

```
w_beats = prod
(s_beats - 1) * GRP  <  prod  <=  s_beats * GRP
```

The `s_beats` bracket is the ceil expressed by multiplying the synthesis
constant `GRP`, so no divide appears there either.

**Cost, stated rather than hidden.** The loop runs `max(tiles, nblk)` cycles:
544 at `MAXCOLS = 17408 / BLK = 32`, 128 in `sim/tb_matvec_fk33_desc`. It gates
a job that is at least `tiles*nblk` cycles long and `nblk >= 1`, so the loop can
never exceed the compute it precedes; at a real shape (4096 x 4096 at
`ROWS_IF = 48`) it is 128 cycles against 11,008, under 1.2%. Two adders, two
comparators, one multiplier. No divider, no magic reciprocal, no tuned
constant.

**What it does NOT cover.** It says nothing about whether the bases point at
the right bytes -- that is still section 5.1's first bullet and still needs a
hash over the weight store.

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

**`w_beats` and `s_beats` are not free parameters.** The gateware refuses the
descriptor with `ERR_SHAPE` unless

```c
int tiles   = (n_rows + ROWS_IF - 1) / ROWS_IF;
int nblk    = (n_cols + BLK     - 1) / BLK;
int GRP     = NPORTS_S * AXI_DW / (ROWS_IF * 16);   /* 1 on the FK33 */
    w_beats = tiles * nblk;
    s_beats = (tiles * nblk + GRP - 1) / GRP;
```

`ROWS_IF`, `BLK`, `NPORTS_S` and `AXI_DW` all come from the `CAPS` register, so
a generator can compute this from the build it is actually talking to rather
than from a constant it was compiled with. Section 5.2 is why this is a check
and not merely a convention.

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
* **Merging the two error spaces.** A's `0x9..0xF` and D's `0x1..0x8` are
  disjoint by construction but nothing enforces it across the two files, and
  the 4-bit field is now full on A's side (section 5).
* **`rtl/matvec_core.vhd:835` reads `ybuf(TILES)` at the top of the row
  range.** Found 2026-08-28 by the section 5.2 shape sweep, deliberately NOT
  fixed here because `matvec_core` is not this track's file. `ybuf` is indexed
  `0 to TILES-1` (`:191`), `rd_t` is an unconstrained integer (`:389`) that
  `S_EMIT` advances to `tiles_r` (`:883-884`), and `:835` reads `ybuf(rd_t)`
  unconditionally every cycle. So whenever `ceil(n_rows/ROWS_IF) = TILES` --
  that is, whenever `n_rows` is in the top `ROWS_IF` rows of the declared
  `MAXROWS_BFP` range -- the last emit cycle indexes one past the array.
  MEASURED at `MAXROWS_BFP = 192 / ROWS_IF = 48`: `n_rows = 145` and
  `n_rows = 192` each abort with
  `index (4) out of bounds (0 to 3) at rtl/matvec_core.vhd:835`.
  Synthesis-benign (`rd_v` is `'0'` that cycle, so nothing consumes `ybuf_q`)
  and simulation-fatal, which is the same shape as worklog OI-7. **It bites
  hardest for a build that sets `MAXROWS_BFP` to the exact `n_rows` it needs
  in order to save BRAM, because then EVERY job trips it.** The shape sweep
  stays below the trap and says so in its own comment rather than routing
  around it silently.
* **`seq_desc_fetch` fetching the base array.** Still remaining work in D. Once
  it does, the base array has exactly one reader in the integrated system, and
  this document's section 4.2 is where the layout is written down.
