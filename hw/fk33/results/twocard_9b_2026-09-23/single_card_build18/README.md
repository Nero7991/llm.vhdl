# Single-card oracle recordings on build 18 (Task 11 step 3, first half), 2026-09-23 06:59 to 07:06

The card holds build 18 (`../../card_build18_2026-09-23/`), the striped seg27 9B image (record
7f9e57e3..., 251 of 251 objects). Three prompts, `--max-new 128`, greedy (the card's own argmax), each
run THREE times (`r0` text and timing only; `r1` and `r2` with `--ids-out` and `--dump-xout`). The ids
files are the reference the two-card run is judged against, via `run_prompt --reference` (which reports
`MATCH` or `FIRST DIVERGENCE at <pos>` on ids, not on detokenized text). `run_pair.sh` is that run,
ready for the day `/dev/xdma1` exists.

| # | prompt (`prompts.txt`, verbatim) | prompt ids | generated | stop | run_chunk (r0/r1/r2) | window exp after the last GO |
|---|---|---|---|---|---|---|
| 1 | What is a DC-DC converter? | 20 | 128 | max-new | 43.705 / 43.705 / 43.705 s | 9 |
| 2 | Explain how a hash table works. | 20 | 128 | max-new | 43.706 / 43.706 / 43.705 s | 8 |
| 3 | Write a short poem about the ocean. | 20 | 70 | stop token at pos 89 | 26.365 / 26.365 / 26.365 s | 8 |

All three prompts tokenize to 20 ids (MEASURED, the `--ids-out` header carries the tokenizer's count) and
all three answers open with id 32 ("A"): a coincidence of the template and the model, not a defect;
the three generated streams differ from their second id on and the texts are what the prompts ask for.

**Determinism, MEASURED:** for every prompt the generated ids of r1 and r2 are byte-identical (`cmp`),
the detokenized text of r0, r1 and r2 is identical (one distinct md5 per prompt), and the 4,096-mantissa
residual window after the last GO is byte-identical between r1 and r2. So the single card is a
deterministic oracle and any divergence the pair shows against these files is the pair's.

**Timing, MEASURED from `tstamp.py`'s per-read monotonic clock (r1):**

| # | prefill 20 positions | decode mean s/token | tok/s | min / max s/token |
|---|---|---|---|---|
| 1 | 6.152 s (0.3076 s/pos) | 0.2988 | 3.347 | 0.2963 / 0.3014 |
| 2 | 6.166 s (0.3083 s/pos) | 0.2988 | 3.347 | 0.2963 / 0.3014 |
| 3 | 6.154 s (0.3077 s/pos) | 0.2977 | 3.359 | 0.2964 / 0.2993 |

This agrees with build 12b's characterisation (`0.2963 s + 37.28 us * position`: 0.3009 s at p=120), so
build 18's KV counters and window change no cycle at these positions, consistent with the 24.578 s
control. The `run_chunk` repeats agree to 1 ms over 43.7 s, the recorded 0.004% floor.

**Trap hit (fixed in a0ccaa0's successor):** the first recording (`r0`) has no ids or window files
because `fk33_chat.sh` runs `set -- $GB` before its `exec`, which replaced the positional parameters, so
`"${@:3}"` at the exec was empty and the pass-through silently did nothing. The scripts now capture
`EXTRA=("${@:3}")` at the top. The `r0` text and timing are valid and are kept as the third repeat.

**What this does NOT establish:** anything about the pair. It establishes what the pair must reproduce.

## Files

`prompts.txt`; per prompt and repeat `p<i>_r<r>.{out,err,ts,start}` and for r1/r2 `.ids` (the reference
format) and `.xout` (`exp E` then 4,096 int16 mantissas of R_X after the last GO); `run_single.sh`,
`run_pair.sh`, `tstamp.py`. Working copies under `/mnt/storage/fk33_builds/build18/oracle/`.
