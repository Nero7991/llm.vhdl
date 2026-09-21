# The SwiGLU was moved onto the group ports, and the step is 61,473 -> 6,176

Date: 2026-09-20.  TRACK GSRWIDE, lever **L2** of
`docs/2026-09-20_d-side-vector-traffic.md`, on top of `e9ec8e7` (TRACK
PATHFREE).  **NO HARDWARE and NO VIVADO were touched by this track.**  Every
number below is `ghdl-mcode` on this workstation or exact arithmetic over
`rtl/llama_top.vhd`'s own FSM; the card figures it is compared against are
TRACK DSIDE's readings of
`hw/fk33/results/card_swg_2026-09-20/profile/profile_striped_tok0.txt`.

---

## 1. The question, verbatim

> THE TARGET IS LEVER L2, ranked second by TRACK DSIDE and still unclaimed.
> [...] Its finding: the region file at `rtl/llama_top.vhd:1334-1389` has FOUR
> ports, an ELEMENT pair one 16-bit word wide used by A, B, C and both vector
> adapters, and a GROUP pair eight lanes wide with per-lane byte enables used
> by `seq_vec_res` alone.  [...]  10.7x per element, and the narrow path is
> not forced by the memory, the port width or a handshake: it is which port
> each adapter was wired to.

## 2. The answer

**Both halves of `VEC_SWG` were moved and both are MEASURED, not projected.**

| | MEASURED, before | MEASURED / DERIVED, after | by |
|---|---:|---:|---|
| `swiglu_mem`, N = 12288 | 24,588 (LANES 1) | **3,085** (LANES 8, wide face) | MEASURED, `sim:tb_swiglu_mem_w8_9b` |
| `gsr` adapter, N = 12288 | 36,870 = 3(N+2) | **3,076** = 2(N/8+2) | DERIVED from the FSM, and MEASURED at the bench shape to the cycle |
| `S_GO` | 1 | 1 | unchanged |
| the card's unexplained residual | 14 | 14, **kept explicit** | TRACK DSIDE's, not absorbed |
| **`VEC_SWG` step** | **61,473** | **6,176** | |

**DERIVED over the token: 32 x 61,473 = 1,967,136 becomes 32 x 6,176 =
197,632, a saving of 1,769,504 cycles -- 5.88% of the 30,115,280-cycle
lane-striped token and 2.86% of the 61,907,159-cycle flat one.**  That is
DSIDE's L2 estimate of 1,769,472 confirmed to within 32 cycles, and the 32 is
DSIDE rounding the unit's LANES = 8 figure to "~3,085" before it had been
measured.

**The values are bit-identical, and the cycle model is exact at four
points.**  `sim/tb_llama_top_swgw.vhd` runs the integration top with the
lever on and carries `sim/tb_llama_top_swg.vhd`'s four pinned landmarks
UNCHANGED -- including `EXP_STEPH`, which hashes every region write the
machine makes, region-tagged, address by address, in order.

**Everything is behind two generics defaulting to today's behaviour**:
`SWG_LANES : positive := 1` and `SWG_WIDE : boolean := false`.

---

## 3. The mechanism, with line numbers and quoted RTL

### 3.1 What the four ports are, and who was on which

`rtl/llama_top.vhd:1409-1464` publishes four region-file faces.  Before this
track:

| port | width | clients |
|---|---|---|
| element read `ur_*` -> `el_rdata` | 1 x 16 bit | A, B, C, `gvr`, `gsr` |
| element write `uw_*` | 1 x 16 bit | the same five |
| group read `r_en`/`r_addr` -> `x_rdata`, `e_rdata` | **LANES x 16, TWO operand regions at one address** | `seq_vec_res` |
| group write `w_we`/`w_addr`/`w_be`/`w_data` | **LANES x 16, per-lane enables** | `seq_vec_res`, and unit A since `6f4458a` |

The group read's shape is the whole lever, and it is in `memp` at
`llama_top.vhd:1888-1904`:

```vhdl
      -- The D-vec group read: ONE address, TWO operand regions.
      if r_en = '1' then
        for i in 0 to LANES-1 loop
          a := to_integer(unsigned(v_reg_a(6 downto 0)))*REGMAX
               + to_integer(r_addr)*LANES + i;
          ...  x_rdata(...) <= std_logic_vector(mem(a));
          a := to_integer(unsigned(v_reg_b(6 downto 0)))*REGMAX
               + to_integer(r_addr)*LANES + i;
          ...  e_rdata(...) <= std_logic_vector(mem(a));
```

**G and U ARE `v_reg_a` and `v_reg_b`** -- `gsr`'s own narrow `S_RD` reads
exactly those two registers, one in each pass (`llama_top.vhd:4040-4048`
before the edit).  So one group-port address fetches a whole group of BOTH
operands, and `gsr`'s two serial passes of `n + 2` were two passes over a
port that delivers both in one.

### 3.2 The five things that had to change, and the sixth that did not

**(a) `swiglu_mem` had no wide face at all.**  `rtl/swiglu_mem.vhd`'s
`g_wdata`/`u_wdata` are `std_logic_vector(15 downto 0)` and `o_rdata` is 16
bits, at every LANES, because TRACK SWGFAST's `LANES` widened the BANKS and
not the PORTS.  Added behind `WIDE_IO : boolean := false`:

```vhdl
    gw_we   : in  std_logic := '0';
    gw_addr : in  std_logic_vector(clog2(N)-1 downto 0) := (others => '0');
    gw_g    : in  std_logic_vector(LANES*16-1 downto 0) := (others => '0');
    gw_u    : in  std_logic_vector(LANES*16-1 downto 0) := (others => '0');
    o_gdata : out std_logic_vector(LANES*16-1 downto 0) := (others => '0');
```

**The layout made this free.**  `swiglu_mem` already puts word i in bank
`i mod LANES` at offset `i / LANES`, so a LANES-ALIGNED group is exactly one
word in every bank at ONE offset -- the same slice `gw_addr(LOG2N-1 downto
LB)` the narrow face already takes, because the low `LB` bits it drops are
the lane index and they are zero on an aligned beat.  There is no shuffle,
no decode and no per-lane address.  `o_gdata` is the LANES output banks'
registered douts concatenated, addressed by the SAME `o_raddr` the narrow
read uses: there is no second read address and no second port, so the
one-edge latency contract is literally the same contract.

`WIDE_IO` REPLACES the word ports rather than sitting beside them, so
neither bank write port grows a mux in either configuration and the FALSE
arm is textually the 2026-09-19/SWGFAST unit.

**(b) The two operand reads: two passes of `n + 2` become one of `ng + 2`**
(`llama_top.vhd:4003-4045`).  `ng = n / SWG_GRP`, and the read latency is
the SAME two edges the element port has and for the same reason (the address
is registered in the adapter, `memp` registers the data), so the `k >= 2`
consumption offset carries over unchanged:

```vhdl
                  if k < ng then
                    swr_en   <= '1';
                    swr_addr <= to_unsigned((k*SWG_GRP)/LANES, GA_W);
                  end if;
                  if k >= 2 then
                    lane0 := ((k-2)*SWG_GRP) mod LANES;
                    gw_we   <= '1';
                    gw_addr <= std_logic_vector(
                                 to_unsigned((k-2)*SWG_GRP, LOG2N));
                    for i in 0 to SWG_GRP-1 loop
                      gw_g(...) <= x_rdata((lane0+i+1)*MANT_W-1
                                           downto (lane0+i)*MANT_W);
                      gw_u(...) <= e_rdata((lane0+i+1)*MANT_W-1
                                           downto (lane0+i)*MANT_W);
                    end loop;
                  end if;
```

**(c) The write-back** (`llama_top.vhd:4100-4148`).  `o_gdata` has the same
one-edge latency as `o_rdata` because it is the same read of the same banks,
so the `rav`/`rav_d` two-deep pipeline is carried over verbatim and only the
stride and the width change.

**(d) The address arithmetic.**  The group port addresses GROUPS, not
elements: `memp` computes `r_addr*LANES + i`.  So a beat covering elements
`e .. e+SWG_GRP-1` has group address `e / LANES` and occupies lanes
`e mod LANES` upward.  At the card SWG_GRP = LANES = 8 and `lane0` is
identically 0, which is why every one of these expressions is written so
that it COLLAPSES at that geometry -- and that is also why four mutants
below are no-ops there and had to be given a second configuration.

**(e) The region lock, and this is the guard-level question the brief asked.**
TRACK WIDEDRAIN's `wr_region <= wg_reg` hunk was needed because unit A
writes a region that `v_reg_d` does not name.  **`gsr` does not**: it writes
the D-vec DESTINATION, which is exactly what `v_reg_d` names, so
`wg_reg <= v_reg_d` in the SwiGLU arm of `wgmux` is an identity and the lock,
`memp` and `wsump` all need no change.  Saying so is not the end of the
question -- see 3.3, which is where the L2 analogue actually lives.

**(f) `w_be` and the partial final group: THE CASE DOES NOT EXIST HERE, AND
NOT MERELY AT THE SHIPPING SHAPE.**  `swiglu_mem` pins `N mod LANES = 0` at
elaboration and `gsr` ASSERTS `n = NN` at issue, so `n` is a multiple of
SWG_GRP in every configuration that elaborates.  WIDEDRAIN's equivalent case
was unreachable because no DESCRIPTOR in the plan had a partial group, which
is a property of the schedule; this one is unreachable because the unit will
not elaborate otherwise, which is a property of the design.  The mask is
computed from `n` anyway, and the mutant that removes the tail term is
reported below as NOT BITING, at both geometries, under its own name.

### 3.3 The L2 analogue of the region-lock hunk, and the check written for it

WIDEDRAIN's warning is that a lever can be wrong in the GUARD rather than in
the data, where a value-checking bench passes it.  For L2 the guard that was
missing is not the region tag.  It is this:

**The ELEMENT ports have `onehot` (`llama_top.vhd:1699-1713`), which watches
`uw_en` across every client and fires when a unit that is not `act_port`
drives it.  THE GROUP PORTS HAVE NEVER HAD AN EQUIVALENT.**  For a year they
had one client; for one day they had two that cannot both be active.  With
three, the failure mode is no longer two drivers on one wire -- a mux
structurally prevents that -- it is **a client raising a request that the mux
is not pointing at**, which is a write or a read silently dropped.

`greq` (`llama_top.vhd:1808-1860`) is that check, and it has two properties:

```vhdl
      a_sel := A_DRAIN_WIDE and act_unit = U_A;
      s_sel := SWG_WIDE and act_unit = U_V and act_vop = V_SWG;
      nw := 0;
      if aw_we = '1' then nw := nw + 1; end if;
      if vw_we = '1' then nw := nw + 1; end if;
      if sw_we = '1' then nw := nw + 1; end if;
      assert nw <= 1  ...
      assert not (sw_we = '1' and not s_sel)  ...
      assert not (vw_we = '1' and (a_sel or s_sel))  ...
      assert not (swr_en = '1' and not s_sel)  ...
```

(b) implies (a) and both are stated because (b) names WHICH client was
dropped and (a) does not.  Clocked, so Vivado ignores them in synthesis.
The rows that give it teeth are `M9_wmux_sel` and `M10_rmux_sel`, each with
its own `_G` control in which `greq` is disabled WHOLE -- not one assert
defanged, because the six properties catch different clients and downgrading
the first would credit an older guard for a mutant that trips the fourth.

### 3.4 The selection rule, and why it is `act_vop` and not `act_unit`

Both muxes select on `act_unit = U_V and act_vop = V_SWG`, which is the SAME
pair `act_port` already uses for the element mux (`llama_top.vhd:1729`).
`act_vop` is latched at `v_taken` (`llama_top.vhd:6993-6999`), the engine's
own accept instant; `gsr` REGISTERS its `tk`, so `v_taken` is high in the
cycle after the accept edge -- the same edge on which `swr_en` is first
registered.  The two line up exactly, and they line up for the reason the
element path already worked.  Selecting on `act_unit` alone would hand the
group ports to `gsr` for the whole of EVERY D-vec op including the residual.

---

## 4. The evidence

### 4.1 `swiglu_mem` at LANES = 8 through the wide face, MEASURED not extrapolated

DSIDE's section 9 lists LANES = 8 under OPEN as *"an extrapolation of
SWGFAST's `2*NB + 13` law past its measured points (1, 2, 4)"*.  Two new gate
rows measure it, and they run the WIDE face, so the ports are measured too:

```
SWGFAST_CYCLES 268   N=128   LANES=1 WIDE_IO=false
SWGFAST_CYCLES  45   N=128   LANES=8 WIDE_IO=true
SWGFAST_CYCLES 24588 N=12288 LANES=1 WIDE_IO=false
SWGFAST_CYCLES 3085  N=12288 LANES=8 WIDE_IO=true
GSRWIDE_BEATS load 24576 store 12288 narrow, load 1536 store 1536 wide   N=12288 LANES=8
GSRWIDE_BEATS load   256 store   128 narrow, load   16 store   16 wide   N=128   LANES=8
```

`2*NB + 13` at NB = 1536 is 3,085 and at NB = 16 is 45.  **The law holds at
8, and it is now a measurement rather than a projection.**

**The values are held to an INDEPENDENT model at every point.**
`sim/tb_swiglu_mem.vhd` compares the DUT against the shipping
`swiglu -> vec_mem -> bfp_pack` chain of `rtl/engine_shared.vhd`, which
shares no storage, no addressing, no pipeline and no pack code with it, with
NO tolerance, over seventeen value trials plus a twelve-point
wild-exponent sweep.  This track added a SECOND read-out pass that compares
every lane of `o_gdata` against `bfp_pack`'s flat `o_mant` -- **not against
`o_rdata`, which is a sibling of the same banks and would make it a round
trip.**  That loop waits exactly one rising edge between presenting
`o_raddr` and sampling, so it is also the wide face's one-edge latency check.

### 4.2 In `llama_top` itself: four configurations, identical values, an EXACT cycle model

MEASURED by `sim/mutate_swg_wide.sh`'s clean controls and by the gate rows,
all at `tb_llama_top_swg`'s generics over three tokens, changing only
`SWG_LANES` and `SWG_WIDE`:

| SWG_LANES | SWG_WIDE | cycles, 3 tokens | delta | EXP_X0 | EXP_XSUM | EXP_XALL | EXP_STEPH |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | false (**shipping**) | 82,329 | -- | 10238 | 87031 | 65159 | 35900 |
| 8 | false | 79,653 | **-2,676** | 10238 | 87031 | 65159 | 35900 |
| 4 | **true** | 76,173 | **-6,156** | 10238 | 87031 | 65159 | 35900 |
| 8 | **true** | 75,405 | **-6,924** | 10238 | 87031 | 65159 | 35900 |

**All four landmarks are bit-identical across all four configurations**, and
`EXP_STEPH` is the strong one: it hashes EVERY region write the machine
makes, region-tagged, address by address, in order, including every enabled
lane of every group write.  So it is the whole write STREAM that is
identical, not a residual that survived it.

**AND THE MODEL IS EXACT AT ALL THREE DELTAS, which is what distinguishes a
structural relationship from a fit.**  DERIVED from the FSM, with 4 SwiGLU
ops per token, 3 tokens, `n = SHAPE.ffn = 128`:

```
adapter narrow   3*(n+2)              = 390
adapter wide     2*(n/GRP + 2)        =  36 at GRP 8,  68 at GRP 4
unit             2*(n/LANES) + 12/13  = 268 at 1, 77 at 4, 45 at 8

SWG_LANES 8 narrow   12 * (268 - 45)             = 12 * 223 = 2,676   MEASURED 2,676
SWG_LANES 4 wide     12 * ((390-68) + (268-77))  = 12 * 513 = 6,156   MEASURED 6,156
SWG_LANES 8 wide     12 * ((390-36) + (268-45))  = 12 * 577 = 6,924   MEASURED 6,924
```

The unit's 77 at LANES = 4, N = 128 was never measured directly; the
integration agrees with it to the cycle, which is an independent
confirmation of SWGFAST's law at a third point.

### 4.3 The card, DERIVED, with the 14-cycle residual kept explicit

DSIDE's accounting reproduces the card's MEASURED 61,473-cycle `VEC_SWG`
step to 14 cycles, and the identical 14 appears on `VEC_NORM` through the
same wrapper, so it is the wrapper's and not the SwiGLU's.  **It is carried
into every row below rather than absorbed.**

| SWG_LANES (SWG_WIDE true) | adapter | S_GO | unit | residual | **step** | saving/step | **x32 per token** | % striped | % flat |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| -- (shipping, narrow, LANES 1) | 36,870 | 1 | 24,588 | 14 | **61,473** | -- | -- | -- | -- |
| 1 | 24,580 | 1 | 24,588 | 14 | 49,183 | 12,290 | 393,280 | 1.31 | 0.64 |
| 2 | 12,292 | 1 | 12,301 | 14 | 24,608 | 36,865 | 1,179,680 | 3.92 | 1.91 |
| 4 | 6,148 | 1 | 6,157 | 14 | 12,320 | 49,153 | 1,572,896 | 5.22 | 2.54 |
| **8** | **3,076** | 1 | **3,085** | 14 | **6,176** | **55,297** | **1,769,504** | **5.88** | **2.86** |

Every `unit` figure is MEASURED (`24,588 / 12,301 / 6,157` by TRACK SWGFAST,
`3,085` by this track's `sim:tb_swiglu_mem_w8_9b`).  Every `adapter` figure
is `2*(12288/GRP + 2)` from the FSM, which 4.2 confirms exact at the bench
shape.  The `61,473` is the card's own profile.

**The SWG_LANES = 1 row is the one nobody had noticed.**  `SWG_WIDE` with
`SWG_LANES = 1` is a legal configuration -- `LANES mod 1 = 0` -- and it buys
393,280 cycles a token with **no lane replication at all**: the two operand
load passes become one because the group READ port carries two regions at
one address, and that is a property of the port, not of the unit's width.
It is the cheapest point on this curve by a wide margin in area, and 4.4
below is why that matters.

### 4.4 The area, ESTIMATE, and what is actually expensive

**NO SYNTHESIS OF ANY KIND HAS SEEN THIS RTL.**  No `synth_design`, no
`place_design`, no `route_design`.  This track had no Vivado lane (the
workstation's was on a card build and the BC-250's was held by TRACK
LEVERCOST), so everything here is arithmetic over widths and is labelled
ESTIMATE.  CLAUDE.md's own table says nothing before `route_design` orders
two runs correctly on this part.

The card places at **CLB 54,854 of 54,960 (99.81%, 106 free)** with LUT at
82.58% and closed at **WNS +0.061 ns**, so the margin is CLB sites and not
LUTs.

| item | ESTIMATE | basis |
|---|---|---|
| `wgmux` 2:1 -> 3:1 | **+0 to +20 LUT** | 156 bits (`w_we` 1 + `wg_reg` 8 + `w_addr` 11 + `w_be` 8 + `w_data` 128).  A 3:1 mux is 2 selects + 3 data = 5 inputs, so it fits the same LUT6 a 2:1 does; what grows is the `act_vop` decode |
| `rgmux`, new | **+12 LUT** | 2:1 over `r_en` 1 + `r_addr` 11 |
| `gsr`'s group-face registers | **+365 FF net** | `sw_*` 148 + `swr_*` 12 + `gw_*` 271, less the ~66 narrow-face flops the wide arm stops using |
| `greq` | **0** | clocked asserts, which Vivado ignores in synthesis |
| **`swiglu_mem` at LANES = 8** | **the whole cost, and it is not measured** | 7 extra copies of a four-stage datapath carrying TWO 32x32 signed multiplies and a `sigmoid_q` table lookup.  DSIDE's ESTIMATE was +16 DSP and +2.3 k LUT per lane, i.e. **+112 DSP and +16 k LUT at 8 lanes**; a 32x32 signed multiply is ~4 DSP48E2, which would make it +56 DSP.  The two estimates differ by 2x and NEITHER has been drawn. |

**So the honest statement is the opposite of the one this lever invites: the
group-port muxes are noise, and the lane replication is the entire area
question.**  That is exactly why 4.3 is a CURVE and not a single point --
`SWG_LANES` is a dial, `SWG_WIDE` is nearly free, and the two are
independent generics on purpose.

**THE ONE THING THAT COULD MAKE THE MUX SIDE EXPENSIVE, and it is not
measured either.**  `lane0 := ((k-2)*SWG_GRP) mod LANES` indexes a slice of
`x_rdata`/`e_rdata`, and `lane0` is a run-time variable.  At the card's
`SWG_GRP = LANES = 8` it is identically zero and the low three bits of
`(k-2)*8` are structurally zero, so constant propagation should fold the
slice to a fixed one; if it does NOT, the lever builds two 8-way 128-bit
barrel shifters.  **ESTIMATE that it folds, with no evidence.**  The
one-line insurance is to write `if SWG_GRP = LANES then lane0 := 0; else ...`
so the branch is an elaboration-time constant and the shifter cannot be
built.  **It was deliberately NOT applied**, because the 46-row mutation
matrix had already been run against the current text and an edit under it
would have made both the matrix and the edit unverified; it is named in
section 8 as the first follow-up.

### 4.4a ADDED LATE: build 10 failed timing, so the area question is live

While this track was running, **card build 10 FAILED TIMING at routed
WNS -5.819 ns with 17,194 failing endpoints on the 75 MHz core clock**
(postmortem at `7e560e9`).  Every worst path runs from one register in
subsystem A's engine to its codebook command replicas, and
`rtl/matvec_core.vhd` has not changed since 2026-08-30, so the cause is
**area displacing that net**, not any lever's logic.

That changes what this write-up owes the reader.  The honest position, with
the generics at their DEFAULTS, is:

- **`SWG_LANES = 1, SWG_WIDE = false` is the shipping configuration and adds
  NOTHING.**  `wgmux` gains one `elsif` arm whose condition is the constant
  `false`, `rgmux` reduces to two wires, `greq` is clocked asserts that
  Vivado drops, and `swiglu_mem`'s `gwide` generate does not elaborate.  A
  build that does not set the generics is not carrying this lever's area.
  That is the property the `S0n` control checks in simulation and the
  `sim:tb_fk33_cardtop_ident` row checks structurally.
- **`SWG_WIDE = true, SWG_LANES = 1` buys 393,280 cycles a token for the
  muxes and ~160 flip-flops and NO lane replication at all.**  If the next
  build needs cycles and cannot afford area, that is the point to take.
- **`SWG_LANES = 8` is where the area is, it is the whole of it, and it is
  unmeasured.**  Given build 10's result, **asking for `SWG_LANES = 8` on
  the next card build without an OOC draw first would be exactly the
  uncontrolled change that failure argues against.**

### 4.5 What would settle the area, in the order that costs least

1. **One OOC synthesis of `fk33_llama_top` at `A_DESC => true`,
   `SWG_REAL => true`, with `(SWG_LANES, SWG_WIDE)` at `(1, false)`,
   `(1, true)`, `(4, true)` and `(8, true)`** -- four points on one
   netlist-generation script, for the LUT / FF / DSP delta and, critically,
   for whether the `lane0` slice folded (check `get_cells -hier -filter
   {REF_NAME =~ MUXF*}` in `gsr`, and the DSP census with `REF_NAME =~ DSP*`
   and NOT `PRIMITIVE_GROUP == DSP`, which matches nothing and warns).
2. Only if that is acceptable, **a routed card pair for WNS**, re-implemented
   from the same synthesised checkpoint so the directive set is held
   constant.

---

## 5. What was applied

### `rtl/swiglu_mem.vhd` -- behind `WIDE_IO : boolean := false`

| site | change |
|---|---|
| generics | `WIDE_IO` added after `LANES` |
| ports | `gw_we`, `gw_addr`, `gw_g`, `gw_u` in, `o_gdata` out, every one with a default so a parent built against the 2026-09-19 entity still elaborates |
| bank write | the two expressions the file had are renamed into `gb_wa`/`gb_wd`/`ub_wa`/`ub_wd` inside a `gnarrow : if not WIDE_IO generate`; a `gwide` arm drives the same four from the group face.  **Exactly one arm elaborates, so neither bank write port grows a mux in either configuration.** |
| bank read | unchanged.  `o_gdata` is the LANES output banks' douts concatenated, addressed by the SAME `o_raddr`; all zeros when `WIDE_IO` is false |

### `rtl/llama_top.vhd` -- behind `SWG_LANES : positive := 1` and `SWG_WIDE : boolean := false`

| # | site | line | change |
|---|---|---|---|
| a | generics | 507-508 | `SWG_LANES`, `SWG_WIDE` |
| b | declarations | 1265-1272 | `CHK_SWG_WIDE` (out-of-range natural, guarded by `boolean'pos(SWG_WIDE)` so it is a property of the configuration ASKED FOR), `SWG_GRP` |
| c | declarations | 1456-1472 | `seq_vec_res`'s read face renamed `vrd_en`/`vrd_addr`; `gsr`'s faces `swr_en`/`swr_addr` and `sw_we`/`sw_addr`/`sw_be`/`sw_data`, declared at the architecture because `gsr` is two generates deep, and tied off at declaration |
| d | `wgmux` | 1745-1772 | a third arm, selected `act_unit = U_V and act_vop = V_SWG`.  `wg_reg` stays `v_reg_d`, which is an identity for this client |
| e | `rgmux` | 1776-1786 | NEW.  The group READ mux, same selection rule.  With `SWG_WIDE` false it reduces to the two wires the file had |
| f | `greq` | 1808-1860 | NEW.  The group ports' one-hot / request-honoured check; see 3.3 |
| g | `u_vres` port map | 2101 | `r_en => vrd_en, r_addr => vrd_addr` |
| h | `gsr` declarations | 3915-3927 | `gw_*`, `o_gd` |
| i | `u_swg` | 3929 | `LANES => SWG_LANES, WIDE_IO => SWG_WIDE`, and the five new actuals.  **The generic was never named before, so `swiglu_mem` has been at LANES 1 since it was written** |
| j | `gsr` S_IDLE | 3993-3999 | `ng := n / SWG_GRP`, exact by `CHK_SWG_WIDE` and the `n = NN` assert |
| k | `gsr` S_RD | 4003-4045 | the one-pass group arm in front of the shipping body, which stays verbatim |
| l | `gsr` S_WR | 4100-4148 | the group write-back arm, same treatment |

### Generated, regenerated, and diffed

`tools/gen_cardtop.py` -> `rtl/fk33_llama_top.vhd` and
`sim/tb_fk33_cardtop_ident.vhd`: `git diff` on each carries this change and
nothing else, and the card's `region_mem` instance already takes `r_en` and
`r_addr` by those names (`gen_cardtop.py:158-159`), so `rgmux` reaches the
card without a generator edit.  `sim/ooc_gdnadapt_extract.py --check` was
already `GDNADAPT_CHECK ok` and stayed so.

**The generics were inserted after `SWG_REAL`, mid-clause, deliberately.**
`gen_cardtop.py:246` anchors its own generic insertion on
`"    B_STATE_AXI : boolean := false\n  );"` -- the LAST generic before the
close -- and its comment says the anchor is fixed rather than a substring
precisely so that it breaks loudly when the clause moves.  Adding at the end
would have broken it.

### New benches

| row | what |
|---|---|
| `sim/tb_swiglu_mem_w8.vhd` | the unit at LANES 8 through the wide face, N = 128 |
| `sim/tb_swiglu_mem_w8_9b.vhd` | the same at N = 12288, the card's shape |
| `sim/tb_llama_top_swgw.vhd` | `tb_llama_top_swg`'s generic map plus `SWG_LANES => 8, SWG_WIDE => true`, carrying its four landmarks UNCHANGED |
| `sim/mutate_swg_wide.sh` | the teeth harness, 46 rows |

`sim/tb_swiglu_mem.vhd` gains `WIDE_IO`, `CHK_GRD`, a wide `load` and a wide
read-out pass against the reference.  `sim/tb_llama_top.vhd` gains two
pass-through generics defaulting to the shipping values.

**`BASELINE_PASS` in `sim/regress.sh` was NOT raised** for the three new
rows.  It is a floor, so the gate stays green either way; `sim/regress.sh`
is owned by TRACK PATHFREE this session and CLAUDE.md forbids editing it
under a live gate.  The next full unfiltered gate should raise it by 5
(DSIDE's `tb_region_drain`, WIDEDRAIN's `tb_llama_top_wdrain`, and these
three) and quote that run.

---

## 6. The mutation table

MEASURED by `bash sim/mutate_swg_wide.sh`, 46 rows plus an 11-row re-run,
`ghdl-mcode`, `sim/tb_llama_top.vhd` at `tb_llama_top_swg`'s generics over
three tokens.  Every mutation is one anchored substitution in
`rtl/llama_top.vhd` applied in a scratch copy, with a REQUIRED occurrence
count of 1 so a partial edit is an error and not a verdict.

**RUN OUT OF A SNAPSHOT, NOT THE REPO, and 7.1 says why.**
`/mnt/storage/fk33_builds/scratch/gsrwide/tree` is `rtl/ sim/ tb/ tools/`
copied once, with the four MIDGAP-owned attention files restored from
`git show HEAD:` so the tree is HEAD-plus-this-track:
`rtl/attn_block.vhd` md5 `12c2c80e1fbfdc525cb853748ea28127`,
`rtl/llama_top.vhd` md5 `ee0416cfa056da5cc45992de0e73a801`, both verified
unchanged after the run.

**THREE OR FOUR CONTROLS PER ROW:**

- `_N` -- the same mutation with **`SWG_WIDE` FALSE and `SWG_LANES` STILL 8**.
  One variable.  If it bites, `sim:tb_llama_top_swg` catches it already.
- `_X` -- the same mutation, wide, with the four landmarks **UNSET**.  If it
  bites, the kill is a STRUCTURAL property, not the value gate.
- `_Q` -- the same mutation at **`SWG_LANES = 4`**, the sub-group geometry
  where `lane0` is not identically zero and `w_be` genuinely masks.  Present
  on every row whose mutation is a NO-OP at `SWG_GRP = LANES`.
- `_G` -- mux rows only: wide, landmarks unset, **`greq` disabled whole**.
  The attribution control for the new check.

| mutant | what | GRP 8 | `_N` | `_X` | GRP 4 (`_Q`) | who actually killed it |
|---|---|---|---|---|---|---|
| `S0w` | CONTROL, clean, GRP 8 wide | SURVIVED 75,405 cyc | -- | -- | -- | clean passes |
| `S0n` | CONTROL, clean, LANES 8 narrow | SURVIVED 79,653 cyc | -- | -- | -- | clean passes |
| `S0q` | CONTROL, clean, GRP 4 wide | -- | -- | -- | SURVIVED 76,173 cyc | clean passes |
| `M1_be_tail` | `w_be` enabled ONE ELEMENT past the vector | **SURVIVED** | SURVIVED | SURVIVED | **SURVIVED** | **nobody, at either geometry -- see below** |
| `M2_be_all` | the lane mask removed entirely | **SURVIVED** | SURVIVED | SURVIVED | KILLED(ABORT) | at GRP 8 a NO-OP; at GRP 4 the SIMULATOR's constrained range on the `o_gd` slice |
| `M3_rd_stride` | the group READ address drops the `SWG_GRP/LANES` stride | **SURVIVED** | SURVIVED | SURVIVED | **KILLED** | at GRP 8 a NO-OP; at GRP 4 **the value gate** |
| `M4_wr_stride` | the group WRITE address drops the stride | **SURVIVED** | SURVIVED | SURVIVED | **KILLED** | at GRP 8 a NO-OP; at GRP 4 **the value gate** |
| `M5_gw_addr` | `gw_addr` drops the `SWG_GRP` factor: every beat writes `swiglu_mem` bank offset `k-2` | **KILLED** | SURVIVED | SURVIVED | -- | **the new row's value gate, and only it** |
| `M6_lane_skew` | the `x_rdata` lane slice skewed one mantissa | KILLED(ABORT) | SURVIVED | KILLED(ABORT) | -- | the SIMULATOR's constrained range, not the gate |
| `M7_swap_gu` | `gw_u` fed from `x_rdata`: U is loaded with G | **KILLED** | SURVIVED | SURVIVED | -- | **the new row's value gate, and only it** |
| `M8_region_tag` | `wg_reg` reads `aw_reg` in the SwiGLU arm | KILLED(ABORT) | SURVIVED | KILLED(ABORT) | -- | `llama_top`'s OWN region lock: *"the region lock DROPPED a write to region 0"* at 6,183,500 ps |
| `M9_wmux_sel` | the group WRITE mux selects on `act_unit` alone | KILLED(ABORT) | SURVIVED | KILLED(ABORT) | `_G` KILLED(ABORT) | **`greq` (c)** at 5,087,500 ps.  See below |
| `M10_rmux_sel` | the group READ mux selects on `act_unit` alone | KILLED(ABORT) | SURVIVED | KILLED(ABORT) | `_G` KILLED(ABORT) | **`greq` (c)** at 5,061,500 ps.  See below |
| `M11_last_beat` | the write-back ends one beat early (`kw = ng-2`) | **KILLED** | SURVIVED | SURVIVED | -- | **the new row's value gate, and only it** |
| `M12_ora_stride` | `o_ra` drops the `SWG_GRP` factor on the read-back | **KILLED** | SURVIVED | SURVIVED | -- | **the new row's value gate, and only it** |
| `M13_ng` | `ng` computed from `LANES` rather than `SWG_GRP` | **SURVIVED** | SURVIVED | SURVIVED | **KILLED** | at GRP 8 a NO-OP; at GRP 4 **the value gate** |

### 6.1 `greq` HAD NO TEETH AS FIRST WRITTEN, and the control is what showed it

**This is the most useful row in the table and it is about the check, not
about the RTL.**  `greq` was written for exactly the mux-selector defect, and
in its first form -- properties (a) and (b), each client's request against
`greq`'s own copy of the selection rule -- **it stayed completely silent on
both `M9_wmux_sel` and `M10_rmux_sel`.**  MEASURED: both were killed by
`tb_llama_top`'s P4 (*"R_X is unchanged after a whole token"*) at
75,405,500 ps, and the `_G` controls, with `greq` disabled whole, produced
the IDENTICAL kill at the IDENTICAL instant.  A check credited with a kill an
existing property would have made anyway is not worth its maintenance.

**Why it was silent is the reusable part.**  A mutation IN THE MUX leaves
`greq`'s copy of the rule intact and correct, so `greq` looks at
`seq_vec_res` requesting during a residual op, agrees that it should be
selected, and says nothing -- while the mux hands the port to somebody else.
**A guard that duplicates the rule cannot see the implementation diverge from
it.**  This is the recorded *"a teeth test whose mutant is built from the
same misconception as the check"* trap turned inside out: here the CHECK and
the THING share a premise instead, and the mutant lands on only one of them.

Property (c) was then added: name the one client that is requesting, and
assert that **the port is carrying that client's beat**.  It reads the mux
OUTPUT and carries no copy of the rule at all.  Re-MEASURED on the same
mutants and the same controls:

```
M9_wmux_sel     llama_top:1886 @5087500ps  (assertion failure):
   seq_vec_res was the only client requesting the group WRITE port and the
   port is not carrying its beat.  The mux honoured somebody else.
M9_wmux_sel_X   the same, at the same instant   (so it is structural, not the value gate)
M9_wmux_sel_G   tb_llama_top:2742 @75405500ps -- P4, "computed nothing"

M10_rmux_sel    llama_top:1906 @5061500ps  (assertion failure):
   seq_vec_res was the only client requesting the group READ port and the
   port is not carrying its address.
M10_rmux_sel_G  tb_llama_top:2756 @75344500ps -- "the residual stream is very
   nearly a constant, which passes every determinism property and means nothing"
```

**What (c) buys, stated rather than claimed:** the defect is found **14.8x
earlier in simulated time** and **the message names the port and the
client**, where P4 says only that the machine computed nothing.  It does NOT
buy a detection P4 would have missed.  That is a smaller claim than "a new
guard caught a new class", and it is the one the controls support.

The three clean controls were re-run against (c) and all three still SURVIVE
with the four landmarks unchanged, so (c) does not fire on a correct design.
**The other 35 rows were NOT re-run**, deliberately and with the reason
stated: (c) fires only when a client's request is not carried by the port,
the port is driven by the two muxes, and no other mutation in this table
touches a mux.  A row could only change from SURVIVED to KILLED, and none can.

### 6.2 The rows that do NOT bite, under their own names

- **`M1_be_tail` survives at BOTH geometries, and that is correct.**  It
  enables one lane past `n`.  That lane can only exist when `n` is not a
  multiple of `SWG_GRP`, and **no configuration that elaborates can present
  one**: `swiglu_mem` pins `N mod LANES = 0` at elaboration and `gsr`
  asserts `n = NN` at issue.  This is STRONGER than WIDEDRAIN's equivalent
  finding, where the case was absent from the shipping schedule but not
  forbidden by the design.  The tail term in `w_be` is kept anyway, because
  the thing it guards -- a write to elements nobody reads -- is invisible to
  every value landmark and visible only to `EXP_STEPH`.
- **`M2`, `M3`, `M4` and `M13` are NO-OPS at `SWG_GRP = LANES`.**  At the
  card's geometry `(k*SWG_GRP)/LANES` IS `k`, `((k-2)*SWG_GRP) mod LANES` IS
  0, and `i >= lane0 and i < lane0+SWG_GRP` is true for every lane, so these
  are textually different programs that compute the same thing.  **Reporting
  them as SURVIVED without the `_Q` geometry would have measured nothing**;
  three of the four bite at `SWG_LANES = 4` and the fourth (`M2`) dies on a
  range error there.
- **`M6_lane_skew` and `M2_be_all_Q` are range errors, not value checks.**
  Real kills -- GHDL stops -- but they were caught by a constrained slice
  bound, which is the same discipline `ga_real`'s "NO CLAMP on `rword`"
  comment already relies on, and NOT by anything this track added.
- **`M8_region_tag` is killed by an EXISTING guard, and that is the cheapest
  possible outcome.**  `_N` survives, so the defect does not exist until the
  SwiGLU drives the group port; `_X` bites, so it is the region lock and not
  the value gate.  The lever creates the hazard and a guard the file already
  had catches it.  Worth recording as such rather than as a new detection.

### 6.3 What the new gate row's value check actually earned

**Four unshared kills: `M5_gw_addr`, `M7_swap_gu`, `M11_last_beat`,
`M12_ora_stride`.**  Each has `_N` SURVIVED (unreachable without the lever)
and `_X` SURVIVED (no structural property sees it), so
`sim:tb_llama_top_swgw` is the only thing in the tree that catches them.
Three of the four are addressing faults inside `swiglu_mem`'s bank offset or
the output read-back -- exactly the class a wide port invites -- and the
fourth loads U with G.

---

## 7. Measurement traps hit

- **ANOTHER TRACK'S EDIT VOIDED 27 OF 46 MUTATION ROWS, AND IT LOOKED
  EXACTLY LIKE A MUTATION RESULT.**  The harness analyses ~60 files once
  into a base library and copies it per row.  TRACK MIDGAP wrote
  `rtl/attn_block.vhd` at 16:18:30 and `rtl/attn_score_q12.vhd` a while
  later, and GHDL's timestamp check then invalidated the base library
  underneath a running matrix.  The FIRST failure mode was loud --
  `DID NOT ANALYZE` on 27 consecutive rows, whose message says outright that
  a mutation that will not compile has tested nothing.  **The SECOND was
  not.**  After the base was rebuilt, the second file changed mid-run and
  every row from `M7_swap_gu_N` onward reported `KILLED(ABORT)` -- including
  `_N` controls whose mutated text is unreachable with `SWG_WIDE` false and
  which therefore CANNOT be killed.  A table copied from that log would have
  credited this track's gate with twenty kills it did not make.  The tell was
  a control that must survive and did not, not anything in the verdict
  column.
  **The fix was to snapshot `rtl/ sim/ tb/ tools/` into the scratch
  directory and run the harness out of the snapshot**, with the
  MIDGAP-owned files restored from `git show HEAD:` so the tree is
  HEAD-plus-this-track and the clean control's landmark match means
  something.  Both md5s are recorded in the write-up.  CLAUDE.md already
  says *"a full-gate run showing many failures in files you cannot have
  touched is MACHINE CONTENTION"*; this is the same thing for a mutation
  matrix, where the symptom is a KILL rather than a FAIL and therefore reads
  as success.
- **FOUR MUTANTS ARE NO-OPS AT THE CARD'S GEOMETRY BY CONSTRUCTION, AND
  SURVIVING IS THE CORRECT ANSWER FOR ALL FOUR.**  At `SWG_GRP = LANES = 8`,
  `(k*SWG_GRP)/LANES` IS `k`, `((k-2)*SWG_GRP) mod LANES` IS 0, and
  `i >= lane0 and i < lane0+SWG_GRP` is true for every lane.  So the
  stride mutants and the mask mutants are textually different programs that
  compute the same thing.  **Reporting them as SURVIVED without the second
  geometry would have measured nothing and looked like a resolution floor**;
  the `_Q` rows at `SWG_LANES = 4` are what give them teeth, and they are in
  the table under their own names.
- **A `_N` CONTROL THAT ALSO MOVES `SWG_LANES` IS ON TWO AXES.**  The
  obvious narrow control is `SWG_LANES = 1, SWG_WIDE = false`, which is the
  shipping configuration -- and it changes the unit's lane count as well as
  the port face, so a kill could belong to either.  Every `_N` here holds
  `SWG_LANES` at 8 and moves only `SWG_WIDE`.  This is CLAUDE.md's recorded
  `c4nd`/`c4kv4` error, which had good controls on the wrong axis.
- **The verdict grep in the harness matched prose.**  The row printer greps
  the run log for `group WRITE port|group READ port|region lock` to name the
  guard that fired, and `rtl/llama_top.vhd`'s own comments contain those
  words, so every row printed a `GUARD:` line quoting a comment.  Harmless
  here because the verdict comes from the `RESULT:` line, but it is the same
  shape as the recorded `C4_DONE` self-match: a haystack that contains the
  needle.  The guard messages quoted in section 6 were read from the run
  logs by their full sentences, not by that grep.
- **`SWGFAST_CYCLES` at LANES = 8 was quoted by three documents as an
  extrapolation and is now a measurement, and it agreed.**  That is worth
  recording as a trap avoided rather than one hit: `2*NB + 13` was fitted to
  three points and CLAUDE.md records two tracks that read scatter as slope.
  It happens to be structural here -- the schedule is `NB` beats per pass
  plus a fixed pipeline -- but nothing in the law said so, and the only
  reason it is now known is that it was measured.

## 8. Open, not determined

- **Every area and timing figure.**  Nothing here has been synthesised,
  placed or routed.  Section 4.4's LUT, FF and DSP numbers are arithmetic
  over widths; section 4.5 names the draw that settles them.
- **Whether the `lane0` slice folds at `SWG_GRP = LANES`.**  ESTIMATE yes,
  no evidence.  If it does not, the lever builds two 8-way 128-bit barrel
  shifters and the area conclusion inverts.  The one-line insurance is named
  in 4.4 and was deliberately not applied under a running matrix; it is the
  first follow-up and it needs a re-run of `S0w`, `S0q` and
  `sim:tb_llama_top_swgw`, not of the whole matrix, because it changes the
  value of `lane0` in no configuration.
- **`swiglu_mem`'s DSP cost at LANES = 8.**  Two ESTIMATEs exist, DSIDE's
  +16 DSP per lane and this track's +8 from the 32x32 decomposition, and
  they differ by 2x.  **Neither has been drawn, and the difference decides
  whether LANES = 8 fits.**  `SWG_LANES` is a dial precisely so this can be
  answered after the fact.
- **The partial final group and the misaligned group are UNREACHABLE, and
  this is stronger than WIDEDRAIN's version of the same statement.**  There
  `dst_off` and `n_rows` happened to be multiples of the group in the
  shipping plan, which is a property of the schedule.  Here `swiglu_mem`
  pins `N mod LANES = 0` at elaboration and `gsr` asserts `n = NN` at issue,
  so no configuration that elaborates can present one.  `M1_be_tail` and
  `M2_be_all` therefore survive at BOTH geometries, under their own names,
  and the tail term in `w_be` is a guard for a case the design cannot reach.
  **It is kept anyway**, because a lane enabled past `n` writes elements
  nobody reads, which no value landmark can see and only `EXP_STEPH` can.
- **The card's 14-cycle `VEC_SWG` residual** is carried through every row
  and is still unattributed.  It is DSIDE's open item, not this track's, and
  it is the same 14 that appears on `VEC_NORM`.
- **`ga_desc`'s and `gsr`'s wide arms have never been simulated TOGETHER.**
  `A_DRAIN_WIDE` and `SWG_WIDE` both drive the group write port through
  `wgmux`, and `greq`'s first property is exactly the assertion that they
  never collide.  Every row here has `A_DRAIN_WIDE` false.  **The
  three-client case is checked by a guard and not by a run**, and the cheap
  closure is one more bench row with both generics true.
- **`wcollide` with a host write during a SwiGLU op.**  Unchanged from
  WIDEDRAIN's entry and still MEASURED `both = 0` with every host write
  before `go`.  A second reachable source of the same untested case.
- **L4 (`gvr` on the group ports, 465,920 cycles) is untouched.**
  `rmsnorm_bf_mem` needs the same pair of wide faces `swiglu_mem` just grew,
  and `rgmux`/`wgmux` now have the shape a fourth client plugs into.  L3
  and L5 likewise.

---

## 9. Gate rows, verbatim

MEASURED by `bash sim/regress.sh --only <pat> --jobs 1`, every group run
AFTER the last edit to the tree.

**md5 bracketing, because this session had four tracks in the same
directory.**  Recorded at the start of the run and again at the end, and
they MATCHED for every file these rows compile that this track owns or
edited:

```
91f5619ad8796867bf6e23c077906992  sim/regress.sh          (NOT edited by this track)
ee0416cfa056da5cc45992de0e73a801  rtl/llama_top.vhd
acd8e05a50eabcf8d24c81dd70c5f7b4  rtl/swiglu_mem.vhd
c55b377b06473efd70d515a7ab552c5b  rtl/fk33_llama_top.vhd
1a165d6a3e15a2c7465273cdc468d5cd  sim/tb_swiglu_mem.vhd
b5efd136f7969815fa70fc87498db528  sim/tb_llama_top.vhd
fb67d52b5e42ba1ee855ea7eb44048cc  sim/tb_llama_top_swgw.vhd
b4b6e7bf244e0aec54a59b0df4ffd394  sim/tb_swiglu_mem_w8.vhd
4b25dadcdfa3d5201debb7b606208ceb  sim/tb_swiglu_mem_w8_9b.vhd
a530acbe0f56e1e64381121931833d30  sim/tb_fk33_cardtop_ident.vhd
```

```
##### --only tb_swiglu_mem
 OVERALL     PASS 4   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only tb_llama_top_swg
 OVERALL     PASS 2   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only seamgate_swg
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only tb_llama_top
 OVERALL     PASS 14   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only cardtop
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only gdnstale
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
##### --only fk33card
 OVERALL     PASS 1   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

The fourteen `tb_llama_top` rows include the new `sim:tb_llama_top_swgw`
beside `sim:tb_llama_top_real` and WIDEDRAIN's `sim:tb_llama_top_wdrain`;
the four `tb_swiglu_mem` rows are `sim:tb_swiglu_mem`, `sim:tb_swiglu_mem_9b`
and the two new wide rows.  `sim:tb_fk33_cardtop_ident` inside `cardtop` is
the generated identity bench, so `fk33_llama_top` with both generics at
their defaults is still bit-identical to `llama_top`.  `sim:seamgate_swg` is
the independent Python oracle (`tools/ref9b/vec_oracle.swg_real`, held to
`ref/run_fx.c` by `tools/ref9b/check_swg_real.py`) that cleared the four
landmarks this track reuses.

## 10. A note for whoever writes the next anchor into this file

TRACK REANCHOR measured that `gsr`'s write-back FSM and `gvr`'s were, at
HEAD, **textually identical except for the comment above them**, which took
`if rav_d = '1' then` from one match to two and silently killed four
mutation rows across two harnesses.  **This track's edit makes them
different**: `gsr`'s `S_WR` now opens `if SWG_WIDE then` and carries a
`sw_*`/`o_gd` arm that `gvr` has no counterpart for.  That is a side effect
and not a fix, and REANCHOR's generate-header scoping is still the right
rule -- `sim/mutate_swg_wide.sh` does not rely on it only because every
anchor it uses is inside the new arm and it asserts an occurrence count of
exactly 1 on each, which is the cheap form of the same discipline.
