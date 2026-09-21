# Build 12b on silicon: it works, and the measurement has almost no noise

MEASURED 2026-09-21 17:54-18:0x by the main session (authorised for hardware;
subagents never). Card 1, `xcvu33p-fsvh2104-2L-e`, PCIe Gen3 x4.

## Load

`hw/fk33/host/fk33_reload.sh hw/fk33/bit/fk33_card_build12b_control_75mhz_2026-09-21.bit`,
**without `--with-vccint`**, so the rail was left alone.

```
ID_OK       magic=0x464B3333  build=0x20260828  ("FK33")
SYSMON      die=42.2 C  VCCINT=0.7162 V
VCCINT_OK   0.7162 V                  <- wiper 68, NOT 0.85 V
HBM_OK      scratch page 0x1FFFFF000 writes and reads back (both stacks mapped)
DMABRAM_OK  0x200000000 holds the four expected words
LnkSta      Speed 8GT/s (ok), Width x4 (ok)
FK33_PCI_UP / BUS_UP_OK
```

Bitstream sha256
`0349d7c48a437cea99a784ad0c2381f7e04f520cacf98a56555d7fc1be42a064`, identical to
the committed `bd_wrapper.bit` and to `KEEP_build12b_dcp/SHA256SUMS`.

## A REAL TRAP FOUND: THE IMAGE RECORD SURVIVES A RECONFIGURATION THAT DESTROYS THE PAYLOAD

Immediately after the reload, the two residency instruments **disagreed**:

```
fk33_imgfp.py which        -> .../qwen35-9b-mv4i-noembd-striped-seg27/manifest.json
fk33_resident_image.py     -> NO KNOWN IMAGE RESIDENT
```

The 512-byte image record in the descriptor arena's reserved tail survived; the
weight payload did not. **`fk33_chat.sh` prefers the record over the byte probe**
("The record wins where it exists", `fk33_chat.sh:~56`), so on this card state it
would have accepted a wiped image and run against garbage.

This is a guard that passes for the wrong reason, and the cheap fix is available
because the loader already does the right thing in the other direction: it ZEROES
the record before writing (`image record at 0x1ffb03e00 zeroed: the card reports
NO IMAGE until this load finishes`). What is missing is invalidating the record on
RECONFIGURATION, which no host tool currently does because reconfiguration happens
outside them. **Suggested: have `fk33_reload.sh` zero the record's 512 bytes after
`BUS_UP_OK`, so a stale record cannot outlive the bitstream that filled HBM.**
Not implemented here; recorded as a finding with a named owner action.

## Weights reloaded and fully verified

```
loading 251 objects, 4.49 GB, H2C
wrote 4,489,027,584 bytes in 8.35 s = 0.54 GB/s
PASS every object written and its source bytes match the manifest digest
read 4,490,047,488 bytes in 5.73 s = 0.78 GB/s
249 headers parsed and matched, 251 payload digests matched
extents 6974 of 6974 digested
PASS the image on the card is the image the manifest describes (251 of 251)
image record written at 0x1ffb03e00: 7f9e57e300d7beb3c1967bd56e87f3a3
```

## Inference: correct, and deterministic

Prompt `"What is a DC-DC converter?"`, `--max-new 64`, chat template with
thinking off, 20 prompt ids.

The card produced coherent, on-topic text:

> A **DC-DC converter** is an electronic circuit designed to convert a direct
> current (DC) voltage from one level to another. It is a fundamental building
> block in modern power electronics, used to regulate voltage levels efficiently
> within electronic systems.

**Three consecutive runs were bit-identical in their control trace** --
`prefill 20 ids, pos 20, first argmax 32, exp 15`, `decode 64 ids, pos 83` -- so
the design is deterministic across a reload-free sequence.

## Throughput, WITH the conditions recorded, which is the point

| run | GOs | run_chunk (s) | wall (s) |
|---|---|---|---|
| 1 | 83 | 24.579 | 24.805 |
| 2 | 83 | 24.578 | 24.704 |
| 3 | 83 | 24.579 | 24.703 |

DERIVED, run 1 basis and stated explicitly because the basis changes the number:

```
64 new tokens / 24.579 s run_chunk = 2.604 tok/s
64 new tokens / 24.805 s wall      = 2.580 tok/s
83 GOs        / 24.805 s wall      = 3.346 tok/s
per GO                             = 296.1 ms
positions covered: prompt 0..19, decode 20..83
```

**THE MEASUREMENT NOISE FLOOR ON SILICON IS ~0.004%.** `run_chunk` spread across
three runs is **0.001 s in 24.579** (24.579 / 24.578 / 24.579). That is a new and
useful fact: a fixed-schedule accelerator polled to completion has essentially no
run-to-run variance, so **a silicon A/B can resolve a sub-0.1% throughput delta**,
in sharp contrast to the OOC WNS floor of 0.4-0.745 ns that makes small timing
deltas uninterpretable (see ATTNDRAW, `docs/../CLAUDE.md`). Repeats cost 25
seconds each; there is no excuse for an unrepeated silicon number.

## NO COMPARISON WITH BUILD 9 IS CLAIMED, AND HERE IS WHY

Build 9's **2.46 tok/s was measured at a position nobody recorded** --
`docs/LEVERBOARD.md` open item 18 states this outright. Token cost grows with
position (`token_cycles(p) = 30,115,217 + 2,793.4 p`), so a tok/s figure without
its position range is not comparable to another one. **2.604 against 2.46 is
therefore NOT a 5.9% improvement and must not be quoted as one.**

What CAN be said: build 12b carries build 9's lever state (every lever off), so it
is EXPECTED to be performance-equivalent, and 2.604 tok/s at decode positions
20..83 is consistent with that expectation. Nothing here is evidence that build
12b is faster or slower than build 9.

**This run closes open item 18 going forward** by recording the conditions:
prompt 20 ids, decode positions 20..83, 83 GOs, `--max-new 64`, argmax fast path,
striped-seg27 image. A future build measured the same way IS comparable to this
one, to ~0.004%.

## What this establishes

- Build 12b is a **working bitstream on silicon**, not merely a closed build.
- The reverted codebook and both stated generator defaults produce a card that
  loads, verifies, and generates correct text.
- There is now a silicon CONTROL with recorded conditions and a measured noise
  floor, which build 9 never had.

## Not measured

- Logit-level correctness against a reference. The output is coherent and
  deterministic; it has not been compared token-for-token against
  `tools/ref9b/check_token.py` or a CPU reference in this session.
- Any longer context. All three runs stop at position 83.
- Power, or thermals beyond the 42.2 C at load time.
