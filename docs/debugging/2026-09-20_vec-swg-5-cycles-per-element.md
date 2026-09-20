# VEC_SWG costs 5.0 cycles per element on the card, and only 2.0 of them are the unit

Date: 2026-09-20. TRACK SWGFAST. Card: FK33 at 75 MHz, bitstream
`hw/fk33/bit/fk33_card_swg_75mhz_2026-09-20.bit`, profile
`hw/fk33/results/card_swg_2026-09-20/profile/profile_flat_tok0.txt`. Tree
at `8771f32` plus this track's edits. NO HARDWARE was touched by this track;
every number below that is not from the profile file is GHDL (mcode) on the
workstation.

## The question

Verbatim from the brief: "VEC_SWG costs 61,473 cycles per step, 32 steps =
1.97 M cycles per token (6.5 percent of the token on the lane-striped image,
3.2 percent on flat). The SwiGLU is over 12,288 elements (Qwen3.5-9B ffn), so
~5.0 cycles per element. VEC_NORM costs 11,336 cycles per step (65 steps,
0.74 M) over 4,096 elements, ~2.8 cycles per element. Both are serial vector
ops in D between A jobs. Account for the 5.0 cycles/element on the card from
the RTL ... Find the cheapest RTL change that removes most of the cycles
without changing VALUES."

## The answer

**The 5.0 cycles per element are 1 + 1 + 2 + 1: llama_top's `gsr` adapter
streams G into the unit (N+2 cycles), then U (N+2), the unit runs two
one-element-per-cycle passes (2N + 12, MEASURED `SWGFAST_CYCLES 24588`), and
the adapter reads the result back one word per cycle (N+2). DERIVED
61,459 against the card's 61,473; the 14-cycle residual is the
`seq_vec_issue` handshake and the profiler's step boundary, and VEC_NORM
leaves the identical 14 (11,322 derived, 11,336 measured).** Neither unit
has a multi-cycle per-element loop, an iterative silu or a divider:
`swiglu_mem` is a four-stage pipeline (Qq convert, `sigmoid_q` ROM
interpolation, two 32x32 multiplies) and `rmsnorm_bf_mem` already runs
LANES = 4.

**The change: `rtl/swiglu_mem.vhd` gains a `LANES` generic (default 1, the
old unit exactly).** LANES banks per operand, the pipeline replicated per
lane, a running max per lane combined in one extra state. MEASURED
start-to-done at N = 12288: **24,588 / 12,301 / 6,157** cycles at LANES
1 / 2 / 4, with the bench's read-out dumps (184,335 lines each) byte-identical
across all three. DERIVED VEC_SWG step: **61,473 -> 49,186 (LANES = 2,
-20.0%) or 43,042 (LANES = 4, -30.0%)**, i.e. 393 k or 590 k cycles per
token. **Nothing reaches the card until `rtl/llama_top.vhd` maps the generic
(one line, below); this track does not own that file.** The remaining 3N per
step is the adapter's serial region-file traffic and is not removable from
inside either unit.

`rmsnorm_bf_mem` is NOT changed: its unit share is 3,125 of 11,336 (27.6%),
and LANES = 8 would save 1,536 cycles per step, 0.16% of a token.

## The procedure

1. Read `rtl/swiglu_mem.vhd`, `rtl/rmsnorm_bf_mem.vhd` and `rtl/llama_top.vhd`'s
   `gsr` (line 3574 on) and `gvr`/`nproc` (line 3300 on) adapters. Both
   adapters have the same six states: S_IDLE, S_RD (one word per cycle from
   the region file into the unit's bank, consumed at k-2, loop to n+1), S_GO,
   S_RUN (wait for the unit's `done`), S_WR (one word per cycle out of the
   unit's bank into the region file, a two-deep valid pipeline), S_DONE.
2. Measure the unit alone. `sim/tb_swiglu_mem.vhd` already counted
   start-to-done per trial (`dut_cyc`); added a `SWGFAST_CYCLES <n> N= LANES=`
   line, and `NORMFAST_CYCLES` to `sim/tb_rmsnorm_bf_mem.vhd`. Run at the
   card's shapes (N = 12288; N = 4096 LANES = 4).
3. Derive the adapter's share from its state machine and check the sum
   against the profile. The control is that BOTH ops must leave the same
   residual, since both adapters have the same shape.
4. Implement LANES behind a default of 1. Run the identity bench (reference
   chain `swiglu -> vec_mem(32) -> bfp_pack`, no shared code) at LANES 1, 2,
   4, at N = 128 and N = 12288, with a `DUMP` generic added to the bench that
   writes every trial's o_exp and read-out mantissas to a file; `cmp` the
   dumps against a baseline produced by the COMMITTED RTL
   (`git show HEAD:rtl/swiglu_mem.vhd`) with a copy of the bench that has no
   LANES map.
5. Re-anchor every mutant in `sim/mutate_swiglu_mem.sh` (the lane loop
   changed the text of most lines), add a LANES axis (every row at 1, 2, 4)
   and six lane-structure mutants. Run with the attribution control (four
   columns).
6. Where a mutant survives for a reason a trial can remove, add the trial
   and re-run, keeping the pre-fix survival in the table.

## The evidence

### The card (MEASURED, profile_flat_tok0.txt)

```
13 61473 1 VEC_SWG 00110000000000
0 11336 1 VEC_NORM 00000000000000
```

### The units alone (MEASURED, GHDL)

```
SWGFAST_CYCLES 24588 N=12288 LANES=1     (committed RTL, 727 MB RSS, 102 s)
SWGFAST_CYCLES 12301 N=12288 LANES=2
SWGFAST_CYCLES 6157 N=12288 LANES=4
SWGFAST_CYCLES 268 N=128 LANES=1         (2N + 12)
SWGFAST_CYCLES 141 N=128 LANES=2         (2*NB + 13)
SWGFAST_CYCLES 77 N=128 LANES=4
NORMFAST_CYCLES 3125 N=4096 LANES=4      (3 * 1024 beats + 53 scalar states)
```

### The adapter (DERIVED from `gsr` / `nproc`, N = 12288 / 4096)

| phase | SWG cycles | NORM cycles |
|---|---|---|
| S_RD pass 0 (G / x), k = 0..n+1 | 12,290 | 4,098 |
| S_RD pass 1 (U) | 12,290 | (w is preloaded) |
| S_GO | 1 | 1 |
| S_RUN (the unit, MEASURED above) | 24,588 | 3,125 |
| S_WR, k = 0..n+1 | 12,290 | 4,098 |
| sum | 61,459 | 11,322 |
| card | 61,473 | 11,336 |
| residual | 14 | 14 |

Per element: SWG 1 + 1 + 2 + 1 = 5.0; NORM 1 + 0.75 + 1 + 0.013 = 2.77.

### The identity, before and after (MEASURED)

```
baseline (HEAD RTL) N=12288: checks=184336 bad=0 live=14 rail=1 rdlat=1  PASS
LANES=2             N=12288: checks=184336 bad=0 live=14 rail=1 rdlat=1  PASS
LANES=4             N=12288: checks=184336 bad=0 live=14 rail=1 rdlat=1  PASS
cmp dump_base9b.txt dump_new9b_L2.txt   -> identical (184,335 lines)
cmp dump_base9b.txt dump_new9b_L4.txt   -> identical
cmp dump_base128.txt dump_new128_L{1,2,4}.txt -> identical (3,225 lines)
```

The dump is the DUT's read-out through `o_raddr` (o_exp, then N mantissas
per trial), so it covers the bank layout and the lane select, not only the
arithmetic.

### After the change, the step (DERIVED: 61,473 - 24,588 + unit)

| LANES | unit | VEC_SWG step | saving per step | per token (32) |
|---|---|---|---|---|
| 1 | 24,588 | 61,473 | 0 | 0 |
| 2 | 12,301 | 49,186 | 12,287 (20.0%) | 393,184 |
| 4 | 6,157 | 43,042 | 18,431 (30.0%) | 589,792 |

### Area (LANES = 1 MEASURED; above it ESTIMATE)

`hw/fk33/results/swgmem_2026-09-19/result_swg_mem.csv`, OOC at 5.0 ns:
16 DSP, 2,493 LUT, 319 FF, 19.5 BRAM tiles, WNS -3.669 (115 MHz at the
harness period; the card closes at 75 MHz). The census roots `ARG`, `a_hq`,
`a_vq`, `b_sig`, `o_wd`, `d_out`, `max_abs` (about 2,400 LUT and all 16 DSP)
are the per-element datapath and replicate per lane, so ESTIMATE +16 DSP and
+2.3 k LUT per additional lane: about 32 DSP / 4.8 k LUT at LANES = 2, 64 DSP
/ 9.5 k LUT at LANES = 4, against a card netlist of 362,195 LUT. BRAM is
neutral in bits (LANES banks of N/LANES words each). **Not measured**; the
draw is `sim/ooc_swgmem_run.sh`'s `draw swiglu_mem swg_mem_l4 "N=12288 Q=12
LANES=4"` and belongs on the BC-250 lane.

### The mutation table (MEASURED, `sim/mutate_swiglu_mem.sh`, N = 128)

Columns: FULL = all checks; noVAL = mantissa check off; noVL+EX = exponent
check also off; noALL = latency probe also off (only the non-degeneracy gate
and "never asserted done" remain). rc=1 in a column means the mutant was
killed with only those checks. Rows with the WHAT truncated at the first
double space; the full text is in the script.

```
MUTANT     L   FULL    noVAL   noVL+EX noALL   VERDICT   WHAT
baseline LANES=1 rc=0 :: checks=3742 bad=0 live=22 rail=7 rdlat=1 N=128 :: SWGFAST_CYCLES 268
baseline LANES=2 rc=0 :: checks=3742 bad=0 live=22 rail=7 rdlat=1 N=128 :: SWGFAST_CYCLES 141
baseline LANES=4 rc=0 :: checks=3742 bad=0 live=22 rail=7 rdlat=1 N=128 :: SWGFAST_CYCLES 77
nosig      1   rc=1    rc=1    rc=1    rc=0    BITE
nosig      2   rc=1    rc=1    rc=1    rc=0    BITE
nosig      4   rc=1    rc=1    rc=1    rc=0    BITE
packrnd    1   rc=1    rc=0    rc=0    rc=0    BITE
packrnd    2   rc=1    rc=0    rc=0    rc=0    BITE
packrnd    4   rc=1    rc=0    rc=0    rc=0    BITE
raskew     1   rc=1    rc=1    rc=1    rc=0    BITE
raskew     2   rc=1    rc=1    rc=1    rc=0    BITE
raskew     4   rc=1    rc=1    rc=1    rc=0    BITE
convrnd    1   rc=1    rc=1    rc=1    rc=0    BITE
convrnd    2   rc=1    rc=1    rc=1    rc=0    BITE
convrnd    4   rc=1    rc=1    rc=1    rc=0    BITE
opswap     1   rc=1    rc=1    rc=1    rc=0    BITE
opswap     2   rc=1    rc=1    rc=1    rc=0    BITE
opswap     4   rc=1    rc=1    rc=1    rc=0    BITE
expswap    1   rc=1    rc=1    rc=1    rc=0    BITE
expswap    2   rc=1    rc=1    rc=1    rc=0    BITE
expswap    4   rc=1    rc=1    rc=1    rc=0    BITE
oexpsign   1   rc=1    rc=1    rc=0    rc=0    BITE
oexpsign   2   rc=1    rc=1    rc=0    rc=0    BITE
oexpsign   4   rc=1    rc=1    rc=0    rc=0    BITE
silush     1   rc=1    rc=1    rc=1    rc=0    BITE
silush     2   rc=1    rc=1    rc=1    rc=0    BITE
silush     4   rc=1    rc=1    rc=1    rc=0    BITE
nodrain    1   rc=1    rc=1    rc=0    rc=0    BITE
nodrain    2   rc=1    rc=1    rc=0    rc=0    BITE
nodrain    4   rc=1    rc=1    rc=0    rc=0    BITE
nosat      1   rc=0    rc=0    rc=0    rc=0    SURVIVES
nosat      2   rc=0    rc=0    rc=0    rc=0    SURVIVES
nosat      4   rc=0    rc=0    rc=0    rc=0    SURVIVES
doneearly  1   rc=0    rc=0    rc=0    rc=0    SURVIVES
doneearly  2   rc=0    rc=0    rc=0    rc=0    SURVIVES
doneearly  4   rc=0    rc=0    rc=0    rc=0    SURVIVES
wrot       1   rc=1    rc=1    rc=1    rc=0    BITE
wrot       2   rc=1    rc=1    rc=1    rc=0    BITE
wrot       4   rc=1    rc=1    rc=1    rc=0    BITE
bankdec    1   rc=0    rc=0    rc=0    rc=0    SURVIVES
bankdec    2   rc=1    rc=1    rc=1    rc=0    BITE
bankdec    4   rc=1    rc=1    rc=1    rc=0    BITE
rselskew   1   rc=0    rc=0    rc=0    rc=0    SURVIVES
rselskew   2   rc=1    rc=1    rc=1    rc=0    BITE
rselskew   4   rc=1    rc=1    rc=1    rc=0    BITE
lanemax    1   rc=0    rc=0    rc=0    rc=0    SURVIVES
lanemax    2   rc=1    rc=1    rc=0    rc=0    BITE
lanemax    4   rc=1    rc=1    rc=0    rc=0    BITE
p1lane     1   rc=0    rc=0    rc=0    rc=0    SURVIVES
p1lane     2   rc=1    rc=1    rc=0    rc=0    BITE
p1lane     4   rc=1    rc=1    rc=0    rc=0    BITE
wdlane     1   rc=0    rc=0    rc=0    rc=0    SURVIVES
wdlane     2   rc=1    rc=1    rc=1    rc=0    BITE
wdlane     4   rc=1    rc=1    rc=1    rc=0    BITE
smaxskip   1   rc=0    rc=0    rc=0    rc=0    SURVIVES
smaxskip   2   rc=1    rc=1    rc=0    rc=0    BITE
smaxskip   4   rc=1    rc=1    rc=0    rc=0    BITE
```

Read across. FULL kills 16 of 18 at LANES 2 and 4 (10 of 18 at LANES = 1,
where the six SWGFAST rows are no-ops or the identity by construction).
noVAL (exponent + latency remain): all but `packrnd` still die, so `packrnd`
is the one kill the mantissa check alone earns. noVL+EX (the latency probe
alone, which compares ONE reference element and is a value check in
disguise): `nosig`, `raskew`, `convrnd`, `opswap`, `expswap`, `silush`,
`wrot`, `bankdec`, `rselskew`, `wdlane` still die; `oexpsign`, `nodrain`,
`lanemax`, `p1lane`, `smaxskip` survive here, so those five are killed by
the EXPONENT check (they corrupt the pack shift and nothing else visible at
one element). noALL kills NOTHING, so no kill is credited to a check that
does not exist. `nosat` and `doneearly` survive everywhere, as before: the
bench's resolution floor, kept under their names.

Before the two planted trials were added (same script, same RTL):

```
nodrain    1   rc=0    rc=0    rc=0    rc=0    SURVIVES
nodrain    2   rc=0    rc=0    rc=0    rc=0    SURVIVES
nodrain    4   rc=0    rc=0    rc=0    rc=0    SURVIVES
lanemax    2   rc=1    rc=1    rc=0    rc=0    BITE       (the random draw)
lanemax    4   rc=0    rc=0    rc=0    rc=0    SURVIVES!EXP=BITE
```


### The gate rows (MEASURED, `sim/regress.sh --only <row> --keep`, after every edit)

```
PASS       sim:tb_swiglu_mem                      3s
PASS       sim:tb_swiglu_mem_9b                 126s   (both matched by --only tb_swiglu_mem)
 OVERALL     PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
PASS       sim:tb_rmsnorm_bf_mem                  1s
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
PASS       sim:tb_llama_top_swg                 125s   ghdl peak 255 MB (/proc exe census)
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
PASS       sim:seamgate_swg                     126s   ghdl peak 411 MB; 3 tokens, 64 seams per token
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
```

The two llama_top rows elaborate `swiglu_mem` at the DEFAULT (LANES = 1)
through `gsr`, so they confirm the default is the old unit in the composed
top; they say nothing about LANES = 2 or 4 there, which needs the
llama_top diff below. `sim/mutate_rmsnorm_bf_mem.sh` was re-run after the
norm bench edit: 0 unexpected verdicts, the same four documented survivors.

## Measured and REJECTED, do not retry

- **Folding pass 1 into the U load stream** (the unit snooping `u_we` and
  reading g from its bank as u arrives, so `start` only runs pass 2).
  Rejected by DERIVATION, not measured: it saves one pass, which at LANES = 4
  is 3,072 cycles per step (0.1% of a token), and it changes the unit's
  residency contract (g must be resident before the first u write; g_exp/
  u_exp must be latched before `start`), which every bench and the adapter
  would have to learn. LANES makes it moot.
- **LANES = 8 for swiglu_mem.** A pass is 1,536 beats; the further saving is
  3,072 cycles per step (98 k per token, 0.3% striped) for another
  ESTIMATE 64 DSP / 9 k LUT. Not drawn.
- **LANES = 8 for rmsnorm_bf_mem.** Saves 1,536 of 11,336 per step, 65
  steps, 99,840 cycles per token (0.16% striped). Not done.
- **Streaming the pass-2 write out of the unit so S_WR overlaps S_RUN.** At
  LANES = 1 this gives 4N per step, the same as LANES = 2 without it; at
  LANES = 4 the region file's one write port per cycle paces pass 2 to N,
  giving 3.25N against 3.5N. It needs llama_top changes for 0.25N. Not
  done.

## What would remove the other 3N (not this track's files)

All three are in `rtl/llama_top.vhd` or the sequencer, and none is small:

1. The G load (N cycles) could hide entirely behind the `ffn_up` A job: G
   is `ffn_gate`'s output and is final before `ffn_up` starts, but the
   sequencer issues ops serially. A split or prefetch op is a `seq_*`
   change.
2. A wider region-file read port (4 x 16-bit words per cycle) would make
   every S_RD and A's `S_XRD` N/4. That is the region file itself.
3. S_WR streamed during pass 2 (above): 0.25N at LANES = 4.

## What llama_top needs (exact diff, NOT applied; this track does not own it)

`rtl/llama_top.vhd`, next to `NORM_LANES` (line 378):

```
    SWG_LANES  : positive := 1;      -- must divide SHAPE.ffn; 1, 2 or 4
```

and in `gsr` (line 3633):

```
-      u_swg : entity work.swiglu_mem
-        generic map(N => NN, Q => 12)
+      u_swg : entity work.swiglu_mem
+        generic map(N => NN, Q => 12, LANES => SWG_LANES)
```

plus `hw/fk33/gen_fk33_card.py` `"--generic", "SWG_LANES=4"` beside
`SWG_REAL=true` (line 226). The adapter's protocol is unchanged: `done` is
still a one-cycle pulse on the edge the last word lands, `o_raddr ->
o_rdata` is still one edge (MEASURED `rdlat=1` at every LANES), and the
unit's `start` still needs both banks resident. The default keeps every
existing bench and the shipping build cycle-identical.

## Measurement traps hit

- **The unit's cycle count is 40% of the op.** `SWGFAST_CYCLES 24588` alone
  reads as 2.0 cycles per element; the card says 5.0. A bench that
  instantiates only the unit cannot see the adapter, and the accounting had
  to be DERIVED from `gsr`'s states and checked against the profile with a
  second op as the control. Report both numbers, always.
- **A kill on a random trial is not a kill by design.** The `lanemax` mutant
  (lane 0 dropped from the lane-max combine) BIT at LANES = 2 and SURVIVED
  at LANES = 4 on the first run. The pack shift only moves when the dropped
  lane's max sits in a higher power-of-two bin than every other lane's;
  random draws over 128 elements rarely give that, and the one planted
  element (`one_big`, index N/2 + 1) is lane 1 at both LANES. The LANES = 2
  bite was the draw. Fixed by planting the element at N/2 + 0..3 so every
  lane holds the max once.
- **`nodrain` survived every trial the bench had.** Its bite needs the max
  in the LAST beat of pass 1; no trial put it there, so a check that has
  existed since 2026-09-19 with the label UNKNOWN had never discriminated.
  `one_big_last` (index N-1) was added; see the table for whether it bites.
- **Comparing the DUT against the reference is not comparing before against
  after.** The identity bench passes for any unit that matches
  `swiglu -> bfp_pack`; the brief asked for bit-identity to the PREVIOUS
  unit, which is the dump `cmp` against the HEAD RTL, a separate artefact.
- Scratch helper scripts must take absolute paths: `run_swg.sh` `cd`s into
  its work directory, and a relative `rtl/swiglu_mem.vhd` failed silently
  with rc=8 on the first run.

## Open, not yet answered

- The LANES = 2 / 4 area and timing on the part (ESTIMATE only above). The
  OOC draw is one command on the BC-250 lane.
- Whether the card's LUT budget (362,195 of 439,680 at the last build)
  takes LANES = 4; LANES = 2 is the conservative first build.
- Real-A `S_XRD` and the region file's port width: the same 1-word-per-cycle
  cost is paid by every A job's x load and is not in this write-up's scope.

---

# CORRECTION AND SECOND PASS, 2026-09-20 (TRACK SWGFAST, second attempt)

The first attempt hit an API rate limit before it committed anything. Its
work was on disk and all of it is re-verified below by a second agent that
did not inherit its context. **Nothing above is withdrawn**; two things are
corrected and one gap is closed. Every number in this section was produced
by a tool run after the first attempt stopped.

## Correction 1: the honest number is 0.95% of a token, not 30%

The table above reports the LANES = 4 saving as **-30.0% of the VEC_SWG
step**, which is right, and never divides it by the token. Doing so is the
whole point of the exercise, because the brief asked what a LANES change
buys on the CARD.

MEASURED, by summing `dur_cycles` over
`hw/fk33/results/card_swg_2026-09-20/profile/profile_flat_tok0.txt`:

```
token total cycles (flat, tok0): 61907125
  A_JOB        42686358  68.95%
  B_JOB        15854607  25.61%
  VEC_SWG       1967136   3.18%
  VEC_NORM       736840   1.19%
  C_JOB          594472   0.96%
  VEC_RES         67712   0.11%
```

DERIVED from that total:

| LANES | unit | step | saving/step | per token (32 steps) | of the whole token |
|---|---|---|---|---|---|
| 1 | 24,588 | 61,473 | 0 | 0 | 0 |
| 2 | 12,301 | 49,186 | 12,287 (19.99%) | 393,184 | **0.635%** |
| 4 | 6,157 | 43,042 | 18,431 (29.98%) | 589,792 | **0.953%** |

**So the unit gets 4x faster and the token gets about one percent faster.**
Both statements are true and only the second one is a result. The ceiling on
this lever is VEC_SWG's entire 3.18%, and a LANES change cannot reach even
that because 3N of the 5N is the adapter. Anyone choosing between LANES = 2
and LANES = 4 is choosing between 0.64% and 0.95% of a token, and should
weigh that against an UNMEASURED DSP and LUT cost (see "not synthesised"
below) on a part whose LUT budget is already the binding constraint.

This is this project's recorded "an exact relationship for one resource is
not a licence to scale a different resource by the same factor" in its other
direction: the unit's cycle count really is exactly `2 * N / LANES + 12 or
13`, verified at six points, and that exactness says nothing about what the
CARD does, because the card spends 60% of the step somewhere the generic
cannot reach.

## Correction 2: the WORKLOG entry for this track was committed by another track

`docs/WORKLOG.md`'s TRACK SWGFAST section was already in `HEAD` when this
second attempt started, and `git log -S "TRACK SWGFAST" -- docs/WORKLOG.md`
names **`11a4d6a "TRACK ACLK: the A clock-domain split contract and WORKLOG
entry"`** as the commit that added it, while the RTL it describes was still
uncommitted in the working tree. This is exactly the shared-file trap in
CLAUDE.md: a pathspec commit on a shared file captures the working tree, so
another track's in-flight WORKLOG edit went in under ACLK's message.

Recorded, **not amended**, per the same rule: amending rewrites another
track's tip and re-runs the race. The consequence worth knowing is that for
several hours the board advertised a LANES generic that was not in any
commit.

## The gap that was closed: the dumps predated the trials that stress the lanes

The identity evidence above (`cmp dump_base9b.txt dump_new9b_L2.txt`, 184,335
lines) is sound but was generated at 08:14-08:16, and
`sim/tb_swiglu_mem.vhd` gained `one_big0..3` and `one_big_last` at 08:31.
**The before/after `cmp` therefore used the OLD stimulus** -- the very trials
added to walk the max across every lane were not in the files being compared.
The tell was arithmetic: 184,335 = 15 x 12,289, i.e. 15 trials, where the
current bench runs 19.

Closed by re-running the whole matrix with the CURRENT bench in every arm
(`ident_matrix.sh`). The base arm is `git show HEAD:rtl/swiglu_mem.vhd`
driven by the current bench with the `LANES => LANES` map removed from the
DUT instantiation ONLY (the script fails if the `sed` matches nothing, so a
silently-unchanged base arm cannot pass unnoticed).

MEASURED:

```
===== N = 128 =====
b128  rc=0 :: SWGFAST_CYCLES 268 N=128 LANES=1   checks=3742 bad=0 live=22 rail=7 rdlat=1
l1128 rc=0 :: SWGFAST_CYCLES 268 N=128 LANES=1   checks=3742 bad=0 live=22 rail=7 rdlat=1
l2128 rc=0 :: SWGFAST_CYCLES 141 N=128 LANES=2   checks=3742 bad=0 live=22 rail=7 rdlat=1
l4128 rc=0 :: SWGFAST_CYCLES  77 N=128 LANES=4   checks=3742 bad=0 live=22 rail=7 rdlat=1
===== N = 12288 =====
b9b  rc=0 :: SWGFAST_CYCLES 24588 N=12288 LANES=1  checks=233492 bad=0 live=18 rail=1 rdlat=1
l19b rc=0 :: SWGFAST_CYCLES 24588 N=12288 LANES=1  checks=233492 bad=0 live=18 rail=1 rdlat=1
l29b rc=0 :: SWGFAST_CYCLES 12301 N=12288 LANES=2  checks=233492 bad=0 live=18 rail=1 rdlat=1
l49b rc=0 :: SWGFAST_CYCLES  6157 N=12288 LANES=4  checks=233492 bad=0 live=18 rail=1 rdlat=1
===== cmp (before/after, current stimulus) =====
IDENTICAL N=128 HEAD-unit vs LANES=1  (3741 lines)
IDENTICAL N=128 HEAD-unit vs LANES=2  (3741 lines)
IDENTICAL N=128 HEAD-unit vs LANES=4  (3741 lines)
IDENTICAL N=9b  HEAD-unit vs LANES=1  (233491 lines)
IDENTICAL N=9b  HEAD-unit vs LANES=2  (233491 lines)
IDENTICAL N=9b  HEAD-unit vs LANES=4  (233491 lines)
```

Six of six identical, at both shapes, by `cmp` on files. Note that the HEAD
unit passes the NEW trials too (18 live, 233,492 checks, bad=0), so those
trials are legitimate stimulus and not something tuned to the new RTL.

The cycle formula is exact, not fitted, at all six points:
`2 * N / LANES + 12` at LANES = 1 and `+ 13` above it. 2*128+12 = 268;
2*64+13 = 141; 2*32+13 = 77; 2*12288+12 = 24,588; 2*6144+13 = 12,301;
2*3072+13 = 6,157.

## The card accounting, re-derived independently

Re-read from `rtl/llama_top.vhd`'s `gsr` process without reference to the
account above. `S_RD` runs `k = 0 .. n+1` and switches `pass` at `k = n+1`,
so each of the G and U loads is `n+2` cycles; `S_GO` is one; `S_RUN` waits
on the unit's `done`; `S_WR` issues `o_ra` for `k < n` behind a two-deep
`rav`/`rav_d` pipeline and leaves on `kw = n-1`, so `n+2`.

DERIVED at n = 12288: `2*(12290) + 1 + 24588 + 12290 = 61459`, against the
card's **61,473**. Residual **14**.

THE CONTROL: VEC_NORM through the `gvr` adapter, which has the same six
states but one load pass (w is preloaded), at n = 4096 with the unit's
MEASURED `NORMFAST_CYCLES 3125`: `4098 + 1 + 3125 + 4098 = 11322` against
the card's **11,336**. Residual **14**, identical.

Two different ops, two different shapes, two different units, the same
14-cycle remainder. That is what makes the 3N/2N split attributable rather
than merely arithmetically consistent, and it is a control on the right
axis: the claim is about the ADAPTER, and the control varies the unit and
the shape while holding the adapter's shape fixed.

The profile is also uniform, which rules out a per-step average hiding
variance: all 32 VEC_SWG steps are exactly 61,473 and all 65 VEC_NORM steps
exactly 11,336 (`awk '$4=="VEC_SWG"{print $2}' ... | sort -u` gives one
line).

## The value oracle

`tools/ref9b/check_swg_real.py` (MEASURED, PASS, rc=0):

```
TABLE  sig_lut.mem vs fx_init() formula: 0 of 513 differ
C      eg= 14 eu= 13 n=4096  differ=2241  ... half-ties 2241, resize32 wraps 0, UNEXPLAINED 0
C      eg= 12 eu= 12 n=4096  differ=0     ... UNEXPLAINED 0
C      eg=  9 eu= 10 n=4096  differ=0     ... UNEXPLAINED 0
C      eg=  8 eu=  8 n=4096  differ=0     ... UNEXPLAINED 0
C      eg=  0 eu=  0 n=4096  differ=2046  ... resize32 wraps 2046, UNEXPLAINED 0
C      eg= 13 eu= 15 n=4096  differ=2130  ... half-ties 2130, UNEXPLAINED 0
C      eg= 16 eu= 14 n=4096  differ=1714  ... half-ties 1714, UNEXPLAINED 0
check_swg_real: PASS
```

**Read what this does and does not cover.** It anchors the PYTHON oracle
`vec_oracle.swg_real` to `ref/fx.h` + `ref/test_swiglu.c`; it does not
instantiate `rtl/swiglu_mem.vhd` and cannot see this change. The RTL-level
oracle is the bench's independent reference chain
`swiglu -> vec_mem(32) -> bfp_pack`, which shares no code with the DUT.
Its check 3, the 9B block-3 case, is opt-in behind `--r9bs` and **did NOT
run**: there is no `.r9bs` capture in the tree (`find . -name '*.r9bs'` is
empty). So the layer-3 correlation figures that check can produce are NOT
part of this evidence.

## Teeth, re-run, plus one new mutant and a SECOND attribution control

`sim/mutate_swiglu_mem.sh` re-run in full after adding **`bankswap`**, the
mutant the brief asked for that the first attempt did not have: the bank and
offset halves of the g write address EXCHANGED, so g word `i` lands in bank
`i / NB` at offset `i mod NB` instead of bank `i mod LANES` at offset
`i / LANES`. The off-by-one decode is the separate `bankdec` row; these are
different defects and both now fail by name.

19 mutants x 3 LANES = 57 rows, **0 NOSUB and 0 unexpected verdicts**.
Columns: FULL = all checks; noVAL = mantissa check off; noVL+EX = exponent
check also off; noALL = latency probe also off.

```
MUTANT     L   FULL    noVAL   noVL+EX noALL   VERDICT
baseline   1   rc=0 :: checks=3742 bad=0 live=22 rail=7 rdlat=1 :: SWGFAST_CYCLES 268
baseline   2   rc=0 :: checks=3742 bad=0 live=22 rail=7 rdlat=1 :: SWGFAST_CYCLES 141
baseline   4   rc=0 :: checks=3742 bad=0 live=22 rail=7 rdlat=1 :: SWGFAST_CYCLES  77
nosig    1/2/4 rc=1    rc=1    rc=1    rc=0    BITE
packrnd  1/2/4 rc=1    rc=0    rc=0    rc=0    BITE
raskew   1/2/4 rc=1    rc=1    rc=1    rc=0    BITE
convrnd  1/2/4 rc=1    rc=1    rc=1    rc=0    BITE
opswap   1/2/4 rc=1    rc=1    rc=1    rc=0    BITE
expswap  1/2/4 rc=1    rc=1    rc=1    rc=0    BITE
oexpsign 1/2/4 rc=1    rc=1    rc=0    rc=0    BITE
silush   1/2/4 rc=1    rc=1    rc=1    rc=0    BITE
nodrain  1/2/4 rc=1    rc=1    rc=0    rc=0    BITE
nosat    1/2/4 rc=0    rc=0    rc=0    rc=0    SURVIVES   <-- floor, kept
doneearly 1/2/4 rc=0   rc=0    rc=0    rc=0    SURVIVES   <-- floor, kept
wrot     1/2/4 rc=1    rc=1    rc=1    rc=0    BITE
bankdec    1   rc=0    rc=0    rc=0    rc=0    SURVIVES   (no-op at LANES=1)
bankdec    2   rc=1    rc=1    rc=1    rc=0    BITE
bankdec    4   rc=1    rc=1    rc=1    rc=0    BITE
rselskew   1   rc=0    rc=0    rc=0    rc=0    SURVIVES   (no-op at LANES=1)
rselskew   2   rc=1    rc=1    rc=1    rc=0    BITE
rselskew   4   rc=1    rc=1    rc=1    rc=0    BITE
bankswap   1   rc=0    rc=0    rc=0    rc=0    SURVIVES   (no-op at LANES=1)  NEW
bankswap   2   rc=1    rc=1    rc=0    rc=0    BITE                            NEW
bankswap   4   rc=1    rc=1    rc=0    rc=0    BITE                            NEW
lanemax    1   rc=0    rc=0    rc=0    rc=0    SURVIVES   (no-op at LANES=1)
lanemax    2   rc=1    rc=1    rc=0    rc=0    BITE
lanemax    4   rc=1    rc=1    rc=0    rc=0    BITE
p1lane     1   rc=0    rc=0    rc=0    rc=0    SURVIVES   (no-op at LANES=1)
p1lane     2   rc=1    rc=1    rc=0    rc=0    BITE
p1lane     4   rc=1    rc=1    rc=0    rc=0    BITE
wdlane     1   rc=0    rc=0    rc=0    rc=0    SURVIVES   (no-op at LANES=1)
wdlane     2   rc=1    rc=1    rc=1    rc=0    BITE
wdlane     4   rc=1    rc=1    rc=1    rc=0    BITE
smaxskip   1   rc=0    rc=0    rc=0    rc=0    SURVIVES   (no-op at LANES=1)
smaxskip   2   rc=1    rc=1    rc=0    rc=0    BITE
smaxskip   4   rc=1    rc=1    rc=0    rc=0    BITE

NOSUB or an unexpected verdict is a FAILURE of this script: 0
```

**The non-biting mutants, kept under their own names.** `nosat` and
`doneearly` survive at every LANES with every check on. They are the bench's
resolution floor, not oversights: `nosat` needs a mantissa that rounds to
exactly 32768, and `doneearly` needs a reader that samples the output on the
`done` edge, which this bench does not do because it reads long afterwards.
The nine `SURVIVES` rows at LANES = 1 are a different thing again -- those
mutations edit lines that are **not elaborated** at LANES = 1 (the decode is
in the `else generate`, `max_of` is never called, `S_MAX` does not exist), so
they measure the resolution floor of THAT CONFIGURATION rather than a missing
check. The script encodes this as the `L1SURV` expectation and fails if such
a row bites at LANES = 1 or survives above it.

### The second attribution control: which kills did the NEW TRIALS earn?

The four-column table above is the attribution control for the CHECKS. It is
not one for the new **trials**, which are what this track actually added to
the bench (`one_big0..3`, `one_big_last`). So a second control was run
(`attrib_trials.sh`): the same mutants against a copy of **HEAD's trial set**
with nothing changed but the `LANES => LANES` map on the DUT, so the lane
mutants are reachable at all.

```
MUTANT     L   OLDtrials  NEWtrials  ATTRIBUTION
bankdec    1   SURVIVES   SURVIVES   survives both (resolution floor)
bankdec    2   BITE       BITE       an older trial already caught it
bankdec    4   BITE       BITE       an older trial already caught it
bankswap   1   SURVIVES   SURVIVES   survives both (resolution floor)
bankswap   2   BITE       BITE       an older trial already caught it
bankswap   4   BITE       BITE       an older trial already caught it
rselskew   1   SURVIVES   SURVIVES   survives both (resolution floor)
rselskew   2   BITE       BITE       an older trial already caught it
rselskew   4   BITE       BITE       an older trial already caught it
lanemax    1   SURVIVES   SURVIVES   survives both (resolution floor)
lanemax    2   BITE       BITE       an older trial already caught it
lanemax    4   SURVIVES   BITE       THE NEW TRIALS EARNED THIS KILL
p1lane     1   SURVIVES   SURVIVES   survives both (resolution floor)
p1lane     2   BITE       BITE       an older trial already caught it
p1lane     4   BITE       BITE       an older trial already caught it
wdlane     1   SURVIVES   SURVIVES   survives both (resolution floor)
wdlane     2   BITE       BITE       an older trial already caught it
wdlane     4   BITE       BITE       an older trial already caught it
smaxskip   1   SURVIVES   SURVIVES   survives both (resolution floor)
smaxskip   2   BITE       BITE       an older trial already caught it
smaxskip   4   BITE       BITE       an older trial already caught it
nodrain    1   SURVIVES   BITE       THE NEW TRIALS EARNED THIS KILL
nodrain    2   SURVIVES   BITE       THE NEW TRIALS EARNED THIS KILL
nodrain    4   SURVIVES   BITE       THE NEW TRIALS EARNED THIS KILL
```

**Of 24 rows the new trials earned exactly FOUR kills**: `nodrain` at all
three LANES, and `lanemax` at LANES = 4. Every other lane mutant was already
caught by an older random trial, so five of the six lane mutants would have
been killed without any of this track's bench work.

This confirms the first attempt's account rather than inflating it. It is
worth stating the unflattering half plainly: the honest yield of the added
trials is `nodrain` (a check that had existed since 2026-09-19 and had never
once discriminated) plus one configuration of `lanemax`. That is a real
result -- `nodrain` guards a genuine defect and was decoration until now --
but it is four rows, not twenty-four.

## Measured and REJECTED, do not retry

Everything in the first attempt's REJECTED list stands. Added:

- **Do not quote the unit's speedup as the card's.** "LANES = 4 makes the
  SwiGLU 4x faster" is true of `SWGFAST_CYCLES` and false of anything the
  card does. The measured ceiling for the whole op is 3.18% of a token and
  the reachable part is 0.95%. Rejected as a headline, not as a change.
- **Do not `cmp` dumps from two different bench versions.** The first
  attempt's 9B dumps were made at 08:14 and the trials that stress the lanes
  were added at 08:31, so the comparison silently used the weaker stimulus.
  It still PASSED and looked complete. The only tell was that
  184,335 / 12,289 = 15 trials where the bench now runs 19.
- **Do not put backticks in a bash array element.** MEASURED here: the new
  `bankswap` row's description contained `` `bankdec` `` inside a
  double-quoted array element, which bash ran as command substitution
  (`bankdec: command not found`) at array-assignment time. The table still
  built, with the word silently deleted. Caught by reading the run's first
  line; `grep -n '`' sim/mutate_swiglu_mem.sh` is the check and is now clean.

## Measurement traps hit in THIS pass

- **The inherited evidence was right and its stimulus was stale.** Every
  `cmp` the first attempt reported is reproducible today, byte for byte
  (`md5sum` puts all three 128-element dumps in one class and both 9B dumps
  in another). Nothing was wrong. The gap was in what the files covered, and
  no amount of re-running THOSE files would have shown it -- only counting
  the lines against the trial count did. **Re-verifying an artefact does not
  verify that the artefact tests what you now claim.**
- **A completed background job is not a correct one.** The first mutation
  re-run reported a full, plausible table with the backtick error sitting in
  line 1 of the log above the header. The table was not wrong, but the run
  was stopped and redone rather than reported, because "the error is probably
  harmless" is not a measurement.
- **Two Vivado processes were resident on this box for this track's whole
  duration** (`/proc/PID/exe` census: two under
  `/tools/Xilinx/2023.2/.../unwrapped/lnx64.o/vivado`, another track's card
  build). No Vivado was started here. GHDL peaked under 800 MB per process
  and at most three tiny N = 128 runs plus one N = 12288 run overlapped;
  `free` never showed less than 10 GiB available.
- **`kill` by PID, from the launch, never by pattern.** The stopped mutation
  run was ended with `kill 2803357`; the surviving GHDL processes were then
  identified by `readlink /proc/PID/exe` and two of the three turned out to
  belong to OTHER tracks (`benable`, `aclk`) and were left alone. A
  `pkill -f ghdl` would have killed both of them.

## Open, NOT determined

- **NOTHING HERE HAS BEEN SYNTHESISED.** No Vivado ran for this change at
  any LANES, by instruction (one lane is on another track's card build, the
  other is on the BC-250). `sim/ooc_swgmem_run.sh`'s only draw is
  `"N=12288 Q=12"`, and the area figures in
  `hw/fk33/results/swgmem_2026-09-19/result_swg_mem.csv` (16 DSP, 2,493 LUT,
  319 FF, 19.5 BRAM, WNS -3.669) are the **pre-change** unit. So: the area
  and timing at LANES = 2 and 4 are ESTIMATE, **and even LANES = 1 has not
  been re-drawn since the RTL changed**. The elaboration pins and the
  null-slice `o_raddr(LB-1 downto 0)` at LANES = 1 are exercised by GHDL
  only; CLAUDE.md's record of packager and synthesis errors that no bench can
  reach applies directly.
- **The card is unchanged and will stay unchanged** until
  `rtl/llama_top.vhd` maps the generic. Verified today that the hand-off
  diff in the section above still matches the file: `NORM_LANES` is declared
  at line 378, `u_swg`'s `generic map(N => NN, Q => 12)` is at line 3634, and
  `hw/fk33/gen_fk33_card.py` line 226 is the `SWG_REAL=true` generic.
  `rmsnorm_bf_mem` is already instantiated with `LANES => NORM_LANES` at
  line 2733, so the pattern is the file's own.
- **Whether LANES = 4 fits the LUT budget.** Unmeasured, and the reason to
  prefer LANES = 2 if a build is attempted at all, given that the whole
  lever is worth under one percent of a token.
- **`check_swg_real.py`'s 9B block-3 case did not run** (no `.r9bs` capture
  in the tree), so the layer-3 correlation against the reference is not part
  of this evidence.
- **The 3N of adapter traffic** is untouched and is the larger half. The
  three candidate levers are listed above and all live in `rtl/llama_top.vhd`
  or the sequencer, which this track does not own.
