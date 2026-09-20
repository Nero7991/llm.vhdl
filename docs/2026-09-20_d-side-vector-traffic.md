# D moves 5.15 M elements a token one at a time, past a port that already carries eight

Date: 2026-09-20. TRACK DSIDE. Tree at `8771f32` plus this track's two new
files. Card numbers are read from
`hw/fk33/results/card_swg_2026-09-20/profile/profile_{flat,striped}_tok0.txt`
(FK33 at 75 MHz, bitstream `fk33_card_swg_75mhz_2026-09-20.bit`). **NO
HARDWARE was touched by this track**; every number that is not in that
profile is GHDL (mcode) or arithmetic over `tools/gen_layer_program.py`'s
own step plan.

---

## 1. The question, verbatim

> Two independent measurements converged on subsystem D's own cycles, not on
> the compute units. [...] Together that is about 4.9 M of the 30.1 M-cycle
> lane-striped token, 16%, and it is all one mechanism: D moves scalars one
> element per cycle over an 8-bit-wide-ish local path while the memories
> either side are far wider. YOUR JOB is to scope it properly and prove the
> numbers before anyone writes RTL.

## 2. The answer

**MEASURED, 5,153,058 cycles of the 30,115,280-cycle lane-striped token
(17.11%) and of the 61,907,159-cycle flat token (8.32%) are moves through
`rtl/llama_top.vhd`'s ONE-ELEMENT-WIDE region-file port, and the region file
already has an EIGHT-ELEMENT-WIDE port beside it with exactly one client.**

The mechanism is not a narrow memory and not a handshake. The region file
(`rtl/llama_top.vhd:1334-1389`) publishes **four** ports:

| port | width | clients today |
|---|---|---|
| element read `ur_en`/`ur_reg`/`ur_addr` -> `el_rdata` | **1** x 16 bit | A, B, C, and both D-vec adapters |
| element write `uw_en`/`uw_reg`/`uw_addr`/`uw_data` | **1** x 16 bit | the same five |
| group read `r_en`/`r_addr` -> `x_rdata`, `e_rdata` | **LANES = 8** x 16 bit, **TWO operand regions at once** | `seq_vec_res` only |
| group write `w_we`/`w_addr`/`w_be`/`w_data` | **LANES = 8** x 16 bit, per-lane enables | `seq_vec_res` only |

**The on-card control is in the profile and needs no new measurement.** At
the SAME vector length, N = 4,096, through the SAME region file:

```
VEC_RES  (group port)    1,058 cycles  = 0.258 cycles per element
VEC_NORM (element port) 11,336 cycles  = 2.768 cycles per element
```

`seq_vec_res` reads TWO operand regions and writes one, and still costs
**10.7x less per element** than a norm that reads one and writes one. Nothing
about the narrow path is forced by the memory; it is forced by which port the
adapter was wired to.

**The cheapest lever, proved in simulation today, is unit A's `S_DRAIN`:**
the source (`ybw`) is ALREADY 48 mantissas wide and the sink (the group write
port) is ALREADY 8 wide, so the change is confined to `rtl/llama_top.vhd` and
touches no other module's interface. MEASURED in `sim/tb_region_drain.vhd`:
`n + 2` cycles becomes `ceil(n/8) + 2`, values identical against an
independent model at twelve shapes. **DERIVED over the token: 1,426,944 ->
178,368, a saving of 1,248,576 cycles, 4.15% of the striped token and 2.02%
of the flat one.**

---

## 3. The mechanism, with line numbers and quoted RTL

### 3.1 Unit A, `S_XRD`: one element per cycle IN (`llama_top.vhd:4286-4301`)

```vhdl
            when S_XRD =>
              if k < j_cols then
                ur_en(U_A)   <= '1';
                ur_reg(U_A)  <= j_src;
                ur_addr(U_A) <= k;
              end if;
              if k >= 2 then
                x_we    <= '1';
                x_waddr <= std_logic_vector(to_unsigned(k-2, 16));
                x_wdata <= std_logic_vector(el_rdata);
              end if;
              if k = j_cols+1 then
                k := 0;
                st := S_EXP;
```

`K + 2` cycles per job: `K` element reads plus the two-edge read latency the
region file's header pins (`llama_top.vhd:1344-1351`). **Why one per cycle:
the SINK.** `x_wdata` is `matvec_int4`'s x bank write port and it is
`std_logic_vector(MANT_W-1 downto 0)` -- 16 bits, one word
(`llama_top.vhd:4151` port map, `rtl/matvec_int4.vhd` entity). Widening this
is a change to subsystem A's core, not to D.

### 3.2 Unit A, `S_DRAIN`: one element per cycle OUT (`llama_top.vhd:4394-4413`)

```vhdl
            when S_DRAIN =>
              if r = 0 then rword := 0; rlane := 0; end if;
              uw_en(U_A)   <= '1';
              uw_reg(U_A)  <= j_dst;
              uw_addr(U_A) <= j_off + r;
              uw_data(U_A) <=
                signed(ybw(rword)((rlane+1)*MANT_W-1 downto rlane*MANT_W));
              if rlane = A_ROWS_IF-1 then
                rlane := 0;
                if rword /= A_YWORDS-1 then rword := rword + 1; end if;
              else
                rlane := rlane + 1;
              end if;
              if r = j_rows-1 then st := S_DONE; else r := r + 1; end if;
```

`M` cycles per job whose `j_dst < NREGION`. **Why one per cycle: NOTHING.**
The source is

```vhdl
    type ybw_t is array (0 to A_YWORDS-1)
      of std_logic_vector(A_ROWS_IF*MANT_W-1 downto 0);     -- :4124-4126
```

that is **48 mantissas per word**, and `rlane` is already indexing inside one
such word. The sink could be the group write port, which `memp` serves at
`llama_top.vhd:1688-1699` with per-lane `w_be`. The adapter uses the narrow
port because it was written before the group port had a second client -- the
region-file header says so outright (`llama_top.vhd:1355-1360`: *"subsystem D
issues at most one unit at a time [...] When D grows overlap, this becomes a
real arbiter and this comment becomes wrong"*).

### 3.3 The D-vec adapters `gsr` and `gvr`

`gsr` (SwiGLU, `llama_top.vhd:3574-3765`) runs **TWO serial read passes** over
the element port, one for G and one for U (`:3690-3720`), then one serial
write-back pass (`:3745-3757`). `gvr` (`:2282`, body `nproc` at `:3354-3530`)
runs one read pass and one write-back pass; its gain vector is preloaded from
the previous op, which is why it is `2N`, not `3N`.

```vhdl
              when S_RD =>                       -- gsr, :3690
                if k < n then
                  ur_en(NUNIT+vi)   <= '1';
                  ur_reg(NUNIT+vi)  <= to_integer(unsigned(v_reg_a(6 downto 0)))
                                  when pass = 0
                                  else to_integer(unsigned(v_reg_b(6 downto 0)));
                  ur_addr(NUNIT+vi) <= k;
                end if;
```

**The two passes are the tell.** The group READ port takes ONE address and
returns LANES words of `v_reg_a` AND LANES words of `v_reg_b` in the same
cycle (`llama_top.vhd:1706-1723`). G and U are `v_reg_a` and `v_reg_b`. The
SwiGLU's entire load is one pass of `N/8` cycles on a port that exists, and
it is being done as two passes of `N` on a port that does not have to be used.

**Why one per cycle here: the SINK again**, but a much smaller one --
`swiglu_mem`'s `g_wdata`/`u_wdata` are `std_logic_vector(15 downto 0)` and
`o_rdata` is 16 bits (`rtl/swiglu_mem.vhd:132-157`), even at TRACK SWGFAST's
`LANES = 4`, where the banks behind those ports are already LANES-way.

### 3.4 B and C read the same way

`bp` prefetches R_QKV, R_BETA, R_ALPHA and R_Z one element per cycle
(`llama_top.vhd:5380-5470`) and drains `VH*DM` the same way (`:5602-5607`);
`cp` prefetches R_QG, R_KIN, R_VIN and drains (`:6583-6660`). DERIVED
394,944 cycles for B's 24 jobs and 81,968 for C's 8. Same mechanism, 1.58% of
the striped token, and NOT the reason B costs 660 k a job.

---

## 4. The reconciliation, both totals, against measured steps

### 4.1 `A_JOB`: the ACLK figure is confirmed to the cycle, and refined

TRACK ACLK's section 7 DERIVED `sum(K+2) = 1,536,622` and
`sum(M) = 1,426,944` from the manifest shapes and called the sum 27.2% of the
striped `A_JOB` total, **without reconciling it against a measured step**.
That reconciliation is done here.

**The model**, read off the FSM at `llama_top.vhd:4276-4419` and nothing else:

```
step = 16       S_CB      (cb_int4, k = 0..15, EVERY job)
     +  1       S_CBGAP
     + (K + 2)  S_XRD
     +  1       S_EXP
     +  1       S_GO
     + engine   S_RUN
     + M        S_DRAIN   (only when j_dst < NREGION)
     +  1       S_DONE
```

so `card_side = K + M + 21` for a job with a region destination and
`K + 21` for an lm_head window. Fitting the remainder against the beat count
`ceil(M/48) * ceil(K/32)` over all 311 unfolded `A_JOB` steps of the striped
profile:

```
fit  engine = 294.07 + 1.51010 * beats        n = 311
residual mean -0.0, sd 51.5, min -197, max +81   (0.147% of the mean step)
sum card-side 2,969,786 (27.26% of A_JOB)   sum engine 7,924,852
```

**MEASURED per-shape table** (the profile's own durations, grouped by the
plan's shapes):

| M | K | drains | n | mean dur | card-side | mean engine | beats | cycles/beat |
|---:|---:|---|---:|---:|---:|---:|---:|---:|
| 4096 | 4096 | yes | 80 | 25,111.5 | 8,214 | 16,897.5 | 11,008 | 1.5350 |
| 12288 | 4096 | yes | 64 | 66,245.4 | 16,406 | 49,839.4 | 32,768 | 1.5210 |
| 2048 | 4096 | yes | 48 | 14,767.2 | 6,166 | 8,601.2 | 5,504 | 1.5627 |
| 32 | 4096 | yes | 48 | 4,642.4 | 4,150 | 492.4 | 128 | 3.8468 |
| 4096 | 12288 | yes | 32 | 66,582.0 | 16,406 | 50,176.0 | 33,024 | 1.5194 |
| 1024 | 4096 | yes | 16 | 9,686.4 | 5,142 | 4,544.4 | 2,816 | 1.6138 |
| **17376** | 4096 | **no** | 14 | 74,194.6 | **4,118** | 70,076.6 | 46,336 | 1.5124 |
| 8192 | 4096 | yes | 8 | 45,656.4 | 12,310 | 33,346.4 | 21,888 | 1.5235 |
| **5056** | 4096 | **no** | 1 | 24,771.0 | **4,118** | 20,653.0 | 13,568 | 1.5222 |

`sum(K+2) + sum(M drained) = 1,536,622 + 1,426,944 = 2,963,566`, **exactly**
ACLK's number; the remaining `311 x 20 = 6,220` are the fixed states, which
ACLK's shape arithmetic could not see. So **ACLK's figure is confirmed and
was 0.21% low**, and its 27.2% becomes 27.26%.

**CONTROLS, and they are what makes the attribution admissible.** Two
deliberately wrong models, same data, same fit:

| model | max |residual| |
|---|---:|
| the model above | **197** |
| charge S_DRAIN to the lm_head windows too | 13,356 (68x worse) |
| drop the `K + 2` S_XRD term | 6,249 (32x worse) |

The lm_head rows are the sharp control: they are the only steps that do NOT
drain (`j_dst >= NREGION`, `llama_top.vhd:4391`), and charging them `M = 17,376`
moves them by 17,376 cycles, which the fit cannot absorb. **The 197-cycle
class residual on those same rows is real and is `S_SDRAIN`** (`:4386-4392`,
waiting for the sampler FIFO to empty) -- a per-class constant this model does
not carry, stated rather than absorbed.

**Is 1.51 a slope or scatter?** CLAUDE.md records two tracks that read scatter
as a slope, so: the beat counts span **362x** (128 to 46,336), the fit
parameters barely move when whole shape groups are dropped
(`F 294.1 -> 291.2 -> 291.1`, `p 1.51010 -> 1.51020 -> 1.51021`), and the
worst residual is 0.3% of the smallest step. **`p` is structural; `F` is a
mean** -- it is pinned mostly by the M = 32 rows (492.4 engine cycles for 128
beats) and is the only number here that would move on a different job mix.

### 4.2 The vector ops: SWGFAST's number confirmed, the brief's total corrected

MEASURED, striped profile: `VEC_SWG` 61,473 x 32 = 1,967,136;
`VEC_NORM` 11,336 x 65 = 736,840; `VEC_RES` 1,058 x 64 = 67,712.

The adapter share, DERIVED from the FSMs at `:3690-3757` and `:3409-3523`:

| | `gsr` (N = 12,288) | `gvr` (N = 4,096) |
|---|---:|---:|
| S_RD pass 0 | 12,290 | 4,098 |
| S_RD pass 1 | 12,290 | **none, the gain is preloaded** |
| S_WR | 12,290 | 4,098 |
| **element-port cycles** | **36,870** | **8,196** |
| unit (MEASURED by SWGFAST) | 24,588 | 3,125 |
| + S_GO | 1 | 1 |
| sum | 61,459 | 11,322 |
| card | 61,473 | 11,336 |
| residual | 14 | 14 |

**CORRECTION to the brief.** It DERIVED the norm's movement as
`65 * (3 * 4098) = 799,110`, using the SwiGLU's three passes. `gvr` has
**two**: `nproc`'s S_GO comment (`llama_top.vhd:3462-3470`) states that the
gain streams in *"from the completion of the PREVIOUS norm op"* and is
interlocked on `wbusy`, not re-read per op. The correct figure is
`65 * 8,196 = 532,740`, and the brief's "about 1,979,000 cycles of pure
vector movement" is **1,712,580**.

### 4.3 The census

| source | cycles | % striped | % flat |
|---|---:|---:|---:|
| A `S_XRD`, `sum(K+2)` | 1,536,622 | 5.10 | 2.48 |
| A `S_DRAIN`, `sum(M)` over drained jobs | 1,426,944 | 4.74 | 2.30 |
| `VEC_SWG`, `32 x 3(N+2)` | 1,179,840 | 3.92 | 1.91 |
| `VEC_NORM`, `65 x 2(N+2)` | 532,740 | 1.77 | 0.86 |
| B prefetch + drain, 24 jobs | 394,944 | 1.31 | 0.64 |
| C prefetch + drain, 8 jobs | 81,968 | 0.27 | 0.13 |
| **total element-port traffic** | **5,153,058** | **17.11** | **8.32** |
| token | 30,115,280 | | 61,907,159 |

Every row except the last two is MEASURED-backed (the profile's step
durations reconcile to it); B and C are DERIVED from their FSMs' loop bounds
and the 9B shape (`VH = 32`, `DM = 128`, `QKVN = 8192`, `QGN = 4096`,
`KVN = 1024`) and have NOT been reconciled against a measured step, because
neither `B_JOB` nor `C_JOB` has a card-side/engine split this track derived.

---

## 5. The levers, ranked

Cost is lines of RTL; "interface" means a port list another track's file owns.
Every lever is specified behind a generic defaulting to today's behaviour,
which is how BMOVER and SWGFAST both landed theirs.

| # | lever | cycles saved / token | % striped | % flat | RTL | interface moved | risk |
|---|---|---:|---:|---:|---|---|---|
| **L1** | **A `S_DRAIN` on the group write port** | **1,248,576** | **4.15** | **2.02** | `llama_top` only, ~45 lines | **none** | low: source and sink are both already wide |
| L2 | `gsr` load + store on the group ports, and `swiglu_mem` at `LANES = 8` | 1,769,472 | 5.88 | 2.86 | `llama_top` ~60 + `swiglu_mem` ~60 | `swiglu_mem` gains wide ports | medium |
| L3 | A `S_XRD` on the group read port | 1,344,000 | 4.46 | 2.17 | `llama_top` ~30 + `matvec_int4` x-bank | **subsystem A's core** | high |
| L4 | `gvr` load + store on the group ports | 465,920 | 1.55 | 0.75 | `llama_top` ~50 + `rmsnorm_bf_mem` ~50 | `rmsnorm_bf_mem` gains wide ports | medium |
| L5 | B and C prefetch/drain on the group ports | ~417,000 | 1.38 | 0.67 | `llama_top` ~120 | none | medium, four sites |

**L1 is first on every axis**: 27,700 cycles per line, no other file, and it
is the one that pays for the group-port mux that L2, L4 and L5 all need.

L2's figure is the whole `VEC_SWG` step, not only the movement: the group
ports cut `36,870 -> 3,076` and `LANES = 8` cuts SWGFAST's `24,588 -> 3,085`,
so `61,473 -> ~6,180`. **DERIVED**; SWGFAST MEASURED the unit at LANES 1/2/4
(24,588 / 12,301 / 6,157) and 8 follows its stated `2*NB + 13` law, which is
an extrapolation of one step and is labelled as such.

### Measured and REJECTED -- do not retry

- **Eliminate `S_DRAIN` entirely by writing y through during `S_RUN`.** The
  arithmetic says it is possible: a y beat arrives once per tile, i.e. every
  `1.51 * ceil(K/32)` cycles (193 cycles at K = 4096), and 48 rows at 8 lanes
  per cycle is 6. **REJECTED because the marginal gain over L1 is 178,368
  cycles, 0.59% of the striped token**, while it moves region writes inside
  the run window and puts `wcollide` (`llama_top.vhd:1667-1677`) and the
  region lock on a path they have never seen. L1 captures 87.5% of it.
- **Overlap `S_DRAIN` of job N with `S_XRD` of job N+1.** `seq_desc_fetch`'s
  `cur_unit` is a scalar and the `u_ready`/`u_start`/`u_done`/`u_ack`
  handshake admits one job at a time, so this is a sequencer change across a
  seam, not an adapter change. Best case it hides `min(1,426,944, 1,536,622)`,
  which L1 and L3 together beat for less RTL and without touching D's
  sequencer. **REJECTED on cost, not on feasibility.**
- **Widen the ELEMENT port instead of using the group port.** The element
  port is shared by five clients through `elmux` (`:1576-1593`) and its width
  is what makes the region file one write port per bank; widening it is the
  `docs/2026-09-04_region-file-for-synthesis.md` question, not a cycle
  question. The group port already exists and costs nothing.

---

## 6. What was proved in simulation, and what is a patch on paper

### 6.1 Proved: `rtl/region_drain.vhd` + `sim/tb_region_drain.vhd` (new, this track)

`region_drain` is `llama_top`'s `S_DRAIN` extracted, with the group-port
traversal beside it behind `WIDE` (default `false`). **The extraction is
honest for this state**: `S_DRAIN` reads only `ybw`, `j_dst`, `j_off`,
`j_rows` and its own three cursors, and touches nothing else in the adapter.
The one thing it CANNOT carry is stated in 6.3.

MEASURED (`ghdl-mcode`, peak RSS **664 MB**, 48 checks, `fail=0`,
`OVERALL PASS 1 FAIL 0` through `sim/regress.sh --only tb_region_drain`):

```
DSIDE_CYCLES ffn_gate_12288   narrow 12290  wide 1538   rows 12288 off 0
DSIDE_CYCLES hidden_4096      narrow  4098  wide  514   rows  4096 off 0
DSIDE_CYCLES qkv_2048_off2048 narrow  2050  wide  258   rows  2048 off 2048
DSIDE_CYCLES qkv_4096_off4096 narrow  4098  wide  514   rows  4096 off 4096
DSIDE_CYCLES ssm_beta_32      narrow    34  wide    6   rows    32 off 0
DSIDE_CYCLES kv_1024          narrow  1026  wide  130   rows  1024 off 0
DSIDE_CYCLES tail_100         narrow   102  wide   15   rows   100 off 0
DSIDE_CYCLES one_word_48      narrow    50  wide    8   rows    48 off 0
DSIDE_CYCLES cross_word_50    narrow    52  wide    9   rows    50 off 8
DSIDE_CYCLES single_1         narrow     3  wide    3   rows     1 off 0
DSIDE_CYCLES misaligned_37    narrow    39  wide   39   rows    37 off 3
DSIDE_CYCLES misaligned_64    narrow    66  wide   66   rows    64 off 4
DSIDE_CYCLES TOTAL narrow 23908 wide 3100
TB_REGION_DRAIN checks=48 fail=0
TB_REGION_DRAIN PASS
```

`narrow = n + 2` and `wide = ceil(n/8) + 2`; the `+2` is the bench's own
start/done framing and is the SAME on both arms, so the state itself is `n`
against `ceil(n/8)`, which is what `llama_top` would see. The two
`misaligned_*` rows are equal by design: `off mod LANES /= 0` has no group
address, so `WIDE = true` falls back to the narrow body and
`o_wide_used = '0'`, asserted rather than inferred.

**The values check is an independent model, not a round trip.** Both region
files are compared element by element **over the whole 49,152-word address
space** against `expect(reg, off+i) = ybw(i / 48) lane (i mod 48)`, built in
the bench from the descriptor alone, with a POISON prefill so an element the
drain did not write is a mismatch rather than a lucky zero.

### 6.2 The mutation table (MEASURED, `region_drain.vhd` mutated in the scratchpad only)

FULL = the shipping bench. RT = the attribution control: the same bench with
the independent model replaced by `exp := mem_n(a)`, i.e. narrow-versus-wide
and nothing else.

| mutant | FULL | RT | cases hit | what |
|---|---|---|---|---|
| C0_control | SURVIVES | SURVIVES | -- | unmutated |
| W1_no_be_tail | BITE (3) | BITE | `tail_100`, `cross_word_50`, `single_1` | `w_be` set for `r+i <= n`: one lane past the vector |
| W2_addr_no_off | BITE (3) | BITE | both `qkv_*`, `cross_word_50` | group address `r/LANES`, dropping `dst_off` |
| W3_lane_skew | **BITE (range error)** | -- | -- | lane slice `+1`: dies on `yb_rdata` bounds, not on a value |
| W4_no_fallback | BITE (4) | BITE | both `misaligned_*` | the alignment fallback removed |
| W5_word_early | BITE (8) | BITE | 8 of 12 | `ybw` word advances one group early |
| W6_no_word_adv | BITE (7) | BITE | 7 of 12 | `ybw` word never advances |
| W7_last_group | BITE (9) | BITE | 9 of 12 | last group dropped |
| **N1_no_reset** | **SURVIVES** | **SURVIVES** | -- | the `r = 0` cursor reset removed from the NARROW arm |
| N2_off_by_one | **BITE (range error)** | -- | -- | `uw_addr <= off + r + 1`: dies on the element address bound |
| N3_no_lane_adv | BITE (11) | BITE | 11 of 12 | narrow arm's `rlane` never advances |

**Reported not biting, under its own name: N1_no_reset.** `llama_top`'s
`r = 0` reset is path-independent because S_DRAIN is entered from TWO states
(S_RUN and S_SDRAIN) and its own comment records that resetting at the entry
sites instead is what an earlier rewrite got wrong. **The extracted entity has
ONE entry, so the property is unreachable in this bench and the mutation is
invisible.** That is a limitation of the extraction, not of the check, and it
is exactly the property the real edit must preserve -- see the patch, which
keeps the line.

**The attribution control says the independent model bought nothing here.**
Every mutant that FULL killed, the round-trip-only bench also killed, because
the two arms share no code below the entity declaration and any mutation
therefore lands on exactly one of them. The model earns its place only
against a mutation that hits BOTH arms identically, and this mutant set
contains none. Stated rather than claimed as rigour.

**Two kills are range errors, not value checks** (W3, N2). They are real
kills -- GHDL stops -- but they were caught by a constrained `natural range`,
which is the same guard `llama_top`'s own "NO CLAMP on `rword`" comment says
it relies on, and NOT by anything this bench added.

### 6.3 What the simulation does NOT prove

- That `llama_top`'s `S_DRAIN`, edited in place, behaves like
  `region_drain`'s narrow arm. The narrow arm is a COPY, with `r`/`rword`/
  `rlane` moved from process variables to signals (behaviour-preserving,
  because `llama_top` reads `ybw(rword)` before it updates `rword` in the same
  cycle). **A copy can drift from its original and nothing here would notice.**
  The real proof is the edit plus `sim:tb_llama_top*`, and this track does not
  own that file.
- The path-independent entry (N1 above).
- Anything about area or timing. `region_drain` has not been synthesised.
  The group write port's second driver is a `LANES*MANT_W = 128`-bit mux,
  which is small, but that is an ESTIMATE.

---

## 7. The exact patch for `rtl/llama_top.vhd`

Another track (BENABLE) holds `rtl/llama_top.vhd` and
`rtl/fk33_llama_top.vhd`, so this is written down rather than applied. **The
file feeds THREE generators** -- `tools/gen_cardtop.py`,
`sim/ooc_gdnadapt_extract.py` and `hw/fk33/gen_fk33_card.py` reads the output
-- so regenerate and check `sim:cardtop` and `sim:gdnstale` after applying,
exactly as BENABLE's entry records.

Behind `A_DRAIN_WIDE : boolean := false` in the entity generics, so the
default elaborates the shipping design.

**(a) A group-write region select, and a mux. New signals beside `w_we`
(`:1327-1330`):**

```vhdl
  -- THE GROUP WRITE PORT'S REGION.  It used to be `v_reg_d` at its single
  -- use site, which was correct while `seq_vec_res` was its only client.
  signal wg_reg : unsigned(7 downto 0) := (others => '0');
  -- Unit A's group-write face, driven by S_DRAIN when A_DRAIN_WIDE.
  signal aw_we   : std_logic := '0';
  signal aw_reg  : unsigned(7 downto 0) := (others => '0');
  signal aw_addr : unsigned(GA_W-1 downto 0) := (others => '0');
  signal aw_be   : std_logic_vector(LANES-1 downto 0) := (others => '0');
  signal aw_data : std_logic_vector(LANES*MANT_W-1 downto 0) := (others => '0');
```

Rename `seq_vec_res`'s four group-write actuals at `:1914` to
`vw_we`/`vw_addr`/`vw_be`/`vw_data` (new signals of the same types), and add
beside `act_port` (`:1574`):

```vhdl
  -- THE GROUP WRITE MUX.  Same rule as `elmux`: selected by `act_unit`,
  -- which is latched at `job_issue` and held for the whole job, so the
  -- selection cannot move underneath a writer mid-operation.  A and V are
  -- the only clients and D issues one unit at a time.
  wgmux : process(act_unit, aw_we, aw_reg, aw_addr, aw_be, aw_data,
                  vw_we, vw_addr, vw_be, vw_data, v_reg_d) is
  begin
    if act_unit = U_A then
      w_we <= aw_we; wg_reg <= aw_reg; w_addr <= aw_addr;
      w_be <= aw_be; w_data <= aw_data;
    else
      w_we <= vw_we; wg_reg <= v_reg_d; w_addr <= vw_addr;
      w_be <= vw_be; w_data <= vw_data;
    end if;
  end process;
```

**(b) `memp`'s group arm reads `wg_reg` instead of `v_reg_d` (`:1693`):**

```vhdl
-            a := to_integer(unsigned(v_reg_d(6 downto 0)))*REGMAX
+            a := to_integer(unsigned(wg_reg(6 downto 0)))*REGMAX
                  + to_integer(w_addr)*LANES + i;
```

**(c) The region lock names the region that is actually being written
(`:1828`):**

```vhdl
-  wr_region <= v_reg_d when w_we = '1'
+  wr_region <= wg_reg  when w_we = '1'
                else to_unsigned(el_wreg, 8);
```

This is behaviour-identical today (`wg_reg` is `v_reg_d` whenever
`act_unit /= U_A`) and is what stops A's wide write being policed against the
D-vec region. **Without (c) the lever is silently wrong in the guard, not in
the data**, which is the worse failure.

**(d) `S_DRAIN` itself (`:4394-4413`).** Keep the narrow body verbatim; add
the wide arm in front of it. `A_ROWS_IF = 48` and `LANES = 8`, so
`LANES | A_ROWS_IF` and a group never straddles two `ybw` words -- pin it:

```vhdl
  constant bad_lanes_div_rows_if : natural := 0 - (A_ROWS_IF mod LANES);
```

```vhdl
            when S_DRAIN =>
              -- PATH-INDEPENDENT RESET.  Entered from S_RUN and from
              -- S_SDRAIN; see the original comment, which still applies and
              -- is the property the extracted bench CANNOT see.
              if r = 0 then rword := 0; rlane := 0; end if;
              if A_DRAIN_WIDE and (j_off mod LANES) = 0 then
                -- THE GROUP PATH.  LANES lanes out of ONE ybw word.
                aw_we   <= '1';
                aw_reg  <= to_unsigned(j_dst, 8);
                aw_addr <= to_unsigned((j_off + r) / LANES, GA_W);
                for i in 0 to LANES-1 loop
                  if r + i < j_rows then
                    aw_be(i) <= '1';
                    aw_data((i+1)*MANT_W-1 downto i*MANT_W)
                      <= ybw(rword)((rlane+i+1)*MANT_W-1 downto (rlane+i)*MANT_W);
                  else
                    aw_be(i) <= '0';
                    aw_data((i+1)*MANT_W-1 downto i*MANT_W) <= (others => '0');
                  end if;
                end loop;
                if rlane = A_ROWS_IF-LANES then
                  rlane := 0;
                  if rword /= A_YWORDS-1 then rword := rword + 1; end if;
                else
                  rlane := rlane + LANES;
                end if;
                if r + LANES >= j_rows then st := S_DONE; else r := r + LANES; end if;
              else
                -- THE SHIPPING PATH, unchanged.  Also the run-time fallback
                -- for a descriptor whose j_off is not a multiple of LANES:
                -- the group port has no address for it, and slower is not
                -- the same problem as wrong.
                uw_en(U_A)   <= '1';
                uw_reg(U_A)  <= j_dst;
                uw_addr(U_A) <= j_off + r;
                uw_data(U_A) <=
                  signed(ybw(rword)((rlane+1)*MANT_W-1 downto rlane*MANT_W));
                if rlane = A_ROWS_IF-1 then
                  rlane := 0;
                  if rword /= A_YWORDS-1 then rword := rword + 1; end if;
                else
                  rlane := rlane + 1;
                end if;
                if r = j_rows-1 then st := S_DONE; else r := r + 1; end if;
              end if;
```

with `aw_we <= '0';` added to the top-of-process default block beside
`uw_en(U_A) <= '0';` (`:4186`).

**(e) The alignment is not hypothetical and not guaranteed.** MEASURED over
all 311 A jobs of a 9B token (`tools/gen_layer_program.build_plan`):
`dst_off` is in `{0, 2048, 4096}` and `n_rows mod 8 = 0` for every one, so the
wide path runs for all of them and `w_be` never masks. The fallback exists
because a descriptor field cannot be checked at elaboration.

### What could break

- **`wcollide`** (`:1667-1677`) asserts `not (w_we = '1' and el_we = '1')`.
  With A driving the group port, a HOST write (`hw_we`, which takes priority
  in `elmux`) during an A job would fire it. That is already true for
  `seq_vec_res` today and the recorded measurement is `both = 0` with *every*
  host write happening before `go`, so the invariant does not change -- but
  it is now reachable from a second place and should be said out loud.
- **`onehot`** (`:1597-1610`) is unaffected: it watches `uw_en`, and the wide
  path drives none.
- The **region lock** is handled by (c); without it the lever is silently
  wrong in the guard.
- **`j_dst` is a `natural` 0..127** in the adapter but `v_reg_d` is 8 bits
  with `x"FF"` meaning R_NONE. `wg_reg` is kept 8 bits wide so (c) is an
  identity for the V path; A only reaches S_DRAIN when `j_dst < NREGION`.

### What it buys

| | now (MEASURED) | with L1 (DERIVED) |
|---|---:|---:|
| A `S_DRAIN`, per token | 1,426,944 | 178,368 |
| striped token | 30,115,280 | 28,866,704 (**-4.15%**) |
| flat token | 61,907,159 | 60,658,583 (**-2.02%**) |

DERIVED by exact arithmetic over the schedule (`sum(M)` against
`sum(ceil(M/8))`), not by extrapolating a ratio.

---

## 8. Measurement traps hit

- **A second driver on a bench memory reads back as 0, and it looks exactly
  like a drain that never wrote.** The first run of `tb_region_drain` cleared
  `mem_n`/`mem_w` from the stimulus process while the memory processes also
  drove them; resolution against the memory process's `'U'` driver made every
  location `'U'`, which `to_integer` reports as 0, and the bench printed
  `12288 differ ... narrow 0 wide 0` -- a value failure, not a driver failure.
  Fixed with a `clr` signal honoured BY the memory process, one driver each.
- **`--print` of `gen_layer_program.py` does not run on this tree**: the
  manifest at `/mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json` has no
  `hbm.desc_arena_base` block, so the tool ABORTs before printing the plan.
  The plan was obtained by importing `build_plan` directly, which needs no
  arena. An ABORT with an empty output file is not an empty plan.
- **The brief's own DERIVED total was 15.6% high** on the norm, by charging it
  the SwiGLU's three passes. Section 4.2.
- **A per-shape mean is not a slope.** The cycles-per-beat column in 4.1 is
  1.5124 to 1.6138 across the eight large shapes, and 3.8468 on the M = 32
  shape. Reading that spread as a trend in M is the recorded LEVERC48 error;
  the fixed-plus-linear form fits all nine to 197 cycles and the M = 32 row is
  the intercept showing itself, not a different rate.

---

## 9. Open, not determined

- **Whether the group-write mux costs anything in timing.** Not synthesised.
  The card closes at 75 MHz with WNS reported in
  `hw/fk33/results/card_swg_2026-09-20/`, and a 128-bit two-way mux on a path
  into a BRAM write port is not obviously free at 83% LUT occupancy.
- **Whether `llama_top` edited in place matches the extracted narrow arm.**
  Only the edit plus `sim:tb_llama_top*` answers it.
- **B's and C's element traffic (476,912 cycles, DERIVED)** has not been
  reconciled against a measured step, because neither op has a card-side /
  engine split derived for it. The `B_JOB` 660 k is owned by
  `docs/debugging/2026-09-20_b-job-660k-cycles.md` and is a different
  mechanism.
- **`swiglu_mem` at `LANES = 8`** is an extrapolation of SWGFAST's
  `2*NB + 13` law past its measured points (1, 2, 4), and the area at 8 lanes
  (ESTIMATE +16 DSP and +2.3 k LUT per lane) has never been drawn.
- **L3 (A's `S_XRD`)** was scoped but not designed: `matvec_int4`'s x bank
  write port is 16 bits and nothing here establishes what widening it costs.
- **`BASELINE_PASS` in `sim/regress.sh` was NOT raised** for the new
  `sim:tb_region_drain` row. It is a floor, so the gate stays green either
  way; the next track to run a full unfiltered gate should raise it by 1 and
  quote the run, and CLAUDE.md's rule against editing `regress.sh` while a
  gate may be live is why this track did not.
- **The 197-cycle `S_SDRAIN` class residual** is named but not modelled.

---

# 10. APPENDED 2026-09-20 -- TRACK WIDEDRAIN: L1 is applied, and section 7's patch was wrong in three places

Date: 2026-09-20. TRACK WIDEDRAIN, on top of `82a3311`. Sections 1 to 9 above
are DSIDE's and are not edited. **NO HARDWARE, NO VIVADO.** Everything below
is `ghdl-mcode` or arithmetic over `tools/gen_layer_program.py`'s own plan.
The largest `ghdl-mcode` process was SAMPLED at **3.11 GB** `VmRSS` while
three benches ran concurrently; that is a sample and not a peak, and it is
quoted as a sample deliberately.

## 10.1 The answer, up front

**MEASURED in `llama_top` itself, which is the one thing section 6.3 listed as
unprovable by the extracted unit.** At `sim/tb_llama_top_real`'s configuration,
changing exactly one generic and nothing else:

```
A_DRAIN_WIDE false   26,382 cycles a token   EXP_X0 -16364  EXP_XSUM 91622  EXP_XALL 91622  EXP_STEPH 17333
A_DRAIN_WIDE true    24,204 cycles a token   EXP_X0 -16364  EXP_XSUM 91622  EXP_XALL 91622  EXP_STEPH 17333
                     ------
                      2,178
```

DERIVED independently from that schedule's 37 drained A jobs -- `sum(M) =
2,904` against `sum(ceil(M/A_DW_GRP)) = 726` with `A_DW_GRP = 4` -- the saving
is **2,178**. The model and the integration agree **to the cycle**, and the
drain is `2,904 -> 726`.

**All four landmarks are bit-identical across the two arms.** `EXP_STEPH` is
the strong one: it hashes `obs_wsum`, a running hash over EVERY region write
the machine makes, region-tagged, address by address, in order. So it is the
whole write STREAM that is identical, not merely the residual that survives it.

**On the card the lever is worth 1,248,576 cycles a token**, verified in 10.4
from the plan rather than inherited from section 7.

## 10.2 Three corrections to the patch of section 7

### (i) THE ELABORATION PIN AS SPECIFIED REFUSES THE WHOLE TREE

Section 7(d) pins the geometry with

```vhdl
constant bad_lanes_div_rows_if : natural := 0 - (A_ROWS_IF mod LANES);
```

`llama_top`'s defaults are **`A_ROWS_IF = 4`** and `LANES = 8`, so that is
`0 - 4`: a negative `natural`, elaborated during the DECLARATIVE part, in
every configuration **including `A_DRAIN_WIDE => false`**. Every
`tb_llama_top*` row, every seam gate and every card build would have stopped
with a range error while the new arm sat unreachable behind a false generic.

And `A_ROWS_IF = 4` is not a default anybody may raise: `A_NPORTS` is the
package constant **5** (`rtl/llama_map_pkg.vhd:69`), `llama_top`'s `m_*`
ports are `A_NPORTS` wide, and `ga_real` maps `NPORTS_W => A_ROWS_IF`. Four
is the only value that elaborates in `llama_top` at all.

The applied form makes the check a property of the configuration being ASKED
FOR, and admits both nestings rather than one:

```vhdl
constant CHK_A_DRAIN_WIDE : natural :=
  0 - boolean'pos(A_DRAIN_WIDE)
      * ((A_ROWS_IF mod LANES) * (LANES mod A_ROWS_IF));
constant A_DW_GRP : positive := minimum(LANES, A_ROWS_IF);
```

`LANES | A_ROWS_IF` is the card (8 | 48, a whole group a cycle, exactly
section 7's traversal); `A_ROWS_IF | LANES` is llama_top's own default
(4 | 8, four of the eight lanes a cycle with the rest held off by `w_be`).
The wide arm carries a `lane0 := (j_off + r) mod LANES` cursor for the second
case; it is identically 0 in the first, so the card's code path is section 7's
unchanged.

### (ii) THE PATCH IS IN THE WRONG ARM FOR THE CARD

Section 7 quotes `llama_top.vhd:4394-4413`, which is **`ga_real`**. The card
does not generate `ga_real`. `hw/fk33/rtl/fk33_card.vhd:222` sets
`A_DESC => true`; `tools/gen_cardtop.py` emits `ga_real` guarded
`if not A_BEHAV and not A_DESC`; the arm that runs is **`ga_desc`**, whose
`S_DRAIN` is a Python string literal (`D12_GA_NEW`) inside
`tools/gen_cardtop.py`. **Applying L1 to `rtl/llama_top.vhd` alone would have
saved the card nothing, and every bench would have agreed that it worked.**

The cycle claim itself survives: `ga_desc` has the same `S_DRAIN` and the same
`S_XRD`, and section 4.1's fit carries the fixed states in a free intercept
`F`, so the `M` and `K` terms -- the only ones that discriminate -- are
unaffected. (`ga_desc` has no `S_CB`, `S_CBGAP` or `S_EXP`, so section 7's
`card_side = K + M + 21` is `ga_real`'s constant, not the card's. The
difference is absorbed by `F` and changes no conclusion.) What was wrong is
the LOCATION, not the number.

This makes `rtl/llama_top.vhd` the input to a generator whose OUTPUT is what
the card compiles -- CLAUDE.md's *"editing a generator's INPUT carries the
same obligation, and line 2 cannot warn you"*, now for a third consumer
alongside `tools/gen_cardtop.py`'s bench and `sim/ooc_gdnadapt_extract.py`.

### (iii) THERE IS A THIRD `v_reg_d` SITE, AND IT IS THE INSTRUMENT

Section 7 names two places that read `v_reg_d` as if it were the group write
port's region -- `memp` and `wr_region` -- and warns, correctly, that missing
the second fails in the GUARD rather than in the data. **There is a third:
`wsump`, the observability write hash at `llama_top.vhd:6915-6937`**, which
is precisely what `EXP_STEPH` hashes.

MEASURED, and found by the bench rather than by reading. With the other hunks
applied and this one missed, `sim:tb_llama_top_wdrain` reported:

```
P14 -- hash of the 64-completion step trace is 26718 and the recorded
       landmark is 17333.
P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622,
                          EXP_XALL => 91622, EXP_STEPH => 26718
                          (1 of the pinned landmarks moved)
```

**Three landmarks agreed and the fourth did not, and the fourth was right.**
The data was correct; the INSTRUMENT was hashing A's writes against whatever
region the last D-vec op happened to have named. A gate carrying only the
three residual landmarks would have gone green over an observer that had
silently stopped describing the design. With the site fixed to `wg_reg`, all
four match; the mutation that restores it is `M7_wsum_region` in 10.5 and it
is killed by `EXP_STEPH` alone.

On the card the equivalent of hunk (b) is one line of `gen_cardtop.py`'s
`D3_STMT_NEW` -- `cm_regd <= "0" & wg_reg(6 downto 0);` -- because there the
region file is a `region_mem` instance and `memp` does not exist.

## 10.3 What was applied

`rtl/llama_top.vhd`, all of it behind `A_DRAIN_WIDE : boolean := false`:

| # | site | change |
|---|---|---|
| a | group-port signals | new `wg_reg`; `seq_vec_res`'s four actuals renamed to `vw_*`; unit A's face `aw_we`/`aw_reg`/`aw_addr`/`aw_be`/`aw_data`, tied off at declaration |
| b | after `act_port` | new `wgmux`, selected by `act_unit`, guarded `A_DRAIN_WIDE and act_unit = U_A` so the FALSE arm reduces textually to the wiring the file had |
| c | `memp` group arm | `v_reg_d` -> `wg_reg` |
| d | `wr_region` | `v_reg_d` -> `wg_reg` |
| e | `wsump` write hash | `v_reg_d` -> `wg_reg`   **(NOT in section 7)** |
| f | `u_vres` port map | `w_* => vw_*` |
| g | `ga_real` `S_DRAIN` | the group arm in front of the shipping body, which stays verbatim and becomes the misalignment fallback |
| h | declarations | `CHK_A_DRAIN_WIDE`, `A_DW_GRP`, and the `lane0` cursor |

`tools/gen_cardtop.py`: (c) as `cm_regd` in `D3_STMT_NEW`; (g) plus `lane0`
and the `aw_we <= '0'` default inside `D12_GA_NEW`, **so `ga_desc` gets the
same lever**. `rtl/fk33_llama_top.vhd` and `sim/tb_fk33_cardtop_ident.vhd`
regenerated; `git diff` on each carries this change and nothing else.

`sim/tb_llama_top.vhd` gains one pass-through generic defaulting false.
`sim/tb_llama_top_wdrain.vhd` is the new gate row: `tb_llama_top_real`'s
generic map character for character plus `A_DRAIN_WIDE => true`, carrying
`tb_llama_top_real`'s four landmarks UNCHANGED. **They are not re-derived,
deliberately** -- re-measuring them from a run of the wide arm is a round trip
against itself, which this project has on record passing for a
wrong-but-consistent implementation (the `m7 mutant`). Those four values were
themselves cleared against `tools/ref9b/` by `sim:seamgate_*`, so a wide run
matching them has matched a Python model transitively at the element level.

`sim/mutate_a_drain_wide.sh` is the teeth harness.

## 10.4 The alignment claim, verified rather than trusted

Section 7(e) asserts every A job has `dst_off` in {0, 2048, 4096} and
`n_rows mod 8 = 0`. RE-DERIVED here from `gen_layer_program.build_plan` at
`QWEN35_9B`, with the lm_head split into the 15 windows the profile unfolds:

```
A_JOB steps 311   drained 296   lm_head windows 15  (14 x 17,376 + 1 x 5,056)
dst_off over drained jobs   {0, 2048, 4096}                  all = 0 mod 8
n_rows  over drained jobs   {32, 1024, 2048, 4096, 8192, 12288}  all = 0 mod 8
sum(M) 1,426,944    sum(ceil(M/8)) 178,368    saving 1,248,576
```

**CONFIRMED to the element, and one number sharpened.** `build_plan` at its
default single lm_head window emits **297** A jobs, not 311; 311 is the count
with 15 windows, which is also `A_N_JOBS` and what the profile's step table
shows. Section 7 said "311 A jobs" without saying which; both are right for
different window counts and only one of them is the arena size.

**AND THE SAME ALIGNMENT HOLDS AT THE BENCH GEOMETRY, WHICH IS THE PROBLEM.**
At `mk_shape_scaled(4, 4, 16)` every drained A job has `dst_off` in
{0, 64, 128} and `n_rows` in {4, 64, 128}, and `A_DW_GRP` is 4 -- so **every
offset and every row count is a multiple of the group, on the bench and on the
card alike.** Two of the wide arm's four behaviours are therefore UNREACHABLE
at every shape any bench or the card can present:

- **the misaligned fallback**, `j_off mod A_DW_GRP /= 0`; and
- **the partial final group**, which is the only thing `w_be`'s tail mask is
  for.

Both are exercised at the card's geometry by `sim/tb_region_drain.vhd`:
`misaligned_37` and `misaligned_64` take the fallback, and `tail_100`,
`cross_word_50` and `single_1` have partial groups, all against an independent
model. They are NOT exercised in `llama_top`, and 10.5 measures exactly that
rather than asserting it: the two mutants that break them both SURVIVE the new
gate row, under their own names.

## 10.5 The mutation table

MEASURED by `bash sim/mutate_a_drain_wide.sh`, 29 rows, `ghdl-mcode`,
`sim/tb_llama_top.vhd` at `tb_llama_top_real`'s generics. Every mutation is
one anchored substitution in `rtl/llama_top.vhd`, applied in a scratch copy,
with a REQUIRED occurrence count of 1 so a partial edit is an error and not a
verdict.

**Two attribution controls per row, because a kill proves nothing about who
made it:**

- `_N` -- the same mutation with **`A_DRAIN_WIDE` FALSE**. If it still bites,
  `sim:tb_llama_top_real` already caught it and the new row deserves no credit.
- `_X` -- the same mutation, wide, with the **four landmarks UNSET**. If it
  still bites, the kill belongs to a structural property (the region lock, the
  residual exponent check, a constrained range), not to the value gate.

| mutant | what | wide | `_N` narrow | `_X` no landmarks | who actually killed it |
|---|---|---|---|---|---|
| `W0w` | CONTROL, clean, wide | SURVIVED, 24,204 cyc | -- | -- | clean passes |
| `W0n` | CONTROL, clean, narrow | SURVIVED, 26,382 cyc | -- | -- | clean passes |
| `M1_be_tail` | `w_be` enabled one row PAST the vector | **SURVIVED** | SURVIVED | SURVIVED | **nobody -- see below** |
| `M2_addr_no_off` | group address drops `j_off` | KILLED, `EXP_STEPH` 17333 -> 31235, other three UNMOVED | SURVIVED | SURVIVED | **the new row's value gate, and only `EXP_STEPH`** |
| `M3_last_group` | off by one on the last group (`>` for `>=`) | **SURVIVED**, 24,241 cyc | SURVIVED | SURVIVED | **nobody -- see below** |
| `M4_lane_skew` | `ybw` lane slice skewed one mantissa | KILLED(ABORT) `overflow detected` | SURVIVED | KILLED(ABORT) | the SIMULATOR's constrained range, not the gate |
| `M5_wr_region` | `wr_region` reads `v_reg_d` again | KILLED(ABORT) | SURVIVED | KILLED(ABORT) | `llama_top`'s OWN `gatechk`: *"the region lock DROPPED a write to region 1"* at 797,500 ps |
| `M6_memp_region` | `memp` reads `v_reg_d` again | KILLED, ALL FOUR landmarks moved (`-32000 / 98349 / 98349 / 40262`) | SURVIVED | KILLED | the residual exponent check P6 fires first; the landmarks confirm |
| `M7_wsum_region` | the write hash reads `v_reg_d` again | KILLED, `EXP_STEPH` 17333 -> 26718, other three UNMOVED | SURVIVED | SURVIVED | **the new row's value gate, and only `EXP_STEPH`** |
| `M8_no_fallback` | the misaligned fallback removed | **SURVIVED** | SURVIVED | SURVIVED | **nobody -- see below** |
| `M9_no_reset` | the `r = 0` cursor reset removed | KILLED(ABORT) | **KILLED(ABORT)** | KILLED(ABORT) | an EXISTING row. `_N` bites, so `sim:tb_llama_top_real` catches it already |

### What the controls actually bought, stated rather than implied

- **`M2` and `M7` are the new row's only unshared kills**, and both are
  `EXP_STEPH`'s alone: their `_X` controls SURVIVE and their `_N` controls
  SURVIVE. `M2` is the sharp one -- the group address losing `dst_off` puts
  every A job's output at offset 0 of its region, and `EXP_X0`, `EXP_XSUM` and
  `EXP_XALL` are all UNMOVED by it, because R_X is written by the residual and
  not by A. **Three agreeing landmarks over a wholesale mis-addressing of
  subsystem A's entire output.** The fourth is the whole gate.
- **`M5` is the hunk section 7 warned about, and the warning was right in
  mechanism and wrong about who catches it.** The kill is `llama_top`'s own
  region-lock `gatechk`, an EXISTING property, not P14 -- its `_X` control
  bites. What the new arm contributes is REACHABILITY: `_N` survives, so the
  defect does not exist until A drives the group port. The lever creates the
  hazard and an existing guard catches it, which is the cheapest possible
  outcome and is worth recording as such.
- **`M9` gets no credit at all.** It bites with `A_DRAIN_WIDE` false, so
  `sim:tb_llama_top_real` would have caught it without this track. Reported
  because a kill nobody can attribute is worse than no kill.
- **`M4` is a range error, not a value check** -- GHDL's `overflow detected`,
  caught by the same constrained `natural range` discipline the `rword`
  comment already relies on. A real kill, and not the gate's.

### The three mutants that do NOT bite, under their own names

All three are the SAME geometric fact, and it is the one 10.4 establishes:
**at every shape reachable here, `dst_off mod A_DW_GRP = 0` and
`n_rows mod A_DW_GRP = 0`.**

- **`M1_be_tail`** enables one lane past the vector. It can only differ when a
  group extends past `j_rows`, i.e. when `j_rows` is not a multiple of
  `A_DW_GRP`. There is no such job. The guard that DOES bite is
  `sim/tb_region_drain.vhd` -- DSIDE's `W1_no_be_tail` kills on `tail_100`,
  `cross_word_50` and `single_1`.
- **`M3_last_group`** is an off-by-one on the final group. Its only observable
  effect here is **one wasted cycle per drained A job**: 24,241 against the
  clean 24,204, and `24,241 - 24,204 = 37`, which is exactly the number of
  drained A jobs in this schedule. It writes an extra group with every lane
  disabled, so no value moves and no landmark can see it. **Nothing in the
  gate reads a cycle count**, which is why this row survives; the cycle figure
  is printed by the bench and compared by a human.
- **`M8_no_fallback`** removes the alignment guard. Unreachable for the same
  reason. `tb_region_drain`'s `W4_no_fallback` kills it on both `misaligned_*`
  rows.

**That is the resolution floor of this gate row, measured rather than
asserted: it cannot see the partial-group tail, the alignment fallback, or a
cycle regression.** The first two are covered one level down; the third is
covered by nothing.

## 10.6 Gate rows, verbatim

MEASURED by `bash sim/regress.sh --only <pat>`, every group re-run AFTER the
last edit to the tree:

```
##### --only tb_llama_top
 OVERALL     PASS 13   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only cardtop
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only gdnstale
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only seamgate
 OVERALL     PASS 6   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only fk33card
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only region_drain
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only gdn
 OVERALL     PASS 21   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1   SKIPPED 0
 REGRESSION: PASS
```

The thirteen `tb_llama_top` rows include the new `sim:tb_llama_top_wdrain`
(70 s) beside `sim:tb_llama_top_real` (77 s); `sim:tb_fk33_cardtop_ident`
(107 s) is the generated identity bench, so `fk33_llama_top` with the generic
false is still bit-identical to `llama_top`. The six `seamgate` rows are the
independent Python oracle that cleared the landmarks this track reuses.

`--only gdn` is the pre-existing state unchanged: `PASS 21 ... NOCHECK 1`, the
one NOCHECK being `sim:tb_gdn_conv_cycles`, which was already there.

`BASELINE_PASS` in `sim/regress.sh` was NOT raised for `sim:tb_llama_top_wdrain`
(nor was it raised for `sim:tb_region_drain` by DSIDE). It is a floor, so the
gate stays green; the next track to run a full unfiltered gate should raise it
by 2 and quote that run.

## 10.7 The recommendation for the next card build

**A_DRAIN_WIDE stays FALSE in this commit, and the ask is an A/B, not a
bitstream on trust.**

What is settled: values are bit-identical through the whole write stream, the
saving is exact arithmetic over the shipping schedule, and the lever is worth
**1,248,576 cycles a token, 4.15% of the 30,115,280-cycle striped token and
2.02% of the flat one**.

What is NOT settled, and it is all of the cost side:

- **Nothing here has been synthesised.** No `synth_design`, no `place_design`,
  no `route_design` has seen this RTL, and CLAUDE.md's own table says nothing
  before `route_design` orders two runs correctly on this part.
- **The mux is small; the estimate is mine and unverified.** `wgmux` is a 2:1
  over `w_we` (1) + `w_addr` (`GA_W` = 11) + `w_be` (8) + `w_data` (128) +
  `wg_reg` (8) = **156 bits**, ESTIMATE ~156 LUT plus the select. Against the
  card's 83% LUT occupancy that is noise, but it sits between a register and
  a BRAM write port on a design that closes at 75 MHz, and one added logic
  level on that path is exactly the kind of thing only a routed run prices.
- **THE FALLBACK IS A RUN-TIME BRANCH, SO BOTH MUXES ARE BUILT.** `j_off` is a
  descriptor field, so `if A_DRAIN_WIDE and (j_off mod A_DW_GRP) = 0` cannot
  fold away. With the generic true, `ga_desc` carries BOTH the existing 48:1
  16-bit element mux AND a new 6:1 128-bit group mux out of `ybw`, plus ~156
  flip-flops for `aw_*`. ESTIMATE +250 to +400 LUT and +156 FF in `ga_desc`;
  DERIVED from the mux widths, not measured. Making it a `generate` would drop
  the fallback and the safety net with it -- **not recommended**, and 10.4/10.5
  show the fallback is already untestable at any shipping shape, so removing
  it would trade a known-untested path for a known-absent one.

**The concrete ask, in the order that costs least:** one OOC synthesis of
`fk33_llama_top` at `A_DESC => true` with `A_DRAIN_WIDE` false and true, on
whichever Vivado lane is free, for the LUT/FF delta; then, only if that is
acceptable, a routed card pair for WNS. A card build with the generic flipped
and no A/B would put an unpriced 128-bit mux on the region file's write path
in the same bitstream as everything else that changed that week, which is the
uncontrolled-experiment shape CLAUDE.md records twice.

## 10.8 Measurement traps hit

- **THE STALE SHARED FILE LIST IN `sim/mutate_llama_top_kv.sh` MAKES EVERY
  `mutate_llama_top*` HARNESS REPORT `DID NOT ANALYZE` ON EVERY ROW.**
  MEASURED: reading its `FILES=` verbatim gives
  `rtl/gdn_state_store.vhd:903: unit "gdn_conv_w_mem" not found in library
  "work"`, because subsystem B's constants path (`e212f04`) added memories
  nothing added to that list. `sim/regress.sh` builds its own order and is
  unaffected, which is why nobody noticed. It fails LOUDLY, which is the only
  reason this is a note. Worked around locally here (TRACK BNARROW holds those
  files); **the shared list still needs the name.**
- **Re-analysing ~60 files per mutation row costs about four minutes each.**
  The first attempt at this 29-row matrix was going to take two and a half
  hours, which is long enough that a table gets trimmed to fit -- and the rows
  that get trimmed are the controls. Only `rtl/llama_top.vhd` and
  `sim/tb_llama_top.vhd` can carry a mutation here, so the harness analyses
  the rest once into a base library and copies it per row.
- **A buffered redirect makes a running matrix look dead.** `nohup ... > log`
  is block-buffered, so row verdicts appear in bursts. Progress was read from
  the count of row DIRECTORIES, which the kernel updates immediately -- the
  same instrument CLAUDE.md already records for a full gate.
- **Three agreeing landmarks are not agreement.** Section 10.2(iii) and `M2`
  in 10.5 are the same lesson from two directions: `EXP_X0`, `EXP_XSUM` and
  `EXP_XALL` all read R_X, which subsystem A does not write. Any number of
  them agreeing says nothing about A's output.
- **`A_ROWS_IF` was read as a tunable and it is a fixed point.** The first
  plan for proving this in `llama_top` assumed a bench could raise `A_ROWS_IF`
  to 8 or 48. `A_NPORTS` is a package constant and `llama_top`'s `m_*` port
  widths come from it, so 4 is the only value that elaborates. That is what
  forced `A_DW_GRP = min(LANES, A_ROWS_IF)` rather than section 7's `LANES`,
  and it is the difference between a provable lever and an unreachable one.

## 10.9 Open, not determined

- **Every cost figure.** Not synthesised, not placed, not routed. The LUT, FF
  and WNS numbers in 10.7 are ESTIMATE from mux widths and nothing else.
- **The partial final group and the misaligned fallback, in `llama_top`.**
  MEASURED unreachable at every shape this design can present (10.4), and
  MEASURED invisible to the new gate row (`M1`, `M3`, `M8` in 10.5). Covered
  only by `sim/tb_region_drain.vhd`, one level down, at the card's geometry.
  **Nothing checks that `llama_top`'s copy of the traversal still matches
  `region_drain`'s** -- the extraction was a copy on 2026-09-20 and can drift.
- **A cycle regression is invisible to the gate.** `M3_last_group` survives
  while costing 37 cycles a token, because no row compares a cycle count. A
  cycle landmark in `tb_llama_top` would close it and does not exist.
- **`ga_desc`'s wide arm has never been SIMULATED.** `sim:tb_fk33_cardtop_adesc`
  checks drivers, not values, and no bench runs an A job through `A_DESC`. The
  code is textually the same traversal as `ga_real`'s at a different
  `A_DW_GRP`, and that is an argument, not a measurement.
- **Whether `wcollide` is still safe with two clients on the group port.**
  Section 7 flagged that a host write during an A job would now fire it from a
  second place. Unchanged and still MEASURED `both = 0` with every host write
  before `go`; still an untested case rather than an impossible one.
- **L2, L3, L4 and L5 are untouched.** L1 has now paid for the group-write mux
  they all need.
