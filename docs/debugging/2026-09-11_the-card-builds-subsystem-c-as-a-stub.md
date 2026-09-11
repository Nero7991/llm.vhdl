# The card builds subsystem C as a STUB, and three of the four switches the plan requires are false

**Date:** 2026-09-11
**Found while:** chasing the RTL Elaboration wall, by asking what generics the
card ACTUALLY passes rather than what it is described as passing.

## The question

> But we want the full system bitstream to run inference correct?

(Oren, 2026-09-10.) So: would the card bitstream now being built run inference?

## The answer

**No.** `hw/fk33/rtl/fk33_card.vhd` passes twelve generics to
`fk33_llama_top` and **`C_REAL` is not one of them**, so the default
`C_REAL : boolean := false` applies and the card elaborates
`gc : if not C_REAL generate` -- a three-state stub FSM -- instead of
`gcr : if C_REAL generate`, which is where **`attn_block` and `attn_kv_axi`
both live**.

`docs/PLAN_TO_FIRST_INFERENCE.md:236` states the requirement outright:

> It must: 1. Instantiate the REAL units (`C_REAL`, `C_KV_AXI`, `NORM_REAL`,
> `B_SRC_REAL` true; `A_BEHAV`, `B_BEHAV` false)

Measured against what the generated wrapper does:

| switch | passed by card | default | EFFECTIVE | plan requires |
|---|---|---|---|---|
| `C_REAL`     | no  | false | **false** | **true** |
| `C_KV_AXI`   | yes | false | true      | true |
| `NORM_REAL`  | no  | false | **false** | **true** |
| `B_SRC_REAL` | no  | false | **false** | **true** |
| `A_BEHAV`    | no  | false | false     | false (correct) |
| `B_BEHAV`    | no  | false | false     | false (correct) |

**Three of the four switches the plan requires TRUE are false.**

## Three consequences, each independently checkable

1. **There is no attention on the card.** `rtl/fk33_llama_top.vhd` instantiates
   `attn_block` exactly once, at `:5893`, inside `gcr`. With `C_REAL` false that
   generate does not elaborate. What runs instead is `gc` at `:5236`, whose body
   is `type st_t is (S_IDLE, S_WR, S_DONE)` and `u_err(U_C) <= '0'`.
2. **The five KV generics are INERT.** `C_KV_BLOCK`, `C_KV_ADDR_W`,
   `C_K_BASE_CH`, `C_V_BASE_CH`, `C_MAXPOS` and `C_CTXLEN` are all consumed
   inside `gcr`. The card passes correct 9B values for every one of them and
   none takes effect. `tools/check_kv_map.py` validates all of them and has no
   notion of `C_REAL`, so **23 green rows say nothing about the built design.**
3. **The KV AXI ports are TIED OFF.** `gkvtie : if not (C_REAL and C_KV_AXI)
   generate` at `:6319` fires whenever either is false. The block design wires
   `kv0_*`/`kv1_*` through a grant to HBM SAXI_30/31; the card top drives them
   from a tie-off.

## The procedure that found it

Nothing clever, and it could have been run on any day since the card top existed.

1. Ask what the card passes, from the GENERATED artifact rather than from the
   generator or from prose: `sed -n '216,229p' hw/fk33/rtl/fk33_card.vhd`.
   Twelve generics, and the interesting fact is which names are ABSENT.
2. For each absent switch, read its default in `rtl/fk33_llama_top.vhd`.
3. Find the generate that consumes it: `grep -nE '^\s*[a-z_0-9]+\s*:\s*if\s+.*C_REAL.*generate'`.
4. Confirm the real unit is inside it and nowhere else:
   `grep -n 'entity work.attn_block' rtl/fk33_llama_top.vhd` -> ONE site, `:5893`.
5. Check the plan for what was intended.

## Measured and REJECTED -- do not retry

- **"`C_KV_AXI => true` means the card has the AXI KV cache."** REJECTED. It is
  necessary and NOT sufficient: `attn_kv_axi` is instantiated inside `gcr`, and
  `gkvtie` ties the ports off unless BOTH `C_REAL` and `C_KV_AXI` hold.
- **"23 green `check_kv_map` rows mean the card's KV geometry is right."**
  REJECTED. They verify the generics AGREE. They cannot see that the generate
  consuming them does not elaborate. A checker comparing two descriptions of a
  thing says nothing about whether the thing is built.
- **"C's content is what makes elaboration intractable."** WEAKENED, not
  refuted. Every card build measured so far ran with C as a STUB, so the
  elaboration wall exists WITHOUT the real C. Turning `C_REAL` on will make the
  design larger, not smaller.

## Measurement traps hit

- **A generic being PASSED is not the same as being USED.** Six correct 9B
  values are passed into a generate that does not elaborate.
- **Reading the generator instead of the artifact.** `gen_fk33_card.py`'s ARGS
  list is long and looks comprehensive. The absence of a name is invisible when
  you read what IS there; it shows up when you diff against a REQUIREMENTS list,
  which is what the plan document is.
- **A green checker measuring the wrong thing.** This is the project's recorded
  "guards that pass for the wrong reason" class, in a new place, and I added
  rows to that very checker two days ago without noticing the generics were
  inert.

## Open, not yet answered

- **Was stubbing C deliberate staging?** No document says so. The plan says the
  opposite, and the WORKLOG discusses `B_SRC_REAL` at length while never
  mentioning `C_REAL` for the card.
- **Will `C_REAL => true` elaborate at all?** Unknown, and the honest
  expectation is that it is harder: it adds `attn_block` (87,340 LUT OOC) and
  `attn_kv_axi` (33,259 LUT at the card's geometry, measured today).
- **`NORM_REAL` and `B_SRC_REAL`** are equally absent and equally required.
  `B_SRC_REAL` additionally "has never executed past token 0 anywhere in this
  repository" (plan, STEP 3b), so turning it on is not a one-line change.
