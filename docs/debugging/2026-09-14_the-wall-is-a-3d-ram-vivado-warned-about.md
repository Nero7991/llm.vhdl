# The 52-hour synthesis wall is a 3D RAM that Vivado warned about by name

**Date:** 2026-09-14
**Build:** `hw/fk33/ooc_card_dcp.tcl`, `-top fk33_card`, `-flatten_hierarchy none`,
part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2.
**Runs:** `cardooc` (workstation, full shape, 54 h and counting) and
`cardsmall4096` (BC-250, `C_MAXPOS=C_CTXLEN=4096`, launched 01:00:05 EDT).

## The question, verbatim

> "Start tonight at 1am ET on BC-250, I'm gonna be using it before that"

being the scheduling of this probe, whose own question was: the full-shape card
OOC has been in a silent phase for over 45 hours with no log output and no
phase markers. **Does that phase terminate at a smaller context, and how does it
scale?**

Symptom numbers at dispatch: 54 h elapsed, CPU 102%, log frozen at 71,492 bytes,
`memory.current` 24,575 MiB pinned against a 24,576 MiB cap, `memory.events
high=7215`, 0 errors.

## The answer, up front

**The context axis was the wrong axis, and the wall is a 3D RAM that Vivado
named in a warning one line before it went silent.**

    WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from
    Record/Structs for RAM  mbank_reg with 16384 registers

`mbank` is declared at `rtl/attn_kv_axi.vhd:667-668` as an array **of an array**
of `std_logic_vector` -- `mbanks_t is array (0 to MPB-1) of mbank_t`, where
`mbank_t is array (0 to RBUF*NBLK-1) of std_logic_vector(CH_W-1 downto 0)`. At
the card's geometry that is `MPB=2`, `RBUF*NBLK=4*8=32`, `CH_W=128`, so 8,192
bits per `GEN_RD` instance and **16,384 across the two**, which is exactly the
register count Vivado prints.

**Its size does not depend on `C_MAXPOS` or `C_CTXLEN` at all** -- it is a
function of `KV_BLOCK`, `RBUF` and `HEAD_DIM` -- which is precisely why a 32x
context reduction moved the wall by zero bytes.

**Status: STRONG CANDIDATE, NOT YET CONFIRMED.** The decisive attribution
control (below) had not run when this was written. Do not treat this as settled.

## The procedure that produced it

1. **Reduce the context 32x and re-run.** `C_MAXPOS=C_CTXLEN=131072 -> 4096`,
   everything else byte-identical, inputs derived from the synced tree by `sed`
   with the diff asserted to be exactly 2 lines. **Isolates: is the wall a
   function of context size?** Answer: no.
2. **Compare the two logs' STOPPING POINT, not their length.** Both end on the
   byte-identical line. This is the step that converts "still slow" into "same
   defect".
3. **Read the last substantive warning before the stop**, rather than the last
   line. The last line is a RAM that COMPLETED; the warning above it is the one
   naming a runtime hazard.
4. **Confirm the warning is invariant across the two runs.** Same message, same
   object, same 16,384 registers at both shapes -- which both corroborates the
   identification and explains step 1's null result.
5. **Pending: the attribution control.** A variant sweep forcing each subsystem
   generic false in turn (`bisect.sh`), pass condition "log grows past byte
   71,325 within 7 minutes", with an unmodified ctx=4096 control that MUST
   reproduce STUCK or the window is wrong and every verdict is void.

## The evidence, raw

`cardooc.log` is 693 lines and ends at line 693. Lines 681-693:

    681: WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from Record/Structs for RAM  mbank_reg with 16384 registers
    682: WARNING: [Synth 8-4767] Trying to implement RAM 'GEN_RD[0].hdr_r_reg' in registers. Block RAM or DRAM implementation is not possible; see log for reasons.
    687: RAM "GEN_RD[0].hdr_r_reg" dissolved into registers
    688: WARNING: [Synth 8-4767] Trying to implement RAM 'GEN_RD[1].hdr_r_reg' in registers. Block RAM or DRAM implementation is not possible; see log for reasons.
    693: RAM "GEN_RD[1].hdr_r_reg" dissolved into registers
    <end of file, 54 hours ago>

`cardsmall.log` (ctx=4096), 694 lines, the same warning at line 682:

    682: WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM or RAM from Record/Structs for RAM  mbank_reg with 16384 registers

Phase markers, both runs:

    89: Starting synth_design
    96: Starting Synthesize : Time (s): cpu = 00:00:02 ; elapsed = 00:00:02 . Memory (MB): peak = 1761.844

So the job entered `Synthesize` at **t = 2 seconds** and has been inside that one
phase ever since. The ctx=4096 run reached the identical stop at **t = 45
seconds** and had produced nothing further 2 h 06 m later, at 100% CPU with
`MemoryPeak` climbing 7.75 -> 7.97 GiB.

Unthrottled memory, ctx=4096 (`memory.events` `high 0, max 0, oom 0`, swap 0):

    MemoryPeak = 7.97 GiB

This is the first card-OOC memory figure in this project that is a real peak
rather than a cap.

## Measured and REJECTED -- do not retry

- **Reducing `C_MAXPOS` / `C_CTXLEN`.** 32x, and the wall did not move by one
  byte. Both runs stop on the identical line. Do not run the ctx=16384 point;
  it is on the same dead axis.
- **`rtl/llama_top.vhd`'s flat `mem` array is NOT the culprit for THIS build.**
  It is 2,752,512 bits (`NREGION=14 x REGMAX=12288 x MANT_W=16`, evaluated by
  GHDL, not by hand), which matches a `[Synth 8-3391]` error seen in a DIFFERENT
  job (`ooc_bb2`) to the digit. **The exact match is a coincidence of a shared
  model dimension, and `rtl/llama_top.vhd` is not in this build's source list at
  all** -- `ooc_card_dcp.tcl:149` reads `rtl/fk33_llama_top.vhd`, whose flat
  array was already replaced by `region_mem`. An exact numeric match is not
  attribution when the object is not in the build.

## Measurement traps hit

- **I REJECTED THE CORRECT OBJECT BY ARGUING FROM ITS TOTAL.** Two hours before
  finding the warning I computed `mbank` at 8,192 bits per instance, called it
  "trivial", and wrote it up under "Measured and REJECTED". The size was right;
  the inference was wrong. **The hazard is not the bit count, it is the 3D
  array-of-array-of-vector shape**, and Vivado said so explicitly in a message
  that was sitting in the log the whole time. This repository already carries
  the rule -- *when a report names the object, no argument about the total is
  admissible* -- and I broke it while quoting it.
- **A CHECK THAT COULD NEVER FIRE, REPORTED HOURLY.** My phase-line grep was
  `^(Start|Finished) ` with a trailing space. Vivado prints "**Starting**". It
  returned 0 every time and I reported "0 phase lines" for hours as though it
  were evidence. The true count is 2, and the second line is the one that
  reframes the whole problem: synthesis was entered at t=2 s, so this was never
  a "post-elaboration" wall.
- **THE LAST LINE OF A LOG NAMES WHAT FINISHED, NOT WHAT IS RUNNING.** Reading
  the final `dissolved into registers` line pointed at `hdr_r`, a 4-word signal
  that completed successfully. The diagnostic content was one line ABOVE the
  RAM section, not at the bottom.
- **An earlier probe's error message is not this probe's evidence.** The
  `[Synth 8-3391]` / 2,752,512 figure came from `ooc_bb2`. I had written that
  caveat into `docs/WORKLOG.md` myself two hours earlier and then chased the
  number anyway because it matched exactly.

## Open, not yet answered

- **The attribution control has not run.** Until a variant that removes
  `attn_kv_axi` progresses past byte 71,325 while the control stays STUCK, this
  is a candidate, not a cause.
- **Whether the phase terminates at all**, at any shape. Nothing has yet been
  observed to exit it.
- **What the fix costs.** `attn_kv_axi.vhd:645-668` documents the bank split as
  a deliberate area optimisation worth ~21,000 LUT per prefetch slot, MEASURED
  2026-09-06. Flattening `mbanks_t` into a single 2D array with a computed index
  should preserve that saving while removing the 3D shape, but that is an
  ESTIMATE and has not been synthesised.
- Whether any OTHER `8-11357` object exists elsewhere in the design that has
  simply not been reached yet. **PARTIALLY ANSWERED, as a LEAD not a
  measurement** -- see the census below.

## What else has this shape (a LEAD, not a measurement)

A scan of the card's REAL source closure -- the 66 files parsed out of
`ooc_card_dcp.tcl`'s own `read_vhdl` lines, not a hand-picked list -- finds
**10 array-of-array types**:

| file:line | type | element |
|---|---|---|
| `rtl/matvec_core.vhd:263` | `cb_bank_t` | `cb_t` |
| `rtl/matvec_core.vhd:384` | `lvl_arr` | `node_arr` |
| `rtl/matvec_core.vhd:404` | `scp_t` | `sc_arr` |
| **`rtl/attn_kv_axi.vhd:667`** | **`mbanks_t`** | **`mbank_t`** |
| `rtl/gdn_conv.vhd:150` | `pk_arr` | `s32_arr` |
| `rtl/gdn_conv.vhd:151` | `xk_arr` | `s16_arr` |
| `rtl/rmsnorm_bf.vhd:360` | `tree_t` | `u63a` |
| `rtl/gdn_recur_pipe.vhd:206` | `red_s_t` | `s42_arr` |
| `rtl/gdn_recur_pipe.vhd:207` | `red_u_t` | `u35_arr` |
| `rtl/seq_desc_fetch.vhd:281` | `bank_arr` | `word_arr` |

**Only `mbanks_t` has been OBSERVED to trigger `8-11357`.** The rest are
unmeasured, and most are probably harmless: `lvl_arr`, `scp_t`, `tree_t`,
`red_s_t`, `red_u_t`, `pk_arr` and `xk_arr` are reduction-tree and pipeline
stages indexed by LOOP CONSTANTS, and Vivado only attempts RAM inference on a
structure addressed by a non-constant index.

**The two worth watching are `cb_bank_t` and `bank_arr`**, which are
RAM-shaped. Note that `cb_bank_t` is the codebook broadcast already on this
project's radar as `CB_BCAST` (the named timing suspect, and the object behind
the stale `CB_STYLE="distributed"` -42,633 LUT figure).

**Do not read this table as a list of defects.** It is a list of places to look
IF fixing `mbank` moves the wall rather than removing it. Synthesis has never
got past `mbank`, so nothing downstream of it has been exercised at all, and a
shape census cannot tell you which of these Vivado will treat as a RAM.
