# The seam gets an address: 0xE000 decided, assigned, instantiated and guarded

TRACK SEAMMAP, 2026-08-30. Started at `d53af73`, HEAD moved to `da06d96` during
the run (five other tracks were live).

## The question, verbatim

> Oren decided N2 option (a) verbatim: **"we don't want host controlling, let's
> get D working"**. TRACK DSEAM then built `rtl/fk33_seam.vhd` (840 lines,
> commit `9270c7a`) and its bench. **What is still missing is the address.**
> Your job is to make the seam a real, addressable block in the generated
> design.
>
> Deliver: `0xE000` assigned in `gen_pcieep.py`, the seam instantiated and
> address-mapped in the emitted block design, the generated artefacts
> regenerated, and the generator selftest green.
>
> **Decide and JUSTIFY whether `0xE000` is actually the right base**, rather
> than inheriting it because a header proposed it.

## The answer, up front

**0xE000 is correct and is now assigned.** It is free, 4 KB aligned, inside the
128 KB AXI-Lite BAR, and it is already the value both halves of the host
contract carry. Keeping it costs nothing; moving it would cost an edit to
`server/fk33_seam.h`, `server/fk33_sim.c`, `server/pl_backend.c` and
`server/tests/seam_selftest.c` for no gain.

**The seam is instantiated, mapped, and its subsystem-D face is tied off with
`d_err` HIGH.** That last word is the finding of this track and it is not a
detail:

> MEASURED by reading `rtl/fk33_seam.vhd:549-566`: the completion arm runs only
> `if running = '1'`, and `running` is cleared ONLY by `d_err`, `d_tok_done` or
> an explicit ABORT. There is no subsystem D in this bitstream, so if the
> obvious "unused input" choice is made and BOTH `d_err` and `d_tok_done` are
> tied LOW, a GO sets `running` and **nothing ever clears it**: STATUS bit 0
> (done) never sets, bit 2 (err) never sets, and a host following this seam's
> own documented `(done | err)` poll loop **hangs forever**.

With `d_err` tied HIGH the same GO terminates on the next cycle with
`st_err = 1`, `st_code = EC_DESC (6)` and `ERR_INFO[3:0] = 0xF`. `0xF` is not a
code `rtl/llama_top.vhd` can produce, so it reads as "there is no subsystem D
in this bitstream" and never as a real descriptor fault. The four `CAPS_*`
generics are left at their RTL default of 0, so `CAPS_VOCAB` reads 0, which is
the honest report of a bitstream with no model behind the seam.

**What this does NOT answer, and no tool in this repository can:** whether the
seam RESPONDS at 0xE000 on the card. See "Open, not yet answered".

## The procedure, in the order it was run

1. **Read the authoritative map, not the documents.** `grep assign_bd_address
   hw/fk33/build_fk33_pcieep.tcl` -- the EMITTED build script, which is what
   Vivado consumes -- rather than `hw/fk33/host/fk33_regs.h` or the prose in
   `server/fk33_seam.h`. This isolates "what the bitstream decodes" from "what
   a host header believes".
2. **Establish pre-change reproducibility.** `md5sum` the two artefacts, run
   `python3 hw/fk33/gen_pcieep.py`, `md5sum -c`. Controls for the possibility
   that the checked-in artefact was already out of step with its generator, in
   which case any later diff would be unattributable.
3. **Read the seam's control FSM before choosing a tie-off**, specifically
   which signals clear `running`. This is what turned an assumed one-line
   change into the `d_err` finding.
4. **Emit the block, then check the emitted text**, not the generator's
   intentions. Both new checks (`check_bar_map`, `check_seam_tieoff`) run on
   the string `main()` is about to write.
5. **Teeth, on the real artefact.** `addr_map_teeth()` mutates
   `build_fk33_pcieep.tcl` itself, so a row whose anchor stops occurring
   exactly once goes VOID instead of silently green.
6. **The attribution control, three arms** (see below).
7. **Post-change reproducibility**, then a full `md5sum -c` over all 1,868
   tracked files.

## The attribution control

Every mutation is scored against three independent arms, reported separately:

| arm | what it is |
|---|---|
| `OLD` | the two address literals present in `gen_pcieep.py` BEFORE this track (`assign_bd_address -offset 0x00004000`, `... 0x0000B000`) |
| `NEEDLE` | this track's own literal string needles for the seam |
| `MAP` | `check_bar_map()`, the parsed overlap / containment / alignment check |

A kill only `MAP` catches is a kill that justifies `check_bar_map`'s
maintenance. A kill `OLD` also catches is one this track must not claim.

**MEASURED, `python3 hw/fk33/gen_pcieep.py --selftest`:**

```
ADDRESS-MAP TEETH (check_bar_map), with the attribution control
ROW  VERDICT   OLD  NEEDLE MAP  MUTATION
----------------------------------------------------------------------------
A1   REFUSED   -    yes    yes  the seam moved onto the thermal block at 0xB000
A2   REFUSED   -    yes    yes  the seam moved past the end of the 128 KB BAR
A3   REFUSED   -    yes    yes  the seam at a base that is not 4 KB aligned, which aliases a 12-bit slave onto itself
A4   REFUSED   -    yes    yes  the seam's address assignment deleted entirely
A5   REFUSED   -    -      yes  the engine control map back at 0x11000, inside the 8 KB scratch -- the collision that cost a --bd-only run
A6   REFUSED   -    -      yes  the scratch grown to 16 KB, swallowing both engine pages without either of them moving
A7   REFUSED   -    -      yes  a new peripheral mapped whose address space nobody declared
A8   REFUSED   -    -      yes  the two arms of the HBM if/else disagreeing: SAXI_16/MEM16 at a different offset in the else branch
A9   accepted  -    -      -    SAFE: the scratch relocated to another free, aligned, in-BAR hole at 0x18000
A10  accepted  -    -      -    SAFE: the thermal control page written before the peak page.  assign_bd_address order carries no meaning and neither may this scan
A11  accepted  -    -      -    FLOOR: fk33_id relocated to the free 0xF000 page. Legal, unique, aligned -- and host/fk33_regs.h still says 0xA000
A0   accepted  -    -      -    the UNMUTATED emitted script (the control)
----------------------------------------------------------------------------
MAP ALONE=4  both=4  NEITHER=0
```

**The `OLD` column is empty on every row.** Not one of these eight defects was
covered by anything that existed before. DERIVED, and checkable:
`git show d53af73:hw/fk33/gen_pcieep.py | grep -ci seam` returns **0** -- the
pre-SEAMMAP generator does not mention the seam at any point, so no pre-existing
check could refer to it.

**A5 is the row that pays for the whole check.** `ENGINE_ADDR`'s own comment
records the engine being put at 0x11000, colliding with the second 4 KB of the
8 KB scratch at 0x10000, and being caught by a 90-second `--bd-only` Vivado run
with `BD 41-1075`. Nothing in this file could see it. It now refuses in
milliseconds.

## The mutation that does NOT bite, reported under its own name

**A11: `fk33_id` relocated from 0xA000 to the free page at 0xF000.**
`check_bar_map` ACCEPTS it, correctly on its own rules -- aligned, unique,
inside the BAR -- and the bitstream would be wrong, because
`hw/fk33/host/fk33_regs.h` hardcodes `FK33_ID_BASE 0x0000A000`. The host would
read the now-empty 0xA000 page and get `0x00000000`, which that header's own
comment says means "the fabric is in reset". A bring-up would chase a
non-existent fabric fault.

This measures the check's resolution floor exactly: **`check_bar_map` verifies
that the map is INTERNALLY CONSISTENT, not that it is the map the host
believes.** `gen_pcieep.py` pins only `THERM_*` against `fk33_regs.h`; `ID`,
`SCRATCH`, `DMABRAM`, `ENG_CTL` and `ENGX` are all unpinned. Widening the
address rules cannot fix this. The fix is a `fk33_regs.h` cross-check of the
same shape as the existing `fk33ctl.py` one, and it is filed below rather than
done here, because `hw/fk33/host/fk33_regs.h` was outside this track's
ownership.

## The tie-off guard, in both directions

Both states this guard refuses are SILENT everywhere else.

**MEASURED, same selftest run:**

```
SEAM TIE-OFF TEETH (check_seam_tieoff)
ROW  RESULT    STATE
----------------------------------------------------------------------------
S1   accepted  SHIPPING: tie-off present, fk33_engine has no llama_top
S2   REFUSED   the tie-off survives into a build whose engine DOES instantiate llama_top: every GO refused with a real transformer behind the seam
S3   REFUSED   the tie-off removed before subsystem D exists: d_err low, GO sets `running` forever, a (done | err) poll hangs
S4   accepted  N3's future state: no tie-off and a real llama_top. Must be ACCEPTED or this guard blocks the work it exists to hand over to
----------------------------------------------------------------------------
SELFTEST PASS
```

S4 matters as much as S2 and S3: a guard that blocks N3 from removing the
tie-off is a guard N3 deletes, and then the property has nothing.

## The three-copy cross-check, and its teeth

The seam contract exists in three places -- `rtl/fk33_seam.vhd` (the gateware),
`server/fk33_seam.h` (the host) and `gen_pcieep.py` (the only thing that can put
them at one address). All three are now cross-checked in `main()`, the same
treatment `host/fk33ctl.py`'s `THERM_*` constants already had, and for the same
stated reason: a drift is silent, because the host reads a different peripheral
and prints a plausible number.

**MEASURED**, harness at `/mnt/storage/seammap-scratch/xcheck_teeth.py` (each
row mutates one file, runs the generator, restores the file in a `finally`):

```
ROW  RESULT    MUTATION
------------------------------------------------------------------------------
X1   REFUSED   the host header moved to 0xF000 while the bitstream stays at 0xE000
       ABORT: server/fk33_seam.h FK33_SEAM_BASE is 0x0000F000 but this build puts it at 0xe000.
X2   REFUSED   the header reverts to the _PROPOSED name after the base is assigned
       ABORT: server/fk33_seam.h still calls the base FK33_SEAM_BASE_PROPOSED.
X3   REFUSED   the host and the RTL disagree on the seam identity word
       ABORT: server/fk33_seam.h FK33_SEAM_ID_MAGIC is 0x4C4C4D33 but this build puts it at 0x4c4c4d32.
X4   REFUSED   the host thinks the seam is 8 KB, the bitstream maps 4 KB
       ABORT: server/fk33_seam.h FK33_SEAM_SPAN is 0x2000 but this build puts it at 0x1000.
X5   REFUSED   the RTL identity word changed and no host would recognise the block
       ABORT: rtl/fk33_seam.vhd ID_MAGIC is 0xDEADBEEF but gen_pcieep.py SEAM_MAGIC is 0x4C4C4D32.
X6   REFUSED   the seam defaults to publishing a 248,320-token vocabulary with no D
       ABORT: rtl/fk33_seam.vhd defaults CAPS_VOCAB to 248320, not 0.
X7   REFUSED   the slave decodes 16 address bits, so a 4 KB page no longer covers it
       ABORT: rtl/fk33_seam.vhd's AXI-Lite write address is no longer 12 bits, so SEAM_SPAN = 0x1000 ...
X0   accepted  CONTROL: an unrelated edit to the header must NOT be refused
------------------------------------------------------------------------------
CROSS-CHECK TEETH: all rows as expected
```

Attribution for X1-X7 is the same as above and is DERIVED rather than run: the
pre-SEAMMAP generator contains the string "seam" zero times, so none of these
could have been caught before.

## The evidence for the base decision

MEASURED occupancy of the PCIe AXI-Lite BAR, from
`grep assign_bd_address hw/fk33/build_fk33_pcieep.tcl` at `d53af73` (the emitted
script, before this track added anything):

```
0x00003000  4K  system_management_wiz_0/S_AXI_LITE/Reg   SYSMON
0x00009000  4K  axi_gpio_0/S_AXI/Reg                     I2C / LED
0x0000A000  4K  fk33_id/S_AXI/Reg
0x0000B000  4K  fk33_therm/S_AXI/Reg
0x0000C000  4K  fk33_thermp/S_AXI/Reg
0x0000D000  4K  fk33_thermc/S_AXI/Reg
0x00010000  8K  fk33_scratch/S_AXI/Mem0
0x00012000  4K  eng/s_axi/reg0
0x00013000  4K  eng/s_axix/reg0
```

The `0x0000..0x6000` assignments in the same file are `jtag_aux`'s own address
space and never appear on the BAR; `0x200000000` is `fk33_dmabram` on the DMA
master. So the only free 4 KB pages below the scratch are **0xE000 and 0xF000**,
and 0xE000 is the lower.

BAR size: `CONFIG.axilite_master_size {128}` /
`CONFIG.axilite_master_scale {Kilobytes}`, i.e. 0x00000..0x1FFFF.
`0xE000 + 0x1000 = 0xF000` is under it. **CAVEAT, and it is the project's own
recorded trap:** that is a REQUEST written into the Tcl, not a report. What
actually answers "is 0xE000 inside the master's decode" is `assign_bd_address`
accepting it during a Vivado run.

Alignment: `rtl/fk33_seam.vhd`'s slave takes `s_axi_awaddr(11 downto 0)`, so any
base that is not 4 KB aligned aliases the register file onto itself.
`FK33_SEAM_SPAN` is 0x1000 and matches. Row A3 shows the check refuses
0xE800.

**Correction to `server/fk33_seam.h`, applied in the same commit.** Its
occupancy list said "0x3400 (SYSMON)". 0x3400 is SYSMON's temperature REGISTER;
the block occupies 0x3000..0x3FFF with a 4 KB range. The answer does not change
-- both readings leave 0xE000 free -- but it is exactly the hand-maintained map
that `check_bar_map` now replaces with a parse of the emitted script.

## The macro rename, and why it touched four files this track did not own

`server/fk33_seam.h`'s own comment set the condition:

> The name stays `_PROPOSED` until that grep returns a line. Renaming it before
> then would make every caller read as though the address were real.

The grep now returns a line, so `FK33_SEAM_BASE_PROPOSED` became
`FK33_SEAM_BASE`. That is a pure identifier substitution across
`server/fk33_sim.c`, `server/pl_backend.c`, `server/pl_backend.h` and
`server/tests/seam_selftest.c`. VERIFIED rather than assumed:

```
$ git diff -U0 -- server/fk33_sim.c server/pl_backend.c server/pl_backend.h \
      server/tests/seam_selftest.c | grep '^[+-][^+-]' | grep -v FK33_SEAM_BASE
(no output)
```

Every changed line in those four files mentions the macro and nothing else.
MEASURED, `cd server && make check` -> `SERVER_COMPILE OK`; `make test` ->
`SEAM_SELFTEST PASS (84 checks, 0 failed)`, matching the 84 recorded by TRACK
EMBDROP in `docs/debugging/2026-08-29_host-embedding-gather.md`.

`gen_pcieep.py` now REFUSES to emit a build while a `#define
FK33_SEAM_BASE_PROPOSED` survives in the header (row X2), so the old name cannot
come back silently.

## Reproducibility and the artefact diff

- **Pre-change:** `md5sum` both artefacts, run the generator, `md5sum -c` ->
  both OK. The checked-in artefacts were already in step with their generator,
  so any diff below is attributable to this track.
- **Post-change:** the generator run twice back to back produces byte-identical
  output. `hw/fk33/fk33_pcieep.xdc` is **byte-identical to `d53af73`** -- it is
  not in the failed list of the full `md5sum -c` below.
- **`hw/fk33/build_fk33_pcieep.tcl`: +85 lines, 0 deletions.** MEASURED,
  `git diff -- hw/fk33/build_fk33_pcieep.tcl | grep -c '^-[^-]'` returns **0**,
  in three hunks: the `add_files` for the seam RTL, the seam block, and the
  `assign_bd_address`.
- **Full tree:** `md5sum -c` over all **1,868** git-tracked files at `d53af73`.
  14 differ. Seven are this track's (`hw/fk33/gen_pcieep.py`,
  `hw/fk33/build_fk33_pcieep.tcl`, `server/fk33_seam.h`, `server/fk33_sim.c`,
  `server/pl_backend.c`, `server/pl_backend.h`,
  `server/tests/seam_selftest.c`). The other seven -- `CLAUDE.md`,
  `docs/WORKLOG.md`, two `docs/debugging/2026-08-30_*.md`,
  `hw/fk33/results/timing_2026-08-30/pblock_squeeze.tcl`, `rtl/llama_top.vhd`,
  `tools/verify_mv4i_desc.py` -- are five concurrent tracks landing while this
  one ran, and HEAD moved `d53af73` -> `da06d96` during the session.

## Measured and REJECTED -- do not retry

- **Tying `d_err` LOW with `d_tok_done` LOW.** The obvious "this input is
  unused" choice. It makes a GO set `running` forever, and the poll loop
  `server/fk33_seam.h` prescribes hangs with no timeout anywhere in the path.
  Guarded by row S3.
- **Fabricating a completion by tying `d_tok_done` to `d_go`.** Terminates the
  poll loop and returns `ARGMAX = 0` as though it were a token. A wrong answer
  that looks right is worse than a hang; a refusal is better than both.
- **Moving the seam to 0x14000 to sit beside the engine's 0x12000/0x13000.**
  Purely cosmetic grouping, and it costs an edit to both halves of a host
  contract that already agrees on 0xE000. A base only one side believes in is
  worse than no base.
- **A hand-written `(name, base, size)` table in `gen_pcieep.py`, checked for
  overlap.** This is the shape of the descriptor-base rule that "agreed with
  its cross-check by coincidence of geometry on every file it had ever seen":
  it would be a SECOND statement of the map, checked against itself, staying
  green while the emitter drifted. `check_bar_map` parses the emitted script
  instead, so there is exactly one statement of the map.
- **Pooling every `assign_bd_address` into one space and refusing repeats.**
  It REFUSES THE CORRECT DESIGN. See the traps below.
- **Shrinking `DESC_WORDS`/`REL_ENT` for the D-less build to save BRAM.** The
  host cannot discover the window capacity -- there is no register publishing
  it -- so a host writing a real 4,040-word descriptor program would have words
  past the bound silently dropped. DERIVED cost of keeping the full size:
  4,608 x 64 bits + 576 x 14 bits = 302,976 bits, about 10 RAMB36 against the
  ~784 the composed design already uses (38.91% of the VU33P's 2,016), i.e.
  about +0.5%. Not the congestion axis.

## Measurement traps hit, including this track's own

1. **`assign_bd_address` is written across four lines with Tcl backslash
   continuations.** The first scan read `assign_bd_address \` and saw neither
   the offset nor the `-target_address_space` that says a line is an engine
   master's view of HBM rather than a slave map. Without joining continuations
   the check either crashes or, worse, classifies 896 HBM segments as
   unparseable BAR entries. Fixed by `re.sub(r"\\\n\s*", " ", text)` before
   parsing.
2. **THE EMITTED SCRIPT CONTAINS MUTUALLY EXCLUSIVE TCL BRANCHES AND A STATIC
   SCAN SEES BOTH ARMS.** MEASURED: `build_fk33_i2cprobe.tcl` assigns
   `hbm/SAXI_00/HBM_MEM00` at 0x0 inside `if {$HBMGlobalSwitch == 1}` AND again
   at 0x0 inside the `else`. **A naive "no two offsets may repeat" rule refuses
   the correct design**, which is how a guard gets deleted. The rule that works:
   identical `(segment, base, range)` rows are the same decision written in two
   arms and collapse; a segment assigned two DIFFERENT addresses refuses (row
   A8). This keeps the whole 8 GiB DMA space inside the overlap check rather
   than carving `hbm` out of it.
3. **Three address spaces legitimately collide.** `jtag_aux`'s `aux_time` is at
   0x3000 and the BAR's SYSMON is at 0x3000. Both are real. Segments are
   classified explicitly by cell name into BAR / AUX / DMA and an
   **unclassified segment is a hard refusal**, so a peripheral added later
   cannot be silently excluded from the overlap check by being unknown to it
   (row A7).
4. **A loose substring needle refused the state it was asking for.** The first
   version of the `_PROPOSED` guard tested `"FK33_SEAM_BASE_PROPOSED" in
   h_src`, which fired on the header's own sentence recording what the macro
   used to be called. Now matched as `^#define\s+FK33_SEAM_BASE_PROPOSED\b`.
   Same shape as the `[get_bd_pins fk33_therm_0/compute_clk]` needle already
   recorded in this file, which was "found by running this guard against a
   broken copy and watching it NOT bite".
5. **A full `md5sum -c` over a moving tree reports other tracks as failures.**
   Seven of the 14 differing files are five concurrent tracks. The baseline was
   taken at `d53af73`; HEAD is `da06d96`. Read `git status --porcelain` against
   the md5 list before concluding anything.
6. **The BITPREP caveat on `--selftest`, restated rather than assumed.** TRACK
   BITPREP recorded, verbatim in `e0e4fec`: *"gen_pcieep.py --selftest PASS
   (8 GUARD ALONE) -- which covers the injected Tcl guards only, not this
   one."* That is still true of the 8-row `GUARD ALONE` table: it exercises
   `fk33_assert_run_started` / `fk33_assert_run_done` / `fk33_bound` under
   `tclsh` and nothing else. **A green `--selftest` is not evidence about the
   address map on its own** -- the evidence is the separate `ADDRESS-MAP TEETH`
   and `SEAM TIE-OFF TEETH` tables this track added, each with its own control
   row.

## Open, not yet answered

1. **Does the seam RESPOND at 0xE000?** Nothing here answers it and a round
   trip through the generator would not: emitting `0xE000` and parsing back
   `0xE000` is self-consistency. The two things that would answer it, in order:
   - **A Vivado `--bd-only` run.** `assign_bd_address` accepting the offset
     proves the address is legal, unique and inside the master's space -- it is
     the tool that caught the 0x11000 collision with `BD 41-1075`. It would
     also settle three things this track could not verify statically and which
     are the most likely ways the emitted Tcl is wrong: (a) whether the
     inferred segment is `fk33_seam_0/s_axi/reg0`, chosen because `eng`, the
     only other module-reference slave in this design, is mapped as
     `eng/s_axi/reg0`; (b) whether Vivado's module reference accepts
     `fk33_seam`'s `unsigned`/`signed` and `natural range` ports; (c) whether
     `core_reset/peripheral_reset`, a `[0:0]` vector pin, connects to the
     seam's scalar `rst`. **All three fail LOUDLY at the BD stage if wrong,
     none of them silently.** NOT RUN: the brief requires asking first, and its
     memory footprint is unmeasured. **This is a REQUEST to Oren.**
   - **A host read of 0xE000 returning `0x4C4C4D32`** on a configured card.
     Hardware, therefore Oren's.
2. **`hw/fk33/host/fk33_regs.h` has no seam block and its non-thermal bases are
   unpinned.** Row A11 is the measured consequence. Someone should add
   `FK33_SEAM_BASE` to it and extend the `fk33ctl.py`-style cross-check in
   `main()` to cover `FK33_ID_BASE`, `FK33_SCRATCH_BASE`, `FK33_DMABRAM_BASE`,
   `FK33_ENG_CTL_BASE` and `FK33_ENGX_BASE`. Outside this track's ownership,
   recorded rather than done.
3. **`rtl/fk33_seam.vhd`'s `CAPS_FLAGS_V` is a hard constant `0x00000005`,
   which sets `FK33_CAP_SAMPLER`.** In this bitstream there is no sampler,
   because there is no subsystem D. `CAPS_VOCAB = 0` and the ERR on every GO
   make the state unambiguous, so nothing is reachable that acts on the flag,
   but the word is still not the truth. **Reported, not fixed:
   `rtl/fk33_seam.vhd` is TRACK DSEAM's.** The fix is to make `CAPS_FLAGS`
   derive from generics rather than be a constant.
4. **`desc_ram` is written by the AXI process and read by the `dram` process.**
   A single array signal driven from one process and read from another usually
   infers a simple dual-port BRAM, but "usually" is not a measurement and this
   has never been synthesised. An OOC synthesis of `fk33_seam` alone would say,
   and would also give the real LUT/BRAM cost against the ~10 RAMB36 derived
   above. NOT RUN, same reason as (1).
5. **The GHDL gate was not run and this track asserts nothing about it.** No
   VHDL was added or changed; `sim/regress.sh`'s planner globs `rtl/`, `sim/`,
   `sim/micro/` and `tb/`, none of which this track touched. TRACK GATEGREEN
   held the gate for the whole session and `ghdl-mcode` has been MEASURED at
   20.9 GiB anon-RSS in one process.

## Corrections to the brief

**One, and it is a scoping correction rather than a factual one.** The brief
said "the seam instantiated and address-mapped in the emitted block design"
without saying what the seam's subsystem-D face should be driven by, which
reads as though the instantiation were mechanical. It is not: subsystem D is
not in this design (board row N3, blocked), so the instantiation had to choose
between a bitstream that hangs a host, one that fabricates a completion, and
one that refuses every GO with a distinguishable code. The third was chosen and
is guarded in both directions by `check_seam_tieoff`. **What is on the BAR at
0xE000 after this commit is a real, addressable, honest seam with no
transformer behind it, not a working subsystem D**, and any claim that N2 is
"done" should say so.
