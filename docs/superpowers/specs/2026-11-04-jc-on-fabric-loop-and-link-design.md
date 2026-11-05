# Jungle Cat on-fabric token loop and die-to-die link: design

Date: 2026-11-04. Status: design approved section by section in conversation (sections 1, 2 on
2026-10-24; 1b, 3, 4 on 2026-11-04). This file is the spec; the implementation plan follows it.

## Goal

Run decode on the Jungle Cat (2x VU35P, 27B split blocks 0-32 on die A, 33-63 + LM head on
die B) without the host carrying the per-token residual. The host starts a run, then only polls.
Test vehicle before the link exists in RTL: 9B on a single die with `embed_gather`.

## Decisions taken (from the brainstorm)

- Greedy argmax only.
- Pluggable row source (`embed_gather`, host row, link).
- The card runs prefill too (the loop walks the prompt, then generates).
- Stop on `max_new`, 8 stop ids, C_MAXPOS-1, or ABORT; output FIFO of 1024 ids.
- GDN state: on-card zero only for fresh sequences (see 1.5).
- Approach A: `tok_loop` drives the existing seam as a second master; `embed_gather` reads HBM
  as a third master on `hbm_sc`.
- Link: N-lane design, tested with 1 lane; Aurora 64B/66B simplex; host relays the token back
  until a B-to-A pair is fitted.

## Hardware facts this design rests on (MEASURED, 2026-11-03/04)

- GT rails are powered only in SLR0 (quads 124-127, 224-227).
  `docs/debugging/2026-11-03_jc-gty-slr1-unpowered-qpll-control.md`.
- The carrier's slot-to-slot lane AC-coupling caps (32 pads) were unpopulated. With 100 nF on two
  pairs, die 0 GTYE4_CHANNEL_X0Y0 TX to die 1 X0Y0 RX carries PRBS31 with 0 errors at
  1.25 Gb/s and BER 1.7e-8 at 10.3125 Gb/s (untuned, MMCM refclk).
  `docs/debugging/2026-11-04_jc-die-to-die-gty-link-search.md`.
- A QPLL0 fed from an MMCM (BC26 200 MHz, x25/4/8 = 156.25 MHz) through GTGREFCLK0, select 111,
  locks on both dies. The board refclk on bank 126 is not yet reliable on die 1.
- `sqrl_bridge` loads the same bitstream file onto both dies.

## 1. Components (approved 2026-10-24)

1.1 **`tok_loop`** (new RTL, one per die).
- Control slave (AXI-Lite, a new address in the die's map, reached through the broker):
  - CTRL: START, ABORT;
  - PROMPT_LEN, MAX_NEW, STOP_ID[0..7], ROW_SRC (gather, host or link);
  - a 4096-entry prompt id buffer, written in one bulk write;
  - STATUS: state, stop reason, position, tokens generated;
  - OUT_FIFO: 1024 ids, read in bulk, with a count.
- Seam master: a second AXI-Lite master into the seam that replays the host's sequence:
  - SEQ_RESET;
  - per position: X_EXP, then WIN_SEL / WIN_ADDR / WIN_DATA with the row, then SEQ_POS /
    N_STEP / GO;
  - poll STATUS, then read ARGMAX.
  - Registers per `server/fk33_seam.h`: STATUS 0x18, SEQ_POS 0x20, N_STEP 0x24, ARGMAX 0x44,
    X_EXP 0x54, WIN_SEL 0x58, WIN_ADDR 0x5C (auto-increments), WIN_DATA 0x60.

1.2 **Seam ownership mux** (new, small): an exclusive 2:1 switch in front of the seam's AXI-Lite
slave, not an arbiter. `tok_loop` owns the seam from START until it stops; host seam accesses
during that time get SLVERR. The seam itself does not change.

1.3 **Row source interface:** `row(tok)` returns n_embd int16 values plus an exponent (5120 on
the 27B, 4096 on the 9B). Implementations:
- **`embed_gather`** (9B): reads two 4 KB pieces of the tiled table from HBM, dequantizes
  (`codebook[nibble] * scale`), takes the block max and BFP-packs the row. Bit-exact to
  `pl_embed_mv4i`.
- **Host row** (27B die A fallback): the loop raises NEED_ROW with the token id in STATUS; the host
  writes the row into a loop-side buffer and sets ROW_READY.
- **Link** (27B die B, section 1b): the row is die A's residual from `jc_link_rx`.

1.4 **Embedding table in HBM** (9B): the packer keeps `token_embd.weight` and places the 572 MB
tiled table after the GDN state. Max context drops from 75,151 to about 42,000 tokens (DERIVED
from the free space).

1.5 **GDN state at START:** a test first establishes whether SEQ_RESET's token-0 masking already
makes stale state harmless. If yes, no fill engine. If not, a zero-fill runs on the gather's HBM
port before position 0.

## 1b. Link components (approved 2026-11-04)

1. **`jc_link_tx`** (die A): after die A's position completes (GO done), `tok_loop`'s seam master
   reads R_X from window 3 (n_embd words, about 10 KB on the 27B). It frames them and streams the
   frame into the Aurora TX. The frame is: header (magic, sequence number, position, word
   count), payload, CRC32.
2. **Aurora 64B/66B, simplex.**
   - Lanes: generic `NLANES`, plus a per-lane table of {GTYE4_CHANNEL site, TX polarity, RX
     polarity}. First build: `NLANES = 1` on GTYE4_CHANNEL_X0Y0.
   - Refclk: the MMCM-on-GTGREFCLK0 path of IBERT G (`/mnt/storage/fk33_builds/jc_ibert/G/`),
     with a generic to select the pin refclk (MGTREFCLK1_126) once it is reliable on both dies.
   - Line rate: 10.3125 Gb/s, with 1.25 Gb/s as the fallback build.
3. **`jc_link_rx`** (die B): deframes; checks CRC, sequence and position; holds the frame in an
   n_embd-word buffer.
4. **Die B's row source is the link:** die B's `tok_loop` waits for a frame whose position equals
   its next position, writes it into window 2 (X) and runs.
5. **Return token, B to A.**
   - Phase 1 (now): host relay. Die B's argmax goes into its OUT_FIFO. The host reads it and
     writes it into a NEXT_TOKEN register on die A's `tok_loop`: two small accesses per token
     instead of the 10 KB hop.
   - Phase 2: `NLANES_RET` in the B-to-A direction carrying the token id, once a reverse pair is
     fitted. The host then leaves the loop.
6. **One bitstream, two roles.** The bridge loads the same file on both dies, so the TX/RX role
   and the A/B half are not generics. Both Aurora directions are instantiated, one enabled at
   runtime: the die reads its DNA (against `jc_dies.json`) or a host-written ROLE register at
   START.

ASSUMED, to verify before relying on it: die A is JTAG device 0 (chain "AB", A nearest TDI), so
the measured lane runs A to B. Check DNA against `jc_dies.json`.

## 2. Data flow and per-token timing (approved 2026-10-24, extended)

- **HBM port for the gather:** the block design's `hbm_sc` smartconnect
  (`hw/jc/card/jc_card_bd.tcl:202-205`, NUM_SI 2: `jtag_hbm` and the ctl core's read master)
  feeds HBM SAXI_16. The gather is a third master (NUM_SI 3): a block-design change only, with no
  edit to `bc_port_grant` or the loader.
- **START (host):** after writing PROMPT_LEN, MAX_NEW, the stop ids and the prompt buffer, the
  host sets START. The loop takes the seam, issues SEQ_RESET, checks that TOK_POS and SEQ_POS read
  0 (as `pl_seq_reset` does), then runs the GDN step (1.5).
- **Per position p:**
  1. Choose the token: `tok = prompt[p]` while p < PROMPT_LEN, otherwise the previous argmax.
  2. Fetch `row(tok)` from the row source. Write X_EXP, WIN_SEL = XIN, WIN_ADDR = 0, then n_embd
     WIN_DATA writes.
  3. Write SEQ_POS = p, N_STEP = 1, GO. Poll STATUS until DONE or ERR, then read ARGMAX.
  4. From p = PROMPT_LEN-1, the argmax is generated: push it to OUT_FIFO, and stop on a stop id,
     max_new, C_MAXPOS-1 or ABORT. Whether a stop id is itself pushed follows `run_prompt`'s ids
     file exactly.
  5. 27B: die A frames and sends R_X (1b.1); die B waits for that position's frame (1b.4).
- **STOP:** latch the reason and the final position, then release the seam.

| Step | Cost per token | Label |
|---|---|---|
| Gather: 2 x 4 KB at 32 B/beat, then dequant and BFP pack | about 10 us | ESTIMATE |
| X row: n_embd AXI-Lite writes through mux and seam, about 6 cycles each | about 0.25 ms at 125 MHz | ESTIMATE |
| R_X read on die A through the seam | about 0.25 ms | ESTIMATE |
| Link, 10 KB at 10.3125 Gb/s (64b/66b) | about 8 us | DERIVED |
| GO, poll, argmax, FIFO | under 2 us | ESTIMATE |
| Engine, one position | 0.36 s (27B die A, 125 MHz) | MEASURED |

The host's existing hop costs about 0.1-0.16 s per position with the bulk read (ESTIMATE, not yet
run on silicon).

## 3. Error handling (approved 2026-11-04)

No silent retry: every fault ends in a latched reason the host can read.

| Fault | Detection | Action |
|---|---|---|
| Engine ERR | STATUS reads ERR after GO | stop, ENGINE_ERR, latch position and STATUS |
| Engine hang | no DONE within a timeout (register, default 4x the measured position time) | stop, ENGINE_TIMEOUT |
| Seam access error | SLVERR or DECERR on the seam master | stop, SEAM_ERR, latch the address |
| Host ABORT | CTRL bit | stop between positions (never mid-GO), ABORT |
| Host touches the seam mid-run | ownership mux | host gets SLVERR; the loop is undisturbed |
| CRC mismatch (die B) | `jc_link_rx` | drop the frame, count it, raise LINK_BAD |
| Wrong sequence or position | header against expected | drop, count, LINK_BAD |
| Link down | Aurora `channel_up` falls | count, LINK_DOWN |
| Frame never arrives | per-position timeout | stop, LINK_TIMEOUT |

**Recovery, phase 1 (host-driven resend):**
- Die A keeps its last frame until the next position overwrites it.
- On LINK_BAD or LINK_DOWN, die B pauses (not stops) and shows it in STATUS.
- The host sets RESEND on die A. Die B resumes on a good frame for that position.
- A per-run resend cap (register, default 3) ends in LINK_RETRY_EXHAUSTED.

**Counters:** frames sent, frames good, CRC fails, sequence/position mismatches, link-down events,
resends.

**Not handled, by design:** corruption that passes CRC32 (about 2^-32 per bad frame), and the
phase 1 token relay beyond the broker's own checks.

## 4. Testing (approved 2026-11-04)

Every value check compares against an existing independent implementation, and every new check
gets a mutant that must fail it (CLAUDE.md, verification discipline).

| Unit | Oracle | Mutants that must fail |
|---|---|---|
| `tok_loop` (GHDL) | A Python model of `run_prompt`'s host sequence: the bench's behavioural seam records every transaction and the trace must equal the model's. Output ids must equal `run_prompt` over `jc_sim_broker` with the same deterministic seam | no SEQ_RESET; prompt index off by one; stop id pushed against the ids-file convention; max_new off by one |
| `embed_gather` (GHDL) | `pl_embed_mv4i` (C), bit-exact, random ids plus edge ids (0, last, an all-negative block) | codebook index swapped; block max taken before the scale |
| `jc_link_tx` / `jc_link_rx` (GHDL) | Aurora replaced by an AXIS channel model with injected bit flips, dropped beats and link-down mid-frame; the received buffer equals the sent one or the right fault is raised | CRC check off (fails the bit-flip case); position check off (fails the stale-frame case); resend cap ignored |
| Aurora + framing (xsim, UNISIM) | Aurora example simulation, `NLANES` 1 and 4 | lane map permuted against the generic |

**Silicon (main session only):**
1. Link alone: 10-minute frame soak on the fitted lane; zero CRC fails, or a measured frame error
   rate.
2. Hop transparency: for positions 0, 3 and 22, die B's X window after the hop is bit-identical to
   die A's R_X read over the host path.
3. Tokens: loop ids = `run_prompt` ids = llama.cpp reference on the 23-id DC-DC prompt, then the
   500-token context test (input and output, twice).
4. Fault injection: wrong RX polarity mid-run gives LINK_BAD and a pause; fixing it plus RESEND
   resumes; same ids at the end.

**Order:** GHDL units (framing, loop, gather), then the card build with the link, then silicon
steps 1-4.

## Out of scope

- Sampling other than greedy argmax.
- Tensor parallelism across 4 dies (subsystem E).
- The 2xx-column and SLR1 quads.
- Batching.

## Open

- Whether the slot-to-slot pairs beyond lane 0 work once their caps are fitted; lane 4 is marginal.
- The die-A/JTAG-index assumption (1b).
- The board refclk on die 1.
- Tuning TX swing/emphasis and RX equalization at 10.3125 Gb/s.
