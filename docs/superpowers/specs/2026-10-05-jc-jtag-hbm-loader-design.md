# Jungle Cat JTAG-to-HBM weight loader: design

Date: 2026-10-05. Status: design approved in chat by Oren; this written spec awaits review.

## 1. Purpose and success criteria

The Jungle Cat (JCC2L-A7 Lite, two JCM35P / VU35P modules) has no PCIe. Its only
no-new-hardware host path is JTAG through the BMC over Ethernet (CoE). The 2-die 27B
pipeline needs ~7.1 GB of weights in each die's HBM. This loader puts a weight image
into one die's HBM over that path.

Done when, on silicon:

1. Card 0's 27B image (`/mnt/storage/llama-models/qwen38-27b-card0-b0-32/manifest.json`,
   `weights_bytes` 7,101,345,792) lands in die 0's HBM at the manifest's addresses in
   **about 46 minutes** (2.7 MB/s transport MEASURED, 96.9% framing efficiency,
   `docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md` S12-S13).
2. Every frame is CRC-checked on arrival and nothing that failed its CRC is committed.
3. The image is verified by a path that does not share the loader's data path (S7).
4. The same tool then loads card 1's image into die 1.

Out of scope: the final Jungle Cat block design with the engine (the loader is a
standalone unit with one AXI master port so it drops into that design later);
loading both dies concurrently (one shared JTAG chain, so no aggregate gain).

## 2. Measured constraints this design rests on

| Fact | Value | Source |
|---|---|---|
| Host path | direct CoE client, TCP to BMC port 21363, commands `0x8000100e`/`0x8000100f` | debugging doc S12 |
| Sustained rate | 2,676.8 KB/s at 16,384-bit commands, depth 4, 27 MHz, 0 bit errors over 100 MB | S12 |
| JTAG clock | 27 MHz is the top (27-54 MHz requests run at 27; 54 corrupts) | S11-S12 |
| Command size | 16,384 bits gives the full rate; 32,768 accepted, no gain | S13 |
| Chain | 2 devices, IR 12 bits each (24 total), BYPASS delay 1 bit per device | S9, BSDL |
| Opcodes (BSDL `xcvu35p_fsvh2104.bsd`) | USER3 `100010100100`, USER4 `100011100100`, BYPASS `111111111111`, IDCODE `001001001001` | Vivado 2023.2 data |
| Module clock | BC26 200 MHz LVDS live; all carrier clocks and GTY refclks dead | bringup S11, S14 |
| HBM reference | FK33 already drives HBM_REF_CLK and APB from a fabric `clk_wiz` | `hw/fk33/gen_pcieep.py` |
| HBM slave | AXI3: 16-beat burst cap (ARLEN/AWLEN 4 bits) | CLAUDE.md |
| Image layout | manifest v2 lane-striped: per-piece absolute `hbm_offset`, 4 KB aligned; no piece crosses the 4 GB stack boundary; `blake2b_128` per file from pack time | `fk33_load_weights.py`, `tools/hbm_map.py` |

## 3. Architecture

```
host (BC-250)                         VU35P die (bitstream: hw/jc/loader/)
coe_load.py                           BSCANE2 (USER4)
  manifest -> pieces -> frames  CoE    |  TCK 27 MHz domain
  0x8000100f, 16384 bits, depth 4 ---> jc_frame_rx --(256-bit words + frame end)--> async_fifo
  <--- TDO: status of previous frame <-'                                              |  200 MHz
                                                                          jc_hbm_writer (AXI3, 16-beat)
                                                                                      |
                                                                          HBM (8 GB, global addressing)
                                                                          jc_hbm_crc  (range CRC32, reads HBM)
BC26 200 MHz -> clk_wiz -> 200 MHz fabric, 100 MHz HBM_REF_CLK + APB_PCLK
```

The existing `jtag_axi` probe (debug hub) stays in the bitstream for the independent
readback in S7. The loader uses USER4; the debug hub's chain is read from the
implemented netlist's `BSCANE2` `JTAG_CHAIN` property and must differ (a build-time
check, not an assumption).

## 4. Units

### 4.1 `jc_frame_rx` (TCK domain), `hw/jc/loader/rtl/jc_frame_rx.vhd`

- `BSCANE2` with `JTAG_CHAIN => 4`. Shifts TDI into a 256-bit shift register on TCK
  while `SEL and SHIFT`.
- **One long DR scan for the whole load.** The measured stream holds TMS at 0 across
  `0x8000100f` commands (debugging doc S12), so the TAP stays in Shift-DR from frame
  to frame and there is NO Capture-DR between frames. The unit therefore counts bits
  itself: `CAPTURE` resets the bit counter, every 16,384 bits is one frame slot, and
  the status shift register (4.4) is reloaded at each slot boundary so it shifts out
  on TDO during the next slot.
- **Resync.** If a slot does not start with the magic word, the unit drops it, flags
  `desync` in status, and ignores input until the next `CAPTURE`. The host resyncs by
  leaving Shift-DR (`0x8000100e`: Exit1, Update) and re-entering it (Capture resets
  the counter), then resends from the last committed seq.
- Frame format (all fields little-endian, LSB first on the wire, which is the order
  `0x8000100f` sends bytes):

  | Field | Bits | Meaning |
  |---|---|---|
  | magic | 32 | `0x4A4C4431` ("JLD1"); a frame not starting with it is discarded |
  | seq | 32 | frame sequence number, +1 per frame |
  | hbm_addr | 40 | byte address, 32-byte aligned |
  | nwords | 16 | payload length in 256-bit words, 1 to 62; 0 for a CRC-range request |
  | flags | 16 | bit 0 = CRC-range request (no payload), others reserved 0 |
  | range_len | 40 | CRC-range requests only: byte length (multiple of 32); else 0 |
  | rsvd | 80 | zero; pads the header to one 256-bit word |
  | payload | 256 x nwords | data |
  | crc32 | 32 | CRC-32 (IEEE, reflected) over header word and payload |

  A 16,384-bit command carries one frame slot: 1 header word + 62 payload words
  (63 x 256 = 16,128 bits) + 32-bit CRC + 224 pad bits (zeros, ignored after the CRC)
  = 16,384. A shorter final frame is padded to the full slot. DERIVED payload
  efficiency 1,984 / 2,048 = 96.9%, so ~2.59 MB/s of image data and ~46 min for
  card 0's 7.10 GB.
- Words go into the FIFO as they complete, tagged `first/last`; the CRC is computed
  serially in TCK and its verdict is pushed as a final tag word. The writer commits
  nothing until the verdict arrives (4.3).
- **TCK runs only while bits shift.** Between commands the BMC stops TCK, so any TCK
  logic still pending after the CRC's last bit (the verdict, the FIFO push, the
  status reload) must finish inside the slot's 224 pad bits. The pad is load-bearing,
  not filler; the bench checks the verdict lands before the slot ends.
- The other die sits in BYPASS and adds one bit of delay on the chain. The host
  shifts one pad bit at the start of the scan when that die is nearer TDI, so slot
  boundaries align with the loader's counter. Which die is nearer TDI is measured at
  bring-up (S8).

### 4.2 `async_fifo` (reused, `rtl/async_fifo.vhd`)

TCK to 200 MHz. Depth sized for one whole frame plus one in flight (2 x 64 words).
Its existing bench and mutation suite cover it.

### 4.3 `jc_hbm_writer` (200 MHz), `hw/jc/loader/rtl/jc_hbm_writer.vhd`

- Buffers one frame's payload in BRAM (62 x 256 bit), writes it only after the CRC
  verdict says PASS. A failed frame is dropped whole: HBM is never half-written.
- AXI3 master: 256-bit data, AWLEN at most 15 (16 beats), no burst crosses a 4 KB
  boundary, `AWSIZE` 32 bytes, all strobes set. Counts BRESP errors.
- Enforces `seq` = last committed + 1; a duplicate (host resend) is acknowledged and
  dropped, a gap is a sequence error reported in status.

### 4.4 Status word (returned on TDO during the next frame)

`magic 0x4A4C5354` ("JLST"), last committed seq, frames committed, CRC failures,
sequence errors, desync count, BRESP errors, writer busy, HBM trip flags, and the
last range-CRC result with its seq. Reloaded at every slot boundary (4.1). The
writer's counters live in the 200 MHz domain and cross to TCK through a gray-coded
or handshake synchroniser (the project's `graygate` rules apply). The host reads
frame N's outcome while sending later frames, so there is no extra round trip. Because of pipelining (depth 4) the host sees results 1 to 4 frames
late and keeps a resend window of that size.

### 4.5 `jc_hbm_crc` (200 MHz), `hw/jc/loader/rtl/jc_hbm_crc.vhd`

On a frame with flags bit 0 (and `nwords` 0): reads `range_len` bytes from `hbm_addr`
and computes CRC-32 over them at HBM read speed (16-beat AXI3 reads, no 4 KB
crossings). The result appears in the status word.

### 4.6 Clocking and HBM, `hw/jc/loader/jc_loader_bd.tcl`

BC26 into `clk_wiz`: 200 MHz fabric clock, 100 MHz `HBM_REF_CLK_0/1` and `APB_0_PCLK`,
copying the FK33 arrangement. HBM IP with both stacks and the global addressing
switch enabled, so the single writer port reaches all 8 GB at the manifest's
absolute addresses. The VU35P HBM temperature/catastrophic-trip outputs are wired to
the status word.

## 5. Host side, `tools/jc/coe_load.py`

- Builds on `hw/jc/xvcstream/coe_stream.py` (the CoE client, same start-up sequence,
  txn wrapped below 0x8000).
- **IR allowlist (safety).** The client refuses to shift any IR value other than
  BYPASS, IDCODE, USER3 and USER4. The BSDL lists JPROGRAM and eFUSE-programming
  instructions on the same register; a wrong IR is the only way this tool can do
  lasting harm, so the check is in code and has a teeth test.
- **Manifest, not files, decides addresses.** Pieces come from
  `fk33_load_weights.pieces_of()` (which delegates to `tools/hbm_map.py::file_pieces()`)
  and the same preflight (aligned, in range, single stack, disjoint). Before sending
  a file it checks the file's `blake2b_128` against the manifest; a mismatch aborts.
- Splits pieces into frames, keeps 4 commands in flight, reads each returned status,
  resends from the last committed seq on a CRC or sequence error, and aborts after
  a bounded number of retries.
- Checkpoint file of the last committed seq, so an interrupted 45-minute load resumes.
- Ends with one range-CRC frame per piece, comparing against the CRC-32 computed from
  the (blake2b-verified) file.

## 6. Verification before silicon

1. **`sim/tb_jc_frame_rx.vhd`**: TCK model shifting frames built by a Python
   generator with an independent CRC-32 (`zlib.crc32`); cases: clean frames, a
   flipped payload bit, a flipped CRC bit, a short final frame, a wrong magic (desync
   then resync via Capture), a seq gap, a duplicate seq, the one-bit chain offset,
   and a long run of back-to-back slots with no Capture between them. Checks counted in variables.
2. **`sim/tb_jc_hbm_writer.vhd`**: AXI3 slave model that fails on AWLEN > 15, a 4 KB
   crossing, or partial strobes; checks a failed-CRC frame writes nothing.
3. **Mutation teeth with attribution controls** for both benches: at minimum the CRC
   check removed, the commit gated on the wrong verdict, the 16-beat cap off by one,
   the seq check removed. Survivors reported under their own names.
4. **Host unit tests** (`tools/jc/test_coe_load.py`): framing round-trips against the
   bench's generator, the resync sequence, and the IR allowlist refuses JPROGRAM and every FUSE opcode from
   the BSDL (teeth: the same test with the allowlist disabled must fail).
5. **OOC synthesis and route** of the loader at 200 MHz on `xcvu35p-fsvh2104-2-e`,
   then the full bitstream, BC-250 lane, under the memory rules in CLAUDE.md.

## 7. Verification on silicon (main session only, never a subagent)

1. Load 100 MB of random data to a scratch range; range-CRC must match.
2. **Independent oracle:** read ~1,000 random 256-byte windows back through the
   `jtag_axi` probe (a different BSCAN chain and a different AXI master, ~39 KB/s,
   about 7 s) and compare against the source bytes.
3. Inject faults from the host (corrupt one frame's CRC, skip a seq) and confirm the
   status reports them and the resend repairs them.
4. Full card 0 image to die 0, timed, then range-CRC over every piece, then the
   JTAG-AXI spot check against the manifest's files.
5. Card 1 image to die 1, same checks.

## 8. Open items to settle during implementation

- Which die is nearer TDI on the chain (decides the pad bit in 4.1). Measured at
  bring-up by loading USER4 on one die and BYPASS on the other.
- The debug hub's `JTAG_CHAIN` in the probe build (expected not 4; checked, not assumed).
- Whether the HBM IP accepts a `clk_wiz`-derived reference on the VU35P exactly as
  on the VU33P; the FK33 says yes for the family, the VU35P is unbuilt.
- Whether the BC26 200 MHz input needs `DIFF_TERM_ADV` and `DQS_BIAS` as in the
  vendor XDC (expected yes, copied from `JCCL2-JCM35.xdc`).
- Whether 62-word frames should shrink if the resend window costs more than the
  3.1% framing overhead under real error rates (expected: zero errors, as measured).

## 9. File map

| Path | Kind |
|---|---|
| `hw/jc/loader/rtl/jc_frame_rx.vhd` | new |
| `hw/jc/loader/rtl/jc_hbm_writer.vhd` | new |
| `hw/jc/loader/rtl/jc_hbm_crc.vhd` | new |
| `hw/jc/loader/rtl/jc_loader_top.vhd` | new, wires 4.1-4.5 |
| `hw/jc/loader/jc_loader_bd.tcl`, `build_loader.tcl`, `jc_loader.xdc` | new |
| `rtl/async_fifo.vhd` | reused, unchanged |
| `sim/tb_jc_frame_rx.vhd`, `sim/tb_jc_hbm_writer.vhd` | new gate rows |
| `tools/jc/coe_load.py`, `tools/jc/test_coe_load.py` | new |
| `hw/jc/xvcstream/coe_stream.py` | reused as the client library |
| `hw/fk33/host/fk33_load_weights.py`, `tools/hbm_map.py` | reused, unchanged |
