# The B/C grant exists now, and the mutation table says which half of it works

**Date:** 2026-09-06
**Question, verbatim from the port-budget document:** the HBM budget closes only
by taking B and C as `max` rather than as a sum, on the ground that they are
never simultaneously active. Its own words on the state of that: *"Both B and C
already specify the cure, and neither has it in RTL."* And on the interlock:
*"its absence is a silent-data-corruption class of bug, not a performance one."*
So: build the 2:1 grant and the drain interlock, and show that the interlock
discriminates rather than decorates.

## The answer, up front

`rtl/bc_port_grant.vhd` (new) multiplexes B's 2 masters and C's 3 masters onto
3 shared HBM ports and holds the switch until the pool is quiet.
`sim/tb_bc_port_grant.vhd` (new) observes the property directly and passes with
**8,761 checks, 0 misdeliveries, 7,847 owner transitions**. It is a gate row.

**The interlock is real: removing it produces 38 mis-delivered bursts.** But the
mutation table also shows that **one of the two defects I fixed was subsumed by
the other**, so the block carries one guard term that this bench cannot make
fail. That is recorded below under its own name rather than quietly kept.

## The shapes, read off the RTL rather than assumed

The precondition that nearly went unchecked. The budget requires B to take two
ports of bandwidth at 175 MHz, and I had only ever seen one `bst_*` master --
which, if true, would mean B could not absorb two ports regardless of the
grant, and building a grant would be wasted work.

MEASURED, `rtl/gdn_state_store.vhd` and `rtl/llama_top.vhd`:

```
r_arvalid : out std_logic                                   <- read master
r_araddr  : out std_logic_vector(ADDR_W-1 downto 0)
r_rdata   : in  std_logic_vector(AXI_DW-1 downto 0)
w_awaddr  : out std_logic_vector(ADDR_W-1 downto 0)         <- write master
w_wdata   : out std_logic_vector(AXI_DW-1 downto 0)
bst_rdata : in  std_logic_vector(255 downto 0)              <- one port wide
```

**B presents one read master and one write master: two masters, hence two
ports.** The worry was unfounded and the budget maps cleanly. C is two reads
(FLATTENED -- `kv_arvalid` is `std_logic_vector(1 downto 0)`, not two separate
interfaces) plus one write: three. Pool of three, assigned

| shared port | when B owns | when C owns |
|---|---|---|
| 0 | B read | C read 0 |
| 1 | B write | C read 1 |
| 2 | idle | C write |

This is the project's own rule about grepping for the SHAPE rather than for the
word a document used, applied before writing rather than after: had I taken the
single `bst_*` name at face value I would have reported that B cannot use two
ports, which is false.

## The two defects, both found by reading the file back, neither by a bench

The first draft analysed cleanly and was wrong twice, in exactly the class the
block exists to prevent.

**Defect 1 -- the switch could land in the same cycle as an address handshake.**
`quiet` is the COUNTER state and the counters move on the next edge. An AR
handshake completing in the cycle the FSM decides to switch is counted *after*
the owner has changed, so the outgoing master's burst is charged to the incoming
one and its data is delivered to the wrong requester.

**Defect 2 -- switching away with an un-accepted VALID violates AXI.** Dropping
the mux while the outgoing master holds an unaccepted `AWVALID`/`ARVALID`/
`WVALID` pulls VALID low without a handshake. The counters do NOT cover this: a
master may assert `WVALID` before `AWVALID`, and an address that never
handshaked was never counted.

## The mutation table, and the row that does not bite

Reference: `PASS -- checks=8761 misdeliveries=0 switches=7847 reads=5334 writes=3427`

| mutant | guard becomes | verdict | misdeliveries | err_switch_busy |
|---|---|---|---|---|
| M1 interlock removed | `'1'` | **FAIL** | 38 | `'1'` |
| M2 counters only | `quiet` | **FAIL** | 19 | `'0'` |
| M3 same-cycle fix removed | `quiet and out_idle` | **PASS** | 0 | `'0'` |
| M4 AXI-hold fix removed | `quiet and not issue_now` | **FAIL** | 1301 | `'0'` |

**M3 IS THE MOST INFORMATIVE ROW AND IT IS THE ONE THAT PASSES.** Removing the
defect-1 guard reproduces the reference run to the digit -- 8761 / 7847 / 5334 /
3427, identical -- so `issue_now` is not merely untested here, it is inert.
The reason is structural: `m_arvalid` is driven solely from the current owner's
valid, so an address handshake this cycle implies that owner has a valid
asserted, which implies `out_idle = 0`. **Defect 1 was real; my fix for it turned
out to be the same fix as defect 2's.**

The term is KEPT, and this is a judgement rather than a measurement: it costs
about three LUTs and it is defence-in-depth against a future edit to the mux
that breaks the implication above. It is documented in the file as inert-given-
`out_idle` so that nobody later reads it as a live guard.

**M4 is the load-bearing one at 1,301 misdeliveries**, i.e. the AXI-hold
condition, not the counters, is what does most of the work.

**The independent observer has a narrower resolution than the bench.**
`err_switch_busy` fired only for M1. It watches `own /= own_q and quiet_q = '0'`,
so it sees the counter-based violation and is blind to the other two -- M2 and
M4 both mis-deliver with it low. It is still worth keeping because it does not
share a term with the guard it observes, but it must not be read as a complete
detector.

## Measurement traps hit

- **The bench's own verdict thresholds needed a liveness floor.** A grant that
  never switches trivially never mis-delivers. Hence
  `n_switch >= 8 and n_rd >= 40 and n_wr >= 20` in the verdict, so a
  dead grant fails rather than passing vacuously. M1's line shows why the raw
  count is not enough on its own: it reports 38,065 switches with only 148
  checks, because it thrashes.
- **Slave latency is varied per port by a small LFSR.** A fixed latency would
  let the design pass by alignment luck; the switch request has to be able to
  land at any point in a burst.
- **VHDL-2008 conditional expressions in variable assignments and in `report`
  arguments are rejected by this GHDL.** Three parse errors that look like
  syntax mistakes are a tool-support boundary; rewritten as `if` statements and
  a small `verdict_s` function.

## Measured and REJECTED -- do not retry

- **Do not conclude B cannot take two ports from the single `bst_*` name.**
  It carries one read AND one write master. I nearly reported the opposite.
- **Do not gate the switch on `quiet` alone** (M2, 19 misdeliveries), and in
  particular do not assume the outstanding counters cover an unaccepted VALID.
  They do not, because `WVALID` may precede `AWVALID`.
- **Do not treat `err_switch_busy` as the detector.** It caught 1 of the 3
  killing mutants.

## Open, not yet answered

- The grant is verified against a bench-local slave model, not against B's or
  C's real masters, and neither is wired to it yet. Nothing in the shipping
  design instantiates `bc_port_grant`.
- Its priority is fixed C-over-B. No starvation bound has been established;
  that is a scheduling property and this bench does not test it.
- The area and timing cost is unmeasured. It has never been through synthesis.
