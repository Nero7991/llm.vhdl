# The OpenAI server reported zero prompt tokens and echoed every prompt

**Date:** 2026-09-04
**Component:** `server/llama_server.cpp`, `ref/run_fx.c`, default `stories260k` path

## The question

`./server/llama_server` is the OpenAI-compatible front end and the only path
here that runs real inference. Does it actually behave like the API it claims?

## The answer

**No, in two ways, and both return a well-formed 200 with plausible text.**

1. **`usage.prompt_tokens` was the literal `0`** in both response builders
   (chat and legacy), so `total_tokens` equalled `completion_tokens` and no
   client could see the prompt cost at all.
2. **`/v1/completions` echoed the prompt unconditionally**, every echoed piece
   was counted as a completion token, and `max_tokens` was spent on them.

MEASURED, before:

```
prompt "Once upon a time there was a little girl", max_tokens 60, temp 0
usage {"prompt_tokens": 0, "completion_tokens": 60, "total_tokens": 60}
text  "Once upon a time there was a little girl named Lily. She loved ..."
```

after:

```
usage {"prompt_tokens": 12, "completion_tokens": 40, "total_tokens": 52}
text  " named Lily. She loved to play outside in the park. ..."
```

and with `"echo": true`, the OpenAI flag that asks for the old behaviour, the
prompt comes back and the usage numbers do not move.

## The cause, and why it is NOT a bug in ref/

`ref/run_fx.c`'s `generate_stream` calls `on_piece` for EVERY position,
including the ones where the next token is teacher-forced from the prompt
rather than sampled:

```c
if (pos < num_prompt_tokens - 1) next = prompt_tokens[pos + 1];
else                             next = sample(sampler, logits);
...
char* piece = decode(tokenizer, token, next);
int stop = on_piece ? on_piece(piece, user) : 0;
```

That is llama2.c's original CLI behaviour -- the prompt prints back as it goes
-- and `run_tokens.sh` compares against it. **Changing it would move a
reference the VHDL engine is checked against.** So the fix is in the SERVER,
which has the opposite contract.

`ref/llama_fx.h` did assert the wrong thing, though. It said *"Each generated
piece is delivered to on_piece"*, which no caller could falsify except by
counting, and the server had believed it. The header now states that echo
pieces come through too, and a new `llama_prompt_tokens(ctx, prompt)` gives a
caller the count to skip, asked of the same tokenizer `generate_stream` uses.

The server swallows `llama_prompt_tokens(prompt) - 1` pieces before anything
counts or sends them. It is `n - 1` and not `n` because position 0 consumes
prompt token 0 and emits token 1, so a one-token prompt has no echo.

## The teeth, and the control that changed the test

`server/tests/server_stories_e2e.py`, gate row `sim:srvstories`. Run against a
`git archive HEAD` build of the PRE-FIX server:

| check | what it asserts | pre-fix |
|---|---|---|
| C1 | `usage.prompt_tokens > 0` | **FAIL** |
| C4 | the default completion does not start with the prompt | **FAIL** |
| C5 | `echo=true` text == prompt echo + the SAME continuation | **FAIL** |
| C7 | chat never echoes | **FAIL** |
| C8 | chat `prompt_tokens > 0` | **FAIL** |
| C11 | the STREAM does not lead with the prompt | **FAIL** |
| C2 | `total == prompt + completion` | pass (SHAPE ONLY) |
| C3 | `completion_tokens == max_tokens` | pass (SHAPE ONLY) |
| C6 | echo does not change `completion_tokens` | pass (SHAPE ONLY) |
| C9 | 4 content chunks for `max_tokens: 4` | pass (SHAPE ONLY) |
| C10 | last chunk carries a `finish_reason` | pass (SHAPE ONLY) |

**C5 is the load-bearing one.** Suppressing an echo is the kind of change that
can quietly alter what the model is asked to do. C5 pins that it did not: the
`echo=true` text must END WITH the default text, so both requests produce the
same continuation token for token, and the change is presentational.

**THE CONTROL CHANGED THE TEST, which is the point of running it.** C3 and C9
were written with messages claiming they caught the echo -- *"echo used to be
charged here"* and *"echoed prompt pieces used to arrive as chunks too"* -- and
the pre-fix run showed both PASSING. They cannot see it: the old code counted
echo pieces toward `max_tokens` and stopped there, so the COUNTS were identical
in both versions and only the CONTENT differed. Both messages now say SHAPE
ONLY, and **C11 exists only because the control exposed C9 as blind.**

C2 is likewise weak alone: `0 + 24 == 24` satisfies it on the broken server. It
has teeth only next to C1.

## Measured and REJECTED -- do not retry

- **"Fix the echo in `ref/run_fx.c` so every caller gets clean output."** No.
  `generate_stream`'s echo is the llama2.c CLI contract and `run_tokens.sh`
  compares against it; that path is how the fixed-point reference is held
  token-identical to the VHDL engine. Changing it to suit the server would move
  the reference. The server skips pieces instead.
- **"Count the prompt tokens in the server by splitting the request text."**
  Only the tokenizer knows. `llama_prompt_tokens` asks the same tokenizer the
  same question, with the same `bos=1, eos=0` and the same `+3` allocation
  `generate_stream` uses, so the two cannot drift.

## Measurement traps hit

- **A `git archive HEAD` tree cannot run this server.** `ref/stories260K.bin`
  is not tracked, so the archived build starts and dies with
  `Couldn't open file ref/stories260K.bin`. The control has to run the ARCHIVED
  BINARY from the REAL working directory. The first control attempt reported a
  connection refusal that looked like a port or timing problem and was neither.
- **The old server passed 5 of 10 checks.** A control that fails everything
  tells you nothing about resolution; the value here was entirely in the rows
  that passed.

## Open, not yet answered

- **`n_prompt` for the qwen35 path.** This fix covers the `stories260k` path.
  The FK33 path builds its prompt through the C chat template and tokenizer and
  its usage numbers were not examined here.
- **`logprobs`, `n`, `best_of`, `stop` as a list, `presence_penalty`** and the
  rest of the OpenAI surface remain unimplemented or unchecked. Only what is
  listed above was measured.
