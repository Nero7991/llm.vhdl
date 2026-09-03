# B's data mover does not fit, and it is ONE array that does not fit

**Date:** 2026-09-03
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, GHDL 1.0.0 mcode
**Files:** `sim/ooc_gdnadapt_extract.py`, `sim/ooc_gdnadapt.tcl`,
`sim/ooc_gdn_block.tcl`, `rtl/ooc_gdnadapt_top.vhd` (generated)

## The question, verbatim

From the standing blocker list, repeatedly: *"per-unit data movers for B/C
(~1,600 unwritten lines)"*. Before writing 1,600 lines, ask what the existing
ones cost, because `hw/fk33/gen_compose4_top.py:928` says only that they *"do
not exist yet"*.

## The answer

**They exist, and the claim that they do not is a statement about ENTITIES, not
about LOGIC.** `rtl/llama_top.vhd`'s `gb_real` block is 614 lines of exactly
B's data mover, it instantiates `gdn_block`, and every `llama_top` gate row has
exercised it for weeks. It had never been synthesised.

It does not fit, and the overage is **a single named object**:

```
|Module Name  | RTL Object                | PORT A (Depth x Width)  | RAMB36 |
|extram__16.. | gb_real.stmem_p.stmem_reg | 3072 K x 64(READ_FIRST) |  5472  |
```

**5,472 RAMB36 against 672 on the device. 814%. One array.**

3,072 Ki x 64 bits is **24.0 MiB exactly**, and
`llama_top.vhd:3847` says why: `stmem_t is array (0 to NLY*STLY-1)` with
`STLY = VH*DM*NBR`, so it is **1.0 MiB per layer times all 24 GDN layers,
resident at once**. This is the project's 24 MB finding, arrived at from a new
direction and now attached to a line number.

**Everything else in the block is fine.** `gdn_block` alone at the same
generics is **22 BRAM tiles, 141 DSP, 56,713 LUT, and WNS +0.483 = 221 MHz**,
which MEETS the card's 200 MHz target. The mover's `-4.008` therefore belongs
to the mover, not to the compute.

So the fix is a **local substitution inside `gb_real`**, not a redesign:
`rtl/gdn_state_store.vhd`, built 2026-09-02, is one resident layer in
32 URAM288 + 12 RAMB36 = 1.125 MiB, against the 1.0 MiB `STLY` needs, with HBM
movers for the other 23. It replaces `stmem_p` and nothing else.

## The procedure

Three steps, each a control for the one before.

1. **Extract**, `sim/ooc_gdnadapt_extract.py`, same method as
   `sim/ooc_normadapt_extract.py`. The block text is taken verbatim from
   whichever `llama_top.vhd` the script is pointed at, so a diff between two
   generated files is a diff between two `llama_top.vhd` files restricted to
   the block.
2. **Sweep the buffer size**, `MAXROWS_OVR`, separating "unsynthesisable" from
   "unsynthesisable AT THIS SIZE".
3. **Synthesise `gdn_block` alone**, `sim/ooc_gdn_block.tcl`, to attribute the
   area. **This step overturned the conclusion drawn from step 2.** See below.

## The evidence

At the default 9B shape, `A_MAXROWS = region_max(SHAPE) = 12288`:

```
ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for
  'gb_real.bp.zb_reg' because the memory pattern used is not supported
RAM has too many ports (16). Maximum supported = 16.
Abnormal program termination (11)
```

The size sweep, both runs `EXIT 0`:

| `MAXROWS` | CLB LUT | LUT as logic | dist RAM | CLB FF | BRAM tile | WNS |
|---|---|---|---|---|---|---|
| 64 | 127,260 | 91,883 | 35,078 | 46,279 | **5,472 (814%)** | -4.008 |
| 256 | 129,224 | 93,751 | 35,174 | 49,317 | **5,472 (814%)** | -4.008 |

`gdn_block` alone, `LAYERS=24`, 6 min 3.8 s CPU, `OOC_EXIT 0`:

| CLB LUT | as logic | as memory | CLB FF | BRAM tile | URAM | DSP | WNS | fmax |
|---|---|---|---|---|---|---|---|---|
| 56,713 | 46,552 | 10,161 | 33,687 | **22** | 0 | 141 | **+0.483** | **221 MHz** |

Arithmetic, DERIVED:

```
3072*1024 entries x 64 bits = 201,326,592 bits = 24.0 MiB
5472 RAMB36 x 36 Kib        = 24.05 MiB          (consistent)
24.0 MiB / 24 layers        = 1.0 MiB per layer
gdn_state_store 32 URAM288  = 1.125 MiB          (covers one layer)
```

## Measured and REJECTED -- do not retry

- **"The 5,472 BRAM is `gdn_block` holding 24 layers of state."** WRONG, and it
  was this document's headline claim until the control ran. `gdn_block` takes
  state through PORTS and holds 22 tiles. The state array belongs to the mover.
  The reasoning that produced the wrong answer is recorded under traps below,
  because the reasoning is the reusable part and it was superficially sound.
- **"The `zb`/`yb` process variables are the problem."** They are A problem --
  `variable zb : buf_t(0 to A_MAXROWS-1)` is 12,288 x 16 bits as a process
  variable and is what Vivado refuses at the 9B shape -- but they are not why
  the design does not fit. Four times the buffer moves BRAM by ZERO. Fixing
  them alone turns a synthesis ERROR into a design still 8x over budget.
- **"The 14 GiB cap caused the crash."** It did not. The failing run consumed
  **45.338 s of CPU** and never approached the cap; `MemoryHigh` throttles
  rather than kills. The crash is Vivado terminating on signal 11 after
  `Synth 8-3391`. Do not re-run it "with more memory".
- **Reading `gdn_block`'s WNS as the block's WNS.** `gdn_block` makes 200 MHz
  comfortably. The composed `-4.008` is the mover, and the largest single
  suspect in the mover is the 24 MiB array being removed anyway.

## Measurement traps hit

- **AN INVARIANCE ARGUMENT IDENTIFIES WHAT A NUMBER IS *NOT*, NEVER WHAT IT
  IS.** The sweep proved the BRAM does not scale with `MAXROWS`, so it is not
  the `zb`/`yb` buffers. From "not the buffers" this document concluded "then
  it is `gdn_block`" -- and wrote that up with a table, an arithmetic
  cross-check against the known 24 MB figure that AGREED, and a recommendation.
  **The agreement was real and the attribution was still wrong**: 24 MiB of
  GDN state is genuinely there, it is simply held one level up from where I put
  it. Ruling out one candidate promotes nothing; there were never only two.
  The control cost six minutes and the document was already written.
- **The census beat every inference from totals.** `CLAUDE.md` already says
  Vivado's log lies in both directions and only the mapping report and an
  object-level census are authoritative. The `Report RAM Utilization` table
  names `gb_real.stmem_p.stmem_reg` outright, it was in the log the whole time,
  and I reasoned from the utilization TOTAL instead of reading it. **When a
  report names the object, no argument about the total is needed or admissible.**
- **A REGEX OVER VHDL IS NOT A PARSER.** A first automated pass at the block's
  seam was wrong FIVE times, each of which would have produced a wrong entity:
  1. `uw_data` read as an input; written at block line 584 inside a one-line
     `if ... then`, and the assignment regex was anchored to line-start.
  2. `y_valid`/`y_mant`/`y_last` read as seam members; they are block-LOCAL,
     and `llama_top` declares same-named signals in a DIFFERENT generate block,
     which the resolver found instead.
  3. `rdy`/`dn`/`ep`/`yexp` the same.
  4. `u_start, u_ready, u_done, u_ack, u_err` invisible entirely: their
     declaration spans two lines.
  5. `u_done_epoch`/`u_y_exp` read as inputs; both are written with a slice
     containing nested parentheses, `((U_B+1)*EPOCH_W-1 downto ...)`, which
     `\([^)]*\)` cannot match.
  The seam is therefore a CHECKED LITERAL, and the check that it is right is
  that the output analyses: GHDL rejects an assigned `in` port, a
  doubly-declared name, and an undeclared one.
- **Generic-dependent types cannot cross an entity boundary.** `nat_u`,
  `sig_u`, `qexp_t` and `buf_t` are architecture-local types whose bounds
  depend on `llama_top`'s own generics; the port list elaborates before the
  generics are known. The seam had to be flattened to `std_logic_vector` with a
  conversion block OUTSIDE the verbatim body.
- **A conditional expression is not legal in a constant declaration.**
  `constant X : positive := (a when c else b);` does not analyse; the override
  goes through a function.
- **`LAYERS = 24` is CHECKED, not hand-derived.** `llama_map_pkg.vhd:167` warns
  that "every hand-derivation of these in this repo has been wrong once". 9B
  has `blocks => 32, attn_interval => 4`, so `attn_layers = 8`, `gdn_layers = 24`.

## Open, not yet answered

- **No substitution has been made.** `gdn_state_store` is built and verified
  standalone; nothing wires it into `gb_real`, and the port shapes have not
  been compared against `stmem_p`'s two accesses.
- **`zb`/`yb` still need a real memory** before the block builds at 12288, and
  no fix is proposed here. It is now the SECOND blocker rather than a
  side-issue, because removing `stmem` does not remove it.
- **The mover's `-4.008` is not attributed.** `stmem` is the largest suspect
  and is being removed regardless, so the honest position is that the timing
  question reopens after the substitution.
- **LUT and timing figures are pre-`opt_design`**, and no place-and-route has
  been run.
- **C's mover (`gcr`, 762 lines) has not been extracted.** The method
  transfers; the seam does not, and mapping it is the same day of work.
- **Nothing here says B computes a correct token.** `llama_top:4316` still
  refuses `B_SRC_REAL` past token 0.
