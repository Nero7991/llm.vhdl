# hw/jc/link -- the Jungle Cat die-to-die Aurora 64B66B link (plan 2026-11-04 Task 5)

TX/RX-simplex Aurora 64B66B core configuration, its tie table and wrapper generator, the GTGREFCLK
MMCM (`jc_gtg_clk`) and its netlist ECO, and the xsim link bench. No hardware is touched here.

## Produces (for Tasks 6 and 7)

- `aurora_cfg.tcl`: `JC_LANES`, `jc_aurora_config nlanes rate mode`, `jc_lane_txpol`,
  `jc_init_div rate`, `jc_init_clk_mhz rate`, `JC_REFCLK_PINS`, `jc_refclk_choice`,
  `jc_aurora_refclk obj`, `jc_aurora_check obj cfg`.
  - `jc_aurora_refclk` is a FIXED pick plus readback (sets C_REFCLK_SOURCE, reads it back,
    errors `AURORA_CFG_FAIL` on refusal or mismatch, returns the value). Call it AFTER the
    `jc_aurora_config` dict is applied: the choice list depends on C_UCOLUMN_USED/C_START_QUAD.
- `aurora_ties.py`: `MAPPED`, `MAPPED_OUT`, `TIES`, `CONST`, `ZERO_OK`, `tie_value`.
  `MAPPED` maps BOTH `tx_reset_pb` and `rx_reset_pb` to the wrapper's `reset_pb` (TX/RX_Simplex
  has no `reset_pb` pin). In the BD, Task 7 must connect `aur_reset_pb` to both IP pins.
- `rtl/jc_aurora_wrap_l1.vhd`, `rtl/jc_aurora_wrap_l4.vhd` (generated): ports as the brief.
- `rtl/jc_gtg_clk.vhd`: generics `POR_LOG2` (8), `INIT_DIV` (10); ports `sys_i` -> `sclk`
  (200 MHz fabric BUFG), `gtg_clk` (156.25 MHz), **`init_clk`** (1250 / INIT_DIV MHz, CLKOUT1,
  BUFG), `locked`. **`init_clk` of the Aurora core is `jc_gtg_clk.init_clk`, not `sclk`**
  (coordinator ruling 2, 2026-11-10). `INIT_DIV` is `jc_init_div <rate>`: 10 (125 MHz) at
  10.3125 Gb/s, 80 (15.625 MHz) at 1.25 Gb/s; `C_INIT_CLK` is set to match by `jc_aurora_config`.
- `eco_aurora_gtg.tcl`: retargets the QPLL the core runs (QPLL1 at 10.3125, see below) to
  GTGREFCLK; `^ECOA_DONE commons=<n>`, errors `^ECOA_FAIL`.
- **XDC patterns for Task 7 (corrected, see ECO check):**
  `set_property LOC MMCM_X0Y2 [get_cells -hier -filter {NAME =~ *gtgclk/*u_mmcm}]` and
  `set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets -of_objects [get_pins -hier -filter {NAME =~ *gtgclk/*u_mmcm/CLKIN1}]]`
  (the plan's `*gtgclk/u_mmcm` form matches nothing in a BD). The refclk pins are
  `PACKAGE_PIN AK38` (`gt_refclk_clk_p`), not AC36.
- A BD module reference of `jc_gtg_clk` needs its file typed plain `VHDL`, not `VHDL 2008`
  (MEASURED, filemgmt 56-195).

## Commands

Build root `/mnt/storage/fk33_builds/jc_link_t5/` (scripts `run_ip.sh`, `run_perm2.sh`,
`run_eco_mut.sh`, `run_sims.sh` there; each sources Vivado 2023.2 `settings64.sh` and runs
under `systemd-run --user --scope -p MemoryHigh=8G -p MemoryMax=10G` with `R` = this worktree).

```bash
# Step 3: IPs (l1, l4 sim; l1card, l1slow card; l4perm, l4permchk mutants)
vivado -mode batch -source hw/jc/link/gen_aurora_ip.tcl -tclargs <B>/l1 1 10.3125 sim
vivado -mode batch -source hw/jc/link/gen_aurora_ip.tcl -tclargs <B>/l4 4 10.3125 sim
vivado -mode batch -source hw/jc/link/gen_aurora_ip.tcl -tclargs <B>/l1card 1 10.3125 card
vivado -mode batch -source hw/jc/link/gen_aurora_ip.tcl -tclargs <B>/l1slow 1 1.25 card
JC_AUR_MUTATE=permute       vivado ... -tclargs <B>/l4perm 4 10.3125 sim
JC_AUR_MUTATE=permute_check vivado ... -tclargs <B>/l4permchk 4 10.3125 sim
python3 hw/jc/link/gen_aurora_wrap.py <B>/l1/jc_aurora_stub.vhdl 1 hw/jc/link/rtl/jc_aurora_wrap_l1.vhd
python3 hw/jc/link/gen_aurora_wrap.py <B>/l4/jc_aurora_stub.vhdl 4 hw/jc/link/rtl/jc_aurora_wrap_l4.vhd
# Step 5: ECO check (and its mutant)
JC_ECO_MUTATE=qpll0 vivado -mode batch -source hw/jc/link/eco_check.tcl -tclargs <B>/l1card <B>/eco_check_mut
vivado -mode batch -source hw/jc/link/eco_check.tcl -tclargs <B>/l1card <B>/eco_check
# Step 7: xsim
bash hw/jc/link/run_aurora_sim.sh <B>/l1 1 0 <B>/sim_l1
bash hw/jc/link/run_aurora_sim.sh <B>/l4 4 0 <B>/sim_l4
bash hw/jc/link/run_aurora_sim.sh <B>/l4 4 1 <B>/sim_l4p
```

## MEASURED records (2026-11-10, Vivado 2023.2, xcvu35p-fsvh2104-2L-e)

### What the IP refused in the brief's configuration (first run, `run1_refclk_fail/`)

- `MGTREFCLK1_of_Quad_X0Y2` (AC36): `ERROR: [IP_Flow 19-3461] ... Valid values are -
  MGTREFCLK0_of_Quad_X0Y0, MGTREFCLK1_of_Quad_X0Y0` (only the start quad's own refclks).
- `list_property_value CONFIG.C_REFCLK_SOURCE` returns `{}` for this IP (rc 0).
- `C_INIT_CLK 200.0`: `ERROR: [IP_Flow 19-3488] ... out of the range (3.125,161.132812000000001)`
  at 10.3125 and `(3.125,19.53125)` at 1.25 (line_rate / 64).
- `C_START_QUAD Quad_X0Y0`, `C_START_LANE X0Y0` refused until `C_UCOLUMN_USED left` (default
  right, X1 sites). `C_REFCLK_FREQUENCY 156.250` refused, `156.25` accepted.
- `drp_mode Disabled` refused: `Valid values are - AXI4_LITE, Native`. The AXI4-Lite DRP slave
  stays and is tied idle (`aurora_ties.py`; per-lane `_laneN` copies at NLANES 4).
- TX/RX_Simplex has `tx_reset_pb`/`rx_reset_pb`, no `reset_pb` (component.xml port enablement).

### Refclk (coordinator ruling 1)

Nominal refclk `MGTREFCLK0_of_Quad_X0Y0`; the gtg ECO moves the running QPLL to GTGREFCLK, so the
pin refclk is never used (the method IBERT G measured on 2026-11-04). Package pins from the
device data (`get_package_pins`, probe `pins.tcl`):

```
PINS pkg AK39 func=MGTREFCLK0N_124 bank=124 diffpair=AK38 site=GTYE4_COMMON_X0Y0
PINS pkg AK38 func=MGTREFCLK0P_124 bank=124 diffpair=AK39 site=GTYE4_COMMON_X0Y0
PINS pkg AC36 func=MGTREFCLK1P_126 bank=126 diffpair=AC37 site=GTYE4_COMMON_X0Y2
```

**AK38/AK39 are UNDRIVEN on the Jungle Cat board** (the board refclk is AC36, MGTREFCLK1 of
bank 126). They only give the IP's `IBUFDS_GTE4_refclk1` a legal site. Whether an undriven
IBUFDS_GTE4 raises a DRC or an opt problem is NOT yet known: the ECO check is out-of-context
and never reaches I/O DRCs. Task 7's full build is the first place it can show.

l1card readback (`l1card.log`):

```
AURORA_REFCLK want=MGTREFCLK0_of_Quad_X0Y0 got=MGTREFCLK0_of_Quad_X0Y0
AURORA_CFG CONFIG.C_UCOLUMN_USED=left
AURORA_CFG CONFIG.dataflow_config=TX/RX_Simplex
AURORA_CFG CONFIG.interface_mode=Framing
AURORA_CFG CONFIG.crc_mode=false
AURORA_CFG CONFIG.flow_mode=None
AURORA_CFG CONFIG.C_AURORA_LANES=1
AURORA_CFG CONFIG.C_LINE_RATE=10.3125
AURORA_CFG CONFIG.C_REFCLK_FREQUENCY=156.25
AURORA_CFG CONFIG.C_INIT_CLK=125.000
AURORA_CFG CONFIG.SupportLevel=1
AURORA_CFG CONFIG.TransceiverControl=true
AURORA_CFG CONFIG.RX_EQ_MODE=AUTO
AURORA_CFG CONFIG.INS_LOSS_NYQ=20
AURORA_CFG CONFIG.C_START_QUAD=Quad_X0Y0
AURORA_CFG CONFIG.C_START_LANE=X0Y0
AURORA_CFG CONFIG.C_EXAMPLE_SIMULATION=false
AURORA_CFG CONFIG.C_GT_LOC_1=1
AURORA_CFG CONFIG.C_REFCLK_SOURCE=MGTREFCLK0_of_Quad_X0Y0
AURORA_LOCS GTYE4_CHANNEL_X0Y0 {gen_channel_container[0].gen_gtye4_channel_inst[0]}
AURORA_IP_OK nlanes=1 rate=10.3125 mode=card refclk=MGTREFCLK0_of_Quad_X0Y0 out=/mnt/storage/fk33_builds/jc_link_t5/l1card
```

l1slow accepted `C_INIT_CLK=15.625` (`AURORA_IP_OK nlanes=1 rate=1.25 mode=card ...`).
l4: `AURORA_LOCS GTYE4_CHANNEL_X0Y0 {..inst[0]} GTYE4_CHANNEL_X0Y1 {..inst[1]} GTYE4_CHANNEL_X0Y2 {..inst[2]} GTYE4_CHANNEL_X0Y3 {..inst[3]}`.

GT LOC format the IP writes (`ip_0/synth/jc_aurora_gt.xdc`, three levels under the `.gen`
IP directory, not under `IP_DIR`):
`set_property LOC GTYE4_CHANNEL_X0Y0 [get_cells -hierarchical -filter {NAME =~ *gen_channel_container[0].*gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]`.

`AURORA_GTG_SOURCES` (l1card): `ip_0/sim/jc_aurora_gt_gtwizard_gtye4.v` (upper-case match only).
The select is a constant in `ip_0/synth/jc_aurora_gt.v`: `.qpll0pd_in(1'H1)`,
`.qpll0refclksel_in(3'H1)`, `.qpll1pd_in(1'H0)`, `.qpll1refclksel_in(3'H1)`,
`.gtgrefclk0_in(1'H0)`, `.gtgrefclk1_in(1'H0)`; `ip_0/jc_aurora_gt.xci`: TX/RX_PLL_TYPE
**QPLL1**, LOCATE_COMMON EXAMPLE_DESIGN. l1slow (1.25 Gb/s): TX/RX_PLL_TYPE **CPLL**,
LOCATE_COMMON CORE, no GTYE4_COMMON in its netlist.

Lane-map mutants: `l4perm` (IP lane map rotated): the IP ignores the rotated C_GT_LOC map and
reads back 1 2 3 4, so it dies in the readback:
`AURORA_CFG_FAIL readback: {CONFIG.C_GT_LOC_1=1 (asked 2)} ... {CONFIG.C_GT_LOC_4=4 (asked 1)}`.
`l4permchk` (table rotated against the IP): `AURORA_CFG_FAIL lane map: lane 0 at GTYE4_CHANNEL_X0Y0, table says GTYE4_CHANNEL_X0Y1`.

### ECO check (`eco_check.log`)

The core runs **QPLL1** (QPLL0 powered down), so the ECO now picks the QPLL whose QPLL<q>PD is
not tied high and retargets GTGREFCLK<q>/QPLL<q>REFCLKSEL; the plan's fixed GTGREFCLK0/QPLL0
form would have rewired the powered-down PLL. `eco_check.tcl` reads the PLL the channels use
from their TXPLLCLKSEL/RXPLLCLKSEL ties, independently of the ECO.

```
ECOA_PD .../common_inst/gtye4_common_gen.GTYE4_COMMON_PRIM_INST QPLL0PD POWER
ECOA_PD .../common_inst/gtye4_common_gen.GTYE4_COMMON_PRIM_INST QPLL1PD GROUND
ECOA_CONN QPLL1 .../GTYE4_COMMON_PRIM_INST/GTGREFCLK1 old=.../common_inst/<const0> new=.../common_inst/gclk
ECOA_SEL ... QPLL1 b0 was POWER now POWER
ECOA_SEL ... QPLL1 b1 was GROUND now POWER
ECOA_SEL ... QPLL1 b2 was GROUND now POWER
ECOA_DONE commons=1 loads=1
ECOCHK_CHAN ...gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST TXPLLCLKSEL=10 RXPLLCLKSEL=10
ECOCHK ...GTYE4_COMMON_PRIM_INST channels on QPLL1 GTGREFCLK1 <- gtgclk/u_gbg (BUFGCE)
ECOCHK post_opt ...GTYE4_COMMON_PRIM_INST GTGREFCLK1 <- gtgclk/u_gbg (BUFGCE) sel=POWER POWER POWER
ECOCHK_PINS AK38=MGTREFCLK0P_124 AK39=MGTREFCLK0N_124
ECOCHK_XDC flat PLAN mmcm_cells=1 clkin_pins=1
ECOCHK_XDC flat FIXED mmcm_cells=1 {gtgclk/u_mmcm} clkin_pins=1 {gtgclk/u_mmcm/CLKIN1} all_mmcm={gtgclk/u_mmcm} refs={MMCME4_ADV}
ECOCHK_XDC bd PLAN mmcm_cells=0 clkin_pins=0
ECOCHK_XDC bd ECO_PIN 1 {bdchk_i/gtgclk/inst/u_gbg/O}
ECOCHK_XDC bd FIXED mmcm_cells=1 {bdchk_i/gtgclk/inst/u_mmcm} clkin_pins=1 {bdchk_i/gtgclk/inst/u_mmcm/CLKIN1} ...
ECOCHK_XDC bd LOC=MMCM_X0Y2 pin_CDR=BACKBONE net=bdchk_i/gtgclk/inst/sclk net_CDR=BACKBONE driver=bdchk_i/gtgclk/inst/u_sbg
ECOCHK_XDC_RESULT flat=1 bd=1
ECOCHK_OK
```

(`...` abbreviates `u_aur/u_core/inst/ultrascale_gt_common_1/jc_aurora_gt_gtye4_common_wrapper_i/common_inst`
or the channel's path; full lines in `/mnt/storage/fk33_builds/jc_link_t5/eco_check.log`.)

Teeth: `JC_ECO_MUTATE=qpll0` (the plan's original GTGREFCLK0/QPLL0REFCLKSEL target) completes
the ECO (`ECOA_DONE commons=1 loads=1`) and is KILLED by the channel-side check
(`eco_check_mut.log`):
`ECOCHK_FAIL .../GTYE4_COMMON_PRIM_INST GTGREFCLK1 not from a BUFG`.

MMCM pin path (coordinator ruling 4): flat netlist `gtgclk/u_mmcm` (MMCME4_ADV); BD
module-reference netlist `bdchk_i/gtgclk/inst/u_mmcm`: an `inst` level, not `U0`. The plan's
`*gtgclk/u_mmcm` and `*gtgclk/u_mmcm/CLKIN1` match 0 cells / 0 pins in the BD; the corrected
`*gtgclk/*u_mmcm` forms match exactly one in both. The ECO pin `*gtgclk/*u_gbg/O` matches
`bdchk_i/gtgclk/inst/u_gbg/O`. On the pin form, `CLOCK_DEDICATED_ROUTE` reads back on the
pin but the net reads empty, so the net form (IBERT G's) is the one to emit; whether the placer
honours either was not tested (no placement here).

### xsim (Step 7)

```
AURSIM_PASS tb_jc_aurora_link NLANES=1 PERM=0 checks=27    /mnt/storage/fk33_builds/jc_link_t5/sim_l1/prj/s.sim/sim_1/behav/xsim/simulate.log  ($finish at 141.97 us)
AURSIM_PASS tb_jc_aurora_link NLANES=4 PERM=0 checks=27    /mnt/storage/fk33_builds/jc_link_t5/sim_l4/prj/s.sim/sim_1/behav/xsim/simulate.log  ($finish at 142.40 us)
AURSIM_FAIL tb_jc_aurora_link NLANES=4 PERM=1 errors=2     /mnt/storage/fk33_builds/jc_link_t5/sim_l4p/prj/s.sim/sim_1/behav/xsim/simulate.log
  Error: tb_jc_aurora_link: frame 0: frame arrived
  Error: tb_jc_aurora_link: frame after B reset: frame arrived (resent once if the first send was eaten by the reset resync)
```

The PERM=1 mutant (lanes rotated between A's TX and B's RX) is killed by the bench itself: B's
`rx_channel_up` still rose, but no frame arrived. The bench's init_clk is 125 MHz (INIT_DIV 10,
C_INIT_CLK 125 in the l1/l4 IPs).

## The simplex RX-after-TX question

MEASURED (xsim, NLANES 1 and 4, 10.3125 Gb/s, C_EXAMPLE_SIMULATION true): resetting B's core
alone (reset_pb high 2 us) while A keeps transmitting, B's `rx_channel_up` comes back
("B rx_channel_up again with A already up" passed), the drop is counted (`link_downs >= 1`), A's
`tx_channel_up` stays up, and the next frame lands with an equal payload. So RX-after-TX works in
simulation: Task 6 does not need to reset both dies together. Not determined: whether the plain
send or the one retry (RESEND) delivered that frame (the bench does not record which), and
whether silicon behaves the same.

## Stub each committed wrapper was generated from

- `rtl/jc_aurora_wrap_l1.vhd`: `/mnt/storage/fk33_builds/jc_link_t5/l1/jc_aurora_stub.vhdl`
  (IP `l1`: 1 lane, 10.3125, sim mode). The l1card stub has identical ports.
- `rtl/jc_aurora_wrap_l4.vhd`: `/mnt/storage/fk33_builds/jc_link_t5/l4/jc_aurora_stub.vhdl`.
- The l1slow stub lacks the four `gt_qpll*_quad1_out` outputs (CPLL); all are left open by the
  wrapper, so the l1 wrapper fits it, but this was not simulated.
