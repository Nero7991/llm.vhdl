# Where does subsystem A's weight base come from, who owns it, and does the fabrication block PACKSTRIPE?

**Date:** 2026-08-30. Branch `fpga`. **TRACK BASEFAB.**
**Base commit:** `9270c7a` (TRACK DSEAM's N2 host seam).

**NO HARDWARE WAS TOUCHED.** Nothing below ran `xsdb`, `hw_server`,
`vivado ... program`, `hw/fk33/pcieep.sh`, `jtag.sh`, `flash.sh`, anything
under `hw/fk33/tcl/`, or anything opening `/dev/xdma*`. GHDL, `git`, `grep`
and `python3` only.

**Tools named:** `ghdl-mcode` via `sim/regress.sh`, `git archive` / `git show`
/ `git diff`, `python3`, `grep`.

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement, with its assumption and what would falsify it).

---

## 1. The questions, verbatim

> 1. **The exact scope of the fabrication.** What `rtl/llama_top.vhd:2694`
>    computes, what consumes it, and what the correct source is.
>    `seq_desc_fetch`'s own header says the base array at descriptor offset
>    0x40 is never fetched -- read that header and say what it says.
> 2. **Who is supposed to own the base array.** DSEAM lists "where the base
>    array comes from" as having **no owner**.
> 3. **The fix, or a costed statement of why it should not be applied yet.**
> 4. **A check that would have caught this.**
> 5. **Teeth with the attribution control.**

And, from the coordinator, the thing to settle first:

> A fabricated base of the form `BASE + step*STRIDE` cannot express a striped
> layout at all. **So G3 is not merely a latent bug that fires when D reaches
> the card -- it is structurally incompatible with the single largest
> performance fix in flight.**
> **Establish whether that is right before you act on it.**

---

## 2. The answers, up front

**2.1 The form claim is RIGHT. The urgency claim is WRONG, and the correction
is load-bearing: PACKSTRIPE is not blocked by G3 and the two tracks do not
collide.**

The form claim first. `rtl/llama_top.vhd` computes a two-parameter affine map,
`w_base(p) = A_MEM_BASE + step*A_JOB_STRIDE + p*A_SUB_BYTES`. PACKSTRIPE's
shipping allocator "assigns segments **per tensor**, greedily on current fill,
within each lane's own HBM stack"
(`docs/debugging/2026-08-30_packstripe-lane-arena-placement.md` section 2), so
lane `p`'s address for tensor `T` is not an affine function of `(T, p)` and no
closed form can express it. The same document states the consequence
explicitly: "The descriptor **re-states all 27 bases for every job**". So a
fabricated affine base and a striped layout are indeed mutually exclusive.

The urgency claim is where the inference goes wrong. **`llama_top`'s
fabrication is not on the striped path, and never was.** MEASURED by reading
the instantiation chain:

| link | file:line | what it says |
|---|---|---|
| the card binds A's descriptor wrapper | `hw/fk33/rtl/fk33_engine.vhd:1156` | `eng : entity work.matvec_int4_desc_axi` at `NPORTS_W`/`NPORTS_S` |
| that wrapper FETCHES the base array | `rtl/matvec_int4_desc_axi.vhd:610-615` | `w_base((p+1)*ADDR_W-1 downto p*ADDR_W) <= dw(DESC_BASE0 + p)(ADDR_W-1 downto 0);` and the same for `s_base` at `DESC_BASE0 + NPORTS_W + q` |
| the core takes arbitrary per-lane bases | `rtl/matvec_int4.vhd:70,73` | `w_base : in std_logic_vector(NPORTS_W*ADDR_W-1 downto 0)` -- an ARRAY, not a base plus a pitch |
| D is not in the card design at all | `hw/fk33/rtl/fk33_engine.vhd` | `grep -c seq_` = **0** |
| the generator already emits striped bases | `tools/gen_mv4i_desc.py:352-357, 469-489` | `sub_base()` -- "the only place a lane-striped manifest differs ... for a v2 lane-striped one it is the piece the manifest placed at file offset `off`", joined on file offset from `pieces` |

So the chain `pack_model_fk33.py --stripe-lanes` -> v2 manifest `pieces` ->
`gen_mv4i_desc.py` -> descriptor image in HBM -> `matvec_int4_desc_axi` ->
`matvec_int4` already carries **27 unrelated 40-bit addresses per job** and is
what the card runs. Striping is expressible end to end today.

**What IS true, restated so it is not lost:** the fabrication is structurally
incompatible with striping *for the one integration in which `llama_top`'s A
seam is what gets wired to the card*. That integration is not the one the card
has, and section 5 argues it is the wrong one to build.

**Correction to the brief, then:** G3 is a defect in the **simulation top**
`rtl/llama_top.vhd`. DSEAM's "on silicon every A job would read the wrong
bytes" is conditional on an integration that does not exist and that the
evidence says should not be built. It is not a live silicon defect.

**2.2 The base array HAS an owner, and it is subsystem A, not D.** The
descriptor format document says so directly
(`docs/2026-08-28_matvec-descriptor-format.md:82-84`): "a descriptor written
for `seq_desc_fetch` alone (64 bytes, no base array, no extension) is **not**
accepted by subsystem A -- A needs the bases and the extension. That asymmetry
is deliberate and is the intended direction: **D issues, A consumes.**" DSEAM
read the "no owner" from the same document's remaining-work list at :570,
which says D fetching the array is still open. Both sentences are in the file
and they describe **two mutually exclusive integrations**. Nobody has chosen
between them. That is the real content of "no owner": not a missing
implementation, a missing decision.

**2.3 The fix is NOT applied and should not be, and the reason is structural
rather than a matter of effort.** `seq_desc_fetch`'s descriptor address is
`resize(fetch_idx & "000", 16) + f_beat` (:576) -- a **hard-wired 8-word,
64-byte stride**, and its header claims 0 DSP by construction *because* of
that shift. A variable-length descriptor (header + `nsub_w` + `nsub_s` +
4-word A extension = **39 words at the FK33 geometry**) cannot be addressed by
`step*8`. Making D fetch the base array therefore costs a multiply or a second
table, plus a `27*ADDR_W`-wide two-bank shadow, to duplicate a fetch
`matvec_int4_desc_axi` already performs correctly. Section 5 has the numbers
and the cheaper alternative.

**2.4 A second defect was found in the same family, and this one IS reachable
at the shipping shape.** The fabricated block was not merely of unknown
provenance, it was **unbounded**: nothing checked that a job's weights fit the
4 KB sub-region the fabrication gives each port. DERIVED at Qwen3.5-9B
(`rtl/model_cfg_pkg.vhd`: hidden 4096, ffn 12288), the FFN gate job needs
`ceil(12288/4) * ceil(4096/32) = 3072*128 = 393,216` beats per port against a
capacity of `4096/16 = 256`. **Short by a factor of 1,536.** A job over
capacity walked into port `p+1`'s sub-region and read it as its own weights,
completing with `done=1, err=0`. Fixed in this change: `llama_top` now refuses
such a job in `S_EXP`, one clocked state before `start` reaches A, so not one
address beat is issued.

**2.5 The answer to "what check would have caught a wrong base" is: only an
address-level oracle, and the oracle is the base array, so no check inside D's
simulation world can catch it today.** What CAN be built, and now is, is a
checker over the address STREAM. `sim/tb_a_wbase.vhd` checks eight properties
that do not need to know the right answer, and kills **8 of 11** mutations of
the fabrication. **The attribution control then denies credit for seven of those
eight**: only M9, the guard this track added, is a detection the six
pre-existing rows do not already make. Section 8 has the table; section 8.1
names the three survivors, one of which is the underlying defect's own shape.

---

## 3. Scope of the fabrication, exactly

`rtl/llama_top.vhd`, unit A's adapter, state `S_EXP` (the line numbered 2694
in the brief is inside the banner; the code is ~40 lines below it):

```vhdl
nb    := (j_cols + A_BLK - 1) / A_BLK;
tiles := (j_rows + A_ROWS_IF - 1) / A_ROWS_IF;
base  := A_MEM_BASE + j_step * A_JOB_STRIDE;
...
for p in 0 to A_ROWS_IF-1 loop
  r_wbase((p+1)*32-1 downto p*32)
    <= std_logic_vector(to_unsigned(base + p*A_SUB_BYTES, 32));
end loop;
r_sbase <= std_logic_vector(to_unsigned(base + A_ROWS_IF*A_SUB_BYTES, 32));
```

with `A_MEM_BASE = 0x100000`, `A_JOB_STRIDE = 0x8000`, `A_SUB_BYTES = 4096`
(the last was a bare literal `4096` before this change; see section 6).

**What consumes it:** `r_wbase` and `r_sbase` are port-mapped straight into
`u_mv : entity work.matvec_int4` (`rtl/llama_top.vhd:2532` at `HEAD`) as
`w_base` and `s_base`, and from there into `axi_rd_port`, which issues the AR
beats. Nothing between the fabrication and the AXI bus re-maps it. **The
brief's "if something downstream re-maps it" is answered: nothing does.**

**What the correct source is:** the descriptor's base array, 64-bit
little-endian words at byte `0x40`, `nsub_w` weight bases followed by `nsub_s`
scale bases (`docs/2026-08-28_matvec-descriptor-format.md` section 4.2,
`rtl/matvec_int4_desc_pkg.vhd` `DESC_BASE0 = 8`).

**Is it per-tensor or per-lane?** The brief asks. It is **both, and uniformly
so**: one affine term per job (`j_step * A_JOB_STRIDE`) and one per lane
(`p * A_SUB_BYTES`). That is precisely the shape a striped layout cannot take.

### 3.1 What `seq_desc_fetch`'s header actually says, verbatim

From `rtl/seq_desc_fetch.vhd:111-115`, quoted rather than summarised as the
brief asked:

```
-- The base array (`nsub_w + nsub_s` 64-bit words at offset 0x40) is NOT
-- fetched here.  Its length is open with A section 14.5 and the count is only
-- RANGE-CHECKED against NSUB_MAX at the moment.  Fetching it is remaining work.
```

and from the same file's opening statement of scope, :12-17:

```
-- It is deliberately NOT the whole of D-ctrl.  Absent, on purpose: the region
-- address generation, the AXI grant mux and its outstanding counters, D-vec,
-- the base array (`nsub_w + nsub_s` 64-bit bases past the header), and the
-- codebook load.  Those are named in the report as remaining work rather than
-- stubbed here, because a stub in an entity that claims to be real is exactly
-- the thing the surrounding specs keep having to withdraw.
```

`rtl/llama_top.vhd`'s own banner (:127-132) says the same thing about itself
and adds the consequence: "So A's weights do not come from the descriptor."

**Both are accurate.** The brief's summary was correct and is confirmed.

---

## 4. The two integrations, and why nobody has chosen

|  | **(P) pointer handoff** | **(F) D fetches the bases** |
|---|---|---|
| what D hands A | the descriptor's byte ADDRESS | 27 (or 28) decoded bases on a wide bus |
| who reads byte 0x40 | `matvec_int4_desc_axi` (already does) | `seq_desc_fetch` (does not) |
| A entity on the card | `matvec_int4_desc_axi` (already bound) | bare `matvec_int4` |
| D's descriptor stride | must become the A descriptor's 512 B alignment | stays 64 B, but the table is then two tables |
| D's `step*8` shift | survives if the stride is a power of two | breaks: 39 words is not a power of two |
| new D state | none (one output, one shift) | `nsub_w + nsub_s` more fetch beats per A job |
| new D storage | one `ADDR_W` output | `NSUB_MAX*64*2` shadow bits worst case; `27*40*2 = 2,160` FF at the FK33 geometry |
| what the format doc says | "D issues, A consumes" (:86) | "Still remaining work in D" (:570) |

**Nothing in the tree chooses.** `rtl/llama_top.vhd` implements neither: it
binds the bare core and invents the bases, which is a third thing and is not a
step toward either.

---

## 5. What must be true before D is wired to the card path

This is the deliverable the brief said might be worth more than an edit, and I
agree, so it is stated as a list rather than a narrative.

1. **A decision between (P) and (F), recorded.** The evidence favours (P) on
   three independent counts: the card already binds `matvec_int4_desc_axi`;
   `gen_mv4i_desc.py` already emits the base array and already handles the
   striped case; and D's 0-DSP `step*8` addressing survives (P) and does not
   survive (F).
2. **Under (P), `seq_desc_fetch` gains ONE output.** `job_desc_addr <=
   A_DESC_BASE + (job_step << clog2(DESC_STRIDE))`. `DESC_STRIDE` is 512 at
   the FK33 (`DESC_MAXB*AXI_DW/8 = 16*32`), a power of two, so it is a shift
   and the 0-DSP claim in that file's header stays true. **DERIVED cost of the
   descriptor table this implies:** `505 steps * 512 B = 258,560 B`, against
   3.826 GiB of free HBM after striping -- 0.0066%. Not a constraint.
3. **`matvec_int4_desc_axi` needs a non-AXI-Lite start path**, or D needs an
   AXI-Lite master. Today `DESC_PTR_LO/HI` and `CTRL.GO` are AXI-Lite
   registers written by a host. That file is not this track's and the change
   is not made here.
4. **A residency oracle, because the descriptor plane cannot supply one.**
   `matvec_int4_desc_axi`'s own header already states it: "What is NOT checked
   ... a base that is well-formed but points at the WRONG sub-region. Nothing
   in the descriptor says what a sub-region should CONTAIN, so only a hash over
   the weight store can see it; it produces a wrong answer rather than an
   error." PACKSTRIPE reached the identical conclusion independently for its
   own mutation M9. **Two tracks, two mechanisms, one answer: the only check
   for a wrong base is a hash of the bytes at that base.** That is
   `fk33_load_weights.py verify`'s per-file blake2b, and it is on-card work.
5. **`hw/fk33/rtl/fk33_engine.vhd` must instantiate D at all.** It does not
   (`grep -c seq_` = 0). Until it does, none of the above is on the critical
   path for anything the card runs.

**What is NOT required, contrary to the brief's framing:** PACKSTRIPE does not
wait on any of this.

---

## 6. What was changed in this track

Two files of RTL and simulation, plus two new files.

**`rtl/llama_top.vhd`** (shared this session with TRACK NORMURAM, whose hunks
are in the `gvr` generate and are untouched here):

* `A_SUB_BYTES` promoted from a bare `4096` in the address expression to a
  generic. The reason is not tidiness: the CAPACITY of a sub-region is what
  bounds a job, and a bound written as a literal inside an expression is a
  bound nothing can check. `sim/tb_llama_top.vhd:790` already carried its own
  local copy of the same 4096 as the divisor that turns an address back into a
  sub-region index, so the number was already duplicated across two files with
  nothing tying them together.
* `CHK_A_BLOCK`, an elaboration guard in the existing block of them: a
  `natural` that goes negative if `A_JOB_STRIDE < (A_ROWS_IF+1)*A_SUB_BYTES`,
  i.e. if the scale port's base lands outside the job's own block and on top
  of the next job's weights. Written as an out-of-range `natural` and not an
  assert, per the standing rule that Vivado silently ignores
  `assert ... severity failure` in synthesis. At the defaults it is
  `32768 - 5*4096 = 12288`, so it does not bind today.
* `A_BEAT_B` / `A_SUB_BEATS` / `A_SCL_BEATS` in the `ga_real` generate: 16 B
  per beat, 256 weight beats, 1024 scale beats.
* **The capacity refusal**, in `S_EXP`, before `S_GO`. `wb := tiles*nb` and
  `sb := (tiles*nb*A_ROWS_IF*2 + 15)/16` are now named variables used BOTH by
  the test and by the values handed to A, because two copies of one expression
  is how a bound and the thing it bounds drift apart. Over capacity: report,
  raise `uerr`, go straight to `S_DONE`. D sees `ERR_UNIT`.

  **`uerr` and not a new port, deliberately.** A new `out` port would have
  been better diagnostics and worse blast radius: seven other tracks are live
  and every existing `llama_top` instantiation would have had to be read to
  confirm an unassociated formal was acceptable. `uerr` reaches the host
  through the error path that already exists, and `err_step` names the job.

**`sim/tb_a_wbase.vhd`** (new, and therefore a new auto-discovered gate row --
see section 9). The address-stream checker; section 7.

**`sim/mutate_a_wbase.sh`** (new). The teeth table and its attribution
control.

### 6.1 What the refusal cannot regress, checked rather than assumed

The 9B-shaped rows in `sim/elab9b_run.sh` and `sim/realshape_gate.sh` include
`llama_top -gA_BEHAV=false`, and at that shape every A job is 1,536x over the
new capacity bound, so the obvious worry is that the refusal turns those rows
red. It cannot. MEASURED by reading `sim/realshape_gate.sh:94-117`: every row
is `ghdl -r ... --stop-time=1ns`, i.e. **elaboration only** -- no `go`, no
descriptor walk, no A job. The refusal lives in `S_EXP`, a run-time state.
`CHK_A_BLOCK`, the half that DOES bite at elaboration, is a function of
`A_JOB_STRIDE`, `A_ROWS_IF` and `A_SUB_BYTES` alone and is `12288` at every
shape. Neither script is in `sim/regress.sh`'s planner anyway
(`regress.sh:581`: "live in sim/realshape_gate.sh, run by hand").

---

## 7. The check, and what it can and cannot see

`sim/tb_a_wbase.vhd` instantiates `llama_top` with the real `matvec_int4`,
records every accepted AR beat on all five weight/scale masters tagged with
the live step, and checks eight properties. Two phases in one run: three A
jobs that fit (P1..P7), then a reset and one job that does not (P8).

| | property | what it discriminates |
|---|---|---|
| P1 | a job's reads stay inside the ONE sub-region the fabrication gave that port | the overrun of section 2.4 |
| P2 | every base is 4 KB aligned | `axi_rd_port`'s stated requirement, unchecked above it until now |
| P3 | within a job, the five ports' extents are pairwise disjoint | two ports reading one extent is a silently wrong dot product |
| P4 | across jobs, no byte is read twice | this is what the `j_step` term is FOR |
| P5 | beats per port equal `tiles*nblk` DERIVED in the bench from its own table | a short or long read |
| P6 | bursts tile the extent exactly: each starts where the last ended | gaps, repeats, reordering |
| P7 | INCR only, `arlen+1 <= A_MAXB` | burst legality |
| P8 | an over-capacity job issues ZERO ARs and raises ERR_UNIT | the refusal must precede the first read, not follow it |

**Why the existing rows are structurally blind, MEASURED by reading them.**
Both weight memories in the tree are the fabrication's own inverse:

* `sim/tb_llama_top_smp.vhd:435` answers on `(addr mod A_JOB_STRIDE_C) / 16`.
  The `j_step * A_JOB_STRIDE` term is divided straight back out, so every step
  reads the same bytes. That is deliberate there (its route comparison needs
  one matrix) and it means the step term could be **deleted** with no effect
  on that row.
* `sim/tb_llama_top.vhd:887-892` computes `stp := off / A_JOB_STRIDE_C` and
  `sub := rmn / A_SUB_BYTES` and indexes its image by them -- the same
  function the DUT applies, run backwards. A base is right by construction
  there and cannot be wrong.

That is what the brief called "a whole column of green tests that cannot see a
wrong-address defect", and it is confirmed: the blindness is in the memory
model, not in the assertions.

**The honest limit, stated as the brief asked.** P1..P8 are all RELATIVE
properties. None of them knows where the weights actually are, because nothing
at this level does. A base array in the descriptor is the only independent
statement of that, and D does not carry one. **So yes: only an address-level
oracle can catch a wrong base, and the oracle is the base array.** Mutation M5
below is that limit made visible.

---

## 8. Teeth, with the attribution control

MEASURED. Every mutant was applied to a `git archive HEAD` snapshot at
`9270c7a` with **only this track's five hunks** re-applied on top -- not the
live working tree, which also carries TRACK NORMURAM's in-flight `gvr` edits.
The mutation harness treats a pattern that does not match exactly once as a
hard error, because a mutation that was never applied looks exactly like one
that survived.

`P=` / `F=` are regress.sh's own counters. **`F>0` means the mutant was
KILLED.** The control column is the SIX pre-existing rows that `--only
tb_llama_top` matches as a substring, enumerated here rather than assumed
(MEASURED from the clean-baseline run's `res.*` files):

```
sim_tb_llama_top          sim_tb_llama_top_seq      sim_tb_llama_top_smp
sim_tb_llama_top_smp_beh  sim_tb_llama_top_real     sim_tb_llama_top_normw
```

**Two of those six are the strongest possible control and I nearly missed
them.** `W_IMAGE` defaults to `""`, in which case `wword_at` takes its
arithmetic branch and `sim/tb_llama_top.vhd:892`'s
`assert stp < NSTEP and sub = p and beat < A_WBEATS` is **unreachable** -- so
on the four rows that leave it empty there is no address assertion in the tree
at all. `tb_llama_top_real` and `tb_llama_top_normw` DO set
`-gW_IMAGE=llama_top_w_b4_pool.hex`, which turns that assert on. Had the
control been only the default rows it would have been a weak one and every
kill would have looked like the new bench's.

| mutant | what it changes | **NEW** `tb_a_wbase` | **CONTROL** 6 pre-existing rows | credited? |
|---|---|---|---|---|
| M1_no_step | `base := A_MEM_BASE` -- every job aliases | **KILLED** `F=1` | **KILLED** `P=2 F=4` | no |
| M2_no_port | every port gets sub-region 0 | **KILLED** `F=1` | **KILLED** `P=2 F=4` | no |
| M3_half_pitch | port pitch `A_SUB_BYTES/2` | **KILLED** `F=1` | **KILLED** `P=2 F=4` | no |
| M4_scale_on_p0 | scale base collides with port 0 | **KILLED** `F=1` | **KILLED** `P=2 F=4` | no |
| M5_step_plus1 | every base shifted one whole job stride | SURVIVED `P=1` | **KILLED** `P=2 F=4` | **the control has a tooth this bench lacks** |
| M6_unaligned | base off 4 KB alignment by 16 B | **KILLED** `F=1` | **KILLED** `P=2 F=4` | no |
| M7_wbeat_short | A handed `wb-1` weight beats | **KILLED** `F=1` | **KILLED** `P=1 F=5` | no |
| M8_sbeat_half | scale-beat formula drops its `*2` | **KILLED** `F=1` | **KILLED** `P=1 F=5` | no |
| M9_guard_off | the new capacity refusal disabled | **KILLED** `F=1` | **PASS 6 of 6** | **YES -- sole detection** |
| M10_guard_ge | capacity test `>` becomes `>=` | SURVIVED `P=1` | NOT RUN | -- |
| M11_port_rev | port-to-sub-region assignment reversed | SURVIVED `P=1` | NOT RUN | -- |

**THE HEADLINE IS THE CONTROL COLUMN, NOT THE KILL COUNT.** `tb_a_wbase` kills
8 of 11. The attribution control denies credit for **seven of those eight**.
The one detection that is genuinely new is **M9**, and it is new for a reason
that generalises: the pre-existing rows never issue an over-capacity A job, so
they structurally cannot observe the guard at all. Every other kill was
already caught.

**And the kills the control makes are NOT address checks.** MEASURED by
reading the failure messages:

```
M1 sim:tb_llama_top       tb_llama_top.vhd:2745 P14 -- R_X(0) is -3096 and the recorded landmark ...
M1 sim:tb_llama_top_real  tb_llama_top.vhd:2041 the residual at step 10 has operand exponents 3 and 28 ...
```

Those are a recorded numeric landmark and an exponent-sanity check. They fire
because `wword` happens to be address-sensitive, so a moved base changes the
VALUES and the landmark moves with them. That is a real detection and it is
counted as one -- but it is incidental and non-diagnostic: the message names
`R_X(0)`, not an address, and it would evaporate for any mutation that moves
an address without moving what the memory returns. **The two `smp` rows, whose
memory answers on `addr mod A_JOB_STRIDE`, PASS every single address mutation
in this table.**

**M9's control was assembled from two invocations** and that is stated rather
than smoothed: the batch run was killed by the harness at M9's last row with
five of six results written (all PASS), and `sim:tb_llama_top_seq` was run
separately afterwards on the same mutated snapshot (`PASS 1 FAIL 0`). Six of
six is therefore measured, not inferred, but not in one command.

### 8.1 The three survivors, under their own names

**M5_step_plus1 -- the most important line in this document.** Shifting every
job's base by one whole `A_JOB_STRIDE` is invisible to `tb_a_wbase`, and it is
invisible for a reason that generalises: every property P1..P8 is relative
(containment, disjointness, contiguity, counts), and a UNIFORM translation of
the whole address space preserves all of them. **That is the exact shape of G3
itself.** A checker built out of relative properties can never see a base that
is uniformly wrong, which is the same conclusion section 7 reaches from the
other direction. It is not a gap to be closed by adding a ninth property; it
is the boundary of what any check without an oracle can do.

**M10 and M11 have NO CONTROL COLUMN. Their rows are not evidence.** The
batch was cut short by the reboot window. Both SURVIVED the new bench, which
is measured; whether the six pre-existing rows catch them is **unmeasured**,
and for M11 in particular there is a specific reason to expect they might --
see below. Do not read "SURVIVED / NOT RUN" as "nothing catches it".

**M10_guard_ge -- a deliberate no-bite, and it should not bite.** Changing the
capacity test from `>` to `>=` refuses a job of exactly 256 beats, which is a
legal job. No phase-1 job is at the boundary, so nothing observes the change.
This row measures the resolution floor of the capacity guard: it is exact to
within one beat and the bench does not probe that last beat. Adding a
256-beat job would close it and would cost a longer run; it is recorded as
open rather than done.

**M11_port_rev -- reversing the port-to-sub-region assignment.** Every
property P1..P8 still holds: the extents are the same set, still disjoint,
still aligned, still contiguous, still the right length. Only the ASSIGNMENT
of extent to port changed, and a port permutation is exactly a wrong base with
a right-looking address space. **PREDICTION, UNVERIFIED:** the two `W_IMAGE`
rows should catch it, because `sim/tb_llama_top.vhd:892` asserts `sub = p` in
its address decode and is the one place in the tree that could -- and
`wword` is also port-sensitive (`p*104729` in its polynomial), so the four
value-landmark rows may catch it incidentally as well. **Neither was run.**
This is the row to run first after the reboot.

---

## 9. Measurement traps hit, including my own

* **`fail` as a SIGNAL in the checker was a defect in the checker.** The first
  draft of `tb_a_wbase` incremented a signal inside a nested `chk` procedure
  called dozens of times with no wait between calls. Every call would have
  read the same stale value and the process would have resolved them all to a
  single increment, so a bench with forty violations would have reported one.
  Caught by reading, not by running -- and it would never have shown up, since
  the verdict only tests `= 0`. Now a process variable, with the reason in the
  file.
* **`--only tb_llama_top` is a SUBSTRING and matches three benches, six rows.**
  That is what makes it a usable control here, but the trap is the general
  one: `--only` on a non-matching pattern still prints `REGRESSION: PASS` and
  the only tell is `PASS 0`.
* **The mutation table's output deliberately says `F=` and not the word
  regress.sh uses**, because that word matches regress.sh's own `FAIL_RE` and
  a table pasted into a log would read as a failure.
* **A one-phase bench would have reported PASS over a guard it never fired.**
  Phase 2 exists for exactly that reason and is the teeth of phase 1's P1.
* **`mk_shape_scaled` is hardwired to hidden 64 / ffn 128 at every argument**
  (`rtl/llama_map_pkg.vhd:255-278`), so the capacity overrun is UNREACHABLE
  through a region-routed job at any scaled shape: `ceil(128/4)*ceil(64/32) =
  64` beats against a 256 cap. This cost real time. The overflow is reachable
  only through a `FLG_TO_SMP` window with `dst = R_NONE`, whose `n_rows` is not
  bounded by a region size because `seq_desc_fetch.vhd:496-506` skips the
  region check when a route flag names the sink. **A bench that only issued
  region-routed A jobs could not have found this defect at any shape.**
* **I nearly took DSEAM's "no owner" at face value.** The base array has an
  owner in one document and is remaining work in another, in the SAME file,
  eight lines and 480 lines apart. Neither is wrong; they describe different
  integrations. Reading only the remaining-work line produces a plan to
  implement (F), which section 4 argues is the wrong one.
* **The 4 KB literal was in two files with nothing tying them.** Making it a
  generic in `llama_top` does not fix `sim/tb_llama_top.vhd:790`'s local copy,
  which is still an independent `4096`. That file is not this track's. It is
  now at least a duplicate of a NAMED thing rather than of another literal.

---

## 10. Measured and REJECTED -- do not retry

* **Do NOT make `seq_desc_fetch` fetch the base array.** Its descriptor
  address is `resize(fetch_idx & "000", 16) + f_beat` (:576) -- a fixed 8-word
  stride, and the file's header claims 0 DSP *because* of it. A 39-word
  descriptor is not addressable by `step*8`. The fetch would also duplicate
  work `matvec_int4_desc_axi:610-615` already does correctly, and would add a
  `27*ADDR_W`-wide two-bank shadow (2,160 FF at the FK33 geometry) to carry a
  value with, in the (P) design, no reader.
* **Do NOT treat G3 as blocking PACKSTRIPE.** Measured in section 2.1: the
  card binds `matvec_int4_desc_axi`, which reads the base array from the
  descriptor image; `gen_mv4i_desc.py`'s `sub_base()` already emits striped
  bases from the v2 manifest's `pieces`. The two tracks are independent.
* **Do NOT expect a value-level bench to find a wrong base.** Both existing
  weight memories are the fabrication's inverse (section 7). Adding assertions
  to them cannot help; the blindness is in the memory model.
* **Do NOT add a ninth relative property to catch M5.** A uniform translation
  preserves containment, disjointness, contiguity and counts by construction.
  Only an oracle over the bytes can see it.
* **Do NOT run a mutation table against the live working tree** while other
  tracks hold the same file. The snapshot in this run is `git archive HEAD`
  plus five named hunks; the alternative is DSEAM's loss of 14 of 17 rows.

---

## 11. Open, not yet answered

* **Which integration, (P) or (F)?** Not this track's decision. Section 4 is
  the comparison and section 5 is the (P) cost.
* **`matvec_int4_desc_axi` has no non-AXI-Lite start path.** Under (P), D
  would need one, or an AXI-Lite master. Neither exists and neither is costed
  here.
* **M10_guard_ge and M11_port_rev have NO attribution control.** Both survived
  `tb_a_wbase`; whether the six pre-existing rows catch them is UNMEASURED.
  The batch was cut short by a reboot window. Run these two first.
* **M10's boundary case.** The capacity guard's `>` versus `>=` is not probed;
  a 256-beat job would close it. At this shape a 256-beat job needs 512 rows,
  which overflows the 64-deep sampler FIFO (the drain is 4x slower than the
  fill), so closing it needs either a different shape or a different route.
* **The full gate has not been re-established.** `BASELINE_PASS` is 99 in
  `sim/regress.sh`, has not been re-established since `845ea28`, and needs
  **+1 for DSEAM's row and +1 for `sim/tb_a_wbase.vhd`, so 101**. That file is
  not this track's; this is a report, not an edit. No full unfiltered run was
  made -- the box was under TRACK GATEGREEN's own full gate and a contended
  run is not evidence.
* **`sim/tb_llama_top.vhd:790`'s independent `4096`** is still a literal in a
  file this track does not own. If `A_SUB_BYTES` is ever changed from a
  generic map, that file's address decode goes wrong silently.
* **Whether `A_JOB_STRIDE` is worth keeping at all.** DERIVED: the whole
  fabricated address space is `505 * 32,768 = 16,547,840 B`, against
  `165,994,496 B per lane * 27 lanes = 4,481,851,392 B` of 9B weights
  (per-lane figure MEASURED by PACKSTRIPE over the live 249-file set) --
  **270.8x short**. The fabrication cannot be scaled to the real
  model by tuning the generics; it can only be replaced. Whether `llama_top`
  should therefore refuse to elaborate at the 9B shape with `A_BEHAV = false`
  is a question this track raises and does not answer, because
  `sim/elab9b_run.sh`'s `real_A` row currently depends on it elaborating.
* **The 9B descriptor count.** DSEAM DERIVED 505 where both the brief and
  `seq_desc_fetch`'s header say 546. This track did not re-derive it and does
  not contradict it; the 505 above is DSEAM's number used as given.
