# Can the packer put each tensor's 27 sub-regions on 27 different HBM pseudo-channels, and does the KV cache still fit?

**Date:** 2026-08-30. Branch `fpga`. **TRACK PACKSTRIPE.**
**No hardware was touched.** The card is unconfigured. Nothing below opened
`/dev/xdma*`, ran `xsdb`, `hw_server`, `vivado ... program`, or anything under
`hw/fk33/tcl/`. Section 8 is a test for Oren to run and it is the only part of
this document that needs a card.

**Tools named:** `python3` over `tools/pack_model_fk33.py`,
`tools/pack_int4.py`, `tools/gen_mv4i_desc.py`, `tools/hbm_map.py`,
`tools/check_mv4i_set.py`, `tools/check_hbm_stack.py`,
`hw/fk33/host/fk33_run_job.py --dry-run`; `cc` building `ref/mv_fk33_tr.c`;
`git show`, `git diff`.

**Files read as the authority:** `hw/fk33/gen_pcieep.py` (`ENG_PORT_MAP`, the
`ENGINE_ADDR` block), `hw/fk33/rtl/fk33_engine.vhd` (which master is which
lane), `tools/gen_mv4i_desc.py` (`check_bases`, `layout_strides`,
`build_descriptor`), `tools/hbm_map.py` (`manifest_regions`,
`derive_region_block`), `hw/fk33/host/fk33_load_weights.py` (`cmd_load`,
`_verify`), `hw/fk33/host/fk33_run_job.py` (`make_plan`, `run_job`),
`server/fk33_manifest.c`, `docs/2026-08-28_can-27-read-masters-be-served.md`,
`docs/debugging/2026-08-30_counters-cycles-beats-starved.md`.

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement with its assumption stated).

---

## 1. The question, verbatim

> **Stripe each tensor's 27 sub-regions across 27 distinct HBM segments, so
> every master gets its own directly attached pseudo-channel.**
>
> 1. The mapping, argued not assumed -- read `ENG_PORT_MAP` out of
>    `hw/fk33/gen_pcieep.py` rather than trusting the brief.
> 2. The capacity problem, settled with arithmetic. TRACK COUNTERS flagged
>    187.3 MB of weights per segment against a 268.4 MB segment as "close but
>    not closed", with the KV cache and the GDN state left to fit in the tails.
>    If it does not fit, say so with numbers and propose the fallback.
> 3. The repack, in `tools/pack_model_fk33.py`, behind a flag or a version
>    bump so the existing packed set is not silently invalidated.
> 4. A verification that the repack changed ADDRESSES and not VALUES.
> 5. The decisive on-card test, as a copy-pasteable command list, with the
>    prediction stated in advance so it can fail.

---

## 2. The answers, up front

**1. The mapping is not what the brief said, and the difference matters.**
`ENG_PORT_MAP` has **28** entries, not 27, and its last entry is the
DESCRIPTOR FETCH master, not a data lane. MEASURED by scraping the file and
cross-reading `hw/fk33/rtl/fk33_engine.vhd`'s per-port comments:

| descriptor field | engine master | SAXI port | HBM segment | stack |
|---|---|---|---|---|
| `w_base[0..14]` | m00..m14 | `SAXI_01..15` | 1..15 | 0 |
| `w_base[15..23]` | m15..m23 | `SAXI_17..25` | 17..25 | 1 |
| `s_base[0..2]` | m24..m26 | `SAXI_26..28` | 26..28 | 1 |
| (descriptor fetch) | m27 | `SAXI_29` | 29 | 1 |

**Reserved, and none of them may hold a lane arena: 0 and 16 are the HOST's
(`SAXI_00`/`SAXI_16`), 29 is the descriptor master's, 30 and 31 are attached to
no engine master at all.** The brief named only segment 16.

Because master index and SAXI index track each other across the 16-port stack
split, **every lane is stack-local for free**: lanes 0..14 read stack 0,
lanes 15..26 read stack 1, exactly the 15/12 split
`docs/2026-08-28_can-27-read-masters-be-served.md` section 5 recommended. The
flat layout could never make more than 15 of the 27 masters stack-local at once
and `tools/pack_model_fk33.py`'s own docstring said so.

**2. It fits, comfortably, and the brief's framing of the capacity problem was
wrong. The cost is not capacity, it is CONTIGUITY.**

MEASURED over the live 249-file `qwen35-9b-mv4i-noembd` set, per lane:

```
per-lane need   165,994,496 B = 158.30 MiB   identical on all 27 lanes
segment          268,435,456 B = 256.00 MiB
fill                                61.8%    97.70 MiB spare per segment
```

COUNTERS' 187.3 MB was computed on the older 250-file set that still carries
`token_embd.weight`; that set is not what the card runs. On it the figure is
**178.42 MiB, 69.7% fill** -- also comfortable. Neither set is close to the
wall. **Total free space is essentially unchanged by striping** (3.826 GiB
striped against 3.808 GiB flat).

What changes is the SHAPE of the free space. It becomes 27 tails of 97.70 MiB
plus segment 16, and the KV cache cannot use any of it, because
`rtl/attn_kv_axi.vhd` addresses KV from one linear base (`C_K_BASE_CH`,
cross-checked by `tools/check_kv_map.py`) and `server/fk33_manifest.c:170`
requires `gdn_state_base >= weights_end`. So KV gets only what lies above the
highest lane arena. MEASURED, from `hbm_map.py --markdown` on the two maps:

| | flat (shipping) | lane-striped | ratio |
|---|---|---|---|
| KV arena | 4,062,965,760 B | 774,656,000 B | **0.191x** |
| context | **233,396 tokens** | **44,500 tokens** | **0.191x** |
| unusable | 8,876,032 B of stack hole | 3,194,744,832 B in 27 tails | |

**44,500 tokens is the price, and it is the only price.** Section 6 costs three
fallbacks that buy context back.

**3. Done, as `--stripe-lanes` in `tools/pack_model_fk33.py`, with a manifest
`format` bump to `"llama.vhdl FK33 load manifest v2 lane-striped"`.** The
version bump is not decoration: under striping `files[].hbm_offset` names a
4 KB HEADER and no longer the base of `nbytes` contiguous bytes, so a v1
consumer that reads the pair would place, verify or describe the image wrong
while reporting success. Two existing consumers were run against the striped
manifest and **REFUSED it correctly** (`hbm_map.py`: 249 faults;
`check_mv4i_set.py`: 249 failures) -- section 7.1.

**4. The repack changed no values, and it changed none because there was no
repack.** The `.mv4i` bytes are a function of the tensor and the geometry, not
of the address, so `--stripe-lanes` over an existing set re-places and does not
re-quantize. MEASURED, four ways, with coverage stated (section 5):

```
A  250 of 250 objects, blake2b-128 and size identical to the flat manifest
B  249 of 249 mv4i, piece file offsets agree with BOTH of gen_mv4i_desc.py's
   independent rules (the file's own 0x38 table, and spec 6.5a from the shape)
C  6,723 of 6,723 lane sub-regions: the bytes at the striped address are the
   same bytes the flat descriptor's base pointed at
D  249 of 249 whole-file digests rebuilt by reading the pieces in order
```

**5. The decisive test is section 8 and it is runnable today with no modified
tool.** Prediction, stated in advance: `blk.0.ffn_gate.weight --rows 100`
(K=4096, 3 tiles, BEATS=384) moves from **CYCLES 8,300-8,900 flat** to
**CYCLES under 1,500 striped**, DERIVED target **~613**, and **VERDICT stays
PASS in both arms** because the oracle comparison is unchanged.

**The one-sentence correction to the brief:** the fix is a packer change AND a
consumer change. `tools/pack_model_fk33.py` can decide the addresses on its
own, but `tools/hbm_map.py`, `tools/gen_mv4i_desc.py`,
`hw/fk33/host/fk33_load_weights.py` and `hw/fk33/host/fk33_run_job.py` all
model a tensor as ONE contiguous extent and each needs to learn `pieces`
before the striped set can be loaded, described or verified in production.
None of them was touched. Section 7 specifies each delta. **`ref/mv_fk33_tr`
needs NO change** -- the brief expected it to, and it does not, because it
emits sub-region OFFSETS and never an HBM address.

---

## 3. The procedure, in the order it was run

| # | step | what it isolates |
|---|---|---|
| 1 | scrape `ENG_PORT_MAP` + `ENG_NMAST` from `gen_pcieep.py`; re-assert its own four invariants | that the segment assignment comes from the file that emits the `connect_bd_intf_net` lines, not from a copy |
| 2 | cross-read `fk33_engine.vhd`'s 28 `-- HBM SAXI master N:` comments | which master is a weight lane, which is scale, which is the descriptor fetch. The brief assumed 27 data lanes fill the map; they do not |
| 3 | sum per-lane bytes over the live manifest via `pack_int4.packed_layout` | the capacity question, before any code was written |
| 4 | `hbm_map.py --markdown` on the SHIPPING flat manifest | the control. `PASS`, 233,396 tokens |
| 5 | implement `--stripe-lanes` + six teeth-checked invariants | the placement |
| 6 | run it over an outdir of hardlinks to the existing packed set | zero repack, zero extra bytes, and the digests become the value oracle |
| 7 | four-part addresses-not-values oracle (section 5) | the whole risk |
| 8 | ten mutations of the plan, each re-scored against all six checks | the attribution control: WHICH check bit, not just that one did |
| 9 | `hbm_map.py --markdown` on the striped manifest, and on its piece-expanded view | separates "the placement is wrong" from "the consumer cannot read the placement" |
| 10 | `fk33_run_job.py`-driven probe, dry-run, plus six refusal teeth | that the card test's plumbing works before Oren spends a card on it |

---

## 4. The evidence, raw

### 4.1 The mapping, MEASURED

`hw/fk33/gen_pcieep.py:307-328`, verbatim:

```python
ENG_NMAST      = 28
...
ENG_PORT_MAP   = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29]

assert len(ENG_PORT_MAP) == ENG_NMAST, "port map length"
assert len(set(ENG_PORT_MAP)) == ENG_NMAST, "port map has a duplicate"
assert 0 not in ENG_PORT_MAP and 16 not in ENG_PORT_MAP, \
    "SAXI_00 and SAXI_16 belong to the host"
assert all(1 <= x <= 31 for x in ENG_PORT_MAP), "port index out of range"
```

`hw/fk33/rtl/fk33_engine.vhd`, the 28 role comments (MEASURED, `grep`):

```
117:    -- HBM SAXI master 0: weight lane 0
...
837:    -- HBM SAXI master 24: scale lane 0
867:    -- HBM SAXI master 25: scale lane 1
897:    -- HBM SAXI master 26: scale lane 2
927:    -- HBM SAXI master 27: descriptor fetch
```

`gen_pcieep.py`'s `ENGINE_ADDR` block, which fixes the granule:

```tcl
        assign_bd_address \
            -target_address_space [get_bd_addr_spaces ENGCELL/${m}_axi] \
            -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \
            [get_bd_addr_segs [format "hbm/SAXI_%02d/HBM_MEM%02d" $sx $s]]
```

`0x10000000` x `256M` for `s` in 0..31, so **address bits [32:28] select the
pseudo-channel**. `scrape_eng_port_map()` asserts both of those literals are
still in the file, because striping at the wrong granule puts every lane back
on one pseudo-channel and looks like it worked.

### 4.2 The corroboration COUNTERS did not cite

`docs/2026-08-28_can-27-read-masters-be-served.md` section 2.2, MEASURED on
this exact part with this exact HBM configuration:

> Oversubscription sweep, all 30 masters onto one pseudo-channel: **9.60 GB/s
> total, flat** from 1 master to 30.

That is the diagnosis stated as a hardware measurement rather than as an
inference: thirty masters aimed at one pseudo-channel deliver what one does.
The card's MEASURED aggregate under the flat layout is 7.39-7.88 GB/s, which
is the 8.000 GB/s a single 256-bit port at ACLK 250 MHz can pass, and that port
bound sits below the 9.60 GB/s pseudo-channel bound -- so at 250 MHz the port
is the limit and COUNTERS' arithmetic is the right one to quote.

The same document's section 5 already recommended this exact placement in
April of this project's life -- "one arena per pseudo-channel, port-local
addressing, 15 lanes on stack 0 and 12 on stack 1" -- and noted that "which HBM
port reads which sub-region is an arena-placement decision in the host loader,
not a file-format decision". This change is that decision, finally taken.

### 4.3 The per-lane budget, MEASURED

`python3` over `manifest.json` + `pack_int4.packed_layout`, live 249-file set:

```
qwen35-9b-mv4i-noembd  mv4i files = 249  npw/nss = 24 3
  manifest hbm.weights_bytes  = 4487442432
  sum of all sub-regions      = 4481851392  (99.9% of weights_bytes)
  headers (4KB x 249)         = 1019904
  nonmatvec_f32.bin           = 4571136
  weight lane need  min/max   = 165994496 / 165994496
  scale  lane need  min/max   = 165994496 / 165994496
  per-lane need (all 27 equal?) True
    lane W00  -> master  0 -> SAXI_01 -> seg  1  stack 0  fill 61.8%
    ...
    lane W14  -> master 14 -> SAXI_15 -> seg 15  stack 0  fill 61.8%
    lane W15  -> master 15 -> SAXI_17 -> seg 17  stack 1  fill 61.8%
    ...
    lane S2   -> master 26 -> SAXI_28 -> seg 28  stack 1  fill 61.8%
  total spare in the 27 lane segments = 2765905920 B = 2.576 GiB
```

**The 27 lanes are equal by COINCIDENCE, not by rule, and the code does not
assume it.** At the FK33 geometry GRP = 1, so `gen_mv4i_desc.layout_strides`'s
scale stride equals its weight stride; at GRP > 1 a scale lane would need
1/GRP as much. That same coincidence already made a two-rule cross-check in
`gen_mv4i_desc.py` decoration for months. `lane_stripe_plan()` sizes every lane
from its own sub-region sizes.

### 4.4 The two maps, MEASURED by `tools/hbm_map.py --markdown`

Flat, the shipping set, and the control for everything below:

```
| region | base | end | bytes | GiB |
| packed weights + F32 blob | 0x0 | 0x1_0b78_f000 | 4,487,442,432 | 4.1793 |
| gdn recurrent state | 0x1_0c00_6000 | 0x1_0d81_e000 | 25,264,128 | 0.0235 |
| kv arena 0 | 0x1_0d81_e000 | 0x1_ffad_d000 | 4,062,965,760 | 3.7839 |
| A descriptor arena | 0x1_ffad_d000 | 0x1_ffb0_4000 | 159,744 | 0.0001 |
| host R_X staging | 0x1_ffb0_4000 | 0x1_fff0_c000 | 4,227,072 | 0.0039 |
| host logits writeback | 0x1_fff0_c000 | 0x1_ffff_e840 | 993,344 | 0.0009 |
| host D program | 0x1_ffff_f000 | 0x2_0000_0000 | 4,096 | 0.0000 |
note: <kv arena 0> ... 233396 tokens at 17408 B/token, after the charge
PASS  every region is aligned, in range, in one stack, and disjoint across all 3 allocators
```

Lane-striped, over the piece-expanded extent list (6,973 extents):

```
| packed weights + F32 blob | 0x0 | 0x1_0b78_f000 | 4,487,442,432 | 4.1793 | 6973 objects, 3194744832 B of stack-line hole |
| gdn recurrent state | 0x1_d000_0000 | 0x1_d181_8000 | 25,264,128 | 0.0235 |
| kv arena 0 | 0x1_d181_8000 | 0x1_ffad_d000 | 774,656,000 | 0.7215 | 44500 tokens at 17408 B/token |
| A descriptor arena | 0x1_ffad_d000 | 0x1_ffb0_4000 | 159,744 | 0.0001 |
| host R_X staging | 0x1_ffb0_4000 | 0x1_fff0_c000 | 4,227,072 | 0.0039 |
| host logits writeback | 0x1_fff0_c000 | 0x1_ffff_e840 | 993,344 | 0.0009 |
| host D program | 0x1_ffff_f000 | 0x2_0000_0000 | 4,096 | 0.0000 |

device      8,589,934,592 B = 8.0000 GiB
accounted   8,487,491,648 B = 7.9046 GiB
unaccounted   102,442,944 B
PASS  every region is aligned, in range, in one stack, and disjoint across all 3 allocators
```

**The descriptor arena and the three host blocks are at IDENTICAL addresses in
both maps.** That is not luck and it is worth stating: `derive_region_block()`
anchors them to the top of the device from `n_embd`, `n_vocab` and
`max_chunk`, so they do not move with the weight placement. It also means the
striped map needs no change to `server/pl_backend.c` or its mirror.

### 4.5 The packer's own output

```
  stripe check 1 every piece is in its master's own segment               PASS  0 violation(s)
  stripe check 2 every piece 4 KB aligned in HBM and in the file          PASS  0 violation(s)
  stripe check 3 the pieces tile the file exactly, in order               PASS  0 violation(s)
  stripe check 4 no two pieces overlap in HBM                             PASS  0 of 6971 adjacent pairs
  stripe check 5 every lane arena fits its segment                        PASS  max fill 61.8%
  stripe check 6 every tensor's 27 data pieces are in 27 DISTINCT segments PASS  0 tensor(s) not fully striped
  A job count      311 descriptors, the max over the four program variants

wrote /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json
  weights          4487442432 B  4.179 GiB  (52.2 % of 8 GiB)
  GDN state        24.1 MB at 0x1d0000000
  dropped          1 tensor(s), 572207104 B (0.533 GiB) NOT placed: token_embd.weight
  qkv segment pad  on, 24 fused tensor(s) padded
  lane stripe      ON, 27 lanes on segments 1,2,3..28 at 256 MiB each
    per lane       165994496 B = 158.30 MiB, 61.8% of a segment (min 165994496, max 165994496)
    segment 0      5591040 B of headers + nonmatvec_f32.bin
    reserved segs  [0, 16, 29, 30, 31]
    UNUSED         2765905920 B = 2.576 GiB in the 27 segment tails, plus whole
                   reserved segments.  Only an extent-aware KV consumer can use
                   them; hbm.kv_extents is already emitted
  stack holes      0 B  0.0 MiB in 0 hole(s)
  free for KV      0.726 GiB from 0x1d1818000 => 44809 tokens of context
  A desc arena     159744 B at 0x1ffadd000 for 311 descriptors at 512 B
  host blocks      x_base 0x1ffb04000 l_base 0x1fff0c000 desc_ptr 0x1fffff000
  total elapsed    7.9 s
```

7.9 seconds, and **not one byte of model data was written**: the outdir is
hardlinks into the existing set and every file reported `kept`. Disk cost of
the whole striped set is the 1,169,722-byte manifest. `df` before and after:
386 G free on `/mnt/storage`, unchanged. The shipping
`qwen35-9b-mv4i-noembd/manifest.json` still has its 2026-08-29 18:07 mtime.

(`free for KV` says 44,809 and `hbm_map` says 44,500. The packer counts to the
top of the device; `hbm_map` subtracts the 5,386,240 B of top-anchored host
reservations = 309 tokens. Both numbers are right about different questions and
the map's is the one to quote.)

---

## 5. Addresses changed, values did not -- the oracle, with coverage stated

Run by `/mnt/storage/track-packstripe/verify_stripe.py`. Every part compares
against something that did not produce the striped manifest.

```
flat  format 'llama.vhdl FK33 load manifest v1'  250 objects
strp  format 'llama.vhdl FK33 load manifest v2 lane-striped'  250 objects

A  VALUES
   objects in the striped manifest      250
   compared against the flat manifest   250   (COVERAGE: 250 of 250)
   in flat but not in striped           0 []
   in striped but not in flat           0 []
   digest or size CHANGED               0 []
   -> PASS every byte identical

B  PIECE FILE OFFSETS vs tools/gen_mv4i_desc.py (both of its rules)
   mv4i objects                         249   (COVERAGE: 249 of 249)
   disagreements                        0 []
   -> PASS

C  BYTES AT THE STRIPED ADDRESS == BYTES THE FLAT DESCRIPTOR POINTED AT
   mv4i objects read                    249
   lane sub-regions compared            6723   (expect 6723)
   mismatches                           0 []
   -> PASS

D  WHOLE-FILE DIGEST REBUILT FROM THE PIECES (what a piece-aware verify does)
   objects                              249   (COVERAGE: 249 of 249 mv4i)
   digest mismatches                    0 []
   -> PASS
```

**Why each one is an oracle and not a round trip.** A is the packer's
pack-time digest of bytes it did not rewrite, compared against a manifest
written on 2026-08-29. B compares against `gen_mv4i_desc.py`'s two rules, one
of which reads the file's own 0x38 offset table and the other of which computes
from the shape alone; neither knows striping exists. C reads real bytes off
disk at both offsets rather than comparing arithmetic to arithmetic. D is the
computation a piece-aware `fk33_load_weights.py verify` would perform, proving
in advance that the existing pack-time digest stays checkable after the change.

**The coverage hole the brief warned about was already fixed.**
`fk33_load_weights.py::_verify` carries the 2026-08-29 note in full: 250
objects in, "249 headers parsed and matched", PASS, the missing one being
`nonmatvec_f32.bin` because check 1 was gated on `kind == "mv4i"` and check 2
was skipped in headers-only mode. It now digests headerless objects even in
headers-only mode and prints the coverage rather than letting the reader infer
it. Nothing here re-opens it; it is named so the next reader does not go
looking.

### 5.1 Teeth: ten mutations, each scored against all six checks

`/mnt/storage/track-packstripe/teeth_stripe.py`. The right column IS the
attribution control -- it names which checks fired, not merely that one did.

| mutation | verdict | checks that FAILED |
|---|---|---|
| M1 one w piece moved a whole segment up | KILL | 1, 4 |
| M2 two lanes SWAPPED (still 27 distinct segments) | KILL | **1 only** |
| M3 one piece misaligned by 1 byte | KILL | 2, 4 |
| M4 one piece 4096 B short (file no longer tiled) | KILL | **3 only** |
| M5 one tensor restored to the FLAT contiguous layout | KILL | 1, 4, 6 |
| M6 two tensors given the same lane-0 address | KILL | **4 only** |
| M7 a lane arena declared past its segment | KILL | **5 only** |
| M8 a piece moved into its OWN segment free tail | **survives** | (none) |
| M9 two tensors swap their lane-0 arenas | **survives** | (none) |
| M10 a header moved elsewhere inside segment 0 | **survives** | (none) |

**CHECK 6 EARNED ZERO INDEPENDENT KILLS AND IS DECORATION BY THIS PROJECT'S
OWN DEFINITION.** It fired only on M5, alongside checks 1 and 4. That is not an
accident: `scrape_eng_port_map()` refuses a `ENG_PORT_MAP` with a duplicate, so
check 1 (every piece in its master's own segment) logically IMPLIES check 6
(27 distinct segments). M2 is the case that shows the implication does not run
the other way -- two lanes swapped still occupy 27 distinct segments and check 6
sees nothing, while check 1 catches it. **Check 6 is kept only as the
human-readable statement of what the change is for, and it is labelled here so
nobody credits it with catching anything.** Check 1 is the load-bearing one.

**The three survivors are the resolution floor and two of them are not
defects.** M8 and M10 move a piece to a different address INSIDE the segment
its lane owns; that is a legal placement and refusing it would be a check that
fails on a safe configuration. **M9 is a real defect that these checks cannot
see**: two tensors swapping a lane arena is a well-formed placement in which
one lane reads the wrong tensor's bytes. Nothing structural can catch it,
because structurally it is correct. What catches it is
`fk33_load_weights.py verify` reading HBM back and finding the per-file
blake2b wrong, and on the card the oracle comparison in `fk33_run_job.py`.
**Say this out loud: the placement checks in this change are NOT a residency
check and do not replace one.**

### 5.2 Teeth: the on-card probe's own refusals

`docs/debugging/2026-08-30_packstripe-stripe_probe.py` against five mutated
manifests:

```
T1    rc=2  refusing: w[0] is at file +4096 in the descriptor and +8192 in the striped manifest
T2    rc=2  refusing: the striped manifest's digest for blk.0.ffn_gate.weight.mv4i is 000...0
              and the flat manifest's is f0bb2c66fd3c0bd3be457746e0aed406.  The two manifests do
              not describe the same bytes, so the relocation would move a DIFFERENT tensor.
T3    rc=2  refusing: w[1] base 0x12142000 is in segment 1 and the manifest labels it 2
T3b   rc=2  refusing: 26 distinct segments, wanted 27 -- this would NOT be the experiment
T4    rc=2  refusing: w[0] striped base 0x12142001 is not 4 KB aligned; the gateware answers EC 0xC
T5    rc=2  refusing: mut_T5.json is 'llama.vhdl FK33 load manifest v1', not a lane-striped manifest
```

**T3 originally SURVIVED and that is the most useful line in this document.**
The first version of the distinct-segment check counted the manifest's declared
`segment` FIELD, so two lanes given the same `hbm_offset` with their labels left
alone still looked like 27 distinct segments. A check that reads a label instead
of the thing the hardware decodes is decoration; address bits [32:28] are what
select the pseudo-channel. The check now derives the segment from the address
and reports the label/address disagreement separately (T3), which is why there
is a T3b at all.

---

## 6. The fallbacks, costed, in case 44,500 tokens is not enough

None of these is implemented. Each is stated with the arithmetic so the choice
can be made on numbers.

**(a) Extent-aware KV. RECOMMENDED. Recovers everything, costs one RTL change.**
The 2.576 GiB in the 27 tails plus segment 16's 256 MiB is real memory at a
fixed 256 MiB stride. `hbm.kv_extents` is ALREADY in every manifest this packer
writes, and `hbm_map.manifest_regions` already reads it. What cannot read it is
`rtl/attn_kv_axi.vhd`, whose KV address is linear in `C_K_BASE_CH`. A strided
map -- skip 158.30 MiB every 256 MiB -- is one compare and one add in the
address generator. **DERIVED recovery: 2.576 + 0.250 GiB = 2.826 GiB extra,
taking context from 44,500 to about 214,000 tokens**, i.e. back to the flat
layout's 233,396 less the descriptor and host reservations. It also spreads KV
reads over 27 pseudo-channels, which subsystem C will want for exactly the
reason subsystem A wanted it. `tools/check_kv_map.py` and `sim/tb_attn_kv_map.vhd`
move with it.

**(b) Stripe over 21 segments instead of 27, keeping 23..31 contiguous.**
Assign lanes to segments 1..15 and 17..22; six of those 21 serve two lanes. A
doubled segment passes 1 beat per AXI cycle shared by two lanes = 0.4 beats per
core cycle each, so a doubled lane needs **2.5 core cycles per weight word**
against the ideal 1.60 -- **DERIVED 8.6x instead of 13.5x**. Segments 23..31 are
then contiguous and free: from `23 * 0x10000000` to `desc_arena_base` is
2,410,532,864 B = **138,600 tokens**. This is the cheapest option that needs no
RTL change at all, and it is a genuine 3x context for a 36% speed give-back.

**(c) Do nothing about KV yet.** Subsystem C is not on the card and nothing
today reads the KV arena. The 44,500-token map is enough to run every subsystem
A measurement, the whole-token sequence work, and the on-card test in section 8.
The decision can be deferred until C is real. **This is what the shipping
default should be until (a) is built.**

**Explicitly REJECTED: moving the GDN state or the descriptor arena into
segment 0 or 16 to free the top.** `server/fk33_manifest.c:170` refuses
`gdn_state_base < weights_end`, and under striping `weights_end` is at
segment 28's arena end, so both must live above it. Changing that C rule to be
extent-aware is the same work as (a) and buys strictly less.

---

## 7. What this change needs from files TRACK PACKSTRIPE does not own

Each delta is specified. **None was applied.** All four are small and none
touches an address computation -- they teach four consumers that one file can
occupy more than one extent.

### 7.1 The refusals, MEASURED, so the deltas are not hypothetical

```
$ python3 tools/hbm_map.py <striped>/manifest.json --markdown
FAIL  OVERLAP: blk.0.ffn_down.weight.mv4i 0x0..0x1b3_e000 and
      blk.0.ffn_gate.weight.mv4i 0x1000..0x1b0_1000 share 28311552 bytes
... 249 FAIL          rc=1

$ python3 tools/check_mv4i_set.py <striped>
FAIL nonmatvec_f32.bin: HBM offset 0xf9000 overlaps the previous region ending 0xa0b000
... 249 FAILURES      rc=1
```

Both refusals are **CORRECT**. They are what the `format` bump exists to
provoke.

**AND ONE CONSUMER PASSED FOR THE WRONG REASON, WHICH IS WORSE THAN EITHER.**

```
$ python3 tools/check_hbm_stack.py <striped>
checked 7154 byte ranges against a 4294967296 B stack boundary
PASS no range crosses a stack boundary          rc=0
```

`tools/check_hbm_stack.py:93,101` builds every range as
`e["hbm_offset"] + <flat layout offset>`. Under striping those ranges are
**fictitious**: they are a 4 KB header's address plus the offsets of sub-regions
that are somewhere else entirely. Every one of them lands in the low 34 MB of
segment 0, so none can cross the 4 GiB line and the `PASS` is guaranteed
regardless of the truth. It checked 7,154 ranges of which **zero exist**. The
striped layout does in fact satisfy the stack rule -- DERIVED: every piece is
inside one 256 MiB segment (check 1) and a segment is inside one stack, and
lane p's segment index equals its SAXI index so it is its master's own stack --
but that PASS is not the evidence, and reading it as evidence is exactly the
2026-08-29 "verify passed an object it never read" failure with a new number.

### 7.2 `tools/hbm_map.py` -- `manifest_regions()`, about 6 lines

```python
    for e in mani["files"]:
        if e.get("pieces"):                         # v2 lane-striped
            for i, x in enumerate(e["pieces"]):
                out.append(Region("%s:%d" % (e["file"], i), x["hbm_offset"],
                                  x["nbytes"], e["kind"],
                                  "pack_model_fk33.py", stack_of(x["hbm_offset"])))
            continue
        out.append(Region(e["file"], e["hbm_offset"], e["nbytes"], ...))
```

`tools/pack_model_fk33.py::expand_pieces()` already does exactly this
transformation and is what the packer hands `derive_region_block()`, so the
adaptor exists and has been exercised over 6,973 extents. It is written in the
packer only because `hbm_map.py` is not this track's to edit; **it belongs in
`hbm_map.py` and the packer's copy should be deleted when it moves.** Two
producers of one fact is the defect `hbm_map.py` exists to end, and this is
knowingly one for as long as it takes to hand over.

### 7.3 `tools/gen_mv4i_desc.py` -- `hbm_base_for()` + `build_descriptor()`

Today `w_base[p] = hbm_base + w_off[p] + w_skip`. Under striping the base is
the piece, so it needs a per-lane base list threaded from the manifest:

```python
    w_base = [ (piece_base[p] if piece_base else hbm_base + o) + w_skip
               for p, o in enumerate(w_off) ]
```

**`check_bases()` must NOT be relaxed.** It compares the file's own 0x38 table
against spec 6.5a's layout, both of which are FILE offsets and neither of which
changes. Section 5 part B is the measurement that says so: 249 of 249 agree.

### 7.4 `hw/fk33/host/fk33_load_weights.py` -- `cmd_load()` and `_verify()`

Both currently walk one `(hbm_offset, nbytes)` range per object. Both become a
loop over `e.get("pieces") or [ {file_offset:0, nbytes:e["nbytes"],
hbm_offset:e["hbm_offset"]} ]`. **The blake2b stays byte-identical** because
the pieces tile the file in increasing file order (check 3, and section 5
part D measured it over 249 of 249 files). `parse_and_check_header` reads
piece 0. Nothing else moves.

### 7.5 `hw/fk33/host/fk33_run_job.py` -- `make_plan()`'s cross-check

```python
    for p in range(f["nsub_w"]):
        xc("w_base[%d]" % p, f["w_base"][p], piece_base[p] + w_skip)
        xc("w_sub_offset[%d]" % p, f["w_sub_offset"][p], orc["wsub"][p])
```

This SPLITS the existing check into two and both halves keep teeth: the C
oracle still validates the file layout, and the manifest now validates the
placement. It is strictly stronger than the single check it replaces.

### 7.6 `ref/mv_fk33_tr` -- NO CHANGE. Correction to the brief.

The brief said `tools/gen_mv4i_desc.py` and `ref/mv_fk33_tr` "cross-check each
other on 42 descriptor fields and guard every job", and that "if the descriptor
changes, both must move together or the check breaks twice". MEASURED from
`fk33_run_job.py::make_plan`: the C side emits `WSUB p <offset>` /
`SSUB q <offset>`, i.e. sub-region OFFSETS, and the Python side is joined to
them by `hbm_base + orc["wsub"][p]`. **The C never computes an HBM address**,
so the only thing that moves is the join, on the Python side, in
`fk33_run_job.py`. `ref/mv_fk33_tr.c` is untouched by this change.

---

## 8. The decisive on-card test. **OREN ONLY. NO AGENT RUNS THIS.**

**Prediction, stated before the run so it can fail.** On
`blk.0.ffn_gate.weight`, `--rows 100`, K=4096, 3 tiles, BEATS=384:

| arm | CYCLES | cycles/beat | VERDICT |
|---|---|---|---|
| A, flat control | **8,300 - 8,900** (COUNTERS measured 8,582) | ~22 | PASS |
| B, lane-striped | **under 1,500**, DERIVED target ~613 | ~1.6 | PASS |

**DERIVED, why 613 and not something smaller.** One dedicated 256-bit
pseudo-channel per lane at ACLK 250 MHz retires a beat every 4 ns; the core
clock is 5 ns; so a lane can supply 1.25 weight words per core cycle against a
demand of 1.0. The memory stops being the bound and COUNTERS' run A -- the same
shipping RTL with an ideal memory and the identical `MAXOUT=16`, `MAXB=16`,
`DEPTH=512` -- gives 613 cycles for exactly this job. 613 is a floor, not a
forecast: 27 real pseudo-channels are not an ideal memory.

**`VERDICT` must stay `PASS` in BOTH arms.** That is the value half and it is
not optional. Subsystem A is proven bit-exact on this silicon over 1,675,264
rows; a placement change that perturbs one weight would look like a hardware
fault.

### 8.0 Prerequisites and one hazard

- **The card is unconfigured. Reprogram first.** Nothing below depends on a
  new bitstream: the descriptor's `w_base[]`/`s_base[]` are already 27
  independent 64-bit fields in the shipping RTL and no gateware change is
  needed. **Any bitstream that `fk33_run_job.py` accepts today runs this.**
  The probe re-runs `rtl_would_reject()` on the relocated descriptor and
  refuses before writing if the gateware would not take it.
- **HAZARD: arm B writes 27 MB into segments 1..28, which under the FLAT
  layout hold OTHER tensors.** Load only the one tensor (step 1), or accept
  that a full flat image must be reloaded afterwards.
- Everything below runs from the repo root with the striped manifest at
  `$STRP` and the shipping flat one at `$FLAT`.

### 8.1 The commands

```bash
cd /home/orencollaco/GitHub/llama.vhdl
FLAT=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
STRP=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json
SD=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped
PROBE=docs/debugging/2026-08-30_packstripe-stripe_probe.py
SCR=/mnt/storage/track-packstripe/probe

# 0  the card answers, and the rail is up.  Nothing here is new.
python3 hw/fk33/host/fk33ctl.py id
python3 hw/fk33/host/fk33ctl.py vccint          # wiper 68, ~0.717 V.  NEVER 0.85 V.

# 1  make ONE tensor resident under the FLAT map, and prove it is there.
python3 hw/fk33/host/fk33_load_weights.py load "$FLAT" \
        --only blk.0.ffn_gate.weight --verify

# 2  ARM A, the control.  Through the SAME file as arm B so the two numbers
#    differ in the placement and in nothing else.
python3 "$PROBE" --flat \
  --mv4i "$SD/blk.0.ffn_gate.weight.mv4i" \
  --flat-manifest "$FLAT" --striped-manifest "$STRP" \
  --rows 100 --x-exp -6 --slot 0 --scratch "$SCR" 2>&1 | tee "$SCR/armA.log"

# 3  ARM B, lane-striped.  Copies the 27 sub-regions to their 27 segments,
#    relocates the 27 descriptor bases, runs the identical job.
python3 "$PROBE" \
  --mv4i "$SD/blk.0.ffn_gate.weight.mv4i" \
  --flat-manifest "$FLAT" --striped-manifest "$STRP" \
  --rows 100 --x-exp -6 --slot 1 --scratch "$SCR" 2>&1 | tee "$SCR/armB.log"

# 4  the two numbers, side by side.
grep -H "^counters\|^VERDICT\|^ARM" "$SCR/armA.log" "$SCR/armB.log"

# 5  THE TEETH FOR THE COPY STEP.  Relocate the bases and do NOT move the
#    bytes.  This MUST fail; if it PASSES, the engine is not reading where the
#    descriptor says and every number above is about something else.
python3 "$PROBE" --no-copy \
  --mv4i "$SD/blk.0.ffn_gate.weight.mv4i" \
  --flat-manifest "$FLAT" --striped-manifest "$STRP" \
  --rows 100 --x-exp -6 --slot 2 --scratch "$SCR" 2>&1 | tail -6
```

### 8.2 What each step prints

- **step 1** ends `PASS  every object written and its source bytes match the
  manifest`, having read HBM back.
- **step 2 and 3** each print, in order: the tensor and job shape;
  `cross-check 42 of 42 fields agree between tools/gen_mv4i_desc.py (Python)
  and ref/mv_fk33_tr (C)`; for arm B only, `RELOCATION 27 sub-regions -> 27
  DISTINCT 256 MiB segments [1, 2, ... 28]` and `gateware would ACCEPT`; then
  `counters    CYCLES=... BEATS=384 STARVED=...`; then
  `result read 100 of 100 rows, compared 100 of 100 against ref/matvec_int4.c,
  0 differ`; then `VERDICT PASS`.
- **step 5** must end `VERDICT FAIL`.

### 8.3 Failure modes, and what each one would mean

| what you see | reading |
|---|---|
| arm A ~8,600, arm B **under 1,500**, both PASS | **The finding is confirmed.** Ship the striping; build section 7's four deltas. |
| arm A ~8,600, arm B ~8,600, both PASS | The 27 masters are NOT limited by the destination pseudo-channel. Next suspect is the HBM global switch's lateral bandwidth, or an arbitration point upstream of the switch. COUNTERS named this as the falsifier; the whole analysis is wrong. |
| arm B between 1,500 and 5,000, PASS | Partial. Real striping gain, plus a second serialisation. Look at the scale path (`s_valid` has no counter -- COUNTERS' open item 3) and at the residual `CYCLES - BEATS - STARVED`, which on the card is 10-47% and which COUNTERS' single-clock model does not reproduce. |
| arm B **FAIL**, rows differ | The relocation moved the wrong bytes, or the copy did not land. `--no-copy` should also FAIL; if it does not, the copy is not the variable. Re-run step 1 and compare `armB.log`'s `RELOCATION` table against the manifest. **Do not read the CYCLES number from a FAIL run.** |
| arm B refuses before running | The probe caught it. The message names which of the six refusals fired; section 5.2 has all six with their teeth. |
| arm A itself FAILs | Nothing to do with striping. The flat image or the bitstream is wrong; stop and fix that first. |
| `compute_halt is asserted RIGHT NOW` | The thermal guard. Open issue THERM-255. `fk33ctl.py thermal --clear` and re-read. |
| `STICKY error state` | A previous descriptor was rejected; `S_ERR` is left only by RESET. Reload the bitstream. |

### 8.4 What was proven about this test WITHOUT a card

`fk33_run_job.py --dry-run` opens nothing under `/dev`. MEASURED, full path:

```
cross-check 42 of 42 fields agree between tools/gen_mv4i_desc.py (Python) and ref/mv_fk33_tr (C)
RELOCATION  27 sub-regions -> 27 DISTINCT 256 MiB segments [1, 2, 3, ... 26, 27, 28]
  w[ 0]  0x0038205000 -> 0x0012142000  seg  1  file +4096      1048576 B
  w[ 1]  0x0038305000 -> 0x0022142000  seg  2  file +1052672   1048576 B
  s[ 2]  0x0039C05000 -> 0x01C2142000  seg 28  file +27267072  1048576 B
  gateware would ACCEPT the relocated descriptor (rtl_would_reject: no findings)
copied      28311552 B in 27 sub-regions to the striped addresses
result      read 100 of 100 rows, compared 100 of 100 against ref/matvec_int4.c, 0 differ
VERDICT     PASS
```

**THAT PASS IS WORTH NOTHING AS A VALUE CHECK AND THE `CYCLES=4096` IT PRINTS
IS FICTION.** `fk33_run_job.SimBar` REPLAYS the oracle, so it returns the right
answer no matter what is in the simulated HBM -- MEASURED: the `--no-copy` arm,
which is designed to fail, also PASSES in dry-run. What the dry-run establishes
is the plumbing: the relocation table is built, tied to the two agreeing tools,
accepted by `rtl_would_reject`, and the 27 copies are issued. Everything about
speed and about values comes from the card and from nowhere else.

---

## 9. Measured and REJECTED -- do not retry

| approach | how it died | do not retry |
|---|---|---|
| **Stripe by spacing the sub-regions 256 MiB apart INSIDE the `.mv4i` file, so the flat `hbm_base + offset` rule still works** | `w_base[p] = hbm_base + HDR + w_stride*p` needs `w_stride >= 256 MiB` to reach a new segment per lane. `w_stride = align4k(tiles*K)`; at K=4096 that needs `tiles = 65536`, i.e. M = 3,145,728 rows. The file would be 6.9 GiB per tensor, almost all holes. | Settled by arithmetic. There is no contiguous file layout that spans 27 segments. |
| **Keep `gen_mv4i_desc.py` unchanged by writing striped offsets into the `.mv4i` HEADER's 0x38 table** | `check_bases()` hard-refuses a header whose table disagrees with spec 6.5a's layout, and that refusal is the only guard against the one descriptor corruption the gateware cannot see. | Do not weaken `check_bases`. The offsets are FILE offsets and they are correct; the placement belongs in the manifest. |
| **Emit 27 concatenated "lane image" files (`lane00.bin`..`lane26.bin`) so the loader places 27 contiguous objects and needs no change** | It works for the loader and for `hbm_map`, and it still leaves `gen_mv4i_desc.py` needing per-lane bases -- the same delta -- while creating 4.2 GiB of new files and destroying the per-tensor blake2b that is the value oracle in section 5. | Strictly worse than `pieces` on every axis except the loader. |
| **Put the GDN state or the descriptor arena in segment 0 or 16 to free the top for KV** | `server/fk33_manifest.c:170` refuses `gdn_state_base < weights_end`, and under striping `weights_end` is at segment 28. | Fallback (a) in section 6 is the same work and buys more. |
| **Read `ENG_PORT_MAP` from the brief, or copy it into the packer** | The brief said "masters 0..14 -> SAXI_01..15, masters 15..27 -> SAXI_17..29" and implied 27 data lanes. The map has 28 entries and the 28th is the descriptor fetch master; placing a data lane there would put weights on segment 29 and leave the descriptor master sharing a pseudo-channel with them. | The packer scrapes `gen_pcieep.py` and re-asserts its four invariants. |
| **Trust `check_hbm_stack.py`'s PASS on a striped manifest** | Section 7.1. It PASSES over 7,154 ranges of which zero exist. | It is a v1 consumer. Its verdict on a v2 manifest is not evidence in either direction. |
| **Count the manifest's declared `segment` field to prove 27 distinct pseudo-channels** | Teeth case T3: two lanes given the same `hbm_offset` with their labels untouched survived. | Derive the segment from address bits [32:28]. The label is not what the hardware decodes. |

---

## 10. Measurement traps hit, including my own

1. **A blind `else:`-insertion re-indented 195 lines of the packer.** A script
   located the branch with `next(i for i,l in enumerate(src) if l == '    else:')`
   and there were FOUR such lines; it found the first, 129 lines above the
   target. Caught in seconds by `ast.parse` and reversed exactly, but the
   lesson stands: never locate a Python block by matching a token that is not
   unique in the file. Anchor on something that is.
2. **`du -sh` on the hardlinked outdir reported 33 K and looked like a failed
   copy.** It was correct. The `qwen35-9b-mv4i-noembd` set is itself a
   directory of SYMLINKS into `qwen35-9b-mv4i` and `qwen35-9b-mv4i-qkvpad`, so
   the hardlinks are hardlinks to symlinks. Everything resolves and nothing was
   copied, which is the intent -- but "the directory is 33 K" is not evidence
   the files are there. `ls -la` is.
3. **The first striped run refused with 249 `OVERLAP` faults and it was the
   RIGHT answer to the WRONG question.** `derive_region_block()` was being
   handed the file list, in which one striped file claims `nbytes` bytes at its
   header's address. Handing it the piece list is not silencing the check; it
   is giving it the truth, and it then compares 6,973 extents instead of 249.
   The distinction matters because the first instinct on seeing a wall of
   overlaps is to loosen the checker.
4. **COUNTERS' 187.3 MB per segment is right for the wrong set.** It is the
   250-file `qwen35-9b-mv4i`, which still carries `token_embd.weight`. The card
   runs `qwen35-9b-mv4i-noembd`, where the figure is 158.30 MiB. Always name
   which packed set a per-segment number came from.
5. **`hbm_map`'s 44,500 tokens and the packer's 44,809 are both right.** The
   packer counts to the top of the device; the map subtracts the 5,386,240 B of
   top-anchored host reservations. Quote the map's.
6. **A `--dry-run` PASS says nothing about values.** `SimBar` replays the
   oracle. The `--no-copy` arm, whose whole purpose is to fail, PASSES in
   dry-run. Any claim from a dry-run is at best DERIVED and is about this
   tooling, never about an FPGA.
7. **`tools/check_mv4i_set.py MANIFEST.json` silently doubles the path** and
   reports `no manifest at .../manifest.json/manifest.json`. It wants the
   DIRECTORY. Two minutes lost; noted so the next reader loses none.

---

## 11. Open, not yet answered

1. **The 13.5x is DERIVED and the 14.0x is COUNTERS' simulation. NEITHER IS
   MEASURED.** Only section 8 settles it, and only on the card. Do not repeat
   either number as a measurement.
2. **Nothing in the striped set has been loaded onto a card.** Section 5 proves
   the addresses are internally consistent and the bytes unchanged; it says
   nothing about residency. The residency backstop is
   `fk33_load_weights.py verify`, which cannot run until section 7.4 lands.
3. **Whether subsystems B, C and D have the same pathology.** COUNTERS' open
   item 5. The GDN state and the KV arena are single large regions and any
   multi-master read of them hits the same 256 MiB granularity.
   `rtl/attn_kv_axi.vhd` has its own `starv` counter and neither track has
   looked at it. Under this layout the GDN state sits alone in segment 29,
   which is at least not contending with a weight lane.
4. **The KV decision is deferred, not made.** Fallback (a) is recommended and
   not costed in engineering time; (b) is the no-RTL option at 138,600 tokens
   and 8.6x; (c) is the shipping default. Someone has to choose.
5. **`expand_pieces()` is knowingly a second producer** of the region model
   until section 7.2 moves it into `hbm_map.py`. It is the exact defect
   `hbm_map.py` exists to end and it is live in the tree right now, in one
   place, named here so it is not discovered later as a surprise.
6. **The lane arenas are packed in manifest order and nothing pins the order.**
   Teeth M8/M9 show the checks do not constrain where inside its segment a
   lane's arena for a given tensor sits. That is correct today -- the address is
   in the manifest and the descriptor reads it -- but if anything ever derives a
   lane address arithmetically instead of reading it, this becomes the hole
   M9 describes.
7. **Segment 16's 256 MiB and the 2.576 GiB of tails are declared free and
   nothing can use them.** Stated in the packer's own summary line rather than
   left for a reader to compute.

---

## 11b. The flat path is unchanged, MEASURED

Re-running the packer with NO `--stripe-lanes` over the same GGUF and the same
`--drop token_embd.weight`, into a fresh outdir of hardlinks, and comparing the
manifest object-by-object against the shipping one:

```
files identical: True
geometry lane_stripe    shipping=None  now=False
hbm      arena_sizing   shipping='...QWEN35_9B by tools/hbm_ma...'
                        now='derived from rtl/model_cfg_pkg.vhd by tools/hbm_map.py arena_sizes()'
  weights          4487442432 B   GDN state 24.1 MB at 0x10c006000
  stack holes      8876032 B at 0xff789000
  free for KV      3.789 GiB from 0x10d81e000 => 233705 tokens
  A desc arena     159744 B at 0x1ffadd000
```

**`files` is byte-identical** -- every `hbm_offset`, every digest, every entry,
in the same order. `geometry.lane_stripe: false` is the one field this change
adds. `hbm.arena_sizing` differs because the shipping manifest was written
before an unrelated edit to that provenance string; `git diff` confirms this
change does not touch it, and it is a comment field that nothing reads.

---

## 12. Corrections to the brief

- **"`tools/gen_mv4i_desc.py` and `ref/mv_fk33_tr` cross-check each other on 42
  descriptor fields ... If the descriptor changes, both must move together."**
  Half right. The 42-field cross-check is real and it does guard every job, but
  `ref/mv_fk33_tr` emits sub-region OFFSETS and never an HBM address. Only the
  Python side and the join in `fk33_run_job.py` move. Section 7.6.
- **"Segment 16 is the host's; find every other reserved one."** Done, and
  there are four more: 0 (`SAXI_00`, the host's other port), 29 (the
  DESCRIPTOR FETCH master, which the brief's own port-map quote assigned to a
  data lane), 30 and 31 (no engine master).
- **"187.3 MB of weights per segment against a 268.4 MB segment, leaving the KV
  cache and the Gated DeltaNet state to fit in the tails."** The live set is
  158.30 MiB per segment, and the KV cache CANNOT fit in the tails at all -- not
  for want of space, but because `rtl/attn_kv_axi.vhd` addresses it from one
  linear base. The capacity question is not the binding one; contiguity is.
- **"`hw/fk33/host/fk33_load_weights.py --verify` ... had a real coverage hole
  yesterday."** It did, and it is already fixed, with the incident written into
  the source as a comment. Section 5 names it rather than re-litigating it.
- **"3. The repack."** There is no repack. The `.mv4i` bytes are a function of
  the tensor and the geometry, not of the address. `--stripe-lanes` over an
  existing set re-places and rewrites only the manifest, in 7.9 s, and every
  digest is unchanged -- which is what makes section 5 part A an oracle instead
  of a tautology.

---

## 13. What changed in the tree

| path | change |
|---|---|
| `tools/pack_model_fk33.py` | `--stripe-lanes`, `scrape_eng_port_map()`, `lane_stripe_plan()`, `check_lane_stripe()` (six invariants), `expand_pieces()`, the `hbm.lane_stripe` manifest block, the `format` v2 bump. The flat path is untouched and is still the default. |
| `docs/debugging/2026-08-30_packstripe-lane-arena-placement.md` | this document |
| `docs/debugging/2026-08-30_packstripe-stripe_probe.py` | the on-card probe of section 8. Deliberately NOT in `tools/` or `hw/fk33/host/`, same precedent as COUNTERS' `2026-08-30_counters-tb_ctr_rate.vhd`. |

**No RTL, no `sim/` file, no host file, no `hbm_map.py`, no `gen_mv4i_desc.py`,
no `ref/`, no `gen_pcieep.py`.**

Artefacts outside the tree, all on `/mnt/storage`, none on root:

| path | what |
|---|---|
| `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/` | the striped set. 250 hardlinks into the existing set plus a 1,169,722-byte manifest. **Zero model bytes written.** |
| `/mnt/storage/track-packstripe/verify_stripe.py` | the four-part addresses-not-values oracle |
| `/mnt/storage/track-packstripe/teeth_stripe.py` | the ten mutations |
| `/mnt/storage/track-packstripe/lane_budget.py` | the per-lane capacity arithmetic |
| `/mnt/storage/track-packstripe/manifest_pieceview.json` | the 6,973-extent view `hbm_map.py` PASSES on |

**The shipping `qwen35-9b-mv4i-noembd` set was not touched.** Its manifest
still carries its 2026-08-29 18:07 mtime. It is the rollback and it is what
every measurement on this project so far was taken against.
