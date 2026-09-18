# Seam bring-up on the card: what to run, in order, and what each step settles

**For Oren, at the bench. Every step here touches hardware and therefore
belongs to a human; nothing in this repository runs them unattended.**

This is bring-up of the **v2 inference seam**, not of the PCIe link. If the
card does not enumerate, `docs/2026-08-27_fk33-pcie-bringup-procedure.md` is
the file, starting with the 6-pin aux lead.

---

## Which bitstream this is for, and what it cannot do

`hw/fk33/bit/fk33_card_withA_75mhz_2026-09-17.bit`, 24,938,098 B, written
19:04 on 2026-09-17. A+B+C+D, routed, WNS +0.009.

**It predates `e62fded`, so `SMP_EN` is false and `CAPS_FLAGS` reads `0x1`:
windows only, no sampler, no logits egress.** The card can RUN a token and has
no way to REPORT one -- there is no argmax register value to read, and a v2
seam publishes no logits row (`rtl/fk33_seam.vhd:91-94`).

**So steps 1 to 5 below are the whole of what this bitstream can answer, and
that is deliberately worth doing**: they are independent of the sampler, they
are the steps that would otherwise serialise behind the next bitstream, and a
defect found in any of them is a defect that would have been blamed on the
sampler build tomorrow.

Step 6 onward needs the sampler bitstream and is written here so the order is
one document rather than two.

---

## 0. Before the card is touched

```
python3 hw/fk33/host/fk33ctl.py thermal
```

**Read the trip counter and clear it.** THERM-255: the guard trips roughly
every three minutes for reasons that are not heat, and **each trip halts the
compute domain**. As of `5e8495d` the host tools clear-and-prove rather than
warn, and print 255 as a floor rather than a count -- but that only makes a
trip VISIBLE, it does not stop one. **A stall or a wrong answer with a
non-zero trip count is not evidence about the seam.** Read it again after
every step below.

`--clear` if it is non-zero. If it will not clear, stop: `fk33_run_job.py`
now refuses in that state and so should you.

---

## 1. The shell answers

```
python3 hw/fk33/host/fk33ctl.py id
```

Expect `0x464b3333`. `0xFFFFFFFF` is a mapped-but-unanswered BAR and
`0x00000000` is a fabric in reset; neither can be mistaken for a pass, and the
tool says which it saw.

**Settles:** link, config space, BAR placement, AXI-Lite clock and reset,
smartconnect decode, and bitstream identity -- all from one read.

---

## 2. MMIO writes land

```
python3 hw/fk33/host/fk33ctl.py scratch
```

**Settles:** that writes reach the fabric, not only reads. `id` and SYSMON are
both read-only, so without this a write path could be dead and every earlier
step would still pass.

---

## 3. The seam is present and decoded -- NEW, and the first thing that reads it

```
python3 hw/fk33/host/fk33ctl.py seam
```

Landed in `67c7071`. Before it, nothing on the host read the seam at all:
`hw/fk33/host/fk33_regs.h` has no seam block, and the only other way to ask was
to bring up the whole `server/pl_backend.c` stack against `/dev/xdma*`.

**It writes NOTHING**, so it is safe against a card mid-job.

Expect, on this bitstream:

```
seam id    0x4c4c4d32   expected 0x4c4c4d32 ("LLM2") at BAR+0xE000
version    2
caps       n_vocab 248320  n_embd 4096  n_layer 32  ctx 4096 tokens
cap flags  0x00000001
  yes  WINDOWS   the DESC/REL/XIN/XOUT window port
   no  HBM_FETCH the card fetches its own D program
   no  SAMPLER   the card computes a running argmax
   no  LOGITS    the card writes the full logits row
```

**`SAMPLER no` is CORRECT on this bitstream and is the whole reason step 6
cannot run here.** On the sampler build the same line must read `yes` and the
flags `0x0000000D`.

The three diagnoses it keeps apart, and they must not be conflated:

| reading | meaning |
|---|---|
| `0x00000000` / `0xFFFFFFFF` | a dead bus -- the seam was never reached |
| a real answer that is not the magic | the seam is NOT in this bitstream, or is decoded elsewhere. An engine-only build lands here |
| the magic, `cap flags 0x0` | a TIE-OFF, not an engine |

It also re-reads its own register map against `server/fk33_seam.h` and prints
`drift  15 offsets agree`. **If it prints a DRIFT line, stop and fix that
first** -- every address below is then suspect.

**Settles:** `rtl/fk33_seam.vhd` is in this bitstream, decoded at 0xE000, its
clock and reset are alive, and the geometry it reports is the 9B shape.
**Settles nothing about whether a job computes correctly**, and the tool says
so in its own output.

---

## 4. The descriptor window takes a program and gives it back

**This is the first step that is not a read**, and it is the one worth the
most, because the v2 seam's whole premise is that the program arrives through a
window.

Generate the program first, on the host, no card:

```
python3 tools/gen_layer_program.py --token --shape 9b \
    --manifest /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json \
    --x-exp 0 --d-table token.dtbl --rel-file token.rel
```

Expect **4,040 lines** in `token.dtbl` (505 descriptors x 8 sixty-four-bit
words) and **505** in `token.rel`.

> **If it refuses with an HBM arena fault, the manifest is stale.**
> `docs/debugging/2026-09-17_gdn-arena-omitted-the-conv-tap-history.md`. The two
> manifests in use were migrated on 2026-09-17; a third copy would not have
> been. The fix is `python3 tools/hbm_map.py <manifest> --write-manifest-arenas`.

505 is checkable against the card rather than taken on trust:
`rtl/fk33_seam.vhd:123-125` predicts it (`491 - 1 + 15 = 505`), and the RTL's
own GO bounds at `:746-761` require `505 <= REL_ENT 576` and
`505 * 8 = 4040 <= DESC_WORDS 4608`. **The window in this bitstream is sized
for exactly this program.**

Then write it and read it back. **There is no host tool for this step yet** --
`server/pl_backend.c` does it (`ace2ce6`) but only over the simulated or
file transport, because nothing in this tree may open `/dev/xdma*`. Driving it
against the card means passing `FK33_ALLOW_HARDWARE` from your own caller,
which is a deliberate act and is yours: see the tripwire in
`server/fk33_transport.h`, and **do not add the token to a script, a test or a
default.**

What the sequence is, in register terms, so it can be done by hand:

```
WIN_SEL  = 0 (DESC)      BAR+0xE058
WIN_ADDR = 0             BAR+0xE05C
WIN_DATA = ...           BAR+0xE060   8,080 writes, 32-bit halves, LOW HALF FIRST
read WIN_ADDR            must read 8080.  It AUTO-INCREMENTS; a stuck address
                         is how a truncated program gets run with no complaint
WIN_SEL  = 1 (REL)
WIN_ADDR = 0
WIN_DATA = ...           505 writes
read WIN_ADDR            must read 505
TBL_LEN  = 505           BAR+0xE050
```

**Read `WIN_ADDR` back after each stream.** That check costs two register reads
and is the only thing standing between a partially-landed program and a card
that runs a different one than you sent. `pl_open` does exactly this and
refuses on a mismatch.

**Settles:** the window port works, the auto-increment works, and the card
holds the whole 505-descriptor program.

---

## 5. A GO is accepted, or refused for a reason you can read

```
SEQ_POS  = 0             BAR+0xE020
N_STEP   = 1             BAR+0xE024   <-- ONE.  Not more.  See below.
X_EXP    = <the row's exponent>       BAR+0xE054
WIN_SEL  = 2 (XIN), WIN_ADDR = 0, then 4,096 mantissa writes
CTRL     = 1 (GO)        BAR+0xE014
poll STATUS              BAR+0xE018
```

**`N_STEP` MUST BE 1.** `rtl/fk33_seam.vhd:746` refuses anything else with a
comment on the line, "one position per GO in v2". **There is no chunked
prefill on this card**: a 23-token prompt is 23 GOs, each carrying 4,096 MMIO
writes of the activation row.

STATUS decodes as `done` bit 0, `busy` bit 1, `err` bit 2, `err_code` bits
11:8. The GO-time refusals, in the RTL's own order:

| code | name | when |
|---|---|---|
| 2 | NSTEP | `N_STEP != 1`, **or** `TBL_LEN` 0, above `REL_ENT`, or needing more than `DESC_WORDS` |
| 5 | RSVD | any of `X_BASE`/`L_BASE`/`DESC_PTR` non-zero -- v2 has no HBM master |
| 8 | SEQ | `SEQ_POS` is not the card's next position |
| 1 | POS | past the KV capacity |

**Note NSTEP covers both the step count and every descriptor-bound failure.**
A host branching on `ERR_DESC` for a missing program will never fire.

Then read `FAULTS` at `BAR+0xE068`. **Every bit is a defect, not a statistic,
and every one is silent in the arithmetic.** A token whose numbers look fine
and whose `FAULTS` is non-zero has not computed what it claims.

**Settles:** subsystem D accepts a token and runs it to completion on silicon,
which has never happened. **On this bitstream that is where it ends**: there is
no argmax to read.

---

## 6 onward: needs the sampler bitstream

Not runnable on the 19:04 build. Recorded here so the order is one document.

6. `fk33ctl.py seam` must show `cap flags 0x0000000D` and `yes SAMPLER`.
7. Load the weights: `fk33_load_weights.py load <manifest> --verify`.
   250 objects, 4.18 GiB. The A descriptor arena is separate and is written
   once per model load.
8. One token, argmax read from `BAR+0xE044`, compared against `ref/run9b`.
9. Prefill 23 + decode, against
   `hw/fk33/results/goal_dcdc_2026-09-17/reference_tokens.txt`. The useful
   output is the FIRST DIVERGENCE position, not pass or fail.

---

## The thing most likely to make step 8 give a wrong number, and it is unresolved

`docs/debugging/2026-09-17_x-exp-is-baked-into-every-a-descriptor.md`.

`hw/fk33/rtl/fk33_engine.vhd:1309` sets `USE_XEXP_PORT => false`, so the card's
subsystem A takes the activation block exponent **from the descriptor** --
which the RTL's own comment calls "stale by construction" in the integrated
system -- and `tools/gen_layer_program.py` bakes ONE `--x-exp` into all 311 of
them. `rtl/seq_opdec.vhd:531` takes the region exponent from the unit's
`y_exp`, so the error propagates.

The host tool that HAS produced correct arithmetic on this silicon disagrees
with that design, in its own docstring
(`hw/fk33/host/fk33_run_layer.py:398-402`):

> no descriptor is built yet: **the x_exp a descriptor carries is a property of
> the vector that reaches the job, which in chained mode is not known until the
> previous job has run.**

**DERIVED, not measured. Nothing has been run.** But if step 8 produces
plausible-looking wrong numbers with `FAULTS = 0` and a clean trip counter,
**read that file before suspecting anything else**, because it predicts exactly
that symptom.
