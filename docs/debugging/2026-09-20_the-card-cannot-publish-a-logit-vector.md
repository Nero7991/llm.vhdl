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

---

# APPENDED 2026-09-20 -- TRACK SMPWIN: the seam "sample window" does not exist,
# and what IS reachable is a localiser, not a measurement

**Date:** 2026-09-20. **Track:** SMPWIN. Same hardware and same bitstream as
above (`fk33_card_swg_75mhz_2026-09-20.bit`, `8dbe160`). **No hardware was
touched by this track.** Nothing above this line is edited; this section closes
the open item in section 7, *"Whether `--probe-smp` under `--upto` gives a
usable per-window prefix argmax ... Nothing has run it."*

## S1. The question, verbatim

> "Can the SHIPPING bitstream publish enough of the token-0 logit vector,
> through the seam sample window that already exists, to compare it against the
> BF16 reference, with NO new build?"

with the brief's stated premise:

> "a sample window DOES exist and is used every day by the silicon bisection
> tooling: seam registers A_WIN_LO/A_WIN_HI/A_WIN_DATA around 0x58-0x60 and
> A_SMP_N at 0x64 ... driven by `tools/gen_layer_program.py --probe-smp`".

## S2. The answer, up front

**NO, and the premise is wrong: there is no sampler sample window.** The
registers at 0x58/0x5C/0x60 are `A_WIN_SEL` / `A_WIN_ADDR` / `A_WIN_DATA` and
they are the four INDIRECT WINDOWS, none of which is a sampler window.
`--probe-smp` does not drive them at all; it sets a descriptor FLAG, and what
it publishes is the three sampler registers `ARGMAX` (0x44), `LOGIT_EXP`
(0x48) and `SMP_N` (0x64). **No logit VALUE is readable at any address on this
bitstream.**

What IS reachable, and this track built the tooling for it, is the **lm_head
PREFIX-ARGMAX CHAIN**: fifteen truncated tokens giving the running argmax over
vocabulary rows `[0, prefix_n(k))`. **MEASURED, that chain is CONSTANT on the
only reference capture that exists**, so it is a LOCALISER for a disagreement
that already exists and NOT a routine check. See S6, which is this track's own
result arguing against this track's own proposal.

## S3. What the window returns, with the RTL quoted

**MEASURED by reading the RTL.** `rtl/fk33_seam.vhd:378-381`:

```
  constant A_WIN_SEL    : natural := 16#58#;
  constant A_WIN_ADDR   : natural := 16#5C#;
  constant A_WIN_DATA   : natural := 16#60#;
  constant A_SMP_N      : natural := 16#64#;
```

`:513-517` says what `WIN_SEL` selects:

```
  -- window selectors
  constant W_DESC : natural := 0;
  constant W_REL  : natural := 1;
  constant W_XIN  : natural := 2;
  constant W_XOUT : natural := 3;
```

so the four windows are the descriptor program, the release mask, the
activation push, and the region file. `A_WIN_ADDR` is 16 bits (`:592`), the
window AUTO-INCREMENTS on a DATA read (`:1154`), and `W_DESC` is genuinely
READABLE BACK (`:1123-1135`) -- which this track uses, but for the program's
identity and not for any result.

**`W_XOUT` reads ZERO on this silicon.** `hw/fk33/gen_fk33_card.py` passes
`HOST_WINDOW=false` and `hw/fk33/rtl/fk33_card.vhd:227` hardcodes
`HOST_WINDOW => false`; `rtl/region_mem.vhd:414-416` is then

```
  g_nohost : if not HOST_WINDOW generate
    hr_data <= (others => '0');
  end generate;
```

**AND THE LOGITS ARE NOT IN A REGION EVEN IF THAT WINDOW WORKED.** Two
independent reasons, both enforced:

1. `rtl/seq_desc_fetch.vhd:502-507` -- *"the converse: a named destination
   with a route flag set would claim a region AND an external sink at once"*
   -- so every `FLG_TO_SMP` job has `dst = NO_REGION`, refused with `ERR_DESC`
   otherwise. `tools/gen_layer_program.py:493` emits the lm_head windows that
   way and `--probe-smp` forces it (`:1322-1324`).
2. An lm_head window is **17,376 rows** against `REGMAX = 4096`
   (`fk33_seam.vhd:197`). No window fits a region whatever the flags say.

**WHAT CROSSES THE SEAM IS THREE NUMBERS.** `hw/fk33/gen_pcieep.py:1316-1318`:

```
    ("smp_token",    "smp_token"),
    ("smp_n",        "smp_n"),
    ("smp_exp",      "smp_exp"),
```

`smp_valid`, `smp_v` (the 32-bit logit value) and `smp_idx` are declared as
outputs of `llama_top` (`:1068-1070`) and of `fk33_card` (`:138-141`) and are
connected to **nothing** in the block design. A `grep` for them outside
`rtl/` and `sim/` returns only declarations.

**AND THE CARD SAYS SO ITSELF.** `rtl/fk33_seam.vhd:503`:

```
  constant CAPS_FLAGS_V : std_logic_vector(31 downto 0) := x"0000003D";
```

`0x3D = 0b111101`: bit 2 `SAMPLER` **set**, bit 3 `LOGITS` (*"the card writes
the full logits row"*, `hw/fk33/host/fk33ctl.py:110`) **CLEAR**. One register
read answers the whole question.

### S3.1 The finding that matters operationally: the argmax is a FOLD COUNT

`rtl/sampler_stream.vhd:51-62` keeps its own index and publishes `best_i` from
**that** counter:

```
      elsif in_valid = '1' then
        cur := signed(in_v);
        if first then
          best_v := cur;      -- index 0 is the initial candidate
          best_i := 0;
          first  := false;
        elsif cur > best_v then
          best_v := cur;      -- strict '>' so the first max wins on ties
          best_i := idx;
        end if;
        idx   := idx + 1;
        token <= best_i;      -- running argmax (final after the last logit)
```

`llama_top` computes a separate `s_idx` from the beat's own index field and
publishes it on `smp_idx` -- **and `smp_idx` is the port that goes nowhere.**
`n_fold` (`llama_top.vhd:6996`) increments in the same cycle as the fold, and
is `smp_n`.

**Consequence: if one beat is lost, every later index shifts by the number of
logits in it and the reported argmax is a well-formed number for the wrong
row.** `SMP_N` is therefore not a statistic but the condition under which the
index means anything, and `FAULTS` bit 0 (`SMP_OVF`) is the other half. This
is why guard G3 below refuses a step rather than flagging it.

### S3.2 Why a PREFIX is what a truncated token gives

`rtl/llama_top.vhd:6960` clears the sampler on `go` and **not** per job:

```
          if go = '1' then
            s_clr  <= '1';
            wp <= 0; rp <= 0; lane <= 0; o := 0; arm <= '0';
            n_fold <= (others => '0');
          end if;
```

and the 15 lm_head windows are emitted ascending, each with `FLG_TO_SMP` and
`out_mode = RAW` so all fifteen share one exponent
(`tools/gen_layer_program.py:474-495`). So a token truncated after window *k*
reports the argmax over rows `[0, prefix_n(k))`, in **vocabulary index space**,
with no offset arithmetic. `--probe-smp` on an lm_head window is a NO-OP
flag-wise (the flag, `dst = R_NONE` and `out_mode = 1` are already set) and is
worth passing anyway because it REFUSES unless the last kept step is an A job
and prints a `PROBE` line naming it.

**VERIFIED against the generator, not assumed:** `--upto 490` prints
`PROBE step 489 output.weight ... over this job's 17376 output rows` and
writes a 491-entry release file; `--upto 504` prints `step 503 ... 5056 output
rows` and 505 entries. The step numbers match
`hw/fk33/results/card_swg_2026-09-20/profile/profile_striped_tok0.txt`, whose
504 steps end in exactly 15 `output.weight` rows at indices 489..503.

**TRAP IN THE GENERATOR'S OWN MESSAGE, not fixed here:** that `PROBE` line
says *"the sampler's ARGMAX is the row index of the max over this job's N
output rows"*. That is true for a bisection probe, where the probed job is the
only `FLG_TO_SMP` job, and **FALSE for an lm_head prefix**, where the running
argmax spans windows 1..k. `gen_layer_program.py` is not this track's file;
the wording is recorded here and `smpwin_sweep.py` prints the correct
interpretation.

## S4. The arithmetic

| quantity | value | label |
|---|---|---|
| lm_head windows | 15, stride 17,376, last 5,056, cover 248,320 exactly | DERIVED, `tools/gen_lmhead_windows.py:plan` |
| `--upto` for window *k* | `489 + k` (490..504) | DERIVED, verified against the generator |
| `TBL_LEN` for window *k* | `490 + k` (491..505) | MEASURED, the generated `.rel` line counts |
| `SMP_N` for window *k* | `17,376 k` for k<15; 248,320 at k=15 | DERIVED |
| one full token | 30,115,246 cycles = **0.4015 s** at 75 MHz | MEASURED, `profile_striped_tok0.txt` |
| the 15 prefixes summed | 444,629,945 cycles = **5.93 s** | DERIVED from the same file |
| bisection instead | ceil(log2 15) = **4 GOs**, about 1.6 s | DERIVED |
| per step, host to card | 7,856..8,080 descriptor halves + 4,096 activation writes | DERIVED; the 4,096 is MEASURED as `h2c 16384, go 1` on the simulated v2 card and as 2,947,548 B over 182 GOs in `dcdc_prompt_160.txt` |
| per step, card to host | 6 register reads at **1.92 us** each | MEASURED per-read cost, `docs/debugging/2026-08-30_readback-y-to-hbm.md:105` (3,583,291 reads in 6.885 s) |

**And the figure the seam's own header invites, corrected.** `fk33_seam.vhd:93`
says pulling the row through this window "would be 993,280 non-posted BAR
reads". At the measured 1.92 us that is **1.907 s**, not the prohibitive
number the sentence implies -- and 993,280 is 4 x 248,320, from the OLD
`Y_IDX`/`Y_LO`/`Y_HI`/`Y_EXP` protocol. Through an auto-incrementing
`WIN_DATA` it would be 248,320 reads = **0.477 s**, about one token's compute.
**This does not make it possible**: the window reads zero and the logits are
never in a region. The point of correcting it is that "too slow" is not the
reason, so nobody should go looking for a faster window.

## S5. The tooling, and its teeth

New: `tools/ref9b/smpwin_sweep.py` (`plan`, `expect`, `ingest`, `next`,
`pack`, `compare`, `--selftest`). It writes the project's existing `.r9bs`
format through `capture_to_r9bs._write_rec`; no second format was created.
Extended: `tools/ref9b/logit_compare.py` gains PARTIAL-vector handling and
`--partial-selftest`. New: `hw/fk33/host/smpwin_sweep_on_card.sh`, which
prints the procedure and refuses if `FK33_ALLOW_HARDWARE` is set (verified:
exit 3).

### The guards, and which half of the trap each one owns

| guard | reads | refuses |
|---|---|---|
| G1_PROBE | the GENERATOR's `PROBE` line | the program on disk is not this k's |
| G2_TBLLEN | the CARD's `A_TBL_LEN` | the card is not running this k's program |
| G3_SMPN | the CARD's `A_SMP_N` | the fold count is not what this prefix folds, so the index is meaningless |
| G5_FAULTS | `A_FAULTS` | any fault; bit 0 shifts every index |
| G6_RANGE | the argmax | outside `[0, prefix_n)` |
| G7_MONOTONE | the chain | a running maximum that neither kept its holder nor found one in the rows just added |
| G9_DISTINCT | the capture bytes | two steps that are the same file |
| G10_COMPLETE | the sweep | fewer than 15 steps, unless `--allow-partial` |
| G11_ANCHOR | the untruncated control run | k=15 disagreeing with the whole-token argmax |

### The teeth table

`python3 tools/ref9b/smpwin_sweep.py --selftest`: **MEASURED 0.13 s, 42.8 MB
peak, 14 mutants, 0 fail.** The attribution control for every row is the same
mutant with each firing guard disabled in turn.

| mutant | guards that fired | attribution control |
|---|---|---|
| `clean` | (none) | -- |
| `stale_probe` (k=7 is a copy of k=6's capture) | G1,G2,G3,G9 | each disabled leaves the other three |
| `stale_seam` (right program generated, run never made) | G2,G3 | G2 off -> G3; G3 off -> G2. **G1 does NOT fire, which is the point of having two.** |
| `offbyone` (`--upto 496` for k=7) | G1,G2,G3 | overlapping |
| `smpn48` (one tile of beats lost) | G3 | **G3 off -> SILENT. G3 owns it.** |
| `truncated` (12 of 15) | G10 | **G10 off -> SILENT** |
| `faults_ovf` (sticky fault, `SMP_N` correct) | G5 | **G5 off -> SILENT** |
| `range` (argmax past `prefix_n` at k=5) | G6,G7 | necessarily overlapping at k>1 |
| `range_k1` (the same at k=1) | G6 | **G6 off -> SILENT. The row that makes G6 worth having.** |
| `nonmonotone` | G7 | **G7 off -> SILENT** |
| `allsame` (one capture pasted 15 times) | G1,G2,G3,G9,G11 | overlapping |
| `anchor` (the control run disagrees) | G11 | **G11 off -> SILENT** |
| `chain_shift` (valid sweep, wrong numbers from k=9) | **(none)** | -- |
| `common` (the same defect in card AND reference) | **(none)** | -- |

plus two rows that are not mutants:

```
PARTIAL ALIGNMENT: a sweep of k=3,9,15 lands at k=[3, 9, 15] -> AGREE
COMMON-MODE CONTROL: the same chain against the UNSHARED reference -> DIVERGE
```

### The mutants that do NOT bite, under their own names

- **`common`** -- the same defect in both inputs. A differential comparison
  cannot see it; this is the resolution floor. **Its control is the line
  above**: the identical chain against a reference that does NOT share the
  defect gives DIVERGE, so the pair is genuinely defective and its agreement
  measures the floor rather than measuring nothing. A `common` row that left
  the reference alone would be a second clean row wearing a scary name.
- **`chain_shift`** -- structurally perfect, numerically wrong. No guard fires
  BY DESIGN: the guards check that the measurement was made, `compare` checks
  what it says. A guard firing here would answer the question for the
  comparator.

### Guards no mutant kills alone, and why they are kept

**G1_PROBE, G2_TBLLEN, G9_DISTINCT.** Reported rather than deleted. G1 reads
the program on disk and G2 reads the silicon; `stale_seam` fires G2 and not
G1, which is the case that has actually bitten. Neither is ever the SOLE
killer on this seam only because `TBL_LEN` differs at every k -- on a card
without that register G1 would be all that is left. G9 is subsumed by G2 for
the same reason and kept for the same reason.

### Teeth on the extension to `logit_compare.py`

`--partial-selftest`: **MEASURED 0.39 s, 67.3 MB peak, 5 rows, 0 fail.**

| row | verdict | required |
|---|---|---|
| `subset_ok` (windows 3..5, with `LOGITS_ROWS`) | ran | `vector=partial`; whole-vector argmax and TOKEN **NOT MEASURED**; 3 of 15 windows reported, 12 named NOT COVERED |
| `subset_norows` (**the same bytes**, no `LOGITS_ROWS`) | REFUSED | `LENGTH_MISMATCH`, naming the record |
| `rows_payload` (claim disagrees with payload) | REFUSED | `ROWS_PAYLOAD_MISMATCH` |
| `rows_oob` (claim leaves the vocabulary) | REFUSED | `ROWS_OUT_OF_RANGE` |
| `full_with_rows` (control: a whole vector declaring full coverage) | ran | all 15 windows covered |

`subset_ok` and `subset_norows` are each other's attribution control: the same
bytes with and without one record, so the coverage branch owns both rows and
nothing else does. The pre-existing nine-row `--selftest` table is
**unchanged** (re-run: `SELFTEST PASS 9 pass, 0 fail, 9 rows`) -- rows were
not added to it because this document quotes it verbatim.

## S6. THE RESULT THAT ARGUES AGAINST THIS TRACK'S OWN PROPOSAL

The first draft of `smpwin_sweep.py` said "15 comparisons instead of 1".
**MEASURED against the only 9B reference that exists (`tok0.r9bs`, prompt id
248045):**

```
reference n=248320  rms 2.5078  global max +12.782196 at 846  INT4 error scale ~0.3140
  k  ref_argmax win_argmax       win_max   gap to max    gap/err
  1         846        846     12.782196     0.000000         --
  2         846      20139      7.610809     5.171387       16.5
  3         846      50382      4.211945     8.570251       27.3
 ...
 13         846     209838      2.569733    10.212463       32.5
 15         846     248045      5.790070     6.992126       22.3

prefix chain distinct values: [846]
```

The winner is in **window 1** and beats every later window's maximum by 5.17 to
10.21 logits, i.e. **16 to 33 INT4 error scales** (the scale is
`0.1252 * rms = 0.314`, from this directory's recorded 0.1252 relative RMS).
So:

- **The reference's chain has ONE distinct value, not fifteen.** DERIVED: the
  card's is constant too unless something is grossly broken.
- **The one bit the chain carries -- "did a later window exceed the window-1
  maximum" -- is ALREADY IN THE ARGMAX THE SHIPPING PROGRAM REPORTS**, because
  that program folds all 15 windows into one running maximum.
- Therefore 14 of the 15 GOs confirm something already near-certain, at 5.93 s
  of card time and 15 program uploads.

**The honest use is narrow and real: run it to LOCALISE a disagreement that
already exists.** A per-window base or stride defect is the recorded OI-3
family ("a well-formed base at the wrong bytes", undetectable by the
gateware); when the full-token argmax is already wrong, the chain names which
of the 15 shards introduced it, and `smpwin_sweep.py next` bisects in 4 GOs.
The tool's header and the operator script both now say this, and `expect`
prints the headroom so the decision is made from the reference rather than
from enthusiasm.

## S7. Measured and REJECTED -- do not retry

- **Reading a logit value out of `WIN_SEL 3` (`W_XOUT`).** Two independent
  reasons, either sufficient: `HOST_WINDOW=false` ties `hr_data` to zero, and
  the lm_head output never enters a region at all (`dst = R_NONE`, enforced at
  `seq_desc_fetch.vhd:502`; and 17,376 rows do not fit `REGMAX = 4096`).
  **Turning `HOST_WINDOW` back on does not fix the second reason**, so the
  2,752,512-register synthesis wall would be paid for nothing.
- **Looking for a sampler window at 0x58-0x60.** There is none. Those are the
  DESC/REL/XIN/XOUT windows; the sampler's whole public surface is 0x44, 0x48
  and 0x64.
- **Asking the card for the MARGIN between the top logit and its neighbours.**
  Suggested in this track's brief as a weaker but useful question. It is NOT
  reachable: no value is published at any address, and an argmax over a set is
  an ordering fact, not a magnitude. `compare` refuses to print one.
- **Asking for a PER-WINDOW argmax without touching HBM.** `--upto` gives
  PREFIXES only. Isolating one window needs an arena image in which only that
  window carries `FLG_TO_SMP`, which is an HBM write per k; the chain gives
  record holders, and a window whose own maximum never beat the running
  maximum is invisible in it.
- **Excluding one vocabulary row to get a top-2 by tournament.**
  `gen_mv4i_desc.build_descriptor:464` refuses `row_start % rows_if`, so a
  window may start only on a 48-row tile boundary and the range
  `(i+1, end)` around an arbitrary winner `i` is not expressible.
- **Running the sweep against the SIMULATED backend as a numeric test.**
  `server/fk33_sim.c:525` returns `SMP_N = n_vocab` after any GO because the
  model folds the whole row at once and does not execute the descriptor table
  at all. MEASURED: `ingest` refused k=1..13 on G3 with the correct reason.
  That is the guard working, not the sim being broken; the sim exercises the
  plumbing (`pl_backend.h:58` says its logits are synthetic by construction)
  and nothing numeric.

## S8. Measurement traps hit, including this track's own

- **`compare` read a partial sweep POSITIONALLY and put a k=15 measurement on
  the k=1 row**, then localised a divergence to "rows [0,17376)" about a
  measurement of rows [0,248320). Caught by the first real end-to-end run, not
  by the selftest. It is exactly the "whole-vector statistic from a subset"
  defect this track was written to refuse, committed by this track. The packed
  file already carried `SMP_PREFIX_UPTO`; `compare` now indexes by it and a
  file without it is refused. The `PARTIAL ALIGNMENT` row is the regression.
- **Four of the fourteen expected teeth rows were hypotheses and were wrong.**
  `stale_probe` also fires G9 (a copied capture carries a copied hash);
  `range` also fires G7; **`allsame` does NOT fire G7, because fifteen
  identical argmaxes ARE monotone** -- a running maximum is allowed to keep
  its holder, so G7 is blind to a chain that never moves; and `chain_shift`'s
  first draft did not change the chain at all, because the synthetic winner
  lived in window 8 and stayed the winner. The table now records the measured
  behaviour with the reason.
- **G7 cascaded off G6's failure and reported one defect under two names.** An
  out-of-range index at k=1 made G7 fire at k=2 as well, so G6 could never be
  shown to own a row. G7 is now skipped when the previous step's index was
  itself out of range, and `range_k1` is the row that proves G6 owns something.
- **The `common` row was a no-op.** As first written it mutated neither input
  and was a second clean row wearing a scary name -- a mutant built from the
  check's own notion of the defect. It now regenerates BOTH the chain and the
  reference from a second vector, and the `COMMON-MODE CONTROL` line shows
  that same chain DIVERGING against the unshared reference.
- **An unplanned kill, and the most useful one.** A 2-minute shell timeout
  truncated the k=14 capture mid-file. `ingest` refused it with
  *"the capture has no PROBE line. A capture missing this is not a short
  capture, it is a capture of a command that did not run"* -- the exact trap
  the guard was written for, arriving by accident rather than by construction.
- **`993,280 non-posted BAR reads` reads as prohibitive and is 1.9 s.** This
  track first wrote it as 1,907 s by slipping a factor of 1,000 on the
  microsecond. The correct figures are in S4. A number quoted to close a
  question should be re-derived even when it points the way you already
  believe.
- **The brief's own premise was wrong and was stated as established.** It
  named "A_WIN_LO/A_WIN_HI/A_WIN_DATA" and said `--probe-smp` drives them. The
  RTL says otherwise in three places. Reading the register map before
  believing the brief cost twenty minutes and was the whole answer.

## S9. Open, not determined

- **Whether the card's prefix chain is in fact constant 846.** Nothing has run
  on hardware. It is a DERIVED prediction from the reference's headroom, and
  the control if anyone runs it is G11: k=15 must equal the untruncated run.
- **What `SMP_N`, `LOGIT_EXP` and `FAULTS` actually read at token 0 on the
  card.** Still not recorded against a prediction, as section 7 above already
  said. `SMP_N` must be 248,320.
- **Whether `A_STEPS_ISS` equals `490 + k` or `489 + k` on a truncated table**
  (does `END_TOKEN` raise `obs_issue`?). Parsed and recorded by `ingest` but
  deliberately NOT made a guard, because no measurement pins it. The first
  real sweep settles it.
- **Whether the per-window headroom is similar on other prompts.** Measured on
  exactly one reference capture. A prompt whose winner sits in a late window
  would give a chain with real structure and would make the sweep worth more;
  nobody has looked for one.
- **The cost of a real logits path.** Sketched below, not designed.

## S10. What a logits path would cost, and what it would answer

Requested by the brief in the event of a NO. **ESTIMATE throughout; the
assumptions are stated.**

**The route is A's output to HBM, and it is the only one.** `y_we`/`y_addr`/
`y_data` (`rtl/matvec_int4_desc_axi.vhd:263`) is a 16-bit local bus with no
master behind it; `gen_wb` is the WEIGHT fetch. What would have to change:

1. **An output AXI master on the engine.** Subsystem A already takes 27 of the
   30 engine HBM ports (`docs/2026-08-28_token-io-path.md`) and the assignment
   lives in `hw/fk33/gen_pcieep.py`, so this is a contested claim on a
   generated file and not a local edit. The seam's own header records the same
   obstacle for the v1 pointer contract.
2. **A write path in the FLG_TO_SMP branch.** The producer half already
   exists: `llama_top.vhd:4232-4241` presents `A_ROWS_IF` s32 lanes plus a
   mask per beat to the logits FIFO. A second consumer writing those beats to
   `l_base + idx*4` is a counter, an address adder and a burst assembler --
   and the FK33's HBM slave is **AXI3, so `ARLEN`/`AWLEN` are 4 bits and 16
   beats is the hard cap**, which the burst assembler must respect.
3. **Nothing on the host.** `pl_backend.c`'s v1 path already reads a
   993,344-byte row per position and `run_prompt --dump-logits` already writes
   it; `logit_compare.py` already compares it, now including partial rows.
   That is the half that exists.

**Area and risk, ESTIMATE.** The datapath is small (one master, a counter, a
burst assembler). The risk is not area, it is that the card build is
**LUT-bound at 109%** (`docs/debugging/2026-09-16_card-build-is-lut-bound-at-109-percent.md`) and that adding a 31st HBM master perturbs a place-and-route
that currently closes. The honest cost is therefore **one full `FK33_CARD=1`
build, budgeted at 47 GB with swap (CLAUDE.md's measured figure), run alone,
with an unknown probability of closing.**

**What it would answer that the argmax plus a chain does not:** how close the
card's vector is to the reference -- the relative RMS against the 0.1252 INT4
baseline, the rank of each side's argmax in the other, top-k overlap, a pure
scale or rotation defect by name, and the per-window RMS that localises a
shard defect **without needing the argmax to already be wrong**. That last
point is the real argument: the prefix chain can only localise a failure that
has already been noticed, and a per-window RMS finds a shard that is 3x worse
than its neighbours while the decision still comes out right.

**A cheaper intermediate nobody has costed:** publish the logits of ONE window
per GO through a 17,376-entry HBM buffer rather than the whole row. Same
master, 1/15th the traffic, and `logit_compare.py --partial` (built by this
track) already reads that shape via `LOGITS_ROWS`. Not designed, not costed;
recorded so the next person does not assume the choice is all-or-nothing.
