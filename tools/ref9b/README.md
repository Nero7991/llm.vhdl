# tools/ref9b -- the whole-model 9B reference and its bisect

Makes a first token FALSIFIABLE. Before this, `ref/` held one whole-model
reference and it was stories260K, so the card could emit *a* token and nothing
in the repository could say whether it was the right one.

Design, decisions, measured numbers, mutation table and the "do not retry" list:
`docs/debugging/2026-08-29_9b-whole-model-reference.md`.

## Three rungs, and what each one isolates

| rung | what | isolates |
|---|---|---|
| 1 | llama.cpp on the BF16 GGUF (`dump_llamacpp`) | the ALGORITHM. Nobody here wrote it, so it is the defence against the m7 mutant |
| 2 | `ref/run9b --acts f32` | the INT4 **weight** format, and nothing else |
| 3 | `ref/run9b --acts bfp` | the int16 BFP **activation** format on top of it. This is the hardware model |

MEASURED 2026-08-29 at the logits: the weight format costs 0.1252 relative RMS,
the activation format 0.00313 on top of it, and all three rungs pick the same
next token on all five positions of the reference prompt.

## Files

| file | what it is |
|---|---|
| `seam_stream.h` | the `.r9bs` format. Every producer writes it: the anchor, the reference, and (when it exists) a simulation or hardware capture |
| `dump_llamacpp.cpp` | rung 1, via llama.cpp's public `cb_eval` hook |
| `build.sh` | builds it against a PREBUILT llama.cpp, writing nothing into that tree |
| `make_index.py` | `manifest.json` -> the flat index `ref/run9b.c` reads |
| `r9bs.py` | stream reader. Run it on a file for per-seam statistics |
| `seam_map.py` | RTL seam name -> llama.cpp node name, with the slices |
| `seam_bisect.py` | the bisect: first diverging seam, with the magnitude |
| `capture_to_r9bs.py` | a line-oriented TEXT capture (what a GHDL bench or the host driver can emit) -> `.r9bs`, and back with `--from-r9bs` |
| `capture_llama_top.sh` | runs `sim/tb_llama_top.vhd` with the capture on. `SMP=1` adds the LOGITS seam; `CAPTURE_REV=<sha>` stamps the provenance header on a scratch tree |
| `scaled_plan.py`, `bisect_scaled.py`, `vec_oracle.py`, `attn_oracle.py` | the STEPWISE oracle at the shape a GHDL run reaches, and its models |
| `ref_stream_scaled.py` | the same expectations as a `.r9bs` stream, so `--mode exact` has a counterpart |
| `mv_step_oracle.c` | one subsystem-A job through `ref/matvec_int4.c`, emitting both the BFP mantissas and the RAW s32 payload |
| `mutate_capture.sh` | teeth for the region seams |
| `mutate_logits.sh` | teeth for the LOGITS seam and the argmax |
| `check_token.py` | the automatic verdict on the DECIDED TOKEN across streams, with the margin that decision had |
| `mutate_token.py` | teeth for `check_token.py`, applied to the stream bytes rather than to the RTL |

`seam_bisect.py` is NOT called `bisect.py`, and that is not cosmetic: a file of
that name here shadows the Python standard library for every script run from
this directory.

## Build and run

```sh
python3 tools/ref9b/make_index.py /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad
gcc -O2 -Wall -Wextra -I ref -o ref/run9b ref/run9b.c -lm
LLAMA_SRC=/mnt/storage/llama-dflash2-src bash tools/ref9b/build.sh
```

**Use `/mnt/storage/llama-dflash2-src`, not `~/GitHub/llama.cpp.upstream`.** The
upstream tree's headers and its prebuilt `libllama.so` are two months apart; the
mismatch is silent at link time and surfaces as `Unsupported ctx type`.

```sh
# rung 1.  -ngl 0 and CUDA_VISIBLE_DEVICES= are deliberate: the GPUs carry a service.
CUDA_VISIBLE_DEVICES= ./tools/ref9b/dump_llamacpp \
  -m /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf \
  -o anchor.r9bs --tokens 760,6511,314,9338,369 -ngl 0 --selfcheck

# rung 3.  ~30 s and 4.5 GB per token.  Always run --selftest first.
./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad --selftest
./ref/run9b --packed /mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad \
            --tokens 760,6511,314,9338,369 --out ref.r9bs
```

## Reading a comparison

```sh
cd tools/ref9b
# once, on a clean run: record the per-seam profile
python3 seam_bisect.py ../../ref.r9bs ../../anchor.r9bs --tok 4 --write-baseline base4.txt
# then gate anything else against it
python3 seam_bisect.py suspect.r9bs ../../anchor.r9bs --tok 4 --baseline base4.txt
# and against a same-format capture, which is the sharper instrument
python3 seam_bisect.py ../../ref.r9bs capture.r9bs --mode exact --tok 4
```

**The token itself is compared automatically, and it is the only whole-model
seam that can be compared EXACTLY between `ref/run9b` and a card.** `run9b`
writes `LOGITS` as F32 while the design publishes raw s32, so those two kinds
never compare exactly -- but a token INDEX has no such problem, and `run9b`
now emits a `TOKEN` record (S32, exp 0, n = 1) carrying its own argmax:

```sh
cd tools/ref9b
python3 check_token.py ../../ref.r9bs ../../anchor.r9bs        # rung 3 vs rung 1
python3 check_token.py ../../ref.r9bs capture.r9bs --expect 2614
```

A row is **REPORTED** when the file carries `TOKEN` (the producer's own argmax)
and **DERIVED** when this script had to take the argmax itself. A DERIVED row is
a ROUND TRIP for that producer and the output says so; the llama.cpp anchor can
only ever be DERIVED, because sampling happens outside the graph `cb_eval` sees.
The verdict prints the **margin** -- the gap to the runner-up, absolutely and in
units of the logits' own RMS -- because an argmax agreement is an agreement
about a decision with a margin and is blind to every error below it. MEASURED on
the reference prompt: position 0 has a margin of 2.134 (0.551 of RMS) and
position 1 only 0.263 (0.089), so the two positions are not equally informative.

**THREE numeric kinds, not two.** A record is F32, BFP16 (int16 mantissas plus
a shared exponent) or **S32** (raw 32-bit values plus a shared exponent). S32 is
what the LOGITS seam carries, because raw `out_mode` publishes a sign-extended
s32 that `rtl/sampler_stream.vhd` reads directly; recording it as BFP16 would
right-shift it by the normalising `ns` before anything compared it. A file
containing an S32 record declares format version 2, so a reader predating it
stops loudly rather than decoding 32-bit values as int16.

**Two rules for reading any output from this tool.**

**A flat threshold is meaningless in `--mode cross`.** The clean reference sits
at rel_rms 0.105 against the anchor at the very first seam, because that is what
INT4 weights cost. At threshold 0.05, 483 of 491 seams "diverge" on a clean run.
Always pass `--baseline`.

**`--mode exact` resolves one LSB.** MEASURED: a single-mantissa perturbation
in one of 491 seams is located to the element index. That is the resolution the
card will be debugged at.

**`--mode exact` compares every record the two streams have in common**, not
just the names `seam_map.py` knows. It walked the map until 2026-08-29, and a
capture at `ATTN_INT = 2` carries three seams the 9B map has no entry for; they
were present in both streams, modelled, and never compared, while the verdict
read like full coverage. The verdict line now states the compared count against
the records present, and names anything in only one stream.

**`--mode exact` finds things `--mode cross` cannot.** Of nine mutants, cross
mode located 6 and exact mode located 8, and for one of them exact mode named a
seam a whole block earlier. A float oracle can say the algorithm is wrong; only
a same-format oracle can say which cycle to look at.

## What this does NOT cover

The interior of every block -- the conv, the L2 norm, the delta-rule recurrence,
the attention kernel, the SwiGLU, the residual add -- is computed in double and
re-packed at the region boundary. Only the subsystem A matvecs are bit-exact.
Those stages are marked `FX-HOOK` in `ref/run9b.c`; each fixed-point recipe that
lands should replace one and be measured on the way in. The full "NOT verified"
list is section 9 of the write-up.

The LOGITS seam is no longer among them: `docs/debugging/2026-08-29_logits-seam-model.md`.
