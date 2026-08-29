# Porting the Qwen3.5 tokenizer to C, and verifying the port

Date: 2026-08-28
Hardware/build: no hardware. Workstation only, `gcc 11.4.0`, `aarch64-linux-gnu-gcc`.
Model: `/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf`.
Oracle: `~/GitHub/llama.cpp.upstream` at `1692f9e50bb20fd96b963af38a282daf78feea64`,
`libllama.so.0.0.9820`, reached through `tools/tok_oracle_batch.cpp`.

Companion to `docs/debugging/2026-08-28_qwen35-tokenizer.md`, which covers the
Python implementation and the GGUF extraction. This file covers only the C
port and its verification. It also **CORRECTS** two claims in that file; see
section 8.

## 1. The question, verbatim

> `server/llama_server.cpp` is zero-dependency C++ and cannot link Python. Port
> the tokenizer to C or C++ so the server can use it, and verify the port to the
> same standard.
>
> Port the `llamacpp` state-machine backend, NOT the `regex` one. Unicode
> category tables for `\p{L}\p{M}\p{N}` and `White_Space` must be generated from
> the **same UCD as the oracle**, or the skew returns.
>
> Verify against llama.cpp, not against the Python. [...] Teeth-check the C
> independently. [...] Any mismatch is a finding to report, not to work around.

## 2. The answer

`server/qwen35_tok.c` (C99, libc only, 977 lines) plus the generated
`server/qwen35_unicode_data.c` agrees with llama.cpp **bit-exactly on all four
checks, 0 mismatches**:

| check | items | mismatches |
|---|---|---|
| corpus, encode | 53,409 strings | **0** |
| corpus, decode (on the ORACLE's ids) | 53,409 strings | **0** |
| every token id decoded individually | 248,320 ids | **0** |
| exhaustive codepoint sweep, 2 contexts | 1,112,064 cpts / 2,224,128 strings | **0** |
| malformed-UTF-8 byte fuzz | 20,051 byte strings | **0** |

Seven mutations were applied to the C; **all seven fail the comparison**, six on
the corpus and the seventh only on the all-ids check (section 5).

The Unicode-version trap was avoided by **not deriving the tables at all**:
`tools/gen_tokenizer_unicode_tables.py` parses them out of the oracle's own
`src/unicode-data.cpp`. Provenance by copying, not by agreement.

**Two findings that are not "the port works":**

1. **The Python tokenizer is WRONG on 243 of 248,320 token ids** and the C is
   right. `token_type == 5` is `UNUSED`, not `BYTE` (`BYTE` is 6). Those 243 are
   the `[PADnnnnnn]` filler at the tail of the vocabulary; llama.cpp decodes
   them to the **empty string**, the Python decodes them to their literal text.
   Section 8.1.
2. **llama.cpp aborts on some malformed UTF-8.** Four bytes `F4 BF BF BF` decode
   to U+13FFFF in `unicode_cpt_from_utf8` (which applies no upper bound) and the
   very next call, `unicode_cpt_to_utf8`, throws `std::invalid_argument` with
   nothing on the path catching it. The oracle process dies with SIGABRT.
   Section 8.2.

## 3. The procedure, in the order it was run

Each step names what it controls for.

1. **Read the oracle's source for every stage before writing any C**:
   `unicode_regex_split_custom_qwen35`, `unicode_cpt_flags_array`,
   `unicode_byte_to_utf8_map`, `unicode_cpt_from_utf8`,
   `llm_tokenizer_bpe_session::tokenize`, `llm_bigram_bpe::comparator`,
   `tokenizer_st_partition`, `token_to_piece`, `detokenize`. Controls for
   "am I porting the Python's reading of llama.cpp, or llama.cpp".
   This is what turned up `escape_whitespaces = false`, `clean_spaces = false`,
   `ignore_merges = false` for `qwen35`, and the `UNUSED`/`BYTE` numbering.
2. **Generate the Unicode tables from `src/unicode-data.cpp`**, the translation
   unit compiled into the `libllama.so` the oracle links. Controls for the
   4,704-codepoint UCD skew that cost the Python a rewrite: there is no second
   copy of the data to drift from.
3. **Write the C, then build it with `-Wall -Wextra` under BOTH toolchains**
   (`gcc` and `aarch64-linux-gnu-gcc`). Controls for "it happens to work on the
   dev box"; the server's shipping build is a static aarch64 cross-build.
4. **Build a batch driver, `tools/tokenizer_c_batch.c`, speaking the oracle's
   exact wire protocol.** Controls for harness asymmetry: the same Python
   function packs both payloads and unpacks both replies, so a bug in the
   harness cannot favour one side. It also carries raw bytes, so the empty
   string, embedded NULs and malformed UTF-8 are all expressible.
5. **Corpus comparison, both directions**, reusing `build_corpus()` from
   `tools/verify_tokenizer.py` by import rather than by copy. Decode is compared
   on the **oracle's** ids, never on ours.
6. **Decode every token id.** Controls for the corpus being reachability-limited:
   a corpus can only produce ids that some corpus string encodes to. This is
   what found the Python's UNUSED bug.
7. **Exhaustive codepoint sweep**, the same one the Python run used. Controls
   for the corpus being a sample of an enumerable input class.
8. **Malformed-byte fuzz.** Controls for the fact that every earlier check, in
   both runs, carried valid UTF-8 only.
9. **Seven mutations.** Controls for "the checker can fail". Deliberately NOT
   the Python's set: two of those are documented as structurally unobservable.

## 4. The evidence

### 4.1 The four checks, verbatim

```
$ python3 tools/verify_tokenizer_c.py --build --n-random 40000
+ cc -O2 -std=c99 -Wall -Wextra -DQWEN35_TOK_MUTATE tools/tokenizer_c_batch.c \
    server/qwen35_tok.c server/qwen35_unicode_data.c -Iserver \
    -o build_artifacts_tok/tokenizer_c_batch
corpus            : 53409 strings, 2502602 UTF-8 bytes
encode compared   : 53409
encode mismatches : 0
decode compared   : 53409
decode mismatches : 0

RESULT: PASS (0 mismatches over 53409 strings x 2 directions)

$ python3 tools/verify_tokenizer_c.py --all-ids
token ids compared: 248320
mismatches        : 0
RESULT: PASS

$ python3 tools/verify_tokenizer_c.py --fuzz-bytes
byte strings      : 20051
mismatches        : 0
RESULT: PASS

$ python3 tools/verify_tokenizer_c.py --sweep-codepoints
  ..1112064/1112064 divergent so far: 0
codepoints swept  : 1112064  (x2 contexts = 2224128 strings)
divergent         : 0
RESULT: PASS
```

Wall times, MEASURED: corpus 3.5 s, all-ids 1.0 s, fuzz 1.1 s, sweep 10.8 s.
The whole verification is 17 s, so there is no excuse for not re-running it.

**Note the corpus is 53,409 strings here and 53,411 in the Python run.** It is
not a different corpus: `build_corpus()` samples 40 random files from
`rtl/ ref/ tools/ docs/ server/`, and this track ADDED files to `tools/` and
`server/`, which changes the sample. Same seed, same generator, different repo.
Do not read the two-string difference as a coverage gap; do not read matching
counts across runs as proof the corpora are identical either.

### 4.2 Table strategy and what it costs, MEASURED

`tools/gen_tokenizer_unicode_tables.py` parses three initialiser lists out of
`~/GitHub/llama.cpp.upstream/src/unicode-data.cpp`:

```
$ python3 tools/gen_tokenizer_unicode_tables.py
ranges     : 2273
whitespace : 25
lowercase  : 1433
wrote server/qwen35_unicode_data.c  82196 bytes
```

| item | MEASURED |
|---|---|
| generated C source | 82,196 bytes, committed |
| `qwen35_unicode_data.o` text (x86-64) | 25,352 bytes |
| `qwen35_tok.o` text (x86-64) | 13,307 bytes |
| `qwen35_unicode_data.o` text (aarch64) | 25,224 bytes |
| `qwen35_tok.o` text (aarch64) | 12,538 bytes |
| `llama_server` linked WITHOUT the tokenizer | 151,144 bytes |
| `llama_server` linked WITH both objects | 193,848 bytes |
| delta | **+42,704 bytes, +28.3%** |

The alternative, a flat 0x110000-entry lookup, would be 1.1 MB of `.rodata` and
was not used. 2,273 ranges is 11 binary-search steps.

Dependencies added: **none**. `stdio.h`, `stdlib.h`, `string.h`, `stdint.h`,
`limits.h`, `stddef.h`. No C++, no exceptions, no allocator assumptions. The
`-static` aarch64 cross-build compiles it with `-Wall -Wextra` clean.

### 4.3 How the server calls it

`server/qwen35_tok.h`. Nothing in `server/llama_server.cpp` calls it yet, and
that is deliberate: that server serves the fixed-point stories260K model with
its own `tok512` vocabulary, and the Qwen3.5 `/v1/chat/completions` seam is
blocked on the descriptor format. `server/Makefile` gains `make tok` and
`make tok-board` targets that are NOT dependencies of `llama_server` or
`board`, so the existing build is byte-for-byte unchanged.

```c
qwen35_tok *tk = qwen35_tok_open("build_artifacts_tok/qwen35_9b.qtk");
int n = qwen35_tok_encode(tk, prompt, strlen(prompt), ids, max, /*parse_special*/1);
int m = qwen35_tok_piece(tk, id, buf, sizeof buf, /*render_special*/1);
```

Negative returns are `-(items needed)`; `QWEN35_TOK_ERR` (`INT_MIN`) is
allocation failure, kept distinct because `-1` is a legitimate "needs 1 slot".
Thread-safe: the tables are read-only after open and every scratch buffer is
per call.

**The chat-template warning is in `qwen35_tok.h`'s header comment, at the top,
where a server author will hit it before the API.** The one that matters:
`add_generation_prompt` emits `<|im_start|>assistant\n` **and then always** a
thinking preamble, `<think>\n` when thinking is enabled and
`<think>\n\n</think>\n\n` otherwise **including when the flag is absent**. A
server appending only `<|im_start|>assistant\n` is off-distribution on every
request. Not implemented here; only made unmissable.

## 5. Teeth-check: seven mutations, seven bite

`server/qwen35_tok.c` carries the mutation hooks behind `-DQWEN35_TOK_MUTATE`,
so the shipping objects cannot be perturbed. Driven by
`verify_tokenizer_c.py --mutate NAME`. **None of these is one of the Python's**;
in particular neither of the two rank perturbations documented as toothless in
the companion file was reused.

| mutation | what it breaks | corpus | all-ids | verdict |
|---|---|---|---|---|
| `merge-rank` | demotes the merge `(U+0120,'t')` (byte 0x20 then `t`) to last | **194 encode** | -- | FAIL, correct |
| `byte-map` | GPT-2 byte map: 0x20 encodes as 0x21's character | **799 encode** | -- | FAIL, correct |
| `drop-special` | forgets `<|im_start|>` is special | **50 encode** | -- | FAIL, correct |
| `mark-flag` | clears `\p{M}` for every codepoint (the qwen35-vs-qwen2 difference) | **33 encode** | -- | FAIL, correct |
| `ws-table` | forgets U+00A0 is `White_Space` | **15 encode** | -- | FAIL, correct |
| `decode-bytemap` | inverse map: U+0120 decodes to 0x21 | **799 decode** | 105,490 | FAIL, correct |
| `decode-unused` | renders `UNUSED` tokens as their literal text | 0 | **243** | FAIL, correct |

The last row is the interesting one. On the corpus it PASSES with 0 mismatches,
because no corpus string can produce a `[PADnnnnnn]` id. It fails only under
`--all-ids`. Had `--all-ids` not been written, this mutation would have looked
like another structurally-unobservable one, and the Python's identical real bug
would still be there. **A mutation that passes is a statement about the check,
not about the code.**

Verbatim, the two most informative:

```
MUTATION: Unicode table: \p{M} cleared for every codepoint
encode mismatches : 33
  [121] text=b'e\xcc\x81 a\xcc\x80\xcc\x81 n\xcc\x83 ... \xe0\xa4\x95\xe0\xa5\x8d\xe0\xa4\xb7 ...'
       ours  =[68, 52033, 264, 93213, 52033, 307, 136, 225, 296, 136, 230, 136, 226, 46215, 157451, 156644, ...]
       oracle=[68, 52033, 264, 93213, 52033, 307, 136, 225, 296, 136, 230, 136, 226, 165216, 156644, ...]
RESULT: FAIL (33 mismatches over 2644 strings x 2 directions)
```

```
MUTATION: decoder renders UNUSED (token_type 5) tokens as their literal text
  (corpus)  decode mismatches : 0        RESULT: PASS
  (all-ids) mismatches        : 243      RESULT: FAIL
  id 248077  ours=b'[PAD248077]'  oracle=b''
  id 248078  ours=b'[PAD248078]'  oracle=b''
  ... 241 more
```

All mutations were reverted (they are runtime flags, default 0, and the final
numbers in 4.1 come from an unmutated rebuild).

## 6. Measured and REJECTED -- do not retry

### 6.1 Do NOT regenerate the Unicode tables from a UCD download

**Do not retry.** llama.cpp's `scripts/gen-unicode-data.py` fetches
`https://www.unicode.org/Public/UCD/latest/ucd/UnicodeData.txt` **at generation
time**. "The same UCD as the oracle" is therefore not a version number you can
write down; it is whatever was current when that checkout's `unicode-data.cpp`
was generated. Downloading "latest" today gives a different table and
reintroduces exactly the skew that cost the Python 4,704 codepoints. The
generator here parses the C++ initialiser lists instead and asserts the same
invariants `unicode_cpt_flags_array()` asserts (starts at 0, ends at 0x110000,
strictly ascending, lowercase map sorted for its binary search). If llama.cpp
ever reshapes that file the parse fails loudly rather than silently emitting
less.

### 6.2 Do NOT reproduce the lowercase/uppercase/NFD flag bits

Measured as unnecessary and deliberately omitted.
`unicode_regex_split_custom_qwen35` reads only `is_number`, `is_letter`,
`is_accent_mark`, `is_whitespace` and `as_uint() != 0`, and `as_uint()` is
already non-zero for every in-range codepoint because `Cn` maps to
`UNDEFINED = 0x0001`. Reproducing them would need the uppercase map and the NFD
ranges for no behavioural difference. The claim is not taken on trust: the
exhaustive 1,112,064-codepoint sweep is what proves it.

### 6.3 Do NOT use the Python as the oracle

The C matches llama.cpp on all 248,320 ids. The Python does not (243
mismatches). Had the C been checked against the Python, the "port" would have
been graded correct only by reproducing the Python's bug.

### 6.4 Do NOT compare the merged text by storing the bigram's string

llama.cpp's stale-entry check is `left_token + right_token != bigram.text`.
The C stores only the total length and compares `S[l].n + S[r].n != bg.size`.
This is equivalent, not an approximation: a word's symbols are contiguous and a
symbol's start offset never moves, so equal left index plus equal total length
means the identical byte range, hence the identical string. Storing the string
would allocate per queue entry for nothing.

## 7. Measurement traps hit

* **A function-like macro that names its argument twice, called with `++pos`.**
  The single real bug in this port. The C++ calls `_get_flags(pos+1)` *and*
  `_get_flags(++pos)`; transcribing `_get_flags` as
  `#define GET_FLAGS(i) ((i) < n ? cpt_flags(cp[i]) : 0)` makes the second form
  increment `pos` twice. The visible symptom was `", w"` splitting as `", "` +
  `"w"` instead of `","` + `" w"`, i.e. a punctuation run that swallowed the
  following space. It survived every single-token smoke test (`" world"` alone
  is correct) and only appeared when punctuation preceded the space. The
  accessors are now functions and carry a comment saying why. **Do not
  re-macro them.**
* **A smoke test that passes is not a subset of a corpus that passes.**
  `" world"`, `"world"`, `" w"`, `" the"` all encoded correctly while
  `"Hello, world"` did not. Anything that only exercises a construct in
  isolation cannot see a state-machine bug in the transition into it.
* **The corpus cannot reach every token id.** 243 ids in this vocabulary are
  unreachable from any input text, and a sampler can still emit them. Corpus
  size does not fix reachability; enumeration does.
* **Every check in the companion file carried valid UTF-8**, because the harness
  carried Python `str`. The byte-level protocol here was a precondition for
  testing anything else, not a nicety.
* **`make clean` in `server/` deletes prebuilt binaries that are gitignored, not
  tracked.** They are not recoverable with `git checkout`. Rebuild them.
* **`git checkout -- .` run from inside `server/` reverts the Makefile you just
  edited.** It did, once, here.

## 8. CORRECTIONS to `docs/debugging/2026-08-28_qwen35-tokenizer.md`

### 8.1 CORRECTION (2026-08-28): "243 BYTE tokens" is wrong; they are UNUSED

That file's section 4.1 says:

> Note there are only **243** BYTE tokens, not 256: 13 of the byte-mapped
> characters also appear as NORMAL tokens and carry that type instead. The
> decoder must therefore not key on type BYTE [...]

**Withdrawn.** The reasoning is wrong and so is the conclusion, though the
Python's corpus results are unaffected. `tools/extract_tokenizer.py`'s
`TOKEN_TYPE` table maps `5: "BYTE", 6: "UNUSED"`. llama.cpp's
`llama_token_type` is the other way round: `5 = LLAMA_TOKEN_TYPE_UNUSED`,
`6 = LLAMA_TOKEN_TYPE_BYTE`. The 243 tokens with `token_type == 5` are ids
248,077..248,319 and their text is `[PAD248077]` ... `[PAD248319]` -- vocabulary
padding, not byte-map characters. This vocabulary has **zero** BYTE tokens.

Consequence, MEASURED against the oracle:

```
python vs llama.cpp over all 248320 ids: mismatches = 243
  id 248077 python= b'[PAD248077]' oracle= b''
  token_type values of the mismatching ids: [5]
  id range: 248077 .. 248319
```

llama.cpp's `token_to_piece` ladder is special -> user-defined -> NORMAL ->
BYTE; `UNUSED` matches none of them, falls out of the switch and returns 0
bytes. The Python's `piece_bytes()` treats anything that is not 2/3/4 as
"NORMAL or BYTE alike" and byte-map-decodes it, which for `[PAD248077]` happens
to succeed and yields the literal text.

The C does it correctly. The Python is **not** fixed here: `tools/` Python is
shared with the other track's verification runs and changing its decode
behaviour mid-flight would invalidate that file's numbers. It is recorded as an
open issue below.

Note the practical severity is low but non-zero: those ids never come out of
`encode`, but a sampler can select any id in `[0, n_vocab)`, and a server that
rendered `[PAD248077]` into a user-visible stream would be emitting text
llama.cpp does not.

### 8.2 NEW: llama.cpp aborts on some malformed UTF-8

Not a correction, an addition to that file's "Invalid UTF-8 input was not
tested" open item. It is now tested, and the answer includes an oracle defect.

`unicode_cpt_from_utf8` masks a 4-byte lead with `0x07` and applies **no upper
bound**, so `F4 BF BF BF` decodes to U+13FFFF. `unicode_regex_split` then calls
`unicode_cpt_to_utf8` on it, which throws `std::invalid_argument("invalid
codepoint")`, and nothing between there and `llama_tokenize` catches it:

```
terminate called after throwing an instance of 'std::invalid_argument'
  what():  invalid codepoint
build_artifacts_tok/tok_oracle_batch exited -6
```

Lead bytes `0xF0..0xFF` are therefore excluded from the random fuzz pool: there
is no oracle answer to compare against. The C does not abort; it emits the
4-byte encoding. That divergence is documented in `qwen35_tok.c` at
`cpt_to_utf8`. **It is untested by construction and remains untested.** A server
taking JSON will not see it, because a JSON parser rejects those bytes first.

## 9. Open, not yet answered

* **The Python decoder is wrong on 243 ids and was deliberately not fixed here**
  (8.1). Fixing it is a one-line change in `qwen35_tokenizer.py::piece_bytes`
  plus the label swap in `extract_tokenizer.py::TOKEN_TYPE`, but it belongs with
  a re-run of that file's numbers, not with this one.
* **`parse_special = false` is implemented and NOT compared.** Same gap as the
  Python. `tokenizer_c_batch` accepts `--no-parse-special` and the oracle does
  too; nothing drives them.
* **`add_special = true` is not implemented at all.** `qwen35_tok_encode`
  prepends nothing. Resolved `add_bos` is false for this vocabulary so it would
  be a no-op, but the API has no flag for it and no test.
* **The special-token tie-break is unproven.** llama.cpp sorts
  `cache_special_tokens` with `std::sort` on text length alone, which is
  unstable; the C breaks the tie on id. For it to matter, two equal-length
  specials would have to claim overlapping positions in one string. No corpus
  string distinguished them and no argument here rules it out.
* **`LSTRIP` / `RSTRIP` special-token attributes are not implemented.**
  llama.cpp sets them only for jina / phi-3 / modern-bert by model name, so this
  vocabulary cannot have them, but the C would ignore them if a future GGUF did.
* **Malformed input above U+10FFFF is untestable against this oracle** (8.2).
* **Only this one GGUF.** The `mmproj-BF16.gguf` alongside it was not looked at,
  and no other `pre` type is supported: `qwen35_tok_open` refuses anything that
  is not `gpt2`/`qwen35`.
* **The chat template is still not rendered anywhere**, in any language. That is
  the remaining blocker for `/v1/chat/completions`, together with the descriptor
  format.
* **Performance was not measured.** The whole corpus (2.5 MB) encodes inside the
  3.5 s wall time of a run that also spawns two processes and loads a 313 MB
  oracle, so it is not obviously slow, but no throughput number was taken.
