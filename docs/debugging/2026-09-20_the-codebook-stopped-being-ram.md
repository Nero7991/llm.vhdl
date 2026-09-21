# 2026-09-20 -- the codebook stopped being RAM: Vivado's 3D-RAM recognizer declined, and the 1,536 LUTRAMs became 48 register banks plus 1,536 mux trees

TRACK CBRAM. Diagnosis only. **`rtl/matvec_core.vhd` was NOT edited by this
track** (md5 `c3325ea1f418dcbcaa85f33e47e8c901` at the start and at the end).

---

## The question, verbatim

> **Why did `cb` stop inferring as distributed RAM?** The change was to the
> write COMMAND path: `cbw_a(c)` became `cbw_a(cb_rank_of(c))`, so 1,536 array
> copies now take their write address from 48 shared rank registers instead of
> 1,536 private ones.

Context: TRACK PLACEDIFF MEASURED, build 11b against build 10, both
`Design State: Fully Placed`, Vivado 2023.2 Build 4029153,
`xcvu33p-fsvh2104-2L-e`: CLB LUTs `361,361 -> 405,434` (**+44,073**),
LUT-as-Distributed-RAM `64,478 -> 52,174` (**-12,304**), F7 Muxes
`28,422 -> 53,022` (**+24,600**), F8 Muxes `6,027 -> 18,315` (**+12,288**,
exactly `1,536 x 8`).

---

## The answer, up front

**Vivado's `[Synth 8-5859]` 3D-RAM recognizer accepted `cb` in build 10 and
declined it in build 11b. That single message is the gate; everything
downstream follows from it.**

MEASURED, from the two builds' own synthesis logs:

```
build 10  INFO: [Synth 8-5859] Recognized 3D RAM cb_reg.  This will most likely
                be implemented in Block/Distributed/Ultra RAMs.
                [/home/orencollaco/GitHub/llama.vhdl/rtl/matvec_core.vhd:692]

build 11b (no 8-5859 naming cb_reg anywhere in the log)
```

Line 692 in build 10's source is the `for c in 0 to CB_COPIES-1` write loop
inside `P_CB`. The message fires **once for the whole 3D array**, not once per
copy, so it is a decision taken on the **loop form, before unrolling** -- which
is the only way the two builds can differ at all, because after unrolling
`cbw_a(cb_rank_of(c))` is a constant index into a signal array exactly as
`cbw_a(c)` is, and the two netlists would be indistinguishable.

**What the design got instead, MEASURED from
`report_control_sets -verbose` at the placed stage in each build:**

| | control sets named `.../core/cbw_v[i]` | bel loads each | total |
|---|---|---|---|
| build 10 | **1,536** (`i = 0..1535`) | **16** | 24,576 LUTRAM bels |
| build 11b | **48** (`i = 0..47`) | **128** | 6,144 flip-flops |

`16` is one `RAM32M16` (14 `RAMD32` + 2 `RAMS32`). `128` is `16 entries x 8
bits`, i.e. the whole codebook in registers.

**So the 1,536 copies did not become 1,536 register banks. They collapsed to
48 -- one per RANK -- and the 1,536 independent read ports stayed, as 1,536
eight-bit 16:1 mux trees.** That is legal: every copy of a rank has a
byte-identical driver after `0b34200`, so equivalent-register merging folds
them; nothing merges the read ports because each lane reads its own index.

**This answers PLACEDIFF's open item (2), "where do the 196,608 bits of
codebook content live in build 11b".** They do not exist. There are 6,144
bits, replicated 48 ways instead of 1,536 ways, and the replication that used
to be free inside a LUTRAM is now paid for in fabric muxes.

**Repairable: yes, and the answer is the plain revert.** MEASURED, and this is
the control that decides it: **build 9 -- the bitstream on the card right now
at 2.46 tok/s -- carries the PRE-change codebook at the same
`CB_STYLE=distributed`, its log carries the same `8-5859 Recognized 3D RAM
cb_reg` and the same 1,536 `RAM32M16` rows, and it routed at WNS +0.061 /
TNS 0.000.** So the 1,536-sink command net that `0b34200` was written to fix
is **not** a routing problem on this part; build 10's -5.819 on that path class
is a fact about build 10's five-lever composition. A revert returns the
codebook to the netlist that is shipping. **Nothing was fixed here** --
`rtl/matvec_core.vhd` was not touched.

---

## The mechanism, at the lines

`rtl/matvec_core.vhd`, `P_CB`, the whole of the change (`0b34200`):

```vhdl
-- build 10 (0b34200^ = b71a6d9:rtl/matvec_core.vhd, md5 b616c782...), :690-694
for c in 0 to CB_COPIES-1 loop
  if cbw_v(c) = '1' then
    cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
  end if;
  ...

-- build 11b (5dc3ee5 = HEAD, md5 c3325ea1...), :804-808
for c in 0 to CB_COPIES-1 loop
  if cbw_v(cb_rank_of(c)) = '1' then
    cb(c)(to_integer(unsigned(cbw_a(cb_rank_of(c)))))
      <= signed(cbw_d(cb_rank_of(c)));
  end if;
end loop;
```

with, at `:332-335`:

```vhdl
function cb_rank_of(c : natural) return natural is
begin
  return (c * CB_RANKS) / CB_COPIES;
end function;
```

**MEASURED**: the recognizer's verdict changed, and the three
`cbw_*(c) -> cbw_*(cb_rank_of(c))` substitutions are the only edit inside that
process.

**DERIVED**: the recognizer must be matching the **un-unrolled loop**, because
after unrolling the two forms produce identical netlist structure (a constant
index into a signal array either way). The pattern it accepted has the RAM
array index and every port expression indexed by the **same loop variable**, so
slice `c` has a private address, data and enable. The new form indexes the RAM
array by `c` and the ports by a **user function call applied to `c`**, and the
pattern no longer matches.

**ESTIMATE, and this is the part that is NOT settled**: whether the gate is
*syntactic* (any index expression that is not the bare loop variable) or
*semantic* (the recognizer refuses when one write-port net would drive more
than one RAM). Those two have **different fixes**, and the OOC experiment
below is designed to separate them. Do not act on one without drawing it.

---

## Why I did not believe the inference log, and what I used instead

CLAUDE.md records that Vivado's inference log lies in both directions, and the
`[Synth 8-7186]` case it quotes **names `cb[0][0]` by name** -- claiming
`ram_style = "distributed"` was ignored one hundred times while every object it
named was a `RAM32M16` in the same run's mapping report. `rtl/matvec_core.vhd`
carries the same warning in its own comments at `:448-451`. So a message about
this object has a documented history of being false.

What I used, in order:

1. **The absence of a message is not evidence.** MEASURED: build 11b's log
   names `cb` in **no** message of any kind (`grep -c cb_reg` = **0**;
   `grep -cE '[^a-zA-Z_]cb[^a-zA-Z0-9_]'` = **0**). Its 101 `8-7186` warnings
   are `qbuf` at `rtl/gdn_block.vhd:396`, subsystem B. That is a null result
   and on its own says nothing.
2. **The positive control is what made the message admissible.** Build 10's
   FULL log survives at `/mnt/storage/fk33_builds/build10/build.stdout` (5.3 MB
   -- the copy committed into `hw/fk33/results/` is a 3 MB tail that never
   reaches synthesis, which is why PLACEDIFF could not make this comparison).
   It names `cb_reg` **3,073 times**: once as `8-5859`, and 3,072 times as
   `cb_reg[c][11] | User Attribute | 16 x 8 | RAM32M16 x 1` in the
   preliminary and final Distributed RAM Mapping Reports (1,536 distinct
   indices, max 1535). **A message that fires in one build and not the other,
   on the same source line of a byte-identical-except-for-this-change file, is
   a differential measurement and not a claim about the tool's honesty.**
3. **The census outranks both, and the census agrees.** `report_control_sets`
   counts BELS, not the tool's opinion: 1,536 x 16 LUTRAM bels became
   48 x 128 flip-flops. `report_utilization`'s primitive table agrees to the
   unit on `RAMD32` and on `MUXF8` (below).

---

## The evidence, as raw output

### The recognizer, both builds

```
$ grep -n "8-5859" /mnt/storage/fk33_builds/build10/build.stdout
7822:INFO: [Synth 8-5859] Recognized 3D RAM gqbuf[0].qbuf_reg. ... [rtl/gdn_block.vhd:749]
7823:INFO: [Synth 8-5859] Recognized 3D RAM gkbuf[0].kbuf_reg. ... [rtl/gdn_block.vhd:760]
7989:INFO: [Synth 8-5859] Recognized 3D RAM cb_reg.            ... [rtl/matvec_core.vhd:692]

$ grep -n "8-5859" /mnt/storage/fk33_builds/build11b/build.stdout
7834:INFO: [Synth 8-5859] Recognized 3D RAM gqbuf[0].qbuf_reg. ... [rtl/gdn_block.vhd:749]
7835:INFO: [Synth 8-5859] Recognized 3D RAM gkbuf[0].kbuf_reg. ... [rtl/gdn_block.vhd:760]
```

The two `gdn_block` rows are the **control that did not move**: the same
recognizer, in the same run, on a different 3D array that was not edited.

And the same three lines, from the build that is on the card
(`hw/fk33/results/card_kvreg_2026-09-20/build.stdout`, build 9, already
committed):

```
FK33_CB_STYLE distributed
INFO: [Synth 8-5859] Recognized 3D RAM gqbuf[0].qbuf_reg. ... [rtl/gdn_block.vhd:749]
INFO: [Synth 8-5859] Recognized 3D RAM gkbuf[0].kbuf_reg. ... [rtl/gdn_block.vhd:760]
INFO: [Synth 8-5859] Recognized 3D RAM cb_reg.            ... [rtl/matvec_core.vhd:692]
1,536 distinct cb_reg indices, max 1535; 3,072 RAM32M16 mapping rows
INFO: [Route 35-20] Post Routing Timing Summary | WNS=0.061 | TNS=0.000 | WHS=0.009 | THS=0.000
```

**Build 9 is the third data point and the one that decides the repair**: same
lever, same 1,536 copies, recognizer fires, routes clean.

### The Distributed RAM Final Mapping Report

```
build 10 , 1,536 rows of:
|matvec_core__GB9  | cb_reg[919][11] | User Attribute | 16 x 8 | RAM32M16 x 1 |

build 11b, the only matvec_core row:
|matvec_core__GB13 | xq_reg          | Implied        | 2 x 512| RAM32M16 x 37|
```

`xq_reg` is the control inside the same entity: LUTRAM inference in
`matvec_core` still works in build 11b; it is `cb` specifically that was
refused.

### The control sets, placed stage, both builds

```
$ grep "core/cbw_v\[" .../bd_wrapper_control_sets_placed.rpt \
    | awk -F'|' '{print $3, $6}'   # enable signal, Bel Load Count

build 10   1536 distinct nets cbw_v[0..1535]   bel-load histogram: 1536 x 16
                                               total 24,576
build 11b    48 distinct nets cbw_v[0..47]     bel-load histogram:   48 x 128
                                               total  6,144
```

**This is also the first time CBFANOUT's central claim has been counted by a
tool on a real build.** `1,536 -> 48` distinct command-register nets: MEASURED,
in the shipping netlist, not OOC and not DERIVED.

### Primitive census, both placed, both from `utilization_placed.rpt`

| primitive | build 10 | build 11b | delta | expected from `1,536 x cb` |
|---|---|---|---|---|
| `RAMD32` | 61,232 | 39,704 | **-21,528** | `1,536 x 14 = 21,528` **exact** |
| `RAMS32` | 8,236 | 5,156 | **-3,080** | `1,536 x 2 = 3,072` (+8) |
| `MUXF8` | 6,027 | 18,315 | **+12,288** | `1,536 x 8 = 12,288` **exact** |
| `MUXF7` | 28,422 | 53,022 | **+24,600** | `1,536 x 16 = 24,576` (+24) |
| `LUT6` | 130,880 | 186,555 | **+55,675** | `1,536 x 32 = 49,152` (+6,523) |
| `CLB Registers` | 308,213 | 296,396 | **-11,817** | see below |
| `RAMD64E` | 29,678 | 29,678 | **0** | control, the other DRAM family |
| `DSP48E2` | 2,087 | 2,087 | **0** | control |
| `SRL16E` | 1,439 | 1,439 | **0** | control |

**DERIVED, and the flip-flop line now closes to 1,383 where PLACEDIFF could
only say "neither confirmed nor refuted":**

```
cbw_* command registers   13 x 1536 = 19,968  ->  13 x 48 = 624   -19,344
cb storage                          0 (LUTRAM) ->  48 x 128 = 6,144   +6,144
                                                   codebook term   -13,200
measured, all seven changes                                        -11,817
residual for the other six changes                                  +1,383
```

**DERIVED, the per-copy trade:** one `RAM32M16` (8 LUT6 sites holding 16
LUTRAM bels, storage AND the 16:1 read select in the same silicon) is replaced
by `8 bits x (4 LUT6 + 2 MUXF7 + 1 MUXF8)` of read mux plus a 1/32 share of a
128-flop bank. **Losing the inference costs about 4x on the read path alone**,
because a LUTRAM's address decode is free and a fabric one is not.

### Tree identity, asserted rather than inferred

```
b71a6d9:rtl/matvec_core.vhd  md5 b616c7822f93154b08200f9418489012   (build 10)
0b34200^:rtl/matvec_core.vhd md5 b616c7822f93154b08200f9418489012   IDENTICAL
0b34200:rtl/matvec_core.vhd  md5 c3325ea1f418dcbcaa85f33e47e8c901
5dc3ee5:rtl/matvec_core.vhd  md5 c3325ea1f418dcbcaa85f33e47e8c901   (build 11b)
HEAD:rtl/matvec_core.vhd     md5 c3325ea1f418dcbcaa85f33e47e8c901
working tree                 md5 c3325ea1f418dcbcaa85f33e47e8c901
```

Build 10's `HEAD` file records `b71a6d98212ee9ebc6fdde6d5a3802154dabd232`.
**So for `matvec_core.vhd` specifically, the two builds differ by exactly
`0b34200`'s four hunks and by nothing else** -- and TRACK CBOOC's `old` arm
(`0b34200^`) IS build 10's file, byte for byte. The seven-change confound
PLACEDIFF correctly flagged for the whole design does not reach inside this
file.

Both builds ran at the same geometry: 1,536 distinct `cb_reg` indices in build
10's mapping table (max index 1535), and `MUXF8 +12,288 = 1,536 x 8` in build
11b.

---

## Relation to TRACK LEVERBOARD2's ESTIMATE, which landed while this was being written

`e3d7907` registered an ESTIMATE of the same mechanism and said outright that
*"TRACK CBRAM owns the mechanism ... its file is the authority over mine when
it lands."* Its words: *"at `distributed` `matvec_core.vhd:465` sets
`dont_touch of cb` false, while `cbw_*` stay true; before `0b34200` each
`cb(c)` was written from `cbw_a(c)`, 1,536 distinct undeletable drivers, so the
copies could not merge; after it 32 copies share each of 48 rank drivers and
become mergeable."*

**The OUTCOME it describes is exactly right and is now MEASURED** -- 48 banks
of 128 flip-flops, in the control-set report. **The ORDER is wrong, and the
order is what the fix depends on.** The copies were not inferred as RAM and
then merged: `[Synth 8-5859]` fires during module synthesis, at log line 7,989
of ~30,000 in build 10 and **not at all** in build 11b, before any merging pass
runs, and build 11b's Distributed RAM **Preliminary** Mapping Report is already
empty of `cb`. The RAM inference was refused up front; ordinary registers were
built; merging then folded them.

Why it matters: under the merge story the lever would be `dont_touch of cb`,
and setting it `"true"` at `distributed` would "fix" the merge -- **and would
give 1,536 x 128 = 196,608 flip-flops**, far worse than either build. Under the
measured story the lever is the write statement's form. **Do not reach for
`dont_touch` here.**

**What LEVERBOARD2 contributes that this file could not**: TRACK LEVERC48's
independent OOC measurement of the same geometry, `regs` minus `distributed`
at `ROWS_IF=48`, **FF +13,195** against this file's DERIVED `-13,200` for the
same decomposition, and `MUXF8 +12,288` to the unit. That turns the flip-flop
reconciliation from one arithmetic fit on one data point into a corroborated
one. Its refusal to NET 44,073 against 42,633 across synthesis contexts stands
and is not disturbed here.

---

## The repair: three options, weighed

### Option R1 -- revert `0b34200` outright. **THE ANSWER, and the thing it is said to reopen is MEASURED not to be a problem.**

I expected to have to write the opposite here. The brief, CBFANOUT's commit
message and my own first draft all say a revert reopens build 10's fanout
failure. **It does not, and the control that settles it is the bitstream
currently serving the user.**

MEASURED, `hw/fk33/results/card_kvreg_2026-09-20/build.stdout`, build 9, the
shipping image at 2.46 tok/s:

```
FK33_CB_STYLE distributed
INFO: [Synth 8-5859] Recognized 3D RAM cb_reg. ... [rtl/matvec_core.vhd:692]
   1,536 distinct cb_reg indices, max 1535; 3,072 RAM32M16 mapping rows
INFO: [Route 35-20] Post Routing Timing Summary | WNS=0.061 | TNS=0.000 |
                                                  WHS=0.009 | THS=0.000
FK33_TIMING WNS=0.061 ns  WHS=0.009 ns
```

**Build 9 has the pre-change codebook, at the same `CB_STYLE=distributed`,
with the same 1,536 copies and the same 13 command nets of 1,536 sinks, and it
routes clean.** So the `cb_addr_reg[i]/C -> cbw_a_reg[c][i]/D` path class is
not unroutable on this part. Build 10's WNS **-5.819** with 17,194 failing
endpoints on that class is a fact about **build 10's composition** -- five
additional levers at 82.19% LUT occupancy -- and not about the net.

That is the same shape as LEVERBOARD2's refusal (12) and as this project's
recurring failure: **a worst-path list tells you where a particular run's slack
went, not that the structure it names is the cause.** The same structure was
already routing at +0.061 two builds earlier.

So a revert returns the codebook to the exact netlist that is on the card right
now, and costs nothing that has ever been measured. `CB_RANKS` is a derived
constant, not a generic, so it must be an RTL change -- there is no build-time
way to turn `0b34200` off.

**LEVERBOARD2's "MANDATORY: revert the per-row codebook" for build 12 is
correct, and this track supplies the missing half of the argument: not only is
L-CB not worth 44,073 LUT, the problem it was written to solve is not present
in the configuration that ships.**

Options R2 and R3 below are recorded because the diagnosis makes them cheap to
reach, **not** because anything here recommends building them.

### Option R2 -- accept the mux tree. REJECTED, with the number.

MEASURED: build 11b placed at **CLB 54,822 of 54,960 = 99.75%, 138 tiles
free**, with CLB LUTs at **92.21%** against build 10's 82.19%. The mux tree is
**+44,073 LUT = 10.0 percentage points of the device's 439,680**. A design with
138 spare CLB tiles has nowhere to put that, and it consumed 71 CLBs rather
than freeing any.

I am deliberately **not** citing build 11b's WNS here. PLACEDIFF established
that the two builds ran three different implementation directives, so the
timing comparison is confounded; the area is a synthesis result and is not.
The area alone is sufficient to reject this option.

### Option R3 -- keep the 48 per-row command registers AND restore a write-statement form the recognizer accepts. **ON THE SHELF, NOT RECOMMENDED NOW.**

Given R1, this buys only the fanout reduction, and the fanout has not been
shown to bind on any routed build. **Do not put it on a card build.** It is
written down because (a) if a future composition reproduces build 10's
worst-path class, this is the fix that does not cost 44,073 LUT, and (b) the
two variants are the arms that answer the mechanism question, which is worth
one cheap OOC run whatever build 12 contains.

Two variants, and **which one is correct depends on the syntactic-vs-semantic
question that is still open**:

**R3a, the free one if it works** (`fan`). Keep `cbw_*` at 48 wide exactly as
now. Add a **combinational** per-copy alias in a generate, and write through
it, so the write statement is syntactically identical to the form build 10
had:

```vhdl
  -- declarations: per-COPY combinational aliases, no registers
  type cbx_a_arr is array(0 to CB_COPIES-1) of std_logic_vector(3 downto 0);
  type cbx_d_arr is array(0 to CB_COPIES-1) of std_logic_vector(7 downto 0);
  signal cbx_v : std_logic_vector(CB_COPIES-1 downto 0);
  signal cbx_a : cbx_a_arr;
  signal cbx_d : cbx_d_arr;
  -- NOTE: cbx_* must NOT carry dont_touch; they are wires, and a dont_touch
  -- signal is not a RAM inference candidate (matvec_core.vhd:423-425).

  -- concurrent, outside P_CB: the function call lives HERE, not in the
  -- RAM's address expression
  gen_cbfan : for c in 0 to CB_COPIES-1 generate
    cbx_v(c) <= cbw_v(cb_rank_of(c));
    cbx_a(c) <= cbw_a(cb_rank_of(c));
    cbx_d(c) <= cbw_d(cb_rank_of(c));
  end generate;

  -- inside P_CB, byte-identical in shape to 0b34200^
  for c in 0 to CB_COPIES-1 loop
    if cbx_v(c) = '1' then
      cb(c)(to_integer(unsigned(cbx_a(c)))) <= signed(cbx_d(c));
    end if;
  end loop;
```

Keeps `CB_WR_LAT = 1`. Keeps the whole `-19,344` flip-flop saving. Fanout
profile identical to today's build 11b: `cb_addr -> 48` register loads, then
each rank register drives its 32 copies. **Unproven**: whether the recognizer
follows a combinational alias.

**R3b, the certain one, at the cost of one cycle** (`bcast`). This is
`CB_BCAST`, which `rtl/matvec_core.vhd:413-421` already names and declines to
build. Restore `cbw_*` to `CB_COPIES` wide so the write statement is **byte
identical** to build 10's, and insert a new 48-wide rank stage `cbr_*` between
the ports and `cbw_*`. Fanout becomes `cb_addr -> 48 (cbr) -> 32 each (cbw)
-> 16 bels each`, i.e. **max 48, strictly better than R3a**. Cost:

- `CB_WR_LAT` 1 -> 2, and **that is not free.** DERIVED from
  `rtl/matvec_int4_desc_axi.vhd:995-1014`: with `CB_WR_LAT = 1` the last
  codebook write lands one full cycle before the core samples `start`; with
  `CB_WR_LAT = 2` it lands on **the very edge that leaves `S_IDLE`**, zero
  margin. The RTL's own comment at `:270-...` says the same thing
  independently. **Mitigation: one drain state between `S_CB` and `S_START`**
  in `rtl/matvec_int4_desc_axi.vhd`, costing one cycle per descriptor. That is
  a second file and a second owner; it must be coordinated, not assumed.
- Gives back most of `0b34200`'s headline: `19,968 + 624 = 20,592` command
  flops against build 10's 19,968, i.e. **+624 FF** rather than -19,344.

**If R3 is ever wanted, draw R3a first.** If it infers it is strictly the best
variant -- build 10's area with build 11b's fanout and flop count. If it does
not, R3b and the cycle. **Neither belongs in build 12.**

---

## The decisive OOC experiment, specified

**It was NOT run by this track.** Both Vivado lanes were held (workstation on
build 11b, BC-250 on TRACK ELABCLASS) and the brief forbade starting one.

### Harness

TRACK CBOOC's, one hierarchy level down from where it currently draws:
`sim/ooc_cbooc_run.sh` / `sim/ooc_cbooc.tcl`, **`CBO_TARGET=matvec_core`**.
`matvec_core` closes the `cb` cone and the fanout cone; it does **not** close
build 10's failing PATH (the startpoint `cb_addr` is a port there), which is
fine, because this question is about INFERENCE and AREA, both of which are
netlist facts fixed at `synth_design`.

### Geometry -- `CB_STYLE=distributed` is load-bearing

```
CBO_GEN="BLK=32 ROWS_IF=48 MAXCOLS=17408 MAXROWS_BFP=17408 \
         CB_ROWS_PER_COPY=1 CB_STYLE=distributed"
CBO_CLK="clk=13.333"
```

At `CB_STYLE=regs`, `CB_COPIES = CB_RANKS = 48` and `cb_rank_of` is the
identity, so **every arm is the same netlist** and the run prints four full
result rows measuring nothing. `sim/ooc_cbooc.tcl` already refuses `regs`.

### The four arms

| arm | `rtl/matvec_core.vhd` | how to build it |
|---|---|---|
| `old` | `0b34200^` (= build 10's, md5 `b616c782`) | `sim/ooc_cbooc_run.sh` makes it |
| `new` | `HEAD` (= build 11b's, md5 `c3325ea1`) | `sim/ooc_cbooc_run.sh` makes it |
| `fan` | R3a above | hand-made tree, drawn via `CBO_RTL=` |
| `bcast` | R3b above | hand-made tree, drawn via `CBO_RTL=` |

`old` and `new`: `CBO_TARGET=matvec_core bash sim/ooc_cbooc_run.sh`. Its
provenance assertion passes today (`matvec_core.vhd` has not moved since
`0b34200`; md5 `c3325ea1` at `0b34200`, at `5dc3ee5`, at `HEAD` and in the
working tree).

`fan` and `bcast`: **do not edit `sim/ooc_cbooc_run.sh`** -- it is CBOOC's.
`sim/ooc_cbooc.tcl` takes `CBO_TAG` / `CBO_TARGET` / `CBO_OUT` / `CBO_RTL` /
`CBO_GEN` / `CBO_CLK` from the environment, so each extra arm is one direct
`vivado -mode batch -source sim/ooc_cbooc.tcl` against its own `rtl/` tree,
with the same `CBO_GEN` string copied verbatim.

### Registered predictions, if the mechanism above is right

Written before any draw and not to be adjusted. The harness's own
`CBOOC_CB` line reports these.

| arm | `8-5859 ... cb_reg` | `cb_ram` | `cb_ff` | `cbw_ff` | `f8` |
|---|---|---|---|---|---|
| `old` | **fires** | **> 0** | **0** | 19,968 | baseline |
| `new` | **absent** | **0** | **6,144** | 624 | baseline **+12,288** |
| `fan` | **fires** | **> 0** | **0** | 624 | baseline |
| `bcast` | **fires** | **> 0** | **0** | 20,592 | baseline |

`cb_ram` is counted as `NAME =~ *cb_reg* && REF_NAME =~ RAM*`, which may
return 1,536 (RAM32M16 macros) or 24,576 (RAMD32/RAMS32 leaves) depending on
the stage; **the discriminator is `cb_ram > 0 with cb_ff = 0` against
`cb_ram = 0 with cb_ff = 6,144`, plus the MUXF8 step, not the absolute
number.** A zero on both is a broken filter, and the tcl already errors on it.

### Falsifiers, each naming what it kills

1. **`old` shows `cb_ram = 0`.** The geometry is wrong (almost certainly
   `CB_STYLE`), and **no number in the run is admissible**. Stop and fix the
   harness invocation.
2. **`new` shows `cb_ram > 0`.** The effect does not reproduce one level down,
   so it is not a property of `matvec_core` alone and this whole diagnosis
   falls. Next step would be `CBO_TARGET=matvec_int4_desc_axi`, and if that
   also infers, the cause is in the card context and only a card build can see
   it.
3. **`bcast` shows `cb_ram = 0`.** **This is the attribution control and it is
   the one that matters.** `bcast`'s write statement is byte-identical to
   `old`'s. If restoring it does not restore the inference, then the write
   statement's form is NOT the gate, my mechanism is wrong, and the diagnosis
   must be redone from the census rather than patched.
4. **`fan` shows `cb_ram = 0` while `bcast` shows `cb_ram > 0`.** The gate is
   SEMANTIC (a write port net may drive only one RAM), not syntactic. R3a is
   dead; take R3b and pay the `CB_WR_LAT` cycle.
5. **`fan` shows `cb_ram > 0`.** The gate is SYNTACTIC. R3a is the fix, at no
   latency and no flop cost. This is the outcome to hope for and the reason
   `fan` is in the run at all.

### Cost and lane

ESTIMATE, from CBOOC's own measurement of the identical geometry on the BC-250
(`matvec_int4_desc_axi` at `regs`, 713 s and 725 s): `matvec_core` at
`distributed` is **10-15 min per arm**, so **40-60 min for four** on one lane.
`CBO_CAP=8G`. **Never above `11G` on the BC-250** -- a 12G cap on that 14 GB
box made it unreachable and it is on no WoL watchdog.

---

## Measured and REJECTED -- do not retry

- **Reading build 11b's log for a message about `cb`. There is none, and the
  absence is not the finding.** `grep -c cb_reg` = **0**;
  `grep -cE '[^a-zA-Z_]cb[^a-zA-Z0-9_]'` = **0**. The 101 `8-7186` warnings in
  that log are `qbuf` at `rtl/gdn_block.vhd:396` and have nothing to do with
  the codebook. Anyone repeating PLACEDIFF's search will get the same null.
  **Go to build 10's full log instead** (below).
- **The committed `hw/fk33/results/card_build10_FAILED_2026-09-20/build.stdout.tail.gz`
  cannot answer this.** It is a tail that never reaches synthesis; it holds no
  `8-5859` and no mapping report. **The full 5.3 MB log does**, and until this
  track ran it existed only at `/mnt/storage/fk33_builds/build10/build.stdout`
  inside a reusable `BUILD_ROOT`. **It is now committed** as
  `build.stdout.full.gz` in the same directory (256 KB), so the comparison is
  repeatable from the repository alone. Use that one, not the tail.
- **`8-7186` as the instrument.** It did not fire for `cb` in either build, and
  CLAUDE.md records it firing falsely on this exact object in the past. It is
  not the message that decides distributed-RAM inference for a 3D array;
  **`8-5859` is.**
- **Explaining the LUT growth as "`cb` became registers".** REJECTED
  numerically: 1,536 x 128 = 196,608 flip-flops would be required and the
  design's register count went **DOWN** by 11,817. The control-set report gives
  the real answer (48 x 128 = 6,144) directly.
- **"A revert reopens build 10's routed failure."** REJECTED by build 9, which
  has the identical pre-change codebook at `CB_STYLE=distributed` and routes at
  **WNS +0.061 / TNS 0.000**. Three documents say otherwise and all three are
  downstream of build 10's worst-path list, which is evidence about build 10.
  **Do not re-derive this claim from a worst-path list without checking build
  9.** (`hw/fk33/results/card_kvreg_2026-09-20/build.stdout`, already
  committed, was in the tree the whole time.)
- **Reaching for `dont_touch of cb = "true"` at `CB_STYLE=distributed` to stop
  the merge.** It would stop the merge and produce **1,536 x 128 = 196,608
  flip-flops**, worse than either build. The merge is downstream of the refused
  inference, not its cause -- see the LEVERBOARD2 section. `matvec_core.vhd`
  already says at `:423-425` that a `dont_touch` signal is not a RAM inference
  candidate, which is why the attribute is `"false"` at `distributed` in the
  first place.
- **Attributing the LUT delta with the primitive table alone.** The two builds
  differ in seven RTL/config changes. What makes it attributable is the exact
  fingerprint `MUXF8 +12,288 = 1,536 x 8` and `RAMD32 -21,528 = 1,536 x 14`,
  plus `RAMD64E`, `DSP48E2`, `SRL16E` and `SRLC32E` unchanged to the digit.

---

## Measurement traps hit, including mine

1. **I mixed the synthesis-stage and placed-stage primitive tables and got
   RAMD32 `-20,906` instead of `-21,528`.** Build 11b has both reports
   committed; build 10 has only the placed one. Taking `RAMD32` from 11b's
   **synth** report and build 10's **placed** report produced a number that
   missed the exact `1,536 x 14` fit by 622 and would have read as "close but
   not structural". Re-run same-stage it is **exact**. This is the recorded
   "both ends from the same tree" rule applied to STAGES rather than trees, and
   the failure mode is identical: the arithmetic stays self-consistent.
2. **A naive `awk -F'|'` over the control-sets table read the wrong column.**
   The detailed table is `clock | enable | set/reset | Slice Load Count | Bel
   Load Count | Bels/Slice`, so `$5` is slices and `$6` is bels. Reading `$5`
   gave 48 sets summing to 1,528 "registers" -- a plausible-looking number that
   is not the one the question needs. The tell was that it was not a round
   multiple of anything; had it been, nothing would have looked wrong.
3. **`grep -o "cb_reg\[[0-9]*\]" | sort -u | wc -l` = 1,536 is not by itself a
   count of copies** -- it is a count of distinct indices appearing anywhere in
   a log whose mapping report is printed twice. It agrees with `max index =
   1535` and with `MUXF8/8`, which is why it is quoted; alone it would be a
   name-based census with no cross-check.
4. **I nearly wrote "a revert reopens build 10's failure" because the brief,
   the commit message and the RTL comments all say so, and I had three sources
   agreeing and no control.** Build 10's ten worst paths ARE
   `cb_addr_reg -> cbw_a_reg`; that is a correct reading of build 10 and it is
   not evidence that the net class is unroutable. The control that settles it
   -- build 9, same lever, same 1,536 copies, WNS +0.061 -- cost two minutes
   and was sitting in an already-committed log. **Three documents agreeing is
   not a control; they are downstream of one observation.** This is the "not
   the buffers" failure shape: ruling in a mechanism from one run's worst-path
   list, where there were never only two candidates.
5. **My own registered prediction was partly wrong and is recorded unadjusted.**
   Before reading the RTL I predicted the cause was that "the write address is
   no longer generated inside the same generate scope as `cb(c)`, so Vivado
   sees a memory whose address port is driven from a wider scope". There is no
   generate scope involved at all -- `P_CB` is a single process with a `for`
   loop, and the recognizer that declined is `8-5859`, which I had not heard
   of. The half that survived is "it is a decision about scope/form taken
   before unrolling"; the half that did not is the mechanism I named.

---

## Open, not determined

1. **Syntactic or semantic.** Whether the recognizer refuses the function call
   in the index expression, or refuses a shared write port. Arms `fan` and
   `bcast` separate them; nothing available without a synthesiser does.
2. **Whether `[Synth 8-5859]` is the only gate.** It is the only message that
   differs, and it is necessary; that it is *sufficient* is an inference from
   two runs, not a property of the tool that I have established.
3. **Whether the LUT growth is what broke build 11b's timing.** Untouched here,
   and PLACEDIFF's directive confound still stands. The mux tree could be on
   the critical path in its own right, or the congestion could be, or neither.
4. **Whether the codebook command fanout binds in ANY composition.** Build 9
   routes it clean at 1,536 sinks and build 10 does not, and what differs is
   five other levers plus the placer directive. Nothing here isolates which.
   **The right reading is that the fanout is not currently a problem, not that
   it can never be one.**
5. **The `S_CB -> S_START` drain state for R3b** is DERIVED from reading
   `rtl/matvec_int4_desc_axi.vhd:995-1014`. It has not been simulated, and
   `matvec_int4_desc_axi.vhd` is not this track's file.
6. **Whether the 48 merged register banks are what the design wants
   functionally.** They are legal -- all copies of a rank hold identical values
   by `0b34200`'s own invariant argument -- but the merge means `dont_touch of
   cb` is `"false"` at `CB_STYLE=distributed` and nothing now prevents Vivado
   merging further if a future edit makes the ranks equivalent too. Nothing
   tests for that.
7. **Build 9's placed AREA is still unknown** -- its log carries the routed
   timing and no utilization report, so the three-build area series has a hole
   exactly where the baseline should be. Its routed TIMING is now on the
   record here and is what the repair rests on.
8. **Nothing here is a silicon measurement.** The card was live and serving
   throughout and was not touched.

---

## Provenance

**Everything load-bearing is now committed, because it was not before.** The
captures live in `hw/fk33/results/cbram_2026-09-20/` (see its README), and the
full build-10 log at
`hw/fk33/results/card_build10_FAILED_2026-09-20/build.stdout.full.gz`. Every
copy was md5 round-trip verified against its source.

| committed | source, which is reusable scratch |
|---|---|
| `card_build10_FAILED_2026-09-20/build.stdout.full.gz` (uncompressed md5 `e938341e8ee6c5db...`) | `/mnt/storage/fk33_builds/build10/build.stdout`, 5,327,098 bytes, `HEAD = b71a6d98...` |
| `cbram_2026-09-20/build10_control_sets_placed.rpt.gz` (md5 `29ab2f0672...`) | `.../build10/root/.../impl_1/bd_wrapper_control_sets_placed.rpt` |
| `cbram_2026-09-20/build11b_control_sets_placed.rpt.gz` (md5 `b90562b649...`) | `.../build11b/root/.../impl_1/...` (`Date: Sun Sep 20 20:26:05 2026`) |
| `cbram_2026-09-20/ram_inference_8-5859.txt` | extracted from both `build.stdout` |
| `cbram_2026-09-20/control_sets_codebook.txt` | extracted from both control-set reports |
| already committed by PLACEDIFF | `card_build10_FAILED_2026-09-20/utilization_placed.rpt`, `card_build11b_2026-09-20/utilization_placed.rpt` |

Build 11b's `build.stdout` was read while the build was still running, read
only.

Nothing was written inside `/mnt/storage/fk33_builds/build11b/`. Scratch on
`/mnt/storage/fk33_builds/scratch/cbram`, never `/tmp`. No Vivado started. No
hardware.
