# Every card build so far synthesised a 4-position KV cache, not Qwen3.5-9B

**Date:** 2026-09-09. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, workstation.
**Found while:** waiting on `cardbuild10`, by reading the build's CRITICAL
WARNINGs after an unrelated grep for real errors.

## The question

Why does the card build not fit in 24 GB, and what exactly is it building?

## The answer

**It was building the wrong design.** `hw/fk33/gen_fk33_card.py` passed six
generics and none of the KV geometry, so the `card` cell was instantiated with
`rtl/fk33_llama_top.vhd`'s DEFAULTS:

| generic | shipping 9B | what was built |
|---|---|---|
| `C_MAXPOS` | 131072 | **4** |
| `C_CTXLEN` | <= C_MAXPOS | **1** |
| `C_K_BASE_CH` | 282598912 | **1** |
| `C_V_BASE_CH` | 353902080 | **254** |
| `C_KV_ADDR_W` | 33 | **16** |

A four-position KV cache with a context length of one, K based at byte 16 and
V at byte 4064, on a 16-bit address bus. That is the bench stand-in.

**A second, independent instance of the same defect** was found in the same
log: `fk33_seam` was also instantiated with its defaults (`REGMAX` 4096,
`HADDR_W` 12) while the card's host-visible region is 12,288 elements needing
14 bits, so **host registers 4096..12287 were unreachable**.

## How it survived every gate

The block design reported it, twenty times, and nothing branched on it:

```
CRITICAL WARNING: [BD 41-2383] Width mismatch when connecting input pin
'/bcgrant/c0_araddr'(33) to pin '/card/kv0_araddr'(16) - Only lower order bits
will be connected, and other input bits of this pin will be left unconnected.
```

**The build gates on `^ERROR`, and a CRITICAL WARNING is not one.** So a silent
17-bit truncation of subsystem C's entire KV address path passed every check
this project has. C would have read and written the low 64 KiB of HBM for every
head of every layer, and the bitstream would have built and run.

**`tools/check_kv_map.py` was GREEN throughout, all 16 rows**, including
`C_KV_ADDR_W - 4 >= clog2(top chunk)` with zero slack. It validates the KVR
block in `sim/realshape_gate.sh`, which carries the correct 9B values, against
the HBM manifest. It never reads `gen_fk33_card.py`.

**That is the "guard that passes for the wrong reason" class one level up.**
The guard was not weak and was not wrong. It was correct, rigorous, and
checking a *different artifact than the one that ships*. A checker that
validates the simulation configuration says nothing whatever about the
hardware configuration unless something asserts the two are equal, and nothing
did. `check_kv_map.py` is also not referenced anywhere in `sim/regress.sh` --
only in `sim/realshape_gate.sh` -- so it is the recorded "a script nothing
schedules" pattern as well.

## The procedure

1. Grep the build journal for real errors, **anchored** on the systemd line
   prefix. The unanchored form matches the script text the log echoes, which
   is the recorded self-match trap and produced a screenful of `#`-prefixed
   false hits here too.
2. Read the CRITICAL WARNINGs, not only the ERRORs.
3. For each named pin, compare the width against the RTL generic that sizes
   it -- `grep -n "C_KV_ADDR_W" rtl/fk33_llama_top.vhd` shows the documented
   value 33 on line 592 and the default 16 on line 599, twelve lines apart.
4. `grep -c '"--generic"' hw/fk33/gen_fk33_card.py` -> **6**. Enumerate them
   and diff against the RTL's own documented shipping set.
5. Before raising `C_MAXPOS`, confirm what it sizes. The behavioural KV cache
   is inside `gkvmem : if not C_KV_AXI generate` and the card sets
   `C_KV_AXI=true`, so it is not instantiated; the file records that cache
   costing 8.9 GB of elaboration at `C_MAXPOS 256` when it IS. With the real
   cache in HBM, `C_MAXPOS` buys only `POSW = clog2(C_MAXPOS+1)` = 18 bits
   against 3.
6. Before raising `REGMAX`, confirm it sizes no storage. It appears only in
   range constraints and bounds tests.

## The evidence

The five values were derived from `rtl/fk33_llama_top.vhd`'s own comment block
and then found to match `sim/realshape_gate.sh:290-291` **to the digit**:

```
KVR="-gC_KV_BLOCK=32 -gC_K_BASE_CH=282598912 -gC_V_BASE_CH=353902080"
KVR="$KVR -gC_KV_ADDR_W=33 -gC_MAXPOS=131072 -gC_CTXLEN=131072"
```

That agreement is independent confirmation, because the two were reached from
different sources.

After the fix, `pcieep_build.sh --bd-only` exits **success, 0 errors**, and the
width mismatches fall from **20 to 4** -- all sixteen KV-path ones gone, the
four survivors being the separate `hr_addr`/`hw_addr` seam defect, which is
fixed by `CONFIG.REGMAX 12288` / `CONFIG.HADDR_W 14`.

**CONFIRMED after the seam fix, second `--bd-only` run:** `[BD 41-2383]` count
**0**, `ERROR` count 0, unit result success, and the property took --
`FK33_SEAM REGMAX=12288 HADDR_W=14`. So the sequence across the two runs is
**20 -> 4 -> 0**, with each step attributable to one change.

**A trap in reading even that confirmation.** The breadcrumb was pulled with
`grep 'FK33_SEAM ' | tail -1`, which returned a PRE-EXISTING
`FK33_SEAM CAPS_CTX = 0` line and not the new one -- another unanchored match
against a haystack that already contained a similar needle. The new line was
only confirmed by grepping for `FK33_SEAM (REGMAX|HADDR_W)` specifically. The
mismatch count reaching 0 is the load-bearing evidence either way; the
breadcrumb was written as a breadcrumb for exactly this reason.

## The gate that would have caught it

`tools/check_kv_map.py` gains a fourth side reading `gen_fk33_card.py` and
requiring each generic to equal the KVR value that is already manifest-checked.

**Teeth, against the ACTUAL pre-fix file taken from git, not a stand-in:**

| state | rc | refused rows |
|---|---|---|
| control, the fixed file | 0 | 0 |
| the real pre-fix file (`git show HEAD:...`) | 1 | **5** |
| `C_KV_ADDR_W` 33 -> 32 | 1 | **1** |

The third state matters: a generic that is PRESENT but WRONG is caught only by
the equality row, not by the "does it set it" row. 32 is not an arbitrary
mutant -- it is the value `realshape_gate.sh` already pins as its known-bad
`real_kv_addr_short` row.

## Measurement traps hit

**My first teeth test reported 0 refusals and I nearly believed it.**
`read_card(path=CARD_GEN)` binds its default at DEFINITION time, so patching
`module.CARD_GEN` after import changed nothing and both runs read the same
fixed file. The test was measuring nothing. Patch the FUNCTION, not the
constant it defaulted from. **A teeth test that does not bite is either a weak
check or a broken test, and the two are indistinguishable until you run the
control** -- here the control passed and the mutant also passed, which is the
signature of a test that never varied its input.

**The rows printed REFUSED and the exit code stayed 0.** `nfail` is tallied at
what was line 330, and I appended the new rows *after* it, so they rendered
correctly and were excluded from the verdict. Caught only because the teeth
test printed `rc=0 refused=5` on the same line. **A check whose result is not
branched on is decoration**, and this is the second recorded instance in this
project of a counter that was printed but never gated.

**A `[BD 41-2383]` count is only meaningful with the pin names.** The raw count
went 20 -> 4, which reads like "mostly fixed"; the names show the remaining
four are an entirely different signal group with a different root cause.

## Measured and REJECTED -- do not retry

- **Blaming the 24 GB ceiling on design size before checking what was being
  built.** Three runs (cardbuild8, 9, 10) and roughly nine hours of Vivado were
  spent fitting a configuration nobody had verified was the intended one. The
  check that settled it, `grep -c '"--generic"'`, costs one second.
- **Reading the utilization/memory numbers from those runs as facts about the
  9B card.** They are facts about a 4-position stand-in and are not quotable
  for the real design in either direction.

## Open, not yet answered

- **Whether the corrected design is bigger or smaller in synthesis memory.**
  Wider addresses and 18-bit positions cost something; nothing else obviously
  changes, because the KV storage was already in HBM. Unknown until measured.
- **Whether any OTHER BD cell is instantiated with defaults.** Two were found
  by reading one log. Nothing enumerates the set, and the same failure mode
  would look identical.
- **Whether `[BD 41-2383]` should fail the build outright.** It is currently
  ungated. Every instance found today was a genuine defect.
