# What is actually left before the card can generate a token?

Date: 2026-09-05. Written after Oren's direction: *"It's okay if we don't hit
200MHz, let's prioritise inference and then optimise once we have that."*

## The question

> The card runs a bitstream containing subsystem A only. What, precisely, stands
> between that and a bitstream that runs the model?

## The answer, up front

**One binding. Everything else on the path is built, benched and waiting.**

`rtl/fk33_llama_top.vhd:3551` instantiates `u_mv : entity work.matvec_int4` --
the plain core, which takes shape registers and a codebook write port. The card's
A is `matvec_int4_desc_axi`, which lives in `fk33_engine`, fetches its own
descriptor from an HBM arena, and needs only a pointer and a GO. That swap is
decision **D1/D2** of the cardtop design note, and it is the **only** unapplied
item on the inference path.

**The clock is no longer in the way.** `FK33_ENG_CORE_MHZ` is now overridable
(default 200 preserved for the shipping A-only build); a full-engine build
selects 175, against the wired top's measured 181.7 MHz.

## What already exists, verified by reading the RTL rather than the documents

| piece | file | role | bench |
|---|---|---|---|
| host seam | `rtl/fk33_seam.vhd` | AXI-Lite in front of D; descriptor program, release mask, activation, go/done | `sim/tb_fk33_seam.vhd` |
| A seam | `rtl/a_desc_adapter.vhd` | D -> A: `arena_base + index*512`, three AXI-Lite writes, completion from ports | `sim/tb_a_desc_adapter.vhd` |
| A job index | `rtl/a_job_counter.vhd` | drives `job_index` | `sim/tb_a_job_counter.vhd` |
| B/C seam | `rtl/u_seam.vhd` | D -> `gdn_block` and `attn_block`, parameterised over their done/ack differences | `sim/tb_u_seam.vhd` |
| the model | `rtl/llama_top.vhd` | A+B+C+D wired: `matvec_int4`, `gdn_block`/`gdn_state_store`/`gdn_job_seq`, `attn_kv_axi`, `seq_*`, `sampler_stream` | `sim/tb_llama_top.vhd` |
| the card top | `rtl/fk33_llama_top.vhd` | generated from the above by `tools/gen_cardtop.py`, D3 applied | gate row `sim:cardtop` |

**`fk33_engine` already carries the entire D-facing surface**, and this is the
part that makes the remaining work small:

```
d_job_done   : out    d_job_err : out          -- A's completion, as PORTS
job_index    : in  std_logic_vector(31 downto 0)
d_x_we/d_x_waddr/d_x_wdata   : in              -- activations into A
d_y_we/d_y_addr/d_y_data/d_y_mask/d_y_exp : out -- results out of A
```

`hw/fk33/gen_fk33_engine.py` anticipates this build in its own comments: *"A
build that drives `job_index` from `rtl/a_job_counter.vhd`"*, and *"`a_desc_adapter.vhd`
takes completion from PORTS rather than from a [polled status]"*. The ports were
built for a caller that does not exist yet.

`hw/fk33/gen_pcieep.py` likewise already branches on it: it detects whether the
engine instantiates `llama_top` and ties the seam's D face off when it does not,
refusing to ship a tie-off that outlives its reason. Its `--selftest` enumerates
all six states including the two that matter here (S4: no tie-off and a real
`llama_top`, must be ACCEPTED; S5: tie-off present, ships today).

## Why the substitution is smaller than the design note implies

The note budgets D1/D2 at ~205 lines (`llama_top.vhd:3196-3400`). Reading the
actual instantiation, most of that is reusable:

| `matvec_int4` port | card equivalent | action |
|---|---|---|
| `x_we`/`x_waddr`/`x_wdata` | `d_x_we`/`d_x_waddr`/`d_x_wdata` | **same shape**, reroute to entity ports |
| `y_we`/`y_addr`/`y_data`/`y_mask`/`y_exp` | `d_y_*` | **same shape**, reroute |
| `done`/`err` | `d_job_done`/`d_job_err` | reroute |
| `cb_we`/`cb_addr`/`cb_data` | none | **delete**: the descriptor plane replaces the codebook write |
| `n_rows`/`n_cols`/`out_shift`/`w_exp`/`x_exp`/`out_mode`/`w_base`/`w_beats`/`s_base`/`s_beats` | none | **delete**: A reads them from its own descriptor |
| `m_ar*`/`m_r*` (one 128-bit read master) | none at this level | **delete**: A owns 28 masters inside `fk33_engine` |
| `start` | `a_desc_adapter.u_start` | replace with the adapter |

So the `ap` process's region-file reading and result draining survive largely
intact; what goes is the shape latching, the codebook streaming and the S_CB /
S_CBGAP states that exist only to fill a codebook the card does not use.

**This is a LEAD about size, not a measurement.** Nothing here has been built,
and the estimate is exactly the kind this project has recorded going wrong. It is
written down so it can be checked against what the work actually costs.

## The order of work

1. **D1/D2 in `tools/gen_cardtop.py`** -- anchored substitution, not a hand-edit
   of the 316 KB generated file. A hand-written fork was already tried, produced
   a 5,363-line draft nobody could review, and was quarantined and deleted on
   2026-09-01.
2. **D4**, the `w_active` gate, ~5 lines.
3. **`gen_fk33_engine.py` instantiates `fk33_llama_top`**, wiring `job_index`
   from `a_job_counter` and the `d_*` surface. This is what flips
   `gen_pcieep.py`'s `has_d` and removes the seam tie-off.
4. **Wire B's `bst_*` (29 ports) and C's `kv_*` (26 ports) to HBM** in the block
   design. **This is the piece with no existing plumbing** and is the real second
   half of the job; A's 28 masters are mapped by `ENG_PORT_MAP` and B and C have
   no equivalent.
5. **Build** at `FK33_ENG_CORE_MHZ=175`.
6. **Host software** -- `server/fk33_seam.h` is already the other half of the
   seam contract.

## Traps this analysis hit, both mine

1. **`head -12` on a grep truncated the evidence and I read the absence of a line
   as the absence of the code.** I concluded `ga_real` did not exist and that the
   real A path was missing; it is at `llama_top.vhd:3444` and was simply past the
   cut. Caught on the next command. **A truncated search is not a negative
   result**, and this is the project's recorded "grep the entity declarations,
   not the words a document used" trap wearing a different hat: there the search
   term was wrong, here the search was right and the OUTPUT was cut.
2. **The generator docstring understated what exists.** `gen_cardtop.py` says
   D1/D2 are "NOT applied yet", which is true, but reading only that would leave
   you expecting to build `a_desc_adapter`, `a_job_counter` and `u_seam` -- all
   three of which exist with benches. **A "not done" note is a statement about
   its own file**, which this repository already records, and it does not
   enumerate what was done elsewhere in the meantime.

## Open, not yet answered

- **Item 4, HBM plumbing for B and C.** 55 ports with no existing mapping. This
  is the least-understood part of the path and probably the largest.
- **Whether the card top still needs its region-file read path** in the form
  `llama_top` uses, or whether the seam supplies activations directly.
- **Throughput at 175 MHz.** No requirement has ever been stated, and the
  2026-09-03 entry flagged this as unmeasured. Still unmeasured; now explicitly
  deprioritised rather than unknown.
