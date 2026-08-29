# The schedule that fails an independent oracle: which of the 2,401 are real

**Date:** 2026-08-29. Branch `fpga`, HEAD `98755cb` at dispatch.
**Track:** SCHED-FIX.
**Packed set:** `/mnt/storage/llama-models/qwen35-9b-mv4i-qkvpad/`
(`ROWS_IF = 48`, `AXI_DW = 256`, `nports_w = 24`, `n_scale_sub = 3`).
**No hardware was touched.** No `xsdb`, `hw_server`, `vivado`, nothing under
`hw/fk33/`, nothing opening `/dev/xdma*`. Two FK33 cards were attached and a
place-and-route was running throughout; every measurement here is GHDL or
Python.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

> TRACK D-PROG ... ran the same oracle against `--stamp sched`, which is
> byte-identical to `sim/llama_sched_pkg.vhd`, the table `llama_top` actually
> executes. That FAILS 2,401 times:
>   - 311 `w_exp` wrong
>   - 253 `out_shift` wrong
>   - `nsub_w = 29` on EVERY step, **a value the FK33's A wrapper refuses with
>     `ERR_GEOM`**
>
> So the numbers the shipping design would drive into subsystem A are wrong,
> and at least one of them is not merely wrong but actively rejected by the
> hardware wrapper.
>
> 1. Confirm or refute that finding independently.
> 2. If confirmed, fix the source so the executed schedule carries the right
>    `w_exp`, `out_shift` and `nsub_w`.
> 3. Make the oracle a standing check.
> 4. Determine whether `nsub_w = 29` would really have been refused on the
>    card, and say how that was never noticed.

---

## 2. The answer, up front

**The 2,401 reproduce exactly, and they are three different things, only one of
which is a defect.**

* **`nsub_w = 29` / `nsub_s = 4` is a real defect and is FIXED.** Both VHDL
  generators wrote the superseded `ROWS_IF = 58` port budget into descriptor
  word 3. The build has run at `NPORTS_W = 24`, `NPORTS_S = 3` since the
  geometry settled at `ROWS_IF = 48`, and
  `rtl/matvec_int4_desc_axi.vhd:695-698` refuses any other value with
  **`EC_GEOM` (0x9), `err_info = 3`, before `start`** -- MEASURED here with the
  RTL as judge. Both packages now take the counts from
  `seq_tbl_pkg.A_NPORTS_W` / `A_NPORTS_S`, and three independent checks hold
  them there.

* **`w_exp` and `out_shift` are NOT a defect in those packages and must not be
  "fixed".** They are index-derived stimulus on purpose, the packages say so
  with measured reasons, and `sim/llama_sched_pkg.vhd` emits at an **arbitrary
  shape** where no packed tensor exists to take a value from. What was missing
  was any statement that these tables are not the program; both headers now
  carry one.

* **`ordinal` is a SECOND real defect, newly found here, and it is RAISED
  rather than fixed** because it is a decision about a field's meaning that
  touches three other tracks' files. `rtl/llama_top.vhd` reads `ordinal` as the
  BLOCK index; `sim/seq_tbl_pkg.vhd` and `tools/gen_layer_program.py` stamp the
  PER-KIND layer ordinal. **DERIVED: driving the manifest-stamped program into
  `llama_top` addresses the wrong layer on 29 of 32 blocks, and computes
  `c_layer = -1` on blocks 3, 7 and 11**, which is out of range for
  `integer range 0 to C_LAY-1`. See section 7.

**The brief's framing needs two corrections and they matter (section 3):
`sim/llama_sched_pkg.vhd` is NOT "the table `llama_top` actually executes" in
any shipping sense, and nothing on the card has ever read a D header.** The
defect was real; the phrase "the shipping design" was not.

**MEASURED, `tools/dprog_check.sh` against `HEAD:tools/ref9b/seam_map.py`:**

```
=== PROGRAM: --stamp manifest, must PASS ===============================
dprog_oracle: 505 steps, 39330 checks, 0 FAIL
DPROG_ORACLE: PASS

=== CONTROL: --stamp sched, must FAIL =================================
  by check: C4-outshift=253, C4-wexp=311, C5-ordinal-B=21, C5-ordinal-C=8, C8-hdr=564
DPROG_ORACLE: FAIL
dprog_check: control FAILED as required.

DPROG_CHECK: PASS
```

2,401 before, 1,157 after. The 1,244 that went are the 622 `nsub` failures and
the 622 they contributed to the `C8-hdr` aggregate.

---

## 3. Corrections to the brief

Every one was checked against the repository rather than reasoned about.

**(a) `sim/llama_sched_pkg.vhd` is not "the table `llama_top` actually
executes", and there is no shipping design that executes it.** It lives in
`sim/`, and MEASURED with `grep`, its only consumer is `sim/tb_llama_top.vhd`
(`:484`, `constant TBL : sched_tbl_t := build_table(SHAPE)`). Its own header
says it emits at an ARBITRARY shape and that "what is NOT preserved is the
element counts". `rtl/llama_top.vhd:155-157` states, and `grep -rn llama_top hw/`
confirms, that **that file is in no synthesis flow at all**. The FK33 bitstream
is `hw/fk33/rtl/fk33_engine.vhd`, which wraps `rtl/matvec_int4_desc_axi.vhd`
and contains **subsystem A only** -- there is no subsystem D on the card, so no
D descriptor header has ever reached hardware.

This is not a quibble that shrinks the finding. It is the reason the finding
was invisible: see section 6.

**(b) There is no `ERR_GEOM` in this tree.** The constant is `EC_GEOM`,
`x"9"`, `rtl/matvec_int4_desc_pkg.vhd:46`. The refusal it names is real and is
MEASURED in section 5; the name is not.

**(c) The 2,401 is right, and the brief lists 564 of it.** MEASURED breakdown
before the fix: `C4-outshift=253`, `C4-wexp=311`, `C5-ordinal-B=21`,
`C5-ordinal-C=8`, `C6-nsubs=311`, `C6-nsubw=311`, `C8-hdr=1186`. The brief
names `w_exp`, `out_shift` and `nsub_w` and omits `nsub_s`, the 29 `ordinal`
failures -- which turned out to be the most interesting rows in the table --
and the `C8-hdr` aggregate.

**(d) D-PROG's two carried-forward corrections both hold.** `token_embd.weight`
takes zero descriptor jobs (MEASURED: no A job on it in the 505-step program),
and `output.weight`'s 15 windows at stride 17,376 are what
`tools/dprog_oracle.py` derives and prints.

**(e) D-PROG's `--stamp sched` transcription is faithful, which I did not
assume.** MEASURED: `tools/gen_layer_program.py --stamp sched` against what
GHDL elaborates from `sim/llama_sched_pkg.vhd` at `mk_shape(MODEL, 1)` --
**0 word mismatches of 4,040**. So the 2,401 is a statement about the VHDL and
not about a Python re-implementation of it. This mattered: the brief's own rule
is that an agreement check against a transcription is not an oracle, and the
transcription had to be shown faithful before its failures could be believed.

---

## 4. The procedure, in the order it was run

Each step is there to remove one way the previous step could be wrong.

1. **Reproduce D-PROG's baseline**, so a later difference is mine.
   `gen_layer_program.py --token --manifest ... | dprog_oracle.py` ->
   505 steps, 39,330 checks, 0 FAIL. **Always pass `--manifest`**; the default
   is the pre-QKV-PAD set (D-PROG's trap, propagated and obeyed).
2. **Reproduce the `--stamp sched` failure.** 2,401, breakdown above.
3. **Stop trusting the transcription.** Wrote a scratch `dump_sched` entity
   that elaborates `seq_tbl_pkg.build_table` and
   `llama_sched_pkg.build_table(mk_shape(MODEL,1))` under GHDL and writes the
   raw 64-bit words to a file. This is the emitted bytes of the actual VHDL.
4. **Decode those bytes independently** (`analyse.py`, 40 lines, opcode
   numbering scraped from `rtl/llama_map_pkg.vhd`). This is where `nsub_w = 29`
   is confirmed without `gen_layer_program.py` in the loop at all.
5. **Byte-compare (3) against (2)** to establish the transcription is faithful.
6. **Find what the right value is, from an artefact no generator wrote:** the
   `nports_w` field at offset `0x1A` and `n_scale_sub` at `0x34` of a packed
   `.mv4i` header, read with `python3` off the raw file.
7. **Ask the RTL whether it would refuse.** Read
   `matvec_int4_desc_axi.vhd`'s `S_CHECK`, then made it judge: a descriptor
   carrying `(29, 4)` fed to the real entity.
8. **Ask why nothing noticed**, by finding every consumer of the field
   (section 6).
9. **Fix, then teeth-check every part of the fix** (section 8), including the
   mutations that do NOT bite.

---

## 5. The evidence, as raw output

### 5.1 The VHDL's own emitted bytes (MEASURED, GHDL)

Step 0 of `llama_sched_pkg.build_table(mk_shape(MODEL,1))`, before the fix:

```
0000000001000004 0000000000001000 00000000FFFFFFFE 00FF0004001D0000 ...
                                                     ^^^^ ^^^^
                                          nsub_s=0x0004   nsub_w=0x001D = 29
```

Decoded over the whole table, both packages, before the fix:

```
sched_bytes.txt: SCHED steps=505  A_JOBs=311
   nsub_w values seen (all steps): [29]   nsub_s: [4]
   on A_JOB: out_shift values [0, 1, 2, 3, 4]  w_exp values [-2, -1, 0, 1, 2]
   A_JOBs with out_shift illegal (<0 or >40): 0
   A_JOBs with nsub_w != 24 (FK33 NPORTS_W): 311
   A_JOBs with nsub_s != 3  (FK33 NPORTS_S): 311
seqtbl_bytes.txt: SEQTBL steps=505  A_JOBs=311
   nsub_w values seen (all steps): [0, 29]   nsub_s: [0, 4]
   on A_JOB: out_shift values [-11 .. 11]
   A_JOBs with out_shift illegal (<0 or >40): 146
   A_JOBs with nsub_w != 24 (FK33 NPORTS_W): 311
   A_JOBs with nsub_s != 3  (FK33 NPORTS_S): 311
```

After the fix, same command, same tree:

```
   nsub_w values seen (all steps): [24]   nsub_s: [3]        (llama_sched_pkg)
   nsub_w values seen (all steps): [0, 24]   nsub_s: [0, 3]  (seq_tbl_pkg)
```

Note the incidental finding in the `seq_tbl_pkg` row: **146 of its 311 A jobs
carry an `out_shift` outside the `[0, 40]` that `matvec_core.vhd:850-867`
accepts.** That is not a defect -- that table is walked by decoder benches and
never executed, and `llama_sched_pkg`'s header already explains why the
executed one uses `i mod 5` instead -- but it is now stated in
`seq_tbl_pkg`'s own header with the number, because "walked and never executed"
was a property nothing recorded and nothing enforces.

### 5.2 The right value, from the packed model's own bytes (MEASURED)

`blk.0.ffn_up.weight.mv4i`, first 0x40 bytes, magic `I4VM`:

```
0x10 09000000  w_exp = 9
0x14 03000000  out_shift = 3
0x18 3000      rows_if = 48
0x1A 1800      nports_w = 24        <-- the field
0x1C 2000      block = 32
0x1E 0001      axi_dw = 256
0x30 00108001  scale_offset
0x34 03000000  n_scale_sub = 3      <-- the field
0x38 0000...   the sub-region offset table
```

and `manifest.json`:

```
"geometry": { "rows_if": 48, "axi_dw": 256, "block": 32,
              "nports_w": 24, "n_scale_sub": 3, "axi_read_masters": 27,
              "qkv_segment_pad": true }
```

and `hw/fk33/rtl/fk33_engine.vhd:963-965`, which is what the card carries:

```
  constant ROWS_IF     : positive := 48;
  constant NPORTS_W    : positive := 24;
  constant NPORTS_S    : positive := 3;
```

### 5.3 Would the card have refused it? (MEASURED, RTL as judge)

`rtl/matvec_int4_desc_axi.vhd:695-698`, in `S_CHECK`, before `start`:

```vhdl
elsif to_integer(unsigned(dw(3)(31 downto 16))) /= NPORTS_W
   or to_integer(unsigned(dw(3)(47 downto 32))) /= NPORTS_S then
  err_code <= EC_GEOM;
  err_info <= std_logic_vector(to_unsigned(3, 16));
```

`dw(3)` is D's header word 3: the A descriptor is D's 64-byte header followed
by the base array and A's extension (`desc_ext0 = DESC_BASE0 + npw + nps`), so
the field the A wrapper checks and the field the schedule writes are **the same
bytes**. Fed to the real entity by `sim/tb_a_geom.vhd`:

```
tb_a_geom: nsub = (24,3) -> err_code 15 err_info 36
tb_a_geom: nsub_w+1 -> err_code 9 err_info 3
tb_a_geom: nsub_s+1 -> err_code 9 err_info 3
tb_a_geom: nsub = (29,4), the superseded ROWS_IF=58 counts -> err_code 9 err_info 3
tb_a_geom RESULT: PASS -- 10 checks, A_ROWS_IF = 48, A_MAXROWS_BFP = 17408,
                          A_NPORTS_W = 24 and A_NPORTS_S = 3 agree with the
                          descriptor plane's own generic defaults
```

`err_code 9` is `EC_GEOM`; `err_info 3` names descriptor word 3. `err_code 15`
on the correct pair is the descriptor being refused LATER for a base reason,
which is this bench's existing and deliberate design (its header explains why
"must NOT be refused at word N" is the assertable property and "must be
accepted" is not).

**So the answer to question 4 is: yes, and unconditionally.** Every one of the
311 A jobs would have been refused before `start`, in every `out_mode`, with a
driver polling `done` alone hanging rather than reading a wrong result. It is
the one item in the 2,401 that is not a wrong number but a non-starting job.

### 5.4 Where 29 and 4 came from (MEASURED, `grep` over `docs/`)

`docs/2026-08-27_weight-path-audit.md:459`:

> At `ROWS_IF = 58` and `AXI_DW = 256`, weights need 29 ports and there are 30

`docs/2026-08-27_budgets-at-the-measured-clock.md:943-944`:

> "at `ROWS_IF = 58` ... gives 29 lanes ... 33 total bases (29 weight + 4
> scale)". **33 lanes is 33 ports and only 30 exist.**

The geometry settled at `ROWS_IF = 48`, which gives 24 + 3 = 27 of the 30
available masters. The two numbers did not follow, and the comment attached to
them in `seq_tbl_pkg` ("D section 2.2-J") and in `llama_sched_pkg` ("the counts
are the real ones so the check is exercised") both asserted they had.

---

## 6. How it was never noticed

Seven independent reasons, each read out of the source rather than guessed.
Any one of them would have been enough on its own, which is why this is worth
recording as a shape rather than as an incident.

1. **`rtl/seq_desc_fetch.vhd:516` only RANGE-checks the field**
   (`> NSUB_MAX`, and `NSUB_MAX => 64` at `rtl/llama_top.vhd:1182`). 29 and 4
   are both under 64, so subsystem D accepted them and was right to.
2. **The base array past the header is not fetched yet**
   (`seq_desc_fetch.vhd:113-115`, "Fetching it is remaining work"), so nothing
   reads `nsub_w` for the purpose the field exists for.
3. **`rtl/llama_top.vhd:2280` binds `matvec_int4`, not
   `matvec_int4_desc_axi`.** The raw core has no descriptor plane and no `nsub`
   port at all, so **no `tb_llama_top*` gate row contains an `EC_GEOM` check**,
   and the integration bench that walks the offending table could not have
   noticed if it wanted to.
4. **`sim/tb_a_geom.vhd` -- the one bench built for exactly this defect class
   -- restated `NPW = 24` / `NPS = 3` as its own constants.** So for those two
   fields it was checking the DUT against its own restatement, which is the
   shape of a check that cannot fail. Its header names that shape and explains
   why `A_ROWS_IF` is taken from `seq_tbl_pkg` instead; the port counts were
   simply never brought into the same discipline.
5. **`tools/check_a_geometry.py` covered `ROWS_IF` and `MAXROWS_BFP` only.**
   The cross-language machinery existed and was pointed at two of the four
   numbers.
6. **There is no subsystem D on the card.** The FK33 bitstream wraps subsystem
   A alone, so no D header has ever been read by hardware and no run could have
   produced the `EC_GEOM` that was waiting.
7. **The two VHDL generators AGREED with each other.** Byte-identity between
   two independently written generators was the project's headline evidence for
   the descriptor plane, and it is worth exactly nothing about a number that
   was copied into both from the same superseded document. This is the
   verification-discipline point the tree already knows in the abstract,
   instantiated: *structure is not values*, and *an agreement check between two
   transcriptions of the same wrong source is not an oracle*.

---

## 7. RAISED, not fixed: `ordinal` means two different things

Found while classifying the 29 `C5-ordinal` failures, which the brief did not
mention. It is a decision rather than a fix, and it touches
`rtl/llama_top.vhd` (high-traffic, another track's today),
`tools/dprog_oracle.py` (D-PROG's, must not be rewritten) and the D format
spec, so it is written down rather than acted on.

**The disagreement, MEASURED by reading all three:**

| site | what it stamps on a B/C job |
|---|---|
| `sim/seq_tbl_pkg.vhd:376,417` | `ao` / `go`, the PER-KIND layer ordinal |
| `tools/gen_layer_program.py:353,400` | the same |
| `sim/llama_sched_pkg.vhd` | `blk mod 64`, the BLOCK index |
| `rtl/llama_top.vhd:2992-2997`, `:3799-3804` | reads it as the BLOCK index |

`llama_top` is unambiguous and says so in a comment:

```vhdl
j_blk  := to_integer(job_ordinal);
-- The GDN LAYER ORDINAL, not the block index.  `job_ordinal`
-- carries the block index; B's `layer` port and the exponent
-- capture are indexed by the GDN layer, which is the block index
-- minus the attention blocks before it.
b_layer  <= j_blk - (j_blk + 1) / SHAPE.attn_interval;
```

and symmetrically `c_layer <= (j_blk + 1) / SHAPE.attn_interval - 1`.

**DERIVED**, at the 9B shape (`blocks = 32`, `attn_interval = 4`,
`rtl/model_cfg_pkg.vhd:65`), applying `llama_top`'s conversion to the ordinal
`gen_layer_program.py` stamps:

```
blk kind  program ordinal   llama_top computes   correct
  0 GDN   0                 0                    0
  1 GDN   1                 1                    1
  2 GDN   2                 2                    2
  3 ATTN  0                 -1                   0    MISMATCH
  4 GDN   3                 2                    3    MISMATCH
  5 GDN   4                 3                    4    MISMATCH
 ...
 31 ATTN  7                 1                    7    MISMATCH
mismatching blocks: 29 of 32   negative c_layer: 3
```

`c_layer` is declared `integer range 0 to C_LAY-1` (`llama_top.vhd:3388`), so
`-1` is a bounds violation. Per the DESC-MUT finding already in the worklog,
**a declared VHDL integer range is a bit width in synthesis and not a check**,
so this is a simulation abort and a silent truncation on the card.

The reason it is invisible today is the same reason `nsub` was: the only bench
that drives `llama_top` uses `llama_sched_pkg`, which happens to be on
`llama_top`'s side of the disagreement.

**Which side is right is not obvious and is not mine to pick.** The house rule
says the RTL wins where a document and the RTL disagree, which points at the
BLOCK index; but `ordinal` is an 8-bit field and `blk mod 64` is already a
lossy encoding of it, and D's spec section on the field would have to be
reconciled either way. The two costs are asymmetric: changing the generators is
two lines and invalidates `dprog_oracle`'s `C5-ordinal-B/C`; changing
`llama_top` is two lines and invalidates nothing but needs that file, which two
other tracks edited today.

---

## 8. The fix, and every mutation run against it

Three checks now hold the pair down, at three different levels, because no one
of them is sufficient and the failure mode of each is different.

**(i) `sim/tb_a_geom.vhd`, the RTL as judge.** `NPW`/`NPS` now come from
`seq_tbl_pkg.A_NPORTS_W`/`A_NPORTS_S`, which sizes the descriptor plane's 27
port vectors, plus a four-descriptor behavioural bracket at `EC_GEOM`
including the historical `(29, 4)` by name. Existing gate row, **no new row and
no `BASELINE_PASS` change**.

**(ii) An elaboration read-back inside both `build_table` functions.** Not
`assert nsw = A_NPORTS_W`, which is a tautology one line below the assignment:
it decodes descriptor **word 3 of the finished table** and asserts the byte the
gateware will read. Fires in every bench that touches either table.

**(iii) `tools/check_a_geometry.py`**, extended from two numbers to four, with
a fifth site (`tools/gen_mv4i_desc.py`, which writes the field into every
packed header) and a guard that refuses a bare integer literal on either
generator's `mk_desc` emit path -- the one shape (ii) cannot catch.

Plus `tools/gen_layer_program.py` now **reads** `A_NPORTS_W` out of the VHDL
rather than restating it, because a literal there was a second copy of the
number that was wrong in the first place: while the packages said 29, that line
said 29 too, and the two agreeing proved nothing.

### Mutations that were KILLED

| # | mutation | judged by | result |
|---|---|---|---|
| M1 | `A_NPORTS_W` 24 -> 29 | `tb_a_geom` | KILLED, bound check at elaboration, `tb_a_geom.vhd:229` |
| M2 | `A_NPORTS_S` 3 -> 4 | `tb_a_geom` | KILLED, same |
| M3 | delete the `EC_GEOM` branch in `matvec_int4_desc_axi` | `tb_a_geom` | KILLED, 3 of 10 checks |
| M4 | delete only the `NPORTS_S` half of that branch | `tb_a_geom` | KILLED, 1 of 10 checks |
| M5 | `EC_GEOM`'s `err_info` 3 -> 4 | `tb_a_geom` | KILLED, 3 of 10 checks |
| M6 | literal `29` back into `seq_tbl_pkg.build_table`'s `nsw` | `tb_seq_tbl_shape` | KILLED at elaboration by the word-3 read-back |
| M7 | literal `29` back into `llama_sched_pkg`'s `mk_desc` call | any bench using the table | KILLED at elaboration by the word-3 read-back |
| T1 | `gen_mv4i_desc.py` `nports_w` 24 -> 29 | `check_a_geometry.py` | KILLED, `DISAGREEMENT on NPORTS_W: [24, 29]` |
| T2 | `fk33_engine.vhd` `NPORTS_S` 3 -> 4 | `check_a_geometry.py` | KILLED, `DISAGREEMENT on NPORTS_S: [3, 4]` |
| T5 | retype `A_NPORTS_W` `natural` -> `positive` | `check_a_geometry.py` | KILLED, `MISSING ... this check has gone blind` |
| T6 | rename `A_NPORTS_S` -> `A_NPORT_S` | `check_a_geometry.py` | KILLED, `MISSING` |
| T7 | `gen_fk33_engine.py` `NPORTS_W` 24 -> 29 | `check_a_geometry.py` | KILLED |
| T4 | replace `nsub_w => A_NPORTS_W` with the CORRECT literal `24` | `check_a_geometry.py` | KILLED, `LITERAL nsub in sim/llama_sched_pkg.vhd` |
| P1 | retype the scrape target so `gen_layer_program.py` cannot read it | the tool itself | KILLED, hard `SystemExit`, no silent default |
| C1 | delete `sched` from `STAMPS` so the control stamps `manifest` | `tools/dprog_check.sh` | KILLED, the directional control fires |

T4 is the one worth pausing on: it substitutes the **right** value as a
literal, and is still refused. A literal that is correct today is exactly the
state the tree was in before this, and is the thing that goes stale silently.

### Mutations that did NOT bite, under their own names

**These measure the resolution floor of the checks and are the most valuable
rows here.**

* **M6 / M7 against `tb_a_geom`.** Reintroducing a literal on either emit path
  is **NOT** caught by `tb_a_geom`, because that bench never calls
  `build_table` -- it judges the *constant*, not what the table writes. This is
  precisely why (ii) exists; M6 and M7 are killed by the read-back and by
  nothing else. Recorded because "the geometry bench covers it" would have been
  a plausible and wrong thing to believe.
* **T3, whitespace reformatting** (`constant A_NPORTS_W : natural :=24;`).
  `check_a_geometry.py` returns rc=0. This is **not a hole**: the patterns use
  `\s*` deliberately and are meant to survive reformatting. It is recorded
  because the file's own header claims a reformatted declaration goes blind and
  is reported as an error, and that claim is only true for a reformat that
  changes a *token* (T5, T6), not the spacing. The header's wording overstates
  its own fragility.
* **Nothing at all catches a wrong `NPORTS` reaching the CARD via a fourth
  language.** `hw/fk33/gen_pcieep.py` and the block design state port counts
  too; `check_a_geometry.py` reaches the two Python files that declare them by
  name and no further. The `hw/**` tree was out of scope for this track.

---

## 9. Measured and REJECTED -- do not retry

* **Do NOT "fix" `w_exp` / `out_shift` in `sim/llama_sched_pkg.vhd` or
  `sim/seq_tbl_pkg.vhd` to the manifest's values.** Three independent reasons,
  all already in those files or measured here:
  (a) `llama_sched_pkg` emits at an **arbitrary shape** -- a scaled sim shape
  has no packed tensor to take a value from, so there is nothing to take;
  (b) `rtl/llama_top.vhd:128-132` states A's weights **do not come from the
  descriptor** in that path, so the exponent qualifies a matvec over synthetic
  weights; (c) the packages document MEASURED reasons for the ranges they use
  -- `out_shift` outside `[0,40]` is an immediate `ERR_UNIT` from
  `matvec_core.vhd:850-867`, and a `w_exp` spread wider than about 4 made
  subsystem A publish `y_exp = 19` against a residual stream at 3, sixteen
  binary places apart, so the whole of A's and B's contribution vanished into
  the BFP alignment shift while every sequencing property still passed.
  Replacing them with per-tensor constants would make many steps share a value,
  which those files' headers already argue makes every check on the field
  vacuous. **The 1,157 residual failures of `--stamp sched` are the correct
  result and `tools/dprog_check.sh` asserts they stay.**

* **Do NOT add a new `sim/tb_*.vhd` for this.** It becomes a gate row
  automatically and moves `BASELINE_PASS`, which four tracks were editing the
  same day. Extending `tb_a_geom`, which already existed for this exact defect
  class, cost nothing and changed no counter. Its check count went 6 -> 10.

* **Do NOT read `nsub_w` as a schedule choice.** It is not "how many weight
  sub-regions this job uses". `S_CHECK` compares it for equality with the
  build's `NPORTS_W`, so the only legal value is the build's, and a job that
  wanted fewer would still have to say 24.

* **`--stamp sched` PASSING the oracle is a failure, not a success.** It is
  wired as a directional control in `tools/dprog_check.sh` for that reason. If
  a future change makes it pass, either the oracle lost its teeth or somebody
  turned a stimulus table into a program.

---

## 10. Measurement traps hit

* **A concurrent track's uncommitted file turned the oracle red for a reason
  that had nothing to do with this work.** `tools/dprog_check.sh` reported
  `FAIL C1-count: program writes 504 regions, llama.cpp's graph has 505 seams`
  on a program that had passed the same check ninety minutes earlier. The
  oracle imports `tools/ref9b/seam_map.py`, TRACK CAPTURE's file, which had
  been modified **two minutes before** (`ls -l` mtime 15:21, run at 15:23).
  Re-running against `git show HEAD:tools/ref9b/seam_map.py` gives
  `505 steps, 39330 checks, 0 FAIL`. The script now carries a note saying a
  lone `C1-count` failure is a `seam_map` question, not a program question.
  This is the worklog's "a full-gate run showing failures in files you cannot
  have touched is MACHINE CONTENTION" rule, in a form it does not currently
  cover: not contention for the machine, but a **cross-track dependency of an
  oracle on a live file**.

* **`cmd | tail` reports `tail`'s exit status**, so the first version of the
  directional control could never have fired -- it would have printed
  "control FAILED as required" for a control that passed. Caught only because
  the mutation C1 was run. A control that cannot fire is worse than no control,
  because it reads as evidence.

* **The first `--stamp sched` decode was of a Python transcription.** Believing
  it without the GHDL dump would have been the exact defect this track exists
  to fix, one level up. The transcription turned out to be faithful to all
  4,040 words, which is a credit to D-PROG's tool and not a reason it should
  have been assumed.

* **`ghdl -r` on `seq_tbl_pkg.build_table` needs `--max-stack-alloc=8192`.**
  The default 128 KB gives `declaration of a too large object (252 > ...)`,
  which reads like a source defect and is not.

---

## 11. What was NOT determined

* **Whether the `ordinal` disagreement should be fixed in the generators or in
  `llama_top`.** Section 7. Raised, with the arithmetic, for a decision.
* **Whether anything else in the D header has the same provenance problem.**
  `const_base`, `const_exp` and `flags` were not audited against an independent
  artefact; only the fields `dprog_oracle` checks were, and it does not claim
  to cover the header exhaustively.
* **Whether the 253-vs-311 split of `C4-outshift` against `C4-wexp` means
  anything.** 58 A jobs are checked for `w_exp` and not for `out_shift`; that
  is a property of the oracle's tensor lookup and was not chased, because both
  classes are expected to fail on a stimulus table.
* **Anything about the card.** No hardware was touched, so "the card would have
  refused it" is a statement about `rtl/matvec_int4_desc_axi.vhd` simulated
  with the FK33's generics, not a measurement on silicon. It is the strongest
  form available while the hardware boundary holds, and it is not the same
  thing.
* **`hw/**`.** Out of scope; `gen_pcieep.py` and the block design state port
  counts that `check_a_geometry.py` does not reach.
