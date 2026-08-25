# Building an HBM bandwidth instrument for the FK33, and the seven things that stopped it

Date: 2026-08-25. Card: SQRL FK33, `xcvu33p-fsvh2104-2L-e`, VCCINT 0.717 V.
Tools: Vivado 2023.2, GHDL 1.0.0.

## 1. The question

Every throughput figure in all five v2 design specs rests on one number: that
the FK33's HBM delivers **~460 GB/s**, of which subsystem A at `ROWS_IF = 58`
demands ~432. Is that true on this card?

It is not a datasheet constant. **460.8 GB/s is exactly 32 AXI ports x 32 bytes
x 450 MHz** -- an arithmetic ceiling that assumes every port driven at the AXI
maximum. Nothing on this card has ever moved a byte of HBM at speed.

## 2. The answer

**Not yet measured.** This file documents the instrument and the build, both of
which are done and committed; the hardware run has not happened. What IS
settled, and was not before:

- **HBM's SAXI ports are AXI3, not AXI4.** 4-bit `ARLEN`, so a burst is at most
  **16 beats = 512 B**. Neither this instrument nor subsystem A can amortise
  address overhead beyond that. This bounds what any measurement can show.
- **The stock FK33 design leaves `DRAM_0/1_STAT_CATTRIP` unconnected.** The HBM
  stacks' own catastrophic-temperature signal goes nowhere. SYSMON's 101 C trip
  watches the FPGA die, and the die is not the stack.
- **The HBM IP fixes pseudo-channel n at n x 256 MB** and rejects any other
  offset, so a master whose addresses do not carry its own channel index cannot
  be mapped at all.
- **First light clocks the HBM AXI domain at 100 MHz**, which caps it at
  ~51 GB/s across 16 ports. Any "bandwidth measurement" in that design would
  have reported the clock, not the memory.

## 3. The procedure

Each step isolates one thing, and the order is deliberate: everything
cheap-and-in-simulation comes before anything that costs an hour of Vivado.

1. **Write the generator with counters that measure DIFFERENT things**, so a
   disagreement is visible rather than averaged away: `beats` is the payload,
   `cycles` is the wall time, `arstall` is cycles spent holding ARVALID without
   ARREADY. Reporting only aggregate bandwidth leaves a shortfall
   unattributable; `arstall` says whether the limit is the memory or our own
   issue rate.
2. **Drive it from a model whose bandwidth is KNOWN** (`sim/tb_hbm_tg.vhd`):
   one beat every THROTTLE cycles per port, so the expected aggregate is exact.
   An instrument never checked against a known quantity measures nothing. This
   is the step that earns the right to believe the hardware number later.
3. **Make the check two-sided, and mean different things by the two sides.**
   Measuring MORE than the model can serve is inflation and gets no tolerance
   at all. Measuring slightly less is the model's own AR turnaround and is
   expected.
4. **Assert that a masked-off generator moves ZERO bytes**, or the port-count
   sweep is a relabelling of the same traffic rather than a real sweep.
5. **Query the IP for its actual port shapes** rather than assuming AXI4.
   `get_bd_pins -of_objects [get_bd_intf_pins hbm/SAXI_01]` after enabling the
   port, plus `CONFIG.PROTOCOL`.
6. **Derive the build from the one that already works.** first light is proven
   to build, configure and run on this card, so the diff is the whole risk
   surface, and the generator script's guard checks that every intended edit is
   present in the OUTPUT on executable lines only.
7. **Only then build**, and read each failure as a fact about the board.

## 4. Evidence

The instrument, against the known-rate model, scaling linearly and recovering
the modelled rate at every port count:

```
nactive=1  beats=1024  cycles=2114  B/cycle got=15.500  want=16.0
nactive=2  beats=2048  cycles=2114  B/cycle got=31.001  want=32.0
nactive=3  beats=3072  cycles=2114  B/cycle got=46.501  want=48.0
nactive=4  beats=4096  cycles=2114  B/cycle got=62.002  want=64.0
temperature status register packs four 7-bit fields correctly
CATTRIP halts the run in fabric and reports the reason
programmed temperature ceiling halts the run
hbm_tg recovers a known bandwidth at every port count
```

The 3% shortfall is the model's own one-cycle AR turnaround at 64 bursts, not
the DUT.

The HBM SAXI port shape, read from the IP rather than assumed:

```
PROTO AXI3
AXI_01_ARADDR  32:0    AXI_01_ARLEN   3:0    AXI_01_ARID  5:0
AXI_01_RDATA  255:0    AXI_01_RID     5:0    AXI_01_RRESP 1:0
(no ARPROT, no ARCACHE, no ARQOS)
```

## 5. Measured and REJECTED, do not retry

Seven build failures, in order. Each is a property of this board or this tool,
not a typo, and each is now encoded in `hw/fk33/gen_hbmbw.py`.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `SAXI_00 is already connected to pcie2hbm_M00_AXI` | first light wires jtag_hbm to SAXI_00 and SAXI_16 | generators use **SAXI_01..15**, 15 ports. The quantity of interest is the SHAPE of bandwidth against port count, which 1..15 shows as well as 1..16 |
| 2 | `protocols of /tg/m00_axi(AXI4) and /hbm/SAXI_01(AXI3) are incompatible` | HBM SAXI is **AXI3** | wrapper regenerated against the real port list |
| 3 | `must be equivalent to the fixed address 0x1000_0000` | the IP **fixes** channel n at n x 256 MB | `PORT0` generic, so generator i emits addresses carrying channel index i+1 |
| 4 | `The maximum range for offset 0x0000_B000 is 4K` | a 64K range must be 64K **aligned** | registers at 0x00010000, clear of first light's map |
| 5 | `clock pins are not connected: /hbm/AXI_01_ACLK ...` | every **enabled** port exposes its own ACLK and ARESET_N; `USER_CLK_SEL_LIST0` shares a clock DOMAIN without removing the pins | connect all 15. first light never hit this because it enabled two ports |
| 6 | `FREQ_HZ does not match between /hbm/SAXI_00(466666666) and /pcie2hbm/M00_AXI(100000000)` | moving the HBM AXI clock to the fast domain stranded jtag_hbm at 100 MHz on the same ports | `NUM_CLKS 2` on pcie2hbm, same crossing as axil2tg |
| 7 | 105 placer errors, `IO Placement failed ... 6009 I/O ports` | **the top was wrong**: `add_files` on `hbm_tg_ip.vhd` adds a second root module, `update_compile_order` re-runs auto-top detection and picks it over `bd_wrapper` | `set_property top bd_wrapper`, then **assert** it |

Also rejected:

- **Vivado's `write_schematic` for a block diagram of any of this.** It is a
  GUI-only feature: in `-mode batch` it returns a filename, prints no error,
  and writes nothing. Confirmed on an elaborated `matvec_int4` and again on a
  bare `start_gui`, which fails the display test headless.
- **Trusting `USER_AXI_INPUT_CLK_FREQ` as the achieved clock.** It is a request
  to the IP. The MMCM lands where it lands, and a bandwidth figure computed
  from the request rather than the achievement is wrong by exactly that ratio.
  `hw/fk33/tcl/hbmbw.tcl` takes the clock as an argument for this reason.

## 6. Measurement traps hit

- **Failure 7 is the expensive one and the one to remember.** Synthesis
  SUCCEEDS on the wrong design. Nothing before the placer says the top changed,
  and the placer's complaint is about I/O count, which reads like a
  pin-budget problem rather than a wrong-top problem.
- **GHDL accepted a 39-bit value assigned into a 32-bit register.** The status
  register packed four 7-bit fields with a `(31 downto 21 => '0')` aggregate,
  whose width is inferred from context inside a concatenation. GHDL and Vivado
  inferred it **differently**, simulation was green, and only synthesis caught
  it. Use explicit literals in concatenations, and check field packing by
  driving known values and reading them back -- the testbench had never done
  this, which is why the bug survived.
- **Two generator bugs that would have been near-undiagnosable on hardware**,
  both found by the known-rate model:
  - AR accept and the last beat of the previous burst land on the SAME edge,
    so separate `+1` and `-1` branches collided and the later assignment won.
    The outstanding count drifted down, underflowed, and the generator stopped
    issuing FOREVER while still reporting itself active -- indistinguishable
    from a memory that went quiet.
  - The host holds `go` high for a whole run, so a finished generator saw
    `go=1, active=0` on the next cycle and re-armed with no work left. It could
    never retire another burst, so busy never deasserted and the host would
    poll forever.
- **A backgrounded launch whose `&&` chain starts with a relative path** ran in
  a stale cwd, failed silently, and reported success. The build simply never
  started and the log looked like the previous run's. Use absolute paths in
  background launches, and check the log's mtime, not just its contents.

## 7. Open, not yet answered

- **The measurement itself.** The bitstream is building; nothing has run on
  hardware.
- **The 7-bit stack temperature code to Celsius mapping is unverified**, which
  is why the generator's soft ceiling ships DISABLED: a limit on an
  uncalibrated scale either never fires or fires at random. CATTRIP needs no
  calibration and is always armed. The sweep prints codes beside SYSMON die
  temperature specifically so this can be calibrated on the first run.
- **The HBM global switch stays ENABLED**, as first light has it. Switch-off
  would very likely measure faster and is the obvious follow-up, but doing it
  in the same build would confound two changes.
- **Only stack 0 is driven.** 15 ports is half the device. Doubling for the
  second stack is a defensible extrapolation, not a result.
- **Whether the fabric can keep 15 masters fed at this clock** is exactly what
  `arstall` exists to answer, and it has not been read yet.
- **Card airflow.** The FK33 is a passively-finned card designed for server
  airflow, in a desktop. Idle is 29 C with 33.2 C the highest ever recorded,
  but nothing has loaded it.
