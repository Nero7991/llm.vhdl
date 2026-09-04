# llama_top does not synthesise at 9B, and the region file is the reason

**Date:** 2026-09-04
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, `sim/ooc_llama_top.tcl`
**Tree:** `9fa36f2` + the OOC script

## The question

`rtl/llama_top.vhd` is the WIRED integration top and its `SHAPE` generic
already defaults to the real 9B target. Can it be synthesised?

## The answer

**No. One object stops it: the region file.**

```
WARNING: [Synth 8-4767] Trying to implement RAM 'mem_reg' in registers.
  1: RAM has too many ports (16). Maximum supported = 16.
ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for 'mem_reg'
  because the memory pattern used is not supported. Failed to dissolve the
  memory into bits because the number of bits (2752512) is too large.
```

`rtl/llama_top.vhd:1159`:

```vhdl
type buf_t is array (natural range <>) of signed(MANT_W-1 downto 0);
subtype mem_t is buf_t(0 to NREGION*REGMAX-1);
signal mem : mem_t := (others => (others => '0'));
```

DERIVED, and it matches Vivado's figure exactly:

    NREGION x REGMAX x MANT_W  =  14 x 12288 x 16  =  2,752,512 bits  =  336 KiB

`NREGION = 14` is `rtl/llama_map_pkg.vhd:86`; `REGMAX` defaults to
`region_max(SHAPE)` which is 12,288 at 9B; `MANT_W = 16`.

**This is not a surprise and it is not a defect.** The comment immediately
above that declaration has said so all along:

> A REAL IMPLEMENTATION would be 14 separately-sized BRAM/URAM regions with
> their own port counts, sized from `region_sizes(SHAPE)` rather than all at
> REGMAX, and the arbitration below would be per-region rather than global.

So the region file is an acknowledged simulation model. What is new is the
MEASUREMENT that it is the thing standing between llama_top and a 9B
synthesis, and that it is the ONLY error in the run.

## Why this is the same shape as B's state store, and that is the good news

On 2026-09-03 B's mover was found not to fit: `gb_real.stmem_p.stmem_reg` was
3072 Ki x 64 = 24.0 MiB = 5,472 RAMB36 against 672 on the part. The fix was
`gdn_state_store` behind an AXI master, taking it to 34 tiles and halving LUT,
reached through the `B_STATE_AXI` generic.

The region file is the same class of object -- a flat behavioural array that
simulates correctly and cannot be synthesised at the real shape -- and it
wants the same treatment: per-region storage sized from `region_sizes(SHAPE)`
with per-region arbitration, exactly as its own comment specifies.

It is also **three orders of magnitude smaller**: 336 KiB against B's 24.0 MiB.
14 regions at their real sizes fit comfortably in the 672 BRAM tiles this part
has. **The region file is a port-count and structure problem, not a capacity
problem**, which makes it a much easier fix than B's was.

## Two things this run also established

1. **Everything else in llama_top synthesised.** `mem_reg` produced the ONLY
   `^ERROR` in the log. A, B, C, D, the norm and the sampler all elaborated and
   went through synthesis at the real 9B shape.
2. **llama_top ANALYSES clean at 9B.** MEASURED separately with
   `ghdl -a --std=08 -frelaxed` over the 57-file dependency set from
   `tools/ref9b/capture_llama_top.sh`: no errors.

## Measured and REJECTED -- do not retry

- **"llama_top fails to analyse at 9B because of `attn_block.vhd:1065:
  constant "g" is not visible here`."** That error is real but it is an
  ARTEFACT OF THE INVOCATION: it appears with `ghdl -a --std=08` and vanishes
  with `ghdl -a --std=08 -frelaxed`, which is what `sim/regress.sh:373` and
  `tools/ref9b/capture_llama_top.sh:137` both use. An earlier attempt
  (`scratchpad/rsg/default_9b.out`) recorded this as a 9B blocker; it is not
  one. **Always take the flags from the scripts that work, not from memory.**
- **"compose4_top is the way to get the 9B shape into llama_top."** Backwards.
  `compose4_top` INSTANTIATES `fk33_engine` plus `gdn_block`, `attn_block` and
  six D units at 9B, but its own header says "THE SUBSYSTEMS ARE NOT WIRED TO
  EACH OTHER". llama_top is the wired one and is ALREADY at 9B by default.
  Nothing needs moving from compose4 into llama_top.
- **"The blocker will be capacity, like B's was."** 336 KiB, not 24 MiB.

## Measurement traps hit

- **Vivado SEGFAULTED after printing the error** (`NINETOP_WRAPPER_EXIT 139`,
  `hs_err_pid288574.log`). RSS at the time was 2.79 GB, so this was NOT memory
  exhaustion and the cap was never approached. **The crash is downstream of the
  error, not a second finding** -- but it means the exit code carries no
  information about how far the run got, and a waiter keyed on the wrapper's
  status would have reported a memory problem that did not happen. The
  `^ERROR` grep is what identified this correctly.
- **The error names `mem_reg`, which is a synthesis name, not a VHDL name.**
  The signal is `mem`; `_reg` is Vivado's suffix. Grepping the RTL for
  `mem_reg` finds nothing.

## Open, not yet answered

- **What the region file should become.** Its own comment specifies the shape
  (per-region, `region_sizes(SHAPE)`, per-region arbitration) but nothing is
  written, and the arbitration change is the substantial part: the current
  single element port is justified by `cur_unit` in `seq_desc_fetch` being a
  scalar, and that justification is recorded as becoming wrong when D grows
  overlap.
- **Whether llama_top FITS at 9B once the region file is real.** Unknown. This
  run never reached `report_utilization`, so there is no area figure for
  llama_top at any shape, and `compose4_top`'s numbers are for an unwired
  composition with a different instance set.
- **Nothing here ran against the card.**
