# The pcieep bitstream build has been broken since 3a145fd, at two points

**Date:** 2026-09-03
**Build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2
**Command:** `hw/fk33/pcieep_build.sh --bd-only` (3 min, 3.4 GB, no synthesis)

## The question

Can a bitstream be built tonight, and would it contain the state-tier work?

## The answer

**No, and no.**

1. **The build ABORTS before Vivado starts**, on a guard that false-positives.
   Fixed here.
2. **With that removed it gets into the block design and fails again**, on
   `fk33_seam`'s four `natural`-typed ports, which Vivado's module inference
   rejects. NOT fixed here; it is the real next blocker.

**Defect 1 masked defect 2**, which is why neither was known.

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

## Defect 2: `fk33_seam` cannot be a block-design cell. NOT FIXED.

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

Last touched in **9270c7a**, so this predates tonight as well. The fix is to
make them `std_logic_vector` and convert inside, which also touches
`sim/tb_fk33_seam*` and whatever the BD wiring expects. **It is four ports, so
it is tractable, but it is a load-bearing file and it needs its own gate cycle.
It is not done here and nothing should claim the build works until it is.**

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

- **Defect 2 is unfixed**, so no bitstream has been produced and none can be
  until `fk33_seam`'s four ports change.
- **Whether anything downstream of `create_bd_cell` also fails** is unknown;
  the build has never got past it, so there may be a third blocker behind this
  one exactly as this one sat behind the first.
- **Nothing here has run against the card**, and `fk33_transport` still refuses
  to open a `/dev` path without an explicit `FK33_ALLOW_HARDWARE` token.
