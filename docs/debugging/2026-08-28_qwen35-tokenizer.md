# Extracting and verifying the Qwen3.5-9B tokenizer

Date: 2026-08-28
Hardware/build: no hardware. Workstation only.
Model: `/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf`, 17,920,697,312 bytes.
Oracle: `~/GitHub/llama.cpp.upstream` at `1692f9e50bb20fd96b963af38a282daf78feea64`
(Fri Aug 14 2026), `libllama.so.0.0.9820`.

## 1. The question, verbatim

> Extract the Qwen3.5-9B tokenizer from the GGUF and implement encode/decode,
> verified bit-exactly against an independent oracle.
>
> [...] Verification: bit-exact agreement with the oracle over a corpus that
> includes ASCII prose, code with punctuation and indentation, CJK, emoji,
> combining characters, leading/trailing whitespace, repeated whitespace, and
> the empty string. Report the exact number of strings compared and the number
> of mismatches. Any mismatch is a failure to report, not to hide.
>
> Teeth-check: deliberately break your encoder [...] confirm the comparison
> FAILS, revert.

## 2. The answer

The tokenizer is byte-level BPE (`tokenizer.ggml.model = "gpt2"`) with the
**`qwen35`** pre-tokenizer regime, 248,320 tokens and 247,587 merges. A Python
implementation now agrees with llama.cpp **bit-exactly on 53,411 corpus strings
in both directions (encode and decode, 0 mismatches), and on all 1,112,064
Unicode codepoints in the exhaustive sweep (0 divergent)**. Two independent
pre-tokenizer backends were implemented and both pass.

The one substantive finding: **llama.cpp's Unicode category tables are NEWER
than this interpreter's**. Python 3.10 ships Unicode 13.0.0; llama.cpp's
`unicode-data.cpp` is generated from whatever UCD was current at build time.
Classifying codepoints with `unicodedata` therefore mis-splits 4,704 codepoints.
The `regex` PyPI module ships newer tables that agree exactly, so categories
come from `regex`. Separately, llama.cpp maps category `Cn` to
`CODEPOINT_FLAG_UNDEFINED = 0x0001`, which is **non-zero**, so its
`flags.as_uint()` test means "in range", not "assigned".

## 3. The procedure, in the order it was run

Each step names what it controls for.

1. **Grep the GGUF metadata keys with `gguf-py`'s `GGUFReader`**, the same
   reader `tools/pack_int4.py` already uses for tensors. Controls for "is the
   tokenizer even in this file, and under which schema". Cost: 5.3 s, no tensor
   read.
2. **Read `tokenizer.ggml.pre`.** It is `qwen35`, not `qwen2`. This single
   string decides the pre-tokenizer regex and is the difference between working
   and subtly wrong; see the `qwen2-regex` mutation below for what assuming
   `qwen2` costs.
3. **Read llama.cpp's source for that pre-type** rather than guessing:
   `src/llama-vocab.cpp` `LLAMA_VOCAB_PRE_TYPE_QWEN35` for the pattern and
   `clean_spaces = false`; `src/unicode.cpp`
   `unicode_regex_split_custom_qwen35()` for the hand-written splitter the
   oracle actually executes; `tokenizer_st_partition()` for special-token
   handling; `llm_tokenizer_bpe_session::tokenize()` for the merge algorithm.
   Controls for "am I implementing the same thing at all".
4. **Confirm `llama-tokenize` is cheap.** `/usr/bin/time -v` on one string:
   0.57 s wall, **313 MB peak RSS**, no GPU. `tools/tokenize/tokenize.cpp` sets
   `model_params.vocab_only = true`, so the 17.9 GB of tensors are never read.
   Controls for the stated worry about loading 17.9 GB; it does not happen.
5. **Build a batch oracle**, `tools/tok_oracle_batch.cpp`, so the vocab loads
   once for the whole corpus. Same `llama_tokenize` / `llama_detokenize` calls
   as `llama-tokenize`. Controls for oracle cost, not for correctness: it is
   the same code path.
6. **Corpus comparison, both directions.** Encode is ours vs the oracle's.
   Decode is ours vs the oracle's, run on the **oracle's** token ids, never on
   ours. Controls for the self-consistency trap: feeding our own ids into our
   own decoder would hide any error our encoder makes.
7. **Teeth-check with seven mutations** (section 5). Controls for "the checker
   can fail".
8. **Exhaustive codepoint sweep** (`--sweep-codepoints`). Every codepoint in
   U+0000..U+10FFFF minus surrogates, in two contexts (`a<c>b`, ` <c>1`),
   2,224,128 strings. Controls for the corpus being a sample: the
   pre-tokenizer's behaviour is a function of Unicode category, and categories
   can be enumerated rather than sampled. This is what found the version skew;
   the corpus had found only 4 of the 4,704 affected codepoints.

## 4. The evidence

### 4.1 What the GGUF carries

```
$ python3 tools/extract_tokenizer.py /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf --summary
architecture       : qwen35
tokenizer.model    : gpt2
tokenizer.pre      : qwen35
n_tokens           : 248320
n_merges           : 247587
  token_type 1 NORMAL       : 248044
  token_type 3 CONTROL      : 27
  token_type 4 USER_DEFINED : 6
  token_type 5 BYTE         : 243
bos_token_id       : None
eos_token_id       : 248046  '<|im_end|>'
pad_token_id       : 248055  '<|vision_pad|>'
unk_token_id       : None
add_bos_token      : None
add_eos_token      : None
add_bos (resolved) : False
clean_spaces       : False
chat_template chars: 7816
special tokens     : 33
```

The 33 specials (CONTROL + USER_DEFINED) are ids 248044..248076:
`<|endoftext|> <|im_start|> <|im_end|> <|object_ref_start|> <|object_ref_end|>
<|box_start|> <|box_end|> <|quad_start|> <|quad_end|> <|vision_start|>
<|vision_end|> <|vision_pad|> <|image_pad|> <|video_pad|> <tool_call>
</tool_call> <|fim_prefix|> <|fim_middle|> <|fim_suffix|> <|fim_pad|>
<|repo_name|> <|file_sep|> <tool_response> </tool_response> <think> </think>
<|audio_start|> <|audio_end|> <tts_pad> <tts_text_bos> <tts_text_eod>
<tts_text_bos_single> <|audio_pad|>`.

Note there are only **243** BYTE tokens, not 256: 13 of the byte-mapped
characters also appear as NORMAL tokens and carry that type instead. The
decoder must therefore not key on type BYTE; it undoes the GPT-2 byte map for
NORMAL and BYTE alike, which is exactly what `llama_vocab::impl::token_to_piece`
does.

Artefact sizes, MEASURED:

| file | bytes | committed |
|---|---|---|
| `build_artifacts_tok/qwen35_9b.qtk` | 8,957,440 | no, regenerate |
| `build_artifacts_tok/qwen35_9b_meta.json` | 9,459 | no, regenerate |
| `build_artifacts_tok/qwen35_chat_template.jinja` | 7,816 | no, regenerate |
| `build_artifacts_tok/tok_oracle_batch` | 22,112 | no, rebuild |

Regenerate with:

```
python3 tools/extract_tokenizer.py \
    /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf \
    build_artifacts_tok/qwen35_9b.qtk \
    --json build_artifacts_tok/qwen35_9b_meta.json \
    --template build_artifacts_tok/qwen35_chat_template.jinja
```

Wall time 5.9 s.

### 4.2 The oracle is cheap

```
$ /usr/bin/time -v ./build/bin/llama-tokenize -m .../Qwen3.5-9B-BF16.gguf -p "Hello, world! 你好" --ids --log-disable
[9419, 11, 1814, 0, 220, 109266]
	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:00.57
	Maximum resident set size (kbytes): 313464
	Major (requiring I/O) page faults: 44
```

313 MB, not 17.9 GB. `llama-cpp-server.service` was never touched and no model
was put on a GPU.

### 4.3 Corpus verification, final

```
$ python3 tools/verify_tokenizer.py --qtk build_artifacts_tok/qwen35_9b.qtk \
    --gguf /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf \
    --oracle build_artifacts_tok/tok_oracle_batch --n-random 40000
corpus            : 53411 strings, 2502660 UTF-8 bytes
split backend     : regex
encode compared   : 53411
encode mismatches : 0
decode compared   : 53411
decode mismatches : 0

RESULT: PASS (0 mismatches over 53411 strings x 2 directions)
```

Same with `--split llamacpp`: `PASS (0 mismatches over 53411 strings x 2
directions)`.

The corpus deliberately contains, all with 0 mismatches: the empty string;
single and repeated spaces, tabs, `\n`, `\r\n`, `\r`, U+000B, U+000C, U+0085,
U+2028, U+2029, U+3000, U+00A0, U+200B, U+FEFF; leading, trailing and
surrounding whitespace on every prose/code/CJK sample; English prose with
contractions in both cases (`'s 'S 't 'RE 've 'M 'll 'LL 'd 'D`, `y'all'd've`);
Python, VHDL and C source with tab and space indentation; 40 real files from
`rtl/ ref/ tools/ docs/ server/` sampled at random offsets; Chinese, Japanese,
Korean; Arabic and Hebrew (RTL); emoji including ZWJ sequences, regional
indicator pairs and a tag-sequence flag; combining marks standalone, leading,
trailing and stacked (`A` + four combining diacritics, Devanagari, Thai); Arabic
and CJK and Roman-numeral and fraction numerals; NUL and other C0 control bytes;
all 33 special-token texts, nested, adjacent, and truncated (`<|im_start|`).

### 4.4 Exhaustive codepoint sweep

```
regex:    divergent codepoints = 0 of 1112064
llamacpp: divergent codepoints = 0 of 1112064
```

2,224,128 strings per backend. This is the strongest statement available: the
pre-tokenizer's decisions are per-codepoint category decisions, and every
codepoint was checked in both a letter context and a space/digit context.

## 5. Teeth-check: seven mutations, four bite

Run as `--mutate NAME` on the 2,645-string default corpus.

| mutation | what it breaks | mismatches | verdict |
|---|---|---|---|
| `merge-rank` | demotes merge `('Ġ','t')` from rank 3 to last | **212 encode** | FAIL, correct |
| `drop-special` | forgets `<|im_start|>` is special | **49 encode** | FAIL, correct |
| `qwen2-regex` | uses the qwen2 pattern instead of qwen35 | **68 encode** | FAIL, correct |
| `byte-map` | byte 0x20 maps to `!` instead of `Ġ` | **800 encode** | FAIL, correct |
| `decode-special` | decoder stops rendering CONTROL tokens | **181 decode** | FAIL, correct |
| `decode-bytemap` | inverse map: U+0120 decodes to 0x21 | **800 decode** | FAIL, correct |
| `merge-rank-mid` | swaps two adjacent mid-table ranks | 0 | PASS, see 6.1 |
| `merge-rank-01` | swaps ranks 0 and 1 | 0 | PASS, see 6.1 |

Verbatim failure output for the two most informative:

```
MUTATION APPLIED  : demoted merge ('Ġ', 't') from rank 3 to rank 247587 (last)
encode mismatches : 212
  [116] text="The quick brown fox jumps over the lazy dog. It's a test; isn't it? She'd say they've ...
       ours  =[760, 3841, 13477, 37550, 33075, 888, 220, 1719, 15217, 5388, 13, ...]
       oracle=[760, 3841, 13477, 37550, 33075, 888, 279, 15217, 5388, 13, ...]
RESULT: FAIL (212 mismatches over 2645 strings x 2 directions)
```

(` the` = 279 collapses to 220 + 1719 = `' '` + `'the'` once the space+t merge
is demoted.)

```
MUTATION APPLIED  : replaced the qwen35 pre-tokenizer pattern with the qwen2 one (no \p{M})
encode mismatches : 68
  [121] text='é à́ ñ ȫ क्ष กำ A̴̵̶̷'
       ours  =[68, 52033, 264, 93213, 52033, 307, 136, 225, 296, 136, 230, 136, 226, 46215, 157451, 156644, ...]
       oracle=[68, 52033, 264, 93213, 52033, 307, 136, 225, 296, 136, 230, 136, 226, 165216, 156644, ...]
RESULT: FAIL (68 mismatches over 2645 strings x 2 directions)
```

That one is the point of the whole exercise: the qwen2 and qwen35 patterns
differ only in `\p{M}`, they agree on every ASCII string, and the difference
shows up on Devanagari `क्ष` and on emoji ZWJ sequences. Taking `pre` to be
qwen2 because "it is a Qwen model" would pass any ASCII smoke test.

```
MUTATION APPLIED  : decoder no longer renders CONTROL tokens (e.g. <|im_end|>) as text
decode mismatches : 181
  [106] ids=[248045, 846, 198, 9419, 248046, 198, 248045, 74455, 198]
       ours  =b'user\nHello\nassistant\n'
       oracle=b'<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n'
```

All mutations were reverted; the final numbers in 4.3 and 4.4 are from the
unmutated code.

## 6. Measured and REJECTED -- do not retry

### 6.1 Two "perturb a merge rank" mutations that have no teeth

**Do not use either as a teeth-check.** Both were run, both PASS, and both are
kept in `apply_mutation()` under their own names precisely so nobody rediscovers
them and concludes the checker is broken.

* `merge-rank-mid`: swaps ranks 123793 and 123794, which belong to
  `('å¥½','å¿ĥ')` and `('å¸¦','åĽŀ')` (byte-mapped Chinese). No realistic
  corpus contains the exact byte sequences those merges need. 0 mismatches.
* `merge-rank-01`: swaps ranks 0 and 1, `('Ġ','Ġ')` and `('ĠĠ','ĠĠ')`.
  0 mismatches, and this one is not a corpus-coverage problem but a
  **structural** one: the pair `('ĠĠ','ĠĠ')` cannot exist as adjacent symbols
  until `('Ġ','Ġ')` has already fired, so their relative rank is unobservable
  at any corpus size.

A rank perturbation only changes output when it inverts the order of two merges
that **compete for overlapping positions and are both reachable**. Demoting
`('Ġ','t')` to last does that; 212 mismatches.

A first automated attempt at "find a competing pair" scanned merges for
`(a,b)`,`(b,c)` and landed on `('Ġ','Ġ')` vs `('Ġ','t')`, which also produced
0 mismatches. Rejected in favour of naming the merge explicitly.

### 6.2 Classifying codepoints with Python's `unicodedata`

**Do not retry.** The `llamacpp` split backend originally used
`unicodedata.category()`. It failed on **4 of 53,411** corpus strings and, once
the exhaustive sweep was written, on **4,704 of 1,112,064 codepoints**, every
one of them category `Cn` under this interpreter.

Two distinct causes, both fixed:

1. **Version skew.** `python3 -c "import unicodedata; print(unicodedata.unidata_version)"`
   gives **13.0.0**. `scripts/gen-unicode-data.py` in llama.cpp downloads
   `https://www.unicode.org/Public/UCD/latest/ucd/UnicodeData.txt` at generation
   time, so its tables are newer. Example: **U+0870** is `Lo` for llama.cpp and
   the `regex` module, `Cn` for this Python, so we split it as punctuation and
   the oracle split it as a letter.

   ```
   $ python3 -c "import regex,unicodedata; c=chr(0x870); print(unicodedata.category(c), bool(regex.match(r'\p{L}',c)))"
   Cn True
   ```

   Fix: take `\p{L}`, `\p{M}`, `\p{N}` from the `regex` module (2.5.140), whose
   tables agree with llama.cpp's on all 1,112,064 codepoints. `unicodedata` is
   kept only as a fallback and is known to be wrong on those 4,704.

2. **`Cn` is not "no flags".** `gen-unicode-data.py` has
   `"Cn": CODEPOINT_FLAG_UNDEFINED` where `UNDEFINED = 0x0001`, so
   `unicode_cpt_flags::as_uint()` is non-zero for **every** codepoint. The only
   all-zero value is the sentinel `unicode_cpt_flags{}` that
   `unicode_regex_split_custom_qwen35`'s `_get_flags` returns for an
   out-of-range index. Our `_has_flags` had been testing "is this codepoint
   assigned"; it now tests "is this position in range", which is what the C++
   means.

### 6.3 Assuming `\s` is Unicode category Z

**Do not retry.** llama.cpp's whitespace set is an explicit list in
`gen-unicode-data.py`, namely U+0009..U+000D, U+0020, U+0085, U+00A0, U+1680,
U+2000..U+200A, U+2028, U+2029, U+202F, U+205F, U+3000. That is Unicode
`White_Space`, and it is not category Z: `\t \n \v \f \r` are `Cc`, and U+180E
is `Cf` and is **not** in the set even though older tables call it a separator.
The transcription now uses that literal list.

### 6.4 Reconstructing a HuggingFace `tokenizer.json` as the oracle

Not done, and deliberately. `transformers` 4.57.1 and `tokenizers` 0.22.1 are
installed on this box, but there is **no `tokenizer.json` on disk** for this
model (`/mnt/storage/llama-models/qwen35-9b/` holds only the two GGUFs and a
`.cache`). Building one out of the GGUF's own tokens and merges and then
checking against it would be checking our reading of the GGUF against our
reading of the GGUF, which is the same self-consistency trap as a round trip
wearing a different hat. llama.cpp reads the GGUF itself, independently, and is
the oracle.

## 7. Measurement traps hit

* **A round trip is not an oracle, and neither is feeding your own ids to your
  own decoder.** The decode comparison runs on the **oracle's** token ids
  (`verify_tokenizer.py` pass 2). If it ran on ours, then for any string our
  encoder got wrong our decoder would be asked a different question than the
  oracle's, and a compensating pair of bugs would pass. Deliberate; see the
  `m7 mutant` precedent in this repo's history.
* **A 2,645-string corpus found 4 of 4,704 broken codepoints.** Corpus size is
  not coverage. When behaviour is a function of an enumerable input class,
  enumerate it. The sweep costs a few minutes.
* **A mutation that passes proves nothing about the code under test.** Two of
  the seven mutations here pass, for two different structural reasons (6.1).
  Had `merge-rank-mid` been the only teeth-check, the honest conclusion would
  have been "the checker was never shown to fail", not "the tokenizer is
  correct".
* **`-p` on `llama-tokenize` processes escapes by default** (`\n` becomes a
  newline) unless `--no-escape` is given. The batch oracle passes raw bytes over
  a length-prefixed pipe and never goes near that path, which is one more reason
  it exists.
* **Peak RSS, not file size, is what a `vocab_only` load costs.** The 17.9 GB
  figure never materialises: 313 MB measured.

## 8. The chat template, and what it implies for `/v1/chat/completions`

Extracted to `build_artifacts_tok/qwen35_chat_template.jinja`, 7,816 bytes.
Not implemented here; this section only makes the consequences legible.

**Role markers.** ChatML. Every message is
`<|im_start|>` + role + `\n` + content + `<|im_end|>` + `\n`. Roles accepted:
`system`, `user`, `assistant`, `tool`; anything else raises. A `system` message
is only emitted if it is `messages[0]`, and a `system` message anywhere else
raises `System message must be at the beginning`.

**BOS.** There is none, at either level. The GGUF has no `bos_token_id` and no
`add_bos_token`, llama.cpp's BPE path leaves `add_bos = false`, and the template
emits no BOS. **Do not prepend anything.**

**EOS / stop.** `eos_token_id = 248046 = <|im_end|>`. Generation stops there.
`<|endoftext|>` (248044) should also be treated as a stop token by a server, as
should the tool-call closer if tools are in play. The pad token is
`<|vision_pad|>` (248055), which is a vision pad, not a text pad; do not use it
as a text filler.

**Generation prompt.** With `add_generation_prompt`, the template appends
`<|im_start|>assistant\n` and then, unconditionally, one of two thinking
preambles:

* `enable_thinking` true: `<think>\n` -- the model continues inside a reasoning
  block and is expected to close it with `</think>`.
* otherwise (**including when the flag is simply absent**):
  `<think>\n\n</think>\n\n` -- an empty, already-closed reasoning block.

This is the single most consequential detail for an OpenAI-compatible endpoint.
The **default branch is the non-thinking one**, and it is not "emit nothing": it
emits four tokens' worth of empty think block. A server that appends only
`<|im_start|>assistant\n` is off-distribution. `<think>` and `</think>` are
tokens 248068 and 248069, both CONTROL, so with `parse_special` on they encode
as single ids.

**Reasoning round-trips.** For assistant messages at or before the last user
query the template emits content only. For assistant messages **after** it, it
emits `<think>\n` + reasoning + `\n</think>\n\n` + content, and it will pull the
reasoning out of the content string itself by splitting on `</think>` if no
separate `reasoning_content` field is given. An endpoint that echoes prior
assistant turns must decide whether it is storing reasoning separately or
inline; both are supported, inline is the fallback.

**Tools.** If `tools` is passed, the template writes its own system message
containing a `<tools>` JSON block and a strict format contract, and folds any
caller system message in after it. The call syntax is **not** JSON-in-
`<tool_call>`; it is nested XML:

```
<tool_call>
<function=NAME>
<parameter=P1>
value
</parameter>
</function>
</tool_call>
```

`<tool_call>` / `</tool_call>` (248058 / 248059) are USER_DEFINED tokens;
`<function=` and `<parameter=` are ordinary text. Tool results go back as role
`tool`, and consecutive tool messages are **merged into one `<|im_start|>user`
turn** with each result wrapped in `<tool_response>...</tool_response>`.

**Multimodal.** Images and videos become
`<|vision_start|><|image_pad|><|vision_end|>` and
`<|vision_start|><|video_pad|><|vision_end|>`. Irrelevant to a text-only
endpoint, but note the vocab and the `mmproj-BF16.gguf` alongside the model both
support it.

**Content trimming.** Every message's rendered content is `|trim`ed. A server
that preserves user trailing whitespace will not match the reference rendering.

## 9. Open, not yet answered

* **No C implementation exists.** `server/llama_server.cpp` is zero-dep C++ and
  cannot call Python, so the current tokenizer cannot serve the endpoint. The
  port is mechanical for steps 1, 3, 4 and 5 of the pipeline; step 2 needs
  Unicode category tables for `\p{L}`, `\p{M}`, `\p{N}` and `White_Space`, which
  is precisely why llama.cpp generates and ships `unicode-data.cpp`. Port the
  `llamacpp` split backend, not the `regex` one, and generate the tables from
  the same UCD the oracle used or the 4,704-codepoint skew comes straight back.
* **The chat template is not implemented**, only read. In particular nothing
  here renders Jinja; a C server needs either a hand-written ChatML emitter that
  reproduces section 8 or a Jinja subset.
* **Invalid UTF-8 input was not tested.** The verification protocol carries
  Python `str`, so every compared string is valid UTF-8. llama.cpp accepts
  arbitrary bytes. Untested, and a server taking JSON is unlikely to see it, but
  it is untested.
* **`add_special = true` was not compared.** The oracle harness supports
  `--add-special` and the resolved `add_bos` is false, so it should be a no-op,
  but it was not exercised.
* **`parse_special = false` was not compared.** Only the `parse_special = true`
  path (llama-tokenize's default) was verified. The Python side implements the
  false path; it is unverified.
* **Only this one GGUF was tested.** The `mmproj-BF16.gguf` alongside it was not
  looked at.
* **Merge-table ties.** llama.cpp sorts `cache_special_tokens` with
  `std::sort`, which is unstable, on text length alone. We sort by
  `(-len, id)`. No corpus string distinguished them, and it is not obvious that
  one exists, but the tie-break is not proven identical.
