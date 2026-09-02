# TRACK CARDTOP (dispatcher, in session): the card top design note, pinned against measured interfaces before any RTL is written

**Date:** 2026-08-31. **Tree:** `b86dfe0`. Row N3, STEP 3 of
`docs/PLAN_TO_FIRST_INFERENCE.md`. Written by the dispatcher in session --
NO subagents for RTL tracks (Oren's ruling; the first CARDTOP attempt was
recalled and its drafts are quarantined at
`/mnt/storage/cardtop_flash_draft_2026-08-31/`). Every interface claim here
is MEASURED against the tree at `b86dfe0` unless labelled.

---

## 1. The question, verbatim

> **Build the card top: an RTL top level that composes A+B+C+D FOR THE CARD,
> token-identical to `rtl/llama_top.vhd` (the oracle).** Done when it
> elaborates in Vivado at the real 9B shape and a bench proves it
> token-identical to `llama_top` on the `ref/run9b` stream.

## 2. The answer up front: four decisions, each pinned

- **D1, FORK, do not evolve.** The card top is a NEW file that instantiates
  the same units. `llama_top` stays the untouched oracle. Evolving it was
  considered and rejected: the two changes the card needs (the A binding and
  the region memory) sit in exactly the places whose failure modes the
  oracle's benches cannot see, and a fork's drift is bounded by the
  token-identity bench while an edited oracle's is not.
- **D2, DESCRIPTORS ARE HOST-PREBUILT.** The card builds no A descriptors.
  `tools/gen_layer_program.py` already emits the whole token's 311
  descriptors, checked by `tools/dprog_oracle.py` (39,330 checks, 0 FAIL,
  MEASURED at `78e2f5a` and re-verified since), into an HBM arena placed by
  `tools/hbm_map.py`. The card top's A adapter only PROGRAMS `DESC_BASE` per
  step and pulses GO. On-card descriptor construction is rejected as
  unverified surface for zero benefit.
- **D3, THE REGION FILE BECOMES SIZED PER-REGION BRAM.** 14 regions, 75,840
  elements total at the 9B shape (DERIVED below), ~34 RAMB36 before
  aspect-ratio rounding -- cheap. The flat `NREGION*REGMAX` array with 8
  muxed client slots is the elaboration blocker and goes. **The two-edge
  read latency is preserved exactly**; every adapter depends on it
  (MEASURED, `llama_top.vhd:1066-1073`).
- **D4, THE RMSWIRE DEADLINE IS STRUCTURAL.** The gain loader in the card
  top's norm path must not start while `rmsnorm_rs_mem`'s `w_active` is
  high, and an assertion says so. A value check cannot see this failure
  (MEASURED, TRACK RMSWIRE, `47c9d9c`).

## 3. The interface survey (MEASURED)

### 3.1 The A seam, simulation vs card

`llama_top.vhd:3308` binds `matvec_int4` (no descriptor plane) and drives it
through a register adapter (`llama_top.vhd:3197-3226`): `start` pulse, six
shape registers written at `job_issue`, codebook writes
(`cb_we/cb_addr/cb_data`), x-vector writes, and 128-bit AXI weight masters.
The weight bases are FABRICATED (`A_MEM_BASE + step*A_JOB_STRIDE + p*A_SUB_BYTES`)
and the adapter REFUSES over-capacity jobs (BASEFAB, `d7a6bf7`).

The card's unit is `matvec_int4_desc_axi` (`rtl/matvec_int4_desc_axi.vhd:129`):
an AXI-Lite map (8-bit address, 32-bit data) holding the descriptor base
registers, a GO bit, and STATUS; a dedicated read-only descriptor fetch
master (`d_ar*`, `ADDR_W=40`); 24 weight + 3 scale AXI masters
(`NPORTS_W=24, NPORTS_S=3, AXI_DW=256, ADDR_W=40, MAXB=16, MAXOUT=16` at the
FK33 geometry, ROWS_IF=48). Generics that matter to the card top:
`USE_XEXP_PORT` (the per-token x_exp from the previous stage -- TRUE on the
card, `:155-160`), `CB_STYLE` (the lever, `"distributed"` per ROUTE2/ROUTE3),
`DUAL_CLK` (the HBM/core CDC, TRUE on the card per the shipping engine).

So the card top's A adapter is a DIFFERENT seam, not a wider one: per A-job
step, write the descriptor's HBM address into `DESC_BASE0..`, pulse GO, and
convert A's one-cycle `done` to D's held-level contract exactly as the
simulation adapter does (`llama_top.vhd:3206-3208`).

### 3.2 The descriptor arena (D2's plumbing)

`tools/gen_layer_program.py:741-815`: `hbm_map` places the arena, the base
comes from the manifest's region block (Oren's decision: one file states
every base), and a colliding arena REFUSES to emit. The per-job stride is
`desc_maxb * axi_dw/8 = 16 * 32 = 512 B`, sized from the whole token program
so the base is a property of the model. The arena therefore IS addressable
by `arena_base + job_index * 512` -- which is the whole answer to BASEFAB's
ownerless-integration warning (`docs/WORKLOG.md`, BASEFAB): that objection
was against `seq_desc_fetch`'s fixed 8-word stride fetching descriptors,
and the card top's A adapter is new logic with its own stride.

DERIVED at the 9B shape: 311 A jobs x 512 B = 159,232 B of arena, and the
host DMAs it once per model load, not per token.

### 3.3 The region file

Sizes at the 9B shape (`rtl/llama_map_pkg.vhd:298-318` with
`QWEN35_9B` from `rtl/model_cfg_pkg.vhd:64-71`, NCARDS=1):

| region | elements | | region | elements |
|---|---:|---|---|---:|
| R_X | 4,096 | | R_QG | 8,192 |
| R_XN | 4,096 | | R_KIN | 1,024 |
| R_QKV | 8,192 | | R_VIN | 1,024 |
| R_Z | 4,096 | | R_Y | 4,096 |
| R_BETA | 32 | | R_G | 12,288 |
| R_ALPHA | 32 | | R_U | 12,288 |
| R_ER | 4,096 | | R_H | 12,288 |

DERIVED total **75,840 elements x 16 bit = 1,213,440 bit = 33.7 RAMB36**
before aspect-ratio rounding. The flat array is `14 x 12,288 = 172,032`
elements behind 8 muxed client slots (`NPORT = NUNIT + NVOP = 5 + 3`,
`llama_top.vhd:1092`); the sized version is ~2.2x smaller AND has a BRAM
shape. Access pattern to preserve (`llama_top.vhd:1059-1081`): one element
read port, one element write port, one LANES-wide group read with two
operand selects, one LANES-wide group write; both read ports REGISTERED,
one cycle, which with the adapter's own address register gives the
two-edge latency every adapter depends on. D issues one unit at a time
(`seq_desc_fetch`'s `cur_unit` is a scalar), so the arbitration is
per-region and trivial until D grows overlap -- at which point the arbiter
is real and the comment at `:1080` becomes wrong, exactly as it says.

### 3.4 The norm path and the deadline (D4)

HEAD's `gvr` binds `rmsnorm_rs_mem` unconditionally (`llama_top.vhd:2190`,
RMSWIRE). Its `w_active` output is high through `S_RAW` AND `S_EMIT` and low
in the shift gap; first rise is `S_RAW`, rise-after-fall is `S_EMIT`. The
invisible window is [977, 2006] and a load started inside it reads the
PREVIOUS op's gain with bit-identical output (MEASURED, `47c9d9c`). The
card top gates the gain-load start on `w_active = '0'` and asserts the
gate. GAIN16's codebook (`c094867`) is inside the same block and needs no
card-top-specific handling: it builds from `NORM_W_IMAGE` at elaboration.

### 3.5 What ROUTE3 measured about the composition this top must fit

MEASURED (`8eaaf18`): the composed A+B+C+D with the gain image routes in
`pb_core` at BRAM 351.5/372.5, DSP 2,177, 0 errors, WNS -0.815 with zero of
the 200 worst paths in `d_norm`. The card top adds the region BRAM (~34+)
and removes the fabrication logic; its fit is inside the same envelope.

## 4. The work breakdown, in dispatch order

1. **`region_mem`** (this track's first RTL): the sized per-region memory
   with llama_top's exact port/latency contract, plus a GHDL bench that
   drives both it and llama_top's flat-array process with the same access
   stream and demands identical read data. Self-contained; needed under
   every decision above.
2. **The A adapter**: `DESC_BASE` programmer + GO + done/err conversion,
   with the arena stride 512 and the job counter. Bench: against a BRAM
   arena holding a `gen_layer_program` emission, token of A jobs.
3. **The top itself**: fork of llama_top's composition with D1..D4 applied
   (`matvec_int4_desc_axi` at the FK33 geometry, `USE_XEXP_PORT=true`,
   `CB_STYLE="distributed"`, `DUAL_CLK=true`, real units, `region_mem`,
   `w_active` gate).
4. **The token-identity bench**: the card top against `llama_top` on the
   `ref/run9b` stream, element for element, plus the `w_active` assertion
   and the attribution control (a mutant that loads inside the window must
   be KILLED by the gate, not by luck).
5. **Vivado elaboration at the real shape** (lane, dispatcher-allocated),
   then the fit/timing draw alongside ROUTE3's.

## 5. Explicitly NOT decided here

- **The host interface** (N2's seam wiring, STEP 4): the card top exposes
  D's contract; how the host drives it is `rtl/fk33_seam.vhd`'s decision
  and is out of scope for this note.
- **The x_exp producer** (which stage's output feeds `x_exp_in` per token):
  needs the activation-exponent flow mapped end to end; recorded as the
  first open question for increment 3.
- **The TIMING lever hunt** (-0.815 WNS, `CB_BCAST` suspect): a separate
  queued track, and its cheapest first move is a placement-directive sweep
  on the ROUTE3 checkpoint.

---

## 6. Increment 1 landed: `rtl/region_mem.vhd`, and the teeth it was given

**Added 2026-09-01 by the dispatcher, in session, no subagents.** D3 of
section 2 is implemented and verified. `sim/tb_region_mem.vhd` compares the
DUT against an independent behavioural model of `llama_top`'s flat array on
every port, and prints a check count with a mismatch count.

MEASURED, `REGRESS_SCRATCH=<dir> MV4I_FK33_FILE=/nonexistent bash sim/regress.sh
--only region_mem --jobs 1`, GHDL 1.0.0 mcode, at `b86dfe0` plus the two new
files:

```
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0
```

**A PASS is not evidence until the check has been shown to fail.** Six
mutations of `rtl/region_mem.vhd`, each isolating ONE clause of the section-3
contract, run in a `git archive` tree so the repo was never mutated:

| mutation | what it breaks | verdict |
|---|---|---|
| `A_swap_group_read_selects` | `x_rdata`/`e_rdata` take each other's registered region select | **FAIL 1, bites** |
| `B_ignore_write_byte_enables` | group write ignores `w_be`, writes all lanes | **FAIL 1, bites** |
| `C_element_write_wins_tie` | write order reversed, so the element write wins a same-word tie | **FAIL 1, bites** |
| `D_pad_read_holds_instead_of_zero` | an out-of-size element read holds its previous word instead of returning 0 | **FAIL 1, bites** |
| `E_unregistered_element_select` | output mux uses the LIVE `el_reg` against the REGISTERED word, breaking the one-cycle contract | **FAIL 1, bites** |
| `F_element_write_ignores_pad_guard` | element writes past the region's real size land in the pad instead of being dropped | **PASS 1, DOES NOT BITE** |

**`F` is the bench's resolution floor and is reported under its own name.**
It does not bite because both read paths and the host window independently
guard on `sz_words(r)`, so a word written into the pad is unreadable through
every port the bench can observe. That is not an accident: section 2's D3
records that `llama_top` cannot see an adapter which writes its own pad
either, so **the bench inherits exactly the blindness of the oracle it was
written against.** An adapter that writes the pad remains undetectable here,
and the only checks that could catch it are the assertion-side ones in
increment 2. Do not re-run `F` expecting a kill.

**A MEASUREMENT TRAP HIT IN THIS RUN, and it is the reason the table has an
`edit=` column.** `C`'s first attempt was applied by a regex that matched
nothing. The harness reported `PASS 1` and, read carelessly, that is
indistinguishable from a mutation that does not bite -- it would have been
written up as a second resolution-floor finding when in truth **no mutant was
ever built.** It was caught only because the runner `cmp`s the mutated file
against the pristine one and prints `edit=SAME` or `edit=DIFF` per row. `C`
bites on the re-run with an explicit block swap. **Any mutation harness that
does not prove its own edit landed is reporting the absence of a mutant as
the absence of a defect**, which is the same shape as the eight dead
hand-maintained source lists TRACK GAIN16 catalogued.

**Not claimed:** these six cover the contract's *values* and its *latency*.
They do not cover the group-write/element-read cross collision under
simultaneous traffic on both ports, because D's one-unit-at-a-time rule
means the bench never generates it -- coverage of the input space is not
coverage of the output space, and that case is enumerated here rather than
tested.

---

## 7. Increment 2 landed: `rtl/a_desc_adapter.vhd`, and a witness that took four tries

**Added 2026-09-01 by the dispatcher, in session, no subagents.** Item 2 of
section 4 is implemented and verified. The seam is SMALLER than the
simulation one, exactly as section 3.1 predicted: three AXI-Lite writes per
job (`DESC_PTR_LO`, `DESC_PTR_HI`, `CTRL` bit 0), and no shape registers at
all, because D2 makes the descriptor host-prebuilt.

Two decisions worth recording:

- **The arena base is an INPUT PORT, not a generic.** `tools/hbm_map.py`'s
  header records that a hardcoded copy of this address in
  `server/fk33_seam.h` had already become "a FOURTH model of the same
  address". `hbm_map.py` is the only thing in the repository that chooses an
  arena address; a generic here would make this file the fifth model.
- **There is no AXI-Lite READ path.** Completion and error come from the
  unit's `job_done`/`job_err` PORTS, which it documents as mirroring STATUS
  bits 0 and 2. A read channel would be a second way to learn the same fact,
  free to disagree with the first. The cost is that this adapter cannot
  report `err_code`; the host reads STATUS when `u_err` fires. Deliberate
  narrowing, not an omission.

MEASURED: `tb_a_desc_adapter: PASS -- 2184 checks, 0 mismatches`, a full
token of 311 A jobs plus a refusal and a recovery.

### 7.1 The mutation table

Nine mutations of `rtl/a_desc_adapter.vhd`, run in a `git archive` tree so
the repo was never mutated, every row `cmp`-verified to have actually
changed the file:

| mutation | caught by | verdict |
|---|---|---|
| `N1_go_before_hi` | register-order check | FAIL |
| `N2_ignore_descriptor_stride` | `DESC_PTR_LO` value check | FAIL |
| `N3_accept_one_past_capacity` | refusal check | FAIL |
| `N4_leave_done_without_ack` | **watchdog** | FAIL |
| `N5_error_flag_is_sticky` | error-survives-into-good-job check | FAIL |
| `N6_do_not_count_jobs` | `jobs_issued` check | FAIL |
| `N7_refuse_still_writes` | refusal issued-writes check | FAIL |
| `N8_retry_go_while_unacked` | hazard witness + write count + watchdog | FAIL |
| `N9_u_done_decoded_from_wrong_states` | RTL assertion; witness with it disabled | FAIL |

**ATTRIBUTION, and it is not flattering to the witness.** Every mutant the
hazard witness catches is ALSO caught by the write-count check, the
watchdog, or the in-RTL assertion. Run with each of those disabled in turn,
**the witness earns ZERO kills alone across all nine rows**, and so does the
in-RTL assertion. Both are kept for one stated reason only: they are the
only checks that name the actual protocol violation, where the others
report a generic symptom ("saw 4 writes", "deadlocked"). That is a
diagnosis argument, not a detection argument, and it is recorded as such
rather than dressed up as coverage.

### 7.2 THE WITNESS TOOK FOUR FORMULATIONS AND THE FIRST THREE ALL PASSED SILENTLY

This is the most reusable thing on this increment. The property is one
sentence: *no AXI write may be issued between a completion and D's ack.*
Every version below looked correct when written.

- **v1, driver-declared window.** The driver announced "a completion is
  standing" and the slave flagged writes inside it. Never fired: the
  offending write can land outside the driver's five-cycle hold. **A check
  whose firing depends on the testbench's own timing is not an invariant.**
- **v2, "no write while `u_done` is high", computed from ports.** Sounded
  strictly stronger. Still never fired, because the adapter LEAVES `S_DONE`
  in order to issue the bad write, so `u_done` is low at the moment it
  lands. **The invariant described the state the adapter was in, not the
  obligation it was under.**
- **v3, latch the obligation from `u_done` rising until `u_ack`.** Correct
  at last, and STILL never fired, for a reason that has nothing to do with
  the invariant: it was only EVALUATED by a `chk` at the end of the
  stimulus process, and `N8` deadlocks the driver, so the watchdog ends the
  run with `severity failure` long before that line is reached. **A check
  that only runs at the end of the test cannot fire in any run that dies
  before the end, and the mutants likeliest to violate a liveness property
  are exactly the ones that die early.**
- **v4, report at the point of violation.** Fires.

Three versions of a check that a careful reader would have approved, all
passing for the wrong reason, all found only by insisting the check be
shown to FAIL. The general form: **it is not enough for an invariant to be
true and correctly computed. It must also be reachable in the runs where it
matters.**

### 7.3 A defect in the bench's own verdict, found the same way

The first version counted checks with two SIGNALS. A signal assignment
takes effect after a wait, so every `chk` between two waits computed the
same right-hand side and the last one won: the suite printed **313 checks
for 311 jobs**, i.e. one of the seven checks per job was counted and six
were invisible. `n_mismatch` is what the PASS line is computed from, so two
failures in one job would have been reported as one. Counters are variables
now. **The tell was arithmetic: 313 is not 311 x 7, and nothing else in the
output looked wrong.**

### 7.4 Measured and REJECTED, do not retry

- **`resize(idx,64) * to_unsigned(DESC_STRIDE,32)`** for the descriptor
  offset. `numeric_std`'s `*` returns the SUM of the operand widths, so this
  is 96 bits into a 64-bit target and fails the bound check at elaboration
  time. `DESC_STRIDE` is constrained to a power of two, so `shift_left` is
  both correct and the honest statement of that constraint.
- **Clearing the write log from the driver.** Two processes assigning one
  unresolved signal is multiple drivers; GHDL rejects it at elaboration. The
  driver requests a clear and the slave, the log's only driver, performs it.

### 7.5 Open, not yet answered

- **No mutant is caught by the hazard witness ALONE.** One would have to
  keep the write count at three per job, keep the adapter live, and still
  violate the ordering. Until such a mutant exists, the witness's detection
  value is unproven and only its diagnostic value is established.
- The bench models the unit's completion semantics; it does not run against
  `matvec_int4_desc_axi` itself. That is item 3's job, where the real unit
  and a real descriptor arena appear together.

---

## 8. CORRECTION to D1, 2026-09-01: fork YES, hand-write NO

**D1 in section 2 is upheld and its implementation is corrected.** The card
top must be a separate file and `llama_top` must stay the untouched oracle;
nothing below changes that. What was never stated, and turns out to matter,
is HOW the fork is produced.

**MEASURED at `941a711`:** `rtl/llama_top.vhd` is **5,684 lines**, and the
four decisions touch **about 8.6% of it**:

| decision | region | lines |
|---|---|---:|
| D3, the region file | `llama_top.vhd:1059-1341` | 283 |
| D1/D2, the A seam and its unit | `llama_top.vhd:3196-3400` | ~205 |
| D4, the `w_active` gate | one gate in the norm path | ~5 |
| generics (`USE_XEXP_PORT`, `CB_STYLE`, `DUAL_CLK`) | the A instantiation | ~5 |

**The other 91% is meant to be character-for-character identical**, because
that is precisely what the token-identity bench in item 4 exists to prove.

**A hand-written fork is therefore the wrong tool, and there is direct
evidence rather than a preference.** The first CARDTOP attempt produced a
**5,363-line draft** that had to be quarantined UNREVIEWED and was deleted on
2026-09-01, because nobody could review five thousand lines whose only
correct content is a copy. Hand-copying 91% of a file is not a design task;
it is a transcription task with a defect rate, and the defects land in the
90% that no reviewer will read closely.

**This repository already has the right tool and uses it in four places:**
`hw/fk33/gen_compose4_top.py` (generates `compose4_top.vhd`, and TRACK ROUTE2
edited the generator rather than the output), `sim/ooc_normadapt_extract.py`,
`sim/mk_browse_wrapper.py`, and `tools/gen_llama_top_weights.py`.

**So item 3 becomes `tools/gen_cardtop.py`**, which reads `rtl/llama_top.vhd`
and emits `rtl/fk33_llama_top.vhd` by applying exactly the four decisions.
Three properties follow that a hand-written fork cannot have:

1. **Drift is bounded mechanically, not by discipline.** When `llama_top`
   changes, the card top is regenerated. The token-identity bench then
   measures a difference that is genuinely semantic rather than one of a
   thousand transcription slips.
2. **The diff IS the design.** A reviewer reads the generator's four
   substitutions, not 5,684 lines, and the substitutions are the entire
   content of decisions D1 to D4.
3. **It cannot silently go stale, PROVIDED it is wired into the gate.** That
   proviso is not optional and it is the trap this repository has hit eight
   times: TRACK GAIN16 catalogued **eight dead hand-maintained source
   closures across four tracks**, including three `util_pkg.vhd` copies
   regenerated by a script **nothing schedules**. A generator nothing runs is
   worse than no generator, because the output looks authoritative. The gate
   must regenerate and diff, and fail if the checked-in file differs.

**Explicitly NOT changed by this correction:** `llama_top` is still not
parameterised. Adding a `MEM_STYLE` or `A_BINDING` generic to it was
considered again here and rejected again, for D1's original reason: the two
substitutions sit exactly where the oracle's own benches are blind, so a
generic would put the card's failure modes inside the file that is supposed
to be the reference. A generated fork keeps them outside it.

**Open:** whether `ooc_normadapt_extract.py`'s abort against HEAD (TRACK
RMSWIRE) shares a cause with what `gen_cardtop.py` will have to do. Both
extract a region of `llama_top` by pattern; one has already broken once when
the flat ports it keyed on were removed. **Key the generator on structure
that the token-identity bench would catch the loss of, not on names.**

---

## 9. Increment 3a: `tools/gen_cardtop.py`, and what pointing the oracle's own bench at the fork found immediately

**2026-09-02.** The generator emits `rtl/fk33_llama_top.vhd` from
`rtl/llama_top.vhd` by applying D3 only, and emits
`sim/tb_fk33_cardtop_ident.vhd` from `sim/tb_llama_top.vhd` by repointing its
single DUT instantiation. **With only D3 applied the card top is REQUIRED to
be behaviourally identical to `llama_top`**, so item 4's oracle is available
now rather than after the A binding, and any difference it sees is a defect in
`region_mem`'s contract at the composition level.

It found one on the first run, and it is exactly the class of defect a unit
bench structurally cannot reach.

### 9.1 MEASURED: `region_mem` dropped a 7-bit mask that `llama_top` applies

`llama_top`'s `memp` indexes the group ports as
`v_reg_a(6 downto 0)`, `v_reg_b(6 downto 0)` and `v_reg_d(6 downto 0)` --
**SEVEN bits of an eight-bit signal** (`llama_top.vhd:1041`,
`:1310`, `:1323`, `:1331`). `region_mem` declares those ports as
`unsigned(7 downto 0)` and indexes with the full `to_integer(r_rega)`, no
mask.

For any value with bit 7 set the two disagree. `NREGION` is 14, so a
well-behaved caller never sets bit 7 and the difference is invisible in
normal traffic -- **which is precisely why no unit bench would ever find
it.** `sim/tb_region_mem.vhd` drives `region_mem`'s own ports and cannot see
what `llama_top` does to those signals before they arrive.

The generator now preserves the mask explicitly, in three named signals
rather than in a port-map expression, so it is visible in the generated file
rather than hidden in an actual:

```vhdl
  cm_rega <= "0" & v_reg_a(6 downto 0);
  cm_regb <= "0" & v_reg_b(6 downto 0);
  cm_regd <= "0" & v_reg_d(6 downto 0);
```

**This is the concrete instance of CLAUDE.md's rule that a per-unit evidence
class says nothing about the composition.** `region_mem` passed its own
bench with five of six mutations biting, and was still not a drop-in
replacement. The composition test cost one generator and found it in one run.

### 9.2 A documentation defect in `llama_top`, recorded not fixed

`llama_top.vhd:1301` says of `memp`:

> `-- write-first, so an in-place overtake is visible rather than hidden`

**The code does not do that.** `mem` is a SIGNAL, so a read later in the same
process execution sees the pre-write value however the writes are ordered
above it: the behaviour is READ_FIRST and an in-place overtake is exactly
what is NOT visible. `region_mem`'s header calls it READ_FIRST and matches
the CODE, which is correct by CLAUDE.md's rule that where a document and the
RTL disagree the RTL wins.

**Not fixed here, deliberately:** `llama_top` is the oracle and D1 says it
stays untouched. The comment is wrong, the behaviour is right, and a
one-word edit to the oracle during a fork is exactly the kind of change that
makes a token-identity result unattributable. Recorded for whoever owns
`llama_top` next.

### 9.3 The gate row is the whole point of the generator

`sim:cardtop` runs `tools/gen_cardtop.py --check --bench`, which regenerates
and diffs. It sits beside `sim:ipsync`, which exists because
`ip_repo/*/src/*.vhd` drifted from `rtl/*.vhd` for exactly the same reason.

**Without that row this is a copy, not a fork.** The card top's entire safety
argument is that 91% of it is mechanically re-derived whenever `llama_top`
moves; a generator nothing schedules still produces output that looks
authoritative, and TRACK GAIN16 catalogued eight dead hand-maintained
closures in this repository, three of them regenerated by a script nothing
runs.

### 9.4 Traps hit while writing the generator

- **The port names were wrong in three places.** `region_mem` was written
  against `r_rega`/`r_regb`/`w_regd`; `llama_top` calls them
  `v_reg_a`/`v_reg_b`/`v_reg_d`. Caught by analysis, not by anything subtle
  -- but it is the same root cause as the mask: the unit was specified
  against an imagined caller.
- **`architecture tb of`, not `architecture sim of`.** A rename keyed on the
  wrong keyword left the generated bench declaring an architecture of an
  entity it had just renamed.
- **The bench rename must be SURGICAL.** `tb_llama_top.vhd` refers to
  `tb_llama_top_real`, `_seq`, `_normw` and `_smp` by name in comments, and
  those files exist. A blanket string replace would rewrite references to
  real benches into references to files that do not, producing confident
  wrong documentation. The generator renames the entity, the architecture
  and the verdict string, and nothing else.

---

## 10. Increment 3b, surveyed and specified 2026-09-02, NOT yet implemented

3a proved the generator and the identity oracle. 3b is the A binding (D1/D2)
and the `w_active` gate (D4). **The survey below is MEASURED against
`llama_top` at `2a7e3a7`**; the RTL is not written, and this section exists so
whoever writes it does not have to re-derive the boundary.

### 10.1 The span

The A block is `llama_top.vhd:3196` (its banner) to `:3577` (`end generate`),
**382 lines**, containing one `u_mv : entity work.matvec_int4` instantiation
and one `ap : process(clk)`.

### 10.2 What the card KEEPS, DROPS and ADDS

**KEEPS, because both units have these ports and D's contract is unchanged:**
`rdy`, `dn`, `uerr`, `ep`, `yexp` (the D-facing handshake and epoch),
`x_we`/`x_waddr`/`x_wdata` (the activation feed), and
`y_we`/`y_addr`/`y_data` (the result sink, which must stay a sink that
CANNOT REFUSE a beat: `matvec_int4`'s `y_we` has no ready and a stall LOSES a
beat, and the descriptor unit inherits that).

**DROPS, all of it, because the descriptor is host-prebuilt (D2):**
`r_rows`, `r_cols`, `r_shift`, `r_wexp`, `r_xexp`, `r_mode`, `r_wbase`
(`A_ROWS_IF*32` bits of FABRICATED weight bases), `r_wbeat`, `r_sbase`,
`r_sbeat`, and `cb_we`/`cb_addr`/`cb_data`. **That is the entire register
adapter.** It also drops the `S_CBGAP` interlock, which exists only because
`cb_we` and `start` must not share an edge in `matvec_core`; with no codebook
writes there is no edge to avoid. **Do not port S_CBGAP forward "to be
safe": a state that cannot be entered is not caution, it is a state nobody
will ever be able to justify removing.**

**ADDS:** an `a_desc_adapter` instance (landed, increment 2) plus the
descriptor fetch master `d_ar*`/`d_r*`, and the FK33 geometry on the unit:
`NPORTS_W=24, NPORTS_S=3, AXI_DW=256, ADDR_W=40, MAXB=16, MAXOUT=16`,
`ROWS_IF=48`, `USE_XEXP_PORT=true`, `CB_STYLE="distributed"`,
`DUAL_CLK=true`.

### 10.3 The three things most likely to go wrong, named in advance

1. **`AXI_DW` goes 128 to 256 and `ADDR_W` 32 to 40.** Every width in the
   kept `y_*`/`m_*` plumbing is derived from those two. `A_ROWS_IF` also goes
   to 48, so `y_data` is `48*64` and not `A_ROWS_IF*64` at the simulation
   value. **A width mismatch here analyses cleanly in some places and
   truncates silently in others.**
2. **`ARLEN` IS 4 BITS ON THE FK33's HBM SLAVE.** It is AXI3, so 16 beats is
   the hard burst cap, not AXI4's 128. `MAXB=16` above is that cap, and a
   module's own assert bounds what THAT MODULE permits and says nothing
   about what the slave accepts.
3. **D4, the `w_active` gate.** The gain loader must not start while
   `rmsnorm_rs_mem`'s `w_active` is high. **A VALUE CHECK CANNOT SEE THIS
   FAILURE** (MEASURED, TRACK RMSWIRE `47c9d9c`): the window is 1,030 cycles,
   `[977, 2006]`, during which the design is wrong and every value is still
   right. It needs an assertion plus an attribution control -- a mutant that
   loads inside the window must be KILLED BY THE GATE, not by luck.

### 10.4 Why the identity oracle gets WEAKER at 3b, and what replaces it

3a's oracle worked because D3 alone must not change behaviour, so
`hash(R_X) = 38863` is a complete statement. **3b deliberately changes the A
binding, so the card top is NO LONGER required to match `llama_top` on a
bench that fabricates weight bases** -- `llama_top`'s adapter computes
`A_MEM_BASE + step*A_JOB_STRIDE + p*A_SUB_BYTES` and the card fetches a real
descriptor instead.

So the pin in `sim/cardtop_ident_expect.txt` will stop holding, and **the
correct response is NOT to re-measure it from the card top.** That would
assert the fork equal to itself. Item 4's bench must instead drive both tops
from the SAME descriptor program (`tools/gen_layer_program.py`, 311
descriptors, checked by `tools/dprog_oracle.py` at 39,330 checks 0 FAIL) so
that the fabricated bases and the fetched descriptors describe the same
arithmetic. **Until that bench exists, 3b has no oracle at all**, and that is
the reason 3b is specified here rather than started.

### 10.5 Open, not yet answered

- **Which stage's output feeds `x_exp_in` per token.** Already recorded in
  section 5 as the first open question; `USE_XEXP_PORT=true` makes it load
  bearing rather than cosmetic.
- Whether the kept `y_*` sink needs resizing for `ROWS_IF=48` or whether the
  existing buffer logic is already parameterised on it.
- Whether `DUAL_CLK=true` puts the D-facing handshake in a different clock
  domain from `ap`, which would make the kept `rdy`/`dn` conversion a CDC
  rather than a rename. **This is the one that would invalidate the "KEEPS"
  list above, so check it FIRST.**

### 10.6 RESOLVED 2026-09-02: `DUAL_CLK` does NOT make the kept handshake a CDC

Section 10.5 flagged this as the item to check FIRST, because it would have
invalidated the "KEEPS" list. It does not.

MEASURED in `rtl/matvec_int4_desc_axi.vhd`: **`s_axi_aclk` IS the core clock**
(`:176`, its own comment says so), and `m_aclk` is the HBM AXI clock, ignored
when `DUAL_CLK = false` (`:179`). The internal units are mapped
`clk => s_axi_aclk, aclk => m_aclk` (`:590`, `:651`), so **the control path --
AXI-Lite, `job_done`, `job_err`, `x_we`, `y_we` -- is in the CORE domain at
either setting, and only the HBM-facing masters cross.** The CDC is inside
the unit.

**This retroactively validates increment 2.** `rtl/a_desc_adapter.vhd` is
written on a single `clk` and drives `s_axi_*`; since `s_axi_aclk` is the core
clock, the adapter is already in the right domain and needs no change when
`DUAL_CLK` is switched on. That was not reasoned about when it was written, so
it was luck rather than judgement, and it is recorded as such.

**The unit's header records the failure that would otherwise have been ours**
(`:407-415`): the descriptor capture was hand-rolled in the core domain first
and **MEASURED to fail the moment `DUAL_CLK` was switched on**, because the
descriptor slave answers in the AXI domain -- "the weight path had a CDC and
the CONTROL path did not". The fix is inside the unit. **Do not re-derive
this; the asymmetry is the whole hazard and it is already closed.**

---

## 11. D5, 2026-09-02: the host read window is what stops the region file being a BRAM

**This overturns the reasoning behind D3, though not D3 itself.** D3 said the
flat `NREGION*REGMAX` array "is the elaboration blocker and goes". The array's
SHAPE was never the blocker.

### 11.1 The measurement that says so

Elaborating `fk33_llama_top` at the real 9B shape, `synth_design -rtl`,
Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`:

```
WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from
Record/Structs for RAM  mem_reg with 2752512 registers
```

**2,752,512 is the SAME number as the recorded crash**
(`HOptDfg::dissolveRam at 2,752,512 bits`, `sim/mk_browse_proj.tcl`). DERIVED:
`region_mem`'s store is `14 regions x 1,536 words x 128 bits = 2,752,512`,
exactly `llama_top`'s `14 x 12,288 x 16`. **Reorganising a flat array into
per-region banks does not reduce what the tool has to dissolve.**

### 11.2 The actual cause

`llama_top` exposes `hr_reg`/`hr_addr`/`hr_data` as **TOP-LEVEL PORTS**
(`llama_top.vhd:690-692`): a COMBINATIONAL, full-range random read into the
region file. **A memory with a combinational read port cannot be a BRAM**, so
while that port exists the store is LUTs and flip-flops whatever shape it has
and whatever `ram_style` asks for.

**Nothing on the card uses it.** MEASURED: no file under `hw/fk33/rtl/`
references `hr_reg`, `hr_addr` or `hr_data`. Its only consumer is
`sim/tb_llama_top.vhd`, which reads results through it.

### 11.3 D5, decided by Oren 2026-09-02: gate it with a generic

`region_mem` and the generated card top take `HOST_WINDOW : boolean := true`.

- **true, the default** -- simulation. `sim/tb_fk33_cardtop_ident.vhd` runs
  here, and **this is the configuration in which identity with `llama_top` is
  proven** (`hash(R_X) = 38863`).
- **false** -- the card. `hr_data` reads zero, the per-region banks carry
  `ram_style = "block"`, and they are free to infer BRAM.

**The honest caveat, stated rather than buried: identity is proven at `true`
and the card is built at `false`, so the proven configuration is not the built
one.** They differ by exactly one OUTPUT port that no card logic reads. Two
options were rejected: registering the window keeps one configuration but
changes behaviour, so the oracle bench's own expectations would have to be
adjusted, and **an oracle you had to adjust is a weaker oracle than one you
did not**; keeping it combinational keeps the region file at 2.75 Mbit of LUT
and flip-flop, which is the thing D3 exists to avoid.

`region_mem` was also restructured so each region declares its OWN `bank`
inside the generate, giving the tool 14 independent 2-D arrays rather than one
3-D object it warns about by name. The unit bench passes unchanged:
`5402 cycles compared, 0 mismatches`.

### 11.4 The pad contract is UNVERIFIED, and one more mutation proved it

Re-running the mutation table against the restructured file, every row
`cmp`-verified to have changed it:

| mutation | verdict |
|---|---|
| `A_swap_group_read_selects` | FAIL, bites |
| `B_ignore_write_byte_enables` | FAIL, bites |
| `C_element_write_wins_tie` | FAIL, bites |
| `D_pad_read_holds_instead_of_zero` | FAIL, bites |
| `E_unregistered_element_select` | FAIL, bites |
| `F_element_write_ignores_pad_guard` | **PASS, does not bite** |
| `G_host_window_ignores_region_size` (new) | **PASS, does not bite** |
| **`F` and `G` TOGETHER** | **PASS, does not bite** |

`F` and `G` are the two halves of the pad contract -- one writes past a
region's real size, the other reads past it -- and the obvious hypothesis was
that neither is observable alone but their conjunction is. **It was tested and
it is false.**

**The reason is a STIMULUS gap, not a checker gap**, and that distinction is
the useful part. The bench never drives an out-of-size access, so with the
write guard removed **no pad write ever happens**, and there is nothing for
the unguarded read to find. No checker can discriminate a defect the stimulus
never triggers. **Coverage of the input space is not coverage of the output
space, and here the input space itself was never reached.**

Note this is also an INTENTIONAL divergence from `llama_top`, which is why the
identity bench cannot close it either: `llama_top`'s array is padded to
`REGMAX` so an out-of-size write lands harmlessly inside it, while
`region_mem` DROPS it (`rtl/region_mem.vhd` header). The two genuinely differ
there, deliberately.

**Open:** a bench that deliberately drives `el_waddr` past `sz_words(r)` would
discriminate `F`. It would also make the intentional divergence above
observable, so it must assert `region_mem`'s behaviour and NOT `llama_top`'s.
