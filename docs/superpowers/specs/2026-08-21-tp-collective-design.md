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

**CORRECTED 2026-08-24 against A §14.2 as corrected 2026-08-22/24 (this section
originally described an s32 partial A no longer emits).** A's `out_mode = "10"`
emits, per output row:

```
y_acc[r] = acc[r]              -- s48, UNROUNDED, no out_shift, no saturation
y_exp    = w_exp + x_exp       -- PER CARD, data-dependent
```

**The normalization is deferred precisely because it cannot be done locally**:
BFP packing needs `amax` over the final result, and a partial's maximum is
unknown until after the reduction. E therefore owns the pack, and also the
single `round_shift(., out_shift)` + `sat32` that A's raw mode would have
applied per card.

**The partials are NOT on a shared grid and are NOT directly summable.**
`x_exp` is each card's local BFP pack of its slice of the previous op's output,
so it is data-dependent and differs per card (A §14.2, corrected). E must
therefore **transport each peer's `y_exp` alongside the payload** and align
before summing (§2.1). The superseded claim that equal `out_shift` alone makes
partials summable as plain integers is withdrawn; `out_shift` no longer even
appears in the partial's grid.

**Spread bound.** With the normative A §14.2 policy (equal `w_exp` across the
shard group, equal `out_shift` programmed everywhere), the `y_exp` spread
equals the `x_exp` spread and is bounded by **17** (the producer's pack takes
s32, so its `ns` is 0..17). Measured: <= 5 on real activations, <= 6 on
adversarial synthetic distributions at production shapes
(`docs/debugging/2026-08-24_partial-sum-exactness.md`).

## 2. Design

### 2.1 Numeric contract (NORMATIVE)

**CORRECTED 2026-08-24, resolving A §15.4b (option 1: min-align, floor, bounded
loss).** The previous contract took s32 inputs on one shared grid and declared
an s36 accumulator; both premises were wrong -- A emits unrounded s48 partials
on per-card grids. The superseded text follows this block.

```
inputs   : p_c[r], c in 0..N-1, each s48 UNROUNDED (A partial mode), on grid
           2^-y_exp_c.  y_exp_c is PER CARD and transported with the payload.
y_min    = min over c of y_exp_c
d_c      = y_exp_c - y_min                             -- alignment shift, >= 0
q_c[r]   = floor_shr(p_c[r], d_c)                      -- SITE 0: floor, exact
                                                       --   for the y_min card
sum[r]   : s(48 + clog2(N)) = sum over c of q_c[r]     -- see bound below
y32[r]   = sat32( round_shift(sum[r], out_shift) )     -- SITES 1/2, A 7.4
amax     = max over r < n_rows of |y32[r]|, held UNSIGNED
msb_pos  : msb index of amax, with msb_pos(0) = 0
ns       = max(0, msb_pos - 14)                        -- right-shift magnitude
out[r]   = sat16( round_shift(y32[r], ns) )            -- SITES 3/4
out_exp  = y_min - out_shift - ns
```

**Accumulator bound.** A's contract asserts `|p_c| < 2^47` (s48); alignment
only shrinks magnitude (plus at most 1 from flooring a negative). Summing N:

| N | Bound | Width |
|---|---|---|
| 2 | 2^48 | **s49** |
| 8 | 2^50 | **s51** |

**`ACC_W = 48 + clog2(N_PEERS)`**; s52 covers N up to 16. The value-level bound
is far smaller (~2^36 when the slices partition `K <= 17408`), but E cannot
verify that its peers' slices partition anything, so the width is derived from
A's interface contract, not the workload.

**Rounding sites.** Three; sites 1-4 inherited from A §7.4, site 0 owned here:

| # | Site | Mode |
|---|---|---|
| 0 | `floor_shr(p_c, d_c)` alignment | **floor**, matching C §2.1.4's min-reference right-shift-only policy |
| 1/2 | `round_shift(sum, out_shift)` then `sat32` | round half toward +infinity, matching `fixed_pkg.scale_mul`; saturate |
| 3/4 | `round_shift(y32, ns)` then `sat16` | as A §7.4 site 4, matching `bfp_pack` |

**The reduction is NOT exact and does not claim to be.** Site 0 loses less than
`N-1` ulp of the `y_min` grid per row (only shifted cards err, each by < 1 ulp,
always toward -infinity). Measured against an exact max-aligned reduction of
the same partials: **at most 1 count of `y32`, and 0 in most runs**, at N=2/4/8
and at the worst-case spread of 17 (`ref/matvec_int4.c`, 15.4b tests).
Bit-identity to a single-card full-K job is unattainable under any policy --
the per-card `x` packs upstream already diverged -- so exactness here would buy
nothing observable; what is normative is bit-exactness against the C reference,
which site 0 preserves because floor alignment is deterministic.

`ns` is subtracted, not added, matching `bfp_pack` (`o_exp = Q - shift_o`) and
C §2.1.4. `out_exp` range is checked; overflow raises `err` (§2.6).

*Superseded 2026-08-21 text: inputs s32 on one shared grid; `sum : s36`
(N=2 s34, N=8 s36); "the reduction itself is exact -- integer addition on a
shared grid loses nothing"; `out_exp = y_exp - ns`. Withdrawn as derived from a
partial format A stopped emitting on 2026-08-22 and from a shared-grid premise
that never held in production.*

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
peer_recv[d][c] : n_rows x s48 (in 64-bit slots, sign-extended), plus a
                  trailer of: the sender's y_exp (i32), the sender's
                  out_shift (i32), and the 32-bit SEQUENCE FLAG, written last
```

*(CORRECTED 2026-08-24: was `n_rows x s32` plus the flag alone. The payload is
A's unrounded s48 partial, 8 B per value, and the per-card `y_exp` must travel
with it -- §1.3. The flag stays last so its arrival still implies the payload
and trailer have landed.)*

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
outputs over part of the K range. **CORRECTED 2026-08-24: 8 B per value, not
4 B** -- the payload is A's unrounded s48 partial (A §14.2, corrected
2026-08-22), which doubles every figure in this section:

```
5120 rows x 8 B = 40,960 B per message  (+ 12 B trailer)
```

| | N=2 (`v3.0`) | N=8 (`v4.0`) |
|---|---|---|
| Collectives per token | 128 | 128 |
| Sent per card per token | 5.12 MB | **35.8 MB** |
| Received per card per token | 5.12 MB | 35.8 MB |
| Receive buffers on chip | 1 x 40 KB | **7 x 40 KB = 280 KB** |
| Est. collective time per token | ~0.6 ms | ~2.6 ms |
| Token budget (compute) | 16.5 ms | 4.1 ms |
| **Unoverlapped overhead** | **~4%** | **~63%** |

(35.8 MB is still only 0.47% of the 7.57 GB per-card weight read -- the
bandwidth argument of §2.2 survives the doubling. The *time* estimates rise
more than 2x at N=8 because each 40 KB hop is ~2.6 us of transfer against
~2 us of latency: the doubled term is now the dominant one, and the operation
drifts from latency-bound toward transfer-bound. These are estimates on the
same unmeasured P2P premise as §2.2; the overhead row is why §2.5's overlap
requirement got harder, not softer.)

280 KB of receive buffers is ~70 BRAM36 at N=8 -- affordable on a VU33P, but it
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
    ACC_W     : positive := 52      -- 48 + clog2(N), s52 covers N <= 16
                                    -- (CORRECTED 2026-08-24, was 36: see 2.1)
  );
  port(
    clk, rst  : in  std_logic;
    start     : in  std_logic;
    my_rank   : in  std_logic_vector(3 downto 0);
    n_rows    : in  integer;
    y_exp     : in  integer;        -- LOCAL card's partial grid, from A's
                                    -- y_exp port; peers' y_exp arrive in the
                                    -- 2.3 trailer (CORRECTED 2026-08-24: the
                                    -- grid is per-card, not shared -- see 1.3)
    out_shift : in  integer;        -- applied ONCE, post-reduction (2.1)
    seq       : in  std_logic_vector(31 downto 0);   -- per-collective sequence
    -- local partial, streamed in from A's y port (s48 in 64 bits, matching
    -- matvec_int4's ROWS_IF*64 y_data lanes; was 32 bits -- CORRECTED)
    p_we      : in  std_logic;
    p_addr    : in  std_logic_vector(clog2(MAXROWS)-1 downto 0);
    p_data    : in  std_logic_vector(63 downto 0);
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
| **peer `out_shift` mismatch** | **`err`.** Each card writes its `out_shift` in the §2.3 trailer; the receiver compares against its own port. *(Reworded 2026-08-24: differing grids are now legal and handled by the `y_exp` alignment, so this is no longer a grid check. It still errs because every card applies its own `out_shift` to the same reduced sum, so a mismatch makes the N local copies of "the same" tensor silently diverge downstream.)* |
| **peer `y_exp` spread > 17** | **`err`** (added 2026-08-24). Under the A §14.2 packer/PS policy the spread is bounded by 17; a larger spread means a shard group with mismatched `w_exp` or a corrupt trailer, and the alignment shifter need not be built wider than 17 to find out. |
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
  (The 15.4b tests in `ref/matvec_int4.c` already execute the full corrected
  §2.1 pipeline -- site-0 alignment included -- at N=2/4/8 against real A
  partials; E's reference can lift that code rather than rewrite it.)
- Overlap (§2.5) must be demonstrated, not assumed: measure collective time with
  and without concurrent weight streaming.
- The three `v1.0-silicon` rules: at most one multiply per state (E has **no**
  multiplies, only adds and shifts, which is worth noting as a simplification);
  never route data through a VHDL `integer`; constrain at the real clock.
