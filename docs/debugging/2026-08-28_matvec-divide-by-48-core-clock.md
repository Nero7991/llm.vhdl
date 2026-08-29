# Why does `matvec_int4_desc_axi` stop at 133.94 MHz on the core clock, and is the divide-by-48 genuinely multicycle?

**Date:** 2026-08-28. Branch `fpga`, baseline `6fc730e`, synthesised in a
detached `git worktree` so that the tracks editing `rtl/` concurrently could
not contaminate a netlist. (`rtl/attn_block.vhd` was mid-edit in the main tree
throughout; the worktree is why that did not matter.)
**Tool:** Vivado 2023.2, `synth_design -mode out_of_context`, `-mode batch`,
`sim/ooc_fk33_a.tcl`.
**Part:** `xcvu33p-fsvh2104-2L-e`, `set_operating_conditions -voltage
{VCCINT 0.717}` applied after synthesis.
**Geometry:** `ROWS_IF=48`, `AXI_DW=256`, `NPORTS_W=24`, `NPORTS_S=3`, `BLK=32`,
`ADDR_W=40`, `MAXB=16`, `MAXOUT=16`, `FIFO_DEPTH=512`,
`MAXCOLS=MAXROWS_BFP=17408`, `DUAL_CLK=true`.

**No hardware was touched.** No `xsdb`, no `hw_server`, no programming, no
bitstream, no `place_design`, no `route_design`. Out-of-context synthesis only.

Predecessors: `2026-08-28_subsystem-a-ooc-synthesis-at-fk33-geometry.md` and
`2026-08-28_ar-throttle-timing-close.md`. The latter closed the AXI clock at
257.33 MHz and left this path open as its section 9 item 4, "the divide-by-48,
unchanged and still owned elsewhere".

Labels: **MEASURED** (a named tool produced the number), **DERIVED**
(arithmetic on measured inputs, shown), **ESTIMATE** (a judgement).

---

## 1. The question

`matvec_int4_desc_axi`'s core clock closed at 133.94 MHz against 226.96 MHz for
`matvec_int4`, on a path `dw_reg -> a 32-bit divide by 48 -> tiles_r` at
`rtl/matvec_core.vhd:885` (`:858` in the predecessor documents, which
predate two commits). `ROWS_IF = 48` is not a power of two, so it is a
real divider, and it is a CONFIGURATION-TIME path: computed once when a
descriptor is accepted, not per beat.

Close it, honestly. Specifically: establish whether the path is genuinely
multicycle by reading the RTL rather than assuming, and only then choose
between a multicycle exception, pipelining, restructuring, or reusing the
`tiles` the descriptor wrapper's shape check already computes.

## 2. The answer

**MEASURED: 133.92 -> 230.73 MHz on `matvec_int4_desc_axi`'s core clock, a
72.3% improvement, with LUT DOWN 309 and the AXI clock unchanged at
257.33 MHz.** `matvec_int4` gained too, 224.27 -> 231.32 MHz and 1,176 fewer
LUTs. The core clock is now bound by the merge fanout into the DSP array
(3 logic levels, route-dominated), which is the path the predecessor already
named as a placement question and not an RTL one.

**NO multicycle exception was added, and none should be.** A hard guarantee
does exist for the specific path that was reported (section 4), but the fix
that removes the divide entirely is cheaper, needs no constraint file that a
future build can lose, and fixes `matvec_int4` as well, where the same divide
is present but was never timed.

**Two divides by 48 had to go, not one.** Removing the first exposed a second
of exactly the same shape, in the result-readback path, and it alone held the
clock at 192.86 MHz:

| step | core Fmax, `matvec_int4_desc_axi` | critical path |
|---|---|---|
| 0, baseline `6fc730e` | **133.92 MHz** | `dw_reg[1][1]` -> `core/tiles_r_reg[25]`, 30 levels, 18 CARRY8, 7.464 ns |
| 1, tile counter in `matvec_core` | **192.86 MHz** | `y_idx_reg[5]` -> `res_reg_0/ADDRARDADDR[14]`, 16 levels, 8 CARRY8, 4.727 ns |
| 2, + `Y_IDX` resolved by subtraction | **230.73 MHz** | `core/st_reg[0]` -> `core/tr_reg[0][0]/DSP_OUTPUT_INST/CEP`, 3 levels |

Neither fix is a divide, a reciprocal or a tuned constant. Both are the
"multiply up, never divide" idiom that `docs/2026-08-28_matvec-descriptor-
format.md` section 5.2 already established for the shape check.

## 3. The procedure, and what each step isolates

| run | isolates |
|---|---|
| `matvec_int4_desc_axi` at `6fc730e` | **reproduce the baseline before touching anything** |
| read every consumer of `tiles_r`, with file:line | whether the path is multicycle by construction or only typically slack |
| `matvec_int4_desc_axi` after the tile counter | whether the reported divide was the whole cost |
| `matvec_int4_desc_axi` after the `Y_IDX` loop | the second divide, which only became visible once the first was gone |
| `matvec_int4` before and after | that the core change helps, or at least does not hurt, the unit that does NOT have a descriptor plane |
| three deliberate mutations of the new counter | that the existing tests can actually see the identity being got wrong |

One synthesis at a time (4.7 to 6.3 GB each, 31 GB box).

## 4. Is it multicycle? The consumer trace, and the guarantee that DOES exist

Asked and answered before anything was changed, because a multicycle exception
on a path that is only usually slack is a functional bug that no simulation can
see: simulation does not model the constraint at all.

**Writer.** `rtl/matvec_core.vhd:885` (at `6fc730e`), in `S_IDLE`, on the edge
that leaves for `S_RUN`. All line numbers in this section are `6fc730e`'s.

**Readers of `tiles_r`, all of them, at `6fc730e`:**

| site | state | earliest it can run |
|---|---|---|
| `:639` `if t_iss = tiles_r - 1` | `S_RUN`, gated by `accept` | 3 cycles after the write |
| `:910` `if rd_t < tiles_r` | `S_EMIT` | after `S_DRAIN` and `S_SCAN` |
| `:942` `if em_t = tiles_r - 1` | `S_EMIT` | later still |

The 3-cycle figure at `:639` is a real guarantee and not a typical case:
`accept` (`:535`, `accept <= '1' when st = S_RUN and w_valid = '1' and
s_valid = '1' and xq_cnt > 0`) needs `xq_cnt > 0`; `xq_cnt <= 0` is written by
the same S_IDLE branch that writes `tiles_r` (`:888`); and `xq_cnt` can only
rise on `pf_out`, which `:609-610` raises only when the PRE-EDGE state is
already `S_RUN`. So the activation prefetch has to prime for two cycles before the
first `accept` can exist, whatever the weight stream does.

**But the setup path that failed is `dw_reg -> tiles_r`, and its guarantee is a
different one: the SOURCE has to be stable.** It is. `dw` is written only by
the descriptor fetch in `S_R`, and `matvec_int4_desc_axi`'s FSM then runs
`S_CHECK` (1 cycle) -> `S_SHAPE` (>= 2) -> `S_SHAPE_C` (1) -> `S_CB` (1, or 17
when `cb_load` is set) -> `S_START` (1) before `core_start` is pulsed. That is
at least 6 cycles of a stable `dw` before the capture edge, from an FSM whose
states are all in one file.

**So a `set_multicycle_path -setup 4 -hold 3` from `dw_reg*` to `tiles_r_reg*`
would have been CORRECT.** It was not taken, for reasons that are about where
it would have to live rather than about whether it is true:

* There is no XDC in this repo that survives into a build, and Vivado's XDC
  reader **forbids `if` and skips the block with only a CRITICAL WARNING**
  (`CLAUDE.md`), so a constraint guarded by "only when `ROWS_IF` is not a power
  of two" would silently vanish. An unguarded one would have to be written
  against hierarchical cell names that `llama_top` can rename.
* The guarantee is the WRAPPER's, and `matvec_core`'s `n_rows` is a plain port.
  `matvec_int4` drives it from a top-level port, `llama_top` from wherever it
  likes. An exception written at `matvec_int4_desc_axi` level is true; the same
  exception is a lie one level up if anyone ever drives `n_rows` from something
  that moves.
* It buys nothing that removing the divide does not also buy, and removing it
  additionally helps `matvec_int4`.

**Recorded so the next reader does not have to re-derive it:** the guarantee is
real, the exception would have been sound at that one instance, and it was
rejected on maintainability, not on correctness.

## 5. The fix

### 5.1 `tiles_r` becomes a counter (rtl/matvec_core.vhd)

`ceil(n_rows / ROWS_IF)` is the number of tiles the issue FSM walks anyway, one
per `nblk` accepted weight words. So it is counted rather than divided, and
"is this the last tile" is a compare against a synthesis constant:

```vhdl
-- S_IDLE
tiles_r   <= 0;
rows_left <= n_rows;          -- was: tiles_r <= (n_rows + ROWS_IF - 1)/ROWS_IF

-- the issue FSM, on the last block of a tile
tiles_r <= tiles_r + 1;
if rows_left <= ROWS_IF then st <= S_DRAIN;
else rows_left <= rows_left - ROWS_IF;
     t_iss     <= t_iss + 1; end if;
```

`rows_left = n_rows - t*ROWS_IF` at tile `t`, so `rows_left <= ROWS_IF` is
exactly `t = ceil(n_rows/ROWS_IF) - 1` for `n_rows >= 1`, which `S_IDLE`
already checks. **Zero added cycles** -- the tiles were being counted out one
at a time regardless -- and the issue FSM no longer reads `tiles_r` at all.
`S_EMIT`'s two readers run only after `S_DRAIN`, which is entered by the branch
that counts the last tile, so they see the final value.

This is option 3 of the four the brief listed. **Option 4, reusing the shape
check's `sh_t`, was checked first and rejected**: `sh_t` is correct and
available (`rtl/matvec_int4_desc_axi.vhd:726-737`, final from `S_SHAPE_C`
onward, several states before `core_start`), but wiring it in needs a new port
and a new generic on `matvec_core` AND on `matvec_int4`, whose other
instantiations (`rtl/matvec_int4_axi.vhd`, `rtl/llama_top.vhd`) are not this
track's files; it would leave `matvec_int4`'s own divide in place, which is a
real timed path in an in-context build even though OOC hides it; and it would
put the identity in two files with nothing forcing them to agree. The counter
subsumes it.

### 5.2 `Y_IDX` is resolved by subtraction (rtl/matvec_int4_desc_axi.vhd)

Exposed only by 5.1. `res` is tile-major, so the AXI-Lite result readback
needed `Y_IDX / ROWS_IF` and `Y_IDX mod ROWS_IF`, both written as VHDL
operators on a 16-bit register, and after 5.1 the three worst paths in the
whole design were all `y_idx_reg[5] -> res_reg_N/ADDRARDADDR[14]`.

A small sequential loop subtracts `ROWS_IF` until it cannot, producing the
quotient and remainder, and **the AXI-Lite read of `Y_LO`/`Y_HI` stalls
(`arready` held low) until they are ready.** The stall is the point: it makes
this a handshake rather than a timing assumption. Answering immediately and
trusting the host to have left enough cycles between the `Y_IDX` write and the
`Y_LO` read is a software convention, and it is precisely the class of thing a
multicycle exception encodes and no test checks.

Cost: `floor(Y_IDX / ROWS_IF)` cycles per NEW `Y_IDX`, bounded by `TILES-1`
(362 at this geometry), on a debug/bring-up readback path that already costs a
whole AXI-Lite transaction per row. MEASURED in simulation as +1,550 ns over
the whole of `tb_matvec_fk33_desc`, 539,935 -> 541,485 ns.

The write side lost its divide too: `res` is written once per tile in tile
order (`rtl/matvec_core.vhd:840` in raw/partial mode, `:978` in BFP mode, both
with `y_addr` = the tile's base row), so the index is a counter reset by
`core_start`. **That assumption is asserted, not assumed** -- `w_tile*ROWS_IF =
to_integer(unsigned(y_addr_i))` on every write.

**One behaviour change, stated:** `res(to_integer(y_idx)/ROWS_IF)` indexed
outside the array for any `Y_IDX >= TILES*ROWS_IF`, which is a simulation abort
and an undefined address in hardware. The loop saturates at `TILES-1` instead.
Nothing legal reaches either.

## 6. The evidence

### 6.1 The baseline, reproduced before anything was changed

MEASURED, `matvec_int4_desc_axi` at `6fc730e`, verbatim, abridged:

```
WNS all=-4.167 | core 3.3 ns -> -4.167 ns slack, Fmax 133.92 MHz
               | axi 3.333 ns -> -0.553 ns slack, Fmax 257.33 MHz
LUT=134843 (LUTRAM 5238)  FF=63905  DSP=1585  BRAM36=192.5

Source:            dw_reg[1][1]/C
Destination:       dut/core/tiles_r_reg[25]/D
Data Path Delay:   7.464ns (logic 3.651ns (48.9%) route 3.813ns (51.1%))
Logic Levels:      30  (CARRY8=18 LUT1=2 LUT2=1 LUT3=3 LUT4=1 LUT5=3 LUT6=2)
```

133.92 against the 133.94 recorded by the predecessor, and the same endpoints,
the same 30 levels, the same 18 CARRY8, the same 7.46 ns. The AXI figure
matches to the digit. **The LUT count does not: 134,843 here against the
136,051 recorded.** Two commits landed between that measurement and this
baseline; the offset is systematic and present in both units, which is why
every area delta below is against a baseline measured in THIS session rather
than against the published one.

### 6.2 After, MEASURED, same script and same geometry

```
WNS all=-1.034 | core 3.3 ns -> -1.034 ns slack, Fmax 230.73 MHz
               | axi 3.333 ns -> -0.553 ns slack, Fmax 257.33 MHz
LUT=134534 (LUTRAM 5238)  FF=64067  DSP=1585  BRAM36=192.5

Source:            dut/core/st_reg[0]/C
Destination:       dut/core/tr_reg[0][0]/DSP_OUTPUT_INST/CEP
Logic Levels:      3  (LUT2=2 LUT4=1)
```

| | `matvec_int4_desc_axi` | | `matvec_int4` | |
|---|---|---|---|---|
| | before | **after** | before | **after** |
| core clock | 133.92 MHz | **230.73 MHz** | 224.27 MHz | **231.32 MHz** |
| AXI clock | 257.33 MHz | **257.33 MHz** | 257.33 MHz | **257.33 MHz** |
| LUT | 134,843 | **134,534** | 133,143 | **131,967** |
| FF | 63,905 | **64,067** | 60,917 | **60,957** |
| DSP | 1,585 | 1,585 | 1,584 | 1,584 |
| BRAM36 | 192.5 | 192.5 | 145.5 | 145.5 |

The two units now differ by 0.6 MHz and sit on the same path, which is the
statement that the descriptor control plane no longer costs core clock at all.
It used to cost 40%.

### 6.3 The bandwidth arithmetic, recomputed

`27 x 256 bits = 864 B` exactly, so the duty has no efficiency term and
`duty = f_core / f_axi`. DERIVED, shown:

```
supply = 27 ports x 32 B x 257.33e6 = 222.33e9 B/s = 222.3 GB/s   (unchanged)
demand = 864 B x 230.73e6           = 199.35e9 B/s = 199.4 GB/s
duty   = 199.35 / 222.33 = 0.8966 = 230.73 / 257.33   (the identity, confirmed)
```

| quantity | as published | `6fc730e` MEASURED | **after, MEASURED** |
|---|---|---|---|
| ACLK | 300.0 MHz ESTIMATE | 257.33 MHz | **257.33 MHz** |
| supply, 27 ports | 259.2 GB/s | 222.3 GB/s | **222.3 GB/s** |
| core clock, descriptor plane | 236.128 MHz | 133.92 MHz | **230.73 MHz** |
| demand | 204.0 GB/s | 115.7 GB/s | **199.4 GB/s** |
| **duty** | 78.7% | 52.0% | **89.7%** |

**`f_core` is still BELOW `f_axi`, so the core remains the binding side and the
duty identity keeps its sign.** The margin narrowed from 123.4 MHz to
26.6 MHz. The next MHz of core clock costs 1.12 GB/s of supply that is not
there; another 26.6 MHz and the AXI side becomes binding and the duty
expression inverts. That is now a live consideration and it was not before.

tok/s, ESTIMATE (it assumes the whole engine tracks one clock and that A
dominates the token, both inherited from the predecessor's model): scaling the
published 32.80 tok/s at 236.128 MHz by the measured core clock of the unit the
FK33 build actually instantiates gives **32.05 tok/s, against 18.60 before**.
The descriptor control plane was throwing away 42% of the token rate.

### 6.4 Simulation, unchanged behaviour

MEASURED, `sim/regress.sh --only tb_matvec`, all eight rows PASS. The one that
matters, verbatim:

```
shape sweep, FK33 arm (ROWS_IF=48, GRP=1): 10 legal shapes accepted,
                                           38 one-off beat-count mutations refused
shape sweep, AXU3EG arm (ROWS_IF=4, GRP=2): 9 legal shapes accepted,
                                            32 one-off beat-count mutations refused
CASE  0 clean descriptor  OK -- 100 elements bit-exact on the core bus,
                                100 rows bit-exact through AXI-Lite, y_exp=6
tb_matvec_fk33_desc: 22 cases run, 0 failures
subsystem A is bit-exact with ref/matvec_int4.c through the descriptor control
plane, and every checked mutation is refused
```

Full gate, MEASURED: `OVERALL PASS 81 FAIL 0 NOVERDICT 0 TIMEOUT 0
BUILD-ERROR 0 NOCHECK 5 SKIPPED 19`, `baseline: 81 passing, matches the
recorded floor of 81`.

### 6.5 Teeth: three mutations of the new counter, and what they cost

A checker never shown to fail has not been shown to work. Each mutation was
applied alone and the tree restored from a saved copy afterwards.

| # | mutation | verdict | what caught it |
|---|---|---|---|
| M1 | `rows_left <= ROWS_IF` -> `rows_left < ROWS_IF` (over-count by one on exact multiples) | **FAIL** | shape sweep: `n_rows=48`, `96`, `192` all "is LEGAL and never completed (timeout 40001)" |
| M2 | count only the tiles that are NOT the last (under-count by one, always) | **FAIL** | sweep timeouts on `n_rows=1,47,48`, plus `CASE 0: expected 100 rows, saw 96` and `4 of 100 rows read back through the AXI-Lite map MISMATCH` |
| M3 | `rows_left <= n_rows - 1` (under-count only when `n_rows mod ROWS_IF = 1`) | **FAIL**, but not where expected | `bound check failure at rtl/axi_rd_fsm.vhd:231` -- a crash in an unrelated file, NOT the value oracle |

**M3 is the valuable row.** By construction it is wrong only at
`n_rows = 49, 97, 145` and correct at `n_rows = 100`, so **`CASE 0`, the only
case in the suite that checks VALUES, cannot see it**, and the shape sweep runs
those three shapes but only checks that the job COMPLETES. It was caught by a
downstream range assertion firing on the beats the core failed to consume,
which is luck, not coverage. Under M3, `tb_matvec_core`, `tb_matvec_fk33`,
`tb_matvec_int4`, `tb_matvec_axi`, `tb_matvec_cb_lockstep`,
`tb_matvec_int4_ip` and `tb_matvec_engine` **all PASS** -- they run 8 rows at
`ROWS_IF = 4`, where the mutation is invisible. `tb_matvec_fk33_desc` is the
only testbench in the repo with any teeth on the tile-count identity.

## 7. What a passing test would NOT have caught

The predecessor track shipped a doubled FIFO write that three testbenches
passed; this change is in the same class, so the diff was re-read for what the
green suite does not cover.

1. **A tile-count error that still terminates and is not at `n_rows = 100`.**
   Section 6.5 M3, measured. The shape sweep runs `n_rows = 49, 97, 145` and
   checks only liveness; `CASE 0` checks values and only at `n_rows = 100`.
   The gap is in the BENCH, not in this change, and it is not this track's
   file to widen. **Named here so it is not discovered a third time.**
2. **`tiles_r` is now meaningless before `S_DRAIN`.** It reads as a partial
   count during `S_RUN`. No consumer exists today and the declaration says so,
   but a future progress or status register that reads it during a job would be
   silently wrong, and nothing would fail.
3. **The `w_tile` assertion does not exist in hardware.** Vivado drops
   `assert` in synthesis (`CLAUDE.md`). If `matvec_core`'s emit order ever
   stopped being tile-ascending-from-0, GHDL would fire and the card would
   silently write the wrong `res` entry. The check has teeth in simulation
   only, which is where the order is decided, but it is not a hardware guard.
4. **`Y_LO`/`Y_HI` now have a variable read latency of up to `TILES-1` cycles
   after a `Y_IDX` write.** Every test drives the readback through the AXI-Lite
   channel and therefore through the stall, so none of them can distinguish a
   correct stall from an unnecessary one. A future consumer that taps `y_sel`
   directly in fabric, bypassing `arready`, would read stale data and no test
   in this repo would notice.
5. **A host that rewrites `Y_IDX` every cycle restarts the loop every cycle and
   never gets an answer.** It is not a deadlock -- stopping the writes yields a
   result -- and AXI-Lite cannot actually issue writes that fast, but nothing
   tests it and nothing bounds it.
6. **The saturation branch (`Y_IDX >= TILES*ROWS_IF`) is unreachable from any
   test**, because the old code aborted simulation there. It is argued, not
   exercised.

## 8. Measured and REJECTED -- do not retry

* **A multicycle exception on `dw_reg -> tiles_r`.** Correct (section 4), and
  still rejected: nowhere to put it that a future build cannot lose, true only
  at one instantiation of a port that other files drive, and strictly worse
  than deleting the divide. Do not add one because "the guarantee exists" --
  the guarantee existing is necessary, not sufficient.
* **Reusing the shape check's `sh_t` (brief option 4).** Checked first as
  instructed. `sh_t` is the same quantity and is ready in time. Rejected: a new
  port plus a new generic on two entities whose other instantiations are other
  tracks' files, `matvec_int4`'s own divide left in place, and the identity
  duplicated across two files with no cross-check.
* **Narrowing the divide to `clog2(MAXROWS_BFP+1)` bits.** Not measured, and
  deliberately not attempted: `n_rows > MAXROWS_BFP` is legal in `out_mode`
  `01`/`10` (`rtl/matvec_core.vhd:881` gates that check on `out_mode = "00"`),
  so the 32-bit width is not slack, it is the raw/partial contract. Narrowing
  it would have been a silent functional restriction dressed as a timing fix.
* **A magic reciprocal for `Y_IDX / 48`.** `q = (n * 43691) >> 21` is exact for
  `n < 2^16` and would have been one multiply. Rejected on the same grounds
  section 5.2 of the descriptor format document already gives: "no divider, no
  magic reciprocal, no tuned constant". It also stops being exact the moment
  `ROWS_IF` or the index width moves, which is exactly what a generic does.

## 9. Measurement traps hit

* **`matvec_int4` OOC HIDES this defect completely.** `n_rows` is a top-level
  port there and `sim/ooc_fk33_a.tcl` sets no `set_input_delay`, so the path is
  simply not timed. Its 224 MHz was never evidence that the divide was cheap;
  it was evidence that nobody was looking. The same is true of every other
  descriptor scalar on that entity. **An unconstrained input port is not a fast
  path, it is an absent one.**
* **The first fix's number, 192.86 MHz, is a real measurement of a design that
  still had a divide-by-48 in it.** Stopping there and reporting "+44%, done"
  would have been defensible and wrong by 38 MHz. The tell was the shape of the
  report: 8 CARRY8 into a BRAM address is not what a fixed control path looks
  like.
* **Area deltas against a published baseline were 1,200 LUT out.** Two commits
  landed between the predecessor's measurement and this one. Every number in
  6.2 is before-and-after from this session; do not diff across documents.
* **`sim/regress.sh`'s `BASELINE_PASS` moved from 80 to 81 mid-session** when
  another track landed `tb_attn_kv_seam`. A gate run read against the number in
  the brief rather than the number in the file would have looked like a
  regression.

## 10. Open, not yet answered

1. **What the core clock does after place and route**, with B, C, D, the HBM IP
   and the XDMA shell present. 230.73 MHz is an OOC ceiling on a path that is
   already 3 logic levels and route-dominated, i.e. the remaining cost is
   placement, not logic.
2. **The margin is now 26.6 MHz, not 123.4.** If the DSP-array route path is
   improved by more than that, the AXI side becomes binding and the duty
   identity inverts. Nobody has looked at what `f_core > f_axi` costs.
3. **`tb_matvec_fk33_desc` checks values at exactly one shape.** Section 7
   item 1. The cheap fix is to check values, not just completion, for the
   shapes the sweep already runs.
4. **`ar_left`, `p_beats` and the `n_beats` port are still unconstrained
   integers** (inherited from the predecessor's section 7). Untouched here.
5. **`rtl/matvec_int4_axi.vhd`, the legacy AXU3EG map, carries the SAME
   readback divide** and was left alone: `:402` `res(y_addr/ROWS_IF)`, `:407`
   `res(to_integer(y_idx)/ROWS_IF)`, `:413-414` `y_idx_d mod ROWS_IF`, i.e.
   section 5.2 word for word. At the AXU3EG's `ROWS_IF = 4` all three are
   shifts and cost nothing, and the FK33 build does not instantiate that
   entity, so this is a trap only for whoever next points that map at a
   non-power-of-two geometry. It is a separate file with a separate testbench
   (`sim/tb_matvec_axi`) and porting the fix was not attempted.
