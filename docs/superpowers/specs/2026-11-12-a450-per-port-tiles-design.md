# Subsystem A at 450 MHz: per-port tiles in their own clock domain (design)

Approved in conversation 2026-11-12 (Oren: "We first design block of the matmul units (or get our
current ones to close at much faster clocks) then scale accordingly"; target 450 MHz; approach
"per-port tiles + fast domain"; sections 1-3 approved as written below).

## 0. Context and goal

- The Jungle Cat dies run at VCCINT 0.850 V (MEASURED, board default,
  `docs/boards/jungle-cat/`), so the -2 timing model applies to the `-2L` part.
- Today A (`matvec_int4_desc_axi` -> `matvec_int4` -> `weight_streamer`, `act_mem_striped`,
  `matvec_core`) shares one clock net with the HBM AXI ports and the whole engine
  (`hw/jc/card/gen_jc_card.py:730`). The card runs at 125 MHz.
- A rates 264 MHz on `xcvu35p-fsvh2104-2-e`, against a primitive ceiling of 637 MHz (MEASURED,
  `hw/targets/ratings/vu35p_jc_m2/a_engine.QWEN35_9B.json`). The worst routed path:
  - starts at `streamer/gen_w[14].port_p/g_dc.fifo/ocnt_reg[0]`;
  - ends at `core/tr_reg[0][542]/DSP_A_B_DATA_INST/CEA2`;
  - has 4 logic levels, and routing is 86% of its delay;
  - is the accept/valid clock-enable of all 1,536 product DSPs, one net with fanout 8,493
    costing 2.319 ns.
- PG276: one HBM AXI port is 256 bits and matches the HBM's toggle rate at 450 MHz, which gives
  460.8 GB/s for the two stacks. The JC ports run at 125 MHz today, 28% of that rate.
- A on silicon: 12.36M cycles per die per token at 1.508 c/word (MEASURED, `measure_token.log`,
  own-PC images). The 1.5 c/word is the `stream_fifo` pop cadence (`rtl/stream_fifo.vhd:78-100`),
  which FAST_POP removes.

**Goal.** A closes at 450 MHz, routed, on the JC part, with every output bit unchanged, so its
throughput is the HBM's. This follows Oren's 2026-10-07 rule: A consumes NPORT x 32 B every
cycle, and throughput scales with the clock with no width change. Raising B, C and the vector ops
("scale accordingly") is separate work, one spec per block.

## 1. Architecture

### 1.1 Clock domains

- `aclk_a`, 450 MHz: A and all 32 HBM AXI ports. PG276 asks for the switch clock to be the
  fastest AXI clock, so the ports move with A.
- `clk_core`: B, C, the vector ops, the sequencer, the seam and the loop. It stays 125 MHz until
  those blocks are raised.
- B's and C's HBM masters reach the ports through dual-clock read/write ports, the
  `axi_rd_port DUAL_CLK` pattern A already carries (`fk33_engine.vhd:1357`).

### 1.2 `mv_tile`: one per weight port (24 on the JC)

Each port carries a self-contained slice: 2 rows x BLK=32 INT4 weights per 256-bit beat
(lane-split 6.5a, `weight_streamer`). A tile owns those 2 rows completely.

| Stage | Content |
|---|---|
| Port front end | AXI3 reader, 16-beat bursts, plus FIFO; FAST_POP cadence, 1.0 beat per cycle |
| Unpack and codebook | 64 nibbles to int8 through a tile-local copy of the 16 x int8 codebook (LUTRAM) |
| MAC | 2 rows x 32 products in 64 DSP48E2; each row's 32 products reduced along the DSP cascade (PCIN/PCOUT), no fabric adder tree |
| Scale | per row, the uint15 block scale multiply, 1 DSP per row |
| Accumulate and round | 48-bit accumulate, then the existing `floor_shr`, `out_shift`, and the BFP/raw/partial output modes, bit-exact with `matvec_core` and `mv4i_arith_pkg` |

- **No shared enables.** Every stage runs every cycle and carries a valid bit beside its data. A
  stall stops only the tile's own FIFO pop. No net in A fans out to more than one tile's worth
  of cells (target: no A net with fanout over 128 outside the distribution tree, whose fanout is
  set by its own register levels).
- **Placement.** One pblock per tile column, in SLR0 directly above that tile's HBM port. A
  crosses no SLR. The distribution tree, the result chain and the job control sit centrally along
  the row of tiles.

### 1.3 What does not change

- The descriptor format and the A_JOB contract with the sequencer.
- The INT4, codebook and BFP arithmetic, and so every output bit.
- The HBM image layout (own-PC), the region file contract, and the util counters' meaning.
- The DSP count stays about 1,584 plus 1 scale DSP per row (48).

## 2. Data flow, control, clock crossing

### 2.1 Weights
Each tile reads only its own port. Weights never cross a tile boundary.

### 2.2 x and scales: one broadcast stream, paced by credits
- **The activation memory** stays one memory (about 8 BRAM36, 512 bits per read), made true
  dual-port: written on `clk_core` by today's load path, read on `aclk_a`.
- **The distributor** reads one block per cycle: 32 x 16-bit x values, plus the 48 x 16-bit
  scale word merged from the 3 scale ports. It sends the pair down a registered tree, 3 to 4
  register levels, so each tile gets its own registered copy.
- **Credits.** Each tile has a 32-deep x/scale FIFO. The distributor sends block b only when it
  holds a credit from every tile. Credits return through a registered AND tree, the only
  24-input signal in A, and it is never on a single-cycle path. FIFO depth covers the tree's
  round trip plus the drift between tiles.
- **Why drift is small.** With the own-PC layout no two tiles share a pseudo-channel, so their
  streams drift only by HBM refresh and turnaround jitter.
- **Rejected:** a private x copy per tile. It costs about 192 BRAM36 to buy independence the
  credits already give.

### 2.3 Results
- After its 2 rows' K/32 blocks (at least 160 cycles), each tile shifts its 2 x 64-bit results
  into a 24-stage daisy chain. The chain assembles the 48-row beat in 24 cycles, inside one
  row-tile, so it never stalls the tiles.
- The beat crosses to `clk_core` through an async FIFO. It is written to the region file under
  the existing `y_we`/`y_addr`/`y_data`/`y_mask`/`y_exp` contract.

### 2.4 Control
- The descriptor fetch moves into `aclk_a`.
- A_JOB start, done, err and sat cross as handshake pulses through 2-flop synchronizers.
- The sequencer issues start after the x load into the dual-port memory completes, the same order
  as today, so the read side never sees a half-written vector.
- The util counters (`a_util_ctr`, `a_job_counter`) count in `aclk_a` and are read through a
  synchronized snapshot.

### 2.5 Bring-up switch
`A_CLK_SPLIT : boolean := false`.
- **false:** `aclk_a` is `clk_core`, so the new A drops into today's card at 125 MHz for a value
  check on silicon. The crossings degenerate to the existing no-op dual-clock pattern.
- **true:** the 450 MHz domain.

### 2.6 Out of scope
- Raising B, C and the vector ops.
- The card generator's 50..250 MHz `clk_core` check (`gen_jc_card.py:116-131`). Only the
  split-on card task changes the generator, and it adds an `aclk_a` MMCM output rather than
  raising `clk_core`.
- A second embedding or on-chip gather layout.

## 3. Verification and gates

### 3.1 Oracles
- **The tile bench** checks against the Python mv4i arithmetic model, the independent
  implementation A was proven bit-exact against. It uses random descriptors, codebooks, scales and
  `out_shift`, all three output modes, saturation, and pad rows. Named mutants plus an attribution
  control apply: a scale-path mutant, a codebook-index mutant, an `out_shift` mutant, and a
  dropped-valid mutant.
- **The composed-A equivalence bench** runs the new A beside today's `matvec_int4` on the same
  vectors in GHDL. `y`, `y_exp`, `y_mask`, `sat` and `err` must be identical on every beat. It
  covers:
  - random per-port back-pressure (tiles drift, credits exhausted);
  - FIFO-empty corners and the end of a job;
  - both `A_CLK_SPLIT` settings with `aclk_a`:`clk_core` at 450:125 and a rolling phase.

  A credit-loss mutant must fail it. GHDL benches stay free of UNISIM primitives; DSP cascade
  inference is behavioural.

### 3.2 Timing gates (routed WNS only; the run must contain `route_design`)
1. `mv_tile` out of context at 2.222 ns on `xcvu35p-fsvh2104-2L-e` at 0.85 V, recorded as a block
   rating (`tools/rate/`).
2. **The honest gate.** A test design with the real HBM IP, 24 tiles, the distributor, the result
   chain, the crossings and a stub sequencer, placed with the per-tile pblocks: routed WNS >= 0 at
   450 MHz on `aclk_a`.

### 3.3 Silicon gates (main session only)
1. Split off, today's 125 MHz card: K1 anchor byte-identical, and the 500-token context test
   (pair, input and output, twice) ids identical to the current card.
2. Split on, `aclk_a` 450 MHz: same values, and `a_jobcyc` per word <= 1.05 in `aclk_a` cycles.

### 3.4 Expected gain (ESTIMATE: 1.0 c/word at 450 MHz; B, C and the vector ops unchanged)
- A per die: 12.36M cycles at 125 MHz (98.9 ms) to 8.19M at 450 MHz (18.2 ms).
- Die token: about 262 ms to about 181 ms. Pair: about 1.9 to about 2.75 tok/s.
- The rest of the engine then holds about 90% of the token, which is the next work.

## 4. Plan shape
1. Tile model and vectors.
2. `mv_tile` RTL, bench and mutants.
3. Tile rating at 450 MHz.
4. x/scale distributor with credits.
5. Result chain and the crossings.
6. Composed A, `A_CLK_SPLIT`, and the equivalence bench.
7. A+HBM 450 MHz test design with pblocks.
8. Card integration, split off; silicon gate 1.
9. Split-on card build; silicon gate 2.

## 5. Risks
- **Credit AND tree latency.** It sets the FIFO depth. Mitigation: the depth is a generic, and the
  bench sweeps it.
- **The DSP cascade over 32 products.** It is one column of 32 DSPs per row (64 per tile), so
  each tile fits its two columns and stays contiguous with its pblock.
- **HBM port sites.** The 24 weight ports plus 3 scale ports land on fixed sites; the test design
  (3.2 gate 2) answers whether the tile pblocks fit above them.
- **Ports B and C share at 450 MHz.** Their dual-clock ports add FIFOs. Their timing is in
  `clk_core`, but the port-side halves are in `aclk_a` and must meet 450 MHz too.
