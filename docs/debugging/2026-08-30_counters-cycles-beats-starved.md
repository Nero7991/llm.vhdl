# What do the engine's CYCLES, BEATS and STARVED counters actually count?

**Date:** 2026-08-30. Branch `fpga`. **TRACK COUNTERS.**
**No hardware was touched.** The card is unconfigured and no new card data was
taken. Everything below is RTL reading, arithmetic on the four measurements
already published, a read of the packed model's own file headers, and GHDL
simulation of the shipping RTL.
**Tools named:** `ghdl-mcode 1.0.0`, `python3` over
`/mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json` and the `.mv4i`
headers, `git show`.
**Files read as the authority:** `rtl/matvec_int4_desc_axi.vhd`,
`rtl/matvec_int4.vhd`, `rtl/weight_streamer.vhd`, `rtl/matvec_core.vhd`,
`rtl/axi_rd_port.vhd`, `rtl/axi_rd_fsm.vhd`, `hw/fk33/rtl/fk33_engine.vhd`,
`hw/fk33/gen_pcieep.py`.

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement with its assumption stated).

---

## 1. The question, verbatim

> **What do the engine's `CYCLES`, `BEATS` and `STARVED` counters actually
> count?**
>
> Two readings fit the measured data and they call for opposite actions:
> **(i) The engine is starved.** 21.67 cycles per beat is 21.67x worse than
> one-beat-per-cycle, HBM latency is not being hidden, and the fix is more
> outstanding reads or better burst packing.
> **(ii) 21.67 cycles per beat is the design's INTENDED arithmetic rate**, a
> "beat" being a wide AXI word that the datapath legitimately chews for ~22
> cycles, and `STARVED` is counting backpressure from the compute side rather
> than absence of data. In which case there is nothing to fix and the name is
> a lie.

---

## 2. The answer, up front

**Reading (i) is right. The engine is genuinely starved, `STARVED` is honestly
named, and the intended rate is ONE weight word per core cycle -- so the card
is running at 4.5% of the datapath's design rate.**

**But the specific stall is neither of the two the question offered.** It is
not outstanding-read depth and it is not burst packing. It is the **HBM
address map**:

> **All 27 of a tensor's AXI read masters are reading out of ONE 256 MiB HBM
> segment, i.e. one pseudo-channel.** The packer lays a `.mv4i` file down
> contiguously, the 27 sub-regions are therefore adjacent, and every tensor in
> the model is far smaller than the 256 MiB granule at which
> `gen_pcieep.py`'s `assign_bd_address` cuts the HBM global address space. So
> 27 dedicated SAXI ports funnel into a single pseudo-channel that retires one
> 256-bit beat per 250 MHz AXI clock.

**DERIVED, and it is the whole number:**

```
one core weight word = ROWS_IF*BLK*4 = 48*32*4 = 6144 bits
                     = NPORTS_W = 24 AXI beats of 256 bits
plus its scale group = ROWS_IF*16  = 768 bits = NPORTS_S = 3 AXI beats
                                   ------------------------------------
                    27 AXI beats of 32 B = 864 B per core weight word

one 256-bit HBM slave port at ACLK = 250 MHz  ->  1 beat/cycle = 8.000 GB/s
27 beats at 250 MHz = 108.0 ns
108.0 ns at the 200 MHz core clock          ->  21.60 CORE CYCLES PER BEAT
```

**MEASURED least-squares slope over the four card jobs: 21.67 cycles/beat.
DERIVED single-pseudo-channel bound: 21.60. They agree to 0.32%.**

The engine is not running at 4.5% of its capability because it is badly
pipelined. It is running at **96 to 99 percent of the single resource the
address map has given it** (MEASURED aggregate 7.393 to 7.877 GB/s against the
8.000 GB/s one port can deliver), while 26 other pseudo-channels sit idle.

**Simulation of the shipping RTL confirms both halves** (section 5). With an
ideal memory the same RTL runs at **1.60 cycles/beat**; with a
one-beat-per-AXI-clock shared budget it runs at **21.74**, and reproduces all
four card measurements within 6%. Three other memory models miss by 21% to
93%, which is the attribution control.

**The correction to quote to Oren, in one sentence:**

> I told you the engine runs at about 1/22 speed "starved on HBM reads" -- the
> 1/22 is right and it is starvation, but I named the wrong cause: it is not
> read latency or burst size, it is that the packer puts all 27 of a tensor's
> sub-regions inside one 256 MiB HBM segment so all 27 masters queue for a
> single pseudo-channel, and the fix is in `tools/pack_model_fk33.py`, not in
> the RTL.

**No RTL change is needed to fix it.** The descriptor already carries 24
independent 64-bit `w_base[]` and 3 independent `s_base[]`. Placement is
entirely a packer and host concern.

---

## 3. Item 1 -- the definitive answer from the RTL

The engine on the card is `rtl/matvec_int4_desc_axi.vhd`, wrapped by
`hw/fk33/rtl/fk33_engine.vhd`. (`rtl/matvec_int4_axi.vhd` has the same three
counters at registers 22/23/24 and is the AXU3EG wrapper; it is NOT what the
FK33 runs. Both increment identically, so nothing below changes if you read
the wrong one, but the register offsets differ.)

### 3.1 Where they are incremented

`rtl/matvec_int4_desc_axi.vhd`, the **S_WAIT arm only**:

```vhdl
          when S_WAIT =>
            c_cycles <= c_cycles + 1;
            if dbg_wbeat   = '1' then c_beats  <= c_beats + 1;  end if;
            if dbg_wstarve = '1' then c_starve <= c_starve + 1; end if;
```

Cleared on entry to the job, in `S_IDLE` when `go_p` is taken:

```vhdl
              busy   <= '1';
              ...
              c_cycles <= (others => '0');
              c_beats  <= (others => '0');
              c_starve <= (others => '0');
```

Read back at registers 13, 14, 15 = `0x34`, `0x38`, `0x3C`:

```vhdl
            when 13 => rdata_r <= std_logic_vector(c_cycles);
            when 14 => rdata_r <= std_logic_vector(c_beats);
            when 15 => rdata_r <= std_logic_vector(c_starve);
```

### 3.2 What the two taps are

`rtl/matvec_int4.vhd`, two concurrent assignments, and that is the whole
definition:

```vhdl
  dbg_wbeat   <= wv and wr;
  dbg_wstarve <= not wv;
```

`wv` is `w_valid` out of `rtl/weight_streamer.vhd`; `wr` is `w_ready` back
from `rtl/matvec_core.vhd`. Chasing each one level further:

```vhdl
  -- weight_streamer: all_v is the AND of every weight port's FIFO non-empty
  pop_w   <= all_v and w_ready;
  w_valid <= all_v;
```

```vhdl
  -- matvec_core
  accept <= '1' when st = S_RUN and w_valid = '1' and s_valid = '1'
                     and xq_cnt > 0 else '0';
  w_ready  <= accept;
  s_ready  <= accept;
```

### 3.3 The answer, per counter

| register | counts | width | saturates? |
|---|---|---|---|
| `0x34 CYCLES` | every cycle the FSM spends in `S_WAIT`, i.e. from `core_start` to `core_done` | `unsigned(31 downto 0)` | **no, it WRAPS** (`c_cycles + 1`, no clamp) |
| `0x38 BEATS` | cycles where a weight WORD was handed to the array and taken (`w_valid and w_ready`) | `unsigned(31 downto 0)` | **no, it WRAPS** |
| `0x3C STARVED` | cycles where `w_valid` was LOW, i.e. **at least one of the 24 weight FIFOs was empty** | `unsigned(31 downto 0)` | **no, it WRAPS** |

Three things about those definitions that are not obvious and that the four
published numbers depend on:

1. **A "BEAT" IS NOT AN AXI BEAT.** It is one `ROWS_IF*BLK*4` = 6144-bit core
   weight word, which is 24 AXI beats of 256 bits, one from each weight port,
   plus 3 more beats on the scale ports. **864 bytes per BEATS increment.**
   Anyone reasoning about bandwidth from `BEATS` without that factor is out by
   27x. `BEATS` equals `tiles*nblk` exactly on a completed job, which is what
   `fk33_run_job.py` already cross-checks and which is now verified against the
   RTL rather than assumed.
2. **`STARVED` IS A LOWER BOUND ON READ-PATH STALL.** `dbg_wstarve` is `not
   w_valid` and `w_valid` is the weight side ONLY. A cycle in which all 24
   weight FIFOs are full but the 3-port SCALE superword has not assembled
   (`s_valid = '0'`) counts as neither `BEATS` nor `STARVED`. So does a cycle
   in which `xq_cnt = 0` (the activation prefetch queue ran dry) or the core is
   in `S_DRAIN`/`S_SCAN`/`S_EMIT`. On the card that residual is 10% to 47% of
   `CYCLES` (section 4.2).
3. **`CYCLES` IS NOT "GO TO DONE".** `busy` is raised in `S_IDLE` on GO, but
   the counters only run in `S_WAIT`. The descriptor fetch (`S_FETCH`, `S_R`),
   the four shape-check states and the up-to-17-cycle codebook load are
   OUTSIDE all three counters. The register-map comment in the RTL said
   "cycles busy, GO to done" and was wrong; it is corrected in this commit.

### 3.4 Item 2 -- saturation, checked, because it has bitten this project

The thermal guard's 8-bit trip counter saturated at 255 and cost an hour, so
this had to be established and not assumed.

**All three counters are `unsigned(31 downto 0)` and all three WRAP; none
saturates and none clamps.** The declaration is one line
(`signal c_cycles, c_beats, c_starve : unsigned(31 downto 0) := (others =>
'0')`) and the three increments quoted in 3.1 are the only writes apart from
the clear.

**Could any of the four published values be clipped? No.**

- `CYCLES` wraps at 2^32 = 4,294,967,296 core cycles = **21.5 s at 200 MHz**
  for a SINGLE matvec job. The largest measured job is 16,847 cycles, i.e.
  **0.00039%** of the range.
- `BEATS` wraps at 2^32 weight words = 3.7 TB of weights in one job. Measured
  maximum 768.
- `STARVED` is bounded by `CYCLES`, so the same argument.
- All three are **cleared per job** in `S_IDLE`, so they cannot accumulate
  across jobs into the range either.

**A wrap here would also not look like quiet**, which is the specific trap the
thermal counter set: a saturating counter reports a rate of zero once full and
zero reads as "nothing happening", whereas a wrapped 32-bit `CYCLES` would
report a small number for a huge job and the `CYCLES/BEATS` ratio would come
out absurdly LOW, not zero. Nothing in the four rows is low.

**Not checked and stated as such:** whether the AXI-Lite read of a 32-bit
counter is atomic with respect to the counter still running. It is not, but
every reading in the published table was taken after `done`, when all three
are frozen. A reading taken mid-job is a torn value and no tool in the tree
takes one.

---

## 4. Item 3 -- deciding between (i) and (ii)

### 4.1 The RTL states the intended rate in words, and it is 1 word per cycle

`rtl/matvec_core.vhd` header, verbatim:

> DATAFLOW. **One weight word per cycle** carries ROWS_IF rows' worth of one
> scale block, in the packer's tile-major order [...]
> The compute path is a **NON-STALLING pipeline**: it shifts every cycle
> carrying a valid bit, so bubbles cost nothing and there is no backpressure
> logic inside the datapath at all. Backpressure exists only at the accept
> point.

`docs/2026-08-28_can-27-read-masters-be-served.md` section 0 sizes the whole
design against that rate: "Subsystem A needs 27 of those 30 for a demand of
**204.0 GB/s** against a 259.2 GB/s supply, a 78.7% duty."

**Reading (ii) is therefore dead on the RTL alone.** There is no 22-cycle
structure anywhere in the datapath: no `BLK`-serialisation, no per-lane
sequencing, nothing that would make 22 a designed number. The array consumes
`ROWS_IF*BLK` = 1536 nibbles in one cycle and the adder tree is pipelined, not
iterative.

### 4.2 What the four card rows actually decompose into

**DERIVED** from the published table, adding the residual
`CYCLES - BEATS - STARVED` (cycles where a weight word WAS available and was
not taken) and the aggregate bandwidth
`BEATS * 27 * 32 B / (CYCLES / 200 MHz)`:

```
job                          CYCLES  BEATS  STARVED   RESID   c/beat     bytes      GB/s
32 rows K=4096 1 tile          2992    128     2567     297    23.38    110592     7.393
100 rows K=4096 3 tiles        8582    384     7530     668    22.35    331776     7.732
64 rows K=4096 2 tiles         5724    256     3872    1596    22.36    221184     7.728
64 rows K=12288 2 tiles       16847    768     8132    7947    21.94    663552     7.877
```

**The aggregate byte rate is FLAT at 7.4 to 7.9 GB/s across a 6x range of job
size.** That is the signature of a single shared resource at its ceiling. It
is NOT the signature of fixed per-job overhead being amortised -- and it
cannot be, because section 3.3 point 3 established that the fixed control-plane
overhead is not inside `CYCLES` at all.

**One 256-bit AXI slave port at ACLK = 250 MHz delivers 8.000 GB/s.** The
engine is at **92.4% to 98.5%** of exactly one port.

### 4.3 The address map, MEASURED from the model's own file headers

`hw/fk33/gen_pcieep.py` cuts the HBM global address space into 32 segments of
256 MiB, one per pseudo-channel, and gives every engine master a window onto
all 32:

```tcl
        assign_bd_address \
            -target_address_space [get_bd_addr_spaces ENGCELL/${m}_axi] \
            -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \
            [get_bd_addr_segs [format "hbm/SAXI_%02d/HBM_MEM%02d" $sx $s]]
```

So **the 256 MiB granule is the pseudo-channel granule**: address bits [32:28]
select which of the 32 physical pseudo-channels a read lands in.

MEASURED, walking every `.mv4i` header in the packed 9B model
(`hbm_offset` from `manifest.json` plus `w_sub_offset[]`/`s_sub_offset[]` from
each file's own header, exactly as `tools/pack_int4.py` writes them):

```
mv4i files: 250
distinct 256 MiB HBM segments the 27 sub-region BASES land in:
   1 segment(s): 235 files
   2 segment(s): 13 files
   3 segment(s): 2 files
```

**235 of 250 tensors have all 27 masters reading from ONE pseudo-channel.**
The two 3-segment files are `output.weight` and `token_embd.weight`, the only
objects large enough to straddle.

The four jobs in the published table specifically:

```
blk.0.ssm_alpha.weight  hbm_offset=4380508160  w bases seg {16}   s bases seg {16}
blk.11.attn_k.weight    hbm_offset=4438286336  w bases seg {16}   s bases seg {16}
blk.0.ffn_gate.weight   hbm_offset=1513844736  w bases seg { 5}   s bases seg { 5}
blk.20.ffn_down.weight  hbm_offset=3443970048  w bases seg {12}   s bases seg {12}
```

Note the extra sting on the first two: segment 16 is `HBM_MEM16`, physically
attached to **`SAXI_16`, which belongs to the HOST**
(`hw/fk33/gen_pcieep.py:272`). `ENG_PORT_MAP` puts the engine's 28 masters on
`SAXI_01..15` and `SAXI_17..29`, so for those jobs **not one of the 27 masters
had the direct path to the pseudo-channel it was reading**; every access
crossed the HBM global switch laterally.

### 4.4 Why this is starvation and not backpressure, restated plainly

`STARVED` is `not w_valid`, and `w_valid` is "every one of the 24 weight FIFOs
has a word". It cannot be raised by anything downstream of the FIFOs. A cycle
counted in `STARVED` is a cycle in which the memory system had not delivered.
That is starvation by any definition, so **the name is correct and should not
be changed.** What was wrong was the diagnosis of the cause, and one line of
the register-map comment.

---

## 5. Item 3, the discriminating measurement -- simulation of the shipping RTL

**Bench:** `docs/debugging/2026-08-30_counters-tb_ctr_rate.vhd`, committed
alongside this document. It is **deliberately NOT in `sim/`**: a new
`sim/tb_*.vhd` becomes a gate row and moves `BASELINE_PASS` for every track on
the box, and `sim/regress.sh` is not this track's to edit. It globs only
`sim/tb_*.vhd` and `tb/tb_*.vhd`, so a file under `docs/` is invisible to it.
Moving it into `sim/` with its own regress row is a one-line job for whoever
next owns `regress.sh`.

It instantiates the **real** `rtl/matvec_int4.vhd` at the exact FK33 geometry
(`ROWS_IF=48 NPORTS_W=24 NPORTS_S=3 AXI_DW=256 BLK=32 FIFO_DEPTH=512 MAXB=16
MAXOUT=16`), reimplements the counter logic exactly as `S_WAIT` does, and
replaces only the memory. The memory model is one process over all 27 ports
with a **shared beat budget**: `GNUM` credits accrue per core cycle, a beat
costs `GDEN`.

### 5.1 How to reproduce

```
mkdir -p /mnt/storage/track-counters/work && cd /mnt/storage/track-counters/work
ghdl -a --std=08 --work=work \
  <repo>/rtl/util_pkg.vhd <repo>/rtl/mv4i_arith_pkg.vhd \
  <repo>/rtl/stream_fifo.vhd <repo>/rtl/async_fifo.vhd \
  <repo>/rtl/axi_rd_fsm.vhd <repo>/rtl/axi_rd_port.vhd \
  <repo>/rtl/weight_streamer.vhd <repo>/rtl/act_mem_striped.vhd \
  <repo>/rtl/matvec_core.vhd <repo>/rtl/matvec_int4.vhd \
  <repo>/docs/debugging/2026-08-30_counters-tb_ctr_rate.vhd
ghdl -r --std=08 --work=work tb_ctr_rate \
  -gUNLIM=false -gGNUM=5 -gGDEN=4 -gLAT=0 -gTAG=D --stop-time=50ms --stop-delta=1000000
```

MEASURED peak RSS 1.6 GiB, wall 9 to 19 s per run. One run at a time.

### 5.2 The memory models and what each one isolates

| run | memory model | isolates |
|---|---|---|
| A | `UNLIM`, `LAT=0` -- every port may take a beat every cycle | the DATAPATH's own ceiling with the shipping FIFO/AR/throttle settings |
| B | `UNLIM`, `LAT=100` -- 100 cycles per burst, **serialised** | see the trap in section 7; do not read this as a MAXOUT result |
| C | shared, `GNUM=1 GDEN=1` -- one beat per CORE cycle across all 27 ports | one pseudo-channel if ACLK were the core clock |
| D | shared, `GNUM=5 GDEN=4` -- one beat per AXI cycle, ACLK/CLK = 250/200 | **the card's actual configuration** |

### 5.3 Raw output

```
CTRRATE tag=A_ideal_lat0                        rows=100 cols=4096 expect_beats=384 CYCLES=613   BEATS=384 STARVED=202   RESID=27 err='0'
CTRRATE tag=B_ideal_lat100                      rows=100 cols=4096 expect_beats=384 CYCLES=2829  BEATS=384 STARVED=2421  RESID=24 err='0'
CTRRATE tag=C_shared_1beat_per_core_cycle       rows=100 cols=4096 expect_beats=384 CYCLES=10405 BEATS=384 STARVED=10020 RESID=1  err='0'
CTRRATE tag=D_shared_1beat_per_axi_cycle_250over200 rows=100 cols=4096 expect_beats=384 CYCLES=8349 BEATS=384 STARVED=7941 RESID=24 err='0'

CTRRATE tag=D_32r_K4096       rows=32  cols=4096  expect_beats=128 CYCLES=2815  BEATS=128 STARVED=2685  RESID=2  err='0'
CTRRATE tag=D_64r_K4096       rows=64  cols=4096  expect_beats=256 CYCLES=5571  BEATS=256 STARVED=5315  RESID=0  err='0'
CTRRATE tag=D_64r_K12288      rows=64  cols=12288 expect_beats=768 CYCLES=16640 BEATS=768 STARVED=15869 RESID=3  err='0'
CTRRATE tag=A_ideal_64r_K12288 rows=64 cols=12288 expect_beats=768 CYCLES=1188  BEATS=768 STARVED=394   RESID=26 err='0'
```

### 5.4 Model D against the card, all four geometries

| job | card CYCLES | model D CYCLES | delta |
|---|---|---|---|
| 32 rows, K=4096 | 2,992 | 2,815 | **-5.9%** |
| 64 rows, K=4096 | 5,724 | 5,571 | **-2.7%** |
| 100 rows, K=4096 | 8,582 | 8,349 | **-2.7%** |
| 64 rows, K=12288 | 16,847 | 16,640 | **-1.2%** |

### 5.5 The attribution control

A model that lands on the data is worth nothing if every model does. It does
not, on the 100-row job (card = 8,582):

| model | CYCLES | error vs card |
|---|---|---|
| A ideal memory | 613 | **-92.9%** |
| B serialised 100-cycle latency | 2,829 | **-67.0%** |
| C one beat per core cycle | 10,405 | **+21.2%** |
| **D one beat per AXI cycle at 250/200** | **8,349** | **-2.7%** |

Only D is close, and D is the only one of the four whose bound was DERIVED
in advance (21.60 cycles/beat) rather than fitted.

**This also settles the outstanding-read hypothesis, which was the obvious
suspect and is wrong.** Runs A and D use the **identical** `MAXOUT=16`,
`MAXB=16`, `FIFO_DEPTH=512` and the identical `axi_rd_fsm` throttle. The only
thing that changes between 1.60 and 21.74 cycles/beat is the memory model. A
port never has more than about one burst of unmet demand in run D, so neither
`MAXOUT` nor the `f_level + pr + want <= DEPTH` throttle is ever the binding
term. **TRACK A7's `outst` counter is not the bound that matters here.**

### 5.6 Confidence

**High that reading (ii) is dead** -- the RTL says one word per cycle in its
header, there is no 22-cycle structure in the datapath, and the same RTL
achieves 1.60 cycles/beat in simulation.

**High that the stall is a single-pseudo-channel bound** -- an independently
DERIVED number (21.60) matches the measured slope (21.67) to 0.32%, the
achieved bandwidth is 92-99% of exactly one AXI port, the aggregate is flat
across a 6x size range, and the placement that would cause it is MEASURED
present in 235 of 250 tensors.

**Circumstantial, not proven, that it is the pseudo-channel and not some other
27-way serialisation** -- the simulation reproduces the numbers with a model
that has that bound, but a simulation cannot prove what the silicon's
bottleneck is. **The decisive on-card test is in section 9 and needs
hardware.**

---

## 6. Items 4, 5 and 6 -- the verdicts

**Item 4 (if (ii)): does not apply.** ~22 cycles/beat is not the intended
rate. The intended rate is 1 word/cycle = 153.6 GB/s of weights and scales at
the 200 MHz core clock, against the 204.0 GB/s figure in
`docs/2026-08-28_can-27-read-masters-be-served.md` (that document counts the
demand at a higher assumed core clock; the ratio is what matters and it is the
same).

**Item 5 (if (i)): the specific stall, and what bounds it.**

| candidate | verdict |
|---|---|
| outstanding-read depth (`MAXOUT`, `rtl/axi_rd_fsm.vhd`) | **NOT the bound.** Section 5.5: same `MAXOUT`, 13.6x rate difference. |
| burst length (`MAXB=16`, the AXI3 4-bit `ARLEN` cap) | **NOT the bound.** 16 beats per burst per port is 16x more than the ~1 beat per 27 cycles the port is actually getting. |
| FIFO depth / AR throttle (`DEPTH=512`) | **NOT the bound.** Never reaches the guard in model D. |
| the scale path (3 ports) | **A SECOND, SMALLER STALL, invisible to `STARVED`.** See section 8, open. |
| **HBM pseudo-channel contention from the address map** | **THE BOUND.** 27 masters, 1 pseudo-channel, 8.000 GB/s. |

**The fix, and it is not in the RTL.** `w_base[0..23]` and `s_base[0..2]` are
already 27 independent 64-bit fields in the descriptor
(`docs/2026-08-28_matvec-descriptor-format.md`), and
`rtl/weight_streamer.vhd` gives each port its own base with no assumption that
they are adjacent. So a placement change alone is enough:

> Place weight sub-region `p` of every tensor in the 256 MiB segment that
> master `p`'s own SAXI port owns, i.e. segment `ENG_PORT_MAP[p]`
> (`hw/fk33/gen_pcieep.py:313`: masters 0..14 -> `SAXI_01..15`, masters 15..27
> -> `SAXI_17..29`). Weight port `p` then reads only from its directly
> attached pseudo-channel and never crosses the global switch at all.

**Capacity, DERIVED, as an ESTIMATE for the packer's owner rather than a
design:** weights are 5,056,995,328 B (`manifest.json:hbm.weights_bytes`)
striped 27 ways = **187.3 MB per segment**, against a 268.4 MB segment. It
fits, with 81 MB spare per segment, but it leaves the GDN state (75.5 MB) and
the KV arena (currently 3.19 GiB) to be fitted into segment tails plus the
four segments no engine master owns (`00`, `16`, `30`, `31` = 1.07 GB). That
arithmetic is close and has not been closed here. **Open, see section 9.**

**Projected gain, ESTIMATE:** model A (ideal memory, same RTL) runs the
K=12288 job in 1,188 cycles against model D's 16,640, i.e. **14.0x**. The card
would not reach that -- model A still shows 394 starved cycles of AR and
fill-up overhead, and 27 real pseudo-channels are not an ideal memory -- but
the direction and the order of magnitude are not in doubt, and even a 10x
would take the 0.56 s of card compute per token to under 60 ms.

**Item 6 (rename or re-document).**

- **`STARVED` is NOT misnamed. Do not rename it.** It counts `not w_valid`,
  which is genuinely the absence of data. Renaming it `BACKPRESSURED` would be
  the wrong-noun error, not the fix for one.
- **`BEATS` is misleading and I am NOT renaming it either**, because
  `hw/fk33/host/fk33_run_job.py` prints it and `hw/fk33/host/**` is not this
  track's, and because its RTL contract "weight words the array consumed" is
  already correct where it is stated. What was missing is the conversion
  factor, now written into the register map: **one BEATS = 24 weight AXI beats
  + 3 scale AXI beats = 864 B.**
- **`CYCLES` WAS mis-documented and that IS fixed in this commit**, as a pure
  comment change to `rtl/matvec_int4_desc_axi.vhd`'s register map. Old text:
  `0x34 CYCLES R cycles busy, GO to done`. It is not GO to done; it is `S_WAIT`
  only. This matters beyond pedantry: the "GO to done" reading is exactly what
  licensed the claim that the falling `STARVED` fraction was fixed per-job
  overhead being amortised, and the fixed overhead is not in the counter.

---

## 7. Measurement traps hit, including my own

1. **`ghdl-mcode` says "overflow detected" and nothing else.** My first bench
   revision multiplied a beat counter by `2654435761` to make a data pattern.
   VHDL `integer` is 32-bit signed; that is an elaboration-time-legal,
   runtime-fatal overflow, and the entire diagnostic is
   `ghdl-mcode:error: overflow detected` with no line number. Keep every
   integer expression in a bench inside 2^31.
2. **Run B is a model artefact and must not be quoted about `MAXOUT`.** My
   slave applies `LAT` to the HEAD of each port's burst queue, so burst `k`'s
   latency starts only after burst `k-1` has fully delivered. That is
   SERIALISED latency, not outstanding-request pipelining. It gives
   `(100+16)/16 = 7.25` cycles/beat and MEASURED 7.37, which looks like "MAXOUT
   is not hiding latency" and is not. It is my model failing to model MAXOUT at
   all. Run A is the control that shows the throttle settings are fine.
3. **The four-row table's `BEATS/CYCLES` percentage is a trap in the original
   write-up.** 4.3-4.6% invites "the engine is 4.5% efficient". It is 4.5% of
   ONE WORD PER CYCLE, which is right, but the same number also reads as a
   bandwidth efficiency and as a bandwidth efficiency it is **wrong by 27x** in
   the optimistic direction, because a word is 27 AXI beats. Always state the
   864 B.
4. **`STARVED` percentage is not a stall percentage.** It misses the scale
   path, the activation queue and the non-`S_RUN` states. On the K=12288 job
   `STARVED` is 48.3% and the true not-consuming fraction is 95.4%.
5. **The bench is SINGLE clock and the card is DUAL.** I modelled the 250/200
   ratio in the memory's credit rate instead of instantiating a second clock.
   That is honest for the throughput question and it is why section 8's
   residual mismatch is open rather than explained.
6. **`sim/regress.sh` globs `sim/tb_*.vhd` off the FILESYSTEM.** Dropping a
   new bench there while three tracks are running turns the shared gate red
   until `BASELINE_PASS` moves. The bench is under `docs/debugging/` for that
   reason and for no other.

---

## 8. Measured and REJECTED -- do not retry

| hypothesis | how it died | do not retry |
|---|---|---|
| **(ii) ~22 cycles/beat is the datapath's intended rate** | `rtl/matvec_core.vhd`'s header specifies one weight word per cycle and a non-stalling pipeline; the same RTL runs at 1.60 cycles/beat in run A | Settled. The datapath is not the problem and must not be touched. |
| **`MAXOUT` / outstanding-read depth is the bound** | runs A and D share `MAXOUT=16`, `MAXB=16`, `DEPTH=512` and differ 13.6x | Raising `MAXOUT` above 16 buys nothing while the address map is unfixed. Note `rtl/axi_rd_port.vhd` already records that `MAXOUT` goes inert above 32 at `DEPTH=512`/`MAXB=16`. |
| **`MAXB` / burst packing is the bound** | a port receives about one beat per 27 AXI cycles; a 16-beat burst is already 16x more than it can use | Do not chase the AXI3 `ARLEN` cap here. It is a real constraint and it is not this constraint. |
| **The falling `STARVED` fraction (85.8% to 48.3%) is fixed per-job overhead being amortised** | the fixed control-plane overhead is not inside `CYCLES` at all (section 3.3 point 3), and the aggregate byte rate is FLAT rather than rising | The falling fraction is the RESIDUAL rising, not overhead amortising. It is a real and separate effect (section 9). |
| **Reading the AXU3EG wrapper `rtl/matvec_int4_axi.vhd` answers the question** | it is not what the FK33 runs; its counters are at registers 22/23/24, not `0x34/0x38/0x3C` | The FK33 engine is `rtl/matvec_int4_desc_axi.vhd`. The increment logic happens to be identical, so this cost nothing, but the register offsets would have. |
| **`STARVED` should be renamed `BACKPRESSURED`** | `dbg_wstarve <= not wv` and `wv` is the AND of the weight FIFOs' non-empty; nothing downstream can raise it | Do not rename it. |

---

## 9. Open, not yet answered

1. **THE DECISIVE ON-CARD TEST HAS NOT BEEN RUN AND NEEDS HARDWARE.** Relocate
   ONE tensor's 27 sub-regions into 27 distinct 256 MiB segments (they need not
   be the "right" segments to prove the point -- any 27 distinct ones will do)
   and re-run the identical job. Prediction, stated in advance so it can be
   wrong: `CYCLES` for the 100-row K=4096 job falls from 8,582 to under 1,500.
   If it does not, this whole analysis is wrong and the next suspect is the HBM
   global switch's lateral bandwidth rather than the destination
   pseudo-channel. **Oren's call; no agent runs it.**
2. **The card's residual does not match the model's, even though the totals
   do.** On the 64-row K=4096 job the card splits 5,724 cycles as
   3,872 starved + 1,596 residual; model D splits 5,571 as 5,315 + 0. Totals
   agree to 2.7%, the split does not. Something on the card holds `w_valid`
   high while the core refuses the word, for 10% to 47% of the job, and my
   single-clock model does not reproduce it. The two candidates are the DUAL
   clock domain crossing (`rtl/axi_rd_port.vhd`'s `async_fifo`, with the AXI
   side filling in bursts of 5 beats per 4 core cycles) and the scale path
   (`s_valid` low while all 24 weight FIFOs are full). **Not determined.** It
   does not change the headline -- the total is what sets throughput -- but it
   is the reason `STARVED` alone cannot be trusted as a stall metric.
3. **A scale-side starve counter does not exist and should.** Recommended RTL
   change, REPORTED AND NOT APPLIED: tap `s_valid` out of `matvec_int4`
   alongside `dbg_wbeat`/`dbg_wstarve` and add a fourth 32-bit counter at
   `0x40` in `rtl/matvec_int4_desc_axi.vhd`. That register offset is free and
   the map has room. It would close item 2 above from the card in one job.
   This touches the generated register header and `hw/fk33/host/**`, so it is
   for whoever owns those.
4. **The striped-placement capacity arithmetic is not closed.** 187.3 MB of
   weights per segment fits a 268.4 MB segment, but the KV arena (3.19 GiB) and
   GDN state (75.5 MB) then have to live in the 81 MB tails plus the four
   host/disabled segments, and that is about 3.26 GB against a 3.27 GB need.
   It is too close to call from here and it interacts with
   `docs/debugging/2026-08-28_hbm-stack-boundary-straddle.md`'s allocator. **A
   packer track should own it.** A cheaper partial fix exists and has not been
   costed: stripe across only 8 or 12 segments instead of 27, which gives 8 to
   12x instead of 27x and leaves far more contiguous space.
5. **Whether subsystems B, C and D have the same pathology has not been
   checked.** They read the KV and GDN arenas, which are single large regions,
   so any multi-master read of them will hit the same 256 MiB granularity.
   `rtl/attn_kv_axi.vhd` has its own `starv` counter and was not examined.
6. **The 204.0 GB/s demand figure in
   `docs/2026-08-28_can-27-read-masters-be-served.md` does not match the
   153.6 GB/s that 200 MHz gives.** That document assumed a higher core clock
   than the 200 MHz `ENG_CORE_MHZ` the shipping build sets. Both are above what
   one pseudo-channel can serve by more than an order of magnitude, so nothing
   here turns on it, but the two documents should be reconciled.

---

## 10. Corrections to the brief and to prior documents

**To `docs/debugging/2026-08-29_first-arithmetic-on-the-silicon.md` section 5.**
That section was right to refuse to let anyone build on it, and its refusal is
now discharged: the counters' semantics ARE verified against the RTL. Two of
its statements are withdrawn:

- *"The starved fraction FALLS as the job grows [...] which is the signature of
  fixed per-job overhead being amortised rather than of a starved data path."*
  **WITHDRAWN.** The fixed per-job overhead is not inside `CYCLES` (section
  3.3). The data path IS starved. The falling fraction is the residual rising,
  which is a different and still-open effect (section 9 item 2).
- *"Note `BEATS/CYCLES` is nearly constant at 4.3-4.6% [...] and that is the
  number to reason about."* **The number is right and the units were never
  stated.** 4.5% is 4.5% of one 864-byte word per cycle. Read as a bandwidth
  efficiency it is out by 27x.

**To `hw/fk33/host/fk33_run_job.py`'s standing note** that it "has not verified
those counters' semantics against the RTL": that is now done, and its
`expected BEATS = tiles*nblk` cross-check is CORRECT -- `matvec_core` consumes
exactly one weight word per (tile, block). Whoever owns `hw/fk33/host/**` may
promote that warn to a check. This track did not touch it.

**To this track's own brief:** the brief offered "outstanding-read depth, burst
length, arbitration" as the candidates for the stall under reading (i), and
flagged `rtl/axi_rd_fsm.vhd`'s `outst` depth as "possibly exactly the bound
that matters". It is not, and section 5.5 is the control that says so.

---

## 11. What changed in the tree

| path | change |
|---|---|
| `docs/debugging/2026-08-30_counters-cycles-beats-starved.md` | this document |
| `docs/debugging/2026-08-30_counters-tb_ctr_rate.vhd` | the rate bench; NOT in `sim/`, so it is not a gate row |
| `rtl/matvec_int4_desc_axi.vhd` | **comment only.** The `0x34/0x38/0x3C` register-map lines, corrected per section 6. No logic, no port, no signal. |

Nothing else. No `sim/` file, no host file, no generated file, no RTL logic.
