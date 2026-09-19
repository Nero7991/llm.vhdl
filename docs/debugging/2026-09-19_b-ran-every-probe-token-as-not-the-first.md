# B's Y is wrong on silicon because every probe after the first ran at tok_pos > 0

Date: 2026-09-19. Card: SQRL FK33, bitstream
`hw/fk33/bit/fk33_card_bconst_qkn_75mhz_2026-09-19.bit` (built from 41e1397,
sha256 3ae5f27b..., WNS +0.032), loaded 06:4x by `hw/fk33/host/fk33_reload.sh`.
Model: Qwen3.5-9B INT4 (`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/`),
`gdn_const.bin` blake2b `ec3eda1a...` verified on HBM.

## The question

Bisecting token 0 of the prompt on silicon, steps 0..6 (norm, three qkv jobs,
gate, beta, alpha) match the reference. Step 7 is B. Probing `attn_gate(Y)`
(an appended A job over the Y region) gives argmax **2591** where the reference
Y gives **2131**, and Y's captured block exponent decoded from `logit_exp` is
**10** against the reference **13**. The RTL-fidelity C model
(`ref/gdn_block_cap_vec.c` via `tools/ref9b/gdn_oracle.py --b-const`) at the
9B shape with the real constants image reproduces the reference Y exactly
(exp 13, attn_gate 2131, corr 1.0000). Why is the card's Y wrong when its
inputs, its constants image and the arithmetic model are all right?

## The answer

**The card was not running token 0.** `llama_top`'s `tok_pos` advances on
every `tok_done`/`tok_ack`, i.e. every closed token, and is cleared only by
`rst`, which on the card is `xdma/axi_aresetn` through `core_reset`: only a
reconfiguration. The seam's SEQ_RESET bit (`rtl/fk33_seam.vhd:843`) clears the
SEAM's `cur_pos` and nothing in the engine; `server/tests/run_prompt.c:343`
says so verbatim ("the card's own tok_pos ... is NOT reset by this; only a
reconfiguration does that. Fine for a probe program that never reaches C or
B"). Every `--close-token` probe since the reload advanced `tok_pos`, so every
probe that reached B ran with `b_tk0 = '0'`: the recurrence read the zeroed
HBM state (exponent bytes 0), the update quantiser chose
`e_u = min(se_j + 2, e_kd) = 2`, the real update was shifted right by about
40 bits, and the new state landed as mantissas 0/-1 at exponent 2. Y computed
from that state is the observed (exp 10, argmax 2591).

There is no B defect. The store, constants, taps and exponents at 9B are right
(the 9B `tb_gdn_state_store` bench with `CONST_EN` passed 845,379 checks in
the same hour). The defect is that the card has NO per-sequence reset short
of reprogramming, which is also a gap for real inference: a host cannot start
a second prompt.

## The procedure

1. **Read the layer-0 GDN state back from HBM after a B-only program.**
   `gen_layer_program.py --upto 8 --close-token` (steps 0..7, B last),
   `fk33ctl.dma_read(0x10c006000, 0x10d000)` (manifest `gdn_state_base`,
   layer 0: 1 MiB mantissas, 4 KiB exponents, 48 KiB conv taps). This is the
   only direct view of B's internals the card offers, and it needed no RTL.
2. **Control the state between runs.** The first readback showed conv tap
   slots 0 AND 2 holding the token's column: leftovers from earlier probe
   runs, because nothing re-zeroed the state. Zeroed the whole `gdn_state`
   region (`fk33ctl.py load <zeros> --offset 0x10c006000 --verify`, PASS
   26,443,776 bytes), re-ran: exactly one slot written. Then re-ran the
   `attn_gate(Y)` probe on the zeroed state: still 2591. So pollution was
   real but NOT the cause (at tk0 the RTL masks the old state and the old
   taps anyway).
3. **Compare the tap column against the reference qkv.** corr 0.9993 /
   0.9994 / 0.9998 for q / k / v. B's input is right; that agrees with steps
   1..3 having matched.
4. **Dump the model's post-token S** (scratch copy of
   `ref/gdn_block_cap_vec.c` with a `GDN_STATE_DUMP` env var, nothing in the
   repo changed) and compare with the card's S.
5. **Force the model to `tk0 = 0`** (`GDN_FORCE_TK0=0` in the scratch copy)
   with the same zero state and compare again.

## The evidence

Card readback, zeroed state, one B run (`state_l0_tok0_clean.bin`):

```
mant nonzero 177757 of 524288 absmax 12
exp unique [2] count 1
conv tap 0 nonzero 0 absmax 0
conv tap 1 nonzero 8188 absmax 22018
conv tap 2 nonzero 0 absmax 0
card mant hist: -1 x 177371, 0 x 346531, everything else < 200 entries
```

Model, `tk0 = 1` (the real token 0):

```
model Y exp 13
model S: absmax 32703 nonzero 393828 exp unique [12 .. 32, 42]
```

Model, `tk0` forced to 0, zero loaded state:

```
tk0 forced 0: model Y exp 10
  attn_gate(Y): top0 row 2591 y 118417 | top1 row 1587 y 113728
  model S: absmax 17 exp unique [2]
  card vs model S mantissas: identical 507460 of 524288
```

The card: Y exp 10, attn_gate argmax 2591. Three independent quantities
(Y exponent, attn_gate argmax, the S image) all match the `tk0 = 0` model and
none match the `tk0 = 1` model.

Where the mechanism lives (`ref/gdn_block_vec.c` stage 4, the RTL's
`gdn_recur_pipe` is its source): `e_u = masked ? e_kd : min(se_j + 2, e_kd)`,
`sk2 = e_kd - e_u`, `u[i] = floor_shr(w18[i], su) + floor_shr(k*d, sk2)`,
`se_new = e_u - sh`. With `se_j = 0` and `masked = 0`, `e_u = 2`, `sk2` is
about 43, and `floor_shr` of a negative product is -1.

The 9B store bench (`sim/tb_gdn_state_store.vhd`, VAL_HEADS 32, DIM 128,
LAYERS 2, NTOK 4, AXI_DW 256, CONST_EN true):

```
tb_gdn_state_store RESULT: PASS -- 845379 checks, of which 24576 exponents
and 16384 conv tap groups (4096 with a full history) and 16384 conv weight
groups + 1584 scalars; ... the constants region was never written.
rc=0
```

## Measured and REJECTED -- do not retry

- **Conv exponent triple wrong.** Full sweep of `cw_exp` for q/k/v over
  8..19 in the model, target (Y exp 10, argmax 2591): `hits []`.
- **Stand-in constants, const without B_SRC_REAL, zero weights, layer-1
  block, dt/a swapped, stand-in exponents, zero dt/a, norm=1, channel-major
  weights, taps reversed, cw_exp +-3:** argmaxes 1248 / 4053 / 0 / 1552 /
  2131 / 610 / 2131 / 2131 / 4024 / 17 / 2547, 1451. None is 2591.
- **State pollution from earlier probe runs.** Real (two tap slots held the
  same column) and irrelevant at tk0; the zeroed-state rerun gave the same
  2591.
- **The store at 9B / the constants decode at 9B.** 845,379-check PASS.
- **`ssm_out(Y)` as a discriminator.** Its argmax is 3994 for nearly any
  input, including `ssm_out(ssm_out(noise))`. Recorded earlier the same
  night; still true.

## Measurement traps hit

- **A stale seam register looked like a result.** After a B-only program
  (last A job = alpha, 32 rows) `fk33ctl.py seam` printed
  `argmax 2591 logit_exp 15`: the last-job argmax register had not been
  updated by that job and still held the previous probe's value. Read
  `tbl_len`/`smp_n`/`steps issued` to identify WHICH run a seam line
  belongs to before quoting its argmax.
- **`run_prompt --seq-reset` prints "seam position cleared" and the seam
  then reports `seq_pos 1`**, both true, both about the seam. Nothing in the
  host output mentions the engine's `tok_pos`, and `obs_tok_pos` reaches the
  seam as a port (`rtl/fk33_seam.vhd:300`) that is mapped to no register, so
  the position B actually used was unobservable from the host. The
  first-token-after-reload had it right and produced argmax 0 / logit exp
  -25 for a reason that is still open.
- **`probe.sh N` silently ran the wrong program once.** `--probe-smp` refuses
  a table whose last kept step is not an A job (exit, no files), the script
  then loaded a NONEXISTENT arena (the `grep -c identical` printed 0) and
  ran `run_prompt` on the previous tag's `.dtbl`. The verdict that came back
  was a real run of a different program. Read the arena-verify count.
- **The model's refusal was right and had to be bypassed deliberately.**
  `gdn_block_cap_vec.c` refuses `tk0 = 0` at token 0 because "a zero state
  here is a plausible wrong answer, not a model." It is exactly the wrong
  answer the card produced. The bypass lives only in a scratch copy.

## What is still open

- The FIRST token after the reload (the only one that ran at `tok_pos = 0`)
  gave argmax 0 with logit exponent -25. That token had B right by this
  analysis, so the next defect is downstream (later layers, attention at C,
  the lm_head windows, or the exponent chain). Not yet bisected, because
  every B-reaching probe now costs a reconfiguration until the fix below is
  built.
- Whether HBM contents survive a reconfiguration (if they do, a reload costs
  2 minutes, not a weight reload). Test: verify `gdn_const` after the next
  reload before loading anything.

## The fix (in flight)

`llama_top` gains a `seq_rst` input that clears `tok_pos` and re-arms the KV
sequence reset; the seam's SEQ_RESET bit drives it; `obs_tok_pos` is exposed
on a read-only seam register so the host can SEE the position B will use.
Host: `pl_seq_reset` already writes the bit. Then a rebuild (about 4h40m at
this design's size, `MemoryHigh=24G`).
