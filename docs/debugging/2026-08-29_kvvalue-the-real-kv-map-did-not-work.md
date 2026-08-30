# The real 9B KV map did not work, and elaborating is exactly why nobody knew

**Date** 2026-08-29. **Track** KVVALUE. **Base commit** `bdc998c`
("worklog: the ownership and in-flight tables named four dead owners..."),
pinned with `SHA=$(git rev-parse HEAD)` as its own step before any
`git archive`, and both archives verified by md5 of `rtl/attn_block.vhd`
(`e35875c29b60979c57dc4b42bd7ff2ef`) and `rtl/llama_top.vhd`
(`62695392d1fb92465ca15744cb08148d`) against `git show HEAD:`. An earlier pin
at `da34b50` was superseded when HEAD moved twice under the run.

**Hardware** none. Nothing here opened `/dev/xdma*`, ran `xsdb`, `hw_server`,
`vivado ... program`, or touched `hw/fk33/`.

**Machine at start**, MEASURED with `df -h` / `free -g`: root
`/dev/nvme1n1p6` 38 G free at 98 percent, `/mnt/storage` 388 G, RAM 31 G with
18 G available and 15 G of swap in use. Root was cleared to 121 G free at 91
percent mid-run by the coordinator. Every artefact of this track is on
`/mnt/storage`.

---

## 1. The question, verbatim

> TRACK CKVMAP just made subsystem C's real 9B KV map **elaborate** [...] **It
> was explicit about what it did NOT establish, and that is your job:**
>
> > No **value** was checked -- everything is shapes, widths and addresses at
> > elaboration. **The real map elaborating is not the real map working.**
>
> **1. Prove the real KV map computes, not just elaborates.** Build an oracle
> at the level of the KV path's OUTPUT and compare numbers. Multi-token, so
> the cache is actually read back across positions [...]
>
> **2. Close the two guards CKVMAP measured as NOT biting** [...] "A base one
> chunk off the manifest elaborates clean. Nothing links the RTL to
> `hbm.kv_base`; only the gate row pins it." [...] "A stale byte number under
> the new name (`-gC_V_BASE_CH=34816`) elaborates clean and means byte
> 557,056."

And, mid-task, from the coordinator:

> **The port map is now the one place the domain can go wrong**, so it is the
> highest-value spot for a teeth-check. A mutation that deletes the shift, or
> shifts the wrong way, or shifts by 3 or 5, should be in your table with its
> verdict.

---

## 2. The answer, up front

**THE REAL KV MAP DID NOT WORK. The first time anything at the real bases was
asked to move a byte, it died.** MEASURED, GHDL 1.0.0 mcode, `attn_kv_axi` at
the manifest's `hbm.kv_base`:

```
/usr/bin/ghdl-mcode:error: overflow detected
in process .tb_attn_kv_map(sim).dut@attn_kv_axi(rtl).gen_rd(1).p_rd
  from: ieee.numeric_std.to_integer at numeric_std-body.vhdl:3042
/usr/bin/ghdl-mcode:error: simulation failed          rc=1
```

`rtl/attn_kv_axi.vhd` took the low bits of an address by writing
`to_integer(a) mod 4096` and `to_integer(a0) mod BEAT_B`, at **four** sites.
`natural'high` is 2,147,483,647 and the K base alone is 4,521,582,592, so the
conversion is out of range before the modulus is ever applied. **This is the
same wall CGENERICS hit on the generic and CKVMAP closed by counting the base
in chunks -- the generic stopped being a byte count, and the module's internal
arithmetic did not.** Every existing KV bench ran with bases under 36 MB, so
none of them could reach it.

**Fixed** by taking the low bits as BITS (`low_bits(a,n) = to_integer(resize(a,n))`,
exact for a power-of-two modulus at every `ADDR_W`), and then **proved on
values**: `sim/tb_attn_kv_map.vhd`, a new bench, at the real bases, the real
`MAXCTX = 131072`, 8 layers, 4 KV heads, HEAD_DIM 256, over a five-token
three-layer sequence.

```
tb_attn_kv_map: PASS -- rtl/attn_kv_axi.vhd at the REAL 9B KV map (K base
chunk 282598912 of 16 bytes, V base chunk 353902080, MAXCTX 131072, 8 layers,
4 KV heads, HEAD_DIM 256): 304 records read BIT-EXACT, 120 records written and
their 3128-chunk memory image BIT-EXACT at independently computed addresses,
with no stray chunk anywhere in the 5.7 GB region
```

**A SECOND, SEPARATE DEFECT fell out of the mutation table and is also
fixed.** A base that is not 16-byte aligned is not merely unchecked: the two
engines DISAGREE about it. The read engine computes
`ph_ch = low_bits(a0,BEAT_LW)/CH_B`, an integer divide by 16, so an offset of
1..15 bytes is quantised away and reads are correct; the write engine keeps
the same offset as `phase` and shifts every strobe by it, so **the record lands
late and byte 0 of its first chunk is never written at all**. Silent one-byte
cache corruption with the reader unable to see the cause. `attn_kv_axi` now
raises `err` on it, which is the only home that check has left -- CKVMAP
correctly retired `llama_top`'s version when the generic became a chunk count,
but this module's port is still a byte address.

**Both of CKVMAP's non-biting guards are CLOSED**, by `tools/check_kv_map.py`:
16 rows linking `tools/hbm_map.py`'s authority, the packed model's manifest,
`rtl/llama_top.vhd`'s generic names and chunk-to-byte shift, and
`sim/realshape_gate.sh`'s `real_kv_map` values. Its own teeth are 17 rows and
**17 of 17 behave as intended**, including `k_base_one_chunk_high` (CKVMAP's
`k_base_off_by_one_ch`) and `v_base_the CKVMAP stale byte 34816`.

**The port-map shift the coordinator asked about is verified two ways**: read
out of `rtl/llama_top.vhd` and compared against `log2(granule)` by the
checker, and mutated to 0, 3 and 5 in the value oracle, where all three are
KILLED. Neither route is a claim about `llama_top` running; section 8 says
what does not transfer.

---

## 3. The procedure, in order, and what each step isolates

1. **Verify the coordinator's and CKVMAP's account of the port map against the
   RTL**, before anything rests on it. Isolates two write-ups from the source.
2. **Probe `to_integer` on a 33-bit unsigned above `integer'high` in
   isolation**, five lines, before touching any design file. Isolates the
   language fact from the design.
3. **Read both existing KV benches for whether either CAN express the real
   map.** Isolates "no bench found this" from "no bench could have".
4. **Write the value oracle** -- new file, chunk-domain addresses, sparse
   memory, coordinate-stamped payload -- and run it on the UNMODIFIED RTL.
   That run is the measurement of the defect, and it is taken before the fix
   so the fix cannot be the thing that produced it.
5. **Fix the four sites**, re-run, and check the three pre-existing KV benches
   still pass so the fix is not paid for elsewhere.
6. **Mutate**, 18 rows, generic and RTL, with the control run FIRST.
7. **Build the manifest link**, then **teeth it**, 17 rows, before wiring it
   into a gate.
8. **Attribute everything against a clean pinned archive**, because the
   working tree went red in `rtl/attn_block.vhd` mid-run and that file belongs
   to another track.

---

## 4. The evidence, as raw output

### 4.1 The port map, verified against the RTL rather than the write-ups

MEASURED by reading `rtl/llama_top.vhd` at `bdc998c`. The coordinator's and
CKVMAP's account is CONFIRMED and is exact:

```vhdl
    constant KBASE_C : std_logic_vector(C_KV_ADDR_W-1 downto 0)
                     := std_logic_vector(shift_left(
                          to_unsigned(C_K_BASE_CH, C_KV_ADDR_W), 4));
    ...
          k_base => KBASE_C, v_base => VBASE_C,
```

and `rtl/attn_kv_axi.vhd`'s `rec_addr` is `unsigned(base) + idx*REC_B` with
`REC_B` in bytes, so `base` must be bytes. The domain changes at the port map
and only there.

### 4.2 The language fact, in isolation (MEASURED)

```
$ ghdl -r --std=08 probe1
probe1.vhd:9:(report note): integer'high = 2147483647
probe1.vhd:11:(report note): chunk read-back = 282598912
probe1.vhd:12:(report note): about to call to_integer(a)
/usr/bin/ghdl-mcode:error: overflow detected
  from: ieee.numeric_std.to_integer at numeric_std-body.vhdl:3042   rc=1
```

`a` is `shift_left(to_unsigned(282598912, 33), 4)` = 4,521,582,592, the
manifest's `hbm.kv_base`. The 33-bit value is fine; the conversion is not.

### 4.3 Why neither existing bench could have found it

MEASURED by reading them, not inferred:

| bench | address model | bases it runs at | reaches the real map? |
|---|---|---|---|
| `sim/kv_axi_harness.vhd` | DENSE `ba_t is array (0 to NB_MAX-1)`, `NB_MAX` 131072 bytes; `rec_addr` returns `integer` | from the vector file, under 36 MB | **no** -- `integer` cannot hold 4.5e9 |
| `sim/tb_attn_kv_seam.vhd` | dense, `ADDR_W` 16 | K 16, V 4064 | **no** |
| `sim/tb_attn_kv_quant.vhd` | quantizer only | n/a | no |

The dense array is the binding constraint, not an oversight: the real region
is 5.7 GB and a byte array of it is not a thing a simulator can allocate.

### 4.4 THE DEFECT, in situ, on the UNMODIFIED RTL

```
$ ghdl -r --std=08 --workdir=work tb_attn_kv_map
/usr/bin/ghdl-mcode:error: overflow detected
in process .tb_attn_kv_map(sim).dut@attn_kv_axi(rtl).gen_rd(1).p_rd
  from: ieee.numeric_std.to_integer at numeric_std-body.vhdl:3042
/usr/bin/ghdl-mcode:error: simulation failed          rc=1
```

Four sites, all `to_integer(<absolute byte address>) mod <power of two>`:

| site (pre-fix line) | expression | reached |
|---|---|---|
| `burst_len` `:416` | `(4096 - (to_integer(a) mod 4096))/BEAT_B` | every AR and AW |
| read engine `:758` | `ph_ch <= (to_integer(a0) mod BEAT_B)/CH_B` | every run open |
| read engine `:759` | `a0 - to_unsigned(to_integer(a0) mod BEAT_B, ADDR_W)` | every run open |
| write engine `:897` | `phase := to_integer(a0) mod BEAT_B` | every record write |

All three engines are hit; the mutation table's three `revert_*` rows below
reproduce each independently.

### 4.5 The fix, and the run after it

```
$ ghdl -r --std=08 --workdir=work tb_attn_kv_map            rc=0   wall 0.34 s
tb_attn_kv_map: phase A done -- 64 preseeded records read back, 0 mismatches so far
tb_attn_kv_map: COVERAGE  records read 304  written 120  image-checked 184
  chunks resident 3128 | AR 132/135  at the 16-beat cap 47/47
  phase-16 runs 70/73  ending on 4 KB 0/0 | AW 120  B 120
  write bursts at the cap 0  phase-16 writes 48
tb_attn_kv_map: PASS -- ... 304 records read BIT-EXACT, 120 records written and
  their 3128-chunk memory image BIT-EXACT at independently computed addresses,
  with no stray chunk anywhere in the 5.7 GB region
```

`3128 = 184 records x 17 chunks`, checked as an equality against
`mem.count`, so the region holds the expected chunks **and nothing else**.

### 4.6 The three anchors, and why this is not a round trip

A packer plus a reversed unpacker passes its own self-test; this project has
the recorded case. So:

* **A1 -- the read path against memory the RTL never wrote.** Phase A preseeds
  layers 1 and 5 DIRECTLY into the sparse memory at addresses the bench
  computes, then asks the DUT for them. 64 records, all bit-exact. Nothing the
  write master does can make this pass.
* **A2 -- the write path against an independently computed address.** Every
  record phase B wrote is compared byte for byte at the chunk address the
  BENCH computes, not the one the DUT used. Two masters agreeing on a wrong
  address is exactly what a read-back-only check cannot see.
* **A3 -- no stray writes.** `mem.count` must equal `nimg*CPR` exactly. A1 and
  A2 say every expected chunk is right; A3 says there are no others. Together
  they are set equality.

And the payload carries its own coordinates: `(region, layer, kv head,
position)` are stamped into fixed slots of the header and of **every** mantissa
block, with the block index alongside, and any chunk that was never written
reads back as **-128 in every byte**, a value the encoding cannot produce. So a
misaddressed read returns data that DECODES to the wrong coordinates, and the
failure message names the record that was actually reached. That is why the
`k_one_byte` row below prints `rtl -128` rather than two unequal integers.

### 4.7 The coverage this run reaches, and what it cannot

| mechanism | reached |
|---|---|
| the AXI3 16-beat cap on reads | 47 K bursts, 47 V bursts |
| the 16-byte record phase | 70 K runs, 73 V runs (phase is 16 for ODD `pos`, DERIVED: `kv_base mod 32 = 0` and `272 mod 32 = 16`) |
| partially strobed write beats | 48 |
| records read AT record phase 16 | 128 of 304 |
| a burst ENDING on a 4 KB boundary | **0** |
| a write burst at the 16-beat cap | **0** at `AXI_DW` 256, **120 of 120** at 128 |

Both bases are 4 KB aligned (DERIVED: `4521582592 = 4096*1103902` and
`5662433280 = 4096*1382430`, both exact) and the runs are short, so no read
burst reaches a 4 KB line. The first three rows are enforced as GATE
conditions inside the bench, not merely printed: a splitter that never split
and a phase that was always zero would satisfy every other check.

**THE PHASE COUNT IS TAKEN FROM THE ORACLE, NOT FROM THE SLAVE, AND THE
DIFFERENCE MATTERS.** The slave can only count ARs that do not begin on a
record boundary (70/73 here), which is a SUPERSET: every continuation AR of a
split run qualifies whatever the phase is. The exact number is
`(16*chunk(record)) mod BEAT_B`, and `16*chunk` overflows `integer` at the
real map, so it is computed as `chunk mod BEAT_CH` -- the same number on the
index that fits. 128 of 304 is the DERIVED expectation: `kv_base mod 32 = 0`
and `272 mod 32 = 16`, so the phase is 16 for exactly the odd positions.

**BOTH AXI WIDTHS RUN AT THE REAL MAP, and neither covers what the other
does.** MEASURED, same bench, `-gAXI_DW=128 -gRBUF=3`:

```
AXI_DW 256   AR 132/135  cap 47/47   records at phase 16 128   AW 120  cap 0
AXI_DW 128   AR 270/285  cap 164/167 records at phase 16   0   AW 240  cap 120
```

At 256 a single-record write is 9 beats and never splits, so the write-side
splitter is UNREACHED; at 128 a record is exactly 17 beats and splits 16 + 1,
so it is reached on every one of the 120 records -- and there the phase is
always zero and the realignment mux cannot be reached at all. Both PASS. The
128 case is `control_dw128` in `sim/mutate_kv_map.sh` so it stays runnable;
the gate row is 256, the FK33 HBM SAXI width.

### 4.8 Teeth on the bench: `bash sim/mutate_kv_map.sh`

19 rows, controls first. **14 KILLED, 2 SURVIVED (both controls), 3 ABORT.**

```
control                  SURVIVED   the unmutated bench, unmutated RTL
control_dw128            SURVIVED   the same at AXI_DW 128
shift_0                  KILLED     READ ADDRESS FAULT, master 0 chunk 26575328
                                    is sub-region -114 (layer -28)
shift_3                  KILLED     READ ADDRESS FAULT ... chunk 150212352
shift_5                  KILLED     READ ADDRESS FAULT ... chunk 37239808
k_one_chunk_hi           KILLED     HEADER MISMATCH want (reg 0 lay 1 hd 0
                                    pos 0) blk 4  oracle 19 rtl 0
k_one_chunk_lo           KILLED     READ ADDRESS FAULT ... sub-region 3 (layer 0)
                                    but the job is layer 1
v_one_chunk_hi           KILLED     HEADER MISMATCH (reg 1 ...)  oracle -20 rtl 0
k_one_byte               KILLED     HEADER MISMATCH ... oracle 0 rtl -128
                                    + attn_kv_axi RAISED err at 75 ns
k_one_rec_hi             KILLED     HEADER MISMATCH ... oracle 0 rtl 1
kv_swapped               KILLED     READ ADDRESS FAULT ... sub-region 36 (layer 9)
lay_stride_gone          KILLED     READ ADDRESS FAULT ... sub-region 0 (layer 0)
lay_head_swap            KILLED     READ ADDRESS FAULT ... sub-region 1 (layer 0)
ctx_stride_off           KILLED     READ ADDRESS FAULT ... chunk 291511740
pos_off_by_one           KILLED     HEADER MISMATCH ... oracle 0 rtl 1
rec_b_off                KILLED     READ ADDRESS FAULT ... chunk 290987520
revert_to_integer_read   ABORT      to_integer at numeric_std-body.vhdl:3042
revert_to_integer_write  ABORT      ... in .dut@attn_kv_axi(rtl).p_wr
revert_to_integer_4k     ABORT      ... in .dut@attn_kv_axi(rtl).gen_rd(1).p_rd
```

**The three ABORT rows are the teeth on the FIX and they are deliberately not
counted as kills.** Each puts one `to_integer` back and the run dies exactly
the way section 4.4 does, in the process the site belongs to. `mutverdict.py`
is right to call that ABORT: the checker was not shown to catch it, the
LANGUAGE was. That is the correct classification and it is also the entire
point -- a defect that kills the simulator is not a defect a value checker can
be credited with finding.

**`k_one_byte` bit in two independent ways** and the pair is worth reading
together: `attn_kv_axi` refuses the configuration at 75 ns (the new alignment
check) AND the data check catches the corruption at 18,815 ns. The second is
what discovered the defect; the first is what now prevents it.

### 4.9 The manifest link: `python3 tools/check_kv_map.py`

```
  ok      record granule divides                                   kv_record_bytes 272 % 16 = 0
  ok      record = header + HEAD_DIM*CM_W/8                        272 vs 16 + 256*8/8 = 272
  ok      header fits the granule                                  NBLK 8 exponent bytes into a 16-byte header chunk
  ok      KV block divides HEAD_DIM and leaves >= 2 blocks         HEAD_DIM 256 / C_KV_BLOCK 32 = 8 blocks
  ok      per-layer per-token bytes = 2*N_KVH*REC_B                2176 vs 2*4*272 = 2176
  ok      llama_top KBASE_C shifts by log2(granule)                shift_left(..., 4), want 4 = log2(16)
  ok      llama_top VBASE_C shifts by log2(granule)                shift_left(..., 4), want 4 = log2(16)
  ok      C_K_BASE_CH*16 == manifest hbm.kv_base                   282598912 * 16 = 4521582592 vs kv_base 4521582592  (delta 0 bytes)
  ok      manifest kv_record_bytes agrees with the shape           272 vs 272
  ok      manifest kv_layers agrees with the shape                 8 vs 8
  ok      manifest kv_bytes_per_token agrees with the shape        17408 vs 17408
  ok      C_V_BASE_CH*16 == kv_base + (bytes_per_token/2)*C_MAXPOS 5662433280 vs 4521582592 + 8704*131072 = 5662433280
  ok      the K+V region ends below desc_arena_base                region ends at 6803283968, descriptor arena starts at 8584548352, margin 1781264384 bytes
  ok      V region starts where K's ends                           353902080 vs 282598912 + 8*4*131072*17 = 353902080
  ok      K and V do not overlap                                   each region is 71303168 chunks; bases 282598912 and 353902080
  ok      C_KV_ADDR_W - 4 >= clog2(top chunk)                      clog2(425205248) = 29, C_KV_ADDR_W - 4 = 29  (slack 0 bit(s))
check_kv_map: 16 rows, 0 refused, 0 not run
```

### 4.10 Teeth on the checker: `python3 tools/check_kv_map.py --teeth`

**17 of 17 rows behaved as intended.** The two that answer the brief directly:

```
  k_base_one_chunk_high     REFUSED
        REFUSED C_K_BASE_CH*16 == manifest hbm.kv_base   282598913 * 16 = 4521582608
                vs kv_base 4521582592  (delta 16 bytes)
  v_base_the CKVMAP stale byte 34816   REFUSED
        REFUSED C_V_BASE_CH*16 == kv_base + (bytes_per_token/2)*C_MAXPOS
                557056 vs 4521582592 + 8704*131072 = 5662433280
```

and the seam rows the coordinator asked for:

```
  the seam shifts by 3      REFUSED   shift_left(..., 3), want 4 = log2(16) --
                                      the cache would sit at 2**-1 times the
                                      arena base, and that elaborates cleanly
  the seam shifts by 5      REFUSED
  the seam does not shift   REFUSED
```

plus `k_base_one_chunk_low`, `k_base_a_stale BYTE number under the _CH name`,
`v_base_one_chunk_high`, `maxpos_halved`, `addr_w_one_short`,
`kv_block_illegal`, `the arena moved by one page`, `the model grew a KV head`,
`the model grew an attention layer`, `the record lost a byte`, `C_CM_W
doubled`, and the control, which is accepted.

### 4.11 The gates, on clean pinned archives

The working tree was RED in ten rows when first run. **That was contention,
not this track**: `rtl/attn_block.vhd:1022: constant "g" is not visible here`,
a file this track must not touch, mid-edit by another. Everything below is a
`git archive` of `bdc998c` with, in the `mine` copy, only this track's six
files overlaid.

```
base (archive, nothing changed)   REALSHAPE GATE: PASS  rows 24 (13 guards that must refuse)
mine (archive + this track)       REALSHAPE GATE: PASS  rows 25 (13 guards that must refuse)
                                  row kv_map_manifest_link ok  16 rows
mine  default_9b   rc=0 peakRSS=2302732 kB wall=2.07
mine  all_real     rc=0 peakRSS=2618880 kB wall=2.30
mine  real_kv_map  rc=0 peakRSS=1261452 kB wall=1.33
```

The KV value gates on the `mine` archive, unfiltered within the filter:

```
PASS  sim:tb_attn_kv_axi     2s
PASS  sim:tb_attn_kv_map     1s     <- new
PASS  sim:tb_attn_kv_quant   1s
PASS  sim:tb_attn_kv_seam    9s
 OVERALL PASS 4  FAIL 0  NOVERDICT 0  TIMEOUT 0  BUILD-ERROR 0  NOCHECK 0  SKIPPED 0
 REGRESSION: PASS
```

**The third field is elapsed SECONDS, not a check count** (`sim/regress.sh:1736`).

### 4.12 The FULL unfiltered gate, both suites, on the `mine` archive

23 minutes wall, alongside TRACK WRITEDEC's own full run on the same box.
Unfiltered, last `OVERALL` line verbatim:

```
 suite sim   PASS 70   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 96   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 6
 REGRESSION: PASS
PASS       sim:tb_attn_kv_map                     0s
```

The four NOCHECK rows are `sim:tb_attn_beh`, `sim:tb_gdn_conv_cycles`,
`sim:tb_swchain_beh` and `tb:tb_engine_dbg`; the six SKIPPED are the
`library beh` post-synthesis compares that need xsim and UNISIM. None is this
track's and none changed.

**96 is not 93 + 1, and I am not raising the floor on the strength of it.**
`BASELINE_PASS` is 93, recorded by TRACK GATEHYGIENE as a clean-archive
ceiling; this is a clean archive plus this track's six files and it measures
96, so two rows besides mine have been fixed or added since that measurement
by other tracks. A floor is a MINIMUM, so a new passing row cannot breach it
and nothing had to change -- and `sim/regress.sh` is the shared file this
project lost six documents to an index race on today. **It should go to 94 on
this track's account alone**, and whoever next holds that file quiescent
should measure the true ceiling rather than take 96 from here: this run was
against an archive, not a clone, and it overlapped another full run.

### 4.13 The final state, re-verified on a clean archive of the tip

`git archive 662b247`, md5 of `sim/tb_attn_kv_map.vhd` matched against
`git show`:

```
tb_attn_kv_map                       rc=0   PASS   304 records, 3128 chunks
tools/check_kv_map.py                       16 rows, 0 refused, 0 not run
tools/check_kv_map.py --teeth               17 of 17 teeth rows behaved as intended
sim/realshape_gate.sh                REALSHAPE GATE: PASS  rows 25
```

---

## 5. Measured and REJECTED -- do not retry

* **Do not try to reach the real map from `sim/kv_axi_harness.vhd` or
  `sim/tb_attn_kv_seam.vhd`.** Both model memory as a DENSE byte array and
  both compute the record address in a VHDL `integer`. The real base is 2.1x
  `integer'high` and the region is 5.7 GB. Neither obstacle is a parameter.
* **Do not "fix" the overflow by widening a variable.** There is no wider
  standard integer in VHDL-2008 and `to_integer` returns `INTEGER` by
  definition. The fix is not to convert at all: all four call sites wanted a
  power-of-two modulus, which is a bit slice.
* **Do not read a green `sim/realshape_gate.sh` -- including its own
  `real_kv_map` row -- as evidence that the KV path works.** MEASURED here:
  `real_kv_map` passes on the UNFIXED tree, at the real bases, while the same
  configuration kills the simulator the moment it is asked to move a byte.
  That row is an elaboration row and says so; this is the concrete instance of
  the general warning.
* **Do not expect a `llama_top` run to cover this.** CKVMAP already recorded
  that `C_MAXPOS`'s default cannot become 131,072, and the `tb_llama_top`
  family runs the behavioural cache. The real map is a build configuration and
  the only things that exercise it are `realshape_gate`'s five rows (shapes)
  and `sim/tb_attn_kv_map.vhd` (values).
* **Do not add an alignment check to `rtl/llama_top.vhd`.** CKVMAP retired the
  one that was there and was right to: with the bases counted in chunks, an
  unaligned base is not representable from that level. The check belongs in
  `attn_kv_axi`, whose port is a byte address, and that is where it now is.
* **Do not treat `mem.count` as a weak check.** It is what turns "every
  expected chunk is correct" into "and there are no others", and it is the
  only thing in the bench that can see a record written twice.

---

## 6. Corrections to my brief and to what reached me

1. **CLOG2's "`C_MAXPOS = 131,072` cannot elaborate, and the overflow moves
   into `llama_top`'s own `constant KVREG_B : natural := C_LAY*C_NKVH*
   C_MAXPOS*REC_B_C`" is about a constant that DOES NOT EXIST on this HEAD.**
   MEASURED at `bdc998c`: `grep -n "KVREG_B" rtl/llama_top.vhd` is empty. The
   constant in that generate is `KVREG_CH`, in 16-byte chunks
   (`:3962`), and it is 71,303,168, not 2,281,701,376. CKVMAP's chunk encoding
   removed the byte-domain form CLOG2 measured. Independently confirmed by
   running it: on a clean archive of `bdc998c` with NOTHING changed,
   `real_kv_map` at `-gC_MAXPOS=131072 -gC_K_BASE_CH=282598912
   -gC_V_BASE_CH=353902080 -gC_KV_ADDR_W=33` is **rc=0, 1,261,260 kB, 1.33 s**.
   CKVMAP's claim reproduces; CLOG2's applies to a tree before `9d287f2`.
2. **"The rename to `_CH` does not defend against copying the number alone,
   and nothing in the RTL can" is right, and the conclusion "so it cannot be
   closed" does not follow.** It cannot be closed IN THE RTL, because 34,816
   is a legal chunk count and the arena is not in the RTL. It is closed
   OUTSIDE it, by the same artefact that closes the off-by-one-chunk guard,
   and the teeth row for exactly that value REFUSES.
3. **My brief said the two guards were the second task after proving values.
   In practice the manifest link is the cheaper and more durable of the two
   results**, because it is what stops the numbers this track just verified
   from silently going stale. The value oracle proves today's map; the checker
   is what notices when the arena moves.

---

## 7. Measurement traps hit, including my own

* **I nearly reported the coverage line's zeros as a fault.** `ending on 4 KB
  0/0` and `write bursts at the cap 0` look like the splitter never ran. They
  are correct and DERIVED: both bases are 4 KB aligned, so a short run cannot
  reach a 4 KB line, and a 9-beat write cannot reach a 16-beat cap. The rows
  that DO gate -- the 16-beat read cap and the phase-16 run -- are asserted
  inside the bench precisely so that a genuinely dead mechanism cannot hide
  among honest zeros.
* **My first fix attempt was to the wrong end of the seam.** The instinct on
  seeing `overflow in to_integer` at the real base is to change the base's
  representation, which is what CKVMAP already did and is not the problem. The
  overflow is in the CONSUMER of the byte address, four sites down.
* **`cd X && cmd` does NOT persist the working directory between Bash calls
  here, but a bare `cd` in its own call does.** I copied a stale scratch file
  over a fixed repo file because I believed the cwd was the scratch tree. The
  edit was lost silently and the same compile error reappeared, which reads
  exactly like a failed edit. Check `pwd` before any `cp` between trees.
* **A generate-indexed signal is not optional in the read slaves.** Copied
  verbatim from `sim/kv_axi_harness.vhd:158-172`, which records that assigning
  `r_rdata(<expression>)` makes the WHOLE vector the longest static prefix and
  presents as the DUT reading zeros from a correct memory. Not re-derived,
  because that trap costs a day and the note existed.
* **A full-gate run failing in files this track cannot have touched is
  contention.** Ten rows of `realshape_gate` were red on the working tree with
  `rtl/attn_block.vhd:1022: constant "g" is not visible here`. Re-run on the
  archive: PASS 24 (base) and PASS 25 (mine).
* **I EDITED FILES INSIDE A TREE THAT HAD A GATE RUNNING ON IT.** While the
  full `regress.sh` was running against the `mine` archive I copied two later
  versions of `sim/tb_attn_kv_map.vhd` into it for the `AXI_DW = 128`
  experiments. `regress.sh` re-execs a private copy of ITSELF so the script
  was safe, but each row analyses its sources when that row runs, so a row
  after the copy would have seen a different file. It happens that
  `sim:tb_attn_kv_map` had already produced its result, and section 4.13
  re-runs the whole thing on a clean archive of the tip, so nothing here rests
  on the ambiguous window -- but the mitigation was luck, not design. CKVMAP
  recorded the same collision from the other side. **Use a second archive for
  experiments; do not reuse the one a gate is reading.**
* **`ghdl -r ... | head` reports the PIPELINE's rc.** Every rc here is from an
  unpiped run or `${PIPESTATUS[0]}`. Restated because it was hit once more in
  the first analysis loop.
* **The third field of a `regress.sh` result line is elapsed SECONDS**
  (`sim/regress.sh:1736`). Carried from CKVMAP, not re-learned.

---

## 8. What this does NOT establish

* **It is `attn_kv_axi`, not `llama_top`.** `sim/tb_attn_kv_map.vhd`
  instantiates the cache directly. The chunk-to-byte shift is REPRODUCED in
  the bench (`BASE_SHIFT`, `KB_C`/`VB_C`) so that it can be mutated, and all
  three mutations of it are killed -- but **a green run of this bench is not a
  statement that `rtl/llama_top.vhd:3715-3720` is correct.** What checks that
  line is `tools/check_kv_map.py`, which reads the shift amount out of the
  source and compares it to `log2(granule)`; that is a source check, not an
  execution. Running `llama_top`'s KV path on values at the real map is not
  possible today and is not in this track's scope.
* **`C_MAXPOS` is the real 131,072 in the bench's ADDRESS ARITHMETIC and
  nowhere else.** `MAXCTX` is the per-(layer,head) stride, and the stride is
  what is real: 131,072 x 272 = 35,651,584 bytes per sub-region. The positions
  actually swept are 0..3 (phase A) and 0..4 (phase B). **A defect that needs
  position 70,000 to appear is not reachable here**, and neither is any
  `POS_W`-width effect above 5.
* **Layers 2, 4 and 6 are never touched**, deliberately: phase A uses 1 and 5,
  phase B uses 0, 3 and 7, and the untouched ones stay poison so a stride
  error lands somewhere that reads back as -128. All four KV heads are covered
  in both phases; all 8 blocks of every record are covered.
* **The gate row is `AXI_DW` 256 only.** The 128 case runs and passes, but
  only as `control_dw128` in `sim/mutate_kv_map.sh`, which nothing runs
  automatically. See section 9.
* **Not attention.** `rtl/attn_block.vhd` is not instantiated. The composition
  is `sim/tb_attn_kv_seam.vhd`'s question and it runs at HEAD_DIM 64 /
  MAXCTX 8 / K base 16.
* **Not the real HBM.** Fixed-latency in-order single-ID slaves. No
  reordering, no refresh, no bank conflicts, no hardware.
* **VIVADO WAS NOT RUN.** Whether the four pre-fix `to_integer` sites also
  mis-synthesise is **NOT DETERMINED**. The modulus is a power of two, so a
  synthesiser that constant-folds may well have produced correct logic by
  accident -- but "correct by accident in one tool" is not a property to rely
  on, the design was unsimulatable at its own map, and VHDL requires the
  argument of `to_integer` to be in `INTEGER` range. `resize` is a bit slice
  and is trivially synthesisable; that is an ESTIMATE, not a measurement.
* **The new `err` on an unaligned base has not been shown to be harmless in
  synthesis either**, for the same reason. It is four comparisons on the
  latched base.

---

## 9. Open, not yet answered

* **Nothing checks `attn_kv_axi`'s run-time position ceiling.** CGENERICS
  raised it and CKVMAP confirmed it: `rec_addr` computes `idx*REC_B` as a
  32-bit `integer` expression, so the ceiling is 246,723 positions. At
  `MAXCTX = 131072` the maximum is `(8*4*131072-1)*272 = 1,140,850,416`,
  **53 percent of `integer'high`**, so it does not bind -- but it is still a
  run-time expression inside a function and still unchecked. It would bind at
  `C_MAXPOS = 246,724`.
* **The two AXI widths are not covered by ONE gate row.** `control_dw128` in
  `sim/mutate_kv_map.sh` runs the 128 case and passes, but the auto-discovered
  `sim/regress.sh` row runs 256 only, so a regression that only shows at 128
  reaches the shared gate through nothing. `sim/tb_attn_kv_axi.vhd` solves
  this by instantiating a harness ENTITY twice; this bench is one
  architecture with one DUT and would have to be split the same way.
* **`sim/elab9b_run.sh` still fails 4 of 17 rows** and did so before CKVMAP;
  this track did not touch it and did not fix it either.
* **`sim/ooc_compose_bcd.tcl:104` still names generics that do not exist**
  (`C_K_BASE 16 / C_V_BASE 4064`) in a comment. Flagged by CKVMAP, still
  true, not owned here.
* **`rtl/attn_c_ports_skel.vhd`'s four stale widths are corrected here**
  (`cur_pos`/`ctx_len` 16 -> `POSW`, `k_base`/`v_base` 32 -> `ADDR_W` 33),
  after verifying by grep over every `*.vhd` that it is instantiated by
  nothing: it appears in its own entity and architecture headers and in one
  COMMENT in `rtl/attn_lane_skel.vhd`, with no component declaration and no
  instantiation. Its `MAXLAYERS` default is still 16 and its `N_HEAD`/`N_KVH`
  are still the `N = 2` tensor-parallel split; those are documentation of a
  different configuration and were left alone rather than half-retargeted.
