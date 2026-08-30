# TRACK DISTRAM -- subsystem B's staging buffers as distributed RAM, 2026-08-29

## The question, verbatim

> **Lever 2a: `rp_cvj` -> distributed RAM.** DERIVED -16,016 LUT. No interface
> change.
> **Lever 2b: `l2_x` / `rp_kn` / `rp_qs` -> distributed RAM.** DERIVED -31,906 LUT.
> Both figures are READCONV's, labelled DERIVED from its probe. **Your job is to
> make them MEASURED**, or to report why they do not hold. Tonight, LUTDIET's
> per-module projections were optimistic on **every** row [...] Do not add a third.
>
> **Check the "disjoint FSM phases" claim yourself before relying on it.**
>
> **If levers 2a+2b close `pb_core` on the correct booking, that is the
> schedule-critical result of the night and should be stated plainly and first.**

Hardware: none, at any point. Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, 5.0 ns,
`synth_design -mode out_of_context -flatten_hierarchy none`, `LUTDIET_NOOPT=1`,
`LUTDIET_CENSUS=1`, one Vivado at a time. Simulation: GHDL mcode.
Pinned tree `b1bbcb2e9b500ce9a702b336bbeb03b73dbea570` (HEAD at dispatch; `rtl/`
is byte-identical to it throughout, checked, so nothing here is confounded by a
concurrent track).

---

## The answer, up front

**`pb_core` CLOSES, with 16,384 LUT of headroom, and the device closes with
50,841. That is the schedule-critical result and it is MEASURED, not derived.**

`gdn_block` goes from **121,475 to 75,297 CLB LUT, -46,178 (-38.0%)**, at
identical DSP (253), identical BRAM (43), zero URAM, and WNS identical to three
decimals (+0.483 ns). Flip-flops fall 248,799 -> 52,226. The block is
**bit-exact and CYCLE-exact** against a byte-for-byte renamed copy of the pinned
file, over 18,313 compared cycles of which 18,136 are busy, on all 37 output
ports, 0 mismatches, with the per-invocation cycle count unchanged at 2,267.

**READCONV's two levers both hold, and its structural account of them does
not.** The corrections are in section 3 and they matter more than the totals:

* **Lever 2a is real and is bigger than derived: -17,295 MEASURED against
  -16,016 DERIVED.** Every projection the brief named tonight came in
  optimistic; this row came in the other way.
* **Lever 2b's *number* is nearly right (-28,883 MEASURED against -31,906
  DERIVED) but its *reason* is wrong.** READCONV booked `l2_x`, `rp_kn` and
  `rp_qs` together as "needs a streaming port on `l2norm_rs` and
  `gdn_recur_pipe`". **None of the three needs any port change at all.** `knb`
  and `qsb` are already head-granular on BOTH sides, and `qbuf`/`kbuf` become a
  bank array whose write hits one bank and whose read takes every bank at one
  address. **No port on any unit moved, no cycle was added anywhere, and
  `rtl/l2norm_rs.vhd` and `rtl/gdn_recur_pipe.vhd` were not edited.**
* **The two bookings in circulation reconcile exactly to 263,559**, and neither
  of the quoted totals (READCONV's 384,716, NORMADAPT's 273,844) was the current
  position. Section 2.

**One thing this does NOT do: it does not touch subsystem C or D.** `pb_core`
closes because B falls by 46,178 against a shortfall of 29,794, not because
anything else improved.

---

## 1. What was reproduced before anything was changed

    tag           top          generics     LUT       FF     DSP  BRAM   F7      F8     WNS
    dr_gdn_base   gdn_block    (defaults) 121,475  248,799   253    43  28,946  13,327  +0.483

`dr_gdn_base` is TRACK READCONV's `rc_gdn_after` row, digit for digit on every
column it reports. Nothing was changed until it did.

---

## 2. The two bookings, reconciled

Two totals were in circulation and the brief asked for them to be settled.

    READCONV, section 6      B 131,760->121,475  C 85,816  D_seq 6,614  D_norm 170,811  = 384,716
    NORMADAPT, section 2(d)  B 131,760           C 85,816  D_seq 6,614  D_norm  49,654  = 273,844

**They differ for two independent reasons that neither document could see, and
each document is right about the half it measured:**

* READCONV carried `D_norm = 170,811`, which is TRACK WRITEDEC's **model** of
  the D-vec norm adapter. NORMADAPT then **measured** that adapter and landed
  it at 49,654 (`9a7f3c0`, `45981f0`). Difference **-121,157**.
* NORMADAPT carried `B = 131,760`, which is the **pre-READCONV** `gdn_block`.
  READCONV landed B at 121,475 (`e5e4fa5`). Difference **-10,285**.

Apply each document's missing half and both land on the same number:

    384,716 - 121,157 = 263,559
    273,844 -  10,285 = 263,559

**So the position when this track started was 263,559**, not 384,716 and not
273,844:

    vs 268,222 free on the device : FITS, 4,663 spare
    vs 233,765 free in pb_core    : OVER by 29,794  (1.127x)

That 29,794 is the number every figure below is measured against.

### The result, on that booking

    row                     before      after     source
    B  gdn_block           121,475     75,297     MEASURED here, dr_gdn_base -> dr_gdn_2abc_f
    C  attn_block           85,816     85,816     wd_attn_after, quoted unchanged
    D  sequencer leaves      6,614      6,614     wd_seq_*, quoted unchanged
    D  norm adapter         49,654     49,654     NORMADAPT, measured, quoted unchanged
                           -------    -------
    total                  263,559    217,381

    vs 268,222 free on the device : FITS, 4,663 spare  ->  FITS, 50,841 spare
    vs 233,765 free in pb_core    : OVER by 29,794     ->  FITS, 16,384 spare

**`pb_core` closes.** The margin is 7.0% of the pblock, which is not
comfortable, but it is the first time this composition has been under the line.

**What that margin is NOT.** These are post-synthesis OOC estimates with
`opt_design` deliberately not run, no placement, no routing, no shell, and no
cross-subsystem merging. C and D are quoted from other tracks' flows. A
composition that fits in this arithmetic is a necessary condition for the
design to fit, not a sufficient one.

---

## 3. The three levers, and where READCONV's structural account is wrong

`gdn_block` has five flat staging registers. WRITEDEC already fixed their
**write** decode; what remained was the **read** side, and READCONV measured
that narrowing a read PORT does nothing because the cost is the mux's source
size. The fix is therefore to stop the store being a flat register at all.

The question READCONV did not ask is **at what granularity each buffer is
written and read**, and that is the whole of what decides whether a port has to
move.

| buffer | bits | written | read | port change needed? |
|---|---:|---|---|---|
| `vbuf` | 65,536 | one `CONV_LANES`-word beat | ONE 16-bit element | **no** (READCONV agreed) |
| `knb` | 32,768 | one whole `DIM`-element head | one whole head | **no** (READCONV said yes) |
| `qsb` | 32,768 | one whole head | one whole head | **no** (READCONV said yes) |
| `qbuf` | 32,768 | one beat | one whole head | **no**, via banking (READCONV said yes) |
| `kbuf` | 32,768 | one beat | one whole head | **no**, via banking (READCONV said yes) |

### 3a. Lever 2a -- `vbuf`, the one READCONV named

`gdn_block:1122` reads exactly one 16-bit element. `vbuf` becomes
`array(0 to NBV-1) of std_logic_vector(CONV_LANES*16-1 downto 0)` with
`ram_style = "distributed"`; the read becomes a RAM read at `vidx/CONV_LANES`
followed by a 4:1 lane mux on 16 bits. `rp_cvj`'s census row goes
**17,472 -> 272 LUT**.

### 3b. Lever 2b -- `knb` and `qsb` were ALREADY head-granular on both sides

This is the correction that matters. READCONV's section 5 table books `rp_kn`
and `rp_qs` as "YES -- gdn_recur_pipe" under "needs a streaming port?". They do
not. Read the RTL:

    gqsb write:  qsb((h+1)*DIM*16-1 downto h*DIM*16) <= l2_q;   -- ONE WHOLE HEAD
    P_HKQ read:  rp_qs <= qsb(base+DIM*16-1 downto base);        -- ONE WHOLE HEAD

Both sides address the same `DIM*16`-bit object. The buffer is therefore a
`KEY_HEADS`-deep by `DIM*16`-wide memory as written, and the conversion is one
declaration plus one indexed write plus one indexed read. `rp_kn` goes
**8,192 -> 1 LUT** and `rp_qs` **8,193 -> 0**.

### 3c. Lever 2c -- `qbuf` and `kbuf`, the asymmetric pair, WITHOUT streaming

These are the ones READCONV's premise was actually about: written one beat at a
time, read one whole head at a time, a 32x width mismatch. A single memory
cannot do that. **`NBH = DIM/CONV_LANES` memories can.**

Bank `j` holds, for every head, the `j`-th beat of that head. The write hits
exactly one bank -- bank `obeat mod NBH` at address `obeat / NBH` -- and the
read takes **all** banks at the same address `kh` and concatenates them. That
is a whole head in one cycle, out of `KEY_HEADS`-deep memories, with no
streaming, no port change and no extra state.

`l2_x`'s census row goes **18,433 -> 2,049 LUT**. The residual 2,049 is the
q/k select, one LUT per bit plus one: exactly the `+1` READCONV identified in
`l2_x`'s original `2048 x 9 + 1` signature, now the only thing left of it.

### The census, root by root

    root      dr_gdn_base   dr_gdn_2a   dr_gdn_2ab   dr_gdn_2abc
    rp_cvj        17,472         272          273           273
    rp_kn          8,192       8,192            1             1
    rp_qs          8,193       8,193            0             0
    l2_x          18,433      18,433       18,433         2,049
                  ------      ------       ------        ------
                  52,290      35,090       18,707         2,323

    CLB LUT      121,475     104,180       90,168        75,297
    delta                    -17,295      -14,012       -14,871
    LUT as memory  4,099       5,283        7,627        10,187
    CLB FF       248,799     183,243      117,799        52,226
    DSP              253         253          253           253
    BRAM tile         43          43           43            43
    URAM               0           0            0             0
    F7            28,946      20,337       12,145         3,953
    F8            13,327       9,023        4,927           831
    WNS (ns)      +0.483      +0.483       +0.483        +0.483

**Zero BRAM tiles and zero URAM were added.** This is LUT memory, which is why
it is not the BRAM trade READCONV was told to leave alone, and why the read
stays asynchronous and the schedule does not move.

### Derived versus measured, stated plainly

    lever              READCONV DERIVED    MEASURED here    error
    2a  vbuf                   -16,016          -17,295     8.0% BETTER than derived
    2b  l2_x+rp_kn+rp_qs       -31,906          -28,883     9.5% worse than derived
        (as implemented: knb+qsb -14,012, qbuf+kbuf -14,871)
                               -------          -------
        total                  -47,922          -46,178     3.6% worse than derived

The brief warned that every projection tonight came in optimistic. **The
aggregate here is optimistic too, by 3.6%, which is an order of magnitude
smaller than the 41,120 / 12,985 / 6,614 / 52% misses it warned about** -- and
2a came in the other way, which none of the rows the brief named did. The
reason both halves are close is that READCONV's factor came from a probe of the
identical structure at the identical sizes, not from a fraction of a census.

---

## 4. Bit-exactness, and why it is cycle-exact and not only value-exact

**The oracle is the pre-change file, not the unit itself.** A round trip is not
an oracle. `hw/fk33/results/distram_2026-08-29/rtl/gdn_block_ref.vhd` is
`rtl/gdn_block.vhd` at the pinned SHA, byte for byte, with only the entity and
architecture names changed -- **verified by un-renaming it and diffing against
`git show b1bbcb2:rtl/gdn_block.vhd`**, both files present and 55,363 bytes
each (the sizes are stated because `diff <(a) <(b) && echo IDENTICAL` is true
when both files are missing).

**The bench is a SHADOW DUT, and the shape is the point.**
`rtl/tb_distram_gdn.vhd` is `sim/tb_gdn_block.vhd` with a second instance bound
to `gdn_block_ref`. Both instances see the SAME environment signals; only the
DUT's outputs feed the environment back. The environment at cycle N is a
function of DUT outputs at cycles < N, so if every port has matched up to N-1
the shadow has seen byte-identical inputs and a mismatch at N is a real
divergence caught **on the cycle it happens**. That is what makes this a
cycle-exact check: a dump-and-diff cannot tell "same values, two cycles later"
from "identical", and a storage change that alters read timing is precisely a
bug of that shape.

All **37** output ports are compared on every rising edge, by name:
`busy cap_ready cv_seg cv_ren cv_grp cv_taken eseg_taken sc_head sc_taken
st_ren st_rhead st_rcol st_rgrp st_wen st_whead st_wcol st_wgrp st_wdata
se_rhead se_rcol se_wen se_whead se_wcol se_wdata w_taken z_ready y_valid
y_mant y_last y_exp done err_conv err_g err_se y_sat dbg_col_ready
dbg_col_drop`.

**Non-triviality is asserted, not assumed.** A comparator that ran only while
the block was idle would pass on anything, so busy cycles are counted
separately and the bench fails hard below 1,000.

    variant   checks   live    fails   cycles/invocation (8 invocations)
    control   18,313  18,136       0   2267 2267 2267 2267 2267 2267 2267 2267
    2a        18,313  18,136       0   2267 x8
    2ab       18,313  18,136       0   2267 x8
    2abc      18,313  18,136       0   2267 x8
    2abc_f    18,313  18,136       0   2267 x8   <-- THE SHIPPED BYTES

**Which bytes each row ran on, because it is not the same for all four.** `2abc_f` is
the SHIPPED file, `cmp`-identical to `rtl/gdn_block.vhd` and to the file
`dr_gdn_2abc_f` synthesised; `2abc` is that file with one dead variable
declaration (`variable base : integer`, left with no remaining use once the
three slice reads went away) still present. Removing it re-measured to the
digit -- 75,297 LUT, 52,226 FF, 253 DSP, 43 BRAM, WNS +0.483 -- and re-passed
equivalence. **The mutation table in section 5 was run on the `2abc` bytes**,
i.e. with that declaration still there, which is a declaration-only difference
from what ships. The `2a` and `2ab` rows ran on the
intermediate variants BEFORE `attribute ram_style : string;` was hoisted to the
top of the architecture, so they differ from the finally-shipped intermediates
by the position of one declaration. Those two intermediates are not shipped;
what IS shipped is covered by the `2abc` row on its exact bytes, and the
re-synthesis `dr_gdn_2a_f` / `dr_gdn_2ab_f` confirms the hoist changes no
resource number.

The `control` row is the UNMODIFIED tree run through the same bench: it proves
the harness wiring, and it proves nothing about resolution. Resolution is
section 5.

### The "disjoint FSM phases" claim, checked rather than inherited

The brief said to check this myself. **It holds for all five buffers, and for
`vbuf` the conversion does not actually depend on it.**

* **`vbuf` does not need the argument.** A distributed-RAM read concurrent with
  a write to the same address returns the OLD contents, and that is exactly
  what the flat register did: `rp_cvj <= vbuf(...)` inside a clocked process
  samples the pre-edge value. The two forms agree cycle for cycle even under a
  same-address collision. The phase argument is what makes a SINGLE-PORT memory
  legal, which is a different claim, and it holds: every `vbuf` write is gated
  on `cv_seg_i > 1`, set only in the segment-2 conv/silu phases, which finish at
  `P_CVDRAIN -> P_SEGN` before `P_L2GO`; the only read is taken in
  `P_COL`/`P_DRAIN`, and no path returns to `P_EXP`/`P_CVGO` from there without
  passing `P_IDLE` (`P_WAITY -> P_IDLE`).
* **`knb`/`qsb`**: written in `P_L2WAIT`, read in `P_HKQ`. `P_L2N` leaves the L2
  loop only after `kh = KEY_HEADS-1`, so every write of an invocation precedes
  every read of it.
* **`qbuf`/`kbuf`**: written under `cv_seg_i = 0` / `= 1` in the conv phases,
  which end at `P_SEGN` before the first `P_L2GO`.

**One real index hazard was found by doing this, and it is not a phase
question.** `obeat` is declared `integer range 0 to NBV` and `kh`
`integer range 0 to KEY_HEADS`; both reach their maximum between phases. The
per-word generates were implicitly bounded (`obeat = wi` for `wi in 0..NBV-1`
simply never matched), but a direct memory index is not. Every converted write
therefore carries an explicit bound -- `obeat < NBV`, `obeat < NBQ`,
`kh < KEY_HEADS`, `khr := kh mod KEY_HEADS` -- and each one is an exact
transcription of the bound the generate gave for free, not a new condition.
Without them this would have been an out-of-range access that the flat form
could not have had.

### The pre-existing independent oracles

    sim/regress.sh --only gdn :
     suite sim   PASS 12   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
     suite tb    PASS 0   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0
     OVERALL     PASS 12   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1   SKIPPED 0
     REGRESSION: PASS

12 / 0 / 1 is exactly what TRACK READCONV's `--only gdn` measured on the tree
this one started from. `sim/tb_gdn_block_vec.vhd` is in that count and it is
the INDEPENDENT oracle: it compares `gdn_block` against `ref/gdn_block_vec.c`,
which computes the whole block from the spec rather than from this RTL.

The full gate, unfiltered last lines (`full_gate.log`):

     suite sim   PASS 80   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
     suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
     OVERALL     PASS 106  FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
     REGRESSION: PASS

**106, not the 100 the brief predicted, and the difference is not mine.** Other
tracks landed new rows during this session; the gate's own footer lists the 22
working-tree-dependent rows and says explicitly not to raise `BASELINE_PASS`
from such a run. `sim/regress.sh` is not touched by this track at all
(`git diff -- sim/regress.sh` is empty).

**A correction to my own brief.** It stated `BASELINE_PASS` is 93. It is **98**
as of `b60591d`, TRACK FLOOR. **Both gate runs above still print `the floor of
93`**, because each took its private copy of `sim/regress.sh` before that commit
landed; the raise is real and the printed floor in these two logs is stale, not
the other way round. This track did not change `BASELINE_PASS` and does not
propose changing it -- and per the gate's own footer, neither 106 nor 105 may be
used to raise it, since both counts include 22 working-tree-dependent rows.

**One honesty note about this run.** It was started before the dead `variable
base` declaration was removed, so it read `rtl/gdn_block.vhd` across that edit.
The difference is one unused declaration and both forms analyse and simulate;
the equivalence run `equiv_2abc_f` and the synthesis `dr_gdn_2abc_f` are both
on the final bytes. A confirming gate on the settled tree is in
`full_gate_final.log`, and it is NOT green -- see immediately below.

### The confirming gate is RED, on one row that is not mine, and here is the proof

    OVERALL     PASS 105  FAIL 1   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
    NOT GREEN:
       - sim:tb_matvec_fk33_desc
    REGRESSION: FAIL

    sim:tb_matvec_fk33_desc  FAIL  50  exit 1: ghdl-mcode:error:
        bound check failure at rtl/axi_rd_fsm.vhd:231

That row is **subsystem A**. `grep -n gdn sim/tb_matvec_fk33_desc.vhd` returns
nothing, so `gdn_block` is not in its design at all. It **passed** in the
21:57 gate and **failed** in the 22:23 one, and between those two runs TRACK
ACOV committed a new `sim/tb_matvec_fk33_desc.vhd` (`028829e`) -- a file this
track is explicitly forbidden to touch.

**Asserting that is not the same as measuring it, so it was measured**, with
two runs of `--only tb_matvec_fk33_desc` (3 rows each) on CLEAN
`git archive HEAD` trees under `REGRESS_REPO`:

    tree                                              verdict
    git archive HEAD, gdn_block reverted to pinned    OVERALL PASS 3  FAIL 0
    git archive HEAD, gdn_block = THIS COMMIT         OVERALL PASS 3  FAIL 0

**The row passes on a clean checkout that carries this change.** It fails only
in the shared working tree, which at 22:23 held another track's uncommitted
`rtl/llama_top.vhd` and a large set of untracked `sim/` files that
`sim/regress.sh` auto-discovers and that a clean archive regenerates. That is
the "gate row failing from another track's dirty file" case the brief names,
and it is left alone rather than chased: the file belongs to TRACK ACOV.

**What this does NOT prove.** It does not prove the working tree is healthy,
and it does not prove the 21:57 `PASS 106 / FAIL 0` is the state of the tree
now. It proves only that the failing row does not depend on this change.

---

## 5. Teeth: the mutation table

An analysis or elaboration failure is scored **VOID**, never CAUGHT -- TRACK
WRITEDEC's first mutant script scored all seven CAUGHT because ghdl could not
open a file. A non-unique anchor is scored **VOID(anchor)**, because a replace
with a non-unique anchor mutates more than intended and the verdict is then
about a different mutant than the one named. The unmutated control is run first
and must PASS.

### The table

    control (unmutated)            : PASS
    v_lane_off                     : CAUGHT
    v_lane_zero                    : CAUGHT
    v_word_off                     : CAUGHT
    v_wr_seg                       : NOT CAUGHT
    v_noguard                      : NOT CAUGHT   <-- a no-op BY CONSTRUCTION, see below
    v_noguard_real                 : NOT CAUGHT
    b_swap                         : CAUGHT
    b_head_off                     : CAUGHT
    b_wr_qk                        : CAUGHT
    c_bank_off                     : CAUGHT
    c_kh_off                       : CAUGHT
    c_qk_swap                      : CAUGHT
    c_gather_rev                   : CAUGHT
    c_noguard_real                 : NOT CAUGHT
    sched_hgap                     : CAUGHT       <-- the schedule mutation

11 of 15 caught. The `control` row is reported by the same rule as every other
row and therefore prints as `NOT CAUGHT`, which is what a control must score;
it is written `PASS` above to keep it readable, and the raw verdict is in
`mutants.log`.

### THE ATTRIBUTION CONTROL, and it changes what this table means

**A kill does not settle it.** For four representative mutants the SAME mutant
was run through the PRE-EXISTING block value oracle -- `sim/regress.sh --only
gdn_block_vec`, `gdn_block` against `ref/gdn_block_vec.c`, with the shadow bench
nowhere in the picture, in a private `REGRESS_REPO` copy so `rtl/` was never
touched (`scripts/run_attribution.sh`):

    mutant              shadow bench      tb_gdn_block_vec (the OLD property)
    (unmutated)         PASS              OVERALL PASS 1  FAIL 0
    v_lane_off          CAUGHT            OVERALL PASS 0  FAIL 1
    b_head_off          CAUGHT            OVERALL PASS 0  FAIL 1
    c_kh_off            CAUGHT            OVERALL PASS 0  FAIL 1
    sched_hgap          CAUGHT            OVERALL PASS 1  FAIL 0

**So THREE of the four kills are NOT the new bench's.** Every value mutation
this track wrote is also killed by an oracle that already existed, and saying
"the shadow bench caught nine mutations" without this control would have
overstated it exactly the way TRACK OI3MUT measured in one of its four pairs.

**The fourth is the one that justifies the bench.** `sched_hgap` forces `P_HKQ`
through `P_HGAP` with `hgapc = HEAD_GAP = 0`, inserting extra cycles and
changing no arithmetic: the invocation goes from 2,267 cycles to 2,271, the
first divergence is `st_ren` at cycle 716, and **`tb_gdn_block_vec` passes it
clean.** A pure schedule change is invisible to every value oracle this project
has, and a storage change that alters read timing is precisely a bug of that
shape -- which is the entire risk this track was told to guard.

### The four that do NOT bite, each for a different reason

* **`v_wr_seg`** changes `cv_seg_i > 1` to `cv_seg_i > 0`, so `vbuf` is also
  written during the k segment. It is a **genuine identity**: the segments run
  q, k, v in order, the k segment writes `vbuf` words 0..NBQ-1, and the v
  segment then writes words 0..NBV-1, overwriting every one of them. It could
  never bite and says nothing about the check's resolution.
* **`v_noguard`** rewrites `obeat < NBV` as `obeat <= NBV-1`. Those are the
  same condition. **This row is a no-op by construction and it is my own
  mistake**: it was written to test guard removal and tests nothing. It is left
  in the table under its own name rather than deleted, because a mutation table
  that quietly drops a bad row is a table you cannot audit. `v_noguard_real`
  and `c_noguard_real`, which delete the guard outright, were added afterwards.
* **`v_noguard_real` and `c_noguard_real`** delete `obeat < NBV` and
  `obeat < NBQ` entirely. **NOT CAUGHT, and this is a real measurement rather
  than a miss.** The guards are bounds insurance, not behaviour: `obeat` only
  ever reaches `NBV`/`NBQ` between segments, when `co_valid` is low, so at the
  shipping shape they never fire. They are kept because the flat form was
  bounded for free by `obeat = wi` and a memory index is not, and because
  "provably unreachable at this shape" is a weaker claim than "cannot go out of
  range". **What this pair does establish is that GHDL's own bound check did
  not fire either**, i.e. the reachability argument is confirmed at the shape
  the bench runs, not merely asserted.

### A trap in the mutation machinery itself

`c_gather_rev` first scored **`VOID(anchor x3)`** and would have been silently
lost as an untestable row. The anchor is a two-line string and the uniqueness
check was `grep -c -F`, **which counts matching LINES, not substring
occurrences**, so a genuinely unique two-line anchor reports 3. Fixed to count
in Python; the mutation then ran and was CAUGHT. A scoring bug that turns a
real mutation into a VOID is the same class of error as one that turns an
analysis failure into a CAUGHT, and it fails in the direction that looks
harmless.

---

## Measured and REJECTED -- do not retry

1. **Believing that `l2_x`, `rp_kn` and `rp_qs` need a streaming port.** They do
   not, and the brief that dispatched this track inherited that claim from
   READCONV section 5. `knb`/`qsb` are head-granular on both sides already;
   `qbuf`/`kbuf` are fixed by BANKING, not by streaming. **Nothing in
   `rtl/l2norm_rs.vhd` or `rtl/gdn_recur_pipe.vhd` was edited and no port
   moved.** Do not spend a track converting `l2norm_rs.x_mant` to a streaming
   interface; there is nothing behind it. (READCONV had already REJECTED
   narrowing a read port on its own, for a different and also correct reason.)
2. **Streaming a whole-vector read into the existing staging register over
   `DIM/CONV_LANES` cycles.** NOT MEASURED and rejected before it was: it is
   what lever 2c would have cost -- 32 extra cycles per L2 invocation, 1,024
   per layer -- and section 3c gets the same area for zero extra cycles. It is
   recorded because it is the obvious next idea and it is strictly worse.
3. **Reading the LUTRAM inference from the synthesis log.** `INFO: [Synth
   8-6904]` is printed only for AUTOMATIC inference. With `ram_style =
   "distributed"` forced, no message appears for `vbuf`, `knb`, `qsb`, `qbuf`
   or `kbuf` at all, and the log instead shows `gdn_recur_pipe`'s OWN internal
   `qbuf`/`kbuf` (depth 2 x width 2048), which have the same names and are a
   different unit. Grepping the log for your buffer's name and finding nothing
   is not evidence that the conversion failed, and grepping and finding
   something is not evidence that it worked. Read the census and
   `LUT as Memory` instead.
4. **Quoting either circulating B+C+D total.** 384,716 (READCONV) and 273,844
   (NORMADAPT) were both stale, in opposite directions, and both resolve to
   263,559. See section 2.

---

## Measurement traps hit, including my own

* **`diff <(a) <(b) && echo IDENTICAL` is TRUE when BOTH files are missing.**
  The un-rename check therefore prints the byte counts of both files
  (55,363 each) alongside the verdict.
* **Every changed file was `cmp`'d into the synthesis tree before synthesis**,
  and the three variant trees were additionally checked file-by-file against
  `rtl/` to confirm that the ONLY file differing was `gdn_block.vhd` -- so a
  concurrent track's edit elsewhere in `rtl/` cannot be inside any delta here.
  `git diff --stat b1bbcb2 HEAD -- rtl/` is empty for the whole session.
* **A relocated declaration is still a changed file.** Levers 2b and 2c need
  `attribute ram_style : string;` declared before the first buffer, so it moved
  out of the 2a block to the top of the architecture. That made the shipped 2a
  and 2ab files differ from the ones first synthesised, by one line's position.
  **Both were re-synthesised** (`dr_gdn_2a_f`, `dr_gdn_2ab_f`) and reproduce
  104,180 and 90,168 exactly, on every column. The point is not the outcome, it
  is that "obviously semantically identical" is a prediction and this table only
  contains measurements.
* **GHDL work libraries do not tolerate a reused directory.** Re-running an
  equivalence into a `--workdir` left over from a FAILED analysis produced
  `entity "l2norm_rs" is obsoleted by package "util_pkg"` on eight files, which
  reads like an RTL problem and is a stale-library problem. Every run now gets
  a fresh `mktemp -d`.
* **`grep -c -F` on a multi-line needle counts lines, not occurrences.** It
  turned a valid mutation into `VOID(anchor x3)`. See section 5.
* **Machine contention is real and it is not silent.** The `_f` re-runs
  overlapped with up to nine other Vivado processes from concurrent tracks;
  elapsed time went 155 s -> 176 s and 142 s -> 141 s for identical work, so
  **the runtimes in these CSVs are not comparable and the resource numbers
  are** -- they are bit-identical across the contended and uncontended runs.
* **My own worst near-miss was `v_noguard`**, a mutation that tested nothing
  and was written to look like it tested the guard. It is reported under its
  own name in section 5 rather than replaced.
* **No `pgrep -f` or `pkill -f` was used at any point**, per the standing rule,
  and nothing was ever `rm`'d through a shell variable: every scratch directory
  is a `mktemp -d` and no script in `scripts/` deletes anything.

---

## What was NOT verified

* **`opt_design` was not run** (`LUTDIET_NOOPT=1`), for comparability with
  LUTDIET's, WRITEDEC's, READCONV's and NORMADAPT's tables. Every number here
  is post-synthesis, out of context, at 5.0 ns with no clock source
  constraint. **An OOC synthesis estimate is not an implementation result** and
  the 16,384-LUT `pb_core` margin is not a placement or routing claim.
* **C and D were not synthesised by this track.** `attn_block` = 85,816 is
  WRITEDEC's `wd_attn_after`, the sequencer leaves are WRITEDEC's `wd_seq_*`,
  and the norm adapter = 49,654 is NORMADAPT's measurement. All three are
  quoted unchanged and none was re-measured here.
* **`l2norm_rs` and `gdn_recur_pipe` were not re-verified,** because they were
  not edited. Their ports, and the cycles on which `gdn_block` drives them, are
  proven unchanged by the shadow bench, which is a stronger statement than
  "the file was not touched" but is not a statement about those units.
* **The shadow bench inherits `sim/tb_gdn_block.vhd`'s stimulus and I did not
  teeth-check that stimulus.** It runs 2 layers x 2 tokens x 2 phases at
  `KEY_HEADS`/`VAL_HEADS`/`DIM` far below the 9B shape (the bench's own
  generics), so the comparison covers 18,136 busy cycles of a small shape, not
  the shipping shape. What the SYNTHESIS measures is the shipping shape; what
  the SIMULATION measures is not.
* **Only ONE shape was simulated.** READCONV ran 8. Every mutation verdict here
  is a statement about that one shape, which is exactly the limitation READCONV
  recorded when `sat_lo` turned out to be shape-dependent.
* **No mutation was written for `qsb`'s write path or for `c_qk_swap`'s k-side
  twin**, so the table's coverage of the five buffers is uneven: `vbuf` has
  five rows, `knb`/`qsb` three, `qbuf`/`kbuf` four.
* **Nothing was placed, routed, or run on hardware.** No hardware tool was
  invoked at any point by this track.
