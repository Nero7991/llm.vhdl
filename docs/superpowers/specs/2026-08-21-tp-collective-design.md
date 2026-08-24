# Subsystem E: Tensor-Parallel Collective

Design spec, 2026-08-21. Milestone `v2.3`.

**STATUS: sections 1-2 only. Section 3 (transport bring-up, failure handling,
validation, acceptance criteria) is deliberately unwritten**, pending review of
this foundation.

## 1. Context and scope

Tensor parallelism splits every matvec across N cards. Column-parallel splits
(by output dim) need no communication. **Row-parallel splits (by input dim) leave
each card holding a partial sum that is meaningless until reduced across all
cards.** Subsystem E performs that reduction.

Per `docs/fpga-hardware-recon.md`: `v3.0` is the 27B on **N=2** FK33s, `v4.0` on
**N=8**. E must serve both.

### 1.1 Why this is a subsystem and not a detail

Three all-reduces per layer would be a detail. **Two per layer across 64 layers
is 128 collectives per token**, and at 20 KB per message the operation is
**latency-bound, not bandwidth-bound**. That inverts the usual intuition and it
determines the algorithm, so it needs designing rather than assuming.

The FK33 has **no QSFP** (confirmed from its XDC: the entire board I/O is
`SYSCLK0_200`, `MAIN_I2C`, 7 LEDs, `PCIE_PERST`, `PCIE_100MHZ_CLK` and
`PCIE_RX/TX[15:0]`). So the transport is PCIe peer-to-peer, and **all cards must
sit behind a common PCIe switch** -- crossing root complexes kills P2P, which is
the `CNS` result this workstation already sees between its own two GPUs.

### 1.2 Scope

**In scope:** the reduction algorithm, the P2P transport and its synchronization,
the numeric contract for summing partials, the final BFP normalization that
subsystem A defers, and the overlap discipline of §2.5.

**Out of scope:** which matvecs are row- vs column-parallel (subsystem A §14.3),
sequencing and barriers across a whole layer (**subsystem D**), PCIe enumeration
and BAR assignment (the PS, at boot), and prefill.

### 1.3 What arrives from subsystem A

A's `out_mode = "10"` (A §14.2) emits, per output row:

```
y_data[r] = sat32( round_shift(acc[r], out_shift) )     -- s32, NOT normalized
y_exp     = w_exp + x_exp - out_shift
```

**The normalization is deferred precisely because it cannot be done locally**:
BFP packing needs `amax` over the final result, and a partial's maximum is
unknown until after the reduction. E therefore owns the pack.

**All N cards in one collective MUST have been programmed with the same
`out_shift`.** That is what makes the partials directly summable as plain s32
integers with no per-card alignment, and it is why the reduction is an integer
add rather than a floating-point merge. Violating it produces silently wrong
results, so §2.6 makes it a checked precondition.

## 2. Design

### 2.1 Numeric contract (NORMATIVE)

```
inputs   : p_c[r], c in 0..N-1, each s32, all on the SAME grid 2^-y_exp
sum[r]   : s36 = sum over c of p_c[r]                 -- see bound below
amax     = max over r < n_rows of |sum[r]|, held UNSIGNED
msb_pos  : msb index of amax, with msb_pos(0) = 0
ns       = max(0, msb_pos - 14)                        -- right-shift magnitude
out[r]   = sat16( round_shift(sum[r], ns) )            -- int16 mantissa
out_exp  = y_exp - ns
```

**Accumulator bound.** A's partial mode saturates each contribution at s32, so
`|p_c| <= 2^31`. Summing N of them:

| N | Bound | Width |
|---|---|---|
| 2 | 2^32 | s34 |
| 8 | 2^34 | **s36** |

**s36 is declared**, covering N up to 16 with a bit to spare. Wider N would need
re-deriving.

**Rounding sites.** Only two, both inherited rather than invented:

| # | Site | Mode |
|---|---|---|
| 1 | `round_shift(sum, ns)` | round half toward +infinity, matching `fixed_pkg.scale_mul` |
| 2 | `sat16` after site 1 | saturate, matching `bfp_pack`'s biased-path corner |

The reduction itself is **exact** -- integer addition on a shared grid loses
nothing. That is the whole point of requiring a common `out_shift`.

`ns` is subtracted, not added, matching `bfp_pack` (`o_exp = Q - shift_o`) and
C §2.1.4. `out_exp` range is checked; overflow raises `err` (§2.6).

### 2.2 Algorithm: all-to-all, not ring

At 20 KB per message, **latency dominates transfer**: a PCIe Gen3 x16 hop moves
20 KB in ~1.3 us against ~2 us of P2P latency. So the algorithm should minimize
*steps*, not bytes -- the opposite of the usual HPC choice.

| Algorithm | Steps | Bytes/card/collective | Est. time @ N=8 |
|---|---|---|---|
| Ring (reduce-scatter + all-gather) | 2(N-1) = **14** | 35 KB | ~32 us |
| Tree (reduce + broadcast) | 2·log2(N) = **6** | 20-40 KB | ~14 us |
| **Direct all-to-all** | **1 (7 pipelined writes)** | 140 KB | **~11 us** |

**Direct all-to-all is chosen.** Each card writes its full partial to every
peer, then sums the N-1 received buffers locally with its own. The 7 writes
pipeline into one latency plus 7 transfers.

Bandwidth cost is real but affordable: at N=8, 128 collectives x 140 KB =
**17.9 MB per card per token**, against a 7.57 GB weight read -- **0.24%**. The
ring would save 4x the bytes and cost 3x the time, which is the wrong trade here.

At **N=2 this degenerates to a single exchange**: one write each way, one add.
No ring, no tree, no ordering subtlety. That is why v3.0 is the right place to
prove the transport.

### 2.3 Transport and synchronization

Each card exposes a **receive region per peer** in its PCIe BAR, mapped to
on-chip memory. Card `c` writes its partial into peer `d`'s region for `c`.

```
peer_recv[d][c] : n_rows x s32, plus one 32-bit SEQUENCE FLAG
```

**Completion is detected by a flag written after the payload.** PCIe posted
writes to the same destination complete **in order**, so a flag landing implies
the payload has landed. The receiver polls the flag; no round trip, no
acknowledgement, no interrupt.

**The flag carries a sequence number, not a boolean.** With 128 collectives per
token there is no time to zero receive buffers between them, and a stale boolean
from collective *k* would be read as completion of collective *k+1*. The
receiver waits for `flag == expected_seq`, and the sequence increments per
collective. This is the single most likely source of a silent, timing-dependent
bug in E, which is why it is stated here and not left to §3.

**Ordering caveat.** The in-order guarantee holds **per source-destination
pair**. It does not order writes from *different* sources, which is exactly why
each source has its own region and its own flag rather than sharing one.

### 2.4 Sizing

Message size is the full hidden dim, since a row-parallel split computes all
outputs over part of the K range:

```
5120 rows x 4 B = 20,480 B per message
```

| | N=2 (`v3.0`) | N=8 (`v4.0`) |
|---|---|---|
| Collectives per token | 128 | 128 |
| Sent per card per token | 2.56 MB | **17.9 MB** |
| Received per card per token | 2.56 MB | 17.9 MB |
| Receive buffers on chip | 1 x 20 KB | **7 x 20 KB = 140 KB** |
| Est. collective time per token | **~0.42 ms** | ~1.4 ms |
| Token budget (compute) | 16.5 ms | 4.1 ms |
| **Unoverlapped overhead** | **~2.5%** | **~34%** |

140 KB of receive buffers is ~35 BRAM36 at N=8 -- affordable on a VU33P, but it
is not free and it scales linearly with N.

### 2.5 Overlap is a requirement, not an optimization

At N=2 a 2.5% overhead could be ignored. **At N=8, 34% cannot.**

The collective is latency-bound; the next matvec's weight fetch is
bandwidth-bound. They contend for nothing except HBM ports, and the collective
uses PCIe. So subsystem D **must** issue the next layer's weight streaming
concurrently with the collective, rather than treating the collective as a
barrier.

This imposes a normative requirement upward: **`done` from E must be a
completion signal that D can await selectively, not a stall that blocks A.**
Section 3 owns the schedule; this section owns the constraint, because a design
that made the collective blocking would be structurally incapable of hitting
`v4.0`'s target and no amount of §3 scheduling would recover it.

### 2.6 Interface and error semantics

```vhdl
entity tp_collective is
  generic(
    N_PEERS   : positive := 2;      -- 2 for v3.0, 8 for v4.0
    MAXROWS   : positive := 17408;  -- matches A's MAXROWS_BFP at 27B
    ACC_W     : positive := 36
  );
  port(
    clk, rst  : in  std_logic;
    start     : in  std_logic;
    my_rank   : in  std_logic_vector(3 downto 0);
    n_rows    : in  integer;
    y_exp     : in  integer;        -- shared grid from A, see 1.3
    out_shift : in  integer;        -- for the precondition check below
    seq       : in  std_logic_vector(31 downto 0);   -- per-collective sequence
    -- local partial, streamed in from A's y port
    p_we      : in  std_logic;
    p_addr    : in  std_logic_vector(clog2(MAXROWS)-1 downto 0);
    p_data    : in  std_logic_vector(31 downto 0);
    -- reduced + normalized result
    o_we      : out std_logic;
    o_addr    : out std_logic_vector(clog2(MAXROWS)-1 downto 0);
    o_data    : out std_logic_vector(15 downto 0);
    o_exp     : out integer;
    done      : out std_logic;      -- one-cycle pulse
    err       : out std_logic;
    -- PCIe P2P master (writes to peer BARs) + slave (peer writes land here)
    ...
  );
end entity;
```

| Condition | Behaviour |
|---|---|
| `n_rows > MAXROWS` | abort at `start`, no output |
| `out_exp` out of int range after `- ns` | abort, `err` |
| **peer `out_shift` mismatch** | **`err`.** Each card writes its `out_shift` alongside the flag; the receiver compares. A mismatch means the partials are on different grids and the integer sum is meaningless. Cheap to check, catastrophic to miss. |
| flag timeout | `err` rather than hanging. §3 pins the threshold; a wedged peer must not deadlock the pipeline. |

## 3. Transport bring-up, failure handling, validation

**NOT YET WRITTEN.** Constraints it must satisfy:

- **P2P must be proven before anything else.** The recon doc records that this
  is a $650 two-card question: whether FPGA-to-FPGA PCIe P2P achieves ~1-2 us
  behind a common switch. Every number in §2.2 and §2.4 rests on it, and no
  amount of design compensates if it is 20 us.
- ACS must be disabled on the switch's downstream ports (`pcie_acs_override=
  downstream,multifunction`, or VT-d off). Cards on different root complexes
  will not work at all.
- The sequence-flag mechanism of §2.3 needs a test that deliberately runs
  collectives back-to-back with no buffer clearing, since that is the case a
  naive implementation passes by accident when slow and fails when fast.
- A C reference implementing §2.1 exactly, including `sat16` and the
  round-half-toward-+infinity site, validated against an N-way integer sum.
- Overlap (§2.5) must be demonstrated, not assumed: measure collective time with
  and without concurrent weight streaming.
- The three `v1.0-silicon` rules: at most one multiply per state (E has **no**
  multiplies, only adds and shifts, which is worth noting as a simplification);
  never route data through a VHDL `integer`; constrain at the real clock.
