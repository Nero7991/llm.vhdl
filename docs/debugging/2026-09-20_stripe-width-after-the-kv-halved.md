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
