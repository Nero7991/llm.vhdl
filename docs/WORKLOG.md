# Parallel worklog

A live board, not a report. One section per track that is in flight, the files
each track owns so two agents cannot collide, and **the next step written down
BEFORE the result arrives**, branched by what the result could be.

Why the branches are pre-written: deciding what to do next while holding a
fresh result is how scope drifts and how a negative result gets talked into
being a positive one. If the branch was written before the answer was known,
the answer only has to be classified, not argued with.

**Discipline for closing a track.** When an agent lands, do exactly one of:

- **MARK OFF** the branch that fired, move the row to the Landed table with its
  commit, and dispatch whatever that branch names.
- **WRITE THE ISSUE DOWN** in Open issues below, with the evidence, then either
  send the agent a follow-up (if the fix is determined) or raise it with Oren
  (if it is a decision rather than a fix). Never silently retry.

Status values: `RUNNING`, `LANDED`, `BLOCKED-DECISION` (needs Oren),
`BLOCKED-DEP` (waiting on another track).

---

## File ownership, right now

Two agents editing one file has already cost this project real time. Nothing
below may be edited by a track that does not own it.

| path | owner | note |
|---|---|---|
| `sim/regress.sh` | **SHARED** | any track adding a test edits it. Re-read it immediately before editing, keep the edit to the rows you add, and re-check `BASELINE_PASS` at commit time. |
| `rtl/llama_top.vhd`, `sim/tb_llama_top.vhd`, `rtl/llama_map_pkg.vhd` | free | released by the integration track at `3246046` |
| `hw/fk33/gen_pcieep.py` | free | released by the HBM-port track (it deliberately changed nothing) |
| `rtl/attn_*.vhd`, `sim/tb_attn_block.vhd`, `ref/attn_*` | TRACK C-ORACLE | |
| `rtl/gdn_*.vhd`, `rtl/l2norm_rs.vhd`, `sim/tb_gdn_*.vhd`, `sim/tb_l2norm_rs.vhd`, `ref/gdn_*`, `ref/l2norm*` | TRACK B-ACCURACY | |
| `tools/qwen35_tokenizer.py`, `tools/*tokenizer*`, `server/**` | TRACK TOK-C | |
| `rtl/matvec_int4*.vhd`, `rtl/weight_streamer.vhd`, `rtl/axi_rd_port.vhd`, `hw/mv_driver.c` | UNOWNED, see Open issues | the A control plane. Blocked on a decision. |

**Standing rule for every track: no hardware.** No `xsdb`, `hw_server`,
`vivado ... program`, `pcieep.sh`, `jtag.sh`, `flash.sh`, `program.tcl`, and
nothing that opens `/dev/xdma*`. A live FK33 is in this session, and an agent
has already destroyed its factory flash image by crossing that line.

---

## In flight

### TRACK C-ORACLE -- does `attn_block` compute attention?

**Status:** RUNNING (dispatched 2026-08-28)
**Owns:** `ref/attn_block_vec.c` (new), `sim/tb_attn_block.vhd`, `rtl/attn_*.vhd`

**The question.** `attn_block` is wired into `llama_top` and a 32-block token
passes, but the integration bench says in its own PASS line that **nothing
establishes it computes attention**. Subsystem C has no block-level reference
anywhere. Eight units are individually excellent and the composition is
unchecked.

**Pre-written next steps:**

- **If bit-exact against a new independent C oracle** -> mark off. Next: raise
  C from "auxiliary path verified" to "block verified" in the audit, and open
  `attn_kv_axi` (the HBM KV interface, still absent) as the remaining C gap.
- **If it diverges** -> this is the most valuable outcome available today and
  must NOT be worked around. Write the divergence down with the failing case,
  bisect to the unit, and report. Do not adjust the oracle to agree.
- **If a block-level oracle proves impractical** (e.g. the block's schedule is
  not reproducible outside the simulator) -> say so plainly, and fall back to
  checking the ARRAY (`attn_mac_array`) against `ref/attn_mac_array_vec.c`
  under the block's real schedule. Partial coverage honestly labelled beats a
  block-level claim that is not real.
- **If it hits `attn_emit.vhd:400`** (the `NGRP=1` bound violation) -> that is
  a known latent defect, recorded below. Do not fix it inside this track
  without saying so; note it and route around with `NGRP >= 2`.

### TRACK B-ACCURACY -- the two places B checks transcription but not arithmetic

**Status:** RUNNING (dispatched 2026-08-28)
**Owns:** `rtl/gdn_recur_pipe.vhd`, `rtl/l2norm_rs.vhd`, their benches, `ref/gdn_*`, `ref/l2norm*`

**The question.** Two measured holes from the completeness audit:
1. `gdn_recur_pipe` is the SHIPPING recurrence and its bench **explicitly
   discards the oracle's accuracy columns** (`sim/tb_gdn_recur_pipe.vhd:147-148`
   reads and drops oracle `u` and `o`). It is checked only for equality with
   `gdn_recur`'s recipe, so a shared recipe error is invisible.
2. `l2norm_rs` is tolerance-checked against `math_real` at 0.75 LSB and
   **`ref/` contains no l2norm model at all**.

**Pre-written next steps:**

- **If both close bit-exactly** -> mark off, and B moves from "most complete"
  to genuinely oracle-covered. Next: B still has **zero** mutation coverage;
  open that as the follow-on.
- **If `gdn_recur_pipe` diverges from the accuracy oracle** -> that is a real
  finding about the shipping unit. Report it, do not relax the check, and do
  not "fix" it by reinstating the discard.
- **If `l2norm_rs` cannot be made bit-exact** (e.g. it is genuinely an
  approximation with a specified error bound) -> then the deliverable changes
  to: state the bound, prove it holds over an adversarial input sweep, and say
  so. A documented bound is a real result; a silent tolerance is not.
- **If either needs an RTL change** -> stop and report before changing RTL that
  `llama_top` now depends on.

### TRACK TOK-C -- the tokenizer in C, so the server can link it

**Status:** RUNNING (dispatched 2026-08-28)
**Owns:** `server/**`, `tools/*tokenizer*`

**The question.** `tools/qwen35_tokenizer.py` is verified bit-exact against
llama.cpp over 53,411 strings and a 1.1M-codepoint sweep, but
`server/llama_server.cpp` is zero-dependency C++ and cannot link Python.

**The trap, already measured and NOT to be rediscovered:** Python's
`unicodedata` is Unicode 13.0.0 here and disagrees with llama.cpp on 4,704 of
1,112,064 codepoints. Category tables must come from the SAME UCD as the
oracle. Port the `llamacpp` state-machine backend, not the `regex` one.

**Pre-written next steps:**

- **If C matches the oracle over the same corpus and sweep** -> mark off. Next:
  the server seam itself, which is `BLOCKED-DEP` on the descriptor format.
- **If it matches the Python but not llama.cpp** -> the Python is the suspect,
  not the C. Report both.
- **If the Unicode tables balloon the binary or the build** -> report the size
  and ask before adding a dependency. `llama_server.cpp` being zero-dep is a
  deliberate property, not an accident.

---

## Open issues

### OI-1: the subsystem A control plane needs a design decision (BLOCKED-DECISION)

A is bit-exact at the FK33 geometry and the HBM can serve its 27 masters
(30 already measured at 288.0 GB/s, 100% of ceiling). Three things stand
between that and arithmetic on silicon, and the first is a decision:

1. **The register map.** `rtl/matvec_int4_axi.vhd:252,265` asserts
   `NPORTS_W=4 / NPORTS_S=1` and holds four `W_BASE`/`W_BASE_HI` pairs plus one
   `S_BASE` pair. FK33 needs 24+3. Its own header argues the map must NOT grow
   with a generic, on the grounds that it would be "a map no driver could
   parse". So this is a fork, not an edit.
2. **The HBM-to-core CDC does not exist.** `weight_streamer` is single-clock.
   At ACLK = f_core the duty is exactly 100% with zero margin, so the CDC is
   mandatory.
3. **`axi_rd_port`'s `MAXOUT` defaults to 2** (32 outstanding beats); the
   measured 288 GB/s run used 16.

Items 2 and 3 are determined work. Item 1 is Oren's call.

### OI-2: `attn_emit.vhd:400` is a bound violation at `NGRP = 1` (latent)

`grp` is declared `integer range 0 to NGRP-1` (`:263`) and line 400 assigns
`grp <= 1` unconditionally. `NGRP` is `positive`, so `NGRP = 1` (one KV head)
is a legal generic value that is an immediate bound violation. Default is 2,
so nothing hits it today. Found by the integration track, verified directly,
deliberately not fixed.

### OI-3: the bench cannot see two classes of defect

Of nine mutations on the integration bench, **two pass while broken**: an
exponent claim re-aimed at R_X, and the prefetch consuming at k-3. Both change
every element and no property in the bench can observe either. Fourth and fifth
instance of the same family. This is the honest ceiling on what `tb_llama_top`
proves, and it is not closed by any track above.

### OI-4: no descriptor-program generator exists, in any language

Subsystem D's control core is integrated and mutation-tested, but nothing emits
the descriptor program it executes. This is **host software** and it is on the
critical path for both the card and the server. Blocked on the descriptor
format being settled.

---

## Landed

| track | result | commit |
|---|---|---|
| Thermal guard synthetic trip | Guard halts, latches, freezes compute, releases. Teeth-checked. | `0b8831c` |
| Subsystem A at FK33 geometry | Bit-exact from real `.mv4i` bytes, 27 masters. Regression 76 -> 77. | `055b6ed` |
| AXI3 burst cap | HBM is AXI3, 16 beats not 128. Bit-exact at both; bench now runs the legal one. | `809ada7` |
| HBM port feasibility | 27 masters fit; 30 already measured at 288.0 GB/s, 100% of ceiling. Design note only. | doc only |
| Qwen3.5 tokenizer | Bit-exact vs llama.cpp, 53,411 strings x 2 + 1.1M codepoints. 7 of 9 mutations bite. | `4123bd8` |
| Magnitude blocker | Explosion was the STIMULUS (synthetic row norm 2^4.87 vs real 2^-0.03). PART 5 withdrawn, PART 3 reinstated. `attn_block` wired behind `C_REAL`. | `3246046` |
