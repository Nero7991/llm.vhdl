# The codebook command net had 1,536 sinks, and the fix costs no cycle

## The question, verbatim

From the TRACK CBFANOUT brief, 2026-09-20, against build 10
(`hw/fk33/results/card_build10_FAILED_2026-09-20/`, commit `7e560e9`),
`xcvu33p-fsvh2104-2L-e`, `FK33_CARD=1`, 75 MHz core clock:

> Build 10 failed at routed **WNS -5.819 ns, 17,194 failing endpoints on the
> 75 MHz core clock**. Every one of the ten worst paths runs from ONE register
> to the codebook command replicas [...] Register to register with **no logic
> between**, so the 5.819 ns is pure net delay. [...] **Whatever you do must
> preserve** [the same-cycle invariant]. [...] If your honest conclusion is
> that this should NOT be changed [...] then say so with the evidence.

## The answer, up front

**It should be changed, and the change is smaller than the one the file itself
proposes.** Replicate the codebook write COMMAND register per ROW
(`CB_RANKS = 48`) instead of per COPY (`CB_COPIES = 1536`). Max fanout per
command bit falls **1,536 -> 48**, `CB_WR_LAT` stays **1**, and the design
loses **19,344 flip-flops**.

The same-cycle invariant is preserved **by the same argument the shipping
design already uses**, not by a weaker one: the proof at
`matvec_core.vhd:266-278` never depended on the cardinality of the command
register set, so coarsening it changes nothing the proof relies on.

This is **not** the `CB_BCAST` construction named at `matvec_core.vhd:299-309`.
That one inserts a rank BETWEEN the port and `cbw_*`, keeps 1,536 command
registers, and takes `CB_WR_LAT` to 2. It reaches the same two fanout numbers
while adding a cycle, adding 624 flops, and tightening the caller contract past
what one shipping caller has margin for. See "Measured and REJECTED".

## The procedure, in the order run

1. **Read the unit's own history before proposing anything.**
   `git log -S CB_COPIES -- rtl/matvec_core.vhd` gives three commits.
   `fe0d3c8` is the one that matters: *"A: replicate the codebook **per row**,
   and the invariant that actually tests it"*. The per-COPY explosion was never
   a design decision; it is a side effect of lever C reusing `CB_COPIES` as the
   bound of the command register array. This change restores the original
   intent rather than inventing a structure.
2. **Establish what the caller contract actually tolerates**, because any fix
   that adds a cycle spends it against real callers. Read the three
   instantiators' FSMs, not the documents: `rtl/llama_top.vhd` (`S_CBGAP` plus
   a long `S_XRD`), `rtl/matvec_int4_desc_axi.vhd` (`S_CB -> S_START -> S_WAIT`,
   **one** spare cycle), `rtl/matvec_int4_axi.vhd` (host-paced AXI writes).
   This is what killed the `CB_WR_LAT := 2` construction.
3. **Baseline the existing mutation table at the style the card builds**, which
   nothing in the gate does: `CBSTYLE=distributed bash sim/mutate_matvec_cb.sh`.
   Row **K3d** turned out to be the measured form of the whole argument.
4. **Write the invariant argument before the RTL** (it is reproduced below).
5. **Build and test the patch entirely outside the repo**, because build 11's
   Vivado was reading sources from this working tree. The patch is a script
   with unique-anchor enforcement, applied to a scratch copy.
6. **Value oracle at both styles and both versions**: `tb_matvec_core` against
   `ref/matvec_int4.c`, plus `tb_matvec_cb_contract` and
   `tb_matvec_cb_lockstep`.
7. **Mutate the fix, with an attribution-control mode for the new check.**
8. **Elaborate at the CARD geometry**, which no bench uses, in both directions.

## The argument that the same-cycle invariant survives

`matvec_core.vhd:266-278` states a correctness property:

> "A codebook that is half old and half new is a silently wrong answer, not a
> failure, so the replicas are written by ONE command that reaches all of them
> in the SAME cycle. There is deliberately no master copy that the replicas
> chase: a master-then-broadcast design has a window in which they legitimately
> differ, and that window is the defect."

Write `rk(c) = (c*CB_RANKS)/CB_COPIES` for the rank serving copy c.

**Claim 1 (the ranks are indistinguishable).** Every `cbw_v/a/d(r)` is assigned
in one loop from one expression of the entity's PORTS and of `st`/`rst`. No
term depends on r. All share `clk` and one initialiser. By induction over
edges, all ranks hold identical values at every instant.

**Claim 2 (one edge, one value).** Copy c writes at edge E iff
`cbw_v(rk(c)) = '1'` pre-E. By Claim 1 that predicate is independent of c, so
either every copy writes at E or none does, and all write the same address and
value. No instant exists at which two copies differ.

**Claim 3 (this is the SAME argument, not a weaker one).** The shipping design
is the special case `CB_RANKS = CB_COPIES`, `rk = identity`. Neither proof uses
the cardinality of the register set nor the injectivity of `rk`.

**Claim 4 (no master, no chase).** The forbidden shape derives a replica's
value from another replica's OUTPUT. Here the command registers are an
antichain: no `cbw_*(r)` feeds any `cbw_*(r')`, and no `cb(c)` feeds anything.
Register depth from port to EVERY copy is exactly 1, identically.

**Claim 5 (nothing outside the module moves).** One register on the path, so
`CB_WR_LAT` stays 1: every caller schedule legal today stays legal, the
"tightest legal schedule" is unchanged, `P_CB_CHK`'s watch point `cbw_v(0)` is
still the LAST stage before `cb` (so the recorded K2b hazard is not re-opened),
and `P_CB_MODEL` is built from ports and does not change at all.

**The entity is byte-identical across the change.** MEASURED:

    $ awk '/^entity matvec_core is/,/^end entity;/' rtl/matvec_core.vhd | md5sum
    054989edc0ceb178f2e97b312d202c56  -
    $ git show HEAD:rtl/matvec_core.vhd | awk '/^entity .../' | md5sum
    054989edc0ceb178f2e97b312d202c56  -

Every diff hunk is inside `architecture rtl`. No instantiating wrapper can be
affected.

## Why 48

Max fanout per command bit as a function of the rank count NR is
`max(NR, CB_COPIES/NR)`, minimised at `sqrt(1536) = 39.2`. DERIVED:

    NR = 1      every copy reads rank 0        max fanout 1,536   (= K3d)
    NR = 48     per ROW, this design           max fanout    48
    NR = 1,536  per COPY, what build 10 built  max fanout 1,536

48 is the nearest value to the optimum that is also a PHYSICAL cluster, and it
is a cluster for a reason unrelated to the codebook: the BLK lanes of one row
feed a shared adder tree (`matvec_core.vhd:186-190`, and `fe0d3c8`), so the
placer keeps them together whether or not we ask. Replicating on a boundary the
adder tree does not respect was rejected in `fe0d3c8` and is rejected here for
the same reason.

## The evidence, as raw output

### The measured form of Claims 1-3: K3d

`CBSTYLE=distributed bash sim/mutate_matvec_cb.sh`, unmodified repo harness:

    K3d    SURVIVED  AC:surv AL:surv AM:surv  NC:surv NL:surv NM:surv
                     SC:surv SL:surv SM:surv
           -- every replica writes off replica 0's command registers
              (master/follower, the design the RTL comment rejects by
              construction)
           expected: SURVIVE: a true equivalent mutant today, because every
                     command register holds the same command.

K3d is `NR = 1`, the extreme of this change, measured functionally equivalent
across three benches and three assert modes. This design is `NR = 48`, strictly
between K3d's 1 and today's 1,536, and inherits that equivalence. K3d is
rejected here on FANOUT alone.

### The value oracle, both styles, both versions

`tb_matvec_core` against `ref/matvec_int4.c` (bench geometry ROWS_IF=4,
BLK=32, so `CB_COPIES=128` and `CB_RANKS=4` -- the change IS exercised):

    --- OLD regs
    TOTAL: 464 stage + 343 output values compared, 0 mismatches
    RTL matches ref/matvec_int4.c at every stage, in all three out_mode values
    --- OLD distributed
    matvec_core: LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=128
                 CB_LANES_PER_COPY=1  CB_WR_LAT=1
    TOTAL: 464 stage + 343 output values compared, 0 mismatches
    RTL matches ref/matvec_int4.c at every stage, in all three out_mode values
    --- NEW regs
    TOTAL: 464 stage + 343 output values compared, 0 mismatches
    RTL matches ref/matvec_int4.c at every stage, in all three out_mode values
    --- NEW distributed
    matvec_core: LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=128
                 CB_LANES_PER_COPY=1  CB_RANKS=4  CB_WR_LAT=1
    TOTAL: 464 stage + 343 output values compared, 0 mismatches
    RTL matches ref/matvec_int4.c at every stage, in all three out_mode values

`tb_matvec_cb_contract` and `tb_matvec_cb_lockstep`, OLD and NEW, regs and
distributed: 8 of 8 PASS.

### The card geometry, which no bench reaches

    $ ghdl -r matvec_core -gROWS_IF=48 -gBLK=32 -gCB_STYLE=distributed ...
    matvec_core: LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536
                 CB_LANES_PER_COPY=1  CB_RANKS=48  CB_WR_LAT=1

(The run then reports `overflow detected`, which is the core being driven with
no stimulus; elaboration -- the thing being tested -- completed.)

Negative control, same geometry, `CB_RANKS` forced back to `CB_COPIES`:

    $ ghdl -r matvec_core -gROWS_IF=48 -gBLK=32 -gCB_STYLE=distributed ...
    ghdl-mcode:error: bound check failure at core_M2.vhd:371
      from: work.matvec_core(rtl).DECL_ELAB at core_M2.vhd:371
    ghdl-mcode:error: error during elaboration

`DECL_ELAB` is declaration elaboration, the same mechanism `CHK_CB_STYLE` uses.

### The teeth table, with the attribution control

Modes: **A** everything live; **P** `CHK_CB_RANKS` neutered (THE ATTRIBUTION
CONTROL for this track's new check); **S** `P_CB_MODEL` demoted (the
pre-existing control). All at `CB_STYLE=distributed`.

| row | verdict | A | P | S | what it is | attribution |
|---|---|---|---|---|---|---|
| CTRL | SURVIVED | surv | surv | surv | the unmutated design | control |
| M1_collapse | KILL(pin) | elab | **surv** | elab | every copy reads rank 0, i.e. NR=1 | **the pin EARNED it** |
| M2_percopy | KILL(pin) | elab | **surv** | elab | `CB_RANKS := CB_COPIES`, the fix undone -- exactly what build 10 built | **the pin EARNED it** |
| M3_offbyone | KILL | elab | elab | elab | map shifted by one copy, last group off the end | older property (index bound) |
| M6_rotate | KILL(pin) | elab | **surv** | elab | every copy reads its NEIGHBOUR'S rank | the pin, **over-strictly** -- see below |
| M4_rankskew | KILL(a) | KILL | KILL | KILL | upper half of the RANKS writes one cycle late | `P_CB_CHK`, not the pin |
| M5_deepen | KILL(a) | KILL | KILL | **surv** | a UNIFORM extra stage, `CB_WR_LAT` not updated | `P_CB_MODEL` earned it |
| M7_liveaddr | KILL(a) | KILL | KILL | surv(C,L) | CONTROL: write address taken live (K7a shape) | proves the harness still kills what the old one killed |

`elab` = refused at elaboration by the out-of-range `natural`.

**M2_percopy is the row that justifies the pin.** Undoing this entire change is
invisible to all three benches in all modes -- `PC/PL/PM: surv` -- because it is
functionally identical. Without the pin, a regression to the structure that
failed build 10 would pass every test in this project. That is this codebase's
standing failure class: a lever that does nothing and looks like it worked.

### Mutations that did NOT bite, under their own names

- **M6_rotate is a FALSE POSITIVE of the pin, reported as such.** Rotating the
  copy-to-rank map preserves both fanout numbers exactly and is functionally
  identical (Claim 1). The pin rejects it anyway, because it requires the map
  to start at 0 and be monotone. **The pin is strictly stronger than the
  property it guards.** That is deliberate -- the alternative is to pin only
  the two fanout numbers, which M1 and M2 would then pass -- but it is a real
  over-constraint and is recorded rather than hidden.
- **Every functional bench survives the fix itself** (CTRL, and the value
  oracle above). Per the standing rule, a green bench across a real change
  means the change is untested by that bench. Here that is CORRECT and is the
  point: the change is provably value-neutral, so **no simulation can score
  it**. The only instruments that can are the elaboration pin (values of
  `CB_RANKS`) and STA (the fanout itself). This is stated rather than papered
  over: **the RTL change is verified by construction and by the pin, and its
  BENEFIT is unmeasured.**
- The pre-existing harness's own row **L4** predicted this failure before it
  happened: *"whether the enable tree that lever C needs, in order not to
  reintroduce the 1,536-fanout net this whole change exists to remove, is
  balanced. Instrument: STA, not simulation."*

### The area claim, and why it is DERIVED rather than fitted

Command-path flops are `CB_RANKS * 13` (1 valid + 4 address + 8 data):

    today     1536 * 13 = 19,968
    proposed    48 * 13 =    624
    DERIVED delta                  -19,344 FF

**This is confirmed against an independent measurement.** Commit `a4828ab`
MEASURED lever C's flop cost as `CLB FF 60,268 -> 73,463, +13,195 (DERIVED
+13,200, residual -5)`. That +13,200 decomposes exactly:

    command registers   +19,344   (1536*13 - 48*13)
    cb becomes LUTRAM    -6,144   (48 copies * 16 entries * 8 bits)
    -------------------------------------------------------------
    net                 +13,200   against +13,195 MEASURED

So the 19,968 command flops are not read off the source; they are the only
decomposition that reproduces a measured number to 5 flops in 13,195.

**FALSIFIABLE PREDICTION.** With this change, lever C's FF delta at ROWS_IF=48
goes from +13,200 to **-6,144**: lever C becomes FF-negative as well as
LUT-negative. One OOC synthesis of `matvec_core` at the FK33 geometry, regs
against distributed, settles it. This is a structural constant, not a fit.

### The timing benefit: ESTIMATE, and what would settle it

**ESTIMATE, and deliberately unquantified.** A fanout reduction's benefit is a
placement property. What is DERIVED is the input: max sinks per command bit
falls 1,536 -> 48, a factor of 32, on the net carrying all ten worst paths of
build 10 at -5.819 ns with no logic in them.

**No number is offered for the resulting WNS**, and specifically no ratio is
derived from build 9's +0.061 against build 10's -5.819. Those two builds
differ in the levers as well as in the area, and this project has twice been
burned reading scatter as slope -- once missing a lever by 5x where the plain
mean was right to 0.48% (`a4828ab`), and once writing up a five-variable pair
as a one-variable experiment.

**What would settle it**, in increasing cost:

1. An OOC synthesis of `matvec_core` at ROWS_IF=48 BLK=32, distributed, before
   and after. Settles the **-19,344 FF prediction exactly** and gives a
   synthesis WNS. Does NOT settle the routed benefit: a synthesis-only harness
   is not a timing result, and `sim/ooc_leverc48_thread.tcl` has no
   `route_design`.
2. `report_high_fanout_nets` plus `get_cells -hier -filter {REF_NAME =~ FD*}`
   on the existing build-10 placed checkpoint versus a re-synthesised one.
3. The only thing that actually answers the question: a routed
   `FK33_CARD=1` build. Per the postmortem, `phys_opt` WNS on this part
   over-promises by 0.4 to 0.6 ns and has inverted a verdict, so **nothing
   before `route_design` orders two runs correctly.**

## Measured and REJECTED -- do not retry

- **`CB_BCAST` as written at `matvec_core.vhd:299-309`** (port -> rank ->
  `cbw_*` -> cb, `CB_WR_LAT := 2`). It reaches the SAME two fanout numbers
  (48 then 32) while adding a cycle, adding 624 flops instead of removing
  19,344, and tightening the caller obligation by one cycle. MEASURED from the
  RTL: `matvec_int4_desc_axi`'s `S_CB` drives the last `cb_we`, the
  `cb_cnt = 16` branch spends one cycle reaching `S_START`, and `S_START`
  pulses `core_start` -- so the core sees `start` exactly **two** cycles after
  the last `cb_we`. At `CB_WR_LAT = 2` the write lands on the very edge that
  leaves `S_IDLE`: legal by the letter of `P_CB_CHK`, with **zero margin**.
  And `core_start <= '0'` is a per-cycle default at
  `matvec_int4_desc_axi.vhd:733`, so `start` is a **one-cycle pulse**: any
  interlock that defers it drops it and the core hangs. Do not build the
  deeper form to buy the same two numbers.
- **A multicycle path constraint.** `cbw_a(c) <= cb_addr` and
  `cbw_d(c) <= cb_data` are unconditional every cycle (`:700-701` pre-change),
  so there is no multi-cycle window to relax without first gating the capture,
  which is an RTL change with its own correctness argument. Not
  constraint-only work.
- **Raising `CB_LANES_PER_COPY` (fewer copies).** Trades command-side fanout
  for READ-side fanout, and the read side is in the multiply path where the
  command side is not. It also gives back lever C's MEASURED -42,633 LUT,
  which the composed fit cannot afford.
- **Removing the `dont_touch` attributes** at `:353-356` (now `:462-465`).
  They are what stops equivalent-register removal merging the replicas into
  one. The `a4828ab` FF arithmetic above is the proof they currently work: all
  1,536 command registers survived synthesis and show up in the measured FF
  delta. They stay, and they apply unchanged to 48.
- **A route or `phys_opt` directive.** Already rejected by the postmortem:
  `[Physopt 32-745]` says the negative slack is too large to improve and its
  own advice threshold is "WNS above -0.5ns" against -5.819.

## Measurement traps hit, including this track's own

- **I read a background log before it flushed and reported it as empty.** The
  mutation harness run completed with exit code 0 and `cat mut.log` printed
  only the header, so the run looked like it had produced nothing. stdout to a
  file is block-buffered. This is the third recorded form of "the harness is
  reporting a fact about the harness"; the file was complete moments later.
  **Count the scratch row directories, or just re-read.**
- **I nearly killed another track's process.** Two `ghdl-mcode` processes
  appeared while memory was exhausted and I assumed they were orphans of my own
  SIGPIPE'd debug run. Reading `/proc/PID/cwd` showed PID 352230 sitting in
  `/mnt/storage/fk33_builds/scratch/gsrwide/...` -- **TRACK GSRWIDE's**, not
  mine. The other PID had already exited. Identifying by the kernel's view
  rather than by a command line is what stopped this, and the failure mode
  would have been silent destruction of a sibling track's evidence.
- **The first version of the pin could not see the defect it exists for.** It
  checked only that the copy-to-rank map is onto and contiguous. MEASURED by
  mutation: `CB_RANKS = CB_COPIES` (the fix undone) and `CB_RANKS = 1` are
  **both legal onto maps**, so the pin passed over both. The fanout bound
  (`CB_RANKS <= ROWS_IF` and `CB_COPIES/CB_RANKS <= BLK`) was added for exactly
  this and is what M1 and M2 now fire on. A check never shown to discriminate
  on the thing it guards is decoration.
- **A mutant that fires the pin scores as ABORT, not KILL, unless the scorer is
  told.** An out-of-range `natural` fails at `ghdl -r` elaboration, not at
  `ghdl -a`, so a parser looking for assertion text in a bench log sees neither
  a PASS nor a failure it recognises. The first table printed `ABORTED` for the
  three rows that were the whole point. The verdicts in this document are read
  from the elaboration diagnostic directly.

## Consequences for other files -- NOT fixed here, deliberately

**`sim/mutate_matvec_cb.sh` anchors on text this change moves.** The command
register declaration (`std_logic_vector(CB_COPIES-1 downto 0)`) and the write
statement (`cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c))`) both
change. Rows anchored on them will print **`ANCHOR FAILED -- tested nothing`**
and the harness reports it loudly rather than silently, which is the correct
behaviour and is why this is a re-anchor job and not a silent loss.

**It is NOT fixed here because `sim/mutate_*.sh` belongs to TRACK REANCHOR**,
and committing another track's in-flight file under this track's message is the
cross-track capture that has already caught four tracks in one day. The
replacements are mechanical:

    CB_COPIES-1 downto 0                      ->  CB_RANKS-1 downto 0
    cbw_a(c) ... cbw_d(c)                     ->  cbw_a(cb_rank_of(c)) ...
    for c in 0 to CB_COPIES-1 loop (capture)  ->  for r in 0 to CB_RANKS-1 loop

Note for whoever does it: the W1 write loop and the W0 capture loop are now
**two separate loops**, so an anchor spanning both no longer exists.

## Open, not determined

1. **The timing benefit is entirely unmeasured.** No Vivado ran for this track.
   Every timing statement here is an ESTIMATE resting on a DERIVED fanout
   reduction.
2. **Whether fixing this net lets build 10's levers close, or moves the failure
   to the next-worst structure.** Inherited unchanged from the postmortem. The
   levers grew the design; the codebook is where it broke FIRST.
3. **The -19,344 FF prediction is DERIVED and not yet MEASURED.** It is exact
   and falsifiable; one OOC synthesis settles it.
4. **Whether Vivado evaluates the new elaboration function.** `cb_rank_chk_f`
   loops `CB_COPIES-1` times (1,535 at the card) over constant folding. GHDL
   does it. Vivado's VHDL front end is not tested here and no Vivado ran.
   **If it does not fold, the build errors rather than silently mis-building**,
   so the failure mode is safe, but it has not been observed either way.
5. **The executable gate rows for the wrapper benches were NOT RUN.** See the
   WORKLOG entry: the box was at 1.6 GB available with 21-23 GB of swap in use
   under build 11's Vivado, and the measured full-gate peak is 2.13 GiB. The
   three benches that instantiate `matvec_core` directly WERE run, at both
   styles and both versions, and the entity is byte-identical across the
   change, which bounds what a wrapper row could newly catch -- but it does not
   reduce it to zero.
6. **`CB_ROWS_PER_COPY > 1` is untested by this track.** The pin admits it
   (`CB_COPIES < ROWS_IF`, so `CB_RANKS = CB_COPIES` and the map is the
   identity, exactly as today) but no bench was run at that setting.
