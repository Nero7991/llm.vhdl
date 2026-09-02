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
