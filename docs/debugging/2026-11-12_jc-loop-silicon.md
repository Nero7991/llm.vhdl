# JC on-fabric loop and die-to-die link on silicon (jccard_loop5)

## 1. The question

Spec `docs/superpowers/specs/2026-11-04-jc-on-fabric-loop-and-link-design.md` section 4, silicon
steps, verbatim:

1. Link alone: 10-minute frame soak on the fitted lane; zero CRC fails, or a measured frame error
   rate.
2. Hop transparency: for positions 0, 3 and 22, die B's X window after the hop is bit-identical to
   die A's R_X read over the host path.
3. Tokens: loop ids = `run_prompt` ids = llama.cpp reference on the 23-id DC-DC prompt, then the
   500-token context test (input and output, twice).
4. Fault injection: wrong RX polarity mid-run gives LINK_BAD and a pause; fixing it plus RESEND
   resumes; same ids at the end.

- Date: 2026-11-12.
- Hardware: Jungle Cat, both VU35P dies, A = layers 0-32, B = layers 33-63, Qwen3.8-27B own-PC
  images (`qwen38-27b-card0-b0-32-ownpc`, `qwen38-27b-card1-b33-63-ownpc`).
- Build: `jccard_loop5`, sha256 `06be2f33b21dfe928b31b815ad0e7e79ab6e7fcf5cff9ed80c2e90b61df12405`
  (`hw/jc/card/results/jccard_loop5_2026-11-11/`), `JC_LINK_REFCLK=gtg JC_LINK_RATE=10.3125`,
  125 MHz, `--impl congestion`, post-route WNS +0.066 ns.
- Spec step 2 positions: the plan's Step 6 runs k = 1, 4 and 23 (1-based prompt lengths), the same
  positions 0, 3 and 22.

## 2. The answers

| Gate | Result | Class |
|---|---|---|
| K1 anchor (loop absent) | `K1_ANCHOR_OK`, argmax 8678, X_OUT byte-identical | MEASURED (run_prompt) |
| GDN masking (plan Step 4) | `GDN_MASK_OK`: stale GDN state after a 23-id run gives the same id (1007) and a byte-identical X_OUT as a clean card | MEASURED |
| 1. Soak | `SOAK_FER 0.000115 frames=69712 crc_fails=8 link_downs=178` over 600 s; zero CRC fails NOT met | MEASURED (jc_link_soak.py) |
| 2. Hop | `HOP_SAME k=1`, `HOP_SAME k=4`, `HOP_SAME k=23` (k=23 with `--resend-max 1000`) | MEASURED (jc_loop.py vs run_prompt) |
| 3a. Tokens | loop ids = run_prompt ids, 16 of 16: 1206 7995 948 10603 12 5449 85831 513 328 55221 1 1056 83871 11 424 369 | MEASURED |
| 3a. llama.cpp agreement | not run here (owned by the card numerics work) | open |
| 3b. Context test | loop: `CTXTEST_PASS` pair and single (500 GOs, ids identical across runs). Host: `CTXTEST_FAIL` pair output_r2 and single output_r1, both a broker WindowUnknown on a window op, not a die error. Pair host ids = loop ids (input 3575; output 485 of 485) | MEASURED (jc_ctxtest.sh) |
| 4. Fault | `FAULT_PAUSED=1 JCLOOP_DONE ids=16`, ids identical to step 3a: FAULT_PASS | MEASURED (jc_loop.py) |

The link works and carries correct data, but die B's receive lane drops (LINK_DOWNS) every 2-4 s
whether or not traffic flows. Each drop costs a RESEND. The loop tolerates it with a raised resend
cap, so the token results are correct and slower than the host path (56.25 s vs 42.19 s wall for
16 tokens; the loop also uses host-supplied rows and a host relay, so this is not a measure of the
on-fabric loop's speed).

## 3. Procedure, in run order, and what each step isolates

1. **Program and load.** Program both dies (`sqrl_bridge`, comma form). Load weights and the side
   image per die with `coe_load`. Verify: `JCVERIFY_PASS 7170 pieces, 0 bad` (A),
   `6750 pieces, 0 bad` (B), and side images `3 pieces, 0 bad` each. Isolates the image from
   everything after it.
2. **LOOP_ID.** Read ID and CAPS on both dies (`loop_id_0.txt`): `0x544c5031`, caps `0x2131400`.
   Proves the loop block is present at `0x20000` in the image that was loaded.
3. **Link status with no reset pulse.** A `ls=0xd` (tx_up, both PLL locks; A has no RX), B
   `ls=0x60f` (tx_up, rx_up, locks). QPLL1 locks from GTGREFCLK. The plan's A4 reset pulse keeps it
   at those values (`reset_pulse.txt`).
4. **K1 anchor.** One-id prompt through the host path, loop absent: isolates the engine and the
   seam mux in the new image.
5. **GDN masking (plan Step 4).** A dirty run (23 ids), then a 5-id run with no rezero, against a
   5-id run on a rezeroed card. Isolates the engine's GDN masking at SEQ_RESET with the loop absent.
6. **Soak (spec step 1).** `jc_link_soak.py --seconds 600`. Die A resends frame 0 continuously;
   die B counts STALE (intact) against CRC_FAILS (corrupted).
7. **Drop probes** (after the soak showed 178 link_downs; section 4.3). Idle, B running with no
   frames, traffic, and paced traffic, 60 s each. They separate traffic-induced drops from
   spontaneous ones.
8. **Hop (spec step 2).** For k in 1, 4, 23: die A's R_X via the host path against die B's X window
   after the hop, same rows and seam on both paths, so a difference can only come from the hop.
9. **Tokens (spec step 3a).** 23-id DC-DC prompt, 16 new tokens, host run (`run_prompt`) as the
   control for the loop run (`jc_loop.py --resend-max 1000`).
10. **Context test (spec step 3b).** `hw/jc/host/jc_ctxtest.sh` pair and single, host and
    `JC_LOOP=1`, N 500, with `JC_LOOP_ARGS="--resend-max 1000"`.
11. **Fault injection (spec step 4).** `jc_loop.py --fault-polarity-at 4` (plan deviation D5: TX
    polarity on A, as the core has no runtime RX polarity).

## 4. Evidence (raw; files under `/mnt/storage/fk33_builds/jccard_loop5/silicon/`)

### 4.1 Soak

```
soak.log:  SOAK_FAIL die B did not take frame 0 (FRAMES_GOOD 0, CRC_FAILS 1)
soak2.log: SOAK_FAIL die A: CTRL RESEND answered WindowUnknown and the read-back does not show it landed; not retried
soak3.log: soak: resends 69712 crc_fails 8 seqpos_bad 69676 link_downs 178 over 600 s (1 RESEND pulses with an unknown outcome)
soak3.log: SOAK_FER 0.000115 frames=69712 crc_fails=8 link_downs=178
```

The first two failures were tool defects, not link results. Frame 0 itself was corrupted, and a
broker reconnect left one RESEND outcome unknown. Both were fixed in `5a8c1ca2` (section 6).

### 4.2 Hop

```
HOP_SAME k=1
HOP_SAME k=4
JCLOOP_FAIL die A stopped LINK_RETRY_EXHAUSTED; reason A=LINK_RETRY_EXHAUSTED B=none ids=0
HOP_DIFF k=23
HOP_SAME k=23
```

The `HOP_DIFF k=23` compares the aborted run's empty output and is not a data difference. The
rerun with `--resend-max 1000` is `HOP_SAME`.

### 4.3 Drop probes (`downs_probe.txt`)

```
IDLE 60s: link_downs 184 -> 211, crc 8 -> 8, B ls 0x70f
B RUNNING, NO FRAMES 60s: link_downs 0 -> 15, B ls 0x50f
TRAFFIC 60s: resends 7606, link_downs 15 -> 29, crc 0 -> 0
PACED 50ms 60s: resends 987, link_downs 29 -> 50, crc 0 -> 0
```

`updown_trace.txt` sampled rx_up at 478.7 ms per pair over 45 s and saw 1 transition. The drops
are much shorter than the sampling period and are seen only through the LINK_DOWNS counter.

DERIVED: 14 to 27 drops per 60 s in every condition, i.e. one every 2.2 to 4.3 s, independent of
traffic. CRC failures did not rise in any probe.

### 4.4 Tokens

```
tok_host.out: timing 38 GOs: run_chunk 39.300 s (of which STATUS wait 18.117 s over 818 polls), X pushes 4.215 s, wall since start 42.187 s
tok_loop.out: jc_loop: die B paused at position 10, RESEND on A   (6 pauses in all)
tok_loop.out: JCLOOP_DONE ids=16 reason=MAX_NEW
tok_loop.err: WALL 56.25 s
```

### 4.5 Context test

`/mnt/storage/fk33_builds/jccard_loop5/ctxtest/*_b.log`:
```
pair_host_b.log:   input: all 2 runs produced identical ids (2 ids)
pair_host_b.log:   CTXTEST_FAIL output_r2: rc 1, GOs '' (want 500), seam error 0.
pair_loop_b.log:   CTXTEST_PASS mode pair dies A B N 500 SHORT repeats 2 tests 'input output': every run reached 500 GOs with no die error, ids identical across runs
single_host_b.log: CTXTEST_FAIL output_r1: rc 1, GOs '' (want 500), seam error 0.
single_loop_b.log: CTXTEST_PASS mode single dies A N 500 SHORT repeats 2 tests 'input output': every run reached 500 GOs with no die error, ids identical across runs
b_n500/output_r2.err:  fk33_transport_jc: die B: WindowUnknown: ... (op 1 at 0xe020): not done after 64 polls, verdict NOTFAILED
b_n500/output_r2.err:  run_prompt: decode 242 returned -2 (no error)
b_n500s/output_r1.err: fk33_transport_jc: die A: WindowUnknown: ... (op 2 at 0xe060): not done after 64 polls, verdict NOTFAILED
b_n500s/output_r1.err: run_prompt: decode 59 returned -2 (no error)
```
Both host failures are the transport refusing to retry a window op whose outcome it could not
confirm, not a die error. The waiter's `cmp` reported DIFF for every pair because the host
`.ids` files start with a `# run_prompt:` comment line. By content, `b_n500` and `b_n500_loop`
agree: input id 3575, output 485 of 485 ids, 0 differences. The single-die host output run
failed, so that comparison has no host side.

### 4.6 Fault injection

Run from the BC-250 against the QUICKACK broker (section 8), `flt_loop.out`:
```
jc_loop: fault: TX polarity inverted on A; B paused=1 crc_fails=3 link_downs=8
FAULT_PAUSED=1 JCLOOP_DONE ids=16 reason=MAX_NEW
```
`cmp bc_loop.ids flt_loop.ids` equal (`IDS_SAME`). The run logged 16 `paused` lines in all: the
fault plus the lane's own drops.

## 5. Measured and REJECTED (do not retry)

- **"The drops are caused by traffic."** Rejected: drops come at the same rate idle (27 per 60 s),
  with B running and no frames (15), under full traffic (14) and paced traffic (21).
- **"Drops corrupt data."** Rejected for the gated outputs: every HOP and IDS comparison is
  identical. A corrupted frame fails CRC, and the RESEND recovers it.

## 6. Measurement traps hit

- The soak tool's first version required frame 0 to arrive intact and treated a WindowUnknown on
  RESEND as fatal. On this link both happen, so it failed for tool reasons (`soak.log`,
  `soak2.log`). Fixed in `5a8c1ca2`: frame 0 is resent while it waits, and an unknown RESEND is
  counted, not fatal, because the accounting reads die A's own RESENDS counter.
- The context-test waiter compared files with `cmp`, and the host `.ids` carry a comment header:
  every comparison read DIFF. Compare ids by content.
- jc_loop's default resend cap (`LINK_RETRY_EXHAUSTED` at k=23) is a policy limit, not a data
  failure. Any comparison against an aborted run reads as DIFF.
- The first context-test launch failed because the worktree had no `build_artifacts_tok/qwen35_9b.qtk`.
  It now runs with `JC_QTK` and `JC_EMBED` set, into the `b_*` directories.
- An rx_up sampler at about 0.5 s misses the drops. Use the LINK_DOWNS counter.

## 7. Open, not yet answered

- **The cause of the link drops.** Hypothesis, NOT tested: die A's simplex TX/RX core has no
  B-to-A lane fitted, so its hot-plug logic sees no CC characters and resets the transceiver it
  shares with TX. Test: fit a B-to-A cap pair, or build die A's core as TX-only, and repeat the
  drop probes. Also unexplained: why B ls shows `0x70f`/`0x50f` in the probes against `0x60f` at
  bring-up.
- **The refclk.** GTGREFCLK is "reserved for internal testing purposes only" (UG578). QPLL1 locks
  and the FER is 1.15e-4, but the link runs outside the supported refclk envelope. Whether the
  drops or the CRC failures come from the refclk is not separated from the hot-plug hypothesis.
- **Gather on silicon.** The HBM address of the 27B embedding image is not grounded, so all
  silicon runs use host rows.
- Phase 2 return link (B to A argmax), lanes beyond 0, the board refclk on die 1.
- llama.cpp agreement, owned by the card numerics work.
- **The next build.** Register `aur_reset_pb`/`pma_init` and set `FAST_POP=true`. The
  `gt_qpllrefclk_quad1_out_1 has no logical paths from master clock o0` warning is not yet
  examined.

## 8. Addendum 2026-11-12 (afternoon): speed, and where the embedding is

- **Broker die switch.** It cost ~207 ms, TCP delayed ACK on the BMC's CMD_TMS replies; full
  record in `2026-11-12_jc-broker-die-switch-delayed-ack.md`. With `TCP_QUICKACK` (`ee825a39`),
  `jc_loop.py` run on the BC-250 does the step 3a run in 19.7 s against 67.0 s, ids identical.
  That is 0.52 s per position, the card's rate. The web UI now drives this loop (`5f63e791`):
  1.43-1.48 tok/s decode measured on short prompts, against 0.75 on the old host path.
- **The embedding is not in HBM** (MEASURED from the manifests). `token_embd.weight` (715,313,152
  bytes) is in `dropped_tensors` on both dies. Die A's free region after GDN state is the KV
  extent, 714,698,752 bytes, 0.6 MB short even with no KV. The KV needs 570 MB at C_MAXPOS
  16384. The own-PC layout leaves 677.6 MB of padding inside the weights region, but it is not
  contiguous. On-chip gather therefore needs a non-contiguous embedding layout (for example a row
  page table in embed_gather) plus a packer that fills the own-PC holes: an RTL change and a build.
  DERIVED: it would save the row push (54 ms) and its handshakes, about 13% of a 0.52 s token.
