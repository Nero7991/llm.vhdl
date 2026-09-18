# Two HBM base inputs on the card cell were never connected, and the K cache sat inside the GDN arena

## The question, verbatim

> Why did the full VHDL gate go red on `sim:kvmap` after the manifest
> migration, and -- found while answering it -- why does every `FK33_CARD=1`
> build carry `CRITICAL WARNING: [BD 41-759]` naming `/card/bst_state_base`
> and `/card/a_arena_base`?

Date: 2026-09-18. Builds: `buildsmp` (2026-09-17 20:45, failed to route) and
`buildcong` (2026-09-18 06:22, killed at 07:55 once this was understood).

## The answer, up front

**Two defects, and both would have produced a bitstream that runs a token and
gets a wrong answer with no fault raised.**

1. **`bst_state_base` and `a_arena_base` were unconnected in the block
   design.** An unconnected input is zero. Subsystem A would have fetched
   every descriptor from HBM address 0 and subsystem B would have written its
   recurrent state there -- both inside the first weight tensor. Every gate
   passed, because `41-759` is a CRITICAL WARNING and `pcieep_build.sh` gates
   on `^ERROR`.

2. **C's baked K-cache base was 1,179,648 B inside the correctly sized GDN
   arena.** `C_K_BASE_CH = 282598912` puts K at `0x10D81E000`, leaving
   exactly 25,264,128 B above `weights_end` -- **the old, under-sized GDN
   figure.** The RTL generic inherited the same omission the manifest had
   (the conv tap history, `docs/debugging/2026-09-17_gdn-arena-omitted-...`).

Fixed as: the seam carries both bases as host-written registers and REFUSES a
GO while either is zero; the generator wires them; a build-time check fails
on any unconnected module-reference input; and the K/V generics are
re-derived from the migrated manifest in all three places that hold them.

## The chain, in the order it was found

1. The full gate went red on ONE row, `sim:kvmap`:
   ```
   REFUSED C_K_BASE_CH*16 == manifest hbm.kv_base   282598912 * 16 = 4521582592 vs kv_base 4522762240  (delta -1179648 bytes)
   ```
   `-1179648` is the migration's exact delta, so the row is doing its job:
   the manifest moved and the bitstream's constant did not.
2. Deriving where the constant came from: `weights_end` is `0x10C006000`,
   K is `0x10D81E000`, and the gap is `25264128` -- the under-sized arena to
   the byte. **So the collision was real before the migration too**; the
   migration only made the checker able to see it.
3. Asking how the card learns the GDN base at all led to `bst_state_base`,
   a port on `fk33_card`, and to `rtl/fk33_llama_top.vhd:719`:
   > the tiered arm needs an HBM allocation for `bst_state_base` that nothing
   > supplies yet, so turning it on without one gives a store that loads from
   > address zero.
   The card sets `B_STATE_AXI => true` regardless.
4. Grepping the failed build's log for the port name found the warning, and
   a second pin beside it:
   ```
   CRITICAL WARNING: [BD 41-759] The input pins (listed below) are either not
   connected or do not have a source port, and they don't have a tie-off
   specified. These pins are tied-off to all 0's to avoid error in
   Implementation flow.
   /card/bst_state_base
   /card/a_arena_base
   ```
   `a_desc_adapter.vhd` says of the second: *"THE ARENA BASE IS AN INPUT
   PORT, NOT A GENERIC, DELIBERATELY [...] a hardcoded copy of this address
   became a FOURTH model of the same address."* Deliberately a port, and
   nothing drove it.
5. The same warning was in the `buildcong` log already, forty minutes in.
   Killed it.

## The fix, and why it is registers rather than tie-offs

`rtl/a_desc_adapter.vhd` already argued the point. The manifest is the only
authority for these addresses, the host reads the manifest, so the host
writes them. `rtl/fk33_seam.vhd` gains four RW registers at `0x6C..0x78`
(`ARENA_LO/HI`, `BST_LO/HI`, 40 and 33 bits, the card's own port widths),
drives two new outputs, and **refuses a GO with either still zero, code
`EC_DESC`** -- because zero is HBM address 0 AND what an unwritten register
holds, so a forgetful host gets a refusal rather than a wrong token.

`server/pl_backend.c`'s v2 arm writes them from the manifest's
`hbm.desc_arena_base` and `hbm.gdn_state_base` -- the same fields
`fk33_load_weights.py` places against -- and refuses to open a v2 card with
neither. `gen_pcieep.py` gains two rows in `SEAM_TO_CARD`.

## Teeth, with the attribution control for each

**The RTL refusal**, `sim:tb_fk33_seam` P6d. Mutant: the `elsif` removed.
```
                                    fixed      mutant
  GO with both bases zero           refused    ACCEPTED (STATUS=2, BUSY)
  GO with arena only                refused    ACCEPTED
  P1 value faults                   0          128
```
The mutant is caught by the new check (P6 = 2) and, informatively, by
everything downstream (P1 = 128): the token ran against garbage. That is what
the card would have done.

**The sim**, `seam_selftest` T13/T14: 131 checks, from 124. Both the register
refusal and `pl_open`'s early refusal have rows, plus the 33-bit overflow.

**The build-time check**, `FK33_UNCONNECTED`, and this one earned its control
three times over:

| version | discriminator | control (fixed) | mutant (pre-fix) | verdict |
|---|---|---|---|---|
| 1 | any input pin with no net | **37 pins** | -- | stricter than Vivado: 32 HBM parity pins, resets, an IRQ, all IP defaults |
| 2 | `TYPE == "module"` on the parent | 0 | **0** | **decoration**: `TYPE` is `ip` for a module_ref, and a top-level pin's `PARENT` is empty, so it excluded everything |
| 3 | `VLNV =~ "*:module_ref:*"` | 0 | **2, names both pins, build FAILS** | works |

Version 2 is the recorded trap exactly: a check that has never been shown to
fail. The mutant that exposed it was itself wrong the first time -- **I deleted
the two `connect_bd_net` lines from the generated Tcl, and `pcieep_build.sh`
regenerates that file from `gen_pcieep.py` before every run, so the mutant was
overwritten by the fix before Vivado saw it.** Count=0 on a "mutant" that was
the control. The honest mutant is at the generator, and it was the one that
finally discriminated. Both discriminator facts (`TYPE=ip`,
`VLNV=xilinx.com:module_ref:fk33_card:1.0`, `PARENT=` empty) were MEASURED by
a Tcl probe against the live project rather than guessed.

**The K/V bases.** `tools/check_kv_map.py` holds the manifest, the generator
and `sim/realshape_gate.sh`'s KVR block to an identity; changing one of the
three refused with `<-- DIVERGED` until all three agreed. 24 rows, 0 refused,
17 of 17 teeth rows. `C_KV_ADDR_W = 33` still holds: `clog2(353975808 +
71303168) = 29`.

## Measured and REJECTED -- do not retry

* **A tie-off constant for either base.** It is the "fourth model of the same
  address" `a_desc_adapter.vhd` warns against, and it would pass the new
  build check while still being wrong on the next repack.
* **Hand-editing `build_fk33_pcieep.tcl` as a mutant.** Regenerated before
  every run. Any mutation of a generated file must go in its generator.
* **Reproducing `41-759` under `--bd-only`.** It fires inside `make_wrapper`,
  which `--bd-only` stops before. The pin-walk does not need the warning, so
  the check runs and discriminates under `--bd-only` -- but do not expect to
  see the warning text there.

## Open, not yet answered

* **Nothing has run against the card**, including the new refusal.
* **Whether B's tiered store actually uses `bst_state_base`** once connected.
  `fk33_llama_top.vhd:722` says the store's tap face is "NOT used here" and
  the token-1 refusal is not lifted. Connecting the base fixes the address; it
  does not establish that the store is complete.
* **The 1.78 GB above the KV region** is where the A arena and the host blocks
  sit; the map was not re-verified end to end after the K/V move, only the
  identity rows.
