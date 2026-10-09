# 2026-10-09: JC broker WindowUnknown after a BMC connection reset (op 3 at 0xe060)

## The question (verbatim, from the brief)

> 3 runs of the same 23-position prefill: run0 succeeded (1184 s), run1 and run2 FAILED with:
> `fk33_transport_jc: die A: WindowUnknown: die A seq N (op 3 at 0xe060): not done after 64 polls,
> verdict NOTFAILED; die A window state is UNKNOWN`
> In both failures the broker's preceding event was a reconnect caused by the BMC dropping the TCP
> connection (ConnectionResetError or TimeoutError). [...] After the UNKNOWN the broker ignored
> SIGINT for 20-30 s (state S, one thread) and had to be SIGTERMed.

Hardware/build: Jungle Cat, 27B two-die images (card0 b0-32 on die A, card1 b33-63 on die B),
broker on the BC-250, `--chain AB`, run_prompt `--jc ... --jc-die A --jc-die2 B --v2`, branch
jc-card. Symptom numbers: run1 failed ~15 min in (broker connection 13, after RECONNECT 12
TimeoutError at 57 s); run2 failed ~2.75 min in (connection 2, after RECONNECT 1
ConnectionResetError at 169 s). Both: `run_prompt: prefill returned -2 for 23 ids`.

## The answer

1. The read frame never executed on die A. The link died on the frame's OWN CoE command, so the
   frame reached the die not at all or only part-shifted (a part slot is abandoned at the next
   Capture-DR and never gets a verdict). An abandoned slot raises neither crc_fail nor desync,
   exactly like a slot that passed, so the ledger calls it NOTFAILED ("passed if it was
   complete; completion unproven") and the broker, correctly by its exactly-once rule, waits for
   completion evidence that cannot come. This is designed behaviour of the broker, not a broker
   bug: it cannot tell "never arrived" from "arrived and queued" from the counters it has.
2. 0xe060 is the seam's WIN_DATA. A WIN_DATA read is NOT side-effect free: it advances WIN_ADDR.
   Every other seam read is. So the broker may not blindly resend it, but the HOST can retry it
   safely by writing WIN_SEL/WIN_ADDR again first (absolute), and can retry any other seam read
   as is. Implemented in server/pl_backend.c (commit below).
3. The SIGINT symptom is unrelated to the UNKNOWN: the broker process had SIGINT ignored from
   birth. hw/jc/host/jc_bc_lane.sh starts it as `nohup python3 ... &` from a non-interactive bash
   (`ssh ... 'bash -s'`), which starts asynchronous commands with SIGINT = SIG_IGN, and Python
   installs its KeyboardInterrupt handler only when SIGINT is SIG_DFL at startup. Fixed in
   jc_broker.main().

## Procedure (what each step isolates)

1. Read the broker's verdict logic: `Broker._xfer` (tools/jc/jc_broker.py:496-525) and
   `_resolve` (:551-584). Isolates what NOTFAILED means: the frame's ledger entry has
   completion unproven (e[3] False) AND the counter rise D fits only "it did not fail".
2. Read the frame core RTL (rtl/jc_ctl_frame_core.vhd) for what a cut slot does at the die:
   Capture-DR (:145-146, :227-231) resets bitcnt/crc/good; a HDR is pushed at bit 255 (:156-172)
   but PASS/FAIL only at bit 16159 (:178-187); desync counts a bad header only, crc_fail a
   complete failed slot only. So a cut or never-sent slot contributes 0 to D.
3. Read the executor (rtl/jc_ctl_exec.vhd) for what would have happened had the frame arrived:
   HDR then PASS required (:367-371); a new HDR discards an open frame (:348-357); a successful
   read publishes rsp_seq/rsp_valid with last_done_seq in one cycle (:553-571) and stays
   presented until acked (:319-322); an errored read sets err_seq (:557-560).
4. Read who can ack: the frame core toggles the ack only for ack_seq == the presented rsp_seq
   (frame_core :189); the broker carries s.ack[die], set only by `_take` (accept, :626) or
   `_discard` (seqs NOT in the current frame's `mine`, :630-637, :734-736, :800-801).
5. Read the transport and host for the address: server/fk33_seam.h:304-306 (WIN_SEL 0x58,
   WIN_ADDR 0x5C, WIN_DATA 0x60, "auto-increments on DATA"); server/pl_backend.c pl_read_xout
   (the only WIN_DATA reader: 5,120 rd32 per hop, one RD_INC frame each).
6. Read the seam RTL read channel (rtl/fk33_seam.vhd:1064-1190) for read side effects.
7. Reproduce on the broker's fake chain (tools/jc/test_jc_broker.py, new tests below), then
   on the host side with a fault-injecting sim broker (server/tests/jc_sim_broker.c `--fail-rd`).
8. For SIGINT: read jc_broker.main()'s shutdown path (:1132-1143, no signal handling at all),
   the launcher (hw/jc/host/jc_bc_lane.sh:84-86, stop_broker :74-81), and MEASURE locally what a
   background python inherits.

## Evidence

### Q1, DERIVED from code (die A is chain position 0, lead 0)

- `_xfer` sets the frame's completion flag only after its own `recv()` returns:
  `e[3] = v.lead == 0` (jc_broker.py:513). If `send()`/`recv()` raises (the link died on that
  command), e[3] stays False. A later slot on the same scan generation would set it True
  (:510-512), but a link loss opens a new generation. So on die A, **NOTFAILED <=> the link
  died on the frame's own command** (a frame whose reply came back is PASSED).
- After the reconnect `_ensure` appends the open filler as exactly one desync (:475), then the
  first good status resolves [frame 0..1, filler 1]. NOTFAILED (not LOST) means D = 1: the
  frame's slot failed no complete slot. NOTFAILED (not AMBIGUOUS) also means ovf did not rise.
- If the frame had reached the die whole with a good CRC, the executor would run the one-item
  AXI-Lite read in microseconds (seam reads are 3 states, fk33_seam.vhd:1067-1188) and present
  rsp_seq = N until acked. Nothing acks N (step 4). The broker reads every poll's rsp_seq
  (`_take`, :614) and consults err_seq for errors (:707). So 64 polls with no evidence rules out
  "executed". No JCBROKER_RSP_COUNT / JCBROKER_RSP_CRC line appears in either broker log, which
  rules out "presented but rejected".
- Remaining: the frame never left the host / never got shifted (BMC already dead), or it was
  part-shifted and abandoned at the reopen's Capture-DR. Both give the same die-side result:
  it never executes. Which of the two happened is NOT determined (and does not matter for the
  fix).

### Q1, reproduced (tools/jc/test_jc_broker.py, new, both pass on the current broker)

- `test_silicon_2026_10_09_a_read_frame_that_never_reached_die_a_is_unknown`: die A, a FIFO
  window at 0xE060 (every execution pops, the WIN_DATA model), the link reset on the RD_INC
  frame's own CMD_TDI before a bit is shifted. Result: `WindowUnknown: ... (op 3 at 0xe060): not
  done after 64 polls, verdict NOTFAILED`, connection 2 reached, the die ran only the earlier
  read, the window did not move. This is the silicon message, byte for byte in its shape.
- `test_silicon_2026_10_09_a_read_frame_whose_reply_was_lost_resumes`: the contrast. Same drop
  point but the command was shifted and only its reply lost. Same verdict, NOTFAILED, yet the
  frame ran, its response is presented on the new connection and the read completes once.
  This is why run0 survived six drops: NOTFAILED is not fatal unless the frame truly never ran.

### Q2, RTL

- rtl/fk33_seam.vhd READ CHANNEL: `rd_wait = 2` builds `rv` from registers and memories; the
  only state written besides rdata/rvalid is, for `roff = A_WIN_DATA` only,
  `r_win_addr <= r_win_addr + 1` and the XOUT prefetch address `xr_addr` (:1174-1183). The
  `rd_wait = 1` desc_q load (:1081-1085) and the AR-time xr_addr (:1071-1076) are read-port
  addresses, not state. No clear-on-read register exists in the case list (:1103-1171).
- XOUT data is `hr_data` from llama_top's host read port (`hr_addr` -> region_mem
  :375-419), a passive register-file read: reading an element twice changes nothing.
- WIN_ADDR writes are absolute (:1016-1021) and re-prime xr_addr in XOUT mode.
- Conclusion: a lost WIN_DATA read is safe to redo after re-writing WIN_SEL and WIN_ADDR; any
  other seam read is safe to redo as is. The executor processes frames strictly in order (one
  FIFO, one frame at a time), so even if the "lost" read did run late, it runs BEFORE the
  re-seek write, and its stale presented response is released by the next read's `_release`
  (JCBROKER_DISCARD). The broker itself cannot redo it (it does not know the window semantics
  and has no proof of non-execution).
- Host side today: pl_read_xout returned -2 on the first failed rd (pl_backend.c, before this
  fix), and fk33_transport_jc.c returns -EIO for an isolated rd32 ok:false WITHOUT marking the
  connection broken (its header comment, "ONE ASYMMETRY ON PURPOSE"), so a host retry is
  possible on the same connection.

### Q3, MEASURED locally (bash + python3, no hardware)

```
$ bash -c 'nohup python3 -c "import signal,sys;print(signal.getsignal(signal.SIGINT), file=sys.stderr)" < /dev/null > /dev/null & wait'
Handlers.SIG_IGN
$ bash -c 'python3 -c "import signal,sys;print(signal.getsignal(signal.SIGINT), file=sys.stderr)"'
<built-in function default_int_handler>
```

jc_broker.py had no signal handling at all (no `import signal` before this fix). The broker
therefore ignored SIGINT for its whole life, not "for 20-30 s after the UNKNOWN"; 20-30 s was
the wait before SIGTERM. `stop_broker` in jc_bc_lane.sh (SIGINT, then 30 s, then JCLANE_FAIL)
cannot have stopped a broker it started.

### Tests run

```
python3 -m pytest -q tools/jc                                         659 passed
make -C server run_prompt jc_sim_broker && \
  python3 -m pytest -q server/tests/test_run_prompt_jc.py             22 passed
make -C server test   SEAM_SELFTEST PASS (209), TRANSPORT_JC_SELFTEST PASS (72), 22 passed
make -C server check  SERVER_COMPILE OK;  make -C server imglock-check rc 0
```

Failing on the old code first (MEASURED, same tree before the fix):
- `test_an_unconfirmed_xout_read_is_reseeked_and_retried[ran]`, `[lost]`: old run_prompt exits 1
  with `fk33_transport_jc: die A: WindowUnknown: injected: ...` and
  `run_prompt: prefill returned -2 for 3 ids` (the silicon failure's shape).
- `test_an_unconfirmed_status_read_is_retried` (B STATUS, the 2nd read, a seam_wait poll):
  old run_prompt exits 1.
- `test_a_read_that_keeps_failing_is_given_up_after_the_bound`: old code gives up after 1.
- `test_main_takes_sigint_even_when_started_with_it_ignored`: old broker prints IGNORED.

Teeth / attribution controls (MEASURED, each mutant built and run, then reverted):
- Retry WITHOUT the WIN_SEL/WIN_ADDR re-seek: `[ran]` fails on the VALUE oracle (generated ids
  differ from the sim reference: '96999' vs '152646'), not only on the log check. `[lost]`
  fails only on the log-order check, as it must (if the read never ran, no re-seek is needed
  for the values).
- PL_RD_RETRIES 3: the bound test and the message checks fail.
- Non-window retry disabled: the STATUS test fails.

## Measured and REJECTED, do not retry

- "The response was presented and acked or lost by the reconnect path": nothing can ack seq N
  (only `_take`/`_discard`, and `_discard` never acks a seq of the current frame); no
  RSP_COUNT/RSP_CRC log line. Rejected (DERIVED).
- "The read executed but its completion is only visible via rsp_seq, which the broker does not
  consult": the broker's read path consults exactly rsp_seq (`_take`), and err_seq for errors.
  Rejected (DERIVED).
- "SIGINT is ignored because the broker is stuck in a 10 s CoE socket timeout after the
  UNKNOWN": a blocking recv is interrupted by a delivered SIGINT in Python; the measured cause is
  SIG_IGN inherited from the launcher. Rejected (MEASURED above).
- "Run0 survived six drops, so drops cannot cause this": the contrast test shows NOTFAILED is
  fatal only when the frame truly never ran; a drop that loses only the reply resumes.
- First choice of injection point for the host STATUS test (the 1st B STATUS read) did NOT fail
  the old code: that read is pl_seq_reset's, and run_prompt continues after a failed
  `--seq-reset` (prints `seq-reset FAILED rc -2`). Moved to the 2nd read (a seam_wait poll).

## Measurement traps hit

- The broker's "verdict NOTFAILED" text reads like "the frame passed". On die A it means the
  opposite of proven: the link died on that frame's own command.
- "Ignored SIGINT for 20-30 s" was the observer's wait, not a broker state; the process had
  SIGINT ignored since start.

## Fix (implemented)

server/pl_backend.c: `rd()` retries an -EIO read (the transport's in-band ok:false, e.g.
WindowUnknown) up to PL_RD_RETRIES = 2 times for every seam offset except WIN_DATA;
`rd_win()` (used by pl_read_xout, the only WIN_DATA reader) re-writes WIN_SEL and WIN_ADDR = the
element index before each retry. -ETIMEDOUT and -ECONNABORTED are not retried (the connection is
already marked broken). Writes are NEVER retried: GO and window writes keep their exactly-once
contract. Each retry prints a `[pl_backend] ... retrying (k of 2)` line.
tools/jc/jc_broker.py main(): `signal.signal(SIGINT, signal.default_int_handler)`.

Deployment note: run_prompt runs on the BC-250 (where the socket is), so the BC-250 needs the
sync and a rebuild of run_prompt, and the broker restarted, before the fix is in effect.

## Not determined (open)

- Whether the lost frame left the host at all or was part-shifted. Same outcome; would need
  CoE-level capture.
- The broker's `st_crc_fails` and the die's last_done_seq after the reconnect were not captured
  (only stderr). A `status` request after an UNKNOWN would have shown them.
- The SAME mechanism on a WRITE frame (XIN wrn WR_FIX frames, WIN_SEL/WIN_ADDR wr32, CTRL=GO)
  still ends the run with WindowUnknown; for wrn the transport also marks the connection broken.
  Not fixed: a host retry would break exactly-once for GO. A proper fix needs die-side proof of
  "never pushed", e.g. the frame core publishing the seq of the last PASS it pushed to the FIFO
  (TCK domain, no lag) in the status word's reserved bits [351:213]; then a NOTFAILED frame
  whose seq is not the last pushed PASS after the reopen is provably LOST and resendable. RTL
  change, needs a rebuild; proposal only.
- How often a drop lands on a write vs a read frame (ESTIMATE only: XOUT reads are 5,120 one-item
  frames per hop, XIN writes ~11 frames per hop, so reads dominate the frame count).
- run_prompt continues after `--seq-reset` fails (prints `seq-reset FAILED rc -2`) instead of
  stopping: a card whose position was not cleared then runs the prompt. Separate defect,
  server/tests/run_prompt.c:710-720, not touched.
- On SIGINT, `br.close()` may still block up to one 10 s CoE timeout if the BMC is silent
  (then the client is poisoned and the rest is fast); within the lane's 30 s window.
