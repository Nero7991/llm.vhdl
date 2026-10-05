# Jungle Cat JTAG-to-HBM Weight Loader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load a 27B weight image (~7.1 GB per die) into a Jungle Cat VU35P die's HBM over the BMC's JTAG path in about 46 minutes, every frame CRC-checked, verified by an independent path.

**Architecture:** The host frames the manifest's pieces into 16,384-bit slots and streams them with the direct pipelined CoE client into a `BSCANE2` USER4 register. A TCK-domain receiver checks each slot's magic and CRC and pushes words through `async_fifo` to a 200 MHz AXI3 writer that commits only CRC-clean, in-sequence frames to HBM. Status returns on TDO in later slots. A range-CRC unit reads HBM back for verification.

**Tech Stack:** VHDL-2008 (GHDL 6 mcode for benches, Vivado 2023.2 for synthesis), Python 3 + pytest, `tools/jc/` host code, `sim/regress.sh` gate.

**Spec:** `docs/superpowers/specs/2026-10-05-jc-jtag-hbm-loader-design.md`

## Global Constraints

- No emojis. No em-dashes in code, docs or comments. Never add a Co-Authored-By line to a commit. Never `git add -A` or `git add .`; stage explicit paths.
- **Subagents get NO hardware access**: no `sqrl_bridge`, no CoE client against the real BMC, no XVC, no `hw_server`, no `vivado ... program`. Tasks 10 and 11's silicon steps are main-session only.
- Frame slot: 16,384 bits = 1 header word + 62 payload words + 32-bit CRC + 224 pad bits (spec 4.1). Words are 256 bits. All fields little-endian, LSB first on the wire.
- Header word bits: magic `[31:0]` = `0x4A4C4431`, seq `[63:32]`, hbm_addr `[103:64]` (32-byte aligned), nwords `[119:104]` (0 to 62), flags `[135:120]` (bit 0 = range CRC), range_len `[175:136]`, zero `[255:176]`.
- Status word magic `0x4A4C5354` (spec 4.4). CRC-32 is IEEE reflected (zlib): init `0xFFFFFFFF`, poly `0xEDB88320`, final XOR `0xFFFFFFFF`.
- HBM is AXI3: AWLEN/ARLEN at most 15 (16 beats), AxSIZE `101` (32 bytes), INCR bursts, no burst crosses a 4 KB boundary, all write strobes set.
- IR allowlist on the host: only BYPASS `111111111111`, IDCODE `001001001001`, USER3 `100010100100`, USER4 `100011100100` may be shifted (BSDL `xcvu35p_fsvh2104.bsd`).
- Benches: GHDL mcode, `--std=08 -frelaxed`; count checks in variables; print a `PASS: <tb>` line only after asserting the check count; every new `sim/tb_*.vhd` is a gate row the moment it exists, so its vector file must be committed with it.
- Nothing expensive under `/tmp`. Vivado runs follow CLAUDE.md's memory rules (one per box, BC-250 at `MemoryHigh=11G`).

## Plan-time rulings against the spec

Recorded here because each changes a spec detail; Task 0 appends them to the spec.

1. **Units live in `rtl/`, not `hw/jc/loader/rtl/`.** `sim/regress.sh` builds each bench's closure from `rtl/`, `sim/` and `sim/micro/` only, so GHDL-tested units must be there. Only the `BSCANE2` wrapper and the top (`hw/jc/loader/rtl/`) stay out, because GHDL cannot simulate the primitive. The receiver therefore splits into `rtl/jc_frame_core.vhd` (pure VHDL, BSCAN signals as ports) and `hw/jc/loader/rtl/jc_frame_rx.vhd` (wrapper).
2. **A slot whose magic is wrong is dropped and counted (`desync`); it does not latch until the next Capture.** The host detects a rising desync count and resyncs (spec 4.1's procedure). This also makes chain alignment uniform: the host always opens a scan with one filler of `16384 - lead` zero bits, which the loader drops as one desync, so frames start on a slot boundary whichever die is nearer TDI.
3. **The frame CRC covers all 63 words as transmitted** (header plus 62 payload words, zero-padded), i.e. bytes `[0, 2016)` of the slot. Same bytes as spec 4.1 for a full frame; for a short frame it also covers the zero padding, which costs nothing and keeps the hardware counter fixed.
4. **`nwords = 0` with `flags = 0` is a status poll**: no write, no sequence check. The host uses it to read status and to flush the CDC.
5. **FIFO words are 258 bits**: tag `[257:256]` (`00` data, `01` header, `10` verdict pass, `11` verdict fail) and the 256-bit word; a verdict word carries the frame's seq in `[31:0]`.
6. **A frame whose word count disagrees with its header is a CRC failure** (it can only happen if the FIFO overflowed, which sets status bit 179).
7. **The image fingerprint record (`fk33_imgfp.py`) is out of scope**: it serves the FK33 runtime; the Jungle Cat block design will decide its own.

## Status word layout (256 bits, the contract between Tasks 3, 6, 8 and 9)

| Bits | Field | Domain |
|---|---|---|
| 31:0 | magic `0x4A4C5354` | core |
| 63:32 | last committed seq (`0xFFFFFFFF` = none) | writer |
| 95:64 | frames committed | writer |
| 111:96 | CRC failures | writer |
| 127:112 | sequence errors (gaps) | writer |
| 143:128 | desync count | core |
| 159:144 | BRESP errors | writer |
| 175:160 | duplicates dropped | writer |
| 176 | busy (writer or CRC unit not idle) | aclk |
| 177 | HBM catastrophic temperature trip | aclk |
| 178 | range CRC result valid | crc unit |
| 179 | FIFO overflow seen | core |
| 180 | range CRC read error (RRESP not OKAY) | crc unit |
| 191:181 | zero | |
| 223:192 | range CRC result | crc unit |
| 255:224 | range CRC seq | crc unit |

## Review Focus

1. **Frames in flight after a failure**: with 4 commands in flight, the frames after a bad one arrive as sequence gaps. The host must treat the burst of `seq_err` as one event, resync once, and resume from `last + 1`, not abort. Pinned by `test_resync_after_crc_failure_with_pipeline` in Task 9.
2. **Status lag**: status reflects the writer a slot or more late. The host must not declare a load complete until a poll shows `last == final seq` and `busy == 0`. Pinned by `test_completion_waits_for_status` in Task 9.
3. **Wrong chain position**: if `--chain` is wrong, every slot desyncs. The host must stop within a few slots with a message naming the chain, not spin or resend forever. Pinned by `test_wrong_chain_position_aborts_fast` in Task 9.
4. **Resume after an interrupted load**: a new host process must continue from the FPGA's `last + 1`, and must refuse when the checkpoint names a different plan. Pinned by `test_resume_continues_from_fpga_status` and `test_resume_refuses_other_plan` in Task 9.
5. **A piece whose length is not a multiple of 32**: the last word is zero-padded and the range CRC must cover the padded length, and the pad must never reach the next object. Pinned by `test_odd_length_piece_pads_inside_its_own_4k` in Task 8.

---

## File map

| Path | Responsibility | Task |
|---|---|---|
| `rtl/jc_loader_pkg.vhd` | constants, field positions, CRC-32 functions | 1 |
| `sim/tb_jc_crc32.vhd`, `sim/jc_crc32_vec.txt` | CRC function bench | 1 |
| `tools/jc/jc_frame.py` | frame/slot/status encoding, the one Python definition of the format | 2 |
| `tools/jc/jc_model.py` | independent Python model of the loader (oracle for benches and host tests) | 2 |
| `tools/jc/gen_jc_vectors.py` | writes every `sim/jc_*_vec.txt` | 2, 3, 4, 5, 6 |
| `tools/jc/test_jc_frame.py` | pytest for the format and model | 2 |
| `rtl/jc_frame_core.vhd`, `sim/tb_jc_frame_core.vhd`, `sim/jc_frame_vec.txt` | TCK receiver | 3 |
| `sim/jc_axi3_mem.vhd` | AXI3 slave memory model with protocol checks (bench-only) | 4 |
| `rtl/jc_hbm_writer.vhd`, `sim/tb_jc_hbm_writer.vhd`, `sim/jc_writer_vec.txt` | AXI3 writer | 4 |
| `rtl/jc_hbm_crc.vhd`, `sim/tb_jc_hbm_crc.vhd`, `sim/jc_crcunit_vec.txt` | range CRC unit | 5 |
| `rtl/jc_status_sync.vhd`, `rtl/jc_loader_core.vhd`, `sim/tb_jc_loader_core.vhd`, `sim/jc_loader_vec.txt` | CDC and composition | 6 |
| `sim/mutate_jc_loader.sh` | mutation teeth with attribution controls | 7 |
| `tools/jc/coe.py`, `tools/jc/test_coe.py` | CoE client library, TAP helpers, IR allowlist | 8 |
| `hw/jc/xvcstream/coe_stream.py` | refactored to import `tools/jc/coe.py` | 8 |
| `tools/jc/coe_load.py`, `tools/jc/test_coe_load.py` | manifest planning, pipelined load, resync, resume, verify | 8, 9 |
| `hw/jc/loader/rtl/jc_frame_rx.vhd`, `hw/jc/loader/rtl/jc_loader_top.vhd`, `hw/jc/loader/jc_loader_bd.tcl`, `hw/jc/loader/jc_loader.xdc`, `hw/jc/loader/build_loader.tcl`, `hw/jc/loader/ooc_loader_core.tcl` | synthesis, OOC route, bitstream | 10 |
| `docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md` (new section) | silicon results | 11 |

---

### Task 0: Record the plan-time rulings in the spec

**Files:**
- Modify: `docs/superpowers/specs/2026-10-05-jc-jtag-hbm-loader-design.md` (append)

- [ ] **Step 1: Append the amendments**

Append this section verbatim to the end of the spec:

```markdown
## 10. Plan-time amendments (2026-10-05)

From `docs/superpowers/plans/2026-10-05-jc-jtag-hbm-loader.md`, "Plan-time rulings":
1. GHDL-tested units live in `rtl/` (the regress closure covers only `rtl/`, `sim/`,
   `sim/micro/`); `jc_frame_core` is the pure-VHDL receiver, `jc_frame_rx` the
   `BSCANE2` wrapper in `hw/jc/loader/rtl/`.
2. A bad-magic slot is dropped and counted, not latched; the host opens every scan with
   a `16384 - lead` bit filler so frames align for either chain position.
3. The frame CRC covers bytes `[0, 2016)` of the slot (all 63 words, zero-padded).
4. `nwords = 0, flags = 0` is a status poll.
5. FIFO words are 258 bits (2-bit tag + word).
6. A word-count mismatch is a CRC failure.
7. The FK33 image fingerprint record is out of scope.
The status word layout is fixed by the plan's "Status word layout" table.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-10-05-jc-jtag-hbm-loader-design.md docs/superpowers/plans/2026-10-05-jc-jtag-hbm-loader.md
git commit -m "jc loader: implementation plan and plan-time spec amendments"
```

---

### Task 1: Loader package and CRC-32 functions

**Files:**
- Create: `rtl/jc_loader_pkg.vhd`
- Create: `tools/jc/__init__.py` (empty), `tools/jc/gen_jc_vectors.py` (CRC section only for now)
- Create: `sim/tb_jc_crc32.vhd`, `sim/jc_crc32_vec.txt`

**Interfaces:**
- Produces (VHDL, `work.jc_loader_pkg`): constants `JC_SLOT_BITS=16384`, `JC_WORD_BITS=256`, `JC_MAX_PAYLOAD=62`, `JC_CRC_FIRST=16128`, `JC_CRC_LAST=16159`, `JC_FIFO_W=258`, `JC_MAGIC_FRAME`, `JC_MAGIC_STAT`, `TAG_DATA/TAG_HDR/TAG_PASS/TAG_FAIL`; functions `crc32_bit(crc, b) return std_logic_vector(31 downto 0)`, `crc32_word(crc, w32) return std_logic_vector(31 downto 0)`.
- Produces (Python): `gen_jc_vectors.py --only crc32` writes `sim/jc_crc32_vec.txt`.

- [ ] **Step 1: Write the vector generator (CRC section)**

`tools/jc/gen_jc_vectors.py`:

```python
#!/usr/bin/env python3
"""Write the Jungle Cat loader bench vectors (sim/jc_*_vec.txt).

Every expected value comes from zlib and tools/jc/jc_model.py, never from the RTL.
Usage: gen_jc_vectors.py [--only crc32|frame|writer|crcunit|loader]
"""
import argparse, os, random, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))

def sim(name):
    return os.path.join(REPO, "sim", name)

def gen_crc32(rng):
    lines = []
    for n in (1, 2, 8, 63, 504):
        words = [rng.getrandbits(32) for _ in range(n)]
        data = b"".join(struct.pack("<I", w) for w in words)
        crc = zlib.crc32(data) & 0xFFFFFFFF
        lines.append("%d %s %08x" % (n, " ".join("%08x" % w for w in words), crc))
    # zlib's published check value: CRC-32("123456789") = 0xcbf43926, 9 bytes padded is
    # not word-aligned, so use the 8-byte prefix "12345678" instead.
    data = b"12345678"
    w = struct.unpack("<2I", data)
    lines.append("2 %08x %08x %08x" % (w[0], w[1], zlib.crc32(data) & 0xFFFFFFFF))
    with open(sim("jc_crc32_vec.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")

GENS = {"crc32": gen_crc32}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=sorted(GENS))
    a = ap.parse_args()
    for name, fn in GENS.items():
        if a.only and name != a.only:
            continue
        fn(random.Random(20261005))
        print("wrote", name)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Generate the vectors**

Run: `python3 tools/jc/gen_jc_vectors.py --only crc32 && wc -l sim/jc_crc32_vec.txt`
Expected: `wrote crc32`, then `6 sim/jc_crc32_vec.txt`.

- [ ] **Step 3: Write the failing bench**

`sim/tb_jc_crc32.vhd`:

```vhdl
-- Bench for jc_loader_pkg.crc32_word against zlib vectors (tools/jc/gen_jc_vectors.py).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_crc32 is
end entity;

architecture sim of tb_jc_crc32 is
begin
  process
    file vf     : text open read_mode is "jc_crc32_vec.txt";
    variable l  : line;
    variable n  : integer;
    variable w  : std_logic_vector(31 downto 0);
    variable c  : std_logic_vector(31 downto 0);
    variable ex : std_logic_vector(31 downto 0);
    variable checks, errors : natural := 0;
  begin
    while not endfile(vf) loop
      readline(vf, l);
      read(l, n);
      c := (others => '1');
      for i in 1 to n loop
        hread(l, w);
        c := crc32_word(c, w);
      end loop;
      hread(l, ex);
      checks := checks + 1;
      if (c xor x"FFFFFFFF") /= ex then
        errors := errors + 1;
        report "crc mismatch on a " & integer'image(n) & "-word vector" severity error;
      end if;
    end loop;
    assert checks = 6 report "expected 6 vectors, read " & integer'image(checks) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_crc32 checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_crc32 errors=" & integer'image(errors) severity failure;
    end if;
    wait;
  end process;
end architecture;
```

Vector files are opened by BARE name: `sim/regress.sh` symlinks every `sim/*.txt` into each row's run directory before `ghdl -r` (see its staging loop over `"$SIM"/*.txt`), so a bench never needs a path prefix.

- [ ] **Step 4: Run it to see it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t1a bash sim/regress.sh --only tb_jc_crc32 --keep 2>&1 | tail -5`
Expected: the row fails to analyze with `jc_loader_pkg` not found (the package does not exist yet). `OVERALL` shows 0 PASS.

- [ ] **Step 5: Write the package**

`rtl/jc_loader_pkg.vhd`:

```vhdl
-- Jungle Cat JTAG-to-HBM loader: shared constants and CRC-32.
-- Spec: docs/superpowers/specs/2026-10-05-jc-jtag-hbm-loader-design.md (S4, S10).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package jc_loader_pkg is
  constant JC_SLOT_BITS   : natural := 16384;
  constant JC_WORD_BITS   : natural := 256;
  constant JC_MAX_PAYLOAD : natural := 62;
  constant JC_CRC_FIRST   : natural := 63 * 256;           -- 16128
  constant JC_CRC_LAST    : natural := JC_CRC_FIRST + 31;  -- 16159
  constant JC_FIFO_W      : natural := 258;
  constant JC_MAGIC_FRAME : std_logic_vector(31 downto 0) := x"4A4C4431";
  constant JC_MAGIC_STAT  : std_logic_vector(31 downto 0) := x"4A4C5354";
  constant TAG_DATA : std_logic_vector(1 downto 0) := "00";
  constant TAG_HDR  : std_logic_vector(1 downto 0) := "01";
  constant TAG_PASS : std_logic_vector(1 downto 0) := "10";
  constant TAG_FAIL : std_logic_vector(1 downto 0) := "11";

  -- Reflected CRC-32 (IEEE, zlib), one bit, LSB first.
  function crc32_bit(crc : std_logic_vector(31 downto 0); b : std_logic)
    return std_logic_vector;
  -- 32 bits, bit 0 first (= four bytes in little-endian address order).
  function crc32_word(crc : std_logic_vector(31 downto 0);
                      w   : std_logic_vector(31 downto 0))
    return std_logic_vector;
end package;

package body jc_loader_pkg is
  function crc32_bit(crc : std_logic_vector(31 downto 0); b : std_logic)
    return std_logic_vector is
    variable c : std_logic_vector(31 downto 0);
  begin
    c := '0' & crc(31 downto 1);
    if (crc(0) xor b) = '1' then
      c := c xor x"EDB88320";
    end if;
    return c;
  end function;

  function crc32_word(crc : std_logic_vector(31 downto 0);
                      w   : std_logic_vector(31 downto 0))
    return std_logic_vector is
    variable c : std_logic_vector(31 downto 0) := crc;
  begin
    for i in 0 to 31 loop
      c := crc32_bit(c, w(i));
    end loop;
    return c;
  end function;
end package body;
```

- [ ] **Step 6: Run the bench to see it pass**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t1b bash sim/regress.sh --only tb_jc_crc32 --keep 2>&1 | tail -5`
Expected: `PASS sim:tb_jc_crc32`, `OVERALL PASS 1 FAIL 0`.

- [ ] **Step 7: Prove the bench can fail**

Temporarily change `x"EDB88320"` to `x"EDB88321"` in a scratch copy (not the repo): `mkdir -p /mnt/storage/fk33_builds/scratch/jcl_t1c && sed 's/EDB88320/EDB88321/' rtl/jc_loader_pkg.vhd > /mnt/storage/fk33_builds/scratch/jcl_t1c/jc_loader_pkg.vhd`, then analyze that copy plus the bench with `ghdl -a --std=08 -frelaxed --workdir=/mnt/storage/fk33_builds/scratch/jcl_t1c` and run `ghdl -r --std=08 -frelaxed --workdir=/mnt/storage/fk33_builds/scratch/jcl_t1c tb_jc_crc32` from inside `/mnt/storage/fk33_builds/scratch/jcl_t1c` after copying `sim/jc_crc32_vec.txt` there (the bench opens it by bare name).
Expected: `FAIL: tb_jc_crc32 errors=6` (or 5: the "12345678" vector may survive a one-bit polynomial change only by coincidence; any nonzero count is a kill).

- [ ] **Step 8: Commit**

```bash
git add rtl/jc_loader_pkg.vhd sim/tb_jc_crc32.vhd sim/jc_crc32_vec.txt tools/jc/__init__.py tools/jc/gen_jc_vectors.py
git commit -m "jc loader: package, CRC-32 functions, zlib-vector bench"
```

---

### Task 2: Frame format library and the independent loader model

**Files:**
- Create: `tools/jc/jc_frame.py`, `tools/jc/jc_model.py`, `tools/jc/test_jc_frame.py`

**Interfaces:**
- Produces (`tools/jc/jc_frame.py`): `SLOT_BITS=16384`, `SLOT_BYTES=2048`, `WORD_BYTES=32`, `MAX_PAYLOAD_WORDS=62`, `MAX_PAYLOAD_BYTES=1984`, `CRC_OFFSET=2016`, `MAGIC_FRAME`, `MAGIC_STAT`, `FLAG_RANGE_CRC=1`; `header(seq, hbm_addr, nwords, flags=0, range_len=0) -> bytes(32)`; `build_slot(seq, hbm_addr, payload=b"", flags=0, range_len=0) -> bytes(2048)`; `poll_slot() -> bytes`; `range_crc_slot(seq, hbm_addr, range_len) -> bytes`; `parse_header(slot) -> dict`; `slot_crc_ok(slot) -> bool`; `parse_status(b32: bytes) -> dict` with keys `magic,last,committed,crc_fail,seq_err,desync,bresp_err,dup,busy,hbm_trip,range_valid,fifo_ovf,range_rerr,range_crc,range_seq`; `pack_status(d) -> bytes(32)`; `bursts(addr, nbeats) -> list[(addr, nbeats)]` (AXI3 16-beat / 4 KB split); `slot_hex(slot) -> str` (4096 hex digits, MSB first).
- Produces (`tools/jc/jc_model.py`): `class LoaderModel` with `feed(slot: bytes)`, attributes `mem: dict[int, bytes]` (32-byte word per aligned address), counters matching `parse_status` keys, `bad_bresp_addrs: set[int]`, `status() -> dict`.

- [ ] **Step 1: Write the failing tests**

`tools/jc/test_jc_frame.py`:

```python
import os, struct, sys, zlib
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import jc_frame as F
from jc.jc_model import LoaderModel

def test_slot_layout_and_crc():
    s = F.build_slot(7, 0x1000, b"\x11" * 64)
    assert len(s) == F.SLOT_BYTES
    h = F.parse_header(s)
    assert (h["magic"], h["seq"], h["addr"], h["nwords"]) == (F.MAGIC_FRAME, 7, 0x1000, 2)
    assert struct.unpack_from("<I", s, F.CRC_OFFSET)[0] == zlib.crc32(s[:F.CRC_OFFSET]) & 0xFFFFFFFF
    assert s[F.CRC_OFFSET + 4:] == bytes(F.SLOT_BYTES - F.CRC_OFFSET - 4)
    assert F.slot_crc_ok(s)

def test_flipped_bit_fails_crc():
    s = bytearray(F.build_slot(1, 0, b"\xAB" * 1984))
    s[100] ^= 0x04
    assert not F.slot_crc_ok(bytes(s))

def test_header_rejects_bad_input():
    with pytest.raises(ValueError):
        F.header(0, 0x10, 1)            # not 32-byte aligned
    with pytest.raises(ValueError):
        F.build_slot(0, 0, b"\0" * 1985)  # over 62 words

def test_status_round_trip():
    d = dict(magic=F.MAGIC_STAT, last=5, committed=6, crc_fail=1, seq_err=2, desync=3,
             bresp_err=4, dup=5, busy=1, hbm_trip=0, range_valid=1, fifo_ovf=0,
             range_rerr=0, range_crc=0xDEADBEEF, range_seq=9)
    assert F.parse_status(F.pack_status(d)) == d

def test_bursts_respect_16_beats_and_4k():
    assert F.bursts(0x0, 62) == [(0x0, 16), (0x200, 16), (0x400, 16), (0x600, 14)]
    assert F.bursts(0xFE0, 3) == [(0xFE0, 1), (0x1000, 2)]

def test_model_commits_in_order_and_counts():
    m = LoaderModel()
    m.feed(bytes(F.SLOT_BYTES))                       # filler: desync
    m.feed(F.build_slot(0, 0x40, b"\x01" * 32))
    m.feed(F.build_slot(0, 0x40, b"\x02" * 32))       # duplicate
    m.feed(F.build_slot(2, 0x80, b"\x03" * 32))       # gap
    bad = bytearray(F.build_slot(1, 0x60, b"\x04" * 32)); bad[40] ^= 1
    m.feed(bytes(bad))                                # crc fail
    m.feed(F.build_slot(1, 0x60, b"\x05" * 32))
    m.feed(F.poll_slot())
    st = m.status()
    assert (st["desync"], st["dup"], st["seq_err"], st["crc_fail"]) == (1, 1, 1, 1)
    assert (st["last"], st["committed"]) == (1, 2)
    assert m.mem[0x40] == b"\x01" * 32 and m.mem[0x60] == b"\x05" * 32 and 0x80 not in m.mem

def test_model_range_crc():
    m = LoaderModel()
    m.feed(F.build_slot(0, 0x100, bytes(range(64))))
    m.feed(F.range_crc_slot(1, 0x100, 64))
    st = m.status()
    assert st["range_valid"] == 1 and st["range_seq"] == 1
    assert st["range_crc"] == zlib.crc32(bytes(range(64))) & 0xFFFFFFFF

def test_model_counts_bresp_per_burst():
    m = LoaderModel(bad_bresp_addrs={0x200})
    m.feed(F.build_slot(0, 0x0, b"\x07" * 1984))       # bursts at 0x0, 0x200, 0x400, 0x600
    assert m.status()["bresp_err"] == 1
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd tools && python3 -m pytest jc/test_jc_frame.py -q 2>&1 | tail -3`
Expected: collection error, `No module named 'jc.jc_frame'`.

- [ ] **Step 3: Implement `tools/jc/jc_frame.py`**

```python
"""Jungle Cat loader frame and status format: the one Python definition.

Spec: docs/superpowers/specs/2026-10-05-jc-jtag-hbm-loader-design.md S4 and S10.
"""
import struct, zlib

SLOT_BITS = 16384
SLOT_BYTES = SLOT_BITS // 8
WORD_BYTES = 32
MAX_PAYLOAD_WORDS = 62
MAX_PAYLOAD_BYTES = MAX_PAYLOAD_WORDS * WORD_BYTES
CRC_OFFSET = 63 * WORD_BYTES
MAGIC_FRAME = 0x4A4C4431
MAGIC_STAT = 0x4A4C5354
FLAG_RANGE_CRC = 1
M40 = (1 << 40) - 1

def header(seq, hbm_addr, nwords, flags=0, range_len=0):
    if hbm_addr % WORD_BYTES or not 0 <= hbm_addr <= M40:
        raise ValueError("hbm_addr must be 32-byte aligned and fit 40 bits: %#x" % hbm_addr)
    if not 0 <= nwords <= MAX_PAYLOAD_WORDS:
        raise ValueError("nwords out of range: %d" % nwords)
    if range_len % WORD_BYTES or not 0 <= range_len <= M40:
        raise ValueError("range_len must be a multiple of 32: %d" % range_len)
    v = (MAGIC_FRAME | (seq & 0xFFFFFFFF) << 32 | hbm_addr << 64 | nwords << 104
         | (flags & 0xFFFF) << 120 | range_len << 136)
    return v.to_bytes(32, "little")

def build_slot(seq, hbm_addr, payload=b"", flags=0, range_len=0):
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ValueError("payload over %d bytes" % MAX_PAYLOAD_BYTES)
    nwords = (len(payload) + WORD_BYTES - 1) // WORD_BYTES
    body = header(seq, hbm_addr, nwords, flags, range_len) + payload.ljust(MAX_PAYLOAD_BYTES, b"\0")
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return body + struct.pack("<I", crc) + bytes(SLOT_BYTES - CRC_OFFSET - 4)

def poll_slot():
    return build_slot(0, 0, b"")

def range_crc_slot(seq, hbm_addr, range_len):
    return build_slot(seq, hbm_addr, b"", FLAG_RANGE_CRC, range_len)

def parse_header(slot):
    v = int.from_bytes(slot[:32], "little")
    return dict(magic=v & 0xFFFFFFFF, seq=(v >> 32) & 0xFFFFFFFF, addr=(v >> 64) & M40,
                nwords=(v >> 104) & 0xFFFF, flags=(v >> 120) & 0xFFFF,
                range_len=(v >> 136) & M40)

def slot_crc_ok(slot):
    return struct.unpack_from("<I", slot, CRC_OFFSET)[0] == zlib.crc32(slot[:CRC_OFFSET]) & 0xFFFFFFFF

# (name, lsb, width) -- the plan's "Status word layout" table
STATUS_FIELDS = [("magic", 0, 32), ("last", 32, 32), ("committed", 64, 32),
                 ("crc_fail", 96, 16), ("seq_err", 112, 16), ("desync", 128, 16),
                 ("bresp_err", 144, 16), ("dup", 160, 16), ("busy", 176, 1),
                 ("hbm_trip", 177, 1), ("range_valid", 178, 1), ("fifo_ovf", 179, 1),
                 ("range_rerr", 180, 1), ("range_crc", 192, 32), ("range_seq", 224, 32)]

def parse_status(b32):
    v = int.from_bytes(b32[:32], "little")
    return {n: (v >> lsb) & ((1 << w) - 1) for n, lsb, w in STATUS_FIELDS}

def pack_status(d):
    v = 0
    for n, lsb, w in STATUS_FIELDS:
        v |= (d[n] & ((1 << w) - 1)) << lsb
    return v.to_bytes(32, "little")

def bursts(addr, nbeats):
    """AXI3 split: at most 16 beats of 32 bytes, never across a 4 KB boundary."""
    out = []
    while nbeats:
        to4k = (4096 - addr % 4096) // WORD_BYTES
        n = min(16, nbeats, to4k)
        out.append((addr, n))
        addr += n * WORD_BYTES
        nbeats -= n
    return out

def slot_hex(slot):
    return "%04096x" % int.from_bytes(slot, "little")
```

- [ ] **Step 4: Implement `tools/jc/jc_model.py`**

```python
"""Independent Python model of the Jungle Cat loader (spec S4, plan rulings).

The oracle for every loader bench and for the host tests. It shares the format
definitions in jc_frame.py and nothing with the RTL.
"""
import zlib
from . import jc_frame as F

class LoaderModel:
    def __init__(self, bad_bresp_addrs=()):
        self.mem = {}
        self.bad_bresp_addrs = set(bad_bresp_addrs)
        self.last = 0xFFFFFFFF
        self.committed = self.crc_fail = self.seq_err = self.desync = 0
        self.bresp_err = self.dup = 0
        self.range_valid = self.range_crc = self.range_seq = 0

    def feed(self, slot):
        h = F.parse_header(slot)
        if h["magic"] != F.MAGIC_FRAME or h["nwords"] > F.MAX_PAYLOAD_WORDS:
            self.desync += 1
            return
        if not F.slot_crc_ok(slot):
            self.crc_fail += 1
            return
        if h["nwords"] == 0 and h["flags"] & F.FLAG_RANGE_CRC == 0:
            return                                            # status poll
        expect = (self.last + 1) & 0xFFFFFFFF
        diff = (h["seq"] - expect) & 0xFFFFFFFF
        if diff != 0:
            if diff >= 0x80000000:
                self.dup += 1
            else:
                self.seq_err += 1
            return
        if h["flags"] & F.FLAG_RANGE_CRC:
            data = b"".join(self.mem.get(a, bytes(32))
                            for a in range(h["addr"], h["addr"] + h["range_len"], 32))
            self.range_crc = zlib.crc32(data) & 0xFFFFFFFF
            self.range_seq = h["seq"]
            self.range_valid = 1
        else:
            for a, n in F.bursts(h["addr"], h["nwords"]):
                if a in self.bad_bresp_addrs:
                    self.bresp_err += 1
            for k in range(h["nwords"]):
                self.mem[h["addr"] + 32 * k] = slot[32 * (k + 1):32 * (k + 2)]
        self.last = h["seq"]
        self.committed += 1

    def status(self):
        return dict(magic=F.MAGIC_STAT, last=self.last, committed=self.committed,
                    crc_fail=self.crc_fail, seq_err=self.seq_err, desync=self.desync,
                    bresp_err=self.bresp_err, dup=self.dup, busy=0, hbm_trip=0,
                    range_valid=self.range_valid, fifo_ovf=0, range_rerr=0,
                    range_crc=self.range_crc, range_seq=self.range_seq)
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd tools && python3 -m pytest jc/test_jc_frame.py -q 2>&1 | tail -3`
Expected: `8 passed`.

- [ ] **Step 6: Commit**

```bash
git add tools/jc/jc_frame.py tools/jc/jc_model.py tools/jc/test_jc_frame.py
git commit -m "jc loader: frame/status format library and independent Python loader model"
```

---

### Task 3: TCK-domain receiver `jc_frame_core`

**Files:**
- Create: `rtl/jc_frame_core.vhd`, `sim/tb_jc_frame_core.vhd`
- Modify: `tools/jc/gen_jc_vectors.py` (add `gen_frame`), create `sim/jc_frame_vec.txt`

**Interfaces:**
- Consumes: `work.jc_loader_pkg` (Task 1); `jc_frame.build_slot/poll_slot/range_crc_slot/slot_hex` (Task 2).
- Produces: `entity jc_frame_core` ports `tck, sel, capture, shift, tdi : in std_logic; tdo : out std_logic; w_valid : out std_logic; w_data : out std_logic_vector(JC_FIFO_W-1 downto 0); w_ready : in std_logic; st_in : in std_logic_vector(255 downto 0); desync_cnt : out unsigned(15 downto 0); ovf_seen : out std_logic`. Contract: one push per word on the TCK edge after it completes; header pushed only if magic is right and nwords <= 62; data pushes 1..nwords; verdict pushed at slot bit 16159 with seq in `[31:0]`; status (st_in with magic, desync and ovf merged) loaded on Capture and at every slot boundary, shifted out LSB first on `tdo`.

- [ ] **Step 1: Add the frame vectors**

Add to `tools/jc/gen_jc_vectors.py` (and register `"frame": gen_frame` in `GENS`):

```python
def gen_frame(rng):
    from jc import jc_frame as F
    slots = []          # (slot, magic_ok, nwords, pass, seq)
    def add(s, ok=True):
        h = F.parse_header(s)
        good = ok and h["magic"] == F.MAGIC_FRAME and h["nwords"] <= F.MAX_PAYLOAD_WORDS
        slots.append((s, int(good), h["nwords"] if good else 0,
                      int(good and F.slot_crc_ok(s)), h["seq"] if good else 0))
    add(bytes(F.SLOT_BYTES), ok=False)                                # filler: desync
    add(F.build_slot(0, 0x0000, rng.randbytes(1984)))                 # full frame
    add(F.build_slot(1, 0x1000, rng.randbytes(32)))                   # one word
    add(F.build_slot(2, 0x2000, rng.randbytes(17 * 32 - 5)))          # short, padded
    add(F.poll_slot())                                                # poll: header only
    add(F.range_crc_slot(3, 0x0, 4096))                               # range request
    s = bytearray(F.build_slot(4, 0x3000, rng.randbytes(1984))); s[777] ^= 0x10
    add(bytes(s))                                                     # payload bit flip
    s = bytearray(F.build_slot(5, 0x4000, rng.randbytes(64))); s[F.CRC_OFFSET] ^= 1
    add(bytes(s))                                                     # CRC bit flip
    s = bytearray(F.build_slot(6, 0x5000, rng.randbytes(64))); s[0] ^= 0x80
    add(bytes(s), ok=False)                                           # wrong magic
    for k in range(8):                                                # back to back
        add(F.build_slot(7 + k, 0x6000 + 0x800 * k, rng.randbytes(rng.randrange(32, 1985))))
    with open(sim("jc_frame_vec.txt"), "w") as f:
        for s, ok, nw, ps, seq in slots:
            f.write("S %d %d %d %08x %s\n" % (ok, nw, ps, seq, F.slot_hex(s)))
```

Run: `python3 tools/jc/gen_jc_vectors.py --only frame && wc -l sim/jc_frame_vec.txt`
Expected: `wrote frame`, `17 sim/jc_frame_vec.txt`.

- [ ] **Step 2: Write the failing bench**

`sim/tb_jc_frame_core.vhd`:

```vhdl
-- Bench for rtl/jc_frame_core.vhd: shifts the slots of sim/jc_frame_vec.txt through
-- one continuous Shift-DR (one Capture at the start, as the host does) and checks every
-- push, every verdict, the desync count and the status on TDO.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_frame_core is
end entity;

architecture sim of tb_jc_frame_core is
  constant TCK_P : time := 37 ns;
  signal tck, sel, capture, shift, tdi, tdo : std_logic := '0';
  signal w_valid, ovf : std_logic;
  signal w_data  : std_logic_vector(JC_FIFO_W-1 downto 0);
  signal st_in   : std_logic_vector(255 downto 0) := (others => '0');
  signal desync  : unsigned(15 downto 0);
  signal done    : boolean := false;

  type push_t is record
    tag  : std_logic_vector(1 downto 0);
    word : std_logic_vector(255 downto 0);
  end record;
  type push_arr is array (0 to 127) of push_t;
  shared variable pushes : push_arr;     -- written by the monitor, read by the driver
  shared variable npush  : natural := 0;
begin
  dut : entity work.jc_frame_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, w_valid => w_valid, w_data => w_data, w_ready => '1',
             st_in => st_in, desync_cnt => desync, ovf_seen => ovf);

  tck <= not tck after TCK_P / 2 when not done else '0';

  -- a fixed, recognisable status pattern from the "aclk side"
  st_in <= x"CAFEF00D" & x"12345678" & x"00000000_00000000" & x"0000" & x"0000" &
           x"0000" & x"0000" & x"0000_0000" & x"00000000";

  monitor : process(tck)
  begin
    if rising_edge(tck) and w_valid = '1' then
      pushes(npush) := (tag => w_data(257 downto 256), word => w_data(255 downto 0));
      npush := npush + 1;
    end if;
  end process;

  driver : process
    file vf : text open read_mode is "jc_frame_vec.txt";
    variable l : line;
    variable c : character;
    variable ok, nw, ps : integer;
    variable seq : std_logic_vector(31 downto 0);
    variable slot : std_logic_vector(JC_SLOT_BITS-1 downto 0);
    variable tdo_bits : std_logic_vector(255 downto 0);
    variable exp_st : std_logic_vector(255 downto 0);
    variable checks, errors, nslot, exp_desync : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then
        errors := errors + 1;
        report "slot " & integer'image(nslot) & ": " & msg severity error;
      end if;
    end procedure;
  begin
    sel <= '1';
    wait until falling_edge(tck);
    capture <= '1';
    wait until falling_edge(tck);
    capture <= '0';
    shift <= '1';
    while not endfile(vf) loop
      readline(vf, l);
      read(l, c);                         -- 'S'
      read(l, ok); read(l, nw); read(l, ps);
      hread(l, seq);
      hread(l, slot);
      npush := 0;
      for i in 0 to JC_SLOT_BITS - 1 loop
        tdi <= slot(i);
        wait until rising_edge(tck);      -- the DUT samples tdi here
        if i < 256 then
          tdo_bits(i) := tdo;             -- tdo before the edge's update is bit i
        end if;
        wait until falling_edge(tck);
      end loop;
      -- every push for this slot has landed by now (the verdict is at bit 16159)
      if ok = 1 then
        exp_desync := exp_desync;
        chk(npush = nw + 2, "expected " & integer'image(nw + 2) & " pushes, got " & integer'image(npush));
        if npush = nw + 2 then
          chk(pushes(0).tag = TAG_HDR and pushes(0).word = slot(255 downto 0), "header push");
          for k in 1 to nw loop
            chk(pushes(k).tag = TAG_DATA and pushes(k).word = slot(256 * k + 255 downto 256 * k),
                "data word " & integer'image(k));
          end loop;
          if ps = 1 then
            chk(pushes(nw + 1).tag = TAG_PASS, "verdict should be PASS");
          else
            chk(pushes(nw + 1).tag = TAG_FAIL, "verdict should be FAIL");
          end if;
          chk(pushes(nw + 1).word(31 downto 0) = seq, "verdict seq");
        end if;
      else
        exp_desync := exp_desync + 1;
        chk(npush = 0, "a bad-magic slot must push nothing, pushed " & integer'image(npush));
      end if;
      chk(to_integer(desync) = exp_desync, "desync count " & integer'image(to_integer(desync)));
      -- TDO in this slot carried the status loaded at its start (desync before this slot)
      exp_st := st_in;
      exp_st(31 downto 0) := JC_MAGIC_STAT;
      exp_st(143 downto 128) := std_logic_vector(to_unsigned(exp_desync - (1 - ok), 16));
      exp_st(179) := '0';
      if nslot > 0 then
        chk(tdo_bits = exp_st, "status on TDO");
      end if;
      nslot := nslot + 1;
    end loop;
    shift <= '0';
    chk(ovf = '0', "no overflow with w_ready held high");
    assert nslot = 17 report "expected 17 slots, ran " & integer'image(nslot) severity failure;
    assert checks > 100 report "too few checks: " & integer'image(checks) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_frame_core checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_frame_core errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
```

Bench notes for the implementer: the status check skips slot 0 (it was loaded by Capture, before any desync). The expected desync on TDO for slot `n` is the count after slot `n-1`, which is `exp_desync` before this slot's own increment; the expression `exp_desync - (1 - ok)` gives exactly that. If GHDL rejects the `st_in` concatenation widths, build it as `(255 downto 224 => x"CAFEF00D", 223 downto 192 => x"12345678", others => '0')`.

- [ ] **Step 3: Run it to see it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t3a bash sim/regress.sh --only tb_jc_frame_core --keep 2>&1 | tail -4`
Expected: analysis error, `jc_frame_core` not found; `OVERALL PASS 0`.

- [ ] **Step 4: Implement `rtl/jc_frame_core.vhd`**

```vhdl
-- Jungle Cat loader: TCK-domain frame receiver (pure VHDL; the BSCANE2 wrapper is
-- hw/jc/loader/rtl/jc_frame_rx.vhd). Spec S4.1, S4.4 and S10; plan rulings 2, 3, 5.
--
-- One continuous Shift-DR carries back-to-back 16,384-bit slots. Capture resets the bit
-- counter. TCK runs only while bits shift, so everything a slot owes (the verdict push)
-- completes inside its own 224 pad bits.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

entity jc_frame_core is
  port(
    tck        : in  std_logic;
    sel        : in  std_logic;
    capture    : in  std_logic;
    shift      : in  std_logic;
    tdi        : in  std_logic;
    tdo        : out std_logic;
    w_valid    : out std_logic;
    w_data     : out std_logic_vector(JC_FIFO_W-1 downto 0);
    w_ready    : in  std_logic;
    st_in      : in  std_logic_vector(255 downto 0);
    desync_cnt : out unsigned(15 downto 0);
    ovf_seen   : out std_logic
  );
end entity;

architecture rtl of jc_frame_core is
  signal bitcnt : natural range 0 to JC_SLOT_BITS - 1 := 0;
  signal sr     : std_logic_vector(255 downto 0) := (others => '0');
  signal crc    : std_logic_vector(31 downto 0) := (others => '1');
  signal rx_crc : std_logic_vector(31 downto 0) := (others => '0');
  signal good   : std_logic := '0';
  signal nwords : unsigned(15 downto 0) := (others => '0');
  signal seq    : std_logic_vector(31 downto 0) := (others => '0');
  signal st_sr  : std_logic_vector(255 downto 0) := (others => '0');
  signal desync : unsigned(15 downto 0) := (others => '0');
  signal ovf    : std_logic := '0';
  signal wv     : std_logic := '0';
  signal wd     : std_logic_vector(JC_FIFO_W-1 downto 0) := (others => '0');

  function merged(st : std_logic_vector(255 downto 0); d : unsigned(15 downto 0);
                  o  : std_logic) return std_logic_vector is
    variable v : std_logic_vector(255 downto 0) := st;
  begin
    v(31 downto 0)    := JC_MAGIC_STAT;
    v(143 downto 128) := std_logic_vector(d);
    v(179)            := o;
    return v;
  end function;
begin
  tdo        <= st_sr(0);
  w_valid    <= wv;
  w_data     <= wd;
  desync_cnt <= desync;
  ovf_seen   <= ovf;

  process(tck)
    variable word   : std_logic_vector(255 downto 0);
    variable widx   : natural range 0 to 63;
    variable crc_rx : std_logic_vector(31 downto 0);
  begin
    if rising_edge(tck) then
      wv <= '0';
      if wv = '1' and w_ready = '0' then
        ovf <= '1';
      end if;
      if sel = '1' and capture = '1' then
        bitcnt <= 0;
        crc    <= (others => '1');
        good   <= '0';
        st_sr  <= merged(st_in, desync, ovf);
      elsif sel = '1' and shift = '1' then
        word  := tdi & sr(255 downto 1);
        sr    <= word;
        st_sr <= '0' & st_sr(255 downto 1);
        if bitcnt < JC_CRC_FIRST then
          crc <= crc32_bit(crc, tdi);
        elsif bitcnt <= JC_CRC_LAST then
          rx_crc <= tdi & rx_crc(31 downto 1);
        end if;
        if bitcnt < JC_CRC_FIRST and (bitcnt mod 256) = 255 then
          widx := bitcnt / 256;
          if widx = 0 then
            if word(31 downto 0) = JC_MAGIC_FRAME
               and unsigned(word(119 downto 104)) <= JC_MAX_PAYLOAD then
              good   <= '1';
              nwords <= unsigned(word(119 downto 104));
              seq    <= word(63 downto 32);
              wv     <= '1';
              wd     <= TAG_HDR & word;
            else
              good   <= '0';
              desync <= desync + 1;
            end if;
          elsif good = '1' and widx <= to_integer(nwords) then
            wv <= '1';
            wd <= TAG_DATA & word;
          end if;
        end if;
        if bitcnt = JC_CRC_LAST and good = '1' then
          crc_rx := tdi & rx_crc(31 downto 1);
          wv <= '1';
          if crc_rx = (crc xor x"FFFFFFFF") then
            wd <= TAG_PASS & std_logic_vector(resize(unsigned(seq), 256));
          else
            wd <= TAG_FAIL & std_logic_vector(resize(unsigned(seq), 256));
          end if;
        end if;
        if bitcnt = JC_SLOT_BITS - 1 then
          bitcnt <= 0;
          crc    <= (others => '1');
          good   <= '0';
          st_sr  <= merged(st_in, desync, ovf);
        else
          bitcnt <= bitcnt + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 5: Run the bench to see it pass**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t3b bash sim/regress.sh --only tb_jc_frame_core --keep 2>&1 | tail -4`
Expected: `PASS sim:tb_jc_frame_core`, `OVERALL PASS 1 FAIL 0`. Read the `checks=` value in the row log; it must be over 100.

- [ ] **Step 6: Commit**

```bash
git add rtl/jc_frame_core.vhd sim/tb_jc_frame_core.vhd sim/jc_frame_vec.txt tools/jc/gen_jc_vectors.py
git commit -m "jc loader: TCK-domain frame receiver with continuous-scan slot framing"
```

---

### Task 4: AXI3 slave model and `jc_hbm_writer`

**Files:**
- Create: `sim/jc_axi3_mem.vhd` (bench-only model, not a gate row)
- Create: `rtl/jc_hbm_writer.vhd`, `sim/tb_jc_hbm_writer.vhd`
- Modify: `tools/jc/gen_jc_vectors.py` (add `gen_writer`), create `sim/jc_writer_vec.txt`

**Interfaces:**
- Consumes: `work.jc_loader_pkg`; `LoaderModel`, `F.bursts`, `F.build_slot` (Task 2).
- Produces: `entity jc_axi3_mem` generics `ADDR_W : positive := 33; IDX_W : positive := 11; STALL : boolean := true; BAD_BRESP_ADDR : std_logic_vector(39 downto 0) := (others => '1')`, ports: AXI3 slave write and read channels named `awaddr, awlen, awsize, awburst, awvalid, awready, wdata, wstrb, wlast, wvalid, wready, bresp, bvalid, bready, araddr, arlen, arsize, arburst, arvalid, arready, rdata, rresp, rlast, rvalid, rready`, plus `clk`, `poke_en, poke_addr(39 downto 0), poke_data(255 downto 0)` (bench preload), `peek_addr(39 downto 0) : in`, `peek_data(255 downto 0) : out`, `peek_hit : out std_logic`, `errors : out natural`.
- Produces: `entity jc_hbm_writer` generic `ADDR_W : positive := 33`; ports `clk, rst, q_valid, q_data(JC_FIFO_W-1 downto 0), q_ready`, AXI3 write master (`awaddr(ADDR_W-1 downto 0), awlen(3 downto 0), awsize(2 downto 0), awburst(1 downto 0), awvalid, awready, wdata(255 downto 0), wstrb(31 downto 0), wlast, wvalid, wready, bresp(1 downto 0), bvalid, bready`), CRC request (`crc_req, crc_addr(ADDR_W-1 downto 0), crc_len : unsigned(39 downto 0), crc_seq(31 downto 0), crc_busy`), status (`last_seq(31 downto 0), committed : unsigned(31 downto 0), crc_fail, seq_err, dup_cnt, bresp_err : unsigned(15 downto 0), busy`).

- [ ] **Step 1: Write the AXI3 memory model**

`sim/jc_axi3_mem.vhd`:

```vhdl
-- AXI3 slave memory for the Jungle Cat loader benches. Holds 2**IDX_W 256-bit words,
-- indexed by address bits [IDX_W+4:5] with the full address stored as a tag, so a
-- bench that aliases two addresses is caught rather than silently passing.
-- Checks every burst against the HBM AXI3 rules and counts violations on `errors`.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jc_axi3_mem is
  generic(ADDR_W : positive := 33; IDX_W : positive := 11; STALL : boolean := true;
          BAD_BRESP_ADDR : std_logic_vector(39 downto 0) := (others => '1'));
  port(
    clk       : in  std_logic;
    awaddr    : in  std_logic_vector(ADDR_W-1 downto 0);
    awlen     : in  std_logic_vector(3 downto 0);
    awsize    : in  std_logic_vector(2 downto 0);
    awburst   : in  std_logic_vector(1 downto 0);
    awvalid   : in  std_logic;
    awready   : out std_logic;
    wdata     : in  std_logic_vector(255 downto 0);
    wstrb     : in  std_logic_vector(31 downto 0);
    wlast     : in  std_logic;
    wvalid    : in  std_logic;
    wready    : out std_logic;
    bresp     : out std_logic_vector(1 downto 0);
    bvalid    : out std_logic;
    bready    : in  std_logic;
    araddr    : in  std_logic_vector(ADDR_W-1 downto 0);
    arlen     : in  std_logic_vector(3 downto 0);
    arsize    : in  std_logic_vector(2 downto 0);
    arburst   : in  std_logic_vector(1 downto 0);
    arvalid   : in  std_logic;
    arready   : out std_logic;
    rdata     : out std_logic_vector(255 downto 0);
    rresp     : out std_logic_vector(1 downto 0);
    rlast     : out std_logic;
    rvalid    : out std_logic;
    rready    : in  std_logic;
    poke_en   : in  std_logic := '0';
    poke_addr : in  std_logic_vector(39 downto 0) := (others => '0');
    poke_data : in  std_logic_vector(255 downto 0) := (others => '0');
    peek_addr : in  std_logic_vector(39 downto 0) := (others => '0');
    peek_data : out std_logic_vector(255 downto 0);
    peek_hit  : out std_logic;
    errors    : out natural
  );
end entity;

architecture sim of jc_axi3_mem is
  constant N : natural := 2 ** IDX_W;
  type mem_t is array (0 to N-1) of std_logic_vector(255 downto 0);
  type tag_t is array (0 to N-1) of std_logic_vector(39 downto 0);
  signal mem  : mem_t := (others => (others => '0'));
  signal tags : tag_t := (others => (others => '1'));       -- all ones = empty
  signal lfsr : std_logic_vector(15 downto 0) := x"ACE1";
  signal nerr : natural := 0;

  function idx(a : std_logic_vector(39 downto 0)) return natural is
  begin
    return to_integer(unsigned(a(IDX_W + 4 downto 5)));
  end function;
  function burst_ok(a : std_logic_vector; len : std_logic_vector(3 downto 0);
                    sz : std_logic_vector(2 downto 0); bt : std_logic_vector(1 downto 0))
    return boolean is
    variable off : natural := to_integer(unsigned(a(11 downto 0)));
  begin
    return sz = "101" and bt = "01" and a(4 downto 0) = "00000"
           and off + (to_integer(unsigned(len)) + 1) * 32 <= 4096;
  end function;
begin
  errors <= nerr;
  peek_data <= mem(idx(peek_addr));
  peek_hit  <= '1' when tags(idx(peek_addr)) = peek_addr else '0';

  process(clk)
    variable wa, ra : std_logic_vector(39 downto 0);
    variable wleft, rleft : integer := -1;
    variable wcnt : natural;
    variable bad_b : boolean;
    variable aw_ok : boolean := false;
    variable stall : std_logic;
  begin
    if rising_edge(clk) then
      lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      stall := '0';
      if STALL then stall := lfsr(0) and lfsr(3); end if;

      if poke_en = '1' then
        mem(idx(poke_addr))  <= poke_data;
        tags(idx(poke_addr)) <= poke_addr;
      end if;

      -- write address
      awready <= '0';
      if awvalid = '1' and wleft < 0 and stall = '0' then
        awready <= '1';
        wa := std_logic_vector(resize(unsigned(awaddr), 40));
        if not burst_ok(wa, awlen, awsize, awburst) then nerr <= nerr + 1;
          report "AXI3 write burst breaks a rule at " & to_hstring(wa) severity error; end if;
        wleft := to_integer(unsigned(awlen)); wcnt := 0;
        bad_b := wa = BAD_BRESP_ADDR;
      end if;
      -- write data
      wready <= '0';
      if wleft >= 0 and wvalid = '1' and stall = '0' then
        wready <= '1';
      end if;
      if wleft >= 0 and wvalid = '1' and wready = '1' then
        if wstrb /= x"FFFFFFFF" then nerr <= nerr + 1;
          report "partial write strobe" severity error; end if;
        if (wleft = 0) /= (wlast = '1') then nerr <= nerr + 1;
          report "WLAST on the wrong beat" severity error; end if;
        if tags(idx(wa)) /= wa and tags(idx(wa)) /= x"FFFFFFFFFF" then nerr <= nerr + 1;
          report "bench address alias at " & to_hstring(wa) severity error; end if;
        mem(idx(wa)) <= wdata; tags(idx(wa)) <= wa;
        wa := std_logic_vector(unsigned(wa) + 32);
        if wleft = 0 then
          bvalid <= '1';
          if bad_b then bresp <= "10"; else bresp <= "00"; end if;
        end if;
        wleft := wleft - 1;
        wready <= '0';
      end if;
      if bvalid = '1' and bready = '1' then bvalid <= '0'; end if;

      -- read address and data
      arready <= '0';
      if arvalid = '1' and rleft < 0 and stall = '0' then
        arready <= '1';
        ra := std_logic_vector(resize(unsigned(araddr), 40));
        if not burst_ok(ra, arlen, arsize, arburst) then nerr <= nerr + 1;
          report "AXI3 read burst breaks a rule at " & to_hstring(ra) severity error; end if;
        rleft := to_integer(unsigned(arlen));
      end if;
      if rvalid = '1' and rready = '1' then
        rvalid <= '0';
        ra := std_logic_vector(unsigned(ra) + 32);
        rleft := rleft - 1;
      elsif rleft >= 0 and arready = '0' and (rvalid = '0') and stall = '0' then
        rvalid <= '1'; rdata <= mem(idx(ra)); rresp <= "00";
        if rleft = 0 then rlast <= '1'; else rlast <= '0'; end if;
      end if;
    end if;
  end process;
end architecture;
```

Implementer note: the model's handshakes are intentionally simple (one beat in flight, LFSR stalls). If GHDL reports a multiple-driver or uninitialised-output problem on `bvalid`, `bresp`, `rvalid`, `rdata`, `rresp` or `rlast`, give each an initial value of `'0'`/zeros in a signal declared in the architecture and drive the port from it.

- [ ] **Step 2: Add the writer vectors**

Add to `gen_jc_vectors.py` (register `"writer": gen_writer`):

```python
def gen_writer(rng):
    """Events fed straight into the writer's FIFO port, plus the model's final state."""
    from jc import jc_frame as F
    from jc.jc_model import LoaderModel
    bad = 0x0600                                # the third burst of the first full frame
    m = LoaderModel(bad_bresp_addrs={bad})
    ev, slots = [], []
    def frame(seq, addr, payload, corrupt=False):
        s = F.build_slot(seq, addr, payload)
        if corrupt:
            s = bytearray(s); s[50] ^= 1; s = bytes(s)
        slots.append(s)
    frame(0, 0x0000, rng.randbytes(1984))       # 4 bursts, one SLVERR at 0x600
    frame(1, 0x0FE0, rng.randbytes(96))         # crosses 4 KB: bursts of 1 then 2
    frame(1, 0x0FE0, rng.randbytes(96))         # duplicate
    frame(3, 0x2000, rng.randbytes(64))         # gap
    frame(2, 0x3000, rng.randbytes(64), corrupt=True)   # CRC fail
    frame(2, 0x3000, rng.randbytes(1000))       # short, padded last word
    slots.append(F.poll_slot())
    for s in slots:
        m.feed(s)
        h = F.parse_header(s)
        ev.append("H %064x" % int.from_bytes(s[:32], "little"))
        for k in range(h["nwords"]):
            ev.append("D %064x" % int.from_bytes(s[32 * (k + 1):32 * (k + 2)], "little"))
        ev.append("%s %08x" % ("P" if F.slot_crc_ok(s) else "F", h["seq"]))
    st = m.status()
    with open(sim("jc_writer_vec.txt"), "w") as f:
        f.write("B %010x\n" % bad)
        f.write("\n".join(ev) + "\n")
        for a in sorted(m.mem):
            f.write("M %010x %064x\n" % (a, int.from_bytes(m.mem[a], "little")))
        f.write("C %08x %08x %04x %04x %04x %04x\n" % (st["last"], st["committed"],
                st["crc_fail"], st["seq_err"], st["dup"], st["bresp_err"]))
```

Run: `python3 tools/jc/gen_jc_vectors.py --only writer && grep -c '^M ' sim/jc_writer_vec.txt && tail -1 sim/jc_writer_vec.txt`
Expected: `wrote writer`; `M` count = 62 + 3 + 32 = 97; the `C` line is `C 00000002 00000003 0001 0001 0001 0001`.

- [ ] **Step 3: Write the failing bench**

`sim/tb_jc_hbm_writer.vhd`:

```vhdl
-- Bench for rtl/jc_hbm_writer.vhd: feeds the FIFO-side events of sim/jc_writer_vec.txt,
-- serves AXI3 through sim/jc_axi3_mem.vhd (which checks every burst rule), then compares
-- memory and counters against the Python model's final state.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_hbm_writer is
end entity;

architecture sim of tb_jc_hbm_writer is
  constant CLK_P : time := 5 ns;
  signal clk, rst : std_logic := '0';
  signal done : boolean := false;
  signal q_valid, q_ready : std_logic := '0';
  signal q_data : std_logic_vector(JC_FIFO_W-1 downto 0) := (others => '0');
  signal awaddr : std_logic_vector(32 downto 0);
  signal awlen : std_logic_vector(3 downto 0);
  signal awsize : std_logic_vector(2 downto 0);
  signal awburst, bresp : std_logic_vector(1 downto 0);
  signal awvalid, awready, wlast, wvalid, wready, bvalid, bready : std_logic;
  signal wdata : std_logic_vector(255 downto 0);
  signal wstrb : std_logic_vector(31 downto 0);
  signal crc_req : std_logic;
  signal crc_addr : std_logic_vector(32 downto 0);
  signal crc_len : unsigned(39 downto 0);
  signal crc_seq, last_seq : std_logic_vector(31 downto 0);
  signal committed : unsigned(31 downto 0);
  signal crc_fail, seq_err, dup_cnt, bresp_err : unsigned(15 downto 0);
  signal busy : std_logic;
  signal peek_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal peek_data : std_logic_vector(255 downto 0);
  signal peek_hit : std_logic;
  signal axi_errors : natural;
begin
  clk <= not clk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_hbm_writer
    port map(clk => clk, rst => rst, q_valid => q_valid, q_data => q_data, q_ready => q_ready,
             awaddr => awaddr, awlen => awlen, awsize => awsize, awburst => awburst,
             awvalid => awvalid, awready => awready, wdata => wdata, wstrb => wstrb,
             wlast => wlast, wvalid => wvalid, wready => wready, bresp => bresp,
             bvalid => bvalid, bready => bready, crc_req => crc_req, crc_addr => crc_addr,
             crc_len => crc_len, crc_seq => crc_seq, crc_busy => '0', last_seq => last_seq,
             committed => committed, crc_fail => crc_fail, seq_err => seq_err,
             dup_cnt => dup_cnt, bresp_err => bresp_err, busy => busy);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true, BAD_BRESP_ADDR => x"0000000600")
    port map(clk => clk, awaddr => awaddr, awlen => awlen, awsize => awsize,
             awburst => awburst, awvalid => awvalid, awready => awready, wdata => wdata,
             wstrb => wstrb, wlast => wlast, wvalid => wvalid, wready => wready,
             bresp => bresp, bvalid => bvalid, bready => bready,
             araddr => (others => '0'), arlen => "0000", arsize => "101", arburst => "01",
             arvalid => '0', arready => open, rdata => open, rresp => open, rlast => open,
             rvalid => open, rready => '0', peek_addr => peek_addr, peek_data => peek_data,
             peek_hit => peek_hit, errors => axi_errors);

  driver : process
    file vf : text open read_mode is "jc_writer_vec.txt";
    variable l : line;
    variable c : character;
    variable w : std_logic_vector(255 downto 0);
    variable a : std_logic_vector(39 downto 0);
    variable s32, e32 : std_logic_vector(31 downto 0);
    variable e16a, e16b, e16c, e16d : std_logic_vector(15 downto 0);
    variable checks, errors, nmem : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then errors := errors + 1; report msg severity error; end if;
    end procedure;
    procedure push(tag : std_logic_vector(1 downto 0); d : std_logic_vector(255 downto 0)) is
    begin
      q_data <= tag & d; q_valid <= '1';
      wait until rising_edge(clk) and q_ready = '1';
      q_valid <= '0';
    end procedure;
  begin
    rst <= '1'; wait for 4 * CLK_P; wait until rising_edge(clk); rst <= '0';
    while not endfile(vf) loop
      readline(vf, l);
      read(l, c);
      case c is
        when 'B' => null;                                   -- configured by the generic
        when 'H' => hread(l, w); push(TAG_HDR, w);
        when 'D' => hread(l, w); push(TAG_DATA, w);
        when 'P' => hread(l, s32); push(TAG_PASS, std_logic_vector(resize(unsigned(s32), 256)));
        when 'F' => hread(l, s32); push(TAG_FAIL, std_logic_vector(resize(unsigned(s32), 256)));
        when 'M' =>
          if nmem = 0 then                                  -- drain before the first check
            for i in 0 to 2000 loop wait until rising_edge(clk); exit when busy = '0'; end loop;
            wait for 20 * CLK_P;
          end if;
          hread(l, a); hread(l, w);
          peek_addr <= a; wait for 1 ns;
          chk(peek_hit = '1' and peek_data = w, "memory at " & to_hstring(a));
          nmem := nmem + 1;
        when 'C' =>
          hread(l, s32); chk(last_seq = s32, "last_seq " & to_hstring(last_seq));
          hread(l, e32); chk(std_logic_vector(committed) = e32, "committed");
          hread(l, e16a); chk(std_logic_vector(crc_fail) = e16a, "crc_fail");
          hread(l, e16b); chk(std_logic_vector(seq_err) = e16b, "seq_err");
          hread(l, e16c); chk(std_logic_vector(dup_cnt) = e16c, "dup");
          hread(l, e16d); chk(std_logic_vector(bresp_err) = e16d, "bresp_err");
        when others => report "bad vector line" severity failure;
      end case;
    end loop;
    chk(axi_errors = 0, "AXI3 rule violations: " & integer'image(axi_errors));
    chk(crc_req = '0', "no range CRC was requested");
    assert nmem = 97 report "expected 97 memory checks, did " & integer'image(nmem) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_hbm_writer checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_hbm_writer errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
```

- [ ] **Step 4: Run it to see it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t4a bash sim/regress.sh --only tb_jc_hbm_writer --keep 2>&1 | tail -4`
Expected: analysis error, `jc_hbm_writer` not found.

- [ ] **Step 5: Implement `rtl/jc_hbm_writer.vhd`**

```vhdl
-- Jungle Cat loader: 200 MHz HBM writer. Spec S4.3; plan rulings 4 and 6.
-- Buffers one frame, commits it only on a PASS verdict with the expected seq, then
-- writes it in AXI3 bursts of at most 16 beats that never cross 4 KB.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

entity jc_hbm_writer is
  generic(ADDR_W : positive := 33);
  port(
    clk, rst  : in  std_logic;
    q_valid   : in  std_logic;
    q_data    : in  std_logic_vector(JC_FIFO_W-1 downto 0);
    q_ready   : out std_logic;
    awaddr    : out std_logic_vector(ADDR_W-1 downto 0);
    awlen     : out std_logic_vector(3 downto 0);
    awsize    : out std_logic_vector(2 downto 0);
    awburst   : out std_logic_vector(1 downto 0);
    awvalid   : out std_logic;
    awready   : in  std_logic;
    wdata     : out std_logic_vector(255 downto 0);
    wstrb     : out std_logic_vector(31 downto 0);
    wlast     : out std_logic;
    wvalid    : out std_logic;
    wready    : in  std_logic;
    bresp     : in  std_logic_vector(1 downto 0);
    bvalid    : in  std_logic;
    bready    : out std_logic;
    crc_req   : out std_logic;
    crc_addr  : out std_logic_vector(ADDR_W-1 downto 0);
    crc_len   : out unsigned(39 downto 0);
    crc_seq   : out std_logic_vector(31 downto 0);
    crc_busy  : in  std_logic;
    last_seq  : out std_logic_vector(31 downto 0);
    committed : out unsigned(31 downto 0);
    crc_fail  : out unsigned(15 downto 0);
    seq_err   : out unsigned(15 downto 0);
    dup_cnt   : out unsigned(15 downto 0);
    bresp_err : out unsigned(15 downto 0);
    busy      : out std_logic
  );
end entity;

architecture rtl of jc_hbm_writer is
  type state_t is (S_HDR, S_COLLECT, S_DECIDE, S_CRCREQ, S_AW, S_W, S_B);
  signal st : state_t := S_HDR;
  type buf_t is array (0 to 63) of std_logic_vector(255 downto 0);
  signal buf : buf_t;
  signal cnt      : unsigned(6 downto 0) := (others => '0');
  signal h_seq    : unsigned(31 downto 0) := (others => '0');
  signal h_addr   : unsigned(39 downto 0) := (others => '0');
  signal h_nw     : unsigned(15 downto 0) := (others => '0');
  signal h_flags  : std_logic_vector(15 downto 0) := (others => '0');
  signal h_rlen   : unsigned(39 downto 0) := (others => '0');
  signal v_ok     : std_logic := '0';
  signal last     : unsigned(31 downto 0) := (others => '1');
  signal n_commit : unsigned(31 downto 0) := (others => '0');
  signal n_crc, n_seq, n_dup, n_bresp : unsigned(15 downto 0) := (others => '0');
  signal cur      : unsigned(39 downto 0) := (others => '0');
  signal remain   : unsigned(6 downto 0) := (others => '0');
  signal rd_idx   : unsigned(5 downto 0) := (others => '0');
  signal beat     : unsigned(4 downto 0) := (others => '0');
  signal blen     : unsigned(4 downto 0);
  signal awv, wv  : std_logic := '0';
  signal creq     : std_logic := '0';

  -- beats in the next burst: min(16, remain, beats left before the 4 KB boundary)
  function burst_len(a : unsigned(39 downto 0); r : unsigned(6 downto 0)) return unsigned is
    variable to4k : unsigned(7 downto 0);
    variable n    : unsigned(7 downto 0);
  begin
    to4k := to_unsigned(128, 8) - resize(a(11 downto 5), 8);
    n := to_unsigned(16, 8);
    if resize(r, 8) < n then n := resize(r, 8); end if;
    if to4k < n then n := to4k; end if;
    return n(4 downto 0);
  end function;
begin
  blen      <= burst_len(cur, remain);
  q_ready   <= '1' when st = S_HDR or st = S_COLLECT else '0';
  awaddr    <= std_logic_vector(cur(ADDR_W-1 downto 0));
  awlen     <= std_logic_vector(resize(blen - 1, 4));
  awsize    <= "101";
  awburst   <= "01";
  awvalid   <= awv;
  wdata     <= buf(to_integer(rd_idx));
  wstrb     <= (others => '1');
  wlast     <= '1' when beat = blen - 1 else '0';
  wvalid    <= wv;
  bready    <= '1' when st = S_B else '0';
  crc_req   <= creq;
  crc_addr  <= std_logic_vector(h_addr(ADDR_W-1 downto 0));
  crc_len   <= h_rlen;
  crc_seq   <= std_logic_vector(h_seq);
  last_seq  <= std_logic_vector(last);
  committed <= n_commit;
  crc_fail  <= n_crc;
  seq_err   <= n_seq;
  dup_cnt   <= n_dup;
  bresp_err <= n_bresp;
  busy      <= '0' when st = S_HDR else '1';

  process(clk)
    variable tag  : std_logic_vector(1 downto 0);
    variable d    : std_logic_vector(255 downto 0);
    variable diff : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      creq <= '0';
      if rst = '1' then
        st <= S_HDR; last <= (others => '1'); n_commit <= (others => '0');
        n_crc <= (others => '0'); n_seq <= (others => '0'); n_dup <= (others => '0');
        n_bresp <= (others => '0'); awv <= '0'; wv <= '0';
      else
        tag := q_data(257 downto 256);
        d   := q_data(255 downto 0);
        case st is
          when S_HDR =>
            if q_valid = '1' and tag = TAG_HDR then
              h_seq <= unsigned(d(63 downto 32)); h_addr <= unsigned(d(103 downto 64));
              h_nw <= unsigned(d(119 downto 104)); h_flags <= d(135 downto 120);
              h_rlen <= unsigned(d(175 downto 136)); cnt <= (others => '0');
              st <= S_COLLECT;
            end if;
          when S_COLLECT =>
            if q_valid = '1' then
              if tag = TAG_DATA then
                if cnt < JC_MAX_PAYLOAD then buf(to_integer(cnt)) <= d; end if;
                cnt <= cnt + 1;
              elsif tag = TAG_HDR then          -- a frame lost its verdict: count, restart
                n_crc <= n_crc + 1;
                h_seq <= unsigned(d(63 downto 32)); h_addr <= unsigned(d(103 downto 64));
                h_nw <= unsigned(d(119 downto 104)); h_flags <= d(135 downto 120);
                h_rlen <= unsigned(d(175 downto 136)); cnt <= (others => '0');
              else
                if tag = TAG_PASS and unsigned(d(31 downto 0)) = h_seq
                   and resize(cnt, 16) = h_nw then
                  v_ok <= '1';
                else
                  v_ok <= '0';
                end if;
                st <= S_DECIDE;
              end if;
            end if;
          when S_DECIDE =>
            diff := h_seq - (last + 1);
            if v_ok = '0' then
              n_crc <= n_crc + 1; st <= S_HDR;
            elsif h_nw = 0 and h_flags(0) = '0' then
              st <= S_HDR;                                -- status poll
            elsif diff = 0 then
              if h_flags(0) = '1' then
                st <= S_CRCREQ;
              else
                cur <= h_addr; remain <= resize(h_nw, 7); rd_idx <= (others => '0');
                st <= S_AW;
              end if;
            elsif diff(31) = '1' then
              n_dup <= n_dup + 1; st <= S_HDR;
            else
              n_seq <= n_seq + 1; st <= S_HDR;
            end if;
          when S_CRCREQ =>
            if crc_busy = '0' then
              creq <= '1'; last <= h_seq; n_commit <= n_commit + 1; st <= S_HDR;
            end if;
          when S_AW =>
            awv <= '1';
            if awv = '1' and awready = '1' then
              awv <= '0'; beat <= (others => '0'); wv <= '1'; st <= S_W;
            end if;
          when S_W =>
            if wv = '1' and wready = '1' then
              rd_idx <= rd_idx + 1;
              if beat = blen - 1 then
                wv <= '0'; st <= S_B;
              else
                beat <= beat + 1;
              end if;
            end if;
          when S_B =>
            if bvalid = '1' then
              if bresp /= "00" then n_bresp <= n_bresp + 1; end if;
              cur <= cur + resize(blen & "00000", 40);
              remain <= remain - resize(blen, 7);
              if remain = resize(blen, 7) then
                last <= h_seq; n_commit <= n_commit + 1; st <= S_HDR;
              else
                st <= S_AW;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 6: Run the bench to see it pass**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t4b bash sim/regress.sh --only tb_jc_hbm_writer --keep 2>&1 | tail -4`
Expected: `PASS sim:tb_jc_hbm_writer`, `OVERALL PASS 1 FAIL 0`. Read the row log: `checks=` is 104 (97 memory + 6 counters + AXI + crc_req) and there are no `AXI3 ... breaks a rule` lines.

- [ ] **Step 7: Commit**

```bash
git add sim/jc_axi3_mem.vhd rtl/jc_hbm_writer.vhd sim/tb_jc_hbm_writer.vhd sim/jc_writer_vec.txt tools/jc/gen_jc_vectors.py
git commit -m "jc loader: AXI3 HBM writer (commit-on-PASS, seq check, 16-beat/4KB bursts) and AXI3 memory model"
```

---

### Task 5: Range CRC unit `jc_hbm_crc`

**Files:**
- Create: `rtl/jc_hbm_crc.vhd`, `sim/tb_jc_hbm_crc.vhd`
- Modify: `tools/jc/gen_jc_vectors.py` (add `gen_crcunit`), create `sim/jc_crcunit_vec.txt`

**Interfaces:**
- Consumes: `jc_axi3_mem` (Task 4), `crc32_word` (Task 1).
- Produces: `entity jc_hbm_crc` generic `ADDR_W : positive := 33`; ports `clk, rst, req : in std_logic; req_addr(ADDR_W-1 downto 0); req_len : unsigned(39 downto 0); req_seq(31 downto 0); busy : out std_logic`; AXI3 read master `araddr(ADDR_W-1 downto 0), arlen(3 downto 0), arsize(2 downto 0), arburst(1 downto 0), arvalid, arready, rdata(255 downto 0), rresp(1 downto 0), rlast, rvalid, rready`; result `res_valid, res_err : out std_logic; res_crc, res_seq : out std_logic_vector(31 downto 0)`.

- [ ] **Step 1: Add the vectors**

```python
def gen_crcunit(rng):
    """Preloaded memory plus range requests with zlib CRCs over the same bytes."""
    words = {}
    for base in (0x0000, 0x0FC0, 0x2000):
        for k in range(70):
            words[base + 32 * k] = rng.randbytes(32)
    reqs = [(0x0000, 32, 1), (0x0000, 70 * 32, 2), (0x0FC0, 5 * 32, 3),   # 5 beats across 4 KB
            (0x2000, 16 * 32, 4), (0x2000, 17 * 32, 5), (0x2000, 0, 6)]  # 0 bytes: CRC of nothing
    with open(sim("jc_crcunit_vec.txt"), "w") as f:
        for a in sorted(words):
            f.write("M %010x %064x\n" % (a, int.from_bytes(words[a], "little")))
        for a, n, seq in reqs:
            data = b"".join(words.get(x, bytes(32)) for x in range(a, a + n, 32))
            f.write("R %010x %010x %08x %08x\n" % (a, n, seq, zlib.crc32(data) & 0xFFFFFFFF))
```

Note `0x0FC0 + 70*32` overlaps `0x2000`? No: `0x0FC0 + 0x8C0 = 0x1880 < 0x2000`. Run: `python3 tools/jc/gen_jc_vectors.py --only crcunit && grep -c '^R ' sim/jc_crcunit_vec.txt`
Expected: `wrote crcunit`, `6`.

- [ ] **Step 2: Write the failing bench**

`sim/tb_jc_hbm_crc.vhd`:

```vhdl
-- Bench for rtl/jc_hbm_crc.vhd: preloads sim/jc_axi3_mem.vhd, issues range requests and
-- compares each result with the zlib CRC in sim/jc_crcunit_vec.txt.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_jc_hbm_crc is
end entity;

architecture sim of tb_jc_hbm_crc is
  constant CLK_P : time := 5 ns;
  signal clk, rst : std_logic := '0';
  signal done : boolean := false;
  signal req, busy, res_valid, res_err : std_logic := '0';
  signal req_addr, araddr : std_logic_vector(32 downto 0) := (others => '0');
  signal req_len : unsigned(39 downto 0) := (others => '0');
  signal req_seq, res_crc, res_seq : std_logic_vector(31 downto 0) := (others => '0');
  signal arlen : std_logic_vector(3 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst, rresp : std_logic_vector(1 downto 0);
  signal arvalid, arready, rlast, rvalid, rready : std_logic;
  signal rdata : std_logic_vector(255 downto 0);
  signal poke_en : std_logic := '0';
  signal poke_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(255 downto 0) := (others => '0');
  signal axi_errors : natural;
begin
  clk <= not clk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_hbm_crc
    port map(clk => clk, rst => rst, req => req, req_addr => req_addr, req_len => req_len,
             req_seq => req_seq, busy => busy, araddr => araddr, arlen => arlen,
             arsize => arsize, arburst => arburst, arvalid => arvalid, arready => arready,
             rdata => rdata, rresp => rresp, rlast => rlast, rvalid => rvalid,
             rready => rready, res_valid => res_valid, res_err => res_err,
             res_crc => res_crc, res_seq => res_seq);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true)
    port map(clk => clk, awaddr => (others => '0'), awlen => "0000", awsize => "101",
             awburst => "01", awvalid => '0', awready => open, wdata => (others => '0'),
             wstrb => (others => '1'), wlast => '0', wvalid => '0', wready => open,
             bresp => open, bvalid => open, bready => '0', araddr => araddr, arlen => arlen,
             arsize => arsize, arburst => arburst, arvalid => arvalid, arready => arready,
             rdata => rdata, rresp => rresp, rlast => rlast, rvalid => rvalid,
             rready => rready, poke_en => poke_en, poke_addr => poke_addr,
             poke_data => poke_data, peek_data => open, peek_hit => open,
             errors => axi_errors);

  driver : process
    file vf : text open read_mode is "jc_crcunit_vec.txt";
    variable l : line;
    variable c : character;
    variable a : std_logic_vector(39 downto 0);
    variable n : std_logic_vector(39 downto 0);
    variable w : std_logic_vector(255 downto 0);
    variable s32, e32 : std_logic_vector(31 downto 0);
    variable checks, errors, nreq : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then errors := errors + 1; report msg severity error; end if;
    end procedure;
  begin
    rst <= '1'; wait for 4 * CLK_P; wait until rising_edge(clk); rst <= '0';
    while not endfile(vf) loop
      readline(vf, l);
      read(l, c);
      if c = 'M' then
        hread(l, a); hread(l, w);
        poke_addr <= a; poke_data <= w; poke_en <= '1';
        wait until rising_edge(clk); poke_en <= '0';
      else
        hread(l, a); hread(l, n); hread(l, s32); hread(l, e32);
        req_addr <= a(32 downto 0); req_len <= unsigned(n); req_seq <= s32; req <= '1';
        wait until rising_edge(clk); req <= '0';
        wait until rising_edge(clk);
        for i in 0 to 20000 loop
          exit when busy = '0';
          wait until rising_edge(clk);
        end loop;
        chk(busy = '0', "request " & to_hstring(s32) & " never finished");
        chk(res_valid = '1' and res_seq = s32, "result seq " & to_hstring(res_seq));
        chk(res_crc = e32, "crc " & to_hstring(res_crc) & " expected " & to_hstring(e32));
        chk(res_err = '0', "no RRESP error");
        nreq := nreq + 1;
      end if;
    end loop;
    chk(axi_errors = 0, "AXI3 rule violations: " & integer'image(axi_errors));
    assert nreq = 6 report "expected 6 requests" severity failure;
    if errors = 0 then
      report "PASS: tb_jc_hbm_crc checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_hbm_crc errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
```

- [ ] **Step 3: Run it to see it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t5a bash sim/regress.sh --only tb_jc_hbm_crc --keep 2>&1 | tail -4`
Expected: analysis error, `jc_hbm_crc` not found.

- [ ] **Step 4: Implement `rtl/jc_hbm_crc.vhd`**

```vhdl
-- Jungle Cat loader: range CRC-32 over HBM (spec S4.5). Reads in AXI3 bursts of at most
-- 16 beats that never cross 4 KB, folds each 256-bit beat 32 bits per cycle (8 cycles a
-- beat, ~800 MB/s at 200 MHz). The result holds until the next request.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

entity jc_hbm_crc is
  generic(ADDR_W : positive := 33);
  port(
    clk, rst  : in  std_logic;
    req       : in  std_logic;
    req_addr  : in  std_logic_vector(ADDR_W-1 downto 0);
    req_len   : in  unsigned(39 downto 0);
    req_seq   : in  std_logic_vector(31 downto 0);
    busy      : out std_logic;
    araddr    : out std_logic_vector(ADDR_W-1 downto 0);
    arlen     : out std_logic_vector(3 downto 0);
    arsize    : out std_logic_vector(2 downto 0);
    arburst   : out std_logic_vector(1 downto 0);
    arvalid   : out std_logic;
    arready   : in  std_logic;
    rdata     : in  std_logic_vector(255 downto 0);
    rresp     : in  std_logic_vector(1 downto 0);
    rlast     : in  std_logic;
    rvalid    : in  std_logic;
    rready    : out std_logic;
    res_valid : out std_logic;
    res_err   : out std_logic;
    res_crc   : out std_logic_vector(31 downto 0);
    res_seq   : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of jc_hbm_crc is
  type state_t is (S_IDLE, S_AR, S_R, S_PROC, S_DONE);
  signal st     : state_t := S_IDLE;
  signal cur    : unsigned(39 downto 0) := (others => '0');
  signal beats  : unsigned(34 downto 0) := (others => '0');   -- beats left in the range
  signal blen   : unsigned(4 downto 0);
  signal inb    : unsigned(4 downto 0) := (others => '0');    -- beats left in this burst
  signal beat_r : std_logic_vector(255 downto 0) := (others => '0');
  signal k      : unsigned(2 downto 0) := (others => '0');
  signal crc    : std_logic_vector(31 downto 0) := (others => '1');
  signal seq    : std_logic_vector(31 downto 0) := (others => '0');
  signal rv, rerr, arv : std_logic := '0';
  signal outcrc : std_logic_vector(31 downto 0) := (others => '0');

  function burst_len(a : unsigned(39 downto 0); r : unsigned(34 downto 0)) return unsigned is
    variable to4k, n : unsigned(7 downto 0);
  begin
    to4k := to_unsigned(128, 8) - resize(a(11 downto 5), 8);
    n := to_unsigned(16, 8);
    if r < 16 then n := resize(r, 8); end if;
    if to4k < n then n := to4k; end if;
    return n(4 downto 0);
  end function;
begin
  blen      <= burst_len(cur, beats);
  araddr    <= std_logic_vector(cur(ADDR_W-1 downto 0));
  arlen     <= std_logic_vector(resize(blen - 1, 4));
  arsize    <= "101";
  arburst   <= "01";
  arvalid   <= arv;
  rready    <= '1' when st = S_R else '0';
  busy      <= '0' when st = S_IDLE else '1';
  res_valid <= rv;
  res_err   <= rerr;
  res_crc   <= outcrc;
  res_seq   <= seq;

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st <= S_IDLE; rv <= '0'; rerr <= '0'; arv <= '0';
      else
        case st is
          when S_IDLE =>
            if req = '1' then
              cur <= resize(unsigned(req_addr), 40);
              beats <= resize(req_len(39 downto 5), 35);
              crc <= (others => '1'); seq <= req_seq; rv <= '0'; rerr <= '0';
              if req_len(39 downto 5) = 0 then st <= S_DONE; else st <= S_AR; end if;
            end if;
          when S_AR =>
            arv <= '1';
            if arv = '1' and arready = '1' then
              arv <= '0'; inb <= blen; st <= S_R;
            end if;
          when S_R =>
            if rvalid = '1' then
              beat_r <= rdata; k <= (others => '0');
              if rresp /= "00" then rerr <= '1'; end if;
              st <= S_PROC;
            end if;
          when S_PROC =>
            crc <= crc32_word(crc, beat_r(32 * to_integer(k) + 31 downto 32 * to_integer(k)));
            if k = 7 then
              beats <= beats - 1;
              cur <= cur + 32;
              if inb = 1 then
                if beats = 1 then st <= S_DONE; else st <= S_AR; end if;
              else
                inb <= inb - 1; st <= S_R;
              end if;
            else
              k <= k + 1;
            end if;
          when S_DONE =>
            outcrc <= crc xor x"FFFFFFFF"; rv <= '1'; st <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
```

Note: `cur` advances by 32 per beat inside a burst, so after a burst it already points at the next burst's address; `blen` is only sampled in `S_AR`, when `cur` is the burst start.

- [ ] **Step 5: Run the bench to see it pass**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t5b bash sim/regress.sh --only tb_jc_hbm_crc --keep 2>&1 | tail -4`
Expected: `PASS sim:tb_jc_hbm_crc`, `OVERALL PASS 1 FAIL 0`.

- [ ] **Step 6: Commit**

```bash
git add rtl/jc_hbm_crc.vhd sim/tb_jc_hbm_crc.vhd sim/jc_crcunit_vec.txt tools/jc/gen_jc_vectors.py
git commit -m "jc loader: HBM range CRC-32 unit (AXI3 reads, 16-beat/4KB) with zlib-vector bench"
```

---

### Task 6: Status CDC and the composed `jc_loader_core`

**Files:**
- Create: `rtl/jc_status_sync.vhd`, `rtl/jc_loader_core.vhd`, `sim/tb_jc_loader_core.vhd`
- Modify: `tools/jc/gen_jc_vectors.py` (add `gen_loader`), create `sim/jc_loader_vec.txt`

**Interfaces:**
- Consumes: `jc_frame_core` (Task 3), `async_fifo` (`rtl/async_fifo.vhd`, `W => 258, DEPTH => 128`), `jc_hbm_writer` (Task 4), `jc_hbm_crc` (Task 5), `jc_axi3_mem` (Task 4), `LoaderModel` (Task 2).
- Produces: `entity jc_status_sync` ports `aclk : in std_logic; live : in std_logic_vector(255 downto 0); tck : in std_logic; st_tck : out std_logic_vector(255 downto 0)`.
- Produces: `entity jc_loader_core` generic `ADDR_W : positive := 33`; ports `tck, sel, capture, shift, tdi : in std_logic; tdo : out std_logic; aclk, arst : in std_logic; hbm_cat_trip : in std_logic;` and the full AXI3 master `m_awaddr .. m_rready` (write channels from the writer, read channels from the CRC unit, same names and widths as Tasks 4 and 5 with an `m_` prefix).

- [ ] **Step 1: Add the end-to-end vectors**

```python
def gen_loader(rng):
    """One continuous scan as the host sends it, plus the model's final memory and status."""
    from jc import jc_frame as F
    from jc.jc_model import LoaderModel
    m = LoaderModel()
    slots = [bytes(F.SLOT_BYTES)]                                     # filler (lead = 0)
    seq = 0
    for k in range(12):
        addr = 0x0400 * k + (0x0FE0 if k == 5 else 0)                 # k=5 crosses 4 KB
        slots.append(F.build_slot(seq, addr, rng.randbytes(rng.randrange(32, 1985)))); seq += 1
    bad = bytearray(F.build_slot(seq, 0x8000, rng.randbytes(500))); bad[999] ^= 2
    slots.append(bytes(bad))                                          # CRC fail
    slots.append(F.build_slot(seq, 0x8000, rng.randbytes(500))); seq += 1   # resend
    slots.append(F.build_slot(seq - 1, 0x8000, rng.randbytes(500)))   # duplicate
    slots.append(F.range_crc_slot(seq, 0x0000, 0x0400 * 3)); seq += 1
    slots += [F.poll_slot()] * 3
    for s in slots:
        m.feed(s)
    st = m.status()
    with open(sim("jc_loader_vec.txt"), "w") as f:
        for s in slots:
            f.write("S %s\n" % F.slot_hex(s))
        for a in sorted(m.mem):
            f.write("M %010x %064x\n" % (a, int.from_bytes(m.mem[a], "little")))
        f.write("T %08x %08x %04x %04x %04x %04x %08x %08x\n" % (
            st["last"], st["committed"], st["crc_fail"], st["seq_err"], st["dup"],
            st["desync"], st["range_crc"], st["range_seq"]))
```

Run: `python3 tools/jc/gen_jc_vectors.py --only loader && grep -c '^S ' sim/jc_loader_vec.txt && tail -1 sim/jc_loader_vec.txt`
Expected: `wrote loader`, `20` slots, and a `T` line whose first fields are `0000000d 0000000e 0001 0000 0001 0001` (last seq 13, 14 commits: seqs 0 to 11, the resent 12 and the range check at 13; one CRC fail, one duplicate, one desync from the filler).

- [ ] **Step 2: Write the failing bench**

`sim/tb_jc_loader_core.vhd`:

```vhdl
-- End-to-end bench for rtl/jc_loader_core.vhd: TCK at 27 MHz, aclk at 200 MHz, one Capture
-- then every slot of sim/jc_loader_vec.txt back to back. Checks HBM contents against the
-- Python model and the status word returned on TDO in the final poll slot.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_loader_core is
end entity;

architecture sim of tb_jc_loader_core is
  constant TCK_P : time := 37 ns;
  constant CLK_P : time := 5 ns;
  signal tck, aclk : std_logic := '0';
  signal arst : std_logic := '1';
  signal sel, capture, shift, tdi, tdo : std_logic := '0';
  signal done : boolean := false;
  signal awaddr, araddr : std_logic_vector(32 downto 0);
  signal awlen, arlen : std_logic_vector(3 downto 0);
  signal awsize, arsize : std_logic_vector(2 downto 0);
  signal awburst, arburst, bresp, rresp : std_logic_vector(1 downto 0);
  signal awvalid, awready, wlast, wvalid, wready, bvalid, bready : std_logic;
  signal arvalid, arready, rlast, rvalid, rready : std_logic;
  signal wdata, rdata : std_logic_vector(255 downto 0);
  signal wstrb : std_logic_vector(31 downto 0);
  signal peek_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal peek_data : std_logic_vector(255 downto 0);
  signal peek_hit : std_logic;
  signal axi_errors : natural;
begin
  tck  <= not tck after TCK_P / 2 when not done else '0';
  aclk <= not aclk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_loader_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, aclk => aclk, arst => arst, hbm_cat_trip => '0',
             m_awaddr => awaddr, m_awlen => awlen, m_awsize => awsize, m_awburst => awburst,
             m_awvalid => awvalid, m_awready => awready, m_wdata => wdata, m_wstrb => wstrb,
             m_wlast => wlast, m_wvalid => wvalid, m_wready => wready, m_bresp => bresp,
             m_bvalid => bvalid, m_bready => bready, m_araddr => araddr, m_arlen => arlen,
             m_arsize => arsize, m_arburst => arburst, m_arvalid => arvalid,
             m_arready => arready, m_rdata => rdata, m_rresp => rresp, m_rlast => rlast,
             m_rvalid => rvalid, m_rready => rready);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 11, STALL => true)
    port map(clk => aclk, awaddr => awaddr, awlen => awlen, awsize => awsize,
             awburst => awburst, awvalid => awvalid, awready => awready, wdata => wdata,
             wstrb => wstrb, wlast => wlast, wvalid => wvalid, wready => wready,
             bresp => bresp, bvalid => bvalid, bready => bready, araddr => araddr,
             arlen => arlen, arsize => arsize, arburst => arburst, arvalid => arvalid,
             arready => arready, rdata => rdata, rresp => rresp, rlast => rlast,
             rvalid => rvalid, rready => rready, peek_addr => peek_addr,
             peek_data => peek_data, peek_hit => peek_hit, errors => axi_errors);

  driver : process
    file vf : text open read_mode is "jc_loader_vec.txt";
    variable l : line;
    variable c : character;
    variable slot : std_logic_vector(JC_SLOT_BITS-1 downto 0);
    variable st : std_logic_vector(255 downto 0);
    variable a : std_logic_vector(39 downto 0);
    variable w : std_logic_vector(255 downto 0);
    variable e32 : std_logic_vector(31 downto 0);
    variable e16 : std_logic_vector(15 downto 0);
    variable checks, errors, nslot, nmem : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then errors := errors + 1; report msg severity error; end if;
    end procedure;
  begin
    wait for 20 * CLK_P; arst <= '0'; wait for 20 * CLK_P;
    sel <= '1';
    wait until falling_edge(tck); capture <= '1';
    wait until falling_edge(tck); capture <= '0'; shift <= '1';
    while not endfile(vf) loop
      readline(vf, l);
      read(l, c);
      if c = 'S' then
        hread(l, slot);
        for i in 0 to JC_SLOT_BITS - 1 loop
          tdi <= slot(i);
          wait until rising_edge(tck);
          if i < 256 then st(i) := tdo; end if;
          wait until falling_edge(tck);
        end loop;
        nslot := nslot + 1;
      elsif c = 'M' then
        hread(l, a); hread(l, w);
        peek_addr <= a; wait for 1 ns;
        chk(peek_hit = '1' and peek_data = w, "memory at " & to_hstring(a));
        nmem := nmem + 1;
      else                                                -- 'T': status of the last slot
        chk(st(31 downto 0) = JC_MAGIC_STAT, "status magic " & to_hstring(st(31 downto 0)));
        hread(l, e32); chk(st(63 downto 32) = e32, "last " & to_hstring(st(63 downto 32)));
        hread(l, e32); chk(st(95 downto 64) = e32, "committed " & to_hstring(st(95 downto 64)));
        hread(l, e16); chk(st(111 downto 96) = e16, "crc_fail");
        hread(l, e16); chk(st(127 downto 112) = e16, "seq_err");
        hread(l, e16); chk(st(175 downto 160) = e16, "dup");
        hread(l, e16); chk(st(143 downto 128) = e16, "desync");
        hread(l, e32); chk(st(223 downto 192) = e32, "range crc " & to_hstring(st(223 downto 192)));
        hread(l, e32); chk(st(255 downto 224) = e32, "range seq");
        chk(st(178) = '1', "range valid");
        chk(st(176) = '0', "idle at the end");
        chk(st(179) = '0' and st(180) = '0', "no overflow, no read error");
        chk(st(159 downto 144) = x"0000", "no BRESP errors");
      end if;
    end loop;
    shift <= '0';
    chk(axi_errors = 0, "AXI3 rule violations: " & integer'image(axi_errors));
    assert nslot = 20 report "expected 20 slots" severity failure;
    assert nmem > 100 report "too few memory checks: " & integer'image(nmem) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_loader_core checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_loader_core errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
```

Note: the `M` lines are read after all slots, so the memory check runs once the last poll slots (about 1.8 ms of TCK) have given the writer and CRC unit far more time than they need. The status in the final poll slot was loaded at that slot's start, two full slots after the last real frame, which is what the CDC needs.

- [ ] **Step 3: Run it to see it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t6a bash sim/regress.sh --only tb_jc_loader_core --keep 2>&1 | tail -4`
Expected: analysis error, `jc_loader_core` not found.

- [ ] **Step 4: Implement `rtl/jc_status_sync.vhd`**

```vhdl
-- Jungle Cat loader: status crossing from aclk to TCK by toggle handshake. aclk publishes a
-- snapshot and flips `pub` only after TCK has acknowledged the previous one, so the
-- snapshot is stable whenever TCK samples it. TCK runs only while shifting, so TCK-side
-- progress happens only then; that is enough because status is read only while shifting.
library ieee;
use ieee.std_logic_1164.all;

entity jc_status_sync is
  port(
    aclk   : in  std_logic;
    live   : in  std_logic_vector(255 downto 0);
    tck    : in  std_logic;
    st_tck : out std_logic_vector(255 downto 0)
  );
end entity;

architecture rtl of jc_status_sync is
  signal snap   : std_logic_vector(255 downto 0) := (others => '0');
  signal pub    : std_logic := '0';
  signal ack_s1, ack_s2 : std_logic := '0';
  signal tgl_s1, tgl_s2 : std_logic := '0';
  signal ack    : std_logic := '0';
  signal st_r   : std_logic_vector(255 downto 0) := (others => '0');
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of ack_s1, ack_s2, tgl_s1, tgl_s2 : signal is "TRUE";
begin
  st_tck <= st_r;

  a_side : process(aclk)
  begin
    if rising_edge(aclk) then
      ack_s1 <= ack;
      ack_s2 <= ack_s1;
      if ack_s2 = pub then
        snap <= live;
        pub  <= not pub;
      end if;
    end if;
  end process;

  t_side : process(tck)
  begin
    if rising_edge(tck) then
      tgl_s1 <= pub;
      tgl_s2 <= tgl_s1;
      if tgl_s2 /= ack then
        st_r <= snap;
        ack  <= tgl_s2;
      end if;
    end if;
  end process;
end architecture;
```

- [ ] **Step 5: Implement `rtl/jc_loader_core.vhd`**

```vhdl
-- Jungle Cat loader: composition (spec S3). TCK side: jc_frame_core. Crossing:
-- async_fifo (258 x 128) for words, jc_status_sync for status. aclk side: jc_hbm_writer
-- (AXI3 write channels) and jc_hbm_crc (AXI3 read channels) share one master port.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

entity jc_loader_core is
  generic(ADDR_W : positive := 33);
  port(
    tck, sel, capture, shift, tdi : in  std_logic;
    tdo          : out std_logic;
    aclk, arst   : in  std_logic;
    hbm_cat_trip : in  std_logic;
    m_awaddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m_awlen   : out std_logic_vector(3 downto 0);
    m_awsize  : out std_logic_vector(2 downto 0);
    m_awburst : out std_logic_vector(1 downto 0);
    m_awvalid : out std_logic;
    m_awready : in  std_logic;
    m_wdata   : out std_logic_vector(255 downto 0);
    m_wstrb   : out std_logic_vector(31 downto 0);
    m_wlast   : out std_logic;
    m_wvalid  : out std_logic;
    m_wready  : in  std_logic;
    m_bresp   : in  std_logic_vector(1 downto 0);
    m_bvalid  : in  std_logic;
    m_bready  : out std_logic;
    m_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector(3 downto 0);
    m_arsize  : out std_logic_vector(2 downto 0);
    m_arburst : out std_logic_vector(1 downto 0);
    m_arvalid : out std_logic;
    m_arready : in  std_logic;
    m_rdata   : in  std_logic_vector(255 downto 0);
    m_rresp   : in  std_logic_vector(1 downto 0);
    m_rlast   : in  std_logic;
    m_rvalid  : in  std_logic;
    m_rready  : out std_logic
  );
end entity;

architecture rtl of jc_loader_core is
  signal w_valid, w_ready, q_valid, q_ready : std_logic;
  signal w_data, q_data : std_logic_vector(JC_FIFO_W-1 downto 0);
  signal st_tck, live : std_logic_vector(255 downto 0);
  signal desync : unsigned(15 downto 0);
  signal ovf : std_logic;
  signal trst_s1, trst_s2 : std_logic := '1';
  signal crc_req, crc_busy, res_valid, res_err, w_busy : std_logic;
  signal crc_addr : std_logic_vector(ADDR_W-1 downto 0);
  signal crc_len : unsigned(39 downto 0);
  signal crc_seq, res_crc, res_seq, last_seq : std_logic_vector(31 downto 0);
  signal committed : unsigned(31 downto 0);
  signal crc_fail, seq_err, dup_cnt, bresp_err : unsigned(15 downto 0);
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of trst_s1, trst_s2 : signal is "TRUE";
begin
  -- FIFO write-side reset in TCK: held from configuration until two TCK edges after arst
  -- falls. The host's filler slot absorbs those edges.
  process(tck)
  begin
    if rising_edge(tck) then
      trst_s1 <= arst;
      trst_s2 <= trst_s1;
    end if;
  end process;

  rx : entity work.jc_frame_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, w_valid => w_valid, w_data => w_data, w_ready => w_ready,
             st_in => st_tck, desync_cnt => desync, ovf_seen => ovf);

  fifo : entity work.async_fifo
    generic map(W => JC_FIFO_W, DEPTH => 128)
    port map(wclk => tck, wrst => trst_s2, w_valid => w_valid, w_data => w_data,
             w_ready => w_ready, w_level => open, clr => '0', clr_done => open,
             rclk => aclk, rrst => arst, q_valid => q_valid, q_data => q_data,
             q_ready => q_ready);

  wr : entity work.jc_hbm_writer
    generic map(ADDR_W => ADDR_W)
    port map(clk => aclk, rst => arst, q_valid => q_valid, q_data => q_data,
             q_ready => q_ready, awaddr => m_awaddr, awlen => m_awlen, awsize => m_awsize,
             awburst => m_awburst, awvalid => m_awvalid, awready => m_awready,
             wdata => m_wdata, wstrb => m_wstrb, wlast => m_wlast, wvalid => m_wvalid,
             wready => m_wready, bresp => m_bresp, bvalid => m_bvalid, bready => m_bready,
             crc_req => crc_req, crc_addr => crc_addr, crc_len => crc_len,
             crc_seq => crc_seq, crc_busy => crc_busy, last_seq => last_seq,
             committed => committed, crc_fail => crc_fail, seq_err => seq_err,
             dup_cnt => dup_cnt, bresp_err => bresp_err, busy => w_busy);

  cu : entity work.jc_hbm_crc
    generic map(ADDR_W => ADDR_W)
    port map(clk => aclk, rst => arst, req => crc_req, req_addr => crc_addr,
             req_len => crc_len, req_seq => crc_seq, busy => crc_busy,
             araddr => m_araddr, arlen => m_arlen, arsize => m_arsize,
             arburst => m_arburst, arvalid => m_arvalid, arready => m_arready,
             rdata => m_rdata, rresp => m_rresp, rlast => m_rlast, rvalid => m_rvalid,
             rready => m_rready, res_valid => res_valid, res_err => res_err,
             res_crc => res_crc, res_seq => res_seq);

  -- aclk-side status (the plan's "Status word layout"); the core fills magic, desync, ovf
  live(31 downto 0)    <= (others => '0');
  live(63 downto 32)   <= last_seq;
  live(95 downto 64)   <= std_logic_vector(committed);
  live(111 downto 96)  <= std_logic_vector(crc_fail);
  live(127 downto 112) <= std_logic_vector(seq_err);
  live(143 downto 128) <= (others => '0');
  live(159 downto 144) <= std_logic_vector(bresp_err);
  live(175 downto 160) <= std_logic_vector(dup_cnt);
  live(176)            <= w_busy or crc_busy;
  live(177)            <= hbm_cat_trip;
  live(178)            <= res_valid;
  live(179)            <= '0';
  live(180)            <= res_err;
  live(191 downto 181) <= (others => '0');
  live(223 downto 192) <= res_crc;
  live(255 downto 224) <= res_seq;

  sync : entity work.jc_status_sync
    port map(aclk => aclk, live => live, tck => tck, st_tck => st_tck);
end architecture;
```

Before running, confirm `async_fifo`'s port list against `rtl/async_fifo.vhd` (it is quoted in this plan's research: `wclk wrst w_valid w_data w_ready w_level clr clr_done rclk rrst q_valid q_data q_ready`). If `clr` must be held low after reset or `clr_done` has a different direction, follow the file.

- [ ] **Step 6: Run the bench to see it pass**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t6b bash sim/regress.sh --only tb_jc_loader_core --keep 2>&1 | tail -4`
Expected: `PASS sim:tb_jc_loader_core`, `OVERALL PASS 1 FAIL 0`. The run is about 20 slots x 16,384 TCK cycles; GHDL mcode should finish within a few minutes. If the row's `--stop-time` default is shorter than the ~12.2 ms of simulated time, give the row the same per-row stop-time override other long rows use in `sim/regress.sh` (search `stop-time` there).

- [ ] **Step 7: Run all five loader rows together**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/scratch/jcl_t6c bash sim/regress.sh --only tb_jc_ --keep 2>&1 | tail -8`
Expected: `PASS` for `tb_jc_crc32`, `tb_jc_frame_core`, `tb_jc_hbm_writer`, `tb_jc_hbm_crc`, `tb_jc_loader_core`; `OVERALL PASS 5 FAIL 0`.

- [ ] **Step 8: Commit**

```bash
git add rtl/jc_status_sync.vhd rtl/jc_loader_core.vhd sim/tb_jc_loader_core.vhd sim/jc_loader_vec.txt tools/jc/gen_jc_vectors.py
git commit -m "jc loader: status CDC and composed loader core, end-to-end bench against the Python model"
```

---

### Task 7: Mutation teeth with attribution controls

**Files:**
- Create: `sim/mutate_jc_loader.sh`

**Interfaces:**
- Consumes: every RTL file and bench from Tasks 1 to 6.
- Produces: a harness that prints one line per mutant, `KILLED`, `SURVIVED`, `BADMUT` (anchor matched 0 or 2+ times) or `DID NOT ANALYZE`, and a final `kill ratio` line. Exit 1 if the self-teeth row Z0 does not report BADMUT.

- [ ] **Step 1: Write the harness**

`sim/mutate_jc_loader.sh`:

```bash
#!/usr/bin/env bash
# Mutation teeth for the Jungle Cat loader (plan Task 7). Each row patches ONE anchor in
# ONE rtl file (the anchor must match exactly once), analyzes the closure into a fresh
# per-run directory and runs the named bench. KILLED = the bench reported FAIL or did not
# print its PASS line. Attribution rows (class ATTR) run a mutant against a bench that
# should NOT see it, to show which bench owns the kill.
# No rm anywhere: every row writes into a new directory under one per-run root.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
GHDL=${GHDL:-ghdl}
RUNROOT=/mnt/storage/fk33_builds/scratch/mutate_jc_loader_$(date +%Y%m%d_%H%M%S)_$$
mkdir -p "$RUNROOT"
DEPS="rtl/jc_loader_pkg.vhd rtl/async_fifo.vhd rtl/jc_frame_core.vhd rtl/jc_hbm_writer.vhd rtl/jc_hbm_crc.vhd rtl/jc_status_sync.vhd rtl/jc_loader_core.vhd sim/jc_axi3_mem.vhd"
NK=0; NS=0; NB=0; NT=0; Z0SEEN=0

run_row() {   # run_row <tag> <class> <rtlfile> <bench> <desc> <old> <new>
  local tag=$1 cls=$2 file=$3 tb=$4 desc=$5 old=$6 new=$7
  local dir=$RUNROOT/$tag
  NT=$((NT+1))
  mkdir -p "$dir/work" "$dir/run"
  cp "$REPO/sim/"jc_*_vec.txt "$dir/run/"
  if ! python3 - "$REPO/$file" "$dir/$(basename "$file")" "$old" "$new" <<'PY' 2>"$dir/patch.log"
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("ANCHOR MATCHED %d TIMES\n" % n); sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  then
    if [ "$tag" = Z0 ]; then Z0SEEN=1; printf '%-4s %-5s BADMUT   (required for the self-teeth row)\n' "$tag" "$cls"
    else NB=$((NB+1)); printf '%-4s %-5s BADMUT   THIS ROW TESTED NOTHING -- %s\n' "$tag" "$cls" "$desc"; fi
    return
  fi
  local f ok=1
  for f in $DEPS; do
    if [ "$f" = "$file" ]; then f="$dir/$(basename "$file")"; else f="$REPO/$f"; fi
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$f" >>"$dir/analyze.log" 2>&1 || ok=0
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$REPO/sim/$tb.vhd" >>"$dir/analyze.log" 2>&1 || ok=0
  if [ $ok = 0 ]; then
    printf '%-4s %-5s DID NOT ANALYZE -- %s\n' "$tag" "$cls" "$desc"; return
  fi
  ( cd "$dir/run" && timeout 900 "$GHDL" -r --std=08 -frelaxed --workdir="$dir/work" "$tb" \
      --stop-time=40ms ) >"$dir/log" 2>&1
  if grep -q "PASS: $tb" "$dir/log"; then
    NS=$((NS+1)); printf '%-4s %-5s SURVIVED %s -- %s\n' "$tag" "$cls" "$tb" "$desc"
  else
    NK=$((NK+1)); printf '%-4s %-5s KILLED   %s -- %s\n' "$tag" "$cls" "$tb" "$desc"
  fi
}

# control: the unmutated tree must pass every bench (a no-op patch on a unique anchor)
for tb in tb_jc_crc32 tb_jc_frame_core tb_jc_hbm_writer tb_jc_hbm_crc tb_jc_loader_core; do
  run_row "C_$tb" CTRL rtl/jc_loader_pkg.vhd "$tb" "control, no change" "x\"EDB88320\"" "x\"EDB88320\""
done

run_row Z0 AUDIT rtl/jc_loader_pkg.vhd tb_jc_crc32 "self-teeth: anchor not in the file" "THIS TEXT IS NOT IN THE FILE" "x"
run_row M1 VALUE rtl/jc_loader_pkg.vhd tb_jc_crc32 "CRC polynomial one bit off" "x\"EDB88320\"" "x\"EDB88321\""
run_row M2 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core "verdict ignores the CRC" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"
run_row M3 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core "magic not checked" "if word(31 downto 0) = JC_MAGIC_FRAME" "if true"
run_row M4 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core "one payload word too many" "widx <= to_integer(nwords)" "widx <= to_integer(nwords) + 1"
run_row M5 VALUE rtl/jc_frame_core.vhd tb_jc_frame_core "desync not counted" "desync <= desync + 1;" "null;"
run_row M6 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "commit on FAIL" "if tag = TAG_PASS and unsigned" "if unsigned"
run_row M7 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "seq check removed" "elsif diff = 0 then" "elsif true then"
run_row M8 PROTO rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "17-beat bursts" "n := to_unsigned(16, 8);" "n := to_unsigned(17, 8);"
run_row M9 PROTO rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "4 KB rule off" "if to4k < n then n := to4k; end if;" "null;"
run_row M10 VALUE rtl/jc_hbm_writer.vhd tb_jc_hbm_writer "BRESP errors not counted" "n_bresp <= n_bresp + 1;" "null;"
run_row M11 VALUE rtl/jc_hbm_crc.vhd tb_jc_hbm_crc "CRC unit skips the last 32-bit lane" "if k = 7 then" "if k = 6 then"
run_row M12 PROTO rtl/jc_hbm_crc.vhd tb_jc_hbm_crc "read bursts ignore 4 KB" "if to4k < n then n := to4k; end if;" "null;"
run_row M13 CDC   rtl/jc_status_sync.vhd tb_jc_loader_core "status never updates in TCK" "st_r <= snap;" "null;"
run_row M14 VALUE rtl/jc_loader_core.vhd tb_jc_loader_core "range result not in status" "live(223 downto 192) <= res_crc;" "live(223 downto 192) <= (others => '0');"
# attribution: the writer bench must NOT see a frame-core mutant (it bypasses the core)
run_row A1 ATTR rtl/jc_frame_core.vhd tb_jc_hbm_writer "M2 against a bench without the core" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"
# attribution: the end-to-end bench must also kill the frame-core CRC mutant on its own
run_row A2 ATTR rtl/jc_frame_core.vhd tb_jc_loader_core "M2 seen end to end" "if crc_rx = (crc xor x\"FFFFFFFF\") then" "if true then"

printf 'kill ratio: %d KILLED of %d rows; %d SURVIVED; %d BADMUT\n' "$NK" "$NT" "$NS" "$NB"
printf 'scratch: %s\n' "$RUNROOT"
[ $Z0SEEN = 1 ] || { echo "HARNESS FAILURE: Z0 did not report BADMUT"; exit 1; }
```

Notes for the implementer: (a) the 5 `C_*` control rows must all report `SURVIVED` (an unmutated tree passing is a "survival" by this harness's definition); if any control is KILLED, nothing else in the table means anything. (b) Expected outcome: M1 to M14 and A2 KILLED, A1 SURVIVED (the writer bench never instantiates the core, so it cannot see M2, which is the attribution it shows). (c) The benches open vectors by bare name, so the vectors are copied into each row's `run` directory, mirroring what `sim/regress.sh` does with symlinks.

- [ ] **Step 2: Run it**

Run: `bash sim/mutate_jc_loader.sh 2>&1 | tee /mnt/storage/fk33_builds/scratch/mutate_jc_loader_task7.log | tail -25`
Expected: five `C_*` rows `SURVIVED`; `Z0 AUDIT BADMUT (required ...)`; M1 to M14 `KILLED`; `A1 ATTR SURVIVED`; `A2 ATTR KILLED`; `kill ratio: 15 KILLED of 22 rows; 6 SURVIVED; 0 BADMUT`.

- [ ] **Step 3: If a VALUE/PROTO/CDC mutant SURVIVES, strengthen the bench, never the harness**

For each survivor, write the bench case that distinguishes it (for example, M10 surviving means the writer vectors never produce a SLVERR: check `B` handling and the model's `bad_bresp_addrs`), regenerate vectors with `gen_jc_vectors.py`, re-run that bench's normal gate row to green, then re-run the harness. Record any survivor that is correct by construction under its own name in the harness header comment with the reason, as `sim/mutate_async_fifo.sh` does for P10 and P14.

- [ ] **Step 4: Commit**

```bash
git add sim/mutate_jc_loader.sh
git commit -m "jc loader: mutation harness, 14 mutants with self-teeth and attribution rows"
```

---

### Task 8: CoE client library with the IR allowlist, and the load planner

**Files:**
- Create: `tools/jc/coe.py`, `tools/jc/test_coe.py`
- Modify: `hw/jc/xvcstream/coe_stream.py` (import the client from `tools/jc/coe.py`)
- Create: `tools/jc/coe_load.py` (planning half: `plan_frames`), `tools/jc/test_coe_load.py` (planning tests)

**Interfaces:**
- Produces (`tools/jc/coe.py`): `IR_BYPASS=0xFFF, IR_IDCODE=0x249, IR_USER3=0x8A4, IR_USER4=0x8E4`, `IR_ALLOW = {IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4}`, `class IRNotAllowed(Exception)`; `class CoE(ip, port=21363, timeout=10.0)` with `send(cmd, payload=b"") -> int`, `reply() -> (txn, status, data)`, `call(cmd, payload=b"") -> (status, data)`, `start(hz=27_000_000) -> bytes` (hello, speed, mode, IDCODEs, IR lengths, mode; returns the IDCODE bytes); `tms_payload(bits) -> bytes`, `pair_payload(tdi_bits, tms_bits) -> bytes`, `ir_scan_payload(ops_tdi_to_tdo) -> bytes` (raises `IRNotAllowed`), `dr_payload(nbits, tdi: bytes) -> bytes` (`0x8000100f` form), constants `CMD_TMS=0x8000100E`, `CMD_TDI=0x8000100F`.
- Produces (`tools/jc/coe_load.py`): `Frame = namedtuple("Frame", "seq addr path off n kind")` with `kind` in `{"data", "range"}`; `plan_frames(manifest_path) -> (frames: list[Frame], plan_sha: str)`; `expected_range_crc(frame) -> int`.

- [ ] **Step 1: Write the failing tests**

`tools/jc/test_coe.py`:

```python
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import coe

# Captured from the stock sqrl_bridge on 2026-10-05 (debugging doc S12).
CAPTURED = {"reset": "00000600001f", "toIR": "000004000003", "exitIR": "000002000001",
            "toDR": "000003000001", "exit": "000003000003"}

def test_tms_payloads_match_the_bridge_byte_for_byte():
    assert coe.tms_payload([1, 1, 1, 1, 1, 0]).hex() == CAPTURED["reset"]
    assert coe.tms_payload([1, 1, 0, 0]).hex() == CAPTURED["toIR"]
    assert coe.tms_payload([1, 0]).hex() == CAPTURED["exitIR"]
    assert coe.tms_payload([1, 0, 0]).hex() == CAPTURED["toDR"]
    assert coe.tms_payload([1, 1, 0]).hex() == CAPTURED["exit"]

# Every opcode in xcvu35p_fsvh2104.bsd that is not on the allowlist (copied from the BSDL).
DANGEROUS = ["001011001011", "010001010001", "110000100100", "110001100100", "110010100100",
             "110100100100", "110011100100", "011001100100", "100100110000", "100100110001",
             "100100110010", "100100110100"]

@pytest.mark.parametrize("op", DANGEROUS)
def test_allowlist_refuses_jprogram_and_fuse_opcodes(op):
    with pytest.raises(coe.IRNotAllowed):
        coe.ir_scan_payload([coe.IR_USER4, int(op, 2)])

def test_allowlist_accepts_exactly_four_opcodes():
    ok = []
    for v in range(4096):
        try:
            coe.ir_scan_payload([v, coe.IR_BYPASS])
            ok.append(v)
        except coe.IRNotAllowed:
            pass
    assert sorted(ok) == sorted(coe.IR_ALLOW)

def test_allowlist_teeth(monkeypatch):
    """The same refusal test must FAIL if the allowlist is disabled."""
    monkeypatch.setattr(coe, "IR_ALLOW", set(range(4096)))
    coe.ir_scan_payload([coe.IR_USER4, int(DANGEROUS[0], 2)])   # no exception now

def test_ir_scan_shifts_the_tdo_side_device_first():
    p = coe.ir_scan_payload([coe.IR_USER4, coe.IR_BYPASS])      # [near TDI, near TDO]
    pairs = p[4:]
    tdi = 0
    for k in range(3):
        tdi |= pairs[2 * k] << (8 * k)
    assert tdi & 0xFFF == coe.IR_BYPASS and (tdi >> 12) & 0xFFF == coe.IR_USER4
    assert pairs[-1] == 0x80                                     # TMS high on bit 23 only

def test_txn_never_sets_bit_15():
    c = coe.CoE.__new__(coe.CoE)
    c.txn = 0x7FFE
    class S:
        def sendall(self, b): self.b = b
    c.s = S()
    seen = [c.send(1) for _ in range(4)]
    assert seen == [0x7FFE, 0x7FFF, 1, 2]
```

`tools/jc/test_coe_load.py` (planning half):

```python
import json, os, sys, zlib, hashlib
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pytest
from jc import coe_load as L, jc_frame as F

def make_manifest(tmp_path, sizes):
    files = []
    off = 0
    for i, n in enumerate(sizes):
        data = bytes((i * 7 + k) & 0xFF for k in range(n))
        p = tmp_path / ("t%d.bin" % i)
        p.write_bytes(data)
        files.append(dict(file=p.name, kind="f32blob", tensor="t%d" % i, nbytes=n,
                          hbm_offset=off, stack=0,
                          blake2b_128=hashlib.blake2b(data, digest_size=16).hexdigest()))
        off += (n + 4095) // 4096 * 4096
    m = dict(format="test", geometry={"rows_if": 48, "axi_dw": 256}, hbm={}, files=files)
    mp = tmp_path / "manifest.json"
    mp.write_text(json.dumps(m))
    return str(mp)

def test_plan_covers_every_byte_once(tmp_path):
    mp = make_manifest(tmp_path, [5000, 64, 4096])
    frames, sha = L.plan_frames(mp)
    data = [f for f in frames if f.kind == "data"]
    assert [f.seq for f in frames] == list(range(len(frames)))
    assert sum(f.n for f in data) == 5000 + 64 + 4096
    assert all(f.n <= F.MAX_PAYLOAD_BYTES and f.addr % 32 == 0 for f in data)
    assert [f for f in frames if f.kind == "range"]               # one per piece, at the end

def test_odd_length_piece_pads_inside_its_own_4k(tmp_path):
    mp = make_manifest(tmp_path, [1000, 64])
    frames, _ = L.plan_frames(mp)
    last0 = max((f for f in frames if f.kind == "data" and f.path.endswith("t0.bin")),
                key=lambda f: f.addr)
    end_padded = last0.addr + (last0.n + 31) // 32 * 32
    assert end_padded <= 4096                                      # never reaches t1 at 4096
    rng = [f for f in frames if f.kind == "range" and f.addr == 0][0]
    assert rng.n == 1024                                           # 1000 rounded up to 32
    assert L.expected_range_crc(rng) == zlib.crc32(open(rng.path, "rb").read() + bytes(24)) & 0xFFFFFFFF

def test_plan_refuses_a_changed_file(tmp_path):
    mp = make_manifest(tmp_path, [64])
    (tmp_path / "t0.bin").write_bytes(b"\xFF" * 64)
    with pytest.raises(L.PlanError):
        L.plan_frames(mp)

def test_plan_sha_changes_with_the_manifest(tmp_path):
    a = make_manifest(tmp_path, [64])
    _, s1 = L.plan_frames(a)
    b = make_manifest(tmp_path, [96])
    _, s2 = L.plan_frames(b)
    assert s1 != s2
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd tools && python3 -m pytest jc/test_coe.py jc/test_coe_load.py -q 2>&1 | tail -3`
Expected: collection errors, `No module named 'jc.coe'`.

- [ ] **Step 3: Implement `tools/jc/coe.py`**

```python
"""Direct SQRL CoE client for the Jungle Cat BMC (no sqrl_bridge).

Protocol: docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md S12.
Only commands observed from the stock bridge are sent. The IR allowlist is the one
guard against shifting JPROGRAM or an eFUSE opcode (xcvu35p_fsvh2104.bsd); keep it.
"""
import socket, struct

IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4 = 0xFFF, 0x249, 0x8A4, 0x8E4
IR_ALLOW = {IR_BYPASS, IR_IDCODE, IR_USER3, IR_USER4}
IR_LEN = 12
CMD_HELLO, CMD_SPEED, CMD_MODE = 0x80001000, 0x8000100C, 0x80001001
CMD_IDCODES, CMD_IRLEN = 0x80001010, 0x80001011
CMD_TMS, CMD_TDI = 0x8000100E, 0x8000100F
STATUS_OK = 0x8000000A
VU35P_X2_IDCODES = bytes.fromhex("9310b7149310b714")

class IRNotAllowed(Exception):
    pass

class CoE:
    def __init__(s, ip, port=21363, timeout=10.0):
        s.s = socket.create_connection((ip, port), timeout=timeout)
        s.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.txn = 1

    def send(s, cmd, payload=b""):
        # txn bit 15 is not a counter bit: txn 0x8000 drew a 4-byte error reply (MEASURED)
        t = s.txn
        s.txn = s.txn + 1 if s.txn < 0x7FFF else 1
        s.s.sendall(struct.pack("<HHI", 8 + len(payload), t, cmd) + payload)
        return t

    def _recv(s, n):
        b = bytearray()
        while len(b) < n:
            c = s.s.recv(n - len(b))
            if not c:
                raise ConnectionError("CoE closed")
            b += c
        return bytes(b)

    def reply(s):
        L, t, st = struct.unpack("<HHI", s._recv(8))
        return t, st, s._recv(L - 8)

    def call(s, cmd, payload=b""):
        t = s.send(cmd, payload)
        while True:
            rt, st, d = s.reply()
            if rt == t:
                return st, d

    def start(s, hz=27_000_000):
        s.call(CMD_HELLO)
        s.call(CMD_SPEED, struct.pack("<II", 0, hz))
        s.call(CMD_MODE, bytes.fromhex("0002"))
        _, ids = s.call(CMD_IDCODES, bytes.fromhex("0000"))
        if ids != VU35P_X2_IDCODES:
            raise RuntimeError("unexpected IDCODEs %s" % ids.hex())
        s.call(CMD_IRLEN, bytes.fromhex("000c0c"))
        s.call(CMD_MODE, bytes.fromhex("0001"))
        return ids

def pair_payload(tdi_bits, tms_bits):
    """0x8000100e body: dev 0, flags 0, count, then (TDI byte, TMS byte) pairs."""
    n = len(tdi_bits)
    out = bytearray(struct.pack("<BBH", 0, 0, n))
    for k in range(0, n, 8):
        m = min(8, n - k)
        out += bytes([sum(tdi_bits[k + j] << j for j in range(m)),
                      sum(tms_bits[k + j] << j for j in range(m))])
    return bytes(out)

def tms_payload(tms_bits):
    return pair_payload([0] * len(tms_bits), tms_bits)

def ir_scan_payload(ops_tdi_to_tdo):
    """IR bits for a chain listed from TDI to TDO. The TDO-side device's opcode is shifted
    first. TMS rises on the last bit (Shift-IR -> Exit1-IR)."""
    for op in ops_tdi_to_tdo:
        if op not in IR_ALLOW:
            raise IRNotAllowed("IR value %#05x is not BYPASS/IDCODE/USER3/USER4" % op)
    bits = []
    for op in reversed(ops_tdi_to_tdo):
        bits += [(op >> i) & 1 for i in range(IR_LEN)]
    tms = [0] * (len(bits) - 1) + [1]
    return pair_payload(bits, tms)

def dr_payload(nbits, tdi):
    return struct.pack("<BBH", 0, 0x20, nbits) + tdi
```

- [ ] **Step 4: Point `coe_stream.py` at the library**

In `hw/jc/xvcstream/coe_stream.py`, replace the local `class CoE`, `tms_payload` and `ir_all_ones_payload` with imports, keeping `main()` unchanged in behaviour:

```python
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tools"))
from jc.coe import CoE, tms_payload, pair_payload

def ir_all_ones_payload(n):
    return pair_payload([1] * n, [0] * (n - 1) + [1])
```

(`ir_all_ones_payload` stays local on purpose: shifting 64 ones is BYPASS on every device and predates the allowlist; it is the measurement tool's own behaviour.) Run `python3 -m py_compile hw/jc/xvcstream/coe_stream.py`; expected: no output.

- [ ] **Step 5: Implement the planning half of `tools/jc/coe_load.py`**

```python
#!/usr/bin/env python3
"""Load a weight image into a Jungle Cat die's HBM over JTAG (plan Tasks 8 and 9).

    coe_load.py load   MANIFEST.json --bmc IP --die A|B --chain AB|BA [--resume]
    coe_load.py verify MANIFEST.json --bmc IP --die A|B --chain AB|BA

Main session only: this opens the board's JTAG. Addresses come only from the manifest,
through fk33_load_weights.pieces_of() (tools/hbm_map.py::file_pieces()).
"""
import collections, hashlib, json, os, sys, zlib
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33", "host"))
from jc import jc_frame as F
import fk33_load_weights as FLW

Frame = collections.namedtuple("Frame", "seq addr path off n kind")

class PlanError(Exception):
    pass

def _entries(mani):
    return list(mani["files"]) + list(FLW.const_entries(mani))

def plan_frames(manifest_path):
    with open(manifest_path) as f:
        mani = json.load(f)
    root = os.path.dirname(os.path.abspath(manifest_path))
    frames, pieces = [], []
    h = hashlib.sha256()
    for e in _entries(mani):
        path = os.path.join(root, e["file"])
        dig = hashlib.blake2b(digest_size=16)
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 24), b""):
                dig.update(chunk)
        if dig.hexdigest() != e["blake2b_128"]:
            raise PlanError("%s hashes to %s, the manifest says %s"
                            % (e["file"], dig.hexdigest(), e["blake2b_128"]))
        for p in FLW.pieces_of(e):
            addr, foff, n = int(p["hbm_offset"]), int(p["file_offset"]), int(p["nbytes"])
            if addr % 32:
                raise PlanError("%s piece at %#x is not 32-byte aligned" % (e["file"], addr))
            pieces.append((addr, path, foff, n))
            h.update(("%s %d %d %d\n" % (e["file"], addr, foff, n)).encode())
    pieces.sort()
    for (a0, _, _, n0), (a1, _, _, _) in zip(pieces, pieces[1:]):
        if a0 + (n0 + 31) // 32 * 32 > a1:
            raise PlanError("pieces overlap after padding: %#x+%d reaches %#x" % (a0, n0, a1))
    seq = 0
    for addr, path, foff, n in pieces:
        k = 0
        while k < n:
            m = min(F.MAX_PAYLOAD_BYTES, n - k)
            frames.append(Frame(seq, addr + k, path, foff + k, m, "data")); seq += 1
            k += m
    for addr, path, foff, n in pieces:
        frames.append(Frame(seq, addr, path, foff, (n + 31) // 32 * 32, "range")); seq += 1
    return frames, h.hexdigest()

def read_payload(fr):
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        return fh.read(fr.n)

def expected_range_crc(fr):
    """CRC over the piece's bytes padded with zeros to the frame's 32-byte length."""
    with open(fr.path, "rb") as fh:
        fh.seek(fr.off)
        raw = fh.read(fr.n)
    return zlib.crc32(raw.ljust(fr.n, b"\0")) & 0xFFFFFFFF
```

Note for the implementer: a range frame's `n` is the padded length, so `read_payload` must not be used on it (the file may be shorter); `expected_range_crc` reads what exists and pads. The test's 1,000-byte file therefore gives `n == 1024` and 24 zero bytes of padding.

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd tools && python3 -m pytest jc/test_coe.py jc/test_coe_load.py -q 2>&1 | tail -3`
Expected: `21 passed` (17 in `test_coe.py`, 12 of them the parametrized refusals, plus 4 planning tests).

- [ ] **Step 7: Commit**

```bash
git add tools/jc/coe.py tools/jc/test_coe.py tools/jc/coe_load.py tools/jc/test_coe_load.py hw/jc/xvcstream/coe_stream.py
git commit -m "jc loader host: CoE client library with IR allowlist, manifest frame planner"
```

---

### Task 9: Pipelined load with resync, completion, resume and verify

**Files:**
- Modify: `tools/jc/coe_load.py` (transport, `Loader`, CLI)
- Modify: `tools/jc/test_coe_load.py` (fake-transport tests)

**Interfaces:**
- Consumes: Task 8's `plan_frames`, `read_payload`, `expected_range_crc`, `coe.*`; Task 2's `LoaderModel`, `F.*`.
- Produces: `class CoeTransport(ip, die, chain, hz=27_000_000)` and `class FakeTransport(model, lead, lag_slots=2, fail_seqs=(), drop_after=None)`, both with `open_scan()`, `send(slot: bytes)`, `recv() -> bytes` (TDO of the oldest outstanding command), `close_scan()`, `depth: int`, `status_offset: int`; `class Loader(transport, frames, plan_sha, ckpt_path)` with `run_load() -> dict` (final status), `run_verify() -> list[(Frame, got, want)]` (mismatches), `class LoadAborted(Exception)`.

- [ ] **Step 1: Write the failing tests**

Append to `tools/jc/test_coe_load.py`:

```python
from jc.jc_model import LoaderModel

def plan(tmp_path, sizes=(5000, 64, 4096)):
    return L.plan_frames(make_manifest(tmp_path, list(sizes)))

def test_clean_load_matches_the_file_bytes(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t = L.FakeTransport(m, lead=1)
    st = L.Loader(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert st["last"] == frames[-1].seq and st["busy"] == 0
    for fr in (f for f in frames if f.kind == "data"):
        raw = L.read_payload(fr)
        for k in range(0, fr.n, 32):
            assert m.mem[fr.addr + k] == raw[k:k + 32].ljust(32, b"\0")

def test_resync_after_crc_failure_with_pipeline(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    t = L.FakeTransport(m, lead=0, fail_seqs={2})
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    st = ld.run_load()
    assert st["last"] == frames[-1].seq
    assert ld.resyncs == 1 and st["crc_fail"] == 1

def test_completion_waits_for_status(tmp_path):
    frames, sha = plan(tmp_path, (64,))
    t = L.FakeTransport(LoaderModel(), lead=1, lag_slots=4)
    st = L.Loader(t, frames, sha, str(tmp_path / "ck.json")).run_load()
    assert st["last"] == frames[-1].seq and st["busy"] == 0

def test_wrong_chain_position_aborts_fast(tmp_path):
    frames, sha = plan(tmp_path)
    t = L.FakeTransport(LoaderModel(), lead=1, wrong_lead=True)
    ld = L.Loader(t, frames, sha, str(tmp_path / "ck.json"))
    with pytest.raises(L.LoadAborted, match="chain"):
        ld.run_load()
    assert t.sent < 64

def test_resume_continues_from_fpga_status(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    t = L.FakeTransport(m, lead=1, drop_after=5)
    with pytest.raises(ConnectionError):
        L.Loader(t, frames, sha, ck).run_load()
    committed = m.last
    t2 = L.FakeTransport(m, lead=1)
    st = L.Loader(t2, frames, sha, ck, resume=True).run_load()
    assert st["last"] == frames[-1].seq
    assert t2.first_seq_sent == committed + 1

def test_resume_refuses_other_plan(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ck = str(tmp_path / "ck.json")
    t = L.FakeTransport(m, lead=1, drop_after=5)
    with pytest.raises(ConnectionError):
        L.Loader(t, frames, sha, ck).run_load()
    with pytest.raises(L.LoadAborted, match="plan"):
        L.Loader(L.FakeTransport(m, lead=1), frames, "0" * 64, ck, resume=True).run_load()

def test_verify_reports_a_corrupted_word(tmp_path):
    frames, sha = plan(tmp_path)
    m = LoaderModel()
    ld = L.Loader(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck.json"))
    ld.run_load()
    m.mem[0x40] = b"\xEE" * 32
    bad = L.Loader(L.FakeTransport(m, lead=1), frames, sha, str(tmp_path / "ck2.json")).run_verify()
    assert len(bad) == 1 and bad[0][0].addr == 0
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd tools && python3 -m pytest jc/test_coe_load.py -q 2>&1 | tail -3`
Expected: 7 failures with `AttributeError: module 'jc.coe_load' has no attribute 'FakeTransport'`.

- [ ] **Step 3: Implement the transports and the loader**

Append to `tools/jc/coe_load.py`:

```python
import time
from jc import coe

FILLER_BITS = F.SLOT_BITS
MAX_RESYNCS = 8
MAX_POLLS = 32

class LoadAborted(Exception):
    pass

class FakeTransport:
    """The loader's view of the board, backed by LoaderModel. Models the chain lead bit,
    status lag (status reflects the model `lag_slots` slots ago), injected CRC faults,
    a wrong chain setting, and a dropped connection."""
    def __init__(s, model, lead, lag_slots=2, fail_seqs=(), drop_after=None, wrong_lead=False):
        s.m, s.lead, s.lag = model, lead, lag_slots
        s.fail = set(fail_seqs); s.drop_after = drop_after; s.wrong = wrong_lead
        s.depth, s.status_offset = 4, 1
        s.hist, s.out, s.sent, s.first_seq_sent = [], [], 0, None
        s.misaligned = False
    def open_scan(s):
        s.misaligned = s.wrong
        s.m.feed(bytes(F.SLOT_BYTES))                          # the filler is one desync
    def send(s, slot):
        if s.drop_after is not None and s.sent >= s.drop_after:
            raise ConnectionError("fake link dropped")
        h = F.parse_header(slot)
        real = h["magic"] == F.MAGIC_FRAME and (h["nwords"] or h["flags"])
        if s.first_seq_sent is None and real:
            s.first_seq_sent = h["seq"]
        if s.misaligned:
            # wrong chain position: the loader sees garbage and TDO carries no status
            s.m.feed(bytes(F.SLOT_BYTES))
            s.out.append(bytes(F.SLOT_BYTES)); s.sent += 1
            return
        if h["seq"] in s.fail and real:
            s.fail.discard(h["seq"])
            b = bytearray(slot); b[100] ^= 1; slot = bytes(b)
        s.hist.append(dict(s.m.status()))
        s.m.feed(slot)
        st = s.hist[max(0, len(s.hist) - 1 - s.lag)]
        tdo = bytearray(F.SLOT_BYTES)
        v = int.from_bytes(F.pack_status(st), "little") << s.status_offset
        tdo[:33] = v.to_bytes(33, "little")
        s.out.append(bytes(tdo)); s.sent += 1
    def recv(s):
        return s.out.pop(0)
    def close_scan(s):
        pass

class CoeTransport:
    """The real board. `chain` lists dies from TDI to TDO ("AB" or "BA"); `die` is the
    target. Main session only."""
    def __init__(s, ip, die, chain, hz=27_000_000):
        if sorted(chain) != ["A", "B"] or die not in chain:
            raise ValueError("chain must be AB or BA and contain the die")
        s.c = coe.CoE(ip)
        s.c.start(hz)
        pos = chain.index(die)
        s.ops = [coe.IR_USER4 if d == die else coe.IR_BYPASS for d in chain]
        s.lead = pos                       # BYPASS devices nearer TDI delay the data
        s.tdo_delay = len(chain) - 1 - pos # BYPASS devices nearer TDO delay the status
        s.status_offset = s.lead + s.tdo_delay
        s.depth = 4
        s.pending = []
    def open_scan(s):
        s.c.call(coe.CMD_TMS, coe.tms_payload([1, 1, 1, 1, 1, 0]))
        s.c.call(coe.CMD_TMS, coe.tms_payload([1, 1, 0, 0]))
        s.c.call(coe.CMD_TMS, coe.ir_scan_payload(s.ops))
        s.c.call(coe.CMD_TMS, coe.tms_payload([1, 0]))
        s.c.call(coe.CMD_TMS, coe.tms_payload([1, 0, 0]))      # Capture-DR, Shift-DR
        n = FILLER_BITS - s.lead
        s.c.call(coe.CMD_TDI, coe.dr_payload(n, bytes((n + 7) // 8)))
    def send(s, slot):
        s.pending.append(s.c.send(coe.CMD_TDI, coe.dr_payload(F.SLOT_BITS, slot)))
    def recv(s):
        t = s.pending.pop(0)
        rt, st, d = s.c.reply()
        if rt != t or st != coe.STATUS_OK or len(d) != F.SLOT_BYTES:
            raise ConnectionError("CoE reply txn %d status %#x len %d (expected txn %d)"
                                  % (rt, st, len(d), t))
        return d
    def close_scan(s):
        while s.pending:
            s.recv()
        s.c.call(coe.CMD_TMS, coe.tms_payload([1, 1, 0]))      # Exit1, Update, RTI

def status_of(tdo, offset):
    v = int.from_bytes(tdo[:40], "little") >> offset
    return F.parse_status((v & ((1 << 256) - 1)).to_bytes(32, "little"))

class Loader:
    def __init__(s, t, frames, plan_sha, ckpt_path, resume=False):
        s.t, s.frames, s.sha, s.ckpt, s.resume = t, frames, plan_sha, ckpt_path, resume
        s.resyncs = 0
        s.st = None

    def _slot(s, fr):
        if fr.kind == "range":
            return F.range_crc_slot(fr.seq, fr.addr, fr.n)
        return F.build_slot(fr.seq, fr.addr, read_payload(fr))

    def _take(s):
        st = status_of(s.t.recv(), s.t.status_offset)
        if st["magic"] == F.MAGIC_STAT:
            s.st = st
        return st

    def _poll_settled(s):
        """Send polls until two consecutive good statuses agree and the loader is idle."""
        prev = None
        for _ in range(MAX_POLLS):
            s.t.send(F.poll_slot())
            st = s._take()
            if st["magic"] != F.MAGIC_STAT:
                prev = None
                continue
            if prev == st and st["busy"] == 0:
                return st
            prev = st
        raise LoadAborted("status never settled: check --chain (die position on the JTAG chain)")

    def _check_ckpt(s):
        if os.path.exists(s.ckpt):
            with open(s.ckpt) as f:
                ck = json.load(f)
            if ck["plan_sha"] != s.sha:
                raise LoadAborted("the checkpoint is for a different plan (%s); reload the "
                                  "bitstream to start over" % ck["plan_sha"][:12])
        elif s.resume:
            raise LoadAborted("--resume given but no checkpoint at %s" % s.ckpt)

    def _save_ckpt(s):
        with open(s.ckpt, "w") as f:
            json.dump(dict(plan_sha=s.sha, last=s.st["last"] if s.st else None), f)

    def run_load(s):
        s._check_ckpt()
        s.t.open_scan()
        st = s._poll_settled()
        if st["last"] != 0xFFFFFFFF and not s.resume:
            raise LoadAborted("the die already holds frames up to seq %d; use --resume with "
                              "the same plan, or reload the bitstream" % st["last"])
        base_err = (st["crc_fail"], st["seq_err"], st["desync"])
        nxt = (st["last"] + 1) & 0xFFFFFFFF
        s._save_ckpt()
        inflight, stalls = 0, 0
        data_end = len(s.frames)
        while True:
            while nxt < data_end and inflight < s.t.depth:
                s.t.send(s._slot(s.frames[nxt])); nxt += 1; inflight += 1
            if inflight == 0:
                st = s._poll_settled()
                if st["last"] == s.frames[-1].seq:
                    s._save_ckpt()
                    s.t.close_scan()
                    return st
                nxt = (st["last"] + 1) & 0xFFFFFFFF           # tail lost: resend
                continue
            st = s._take(); inflight -= 1
            if st["magic"] != F.MAGIC_STAT:
                stalls += 1
                if stalls > 2 * s.t.depth + 4:
                    raise LoadAborted("no valid status for %d slots: check --chain" % stalls)
                continue
            stalls = 0
            err = (st["crc_fail"], st["seq_err"], st["desync"])
            if err != base_err:
                while inflight:
                    s._take(); inflight -= 1
                s.resyncs += 1
                if s.resyncs > MAX_RESYNCS:
                    raise LoadAborted("%d resyncs, giving up at seq %d" % (s.resyncs, st["last"]))
                s.t.close_scan(); s.t.open_scan()
                st = s._poll_settled()
                base_err = (st["crc_fail"], st["seq_err"], st["desync"])
                nxt = (st["last"] + 1) & 0xFFFFFFFF
            if st["committed"] % 1000 == 0:
                s._save_ckpt()

    def run_verify(s):
        """Range-CRC every piece again (fresh seqs continue after the die's last)."""
        s.t.open_scan()
        st = s._poll_settled()
        seq = (st["last"] + 1) & 0xFFFFFFFF
        bad = []
        for fr in (f for f in s.frames if f.kind == "range"):
            s.t.send(F.range_crc_slot(seq, fr.addr, fr.n)); s._take()
            st = s._poll_settled()
            if st["range_seq"] != seq or not st["range_valid"]:
                raise LoadAborted("range CRC for seq %d never reported" % seq)
            want = expected_range_crc(fr)
            if st["range_crc"] != want:
                bad.append((fr, st["range_crc"], want))
            seq += 1
        s.t.close_scan()
        return bad

def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["load", "verify"])
    ap.add_argument("manifest")
    ap.add_argument("--bmc", required=True)
    ap.add_argument("--die", required=True, choices=["A", "B"])
    ap.add_argument("--chain", required=True, choices=["AB", "BA"])
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--ckpt", default=None)
    a = ap.parse_args(argv)
    frames, sha = plan_frames(a.manifest)
    ck = a.ckpt or "/mnt/storage/fk33_builds/jc_load/%s_%s.json" % (sha[:12], a.die)
    os.makedirs(os.path.dirname(ck), exist_ok=True)
    t = CoeTransport(a.bmc, a.die, a.chain)
    ld = Loader(t, frames, sha, ck, resume=a.resume)
    t0 = time.time()
    if a.cmd == "load":
        st = ld.run_load()
        n = sum(f.n for f in frames if f.kind == "data")
        dt = time.time() - t0
        print("JCLOAD_DONE last=%d committed=%d crc_fail=%d resyncs=%d %.0f s %.2f MB/s"
              % (st["last"], st["committed"], st["crc_fail"], ld.resyncs, dt, n / dt / 1e6))
    else:
        bad = ld.run_verify()
        for fr, got, want in bad[:20]:
            print("JCVERIFY_BAD addr=%#x n=%d got=%08x want=%08x" % (fr.addr, fr.n, got, want))
        print("JCVERIFY_%s %d pieces, %d bad" % ("PASS" if not bad else "FAIL",
              sum(1 for f in frames if f.kind == "range"), len(bad)))
        return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
```

Implementer notes: (a) `run_load` sends the range frames too (they are in `frames` after the data frames), so a finished load already carries one range check per piece; `run_verify` is the separate re-check. (b) The fake's `first_seq_sent` records the first frame that carries data or a range request, which is what the resume test asserts. If a test fails on that bookkeeping rather than on the loader's behaviour, fix the fake, not the assertion. (c) Keep `MAX_POLLS` and the stall limit small enough that `test_wrong_chain_position_aborts_fast` sees fewer than 64 slots.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd tools && python3 -m pytest jc/ -q 2>&1 | tail -3`
Expected: all tests in `tools/jc/` pass (8 + 21 + 7 = 36).

- [ ] **Step 5: Run the project's Python tests**

Run: `cd tools && python3 -m pytest -q 2>&1 | tail -3`
Expected: no new failures. Any pre-existing failure is reported by name in the task report.

- [ ] **Step 6: Commit**

```bash
git add tools/jc/coe_load.py tools/jc/test_coe_load.py
git commit -m "jc loader host: pipelined load with resync, settled-status completion, resume and range-CRC verify"
```

---

### Task 10: BSCANE2 wrapper, top, OOC route and bitstream

**Files:**
- Create: `hw/jc/loader/rtl/jc_frame_rx.vhd`, `hw/jc/loader/rtl/jc_loader_top.vhd`
- Create: `hw/jc/loader/jc_loader_bd.tcl`, `hw/jc/loader/jc_loader.xdc`, `hw/jc/loader/build_loader.tcl`, `hw/jc/loader/ooc_loader_core.tcl`, `hw/jc/loader/README.md`

**Interfaces:**
- Consumes: `jc_loader_core` (Task 6); the BD shape of `hw/jc/axiprobe/jc_axiprobe_bd.tcl` (jtag_axi) and the FK33 HBM clocking in `hw/fk33/gen_pcieep.py` (clk_wiz output feeding `HBM_REF_CLK_0/1` and `APB_0_PCLK`).
- Produces: `/mnt/storage/fk33_builds/jc_loader/jc_loader.bit` and `.ltx`, an OOC route report for `jc_loader_core` at 200 MHz, and the `JTAG_CHAIN` census.

- [ ] **Step 1: Write the wrapper**

`hw/jc/loader/rtl/jc_frame_rx.vhd`:

```vhdl
-- BSCANE2 (USER4) around jc_frame_core. Synthesis only: GHDL benches drive the core.
library ieee;
use ieee.std_logic_1164.all;
library unisim;
use unisim.vcomponents.all;

entity jc_frame_rx is
  port(
    tck_o, sel_o, capture_o, shift_o, tdi_o : out std_logic;
    tdo_i : in std_logic
  );
end entity;

architecture rtl of jc_frame_rx is
  signal tck_raw : std_logic;
begin
  bs : BSCANE2
    generic map(JTAG_CHAIN => 4)
    port map(CAPTURE => capture_o, DRCK => open, RESET => open, RUNTEST => open,
             SEL => sel_o, SHIFT => shift_o, TCK => tck_raw, TDI => tdi_o, TMS => open,
             UPDATE => open, TDO => tdo_i);
  bufg_tck : BUFG port map(I => tck_raw, O => tck_o);
end architecture;
```

- [ ] **Step 2: Write the top**

`hw/jc/loader/rtl/jc_loader_top.vhd` instantiates `jc_frame_rx` and `jc_loader_core` and exposes the AXI3 master as ports for the block design (`std_logic`/`std_logic_vector` only, per `hw/fk33/CLAUDE.md`):

```vhdl
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jc_loader_top is
  port(
    aclk, arst, hbm_cat_trip : in std_logic;
    m_awaddr  : out std_logic_vector(32 downto 0);
    m_awlen   : out std_logic_vector(3 downto 0);
    m_awsize  : out std_logic_vector(2 downto 0);
    m_awburst : out std_logic_vector(1 downto 0);
    m_awvalid : out std_logic;
    m_awready : in  std_logic;
    m_wdata   : out std_logic_vector(255 downto 0);
    m_wstrb   : out std_logic_vector(31 downto 0);
    m_wlast   : out std_logic;
    m_wvalid  : out std_logic;
    m_wready  : in  std_logic;
    m_bresp   : in  std_logic_vector(1 downto 0);
    m_bvalid  : in  std_logic;
    m_bready  : out std_logic;
    m_araddr  : out std_logic_vector(32 downto 0);
    m_arlen   : out std_logic_vector(3 downto 0);
    m_arsize  : out std_logic_vector(2 downto 0);
    m_arburst : out std_logic_vector(1 downto 0);
    m_arvalid : out std_logic;
    m_arready : in  std_logic;
    m_rdata   : in  std_logic_vector(255 downto 0);
    m_rresp   : in  std_logic_vector(1 downto 0);
    m_rlast   : in  std_logic;
    m_rvalid  : in  std_logic;
    m_rready  : out std_logic
  );
end entity;

architecture rtl of jc_loader_top is
  signal tck, sel, capture, shift, tdi, tdo : std_logic;
begin
  bs : entity work.jc_frame_rx
    port map(tck_o => tck, sel_o => sel, capture_o => capture, shift_o => shift,
             tdi_o => tdi, tdo_i => tdo);
  core : entity work.jc_loader_core
    generic map(ADDR_W => 33)
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, aclk => aclk, arst => arst, hbm_cat_trip => hbm_cat_trip,
             m_awaddr => m_awaddr, m_awlen => m_awlen, m_awsize => m_awsize,
             m_awburst => m_awburst, m_awvalid => m_awvalid, m_awready => m_awready,
             m_wdata => m_wdata, m_wstrb => m_wstrb, m_wlast => m_wlast,
             m_wvalid => m_wvalid, m_wready => m_wready, m_bresp => m_bresp,
             m_bvalid => m_bvalid, m_bready => m_bready, m_araddr => m_araddr,
             m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
             m_arvalid => m_arvalid, m_arready => m_arready, m_rdata => m_rdata,
             m_rresp => m_rresp, m_rlast => m_rlast, m_rvalid => m_rvalid,
             m_rready => m_rready);
end architecture;
```

- [ ] **Step 3: OOC synthesis and route of `jc_loader_core` at 200 MHz (BC-250 lane)**

`hw/jc/loader/ooc_loader_core.tcl`:

```tcl
# OOC synth + place + route of jc_loader_core on the VU35P at 200 MHz aclk, 27 MHz TCK.
# Usage: vivado -mode batch -source ooc_loader_core.tcl -tclargs <repo> <outdir>
set repo [lindex $argv 0]; set out [lindex $argv 1]
file mkdir $out
create_project -in_memory -part xcvu35p-fsvh2104-2-e
foreach f {rtl/jc_loader_pkg.vhd rtl/async_fifo.vhd rtl/jc_frame_core.vhd rtl/jc_hbm_writer.vhd
           rtl/jc_hbm_crc.vhd rtl/jc_status_sync.vhd rtl/jc_loader_core.vhd} {
  read_vhdl -vhdl2008 $repo/$f
}
synth_design -top jc_loader_core -mode out_of_context
create_clock -name aclk -period 5.000 [get_ports aclk]
create_clock -name tck -period 37.037 [get_ports tck]
set_clock_groups -asynchronous -group aclk -group tck
opt_design
place_design
route_design
report_utilization -file $out/util_routed.rpt
report_timing_summary -file $out/timing_routed.rpt
report_cdc -file $out/cdc.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "OOC_LOADER_ROUTE WNS $wns"
```

Run on the BC-250 (resolve its address first; sync; cap at `MemoryHigh=11G` through a wrapper FILE, per CLAUDE.md):

```bash
ssh labuser@192.0.2.1 "grep -i cachyos /var/lib/misc/dnsmasq.leases"
bash ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh
```

Then on the BC-250: `systemd-run --user --scope -p MemoryHigh=11G /tools/Xilinx/2023.2/Vivado/2023.2/bin/vivado -mode batch -source hw/jc/loader/ooc_loader_core.tcl -tclargs ~/GitHub/llama.vhdl /home/orencollaco/jcl_ooc` and gate on the anchored sentinel: `grep -E '^OOC_LOADER_ROUTE WNS' vivado.log`.
Expected: `OOC_LOADER_ROUTE WNS` non-negative. `report_cdc` shows only the `async_fifo` gray pointers and the `jc_status_sync` toggle/snapshot paths (all behind `ASYNC_REG` flops). Record LUT/FF/BRAM from `util_routed.rpt`.

- [ ] **Step 4: Block design, XDC and bitstream build**

`hw/jc/loader/jc_loader_bd.tcl` builds, in this order, using `hw/jc/axiprobe/jc_axiprobe_bd.tcl` as the style reference:
1. `util_ds_buf` (IBUFDS) on `sysclk_clk_p/n` (BC26, 200 MHz LVDS).
2. `clk_wiz` with `clk_out1` 200 MHz (aclk) and `clk_out2` 100 MHz (HBM_REF_CLK_0/1 and APB_0_PCLK), `locked` into a `proc_sys_reset` for aclk.
3. `hbm` IP (`xilinx.com:ip:hbm`), both stacks, `USER_SWITCH_ENABLE_00/01 = TRUE` (global addressing), one AXI port enabled (`AXI_00`), clocked by aclk; `DRAM_*_STAT_CATTRIP` ORed into `hbm_cat_trip`.
4. `jc_loader_top` as a module reference, its `m_*` ports connected to `SAXI_00` (`m_awaddr` to `AXI_00_AWADDR`, the rest by name; AXI3 has no `AWLOCK/AWCACHE/AWPROT` beyond tie-offs the IP needs at their defaults).
5. The existing probe's `jtag_axi` + `axi_bram_ctrl` + 8 KB BRAM at `0xC0000000` stays as it is in the axiprobe build (the independent readback path), plus a second `jtag_axi` master into the HBM's `SAXI_01` for Task 11's spot checks.

`hw/jc/loader/jc_loader.xdc`:

```tcl
set_property PACKAGE_PIN BC26 [get_ports sysclk_clk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_clk_p]
set_property DQS_BIAS TRUE [get_ports sysclk_clk_p]
create_clock -name sysclk -period 5.000 [get_ports sysclk_clk_p]
create_clock -name tck_user4 -period 37.037 [get_pins -hier -filter {NAME =~ *bs/bs/TCK}]
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sysclk] -group [get_clocks tck_user4]
```

`hw/jc/loader/build_loader.tcl` mirrors `hw/jc/axiprobe/build_axiprobe.tcl` (project under the build root, `synth_1`/`impl_1`, `write_bitstream`, `write_debug_probes`), prints the anchored sentinels `JCLOADER_BIT <path>` and `JCLOADER_DONE`, and before `write_bitstream` prints the BSCAN census:

```tcl
foreach c [get_cells -hier -filter {REF_NAME == BSCANE2}] {
  puts "JCLOADER_BSCAN $c JTAG_CHAIN=[get_property JTAG_CHAIN $c]"
}
```

Run on the BC-250 under `MemoryHigh=11G` with `BUILD_ROOT=/mnt/storage/...` replaced by the BC-250's own storage path, or on the workstation alone (one Vivado per box): `vivado -mode batch -source hw/jc/loader/build_loader.tcl -tclargs /mnt/storage/fk33_builds/jc_loader xcvu35p-fsvh2104-1-e` (the part the census and probe were built for).
Expected: `^JCLOADER_DONE`; exactly two `JCLOADER_BSCAN` lines for the debug hub and one for the loader with `JTAG_CHAIN=4`, and the hub's value is NOT 4. If the hub also says 4, set the hub's `C_USER_SCAN_CHAIN` to 1 or 2 in the BD and rebuild. Routed timing met (`WNS >= 0`). Copy the `.bit`, `.ltx`, the timing summary and the BSCAN census into `hw/jc/loader/results/<date>/` as soon as the sentinel appears.

- [ ] **Step 5: Commit**

```bash
git add hw/jc/loader/rtl/jc_frame_rx.vhd hw/jc/loader/rtl/jc_loader_top.vhd hw/jc/loader/jc_loader_bd.tcl hw/jc/loader/jc_loader.xdc hw/jc/loader/build_loader.tcl hw/jc/loader/ooc_loader_core.tcl hw/jc/loader/README.md hw/jc/loader/results
git commit -m "jc loader: BSCANE2 USER4 wrapper, top, block design, OOC route and bitstream"
```

---

### Task 11: Silicon bring-up (MAIN SESSION ONLY, never a subagent)

**Files:**
- Modify: `docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md` (append a dated section with raw output)
- Create: `tools/jc/spot_check.tcl` (JTAG-AXI readback of random windows)

**Interfaces:**
- Consumes: the Task 10 bitstream, `tools/jc/coe_load.py`, the BC-250 network set-up recorded in the WORKLOG (dnsmasq on `enp4s0`; not persistent across a reboot).

- [ ] **Step 1: Load the bitstream on both dies**

On the BC-250: stop any bridge by `/proc/PID/exe`, then `./sqrl_bridge_tck27 C<bmc> jc_loader.bit,jc_loader.bit skip 2542`. Read the log for `Bitstream Loaded` on devices 0 and 1, then stop the bridge again (the direct client needs the BMC socket).

- [ ] **Step 2: Find the chain order**

Run `python3 tools/jc/coe_load.py verify <a tiny test manifest> --bmc <ip> --die A --chain AB` with a manifest of one 64-byte file. If it aborts with "status never settled: check --chain", run it with `--chain BA`. The setting that returns valid status is the chain order; record it in the WORKLOG and in `hw/jc/loader/README.md`.

- [ ] **Step 3: 100 MB random load and range CRC**

Generate a 100 MB random file and a one-file manifest for it at a scratch HBM range (`hbm_offset` 0x1_8000_0000), then `coe_load.py load` and `coe_load.py verify`.
Expected: `JCLOAD_DONE ... crc_fail=0 resyncs=0`, about 2.6 MB/s, and `JCVERIFY_PASS`.

- [ ] **Step 4: Independent oracle through JTAG-AXI**

`tools/jc/spot_check.tcl` opens the hardware target over XVC (restart the bridge with XVC), reads 1,000 random 256-byte windows of the 100 MB range through the second `jtag_axi` master (`SAXI_01`), and prints `SPOT <addr> <hex>`; a Python step compares each window against the source file.
Expected: 1,000 of 1,000 windows match. This path shares nothing with the loader: different BSCAN chain, different AXI master, different HBM port.

- [ ] **Step 5: Fault injection on silicon**

Run the load with `FakeTransport`-style corruption applied to the real transport for one seq (add a `--corrupt-seq N` debug flag to `coe_load.py` that flips one payload bit of that frame on its first send). Expected: status shows one CRC failure, `resyncs=1`, the load completes, `JCVERIFY_PASS`.

- [ ] **Step 6: Card 0's 27B image to die A, timed**

`coe_load.py load /mnt/storage/llama-models/qwen38-27b-card0-b0-32/manifest.json --bmc <ip> --die A --chain <order>` then `verify`, then a spot check of 1,000 random windows inside random pieces against the files.
Expected: about 46 minutes, `JCVERIFY_PASS`, 1,000 of 1,000 windows match.

- [ ] **Step 7: Card 1's image to die B**

Same with `qwen38-27b-card1-b33-63` and `--die B`.

- [ ] **Step 8: Write it up and commit**

Append a dated section to the debugging doc with the raw `JCLOAD_DONE` / `JCVERIFY_*` / spot-check lines, the chain order, the measured MB/s, and any trap hit. Update `docs/WORKLOG.md`'s current state.

```bash
git add tools/jc/spot_check.tcl tools/jc/coe_load.py docs/debugging/2026-10-05_jc-jtag-axi-host-path-is-latency-bound.md docs/WORKLOG.md hw/jc/loader/README.md
git commit -m "jc loader on silicon: 27B images loaded and verified on both dies"
```
