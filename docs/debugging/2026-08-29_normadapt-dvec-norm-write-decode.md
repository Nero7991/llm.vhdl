# Is `llama_top`'s D-vec norm adapter really 129,877 LUT of the write-decode idiom, and does removing it close `pb_core`?

**Date:** 2026-08-29
**Track:** NORMADAPT
**Baseline, pinned as its own step before `git archive`:**
`93390fdc74bd996e23ea0b3846251487ce0c9821`, extracted to
`/mnt/storage/normadapt/src`. HEAD was `61e6a12` when this track was briefed and
had already moved to `93390fd` by the time the archive was taken; `git rev-parse
HEAD` was run and captured **before** `git archive`, and
`md5sum` confirmed `rtl/llama_top.vhd` identical between the archive and the
working tree at that moment (`0d0d2f1d8a69b7d1a8b6fd7904303d37`).
**Tools:** GHDL 1.0.0 (mcode) for equivalence and mutation; Vivado 2023.2 for
area, through TRACK LUTDIET's `sim/ooc_lutdiet_run.sh` and
`sim/ooc_lutdiet_ports.tcl` **unmodified**, `xcvu33p-fsvh2104-2L-e`, 5.0 ns,
`-mode out_of_context -flatten_hierarchy none`, `LUTDIET_NOOPT=1`,
`LUTDIET_CENSUS=1`, so every number here is directly comparable to LUTDIET's,
WRITEDEC's and COMPOSE's without adjustment.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `program_hw_devices`,
nothing under `hw/fk33/host` or `hw/fk33/tcl`, nothing opening `/dev/xdma*`.
**Artefacts:** `hw/fk33/results/normadapt_2026-08-29/`

---

## 1. The question, verbatim

> TRACK WRITEDEC MEASURED that the write-decode fix takes B+C+D from 772,248 to
> **265,124 LUT** -- which fits the device with 3,098 spare but is **31,359 OVER
> `pb_core`** (233,765 free). It then found where the rest is:
>
> > **`rtl/llama_top.vhd`'s D-vec norm adapter is 129,877 CLB LUT of the same
> > idiom one level up.** `lutdiet_rms_flat` 299,030 -> 170,811; the residual is
> > `xv` 88,640 + `wv` 88,640 + `ord` 17,472 primitives.
>
> **129,877 is four times the 31,359 gap.** This is the item that plausibly
> closes the fit on its own.

---

## 2. The answer, up front

**The item is real, the fix works, and the figure in the brief was overstated by
52%. MEASURED: the D-vec norm adapter plus its `rmsnorm_rs` is 126,267 CLB LUT,
not the 170,811 the model said, and the adapter's OWN logic is 102,204, not
129,877. Rewriting the write takes the whole thing to 49,654 -- a saving of
76,613 CLB LUT, 60.7%, at identical DSP, identical BRAM, identical WNS to three
decimal places and 22 fewer flip-flops. It does NOT close `pb_core`, and the
reason it cannot is arithmetic the brief inherited: the 31,359 shortfall was
computed from a booking that never contained the adapter in the first place.**

**(a) MEASURED, the three synthesis points.** `xcvu33p-fsvh2104-2L-e`, 5.0 ns,
`-flatten_hierarchy none`, no `opt_design`, `SHAPE.hidden = 4096`,
`NORM_LANES = 4`, `NORM_W_IMAGE = ""`:

| tag | top | CLB LUT | adapter's own | `gvr.u_rms` | CLB FF | DSP | BRAM | CARRY8 | F7 | F8 | WNS | Fmax | synth s | peak RSS |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `na_before` | `ooc_normadapt_ref` | **126,267** | 102,204 | 24,063 | 133,219 | 41 | 0 | 272 | 17,984 | 8,832 | +1.675 | 300.752 | 154 | 12.50 GiB |
| `na_after` | `ooc_normadapt` | **49,654** | **25,523** | 24,131 | 133,197 | 41 | 0 | 268 | 18,208 | 8,944 | +1.675 | 300.752 | 174 | 12.50 GiB |
| `na_shift` | `ooc_normadapt_shift` | 44,293 | 20,225 | 24,068 | 133,132 | 41 | 0 | 268 | 18,064 | 8,976 | +1.675 | 300.752 | 176 | 12.10 GiB |

**-76,613 CLB LUT, -60.7% on the whole harness and -75.0% on the adapter's own
logic.** DSP does not move. BRAM does not move and stays zero. WNS does not move
at all -- `+1.675` and `300.7518796992481 MHz` are bit-identical across all
three builds. FF falls by 22, which is control, not storage: the vector is still
65,536 flops and is still exactly one copy of it.

**(b) The census names the whole delta in one row.**

    before   gvr.xv        82408 LUT   0 F7   0 F8   65536 FF
    after    gvr.xw         5425 LUT   0 F7   0 F8   65536 FF

**-76,983 LUT primitives, -93.4%, on the same 65,536 flops.** Everything else in
the census is within noise: `gvr.uw_data` (the output READ mux) 19,472 -> 20,192,
`gvr.u_rms/sq` 17,475 -> 17,475 unchanged, `gow.o` 2,875 -> 2,943. The accounted
LUT-primitive total is 127,044 against 126,267 CLB LUTs before and 50,819 against
49,654 after, a ratio of 1.006 and 1.023 -- **so on this design a LUT primitive
is a CLB LUT, and WRITEDEC's 1.336 primitives-per-CLB-LUT ratio, measured on
`gdn_block`, does not transfer here.**

**(c) It is bit-exact, and that was checked against the PRE-CHANGE RTL.**
`ooc_normadapt_equiv` compares every output of the two adapters on every rising
edge by name -- handshake, region read port, region write port, observation taps
-- at six shapes, **54 of 54 trials non-degenerate**, `PASS`, `nfail = 0`.
Eleven of thirteen mutations are killed, nine of them by this bench and two by
GHDL's own bounds check; the two survivors are the no-op control and one
measured blind spot, both reported under their own names in section 6.3.

**(d) The composition, MEASURED, replacing WRITEDEC's modelled D_norm.**

| booking | B | C | D_seq | D_norm | total | vs 268,222 free (device) | vs 233,765 free (`pb_core`) |
|---|---:|---:|---:|---:|---:|---|---|
| optimistic (COMPOSE's), no adapter at all | 131,760 | 85,816 | 6,614 | 40,934 | 265,124 | FITS, 3,098 spare | OVER by 31,359 |
| realistic, WRITEDEC's MODEL of the adapter | 131,760 | 85,816 | 6,614 | 170,811 | 395,001 | OVER by 126,779 | OVER by 161,236 |
| realistic, MEASURED, before this change | 131,760 | 85,816 | 6,614 | **126,267** | **350,457** | OVER by 82,235 | OVER by 116,692 |
| realistic, MEASURED, **after this change** | 131,760 | 85,816 | 6,614 | **49,654** | **273,844** | **OVER by 5,622 (1.02x)** | **OVER by 40,079 (1.17x)** |

**(e) So the honest verdict, and it is not the one the brief expected.** This is
the largest single reduction still available in B+C+D and it does not close
`pb_core`. What it DOES do is close the gap between the two bookings the project
has been quoting: the realistic composition was 129,877 LUT worse than the
optimistic one on the model and 85,333 worse on the measurement, and it is now
**8,720 worse**. That residual has an exact account:

    adapter's own logic, after            25,523
    less rmsnorm_rs cheaper in context    -16,803   (40,934 standalone -> 24,131 here)
    ------------------------------------------------
    difference against the optimistic booking  8,720

The 16,803 is not an accounting trick: with `NORM_W_IMAGE` empty, `NW_N = 1`,
`wsel` is a constant, and Vivado folds it through the instance boundary, so
`w_mant`'s read mux (17,916 LUT standalone) collapses to 480. **That is also
exactly why the model overstated the adapter -- see section 3.**

**Which means the `pb_core` shortfall is still 31,359 on the optimistic booking
and this change did not touch it.** The brief's framing -- "129,877 is four
times the 31,359 gap, this is the item that plausibly closes the fit on its
own" -- compares an item against a gap computed from a total that never
contained that item. Removing it cannot reduce that gap. **The lever that closes
`pb_core` is still TRACK READCONV's read conversion, exactly as WRITEDEC's
section 8.2 said.**

---

## 3. Corrections to the brief and to WRITEDEC, under their own heading

### 3.1 Corrections to WRITEDEC

| WRITEDEC claim | verdict |
|---|---|
| "`rtl/llama_top.vhd`'s D-vec norm adapter is **129,877 CLB LUT** of the same idiom one level up" | **CORRECTED. MEASURED 102,204** for the adapter's own logic, 27,673 lower; and 126,267 rather than 170,811 for the adapter plus its `rmsnorm_rs`, 44,544 lower. The figure came from `lutdiet_rms_flat`, a hand-written model, and the model is not the shipping adapter |
| "the residual is `xv` 88,640 + `wv` 88,640 + `ord` 17,472 primitives" | **`wv` DOES NOT EXIST IN `llama_top`.** MEASURED: there is no `wv` root in the census of the extracted adapter at all. `lutdiet_rms_flat` streams the gain in word by word into a written register; `llama_top` drives `w_mant` from `NW_TBL(nidx)`, and with `NORM_W_IMAGE` empty `NW_N = 1`, so `wsel` is an elaboration-time CONSTANT. `xv` MEASURED 82,408, not 88,640; `ord` appears as `gvr.uw_data` at 19,472, not 17,472 |
| the same model's `ord` at 17,472 LUT / 8,736 F7 / 4,368 F8 | **CLOSE, and the small difference is real work the model does not do.** In `llama_top` that mux feeds a REGISTERED `uw_data` under a write enable, so it is 19,472 / 9,280 / 4,480 |
| the write decode carries ZERO MUXF7 and ZERO MUXF8 | **CONFIRMED, on a fourth module.** `gvr.xv` is 82,408 LUT with 0 F7 and 0 F8 before, `gvr.xw` 5,425 with 0 F7 and 0 F8 after. All 17,984 F7 and 8,832 F8 in the before build belong to the two READ muxes (`gvr.uw_data` + `sq`), and they sum to exactly the reported totals |
| WRITEDEC's own numbers for `rmsnorm_rs` (40,934), `gdn_block` (131,760), `attn_block` (85,816), `D_seq` (6,614) | **NOT re-measured here.** They are used verbatim in the composition table and this track adds no independent evidence for them |

### 3.2 Corrections to the brief

| brief claim | verdict |
|---|---|
| "129,877 is four times the 31,359 gap. This is the item that plausibly closes the fit on its own." | **WRONG, and the error is structural rather than numerical.** The 31,359 comes from the OPTIMISTIC booking, whose `D_norm` is the bare `rmsnorm_rs` with **no adapter storage at all**. The adapter is not in that total, so removing its cost cannot reduce that shortfall by one LUT. Against the REALISTIC booking, which does contain it, this change is worth 76,613 and still leaves 40,079 over `pb_core` |
| "the residual is `xv` 88,640 + `wv` 88,640 + `ord` 17,472" | correctly quoted from WRITEDEC; **`wv` is not in the shipping design.** See 3.1 |
| "Use WRITEDEC's form, NOT LUTDIET's ... copy its form" | **followed in substance, not in letter, and the letter would not have worked.** WRITEDEC's form is a per-word generate whose enable is a combinational function of `state`, `v3` and `idx3` -- all SIGNALS in `rmsnorm_rs`. In this adapter the equivalents (`st`, `k`) are process VARIABLES, invisible outside the process, so that form is only reachable by promoting them to signals or by predicting the write address one cycle early. Both are control changes. The landed form changes no control at all and gets 93.4% off the same root |
| "A per-word generate whose slice bounds contain a for-loop variable ... simulates as X while synthesising cleanly. Simulate every generate you write." | **CONFIRMED as the right instruction and NOT hit.** The generate here indexes on the GENERATE index, which is constant per generated statement; every one of the 54 equivalence trials ran on it and none produced a metavalue. The trap is recorded in the RTL comment so the next edit does not reintroduce it |
| "`rmsnorm_rs` has a SILENT ALL-ZEROS RAIL ... Assert non-triviality on every trial" | **CONFIRMED, and it fired twice for real.** See section 8.4 |
| "TRACK READCONV ... owns `rtl/rmsnorm_rs.vhd`. Pin your baseline to a sha" | done; `rmsnorm_rs` was neither read from the working tree nor edited. Every measurement uses the pinned copy, so a `rmsnorm_rs` that changes under READCONV changes none of these numbers |

---

## 4. The procedure, and what each step isolates

1. **Pin the sha as its own step, then `git archive`, then `md5sum` the one
   file that matters.** HEAD moved from `61e6a12` to `93390fd` between the
   brief being written and the archive being taken.
2. **Extract the adapter MECHANICALLY, not by hand.**
   `sim/ooc_normadapt_extract.py` copies `llama_top`'s `gvr` generate block
   VERBATIM between two content anchors and wraps it in an entity that declares
   every enclosing-scope name the block reads, with the same name and the same
   type. It is run against BOTH trees, so the diff between the two generated
   harnesses IS the diff between the two `llama_top.vhd` files restricted to
   that block. It aborts unless each anchor matches exactly once and the
   `generate`/`end generate` count inside the extracted range balances.
   *What this isolates:* it removes the possibility that the before/after
   comparison is really a comparison of two hand-written models. TRACK LUTDIET's
   `lutdiet_rms_flat` is a hand-written model, and section 3 shows it differs
   from the shipping adapter in a way that matters.
3. **Build the oracle against the PRE-CHANGE RTL**, never against the new code
   compared with itself. `ooc_normadapt_ref` is the pinned block; nothing about
   it is retyped.
4. **Compare every OUTPUT on every rising edge, by name** -- not the emitted
   vector, and not a verdict. `done` is what `llama_top` and the pinned `seq`
   landmarks wait on; LUTDIET's `hotw` variant of this same fix moved `done` by
   one cycle and its own summary did not say so. A vector-only oracle passes
   that.
5. **Assert non-triviality on EVERY trial, as a hard failure.** `rmsnorm_rs`
   has a silent all-zeros rail and two all-zero vectors compare equal.
6. **Cover the index corners the generate creates**, at six shapes including
   `NB = 1` (N=8 LANES=8) and `LANES = 1`, plus a reset taken mid-operation and
   a correct operation after it.
7. **Teeth-check, and classify a mutant's death by WHAT killed it.** A mutant
   killed by GHDL's array-bounds check or by an assert inside `rmsnorm_rs` is
   dead but says nothing about this bench's resolution, and neither bound
   exists in synthesis. Three outcomes, not two.
8. **Simulate every generate.** A per-word generate whose slice bounds carry a
   for-LOOP variable drives the whole signal from every process and simulates as
   `X` while synthesising cleanly.
9. **`cmp` every file into the synthesis tree before synthesising it.**
10. **One Vivado at a time.** Another track was synthesising throughout; the
    runner blocks on `ps -eo comm | grep -cx vivado` before each point.

---

## 5. The change, in one paragraph

`rtl/llama_top.vhd`'s D-vec norm adapter staged the incoming vector in a flat
`std_logic_vector(NN*MANT_W-1 downto 0)` and wrote it with a RUNTIME slice,
`xv((k-1)*MANT_W-1 downto (k-2)*MANT_W) <= el_rdata`, where `k` is the read
pass's process variable. The same bits are now held as
`type xw_t is array (0 to NN-1) of std_logic_vector(MANT_W-1 downto 0)`, the
write target is the whole word `xw(k-2)`, and a concurrent generate rebuilds the
flat view `rmsnorm_rs`'s `x_mant` port needs:
`gxflat : for i in 0 to NN-1 generate xv((i+1)*MANT_W-1 downto i*MANT_W) <= xw(i);`
**No control logic moves.** The write happens on the same edges, under the same
condition, with the same data and the same index; the FSM, the `ssq`
accumulation, the `nidx` sequencing and every handshake are untouched. The slice
bounds in `gxflat` are the GENERATE index, which is a constant inside each
generated statement, so each bit of `xv` has exactly one driver -- this is the
form that avoids the whole-signal-driver trap, not the form that hits it.

---

## 6. The evidence, as raw output

### 6.1 The three result CSVs, verbatim

    target,gen,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,synth_lut,synth_ff,synth_dsp,synth_bram
    ooc_normadapt_ref,"",41,126267,126267,0,133219,0,0,0,0,272,17984,8832,1.675,300.7518796992481,154,-1,126267,133219,41,0
    ooc_normadapt,"",41,49654,49654,0,133197,0,0,0,0,268,18208,8944,1.675,300.7518796992481,174,-1,49654,133197,41,0
    ooc_normadapt_shift,"",41,44293,44293,0,133132,0,0,0,0,268,18064,8976,1.675,300.7518796992481,176,-1,44293,133132,41,0

### 6.2 The hierarchical split, which is a stronger attribution than subtracting a standalone number

    | ooc_normadapt_ref     |      (top) |     126267 | ... | 133219 | ... |  41 |
    |   (ooc_normadapt_ref) |      (top) |     102204 | ... |  66028 | ... |   1 |
    |   gvr.u_rms           | rmsnorm_rs |      24063 | ... |  67191 | ... |  40 |

    | ooc_normadapt         |      (top) |      49654 | ... | 133197 | ... |  41 |
    |   (ooc_normadapt)     |      (top) |      25523 | ... |  66006 | ... |   1 |
    |   gvr.u_rms           | rmsnorm_rs |      24131 | ... |  67191 | ... |  40 |

The one DSP outside `u_rms` is the adapter's own `sqp := el_rdata * el_rdata`,
which is a useful sanity check that the harness really carries the adapter and
not a stub. **`gvr.u_rms` is 24,063 here against 40,934 standalone**, because
`w_mant` is a constant in this configuration and Vivado propagates it across the
preserved boundary; that gap is the whole reason the model overstated the cost.

### 6.3 The census, before and after

Before (`census_na_before.txt`):

    root                                     LUT   MUXF7   MUXF8       FF  CARRY8  example_cell
    gvr.xv                                 82408       0       0    65536       4  gvr.xv[65535]_i_10
    gvr.uw_data                            19472    9280    4480       16       0  gvr.uw_data[5][0]_i_11
    sq                                     17475    8704    4352        0       0  gvr.u_rms/sq_reg[1]_i_19
    gow.o                                   2875       0       0        0       0  gvr.u_rms/gow[1018].o_reg[65215]_i_1
    max_raw                                 1046       0       0       63      56  gvr.u_rms/max_raw[15]_i_11
    ARG                                      480       0       0        0      11  gvr.u_rms/ARG__11_i_7
    # LUT primitives accounted: 127044 of 127044

After (`census_na_after.txt`):

    root                                     LUT   MUXF7   MUXF8       FF  CARRY8  example_cell
    gvr.uw_data                            20192    9504    4592       16       0  gvr.uw_data[5][0]_i_26
    sq                                     17475    8704    4352        0       0  gvr.u_rms/sq_reg[1]_i_19
    gvr.xw                                  5425       0       0    65536       0  gvr.xw[1026][15]_i_4
    gow.o                                   2943       0       0        0       0  gvr.u_rms/gow[1018].o_reg[65215]_i_1
    max_raw                                 1046       0       0       63      56  gvr.u_rms/max_raw[15]_i_11
    ARG                                      480       0       0        0      11  gvr.u_rms/ARG__11_i_7
    # LUT primitives accounted: 50819 of 50819

`ARG` at **480** is the measurement that kills `wv`: standalone it is 17,916,
and here the gain fetch has no mux left because the gain is a constant.

### 6.4 The equivalence, six shapes, 54 non-degenerate trials

    NORMADAPT_EQUIV PASS NN=64  LANES=4 Q=12 cycles=2245
    NORMADAPT_EQUIV PASS NN=8   LANES=8 Q=12 cycles=787
    NORMADAPT_EQUIV PASS NN=16  LANES=1 Q=12 cycles=1381
    NORMADAPT_EQUIV PASS NN=128 LANES=4 Q=12 cycles=3877
    NORMADAPT_EQUIV PASS NN=32  LANES=2 Q=12 cycles=1669
    NORMADAPT_EQUIV PASS NN=256 LANES=8 Q=12 cycles=6181

Nine trials per shape, each one printing its own non-degeneracy count, e.g.

    trial cls=0 xe=0 nonzero=64 distinct=63 y_exp=14
    trial cls=2 xe=0 nonzero=62 distinct=63 y_exp=14
    trial cls=3 xe=0 nonzero=64 distinct=63 y_exp=12

`nonzero` and `distinct` are counted over the emitted vector; a zero in either
is a `severity failure`, not a note. Full log: `equiv.txt`.

### 6.5 The mutations, with what killed each one

    m_none               SURVIVED
    m_off1               CAUGHT-RTL     (index (64) out of bounds)
    m_wr_rot             CAUGHT-BENCH   (MISMATCH uw addr/reg/data at addr )
    m_flat_rev           CAUGHT-BENCH   (MISMATCH uw addr/reg/data at addr )
    m_flat_drop0         CAUGHT-RTL     (rmsnorm_rs: sum of squares out of the assumed range)
    m_flat_rot           CAUGHT-BENCH   (MISMATCH uw addr/reg/data at addr )
    m_firstdrop          CAUGHT-BENCH   (MISMATCH obs_norm payload)
    m_zerodata           CAUGHT-BENCH   (MISMATCH uw addr/reg/data at addr )
    m_extracycle         CAUGHT-BENCH   (MISMATCH obs_pub ref)
    m_uwaddr             CAUGHT-BENCH   (MISMATCH uw addr/reg/data at addr )
    m_uwreg              CAUGHT-BENCH   (MISMATCH uw addr/reg/data at addr )
    m_ssq                CAUGHT-BENCH   (MISMATCH obs_norm payload)
    m_nidx_at_accept     SURVIVED

**The two SURVIVED rows, under their own names, because they are the useful ones.**

- **`m_none`** is the no-op control and MUST survive. A run in which it did not
  would mean the two harnesses differ for a reason other than the edit.
- **`m_nidx_at_accept`** advances the gain index at the ACCEPT instead of at the
  completion -- the off-by-one `rtl/llama_top.vhd`'s own comment says was the
  first version of `nsel`, and which it describes as "every seam wrong, none of
  them structurally so". **It survives, and it is right that it does:** with
  `NORM_W_IMAGE` empty there is exactly ONE gain, so which one you select cannot
  matter. This is a measured statement about this bench's coverage: **the gain
  sequencing is untested at the synthesis default and needs a `NORM_W_IMAGE`
  trial to be tested at all.** It is not evidence about `nsel`.

**`m_extracycle` is the row that shows this bench gates on the SCHEDULE.** It
extends the read pass by exactly one cycle, changes no value, and is killed on
`obs_pub` -- which is what a `done` moved by one cycle would look like, and the
failure mode LUTDIET's `hotw` form has.

### 6.6 The gate, unfiltered

`REGRESS_SCRATCH=/mnt/storage/normadapt/rg2 bash sim/regress.sh --jobs 2 --keep
--only tb_llama_top`, on the working tree carrying this change:

     OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
     REGRESSION: PASS

    sim:tb_llama_top          PASS    113
    sim:tb_llama_top_normw    PASS     79
    sim:tb_llama_top_real     PASS     76
    sim:tb_llama_top_seq      PASS    318
    sim:tb_llama_top_smp      PASS      1
    sim:tb_llama_top_smp_beh  PASS      2

(The third column is elapsed SECONDS, not a check count.) `tb_llama_top_real`
and `tb_llama_top_normw` are the two rows that set `NORM_REAL = true`, so they
are the ones that exercise the changed code at all. **An earlier run of this
same set with `--only llama_top_` reported `OVERALL PASS 5` and silently omitted
`tb_llama_top`; see section 8.2.**

### 6.7 The shift-register probe, measured and not landed

`na_shift` replaces the decoded write with a plain shift register: every write
shifts the whole array down one word and puts the new element at the top, so
after exactly `NN` writes element `i` is at `xw(i)`. It has no write decode at
all -- there is no `gvr.xw` root in its census -- and it is **44,293 LUT against
the landed 49,654, a further 5,361, 10.8%.** It passes the same equivalence at
three shapes.

**It is NOT landed, and the 5,361 is the reason it is easy to decline.** Its
correctness depends on the pass writing exactly `NN` elements in order before
anything reads `xv`, and the only thing enforcing that is
`assert n = NN ... severity failure` -- **which Vivado ignores in synthesis**,
as this file's own header records. The landed form is correct for any `n`; the
shift form turns a short vector from a partially-stale result into a rotated
one. 10.8% is not worth a correctness precondition that the synthesiser cannot
see.

---

## 7. Measured and REJECTED -- do not retry

- **LUTDIET's `hotw` form -- registering `{o_we, o_wa, o_wd}` in the FSM.** Not
  retried, on TRACK WRITEDEC's measurement: it fires `done` ONE CYCLE LATER, and
  `done` is what `llama_top` and the pinned `seq` landmarks wait on. Every
  change here is combinational in the enable and cycle-exact, and the
  equivalence bench compares `v_done` on every edge specifically so that this
  failure mode cannot pass.
- **Converting the OUTPUT read (`ord`) by the same trick.** Reading
  `ov((k+1)*MANT_W-1 downto k*MANT_W)` through an array view `ow(k)` is the SAME
  N:1 mux with a different spelling and saves nothing; LUTDIET's own hand count
  of a 16:1-per-MUXF8 tree matched `ord` exactly on all three of LUT, F7 and F8,
  which is what a mux costs. Removing it needs either a memory-backed output
  port on `rmsnorm_rs` (TRACK READCONV's territory, not this file's) or a second
  65,536-flop shift-out register in the adapter. **DERIVED, not measured** --
  this track did not synthesise an array-view variant.
- **Growing the stimulus into the all-zeros rail.** Deliberately excluded: two
  all-zero vectors compare equal, so a trial on the rail cannot distinguish
  anything. Behaviour ON the rail is therefore uncompared, and that is a
  coverage statement, not a claim that it is safe.

---

## 8. Measurement traps hit, including this track's own

### 8.1 Another track's full gate has been deadlocked on its own command line

**MEASURED, and it is not mine to fix, so it is recorded here.** pid 741564:

    bash -c while pgrep -f "regress.sh --only llama_top" >/dev/null; do sleep 20; done; \
      REGRESS_SCRATCH=/mnt/storage/writedec/rg_full timeout 14400 bash sim/regress.sh --jobs 2 \
      > /mnt/storage/writedec/full_gate.log 2>&1; echo "FULLGATE rc=$?" >> ...

`pgrep -f` matches against the whole command line, and **that string is IN this
process's own command line**, so the guard matches the guard. It had been in the
loop for **3,803 seconds** when this track first looked, and `sim/regress.sh`
had never been started. Verified without reproducing the bug, by splitting the
pattern across a shell concatenation so this track's own command line could not
contain it:

    PAT="regress.sh --only lla""ma_top"; pgrep -af "$PAT"
    741564 bash -c while pgrep -f "regress.sh --only llama_top" >/dev/null; do sleep 20; ...

**One hit, and it is itself.** So TRACK WRITEDEC's queued full gate will never
run, and anyone waiting on `/mnt/storage/writedec/full_gate.log` is waiting on
nothing. This is the project's `pgrep -f` self-match rule -- already written
down because it has killed the shell four times -- appearing in its quiet form:
it does not kill anything, it just never fires.

### 8.2 `--only llama_top_` silently drops `tb_llama_top`

`--only` is a SUBSTRING. `llama_top_` matches the five `tb_llama_top_*` rows and
NOT `tb_llama_top`, which is the row with 45 asserts. The first gate run here
printed `OVERALL PASS 5 FAIL 0`, which is a true statement about five rows and
reads like a statement about six. Re-run with `--only tb_llama_top`.

### 8.3 "Wait for zero Vivado" livelocks against a track running short points

The first version of `sim/ooc_normadapt/run_synth.sh` blocked until
`ps -eo comm | grep -cx vivado` was 0, polling every 60 s. Another track then ran
six small probe points back to back, and the gap between two of its runs is
shorter than the poll interval, so the wait sat through all of them without ever
seeing a gap. Replaced with a 5 s poll plus a bounded patience that falls back to
a MEMORY rule -- available RAM and no Vivado above 4 GiB resident -- because OOM
is what the one-at-a-time rule exists to prevent. In the event the fallback was
never used: a genuine gap appeared and the run started in it.

### 8.4 The non-triviality assert fired TWICE, for real

Not a formality. Two stimulus choices that looked reasonable put `rmsnorm_rs` on
its silent all-zeros rail and were caught as bench failures rather than passing:

    DEGENERATE TRIAL cls=1 xe=0 nonzero=0 distinct-from-elem0=0
    DEGENERATE TRIAL cls=4 xe=-4 nonzero=0 distinct-from-elem0=0

The first is an element class near the int16 rail; the SECOND is the same class
that passes at `xe = 0` failing at `xe = -4`, which also corrects a piece of
reasoning this track had already written down: the rail is on `rms(x_real)`, so
`x_exp` DOES move it, even though `o_exp` is a function of the shape of x and
not of its scale. Retuned to **54 of 54 non-degenerate** across six shapes.

### 8.5 Two mutants were killed by GHDL, not by this bench

`m_off1` (write `xw(k-1)`) dies on `index (64) out of bounds`, and
`m_flat_drop0` (leave element 0 undriven) dies on `rmsnorm_rs: sum of squares
out of the assumed range` -- the DESIGN's assert, reached through a metavalue.
Both are dead, neither is evidence about this bench's resolution, and **neither
bound exists in synthesis.** A two-outcome classifier would have booked them as
teeth. The runner now reports `CAUGHT-BENCH` and `CAUGHT-RTL` separately, and
`m_wr_rot` was added as an in-bounds write-index error so the bench's own
resolution on that failure mode is measured rather than assumed. It kills it.

### 8.6 A duplicate entity name in one GHDL library is not a duplicate error

Analysing a second copy of the harness under the same entity name into the same
`--workdir` produced `architecture "tb" of "ooc_normadapt_equiv" is obsoleted by
entity "ooc_normadapt"`, which reads like a stale-build problem rather than what
it is. The fix is a clean work directory per comparison, and this script now
rebuilds one.

### 8.7 The extraction is anchored on CONTENT, because the line numbers moved

The `gvr` block was `llama_top.vhd:1801..2146` before this change and
`1801..2181` after it, in the same hour, by this track's own edit. Line numbers
in this file have been unstable all day; every anchor here is a full line of
text and the extractor aborts unless it matches exactly once.

---

## 9. What was NOT verified

**Nothing here is placed or routed.** Every caveat in
`sim/ooc_compose_bcd.tcl`'s header stands: no inter-subsystem routing, no
placement, no shell, no cross-subsystem resource merging. An OOC synthesis sum
is not a routability result, and a pblock is a floorplan constraint rather than
a device.

**The adapter is behind a generic that DEFAULTS FALSE.** `rtl/llama_top.vhd:351`
is `NORM_REAL : boolean := false`, so the `gvr` block is not elaborated at all
at `llama_top`'s defaults -- which is what `sim/ooc_compose_bcd.tcl`
(`set GEN(llama_top) {}`) synthesises. Every number in this file is for the
`NORM_REAL = true` configuration, which is the one a build that actually
normalises must use. Whatever the `NORM_REAL = false` behavioural stub at
`llama_top:1524` costs -- it stages the same vector in a `buf_t(0 to REGMAX-1)`
process variable at `REGMAX = region_max(SHAPE) = 12,288` -- is unmeasured here.

**`NORM_W_IMAGE` is empty in every measurement here, and that is not a corner.**
With it empty, `NW_N = 1`, `NW_TBL` is a single constant and `wsel` folds to a
constant, which is why `w_mant`'s read mux is 480 LUT rather than the ~17,900 it
measures standalone. With a REAL gain image at 9B, `NW_TBL` becomes an
`NW_N x 4096 x 16`-bit elaboration-time constant with an `NW_N`-way 65,536-bit
mux on `wsel`; at 32 blocks that is 65 entries and **4.26 Mbit of constant plus a
65:1 mux of 65,536 bits, entirely unmeasured.** ESTIMATE, stated because the
number is large enough to matter: that is potentially a bigger item than the one
this track just removed, and it is invisible in the configuration everyone has
been synthesising.

**The equivalence runs at `hidden` 8 to 256, never at 4096.** The generate's
structure is identical at every N and the corners it creates (index 0, index
N-1, `NB = 1`, `LANES = 1`) are covered, but the 9B shape itself is synthesised
and never simulated. This is the same boundary every other track here has.

**What the stimulus cannot reach, enumerated rather than assumed:**

- `n /= NN`. The adapter asserts on it and the schedule never issues it, so the
  refusal path is uncovered. Note Vivado ignores `severity failure`.
- `NW_N > 1`. The gain-index sequencing (`nsel`, `nidx`, `novf`) is therefore
  uncovered, which is exactly why **`m_nidx_at_accept` SURVIVES**: moving the
  index advance from the completion to the accept -- the off-by-one the RTL's
  own comment says was the first version -- changes nothing when there is one
  gain. That is a measured blind spot of this bench, not a property of the RTL.
- `rmsnorm_rs`'s emit saturation. TRACK WRITEDEC found no trial reaches it;
  none here does either.
- The all-zeros rail itself, deliberately (see section 7).
- `v_err`, which this branch ties to `'0'` unconditionally.

**The `ord` read mux is not fixed and not measured as fixable here.** It is
19,472 LUT / 9,280 F7 / 4,480 F8 in the before build and essentially unchanged
after, and it is now the adapter's largest remaining item.

**The full gate was not run.** Five `tb_llama_top_*` rows and then all six
`tb_llama_top*` rows were run targeted; no other row was. The one full-gate run
queued on this box has been deadlocked since before this track started (section
8.1), so there is no current full-gate number for anyone to compare against.
