# The shipping bitstream cannot publish a logit vector

**Date:** 2026-09-20. **Track:** LOGITCMP. **Hardware:** FK33
`xcvu33p-fsvh2104-2L-e`, bitstream `hw/fk33/bit/fk33_card_swg_75mhz_2026-09-20.bit`
from `8dbe160` -- the build that produced the first correct answer at 03:05.
**No hardware was touched by this track.**

## 1. The question, verbatim

From the project memory written after the first inference:

> "Next measurements: logit-level comparison at token 0, then throughput."

and in this track's brief:

> "Today the host only reads the argmax through a fast path; `run_prompt
> --check-argmax` pulls the full logits row (`server/tests/run_prompt.c` line 30
> says so) but nothing compares the whole vector against a reference. [...] the
> honest question is how close the card's logit VECTOR is to the reference at
> token 0, where both start from identical state."

## 2. The answer, up front

**The card cannot produce a logit vector at all, on this bitstream, by any
route.** `run_prompt --check-argmax` pulls a full logits row from the
SIMULATED card only; against the silicon that is loaded today the request is
refused before a byte moves. Three independent mechanisms each make it
impossible, so this is a property of the build and not a missing host feature:

1. **The seam does not carry one.** `rtl/fk33_seam.vhd:91-94`: the v2 window
   block "returns the sampler's ARGMAX and its shared exponent. It does NOT
   return 248,320 s32 logits: there is no C2H path here, and pulling them
   through this window would be 993,280 non-posted BAR reads."
   `server/pl_backend.c:1243` refuses `want_logits` on `version >= 2` rather
   than reading whatever is at address 0.
2. **Subsystem A has no HBM write-back for its output.**
   `rtl/matvec_int4_desc_axi.vhd:263` declares `y_addr : out
   std_logic_vector(15 downto 0)` -- a 16-bit local bus into the region file.
   `gen_wb` is the WEIGHT-fetch port generate, not an output writer. The
   lm_head's 248,320 rows never become bytes in HBM that a host DMA could
   fetch.
3. **The region read-back window is compiled out.**
   `hw/fk33/gen_fk33_card.py` passes `HOST_WINDOW=false`, and `region_mem`'s own
   comment records the consequence: "hr_data reads zero and the banks can infer
   BRAM". `WIN_SEL 3` therefore returns zeros on this silicon. It was set false
   deliberately -- a combinational full-range read port cannot be BRAM and cost
   Vivado 2,752,512 registers -- so it is not an oversight to reverse casually.

What the card DOES publish per token is four registers: `ARGMAX` (0xE044),
`LOGIT_EXP` (0xE048), `SMP_N` (0xE064) and `FAULTS` (0xE068).

**What was built instead:** the whole comparison path, verified end to end
against the simulated v1 card which does have a logits row, so that the day a
bitstream with the logits DMA lands the measurement is one command; plus the
refusal to report an absent vector as agreement, which is the part that would
otherwise have gone wrong silently.

## 3. The procedure, in the order it was run

Each step is stated with what it isolates.

1. **Read the existing pieces before writing any.** `tools/ref9b/README.md`,
   `r9bs.py`, `seam_stream.h`, `check_token.py`, `mutate_logits.sh`,
   `capture_to_r9bs.py`, `server/pl_backend.h`, `server/tests/run_prompt.c`.
   ISOLATES: whether the thing already exists. It half did -- `seam_stream.h`
   is a complete C writer for the exact format wanted, and `check_token.py`
   already owns the argmax, the margin and the tie rule. Neither was rewritten.
2. **Read the record inventory of the reference capture**, not its filename.
   `python3 tools/ref9b/r9bs.py <scratch>/xexp/tok0.r9bs`. ISOLATES: what the
   reference actually contains and at what numeric kind.
3. **Find the reference's PROMPT from its own log**, because a comparison needs
   both ends drawn from the same input. `run9b_bfp_4tok.log` line 2:
   `TOKEN 0 id=248045 argmax=846 logit=12.782196`. ISOLATES: that the reference
   is the SINGLE id 248045 and not the 23-id DC-DC prompt whose token 0 is 1206.
4. **Read the first-inference transcript for the card's contract version**,
   rather than assuming it. ISOLATES: `seam v2`, `c2h 0`, `argmax fast path`.
5. **Follow the refusal to its source** in `pl_backend.c`, then to
   `fk33_seam.vhd`, then ask whether any OTHER route exists: the A write-back
   (grep the entity's ports, not the word "writeback") and the `WIN_SEL 3`
   window (grep the RTL, then the generic the card build passes). ISOLATES:
   that all three are closed, independently.
6. **Build `--dump-logits` against the SIMULATED v1 card** and read the file
   back with the pre-existing `r9bs.py` and `check_token.py`. ISOLATES: the
   plumbing, and nothing numeric -- `pl_backend.h:58` says the simulated card's
   logits are synthetic by construction.
7. **Write the comparator, then mutate it and see the rows fail.** Nine
   mutations of a finished dump, scored PER FIELD; then two mutants of the
   COMPARATOR ITSELF to confirm each new check owns its row.
8. **Run the v2 simulated card through the same path**, because the refusal is
   the case that matters on real silicon. ISOLATES: that an absent vector is
   reported as absent. It was not, at first (section 6).

## 4. The evidence

### The card is v2 and pulls no row

`hw/fk33/results/card_swg_2026-09-20/dcdc_prompt_160.txt`, verbatim:

```
card       seam v2 @BAR+0xE000 vocab=248320 embd=4096 layer=32 ctx=131072 chunk=1 x_stride=8256 l_stride=993344 | chardev user=/dev/xdma0_user ...
prefill    23 ids, pos 23, first argmax 1206, exp 15
bytes      h2c 2981888, c2h 0, go 182 (argmax fast path)
```

`c2h 0` over 182 GOs. Not one byte came back from the card.

### The reference capture

```
LOGITS        tok=0 layer=-1  n=248320  f32        min=-11.2288 max=+12.7822 rms=2.50779
TOKEN         tok=0 layer=-1  n=1       s32 e=0    min=+846 max=+846 rms=846
# 492 records
```
(MEASURED: `python3 tools/ref9b/r9bs.py`, 0.13 s, 30.7 MB peak.)

Its own log: `TOKEN 0 id=248045  argmax=846 logit=12.782196  30.90 s`. The
`12.782196` and the record's `max=+12.7822` are the same number, which is what
pins the capture to that prompt.

### The dump path, against the simulated v1 card

```
prefill    23 ids, pos 23, first argmax 187649, exp -11
dump       .../sim_tok0.r9bs: LOGITS S32 vector present, LOGIT_EXP -11, TOKEN 187649 (seam v1)
bytes      h2c 189888, c2h 993344, go 1 (full logits row per position)
argmax     0 mismatch(es) ...
```
(MEASURED: 6.1 MB peak RSS.) The file reads with the pre-existing tools
unchanged:

```
LOGITS     tok=0 layer=-1  n=248320  s32 e=-11   ...
LOGIT_EXP  tok=0 layer=-1  n=1       s32 e=0     ...
TOKEN      tok=0 layer=-1  n=1       s32 e=0     min=+187649 ...
tok  stream            source    token   n       gap          gap/rms   top2
0    sim_tok0.r9bs     REPORTED  187649  248320  2.10492e+09  53.97827  6.71068e+07
```

### The dump path, against the simulated v2 card

```
card       seam v2 ... | SIMULATED card (NOT hardware, NOT a numeric reference) v2 ...
dump       NOTE seam v2 publishes no logits row (rtl/fk33_seam.vhd:91-94: "It does NOT return 248320 s32 logits").
dump       .../simv2_tok0.r9bs: NO LOGITS RECORD -- this card publishes no logits row, LOGIT_EXP -11, TOKEN 130157 (seam v2)
bytes      h2c 16384, c2h 0, go 1 (argmax fast path)
```
then
```
CARD  simv2_tok0.r9bs: NO LOGITS record at tok 0 (LOGIT_EXP -11, TOKEN 130157)
REF   tok0.r9bs: LOGITS n=248320 kind=f32 exp=0 rms=2.50779 TOKEN=846
VECTOR UNAVAILABLE: no LOGITS record on the card side.  Every statistic below
is NOT MEASURED, which is not the same as agreement.
VERDICT NOT MEASURED: UNAVAILABLE.  This is not a pass.      [exit 2]
```

### The teeth table

`python3 tools/ref9b/logit_compare.py --selftest`, MEASURED 3.0 s, 75.5 MB
peak, 9 rows, 0 fail. The `this script` column is the VECTOR-only signature;
the `check_token` column is the ATTRIBUTION CONTROL, the pre-existing
instrument run on the identical pair.

| mutant | this script | check_token | attribution |
|---|---|---|---|
| `clean` (control) | vector-same | silent | -- both silent, as required |
| `lsb1` one LSB on one element | **vector-MOVED**, `scaled_max_abs_i` names the element | silent | **this script's kill alone** |
| `swap12` argmax and runner-up exchanged | vector-MOVED, both ranks 2, `topk_1` 0 and `topk_5` 5 | KILLS | shared; the existing check gets there first |
| `exp1` exponent off by one | **vector-MOVED**, `alpha_log2` moves exactly one octave, residual bit-identical | silent | **this script's kill alone** |
| `rot1` vector rotated by one | vector-MOVED, `rotation=1` named | KILLS | shared, but only this one says it is a ROTATION |
| `trunc` payload truncated | vector-ERROR (raises) | KILLS | shared |
| `common` the same LSB in BOTH files | **vector-same** | silent | **DOES NOT BITE, by construction** |
| `tokenbias` TOKEN moved off its own row | **vector-same** | KILLS | **DOES NOT BITE; the kill is check_token's** |
| `novec` LOGITS record absent | vector-MOVED to UNAVAILABLE, exit 2 | silent | **this script's kill alone** |

The two non-biting rows are the valuable ones. `common` measures the
resolution floor: a differential comparator cannot see an error its two inputs
share, and only an independently-written oracle can. `tokenbias` is the
dump-file shape of `fk33_sim`'s `fault_argmax_bias` -- a sampler reporting an
index its own row does not support -- and it exists so that this script is NOT
credited with a kill `check_token.py` already makes.

### Teeth on the teeth: two mutants of the comparator itself

| comparator mutant | rows that fail |
|---|---|
| `detect_shift` forced to return `None` | `rot1` only |
| best-fit `alpha` forced to `1.0` | `exp1` only |

Each new check owns exactly one row. Before the per-field scoring (section 6)
both mutants passed all nine.

## 5. Measured and REJECTED -- do not retry

- **`run_prompt --check-argmax` against the card, expecting a logit row.**
  `pl_backend.c:1243` returns -1 on `version >= 2`, so prefill fails after the
  program has been streamed and the bases written. Nothing is learned and a
  GO's worth of setup is wasted. `--dump-logits` now checks `pl_version()`
  BEFORE the GO and says why.
- **Reading the card's final activation row and computing the lm_head on the
  host.** The obvious split -- compare `R_XN.final` (4,096 values, present in
  the reference capture) and then run the host's own matvec over it -- needs
  `WIN_SEL 3`. `HOST_WINDOW=false` makes that window read zero on this build.
  DO NOT RETRY without a bitstream built with `HOST_WINDOW=true`, and note
  that such a build costs 2,752,512 registers and was the recorded cause of
  ten failed synthesis runs.
- **Looking for an HBM write-back of subsystem A's output.** `gen_wb` in
  `rtl/matvec_int4_desc_axi.vhd:640` is the WEIGHT-fetch port generate. The
  output bus is `y_we`/`y_addr`/`y_data` with a 16-bit address. There is no
  output master to point at HBM.
- **Comparing the card on the DC-DC prompt against `tok0.r9bs`.** They are
  different prompts: token 0 is 1206 and 846 respectively. The numbers would
  have been well formed and the verdict meaningless.

## 6. Measurement traps hit, including this track's own

- **A teeth test that scored "did the signature move" could not attribute a
  kill.** Two deliberate mutants of the comparator -- the rotation detector
  disabled and the best-fit scale disabled -- PASSED all nine rows, because
  `rot1` also moves rank and top-k and `exp1` also moves the residual. Each row
  now names the FIELD its check owns. This is the recorded "credited with a
  kill an existing property would have caught anyway", found by running the
  attribution control on the checker rather than on the design.
- **The attribution column read `KILLS` for every row, including the clean
  control, when `check_token.py` was simply not beside the script.** A copy of
  the comparator run from a scratch directory invoked `python3 <missing path>`,
  which exits 2, which the column read as a kill. The column is now VOID unless
  `check_token.py` exists AND is silent on the clean pair, and a VOID column is
  a failure of the test rather than a footnote. Same shape as "a residency
  checker that printed PASS over an object neither of its checks ever read".
- **`VECTOR UNAVAILABLE` exited 0 and printed the ordinary verdict.** Caught by
  running the SIMULATED v2 card, which is the only configuration that produces
  the state. The first version returned ok when EITHER side had a vector, so a
  run that read no card vector at all was reportable as a comparison that found
  nothing wrong. It now exits 2, and the `novec` row asserts the exit status and
  not only the printed text.
- **An EXACT rotation detector can never fire in a cross-format comparison.**
  `np.array_equal(a, np.roll(b, s))` compares `mant * 2^-exp` against a float;
  they never match bit-for-bit whatever the alignment. Exactness is the right
  instrument for `seam_bisect.py --mode exact` and the wrong one here. The test
  is now relative, with both sides normalised to unit RMS first (a best-fit
  alpha collapses towards zero under a rotation and cannot be divided by).
- **`alpha_log2 == 1.0` is not the property `exp1` has.** The control's own
  `alpha_log2` is 9.84e-09, the quantiser's bias, so the mutant lands on
  1.0000000098. The property is a one-octave move RELATIVE TO THE CONTROL. The
  residual needs no tolerance at all: halving is exact in binary floating point
  and the two agree to the last bit.
- **`ls` on the reference's directory does not tell you its prompt.** The
  capture's own log did. A capture named `tok0.r9bs` sitting next to the
  DC-DC artefacts is exactly as plausible for either prompt.

## 7. Open, not determined

- **How close the card's logit vector actually is to the reference.** Not
  measured, and not measurable on this bitstream. This is the whole original
  question and it remains unanswered.
- **Whether `--probe-smp` under `--upto` gives a usable per-window prefix
  argmax.** DERIVED from `rtl/llama_top.vhd:3827,3934` (`smp_base` resets on GO
  and accumulates over every `FLG_TO_SMP` job) that probing after lm_head
  window *w* should report the argmax over rows 0..end-of-window-*w*. **Nothing
  has run it.** Its control, if anyone does, is window 14, whose prefix argmax
  must equal the full token's argmax.
- **What `SMP_N` and `LOGIT_EXP` actually read at token 0 on the card.** Both
  are available today and neither has been recorded against a reference-derived
  prediction. `SMP_N` must be 248,320.
- **Whether a logits-DMA bitstream is worth building.** The host half already
  exists (`pl_backend.c`'s v1 path, 993,344 B per position, DERIVED at the
  measured 1.11 GB/s as 894.9 us) and so does the dump and the comparator. The
  cost is an FPGA build and a place-and-route draw. Not this track's call.
- **Whether the per-window section of the comparator is correct on real
  numbers.** It has been exercised only on synthetic vectors and on the
  simulated card's synthetic logits; its tiling comes from
  `tools/gen_lmhead_windows.py` and is not independently re-derived here.
