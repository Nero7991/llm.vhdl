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

---

## 2026-09-21 -- TRACK CBRUN ran the four arms. FALSIFIER 2 FIRED: the effect does not exist out of context, the mechanism above is NOT confirmed, and option R3a is not an option at all

TRACK CBRUN. Four arms, `CBO_TARGET=matvec_core`, `CB_STYLE=distributed`, on the
BC-250, all capped and verified. **No hardware. No Vivado on the workstation** --
that lane was claimed by the main session for a `matvec_int4_desc_axi` draw.
**`rtl/matvec_core.vhd` was NOT edited in the repository**: every arm is a tree
under `/mnt/storage/fk33_builds/scratch/cbrun`, and TRACK CBREVERT owns the repo
file. Captures and drivers: `hw/fk33/results/cbrun_2026-09-21/`.

### The question, verbatim

> `CBO_TARGET=matvec_core`, `CBO_GEN="BLK=32 ROWS_IF=48 MAXCOLS=17408
> MAXROWS_BFP=17408 CB_ROWS_PER_COPY=1 CB_STYLE=distributed"`, four arms.
> `bcast` is the attribution control and the row that matters most: its write
> statement is byte-identical to `old`'s. If restoring it does not restore the
> inference, CBRAM's mechanism is wrong and must be redone rather than patched.
> `fan` against `bcast` separates syntactic from semantic.

### The answer, up front

**There is nothing to separate. `cb` infers as distributed RAM in ALL FOUR arms,
to the same primitive count, at the card's geometry.** MEASURED from each arm's
post-`opt_design` checkpoint by `get_cells`:

    arm     cb_ram   cb_ff   RAM32M16   RAMD32   RAMS32   MUXF8
    old      26112      0      1573      22022     3146      0
    new      26112      0      1573      22022     3146      0
    bcast    26112      0      1573      22022     3146      0
    fan      26112      0      1573      22022     3146      0

Identical to the digit in every column, in every arm. `26,112 = 1,536 x 17`,
and the 17 decomposes exactly: **14 `RAMD32` + 2 `RAMS32` + 1 `RAM32M16` per
copy**, i.e. one `RAM32M16` macro and its sixteen bels. `1,573 = 1,536` for `cb`
plus the `37` of `xq_reg`, matching the `RAM32M16 x 37` row the card build's own
mapping report gives for `xq_reg`.

**This is falsifier 2 of the specification above -- "`new` shows `cb_ram > 0`:
the effect does not reproduce one level down, so it is not a property of
`matvec_core` alone and this whole diagnosis falls" -- and it has fired.** The
same verdict was reached concurrently and independently at
`CBO_TARGET=matvec_int4_desc_axi` by the main session (`cb_ram = 26112` in both
arms, `f8` delta `+0`, `lut_mem` delta `+0`), so it is not an artefact of
choosing `matvec_core`.

**So the mechanism this file proposes is NOT CONFIRMED.** The write statement's
form does not gate the inference at this level, in either direction:
`cbw_a(cb_rank_of(c))` infers exactly as `cbw_a(c)` does. The
syntactic-versus-semantic question left open above is answered *neither*: the
form is not a gate here at all.

**AND THE INSTRUMENT IS REFUTED, which is the more reusable half.**
`[Synth 8-5859]` names `cb_reg` in **none of the four arms** -- anchored count
**0** in each -- in runs whose Distributed RAM mapping reports name 1,536
`cb_reg` copies as `RAM32M16` and whose censuses agree. **An absent `8-5859` is
compatible with a fully successful inference, measured directly, four times.**
The diagnosis above rests on that absence in build 11b and it cannot bear the
weight. See the CORRECTION at the end of this section.

**Option R3a (`fan`) is not a repair option. It is the same netlist as `new`.**
MEASURED: `fan` and `new` agree on all twenty summary fields *and* on the total
cell, net and pin counts of the checkpoint, and `cbx_any = 0` -- the
combinational aliases do not exist in the netlist at all.

    arm     cells    nets       pins       cbx_any
    new    171716   2046259    4708060       0
    fan    171716   2046259    4708060       0
    old    191787   2066173    4806825       0
    bcast  191921   2066115    4809766       0

The alias folds away completely, so R3a cannot differ from `new` in any way, and
it could never have restored anything `new` lost. **This is CBOOC's
`CB_STYLE=regs` finding in a second place: two arms that are secretly one, which
would have printed a full result row and read as a careful negative.** Strike
R3a from the shelf.

**Is the revert still the right fix? Yes, and nothing here weakens it -- but it
now rests entirely on two CARD-level facts and not on this mechanism.** (1) Build
9 carries the pre-change codebook at the same `CB_STYLE=distributed` and routes
at WNS +0.061 / TNS 0.000, measured in this file from an already-committed log.
(2) Build 11b did not fail on timing, it failed to ROUTE, and 38 of the 40 nets
in its top-10 signal-overlap table are `bd_i/eng/inst/eng/dut/core/cb[][][]`
(MEASURED by the main session). **The revert was never contingent on the
`8-5859` story, and that is the only reason the recommendation survives the
mechanism falling.**

### The procedure, in order, and what each step isolates

1. **Prepare `old` and `new` where git lives**, with CBOOC's
   `sim/ooc_cbooc_run.sh` in `CBO_PREPARE_ONLY=1` mode -- the mode that exists
   for exactly this. Its provenance assertion passed, so `0b34200^` IS
   HEAD-minus-the-four-hunks and `old` is build 10's file rather than an
   imitation of the change. `MANIFEST.txt` carries the sha256s because the
   BC-250 sync copies no `.git`, so sha256 is the only form of the check that
   survives the crossing. All four recomputed identically on the far side.
2. **Build `fan` and `bcast` from `new`, not from `old`**, by anchored
   substitutions each asserted to match exactly once. From `old` they would have
   reintroduced all four hunks and been unattributable. `bcast`'s write statement
   is byte-identical to `old`'s (md5 `0e6469929f647e84414589a72db95817` of the
   extracted line in both) while its write LOOP is `new`'s split loop with only
   the index expressions changed -- a discriminator the specification did not
   have, separating the loop split from the index expression.
3. **Gate all four on GHDL elaboration before shipping.** All four print their
   announcement, then fail identically at time 0 with `overflow detected`
   (CBOOC's documented property of `matvec_core` as a TOP with `integer` ports at
   `integer'left`; `overflow_lines=1` and `assert_failures=0` in each). A
   `CBRUN_ARM=` field was added to `fan` and `bcast` because the gate keys on
   `CB_COPIES` and `CB_RANKS`, identical in `new`, `fan` and `bcast`; without it
   a mixed-up arm would have looked like a result.
4. **Verify the cap from inside the cgroup before exec'ing Vivado**, never from
   `systemd-run`'s exit status. This caught a real failure (trap 2 below).
5. **Draw all four through the same unedited `sim/ooc_cbooc.tcl`**, one Vivado at
   a time, so no harness difference lies on the same axis as the RTL difference.
6. **Check falsifier 1 after the first arm, before spending three more draws.**
   `old` gave `cb_ram = 26112`, so the geometry was right and the run admissible.
7. **Read the mapping report and the census, not the log's opinion.** This is
   what turned the expected result over, and it had to be done FIRST rather than
   as a confirmation step -- see trap 3.
8. **Re-open each arm's post-`opt_design` checkpoint** to name the command nets
   and count total cells, rather than re-synthesising. Same netlist, so the
   answer is exact rather than equivalent, and it costs ~80 s per arm.

### The evidence, as raw output

#### The recognizer, ANCHORED, all four arms

    arm     8-5859 total   8-5859 naming cb_reg   cb_reg RAM32M16 mapping rows   distinct cb_reg indices
    old          0                  0                      3072                         1536
    new          0                  0                      3072                         1536
    bcast        0                  0                      3072                         1536
    fan          0                  0                      3072                         1536

3,072 is 1,536 rows in each of the preliminary and final mapping reports;
`xq_reg` appears twice in each arm for the same reason.

**The greps MUST be line-anchored, and unanchored they are wrong in this exact
log.** `grep -c 'Synth 8-7186'` returns **24,577**; anchored on
`^WARNING: \[Synth 8-7186\]` it is **24,576 = 1,536 x 16 exactly**, once per
LUTRAM bel. `grep -c 'Synth 8-10226'` returns **1**; anchored it is **0**. Both
over-counts are the SAME single line: `sim/ooc_cbooc.tcl` echoes its own source
into the log, including the line that raises those two message limits:

    # foreach mid {{Synth 8-7186} {Synth 8-10226}} {

And every object the 24,576 warnings name is a `RAM32M16` in the same run's
mapping report -- CLAUDE.md's recorded `cb[0][0]` lie, reproduced verbatim and
now with an exact count:

    WARNING: [Synth 8-7186] Applying attribute ram_style = "distributed" is
    ignored, object 'cb[0][0]' is not inferred as ram due to incorrect usage
    [.../old/rtl/matvec_core.vhd:264]

    |matvec_core__GB10 | cb_reg[1023][11] | User Attribute | 16 x 8 | RAM32M16 x 1 |

#### The codebook census, `opt` stage, all four arms

    arm     cb_ram   cb_ff   cbw_ff   cbr_ff   cbx_any   cbwv_ff  cbwa_ff  cbwd_ff
    old      26112      0     19968       0        0       1536     6144    12288
    new      26112      0       624       0        0         48      192      384
    bcast    26112      0     19968     624        0       1536     6144    12288
    fan      26112      0       624       0        0         48      192      384

`cbw_ff` `19,968 -> 624` is exactly `13 x 1,536 -> 13 x 48`, delta **-19,344**,
structural and exact. `bcast` restores 19,968 and adds its own 624 `cbr_*` stage,
giving 20,592 command flops in total -- **but note the filter: `cbr_*` does not
match `NAME =~ *cbw_*`, so the specification's registered `cbw_ff = 20,592` for
`bcast` reads as 19,968 in that column by construction of the name, not by a
disagreement about the design.**

#### Utilization and primitive census, `opt` STAGE ONLY, never mixed with synth

    arm     lut     lut_logic  lut_mem   ff      MUXF7  MUXF8   DSP    BRAM   CARRY8  SRL
    old    78183     64769      13414   73463      3      0     1584   21.5    5866   830
    new    77560     64146      13414   54126      0      0     1584   21.5    5895   830
    bcast  77745     64331      13414   74092     10      0     1584   21.5    5808   830
    fan    77560     64146      13414   54126      0      0     1584   21.5    5895   830

Controls that did NOT move, which is what makes the rest attributable:
`lut_mem` 13,414, `DSP` 1,584, `BRAM` 21.5, `SRL` 830, `RAMD32` 22,022,
`RAMS32` 3,146, `RAM32M16` 1,573 -- identical in all four arms.

#### The command-net fanout, by NAME, from the checkpoints

    arm     distinct D nets   max FLAT_PIN_COUNT   histogram
    old            13               1537           1537x1 1536x12
    new            13                129            129x1   48x12
    fan            13                129            129x1   48x12
    bcast         624                 33             33x624

`FLAT_PIN_COUNT` counts the driver when the driver is a cell pin and not when it
is a top-level port, which is why the twelve port-driven nets read one lower
than the internally-driven valid net for the same load count.

#### WHICH of the thirteen is the outlier, and why -- the question the histogram cannot answer

    CBN_NET tag=cb_old   flat_pin_count=1537 loads=1536 to_cbw_v=1536 to_other=0  drivers=1 ports=0 name=cbw_v_reg0
    CBN_NET tag=cb_new   flat_pin_count=129  loads=128  to_cbw_v=48   to_other=80 drivers=1 ports=0 name=cbw_v_reg1
    CBN_NET tag=cb_fan   flat_pin_count=129  loads=128  to_cbw_v=48   to_other=80 drivers=1 ports=0 name=cbw_v_reg1
    CBN_NET tag=cb_bcast flat_pin_count=33   loads=32   to_cbw_v=32   to_other=0  drivers=1 ports=0 name=cbr_v[0..47]

    the other twelve, every arm:  cb_addr[0..3] and cb_data[0..7], ports=1,
    drivers=0, loads = exactly CB_RANKS (48) in new/fan and CB_COPIES (1536) in
    old, to_other=0 in every case.

**MEASURED: the outlier is the VALID bit, and it is the outlier because its net
is SHARED. 48 of its 128 loads are the `cbw_v` flops -- exactly `CB_RANKS`, as
registered -- and the other 80 are pins elsewhere in the core.** The twelve
address and data bits fell to exactly `CB_RANKS` because they are top-level
PORTS that drive nothing but the command registers; the thirteenth is an
internal logic net (the `cb_we and st = S_IDLE and rst = '0'` term) that also
feeds 80 unrelated sinks. In `old` the same net has `to_other = 0` and exactly
1,536 `cbw_v` loads.

**ESTIMATE for the mechanism, stated as an estimate:** at 1,536 loads Vivado
isolated that term onto its own replica, and at 48 loads it no longer did, so
the command net stayed merged with the shared decode. What is MEASURED is the
`48 + 80` split and the `1,536 + 0` split; the reason Vivado replicated in one
case and not the other is not established here. **This also predicts the
number is context-dependent, and it is: the main session measured 108 loads for
the same net at `matvec_int4_desc_axi` against 128 here.** So `109` and `129`
are the same finding in two contexts, and neither is `49`.

#### Memory, per arm -- and EVERY arm hit the cap

    arm     cgroup_peak_mb  at_cap  cgroup_swap_mb  summed_vmrss_gb  wall_s
    old         8195         YES         8635            9.64         1488
    new         8195         YES         8372            9.28         1258
    bcast       8195         YES         8432            9.58         1380
    fan         8195         YES         8066            9.60         1259

**All four `memory.peak` figures are the CAP, not the appetite**, and must not
be quoted as footprints: `MemoryHigh` forces reclaim rather than failing, so RSS
sits at the cap and `memory.peak` records the cap. The only honest size figure
from this run is Vivado's own accounting, `Memory (MB): peak = 3,941` for `old`
at its largest synthesis phase. The ~8.5 GB `cgroup_swap_mb` is the price of an
8G cap on a job whose cgroup charge includes its page cache; box swap in use
peaked around 6 GB of 48 GB and the swap guard (kill at 20 GB) never fired. The
cap was held at 8G for all four arms rather than raised to reduce the thrash,
because wall time is not a result this experiment needs and changing a cap
mid-experiment adds an unforced variable.

#### How the cap was verified, and the trap the verification caught

Never from `systemd-run`'s exit status. The wrapper reads `memory.high` out of
its OWN cgroup and refuses to `exec vivado` if it is `max` or unreadable. The
first form tried was `systemd-run ... bash -c '... $cg ...'`, and **systemd
expanded the `$cg` in its own command line before bash ever saw it**:

    Referenced but unset environment variable evaluates to an empty string: cg
    cgroup=/user.slice/.../cbrun_captest_2570525.scope
    memory.high=cat: /sys/fs/cgroup/memory.high: No such file or directory
    systemd_run_rc=0

A correctly named scope, a cap that WAS really applied, an `rc=0`, and a cap
check that verified nothing. Writing the wrapper to a FILE so no `$` reaches
systemd's command line fixes it, and the live runs then carried:

    CBRUN_CAP_READBACK cgroup=/user.slice/.../cbrun_old_2570677.scope memory.high=8589934592 memory.max=11811160064
    CBN_CAP_READBACK   cgroup=/user.slice/.../cbn_old_2985399.scope   memory.high=8589934592

`MemoryHigh=8G` throttles and `MemoryMax=11G` is a hard in-cgroup kill line, so
neither reaches the 11G ceiling that a 12G cap crossed when it made this box
unreachable.

### Registered predictions against results, unadjusted

| registered by | prediction | measured at `matvec_core` | verdict |
|---|---|---|---|
| CBOOC | `cbw_*` command flops `19,968 -> 624`, delta **-19,344** | 19,968 -> 624, **-19,344** | **HIT, exact** |
| CBOOC | total FF delta **-19,344** | **-19,337** (73,463 -> 54,126) | **near miss: 7 flops reappear elsewhere** |
| CBOOC | LUT delta **0** | **-623** (78,183 -> 77,560) | **MISS.** The main session measured **+1,456** at `desc_axi`: wrong in both runs, in opposite directions |
| CBOOC | 13 `cbw_*` command nets in BOTH arms, as a control | 13 in both | **HIT, and it is the control that makes the fanout row attributable** |
| CBOOC | max command-net fanout `1,537 -> 49` | `1,537 -> 129` | **MISS on the max.** Twelve of thirteen fell to exactly 48; the thirteenth is shared (above) |
| CBOOC | LUTRAM / DSP / RAMB36 / CARRY8 / MUXF7 / MUXF8 delta 0 | `lut_mem` 0, DSP 0, BRAM 0, SRL 0; **CARRY8 +29, MUXF7 -3** | partly MISS, small |
| CBRAM | `[Synth 8-5859] Recognized 3D RAM cb_reg` **fires for `old`**, absent for `new` | **absent for `old` too** | **MISS, and it refutes the instrument** |
| CBRAM | `MUXF8` `0 -> 12,288` on the `matvec_core` draw | **0 -> 0** | **MISS** |
| CBRAM | `old`/`fan`/`bcast` `cb_ram > 0` with `cb_ff = 0`; `new` `cb_ram = 0` with `cb_ff = 6,144` | `cb_ram = 26,112`, `cb_ff = 0`, in **all four** | **MISS on `new`: this is falsifier 2** |
| CBRAM | `bcast` gives back `+624 FF` over `old` | `74,092 - 73,463 = +629` | **HIT to 5 flops** |
| CBRAM | `bcast` fanout max 48, strictly better than R3a | max **32** on the 624 `cbr_*` nets, 48 on the port side | **HIT** |
| CBRAM | R3a keeps the whole `-19,344` flop saving | it does, because **it is the same netlist as `new`** | HIT, and vacuous |

### Measured and REJECTED -- do not retry

- **`[Synth 8-5859]` as the instrument for whether `cb` inferred.** MEASURED:
  absent in all four arms, including two in which 1,536 `RAM32M16` copies are
  named by the mapping report and counted by `get_cells`. It is also unavailable
  as a differential at this target for a second, independent reason: the positive
  control the section above relies on is `gdn_block`'s `qbuf`/`kbuf` rows, and
  **`gdn_block` is not in `matvec_core`'s closure at all**, so there is no
  control here even in principle. Use the Distributed RAM mapping report, which
  names the object, with the `get_cells` census as the cross-check.
- **Reproducing the card's mux tree out of context, at EITHER level.** MEASURED
  at `matvec_core` (`MUXF8 = 0` in all four arms) and at `matvec_int4_desc_axi`
  (`f8` delta `+0`, `cb_ram = 26112` both arms). The card's `+12,288 MUXF8` and
  `-12,304 LUT-as-Distributed-RAM` have no OOC counterpart at any level tried.
  **An OOC draw cannot answer what `cb` becomes on the card.** This is the
  recorded "the parts do not sum across synthesis contexts" rule landing on the
  codebook.
- **Option R3a, the combinational per-copy alias.** REJECTED with a proof rather
  than an opinion: `cbx_any = 0`, and identical cell, net and pin totals to
  `new`. It is the same netlist. Do not draw it again.
- **Treating the four arms' agreement on inference as four confirmations.** It is
  one null control counted four times. All four agree BECAUSE all four infer,
  which is exactly the state in which the arms cannot discriminate.
- **`CB_STYLE=regs` for this question.** Not retried; the reason stands.
- **Quoting any `memory.peak` from this run as a footprint.** All four are the
  8G cap.

### Measurement traps hit, including mine

1. **I wrote my own message greps UNANCHORED, in a project that has recorded
   this trap three times.** `8-7186` read 24,577 against a true 24,576, and
   `8-10226` read 1 against a true 0 -- both over-counts being the SAME line of
   the tcl's own source, echoed into the log by the very command that raises
   those message limits. The damage would have been precisely on the numbers
   whose exactness (`1,536 x 16`) was the reason for reading them.
2. **The cap readback I added to avoid ELABCLASS's trap had the same shape of
   bug itself**, and only a deliberate teeth test on a throwaway scope found it:
   systemd ate the `$cg` in the command line, so the check read
   `/sys/fs/cgroup/memory.high`, got "No such file", and exited 0. **Adding a
   verification step is not the same as verifying it**; the check had to be run
   against a state I had measured before I believed either it or the cap.
3. **My first reading of the live `old` log was "8-5859 = 0, so falsifier 1 has
   fired and the geometry is wrong".** It had not. The mapping report in the SAME
   log already named 1,536 `RAM32M16` copies. I reached for the message before
   the report because the message was the instrument the specification named --
   the recorded "read the census FIRST, not as a confirmation step after forming
   a theory", walked into from the other direction.
4. **My `CBN_RAMIN` histogram of the RAM cells' input nets is not trustworthy and
   I am not quoting its values.** It reports 24,577 distinct nets all with
   `FLAT_PIN_COUNT = 443,140`, which cannot be true of distinct nets; a batched
   `get_property` over ~10^5 nets appears to have mis-bound values to objects.
   It is used ONLY as a string-equality check between `fan` and `new`, which
   survives whatever the mis-binding is because the same mis-binding on the same
   netlist gives the same string. **A number that cannot be true is not a small
   error, it is a broken instrument**, and the tell was that it was not a round
   multiple of anything nor consistent with `CBOOC_FANOUT_TOP`'s single largest
   net.
5. **`summed_vmrss_gb` of 9.28-9.64 GB looks like the job's footprint and is
   not.** It sums Vivado's parallel-synthesis workers, which inherit the
   parent's argv, next to a cgroup pinned at 8G.
6. **`bcast`'s registered `cbw_ff = 20,592` reads as 19,968** because the census
   filter is `NAME =~ *cbw_*` and the new stage is named `cbr_*`. The arithmetic
   was right and the name was not in the filter. A prediction has to be written
   in the instrument's own terms or it scores as a miss it did not earn.

### CORRECTION, 2026-09-21: the claim that the recognizer DECLINED `cb` is WITHDRAWN

The section above states, as its answer up front, *"Vivado's `[Synth 8-5859]`
3D-RAM recognizer accepted `cb` in build 10 and declined it in build 11b. That
single message is the gate; everything downstream follows from it."*

**The first half stands as a positive observation** -- build 10's log does
contain `8-5859 ... Recognized 3D RAM cb_reg ... matvec_core.vhd:692`, and that
is a message that was really printed. **The second half is WITHDRAWN.** Build
11b's log carries no `8-5859` about `cb` in either direction, and MEASURED here
four times, an absent `8-5859` is compatible with a fully successful inference.
"Declined" was read off an absence. The section's own open item 2 asked whether
`8-5859` is *sufficient*; the answer is that it is not even *necessary*.

**What is NOT withdrawn:** the placed-stage census in the section above --
`RAMD32 -21,528 = 1,536 x 14`, `MUXF8 +12,288 = 1,536 x 8`, the control sets
going `1,536 x 16` LUTRAM bels to `48 x 128` flip-flops, and `RAMD64E`,
`DSP48E2` and `SRL16E` unchanged to the digit. Those are object-level
measurements on the real builds and they still say `cb` became a mux tree on the
card. **What has fallen is the explanation of WHY, and with it both shelf
repairs**, because neither can be tested in a context where the defect does not
appear.

### Open, not determined

1. **What actually differs between the card context and OOC**, such that `cb`
   becomes 1,536 mux trees there and 1,536 `RAM32M16` here, at the same
   generics, from the same RTL. Nothing in this run isolates it. The candidates
   nobody has separated are the `-mode out_of_context` flag itself, the enclosing
   hierarchy (`matvec_int4` -> `matvec_int4_desc_axi` -> `fk33_engine` ->
   `fk33_card` -> `bd_wrapper`), the card build's synthesis directive and
   `-flatten_hierarchy` setting, and device occupancy pressure at 92% LUT.
2. **Whether the card-context effect is a function of `0b34200` at all.** Both
   OOC levels now say the RTL difference alone does not cause it. The card
   evidence is two builds that differ in seven things. **This is not a small
   open item: it is the possibility that the codebook change is a bystander.**
   The revert is still right on the build-9 and build-11b-route evidence, but
   "L-CB caused the mux tree" is now less supported than it was this morning,
   not more.
3. **What the 80 non-`cbw_v` sinks of the shared valid net are.** MEASURED as
   80; not identified. One more checkpoint query would name them.
4. **Why Vivado replicated that term at 1,536 loads and not at 48.** ESTIMATE
   only, above.
5. **Whether `bcast` helps on the card.** Untestable here by construction, and
   its `+629 FF` and max-32 fanout are its cost, not a benefit. **Do not put it
   on a card build on the strength of this run.**
6. **Nothing here is a timing or routing result.** `synth_design` + `opt_design`
   only, no place, no route; the OOC WNS figures (+10.005, +10.015, +9.725,
   +10.015 at a 13.333 ns period, 0 failing endpoints in every arm) are not
   comparable to a routed number and are not quoted as one.
7. **Nothing here is a silicon measurement.** The card was live and serving
   throughout and was not touched.

### CORRECTION to the CBRUN section above, 2026-09-21, same day: THE CARD BUILD RAN A DIFFERENT CONFIGURATION, SO MY "CONTEXT EFFECT" WAS NEVER A CONTEXT EFFECT

`24fd4cc` landed while these four arms were drawing, and it MEASURES that
**build 11b ran at `FK33_CB_STYLE=regs`**: the anchored `^FK33_CB_STYLE`
sentinel reads 1/1/0 for builds 9/10/11b, and Vivado's own
`Parameter CB_STYLE bound to` reads `distributed x4 / distributed x4 / regs x4`.
At `regs`, `matvec_core` sets `dont_touch = true` and `ram_style = registers` on
`cb`, so the design FORBIDS its own RAM inference, and `CB_COPIES` is 48, making
`cb_rank_of` the identity. **`0b34200` was the identity function in build 11b
and did nothing.**

Two things in my section above are therefore WITHDRAWN.

1. **Open item 1, "what actually differs between the card context and OOC", and
   its whole candidate list** (`-mode out_of_context`, the enclosing hierarchy,
   the card's directive and flattening, 92% occupancy). **WITHDRAWN.** Nothing
   differed about the CONTEXT. My four arms ran at `distributed` and the card
   build ran at `regs`. I reached for this project's genuine recorded
   "the parts do not sum across synthesis contexts" finding to explain a plain
   configuration difference, and citing a real phenomenon is exactly what made
   the explanation feel grounded. `24fd4cc` withdraws the same error on its own
   side and names it better than I can.
2. **"The revert is still right, and now rests only on card-level evidence",
   where the second of the two facts was build 11b's route failure with 38 of 40
   overlap nets in `core/cb`. WITHDRAWN as evidence about `0b34200`.** At `regs`
   that commit is inert, so build 11b's codebook congestion cannot be evidence
   about it. Naming the object bounds WHERE, never WHY. What survives is only
   the first fact: build 9 carries the pre-change codebook at `distributed` and
   routes at WNS +0.061 / TNS 0.000. **The case for reverting `0b34200` is now
   materially weaker than my section stated, and build 12 -- HEAD at
   `FK33_CB_STYLE=distributed` with the other four levers off -- is the control
   that decides it, not this run.**

**What my four arms contribute AFTER the correction is more useful than what
they contributed before, and it bears on the build now in flight.** They are the
first synthesis evidence of HEAD's codebook at `CB_STYLE=distributed`, which is
build 12's configuration: **`cb` infers as 1,536 `RAM32M16` with `MUXF8 = 0`,
identically to the pre-change RTL, at the card's geometry.** So build 12 should
NOT carry the 12,288 `MUXF8` tree, and if it does, the cause is not `0b34200`.
That is a falsifiable prediction registered here before build 12 lands, and my
section's null result is exactly what `24fd4cc` predicts rather than a surprise.

**An independent cross-check the two runs did not plan.** `24fd4cc` decomposes
the card DCP's `xq_reg` as 518 `RAMD32` + 74 `RAMS32` = 37 x 16 children of 37
macros. My OOC census, on a different box and a different netlist, gives
`RAMD32 = 22,022` and `RAMS32 = 3,146` in all four arms, and
`22,022 - 1,536 x 14 = 518` with `3,146 - 1,536 x 2 = 74`. **Both residuals match
to the unit.** Two unrelated measurements agreeing on the leftover after the
codebook is subtracted is a real check on both censuses.

**And it confirms `REF_NAME =~ RAM*` over-counts, which my own `cb_ram` column
uses.** `24fd4cc` measures the over-count at 17.6x for `xq_reg`. My
`cb_ram = 26,112` is `1,536 x 17` = macro plus its sixteen bels per copy, which
I decomposed above rather than quoting as a macro count -- but the honest macro
figure is **1,536**, from `RAM32M16 = 1,573` less `xq_reg`'s 37, and that is the
number to quote. Read the `cb_ram` column as "macro plus children", never as
copies.
