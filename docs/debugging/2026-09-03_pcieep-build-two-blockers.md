# The pcieep bitstream build has been broken since 3a145fd, at two points

**Date:** 2026-09-03
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2
**Command:** `hw/fk33/pcieep_build.sh --bd-only` (3 min, 3.4 GB, no synthesis)

## The question

Can a bitstream be built tonight, and would it contain the state-tier work?

## The answer

**The block design now builds. Nothing has been synthesised, and a bitstream
would contain subsystem A only.**

Two defects, each hiding the next:

1. **The build ABORTED before Vivado started**, on a guard that
   false-positived on a comment. Fixed.
2. **With that removed it reached the block design and failed again**, on
   `fk33_seam`'s four `natural`-typed ports, which Vivado's module inference
   rejects. Fixed, in two steps -- the obvious fix produced a THIRD error.

**Defect 1 masked defect 2**, which is why neither was known. The end state,
MEASURED by `hw/fk33/pcieep_build.sh --bd-only`:

```
BD4_EXIT 0
errors: 0
FK33_BD_VALIDATE OK
FK33_BD_ONLY_DONE
```

read with line-anchored greps (`grep -cE '^FK33_BD_VALIDATE OK'` -> 2), not
from a tail, because this script echoes its own source into its log.

**This is `--bd-only`. It is NOT a bitstream.** `synth_design`,
`place_design`, `route_design` and `write_bitstream` have never run on this
path, so a third blocker behind this one remains possible -- exactly as this
one sat behind the first.

And separately: a bitstream would contain **subsystem A only**.
`hw/fk33/rtl/fk33_engine.vhd` instantiates exactly one entity,
`matvec_int4_desc_axi`. There is no B, no D, no state tier in the endpoint
design, so building one would not carry any of 2026-09-03's B work.

## Defect 1: the D-presence guard matched a COMMENT

`hw/fk33/gen_pcieep.py`'s `_check_seam_d_consistency` asserts that the seam's
`d_err` tie-off and the presence of subsystem D agree. Its detection was:

```python
has_d = re.search(r"\bllama_top\b", eng_src) is not None
```

`fk33_engine.vhd` has carried three COMMENT references to `llama_top.vhd`'s
line numbers since **3a145fd** ("fk33_engine gains a D-facing surface"):

```
188:    -- one element per cycle, the same shape llama_top's own A adapter
189:    -- drives (`llama_top.vhd:3197-3226`).
203:    -- contract, not a choice made here (llama_top.vhd:3217-3220 says the
```

They are citations of a contract, not an instantiation. So every run since that
commit died with:

```
ABORT: .../fk33_engine.vhd instantiates llama_top, so subsystem D IS in this
design, but SEAM_BLOCK still ties the seam's d_err HIGH.
```

about a design that does not instantiate it.

**The guard's DESIGN is sound and is kept** -- it checks BOTH directions, and
the opposite arm (tie-off removed while D is absent) is a real hazard it names
precisely. Only the detection was wrong. It now strips VHDL comments and
matches an instantiation:

```python
eng_nc = re.sub(r"--[^\n]*", "", eng_src)
has_d = (re.search(r"entity\s+work\.llama_top\b", eng_nc) is not None
         or re.search(r":\s*llama_top\s", eng_nc) is not None)
```

**TEETH, both directions, MEASURED:**

| `fk33_engine.vhd` contains | verdict |
|---|---|
| the three comment references only | `FK33_SEAMMAP tie-off present and fk33_engine.vhd has no llama_top -- consistent` |
| a real `u_teeth : entity work.llama_top port map(...)` inserted | **`ABORT`** |

The second row is the control: without it, "the abort stopped happening" is
equally consistent with having broken the guard entirely.

## Defect 2: `fk33_seam` cannot be a block-design cell. FIXED.

With defect 1 gone the build reaches `create_bd_cell` and fails:

```
ERROR: [IP_Flow 19-734] Port 'hw_reg': Port type 'natural' is not recognized.
  Only std_logic and std_logic_vector types are allowed for ports.
ERROR: [IP_Flow 19-734] Port 'hw_addr': ... 'natural' ...
ERROR: [IP_Flow 19-734] Port 'hr_reg':  ... 'natural' ...
ERROR: [IP_Flow 19-4668] Failed to infer definition from module 'fk33_seam'.
ERROR: [BD 41-1699] Unable to add reference type cell for reference-module 'fk33_seam'
```

`rtl/fk33_seam.vhd`'s entity has exactly FOUR such ports:

```
73:    hw_reg       : out natural range 0 to NREG-1;
74:    hw_addr      : out natural range 0 to REGMAX-1;
76:    hr_reg       : out natural range 0 to NREG-1;
77:    hr_addr      : out natural range 0 to REGMAX-1;
```

Last touched in **9270c7a**, so this predates tonight as well.

### The obvious fix produced a THIRD error

Converting the ports to `std_logic_vector` with the width written the way the
rest of the file writes widths:

```vhdl
hw_reg : out std_logic_vector(clog2(NREG)-1 downto 0);
```

is correct VHDL, elaborates, and Vivado's IP packager still refuses it:

```
ERROR: [IP_Flow 19-627] Unsupported function call "clog2" in the expression
```

**A block-design port width is an XPath expression over the cell's generics,
evaluated by the packager, not by VHDL.** It can reference a generic and do
arithmetic on it; it cannot call a VHDL function, so no function of `NREG` is
admissible however trivially it evaluates. This is a genuinely different
constraint from `19-734` and is invisible until `19-734` is gone.

### What actually works: carry the width as a generic

Two new generics, and the ports sized directly from them:

```vhdl
generic (
  HREG_W  : positive := 4;
  HADDR_W : positive := 12;
  ...
);
port (
  hw_reg  : out std_logic_vector(HREG_W-1  downto 0);
  hw_addr : out std_logic_vector(HADDR_W-1 downto 0);
  hr_reg  : out std_logic_vector(HREG_W-1  downto 0);
  hr_addr : out std_logic_vector(HADDR_W-1 downto 0);
);
```

`HREG_W-1` is arithmetic on a generic, which the packager accepts.

**A generic that must agree with a derived value is a new way to be silently
wrong**, so the agreement is enforced TWO-SIDED, in the architecture, using the
out-of-range-`natural` idiom because Vivado ignores `assert ... severity
failure` in synthesis:

```vhdl
constant bad_hreg_w_small  : natural := HREG_W - clog2(NREG);
constant bad_hreg_w_big    : natural := clog2(NREG) - HREG_W;
constant bad_haddr_w_small : natural := HADDR_W - clog2(REGMAX);
constant bad_haddr_w_big   : natural := clog2(REGMAX) - HADDR_W;
```

Either direction of disagreement makes one of the four negative and fails
elaboration. A one-sided check would have let a too-WIDE port through.

`use work.util_pkg.all;` was added for `clog2`. That is safe in the BD project
specifically because `build_fk33_pcieep.tcl:187` already adds `util_pkg` to it;
it was checked rather than assumed.

`sim/tb_fk33_seam.vhd` converts at the bench boundary, because `llama_top`'s
matching host-window ports are still `natural`. **Only the seam's own entity
had to change**, which is why this stayed at four ports.

### Evidence

- `sim:tb_fk33_seam` **PASS, 52 s** (a live gate row, not a new one written to
  agree with the change): `tb_fk33_seam: PASS -- a whole token ran with llama`.
- `--bd-only`: `BD4_EXIT 0`, `errors: 0`, `FK33_BD_VALIDATE OK`,
  `FK33_BD_ONLY_DONE`.
- `FK33_SEAMMAP tie-off present and fk33_engine.vhd has no llama_top --
  consistent`, i.e. defect 1's guard now agrees with reality instead of with a
  comment.

## Defect 1's teeth test was built from defect 1

Found 2026-09-03 by the full gate, AFTER the fix landed: `sim:runguard` went
red with *"the seam tie-off guard does not discriminate as claimed"*.

`gen_pcieep.py`'s `seam_tieoff_teeth()` constructs the state "subsystem D is
present" like this:

```python
with_d = no_d + "  -- u_top : entity work.llama_top\n"
```

**That is a comment.** The selftest asserted that a commented-out
instantiation MEANS subsystem D exists, which is exactly the misconception the
detector had. Both were wrong in the same direction, so the four rows agreed
with each other and the suite passed **every day the build was dead**. Fixing
the detector is what finally made them disagree, and the "failure" was the
selftest catching up, not a regression.

**A teeth test whose mutant is built from the same misconception as the check
cannot detect that misconception.** Construct the mutant from the THING -- a
real instantiation -- never from the check's notion of it.

Fixed by making `with_d` a real instantiation, and adding the two rows that
never existed:

| row | state | verdict |
|---|---|---|
| S5 | tie-off present, `llama_top` in COMMENTS only | must ACCEPT |
| S6 | no tie-off, `llama_top` in COMMENTS only | must REFUSE |

S5 is the shipping state, verbatim the shape `fk33_engine.vhd` has carried
since 3a145fd.

### Attribution control

The pre-fix detector (`re.search(r"\bllama_top\b", eng_src)`, no comment
stripping) run against all six rows:

```
S1 accepted   S2 REFUSED   S3 REFUSED   S4 accepted   -- all CORRECT
S5 REFUSED  <== WRONG      S6 accepted <== WRONG
```

**The four original rows are insensitive to the defect in BOTH directions.**
They pass identically with the broken detector and the fixed one. S5 and S6
are the entire discrimination. Without the control the fix would have been
credited to a suite that cannot see it.

## A static gate row now covers the port class

`sim/check_bd_ports.py` (row `sim:bdports`, milliseconds) parses every entity
named by a `create_bd_cell -type module -reference` and refuses a port that is
not `std_logic`/`std_logic_vector`/`signed`/`unsigned`, or whose width calls a
function. Five cells, 1,860 ports today.

`signed` and `unsigned` ARE accepted despite 19-734's wording. MEASURED: the
`--bd-only` run that succeeded had ELEVEN such ports on `fk33_seam` and the
packager named only the four `natural` ones. **The first version of the
checker trusted the error TEXT instead and reported 11 failures against RTL
that demonstrably builds** -- the same class of error as the selftest above,
caught the same way, by running it against reality.

Teeth: M1 (`natural` port), M2 (`clog2` width), M3 (cell with no entity),
M4 (all `create_bd_cell` lines broken -> refuses the vacuous scan), M7
(`signed` width calling a function) all KILLED. Controls that must NOT bite
and did not: M5 a new `unsigned` port on a BD cell (port count 1860 -> 1861,
so it was parsed and accepted); **M6 a `natural` port added to `llama_top`,
which is not a BD cell (port count unchanged, so llama_top was never scanned)**
-- that is the control distinguishing "checks block-design cells" from "greps
the tree for the word natural".

**It does NOT replace `--bd-only`.** It checks entities, not the block design.

## Measured and REJECTED -- do not retry

- **"The bitstream path does not contain `llama_top`, proven by grepping
  `fk33_engine.vhd`."** The CONCLUSION is right, the EVIDENCE was not: that
  file is GENERATED, and the first grep was against a stale copy before
  `gen_fk33_engine.py` had run. CLAUDE.md already says to check line 2 of any
  `.vhd` before trusting it; the same applies to reading one. The sound
  evidence is the entity census of the regenerated file plus `gen_pcieep.py`'s
  own abort arm, not a grep of whatever is on disk.
- **"It does not fit in memory, so it cannot be run."** That was true earlier
  (25.0 GiB peak against 13 GB free while `llama-cpp-server` held 18). It is
  NOT true now: that service is inactive and there is 23 GB free plus 27 GB of
  swap. Memory is not the blocker; defect 2 is. Do not cite the memory figure
  as the reason again without re-measuring `free`.

## Measurement traps hit

- **`--bd-only` costs 3 minutes and 3.4 GB and finds everything that is not a
  timing or placement result.** Both defects here were found by it. There was
  no reason to have gone weeks without running it except that NOTHING SCHEDULES
  IT -- the same rot as `server_e2e.py` (silently red for days),
  `sim:cardtop`'s eight dead source closures, and the four `llama_top` mutation
  harnesses that would have broken unnoticed. **A build script no gate runs is
  a build script that has already stopped working; you just have not looked.**
- **A haystack that can contain your needle in a context you did not mean.**
  This is the THIRD instance in one session, after `pgrep -f` matching its own
  command line and a sentinel `grep` matching the script embedded in its own
  log. Here it is a guard matching a comment. Anchor the match, or pick a
  needle the haystack cannot hold.

## Open, not yet answered

- **NO BITSTREAM HAS BEEN PRODUCED.** `--bd-only` stops before synthesis by
  design. Whether `synth_design` / `place_design` / `route_design` /
  `write_bitstream` succeed on this path is untested, and the composed
  `compose4_top` route that IS measured (`core_clk` -0.090 ns with high-effort
  directives) is a different top, so it does not answer this.
- **A third blocker behind `create_bd_cell` remains possible.** Each fix so far
  produced a DIFFERENT error, which is the sign the layers are real; there is
  no reason to assume this one was the last.
- **`HREG_W`/`HADDR_W` defaults (4, 12) are only checked at ELABORATION.** A
  caller that instantiates the seam with a mismatched pair gets a hard failure,
  which is intended -- but a caller that never elaborates (a packaged IP reused
  with different generics) would not hit it. Nothing does that today.
- **Nothing here has run against the card**, and `fk33_transport` still refuses
  to open a `/dev` path without an explicit `FK33_ALLOW_HARDWARE` token.
