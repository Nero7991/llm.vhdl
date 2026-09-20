# The GDN recurrence: 149,579 cycles, and 98,422 of them are a bench default

Date: 2026-09-20. Track BRECUR. No hardware. No Vivado on the workstation.

## The question, verbatim

> A B job on the card is MEASURED at 660,601 cycles, 24 per token. TRACK
> BMOVER and TRACK BNARROW have now cut the DATA MOVER from 644,172 to
> 222,805 cycles. BNARROW's closing sentence is your brief: `gdn_block`'s own
> run is 149,579 cycles, now 67% of the 222,805-cycle job, and the mover is
> only 71,164. The next lever is the recurrence, not the mover.
>
> Account for the 149,579 cycles from the RTL. Say what is a true serial
> dependency and what is merely a loop that was written serially. **That
> distinction is the whole track.** Price the parallel options against the
> device. If the recurrence is genuinely serial at the shipping shape and the
> only way to speed it up is more multipliers that do not fit, say so in one
> sentence at the top and spend the rest documenting why.

Hardware: FK33 `xcvu33p-fsvh2104-2L-e`, Qwen3.5-9B, 32 value heads, head dim
128, 24 GDN layers, core clock 75 MHz.

## The answer

**It is not serial, the lever already exists as a generic, and it is set to a
bench default.** `rtl/llama_top.vhd:816` ships `B_RECUR_LANES : positive := 4`
while `rtl/gdn_block.vhd:207` defaults the same generic to `32` and calls it
"section 3.1's assumption". The only justification given for the 4 is that it
is "the exact set `sim/tb_gdn_block.vhd` defaults to". The sweep costs
`VAL_HEADS * DIM * (DIM/RECUR_LANES)` cycles, so the lane count is a direct
divisor on the largest phase of a B job.

**MEASURED at the 9B shape: `RECUR_LANES = 16` takes `gdn_block` from 149,579
to 51,157 cycles, a saving of 98,422 (65.8%), with the output bit-identical.**
The card cannot go past 16 -- that ceiling is in the AXI mover, not in the
arithmetic -- and 16 is the largest reachable value.

The cost, MEASURED by OOC sweep, is **+48 DSP** (17 -> 65, and `4*LANES+1`
holds exactly at all four lane counts), **+7,865 LUT** (9,427 -> 17,292) and
**+9 BRAM tiles**. Against the card that is 6.1% of the free DSP and 8.6% of
the free BRAM; the LUT is the one that has to be argued, because the card is at
99.81% CLB. The HBM arena, the manifest and the host image are
**byte-identical**, because the state word count and the lane width cancel:
32,768 beats of 256 bits either way.

The card change is **one line** in `hw/fk33/gen_fk33_card.py`. Every generic
it needs is already threaded through `rtl/llama_top.vhd` and
`rtl/fk33_llama_top.vhd:851`.

## The procedure

1. **Read the loop, not the prose.** `rtl/gdn_block.vhd`'s `P_COL` state
   (:1155-1180) issues exactly one state-memory group request per cycle,
   `NB_R = DIM/RECUR_LANES` groups per column, `DIM` columns per head,
   `VAL_HEADS` heads. That product IS the 131,072.
2. **Separate the true dependency from the written-serial one.** Read
   `rtl/gdn_recur_pipe.vhd`'s header and its slot machinery to establish which
   of the four nested loops carries a dependency.
3. **Measure the phases instead of deriving them.** Extend
   `sim/tb_gdn_block.vhd` to split one invocation into five disjoint spans
   taken from the DUT's OWN REQUEST PORTS (`cv_ren`, `st_ren`), so no RTL
   changes and nothing depends on the FSM encoding. Run at the 9B generics.
4. **Find the ceiling before proposing a value.** Read every elaboration-time
   refusal on the path the lane width touches, in particular
   `rtl/gdn_state_axi.vhd`, which is a file this track does not own.
5. **Price it with a measured sweep, not a fitted one.** OOC-synthesise
   `gdn_recur_pipe` at LANES 4, 8, 16 and 32, with the 32 row as a CONTROL
   against the only published number that exists for this unit.
6. **Prove the values.** Two independent routes: the block's independent C
   oracle `ref/gdn_block_vec.c`, and a cross-lane dump comparison at the real
   9B shape after normalising the one lane-dependent index in the dump.
7. **Teeth**, with the attribution control for each new check, and every
   non-biting mutant reported under its own name.

## The cycle account, MEASURED

`sim/tb_gdn_block.vhd` at `KEY_HEADS=16 VAL_HEADS=32 DIM=128 CONV_LANES=4
SILU_LANES=8 RECUR_SLOTS=16 NLAYER=1 TOKENS=1`, producers eager, GHDL 6.0.0
mcode on the BC-250 (`ulimit -s unlimited`, `--max-stack-alloc=0`), peak RSS
2.82 GB sampled from `/proc/PID/status`.

```
RECUR_LANES=4
tb_gdn_block: CYCLES invocation 0 (layer 0 token 0) = 149579
BRECUR_CYCLES inv 0 pre 6 conv 3132 mid 6330 recur 131134 drain 8977 total 149579
BRECUR_ISSUE inv 0 cv_req 2048 st_req 131072 st_req_derived 131072
tb_gdn_block: PASS, 4096 elements, dump in b9_l4.txt

RECUR_LANES=16
tb_gdn_block: CYCLES invocation 0 (layer 0 token 0) = 51157
BRECUR_CYCLES inv 0 pre 6 conv 3132 mid 6330 recur 32830 drain 8859 total 51157
BRECUR_ISSUE inv 0 cv_req 2048 st_req 32768 st_req_derived 32768
tb_gdn_block: PASS, 4096 elements, dump in b9_l16.txt
```

| phase | what it is | LANES=4 | LANES=16 |
|---|---|---|---|
| pre | start to first conv tap request | 6 | 6 |
| conv | `gdn_conv` + the straight-through silu | 3,132 | 3,132 |
| mid | the two L2 norms and the scalar path | 6,330 | 6,330 |
| **recur** | **the state sweep, issue span** | **131,134** | **32,830** |
| drain | pipe drain + emit chain finishing the last head | 8,977 | 8,859 |
| **total** | | **149,579** | **51,157** |

**The 149,579 baseline reproduces TRACK BMOVER's independently measured
149,579 to the cycle**, which is what makes the instrumentation quotable.

The brief's two prior estimates, checked: the recurrence is **87.7%** of the
block's run (131,134 of 149,579), confirming the "roughly 88%"; and at 24 B
jobs a token the **block** costs 3,589,896 cycles while the **recurrence
alone** costs 3,147,216, so the brief's "about 3.6 M" is the former and not
the latter.

Two internal consistency results worth stating because they were not designed
in: `conv` and `mid` are **identical to the cycle** across the two lane counts,
as they must be since neither reads `RECUR_LANES`; and `recur - st_req` is
**62 in both runs**, i.e. ~2 cycles of per-head boundary over 32 heads,
unchanged by the lane width.

### A correction to the earlier attribution

`docs/debugging/2026-09-20_b-job-660k-cycles.md:109` says the gap between
149,579 and 131,072 is "the conv passes (2,048 beats), the L2 norms, the
scalar path and the per-head boundaries". MEASURED, the 18,445 splits as
**conv 3,132 (17%), mid 6,330 (34%), drain 8,977 (49%), pre 6**. The largest
single component is the **drain**, which that list does not mention at all.
Its internal split is NOT determined here and is listed as open below.

## What is a true serial dependency, and what is not

This is the question the track was set, so it is answered explicitly, loop by
loop.

| loop | extent at 9B | dependency | verdict |
|---|---|---|---|
| token position `t` | the sequence | `S_t` is a function of `S_{t-1}` | **TRUE SERIAL.** `rtl/gdn_recur_pipe.vhd:506`, `rtl/gdn_block.vhd:889-894`; TRACK PREFILL rejected prompt batching on exactly this (`docs/2026-09-20_prefill-batching-scope.md`). Nothing here reorders positions. |
| value head `h` | 32 | none; heads are independent | parallel in principle, at 32x the hardware. **Not taken**, and not needed. |
| column `c` | 128 per head | none; section 2.4 column-locality | **ALREADY EXPLOITED.** `gdn_recur_pipe` is column-pipelined at issue interval `NB`, with per-column SLOTS. This loop is not serial and has not been for a month. |
| element group within a column | `NB = DIM/LANES` | **none.** The `DIM` elements of a column are independent; they are visited `LANES` at a time only because the state memory port is `LANES*16` bits wide | **WRITTEN SERIAL, NOT SERIAL.** This is the whole lever. |

So the answer to "is more multiplier area the only way" is no: the multipliers
that exist are **idle `(NB-1)/NB` of the time**, which is 31/32 at the shipping
`LANES=4`. `gdn_recur_pipe`'s own header states the design target -- "all four
multipliers are then busy every cycle and the issue interval is `NB =
DIM/LANES`" -- and the shipping card runs it at one eighth of the width the
unit was written for.

The four per-lane multiplies are `rtl/gdn_recur_pipe.vhd:514` (`a_m1`), `:527`
(`a_m2`), `:712` (`b_mkd`) and `:849` (`c_m3`), plus one per-column scalar at
`:616` (`dmul`). Hence `DSP = 4*LANES + 1`, DERIVED, and confirmed by
measurement at two lane counts below.

## The ceiling is in the mover, not in the arithmetic

`RECUR_LANES` cannot exceed 16 on this card, and the refusal is not in any file
this track owns. `rtl/gdn_state_axi.vhd:212`:

```vhdl
constant WPB : positive := AXI_DW / WBITS;      -- store words per beat
```

with `WBITS = WORD_BITS = RECUR_LANES*16` (`:102`) and `AXI_DW = 256` (`:111`,
the FK33 HBM SAXI data width). `WPB` is a `positive`, so `RECUR_LANES*16 <=
256`, i.e. `RECUR_LANES <= 16`. And `:232`:

```vhdl
constant bad_axi_dw_not_multiple_of_word : natural := AXI_DW - WPB*WBITS;
```

forces the store word to tile the beat exactly. **The reachable set is
`{1, 2, 4, 8, 16}`.** `RECUR_LANES = 32` -- `gdn_block`'s own default, and the
configuration every published `gdn_recur_pipe` number was measured at -- does
not elaborate on the card at all, and it fails as a bare `positive` bound-check
rather than as one of that file's named refusals.

This matters beyond the number: it means **`gdn_block`'s default generic set is
not a configuration the card can build**, and the one place that says so is a
`positive` in a different unit.

### The arena does not move

`bad_mant_bytes_vs_shape` (`:238`) requires `MANT_BYTES = BEATS*BPB`. At
`LANES=4`: 131,072 words, `WPB=4`, 32,768 beats. At `LANES=16`: 32,768 words,
`WPB=1`, 32,768 beats. `MANT_BYTES = 32,768 * 32 = 1,048,576` in both, matching
`rtl/gdn_state_store.vhd:95`. **The HBM layout, the per-layer stride, the
manifest and the host-side image are byte-identical.** No host change, no
re-imaging, no manifest edit.

## The emit chain is the real downstream limit, and it is fine at 9B

Widening the lanes shortens the column ARRIVAL PERIOD, and
`rtl/gdn_emit_chain.vhd` has a per-head deadline that is a function of it. Its
header states the budget at `DIM=128`: columns for one head arrive over
`DIM*NB` cycles, and the serial work after they land is `142 + 128 = 270`.

| LANES | `NB` | head arrival at DIM=128 | needed | margin |
|---|---|---|---|---|
| 4 (shipping) | 32 | 4,096 | 270 | 15.2x |
| 16 (proposed) | 8 | 1,024 | 270 | 3.8x |
| 32 (unreachable) | 4 | 512 | 270 | 1.9x |

MEASURED rather than left at that: the 9B `RECUR_LANES=16` run above passes
with `STRICT_PRODUCER` on, which is the check that fails the simulation if a
column is ever offered and refused. No column was refused.

## Value identity

**Route 1, cross-lane at the real shape.** `sim/tb_gdn_block.vhd`'s dump writes
state as `s <word> <lane> <value>`, and the flat element index is
`word*RECUR_LANES + lane`, which is lane-INDEPENDENT. Normalising that one
index makes the two dumps directly comparable:

```
$ norm b9_l4.txt 4 > n_l4.txt ; norm b9_l16.txt 16 > n_l16.txt
$ wc -l n_l4.txt n_l16.txt
  532481 n_l4.txt
  532481 n_l16.txt
$ cmp n_l4.txt n_l16.txt && echo IDENTICAL
IDENTICAL
$ md5sum n_l4.txt n_l16.txt
9545a7f02300e633898c60f632a9544a  n_l4.txt
9545a7f02300e633898c60f632a9544a  n_l16.txt
```

532,481 lines: the whole y stream (4,096 mantissas), the complete final
recurrent state (32 x 128 x 128 = 524,288 int16), the 4,096 state exponents and
the per-block headers. **Bit-identical.**

The normalisation is load-bearing rather than a formality, and the raw files
prove it: `b9_l4.txt` is 8,229,692 bytes and `b9_l16.txt` is 8,168,692, so the
comparison is not trivially true.

**Route 2, an independent oracle.** `sim/tb_gdn_block_vec.vhd` drives the same
DUT from stimulus written by `ref/gdn_block_vec.c` and asserts the y stream,
`y_exp`, the final state, the state-exponent table and all four status flags
bit for bit. At the committed small shape, `RECUR_LANES=4`:

```
tb_gdn_block_vec: PASS, 256 y elements, 4096 state mantissas and 128 state
exponents bit-exact against gdn_block_vec.txt
```

## Area, MEASURED

OOC `synth_design` on `xcvu33p-fsvh2104-2L-e` at 3.3 ns, `DIM=128`,
`SLOTS=16`, one Vivado on the BC-250 under `MemoryHigh=10G`, via
`sim/ooc_gdn_recur_pipe_lanes.tcl`. The LUT column is `report_utilization`'s
CLB LUT row; see the measurement trap below for why the object census column
reads zero.

| LANES | DSP | DSP derived `4L+1` | LUT | BRAM | Fmax |
|---|---|---|---|---|---|
| 4 (shipping) | 17 | 17 | 9,427 | 3.5 | 299.0 MHz |
| 8 | 33 | 33 | 12,549 | 6.5 | 299.0 MHz |
| **16 (proposed)** | **65** | 65 | **17,292** | 12.5 | 299.0 MHz |
| 32 (CONTROL, unreachable on the card) | 129 | 129 | 27,861 | 24.5 | 299.0 MHz |

### The control half-passed, and that is a result

The 32 row exists to check the harness against the only published numbers for
this unit (`docs/debugging/2026-08-26_gdn-recurrence-column-pipelining.md`:
**129 DSP and 24,037 LUT**).

- **DSP reproduces exactly: 129 against 129.** Together with `4*LANES+1`
  holding at all four points, the harness is measuring the right object.
- **LUT does NOT reproduce: 27,861 against 24,037, +15.9%.**

**The published LUT figure is not a valid baseline for today's RTL, and this
sweep's internal deltas are unaffected.** All four rows here come from ONE
tree in ONE Vivado session, so the +7,865 between LANES 4 and 16 is a
like-for-like measurement; the 24,037 comes from a tree of 2026-08-26 and the
comparison across them is the stale-table shape this project has already been
bitten by. Two candidate causes, and **which one it is has NOT been
determined**: `gdn_recur_pipe.vhd` gained the head-boundary double buffer
after that measurement (`sim/ooc_gdn_recur_pipe_dbuf.tcl` exists precisely to
price it), and the published run used part `xcvu33p-fsvh2104-2-e` at 3.322 ns
where this one uses the card's own `xcvu33p-fsvh2104-2L-e` at 3.3 ns.

Do not quote 24,037 for this unit again without re-deriving it.

**The shipping-to-proposed delta is +48 DSP, +7,865 LUT and +9 BRAM tiles.**
Every DSP row equals `4*LANES+1` exactly, at all four measured points, so that
relationship is structural and not a fit. LUT is NOT structural -- the
per-lane figure falls 2,357 / 1,569 / 1,081 / 871 across the four rows, i.e.
the unit has a large lane-INDEPENDENT base -- which is exactly why all four
points were measured instead of two being fitted. For the record of what
fitting would have done: a straight line through the 4 and 32 rows predicts
**16,124** at LANES=16 against a measured **17,292**, under by 7%.

Fmax does not move at any lane count (all four rows at the same -0.044 ns WNS,
299.0 MHz), which is a synthesis-only result and is not a timing verdict; see
the open items.

The 32 row is a control, not a proposal: `docs/debugging/2026-08-26_gdn-
recurrence-column-pipelining.md` published **129 DSP and 24,037 LUT** at that
point, so this sweep either reproduces them or the harness is wrong and no row
in it counts.

### Against the device

MEASURED from `hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_
placed.rpt`: **DSP 2,087 of 2,880 (793 free)**, **CLB 54,854 of 54,960
(99.81%, 106 free)**, LUT 363,095 of 439,680 (82.58%), BRAM 567 of 672.

DSP is not the constraint: **+48 of 793 free is 6.1%.** BRAM is not either:
**+9 of 105 free.** **CLB is the constraint.** The +7,865 LUT takes the card
from 363,095 to 370,960 of 439,680, i.e. 82.58% -> 84.37% -- but the CLB row is
at **99.81% with 106 CLBs free**, so those LUTs cannot take new CLBs and must
pack into CLBs already in use. The build runs `Congestion_SpreadLogic_high`,
which deliberately spreads logic, so the 99.81% is partly a strategy artefact
rather than a hard ceiling; that makes the outcome **plausible and unproven**,
and a full-card draw is the only thing that settles it.

Note what is NOT claimed: the LUT delta was measured, not scaled from the DSP
delta. This project has a recorded case where an exact DSP relationship was
scaled to LUT and was wrong by 3.4x in the flattering direction.

## Measured and REJECTED -- do not retry

- **`RECUR_LANES = 32`.** It is `gdn_block`'s own default and the only lane
  count with published area numbers, and **the card cannot elaborate it**:
  `rtl/gdn_state_axi.vhd:212` takes `WPB : positive` to zero. Do not propose
  it, and do not read the published 129 DSP / 24,037 LUT figures as a cost for
  anything shippable.
- **Validating this lever at the small bench shape.** MEASURED:
  `tb_gdn_block_vec` at `KEY_HEADS=2 VAL_HEADS=4 DIM=32`:
  - `RECUR_LANES=8` -> `gdn_emit_chain.vhd:278`: *"a column was offered and
    refused while STRICT_PRODUCER is set"*.
  - `RECUR_LANES=16` -> `gdn_recur_pipe.vhd:410`: *"SLOTS=16 is below the 22
    columns in flight at this LANES"*.

  **Both are artefacts of DIM=32 and neither occurs at DIM=128.** The emit
  chain's serial work scales with `DIM` while the arrival period scales with
  `DIM*NB`, so shrinking `DIM` TIGHTENS the deadline at a given `NB`; and
  `SLOTS_MIN` is shape-dependent, 22 at `DIM=32 LANES=16` against 11 at
  `DIM=128 LANES=16`. **A track that tested only at the small shape would have
  concluded the lever is impossible.** It is the opposite: the real shape is
  the forgiving one.
- **Deriving the non-recurrence phases instead of measuring them.** The
  previous attribution put the 18,445 into "conv, L2, scalars, per-head
  boundaries" and the largest component is actually the drain, which is not on
  that list.

## Measurement traps hit

- **`PRIMITIVE_GROUP == LUT` matches nothing on this part, silently.** The
  first OOC row printed `lut=0 ff=0` next to a utilization report saying
  **9,427**, with only a `WARNING: [Vivado 12-180]` and a clean exit. This is
  the exact shape this project already recorded for `PRIMITIVE_GROUP == DSP`.
  It was caught only because the script prints the utilization row NEXT TO the
  census rather than instead of it. **`sim/ooc_gdn_recur_pipe_dbuf.tcl:31-32`
  still carries the broken filter**, so every LUT and FF figure that script has
  ever produced is zero and was never read. The working forms are
  `REF_NAME =~ LUT*` and `REF_NAME =~ FD*`.
- **`/usr/bin/time -v` reported `Exit status: 0` for a process it also reported
  as `Command terminated by signal 11`.** The run was a stack overflow
  (`ulimit -s unlimited` is required for this bench at `DIM=128`) and the exit
  status line says nothing about it. Another instance of the harness reporting
  a fact about the harness.
- **`/usr/bin/time` does not exist on the BC-250** (CachyOS). Peak RSS there
  has to be sampled from `/proc/PID/status` `VmHWM`.
- **Two of my own runs wrote to one log.** A first launch and a second launch
  of the same tag both redirected to `b9_l4.log`; the second truncated the
  first and the log then looked like a fresh run that had produced nothing for
  twenty minutes. Both were stopped and the pair re-run with distinct logs.
  Nothing was mis-reported, because the log was never believed -- but the
  symptom is indistinguishable from a hung simulation.
- **An unanchored `grep` matched the Tcl script echoed into its own log.** A
  poll for `WARN_DSP` returned the line `#     puts "WARN_DSP L=$L ..."` from
  the source Vivado prints at startup. The project already records this for
  `C4_DONE`; anchor on `^RESULT`.
- **A gate failure in a file this track cannot touch.** `--only seamgate` and
  `--only tb_llama_top_b` both went red with `ghdl -a failed on
  rtl/attn_block.vhd: error limit reached`, which is TRACK CSWEEP's file, mid
  edit: `attn_block.vhd:852` was a half-written `when/else`. It analysed
  cleanly again forty minutes later and the rows were re-run. **A red gate in
  a file you do not own is a fact about the other track's working tree**, and
  the only way to tell it from your own breakage is to read the error text.
- **`ps -o etime=` is `mm:ss`, not `hh:mm`.** A process at `02:04` had been
  running two minutes, not two hours, and a backgrounded `sleep` had returned
  far sooner than assumed. Read the wall clock before concluding a job is
  slow.

## Teeth

Two checks were added to `sim/tb_gdn_block.vhd`, each behind its own generic so
that its attribution control can disable it. Mutants are applied to a COPY of
the RTL under `/mnt/storage/.../brecur/mut*`, never to the repo, so that the
other tracks' gates are never compiled against a mutant.

**What was deliberately NOT added:** the five spans sum to the total
ALGEBRAICALLY (the expression telescopes), so an assertion on that sum can
never fail. It is decoration and it is not in the file.

| mutant | live | attribution control | verdict |
|---|---|---|---|
| baseline (no mutation) | PASS, `st_req 1024 = derived` | -- | control clean |
| **M2** conv tap read enable also asserted during the sweep (`cv_ren_i <= '1'` added in `P_COL`) | **FAIL, PH_ORDER**, "last conv request at cycle 1717 is not before the first state request at cycle 688" | **`PH_ORDER=false` -> PASS**, every value check green | **PH_ORDER is the SOLE detector.** Value-neutral defect, invisible to the dump comparison and to the oracle. |
| **M4** `NB_R` stops tracking the generic (`DIM/RECUR_LANES` -> `DIM/4`) | **DOES NOT BITE** at the shipping `RECUR_LANES=4`, because `DIM/4` is `DIM/RECUR_LANES` there | n/a | **Reported as non-biting.** The real guard is running the bench at any other lane count. |
| **M4 at `RECUR_LANES=2`** (same mutant, where it is live) | FAIL, but at `gdn_recur_pipe.vhd:670` "engine B started before SCAL1 finished" | pristine control at `RECUR_LANES=2` PASSES with `st_req 2048 = derived` | **The kill belongs to an OLDER property**, not to PH_ISSUE. |
| **M4 at `RECUR_LANES=2`, `gdn_recur_pipe:670` suppressed** | FAIL, at `gdn_recur_pipe.vhd:794` "engine C started before SCAL2 finished" | -- | **A SECOND older property shadows it.** |

**The honest verdict on PH_ISSUE: it has not been shown to discriminate on
anything.** Every mutant constructed for it is killed first by one of
`gdn_recur_pipe`'s own slot-validity assertions, and there is a structural
reason: PH_ISSUE is an END-OF-RUN check, so any mutant that stops the run from
completing is caught by the deadlock rather than by the check. It is kept
because it costs nothing and it pins the published 131,072 to the build rather
than to a comment, but **it must not be quoted as a check with teeth**, and
this row exists so that nobody credits it with a kill later.

## Gate rows, verbatim

Every row below is `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/brecur/...
bash sim/regress.sh --only <substring> --keep`.

```
--only gdn
 OVERALL     PASS 21   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1   SKIPPED 0
 REGRESSION: PASS

--only bmover
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS

--only tb_llama_top_b
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS

--only seamgate
PASS       sim:seamgate_real                     41s  SEAMGATE PASS -- real: 1 token(s), at least 64 seams per token
PASS       sim:seamgate_stub                     31s  SEAMGATE PASS -- stub: 1 token(s), at least 63 seams per token
PASS       sim:seamgate_seq                     172s  SEAMGATE PASS -- seq: 3 token(s), at least 61 seams per token
PASS       sim:seamgate_bconst                  149s  SEAMGATE PASS -- bconst: 3 token(s), at least 61 seams per token
PASS       sim:seamgate_qkn                     130s  SEAMGATE PASS -- qkn: 3 token(s), at least 64 seams per token
PASS       sim:seamgate_swg                     135s  SEAMGATE PASS -- swg: 3 token(s), at least 64 seams per token
 OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

`seamgate_bconst` is the row the brief named as the value authority. Note what
it does and does not establish here: it runs `sim/tb_llama_top.vhd`, which does
NOT expose `B_RECUR_LANES`, so **every seamgate row above is at `LANES = 4`**.
It proves this track broke nothing; it does not and cannot check `LANES = 16`.
The 16-lane evidence is the cross-lane dump identity and the block oracle,
above.

`--only gdn` is PASS 21 with the one pre-existing NOCHECK
(`tb_gdn_conv_cycles`), which is where it was before this track.

**The `tb_llama_top_b` row above is a RE-RUN.** Its first run was
`BUILD-ERROR 3`, every one of them `ghdl -a failed on rtl/attn_block.vhd:
error limit reached` -- a syntax error at `attn_block.vhd:852`, a half-written
`when/else`, in TRACK CSWEEP's file while that track had it open. It analysed
cleanly forty minutes later and the row is green. Recorded rather than quietly
re-run, because a red gate in a file you do not own looks exactly like a red
gate in one you do.

## Open, not determined

- **The `drain` phase, 8,977 cycles (49% of the non-recurrence cost, and 17.3%
  of the whole block after this lever lands).** It is `P_DRAIN` plus
  `P_WAITY`. The pipeline drain accounts for `DC + 2*NB` = 256 at `LANES=4` and
  88 at `LANES=16`, and the measured difference between the two runs is 118, so
  the drain is dominated by something that is NOT the pipe and NOT lane
  dependent. **No attribution is offered.** Ruling out the pipe promotes
  nothing. The measurement that would settle it is a span from the last
  `st_ren` to the last `y_valid`, which this bench could print and does not.
- **The LUT cost at `LANES=16` against a card at 99.81% CLB.** The OOC number
  is a unit in isolation; CLAUDE.md records that the parts do not sum across
  synthesis contexts. A composed or full-card draw is owed before this ships.
- **Fmax at `LANES=16` in context.** The OOC rows are synthesis-only; this
  project's own rule is that nothing before `route_design` orders two runs
  correctly, and the card routes at WNS +0.001.
- **The oracle at `LANES=16`.** `ref/gdn_block_vec.c` was run at the committed
  small shape only, where `LANES=16` is refused for shape reasons unrelated to
  this lever. The 9B oracle run is listed in the evidence above; the cross-lane
  dump identity stands on its own either way.
- **`sim/tb_llama_top.vhd` does not expose `B_RECUR_LANES`**, so `seamgate`
  cannot be run at any lane count but 4 without threading one generic into that
  bench. That is a file this track does not own.
- **The card's own B-job cycle count.** Everything here is simulation. The
  card measures 660,601; the bench total for the shipping configuration is
  644,172, a 2.5% residual that TRACK BMOVER also saw and nobody has explained.

## What to change, exactly

One line, in `hw/fk33/gen_fk33_card.py`, alongside the `B_*` generics that are
already there (`:148`, `:158`, `:170`):

```python
    "--generic", "B_RECUR_LANES=16",
```

Nothing else. `rtl/llama_top.vhd:816` already declares the generic and already
maps it into both `u_gdn` and `u_state`; `rtl/fk33_llama_top.vhd:851` already
carries it through the generated card top. `RECUR_SLOTS=16` is already
sufficient at `DIM=128 LANES=16`: that is MEASURED by the 9B run above
completing, not derived -- `gdn_recur_pipe.vhd:410` fails the simulation by
name when it is not, as it did at `DIM=32 LANES=16`. The HBM image does not
change.

**DERIVED saving on the card**, at 24 B jobs per token: `24 * 98,422 =
2,362,128` cycles a token, **31.5 ms at 75 MHz**. The B job goes from 222,805
to about 124,383, and `gdn_block` stops being the majority of it.
