# Every A descriptor in the token program carries the SAME baked `x_exp`, and the card build reads it

> **Status: DERIVED from reading the RTL, the generator and the build's own
> generic map. NOT MEASURED. Nothing has been run.** The falsification test is
> stated at the bottom and costs one bench run. This is written now, before the
> bitstream lands, because if it is right it is the class of defect that
> presents as an ordinary wrong answer with no fault raised anywhere, and
> because the evidence is all in files that are about to be built into a card.

## The question, verbatim

> `tools/gen_layer_program.py` refuses to emit subsystem A's descriptors
> without `--x-exp`, and calls it *"the activation vector's BFP exponent, a
> per-token runtime value the previous stage produces; nothing in the manifest
> supplies it."* The v2 seam writes the program into the card's windows ONCE
> per model. So what happens on the second token, whose exponent is different?

Date: 2026-09-17, while the `FK33_CARD=1` A+B+C+D bitstream was routing.

## The answer, up front

**Two things, and the second is the larger one.**

1. **The card build takes `x_exp` from the DESCRIPTOR, not from the live
   port.** `hw/fk33/rtl/fk33_engine.vhd:1309` sets `USE_XEXP_PORT => false`
   explicitly, and :1118 says *"USE_XEXP_PORT is false, so this is never
   read."* The RTL's own comment on that generic
   (`rtl/matvec_int4_desc_axi.vhd:173-178`) says the descriptor's copy is
   **"stale by construction"** in the integrated system, and ends *"Which one
   the FK33 build uses is an integration decision."* **That decision has never
   been made; the default stands.**

2. **`gen_layer_program.py` bakes ONE `x_exp` into EVERY A descriptor of the
   token.** `a_jobs_for(steps, manifest_path, x_exp, ...)` takes a scalar and
   passes it unchanged to `build_descriptor(... st.n_rows, x_exp, ...)` for
   every step. So it is not merely stale across tokens: **within a single
   token, every A job carries the exponent of the host's input row**, while
   each job's actual input is the previous stage's output with its own
   runtime exponent.

The mantissas are unaffected. What is wrong is `y_exp`, and `y_exp` is what
D propagates.

## Why it propagates rather than staying local

`rtl/matvec_int4_desc_axi` computes, per the descriptor format doc's own
formula, `y_exp = w_exp + x_exp - out_shift`. Subsystem D then takes the
exponent **from the unit's output**, not from its own model of it:

```vhdl
-- rtl/seq_opdec.vhd:531
x_exp <= signed(u_y_exp((x_unit+1)*EXP_W-1 downto x_unit*EXP_W));
```

So an A job whose descriptor carries a wrong `x_exp` reports a wrong `y_exp`,
D records that as the region's exponent, and the next stage consumes it. An
error of `d` in the baked exponent is a factor of `2^d` on that tensor,
carried forward.

## The chain, file by file

| link | evidence |
|---|---|
| the card's A unit is `matvec_int4_desc_axi` | `rtl/a_desc_adapter.vhd:7` -- *"THE CARD'S UNIT IS DIFFERENT: it is `matvec_int4_desc_axi`"* |
| D reaches it through a pointer and a GO, and patches nothing | `a_desc_adapter.vhd:9-11` -- *"three AXI-Lite writes per job: DESC_PTR_LO, DESC_PTR_HI, CTRL"* |
| the descriptor carries `x_exp` | `docs/2026-08-28_matvec-descriptor-format.md:191` -- `ext word 2 (E + 0x10) : [31:0] x_exp (i32)` |
| the unit chooses descriptor or port | `rtl/matvec_int4_desc_axi.vhd:638` -- `v_xexp <= x_exp_in when USE_XEXP_PORT else lo32(dw(EXT0 + 2));` |
| the card chooses the DESCRIPTOR | `hw/fk33/rtl/fk33_engine.vhd:1309` -- `USE_XEXP_PORT => false,` |
| the generator bakes one value for all jobs | `tools/gen_layer_program.py:666, :775` |
| the generator says it is a runtime value | `gen_layer_program.py:1176-1180`, the refusal text |
| D propagates the unit's `y_exp` | `rtl/seq_opdec.vhd:531` |

## What the project already knew, and what it did not

**This is not a new discovery of the generic.** `sim/tb_matvec_fk33_desc_xexp.vhd`
exists for exactly it, and it is a good bench: under `XEXP_PORT` it writes the
descriptor's own `x_exp` **seven too large** and drives the true value on the
port, so a mux wired the wrong way fails rather than passing on agreement. Its
teeth are MEASURED (`CASE 0: Y_EXP MISMATCH got 13 want 6`).

Its closing paragraph is the gap, verbatim:

> **WHAT IT DOES NOT COVER.** It elaborates `USE_XEXP_PORT = true` at
> `DUAL_CLK = false` only, and **it says nothing about WHICH source the FK33
> build should use** -- that build sets the generic false and puts `x_exp` in
> the descriptor, and this row does not argue with it.

So the branch was proven to WORK and was deliberately not chosen. The reading
above is that not choosing it is wrong for the composed card, and **nothing in
the tree connects that bench's existence to the fact that a whole token's
descriptors now come from one `--x-exp` argument.** The two facts have never
been in the same place until this file.

`sim/mv4i_desc_mutations.py:446` also names it, as row N1, class GEN: *"guarded
by a generic this harness does not set"* -- i.e. it was correctly recorded as
an untested branch rather than a passing one.

## What this does NOT establish

* **It is not measured.** No bench was run, no simulation, no hardware. Every
  claim above is a reading.
* **It does not establish that `--x-exp 0` is what the card will be given.**
  `0` is what was passed while generating a program to exercise the host
  driver, and any value has the same problem.
* **It does not establish the magnitude.** How far the true per-stage exponents
  drift from the host row's is unknown and is a property of the model's
  activations, not of this code. If a normalisation stage pins every
  intermediate to the same block exponent, the defect could be small or absent
  -- and that is a real possibility worth checking before acting, because
  `rms_norm` is exactly the kind of stage that would do it.
* **It says nothing about whether `x_exp_in` is WIRED** in the composed top, as
  opposed to merely present. Turning the generic on requires a source for the
  live exponent at each job, and the only per-token value the seam has is
  `host_x_exp`, which is the HOST ROW's exponent -- the right answer for the
  first A job of a token and not obviously for the rest.

## The falsification test, which is cheap

**Run a whole token through `sim/tb_llama_top*` twice with two different host
activation exponents and compare the output mantissas.** If the descriptors'
baked `x_exp` is genuinely consumed, changing only the host row's exponent
changes `y_exp` reporting while the descriptors stay put, and the divergence
appears at the first A job. The benches already run whole tokens
(`sim_tb_llama_top_seq`, 300 checks) so this is a stimulus change, not a new
bench.

A second, even cheaper one: **grep the existing token benches for how they
supply A's descriptors.** If they build them per-run from the live exponent,
they are not exercising the card's configuration at all, and that alone would
explain why 300 passing checks have never seen this.

## Open, not yet answered

* **Whether `out_mode` makes `y_exp` irrelevant for some or all A jobs.** Not
  investigated. If a job's output is consumed in a fixed-point mode that
  ignores the block exponent, that job is unaffected.
* **Whether D's region bookkeeping overrides the unit's `y_exp` anywhere.**
  `seq_opdec.vhd:531` is the only assignment found, and `:665` shows
  `host_x_exp` is used only at `T_PUB`, the publish of the HOST region. But the
  whole of D was not read.
* **What the right fix is.** Two shapes are visible and neither was chosen
  here: set `USE_XEXP_PORT => true` and find a live per-job exponent for
  `x_exp_in`, or have the host rewrite the A descriptors' `x_exp` word per
  token. The second is 505 descriptors of DMA per token and defeats the point
  of writing the program once; the first needs a source the seam may not have.

---

## ADDENDUM, same day: the second cheap test was run, and it strengthens the finding

**The first falsification test proposed above CANNOT WORK, and finding out why
is the more useful result.**

`sim/tb_llama_top*` instantiates `rtl/llama_top.vhd`, and **`llama_top` uses
`matvec_int4`, a unit with NO DESCRIPTOR PLANE AT ALL.** The card uses
`matvec_int4_desc_axi`. `rtl/a_desc_adapter.vhd:3-7` states the difference
outright:

> `llama_top`'s adapter (llama_top.vhd:3196-3235) bridges D to `matvec_int4`,
> a unit with no descriptor plane, by holding six shape registers and
> fabricating weight base addresses. **THE CARD'S UNIT IS DIFFERENT:** it is
> `matvec_int4_desc_axi`, which fetches a host-prebuilt descriptor over its
> own read master.

So running a whole token at two different host exponents would exercise the
FABRICATED path and say nothing about the descriptor's `x_exp`. **No
whole-token bench in this repository exercises the card's A binding**, which is
the direct answer to why 300 passing checks in `sim_tb_llama_top_seq` have
never seen this.

The generated card top says the same thing from the other side, and names the
two arms (`rtl/fk33_llama_top.vhd:738-749`):

> **false** = llama_top's `ga_real`, driving `matvec_int4` from a FABRICATED
> weight base; that is the configuration in which identity with llama_top is
> PROVEN, and it is the default so the identity bench keeps meaning what it
> says. **true** = the card: `ga_desc`, which drives the descriptor plane of
> `matvec_int4_desc_axi` living outside this top in `fk33_engine`.
>
> **THE TWO ARE NOT EQUIVALENT AND MUST NOT BE READ AS A TUNING CHOICE.**

`hw/fk33/rtl/fk33_card.vhd:217` sets `A_DESC => true`. **The bitstream now
routing is the arm no whole-token bench covers**, and the arm whose identity
with `llama_top` is explicitly NOT the proven one.

## And the design says the descriptors are written once, in as many words

`rtl/fk33_llama_top.vhd:751-754`:

> `A_N_JOBS : positive := 311` -- Descriptors the arena was sized for [...]
> **DERIVED at the 9B shape: 311 A jobs x 512 B = 159,232 B, DMA'd once per
> model load rather than once per token.**

So "written once per model" is the stated intent, not an accident of how the
program was generated. A per-token value baked into a once-per-model artefact
is therefore a design question with an owner, not a bug in the generator.

## Revised status

The reading is unchanged and the two supporting facts are now stronger:

* the card's A binding is `A_DESC = true`, **covered by no whole-token bench**;
* the A descriptors are **intended** to be written once per model load, and
  carry a field the generator itself calls a per-token runtime value.

**Still not measured.** What would measure it is a whole-token bench at
`A_DESC = true` against `matvec_int4_desc_axi`, which does not exist. That is
the real gap this file found, and it is larger than the `x_exp` question:
**the card's A path has unit coverage and no token-level coverage.**

---

## SECOND ADDENDUM: the path that HAS produced correct arithmetic on this silicon says the value is per-job and not knowable in advance

This is the strongest evidence in the file and it is a docstring, not a
derivation. `hw/fk33/host/fk33_run_layer.py:398-402`, `make_layer`:

> """The layer's A jobs, their descriptors' inputs, and the seams each one
> reads and writes. No card, no /dev, and **no descriptor is built yet: the
> x_exp a descriptor carries is a property of the vector that reaches the job,
> which in chained mode is not known until the previous job has run.**"""

That is the tool behind
`docs/debugging/2026-08-29_first-layer-in-sequence-on-silicon.md` and the
whole-token run: 88,128 result rows compared element for element against
`ref/run9b`, zero differ, in `chained` mode where every activation after the
layer input is the card's own output. **It gets the right answer, and it gets
it by building every A descriptor at run time from the exponent of the vector
that actually arrives.**

The v2 card path does the opposite by construction:
`rtl/fk33_llama_top.vhd:751-754` says the 311 descriptors are "**DMA'd once
per model load rather than once per token**", and `gen_layer_program.py:666`
takes a single `--x-exp` scalar for all of them.

**Two paths, opposite answers to the same question, and the one that is
demonstrably correct on hardware is the one the card build does not use.**

### What this changes and what it does not

* It is **corroboration, not measurement.** No run of the `A_DESC = true` path
  has happened. But the claim is no longer only a reading of the RTL: the
  project's own working host tool states the requirement in its docstring and
  satisfies it by rebuilding per job.
* It **identifies which of the two candidate fixes matches known-good
  behaviour.** The "host rewrites the descriptors" shape is what
  `fk33_run_layer` already does; the `USE_XEXP_PORT => true` shape is the
  cheaper one but needs a live per-job exponent source that the seam may not
  expose. Neither is chosen here.
* It **sharpens the cost objection I raised against rewriting.** I wrote that
  rewriting 311 descriptors per token "defeats the point of writing the
  program once". `fk33_run_layer` shows the rewrite is not the whole
  descriptor -- only the fields that depend on the arriving vector -- and it
  does it per JOB rather than per token, which is more work, not less. So the
  cost objection stands and is if anything understated. That is an argument for
  the port, not against the finding.

### The one measurement that would settle it, restated

Not a bench on `llama_top` -- that arm uses `matvec_int4` and cannot see this.
**Drive `fk33_run_token.py` on hardware and compare against a run in which the
descriptors' `x_exp` is deliberately frozen at one value**, which is exactly
what the card build does. If the frozen run diverges, the card build diverges.
That is a host-side change to a tool that already exists, and it is Oren's run
because it touches the card.

---

## THIRD ADDENDUM: the live per-job exponent already exists, and the sibling generate arm already uses it

The two fixes listed at the top were written as if a live exponent source might
not exist. **It does, it is architecture-level, and `ga_real` -- the OTHER arm
of the same generate -- reads it per job today.**

`rtl/fk33_llama_top.vhd:1202`:

```vhdl
signal exp_rd_data : signed(EXP_W-1 downto 0);
```

Declared at architecture level, before any `generate`, so it is in scope for
**both** arms. `ga_real` (`A_DESC = false`, from :4050) latches it at job
issue:

```vhdl
-- rtl/fk33_llama_top.vhd:4374, inside ga_real
r_xexp <= std_logic_vector(resize(exp_rd_data, 32));
```

and hands it straight to `matvec_int4` at :4180 as `x_exp => r_xexp`.

**So the arm whose identity with `llama_top` is PROVEN takes the exponent from
the region's live exponent store, per job. The card's arm, `ga_desc` (:3702),
takes it from a descriptor written once per model load.** Those are the two
arms of one `if A_DESC generate`, and they disagree about the one value the
generator calls a per-token runtime quantity.

This is the same disagreement `fk33_run_layer.py`'s docstring describes from
the host side, now visible inside a single RTL file.

### What this changes about the fix

The `USE_XEXP_PORT => true` shape is **cheaper than it looked**, because the
source is not missing:

1. `ga_desc` routes `exp_rd_data` out of `fk33_llama_top` as a new port;
2. `fk33_card.vhd` wires it to `fk33_engine`'s `x_exp_in`;
3. `fk33_engine.vhd:1309` becomes `USE_XEXP_PORT => true`.

**Every one of those three files is GENERATED** (`tools/gen_cardtop.py`,
`hw/fk33/gen_fk33_card.py`, `hw/fk33/gen_fk33_engine.py`), so all three edits
go in the generators and `fk33_engine.vhd:1118`'s comment -- *"USE_XEXP_PORT is
false, so this is never read"* -- is the line that has to stop being true.
Adding a port to a block-design cell is subject to the recorded packager rules:
`natural` is not a port type and no function of a generic may size a port, but
`signed`/`unsigned` of a plain generic expression are accepted, MEASURED.

### The one design question it raises, and it is not answered here

**`ga_real` latches the exponent at job ISSUE; A on the card reads `x_exp_in`
when it processes the descriptor, which is after the GO.** So a direct wire is
not sufficient -- the value must be HELD stable for the duration of the job,
which means a register in the adapter path and a statement of when it is
sampled. Getting that edge wrong is the recorded `seq_desc_fetch` `go`
level-vs-pulse defect in a new place: *"read the driver's stated contract, and
where they differ take the weaker one."*

**Still nothing measured.** What this addendum establishes is only that the
fix does not need a new signal, and that the design already contains a
per-job answer to the question the card's arm answers once per model.

---

## FOURTH ADDENDUM, 2026-09-18: THE FIX LANDED AS THE LIVE PORT, AND THE CARD ARM HAD NEVER CLAIMED THE EXPONENT READ PORT AT ALL

Oren chose shape (b), the live port, on 2026-09-18. What was found on the
way in, and what was built:

### The arm did not merely read the wrong source; it read no source

The third addendum said `ga_real` latches `exp_rd_data` per job and `ga_desc`
does not. Reading `ga_desc` for the edit showed something the addendum did
not say: **`a_exp_region` is driven at job issue in `ga_behav`
(`fk33_llama_top.vhd:3472`) and in `ga_real` (`:4251`), and in `ga_desc` it
was not driven anywhere.** It sat at its `(others => '0')` default. So the
card arm was not choosing the descriptor's copy over the live one; it had
never addressed the exponent store, because the descriptor carried a value
and nothing in the arm needed another. The live source was in scope, per the
third addendum, and unused.

### What was built (all four files are generated; the generators were edited)

| generator | emits | change |
|---|---|---|
| `tools/gen_cardtop.py` | `rtl/fk33_llama_top.vhd` | new output `a_x_exp(31..0)`; `ga_desc` drives `a_exp_region <= job_src; a_exp_seg <= "00"` at issue (the sibling arms' exact lines); `S_GO` asserts `exp_rd_valid` and latches `r_xexp <= resize(exp_rd_data, 32)` on the edge `ad_start` first rises; `gnd_a` ties the port off in the other arm |
| `hw/fk33/gen_fk33_engine.py` | `hw/fk33/rtl/fk33_engine.vhd` | generic `USE_XEXP_PORT : boolean := false`, forwarded to `matvec_int4_desc_axi`; port `d_x_exp(31..0) := 0` replaces the `x_exp_zero` signal on `x_exp_in` |
| `hw/fk33/gen_fk33_card.py` | `hw/fk33/rtl/fk33_card.vhd` | picked the new port up unaided (the wrapper walks the entity) |
| `hw/fk33/gen_pcieep.py` | `hw/fk33/build_fk33_pcieep.tcl` | under `FK33_CARD=1`: `set_property CONFIG.USE_XEXP_PORT {true}` on `eng` with a readback that errors on anything but true, and `connect_bd_net card/a_x_exp eng/d_x_exp` in `CARD_SEAM_TO_ENG` |
| `hw/fk33/gen_compose4_top.py` | `hw/fk33/rtl/compose4_top.vhd` | regenerated; the `c4stale` gate row caught it (the top exports every engine port, so a new engine port is a new top port) |

**The generic defaults FALSE and follows `FK33_CARD`, deliberately.** The
engine-only host flow (`fk33_run_layer.py`) builds every descriptor at run
time with the right `x_exp` and drives no port, so flipping the default
would break the flow that has produced element-exact results on silicon.
`gen_pcieep.py` reads the same environment test for the CONFIG and for the
net and refuses to run if the two ever disagree.

### The sample edge, answered

The third addendum left open when the value is sampled and how it is held.
`r_xexp` is written in `S_GO`, which is entered only after `S_XRD` has run
to `k = j_cols + 1`, so the source region's exponent has been captured for at
least `j_cols` cycles (the same `exp_rd_valid` assertion `ga_real` makes in
`S_EXP`). It is written on the SAME edge `ad_start` first rises. The adapter
then issues three AXI-Lite writes and the unit fetches a 512 B descriptor
before reaching `S_CHECK`, where `v_xexp <= x_exp_in` is first read
(`matvec_int4_desc_axi.vhd:638`, combinational). `r_xexp` is next written at
the next `S_GO`, which cannot happen before this job has retired
(`S_RUN -> S_DONE -> u_ack -> S_IDLE -> job_issue`). So the port is stable
under every read of the job. `act_unit` is latched at issue, so the exponent
mux cannot move under `S_GO` either.

### What was MEASURED, and what was not

* `sim:tb_fk33_cardtop_adesc` elaborates `A_DESC = true` with the change and
  reports `a_x_exp` driven: **checks=14 bad=0** (was 13).
* `sim:tb_fk33_cardtop_ident` (the `A_DESC = false` identity bench):
  **PASS 108**, unchanged, so the other arm is untouched.
* `sim:cardtop`, `sim:runguard`, `sim:kvmap`: green. `sim:c4stale` went RED
  on the first run (27 diff lines, the new port) and green after regenerating
  `compose4_top.vhd`. That is the gate working, not a defect.
* `hw/fk33/rtl/fk33_engine.vhd` analysed, elaborated and ran 1 us under
  `ghdl-mcode` with the new generic and port bound.
* `pcieep_build.sh --bd-only` under `FK33_CARD=1`: `FK33_XEXP_PORT true`
  (the readback executed and accepted Vivado's value), `FK33_UNCONNECTED
  count=0`, `FK33_BD_VALIDATE OK`, `FK33_BD_ONLY_DONE`, 0 `^ERROR`. The 32
  `[BD 41-1377]` address-overlap warnings are the same 32 the routed
  2026-09-18 build carries, MEASURED by `grep -c` on both logs.

**Not measured, and still the gap this file is about:** no bench runs a job
through `ga_desc` against a descriptor-plane engine, so the VALUE reaching
`x_exp_in` has not been compared with anything. The check for that is the
card: `server/tests/run_prompt.c`'s first-divergence report against
`reference_tokens.txt`. If the card diverges at the first A job with the
port build and did not with the descriptor build, the sample edge above is
wrong; if it diverges identically in both, the defect is elsewhere and this
fix was necessary but not sufficient.

### Mutant of the wire, MEASURED, and it found a second thing

The `("a_x_exp", "d_x_exp")` row was removed from `CARD_SEAM_TO_ENG` in the
generator (the generator, not the emitted Tcl, which `pcieep_build.sh`
regenerates) and `--bd-only` re-run under `FK33_CARD=1`:

```
FK33_UNCONNECTED count=1
FK33_UNCONNECTED pin /eng/d_x_exp
FK33_UNCONNECTED FAIL: 1 module input pin(s) have no driver and no tie-off: /eng/d_x_exp.  An unconnected input is ZERO.  Connect it or tie it off explicitly.
```

Control (the unmutated generator, same session): `count=0`, `FK33_BD_ONLY_DONE`.
Killed, attributed to the check.

**AND VIVADO ITSELF SAID NOTHING.** `grep -c 41-759` on the mutant's log is
**0**. `validate_bd_design` ran (15 s, peak 3,830 MB) and raised no
`[BD 41-759]` for `/eng/d_x_exp`, where it had raised one for
`/card/a_arena_base` the day before. The difference is that `d_x_exp` is
declared `:= (others => '0')` in the engine's entity and the card wrapper
strips defaults from its ports. **So a module-reference input WITH a VHDL
default that is left unconnected produces no warning of any severity: it is
tied to the default silently.** The 41-759 that led to the unconnected-pin
check is the loud case; this is the quiet one, and the engine's whole
D-facing surface (`d_x_we`, `d_x_waddr`, `d_x_wdata`, `job_index`, and now
`d_x_exp`) is declared with defaults. Had the net been forgotten, the port
build would have read `x_exp = 0` for every job with no message anywhere,
which is exactly the symptom this file describes, arrived at by a different
road. The net-based check is therefore the ONLY guard on this wire, and it is
gated in every `FK33_CARD=1` build.
