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
