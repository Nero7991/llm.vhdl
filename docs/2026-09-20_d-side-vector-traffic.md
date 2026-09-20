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
