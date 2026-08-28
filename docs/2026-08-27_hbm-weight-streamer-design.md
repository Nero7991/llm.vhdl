# The HBM weight streamer: the block that reads HBM and feeds subsystem A

**Date:** 2026-08-27. Branch `fpga`, at `adc6fe1`.
**Part:** `xcvu33p-fsvh2104-2L-e`, SQRL FK33, VCCINT 0.717 V MEASURED.
**Answers:** item **N4** of `docs/2026-08-27_weight-path-audit.md` section 10, and
the three requirements A spec section 14.5 defers.
**Depends on:** `docs/2026-08-27_hbm-residency-map.md` (N3) for the address map,
and `docs/debugging/2026-08-27_hbm-port-count-is-a-width-budget.md` for the port
count.

**Labelling.** MEASURED / DERIVED / ESTIMATE on every quantity. **No Vivado was
run.** Two place-and-route jobs were already queued on this machine, so every
resource and timing figure is DERIVED or ESTIMATE and says which.

**Clock assumed.** The design is dimensioned against **`f_core` = 200 MHz** and
verified not to break at the 237.8 MHz synthesis figure. 237.8 MHz is MEASURED
for `matvec_core` at `ROWS_IF = 58`, 0.717 V, out of context
(`sim/ooc_sweep/results.csv:7`); 236.1 MHz at `ROWS_IF = 48` (`:8`). Subsystem
B's emit chain measures 216.5 MHz **post-route**, and A's post-route figure at
`ROWS_IF = 58` is being measured now and may land near 200. **The HBM ACLK is a
separate domain at 300 MHz, MEASURED on the card, and it does NOT derate with
VCCINT** (`hw/fk33/results/hbmbw_30port_300mhz.txt`, and
`docs/debugging/2026-08-25_voltage-derate-on-hardware.md:35-40`). Every place
where those two clocks are confused is called out.

---

## 0. The answer, up front

**Shape:** 27 independent AXI4 read masters on the 300 MHz HBM ACLK, each
feeding one dual-clock FIFO, all 27 FIFO heads concatenated by pure wiring into
one 6,912-bit word popped in lockstep on the core clock. No crossbar, no
scheduler, no width conversion, no reordering. **A spec section 14.5's
"port-to-lane scheduler and more FIFOs than ports" is not needed**, because the
lane count and the port count are made equal by choosing `ROWS_IF = 48` instead
of 58 (see the port-count debugging note).

**Port count: 27 of the 30 available**, and the number is an exact identity
`ROWS_IF x 9 / 16`, not a bandwidth calculation. The streamer must **not** be
designed to sustain 288 GB/s: at `ROWS_IF = 48` and `f_core = 200 MHz` it asks
for **172.8 GB/s** and its 27 ports can supply **259.2 GB/s**, so each port runs
at **66.7% duty**. The surplus is structurally unusable and trying to recover it
is what makes the design complicated for nothing.

**The CDC is the FIFO.** A spec section 14.5 item 3 asks for "a CDC discipline
that does not exist in the DDR4 design". It is a dual-clock FIFO per lane, which
the design needs anyway for latency buffering. There is no separate CDC block.

**The three things that make this NOT a small change to `weight_streamer.vhd`:**
`AXI_DW` doubles to 256 so one lane is two rows and the `ROWS_IF = 4`
lane-equals-row coincidence dies; the module becomes dual-clock; and the
per-lane base addresses collapse from a `NPORTS_W x ADDR_W` descriptor field to
one offset plus a constant arena table.

**No RTL is written by this document, deliberately.** Section 9 says why, and
which four measurements would settle it.

---

## 1. What it has to do, stated from the RTL rather than from prose

`rtl/matvec_core.vhd:275-278` is the whole requirement:

```vhdl
accept <= '1' when st = S_RUN and w_valid = '1' and s_valid = '1' ... ;
w_ready  <= accept;
s_ready  <= accept;
```

The core accepts one word when **both** streams are valid, and it tolerates
bubbles: `rtl/matvec_core.vhd:25-27` says "the compute path is a NON-STALLING
pipeline ... backpressure exists only at the accept point". So the streamer's
only functional obligation is:

> deliver `w_data` and `s_data` **in the packer's order**, with `w_valid` and
> `s_valid` high together, as often as possible, and never out of step.

Everything else is a throughput concern. The **correctness** hazard is
misalignment, not starvation, and A spec section 7.7's 2026-08-22 correction
lists the three mechanisms that produce it silently.

Per core cycle the core wants:

| stream | bits at `ROWS_IF = 48` | source |
|---|---|---|
| `w_data` | `ROWS_IF x BLK x 4` = **6,144** | `rtl/matvec_core.vhd:78` |
| `s_data` | `ROWS_IF x 16` = **768** | `rtl/matvec_core.vhd:81-82` |
| total | **6,912 = 27 x 256** | DERIVED |

---

## 2. Block diagram

```
                      HBM ACLK domain, 300 MHz MEASURED
  +---------------------------------------------------------------------+
  |                                                                     |
  |  desc_sync        ARENA_BASE : constant table, 27 x 33 bits         |
  |  (2-flop + ack)        |                                            |
  |      |                 v                                            |
  |      |      +---------------------------+                           |
  |      +----->| hbm_rd_lane[0]            |--- m_axi[0] ---> SAXI_01  |
  |      |      |   AR gen: base+off, INCR, |                  (MEM00)  |
  |      |      |   ARLEN=15 (512 B)        |                           |
  |      |      |   credit: MAXOUT bursts   |                           |
  |      |      |   drain / flush FSM       |                           |
  |      |      |   +---------------------+ |                           |
  |      |      |   | dual-clock FIFO     | |   <-- THE CDC LIVES HERE  |
  |      |      |   | 256 b x DEPTH       | |                           |
  |      |      |   +---------------------+ |                           |
  |      |      +------------|--------------+                           |
  |      |                   |  (gray-coded pointers)                   |
  +------|-------------------|------------------------------------------+
         |                   |          core clock domain, 200-238 MHz
  +------|-------------------|------------------------------------------+
  |      |                   v                                          |
  |      |            +-------------+                                   |
  |      |            | skid[0]     |  2-deep AXIS register slice       |
  |      |            +------|------+                                   |
  |      |                   |                                          |
  |      |   ... lanes 1 .. 26, identical ...                           |
  |      |                   |                                          |
  |      |          +--------v---------+                                |
  |      |          |   POP GATE       |  all_v = AND of 27 reg'd valids|
  |      +--------->|   (registered)   |  pop = all_v and core_ready    |
  |                 +--------|---------+                                |
  |                          |                                          |
  |          +---------------+---------------+                          |
  |          |                               |                          |
  |   lanes 0..23 -> w_data 6144 b     lanes 24..26 -> s_data 768 b      |
  |          |                               |                          |
  |          v                               v                          |
  |   +-----------------------------------------------+                 |
  |   |             matvec_core (unchanged)           |                 |
  |   +-----------------------------------------------+                 |
  +---------------------------------------------------------------------+
```

`hbm_rd_lane` is a **new** module. It is `rtl/axi_rd_port.vhd` made dual-clock,
and it is new rather than a modification because `axi_rd_port` is owned by the
`ADDR_W`-widening work (N5) and is still the AXU3EG's port. The two must not be
made to share a file.

The merge is **wiring plus one AND gate**. There is no mux, no width converter,
no drain schedule and no reordering, for the same reason rev 4 of A spec section
7.7 gives: the interleave lives in the packer.

---

## 3. Port list

### 3.1 `hbm_weight_streamer`

```vhdl
entity hbm_weight_streamer is
  generic(
    ROWS_IF  : positive := 48;
    BLK      : positive := 32;
    AXI_DW   : positive := 256;   -- HBM SAXI width, rtl/hbm_tg.vhd:92
    ADDR_W   : positive := 33;    -- 8 GiB.  NOT 64: see 3.3
    NLANE_W  : positive := 24;    -- = ROWS_IF*BLK*4 / AXI_DW
    NLANE_S  : positive := 3;     -- = ROWS_IF*16    / AXI_DW
    NLANE    : positive := 27;    -- = NLANE_W + NLANE_S
    DEPTH    : positive := 512;   -- beats per lane FIFO, 16 KiB at 256 b
    MAXB     : positive := 16;    -- beats per burst = 512 B, MEASURED sufficient
    MAXOUT   : positive := 12     -- bursts in flight per lane, see 6.2
  );
  port(
    -- HBM AXI clock domain, 300 MHz
    aclk      : in  std_logic;
    aresetn   : in  std_logic;

    -- core clock domain
    clk, rst  : in  std_logic;

    -- job, core domain.  ONE offset for all 27 lanes: see 4.
    start     : in  std_logic;                                -- one-cycle pulse
    w_off     : in  std_logic_vector(ADDR_W-1 downto 0);       -- 4 KiB aligned
    n_beats   : in  std_logic_vector(31 downto 0);             -- per lane
    busy      : out std_logic;                                 -- job accepted

    -- NLANE AXI4 read masters, flattened, ACLK domain
    m_arvalid : out std_logic_vector(NLANE-1 downto 0);
    m_arready : in  std_logic_vector(NLANE-1 downto 0);
    m_araddr  : out std_logic_vector(NLANE*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector(NLANE*8-1 downto 0);
    m_arsize  : out std_logic_vector(NLANE*3-1 downto 0);
    m_arburst : out std_logic_vector(NLANE*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NLANE-1 downto 0);
    m_rready  : out std_logic_vector(NLANE-1 downto 0);
    m_rdata   : in  std_logic_vector(NLANE*AXI_DW-1 downto 0);
    m_rresp   : in  std_logic_vector(NLANE*2-1 downto 0);      -- NEW, see 7.4
    m_rlast   : in  std_logic_vector(NLANE-1 downto 0);

    -- to matvec_core, core domain, unchanged shape
    w_valid   : out std_logic;
    w_data    : out std_logic_vector(ROWS_IF*BLK*4-1 downto 0);
    w_ready   : in  std_logic;
    s_valid   : out std_logic;
    s_data    : out std_logic_vector(ROWS_IF*16-1 downto 0);
    s_ready   : in  std_logic;

    -- diagnosis.  Without these a shortfall is unattributable, which is the
    -- lesson rtl/hbm_tg.vhd:76-84 records against its own first version.
    dbg_starve_lane : out std_logic_vector(NLANE-1 downto 0);  -- this lane empty
                                                               -- while pop gated
    dbg_beats       : out std_logic_vector(31 downto 0);       -- words popped
    dbg_stall       : out std_logic_vector(31 downto 0);       -- cycles gated
    err_rresp       : out std_logic                            -- sticky, any
  );                                                           -- non-OKAY
end entity;
```

`m_rresp` is new relative to `rtl/axi_rd_port.vhd`, which does not connect it.
`hbm_tg` does check it and the 30-port run reports "zero non-OKAY responses"
because it checks; a weight path that ignores `RRESP` converts an address-decode
fault into wrong numbers rather than an error.

### 3.2 `hbm_rd_lane`

One per lane. `axi_rd_port`'s FSM (`S_IDLE / S_DRAIN / S_FLUSH / S_RUN`) and its
credit accounting carry over unchanged in behaviour; what changes is that the
FIFO is dual-clock and the read side lives on `clk` while everything else lives
on `aclk`.

```vhdl
entity hbm_rd_lane is
  generic(AXI_DW, ADDR_W, DEPTH, MAXB, MAXOUT : positive);
  port(
    aclk, aresetn : in std_logic;                 -- AXI side
    clk, rst      : in std_logic;                 -- stream side
    a_start   : in  std_logic;                    -- ACLK domain, synchronised
    a_base    : in  std_logic_vector(ADDR_W-1 downto 0);
    a_beats   : in  integer;
    -- AXI4 read, ACLK
    arvalid, arready, rvalid, rready, rlast : ...;
    araddr, arlen, arsize, arburst, rdata, rresp : ...;
    -- stream out, core clock
    q_valid : out std_logic;
    q_data  : out std_logic_vector(AXI_DW-1 downto 0);
    q_ready : in  std_logic;
    q_level : out integer                          -- read side, for dbg_starve
  );
end entity;
```

### 3.3 `ADDR_W = 33`, not 64

The audit's hop 10 says `ADDR_W = 32` "cannot address 8 GB". True, and the fix
is **33 bits**, not 64. HBM tops out at `0x1_FFFF_FFFF` and `rtl/hbm_tg.vhd:95`
already uses `ADDR_W : positive := 33`. 64 bits costs 31 bits of adder and
register per lane x 27 lanes for address space that does not exist on this card.

The **file format** keeps 64-bit offsets (spec 6.4 at `tools/pack_int4.py:239`)
because a file outlives a board; the **fabric** truncates on load and the
descriptor register block range-checks. That check is the N8 register block's
job, not the streamer's.

---

## 4. Descriptor to addresses

This is the part that changes most, and it changes in the direction of less
machinery.

**Today** (`rtl/weight_streamer.vhd:53-57`): `NPORTS_W` separate base addresses
plus a separate scale base, all from the header's `w_sub_offset[]` array.

**On the FK33:** one offset, because every lane's sub-region for a given tensor
is the same size and therefore sits at the same offset inside its arena.

```
addr(lane L) = ARENA_BASE(L) + w_off
n_beats(L)   = n_beats                       -- identical for all L

ARENA_BASE(L) = CH(L) x 0x1000_0000          -- constant, from the residency map
CH(L) = L        for L in 0..13              -- SAXI_01..14, stack 0
CH(L) = L + 2    for L in 14..26             -- SAXI_17..29, stack 1
```

`ARENA_BASE` is a **VHDL constant array**, generated alongside the block-design
port connections so the two cannot drift. It is also exposed through the ID
register block so the host can refuse to pair a new image with an old bitstream.

Why this is safe: each lane's sub-region size is
`ceil(tiles x NB x 32 B / 4 KiB) x 4 KiB` and `tiles x NB` does not depend on the
lane. Both facts hold for **all 27 lanes including the scale lanes**, because a
scale lane is a 256-bit slice of the same tile-block word.

**Consequence for subsystem D.** `rtl/seq_desc_fetch.vhd:111-113` defers
fetching "the base array (`nsub_w + nsub_s` 64-bit words at offset 0x40)". With
one offset per tensor, **that array does not need to exist**. N10 shrinks from
"fetch a variable-length array whose length is open" to "fetch one more 64-bit
word", and A section 14.5's dependency on it is discharged.

### 4.1 Lane content, normative for the packer

This is the contract N6 has to implement. Let `W` be the 6,144-bit weight word
and `S` the 768-bit scale word the core consumes at core cycle `t`, in the
existing tile-major order (spec 6.4: for tile `t`, for block `b`, for row `r`).

| lane `L` | carries | in terms of rows |
|---|---|---|
| 0 .. 23 | `W[(L+1)*256-1 : L*256]` | rows `2L` (low 128 bits) and `2L+1` (high 128 bits) of the tile |
| 24 .. 26 | `S[(L-24+1)*256-1 : (L-24)*256]` | scales for rows `16(L-24) .. 16(L-24)+15`, uint16 LE, row `r` at byte `2(r mod 16)` |

Nibble order inside a row's 128-bit chunk is unchanged from spec 6.5: weight `k`
at bits `4k+3 downto 4k`, `k` even in the low nibble of byte `k/2`.

**The `ROWS_IF = 4` lane-equals-row coincidence is now dead.** Spec 6.5 flags it
as load-bearing and says it must not be assumed elsewhere; at `AXI_DW = 256` a
lane is two rows, and the first packer to get this wrong will produce a file that
loads, runs, and returns wrong numbers with the rows of every tile pairwise
swapped in a way that looks like a scale bug.

**The whole-model image is the transpose of the per-tensor files.** Arena `L`
is lane `L` of tensor 0, then lane `L` of tensor 1, and so on in a fixed tensor
order, each 4 KiB aligned. `tools/pack_int4.py` emits per-tensor files; N7's
image builder does the transpose and emits the manifest. Neither exists yet.

---

## 5. The boundary between sub-regions

There are three kinds of boundary and they are handled by three different
mechanisms. Getting them confused is how spec 7.7's 2026-08-22 correction
happened.

**Between jobs (tensor to tensor).** Handled by the drain-then-flush FSM
inherited from `rtl/axi_rd_port.vhd:130-160`, unchanged in principle and
mandatory: a `start` parks the lane in `S_DRAIN`, discards R beats until every
outstanding burst retires, then flushes, then runs, with `q_valid` suppressed
throughout. All three of that section's failure modes apply here identically, and
one is **worse** on HBM: `MAXOUT = 12` bursts of 16 beats means up to 192 beats
to drain per lane against the DDR4 build's 512, so draining is cheaper, but the
27-way version has 27 lanes draining independently and the job is not restartable
until the slowest finishes. `busy` must therefore be the AND of all 27 lanes'
run states, not a single counter.

**Inside a job, at a 4 KiB AXI boundary.** Cannot occur. `MAXB = 16` beats is
512 B, `w_off` is 4 KiB aligned, and `ARENA_BASE` is 256 MiB aligned, so every
burst is 512 B aligned and no burst crosses 4 KiB. This is the reason `MAXB`
drops from `axi_rd_port`'s 256 to 16: 256 beats at `AXI_DW = 256` would be 8 KiB
and **illegal**, and it would have been an easy carry-over.
`hw/fk33/results/hbmbw_30port_300mhz.txt:119` MEASURED 100% of the ceiling at
exactly this burst length, so nothing is lost.

**Inside a job, at a 256 MiB pseudo-channel boundary.** Cannot occur, and this
is a design **invariant that must be asserted**, not a hope:

```vhdl
assert ARENA_SIZE <= 16#10000000#
  report "hbm_weight_streamer: an arena crosses a pseudo-channel boundary; "
       & "the port-local access pattern that measured 288 GB/s no longer "
       & "applies and the 100% efficiency figure is void"
  severity failure;
```

At 9B, `ARENA_SIZE` is 158.3 MiB of 256 (DERIVED, residency map section 4). At
27B N=2 it is 254.6 MiB before alignment and over the bound after, so the assert
fires rather than the design silently degrading. That is the correct behaviour:
N=2 needs a different lane count, and finding out from an assert beats finding
out from a bandwidth shortfall on hardware.

---

## 6. Where back-pressure lives

**Back-pressure is a correctness property wherever a producer cannot be
stalled.** Every interface, with the answer stated rather than implied.

| # | interface | producer | can the producer be stalled? | if not, what makes it correct |
|---|---|---|---|---|
| 1 | HBM `SAXI` R channel to lane FIFO | HBM controller | **yes**, `RREADY` | -- and it never has to be: AR issue reserves FIFO space before the burst is requested, so `RREADY` is high for every beat of an accepted burst in `S_RUN` |
| 2 | lane FIFO write to read (the CDC) | write side | **yes**, `full` | full propagates to item 1 |
| 3 | lane FIFO to skid buffer | FIFO | **yes** | standard valid/ready |
| 4 | skid buffers to pop gate | skid | **yes** | 27-way AND; a lane that is empty stalls all 27 |
| 5 | streamer to `matvec_core` `w_data`/`s_data` | streamer | **yes**, `w_valid` low | `rtl/matvec_core.vhd:25-27`: the pipeline is non-stalling and bubbles cost nothing |
| 6 | `matvec_core` to `w_ready` | core | **yes**, `w_ready` low | the core deasserts it whenever `st /= S_RUN` or `s_valid = '0'`; every lane FIFO absorbs it |
| 7 | **`matvec_core` `y_we` output** | core | **NO.** `y_we`/`y_addr`/`y_data` have no `ready` (`rtl/matvec_core.vhd:88-92`) | the consumer must be a memory that is unconditionally writable. Pre-existing property of A, unchanged here, but it is the one place in A where a stall is a lost result rather than a lost cycle |
| 8 | **activation write `x_we`** | B or C | **NO.** No `ready` (`rtl/matvec_int4.vhd:67-69`) | A must be idle while X is written. Guaranteed by D's schedule, not by the interface. Also unchanged, also a real hazard |
| 9 | **codebook write `cb_we`** | descriptor source | **NO** | "illegal outside idle" (`rtl/matvec_core.vhd:70`) |
| 10 | descriptor registers | host or D | n/a | written while `busy = '0'`; the register block must reject writes otherwise rather than accept them |
| 11 | `start` pulse, core to ACLK | core | n/a | request/acknowledge handshake, not a pulse synchroniser: the ACLK side must confirm all 27 lanes have latched the job before `busy` rises, or a job can start on some lanes and not others |

**Item 11 is the new one and it is the dangerous one.** A two-flop pulse
synchroniser is not sufficient: with 27 lanes it is possible for the pulse to be
captured on some and missed on none only if the pulse is held, and a held pulse
with no acknowledge cannot tell the core when it is safe to change `w_off`. Use
a full four-phase handshake with `w_off`/`n_beats` held stable until `busy`
rises. This is the exact class of bug
`docs/debugging/2026-08-25_voltage-derate-on-hardware.md` records as "the CDC
bugs" in the 350 MHz attempt.

### 6.1 Lane drift: throughput loss, not deadlock

If one lane's FIFO empties while the others are full, item 4 gates the pop and
items 1 to 3 back-pressure the other 26 ports. Correctness is preserved by
construction, because the merge is lockstep and can only ever emit a whole word.

**Deadlock is impossible**: the starving lane has a dedicated port with dedicated
pseudo-channel bandwidth, so it always makes progress. Only throughput is lost,
and only while the slow lane catches up at the surplus rate
`(f_ACLK - f_core) / f_core` = 26% of a beat per core cycle at 237.8 MHz, or 50%
at 200 MHz.

The **rate is set by the slowest lane, always**, not on average. That is why the
residency map recommends port-local addressing and why borrowing the two
smartconnect-backed host ports was rejected: two lanes with different latency
would set the rate for all 27.

### 6.2 FIFO depth and outstanding bursts

DERIVED, and the input is an ESTIMATE:

```
per-lane consumption      = 1 beat per core cycle          = 200e6 beats/s
per-lane supply           = 1 beat per ACLK cycle          = 300e6 beats/s
surplus                   = 100e6 beats/s

to keep the AR pipeline full over a read latency of L ACLK cycles:
  MAXOUT x MAXB >= L
  at L = 150 (ESTIMATE, unmeasured), MAXB = 16   ->  MAXOUT >= 10, take 12

to ride out one HBM refresh without a bubble:
  tRFC ~ 260 ns (ESTIMATE, HBM2 class) = 78 ACLK cycles = 52 core cycles
  DEPTH >= MAXOUT x MAXB + refresh margin = 192 + 52 = 244, take 512
```

`DEPTH = 512` beats is 16 KiB per lane and 442 KiB across 27 lanes, which at the
204 GB/s consumption rate is **2.2 microseconds of runway** against a read
latency believed to be on the order of 100 to 200 nanoseconds. It is generous on
purpose, because the quantity it is sized against has never been measured.

---

## 7. What it costs

### 7.1 Fabric, DERIVED from per-lane estimates

| item | per lane | x 27 | of the VU33P |
|---|---|---|---|
| dual-clock FIFO, 256 b x 512, BRAM36 | 4 | **108** | **16.9% of 640** |
| AR generator, credit, drain FSM (LUT) | ~180 | ~4,900 | 1.1% of ~440K |
| FIFO gray pointers and sync (LUT) | ~90 | ~2,400 | 0.5% |
| 2-deep skid buffer (FF) | 512 | 13,800 | 1.6% of ~880K |
| AR generator and credit (FF) | ~220 | ~5,900 | 0.7% |
| merge: 27-input AND, 6,912-bit concat | -- | ~60 LUT | 0.0% |
| **streamer total** | | **~7,400 LUT, ~20K FF, 108 BRAM36** | |
| `matvec_core` at `ROWS_IF = 48` | | 112,712 LUT, 53,193 FF, 21.5 BRAM | MEASURED, `sim/ooc_sweep/results.csv:8` |
| **subsystem A total** | | **~120K LUT (27%), ~73K FF, ~130 BRAM (20%), 1,584 DSP (55%)** | |

**URAM is deliberately not used for the FIFOs.** URAM288E2 has a single clock
shared by both ports, so it cannot implement an asynchronous FIFO. If measurement
forces `DEPTH` past 1,024 beats, the escalation is a shallow LUTRAM async FIFO
for the CDC followed by a deep synchronous URAM FIFO on the core side, at the
cost of splitting the credit accounting across the domain boundary. Do not plan
on URAM for the dual-clock stage.

### 7.2 Address-map complexity

**Near zero, which is the surprise.** The 27 ports use the address map that is
already in both existing builds: pseudo-channel `n` at `n x 256 MiB`, identical
from every port (residency map section 6). The additions are:

- 27 more `assign_bd_address` blocks in the FK33 build script, mechanically
  identical to `build_fk33_hbmbw.tcl:483-738`;
- one 27-entry `ARENA_BASE` constant, generated with them;
- one host-side assertion that a lane's arena is in the right 4 GiB half.

There is no new address encoding, no translation layer and no per-port window.

### 7.3 Timing, and the one thing that is genuinely hard

The AXI side is not the risk: `hbmbw` closed **300 MHz with 30 masters at
WNS +0.101 ns** on this card (MEASURED). `hbm_rd_lane`'s AR path is comparable
in depth to `hbm_tg`'s.

**The risk is the 6,912-bit merge, which has to cross most of the die.** The
27 lane FIFOs must sit against the HBM interface at the bottom edge, and
`matvec_core`'s 1,584 DSP spread across the DSP columns above them.

**The VU33P is a MONOLITHIC single-SLR device, so there is no Laguna crossing.**
MEASURED by inspection of the Vivado 2023.2 part data: the BSDL for
`xcvu33p_fsvh2104` contains **zero** references to `SLR`, while
`xcvu35p_fsvh2104` contains 35 and `xcvu37p_fsvh2892` contains 55
(`/tools/Xilinx/2023.2/Vivado/2023.2/data/parts/xilinx/virtexuplusHBM/public/bsdl/`).
Multi-die SSI parts declare per-SLR TAP structure there and monolithic parts do
not. It is corroborated by the DSP count: 2,880 on the VU33P against 5,952 on
the two-SLR VU35P, i.e. 2,976 per SLR. **An earlier draft of this document
asserted a two-SLR device and a mandatory SLR crossing; that claim is
withdrawn.** It would have justified floorplanning work that is not needed.

Three design rules still follow, because a long intra-die haul needs the same
elasticity a Laguna crossing would:

1. **No combinational path may run from the pop gate back to a FIFO.** All 27
   valids are registered before the AND, and all 27 readies are registered after
   it. Otherwise the round trip is FIFO-to-gate-to-FIFO across the die.
2. **Latency on the lane path is free; back-pressure latency is not.** Because
   the handshake is elastic, any number of AXIS register slices may be inserted
   per lane. Each costs 512 FF per lane and nothing else.
3. **The pop gate belongs next to `matvec_core`'s accept register**, so the long
   haul carries data and valid one way and ready back through its own slice,
   rather than carrying a 27-way reduction across the die and the answer back.

ESTIMATE: with rules 1 to 3 the streamer does not set the critical path, and the
critical path stays inside `matvec_core` where the 236.1 MHz was measured. That
is an estimate and it is the second most consequential unmeasured quantity here.
It is a weaker worry than it was before the SLR question was settled, but it is
still the one thing only place-and-route can answer.

### 7.4 What the design does NOT cost

- **No crossbar.** A spec section 14.5 item 1 anticipated a port-to-lane
  scheduler with more FIFOs than ports. Choosing `ROWS_IF` so the lane count
  equals an available port count removes it entirely.
- **No width conversion.** Rev 3 of spec 7.7 costed this at ~8 BRAM36 per port
  for the read port alone. Not needed: FIFO width equals lane width equals
  `AXI_DW`.
- **No separate CDC block.** It is the FIFO.
- **No multi-sub-region scale machinery.** A spec section 14.5 item 2 asks for
  it; under the unified lane model scale lanes are lanes and `n_scale_sub`
  becomes `NLANE_S`, popped by the same gate as everything else. The
  `AXI_DW >= SW and AXI_DW mod SW = 0` assertion at
  `rtl/weight_streamer.vhd:107-110`, which fails at any large `ROWS_IF`, does not
  survive into this design because the 2:1 scale unpack it guards
  (`:169-175`) is gone.

---

## 8. Where this lands in the file tree

**`rtl/weight_streamer.vhd` and `rtl/matvec_int4.vhd` are NOT modified.** They
are the AXU3EG's built, timing-closed, silicon-validated path
(spec section 14.4b). `rtl/matvec_int4_axi.vhd` and `rtl/matvec_int4_ip.vhd`
instantiate `matvec_int4` and are owned by other work in flight, so changing
`matvec_int4`'s port list would break them.

New files, none written yet:

| file | contents |
|---|---|
| `rtl/hbm_rd_lane.vhd` | one dual-clock AXI4 read master plus its FIFO |
| `rtl/hbm_weight_streamer.vhd` | 27 lanes, the merge, the descriptor handshake |
| `rtl/fk33_arena_pkg.vhd` | `ARENA_BASE`, `ARENA_SIZE`, `CH()`, generated |
| `rtl/matvec_int4_hbm.vhd` | FK33 top: `matvec_core` + `act_mem_striped` + the above |
| `ref/hbm_weight_streamer.c` | the independent C reference, section 9 |
| `sim/tb_hbm_weight_streamer.vhd` | with an AXI slave model that injects per-lane latency skew |

---

## 9. Why there is no RTL in this commit

The project standard for new RTL is a C reference in `ref/` sharing no
machinery with it, bit-exact verification with no tolerance, and mutation testing
of the reference before the RTL exists. That is a substantial investment, and it
should not be spent on parameters that four pending measurements can move. Three
of the four would change the file layout, which means changing the packer twice
-- the exact failure the audit's N3 ordering exists to avoid.

**What is settled and would not change:** the merge is wiring; the CDC is the
FIFO; scale lanes are lanes; one offset per tensor plus a constant arena table;
`MAXB = 16`; drain-then-flush per lane; the back-pressure table of section 6.

**What is not settled:**

1. **`ROWS_IF`, and therefore `NLANE`, and therefore the pack format.** 48 is
   this document's recommendation and it costs 12.7% of token rate against the
   unbuildable 58. That is a whole-die allocation decision of the kind A spec
   section 15.4c makes, and it should be made explicitly by the project rather
   than implicitly by whoever writes the first file. **This one gates the
   packer.**
2. **A's post-route `f_core` at `ROWS_IF = 48` with the streamer attached.**
   236.1 MHz is out-of-context synthesis of `matvec_core` alone. If post-route
   lands near 200 MHz the port duty falls to 66.7% and nothing else changes; if
   the 6,912-bit merge does not close against a real placement, the design
   changes structurally.
3. **The HBM ACLK ceiling with 27 real readers.** If ACLK ever reaches 2x
   `f_core` the port count halves and `ROWS_IF = 64` fits in 18 ports, which
   would be worth roughly 25% of A's time and would free 9 ports for B and C.
   350 MHz misses by 0.395 to 0.467 ns today
   (`docs/debugging/2026-08-25_voltage-derate-on-hardware.md:244`). **This one
   also gates the packer**, through `NLANE`.
4. **HBM read latency and its jitter across 27 concurrent port-local readers.**
   Sizes `DEPTH` and `MAXOUT`, i.e. the 108-BRAM figure. `hbm_tg` measured
   throughput and `arstall`, never latency (`rtl/hbm_tg.vhd:76-84`). Adding a
   latency histogram to it is small and can run on the existing card.

Items 3 and 4 are measurable on hardware that exists, with an instrument that
exists. Item 2 needs one place-and-route run that must not be started while the
current two are queued. Item 1 is a decision, not a measurement.

**The right next action is item 4 and item 3 on the card, then item 1 as an
explicit decision, then the RTL.** Writing the RTL first would produce a
`ROWS_IF = 48` streamer, a `ROWS_IF = 48` packer and a `ROWS_IF = 48` image
builder that a single ACLK measurement could invalidate together.

---

## 10. What must be measured, consolidated

| # | quantity | how | what it moves | who can run it |
|---|---|---|---|---|
| 1 | HBM read latency and per-lane jitter, 27 port-local readers | add a latency histogram to `hbm_tg`, rebuild `hbmbw` | `DEPTH`, `MAXOUT`, 108 BRAM36 | card, existing instrument |
| 2 | HBM ACLK ceiling with realistic readers attached | `hbmbw` at 350 and 400 MHz | `NLANE`, `ROWS_IF`, the whole port budget | card, one rebuild each |
| 3 | A post-route `f_core` at `ROWS_IF = 48` with 27 lanes attached | one implementation run | whether the 6,912-bit merge closes | needs a free machine |
| 4 | cross-channel sequential read bandwidth | `hbm_tg`'s `rgn_stride`, no rebuild | residency Map A versus Map B | card, Tcl only |
| 5 | actual PCIe link throughput | N2, after N1 | nothing here; the cold load is already a non-issue | card |
| 6 | the 9B tensor list from a real GGUF | obtain the GGUF | `ARENA_SIZE`, section 4 of the residency map | needs the file |

Nothing on this list is blocked by anything else on it.

---

## 11. Corrections

None yet. Append with a date; mark superseded claims withdrawn in place.
