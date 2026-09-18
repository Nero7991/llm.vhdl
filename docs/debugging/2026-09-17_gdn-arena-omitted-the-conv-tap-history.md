# The packed manifest's GDN arena was 1,179,648 B short, and it is exactly the conv tap history

## The question, verbatim

> Generate subsystem D's descriptor program for one whole token of Qwen3.5-9B
> against `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json`, so
> that a host driver for the v2 window seam has something to write into the
> card's descriptor window.

Date: 2026-09-17. Build: the `FK33_CARD=1` A+B+C+D bitstream at 75 MHz, in
place-and-route at the time of writing. Symptom:

```
gen_layer_program: REFUSING to emit A descriptors -- the HBM map has 1
overlap/placement fault(s).  See tools/hbm_map.py.
  the GDN recurrent state arena: hbm.gdn_state_bytes is 25264128 B and the
  QWEN35_9B shape needs 26443776 B.
```

## The answer, up front

**The manifest's `gdn_state_bytes_per_layer` was 1,052,672 B, which is the GDN
mantissas plus the column exponents and NOTHING ELSE. It omitted the 49,152 B
per-layer depthwise-conv tap history. 24 GDN layers x 49,152 = 1,179,648 B,
which is the entire shortfall to the byte.**

It is a STALE ARTEFACT, not a live code defect: `tools/hbm_map.py:430` already
adds `gdn_conv_b` under `include_gdn_conv`, which defaults to `True`, and its
own comment records why the omission survived -- *"the second token of any
sequence convolves against zeros, and that is a WRONG NUMBER rather than a
hang [...] `B_SRC_REAL` has never run past token 0 anywhere."* The manifest on
disk was written on 2026-08-29, before that term existed.

Fixed by re-laying-out the arenas from the RTL shape:

```
python3 tools/hbm_map.py <manifest> --write-manifest-arenas
```

## Why it mattered, and it is not a capacity cost

The checker's own words: *"UNDER-reservation is not a capacity cost, it is a
neighbouring arena being overwritten -- a GDN slot past the end lands on the
KV cache."* The GDN arena is immediately followed by `kv_base`. A layer
writing its conv tap history past the reservation writes into the KV cache of
a token already computed, and nothing raises a fault: the next attention layer
reads a plausible K or V record that is not the one it stored.

## The procedure that produced it

1. **Ask the generator for the whole token's program.** It refused, and the
   refusal named the arena, the two numbers and the derivation. That is the
   entire diagnosis; every step below is confirmation.
2. **Read the two figures out of the manifest rather than out of the message**,
   because the message is the tool's derivation and the manifest is the
   artefact under suspicion:

   ```
   gdn_state_bytes                 25264128
   gdn_state_layers                      24
   gdn_state_bytes_per_layer        1052672
   gdn_state_mant_bytes_per_layer   1048576
   gdn_state_exp_bytes_per_layer       4096
   ```

   `1048576 + 4096 = 1052672` EXACTLY, so the per-layer figure is the sum of
   the two terms the manifest itself names and there is no third.
3. **Subtract, and compare against each term of the tool's derivation
   separately** rather than against the total. `1101824 - 1052672 = 49152`,
   and the derivation's third line reads `3 x 8192 x 16/8 B = 49152 B conv tap
   history`. The match is to the byte and it is one named term, which is what
   makes this an omission rather than a disagreement about sizing.
4. **Find the producer and check whether the code or the artefact is stale.**
   `grep -rn gdn_state_bytes_per_layer tools/*.py` gives `hbm_map.py:450` as
   the only computation. Reading it shows the term is present and gated
   `include_gdn_conv=True`. **So the code is right and the file is old.** This
   step is what decides between a one-command migration and an RTL change.
5. **Re-lay-out, and re-run the SAME check.** It must go from FAIL to EQUAL,
   and the neighbours must move by exactly the shortfall.
6. **Re-run the thing that refused.** The program now emits.

## The evidence, as raw output

Before:

```
  gdn_state_bytes      manifest 25264128     derived 26443776     0.955x UNDER
  kv_bytes_per_token   manifest 17408        derived 17408        EQUAL
FAIL  the GDN recurrent state arena: ...
```

The migration, and note that every number that moved moved by the same
1,179,648 B:

```
re-laid-out the GDN and KV arenas in .../manifest.json
  free_after_gdn                 4068352000 -> 4067172352      (-1179648)
  gdn_state_bytes                  25264128 -> 26443776        (+1179648)
  gdn_state_bytes_per_layer         1052672 -> 1101824         (+49152)
  kv_base                        4521582592 -> 4522762240      (+1179648)
  max_context_tokens                 233705 -> 233638          (-67 tokens)
  backup: .../manifest.json.bak-arenas
```

After:

```
  gdn_state_bytes      manifest 26443776     derived 26443776     EQUAL
  kv_bytes_per_token   manifest 17408        derived 17408        EQUAL
```

And the program that was refused:

```
$ python3 tools/gen_layer_program.py --token --shape 9b --manifest ... --x-exp 0
$ wc -l token.dtbl token.rel
   4040 token.dtbl
    505 token.rel
```

**4,040 = 505 x 8**, eight 64-bit words per descriptor, written as text hex
lines.

## The cross-check that was worth more than the fix

505 is not an arbitrary number and it is checkable against the RTL from two
directions:

* `rtl/fk33_seam.vhd:123-125` predicts it outright: *"`llama_map_pkg.n_steps`
  is [...] runs `n_steps - 1 + lm_windows = 491 - 1 + 15 = 505`"*. The
  generator emitted 505 without being told.
* It FITS THE CARD'S WINDOWS, with margin, and the RTL's GO checks are what
  bound it (`rtl/fk33_seam.vhd:746-761`):

  | bound | RTL | this program | |
  |---|---|---|---|
  | `TBL_LEN <= REL_ENT` | 576 | 505 | ok |
  | `TBL_LEN * 8 <= DESC_WORDS` | 4608 | 4040 | ok |

  A host writes the descriptor window as 32-bit halves, so 8,080 writes
  against a 9,216-half window.

So the descriptor windows in the bitstream now in place-and-route are sized
for exactly this program, and that agreement was measured rather than assumed.

## Measured and REJECTED -- do not retry

* **`--no-a`.** It emits the D table and skips the refusal, and it was the
  first thing tried. The resulting `token.dtbl` was a perfectly ordinary
  68,680-byte file with no indication that anything was missing. **A program
  emitted this way is not the token's program**, and taking it would have
  moved the defect from a loud refusal into a silent one. It is the right flag
  for inspecting the D table alone and the wrong flag for producing something
  to run.
* **Treating the refusal as a capacity problem.** `max_context_tokens` falls
  by 67 tokens, which reads like the cost of the fix. It is not: the 67 tokens
  are the price of reserving space that was ALWAYS being written. Nothing got
  smaller; an overlap got removed.
* **Editing `gdn_state_bytes` by hand.** It has four dependent fields
  (`gdn_state_bytes_per_layer`, `kv_base`, `free_after_gdn`,
  `max_context_tokens`) and the tool moves all five atomically with a backup.
  A hand edit that moved one of them is a manifest that passes the arena check
  and places the KV cache wrong.

## Measurement traps hit, including my own

* **The tool's message contains its own derivation, and reading the numbers
  out of THAT rather than out of the manifest would have proved nothing.**
  The whole question is whether the artefact agrees with the derivation, so
  both ends must be read from their own source. This is the project's recorded
  same-tree rule in a new place.
* **I compared against the TOTAL first and it was uninformative.** `26443776 -
  25264128 = 1179648` is not obviously anything. Dividing by the layer count
  and comparing against each NAMED TERM of the derivation is what turned it
  from a discrepancy into an identification. A difference matched against a
  total tells you there is a defect; a difference matched against a term tells
  you which.
* **"The code is wrong" was the assumed shape and it was wrong.** The natural
  reading of a checker failing is that the thing it checks is broken. Here the
  checker and the code agreed and the FILE was old. Checking which of the two
  is stale costs one `grep` and decides between a one-command migration and an
  RTL change.

## Open, not yet answered

* ~~**Whether any other artefact carries the old arena.**~~ **ANSWERED the
  same day, and it did.** Every packed manifest under
  `/mnt/storage/llama-models/` was run through `--arena`:

  | manifest | gdn_state_bytes | derived | verdict |
  |---|---|---|---|
  | `qwen35-9b-mv4i-noembd` | 26443776 | 26443776 | migrated, EQUAL |
  | `qwen35-9b-mv4i-noembd-striped` | 25264128 | 26443776 | **the SAME defect** |
  | `qwen35-9b-mv4i` | 75497472 | 26443776 | 2.855x OVER |
  | `qwen35-9b-mv4i-qkvpad` | 75497472 | 26443776 | 2.855x OVER |
  | `qwen35-9b-mv4i-stackfix` | 75497472 | 26443776 | 2.855x OVER |

  The **striped** manifest carried the identical 1,179,648 B under-reservation
  and was migrated too (backup `.bak-2026-09-17` and the tool's own
  `.bak-arenas`). It is the lane-striped variant, i.e. a candidate for what
  the card actually loads, so leaving it would have moved the defect rather
  than fixed it. Its numbers move differently because its weights end
  elsewhere: `gdn_state_base` went DOWN by 69,320,704 and
  `max_context_tokens` UP from 75,649 to 79,564.

  The three at **75,497,472 B are 2.855x OVER**, which is a different
  discrepancy and a SAFE one: over-reservation wastes address space and
  overlaps nothing. **They were deliberately NOT migrated.** They are older
  packs, nothing schedules them, and a migration is a change to an artefact
  that is currently correct-but-wasteful. Where 75,497,472 came from has not
  been derived and is not worth deriving unless one of them is used.
* **Whether the conv tap history is actually written by the RTL yet.** This
  fixes the RESERVATION. `hbm_map.py`'s own comment says the omission survived
  because `B_SRC_REAL` has never run past token 0 anywhere, and nothing here
  changes that: it remains unmeasured whether `gdn_block` stores and reloads
  those taps across tokens on silicon. **A correctly sized arena that nothing
  writes to produces the same wrong answer on token 1.**
* **The 67-token reduction in `max_context_tokens`** is recorded and not
  reasoned about. It is far above the 4,096 the card's `C_CTXLEN` allows, so
  it cannot bind today.
