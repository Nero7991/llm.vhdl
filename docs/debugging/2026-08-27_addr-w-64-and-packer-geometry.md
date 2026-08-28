# ADDR_W past 4 GB, and the packer geometry that emitted plausible wrong files

**Date:** 2026-08-27
**Repo:** `llama.vhdl`, branch `fpga`, from `adc6fe1`
**Tools:** GHDL 1.0.0 (mcode backend), gcc, python3 + `gguf-py` from
`/mnt/storage/llama-dflash2-src/gguf-py`. **No Vivado was run.**
**Explains:** audit items N5 and N6 of
`docs/2026-08-27_weight-path-audit.md`.

---

## 1. The question, verbatim

Two, from the same audit:

> **N5** -- widen `ADDR_W` from 32 to 64. You found it at
> `rtl/axi_rd_port.vhd:31`, `rtl/matvec_int4_axi.vhd:56` and
> `rtl/matvec_int4_ip.vhd:28`, against a 5.04 GB image. This is a silent wrap,
> not a failure: an address past 4 GB truncates and reads plausible-looking
> wrong weights. [...] look specifically for intermediate `integer` variables,
> which are 32-bit signed in VHDL and will overflow at 2 GB even after the ports
> are 64 bits wide. That is the trap this change usually dies on.

> **N6** -- `--rows-if 80` runs happily and emits an 80-sub-region file no FK33
> design can consume, producing a plausible wrong file rather than an error.
> [...] `--crosscheck` is called from nowhere.

Symptom numbers at the start: 9B packs to 5.087 GB against a 4 GB reach;
`tools/pack_int4.py --audit --rows-if 80` exits 0; `grep -rn crosscheck` finds
the definition and no caller.

---

## 2. The answer, up front

**N5. The datapath was already correct and had never been tested. The break was
entirely in the AXI-Lite register map, and it was LOUD, not silent.**
`matvec_int4`, `weight_streamer` and `axi_rd_port` run unmodified at
`ADDR_W = 64` with a base above 4 GB. `matvec_int4_axi` could not be elaborated
at 64 at all: it failed a bound check at `matvec_int4_axi.vhd:177`, because
`r_sbase` was declared `31 downto 0` against an `ADDR_W`-wide port. So the
premise "an address past 4 GB truncates and reads plausible-looking wrong
weights" was **false of the RTL as committed** -- there was no path by which a
>4 GB base could be programmed at all. The silent wrap it warns about is real,
but it lives one level up, in the register map that had no way to carry the
top half. That is now a LO/HI pair with an explicit `ERR_ADDR` refusal.

**The predicted `integer` trap was real and was in the TESTBENCHES, not the
RTL.** `sim/tb_matvec_int4.vhd` built every base with `to_unsigned(v, ADDR_W)`
from a VHDL `integer`, which is 32-bit signed and cannot represent
`0x1_0000_0000` at any `ADDR_W`; and both AXI slave models indexed their image
with `to_integer(a / 16)`, which overflows on a 64-bit address before the
`mod MAXW` meant to bound it can run. Nothing above 4 GB was expressible, which
is exactly why nobody had ever tried.

**N6. The foot-gun was one line.** `tools/pack_int4.py:203` read
`nports = rows_if  # 6.5 invariant at BLOCK=32, AXI_DW=128`. That is the
invariant already evaluated at one width, used as if it were the invariant.
`AXI_DW` is now an explicit input, `NPORTS_W` is derived from it, the value
travels in the file header at `0x1E` (previously reserved-and-zero, so `0`
decodes as `128` and no existing file is invalidated), and geometries nothing
implements are refused with the specific reason. `--crosscheck` now runs on
every `sim/run_matvec.sh` invocation, in both emitter directions.

---

## 3. The procedure that produced it, in order

Each step isolates one thing. The order matters: steps 1-3 establish what was
actually broken before anything was changed, which is what kept the fix from
being a find-and-replace across five files.

| # | Probe | What it isolates |
|---|---|---|
| 1 | Read `axi_rd_port.vhd` end to end looking for integer address arithmetic | Whether the datapath has the predicted `integer` trap. It has exactly one integer expression touching an address, `this_len * BYTES`, bounded at 8192. |
| 2 | Run `tb_matvec_int4` **unmodified** as a baseline | That the chain is green before anything moves. Without this, any later failure is ambiguous. |
| 3 | Make `ADDR_W` a testbench **generic**, then run the pre-change RTL at 64 | Whether the datapath needed changing at all. **It did not.** This is the step that stopped four files from being edited unnecessarily. |
| 4 | Elaborate `matvec_int4_axi` at `ADDR_W=64` with a throwaway probe entity | Where the actual break is. One bound check, one line. |
| 5 | Add `BASE_HI` and an address **check** in the slave model | That truncation is DETECTABLE. It is not, without this: the image is served modulo `MAXW`, so a base that loses its top 32 bits reads exactly the right bytes and the test passes. |
| 6 | Run the 2x2 matrix (`ADDR_W` in {32,64}) x (`BASE_HI` in {0,1}) against the **pre-change** RTL from a clean library | The regression test is seen to fail before the fix, which is the only thing that makes it evidence. |
| 7 | Rebuild the register map as LO/HI + `ERR_ADDR` + `ADDR_CAP`, rerun the matrix | The fix works and the 32-bit case is unchanged. |
| 8 | `--rows-if 80` and `--axi-dw 256` against the packer | The N6 foot-gun, reproduced. |
| 9 | Re-run `--audit` at `ROWS_IF` 4 / 58 / 80 after the change | That the sizing numbers in the audit document did not move. They did not. |
| 10 | Add `--emit` to the C reference; cross-check C-packed and Python-packed files both ways | Both emitters, not just the one measured by hand. |

**Controls used, and what each one controls for:**

- `ADDR_W=32, BASE_HI=0` is run on **every** shape alongside the 64-bit rows.
  Without it, "the 64-bit path works" would not distinguish a fix from a
  rewrite that broke the AXU3EG.
- The `ERR_ADDR` probe is **two-sided**: it must latch at `ADDR_W=32` and must
  NOT latch at 64. A one-sided check passes on a build with the bit tied high.
- Stage 9's refusal list is paired with an **acceptance** list
  (`ROWS_IF` in {1,2,4,8} at `AXI_DW=128`). A packer that refuses everything
  would otherwise score perfectly.

---

## 4. The evidence, as captured output

### 4.1 The pre-change RTL, run against the new testbenches, clean library

Snapshot of the five files at `adc6fe1`, analysed into an empty library
together with the current testbenches:

```
=== PRE-CHANGE RTL (snapshot of adc6fe1) + NEW testbenches ===
--- tb_matvec_int4, pre-change RTL ---
  ADDR_W=64 BASE_HI=1  : PASS
  ADDR_W=32 BASE_HI=1  : FAIL: assertion failure): port 0: address high half is 0,
                               expected 1 -- the base was truncated (ADDR_W=32)
--- tb_matvec_axi, pre-change RTL ---
  ADDR_W=32 BASE_HI=0  : FAIL: assertion failure): ADDR_CAP reads 0, expected 32
  ADDR_W=64 BASE_HI=0  : FAIL: bound check failure at .../pre_n5/matvec_int4_axi.vhd:177
  ADDR_W=64 BASE_HI=1  : FAIL: bound check failure at .../pre_n5/matvec_int4_axi.vhd:177
```

Read the four lines in order. The datapath **passes** at 64 bits with a >4 GB
base, unmodified. The same testbench **fails** when the width is narrowed, so
the check is live. The register map cannot be elaborated at 64 at all. And it
has no `ADDR_CAP`, correctly detected.

`matvec_int4_axi.vhd:177` in that snapshot is the port map line `s_base =>
r_sbase`.

### 4.2 The post-change RTL, same matrix

```
ADDR_W=32 BASE_HI=0  : PASS  end to end: 8 rows compared, 0 mismatches
ADDR_W=64 BASE_HI=0  : PASS  end to end: 8 rows compared, 0 mismatches
ADDR_W=64 BASE_HI=1  : PASS  end to end: 8 rows compared, 0 mismatches
ADDR_W=32 BASE_HI=1  : FAIL  (correct: the base cannot be represented)
```

```
ADDR_W=32 BASE_HI=0  : PASS  AXI: 8 rows read back, 0 mismatches | ERR_ADDR correctly latched
ADDR_W=64 BASE_HI=0  : PASS  AXI: 8 rows read back, 0 mismatches | ERR_ADDR correctly silent
ADDR_W=64 BASE_HI=1  : PASS  AXI: 8 rows read back, 0 mismatches | ERR_ADDR correctly silent
ADDR_W=32 BASE_HI=1  : FAIL  ERR_ADDR latched on a base this build can represent
```

The last row is the important one and it fails *earlier* than in 4.1: the
wrapper now latches `ERR_ADDR` at descriptor-programming time, before a single
AXI transaction is issued. The hardware refuses the job rather than running it
against a truncated address.

### 4.3 The full chain, after both changes

`sh sim/run_matvec.sh`, tail:

```
== 6. subsystem A end to end, from the REAL packed bytes ==
  M=8   K=96   ROWS_IF=4  stall=3  aw=32 hi=0  OK   end to end: 8 rows compared, 0 mismatches
  ...
  M=8   K=96   ROWS_IF=4  stall=3  aw=64 hi=1  OK   end to end: 8 rows compared, 0 mismatches
  M=7   K=100  ROWS_IF=4  stall=3  aw=64 hi=1  OK   end to end: 7 rows compared, 0 mismatches
  M=13  K=129  ROWS_IF=8  stall=3  aw=64 hi=1  OK   end to end: 13 rows compared, 0 mismatches
== 6b. the >4 GB base MUST FAIL at ADDR_W=32 (N5 negative control) ==
  ADDR_W=32 BASE_HI=1  correctly REFUSED: address high half is 0, expected 1
== 7. the PS sequence over AXI-Lite (10 step 5, in simulation) ==
  M=8   K=96   stall=3  aw=32 hi=0  OK   AXI: 8 rows read back, 0 mismatches, ERR_ADDR correctly latched
  M=8   K=96   stall=3  aw=64 hi=1  OK   AXI: 8 rows read back, 0 mismatches, ERR_ADDR correctly silent
== 7b. ERR_ADDR must latch when a base does not fit (N5 negative control) ==
  ADDR_W=32 BASE_HI=1  correctly REFUSED by ERR_ADDR before start
== 8. the PACKER agrees with the C reference on the same bytes (N6) ==
  8a C-packed M=8   K=96    OK   M=8 K=96 w_exp=2 out_shift=3 ns=4 y_exp=-5 mant_sum=3004 sat=0
  8a C-packed M=13  K=129   OK   M=13 K=129 w_exp=2 out_shift=3 ns=5 y_exp=-6 mant_sum=26037 sat=0
  8a C-packed M=7   K=100   OK   M=7 K=100 w_exp=2 out_shift=3 ns=4 y_exp=-5 mant_sum=-60018 sat=0
  8a C-packed M=1   K=33    OK   M=1 K=33 w_exp=2 out_shift=3 ns=3 y_exp=-4 mant_sum=-18244 sat=0
  8b python-packed blk.0.ssm_alpha.weight  OK   M=48 K=5120 w_exp=9 out_shift=4 ns=4 y_exp=1 mant_sum=120792 sat=0
== 9. the packer REFUSES geometries nothing implements (N6) ==
  ROWS_IF=80  AXI_DW=128   refused, no file written
  ROWS_IF=58  AXI_DW=256   refused, no file written
  ROWS_IF=8   AXI_DW=256   refused, no file written
  ROWS_IF=16  AXI_DW=128   refused, no file written
  ROWS_IF=1   AXI_DW=128   accepted, as it must be
  ROWS_IF=2   AXI_DW=128   accepted, as it must be
  ROWS_IF=4   AXI_DW=128   accepted, as it must be
  ROWS_IF=8   AXI_DW=128   accepted, as it must be
== all green ==
```

Stage 8b reproduces, automatically, the exact line that was measured by hand
during the audit: `M=48 K=5120 w_exp=9 out_shift=4 ns=4 y_exp=1
mant_sum=120792 sat=0`. That measurement is now a regression test.

### 4.4 The packer refusing, with reasons

```
$ python3 tools/pack_int4.py MODEL.gguf blk.0.ssm_alpha.weight x.mv4i --rows-if 80 --axi-dw 256
pack_int4: refusing this geometry.
  - The sub-region BYTE LAYOUT is undefined at AXI_DW=256. Only 128 is
    specified: there one lane is exactly one row's chunk (spec 6.5, the
    'ROWS_IF=4 coincidence'), and that is the layout this packer emits. At
    256 bits a lane spans 2 rows and the interleave within a sub-region has
    never been written down -- spec 14.5 defers it until the HBM
    weight_streamer exists. I do not know the legal set for the FK33 and
    will not guess one.
  - The scale region needs more than one sub-region at ROWS_IF=80: 1280
    scale bits per cycle against a 256-bit port.
    rtl/weight_streamer.vhd:104-110 states this is not implemented (spec
    14.5 item 2). The header carries n_scale_sub for it; nothing reads it
    yet.
  Geometries this packer emits today: BLOCK=32, AXI_DW=128,
  ROWS_IF in {1, 2, 4, 8}.  Anything else needs the layout to be
  specified first.
rc=2
```

Both reasons are listed, not the first one hit. The refusal happens **before**
the tensor is read, so it costs milliseconds rather than the ~40 s a
dequantisation of a real tensor takes.

### 4.5 The audit numbers did not move

Re-run after the change, against `Qwen3.8-27B-Q4_K_M.gguf`:

| `ROWS_IF` | packed whole model | before | after |
|---|---|---|---|
| 4 | 14.101 GiB | 14.101 | 14.101 |
| 58 | 14.228 GiB | 14.228 | 14.228 |
| 80 | 14.190 GiB | 14.190 | 14.190 |

The per-sub-region size formula was generalised from `BLOCK//2` to
`axi_dw // 8`; at `AXI_DW = 128` those are both 16, which is why nothing moved.
The 58 and 80 rows now print `*** SIZES ONLY -- this geometry CANNOT BE
PACKED ***` above the numbers.

---

## 5. Measured and REJECTED -- do not retry

**5.1 Do NOT change the `ADDR_W` default from 32 to 64.**
`hw/design_mv_generated.tcl:531-534` overrides only `FIFO_DEPTH` and `MAXOUT`,
so the AXU3EG block design takes `ADDR_W` **from the default**, and its HP-port
address spaces are assigned 32-bit (`assign_bd_address -offset 0x00000000
-range 0x80000000` on each of `mv/m00_axi` .. `mv/m04_axi`, with
`HP0_DDR_HIGH` explicitly excluded at line 611). Raising the default silently
changes that bitstream's master width and every one of those assignments.
Verifying the consequence needs Vivado, which was explicitly out of scope for
this run. The default stays 32; the FK33 passes 64 explicitly; the reason is
recorded in `rtl/matvec_int4_ip.vhd` at the generic itself.

**5.2 Do NOT "fix" the datapath for 64-bit addressing. There is nothing to
fix.** Measured, section 4.1: `axi_rd_port`, `weight_streamer` and
`matvec_int4` pass at `ADDR_W=64` with a >4 GB base, **unmodified**. The only
integer expression touching an address is `this_len * BYTES` at
`rtl/axi_rd_port.vhd:182`, bounded at `256 * 32 = 8192`. `n_beats`, `ar_left`
and `promised` are beat counts, not addresses: the largest sub-region in the
27B model is ~1.2e6 beats and the whole 5 GB image is 3.1e8, both far under
`integer'high`. Spec A section 15.5's claim that the datapath is already
parameterised is correct; it had simply never been exercised.

**5.3 Do NOT index the AXI slave model's image with `to_integer(a / 16) mod
MAXW`.** That was the original code in both testbenches and it is wrong at 64
bits for a reason that reads as right: the `mod MAXW` looks like it bounds the
value, but `to_integer` runs **first** and overflows a 32-bit signed integer on
any address above 2 GB. Take an address **slice** instead:
`img(to_integer(a(clog2(MAXW)+3 downto 4)))`.

**5.4 Do NOT test a wide base without an explicit high-half check.** Measured
and nearly missed: with the image served modulo `MAXW`, a base whose top 32
bits are silently dropped reads **exactly the right bytes** and the testbench
reports 0 mismatches. A `BASE_HI` generic alone is not a test; the
`assert to_integer(shift_right(a, 32)) = BASE_HI` in the slave is the test.

**5.5 Do NOT build a >4 GB constant through a VHDL `integer`.** `to_unsigned(v,
64)` cannot express `0x1_0000_0000` because `v` is a 32-bit signed integer, and
`BASE_HI * 2**32` does not elaborate for the same reason. Assemble in
`unsigned`: `to_unsigned(off, ADDR_W) + shift_left(to_unsigned(BASE_HI,
ADDR_W), 32)`. `shift_left` by 32 on a 32-bit vector yields 0 by numeric_std's
own definition, which is what makes the same source legal at both widths.

**5.6 Do NOT make the register map's shape depend on `ADDR_W`.** Tried on
paper and discarded: slicing `s_axi_wdata(ADDR_W-1 downto 0)` into a
variable-width register is what the pre-change code did in the `W_BASE` case
(`when 8|9|10|11`), and at `ADDR_W=64` it indexes a 32-bit bus out of range.
Making the register count vary instead would give every bitstream a different
map and no host driver could parse it without knowing the synthesis generics
first. The storage is fixed at 64 bits, the port is **sliced out of it**, and
`ADDR_CAP` at `0x7C` reports the width so a driver can discover it.

**5.7 Do NOT make `--audit` refuse an unimplementable geometry.** Tried, and it
broke the sizing numbers this project already published. The audit writes no
bytes, and the layout and scale-sub-region limits change only how the same
total is CUT, not the total. Rule 1 (the invariant must divide) is arithmetic
and still applies everywhere; rules 2 and 3 are not-implemented-yet limits and
are reported next to the sizes instead. `unmet_reasons()` exists so the two
call sites ask the same question and get the same prose.

**5.8 Do NOT relax the C reference's `nports_w != rows_if` check to the general
invariant and stop there.** The general form is the right check, but
`get_widx`/`get_scale` decode the lane-is-one-row layout and only that, so
accepting any file satisfying the general invariant would mean decoding files
the reference cannot read. Both checks exist, with **different return codes**:
`-4` for a self-inconsistent header, `-7` for a valid file this decoder does
not handle.

---

## 5a. A separate defect found by running the suite, and it destroyed a fix

**`sim/run_matvec.sh` stage 1 silently deleted a hand-added
undefined-behaviour guard from `ref/mv4i_arith.h`.** Not the change under test;
a side effect of running the suite at all, and worth its own section because it
will happen to the next person.

`ref/mv4i_arith.h` is GENERATED by `tools/gen_arith.py`. Someone added, by
hand, directly to the generated file:

```c
    /* sh = 63 makes (int64_t)1 << sh overflow, which is UNDEFINED behaviour,
     * not merely implementation-defined.  It is reachable: this project clamps
     * every shift count to [0, 63] by convention, so 63 is a value the callers
     * deliberately produce.  UBSan flags it on gdn_err.c at ... */
    if (sh >= 63) return (v < 0) ? -1 : 0;
```

plus the matching `sh >= 64` case in `mv4i_round_shift`. The generator does not
emit either, so `gen_arith.py --check` reports `STALE: ref/mv4i_arith.h`, and
stage 1's `--check || { gen_arith.py; }` regenerated the file and threw the
guard away. **Recovered from git only because the diff was read before
committing.** Verified reproducible: restore the file, run
`python3 tools/gen_arith.py --check`, get `STALE` and exit 1.

Two things follow.

**The guard is restored and left in place here.** It is a behaviour change, not
a comment: at `sh >= 63` it returns `-1`/`0` directly instead of relying on the
`1 << 63` overflow happening to produce `INT64_MIN` on gcc x86-64.

**The real fix is in `tools/gen_arith.py` and was NOT made.** That generator
also emits `rtl/mv4i_arith_pkg.vhd` and `sim/arith_vectors.txt`, so changing it
changes RTL numeric behaviour shared by A and B, and another agent is working
in that area today. Making it in passing, from a task about address widths,
is exactly the kind of unrelated edit that gets blamed for a later divergence.

**What was done instead:** stage 1 now takes a `.prechk` backup of all three
generated files, prints a boxed warning naming them, and reports which ones
actually changed. Non-destructive and impossible to miss, but it is a
mitigation, not a fix. **The generator still does not emit the guard, so every
`run_matvec.sh` invocation still overwrites it.** Whoever owns `gen_arith.py`
should fold the guard into the generator and delete this workaround.

## 6. Measurement traps hit, including my own

**6.1 `ghdl -e` succeeds without producing anything.** The mcode backend does
no code generation, so an elaboration "pass" proves the design binds and
nothing about whether it runs. Every result here comes from `ghdl -r`. The
`ADDR_W=64` bound-check failure in section 4.1 appears **at run time**, not at
`-e`, which is why the probe entity had to be executed rather than elaborated.

**6.2 `set -e` in `sim/run_matvec.sh` silently kills a negative control.**
`out=$(cmd)` takes `cmd`'s exit status, so a test that is SUPPOSED to fail
aborts the script before the result can be judged -- and the script exits
non-zero, so it looks like the suite failed rather than like the control
worked. Both new negative controls end in `|| true` for this reason. Anyone
adding a third must do the same.

**6.3 My own first draft of the packer refusal fired the wrong rule.** At
`ROWS_IF=80, AXI_DW=128` the scale-region rule triggers before the byte-layout
rule, so the message named `weight_streamer` and never mentioned that 80
sub-regions are unconsumable. Both are true; reporting only the first hit sends
the reader to the wrong file. `unmet_reasons()` returns a list and the caller
prints all of it.

**6.4 The 7.99% RMS on `blk.0.ssm_alpha.weight` is not a defect and looks like
one.** That tensor is Q8_0 in the shipped GGUF precisely because it is
quantisation-sensitive, and this format takes it to 4.5 bits. Spec A section
6.1's measured +1.69% whole-model perplexity is the end-to-end answer. Do not
read a single tensor's reconstruction error as a format verdict.

**6.5 `read_tensor` returns `(M, K)` with `K = ne0`.** `--list` prints
`blk.0.ssm_alpha.weight ... 5120x48`, and that is `M=48, K=5120`, not the other
way round. Picking a test tensor by its listed shape gets this backwards half
the time.

---

## 7. What changed

| File | Change |
|---|---|
| `rtl/matvec_int4_axi.vhd` | Bases stored as fixed 64-bit LO/HI pairs; new regs `0x68`-`0x78` (HI) and `0x7C` (`ADDR_CAP`); `ERR_ADDR` sticky at STATUS bit 4; generic-contract asserts for `ADDR_W` in 32..64 and `NPORTS_W = 4` |
| `rtl/matvec_int4_ip.vhd` | Comment only: why the default stays 32 |
| `sim/tb_matvec_int4.vhd` | `ADDR_W` and `BASE_HI` generics; bases assembled in `unsigned`; slave indexes by address slice and asserts the high half |
| `sim/tb_matvec_axi.vhd` | Same, plus `ADDR_CAP` check, HI-register programming and read-back, and the two-sided `ERR_ADDR` probe |
| `sim/run_matvec.sh` | Stage 6/7 sweep `ADDR_W`/`BASE_HI`; new stages 6b, 7b, 8, 9 |
| `tools/pack_int4.py` | `check_geometry()` / `unmet_reasons()`; `--axi-dw`; `NPORTS_W` derived; `AXI_DW` written to header `0x1E`; refuses before reading the tensor |
| `ref/matvec_int4.c` | Reads `axi_dw` (0 means 128); general invariant at `-4`, decoder limit at `-7`; C packer stamps the field; new `--emit` mode |
| `hw/mv_driver.c` | Programs the HI registers, reads `ADDR_CAP`, aborts on `ERR_ADDR` before start |
| `docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md` | Section 6.4: `0x1E` is now `AXI_DW`, with the legal geometry set stated |

The `NPORTS_W = 4` assertion in the wrapper documents a **pre-existing latent
bug** rather than a new constraint: the `when 8|9|10|11` decode was always
fixed-size, so a build with a different `NPORTS_W` would have corrupted a
neighbouring base instead of failing. It was never stated anywhere.

---

## 8. Open, not yet answered

- **The FK33 geometry is still undefined**, and deliberately so. Nothing here
  guesses at it; N3 and N4 own it. What this work adds is that a wrong guess
  now fails loudly instead of producing a file.
- **`ADDR_W` between 33 and 63 is legal and untested.** The asserts admit the
  whole range because a narrower HBM address (33 bits reaches all 8 GB) is a
  reasonable thing to want; only 32 and 64 have been run.
- **Nothing was synthesised.** The `ERR_ADDR` logic, the array-typed base
  storage and the wider slices have never been through Vivado, so their timing
  and resource cost are unknown. The array-with-static-slice form was chosen
  over a flat vector with moving slice bounds specifically to keep that safe,
  but "chosen to be safe" is not "measured".
- **Byte-identity between the two packers is still untested.** Stage 8 proves
  they *interpret* the layout identically in both directions, which covers the
  failure modes that corrupt a result. Spec 6.4 asks for byte-identical files
  and that is a stronger claim than anything measured here.
- **`tools/gen_arith.py` still does not emit the UB guard** (section 5a). The
  suite warns and backs up; it does not stop. Until the generator is fixed,
  `ref/mv4i_arith.h` will be overwritten on every run.
- **`hw/mv_driver.c` was compiled, not run.** No AXU3EG was available. The
  register sequence it now follows is the one `sim/tb_matvec_axi.vhd` executes,
  which is the intended relationship between the two, but the board has not
  seen it.
