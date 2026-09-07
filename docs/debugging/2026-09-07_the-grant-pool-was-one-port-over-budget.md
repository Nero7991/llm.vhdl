# The B/C grant asked for three HBM ports and the card has two

Date: 2026-09-07. Part `xcvu33p-fsvh2104-2L-e`, SQRL FK33.
Files: `rtl/bc_port_grant.vhd`, `sim/tb_bc_port_grant.vhd`,
`hw/fk33/gen_fk33_card.py`, `hw/fk33/rtl/fk33_bc_grant.vhd`.

## The question

While wiring the two-cell block design in `gen_pcieep.py`, the shared HBM ports
had to be allocated. `fk33_bc_grant` exposes `m0_axi`, `m1_axi`, `m2_axi`. How
many SAXI ports are actually free for them?

## The answer

**Two, and the grant wanted three -- but it only ever needed two.** MEASURED
from the RTL: pool port 0 is driven on AR/R in both owners and its AW/W/B
channels are driven by neither; pool port 2 is driven on AW/W/B and never on
AR/R. **The two use disjoint AXI channel groups, so C's write moves onto port
0's idle write channels and the pool becomes 2 with no arbitration added and no
behaviour changed.** `NPORT` is now 2 and the wrapper emits `m0`/`m1` only.

The budget: the HBM has 32 SAXI. `SAXI_00` and `SAXI_16` belong to the host,
one per stack. Subsystem A's `ENG_PORT_MAP` uses 28 (`1..15`, `17..29`).
`32 - 2 - 28 = 2`, and those two, `SAXI_30` and `SAXI_31`, are presently
`CONFIG.USER_SAXI_30 {false}` / `31 {false}` and must be enabled. DERIVED, then
confirmed against `gen_pcieep.py:436` ("SAXI_00 and SAXI_16 belong to the
host") and the `USER_SAXI` lines at 2065-2068.

## The procedure

1. Enumerate the card's and grant's port groups from the generated entities.
   This showed the shapes match end to end (`bst_*` RW to `b_*`, `kv_*` write
   to `c_*`, `kv0_*`/`kv1_*` reads to `c0_*`/`c1_*`) and that the pool is 3.
2. Count the spare SAXI from `ENG_PORT_MAP` rather than from any document.
3. Read which pool index each owner drives, to find whether 3 was a
   requirement or an artefact. It was an artefact.
4. Re-index C's write from port 2 to port 0, set `NPORT` to 2.
5. Run the bench. Teeth-test the re-index. Run the attribution control.

## The evidence

The role assignment, `rtl/bc_port_grant.vhd`, before the change. Note that the
`OWN_B` branch never mentions index 2 and neither branch drives index 0's write
channels; the process defaults every output to `(others => '0')` first:

```
      m_arvalid(0) <= b_arvalid;              -- OWN_B: port 0 read
      m_awvalid(1) <= b_awvalid;              -- OWN_B: port 1 write
    elsif own = OWN_C then
      m_arvalid(1 downto 0) <= c_arvalid;     -- OWN_C: ports 0,1 read
      m_awvalid(2) <= c_awvalid;              -- OWN_C: port 2 write
```

Bench at a genuine `NPORT=2`, after the change:

```
PASS -- checks=8494 misdeliveries=0 switches=7619 reads=5142 writes=3352
       p0rd=3352 p0wr=1790 p1rd=1790 p1wr=1562 err_switch_busy='0'
```

`5142 = 3352 + 1790` and `3352 = 1790 + 1562`, so the per-port counters
partition the aggregates exactly.

MUTANT M-P1, C's write returned to port 1 (20 diff lines), at `NPORT=2`:

```
FAIL -- checks=8571 misdeliveries=0 switches=7429 reads=5220 writes=3351
       p0rd=3353 p0wr=0 p1rd=1867 p1wr=3351 err_switch_busy='0'
POOL PORT 0 CARRIED NO WRITE
```

**Attribution control: `misdeliveries=0` in the mutant.** The pre-existing
interlock property does not fire. The kill belongs solely to the new per-port
check, so that check is worth its maintenance.

## Measurement traps hit

**THE BENCH PINNED `NPORT=>3` AND I READ TWO GREEN RUNS AS "VERIFIED AT
NPORT=2".** `sim/tb_bc_port_grant.vhd:28` had `constant NP : positive := 3` and
line 70 passes `NPORT=>NP`, which **overrides the entity default**. So changing
the default from 3 to 2 changed nothing the bench instantiated: both the
reference run and the first teeth test ran a 3-port grant with C's write merely
re-indexed, and both were green. The first honest `NPORT=2` run happened only
after `NP` was set to 2 as well.

This is the recorded rule that a green bench across a real change means the
change is untested, in a new place: here the bench was not insensitive, it was
**not testing the modified configuration at all**, and nothing in its output
said so. A generic default is not a configuration; the instantiation is.

**What caught it was the new check, not any reasoning.** `POOL PORT 2 CARRIED
NO READ` fired on the very first run, because at `NP=3` port 2 had become
permanently idle. A check written to guard the block design's wiring caught an
error in the verification of the change that motivated it, one run after being
added.

**THE FIRST TEETH TEST WAS AN EQUIVALENT MUTANT AND I NEARLY RECORDED IT AS A
BENCH GAP.** At `NPORT=3`, moving C's write from port 0 to port 1 is
functionally correct -- the grant serialises the owners, so B's write and C's
write never overlap on port 1 -- and it passed. That pass was the right answer.
Only at `NPORT=2`, where the property under test is that the pool is fully
used, does the same edit become a defect. **A mutant that survives is a claim
about the mutant as much as about the check**, and the discriminator was asking
what the mutant would actually break, not re-running it harder.

**A null grep, five patterns wide, was my own pattern being wrong.**
`grep -nE '^\s*m0_(awvalid|...)\s*<='` returned nothing for m0, m2 **and for
m1, which is certainly driven**. The control was in the same command and it
was the control that showed the fault: the ports are not named `m0_*` in
`bc_port_grant.vhd` at all. They are a width-`NPORT` vector `m_*` that the
wrapper generator splits. Had I greppd only for the two ports I hoped were
idle, the null result would have read as confirmation.

## Measured and REJECTED -- do not retry

- **Merging the three pool ports onto two SAXI with a smartconnect.** Not
  needed, and it would have added an arbiter in front of an arbiter. The
  channel-disjointness above makes the merge free. Rejected before building.
- **Reducing subsystem A from 28 masters to 27 to free a third port.** A's port
  count follows `A_ROWS_IF=48` and its area is already the binding constraint
  at 94.47% CLB. Changing it to serve the grant would trade a settled result
  for an unsettled one.
- **Treating `SAXI_00`/`SAXI_16` as available.** They are the host's DMA path,
  one per stack, and the 8 GB address map is built on them
  (`gen_pcieep.py:2209`).

## Open, not yet answered

- `SAXI_30` and `SAXI_31` are still `USER_SAXI_nn {false}`. Enabling them, and
  the `AXI_nn_ACLK` / `AXI_nn_ARESET_N` pins that come with every enabled port,
  is part of the `gen_pcieep.py` wiring and is not done.
- The card's `bst_*` carries `arsize`, `arburst`, `wstrb`, `rresp`, `bresp`;
  the grant's `b_*` does not. Those five have to be tied off or dropped at the
  join, and which is correct has not been decided.
- **Bandwidth was not analysed.** Port 0 now carries C's read 0 and C's write
  concurrently on one HBM pseudo-channel. That is legal AXI and correct, but
  whether it is the right split of the KV traffic is unmeasured.
