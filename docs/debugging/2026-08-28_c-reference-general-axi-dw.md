# The C reference at arbitrary AXI_DW, and how far NPORTS_S plumbs upward

## 1. The question

Verbatim, 2026-08-28:

> `ref/matvec_int4.c` still refuses anything but 128:
>
>     ref/matvec_int4.c:142    if (h->axi_dw != 128) return -7;
>
> and hardcodes it when writing a header:
>
>     ref/matvec_int4.c:343    *(uint16_t *)(void *)(p + 0x1E) = 128;   /* AXI_DW */
>
> It also reads only `s_sub_offset[0]`, so it cannot address a multi-sub-region
> scale layout. [...] Generalise the C reference to the 6.5a rule: arbitrary
> AXI_DW, NPORTS_W derived from the invariant, n_scale_sub sub-regions with the
> per-sub-region offset table. Keep a refusal path for genuinely unspecified
> geometries -- do not turn it into a permissive pass-through.
>
> Task 2 -- plumb NPORTS_S upward. `rtl/matvec_int4.vhd` is fixed at NPORTS_S=1
> and does not expose the generic, so nothing above `weight_streamer` can
> request a multi-sub-region scale layout.

Motivation, stated in the same task: this repo verifies by **double oracle** --
the C reference and the RTL are independent implementations and a result is
trusted only when both agree bit-exactly. At `AXI_DW = 256` that discipline did
not hold, because one of the two oracles refused the file.

Hardware/build context: no board involved. GHDL **mcode** backend
(GHDL 1.0.0 Dunoon; `ghdl -e` produces no binary, every run below is
`ghdl -r <entity>` directly), gcc with `-O2 -Wall -Wextra` and assertions ON
(the file `#error`s under `-DNDEBUG`), Python 3.10.12, GGUF
`/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf` (BF16, 17.9 GB),
tensor `blk.0.ssm_alpha.weight` (32 x 4096). Repo `llama.vhdl` branch `fpga`,
starting at `f46de8b`.

## 2. The answer

**Task 1 is done.** `ref/matvec_int4.c` now implements spec 6.5a at any AXI4
data width: `get_widx` addresses a byte by its offset in the **tile word** and
divides by `port_b` to find the sub-region, `get_scale` reads a **superword**
chunked `GRP` ways across `n_scale_sub` sub-regions, and the packer in the
self-test emits the same layout. The `AXI_DW = 128` path is **byte-identical**
to the pre-change binary on 11 of 11 emitted artifacts and produces identical
crosscheck lines. Three refusals survive and all five refusal codes are
exercised by new self-tests. The C reference and the **Python packer** now
produce byte-identical files at 13 geometries including the FK33's 48/256, and
the C reference reads the RTL testbench's own 6.5a memory bytes with **zero**
mismatches at both 48/256 and 4/128.

**Task 2 is partial by design and the boundary is a real one.**
`rtl/matvec_int4.vhd` now has `NPORTS_S` (default 1) and is general;
`rtl/matvec_int4_axi.vhd` carries the generic but **asserts it is 1**, because
its AXI-Lite register map holds exactly one `S_BASE` / `S_BASE_HI` pair and the
FK33 needs three. `rtl/matvec_int4_ip.vhd` was **not** touched: it has five
hand-named masters and no `NPORTS_W` generic at all, so `NPORTS_S` there is a
new wrapper, not a generic.

## 3. The procedure that produced it

In this order, and the order mattered.

1. **Capture the byte-identity reference BEFORE editing.** Build the pre-change
   `ref/matvec_int4.c`, then emit 7 `.mv4i` images and 4 traces across the
   `ROWS_IF` values and awkward shapes the old code accepted, plus the
   crosscheck line of each. This cannot be reconstructed after the edit.
2. **Build the geometry corpus with the tool that is already general.** Pack one
   real tensor at 12 `(ROWS_IF, AXI_DW)` combinations with `tools/pack_int4.py`
   and record what the OLD C reference does with each (`-7` on 8 of 12). That
   fixes what "generalised" has to mean before any C is written.
3. **Generalise the reader first, then the writer.** Reader (`mv4i_parse`,
   `get_widx`, `get_scale`) and writer (`pack_geom`) are separate changes with
   separate evidence: the reader is checked against Python-written files, the
   writer against Python-written bytes. Doing both at once and testing only
   round-trip is the tautology this repo exists to avoid -- see mutant m7.
4. **Byte-identity regression at 128, twice**: once immediately after the
   reader/writer change and again after the CLI signature change, because the
   second edit touched `--emit`'s argument list.
5. **Cross-oracle 1, C vs Python, on VALUES.** Every one of the 12 packed files
   through the new C reference; all must give the same `mant_sum` the Python
   `--crosscheck` gives, because the same matrix packed any way is the same
   matrix.
6. **Cross-oracle 2, C vs Python, on BYTES.** Reproduce the C packer's LCG in
   Python, call `pack_int4.pack()` with identical inputs, compare files
   byte-for-byte at 13 geometries. This is the check that survives a
   self-consistent error.
7. **Cross-oracle 3, C vs RTL, DIRECTLY.** Extract `sim/tb_weight_streamer.vhd`'s
   own `wnib`/`sclv`/`wmem`/`smem` functions **verbatim with awk**, dump the
   sub-region bytes they define, load those bytes into an `.mv4i` and check the
   C reference's `get_widx`/`get_scale` return the testbench's ROW-definition
   values. No packer in the loop.
8. **Teeth: seven one-line mutants**, each with its failing geometry predicted
   before running, against all three checks.
9. **Task 2**: plumb, then elaborate the FK33 geometry through `matvec_int4`
   with negative controls on the streamer's own asserts.
10. `sim/regress.sh` full run as the gate.

What each control isolates:

- The **pre-change binary** is the control for the whole edit: it separates
  "reads a new layout" from "changed the old one while doing so".
- The **`ROWS_IF=4 / AXI_DW=128` row** in every table is the control for the new
  geometries: it is what is in a built bitstream, so if it moves, something real
  broke.
- **Cross-oracle 2 (bytes)** is the control for cross-oracle 1 (values): values
  agreeing proves the two implementations invert each other, bytes agreeing
  proves they agree on the layout itself. m7 below is the case where the first
  passes and the second fails.
- **Cross-oracle 3** is the control for both: Python and C could in principle
  share an error the RTL does not.

## 4. The evidence

### 4.1 Byte identity of the AXI_DW=128 path

11 artifacts: 7 packed images across `M in {1,6,8,9,13,32,33}`,
`K in {32,40,64,96,100,1000,4096}`, `ROWS_IF in {1,2,4,8}`, and 4 stage traces
including the adversarial saturating one.

```
$ diff base/md5.txt new_md5.txt && echo "AXI_DW=128 FILES BYTE IDENTICAL (11/11)"
AXI_DW=128 FILES BYTE IDENTICAL (11/11)
$ diff base/crosscheck.txt new_crosscheck.txt && echo "CROSSCHECK LINES IDENTICAL"
CROSSCHECK LINES IDENTICAL
```

The pre-change self-test output also diffs clean against the post-change run up
to the point the new tests are appended.

### 4.2 What the OLD C reference did, and what the NEW one does

Same 12 files, packed from `blk.0.ssm_alpha.weight` by `tools/pack_int4.py`.

```
                          OLD                     NEW
alpha_r1_d128.mv4i        mant_sum=-25272         mant_sum=-25272
alpha_r2_d128.mv4i        mant_sum=-25272         mant_sum=-25272
alpha_r4_d128.mv4i        mant_sum=-25272         mant_sum=-25272
alpha_r8_d128.mv4i        mant_sum=-25272         mant_sum=-25272
alpha_r2_d64.mv4i         parse failed: -7        mant_sum=-25272
alpha_r4_d64.mv4i         parse failed: -7        mant_sum=-25272
alpha_r8_d256.mv4i        parse failed: -7        mant_sum=-25272
alpha_r16_d256.mv4i       parse failed: -7        mant_sum=-25272
alpha_r32_d512.mv4i       parse failed: -7        mant_sum=-25272
alpha_r6_d256.mv4i        parse failed: -7        mant_sum=-25272
alpha_r24_d256.mv4i       parse failed: -7        mant_sum=-25272
alpha_r48_d256.mv4i       parse failed: -7        mant_sum=-25272
```

`tools/pack_int4.py --crosscheck` gives `mant_sum=-25272` on all twelve
independently. The corpus is chosen so both scale regimes and the mixed one are
covered:

| file | NPORTS_W | n_scale_sub | GRP | regime |
|---|---|---|---|---|
| r4/128 | 4 | 1 | 2 | AXU3EG, built |
| r1/128 | 1 | 1 | 8 | GRP only |
| r8/128, r4/64, r2/64, r16/256, r32/512 | -- | 1 | 1 | neither |
| r8/256 | 4 | 1 | 2 | GRP only, off 128 |
| **r48/256** | **24** | **3** | **1** | **FK33, n_scale_sub only** |
| r24/256 | 12 | 3 | 2 | **mixed** |
| r6/256 | 3 | 3 | 8 | **mixed, SW = 96 not a power of two** |

The mixed regime matters because spec 6.5a says "exactly one of `GRP` and
`n_scale_sub` exceeds 1 whenever `SW` and `AXI_DW` are both powers of two" --
neither production geometry reaches the case where both do, and a reader that
handled only the two clean regimes would pass every production test.

### 4.3 New self-tests, from `ref/matvec_int4`

```
  13 6.5a every geometry parses                  PASS
  13b 6.5a NPORTS_W/n_scale_sub/GRP as specified PASS
  13c 6.5a same result at 10 (ROWS_IF, AXI_DW) geometries PASS
  14 the FK33 image itself parses                PASS
  14a AXI_DW=96 refused (-7, not an AXI4 width)  PASS
  14b n_scale_sub=6 refused (-9, 6.5a minimality) PASS
  14c n_scale_sub=1 refused (-9, the OLD assumption) PASS
  14d NPORTS_W=512 refused (-8, offset table bound) PASS
  14e NPORTS_W=23 refused (-4, 6.5 invariant)    PASS
```

Test 13 packs `M = 100, K = 200` -- `K` not a whole number of blocks so the
column mask runs, `M` not a multiple of any `ROWS_IF` in the table so every
geometry has pad rows -- at ten geometries and requires the `y_data` of all ten
to be identical. 13b checks `NPORTS_W`, `n_scale_sub` and `GRP` against 6.5a
evaluated by hand in a table, not against the same helper the packer used.

### 4.4 Cross-oracle 2: the C packer and the Python packer emit the same bytes

Same LCG-generated weights and scales fed to both, files compared byte for byte:

```
  IDENTICAL  M=8    K=96    RI=4   DW=128   24576 bytes
  IDENTICAL  M=8    K=96    RI=1   DW=128   12288 bytes
  IDENTICAL  M=8    K=96    RI=2   DW=128   16384 bytes
  IDENTICAL  M=8    K=96    RI=8   DW=128   40960 bytes
  IDENTICAL  M=100  K=1024  RI=4   DW=128   77824 bytes
  IDENTICAL  M=100  K=1024  RI=48  DW=256   114688 bytes
  IDENTICAL  M=100  K=1024  RI=24  DW=256   114688 bytes
  IDENTICAL  M=100  K=1024  RI=6   DW=256   77824 bytes
  IDENTICAL  M=100  K=1024  RI=8   DW=256   77824 bytes
  IDENTICAL  M=100  K=1024  RI=4   DW=64    77824 bytes
  IDENTICAL  M=100  K=1024  RI=2   DW=32    77824 bytes
  IDENTICAL  M=32   K=4096  RI=48  DW=256   114688 bytes
  IDENTICAL  M=1    K=32    RI=48  DW=256   114688 bytes
C-packer vs Python-packer bytes: identical 13, differing 0
```

### 4.5 Cross-oracle 3: the C reference reads the RTL testbench's own bytes

`sim/tb_weight_streamer.vhd`'s `wmem(p,n)` and `smem(q,m)` ARE spec 6.5a's slice
definition, and `weight_streamer` is already proved to reassemble them into
`wword`/`sword`. Those four functions were extracted **verbatim by awk** into a
scratch dumper, their bytes loaded into an `.mv4i`, and the C reference asked
what it thinks each weight and scale is:

```
ROWS_IF=48 AXI_DW=256 NPORTS_W=24 n_scale_sub=3 GRP=1: 405 dump beats,
  144 rows x 160 cols, weight mismatches 0, scale mismatches 0
ROWS_IF=4  AXI_DW=128 NPORTS_W=4  n_scale_sub=1 GRP=2:  68 dump beats,
   12 rows x 160 cols, weight mismatches 0, scale mismatches 0
```

23,040 weights and 720 scales at the FK33 geometry, no packer in the loop.

### 4.6 Teeth: seven one-line mutants, each predicted before running

| mutant | one-line change | self-test | crosscheck vs the 12 Python files | C-vs-Python bytes | C-vs-RTL bytes |
|---|---|---|---|---|---|
| m1 | decoder: weight sub-region `p` -> `NPORTS_W-1-p` | 13c FAIL (+ test 9) | diverges on **11 of 12** (all but `r1_d128`, where reversing one element is identity) | pass | FAIL both geometries |
| m2 | decoder: scale sub-region `q` -> `n_scale_sub-1-q` | 13c FAIL | diverges on **exactly the 3 files with `n_scale_sub > 1`**: r48/256, r24/256, r6/256 | pass | FAIL at 48/256 only (480 of 720 scales) |
| m3 | decoder: chunk `g mod GRP` -> `GRP-1 - g mod GRP` | 13c FAIL | diverges on **exactly the 7 files with `GRP > 1`**: r1/128, r2/128, r4/128, r2/64, r8/256, r24/256, r6/256 | pass | FAIL at 4/128 only (60 of 60) |
| m4 | parse: the `-9` minimality refusal deleted | 14b, 14c FAIL | pass | pass | pass |
| m5 | parse: the `-7` AXI4-width refusal deleted | 14a FAIL | pass | pass | pass |
| m6 | **packer only**: sub-region `sr` -> `nports-1-sr` | 13c FAIL (+ test 9) | pass | **FAIL 12 of 13** | pass |
| m7 | **m1 AND m6 together** -- the same reversal in the packer and the decoder | **0 failures, whole suite green** | diverges on 11 of 12 | **FAIL 12 of 13** | FAIL both |

All seven exit non-zero somewhere. The *pattern* is the informative part:

- **m2 and m3 are complementary.** m2 is invisible at every `n_scale_sub = 1`
  geometry, which is every geometry that existed before this work; m3 is
  invisible at every `GRP = 1` geometry, which includes the FK33 target. Neither
  the AXU3EG nor the FK33 can catch both. The mixed-regime files (r24/256,
  r6/256) are the only ones that catch both, which is why they are in the corpus.
- **m7 is the headline.** A reversal applied *consistently* to the C packer and
  the C decoder passes the entire C self-test, including 13c, with zero
  failures. It is caught only by comparison against a second implementation.
  **The C self-test cannot establish the byte layout; only the double oracle
  can.** Any future change to this layout must be checked against
  `tools/pack_int4.py` bytes, not against the self-test alone.
- **m4 and m5 are invisible to every value-level and byte-level check**, which
  is the reason the refusal paths needed their own tests rather than being
  presumed exercised.

### 4.7 `sim/run_matvec.sh` step 8 extended, step 9 repaired

Step 8a now sweeps `AXI_DW` as well as shape, and both readers agree:

```
  8a C-packed M=8   K=96   RI=4   DW=128   OK   ... mant_sum=3004 sat=0
  8a C-packed M=13  K=129  RI=4   DW=128   OK   ... mant_sum=26037 sat=0
  8a C-packed M=7   K=100  RI=4   DW=128   OK   ... mant_sum=-60018 sat=0
  8a C-packed M=1   K=33   RI=4   DW=128   OK   ... mant_sum=-18244 sat=0
  8a C-packed M=100 K=1024 RI=48  DW=256   OK   ... mant_sum=-6275 sat=0
  8a C-packed M=50  K=320  RI=24  DW=256   OK   ... mant_sum=-133296 sat=0
  8a C-packed M=13  K=129  RI=6   DW=256   OK   ... mant_sum=26037 sat=0
  8a C-packed M=9   K=64   RI=4   DW=64    OK   ... mant_sum=24560 sat=0
  8b python-packed blk.0.ssm_alpha.weight  OK   ... mant_sum=120792 sat=0
== 9. the packer REFUSES geometries nothing implements (N6) ==
  ROWS_IF=1    AXI_DW=256   refused, as it must be
  ROWS_IF=5    AXI_DW=256   refused, as it must be
  ROWS_IF=3    AXI_DW=512   refused, as it must be
  ROWS_IF=3    AXI_DW=384   refused, as it must be
  ROWS_IF=6    AXI_DW=96    refused, as it must be
  ROWS_IF=1000 AXI_DW=8     refused, as it must be
  ROWS_IF=1    AXI_DW=128   accepted, as it must be
  ...
  ROWS_IF=48   AXI_DW=256   accepted, as it must be
  ROWS_IF=24   AXI_DW=256   accepted, as it must be
  ROWS_IF=6    AXI_DW=256   accepted, as it must be
  ROWS_IF=4    AXI_DW=64    accepted, as it must be
== all green ==
```

Note that `M=13 K=129` gives the same `mant_sum=26037` at `RI=4/DW=128` and at
`RI=6/DW=256`, which is cross-oracle 1 restated inside the runner.

### 4.8 Task 2: `NPORTS_S` reaching `weight_streamer` through `matvec_int4`

A scratch testbench instantiating `matvec_int4` alone (no AXI wrapper):

```
--- A: FK33 geometry, NPORTS_S=3, MAXB=128 (must pass)
(report note): tb_nps: elaborated and ran at ROWS_IF=48 NPORTS_W=24
               NPORTS_S=3 AXI_DW=256 MAXB=128           rc=0
--- B: NPORTS_S=2 at the same geometry (must FAIL)
error: bound check failure at rtl/weight_streamer.vhd:126   rc=1
--- C: MAXB=256 at AXI_DW=256 (must FAIL the 4 KB burst assert)
error: assertion failed ... weight_streamer.vhd:175        rc=1
--- D: the AXU3EG default path, NPORTS_S=1 (must pass)
(report note): tb_nps: elaborated and ran at ROWS_IF=4 NPORTS_W=4
               NPORTS_S=1 AXI_DW=128 MAXB=256            rc=0
--- E: NPORTS_S=6 (divides, but is not minimal)
(assertion failure): weight_streamer: NPORTS_S is not the minimal
  n_scale_sub of 6.5a; the packed file's scale sub-regions are cut
  differently                                            rc=1
```

And the AXI wrapper refuses `NPORTS_S > 1` (see the trap in 6.3 about which
assert actually speaks):

```
--- NPS=1 (default, must pass)   (report note): elaborated with NPORTS_S=1  rc=0
--- NPS=2                        assertion failure                          rc=1
```

### 4.9 Regression gate

See section 8 for the recorded result of the `sim/regress.sh` run made with
these changes in the tree.

## 5. Measured and REJECTED -- do not retry

**Turning `mv4i_parse` into a pass-through.** Rejected as the obvious wrong
shape, exactly as `unmet_reasons()` was on the packer side. Five refusal codes
survive and each has its own test (14a-14e): `-4` the 6.5 invariant, `-7`
AXI_DW not an AXI4 data width, `-8` the sub-region offset table (both the
64-entry array bound and the 4 KB header bound of 6.4), `-9` `n_scale_sub`
disagreeing with 6.5a's minimal value. Mutants m4 and m5 confirm those tests are
the only thing standing between the codes and deletion.

**Refusing `AXI_DW < BLOCK*4`.** Considered, because `ROWS_IF=4 / AXI_DW=64`
splits a row chunk across two sub-regions and looks like it should need a
special case. It does not: 6.5a's slice rule is symmetric and the geometry packs,
decodes and round-trips (`mant_sum=-25272`, section 4.2). Refusing it would have
been refusing the general rule. It is in the test-13 table for that reason.

**Reading the scale as a 16-bit word.** The natural `rd_u16(s + off)` works at
every width this project targets, because the byte offset within a superword is
even and `port_b` is even for `AXI_DW >= 16`. It breaks at `AXI_DW = 8`, where
`port_b = 1` and a scale straddles two sub-regions. `get_scale` reads two bytes
through `scale_byte()` instead. Cost: one extra division per byte, on a
reference implementation whose whole purpose is to be obviously correct.
**Do not "optimise" this back into a `rd_u16`** -- the tidy widths are exactly
how 6.5 came to be pinned at 128 in the first place.

**Deriving `n_scale_sub` in `mv4i_parse` and ignoring the header field.** The
same argument the prior agent recorded for the RTL generic: a derived value
cannot disagree with itself, so it asserts nothing. The header field is read and
**checked** against 6.5a, and `-9` is what a disagreement produces. The one
accepted deviation is `n_scale_sub == 0`, which can only mean a file older than
the field and therefore the single contiguous region.

**Extending the AXI-Lite register map to carry three `S_BASE` pairs.** Rejected
for this change. `matvec_int4_axi` already asserts `NPORTS_W = 4` with the
reason "a map whose shape depended on a synthesis generic would be a map no
driver could parse", and three scale bases has exactly that problem, plus a
matching change in `hw/mv_driver.c` and spec 10. Carrying three bases is not a
wider register, it is a different register map. The generic is present and
asserted at 1 so the blocker is named rather than silent.

**Touching `rtl/matvec_int4_ip.vhd`.** It has five hand-named masters
(`m00_axi_*` .. `m04_axi_*`) because Vivado's interface inference keys on names,
and it has no `NPORTS_W` generic at all. At the FK33 geometry it would need 27
named masters. That is a new wrapper, not a generic, and it is downstream of a
register-map decision that has not been made.

**Making `matvec_int4`'s scale ports a separate vector from the weight ports.**
Not attempted, and recorded so nobody tries: the flattened
`NPORTS_W+NPORTS_S-1 downto 0` form is what makes `NPORTS_S = 1` reduce
*syntactically* to the old `NPORTS_W downto 0`, which is why `rtl/llama_top.vhd`
and every testbench needed no edit at all. A separate vector would have forced
every instantiation to change.

## 6. Measurement traps hit

### 6.1 `sim/run_matvec.sh` step 9 had been vacuous since commit `0f44da2`

The step drove each supposedly-refused geometry through the full packer CLI with
`/dev/null` as the GGUF and asserted only that the process exited non-zero. Once
`0f44da2` made `8/256`, `16/128`, `58/256` and `80/128` legal geometries, the
CLI still exited non-zero -- **because `/dev/null` is not a GGUF** -- and the
step still printed "refused, no file written" for all four. It had been testing
nothing for a day and said so to nobody.

```
$ python3 tools/pack_int4.py /dev/null t /tmp/x.mv4i --rows-if 8 --axi-dw 256
reading t from /dev/null
OSError: [Errno 22] Invalid argument
rc=1
```

Both directions now call `check_geometry()` directly, where the only thing that
can decide the outcome is the geometry. General form of the trap: **a guard
driven through a CLI that can fail for a second reason is not a guard.**

### 6.2 `-7` was not reachable by simply corrupting `AXI_DW`

The first attempt at test 14a set `axi_dw = 96` on a 48/256 image, which returns
`-4`, not `-7`: the 6.5 invariant `NPORTS_W * AXI_DW = ROWS_IF * BLOCK * 4` is
checked first and `24 * 96 != 6144`. Reaching the AXI4-width refusal requires a
geometry where the invariant still divides, so the test sets
`rows_if = 3, nports_w = 4, axi_dw = 96` (`384 = 4 * 96`). A refusal test that
lands on the wrong code is a test that says a different guard has teeth.

### 6.3 At `NPORTS_W = 4` the wrapper's new `NPORTS_S = 1` assert can never be
the one that speaks

`matvec_int4_axi` pins `NPORTS_W = 4`, which forces `ROWS_IF = AXI_DW/32` and
therefore `SW = AXI_DW/2`, and `n_scale_sub = SW/gcd(SW, AXI_DW) = 1` at **every**
AXI4 width. So any `NPORTS_S > 1` passed to the wrapper is also non-minimal, and
`weight_streamer`'s own minimality assert fires first:

```
rtl/weight_streamer.vhd:168: weight_streamer: NPORTS_S is not the minimal
  n_scale_sub of 6.5a; the packed file's scale sub-regions are cut differently
```

**The wrapper's assert therefore has no independent teeth** and deleting it
would not fail anything. It is kept as documentation of the register-map limit
and as the assert that would fire first if the streamer's check were ever
relaxed. Stated here rather than claimed as a verified guard.

### 6.4 A `positive` bound check can pre-empt the assert written for the case

At `ROWS_IF=48, AXI_DW=256, NPORTS_S=2`, `weight_streamer`'s
`constant GRP : positive := SUPER / SW` evaluates `512/768 = 0` and fails the
subtype bound **during declaration elaboration**, before the minimality assert
runs. The result is still a hard non-zero exit, but the message is
`bound check failure at rtl/weight_streamer.vhd:126` and says nothing about
6.5a. The assert is only the speaker for values that divide but are not minimal
(`NPORTS_S = 6`, verified in section 4.8 case E). Both are safe; only one is
legible. Do not read a bound-check failure here as a different bug.

### 6.5 `pack()`'s scale region rounds to a whole SUPERWORD, and at 128 that is
invisible only because of the 4 KB alignment

The old C `pack()` sized the scale region as `align4k(tiles*NB*rows_if*2)`; the
new one as `align4k(nsuper*port_b)` where `nsuper = ceil(tiles*NB / GRP)`. These
differ by up to 14 bytes before alignment. They cannot differ after it: the old
size is exactly `4096k` only when `tiles*NB` is a multiple of `GRP`, in which
case `nsuper*port_b` equals it. Checked by argument and then by measurement --
all 11 baseline files, including `M=32 K=4096`, are byte-identical. Worth
restating because the same rounding is the one place the *Python* packer could
have changed a file size too, and it is the reason `packed_layout()` returns a
`nsuper`-derived size rather than a group-derived one.

### 6.6 The mcode backend, again

`ghdl -e` succeeds and produces no binary. Every result in 4.5 and 4.8 comes
from `ghdl -r <entity>` directly. The analysis order also matters and is not
inferred: `util_pkg` -> `mv4i_arith_pkg` -> **`stream_fifo`** -> `axi_rd_port`
-> `weight_streamer` -> ... A first pass that omitted `stream_fifo` reported
`unit "axi_rd_port" not found in library "work"` from `weight_streamer`, which
reads as a missing entity and is a missing *dependency two levels down*.

### 6.7 `-Wall -Wextra` and assertions are load bearing on this file

`ref/matvec_int4.c` `#error`s under `-DNDEBUG` by design, because every width
bound in 7.4 is enforced by `assert()` alone. All builds above use
`cc -O2 -Wall -Wextra` with no `-DNDEBUG`, and the mutant builds use `-w` only
to suppress warnings from deliberately broken code -- never `-DNDEBUG`.

## 7. Open, not yet answered

- **There is no DATA-level test of `matvec_int4` at `NPORTS_S = 3`.** Section 4.8
  proves the generic reaches `weight_streamer` and that its asserts fire, and
  `sim/tb_weight_streamer.vhd` proves the streamer's reassembly at 48/256. What
  is untested is the two together carrying real weights into `matvec_core`.
  `sim/tb_matvec_int4.vhd` is the vehicle and it is hardcoded to `AXI_DW = 128`
  (`constant AXI_DW : positive := 128`, `constant NP : positive := RI`, a slave
  model serving 128-bit beats, and its own 128-bit image construction). Making
  it general is a testbench rewrite, not a generic.
- **`matvec_int4_axi` cannot reach the FK33 geometry at all**, and not only
  because of `NPORTS_S`: `NPORTS_W = 4` is asserted, and the result buffer,
  `Y_DATA` lane mux and the four `W_BASE`/`W_BASE_HI` register pairs are all
  fixed at four. The FK33 control plane is a separate design.
- **`hw/mv_driver.c` includes `ref/matvec_int4.c` with `MV4I_LIB`** and so picks
  up the generalised reader automatically. It was not rebuilt or run here; no
  board was involved. Its own header-writing path (if any) was not audited.
- **No synthesis.** Nothing in this change was run through Vivado. The
  `NPORTS_S` generic widens `matvec_int4`'s port vectors, which at the default
  is a syntactic no-op, but that is an argument and not a synthesis run.
- **The 6.5a rule at `AXI_DW = 8` is implemented and never exercised end to
  end.** `scale_byte()` handles the straddle and `ROWS_IF=1000/AXI_DW=8` is used
  only as the offset-table refusal case. No file was packed at 8 bits, because
  no bus is 8 bits.
- **The RTL has no MIXED-REGIME instance.** `sim/tb_weight_streamer.vhd` covers
  `n_scale_sub = 3, GRP = 1` (48/256) and `n_scale_sub = 1, GRP = 2` (4/128), so
  between them the sub-region-order and chunk-order mutant classes are both
  caught. What no RTL instance reaches is a geometry where **both** exceed 1 and
  the two selects interact: `ROWS_IF = 24, AXI_DW = 256, NPW = 12, NPS = 3,
  GRP = 2`, or `ROWS_IF = 6, AXI_DW = 256` where `SW = 96` is not a power of
  two. Both are covered on the C side (tests 13, and rows in 4.2/4.4) and
  neither is covered on the RTL side. Adding a third `ws_check` instance is the
  obvious next step; it was deliberately not done here because the regression
  run that gates this change was already in flight over that file.
- **`DEPTH` still not re-budgeted at 256 bits**, and the HBM-to-core CDC of spec
  14.5 item 3 is still untouched. Both were open in
  `2026-08-28_fk33-pack-layout-axi256.md` and neither is closed here.

## 8. Regression gate

`sim/regress.sh` with these changes in the tree (`BASELINE_PASS = 74`):

```
 suite sim   PASS 48   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 74   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 74 passing, matches the recorded floor of 74
 REGRESSION: PASS
```

`BASELINE_PASS` is NOT raised: this change adds no testbench. Everything new is
in the C reference's own self-test, which `sim/regress.sh` runs as step 2 of
`sim/run_matvec.sh`'s chain rather than as a counted testbench, and in scratch
harnesses that are deliberately not checked in (they exist to compare against
implementations, and a checked-in copy of the RTL testbench's own functions
would stop being an independent statement of the rule the moment either side
moved).
