# TRACK READCONV -- subsystem B's read side, 2026-08-29

## The question, verbatim

> Take B's read side: convert the flat whole-vector READ ports to a streaming
> interface, which requires `rtl/l2norm_rs.vhd` to accept one. LUTDIET measured
> B's read share at **8.9% of 585,430 primitives** and C's at 3.5%, so **know
> going in that this is the smaller half and may not close the gap on its own.**
> Measure what it actually buys and say so plainly, including if the answer is
> "not enough".

Hardware: none. Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, 5.0 ns,
`synth_design -mode out_of_context -flatten_hierarchy none`, `LUTDIET_NOOPT=1`,
on a `git archive` of `4d40fe2019ab51f0fd91acd9c580790e5e324c2f` (HEAD at
dispatch, three commits after TRACK WRITEDEC released the RTL at `971524c`).
Simulation: GHDL mcode.

## The answer, up front

**The streaming conversion the brief asks for does not exist as a saving. It
was measured directly and it buys nothing.** A variable-index read out of a flat
register costs `stored_bits / 4` LUT and **the read port's width does not appear
in that expression**: selecting 128 words, 4 words or 1 word out of the same
2,048-word store all cost the same, because the cost is the multiplexer's
*source* size and not its output size. Narrowing `l2norm_rs`'s `x_mant` port
therefore moves the identical mux from one side of the port to the other.

**One real saving was found on the way and it is not a read at all.** TRACK
WRITEDEC did not own `rtl/l2norm_rs.vhd`, so the *write* decode into that unit's
own `k_reg`/`q_reg` was still the pre-WRITEDEC idiom. Applying WRITEDEC's fix to
it takes `l2norm_rs` from **14,931 to 4,693 LUT, -68.6%**, at identical ports,
identical DSP, zero BRAM and identical WNS, and it is bit-exact and cycle-exact.

**It does not close the fit, and neither would a perfect read conversion.** The
arithmetic is in section 6 and the margin is not close.

**What a streaming port IS good for, and this is the finding worth carrying
forward:** it is the *enabler* for putting the store in memory, because a memory
can only present one word per cycle. The saving belongs to the memory, not to the
streaming. See section 5 for the measured distributed-RAM numbers, which are a
LUT-only fallback and are **not** the BRAM trade this track was told to leave
alone.

## 1. What was reproduced before anything was changed

Two before-numbers were reproduced to the digit on this tree, so any delta is
the change and nothing else.

    tag           top          generics          LUT      FF    DSP  BRAM   F7      F8      WNS
    rc_l2_base    l2norm_rs    N=128 LANES=4   14,931   4,833    36     0     256      0   +1.663
    rc_gdn_base   gdn_block    (defaults)     131,760 248,873   253    43  29,025 13,327   +0.483

`rc_l2_base` is TRACK LUTDIET's `l2_ctrl` row, digit for digit.
`rc_gdn_base` is TRACK WRITEDEC's `wd_gdn_after` row, digit for digit.

## 2. Where B's read cost actually sits, after the write decode

TRACK LUTDIET's census was taken BEFORE the write decode, so its percentages are
against a denominator that has since fallen 3.3x. The table below is
`census_rc_gdn_base.txt`, taken by this track on `gdn_block` = 131,760 LUT, and
it reproduces WRITEDEC's `census_wd_gdn_after.txt` row for row:

    root        LUT     MUXF7  MUXF8       what it is
    l2_x     18,433     8,192  4,096   gdn_block:958/960, a 2,048-bit slice of
                                       qbuf/kbuf, 16 heads x 2 buffers = 32:1
    rp_cvj   17,473     8,736  4,368   gdn_block:1122, ONE 16-bit element out of
                                       vbuf, 4,096:1
    q         8,354         0      0   u_l2/q_reg -- NOT a read.  l2norm_rs's own
                                       WRITE demux, which WRITEDEC did not own
    rp_qs     8,192     4,096  2,048   gdn_block:1055, 2,048-bit slice of qsb, 16:1
    rp_kn     8,192     4,096  2,048   gdn_block:1054, 2,048-bit slice of knb, 16:1
    k         6,710         0      0   u_l2/k_reg -- the other half of the same
                                       write demux
    o         4,426         0      0   u_emit/u_head/o_reg, gdn_head_emit's own
                                       flat output register (a different file)

    read muxes            52,290  = 39.7% of gdn_block
    l2norm_rs write demux 15,064  = 11.4% of gdn_block

**Two things follow immediately and both matter.**

* The read share is not 8.9%. That figure was a fraction of a pre-write-decode
  denominator. Against the shipping module it is **39.7%**, and 8.9% would have
  made this track look not worth running.
* `q` and `k` are in the read column of nobody's table and are not reads. They
  are the write idiom WRITEDEC fixed everywhere it owned, in the one unit on B's
  norm path it did not own. That is the whole of this track's landed saving.

The four read muxes have an exact and very regular signature: per output bit,
`l2_x` is 9 LUT + 4 F7 + 2 F8 (`2048 x 9 + 1 = 18,433`), `rp_kn` and `rp_qs` are
4 LUT + 2 F7 + 1 F8 (`2048 x 4 = 8,192`). That is a 16:1 mux built as
4 x LUT6-as-4:1 -> 2 x MUXF7 -> 1 x MUXF8, plus one more LUT for `l2_x`'s q/k
select. It is the textbook structure, which is why section 3's prediction is
worth testing rather than assuming.

## 3. THE EXPERIMENT THAT KILLED THE PREMISE

`hw/fk33/results/readconv_2026-08-29/rtl/readconv_probe.vhd`. One 2,048 x 16b
store -- `gdn_block`'s `qbuf` exactly, at `KEY_HEADS = 16`, `DIM = 128`. The
write decode is WRITEDEC's per-word constant-index generate in **every** variant,
so the write cost is identical and cannot confound. The read output is a
registered PORT, so the mux cannot be optimised into a consumer that is not
there. Only the read port width moves.

    variant                      store          read     1-of-N   read-mux   total    CLB FF   LUT as
                                                width                 LUT      LUT             memory
    readconv_flat SELW=128    2,048 x 16b     2,048 b     16:1      8,192    8,761   34,816       0
    readconv_flat SELW=4      2,048 x 16b        64 b    512:1      8,768    9,311   32,832       0
    readconv_flat SELW=1      2,048 x 16b        16 b   2048:1      8,736    9,281   32,784       0
    readconv_dram WLANES=4    2,048 x 16b        64 b    512:1        128      728       64     592

    readconv_flat SELW=1      4,096 x 16b        16 b   4096:1     17,472   18,543   65,552       0
    readconv_dram WLANES=4    4,096 x 16b        64 b   1024:1        256    1,456       64   1,184

**The read port width is 128x apart across the first three rows and the read
mux moves by 6.6%, in the WRONG DIRECTION.** `stored_bits / 4` predicts
`32,768 / 4 = 8,192`; the measured 8,192 / 8,768 / 8,736 straddle it. The
narrow ports are marginally *worse*, because a deeper 1-of-N tree wastes a
little more of each LUT6.

Two cross-checks that this probe is modelling the real thing and not a toy:

* `readconv_flat` SELW=128 over a 2,048-word store is exactly `gdn_block`'s
  `rp_kn` / `rp_qs` shape, and its read mux is **8,192 LUT / 4,096 F7 /
  2,048 F8** against `rp_kn`'s measured **8,192 / 4,096 / 2,048**. Digit for
  digit.
* `readconv_flat` SELW=1 over a 4,096-word store is `rp_cvj`'s shape, and its
  read mux is **17,472 LUT / 8,736 F7 / 4,368 F8** against `rp_cvj`'s measured
  **17,472 / 8,736 / 4,368**. Digit for digit.

The write decode is 550-580 LUT in every flat variant, confirming it is not
moving and cannot be what the comparison is seeing.

### The same result was already sitting in WRITEDEC's artefacts, unread

This did not need a new probe to be *suspected*; the probe exists because a
suspicion measured on a purpose-built harness is worth more than one inferred
from two rows of somebody else's census. But the corroboration is exact and it
is worth stating, because it is the cheapest way for the next person to check
this claim without running anything.

From `census_wd_rmsflat_after.txt` (`lutdiet_rms_flat`, N=4096 LANES=4) and
`census_wd_gdn_after.txt` (`gdn_block`), two variable-index reads with the SAME
65,536-bit source and read widths **32x apart**:

    read              source bits   read width   1-of-N     LUT primitives
    u/sq   (S_ACC)        65,536      64 bits     1024:1        17,475
    u/ARG  (emit)         65,536      64 bits     1024:1        17,916
    l2_x   (gdn_block)    65,536    2,048 bits      32:1        18,433

`source_bits / 4` predicts 16,384 for all three. The measured spread is 6% and
does not correlate with the read width at all. **`rmsnorm_rs` already reads its
flat port four words at a time -- it is already "streaming" in the only sense
that matters to the port -- and it still pays the full mux.**



## 4. Bit-exactness of the change that DID land

`rtl/l2norm_rs.vhd`'s `k_reg`/`q_reg` write decode, converted to WRITEDEC's
combinational-datum plus per-word constant-index generate. `sat16` is hoisted
from the FSM process to the architecture so the generate can call it; the body is
byte for byte the one the process declared.

**The oracle is the pre-change file, not the unit itself.** A round trip is not
an oracle. `rtl/l2norm_rs_ref.vhd` is `l2norm_rs.vhd` at the pinned SHA, byte for
byte, with only the entity and architecture names changed -- verified by
un-renaming it and `diff`ing against the archive. `rtl/tb_readconv_l2.vhd` runs
both off identical stimulus and compares **every element of both output paths and
the start-to-done cycle count**.

**Non-triviality is asserted on every trial, and that is not decoration.**
`l2norm_rs` has a silent all-zeros rail: `ssq = 0` takes `S_ZERO` and emits zeros
on both paths by design (B 2.1.3's deliberate divergence from `ggml_l2_norm`), and
a badly chosen magnitude rounds every element to zero as well. LUTDIET's probe was
fooled by exactly this shape on `rmsnorm_rs`: three of six trials proved nothing
and the run still reported six of six passed. Every trial here declares whether it
expects zeros, and the bench fails **hard** if a live trial produces none, or if
the `S_ZERO` trial produces any.

16 classes, 8 shapes:

    N=8   LANES=1     trials=16 live=15 fails=0    OVERALL PASS
    N=8   LANES=8     trials=16 live=15 fails=0    OVERALL PASS
    N=32  LANES=4     trials=16 live=15 fails=0    OVERALL PASS
    N=64  LANES=8     trials=16 live=15 fails=0    OVERALL PASS
    N=128 LANES=1     trials=16 live=15 fails=0    OVERALL PASS
    N=128 LANES=4     trials=16 live=15 fails=0    OVERALL PASS
    N=256 LANES=2     trials=16 live=15 fails=0    OVERALL PASS
    N=512 LANES=4     trials=16 live=15 fails=0    OVERALL PASS

128 trials, 120 of them asserted non-degenerate, 0 failures, and `done` on the
identical cycle in all 128. The classes include index 0 alone, index N-1 alone,
the most negative int16 flat, mixed per-element magnitude (the class that caught
this unit's original `idx1`-vs-`idx2` gating bug -- a uniform vector cannot see a
block written with the wrong index), `NB = 1` (N=8 LANES=8), and a reset taken
mid-emit followed by a clean run.

### The saving passes straight through into `gdn_block`

    tag             top          LUT       FF      DSP  BRAM  URAM   F7      F8     WNS
    rc_l2_base      l2norm_rs    14,931    4,833    36     0     0     256      0  +1.663
    rc_l2_after     l2norm_rs     4,693    4,784    36     0     0      64      0  +1.663
    rc_gdn_base     gdn_block   131,760  248,873   253    43     0  29,025 13,327  +0.483
    rc_gdn_after    gdn_block   121,475  248,799   253    43     0  28,946 13,327  +0.483

`l2norm_rs` standalone falls **10,238 LUT**; `gdn_block` falls **10,285**. The
two agree to 47 LUT, which is what a saving passing through a boundary
untouched looks like. DSP, BRAM, URAM and WNS are identical on both pairs.
Vivado's own peak RSS on `l2norm_rs` falls from **12.56 GiB to 2.99 GiB**.

By census root, inside `gdn_block`:

    root                       before     after     delta
    q     (u_l2/q_reg)          8,354         -
    k     (u_l2/k_reg)          6,710         -
    gkq.q (u_l2/gkq[*])             -     1,518
    gkq.k (u_l2/gkq[*])             -     1,624
                               ------    ------    ------
                               15,064     3,142   -11,922 primitives

    l2_x                       18,433    18,433         0
    rp_cvj                     17,473    17,472        -1
    rp_qs                       8,192     8,193        +1
    rp_kn                       8,192     8,192         0

**The four read muxes do not move by more than one LUT**, which is the same
statement section 3 makes on a purpose-built harness, made here on the shipping
module.

The pre-existing independent oracles were run too and are unaffected:

    sim/regress.sh --only l2norm : OVERALL PASS 1  FAIL 0
    sim/regress.sh --only gdn    : OVERALL PASS 12 FAIL 0 NOCHECK 1

The full gate, unfiltered last lines (`full_gate.log`):

     suite sim   PASS 74   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
     suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
     OVERALL     PASS 100  FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
     REGRESSION: PASS

100 is exactly the working-tree figure TRACK WRITEDEC's last full gate measured.
`BASELINE_PASS` is left at 93, the clean-`git archive` ceiling, and
`sim/regress.sh` is not touched by this track at all.

`sim/tb_l2norm_rs.vhd` carries an INDEPENDENT real-valued accuracy assertion (it
exists because this unit's first testbench certified a broken recipe by computing
its golden from the same recipe). `tb_gdn_block` and `tb_gdn_block_vec` exercise
`l2norm_rs` inside the composed block against `ref/gdn_block_vec.c`.

### Teeth: 14 mutations at N=128 LANES=4, 9 caught, and the five that do NOT bite

An analysis failure is scored VOID, never CAUGHT -- WRITEDEC's first mutant
script scored all seven CAUGHT because ghdl could not open a file. The unmutated
control is run first and must PASS or the table means nothing; it did.

    control (unmutated)            : PASS
    idx_off                        : CAUGHT
    lastword                       : CAUGHT
    no_rst                         : NOT CAUGHT
    no_v1                          : NOT CAUGHT
    no_state                       : NOT CAUGHT
    no_zero                        : CAUGHT
    zero_off                       : NOT CAUGHT
    kq_swap                        : CAUGHT
    lane_rev                       : CAUGHT
    shk_off                        : CAUGHT
    nobias_k                       : CAUGHT
    nobias_q                       : CAUGHT
    sat_hi                         : CAUGHT
    sat_lo                         : NOT CAUGHT

**The five that do not bite are the most useful rows here and each has a
different reason.**

* `zero_off` moves `S_ZERO`'s write index by one word. It is **genuinely an
  identity**: every generate instance still fires exactly once as `idx` sweeps
  `0..NB-1`, and every word is written the same value, zero. A permutation of
  zeros is zeros. This mutation could never bite and says nothing about the check.
* `no_state`, `no_v1`, `no_rst` each delete one guard term. All three are
  **idempotent at the output**: `v1` is only ever `'1'` inside `S_EMIT` (so the
  `state` term is redundant), the spurious `v1 = '0'` write lands on word 0 which
  the real write overwrites two cycles later, and the extra write on the reset
  cycle is erased by the next full emit. Nothing observes `k_mant` between a
  mid-run reset and the following `done`, and `gdn_block` never does. The terms
  are kept anyway, because equivalence to the pre-change file is the property
  being preserved and "provably unobservable today" is not the same claim.
* **`sat_lo` is the real one, and the first answer I wrote about it was wrong.**
  At the shape the mutation table is run at, N=128 LANES=4, it is NOT CAUGHT by
  any of the 16 classes, including two written specifically to try -- a lone
  `-20000` and a lone `-32768`. I concluded the negative saturation branch was
  unreachable in principle, by the argument that `|x[i]| <= sqrt(ssq)` bounds
  `k_n` at 32768 in magnitude, which lands on `-32768` exactly, which is
  REPRESENTABLE, so the `resize` branch takes it and the clamp never runs.
  **That argument is correct about the k path and forgets the q path entirely.**
  Re-running the same mutant across shapes:

        N=8   LANES=1 : CAUGHT
        N=32  LANES=4 : CAUGHT
        N=128 LANES=4 : NOT CAUGHT
        N=512 LANES=4 : NOT CAUGHT

  The q path emits at exponent 18 with a `1/sqrt(N)` fold, so
  `|q_s| <= 2^18 / sqrt(N)`, which exceeds 32,768 exactly when **N < 64**. At
  N=8 that ceiling is 92,682 and class 3 (alternating +32767 / -32768) drives it
  straight through the low clamp. At N=128 it is 23,170 and nothing can reach
  either clamp on the q path; only the k path can, and only its HIGH side, which
  is why `sat_hi` is caught there and `sat_lo` is not.

  So the honest statement is not "unreachable" but: **the negative saturation
  branch of `sat16` is dead at the shipping shape (`gdn_block` instantiates
  `l2norm_rs` at N = DIM = 128) and live only at N < 64.** The 8-shape sweep
  covers it at N=8 and N=32; the mutation table, run at one shape, does not.
  Recorded this way rather than corrected silently, because the wrong version
  was a plausible-sounding closed-form argument that would have been believed:
  **coverage of the input space is not coverage of the output space, and a
  bound argument that covers one output path is not a bound argument.**

## 5. The measured fallback that is NOT the BRAM trade

**Distributed RAM, `ram_style = "distributed"`, measured in the same probe.**
This is LUT-based memory. It uses **zero BRAM tiles and zero URAM**, so it is
not the trade this track was told to leave alone, and unlike BRAM its read is
**asynchronous**, so it inserts no pipeline stage and changes no schedule.

    store          flat register           distributed RAM        delta
    2,048 x 16b    9,311 LUT  32,832 FF    728 LUT   64 FF    -92.2% LUT, -99.8% FF
    4,096 x 16b   18,543 LUT  65,552 FF  1,456 LUT   64 FF    -92.1% LUT, -99.8% FF

`gdn_block` already proves Vivado infers this pattern in this very file without
being asked: the `rc_gdn_after` log carries
`INFO: [Synth 8-6904] The RAM "gdn_block/eg_b_reg" of size (depth=32 x width=16)
is automatically implemented using LUTRAM` for `eg_b`, `beta_b` and
`u_recur/egbuf`.

**Applied to B's four read muxes, on the measured 92% factor:**

    root      source store        today    as distributed RAM   needs a streaming port?
    l2_x      qbuf + kbuf, 2 x 32,768 b   18,433      ~1,456    YES -- l2norm_rs.x_mant
    rp_cvj    vbuf,            65,536 b   17,472      ~1,456    NO  -- ALREADY one element
    rp_kn     knb,             32,768 b    8,192        ~728    YES -- gdn_recur_pipe
    rp_qs     qsb,             32,768 b    8,193        ~728    YES -- gdn_recur_pipe
                                          ------      ------
                                          52,290      ~4,368     DERIVED, -47,922

**`rp_cvj` is the second largest of the four and the only one that needs NO
interface change at all.** `gdn_block:1122` already reads exactly one 16-bit element
(`rp_cvj <= signed(vbuf(base+15 downto base))`), and `vbuf` has exactly one
reader and one writer in disjoint FSM phases. Only the storage declaration
moves. That was not known when this track was briefed, and it is the cheapest
16,000 LUT on the board.

**This was NOT implemented.** The brief says to stop rather than escalate into a
storage change once the measurement says the fit does not close, and the
measurement says the fit does not close. The numbers are here so the decision
can be made on evidence.

## 6. Composition: this does not close the fit, and it was never going to

All rows are post-synthesis CLB LUTs at `-flatten_hierarchy none`. B is measured
by this track; C, D's five sequencer leaves and D's norm are TRACK WRITEDEC's
rows, quoted unchanged so the composition is summed from one flow.

    row                                          WRITEDEC   READCONV   source
    B   gdn_block                                 131,760    121,475   measured here
    C   attn_block                                 85,816     85,816   wd_attn_after
    D   seq_desc_fetch+opdec+region_lock
        +vec_issue+vec_res                          6,614      6,614   wd_seq_*
    D   norm AS llama_top INSTANTIATES IT
        (lutdiet_rms_flat)                        170,811    170,811   wd_rmsflat_after
                                                  -------    -------
    total                                         395,001    384,716

    against 268,222 free on the device : 1.47x over -> 1.43x over  (116,494 short)
    against 233,765 free in pb_core    : 1.69x over -> 1.65x over  (150,951 short)

**This track moved the total by 10,285 LUT, 2.6%.** That is the honest size of
it and it was always going to be, because 52,290 of B's LUT is read mux and
section 3 says the read mux does not respond to the conversion the track was
dispatched to make.

### What it would actually take, and the big one is not mine

    lever                                                       LUT       class
    1  l2norm_rs write decode                LANDED HERE     -10,285   MEASURED
    2a rp_cvj -> distributed RAM             not taken       -16,016   DERIVED from probe
    2b l2_x, rp_kn, rp_qs -> distributed RAM not taken       -31,906   DERIVED from probe
       (2b additionally needs streaming ports on l2norm_rs and gdn_recur_pipe)
    3  llama_top's D-vec norm write decode   NOT MY FILE    -125,791   ESTIMATE

    after 1        384,716   device 1.43x OVER   pb_core 1.65x OVER
    after 1+3      258,925   device FITS  +9,297 pb_core   25,160 OVER
    after 1+3+2a   242,909   device FITS +25,313 pb_core    9,144 OVER
    after 1+3+2a+2b 211,003  device FITS +57,219 pb_core  FITS +22,762

**Lever 3 is `rtl/llama_top.vhd` and belongs to TRACK CLOG2TOP right now.** Its
size is not a guess about where the cost might be; WRITEDEC's own census of
`lutdiet_rms_flat` after its change accounts every one of the 237,113 LUT
primitives behind that 170,811:

    root      LUT prims   F7     F8       what it is
    wv           88,640    0      0   the WRAPPER's flat vector write demux
    xv           88,640    0      0   the other one.  Together 74.8%
    ARG          17,916  8,704  4,352 rmsnorm_rs's x_mant/w_mant read mux
    sq           17,475  8,704  4,352 rmsnorm_rs's S_ACC read mux
    ord          17,472  8,736  4,368 the wrapper's output read mux
    gow.o         2,947    0      0   rmsnorm_rs's own decode, ALREADY fixed

`xv` and `wv` carry **zero MUXF7 and zero MUXF8 and 65,536 flops each**, which
is the write-demux signature exactly, and they are 74.8% of D's norm. The
ESTIMATE above assumes WRITEDEC's measured removal fraction on the identical
structure one level down (`o_reg` at N=4096: 162,276 -> 2,356 primitives, 98.5%)
carries across. **That assumption is the whole of lever 3's number and it has
not been measured.**

**The conclusion, stated plainly.** `pb_core` does not close on B's read side.
It does not close on B's read side plus this track's write fix. On these numbers
it closes only with lever 3 AND essentially all of B's read side, and lever 3 is
the largest single item on the board and is in another track's file. If lever 3
lands at anything near its estimate, the *device* fits without touching B's read
side at all; `pb_core` is what forces the rest.

## Measured and REJECTED -- do not retry

1. **Narrowing a flat-register read port.** `readconv_flat` at SELW = 128, 4 and
   1 over the same 2,048-word store. The cost does not move with the port width;
   it is set by the store. Converting `l2norm_rs`'s `x_mant`, `gdn_recur_pipe`'s
   `rp_kn`/`rp_qs` or anything else to a streaming port, **on its own**, is work
   with no area behind it. Do not re-derive this from the F7/F8 signature; the
   signature is consistent with both hypotheses and only the controlled pair
   separates them.
2. **Hunting B's read cost by the MUXF7/MUXF8 signature and stopping there.** It
   finds `l2_x`, `rp_cvj`, `rp_kn`, `rp_qs` and misses `u_l2/q_reg` and
   `u_l2/k_reg` entirely -- 15,064 LUT with zero F7 and zero F8, which is the only
   part of B's read column that actually came off.
3. **Quoting LUTDIET's 8.9% read share against the shipping module.** It is a
   fraction of a denominator that WRITEDEC has since cut by 3.3x. The shipping
   figure is 39.7%.
4. **Rotating the staging registers instead of muxing them.** Every read index
   in `gdn_block` advances monotonically (`kh` 0..15 for `l2_x`,
   `vh mod KEY_HEADS` for `rp_kn`/`rp_qs`), so a circular shift by one head per
   read would put the wanted slice permanently at the bottom and delete the mux.
   NOT MEASURED, and rejected on arithmetic before it was: rotating means every
   one of the 32,768 storage flops needs a 2:1 mux on its D input to choose
   between the conv write and its neighbour, which is of order 0.5-1 LUT per bit
   -- the same 16-32k it was meant to remove. It also destroys WRITEDEC's
   constant-index write generate. Labelled DERIVED, not MEASURED; it is here so
   the next person does not spend a night on it.

## Measurement traps hit, including my own

* **A `pgrep`/`pkill` on a pattern in my own command line was not used**, per the
  standing rule. Concurrency was managed by chaining runs in one background shell.
* **Machine contention is real and it is not silent.** `rc_gdn_after` ran while
  another track held ~10 GB, and Vivado printed `Thrashing Detected! Process may
  be trying to use more memory than is available` on a loop with major page faults
  climbing. It is not an error and the run survives, but the elapsed time is
  meaningless and a run that dies here must not be read as a property of the RTL.
* **The `ref` copy was verified by un-renaming, not by eye.** `sed`-ing
  `l2norm_rs_ref` back to `l2norm_rs` and `diff`ing against the pinned archive
  returns empty. A hand-checked rename is exactly the kind of thing that silently
  drops a line.
* **Every changed file was `cmp`'d into the synthesis tree before synthesis.**
  WRITEDEC recorded a run made against an unchanged tree that produced a plausible
  wrong number.
* **A closed-form reachability argument covered one output path and I believed
  it.** `sat_lo` NOT CAUGHT at N=128 led me to write that the negative saturation
  branch is unreachable, with a bound argument that is correct about the k path.
  The q path emits at a different exponent with a `1/sqrt(N)` fold and has a
  different bound, and the mutant IS caught at N=8 and N=32. **A mutation table
  run at ONE shape is a statement about that shape.** The corrected version is in
  section 4 and the wrong one is left standing next to it rather than deleted.
* **The mutation anchors are asserted unique.** A `str.replace` with a
  non-unique anchor mutates more than intended and the verdict is then about a
  different mutant than the one named. Non-unique scores VOID(anchor), not CAUGHT.

## What was NOT verified

* **`gdn_block` was not re-verified against an oracle at its own output by this
  track.** `l2norm_rs`'s ports and cycle behaviour are unchanged and proven
  unchanged, and `tb_gdn_block` / `tb_gdn_block_vec` pass, but those benches were
  not written by me and I did not teeth-check them.
* **The distributed-RAM numbers in section 5 are a probe, not an implementation.**
  Nothing has been converted. In particular the probe does not model the
  read/write phase separation that a real conversion of `qbuf`, `kbuf`, `knb`,
  `qsb` or `vbuf` would have to argue, nor the extra cycle a registered RAM read
  inserts into `gdn_block`'s schedule.
* **`attn_block` was not synthesised by this track.** Its read column was read
  out of WRITEDEC's `census_wd_attn_after.txt` and is quoted, not measured here.
* **No timing closure claim beyond the OOC WNS printed by `report_timing_summary`
  at 5.0 ns with no clock source constraint.** An OOC synthesis estimate is not an
  implementation result.
* **`opt_design` was not run** (`LUTDIET_NOOPT=1`), for comparability with
  LUTDIET's and WRITEDEC's tables. Every number here is post-synthesis.
