# Build 12b on silicon: prompt processing, tok/s against context, and die temperature

Date: 2026-09-21. Card: FK33 holding build 12b (`../bd_wrapper.bit`, sha256
`0349d7c4...`, 75 MHz core, routed WNS +0.046). Image
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27`, verified
251/251 before the runs. Argmax fast path, `--stream`, one position per GO.

## The question

"Before that let's do some quick testing of this bitstream, prompt
processsing, tok/s at context lengths. Temp increase during tok gen"

## The answers, up front

1. **Prompt processing runs at the decode rate.** A v2 card takes ONE
   position per GO (`server/pl_backend.c:524-534` overrides `max_chunk` to 1),
   so a 1,240-id prompt cost **393.9 s of card time, 0.318 s per position,
   3.15 positions/s** (MEASURED, `timing` line minus the 7 decode GOs).
   Two repeats: `run_chunk` 396.297 s and 396.298 s, a spread of 0.0003%.
2. **Decode throughput falls linearly with position**, MEASURED over one
   2,048-token generation with every token timestamped on the host:

   | positions | tokens | s/token | tok/s |
   |---|---:|---:|---:|
   | 37-128 | 91 | 0.2993 | 3.34 |
   | 128-256 | 128 | 0.3041 | 3.29 |
   | 256-512 | 256 | 0.3105 | 3.22 |
   | 512-1024 | 512 | 0.3248 | 3.08 |
   | 1024-1536 | 512 | 0.3441 | 2.91 |
   | 1536-2084 | 548 | 0.3637 | 2.75 |

   Least-squares over all 2,047 intervals:
   `interval = 0.2963 s + 37.28 us * p`, i.e. **22,221,894 + 2,796.2 cycles
   per position at 75 MHz**, residual rms 3.9 ms. The slope reproduces the
   2026-09-20 seam-counter figure (2,793.4) to 0.1%. The intercept does not:
   see section 4.
3. **No measurable die-temperature rise.** SYSMON polled every 15 s over
   PCIe MMIO: idle mean 41.0 C (13 samples, 39.8-42.2), during the 11.6-minute
   generation mean 41.0 C (47 samples, 39.7-42.0). The seam's continuous
   peak-hold read 44.3 C after the 2048-token run and 42.3 C after the two
   prefill runs; VCCINT 0.7156 V throughout. Any rise is below the sensor's
   +/-1.2 C sample-to-sample scatter.

## Procedure

1. `fk33ctl.py thermal --clear-peak`; start `poll_temp.sh` (SYSMON read every
   15 s, read-only MMIO at the SYSMON window, disjoint from the seam).
2. `chat_nostop.sh` = `fk33_chat.sh` with `--stop -1` appended, so the
   end-of-turn token does not end the run. Prompt: "Write a long, detailed
   essay on the history of power electronics..." (37 ids after the chat
   template), `--max-new 2048`. stdout through `tstamp.py`, which records the
   monotonic time of every `read(2)` on the pipe; run_prompt does an
   `fflush` per token so one read is one token piece.
3. `analyze.py`: token k's interval is attributed to the position of the GO
   that produced it (`n_prompt + k - 1`), binned and fitted. Prefill time is
   the first token's timestamp minus the banner's (includes ~0.3 s of host
   setup; the `timing` line is used for the quoted figure).
4. `run_prefill.sh`: the 1,014-word prompt in `longprompt.txt` (1,240 ids),
   `--max-new 8`, twice.
5. `fk33_step_profile.py` against the same `token.dtbl` as the chat (`cmp`
   identical), one GO at position 0, for the opcode partition of the
   intercept.

## Evidence (raw)

2048-token run, `timing` line:
```
decode     2048 ids generated, pos 2084, stopped at --max-new
timing     2084 GOs: run_chunk 694.716 s (of which STATUS wait 694.707 s over 6442342 polls), X pushes 3.690 s, wall since start 698.451 s
```
Prefill runs:
```
prefill    1240 ids, pos 1240, first argmax 32, exp 15
decode     8 ids generated, pos 1247, stopped at --max-new
timing     1247 GOs: run_chunk 396.297 s (...), X pushes 1.725 s, wall since start 398.058 s   (run 1)
timing     1247 GOs: run_chunk 396.298 s (...), X pushes 1.367 s, wall since start 397.699 s   (run 2)
```
First-token timestamps: 395.913 s (run 1), 395.555 s (run 2); decode intervals
after the prompt 0.342 s at p ~ 1240, against the fit's 0.3426 s.

Seam counter after run 2 (`fk33ctl.py seam`): `last job seq_pos 1247 cycles
25516994` = 0.3402 s at 75 MHz, against the wall-clock fit's 0.3428 s at
p = 1246. So the counter is on the 75 MHz core clock and the wall clock carries
about 0.8% of host overhead.

Position-0 step profile (`profile_p0.txt`, 505 of 505 transitions seen):
```
opcode          12b p=0     2026-09-20 build 9 p=0     delta
A_JOB        10,889,703     10,890,053                 -350
B_JOB         7,781,075     15,854,364          -8,073,289
VEC_SWG       1,967,136      1,967,136                    0
VEC_NORM        736,840        736,840                    0
C_JOB           654,588        594,472              +60,116
VEC_RES          67,712         67,712                    0
TOTAL        22,101,743     30,115,217          -8,013,474
```
(Two further rows of 4,655 and 0 cycles are the listing's header lines
mis-parsed as steps and are not opcodes.)

## 4. The recorded cycle model's intercept does not describe build 12b

`docs/LEVERBOARD.md` section 3 carries `token_cycles(p) = 30,115,217 +
2,793.4 p` from a build-9 profile. On build 12b the slope holds (2,796.2 from
wall time, and C's per-position cost is unchanged) but the intercept is
**22.10 M (seam counter) / 22.22 M (wall fit)**, and the whole 8.0 M
difference is **B_JOB: 324 k cycles per B job against the recorded 660 k.**
Every other opcode agrees to the cycle (A within 350; the three VEC classes
exactly).

The partition at p = 0 for the SHIPPING build is therefore:

| opcode | cycles | share |
|---|---:|---:|
| A_JOB | 10,889,703 | 49.3% |
| B_JOB | 7,781,075 | 35.2% |
| VEC_SWG | 1,967,136 | 8.9% |
| VEC_NORM | 736,840 | 3.3% |
| C_JOB | 654,588 | 3.0% |
| VEC_RES | 67,712 | 0.3% |

**A is the largest opcode on the card, not B.** The lever ranking in
LEVERBOARD that puts `B_RECUR_LANES=16` ahead was computed against B at 52.6%.

**NOT determined, and not attributed here:** why B_JOB halved between the
2026-09-20 profile and 12b. 12b has every lever OFF, so it is not a lever. It
is either a change to B's RTL or constants path between that bitstream's
commit and 3e344a2, or a difference in what the 09-20 profile measured. The
discriminator is a step profile of the 09-20 bitstream
(`hw/fk33/bit/fk33_card_kvreg_75mhz_2026-09-20.bit`) at the same image, which
costs a reload and one token; and `git log <that commit>..3e344a2 -- rtl/gdn*
rtl/b_*`.

## Measured and REJECTED, do not retry

- **Reading prefill time from the first-token timestamp alone.** It is
  395.9 s against 393.9 s of card time: the 2 s is the arena load, GDN state
  zero and program stream that `fk33_chat.sh` runs before `run_prompt`.
  Quote the `timing` line's `run_chunk` minus the decode GOs.
- **Treating the 15 s SYSMON poll as the peak.** Polled max 42.0 C, peak-hold
  44.3 C over the same window; the sensor's transients are shorter than 15 s.
  The peak-hold register is the instrument for "did it get hot"; the poll is
  the instrument for "how hot on average".
- **Using `fk33_chat.sh` as-is for a long generation.** It stops on
  `<|im_end|>`; a 2,048-token sweep needs `--stop -1`, which the wrapper does
  not pass through.

## Measurement traps hit

- run_prompt's banner (`embedding`, `program`, `release`, `transport` lines)
  is block-buffered into the pipe and arrives in the SAME read as the first
  token piece (a 923-byte read at 395.9 s). `tstamp.py` measures flushes, not
  prints; the banner's timestamp is meaningless and the first token's is
  right.
- The step listing's two header lines parse as steps `of` and `?` in the
  opcode sum; 4,655 cycles, ignore them.

## Open

- Why B_JOB is 324 k per job on 12b against 660 k recorded (above).
- C_JOB at p = 0 is +60 k (10%) over the 09-20 figure; the prompt token
  differs, and whether C's p = 0 cost depends on the token is not known.
- Die-temperature rise is bounded below the sensor scatter; a longer run or a
  direct power measurement at the slot would be needed to see a rise at all.
