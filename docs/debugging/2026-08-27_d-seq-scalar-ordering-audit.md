# Subsystem D: the scalar-versus-valid ordering audit of the three shipped units

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`. Files touched: `sim/tb_seq_desc_fetch.vhd`,
`sim/tb_seq_opdec.vhd`, `sim/tb_seq_region_lock.vhd`, `sim/seq_tbl_pkg.vhd`,
new `sim/ord_teeth_seq.sh`. **No `rtl/` file was changed.**
**Tools:** GHDL 1.0.0, **mcode** backend (`ghdl -r` run directly; `ghdl -e`
produces no binary and silently succeeds). No synthesis.
**Target:** `MODEL = QWEN35_9B`, `NCARDS = 1`. 491 descriptors per token.
**Predecessors:** `2026-08-27_gdn-conv-eseg-published-late.md` (the defect
shape), `2026-08-27_d-sequencer-first-units.md`,
`2026-08-27_d-sequencer-opcode-decode.md`.

## The question

Verbatim, from subsystem B's sweep of `rtl/` for units declaring both an
exponent-or-shift-like output and a valid-like output:

> A scalar that qualifies a stream must be assigned in a state STRICTLY EARLIER
> than the state that first raises that stream's valid. A testbench that samples
> it at `done` cannot tell you whether that holds. Three of the eleven matching
> units are D's and all three are OPEN:
> `seq_desc_fetch` -- `job_w_exp`, `job_out_shift`, `job_const_exp` against
> `job_valid`; `seq_opdec` -- `cmp_y_exp` / `y_exp_taken` / `y_exp_held` against
> `cmp_valid`; `seq_region_lock` -- `exp_rd_data` against `exp_rd_valid`.
> Settle each by reading the write time of the backing register relative to the
> valid, add the ordering guard, and prove each guard has teeth by running it
> against a deliberately broken copy.

## The answer

**All three units are CLEAN, with the state names below.** The finding worth
keeping is not the verdict, it is what happened when the guards were tested:
**one of the three guards was vacuous on the real table and passed against a
deliberately broken DUT**, because all three scalars it watches -- `w_exp`,
`out_shift`, `const_exp` -- were **identically zero in all 491 descriptors**.
A scalar that is the same constant everywhere makes stale, late, never-driven
and correct indistinguishable. Fixed in `sim/seq_tbl_pkg.vhd` by stamping the
three fields from the step index; the guard then fails on the broken copy.

## The verdicts, with state names

| unit | scalar | valid | backing register, and where it is written | verdict |
|---|---|---|---|---|
| `seq_desc_fetch` | `job_w_exp`, `job_out_shift`, `job_const_exp` | `job_valid` (`jvalid_r`) | the scalars are continuous decodes `f_wexp/f_oshift/f_cexp` of the concurrent alias `lv_w <= dw(live_bank)`; the only backing register is **`live_bank`**, written in **`S_ISSUE`** on the *same clocked assignment* that sets `jvalid_r <= '1'` | **CLEAN.** Same edge, not one later: there is no instant at which `job_valid` is high and the decode still shows the other bank. `live_bank` next moves in the next `S_ISSUE`, so the decode is also still valid at `job_cmp` (raised in `S_COMPLETE`, one state after `jvalid_r` is cleared) |
| `seq_opdec` | `cmp_y_exp`, `y_exp_held` | `cmp_valid`, `y_exp_taken` | **`x_exp`**, written in process `xcap` at the **first cycle `u_done(x_unit)` is observed**. `cmp_valid <= job_cmp`, and `job_cmp` is raised in `seq_desc_fetch`'s **`S_COMPLETE`**, which is at least one clocked state after the completion was observed in `S_WAIT` | **CLEAN**, strictly earlier. `y_exp_taken` (`x_pulse`) is registered on the same edge as `x_exp`, so the pulse and its payload are simultaneous, which is the correct relation for a `_taken` pulse. The unit already carries its own `STRICT` assertion for the failing case (`job_cmp = '1' and x_armed = '1' and x_taken = '0'`) |
| `seq_region_lock` | `exp_rd_data` | `exp_rd_valid` | `exp_cap(slot)` and `exp_vld(slot)`, **both written on the same edge**, in the `cmp_valid = '1' and jb_live = '1'` branch of the commit process | **CLEAN.** These are **not** a stream scalar and its valid: they are a register-file read port, and `exp_rd_valid` means "this slot has been captured since reset", not "a beat is valid". Both outputs are purely combinational reads of the two arrays off the same address. The specific worry raised -- one register serving two roles -- does not apply: they are two distinct arrays, and neither is a stream valid |

## The procedure

1. Read the write time of each backing register against the write time of the
   valid, in the RTL, and name the state. Not "it looks fine".
2. Add the guard in the `ord_chk` form of `sim/tb_gdn_conv.vhd`: capture the
   scalar at the FIRST valid beat, assert it still equals the value at `done`.
3. **Break a copy of each unit in the gdn_conv way and require the guard to
   fail.** `sim/ord_teeth_seq.sh`. A guard added after a fix is worthless until
   shown to fail before it.
4. Require the guard's OWN message, not merely a failing run. This is the step
   that produced the finding: break D1a fails, but on a check that was already
   there.
5. Re-run all 50 configurations of the three shipped suites.

## The evidence

### `sim/ord_teeth_seq.sh`, all four breaks

```
=== 1. seq_desc_fetch: publish the live-bank decode one cycle late ===
D1a  TEETH -- the expected check fires:
  tb_seq_desc_fetch.vhd:410:@42500ps:(report error): JOB SHADOW MOVED under
  unit 4 at step 0, cycle 42.

=== 1b. seq_desc_fetch: withdraw the decode BEFORE job_cmp ===
D1b  TEETH -- the expected check fires:
  tb_seq_desc_fetch.vhd:714:@114500ps:(assertion failure): a job scalar
  CHANGED after the first cycle of job_valid -- 1111...0001011111... 

=== 2. seq_opdec: capture the exponent at job_cmp, not at first done ===
D2  TEETH -- the expected check fires:
  tb_seq_opdec.vhd:1089:@120500ps:(assertion failure): y_exp_taken pulsed
  AFTER cmp_valid -- the exponent was captured at or after the instant the
  lock latched it

=== 3. seq_region_lock: register the exponent read port ===
D3  TEETH -- the expected check fires:
  tb_seq_region_lock.vhd:366:@30500ps:(report error): region 0 segment 0 reads
  0000000000000000 in the first cycle after its own commit at step 0,
  want 1111111111100010
```

The four breaks, in RTL terms:

- **D1a** `lv_w <= dw(live_bank)` wrapped in a clocked process: the decode is one
  cycle late, the exact gdn_conv shape.
- **D1b** `lv_w <= dw(other(live_bank)) when jvalid_r = '0' else dw(live_bank)`:
  the decode is withdrawn one state EARLY, in the one window nothing else covers.
- **D2** the capture condition `u_done(x_unit) = '1'` replaced by `job_cmp = '1'`.
- **D3** `exp_rd_data` given a clocked process instead of a combinational read.

### Regression, after the guards and the table change

```
run_seq_desc_fetch.sh   18 PASS, 0 FAIL, 0 report error
run_seq_region_lock.sh  10 PASS, 0 FAIL, 0 report error
run_seq_opdec.sh        22 PASS, 0 FAIL, 0 report error
```

Every fault-injection row still reports the same code and the same failing step
as `2026-08-27_d-sequencer-opcode-decode.md` records (`code=3 step=300`,
`code=3 step=2`, and the rest).

## Measured and REJECTED -- do not retry

- **"The broken copy failed, so the guard has teeth."** It does not follow, and
  this is the whole reason break D1a is recorded separately. The late-decode
  break is caught at step 0 by the PRE-EXISTING per-unit `job_digest` check,
  which compares the whole shadow on every cycle `job_valid` is high. `ord_chk`
  never reached `job_cmp`. A teeth test must require the guard's OWN message;
  `sim/ord_teeth_seq.sh` takes a `want` regex per break for exactly that reason.
- **Testing `tb_seq_desc_fetch`'s `ord_chk` on the shipped descriptor table.**
  It PASSES against the D1b broken DUT. Cause: `w_exp`, `out_shift` and
  `const_exp` were **0 in all 491 descriptors** -- no call site of `mk_desc`
  ever passed them -- so `at_v = sc` compares zero against zero at every step.
  **A guard whose subject is a constant is a comment.** Same family as the
  `attn_recip` N7 result (a guard no vector reaches) and as
  `tb_seq_region_lock`'s existing rule that `cmp_y_exp` be derived from the step
  index so a shared capture is a WRONG NUMBER and not a repeat.
- **Making the three fields nonzero only in the testbench.** They come out of
  the URAM descriptor table, so there is nowhere else to put them. The fix is in
  `seq_tbl_pkg`'s `emit`, which now stamps
  `w_exp = (7p mod 61) - 30`, `out_shift = (p mod 23) - 11`,
  `const_exp = (5p mod 41) - 20`. The three unused `mk_desc` parameters were
  deleted rather than left to be silently overridden by `emit`; nothing outside
  that package calls `mk_desc`, and no gateware check reads these fields, so any
  value is legal table content.
- **A separate `ord_chk` process in `tb_seq_region_lock`.** It would need to
  drive `exp_rd_region`/`exp_rd_seg`, which the stimulus already drives, and a
  second driver on an unresolved signal is an elaboration error. The guard is
  inline in the stimulus instead, immediately after the commit edge.

## Measurement traps hit

- **`to_string`, never `integer'image(to_integer(...))`.** Carried over from the
  gdn_conv guard and it earned its place again: on break D3 the first read is
  all-zero-or-metavalue and a `to_integer` inside the report expression kills the
  run inside `numeric_std-body.vhdl` with no message.
- **`wait until rising_edge(clk)` resumes in the SAME delta as the edge.** The
  region-lock guard assigns the read address and then waits **1 ns**, not zero,
  or the combinational read still shows the previous address. Third time this
  has been the right call in this project.
- **An `impure function` that reads signals.** `tb_seq_desc_fetch`'s `sc`
  helper reads three signals; declared `function` it emits three `-Wpure`
  warnings at analysis, which is noise at exactly the place a real warning would
  be scrolled past.
- **`variable d` inside `emit` hides `variable d` in `build_table`.** VHDL is
  case-insensitive and GHDL warns with `-Whide`. Renamed `ds`. Same shape as the
  `nhead` / `NHEAD` trap in `tb_attn_recip`.

## Open, not yet answered

- **The `job_digest` check is gated on `job_valid` and therefore stops one cycle
  before `job_cmp`.** `ord_chk` now covers that cycle, but only for the three
  scalars, not for the whole digest. Widening the digest gate to
  `[job_issue, job_cmp]` inclusive would subsume `ord_chk` entirely; it was not
  done here because the gate's current width is deliberate and documented
  (`2026-08-27_d-sequencer-first-units.md`), and changing it needs the
  `READY_EARLY + STALE_HOLD` configurations re-run against the reasoning that
  set it.
- **Eight of the eleven units B's sweep matched are not D's** and are untouched
  here.
- **No synthesis**, so none of this says anything about whether the guards'
  subjects close timing.
