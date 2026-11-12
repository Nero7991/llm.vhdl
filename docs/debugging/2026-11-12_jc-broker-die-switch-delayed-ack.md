# JC broker: each die switch cost ~207 ms (TCP delayed ACK on the BMC's CMD_TMS replies)

## 1. The question

2026-11-12, Jungle Cat on `jccard_loop5` (both dies, own-PC 27B images), broker on the BC-250
(`tools/jc/jc_broker.py serve --chain AB`). Oren: "we need to considerably speed this up". The
web UI's host path ran at 0.75 tok/s, and `jc_loop.py` took 67.0 s for 38 positions (1.76 s per
position) against a card compute time of about 0.52 s per position (DERIVED from the own-PC
cycle counts, 1.91 tok/s pair). Where did the other ~1.2 s per position go?

## 2. The answer

Every switch between die A and die B on the shared JTAG chain cost ~207 ms. A switch is five
synchronous CMD_TMS round trips to the BMC: exit DR, to IR, IR shift, exit IR, to DR. The BMC
answers each in two small TCP writes, and the second waited for our delayed ACK of the first,
about 40 ms. Setting `TCP_QUICKACK` before every `recv` in `tools/jc/coe.py` (commit `ee825a39`)
brought a switch down to ~2 ms. The loop run dropped from 67.0 s to 19.7 s with identical ids,
which is the card's own rate.

## 3. Procedure

1. **Request breakdown** (`run_prompt` timing line, UI request, 22 positions):
   - run_chunk 22.3 s, of which STATUS wait 10.6 s (card compute plus poll granularity);
   - X pushes 2.6 s;
   - the rest is host register traffic.

   Separates card time from host time.
2. **Single-op latency, idle card**, 50 reads of one register, per die:
   - from the workstation through the ssh-forwarded socket: A 46.6 ms, B 19.6 ms;
   - on the BC-250 next to the broker: 10-12 ms.

   Separates the ssh forward from the broker and BMC.
3. **Loop driver moved to the BC-250:** 53.3 s for 38 positions. Ruled out the forward as the main cost.
4. **Per-call profile** (`prof_loop.py`, which wraps `Broker.call` and `send_row`):
   - Calls split into fast ones (3.9-7.5 ms) and slow ones (100-213 ms).
   - The slow ones were the calls that followed a call to the other die: `LINK_CREDIT` on A after
     `LINK_CONSUMED` on B, every `STATUS` (read A then B each iteration), and `ID` at setup.
5. **Isolating microbenchmark** (BC-250, idle card):
   - 20 reads on die A: 7.25 ms per read;
   - 10 x (A, B) alternating: 214.2 ms per read.

   This isolates the die switch from everything else.
6. **Code read.** `jc_broker._Conn.select` closes one die's scan and opens the other's.
   `CoeTransport.open_scan`/`close_scan` issue five CMD_TMS moves, each a synchronous
   `_call_token` round trip, and nothing else (filler 16384 bits, 1 settle poll). That makes
   207 / 5 = ~41 ms per move, the Linux delayed-ACK timer.
7. **Fix applied to a scratch copy of `tools/` on the BC-250, broker restarted**, same
   microbenchmark: same-die 5.43 ms, alternating 7.22 ms.
8. **Loop rerun** under the patched broker: 19.74 s, 3526 broker calls, ids identical (`SAME`).

## 4. Evidence (raw)

Before (`prof_loop.py`, BC-250):
```
WALL 66.96 s
send_row: 38 calls 12.17 s
broker total 886 calls 66.44 s
  rd32 STATUS                     160 calls   26.65 s  166.5 ms/call
  rd32 OUT_COUNT                  117 calls   12.65 s  108.1 ms/call
  rd32 POS                         85 calls    8.46 s   99.5 ms/call
  wr32 LINK_CREDIT                 39 calls    8.27 s  212.0 ms/call
  rd32 CRC_FAILS                   16 calls    3.41 s  213.3 ms/call
  wrn ROW_DATA                     38 calls    2.48 s   65.2 ms/call
  rd32 RESENDS                      9 calls    1.91 s  211.8 ms/call
  wr32 OUT_ACK                    117 calls    0.46 s    3.9 ms/call
  rd32 ID                           2 calls    0.43 s  213.5 ms/call
  rd32 ROW_TOK                     38 calls    0.28 s    7.5 ms/call
  wr32 NEXT_TOKEN                  16 calls    0.27 s   17.0 ms/call
  rd32 LINK_CONSUMED               58 calls    0.22 s    3.9 ms/call
  wr32 CTRL                        49 calls    0.19 s    3.9 ms/call
```
Microbenchmark before: `same die A ms 7.254838943481445`, `alternating A/B ms per read 214.24832344055176`.

After:
```
same die A ms 5.42827844619751
alternating A/B ms per read 7.21888542175293

WALL 19.74 s
send_row: 38 calls 3.58 s
broker total 3526 calls 19.34 s
  rd32 OUT_COUNT                  853 calls    5.77 s    6.8 ms/call
  rd32 STATUS                     896 calls    5.06 s    5.6 ms/call
  wr32 OUT_ACK                    853 calls    2.67 s    3.1 ms/call
  wrn ROW_DATA                     38 calls    2.06 s   54.2 ms/call
  rd32 LINK_CONSUMED              426 calls    1.32 s    3.1 ms/call
```
The call count rose because the driver polls: with fast calls it polls more often in the same
card time. 19.7 s / 38 = 0.52 s per position.

UI host path after the fix (workstation `run_prompt`, ssh forward): 22 positions, run_chunk 26.2 s
(STATUS wait 7.2 s, X pushes 0.54 s), 1.08 tok/s decode. The host path is still dominated by its
own per-op traffic over the forward; the loop on the BC-250 is the fast path.

## 5. Measured and REJECTED (do not retry)

- **"The ssh socket forward is the bottleneck."** Moving the driver to the BC-250 took the loop
  from 56.3 s to 53.3 s only.
- **"Row pushes are bandwidth-bound at ~36 KB/s (280 ms per row)."** The 280 ms was mostly a die
  switch. The bulk `wrn ROW_DATA` itself is 54-65 ms.
- **"The card is slower under load."** A 213 ms `ID` read at setup with the card idle ruled this out.

## 6. Measurement traps hit

- Per-op averages from a single-die microbenchmark (11 ms) hid the cost, because they never switch
  dies. Any latency figure for this broker must state the die order of the calls.
- A slow call in the profile is not slow because of what it is: `STATUS` is slow when it follows
  a call to the other die. Attribute by sequence, not by register.

## 7. Open

- `TCP_QUICKACK` is reset by the kernel and is set before every `recv`. Not tested off Linux (the
  `hasattr` guard skips it).
- The broker currently running on the BC-250 runs from a scratch copy with the same patch
  (`/home/labuser/brkx`), not from the synced repo. Re-sync and restart it from the repo after
  this commit lands on the branch the sync script copies.
- Whether `run_prompt`'s C transport path has the same problem on its side was not checked: it
  talks to the broker over a Unix socket only.
