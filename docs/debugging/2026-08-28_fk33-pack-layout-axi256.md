# Closing the FK33 pack format: ROWS_IF=48 at AXI_DW=256

## 1. The question

Verbatim, 2026-08-28:

> `tools/pack_int4.py` and `rtl/weight_streamer.vhd` can only handle AXI_DW=128
> with ROWS_IF in {1,2,4,8}. The FK33 target needs ROWS_IF=48 with AXI_DW=256
> (HBM SAXI port width). Your job is to close that gap: first by SPECIFYING the
> missing layout normatively, then by implementing it in both the packer and
> the RTL, with tests that would fail if either got it wrong.

Two named blockers, both quoted from `tools/pack_int4.py:unmet_reasons()` as it
stood before this work:

1. the sub-region byte layout is undefined at `AXI_DW != 128`, because spec 6.5
   pins the lane-to-row mapping only at 128 bits where one AXI lane is exactly
   one row's `BLOCK*4 = 128`-bit chunk, and 6.5 itself warns that "the
   ROWS_IF = 4 coincidence is load-bearing and must not be assumed elsewhere";
2. the scale region needs multiple sub-regions at `ROWS_IF = 48`
   (`48*16 = 768` bits/cycle against one 256-bit port), and
   `rtl/weight_streamer.vhd:104-110` asserted `severity failure` on it.

Hardware/build context: no board involved. GHDL mcode backend
(`ghdl -e` produces no binary; run `ghdl -r <entity>` directly),
Vivado not invoked, Python 3.10.12, GGUF
`/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf` (BF16, 17.9 GB).
Repo `llama.vhdl` branch `fpga` at `0e15aac`.

## 2. The answer

The general rule is a plain **bit slice**, and stating it that way makes the
128-bit case a corollary rather than a special case: the tile word is the
`ROWS_IF` row-chunks concatenated with row 0 at the LSB, weight sub-region `p`
carries bit slice `p` of it, and the scale region is the same construction over
a superword of `n_scale_sub * AXI_DW` bits with
`n_scale_sub = lcm(ROWS_IF*16, AXI_DW) / AXI_DW`. Under that rule the RTL's
weight merge already needed **no change whatever** -- only its comments were
pinned at 128, not its logic -- and the whole of the first blocker was a packer
problem. `ROWS_IF=48, BLOCK=32, AXI_DW=256` gives `NPORTS_W = 24`,
`n_scale_sub = 3`, **27 AXI read masters**, inside the 30 usable HBM SAXI ports.

## 3. The procedure that produced it

In this order, and the order mattered.

1. **Capture the byte-identity reference BEFORE editing anything.** Five packed
   files from the current code, at the four `ROWS_IF` values the old packer
   accepted. Without this there is nothing to prove a regression against later,
   and it cannot be reconstructed after the edit.
2. **Verify the target arithmetic independently** rather than taking
   `24 + 3 = 27` from the task statement. `48*32*4 = 6144`; `6144/256 = 24`;
   `48*16 = 768`; smallest `n` with `256n mod 768 = 0` is 3.
3. **Write the general rule, then substitute the old geometry into it and check
   it reproduces the existing normative text.** This is the step that decides
   whether the rule is right. If substitution had disagreed with 6.5's pinned
   rows, the rule would have been wrong -- the pinned rows are what real files
   and a built bitstream conform to, so they are the fixed point.
4. **Packer, then differential test against the pre-edit code.** Byte-identity
   on files first, then a direct `pack()`-versus-`pack()` differential over
   awkward shapes, which reaches cases no available tensor has.
5. **RTL.** Establish first that the weight merge was already general (read the
   assignment, not the comment); change only the scale path.
6. **Testbench with two independently written encodings of the same rule**, one
   building the memory from the slice definition and one building the expected
   value from the row definition, so that agreement is evidence and not
   tautology.
7. **Teeth check**: four one-line mutants of the DUT, each of which must make
   the testbench fail, and each of which should fail in a *predictable subset*
   of the two geometries. A mutant that fails everywhere proves less than one
   that fails exactly where it can be seen.
8. `sim/regress.sh` full run as the gate.

What each control isolates:

- The **`ROWS_IF=4 / AXI_DW=128` DUT instance** in the testbench is the control
  for the FK33 instance: it is the geometry that already worked and is already
  in a bitstream, so if it moved, the generalisation broke something real.
- The **byte-identity check** is the control for the packer: it separates
  "emits a new layout correctly" from "changed the old layout while doing so".
- The **cross-geometry crosscheck** (same tensor packed both ways, decoded, same
  `mant_sum`) is the control for the layout being *invertible* rather than
  merely self-consistent.

## 4. The evidence

### 4.1 Byte identity of the old geometries, files

```
$ for R in 1 2 4 8; do python3 tools/pack_int4.py $GGUF blk.0.ssm_alpha.weight new_alpha_r$R.mv4i --rows-if $R; done
=== DIFF ===
IDENTICAL  alpha_r1
IDENTICAL  alpha_r2
IDENTICAL  alpha_r4
IDENTICAL  alpha_r8
IDENTICAL  beta_r4
```

`blk.0.ssm_alpha.weight` and `blk.0.ssm_beta.weight` are `4096 x 32`, so
`M = 32, K = 4096, NB = 128`. 77,824 bytes each.

### 4.2 Byte identity, direct differential over shapes the model does not contain

`pack()` from the pre-edit file and from the new file, same inputs, over
`M in {1,3,7,8,15,32,33,100,257}` x `K in {1,31,32,33,64,96,1000,4096}` x
`ROWS_IF in {1,2,4,8}` at `AXI_DW=128`:

```
identical 288, differing 0
```

This is the check that reaches `K` not a multiple of `BLOCK`, `M` not a
multiple of `ROWS_IF`, and `tiles*NB` not a multiple of `GRP` -- the last being
the only place the new superword rounding could have changed a size.

### 4.3 The FK33 geometry packs, and decodes to the same numbers

```
$ python3 tools/pack_int4.py $GGUF blk.0.ssm_alpha.weight fk_alpha_r48.mv4i --rows-if 48 --axi-dw 256
  shape M=32 K=4096  (0.1M weights)
  geometry ROWS_IF=48 AXI_DW=256 BLOCK=32 -> NPORTS_W=24 n_scale_sub=3 (27 AXI read masters)
  w_exp=9  out_shift=3  NB=128
wrote fk_alpha_r48.mv4i  0.11 MB  (7.00 bits/weight)

$ python3 tools/pack_int4.py new_alpha_r4.mv4i  --crosscheck
M=32 K=4096 w_exp=9 out_shift=3 ns=5 y_exp=1 mant_sum=-25272 sat=0
$ python3 tools/pack_int4.py fk_alpha_r48.mv4i --crosscheck
M=32 K=4096 w_exp=9 out_shift=3 ns=5 y_exp=1 mant_sum=-25272 sat=0
$ for R in 1 2 8; do python3 tools/pack_int4.py new_alpha_r$R.mv4i --crosscheck; done
M=32 K=4096 w_exp=9 out_shift=3 ns=5 y_exp=1 mant_sum=-25272 sat=0
M=32 K=4096 w_exp=9 out_shift=3 ns=5 y_exp=1 mant_sum=-25272 sat=0
M=32 K=4096 w_exp=9 out_shift=3 ns=5 y_exp=1 mant_sum=-25272 sat=0
```

7.00 bits/weight is padding, not overhead growth: `M = 32` against `ROWS_IF = 48`
is one tile with 16 rows of pad. On the whole 9B model at 48/256 the packed
size is 4.709 GiB against a 4.690 GiB payload, **+0.4%**.

### 4.4 The refusal path still refuses

```
$ pack_int4.py ... --rows-if 1 --axi-dw 256
  - 6.5 invariant does not divide: ROWS_IF*BLOCK*4 = 128 bits is not a whole
    number of 256-bit ports (ROWS_IF=1, BLOCK=32)
$ pack_int4.py ... --rows-if 3 --axi-dw 384      (rc=2)
  - AXI_DW=384 is not an AXI4 data width (8, 16, 32, 64, 128, 256, 512, 1024)
$ pack_int4.py ... --rows-if 1000 --axi-dw 8
  - The sub-region offset table does not fit the 4 KB header: NPORTS_W=16000
    plus n_scale_sub=2000 is 18000 u64 entries from 0x38, ending at 144056
    bytes against 4096 (spec 6.4).
```

### 4.5 The testbench, both geometries

```
$ ghdl -r --std=08 tb_weight_streamer
ROWS_IF=4 AXI_DW=128:  15 weight words of  512 bits over  4 sub-regions,
                       15 scale groups of  64 bits over 1 sub-regions (GRP=2), 0 wrong
ROWS_IF=48 AXI_DW=256: 15 weight words of 6144 bits over 24 sub-regions,
                       15 scale groups of 768 bits over 3 sub-regions (GRP=1), 0 wrong
weight_streamer: 0 reassembly errors across both geometries
```

### 4.6 Teeth: four one-line mutants of `rtl/weight_streamer.vhd`

| mutant | change | result | fails in |
|---|---|---|---|
| m1 | `qd(p)` -> `qd(NPORTS_W-1-p)` in the weight merge | rc=1 | **both** geometries |
| m2 | `qd(NPORTS_W+q)` -> `qd(NPORTS_W+NPORTS_S-1-q)` in the superword assembly | rc=1 | ROWS_IF=48 only |
| m3 | chunk select `s_chunk` -> `GRP-1-s_chunk` | rc=1 | ROWS_IF=4 only |
| m4 | `s_take` gated on `qv(NPORTS_W)` alone instead of `s_allv` | rc=1 | ROWS_IF=48 only |

All four exit non-zero. The *pattern* is the informative part and it is what
was predicted before running: m2 cannot be seen at `n_scale_sub = 1` because
reversing a one-element list is the identity, and m3 cannot be seen at
`GRP = 1` for the same reason. That the two configurations each catch a mutant
the other cannot is the evidence that they are not testing the same thing.

Sample m2 output (note it is silent on the AXU3EG geometry):

```
tb_weight_streamer.vhd:335:13:@185ns:(report error): ROWS_IF=48 AXI_DW=256: SCALE group 0 (tile 0 block 0) reassembled wrong
tb_weight_streamer.vhd:335:13:@215ns:(report error): ROWS_IF=48 AXI_DW=256: SCALE group 1 (tile 0 block 1) reassembled wrong
```

### 4.7 Regression gate

```
 suite sim   PASS 48   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 74   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 REGRESSION: PASS
```

74 = the recorded floor of 73 plus this one new testbench. `BASELINE_PASS`
raised to 74.

## 5. Measured and REJECTED -- do not retry

**Rewriting spec 6.5's pinned rows to a "cleaner" general form.** Considered and
rejected before any edit. Those four rows describe files that exist on disk and
a bitstream that is built and timing-closed (spec 14.4b). The general rule was
therefore written as a *new* subsection 6.5a and then **validated by
substitution** against the old rows, not by replacing them. Substituting
`ROWS_IF=4, BLOCK=32, AXI_DW=128` reproduces all four verbatim: word = 512
bits with row `r` at `(r+1)*128-1 downto r*128`; `NPORTS_W = 4` and slice `p`
IS row `p`; `SW = 64` so `n_scale_sub = 1` and `GRP = 2`, which is 7.7's
`UNPACK = 2`. Had it not reproduced them, the rule would have been the thing to
change.

**Changing the weight merge in `rtl/weight_streamer.vhd`.** Attempted mentally,
then measured against the source and abandoned:
`w_data((p+1)*AXI_DW-1 downto p*AXI_DW) <= qd(p)` is *already* 6.5a's slice
rule at every `AXI_DW`. What was pinned at 128 was a **comment** asserting a
lane is a row. Do not go looking for a weight-side bug here; there is none, and
the m1 mutant exists specifically to show the line is load-bearing rather than
vestigial.

**`ROWS_IF = 80`, in any form.** `AXI_DW = 256` gives `NPORTS_W = 40` plus
`n_scale_sub = 5` = **45 masters against 30 usable HBM SAXI ports**. It is
still written into spec 6.5, 13 and 14.5, and every one of those is now marked
with a dated CORRECTION. Withdrawn by measurement in 15.2/15.3, not by opinion.

**`ROWS_IF = 58`** (floated in `rtl/matvec_core.vhd` comments). `SW = 928`,
`lcm(928,256)/256 = 29`, so `NPORTS_W = 29` **plus `n_scale_sub = 29` = 58
masters**; as raw bandwidth, `(7424+928)/256 = 32.62` ports against 30. Worse
than 80 on the scale path, because 58 is not a multiple of 16 and the scale
superword degenerates to one group per 29 beats. Do not retry.

**Deriving `NPORTS_S` inside `weight_streamer` instead of taking it as a
generic.** Rejected: what actually needs checking is that the *caller* and the
*packed file* agree on how many sub-regions the file was cut into. A derived
value cannot disagree with itself, so it would assert nothing. It is a generic
with an assert that it equals the minimal `lcm`-derived value.

**Making `unmet_reasons()` return nothing** (turning the refusal into a
pass-through). Rejected as the obvious wrong shape of this change. Three
refusals survive and all three fire (section 4.4): the 6.5 invariant must
divide, `AXI_DW` must be an AXI4 data width because `axi_rd_port` derives
`ARSIZE` from it and a 96-bit port is a file for a bus that cannot exist, and
the offset table must fit the 4 KB header.

## 6. Measurement traps hit

**`ghdl -e` succeeds and produces nothing on the mcode backend.** Known before
starting and still worth restating: a build step that "passes" here has not
built anything. Every result above comes from `ghdl -r <entity>` directly.

**The first analysis was run without `--std=08` and silently half-worked.**
`ghdl -a -frelaxed ...` reported one error on `rtl/axi_rd_port.vhd`
(`port "rready" cannot be read`) and my shell `&& echo ANALYSE OK` still
printed OK, because the error came from a pipeline stage whose exit code was
not the one tested. `ghdl -r tb_weight_streamer` then said *"cannot find entity
or configuration"* -- which reads as a testbench problem and is not one. The
repo builds this hierarchy under `--std=08` (`sim/run_matvec.sh`,
`sim/regress.sh:321`). Trap: an analysis failure downstream of a pipe looks
like a missing top-level entity.

**A commit message containing double quotes broke the shell and produced
`error: pathspec 'beats' did not match any file(s)`.** Nothing to do with git
pathspecs. Commit messages of this length go in a file and are passed with
`-F`.

**7.00 bits/weight on the FK33 test file is not a regression.** It is `M = 32`
padded up to one 48-row tile. Reading a per-weight figure off a tensor smaller
than one tile measures the padding, not the format. The whole-model `--audit`
number (+0.4%) is the one that means anything.

**Indexing a function call result** (`std_logic_vector(to_unsigned(x,4))(i)`)
is VHDL-2008 only and was avoided via an intermediate variable, so the
testbench does not silently depend on the standard it is analysed under.

## 7. Open, not yet answered

- **`ref/matvec_int4.c` still refuses `AXI_DW != 128` with code -7**, and its
  `get_scale` reads `s_sub_offset[0]` only. It therefore *refuses* an FK33 file
  rather than misreading one, which is safe, but the packer -> C -> RTL
  bit-identity chain the spec requires is currently two legs long at 256 bits,
  not three. Deliberately out of scope here; it is the obvious next task.
- **`rtl/matvec_int4.vhd` is fixed at `NPORTS_S = 1`.** It does not expose the
  generic, so `weight_streamer`'s new capability is reachable only by
  instantiating it directly (as the testbench does). Plumbing `NPORTS_S`
  through `matvec_int4` -> `matvec_int4_axi` -> `matvec_int4_ip` widens their
  AXI port vectors and touches the AXI-Lite register map's `s_base`, which is a
  separate change with its own regression surface.
- **Spec 14.5 item 3, the HBM AXI clock (~450 MHz) to core clock (~300 MHz)
  CDC, is untouched.** `weight_streamer` is single-clock. Nothing here makes it
  otherwise, and the FK33 integration must still resolve it.
- **No synthesis was run at `ROWS_IF = 48 / AXI_DW = 256`.** 27 masters, 24
  FIFOs of `DEPTH` beats at 256 bits, and a 6,144-bit `w_data` net are a
  materially different physical problem from the AXU3EG's 4 x 128. The
  simulation says the reassembly is correct; it says nothing about whether it
  places, routes or closes timing. `sim/ooc_core_sweep.tcl` is the vehicle for
  finding out.
- **`DEPTH` was not re-budgeted.** 7.7 budgets 8 KB per FIFO at
  `AXI_DW = 128, DEPTH = 512`. At 256 bits the same `DEPTH` is 16 KB per port
  and there are 27 ports. Whether that is the right trade against HBM's higher
  latency is unmeasured.
