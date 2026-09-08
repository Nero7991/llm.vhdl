# The three-cell card block design, and the six things that stopped it

Date: 2026-09-07. Part `xcvu33p-fsvh2104-2L-e`, SQRL FK33, Vivado 2023.2.
Files: `hw/fk33/gen_pcieep.py`, `tools/gen_cardtop.py`, `rtl/bc_port_grant.vhd`,
`sim/tb_bc_port_grant.vhd`, and the generated
`rtl/fk33_llama_top.vhd`, `hw/fk33/rtl/fk33_card.vhd`,
`hw/fk33/rtl/fk33_bc_grant.vhd`.

## The question

Subsystem A has been a block-design cell for weeks. B, C and D exist as RTL and
as a generated BD-legal wrapper, and the B/C grant exists, but nothing wired
them into `bd`. Does the three-cell design -- `eng` + `card` + `bcgrant` --
actually build?

## The answer

**Yes. `pcieep_build.sh --bd-only` completes with exit 0, zero `ERROR:` lines
and zero address-overlap warnings, in both configurations**: with the card
(`FK33_CARD=1`) and without it. `validate_bd_design` and `make_wrapper` both
pass. Nothing is synthesised, so this is a legality result and not a fit or
timing result.

Six distinct faults stood between the wiring and that result, and **not one of
them is reachable by any simulation.** They are listed below in the order the
tool found them, because that order is the reusable part: each was invisible
until the one before it was fixed.

## The procedure

`--bd-only` costs about 2 min 20 s of CPU and peaks at 3.84 GB, so it was run
seven times rather than reasoned about. Each run answered exactly one question
and the next question did not exist until it did.

1. **Enumerate both sides before connecting.** The A seam, the host seam and
   the B/C ports were read out of the generated entities and matched pairwise.
   All three are 1:1, which is why the seam wiring itself produced no errors.
2. **Run, read the first error, fix, run again.** No attempt was made to
   predict the next failure.
3. **Regression both ways.** Every fix was checked with the card OFF as well as
   ON, because the engine-only build is the one that has produced bitstreams.

## The evidence

### 1. An inferred interface is named by the PORT PREFIX, not prefix + `_axi`

```
WARNING: [BD 5-232] No interface pins matched 'get_bd_intf_pins card/a_axi'
ERROR:   [BD 5-106] Arguments to the connect_bd_intf_net command cannot be empty.
```

The engine's interfaces are called `m00_axi` and `s_axi` **because `_axi` is
part of its port names** (`m00_axi_awvalid`). The card's are `a`, `bst`, `kv`,
`kv0`, `kv1`, `m`; the grant's are `b`, `c`, `m0`, `m1`. Measured by making the
build print them, which is now a permanent part of `_card_block()`:

```
FK33_CARD INTF card a       FK33_CARD INTF bcgrant b
FK33_CARD INTF card bst     FK33_CARD INTF bcgrant c
FK33_CARD INTF card kv      FK33_CARD INTF bcgrant m0
FK33_CARD INTF card kv0     FK33_CARD INTF bcgrant m1
FK33_CARD INTF card kv1
FK33_CARD INTF card m
```

Note the grant has **no `c0`/`c1` interfaces**: those read-only port groups were
not inferred as interfaces at all. They are connected signal by signal, which
works and is what the code does.

### 2. The HBM slave is AXI3 and the card's masters were written AXI4

```
ERROR: [BD 41-1285] The protocols of the interfaces '/bcgrant/m0'(AXI4) and
       '/hbm/SAXI_30'(AXI3) are incompatible. They cannot be connected.
```

The discriminator is the length width: `fk33_engine`'s `m00_axi_arlen` is
`std_logic_vector(3 downto 0)` and the grant's was 8 bits, inherited from
`gdn_state_axi` and `attn_kv_axi`, both of which declare AXI4-width ports.

**Both requesters are already capped at 16 beats at COMPILE time** --
`gdn_state_axi:192 bad_maxb_over_axi3_cap` and `attn_kv_axi:531 assert MAXB <=
16` -- so the discarded nibble is always zero and the narrowing is lossless.
The grant gained `MLEN_W : positive := 4` and a sticky `err_len_ovf` that
reports a requester presenting more than the cap, rather than silently turning
a long burst into a short one. The bench is unchanged in every count across the
narrowing:

```
before:  PASS checks=8494 switches=7619 reads=5142 writes=3352 p0wr=1790 p1wr=1562
after:   PASS checks=8494 switches=7619 reads=5142 writes=3352 p0wr=1790 p1wr=1562
                                                          ... err_len_ovf='0'
```

### 3. An unqualified `assign_bd_address` covers EVERY master

```
ERROR: [BD 41-1075] Cannot assign slave segment '/eng/s_axi/reg0' into address
       space '/card/a' at address '0x0001_2000 [ 4K ]'. The proposed range '4K'
       is greater than the maximum range '256' from slave segment
       '/eng/s_axi/reg0' to address space '/card/a'.
```

`ENGINE_ADDR` mapped the engine's control slave at 4K with no target. Once the
card is a second master into that slave, the same call tries to give the card's
8-bit master a 4K window. Fixed by naming the two host spaces, taken from that
call's own log lines in the engine-only build:

```
foreach sp {jtag_axil/Data xdma/M_AXI_LITE} { assign_bd_address ... }
```

### 4. A smartconnect sizes its slave MMU from the SLAVE, not from the window

```
ERROR: [IP_Flow 19-3478] Validation failed for parameter 'SEG000_SIZE' with
       current value '12' for BD Cell 'engctl/inst/s01_mmu'.
       PARAM_VALUE.SEG000_SIZE must be <= ADDR_WIDTH (8)
```

The card's control master was 8 bits (`LITE_AW => 8`), correct for the in-card
`matvec_int4`, but on the card it drives `matvec_int4_desc_axi`, whose AXI-Lite
map is 4 KB. Widened to 12 in `tools/gen_cardtop.py`. The adapter uses only
`0x00`, `0x04` and `0x08`, so the four new bits are always zero and this is a
pure zero-extension.

### 5. The grant is one clock domain and the HBM is another

```
ERROR: [BD 41-237] FREQ_HZ does not match between /hbm/SAXI_30(250000000)
                                             and /bcgrant/m0(200000000)
ERROR: [BD 41-237] CLK_DOMAIN does not match between /hbm/SAXI_30(...axi_aclk)
                                                 and /bcgrant/m0(...clk_out1)
```

`fk33_engine` has TWO clock ports and crosses the domain **inside** the unit,
using `matvec_int4_desc_axi`'s own `async_fifo`. The grant has one clock and its
requesters are in the core domain, so an `axi_clock_converter` per port was
added (`PROTOCOL AXI3`, read back rather than assumed). SmartConnect was
rejected for this: it speaks AXI4/AXI4-Lite and both ends here are AXI3, so it
would protocol-convert twice to do a job that is purely a domain crossing.

### 6. A guard that counted faults and never acted on them

```
FK33_ENG portcheck bad=2 (must be 0)
```

**and the build passed.** `engbad` was printed and never branched on, so every
fault it counts -- a dangling master, an undriven ACLK, an unconnected
`m..._axi`, an undriven `compute_halt` -- was being reported into a log and
ignored. It now raises. The `bad=2` itself was a stale expectation: the check
hardcoded `SAXI_30/31 must be false`, which is right without the card and wrong
with it, so the expectation now reads the design (`[llength [get_bd_cells -quiet
card]]`) rather than a generator flag.

Final state, both configurations, exit 0 and zero `ERROR:` lines:

```
card ON : FK33_SEAMMAP tie-off absent and subsystem D is in the card cell
          FK33_ENG SAXI_30 = true (must be true)     portcheck bad=0
          FK33_CARD bc_cdc0 PROTOCOL AXI3 -> SAXI_30
          FK33_CARD card/a maps /card/a/SEG_eng_reg0
card OFF: FK33_SEAMMAP tie-off present and subsystem D is absent
          FK33_ENG SAXI_30 = false (must be false)   portcheck bad=0
```

## Measured and REJECTED -- do not retry

- **Pre-assigning `card/a` a 256-byte window to avoid fault 3's 4K request.**
  It was the first fix tried. The narrow assignment DOES land -- the log says
  `/card/a at <0x0000_0000 [ 256 ]>` -- and the unqualified call **still**
  tried to map 4K into that space and failed identically. Already-assigned does
  not mean skipped.
- **Leaving the card's control master at 8 bits and relying on that 256-byte
  window.** Fault 4 is decided by the slave's segment, not by the master's
  window, so no address assignment can fix it. The port has to be wide enough.
- **A smartconnect for the HBM crossing.** See fault 5.
- **Deleting the seam tie-off at Tcl run time with `delete_bd_objs`.** It works,
  but `check_seam_tieoff` reads the generated script's TEXT, so the tie-off
  would still appear present and the guard would have kept passing even if the
  delete silently matched nothing. The tie-off is now not emitted at all when
  the card is on, which makes the guard's reading true by construction.

## Measurement traps hit

**The standalone probe cost three runs and answered nothing.** A small Tcl to
list the inferred interface names failed on `exit 127` (no `vivado` on the
systemd unit's PATH), then on manual compile order, then on
`[filemgmt 56-195] ... type VHDL 2008 ... not allowed as the top file in the
reference`. The build itself already knew the answer; adding a `puts` loop to
`_card_block()` got it on the next real run and left a permanent diagnostic.
**Prefer instrumenting the failing job over building a separate rig to ask it a
question.**

**A green bench across the AXI3 narrowing means the narrowing is untested, and
here that reading is correct.** Every count is identical before and after, which
is the expected result when the discarded bits were always zero -- but it is
also what a bench that cannot see the change would print. The new
`err_len_ovf` was teeth-tested by widening its comparison to the whole length,
which makes ordinary traffic trip it: `FAIL ... err_len_ovf='1'` with
`misdeliveries=0` and `err_switch_busy='0'`, so the kill is attributable to the
new check alone. **That tests the plumbing, NOT the 16-beat threshold**, because
the bench never issues a burst longer than 16. The threshold is unexercised and
is recorded here as such.

## Open, not yet answered

- **Nothing is synthesised.** This is legality only. Area, fit and timing for
  the three-cell design are unknown, and the whole-card figure still rests on a
  shell number carried from 2026-09-05 rather than re-derived same-tree.
- **The 16-beat threshold in `err_len_ovf` has never been exercised** (above).
- **`bst_*` carries `arsize`, `arburst`, `wstrb`, `rresp`, `bresp` and the
  grant's `b_*` does not.** The connection succeeded, so Vivado is defaulting
  them; whether the defaults are the intended values has not been checked.
- **Bandwidth.** Pool port 0 now carries C's read 0 and C's write concurrently,
  and both HBM ports sit behind a clock converter whose depth was not chosen.
- **`err_switch_busy` and `err_len_ovf` are not wired to anything**, so a fault
  either reports would be invisible to the host.
