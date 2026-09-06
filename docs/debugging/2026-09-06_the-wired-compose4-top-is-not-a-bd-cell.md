# The wired compose4_top is not a BD cell, and `--wire` makes that worse

**Date:** 2026-09-06
**Question:** the chosen route to the first full A+B+C+D bitstream is *"BD
instantiates the wired compose4_top"* -- point `gen_pcieep`'s engine cell at
`gen_compose4_top.py --wire` instead of `fk33_engine`. The stated cost was
rewriting `gen_pcieep`'s ENGINE_BLOCK for instance-prefixed port names and
mapping B and C onto SAXI_30/31. Is that the whole cost?

## The answer, up front

**No.** Three things block it, none of them reachable by any bench, and the
third was not in the option text at all:

1. The wired entity has **22 ports the block-design packager rejects outright**
   -- 18 `integer` and 4 `natural` -- each a `[IP_Flow 19-734]` failure.
2. **`--wire` INTRODUCES all four `natural` ports.** The unwired top has zero.
   Two of them are ranged `0 to region_max(RG_SHAPE)-1`, a function call over a
   record-typed generic, so they would also trip `[IP_Flow 19-627]` even if the
   type were allowed.
3. **The D-to-A token DATA seam is not wired.** `--wire` connects control only.
   `grep -nE 'd_x_we|d_y_we|d_x_wdata|d_y_data' hw/fk33/gen_compose4_top.py`
   returns **nothing**: the generator has no handling of it whatsoever.

The premise of the choice still holds -- the D-to-A *control* wiring and B's and
C's handshakes really are there. It is the cost estimate that was wrong.

## The measurement

Port-name set difference between the committed (unwired) `compose4_top` and a
freshly generated `--wire` variant, rather than a count of either:

```
unwired: natural=0  integer=18  total=1195
wired:   natural=4  integer=18  total=1185
```

`--wire` is a net -10 ports: it **consumes 32** and **adds 22**.

**Consumed (32)** -- and this is the part that makes the choice sound:

| group | ports |
|---|---|
| A's descriptor AXI-Lite write channel | `a_eng_s_axi_aw*`, `_w*`, `_b*` (11) |
| A's job index and completion | `a_eng_job_index`, `a_eng_d_job_done`, `a_eng_d_job_err` |
| B's control handshake | `b_gdn_start/busy/done/err_conv/err_g/err_se` |
| C's control handshake | `c_attn_start/busy/done/done_ack/err` |
| D's fetch seam | `d_fetch_u_start/ready/done/err/u_ack/job_epoch/done_epoch` |

**Added (22):** `a_arena_base`, `a_index_err`, `a_jobs_issued`, and the entire
19-port region-file interface `rg_*`.

**All four `natural` ports are in that added set:**

```
rg_el_reg    : in natural range 0 to NREGION-1;
rg_el_addr   : in natural range 0 to region_max(RG_SHAPE)-1;
rg_el_wreg   : in natural range 0 to NREGION-1;
rg_el_waddr  : in natural range 0 to region_max(RG_SHAPE)-1;
```

The 18 `integer` ports are present in BOTH and belong to **17 B, 1 C**
(`b_gdn_layer`, `b_gdn_st_rhead`, `c_attn_layer`, ...).

**The data seam is still exported in the wired top**, which is the direct
evidence for point 3:

```
a_eng_d_x_we    : in  std_logic;
a_eng_d_x_waddr : in  std_logic_vector(15 downto 0);
a_eng_d_x_wdata : in  std_logic_vector(15 downto 0);
a_eng_d_y_we    : out std_logic;
a_eng_d_y_data  : out std_logic_vector(48*64-1 downto 0);
```

## What is NOT a problem

- **The `std_logic_vector` widths are safe.** Every one is arithmetic on
  literals, because the generator substitutes numbers before emitting:
  `(4)*(4)*16-1`, `48*64-1`, `(128)/(32)-1`. None is a function of a generic,
  so `[IP_Flow 19-627]` does not apply to any vector port.
- **`signed` and `unsigned` are accepted** by the packager -- 46 and 90 ports
  respectively -- as already MEASURED by the passing `--bd-only` that named
  only the `natural` ports. Do not "fix" these.

## What this implies for the plan

The BD cell cannot be `compose4_wired` as generated. It needs a thin BD-facing
wrapper that instantiates it and presents only clocks, resets, the host
AXI-Lite and the HBM masters:

1. terminate the 18 B/C `integer` observability ports;
2. terminate or internalise the 19 `rg_*` ports, including the 4 `natural`;
3. **wire `a_eng_d_x_*` and `a_eng_d_y_*` internally**, which is new logic, not
   a re-export.

Item 3 also qualifies the composed timing record: **those routed numbers were
taken on a design in which D and A are not connected on the data path.** The
connection is 3,072 bits of `d_y_data` plus its address and mask. It is not
free, and no existing measurement includes it.

## Measured and REJECTED -- do not retry

- **Do not read `--wire` as "wires the subsystems together".** Its own help text
  says *"connect D to A instead of exporting both"*, and MEASURED it wires
  CONTROL only. The datapath is absent from the generator entirely.
- **Do not assume the wired top is closer to packageable than the unwired one.**
  On the `natural`-port criterion it is strictly further: 4 against 0.
- **Do not hand-edit `hw/fk33/rtl/compose4_top.vhd`.** Line 2 says GENERATED,
  and the committed file is deliberately the UNWIRED measurement vehicle whose
  numbers are quoted elsewhere. The wired variant must be generated to its own
  output, as here (`--entity compose4_wired --out ...`).

## Measurement trap hit

I first compared the two port *counts* (1195 vs 1185) and read the -10 as "`--wire`
consumed ten ports". It consumed 32 and added 22. **A net count of a set
difference hides both halves**, and the added half is where all four blocking
`natural` ports live -- so the count pointed the opposite way from the truth.
`comm -23` / `comm -13` on the sorted name sets took one command and settled it.

## Open, not yet answered

- Whether the `rg_*` region-file interface is meant to leave the composed top at
  all, or is exported only so synthesis cannot optimise the region file away.
  That decides whether the wrapper terminates it or the generator should.
- The area and timing cost of the D-to-A data connection. Unmeasured.
