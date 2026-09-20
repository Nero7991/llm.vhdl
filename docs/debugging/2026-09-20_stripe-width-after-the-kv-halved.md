# Stripe width after the KV halved: does one lane per pseudo-channel fit now?

TRACK STRIPE27, 2026-09-20. Workstation, no hardware, no Vivado.

---

## 1. The question, verbatim

> `tools/pack_model_fk33.py --stripe-lanes` gives each of the 27 AXI read
> masters its own 256 MiB HBM segment where it can, but it COMPACTS the 12
> stack-1 lanes onto fewer segments, because the KV cache needed the space
> above them. [...] TRACK KVREG dropped the card's `C_MAXPOS` and `C_CTXLEN`
> from 131,072 to 65,536 (commit 109dc27) [...] That is 1.06 GiB of HBM given
> back, which is roughly four 256 MiB segments. Whether it is enough to widen
> the stripe from 12 stack-1 segments to the full set is the question; nobody
> has re-run the search since.
>
> [...] say plainly whether the current 75 MHz card is supply-bound at all,
> i.e. whether this change does ANYTHING without the 200 MHz A clock.

Hardware and build: SQRL FK33, `xcvu33p-fsvh2104-2L-e`, 8 GiB HBM, the
shipped `FK33_CARD=1` bitstream at engine core 75 MHz / ACLK 250 MHz,
`hw/fk33/gen_fk33_card.py` `C_MAXPOS=65536` `C_CTXLEN=65536`. Model
`/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf`, geometry
`ROWS_IF=48 AXI_DW=256`, 27 AXI read masters.

---

## 2. The answer, up front

**At 75 MHz this change does nothing at all, and at 200 MHz the average-rate
model also predicts nothing.** The busiest pseudo-channel at two lanes supplies
a beat every 8.00 ns. The card's striped A engine consumes one every 20.40 ns
(MEASURED, 7,931,072 cycles over 5,184,384 beats at 75 MHz). The supply bound
is slack by 12.40 ns per beat, i.e. **the memory is idle 61% of the time
already**; halving the bound to 4.00 ns changes nothing that is binding. At
200 MHz the demand is 10.15 ns per beat (MEASURED, engine-only build) against
the same 8.00 ns supply, so the bound is still slack, by 21%.

**And the premise is wrong: the KV halving gave nothing back.** The packer's
context bar has been `DEFAULT_MIN_CONTEXT_TOKENS = 65536` since the striping
landed on 2026-08-30, which is the number `C_MAXPOS` was *lowered to*.
`gen_fk33_card.py`'s own comment says the halving was done "so the STRIPED
layout fits" -- the card was writing a 131,072-token extent into a layout that
only ever yielded 75,340, which is the extent side of the 2026-09-20
silent-overwrite defect. Nothing above `kv_base` was freed for weights, because
nothing above `kv_base` was ever occupied by weights.

**One lane per pseudo-channel is a real layout and it is built**, at
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-stripe27`, 27 lanes on 27
segments, max 1 lane per PC on every one of the 249 tensors. **It yields 44,341
tokens of context, 32.3% below the 65,536 the shipped card writes**, and
`tools/check_kv_map.py` refuses it against the shipped bitstream on 3 rows. It
is a MEASUREMENT image and must not be loaded until a card is rebuilt at
`C_MAXPOS <= 44341`.

The upper bound on what it could buy, if the ENTIRE 0.43 cycles/beat that the
200 MHz build sits above its datapath floor turned out to be pseudo-channel
contention rather than datapath overhead: **3.2% of a token** (0.3484 s ->
0.3372 s), for 32.3% of the context. That is a bad trade, and 3.2% is the
optimistic end of a range whose realistic end is zero.

---

## 3. The procedure, in the order it was run

Each step isolates one thing. Nothing below touched the card, Vivado, or the
two existing images.

| # | probe | what it isolates |
|---|---|---|
| 1 | read `lane_stripe_plan`, `_assign_group`, `choose_stripe_width`, `stripe_context_tokens`, `check_lane_stripe` and the `--stripe-*` arguments | what the compaction is actually a function of |
| 2 | read the shipped striped manifest's `hbm.lane_stripe.width_search` | the curve as it was on 2026-08-30, so a re-run can be compared against it rather than replacing it |
| 3 | re-run `choose_stripe_width()` against today's tree with the manifest's own `recs`, at the 65,536 bar and with no bar | the curve TODAY, and whether anything moved |
| 4 | `grep C_MAXPOS hw/fk33/gen_fk33_card.py` and read the comment above it | the RTL's own account of why the halving happened. CLAUDE.md: where a document and the RTL disagree, the RTL wins, and here the RTL contradicted the brief |
| 5 | build the n=12 image into a NEW directory by symlinking the 250 packed files and re-running the packer without `--force` | addresses only. The per-file blake2b digests are the oracle for "addresses changed, values did not" |
| 6 | per-tensor `(segment, lanes-on-it)` census on both manifests | the point of the exercise, measured on the output rather than argued from the plan |
| 7 | `tools/pack_gdn_consts.py` against the new manifest | whether the new layout needs the `gdn_const` region the way the shipped one does, and at what base |
| 8 | `tools/check_kv_map.py --striped-manifest <new>` | whether the card, as built, can address the new layout |
| 9 | a new refusal in the packer, with a mutant, an attribution control and a non-regression control | close the hole that let step 5 write an unloadable image in the first place |
| 10 | `tools/gen_layer_program.py --token` against both manifests, byte-compared | that the D program is placement-independent and only the A arena moves |
| 11 | the supply-vs-demand arithmetic at 75 and 200 MHz | the actual question |

Controls used throughout: the SHIPPED width (n=10) re-packed with every change
in place, and the FLAT image re-packed the same way. Both must be byte-identical
to what is on disk, and both are.

---

## 4. The evidence, as raw output

### 4.1 The width curve, re-run 2026-09-20 (MEASURED)

`choose_stripe_width()` with the shipped manifest's own 249 records, today's
`tools/`, `kv_top = hbm.desc_arena_base = 0x1ffadd000`:

```
  stripe width search (stack-1 segments; stack-0 stays 1:1)
    n   max lanes/seg   DERIVED c/beat   peak fill   KV tokens
   12        1             1.60           61.8%      44432  (under the 65536 target)
   11        2             1.60           69.7%      59852  (under the 65536 target)
   10        2             1.60           74.2%      75272  <== chosen
    9        2             1.60           82.5%      90692
    8        2             1.60           92.8%     106113
    7   REFUSED: pack_model_fk33: HBM segment 21 overflows
    6   REFUSED: pack_model_fk33: HBM segment 17 overflows
    5   REFUSED: pack_model_fk33: 27 lanes onto 20 segments puts 3 lanes on one pseudo-channel
    4   REFUSED: pack_model_fk33: 27 lanes onto 19 segments puts 3 lanes on one pseudo-channel
    3   REFUSED: pack_model_fk33: 27 lanes onto 18 segments puts 4 lanes on one pseudo-channel
    2   REFUSED: pack_model_fk33: 27 lanes onto 17 segments puts 6 lanes on one pseudo-channel
    1   REFUSED: pack_model_fk33: 27 lanes onto 16 segments puts 12 lanes on one pseudo-channel
```

`n = 12` is the one-lane-per-pseudo-channel point: 15 stack-0 lanes on segments
1..15 and 12 stack-1 lanes on 17..28, 27 lanes on 27 segments.

The same eight rows in the shipped manifest's stored `width_search` read 44,500
/ 59,920 / 75,340 / 90,760 / 106,180. **The 68-token difference is not noise and
not a change in the search**: `hbm_map.arena_sizes()` has since grown
`gdn_state_conv_bytes_per_layer`, so `GDN_STATE_BYTES` went 25,264,128 ->
26,443,776 and every `kv_base` moved up by 1,179,648 B. The `gdn` column is
identical in all eight rows, which is what attributes the delta to the GDN
state and not to the placement.

**The chosen width did not move.** `n = 10` then, `n = 10` now.

### 4.2 Why the KV halving freed nothing (MEASURED, from the RTL)

`hw/fk33/gen_fk33_card.py:341`, the generator's own comment above the generic:

```
# C_MAXPOS HALVED 2026-09-20, 131072 -> 65536, so the STRIPED layout fits.
```

and `tools/pack_model_fk33.py:163`, unchanged since 2026-08-30:

```
DEFAULT_MIN_CONTEXT_TOKENS = 65536
```

The bar the packer refuses below was ALREADY the number `C_MAXPOS` was lowered
to. The halving moved the CARD down to meet the layout; it did not move the
layout. DERIVED: 44,432 < 65,536 before the halving and 44,432 < 65,536 after
it, so `n = 12` was refused for the same reason on both days.

### 4.3 The per-tensor pseudo-channel census (MEASURED, from the manifests)

```
striped (n=10)   (segment, lanes-on-it) -> number of tensors
   {(17, 2): 34, (18, 2): 34, (19, 2): 56, (20, 2): 56, (21, 2): 53,
    (22, 2): 53, (23, 2): 55, (24, 2): 55, (25, 2): 51, (26, 2): 51}
   max lanes on any PC for any tensor: 2
   segments used: [1..15, 17..26]
stripe27 (n=12)   (segment, lanes-on-it) -> number of tensors
   none with >=2
   max lanes on any PC for any tensor: 1
   segments used: [1..15, 17..28]
```

Note for the record: the brief quoted the shipped census as `{(25,2): 249}`.
That is not what the manifest holds. Every one of the ten compacted segments
carries two lanes on 34 to 56 of the 249 tensors, because `_assign_group()` is
greedy on fill and re-decides per tensor; no single segment is "the busiest" for
all of them. The DERIVED rate is the same either way, since the model is per
tensor.

### 4.4 The packer's own checks on the new layout (MEASURED)

```
  stripe check 1 every piece is inside a segment its lane's group owns    PASS  0 violation(s)
  stripe check 2 every piece 4 KB aligned in HBM and in the file          PASS  0 violation(s)
  stripe check 3 the pieces tile the file exactly, in order               PASS  0 violation(s)
  stripe check 4 no two pieces overlap in HBM                             PASS  0 of 6971 adjacent pairs
  stripe check 5 every segment arena fits                                 PASS  peak fill 61.8%
  stripe check 6 no tensor puts more than 1 lane(s) on one pseudo-channel PASS  worst observed 1, DERIVED 1.60 c/beat vs datapath 1.60
  stripe check 7 every lane reads only its own master's HBM stack         PASS  0 violation(s)
  lane stripe      ON, 27 lanes on 27 segments of 256 MiB
    stack 0        lanes 0..14 1:1 on segments [1..15]
    stack 1        the remaining lanes on segments [17..28]
    sharing        at most 1 lane(s) per pseudo-channel per tensor
    DERIVED rate   1.60 core cycles per weight word = max(datapath 1.60, memory 0.80); the flat layout is 21.60
    peak fill      165994496 B = 158.30 MiB, 61.8% of a segment
    reserved segs  [16, 29, 30, 31]
    UNUSED         2765905920 B = 2.576 GiB in the 27 segment tails
  CONTEXT          44432 tokens (43.4k)
```

`python3 tools/check_hbm_stack.py <newdir>` -> `checked 7154 byte ranges [...]
PASS no range crosses a stack boundary`.

### 4.5 The digest oracle: addresses changed, values did not (MEASURED)

```
files in striped: 250  files in stripe27: 250
same file set: True
digests EQUAL   : 250
digests DIFFERENT: 0 []
null digests    : 0
files whose hbm_offset (header) moved: 0
pieces: 6972 6972 moved: 2978
pieces whose SEGMENT changed: 2534
```

**250 of 250 blake2b-128 digests are equal**, covering the 249 `.mv4i` files
and `nonmatvec_f32.bin`, while **2,978 of 6,972 placed pieces moved and 2,534
changed pseudo-channel.** The packed bytes are the same bytes -- the two
directories are 250 symlinks each onto the same underlying files -- and the
manifest digests confirm the packer took the `KEPT` path for every one. The
`gdn_const.bin` image is independently equal: blake2b-128
`ec3eda1ae15abf20326541ceacdeb917` in both manifests.

### 4.6 `gdn_const` on the new layout (MEASURED)

The new manifest needs it exactly as the shipped one does, and lands at the
same base, because `derive_gdn_const_block()` anchors to the descriptor arena
and the arena is placement-independent:

```
  gdn_const_base               absent         -> 0x1_ff95_a000
  gdn_const_bytes              absent         -> 1585152
  gdn_const_layers             absent         -> 24
  free_after_gdn               778862592      -> 771891200
  max_context_tokens           44741          -> 44341
  gdn_const_blake2b_128        ec3eda1ae15abf20326541ceacdeb917
PASS  every decoded value is within half a quantum of the source and every
      exponent is the rule's
```

44,341 is the honest context figure. The packer prints 44,432 because
`gdn_const` does not exist when the packer runs; `pack_gdn_consts.py` carves
1,585,152 B (91 tokens) out of the KV arena's top afterwards and rewrites
`max_context_tokens` in place.

### 4.7 The card cannot address it (MEASURED, `tools/check_kv_map.py`)

```
check_kv_map rc=1
  ok      striped manifest: V == K + C_MAXPOS*(kv_bytes_per_token/2)  K 7811072000, V 8381497344, K + 65536*8704 = 8381497344
  ok      striped manifest: KV extent starts at hbm.kv_base           K 7811072000 vs hbm.kv_base 7811072000 (delta 0)
  REFUSED striped manifest: KV extent inside hbm.size                 [7811072000, 8951922688) against size 8589934592 (361988096 bytes past the end)
  ok      striped manifest: KV extent intersects no weight piece      0 of the pieces of 250 files intersect [7811072000, 8951922688)
  ok      striped manifest: KV extent clear of gdn_state              gdn_state [7784628224, 7811072000) against KV [7811072000, 8951922688)
  REFUSED striped manifest: KV extent clear of gdn_const              gdn_const [8582963200, 8584548352) against KV [7811072000, 8951922688)
  REFUSED striped manifest: KV extent clear of desc_arena             desc_arena [8584548352, 8584708096) against KV [7811072000, 8951922688)
check_kv_map: 38 rows, 3 refused, 0 not run
```

The extent assertions the brief asked for already exist: TRACK KVREG added
`kv_extent_rows()` this morning, and it checks exactly `[kv_base, kv_base +
2 * C_MAXPOS * kv_bytes_per_layer_per_token * kv_layers / 2)` against every
piece of every file and against `gdn_state`, `gdn_const` and `desc_arena`. It
did not need extending; it needed running against this layout.

The exact boundary, one token either side (MEASURED):

```
stripe27: kv_base 7811072000, ceiling gdn_const_base 8582963200 -> 44341 tokens
  C_MAXPOS=65536   REFUSED (3 rows)
  C_MAXPOS=44342   REFUSED (1 rows)
        KV extent clear of gdn_const | gdn_const [8582963200, 8584548352) against KV [7811072000, 8582977536)
  C_MAXPOS=44341   ACCEPTED
  C_MAXPOS=32768   ACCEPTED
```

### 4.8 The new refusal in the packer, and its teeth

`tools/check_kv_map.py` can only refuse an image that already exists. The
packer wrote this one and reported success, because `--stripe-min-context` is
an operator preference and the card's `C_MAXPOS` is a compiled-in extent, and
nothing connected the two. Added: `scrape_card_maxpos()` reading
`hw/fk33/gen_fk33_card.py`, a refusal when the layout leaves fewer tokens than
the card writes, three new manifest fields (`card_c_maxpos`,
`card_kv_tokens_available`, `card_kv_fits`) and an explicit
`--stripe-allow-under-maxpos` for a measurement image.

| # | mutant | new check | verdict | what it measures |
|---|---|---|---|---|
| T1 | n=12 layout, 44,432 tokens, card writes 65,536 | ON | **REFUSED**, nothing written | the check bites on the real case |
| T2 | the SAME layout | **OFF** (`--stripe-allow-under-maxpos`) | **accepted, rc=0, 7 of 7 pre-existing stripe checks PASS** | **the attribution control: every existing check was blind** |
| T3 | the SHIPPED n=10 layout, 75,272 tokens | ON | accepted, `card_kv_fits: true` | non-regression on the shipping path |
| T4 | the FLAT layout, 233,328 tokens | ON | accepted, files byte-identical to the image on disk | non-regression on the other path |
| T5 | `C_MAXPOS` generic RENAMED in the generator | ON | **REFUSED** | the scrape goes dark rather than silently returning nothing |
| T6 | TWO different `C_MAXPOS` in the generator | ON | **REFUSED** | a second producer of the number |
| T7 | the generator file absent | ON | accepted, returns `None`, no check | deliberate: a tree without a card generator must still pack |

T1, raw:

```
  stripe check 1 every piece is inside a segment its lane's group owns    PASS  0 violation(s)
  ... (2..5 PASS) ...
  stripe check 6 no tensor puts more than 1 lane(s) on one pseudo-channel PASS  worst observed 1
  stripe check 7 every lane reads only its own master's HBM stack         PASS  0 violation(s)
pack_model_fk33: this layout leaves 44432 tokens of KV between kv_base
0x1d1938000 and the descriptor arena 0x1ffadd000, and the CARD writes 65536
(hw/fk33/gen_fk33_card.py C_MAXPOS).  The last 21104 tokens of the V region
would land in gdn_const, the descriptor arena and the host blocks, and nothing
on the card faults -- it is the 2026-09-20 silent-overwrite class from the
extent side.  Nothing was written.
```

T3 non-regression, exact:

```
NON-REGRESSION: re-packing the SHIPPED width with the new check in place
  files identical (name, hbm_offset, nbytes, digest, every piece): True
  hbm keys only in the NEW run: ['card_c_maxpos', 'card_c_maxpos_source',
                                'card_kv_fits', 'card_kv_tokens_available',
                                'gdn_state_conv_bytes_per_layer']
  card_c_maxpos 65536  card_kv_tokens_available 75272  card_kv_fits True
```

T4 non-regression: `files identical: True`, `card_kv_tokens_available 233328`.

### 4.9 The token program (MEASURED)

```
python3 tools/gen_layer_program.py --token --shape 9b --x-exp 0 \
  --manifest /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-stripe27/manifest.json \
  --d-table  <SD>/program/token.dtbl \
  --rel-file <SD>/program/token.rel \
  --arena-image <SD>/program/token.arena \
  --json     <SD>/program/token.json
A arena image: 311 descriptors x 512 B stride = 159232 B; load at HBM
0x1FFADD000 (hbm.desc_arena_base)
```

Byte-compared against the same command run on the SHIPPED striped manifest:

```
token.dtbl IDENTICAL
token.rel  IDENTICAL
token.arena DIFFERS: 10376 of 159232 bytes
```

The D table and the relocation file are placement-independent; the whole
difference is the 27 per-lane 64-bit bases inside the A descriptors, which is
what a lane stripe is. `--x-exp` is REQUIRED and its value is irrelevant on the
card (`USE_XEXP_PORT` reads the live exponent from D); 0 is used above.

Digests of the emitted program:

```
b6d8888913c8bd58aee27638dc1bfbdcb6a77e383844e989ba8e7836786dd156  token.dtbl
7c6e8ae899eadb2a1858b182b88453d50d38a10cc704146ac0922cb2b6eb98f4  token.rel
689d960251f3c934ced71b54fe1156d360132034bbb8fa9dc8f967e672cc9cda  token.arena
```

### 4.10 The arithmetic that answers the question (DERIVED)

```
STRUCTURAL (exact, no fit):
  one pseudo-channel passes 32 B per ACLK cycle at 250 MHz
  a beat is AXI_DW/8 = 32 B, so ONE beat per PC every 4.000 ns
  with M lanes on a PC each lane gets a beat every M x 4.0 ns

MEAN (a ratio over a whole token's job mix, not a constant):
  card 75 MHz  striped: 7931072 cycles / 5184384 beats = 1.5298 cycles/beat
  eng  200 MHz striped: 2.0300 cycles/beat (MEASURED, separate build)
  datapath floor      : 613/384 = 1.5964 cycles/beat (MEASURED, ideal memory)

clock      M        | cycle ns     demand ns/beat supply ns/beat binding?
75 MHz     M=2      | 13.333       20.40          8.00           datapath (supply idle 61%)
75 MHz     M=1      | 13.333       20.40          4.00           datapath (supply idle 80%)
200 MHz    M=2      | 5.000        10.15          8.00           datapath (supply idle 21%)
200 MHz    M=1      | 5.000        10.15          4.00           datapath (supply idle 61%)

DERIVED benefit of M=2 -> M=1:
  at  75 MHz: supply goes 8.0 -> 4.0 ns/beat; demand is 20.40 ns/beat.
              already slack by 12.40 ns/beat (61%) -> the model predicts ZERO.
  at 200 MHz: supply goes 8.0 -> 4.0 ns/beat; demand is 10.15 ns/beat.
              already slack by 2.15 ns/beat (21%) -> the model predicts ZERO.

UPPER BOUND at 200 MHz if the ENTIRE 0.43 cycles/beat above the datapath floor
were PC contention rather than datapath overhead:
  engine-side per beat  10.15 ns -> 7.98 ns, i.e. 21.4% faster engine-side
  A engine-side  0.0526 s -> 0.0414 s   (saving 0.0112 s)
  token          0.3484 s -> 0.3372 s   = 3.23% of a token, 1.033x
COST: context 65536 -> 44341 tokens (-32.3%); C_MAXPOS must be rebuilt at
      <= 44341, i.e. 32768 as a power of two.
```

**Which quantity is which**, because CLAUDE.md records a track that read scatter
as a slope and another that scaled one resource by another's exact ratio:

- `4.000 ns per beat per pseudo-channel` is **STRUCTURAL**. It is
  `(AXI_DW/8) / (32 B x 250 MHz)` with no free parameter, and it is exact.
  `M x 4.0` is the same constant times an integer.
- `1.5298` and `2.03` cycles per beat are **MEANS** over a whole token's mix of
  249 tensors of different shapes. They are not constants and not slopes; the
  per-job spread behind them is unmeasured, and the 200 MHz figure comes from a
  DIFFERENT build (engine-only) than the 75 MHz one (card).
- `1.5964` is also a MEAN, from ONE simulated job (613 cycles, 384 beats) with
  an ideal memory. One point.
- Nothing above is fitted, and nothing above is extrapolated. The 3.23% is an
  arithmetic upper bound on a quantity whose lower bound is 0, not an estimate
  of where in that range the answer lies.

### 4.11 A separate defect found on the way: `hbm_map.write_arenas()` puts the GDN state and the bottom of the KV cache back on a weight lane's pseudo-channel (MEASURED)

Not this track's question and not fixed here, but it is in the image that is
loaded on the card right now.

`stripe_context_tokens()`'s docstring states the rule: *"The GDN state and the
KV cache start at the next SEGMENT boundary above the weights, not the next
4 KB page [...] a 4 KB round-up would leave the GDN state sharing the top
lane's pseudo-channel -- the exact contention this whole change removes."*
`main()` enforces it with an explicit refusal if `segment_of(gdn_base)` is a
lane segment.

`tools/hbm_map.py:write_arenas()` re-lays the arenas out with
`PK.place(weights_end, gdn_bytes)`, which is a 4 KB placement, and rewrites the
manifest in place. It never consults `lane_stripe`. Applied to the shipped
striped manifest between 2026-09-17 and 2026-09-20:

```
  manifest.json.bak-arenas     gdn_state_base 0x1b0000000 (segment 27)
  manifest.json                gdn_state_base 0x1abde4000 (segment 26)

  weights_end      0x1abde4000  segment 26  A WEIGHT LANE'S
  gdn_state_base   0x1abde4000  segment 26  A WEIGHT LANE'S
  kv_base          0x1ad71c000  segment 26  A WEIGHT LANE'S
  segment 26 spans [0x1a0000000, 0x1b0000000)
  GDN state bytes in that segment : 26443776
  KV bytes in that segment        : 42876928 = 2463 tokens of 17408
  lanes that read segment 26      : [15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26]
```

So 26.4 MB of GDN state and the first 2,463 tokens of KV share pseudo-channel
26 with two weight lanes per tensor. The packer would have refused this
placement outright; the second allocator produced it silently, and
`check_kv_map.py` passes it because the bytes do not OVERLAP any piece -- they
sit in the segment's tail above the lane arena. **The invariant is about the
pseudo-channel, and the only check that exists is about bytes.**

Magnitude, DERIVED: C's KV traffic is small against A's weight traffic, so the
bandwidth cost is probably minor; it has not been measured and no number is
claimed here.

---

## 5. Measured and REJECTED -- do not retry

- **"The KV halving freed about four segments, so the stripe can widen."**
  REJECTED. The packer's bar was 65,536 before the halving and the card's
  `C_MAXPOS` is 65,536 after it. The chosen width is `n = 10` on both sides of
  the change, MEASURED by re-running the identical search. Do not re-run the
  search expecting a different width because a context parameter moved
  DOWNWARD; only something that moves `weights_end` or the descriptor arena can
  change it.
- **"One lane per pseudo-channel is the next lever at 75 MHz."** REJECTED, by
  12.40 ns of slack per beat. The 75 MHz card is datapath-bound with the memory
  idle 61% of the time. Do not build a 27-wide image for the 75 MHz card.
- **"Then it is the next lever at 200 MHz."** REJECTED as an average-rate
  claim: 10.15 ns demand against an 8.00 ns supply is 21% of slack, so the
  bound is not binding there either. NOT rejected as a latency/burstiness
  claim, which is untested -- see the open list.
- **Narrowing the stripe below `n = 8`.** REJECTED by the allocator itself:
  `n = 7` and `n = 6` overflow a 256 MiB segment, and `n <= 5` puts 3 or more
  lanes on one pseudo-channel, which is a DERIVED real loss. `n = 8` at 92.8%
  peak fill is the narrow end and buys 106,113 tokens, far more than
  `C_MAXPOS` can address. There is nothing to gain below `n = 10`.
- **Using `tools/check_mv4i_set.py` as a check on any striped image.**
  REJECTED. It reports **249 FAILURES on the SHIPPED striped set as well as on
  the new one**, and PASS on the flat one: it models `hbm_offset + nbytes` as
  contiguous, which a v2 manifest's 4 KB header is not. Its output on a striped
  set carries no information. `tools/check_hbm_stack.py` IS piece-aware and
  does pass.

---

## 6. Measurement traps hit

- **The brief's census was wrong and it would have propagated.** It gave the
  shipped busiest-PC census as `{(25,2): 249}`, i.e. one segment carrying two
  lanes on every tensor. The manifest says ten segments each carrying two lanes
  on 34 to 56 tensors. The DERIVED rate is unaffected because the bound is per
  tensor, but the shape of the contention is not what the sentence describes.
  Read the census out of the artefact; do not restate one from a brief.
- **The stored `width_search` rows in the manifest are NOT today's numbers, and
  nothing marks them stale.** They say 44,500 and 75,340; re-running says 44,432
  and 75,272. `GDN_STATE_BYTES` grew under them. This is the "comparison needs
  both ends from the same tree" trap: the rows are internally consistent, sum
  correctly, and are simply from a different week. The `gdn` column being
  identical in all eight rows is what made the delta attributable.
- **A manifest is rewritten in place by at least three tools.** The shipped
  striped manifest has four backup files from three different rewriters
  (`pack_model_fk33`, `hbm_map.write_arenas`, `pack_gdn_consts`). `hbm.*` read
  out of it is not necessarily what the packer produced, and section 4.11 is
  the case where that mattered. Compare against the `.bak-*` chain before
  attributing a field to the packer.
- **`max_context_tokens` and the stripe's `context_tokens` are different
  numbers and both appear in the same manifest.** 44,741 / 44,432 / 44,341 all
  appear for this image: the first counts to the end of HBM, the second to the
  descriptor arena, the third to `gdn_const_base`. Only the third is what the
  card may address. Quote the third.
- **The first attempt at the token program exited 1 with an empty log**,
  because `--x-exp` is mandatory and `/usr/bin/time -v` had captured stderr
  into the timing file. A non-zero rc with a zero-length log is a redirection
  bug, not a tool failure.
- **I wrote the unloadable image before the check that refuses it existed.**
  The packer reported full success, all seven stripe checks PASS, `CONTEXT
  44432 tokens [...] Margin 1.11x`. That is T2 in the teeth table and it is the
  attribution control: every existing check in that tool is blind to an image
  the card cannot address.

---

## 7. Open, NOT determined

- **Whether the 0.43 cycles/beat that the 200 MHz engine-only build sits above
  its datapath floor is pseudo-channel contention.** The average-rate model
  says the 8.00 ns supply is not binding at 10.15 ns of demand, but an
  average-rate model cannot see burst interference or read latency, and two
  masters interleaving on one PC pay both. The 27-wide image now exists
  precisely so this can be measured rather than argued. It needs a 200 MHz
  build AND `C_MAXPOS <= 44341`.
- **What the per-job spread behind 1.53 and 2.03 cycles/beat looks like.** Both
  are means over 249 tensors of very different K and M. A mean cannot say
  whether some jobs are supply-bound while others are not, and the lever only
  helps the ones that are.
- **Whether 2.03 and 1.53 are comparable at all.** They come from two different
  builds (engine-only and card) with different surrounding logic. CLAUDE.md's
  same-tree rule applies and neither figure was taken with the other's
  configuration.
- **The bandwidth cost of section 4.11.** GDN state plus 2,463 tokens of KV on
  a weight lane's pseudo-channel in the loaded image. Unmeasured, and the fix
  (teach `write_arenas` the `lane_stripe` block, or make it refuse a v2
  manifest) is unwritten.
- **Whether `C_MAXPOS = 32768` is acceptable as a product decision.** 44,341 is
  the layout's ceiling; 32,768 is the power of two under it. Nothing here is a
  judgement about whether 32k of context is enough.
- **Whether the 2.576 GiB of unused segment tails can hold the KV cache.**
  `hbm.kv_extents` is emitted and the refusal message in `choose_stripe_width`
  points at `docs/debugging/2026-08-30_packstripe-lane-arena-placement.md`
  section 6 for the extent-aware KV change. If that landed, `n = 12` would fit
  the full 65,536 and the whole trade in this document disappears. Nobody has
  costed it.
- **`tools/check_mv4i_set.py` and any other v1-only consumer.** 249 FAILURES on
  every striped set, today, silently, on the shipping image as well.

---

## 8. The artefacts

**Image (outside the repo, do not load on the shipped bitstream):**

```
/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-stripe27/
  250 symlinks onto the same packed files as .../qwen35-9b-mv4i-noembd-striped
  manifest.json   sha256 f4baaa1eb6a24e4df9689b66c43baa342a978f6655f86be73b3243d3ab33dd2e
  gdn_const.bin   sha256 7c6400623f8bc0d8884ed3d346ed7e62e2b79dfcd05cde328fe2ca20ccee7e36
                  blake2b-128 ec3eda1ae15abf20326541ceacdeb917 (equal to the shipped set's)
  hbm.card_kv_fits = false
```

**To regenerate it from nothing but the GGUF and the existing packed set:**

```bash
NEW=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-stripe27
OLD=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped
G=/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
mkdir -p "$NEW"
cd "$OLD"; for f in *; do [ -L "$f" ] && cp -a -- "$f" "$NEW/$f"; done
cd /home/orencollaco/GitHub/llama.vhdl
python3 tools/pack_model_fk33.py "$G" "$NEW" --rows-if 48 --axi-dw 256 \
    --drop token_embd.weight --stripe-lanes \
    --stripe-stack1-segments 12 --stripe-min-context 40000 \
    --stripe-allow-under-maxpos
python3 tools/pack_gdn_consts.py --gguf "$G" --manifest "$NEW/manifest.json" \
    --out "$NEW/gdn_const.bin" --shape 9b
```

Cost, MEASURED: `pack_model_fk33` 13.4 s wall, peak RSS 606,752 KiB;
`pack_gdn_consts` 5.8 s, peak RSS 600,176 KiB. No Vivado, no GHDL, no card.

**Token program (scratchpad, regenerate anywhere):** see section 4.9 for the
exact command and the three digests.

**Repo changes:** `tools/pack_model_fk33.py` -- `scrape_card_maxpos()`, the
`card_kv_fits` refusal, `--stripe-allow-under-maxpos`, three manifest fields.

---

## 9. What the dispatcher must NOT do

Do not load this image. `tools/check_kv_map.py --striped-manifest
<newdir>/manifest.json` refuses it on three rows against the shipped bitstream,
and the failure mode if it were loaded is the 2026-09-20 one: C writing KV
records over `gdn_const`, the descriptor arena and the host blocks, with no
fault and a wrong token. It becomes loadable only alongside a card built at
`C_MAXPOS <= 44341`, and by section 4.10 that build is worth at most 3.2% of a
token and probably nothing.

---

# APPENDED 2026-09-20 by TRACK ARENAPLACE: the 4.11 defect, fixed and measured

Section 4.11 above found the defect and did not fix it. This section fixes it,
teeth-tests the fix, produces a corrected image, and bounds what the defect was
costing. **Nothing above this line is edited.**

## 10.1 The question, verbatim

> `tools/hbm_map.py`'s `write_arenas()` re-places the GDN state with a 4 KB
> round-up and never reads the manifest's `lane_stripe` block. In the shipped
> striped image that pulls `gdn_state_base` from segment 27 back into segment
> 26, so about 26.4 MB of B's recurrent state and the first 2,463 tokens of the
> KV cache now share pseudo-channel 26 with two weight lanes per tensor. [...]
> Magnitude is UNMEASURED.

Date 2026-09-20. Inputs: `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/`
(`manifest.json` of Sep 20 06:32 and its `manifest.json.bak-arenas` of Sep 17
21:24), `tools/hbm_map.py` and `tools/pack_model_fk33.py` at `8771f32`.

## 10.2 The answer, up front

**The defect is exactly as 4.11 described, and it is now caught in three
places by one rule.** `relayout_arenas()` now CALLS
`pack_model_fk33.stripe_context_tokens()` on a striped manifest instead of
`PK.place()`, so the placement rule is stated once, in the packer; and a new
`hbm_map.stripe_residency_fails()` (fault code P7) refuses any manifest whose
GDN state or KV arena decodes to a pseudo-channel a weight lane occupies. P7
is in `plan().check()`, so `gen_layer_program.py` and `pack_gdn_consts.py`
refuse the defective image too, and it is a named row in `check_kv_map.py`.

**The performance cost of the defect as it stands is bounded above by 16,429
cycles per B job (2.5%), and is DERIVED to be ZERO in the current design**,
because D issues steps serially: no weight lane is active while B's state
mover or C's KV port is using pseudo-channel 26. It is a correctness defect
that becomes load-bearing the moment lever 5 of the BMOVER table (overlap the
state load with the next layer's A jobs) lands.

**One correction to 4.11's census**, which does not change its conclusion: the
phrase "two weight lanes per tensor" over-states it. MEASURED over the shipped
manifest's own pieces, 249 tensors have bytes in segment 26; **198 of them put
ONE lane there and 51 put TWO**.

## 10.3 The procedure

1. Read `write_arenas()` / `relayout_arenas()` and every caller, and read the
   packer's `stripe_context_tokens()` and `main()`'s refusal. Quote both.
2. Read the shipped manifest AND its three backup files, which is the only way
   to see which tool wrote which field (trap recorded in section 6).
3. Census segment 26 out of the manifest's own `pieces`, not out of a brief.
4. Make the second allocator CALL the packer's rule rather than restate it,
   and add the invariant as a fault in the map's own checker.
5. Teeth, including the shipped image as a live mutant and the attribution
   control with the new rows disabled.
6. Repack the corrected image from the same symlinked bytes. Cross-check that
   the repack and the fixed `relayout_arenas()` agree on the placement, which
   is the evidence that the two allocators no longer disagree.
7. Bound the magnitude from the BMOVER measurement rather than assert it.

## 10.4 The evidence

### The two placements, and who owns segment 26

```
manifest.json.bak-arenas   gdn_state_base 0x1b0000000 segment 27   (the PACKER)
manifest.json              gdn_state_base 0x1abde4000 segment 26   (write_arenas)
manifest.json              kv_base        0x1ad71c000 segment 26

segment 26 spans [0x1a0000000, 0x1b0000000); weights_end 0x1abde4000
reserved_segments in the manifest        : [16, 27, 28, 29, 30, 31]
lanes whose stripe includes segment 26   : [15..26], 12 lanes
lanes with BYTES in segment 26           : {16:51, 18:53, 20:54, 22:57, 24:34, 26:51}
                                           300 pieces over 249 tensors
tensors with 1 lane in segment 26        : 198
tensors with 2 lanes in segment 26       : 51
GDN state bytes in segment 26            : 26443776
KV bytes in segment 26                   : 42876928 = 2463 tokens of 17408
```

### The code, quoted

`tools/pack_model_fk33.py:643` states the rule and argues it:

```python
def stripe_context_tokens(weights_end, gdn_bytes, kv_top, per_token):
    """...
    The GDN state and the KV cache start at the next SEGMENT boundary above the
    weights, not the next 4 KB page.  Two reasons, both load-bearing:
    `server/fk33_manifest.c:170` requires `gdn_state_base >= weights_end`, and
    a 4 KB round-up would leave the GDN state sharing the top lane's
    pseudo-channel -- the exact contention this whole change removes."""
    gdn = ((weights_end + SEGMENT_BYTES - 1) // SEGMENT_BYTES) * SEGMENT_BYTES
```

and `main()` refuses the violation outright (`pack_model_fk33.py:1329`):

```python
        if segment_of(gdn_base) in lane_segs:
            raise SystemExit("pack_model_fk33: the GDN state would land in "
                             "segment %d, which a weight lane owns"
                             % segment_of(gdn_base))
```

`tools/hbm_map.py:relayout_arenas()` at `8771f32` bypassed both:

```python
    gdn_base, hole = PK.place(weights_end, gdn_bytes)
    kv_base = align_up(gdn_base + gdn_bytes, int(hbm.get("align", 4096)))
```

`PK.place()` is the 4 KB allocator (`pack_model_fk33.py:374`, "Next legal base
for `nbytes` at or after `off`"). `lane_stripe` appears nowhere in the
function. It is now:

```python
    if hbm.get("lane_stripe") is not None:
        _tokens, gdn_base, _kvb = PK.stripe_context_tokens(
            weights_end, gdn_bytes, top, per)
        ...
        chk, _ = PK.place(gdn_base, gdn_bytes)      # the STACK rule still applies
        if chk != gdn_base:
            raise SystemExit(...)
    else:
        gdn_base, hole = PK.place(weights_end, gdn_bytes)
```

### Old versus new, same inputs (the attribution control for the ALLOCATOR)

HEAD's `tools/hbm_map.py` was run from a scratch tree that symlinks `server/`
and `rtl/`, so both versions read the same authorities.

```
== striped manifest.json.bak-arenas (what write_arenas was actually given)
   OLD(HEAD) relayout OK  gdn 0x1abde4000 seg 26  kv 0x1ad71c000
   NEW       relayout OK  gdn 0x1b0000000 seg 27  kv 0x1b1938000
   keys differing: gdn_state_base, kv_base, kv_extents, free_after_gdn,
                   max_context_tokens, gdn_state_segment_pad_bytes
== flat manifest (the behaviour that must NOT change)
   OLD(HEAD) relayout OK  gdn 0x10c006000 seg 16  kv 0x10d93e000
   NEW       relayout OK  gdn 0x10c006000 seg 16  kv 0x10d93e000
   keys differing OLD vs NEW: NONE (byte-identical layout)
== striped manifest.json (the SHIPPED, already-defective one)
   OLD(HEAD) relayout OK  gdn 0x1abde4000 seg 26  plan().check() faults on INPUT: 0
   NEW       relayout OK  gdn 0x1b0000000 seg 27  plan().check() faults on INPUT: 2
```

The third block is the whole finding in three lines: on the image that is
loaded on the card, HEAD's checker reports **0 faults** and HEAD's allocator
**reproduces the defect**; the new one reports 2 and repairs it.

### The teeth

`hbm_map` allocator, run directly. WANT written before the numbers were seen.

| mutant | want | got |
|---|---|---|
| flat manifest (control) | accept, unchanged | ACCEPTED, gdn 0x10c006000, identical to HEAD |
| corrected striped image (control) | accept | ACCEPTED, gdn 0x1b0000000 seg 27 |
| SHIPPED defective manifest, re-laid out | accept AND repair | ACCEPTED, gdn moved to 0x1b0000000 seg 27 |
| M-A: a lane plan that OWNS segment 27 | REFUSE | REFUSED, P7 names segment 27 |
| M-C: `lane_stripe` present, `segments` empty | REFUSE | REFUSED (see below) |

**M-C is a hole this track opened and then closed, and it is reported because
it was real for about twenty minutes.** The first fix branched on
`stripe_lane_segments(mani)` being non-empty. A manifest carrying a
`lane_stripe` block with an EMPTY `segments` list then fell straight through to
the 4 KB rule and reproduced the defect in silence (MEASURED: `gdn 0x1abde4000
seg 26`). The branch is now on the BLOCK's presence, and an empty lane plan is
a P7 fault in its own right. **An empty set is not evidence of a flat image**,
and this is the same shape as every "passes for the wrong reason" entry in
CLAUDE.md.

`tools/check_kv_map.py --teeth`, **29 of 29 rows behaved as intended**. The
seven new rows:

| row | want | got |
|---|---|---|
| THE SHIPPED striped image `.../noembd-striped` as it stands today | REFUSE | REFUSED on exactly one row, the residency row |
| **attribution control: same image, residency rows OFF** | **accept** | **accepted** |
| `gdn_state` ONE BYTE BELOW the boundary (0x1afffffff) | REFUSE | REFUSED, segment 26 |
| `gdn_state` EXACTLY ON the boundary (0x1b0000000) | accept | accepted |
| `gdn_state` one PAGE below the boundary (0x1affff000) | REFUSE | REFUSED, segment 26 |
| `kv_base` alone dragged back to 0x1ad71c000, `gdn_state` left correct | REFUSE | REFUSED, names kv_base |
| `gdn_state` ONE BYTE ABOVE the boundary (0x1b0000001) | **accept -- DOES NOT BITE** | accepted |

**The attribution control is the load-bearing row.** The shipped image with
only the residency rows disabled is ACCEPTED by all 38 pre-existing rows,
which is the measurement that none of them could see this. Its refusal with
the rows on names exactly one row, so the kill is not shared.

**The non-biting row, under its own name.** A base one byte ABOVE the segment
boundary is inside reserved segment 27, no lane shares its pseudo-channel, and
P7 is silent -- correctly, because the contention is a property of WHICH
pseudo-channel the bytes decode to, not of where inside it they start. An
alignment rule inside P7 would be a rule that fires for a reason other than the
one it names. **The real guard for it is measured separately and does exist:**

```
gdn_state one BYTE above the boundary 0x1b0000001    P7 0  other 2
  <gdn recurrent state>: base 0x1_b000_0001 is not 4 KB aligned (placed by pack_model_fk33.py)
gdn_state one BYTE below 0x1afffffff                 P7 1  other 1
gdn_state one PAGE below 0x1affff000                 P7 1  other 0
kv_base back to 0x1ad71c000                          P7 1  other 0
baseline (corrected image)                           P7 0  other 0
```

so `hbm_map.plan().check()` refuses the misaligned base on its pre-existing
4 KB region rule, and P7 is not credited with it.

### The corrected image

```
/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27/
  250 symlinks onto the same packed files as .../qwen35-9b-mv4i-noembd-striped
  manifest.json           1179587 B
      sha256 05daf1c011b89a2ed2b02e26dfa708dab94eaa6a4b564f2708a6623235b62ae6
  manifest.json.bak-gdnconst
  gdn_const.bin           1585152 B
      sha256 7c6400623f8bc0d8884ed3d346ed7e62e2b79dfcd05cde328fe2ca20ccee7e36
      blake2b-128 ec3eda1ae15abf20326541ceacdeb917 (equal to the shipped set's,
      and to the stripe27 set's: the constant image does not depend on placement)
```

MEASURED against the shipped striped set:

```
files shipped 250, new 250        same name set: True
per-file blake2b differing        : NONE -- all 250 equal
files whose hbm_offset moved      : 0
weights_end       shipped 0x1abde4000 seg26   new 0x1abde4000 seg26
gdn_state_base    shipped 0x1abde4000 seg26   new 0x1b0000000 seg27
gdn_state_bytes   shipped 26443776            new 26443776
kv_base           shipped 0x1ad71c000 seg26   new 0x1b1938000 seg27
gdn_const_base    shipped 0x1ff95a000 seg31   new 0x1ff95a000 seg31
desc_arena_base   shipped 0x1ffadd000 seg31   new 0x1ffadd000 seg31
max_context_tokens shipped 79163              new 75181
card_kv_fits      shipped absent              new True
gdn_const_blake2b shipped ec3eda1a...b917     new ec3eda1a...b917
lane segment fills shipped vs new : IDENTICAL in all 25 segments
P7 on the new image               : CLEAN
hbm_map plan().check() on new     : CLEAN
kv arena spans segments           : 27..31, every one of them reserved
```

`max_context_tokens` FALLS from 79,163 to 75,181. That is the defect being
paid back: the shipped figure counted the 2,463 tokens that were sitting on
segment 26 plus the bytes of the 69,320,704-byte segment pad. 75,181 is still
1.147x the card's `C_MAXPOS`.

`C_MAXPOS` is 65,536, MEASURED by reading `hw/fk33/gen_fk33_card.py` (via
`check_kv_map`'s own `_read_int_generic`, row `gen_fk33_card C_MAXPOS == KVR
C_MAXPOS  built 65536 vs simulated 65536`), not from any prose.

Checks on it:

```
python3 tools/check_kv_map.py --striped-manifest <new>/manifest.json
  check_kv_map: 40 rows, 0 refused, 0 not run        (rc 0)
python3 tools/check_hbm_stack.py <newdir>
  PASS no range crosses a stack boundary; 7154 ranges, 249 of 250 lane-striped
```

Cost, MEASURED: `pack_model_fk33` 11.13 s wall, peak RSS 606,320 KiB;
`pack_gdn_consts` 5.76 s, peak RSS 600,736 KiB. No Vivado, no GHDL, no card.

### The token program does NOT need regenerating

MEASURED, both programs emitted with `--x-exp 0` and byte-compared:

```
token.dtbl  IDENTICAL
token.rel   IDENTICAL
token.arena IDENTICAL
```

against section 4.9's stripe27 result, where `token.arena` DIFFERED in 10,376
bytes. The difference there was the 27 per-lane bases; here **no weight piece
moved** (0 of 250 `hbm_offset` changed) and `desc_arena_base` is unchanged, so
the A descriptors are the same bytes. The GDN state and KV bases are not in
the program at all -- `grep -n "gdn_state_base\|kv_base" tools/gen_layer_program.py`
returns nothing; the host programs them into the seam from the manifest.

The old program had to be emitted with HEAD's `hbm_map.py`, because the new
one REFUSES:

```
gen_layer_program: REFUSING to emit A descriptors -- the HBM map has 2
overlap/placement fault(s).  See tools/hbm_map.py.
  PIECES P7: gdn_state spans 0x1_abde_4000..0x1_ad71_c000, ...
```

That refusal was not designed; it follows from putting P7 in `plan().check()`,
and it is the third independent place the defective image is now stopped.

Digests of the corrected image's program (scratchpad, regenerate anywhere):

```
b6d8888913c8bd58aee27638dc1bfbdcb6a77e383844e989ba8e7836786dd156  token.dtbl
7c6e8ae899eadb2a1858b182b88453d50d38a10cc704146ac0922cb2b6eb98f4  token.rel
7707d67a0be24bf3041b5fe42a9d666599c710341bf2d43fa1c5fe3fa44d91d3  token.arena
```

## 10.5 The magnitude, DERIVED

**Upper bound, from the BMOVER measurement.** B's state mover is 660,601
cycles per job on the card (MEASURED, `profile_flat_tok0.txt` step 7) and
`sim/tb_bmover_phases` accounts for **644,172** of them against a modelled
memory. The residual is **16,429 cycles, 2.5%**, and
`docs/debugging/2026-09-20_b-job-660k-cycles.md` lists it as open with three
named candidates (the card's slower producers, per-beat bubbles in the HBM
path, the seam's issue overhead). Pseudo-channel contention is a fourth
candidate inside the same residual. So:

> **The defect costs at most 16,429 cycles per B job, at most 2.5% of the job,
> at most 24 x 16,429 = 394,296 cycles = 5.26 ms per token at 75 MHz, which is
> at most 1.3% of the 30.1 M-cycle striped token -- and it shares that budget
> with three other candidates, so its own share is at most that and may be 0.**

**DERIVED, it is 0 today.** D issues steps serially. A `B_JOB` is one step and
an `A_JOB` is another; the BMOVER lever table lists "load layer L+1's state
during layer L's A jobs" as lever 5, **not done**, needing `llama_top` and D
scheduling. So while B's mover is using pseudo-channel 26 no weight lane is
active, and there is nothing to contend with. The same argument covers C's KV
reads. **The defect is a correctness defect with no measurable cost in the
current schedule.**

**The duty cycle, for when that stops being true.** Per B job the state
traffic is 1,101,824 B in and 1,101,824 B out = **68,864 beats** of 32 B, all
of it in segment 26 in the shipped image (`gdn_state_bytes` 26,443,776 / 24
layers = 1,101,824 B per layer, and the whole arena is inside segment 26). At
the STRUCTURAL 4.000 ns per beat per pseudo-channel from section 4.10 that is
**275.5 us** of pseudo-channel occupancy inside a job that takes
660,601 / 75 MHz = **8.808 ms**: a **3.13% duty cycle**. Even under full
overlap with A, B is asking for 3.1% of one pseudo-channel.

**What is NOT bounded here.** C's KV traffic for positions 0..2,462, which
also sits in segment 26 in the shipped image. No per-position C measurement
exists, so no number is claimed. Under the same serial-step argument it is
also 0 today.

**The flat-versus-striped comparison is NOT a control for this**, and it would
be easy to mistake it for one. The BMOVER doc records the B job as "identical
on the flat and the lane-striped HBM image" -- but the FLAT layout puts
`gdn_state_base` at 0x10c006000, which is segment 16, and segment 16 also
holds the top of the flat weight image. Both layouts share the state's
pseudo-channel with weights. The comparison measures that the job does not
care which layout it is on; it does not measure a contended case against an
uncontended one.

## 10.6 Measured and REJECTED -- do not retry

- **"Add a segment-alignment rule to P7."** REJECTED. The mutant
  `gdn_state_base = 0x1b0000001` is inside reserved segment 27 and costs
  nothing in contention; an alignment rule in P7 would fire for a reason other
  than the one it names. MEASURED: `hbm_map.plan().check()` already refuses it
  on the pre-existing 4 KB region rule (2 faults), so the behaviour exists and
  is correctly attributed elsewhere.
- **"Duplicate the segment-boundary rule in `hbm_map`."** REJECTED on sight and
  then on measurement: a rule stated twice is how this defect happened.
  `relayout_arenas()` CALLS `pack_model_fk33.stripe_context_tokens()`. The
  cross-check is that a full repack and the fixed re-layout agree to the byte
  on `gdn_state_base` (0x1b0000000) and `kv_base` (0x1b1938000).
- **"Branch on the lane-segment SET being non-empty."** REJECTED, MEASURED as
  teeth M-C: a `lane_stripe` block with an empty `segments` list then falls
  through to the 4 KB rule and reproduces the defect silently. Branch on the
  block's presence.
- **"Repack with `--stripe-stack1-segments` to reproduce the shipped width."**
  Not needed. The width search re-chose `n = 10` on its own (12/11 under the
  65,536 target, 10 at 75,272 chosen), and the resulting 25 lane-segment fills
  are IDENTICAL to the shipped manifest's.
- **"Use `tools/check_mv4i_set.py` on the corrected set."** REJECTED, see 10.7.

## 10.7 `tools/check_mv4i_set.py` is v1-only -- recorded, NOT fixed

MEASURED today, re-derived rather than restated from the brief:

```
qwen35-9b-mv4i-noembd              PASS, rc 0
qwen35-9b-mv4i-noembd-striped      249 FAILURES, rc 1
qwen35-9b-mv4i-noembd-striped-seg27 249 FAILURES, rc 1

FAIL blk.14.ffn_down.weight.mv4i: HBM offset 0x1000 overlaps the previous
     region ending 0x221b3000
```

It models an entry as `nbytes` contiguous bytes at `hbm_offset`, which on a v2
manifest names a 4 KB HEADER. Every striped entry therefore "overlaps" its
neighbour. **Its verdict on any striped image carries no information** and it
must not be quoted for or against one.

**What it would take to make it striping-aware:** it should use
`hbm_map.file_pieces(e)`, which already exists and already returns a synthetic
one-piece list for a flat entry precisely so that the flat and striped paths
cannot drift. Three of its rules -- placement, overlap, and the sub-region
offset arithmetic -- would then run per piece instead of per file, and the
`blake2b` and size rules are already piece-independent because the packer
digests the whole file. Until then the honest change is a REFUSAL on
`format ... v2 lane-striped` rather than 249 wrong lines; that is a behaviour
change and was deliberately not made by this track.

**Nothing in the repository treats its output as a gate.** MEASURED:
`grep -rn check_mv4i_set` over the tree outside `.claude/worktrees` finds it in
`tools/hbm_map.py:109`, `tools/pack_model_fk33.py:899,1582`,
`tools/weights_residency.py:9,55`, `hw/fk33/host/fk33_load_weights.py:303`,
`docs/2026-09-18_b-constants-path.md:79` and `docs/WORKLOG.md:62` -- **every
one a comment or a docstring, none an invocation.** `sim/regress.sh` and
`sim/realshape_gate.sh` do not run it. It is the recorded "a script nothing
schedules" pattern, which is the only reason its wrong verdict has cost
nothing so far.

## 10.8 Measurement traps hit

- **A `cp` onto a SYMLINK writes through it.** Building the HEAD-version
  scratch tree with `for f in tools/*.py; do ln -s ...; done` and then
  `cp $SD/old/hbm_map.py $SD/oldrepo/tools/hbm_map.py` **overwrote the REPO's
  `tools/hbm_map.py` with the HEAD copy and destroyed this track's edits.**
  `git status` showed the file clean, which is exactly what makes it
  dangerous: the evidence of the loss looks like the absence of work. Caught
  by `grep -c stripe_residency_fails` returning 0, and the edits were redone.
  `cp --remove-destination` is the fix. This is CLAUDE.md's recorded
  `cp "$SD/tree/$f" "$f"` hazard with the variable on the DESTINATION side
  only, and it still fired.
- **`cmd | tail` reports `tail`'s exit code.** The first
  `check_mv4i_set.py` run appeared to exit 0 while printing "249 FAILURES",
  which would have become a second finding about its exit code. Re-run without
  the pipe: rc 1. A fact about the harness reported as a fact about the job.
- **The stored `context_tokens` in a manifest is not today's number.** The
  shipped block says 75,340; a re-pack of the identical width says 75,272,
  because `GDN_STATE_BYTES` grew under it. Section 6 already recorded this and
  it recurred here; the lane-segment FILLS being byte-identical is what made
  the repack attributable.
- **"Two weight lanes per tensor" was a summary, not a census.** The real
  distribution is 198 tensors with one lane in segment 26 and 51 with two.
  Read the census out of the artefact, including from a document written the
  same day.

## 10.9 Open, NOT determined

- **What C's KV traffic on segment 26 was costing.** No per-position C
  measurement exists. Under the serial-step argument it is 0 today; nobody has
  measured a C step's pseudo-channel occupancy.
- **Whether pseudo-channel contention is any part of the BMOVER 16,429-cycle
  residual.** It is inside the bound and shares it with three other named
  candidates. Distinguishing them needs the corrected image on the card
  beside the shipped one, which is a hardware measurement this track cannot
  make.
- **Whether the 69,320,704-byte segment pad below `gdn_state_base` can be
  used.** It is recorded as `hbm.gdn_state_segment_pad_bytes` for the first
  time, and it is 66 MiB of segment-26 tail. It is usable only by a consumer
  that does not mind sharing six weight lanes' pseudo-channel, which is the
  whole point of not putting the arenas there.
- **Whether the packer should record that pad too.** It does not, and the two
  tools therefore differ in what they write, which is the shape of defect this
  section exists to close. It is additive and harmless, and it was left alone
  rather than changed under a track that is not the packer's owner.
- **`hbm_map.relayout_arenas()`'s stack-line refusal has no mutant that
  reaches it through a real layout.** It fires only if a segment-aligned base
  would straddle the 4 GiB line, which needs an arena of a size nothing in
  this shape produces. It is asserted, not measured.

## 10.10 The corrected image: what to run

**Load it (HARDWARE -- the dispatcher, never a subagent):**

```bash
NEW=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27
python3 hw/fk33/host/fk33_load_weights.py plan "$NEW/manifest.json"     # no device
python3 hw/fk33/host/fk33_load_weights.py load "$NEW/manifest.json" --verify
```

`load` places all 250 objects AND `gdn_const.bin` at `hbm.gdn_const_base`
(0x1FF95A000); the constant image is synthesised as an extra entry from the
`hbm.gdn_const_*` fields, so it needs no second command. The A descriptor
arena goes to 0x1FFADD000 as before, and the token program is byte-identical
to the one already in use, so it does not have to be re-emitted.

**Regenerate the image from nothing but the GGUF and the existing packed set:**

```bash
NEW=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27
OLD=/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped
G=/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
mkdir -p "$NEW"
cd "$OLD"; for f in *; do [ -L "$f" ] && cp -a -- "$f" "$NEW/$f"; done
cd /home/orencollaco/GitHub/llama.vhdl
python3 tools/pack_model_fk33.py "$G" "$NEW" --rows-if 48 --axi-dw 256 \
    --drop token_embd.weight --stripe-lanes
python3 tools/pack_gdn_consts.py --gguf "$G" --manifest "$NEW/manifest.json" \
    --out "$NEW/gdn_const.bin" --shape 9b
python3 tools/check_kv_map.py --striped-manifest "$NEW/manifest.json"
python3 tools/check_hbm_stack.py "$NEW"
```

**DO NOT run `python3 tools/hbm_map.py <manifest> --write-manifest-arenas` on
it.** It is no longer wrong -- that is this section -- but it is also not
needed: a fresh pack already sizes the arenas from
`rtl/model_cfg_pkg.vhd`. The flag exists for the migration of a set packed
against the 27B literals.

**Regenerate the token program (optional, it is unchanged):**

```bash
python3 tools/gen_layer_program.py --token --shape 9b --x-exp 0 \
  --manifest /mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27/manifest.json \
  --d-table <SD>/token.dtbl --rel-file <SD>/token.rel \
  --arena-image <SD>/token.arena --json <SD>/token.json
```

**The shipped `.../qwen35-9b-mv4i-noembd-striped` is left on disk, unmodified,
as the mutant `check_kv_map.py --teeth` fires on.** It must not be loaded.
