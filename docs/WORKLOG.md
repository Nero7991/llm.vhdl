# Parallel worklog

A live board, not a report. One section per track that is in flight, the files
each track owns so two agents cannot collide, and **the next step written down
BEFORE the result arrives**, branched by what the result could be.

Why the branches are pre-written: deciding what to do next while holding a
fresh result is how scope drifts and how a negative result gets talked into
being a positive one. If the branch was written before the answer was known,
the answer only has to be classified, not argued with.

## STATE OF THE BOARD, 2026-08-30 morning

Written to survive a context compaction. Every figure here is MEASURED unless
labelled, and several supersede figures still standing elsewhere in this file.

### 2026-08-30 08:30, added by the dispatcher: three landings and one new constraint

**TRACK RESETLAND landed (`8b7eefe`).** All three of RESETGUARD's orphaned
changes are in, plus a third file the brief did not know about. Generated
artefacts MEASURED byte-identical over 676 tracked files. The reset-topology
guard now has teeth with the attribution control run on every row: **7 dangerous
rows all abort, and `GUARD OFF` is `PASS` on every one**, so the new check earns
all seven kills alone rather than inheriting them. Two rows corrected the agent
rather than the guard, and are recorded as such. Remaining hole, stated as
fail-OPEN: the guard reads the block design and **cannot see the RTL**, so a
soft-reset bit added inside `fk33_engine.vhd` or `llama_top.vhd` leaves it green.

**TRACK RMSMUX draw 1 is in, on the BC-250, and every pre-registered falsifier
held.** This is the largest area lever measured on this project so far:

| quantity | predicted | MEASURED `mem_d1` |
|---|---|---:|
| `ARG` census root (the x and w reads) | -- | **443**, from **17,916** in the flat unit |
| CLB LUT | 4,798..7,823 | **4,825** |
| MUXF7 / MUXF8 | 0 / 0 | **0 / 0** |
| CLB FF | below 1,700 | **1,629** |
| DSP | 40 | **40** |
| WNS @ 5.0 ns | not predicted | **+0.971**, 248.2 MHz |

**FINAL, all three draws in, TRACK RMSMUX complete** (`5152e91`, artefacts
`hw/fk33/results/rmsmux_2026-08-30/`). Against its own same-session control,
same flow, one tool at a time:

| | `rmsnorm_rs` control | `rmsnorm_rs_mem` | delta |
|---|---:|---:|---:|
| CLB LUT | 40,934 | **4,825** | **-36,109, -88.2%** |
| CLB FF | 67,196 | **1,629** | **-65,567, -97.6%** |
| MUXF7 | 17,408 | **0** | **-17,408, -100%** |
| MUXF8 | 8,704 | **0** | **-8,704, -100%** |
| BRAM tile | 0 | 6 | +6 of 425.5 free |
| DSP | 40 | 40 | 0 |
| WNS @ 5.0 ns | +1.675 | +0.971 | -0.704 ns, still meets 200 MHz |

**Scatter is `1.0000x`: the two identical-command draws are byte-identical in
every CSV field AND their censuses hash the same** (`2c85f5c4...`), agreeing
down to per-root primitive tallies. **Operationally, and this is the part the
fit table needs: SCATTER's 1.55x must NOT be applied to this 4,825.** The
pre-registered hypothesis (that SCATTER's spread came from register merging on
a foldable constant ROM, and a memory-backed unit has no fold to perform) is
**unrefuted, not proven** -- two draws, one box, one session.

The control's own census settles the attribution **on the shipped file**, not on
a transform of a superseded one: `ARG` 17,916 + `sq` 17,474 = **86.5% of the
shipped unit's LUT and 100.0% of its MUXF7 and MUXF8**, both agreeing with
LUTDIET's census to the LUT. The saving exceeds the 35,390 of read mux because
the memory form also removes `gow.o` (WRITEDEC's write decode, 2,356).

**Still open and NOT derivable from the above: the COMPOSED number.** Nothing
here is placed, routed or composed, and TIMING's composed baseline was drawn
with a foldable `w_mant`.

The 1024:1 read mux is gone, measured rather than argued: **no root anywhere
carries a single MUXF7 or MUXF8, and there is no `sq` root at all.** The FF
figure is the one worth pausing on, because it was a mechanism-level prediction
and not a curve fit: three dropped registers, `o_we` + `o_wa` + `o_wd` = 75
flops predicted, **71 measured**. Two independently derived transforms of the
same file agree root for root to the LUT on everything except the one thing that
differs between them. Scatter conclusion is held until `mem_d2` returns, as
pre-registered.

**NEW CONSTRAINT, found by TRACK NORMURAM, and it changes a composition
everyone assumed was free.** Section 12 of the RMSMUX write-up reads NORMURAM's
gain-loader word stream as free to reuse against `rmsnorm_rs_mem`'s bank port.
**It is free in ORDER and in GRANULARITY but NOT in RATE.**

- Today: budget to `r_go` is `NN+4`, load is `NN/GW+1`, margin **GW = 4.0x and
  independent of shape**. A bench at hidden 64 exercises the ratio a build at
  4096 has.
- Composed: `w_we`/`w_waddr`/`w_wdata` is one 16-bit word per cycle, so the load
  becomes `NN+2` and the margin becomes about **`1 + 1/LANES`**: 1.26x at the
  shipping `NORM_LANES = 4`, **1.07x at `NORM_LANES = 16`**, which
  `rmsnorm_rs_mem`'s own sweep covers as legal.

DERIVED by NORMURAM, reviewed for shape by the dispatcher, **not independently
re-derived**. The conclusion does not turn on the exact `S_RAW` arrival term:
any margin that depends on `LANES` has already lost the property that made the
current form checkable.

Second and worse for checking: the reader walks LANES elements per cycle against
the writer's one, both ascending, so "fully resident before use" stops being a
phase separation and becomes a race. **The deadline moves from `r_go`, which
`gvr` can see and `wbusy` checks today, to the unit's internal `S_RAW`, which
`gvr` cannot see at all.** NORMURAM's U6/U6x pair is direct evidence that this
fault class leaves the values correct and every landmark unmoved.

**Ruling: the composition is sequenced AFTER NORMURAM's six points land, and the
`nw_empty` = 49,654 anchor is not retired** -- NORMADAPT, NWROM, NWFIX and
NORMURAM all quote it as the scale their numbers sit on.

**General rule extracted, and it is reusable past this track: a change that
removes a check and tightens the margin that check was guarding is not a wiring
change.** NORMURAM was dispatched to compose two levers, judged it a redesign,
stopped, and reported. That was correct.

### The single most important thing on the board

**The composed A+B+C+D does not route on this part as currently written, and
Vivado said so itself, unprompted:**

```
[Route 35-447] Congestion is preventing the router from routing all nets.
iteration 0  494,506 -> 150,615 -> 65,271 -> 35,976 -> 23,310 -> 16,757  (56m35s)
iteration 1  69,858 -> 183,525 -> 111,513   (RISING -- the router is thrashing)
```

Placed occupancy **54,866 of 54,960 CLB = 99.83%**, congestion level 7, 33,767
failing endpoints after placement, **20,000 of the 20,000 worst net-dominated**
(mean net 4.575 ns against mean logic 0.670 ns). The route was killed as a
decision, not a completion (`ac35293`); `c4dev_physopt.dcp` is kept.

### TRACK RMSWIRE COMPLETE (`47c9d9c`). STEP 1a IS DONE, and composition found a cost no unit draw could.

| | `ctl_flat` | `mem_bank` | delta |
|---|---:|---:|---:|
| CLB LUT | 67,318 | **5,265** | **-62,053, -92.2%** |
| CLB FF | 191,664 | **2,149** | **-189,515** |
| MUXF7 / MUXF8 | 26,736 / 13,296 | **0 / 0** | -100% |
| **BRAM tile** | **171** | **177** | **+6** |
| WNS @ 5.0 ns | +1.675 | +0.971 | 248.2 MHz |

**The saving is 72% LARGER than RMSMUX's standalone -36,109, and the census says
exactly why: `gvr.uw_data` -- 19,728 LUT / 9,328 MUXF7 / 4,592 MUXF8 -- is the
ADAPTER'S OWN 4096-to-1 write-back read mux, absent from every standalone draw.**
Nobody had measured it, because a unit draw structurally cannot see it. **This is
the counter-example to "compose late": composing EARLIER would have found a
62,053-LUT structure two tracks were unknowingly leaving on the table.**

**BRAM CONFIRMED BY MEASUREMENT, and the dispatcher's DERIVED figure holds:**
`246.5 + 177 = 423.5` against `372.5` available in `pb_core` -- **51 short**. The
gain image did not move (171 RAMB36 at both points). **45 of those 51 tiles are
NOT this lever.** The binding term is the gain image, and NORMURAM's `GW = 2`
fallback has still not been measured.

**`wact_chk` EARNS ZERO KILLS**, stated plainly. Kept only because `onlyWA =
K:wact` shows it discriminates and it is the sole check on the real deadline if
the gate is ever relaxed. **R1, R2 and R11 do not bite and are named** -- R1
(gate removed, survives) measures the gate at **zero cycles**.

**THREE CORRECTIONS THAT OUTLIVE THIS TRACK.**

1. **`sim/mutate_llama_top_kv.sh` needed `vec_mem` + `rmsnorm_rs_mem` added by
   hand.** Three harnesses read that hand-maintained closure, and without it
   **every row of all three, INCLUDING THE CONTROLS, was `NOBUILD`.**
   `regress.sh` computes its own closure and stayed green throughout, so **the
   gate structurally cannot catch this class.** A mutation harness whose
   controls all fail to build reports nothing and looks like it ran.
2. **`ooc_normadapt_extract.py --shift` now aborts against HEAD** (no `xw`).
   Correct behaviour, but **NORMADAPT's `na_shift` probe is no longer
   reproducible.**
3. **`nw_empty = 49,654` IS RETIRED as a cross-track control.** It was a draw of
   a configuration -- flat port, foldable constant gain -- that `llama_top` no
   longer contains. **This reverses the dispatcher's ruling this morning that it
   must not be retired**, and correctly: that ruling was right while the tree
   still held that configuration and wrong the moment this landed. Prior
   conclusions stand for their own trees; **nothing replaces it as a shared
   scale, and four tracks were quoting it.**

### TRACK RMSWIRE, in flight: the lever is wired, and there are TWO deadlines

**Landed and green.** `rmsnorm_rs_mem` is wired into `llama_top` at the real 9B
shape. All six `sim:tb_llama_top*` rows PASS, including `tb_llama_top_normw`,
the only wrapper that exercises the gain loader. **The token landmarks did not
move, so the numeric oracle is unchanged.** New gate row
`sim:tb_rmswire_loadrace` PASS at `N=4096 LANES=4`.

**THE FINDING, and it outranks the area number the track was dispatched for.
There are TWO deadlines, not one:**

- **`S_RAW` at `start+1067`** corrupts only `max_raw`.
- **`S_EMIT` at `start+2097`** corrupts every output word.
- **The strict boundary, 2007, is the INVISIBLE one.** At `start_at=1991`, 21
  elements are read from the PREVIOUS norm op's gain **and the output is
  bit-identical to the oracle.**

Both boundaries are now pinned to the cycle and predicted exactly by one
corrected model.

**A race that produces bit-identical output cannot be caught by any check that
compares values.** This is the inverse of this project's usual failure mode:
normally the structure looks right and the numbers are wrong, and here **the
numbers are right and the design is wrong.** It is exactly what TRACK NORMURAM
refused the composition over -- it said the fault class "leaves the VALUES
correct and is invisible to the landmarks" -- and RMSWIRE has now put a number
on it: **the invisible window is 116 cycles wide, 2007 to 2123.** Nobody had one.

**CORRECTION, 2026-08-30, by TRACK RMSWIRE. WITHDRAWN: the dispatcher's "116
cycles wide, 2007 to 2123". THE WINDOW IS 1,030 CYCLES AND I HAD BOTH ENDS
WRONG.** `2007` is the window's first SAFE cycle, not its start, and `2123` was
invented. MEASURED, both boundaries pinned to the cycle (`2006` corrupt / `2007`
clean, `976` corrupt / `977` clean):

```
window = [977, 2006] = 1030 cycles = exactly S_EMIT arrival - S_RAW arrival = 2097 - 1067
```

17 points swept across it with the ordinary previous-op stale gain
(`invisible_window.txt`):

```
start_at  raw_rise  stale_raw  differing verdict
977       2044      1373       0        INVISIBLE
1400      2467       809       0        INVISIBLE
1991      3058        21       0        INVISIBLE
2006      3073         1       0        INVISIBLE
```

**Up to 1,373 of 4,096 elements read from the WRONG gain vector and not one
output word moves, anywhere in the window.**

**`tb_llama_top`'s four `EXP_*` landmarks are TOKEN HASHES and pass
throughout.** Whoever builds the card top (row N3) inherits this deadline and
**cannot see it from outside the unit** without the tap.

**THE TAP NOW EXISTS.** `rtl/rmsnorm_rs_mem.vhd` gained one output, `w_active`,
high through `S_RAW` AND `S_EMIT` and low in the `S_SHIFT1`/`S_SHIFT2` gap, so
**one pin times both deadlines**: first rise is `S_RAW`, rise-after-fall is
`S_EMIT`. Every number above was measured off it. Named association throughout
means a parent may leave it unassociated.

**THE THREE MEMORY FIGURES ARE NOT INTERCHANGEABLE, and this run is the worked
example:**

| figure | value | what it is |
|---|---:|---|
| Vivado `Memory (MB): peak` | **17.3 GiB** | the tool's peak ALLOCATION; swap absorbed it |
| summed `/proc` `VmRSS` | **11.94 GiB** | sampled RESIDENT; 5.4 GiB below Vivado's, sign of the error unknown |
| cgroup `memory.peak` | **11.0015 GiB** | **THE CAP**, 1.6 MB above `MemoryHigh=11G`. Not a footprint. |

The last row reproduces CLAUDE.md's warning exactly, on a real job.

**CROSS-VALIDATION worth having: `ctl_flat` reproduced NORMURAM's `nu_u1` on
DIFFERENT hardware, every field identical** -- `lut=67318 ff=191664 bram=171
f7=26736 f8=13296 wns=1.675`, at 1,625 s against 641 s (2.53x). That is the
BC-250/workstation bit-identity property re-confirmed on a composed draw rather
than a unit one.

**Attribution, R3: `K:loadassert / K:loadassert / K:landmarks` -- the landmarks
earn that kill on their own, so NEITHER new assertion gets credit for it.**

**Correction to my brief, accepted: I sent a COMPOSED `llama_top` draw to the
14 GB BC-250** on the strength of RMSMUX's 10.58 GB peak, which was a UNIT draw.
That is the "figure from a smaller design applied to a bigger one" error, made
in the brief itself. Vivado reported a 17.1 GB peak; the box survived on swap
(MEASURED mid-run: 10 GB free, 2 of 46 GB swap, load 1.13).

**And a distinction worth keeping: Vivado's `Memory (MB): peak` is not the
cgroup's `memory.peak`.** The former is the process's own peak allocation, which
swap can absorb -- which is why 17.1 GB "fit" on a 14 GB box. Quote the cgroup
figure, and only from a run that never reached its cap.

### THE STRIPING EXPERIMENT RAN ON SILICON, 2026-08-30 14:20. 11.09x.

```
mean cycles/beat   flat 22.49   striped 2.03   speedup 11.09x
```

**The pre-registered band was 1.60 to 3.0 and the measurement is 2.03.** Neither
falsifier fired: not 10-12 (half the lanes still sharing a channel), not ~21.6
(the descriptors not being the striped ones).

| tensor | flat | striped |
|---|---:|---:|
| `blk.0.ssm_alpha.weight` | 23.45 | **2.38** |
| `blk.0.ffn_gate.weight` | 22.19 | **2.02** |
| `blk.11.attn_k.weight` | 22.38 | **2.00** |
| `blk.20.ffn_down.weight` | 21.95 | **1.72** |

**The census is printed beside every number**, so the layout and the measurement
cannot be read apart. Whole-image: flat `{(1,27): 235, ...}`, striped
`{(25,2): 249}` -- every one of the 249 tensors on 25 channels with at most 2
lanes on the busiest. G1, G2 and G2b all PASS. Both manifests pinned by sha256
in the log, because that file has moved under three tracks.

**`trips=0` before AND after all eight jobs**, with the counter cleared and
observed 0 before each. The thermal veto was discriminating rather than
saturated, because the cold power cycle reset it -- so no number here is
contaminated by THERM-255.

**STRIPEREADY's caveat against its own interest did NOT bite:** only 15 to 17 of
27 lanes read the pseudo-channel their own engine master is wired to, so ~40%
cross the HBM global switch laterally, **and 2.03 was reached anyway.** Lateral
crossing is cheaper than the estimate feared. That is now a measured fact rather
than an assumption, and it is the one genuinely new thing this run taught beyond
confirming the prediction.

Log: `/mnt/storage/stripe_experiment_2026-08-30.log`. The card is left holding
the striped image, fully verified; re-running the command is safe.

### AND THE CARD BOOTS ITSELF NOW

`hw/fk33/bit/fk33_pcieep.mcs` written to card 1's SPI flash. On the next full
power cycle the FPGA configured from flash, trained inside the ~100 ms PERST
window, and the BIOS enumerated **root port `00:1d.0`** unaided --
`06:00.0 Xilinx Corporation Device [10ee:9034]`, `LnkSta: Speed 8GT/s (ok),
Width x4 (ok)`.

**This retires the entire rescan/reboot problem.** The port is live at every
boot from now on, and any bitstream goes in behind it with `remove -> configure
-> rescan` (`sudo hw/fk33/host/fk33_reload.sh --with-vccint`), which is the
August procedure that always worked and had simply lost its precondition.

**`00:1c.4` was the RTX 3090's slot, not the card's.** A whole deadlock theory
was built on that misidentification this morning; it was settled by flashing and
looking, not by more inference.

### TRACK GATEGREEN COMPLETE (`392f818`, `df0b194`). THE TREE IS GREEN.

Full both-suite run on a clean `git archive 32a7b47`, GHDL 1.0.0 mcode,
`--jobs 1`:

```
 suite sim   PASS 79   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 105  FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 6
 REGRESSION: PASS
```

**Zero red rows, so no bisection was needed.** Every row for every file the 32
commits touched passed, including the two new auto-discovered rows.

**`BASELINE_PASS` LEFT AT 99, DELIBERATELY.** The floor run (with the documented
`MV4I_FK33_FILE=/nonexistent`) measures **101**, and the gate itself printed the
raise suggestion. But `sim/tb_a_wbase.vhd` landed in `d7a6bf7` AFTER the archive
(verified with `git merge-base --is-ancestor`), so 101 describes a commit that is
no longer HEAD and **102 would be arithmetic over a row nobody has run.** The
measurement, the recipe and the reason are written into `sim/regress.sh` so the
next track closes it with one run and no re-derivation.

**WHAT THE GATE DOES NOT COVER, and this matters because seven tracks quoted
area and timing numbers today:** GHDL simulation plus seven Python/Tcl
self-checks. **No synthesis, no timing, no placement, no routing, no area, no
power, no card.** Six `*_cmp` rows are skipped by design, so **the netlist is
never compared to the behavioural model.** Four rows are NOCHECK. **Five `rtl/`
files are reached by no testbench at all.**

And the line worth keeping: **`FAIL 0` means no row noticed anything, not that
the rows would notice.** ATTNTEETH found `tb_attn_block` passing a broken tree
on a degenerate oracle, and BASEFAB's control denies its own new row credit for
seven of eight kills. **Much of this suite's apparent discrimination is
incidental.**

**TWO CORRECTIONS TO MY BRIEF.**
1. "Nobody has run the full gate" was wrong -- TRACK STRAYROW ran one on a clean
   archive of `2217778` (`912ada7`). **The practice was followed; only the
   number was stale.**
2. **THE MEMORY WARNING DOES NOT SURVIVE MEASUREMENT.** The full gate at
   `--jobs 1` peaks at **2.13 GiB** (cgroup `memory.peak`, under its 8G cap so a
   real peak), beside a 7-10.6 GiB Vivado `place_design`, `MemAvailable` never
   below 19 GiB. **The 20.9 GiB `ghdl-mcode` figure belongs to something else
   and the whole dispatch budget was provisioned against it all night.** Landed
   in CLAUDE.md; **the bench that actually reaches 20.9 GiB is now an open item
   and must be pinned before that number is quoted again.**

**ITS OWN TRAP, and it is a guard passing its teeth-check on a live operator
error:** the first gate ran WITHOUT `MV4I_FK33_FILE=/nonexistent`, so four FK33
rows ran off a `.mv4i` that has sat on this box since 28 Aug, and the headline
came out **105**. **The gate refused the raise and named all four rows.** Note
the `NOT IN GIT` check was silent and correct (an archive has no `.git`); the
optional-row refusal is a separate mechanism and it is the one that fired.

**Largest unverified surface:** `rtl/llama_top.vhd` changed after `32a7b47`
(BASEFAB's `d7a6bf7`), so the six `tb_llama_top*` rows are unverified at HEAD.

### TRACK BASEFAB COMPLETE (`d7a6bf7`). THE URGENCY CLAIM WAS WRONG, AND THAT IS GOOD NEWS.

**The form claim was right; the urgency claim that drove the dispatch was
wrong.** `w_base(p) = A_MEM_BASE + step*A_JOB_STRIDE + p*A_SUB_BYTES` is a
two-parameter affine map and PACKSTRIPE's allocator assigns segments per tensor,
greedily on fill, which no closed form expresses. **But `llama_top`'s
fabrication is not on the striped path and never was.**

MEASURED by BASEFAB and **independently VERIFIED by the dispatcher**:

- `hw/fk33/rtl/fk33_engine.vhd` binds **`matvec_int4_desc_axi`**, not `matvec_int4`.
- `grep -c 'seq_' hw/fk33/rtl/fk33_engine.vhd` = **0**.
- `rtl/matvec_int4_desc_axi.vhd:610-615` drives
  `w_base <= dw(DESC_BASE0 + p)` -- **27 arbitrary 40-bit addresses fetched from
  the descriptor image.**
- `tools/gen_mv4i_desc.py`'s `sub_base()` already emits striped bases from the
  v2 manifest's `pieces`.

**So striping is expressible end to end on the card TODAY, PACKSTRIPE is not
blocked by G3, and DSEAM's "on silicon every A job would read the wrong bytes"
is conditional on an integration that does not exist. G3 is a defect in the
SIMULATION top.** This materially de-risks the striping experiment.

**A REAL DEFECT FIXED, because it is reachable today: the fabricated block was
UNBOUNDED.** DERIVED at 9B, the FFN gate job needs **393,216 beats per port
against a 256-beat sub-region, short by 1,536x**. Over-capacity jobs walked into
port p+1's region and completed **`done=1, err=0`**. `llama_top` now refuses in
`S_EXP` before `start`, so zero address beats are issued.

**THE ATTRIBUTION CONTROL IS THE HEADLINE AND IT DENIES CREDIT FOR SEVEN OF
EIGHT KILLS.** `sim/tb_a_wbase.vhd` kills 8 of 11; **only M9, the new guard, is
a detection the six pre-existing rows do not already make.** And those rows kill
via **recorded numeric landmarks, not address checks** -- they fire because
`wword` happens to be address-sensitive. The two `smp` rows, whose memory answers
on `addr mod A_JOB_STRIDE`, **pass every address mutation in the table.**

**M5 IS THE MOST USEFUL ROW IN THE TABLE:** a uniform one-stride shift of every
base **survives the bench and is caught only by the control**. *A checker of
relative properties can never see a base that is uniformly wrong* -- which is
G3's own shape. **Only an address-level oracle can catch a wrong base, and the
oracle is the base array.**

**THE DECISION THAT IS ACTUALLY OWNERLESS is not the base array, it is the
integration.** `docs/2026-08-28_matvec-descriptor-format.md` says "D issues, A
consumes" at :84 and "D fetching it is remaining work" at :570 -- **two mutually
exclusive integrations in one file, and nobody has chosen.** BASEFAB argues D
fetching it is the WRONG choice for a structural reason: `seq_desc_fetch`'s
descriptor address is `resize(fetch_idx & "000", 16)`, a **fixed 8-word stride**
on which its 0-DSP claim rests, and a 39-word descriptor is not addressable by
`step*8`.

**UNVERIFIED, under their own names:** M10_guard_ge and M11_port_rev **have no
control column** -- both survived the bench, but whether the pre-existing rows
catch them is unmeasured because the batch was cut short. Run M11 first;
`tb_llama_top.vhd:892`'s `sub = p` assert should catch it.

**No full gate run** -- GATEGREEN held the box and BASEFAB correctly judged a
contended run not to be evidence. **`BASELINE_PASS` needs +1 for its row**
(`sim/tb_a_wbase.vhd`); `sim/regress.sh` untouched. GATEGREEN notified.

### TRACK TRIPVETO (`729df43`). SIX consumers, THREE failure directions, and the fix deliberately NOT landed.

**Six consumers in four files, and the load-bearing column is the failure
DIRECTION, not the file:**

| # | where | verdict at `trip_cnt = 255` |
|---|---|---|
| 1 | `fk33_run_job.py:909, 1000-1001` | **false PASS**, veto dead; `:926` prints a correct warning about exactly this and proceeds |
| 2 | `fk33_run_token.py:737-738, 748, 775-776` | **false PASS**, `t1 == t0` forever, no trip logged, no retry fires |
| 3 | `fk33_run_token.py:980-981, 1044-1045, 1352` | silent under-report |
| 4 | `therm_selftest.py:256, 294-297` | **INVERTED** -- it asserts the counter MUST move, so saturation makes it FAIL a WORKING guard |
| 5 | `fk33ctl.py:358` | silent under-report |
| 6 | `hw/fk33/tcl/aux_probe.tcl:114-116` | silent under-report, on the JTAG path |
| -- | `fk33_stripe_experiment.py:227-260` | defended (STRIPEREADY's) |

Named as NOT consumers so nobody re-checks: `fk33_run_layer.py`,
`fk33_load_weights.py`, all of `server/`, all of `tools/`.

**CORRECTION TO MY BRIEF, and it is the reusable part: my starting grep finds
THREE OF SIX.** `fk33_run_token.py` names them `t0`/`t1` and `trips0`/`trips1`,
`therm_selftest.py` uses `trips_before`/`trips_after`, and `aux_probe.tcl` is
Tcl outside the searched path. **The REGISTER name is the search key, not the
variable names.**

**THE RTL SATURATION IS CORRECT. DO NOT REBUILD.** TRIPVETO opened expecting to
recommend widening and its own measurement killed that: **wrapping trades a
permanent, detectable failure for a periodic, undetectable one**; 16 bits buys
~4.5 h at the measured 30 crossings/s and changes nothing about the failure
mode; and any fixed width saturates above some rate. The one thing worth riding
along with a future `fk33_thermal.vhd` change is a **sticky `trip_cnt_sat` bit,
one FF** -- the only thing that can close consumers 3, 5 and 6, which no host
change can reach, because clearing destroys the history they report.

**WHY THE FIX WAS NOT LANDED, and this was the right call.** Applying
STRIPEREADY's clear-and-prove shape inside `fk33_run_job.py` **BREAKS
`fk33_run_token.py`**: its retry wrapper samples `t0` immediately before
`_ORIG_RUN_JOB(...)` and `t1` immediately after, so if `run_job` clears then
`t1 < t0` on every job, `t1 != t0` fires, and **a phantom trip is logged and a
retry burned on every job of every layer of every token.** That converts a dead
veto into a live false alarm **which would read as evidence about THERM-255
itself.** The correct fix is a structured channel that `run_token` consumes
instead of sampling around the call: two files, hardware-only consumer, not
something to half-land before a reboot.

**TWO TRAPS FOUND BY READING, for whoever takes the fix:**
- `SimBar._status` at `fk33_run_job.py:774` fires the injected trip only when
  `self.trip == faults["trip0"]`. After a clear that is `0 == 255`, so the
  `trip0=255, trip_during=1` mutant **would not bite AND would look like it
  had.**
- `tests_fk33ctl.py:137` and `:175` both pin the count at **3** (DERIVED:
  `(0x8A0377CD >> 16) & 0xFF = 3`). **The existing fixture cannot see this
  defect at all.**

**Correction appended in place:** `2026-08-30_therm255-...md:262` ("nothing here
is fixed") is now stale FOR THE RTL IN THE TREE -- the capture-a-cycle-late
defect is fixed at `fk33_thermal.vhd:1146-1160`. **It remains true for the
bitstream ON THE CARD.**

**OPERATIONAL NOTE FOR THE STRIPING RUN:** `fk33_stripe_experiment.py` defends
itself, so the one-command experiment is safe. **`fk33_run_job.py` and
`fk33_run_token.py` invoked directly are NOT**, and at 255 they will report
health.

### TRACK STRIPEREADY COMPLETE (`0eac8d4`, `639880e`). THE EXPERIMENT IS ONE COMMAND.

```bash
cd /home/orencollaco/GitHub/llama.vhdl
python3 hw/fk33/host/fk33_stripe_experiment.py run
```

It pins BOTH manifests by hash, runs every offline guard, loads and verifies the
FLAT image, runs the four published jobs, repeats for the STRIPED image, and
prints one table with CYCLES, BEATS, STARVED, cycles/beat, **the trip count**
and the channel census on each row. Idempotent, both phases are full loads, and
it finishes with the card holding a verified striped image. **If it refuses it
produces no number and names the guard.**

**The `index.txt` gap is closed WITHOUT touching the packer**, which matters
because the packer has moved the manifest under three tracks now.
`tools/ref9b/make_index.py` reads geometry and shape only, never `hbm_offset`
and never `pieces`; STRIPEREADY enumerated its inputs, PREDICTED the striped
index would be byte-identical to the flat apart from line 1, then generated it:
MEASURED **428 body lines identical, one differing provenance comment**, and
`git diff --stat -- tools/pack_model_fk33.py` empty. Blocker measured shut both
ways (`index.txt does not exist` to `248320 of 248320 logits, 0 differ`).
**But `plan` is INERT to placement** -- flat vs striped differs in two lines,
both timings -- **so it closes the gap without being a striping verifier and
must not be quoted as one.**

**THE FINDING, and it sits directly on the measurement path.**
`hw/fk33/host/fk33_run_job.py`'s thermal veto rests on `trip_cnt`, which
**SATURATES at 255**. VERIFIED by the dispatcher at
`hw/fk33/rtl/fk33_thermal.vhd:1166`:

```vhdl
if trip_cnt /= to_unsigned(255, trip_cnt'length) then
  trip_cnt <= trip_cnt + 1;
end if;
```

At 255 the veto's `trip1 != trip0` test is **false forever** while still
printing `trips=255 (was 255)`. **The guard stops discriminating exactly when
the condition it guards is worst, and reports health while doing so** -- and
THERM-255, the open issue named for that number, is the reason the counter gets
there. STRIPEREADY's own runner defends itself (clear, then refuse unless the
post-clear word reads 0) and correctly flagged the rest as needing an owner.
Dispatched as TRACK TRIPVETO.

**T12 IS CLOSED**, after three tracks carried it. Honestly reported: its first
mutant was **not clean** -- it overlapped the f32 blob and `hbm_map` killed it
for the wrong reason, and **the neighbouring arms revealed that, not its own**.
The clean version is a same-size permutation that five checks pass and the
runner refuses. **Closed at the host, still open at the packer.**

**THE PREDICTION IS UNCHANGED, and its load-bearing input is now MEASURED over
all 249 tensors rather than inferred:** `striped {(25, 2): 249}` -- every
tensor, 25 channels, exactly 2 lanes on the busiest. The flat half of that
census **independently reproduces the counters document** (235/13/1, the missing
3-segment file being `token_embd`, absent from `noembd`).

**NEW FALSIFIER INPUT, and it weakens the run rather than strengthening it:**
only **15 to 17 of 27 lanes** read the channel their own master is wired to, so
the result leans hard on STRIPEPATH's lateral-crossing ESTIMATE -- and the four
measurement tensors split 17/15/17/15, **not enough spread to test it.**

**Verification:** 11 mutants x 5 arms, **control surviving in every arm**. G1
earns 1 independent kill, the census family 3, whole-image scope 1 that the
four-tensor scope cannot see, the oracle join 1. **M2, M3, M4 earn G1 nothing
and are named. M7 and M8 survive as designed. G4's extent-count cross-check
earns ZERO and is labelled.** Six commands traced with zero `/dev` opens.

**Correction to my brief, and it is right:** "verify the striped image and the
striped descriptors" is TWO guards and either can pass while the other fails --
**which is exactly the `output.weight` byte-identity case TOKENSTRIPE hit.**

### TRACK CBINFER COMPLETE (`0d24f7d`). LEVER C IS ALIVE: Vivado DOES infer LUTRAM.

LEVERC's own first open item said this "must be the first thing a Vivado lane
checks, before any area number", because a NO would have made lever C **1,536
register copies, strictly worse than today**, and moot every row containing it.

**1. YES.** MEASURED at three geometries on `xcvu33p-fsvh2104-2L-e`, Vivado
2023.2: at `CB_STYLE = "distributed"` every codebook copy becomes one
`RAM32M16` (16 x 8, 8 LUTs) and the 16:1 mux per lane vanishes. The clean line
is the object-level census at ROWS_IF=8:

```
v_regs_r8   cells named cb_reg*:  RAM=0     FF=1024
v_dist_r8   cells named cb_reg*:  RAM=4352  FF=0
```

**LEVERC's 12,288-LUTRAM assumption is now MEASURED rather than assumed:**
LUTRAM added per lane is **8.000 at all three points** (128, 256, 512 lanes),
MUXF8 removed 8.000/lane, MUXF7 removed 16.00/lane -- **matching CONGEST's
shell per-lane census exactly**.

**2. The `ram_style` attribute from a function of a generic is ACCEPTED and
EARNS NOTHING.** The Final Mapping Report attributes 128 of 128 copies to `User
Attribute` -- but the attribution control (both attributes deleted) is
**byte-identical in every column** and merely relabels the inference `Implied`.
**So LEVERC's two-sibling-architecture fallback is not required and would buy
nothing.** `dont_touch = "false"` versus deleting it is also identical, so
presence-not-value was tested and refuted.

**3. `ram_style = "registers"` does NOT change today's shipping build** --
identical on eleven columns and WNS to the last digit, with a repeat draw
reproducing itself exactly, so it is a demonstrated no-op rather than a
coincidence.

**THE TRAP THAT WOULD HAVE INVERTED ANSWER 1, and it is the mirror image of
NORMURAM's URAM trap the same morning.** Vivado's log says, one hundred times:

```
WARNING: [Synth 8-7186] Applying attribute ram_style = "distributed" is ignored,
object 'cb[0][0]' is not inferred as ram due to incorrect usage
```

**Every object it names IS a `RAM32M16` in the same run's mapping report.**
Where `[Synth 8-10226]` claimed a resource the design never got, this one denies
one the design did get. **Vivado's inference log is unreliable in BOTH
directions; only the mapping report and the primitive census are
authoritative.** Landed in CLAUDE.md as `7888ef9`.

**CORRECTION OWED TO LEVERC, and it does not change their conclusion.** A
`RAM32M16` is 8 LUTs and CLB-atomic, so LEVERC's fragmented "4 per CLB" case is
unreachable. Their CLB saving narrows to **4,608 .. 8,946** from 3,072 .. 8,946.
**Lever C still does not close the fit under either bound; LEVERC's conclusion
stands.**

**NEXT VIVADO JOB, and it must go on the WORKSTATION:** the FK33 geometry
`ROWS_IF=48` was **not drawn**. ROWS_IF=16 already peaked at **14.38 GB summed
Vivado RSS on the BC-250's 14 GB**, so 48 does not fit there. Projections to
1,536 lanes are labelled: the structural per-lane figures are exact at three
points, but the **total-LUT saving is an ESTIMATE of 36,000-39,000** because
per-lane saving falls with lane count (29.11 / 27.71 / 26.05) and two models
disagree. DERIVED and exact: **+13,200 FF** at ROWS_IF=48 (three-point model,
residuals 0, -2, +4).

**Its own trap, recorded against itself:** the first primitive-census parser
assumed a four-column Primitives table (it has three) and **silently wrote zeros
into six CSV rows beside a populated utilization table** -- the exact failure
the cross-check exists to catch. Parser now hard-errors on zero rows.

**Not covered:** OOC synthesis, not placement, and lever C's claim is about
PACKING which only a place run measures. `matvec_core` alone, not the composed
design.

### TRACK NORMURAM COMPLETE (`c479ae8`, `57ecea4`, `5026897`). The gain image is out of LUT fabric.

`rtl/llama_top.vhd`'s `gvr` generate reshapes `NW_TBL` to 4 elements per word,
lets Vivado infer BLOCK RAM, and shifts it into a plain register. The
empty-image build (`gwc`) keeps the old code **character for character**.

| point | LUT | BRAM | URAM | WNS |
|---|---:|---:|---:|---:|
| `nu_empty` pinned, no image | 49,654 | 0 | 0 | +1.675 |
| `nu_ec` NEW RTL, no image | **49,654** bit-identical | 0 | 0 | +1.675 |
| `nu_a` route (a), image | 83,709 | 0 | 0 | +1.675 |
| `nu_rom` pinned, image | 89,970 | 0 | 0 | +1.675 |
| `nu_u1` NEW RTL, image | **67,318** | 171 | 0 | +1.675 |
| `nu_u2` same command again | **67,318** | 171 | 0 | +1.675 |

**Saving +15,279 to +60,747 LUT, and the WHOLE INTERVAL belongs to the
before-side.** `nu_empty` reproduces NWFIX's control on all eleven columns;
`nu_u1`/`nu_u2` agree on the entire `report_utilization` with byte-identical
censuses (md5 `1b341a73`). WNS unchanged on all six points. The gain store,
address generator, shift register and busy logic together are **313 LUT and
58,453 FF**, landing within 259 LUT of NWFIX's HBM floor **and spending no HBM
bandwidth**.

**THREE CORRECTIONS THAT OUTRANK THE NUMBER.**

1. **Route (a) is a no-op, and not for the reason anyone gave.** `Synth 8-6040`
   fires word for word with `:= 0` deleted, because **a VHDL signal of subtype
   `natural range 0 to NW_N-1` has an initial value regardless** -- the language
   gives it `subtype'left`, which is 0. **There is no way to spell "no initial
   value".** The width would have refused it anyway: 65 x 65,536 needs 911
   primitives against 672 RAMB36 / 320 URAM288.
2. **URAM cannot hold this table at all** -- see the relabelling above.
3. **"+32,943" was the DROP saving.** Any real gain pays `rmsnorm_rs`'s 17,367
   LUT fold wherever it lives, so **no route that keeps the image reaches
   349,421.**

**THE ATTRIBUTION CONTROL CHANGED A CLAIM IN THE NEW CHECK'S FAVOUR, which is
the rarer direction.** U6 is a margin failure that leaves the VALUES CORRECT,
killed by the new `wbusy` assertion; U6x is the same mutant with that assertion
disabled and it **survives with zero landmarks moved**. Both m7-class packing
mutants killed on all four landmarks. **U7 reported as a row that does not
bite**: the landmarks cannot see `GW`.

**NEW MEASUREMENT TRAP, landed in CLAUDE.md as `cc06f35`: a capped job's
`memory.peak` is the CAP, not the peak.** MEASURED: a five-point batch under
`MemoryHigh=13G` reported `memory.peak` **1.1 MB above 13 GiB** -- the throttle
holding it there, not the job's appetite. **The only honest unthrottled figure
was `nu_empty`'s 10.54 GiB.** Cap for safety; read `memory.peak` for size only
from a run that never reached its cap.

**Open:** nothing here is placed or routed; the Vivado half of the values oracle
is still open; and **171 BRAM is 25.45% of the device**, so a `GW = 2` point is
the obvious next measurement if BRAM binds. The `rmsnorm_rs_mem` composition is
DEFERRED, not rejected, for the rate reasons recorded above.

### TRACK ATTNTEETH COMPLETE (`5755473`,`a8053ca`,`1e18ce3`). The oracle's STIMULUS was the defect.

**`tb_attn_block` passed a deliberately broken tree, and the mechanism was never
in the bench.** Root cause is ONE LINE of the oracle's stimulus,
`ref/attn_block_vec.c:864`:

```c
for (i = 0; i < N * N_KVH; i++)    vin[i] = m12(65537 + SEED, i);
```

Uniform on [-2048, 2047] with no per-block structure, so every block's peak
lands in the top binade and `kv_quant` gives all NBLK blocks the SAME exponent.
MEASURED with a probe at the fold site: all six folds are `e0=e1=e2=e3=6`.
**`v_ref` is the minimum over that, and a minimum over a constant vector is that
constant.** P8 compared exactly the right numbers, bit-exactly, with no
tolerance, **and could not have disagreed whatever the reduction did.**

**All four hypotheses in my brief were wrong** -- shared source, narrow scope,
stale vector, early exit. Each was checked and each refuted. The defect was
upstream of every one of them.

| tag | mutation | before | after | `kv_seam` |
|---|---|---|---|---|
| M1 | drop the last tree stage (TIMING's) | PASS | KILLED | KILLED |
| M2 | no reduction, return block 0 | PASS | KILLED | KILLED |
| M3 | maximum not minimum | PASS | KILLED | KILLED |
| M4 | pad with 127 | PASS | SURVIVED | SURVIVED |
| M5 | result never folded in | KILLED | KILLED | KILLED |
| M6 | per-TOKEN not per-SEQUENCE | PASS | SURVIVED | KILLED |
| M7 | defect C1, `v_ref` shared across layers | PASS | SURVIVED | KILLED |
| M8 | drop the LAST block exponent | PASS | KILLED | SURVIVED |

**1 of 8 to 5 of 8. M8 is the one that matters: it survived BOTH benches
before.**

**THE ATTRIBUTION CONTROL PAID FOR ITSELF AGAIN. P9 is credited with ZERO
kills.** All eight verdicts are identical with P9 disabled; P8 does all the
killing, and P9 is justified as a stimulus gate rather than a detector.
**Without the control this would have claimed four detections for a check that
makes none.** P9's own teeth-check (flat stimulus, honest RTL) fails with every
sub-check firing while P8 passes.

**Survivors kept and explained:** M4's pad branch is unreachable (`NBLK` is
4/4/8, all powers of two -- dead code, not a missed defect). M6 and M7 are
structural to a one-token one-layer bench and `kv_seam` owns and kills both.
**The two benches have DISJOINT blind spots**, which is a stronger statement
than either being adequate.

**AND IT CAUGHT ITS OWN FIX REINTRODUCING THE DEFECT ONE LEVEL UP.** A per-head
PERMUTATION taper gives every head the same `v_ref`, so `attn_emit`'s cross-head
fold went degenerate. **It passed the generator's assert, P9 as first written,
and the whole suite.** The sibling enumeration caught it; nothing checking the
fix did.

**HIGHEST-VALUE FOLLOW-ON, NOT YET OWNED:** `ref/attn_block_seq_vec.c:214-215`
still carries the untapered line word for word, giving `e_grid = {20,20}` on
layer 1 -- **a minimum over a constant vector on half the design**. And
`tb_attn_kv_seam`'s teeth on this structure are **ONE block exponent of sixteen
headers** (15 of 16 folds are flat `6 6 6 6`), which is the repo's entire
coverage of the fold, at a hand-picked seed. Blocked on `sim/regress.sh`
(GATEGREEN's), whose lines 1499-1518 justify that generator's SEED=2 in terms of
exactly these numbers.

### TRACK TOKENSTRIPE COMPLETE (`6ca385f`, `a25847b`). The sixth consumer, and a guard fixed rather than muted.

**Defect sized first:** 15 window descriptors, **0 errors, 405 of 405
sub-region bases wrong**. After: 405/405 MOVE, 0 wrong against the manifest,
lm-head **3 to 25 pseudo-channels**. It was THREE lines, not two -- `TailJob`
uses `__slots__`, so `pieces` had to be declared there or the assignment raises.

**THE TRAP, and it explains why a track looking straight at this missed it:**
`output.weight.mv4i` sits at `hbm_offset` **0 under BOTH layouts** (same
`blake2b_128`), so the pre-change tail's 15 descriptors are **byte-identical
between the flat and the striped manifest. Diffing the two runs shows
nothing.** Only comparison against the manifest's `pieces` sees it.

**`tools/weights_residency.py` was FIXED, not muted, and the old rule was
another coincidence-of-geometry guard.** `stack_hole_bytes` is not "the gaps":
`place()` returns `hole` only for a stack-boundary skip and the striped branch
never calls `place()`, so it is structurally 0. The old check compared it
against ALL inter-placement gaps, **and the two coincide under the flat layout
only because a bump allocator leaves no other gaps.** Replaced by a closed
ledger, DERIVED exact to the byte before any rule was written:
`2,690,994,176 = 0 + 2,422,558,720 + 268,435,456`.

**It is STRICTER on the flat layout, not looser**: the old rule compared totals,
so a `stack_holes` entry at the wrong address, a list disagreeing with its own
total, and an emptied list all passed. All three now fail and the pre-change
file survives all three. Ledger earns **10 independent kills**; rows earning
nothing (S1b, S5, S6) are named.

**Corrections issued:** STRIPEPATH's "running `fk33_run_token.py` needs the
card" is WRONG -- `plan` and `selfcheck` are offline and were traced clean, so
its section 9.2 step 4 is superseded. And my brief's framing was off: the
manifest's `stack_hole_bytes` was always correct; it was the CHECKER's
re-derivation that was flat-only, which is why the fix is a consumer change.

**Traps it hit and reported against itself:** its first teeth table credited the
change with 8 kills it had not earned, for want of a whole-ledger-removed arm.

**STILL OPEN and blocking a full striped re-run:** the striped packed dir has
**no `index.txt`** (PACKSTRIPE's artefact), so `plan`'s host re-run cannot cover
the striped set. T12 remains unclosed.

### TRACK STRIPEPATH COMPLETE, 2026-08-30 (`d7f96cd`, `9d73018`). The striping path emits.

**The defect, SIZED before it was fixed:** pre-change, `fk33_run_layer` on the
striped set emitted 296 descriptors, **0 errors, and 7,992 of 7,992 bases
wrong**. It failed silently and completely.

**After: all bases MOVE and land where the manifest placed their file offset**,
reaching **25 distinct pseudo-channels** read from address bits [32:28].
`output.weight` goes from 3 segments to **25**. Inertness on the flat set:
**24,258 descriptor words, nine diffs**, one intentional and named.

**Guards that could not see their own defect, found here:**
`check_hbm_stack` printed **PASS** with a piece straddling the 4 GiB stack line.
It now earns 7 kills with the pre-change file earning zero on every row and its
control surviving, so that attribution is clean. And **the range count was never
a discriminator at all**: 7,154 on BOTH layouts, because
`250 + 249*27 = 249*28 + 1 = 6,973`.

**Zero-kill checks named and NOT credited** (the most valuable part of the
report): the extent rule in `check_byte_cover` (its NOEXT arm kills identically
to NEW on all 13 rows), and the `pieces` threading in `gen_layer_program` and
`fk33_run_layer`. Non-biting mutants **T5 and T12** reported under their own
names, with **T12 flagged as the hole nothing here closes**.

**CORRECTION issued by STRIPEPATH, and it binds every future track on this
path:** PIECES' quoted numbers do not reproduce -- against today's manifest the
pre-PIECES world does not emit 311 jobs, it dies on an `hbm_map` OVERLAP, and
the bases are not byte-identical to the flat program's. **The defect is real and
was measured directly; the specific numbers must not be quoted. PACKSTRIPE has
now moved the manifest between tracks twice.** Pin the manifest's identity
(path plus hash) in any write-up that measures against it.

Also corrected: `fk33_run_layer` needed **no** `hbm_map.plan().check()`, because
`make_layer` already calls `place_desc_arena()` which runs one and raises. "The
same two lines" was wrong once already.

### THE CARD EXPERIMENT IS READY, AND ITS PREDICTION IS PINNED IN ADVANCE

Section 9 of `docs/debugging/2026-08-30_stripepath-five-emitters.md` carries the
offline arm, the card arm (Oren's only) and a failure-mode table.

**Prediction, stated before the run: cycles/beat should fall from the MEASURED
21.67 to between 1.60 and 3.0.** DERIVED: 27 beats on one pseudo-channel = 21.60
core cycles; at most 2 lanes per channel = 1.60, which is exactly the RTL's own
ideal-memory floor.

**The falsifiers are stated too, and this is what makes it an experiment rather
than a demonstration.** A measured **10 to 12** means half the lanes still share
a channel. An **unchanged 21.6** means the image or the descriptors are not the
striped ones, and is **NOT evidence about the theory**.

**No new bitstream is needed.** Two things still block it:

1. **`hw/fk33/host/fk33_run_token.py:1103` is a SIXTH consumer with the
   identical defect**, on the token path, emitting the lm-head's 15 window
   descriptors. **Until it lands, a striped set gives a correct 32-layer body
   and a WRONG lm-head.** Dispatched as TRACK TOKENSTRIPE.
2. **PCIe enumeration.** The card is configured (`d31ab02`) but its root port is
   hidden by the BIOS; see the CORRECTION in
   `docs/debugging/2026-08-30_restoring-the-card-after-a-power-cycle.md` -- a
   rescan cannot work and the fix is a warm reboot, deferred by Oren until the
   synthesis and gate lanes quiesce.

Also handed over: `tools/weights_residency.py` fails on a striped manifest for a
reason unrelated to what it guards (`stack_hole_bytes` computed for the flat
layout against 2.69 GiB of by-design arena gaps) -- **needs an owner BEFORE it
gets muted**, also TOKENSTRIPE. And `pack_model_fk33.expand_pieces()` remains a
**second producer** of piece extents.

### TRACK SEAMMAP COMPLETE, 2026-08-30 (`1e46fb3`). N2 option (a) has an address.

**`0xE000` is assigned, and it was checked rather than inherited.** MEASURED
against the EMITTED `build_fk33_pcieep.tcl` rather than a document: BAR
occupancy is 0x3000 SYSMON, 0x9000 GPIO, 0xA000 id, 0xB/C/D000 thermal,
0x10000 + 8K scratch, 0x12000/0x13000 engine. **`0xE000` and `0xF000` are the
only free 4 KB pages below the scratch**, and `0xE000` is the lower. It is
inside the 128 KB BAR and 4 KB aligned, which `fk33_seam`'s 12-bit
`s_axi_awaddr` requires. `FK33_SEAM_BASE_PROPOSED` is now `FK33_SEAM_BASE`
across all four callers, and **the generator refuses to emit while the
`_PROPOSED` define survives**.

**THE FINDING, AND IT IS A DESIGN DECISION THE BRIEF DID NOT ANTICIPATE. There
is no subsystem D behind this seam (N3), so its D face is driven by constants,
and the OBVIOUS tie-off hangs the host.** MEASURED at `rtl/fk33_seam.vhd:549`:
the completion arm runs only `if running = '1'`, and `running` is cleared ONLY
by `d_err`, `d_tok_done` or ABORT. **Tie both low and a GO sets `running`
forever** -- neither done nor err ever sets, and the `(done | err)` poll loop
this seam's own header prescribes never exits.

So `d_err` is tied HIGH: every GO refuses one cycle later with `EC_DESC` and
`ERR_INFO[3:0] = 0xF`, **a code `llama_top` cannot produce**, so the refusal is
distinguishable from a real error rather than merely silent. Faking a completion
via `d_tok_done <= d_go` was considered and REJECTED.

**SEAMMAP's own correction to my brief, and it is right: N2 must NOT be reported
as "done" without the clause.** What sits at `0xE000` is a real, addressable,
honest seam **with no transformer behind it**. The brief framed the
instantiation as mechanical; it was not.

**Verification worth copying.** `check_bar_map` **parses the emitted script**
rather than restating the map, deliberately avoiding the hand-table shape that
produced the descriptor-base coincidence defect. Address teeth ran a 3-arm
attribution control (pre-SEAMMAP needles / new needles / the parser): 8
refusals, 3 must-not-refuse, `MAP ALONE=4 both=4 NEITHER=0`, with **the
pre-existing arm empty on every row** (DERIVED: `git show
d53af73:hw/fk33/gen_pcieep.py | grep -ci seam` = 0). `md5sum -c` over **1,868**
tracked files.

**NON-BITER, reported under its own name and it is the useful one:** relocating
`fk33_id` to `0xF000` is legal on every rule and WRONG, because `fk33_regs.h`
hardcodes `0xA000`. **The check verifies internal consistency, not agreement
with the host header.** Filed as work.

**QUEUED, NOT REFUSED: a Vivado `--bd-only` run.** SEAMMAP requested it and did
not take it, because its memory footprint is unmeasured and both lanes were
committed (NORMURAM on the workstation, CBINFER on the BC-250). **It is the only
non-hardware thing that answers whether the seam responds at `0xE000`**, and it
would settle three things that cannot be checked statically: the inferred
segment name `fk33_seam_0/s_axi/reg0`, whether module reference accepts
`fk33_seam`'s `unsigned`/`natural range` ports, and whether
`core_reset/peripheral_reset` ([0:0]) connects to the scalar `rst`. All three
fail LOUDLY at the BD stage, none silently. **Dispatch when a lane frees.**

Also open from SEAMMAP: `rtl/fk33_seam.vhd`'s `CAPS_FLAGS_V = 0x5` sets
`FK33_CAP_SAMPLER` in a bitstream with no sampler (reported to DSEAM, correctly
not fixed -- not its file); `fk33_regs.h` has no seam block and its non-thermal
bases are unpinned; `desc_ram` BRAM inference is unsynthesised.

### TRACK TIMING COMPLETE, 2026-08-30 (`9e3348e`..`5d25911`). Three results.

**1. SUBSYSTEM C CLOSES 200 MHz STANDALONE FOR THE FIRST TIME.** The 256 failing
endpoints were one structure: `c_attn/vref_r`, and `LAYERS*N_KVH*EXP_W` =
8*4*8 = **exactly 256 bits**. All forty worst placed paths ran
`vref_r_reg` to `vref_r_reg` through 28 logic levels, and the post-synthesis
report named the mechanism itself (`Logic Levels: 28 (CARRY8=8 ...)`): a SERIAL
min-fold over `NBLK`=8 seeded from `vref_r`. Reassociated into a balanced tree
with `vref_r` folded last. Min is associative, commutative and idempotent on
integers, so the change is **bit-exact and latency-neutral by construction**,
and CARRY8 is unchanged at 2,734 -- the same comparisons, re-bracketed.

MEASURED on the BC-250, before and after: **WNS -3.122 to +0.825, Fmax 123.1 to
239.5 MHz.**

**2. THE FIT, WITH RMSMUX MEASURED AND THE SQUEEZE DENSITY. The two levers are
EQUALS, correcting TIMING's own earlier claim that lever C led:**

| configuration | CLB |
|---|---:|
| RMSMUX alone | **92.1%** |
| lever C alone | **92.9%** |
| **both together** | **84.1%, the first configuration with real margin** |

**3. THE BRIEF I GAVE TIMING WAS WRONG, AND IT SAID SO.** I told it "only 256 of
1,027,089 endpoints fail". **That was the POST-SYNTHESIS count; the placed
report already on disk said 33,767.** There were two independent problems and my
brief described only the first. The other 33,511 are **net-delay, not logic**:
mean net 4.575 ns against mean logic 0.670 ns, 20,000 of 20,000 net-dominated.
The attribution control is the convincing part: **subsystem A, unchanged and
proven on silicon, fails 3,779 endpoints in this composition.** Root cause is
area, at 54,866 of 54,960 CLB.

Also retired: the post-synthesis 279,484 hold violations are an **artefact**,
collapsing to 7,881 on placement with no RTL change, and the named path has
`Logic Levels: 0`.

**NEW OPEN ISSUE, and it is the highest-value line in TIMING's report:
`tb_attn_block` PASSES A DELIBERATELY BROKEN TREE.** This is the bench named
after the unit, carrying subsystem C's bit-exact oracle, and it was found only
by running the mutant. **A guard passing for the wrong reason, in the one place
that was most trusted.** It needs an owner. Note this is the same unit that
"passed seven properties and 13 of 17 wiring mutations while computing wrong
numbers" in the CLAUDE.md verification list, so this is the SECOND time
`attn_block`'s evidence has been shown not to discriminate.

**AND THE STANDING CAUTION ON ALL THREE NUMBERS ABOVE.** Those percentages need
a density reached only under pressure, and reaching it cost **0.602 ns of WNS**
on a design whose observed failure is `[Route 35-447]` **routing congestion**,
not area. **The next question is not another area number. It is whether an 84%
configuration ROUTES.**

### SUPERSEDED 2026-08-30 by TRACK TIMING's pblock squeeze (`1ebac6e`)

**The table immediately below is SUPERSEDED. Its density constant was measured
on an empty die and is wrong under pressure.** It is kept because the levers and
their ordering are still right and because the correction is the point.

The squeeze constrained the composed design to a pblock at 85.4% of the die and
asked whether the placer would fail. **It did not fail. It placed.**

```
PS_PLACE_RC       0
PS_UTIL  lut 347906  clb 49497
PS_DENSITY        7.029 LUT per CLB
PS_WNS            -3.658
```

| | whole die free | pblock, 85.4% |
|---|---:|---:|
| CLB | 54,866 | **49,497** |
| density | 6.324 | **7.029** (+11.1%) |
| non-mux density | 5.617 | **6.553** |
| WNS | -3.056 | **-3.658** |

**Density is elastic. 6.324 was a property of an empty die, not of the
netlist** -- the same netlist packed into 5,369 fewer CLB under pressure. This
falsifies the `D_nonmux = 5.617` constant that the C4 arithmetic used. LEVERC's
mux term is untouched: 8.00 is pinned by the CLB structure, exactly as its
architectural argument requires.

| configuration | old (5.617) | **squeeze-measured (6.553)** |
|---|---:|---:|
| today + shell + ROM best | 123.5% | **110.1%** |
| **+ lever C + gain to BRAM** | 105.3% | **92.9%** |
| + lever C + BRAM + `d_norm` | 94.7% | **82.7%** |
| **+ `d_norm` + BRAM, no lever C** | 102.2% | **90.7%** |

**Two levers may suffice on CLB count. The 105.2% relayed to Oren is
superseded.**

**RELABELLED 2026-08-30 by TRACK NORMURAM: those rows said "gain to URAM" and
the resource is BRAM.** MEASURED, Vivado's own words in TRACK NWROM's log
(`/mnt/storage/nwrom/out/vivado_nw_lfura65.log:412`, sitting in the artefacts
since 2026-08-29 and never read past the result CSV):

```
WARNING: [Synth 8-10226] The ram_style = ultra set on ROM
"ooc_nwrom_memura__GCB101/gvr.nwrom" can not be honored for this device.
The URAM primitives on this device do not support initializations to any
non 0 values.  This ROM will be implemented using BRAMs
```

Both of NWROM's memory probes report **`uram=0`**. The "114 URAM288" that this
brief, TRACK SCATTER section 11 and TIMING's table all carried is the **`bram`
column of a run in which the URAM request was REFUSED and silently downgraded.**
The probe never used a single URAM.

**The LUT saving is real and unaffected; what changes is the currency.** The
gain image costs **114 to 135 BRAM tiles of the 672 on this part**, and nobody
has been charging that against a BRAM budget. RMSMUX's vectors want 6 more.
**"320 idle URAM288" is true and unusable**: URAM on this device is available
only to a store written at RUN TIME, so the only URAM-capable way to serve this
gain is the HBM route, which is a point in route (c)'s favour that no brief
made.

**No design change followed, and that is correct.** Vivado falls back to BRAM
either way; asking for `rom_style = "block"` explicitly only stops the log
carrying a WARNING that claims a resource the design never gets, which is
exactly how the misread happened.

**TIMING's own prediction was refuted on both limbs** and it says so: it
predicted the placer would either fail or stay near 6.32, and neither happened.
The pre-registered threshold of 48,000 CLB was not met at 49,497, so by the
letter the claim survives and by its spirit it does not.

**TIMING's withdrawn 93.2% and this measured 92.9% agree, and that is TWO ERRORS
CANCELLING, not vindication.** Section 7a inflated density for an
architecturally backwards reason AND under-estimated achievable density under
pressure, by similar amounts in opposite directions. **The 93.2% stays
withdrawn**; reasoning is what gets reused and none of that reasoning was right.

**AND THE CATCH, WHICH IS PROBABLY THE REAL RESULT. The squeeze bought CLB
capacity in exactly the currency this design has already run out of.** WNS went
**-3.056 to -3.658**, and the router had already declared, at the LOOSER
density, that `[Route 35-447] congestion is preventing the router from routing
all nets`. At 7.029 there is less routing resource per cell, not more.

**"Fits by CLB count" and "builds" are different claims, and this experiment
moved only the first.** A design at 92.9% CLB and 7.029 density gives the router
a HARDER job than the one that already failed. Nobody may quote a percentage
from the table above as a fit verdict.

**Everything containing "+ lever C" is gated on TRACK CBINFER**, which is
answering LEVERC's own first open item: whether Vivado infers LUTRAM from
`cb`'s array-of-array-of-`signed` at all. If it does not, lever C is 1,536
register copies, strictly worse than today, and those rows are moot.

**The fit needs THREE levers, and the ordering is not what anyone assumed:**

| configuration | CLB |
|---|---:|
| today | 121% |
| + lever C alone (IQ4_NL codebook to LUTRAM) | 115.9% |
| **+ `d_norm/gvr.u_rms` read muxes alone** | **102.2%** |
| + lever C + norm gain image out of LUTs | 105.2% |
| + all three | 94.6% |

**`d_norm` alone beats lever C alone by 13.7 points and nobody was working on
it.** It is 43,213 LUT plus 17,696 MUXF7 of 1024:1 read muxes, it has **never
run on silicon** (the token run's 64 RMS norms ran on the host), so it carries
less regression risk than lever C, which is inside `matvec_core`.

**Caveats that bound all of the above, and must travel with it:**
- The 94.6% row is **overstated by ~17,405 LUT**: TRACK NORMURAM MEASURED that
  "+32,943" is the saving from DROPPING the gain image, not MOVING it, because
  any real gain pays a 17,367 LUT `w_mant` fold wherever the table lives.
- The norm-image term is the best of six draws of the one quantity SCATTER
  ruled **NOT SAFE to quote as a point** (82,597..128,065). Range or nothing.
- `compose4` **wires nothing to anything** -- no inter-subsystem nets, no host
  plumbing. The real top adds logic and nets on top of 420,240. The total is a
  FLOOR.
- A `pblock_squeeze` (netlist unchanged, die restricted to 46,920 CLB) is in
  flight and is **the only measurement** of packing under pressure. Everything
  else about density is inference.

### The engine runs at 1/22 speed and the cause is the address map, not the RTL

DERIVED before fitting, then MEASURED to 0.32%: one core weight word is
24 weight + 3 scale beats = 27 x 32 B = 864 B; one 256-bit HBM port at 250 MHz
is 8.000 GB/s; 27 beats through ONE port = 21.60 core cycles at 200 MHz.
**Measured slope 21.67.** The card sustains 7.39-7.88 GB/s -- 92-99% of exactly
one AXI port, with 26 idle -- because **235 of 250 tensors have all 27 lane
sub-regions inside ONE 256 MiB segment**, which is the pseudo-channel granule.

The attribution control is what makes it solid: the same shipping RTL with only
the memory model swapped runs at **1.60 cycles/beat at identical `MAXOUT=16`,
`MAXB=16`, `DEPTH=512`** -- which kills the outstanding-read hypothesis
outright, including TRACK A7's `outst` depth.

**Fix is in the packer, not the RTL.** Supply model `max(1.60 datapath, M/1.25
memory)` where M = lanes per pseudo-channel: M=1 and M=2 both give **1.60**, M=3
gives 2.40, M=27 gives 21.60. **M=2 is exactly the knee**, so the shipping
default is 27 lanes on 25 segments, max 2 per PC: full datapath-floor
throughput at **75,340 tokens**, against Oren's stated 64k requirement.
**The model has NO anchor at M=2** -- flagged as its largest unhedged
assumption.

**BLOCKED:** `gen_layer_program.py` correctly refuses a striped manifest rather
than emitting a wrong program, so **nothing can emit a token program for a
striped set** until TRACK STRIPEPATH lands. The card experiment cannot run
before then.

### Decisions taken by Oren, with their triggers

- **N2 = option (a)**: the seam in front of D. "We don't want host controlling."
  `rtl/fk33_seam.vhd` landed (`9270c7a`). **`0xE000` is still assigned nowhere
  in `gen_pcieep.py`** -- the block has registers and no address.
- **Context requirement is 64k**, not 262,144. Ceiling on one card is ~202,681,
  but **X1 must be checked against the SHIPPING striping layout, never against
  202,681**, which describes a configuration nobody intends to build.
- **9B is single-card.** Two cards buy a fit and context, **not speed**.
  MEASURED: `attn_mac_array` is **exactly invariant under tensor parallelism**
  because `G := N_QH/N_KVH` divides numerator and denominator by the same N --
  the N=2 draw returned **298 DSP, identical to N=1, to the unit**. The ladder
  that does shrink it (`QH_TILE` below `G`) is available at N=1 with no second
  card, no subsystem E and no peer link. Reopens only on context, a bigger
  model, or batching.
- **Lever C reopened** by its own stated trigger. Its closure had been
  discharged against the subsystem-A-only PBLOCK route, not against A+B+C+D.

### The defect class this project keeps finding

**Guards that pass for the wrong reason. Six more today**, in addition to the
four already recorded:

1. `check_hbm_stack.py` PASSED over **7,154 ranges of which zero exist**.
2. The **42-field descriptor cross-check cannot see a wrong address.** With a
   piece's address mutated, `make_plan` reported **69 of 69 fields agree** --
   the placement is on both sides and cancels. It had the same defect via
   `hbm_base`. This is the check that was described everywhere as "gates every
   job".
3. `gen_layer_program.py --token` on a striped set emitted **311 of 311 A jobs,
   0 refused, all 6,723 bases byte-identical to the flat program's** -- a
   complete, gateware-acceptable, wrong program reported as success.
4. `tb_attn_block` -- the bench named after the unit, carrying subsystem C's
   bit-exact oracle -- **passes a deliberately broken min-fold tree**.
5. Lever C's closure in this file, discharged against the wrong design.
6. The 2026-08-25 capacity table's "9B fits with ~2.9 GiB spare" **counted
   weights only**; at 262,144 the real figure is 9.625 GB against 8.590 GB. It
   underwrote the single-card strategy for five days and survives only because
   the answer came back 64k.

**And one model failure of a different shape:** a one-parameter packing model
calibrated on a single placed design was wrong by **12 points with its sign
inverted**. It was correctly labelled ESTIMATE with its assumption stated, and
that was not enough. See CLAUDE.md.

### The machine

The workstation **hung hard at 01:25** under six concurrent Vivados --
`kcompactd0` stuck 75 s, RCU stalls, nine CPUs in soft lockup, power button,
FPGA configuration lost, ninety minutes of place-and-route destroyed. **A single
composed route leaves 233 MB free while ALONE on the box**, so no pre-flight
`free` check could ever have caught it. Rules in CLAUDE.md; the second lane
(BC-250) was idle at load 0.07 the entire night and was never used.

**The card is currently UNCONFIGURED** -- slot power was cut -- and nothing has
been reprogrammed since.

## THE REFILL RULE (read this first, every time)

**Standing instruction from Oren, 2026-08-28: the parallel slots must not go
empty while the backlog is non-empty, and this runs overnight.**

So: **every time an agent completes, before writing the report, check the
BACKLOG below and dispatch the next ready item.** Closing a track and refilling
its slot are one action, not two. It is easy to land a result, write it up well,
and only then notice that four slots have been idle for the whole write-up --
that happened once already today and Oren caught it, not me.

Target **four concurrent tracks**. Fewer only when the backlog genuinely has
nothing whose dependencies are met. If that ever happens, say so explicitly
rather than quietly running one agent.

A backlog item is READY when its file ownership does not collide with a running
track and its listed dependency has landed. If nothing is ready, the right move
is to look for what the last few results NEWLY unblocked, because every landing
today opened at least one new item.

**Discipline for closing a track.** When an agent lands, do exactly one of:

- **MARK OFF** the branch that fired, move the row to the Landed table with its
  commit, and dispatch whatever that branch names.
- **WRITE THE ISSUE DOWN** in Open issues below, with the evidence, then either
  send the agent a follow-up (if the fix is determined) or raise it with Oren
  (if it is a decision rather than a fix). Never silently retry.

Status values: `RUNNING`, `LANDED`, `BLOCKED-DECISION` (needs Oren),
`BLOCKED-DEP` (waiting on another track).

---

## WHAT STANDS BETWEEN THIS PROJECT AND 9B INFERENCE ON THE CARD

**Added 2026-08-29 by TRACK BOARDAUDIT. Every fact here is MEASURED against the
tree at `5a19f984`, and the audit went looking for it because several tracks
had each said a piece of it in their own write-ups and no place on this board
said it whole.**

**The one-sentence answer: the design routes, a bitstream exists and is loaded,
the 9B weights are resident in HBM and verified against a digest the loader did
not produce -- and NOTHING HAS VERIFIED WHAT ANY OF IT COMPUTES, because the
card carries subsystem A alone and no tool in this repository can start a job
on it.**

The five things that are true, in the order they were established:

1. **The bitstream routes and loads.** `ed1ffe2`, 0 nets with routing errors,
   288,506 fully routed, `hw/fk33/bit/fk33_pcieep_eng.bit` 22,568,402 bytes.
   Loaded on card 1: configures, links Gen3 x4, identifies as `0x464B3333`,
   SYSMON reads through the design, BAR writes work, the DMA BRAM and both HBM
   stacks round-trip. `docs/debugging/2026-08-29_first-engine-load-on-card.md`.
2. **The weights are on the card and are the right bytes.** 4,487,442,432 B
   written in 8.76 s and read back and matched against the manifest's pack-time
   `blake2b_128` and an independently written header parse. TRACK WEIGHTS,
   `9d7a9e5`. That write-up's own words: **"a loaded magazine, not a fired shot."**
3. **The card carries subsystem A and nothing else.** MEASURED:
   `hw/fk33/rtl/fk33_engine.vhd` instantiates `matvec_int4_desc_axi` and no
   other work unit. There is no B, no C, no D on the silicon.
4. **No host tool can start a job on it.** MEASURED: `gen_pcieep.py` puts the
   engine's register map at `ENG_CTL_BASE = 0x00012000`;
   `grep -rn '0x12000\|ENG_CTL' hw/fk33/host/ server/ tools/` returns nothing.
   `fk33_regs.h` has no engine block. `fk33ctl.py` has ten commands and none of
   them starts an operation.
5. **The host seam that WAS written targets a contract no gateware implements.**
   MEASURED: `server/fk33_seam.h` defines `FK33_SEAM_*` with magic `"LLM2"` at a
   base its own comment calls **PROPOSED, NOT DECIDED**; no file under `rtl/` or
   `hw/fk33/rtl/` mentions it. `server/pl_backend.c`'s third line says
   **"Nothing here has ever run against the card."**

**So there are three gaps, not one, and they are of different kinds.**

- A **tooling** gap: N1, the host-side runner for one A job, checked against
  `ref/matvec_int4.c`. Writable and testable with **no hardware** through
  `fk33_transport_open_sim`/`_filedir`; only the final run needs the bench.
- A **decision** gap: N2, whether the seam or the descriptor plane is the
  contract. Nobody should pick this for Oren.
- A **design** gap: N3, an RTL top that composes A+B+C+D for the card. It does
  not exist. `rtl/llama_top.vhd` composes all four but is a simulation top: it
  binds `matvec_int4`, which has no descriptor plane, and `C_REAL`, `C_KV_AXI`,
  `NORM_REAL` and `B_SRC_REAL` all default FALSE. N3 is blocked on B+C+D
  fitting, which is WRITEDEC and N5.

**The ordering matters and the cheap step is first.** N1 is small, needs no
decision and no new RTL, and it is the only one of the three that converts
"9B inference on the card" from an unfalsifiable claim into a measurable one.
Every schedule below it rests on arithmetic nobody has ever checked on this
silicon.

---

## File ownership, right now

Two agents editing one file has already cost this project real time. Nothing
below may be edited by a track that does not own it.

**REWRITTEN 2026-08-29 by TRACK BOARDAUDIT. The table it replaces named four
tracks that had landed days earlier (C-ORACLE, B-ACCURACY, TOK-C, A-CTRL) and
named none of the tracks actually running that night.** An ownership table that
lists dead owners is worse than none: it makes free files look taken and taken
files look free, and both errors cost a dispatch.

| path | owner | note |
|---|---|---|
| `sim/regress.sh` | **SHARED** | any track adding a test edits it. Re-read it immediately before editing, keep the edit to the rows you add, and re-check `BASELINE_PASS` at commit time. Editing it under a running instance is already safe; see the note below. |
| `rtl/rmsnorm_rs.vhd`, `rtl/gdn_block.vhd`, `rtl/attn_block.vhd`, `sim/ooc_writedec_*`, `hw/fk33/results/writedec_*` | **TRACK WRITEDEC** | RUNNING. Has already committed `51323ca` for `rmsnorm_rs` and is working through `gdn_block` and `attn_block`. |
| `sim/tb_llama_top.vhd`, `sim/realshape_gate.sh`, `sim/elab9b_run.sh`, `rtl/attn_kv_axi.vhd`, `rtl/attn_c_ports_skel.vhd` | **TRACK KVVALUE** | RUNNING |
| `rtl/llama_top.vhd`, `rtl/hbm_tg.vhd`, the `sim/micro` copies | **TRACK CLOG2TOP** | RUNNING |
| `docs/WORKLOG.md` | **TRACK BOARDAUDIT** | RUNNING, exclusively, by arrangement with Oren for the duration of the audit. Released when this track reports. |
| `hw/fk33/gen_pcieep.py`, `hw/fk33/*.tcl`, `hw/fk33/*.xdc`, `hw/fk33/gen_fk33_engine.py`, `hw/fk33/rtl/fk33_engine.vhd` | free | released by TRACK SHELL at `928ad9f`, then by TRACK PBLOCK at `ed1ffe2`. `rtl/fk33_engine.vhd` is GENERATED, so edit `gen_fk33_engine.py`. **Wanted by backlog rows N3 and N4.** |
| `hw/fk33/host/fk33_load_weights.py` | **A TRACK IS ACTIVE HERE** | Committed `4b26b7e` and `6d9c857` on 2026-08-29 while BOARDAUDIT was running: the fast residency check passed an object neither check ever read. Track name not declared in either message. **Treat as owned until it reports.** |
| `hw/fk33/host/**` except `fk33_load_weights.py` | free | never claimed by a track. **Wanted by backlog row N1**, which is the first thing to dispatch. N1 adds a NEW file and edits `fk33_regs.h`, so it does not collide with the loader work above -- but confirm that before dispatching, because this row was measured wrong once already tonight. |
| `rtl/attn_*.vhd` (except `attn_kv_axi`, `attn_c_ports_skel`, `attn_block`), `sim/tb_attn_*.vhd`, `ref/attn_*` | free | released by TRACK C-ORACLE `8baa413`, TRACK C-SEAM and TRACK RY-ORACLE |
| `rtl/gdn_*.vhd`, `rtl/l2norm_rs.vhd`, `sim/tb_gdn_*.vhd`, `ref/gdn_*`, `ref/l2norm*` | free | released by TRACK B-ACCURACY, TRACK B-FIX, TRACK B-RECUR `ea26eec` and TRACK BGATE2 `dfe308c`. **`rtl/gdn_block.vhd` is the exception: WRITEDEC holds it.** |
| `tools/qwen35_tokenizer.py`, `tools/*tokenizer*`, `server/**` | free | released by TRACK TOK-C `0181cc3` and TRACK SERVER `3963a60`. **Wanted by N2 once the decision is made.** |
| `rtl/matvec_int4*.vhd`, `rtl/weight_streamer.vhd`, `rtl/axi_rd_port.vhd`, `rtl/axi_rd_fsm.vhd`, `rtl/async_fifo.vhd`, `hw/mv_driver.c`, matvec benches | free | released by TRACK A-CTRL `a4f7e17` and TRACK OUTMODE `0ff6828`. **Wanted by backlog rows N7, N8 and N10.** |
| `tools/gen_layer_program.py`, `tools/dprog_oracle.py`, `tools/hbm_map.py` | free | released by TRACK D-PROG `a2b20f3`, TRACK SCHED-FIX and TRACK ARENA-MANIFEST `b28e92b` |

**A COMPLETED AGENT CAN STILL WAKE UP AND COMMIT.** Observed 2026-08-28: the
subsystem-A-sim track reported done, was superseded, and then woke hours later
and committed `2b12a7b` while TRACK A-CTRL already owned those files. It landed
clean (a doc correction plus a comment in `sim/regress.sh`, `BASELINE_PASS`
untouched, the bench itself not touched) so nothing was lost, but that was
luck rather than design. Consequences:

- "Completed" is not "released". A track's ownership row stays until its files
  are verified quiescent, not merely until its report arrives.
- After any late commit, re-run the affected tests yourself rather than
  trusting either agent's report. That agent explicitly said its own
  confirmation run never returned and declined to claim it, which was the right
  call; the run was completed separately and all three passed.
- Prefer giving a superseded track NO further instructions. Sending it a
  follow-up is what turns a harmless late commit into a genuine collision.

**`git commit -m msg -- <paths>` COMMITS THE WORKING TREE, NOT THE INDEX.
THREE INDEPENDENT TRACKS HIT THIS ON THE SAME DAY** -- C-ORACLE, B-ACCURACY,
and me, the last of them one commit after documenting it. B-ACCURACY hit it in
its most deceptive form: it staged a single hunk of the shared `regress.sh`
with `git apply --cached` and then named the file on the commit line, which
discarded the careful staging entirely. It caught this only because the
committed `--stat` disagreed with the staged one, 22 lines against 7.

Three instances in a day means this is not an advisory to be more careful; it
is a property of the command that has to be worked around structurally. **On a
shared file: stage the hunk, then commit with NO pathspec.**
Observed 2026-08-28: TRACK C-ORACLE's first commit swept in TRACK A-CTRL's
uncommitted `sim/regress.sh` edits (`BASELINE_PASS=78`, rows for tests whose
files were not committed yet) purely because they were sitting in the working
tree at that path. It caught this and amended them out, and HEAD is clean, but
the pathspec form is the exact form this project's standing instruction
mandates in order to AVOID `git add -A`, so the two rules fight each other on
shared files.

The rule that resolves it: **for a SHARED file, run `git diff -- <file>` and
confirm every hunk is yours BEFORE committing.** If it is not, stage only your
hunks with `git add -p` and then commit with no pathspec so the index is what
lands. For files only your track owns, the pathspec form is still correct and
still the default.

An amend is only available while the bad commit is still the tip. Two tracks
committing within a minute of each other would have made it permanent.

**Editing `sim/regress.sh` under a running instance is ALREADY SAFE, and you
do not need to `pgrep` first.** bash reads a script lazily by byte offset, so
in general editing a script mid-run resumes the shell mid-token and the process
that dies is not the one that edited it. `sim/regress.sh` was bitten by exactly
this three times during its own development, once to a third party, so section
0 now copies the file to a private temp path, syntax-checks the copy in case
the original was mid-write, and re-execs that (`:287`, `:299`). From then on
the running process reads a file nobody else can name.

Recorded because a track disclosed having edited it during another run and
could not rule out damage. There was none, and there could not have been. The
disclosure was still the right call: reporting a suspected collision you cannot
disprove is worth more than a silent hope, and the answer only took one grep.

**CORRECTION, appended: commit `4891c6d` mixes two authors' work.** Its
message describes only my `regress.sh` note; everything else in it is TRACK
A-CTRL's own worklog update, swept in by a pathspec commit while A-CTRL was
editing the same file. Nothing was lost and A-CTRL's content is intact; the
defect is a message that described half its contents. It could not be amended,
because another track committed on top within the minute -- which is the
failure mode recorded two paragraphs above, reproduced against its own author
inside an hour.

The root cause is worth more than the incident. I ran the prescribed check,
saw it print DIRTY, and committed anyway, because I had chained the check and
the commit into one command so the check merely PRECEDED the action instead of
GATING it. **A check whose result you do not branch on is decoration.** Run the
check as its own step, read it, then act.

**Standing rule for every track: no hardware.** No `xsdb`, `hw_server`,
`vivado ... program`, `pcieep.sh`, `jtag.sh`, `flash.sh`, `program.tcl`, and
nothing that opens `/dev/xdma*`. A live FK33 is in this session, and an agent
has already destroyed its factory flash image by crossing that line.

---

## In flight

**This section is REWRITTEN at every dispatch, not appended to.** I set that
rule on 2026-08-29 after an independent review found it listing two tracks as
RUNNING a day after both landed, and then broke it myself across eight
consecutive dispatches. Appending is one action and retiring a row is another,
and only the first feels like progress. If this table names a track that has
landed, the table is the defect.

**Corrected 2026-08-29 by TRACK BOARDAUDIT: BGATE2 had LANDED (`dfe308c`) and
was still listed here as RUNNING, which is the defect this section's own rule
names. It is moved to Landed. BOARDAUDIT is added, because it was running and
was not listed.**

| track | question | owns |
|---|---|---|
| **READCONV** | **The remaining lever on the `pb_core` fit.** B's read-side conversion, needing `l2norm_rs` to take a streaming port. LUTDIET measured B's read share at 8.9% of 585,430 primitives, so this is the smaller half and may not close 40,079 alone. NOT the BRAM trade; that stays the fallback. | `rtl/l2norm_rs.vhd`, `rtl/gdn_block.vhd`, `rtl/attn_block.vhd`, `rtl/rmsnorm_rs.vhd`, `sim/ooc_readconv_*` |
| **ACOV** | Row N8. Subsystem A's three coverage gaps -- no mutation script for `matvec_int4.vhd` or `axi_rd_port.vhd`, `USE_XEXP_PORT=true` in no bench, `DUAL_CLK=true` manual only. **A is now the only part of this design proven on silicon and the part with the named holes.** | `sim/mutate_matvec_int4.sh` (new), `sim/mutate_axi_rd_port.sh` (new), `sim/tb_a_geom.vhd`, `sim/tb_matvec_fk33_desc.vhd`, `tools/verify_mv4i_desc.py` |
| **NWROM** | NORMADAPT's flagged risk: **every fit number tonight was taken with `NORM_W_IMAGE` EMPTY.** Populated at 9B it is 65 entries of 65,536 bits with a 65:1 mux, and may cost more than the 76,613 LUT NORMADAPT just saved. Measure it, and say whether it belongs in BRAM/URAM -- both sit unused in every measurement taken tonight. | `rtl/llama_top.vhd`, `sim/ooc_nwrom_*`, `hw/fk33/results/nwrom_*` |
| **GRAY1** | Row N10, **the sharpest instance of tonight's theme**: `G1` (both gray functions replaced by identity) is caught by neither simulation nor `report_cdc`, and **the broken design reports TWO FEWER `report_cdc` warnings than the correct one**, so a "must not get worse" rule actively passes it. In `async_fifo.vhd`, which is in the datapath now working on silicon. | `rtl/async_fifo.vhd`, `sim/cdc_teeth.sh`, `sim/tb_async_fifo*.vhd` |

**Landed since the last rewrite:** OI3B, COMPOSE, WEIGHTS, REALSHAPE, REALFIX,
SEAMGATE, RY-MODEL, SCHED-FIX, ORDINAL, ARENA-MANIFEST, KVSIZE, CGENERICS,
BUILD-E2E, GATEHYGIENE, BTOP1, LUTDIET, CKVMAP, CLOG2, BGATE2 (`dfe308c`),
BOARDAUDIT (`7c5f5a3`..`d7952b6`), KVVALUE (`ef1aa7e`), WRITEDEC (`971524c`),
AJOBRUN (`1fdf42e`), CLOG2TOP (`61e6a12`), ERRINFO (`a269ed4`, row N12),
NORMADAPT (`45981f0`), OI3MUT (`3853650`, row N6).

### The fit, corrected. MY ARITHMETIC WAS STRUCTURALLY WRONG.

I told the board that NORMADAPT's 129,877 LUT target was "four times the
31,359 `pb_core` gap". **That subtraction was never valid**, and NORMADAPT
caught it: the 31,359 shortfall comes from the OPTIMISTIC booking, whose
`D_norm` is the bare `rmsnorm_rs` with **no adapter storage at all**. You
cannot reduce a shortfall computed from a total that never contained the thing
you removed. The 129,877 figure was also a MODEL and overstates by 52% -- the
real adapter's own logic is 102,204, and `wv` **does not exist in `llama_top`**.

MEASURED position now: **realistic B+C+D = 273,844 LUT**, over the device by
**5,622** and over `pb_core` by **40,079**, against 350,457 before NORMADAPT.
What NORMADAPT actually bought was collapsing the gap between the optimistic
and realistic bookings from 85,333 to **8,720**. **READCONV is the remaining
lever**, and TRACK NWROM may yet move the number the wrong way.

## ROW N1 IS ANSWERED. SUBSYSTEM A COMPUTES CORRECTLY ON THE FK33.

MEASURED 2026-08-29 20:12-20:16 by the dispatcher on card 1, under Oren's
one-night authorisation. **Twelve jobs. All eight distinct `(M, K)` geometries
in the 9B model. Every mantissa and every `y_exp` bit-identical to
`ref/matvec_int4.c`.** `err_code=0x0 (EC_NONE)` throughout; `BEATS` matched
`tiles*nblk` exactly every time. Write-up:
`docs/debugging/2026-08-29_first-arithmetic-on-the-silicon.md`.

The load-bearing row is `blk.11.attn_k.weight --rows 100`: that is the **exact
argv `sim/regress.sh:1428` feeds `sim/tb_matvec_fk33`**, on a byte-identical
file, so the card and the simulator agree on the same job. The two awkward
geometries were chosen deliberately: `M = 8224` is the only shape in the model
that is **not** a multiple of 32, and `M = 248320` is the lm_head (run at 64
rows, one window inside the 17,408 cap -- this does **NOT** contradict LMHEAD's
finding that the gateware refuses it as one job).

**Every result is unconfounded by THERM-255, and that was checked rather than
assumed:** counter cleared at 20:12:27, read 0 before and after every job,
`LATCHED TRIP none since the last clear` still true at 20:16.

**What this does NOT establish:** subsystem A alone. `fk33_engine.vhd`
instantiates `matvec_int4_desc_axi` and nothing else, so **B, C and D have
never run on this silicon** -- row N3 stands. One activation vector per job,
supplied by the host; nothing here exercises a layer, a sequence or the KV
cache. And one row-count per geometry, so an off-by-one at a window boundary
is not excluded.

**Tracks that landed and appear NOWHERE on this board, found by TRACK BOARDAUDIT
2026-08-29.** Each has a full write-up in `docs/debugging/` and none is named in
any Landed row. Recorded here rather than reconstructed into rows, because the
write-ups are the artefact and the point is that the board lost them:
**PBLOCK** (`ed1ffe2`, `2026-08-29_shell-pblock.md` -- the routed bitstream),
**FIRSTLOAD** (`2026-08-29_first-engine-load-on-card.md` -- the bitstream loads,
links and identifies; three instrument defects; the memory finding raised then
withdrawn),
**CARD2** (`2026-08-29_second-fk33-verify-and-flash-backup.md` -- card 2 works,
its factory flash is dumped and double-read),
**SERVER** (`3963a60`, `2026-08-29_host-seam-v2.md` -- backlog row 5),
**B-RECUR** (`ea26eec`, `2026-08-29_gdn-recur-coverage-and-dm.md` -- backlog row 8),
**SPECREC** (`f65e2bc`, `2026-08-29_spec-reconciliation.md` -- backlog row 9;
this one DOES have a Landed row, so the board contradicted itself),
**CAPTURE** (`2026-08-29_capture-llama-top-r9bs.md`),
**C-SEAM** (`2026-08-29_c-seam-layer-interleave.md`),
**CDC-STATIC** (`be982b3`, `2026-08-29_cdc-static-analysis.md`),
**ADDRARENA** (`2026-08-29_addrarena-one-hbm-map.md`),
**EMBED-BF16** (`2026-08-29_embedding-bf16-upgrade.md`),
**HOST-EMBED** (`2026-08-29_host-embedding-gather.md`),
**REFTOKEN** (`2026-08-29_ref-token-automatic-verdict.md`),
**LOGITS-SEAM** (`2026-08-29_logits-seam-model.md`),
**GDN-ORACLE** (`2026-08-29_gdn-block-oracle.md`).
**MEASURED: `grep -ci` on this file for each of those filenames returned 0.**
Three of the four dispatches wasted today were onto work whose write-up was
sitting in `docs/debugging/` unreferenced.

**CORRECTION, appended the same night: fifteen was a sample, and the real
figure is far worse.** A full inventory of all **91** write-ups dated 2026-08-28
or 2026-08-29 measured that only about **18 have a row in the Landed table at
all**. The remainder split two ways, and the second is the larger problem:

* **18 tracks are named ONLY by the bare "Landed since the last rewrite"
  sentence above** -- OI3B, COMPOSE, WEIGHTS, REALSHAPE, REALFIX, SEAMGATE,
  RY-MODEL, SCHED-FIX, ORDINAL, ARENA-MANIFEST, KVSIZE, CGENERICS, BUILD-E2E,
  GATEHYGIENE, BTOP1, LUTDIET, CKVMAP, CLOG2. Every one is committed and fully
  written up, and none has a commit, a result or a single line a reader
  scanning `## Landed` would ever see. **A name-drop is not a record.** That
  sentence is the single densest piece of under-recording on this board.
* **Roughly 35 more appear NOWHERE**: no filename, no track name, no commit.
  They include whole subsystems of the day's work -- `fk33-spi-flash-boot`,
  `fk33-thermal-protection`, `fk33-free-running-observability`,
  `hbm-stack-boundary-straddle`, `llama-top-first-seams`,
  `subsystem-c-top-and-mac-array`, `cdc-and-fifo-coverage`,
  `codebook-coherency-oracle`, `three-range-defects` (the commit that actually
  fixed OI-2, OI-7 and OI-8), and `thermal-guard-255-trips`, **which is an OPEN
  hardware defect and is now recorded as THERM-255 above.**

**The generalisation, and it is the reason the board keeps failing this way.**
The commit log cannot be used to recover this: only **2 of 183** commits since
2026-08-28 use the `TRACK X:` convention, and 95 distinct message prefixes were
counted. **The reliable index is the write-up header**, because nearly every
file in `docs/debugging/` declares its own track and, where it has one, its own
backlog row number. Anyone auditing this board again should start there and not
with `git log`. And the cheap fix for the future is one line: **when a track
lands, its Landed row cites the write-up FILENAME**, so a `grep` can find it.

**AN OPEN CONTRADICTION, RECORDED RATHER THAN PAPERED OVER.** CKVMAP reported
"the real 9B KV map elaborates" (2,452,864 kB / 2.36 s, `realshape_gate` PASS
24). CLOG2 reported, as its load-bearing finding, that **`C_MAXPOS = 131,072`
cannot elaborate and fixing `clog2` cannot make it**: the argument is
6,803,283,968, **3.2x `natural'high`**, so it cannot be FORMED as a `natural`;
a perfect `clog2(natural)` moves the ceiling only to 123,361, still short; and
at 131,072 the overflow moves EARLIER, into `llama_top`'s own
`constant KVREG_B : natural := C_LAY*C_NKVH*C_MAXPOS*REC_B_C` = 2,281,701,376.
Both may be true of different configurations -- CKVMAP deliberately did not
change the default and called the real map a build configuration. **TRACK
CLOG2TOP is dispatched to settle it.** `C_MAXPOS = 131,072` is Oren's decision
and is not being reopened; if it does not elaborate, it gets made to.

**Two of my own framings were wrong and are corrected here.** (1) I told CLOG2
that `llama_top:785` "blamed a bystander"; it MEASURED that `:785` WAS the
failing `while` line inside the local `clog2`. **Missing attribution, not
misattribution** -- it names the function correctly and fails to name the
caller. (2) I said fixing `clog2` would unblock the KV map. It does not and
cannot; that is what the `clog2(unsigned)` overload exists for, and on the real
value it returns **33**, exactly `C_KV_ADDR_W`, corroborating CGENERICS'
zero-slack finding by an independent route.

**B+C+D CLOSES, and the cheapest fix is not the one anyone expected.** LUTDIET
(`4950666`) MEASURED that decoding the variable-index write with a per-word
generate and a CONSTANT index takes `rmsnorm_rs` from 169,746 to **40,804 LUT**
at identical ports, identical FF, identical WNS and **zero BRAM** -- a 76%
reduction with no memory and no interface change. That alone projects B+C+D at
**210,890 LUT against 233,765 free in `pb_core`**, against COMPOSE's 2.88x-over
starting point. The margin is 22,875 LUT, **9.8%**, which is positive and thin.

**It also corrected the mechanism, and the correction changes where to look.**
COMPOSE described the cost as a mux tree. The mux tree is **17.5%** of it.
**80.5% is the variable-index WRITE into the flat register, and that structure
uses ZERO MUXF7 and ZERO MUXF8** -- so hunting this cost by its F7/F8 signature
finds one fifth of it. Same split by netlist census in B (79.8% write / 8.9%
read, 88.7% of 585,430 primitives) and C (54.1% / 3.5%).

**Two of my own figures were wrong and are corrected here.** "Lose roughly 500K
to fit" was the DEVICE number; `pb_core` needs **538,135**. And COMPOSE
UNDERSTATED the composition: it booked D's norm at 169,746, the unit WITHOUT
the vector storage `llama_top` must add, while B and C included theirs. With
it, D's norm is 299,030 and B+C+D is ~901K, not 772K.

**`BASELINE_PASS` IS NOW 93, AND THE OLD 101 WAS UNREACHABLE ON EVERY TREE.**
GATEHYGIENE (`1399425`, `5154518`, `7676510`) found the gate had been printing
`REGRESSION: FAIL` for **every track since `e788a0e`**, including on the working
tree it was calibrated against. The planner globs `sim/tb_*.vhd` off the
FILESYSTEM and nothing distinguished a row backed by a committed file from a
private one, so two tracks counted the same two untracked benches and neither
was wrong on what it could see. 93 is a MEASURED clean-`git archive` ceiling
(97 rows, 4 NOCHECK, FAIL 0); the working tree measures **99**, the difference
being ~20 rows a clone does not get. The gate now names those rows and
**refuses to suggest raising the floor** while the list is non-empty.

**CGENERICS stopped rather than editing `rtl/llama_top.vhd` under BTOP1**, which
was the instruction and is why its remediation is a handoff rather than a
collision. That remediation -- encode C's KV bases in the format's own 16-byte
granule, `C_K_BASE_CH` 282,598,912 and `C_V_BASE_CH` 353,902,080 -- is the first
thing to dispatch when BTOP1 releases the file. It is blocked on CLOG2 too: the
chunk-domain sum needs a `clog2` that does not overflow.

**Standing instruction to every track: nothing may be run against the card.**
A SECOND FK33 arrived 2026-08-29; its factory flash image was backed up the
same day and is the only surviving copy of a SQRL factory image, card 1's
having been destroyed by an agent that crossed this line.

**This is NOT contradicted by the overnight authorisation in the Decisions
table, and the distinction is the whole point.** Oren authorised **himself**,
on 2026-08-29 only, to JTAG-configure card 1 and run host-side tests. That is a
DISPATCHER-level act by the person at the bench. **The TRACK-level prohibition
above is unchanged, unconditional and absolute**: no agent runs `xsdb`,
`hw_server`, `vivado ... program`, `pcieep.sh`, `jtag.sh`, `flash.sh`,
`program.tcl`, anything under `hw/fk33/host/`, or anything opening
`/dev/xdma*`, whatever any decision row says. A track that reads the
authorisation as applying to itself has misread it. Backlog row N1 is written
to respect exactly this split: an agent writes and fully exercises the runner
through `fk33_transport_open_sim`/`_filedir`, and only the final run is Oren's.

**This note previously said "there is no bitstream at present in any case".
That is no longer true.** TRACK PBLOCK's `ed1ffe2` produced a routed,
timing-clean bitstream (`hw/fk33/bit/fk33_pcieep_eng.bit`, 22,568,402 bytes).
The instruction is unchanged and now carries its full weight: the constraint is
the hardware boundary itself, not the absence of anything to load.

## Open, raised 2026-08-29, each needing a decision rather than more work

| # | item | state |
|---|---|---|
| **BUILD-HANG** | **A FK33 shell build has been hung for 27.6 hours and nothing noticed.** MEASURED 2026-08-29 19:05 by reading `/proc`: pid 1043119 (`vrs`) has been blocked on `wait_on_run synth_1` since **Aug 28 15:27:12**, with **7 minutes of CPU across 27.6 hours** and 2.5 MB RSS. It is not slow, it is stopped. The cause is worse than a hang: `launch_runs` printed `Time (s): cpu = 00:00:17` and **reported success**, but `synth_1` **never started** -- there is no `runme.log`, no `.vivado.begin`/`.end` marker, and no `synth_1` directory in `fk33_pcieep.runs/` at all, only the `bd_*` sub-runs. `wait_on_run` then waited forever for a run that did not exist. The parent is reparented to systemd, so the agent that launched it is long gone and never got an answer. **This is the project's own recurring defect class in a new place: a command that returns success while doing nothing, paired with a wait that cannot time out.** Any future shell build can hit it, and the symptom is indistinguishable from a legitimately long place-and-route. Scratch is `<scratchpad>/pcieep3`, 138 MB, left intact for inspection. | **PROCESS CLEARED, DEFECT OPEN.** Oren approved the kill 2026-08-29; pids 1041037/1043086/1043119 are gone and 83 GB of cold scratch from landed tracks was cleared alongside it, taking root from 98% to **91%** (38 G to 121 G free). The `pcieep3` scratch was among the ten removed. **The defect itself is untouched:** the REAL fix is a bounded wait plus a post-`launch_runs` assertion that the run directory exists, and it belongs to whoever next owns `hw/fk33/gen_pcieep.py`. Until then any shell build can hang indefinitely with a symptom indistinguishable from a long place-and-route. |
| **THERM-255** | **THE THERMAL GUARD TRIPPED 255 TIMES OVERNIGHT AND IT WAS NOT HEAT. OPEN, UNRESOLVED, AND RECORDED NOWHERE ON THIS BOARD UNTIL NOW.** Found by TRACK BOARDAUDIT 2026-08-29 in `docs/debugging/2026-08-29_thermal-guard-255-trips.md` (`0540c35`), which is an OPEN write-up whose own status line says a watcher is running. MEASURED on card 1 at `06:00.0` running `fk33_pcieep_therm.bit`: the trip counter was cleared to 0 and read **255** about 14 hours later, which is the SATURATING maximum of an 8-bit field, so the true count is 255 or more -- roughly **one trip every three minutes**. Every temperature was cool (die 35.3 C peak 37.3 against a 90 C halt; HBM 37/37 peak 38 against 85; both SYSMON stickies 0) and `trip_cause` was **0** on a saturated counter. What WAS set is `THERM_STATUS` bit 30, **the two HBM temperature copies disagreed, a CDC fault**. Working hypothesis, NOT confirmed: the HBM staleness path declares the sensor invalid after `G_STALE_MS` = 250 ms without a fresh accepted sample and correctly fails safe by treating an invalid sensor as HOT. **EACH TRIP HALTS THE COMPUTE DOMAIN.** | **OPEN, AND IT MATTERS TONIGHT.** Oren is authorised to load and run on card 1 on 2026-08-29 in order to answer backlog row N1. On a card doing real work this defect presents as **random stalls with no apparent cause**, and the write-up's own words are that it is "precisely the class of fault that gets attributed to the wrong subsystem for a week". **So before believing any N1 result, read the trip counter and the CDC sticky, and read them AFTER the run as well as before.** A stalled or wrong N1 result with a non-zero trip count is not evidence about subsystem A. **Measurement trap already recorded by that write-up and worth repeating here: a 60-second clean sample is NOT evidence of absence at a three-minute mean interval** -- twelve consecutive clean 5-second samples were taken and proved nothing. Note the engine build is a different bitstream from the thermal build this was seen on, so whether the same guard behaves this way in `fk33_pcieep_eng.bit` is itself unmeasured. |
| **IPREPO-DRIFT** | **Three copies of `util_pkg.vhd` under `ip_repo/*/src/` drift with nothing in the tree able to notice.** MEASURED by TRACK CLOG2TOP: they are regenerated from `rtl/` by `ip_repo/package_llama_ip.tcl`, and **nothing schedules that script** -- no gate row, no build script, and `sim/regress.sh` never mentions `ip_repo` at all. TRACK CLOG2's note that "the next packaging run fixes them" describes **a run that does not exist**. So `rtl/util_pkg.vhd` gained a corrected `clog2` tonight (`209d69e`) and the three IP copies still carry the overflowing doubling loop, silently. | **OPEN, no owner.** Two candidate fixes and they are not equivalent: a gate row that regenerates and diffs (catches drift, costs a Vivado invocation), or a cheap checker that compares the copies to `rtl/` byte-for-byte and refuses (catches drift with no Vivado, but cannot catch a packaging script that is itself wrong). Note this is the same class as the `sim/tr.txt` hole GATEHYGIENE closed: a load-bearing input that no gate reads. |
| **DESC-RULE2** | **`tools/gen_mv4i_desc.py`'s second base rule omits the `align4k()` that `ref/matvec_int4.c:474` and `tools/pack_int4.py:477` both apply.** MEASURED by TRACK AJOBRUN. At `GRP=1` with `K` in {4096, 12288}, `tiles*nb*port_b` is always a multiple of 4096, so **rule 2 agrees with rule 1 by coincidence of geometry on every file it has ever seen** -- and falsely refuses anything else (measured: `M=96 K=128` gives `[4096, 8192]` against `[4096, 4352]`). **That two-rule cross-check is the only guard against the one descriptor corruption the gateware cannot see**, so it is currently a guard that passes for the wrong reason. AJOBRUN's `selfcheck` carries a probe that MEASURES and PRINTS it without asserting, so it flips green when fixed. | **OPEN, no owner.** Small and self-contained. Worth doing before any shape outside the current model is packed, because the failure mode is a guard that has never actually discriminated. |
| **B-CONV-HIST** | **Raised by TRACK BTOP1 (`bf99d39`), and it is the cost of its own fix.** Opening `tvalid` so the causal conv has history turns `cvdata_p`'s zero taps from inert into a **live wrong number** under `B_SRC_REAL`: a zero mantissa carried at a real captured exponent. Both checkers refuse it independently -- `S_GO` asserts and `gdn_oracle.py` raises -- so this is not a silent defect, which is the good news. A real history needs a new `(KCONV-1) x qkv_dim` buffer, **ESTIMATE ~90 MB of GHDL signal at the 9B shape**, in the file TRACK REALFIX just fought a 46 GB signal down to make elaborate at all. BTOP1 **refused it rather than bodging it** and listed it open, which was right. Note `B_SRC_REAL` is already unrunnable for a separate `R_ALPHA` reason at `rtl/llama_top.vhd:52-58`, so nothing regresses today by leaving this. | **CLOSED AS WON'T-FIX, Oren, 2026-08-29.** `B_SRC_REAL` is not wanted, so the buffer is not built. **The two refusals stay and are the guard: `S_GO`'s assert and `gdn_oracle.py`'s raise must NOT be deleted as dead code by a later cleanup on the grounds that `B_SRC_REAL` is never true.** That deletion is exactly how a won't-fix becomes a silent defect. See the Decisions table; reopening requires fixing `R_ALPHA` first, so it is two problems, not one. |
| **B-BLK-1** | `rtl/gdn_block.vhd:958` maps value head h to key head `h/(VAL_HEADS/KEY_HEADS)` (contiguous) where the model tiles, `h mod KEY_HEADS`. MEASURED wrong on 30 of 32 value heads at the 9B shape. `VPK` appears in exactly one RTL file, so nothing downstream compensates. B spec sections 2.9 and 4 both give the RATIO and neither says WHICH heads, which is the proximate cause. | **DECIDED** 2026-08-29: fold into TRACK B-LAYER, now in flight |
| **BFP repack rule** | The 9B reference's float-to-BFP repack always normalises (`reg_put`, `exp = 14 - floor(log2(amax))`, no clamp); every shipping unit on the path clamps (`sh = max(0, msb_pos(amax) - 14)`) and so stays under-normalised on quiet blocks. MEASURED by RUNNING `rtl/bfp_pack.vhd`: 341 of 760 exponents differ, all quiet blocks, none loud, reconstructed VALUES exact. **193 of 490 BFP records per token (39.4%) are on the unclamped rule, so `--mode exact` reports a FALSE first divergence before reaching any real defect.** Three routes scoped in section 6 of REF9B's write-up; they are not equivalent. | **OREN'S CALL.** TRACK CAPTURE told to work around it and report which route the capture work says is needed, NOT to pick one |
| **`matvec_int4_axi` register 15** | No completeness guard and no idle interlock, so a partial codebook load through that plane is silently consumed. It is the standalone register-mapped plane; the FK33 path uses `matvec_int4_desc_axi.vhd`, which loads all sixteen atomically and rejects an unloaded codebook with `EC_DESC`. | Left as a decision, not a fix. Not on the FK33 path |
| **OI-9 error-code space** | Full. Widen, subdivide via `ERR_INFO`, or take a reserved D value, with consequences for D. | **DECIDED, Oren, 2026-08-29: SUBDIVIDE VIA `ERR_INFO`**, because it leaves the byte layout untouched. No longer a decision; it is backlog row N12. D-PROG was told to STOP and report rather than choose, and that was right. |
| **AXIRD-FRST** | **`frst <= rst;` in `rtl/axi_rd_port.vhd`'s `g_sc` generate is DEAD, and this is the THIRD time it has been found.** Raised first by TRACK ACOV as its mutation row `B1`, flagged again to TRACK FLOOR, and written down here so a fourth rediscovery costs nothing. RE-MEASURED 2026-08-29 by TRACK FLOOR, by enumerating every occurrence of the signal in the file: declared `:157`, driven `:203` (inside `g_sc`) and `:241` (inside `g_dc`), and READ at only `:282` and `:292`, **both of which are inside `g_dc`**. Exactly one generate elaborates, so under `DUAL_CLK = false` the signal is driven and never read. The `g_sc` FSM and FIFO both take `rst => rst` directly. Harmless to the netlist -- synthesis drops a dangling driver -- but it reads as though the single-clock branch has a FIFO reset that is used, and it is a mutation site no bench can cover, which is why ACOV scored it. | **OPEN, and deliberately NOT fixed by TRACK FLOOR: `rtl/**` was outside its ownership and the correct move was to record it rather than reach.** The fix is one deleted line and belongs to whoever next owns `rtl/axi_rd_port.vhd`. Note the deletion is only safe together with the observation above that no read survives outside `g_dc`; a reader who deletes the `g_dc` assignment at `:241` instead breaks the dual-clock path. **RE-VERIFIED AT HEAD 2026-08-29 by TRACK STRAYROW, and THE LINE NUMBERS ABOVE ARE NOW STALE** -- `75f95a8` (TRACK A7) added `abort_c` and the `gate_chk` process to the same file and moved everything down. Identify it by CONTENT, not by line: the dead driver is the bare `frst    <= rst;` that is the FIRST statement inside `g_sc`, and the live one is `frst  <= rst_s2;` inside `g_dc`. MEASURED at `75f95a8` with `grep -n frst rtl/axi_rd_port.vhd` against the generate boundaries from `grep -n 'generate' rtl/axi_rd_port.vhd`: declared `:157`; driven `:239` (inside `g_sc`, which spans `:236`-`:273`) and `:309` (inside `g_dc`, `:276`-`:372`); READ only at `:357` and `:367`, both inside `g_dc`. **The finding is unchanged and the warning is unchanged: the safe deletion is the `g_sc` driver, now `:239`, NOT the `g_dc` one, now `:309`.** TRACK STRAYROW did not fix it -- `rtl/**` was outside its ownership too, and it was told explicitly to confirm and record rather than reach. Raw measurement in `docs/debugging/2026-08-29_strayrow-gate-row-and-three-handoffs.md` section 5.7. **This is the fourth finding and the second re-measurement; the next reader should be able to act on it without re-deriving anything.** |
| **IPSYNC-DOC** | **`ip_repo/check_ip_sync.py`'s docstring now documents a defect that has been FIXED, which is the same trap TRACK FLOOR just cleared out of `tools/lmhead_window_check.py`.** Its "THE HONEST WEAKNESS" note says `hw/package_mac_axi.tcl` and `hw/package_matvec_engine.tcl` "both END IN AN ERROR, `Unknown property 'CONFIG.ASSOCIATED_BUSIF' on bus_interface`, after `ipx::save_core` has already run". TRACK FLOOR fixed both scripts 2026-08-29 and MEASURED the before and after with Vivado 2023.2 (pre-fix rc=1 and no `PACKAGE_DONE`; post-fix rc=0, `CLOCK_ASSOC: s_axi`, `PACKAGE_DONE 1`). The surrounding paragraph is still correct and worth keeping -- the checker genuinely cannot see a packaging script that is itself wrong -- so only the worked example is stale. | **OPEN, no owner. `ip_repo/**` was outside TRACK FLOOR's ownership**, so it recorded this instead of editing, which is the same call it made on AXIRD-FRST. **CLOSED 2026-08-29 by TRACK STRAYROW (`15b2f39`), exactly as FLOOR asked.** The worked example is kept in its FIXED form rather than deleted: it now states that it was first recorded by TRACK NOGUARD, that TRACK FLOOR root-caused and fixed it in `d2adbcd`, and that the MEASURED before/after was pre-fix rc=1 with no `PACKAGE_DONE` against post-fix rc=0 with `CLOCK_ASSOC: s_axi` and `PACKAGE_DONE 1`, citing `docs/debugging/2026-08-29_floor-and-three-defects.md`. The surrounding weakness paragraph is untouched. **Deleting the example would also have broken a live cross-reference in the other direction:** `hw/package_mac_axi.tcl:36` points back at this note by name. VERIFIED at HEAD rather than taken from this entry -- both packaging scripts now read the value through `ipx::get_bus_parameters` and `error "PACKAGE FAIL"` if it is not `s_axi`, and both are committed clean. MEASURED after the edit: `--selftest` `SELFTEST PASS` with `CHECK ALONE=6`, live run `IPSYNC: 3 IP(s), 32 packaged .vhd, 0 finding(s)` / `IPSYNC: PASS`. A sweep for siblings citing the same example found none: the only other live citations of `ASSOCIATED_BUSIF` outside `docs/debugging/` are the two fixed scripts themselves. |
| **STRAY-NEXTJOB** | **A reset that lands with bursts outstanding leaves `axi_rd_port` delivering the PREVIOUS job's beats as the NEXT job's, and this is now REPRODUCED rather than argued.** It is the open item in section 8 of `docs/debugging/2026-08-29_a7-dual-clock-run-gate.md`, which TRACK A7 raised and deliberately did not fix. MEASURED 2026-08-29 by TRACK STRAYROW (full write-up `docs/debugging/2026-08-29_strayrow-gate-row-and-three-handoffs.md`, control E) on the COMMITTED RTL with A7's `outst` clamp present, using `sim/tb_axi_rd_port_stray.vhd` with its `DRAIN_WAIT` cut from 200 to 4 core cycles: all three clock ratios report a value-oracle failure, `BEAT got 3133 want 5120` at `anear`, `got 3108 want 5120` at `aslow`, `got 3155 want 5120` at `afast` -- a beat from a burst issued BEFORE the reset, handed to the consumer as the new job's word 0. **The clamp does not touch this. It is a wrong-numbers failure, not a hang.** The mechanism is in `rtl/axi_rd_fsm.vhd`: after a reset `arv = '0'` and `outst = 0`, so a following `start` satisfies `S_DRAIN`'s exit condition immediately, the clear runs, and pre-reset beats then land in `S_RUN` and are written to the FIFO. On the FK33 the two reset nets genuinely differ (`core_aresetn` against the XDMA's `axi_aresetn`), so the slave keeping its queue across the port's reset is the SHIPPING case, not a bench contrivance. | **OPEN. It is a DESIGN DECISION, not a fix, and it is deliberately NOT taken by one track.** A7 section 6 sets out the fork: preserving `outst`/`arv` across `rst` so `S_DRAIN` waits for the strays is correct if the slave does NOT share the reset (the FK33 case) and HANGS if it does (the case `sim/tb_axi_rd_port_dual.vhd`'s J7 models). **Nothing says the card computed anything wrong**: it needs a reset mid-job followed by a restart inside the drain window, and the shipping flow has not been shown to produce one. The gate row is parked on the safe side at `DRAIN_WAIT = 200` so it goes in GREEN; the oracle that catches this is already in the file, so whoever takes the decision shrinks one constant and has the check. `rtl/**` was outside TRACK STRAYROW's ownership. |

### OI-3b, raised by TRACK C-SEAM 2026-08-29 -- the purest instance yet

**`sim/tb_llama_top_seq.vhd` PASSES with defect C1 fully restored** (299 s,
`OVERALL PASS 1 FAIL 0`). As a negative control -- because a PASS is otherwise
indistinguishable from a mutant that never reached the checker -- `v_ref` was
collapsed to a SINGLE register shared across every layer AND every KV head,
strictly worse than C1. **It PASSES again** (319 s).

Cause: the `R_X` landmark is `report`ed, never `assert`ed. Its actual gate is
self-consistency across KV read latencies, and **a deterministic defect is
consistent with itself.** The bench's own header already said "still PASS"
before and after C1's fix; the same fact sat in the file, unread as a gap.

MEASURED by the dispatcher, and stronger than reported: four of the six
`tb_llama_top*` benches carry NO assert at all, and `_seq` carries neither
assert nor report.

    tb_llama_top       45 asserts    tb_llama_top_seq        0
    tb_llama_top_smp   16 asserts    tb_llama_top_real       0
                                     tb_llama_top_normw      0
                                     tb_llama_top_smp_beh    0

**That is a lead, NOT a verdict**, and the distinction must be kept: `regress.sh`
judges rows TEXTUALLY via `FAIL_RE`/`PASS_RE` (`:1207`), so a bench with zero
asserts can still fail correctly by PRINTING `MISMATCH`, and one with many
asserts can still be decoration if they do not cover the value. C-SEAM's
empirical negative control is the real evidence. **TRACK OI3B owns this.**

Generalisation from C-SEAM, worth keeping: interleaving the layers is necessary
and nowhere near sufficient. Only schedule **plus an independent value oracle at
the output** kills the mutant.

### The BACKLOG table is not being maintained

Three landed rows were found still open today (1, 12, and OI-4), and one of them
caused a track to be dispatched onto finished work. The In flight section has a
rule about exactly this and the BACKLOG table has none. **Strike a row in the
same action that lands it.**

### TRACK REALSHAPE, 2026-08-29: the real shape has never elaborated, and it is the DEFAULT

`ghdl -r llama_top` with **no generic overrides** dies: 24.9 GB, 18.2 s,
`STORAGE_ERROR : grt-table.adb:58`. VERIFIED INDEPENDENTLY by the dispatcher:
`mk_shape(MODEL, NCARDS)` occurs **exactly once in the whole VHDL tree**, at
`rtl/llama_top.vhd:168`, as `llama_top`'s OWN DEFAULT, commented "Defaults to
the real build target. A simulation passes `mk_shape_scaled(...)`."

**So the never-elaborated configuration is the top level's default -- the one
synthesis gets if nobody overrides it.** Every simulation ever run has passed
the scaled shape instead.

The wall is not a subsystem. `gdn_block` standalone at the exact 9B generics
takes 0.35 s / 299 MB. It is one declaration: `rtl/llama_top.vhd:2731-2733`
models B's per-layer recurrent state as a **signal** array of 201,326,592 bits.
MEASURED ~228 bytes per GHDL scalar signal, so DERIVED **~46 GB**. The same
bits as a process variable measured **206 MB / 0.17 s**.

Six defects, five invisible at `mk_shape_scaled`. The sharpest is **R4**:
`attn_kv_axi:455`'s guard `NBLK <= 16` is UNREACHABLE at the shipping
`HEAD_DIM 256`, so the illegal value prints `overflow detected` with no line
number, and at `HEAD_DIM 32/64` the same value prints the named assert. It also
makes `llama_top:3650`'s mirror guard dead. **Zero margin, hit exactly by the
shipping geometry, and one step past it the diagnostic vanishes.**

`VN_W` 14 gives only 1.33x at 9B and **fails outright at 27B** (`ffn` 17408),
which matters for the stated end goal.

**The prize:** with `stmem` shrunk in a throwaway probe, the FULL composition
including real B elaborates in **2.09 GB / 1.93 s**, so a real-shape
elaboration gate row is affordable. TRACK REALFIX is going for it.

### Raised by TRACK D-PROG, 2026-08-29 -- the most serious of the day

**Every check on the layer program was an agreement check against the schedule
itself.** Two were further transcriptions of it (`seq_tbl_pkg`,
`llama_sched_pkg`), one asked only whether a descriptor is well FORMED (the
gateware has no idea which tensor a job should have used), and the fourth
diffed a run against a run driven by the second. That column is jointly
compatible with a program that is internally perfect and computes the wrong
model, and the earlier write-up said so itself.

`tools/dprog_oracle.py` is the first check that is not: it decodes the EMITTED
BYTES against artefacts from other sources -- llama.cpp's execution order via
`tools/ref9b/seam_map.py`, the packed `manifest.json`, and decisively each
`.mv4i` file's own 4 KB header, whose sub-region offset table at `0x38` pins
every weight base exactly. On the generated program: **39,330 checks, 0 FAIL**,
whole token, 505 steps. Teeth: 25 of 27 mutations killed, including **all six
that the earlier table recorded as RTL-silent**.

**Then the same oracle was run against `--stamp sched`, byte-identical to
`sim/llama_sched_pkg.vhd`, the table `llama_top` actually executes: 2,401
FAILS.** 311 `w_exp`, 253 `out_shift`, and `nsub_w = 29` on every step, which
the FK33's A wrapper refuses with `ERR_GEOM`. Byte-identity against a walker
test proves the step SEQUENCE agrees and says nothing about the numbers a real
run needs. **TRACK SCHED-FIX confirmed the numbers and CORRECTED the framing (`78e2f5a`).**
It reproduced the dump independently, without D-PROG's tool, and byte-compared:
0 mismatches of 4,040 words, so the transcription is faithful.

**But the 2,401 is three different things and only one is a defect, and the
headline was wrong in a way that matters.** `sim/llama_sched_pkg.vhd` is NOT
"the table `llama_top` actually executes" in any shipping sense: it is
`sim/`-only, consumed solely by `sim/tb_llama_top.vhd:484`, and in no synthesis
flow. VERIFIED INDEPENDENTLY by the dispatcher: `llama_top` appears nowhere
under `hw/`, and `hw/fk33/rtl/fk33_engine.vhd` wraps `matvec_int4_desc_axi`,
i.e. **subsystem A only, no D on the card today.** That is not a quibble that
shrinks the finding; it is WHY the finding was invisible.

**The real defect, fixed:** `nsub_w`/`nsub_s` were 29/4, the superseded
`ROWS_IF=58` budget, carried in under comments claiming they were "the real
ones". Right values 24/3, confirmed from an artefact no generator wrote: every
packed `.mv4i` header's own bytes (`nports_w` at `0x1A`, `n_scale_sub` at
`0x34`). All 311 A jobs would have been refused before `start` with `EC_GEOM`
(NOT `ERR_GEOM`, which does not exist) and a polling driver would hang.

**Seven independent reasons it went unnoticed**, the last being the one to
generalise: `seq_desc_fetch` only range-checks against `NSUB_MAX=64`; the base
array is not fetched yet; `llama_top:2280` binds `matvec_int4`, which has no
descriptor plane, so no `tb_llama_top*` row can contain an `EC_GEOM` check;
`tb_a_geom` restated the constants itself; `check_a_geometry.py` covered two of
four numbers; no D on the card; and **the two generators agreed with each
other.** Producer-versus-producer agreement is not evidence.

**Deliberately NOT "fixed": `w_exp`/`out_shift`.** `llama_sched_pkg` emits at an
arbitrary shape with no tensor to take a value from, and the ranges are
measured constraints. The 1,157 residual failures are the CORRECT result and
are now asserted to stay.

**OI-4 is STALE at HEAD and should be closed.** `tools/gen_layer_program.py`
(1,015 lines) landed at `a2b20f3`: job sequencing, region routing and the D
fields A does not read all exist. Backlog 6's items 1 to 3 were already done.

Two corrections worth carrying: **`token_embd.weight` needs ZERO descriptor
jobs, not 15** (host-side gather into `R_X`; the 505-step program contains no A
job on it), and "one matvec job is emitted" understates it by 310 -- **311 are
emitted and all pass**. `output.weight`'s 15 windows are confirmed.

**Trap to propagate:** `gen_layer_program.py` defaults to the PRE-QKV-PAD packed
set, where 48 of 311 A jobs are refused. **Always pass `--manifest`.**

**OI-9 preference, asked for and NOW ACTED ON:** subdivide via `ERR_INFO`. It
already carries a word index, so it costs neither a format change nor a
reserved D value. **Oren chose exactly this on 2026-08-29.** D-PROG's preference
was recorded and then sat unasked for a day, which is the deferral-becomes-a-
decision failure mode this board has its own section about.

### Raised by TRACK DESC-MUT, 2026-08-29

* **Two weakening mutations are stopped only by a declared VHDL integer range.**
  `S5` and `F3` accept a descriptor that should be refused, and the only thing
  preventing it is a range declaration, **which is a bit width in synthesis and
  not a check**. So they are caught in simulation and would NOT be caught on the
  card. Recorded as ABORT rather than counted as kills, which is the honest
  reading. No owner.
* **`EC_CORE` (0xE) is reachable by no bench in the tree.** Mutation `R1` deletes
  the `core_err -> EC_CORE` path and survives both judges. Closing it needs a
  stimulus no bench currently produces.
* **"Refused for the right reason" is recoverable for only 6 of 9 error codes**,
  and this is now MEASURED rather than suspected. `EC_DESC` (0x3) is raised at
  nine sites with two confirmed collisions even with `ERR_INFO` pinned. Not
  fixable by renumbering: `EC_SHAPE` took the last 4-bit value, which is OI-9,
  and `ERR_INFO` is a word index by construction.
* **Subsystem A coverage gaps:** `rtl/matvec_int4.vhd` and `rtl/axi_rd_port.vhd`
  have no mutation script; `USE_XEXP_PORT=true` appears in NO bench at all; and
  `DUAL_CLK=true` is a manual run, so the descriptor-path CDC, whose absence
  once broke 17 of 22 cases, has no automatic coverage.

### Two blind spots recorded, with no owner

* **Gray coding has no automated defence, and TRACK BOARDAUDIT narrowed that to exactly one class.** TRACK CDC-STATIC landed real machinery (`sim/cdc_teeth.sh`, `sim/mutate_async_fifo.sh` class GRAY `G1`..`G6`, `docs/debugging/2026-08-29_cdc-static-analysis.md`, `be982b3`) and it closes two of three classes: the encoder/decoder MISMATCH (`G2`) is killed by simulation, and the 2FF-vs-1FF MTBF class (`G3`/`G4`/`C6`) by `report_cdc`. **What remains undefended is `G1` alone: both gray functions replaced by identity, consistently.** It is worse than uncaught -- the binary-pointer design reports TWO FEWER `report_cdc` warnings than the correct one, so any "the report must not get worse" rule PASSES it. Vivado classifies by width, depth, ASYNC_REG and fan-in and never inspects an encoding. Simulation and static analysis are complementary on topology and **both blind to the encoding.** The CDC-STATIC write-up says this about itself in its own section 7; backlog row N10.
* **`K2b`, a standing hazard, not a task.** `P_CB_CHK`'s idle invariant watches `cbw_v(0)`, the command REGISTER, not the write. Any future change that deepens the codebook command path makes the invariant vacuous with nothing in the tree noticing. Lever C is no longer being taken (the shell routes without it), but the hazard is not specific to lever C.

## Decisions taken, with their triggers

**Why this section exists.** An independent review on 2026-08-29 named
"decisions deferred so long they have quietly become decisions" as a failure
mode of this project. A deferral with no recorded trigger is indistinguishable
from having forgotten. Each row below says what was decided, by whom, on what
evidence, and **what event should reopen it**.

| decision | by | on what evidence | trigger to revisit |
|---|---|---|---|
| ~~**Congestion fallback is lever C (IQ4_NL codebook to LUTRAM)**, pre-authorised.~~ **TRIGGER FIRED, DECISION CLOSED AS NOT NEEDED.** | Oren, 2026-08-29; closed by TRACK BOARDAUDIT 2026-08-29 | CONGEST measured the codebook at 86,992 primitives, 39.5% of `matvec_core`, and 97.7%/98.8% of the design's MUXF7/MUXF8. ~7.1x win, zero throughput cost. Risk is a 32x write-coherency surface. | **The stated trigger was "if TRACK PBLOCK routes the design, the fallback is not needed", and PBLOCK routed it at `ed1ffe2`** (0 nets with routing errors, 288,506 fully routed). Lever C was not taken and its 32x write-coherency surface was never opened. The row stayed live for a day after the event that retired it. Reopen only if a LATER build fails to route; the pre-authorisation stands, and the standing condition still holds -- **if lever C is ever taken, its oracle work is dispatched ALONGSIDE, not after.** Note `K2b` in the blind-spot list is a hazard in this same code and is NOT specific to lever C, so it does not close with this row. |

### LEVER C REOPENED 2026-08-30 -- its own stated trigger has fired

The row says **"Reopen only if a LATER build fails to route; the
pre-authorisation stands."** A later build is failing to route. No new decision
from Oren is needed; this records that the condition was met.

**The closure reasoning was evaluated against the wrong design, and that is
worth naming as a defect in the decision log rather than in the RTL.** The
stated trigger was "if TRACK PBLOCK routes the design, the fallback is not
needed", and PBLOCK routed `ed1ffe2` cleanly. But **PBLOCK routed the
subsystem-A-only shell.** The design that has to fit is A+B+C+D, which did not
exist in routable form on 2026-08-29. A trigger discharged against a smaller
design than the one it was protecting is the same shape as the guards-that-pass-
for-the-wrong-reason class in CLAUDE.md.

**MEASURED by TRACK TIMING, 2026-08-30**, from COMPOSE4's surviving placed
checkpoint plus its own runs:

- Placed CLB occupancy **54,866 of 54,960 = 99.83%**, congestion level 7.
- **33,767 failing endpoints after placement**, not the 256 the post-synthesis
  report shows. Of the 20,000 worst, **20,000 of 20,000 are net-dominated**:
  mean net delay **4.575 ns** against mean logic delay **0.670 ns**.
- Attribution control: **subsystem A alone fails 3,779 endpoints** while being
  byte-for-byte the entity that closes 200 MHz on the card today. It cannot
  have acquired a logic problem by being placed beside B, C and D.
- WNS after `phys_opt_design` **-2.834 ns** (from -3.056).

**The fit arithmetic, which is the real answer to N3:**

```
composed 346,971 + shell 40,326 + norm image 32,943 = 420,240 LUT
raw LUT:  420,240 / 439,680 = 95.6%          <- looks survivable, and is not the constraint
at the MEASURED 6.32 LUT/CLB -> 66,494 CLB of 54,960 = 121%
at 7.0                        -> 60,034 CLB           = 109%
at an unreachable 8.0         -> 52,530 CLB           =  96%
```

**The binding constraint is CLB packing density, not LUT count.** That is
exactly why lever C is more valuable than its LUT saving suggests: CONGEST
MEASURED the codebook at 86,992 primitives, 39.5% of `matvec_core`, and
**97.7% / 98.8% of the whole design's MUXF7 / MUXF8**. MUXF7/F8 pin LUTs into
specific CLB slots, so removing them attacks the 6.32 directly. **Do not
justify lever C on its ~7.1x LUT win alone; the packing effect is the point and
it has not been measured.**

**CORRECTION 2026-08-30, from TRACK LEVERC (`845ea28`): the MUXF7/F8 figures
above are the A-ONLY SHELL build's, and this block applied them to the COMPOSED
fit. That is the same defect this block was written to record, committed inside
it.**

MEASURED in the composed A+B+C+D, from TRACK TIMING's own `TT_MUX` census: the
codebook is **37.7% of MUXF7 (24,576 / 65,108) and 47.6% of MUXF8
(12,288 / 25,788)** -- not 97.7% / 98.8%. `d_norm/gvr.u_rms` alone carries
17,696 F7 and 8,736 F8, and `c_attn/u_arr` another 15,796 F7. **Attribution corrected the same day:** I wrote here that TIMING had made the
same substitution in its section 7a. **It had not, and that accusation is
withdrawn.** TIMING applied 97.7% / 98.8% to `a_eng`'s OWN census, explicitly
labelled as such, giving 24,297 MUXF7 against LEVERC's structural
**24,576 = 1536 x 16** -- 1.1% agreement, and as a share of the composed design
its figure reads 37.3% / 47.5%, the same quantity. **The substitution was mine
alone.** I inferred a second instance from a superficial reading and published
it as a finding about another track's work.

**A second correction, which reverses the sign of the argument.** This block
said removing MUXF7/F8 "attacks the 6.32 directly" because they pin LUTs into
CLB slots. LEVERC's arithmetic says the premise is backwards: **a MUXF8 shape
occupies 4 LUT6 in one CLB half and wastes none of them, so a paired mux region
sits at exactly 8.00 LUT/CLB -- the device maximum.** The codebook mux is the
DENSEST structure in the design, not the loosest, and removing it LOWERS the
average density. An indivisible shape costs the placer freedom, not LUT sites.

Bounded rather than point-estimated, since the non-mux logic also cannot exceed
8 LUT/CLB (which refutes the fully-unpaired extreme by arithmetic):

```
mux-region density        4.69 .. 8.00 LUT/CLB
CLB saving from lever C   3,072 .. 8,946
overshoot (11,534 CLB)    27% .. 78% closed
post-lever-C occupancy    104.7% .. 115.4%
density moves             6.05 (down) .. 6.66 (up)   from 6.324
```

**Lever C alone does not close the fit under either bound.** That agrees with
TIMING's conclusion while removing the reasoning both of us used to reach it.

**`K2b` is CLOSED** by the same track, independently of whether lever C ships.
`P_CB_CHK` watched the command register; re-aiming it at "the last stage" does
not fix it, because the next change moves past that too. The new `P_CB_MODEL`
watches no register at all: it rebuilds the write path from the entity's ports,
delays it by a declared `CB_WR_LAT`, and requires `cb` to equal it every copy
every cycle. **Its attribution control denied credit for thirteen of fifteen
apparent detections** -- without it the table would have claimed fifteen where
two are real.

Standing condition carried forward from the original row and still binding:
**if lever C is taken, its oracle work is dispatched ALONGSIDE, not after.**
Its known risk is a 32x write-coherency surface. `K2b` remains a standing
hazard in this same code and is not specific to lever C.
| **Tandem PCIe, ALL OF IT: deferred until 9B inference works on the card.** Not just the Field Updates hierarchy question -- the whole subject, including MCAP and ICAP. Do NOT restructure the shell for it, and do NOT spend a slot on it. | Oren, 2026-08-29 (superseding his earlier 'decide after it routes') | The earlier deferral was already the right call on TANDEM's own evidence (`abbd2ed`): its stage-1 pblock excludes `SLICE_X216Y0:SLICE_X232Y239` at DRC severity **Error**, **50,135 placed cells sit inside it**, and there is nothing to the right of `SLICE_X232` so every one of them moves LEFT into the half that already fails to route. Oren has now widened it: a bitstream-reload path is worth nothing until there is a bitstream worth reloading. | **9B inference running on the card.** Not 'the design routes' -- routing is necessary and nowhere near sufficient. Until then the standing procedure is the warm JTAG configure into a live root port plus `echo 1 > /sys/bus/pci/rescan`, which WORKS and is documented in `docs/debugging/2026-08-28_fk33-first-light.md`. **Nobody should re-litigate the reload path before then.** Accepted costs, both real: retrofitting the three-partition hierarchy later is the expensive path, and the card still cannot configure itself at power-on. |
| **Logits egress is the full writeback, NOT on-card top-k.** Not a judgement call in the end. | evidence, confirmed by dispatcher 2026-08-29 | EGRESS measured writeback at 124 us, **0.32% of the 38.27 ms budget** and 32x oversupplied vs the 300 MB/s A can produce logits at, on two already-reserved idle pseudo-channels. The fabric direction is INVERTED from the intuition: top-k's logic lands inside `matvec_core`, which is 72-81% of every level-6/7 congestion window, while the writeback lands at the die edge. Top-k also loses repetition/frequency penalties, `logit_bias` outside k, speculative verification, and the oracle at the seam that decides a token, and makes `top_p` an approximation whose error the host CANNOT DETECT. | If the writeback is ever measured to add materially to `matvec_core`'s congestion. Two unexplored options are recorded in `docs/debugging/2026-08-29_logits-egress.md`: top-k plus the exact normaliser, and C2H from the existing 43-BRAM36 result buffer. |
| **Card 2's factory flash: DUMP IT, and this is NOT a Tandem question.** It was previously bundled into the Tandem trigger and should not have been. | dispatcher, 2026-08-29 | Card 1's SQRL factory image was **destroyed** by an agent crossing the hardware boundary. Card 2's copy is the ONLY surviving one and is card 1's restore path. That value is independent of Tandem, of routing, and of inference. `hw/fk33/flash.sh` already has a readback mode; it writes nothing, but note its own warning that **readback IS itself a JTAG configuration**, so the card stops running the factory image until a power cycle. Check VCCINT is above the 0.698 V floor first, and treat an all-0xFF or all-0x00 readback as a **failed read that looks like a backup**. | **DONE 2026-08-29, and this row did not say so.** `docs/debugging/2026-08-29_second-fk33-verify-and-flash-backup.md`: card 2 self-configured from its own SPI flash (`CFG_DONE 1`, every BOOT_STATUS error bit clear) and the flash was read out to `hw/fk33/bit/fk33_factory_backup_153300001366.{bin,mcs}`. **Teeth on the readback: it was read TWICE and the two reads are md5-identical (`dcb97432538b9c7d2855b1d9c93658f7`)**, which is the check that separates a real backup from an all-0xFF read that looks like one. Two findings came free: **the SQRL factory image does NOT raise VCCINT** (card 2 measured 0.677 V running it, never observable before because card 1's image was destroyed), and `jtag.sh` was resetting the WRONG CARD's FTDI regardless of `FK33_TARGET`, now fixed. **What is NOT done: the backup has no off-disk copy.** It is untracked in git and sits only on a root filesystem at 91%. That is backlog row N9 and it is trivial. |
| **OI-9, the full descriptor error-code space: SUBDIVIDE VIA `ERR_INFO`.** Not widening the code field, and not raiding a value reserved for subsystem D. | Oren, 2026-08-29 | It keeps the descriptor's byte layout UNCHANGED, so nothing already byte-pinned in `docs/2026-08-28_matvec-descriptor-format.md` moves -- and that format is the one artefact subsystem A, subsystem D and the host builder all read, and the one that has already been verified. `ERR_INFO` already carries a word index, so the sub-case rides in a field that exists. Accepted costs, both real: **`ERR_INFO` stops being free for anything else**, and the host decoder gains a second lookup. | `ERR_INFO` being needed for a second purpose, or the sub-case count outgrowing that field too. **This is no longer a decision and backlog row 10 is struck**; it becomes a dispatchable implementation item owning `rtl/matvec_int4_desc_pkg.vhd`, `rtl/matvec_int4_desc_axi.vhd`, the host decoder in `server/pl_backend.c` and `sim/tb_matvec_fk33_desc.vhd`. |
| **B-CONV-HIST: CLOSED AS WON'T-FIX.** `B_SRC_REAL` is not wanted, so the causal conv does not get a real history and the `(KCONV-1) x qkv_dim` buffer is not built. | Oren, 2026-08-29 | `B_SRC_REAL` is **already unrunnable for a separate `R_ALPHA` reason**, recorded in `rtl/llama_top.vhd`'s own header: with it TRUE the degenerate-residual count RISES, 0/3/10/23 -> 3/5/11/24 at 4/8/16/32 blocks, because A's synthetic weights make `R_ALPHA`'s VALUES physically impossible and `gdn_scalar`'s gate saturates shut. So nothing regresses by leaving this. The buffer BTOP1 refused would have been an ESTIMATE ~90 MB of GHDL signal at the 9B shape, in the file TRACK REALFIX had just fought a 46 GB signal down to make elaborate at all. | **THE TWO REFUSALS ARE THE GUARD AND MUST NOT BE REMOVED AS DEAD CODE BY A LATER CLEANUP.** `S_GO` asserts and `tools/gdn_oracle.py` raises, independently, on the zero-mantissa-at-a-real-exponent value; that is why this closes as won't-fix rather than as a latent defect. Deleting either refusal because "`B_SRC_REAL` is never true" is precisely how a won't-fix becomes a silent defect. **Reopen only if `B_SRC_REAL` is wanted, and note that is TWO problems, not one: `R_ALPHA` has to be fixed first.** |
| **Hardware, overnight 2026-08-29: OREN PERSONALLY may JTAG-configure card 1 and run host-side tests.** | Oren, 2026-08-29 | Backlog row N1 cannot be answered without it: the bitstream is loaded, the weights are resident, and no arithmetic has ever been checked on this silicon. | **THIS CHANGES NOTHING FOR AGENTS. The no-hardware rule for every track is absolute and unchanged.** Scope, and it is narrow: JTAG configure of **card 1** and host-side tests, by Oren, **scoped to the night of 2026-08-29 and not a permanent grant**. NOT authorised, by anyone: any VCCINT change (stay at wiper 68, ~0.717 V), any flash write, anything touching **card 2**, and any subagent doing any of it for any reason. Card 2's factory image is the only surviving SQRL factory image in existence and is card 1's restore path. |
| **`C_MAXPOS` = 131,072 for the 9B bitstream**, not the 233,396 the resized arenas allow. | Oren, 2026-08-29 | KVSIZE's resize took the arenas from 61,229 to 233,396 tokens, so both values fit and the choice was never a derivation -- TRACK CGENERICS said so explicitly and set neither. 131,072 is Qwen3.5-9B's own native context; everything past it depends on RoPE extension work that does not exist, so the extra 102,324 tokens would be capacity the weights cannot use. Costs ~44% of the arena as headroom. | RoPE scaling landing, or an arena needing the space back. Note `C_KV_ADDR_W = 33` is NOT freed by this: CGENERICS measured it exact with **zero slack** at the chunk-domain sum, and only a value SMALLER than 131,072 would change it. |
| **Cross-stack read measurement on the card: NOT taken.** Needs hardware; raised with Oren and never confirmed. | pending | 12 of 27 masters read cross-stack; a stack offers at most 15 engine ports. | **PREMISE FALSIFIED 2026-08-29 by TRACK BOARDAUDIT.** The stated reason for deprioritising was "the design does not route, so there is no engine bitstream to measure with". **The design routes (`ed1ffe2`) and the engine bitstream has been loaded on card 1**, links Gen3 x4, and both HBM stacks round-trip through the host BAR at 0.51 GB/s write / 0.78 GB/s read. So the blocker is now only the hardware boundary and Oren's time, not the absence of a bitstream. It is still not urgent -- it should follow N1, because measuring the bandwidth of an engine that has never been shown to compute anything is the wrong order. |


## Open issues

### OI-1: RESOLVED 2026-08-28 -- descriptor in memory

A is bit-exact at the FK33 geometry and the HBM can serve its 27 masters
(30 already measured at 288.0 GB/s, 100% of ceiling). Three things stand
between that and arithmetic on silicon, and the first is a decision:

1. **The register map.** `rtl/matvec_int4_axi.vhd:252,265` asserts
   `NPORTS_W=4 / NPORTS_S=1` and holds four `W_BASE`/`W_BASE_HI` pairs plus one
   `S_BASE` pair. FK33 needs 24+3. Its own header argues the map must NOT grow
   with a generic, on the grounds that it would be "a map no driver could
   parse". So this is a fork, not an edit.
2. **The HBM-to-core CDC does not exist.** `weight_streamer` is single-clock.
   At ACLK = f_core the duty is exactly 100% with zero margin, so the CDC is
   mandatory.
3. **`axi_rd_port`'s `MAXOUT` defaults to 2** (32 outstanding beats); the
   measured 288 GB/s run used 16.

Items 2 and 3 are determined work. **Item 1 was Oren's call and is now
answered: descriptor in memory.** All three landed 2026-08-28 as TRACK A-CTRL
above. This issue is closed; the record is kept because the rejected options
and their costs are the part worth re-reading.

**Two gaps opened by that work, both MEASURED by
`sim/tb_matvec_fk33_desc.vhd`'s mutation table, both deliberately NOT closed:**

- **A well-formed base pointing at the WRONG sub-region is undetectable.**
  Case 19 aims weight sub-region 7's base at sub-region 8's bytes. The design
  accepts, computes and reports success, and 4 of 100 result elements are wrong
  -- exactly the two rows that bit slice 7 carries, in each of the two live
  tiles. Nothing in the descriptor says what a sub-region should CONTAIN, so
  only the weight store's own hash can catch this. Same family as OI-3.
- **A `w_beats` that is too small HANGS.** Case 20 halves it; the array starves
  and the job never completes and never errors, because `WDOG_LIMIT` covers the
  descriptor FETCH only. Not a wrong answer, but a driver polling for
  `done or err` waits forever. Closing it needs a compute-phase watchdog whose
  limit is a per-geometry number, which is a decision rather than an
  implementation, so it was left for Oren.

### OI-2: `attn_emit.vhd:400` is a bound violation at `NGRP = 1` (latent)

**RESOLVED at HEAD, 2026-08-29.** `rtl/attn_emit.vhd` no longer assigns
`grp <= 1` anywhere; `:410` is now a comment documenting the old defect, and
the `NGRP = 1` case takes an explicit `grp <= 0; state <= S_SHIFTS`. VERIFIED
by reading the file at HEAD, not by trusting this entry. The description below
is kept for the record and is no longer the state of the tree.


`grp` is declared `integer range 0 to NGRP-1` (`:263`) and line 400 assigns
`grp <= 1` unconditionally. `NGRP` is `positive`, so `NGRP = 1` (one KV head)
is a legal generic value that is an immediate bound violation. Default is 2,
so nothing hits it today. Found by the integration track, verified directly,
deliberately not fixed.

### OI-3: the bench cannot see two classes of defect

Of nine mutations on the integration bench, **two pass while broken**: an
exponent claim re-aimed at R_X, and the prefetch consuming at k-3. Both change
every element and no property in the bench can observe either. Fourth and fifth
instance of the same family. This is the honest ceiling on what `tb_llama_top`
proves, and it is not closed by any track above.

**UPDATE 2026-08-29, TRACK BOARDAUDIT. Probably closed, and NOT MEASURED, which
is the whole point of saying so.** TRACK OI3B (`5578132`) gave the family a real
value gate: `sim/tb_llama_top.vhd`'s `P14` fires when
`results(0)(NTOK-1)(0) /= L_X0`, with `L_X0` pinned in `sim/tb_llama_top_real.vhd`.
The two defects OI-3 names are `rtl/llama_top.vhd`'s
`c_exp_region <= to_unsigned(R_VIN, 8)` and `if k >= 2 then qg_buf(k-2) <= el_rdata`,
both live in the config `tb_llama_top_real` exercises, and both move `R_X(0)`.
So the gate ought to kill them.

**But nothing has shown that it does.** MEASURED: no `sim/mutate_llama_top_*.sh`
row and no line of OI3B's own teeth table names either mutation; OI3B's teeth
were taken on defect C1, the `v_ref` collapse and the `gdn_silu` truncation.
**A gate that ought to catch a defect and has never been shown to is exactly the
class this project keeps being bitten by**, so this stays OPEN as backlog row N6
until two mutations have been run. It is cheap: two mutations, one bench.

### OI-5: RESOLVED 2026-08-28 (`c8a57d8`) -- the Python decoder was wrong on 243 ids

Found by TRACK TOK-C while verifying the C port, and deliberately NOT fixed
there. `tools/extract_tokenizer.py`'s `TOKEN_TYPE` table has `5: BYTE,
6: UNUSED`; llama.cpp has it the other way round (`5 = UNUSED`, `6 = BYTE`).
The 243 tokens with `token_type == 5` are ids 248,077..248,319, text
`[PAD248077]`..`[PAD248319]` -- vocabulary padding, not byte-map characters.
llama.cpp decodes them to the **empty string**;
`qwen35_tokenizer.py::piece_bytes` returns their literal text. MEASURED against
the oracle: 243 of 248,320 ids mismatch.

Unreachable from `encode`, so every corpus number in
`docs/debugging/2026-08-28_qwen35-tokenizer.md` stands. Reachable from a
sampler, so a server using the Python would emit text llama.cpp does not.
`server/qwen35_tok.c` is correct. The fix is one line in `piece_bytes` plus the
label swap in `extract_tokenizer.py`, but it needs a re-run of that file's
numbers, so it is an issue rather than a drive-by edit. This also withdraws
that file's claim that "13 byte-mapped characters carry NORMAL type": this
vocabulary has ZERO tokens of type BYTE. Write-up:
`docs/debugging/2026-08-28_qwen35-tokenizer-c.md` section 8.1.

**RESOLVED, `c8a57d8`.** The label swap and the decoder case are both fixed,
but the part worth keeping is the third change. **No corpus of any size could
ever have caught this**, because UNUSED tokens are unreachable from `encode`,
so the only ids the corpus can decode are the ids encoding produced. The
Python's verifier had no way to look anywhere else, which is why the C found it
and the Python did not, despite the Python having been checked over 53,411
strings AND a 1.1M-codepoint sweep. Coverage of the input space is not coverage
of the output space.

So `tools/verify_tokenizer.py` gained `--all-ids`, decoding every id in the
vocabulary one per string against the oracle -- the check the C's verifier had
and the Python's lacked. MEASURED after the fix: 248,320 ids, 0 mismatches,
corpus still 0/0. Teeth-checked by removing the fix again: 243 mismatches,
every one a `[PAD*]` token with `type=5`.

**Generalise this before the next tokenizer-shaped thing:** when a check is
driven by generated inputs, ask what part of the output space those inputs
cannot reach, and enumerate it separately.

### OI-7: `l2norm_rs` rejects a legal input, at `severity failure`

**RESOLVED at HEAD, 2026-08-29.** `rtl/l2norm_rs.vhd:256` now states the bound
INCLUSIVELY (`ssq <= shift_left(...)`), matching `:97`. Fixed by RANGE rather
than by widening `SSQ_BITS`, which would have admitted up to `2^38-1` and
thrown away half the overflow detection. VERIFIED at HEAD.


Found by TRACK B-ACCURACY and deliberately not fixed, because `l2norm_rs` sits
under `gdn_block` and `llama_top` as of `3246046`.

`rtl/l2norm_rs.vhd:97` states the bound INCLUSIVELY: `ssq <= N * 2^30`, i.e.
`2^37` at `N = 128`. `:245` asserts it STRICTLY: `ssq < 2^SSQ_BITS` with
`SSQ_BITS = 30 + LOG2N = 37` (`:128`). The vector `x[i] = -32768` for all `i`
is a legal int16 input whose `ssq` is exactly `128 * 2^30 = 2^37`, so the
maximum legal input trips the assert. MEASURED on untouched RTL:

    rtl/l2norm_rs.vhd:245: (assertion failure):
        l2norm_rs: ssq outside the u37 bound implied by N

`severity failure`, so it kills the run rather than saturating.

**Corroboration the finder did not cite:** `:90` calls this "the u38 bound",
and representing `2^37` inclusively does require 38 bits, while the constant
computes 37. The author's comment disagrees with the author's constant, which
is what an off-by-one looks like from the outside. Fix is `SSQ_BITS = 31 +
LOG2N`, or make the compare `<=`.

**Not determined: whether `ssq = 2^37` is reachable from `gdn_block`'s real
activations.** Spec 2.1.3's requantizer argues against it. That is an argument,
not a measurement, and the distinction is the whole issue: an unreachable
defect is a latent trap, a reachable one is a crash. `msb(ssq) = 37` is also
the single exponent the new 182-case sweep cannot reach, so adding it to the
vector set would turn the regression red, which is not the same thing as
reporting the defect. The generator carries it as a comment naming the
measurement.

### OI-8: `matvec_core` reads `ybuf` one past the end at the top of its row range

**RESOLVED at HEAD, 2026-08-29** (`7ccc239`). `rtl/matvec_core.vhd:928` reads
`ybuf(ybuf_addr(rd_t))` through the clamping function at `:128`, which bounds
the ADDRESS rather than gating the read, so the BRAM read port still infers.
The same buffer's WRITE side was a separate defect, OI-10, fixed at `:865`.
VERIFIED at HEAD.


Found by TRACK A-SHAPE while sweeping legal shapes, and not fixed because
`rtl/matvec_core.vhd` is not that track's file.

`ybuf` is declared `array(0 to TILES-1)` (`:191`), `rd_t` is an
**unconstrained** integer (`:389`) that `S_EMIT` advances to `tiles_r`
(`:883-884`), and `:835` reads `ybuf(rd_t)` **unconditionally every cycle**.
So whenever `ceil(n_rows / ROWS_IF) = TILES` -- that is, whenever `n_rows`
falls in the top `ROWS_IF` rows of the declared `MAXROWS_BFP` range -- the last
emit cycle indexes one past the array. Verified here by inspection of all three
lines.

MEASURED by the finder at `MAXROWS_BFP=192 / ROWS_IF=48`: `n_rows = 145` and
`n_rows = 192` each abort with
`index (4) out of bounds (0 to 3) at rtl/matvec_core.vhd:835`.

**Synthesis-benign, simulation-fatal**, the same shape as OI-7: `rd_v` is `'0'`
that cycle so nothing consumes `ybuf_q`, but GHDL kills the run. **It bites
hardest for exactly the build you would want to ship**: one that sets
`MAXROWS_BFP` to the precise `n_rows` it needs in order to save BRAM, because
then every job trips it.

Consequence for the shape check that found it: A-SHAPE's sweep deliberately
stays below the trap, so **the top corner of the row range is unverified**, and
that is precisely where an off-by-one in `tiles` would show. Closing OI-8
unblocks that verification too.

### OI-10: RESOLVED 2026-08-29 (`0ff6828`) -- `matvec_core` wrote `ybuf` past the end in raw mode

Filed by TRACK RANGE, reproduced and fixed by TRACK OUTMODE. Write-up:
`docs/debugging/2026-08-29_out_mode-raw-oracle-and-oi10.md`.

Reproduced exactly as filed. `ybuf(re2_t)` was written whenever `out_mode /=
"10"`, while `S_IDLE` bounds `n_rows` against `MAXROWS_BFP` only when
`out_mode = "00"` -- and spec 7.6 makes `n_rows > MAXROWS_BFP` **legal** in raw
("in raw mode `M` may exceed `MAXROWS_BFP`", `lm_head` being the caller).
MEASURED at `MAXROWS_BFP = 64 / ROWS_IF = 4`, `out_mode = "01"`, `n_rows = 65`:
`index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:839`, with the SAME
65 rows in partial mode passing in the pass immediately before it.

**Two corrections to the filing, both worth carrying.**

1. **It is NOT reachable "on exactly the argument that produced OI-8".** That
   argument is `n_rows` in the top `ROWS_IF` rows *of* the range, and raw mode
   at exactly `MAXROWS_BFP` passes on unfixed RTL (measured). The write pointer
   stops at `tiles - 1`; only OI-8's read pointer runs one past. OI-10 needs
   `n_rows` **above** the range. Do not look for it at the top corner.
2. **`out_mode = "10"` was NOT unexercised.** `sim/tb_matvec_core` PASS 2 has
   been running partial and comparing `y_data` against the reference's `ACC`
   line all along. `out_mode = "01"` was driven, too, by
   `sim/tb_matvec_cb_lockstep` -- but that bench compares four runs **against
   each other** at one tile and never against `ref/matvec_int4.c`, so raw had
   no oracle. "Never run" was wrong; "never checked against the reference" was
   right, and it is the half that mattered.

Fixed by narrowing the write ENABLE to `out_mode = "00"`, not by clamping the
address as OI-8 did: OI-8 clamped because that access is a READ that must stay
unconditional to infer the BRAM read port, while this is a WRITE whose
condition already IS the write enable. `ybuf` is the BFP output buffer and
nothing else, so the raw write was dead as well as out of range.

`sim/tb_matvec_core` now drives all three modes against the reference and needed
no new vector -- `ref/matvec_int4.c` already writes the `YDATA` line and that IS
the raw payload; the loader was dropping it. 343 output values compared, up from
24. Six mutations; the one that does NOT bite is the alternative address-clamp
fix, which is the bench's permanent resolution floor here because nothing reads
`ybuf` in raw mode at all.

### OI-11: WITHDRAWN for the FK33 arm, RESOLVED 2026-08-29 for the AXU3EG arm

Filed by TRACK RANGE against `sim/tb_matvec_fk33_desc.vhd`; examined by TRACK
OUTMODE.

**The FK33 arm does not have this defect and did not have it when the issue was
written.** Its `k = 0` branch is `if st(2) = '1' ... elsif st(0) /= '1' then
"is LEGAL and never completed (timeout N)"`, so a hang exits the bounded poll
with both bits clear and is scored as a failure. `git log -S"is LEGAL and never
completed"` puts that line in `f693faf`, which predates `7ccc239`, the commit
under which OI-11 was filed. Withdrawn for that arm.

**The gap is real on the AXU3EG arm**, which the filing did not name. That arm
ties off the weight masters, so an accepted descriptor can never complete by
construction and there is no `done` to poll; its verdict was `err` alone after a
fixed window. A design that silently did nothing -- never started, never errored
-- scored as an acceptance.

Closed by requiring the accepted descriptor to be RUNNING: STATUS bit 1 (`busy`)
set and bit 0 (`done`) clear after the window. That is the only completion-class
statement available where completion cannot happen. TEETH, MEASURED: an RTL
mutant that never raises `busy` on the accepted path passes the ENTIRE bench at
HEAD -- both shape sweeps, all 22 cases, `GHDL_EXIT=0` -- and fails 9 of 9 legal
AXU3EG shapes with the check in place. Nothing else in the tree saw it.

### OI-9: DECIDED 2026-08-29 -- the error-code space is full, and it gets subdivided

**Oren's decision, 2026-08-29: SUBDIVIDE VIA `ERR_INFO`.** Not widening the
4-bit field, and not raiding a value reserved for subsystem D. The reason is
that it leaves the descriptor's byte layout UNCHANGED, and that layout is the
one artefact A, D and the host builder all read and the one already verified.
Accepted cost: `ERR_INFO` stops being free for anything else, and the host
decoder gains a second lookup. Implementation is backlog row N12, and it must
carry DESC-MUT's measurement that **`EC_DESC` (0x3) is raised at NINE sites with
two confirmed collisions even with `ERR_INFO` pinned** -- subdividing `EC_DESC`
is the first thing this route buys. The statement of the problem follows and is
unchanged.

`EC_SHAPE = 0xF` (`rtl/matvec_int4_desc_pkg.vhd:52-57`) took the last free
value. `0x0, 0x3, 0x4, 0x9..0xE` were already taken and `0x1, 0x2, 0x5..0x8`
stay reserved for subsystem D, whose header this format shares verbatim. The
field is 4 bits and it is now full.

Not urgent, and deliberately not pre-solved: the next error condition anyone
wants to report has nowhere to go, and the options (widen the field, subdivide
a code using `ERR_INFO`, or take a reserved D value) all have consequences for
D. Whoever needs the next code decides. Recorded now so that decision is not
discovered at the worst moment. **Superseded by the decision above.**

### OI-6: llama.cpp aborts on some malformed UTF-8 (upstream, informational)

`unicode_cpt_from_utf8` masks a 4-byte UTF-8 lead with `0x07` and applies no
upper bound, so the bytes `F4 BF BF BF` decode to U+13FFFF;
`unicode_cpt_to_utf8` then throws `std::invalid_argument` and nothing between
there and `llama_tokenize` catches it. The process dies with SIGABRT.
Reproduced against `llama.cpp.upstream@1692f9e5`. Only reachable from a host
that feeds raw bytes; a JSON parser rejects them first. Recorded so nobody
re-derives it while fuzzing, and because it is why the byte fuzz excludes lead
bytes `0xF0..0xFF` -- there is no oracle answer to compare against.

### OI-12: RESOLVED 2026-08-29 (`ed1ffe2`) -- the FK33 shell build did not route

**CLOSED by TRACK BOARDAUDIT 2026-08-29, against the tree rather than against a
document.** The cause was never area, timing or the placer: it was
`hw/fk33/fk33_pcieep.xdc:133-140`, an **inherited SQRL constraint** assigning
the whole block design to a pblock holding 67% of the assigned LUTs and 33% of
the assigned DSPs. It is `IS_SOFT`, so the placer crammed and spilled rather
than failing, and SHELL's own `runme.log` said so in nine `Place 30-640` lines
nobody read. Deleting it plus a small pblock at `CLOCKREGION_X0Y0:X6Y3` routes.

VERIFIED in the tree, not in a report: `hw/fk33/results/pblock_2026-08-29/ASX_route_status.rpt`
says **0 nets with routing errors, 288,506 fully routed**, and
`hw/fk33/bit/fk33_pcieep_eng.bit` is 22,568,402 bytes. `ed1ffe2` is an ancestor
of HEAD. The bitstream has since been loaded on card 1 and configures, links
Gen3 x4 and identifies (`docs/debugging/2026-08-29_first-engine-load-on-card.md`).

**This entry sat unmodified for a day saying "There is no routed checkpoint and
no bitstream" while both existed**, and the BACKLOG row for the same work said
the opposite. Two places recording one fact is how that happens. The
description below is kept for the record and is no longer the state of the tree.

**PROVENANCE CORRECTED 2026-08-30 by TRACK BITPREP** (`e0e4fec`,
`docs/debugging/2026-08-30_bitprep-rebuild-readiness.md`). `ed1ffe2` is the
right commit for the **constraints and the routing** and the wrong one for the
**netlist**. MEASURED from the artefact's own header: `write_bitstream` stamped
`fk33_pcieep_eng.bit` at **2026/08/29 14:38:06**, and `ed1ffe2` landed at
**14:42:42, four minutes later**. The netlist was synthesised around 06:56 that
morning from `rtl/` at **`54b3c1a`**, with `hw/fk33/` in the state committed as
`928ad9f`. No git SHA is stamped in the bitstream (`UserID=0XFFFFFFFF`), so
this is reconstructed from build logs, not read off the artefact. Several
write-ups say `ed1ffe2`; they are **not** being edited, because most of them
are talking about the routing, where it is correct. When the question is *what
RTL is on the card*, the answer is `54b3c1a`.

**What a rebuild is actually worth, MEASURED by BITPREP.** The pcieep build
consumes **fifteen** RTL files and B, C and D are not among them. `54b3c1a..HEAD`
has 28 `rtl/` commits and **only 8 touch this design**, of which one is
assert-only and one is inert at this geometry. The real content of a rebuild is
**four commits: `0ff6828`, `75f95a8` (A7's `outst` clamp), `3ecc729` (DONE1's
`done_l` race), `a4a564c` (THERMFIX's thermal guard)** -- not twenty-eight. All
four confirmed absent from the loaded bit.

**`hw/fk33/bit/` is gitignored (`.gitignore:134`), so the tree held the ONLY
copy of what is on the card.** Archived 2026-08-30 to
`/mnt/storage/fk33-bitstream-archive/`, all six `.bit` files, with the loaded
one named `fk33_pcieep_eng.2026-08-29T1438.rtl-54b3c1a.bit`. Its sha256 is
`6b12b3c46ee26396bcbc1f75cf240fe6231528a7a10c95ac91596b52bce164c6` and it was
verified equal to the working copy after the archive. **This is the rollback
artefact.** Note `hw/fk33/pcieep.sh` prefers `bit/fk33_pcieep.bit`, which is the
Aug-27 **pre-engine** build -- without `EP_BIT` set explicitly it will configure
a card with no engine and report success.


### OI-12, superseded text

**MEASURED 2026-08-29, `928ad9f`.** The first build carrying subsystem A on the
card's HBM ports places, but `route_design` terminates:

    ERROR: [Route 35-3] Design is not routable as its global congestion
                        level is 7.

7 is the top of the scale. Six attempts at initial net routing over 7 min 48 s,
then abandoned. **There is no routed checkpoint and no bitstream.**

**It is not area.** Whole design 39.50% LUT, 14.22% FF, 38.91% BRAM36, 55.03%
DSP, 0 URAM. The engine's own area in the shell is within 1.8% of the
out-of-context figure on every line (LUT 132,113 vs 134,534; FF 63,797 vs
64,067; DSP and BRAM36 identical), so the OOC numbers were honest and the
shell costs 41,581 LUT and 69 BRAM36 on top.

**It is probably not timing either, though that is not settled.** Design-wide
WNS went -0.763 after place, -0.368 after phys_opt, -0.260 at the router's last
update before it quit, against 250 MHz on the HBM AXI side and 200 MHz on the
core.

**What is NOT known is what is congested.** `report_design_analysis
-congestion` did not complete in the time available, so the 128x128
long-congestion regions south and east are the only localisation there is. The
untried experiments, in order of cheapness: a pblock putting the engine in the
clock regions nearest the HBM BLI interfaces (its core clock currently spans
all 8x4 regions); a lower clock, which separates congestion from the
timing-driven replication that added 185 of the design's 3,887 control sets;
and a different placer directive.

Write-up, including five things measured and rejected:
`docs/debugging/2026-08-29_fk33-shell-integration-does-not-route.md`.

### OI-13: the aux domain's CDC check does not scale to subsystem A

The impl-stage verification that made the aux domain trustworthy -- enumerate
every path crossing the clock boundary and demand that none is ANALYSED, since
an asynchronous group excludes a path without stopping it being enumerated --
**does not terminate** on a design containing subsystem A. MEASURED: over 20
minutes on `get_timing_paths -from <core> -to <axi> -max_paths 8`, killed.
`report_timing_summary` on the same checkpoint likewise. 28 gray-pointer FIFOs
plus 28 four-phase clear handshakes is an enormous enumeration where the aux
domain is a handful of single-bit crossings.

`gen_pcieep.py` now checks only that both clock lookups RESOLVE, which is what
decides whether the XDC `set_clock_groups` matched anything (an empty group is
a warning, not an error), and writes `report_clock_interaction` to a file for a
human. It is labelled in the script as the weaker check it is. **Consequence:
nothing currently proves the per-port CDC is being treated as asynchronous
rather than timed, and no per-clock WNS figure exists for this design.** If the
group did NOT apply, every WNS above is pessimistic rather than optimistic.

### OI-4: RESOLVED 2026-08-29 (`a2b20f3`) -- the descriptor-program generator exists

**CLOSED by TRACK BOARDAUDIT 2026-08-29.** `tools/gen_layer_program.py` is
1,155 lines, names backlog row 6 in its own header, and emits real bytes:
`d_table.hex` and a per-job `a<NN>_<tensor>.hex` for each of the 311 A jobs,
behind a full CLI. `tools/dprog_oracle.py` (956 lines) checks the EMITTED BYTES
against artefacts from other sources. Both VERIFIED present at HEAD.

Note the WORKLOG's own D-PROG section already said "**OI-4 is STALE at HEAD and
should be closed**" and the entry was left open anyway. A correction written in
one section does not close an issue recorded in another.

**Trap that survives the closure: `gen_layer_program.py` defaults to the
PRE-QKV-PAD packed set, where 48 of 311 A jobs are refused. Always pass
`--manifest`.**

Superseded text: Subsystem D's control core is integrated and mutation-tested,
but nothing emits the descriptor program it executes. This is **host software**
and it is on the critical path for both the card and the server. **UNBLOCKED
2026-08-28:** the descriptor format is settled and byte-pinned in
`docs/2026-08-28_matvec-descriptor-format.md`, whose section 7 carries a
reference builder in C for the A job. Still nothing emits it.

---

## Landed

| track | result | commit |
|---|---|---|
| **RY-ORACLE: subsystem C's output gets a value oracle, and it found a defect** | `R_Y` had NO integration-level model, which is why R7 was unkillable. Now modelled from the machine's own captured `R_QG`/`R_KIN`/`R_VIN`; coverage 58 -> 59 of 63. **R7 killed on the numbers.** B's three `R_Y` seams stay open for a STRUCTURAL reason (input includes recurrent state no region holds), not for want of effort. **Unplanned finding, defect C1:** `attn_block`'s `v_ref` fold has no layer dimension while its own comment says it must; live at the real shape's 8 attention layers; no bench could see it because `tb_attn_block` hardwires `layer => 0`. **Also WITHDREW the `R_ER` alarm as a stimulus artefact:** synthetic weights grow the residual 1.06e6x over four blocks against 1.10x real, and at the real shape there are ZERO annihilation cases. Warned that fixing C1 SILENTLY UN-KILLS R7. | `686fd97`, `08df58b`, `d6819e8`, `b32ecb5`, `0e867a0`, `eeb1200` |
| **BISECT: the first value oracle to reach integration level** | Built the capture path, then CORRECTED its own brief: the 9B reference cannot bisect a GHDL run (35,650x the arithmetic, ~15 days/token, and `v_n` at 13 bits cannot express `ffn = 12288`). Built a stepwise oracle instead: **58 of 63 seams clean in all three configurations**, N2 killed on the numbers at `R_XN-0` element 63. **Retracted its own gate verdict**: it read the FIRST of two report blocks in a log whose scratch tree had been deleted mid-run. Lesson: a grep returns every candidate verdict, only the LAST is the verdict. | `ecfd178`, `f6fda25`, `85f4e71` |
| **A-MUT: subsystem A's first mutation coverage, and the adversarial trace is the WEAKEST** | 57 mutations x 3 traces, ABORT as a third verdict. Committed gate 36 kills, ragged 40, **adversarial only 30** -- ten mutations the plain trace kills survive it, because identical products make rounding invisible (all at the rail) and adder-tree changes invisible by symmetry (`2*p == p+p`). **Saturation coverage and value diversity are OPPOSED.** Eight mutations are invisible to the committed gate (`tr.txt` has K=96 and M=8 exact, SATEV 0), including removal of the `sat32` clamp. Two stimulus gaps closed: `xmem` poisoned not zeroed, and an `err`-goes-HIGH assert (the guard on a `ybuf` overrun was itself unguarded). No RTL defect found. | `a3dc2f4` |
| **EMBDROP: 562 MiB per card, 2.195 GiB per cluster** | Repacked without `token_embd.weight` after Oren's decision. Recovered 589,287,424 B = tensor plus 17,080,320 B of stack-boundary hole no longer skipped; 6.86% of HBM, **29.5% of the N=4 spare**; `max_context_tokens` 52,319 -> 61,311. Made it a REVERSIBLE named flag, not a deletion. Checked the one thing that could falsify the premise: **`output.weight` is NOT tied** (different GGUF offsets, different bytes). Found `pl_open_opts`'s default bases point INSIDE the weight image in BOTH sets. Caught a stale line number in the dispatcher's own brief, off by 39. | `46216b3` |
| **TOKIO: the embedding was already decided, and the lm_head table was refused by its own gateware** | `seq_tbl_pkg` encoded a single 248,320-row lm_head job the descriptor plane REFUSES; now 15 windows at stride 17,376 (not 17,408: `17408 mod 48 = 32`). It now matches `gen_layer_program.py`'s DEFAULT output byte for byte, where before it matched only under `--one-lmhead-job`. **The embedding decision was NOT open** -- the host-writes-`R_X` path was already built (`seq_opdec`'s `tok_fsm` exists solely to publish it). New bench asks what four table-walking benches structurally cannot: they all take `TBL_STEPS` from the package. Scored one mutant killed by the LANGUAGE separately rather than claiming 11 of 11, and found a decoration check of its own. | `80d3a61` |
| **SPECREC: the six absent C units were six absent NAMES** | All thirteen spec-named responsibilities ARE implemented; the backlog verdict was an absent name read as an absent responsibility. `attn_score_q12.vhd` is real, is half of `attn_score_tree`, and is on NO spec list -- the mirror defect. Fourteen false claims corrected in place across five files, prioritised by blast radius. **27 read masters is 28**, so free HBM ports for B and C drop from 3 to 2. Nine analyses that never became work, four of them missing CHECKS -- and a missing check generates no artefact, so nothing reminds anyone. | `5b41635`, `f65e2bc`, part of `686fd97` |
| **CD-SEED: 60 gates in C and D, ZERO false-reds** | B's defect class is structurally impossible on C/D's bench side: all 25 benches are bit-exact, and C's bounds are DERIVED per case rather than fitted to a seed, so they move with the stimulus. B-SEED's 'widen it' rule does NOT transfer -- `attn_gate`'s oracle 1 attains its gate exactly at 20 of 40 seeds and widening would delete it. **One real defect fixed:** two committed vector files had no `tb_vector_args` row, so neither generator was ever built or run and five checks were unreachable. **Found that `mutate_attn_*.sh` score a DIED run as a KILL**, making C's published ratios unsafe. | `e27a9ad`, `9b02e8e` |
| **B-SEED: nine of thirty-five B thresholds fire on the HONEST unit** | Three at 98%, 82% and 58% of seeds. **The recursion is the finding:** B-RECUR's retune from that morning was ITSELF false-red -- its 52-seed sweep said honest max 15.429, thirty different seeds found 32.122, and two sweeps disagreeing 2.08x on a maximum means no feasible seed count bounds the tail. So COUNTS carry these benches, not maxima. Two thresholds had ZERO resolution left (a 2.5% window and a window of zero), recorded as never load-bearing again. Retunes took false-reds to 0 with all four kill ratios unchanged. Found a `SEED` knob that was inert: declared, printed, never passed. | `81297ee`, `0503be8`, `4a17dcc` |
| **TANDEM: available, and unevaluable until the design routes** | Confirmed by the TOOL, not the documentation: `create_ip xdma:4.1` accepts all four modes on this part. But the stage-1 pblock is a DRC-Error exclusion zone at `SLICE_X216Y0:SLICE_X232Y239`, **50,135 placed cells sit inside it**, and there is nothing to the right, so they all move LEFT into the congested half. Two things nobody had noticed: `DFX_over_PCIe` emits MCAP with NO stage-1 pblock, and **every non-GT pin is in bank 65, the config bank**, so observability must become static logic under any Tandem variant. Corrected the one-day ICAP estimate: right for the plumbing, wrong for the capability. | `abbd2ed` |
| **SHELL: the composed design does NOT route** | First FK33 build containing real arithmetic (subsystem A's descriptor plane as `fk33_engine`, 28 AXI masters). Places, then `[Route 35-3] Design is not routable as its global congestion level is 7` after six attempts over 7:47. **No bitstream exists.** NOT a timing miss (WNS -0.260) and NOT an area blowout (39.50% LUT, 55.03% DSP, 38.91% BRAM36). The engine SHRANK in the shell vs OOC (134,534 -> 132,113 LUT), so the OOC figures were honest. Corrected its brief three times: 192.5 vs 145.5 BRAM36 are different builds, masters are 28 not 27, and backlog 2's `llama_top` is a sim top with stories260K ROMs and no HBM interface. Found a combinational halt mask that did not block a GO, caught by a scratch bench with a firing negative control rather than by inspection. Peak RSS 22.81 GB. Filed OI-12 and OI-13. | `928ad9f`, `70c35db`, `d807a1c` |
| **LMHEAD: the whole token's A program is expressible** | `311 of 311 A jobs emitted, 0 refused` (was 296 of 297). 15 raw row windows at stride 17,376. **Route 2 refuted with the RTL as judge:** `matvec_int4_desc_axi`'s `S_CHECK` bounds `n_rows` in EVERY `out_mode`, so a 248,320-row descriptor is refused `err_code 0x3` in raw and BFP alike -- answering OUTMODE's open question NO. Raw over BFP is load-bearing: in BFP 832 of 1024 mantissas move and every value is exactly 2x, feeding a sampler whose only input is a bare 32-bit integer. 248,320 of 248,320 logits bit-identical, 9 of 10 mutations killed, m10 named a permanent structural non-biter. The 'destination region nobody has decided' does NOT exist: `dst = R_NONE` + `FLG_TO_SMP` was always there. Found a defect in `seq_tbl_pkg`, which encodes the job the gateware refuses. | `a781326` |
| **B-GATE: the flagship mutation now fails the gate** | `gdn_silu` and `rmsnorm_bf` had oracles that were PRINTED, not gated. Route B (in-bench real-valued oracle) chosen and Route A killed with one line: an RTL-only mutation leaves the generator reading the UNMUTATED 0.7704 LSB while the bench reads 1.68e10. Flagship closed WITH a control (same tree, only the bench swapped: FAIL new, PASS old). Gates max/count/mean/floor. **Warning for all of subsystem B: the committed `rmsnorm_bf` seed is the benign extreme of a 13x range** (honest worst 0.770 -> 9.999 LSB over nine seeds), so the pre-existing `ACC_LSB=1.0` fires on the HONEST unit at eight of nine seeds. Any B threshold calibrated on one seed is suspect. Also: a max-only gate could not have been made honest for either unit, and a mutation that destroys a unit reads BETTER than the correct one on every figure but the floor. 33 of 43 mutations killed, all 11 BOTH-class killed, 10 survivors named. | `728fcfe` |
| **QKV-PAD: 49 refused A jobs became 1** | Each fused row segment padded with ZERO rows to a whole `ROWS_IF` tile: starts 0/2064/4128, M = 8224 vs M_logical 8192, uniform across all 24 tensors and derived from GGUF metadata rather than the brief. Zero is the fill BECAUSE it is the only one also invisible under a WRONG scan domain (measured: a full-scale pad shifts ns 5 -> 8). 33,554,432 nibbles and 1,048,576 scales identical; 5 of 5 equivalence mutants bite. Found a silent pass in the tooling: a tile-aligned but WRONG `row_start` makes a descriptor the RTL accepts whose bases read past the tensor, and the gateware can never see it because `row_start` is not a descriptor field. | `e28083f` |
| **OUTMODE: raw mode had no oracle and wrote past the end of ybuf** | `out_mode=01` was already DRIVEN, by `tb_matvec_cb_lockstep` -- but that bench compares four runs against EACH OTHER and never against the reference. A round trip, not an oracle. With a real oracle attached, raw needed no new vector (`ref/matvec_int4.c` already emits `YDATA`; the loader dropped the line). Coverage 184/24 -> 464/343 values, masked rows now scored against zero rather than skipped. OI-10 fixed by narrowing the write ENABLE, not clamping the address as OI-8 did, with the reason in the code. **M6, the alternative fix form, DOES NOT BITE and is reported as a permanent floor:** nothing reads `ybuf` in raw mode, so no bench can separate the two forms. OI-11 WITHDRAWN for the arm it named (`f693faf` predates the filing, verified by ancestry) and closed on the AXU3EG arm it missed, where a `busy <= '0'` mutant passed all 22 cases. | `0ff6828`, `b65d9ad` |
| **B-FIX: three verification defects, and a corrected diagnosis** | Fixed D1 (golden two days behind its generator), D2 (the chain gate ran at the one `Z_DELAY` that hides the defect; bisection put the threshold at (520,540], corrected from '~512', and 640 is DERIVED from 616 cycles per head), and D3. **Corrected B-MUT's diagnosis on D3:** the sentinel-cancellation story explains only 14 of 17 cases past 100 LSB and the joint-worst case has NO saturation. The unifying statement is that the error is |a| times the softplus error, so the gate became a DOMAIN PREDICATE on inputs rather than a threshold. BOTH-class score 0 of 5 -> 4 of 5. Trap recorded: ghdl-mcode cannot override a `real` generic. | `ebcca86`, `6332abe`, `6e20668` |
| **TRACK TOP-KV: the KV seam at the INTEGRATION level** | `llama_top` instantiates `attn_kv_axi`, connects `attn_block`'s four seam handshakes, and advances a sequence position on `tok_done`/`tok_ack` instead of hardwiring 0. Four tokens of one sequence, TWO attention layers, three KV read latencies (100/7/403), R_X bit-identical per token, 0 KV faults. 26 mutation rows, 13 killed, 9 survivors all analysed. **Also closes backlog 14:** the gate had NO row with the real path on, and now has two. The 32-block real-weight landmark is byte-identical (`R_X(0) = -14110 hash 52347`, all 65 `log2 rms` samples). Regression 81 -> 83. `docs/debugging/2026-08-29_llama-top-kv-seam-multitoken.md` | see git log |
| Thermal guard synthetic trip | Guard halts, latches, freezes compute, releases. Teeth-checked. | `0b8831c` |
| Subsystem A at FK33 geometry | Bit-exact from real `.mv4i` bytes, 27 masters. Regression 76 -> 77. | `055b6ed` |
| AXI3 burst cap | HBM is AXI3, 16 beats not 128. Bit-exact at both; bench now runs the legal one. | `809ada7` |
| HBM port feasibility | 27 masters fit; 30 already measured at 288.0 GB/s, 100% of ceiling. Design note only. | doc only |
| Qwen3.5 tokenizer | Bit-exact vs llama.cpp, 53,411 strings x 2 + 1.1M codepoints. 7 of 9 mutations bite. | `4123bd8` |
| Qwen3.5 tokenizer in C | Bit-exact vs llama.cpp: 53,409 strings x 2, ALL 248,320 token ids, 1.1M codepoints, 20,051 malformed-byte strings. 7 of 7 mutations bite. +42,704 bytes linked, no new dependency. Found OI-5 and OI-6. | `0181cc3` |
| Full gate re-measured | 77 PASS / 0 FAIL, matches the recorded floor. Verified independently after `3246046`. | n/a |
| **C-ORACLE: `attn_block` did NOT compute attention** | First block-level oracle for subsystem C. 64 of 64 mantissas wrong on first comparison; bisected to TWO independent defects in `rtl/attn_block.vhd` (cached V exponents overwritten by the current token's, because `hdr_valid` is a level not a pulse; and every accumulator rescaled twice per rise, because `rs_have` re-latched from a still-standing `rs_valid`). Both fixed, oracle never adjusted. 17 wiring mutations, 17 killed. Regression 77, unchanged: a property was added to an existing test, not a test. VERIFIED SEPARATELY: `tb_attn_block` PASS and `tb_llama_top` PASS after the RTL fix. Note what that second one is and is not evidence for -- it shows the fix broke nothing, NOT that the fix is right, since `llama_top` runs one token at `cur_pos = 0` and never reaches either defect. The evidence the fix is right is the bit-exact oracle. | `8baa413` |
| A-sim MAXB correction | The original A agent woke, independently confirmed the AXI3 defect in its own bench, and appended a dated CORRECTION rather than editing the wrong claim out. Confirmation run completed separately: matvec_fk33, weight_streamer, axi_rd_port all PASS. | `2b12a7b` |
| **A-CTRL: the descriptor control plane, the CDC, and MAXOUT** (OI-1) | Descriptor format is D's, byte for byte, plus a four-word A extension AFTER the base array where D never reads. `matvec_int4_desc_axi` fetches and checks it before starting anything; `matvec_int4_axi` retained unchanged for the AXU3EG. Per-port async FIFO closes the HBM-to-core CDC; MAXOUT 2 -> 16. MEASURED: 100 of 100 elements bit-exact against `ref/matvec_int4.c` on the core bus AND 100 of 100 rows bit-exact through the AXI-Lite map, at `MAXB=16`, at four AXI/core clock ratios including a non-integer one. 22-case mutation table: 19 refused with the right code, 2 named as undetectable (see OI-1), 1 is the clean case. Found and fixed two of its own defects: a delta-skewed clock signal (broke `tb_matvec_int4_ip`) and a descriptor fetch left in the wrong clock domain (broke 17 of 22 cases under `DUAL_CLK`). Full gate 78 PASS / 0 FAIL, matches the raised floor. | `a4f7e17` |
| Magnitude blocker | Explosion was the STIMULUS (synthetic row norm 2^4.87 vs real 2^-0.03). PART 5 withdrawn, PART 3 reinstated. `attn_block` wired behind `C_REAL`. | `3246046` |
| **B-FIX: the three defects B-MUT measured in the CHECKING** | D1 `sim/gdn_conv_vec.txt` regenerated: 19 of 641 lines move, all case headers, all at `c % 7 == 0`, only the `cw_exp`/`e_seg`/`err` fields; no `x`/`w`/`sm`/oracle line moves and the worst-vs-oracle figure is unchanged at `4.99999999998181e-1`. Mutation R13 went pass -> FAIL against the committed golden. D2 `sim/regress.sh` now passes `-gZ_DELAY=640` to `tb_gdn_emit_chain`; MEASURED, the `z_have` mutation passes at 0/7/40/520 and fails at 540 and above, control PASSes at 640, so the kill threshold is (520, 540] and not the "~512" previously estimated. Cost 52 s -> 61 s. D3 the answer is NOT the expected one: the sentinel-cancellation diagnosis is INCOMPLETE -- the joint-worst case (70) has ZERO sentinel saturation and is 32767.9963 LSB wrong through the softplus negative-tail flush times an abs(a) of 3.09e14. `sim/tb_gdn_scalar.vhd` now GATES accuracy on a domain defined by a predicate on the INPUTS: 259 of 320 cases, worst 15.3271 LSB(Q15), gate 23.0, plus a count-past-1-LSB gate at 100 (67 measured) that catches B5 which the max cannot see, plus a beta gate and an in-domain-count FLOOR so the domain cannot empty. Teeth: 4 of 5 BOTH mutations now fail the BENCH; B4 deliberately still survives. `gdn_scalar` becomes the second of B's seven units with an accuracy gate `regress.sh` can fail. Full gate 81 PASS / 0 FAIL, matches the recorded floor; no test added or removed. Writeup: `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md`. | `ebcca86`, `6332abe` + this |

---

## BACKLOG, ordered, ready-to-dispatch

**AUDITED END TO END 2026-08-29 by TRACK BOARDAUDIT against `git rev-parse HEAD`
= `5a19f984`.** Every row below was judged by reading the tree and `git log`,
never by reading another document. Nine of the fourteen rows were already done;
four had never been struck by anyone and two of those cost a dispatch. The
genuinely open work is in the NEW rows at the bottom, and it is not what the
old table said it was.

**STRIKE A ROW IN THE SAME ACTION THAT LANDS IT.** This table had no such rule
and the In flight table did, which is exactly the difference in their accuracy.

### Closed rows, with what closes each

| # | task | closed by |
|---|---|---|
| ~~1~~ | `attn_block` <-> `attn_kv_axi` seam | `e7e7ae5`, with `sim/tb_attn_kv_seam.vhd`, `ref/attn_block_seq_vec.c`, `sim/mutate_attn_kv_seam.sh`. **Unstruck for a day; TRACK C-SEAM was dispatched onto it.** The dispatch was not wasted: it found OI-3b. |
| ~~2~~ | FK33 shell integration, then the congestion | Integration `928ad9f` / `70c35db`. Congestion RESOLVED by TRACK PBLOCK `ed1ffe2`: an **inherited SQRL constraint** at `hw/fk33/fk33_pcieep.xdc:133-140` assigned the whole block design to a pblock holding 67% of the assigned LUTs; it is `IS_SOFT`, so the placer crammed rather than failing, and `runme.log` said so in nine `Place 30-640` lines nobody read. Artefacts VERIFIED present: `hw/fk33/results/pblock_2026-08-29/ASX_route_status.rpt` (0 nets with routing errors, 288,506 fully routed) and `hw/fk33/bit/fk33_pcieep_eng.bit`, 22,568,402 bytes. **The bitstream has since been LOADED** (`docs/debugging/2026-08-29_first-engine-load-on-card.md`): configures, links Gen3 x4, identifies, BAR and DMA and HBM all round-trip. **What it COMPUTES is still unverified, and that is now row N1.** |
| ~~3~~ | `llama_top` instantiates `attn_kv_axi` and carries a sequence position | TRACK TOP-KV, see Landed |
| ~~4~~ | Token I/O: embedding and LM head | TRACK TOKIO `80d3a61` + TRACK EMBDROP `46216b3` |
| ~~5~~ | `pl_backend` v2 and the server seam | **LANDED, TRACK SERVER, `3963a60`, `docs/debugging/2026-08-29_host-seam-v2.md`.** `server/pl_backend.{c,h}` is a full v2: `pl_prefill`/`pl_decode`, `fk33_transport` with chardev, filedir and sim backends, `fk33_manifest.c`. **This row was never struck. It is the SEVENTH such instance.** But read row N2 before believing the work is usable: `server/pl_backend.c`'s own first three lines say **"Nothing here has ever run against the card"**, and the register contract it drives is implemented by no RTL in this repository. |
| ~~6~~ | Subsystem D: the layer-level descriptor program | `tools/gen_layer_program.py`, 1,155 lines, `a2b20f3`, naming this row in its own header. Oracle `tools/dprog_oracle.py`, 956 lines. |
| ~~8~~ | `gdn_recur` / `gdn_exp_capture` mutation coverage + the `d_m` grid defect | **LANDED, TRACK B-RECUR, `ea26eec`, `docs/debugging/2026-08-29_gdn-recur-coverage-and-dm.md`**, whose title is the answer: *the 8.955 LSB is not the d_m grid defect, and the gate that held it fires on the honest unit*. `sim/mutate_gdn_recur.sh` and `sim/mutate_gdn_exp_capture.sh` both exist. **Never struck. EIGHTH instance.** |
| ~~9~~ | Subsystem C spec reconciliation | **LANDED, TRACK SPECREC, `5b41635` / `f65e2bc`, `docs/debugging/2026-08-29_spec-reconciliation.md`.** The row's own premise was refuted: all thirteen spec-named responsibilities ARE implemented; six absent NAMES were read as six absent units. **Never struck, and the board contradicted itself, because the Landed table has carried a SPECREC row the whole time. NINTH instance.** |
| ~~11~~ | The five B units with no accuracy gate `regress.sh` can fail | **LANDED.** `728fcfe` (`gdn_silu`, `rmsnorm_bf`), `81297ee`, `2868f6b` (the three emit units), then TRACK BGATE2 `f3cb87a` / `2c89814` / `589513c` / `1216a5e` / `dfe308c` pinned the goldens to the gate rather than to whatever lies in `sim/`. **`2868f6b` closed this TWELVE HOURS BEFORE BGATE2 was dispatched onto it**, which is the most expensive instance of the day and is written up in `2c89814`. Full unfiltered gate at `1216a5e`: `OVERALL PASS 99 FAIL 0`. |
| ~~12~~ | A whole-model 9B numeric reference | `91ba5ef`, `885420c`, `ecfd178`, `f6fda25`, `686fd97`, `0e867a0`; `docs/debugging/2026-08-29_9b-whole-model-reference.md`. The `llama_top` capture that was its remaining gap landed as TRACK CAPTURE, `docs/debugging/2026-08-29_capture-llama-top-r9bs.md`. |
| ~~13~~ | A composed synthesis at the real shape | **LANDED as two tracks, and the answer was NEGATIVE.** TRACK COMPOSE `01a9e95` measured B+C+D out of context at the real 9B shape: **DSP 591, and the model was right to 1.5%, so the DSP risk is retired**; LUT 771,900 against 268,222 free is **2.88x over**. TRACK REALFIX `3e93bed` retired the row's other half by making the real 9B shape elaborate in GHDL, so the first full-shape elaboration no longer happens inside Vivado on the critical path. **Residual is row N5**, a re-measurement after WRITEDEC. |
| ~~14~~ | Two real-path rows for the gate | TRACK TOP-KV: `sim/tb_llama_top_real.vhd` and `sim/tb_llama_top_seq.vhd` |

### Still open, ordered

| # | task | depends on | owns |
|---|---|---|---|
| **N1** | **NOTHING HAS VERIFIED WHAT THE CARD COMPUTES, AND NO TOOL IN THIS REPOSITORY CAN.** This is the standing question and it now has a row. MEASURED: `hw/fk33/gen_pcieep.py` puts the engine's own register map at **`ENG_CTL_BASE = 0x00012000`** and its activation writer at `ENG_XW_BASE = 0x00013000`; `grep -rn '0x12000\|0x00012000\|ENG_CTL' hw/fk33/host/ server/ tools/` returns **nothing**. `hw/fk33/host/fk33_regs.h` has no engine block at all, and `fk33ctl.py`'s commands are `sysmon thermal id scratch gpio vccint selftest bench load verify` -- none of which starts a job. So: write the host-side runner that builds one `matvec_int4_desc_axi` descriptor, points it at a real `.mv4i` weight already resident in HBM, starts it at `0x12000`, and compares the result against `ref/matvec_int4.c`. **The agent-safe half is all of it except the last step:** `server/fk33_transport.h` already offers `fk33_transport_open_sim` and `fk33_transport_open_filedir`, so the runner can be written and fully exercised with NO hardware. **The real run is Oren's, at the bench.** This is the first arithmetic on this silicon and every schedule below it is unfalsifiable until it happens. **Read open issue THERM-255 before trusting any result from it:** the thermal guard has been measured tripping roughly once every three minutes for reasons that are not heat, and each trip halts the compute domain, so a stall or a wrong answer with a non-zero trip count is not evidence about subsystem A. | none | `hw/fk33/host/` (new file), `hw/fk33/host/fk33_regs.h` |
| **N2** | **THE HOST SEAM CONTRACT HAS NO GATEWARE, AND NOBODY HAS SAID WHICH SIDE MOVES.** MEASURED: `server/fk33_seam.h` defines a register block with magic `0x4C4C4D32` ("LLM2") at `FK33_SEAM_BASE_PROPOSED = 0x0000E000`, and its own comment says **"BASE IS PROPOSED, NOT DECIDED"**. `grep -rln 'LLM2\|4C4C4D32\|SEAM_ID' rtl/ hw/fk33/rtl/ hw/fk33/gen_pcieep.py` returns **zero files**; `0xE000` is assigned nowhere in `gen_pcieep.py`. So the whole of row 5's work drives a contract no bitstream implements, which is why `pl_backend.c` line 2 says it has never run. **This is a DECISION, not a fix, and it is Oren's:** either (a) build an `fk33_seam` AXI-Lite block in front of subsystem D, which presumes D is on the card and it is not, or (b) retarget `pl_backend` at the descriptor plane that IS on the card, which makes the host own the step loop, or (c) leave the seam as the target contract and accept that row 5 is dead code until N3 lands. Do not let a track pick one. | N1 for evidence | decision |

### N2 RESOLVED 2026-08-30 by Oren: option (a). Build the seam in front of D.

Oren, verbatim: **"we don't want host controlling, let's get D working"**.

That selects **(a) build an `fk33_seam` AXI-Lite block in front of subsystem D**
and rejects (b) explicitly. (b) was "retarget `pl_backend` at the descriptor
plane that IS on the card, which makes the host own the step loop" -- and the
host owning the step loop is the thing being ruled out.

**The row's own objection to (a) stands and is now a work item rather than a
reason not to choose it:** (a) "presumes D is on the card and it is not". So (a)
depends on N3, the composed A+B+C+D place-and-route. That is the ordering, not
a blocker.

What this makes true:

- `server/fk33_seam.h`'s magic `0x4C4C4D32` ("LLM2") and
  `FK33_SEAM_BASE_PROPOSED = 0x0000E000` stop being proposed. The base still has
  to be **assigned in `gen_pcieep.py`**, where `0xE000` is currently assigned
  nowhere, and the register block still has to be **implemented in RTL**, where
  `grep -rln 'LLM2\|4C4C4D32\|SEAM_ID' rtl/ hw/fk33/rtl/ hw/fk33/gen_pcieep.py`
  returns zero files.
- Row 5's work stops being dead code, and `server/pl_backend.c` line 2 -- "Nothing
  here has ever run against the card" -- becomes a thing to fix rather than a
  thing to accept.
- The host-side step loop in `hw/fk33/host/fk33_run_token.py` becomes a
  **reference implementation and an oracle**, not the shipping path. It stays
  valuable exactly because it is bit-exact against `ref/run9b`: it is what the
  seam's output gets compared to.

**What it does NOT change, MEASURED, and this is the part that matters for
expectations.** Removing the host from the inner loop is worth the PCIe traffic
and nothing else. Fitting the card's own cycle counters across a 6x range of job
size:

```
CYCLES = 21.67 * BEATS + 215
  BEATS= 128 CYCLES=  2992  cycles/beat=23.38
  BEATS= 384 CYCLES=  8582  cycles/beat=22.35
  BEATS= 256 CYCLES=  5724  cycles/beat=22.36
  BEATS= 768 CYCLES= 16847  cycles/beat=21.94
```

The intercept is **215 cycles = 1.07 us**, so the per-job setup that D amortises
is worth **0.33 ms across a whole 311-job token**. The 21.67 cycles per beat is
**per-beat and does not amortise**, so **D does not touch it.** Anyone expecting
D to fix the engine's internal rate should read this first.
| **N3** | **NO RTL TOP COMPOSES A+B+C+D FOR THE CARD.** MEASURED: `hw/fk33/rtl/fk33_engine.vhd` instantiates `matvec_int4_desc_axi` and **nothing else** -- subsystem A alone. `rtl/llama_top.vhd` does instantiate all four (`matvec_int4`, `gdn_block`, `attn_block` + `attn_kv_axi`, the five `seq_*` + `rmsnorm_rs`, plus `sampler_stream`) but it is a SIMULATION top: it binds **`matvec_int4`, which has no descriptor plane**, and `C_REAL`, `C_KV_AXI`, `NORM_REAL` and `B_SRC_REAL` all default **false**. So between "B+C+D fits" and "9B runs on the card" there is an entire unwritten top level, and no row named it until now. **Blocked on WRITEDEC** (there is no point composing something that does not fit) and on N2 (the top level's host interface is exactly what N2 decides). | WRITEDEC, N2 | `hw/fk33/gen_fk33_engine.py`, `hw/fk33/rtl/fk33_engine.vhd` (generated), a new synthesis top |
| **N4** | **BUILD-HANG's real fix, which nobody owns.** A shell build sat blocked on `wait_on_run synth_1` for **27.6 hours** for a run `launch_runs` reported as started and never created. The processes were killed 2026-08-29 with Oren's approval; **the defect is untouched.** Fix is two lines of discipline in `hw/fk33/gen_pcieep.py`: a **bounded** wait, and a post-`launch_runs` assertion that the run directory actually exists. Small, self-contained, and the file is free. | none | `hw/fk33/gen_pcieep.py` |
| **N5** | **Re-measure the composed B+C+D after WRITEDEC lands.** COMPOSE MEASURED 771,900 LUT against 268,222 free. LUTDIET MEASURED the fix on one unit (`rmsnorm_rs` 169,746 -> 40,804 LUT at identical ports, FF, WNS and zero BRAM) and PROJECTED B+C+D at 210,890 against 233,765 free in `pb_core` -- a **9.8% margin, which is positive and thin**. A projection is not a measurement and 9.8% is not enough margin to schedule against. Re-run `sim/ooc_compose_bcd.tcl` on the post-WRITEDEC tree. | WRITEDEC | `sim/ooc_compose_bcd.tcl`, `hw/fk33/results/` |
| **N6** | **OI-3's two named mutations have never been re-run against the gate that should now catch them.** TRACK OI3B (`5578132`) gave `tb_llama_top` a real value gate (`P14`, pinning `L_X0`). The two defects OI-3 names live at `rtl/llama_top.vhd`'s `c_exp_region <= to_unsigned(R_VIN, 8)` and `if k >= 2 then qg_buf(k-2) <= el_rdata`, both inside the config `tb_llama_top_real` exercises, and both move `R_X(0)`. So the gate *should* kill them -- but MEASURED by TRACK BOARDAUDIT, no mutate script and no line of OI3B's teeth table names either one, and OI3B's teeth were taken on different mutations (C1, the `v_ref` collapse, the `gdn_silu` truncation). **A gate that should catch a defect and has never been shown to is exactly the class this project keeps being bitten by.** Cheap: two mutations, one bench. | OI3B (landed) | `sim/mutate_llama_top_land.sh`, `sim/tb_llama_top*.vhd` |
| **N7** | **`EC_CORE` (0xE) is reachable by no bench in the tree**, and mutation `R1` deleting the `core_err -> EC_CORE` path survives both judges. Closing it needs a stimulus no bench currently produces. Raised by TRACK DESC-MUT with no owner; still none. | none | `sim/tb_matvec_fk33_desc.vhd`, `sim/mutate_mv4i_desc*.sh` |
| **N8** | **Subsystem A coverage gaps, all three named by DESC-MUT and all three still open.** `rtl/matvec_int4.vhd` and `rtl/axi_rd_port.vhd` have **no mutation script**; `USE_XEXP_PORT=true` appears in **no bench at all**; and `DUAL_CLK=true` is a manual run, so the descriptor-path CDC -- whose absence once broke 17 of 22 cases -- has no automatic coverage. | none | `sim/mutate_matvec_int4.sh` (new), `sim/mutate_axi_rd_port.sh` (new), `sim/regress.sh` |
| **N9** | **The only surviving SQRL factory image has no off-disk copy.** `hw/fk33/bit/fk33_factory_backup_153300001366.{bin,mcs}` (33,554,432 B and 92,282,892 B) were dumped 2026-08-29 and VERIFIED by two independent reads with identical md5 (`dcb97432538b9c7d2855b1d9c93658f7`). They are **untracked in git** and sit only on a root filesystem at **91%**. Card 1's factory image was destroyed; this is its restore path and the only irreplaceable artefact in the project. Copy it to `/mnt/storage` (388 G free) and record the digest. Trivial, and the cost of not doing it is unbounded. | none | `hw/fk33/bit/` (copy only), a note in `docs/` |
| ~~**10**~~ | ~~OI-9 is a decision: widen, subdivide, or take a reserved D value. Ask Oren rather than choosing.~~ **DECIDED by Oren 2026-08-29: SUBDIVIDE VIA `ERR_INFO`.** See the Decisions table. The row is no longer a decision; it is row N12. | -- | -- |
| **N12** | **OI-9 implementation: subdivide the descriptor error space via `ERR_INFO`.** Oren decided the route on 2026-08-29, so this is determined work. VERIFIED still needed at HEAD: `rtl/matvec_int4_desc_pkg.vhd` accounts for all sixteen 4-bit values (`EC_NONE 0x0`, `EC_DESC 0x3`, `EC_WDOG 0x4`, `EC_GEOM 0x9`..`EC_SHAPE 0xF`, with `0x1,0x2,0x5..0x8` reserved for D) and says so in its own comment. **The byte layout must not move** -- that is the reason the route was chosen. Two things this must carry, both already MEASURED by TRACK DESC-MUT: **`EC_DESC` (0x3) is raised at NINE sites with two confirmed collisions even with `ERR_INFO` pinned**, so "refused for the right reason" is currently recoverable for only 6 of 9 codes and subdividing `EC_DESC` is the first thing this buys; and `ERR_INFO` is a word index by construction, so the sub-case encoding has to coexist with that meaning rather than replace it. Update the host decoder in the same change or the card gains a code the host cannot name. | none | `rtl/matvec_int4_desc_pkg.vhd`, `rtl/matvec_int4_desc_axi.vhd`, `server/pl_backend.c` (the decoder), `sim/tb_matvec_fk33_desc.vhd`, `docs/2026-08-28_matvec-descriptor-format.md` |
| **7** | **OI-3 proper: the two defect classes `tb_llama_top` structurally cannot see.** Distinct from N6, which only asks whether the existing gate already covers them. If N6 measures that it does, this row closes; if it measures that it does not, this row is the work. | N6 | `sim/tb_llama_top.vhd` |
| **N10** | **Gray coding still has no automated defence, and this is now precise.** TRACK CDC-STATIC's `sim/cdc_teeth.sh` and `docs/debugging/2026-08-29_cdc-static-analysis.md` (`be982b3`) closed two of the three classes: the encoder/decoder MISMATCH (`G2`) is caught by simulation, and the 2FF-vs-1FF MTBF class by `report_cdc`. **`G1`, both gray functions replaced by identity, is caught by neither** -- and is worse than uncaught, because the binary-pointer design reports TWO FEWER `report_cdc` warnings than the correct one, so any "the report must not get worse" rule passes it. The doc says so about itself. No owner. | none | `rtl/async_fifo.vhd`, `sim/cdc_teeth.sh` |
| **N11** | **`K2b`: `P_CB_CHK`'s idle invariant watches the command REGISTER, not the write.** VERIFIED unchanged at HEAD: the assert is on `cbw_v(0)`, which is the stage-W0 command register set the cycle `cb_we='1' and st=S_IDLE`, not the stage-W1 write into `cb(c)`. Any future change that deepens the codebook command path makes the invariant vacuous with nothing in the tree noticing. A standing hazard, not a task; recorded so it is not discovered by a defect. | none | `rtl/matvec_core.vhd` |

### THE ORDERED READY-TO-DISPATCH LIST

**Produced 2026-08-29 by TRACK BOARDAUDIT at HEAD `5a19f984`, after auditing
every row above against the tree.** READY means both of: its file ownership
does not collide with WRITEDEC, KVVALUE or CLOG2TOP, and its dependency has
landed. Ownership was checked against the rewritten table at the top of this
file, not against the stale one it replaced.

**Dispatch in this order. The first three are mutually non-colliding and can
run concurrently right now.**

| order | row | why now | owns | collides with a running track? |
|---|---|---|---|---|
| **1** | **N1** | **The only item that converts "9B inference on the card" from unfalsifiable into measurable.** No dependency, no decision, no new RTL. **CORRECTED while this list was being written: `hw/fk33/host/` is NOT wholly free.** An undeclared track committed `4b26b7e` / `6d9c857` into `hw/fk33/host/fk33_load_weights.py` minutes ago. N1 adds a new file and edits `fk33_regs.h`, so it does not collide -- **but this is the second ownership error of the night and it was caught by watching `git log`, not by reading the table. Re-check `git log --oneline` for the target directory immediately before dispatching anything.** Write and fully exercise the runner through `fk33_transport_open_sim`/`_filedir` with **no hardware**; hand the final run to Oren, who is authorised for card 1 tonight and only tonight. | `hw/fk33/host/` (new file), `hw/fk33/host/fk33_regs.h` | no |
| **2** | **N12** | Oren decided the route hours ago, so it is determined work rather than a question. Carries DESC-MUT's `EC_DESC` nine-site collision measurement, which is the thing the route actually buys. | `rtl/matvec_int4_desc_pkg.vhd`, `rtl/matvec_int4_desc_axi.vhd`, `server/pl_backend.c`, `sim/tb_matvec_fk33_desc.vhd`, `sim/regress.sh` (shared) | no |
| **3** | **N4** | Small, self-contained, and it is the fix for a defect that already cost 27.6 hours of a build slot silently. `hw/fk33/gen_pcieep.py` was released by PBLOCK and nobody has claimed it. Fold **N9** into this track: copying the only surviving SQRL factory image off a 91%-full root disk is minutes of work and the cost of not doing it is unbounded. | `hw/fk33/gen_pcieep.py`; plus `hw/fk33/bit/` (copy only) for N9 | no |
| **4** | **N8** | Three named subsystem-A coverage gaps, all still open, all independent of everything running. Sequence it AFTER N12 if N12 is running, because both touch `sim/regress.sh` and one of them touches `tb_matvec_fk33_desc`. | `sim/mutate_matvec_int4.sh` (new), `sim/mutate_axi_rd_port.sh` (new), `sim/regress.sh` (shared) | no, but serialise with N12 |
| **5** | **N7** | `EC_CORE` reachable by no bench. Genuinely open, no owner. **Serialise after N12**, which is in the same file, and there is a real argument for making them one track: N12 subdivides the error space and N7 makes one of its codes reachable. | `sim/tb_matvec_fk33_desc.vhd`, `sim/mutate_mv4i_desc*.sh` | serialise with N12 |
| **6** | **N10** | The one gray-coding class nothing defends, now narrowed to `G1` alone by CDC-STATIC. Honest risk: it may be unclosable, and the write-up already argues so. Dispatch it as a question, not as a task, and accept "measured, cannot be closed, here is why" as a good result. | `rtl/async_fifo.vhd`, `sim/cdc_teeth.sh` | no |
| BLOCKED | **N6** | Cheap and valuable, but **KVVALUE owns `sim/tb_llama_top.vhd`**. Dispatch the moment KVVALUE releases. Closing N6 also closes or reopens backlog row 7, so it gates that too. | `sim/mutate_llama_top_land.sh`, `sim/tb_llama_top*.vhd` | **yes, KVVALUE** |
| BLOCKED | **N5** | Depends on WRITEDEC. It replaces LUTDIET's 9.8% PROJECTED margin with a measurement, and 9.8% is not a margin anyone should schedule against. Dispatch the moment WRITEDEC lands. | `sim/ooc_compose_bcd.tcl`, `hw/fk33/results/` | **yes, WRITEDEC** |
| BLOCKED | **N3** | Depends on WRITEDEC (no point composing what does not fit) and on N2 (its host interface is what N2 decides). The single largest piece of unwritten work between here and 9B on the card. | `hw/fk33/gen_fk33_engine.py`, a new synthesis top | **yes, WRITEDEC; and N2** |
| **OREN** | **N2** | A decision, not a fix: is the seam or the descriptor plane the contract? Raise it; do not let a track choose. N1's result is the evidence that should inform it, which is another reason N1 goes first. | decision | n/a |

**If all four slots are somehow free: N1, N12, N4+N9, N8.**

**What this list does NOT contain, said explicitly.** No row here claims the
card computes anything correctly, because nothing has measured that. N1 is the
row that would, and until it returns a number, every downstream estimate on
this board -- the LUT margin, the token budget, the schedule -- is arithmetic
about a machine whose arithmetic has never been checked.
