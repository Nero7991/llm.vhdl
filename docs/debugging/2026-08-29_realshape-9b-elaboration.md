# The real 9B shape has never elaborated in any simulator. Can it?

TRACK REALSHAPE, 2026-08-29. Backlog 13, first half.

Measured against a pristine `git archive` of
**`a9792dfc0a2a9d6817e0e37a8dbed346fe550107`**, extracted to a scratch tree, so
nothing in this file depends on a working tree that moved a dozen times today.

Tooling: `GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6) [Dunoon edition]`, **mcode** backend,
`--std=08`. Host: 31 GiB, 24 threads. Every row was run under
`systemd-run --user --scope -p MemoryMax=20G -p MemorySwapMax=0`, one at a
time, so a runaway could not reach systemd-oomd.

## The question, verbatim

> Deliver: elaborate the composed design at the real 9B shape, in GHDL, with
> stubs where a subsystem is not ready. Elaboration and static checks only.
> [...] What matters is that every generic, array bound, index expression and
> integer range is exercised at the true dimensions.
>
> 1. Whether it elaborates at all, and every error if not.
> 2. The memory footprint and elapsed time.
> 3. Which subsystems had to be stubbed and why.
> 4. Any bound, range or width that is tight at the real shape even where it
>    does not fail.

## The answer, up front

**It does not elaborate as it ships, and the reason is not a subsystem. It is
one signal declaration in `rtl/llama_top.vhd`.** Subsystem B's per-layer
recurrent state is modelled as a signal array of 201,326,592 bits; ghdl-mcode
costs ~228 bytes per scalar signal, so that one declaration wants **~46 GB**.
With `stmem`/`semem` shrunk in a throwaway copy and **nothing else changed**,
the whole composition -- real `matvec_int4`, real `gdn_block`, real
`attn_block` against the real `attn_kv_axi` over three AXI masters, real
`rmsnorm_rs`, the sampler on, B fed from the real regions -- elaborates at the
true 9B dimensions in **1.93 s and 2.09 GB**. So a real-shape elaboration gate
row is affordable today; it is blocked by a modelling choice, not by scale.

Getting there surfaced **six defects, every one of them invisible at
`mk_shape_scaled` and five of them shape-driven**:

| # | defect | how it shows at 9B | how it shows at 4/8/16 blocks scaled |
|---|---|---|---|
| R1 | `REGMAX` defaults to 4096; `region_max(mk_shape(MODEL,1))` is **12288** | nothing asserts it. Elaborates clean, then a bound-check error on the first FFN write in sim and a **silent 12-bit truncation in synthesis** | invisible: scaled `region_max` is 128 |
| R2 | subsystem B's state store is a signal array of 201,326,592 bits | ~46 GB, `STORAGE_ERROR` | 8,192 bits |
| R3 | `VN_W` defaults to 13, so a D-vec job is capped at 8191 elements; `OP_VEC_SWG` carries `n_rows = ffn = 12288` | `EC_NROWS` at run time on every FFN of every block. **No elaboration check exists** | invisible: scaled ffn is 128 |
| R4 | `attn_kv_axi`'s guard `NBLK*EXP_W/8 <= CH_B` is **unreachable at HEAD_DIM 256**: elaboration overflows first | `overflow detected`, no line, no message | the same illegal value prints the named assert |
| R5 | nothing checks that the K and V cache regions **fit `ADDR_W`**, only that they do not overlap each other | 2 x 34,816 B in a 65,536 B space elaborates clean; V wraps onto K | invisible: 2 x 544 B |
| R6 | `C_CTXLEN < 2**POS_W` with `POS_W = clog2(C_MAXPOS)` | at a power-of-two cache depth the **last position can never be used** | same defect, but nothing runs at `ctx = maxpos` |

R1, R3 and R5 are silent. R4 is loud but unattributable. R6 is the classic
off-by-one at a maximum, i.e. the same family as OI-7, OI-8 and OI-10.

**Elaborating is not computing.** Nothing below checks a value. Every claim
here is about shapes, widths and ranges.

## Corrections to the brief

All three factual claims in the brief were checked and all three hold, one of
them more strongly than stated.

- `hw/fk33/rtl/fk33_engine.vhd` instantiates exactly one entity,
  `matvec_int4_desc_axi` (line 1156). MEASURED, `grep -nE 'entity work\.'`.
- `llama_top` appears in **no** file under `hw/`. MEASURED, `grep -rl`.
- "The real 9B shape has never elaborated anywhere" is true and understates it.
  `mk_shape(MODEL, NCARDS)` occurs **exactly once in the entire VHDL tree**, as
  `rtl/llama_top.vhd:168`'s default. No bench passes it. So the configuration
  that had never been elaborated is the top level's own **default**
  configuration, which is the one a synthesis run gets if nobody overrides it.

One thing the brief implies that is **not** true: it is not subsystem B that
fails at the real shape. `gdn_block` elaborates standalone at the exact 9B
generics (`KEY_HEADS 16, VAL_HEADS 32, DIM 128, LAYERS 24`) in **0.35 s and
299 MB**, and another track has already OOC-synthesised it at those generics
(`hw/fk33/results/compose_2026-08-29/run_gdn_block.log`, `LAYERS bound to: 24`,
`DIM bound to: 128`). What fails is `llama_top`'s **model of the memory B talks
to**, which is a different file and a different fix.

## The procedure

Each step isolates one thing. Run it with `bash sim/elab9b_run.sh`.

1. **Import `rtl/*.vhd` into one library and `ghdl -m llama_top`.** Safe here
   and only here: `rtl/` has no duplicate entity or package names (MEASURED,
   `grep -oiE '^ *entity +\w+ +is' rtl/*.vhd | sort | uniq -d` is empty). The
   project rule against a single library covers `rtl+sim+tb`, which does have
   duplicates.
2. **`ghdl -r llama_top --stop-time=1ns` with no generic overrides.** This is
   the shipped default and therefore the real 9B shape. Controls for nothing;
   it is the baseline the rest is measured against.
3. **`-gA_BEHAV=true -gB_BEHAV=true`.** Removes both real compute subsystems,
   leaving D's spine, the region file, the locks and the exponent path. If this
   passes, the sequencer and the region model are not the wall.
4. **Flip A and B back on one at a time.** Separates the two.
5. **`gdn_block` standalone at the same generics.** Separates B's own RTL from
   `llama_top`'s model of B's memories. This is the step that moves the defect
   out of subsystem B.
6. **A throwaway copy of `llama_top.vhd` with `stmem`/`semem` shrunk to 1024
   entries and nothing else touched.** Answers "is the state store the *only*
   thing standing in the way", which the bisect above cannot answer on its own.
7. **A standalone cost probe**: one entity, one signal array, swept over size,
   plus the same array as a process variable. Turns "GHDL ran out of memory"
   into bytes per scalar signal, so the requirement can be stated as a number
   rather than as a crash.
8. **C's parameters at the real head dim**, swept: `C_KV_BLOCK`,
   `C_K_BASE`/`C_V_BASE`, `C_KV_ADDR_W`, `C_MAXPOS`/`C_CTXLEN`. The control
   that matters is running the *same* illegal `C_KV_BLOCK` at HEAD_DIM 32, 64
   and 256, which is what shows that a guard is unreachable rather than absent.
9. **`sim/elab9b_vn_probe.vhd`** issues one `OP_VEC_SWG` at `MODEL.ffn` rows
   into a standalone `seq_vec_issue`, at VN_W 13 and 14, with a
   `hidden`-sized job as the negative control so a refusal cannot be an
   always-refuse.

## The evidence

### The matrix, verbatim

`bash sim/elab9b_run.sh`, pristine tree, cap 20G:

```
elab9b: GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6) [Dunoon edition]
default          rc=137 peakRSS=20937980 kB  wall=0:10.70  expect=fail
    Command terminated by signal 9
stub_A_and_B     rc=0   peakRSS= 1109468 kB  wall=0:01.27  expect=ok
real_A           rc=0   peakRSS= 1358044 kB  wall=0:01.38  expect=ok
real_B           rc=137 peakRSS=20931092 kB  wall=0:10.80  expect=fail
    Command terminated by signal 9
real_C           rc=0   peakRSS= 1487072 kB  wall=0:01.53  expect=ok
real_norm        rc=0   peakRSS= 1209052 kB  wall=0:01.31  expect=ok
real_smp         rc=0   peakRSS= 1110356 kB  wall=0:01.30  expect=ok
kv_default_block rc=1   peakRSS=  812276 kB  wall=0:00.76  expect=fail
    /usr/bin/ghdl-mcode:error: overflow detected
    /usr/bin/ghdl-mcode:error: error during elaboration
kv_default_base  rc=1   peakRSS= 1378628 kB  wall=0:01.39  expect=fail
    rtl/llama_top.vhd:3664:7:@0ms:(assertion failure): llama_top: the K and V
    KV regions overlap.  Each is 34816 bytes.
kv_addr_wrap     rc=0   peakRSS= 1378348 kB  wall=0:01.38  expect=ok
kv_good          rc=0   peakRSS= 1378820 kB  wall=0:01.38  expect=ok
ctx_at_max       rc=1   peakRSS= 8893164 kB  wall=0:07.22  expect=fail
    rtl/llama_top.vhd:3657:7:@0ms:(assertion failure): llama_top: C_CTXLEN must
    fit in the cache and in POS_W.
ctx_one_short    rc=0   peakRSS= 8893508 kB  wall=0:07.05  expect=ok
all_but_B        rc=0   peakRSS= 1726188 kB  wall=0:01.69  expect=ok
vn13_swg_9b      rc=0   peakRSS=   13824 kB  wall=0:00.10  expect=ok
    elab9b_vn_probe: VN_W=13  2**VN_W=8192  OP_VEC_SWG n_rows=12288
                     (MODEL.ffn=12288, MODEL.hidden=4096)
    elab9b_vn_probe: REFUSED, err_code=EC_NROWS(2).  A D-vec job of 12288
                     elements does not fit VN_W=13.
vn14_swg_9b      rc=0   peakRSS=   13824 kB  wall=0:00.05  expect=ok
    elab9b_vn_probe: VN_W=14  2**VN_W=16384  OP_VEC_SWG n_rows=12288
    elab9b_vn_probe: ACCEPTED.  v_start='1' v_n=12288
vn13_hidden      rc=0   peakRSS=   13248 kB  wall=0:00.07  expect=ok
    elab9b_vn_probe: VN_W=13  2**VN_W=8192  OP_VEC_SWG n_rows=4096
    elab9b_vn_probe: ACCEPTED.  v_start='1' v_n=4096

elab9b: rows PASS 17 FAIL 0 (of which 5 were expected failures)
```

Whole matrix: **17 rows, about 50 s wall**, on a box that another track was
already using (`free -g` showed 10 GiB in use when this ran).

Unbounded, with no `MemoryMax`, `default` gets further and then dies properly:

```
Execution of /usr/bin/ghdl-mcode terminated by unhandled exception
raised STORAGE_ERROR : grt-table.adb:58 explicit raise
	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:18.24
	Maximum resident set size (kbytes): 24929896
```

### R2, the state store, sized

`rtl/llama_top.vhd:2731-2733`:

```vhdl
    constant STLY : positive := VH*DM*NBR;   -- state words per layer
    type stmem_t is array (0 to NLY*STLY-1)
                    of std_logic_vector(B_RECUR_LANES*16-1 downto 0);
    signal stmem : stmem_t := (others => (others => '0'));
```

DERIVED at `mk_shape(QWEN35_9B, 1)`: `NLY = 32 - 32/4 = 24`, `VH = 32`,
`DM = 128`, `NBR = DM/B_RECUR_LANES`, word width `B_RECUR_LANES*16`, so

    bits = NLY * VH * DM * DM * 16 = 24 * 32 * 128 * 128 * 16 = 201,326,592

which is **25.17 MB** and agrees exactly with the figure
`docs/2026-08-27_hbm-residency-map.md:191` already carries for the HBM-resident
GDN state. The lane count cancels, so `B_RECUR_LANES` cannot shrink it.
MEASURED, not assumed:

| `B_RECUR_LANES` | rc | peak RSS |
|---|---|---|
| 4 (default) | 137, killed at 20G | 20,931,092 kB |
| 16 | 137, killed at 20G | 20,930,368 kB |
| 32 | 137, killed at 20G | 20,930,600 kB |

Cost per scalar signal, MEASURED with a standalone probe (one signal array of
`NW` x 64 bits, `ghdl -r`, big stack):

| NW | scalar signals | peak RSS | wall | bytes/signal |
|---|---|---|---|---|
| 262,144 | 16,777,216 | 3,744,260 kB | 2.81 s | 228.6 |
| 1,048,576 | 67,108,864 | 14,950,580 kB | 11.64 s | 228.1 |
| 3,145,728 | 201,326,592 | killed at 26G | -- | -- |

The same 201,326,592 bits as a **process variable** instead of a signal:
**206,464 kB and 0.17 s.** A factor of about 220.

DERIVED requirement for `stmem` alone at 228 B/signal:
201,326,592 x 228 = **45.9 GB**, plus `semem` at 786,432 signals = 0.18 GB.

### R2, the fix bounded (probe, not committed)

A throwaway copy of `llama_top.vhd` with `stmem_t` and `semem_t` shrunk to
`0 to 1023` and **nothing else changed**:

| configuration | rc | peak RSS | wall |
|---|---|---|---|
| real A + real B | 0 | 1,724,128 kB | 1.71 s |
| real A + real B + `B_SRC_REAL` + real C + `C_KV_AXI` + `NORM_REAL` + `SMP_EN` | 0 | 2,092,672 kB | 1.93 s |

That copy lived only in the session scratchpad. **No RTL was changed in the
repository**, per the track brief.

### R4, the unreachable guard

Same illegal `KV_BLOCK`, three head dims, `attn_kv_axi` standalone, all other
generics fixed (`N_KVH 4, LAYERS 8, MAXCTX 4, POS_W 16, CM_W 8, EXP_W 8,
AXI_DW 256, ADDR_W 16`):

```
HEAD_DIM  KV_BLOCK  NBLK   result
   32        4       8     assertion failure: attn_kv_axi: one KV block must be
                           a whole number of 16-byte chunks
   32        8       4     assertion failure (same)
   32       16       2     ok
   64        4      16     assertion failure (same)
   64        8       8     assertion failure (same)
   64       16       4     ok
  256        4      64     overflow detected, error during elaboration
  256        8      32     overflow detected, error during elaboration
  256       16      16     ok
```

The trigger is `NBLK`, not `KV_BLOCK`, and it is independent of `MPB`:

```
HEAD_DIM 512, KV_BLOCK 16 -> NBLK 32, MPB 1  -> overflow detected
HEAD_DIM 128, KV_BLOCK  4 -> NBLK 32, MPB 0  -> overflow detected
HEAD_DIM  64, KV_BLOCK  4 -> NBLK 16, MPB 0  -> assertion failure (named)
HEAD_DIM 256, KV_BLOCK 32 -> NBLK  8, MPB 2  -> ok
```

GHDL attributes it to `work.attn_kv_axi(rtl).STMT_ELAB at attn_kv_axi.vhd:791`,
in process `p_wr`. The guard that exists for exactly this condition is
`attn_kv_axi.vhd:455`, `assert NBLK*EXP_W/8 <= CH_B`, and it never runs: GHDL
elaborates every declaration before any concurrent assert. `llama_top`'s own
mirror of the constraint (`llama_top.vhd:3650`) is dead for the same reason.

**`NBLK <= 16` therefore has zero margin at the real geometry**: the shipped
`HEAD_DIM 256 / KV_BLOCK 16` hits it exactly, and one step past it the
diagnostic disappears. The 27B target has the same `attn_head_dim` 256, so this
does not improve on retarget.

### R5, the missing address-space bound

`llama_top.vhd:3664` checks only that the two regions do not overlap **each
other**. It does not check that they fit `C_KV_ADDR_W`. MEASURED: with
`C_K_BASE = 0`, `C_V_BASE = 34816`, `C_KV_ADDR_W = 16`, the pair needs 69,632
bytes of a 65,536-byte space and the design **elaborates clean** (`kv_addr_wrap`
row, rc=0). The top 4,096 bytes of V wrap onto the first records of K.

### R6, the off-by-one at the cache maximum

`llama_top.vhd:3657`: `assert C_CTXLEN <= C_MAXPOS and C_CTXLEN < 2**POSW`,
with `POSW := clog2(C_MAXPOS)` (`:3387`). When `C_MAXPOS` is a power of two,
`2**POSW = C_MAXPOS` and the two clauses contradict at `C_CTXLEN = C_MAXPOS`.
MEASURED at `C_MAXPOS = 256`: `C_CTXLEN = 256` fails, `C_CTXLEN = 255` passes.
The usable context is `MAXCTX - 1`, and the assert blames the caller.

### The C cache model is elaborated even when the AXI cache replaces it

`llama_top.vhd:3483-3485` declares `kvhdr`/`kvmem` **outside** the `gkvaxi`
generate, so the behavioural KV cache exists even with `C_KV_AXI = true`.
MEASURED cost at the real shape, `C_KV_AXI` on throughout:

| `C_MAXPOS` | peak RSS | wall |
|---|---|---|
| 4 | 1,378,872 kB | 1.40 s |
| 16 | 1,735,092 kB | 1.65 s |
| 64 | 3,166,340 kB | 2.82 s |
| 256 | 8,893,260 kB | 7.28 s |

**29.8 MB per cache position**, all of it dead when `C_KV_AXI` is on.
DERIVED cross-check at `C_MAXPOS = 256`:
`kvmem = C_LAY*2*C_NKVH*C_MAXPOS*C_NBLK = 8*2*4*256*8 = 131,072` entries of
`KV_BLOCK*CM_W = 256` bits = 33,554,432 scalar signals; at 228 B/signal that is
7.65 GB against a measured delta of 7.51 GB.

### Bounds at the real shape that hold, with their margins

Reported because a bound that holds with no margin is the next defect.

| width | value | what the 9B shape needs | margin |
|---|---|---|---|
| `STEP_W` 11 | 2048 steps | `n_steps` = 24*16 + 8*13 + 3 = **491** | 4.2x |
| `d_raddr` 16 bits, 8 words per descriptor | 8192 steps | 491 | 16.7x |
| `ADDR_W` 16 (region-lock element address) | 65536 | `region_max` 12288 | 5.3x |
| `EPOCH_W` 4 | 16 epochs | not exercised here | not determined |
| `VN_W` 13 for `OP_VEC_NORM`/`OP_VEC_RES` | 8192 | `hidden` 4096 | 2x |
| `VN_W` 13 for `OP_VEC_SWG` | 8192 | `ffn` **12288** | **FAILS** |
| `NBLK <= 16` (`attn_kv_axi:455`) | 16 | `256/16` = **16** | **zero** |
| `smp_idx` 32 bits | 4.29e9 | `vocab` 248,320 | ample |
| `obs_tok_pos` 16 bits (`llama_top:4158`) | 65536 | `max_context` **262144** | **silent truncation, observability only** |

`VN_W` also does not survive the retarget: 14 bits admits the 9B `ffn` 12288
with 1.33x margin, but the 27B `ffn` is 17408 and needs 15.

## Measured and REJECTED -- do not retry

- **`ghdl -e llama_top` and `ghdl -m llama_top`.** Both return 0 and print
  nothing on a design that cannot be elaborated. `-m` finished the whole
  closure in **0.28 s / 45 MB** while `-r` on the same library needs 25 GB and
  dies. This is the project's recorded mcode trap and it fired here first.
- **Believing the default 8 MB stack.** The first `ghdl -r` died with SIGSEGV
  at 2.2 GB in 2.13 s, which reads as a GHDL bug. With `ulimit -s unlimited`
  the same command reaches 24.9 GB and raises a proper `STORAGE_ERROR`. Do not
  conclude anything about a large VHDL design from a segfault until the stack
  is raised.
- **Shrinking `stmem` via `B_RECUR_LANES`.** Measured at 4, 16 and 32; peak RSS
  is 20.93 GB in all three within 0.004%. The lane count cancels out of the bit
  total. Do not retry.
- **Overriding `SHAPE` from the command line.** It is a record generic;
  `ghdl -g` cannot set one. It does not need to: `mk_shape(MODEL, NCARDS)` is
  already the default, which is the whole point of this exercise.
- **Overriding a `real` generic** (`gdn_block`'s `EPS`) under ghdl-mcode:
  `unhandled type for generic override`. Not needed for any row above; noted so
  the next person does not build a harness around it.
- **Blaming subsystem B.** `gdn_block` standalone at `KEY_HEADS 16,
  VAL_HEADS 32, DIM 128, LAYERS 24` elaborates in **0.35 s / 299 MB** at
  `RECUR_LANES 4` and **0.37 s / 315 MB** at 32. The RTL is fine at the real
  shape; the model of its memory is not.
- **Assuming `C_KV_AXI = true` removes the behavioural cache.** It does not;
  see the 29.8 MB/position table. Turning the AXI cache on does not reduce the
  elaboration cost by one byte.

## Measurement traps hit

- **`ghdl -i` leaves every package marked obsolete.** Analysing
  `sim/elab9b_vn_probe.vhd` before `ghdl -m llama_top` fails with
  `package "llama_map_pkg" is obsoleted by package "model_cfg_pkg"`, which
  reads like a source error in the probe and is purely an ordering artefact.
  `sim/elab9b_run.sh` now builds the closure first and says why.
- **`systemd-run --scope` inherits the caller shell's `ulimit`, and a `for`
  loop in a fresh `bash -c` does not.** Three cost-probe rows reported
  plausible-looking RSS numbers that were really the RSS at a stack segfault
  (rc=139), i.e. **partial elaborations reported as measurements**. The tell is
  rc=139, not the number. Every row in this file has its rc printed beside its
  RSS for that reason.
- **A cost probe that declares the expensive object unconditionally measures
  nothing.** The first signal-vs-variable probe kept the signal array in scope
  in both modes, so "variable mode" reproduced the signal cost exactly and
  looked like a refutation. Two separate entities, not one with a `MODE`
  generic.
- **`peakRSS` under a `MemoryMax` cap is the cap, not the requirement.** Rows
  `default` and `real_B` report 20.9 GB because that is where the kill landed.
  The 24.9 GB figure is from an uncapped run and is still a floor, not the
  requirement; the requirement is the DERIVED 46 GB.
- **Machine contention.** `free -g` showed 10 GiB in use from another track
  during the matrix run. It changes wall times and it does not change any rc or
  any peak RSS in this file, because every row is capped and none of them is
  near the cap except the two that are meant to be.

## What was NOT determined

- **No value was checked anywhere.** This is an elaboration and static-range
  result only. A composed design that elaborates at the real shape is not a
  design that computes at the real shape, and nothing here moves the
  `err_unit_stub` / attention-stub position one inch.
- **No simulation was run at the real shape.** `--stop-time` is 1 ns or 2 us
  with no clock driven at the top level. Whether the 9B token schedule can be
  *walked* is open; R3 says the first FFN of the first block will refuse.
- **`EPOCH_W` was not exercised.** 4 bits is 16 epochs; nothing here issues an
  epoch, so the margin is unknown rather than large.
- **Vivado was not run.** The claim that R1's `natural range 0 to REGMAX-1`
  becomes a silent 12-bit truncation in synthesis, rather than the bound-check
  error GHDL gives, is **ESTIMATE** from the language rules, not measured.
- **The exact expression that overflows in R4 was not pinned down.** GHDL names
  `STMT_ELAB at attn_kv_axi.vhd:791` in `p_wr`; the trigger was localised to
  `NBLK > 16` by sweep, and the most likely site is the static slice
  `wbuf(0)(NBLK*EXP_W-1 downto 0)` at `:829` against a `CH_W = 128`-bit
  element, but that was not confirmed.
- **Whether `stmem` can legally become a process variable** was not
  established. The probe shrank the array; it did not convert it. The read port
  is registered and the write port is synchronous, so one process could own
  both, but the existing code reads and writes it from separate places and that
  restructuring was not attempted, and is not this track's to attempt.

## What to do about it, in order

Not applied. Every one of these is a change to `rtl/`, which this track was
told to read and not edit.

1. **R2.** Make `stmem`/`semem` process-local variables of a single owning
   process, or a `shared variable` of a protected type. Measured cost of the
   same bits as a variable: 206 MB and 0.17 s, against a derived 46 GB. This is
   the one change that makes the real shape reachable at all, and it is
   modelling only: the store is HBM-resident in the design
   (`docs/2026-08-27_hbm-residency-map.md:177`).
2. **R1 and R3.** Add two elaboration asserts to `llama_top`:
   `REGMAX >= region_max(SHAPE)` and `2**VN_W > region_max(SHAPE)`. Both are
   one line, both are checkable at elaboration, and both currently fail at the
   default shape. `VN_W` must go to 14 for 9B and 15 for 27B.
3. **R4.** Hoist `NBLK*EXP_W/8 <= CH_B` out of a concurrent assert into
   something evaluated during declaration elaboration -- the project's own
   recorded technique is an out-of-range `natural` constant, which is also what
   makes it survive Vivado.
4. **R5.** Add `max(C_K_BASE, C_V_BASE) + region_bytes <= 2**C_KV_ADDR_W`.
5. **R6.** `POSW := clog2(C_MAXPOS + 1)`, or drop the `C_CTXLEN < 2**POSW`
   clause, which `C_CTXLEN <= C_MAXPOS` already implies once the width is
   right.
6. **The dead behavioural cache.** Move `kvhdr`/`kvmem` inside the
   `not C_KV_AXI` branch. 29.8 MB per position of elaboration cost, for storage
   nothing reads.
7. **Then make `sim/elab9b_run.sh` a gate row.** After (1) the whole matrix is
   ~50 s and under 2.5 GB, which is cheaper than several existing rows. It must
   stay out of the `tb_*.vhd` glob or it becomes everyone's problem.

Also worth noting for whoever owns the banner: `llama_top.vhd:1056-1058` prints
"ATTENTION IS A STUB" unconditionally, including when `C_REAL` is true and the
real `attn_block` is instantiated. The `:3540` / `:3548` report below it says
the opposite. Cosmetic, but the two disagree in the same log.

## Files

- `sim/elab9b_run.sh` -- the whole matrix, one row at a time, memory-capped.
  Not a `tb_*.vhd`, deliberately.
- `sim/elab9b_vn_probe.vhd` -- the `VN_W` question, with its negative control.
