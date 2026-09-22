# The residual window reads zero on silicon: the two-card hop has an exponent and no mantissas

## The question

2026-09-22, build 14 (12b + `XEXP_OUT`, re-implementation, WNS +0.056 at 75
MHz, caps `0x7D`) on the FK33, striped seg27 image verified 251/251.
After the single-id reference prompt `248045` (one prefill GO, no decode), the
card's argmax is 846 and `XEXP_OUT` reads 8, both equal to the reference
stream `tok0.r9bs` (LOGITS argmax 846; `R_X-31` exp 8). **Do the 4,096
residual mantissas that the two-card hop reads from seam window 3 equal the
reference's `R_X-31` record?**

## The answer

**No: window 3 returns all zeros on the card.** 4 of 4,096 mantissas "equal"
the reference and those four are the reference's own zeros; card RMS 0.0
against reference RMS 3.049. The exponent path works, the mantissa path does
not exist on this silicon. `hw/fk33/gen_fk33_card.py:203` builds every card
with `HOST_WINDOW=false`, under which `rtl/region_mem.vhd:414` ties
`hr_data <= (others => '0')`, and `rtl/fk33_seam.vhd:1155` serves window 3
from exactly that signal. The two-card spec's premise that window 3 carries
"the mantissas, already there" was FALSE when it was written, the fact was
recorded three days earlier in `hw/fk33/host/logit_compare_on_card.sh`
(reason 3 of "the shipping bitstream cannot produce a logit vector"), and the
simulator (`server/fk33_sim.c`) models the window as live, so every test in
the plan passed over a path the card does not have.

## The procedure

1. **The exponent alone, single card, reference token.** `run_prompt
   --allow-hardware HOST --seq-reset --v2 --prompt <248045> --max-new 1` on
   build 14, then `fk33ctl.py seam`. Isolates: the register's VALUE against
   an independent reference at the one position where card and reference
   start from identical state. Result: `argmax 846 logit_exp 15 x_exp_out 8`.
   Reference: LOGITS argmax 846, `R_X-31` exp 8. MATCH.
2. **The mantissas, same run, through the hop's own read.** Added
   `run_prompt --dump-xout <file>`, which calls `pl_read_xout` (the exact
   function `pl_pipeline` uses for the hop) after the last GO and writes
   `exp` plus n_embd int16 values. Compared against `R_X-31` from
   `tok0.r9bs` with `tools/ref9b/r9bs.py`. Isolates: the data the second
   card would receive. Result below.
3. **The same option on the simulated card** first (identity engine):
   returns the pushed row, exp -8, 4,096 values, i.e. the read path in the
   host and the simulator is live. So the zeros are the card's, not the
   host's.
4. **Read the RTL for the window's source**, from the seam backwards:
   `fk33_seam.vhd` W_XOUT -> `hr_data`; `llama_top.vhd:2087` /
   `region_mem.vhd` `g_host`/`g_nohost`; `gen_fk33_card.py:203`.

## The evidence, raw

```
prefill    1 ids, pos 1, first argmax 846, exp 15
xout       R_X after the last GO: exp 8, 4096 mantissas -> .../xout_card_tok0.txt
card exp 8 reference R_X-31 exp 8 n 4096 4096
mantissas: equal 4 of 4096 | max |diff| 28810 | mean |diff| 506.19140625
values: rel RMS diff 1.0 | card max 0.0 ref max 112.5390625 | card rms 0.0 ref rms 3.049082234097772
```

`hw/fk33/gen_fk33_card.py:203`: `"--generic", "HOST_WINDOW=false",` with the
comment "The port is DEAD ON THE CARD -- nothing on the board drives or
consumes it; it exists for sim/tb_llama_top.vhd". `rtl/region_mem.vhd:414-416`:

```
  g_nohost : if not HOST_WINDOW generate
    hr_data <= (others => '0');
  end generate;
```

`rtl/fk33_seam.vhd:1154-1155`: `when W_XOUT => rv := std_logic_vector(resize(hr_data, 32));`

Why it is off: a combinational full-range read port into the region file
cannot be a BRAM; with it present Vivado built the store as 2,752,512
registers (MEASURED 2026-09-02, `[Synth 8-11357]`), which is the recorded
cause of ten card builds that never left elaboration. Turning it back on is
not an option.

## Measured and REJECTED, do not retry

- **`HOST_WINDOW=true` on the card.** 2.75 M registers, the elaboration wall.
- **Reading R_X from HBM.** There is no write-back of the region file to HBM
  (`logit_compare_on_card.sh` reason 2); nothing to DMA.
- **Trusting the simulator for the hop.** `fk33_sim.c` fills `win_xout` from
  `win_xin` on every GO; it models a window the card does not implement.
  T15/T16/T17 and the run_prompt two-card runs are all green over this.

## What the hop needs instead (DESIGN OPTIONS, not built)

The seam's read path already presents `hr_addr` at AR-accept and waits one
clocked state before sampling `hr_data` (`fk33_seam.vhd:652`), so a
REGISTERED one-cycle read fits the existing protocol, possibly with one more
wait state.

- **A. Route the host read through the region file's existing group read
  port** (`r_en/r_rega/r_addr -> x_rdata`, registered one cycle, LANES wide)
  when the engine is idle after `tok_done`, with a lane select on the word.
  Cost: a 2:1 mux on the read-address inputs and a LANES:1 lane mux; **zero
  memory**; reads the real R_X. Risk: the mux sits on the vector units' read
  address path, whose slack on a design that routed at +0.056 is unmeasured.
- **B. A shadow copy of R_X**: a 4096 x 16 simple-dual-port BRAM (2 BRAM36 of
  105 free) written alongside every write that lands in region R_X
  (`w_we`/`el_we` with the region index = R_X), read by `hr_addr`. Cost: 2
  BRAM36 plus the write-side decode; touches no engine path. Risk: a shadow
  that can diverge from the region file (mitigated by comparing both in
  `tb_llama_top`, which has `HOST_WINDOW=true` and can read the real one).

Either is a card build (~2 h under the rescue recipe, 6 h under the default)
and a gate row in `tb_fk33_seam` that reads mantissas back and compares them
to the region file.

## Measurement traps hit

- **A register that reads correctly is not a data path that works.**
  `x_exp_out = 8` matched the reference and, had the mantissas not been
  dumped, the hop would have been reported as validated on one card. The
  mantissa read was the check that could fail, and it did.
- **The premise was in the spec as a fact and in a script header as its
  negation, three days apart.** `grep -rn "hr_data reads zero"` would have
  found it before the spec was written.
- **Simulation fidelity is bounded by what the simulator was written to
  model.** Recorded here as the third such floor in the two-card work (after
  the exponent-shift mutant and the card-0-argmax mutant).

## Open, not yet answered

- Which of A or B, and its routed cost. Oren's call.
- Whether the group read port is idle for the whole host-read window after
  `tok_done` (A's correctness condition).
