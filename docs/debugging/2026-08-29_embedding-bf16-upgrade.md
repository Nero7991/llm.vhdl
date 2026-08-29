# The embedding moves from the packed INT4 copy to the GGUF BF16 copy, reference first

**Date:** 2026-08-29. Branch `fpga`. Track EMBED-BF16.
**Model:** `/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf`
(`token_embd.weight`, BF16, 4096 x 248320, 2,034,237,440 B).
**Packed set:** `/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/`
(`ROWS_IF = 48`, `AXI_DW = 256`, `qkv_segment_pad = true`).
**Tools that ran:** `gcc` 11 (`-O2 -std=c99 -Wall -Wextra`), `g++`,
`python3` + `numpy`, `gguf-py`'s `GGUFReader`, `make` (`server/Makefile`
targets `check`, `test`, `embed-check`, `llama_server`),
`tools/check_embed_bf16.py`, `tools/ref9b/{r9bs,seam_map,seam_bisect}.py`,
`ref/run9b`.
**No hardware was touched.** Nothing here ran against the FK33. No
`/dev/xdma*`, `xsdb`, `hw_server`, `vivado ... program` or `hw/fk33/*.sh`
invocation appears anywhere in this work. Section 8 is the full "NOT verified"
list.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

> **Upgrade the embedding from the packed INT4 copy to the GGUF BF16 copy. Move
> the REFERENCE FIRST, then the host.**
>
> TRACK HOSTEMB measured, both packed to int16 BFP by the same rule:
>
>     INT4 packed copy   0.086295 mean relative error
>     GGUF BF16 copy     0.000048 mean relative error      -- a factor of 1,803
>
> The reason this matters more than a weight quantisation: **the embedding row
> is an ACTIVATION, not a weight.** It is the input to the whole model, and it
> is INT4 only because it happened to be packed alongside the weight tensors.
> For scale, TRACK REF9B measured that INT4 *weights* cost 0.1252 relative RMS
> at the logits.
>
> **HOSTEMB shipped INT4 anyway and was right to** [...] It is the VERIFIED
> copy, not the accurate one. [...] **So the order is not a preference, it is
> the whole safety property.** If the host switches first, it ships an
> activation nothing has evaluated.
>
> **Step 1: `ref/run9b.c` reads the BF16 embedding.** Keep the INT4 path
> selectable so the old results stay reproducible -- a flag, not a replacement.
> Say what the flag is and what the default is.
> **Step 2: re-run the whole-model reference and re-establish its headline
> numbers on the new basis.** [...] **Report the new figures beside the old
> ones.** If the logits figure barely moves, that is a real and useful result.
> **Step 3: only then, switch `server/embed_mv4i.c`'s provider** (or add a
> sibling) to the BF16 source, keeping the INT4 provider available.
>
> [...] the 2.03 GB is **storage, not resident RAM**, and the upgrade's memory
> cost is close to zero. **Verify that**, because I am asserting it rather than
> having measured it, and report the actual resident cost of your
> implementation.

---

## 2. The answers, up front

**The flag is `--embed gguf|mv4i` on `ref/run9b.c`, and the DEFAULT IS `gguf`.**
`--gguf PATH` names the checkpoint. The old path is a flag, not a comment, and
it is not merely present: MEASURED, `--embed mv4i` reproduces the published
rung-3 stream **byte for byte** -- `md5 fdd39e6dd436cba501a8e4f0a831a2c5` on
both 29,881,643-byte files (section 5.2). Nothing about the pre-2026-08-29
numbers has to be taken on trust.

**THE LOGITS FIGURE BARELY MOVES, AND ITS SIGN IS NOT EVEN CONSISTENT ACROSS
THE FIVE POSITIONS. THAT IS THE RESULT.** MEASURED at the logits, all five
reference positions, 32 layers, both bases scored against the same unchanged
rung-1 anchor. `w:1->2` is the INT4 weight format alone:

| token | `w:1->2` INT4 embedding (old) | `w:1->2` BF16 embedding (new) | direction |
|---|---|---|---|
| 0 | 0.08765 | 0.08803 | **worse** |
| 1 | 0.11503 | 0.11626 | **worse** |
| 2 | 0.08560 | 0.08487 | better |
| 3 | 0.14550 | 0.14344 | better |
| 4 | **0.12524** | **0.12237** | better |
| mean | 0.11180 | 0.11099 | 0.7% better |

And the published headline row, token 4, in full:

| what it isolates | INT4 embedding (old) | BF16 embedding (new) |
|---|---|---|
| INT4 **weight** format, rung 1 -> rung 2 | **0.12524** | **0.12237** |
| int16 BFP **activation** format, rung 2 -> rung 3 | **0.0031305** | **0.0030803** |
| both together, rung 1 -> rung 3 | 0.12572 | 0.12205 |
| `1 - cos`, rung 1 -> rung 3 | 0.006897 | 0.006495 |

**A ~2,000x more accurate embedding buys 2.3% at the logits on the token the
headline quotes, 0.7% averaged over five, and it makes two of the five slightly
worse.** DERIVED: 0.12524 -> 0.12237 is a 2.3% relative reduction; the mean over
five positions moves 0.11180 -> 0.11099, 0.7%. **The embedding precision does
not propagate.** The sign flip on tokens 0 and 1 is the sharpest statement of it:
a change that removed essentially all of the input error can leave the output
error slightly larger, because what dominates is 32 layers of INT4 weights and
the two error fields are not aligned.

**Where the improvement actually lives, and where it dies.** MEASURED, token 4:

| seam | `w:1->2` old | `w:1->2` new |
|---|---|---|
| `R_X.embed` | 0.093985 | **0** (exactly) |
| `R_XN-0` (one RMS norm later) | 0.082542 | **5.88e-08** |
| `R_QKV.q-0` (the FIRST INT4 matvec) | 0.048385 | **0.036741** |
| `R_X-0` (end of block 0) | 0.054767 | 0.052581 |
| `LOGITS` | 0.12524 | 0.12237 |

The embedding row and the norm of it are now EXACT against llama.cpp -- rel RMS
`0` and `5.9e-08`. The error is created entirely by the first INT4 matvec, and
after one block only 4% of the old error is gone. This is a more useful picture
than the headline: the input is no longer a source of error at all, and it
barely matters.

**All five next tokens are unchanged, and so is the top-5.** Argmax 2614 / 314 /
279 / 369 / 11751 under the anchor, under the old basis and under the new. Token
4's top-5 is `[11751, 264, 1259, 3750, 7172]` on both bases. **The upgrade
changes no token this reference can see.**

**Step 3 is done and the INT4 provider is retained.** `server/embed_bf16.c` is
the sibling of `server/embed_mv4i.c`; both are built, both ship on both
toolchains, and `llama_server --embed auto|gguf|mv4i|synthetic` selects. The
BF16 provider's BFP pack is **bit-identical to `ref/run9b.c`'s own `R_X.embed`
seam** on all five reference tokens -- mantissas and exponent -- so "the host
ships what the reference evaluated" is a measurement, not a claim.

**The `pread` assertion is CORRECT, and the measurement is sharper than the
assertion.** MEASURED in ONE process so the libc baseline is identical
(section 5.5): opening the BF16 provider and gathering 64 rows costs **216 kB**
of resident memory; the same for the INT4 provider costs **228 kB**. The
upgrade's resident cost is **negative to within noise**, not 1.46 GB. But the
reason is not the one the assertion gives: `mmap` would ALSO have cost almost no
RSS, because pages fault in on touch. What `mmap` costs is **address space** --
MEASURED, `VmPeak` 3,724 kB -> **17,504,404 kB** the instant the 17.9 GB file is
mapped, with `VmHWM` moving only 2,296 -> 3,064 kB after touching 64 rows. So
the honest statement is: 2.03 GB is storage; the resident cost of either
provider is a fifth of a megabyte; and `pread` is kept for the read shape and
for 32-bit address spaces, not for RSS.

**Pre-converting to int16 BFP would be BIGGER, not smaller.** DERIVED, as the
brief suspected: 248,320 x (16 + 4,096 x 2) = 248,320 x 8,208 = **2,038,210,560
B** against the BF16 tensor's 2,034,237,440 B. 0.2% larger, plus a third file
format. Not proposed.

---

## 3. The procedure, in the order it was run

Each step says what it controls for.

1. **Read `docs/debugging/2026-08-29_host-embedding-gather.md` section 5.2
   before writing any code.** It had already worked out what the GGUF choice
   would change and in what order to change it. Controls for re-deriving a
   decision that was already made and recorded, and for getting the order
   backwards.
2. **Write the GGUF row reader as a NARROW header walk plus one `pread`**
   (`ref/embed_bf16.c`), refusing anything that is not BF16 and 2-D. Controls
   for a general parser that parses and lies, and for a mis-skipped metadata
   value landing the tensor table at a plausible-looking wrong offset.
3. **Check the reader against `gguf-py` BEFORE using it for anything.** The
   absolute offset of row 0 must agree with a parser nobody here wrote.
   Controls for a build that compiles and computes something plausible.
4. **Check the ROWS against llama.cpp's own embedding rows**, not just against
   another parser of the same file. `model.input_embed` inside the rung-1
   anchor stream is llama.cpp's `get_rows` output for the same five tokens.
   Controls for two parsers sharing one misunderstanding of the format.
5. **Only then change `ref/run9b.c`**, and change it as a FLAG. Controls for
   the old headline numbers becoming unreproducible, which would make every
   published 9B figure uncitable.
6. **Re-run rung 3 on the new basis, then re-run rung 3 on the OLD basis with
   the SAME binary, and `cmp` the old run against the committed stream.**
   Controls for the flag being a decoration: if `--embed mv4i` did not
   reproduce `ref_bfp.r9bs` byte for byte, the edit changed something it should
   not have.
7. **Re-run rung 2 on the new basis.** Controls for attributing the change to
   the wrong format: without a new rung 2, `a:2->3` cannot be separated from
   `w:1->2`.
8. **Reproduce the PUBLISHED gap table with my own script before using that
   script on the new data.** Controls for a measurement tool that produces
   different numbers for reasons of its own. It reproduces section 5.6 of the
   REF9B write-up to five significant figures.
9. **Only then write the host provider**, and check its PACK against the
   reference's own `R_X.embed` seam rather than against a numpy re-expression
   of the same rule. Controls for the `m7` mutant.
10. **Run the mutation table**, seven reader defects and three pack defects,
    and record which checks do NOT fire for each. Controls for a checker never
    shown to fail.
11. **Measure the resident cost of both providers and of the `mmap` road not
    taken, in ONE process.** Controls for comparing two processes' RSS and
    attributing the libc/stack difference to the provider.
12. **Re-run the existing server gate** (`make check`, `make test`,
    `make llama_server`, `make embed-check`). Controls for this track having
    broken another track's checks.

---

## 4. What was changed

| file | change |
|---|---|
| `ref/embed_bf16.h`, `ref/embed_bf16.c` | NEW. A narrow GGUF v2/v3 header walker plus one contiguous `pread` of a BF16 row, with seven named mutants behind `-DEMBED_BF16_MUTANTS`. |
| `ref/run9b.c` | `embed()` takes its row from either source. New `--embed gguf|mv4i` (default `gguf`) and `--gguf PATH`. The source is OPENED eagerly and PRINTED on every run as an `EMBED` line, because the hazard this flag guards against is a number quoted without its basis. |
| `server/embed_bf16.h`, `server/embed_bf16.c` | NEW. The `pl_embed_fn` on top of that reader: `reg_put`'s BFP pack, value for value. Three further mutants for the pack stage. Includes `../ref/embed_bf16.c` so there is ONE parser, not two. |
| `server/tests/embed_bf16_dump.c` | NEW. The C gather as parseable text; drives the mutants. |
| `server/tests/embed_e2e.c` | New section D2: the BF16 provider driving the same seam against the simulated card, with a check that the two providers give DIFFERENT argmaxes (without which the section would be measuring plumbing only). |
| `server/llama_server.cpp` | `--embed auto|gguf|mv4i|synthetic` and `--embed-path`. `auto` (the default) takes the BF16 GGUF when its file is present and says so; an EXPLICIT `gguf` or `mv4i` that will not open is a refusal, never a quiet downgrade. |
| `server/tests/server_e2e.py` | Now passes `--embed synthetic` explicitly, because this script's own oracle models `pl_embed_synthetic` and can check the request path against nothing else. |
| `server/Makefile` | `embed_bf16.c` into `CSRC` (both toolchains, and the board build); new `embed_bf16_dump` target; `embed-check` runs the BF16 checks and the mutation table and SKIPS cleanly when the GGUF or the oracle streams are absent. |
| `tools/check_embed_bf16.py` | NEW. Five named checks against four things this track did not write, plus the mutation table and the head-to-head accuracy comparison of the two copies. |

Reproduce with:

```sh
gcc -O2 -Wall -Wextra -I ref -o ref/run9b ref/run9b.c -lm
./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \
            --embed gguf --acts bfp --tokens 760,6511,314,9338,369 \
            --out /mnt/storage/ref9b-bf16/ref_bfp_gguf.r9bs
./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \
            --embed mv4i --acts bfp --tokens 760,6511,314,9338,369 \
            --out /mnt/storage/ref9b-bf16/ref_bfp_mv4i.r9bs
cmp /mnt/storage/ref9b/ref_bfp.r9bs /mnt/storage/ref9b-bf16/ref_bfp_mv4i.r9bs
cd server && make embed-check
```

---

## 5. The evidence, as captured output

### 5.1 The reader lands where a foreign parser says it should

```
$ server/embed_bf16_dump --gguf /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf --info
INFO gguf .../Qwen3.5-9B-BF16.gguf v3 align=32 tensor=token_embd.weight BF16
     ne0=4096 ne1=248320 data_start=0xa75be0 tensor_off=0x79400000
     row0=0x79e75be0 read=8192B x1
SHAPE M 248320 K 4096

real  0m0.089s
```

`gguf-py`'s `GGUFReader`, independently:

```
token_embd.weight  GGMLQuantizationType.BF16  [4096 248320]  data_offset 2045205472
alignment 32   data_offset (section) 10968032
```

`0x79e75be0 = 2045205472` and `0xa75be0 = 10968032`. Both agree, and the reader
found the tensor BY NAME rather than by index, which matters because
`output.weight` in this checkpoint is also BF16 and also 4096 x 248320
(section 5.4, mutant m6).

### 5.2 `--embed mv4i` reproduces the pre-2026-08-29 stream BYTE FOR BYTE

The control that makes every old number still citable. Same new binary, same
prompt, only the flag differs:

```
$ run9b --packed .../qwen35-9b-mv4i-qkvpad --embed mv4i --acts bfp \
        --tokens 760,6511,314,9338,369 --out .../ref_bfp_mv4i.r9bs
EMBED mv4i  .../qwen35-9b-mv4i-qkvpad/token_embd.weight.mv4i  (the PRE-2026-08-29 basis)
TOKEN 0 id=760   argmax=2614  logit=12.382477  43.64 s
TOKEN 1 id=6511  argmax=314   logit=17.050171  51.60 s
TOKEN 2 id=314   argmax=279   logit=14.794373  47.42 s
TOKEN 3 id=9338  argmax=369   logit=19.442627  49.84 s
TOKEN 4 id=369   argmax=11751 logit=17.576599  44.01 s
  TOP0 id=11751 logit=17.576599
  TOP1 id=264   logit=14.571533
  TOP2 id=1259  logit=14.112061
  TOP3 id=3750  logit=14.065613
  TOP4 id=7172  logit=14.009033
wrote .../ref_bfp_mv4i.r9bs: 2455 records
Elapsed 3:56.55   Maximum resident set size 3375032 kB

$ cmp /mnt/storage/ref9b/ref_bfp.r9bs /mnt/storage/ref9b-bf16/ref_bfp_mv4i.r9bs
$ md5sum ...
fdd39e6dd436cba501a8e4f0a831a2c5  /mnt/storage/ref9b/ref_bfp.r9bs
fdd39e6dd436cba501a8e4f0a831a2c5  /mnt/storage/ref9b-bf16/ref_bfp_mv4i.r9bs
```

Every logit matches the published `docs/debugging/2026-08-29_9b-whole-model-reference.md`
section 5.2 to the digit, and the 29,881,643-byte stream is identical.

And the new basis, same prompt:

```
$ run9b ... --embed gguf --acts bfp --out .../ref_bfp_gguf.r9bs
EMBED gguf  gguf .../Qwen3.5-9B-BF16.gguf v3 align=32 tensor=token_embd.weight
            BF16 ne0=4096 ne1=248320 ... row0=0x79e75be0 read=8192B x1
TOKEN 0 id=760   argmax=2614  logit=12.379822  46.60 s
TOKEN 1 id=6511  argmax=314   logit=17.002502  43.29 s
TOKEN 2 id=314   argmax=279   logit=14.769531  44.55 s
TOKEN 3 id=9338  argmax=369   logit=19.441284  46.88 s
TOKEN 4 id=369   argmax=11751 logit=17.603638  46.19 s
  TOP0 id=11751 logit=17.603638      TOP3 id=3750 logit=13.992310
  TOP1 id=264   logit=14.528870      TOP4 id=7172 logit=13.917114
  TOP2 id=1259  logit=14.085571
Elapsed 3:47.63   Maximum resident set size 2516824 kB

$ run9b ... --embed gguf --acts f32 --out .../ref_f32_gguf.r9bs        # rung 2
TOKEN 4 id=369   argmax=11751 logit=17.613599  145.50 s
Elapsed 12:31.08   Maximum resident set size 1085824 kB
```

Same argmax on all five, same top-5 ids in the same order. **Do not read
anything into the three MAXRSS figures**; see section 7.

### 5.3 The layered gap, per seam, token 4, on both bases

The tool is `gap_table.py`, and it was validated FIRST by reproducing the
published table from the published streams:

```
OLD BASIS (anchor_f32 / ref_f32 / ref_bfp) -- reproduces write-up section 5.6
seam           anchor node                  w:1->2     a:2->3   tot:1->3 | 1-cos 1->2 1-cos 1->3
R_X.embed      model.input_embed          0.093985 0.00039416   0.093977 |  0.004028   0.004028
R_XN-0         attn_norm-0                0.082542 0.00061088   0.082519 |   0.00341   0.003408
R_QKV.q-0      linear_attn_qkv_mixed-0    0.048385 0.00034685   0.048405 |  0.001059   0.001059
R_Y-0          final_output-0             0.018506 0.00057356   0.018489 | 0.0001693   0.000169
R_ER-0         linear_attn_out-0          0.040622  0.0011726   0.041026 | 0.0008001  0.0008158
R_X-0          l_out-0                    0.054767  0.0017715   0.055112 |  0.001136   0.001155
R_X-7          l_out-7                     0.12272  0.0034825    0.12323 |   0.00742   0.007473
R_X-15         l_out-15                    0.14761  0.0043494    0.14869 |   0.01085    0.01101
R_X-23         l_out-23                    0.13932  0.0046563    0.14035 |  0.009401   0.009563
R_X-31         l_out-31                    0.11955  0.0042453    0.12007 |  0.006974   0.007045
R_XN.final     result_norm                 0.12117  0.0043212    0.12177 |  0.007341   0.007412
LOGITS         result_output               0.12524  0.0031305    0.12572 |  0.006846   0.006897

NEW BASIS (anchor_f32 / ref_f32_gguf / ref_bfp_gguf)
seam           anchor node                  w:1->2     a:2->3   tot:1->3 | 1-cos 1->2 1-cos 1->3
R_X.embed      model.input_embed                 0 0.00033219 0.00033219 |         0  5.517e-08
R_XN-0         attn_norm-0              5.8791e-08 0.00057581 0.00057581 | 1.221e-15  1.657e-07
R_QKV.q-0      linear_attn_qkv_mixed-0    0.036741  0.0003458    0.03673 | 0.0005478  0.0005476
R_Y-0          final_output-0             0.014504 0.00058397   0.014475 | 0.0001031  0.0001026
R_ER-0         linear_attn_out-0          0.040054  0.0011968   0.040412 | 0.0007852  0.0008009
R_X-0          l_out-0                    0.052581  0.0017764   0.053086 |  0.001064   0.001084
R_X-7          l_out-7                     0.11711  0.0035898    0.11724 |  0.006817   0.006827
R_X-15         l_out-15                     0.1405  0.0035774    0.14089 |  0.009842   0.009895
R_X-23         l_out-23                    0.13497  0.0035248     0.1354 |  0.008682   0.008725
R_X-31         l_out-31                    0.11608  0.0040751    0.11631 |  0.006516   0.006541
R_XN.final     result_norm                 0.11739  0.0041982     0.1176 |  0.006895   0.006918
LOGITS         result_output               0.12237  0.0030803    0.12205 |  0.006515   0.006495
```

`R_X.embed` `w:1->2` is EXACTLY `0`: rung 2 now carries llama.cpp's own BF16
embedding row in float64, so there is nothing to differ. `R_XN-0` at `5.9e-08`
is `rmsnorm` in double against `rmsnorm` in ggml's float32, i.e. the floor of
the comparison. The first non-trivial number is `R_QKV.q-0`, the first INT4
matvec.

And all five positions at the logits:

```
tok  w:1->2 old / new         a:2->3 old / new         tot:1->3 old / new          argmax old/new/anchor
0      0.08765 /   0.08803   0.003437 /  0.003327    0.08793 /   0.08809   2614 / 2614 / 2614
1      0.11503 /   0.11626   0.005250 /  0.004954    0.11593 /   0.11679    314 /  314 /  314
2      0.08560 /   0.08487   0.002278 /  0.001892    0.08627 /   0.08490    279 /  279 /  279
3      0.14550 /   0.14344   0.004676 /  0.004184    0.14520 /   0.14358    369 /  369 /  369
4      0.12524 /   0.12237   0.003130 /  0.003080    0.12572 /   0.12205  11751 /11751 /11751
```

Tokens 0 and 1 are WORSE on the new basis. That is not noise in the tool -- the
streams are deterministic -- it is the honest shape of the result.

### 5.4 The C reader and the C pack, against four things this track did not write

```
$ python3 tools/check_embed_bf16.py --dump server/embed_bf16_dump --n 64 \
      --anchor /mnt/storage/ref9b/anchor_f32.r9bs \
      --ref-stream /mnt/storage/ref9b-bf16/ref_bfp_gguf.r9bs
gguf     /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
tensor   token_embd.weight  BF16 ne0=4096 ne1=248320 row0=0x79e75be0  (gguf-py)
tokens   69, corner-forced
oracles  gguf-py=yes  anchor=yes(5)  ref-stream=yes(5)

CHK-D header geometry vs gguf-py     OK
CHK-A rows vs gguf-py                0 of 69 differ (0 non-finite)
CHK-B rows vs llama.cpp input_embed  0 of 5 differ
CHK-C pack vs ref/run9b R_X.embed    0 of 5 differ
CHK-E worst matched relerr           0
      best  mismatched relerr        0.805142

CHECK PASS
```

CHK-B is bit-exact equality of 4,096 float64 against `model.input_embed` in the
rung-1 anchor -- llama.cpp's own `get_rows` output, from a loader nobody here
wrote. CHK-C is bit-exact equality of 4,096 int16 mantissas AND the shared
exponent against `ref/run9b.c`'s own `R_X.embed` record.

The mutation table, `--n 32`:

```
mutation table -- a row is KILLED if some check refuses it
mutant                                         verdict  what fired
m0 clean (control)                             PASS     must PASS or the table means nothing
m1 bf16 taken as the LOW half of the f32       KILLED   CHK-A gguf-py 37/37 worst relerr 1, CHK-B llama.cpp 5/5, CHK-C ref seam 5/5, CHK-E separation lost (1 >= 1)
m2 row + 1                                     KILLED   CHK-A gguf-py 37/37 worst relerr 1.639, CHK-B llama.cpp 5/5, CHK-C ref seam 5/5, CHK-E separation lost (1.639 >= 0)
m3 tensor offset treated as absolute           KILLED   CHK-A gguf-py 37/37 worst relerr 4.048, CHK-B llama.cpp 5/5, CHK-C ref seam 5/5, CHK-E separation lost (2.092 >= 1.287)
m4 alignment ignored                           KILLED   CHK-A gguf-py 37/37 worst relerr 0 (+37 rows NON-FINITE), CHK-B llama.cpp 5/5, CHK-C ref seam 5/5
m5 row read column-major (stride ne1)          KILLED   CHK-A gguf-py 37/37 worst relerr 4.335, CHK-B llama.cpp 5/5, CHK-C ref seam 5/5, CHK-E separation lost (1.736 >= 1.304)
m6 tensor found by index 0, not by name        KILLED   CHK-A gguf-py 37/37 worst relerr 2.306, CHK-B llama.cpp 5/5, CHK-C ref seam 5/5, CHK-E separation lost (2.026 >= 1.259)
m7 bf16 sign bit dropped                       KILLED   CHK-A gguf-py 37/37 worst relerr 1.621, CHK-B llama.cpp 5/5, CHK-C ref seam 5/5, CHK-E separation lost (1.621 >= 1.255)
m8 *exp returned negated                       KILLED   CHK-C ref seam 5/5
m9 BFP headroom TARGET_MSB 14 -> 13            KILLED   CHK-C ref seam 5/5
m10 BFP pack truncates instead of rounding     KILLED   CHK-C ref seam 5/5
killed 10 of 10
```

**Checks that do NOT bite, named. This is the part worth re-reading:**

| the check | what it CANNOT see | evidence |
|---|---|---|
| CHK-A (gguf-py), CHK-B (llama.cpp), CHK-E (separation) | **m8, m9 and m10 entirely.** All three are PACK defects and all three checks compare the row BEFORE the pack. Only CHK-C sees them, and CHK-C exists for exactly this reason. | the m8/m9/m10 rows carry one term |
| CHK-D (geometry) | **every mutant, all ten.** It reads the same header fields the clean build reads and none of the mutants touches the header parse; they act at read or pack time. It is a build-sanity check, not a correctness check, and the table says so by never listing it. | no row mentions CHK-D |
| CHK-E (neighbour separation) | **m4, m8, m9, m10.** m4 decodes to NaN so the comparison degenerates; the other three do not move the row's direction at all. | m4/m8/m9/m10 rows have no CHK-E term |
| CHK-A's *worst relative error* number | **a row that decodes to NaN.** m4 shows `worst relerr 0` -- see section 7. The verdict was right; the number was meaningless until the non-finite count was added. | the m4 row |
| all of them, jointly | **a defect present in BOTH the C reader AND `gguf-py` AND llama.cpp.** Three implementations of the GGUF format could in principle share one misunderstanding. Nothing here can see that, and nothing in this repository can. | stated, not measured |

m6 deserves its own line. `output.weight` is BF16 and 4096 x 248320, exactly like
`token_embd.weight`, so a reader that took tensor index 0 instead of matching the
name would pass every shape, dtype and bounds check in the file. Only a value
oracle kills it, and three of them do.

### 5.5 The resident cost, measured in ONE process

`rsscmp.c` (scratchpad) opens both providers and gathers 64 rows through each,
then `mmap`s the whole GGUF and touches 64 rows, all in one process so the libc
and stack baseline is shared:

```
baseline (no provider open)        VmHWM     1852 kB   VmPeak       3724 kB
after mv4i open                    VmHWM     2064 kB   VmPeak       3724 kB
mv4i, 64 rows gathered             VmHWM     2080 kB   VmPeak       3724 kB
after bf16 open                    VmHWM     2096 kB   VmPeak       3724 kB
bf16 pread, 64 rows gathered       VmHWM     2296 kB   VmPeak       3724 kB
after mmap of the whole GGUF       VmHWM     2296 kB   VmPeak   17504404 kB
mmap, 64 rows touched              VmHWM     3064 kB   VmPeak   17504404 kB
```

DERIVED: the INT4 provider costs `2080 - 1852 = 228 kB` resident; the BF16
provider costs `2296 - 2080 = 216 kB` on top of it. Neither is 572 MB and
neither is 2.03 GB. MEASURED: `mmap` of the 17.9 GB file moves `VmHWM` by 0 and
`VmPeak` by 17.5 GB.

### 5.6 The refusals, shown firing

```
$ ./server/llama_server --model qwen35 --embed gguf --embed-path /nonexistent.gguf
embed_bf16: /nonexistent.gguf: No such file or directory
[llama_server] --embed gguf could not open /nonexistent.gguf.
  REFUSED rather than downgraded: falling back to the INT4
  copy would serve an activation 1,803x coarser than the one
  the reference evaluates, with nothing in the log to say so.
  Pass --embed-path, --embed mv4i, or --embed synthetic.
rc=1

$ ./server/llama_server --model qwen35                       # the auto path
[llama_server] embedding: gguf (auto: the BF16 checkpoint is present)
    gguf .../Qwen3.5-9B-BF16.gguf v3 align=32 tensor=token_embd.weight BF16 ...
```

And the refusals inside the reader, which are the ones a wrong file hits:

```
embed_bf16: <file>: <tensor> is ggml type N <name>, not BF16 (30). Refused
  rather than reinterpreted: reading an F16 tensor as BF16 gives
  plausible-looking numbers that are wrong by 2^112.
embed_bf16: row N outside 0 .. 248319
embed_bf16: caller wants N elements, token_embd.weight has ne0 = 4096.
  Refused rather than truncated: a short embedding row is a plausible-looking
  wrong answer.
embed_bf16_dump: mutant 1 refused.  A build without
  -DEMBED_BF16_MUTANTS cannot select a defect, which is the point.     rc=3
```

### 5.7 The provider driving the real seam, beside the INT4 one

```
$ server/embed_e2e --mv4i .../token_embd.weight.mv4i \
                   --manifest .../qwen35-9b-mv4i-noembd/manifest.json \
                   --gguf .../Qwen3.5-9B-BF16.gguf
D  the real provider driving the real seam (simulated card)
   mv4i ... recipe=wide read=4096B x2
   prefilled 5, pos 5, argmax 145844 (SYNTHETIC logits: meaningless)
   H2C 41280 B for 1 GOs; the provider read 40960 B in 5 gathers
D2 the BF16 provider driving the SAME seam, on the SAME tokens
   gguf ... BF16 ne0=4096 ne1=248320 ... read=8192B x1
   prefilled 5, pos 5, argmax 79704 (SYNTHETIC logits: meaningless)
   H2C 41280 B for 1 GOs; the provider read 40960 B in 5 gathers
E  the OLD x_base, offered to pl_open with this manifest
F  and the same offer with NO manifest, which cannot be checked

EMBED_E2E PASS  (0 failed)
```

Same 40,960 B read and the same 41,280 B H2C, in **5 gathers instead of 10**.
The two argmaxes DIFFER (145844 against 79704), which is the check that this
section can tell the two providers apart at all; without it every assertion
above would be measuring plumbing only. Both numbers are `fk33_sim.c`'s
synthetic function and neither is inference.

### 5.8 The two copies at the activation, re-measured

```
$ python3 tools/check_embed_bf16.py --dump server/embed_bf16_dump --n 48 \
      --compare-mv4i .../token_embd.weight.mv4i --mv4i-dump server/embed_dump
the two copies at the ACTIVATION, both packed to int16 BFP by the
same rule, both scored against the SAME BF16 GGUF row
  rows 48
  packed INT4 -> BFP int16   mean relerr 0.086123  worst 0.126667
  GGUF BF16   -> BFP int16   mean relerr 0.000040  worst 0.000425
  ratio INT4/BF16 mean = 2151.5x
```

HOSTEMB measured `0.086295 / 0.000048 / 1803.5x` on ITS 48 rows; this is 48
DIFFERENT corner-forced rows, chosen for byte-offset corners rather than for
tile corners, and the worst-case figures (0.126667 and 0.000425) are identical.
The ratio is a property of the sample, not a constant: quote it as "roughly two
thousand", not as 1,803.

### 5.9 The existing gates still pass

```
$ cd server && make check
cc ... -fsyntax-only ... embed_mv4i.c embed_bf16.c ... tests/embed_bf16_dump.c
aarch64-linux-gnu-gcc ... -fsyntax-only fk33_manifest.c embed_mv4i.c embed_bf16.c
g++ ... -fsyntax-only llama_server.cpp
SERVER_COMPILE OK

$ make test
SEAM_SELFTEST PASS  (84 checks, 0 failed)

$ make llama_server
g++ ... embed_mv4i.o embed_bf16.o ... -o llama_server -lm -lpthread

$ ./ref/run9b --packed .../qwen35-9b-mv4i-qkvpad --selftest
SELFTEST blk.0.ssm_out.weight         M=4096    exp 2 vs 2  mismatches=0  exact
SELFTEST blk.3.attn_k.weight          M=1024    exp 2 vs 2  mismatches=0  exact
SELFTEST blk.0.ffn_down.weight        M=4096    exp 2 vs 2  mismatches=0  exact
```

The aarch64 line printed no "skipped" message, so the provider compiles for the
SBC. It was NOT run there.


---

## 6. Measured and REJECTED -- do not retry

**Switching the host first, or switching both at once.** REJECTED before
anything was written, and it is the reason this file exists in this order.
`docs/debugging/2026-08-29_host-embedding-gather.md` section 8 records HOSTEMB
nearly making the mirror-image error: it started reasoning about which copy was
more *accurate* instead of which copy was *verified*. A host that switched
first would ship an activation no rung of the reference had evaluated, and the
0.1252 everybody quotes would silently have stopped applying to it. The order
cost one extra rung-3 run (3 m 48 s) and one extra rung-2 run.

**Making `--embed gguf` fall back to the packed copy when the GGUF is missing.**
REJECTED. A fallback is exactly the mechanism by which a 1,803x coarser
activation gets served with nothing in the log to say so. `ref/run9b.c` dies
with a message naming `--embed mv4i`; `llama_server` refuses an explicit
`--embed gguf` whose file will not open. MEASURED, both refusals fire
(section 5.6). `llama_server --embed auto` DOES choose, but it chooses before
opening anything and prints the reason, which is a different thing from a
fallback after a failure.

**Deleting the INT4 path once the BF16 one worked.** REJECTED. Every 9B figure
published before 2026-08-29 -- 0.1252, 0.00313, the nine-mutant bisect table,
the five baselines in `/mnt/storage/ref9b/baseline_tok*.txt` -- was measured
with the packed embedding. MEASURED: with the flag, `--embed mv4i` reproduces
`ref_bfp.r9bs` byte for byte, so those numbers are re-derivable rather than
merely remembered.

**Pre-converting the embedding to int16 BFP on disk, to save space.** REJECTED
by arithmetic, as the brief predicted. DERIVED: 248,320 rows x (16 B header +
4,096 x 2 B) = 248,320 x 8,208 = **2,038,210,560 B**, against the BF16 tensor's
2,034,237,440 B. It is 0.2% BIGGER, not smaller, and it would add a third file
format and a second pack implementation. There is no version of this that is a
saving.

**Using `MAXRSS` of `ref/run9b` to price the change.** MEASURED and rejected as
a measurement, not as an idea. The old published figure is 4,491,652 kB and this
track's rung-3 run reports 2,516,824 kB -- a 1.9 GB "improvement" that is not
real. `run9b` `mmap`s the whole 5 GB packed set, so its RSS is dominated by how
many mapped weight pages the kernel has chosen to keep resident, and the box was
under memory pressure from six other agents. See section 7. The provider cost is
measured in one process instead (section 5.5).

**`mmap`-ing the 2.03 GB embedding tensor in the provider.** REJECTED, but NOT
for the reason the brief's cost line implies. MEASURED: `mmap` of the whole
17.9 GB GGUF costs **almost no RSS** (VmHWM 2,296 -> 3,064 kB after touching 64
rows) because pages fault in on touch. What it costs is 17.5 GB of ADDRESS
SPACE, which is free on this box and fatal on a 32-bit SBC. `pread` is kept for
that, and because the read shape is then literally the one contiguous burst a
driver or an on-card gatherer would issue.

**Writing a general GGUF parser, or vendoring `gguf-py`'s.** REJECTED. A general
parser is more code and would still have to be told which tensor matters.
`ref/embed_bf16.c` walks the header once, keeps four numbers, and REFUSES
anything that is not BF16 and 2-D rather than reinterpreting it. The check that
this narrow walk lands in the right place is CHK-D against `gguf-py`, which is
a general parser and is not ours.

**Checking the pack against a numpy re-expression of `reg_put`.** REJECTED as an
ORACLE, though the function is in `tools/check_embed_bf16.py` (`bfp_pack_np`)
and is labelled advisory. It is written by this track, so agreeing with it is a
round trip. The pack's oracle is CHK-C: `ref/run9b.c`'s own `R_X.embed` seam,
produced by code this track did not modify.

---

## 7. Measurement traps hit, including my own

**MY OWN, and it is the one that would have gone into the write-up as a
finding: a relative error printed as `0` that was actually `NaN`.** Mutant m4
(alignment ignored) shifts every read by up to 31 bytes, and the resulting
16-bit patterns decode to NaN. `relerr` then returns NaN, and in Python
`max(0.0, float("nan"))` is `0.0`, so the first run of the mutation table
printed `CHK-A gguf-py 37/37 worst relerr 0` -- a row that reads as "every row
differs, but by nothing at all". The mutant was still killed, so the verdict was
never wrong; the NUMBER was. The tool now counts non-finite rows separately and
prints them, and the table in section 5.4 carries that count. A metric that
silently collapses to its identity element on the worst input is worse than no
metric.

**`MAXRSS` of a process that `mmap`s 5 GB of weights measures the page cache,
not the program.** This track's rung-3 run reports 2,516,824 kB where the
published REF9B run reports 4,491,652 kB, for a change that touches 40 kB of
embedding per run. Nothing improved by 1.9 GB. The two runs simply saw different
memory pressure. Any RSS comparison across runs of `run9b` is meaningless, and
the resident cost of the change is measured in ONE process in section 5.5.

**`mmap` looks free if you only look at RSS.** The brief's cost line said the
upgrade costs 1.46 GB of host RAM, and the correction said it does not because
the provider `pread`s. Both are looking at the wrong counter: MEASURED,
`mmap`ing the entire 17.9 GB file moved `VmHWM` by 0 kB and `VmPeak` by
17.5 GB. If "memory cost" had been measured as RSS alone, `mmap` would have
scored identically to `pread` and the design argument would have evaporated.
The argument survives on address space and read shape, not on RSS.

**The gap table had to be validated against the PUBLISHED numbers before it was
used on new data.** `gap_table.py` reproduces section 5.6 of the REF9B write-up
to five significant figures (0.12524 / 0.0031305 / 0.12572 against the published
0.1252 / 0.00313 / 0.1257) on the SAME three streams. Without that step, any
difference in the new table would have been ambiguous between "the change did
this" and "my script computes something else".

**A per-seam improvement that is total at the seam and nearly nothing four
seams later is easy to over-report.** `R_X.embed` goes from 0.093985 to exactly
`0` and `R_XN-0` from 0.082542 to 5.9e-08 -- the input to the model and the
first norm of it are now EXACT against llama.cpp. Quoting either would have made
this look like an enormous win. By `R_X-0`, the end of the first block, 96% of
the old error is back (0.054767 -> 0.052581), and at the logits the improvement
is 2.3% on the quoted token, 0.7% averaged over five, with two of the five
slightly WORSE. The seam you quote decides what the result appears to be, and
only the logits row answers the question that was asked.

**`array_equal` is False for two identical NaNs.** The same m4 row that produced
the NaN relerr also inflates the `differ` count in a way that is correct here
but would be a false positive on a tensor that legitimately contained NaN. The
real `token_embd.weight` contains none (the clean control passes CHK-A on every
row), which is why this is recorded as a trap rather than a defect.

**`server_e2e.py` would have failed for the right reason and looked like a
regression.** Its oracle reimplements `pl_embed_synthetic`, so the moment
`llama_server`'s default embedding stopped being synthetic, every case would
have failed with the server right and the oracle wrong -- the same shape of
error that script's own comment records having hit once already. It now passes
`--embed synthetic` explicitly.

**Running tools from the repository's `sim/` directory overwrites committed
vector files.** Every command here ran from the repository root or from
`server/`, and every scratch binary was built into the session scratchpad. The
two large stream artefacts went to `/mnt/storage/ref9b-bf16/`, not to root,
which is at 93%.

---

## 8. NOT verified

* **Nothing ran against the card.** No `/dev/xdma*` was opened, no bitstream
  loaded, no JTAG or `hw_server` started, nothing under `hw/fk33/` invoked. The
  only card in the loop is `server/fk33_sim.c`, whose logits are a synthetic
  function of (position, token id, activation). **No token in this write-up is
  inference**, and the composed FK33 design still does not route.
* **The improvement is measured on FIVE tokens of ONE prompt.** 0.12524 ->
  0.12237 at the logits is token 4 of the reference prompt at 32 layers. It is
  not a perplexity measurement, it is not a corpus, and nothing here says what
  the change is worth to generated text. It is entirely possible that the
  embedding matters more on tokens whose rows are badly served by a 4.5-bit
  pack; this measurement cannot see that.
* **Rung 1 was NOT re-run.** The anchor `/mnt/storage/ref9b/anchor_f32.r9bs` is
  REF9B's, unchanged, and is correct to reuse because llama.cpp reads the BF16
  checkpoint and knows nothing about either of our embedding copies. That it is
  the right anchor is an argument, not a measurement.
* **The nine-mutant bisect table was NOT re-run on the new basis.** REF9B's
  table (8 of 9 located in exact mode, 6 of 9 in cross mode) was measured with
  the INT4 embedding. Nothing here says whether the located seams change; the
  ESTIMATE, stated as one, is that they do not, because the first diverging seam
  in every case is at least a whole block downstream of the embedding.
  Re-running it is nine rung-3 runs, about 35 minutes on a quiet box.
* **`tools/ref9b/README.md` still documents the rung-3 command without
  `--embed`.** That file belongs to TRACK C1 and was not edited. Its command is
  now the GGUF basis by default, which is correct, but the README does not say
  so. Flagged for the dispatcher.
* **The five baselines in `/mnt/storage/ref9b/baseline_tok*.txt` are the OLD
  basis.** `seam_bisect.py --baseline` gates against a clean-run profile, and
  those profiles were recorded against the INT4-embedding reference. They are
  still valid for a run made with `--embed mv4i` and are NOT valid for the
  default. Re-recording them is one rung-3 run plus five `--write-baseline`
  invocations; it was not done here because `seam_bisect.py` is TRACK C1's file
  and is currently reporting nine known-false divergences on `NORM_W_IMAGE`
  captures.
* **The GGUF reader is checked on ONE file.** Version 3, alignment 32, one BF16
  2-D tensor found by name. GGUF v2, a non-default alignment, a nested metadata
  array and a 1-D or 3-D tensor are all handled in code and none of them has
  ever been exercised.
* **`sample_tokens` covers 37 to 69 rows of 248,320.** The corners are forced
  (row 0, the last row, the 2^31 byte-offset crossing, page-boundary rows,
  powers of two) and the rest is a seeded spread. A defect affecting only some
  other specific row is not excluded.
* **The provider's per-token cost is byte counts inside a process.** One 8,192 B
  `pread` per token and 8,256 B H2C per token are MEASURED as counters; no PCIe
  transfer, no small-transfer latency, and no SBC disk or filesystem latency has
  been measured. `fk33_seam.h` records that no small-transfer latency has ever
  been measured on this card.
* **Nothing was measured on an SBC.** The address-space argument for `pread`
  over `mmap` is an ESTIMATE about 32-bit hosts; the numbers in section 5.5 are
  from this x86-64 workstation.
* **The board build was syntax-checked, not run.** `aarch64-linux-gnu-gcc
  -fsyntax-only` covers `embed_bf16.c`; `make board` was not run and no aarch64
  binary was executed.

---

## 9. Corrections

*(None yet. Later findings that overturn something above go here, dated, with
the superseded claim marked withdrawn rather than deleted.)*
