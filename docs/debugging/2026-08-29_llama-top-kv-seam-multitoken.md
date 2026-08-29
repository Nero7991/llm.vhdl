# The KV seam at the INTEGRATION level, and the first multi-token `llama_top`

2026-08-29. Track TOP-KV, backlog item 3. Simulation only, no hardware.
Build: the `fpga` branch working tree at `54b3c1a`, GHDL 1.0.0 mcode,
`--std=08 -frelaxed --max-stack-alloc=0`.

## 1. The question, verbatim

> TRACK C-SEAM connected `attn_block` to `attn_kv_axi` and **proved
> multi-token attention**: 4 tokens at `cur_pos` 0..3, bit-exact over 1,028
> output values and 1,088 HBM record bytes. The seam added four inputs to
> `attn_block`, all defaulting to `'1'`: `kw_rdy`, `kr_rdy`, `vr_rdy`,
> `kv_wr_idle`. **`rtl/llama_top.vhd` still leaves all four open**, which is
> why it compiles unchanged and is bit-identical. So `llama_top` currently
> instantiates an attention block whose KV interface is tied to "always ready"
> and connected to nothing. **`llama_top` runs ONE token at `cur_pos = 0`.**
> That is exactly why both of `attn_block`'s real defects were invisible to
> it: the cache is never read and no softmax maximum can rise.
>
> 1. Survey and report first. 2. Wire the KV seam into `llama_top`.
> 3. Run more than one token, in `llama_top`. 4. Preserve what already holds.
> 5. Teeth-check. If wiring the seam would cost `llama_top`'s current
> bit-exactness, STOP and report the design question rather than trading it
> away.

## 2. The answer, up front

**Done, and the answer to "would it cost the bit-exactness" is NO, because
the shape forced the whole thing behind a generic anyway.**

`rtl/llama_top.vhd` instantiates `rtl/attn_kv_axi.vhd` under a new `C_KV_AXI`
generic, connects all four handshakes, and publishes a sequence position
advanced on the `tok_done`/`tok_ack` handshake instead of a hardwired 0.
`sim/tb_llama_top.vhd` runs `NTOK` tokens of one sequence per reset, models
the three KV AXI slaves, and adds six properties.

**MEASURED: four tokens of one sequence, TWO attention layers per token,
through the real `attn_kv_axi` over three modelled AXI slaves at three
different KV read latencies (100, 7 and 403 cycles), R_X bit-identical PER
TOKEN across all three, 0 KV faults, 33 record write bursts retired and every
read beat checked against the bench's own evaluation of C spec 2.2's address
equation.**

**The geometry is FORCED, and finding that out is what decided the design.**
`attn_kv_axi` asserts `CM_W = 8` (`rtl/attn_kv_axi.vhd:450`),
`(KV_BLOCK*CM_W/8) mod 16 = 0` (`:463`, the record's 16-byte granule) and
`N_KVH >= 2` (`:489`). `attn_block` asserts `HEAD_DIM` is an EVEN power of two
(`rtl/attn_block.vhd:666`), `HEAD_DIM/KV_BLOCK >= 2` (`:660`) and a GQA group
of at least 2 (`:657`). Together: `KV_BLOCK >= 16`, so `HEAD_DIM >= 32`, so
`HEAD_DIM = 64` (32 is not an even power of two). `mk_shape_scaled` could not
produce that shape at all -- its formula is `attn_q_heads = 64/attn_hd`,
`attn_kv_heads = 32/attn_hd`, which at `attn_hd = 64` gives ONE query head and
ZERO KV heads -- so `rtl/llama_map_pkg.vhd` gained a third point.
`att_q`, `att_qg` and `att_kv` are 4x their `attn_hd = 16` values there, so
**no landmark measured at ATTN_HD 16 or 32 is comparable with one measured at
64.** That is also why the KV path could not simply replace the existing one.

**What is preserved, re-measured after the change and byte-identical:**
`BLOCKS=32 ATTN_INT=4 NRUNS=1 C_REAL NORM_REAL ATTN_HD=16 NORM_ANCHOR=false`
with the PART 6 pooled real Qwen3.5-9B weights -> **PASS, 491 descriptors,
`R_X(0) = -14110 hash(R_X) = 52347`, 0 degenerate residuals**, and all 65
`log2 rms` samples of the norm's input identical to the pre-change run
(min 3.2005, max 3.3434). The default gate row is likewise `R_X(0) = -12049
hash(R_X) = 86767` at the same simulation end time to within four cycles.

**And a third gate row, raised mid-track by the coordinator:** until today the
gate ran `tb_llama_top` on its generic DEFAULTS, which are the attention STUB,
the probe norm and synthetic weights, so **the real path was not defended by
the regression at all**. `sim/tb_llama_top_real.vhd` turns C, the norm and the
weights on and reproduces PART 6's published landmark exactly. See 4.5.

**What it does NOT establish.** There is still no value oracle for a whole
token, so nothing here says the numbers are attention. That claim belongs to
`ref/attn_block_seq_vec.c` through `sim/tb_attn_kv_seam.vhd`, at the BLOCK
level. What this adds is that the INTEGRATION drives that contract: the
position, the layer, the bases, the sequence reset and the four handshakes.

## 3. The survey, and where the brief and the RTL disagree

Read out of the RTL at `54b3c1a` before anything was changed.

### 3.1 How `llama_top` instantiated `attn_block`

`rtl/llama_top.vhd:2990`, inside `gcr : if C_REAL generate`. The port map has
`kw_*`, `kr_*` and `vr_*` but **not** `kw_rdy`, `kr_rdy`, `vr_rdy` or
`kv_wr_idle`: all four were left open and took `attn_block`'s `'1'` defaults.
The cache was the `kvp` process at `:2941-2977` -- a one-cycle synchronous
behavioural memory over two arrays sized `C_LAY*2*C_NKVH*C_MAXPOS`, with
`C_MAXPOS` defaulting to 4. That memory can never refuse, so the `'1'`
defaults were CORRECT for it and silently wrong for anything with latency.

### 3.2 Where `cur_pos` was fixed at 0 -- the brief's line number is off

The brief cited `rtl/llama_top.vhd:2746`. **At 2746 there is a COMMENT**, part
of the block that says "`llama_top` runs ONE token with `tk0` hardwired, so
`cur_pos` is 0 and `ctx_len` is 1". The assignments are at **`:3050` and
`:3051`**, in the C adapter's `job_issue` branch:

```vhdl
c_cpos  <= (others => '0');
c_ctx   <= to_unsigned(1, POSW);
```

The RTL wins; the comment is accurate about the behaviour and is not the site.

### 3.3 What the descriptor program does per token, and what it does NOT carry

`sim/llama_sched_pkg.vhd` emits, per attention block: `OP_VEC_NORM`,
`OP_A_JOB`(R_QG), `OP_A_JOB`(R_KIN), `OP_A_JOB`(R_VIN), `OP_C_JOB`,
`OP_A_JOB`(R_ER), `OP_VEC_RES`, then six FFN steps -- 13 steps
(`NSTEP_ATTN_N1`). A GDN block is 16 (`NSTEP_GDN_N1`). Every size in it is a
function of `SHAPE` (`att_q`, `att_qg`, `att_kv`, `hidden`, `ffn`), which is
why the ATTN_HD 64 shape needed no schedule change at all.

**The descriptor carries no sequence position.** `seq_desc_fetch`'s job
fields (`rtl/seq_desc_fetch.vhd:198-217`) are epoch, unit, opcode, flags, src,
src2, dst, dst_off, n_rows, n_cols, w_exp, out_shift, out_mode, ordinal,
const_base, const_exp, step. There is no position and no token index. A
multi-token run therefore cannot be driven from the table: the position has to
be state the machine keeps between `go` pulses, which is why the fix is a
counter in `llama_top` and not a descriptor field.

### 3.4 What had to change for a second token

1. A position counter, and something to advance it. `tok_done` is a PORT
   driven straight from `seq_desc_fetch`, so it had to become an internal
   signal with the port a copy.
2. `ctx_len`. Both `attn_block` (`:1163`) and `attn_kv_axi` (`:542`) refuse
   `cur_pos >= ctx_len`, so a fixed `ctx_len = 1` refuses every token after
   the first. Neither uses the value for anything else -- `clen_r` is latched
   and DEAD in both files -- so it bounds the run and does not enter the
   arithmetic.
3. The cache depth. `C_MAXPOS` defaults to 4.
4. **The bench's own per-step counters.** `n_chk`, `n_issue` and `n_cmp` were
   reset on `tb_reset`, i.e. once per RUN. `rel_mask <= PLAN(n_chk).rel when
   n_chk < NSTEP else (others => '0')`, so on token 1 `n_chk` was already
   past NSTEP and the bench published an ALL-ZERO release mask. MEASURED: the
   walker refused with `err_code x3 at step 10`, which reads exactly like a
   DUT fault and is the bench's bookkeeping. See 7.1.

## 4. What changed, file by file

### `rtl/llama_map_pkg.vhd`

| site | change |
|---|---|
| `mk_shape_scaled` | a third point: `attn_hd > 32` returns 4 query heads and 2 KV heads and lets the attention region widths grow (`att_q` 256, `att_qg` 512, `att_kv` 128). `attn_hd` 16 and 32 are byte-for-byte what they were. |

### `rtl/llama_top.vhd`

| site | change | why |
|---|---|---|
| generics | `C_KV_AXI`, `C_CTXLEN`, `C_K_BASE`, `C_V_BASE`, `C_KV_ADDR_W`, `C_KV_AXI_DW`, `C_KV_MAXB`, `C_KV_MAXOUT`, `C_KV_RBUF` | `C_KV_AXI` defaults FALSE, so the default path is bit-identical |
| ports | 24 KV master signals plus `kv_err` and `obs_tok_pos`; every input has a default, every output is driven | an instantiation predating this still elaborates. `llama_top` is instantiated only by `sim/tb_llama_top.vhd` today, but TRACK SHELL is building from HEAD |
| `tok_done` | now an internal `tok_done_i` with the port a copy | this file has to act on it, and reading an output port makes the meaning depend on the standard revision |
| `tok_pos` | new counter, cleared by `rst`, advanced on `tok_done_i and tok_ack`, reports an error rather than wrapping at `C_MAXPOS` | wrapping would overwrite position 0's record and every later read would be served a plausible wrong answer |
| `:3050-3051` | `c_cpos <= to_unsigned(tok_pos, POSW)`, `c_ctx <= to_unsigned(C_CTXLEN, POSW)` | the whole point |
| the cache | split into `gkvmem` (the old behavioural memory, all four handshakes tied high) and `gkvaxi` (the real `attn_kv_axi`) | only one branch elaborates, so each signal has one driver |
| the `attn_block` port map | `kw_rdy`, `kr_rdy`, `vr_rdy`, `kv_wr_idle` connected | they were open |
| `uerr` | `c_err or kv_err_i` | a cache fault that only reached its own port would leave the schedule reporting success on a token whose records were never written |
| `glchk` | asserts `kv_layer = c_layer` on every write beat, when `C_LAY > 1` | the block publishes the layer per write and the cache latches it once at `start`; nothing else connects them |
| elaboration | five asserts naming the caller for the three-way geometry constraint, the K/V region overlap and the 16-byte base alignment | `attn_kv_axi`'s own asserts would read as a bug in that file |
| the banner | says which cache is instantiated | the old text asserted `attn_kv_axi` is absent, which is now false in one configuration |

### `sim/tb_llama_top.vhd`

`NTOK` tokens per run; the three KV AXI slaves over one protected type
carrying both the modelled HBM and a per-slot SHADOW; six new properties
(P7 write placement, P8 read placement, P9 read coverage, P10 served bytes,
P11 C spec 2.7, P12/P12b the sequence); a per-token embedding; and the KV read
latency swept with the run alongside the descriptor-memory latency.

### The new files

| file | what it is |
|---|---|
| `sim/tb_llama_top_seq.vhd` | a wrapper pinning the multi-token KV configuration. `sim/regress.sh` keys a test by NAME and cannot run one testbench at two generic sets, so a configuration that has to be GATED needs its own top level. It adds no checks; every property belongs to `tb_llama_top`. |
| `sim/tb_llama_top_real.vhd` | the same shape of wrapper for the real path: real A, B, C, the real `rmsnorm_rs` and real weights. See 4.5. |
| `sim/llama_top_w_b4_pool.hex` | the committed real Qwen3.5-9B weight image, 660 KB, md5 `8cd88f10114e3a74a586c8a382d0889c`. |
| `sim/mutate_llama_top_kv.sh` | 26 rows: the teeth. |

`sim/regress.sh`: `BASELINE_PASS` 81 -> 83, both new rows added to `SLOW_TBS`
and to the `--quick` exclusion list with their measured runtimes, and `*.hex`
added to the per-test workdir glob.

## 4.5 The gate row nobody had: the real path was not defended at all

Raised by the coordinator mid-track and verified against the tree:
`grep -n 'C_REAL\|NORM_REAL\|B_SRC_REAL' sim/regress.sh` had **zero hits**, and
all three default FALSE in `rtl/llama_top.vhd` (`:203`, `:299`, `:311`). So
every `tb_llama_top` gate row elaborated with the attention STUB, the probe
norm and the synthetic conv-tap source, and PART 6's flagship result -- the
whole token passing with real A, real B, real C, the real `rmsnorm_rs` AND
real Qwen3.5-9B weights -- was a one-off manual run at NRUNS = 1. **A
regression in the real path left the gate green.**

Two rows now exist and they cover DISJOINT real paths, because the two
configurations cannot be combined:

| row | what is real | shape | MEASURED |
|---|---|---|---|
| `tb_llama_top` | A, B, D; stub C, probe norm, synthetic weights | ATTN_HD 32 | 121 s |
| `tb_llama_top_real` | A, B, C, D, the real `rmsnorm_rs`, real weights | ATTN_HD 16 | **75 s** |
| `tb_llama_top_seq` | A, B, C, D and the real `attn_kv_axi`, 3 tokens | ATTN_HD 64 | 302 s |

`tb_llama_top_real` reproduces PART 6's published control landmark EXACTLY --
`R_X(0) = -16339 hash(R_X) = 92903`, 0 degenerate residuals -- and adds a
second descriptor-latency point that the manual run did not have.

**Why the two cannot be one row.** `C_KV_AXI` forces ATTN_HD 64 (section 2).
The real weight image is emitted per STEP by `tools/gen_llama_top_weights.py`,
which maps the bench's block index onto the REAL model's layers, and the real
Qwen3.5-9B has full attention every FOURTH block -- `--attn-interval 2` asks
for `blk.1.attn_q.weight` and the tool refuses, MEASURED. So the real-weights
row is `ATTN_INT = 4`, one attention block, ATTN_HD 16; and the KV row is
`ATTN_INT = 2`, two attention layers, ATTN_HD 64, synthetic weights. Closing
that needs a weight generator that accepts the ATTN_HD 64 shape, and `tools/`
was not this track's file.

**The weight image is COMMITTED, 660 KB, and that is deliberate.** The
generator needs an 18 GB GGUF that is not in git, so a generated row would
carry a genuine external prerequisite and report VECTORGEN_RUN_FAILED on any
machine without the model set -- the position `mv_fk33_tr.txt` is already in.
`sim/llama_top_w_b4_pool.hex` is the tool's output for
`--blocks 4 --attn-interval 4 --reduce pool`, and it reproduced
byte-identically (md5 `8cd88f10114e3a74a586c8a382d0889c`) from two separate
runs of the tool on two different days. The repo already commits 2.5 MB vector
files in `sim/`.

**One `sim/regress.sh` trap on the way in:** the per-test workdir is populated
by globbing `*.txt *.dat *.csv *.mem *.bin`. A `.hex` matched none of them, so
the row failed with `cannot open the weight image`, which reads like a missing
file and is a missing GLOB. `*.hex` added.

## 5. The procedure, in the order it was run

Each step says what it isolates.

1. **Reproduce both baselines before touching anything.** The gate row
   (`sim/regress.sh --only llama_top`) -> PASS, `R_X(0) = -12049 hash 86767`.
   The preserved configuration (32 blocks, real C, real norm, real weights)
   -> PASS, `R_X(0) = -14110 hash 52347`, 0 degenerate, and the 65 `log2 rms`
   samples captured to a file so the "after" could be diffed rather than
   eyeballed. Without the file the claim "unchanged" is a memory.

2. **Read the two units' elaboration asserts before designing anything.**
   This is what produced the three-way geometry constraint in section 2, and
   it is the step that decided the whole design: at the existing
   `ATTN_HD = 16` shape the two units CANNOT be connected at all, so the KV
   path could not replace the behavioural memory and had to be a generic.

3. **Prove the ATTN_HD 64 shape runs at all, with the OLD behavioural cache,
   before adding the new one.** One variable at a time. `BLOCKS=4 ATTN_INT=4
   NRUNS=1 C_REAL ATTN_HD=64 KV_BLOCK=16 N_ROT=16 MAXPOS=8` -> PASS,
   `R_X(0) = -12006 hash 26916`, 40 s. If that had failed, nothing about the
   cache would have been diagnosable.

4. **Wire the seam, and re-run the DEFAULT path first**, before any new
   bench code. `R_X(0) = -12049 hash 86767`, unchanged.

5. **Run the token loop, and let it fail.** It did, twice, and both were the
   bench rather than the DUT (7.1, 7.2).

6. **Write the shadow BEFORE writing any read check.** The shadow is keyed by
   slot through this file's own copy of C spec 2.2's equation. A check that
   compared the memory against itself would pass for a wrong equation, because
   both masters use the DUT's.

7. **Measure whether the sequence has content, rather than assuming it.**
   This is the step that found 7.3, the degenerate stimulus, and it was only
   run because two runs at different NTOK printed the SAME hash.

8. **Mutate, with controls.** `sim/mutate_llama_top_kv.sh`.

## 6. The evidence

### 6.1 Four tokens, two attention layers, three KV read latencies

`BLOCKS=4 ATTN_INT=2 NTOK=4 NRUNS=3 C_REAL ATTN_HD=64 KV_BLOCK=16 N_ROT=16
MAXPOS=8 KV_AXI` (this run predates the varying embedding of 7.3):

```
run 0 token 0 descriptor latency 1: 60 jobs issued, 61 completions, KV records written 9,  KV beats read 0
run 0 token 1 descriptor latency 1: 60 jobs issued, 61 completions, KV records written 17, KV beats read 24
run 0 token 2 ...                                                   KV records written 25, KV beats read 65+
run 0 token 3 ...                                                   KV records written 33, KV beats read 131
tb_llama_top: schedule mismatches=0 skew differences=0 degenerate residuals=0
              KV faults=0 (write placement 0, read placement 0, served bytes 0,
                           coverage 0, bresp ordering 0)
tb_llama_top RESULT: PASS -- 61 descriptors, 4 blocks, 4 tokens per run,
              3 descriptor-latency points, R_X bit-identical across all of them
```

**Read the write and read counts, they are the shape of the claim.** Eight
record write bursts per token = 2 attention layers x 2 KV heads x {K, V}.
Token 0 reads ZERO beats -- that is `attn_block`'s bypass, and it is why one
token proved nothing. The read volume then grows with the position.

### 6.2 The three latency points are the KV path's, not just the descriptor's

The sweep moves `kv_lat` as well as `uram_lat`: run 0 at 100 cycles, run 1 at
7, run 2 at 403. At 7 cycles token 1 fetches 24 beats and at 100 it fetches
17 in the first version of the counter -- i.e. the prefetcher genuinely
behaves differently -- and R_X is bit-identical per token across all three.

### 6.3 The gate row, in the real harness

```
PASS  sim:tb_llama_top      121s  ... R_X(0) = -12049 hash(R_X) = 86767
PASS  sim:tb_llama_top_seq  302s  ... 61 descriptors, 4 blocks, 3 tokens per run,
                                      2 descriptor-latency points
```

### 6.4 The preserved configuration, byte-identical

`BLOCKS=32 ATTN_INT=4 NRUNS=1 C_REAL NORM_REAL ATTN_HD=16 NORM_ANCHOR=false
W_IMAGE=<PART 6 pooled real Qwen3.5-9B image>`:

```
before:  PASS -- 491 descriptors, 32 blocks, R_X(0) = -14110 hash(R_X) = 52347
         degenerate residuals=0,  65 NORMMAG samples, min 3.2005 max 3.3434
after:   PASS -- 491 descriptors, 32 blocks, R_X(0) = -14110 hash(R_X) = 52347
         degenerate residuals=0,  65 NORMMAG samples, byte-identical (diff empty)
```

All 65 `log2 rms` values compared with `diff`, not by eye.

## 6.5 The mutation table

`sim/mutate_llama_top_kv.sh`. **26 rows: 4 controls and 22 mutations, 13
killed and 9 survivors, and every survivor is analysed below rather than
assumed equivalent.** Three of the kills were survivors first and became kills
by STRENGTHENING A CHECK, never by weakening the mutation.

Controls first, because the rest is only readable against them.

| # | mutation | outcome | killed by |
|---|---|---|---|
| C0 | CONTROL: clean, the shipping KV configuration | SURVIVED (correct) | -- |
| C1 | CONTROL: clean, 4000-cycle BRESP latency | SURVIVED (correct) | -- |
| C2 | CONTROL: clean, write slave refuses AW for 3000 cycles | SURVIVED (correct) | -- |
| C3 | CONTROL: clean, write slave commits at W (the WEAK slave) | SURVIVED (correct) | -- |
| M1 | the read slaves serve the PREVIOUS position's bytes | KILLED | P10, 3,836 served-byte faults |
| M2 | one record's write burst dropped, BRESP still returned | KILLED | P10 (72) and P11 (4) |
| M3 | the read slaves return zeros | KILLED | P10, 4,102 |
| M4 | the DUT is RESET between tokens (the pre-seam bench) | KILLED | the position readback (12) and P9 (112) |
| M5 | the same embedding for every token | KILLED | P12b, 6 |
| R1 | the BLOCK ignores the residency answer (`kr_rdy` tied high) | KILLED | the seam handshake property |
| R1b | the CACHE's `kr_rdy` output left `open` | **SURVIVED** | see 6.5.1 |
| R2 | `kv_wr_idle` ungated, at WR_LAT 12 | **SURVIVED** | see 6.5.2 |
| R2b | the same, at a 4000-cycle BRESP latency | KILLED | P11, 71 |
| R2c | the same, at 4000 cycles AND the weak slave | **SURVIVED** | see 6.5.2 |
| R3 | `attn_kv_axi` configured for the NEXT layer | KILLED | P7 (3,840) and P8 (4,896) |
| R4 | the sequence position never advances | KILLED | the position readback (12) and P9 (112) |
| R5 | the position published to block AND cache is one too large | KILLED | P3, unit C emitted 0 y elements |
| R6 | the K and V bases are swapped | KILLED | P8's master-vs-region check, 5,440 |
| R7 | the `v_ref` sequence reset is issued per TOKEN | **SURVIVED** | see 6.5.3 |
| R8 | the bypass removed AND the cache told `cur_pos` is readable | KILLED | P9's second half |
| N1 | the real rmsnorm's gain exponent 20 octaves out | KILLED on `tb_llama_top_real` | P6, 16 degenerate residuals |
| N1x | the SAME mutation against the DEFAULT gate row | SURVIVED (correct) | -- |
| N2 | the real rmsnorm's writeback drops its last element | **SURVIVED** | see 6.5.4 |
| N2x | the same against the DEFAULT gate row | SURVIVED (correct) | -- |
| X1 | R1b's mutant against the DEFAULT gate row | SURVIVED (correct) | -- |
| X1r | R1b's mutant against the REAL-PATH row | SURVIVED (correct) | -- |

**The three kills that were survivors first.** Each is a check that was
strengthened after a mutation went through it:

- **R6** (K and V bases swapped) survived until the read slave started
  checking WHICH MASTER fetched a byte. Index 0 is the K stream and index 1
  the V stream, and without that a base swap is a pure relabelling every other
  check agrees with. One line, 5,440 faults.
- **R2b** (`kv_wr_idle` ungated at 4000 cycles) survived until the write slave
  was split in two: the SHADOW is written when the master's W beat is
  ACCEPTED, and the modelled memory only at BVALID. With both written at
  BVALID, P11 compared two zeros and agreed. See 7.7.
- **R8** (the sweep reads the record at `cur_pos`) could not fire at all until
  the read coverage mask was marked for every decoded byte rather than only
  for `ps < cur_pos` -- the slots P9's second half tests were the only ones
  never marked. See 7.8.

**R5's kill is not the one it was written for, and that is worth saying.**
Publishing `cur_pos + 1` to both sides was meant to exercise P9's second half.
It dies earlier and harder: the block emits ZERO y elements and P3 fires. R8
is the mutation that actually reaches P9's second half.

### 6.5.1 R1b survived, and the pair R1/R1b is where the property ends

R1 and R1b are the same defect said two ways. R1 leaves the BLOCK ignoring an
answer the cache still publishes, and `llama_top`'s handshake property -- a
beat offered while its gate is low -- kills it. R1b leaves the CACHE's
`kr_rdy` output unconnected, so `kr_rdy_s` has no driver and holds its `'1'`
initial value: **there is no wire left for the property to watch.**

This is not a gap that more simulation closes. A `=> open` on an output whose
value the design depends on is visible by inspection and invisible to a
simulator, because the thing it deletes is the evidence. What limits the
damage is that both `attn_block` and `attn_kv_axi` publish these signals with
`'1'` defaults ON PURPOSE (so a pre-existing instantiation still elaborates),
which is exactly the cost TRACK C-SEAM recorded when it chose those defaults.

### 6.5.2 R2 / R2b / R2c: the shape of the BRESP risk, and the slave that hides it

`attn_block` writes both records early in a job and then spends the rest of it
on the sweep and the output stage, so at any BRESP latency short compared with
a job the write has retired long before `done` and the `kv_wr_idle` gate is
unobservable. R2 at WR_LAT 12 survives for that reason and the survival is the
honest shape of the risk. R2b at 4000 opens the window and dies on P11, 71
faults.

**R2c is the row that matters most.** The same mutation at the same 4000-cycle
latency, with the write slave weakened to commit at W time, SURVIVES. So P11's
teeth are not in the property, they are in the slave model. C3 is its control
and passes. That is TRACK C-SEAM's 7.5 reproduced one level up, and it is why
the split described in 7.7 is load bearing.

### 6.5.3 R7 survived: the integration has no value oracle

Resetting `v_ref` per TOKEN instead of per SEQUENCE (C spec 2.1.4) changes the
NUMBERS and nothing else: the addresses are right, the coverage is right, the
served bytes are right, and the result is deterministic at every latency, so
P2 agrees with itself. `sim/tb_attn_kv_seam.vhd` kills the same mutation
because it has `ref/attn_block_seq_vec.c`, and it needed a CHOSEN seed to do
it -- at eight of nine seeds tried the oracle itself is byte-identical under
this mutation. **The integration level cannot see it and no amount of
structural checking here will.** It is defect class OI-3, for the sixth time
in this project.

### 6.5.4 N2 survived: a dropped norm element is a wrong number nothing can see

Dropping the last element of the real rmsnorm's writeback leaves R_XN's last
element carrying the previous step's value. Every handshake is honoured, the
element count the region lock sees is the count it was told, and the residual
is a plausible number at every latency. Same family as R7 and as the two
mutations `docs/debugging/2026-08-28_llama-top-first-seams.md` already records
as PASSING BROKEN. N1, which moves the output SCALE rather than one element,
dies on P6 with 16 degenerate residuals -- so the real-path row has teeth for
the scale and none for a single element.

### 6.5.5 N1x, N2x, X1 and X1r are the cross-row controls, and they are the point

The coordinator's question was whether a mutation in a real-only path fails
the new row and passes the existing ones. Measured:

| mutation | `tb_llama_top` (default) | `tb_llama_top_real` | `tb_llama_top_seq` |
|---|---|---|---|
| N1, the real rmsnorm's gain exponent | PASS (N1x) | **FAIL** (N1) | not run |
| R1b, `kr_rdy` open in the KV branch | PASS (X1) | PASS (X1r) | SURVIVED (R1b) |
| R1, the block ignores `kr_rdy` | not elaborated | not elaborated | **FAIL** |

N1 is the answer: the `NORM_REAL` adapter does not elaborate at all in the
default row, so the default row is structurally blind to every defect in it,
and the new row catches a real one. R1 is the same statement for the KV
branch and `tb_llama_top_seq`.

## 7. Measurement traps hit, including three that cost real time

### 7.1 The bench's own per-step counters made token 1 look like a DUT fault

Token 0 completed cleanly; token 1 died with
`tb_llama_top: the walker raised err_code x3 at step 10`, preceded by
`step 60 issued opcode 4, plan says 7` and a wall of
`issue 61 is past the end of a 61-step table`.

That reads like the descriptor walker desynchronising. It is not. `n_chk` is
reset on `tb_reset` -- once per RUN -- and

```vhdl
rel_mask <= PLAN(n_chk).rel when n_chk < NSTEP else (others => '0');
```

so on token 1 `n_chk` was already 61 and the bench published an **all-zero
release mask**, which is a legitimate instruction to the walker meaning "no
region is live". The walker did exactly what it was told. Fixed by clearing
`n_chk`, `n_issue` and `n_cmp` on `go` as well.

**Symptom to recognise: a schedule check that fires from step 0 of the SECOND
token while the first was perfect.** Per-run bench state is per-token state
the moment a token loop exists, and nothing in the language says so.

### 7.2 A signal incremented in a loop counts CYCLES, not events

Every fault counter was first written `kv_bad_rd <= kv_bad_rd + 1` inside a
`for c in 0 to BEAT_B-1` loop. A signal takes its LAST assignment in a delta,
so a per-byte counter written that way counts *cycles containing at least one
fault*. MEASURED: 3 reported against 48 actual (the sub-beat alignment padding
of 6.5's read masters, 16 bytes at each end of a region). All five counters are
now variables published once per cycle.

Same family, one level up: **the counters must NOT be cleared on `rst`**,
because `rst` is asserted once per RUN and clearing them erases run 0's faults
the instant run 1 starts. A fault counter a later reset zeroes reports a clean
run.

### 7.3 The token loop was a degenerate sequence, and two hashes agreeing is what showed it

The first token loop preloaded **the same embedding for every token**, so that
"R_X differs from token 0" would mean "something crossed the token boundary".
It passed. The tell was that an `NTOK = 3` run and an `NTOK = 4` run printed
the **same** `R_X(0) = -22336 hash(R_X) = 81877`.

MEASURED, after adding a consecutive-token difference count:

```
P12 -- token 1 vs token 0: 62 of 64 R_X elements differ
P12 -- token 2 vs token 1:  0 of 64 R_X elements differ
```

**The mechanism is the stimulus, not a defect.** With an identical input every
token, every K and V record in the cache is identical, and an attention output
that is a convex combination of identical vectors does not depend on how many
of them are in the sum. So the cache held ONE distinct record, every read
returned it, and every mutation of the read path would have been measuring the
stimulus rather than the check -- C-SEAM's trap 7.4, reproduced here from the
other direction.

Fixed by putting the token index into the embedding (`EMBED_VARY`, default
true). Re-measured: **64 of 64 differ token 1 vs token 0, and 64 of 64 token 2
vs token 1.** And a new property, P12b, asserts from the shadow that the
record at position t is not byte-identical to the one at position t-1 -- **not
guarded on `EMBED_VARY`**, because a property that switches itself off for the
stimulus it exists to reject has tested nothing. `EMBED_VARY=false` is row M5
of the mutation table.

**Generalise it: two runs at different depths printing the same landmark is a
stimulus result, not a coincidence.**

### 7.4 An over-fetched byte is not a wild address

A read burst is 32 bytes and the record bases are 16-byte aligned, so the
first burst of a region necessarily starts BELOW the base and the last ends
above it, and a run's tail beat reaches into the record at `cur_pos` -- the one
this job is WRITING through another master. The first read check called all
three a fault. The at-most-one-beat padding at each end is now exempt, and
bytes belonging to a record at or past `cur_pos` are skipped rather than
compared, because comparing them is a race by construction.

**This is the same boundary C-SEAM wrote down as "the readable bound is
`pos < cur_pos`, not `pos < ctx_len`", seen from the checker's side.**

### 7.5 `regress.sh`'s FAIL_RE is case-sensitive and contains `IS NOT`

The new PASS line originally read `WHAT THAT IS NOT: there is no value
oracle...`. `FAIL_RE` contains the literal `IS NOT`, so that would have made
the gate row RED on every passing run. The existing bench already carries a
comment warning about exactly this and it still nearly happened.

### 7.6 `mk_shape_scaled`'s formula has no third point, and it fails silently

`attn_q_heads => 64 / attn_hd, attn_kv_heads => 32 / attn_hd` gives 1 and 0 at
`attn_hd = 64`. `attn_kv_heads => 0` in a record whose field is `positive`
aborts at elaboration -- which is loud -- but the interesting part is that
nothing in the function says the formula only has two valid points. It does
now.

### 7.7 A shadow written at the same instant as the memory cannot see BRESP ordering

The first write slave did the placement decode, the shadow write and the
memory write in ONE procedure, called at BVALID. P11 then compared the
modelled memory against the shadow -- and with `kv_wr_idle` ungated, the
record is in NEITHER when `done` fires, so it compared two zeros and agreed.
**R2b survived.** Split into `note_beat` (shadow, at W acceptance, where the
record's content is known) and `mem_beat` (memory, at BVALID, which is what
AXI promises), R2b dies with 71 faults. C-SEAM's 7.5 says model the ordering
the spec gives you; this is the same rule applied to BOTH sides of a
comparison. **A check whose two sides move together cannot see the thing
between them.**

### 7.8 A branch that can never fire reads exactly like coverage

P9 has two halves: the sweep must fully read every record at `pos < cur_pos`,
and must NOT fully read the one at `cur_pos`. The read coverage mask was
marked only for bytes with `ps < cur_pos` -- so the slots the second half
tests were the only ones it never marked, and that half **could not fire under
any mutation**. Found by reading the code, not by any run, because a dead
branch is silent by construction. R8 is the mutation that now proves it fires.

### 7.9 Editing a running bash script, twice, after writing down that it breaks

`sim/mutate_llama_top_kv.sh` was edited while instances of it were running,
and the shells died with `syntax error near unexpected token` at lines that
are perfectly valid -- bash reads a script lazily by byte offset and an insert
shifts every offset after it. The RESULTS printed before the death were
correct and complete, which is the worst combination: a run that produced
right answers and then failed for an unrelated reason. `sim/regress.sh` has
carried a warning about exactly this since its own development and this file's
project instructions repeat it. **Copy the script elsewhere and edit that, or
wait.** Recorded because it happened twice in one session, to someone who had
read the warning.

## 8. Measured and REJECTED -- do not retry

- **Replacing the behavioural KV memory with `attn_kv_axi` unconditionally.**
  Impossible at the shape every existing `llama_top` landmark is measured at:
  `attn_kv_axi` needs `KV_BLOCK >= 16` at `CM_W = 8` and `attn_block` needs
  `HEAD_DIM/KV_BLOCK >= 2` with `HEAD_DIM` an even power of two, so the two
  units do not connect below `HEAD_DIM = 64`, and `ATTN_HD = 16` is the only
  value the real `attn_block` accepted before today. Both branches therefore
  have to exist. This is not a preference; it is an elaboration failure.

- **Raising `CM_W` to 16 so `KV_BLOCK = 8` would satisfy the 16-byte
  granule.** Started, then rejected on reading `rtl/attn_kv_axi.vhd:450`:
  `assert CM_W = 8 and EXP_W = 8`. The record format is int8 and the unit
  refuses anything else.

- **Growing `mk_shape_scaled`'s ATTENTION REGION WIDTHS at `attn_hd` 16 or
  32 to keep one formula.** Rejected: `att_q`, `att_qg` and `att_kv` are what
  every descriptor's `n_rows` is, so touching them at 16 or 32 would move
  every published landmark in `sim/tb_llama_top.vhd`. The formula gets a third
  point instead and the first two are byte-for-byte unchanged.

- **Making the multi-token configuration the `tb_llama_top` gate row.**
  Rejected: it would drop the existing row's coverage (the default shape, the
  four-point descriptor-latency sweep, the stub-C announcement) to gain the
  new one. `sim/regress.sh` keys a test by name and cannot run one testbench
  twice, so the new configuration is a WRAPPER entity,
  `sim/tb_llama_top_seq.vhd`, and both rows run.

- **A one-token `EMBED_VARY=false` sequence as the shipping stimulus.**
  Measured and rejected: see 7.3. It passes, and it passes because every
  record in the cache is the same bytes.

- **A `kr_rdy => open` mutation as evidence about the handshake property.**
  Measured (R1b) and it survives, and it deserves to: the property watches the
  wire the mutation deletes. Use the R1 form -- the BLOCK's input tied high --
  when the question is whether the property has teeth.

- **Comparing over-fetched bytes against the shadow.** Rejected by
  construction: the tail beat of a run reaches into the record at `cur_pos`,
  which this same job is writing through a different master, so the comparison
  is a race and would fire intermittently. Those bytes are skipped and the
  reason is in the code.

## 9. Open, not yet answered

- **There is still no value oracle at the integration level.** Nothing here
  says the numbers are attention. P7 to P11 say the records went to the
  addresses C spec 2.2 gives, that exactly the earlier positions were read,
  and that what came back is what was written. P12/P12b say the sequence has
  distinct content and that it reaches the output. None of that is arithmetic.

- **P12 cannot separate the KV cache from subsystem B.** `gdn_block` carries
  recurrent state across tokens too, so "something crossed the boundary" has
  two possible sources. `MUT_KV_ZERO` is the control and its row is in the
  table; read it before quoting P12.

- **The three slaves are a fixed-latency in-order model with a single ID.**
  Reordering across IDs, refresh and bank conflicts are not modelled. No
  hardware was touched at any point.

- **`NTOK` is 4 and `MAXPOS` is 8.** Long context is not approached, and the
  s26 softmax denominator and s36 accumulator widths C-SEAM named as the first
  things to bite are not approached either.

- **The shipping geometry.** This runs HEAD_DIM 64 / 4 query heads / 2 KV
  heads / KV_BLOCK 16 / N_ROT 16. The build is 256 / 12 / 2 / 32 / 64. Same
  point `sim/tb_attn_kv_seam.vhd` runs, for the same reason.

- **Synthesis.** Nothing here was run through Vivado. The new ports and the
  `attn_kv_axi` instance are real area and real timing on the C path and
  neither has been measured.

- **`C_KV_AXI` defaults FALSE, so the shipping default is still the
  never-refusing memory.** That is deliberate -- it is what keeps the 32-block
  real-weight landmark alive -- but it means a build that forgets the generic
  gets the pre-seam behaviour silently, exactly as `attn_block`'s `'1'`
  defaults do one level down. The banner says which one is in.

- **`R1b` is not closable by simulation.** An output port left `open` whose
  value the design needs deletes the evidence along with the signal. Nothing
  in this bench, or any bench, can see it; only reading the port map can.

- **P9's "not more than `pos < cur_pos`" half is proven by exactly one
  mutation**, R8, and R8 needs a two-file mutant. No single-file defect
  reaches it, which means the branch is real but thin.

- **The real-path gate row has no teeth for a single wrong element.** N2 drops
  one element of the real rmsnorm's output and passes. N1, which moves the
  output SCALE, dies on P6. So `tb_llama_top_real` defends the magnitude
  behaviour PART 6 measured and does not defend the arithmetic.

- **`tb_llama_top_real` and `tb_llama_top_seq` cover DISJOINT real paths and
  neither covers both.** `C_KV_AXI` needs ATTN_HD 64 and `C_REAL` with real
  weights needs ATTN_HD 16, because the weight image is indexed by STEP and
  the generator only knows the real model's `attn_interval` of 4. A row with
  the real weights AND the KV cache would need a weight generator that accepts
  the ATTN_HD 64 shape, and `tools/` was not this track's file.

- **Two attention layers, not more.** `ATTN_INT = 2` at `BLOCKS = 4` gives
  two, which is what makes the `layer` term of the address equation
  observable at all. Four or eight layers interleaving is untested.
