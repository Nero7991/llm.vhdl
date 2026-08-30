# Can `rmsnorm_rs`'s 1024:1 read muxes become a memory, bit-exactly, and what does it cost?

**Date:** 2026-08-30
**Track:** RMSMUX
**Tree:** parent commit `e92cfe8`; this track's four files landed as
`ce7b836`. `rtl/llama_top.vhd` was MODIFIED and uncommitted throughout
(TRACK NORMURAM) and was never touched by this track.
**Tools:** GHDL (mcode) only. **No Vivado ran.** **No hardware was touched** --
no `xsdb`, no `hw_server`, no `program_hw_devices`, nothing under
`hw/fk33/host` or `hw/fk33/tcl`, nothing opening `/dev/xdma*`.
**Scratch:** `/mnt/storage/rmsmux`. Nothing was written to root.

---

## 1. The question, verbatim

> **`d_norm/gvr.u_rms` in `rmsnorm_rs`: two 65,536-bit flat vectors, 131,072 FF
> plus 43,213 LUT of 1024:1 read muxes, and 17,696 MUXF7** (MEASURED, TIMING's
> `TT_MUX` census). [...] **`d_norm` alone beats lever C alone by 13.7 points.**
> [...]
> 1. **What those two 65,536-bit vectors actually are and why they are flat**,
>    before proposing anything. [...] If the flatness is load-bearing (single-
>    cycle random access, a fanout fix, a timing requirement), URAM's read
>    latency breaks it and you must say how that is absorbed.
> 2. **The change**, with the arithmetic bit-for-bit unchanged.
> 3. **The oracle, at the level of the OUTPUT.** [...] A round trip is not an
>    oracle.
> 4. **A latency statement.** [...] Say exactly what absorbs it, and whether any
>    handshake or seam moves.
> 5. **Area, drawn TWICE, reported as a RANGE.**
> 6. **Teeth, with the attribution control.**

---

## 2. The answer, up front

**The flatness is NOT load-bearing, the latency is absorbed by a register the
file already has, and `done` does not move by one cycle.** MEASURED, not
argued: `rtl/rmsnorm_rs_mem.vhd` is bit-exact with `rtl/rmsnorm.vhd` element for
element AND fires `done` on the **same cycle** as `rmsnorm_rs`, over 10
non-degenerate trials at each of **8 (N, LANES) configurations** including
`LANES = 1` and `LANES = 16`.

### THIS TRANSFORM ALREADY EXISTED. READ TRACK LUTDIET FIRST.

Put first because it is the single most useful thing to know before scheduling
this lever, and because the brief that dispatched this track said the opposite.

**TRACK LUTDIET built and MEASURED a `rmsnorm_rs_mem` on 2026-08-29.** The
artefacts have been in the repo the whole time, at
`hw/fk33/results/lutdiet_2026-08-29/`, with the write-up at
`docs/debugging/2026-08-29_lutdiet-flat-vector-ports.md`. Verbatim from
`result_mem_n4096.csv` and `result_hotw_n4096.csv`, `xcvu33p-fsvh2104-2L-e`,
5.0 ns, `-mode out_of_context -flatten_hierarchy none`:

    rmsnorm_rs_mem, N=4096 LANES=4:  dsp 40  lut 4798   ff 1700   ramb18 12
                                     bram_tile 6  uram 0  f7 0      f8 0
                                     wns +0.971  fmax 248.2 MHz  synth 21 s
    rmsnorm_rs_hotw,N=4096 LANES=4:  dsp 40  lut 40804  ff 67267  bram_tile 0
                                     uram 0       f7 17408  f8 8704
                                     wns +1.675  fmax 300.8 MHz  synth 74 s

and `census_rmsnorm_rs_mem.txt`, top roots, verbatim:

    root                                     LUT   MUXF7   MUXF8       FF  CARRY8
    o_wd                                    1101       0       0       64      32
    max_raw                                 1047       0       0       63      56
    rq_shifted                               519       0       0       64       2
    ARG                                      443       0       0        0      11
    shifted_r                                405       0       0       64       0

**`ARG` -- the read of `x_mant` and `w_mant` -- falls from 17,916 LUT to 443,
there is no `sq` root at all, and MUXF7 and MUXF8 are both ZERO.** That is the
mechanism this lever rests on, already measured on the real part, with a
three-mutant teeth check and a GHDL bit-exactness proof, a day before this
track was dispatched.

**What this track adds, and it is deliberately narrow:** the transform
re-derived onto the post-WRITEDEC base (LUTDIET's was pre-WRITEDEC and has been
superseded by `51323ca`); a combinational output write path so `done` does not
move at all, where LUTDIET's registered form cost a cycle; `LANES = 1` support;
an oracle against `rtl/rmsnorm.vhd` rather than against `rmsnorm_rs`; a
three-column attribution control; and a unit that lives in `rtl/` and is a gate
row, where LUTDIET's was explicitly a measurement artefact outside `rtl/`.

**THE FALSE PREMISE WAS IN THE DISPATCH, NOT IN LUTDIET'S WORK.** The brief for
this track stated "Nobody has been working on it". LUTDIET had, had measured it,
and had left the numbers in the repo under a clear README. This is recorded here
because it is the second false premise about prior work handed to a track on the
same day, and the cost of the class is duplicated tracks rather than wrong
numbers. **The cheap check is `ls hw/fk33/results/` and a grep of
`docs/debugging/` for the unit's name before writing a brief.**

**Four things this track establishes:**

**(a) The two vectors are not both inside the unit, and my brief was wrong
about that.** TIMING's own numbers say so: `gvr.u_rms` is **67,384 FF** and
`d_norm` as a whole is **133,607 FF**. So one 65,536-bit vector is `u_rms`'s
own `o_reg`, and the other is **`gvr.xw`, the adapter's input staging register
in `rtl/llama_top.vhd`** -- a different file, owned by a different track. This
lever is two changes in two files, not one.

**(b) The flat ports are INHERITED, not required.** `rmsnorm_rs` exists to be a
drop-in for `rtl/rmsnorm.vhd`, whose ports are flat. Nothing in the file's
header, its three recorded optimisation notes or its commit history claims the
flat read buys anything. What the header DOES record is the opposite: the fetch
was **deliberately given its own register** because "putting it in the same
stage as the multiply made idx -> mux -> DSP the critical path at 257.0 MHz".
`xa`/`xf`/`wf` exist to spend a cycle on the fetch. **A block RAM's output
register is that cycle.** The substitution is one-for-one and no pipeline stage
is added or removed.

**(c) The compute schedule is unchanged, cycle for cycle, and so is `done`.**
MEASURED at N=128 LANES=4: `rmsnorm_rs` 148 cycles, `rmsnorm_rs_mem` 148
cycles, on every one of 12 trials. This CORRECTS TIMING section 8's "not
latency-neutral -- a URAM read is registered, so every element access gains
cycles and the unit's internal schedule has to absorb them". It does not,
because the schedule already had the cycle. The only new latency is **one
priming cycle on the output readout, once per operation, not once per word**.

**(d) Every kill in the mutation table belongs to the VALUE comparison against
an independent implementation.** Six of ten mutations bite. With the value
check disabled and the latency probe disabled -- leaving the done-cycle
comparison and the non-degeneracy gate, i.e. every *structural* check -- **five
of those six survive.** That is this project's through-line measured again on a
new unit: structure is not values.

**What is NOT established: any area number.** No Vivado ran. Both lanes were
held (TIMING on the workstation, TWOCARD on the BC-250) and the brief said to
ask rather than start a third. Section 8 states the DERIVED prediction and what
would falsify it, so the draws when they happen are a test rather than a
measurement of an unstated expectation.

---

## 3. Corrections to the brief and to TIMING

| claim | verdict |
|---|---|
| `gvr.u_rms` is "43,213 LUT, 17,696 MUXF7, 8,736 MUXF8, 67,384 FF" | **CONFIRMED**, quoted from TIMING's own census and used as given |
| `d_norm/gvr.u_rms` is "43,213 LUT ... plus 131,072 FF of vector held in flops" | **CORRECTED.** Only 67,384 FF are in `u_rms`. The other 65,536 are `gvr.xw` in `rtl/llama_top.vhd`. The row conflates an instance with its parent, and it matters because the two halves have different owners |
| "1 URAM288 per 4096x16 vector ... URAM is at 0 of 320" | **TRUE BUT NOT WHAT THE CHANGE NEEDS.** LUTDIET MEASURED the identical transform landing in **6 BRAM tiles** with the repo's existing `rtl/vec_mem.vhd`, against **425.5 free BRAM tiles**. URAM is not required and was not used. The 320 idle URAM remain idle |
| TIMING 8: "not latency-neutral -- every element access gains cycles and the unit's internal schedule has to absorb them" | **CORRECTED, MEASURED.** `done` fires on the same cycle. The schedule already contained the fetch register the RAM's output register replaces |
| TIMING 12a: "hardest of the three; interface redesign ... a unit that is instantiated by B, C and D" | **CORRECTED IN SCOPE.** `rmsnorm_rs` is UNCHANGED. `rmsnorm_rs_mem` is a new entity, so every existing instantiation in B, C and D is untouched and the blast radius is exactly whoever instantiates the new one |
| "`rmsnorm_rs` has never run on silicon" | **CONFIRMED.** `docs/debugging/2026-08-30_a-whole-token-on-the-silicon.md` section on what did not run: "The 64 RMS norms, the final norm ... ran on the **host**." Restated in section 10 with what it does and does not buy |
| TIMING's 43,213 LUT for `gvr.u_rms` is the baseline this lever comes off | **QUALIFIED, and it is the most important qualification in this document.** `hw/fk33/rtl/compose4_top.vhd` line 19 states it outright: **"NORM_W_IMAGE IS EMPTY HERE, as it was in every row of the booking"**, and `sim/ooc_normadapt_extract.py` defaults it to `""`. So the composed draw measured `u_rms` with `w_mant` driven by a register whose only value is the elaboration-time constant `W_CONST`. TRACK NWFIX MEASURED that configuration difference **on this exact port at 17,367 LUT**. The design that has to fit has a REAL gain image. See section 8. ACCEPTED by the coordinator, who is carrying it into the fit table; TRACK NORMURAM reached the same fold from the opposite direction, which is two independent arrivals at one number |
| "nobody has been working on it" | **FALSE, and the error is the DISPATCH's rather than a gap in the repo.** TRACK LUTDIET built and MEASURED `rmsnorm_rs_mem` on 2026-08-29 and left it at `hw/fk33/results/lutdiet_2026-08-29/` with a README, a census, a bit-exactness log and a three-mutant teeth check: **299,030 -> 4,798 CLB LUT**, F7 and F8 to zero, for +6 BRAM tiles. See the block at the head of section 2. **The prior art halves the risk of this lever and must be read before it is scheduled.** ACCEPTED by the coordinator, who has recorded the false premise under their own name |

---

## 4. What the two vectors are, and why they were flat

Read off the RTL, not off a document.

| the vector | where it lives | what it is | who owns the file |
|---|---|---|---|
| `x_mant`, 65,536 bits | a **port**, driven by `gvr.xv`, a concurrent flat view of the register array `gvr.xw` (`rtl/llama_top.vhd`) | the residual-stream vector, filled ONE WORD PER CYCLE from the region file | TRACK NORMADAPT / NORMURAM |
| `w_mant`, 65,536 bits | a **port**, driven by `gvr.wsel`, which in the populated branch is a rename of `gwm.wreg`, a 65,536-bit SHIFT REGISTER loaded one word at a time from a URAM ROM | the learned gain | TRACK NORMURAM |
| `o_reg`, 65,536 bits | **inside** `rmsnorm_rs` | the output register | this track |

So the "two 65,536-bit vectors held in flops" attributed to `u_rms` are in fact
`gvr.xw` (parent) and `u_rms.o_reg` (unit), and in the populated-gain build
there is a **third**, `gwm.wreg`, which TIMING's `d_norm` FF total does not
separate out.

**Why flat.** `rmsnorm_rs.vhd`'s opening line is "Integer RMSNorm, BIT-EXACT
with rtl/rmsnorm.vhd, made fast enough to use", and `rtl/rmsnorm.vhd`'s ports
are flat `std_logic_vector(N*16-1 downto 0)`. The port shape is inherited from
the unit this one replaces. It is the project-wide convention for "a whole
vector at once" and it is also what `l2norm_rs` and `rmsnorm_bf` use.

**Is it load-bearing?** No, and the file itself is the evidence. Three separate
notes in `rmsnorm_rs.vhd` record measurements about the fetch, and every one of
them says the fetch wanted MORE latency, not less:

    -- FETCH stage.  Selecting one element out of the N*16 bus is a 128-to-1
    -- mux (MUXF7/MUXF8), and putting it in the same stage as the multiply made
    -- idx -> mux -> DSP the critical path at 257.0 MHz.  Registering the fetch
    -- separates the mux from the multiplier and gives the multiply registered
    -- operands, which is also what a DSP AREG/BREG wants.

and in `S_ACC`:

    -- Three stages for the same reason the element passes have them:
    -- fused, this was idx -> 128:1 mux -> DSP square -> 64-bit
    -- accumulate in one cycle, and it measured as the critical path at
    -- 260.1 MHz once everything ahead of it had been split.

**That register is exactly what a block RAM's output register is.** Same
one-cycle latency, same address source, same consumer. `x_q`/`w_q` replace
`xa`/`xf`/`wf` one for one.

**And TIMING's own timing evidence points the same way**: only 3 memory cells
appear among the 3,000 worst paths, so this structure is not timing-critical
today. That is a statement about today's implementation, so the schedule claim
here is made from cycle counts (MEASURED) and not from that.

**One thing the flatness IS load-bearing for, and it is not a timing property.**
`rmsnorm_rs.vhd`'s header FORBIDS storing `raw[j]` in an indexed array, because
"a 64x64 indexed array was inferred as UNINITIALIZED distributed RAM in the
congested engine and produced NON-DETERMINISTIC hardware output". **That ban is
about an INFERRED distributed RAM with no initial value.** `rtl/vec_mem.vhd`
carries `attribute ram_style ... is "block"` and an initialiser, and was added
on 2026-07-27 for this exact trade on `swiglu`/`bfp_pack`. `raw[j]` is still
recomputed here and is not stored. The ban is respected, not worked around.

---

## 5. The change

`rtl/rmsnorm_rs_mem.vhd`, a NEW entity. `rtl/rmsnorm_rs.vhd` is unmodified.

Three flat ports become word streams into and out of `LANES`-way banked
`vec_mem`. Word `i` lives in bank `i mod LANES` at offset `i / LANES`, which is
the order the three element passes already walk it.

    x_we / x_waddr / x_wdata      write stream in   (replaces x_mant)
    w_we / w_waddr / w_wdata      write stream in   (replaces w_mant)
    o_raddr / o_rdata             read stream out   (replaces o_mant)

Everything else is character-identical to `rmsnorm_rs`: every width, every
rounding site, every shift, the accumulation order, the S_INV split, the Newton
cadence, the MREG idiom, the narrowing assertions and the state machine.

It was derived by a **fixed list of 14 named substitutions** that aborts if any
one fires the wrong number of times, so the transform is the diff. **The script
is not the ongoing guard** -- `docs/debugging` already records the defect class
where "three `util_pkg.vhd` copies regenerated by a script nothing schedules"
counted as a check. **The ongoing guard is the gate row**, which compares the
two files' outputs on every run.

**Two deliberate departures from LUTDIET's prototype:**

1. **The output write path stays COMBINATIONAL.** LUTDIET registered
   `o_we`/`o_wa`/`o_wd` and had to add `and o_we = '0'` to the completion
   condition, costing one cycle on `done`. TRACK WRITEDEC had already made
   `o_wd` combinational in the shipping file for exactly the reason that `done`
   is what the top level and the pinned sequencer landmarks wait on. Keeping it
   combinational means the bank write lands on the same rising edge the flat
   register write used to and **`done` does not move at all**. The `rst = '0'`
   term in WRITEDEC's guard is carried over verbatim.
2. **`LANES = 1` works.** The bank index is a zero-width slice at `LANES = 1`,
   which is a null-range comparison; a `LANES = 1` / `LANES > 1` conditional
   generate handles it, and `LANES = 1` is one of the eight configurations in
   the sweep. `rmsnorm_rs` documents `LANES = 1` as "the fallback", so a
   variant that silently could not elaborate at it would be a trap.

---

## 6. The oracle, and why it is not a round trip

**The DUT writes its input into a RAM and reads its output out of one**, so a
bench that checked "what went in came out" would pass a packer plus a reversed
decoder -- this project's recorded `m7 mutant`. So nothing here is a round
trip.

`sim/tb_rmsnorm_rs_mem.vhd` instantiates **three** units on the same stimulus:

* **`rtl/rmsnorm.vhd`** -- the GOLDEN. An independently written flat
  implementation of the same arithmetic, itself asserted bit-exact against
  `rmsnorm_fx()` in `ref/run_fx.c`. It shares no storage, no addressing and no
  indexing with the DUT. **Every value comparison in this bench is against
  this**, at the level of the unit's OUTPUT.
* **`rtl/rmsnorm_rs.vhd`** -- the shipping sibling. The DUT's contract is to be
  a drop-in for it, and the two are separately maintained files, so a drift
  between them has to be caught at every gate run rather than at the next area
  draw.
* the DUT.

Four things are checked, and the non-value ones exist because a value check
alone passes a rewrite that moved the schedule:

1. **Values**, element for element, DUT read out one word at a time through
   `o_raddr`/`o_rdata`, against the golden.
2. **`o_exp`**, per trial.
3. **The CYCLE `done` fires on**, DUT against `rmsnorm_rs`, exactly.
4. **The read latency of `o_raddr` -> `o_rdata`**, MEASURED in edges rather
   than assumed.

**NON-DEGENERACY IS A HARD FAILURE.** LUTDIET MEASURED three of its six trials
producing an all-zero output from `rmsnorm_rs` ITSELF -- the unit has a silent
all-zeros rail outside its 19-octave reciprocal window -- and two all-zero
vectors compare equal. Twelve trials run here; each is classified, a trial on
the rail is reported **under its own name** and is not counted as evidence, and
the run FAILS unless at least 9 were non-degenerate. Two land on the rail every
time: `all_zero` (by construction) and `rand_wide`.

**Stimulus classes**, chosen for the sites where a narrowing or a reordering
could differ, not to be a broad random sweep: mid-scale random; saturated
`+-32767/-32768` (which is what licenses the s48 narrowing); one large element
against zeros (so `max|raw|` comes from ONE lane); all-zero (the `mean_sq_q < 1`
clamp and the rsqrt's degenerate path); both signs of `x_exp`; powers of two
(so `max|raw|` lands on a bit boundary); **a ramp** and **a bank-aligned ramp**,
which are the two cases a permuted or off-by-one readout passes on random data
and fails visibly on; **a per-element gain**, because every other trial uses a
constant `w` and would mask a w-side bank fault; and two further random draws.

---

## 7. The evidence, as raw output

### 7.1 The gate row

    PASS       sim:tb_rmsnorm_bf      7s  ... bit-exact with the C reference on all 20
    PASS       sim:tb_rmsnorm_rs      3s  ... random, xe=8: bit-exact  (ref 651 cycles, rs 148)
    PASS       sim:tb_rmsnorm_rs_mem  2s  ... RMSMUX PASS: rmsnorm_rs_mem is bit-exact with rm
    PASS       tb:tb_rmsnorm          0s  ... PASS:rmsnorm  max_dev=1
     OVERALL     PASS 4   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 1

`REGRESS_SCRATCH=/mnt/storage/rmsmux/regress bash sim/regress.sh --only rmsnorm`.
**This is FOUR rows of a 99-row gate, not the gate.** `BASELINE_PASS` has not
been re-established since `845ea28` and was not re-established here; both Vivado
lanes were held and a full gate run on a contended box produces failures in
files no track touched.

### 7.2 The full bench, default generics (N=128, LANES=4)

    RMSMUX live rand_mid  o_exp 13 nonzero 128/128 done_cyc 148
    RMSMUX live sat       o_exp -19 nonzero 128/128 done_cyc 148
    RMSMUX live one_big   o_exp 11 nonzero 1/128 done_cyc 148
    RMSMUX RAIL all_zero: output is all-zero or constant, so this trial proves nothing about the values
    RMSMUX live xexp_pos  o_exp 13 nonzero 128/128 done_cyc 148
    RMSMUX live xexp_neg  o_exp 12 nonzero 128/128 done_cyc 148
    RMSMUX live pow2      o_exp 13 nonzero 128/128 done_cyc 148
    RMSMUX live ramp      o_exp 14 nonzero 128/128 done_cyc 148
    RMSMUX live bankramp  o_exp 14 nonzero 128/128 done_cyc 148
    RMSMUX live wvary     o_exp 13 nonzero 128/128 done_cyc 148
    RMSMUX RAIL rand_wide: output is all-zero or constant, so this trial proves nothing about the values
    RMSMUX live latref    o_exp 14 nonzero 128/128 done_cyc 148
    RMSMUX SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    RMSMUX PASS: rmsnorm_rs_mem is bit-exact with rmsnorm and with rmsnorm_rs, on the same cycle, over 10 non-degenerate trials

`done_cyc 148` on every trial, and `sim/tb_rmsnorm_rs`'s own line above reads
`(ref 651 cycles, rs 148)`. **The memory-backed unit is on the shipping unit's
cycle, not the behavioural model's.**

### 7.3 The generic sweep

`rmsnorm_rs.vhd`'s own header records a lane-reduction bug that "happened to
pass at 2, 4 and 8 on the test vectors and failed at 16, which is the whole
argument for sweeping the generic instead of testing one value". So it is swept.

    N=128 LANES=1  rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    N=128 LANES=2  rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    N=128 LANES=4  rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    N=128 LANES=8  rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    N=128 LANES=16 rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    N=256 LANES=4  rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    N=256 LANES=8  rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    N=64  LANES=4  rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1

### 7.4 The mutation table, WITH the attribution control

`bash sim/mutate_rmsnorm_rs_mem.sh`. Column FULL is the whole bench; `noVAL`
disables the value comparison; `noVL+LT` disables the value comparison AND the
latency probe, leaving only the done-cycle comparison and the non-degeneracy
gate -- the genuinely structural checks.

    MUTANT         FULL    noVAL   noVL+LT VERDICT   WHAT
    baseline rc=0 :: SUMMARY live 10 rail 2 fails 0 read_latency_edges 1
    bankswap       rc=1    rc=1    rc=0    BITE      x bank index taken from the HIGH bits of the word index
    addroff        rc=1    rc=1    rc=0    BITE      output bank write address off by one
    selxor         rc=1    rc=1    rc=0    BITE      read-side lane select perturbed
    raskew         rc=1    rc=1    rc=0    BITE      the element-pass read address advanced by one
    wbank          rc=1    rc=0    rc=0    BITE      w bank enable driven from x_waddr (copy-paste class)
    owe_norst      rc=0    rc=0    rc=0    SURVIVES  WRITEDEC's rst term dropped from the output write guard
    xwswap         rc=0    rc=0    rc=0    SURVIVES  x and w exchanged in the emit multiply
    obank_hi       rc=1    rc=0    rc=0    BITE      output READ transposed, bank and offset, on the read side ONLY
    doneearly      rc=1    rc=1    rc=1    BITE      done fires one cycle EARLY, values untouched
    transpose_all  rc=0    rc=0    rc=0    SURVIVES  bank and offset transposed CONSISTENTLY on x, w and o

**What the control says, and it is the point of running it.**

* **Six mutations bite. Five of the six die in the `noVL+LT` column only when
  the value check is ON.** The done-cycle comparison and the non-degeneracy
  gate, run alone, let `bankswap`, `addroff`, `selxor`, `raskew`, `wbank` and
  `obank_hi` through. **Every real kill belongs to the comparison against an
  independent implementation.**
* **The latency probe is a value check in disguise, and the control found
  that.** With `CHK_VAL` off, `bankswap`, `addroff`, `selxor` and `raskew`
  still died -- but of the latency assertion, because that probe matches
  `o_rdata` against one golden element. It is not an independent check and it
  is not credited as one. That is why the third column exists.
* **`doneearly` is the one mutation the structural checks catch alone**, and it
  was planted for exactly that purpose: values are untouched (0 value
  mismatches in its log) and only the cycle moves, 148 -> 147. Without it the
  done-cycle check would be a checker never shown to fail.

### 7.5 Mutations that do NOT bite, under their own names

These are the resolution floor and none is discarded.

**`transpose_all` -- NOT A DEFECT.** Transposing bank and offset consistently
on x, w AND o is **functionally equivalent**, and the reason is structural
rather than accidental: pass 1 reduces by an exact integer sum and pass 2 by a
maximum, both order-independent (`rmsnorm_rs.vhd` says so and it is what makes
LANES bit-exact in the first place), and the x/w pairing and the o placement
are preserved because all three use the same split. **So the bank/offset split
is a free choice, provided all three memories share it.** That is worth knowing
before anyone "fixes" it.

**`xwswap` -- NOT A DEFECT.** `p1_xinv <= w_q * inv32` with `p1_wm <= x_q`
computes `(w*inv)*x` instead of `(x*inv)*w`. Integer multiplication is
commutative and the products are exact, and both narrowings still hold
(`|w| < 2^15`, `|inv| < 2^31` so `|w*inv| < 2^46` inside the s48; `|x| < 2^15`
inside the s17). Bit-identical. **The expectation in the mutation list was
wrong and is corrected there rather than deleted.**

**`owe_norst` -- A GENUINE GAP, and it is not closable at this boundary.**
Dropping TRACK WRITEDEC's `rst = '0'` term lets one spurious word be written on
the cycle `rst` is taken. This bench never resets mid-operation, so it does not
see it -- **but adding a mid-operation reset would not close it either**,
because the next complete pass rewrites every word before anything reads the
output. The fault is unobservable at the unit's output boundary by ANY bench
that only observes completed operations, and that is equally true of the
original `gow` guard in `rmsnorm_rs`. **WRITEDEC's `rst` term is defensive
rather than observably load-bearing here.** Listed in section 11.

---

## 8. Area: the DERIVED prediction, and what would falsify it

**No Vivado ran.** Stated first so nothing below reads as a measurement.

The prediction is DERIVED from a **census** and not fitted to a point, which is
the discipline `e92cfe8` was written to enforce.

MEASURED by TRACK LUTDIET, `census_hotw_n4096.txt`, N=4096 LANES=4, on a base
with the write decode already fixed -- i.e. the shape of the shipping
`rmsnorm_rs`:

| census root | what it is in the RTL | LUT | MUXF7 | MUXF8 |
|---|---|---:|---:|---:|
| `ARG` | the x and w reads in `S_RAW`/`S_EMIT` | 17,916 | | |
| `sq` | the x read in `S_ACC` | 17,474 | | |
| read muxes together | | **35,390** | **17,408** | **8,704** |
| write decode after WRITEDEC | | 1,052 | 0 | 0 |
| everything else: rsqrt, Newton, encoders, saturation, FSM | | ~3,987 | | |
| `rmsnorm_rs_hotw` total | | 40,804 | 17,408 | 8,704 |

MEASURED by TRACK TIMING in the composed placement: `d_norm/gvr.u_rms` =
43,213 LUT, 17,696 MUXF7, 8,736 MUXF8, 67,384 FF.

**THE TWO MEASUREMENTS ARE NOT THE SAME EXPERIMENT, AND THE PREDICTION IS
STATED AGAINST THE STANDALONE ONE.** `compose4_top.vhd`'s own header says
`NORM_W_IMAGE` is EMPTY in every row of that booking, so in the composed draw
`w_mant` is driven by a register whose only value is the elaboration-time
constant `W_CONST` -- and TRACK NWFIX MEASURED that Vivado's fold of exactly
that port is worth **17,367 LUT**. LUTDIET's 40,804 was drawn with both flat
vectors as genuine top-level ports, which is the apples-to-apples control for a
standalone OOC draw of `rmsnorm_rs_mem`, so **40,804 is the number to compare
against and 43,213 is not.**

That the composed draw is *larger* than the standalone one despite having a
foldable `w_mant` is not explained here and is listed as open. It cuts in the
direction that matters, though: **in the shipping configuration the gain is a
real, token-varying register, `w_mant` cannot fold, and `u_rms` is therefore at
least as large as 43,213 and probably larger.** TIMING's fit-table row for this
lever is a floor for the same reason its LUT total is.

**DERIVED:** the standalone read muxes account for 17,408 of the composed
draw's 17,696 MUXF7 (**98.4%**) and 8,704 of its 8,736 MUXF8 (**99.6%**). So
essentially the WHOLE of `u_rms`'s F7/F8 population is the two read muxes, and
the transform takes them to **zero** -- LUTDIET measured exactly that,
`F7 17,408 -> 0` and `F8 8,704 -> 0`, on the same transform.

**PREDICTION (DERIVED), to be tested by two draws at N=4096 LANES=4:**

| quantity | `rmsnorm_rs` today | `rmsnorm_rs_mem` predicted |
|---|---:|---:|
| CLB LUT | **40,804 standalone** (the control); 43,213 composed, different gain config | **4,800 .. 8,000** |
| MUXF7 | 17,696 | **0** |
| MUXF8 | 8,736 | **0** |
| CLB FF | 67,384 | **~1,700** |
| BRAM tile | 0 | **6** |
| DSP | 40 | **40** |

The LUT band's lower end is LUTDIET's measured 4,798 for its variant; the upper
end is `43,213 - 35,390 = 7,823`, i.e. the LARGER of the two baselines with only
the two census roots removed, which makes the band deliberately generous rather
than tight. This unit differs from LUTDIET's in keeping the output
write path combinational, which removes three registers and adds none.

**WHAT WOULD FALSIFY IT.** (i) A draw with MUXF7 materially above zero: the
census attribution of F7 to the read muxes is then wrong. (ii) A LUT draw
materially above 8,000: something other than the two census roots scaled with
the port width and was missed. (iii) DSP moving off 40: the transform touched
arithmetic, which it must not.

**IT MUST BE DRAWN TWICE AND REPORTED AS A RANGE.** TRACK SCATTER MEASURED
82,597 to 128,065 CLB LUT across five draws of a memory-like structure on this
project, two of them from the IDENTICAL command. A single draw here means
nothing, and the same discipline applies to a number that is predicted to be
small. Scatter has NOT been measured at this size on this project, so the two
draws also measure the scatter rather than merely averaging over it.

**THE PREDICTION IS SHARPER THAN THE BAND, AND BOTH ARE STATED.** LUTDIET's
already-measured `rmsnorm_rs_mem` is **4,798 LUT / 1,700 FF / 6 BRAM / 0 F7 /
0 F8 / 40 DSP**, and this unit differs from it by making the output write path
combinational, which removes three registers (`o_we`, `o_wa`, `o_wd`) and adds
none. **So the central expectation is 4,798 LUT to within a few hundred, and
slightly BELOW 1,700 FF.** The 4,798..7,823 band is retained because two draws
have not been taken and because a central expectation that coincides with a
prior measurement is exactly the situation in which it is easiest to stop
asking what would falsify it.

### How the scatter will be read, PRE-REGISTERED before the draws ran

Written and committed **before** `mem_d1` and `mem_d2` returned, so the
interpretation cannot be tuned to the numbers. The coordinator asked for the
scatter as a first-class result and it is treated as one.

Let `spread = max(d1, d2) / min(d1, d2)` on CLB LUT.

* **`spread` at or near 1.00** does NOT mean this structure is scatter-free.
  Two draws can agree by chance, and SCATTER's own evidence is that two of its
  five draws came from the identical command and still differed. It means only
  that **no scatter was observed in two draws**, which is what will be written.
* **`spread` materially above 1.00** is the more informative outcome and is
  NOT a defect: it bounds how much any single-draw area claim about this unit
  can be trusted, including LUTDIET's 4,798, which was one draw.
* **Either way the reported area is a RANGE**, `min..max`, never a mean. A mean
  of two draws is a number with no error bar pretending to be a measurement.
* **The comparison to `rmsnorm_rs` uses the WORST mem draw against the control**,
  so the saving is a floor rather than a best case.
* **SCATTER's 1.55x does not transfer.** It was measured on a 65,536-flop
  constant ROM whose spread came from register merging, and a memory-backed
  unit with no fold to perform has no obvious equivalent mechanism. **That is a
  hypothesis, and `mem_d1` vs `mem_d2` is its test.** If the spread here is
  large, the merging explanation for SCATTER's spread is incomplete.

### THE DRAWS. MEASURED 2026-08-30 on the BC-250.

Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, 5.0 ns, `synth_design -mode
out_of_context -flatten_hierarchy none` then `opt_design`, via
`sim/ooc_lutdiet_ports.tcl` **unmodified** and `sim/ooc_rmsmux_run.sh`. Tree
verified by md5 on all four load-bearing files against the local tree before
the run. Peak RSS 3.46 and 3.53 GB of the box's 14. One tool at a time.

    mem_d1  rmsnorm_rs_mem,"N=4096 LANES=4",40,4825,4825,0,1629,0,12,6,0,252,0,0,0.971,248.2005460412013,53,15,...
    mem_d2  rmsnorm_rs_mem,"N=4096 LANES=4",40,4825,4825,0,1629,0,12,6,0,252,0,0,0.971,248.2005460412013,53,15,...
    columns: target,gen,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,
             carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,...

**Every prediction in the table above was made before these ran.**

| quantity | PREDICTED | MEASURED | verdict |
|---|---|---:|---|
| CLB LUT | 4,798..7,823, central "4,798 to within a few hundred" | **4,825** | hit, +27 on LUTDIET (+0.56%) |
| MUXF7 | 0 | **0** | hit, falsifier (i) did not fire |
| MUXF8 | 0 | **0** | hit |
| CLB FF | "slightly BELOW 1,700" | **1,629** | hit, -71 against a DERIVED -75 |
| BRAM tile | 6 | **6** (12 RAMB18) | hit |
| DSP | 40 | **40** | hit, falsifier (iii) did not fire |
| CLB LUT above 8,000 | falsifier (ii) | 4,825 | did not fire |

**The FF row is the one that tests understanding rather than luck.** The
prediction was not "about 1,700"; it was *below* 1,700 by the three registers
this unit removes relative to LUTDIET's, which are `o_we` (1 bit), `o_wa`
(`clog2(NB)` = 10 bits) and `o_wd` (`LANES*16` = 64 bits) = **75 flops
DERIVED**. Measured **71**. The direction and the magnitude were both stated in
advance.

The census confirms the mechanism directly. `ARG`, the read of `x_mant` and
`w_mant`, is **443 LUT against 17,916** in the flat unit, and there is **no
`sq` root at all** -- the `S_ACC` read mux is gone rather than shrunk. Every
root reports MUXF7 = 0 and MUXF8 = 0. Against LUTDIET's census the two agree
root for root -- `max_raw` 1,047, `rq_shifted` 519, `ARG` 443, `shifted_r` 405,
`S` 222, all identical -- and differ in exactly one place, `o_wd` 1,101 becoming
`gbank.uo` 1,148, which is the one thing this unit changed.

### THE SCATTER, AS A FIRST-CLASS RESULT

**`spread = 1.0000x`, and it is stronger than the headline.** The two draws are
byte-identical in every CSV field including WNS and an Fmax to 13 significant
figures, **and their censuses hash the same**:

    diff <(tail -1 result_mem_d1.csv) <(tail -1 result_mem_d2.csv)  ->  IDENTICAL
    2c85f5c4d9e8fa4cca6149d571beaf46  census_mem_d1.txt
    2c85f5c4d9e8fa4cca6149d571beaf46  census_mem_d2.txt

So the two netlists agree down to per-root primitive tallies, not merely in
size. **This synthesis is deterministic for this design.**

**Read exactly as pre-registered, in both directions.**

* **It does NOT establish that this structure is scatter-free.** Two draws, one
  box, one session, back to back, same tool lifetime. It establishes that **no
  scatter was observed in two draws**, which is what is written.
* **The pre-registered hypothesis was NOT refuted.** The prediction was that
  the spread here would be small because SCATTER's 1.55x came from **register
  merging on a foldable 65,536-flop constant ROM**, and a memory-backed unit
  has no fold to perform. A structure with nothing to merge drew identically
  twice. **That is consistent with the merging explanation and fails to refute
  it; one comparison does not prove it**, and the alternative -- that SCATTER's
  two identical-command draws differed for a reason unrelated to merging, such
  as a tool or host difference this run does not control for -- is untested
  here.
* **The operational consequence, which is what the fit table needs: SCATTER's
  1.55x must NOT be applied to this unit's 4,825.** The spread that bounds other
  area conclusions tonight was measured on a different structure with a
  mechanism this one lacks, and it was measured here at 1.0000x.

**STATUS OF THE CONTROL: running at the time of writing.**

**STATUS: QUEUED, NOT RUN.** The draws are fourth in the lane order set by the
coordinator on 2026-08-30 (TIMING's pblock squeeze on the workstation, then
LEVERC's inference question, then NORMURAM's six points, then these) and are to
be taken on the **BC-250**, whose results are bit-identical to the workstation's
and where a small OOC job is the right fit. Nothing in this section is a
measurement until they run.

---

## 9. The latency statement, and which seams move

**Inside the unit: nothing moves.** MEASURED, 12 trials x 8 configurations:
`done` fires on cycle 148, the same cycle as `rmsnorm_rs`. The three element
passes still run `3N/LANES` beats. The compute is cycle-identical.

**What absorbs the RAM's read latency:** the fetch register the file already
had. `xa`/`xf`/`wf` were introduced by measurement (`idx -> mux -> DSP` was the
critical path at 257.0 MHz) to give the fetch its own cycle. `x_q`/`w_q` are
the RAM's output registers and occupy exactly that cycle.

**The one new latency:** `o_raddr` -> `o_rdata` is **ONE edge**, MEASURED by
the bench rather than derived, because the RAM output register and the
lane-select register both capture from the same combinational `o_raddr` and are
therefore in parallel, not in series. **My own first draft of the port comment
said two edges by counting them as a chain; the bench measured one and the
comment is corrected in place.** The cost to a reader is a single priming
cycle at the start of the drain pass, **once per operation, not once per word**.

**Which seams this touches: none, at the unit boundary.** `hw/fk33/host/
fk33_run_token.py` compares 63 captured seams against `ref/run9b`; the ones
this unit feeds are `R_XN-L`, `R_XN.ffn-L` and `R_XN.final`, which are **VALUE**
seams. The values are bit-identical, so those comparisons are unaffected.

**The one place a cycle COULD move is in the parent, and I did not make that
change.** `rtl/llama_top.vhd`'s `gvr` adapter drains `ov` combinationally in
`S_WR`; against a memory it must present `o_raddr` and read one cycle later, so
the drain pass gains one priming cycle and the adapter's `dn` could land one
cycle later. That is a parent-side change in a file this track does not own and
did not touch, its effect on the pinned `seq` landmarks has NOT been measured,
and it is listed in section 11 as open.

---

## 10. Risk, relative to the other two levers

**This lever is not inside anything that has run on silicon.** The project's
only whole-token silicon result records that "The 64 RMS norms, the final norm
... ran on the **host**". `rmsnorm_rs` has never executed on the card. TRACK
LEVERC's change is inside `matvec_core`, which did. So a defect introduced here
cannot regress a proven datapath -- it can only fail to work.

**That lowers the blast radius and RAISES the burden on simulation**, because
there is no silicon result to fall back on and no captured seam that would
catch it. It is why this track's whole weight is on section 6's oracle and
section 7.4's control rather than on "it synthesises and the numbers look
right".

**And the scope is narrower than TIMING assumed.** `rmsnorm_rs` is unchanged,
so B's and C's instantiations of it are untouched. Only a parent that
instantiates `rmsnorm_rs_mem` is exposed, and today none does.

---

## 11. Open, not yet answered

1. **No area number exists.** Section 8 is a prediction. Two draws at N=4096
   LANES=4, reported as a range, are the outstanding work, and they need a
   Vivado lane.
2. **THE HOOKUP IS NOT MADE HERE. ARBITRATED 2026-08-30: TRACK NORMURAM OWNS
   IT** and wires this unit in following section 12's port map verbatim, since
   `gvr` is its file. This track stopped at the file boundary and reported,
   which is what the arbitration was for. **Closed as an arbitration, still
   open as work**: until NORMURAM lands it, none of the saving is realised.
3. **The parent's drain gains one priming cycle** and the effect on the pinned
   `seq` landmarks and on `d_norm`'s `dn` instant has not been measured. This
   is the only place in the whole change where a cycle can move.
4. **`owe_norst` is not detectable at this boundary** (section 7.5). The `rst`
   term is carried over verbatim on WRITEDEC's authority, not on evidence
   gathered here.
5. **No congestion, routing-resource or power number.** The prior instance of
   this transform in this repo (`4914751`, swiglu/bfp_pack) reported the
   ROUTING win as larger than the area win -- "the route went from
   congestion-cliff (3 rip-up passes) to single-pass clean". That is
   un-quantified upside this document does not measure, and it matters more
   than usual for a design TIMING measured at congestion level 7.
6. **URAM is still untouched.** This lands in 6 BRAM tiles. Whether the same
   vectors would rather be in URAM, to leave BRAM for the KV cache, is not
   answered.
7. **`l2norm_rs` and `rmsnorm_bf` have the same flat-port idiom** and were not
   looked at. LUTDIET's section 9 item 3 says B's read side is a bigger change
   than D's because `gdn_block` reads 128 words in one cycle.
8. **Why the composed draw of `u_rms` (43,213 LUT) is LARGER than the
   standalone one (40,804) even though its `w_mant` is a constant that NWFIX
   measured as foldable by 17,367 LUT.** Not explained. Until it is, neither
   number should be treated as *the* baseline for this lever, and both draws in
   section 8 should be taken with the standalone control drawn in the same
   session. **The N=4096 GHDL run that would close item 10 was deliberately
   NOT taken**: `ghdl-mcode` has been MEASURED at 20.9 GiB in one process and
   GATEGREEN's full gate held the workstation, so the box could not have taken
   it beside TIMING's route. Confirmed by the coordinator as staying open
   rather than becoming a quiet omission.
9. **THE COMPOSED LOAD RACE IS UNVERIFIED AND THIS BENCH CANNOT VERIFY IT.**
   See the NORMURAM block in section 12. `tb_rmsnorm_rs_mem` loads both vectors
   before `start`, so the concurrent-load case has no coverage at all, and the
   deadline is inside the unit where the parent cannot see it.
10. **Only N=64..256 was simulated.** N=4096 was never run in GHDL; the sweep
   argument is that the transform is index arithmetic that does not depend on
   N, but that is an argument, not a measurement.

---

## 12. The hookup, stated precisely so it can be arbitrated rather than guessed

**ARBITRATED 2026-08-30: TRACK NORMURAM applies this, not this track.** `gvr`
is NORMURAM's file and it wires the unit in following the port map below
verbatim. What is written here is therefore a handoff, not a proposal, and
nothing in this section has been applied by TRACK RMSMUX.

    u_rms : entity work.rmsnorm_rs_mem
      generic map(N => NN, LANES => NORM_LANES, Q => NORM_Q)
      port map(clk => clk, rst => rst, start => r_go,
               x_we => <the adapter's existing per-word region write>,
               x_waddr => <its existing k-2 index>,
               x_wdata => el_rdata,
               x_exp => r_xe,
               w_we => <gwm's existing wdv>, w_waddr => <gwm's wptr>,
               w_wdata => <gwm's wrd>, w_exp => NORM_W_EXP,
               done => r_done,
               o_raddr => <the S_WR drain index>, o_rdata => <one word>,
               o_exp => r_oe);

**Why this is ADDITIVE to TRACK NORMURAM and not in conflict with it.** Read
NORMURAM's own comment in `gwm`: it already reads the gain **one word at a
time** from a URAM ROM and shifts it into `wreg`, and its own note says the
shift register form was chosen over an addressed array precisely "because the
words arrive strictly in order". Those words arrive in exactly the order and at
exactly the granularity `w_we`/`w_waddr`/`w_wdata` want. So:

* NORMURAM removed the **32,943 LUT** gain ROM and replaced it with 17 URAM288
  plus a **65,536-bit `wreg`**.
* Pointing that loader at the bank port instead **deletes `wreg` as well**
  -- another 65,536 FF -- and takes the w read mux inside the unit with it.
* Likewise `gvr.xw`, 65,536 FF, and its flat view `xv`, disappear entirely.

**DERIVED, and the arithmetic closes, which is the check that it is the right
account.** `u_rms` 67,384 FF + `gvr.xw` 65,536 FF = **132,920**, against
`d_norm`'s MEASURED **133,607** -- leaving **687 flops** for the whole of the
adapter's state machine. That is consistent, and it also confirms the section-8
qualification from a second direction: `wsel` contributes essentially NO flops
in that draw, which is what a register whose only value is a constant does.
**In the shipping configuration `gwm.wreg` is a real 65,536-flop shift register
and is a third vector, so the hookup's FF saving there is larger than 132,920.
Do not quote a single number for it until a composed FF census is taken with a
real gain image.**

### THE COMPOSITION COSTS TIMING MARGIN. FINDING BY TRACK NORMURAM.

**Recorded here because section 12 as first written was wrong by omission**: it
read NORMURAM's gain loader as free to reuse. It is free in **order** and in
**granularity** but **NOT in RATE**, and that is a real cost that belongs on
the record before anyone books the FF saving.

`w_we`/`w_waddr`/`w_wdata` is **one 16-bit word per cycle**. NORMURAM's
shift-register form reads `GW = 4` elements per cycle. So pointing the loader
at this unit's bank port makes the load 4x longer.

**DERIVED INDEPENDENTLY HERE, from `rtl/rmsnorm_rs.vhd`'s own state list rather
than from NORMURAM's message, and it agrees.** The fixed states between the end
of `S_ACC` and the first `w` read at `S_RAW` are `S_INV1..6` (6), `S_SEED1..2`
(2), `S_RQ` steps 0..24 (25), `S_RQ_FOLD` (1), `S_RQ_FIN1..3` (3),
`S_RQ_CLAMP` (1) = **38 cycles**. With the load at `NN+2` and the deadline at
`NN + NN/LANES + 38`:

| configuration | load | deadline | margin |
|---|---:|---:|---:|
| today, shift register, `GW = 4`, any shape | `NN/GW+1` | `NN+4` | **4.0000x** |
| composed, `NN = 4096`, `NORM_LANES = 4` | 4,098 | 5,158 | **1.2587x** |
| composed, `NN = 4096`, `NORM_LANES = 16` | 4,098 | 4,390 | **1.0713x** |

matching NORMURAM's 4.0x, 1.26x and 1.07x. `LANES = 16` is not hypothetical:
it is a legal configuration and it is one of the eight this unit's own sweep
covers.

**AND THE PART THE ARITHMETIC ADDS, WHICH IS THE DANGEROUS ONE.** The margin is
shape-invariant today and is NOT shape-invariant composed, and it moves in the
direction that makes a small-shape bench **flattering**:

| shape | composed margin, `LANES = 4` | composed margin, `LANES = 16` |
|---|---:|---:|
| `NN = 64` (a bench shape) | **1.7879x** | 1.6061x |
| `NN = 4096` (the build) | **1.2587x** | 1.0713x |

**A bench at hidden 64 sees 1.79x of margin where the shipping build has 1.26x.**
So a composed test that passes at a small shape is not evidence about the real
one, which is exactly the property `GW = 4`'s 4.0000x had and the bank port
loses. Whoever attempts the composition must exercise it at the real shape or
not claim it.

**The URAM count survives** (`GW = 4` with a 4-cycle demux keeps 17 URAM288,
not the 114 NWROM measured at `GW = 1`). It is the rate that does not.

**Second-order, and worse for checking than for timing.** Today the gain is
fully resident before `r_go`, which is a **phase separation** that `gvr` can
see and that `wbusy` checks. Composed, the reader walks `LANES` elements per
cycle against the writer's one, both ascending, so it becomes a **race** -- and
the deadline moves from `r_go`, which `gvr` can see, to the unit's internal
`S_RAW`, which `gvr` cannot see at all. NORMURAM's U6/U6x mutant pair is direct
evidence that this fault class leaves the VALUES correct and every landmark
unmoved, which is the worst possible signature.

**MY OWN VERIFICATION SAYS NOTHING ABOUT THIS, AND THAT IS MINE TO STATE.**
`sim/tb_rmsnorm_rs_mem.vhd` loads x and w **completely before `start`**, so it
exercises the phase-separated case only and never the concurrent-load race. No
mutation in section 7.4 perturbs load timing. **The unit is verified; the
composition is not, and this bench cannot verify it.**

`rmsnorm_rs_mem` exposes no tap for when `S_RAW` begins, so a parent cannot
today check the deadline it now owns. Making that visible is a small,
non-arithmetic addition and is **not made here** -- the coordinator has
sequenced the composition after NORMURAM's six points and has not asked for a
change to this unit. Named so the composed step starts from it.

**The one thing that must be decided by Oren and not by a track:** `gvr` is one
generate block holding BOTH the gain image (NORMURAM's) and the input staging
(this lever's), and both changes want to edit it. They do not conflict in
substance -- they compose -- but they conflict in the index. **This track
stopped at the file boundary and reported rather than editing it.**

---

## 13. Measured and REJECTED -- do not retry

* **`wait for 0 ns` to sample a registered RAM output in GHDL.** The RAM's
  `dout` and the lane-select register resolve one delta after the clock edge,
  and `o_rdata`, being combinational off them, one delta after that. A
  single-delta sample reads the PREVIOUS address, and the bench reported
  **every element off by one** -- a plausible, ordered, entirely wrong result
  that looked exactly like a real one-element shift in the design. Sample at
  the falling edge (`wait for 1 ns` at this bench's 2 ns period). Cost: one
  full debug cycle spent suspecting the DUT.
* **Driving `x_waddr` and `w_waddr` with the same value on the same cycle.**
  It makes the `wbank` mutation -- the w bank enable decoded from `x_waddr`,
  the copy-paste fault this interface most invites -- a literal no-op, and it
  SURVIVED a bench that was killing everything else. The two loads are now
  sequential passes, which is also what the parent does. **The mutation found
  the bench's coverage gap, not the design's defect, which is what mutations
  are for.**
* **Probing a latency by matching against an all-zero reference.** The first
  version of the read-latency probe ran after `rand_wide`, which lands on the
  unit's all-zeros rail, so it matched at every latency including zero. The
  probe's own guard (element 0 must differ from element N-1) turned that into a
  visible `-1` instead of a false `1`. A live trial is now run immediately
  before the probe.
* **Registering `o_we`/`o_wa`/`o_wd`** (LUTDIET's form). It costs one cycle on
  `done` and then needs `and o_we = '0'` in the completion condition to avoid
  losing the last word. `done` is what the top level and the pinned sequencer
  landmarks wait on. The combinational form is what TRACK WRITEDEC already
  shipped and it is free.
* **Raising `maxLoopLimit`.** Not retried; it was measured to work and rejected
  as a crutch by `912228c`, and nothing here needs it.

---

## 14. Measurement traps hit, including my own

* **The one-element shift looked exactly like a design bug and was mine.** See
  section 13. The `ramp` and `bankramp` trials are what made the *pattern*
  legible (`dut[i] == golden[i-1]` on ordered data); on random data alone the
  report would have read "everything differs" and the debug would have been
  longer. **Ordered stimulus is not redundant with random stimulus.**
* **A mutation that survives is not automatically a gap.** Two of the three
  survivors here (`xwswap`, `transpose_all`) are genuine equivalences with
  structural reasons, and one of them I had listed as expected-to-bite. The
  expectation was corrected in the mutation list rather than deleted.
* **The latency probe credited itself with kills it had no right to.** Only the
  three-column control separated "the bench caught it" from "this check caught
  it". A two-column control would have shown `bankswap` dying with `CHK_VAL`
  off and read as evidence for a structural check.
* **`ghdl -a` silently leaves an architecture obsolete** when its entity is
  re-analysed. The generic sweep's first pass returned `rc=1` on all eight
  configurations with the message `architecture "sim" ... is obsoleted by
  entity "rmsnorm_rs_mem"` and no mention of a failing check. Re-analyse the
  bench after touching the RTL.
* **`grep -c` on the Vivado presence check counts its own `grep`.** Used only
  as a presence gate, per `40cd673`, never as a count.
* **The gate's own `UNTRACKED` listing is the guard that caught the files not
  being committed**, and it names them individually: a row that exists for you
  and not for a clone.

---

## 15. Files

Owned and created by this track, and nothing else was edited:

    rtl/rmsnorm_rs_mem.vhd            the unit
    sim/tb_rmsnorm_rs_mem.vhd         the oracle (a new gate row)
    sim/mutate_rmsnorm_rs_mem.sh      the teeth, with the attribution control
    docs/debugging/2026-08-30_rmsmux-flat-vector-read-muxes.md   this file
