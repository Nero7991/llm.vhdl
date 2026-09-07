# A block-design-legal face for the composed card top

**Date:** 2026-09-07
**Question:** `compose4_top --wire --mem` is the design the card needs -- A, B,
C, D, plus both HBM memory subsystems, with D wired to A and the B/C seams
driven. The IP packager refuses it. Can it be given a legal face without
touching verified RTL?

## The answer, up front

Yes. `tools/gen_bd_wrapper.py` (new) emits a wrapper that takes the design from

```
  source top   ports=1300  REFUSALS=57   {19-734: 38, 19-627: 19}
  BD wrapper   ports=1300  REFUSALS=0    {}
```

and it **elaborates in Vivado over the real design with zero errors**
(`WRAP_ELAB_OK ports=43475`). It changes no logic: every port is the same
signal in a type the packager accepts, converted at the boundary.

## Why a wrapper rather than fixing the ports

The 57 refusals are on internal seams belonging to B, C, D and the region file.
A real card top will TERMINATE most of them rather than export them, so
rewriting 22 entity ports across three verified subsystems to satisfy a
packager rule would be changing RTL for a tooling constraint, in files that
carry four benches and a mutation script each.

Neither refusal class is reachable by any bench. They are packager rules, not
language rules, so the RTL elaborates, simulates and passes every gate row
while the block design cannot instantiate it -- which is exactly how the pcieep
build stayed dead from `3a145fd` with nobody aware.

## The two conversions

| refusal | port shape | wrapper carries |
|---|---|---|
| `[IP_Flow 19-734]` | `integer range 0 to N-1` | `std_logic_vector(W-1 downto 0)`, `W = clog2(N)` as a LITERAL |
| `[IP_Flow 19-734]` | bare `integer` | `signed(31 downto 0)` -- VHDL's integer is 32-bit signed |
| `[IP_Flow 19-627]` | `unsigned(clog2(X)-1 downto 0)` | `unsigned(K-1 downto 0)`, `K` folded here |

`signed` and `unsigned` are ACCEPTED port types despite 19-734's wording, which
`sim/check_bd_ports.py:68` records as MEASURED. So the folding case needs no
type change at all -- only the function call in the WIDTH has to go, because a
block-design port width is an XPath expression over the generics and cannot
call a VHDL function however trivially it evaluates.

## It refuses rather than guesses, and that caught four ports

Four ranges name things the tool cannot evaluate:

```
rg_el_reg   : in natural range 0 to NREGION-1
rg_el_addr  : in natural range 0 to region_max(RG_SHAPE)-1
```

The generator prints them and exits 1. The values are supplied explicitly with
`--const`, and they come **from the VHDL** rather than from a comment: a
three-line GHDL probe reporting `NREGION` and
`region_max(mk_shape(MODEL, NCARDS))` gives **14** and **12288**. (The
generator's own comment already guessed 12288; the probe confirms it, which is
the difference between a checked number and a remembered one.)

## Three bugs in the tool, all found by running it

Each is recorded because each produced a plausible-looking wrong answer rather
than an error.

1. **An unconstrained `integer` port was classified and then never emitted.**
   `b_gdn_w_exp : in integer` fell into a branch `main()` did not handle, so it
   was reported unhandled with no explanation of why it differed from the
   ranged integers beside it.

2. **The clog2 folder required a parenthesis-free argument.**
   `clog2(2*(256)*(16))` never matched, so **all 11 of C's ports** were
   reported unhandled. Fixed by folding innermost parenthesised arithmetic
   first, so clog2's argument is literal by construction.

3. **And that fix ate the function's own parentheses.**
   `clog2(2*256*16)` became `clog28192`, after which the clog2 pass matched
   nothing and every port was still unhandled -- **for the opposite reason,
   with an identical symptom.** Fixed with a negative lookbehind so a
   parenthesis preceded by an identifier is left alone.

Bug 3 is the interesting one: the failure mode after the fix was
indistinguishable from the failure mode before it. The only thing that
separated them was unit-checking `const_eval` against the seven real
expressions, which takes one command and is now in the record:

```
  clog2(2*(256)*(16))-1      -> 12    ok
  clog2((256)*(4))-1         -> 9     ok
  clog2((8))-1               -> 2     ok
  clog2((4))-1               -> 1     ok
  clog2((256)/(32))-1        -> 2     ok
  clog2((16)*(256))-1        -> 11    ok
  (13)-clog2((8))-1          -> 9     ok
```

## Measurement traps hit

- **GHDL cannot validate this.** The composed top instantiates UNISIM `BUFG`s
  and GHDL has no UNISIM, so `ghdl -a` fails on the TOP, not the wrapper, and
  the wrapper then fails with `unit "compose4_card" not found` -- which reads
  like a wrapper defect and is not one. Vivado `synth_design -rtl` is the
  validator; it costs about 3 minutes.
- **`ghdl -a rtl/*.vhd` in alphabetical order is not a dependency order.**
  64 files failed on the first pass. Iterating until no progress converges,
  but the first pass's output means nothing.

## Measured and REJECTED -- do not retry

- **Do not rewrite B, C or D's entity ports to please the packager.** They are
  internal seams a card top will terminate, and they carry benches.
- **Do not let the tool guess a width it cannot evaluate.** The four `rg_*`
  ports would have been silently wrong, and a wrong width in a wrapper is not
  an error anywhere -- it is a mis-wired block design.

## Open, not yet answered

- The wrapper exports all 1,300 ports. A real card top must TERMINATE the
  B/C/D seams and the region file rather than export them; this makes the
  design packageable, not connected.
- Nothing has run `--bd-only` against it, which remains the real test.
- `gen_pcieep.py`'s `ENGINE_BLOCK` still expects `fk33_engine`'s port names.
