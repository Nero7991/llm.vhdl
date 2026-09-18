# THE GOAL, AS A CHECKABLE ARTEFACT

**Oren, 2026-09-17, verbatim:** *"let's work towards running full inference on
the card! The goal, get Qwen3.5 9B to answer prompt correctly 'In what cases is
DC-DC converters better than transformers'"*

"Correctly" cannot be graded by reading the card's output and nodding. This
directory turns it into a comparison:

> **The card, given `prompt_tokens.txt`, decoding greedily, must emit exactly
> the 1,197 ids in `reference_tokens.txt`, ending on 248046 (`<|im_end|>`).**

## The files

| file | what it is |
|---|---|
| `prompt_rendered.txt` | 127 bytes. The chat template's output for ONE user message, `enable_thinking = 0`, produced by reading `server/qwen35_chat.c`'s own literals: `<\|im_start\|>user\n...<\|im_end\|>\n<\|im_start\|>assistant\n<think>\n\n</think>\n\n` |
| `prompt_tokens.txt` | 23 ids, from `server/qwen35_tok.c` with `parse_special = 1` |
| `reference_tokens.txt` | 1,197 ids, the complete greedy continuation |
| `reference_answer.txt` | 5,307 bytes, the same thing detokenised, for humans |

## How the reference was produced, and the trap on the way

`llama.cpp` (`b9820-3fc4e1052`) on `/mnt/storage/llama-models/qwen35-9b/
Qwen3.5-9B-BF16.gguf` -- rung 1 of `ref/run9b.c`'s ladder, the ALGORITHM
oracle. Greedy: `temperature 0, top_k 1`. Stopped on EOS, not on a limit.

**THE PROMPT WAS HANDED OVER AS TOKEN IDS, NOT AS TEXT, AND THAT MATTERS.**
MEASURED: `llama-completion -f` on the same 127 bytes reported **31 prompt
tokens** where `server/qwen35_tok.c` with `parse_special = 1` produces **23**.
It did not fold `<|im_start|>` and friends into single ids, so it was decoding
from a DIFFERENT sequence than the card will ever see. The prose it produced
looked entirely reasonable, which is the problem: a plausible answer from the
wrong input is indistinguishable from a right one by reading.

The committed reference therefore comes from `llama-server`'s `/completion`
with `"prompt": [ids]`, the ids above, so the oracle and the card start from
the identical sequence.

Two other things that would have made the reference wrong:
- **THINKING MODE.** Qwen3.5-9B is a reasoning model and `llama-cli --jinja`
  emitted `[Start thinking]` and burned 400 tokens on a chain of thought.
  `server/qwen35_chat.h` states the template's own default is
  `enable_thinking = 0` -- `<think>\n\n</think>\n\n`, an empty already-closed
  block -- so the host runs NON-thinking and the reference must too.
- **SAMPLING.** The card's sampler is an argmax (`rtl/sampler_stream.vhd`,
  first-max-wins). A reference at any temperature above 0 is not comparable.

## What agreement does and does not prove

Matching all 1,197 ids proves the card reproduces this checkpoint's greedy
decode for this prompt. It does NOT prove the model is correct about DC-DC
converters, and it does not generalise to another prompt.

**And argmax agreement alone is weak.** `docs/PLAN_TO_FIRST_INFERENCE.md`:
*"a token that only matches on argmax is not verified"*. The strong check is
element-wise against `ref/run9b`'s stream for ONE token first; this file is the
end-to-end goal, not a substitute for that.

## Cost, DERIVED

1,197 tokens at the 38.27 ms/token budget of `docs/2026-08-28_token-io-path.md`
is 45.8 s at 200 MHz; the card is built at **75 MHz**, so roughly **2 minutes**
of continuous compute. THERM-255 trips the compute domain about every three
minutes, so this generation sits inside the window where a trip is likely --
which is why the fix lands before the long run and not after.
