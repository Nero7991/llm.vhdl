# Packing the entire Qwen3.5-9B weight set for the FK33

## 1. The question, verbatim

> Pack the entire Qwen3.5-9B weight set for the FK33, durably.
>
> Source GGUF: `/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf` (BF16, 17.9 GB).
> Output directory: `/mnt/storage/llama-models/qwen35-9b-mv4i/`.
>
> Enumerate what to pack, reproducing the classification from `audit()` in the packer.
> Pack all 250 matvec tensors at `--rows-if 48 --axi-dw 256`. Handle the non-matvec 177 too,
> and document how they are carried. Produce a 4 KB aligned load manifest. Verify a sample end
> to end on the real card. State whether the packer's error numbers matched between geometries.

**Date:** 2026-08-28.
**Hardware:** SQRL FK33, VU33P, PCIe Gen3 x4, `10ee:9034`, fabric build `0x20260827`,
VCCINT 0.7159 V (wiper 68, untouched by this work), die 35.3 C. Host: this workstation,
Python 3.10.12, numpy, `gguf-py` from `/mnt/storage/llama-dflash2-src`.
**Symptom numbers to reproduce:** `--audit --rows-if 48 --axi-dw 256 --cards 1` reports
427 tensors, 250 matvec, 4.709 GiB packed, 58.9% of 8 GiB, +0.4% format overhead.

## 2. The answer

All 250 matvec tensors packed at ROWS_IF=48 / AXI_DW=256 in **27 min 32 s** on one core to
**5,056,995,328 B = 4.7097 GiB = 58.87% of the card's 8 GiB**, leaving **3.290 GiB** of
headroom (3.220 GiB after the 72 MB GDN recurrent state, i.e. 52,756 tokens of KV); the
packer's reconstruction error is **bit-identical between `4/128` and `48/256`** on all three
tensors tested, confirming 6.5a is a pure layout permutation; and three tensors of three
different shapes loaded into HBM and read back **byte-identical** on the real card.

The 177 non-matvec tensors are carried in **one contiguous F32 side file**,
`nonmatvec_f32.bin` (4,571,136 B, 177 entries, each 4 KB aligned inside it). **That layout is
a decision made here, not something the spec dictates** -- see SS5.

## 3. The procedure, in the order it was run

Each step is chosen so a failure localises itself; the hardware is touched only at the end and
only over `/dev/xdma*`.

| # | Probe | What it isolates |
|---|---|---|
| 1 | `pack_int4.py --audit --rows-if 48 --axi-dw 256 --cards 1` | The target totals, BEFORE writing a byte. If the audit and the packed set later disagree, one of them re-derived something. |
| 2 | `pack_int4.py --list` piped through `sed 's/blk\.[0-9]*\./blk.N./' | sort -u` | The tensor ARCHETYPES (23 of them), so the 427 can be reasoned about as 23 shapes rather than 427 names. |
| 3 | Lift `is_matvec()` and `tensor_as_mk()` out of `pack_int4.py` | Makes the classification and the (M,K) convention single-authority so the model packer cannot drift from `--audit`. Re-ran step 1: byte-identical output, so the refactor is neutral. |
| 4 | `pack_model_fk33.py --only blk.1.ffn_gate` | One tensor end to end, to time the job before committing an hour to it. 9.9 s for 50.3 M weights = 0.197 s/M, so 8.95 B weights is ~30 min. Serial, not parallel: the estimate said parallelism was not needed and the two 1.017 B-weight tensors peak at ~10 GB RSS each. |
| 5 | Full run under `/usr/bin/time -v`, detached with `setsid nohup` | The whole set plus peak RSS. |
| 6 | `pack_int4.py --verify` on 3 shapes x 2 geometries | Whether 6.5a touched the arithmetic. The control is that `quantize()` takes no geometry argument at all, so the numbers MUST match; measuring it is what turns that from an argument into a fact. |
| 7 | `check_mv4i_set.py` (new) on the real set | Every header, size, sub-region offset and HBM placement against `packed_layout` re-derived independently. |
| 8 | The same checker against FOUR deliberately corrupted trees | Whether the guard has teeth. It did not, on one of the four. See SS7. |
| 9 | `fk33ctl.py load --offset <manifest offset> --verify` on 3 shapes | The file -> DMA -> HBM -> read-back chain, bit-exact. |
| 10 | `fk33ctl.py load` on the 572 MB `output.weight`, then blake2b timed alone | Whether the load rate is DMA-bound. It is not. See SS7. |

Before every `fk33ctl.py` call: `fuser /dev/xdma0_user /dev/xdma0_h2c_0 /dev/xdma0_c2h_0`
returned no holders, and `fk33ctl.py id` returned the magic. No JTAG, no `pcieep.sh`, no
`xsdb`, no hardware manager, no `vccint`.

## 4. The evidence

### 4.1 The pack

```
model    /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
outdir   /mnt/storage/llama-models/qwen35-9b-mv4i
geometry ROWS_IF=48 AXI_DW=256 BLOCK=32 -> NPORTS_W=24 n_scale_sub=3 (27 AXI read masters)
tensors  427 total, 250 matvec, 177 kept F32
wrote nonmatvec_f32.bin  4571136 bytes, 177 tensors, 0.1 s
[1/250] output.weight M=248320 K=4096 w_exp=8 out_shift=3 572207104 B 4.501 bpw 191.2 s
...
[250/250] blk.9.ssm_out.weight ...

wrote /mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json
  weights          5056995328 B  4.710 GiB  (58.9 % of 8 GiB)
  GDN state        72.0 MB at 0x12d6ba000
  free for KV      3.220 GiB from 0x131eba000 => 52756 tokens of context
  total elapsed    1643.6 s

	Elapsed (wall clock) time (h:mm:ss or m:ss): 27:31.69
	Maximum resident set size (kbytes): 12163272
	Exit status: 0
```

Aggregates read back out of the manifest:

```
matvec files         250 5052424192 B  4.7054 GiB
matvec weights       8952741888  -> 4.5148 bits/weight
f32 side file        4571136 B, 177 tensors, base 0x12d25e000
f32 payload (no pad)  4245504
TOTAL                5056995328 B  4.7097 GiB  = 58.87% of 8 GiB
headroom over weights 3.2903 GiB
after GDN 72 MB       3.2200 GiB -> 52756 tokens @ 65536 B/token
```

`w_exp` is per tensor and `out_shift` is a pure function of K (spec 7.4), which the spread
confirms -- every K=4096 tensor got `out_shift=3` and every K=12288 tensor got 5, with no
exceptions across 250 tensors:

```
  M=12288   K=4096   n=64   w_exp=[7, 8, 9]      out_shift=[3]
  M=4096    K=4096   n=56   w_exp=[6, 7, 8, 9]   out_shift=[3]
  M=32      K=4096   n=48   w_exp=[8, 9, 10]     out_shift=[3]
  M=4096    K=12288  n=32   w_exp=[7, 8]         out_shift=[5]
  M=8192    K=4096   n=32   w_exp=[7, 8, 9]      out_shift=[3]
  M=1024    K=4096   n=16   w_exp=[7, 8, 9]      out_shift=[3]
  M=248320  K=4096   n=2    w_exp=[8]            out_shift=[3]
```

### 4.2 Geometry invariance of the arithmetic

Same tensor, both geometries, `--verify`:

```
=== blk.0.attn_qkv.weight  ROWS_IF=4 AXI_DW=128 ===
  weight reconstruction: max 3.584e-02 (9.61% of max|w|), RMS 8.02% relative
  matvec vs float32:     RMS rel 8.11%, cosine 0.996714
=== blk.0.attn_qkv.weight  ROWS_IF=48 AXI_DW=256 ===
  weight reconstruction: max 3.584e-02 (9.61% of max|w|), RMS 8.02% relative
  matvec vs float32:     RMS rel 8.11%, cosine 0.996714
=== blk.0.ffn_gate.weight  ROWS_IF=4 AXI_DW=128 ===
  weight reconstruction: max 1.336e-02 (4.68% of max|w|), RMS 8.03% relative
  matvec vs float32:     RMS rel 8.02%, cosine 0.996782
=== blk.0.ffn_gate.weight  ROWS_IF=48 AXI_DW=256 ===
  weight reconstruction: max 1.336e-02 (4.68% of max|w|), RMS 8.03% relative
  matvec vs float32:     RMS rel 8.02%, cosine 0.996782
=== blk.0.ffn_down.weight  ROWS_IF=4 AXI_DW=128 ===
  weight reconstruction: max 3.467e-02 (5.31% of max|w|), RMS 8.06% relative
  matvec vs float32:     RMS rel 8.05%, cosine 0.996756
=== blk.0.ffn_down.weight  ROWS_IF=48 AXI_DW=256 ===
  weight reconstruction: max 3.467e-02 (5.31% of max|w|), RMS 8.06% relative
  matvec vs float32:     RMS rel 8.05%, cosine 0.996756
```

Identical to the last printed digit on all three, at RMS ~8.0% and cosine ~0.9967 as expected.
Only the file SIZE differs (18.88 MB at 4/128, 18.92 MB at 48/256 for `attn_qkv`), which is the
extra 4 KB alignment slack of 27 sub-regions against 5.

### 4.3 The structural checker, and the corrupted controls

```
### CONTROL, good tree, --full
250 packed tensors + 1 F32 side file, 5056995328 bytes total, 251 payloads hashed and matched
PASS  every header, size, sub-region offset and HBM placement is as spec 6.4/6.5a requires
rc=0

### CASE 1: one byte flipped in the header (AXI_DW field at 0x1E)
rc=1
FAIL blk.0.ssm_alpha.weight.mv4i: header ROWS_IF/BLOCK/AXI_DW 48/32/384, want 48/32/256

### CASE 2: file truncated by one 4 KB page
rc=1
FAIL blk.0.ssm_alpha.weight.mv4i: on disk 110592 bytes, manifest 114688
FAIL manifest weights_bytes 5056995328, files on disk sum to 5056880640
FAIL manifest counts.matvec 250, 249 .mv4i entries checked

### CASE 4: manifest HBM offset made non-4KB-aligned
rc=1
FAIL blk.15.ffn_down.weight.mv4i: HBM offset 0x4949f001 is not 4 KB aligned
FAIL blk.15.ffn_gate.weight.mv4i: HBM offset 0x4afd6000 overlaps the previous region ending 0x4afd6001
```

Case 3 is in SS7 -- it is the one the guard initially did NOT catch.

### 4.4 On the card

Offsets are exactly the manifest's `hbm_offset`, not hand-picked.

```
blk.0.attn_qkv.weight  M=8192  K=4096   w_exp=8 out_shift=3  18915328 B  hbm=0xad248000
blk.0.ffn_gate.weight  M=12288 K=4096   w_exp=8 out_shift=3  28315648 B  hbm=0x5a3b7000
blk.0.ffn_down.weight  M=4096  K=12288  w_exp=7 out_shift=5  28536832 B  hbm=0x58880000
```

```
=== blk.0.attn_qkv.weight.mv4i at 0xad248000 ===
wrote 18915328 bytes in 0.03 s = 0.66 GB/s
source blake2b-128 108a8f43e507d3cd90ed13c458ae3534
PASS  18915328 bytes identical
      source 108a8f43e507d3cd90ed13c458ae3534  hbm 108a8f43e507d3cd90ed13c458ae3534
=== blk.0.ffn_gate.weight.mv4i at 0x5a3b7000 ===
wrote 28315648 bytes in 0.04 s = 0.64 GB/s
PASS  28315648 bytes identical
      source f0bb2c66fd3c0bd3be457746e0aed406  hbm f0bb2c66fd3c0bd3be457746e0aed406
=== blk.0.ffn_down.weight.mv4i at 0x58880000 ===
wrote 28536832 bytes in 0.04 s = 0.65 GB/s
PASS  28536832 bytes identical
      source 26fb455e98be17006a48c491d0161346  hbm 26fb455e98be17006a48c491d0161346
=== output.weight.mv4i at 0x0 (572 MB, the DMA-rate probe) ===
wrote 572207104 bytes in 0.77 s = 0.74 GB/s
PASS  572207104 bytes identical
      source 619a7aa9b1ada3c74317c04d3fa27aee  hbm 619a7aa9b1ada3c74317c04d3fa27aee
```

The `source` digests here are the same `blake2b_128` values the manifest records, so one number
now ties the packer's output, the file on disk, the manifest and the bytes in HBM together.

## 5. How the 177 non-matvec tensors are carried -- MY DECISION

The specs do not pin an HBM layout for them, and this is worth being explicit about:

- sequencer D SS6.4 deliberately keeps the descriptor table, the norm weights and B's constants
  in D's **URAM constant memory**, valued at "~1.53 MB per token of HBM traffic avoided and,
  more importantly, zero ports";
- D SS8.1's remark that "the table and norm weights move to HBM and D takes one dedicated read
  port" is conditional and specifies no layout;
- A's spec 6.4/6.5a covers the packed matvec format only.

So the layout below was chosen here and can be changed freely if something is ever specified:

- **one** contiguous side file `nonmatvec_f32.bin`, so the 177 arrive in a single DMA rather
  than 177 transfers averaging 3 KB;
- each tensor little-endian float32 in GGUF element order (ne0 fastest), unpermuted -- the F32
  source tensors are already in that order and the BF16 ones dequantize into it;
- each tensor **4 KB aligned inside the file**, so with the file at a 4 KB aligned base every
  individual tensor is independently 4 KB aligned and can be fetched on its own;
- padding 0x00, matching spec 6.4's pad fill.

Cost of the alignment: 4,571,136 B stored against 4,245,504 B of payload, i.e. **325,632 B**
(0.006% of the set). The manifest lists every entry's `name`, `shape_ne`, in-file `offset`,
`nbytes` and absolute `hbm_offset`.

## 6. Measured and REJECTED -- do not retry

- **Parallel packing.** Rejected on measurement, not on principle: one tensor took 9.9 s for
  50.3 M weights, so the whole model projected to ~30 min serial (actual 27:32). Against that,
  the two 1.017 B-weight tensors peak at 10.6 GB RSS EACH, and this box has 31 GB with another
  agent possibly running Vivado (which alone peaks at 23.8 GB). Three workers could have
  co-scheduled two giants and OOM'd the box for a ~15 min saving. Do not re-introduce a worker
  pool without a scheduler that serialises the M=248320 tensors.
- **Re-opening the GGUF per tensor.** `pack_int4.read_tensor(path, name)` constructs a fresh
  `GGUFReader`, which re-parses the whole metadata block; `--audit` alone costs 5.4 s of that.
  Over 250 tensors it is 10-20 min of pure overhead for zero work. Fixed by adding
  `tensor_as_mk(t)` for an already-open reader. Do not call `read_tensor` in a loop.
- **`.astype(np.float32)` with the default `copy=True` in `read_tensor`.** On `output.weight`
  and `token_embd.weight` (1.017e9 weights) that is a 4 GB transient on top of the 4 GB result.
  Changed to `copy=False` on both branches; nothing downstream mutates W. Peak RSS with the fix
  is 12.16 GB, which is what made the serial run safe beside a possible Vivado build.
- **Trusting `--full` to catch payload damage, before this session.** It hashed every file and
  **printed** the digest without comparing it to anything, so it returned PASS on a file with a
  flipped byte. A guard that prints is not a guard. See SS7.

## 7. Measurement traps hit, including my own

**The checker had no teeth against a payload byte flip, and I nearly reported it as if it did.**
Case 3 of the corruption test set byte 8192 of `blk.0.ssm_alpha.weight.mv4i` to 0xFF. Header,
size, every sub-region offset and every HBM placement are all still correct, so:

```
### CASE 3: one byte flipped in the PAYLOAD
-- without --full:
rc=0
PASS  every header, size, sub-region offset and HBM placement is as spec 6.4/6.5a requires
```

The first `--full` implementation did not help, because it hashed and printed rather than
hashed and compared. Fixed by recording `blake2b_128` per file in the manifest at pack time
(the resume path made regenerating it a 12.8 s job, not a 27 min one) and comparing in the
checker. Re-run:

```
### CASE 3 REDONE, --full
rc=1
FAIL blk.0.ssm_alpha.weight.mv4i: blake2b-128 9d2357831f3120578a47a5b7a7b7de2f,
     manifest says 7e5131838923a96d9b6f7b7a16c41d80 -- the payload has changed
```

Secondary trap in the same fix: the summary line counted hash ATTEMPTS, so a failing run still
said "251 payloads hashed and matched". It now counts matches only.

**`fk33ctl.py load` is hash-bound, not DMA-bound, and 0.74 GB/s is NOT a DMA regression.**
The 572 MB probe measured 0.74 GB/s against the 3.27 GB/s H2C figure established earlier today.
The cause is that `cmd_load` blake2b-hashes each 8 MB chunk on the CPU in the same loop that
writes it. Measured on the same file, already in page cache:

```
read+blake2b 572207104 B in 0.57 s = 1.00 GB/s
read only    572207104 B in 0.06 s = 9.64 GB/s
```

Serialised, 1/(1/1.00 + 1/3.27) = 0.766 GB/s, which is the 0.74 GB/s observed. **So a cold load
of the whole 4.710 GiB set through `fk33ctl.py load` is ~6.8 s, not the ~1.4 s the raw H2C rate
implies.** Do not read a low `load` number as a link or DMA problem; run `fk33ctl.py bench`,
which does no hashing, to see the DMA rate. The obvious fix (hash on another thread, or skip
the source hash when `--verify` is going to compare the bytes anyway) was NOT applied here --
it changes a tool the bring-up work depends on, and this task had no mandate to.

**Small transfers understate the DMA rate further.** The three tensor loads reported
0.64-0.66 GB/s at 19-29 MB versus 0.74 GB/s at 572 MB. Per-call and per-chunk overhead
dominates at that size. Any DMA-rate claim needs a transfer of at least a few hundred MB.

**`--audit` counts the non-matvec tensors as `params * 4` with no padding**, so it reports
4.709 GiB where the real set is 4.7097 GiB. The 325,632 B difference is exactly the intra-blob
4 KB alignment the audit does not model. They are the same number to three decimals, but they
are not identical and it is not a defect in either.

**`ps -eo ... -p <pid>` ignores the `-p`.** Used it once to check the packer's RSS and got all
600 processes on the box. Use `ps -o ... --no-headers -p <pid>`.

## 8. What was NOT determined -- open

- **The whole set has never been loaded into HBM at once.** Four files totalling 648 MB were,
  all bit-exact. The remaining 247 are proven only by arithmetic (they fit, offsets are aligned
  and non-overlapping, checked by `check_mv4i_set.py`) and by the identical packing code path.
  A full-set load is ~7 s of DMA plus ~7 s of read-back verify and is the obvious next probe.
- **No RTL has consumed one of these files.** Every check here is host-side or a byte
  comparison. That `NPORTS_W=24` sub-regions with `n_scale_sub=3` are what the FK33 design
  actually pops is asserted by spec 6.5a and by `pack_int4.crosscheck`, not by simulation
  against this set.
- **`token_embd.weight` is packed as a matvec (572,207,104 B) and probably need not be resident.**
  `is_matvec` classifies it as one because it is 2D with M,K > 1, and the task's instruction was
  to reproduce `audit()`'s classification rather than invent a rule -- so it is packed. But
  sequencer D SS3.2 leaves the embedding gather **on the host**, which dequantizes row `tok`
  and writes it to region X. If that stands, dropping `token_embd` from HBM reclaims 0.533 GiB and
  another 8,731 tokens of context. Not changed here; flagged for whoever owns D SS3.2.
- **Whether a 4-bit `token_embd` is even usable as a lookup table in this layout.** A single row
  is scattered across 24 weight sub-regions and 3 scale sub-regions. Extracting one row is
  defined but is 27 strided reads, not a contiguous fetch. Nobody has specified the gather.
- **Accuracy of the packed model as a model.** Per-tensor RMS ~8.0% and cosine ~0.9967 are the
  packer's own metrics on single matvecs. No perplexity, no token-level comparison against the
  BF16 reference, no end-to-end run. 6.5a is a permutation so it cannot have changed this
  relative to the already-characterised 4/128 path, but the absolute quality of INT4 IQ4_NL on
  Qwen3.5-9B is still unmeasured.
- **`--cards 2`.** Everything here is `--cards 1`. The shard penalty at ROWS_IF=48 is reported
  as 0.000 GiB by the audit but no sharded set was produced.

## 9. Reproducing

```bash
python3 tools/pack_model_fk33.py \
  /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf \
  /mnt/storage/llama-models/qwen35-9b-mv4i --rows-if 48 --axi-dw 256
python3 tools/check_mv4i_set.py /mnt/storage/llama-models/qwen35-9b-mv4i --full
```

The run is **resumable**: a `.mv4i` already present at the size `packed_layout` predicts is
kept and its `w_exp`/`out_shift` are read back out of its header, so a re-run costs ~13 s and
regenerates the manifest. `--force` repacks. Writes go to `<name>.mv4i.part` and are renamed
only on success, so an interrupted run leaves no file of the right size with wrong contents.

**The packed set is NOT in git** -- it is 4.7 GiB and lives in `/mnt/storage/llama-models/`,
outside the repository. Only the three tools and this note are committed.
