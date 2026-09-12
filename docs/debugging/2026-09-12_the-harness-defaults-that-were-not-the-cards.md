# The OOC harness defaults were not the card's, and one of them moved the answer 9.4x

**Date:** 2026-09-12
**Subject:** `sim/ooc_cattnadapt.tcl` / `rtl/ooc_cattnadapt_top.vhd`, subsystem
C's data mover, measured on the BC-250 against `xcvu33p-fsvh2104-2L-e`.

## The question, verbatim

Where does subsystem C's area go, and is it large enough to be the reason the
card does not fit?

## The answer, up front

**At the card's real configuration C's mover is 112,519 LUT, 25.6% of the
part, and the area is in `attn_block`/`u_arr` -- the MAC array, i.e. the
compute.** `attn_kv_axi` is 25,485 LUT, 23% of the mover.

**An earlier answer, published and then withdrawn within the hour, said C's
mover was 325,794 LUT (74% of the part) and that `attn_kv_axi` was 238,410 LUT
of registers with zero memory primitives.** That measured a configuration
nothing will ever build. The harness top's generic DEFAULTS are not the card's,
and only three of them had been overridden.

| generic | OOC top default | the CARD | in the bad run |
|---|---|---|---|
| `C_MAXPOS` | 4 | 131072 | 4 |
| `C_CTXLEN` | 4 | 131072 | 4 |
| `C_KV_RBUF` | **64** | **4** | 64 |
| `C_KV_BLOCK` | 4 | 32 | 32 (overridden) |
| `C_N_ROT` | 8 | 64 | 64 (overridden) |

**`C_KV_RBUF` alone -- a read-buffer depth -- accounts for the bulk of it:
that block went 238,410 -> 25,485 LUT, 9.4x, and the whole measurement
325,794 -> 112,519, 2.9x.**

## The procedure

1. **Measure, then attribute INSIDE one synthesis.**
   `report_utilization -hierarchical`, not a subtraction across contexts.
2. **When two harnesses disagree about the same module, chase the
   disagreement before using either number.** A standalone harness had
   measured `attn_kv_axi` at 33,259 LUT against this run's 238,410. **That 7x
   is the only reason this was caught.**
3. **Diff the two harnesses' GENERICS, not their prose.** Dump the entity's
   generic defaults and compare against `hw/fk33/rtl/fk33_card.vhd`'s generic
   map, field by field.
4. **Check what the extracted top says against what it was extracted FROM.**
5. Re-run with every differing generic set, and confirm from a config line
   echoed by the script that they took effect.

## The evidence

Same harness, same tree, same box, only the generics differing:

```
WRONG   cfg: kv=true blk=32 rot=64   (maxpos=4 ctxlen=4 rbuf=64, all defaulted)
  ooc_cattnadapt_top   325,794 LUT   369,197 FF   296 DSP
    gcr.gkvaxi.u_kv    238,410 LUT   274,550 FF     0 DSP   0 BRAM 0 URAM
    gcr.u_attn          85,188 LUT    94,351 FF   296 DSP

RIGHT   cfg: kv=true blk=32 rot=64   maxpos=131072 ctxlen=131072 rbuf=4
  ooc_cattnadapt_top   112,519 LUT   115,424 FF   301 DSP   16 BRAM
    gcr.gkvaxi.u_kv     25,485 LUT    20,584 FF     3 DSP
    gcr.u_attn          84,918 LUT    94,521 FF   298 DSP
      u_arr             55,689 LUT    39,312 FF   256 DSP
```

Note `attn_block` is essentially unchanged (85,188 vs 84,918): the entire
difference is the KV path, which is what the mis-set generics feed.

## Measured and REJECTED -- do not retry

- **"C's area is `attn_kv_axi`."** REFUTED at the card's shape: it is 23% of
  the mover, and `attn_block`/`u_arr` is the bulk.
- **"The KV interface is built from registers where memory was intended"**
  (274,550 FF, 0 BRAM/URAM/LUTRAM). REFUTED: an artifact of `RBUF=64`. At
  `RBUF=4` the design infers 16 BRAM tiles and `ypre` as `RAM_SDP 4096x24`.
- **"C's mover is 74% of the part."** REFUTED: 25.6%.
- Two levers, separately measured with one-variable controls and both closed:
  `C_N_ROT` 8 -> 64 costs **+21 LUT**; `C_KV_BLOCK` is non-monotonic in LUT
  with its minimum at the card's 32 (413,341 / 325,794 / 350,326 at 16/32/64,
  at the WRONG maxpos/rbuf, so treat those three as a shape not a magnitude).

## Measurement traps hit

- **An extraction that changes a default has no tell.**
  `rtl/ooc_cattnadapt_top.vhd` defaults `C_KV_RBUF` to **64**; the
  `rtl/fk33_llama_top.vhd` it was extracted from says **4**, and the card does
  not override it. The harness looks exactly like the thing it came from.
- **A harness's defaults matter MORE than the design's, because measurements
  come from harnesses.** An audit of `fk33_card.vhd` against `llama_top` had
  been done the day before and would never have caught this.
- **Overriding SOME generics is more dangerous than overriding none**, because
  the config line printed `kv=true blk=32 rot=64` and looked deliberate. The
  three that were set were the three being studied; the three that mattered
  were invisible.
- **This is the fifth instance in two days of "a generic whose default is the
  simulation value"** (`C_REAL`, `C_KV_BLOCK`, `C_N_ROT`, `NORM_W_IMAGE`, and
  now the harness trio) and the first that was the author's own.

## Open, not yet answered

- Whether the composed design fits. Component figures from different contexts
  do not sum, and the only run that will answer it is the composed one.
- The `C_KV_BLOCK` sweep was taken at the WRONG `maxpos`/`rbuf`. Its SHAPE
  (non-monotonic, minimum at 32) is probably robust because it is a structural
  argument about `NBLK`, but the magnitudes are not the card's and it has not
  been repeated at the corrected settings.
- `attn_kv_axi` standalone measured 33,259 LUT against 25,485 here. Same
  order, still not identical, and the residual difference is unexplained.
