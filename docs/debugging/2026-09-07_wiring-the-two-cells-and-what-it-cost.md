# Wiring the two cells: three configuration defects, and an elaboration that does not fit

**Date:** 2026-09-07
**Question:** the card is a two-cell block design. Do the two cells actually
join, and does the card configuration elaborate?

## The answer, up front

**The seam now matches, and three real configuration defects were found by
trying.** The full card configuration has **NOT** been shown to elaborate: the
attempt ran 102 minutes, reached 12.13 GB, began cgroup reclaim throttling
(`memory.events high 94`), pushed the box to 3 GB free with 4 GB of swap in
use, and was stopped rather than allowed to escalate.

What HAS elaborated cleanly is the partial configuration -- `B_STATE_AXI=true`,
`C_KV_AXI=true`, `C_KV_BLOCK=32`, with `A_DESC` false and `A_ROWS_IF` 4 --
`CARD_ELAB_OK bitports=3588`. **That is a different configuration and must not
be quoted as the card's.**

## The three defects, each found by comparing the two entities

Nothing in either file references the other, and each is internally consistent,
so every one of these is invisible until the cells are connected.

### 1. The seam widths disagreed by 12x

| signal | engine | card (before) |
|---|---|---|
| `d_y_data` / `a_y_data` | `48*64` = **3072** bits | **256** |
| `d_y_mask` / `a_y_mask` | **48** | **4** |

`hw/fk33/gen_fk33_engine.py` pins `ROWS_IF = 48`, a MEASURED choice (TRACK
LEVERC48: "distributed" at 48 is -42,633 CLB LUT). The card top's `A_ROWS_IF`
**defaults to 4**. Fixed by pinning `A_ROWS_IF=48`; the seam now matches on all
7 shared signals with 0 mismatches.

**This is what makes `--generic` driving width folding load-bearing** rather
than defensive. That guard was added earlier the same day and teeth-tested as
NOT biting (`C_KV_BLOCK` 4 versus 32 gave a byte-identical port clause). Here
it bites: a pin that did not reach the folding would leave the wrapper's port
256 bits wide over a 3072-bit instance, with nothing to say so.

### 2. `CHK_A_BLOCK` fires over a path this configuration does not build

```
ERROR: [Synth 8-11323] assigned value '-167936' out of range  (fk33_llama_top.vhd:1091)
```

`CHK_A_BLOCK := A_JOB_STRIDE - (A_ROWS_IF + 1) * A_SUB_BYTES` is the project's
out-of-range-`natural` idiom for a compile-time assertion, because Vivado
silently ignores `assert ... severity failure` in synthesis. At `A_ROWS_IF=48`
it is `32,768 - 49*4,096 = -167,936`. **Correct arithmetic.**

But its own comment says it guards `ga_real`, and `ga_real` is
`if not A_BEHAV and not A_DESC generate` -- not instantiated at `A_DESC=true`.
MEASURED by grep, `A_JOB_STRIDE` appears nowhere outside that generate and this
constant. The constant lives in the architecture's declarative region, so it is
evaluated whether or not the path exists.

Worked around by pinning `A_JOB_STRIDE=16#40000#` (262,144, which is 49*4,096
rounded up), with the reasoning written into `gen_fk33_card.py`. **The cleaner
fix is to make the guard conditional on `not A_DESC`, and it is deliberately
NOT done here: that edits a guard, and a guard weakened by someone who only
wanted their own build to pass is how guards stop working.**

### 3. `A_DESC` was never pinned, and the symptom named something else

```
ERROR: [Synth 8-549] port width mismatch for port 'm_arvalid':
                     port width = 49, actual width = 5   (matvec_int4.vhd:96)
```

`A_DESC = true` is the entire point of this cell and it was missing from the
first version of the configuration list. With it false, `ga_real` instantiates
`matvec_int4` -- the SIMULATION path's A, five masters at `ROWS_IF 4` -- inside
a cell whose whole purpose is to drive the OTHER cell's A across the seam.

**The symptom did not say "A_DESC is false".** It said a width mismatch between
49 and 5, because `A_ROWS_IF=48` asks `matvec_int4` for 49 masters while
`A_NPORTS` is a package CONSTANT of 5 (`llama_map_pkg.vhd:69`, pinned because
`weight_streamer.vhd` fixes `NPORTS_W = ROWS_IF = 4` at BLK 32 / AXI_DW 128).
That reads as *"A_ROWS_IF = 48 is illegal here"*, which is true of `ga_real` and
irrelevant to this cell -- the path should not exist at all.

## The memory finding, which is its own result

The full card configuration's `synth_design -rtl` **exceeds what is available
alongside `llama-server`**:

```
102 minutes, RSS 12.13 GB, cgroup memory.events high=94
system: 3 GB free, 4 GB swap in use
```

Diagnosed rather than assumed: at 73 minutes the same run showed
`high 0`, `majflt 0` and CPU time advancing at a full core -- genuinely working
and not thrashing. It crossed into reclaim only later. **`majflt` and
`memory.events` distinguish "slow" from "dying", and only one of those is worth
waiting out.**

`llama-server` permanently holds ~7 GB of the box's 31. Freeing it is a
deliberate act with a user-visible cost and is **Oren's call, not a track's**,
which is why this run was stopped instead.

## Measured and REJECTED -- do not retry

- **Do not elaborate the full card configuration under a 12 GB cap beside
  `llama-server`.** 102 minutes, throttled, incomplete.
- **Do not quote `CARD_ELAB_OK bitports=3588` as the card's.** That result is
  `A_DESC` false at `A_ROWS_IF` 4 -- a different design.
- **Do not "fix" `CHK_A_BLOCK` by relaxing it.** Pin `A_JOB_STRIDE` instead
  until someone makes it conditional deliberately.

## Open, not yet answered

- Whether the full configuration elaborates at all. It needs either more
  memory headroom or the BC-250 lane (which was in interactive use today).
- `--bd-only` has still not been run.
- The three cells are not connected in `gen_pcieep.py`.
