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

**CORRECTION 2026-08-30, appended in place, NOT edited into history.** The
first version of this document shipped a 27-wide stripe as the default and
offered a "21-segment hybrid" as a fallback at 8.6x. Oren then stated the
context requirement -- "Not a requirement, even 64k ish is fine" -- and against
it **the 27-wide default FAILS at 44,500 tokens**. Re-deriving the supply model
to answer that found TWO errors of my own, both in the fallback's favour and
both now fixed:

1. **The 8.6x was arithmetic.** I wrote "1 beat per AXI cycle = 0.8 beats per
   core cycle"; it is 250/200 = **1.25**, not 200/250 = 0.8. Two lanes per
   pseudo-channel supply **1.60** core cycles per weight word, which is exactly
   the datapath's own floor, so **M = 2 costs nothing in the model** -- not 2.5
   c/beat and not a 36% give-back.
2. **The 21-segment hybrid as I described it was INFEASIBLE.** It assumed a
   fixed lane -> segment table, and two lanes' arenas are 316.61 MiB against a
   256.00 MiB segment. Compaction is only possible if WHICH segment a lane
   reads varies per TENSOR, which is what the shipping allocator now does.

**The default is now the compacted layout: 27 lanes on 25 segments, at most 2
per pseudo-channel, DERIVED 1.60 core cycles per weight word (the same as the
27-wide stripe), 75,340 tokens of context.** Sections 2, 6, 8 and 11b are
rewritten below; sections 4.3, 5 and 7.1 carry the original 27-wide numbers and
are marked where they do.

**Files read as the authority:** `hw/fk33/gen_pcieep.py` (`ENG_PORT_MAP`, the
`ENGINE_ADDR` block), `hw/fk33/rtl/fk33_engine.vhd` (which master is which
lane), `tools/gen_mv4i_desc.py` (`check_bases`, `layout_strides`,
`build_descriptor`), `tools/hbm_map.py` (`manifest_regions`,
`derive_region_block`), `hw/fk33/host/fk33_load_weights.py` (`cmd_load`,
`_verify`), `hw/fk33/host/fk33_run_job.py` (`make_plan`, `run_job`),
`server/fk33_manifest.c`, `rtl/attn_kv_axi.vhd` (`rec_addr`),
`rtl/llama_top.vhd` (`C_K_BASE_CH`/`C_V_BASE_CH`), `tools/check_kv_map.py`, `docs/2026-08-28_can-27-read-masters-be-served.md`,
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

**2. It fits, comfortably. The brief's framing of the capacity problem was
wrong: the cost is not capacity, it is CONTIGUITY -- and the amount of
contiguity is a DIAL, not a constant.**

MEASURED over the live 249-file `qwen35-9b-mv4i-noembd` set, per lane:

```
per-lane need   165,994,496 B = 158.30 MiB   identical on all 27 lanes
segment          268,435,456 B = 256.00 MiB
```

COUNTERS' 187.3 MB was computed on the older 250-file set that still carries
`token_embd.weight`; that set is not what the card runs. Neither set is close
to a wall. **Total free space is essentially unchanged by striping** (3.826 GiB
striped against 3.808 GiB flat). What changes is the SHAPE of the free space:
it becomes segment tails, and the KV cache cannot use a tail, because
`rtl/attn_kv_axi.vhd`'s `rec_addr` is one linear base
(`addr = base + ((layer*N_KVH + head)*MAXCTX + pos) * REC_B`) and
`server/fk33_manifest.c:170` requires `gdn_state_base >= weights_end`. So KV
gets only what lies above the highest lane arena.

**THE SUPPLY MODEL, DERIVED, and it reproduces both known anchors.** A
pseudo-channel's fabric access path is 32 B per ACLK cycle regardless of how
many masters target it (`docs/2026-08-28_can-27-read-masters-be-served.md`
section 2.1, MEASURED). ACLK is 250 MHz, the core is 200 MHz, so one PC passes
**1.25 beats per CORE cycle**. With M lanes sharing a PC:

```
memory bound = M / 1.25 core cycles per weight word
achieved     = max(datapath floor 1.60, M / 1.25)

  M =  1 -> max(1.60, 0.80) =  1.60      M =  3 -> 2.40
  M =  2 -> max(1.60, 1.60) =  1.60      M = 27 -> 21.60
```

Anchor 1: M = 27 gives **21.60**, against COUNTERS' independently DERIVED 21.60
and the card's MEASURED 21.67. Anchor 2: M = 1 is datapath-bound, and COUNTERS'
run A -- the same shipping RTL with an ideal memory -- measured 613 cycles for
384 beats = 1.596. **M = 2 is free in this model**, and that is what makes
compaction affordable: fewer segments means more contiguous KV at no DERIVED
cost, right up to the point where a third lane joins a pseudo-channel.

**But a fixed lane -> segment table cannot compact at all**: two lanes' arenas
are 316.61 MiB against a 256.00 MiB segment. So the allocator assigns segments
**per tensor**, greedily on current fill, within each lane's own HBM stack. The
descriptor re-states all 27 bases for every job, so the only property that must
hold is per-job: no pseudo-channel asked for more than M lanes.

**The width curve, MEASURED, printed by the tool itself on every run:**

```
  stripe width search (stack-1 segments; stack-0 stays 1:1)
    n   max lanes/seg   DERIVED c/beat   peak fill   KV tokens
   12        1             1.60           61.8%      44500  (under the 65536 target)
   11        2             1.60           69.7%      59920  (under the 65536 target)
   10        2             1.60           74.2%      75340  <== chosen
    9        2             1.60           82.5%      90760
    8        2             1.60           92.8%     106180
    7   REFUSED: HBM segment 21 overflows
    6   REFUSED: HBM segment 17 overflows
    5   REFUSED: 27 lanes onto 20 segments puts 3 lanes on one pseudo-channel
    4   REFUSED: 27 lanes onto 19 segments puts 3 lanes on one pseudo-channel
    3   REFUSED: 27 lanes onto 18 segments puts 4 lanes on one pseudo-channel
    2   REFUSED: 27 lanes onto 17 segments puts 6 lanes on one pseudo-channel
    1   REFUSED: 27 lanes onto 16 segments puts 12 lanes on one pseudo-channel
```

Only stack-1 segments are compacted. Compacting stack-0 frees LOW segments,
which buys no contiguity at the top and therefore no context, and a lane is
never moved off its own stack (check 7) because cross-stack lateral throughput
is UNMEASURED in this project.

**The rule is the WIDEST width that still meets the context target, never the
narrowest.** M = 2 is free with ZERO SLACK -- COUNTERS' run A still shows 394
of 1,188 cycles going to AR issue and FIFO fill with an ideal memory, and a
memory matched exactly to consumption cannot hide them -- so compact only as
far as the requirement forces.

| layout | max lanes/PC | DERIVED c/beat | context | meets 64k |
|---|---|---|---|---|
| flat (shipping today) | 27 | 21.60 | 233,396 | yes, and 13.5x too slow |
| 27-wide stripe (my first default) | 1 | 1.60 | **44,500** | **NO** |
| **25-segment compact (the new default)** | **2** | **1.60** | **75,340** | **yes, 1.15x** |
| 23-segment compact | 2 | 1.60 | 106,180 | yes, 1.62x, 92.8% fill |
| extent-aware KV (section 6) | 1 or 2 | 1.60 | ~219,000 | yes, 3.3x, one RTL change |

**3. Done, as `--stripe-lanes` in `tools/pack_model_fk33.py`, with a manifest
`format` bump to `"llama.vhdl FK33 load manifest v2 lane-striped"`, and with a
CONTEXT GATE that refuses rather than shipping a layout that misses the
requirement.** `--stripe-min-context` defaults to 65,536; the packer searches
the width curve, picks the widest that meets it, prints the whole curve, and
REFUSES if none does. **The context the chosen layout yields is the last line
of the tool's own summary**, so nobody has to open this document to discover
what they got:

```
  CONTEXT          75340 tokens (73.6k), against the 65536 required (64k).  Margin 1.15x
```

`--stripe-stack1-segments N` overrides the search; the context refusal still
applies afterwards, so the override cannot be used to sneak a sub-target layout
out. Lowering the bar takes an explicit `--stripe-min-context`. The
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

**5. The decisive test is section 8, it is runnable today with no modified
tool, and the prediction is RESTATED for the layout that is now the default.**
`blk.0.ffn_gate.weight --rows 100` (K=4096, 3 tiles, BEATS=384) moves from
**CYCLES 8,300-8,900 flat** to **CYCLES under 1,500 striped**, and **VERDICT
stays PASS in both arms**. The threshold does not move between the 27-wide and
the compacted layout, because both are DERIVED at 1.60 c/beat; what moves is
the confidence in the lower end, and section 8 states that separately.

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

*(Per-lane bytes are a property of the packed set, not of the width, so this
table is unchanged by the correction. The `fill` percentages quoted here are
the 27-wide ones; the shipping 25-segment default peaks at 74.2%.)*

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

Lane-striped, the shipping 25-segment default, over the 6,973 real extents:

```
| packed weights + F32 blob | 0x0 | 0x1_0b78_f000 | 4,487,442,432 | 4.1793 | 6973 objects, 2690994176 B of stack-line hole |
| gdn recurrent state | 0x1_b000_0000 | 0x1_b181_8000 | 25,264,128 | 0.0235 |
| kv arena 0 | 0x1_b181_8000 | 0x1_ffad_d000 | 1,311,526,912 | 1.2215 | 75340 tokens at 17408 B/token |
| A descriptor arena | 0x1_ffad_d000 | 0x1_ffb0_4000 | 159,744 | 0.0001 |
| host R_X staging | 0x1_ffb0_4000 | 0x1_fff0_c000 | 4,227,072 | 0.0039 |
| host logits writeback | 0x1_fff0_c000 | 0x1_ffff_e840 | 993,344 | 0.0009 |
| host D program | 0x1_ffff_f000 | 0x2_0000_0000 | 4,096 | 0.0000 |

device      8,589,934,592 B = 8.0000 GiB
accounted   8,520,611,904 B = 7.9354 GiB
unaccounted    69,322,688 B
PASS  every region is aligned, in range, in one stack, and disjoint across all 3 allocators
```

**The descriptor arena and the three host blocks are at IDENTICAL addresses in
both maps.** That is not luck: `derive_region_block()` anchors them to the top
of the device from `n_embd`, `n_vocab` and `max_chunk`, none of which the weight
placement touches. It is also load-bearing, because the width search needs a KV
ceiling BEFORE the placement exists. **It is asserted, not believed** -- the
packer compares the arena the search used against the arena
`derive_region_block()` actually returns and refuses on a mismatch. Teeth: with
`kv_top` deliberately moved one page, MEASURED

```
pack_model_fk33: the width search sized the KV cache against a descriptor arena
at 0x1ffadc000 and derive_region_block() placed it at 0x1ffadd000.  The arena is
NOT placement-independent after all and every context figure printed above is
wrong.  Nothing was written.
```

### 4.5 The packer's own output, shipping default

```
  stripe width search (stack-1 segments; stack-0 stays 1:1)
   10        2             1.60           74.2%      75340  <== chosen
  stripe check 1 every piece is inside a segment its lane's group owns    PASS  0 violation(s)
  stripe check 2 every piece 4 KB aligned in HBM and in the file          PASS  0 violation(s)
  stripe check 3 the pieces tile the file exactly, in order               PASS  0 violation(s)
  stripe check 4 no two pieces overlap in HBM                             PASS  0 of 6971 adjacent pairs
  stripe check 5 every segment arena fits                                 PASS  peak fill 74.2%
  stripe check 6 no tensor puts more than 2 lane(s) on one pseudo-channel PASS  worst observed 2, DERIVED 1.60 c/beat vs datapath 1.60
  stripe check 7 every lane reads only its own master's HBM stack         PASS  0 violation(s)

wrote /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json
  weights          4487442432 B  4.179 GiB  (52.2 % of 8 GiB)
  GDN state        24.1 MB at 0x1b0000000
  lane stripe      ON, 27 lanes on 25 segments of 256 MiB
    stack 0        lanes 0..14 1:1 on segments [1..15]
    stack 1        the remaining lanes on segments [17..26]
    sharing        at most 2 lane(s) per pseudo-channel per tensor
    DERIVED rate   1.60 core cycles per weight word = max(datapath 1.60, memory 1.60); the flat layout is 21.60
    peak fill      199307264 B = 190.07 MiB, 74.2% of a segment
    segment 0      5591040 B of headers + nonmatvec_f32.bin
    reserved segs  [16, 27, 28, 29, 30, 31]
    UNUSED         2229035008 B = 2.076 GiB in the 25 segment tails
  CONTEXT          75340 tokens (73.6k), against the 65536 required (64k).  Margin 1.15x
  free for KV      1.226 GiB from 0x1b1818000 => 75649 tokens of context
  A desc arena     159744 B at 0x1ffadd000 for 311 descriptors at 512 B
  total elapsed    7.1 s
```

7.1 seconds, and **not one byte of model data was written**: the outdir is
hardlinks into the existing set and every file reported `kept`. Disk cost of
the whole striped set is the manifest. The shipping
`qwen35-9b-mv4i-noembd/manifest.json` still has its 2026-08-29 18:07 mtime.

(`free for KV` says 75,649 and `hbm_map` says 75,340. The packer counts to the
top of the device; `hbm_map` subtracts the 5,386,240 B of top-anchored host
reservations = 309 tokens. Both are right about different questions and the
map's is the one to quote.)

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

### 5.1 Teeth: twelve mutations, each scored against all seven checks

`/mnt/storage/track-packstripe/teeth_stripe.py`. The right column IS the
attribution control -- it names which checks fired, not merely that one did.

| mutation | verdict | checks that FAILED |
|---|---|---|
| M1 one w piece moved a whole segment up | KILL | 1, 4 |
| M2 two lanes SWAPPED | KILL | **1 only** |
| M3 one piece misaligned by 1 byte | KILL | 2, 4 |
| M4 one piece 4096 B short (file no longer tiled) | KILL | **3 only** |
| M5 one tensor restored to the FLAT contiguous layout | KILL | 1, 4, 6, 7 |
| M6 two tensors given the same lane-0 address | KILL | **4 only** |
| M7 a segment arena declared past its segment | KILL | **5 only** |
| M8 a piece moved into its OWN segment free tail | **survives** | (none) |
| M9 two tensors swap their lane-0 arenas | **survives** | (none) |
| M10 a header moved elsewhere inside segment 0 | **survives** | (none) |
| M11 a stack-0 lane pointed at a stack-1 segment | KILL | 1, 4, 7 |
| M12 THREE lanes of one tensor on one pseudo-channel | KILL | **6 only** |

**CHECK 6 CHANGED STATUS WITH THE ALLOCATOR AND BOTH FACTS BELONG ON THE
RECORD.** Under the FIRST, 27-wide allocator it was "27 distinct segments", it
earned **zero independent kills**, and it was labelled decoration here: with a
unique `ENG_PORT_MAP` and a fixed lane -> segment table, check 1 logically
implied it. Under the shipping per-tensor allocator the map is no longer fixed,
so a lanes-per-pseudo-channel bound is a genuinely separate property, and
**M12 kills on check 6 ALONE.** The same rule was decoration in one design and
load-bearing in the next; nothing about the rule changed, only what else was
true around it.

**CHECK 7 IS THE NEW DECORATION AND IS LABELLED AS SUCH.** Every lane's allowed
segment set is partitioned by stack, so a cross-stack piece is always outside
that set and check 1 always co-fires: M11 kills on 1, 4 and 7 and there is no
mutation where 7 fires alone. It is kept as the readable statement of the
stack-locality property, credited with **zero independent kills**.

**M12 needed a second attempt and that is the attribution control working.**
The first version put three lanes on top of other tensors' bytes; check 4
caught the overlap and check 6 would have been credited with a kill an existing
check already had. Putting the three sub-regions in the segment's FREE TAIL,
where nothing overlaps, is what isolates check 6. **M8 needed a second attempt
for the mirror-image reason**: a fixed "240 MiB into the segment" ran off the
end for `output.weight`, whose sub-region is 23 MiB, so it KILLED on checks 1
and 4 and was measuring my constant rather than the checker.

**The three survivors are the resolution floor and two of them are not
defects.** M8 and M10 move a piece to a different legal address inside a segment
its lane may read; refusing those would be a check that fails on a safe
configuration. **M9 is a real defect that these checks structurally cannot
see**: two tensors swapping a lane arena is a well-formed placement in which one
lane reads the wrong tensor's bytes. What catches it is
`fk33_load_weights.py verify` reading HBM back and finding the per-file blake2b
wrong, and on the card the oracle comparison in `fk33_run_job.py`. **The
placement checks in this change are NOT a residency check and do not replace
one.** (`tools/hbm_map.py`'s new `manifest_piece_fails()` says the same thing
in its own docstring and cites M9 by name.)

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
T6    rc=2  refusing: 3 lanes land on one pseudo-channel and the manifest plans at most 2 -- this
              would NOT be the experiment
T7    rc=2  refusing: 27 lanes land on one pseudo-channel and the manifest plans at most 2 -- this
              would NOT be the experiment
```

T6 and T7 replace an earlier `len(segs) != 27` refusal that the compacted
layout would have tripped on a CORRECT placement. The property that makes this
the experiment is not "27 distinct segments" -- it is that no pseudo-channel is
asked for more lanes than the manifest planned, because the DERIVED rate is
`max(1.60, M/1.25)` and M is the whole variable.

**T3 originally SURVIVED and that is the most useful line in this document.**
The first version of the distinct-segment check counted the manifest's declared
`segment` FIELD, so two lanes given the same `hbm_offset` with their labels left
alone still looked like 27 distinct segments. A check that reads a label instead
of the thing the hardware decodes is decoration; address bits [32:28] are what
select the pseudo-channel. The check now derives the segment from the address
and reports the label/address disagreement separately (T3), which is why there
is a T3b at all.

---

## 6. The extent-aware KV change, costed. NOT APPLIED -- `rtl/**` is not mine

The shipping default meets the requirement at 1.15x. **Extent-aware KV is the
right end state anyway**: it takes the same 1.60 c/beat to ~219,000 tokens, a
3.3x margin, and it removes the whole width-versus-context trade instead of
tuning it. This section is the cost, so it can be dispatched or declined on
numbers. **Nothing in `rtl/**` was touched.**

### 6.1 What is actually in the way, MEASURED from the RTL

`rtl/attn_kv_axi.vhd:431`, the entire obstacle, verbatim:

```vhdl
  -- addr = base + ((layer*N_KVH + head)*MAXCTX + pos) * REC_B   (C spec 2.2)
  function rec_addr(base : std_logic_vector; lay, hd, ps : integer)
    return unsigned is
    variable idx : integer;
  begin
    idx := (lay*N_KVH + hd)*MAXCTX + ps;
    return unsigned(base) + to_unsigned(idx*REC_B, ADDR_W);
  end function;
```

One scalar base, one linear index. `rtl/llama_top.vhd:549` supplies it as
`C_K_BASE_CH` / `C_V_BASE_CH`, chunk counts at a 16 B granule. That is why a
tail cannot be used: the arena must be one run.

### 6.2 The change, and the shape it should NOT take

**REJECTED before costing: a strided map** -- `addr = base + (i/U)*S + (i mod U)`
where U is the usable bytes per 256 MiB segment. `REC_B` is 272, not a power of
two, so keeping records unsplit needs `floor(U/272)` records per extent and the
divisor is not a power of two. That is a constant-divisor divide in the ADDRESS
path, and this project has already spent real time on dividers
(`build_artifacts_itdiv/`, `rtl/divider_rs.vhd`). Rounding U down to a power of
two instead avoids the divider but throws away 30% of each tail.

**RECOMMENDED: a per-slice base table.** The index already decomposes as
`(layer, head)` selecting a slice and `pos` running inside it. Replace the
scalar with a table indexed by `lay*N_KVH + hd`:

```vhdl
  addr = base_tbl(lay*N_KVH + hd) + ps * REC_B
```

- **No divider, no modulo, no bit-slicing.** The multiply `ps*REC_B` is already
  there; only the addend's source changes.
- **Every record is contiguous by construction**, because a slice is contiguous
  and a record lives inside one slice. The straddle class does not arise.
- **Table size:** `LAY*N_KVH` = 8 x 8 = 64 slices for K and 64 for V = **128
  entries x ADDR_W 33 = 4,224 bits**, one small distributed ROM. ESTIMATE, from
  the entry count and width; not synthesised.
- **Slice size at ~219,000 tokens: 219,000 x 272 = 59.6 MB**, against the
  shipping default's 65.93 MiB tails. One slice per tail fits; the allocator
  packs the 128 slices across the 25 tails, segment 16 and segments 27..31.

### 6.3 What it recovers, DERIVED

```
shipping default KV          1,311,526,912 B     75,340 tokens
+ 25 segment tails           2,229,035,008 B    (MEASURED, printed by the packer)
+ segment 16                   268,435,456 B
                             ---------------
                             3,808,997,376 B   ~218,800 tokens   = 3.34x the 64k target
```

That is within rounding of the flat layout's 233,396, the difference being the
5,591,040 B of headers and blob in segment 0 and the reserved-segment rounding.

### 6.4 What it risks, named

1. **The table has to be LOADED, and that is the real cost, not the adder.**
   Today the base is a generic. 128 entries need either a register file on the
   AXI-Lite map or a descriptor field, i.e. a new control path with its own
   ordering hazard: a slice base read before it is written is a silent wrong
   address, exactly the class `rtl/attn_kv_axi.vhd:619`'s alignment check
   exists to catch.
2. **The width asserts assume two scalars.** `rtl/llama_top.vhd:4291-4334`
   sizes `C_KV_ADDR_W` from `maximum(C_K_BASE_CH, C_V_BASE_CH)` and checks
   K/V disjointness with a single pair of comparisons. Both become a reduction
   over 128 entries. An assert that silently stops covering 126 of them is the
   guard-shaped hole this project keeps finding.
3. **A slice must not straddle a 256 MiB boundary**, or a record inside it can.
   That is an allocator rule of the same class as the existing stack rule, and
   it is the packer's to enforce, not the RTL's.
4. **Three artefacts pin the scalar and must move together**:
   `tools/check_kv_map.py:256` (`C_K_BASE_CH*16 == manifest hbm.kv_base`),
   `sim/tb_attn_kv_map.vhd:122`, and `sim/mutate_kv_map.sh`.

### 6.5 The oracle that catches a mistake ALREADY EXISTS and has already bitten

`sim/mutate_kv_map.sh` carries a `k_one_byte` row -- a base one byte high --
and `rtl/attn_kv_axi.vhd:608` records that it was MEASURED to kill before the
alignment check existed. `tools/check_kv_map.py` compares the RTL's constants
against the manifest's `kv_base` and would compare the table against a manifest
`kv_slices[]` the same way. So the change does not need a new verification
strategy invented for it: **extend the existing per-base comparison to 128
bases, and extend the mutation row to perturb one slice base rather than the
one.** A mutation that moves slice 63 and is not caught means the checker is
covering 1 of 128, which is the 250-in/249-checked shape again and is exactly
what to look for.

**ESTIMATE of size, with the assumption stated:** a table declaration, one
indexed read replacing one signal read in `rec_addr`'s call sites (two, at
`:813` and `:952`), the two assert reductions, the load path, and the three
artefact updates. The RTL edit itself is small; **the load path is the part
that is not, and it is the part to scope before dispatching.**

### 6.6 The cheaper option, if the RTL is contested

**Narrow the stripe further.** The width curve is already printed and already
refuses anything worse than 2 lanes per pseudo-channel: `n=8` yields **106,180
tokens at the same DERIVED 1.60 c/beat**, for `--stripe-stack1-segments 8` and
no code change anywhere. Its cost is 92.8% peak segment fill, which leaves
almost nothing for a future model or for restoring `token_embd.weight`. That is
the whole trade and it needs no RTL.

## 7. What this change needs from files TRACK PACKSTRIPE does not own

Each delta is specified. **None was applied.** All four are small and none
touches an address computation -- they teach four consumers that one file can
occupy more than one extent.

### 7.1 The refusals, MEASURED, so the deltas are not hypothetical

Against the `hbm_map.py` that existed when the striped manifest was first
written:

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

### 7.1a UNMISSABLE: A GUARD THAT PASSED OVER 7,154 RANGES OF WHICH ZERO EXIST

**This is the fourth guard-passing-for-the-wrong-reason found on this project
today and the second of exactly the 250-in / 249-checked shape. It is recorded
here as a PATTERN, not as one bug.**

```
$ python3 tools/check_hbm_stack.py <striped>
checked 7154 byte ranges against a 4294967296 B stack boundary
PASS no range crosses a stack boundary          rc=0
```

`tools/check_hbm_stack.py:93,101` builds every range as
`e["hbm_offset"] + <flat layout offset>`. Under striping those ranges are
**fictitious**: a 4 KB header's address plus the offsets of sub-regions that are
somewhere else entirely. Every one of them lands in the low 34 MB of segment 0,
so none *can* cross the 4 GiB line and the `PASS` is guaranteed **regardless of
the truth**. It checked 7,154 ranges of which **zero exist**.

The striped layout does satisfy the stack rule -- DERIVED: every piece is inside
one 256 MiB segment (check 1), a segment is inside one stack, and check 7 keeps
every lane on its own master's stack -- **but that PASS is not the evidence, and
reading it as evidence is the 2026-08-29 "verify passed an object it never read"
failure with a new number.**

The four found today, so the shape is visible in one place:

| guard | what it printed | what it had actually read |
|---|---|---|
| `fk33_load_weights.py verify` (2026-08-29) | `249 headers parsed and matched`, PASS | 249 of 250 objects; `nonmatvec_f32.bin` fell through both checks |
| a descriptor base rule in `gen_mv4i_desc.py` | agreed with its cross-check | agreed **by coincidence of geometry** on every file it had ever seen |
| three `util_pkg.vhd` copies | regenerated and matching | regenerated by a script **nothing schedules** |
| **`check_hbm_stack.py` on a v2 manifest (today)** | **`checked 7154 byte ranges`, PASS** | **7,154 ranges that do not exist** |

The tell is identical every time: **the check has never been shown to
discriminate on the thing it guards.** `check_hbm_stack.py` has never been run
against a layout whose real ranges could cross a stack line, so its PASS
carries no information in either direction. It is a v1 consumer; its verdict on
a v2 manifest is not evidence.

### 7.1b hbm_map.py's delta HAS LANDED, by another track, and it does not collide

MEASURED after the fact: `tools/hbm_map.py` in the working tree now carries
`file_pieces()` and `manifest_piece_fails()` (uncommitted, another track's), and
the shipping striped manifest **PASSES it directly** over 6,973 real extents --
no expansion adaptor needed. Its P1-P6 rules are tiling, byte-sum, the
`hbm_offset`-is-the-header rule, the header's declared stack, the label-versus-
address decode, and the granule. **None of them assumes one lane per segment or
that a lane reads its own master's segment**, so the compacted default satisfies
all six; that track's own docstring scopes the master-segment rule OUT and cites
this document's check 1 and teeth M9 by name. No collision.

`tools/pack_model_fk33.py::expand_pieces()` was knowingly a second producer of
the region model. It now **defers**: the packer feature-tests
`hasattr(HM, "file_pieces")` and hands `derive_region_block()` the manifest
unexpanded when `hbm_map` owns it, so the duplicate goes dark the moment that
track lands and the packer still works if it does not.

### 7.2 `tools/hbm_map.py` -- DONE by another track, kept for the record

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

**RE-STATED FOR THE LAYOUT THAT IS NOW THE DEFAULT.** Arm B runs the shipping
25-segment compacted layout, not the 27-wide one. Prediction, before the run:

| arm | layout | max lanes/PC | CYCLES | cycles/beat | VERDICT |
|---|---|---|---|---|---|
| A, flat control | 1 segment | 27 | **8,300 - 8,900** (COUNTERS measured 8,582) | ~22 | **PASS** |
| B, striped default | 25 segments | **2** | **under 1,500**, DERIVED floor 613, ESTIMATE 613-950 | 1.6 - 2.5 | **PASS** |

**The threshold does not move between the two striped layouts and here is why,
DERIVED.** The supply model is `max(1.60 datapath, M/1.25 memory)`. At M = 1 it
is `max(1.60, 0.80) = 1.60`; at M = 2 it is `max(1.60, 1.60) = 1.60`. Both give
613 cycles for a 384-beat job. So COUNTERS' "under 1,500" survives the change of
default unaltered.

**What DOES move is the confidence in the lower end, and this is an ESTIMATE
with its assumption stated.** At M = 2 the memory supplies exactly what the
datapath consumes, with zero slack. COUNTERS' run A shows 394 of 1,188 cycles
going to AR issue and FIFO fill even with an ideal memory, and a memory matched
exactly to consumption cannot hide any of it. So arm B is expected somewhere in
**613 to 950 cycles** rather than at 613. The probe prints the max lanes per
pseudo-channel for the specific tensor, so the arm reports which case it ran:
`blk.0.ffn_gate.weight` under the shipping default is **M = 2** (MEASURED from
the manifest by the probe in dry-run).

**If you want the M = 1 point as well**, repack with
`--stripe-stack1-segments 12 --stripe-min-context 40000` into a separate outdir
and run a third arm. That is the 27-wide layout, it yields 44,500 tokens, and it
is the clean measurement of whether M = 2 costs anything. **It is the only way
to find out**, because the model says zero and the model has never been tested
at M = 2.

**`VERDICT` must stay `PASS` in ALL arms.** That is the value half and it is not
optional. Subsystem A is proven bit-exact on this silicon over 1,675,264 rows; a
placement change that perturbs one weight would look like a hardware fault.

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

# 4b OPTIONAL third arm, the M=1 point.  Repack into a SEPARATE outdir; it
#    yields only 44,500 tokens and is a measurement, not a shipping layout.
#    (Needs the .mv4i files present -- hardlink them in first, as the striped
#     set was made.)
#      python3 tools/pack_model_fk33.py <GGUF> <NEWDIR> --rows-if 48 \
#          --axi-dw 256 --drop token_embd.weight --stripe-lanes \
#          --stripe-stack1-segments 12 --stripe-min-context 40000
#    then re-run step 3 against <NEWDIR>/manifest.json.

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
  and ref/mv_fk33_tr (C)`; for arm B only, `RELOCATION 27 sub-regions -> 25 segments
  [1..15, 17..26]`, `sharing at most 2 lane(s) per pseudo-channel for THIS
  tensor (the manifest plans at most 2)`, the DERIVED rate line, and
  `gateware would ACCEPT`; then
  `counters    CYCLES=... BEATS=384 STARVED=...`; then
  `result read 100 of 100 rows, compared 100 of 100 against ref/matvec_int4.c,
  0 differ`; then `VERDICT PASS`.
- **step 5** must end `VERDICT FAIL`.

### 8.3 Failure modes, and what each one would mean

| what you see | reading |
|---|---|
| arm A ~8,600, arm B **under 1,500**, both PASS | **The finding is confirmed.** Ship the striping; build section 7's four deltas. |
| arm A ~8,600, arm B ~8,600, both PASS | The 27 masters are NOT limited by the destination pseudo-channel. Next suspect is the HBM global switch's lateral bandwidth, or an arbitration point upstream of the switch. COUNTERS named this as the falsifier; the whole analysis is wrong. |
| arm B between 950 and 1,500, PASS | The finding is confirmed and **M = 2 costs more than the model says**. Re-run the optional M = 1 arm (step 4b) to price it; if that one lands near 613, widen the stripe and take the context from the extent-aware KV change instead. |
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
RELOCATION  27 sub-regions -> 25 segments [1, 2, ... 15, 17, ... 26]
  sharing     at most 2 lane(s) per pseudo-channel for THIS tensor (the manifest plans at most 2)
  DERIVED     1.60 core cycles per weight word = max(datapath 1.60, memory 1.60); the flat layout is 21.60
  w[ 0]  0x0038205000 -> 0x0012142000  seg  1  file +4096      1048576 B
  w[ 1]  0x0038305000 -> 0x0022142000  seg  2  file +1052672   1048576 B
  s[ 2]  0x0039C05000 -> 0x0182542000  seg 24  file +27267072  1048576 B
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
| **A FIXED lane -> segment table with two lanes per segment (my own first "21-segment hybrid")** | Two lanes' arenas are 316.61 MiB against a 256.00 MiB segment. The fallback I published in the first version of this document could not have been built. | Compaction requires a PER-TENSOR assignment. A fixed table cannot go below 27 segments at this model size, full stop. |
| **The "8.6x for a 21-segment hybrid" figure I published** | 250/200 = 1.25 beats per core cycle, not 200/250 = 0.8. Two lanes per pseudo-channel is **1.60** c/beat, equal to the datapath floor, not 2.50. | The ratio is ACLK over core clock. Getting it upside down made a free option look like a 36% give-back and nearly cost the right default. |
| **A strided extent-aware KV map, `addr = base + (i/U)*S + (i mod U)`** | `REC_B` = 272 is not a power of two, so keeping records unsplit needs a non-power-of-two divisor in the ADDRESS path. Rounding U down to a power of two avoids the divider and throws away 30% of every tail. | Use the per-slice base table in section 6.2 instead: no divider, and records are contiguous by construction. |
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
7. **I inverted a clock ratio and it changed a design decision.** "1 beat per
   AXI cycle = 0.8 beats per core cycle" is wrong; ACLK 250 over core 200 is
   **1.25**. The error made two-lanes-per-pseudo-channel look like a 2.50
   c/beat, 36% give-back when it is 1.60 and free. It survived a full write-up
   because 2.50 was plausible and nothing cross-checked it. **The fix that
   would have caught it in seconds: state the model, then run it against BOTH
   known anchors.** M = 27 must give 21.60 (COUNTERS' DERIVED, card's MEASURED
   21.67) and M = 1 must give the datapath floor. A model that reproduces two
   independent anchors is very hard to have upside down.
8. **A fallback I published had never been checked for CAPACITY.** The
   21-segment hybrid was costed for speed and for context and not for whether
   the bytes fit -- and they do not, by 24%. Cost every axis of an option
   before offering it, including the one the rest of the document already
   established as the constraint.
9. **A blind `rm`-free scratch run still cost two minutes: pointing the packer
   at a NEW outdir made it repack for real** instead of reusing hardlinks, and
   it had to be killed at the timeout with a mutated source file in the tree.
   Restore first, diagnose second. The restore was verified by grep, not
   assumed.
10. **`tools/check_mv4i_set.py MANIFEST.json` silently doubles the path** and
   reports `no manifest at .../manifest.json/manifest.json`. It wants the
   DIRECTORY. Two minutes lost; noted so the next reader loses none.

---

## 11. Open, not yet answered

1. **The 13.5x is DERIVED and the 14.0x is COUNTERS' simulation. NEITHER IS
   MEASURED.** Only section 8 settles it, and only on the card. Do not repeat
   either number as a measurement.
1b. **M = 2 HAS NEVER BEEN TESTED, in simulation or on silicon.** The whole
   compaction rests on `max(1.60, M/1.25)` giving 1.60 at M = 2, and the model
   reproduces the M = 1 and M = 27 anchors but has no anchor between them. If M
   = 2 costs anything real, the shipping default is slower than the 27-wide
   stripe it replaced and the right answer is to widen and take the context
   from section 6 instead. **Step 4b of the card test is the measurement that
   prices it and it takes one extra run.** This is the single largest unhedged
   assumption in this document.
2. **Nothing in the striped set has been loaded onto a card.** Section 5 proves
   the addresses are internally consistent and the bytes unchanged; it says
   nothing about residency. The residency backstop is
   `fk33_load_weights.py verify`, which cannot run until section 7.4 lands.
3. **Whether subsystems B, C and D have the same pathology.** COUNTERS' open
   item 5. The GDN state and the KV arena are single large regions and any
   multi-master read of them hits the same 256 MiB granularity.
   `rtl/attn_kv_axi.vhd` has its own `starv` counter and neither track has
   looked at it. Under this layout the GDN state sits alone in segment 27,
   which is at least not contending with a weight lane.
4. **The extent-aware KV change is COSTED but not scoped in engineering time.**
   Section 6 gives the shape (a 128-entry per-slice base table, no divider),
   the recovery (~219,000 tokens, 3.3x the target), the four named risks and
   the oracle that already exists and has already bitten. **The RTL edit is
   small; the load path for 128 bases is not, and that is the part to scope
   before dispatching.** Until then the shipping default meets the requirement
   at 1.15x and `--stripe-stack1-segments 8` is the no-RTL route to 106,180
   tokens at the same DERIVED rate, at 92.8% segment fill.
5. **`expand_pieces()` is now dark but not deleted.** `hbm_map.py` has grown
   its own piece awareness (section 7.1b) and the packer feature-tests for it,
   so the duplicate producer no longer runs. It should be DELETED once that
   track commits; leaving a dead second producer in the tree is how it comes
   back.
6. **The lane arenas are packed in manifest order and nothing pins the order.**
   Teeth M8/M9 show the checks do not constrain where inside its segment a
   lane's arena for a given tensor sits. That is correct today -- the address is
   in the manifest and the descriptor reads it -- but if anything ever derives a
   lane address arithmetically instead of reading it, this becomes the hole
   M9 describes.
7. **Segment 16's 256 MiB and the 2.076 GiB of tails are declared free and
   nothing can use them.** Stated in the packer's own summary line rather than
   left for a reader to compute. Section 6 is the change that would.
8. **The context margin is 1.15x and that is thin.** 75,340 against 65,536.
   Restoring `token_embd.weight` to the image, or a larger model, moves the
   whole curve and the packer would then refuse rather than ship. That refusal
   is the intended behaviour, but it means the 64k requirement is currently met
   with less headroom than any other number in this document.
9. **Whether the greedy per-tensor assignment is STABLE against a change in
   manifest order.** It bump-allocates on current fill in `recs` order, so a
   different tensor order gives a different, equally valid layout. Nothing
   depends on the specific one -- the manifest states every address -- but two
   packs of the same model are not guaranteed byte-identical manifests, and
   nothing checks that they are.

---

## 11b. The flat path is unchanged, MEASURED

Re-running the packer with NO `--stripe-lanes` over the same GGUF and the same
`--drop token_embd.weight`, into a fresh outdir of hardlinks, and comparing
against the shipping manifest:

```
flat files[] identical to the shipping set: True
flat hbm kv/gdn identical: True     (kv_base, gdn_state_base, weights_end,
                                     max_context_tokens, desc_arena_base)
  weights          4487442432 B   GDN state 24.1 MB at 0x10c006000
  stack holes      8876032 B at 0xff789000
  free for KV      3.789 GiB from 0x10d81e000 => 233705 tokens
  A desc arena     159744 B at 0x1ffadd000
```

**`files` is byte-identical** -- every `hbm_offset`, every digest, every entry,
in the same order -- and so is every address in `hbm`. The only field this
change adds to a flat manifest is `geometry.lane_stripe: false`.

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
- **The context requirement was not in the brief and it decides the design.**
  Oren, 2026-08-30: "Not a requirement, even 64k ish is fine." Against it the
  27-wide stripe I first shipped as the default FAILS at 44,500 tokens. The
  requirement is now a tool default (`--stripe-min-context 65536`), a refusal,
  and the last line of the packer's summary, so it cannot be missed again by
  anyone who never opens this file.
- **"3. The repack."** There is no repack. The `.mv4i` bytes are a function of
  the tensor and the geometry, not of the address. `--stripe-lanes` over an
  existing set re-places and rewrites only the manifest, in 7.9 s, and every
  digest is unchanged -- which is what makes section 5 part A an oracle instead
  of a tautology.

---

## 13. What changed in the tree

| path | change |
|---|---|
| `tools/pack_model_fk33.py` | `--stripe-lanes`, `--stripe-min-context` (default 65,536), `--stripe-stack1-segments`, `scrape_eng_port_map()`, `_lane_groups()`, `_assign_group()`, `lane_stripe_plan()` (per-tensor, stack-local), `stripe_context_tokens()`, `choose_stripe_width()`, `check_lane_stripe()` (seven invariants), `expand_pieces()` (now feature-tested dark), the `hbm.lane_stripe` manifest block, the `format` v2 bump, the placement-independence assert. The flat path is untouched and is still the default. |
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
