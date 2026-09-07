# The card is a TWO-cell block design, and both cells now exist

**Date:** 2026-09-07. Status note, written to make the next step executable
rather than to record a measurement.

## The architecture, established today

Subsystem A appears in this repository as **two different units**, and
conflating them is what made the BD question look larger than it is:

| unit | masters | who instantiates it |
|---|---|---|
| `matvec_int4` | **5** (`A_NPORTS`: 4 weight + 1 scale, pinned by `weight_streamer.vhd` at `ROWS_IF = 4`) | `llama_top:3516`, the simulation path |
| `matvec_int4_desc_axi` | **28** (27 weight/scale + 1 descriptor) | `hw/fk33/rtl/fk33_engine.vhd`, the card path |

`fk33_llama_top`'s `ga_desc` generate (behind `A_DESC`) instantiates
**`a_job_counter` and `a_desc_adapter` only** -- the descriptor CONTROL plane.
It does not contain an A compute unit at all. That is not an omission; it is
the design. A lives in its own BD cell.

So the card is:

```
   +-------------------------+            +---------------------------+
   |  fk33_engine   (cell A) |            |  fk33_card   (cell B+C+D) |
   |  matvec_int4_desc_axi   |            |  fk33_llama_top,          |
   |                         |            |   A_DESC   = true         |
   |  s_axi   <--------------+------------+-- a_awaddr/a_wdata/...    |
   |  d_x_*   <--------------+------------+-- a_x_we/a_x_waddr/...    |
   |  d_y_*   --------------->------------+-> a_y_we/a_y_data/...     |
   |  job_index <------------+------------+-- a_job_index             |
   |                         |            |   B_STATE_AXI = true      |
   |  m00..m27 -> SAXI       |            |   C_KV_AXI    = true      |
   +-------------------------+            |   bst_* -> SAXI           |
                                          |   kv_*  -> SAXI           |
                                          +---------------------------+
```

**The seam between them is already exported and already BD-legal**: 23
`a_*` ports on the card top, every one `std_logic` or `std_logic_vector`.
They were added by the D1/D2 work earlier in this session.

## What is done

- **Cell A exists and is wired.** `gen_pcieep.py`'s `_eng_block()` creates it
  with its 28 masters named and clock-associated. It has built to a bitstream.
- **Cell B+C+D exists and elaborates.** `tools/gen_bd_wrapper.py` gives
  `fk33_llama_top` a packager-legal face: **141 ports, 0 refusals, no generic
  clause**, and it elaborates in Vivado with **zero errors** at
  `B_STATE_AXI=true C_KV_AXI=true C_KV_BLOCK=32` (`CARD_ELAB_OK bitports=3588`).
  That configuration had never been elaborated before.
- **The HBM contention between them is solved in RTL.** `rtl/bc_port_grant.vhd`
  arbitrates B's 2 masters and C's 3 onto 3 shared ports with a drain
  interlock, verified at 8,761 checks with a 4-row mutation table.

## What is next, in order

1. **Un-flatten C's read side. That is the whole of it, and it is TWO
   interfaces.** MEASURED on the generated top:

   | signal group | shape | needs splitting |
   |---|---|---|
   | `kv_ar*` / `kv_r*` | `std_logic_vector(1 downto 0)`, `2*C_KV_ADDR_W`, `2*C_KV_AXI_DW` | **yes, 2 masters** |
   | `kv_aw*` / `kv_w*` / `kv_b*` | single, `std_logic` | no |
   | `bst_*` | single, `std_logic` | no |

   So cell B+C+D presents **five** masters (B read, B write, C read 0, C read 1,
   C write) of which only C's two reads are flattened. *"Vivado's block designer
   cannot see a flattened vector as AXI at all"* (`gen_fk33_engine.py`'s own
   words) applies to exactly those two. Cell A needed a 28-master generated
   wrapper for this; cell B+C+D needs a two-interface split.

   `A_NPORTS` is 5 on this top and is irrelevant to the card, because A's
   masters come from cell A.
2. **Add the second cell to `gen_pcieep.py`** beside `_eng_block()`, wire the
   23-port seam, and map `bst_*`/`kv_*` onto the spare SAXI ports through
   `bc_port_grant`.
3. **`--bd-only`.** 3 minutes, 3.4 GB, and it is the only thing that tests any
   of the above. Nothing schedules it, which is how the build stayed dead from
   `3a145fd`.
4. **Full build**, at `FK33_ENG_CORE_MHZ=175`.

## The two open risks, stated as risks

- **Fit.** MEASURED on the COMPOSED top, not this one: engine plus both HBM
  memory subsystems places at 94.47% CLB, and with the shell the density needed
  device-wide is ~6.20 LUT/CLB against the 5.72 already called *"essentially no
  freedom to spread"*. This two-cell design has never been synthesised, so its
  own number is unknown. **The composed figures are a lead, not a forecast.**
- **The port budget.** A's 28 plus B's 2 plus C's 3 is 33 against 30 available.
  The grant closes B-versus-C to 3 shared, giving 31, and the descriptor master
  sharing a data lane closes the last one. None of that is wired yet.
