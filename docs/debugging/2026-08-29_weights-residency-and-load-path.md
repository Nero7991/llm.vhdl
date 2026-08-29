# The 9B weight residency map, and a load path that can be proved

**Date:** 2026-08-29
**Track:** WEIGHTS
**Tree:** `fk33` branch. Work started at HEAD `62743ce`; HEAD had moved to
`06f6793` by the time of writing (two commits from TRACK REALSHAPE). Nothing
this track touched is in either commit, so every number below is independent of
that move. The measured artefacts are the packed sets under
`/mnt/storage/llama-models/`, which are not in git at all.
**Tools:** `python3` (`tools/check_mv4i_set.py`, `tools/gen_layer_program.py`,
`tools/pack_int4.py`, and the two new files below), `du`, `df`, `free`.
**No hardware was touched.** Nothing here opened `/dev/xdma*`, and no `xsdb`,
`hw_server`, `vivado ... program`, `hw/fk33/*.sh` or `hw/fk33/tcl/*` invocation
appears anywhere in this work. The card-side flow was exercised end to end
against a **file standing in for HBM**, on `/mnt/storage`, and that file was
deleted afterwards.

**Machine, measured first:** `free -g` 31 GB total / 24 available, 27 GB swap
free. `df -h`: root 1.3 T at **95% full, 68 G free**; `/mnt/storage` 916 G at
56%, **389 G free**. Everything multi-GB in this work was done on
`/mnt/storage` and cleaned up; root was never written to.

---

## 1. The question, verbatim

> 1. **What exactly must live in HBM for 9B inference, and where.** A residency
>    map: every tensor, its packed size, its HBM base address, and the
>    arithmetic that places it. The device has 8 GiB. Say how much is used and
>    how much is spare.
> 2. **What must NOT.** Oren decided `token_embd.weight` is dropped from HBM and
>    gathered host-side into `R_X`. TRACK D-PROG independently confirmed it
>    needs ZERO descriptor jobs and that the 505-step program contains no A job
>    on it. Verify, and quantify the saving.
> 3. **The load path.** `fk33ctl.py` has `load` and `verify` subcommands.
>    Establish whether they can place the real image, what they assume, and what
>    is missing. Write whatever tooling is needed so the dispatcher can run one
>    command to load and verify the image.
> 4. **Verification that the image ON THE CARD is the image you meant.** A load
>    that reports success and places the wrong bytes is exactly this project's
>    recurring failure. `verify` must be an independent check, not a re-read of
>    what was just written by the same code path.

---

## 2. The answers, up front

**It fits, with room.** The 9B image is **4,487,442,432 B = 4.1793 GiB**, 52.24%
of the device, in **250 objects** (249 packed `.mv4i` tensors plus one 4,571,136
B F32 side blob carrying the 177 norms/biases/`ssm_a`/`ssm_conv1d`). After the
75,497,472 B GDN recurrent state and the three top-anchored host blocks, what is
left is **4,012,892,160 B = 3.7373 GiB of KV, which is 61,231 tokens of
context**. Nothing is close to the ceiling. The correct set is
`/mnt/storage/llama-models/qwen35-9b-mv4i-noembd`.

**The `token_embd.weight` drop is confirmed on both halves and is worth 572,207,104 B.**
Confirmed independently here: the 505-step token program emits **311 A jobs, of
which ZERO name `token_embd.weight`**, and all 311 are accepted. The saving is
0.5329 GiB, which buys **8,992 tokens of context, 61,311 against 52,319 on the
same set with the tensor placed** (17.19% more, MEASURED by comparing the two
manifests' own `max_context_tokens`).

**`fk33ctl.py load`/`verify` CAN place the image and CANNOT prove it.** They
take one file and one offset, so the 250-object image needs 250 hand-typed
offsets; and `verify` compares the read-back against **the local file the
operator named on the same command line**, so the same wrong pairing that
produced a wrong load reproduces itself in the check and it reports PASS. Two
new files close both gaps, neither of which touches `fk33ctl.py`:

* **`hw/fk33/host/fk33_load_weights.py`** -- `plan` / `load` / `verify` /
  `selfcheck`, driven by the manifest. `verify` **never opens a `.mv4i` file**;
  it judges the read-back against the manifest's pack-time `blake2b_128` and
  against an independently written parse of each tensor's own 4 KB header. The
  dispatcher's one command is at section 7.
* **`tools/weights_residency.py`** -- the address-space auditor. No device, no
  payload, runs in under a second on a manifest alone.

**THE FINDING THAT MATTERS, and it is new. Three allocators share this address
space and none of them can see the other two, and two of them anchor at the same
end of the device.** MEASURED/DERIVED: `gen_layer_program.py`'s default A
descriptor arena and `server/pl_backend.c::pl_derive_bases()`'s three host blocks
**collide** --

    A descriptor arena     0x1_FFFD_9000 .. 0x1_FFFF_FE00   159,232 B
    host logits writeback  0x1_FFF0_C000 .. 0x1_FFFF_E840   993,344 B   OVERLAP 153,664 B
    host D program         0x1_FFFF_F000 .. 0x2_0000_0000     4,096 B   OVERLAP   3,584 B

153,664 B of the logits writeback is **38,416 float32 logit slots, the top
15.47% of the 248,320-entry vocabulary**, sitting under the A descriptors.
Whichever writes last wins and the symptom is a wrong token, silently. Neither
tool can see it: `pl_check_bases()` has no concept of an A descriptor arena, and
`gen_layer_program.py` has no concept of the host blocks. `tools/weights_residency.py`
reports it as a FAIL and a one-flag change makes the map disjoint (section 6).

---

## 3. The residency map

MEASURED, `python3 tools/weights_residency.py /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json`:

| region | base | end | bytes | GiB | who places it |
|---|---|---|---|---|---|
| packed weights + F32 blob | `0x0` | `0x1_0B78_F000` | 4,487,442,432 | 4.1793 | `pack_model_fk33.py` |
| GDN recurrent state | `0x1_0C00_6000` | `0x1_1080_6000` | 75,497,472 | 0.0703 | `pack_model_fk33.py` |
| KV arena | `0x1_1080_6000` | `0x1_FFB0_4000` | 4,012,892,160 | 3.7373 | whatever is left |
| host R_X staging | `0x1_FFB0_4000` | `0x1_FFF0_C000` | 4,227,072 | 0.0039 | `pl_derive_bases()` |
| host logits writeback | `0x1_FFF0_C000` | `0x1_FFFF_E840` | 993,344 | 0.0009 | `pl_derive_bases()` |
| **A descriptor arena** | `0x1_FFFD_9000` | `0x1_FFFF_FE00` | 159,232 | 0.0001 | `gen_layer_program.py` |
| host D program | `0x1_FFFF_F000` | `0x2_0000_0000` | 4,096 | 0.0000 | `pl_derive_bases()` |

Plus **8,876,032 B of hole**, a single skip at `0xFF78_9000` that the
allocator inserted so `blk.29.attn_qkv.weight.mv4i` would not straddle the
`0x1_0000_0000` stack boundary. That skip is not waste in the ordinary sense:
an AXI master reading across that line does **not** fault -- the HBM IP exposes
all 32 pseudo-channel segments on every port -- so it returns the wrong bytes
and the job reports success. The hole buys a class of silent wrong answer being
impossible.

By tensor kind, MEASURED (`--per-tensor`):

| kind | n | bytes | GiB |
|---|---|---|---|
| `ffn_down.weight` | 32 | 913,178,624 | 0.8505 |
| `ffn_gate.weight` | 32 | 906,100,736 | 0.8439 |
| `ffn_up.weight` | 32 | 906,100,736 | 0.8439 |
| `output.weight` | 1 | 572,207,104 | 0.5329 |
| `attn_qkv.weight` | 24 | 456,622,080 | 0.4253 |
| `attn_gate.weight` | 24 | 228,360,192 | 0.2127 |
| `ssm_out.weight` | 24 | 228,360,192 | 0.2127 |
| `attn_q.weight` | 8 | 151,322,624 | 0.1409 |
| `attn_output.weight` | 8 | 76,120,064 | 0.0709 |
| `attn_k.weight` | 8 | 19,496,960 | 0.0182 |
| `attn_v.weight` | 8 | 19,496,960 | 0.0182 |
| `nonmatvec_f32.bin` | 1 | 4,571,136 | 0.0043 |
| `ssm_alpha.weight` | 24 | 2,752,512 | 0.0026 |
| `ssm_beta.weight` | 24 | 2,752,512 | 0.0026 |

The arithmetic that places each object is `pack_int4.packed_layout`: a file is
`4096 + sub_sz * NPORTS_W + scl_sub_sz * n_scale_sub`, with
`sub_sz = align4k(tiles * NB * AXI_DW/8)`, `tiles = ceil(M / ROWS_IF)`,
`NB = ceil(K / 32)`. At the FK33 geometry `ROWS_IF = 48`, `AXI_DW = 256`,
`NPORTS_W = 24`, `n_scale_sub = 3`. Bases are then a running 4 KB aligned
offset from 0 in GGUF tensor order, with a skip at the stack line.

**Spare:** 3.74 GiB, all of it the KV arena. There is no unallocated slack
beyond that, by construction -- the KV arena is defined as everything left.

---

## 4. What must NOT live in HBM

`token_embd.weight`, 248,320 x 4,096, **572,207,104 B packed**. The manifest
records it as dropped rather than merely absent:

```
  DROPPED  token_embd.weight  shape [4096, 248320]  would have cost 572207104 B = 0.5329 GiB
```

**Verified here, not taken on trust**, by running the token program against the
correct manifest (`tools/gen_layer_program.py --token --shape 9b --manifest ...
--x-exp 0 --stamp manifest`):

```
n_emitted 505     steps 505     a_jobs 311
a_jobs 311 ok 311 bad 0
token_embd A jobs: 0
output.weight jobs: 15
```

Zero A jobs on `token_embd.weight`, and no job of any kind refused. The 505-step
count and the 311 A-job count both reproduce TRACK D-PROG's figures exactly.

**The saving, MEASURED by comparing the two manifests' own `hbm` blocks** (the
`qkvpad` set is byte-for-byte the same pack with the tensor placed):

| | with `token_embd` | without | delta |
|---|---|---|---|
| `weights_bytes` | 5,059,649,536 | 4,487,442,432 | **-572,207,104** |
| `stack_hole_bytes` | 25,956,352 | 8,876,032 | -17,080,320 |
| `kv_base` | `0x1_33A0_3000` | `0x1_1080_6000` | |
| KV arena | 3,428,831,232 | 4,018,118,656 | **+589,287,424** |
| `max_context_tokens` | 52,319 | **61,311** | **+8,992 (+17.19%)** |

The KV gain is 589,287,424 B, **larger than the tensor** by 17,080,320 B,
because dropping it also reorders what lands at the stack boundary and shrinks
the skip hole from 25,956,352 to 8,876,032 B. That second-order effect is worth
recording; it is not obvious and it is free.

The host keeps the packed copy: `token_embd.weight.mv4i` exists in
`qwen35-9b-mv4i` and `qwen35-9b-mv4i-qkvpad`, and
`docs/debugging/2026-08-29_host-embedding-gather.md` establishes the gather is
two contiguous 4 KB reads per row.

---

## 5. The load path: what `fk33ctl.py` can and cannot do

Read at `hw/fk33/host/fk33ctl.py:581-635`. **Not modified. Not run.**

What it does right, and what the new file inherits rather than replaces:

* `/dev/xdma0_h2c_0` / `_c2h_0` are byte-addressed at the HBM address, flat
  0 .. `0x1_FFFF_FFFF`. **VERIFIED that the engine sees the same map**, which is
  the assumption the whole design rests on and which nothing had checked in one
  place: `hw/fk33/gen_pcieep.py:890-902` assigns every engine master
  `m00..m27` all 32 `HBM_MEM` segments at `-offset [expr {$s * 0x10000000}]
  -range 256M`. So `hbm_offset` in the manifest is ONE number that means the
  same thing to the loader and to subsystem A. `DMABRAM_BASE = 0x2_0000_0000`
  sits deliberately above HBM so an off-by-one host offset cannot silently land
  on it.
* `check_range` bounds every access against the 8 GiB map.
* 8 MiB `pwrite`/`pread` chunking with short-write retry.

What is missing, in order of how much it costs:

1. **One file, one offset.** The image is 250 objects. Nothing reads the
   manifest, so the offsets would be typed.
2. **`verify` is not independent.** It compares HBM against the file the
   operator named. The operator names both the file and the offset, so a
   mis-pairing verifies clean. Concretely: loading `blk.14.ffn_up` at
   `blk.14.ffn_gate`'s base and then running `fk33ctl.py verify
   blk.14.ffn_up.weight.mv4i --offset <ffn_gate's base>` PASSES.
3. **No placement preflight.** A load is minutes; a misaligned or overlapping
   base is a second to detect and is detected only after the fact, if at all.
4. **`MAXROWS_BFP` and the geometry are nowhere in the loop.** Nothing checks
   that the tensor at a base is the shape the descriptors will assume.

**A correction to my own brief:** the brief said `fk33ctl.py load --verify`
should be established as "can it place the real image". It can, one object at a
time, and the read-back check it performs is a genuine transport check --
H2C wrote and C2H read, two different DMA engines, and
`docs/debugging/2026-08-28_fk33-9b-full-weight-pack.md` already used it to move
a 572 MB tensor at 0.74 GB/s. The gap is not the transport. It is that the
comparison target is chosen by the same hand that chose the destination.

---

## 6. The collision at the top of HBM

This is the part that changes something.

`gen_layer_program.py:980-988` allocates the A descriptor arena itself, with an
explicit comment saying it has to because nothing reserves the space:

```python
# Nothing in the manifest reserves descriptor space.  Take it from the
# TOP of HBM, aligned down, and state the cost.
need = 512 * max(1, sum(1 for st in sel if st.opcode == OP_A_JOB))
desc_base = (size - need) & ~0xFFF
```

MEASURED from the generated program: `desc_addr` runs `0x1FFFD9000` to
`0x1FFFFFC00`, 311 descriptors, 159,232 B.

`server/pl_backend.c:192-220` allocates the host's three blocks, also top-down
from the top of HBM. DERIVED by re-implementing its arithmetic from
`server/fk33_seam.h`'s `fk33_x_stride`/`fk33_l_stride` at `n_embd = 4096`,
`n_vocab = 248320`, `max_chunk = 512`:

```
x_stride 8256   l_stride 993344
x  0x1ffb04000 .. 0x1fff0c000  (4227072 B)
l  0x1fff0c000 .. 0x1ffffe840  (993344 B)
D  0x1fffff000 .. 0x200000000  (4096 B)
host blocks span 5226496 B = 79.75 KV tokens
A  0x1fffd9000 .. 0x1fffffe00  (159232 B)
A vs D page  : 3584 B
A vs logits  : 153664 B
A vs x       : 0 B
logit slots lost: 38416
```

Those three base addresses reproduce
`docs/debugging/2026-08-29_host-embedding-gather.md`'s stated
`x 0x1FFB04000 / l 0x1FFF0C000 / desc 0x1FFFFF000` exactly, which is the check
that the re-derivation is faithful.

`pl_check_bases()` refuses a base that lands below the weight image's
`reserved_end`, and checks the three host blocks against each other. It has no
concept of an A descriptor arena, so it cannot refuse this. `gen_layer_program.py`
has no concept of the host blocks. **Producer-versus-producer agreement is not
evidence, and here the two producers do not even communicate.**

`tools/weights_residency.py` models all three in one picture and reports:

```
FAIL  OVERLAP: <host logits writeback> 0x1_fff0_c000..0x1_ffff_e840 and <A descriptor arena> 0x1_fffd_9000..0x1_ffff_fe00 share 153664 bytes
FAIL  OVERLAP: <A descriptor arena> 0x1_fffd_9000..0x1_ffff_fe00 and <host D program> 0x1_ffff_f000..0x2_0000_0000 share 3584 bytes

2 FAIL
```

**The fix is one flag and costs 3 tokens of context.** Put the A arena
immediately below the host blocks rather than above them:

    gen_layer_program.py ... --desc-base 0x1FFADD000

MEASURED, `weights_residency.py --desc-base 0x1FFADD000`:

```
kv 4,012,732,416 = 3.7371 GiB -> 61229 tokens of context
note: KV arena shortened to 0x1_ffad_d000 by the top-anchored reservations: 5,386,240 B = 82 tokens

PASS  every region is aligned, in range, in one stack, and disjoint
```

61,231 -> 61,229 tokens. **That is not the decision, though; it is the
workaround.** The decision is who owns the number, and it is the same question
`docs/debugging/2026-08-29_layer-descriptor-program.md` section 9 already
raised and left open: either `pack_model_fk33.py` reserves a named descriptor
region in the manifest and both consumers read it, or `pl_derive_bases()` grows
a fourth block and `gen_layer_program.py` is told the base rather than choosing
one. Until one of those happens, **the `--desc-base` flag must be passed on
every invocation and its value must be checked against
`pl_derive_bases()`'s `x_base`**, which is exactly the kind of coupling a
manifest field exists to remove.

**A one-token correction to `2026-08-29_host-embedding-gather.md` section 6.2.**
It states the host blocks take `max_context_tokens` 61,311 -> **61,232**, by
charging `floor(5226496 / 65536) = 79` tokens. The arena is shortened to
`x_base`, so what is actually lost is the whole 5,226,496 B including the 0.75
of a token slot at the end: `floor(4018118656 - 5226496) / 65536 =` **61,231**.
One token. Recorded because the number appears in a capacity claim.

---

## 7. The one command for the dispatcher

Load and verify the whole image, from a card that has been through
`fk33ctl.py id` / `vccint` / `selftest`:

```bash
python3 hw/fk33/host/fk33_load_weights.py load \
    /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json \
    --verify --progress
```

Before that, and worth its one second, because it needs neither the card nor the
4.5 GB:

```bash
python3 tools/weights_residency.py \
    /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
python3 hw/fk33/host/fk33_load_weights.py plan \
    /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
```

To re-check a card that was loaded earlier, with no image on the machine at all:

```bash
python3 hw/fk33/host/fk33_load_weights.py verify \
    /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json --headers-only   # ~1 MB, instant
python3 hw/fk33/host/fk33_load_weights.py verify \
    /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json --progress       # full
```

**Expected wall time on the card, ESTIMATE.** Assumption: the first-light
figures hold (`docs/debugging/2026-08-28_fk33-first-light.md`: H2C 3.27 GB/s,
C2H 1.11 GB/s) and host-side blake2b-128 runs at the 1.00 GB/s already measured
in `2026-08-28_fk33-9b-full-weight-pack.md`. Load is serialised disk-read +
hash + H2C, so `1/(1/2.0 + 1/1.00 + 1/3.27) = 0.55 GB/s` -> **~8 s**. Full
verify is serialised C2H + hash, `1/(1/1.11 + 1/1.00) = 0.53 GB/s` -> **~8.5 s**.
Neither is worth optimising.

---

## 8. Why `verify` here is an oracle and `fk33ctl.py verify` is not

`hw/fk33/host/fk33_load_weights.py verify` **never opens a `.mv4i` file.** It
reads the manifest and the card, and nothing else. The image can be deleted or
on another machine. It is therefore structurally impossible for it to re-read
what `load` just wrote through the same path, which is the property the brief
asked for and which no amount of care in a byte-compare can supply.

It has two independent artefacts and they catch different things.

**Artefact 1, the pack-time digest.** `manifest.json` carries `blake2b_128` per
object, computed by `pack_model_fk33.py` from the packed bytes at pack time. The
read-back is hashed and compared to it. A tensor at another tensor's base fails.
A byte flipped in flight fails. A stale image from a previous pack fails.

**Artefact 2, each tensor's own 4 KB header.** The sub-region offset table at
`0x38` is what `tools/gen_layer_program.py` reads to build every descriptor, and
no generator wrote it into the manifest. The header is read back **from the
card** and parsed by a parser written in `fk33_load_weights.py` from the spec
6.4/6.5a byte offsets, deliberately NOT importing `tools/pack_int4.py` -- sharing
the packer's arithmetic would make the two incapable of disagreeing, which is
the `m7 mutant` failure CLAUDE.md records. It checks `M`, `K`, `w_exp`,
`out_shift`, `ROWS_IF`, `NPORTS_W`, `BLOCK`, `AXI_DW`, `scale_offset`,
`n_scale_sub` and every one of the 27 sub-region offsets, against the manifest
entry AND against the geometry re-derived from first principles.

**The re-derivation was checked against the packer over the whole set before
being trusted** (MEASURED, one-off script): `_packed_layout` agreed with
`pack_int4.packed_layout` on all **249 tensors, 0 mismatches**, and on a sweep
of 7 `ROWS_IF` x 3 `AXI_DW` geometries, **0 mismatches** in `NPORTS_W` and
`n_scale_sub`. Two implementations that agree are not evidence of correctness,
but two implementations that DISAGREE would have made the header check
worthless, so the agreement is a precondition rather than a result.

---

## 9. Evidence: the checks were shown to fail

### 9.1 `fk33_load_weights.py selfcheck` -- 16 rows, no card, no image

MEASURED (`python3 hw/fk33/host/fk33_load_weights.py selfcheck`, rc 0):

```
mutation                                                   expect  caught  verdict
BASELINE clean image (must PASS)                             PASS      no  ok
BASELINE clean image, headers only (must PASS)               PASS      no  ok
M1 one payload byte flipped                                  FAIL     yes  ok
M2 one header byte flipped (M)                               FAIL     yes  ok
M3 magic destroyed                                           FAIL     yes  ok
M4 tensor 0 written over tensor 1's base                     FAIL     yes  ok
M5 tensor 0 written over tensor 1's base, headers only       FAIL     yes  ok
M6 image truncated at the top                                FAIL     yes  ok
M7 sub-region offset table entry altered                     FAIL     yes  ok
M8 one payload byte flipped, headers only (EXPECTED NOT TO BITE)     PASS      no  ok
M9 whole image shifted by one 4 KB page                      FAIL     yes  ok
M10 whole image shifted, headers only                        FAIL     yes  ok
M11 two DIFFERENT-shape tensors swapped                      FAIL     yes  ok
M12 two different-shape tensors swapped, headers only        FAIL     yes  ok
M13 two IDENTICAL-shape tensors swapped                      FAIL     yes  ok
M14 two identical-shape tensors swapped, headers only (EXPECTED NOT TO BITE)     PASS      no  ok

PASS  every check was shown to fail on a defect it claims to catch
```

### 9.2 The two rows that do NOT bite, and why they are the most useful rows

**M8: `--headers-only` cannot see a payload byte.** It reads 4 KB per object.
That is its definition, not a defect, and it is why the full digest verify
exists.

**M14: `--headers-only` cannot tell two tensors of the same
`(M, K, w_exp, out_shift)` apart, and at 9B that is nearly all of them.**
MEASURED over the shipping manifest: **246 of 249 packed tensors are in a class
of size > 1**; there are only 21 distinct `(M, K, w_exp, out_shift)` tuples,
the largest class having 37 members. So a same-class swap is invisible to the
header pass by construction. **This is the resolution floor of `--headers-only`
and it is large.** Run it as a fast screen, never as the verdict.

### 9.3 The same-class swap, on the REAL image

Not synthetic. The full 4.49 GB image was loaded into an 8 GiB sparse file on
`/mnt/storage` standing in for HBM, then `blk.14.ffn_gate.weight.mv4i` and
`blk.14.ffn_up.weight.mv4i` -- both 28,315,648 B, both `(12288, 4096, 9, 3)` --
were swapped in place. MEASURED:

```
=== headers-only over the WHOLE image (does it bite?)
249 headers parsed and matched, 0 payload digests matched
PASS  the image on the card is the image the manifest describes
  rc=0
=== full over the WHOLE image
read 4,488,462,336 bytes in 4.78 s = 0.94 GB/s
249 headers parsed and matched, 248 payload digests matched
FAIL  blk.14.ffn_gate.weight.mv4i @ 0x23cea000: HBM hashes to 0500c3becce6e1630ae2ad0a9e0bde05, the manifest's pack-time digest is 818bfaecf77c5fcef59731658fdc83fd -- the bytes on the card are NOT this tensor
FAIL  blk.14.ffn_up.weight.mv4i @ 0x257eb000: HBM hashes to 818bfaecf77c5fcef59731658fdc83fd, the manifest's pack-time digest is 0500c3becce6e1630ae2ad0a9e0bde05 -- the bytes on the card are NOT this tensor
2 FAIL
  rc=1
```

The two digests are visibly transposed, which names the defect rather than
merely detecting it. **Structure is not values, on real data.** A single flipped
payload byte at `0x23d09240` was caught the same way.

### 9.4 The clean run, on the REAL image

MEASURED end to end against the file standing in for HBM:

```
loading 250 objects, 4.49 GB, H2C /mnt/storage/tmp-track-weights/fake_hbm.bin
   250/250    4.49 GB   0.52 GB/s
wrote 4,487,442,432 bytes in 8.56 s = 0.52 GB/s
PASS  every object written and its source bytes match the manifest digest

verifying 250 objects against the manifest (headers only)
read 1,019,904 bytes in 0.00 s = 0.44 GB/s
249 headers parsed and matched, 0 payload digests matched
PASS  the image on the card is the image the manifest describes
   (real 0m0.033s)

verifying 250 objects against the manifest (full read-back)
read 4,488,462,336 bytes in 5.15 s = 0.87 GB/s
249 headers parsed and matched, 250 payload digests matched
PASS  the image on the card is the image the manifest describes
```

**All 250 source digests matched the manifest**, which is `check_mv4i_set.py
--full`'s payload check obtained as a by-product, from a second implementation.
`tools/check_mv4i_set.py` (structural, without `--full`) also PASSES on the set:

```
1 tensor(s) declared dropped and confirmed absent from the image: token_embd.weight (572207104 B)
249 packed tensors + 1 F32 side file, 4487442432 bytes total
PASS  every header, size, sub-region offset and HBM placement is as spec 6.4/6.5a requires
```

The rates above are **not card rates**: both ends were NVMe and the page cache
was warm. Section 7 has the card estimate.

### 9.5 `tools/weights_residency.py` -- 12 rows, mutating the manifest

MEASURED (one-off script, manifest copies in the scratchpad):

```
mutation                                                  expect  caught  verdict
BASELINE (must PASS)                                        PASS      no  ok
R1 one tensor base +1 (unaligned)                           FAIL     yes  ok
R2 one tensor base -4096 (overlaps its predecessor)         FAIL     yes  ok
R3 an object straddling the 4 GiB stack boundary            FAIL     yes  ok
R4 a tensor stack field flipped                             FAIL     yes  ok
R5 hbm.weights_bytes off by 4096                            FAIL     yes  ok
R6 hbm.max_context_tokens off by one                        FAIL     yes  ok
R7 hbm.stack_hole_bytes zeroed                              FAIL     yes  ok
R8 an f32 sub-entry offset made unaligned                   FAIL     yes  ok
R9 an f32 sub-entry hbm_offset moved                        FAIL     yes  ok
R10 a payload digest corrupted (EXPECTED NOT TO BITE)       PASS      no  ok
R11 two same-size tensors swapped in place (EXPECTED NOT TO BITE)    PASS      no  ok

rows behaving as designed: 12 of 12
```

**R10 and R11 are the resolution floor of the address auditor and are the point
of the file's division of labour.** It is about ADDRESSES. It cannot see a wrong
payload and it cannot see two same-size tensors exchanged, because neither
changes any address. Those are `fk33_load_weights.py verify`'s job (9.3) and
`check_mv4i_set.py --full`'s job on disk.

### 9.6 The loader refuses before writing

MEASURED, on a manifest whose objects were made to overlap:

```
FAIL  OVERLAP: blk.14.ffn_gate.weight.mv4i 0x23cea000..0x257eb000 and blk.14.ffn_up.weight.mv4i 0x257ea000..0x272eb000
251 FAIL -- refusing to write anything
rc=1
```

`FK33_H2C` was pointed at a nonexistent path for that run, and no error came
from opening it, which is the proof that the preflight completes before the
device is touched.

---

## 10. Measured and REJECTED -- do not retry

* **`fk33ctl.py verify` as the load oracle. REJECTED.** Read at
  `hw/fk33/host/fk33ctl.py:613-635`. It byte-compares HBM against a file the
  operator names alongside the offset, so a mis-pairing verifies clean. It is a
  correct and useful TRANSPORT check and should keep being used as one. It is
  not an answer to "is this the image I meant". Do not extend it into one; the
  independence has to come from not having the file, which is a different
  program.
* **`--headers-only` as the verdict. REJECTED, with a number.** 246 of 249
  packed tensors share their entire header with at least one sibling (21
  distinct `(M, K, w_exp, out_shift)` classes, largest 37). MEASURED on the real
  image: swapping `blk.14.ffn_gate` and `blk.14.ffn_up` PASSES `--headers-only`
  and FAILS the full verify. Use it as a 33 ms screen for wrong-base and
  wrong-shape errors, never as the answer.
* **Importing `tools/pack_int4.py` into the verifier. REJECTED before it was
  written.** It would make the header check and the packed file incapable of
  disagreeing. The arithmetic is re-derived instead, and the re-derivation was
  cross-checked against the packer over 249 tensors and 21 geometries as a
  precondition (section 8).
* **`qwen35-9b-mv4i-stackfix` and `qwen35-9b-mv4i` as the image. REJECTED.**
  `stackfix` (2026-08-28 21:55) predates the qkv segment pad and still contains
  `token_embd.weight`; `qwen35-9b-mv4i` is the original 4.8 G unpadded set with
  48 of 311 A jobs unexpressible. The correct set is **`qwen35-9b-mv4i-noembd`**
  (2026-08-29 11:50), which symlinks the padded `attn_qkv` files from `-qkvpad`
  and the rest from the base set. Its `manifest.json` declares both
  `qkv_segment_pad: true` and the dropped tensor.
* **Running `gen_layer_program.py` without `--manifest`. REJECTED, and it is
  the recorded trap.** The default is the pre-QKV-pad set and 48 of 311 A jobs
  are refused. With `--manifest` pointed at `-noembd`: **311 of 311 accepted**.
* **Reserving descriptor space by moving `kv_base` up. NOT TAKEN.** It would
  make the manifest describe an allocation that the KV allocator, which does not
  exist as code, would then have to honour. The narrow fix is `--desc-base`; the
  right fix is a named region in the manifest that both consumers read. That is
  a decision, recorded in section 6, not something this track should pick.

---

## 11. Measurement traps hit

* **The four packed sets are LAYERED BY SYMLINK and `du -sh` lies about them.**
  `du -sh` reports `qwen35-9b-mv4i-noembd` as **1.2 M** and
  `qwen35-9b-mv4i-qkvpad` as **437 M**, because 250 of 252 and 227 of 254 of
  their entries respectively are symlinks into the 4.8 G base set. The real
  image is 4.5 GB in
  every case. Anyone sizing a copy off `du` will under-provision by 3,700x. Use
  the manifest's `weights_bytes`, or `du -shL`.
* **I got `fk33_l_stride` wrong on the first pass** and computed the logits
  buffer at 496,704 B instead of 993,344 B, by using `2 * n_vocab` where
  `server/fk33_seam.h:258` says `4 * n_vocab` (float32 logits, not int16). The
  error was caught only because the resulting `x_base`/`l_base` did not
  reproduce the three addresses
  `docs/debugging/2026-08-29_host-embedding-gather.md` already records. **A
  re-derivation with no independent anchor to land on would have shipped the
  wrong overlap number.** The anchor is what made it a check.
* **`grep -c token_embd` in the `-noembd` directory returns 0 and that is not
  proof of the drop.** The directory listing says nothing about what the program
  reads. The proof is the 311 A jobs containing none.
* **A `tail`-ed pipeline reports the wrong exit code.** Several runs here read
  `rc=0` on a genuine FAIL because `$?` was `tail`'s. Every verdict in this
  document was re-read from the `N FAIL` line or from `${PIPESTATUS[0]}`.
* **The offline rates are not card rates.** 0.52 GB/s load and 0.87 GB/s verify
  were measured NVMe-to-NVMe with a warm page cache; they bound the host-side
  hashing, not the DMA. Section 7's card figures are an ESTIMATE built on the
  first-light H2C/C2H numbers and are labelled as such.

---

## 12. Open, not determined here

* **Who owns the descriptor arena's base.** Section 6. It is a decision between
  a manifest field and a fourth `pl_derive_bases()` block, and both consumers
  have to be changed either way. Until then `--desc-base 0x1FFADD000` is
  mandatory on every `gen_layer_program.py` invocation and is not enforced
  anywhere.
* **Nothing verifies that the GDN state region and the KV arena are ever
  WRITTEN.** They are declared in the manifest and reserved by address; no code
  in this tree allocates within them. The residency map checks they do not
  collide, which is all it can check.
* **The flat layout is not port-local, and this track did not change that.**
  `pack_model_fk33.py`'s own docstring says it: subsystem A reads each tensor
  with 27 masters, a stack offers at most 15 engine ports, so at least 12 of the
  27 read cross-stack on every tensor. The straddle rule removes the silent
  wrong answer; it does not make the layout local. The 27-lane arena layout
  needs a build-time lane-to-port-to-stack table no bitstream in this repo has.
* **`x_exp` is still a hole.** `gen_layer_program.py` needs it and it is a
  per-token runtime value. The `--x-exp 0` used to count A jobs here is a
  placeholder and says nothing about a real run.
* **No arithmetic claim is made about the model.** This track verified that the
  right BYTES are at the right ADDRESSES. Whether the numbers they produce are
  Qwen3.5-9B's numbers is `ref9b`'s question and is untouched here.
