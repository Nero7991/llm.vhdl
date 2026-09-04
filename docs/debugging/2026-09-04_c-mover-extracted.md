# C's data mover, extracted and measured: it fits, and it misses timing

**Date:** 2026-09-04
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, `sim/ooc_cattnadapt.tcl`
**Method:** `sim/ooc_cattnadapt_extract.py`, the same method
`sim/ooc_gdnadapt_extract.py` used for B

## The question

`docs/debugging/2026-09-03_b-mover-does-not-fit.md` closes with *"C's mover
(`gcr`, 762 lines) has not been extracted. The method transfers; the seam does
not, and mapping it is the same day of work."* What does C's mover cost, and
does it fit?

## The answer

**It fits comfortably on area and misses timing badly.** And the two KV
configurations give completely different answers, so the choice between them is
not a tuning knob.

| | C's mover, on-chip KV | C's mover, KV over AXI |
|---|---|---|
| CLB LUTs | 74,586 (16.96%) | |
| CLB Registers | 97,131 (11.05%) | |
| Block RAM Tile | **60 of 672 (8.93%)** | |
| URAM | 0 | |
| DSPs | 72 (2.50%) | |
| WNS at 5.000 ns | **-1.611 ns = 151.3 MHz** | |
| result | **0 errors** | **DOES NOT SYNTHESISE** |

**Against B, which is the point of the comparison:** B's mover did NOT fit --
one object, `gb_real.stmem_p.stmem_reg`, was 5,472 RAMB36 against 672 -- and it
took `gdn_state_store` behind an AXI master to bring it to 34. **C has no such
object.** Vivado's RAM table names every one of C's and they all infer:

```
|ooc_cattnadapt_top | gcr.qg_buf_reg  | 8 K x 16(READ_FIRST) | ... Port A and B
|ooc_cattnadapt_top | gcr.kin_buf_reg | 1 K x 16(READ_FIRST) | ... Port A and B
|ooc_cattnadapt_top | gcr.vin_buf_reg | 1 K x 16(READ_FIRST) | ... Port A and B
|attn_block__GCB0   | ypre_reg        | 4 K x 24(READ_FIRST) | ... Port A and B
```

**The binding constraint for C is TIMING, not area.** -1.611 ns against a
5.000 ns period is a 32% overshoot, and it is far worse than the composed
`compose4_top`'s -0.815 or the A-only endpoint bitstream's -0.203. This is a
pre-`opt_design` out-of-context number with no placement, so it is not a
prediction for the card; it is a statement that C's mover starts a long way
from 200 MHz.

## The KV-over-AXI arm does not synthesise, and it took two refusals to find out

**First refusal, and it is the design working correctly:**

```
ERROR: [Synth 8-11323] assigned value '-48' out of range
  rtl/ooc_cattnadapt_top.vhd:509
```

That is `CHK_KV_NBLK : natural := 16 - C_NBLK*8/8` going negative -- the
out-of-range-`natural` idiom this project uses because Vivado ignores a failing
`assert ... severity failure` in synthesis. `C_NBLK = attn_head_dim /
C_KV_BLOCK = 256/4 = 64` at the 9B shape, the block exponents must fit a
16-byte header chunk, so `C_NBLK <= 16` and therefore **`C_KV_BLOCK >= 16`**.
The constant is mirrored from `attn_kv_axi`'s own `:455` assert specifically so
the CALLER is named, and that is exactly what it did.

**Second, with `C_KV_BLOCK=16`, a real blocker:**

```
ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for
  'GEN_RD[0].recbuf_reg' ... the number of bits (139264) is too large
ERROR: [Synth 8-3391] ... 'GEN_RD[1].recbuf_reg' ... (139264) ...
```

`recbuf` is `rtl/attn_kv_axi.vhd:646`,
`signal recbuf : ch_arr(0 to RBUF*CPR-1)`, one per read channel. **So the AXI
KV path has the same class of unsynthesisable buffer that B's state store had**,
twice, at 139,264 bits each.

## The seam, and the two NEW ways a mechanical derivation was wrong

The extraction is verbatim block text; what has to be derived is the seam --
which names the block reads from `llama_top`'s enclosing scope, and in which
direction. A mechanical pass classified 50 names: 22 `llama_top` generics, 16
assigned, 12 read-only. **It was wrong twice, and GHDL found both**, which is
the whole reason the method compiles the result rather than trusting the pass:

1. **26 KV AXI names were invisible.** They are `llama_top` ENTITY PORTS, not
   architecture signals, so a classifier looking for `signal`/`constant`
   declarations cannot see them at all. `kv_rdata` additionally spans two lines
   (`llama_top.vhd:751-752`), the same two-line trap that hid `u_start` from
   B's pass.
2. **`kv_err_i` was called an input and is an output.** It is driven THROUGH A
   PORT MAP -- `err => kv_err_i` on the `attn_kv_axi` instance -- and never by
   a `<=`, so an assignment-based test cannot see it drive. GHDL:
   `cannot associate out port "err" with actual port of mode in`.

Those are a sixth and seventh failure mode on top of the five
`ooc_gdnadapt_extract.py` records. **A regex over VHDL is not a parser**, and
the check that the seam is right remains that the output ANALYSES: GHDL rejects
an `in` port that is assigned, a name declared twice, and a name with no
declaration at all.

## Measured and REJECTED -- do not retry

- **"C's mover will need an AXI tier like B's."** The opposite. C's buffers all
  infer as true dual-port BRAM at 60 tiles total; it is the AXI arm that fails
  to synthesise. Do not spend effort moving C's KV off chip on the assumption
  that it must go the way B's state did.
- **"`C_KV_AXI=true` can be swept against the default generics."** It is
  refused at elaboration, correctly, because `C_KV_BLOCK=4` is illegal at the
  9B head_dim. The sweep must set `C_KV_BLOCK >= 16` or it measures nothing.

## Open, not yet answered

- **Where the -1.611 ns is.** No failing-endpoint census has been run on this
  block, and the compose4 work established that the worst path does not name
  the owner.
- **Whether `recbuf` is fixable the way `stmem` was.** It is 139,264 bits x2,
  three orders smaller than B's 24 MiB, so the answer is probably yes and
  cheaply -- but it has not been tried.
- **Nothing here says C computes a correct token.** It is one generate block
  synthesised alone. The token oracle is `tools/ref9b` rung 3.
- **Not placed, not routed.** Out-of-context synthesis only.
