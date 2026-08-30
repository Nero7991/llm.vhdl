# The Y readback: can the engine write results to HBM instead of the keyhole

**Date:** 2026-08-30, 01:05-02:10
**Track:** READBACK
**Tree:** `e0e4fec` (HEAD when this track opened). No RTL was changed by this track.
**Tools:** file reading, `tools/hbm_map.py` (host-only, no card), and arithmetic
over numbers other people measured. **Vivado was NOT run** -- see section 9 for
why, and what that costs this document.
**No hardware was touched:** no `xsdb`, no `hw_server`, no `vivado ... program`,
no `hw/fk33/pcieep.sh` / `jtag.sh` / `flash.sh` / `tcl/*`, no `/dev/xdma*`.
Every card number below was measured by Oren and is attributed where it is used.

---

## 1. The question, verbatim

> **Can the engine write its Y results to HBM so the host reads them by DMA
> instead of by 3.58 million MMIO reads, and what would that cost in area,
> timing and complexity?**
>
> Answer it as a design question with numbers, and implement it only if the
> answer is clean. A well-argued "no, and here is why" is a real result -- do
> not force an implementation to have something to show.

---

## 2. The answer, up front

**Yes, and it is cheaper and larger than the framing assumed, but I did not
build it tonight and section 9 says why.**

Three findings decide it, and two of them were not in the brief.

**(1) The write path already exists, all the way to the die edge.** Every one of
the engine's 28 HBM masters is a full AXI3 interface with AW/W/B channels
declared in `hw/fk33/rtl/fk33_engine.vhd` and connected to `hbm/SAXI_nn` by
`hw/fk33/gen_pcieep.py:835`. Those channels are **tied off in one generated line
per port** (`gen_fk33_engine.py:184-196`, "write channel: permanently idle.
Present only so the interface..."). A Y writeback needs **no new HBM port, no
new pseudo-channel, no block-design change and no `assign_bd_address` change.**
`m27` -- the descriptor master -- is the natural carrier: it is idle from
`S_CHECK` until the next GO, which is exactly the window the writeback runs in.

**(2) The prize is bigger than 7.2 s, because the per-row Python loop dies with
the per-row MMIO.** MEASURED breakdown in section 4: the Y readback is 7.204 s
of MMIO, but the loop that issues it also costs about **4.97 s of Python
interpreter time** on top, and a DMA path deletes the loop, not just the
syscalls. MEASURED against DERIVED, the token is 17.814 s and only **0.56 s of
it is the card computing.**

**(3) The descriptor format does not need to change at all.** Put the Y base in
two new AXI-Lite registers, not in the descriptor. That costs 2 MMIO writes per
job (622 for the whole token, 0.3 ms) and leaves
`tools/gen_mv4i_desc.py` / `ref/mv_fk33_tr` untouched, so the cross-check that
guards every job is not disturbed. Section 8 answers the activations question
the same way and says what to reserve if Oren wants the descriptor route anyway.

**The costed answer:**

| option | token wall | area | risk |
|---|---|---|---|
| today | 17.814 s | -- | -- |
| **(a) Y to HBM, host DMA** | **ESTIMATE ~6 s** (conservative bound 10.6 s) | **ESTIMATE 1.6-2.1K LUT = +1.2-1.6% on the engine's MEASURED 132,065** | congestion, and a fit that COMPOSE4 has not reported |
| (b) host-only MMIO batching | ESTIMATE 13-16 s, UNMEASURED | zero | zero |
| (c) leave it alone | 17.814 s | zero | zero |
| (d) `Y_IDX` auto-increment on `Y_HI` read | 17.04 s | ~40 LUT | register-map semantic change |

**(c) is REFUTED by Oren's DMA sweep** and I did not need to argue it: the fixed
cost of a DMA call is 7.5 us against 413 us of MMIO for the smallest real job.
Granularity is not the obstacle and no cross-job batching is required.

**(b) has never been measured and it is the one thing I want measured before any
RTL is written**, not because it competes with (a) -- it cannot, it leaves the
per-row Python loop in place -- but because it decides whether 1.92 us is PCIe
or syscall, and that number reappears in every future estimate this project
makes. It is twenty minutes and section 10 has the command.

---

## 3. The procedure

Six steps, in order, each a gate on the next. None needed the card.

| step | what it establishes | tool |
|---|---|---|
| 1 | the exact split of the 3,583,291 reads and 3,212,819 writes | `token_chained.log` + the tool's own DERIVED table |
| 2 | whether polling is a large share (it is not) | the residual after step 1 |
| 3 | whether the HBM write channel exists and is routed | `fk33_engine.vhd`, `gen_fk33_engine.py`, `gen_pcieep.py` |
| 4 | where Y lives on-chip and what a writeback would read | `matvec_int4_desc_axi.vhd:414-466, 1049-1090` |
| 5 | whether the descriptor has room, and whether it needs to | `matvec_int4_desc_pkg.vhd`, `docs/2026-08-28_matvec-descriptor-format.md` |
| 6 | where Y lives in HBM and what it displaces | `tools/hbm_map.py` on the shipping manifest |

Step 1 before step 3 is deliberate and it is the control: if polling had turned
out to be a large share of the reads, the cheap fix is the poll loop and no RTL
is justified at all. It is 6.5% of the reads and 2.5% of the token.

---

## 4. Item 1: the read and write breakdown, exactly

**MEASURED** (`hw/fk33/results/token_2026-08-30/token_chained.log`, the tool's own
`Meter`, setup amortised into one process and one open device):

```
MMIO reads     3583291      6.885 s     1.92 us each
MMIO writes    3212819      1.493 s     0.46 us each
token wall    17.814 s
```

**MEASURED**, the same tool's own DERIVED access counts, printed before the run:

```
  activation writes    1536000
  Y index writes       1675264
  Y readback reads     3350528
  of which lm_head      496640
```

**DERIVED**, the reconciliation. This is the whole of item 1:

| class | count | share of its channel | time at the measured rate |
|---|---|---|---|
| `Y_LO` + `Y_HI` reads | 3,350,528 | **93.50% of reads** | **6.4330 s** |
| everything else read (status polls, `Y_EXP`, `CYCLES`/`BEATS`/`STARVED`, `THERM_STATUS`, setup) | 232,763 | 6.50% of reads | 0.4469 s |
| `Y_IDX` writes | 1,675,264 | **52.14% of writes** | **0.7706 s** |
| activation writes | 1,536,000 | 47.81% of writes | 0.7066 s |
| control writes | **1,555** | 0.05% of writes | 0.0007 s |

The reads sum to 6.8799 s against 6.885 s measured and the writes to 1.4779 s
against 1.493 s, both inside the rounding of "1.92" and "0.46".

**The control-write count is the check that this accounting is not a story.**
3,212,819 - 1,675,264 - 1,536,000 = **1,555 = exactly 5 x 311 jobs**:
`DESC_PTR_LO`, `DESC_PTR_HI`, `CTRL`, and two more per job, and not one write
unaccounted across 311 jobs. Nothing else is touching the register file.

**The answer to item 1, in one line:**

> **The Y readback is 2 reads and 1 write per row: 7.2036 s, which is 86.0% of
> all MMIO time and 40.4% of the whole token. Status polling is 232,763 reads,
> 0.4469 s, 2.5% of the token, and it is NOT worth attacking.**

And polling is worth less than even that suggests: those reads are how the host
*waits* for the card, and the card's own compute is 0.56 s (`weight beats
5,187,328` at the MEASURED 21.6 core cycles per beat, 200 MHz). Removing polls
does not make a job finish sooner; it would only replace a busy-wait with a
sleep.

### 4.1 The term nobody had counted: the Python loop

**DERIVED**, and it changes the size of the prize.

The per-job loops account for 13.329 s of the 17.814 s token (`layer wall sum
11.746 s` over 32 layers, plus `1.583 s` over 15 lm_head windows; both summed
from the log). Of that 13.329 s:

```
  Y readback MMIO        7.2036 s
  activation write MMIO  0.7066 s
  poll/status MMIO       0.4469 s
  ------------------------------
  MMIO subtotal          8.357  s   (62.7%)
  residual               4.972  s   (37.3%)
```

The residual is **2.97 us per result row** across 1,675,264 rows. That is the
`fk33_run_job.py:955-963` loop body itself -- three `os.pread`/`os.pwrite` calls,
a dict lookup and a compare, in CPython -- on top of the syscalls it issues.

**This is the finding that inverts the cost/benefit.** Option (a) does not
merely replace 3.35 M reads with one DMA; **it deletes the loop.** Option (b),
whatever it measures, cannot: it still walks one row at a time.

---

## 5. Item 2: what DMA achieves, and what it does not

**MEASURED by Oren, 2026-08-30**, read-only C2H sweep against a weights region
at `0x38204000`, warmed, repeated (his script,
`.../scratchpad/dispatcher_therm/dmasize.py`):

```
    bytes   reps   total s   us/call      MB/s
       64   2000     0.015      7.43       8.6
      512   2000     0.015      7.47      68.5
     1024   2000     0.015      7.69     133.2
     4096    976     0.008      8.37     489.4
     8192    488     0.005     10.53     778.1
    16384    244     0.003     13.80    1187.2
    65536     61     0.003     42.92    1526.8
   262144     15     0.003    219.62    1193.6
  1048576      4     0.004    970.01    1081.0
  4194304      4     0.018   4440.68     944.5
```

**Separated, as the brief asked:**

* **fixed cost per call: ~7.5 us.** Flat from 64 B to 1024 B, still only 8.37 us
  at 4 KB. It dominates below about 8 KB.
* **per-byte cost: best near 64 KB at ~1.5 GB/s**, falling to ~0.94 GB/s at
  4 MB. **Not a single throughput figure**, and the fall-off at large sizes is
  unexplained -- Oren says so and I have not explained it either. For the sizes
  this design uses (185 KB and below) ~1.2 GB/s is the defensible figure.

**Oren's granularity worry is REFUTED by his own data, and I confirm his
arithmetic with one correction.** He assumed 2.14 reads per row by dividing the
total reads by the total rows; section 4 shows the true figure is **exactly 2.00
reads plus 1.00 write per row**, with the non-Y traffic a separate 6.5%. That
makes his per-job comparison slightly *better*, not worse:

* a 96-row job by MMIO: 96 x (2 x 1.92 + 0.46) us = **413 us** (he said ~369 us)
* the same job's Y by DMA: 768 B, deep inside the flat region = **7.5 us**

**55x at the smallest job size.** No cross-job batching is needed and a design
that requires it is more complex than the data justifies.

**What the sweep does NOT settle**, and Oren named all three: it measures the
host side of an existing path; it says nothing about the engine's cost to write
HBM; and it is a read of a region already written, so it carries no information
about the write direction. Section 7 costs the engine side from first principles
and from `axi_rd_port`'s MEASURED OOC number, which is the nearest comparable in
the tree.

---

## 6. Item 3: where Y lives now, and what already exists

### 6.1 On-chip

`rtl/matvec_int4_desc_axi.vhd:421-425`:

```vhdl
type res_t is array(0 to TILES-1) of std_logic_vector(ROWS_IF*64-1 downto 0);
signal res   : res_t;
attribute ram_style of res : signal is "block";
signal res_q   : std_logic_vector(ROWS_IF*64-1 downto 0) := (others => '0');
```

At the FK33 geometry `TILES = ceil(17408/48) = 363`, so `res` is 363 x 3,072
bits = 139 KiB and holds **17,424 rows -- a whole job**, including the largest
one the token has (a 17,376-row lm_head window). It is written unconditionally on
every `y_we` at `:1049-1050`, in **every** `out_mode`. **The results are already
buffered on-chip. Nothing has to be recomputed or re-tapped.**

The read side is `Y_IDX` -> `(yq, yr)` by repeated subtraction (`:1007-1035`,
deliberately no divide), then `res_q` and a 48:1 64-bit lane mux. `res` is a
true dual-port BRAM whose two ports are already spoken for -- one write, one
read -- but **the read port is free during the writeback window** because
`Y_IDX` readback and a DMA writeback are mutually exclusive by construction.
The address mux that time-shares it is 9 bits wide.

### 6.2 Off-chip, to the die edge

MEASURED by reading the generators:

* `hw/fk33/rtl/fk33_engine.vhd:928-943` declares `m27_axi_awvalid/awaddr/awid/
  awlen(3 downto 0)/awsize/awburst`, `wvalid/wready/wdata(255 downto 0)/wstrb/
  wlast`, `bvalid/bready/bid/bresp`. **`awlen` is 4 bits, which is the AXI3 cap
  restated at the port**: 16 beats, not AXI4's 4 KB rule.
* `hw/fk33/rtl/fk33_engine.vhd:1891` and `gen_fk33_engine.py:184-196` tie them
  off: `m27_axi_awvalid <= '0'; ... m27_axi_bready <= '1';`, with the comment
  "write channel: permanently idle. Present only so the interface..."
* `hw/fk33/gen_pcieep.py:835` connects `eng/m27_axi` to `hbm/SAXI_nn` as a
  **whole AXI interface**, and `:898` assigns its address space. Writes use the
  same address space as reads.

**So the only thing standing between the engine and HBM writes is those tie-off
lines.** No SAXI enable, no `SAXI_30`/`SAXI_31` (which stay reserved for B and
C), no BD topology change.

`DUAL_CLK => true` (`fk33_engine.vhd:1171`): the read masters run on `hbm_aclk`
at 250 MHz with per-port async FIFOs. The writeback should mirror that shape
exactly, so the CDC question is one that `rtl/axi_rd_port.vhd` has already
answered and been tested against.

### 6.3 In HBM

MEASURED, `tools/hbm_map.py` on `qwen35-9b-mv4i-stackfix/manifest.json`:

```
| packed weights + F32 blob | 0x0           | 0x1_2d6b_a000 | 5,056,995,328 |
| gdn recurrent state       | 0x1_2f14_6000 | 0x1_3394_6000 |    75,497,472 |
| kv arena 0                | 0x1_3394_6000 | 0x1_ffad_d000 | 3,424,219,136 |
| A descriptor arena        | 0x1_ffad_d000 | 0x1_ffb0_4000 |       159,744 |
| host R_X staging          | 0x1_ffb0_4000 | 0x1_fff0_c000 |     4,227,072 |
| host logits writeback     | 0x1_fff0_c000 | 0x1_ffff_e840 |       993,344 |
| host D program            | 0x1_ffff_f000 | 0x2_0000_0000 |         4,096 |
device 8,589,934,592   accounted 8,589,932,608   unaccounted 1,984
```

**The map is exactly full, and a `host logits writeback` block already exists.**
Two things follow.

* **The lm_head's Y already has an address.** 993,344 B at `0x1_fff0_c000` was
  reserved by `pl_derive_bases()` for precisely this and is consumed by no path
  that exists today.
* **The per-layer jobs need a scratch region and it should be one job deep, not
  one token deep.** The largest job is 362 tiles; at the 512-byte tile stride of
  section 7.2 that is 185,344 B. **A 256 KiB region drained after every job is
  enough**, and 256 KiB is 4 tokens of KV context at the arena's *current*
  reservation. The map itself flags that reservation as **3.765x larger than the
  9B shape needs** ("Over-reservation is SAFE, so this is a note and not a
  fault"), so this is 4 tokens out of 2.4 GiB of acknowledged slack. That is
  where the space comes from and it is not close.

Buffering the whole token instead would need 34,901 tiles x 512 B = 17.87 MB and
274 tokens of context. Not necessary; do not do it.

---

## 7. Item 4: the design, and the alternatives, costed

### 7.1 Option (a): the engine writes Y to HBM

**Control plane -- registers, not descriptor fields.**

```
  0x40 Y_BASE_LO  RW  Y writeback byte address, low 32.  512-byte aligned.
  0x44 Y_BASE_HI  RW  high 32.  Bit at or above ADDR_W latches ERR_ADDR at
                      WRITE TIME, exactly as DESC_PTR_HI already does.
       CTRL bit 1  W  WB_ARM, latched with GO.  0 = today's behaviour exactly.
       STATUS      R  a new bit: writeback complete.
```

`Y_BASE = 0` means "no writeback", so a host that never writes the register gets
byte-identical behaviour to today. That is the same shape as EGRESS's
`SMP_EN` and it is what makes this safe to land ahead of the host tooling.

**Data plane.** At `S_DONE`, if armed, walk tiles `0 .. ceil(n_rows/48)-1`:
read `res(t)` through the existing read port, register into the existing
`res_q`, then emit 12 beats of 256 bits (4 rows each) into a 256-bit async FIFO,
which an AW/W/B FSM on `hbm_aclk` drains onto `m27`'s write channel.

**The 4 KB rule, met by alignment rather than by a splitter**, which is the
argument `DESC_ALIGN` already makes in this same file (`:246-252`):

> one burst per tile, `AWLEN = 11` (12 beats, 384 B), at
> `Y_BASE + t * 512`, with `Y_BASE` 512-aligned.

A 384-byte burst starting at a 512-aligned address lies inside that 512-byte
block, and a 512-byte block lies inside one 4 KB page. `AWLEN = 11` fits AXI3's
4 bits with 4 to spare. No splitter, no padding written, 25% of the address
space unused and nothing else spent.

**The host layout is then trivially checkable**: row `r` is at byte
`Y_BASE + (r/48)*512 + (r%48)*8`, and the host knows `n_rows` independently.

**`done` must not rise until the last `BRESP`.** Otherwise the host DMAs a
partial image. This is the DONE-1 class of defect exactly -- a completion signal
that does not belong to the work it appears to describe -- and that defect has
already been found once in this file (`:293-310`, the three-clock window where
STATUS reported the previous job's `done`). Gate `done` on writeback completion
when armed. **Cost:** 362 tiles x 12 beats at 250 MHz = 17 us for the largest
job. Against 413 us of MMIO for a 96-row job, it is free.

**Area, ESTIMATE, with its anchor stated:**

| part | LUT | FF | BRAM36 |
|---|---|---|---|
| AXI3 write port, mirror of `axi_rd_port` (MEASURED 550 LUT / 287 FF / 4 BRAM36 at `DUAL_CLK=1, MAXOUT=16`, 256-bit, `sim/ooc_fk33a/results.csv`) | 550-700 | ~300 | 4 |
| 3,072 -> 256 serialiser off the existing `res_q` (256-bit 12:1 mux) | 800-1,100 | ~40 | 0 |
| tile/beat counters, FSM, address adder | ~150 | ~80 | 0 |
| two AXI-Lite registers + decode + `ERR_ADDR` at write time | ~120 | ~70 | 0 |
| **total** | **1.6-2.1K** | **~490** | **4** |

**Against MEASURED context** (`hw/fk33/results/congestion_2026-08-29/placed_util_engine.rpt`,
Fully Placed, `xcvu33p`): the engine is **132,065 CLB LUT**, 63,733 FF, 192.5
BRAM tiles, **0 of 320 URAM**. So this is **+1.3-1.6% on the engine** and
**+0.36-0.48% of the device's 439,680 LUT**. The 4 BRAM36 can be URAM instead; 320
URAM are untouched.

**Two cheaper shapes exist and both are worth knowing.**

* **`res` as 256-bit words.** If `res` were `array(0 to TILES*12-1) of
  std_logic_vector(255 downto 0)`, the writeback needs **no mux at all** -- just
  an address counter -- and the existing `Y_IDX` path's 48:1 mux shrinks to 4:1.
  That is a **net area REDUCTION** of roughly 800-1,000 LUT against today, not an
  addition. The cost is 12 write cycles per tile instead of 1, absorbed easily
  (`y_we` fires at most once per `nblk` = 128 cycles at K=4096), and the risk is
  that it rewrites the currently-shipping, bit-exact `Y_IDX` read path. **Do not
  bundle it with the writeback; it is a separate, independently verifiable
  change and it should be measured on its own.**
* **URAM for `res`.** EGRESS records 43 BRAM36 for this buffer, citing
  `congest_hier_util.rpt:384` -- **a file that is not in the tree**, so I could
  not verify it and it is quoted here as EGRESS's number, not as a MEASURED one.
  What IS measured is that the engine holds 192.5 BRAM tiles and **0 of 320
  URAM**. Not this track's business, but it is free headroom sitting next to the
  thing being changed.

**Timing.** MEASURED by BITPREP, the shipping flow closes at **WNS +0.069 ns**,
and `3ecc729` already added a combinational path from the AXI-Lite write
handshake into the descriptor FSM. This design **does not touch that path**:
`go_now` decodes CTRL bit 0 and the new register writes are a parallel decode
that does not lengthen it. The serialiser is register-to-register in the core
domain with one mux level. The real risk is not the arithmetic, it is placement:
the new logic sits beside `res`, in `matvec_int4_desc_axi`'s ~13,997 LUT of
wrapper, **not inside `matvec_core`**, which is 118,068 of the engine's 132,065
LUT and is 72-81% of every level-6 and level-7 congestion window in the build
that failed to route. That distinction is the whole of the reversal trigger the
Decisions table records for the egress decision, and this design lands on the
right side of it. **It is an argument, not a measurement, and section 9 says so.**

**Token wall.**

* **Conservative bound**, assuming only the MMIO goes and the host still walks
  rows: 17.814 - 7.204 + 0.020 (311 DMA calls at 7.5 us plus 17.9 MB at ~1.2
  GB/s, or 0.3 ms if drained per job at 185 KB) + 0.0003 (622 arm writes) =
  **10.63 s. DERIVED.**
* **Realistic**, assuming the per-row Python loop of section 4.1 goes with it and
  is replaced by a bulk compare of 13.4 MB: 17.814 - 7.204 - ~4.5 + ~0.07 =
  **~6.2 s. ESTIMATE**, and the assumption is that the host tool is rewritten to
  compare in bulk rather than per row. If it is not, the conservative bound is
  what you get.

### 7.2 Option (b): batch the existing MMIO better, no RTL

**The register map forecloses the obvious form of this, and that is worth
stating because it is the first thing anyone will try.** `Y_IDX` is *state*: the
sequence is write-then-read-twice, so two threads cannot have two BAR reads in
flight without racing on the shared index register. **Multi-threading the
readback to overlap PCIe latency is impossible without an RTL change.** The
keyhole is not merely narrow, it is stateful.

What is left is reducing the cost of each access, and it has never been measured:

* **`Mmio.rd` is `os.pread(fd, 4, off)` -- a syscall per 32-bit read**
  (`fk33ctl.py:127-131`), not an `mmap` load. Nobody has measured how much of
  the 1.92 us is the syscall and Python and how much is the PCIe round trip.
* **`Y_LO` is at `0x28`, which is 8-byte aligned, and `Y_HI` is at `0x2C`.** A
  single 8-byte access covers both. Even if the driver still issues two
  `ioread32`s, that is one syscall and one Python call instead of two.
* `Y_EXP` at `0x30` makes a 12-byte read cover all three.

**ESTIMATE, with the assumption stated:** if the syscall-plus-interpreter term is
~0.9 us of the 1.92 us, an 8-byte read costs ~2.9 us instead of 3.84, saving
1.51 s -> **16.30 s**. If `mmap` works and a 64-bit load is a single TLP, reads
could approach ~1.0 us each and the saving is ~4.75 s -> **~13.0 s**. Both are
guesses about a number that takes twenty minutes to measure; section 10 has the
command.

**Option (b) cannot reach option (a) and it is not trying to.** It leaves the
1,675,264-iteration Python loop and its 4.97 s in place. Its value is that it is
free, it is available tonight, and **the number it produces is reused by every
future estimate in this project.**

### 7.3 Option (c): leave it alone

**REJECTED, and not by me.** Oren's sweep settles it: the fixed DMA cost is
7.5 us against 413 us of MMIO for the smallest real job (96 rows). The
per-transfer cost does not dominate at this granularity and it is not close.

### 7.4 Option (d): `Y_IDX` auto-increments on a `Y_HI` read

Not in the brief, and it is the cheapest RTL change that does anything: an
increment on the `Y_HI` read handshake removes 1,675,264 `Y_IDX` writes, 0.771 s,
**4.3% of the token, for perhaps 40 LUT.** It also removes the
`(yq, yr)` repeated-subtraction restart on every row, which today costs
`floor(Y_IDX/48)` cycles per new index (`:448-451`) -- a term nobody has counted.

**It is not recommended as a destination**, because it changes the semantics of a
register map whose whole stated virtue is being constant, and it needs a matching
change in `fk33_regs.h` and both host tools. It is recorded because if option (a)
is deferred for a quarter, this is 4.3% for almost nothing.

---

## 8. The descriptor, and whether this forecloses the activations

**Asked by Oren mid-track, and the answer is: nothing needs reserving, because
the design proposed here does not touch the descriptor at all.**

**First, a correction to the numbers in the request.** The token's 3,212,819
MMIO writes are **not** all activations. Section 4: 1,675,264 of them are
`Y_IDX`, 1,536,000 are activations and 1,555 are control. So the activation
write cost is **0.7066 s, not 1.478 s**, and a bulk X path is worth **one tenth
of what the Y path is worth**, not half. The per-job figure in the request is
right (4,096 elements x 0.46 us = 1.88 ms; the token averages 4,939 elements per
job), it is the token total that doubled by including `Y_IDX`.

**Why the register route is the right one for both.** A Y base is a host-chosen
destination that changes once per job and costs 2 MMIO writes to set. Putting it
in the descriptor buys nothing and costs a version bump of a format that two
independent authorities cross-check on every job. The same is true of an X base,
and more so: **in the eventual D-sequenced design the activation for job n is
job n-1's output and never has a host-chosen address at all.** A descriptor field
for X would be a field that exists only for the host-tool era.

**If Oren wants the descriptor route anyway, here is the room, and it is not
enough for both.** MEASURED from `rtl/matvec_int4_desc_pkg.vhd` and
`docs/2026-08-28_matvec-descriptor-format.md:186-193`:

* **ext word 3** (`E + 0x18`) is a full 64-bit `PAD, must be 0`.
* **ext word 2 `[63:32]`** is a 32-bit pad half.
* Both are already checked -- a nonzero value raises `ERR_DESC` sub-case 5
  `ED_PAD_EXT` -- so a v1 gateware would **refuse** a descriptor carrying a base,
  which is the correct failure mode and is free forward-compatibility teeth.

That is 1.5 free words. **Y needs one and X needs one, so they do not both fit**,
and a descriptor route would have to grow `DESC_EXT_WORDS` from 4 to 5 or 6 --
which moves `desc_words()`, the descriptor length, the beat count and the
`EI_WORD_FITS` guard, in both authorities. **If that is the route, do BOTH fields
in ONE bump of `MV4I_DESC_VER` to 2.** Doing them separately breaks the
cross-check twice, which is precisely the outcome the request exists to avoid.

**One more piece of symmetry worth recording:** an X-in path is an AXI *read*
master and a Y-out path is an AXI *write* master, and **`m27` can carry both**.
Its read channel is busy only during the descriptor fetch at job start and its
write channel only after `done`. Neither needs a new port.

---

## 9. Why I did not implement it

Three reasons, in descending order of weight. The first is the binding one.

1. **I cannot measure the area, and the brief says the area is a first-class
   result.** MEASURED at the start of this track: root filesystem 91% with 126 G
   free, RAM 31 G with **0 G free and 21 G of swap in use**, load average 4.54,
   and **TRACK COMPOSE4's place-and-route has been running over an hour**.
   BITPREP MEASURED a full `pcieep` build at a 25.0 GiB peak. An OOC synthesis
   for the writeback would compete with COMPOSE4 for memory that is not there,
   and the brief forbids starting a full build. **An implementation whose area I
   cannot state is exactly the unmeasured thing this project's verification
   discipline exists to refuse.**
2. **COMPOSE4 has not reported and it owns the constraint that decides this.**
   B+C+D compose to 217,381 LUT against 233,765 free in `pb_core`, and the fit is
   not settled. Adding 1.6-2.1K LUT to subsystem A is 0.36-0.48% of the device and
   10-13% of that remaining headroom -- affordable if the fit holds and irrelevant
   if it does not.
3. **The free measurement in section 7.2 has not been taken.** It cannot change
   the direction of the answer, but it is twenty minutes and it calibrates a
   number (`1.92 us`: PCIe or syscall?) that this project has now quoted in four
   documents without ever decomposing.

**What I would build, in order, when the fit is known:**

1. `Y_BASE_LO`/`Y_BASE_HI`/`WB_ARM` and the writeback FSM in
   `rtl/matvec_int4_desc_axi.vhd`, behind `Y_WB_EN : boolean := false` so the
   default is byte-identical to today.
2. `sim/tb_matvec_y_wb.vhd` with an AXI3 write-slave model, and the mutation
   table of section 11.
3. An OOC synthesis of `matvec_int4_desc_axi` with `Y_WB_EN` false and true, and
   report the delta. That is the area number this document is missing.
4. Only then the `gen_fk33_engine.py` untie-off, which is one line per channel on
   `m27`, and the host side, which is Oren's.

---

## 10. Commands for the card. Each says what it prints

**None of these writes anything to HBM.** Step 3 is the only one that would, and
it is written as a proposal with its offset argued, not as a command to run now.

### 10.1 Decompose the 1.92 us: is it PCIe, or is it the syscall?

This is the measurement of section 7.2, and it is the one I most want. It reads
only `0x12028..0x1203C` (`Y_LO`, `Y_HI`, `Y_EXP`, `CYCLES`, `BEATS`, `STARVED`),
all read-only, all side-effect free. It writes nothing anywhere.

```bash
python3 - <<'PYEOF'
import os, time, struct, mmap
USER = "/dev/xdma0_user"
BASE = 0x12028                      # FK33_ENG_Y_LO; 0x28..0x3C are read-only
fd = os.open(USER, os.O_RDWR | os.O_SYNC)

def bench(fn, reps):
    fn()
    t0 = time.perf_counter()
    for _ in range(reps):
        fn()
    return (time.perf_counter() - t0) / reps * 1e6

print("A. pread, one syscall per call")
for n in (4, 8, 12, 16, 24):
    print("   %2d B   %6.3f us" % (n, bench(lambda n=n: os.pread(fd, n, BASE), 20000)))

print("B. the Python-only control -- same calls against a bytearray, no card")
buf = bytearray(64)
print("   unpack <I  %6.3f us" % bench(lambda: struct.unpack_from("<I", buf, 0), 200000))
print("   unpack <Q  %6.3f us" % bench(lambda: struct.unpack_from("<Q", buf, 0), 200000))
print("   loop floor %6.3f us" % bench(lambda: None, 200000))

print("C. mmap of the BAR, if the driver allows it")
try:
    m = mmap.mmap(fd, 0x13000, prot=mmap.PROT_READ | mmap.PROT_WRITE)
except Exception as e:
    print("   mmap REFUSED: %s" % e)
    print("   -> the syscall is unavoidable; option (b) is limited to wider preads")
else:
    print("   load  <I  %6.3f us" % bench(lambda: struct.unpack_from("<I", m, BASE), 20000))
    print("   load  <Q  %6.3f us" % bench(lambda: struct.unpack_from("<Q", m, BASE), 20000))
    print("   slice 8 B %6.3f us" % bench(lambda: m[BASE:BASE+8], 20000))
    print("   Y_LO=%08x Y_HI=%08x  as <Q: %016x"
          % (struct.unpack_from("<I", m, BASE)[0],
             struct.unpack_from("<I", m, BASE+4)[0],
             struct.unpack_from("<Q", m, BASE)[0]))
    m.close()
os.close(fd)
PYEOF
```

**What each block establishes.**

* **A** is the workload as it exists. The 4 B row should reproduce ~1.92 us; if
  it does not, the token's `Meter` and this bench disagree and that is the first
  thing to explain, not to explain away.
* **A at 8 B against A at 4 B is the whole question.** If 8 B costs the same as
  4 B, the PCIe round trip is not the cost and **option (b) is worth ~1.5 s for
  free**. If 8 B costs twice 4 B, the round trip *is* the cost, option (b) is
  worth almost nothing, and **that strengthens the case for option (a).** Either
  outcome is decision-relevant, which is why it is worth twenty minutes.
* **B is the attribution control** and it is the part that is easy to omit. It
  measures the CPython cost of the same call shapes with no card in the path, so
  the A rows can be corrected rather than believed. Without it, a 1.92 us pread
  and a 1.4 us mmap load cannot be told apart from an interpreter artefact.
* **C** tests whether `mmap` on `/dev/xdma0_user` is permitted at all, and
  whether an aligned 64-bit load returns `(Y_HI << 32) | Y_LO`. The last printed
  line is the correctness check on that: the `<Q` value must equal the two `<I`
  values concatenated, or the 64-bit path is not returning what it appears to.

### 10.2 The small-transfer C2H shape, if you want the fall-off explained

Your sweep's non-monotonic tail (1.53 GB/s at 64 KB down to 0.94 GB/s at 4 MB)
is the one number in it I cannot use confidently. Re-running it with the fd
opened **once** outside the loop, rather than `fk33ctl.dma_read`'s open/close per
call, would say whether the 7.5 us fixed term is the driver or the two syscalls,
and whether the tail is a descriptor-chain effect:

```bash
python3 - <<'PYEOF'
import os, time
C2H = "/dev/xdma0_c2h_0"
OFF = 0x38204000                    # the same warmed weights region you used
fd = os.open(C2H, os.O_RDONLY)
print(" bytes    us/call    MB/s    (fd opened ONCE, outside the loop)")
for n in (64, 256, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304):
    reps = max(4, min(2000, (1 << 22) // n))
    os.pread(fd, n, OFF)
    t0 = time.perf_counter()
    for _ in range(reps):
        os.pread(fd, n, OFF)
    us = (time.perf_counter() - t0) / reps * 1e6
    print("%7d   %8.2f  %7.1f" % (n, us, n / us))
os.close(fd)
PYEOF
```

**What it prints:** the same curve with the per-call `open`/`close` removed. If
the fixed term drops well below 7.5 us, most of it was the two syscalls and a
production host that holds the fd open pays less than your sweep suggests --
which makes option (a) better still.

### 10.3 An H2C offset I am prepared to argue, NOT a command to run now

You said you will not pick the offset and I should. **I am not asking you to run
an H2C sweep as part of this track** -- the Y path is a read path and section 5
already settles it. If a write sweep is wanted later, here is the offset and the
argument:

> **`0x1_fff0_c000`, length capped at 993,344 B** (`0x1_fff0_c000` ..
> `0x1_ffff_e840`).

**Why it is scratch.** `tools/hbm_map.py` -- the one whole-map model, and the
only thing in the tree that can see all three allocators at once -- names that
block `host logits writeback`, placed by `pl_derive_bases()`. It is disjoint by
construction from the packed weights (which end at `0x1_2d6b_a000`), the GDN
recurrent state, the KV arena, the A descriptor arena at `0x1_ffad_d000`, and
host `R_X` staging, and `hbm_map.py` prints `PASS every region is aligned, in
range, in one stack, and disjoint across all 3 allocators`. **Nothing that exists
today reads or writes it**: the logits egress path it was reserved for is the
thing this document is about, and the token run reads logits through
`Y_LO`/`Y_HI`, not from HBM.

**What re-establishes state if I am wrong.** Nothing in that block needs
re-establishing, because nothing reads it. If the offset or the cap were wrong,
the two regions it could reach are `host D program` (4,096 B, also unused today)
above and `host R_X staging` below, and it cannot reach the descriptor arena at
all -- the arena is 4,227,072 B further down and the cap forbids it. If weights
were somehow touched, `hw/fk33/host/fk33_load_weights.py --verify` re-checks them
against the manifest and a plain reload rewrites them, at the H2C rate of
3.27 GB/s for 4.7 GiB. **Run the map first and read its PASS line, every time,
before any write sweep:**

```bash
python3 tools/hbm_map.py /mnt/storage/llama-models/qwen35-9b-mv4i-stackfix/manifest.json --markdown
```

**What it prints:** the seven-region table quoted in section 6.3 and a final
`PASS`/fault line. If that line is not `PASS`, the offset argument above is void
and no write sweep should run.

---

## 11. If option (a) is built: the checks it must have, and the trap it walks into

**A round trip is not an oracle, and here it bites harder than usual**, because
the DMA is no longer just moving bytes -- it is carrying the thing under test.
`fk33_run_job.py` already says this about its own descriptor check. What saves it
is that the *values* are still compared against `ref/run9b`'s independent stream,
which is unchanged. So the failure this design newly exposes is not "wrong
values undetected", it is **"a stale image passes because the reference happens
to match it"** -- the same job's previous run, or the previous job's tail.

**The check that has teeth: poison before arm.** The host writes a known pattern
over the Y scratch region before each job and refuses any row that still carries
it. **And the attribution control is mandatory**: the same stale-image mutant
with poisoning disabled. If the mutant dies without poisoning, an older check
already caught it and the poison is decoration. That control is the thing
CLAUDE.md records a track getting wrong on 2026-08-29, crediting a new check with
four kills when three were its own.

**Mutations the bench must run, with the two that I expect NOT to bite named
under their own headings**, because a mutation that does not bite measures the
check's resolution floor and is the most valuable row in the table:

| mutation | expected | what it tests |
|---|---|---|
| one mantissa wrong in the DMA image | FAIL | the value comparison still reaches the DMA path |
| the writeback runs one tile short | FAIL | `n_rows` -> tile-count arithmetic |
| tile stride 384 instead of 512 | FAIL | the host and gateware agree on the padded layout |
| `done` rises before the last `BRESP` | FAIL, and INCONCLUSIVE without poisoning | the DONE-1 class, restated for the write path |
| the previous job's image is left in place and the writeback never runs | FAIL only WITH poisoning | the stale-image trap; **this is the row the attribution control is for** |
| `AWLEN` raised to 15 (16 beats, 512 B) | **expected NOT to bite** | it is still legal AXI3 and still inside one 4 KB page; the bench cannot see the difference, and that is a resolution floor, not a pass |
| `Y_BASE` misaligned by 8 bytes | **expected NOT to bite unless an alignment check is added** | the burst still lies inside a 4 KB page at that offset, so the 4 KB rule is not violated and nothing downstream notices; if the design wants alignment enforced it needs an explicit `EC_ALIGN` raise, which is why this row exists |

---

## 12. Measured and REJECTED -- do not retry

* **Multi-threading the MMIO readback to overlap PCIe latency.** REJECTED on the
  register map, not on measurement: `Y_IDX` is state, so two threads cannot hold
  two reads in flight without racing on it. There is no host-side concurrency
  fix. (`matvec_int4_desc_axi.vhd:50-52`, `fk33_run_job.py:955-958`.)
* **Attacking the status polling.** REJECTED by section 4: 232,763 reads,
  0.4469 s, 2.5% of the token, and those reads are the host waiting for 0.56 s
  of real card compute. Removing them replaces a busy-wait with a sleep and saves
  nothing.
* **Batching Y across jobs to amortise the DMA fixed cost.** REJECTED by Oren's
  sweep: 7.5 us fixed against 413 us of MMIO for the smallest real job. It would
  work, and it is unnecessary complexity.
* **Buffering the whole token's Y in HBM (17.87 MB).** REJECTED in favour of a
  256 KiB region drained per job: 185,344 B is the largest job, and 17.87 MB
  costs 274 tokens of KV context for nothing.
* **A descriptor field for the Y base.** REJECTED in favour of two AXI-Lite
  registers: it costs 622 MMIO writes per token (0.3 ms) and leaves
  `tools/gen_mv4i_desc.py` and `ref/mv_fk33_tr` untouched. See section 8 for what
  to do if it is wanted anyway.
* **Enabling `SAXI_30`/`SAXI_31` for the writeback.** REJECTED as unnecessary:
  `m27`'s write channel is already routed to an enabled port and is idle in
  exactly the window the writeback needs. The two spare pseudo-channels stay
  budgeted for B and C (`gen_pcieep.py:273`).
* **Reading the token log's per-layer wall as the readback cost.** REJECTED as a
  method: it bundles the Python loop with the MMIO, and section 4.1 exists
  because separating them changed the answer by 4.97 s.

---

## 13. Measurement traps hit, including my own

* **I nearly inherited "2.14 reads per row".** It is the total reads divided by
  the total rows, which folds status polling and setup into the per-row figure.
  The true figure is exactly 2 reads and 1 write per row, and the residual is a
  separate 6.5%. The tell that the corrected accounting is right is that the
  control writes come out at **exactly 5 x 311**, and nothing about the wrong
  version would have produced that.
* **"3,212,819 MMIO writes are activations" is wrong by 2.1x.** Only 1,536,000
  are; 1,675,264 are `Y_IDX`. A bulk X path is worth 0.71 s, not 1.48 s.
  Corrected in section 8, and it changes the priority between the two paths from
  2:1 to 10:1.
* **The 4.97 s Python residual is DERIVED by subtraction and it is the softest
  number here.** It is `sum(layer wall) + sum(window wall) - MMIO`, so anything
  the tool does inside those loops that is neither MMIO nor interpreter overhead
  lands in it. It is large enough to matter and I have not isolated it directly;
  a `cProfile` of one layer would.
* **`cmd_bench` in `fk33ctl.py` WRITES `os.urandom` to the offset before reading
  it.** Oren avoided it deliberately for the sweep and said so. Anyone reaching
  for the built-in benchmark to measure C2H would clobber weights.
* **One citation I inherited points at a file that does not exist.**
  `docs/debugging/2026-08-29_logits-egress.md` sources the "43 BRAM36 result
  buffer" figure to `congest_hier_util.rpt:384`. There is no such file anywhere
  in the tree (`find . -name congest_hier_util.rpt` is empty). The number may
  still be right -- it was presumably read off a report that was not kept -- but
  it is not checkable, and I have relabelled it in section 7.1 rather than pass
  it on as MEASURED. **A citation is only as good as the artefact surviving.**
* **`report_utilization -cells bd_i/eng` is the engine, not the wrapper.** The
  132,065 LUT figure includes `matvec_core`'s 118,068. The wrapper that holds
  `res` is the ~13,997 LUT difference, and quoting the engine figure as "the
  block the writeback lands in" would overstate the congestion argument by 9x.

---

## 14. Open, not yet answered

* **The area number.** ESTIMATE 1.6-2.1K LUT is anchored on `axi_rd_port`'s
  MEASURED OOC result and nothing else. No synthesis was run. Section 9 says why.
* **What it does to routing.** The argument that the writeback lands in the
  wrapper rather than in `matvec_core` is read off a hierarchy report, not off a
  placed design with the writeback in it. The egress decision's own stated
  reversal trigger is "if the writeback is ever measured to add materially to
  `matvec_core`'s congestion", and this document does not measure that.
* **Whether 1.92 us is PCIe or syscall.** Unmeasured. Section 10.1.
* **Why C2H throughput falls from 1.53 GB/s at 64 KB to 0.94 GB/s at 4 MB.**
  Unexplained by Oren and unexplained by me. Section 10.2 is a first cut.
* **The engine's HBM WRITE cost.** Every HBM number in this tree is a read
  number. `hbmbw_readwrite.txt` has a write figure (32 B/beat, 9.6 GB/s) but no
  latency, and the writeback's 17 us for the largest job is DERIVED from beat
  counts at 250 MHz, not measured.
* **Whether `res` should be 256 bits wide.** Section 7.1 argues it would make the
  writeback free and shrink the existing lane mux -- a net area reduction. It is
  a change to a shipping, bit-exact read path and nothing has measured it.
* **The 21.6 core cycles per weight beat.** The card's own compute is 0.56 s
  against an ideal 25.9 ms at one beat per cycle. That is a 21.6x gap that this
  document only walked past. It is invisible today because the host is 30x slower
  still; the moment option (a) lands and the token reaches ~6 s, **the card's own
  starvation becomes the second-largest term.** Nothing here investigates it.
* **What a second token costs.** Unchanged from the token document: nothing here
  exercises a growing KV cache or a changing position.
