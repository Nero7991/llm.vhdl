# TRACK AJOBRUN -- the tool that can start a job on the card

**Date:** 2026-08-29
**Backlog row:** N1
**Files:** `hw/fk33/host/fk33_run_job.py` (new), `hw/fk33/gen_fk33_regs.py`,
`hw/fk33/host/fk33_regs.h` (generated from it)
**Hardware:** SQRL FK33 card 1 at `06:00.0`, `hw/fk33/bit/fk33_pcieep_eng.bit`
(22,568,402 B, `ed1ffe2`), 9B weight image `qwen35-9b-mv4i-noembd` resident
(4,487,442,432 B)
**Hardware touched by this track: NONE.** Measured, not asserted; see section 4.1.
**Commit:** `836b802`

---

## 1. The question, verbatim

> **NOTHING HAS VERIFIED WHAT THE CARD COMPUTES, AND NO TOOL IN THIS REPOSITORY
> CAN.** ... `hw/fk33/gen_pcieep.py` puts the engine's own register map at
> **`ENG_CTL_BASE = 0x00012000`** and its activation writer at
> `ENG_XW_BASE = 0x00013000`; `grep -rn '0x12000\|0x00012000\|ENG_CTL'
> hw/fk33/host/ server/ tools/` returns **nothing**. ... So: write the
> host-side runner that builds one `matvec_int4_desc_axi` descriptor, points it
> at a real `.mv4i` weight already resident in HBM, starts it at `0x12000`, and
> compares the result against `ref/matvec_int4.c`.

---

## 2. The answer, up front

**The runner exists: `hw/fk33/host/fk33_run_job.py`, with `plan`, `selfcheck`
and `run [--dry-run]`. Nothing in it has ever touched a card, and its verdict
is a per-row numeric comparison, not a completion flag.**

Three findings sit alongside it and matter more than the code:

1. **The descriptor bytes were NOT the gap, and neither was the oracle.**
   `tools/gen_mv4i_desc.py` already builds the 312-byte descriptor for a real
   tensor and `ref/mv_fk33_tr.c` already produces the activation vector and the
   expected `y` from `mv4i_matvec()`. Both are used verbatim. **The gap was
   exactly the register-level start/status path**, as TRACK BOARDAUDIT said, and
   that is all this track wrote. A third descriptor builder would have been the
   defect, not the deliverable.

2. **A NEW OPEN DEFECT, MEASURED: `tools/gen_mv4i_desc.py`'s two-rule base
   check agrees by coincidence of geometry on the entire 9B tensor set, and
   would falsely refuse anything else.** Section 5. That check is the tool's
   headline safety property -- the only thing standing between a host and the
   one descriptor corruption the gateware cannot see -- and on the files it has
   ever been run on it is not an independent check at all. NOT FIXED: that file
   is not this track's.

3. **The 9B set contains 48 tensors at M=32, K=4096, which are a one-tile job
   (`tiles=1`, `w_beats=128`).** That is the smallest job the card can be asked
   for, it needs 4096 activation writes and 32 result reads, and its answer is
   fully pinned by the oracle. It is the recommended first run.

**Nothing here is MEASURED about subsystem A.** Every claim this track can make
without a card is DERIVED at best, and the `--dry-run` model deliberately
replays the oracle, so a dry-run PASS is a statement about the tool's plumbing
and says so in its own output.

---

## 3. What was built, and what each piece is for

```
fk33_run_job.py plan       build the descriptor + the oracle, cross-check them
fk33_run_job.py selfcheck  32 mutations against a simulated card, no model
fk33_run_job.py run        the card   (--dry-run: simulated, opens no /dev)
```

### 3.1 The register map is scraped, not typed

`hw/fk33/host/fk33_regs.h` had no engine block. It is GENERATED, and its own
header says an edit there "changes what the host believes and not what the card
implements". So the block was added to `hw/fk33/gen_fk33_regs.py`, which now
pulls from three sources and **no document**:

| value | source | why that source |
|---|---|---|
| `ENG_CTL_BASE`, `ENG_XW_BASE` | `gen_pcieep.py` | it configures the block design |
| `ROWS_IF`/`BLK`/`NPORTS_*`/`AXI_DW`/`ADDR_W`/`MAXCOLS`/`DESC_MAXB`, `ENG_MAGIC` | `gen_fk33_engine.py` | it GENERATES `rtl/fk33_engine.vhd` |
| `MV4I_MAGIC`, the `EC_*` space | `rtl/matvec_int4_desc_pkg.vhd` | it is what the gateware and the descriptor generator both compute from |

`fk33_run_job.py` then **scrapes the generated header** rather than carrying its
own copy of the numbers, so `gen_fk33_regs.py --check` covers the Python too.

The sixteen register OFFSETS are the one thing that had to be transcribed by
hand (from `matvec_int4_desc_axi.vhd`'s `wrp`/`rdp` decodes, which switch on
`reg = addr[7:2]`). Two guards, and the difference between them is the point:

* `check_reg_table()` compares the transcription against the RTL's **header
  comment table**. That is two transcriptions of one decode agreeing. It bites
  on a shifted offset, a deleted row, a swapped pair and a changed access flag
  (evidence 4.3), and it is worth having, but it is not strong.
* **The strong check is on the card**: `ID`, `ADDR_CAP`, `CAPS` and
  `DESC_WORDS` are four constants at four different offsets, and all four
  reading their expected values cannot happen if the table is shifted.

### 3.2 The oracle is not a round trip

`ref/mv_fk33_tr` reaches the weight bytes through `get_widx()`/`get_scale()` in
C on the host; the card reaches the same bytes through 27 AXI masters into HBM.
Nothing is compared against itself.

The `100`-row job on `blk.11.attn_k.weight.mv4i` at `x_exp = 5` is **the exact
argv `sim/regress.sh:1428` gives that generator** for `sim/tb_matvec_fk33`, and
the file in `qwen35-9b-mv4i-noembd/` is byte-identical to the one the gate uses
(`cmp` clean). So a card/simulator disagreement on that job is maximally
informative: the RTL has already been shown to match the oracle on those exact
numbers.

There is exactly one round trip in the tool -- the descriptor read-back after
the DMA write -- and it is labelled in the output as proving the DMA moved
bytes, not that the bytes are right.

### 3.3 What refuses before anything is written

* the Python/C **cross-check**: 42 fields, including every one of the 27 bases,
  the beat counts and the codebook, between `gen_mv4i_desc.py`'s Python header
  parse and `mv4i_parse()`'s C one;
* the manifest's **`blake2b_128`** on the file being described (the only
  host-side check that can see the descriptor being pointed at bytes other than
  the ones it was built from -- and it checks the FILE, not what is resident:
  residency is `fk33_load_weights.py verify`'s job);
* `hbm_map.manifest_arena()` for the descriptor address -- **read, never
  re-derived**, per the ARENA-MANIFEST decision;
* `gen_mv4i_desc.rtl_would_reject()`, which restates `S_CHECK`'s conditions.

### 3.4 What refuses on the card, before GO

* the three identity constants (`FK33`, `MV4I`, `ENG1`), each with its two
  plausible wrong answers named (`0xFFFFFFFF` = BAR mapped with nothing
  answering, `0x00000000` = fabric in reset);
* `CAPS`/`ADDR_CAP`/`DESC_WORDS` against what the descriptor was built for;
* **`STATUS.err` already set.** `matvec_int4_desc_axi`'s `S_ERR` is left ONLY by
  reset, deliberately, so a further GO cannot re-arm it. The tool refuses and
  says the bitstream must be reloaded, rather than issuing a GO that cannot
  work;
* `STATUS.busy` already set;
* **`ENGX_STAT.HALT` live.** `rtl/fk33_engine.vhd` masks `CTRL` bit 0 while
  `compute_halt` is high, so a GO issued then is silently swallowed;
* the engine's own **`X_ADDR` counter** after the activation load: after `n_cols`
  writes it must read `n_cols`. That is a counter in the fabric, not a host
  variable, so it catches writes that did not land.

### 3.5 THERM-255 is handled as a first-class outcome, not an afterthought

The tool reads `THERM_STATUS` immediately before and immediately after the job.
If the trip counter moved, **the verdict is `INCONCLUSIVE` and never `PASS` or
`FAIL`**, because each trip halts the compute domain. It also names:

* a **saturated** counter at 255 before the run, because "it did not move"
  cannot then be observed -- clear it first;
* `THERM_STATUS` bit 30, the HBM-copies-disagree CDC sticky, which is what
  `2026-08-29_thermal-guard-255-trips.md` actually found set;
* bit 31 clear, meaning a bitstream with no guard at all.

**And `GO_BLOCKED` distinguishes the two failure shapes.** Without it, a GO
swallowed by the halt and a job that runs forever look identical from the host:
both are `STATUS` never reaching done. The wrapper's sticky bit is cleared
before GO and read after, so "the command was refused" and "the engine is slow"
are different reports.

---

## 4. Evidence

### 4.1 Nothing under /dev was opened

`/dev/xdma0_*` **exists on this machine and the card is live**, so this is
measured rather than asserted. `os.open` is the only way in -- `DevBar` and
`DevHbm` both use it -- so it was wrapped and every path run under the wrapper:

```
== plan          dev-open guard: 0 /dev opens attempted
== run --dry-run dev-open guard: 0 /dev opens attempted
== selfcheck     dev-open guard: 0 /dev opens attempted
== TEETH: the guard itself, on the real transport
                 dev-open guard: 1 /dev opens attempted
```

The last row is the guard's own teeth-check: it aborts *before* calling the real
`os.open`, so the card was not touched by it either.

### 4.2 `selfcheck` -- 32 rows, 0 disagreements, 5.6 s, no card and no model

```
synthetic   synth.mv4i (225280 bytes), M=96 K=4096, one-object manifest

mutation                       want           got            verdict
----------------------------------------------------------------------------
control (clean)                PASS           PASS           ok
BAR unmapped (all ones)        REFUSED        REFUSED        ok
fabric in reset (all zero)     REFUSED        REFUSED        ok
wrong engine ID                REFUSED        REFUSED        ok
no activation writer           REFUSED        REFUSED        ok
CAPS ROWS_IF 48 -> 4           REFUSED        REFUSED        ok
CAPS NPORTS_W 24 -> 4          REFUSED        REFUSED        ok
ADDR_CAP 40 -> 33              REFUSED        REFUSED        ok
DESC_WORDS 39 -> 17            REFUSED        REFUSED        ok
engine already in S_ERR        FAIL           FAIL           ok
EC_SHAPE from the gateware     FAIL           FAIL           ok
compute_halt high at GO        REFUSED        REFUSED        ok
X_ADDR does not advance        REFUSED        REFUSED        ok
job never completes            FAIL           FAIL           ok
one wrong mantissa             FAIL           FAIL           ok
wrong y_exp                    FAIL           FAIL           ok
trip counter moves in-job      INCONCLUSIVE   INCONCLUSIVE   ok
wrong answer AND a trip        INCONCLUSIVE   INCONCLUSIVE   ok
busy for several polls         PASS           PASS           ok
BEATS wrong (warn only)        PASS           PASS           ok
STARVED nonzero (warn)         PASS           PASS           ok

DESCRIPTOR-SIDE checks, run without a card at all:
control: the real plan         accepted       accepted       ok
--rows past M                  refused        refused        ok
--slot outside the arena       refused        refused        ok
--addr-w 33 (still fits)       accepted       accepted       ok
--addr-w 24 (arena needs 33)   refused        refused        ok
--out-mode 3 (> 2)             refused        refused        ok
manifest with no arena block   refused        refused        ok
arena base off by 8 (alignment) refused       refused        ok
weight base above ADDR_W       refused        refused        ok
manifest digest disagrees      refused        refused        ok
manifest digest agrees         accepted       accepted       ok

selfcheck   32 mutations, 17 expected-refusal rows bit, 0 rows disagreed
```

**ROWS THAT DO NOT BITE, under their own names.** These measure the resolution
floor and are the most valuable lines here:

| row | why it does not bite |
|---|---|
| `BEATS wrong (warn only)` | `BEATS` disagreeing with `tiles*nblk` is REPORTED and does not change the verdict. Deliberate: this track has not verified that counter's semantics against the RTL, and a check whose meaning is unverified must not turn a correct numeric result into a FAIL. |
| `STARVED nonzero (warn)` | same reason. |
| `busy for several polls` | a job taking several polls is normal, not a defect. It is a control that the poll loop terminates, not a tooth. |
| `--addr-w 33 (still fits)` | every address in the plan is under 2^33, so narrowing `ADDR_W` to 33 is genuinely not an error. Refusing it would be a false positive. The `--addr-w 24` row is the one with teeth; on the card `ADDR_CAP` is checked separately. |

### 4.3 The register-table check, mutated

```
control                      : agrees
STATUS offset 0x0C -> 0x10   : REFUSED
CYCLES row deleted           : REFUSED
Y_LO/Y_HI swapped            : REFUSED
CTRL access W -> R           : REFUSED
```

### 4.4 `load_regs` refuses rather than defaulting

```
control                      : loaded 79 names
drop FK33_ENG_ID_MAGIC       : REFUSED
drop FK33_ENGX_BASE          : REFUSED
drop FK33_ENG_CAPS           : REFUSED
drop FK33_THERM_TRIP         : REFUSED
missing header               : REFUSED
```

### 4.5 The descriptor decoded independently against the format doc, section 7

Written from `docs/2026-08-28_matvec-descriptor-format.md`, not from
`gen_mv4i_desc.py`. A reader, not a second builder.

```
descriptor: 312 bytes, 39 words
  opcode                 0                      == 0
  flags(cb_load)         4                      == 4
  n_rows                 32                     == 32
  n_cols                 4096                   == 4096
  w_exp                  9                      == 9
  out_shift              3                      == 3
  out_mode               0                      == 0
  nsub_w                 24                     == 24
  nsub_s                 3                      == 3
  src_region2            255                    == 255
  word3 pad              0                      == 0
  word7 pad              0                      == 0
  codebook  [-127,-104,-83,-65,-49,-35,-22,-10,1,13,25,38,53,69,89,113]  == oracle's
  ext0 index             35                     == 35
  ext_magic              1297495113             == 1297495113   (0x4D563449)
  ext_version            1                      == 1
  ext_flags              0                      == 0
  w_beats                128                    == 128
  s_beats                128                    == 128
  x_exp                  5                      == 5
  ext2 pad               0                      == 0
  ext3 pad               0                      == 0
  tiles*nblk             128                    == 128
  GRP                    1                      == 1
  s_beats rule           128                    == 128
  bases 4KB-aligned: True  inside ADDR_W: True
```

### 4.5b It runs from a clean `git archive`, not just from this working tree

`selfcheck` needs `cc` and the repository and nothing else -- no model set, no
card. Checked against the commit itself rather than the tree it was written in,
because a tool that only works where it was written is how a gate row rots:

```
$ git archive 836b8025b5aa52dc69e909772dba8ed1866fe0e0 | tar -x -C <clean dir>
$ python3 hw/fk33/gen_fk33_regs.py --check
fk33_regs.h is in step with gen_pcieep.py
$ python3 hw/fk33/host/fk33_run_job.py selfcheck
selfcheck   32 mutations, 17 expected-refusal rows bit, 0 rows disagreed
clean-archive selfcheck rc=0
```

### 4.6 The two candidate first jobs, planned and dry-run

```
tensor      blk.0.ssm_alpha.weight.mv4i
shape       M=32 K=4096   job n_rows=32 n_cols=4096  tiles=1 nb=128
geometry    ROWS_IF=48 AXI_DW=256 BLOCK=32 GRP=1 nsub_w=24 nsub_s=3
numeric     w_exp=9 out_shift=3 x_exp=5 out_mode=0 cb_load=True
beats       w_beats=128 s_beats=128
weights     hbm_base=0xE31E2000  w_base[0]=0xE31E3000  s_base[0]=0xE31FB000
descriptor  39 words / 312 bytes -> HBM 0x1FFADD000 (arena 0x1FFADD000 + 159744 B)
image       blake2b_128 ... matches the manifest's
            y_exp=6 sat_event=0, 32 expected mantissas
cross-check 42 of 42 fields agree between gen_mv4i_desc.py (Python) and mv_fk33_tr (C)
plan        consistent

tensor      blk.11.attn_k.weight.mv4i
shape       M=1024 K=4096   job n_rows=100 n_cols=4096  tiles=3 nb=128
beats       w_beats=384 s_beats=384
image       blake2b_128 e21ef237a77081a93e4457f93808b317 matches the manifest's
cross-check 42 of 42 fields agree
```

Dry-run of both, with the model replaying the oracle:

```
result      read 32 of 32 rows, compared 32 of 32 against ref/matvec_int4.c, 0 differ
            y_exp card=6 oracle=6
VERDICT     PASS -- ... DRY RUN.  This is a statement about this tool, not about any FPGA.

result      read 100 of 100 rows, compared 100 of 100 against ref/matvec_int4.c, 0 differ
```

---

## 5. THE NEW OPEN DEFECT -- `gen_mv4i_desc.py`'s second base rule

**MEASURED. NOT FIXED HERE: `tools/gen_mv4i_desc.py` is not this track's file.**

That tool's stated headline property is that it computes every base **twice**,
by rules that share no code, and refuses to emit if they disagree -- because
"a base is the one field whose corruption the gateware cannot see". Rule 1 is
the file's own offset table at `0x38`. Rule 2 is `sub_offsets_from_layout()`,
which strides by `h.sub_bytes()` = `tiles * nb * port_b`.

**Both packers pad every sub-region to 4 KB and rule 2 does not.**

```
ref/matvec_int4.c:474     sub_pad = align4k((size_t)tiles * NB * port_b);
tools/pack_int4.py:477    sub_sz  = align4k(tiles * NB * port_b)
tools/pack_int4.py:482    scl_sub_sz = align4k(nsuper * port_b)     <- its OWN stride
tools/gen_mv4i_desc.py    stride = h.sub_bytes()                    <- neither
```

`pack_int4.py` further gives the SCALE sub-regions a separate stride, which
differs from the weight stride whenever `GRP != 1`; rule 2 uses one stride for
both.

Measured on a synthetic image from `ref/matvec_int4.c --emit` at M=96, K=128:

```
M=96 K=128 nb=4 tiles=2 port_b=32 -> sub_bytes()=256, 4 KB-aligned=False
rule 1 (file offset table) w[0:2]=[4096, 8192]
rule 2 (layout)            w[0:2]=[4096, 4352]
DescError: the file's offset table and spec 6.5a's layout DISAGREE
```

**Why nobody has hit it, and why that is the bad part.** At the FK33 geometry
`GRP = 1`, and every tensor in the 9B set has `K` in `{4096, 12288}`, so `nb` is
128 or 384 and `tiles * nb * port_b` is always an exact multiple of 4096. Rule 2
therefore agrees with rule 1 **by coincidence of geometry** on every file it has
ever been run on.

So on this tensor set the two-rule check is not an independent check at all, and
on any tensor whose sub-region size is not already 4 KB-aligned it **refuses a
correct file**. This is the project's standing failure shape -- a per-unit
evidence class that is structurally present and jointly compatible with the
thing it claims to exclude -- reproduced in the one check specifically built to
exclude it.

The fix is one `align4k` on the weight stride plus a separate
`align4k(nsuper * port_b)` for the scale stride, mirroring `pack_int4.py`. It is
NOT applied here. `fk33_run_job.py selfcheck` carries `layout_rule_probe()`,
which **measures and prints this without asserting on it**, so the row flips to
"AGREE -- the defect below appears to have been fixed" when someone fixes it
rather than turning red.

Consequence for this track: `selfcheck`'s synthetic image is `K = 4096`, not a
smaller shape. That is a workaround for this defect, recorded in the code at the
`--sc-k` argument so nobody "simplifies" it back.

---

## 6. Measured and REJECTED -- do not retry

| thing | why it was rejected, with the number |
|---|---|
| **Writing a third descriptor builder.** | `tools/gen_mv4i_desc.py` already emits the 312-byte image for a real tensor, computes the bases by two rules, and predicts every `S_CHECK` condition. The brief warned about this and it was correct. **The gap was the register path and only the register path.** |
| **Writing a y oracle.** | `ref/mv_fk33_tr.c` already emits the activation vector, `YMANT` per row, `YEXP` and `SATEV` from `mv4i_matvec()`, and `sim/tb_matvec_fk33` already passes against it. Building 6 ms. |
| **Adding a CLI mode to `ref/matvec_int4.c`.** | Unnecessary once `mv_fk33_tr` was found, and outside this track's ownership. Its own `crosscheck` mode is not usable as this oracle in any case: it fixes `x_exp = 0`, uses the whole `M`, and prints only `mant_sum`, not per-row values. |
| **Hand-editing `hw/fk33/host/fk33_regs.h`.** | It is GENERATED, and its own header records a case where a real fix was hand-added to a generated file and "every build silently deleted it". `gen_fk33_regs.py --check` would have gone red on the next run. |
| **Typing the register constants into the Python.** | That recreates exactly the divergence `fk33_regs.h` exists to prevent, and `--check` cannot see a Python copy. The tool scrapes the generated header instead; a missing name raises. |
| **Scraping the register OFFSETS out of the RTL decode.** | The decode is two `case` statements on integers in two processes. A regex over it is fragile in the direction that fails silently. Transcribed instead, guarded by the RTL's comment table (weak, stated as weak) and by four card-side constants at four offsets (strong). |
| **Adding a `sim/regress.sh` gate row for `selfcheck`.** | 5.6 s, and it would be a genuinely good gate row. **Not done, deliberately.** `regress.sh` is SHARED, three tracks are running, adding a row that a clean `git archive` CAN run raises the archive ceiling and forces a `BASELINE_PASS` bump from 93 -- and `BASELINE_PASS` is the exact landmine GATEHYGIENE found had been printing `REGRESSION: FAIL` for every track since `e788a0e`. Editing a shared file to change a shared counter while three tracks run is not worth a gate row. The row for whoever next owns it is in section 8. |
| **A single "did it work" boolean.** | The verdict space is four values -- `PASS`, `FAIL`, `INCONCLUSIVE`, `REFUSED` -- because on this card a stall with a moved trip counter is genuinely none of the other three. Collapsing `INCONCLUSIVE` into `FAIL` is how THERM-255 gets attributed to subsystem A. |

---

## 7. Measurement traps hit, including my own

1. **`SimBar` was constructed without the oracle and the first dry run printed
   `FAIL -- 32 of 32 mantissas differ`.** Every card-side number was 0. This is
   the most useful trap of the session: the tool's *failure* path was exercised
   before its success path, and it printed exactly the right thing for what it
   was given. Had the wiring bug been in the opposite direction -- a comparator
   that skipped the loop -- it would have printed PASS. **Which direction a
   plumbing bug fails in is luck; that is why the mutation table exists.**

2. **`rc=0` from a command whose output went through `| tail`.** The pipeline's
   status is `tail`'s. Two of the first three "successful" runs here were
   reported by `tail`. Every rc in section 4 was taken by redirecting to a file
   and reading `$?` from the interpreter itself.

3. **`hbm_base_for()` returns a 3-tuple, not an int**, and Python concatenated
   the tuple instead of raising a type error at the call site. It surfaced 30
   lines later inside `gen_mv4i_desc.py`.

4. **`FK33_HBM_TOP` is spelled `0x200000000ull`.** The first `#define` regex
   allowed `u?` and silently skipped it, and `load_regs()` then reported it
   missing -- which was the *correct* behaviour and is why the bug took one
   minute rather than an afternoon. A regex that had defaulted it to 0 would
   have made every HBM write "run past the top" instead.

5. **`--addr-w 33` was written into the teeth table as an expected refusal and
   was not one.** The expectation was wrong, not the check: every address in the
   plan fits under 2^33. It is kept in the table as an expected *acceptance*,
   because a row that documents where a check correctly does not fire is worth
   as much as one that documents where it does.

6. **A `%` inside a Python string inside a shell heredoc.** Escaped it as `%%`
   out of habit for a quoted heredoc that does no interpolation, twice.

---

## 8. Precise command list for the dispatcher, at the bench

**Every command below is Oren's. No agent runs any of them.**
Run from the repository root. If any step prints something other than what is
listed, stop and read the diagnostic -- each one names its own cause.

### Step 0 -- group membership (this is a process property, not an account one)

```bash
id -nG | tr ' ' '\n' | grep -x fk33 || echo "THIS SHELL is not in fk33"
getent group fk33
```
If the shell is not in the group but the account is, prefix every later command
with `sg fk33 -c '...'`. The tool gives this diagnostic itself on `EACCES`
rather than an opaque permission error, but seeing it up front is cheaper.

### Step 1 -- no card needed, and it should be run first anyway

```bash
python3 hw/fk33/gen_fk33_regs.py --check
python3 hw/fk33/host/fk33_run_job.py selfcheck
```
Expect `fk33_regs.h is in step with gen_pcieep.py`, then
`selfcheck   32 mutations, 17 expected-refusal rows bit, 0 rows disagreed`,
rc 0, about 6 s.
*Failure:* any nonzero "rows disagreed" means the checking itself is broken and
nothing downstream is worth running.

### Step 2 -- the plan, still no card

```bash
python3 hw/fk33/host/fk33_run_job.py plan \
  --mv4i /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/blk.0.ssm_alpha.weight.mv4i \
  --rows 32
```
Expect `cross-check 42 of 42 fields agree`, `image ... matches the manifest's`,
`plan consistent`, rc 0.
*Failure:* `DISAGREE` on any field means the Python and C readings of the
`.mv4i` header differ, which is a packer or a tool defect, not a card one.

### Step 3 -- clear the thermal trip counter, then WAIT

```bash
python3 hw/fk33/host/fk33ctl.py thermal          # note the trip count first
python3 hw/fk33/host/fk33ctl.py thermal --clear
sleep 600
python3 hw/fk33/host/fk33ctl.py thermal
```
**The ten-minute wait is not optional and it is the measurement.** THERM-255
found roughly one trip every three minutes; twelve consecutive clean five-second
samples proved nothing. If the counter is above 0 after ten minutes, the guard
is tripping in THIS bitstream too, and every result below is `INCONCLUSIVE` by
construction -- record the count and stop, because that is itself the finding.
Note the counter SATURATES at 255: a run that starts at 255 can never show
movement.

`--clear` is `fk33ctl.py`'s own flag (`hw/fk33/host/fk33ctl.py:648`) and its
help says it clears the trip latch, the cause and the trip count, does NOT clear
the peak-hold, and does NOT release a halt the live sensors still justify. That
last clause matters: if `--clear` does not make `HALT` go away, the sensors are
the reason and this is not THERM-255.

### Step 4 -- the smallest job. THIS IS THE ANSWER TO N1.

```bash
python3 hw/fk33/host/fk33_run_job.py run \
  --mv4i /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/blk.0.ssm_alpha.weight.mv4i \
  --rows 32 --slot 0
```

32 rows, 4096 columns, one tile, `w_beats = 128`. 4096 activation writes and 32
result reads over MMIO, so expect a few tens of milliseconds of transfer.

**What it prints if it works** (rc 0):

```
identity    FK33 0x464B3333 | MV4I 0x4D563449 | ENG1 0x454E4731
caps        NPORTS_W=24 NPORTS_S=3 ROWS_IF=48 AXI_DW=256 ADDR_W=40 DESC_WORDS=39
thermal     STATUS=0x8....... trips=0 cause=0 trip_cause=0 temps=0x........
descriptor  312 bytes written to 0x1FFADD000 and read back identical
activations 4096 elements written in 0.0X s; the engine's own X_ADDR counter agrees (4096)
job         STATUS=0x00000001 done=1 busy=0 err=0 err_code=0x0 (EC_NONE) after N polls
thermal     STATUS=0x8....... trips=0 (was 0)
counters    CYCLES=... BEATS=128 STARVED=... (expected BEATS = tiles*nblk = 128)
result      read 32 of 32 rows, compared 32 of 32 against ref/matvec_int4.c, 0 differ
            y_exp card=6 oracle=6

VERDICT     PASS -- 32 of 32 mantissas and y_exp are bit-identical to ref/matvec_int4.c
```

**The failure modes, and what each looks like:**

| what you see | what it means | rc |
|---|---|---|
| `identity register reads 0x00000000 ... The fabric is held in reset` | the bitstream is not configured, or is held in reset | 2 |
| `identity register reads 0xFFFFFFFF ... BAR is mapped with nothing answering` | the XDMA BAR is mapped but the fabric is not answering | 2 |
| `the engine's ID register ... reads 0x........, not 0x4D563449` | this bitstream is not `fk33_pcieep_eng.bit`, or `ENG_CTL_BASE` moved | 2 |
| `the activation writer's ID ... not 0x454E4731` | `fk33_engine.vhd`'s `s_axix` is missing or at another base | 2 |
| `CAPS = 0x........ decodes to {...}` | the bitstream was synthesised at a different geometry than the descriptor was built for. The gateware would answer `EC_GEOM`; this refuses first | 2 |
| `the engine is already in its STICKY error state` | a previous job was rejected. `S_ERR` is left only by RESET. **Reload the bitstream**; a further GO cannot clear it | 2 |
| `compute_halt is asserted RIGHT NOW` | THERM-255 is live at this instant. Do not retry in a loop; go back to step 3 | 2 |
| `GO_BLOCKED is set: the thermal guard REFUSED the GO` | the halt went high between the check and the write. The job never started. Not a subsystem-A result | 2 |
| `after writing 4096 activation elements the engine's own X_ADDR counter reads N` | MMIO writes were dropped. The vector the array would use is not the vector the oracle used | 2 |
| `err_code=0x9 (EC_GEOM)` / `0xA (EC_MAGIC)` / `0xF (EC_SHAPE)` etc. | the gateware refused the descriptor before starting. The tool prints the code, its name, what it means and `ERR_INFO`'s word index | 1 |
| `the job never completed: N polls over T s` | the array starved, or the descriptor fetch hung. `WDOG_LIMIT` covers the FETCH only | 1 |
| `VERDICT INCONCLUSIVE ... the thermal trip counter moved` | **not** a subsystem-A result either way. Repeat step 3 | 3 |
| `VERDICT FAIL -- k of 32 mantissas differ` | **this is the interesting one.** The card computed and got a different number. Record the row indices and the two values; the per-row dump is in the output | 1 |

### Step 5 -- the job the simulator has already passed

```bash
python3 hw/fk33/host/fk33_run_job.py run \
  --mv4i /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/blk.11.attn_k.weight.mv4i \
  --rows 100 --slot 1
```

Same tensor, same `n_rows`, same `x_exp` and the same oracle seed that
`sim/regress.sh:1428` feeds `sim/tb_matvec_fk33`, and the file is byte-identical
to the gate's. Three tiles, 44 pad rows in the last one, `w_beats = 384`. If
step 4 passes and this fails, the difference is multi-tile or pad-row handling.
Expect `read 100 of 100 rows, compared 100 of 100 ... 0 differ`, `y_exp card=6`.

### Step 6 -- read the counter one more time, whatever happened

```bash
python3 hw/fk33/host/fk33ctl.py thermal
```
The tool already reads it either side of the job; this is the independent look,
and it is what turns "the trips did not move during the job" into a statement
about the window rather than about the poll.

### If anything above should be re-run

`--slot N` picks a different arena slot (311 available, stride 512), so a
re-run never has to reuse a slot. `--seed` and `--xamp` change the oracle's
activation vector, which is the cheapest way to tell a real arithmetic defect
from a lucky vector: **a wrong answer that survives a change of seed is a
defect; one that does not is a saturation or a range problem.**

---

## 9. Open, not answered by this track

* **Whether the card computes anything correctly.** That is step 4 and it needs
  the bench. Everything this track produced is DERIVED.
* **Whether the thermal guard trips in `fk33_pcieep_eng.bit`.** THERM-255 was
  measured on `fk33_pcieep_therm.bit`, a different bitstream. Step 3 is the
  measurement and it has not been taken.
* **`BEATS` and `STARVED` semantics.** Reported, never asserted on. `BEATS`
  *should* be `tiles*nblk`; that this track did not verify the counter against
  the RTL is why a disagreement is a warning and not a verdict.
* **`gen_mv4i_desc.py`'s rule 2** (section 5). Not this track's file.
* **A `sim/regress.sh` gate row for `selfcheck`.** Deliberately not added
  (section 6). The row for whoever next owns that file, and it needs only `cc`
  and the repository -- no model set:
  `hw/fk33/host/fk33_run_job.py selfcheck`, PASS on rc 0, ~6 s, and it raises
  the clean-`git archive` ceiling by one so `BASELINE_PASS` goes 93 -> 94.
* **The activation path is host-driven and always will be in this bitstream.**
  `x` arrives one element per MMIO write. That is fine for one job and is not a
  path to a token: at 4096 elements per matvec and ~500 matvecs per token it is
  two million MMIO writes. Whatever N3 composes will need `x` to come from the
  previous stage, which is what the port is for.
* **Multi-job sequencing.** One descriptor, one GO, one result read. Nothing
  here chains jobs, and `S_ERR`'s reset-only exit means a chained runner has to
  decide what to do about a rejected descriptor mid-sequence.
