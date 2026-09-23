# The norm gain is indexed by a per-token counter, so a card that starts at block 16 normalises with block 0's gains

## The question, verbatim

2026-09-23, two FK33s on the workstation (card 1 serial 153300000607A at 0000:07:00.0, card 2 serial
153300001366A at 0000:06:00.0 on the MCIO riser), both holding build 18
(`hw/fk33/results/card_build18_2026-09-23/`), images `qwen35-9b-card0-b0-15` on xdma0 and
`qwen35-9b-card1-b16-31` on xdma1. First pair run (`run_pair.sh 1`): all three prompts run end to end,
147 hops, 42.3 s wall (the single card: 43.9 s), but the ids diverge from the single-card reference at
positions 7, 28 and 0, and the pair's text degrades into repetition ("silver, silver, silver"). Why?

## The answer

`rtl/llama_top.vhd` serves the RMSNorm gain from `NORM_W_IMAGE`, "one entry per OP_VEC_NORM of the
token, in SCHEDULE ORDER", indexed by a per-token COUNTER of norm ops, not by the step's block. Every
VEC_NORM step already carries its block in `const_base`; the RTL does not read it for the gain. A
program that starts at block 16 therefore normalises block 16 with block 0's `attn_norm`, block 16's
FFN half with block 0's `post_attention_norm`, and so on, every norm 32 entries early. Card 0 is
unaffected because its norms are the token's first 32. The hop (window 3 mantissas + XEXP_OUT, pushed
through XIN + X_EXP) is bit-faithful and was never the problem.

MEASURED: with 32 throwaway VEC_NORMs (plus one result-discarding A job to release XN) ahead of block
16, card 1 fed the full card's exact block-15 residual reproduces the full card's token 0 (argmax 846,
logit exp 15) and its residual after block 31 BIT FOR BIT (4,096 of 4,096 mantissas, exponent 8).
Without the padding: 4,087 of 4,096 differ and the token is 220.

## The procedure, in the order it was run, and what each step isolates

1. **Pair run** (`run_pair.sh`, `--reference` on ids): diverges at 7 / 28 / 0. Establishes only that
   the pair is not the single card.
2. **Pair at token 0** (`--prompt 248045 --max-new 1 --dump-xout`): card 0's residual after block 15
   against the reference stream `R_X-15`: corr 0.99873, rel RMS 0.051, exp 8 (the single card's final
   residual scores 0.9965 against `R_X-31`). Card 0's half is right; the pair's token is 220 against 846.
3. **Window loopback, no GO** (`loopback4.py`): a 4,096-word pattern through XIN and back through
   window 3 with the host's own pread/pwrite primitive: 0 of 4,096 differ. The mantissa transport is
   bit-faithful. (The first attempt with mmap showed 2,048 of 4,096 differing; see traps.)
4. **Card 1 alone** (`run_prompt --x-row`, new): fed card 0's dumped row it answers 220, the pair's
   token, so the pair reproduces card-1-alone exactly and the fault is inside card 1's half. Fed the
   reference's `R_X-15` it also answers 220, `R_X-31` corr 0.948.
5. **Static inputs compared**: D table of card 1 == full program's second half, 2,088 of 2,088 words;
   job-by-job tensor list identical; D header identical; HBM bases identical; per-tensor sizes,
   digests and piece layouts identical. Nothing static differs.
6. **Pushed-entry control on card 0**: blocks 1..15 from the reference's `R_X-0` reach `R_X-15` at
   corr 0.996, so entering a token from a pushed residual is not itself the fault.
7. **Bit-exact oracle**: the full image loaded on card 2, truncated programs (`--upto` at block
   boundaries) dump the single card's own residual after blocks 15, 16, 17, 18, 19 and 31. Card 0's
   row == the full card's block-15 residual, bit for bit (so the two images compute identically).
8. **Bisect by block**: card 1's half from that exact row differs from the full card ALREADY after
   block 16 (3,939 of 4,096; rms delta 11 on rms 407; not proportional to the input: corr 0.23; a
   least-squares fit gives half = 1.006 x + 1.002 ER, so no scale or exponent error).
9. **History control**: clean bitstream reloads before each side; both sides reproduce their earlier
   dumps bit for bit. No on-chip state carries across tokens.
10. **Bisect inside block 16**: after the GDN half (`--upto` at the first VEC_RES) 2,947 differ, max
    |delta| 6; redirecting the block's FIRST step (VEC_NORM) into R_X with `--override 0:dst=X` and
    `--override 244:dst=X` on the full program: the norm outputs differ in 3,825 of 4,096, max 667,
    with identical input mantissas, exponent and `const_base`. The first step is wrong.
11. **RTL**: `NORM_W_IMAGE` "indexed by NORM OP ... an image built for a different BLOCKS would serve
    every norm the gain of some other norm, silently"; `wsel <= NW_TBL(nidx)`.
12. **Confirmation by prediction**: `gen_layer_program.py --pad-norms 32` (new) emits 32 throwaway
    norms first. Two lock rules had to be honoured to make that legal, each MEASURED as a DESC refusal
    first: a producer's offset must equal the region's fill pointer (so pads 2..32 are IN-PLACE
    XN -> XN), and an in-place destination is never released by its own step (so a consumer that
    produces nothing follows: an A job on `blk.16.ssm_beta.weight` with `dst = R_NONE` and `FLG_TO_E`,
    since a destination-less job must carry a route flag and E is inert at NCARDS = 1). Result: bit
    identity with the full card, token 846.

## The evidence

```
pair, token 0:            prefill 1 ids, pos 1, first argmax 220, exp 0 ; card 0 R_X vs R_X-15: corr 0.99873
card 1 alone, card 0 row: prefill 1 ids, pos 1, first argmax 220, exp 14 ; R_X-31 vs anchor corr 0.94550
card 1 alone, anchor row: first argmax 220 ; corr 0.94838
loopback (pread/pwrite):  0 of 4096 differ; WIN_ADDR after 4096 reads: 4096
D table c1 vs full[244:]: differing words 0 of 2088 ; tensor table diff: empty
full card R_X-15 vs card 0 row: IDENTICAL mantissas
half upto 16 vs full block 16: 3939 differ   (clean reload, twice: IDENTICAL to itself)
half after GDN half vs full:   2947 differ, max |delta| 6
XN (first step) half vs full:  3825 of 4096 differ, max |delta| 667, exp 9 both
padded half (32 norms + release job), whole half: first argmax 846, exp 15 ; R_X-31 vs full card: BIT-IDENTICAL
```

Working files: `/mnt/storage/fk33_builds/pair/` (`clean/`, `fullref/`, `prog/`, `bis_*`, `pad_*`).

## Measured and REJECTED, do not retry

- **The hop transport corrupts the row.** Rejected by the loopback (0 of 4,096) and by card 0's row
  being bit-identical to the full card's own block-15 residual.
- **The pushed row's exponent is misinterpreted.** Rejected: the block-16 delta is not proportional to
  the input (corr 0.23) and the fit coefficients are 1.006 / 1.002.
- **A static input differs (program, header, descriptors, bases, weights, placement).** Rejected item
  by item in step 5.
- **On-chip state from earlier tokens.** Rejected by clean reloads on both sides.
- **The attention layer index (`kv_layer`) counts from 0 per token.** Rejected by reading: both
  `attn_block` and `attn_kv_axi` latch `layer` from the job's ordinal; and the first difference is in
  a GDN block's first norm, before any attention.
- **Padding with 32 `X -> XN` norms.** DESC-refused at step 1: a producer's offset must equal the fill
  pointer. **Padding ending on an in-place norm.** DESC-refused at step 32: an in-place destination is
  never released by its own step. **A release job with no route flag.** DESC-refused at step 32:
  `seq_desc_fetch.vhd:494`.

## Measurement traps hit

- **mmap on the user BAR hits an auto-incrementing register TWICE per access.** A python probe using
  `mmap` slices wrote and read the window with the address advancing by 2 per access (WIN_ADDR read
  8192 after 4,096 reads), which looked exactly like "the upper half of the window is dead". The host
  code uses pread/pwrite (one AXI-Lite transaction per access) and is fine. Probe the seam only with
  the primitive the host code uses.
- **A truncated program's `argmax` is stale**: with no LM head job the sampler folds nothing
  (`smp_n 0`) and the register still holds the previous token's value (846 or 220). Read `smp_n`
  before believing an argmax from a program without the head.
- **`run_prompt` printed `transport /dev/xdma0_user` while driving xdma1** (a literal in the banner,
  fixed the same day). The image lock, which refuses the wrong card's manifest, is what proved which
  card was open.
- **The float reference stream cannot localise a 2 to 3 percent numeric fault**: every block's corr
  against it drifts anyway. The bit-exact oracle (the same design's own residual, dumped at the same
  step) is what found the block, the half of the block and the step.

## Open, not yet answered

- The proper fix is in the RTL: index `NW_TBL` by the step's `const_base` (2 per block plus the tail),
  which needs a card build (about 4.5 h). Until then `fk33_chat2.sh` passes `--pad-norms 2*lo` for any
  card whose range starts above block 0, at a cost of 32 norm passes and one 32-row matvec per token
  on card 1; the cost is measured in the pair timing below when it lands.
- The `--override 33:dst=X` XN probe on the padded program was DESC-refused (not investigated; the
  whole-half bit identity made it moot).

## ADDENDUM 2026-09-23: the RTL fix, in simulation (not yet on silicon)

The fix is in `rtl/llama_top.vhd` and is plan Task 2 of
`docs/superpowers/plans/2026-09-23-27b-two-card.md`. Nothing above is withdrawn.

- **The index.** An `OP_VEC_NORM` names its gain row in `const_base`: `2*blk` for a block's first
  norm, `2*blk+1` for its FFN norm, `2*blocks` for the final norm. `seq_vec_issue` latches it at
  issue (`v_cb`); the norm engine latches it again at accept. The counter `nidx` is deleted.
- **The load** starts at the accept, not at the previous op's completion. It runs beside `S_RD`.
- **The source** is either the old table (`NORM_HBM` false, every bench default) indexed by the row,
  or HBM (`NORM_HBM` true, what `hw/fk33/gen_fk33_card.py` now builds): the row read over `bst_*`
  from `gdn_const_base + norm_const_offset + row*hidden*2`, the rows appended to the GDN constants
  image by `tools/pack_gdn_consts.py` from the same `norm_w_<sfx>.hex` the table was built from.

MEASURED, GHDL, `sim/regress.sh --only ...`:

| row | tree | result |
|---|---|---|
| `tb_llama_top_normw` (control, program from step 0) | fixed | PASS, 0 of 4 landmarks moved |
| `tb_llama_top_normrev` (rows reversed in image AND program) | fixed | PASS, normw's landmarks exactly |
| `tb_llama_top_normw` | pre-fix HEAD `61c3e7d` | PASS |
| `tb_llama_top_normrev` | pre-fix HEAD `61c3e7d` | **FAIL, 4 of 4 landmarks moved** (R_X(0) -16438 vs -16350) |
| `tb_llama_top_normhbm` (HBM path, DUT given NO table) | fixed | PASS, normw's landmarks exactly |
| `tb_llama_top_bconst_normhbm` (HBM path sharing `bst_*` with the live B state store, 3 tokens) | fixed | PASS, bconst's landmarks exactly |
| `tb_fk33_cardtop_normhbm` (HBM path in the generated card top) | fixed | PASS, normw's landmarks exactly |

So the new row kills the defect this note is about and the old row cannot; the attribution is the
P14 landmark check, which is the only check that fired on the pre-fix run.

HBM-path mutants (fixed tree, one edit each):

| mutant | row | verdict | what caught it |
|---|---|---|---|
| fetch row r+1 | normhbm | killed | `bst_bad` bounds, on the final row |
| swap rows in pairs, final row kept | normhbm | killed | landmarks, 4 of 4 moved |
| elements in reverse order within a beat | normhbm | killed | landmarks |
| `wbusy` released at element NN/2 | normhbm | **DID NOT BITE** | the unit reads the gain only after its rsqrt, long after the load ends; `wbusy` is a guard with no reachable race at this shape |
| mux takes the channel while the store is busy | bconst_normhbm | **DID NOT BITE** | no program overlaps a norm with a B job, so the exclusion arm never runs |
| store sees RVALID while the norm owns the channel | bconst_normhbm | **DID NOT BITE** | same reason |

The last two are the resolution floor: **the `bst_*` read mux's exclusion is untested by any bench.**
It is correct by construction only.

Also changed so an old program cannot meet the new RTL silently: `tools/gen_layer_program.py`
emits the row, `tools/dprog_oracle.py` C5 checks it (a 9B program from the pre-change generator
fails 63 checks, every block norm except block 0's first), and `fk33_chat.sh` / `fk33_chat2.sh`
key their cached token programs on the generator's hash.

Open: the fix is not on silicon. `--pad-norms` stays until a NORM_HBM card build runs the pair
without it and matches the single card.
