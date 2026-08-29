# Defect C1 fixed: `attn_block`'s v_ref fold gets its LAYER dimension, and three landmarks move

**Date:** 2026-08-29. Branch `fpga`. Track C1.
**Design under test:** repository commit **`a3dc2f4`**, taken as a `git archive HEAD`
snapshot into a scratch tree, plus ONE changed file. Every number below is
measured against that snapshot or against that snapshot with
`rtl/attn_block.vhd` replaced. **Nothing is measured against the working tree**,
which at the time held TRACK NORMW's 212 uncommitted lines in
`rtl/llama_top.vhd` and its own hunks in `sim/tb_llama_top.vhd`.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado ... program`,
nothing under `hw/fk33/`, nothing opening `/dev/xdma*`. Vivado was used only for
out-of-context synthesis.

**RE-MEASURED at `8db2fa1`, after TRACK NORMW's `9f690a0` added `NORM_W_IMAGE`
to `rtl/llama_top.vhd` (+214 lines) mid-track.** All four landmark pairs in
section 2 reproduce byte for byte on a fresh `git archive HEAD` at `8db2fa1`
(`-8060 / 28506` -> `-8079 / 41907` and `-14110 / 52347` -> `-14035 / 43861`),
so NORMW's generic is inert at its `""` default and every number below stands at
both commits. **Re-measuring rather than assuming that is the whole point of the
step:** an additive generic is inert until it is not.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The questions, verbatim

From this track's brief:

> **Part 1: fix it properly.** Give `vref_r` its layer dimension. RY-ORACLE's
> scratch candidate is a starting point, not a design -- read it, and satisfy
> yourself the shape is right (`C_LAY` x `N_KVH`, and check what actually
> indexes it and when it is reset). Watch the resource cost: `attn_block` sits
> inside a design that already fails to route, so say what the extra state
> costs in registers and whether it is worth calling out.

> **Part 2: measure the hash movement, and present it as a fact rather than
> asking permission.** The published landmarks are:
>
>     tb_llama_top_real control landmark    R_X(0) = -16339  hash 92903
>     32 blocks, real weights, C_REAL       R_X(0) = -14110  hash 52347
>
> **These are expected to MOVE, and that is the correct outcome, not a
> regression** ... Your job is to state the new values, show that the movement
> is explained by C1 and nothing else, and update whatever records them.

> **Part 3: the trap RY-ORACLE flagged** ... So fixing C1 **removes** a
> mutation's detectability. Do not let that happen silently. Either extend the
> stimulus so R7 stays killed, or state explicitly and prominently that R7 is
> unkillable again and why.

And the blocker:

> `sim/tb_llama_top.vhd:802-803`'s `KV_K_BASE` / `KV_V_BASE` are **constants
> 4048 bytes apart**, so four attention layers fails elaboration ... **That file
> is now free.** Make them generics if that is what it takes.

---

## 2. The answers, up front

**PART 1. `vref_r` is now `e8_arr(0 to LAYERS*N_KVH-1)`, indexed
`lay_r*N_KVH + kvh` at all four use sites, and the spec oracle goes from 4 of 6
to 6 of 6.** The shape is `LAYERS x N_KVH`, not `C_LAY x N_KVH`: `C_LAY` is
`llama_top`'s name for the number it passes down as the block's `LAYERS`
generic, and the block must size its own state from its own generic.

The index is `lay_r`, the LATCHED layer, never the live `layer` port. That is
not cosmetic. `layer` is a descriptor field the sequencer may advance while a
job is still running, which is RULE 2 in this file's own header and the exact
shape of `llama_top`'s defect 1; `lay_r` is captured at `P_IDLE` on `start` and
is stable for the whole job, including for the combinational `ops` process that
performs site 3's alignment shift. Reset is unchanged and stays correct: both
`rst` and the rising edge of `kv_seq_rst` clear the WHOLE array to +127, which
is per SEQUENCE across every layer, which is what C spec 2.1.4 asks for.

**Resource cost, MEASURED, and it is worth calling out for the LUTs and not for
the registers.** Vivado 2023.2 out-of-context synthesis, `xcvu33p-fsvh2104-2L-e`,
`HEAD_DIM=256 N_QH=16 N_KVH=4 KV_BLOCK=32 N_ROT=64 LAYERS=8` (Qwen3.5-9B on one
card, eight attention layers):

| | before | after | delta |
|---|---|---|---|
| CLB LUTs | 153848 | 157200 | **+3352 (+2.18%)** |
| CLB Registers | 101286 | 101561 | +275 (+0.27%) |
| Block RAM tiles | 11 | 11 | 0 |
| DSPs | 298 | 298 | 0 |
| F7 Muxes | 17842 | 17853 | +11 |

**DERIVED**, the state itself is `(8*4 - 4) * 8 = 224` extra flip-flops, and the
measured +275 is that plus 51 of synthesis noise. **The registers are not the
story; the LUTs are.** The extra 3352 LUTs are the address decode: a 32-entry
8-bit array indexed by a runtime `lay_r*N_KVH + kvh` becomes a read mux and a
write demux where a 4-entry array was nearly free, and one of the reads sits in
a combinational process. 3352 LUTs is 0.76% of the VU33P's 439680, on a unit
already at 35% of the device by itself. That is small in absolute terms and it
is NOT nothing on a design that already fails to route, so TRACK PBLOCK should
know the number rather than discover it.

**PART 2. Three landmarks and their movement, each named with its
configuration. One of the two in the brief did NOT move, and that is the
control that attributes the other two.**

| # | configuration | attention layers | at `a3dc2f4` | with the C1 fix |
|---|---|---|---|---|
| A | `tb_llama_top_real` control: `BLOCKS=4 ATTN_INT=4 C_REAL ATTN_HD=16 NORM_REAL NORM_ANCHOR=false W_IMAGE=llama_top_w_b4_pool.hex NRUNS=1` | **1** | `R_X(0) = -16339 hash 92903` | **`-16339 / 92903`, UNCHANGED** |
| B | 32 blocks, real weights: the same, `BLOCKS=32`, `W_IMAGE` = the b32 pooled image | **8** | `R_X(0) = -14110 hash 52347` | **`-14035 / 43861`** |
| C | `seq`, the KV-cache row: `BLOCKS=4 ATTN_INT=2 NTOK=3 C_REAL ATTN_HD=64 KV_BLOCK=16 N_ROT=16 MAXPOS=8 KV_AXI` | **2** | `R_X(0) = -8060 hash 28506` | **`-8079 / 41907`** |
| D | 4 attention layers on the AXI path: `BLOCKS=8 ATTN_INT=2 NTOK=3` + the new region generics | **4** | `R_X(0) = -8162 hash 33155` | **`-8251 / 93838`** |

**Row A is the attribution, and it is a stronger argument than any narrative.**
`BLOCKS=4 ATTN_INT=4` has exactly ONE attention layer, so a per-layer fold and a
shared fold are the same object, and the fix cannot change a bit. It does not:
the landmark is identical AND the whole 63-record seam capture is identical, AND
that capture still equals the committed `tools/ref9b/golden/llama_top_real.txt`
record for record. Rows B, C and D have 8, 2 and 4 attention layers and all
three move. **A change that moves every multi-attention-layer configuration and
no single-layer one is C1 and cannot be anything else**, because nothing else in
the patch is conditioned on the layer index.

Row C reproduces TRACK RY-ORACLE's scratch-candidate prediction (`-8079 /
41907`) exactly, from an implementation written independently of it. Row B is
the number RY-ORACLE's sections 11 and 12 said was not obtainable in this
repository; it is, because `C_KV_AXI` defaults FALSE and the region-overlap
assert that blocked four attention layers only guards the AXI cache. Row D is
that same AXI path at four attention layers, unblocked by making the bench's
region bases generics.

**PART 3. R7 is returned to the survivor list, and that is stated here rather
than hidden. A replacement mutation, R7b, implements the defect R7's own
description names and IS killed at the existing stimulus.**

MEASURED, `cmp` of the clean capture against the R7 mutant's, at three sequence
lengths, with C1 fixed: **byte-identical at NTOK 3, NTOK 5 and NTOK 8.** More
tokens do not help and that path is closed.

The reason is measured, not argued, and it is TWO independent facts:

1. **R7 does not do what its description says.** `tok_done_i` is a LEVEL held
   until `tok_ack`, so `if rst = '1' or tok_done_i = '1' then c_seqrst <= '1'`
   takes priority over the `elsif c_srtk = '1'` clear for the entire done
   window. `c_seqrst` never returns to '0' after the first token boundary, and
   `attn_block` detects a RISING EDGE. A `report` on that edge shows the reset
   firing exactly twice in a three-token run: once from `rst`, once at the
   0->1 boundary, never again. **R7 is "reset ONCE", not "reset per token".**
2. **Even that one reset is arithmetically inert on a correct design.** A
   `report` on the fold shows every `(layer, token)` folding to the value it
   already held: layer 0 stays 0 and layer 1 stays -1 at all three tokens. A
   reset to +127 followed by a re-fold of the same records lands on the same
   number.

So R7 was only ever observable through C1's cross-layer carry, exactly as
RY-ORACLE's section 10 said.

**R7b is the fix for the coverage, and it needs no new stimulus.** It sets
`c_seqrst` on an EDGE-DETECTED `tok_done_i`, so the reset cannot go sticky and
actually fires at every token boundary. MEASURED: **KILLED(ABORT)** on both the
defective and the fixed design, and killed by the DESIGN rather than by a
checker. A v_ref reset mid-sequence leaves cached V records from earlier tokens
whose block exponents sit BELOW the re-folded reference, site 3's
`e_v[b] - v_ref` goes negative, `rtl/attn_block.vhd:1493` raises `err` on
`vsh_neg`, and the walker reports `ERR_UNIT` (x1) at step 49. Both links were
probed, not inferred: `uerr <= c_err or kv_err_i or kv_seam_bad` reports
`c_err='1' kv_err_i='0' kv_seam_bad='0'`, and inside `attn_block` only the
`vsh_neg` site fires, ten times.

**Net coverage after the fix: unchanged in count and improved in meaning.** One
row (R7) moves from KILLED to SURVIVED and is documented as a weaker mutant than
its own text claims; one row (R7b) is added that implements the described defect
and is killed. "The harness kills X" and "the harness kills X on a correct
design" are different claims and only the second is worth having.

**THE BLOCKER. `KV_K_BASE`, `KV_V_BASE` and `KV_NB` are now generics** of
`sim/tb_llama_top.vhd` (`KV_K_BASE_G`, `KV_V_BASE_G`, `KV_NB_G`), defaulting to
16 / 4064 / 8192, which are exactly the old constants, so every landmark
measured before they existed is unchanged. `KV_NB` had to join them: raising the
bases without raising the memory writes past the modelled array. A new
elaboration-time check refuses a triple that does not fit, printing all four
numbers, rather than aborting later with an index error. Row D above and an
8-token run at `MAXPOS=16` are both configurations the old constants could not
express.

---

## 3. The procedure, in the order it was run

Each step controls for exactly one thing.

1. **Read `rtl/attn_block.vhd`'s four `vref_r` use sites and `lay_r`'s
   lifetime BEFORE writing the patch.** Controls for: copying RY-ORACLE's
   scratch diff without knowing whether `lay_r` is stable in a combinational
   process. It is: latched at `P_IDLE`, held for the job.
2. **Take the baseline as `git archive HEAD`, not the working tree.**
   Controls for: TRACK NORMW's 212 uncommitted lines in `rtl/llama_top.vhd`.
   The first attempt at a run in a scratch tree failed to analyze with
   `generic "norm_w_image" is not an interface name`, which is what discovering
   this looked like.
3. **Regenerate the committed 4-block weight image from HEAD's generator and
   compare md5 before generating the 32-block one.** Controls for: a 32-block
   image built by a recipe that no longer matches the committed artefact.
   `8cd88f10114e3a74a586c8a382d0889c` both ways.
4. **Measure the ONE-attention-layer configuration first.** Controls for: a
   patch that changes something other than the layer fold. If row A had moved,
   the patch would have been wrong regardless of what the oracle said.
5. **Only then measure the 2-, 4- and 8-attention-layer rows.** Controls for:
   attributing a move to C1 without a negative control.
6. **Score the `seq` capture against `attn_oracle.py --fold perlayer`, the
   SPEC.** Controls for: declaring victory from a hash that merely moved. A
   moved hash says something changed; 6 of 6 against an independent model says
   what it changed to.
7. **Run the full `bisect_scaled.py` at all three tokens, with `--kv-block`
   and `--n-rot` taken from the run's own generics.** Controls for: a fix at
   `R_Y` that broke a seam somewhere else. 57 modelled seams, clean at every
   token.
8. **Apply R7 to the FIXED tree and `cmp` the captures.** Controls for: landing
   a fix that silently removes a mutation's teeth. It does, and this is the step
   that found it independently of RY-ORACLE's report.
9. **Lengthen the sequence to 5 and 8 tokens before writing a new stimulus.**
   Controls for: building machinery to solve a problem that more of the existing
   stimulus already solves. It does not.
10. **`report`-probe the fold and the reset edge rather than reason about
    them.** Controls for: an explanation that fits the numbers and is wrong.
    This is the step that found R7's `c_seqrst` goes sticky, which no amount of
    reading the mutation text suggested.
11. **Write R7b, and probe BOTH links of its error chain.** Controls for:
    naming a mechanism because it is the plausible one. The first attribution
    (to `attn_block`) was made on a run whose probe was never in the source --
    see trap T1 -- and only the second, verified patch established it.
12. **OOC-synthesize the unit before and after at the real 9B shape.** Controls
    for: "a few registers" as a resource claim on a design that fails to route.
13. **Full unfiltered gate.** Controls for: this track having broken something.

---

## 4. The evidence, as raw captured output

### 4.1 The patch

`rtl/attn_block.vhd`, five sites, one declaration and four indexings:

```vhdl
-  signal vref_r : e8_arr(0 to N_KVH-1)        := (others => to_signed(127, EXP_W));
+  signal vref_r : e8_arr(0 to LAYERS*N_KVH-1)
+                := (others => to_signed(127, EXP_W));
   :943   vref_r(kvh)  ->  vref_r(lay_r*N_KVH + kvh)     -- site 3's shift
   :1305  vref_r(kvh)  ->  vref_r(lay_r*N_KVH + kvh)     -- the write-time fold, read
   :1309  vref_r(kvh)  ->  vref_r(lay_r*N_KVH + kvh)     -- the write-time fold, write
   :1609  vref_r(h)    ->  vref_r(lay_r*N_KVH + h)       -- site 6f's output grid
```

The two `(others => to_signed(127, EXP_W))` resets (at `rst`, and on the rising
edge of `kv_seq_rst`) are untouched and now clear every layer's fold, which is
what per-SEQUENCE means.

### 4.2 Row A, the one-attention-layer control, byte-identical

```
$ SCRATCH=... bash tools/ref9b/capture_llama_top.sh real     # baseline tree
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run,
  1 descriptor-latency points, R_X bit-identical across all of them,
  R_X(0) = -16339 hash(R_X) = 92903

$ SCRATCH=... bash tools/ref9b/capture_llama_top.sh real     # C1-fixed tree
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run,
  1 descriptor-latency points, R_X bit-identical across all of them,
  R_X(0) = -16339 hash(R_X) = 92903

$ cmp cap_real_base.txt cap_real_fix.txt
IDENTICAL
$ diff <(grep -av '^#' cap_real_fix.txt) \
       <(grep -av '^#' tools/ref9b/golden/llama_top_real.txt)
(empty; 63 SEAM records each)
```

### 4.3 Rows B, C and D, the multi-attention-layer configurations

```
=== B, BLOCKS=32 ATTN_INT=4, 8 attention layers, real pooled Qwen weights
before: PASS -- 491 descriptors, 32 blocks, ... R_X(0) = -14110 hash(R_X) = 52347
after:  PASS -- 491 descriptors, 32 blocks, ... R_X(0) = -14035 hash(R_X) = 43861
both:   schedule mismatches=0 skew differences=0 degenerate residuals=0

=== C, the seq row, 2 attention layers, 3 tokens, KV_AXI
before: PASS -- 61 descriptors, 4 blocks, 3 tokens per run, R_X(0) = -8060 hash = 28506
after:  PASS -- 61 descriptors, 4 blocks, 3 tokens per run, R_X(0) = -8079 hash = 41907

=== D, BLOCKS=8 ATTN_INT=2, 4 attention layers, KV_AXI, the new region generics
        -gKV_V_BASE_G=8160 -gKV_NB_G=16384
before: PASS -- 119 descriptors, 8 blocks, 3 tokens per run, R_X(0) = -8162 hash = 33155
after:  PASS -- 119 descriptors, 8 blocks, 3 tokens per run, R_X(0) = -8251 hash = 93838
```

Two more configurations the old constants could not express, on the fixed tree:
`NTOK=5` gives `R_X(0) = -4222 hash 64932`; `NTOK=8 MAXPOS=16
KV_V_BASE_G=8160 KV_NB_G=16384` gives `R_X(0) = -11830 hash 87822`.

### 4.4 The spec oracle, 4 of 6 to 6 of 6

`tools/ref9b/attn_oracle.py --blocks 4 --attn-int 2 --attn-hd 64 --kv-block 16
--n-rot 16 --fold perlayer` on the `seq` capture:

```
=== a3dc2f4, unfixed
  R_Y-1  tok 1  exp 8 expected vs 8 captured, 82 of 256 mantissas differ,
                first at 12 (expected 9308, captured 9054)
  R_Y-1  tok 2  exp 8 expected vs 8 captured, 105 of 256 mantissas differ,
                first at 17 (expected 8103, captured 8089)
# 4 of 6 R_Y seams match the model bit for bit
FIRST DIVERGENCE: R_Y-1 tok 1 at element 12 -- expected 9308, captured 9054

=== the same, with the C1 fix
  ok           R_Y-1        tok 0
  ok           R_Y-3        tok 0
  ok           R_Y-1        tok 1
  ok           R_Y-3        tok 1
  ok           R_Y-1        tok 2
  ok           R_Y-3        tok 2
# 6 of 6 R_Y seams match the model bit for bit
EVERY MODELLED R_Y MATCHES ITS MODEL BIT FOR BIT, given the machine's own inputs.
```

The oracle was not moved: `perlayer` is C spec 2.1.4 and remains the default.

### 4.5 The whole 57-seam bisect on the fixed capture

`tools/ref9b/bisect_scaled.py ... --kv-block 16 --n-rot 16 --norm anchor`,
each of the three tokens:

```
# 57 seams checked against a model, 3 NOT checked
    NOT CHECKED  R_Y-0          subsystem B has no integration-level model
    NOT CHECKED  R_Y-2          subsystem B has no integration-level model
    NOT CHECKED  LOGITS         destination is R_NONE (finding D1)

EVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT, given the machine's own inputs.
```

Identical at tok 0, tok 1 and tok 2. The unfixed capture diverges at `R_Y-1`
at tok 1 and tok 2 and is clean at tok 0.

### 4.6 R7, and why it survives the fix

```
$ cmp cap_seq_fix.txt cap_seq_fix_r7.txt          # C1 fixed, NTOK=3
IDENTICAL
$ cmp cap_seq_base.txt cap_seq_base_r7.txt        # C1 present, NTOK=3
differ: byte 49243, line 619
NTOK=5, C1 fixed:  clean -4222/64932   R7 -4222/64932    IDENTICAL
NTOK=8, C1 fixed:  clean -11830/87822  R7 -11830/87822   IDENTICAL
```

The fold and reset probe, C1 FIXED, clean:

```
VREFPROBE seqrst
VREFPROBE fold lay=0 kvh=0 pos=0 old=127 new=0
VREFPROBE fold lay=0 kvh=1 pos=0 old=127 new=0
VREFPROBE fold lay=1 kvh=0 pos=0 old=127 new=-1
VREFPROBE fold lay=1 kvh=1 pos=0 old=127 new=-1
VREFPROBE fold lay=0 kvh=0 pos=1 old=0   new=0
VREFPROBE fold lay=0 kvh=1 pos=1 old=0   new=0
VREFPROBE fold lay=1 kvh=0 pos=1 old=-1  new=-1
VREFPROBE fold lay=1 kvh=1 pos=1 old=-1  new=-1
VREFPROBE fold lay=0 kvh=0 pos=2 old=0   new=0
VREFPROBE fold lay=0 kvh=1 pos=2 old=0   new=0
VREFPROBE fold lay=1 kvh=0 pos=2 old=-1  new=-1
VREFPROBE fold lay=1 kvh=1 pos=2 old=-1  new=-1
```

The same probe, C1 FIXED, with R7 applied:

```
VREFPROBE seqrst                                   <-- from rst
VREFPROBE fold lay=0 kvh=0 pos=0 old=127 new=0
VREFPROBE fold lay=0 kvh=1 pos=0 old=127 new=0
VREFPROBE fold lay=1 kvh=0 pos=0 old=127 new=-1
VREFPROBE fold lay=1 kvh=1 pos=0 old=127 new=-1
VREFPROBE seqrst                                   <-- the 0->1 boundary
VREFPROBE fold lay=0 kvh=0 pos=1 old=127 new=0
VREFPROBE fold lay=0 kvh=1 pos=1 old=127 new=0
VREFPROBE fold lay=1 kvh=0 pos=1 old=127 new=-1
VREFPROBE fold lay=1 kvh=1 pos=1 old=127 new=-1
VREFPROBE fold lay=0 kvh=0 pos=2 old=0   new=0     <-- NO seqrst before pos 2
VREFPROBE fold lay=0 kvh=1 pos=2 old=0   new=0
VREFPROBE fold lay=1 kvh=0 pos=2 old=-1  new=-1
VREFPROBE fold lay=1 kvh=1 pos=2 old=-1  new=-1
```

Two facts in one capture: the reset fires at ONE token boundary and not the
other, and every `new` equals the `old` it replaced, so even where it does fire
it changes nothing.

### 4.7 R7b, the described defect, killed

```
sim/tb_llama_top.vhd:1843:9:@104039500ps:(assertion failure):
  tb_llama_top: the walker raised err_code x1 at step 49
/usr/bin/ghdl-mcode:error: assertion failed
  ... 170 of 180 records written
```

`err_code x1` is `seq_desc_fetch`'s `ERR_UNIT`. Which unit, probed at
`rtl/llama_top.vhd`'s C adapter:

```
UERRPROBE c_err='1' kv_err_i='0' kv_seam_bad='0'
```

Which site inside `attn_block`, probed at all five `err_r <= '1'` sites:

```
     10 ERRPROBE VSHNEG
```

`rtl/attn_block.vhd:1493`, `if vsh_neg = '1' then err_r <= '1'; end if;` -- the
site-3 alignment shift `e_v[b] - v_ref` going negative, which is precisely what
a mid-sequence reset of a MINIMUM fold must cause once the cache already holds
records from earlier tokens.

### 4.8 The resource measurement

Vivado 2023.2, `synth_design -mode out_of_context -top attn_block -part
xcvu33p-fsvh2104-2L-e -generic HEAD_DIM=256 -generic N_QH=16 -generic N_KVH=4
-generic KV_BLOCK=32 -generic N_ROT=64 -generic LAYERS=8`:

```
                        before      after
  CLB LUTs              153848     157200     +3352   +2.18%
    LUT as Logic        153739     157091     +3352
    LUT as Memory          109        109         0
  CLB Registers         101286     101561      +275   +0.27%
  CARRY8                  2734       2734         0
  F7 Muxes               17842      17853       +11
  F8 Muxes                3808       3808         0
  Block RAM Tile            11         11         0
  DSPs                     298        298         0
```

---

## 5. Measured and REJECTED -- do not retry

**Killing R7 by making the sequence longer.** MEASURED at NTOK 5 and NTOK 8
(the latter needing `MAXPOS=16` and therefore the new region generics): the
clean and R7 captures are identical at both. The reason is structural and no
length fixes it -- R7's `c_seqrst` goes sticky after the first token boundary,
so a longer sequence adds boundaries at which nothing happens. Do not retry
this axis; fix the mutation instead (R7b) or accept R7 as a survivor.

**Reading `attn_oracle.py` or `bisect_scaled.py` without passing `--kv-block`
and `--n-rot` from the run's own generics.** MEASURED, and it bit this track on
its first bisect of the FIXED design: with the defaults (4 and 8) against a
capture elaborated at 16 and 16, the fixed design reports

```
  R_Y-1  exp 8 expected vs 8 captured, 41 of 256 mantissas differ, first at 16
  R_Y-3  exp 7 expected vs 7 captured, 77 of 256 mantissas differ, first at 0
```

at every token, which reads as "the fix broke it". With the right two numbers
the same capture is clean at every token. This is RY-ORACLE's trap T7 and it
has now caught two tracks. **It also found a real defect in
`sim/mutate_llama_top_kv.sh`:** its `cap_oracle_args seq` omitted both, which
was harmless while `bisect_scaled.py` had no `R_Y` model and became a permanent
false KILL on the clean control `V0s` the day it acquired one. Fixed here.

**Attributing the 32-block landmark movement to anything other than C1.**
MEASURED: the ONE-attention-layer configuration is byte-identical across the
patch, capture and all, and the 2-, 4- and 8-attention-layer configurations all
move. Do not re-open this as "maybe the weight image changed" -- the b4 image
regenerates to the same md5 (`8cd88f10114e3a74a586c8a382d0889c`) from HEAD's
generator, and the b32 image comes from that same generator invocation with
`--blocks 32`.

**Measuring any of this against the working tree.** REJECTED before it was
attempted, and the reason showed up immediately: TRACK NORMW had 212
uncommitted lines in `rtl/llama_top.vhd` and its own hunks in
`sim/tb_llama_top.vhd`, so the first scratch run died with `generic
"norm_w_image" is not an interface name`. Every tree used here is
`git archive HEAD` plus exactly the file under test.

**Hoisting site 3's `vref_r` read into a registered `vref_cur` to recover the
LUTs.** NOT ATTEMPTED, and deliberately. It would cut the read mux to one
instance, but `kvh` advances at `P_HN` and a registered copy introduces a cycle
of skew against the phase that consumes it. That is the exact shape of the
head-23 defect this block's header was written to prevent. If TRACK PBLOCK needs
the 3352 LUTs, this is the lever, and it needs its own value-oracle run.

---

## 6. Measurement traps hit, including my own

**T1. A patch script that DIED left the launcher running the UNPATCHED tree,
and the resulting null result looked like a real negative.** My first attempt to
probe `attn_block`'s five `err_r` sites used `"          err_r <= '1';"` as the
match string. With ten leading spaces that string is a SUBSTRING of the
twelve- and sixteen-space occurrences, so `s.count(old)` was 4 where the script
asserted 1, python raised, and the shell went straight on to `nohup` the capture
of a tree with no probe in it. The run completed normally and reported ZERO
probe hits, which I read as "the error does not come from `attn_block`" and
nearly wrote down. The tell was cheap and I should have used it first:
`grep -c ERRPROBE` on the SOURCE, not on the log. **A probe that fired zero
times and a probe that was never compiled produce the same log.**

**T2. `--kv-block` and `--n-rot` again, from the other side.** See section 5.
Worth restating as a trap and not only as a rejection: the wrong-but-legal value
produces `5 of 64 mantissas differ, every delta exactly 1`, which is
indistinguishable from a genuine one-LSB rounding defect. There is no signature.
Take both from the run's generics every time.

**T3. `NTOK=8` at `MAXPOS=8` aborts on the CONTEXT check, not on the KV
regions.** `rtl/llama_top.vhd:3402`, "C_CTXLEN must fit in the cache and in
POS_W". Reading that as the region-overlap blocker would have sent the region
generics after the wrong constant.

**T4. The brief predicted that BOTH published landmarks would move, and one of
them cannot.** `tb_llama_top_real` is `ATTN_INT=4` at `BLOCKS=4`, which is one
attention layer. The prediction was right about the mechanism and wrong about
that row, and a track that had "expected to move" in mind could have gone
looking for a reason its patch was incomplete. **Check a configuration's
`n_attn_blocks` before predicting anything about its v_ref.**

**T5. `pertoken` is still not a model of R7, and it is not a model of R7b
either.** RY-ORACLE recorded this for the unfixed design (its T2). With C1 fixed
the two coincide in principle, and the oracle duly reports the fixed design at
5 of 6 against `pertoken` with `R_Y-3 tok 2` naming `v_ref` 1 against -1. That
made `pertoken` look like a prediction that R7 would bite, which it is not: the
RTL under R7 never reaches that state because its reset is sticky, and the RTL
under R7b raises `err` before producing a number at all. **A fold model is a
model of an arithmetic, not of a reset's plumbing.**

**T6. Not a trap I hit, but the one this document is most exposed to.** Rows B,
C and D establish that C1's effect is real at 2, 4 and 8 attention layers, and
row A establishes that it is absent at 1. None of them establishes that the
NEW numbers are RIGHT at 8 attention layers: `bisect_scaled.py` has been run at
2 attention layers (`seq`) and 1 (`real`), never at 8, because no oracle
configuration exists there. The 6-of-6 claim is a claim about the `seq` shape.

---

## 7. NOT verified

* **That row B's new value (`-14035 / 43861`) is CORRECT.** It is measured, it
  is explained, and it is not oracle-checked: no value oracle in this
  repository runs at `BLOCKS=32`. What is established is that the design now
  matches C spec 2.1.4's fold at the shape where the model exists.
* **C1's effect at eight attention layers on the AXI cache path.** Row B is the
  behavioural cache (`C_KV_AXI` false); row D is the AXI path at four. Eight on
  AXI was not run.
* **Subsystem B's `R_Y-0` and `R_Y-2`, and `LOGITS`.** Unchanged from
  RY-ORACLE. Still no integration-level model.
* **Whether C1 could have produced a WRONG answer rather than a less precise
  one.** Unchanged from RY-ORACLE section 7: the `e_v[b] >= v_ref` invariant
  held in the defective direction, so no wrap was expected and none was seen.
  Argued, not proven. The R7b result is the other side of the same coin and is
  measured: violate that invariant and `vsh_neg` fires immediately.
* **The per-site fixed-point numerics inside subsystem C.** This work checks the
  COMPOSITION and the cache across tokens, exactly as RY-ORACLE's model does.
* **The LUT delta at any shape other than `HEAD_DIM=256 N_QH=16 N_KVH=4
  LAYERS=8`.** One synthesis point, before and after. `LAYERS` is a generic and
  the mux grows with it; a 27B two-card build with a different `LAYERS` will
  differ and was not measured.
* **Timing.** `synth_design` was run without a clock constraint, so no WNS or
  Fmax figure is claimed here in either direction. The +3352 LUTs is an area
  statement only.
* **Anything at the 9B shape in GHDL.** Unchanged: about 15 days per token.
* **`bisect_scaled.py --norm real` against a `NORM_W_IMAGE` capture.** TRACK
  NORMW reports nine false divergences pointing at `R_XN-0`. Nothing in this
  document uses that combination -- the `seq` rows are `--norm anchor` and the
  `real` rows are captures taken before `9f690a0` -- but the next track to
  bisect C anything should know.

---

## 8. Files changed

| file | what |
|---|---|
| `rtl/attn_block.vhd` | `vref_r` gains its `LAYERS` dimension; four indexings and two comments |
| `sim/tb_llama_top.vhd` | `KV_K_BASE_G` / `KV_V_BASE_G` / `KV_NB_G` generics with the old constants as defaults, an elaboration-time fit check, and the 32-block landmark's move recorded where the old value was |
| `sim/mutate_llama_top_kv.sh` | `cap_oracle_args seq` gains `--kv-block 16 --n-rot 16`; rows `R7b` and `VR7b`; R7's survival documented under its own name |

---

## 9. Appended, same day: two harness rows validated end to end, and a THIRD that had gone silently missing

Sections 2 and 4 score R7 and R7b from captures taken by hand. Run through the
harness itself, `SCRATCH=... ONLY="R7 R7b" bash sim/mutate_llama_top_kv.sh`:

```
R7   SURVIVED   -- the v_ref sequence reset is issued per TOKEN, not per sequence (C spec 2.1.4)
R7b  KILLED(ABORT) -- the run produced no RESULT line -- R7's DESCRIPTION, actually
     implemented: the v_ref fold is reset at EVERY token boundary (edge-detected, so it
     cannot go sticky the way R7 does)
```

The same run printed one line that belongs to neither row:

```
=== N: the NORM_REAL adapter, which only sim/tb_llama_top_real.vhd reaches ===
MUTATION ANCHOR MATCHED 0 TIMES, expected 1
```

**Row N1 had stopped existing and nothing said so except that line.** TRACK
NORMW's `9f690a0` made the top-level norm gain a SELECTED source, so
`w_mant => W_CONST, w_exp => NORM_W_EXP,` became `w_mant => wsel,    w_exp =>
NORM_W_EXP,` and N1's anchor no longer matched. `mutate_rtl` returns empty on a
bad anchor and the caller's `[ -n "$D" ]` then skips the row, so the harness
went from reporting a kill to reporting nothing, and BOTH its rows (N1 and its
blindness control N1x) vanished. Re-anchored, mutation unchanged, and
re-measured:

```
N1   KILLED     -- the real rmsnorm's learned-gain exponent is 20 octaves out
        tb_llama_top: ... degenerate residuals=16 ...
        tb_llama_top RESULT: FAIL
N1x  SURVIVED   -- the SAME mutation against the DEFAULT gate row, which does not
     elaborate the NORM_REAL adapter at all
```

**The general point is worth more than the row.** A textual-anchor mutation
harness decays silently every time the RTL it points into is refactored, and
the decay looks like a shorter report rather than like a failure. `mutate_rtl`'s
loud `MATCHED 0 TIMES` is the only thing standing between a stale anchor and a
mutation table that has quietly shrunk -- **read the harness's stderr, not only
its verdict lines**, and treat a row that has simply stopped appearing as a
regression in coverage.
