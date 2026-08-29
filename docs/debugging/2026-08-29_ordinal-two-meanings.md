# `ordinal` meant two different things, and only one of them is the spec's

2026-08-29. TRACK ORDINAL. Repo `llama.vhdl`, HEAD `35e0ed0` at the time of
measurement (the tree moved twice during this track: `78e2f5a` -> `d1d1e95` ->
`35e0ed0`; every number below was re-measured at `35e0ed0` unless it says
otherwise). GHDL mcode, Vivado 2023.2, part `xczu3eg-sfvc784-1-e`.
No hardware was touched.

---

## 1. The question, verbatim

From TRACK SCHED-FIX's write-up
(`docs/debugging/2026-08-29_sched-nsub-and-what-executes.md`), raised and
deliberately not fixed there:

> **`ordinal` means two different things.** `rtl/llama_top.vhd:2992,:3799`
> reads it as the **block index** and derives the layer itself;
> `sim/seq_tbl_pkg.vhd:376,417` and `tools/gen_layer_program.py:353,400` stamp
> the **per-kind** ordinal.
>
> DERIVED at the 9B shape: driving the manifest-stamped program into
> `llama_top` addresses the wrong layer on **29 of 32 blocks** and computes
> `c_layer = -1` on blocks 3, 7, 11, which is out of range for
> `integer range 0 to C_LAY-1`.

Four things were asked: confirm or refute it by RUNNING something; decide which
meaning is correct and make every site agree; state the field's meaning
normatively in the D spec; and say what `c_layer = -1` would actually do,
distinguishing simulation from synthesis.

---

## 2. The answer, up front

**CONFIRMED, exactly as stated, by three independent measurements.** 29 of 32
blocks, `c_layer = -1` on the first three attention blocks. Not one figure in
the brief was wrong.

**The PER-KIND ordinal is correct and the consumer was the defect.** The D
spec fixes the field per-kind in two places, and `rtl/seq_top_skel.vhd` -- the
D subsystem's own RTL, not a document -- declares the port as
`unsigned(5 downto 0); -- B: 0..47, C: 0..15` and wires the latched value
**straight into `b_w_sel`** with no arithmetic. That is what the field is for.
`rtl/llama_top.vhd` now takes the ordinal and derives nothing;
`sim/llama_sched_pkg.vhd`, the one generator that stamped the block index, now
stamps the per-kind ordinal like the other two.

**`c_layer = -1` on the card is not an error and not a hang. It is layer 7.**
MEASURED in Vivado: with the ordinal a run-time value, the expression
synthesises with **0 errors** into a **3-bit** register (`C_LAY = 8` at the 9B
shape), so `-1` is stored as `111`. Blocks 3, 7 and 11 would each have read and
written attention layer **7**'s KV cache -- the last layer's -- silently.
There is one exception worth knowing: if the value is STATICALLY derivable,
Vivado does error (`[Synth 8-11323] assigned value '-1' out of range`). In
`llama_top` it is not: the ordinal arrives from descriptor memory.

**The fix is value-preserving at every shape**, and that is checkable rather
than asserted: the old consumer computed `blk - (blk+1)/attn_interval` from a
block index, which is exactly the `gdn_ord` the new producer stamps. Every
`tb_llama_top` landmark hash is unchanged (38863 / 81180 / 25008, three
configurations, base and fixed).

**Not live on hardware today**, and this matters for how the defect is read:
the FK33 bitstream is `hw/fk33/rtl/fk33_engine.vhd` wrapping
`matvec_int4_desc_axi`, subsystem A only. There is no D on the card, so
nothing has ever executed the wrong layer on silicon. It goes live the moment
D is on the card.

---

## 3. Which meaning is correct, and why it is not the cheaper one

It would have been cheaper to keep the block-index reading: two producers to
change instead of one consumer plus one producer, and the pair that already
agreed is the pair the gate runs. The per-kind reading wins on the evidence.

**For per-kind:**

1. **D spec 4.1** gives the generator formulas
   `gdn_ord(i) = i - (i+1)/4` and `attn_ord(i) = (i-3)/4`, and says "B receives
   `gdn_ord`, C receives `attn_ord` (O6)".
2. **D spec 6.1**, the descriptor table, row `0x19`: `ordinal (B: 0..47,
   C: 0..15)`. Those are per-kind ranges at the 27B shape; a block index there
   is 0..63.
3. **D spec 6** on the constant memory: "B's constant read ports ... offset by
   `ordinal` from the descriptor."
4. **`rtl/seq_top_skel.vhd:125`** declares
   `job_ordinal : out unsigned(5 downto 0); -- B: 0..47, C: 0..15`, and
   **`:403`** is `b_w_sel <= shadow(live_bank).ordinal;` under the comment
   "B's ssm_norm select is the LATCHED ordinal, not the live block counter."
   This is RTL. The house rule is that where a document and the RTL disagree
   the RTL wins -- and here **two RTL files disagreed with each other**, so
   the rule had to be applied to the one that is subsystem D rather than the
   integration top.
5. **The arithmetic argument, which is the decisive one.** Both formulas
   divide by `attn_interval`, a build generic. A consumer that re-derives has
   put a divider in the gateware. `rtl/seq_top_skel.vhd:214` argues in its own
   words that D-ctrl is 0 DSP precisely because "the ordinals come from the
   host generator", and spec 4.1 says "in practice D does not compute these".
   The block-index reading is not merely a different convention; it
   contradicts the reason the field exists.
6. `sim/seq_tbl_pkg.vhd`, `tools/gen_layer_program.py` and
   `tools/dprog_oracle.py` were all already on this side.

**For block index:** `rtl/llama_top.vhd:2992,:3799` and
`sim/llama_sched_pkg.vhd:366`. That is the whole case, and those two are
exactly the pair that were checked against each other.

**One argument that looked like support for block-index and is not.** All
three generators stamp `blk mod 64` as the ordinal of a block's `VEC_NORM`
step, which makes the field look uniform. It is not consumed there: the
norm-weight selector is `const_base` (0x20), and no RTL in the tree reads
`ordinal` outside a B or C job. MEASURED -- see mutation **T4** below, which
sets it to 0 and changes nothing.

---

## 4. The procedure, in the order it was run

Each step says what it controls for.

| # | probe | what it isolates |
|---|---|---|
| **M1** | Elaborate `sim/seq_tbl_pkg.build_table` at the committed 9B `MODEL`, read the `ordinal` byte back OUT of encoded word 3 bits 15:8, apply `llama_top`'s two expressions verbatim | the VHDL producer's emitted BYTES against the consumer's arithmetic. Reading the byte back rather than the generator's variable is the point: it is the wire format that is contested |
| **M1b** | Same probe in Python against `tools/gen_layer_program.py --stamp manifest`'s `d_table.hex` | the *other* producer, independently. Two producers agreeing would prove nothing, so both are judged against the same third thing (below), not against each other |
| **M1c** | `tools/dprog_oracle.py`'s existing `C5-ordinal-B` / `C5-ordinal-C` run against `--stamp sched` | a third angle whose layer numbering comes from `tools/ref9b/seam_map.py`, i.e. llama.cpp's execution order, not from any generator in this repo |
| **M2** | Real `rtl/llama_top.vhd` driven by a scratch `llama_sched_pkg` stamping per-kind ordinals, `-gBLOCKS=8 -gC_REAL=true -gATTN_HD=16` | the CONSUMER, on unmodified RTL. M1 applies the expression by hand; this runs it |
| **M3** | Same at `-gBLOCKS=8 -gATTN_INT=2`, C stubbed | the B half in isolation, where the failure is silent rather than fatal |
| **M4** | Vivado OOC synthesis of the isolated `c_layer` expression, run-time input and constant input | simulation-versus-synthesis. A VHDL integer range is a bound check in one and a width in the other |
| **M5** | base / fixed hash comparison at three configurations | that the fix moves no numbers |
| **T1..T4** | mutations | that the checks have teeth, and where their floor is |

**The oracle in M1, M1b and M2 is the schedule ORDER, not either generator:**
the n-th `B_JOB` of a token is GDN layer n and the n-th `C_JOB` is attention
layer n, because a token visits blocks in ascending order exactly once. M1c
substitutes llama.cpp's own graph for that reasoning and gets the same answer.

---

## 5. The evidence, as raw output

### 5.1 M1 -- the VHDL producer's bytes against the consumer's arithmetic

`ghdl -r tb_ord_probe --max-stack-alloc=0`, over
`rtl/model_cfg_pkg.vhd sim/seq_tbl_pkg.vhd` at `MODEL = QWEN35_9B`:

```
MODEL blocks=32 attn_interval=4 steps=505
C  attn_layer=0 ordinal_byte=0 llama_top_c_layer=-1  MISMATCH
B  gdn_layer=3 ordinal_byte=3 llama_top_b_layer=2  MISMATCH
B  gdn_layer=4 ordinal_byte=4 llama_top_b_layer=3  MISMATCH
B  gdn_layer=5 ordinal_byte=5 llama_top_b_layer=4  MISMATCH
C  attn_layer=1 ordinal_byte=1 llama_top_c_layer=-1  MISMATCH
...
C  attn_layer=7 ordinal_byte=7 llama_top_c_layer=1  MISMATCH
TOTALS  B_JOBS=24 wrong=21   C_JOBS=8 wrong=8 of which negative=3
BLOCKS_ADDRESSED_WRONG=29 of 32
```

### 5.2 M1b -- the Python producer's bytes, same probe

```
$ python3 gen_layer_program.py --token --x-exp 5 --no-hash \
      --manifest .../qwen35-9b-mv4i-qkvpad/manifest.json --d-table prog/d_table.hex
$ python3 ordprobe.py prog/d_table.hex 4
...
TOTALS steps=505  B_JOBS=24 wrong=21   C_JOBS=8 wrong=8 negative=3
BLOCKS_ADDRESSED_WRONG=29 of 32
```

**Directional control on the probe itself**, so it is not a check that cannot
fail: the same probe against `--stamp sched`, which stamped the block index,
returns clean and exits 0.

```
$ python3 ordprobe.py sched/d_table.hex 4
TOTALS steps=505  B_JOBS=24 wrong=0   C_JOBS=8 wrong=0 negative=0
BLOCKS_ADDRESSED_WRONG=0 of 32
rc=0
```

### 5.3 M1c -- the third angle, from llama.cpp's execution order

`tools/dprog_check.sh` at pristine `35e0ed0`, the `--stamp sched` control:

```
  by check: C1-count=1, C4-outshift=253, C4-wexp=311,
            C5-ordinal-B=21, C5-ordinal-C=8, C8-hdr=564
```

`21 + 8 = 29`, from an oracle that never consults either VHDL generator.
Three independent routes, one number.

### 5.4 M2 -- the real RTL, the C half

`ghdl -r tb_llama_top -gBLOCKS=8 -gC_REAL=true -gATTN_HD=16`, unmodified
`rtl/llama_top.vhd`, `llama_sched_pkg` stamping per-kind:

```
/usr/bin/ghdl-mcode:error: bound check failure at rtl/llama_top.vhd:3804
in process .tb_llama_top(tb).dut@llama_top(rtl).gcr.cp
  from: process work.llama_top(rtl).gcr.B1.cp at llama_top.vhd:3804
/usr/bin/ghdl-mcode:error: simulation failed
```

### 5.5 M3 -- the real RTL, the B half, and this is the dangerous one

`-gBLOCKS=8 -gATTN_INT=2`, C stubbed so the run reaches the end:

```
base     RESULT: PASS -- R_X(0) = -13981 hash(R_X) = 81180
perkind  RESULT: PASS -- R_X(0) = -13984 hash(R_X) = 53566
```

**Both PASS.** The B half addresses the wrong GDN layer's state memory,
produces a different residual stream, and every property in `tb_llama_top`
is satisfied. Only the hash sees it. The C half aborts; the B half does not.

### 5.6 M4 -- what `-1` does in synthesis

Isolated entity carrying `rtl/llama_top.vhd:3388`'s declaration and
`:3804`'s expression, `synth_design -mode out_of_context`, `xczu3eg`.

Run-time input (`ord` a port), `C_LAY = 8`:

```
Synthesis finished with 0 errors, 0 critical warnings and 14 warnings.
  GND GND / VCC VCC
  LUT3 c_layer[0]_i_1 / LUT4 c_layer[1]_i_1 / LUT5 c_layer[2]_i_1
  FDRE c_layer_reg[0] / FDRE c_layer_reg[1] / FDRE c_layer_reg[2]
  q[0] <- q[0]   q[1] <- q[1]   q[2] <- q[2]
  q[3] <- <const0>  q[4] <- <const0>  ...  q[7] <- <const0>
```

Three flops. **The declared range `0 to C_LAY-1` became a width, and there is
no check anywhere.** DERIVED from that measured width: `-1` truncated to 3
bits is `111` = 7 = the last attention layer at the 9B shape.

Constant input (`ord` a `constant 0`, so the value folds):

```
ERROR: [Synth 8-11323] assigned value '-1' out of range
ERROR: [Synth 8-285] failed synthesizing module 'ordsynth0'
```

**So the sim/synthesis story is not "simulation catches it, synthesis does
not". It is: whether synthesis catches it depends entirely on whether the
offending value is statically derivable, and in `llama_top` it is not** -- the
ordinal comes out of descriptor memory. This refines TRACK DESC-MUT's finding
(a declared VHDL integer range is a bit width in synthesis and not a check)
rather than contradicting it: DESC-MUT's `S5`/`F3` are also run-time values.

### 5.7 M5 -- the fix moves no numbers

`sim/tb_llama_top.vhd` at `35e0ed0`, base tree from `git archive HEAD` against
the same tree plus the two fixed files:

| configuration | base | fixed |
|---|---|---|
| default (`BLOCKS=4 ATTN_INT=4`) | `R_X(0) = -12739 hash 38863` | **identical** |
| `-gBLOCKS=8 -gATTN_INT=2` | `R_X(0) = -13981 hash 81180` | **identical** |
| `-gBLOCKS=8 -gC_REAL=true -gATTN_HD=16` | `R_X(0) = -8793 hash 25008` | **identical** |

The third row was also measured at `d1d1e95` before HEAD moved, with the same
three numbers.

---

## 6. Teeth

Every mutation below was applied to the FIXED tree and run. Two of the four do
not bite, and they are the most useful rows.

| id | mutation | configuration | result |
|---|---|---|---|
| **T1** | `llama_top` B consumer re-derives again: `b_layer <= j_lay - (j_lay+1)/attn_interval` | `-gBLOCKS=8 -gATTN_INT=2` | **KILLED, by the hash only.** 53566 against 81180. `RESULT: PASS`, `rc=0`, zero properties fired |
| **T1'** | same mutant | **default gate row** | **DOES NOT BITE.** 38863, unchanged. At `BLOCKS=4 ATTN_INT=4` the GDN blocks are 0, 1, 2, where `gdn_ord(b) = b`, so the two conventions coincide |
| **T2** | `llama_top` C consumer re-derives again | `-gBLOCKS=8 -gC_REAL=true` | **KILLED.** `bound check failure at rtl/llama_top.vhd:3847` |
| **T2'** | same mutant | **default gate row** | **DOES NOT BITE.** 38863. `C_REAL` defaults false, so the entire `gcr` generate containing `c_layer` is not elaborated |
| **T3** | producer reverted: `llama_sched_pkg` stamps `blk mod 64` again, consumer fixed | `-gBLOCKS=8 -gATTN_INT=2` | **KILLED, legibly:** `llama_top: unit B was issued ordinal 4 but this shape has only 4 GDN layers` |
| **T4** | the inert `VEC_NORM` ordinal set to 0 | default | **DOES NOT BITE.** 38863. This is the resolution floor: nothing in the tree can see the ordinal on a non-B/C opcode, which is why the spec now fixes it by convention rather than leaving it to the generator |
| **P1** | the M1b probe run against a table stamped the other way | -- | passes, `rc=0`. The probe can return both verdicts |

**T1' and T2' together are the whole reason this survived.** The gate row that
exercises `llama_top` runs four blocks with attention stubbed. In that
configuration neither half of the defect is observable, by construction and not
by luck. The B half needs a shape where a GDN block sits after an attention
block; the C half needs `C_REAL`.

**T3's message is the reason the assert exists.** Before the assert was moved
ahead of the assignment, the same mutant died as a bare
`bound check failure at rtl/llama_top.vhd:3010`, which names a line and says
nothing about why. Both are kills; only one is a kill a reader can act on.

---

## 7. What changed

| file | change |
|---|---|
| `rtl/llama_top.vhd` | B adapter (`:2992` area) and C adapter (`:3799` area) take `job_ordinal` as the layer and derive nothing. `j_blk` renamed `j_lay` in both, because the variable no longer holds a block index. A guarded `assert` ahead of each assignment, marked SIMULATION ONLY |
| `sim/llama_sched_pkg.vhd` | `build_table` stamps `gdn_ord` on `B_JOB`, `attn_ord` on `C_JOB`, `blk mod 64` on a block norm, and **0 on the tail** (it was the only generator writing `blocks mod 64` there; `tools/dprog_oracle.py` called the tail "contested" and it is now settled on an inert byte in favour of the other two) |
| `docs/superpowers/specs/2026-08-24-transformer-sequencer-design.md` | §4.1 gains two NORMATIVE clauses and a record of this defect. §6.1 gains a per-opcode table for `0x19` and states that "not consumed" does not mean "free to vary" |
| `sim/seq_tbl_pkg.vhd` | comment only. It was always on the spec's side |
| `tools/gen_layer_program.py` | header no longer says the two VHDL generators disagree. `stamp_sched` emits `st.ordinal`, following the fixed VHDL it emulates |
| `tools/dprog_oracle.py` | `check_layer_index` docstring corrected: it contained both "both fields are inert in `llama_top`" and "`ordinal` is NOT inert on a B or C job" |

**No new `sim/tb_*.vhd`.** A new file becomes a gate row automatically, and the
standing check this defect needs already exists: `C5-ordinal-B` /
`C5-ordinal-C` in `tools/dprog_oracle.py`, run by `tools/dprog_check.sh`. The
probe used for M1/M1b is scratch and is described above in enough detail to
rebuild in ten minutes.

---

## 8. Measured and REJECTED -- do not retry

* **"Make the producers stamp the block index instead."** Cheaper on paper: two
  files instead of two, and the pair that already agreed is the pair the gate
  runs. Rejected on section 3's evidence, and specifically on point 5 -- it
  would require `rtl/seq_top_skel.vhd` to divide by a generic `attn_interval`
  to recover `b_w_sel`, which is the arithmetic spec 4.1 and 7.1 exist to keep
  out of D. Do not reopen this without new evidence about `seq_top_skel`.
* **"Add a `sim/tb_ordinal.vhd` gate row."** Rejected. `tools/dprog_oracle.py`
  already carries the check against a non-repo oracle, and a new bench file
  becomes a gate row for every concurrent track.
* **Observing the defect at the default `tb_llama_top` configuration.**
  MEASURED not possible: T1' and T2' both return the unchanged hash 38863. Do
  not try to reproduce this at `BLOCKS=4`; use `-gBLOCKS=8 -gATTN_INT=2` for
  the B half and `-gBLOCKS=8 -gC_REAL=true -gATTN_HD=16` for the C half.
* **Reading the `-1` as a crash on the card.** MEASURED: 0 synthesis errors and
  a 3-bit register. It is layer 7, silently.
* **Changing the block-norm `ordinal` to 0 to make the field uniform.**
  MEASURED as invisible (T4), and it would break `dprog_oracle`'s
  `C5-ordinal-NORM`, which is the only check that field has. Left as it is and
  written into the spec.

---

## 9. Measurement traps hit

* **HEAD moved twice under this track**, `78e2f5a` -> `d1d1e95` -> `35e0ed0`,
  and `sim/tb_llama_top.vhd` gained 205 lines from TRACK LOGITS in the second
  move. Every measurement was taken against a `git archive <sha>` tree rather
  than the working tree, and the whole M2/M3/M5 set was re-run at `35e0ed0`
  after the move. The hashes were unchanged, but that was not knowable in
  advance.
* **`tools/dprog_check.sh` reports `C1-count=1` at HEAD, and it is not this
  track's.** It is exactly the trap that script's own header documents: the
  oracle imports `tools/ref9b/seam_map.py`, which moved the graph from 504
  seams to 505. Confirmed by running the identical command inside a pristine
  `git archive 35e0ed0` tree with none of this track's changes present, where
  it also fails with `C1-count=1` alone. **Raised for the dispatcher in
  section 11, not fixed here** -- that file belongs to another track.
* **The assert fired after the assignment and was therefore invisible.** A
  signal's declared range aborts the process at the assignment, so an assert
  placed below it never runs. Both orders kill; only one prints a sentence.
  Caught by running T3, not by reading the code.
* **`ghdl -r` on `seq_tbl_pkg.build_table` needs `--max-stack-alloc=0`.** The
  505-descriptor table is 252 KB against the 128 KB default, and the failure is
  `declaration of a too large object` at elaboration, which reads like a
  malformed package rather than a flag.
* **`sleep` in a foreground shell is capped at two minutes here.** Two polling
  commands were killed at 2m and had to be re-issued as a bare status read.
  Nothing was lost; the runs were detached.

---

## 10. What was NOT determined

* **Whether any other consumer of `job_ordinal` exists outside `llama_top` and
  `seq_top_skel`.** `grep -n ordinal rtl/*.vhd` finds only those two and
  `seq_desc_fetch`, which forwards it. That is a grep, not a proof about a
  file that does not exist yet: `rtl/seq_top_skel.vhd` is a SKELETON, and the
  real D top has not been written.
* **Whether `b_w_sel` in the eventual real D is wired the way the skeleton
  wires it.** The decision in section 3 leans on that wiring. If the real D
  ever needs the block index too, the answer is a second field, not a second
  meaning for this one.
* **The value effect at the true 9B shape.** Every RTL measurement here is at
  4 or 8 blocks. `sim/tb_llama_top.vhd`'s own notes say a 32-block token does
  not yet pass P6 unanchored, so a 32-block value run would not have been
  interpretable.
* **Whether `-1` reaching `attn_kv_axi` as layer 7 produces a detectable
  symptom** rather than merely wrong numbers. Not investigated; the fix
  removes the case.

---

## 11. Raised for the dispatcher

1. **`tools/dprog_check.sh` is RED at HEAD on `C1-count`, and it is not this
   track's change.** Reproduced in a pristine `git archive 35e0ed0` tree.
   `tools/ref9b/seam_map.py` moved to 505 seams while the program writes 504
   regions. Either the program is missing a region write or the graph gained a
   seam that is not one. Owner is whoever holds `tools/ref9b/**`.
2. **`sim/llama_sched_pkg.vhd` was edited by this track and was listed as
   TRACK SCHED-FIX's file.** SCHED-FIX had landed (`78e2f5a`) and the file was
   clean in the working tree. The edit was unavoidable: fixing the consumer
   without it turns every `tb_llama_top` row red. One hunk, in `build_table`
   only.
3. **The brief's line numbers were stale by ten in one place.**
   `sim/seq_tbl_pkg.vhd`'s per-kind stamps are at `:386` and `:427`, not
   `:376`/`:417`. Everything else in the brief, including both figures,
   verified exactly.
