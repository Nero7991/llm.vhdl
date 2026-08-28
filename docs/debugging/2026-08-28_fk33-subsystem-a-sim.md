# Subsystem A at the FK33 geometry, driven from a real .mv4i file

## 1. The question

Verbatim, 2026-08-28:

> Get subsystem A ready to run on the card, proven in simulation, without
> touching the card. [...] Identify the gap between the verified simulation
> configuration and what the FK33 shell would need (ROWS_IF=48, AXI_DW=256,
> reading real `.mv4i` bytes from an HBM-like AXI slave). [...] Produce a
> testbench that drives the real `matvec_int4` RTL at the FK33 configuration,
> from real bytes taken from an actual `.mv4i` file, and checks the result
> bit-exactly against `ref/matvec_int4.c`. [...] Deliberately break the RTL or
> the data, confirm your testbench FAILS, then revert.

Hardware/build context: **no board involved, and none touched.** GHDL 1.0.0
Dunoon, **mcode** backend (`ghdl -e` produces no binary; every run below is
`ghdl -r <entity>` directly). gcc with `-O2 -Wall -Wextra`, assertions ON.
Vivado not invoked. Repo `llama.vhdl` branch `fpga` at `674da7f`. Packed model
set `/mnt/storage/llama-models/qwen35-9b-mv4i/` (250 tensors, 4.71 GiB,
`manifest.json` geometry `rows_if 48 / axi_dw 256 / nports_w 24 /
n_scale_sub 3 / axi_read_masters 27`).

Two corrections to the premises the task was stated with, both found before any
edit:

* **The regression floor is 76, not 73.** `sim/regress.sh:351` read
  `BASELINE_PASS=76`, and a full run before any change of mine measured exactly
  76. The 73 in the task statement is three testbenches out of date.
* **`rtl/matvec_int4.vhd` is no longer fixed at `NPORTS_S = 1`.** Commit
  `e1cc1de` exposed the generic. What was still missing is what the note that
  came with it said was missing: *data* through it.

## 2. The answer

**The gap was exactly one thing: nothing had ever put DATA through
`matvec_int4` at 48/256.** Every part underneath was already general and
already checked, but each was checked in isolation and the seam between the
streamer's 24+3 sub-region reassembly and the array's row mapping had no test
at all. `sim/tb_matvec_fk33.vhd` closes it: the real `matvec_int4`, at
ROWS_IF=48 / NPORTS_W=24 / NPORTS_S=3 / AXI_DW=256 over **27 AXI read
masters**, fed the actual sub-region bytes of
`blk.11.attn_k.weight.mv4i` at the byte offsets that file's own 4 KB header
names, checked **bit-exactly** (full 64-bit result lanes, `y_exp`, sticky
`sat_event`, row count -- no tolerance anywhere) against `ref/matvec_int4.c`.
It passes, and five mutants show it has teeth.

**The measured complementarity is the load-bearing part.** The pre-existing
`sim/tb_matvec_int4.vhd` and this new bench each catch a mutant the other
CANNOT, and both were predicted before running:

| mutant (one line) | tb_matvec_int4 (4/128, NPS=1, GRP=2) | tb_matvec_fk33 (48/256, NPS=3, GRP=1) |
|---|---|---|
| M1 weight sub-region order reversed | **FAIL** rc=1 | **FAIL** rc=1 |
| M2 scale sub-region order reversed | **PASS**, silent | **FAIL** rc=1 |
| M3 scale chunk (GRP) order reversed | **FAIL** rc=1 | **PASS**, silent |

M2 is invisible at `n_scale_sub = 1` because reversing a one-element list is
the identity, and M3 is invisible at `GRP = 1` for the same reason. **Neither
bench alone covers the scale path**; keeping both is not redundancy.

**Step 5 was NOT done, and the reason is a real blocker, not time.** See
section 7.

## 3. The procedure that produced it

In this order, and the order mattered.

1. **Measure the baseline before touching anything.** Full `sim/regress.sh`,
   both suites: PASS 76. Do not take the floor from the task statement.
2. **Read the two prior notes' "open, not yet answered" sections before
   deciding what the gap is.** Both name it precisely
   (`2026-08-28_c-reference-general-axi-dw.md` section 7, first bullet), which
   is faster and more reliable than re-deriving it from the source.
3. **Check what the real files actually are** rather than assuming. All 250
   are `rows_if 48 / axi_dw 256`; the seven distinct shapes are
   `(M,K) = (32,4096), (1024,4096), (4096,4096), (8192,4096), (12288,4096),
   (4096,12288), (248320,4096)`. That decides the test case: the smallest file
   is `M = 32`, which at `ROWS_IF = 48` is **one tile**, so it cannot exercise
   the tile loop or a multi-burst read.
4. **Pick the case from the geometry, not from convenience.** `n_rows = 100`
   on the `M = 1024` file is `2*48 + 4`: three tiles, 44 pad rows in the last,
   and `3 * 128 = 384` beats per sub-region, which at `MAXB = 128` is three
   bursts and therefore exercises the address increment. `n_cols` is NOT
   subsettable and the generator refuses to try -- the block stride inside a
   sub-region is the FILE's `nb`, so a shorter `n_cols` would silently read
   the wrong beats.
5. **Dump the bytes, do not re-derive them.** `ref/mv_fk33_tr.c` copies the
   sub-region beats verbatim out of the file. A testbench that rebuilt them
   from spec 6.5a would agree with a wrong 6.5a just as happily; that is the
   same argument `sim/tb_matvec_int4.vhd`'s own header makes.
6. **Take the expected result through a DIFFERENT code path in the same
   reference.** `mv4i_matvec()` reaches those bytes through
   `get_widx()`/`get_scale()`, not through the raw dump. Double oracle, not
   round trip.
7. **Data mutants first, RTL mutants second.** The data mutants need no edit
   to the repo at all, so they can be run while a regression is in flight; the
   RTL mutants were applied to COPIES in a scratch tree and analysed into
   private GHDL libraries, so `rtl/weight_streamer.vhd` was never modified in
   the working tree at any point.
8. **Every mutant run against BOTH benches**, so the claim that the new one
   adds coverage is measured rather than argued.
9. `sim/regress.sh` full run as the gate, before and after.

What each control isolates:

* **`sim/tb_matvec_int4.vhd`, unchanged, in every mutant table** is the control
  for the new bench: it is the geometry that is already in a built, timing-
  closed bitstream (spec 14.4), so if a mutant moves it, something real broke.
* **The per-port address assertions in the slave** are the control for the
  descriptor: with one array per port, a base that pointed into the wrong
  sub-region would otherwise be served plausible bytes.
* **The `BASE_HI` high-half check** is the control for the 64-bit address path:
  the FK33 has 8 GB of HBM and a truncated base reads exactly the right bytes
  when the image is served per port, so only an explicit check sees the wrap.
* **M3 passing on the new bench** is the control for M2: it is what shows the
  two benches are not testing the same thing in two colours.

## 4. The evidence

### 4.1 The baseline, before any change

```
 suite sim   PASS 50   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 76   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 76 passing, matches the recorded floor of 76
 REGRESSION: PASS
```

### 4.2 The trace generator, on a real tensor

```
$ cc -O2 -Wall -Wextra -I ref -o mv_fk33_tr ref/mv_fk33_tr.c
$ ./mv_fk33_tr t100.txt \
    /mnt/storage/llama-models/qwen35-9b-mv4i/blk.11.attn_k.weight.mv4i 100
wrote t100.txt from .../blk.11.attn_k.weight.mv4i: ROWS_IF=48 NPORTS_W=24
  NPORTS_S=3 AXI_DW=256 GRP=1 n_rows=100 n_cols=4096 tiles=3 wbeats=384
  sbeats=384 y_exp=6 mant_sum=-69632 sat=0
```

The 27 sub-region bases it read out of the file's header, megabytes apart and
4 KB aligned, which is why the testbench keeps one array per port rather than
a flat image:

```
WSUB 0 4096      WSUB 8  724992    WSUB 16 1445888
WSUB 1 94208     WSUB 9  815104    WSUB 17 1536000
...              ...               WSUB 23 2076672
SSUB 0 2166784   SSUB 1 2256896    SSUB 2 2347008
WBEATS 384       SBEATS 384
```

### 4.3 The testbench, green

```
$ ghdl -r --std=08 -frelaxed --workdir=work tb_matvec_fk33 \
       --stop-time=50ms --stop-delta=1000000 --max-stack-alloc=0
tb_matvec_fk33.vhd:391:@205ns:(report note): loaded 10368 sub-region beats
  from mv_fk33_tr.txt
tb_matvec_fk33.vhd:456:@47875ns:(report note): FK33 geometry ROWS_IF=48
  AXI_DW=256 NPORTS_W=24 NPORTS_S=3 over 27 AXI masters: 100 rows compared,
  0 mismatches, y_exp=6
tb_matvec_fk33.vhd:472:@47875ns:(report note): subsystem A is bit-exact with
  ref/matvec_int4.c from the real .mv4i bytes up, at ROWS_IF=48 / AXI_DW=256
rc=0
```

10368 = 27 ports x 384 beats. Wall clock 9.8 s.

### 4.4 Teeth, DATA mutants (the trace, not the RTL)

**D1 -- transpose two weights.** One byte of one beat of one port: `95` -> `59`,
which swaps weights j=0 and j=1 of row 0 of tile 0 block 0 (6.5: j even is the
low nibble). This is the smallest mutation the format admits.

```
tb_matvec_fk33.vhd:417:(report error): END-TO-END MISMATCH r=0 got -1057 want -1073
tb_matvec_fk33.vhd:456:(report note): ... 100 rows compared, 1 mismatches ...
tb_matvec_fk33.vhd:468:(assertion failure): SUBSYSTEM A DIVERGES FROM
  ref/matvec_int4.c AT THE FK33 GEOMETRY
rc=1
```

Note it fails on **row 0 and only row 0**, which is exactly the row those two
weights belong to. A bench that failed everywhere on this would be telling you
less.

**D2 -- off-by-one the scale index.** Every scale-port beat renumbered down by
one, so the array sees block b's scales while consuming block b+1.

```
tb_matvec_fk33.vhd:417:(report error): END-TO-END MISMATCH r=0 got -453 want -1073
tb_matvec_fk33.vhd:417:(report error): END-TO-END MISMATCH r=1 got -2417 want -5036
tb_matvec_fk33.vhd:417:(report error): END-TO-END MISMATCH r=2 got 3948 want 7653
... (all 100 rows)
rc=1
```

### 4.5 Teeth, RTL mutants, each run against BOTH benches

Applied to a **copy** of `rtl/weight_streamer.vhd` in a scratch tree and
analysed into a private GHDL library. The repo file was never edited.

| id | one-line change |
|---|---|
| M1 | `w_data(...) <= qd(p)` -> `qd(NPORTS_W-1-p)` |
| M2 | `s_hold(...) <= qd(NPORTS_W+q)` -> `qd(NPORTS_W+NPORTS_S-1-q)` |
| M3 | `s_data <= s_hold((s_chunk+1)*SW-1 downto s_chunk*SW)` -> `s_hold((GRP-s_chunk)*SW-1 downto (GRP-1-s_chunk)*SW)` |

```
===== M1, tb_matvec_fk33 =====
END-TO-END MISMATCH r=0 got 3395 want -1073   (and r=1..99)          rc=1
===== M1, tb_matvec_int4 =====
ghdl-mcode:error: assertion failed ... tb_matvec_int4.vhd:354        rc=1

===== M2, tb_matvec_fk33 =====
END-TO-END MISMATCH r=0 got -4142 want -1073  (and r=1..99)          rc=1
===== M2, tb_matvec_int4 =====
(report note): end to end: 8 rows compared, 0 mismatches, y_exp=-2
(report note): subsystem A matches ref/matvec_int4.c from the packed bytes up
                                                                      rc=0
===== M3, tb_matvec_fk33 =====
(report note): ... 100 rows compared, 0 mismatches, y_exp=6
(report note): subsystem A is bit-exact with ref/matvec_int4.c ...    rc=0
===== M3, tb_matvec_int4 =====
ghdl-mcode:error: assertion failed ... tb_matvec_int4.vhd:354        rc=1
```

An unmutated control run of `tb_matvec_int4` in the same private library
reports `0 mismatches` and rc=0, so the M2 pass is a genuine miss and not a
broken harness.

### 4.6 Regression gate, after

Recorded in section 8.

## 5. Measured and REJECTED -- do not retry

**Generalising `sim/tb_matvec_int4.vhd` in place instead of adding a file.**
Rejected before starting. `AXI_DW` is a `constant` there, `NP` is `RI`, the
slave model serves 128-bit beats and the image is built as 128-bit words; the
prior note already calls making it general "a testbench rewrite, not a
generic". More to the point, section 4.5 shows that file is a **negative
control** for the new one -- M2 and M3 are only interesting because the two
benches disagree. Merging them would have destroyed the evidence.

**A flat, address-indexed image, as `tb_matvec_int4` uses.** Measured and
rejected on the real files: `blk.11.attn_k.weight.mv4i` is 2,437,120 bytes =
76,160 beats of 256 bits, of which the test reads 10,368. A flat memory is
7x the storage and, worse, it would **serve a wrong-sub-region read plausible
bytes**. One array per port lets the slave assert that port p addressed its own
region at the expected beat.

**Subsetting `n_cols`.** The beats of a sub-region run tile-major then block
with the block stride fixed by the FILE's `nb = ceil(K/32)`, so a prefix in
rows is contiguous but a prefix in columns is not. The generator refuses rather
than gathering; a gather would have put a second copy of the layout rule in the
testbench, which is the thing this whole file exists to avoid.

**`M = 32` tensors (`blk.*.ssm_alpha/beta`) as the test case**, despite being
the smallest at 112 KB. At `ROWS_IF = 48` that is ONE tile: no tile loop, and
`w_beats = 128` is exactly `MAXB`, so the burst generator issues a single burst
and the address increment is never exercised. It would have looked like a
cheaper test and tested less.

**Signals for the image and the activation vector.** 27 x 384 x 256 is 2.65 M
scalars; as a signal that is 2.65 M drivers plus one delta cycle per loaded
line. Non-protected shared variables under `-frelaxed` (which
`sim/regress.sh` passes unconditionally to both `-a` and `-r`) cost neither,
and the write/read ordering is enforced by the `loaded` signal. GHDL warns
`type of a shared variable must be a protected type` three times; that is
expected and is not an error.

**Emitting the stage trace (`PARTIAL`/`CONTRIB`/`ACC`/`YDATA`) as
`ref/matvec_int4 --trace` does.** At `M = 100, NB = 128` that is 25,600 extra
lines the new bench does not read. `g_trace` is deliberately left NULL in
`ref/mv_fk33_tr.c`.

**A synthetic fallback when the .mv4i file is absent.** Considered, and
rejected as dishonest: a fallback that silently packs its own bytes would let
this bench report "from the real .mv4i bytes up" on a machine where the model
set is missing. The generator exits non-zero with the path in the message
instead, which `sim/regress.sh` reports as `VECTORGEN_RUN_FAILED` -- a legible
external-prerequisite failure, never a wrong answer. The path is overridable
with `MV4I_FK33_FILE`.

## 6. Measurement traps hit

**The stated regression floor was wrong, in the safe direction.** The task said
73; `sim/regress.sh` said 76 and a measured full run said 76. Had it been taken
on faith, three testbenches' worth of coverage could have disappeared and the
run would still have reported PASS. **Measure the floor, never quote it.**

**A vector file whose name contains `/` is invisible to `sim/regress.sh`'s
generator machinery.** `tb_matvec_int4`'s trace is `"../tr.txt"`, so it is
*symlinked* from `sim/tr.txt` and never regenerated -- and `sim/tr.txt` is
**not tracked by git**. The new bench's `TRACE` default is therefore the bare
name `"mv_fk33_tr.txt"`, which the plan parser picks up as a vector, matches to
`ref/mv_fk33_tr.c` by stem, builds and runs into the test's own workdir. If the
`tb_vector_args` row is ever deleted the generator is invoked with no arguments
and exits 2 on its usage message -- loud, which is the intended failure shape.

**Prefix token matching would have been a real hazard here.** The trace has
both `WSUB` and `WBEATS`, and both `SSUB`, `SBEATS` and `SATEV`.
`tb_matvec_int4` compares `tok(1 to n)` alone, which is safe only for the token
set it happens to have. The new loader uses a `tokis()` helper that also
requires the following character to be a space.

**A truncated trace is not a wrong answer and must not be reported as one.**
The generator writes `END` last and the loader asserts it saw it. Without that,
a generator killed mid-write would present as a bench-vs-reference divergence.

**`ghdl -e` still produces no binary on the mcode backend**, and the analysis
order is still not inferable: `util_pkg` -> `mv4i_arith_pkg` -> **`stream_fifo`**
-> `axi_rd_port` -> `weight_streamer` -> `act_mem_striped` -> `matvec_core` ->
`matvec_int4` -> the bench. Omitting `stream_fifo` reports
`unit "axi_rd_port" not found`, which reads as a missing entity and is a
missing dependency two levels down.

**Eight `NUMERIC_STD.TO_INTEGER: metavalue detected` warnings appear at time
0.** They come from converting output ports that no process has driven yet
(`y_exp <= to_integer(signed(v_yexp))`), are present in `tb_matvec_int4` for
the same reason, and are `(assertion warning)` which `sim/regress.sh`'s
`FAIL_RE` does not match. Not a defect and not a new one.

**Mutating RTL while a regression is in flight would have corrupted the
result**, and `sim/regress.sh`'s own header warns that editing *it* mid-run
corrupts the run itself (bash reads the script by byte offset). Both were
avoided by mutating copies into private GHDL libraries and by holding every
`regress.sh` edit until the baseline run had exited.

## 7. Open, not yet answered

* **NOT DONE: the `fk33_matvec` build variant of `hw/fk33/gen_pcieep.py`.**
  This is not a time problem, it is three named blockers, and emitting a
  half-wired variant would have been worse than emitting none:
  1. **There is no control plane that can reach this geometry.**
     `rtl/matvec_int4_axi.vhd` asserts `NPORTS_W = 4`, holds four
     `W_BASE`/`W_BASE_HI` pairs and exactly one `S_BASE` pair, and its own
     header states the reason the map cannot simply grow: "a map whose shape
     depended on a synthesis generic would be a map no driver could parse."
     The FK33 needs 24 + 3. That is a different register map (an indexed
     base window, most likely), plus a matching change in `hw/mv_driver.c`
     and spec 10.
  2. **The HBM AXI clock to core clock CDC does not exist.**
     `rtl/weight_streamer.vhd` is single-clock and says so; spec 14.5 item 3
     has been open since the geometry was settled. The FK33's HBM AXI runs at
     ~450 MHz against a ~300 MHz core.
  3. **The shell enables two HBM SAXI ports, not 29.**
     `hw/fk33/build_fk33_pcieep.tcl` sets `USER_SAXI_xx {false}` for
     everything except `SAXI_00` and `SAXI_16`, and `pcie2hbm` is a
     smartconnect with `NUM_SI 2 / NUM_MI 2`. Wiring 27 more masters is a
     block-design change of a different size from the ones that generator
     currently makes.
* **`DEPTH` is still not re-budgeted at 256 bits.** The bench runs
  `FIFO_DEPTH = 256`, chosen only to keep the simulation small. Spec 7.7
  budgets 8 KB per FIFO at `AXI_DW = 128, DEPTH = 512`; at 256 bits that same
  depth is 16 KB and there are 27 of them. Unmeasured, and this bench says
  nothing about it.
* **No synthesis, no place and route, no timing.** Nothing here went through
  Vivado. A 6,144-bit `w_data` net and 27 masters are a materially different
  physical problem from the AXU3EG's 4 x 128, and simulation says only that
  the arithmetic and the reassembly are right.
* **One tensor, one shape, one activation vector.** The bench runs
  `blk.11.attn_k.weight` at `n_rows = 100`. It does not sweep the other six
  shapes, does not run `K = 12288` (`ffn_down`), and does not run
  `out_mode` other than BFP. `MAXCOLS = 4096` in the bench's DUT would have to
  rise for `ffn_down`.
* **`sat_event` is compared but never provoked.** `XAMP` is 8000 precisely so
  the accumulator stays clear of the s32 clamp, so the comparison is
  `0 == 0` on this vector. The adversarial construction that drives it exists
  in `ref/matvec_int4.c --trace ... sat=1` and is NOT wired into this path.
* **The RTL still has no MIXED-REGIME instance** (`n_scale_sub > 1` AND
  `GRP > 1` together, e.g. `ROWS_IF=24 / AXI_DW=256`). That was open in
  `2026-08-28_c-reference-general-axi-dw.md` and is still open; neither
  production geometry reaches it. Section 4.5's M2/M3 table is precisely the
  reason it matters.
* **The trace's descriptor is trusted.** The bases, beat counts and codebook
  come from `ref/matvec_int4.c`'s header parse, so an error there would be
  shared by both sides. Only the BYTES are independent. The mitigation is that
  the header parse is separately checked by `tools/pack_int4.py --crosscheck`
  and by tests 13/13b/14 of the C self-test, not that this bench checks it.

## 8. Regression gate

Full `sim/regress.sh`, both suites, with these changes in the tree:

```
 suite sim   PASS 51   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 77   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 77 passing, matches the recorded floor of 77
 REGRESSION: PASS
```

76 -> 77, the one new testbench, nothing else moved. `BASELINE_PASS` raised to
77 at `sim/regress.sh:351`. The new bench's own row:

```
sim:tb_matvec_fk33   PASS   10s   tb_matvec_fk33.vhd:472:@47875ns:(report note):
  subsystem A is bit-exact with ref/matvec_int4.c fro...
```

Both runs saw an identical working tree apart from these changes:
`rtl/llama_top.vhd` and `sim/tb_llama_top.vhd` carry another workstream's
uncommitted edits, and their mtimes (16:24:21 and 16:26:44) predate the
baseline run's start (16:27:44) and did not move. Neither file was touched
here.

## 9. Reproducing this

```
# the whole thing, through the gate
bash sim/regress.sh --only matvec_fk33

# by hand
cc -O2 -Wall -Wextra -I ref -o /tmp/mv_fk33_tr ref/mv_fk33_tr.c
/tmp/mv_fk33_tr /tmp/run/mv_fk33_tr.txt \
    /mnt/storage/llama-models/qwen35-9b-mv4i/blk.11.attn_k.weight.mv4i 100 5
for f in rtl/util_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/stream_fifo.vhd \
         rtl/axi_rd_port.vhd rtl/weight_streamer.vhd rtl/act_mem_striped.vhd \
         rtl/matvec_core.vhd rtl/matvec_int4.vhd sim/tb_matvec_fk33.vhd; do
  ghdl -a --std=08 -frelaxed --workdir=/tmp/work $f
done
cd /tmp/run && ghdl -r --std=08 -frelaxed --workdir=/tmp/work tb_matvec_fk33 \
    --stop-time=50ms --stop-delta=1000000 --max-stack-alloc=0
```

`ghdl -e` is NOT in that list on purpose: this is the mcode backend and it
would produce no binary while exiting 0.
