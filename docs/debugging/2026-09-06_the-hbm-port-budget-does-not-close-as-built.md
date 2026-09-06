# Does the HBM port budget close for B and C as the build actually allocates?

Date: 2026-09-06. Written while implementing Oren's choice that the PCIe block
design should instantiate the wired `compose4_top`.

## The question

> B and C need HBM. `gen_pcieep.py` says SAXI_30 and SAXI_31 are "the two spare
> engine ports `docs/2026-08-27_hbm-port-contention.md` budgets for B and C".
> Does that close?

## The answer, up front

**No, not as built -- and it is off by exactly one port, because the budget
counted A at 27 masters and the build gives A 28.**

**But Oren's decision to drop the core clock closes it for B.** B's port demand
is proportional to the core clock, and at the 175 MHz the full-engine build now
targets it falls to 2, which is what is actually spare.

| | ports |
|---|---|
| SAXI total | 32 |
| host (0 and 16, excluded by `gen_pcieep`'s own assert) | 2 |
| **available** | **30** |
| A: 27 data lanes + **1 descriptor master** (`ENG_NMAST`) | 28 |
| **actually spare** | **2** |
| spare the budget doc assumed (it counted A = 27) | 3 |

DERIVED from the doc's own MEASURED figures (30.22 GB/s at 236.128 MHz, 11.77
GB/s per port), B's demand scaling linearly with the core clock:

| core clock | B demand | B ports |
|---|---|---|
| 300.000 MHz | 38.39 GB/s | 4 |
| 236.128 MHz | 30.22 GB/s | 3 |
| 200.000 MHz | 25.60 GB/s | 3 |
| **175.000 MHz** | **22.40 GB/s** | **2** |

**So lowering the clock was not only a schedule concession. It moves B from
needing 3 ports to needing 2, and 2 is what exists.** That was not the reason
for the decision and nobody argued it at the time; it falls out of the
arithmetic.

## What is still NOT closed, and must not be glossed

1. **C's demand is 3 ports in the budget doc and I have NOT established whether
   it scales with the core clock the way B's does.** If it does not, C does not
   fit in 2 and something has to give. This is the open question that decides
   whether the first full bitstream can carry C at all.
2. **The 2:1 grant mux between B and C does not exist in RTL.** The budget doc
   is explicit: *"Both B and C already specify the cure, and neither has it in
   RTL."* The budget closes only because B and C are mutually exclusive, and
   that mutual exclusion has to be ENFORCED by a grant, not merely be true of
   the schedule.
3. **The drain interlock at the mux does not exist either**, and the doc rates
   its absence as *"a silent-data-corruption class of bug, not a performance
   one"* -- one counter per shared port and one FSM state, MEASURED below 0.02%
   of the token. Cheap, absent, and the failure mode is wrong numbers rather
   than a hang.

## Corrections to my own record, both directions, within a day

- **2026-09-05, overstated:** I called this "HBM plumbing for B's 29 `bst_*` and
  C's 26 `kv_*` ports... no existing mapping... probably the largest remaining
  piece", from a `grep -oE` port count. A count of identifiers is not a measure
  of interface complexity.
- **2026-09-06, UNDERSTATED, and this document is the correction:** I then said
  it was "two AXI masters into two reserved slots, no allocation problem and no
  outstanding decision." Wrong on three counts. **C is not one master** --
  `kv_arvalid` is `std_logic_vector(1 downto 0)` and `kv_araddr` is
  `2*C_KV_ADDR_W` wide, i.e. two flattened read channels plus one write. **The
  slots do not number what I said** -- 2, not the doc's 3. And **the grant mux
  and drain interlock are specified and unbuilt**, so there is very much
  outstanding work.

The over-correction was worse than the original error, because it was delivered
with more confidence and it removed an item from the remaining-work list that
belongs on it. **Correcting an overstatement is not the same as establishing the
opposite**, and I did the second while believing I was doing the first.

What produced it: I read `gen_pcieep`'s "two spare engine ports ... budgets for
B and C" and stopped, because it agreed with the count I had just derived. **A
source that confirms the conclusion you already reached is the one to read
furthest into**, and the budget document it cites says B needs 3 or 4 and C
needs 3 -- which is on its first screen.

## Open, not yet answered

- Whether C's port demand scales with the core clock (decides the fit).
- Whether the 2:1 grant and the drain interlock can be built as one small block
  at the mux, as the doc suggests, or need changes inside B and C.
- Whether the descriptor master genuinely needs a dedicated SAXI port, or could
  share one with a data lane -- which would restore the doc's third spare.

---

## RESOLVED, same day: C does NOT scale with the clock, and the fix is one shared lane

### The open question is answered, and the answer is the unwelcome one

`docs/2026-08-27_hbm-port-contention.md:375`, verbatim:

> **C, DERIVED.** 3 masters (2 read + 1 write) is a *concurrency* requirement,
> not a bandwidth one. C's KV traffic is 0.036 GB per token at ctx 2048 over
> 1,217,484 cycles = 5.156 ms = **6.98 GB/s**, which is 0.6 of one port; at ctx
> 32,768 it is 0.570 GB over 66.6 ms = 8.56 GB/s. **C needs 3 ports because its
> datapath issues three concurrent streams, and it needs no more at any
> context.**

**So the clock lever does not help C.** B's 3 -> 2 at 175 MHz is real and
bandwidth-driven; C is pinned at 3 by concurrency at every clock and every
context. The budget at the clock the full-engine build now targets:

```
A data                     27
A descriptor master         1
max(B = 2, C = 3)           3
                          ---
                           31
available                  30
                          ---
                    SHORT BY 1
```

And the budget doc's own table, which assumed A = 27, already closed at exactly
30 with **spare 0**. **There was never room for the descriptor master.** That is
the whole discrepancy: `gen_pcieep` calls SAXI_30/31 "two spare engine ports
budgeted for B and C", and the document it cites budgets **three** to
`max(B, C)` and leaves none.

### The fix: the descriptor master shares a data lane. It is nearly free and it is SAFE BY CONSTRUCTION.

**Cost, DERIVED.** The arena is 311 descriptors x 512 B = 159,232 B per token:

| context | token time | descriptor traffic | share of one port |
|---|---|---|---|
| ctx 2,048 | 5.156 ms | 0.03088 GB/s | **0.262%** |
| ctx 32,768 | 66.6 ms | 0.00239 GB/s | **0.020%** |

**Safety, MEASURED from the RTL rather than argued from timing.**
`rtl/matvec_int4_desc_axi.vhd` starts the two masters from different FSM states,
227 lines and six states apart:

- `d_start <= '1'` at **:771**, in `S_IDLE` -- launches the descriptor fetch.
- `core_start <= '1'` at **:998** -- launches the 27 weight/scale masters,
  reached only via `S_FETCH -> S_R -> S_CHECK -> S_SHAPE -> S_SHAPE_C -> S_CB`.

The descriptor read is therefore COMPLETE before any weight read is issued, and
the next descriptor fetch begins only from `S_IDLE`, i.e. after `done`. **The
two never contend**, so sharing a lane is a phase separation enforced by a state
machine, not an arbitration with a deadline.

That distinction is the one this project already insists on elsewhere: the norm
path's gate was put on `wbusy` rather than `w_active` precisely because
*"`wbusy` is a single bit that is either true or false; that is the difference
between a check with teeth and an argument."* A 2:1 select driven by an FSM
state is the same kind of object.

**With the descriptor master sharing lane 0 the budget closes exactly:**

```
A data (lane 0 also carries the descriptor)   27
max(B = 2, C = 3)                              3
                                             ---
                                              30
available                                      30      CLOSES, spare 0
```

### What is STILL required before a bitstream carrying B and C means anything

Unchanged by any of the above, and not to be skipped:

1. **The 2:1 grant between B and C over the shared 3 ports does not exist in
   RTL.** The budget closes only because B and C are mutually exclusive, and
   that must be ENFORCED, not assumed.
2. **The drain interlock at the mux does not exist**, and its absence is rated
   *"a silent-data-corruption class of bug, not a performance one"*: one counter
   per shared port, one FSM state, MEASURED below 0.02% of the token.
3. **B at 2 ports has not been re-derived for correctness, only for
   bandwidth.** 22.40 GB/s against 2 x 11.77 = 23.54 GB/s is a 4.8% margin, and
   a margin that thin should be checked against the burst pattern rather than
   the average before it is trusted.

### Open

- Whether lane 0 is the right lane to share (any of the 27 works on bandwidth;
  the choice may matter for the stack-boundary straddle the arena layout note
  describes).
- Whether B at 2 ports holds under bursts, per item 3 above.
