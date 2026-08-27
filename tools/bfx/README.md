# tools/bfx -- subsystem B fixed-point substitution harness

Measures what subsystem B's fixed-point activation numerics cost the model, by
substituting B's arithmetic into a real Qwen3.8-27B forward pass and scoring
perplexity. Design, results and feasibility verdict:
`docs/2026-08-27_epsilon-class-measurement-plan.md`.

## What is here

| file | what it is |
|---|---|
| `gdn_probe.cpp` | the harness: site identification, substitution via `cb_eval`, its own perplexity loop |
| `bfx_emit_chain.c` | subsystem B's emit chain (head emit, `rmsnorm_bf`, `gdn_silu`, gated product, head fold) driven from f32 tensors, plus a double control |
| `build.sh` | builds against the PREBUILT llama.cpp; writes nothing into that tree |
| `run_sweep.sh` | the full ladder of runs, one row per configuration |
| `results_wikitext_20chunks.txt` | the 2026-08-27 sweep output |
| `results_perlayer_emit_fx.txt` | per-layer error of B's emit chain on real activations |

## Build

```sh
bash tools/bfx/build.sh
```

Needs `/mnt/storage/llama-dflash2-src` with its `build/bin/*.so` present.
Override with `LLAMA_SRC` / `LLAMA_BUILD`. Nothing in that tree is modified,
rebuilt or relinked, so the tree `llama-cpp-server` runs from is untouched.

## Run

The GPUs must be free. A 27B model will not fit alongside a running
`llama-cpp-server`, which holds ~37 GB of the 48 GB. **Do not start or stop that
service to make room without asking the owner.**

```sh
M=/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf
D=/mnt/storage/ppl-data/wikitext-2-raw/wiki.test.raw

# what subsystem B looks like in the ggml graph, and the literal node chain
./tools/bfx/gdn_probe -m $M --inventory --ctx 512

# the baseline, which must equal llama-perplexity with -b 512 -ub 512
./tools/bfx/gdn_probe -m $M -f $D --ctx 512 --chunks 20 --mode baseline

# the harness self-check: MUST be bit-identical to the baseline
./tools/bfx/gdn_probe -m $M -f $D --ctx 512 --chunks 20 --mode identity

# B's emit chain in fixed point, substituted
./tools/bfx/gdn_probe -m $M -f $D --ctx 512 --chunks 20 --mode emit_fx --report

# the cheap proxy: B's error on real activations, no substitution, ~20 s
./tools/bfx/gdn_probe -m $M -f $D --ctx 512 --chunks 3 --mode emit_fx --report-only

# the scatter band, which is what any result has to be read against
OUT=/tmp/sweep.txt CHUNKS=20 bash tools/bfx/run_sweep.sh
```

## Two rules for reading any output from this tool

**Check `callback hits`.** A substitution mode that reports zero hits measured
nothing, and it reports the baseline perplexity while doing so. This has already
happened once.

**Check the result against the scatter band, not against the baseline.** At 20
chunks the band is about +/-0.02 and it does not shrink with a smaller
perturbation. See section 4 of the plan document.
