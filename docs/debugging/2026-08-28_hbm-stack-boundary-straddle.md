# One packed tensor straddles the FK33's 4 GiB HBM stack boundary

**Date:** 2026-08-28. Branch `fpga`. Track HBM-PLACE.
**Card:** SQRL FK33, `xcvu33p-fsvh2104-2L-e`, 8 GiB HBM as **two 4 GiB stacks**.
**Set under test:** `/mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json`,
250 packed tensors + 1 F32 side blob, `ROWS_IF=48 AXI_DW=256 BLK=32`,
27 AXI read masters. **No hardware was touched.**

**The question, verbatim** (from `docs/2026-08-28_token-io-path.md` section 7.3,
raised there and left for the packer's owner):

> `blk.7.ffn_gate.weight` straddles the 4 GiB HBM stack boundary by 479,232
> bytes (occupies 4,267,130,880 .. 4,295,446,528; the boundary is at
> 4,294,967,296). Confirm it, find every instance, establish what the hardware
> does at the boundary, and fix the packer's placement.

Labels: **MEASURED** (a named tool ran), **DERIVED** (arithmetic shown),
**ESTIMATE** (a judgement with its assumption).

---

## 1. The answer, up front

**TOKEN-IO's arithmetic is right, and it is the only instance.** MEASURED by
two independent walks of the manifest: exactly **one** file crosses the
boundary, `blk.7.ffn_gate.weight.mv4i`, and exactly **one** of its 27
sub-regions does, the last scale sub-region `s2`. 479,232 bytes are on the
wrong side. No other tensor, no other sub-region, no F32 side-blob entry, and
neither the GDN state region nor the KV region crosses.

**What the hardware does: it does not fault, and it probably does not alias
either. The read decodes and completes.** With `HBMGlobalSwitch 1` (which is
what every build in this repo sets), the HBM IP exposes **all 32
pseudo-channel segments on every one of the 32 SAXI ports**, i.e. the whole
8 GiB, cross-stack included -- MEASURED from the IP in
`docs/2026-08-28_can-27-read-masters-be-served.md` section 2.1. The stack rule
is therefore a **discipline the build imposes**, not a property of the silicon,
and the residency map's reason for it ("no cross-stack path") is wrong. Section 3
separates what is enforced from what is convention.

**The fix is a stack-aware allocator in `tools/pack_model_fk33.py`.** Rule: no
placed object may contain a stack boundary strictly inside it; when one would,
the allocator skips to the boundary and records the hole. Cost: **one hole of
27,836,416 B (26.548 MiB)**, 0.324% of HBM, which moves the KV budget from
3.2200 GiB to 3.1941 GiB and the context ceiling from **52,756 to 52,331
tokens, minus 425 (0.81%)**. Everything still fits; nothing had to be dropped.

**Verified two ways.** `tools/check_hbm_stack.py` re-derives every byte range
from the emitted **file headers** rather than from the packer's arithmetic. It
**FAILs the old manifest** (2 ranges) and **PASSes the new** one, on the same
7,182 ranges, and 10 of 11 mutants kill it.

---

## 2. The procedure, in the order it was run

Each step is here because it isolates something the previous one could not.

1. **Enumerate crossings from the manifest plus `packed_layout`.**
   `scratchpad/enum.py`. Walks all 251 files; for each `.mv4i` reconstructs the
   header + 24 weight + 3 scale sub-regions from `pack_int4.packed_layout`, for
   the blob the 177 entries, and tests `base // 4GiB != (base+n-1) // 4GiB`.
   Isolates: **how many** instances there are, at file and at sub-region
   granularity, which the single tensor named in the report did not settle.
2. **Establish the hardware behaviour from the IP and the build scripts, not
   from the residency map.** Section 3. Isolates: whether this is a
   wrong-answer defect or a bandwidth defect. The two call for different fixes.
3. **Implement the allocator and assert the rule in the packer.** Section 4.
4. **Re-derive every range independently and re-run on BOTH manifests.**
   `tools/check_hbm_stack.py`, which shares no code with the allocator and
   reads the sub-region base table out of each file's own 4 KiB header
   (spec 6.4 offsets 0x1A, 0x30, 0x34, 0x38). Isolates: whether the allocator
   and its own assertion are merely agreeing with each other.
5. **Mutate the checker's input 11 ways.** Section 6. Isolates the checker's
   resolution floor, including the one case where a whole file crosses but no
   sub-region does.

---

## 3. What the hardware actually does at the boundary

**Enforcement, with citations.**

| mechanism | what it does | enforced or convention |
|---|---|---|
| HBM IP switch decode, `USER_SWITCH_ENABLE_00/01 = TRUE` | every SAXI port exposes all 32 `HBM_MEM` segments = the whole 8 GiB | **the decode PERMITS cross-stack.** MEASURED, `can-27-read-masters` 2.1, from `get_bd_addr_segs hbm/SAXI_nn/*` on `SAXI_00`, `SAXI_01`, `SAXI_17` |
| `pcie2hbm` SmartConnect (`build_fk33_pcieep.tcl:265-270`), `NUM_SI 2 / NUM_MI 2` | the host's `xdma/M_AXI` and `jtag_hbm` reach `SAXI_00` for stack 0 and `SAXI_16` for stack 1, with the cross-stack halves `exclude_bd_addr_seg`'d (`:941-972`) | **ENFORCED.** There is a real decoder in the path, so an excluded address DECERRs. This is also why the host DMA writes the packed set to the correct stack regardless of layout |
| `assign_bd_address` / `exclude_bd_addr_seg` on ENGINE ports | `gen_hbmbw.py:344-350` gives each generator only its own stack's 16 segments | **CONVENTION.** The generators connect DIRECTLY to the HBM IP (`build_fk33_hbmbw.tcl:443` `connect_bd_intf_net tg/m00_axi hbm/SAXI_01`), with no interconnect between, so nothing in the fabric decodes. The assignment constrains Vivado's address editor, not the silicon |
| `gen_hbmbw.py:337` "Without these extra segments those accesses would DECERR instead" | the author's belief about unassigned segments | **NOT ESTABLISHED for a direct connection.** No measurement in this repo shows a DECERR from an engine port |
| Master address width | `hbm_tg` drives `ADDR_W = 33` (`rtl/hbm_tg.vhd:91`); the A datapath is `ADDR_W`-generic (`rtl/weight_streamer.vhd:72` default 32, `rtl/matvec_int4_desc_axi.vhd:106` default 40) and `sim/tb_matvec_fk33.vhd:77` runs it at 64 and **"FAILS loudly at 32"** (`:79`) | **a truncation-to-stack-0 alias is guarded in simulation**, so it is not the live failure mode |

**So the failure mode is: the address decodes, the HBM IP routes it laterally to
the other stack, and OKAY data comes back.** ESTIMATE on the routing, with the
assumption stated: the IP reports the segments as reachable, and no measurement
on this card characterises the lateral path (`can-27-read-masters` sections 8
and 9 both say so explicitly).

**Which means the severity is NOT what the residency map says, and is still
high.** The residency map (section 5 item 4) predicts A "reads whatever is at
that address in its own stack" -- a wrong answer. If the lateral path works,
`blk.7.ffn_gate` would return the RIGHT bytes at an uncharacterised latency,
and the damage is a timing anomaly on one tensor rather than wrong logits. If
it does not work, or if a future build sets `HBMGlobalSwitch 0`, it is a wrong
answer. **Nothing in the repo decides between those two.** Both are unacceptable
in a shipped layout and both are removed by the same fix, so the fix did not
wait for the measurement.

**The bigger structural finding, recorded because the straddle is a symptom of
it.** Subsystem A has 27 read masters. A stack offers at most 15 engine ports
after the host takes one, so **27 masters cannot fit on one stack** and any A
port set spans both. Under the flat contiguous layout that is actually packed,
all 27 sub-regions of a tensor sit within a few hundred MB of each other, i.e.
in ONE stack -- so **at least 12 of the 27 masters read out of their own stack on
every tensor, not just on `blk.7.ffn_gate`.** The residency map's 27-lane arena
layout (its section 3) is the answer to that, and it needs a build-time
lane -> port -> pseudo-channel table that no bitstream in this repo has. That is
a design decision, not a packer change, and it is **NOT made here.**

---

## 4. The fix

`tools/pack_model_fk33.py`, new `place(off, nbytes) -> (base, hole)`.

**The rule: no placed object may contain a stack boundary strictly inside it.**
Applied to every `.mv4i` file, the F32 side blob and each of its 177 entries,
and the GDN state region. A file that is wholly inside one stack has all 27 of
its sub-regions wholly inside that stack for free, so the file-level rule is
strictly stronger than the sub-region rule and is the one a reader can check
without parsing a header. The packer asserts BOTH anyway (the sub-region loop
costs nothing) so a future layout change cannot weaken it silently.

**Alignment it requires: none beyond the 4 KiB that was already there.** The
rule needs the ability to leave a hole, not a coarser alignment. Aligning every
tensor to something larger would cost far more than the hole does.

**KV is a region, not an object, so the rule applies to the RECORD.** The
manifest now carries `kv_extents`, the KV region split at every stack boundary
with whole records counted inside each extent. The old
`free // kv_bytes_per_token` silently permitted one straddling 64 KiB record
per boundary crossed. It happens not to bite today (`kv_base` is above 4 GiB),
which is exactly why it needed fixing before it moved.

**Cost, DERIVED, and MEASURED as the difference between the two manifests:**

| quantity | old | new | delta |
|---|---|---|---|
| straddling ranges | 2 | 0 | -2 |
| weight bytes | 5,056,995,328 | 5,056,995,328 | 0 |
| stack hole | 0 | 27,836,416 (26.548 MiB) | +26.5 MiB |
| `weights_end` | 4.7097 GiB | 4.7356 GiB | +0.0259 GiB |
| `kv_base` | 5,132,492,800 | 5,160,329,216 | +27,836,416 |
| free for KV | 3.2200 GiB | 3.1941 GiB | -0.81% |
| max context | 52,756 tok | 52,331 tok | **-425 tok** |
| committed of 8 GiB | 59.75% | 60.07% | +0.32 pt |

Files whose `hbm_offset` moved: **131 of 251**, all by exactly +27,836,416.
The other 120 are unmoved. All 251 sizes and blake2b-128 digests are unchanged,
MEASURED, so **no byte of the packed set was rewritten** and nothing needs
re-DMA'ing on that account.

**The alternative, priced and NOT chosen.** A greedy first-fit-decreasing fill
of the hole from the files placed after it would seat 19 of them and leave a
77,824 B residue, recovering **423 of the 425 tokens** (DERIVED). It was not
implemented: it makes the manifest's order a function of the file sizes rather
than of the GGUF's tensor order, and 425 tokens is 0.8% of a budget that the
residency map's own analysis says is compute-capped at 4,096-8,192 tokens, i.e.
at 8-16% of where it is capacity-capped. If someone wants those 423 tokens the
hook is `place()` and the decision is theirs.

---

## 5. The evidence, raw

Independent enumeration, `packed_layout`-based (step 1):

```
stack boundary = 4294967296 0x100000000
tensors/files crossing: 1   sub-regions crossing: 1

FILE blk.7.ffn_gate.weight.mv4i
  range 4267130880 .. 4295446528  (0xfe574000 .. 0x100075000)  crosses=True  bytes above boundary=479232
    SUB s2: 4294397952 .. 4295446528   above=479232
```

`tools/check_hbm_stack.py`, header-based, on the OLD manifest:

```
checked 7182 byte ranges against a 4294967296 B stack boundary in /mnt/storage/llama-models/qwen35-9b-mv4i/manifest.json
FAIL 2 range(s) cross a stack boundary or are structurally wrong:
  blk.7.ffn_gate.weight.mv4i: 4267130880 .. 4295446528 crosses 4294967296 (stack 0 -> 1); 479232 bytes on the wrong side
  blk.7.ffn_gate.weight.mv4i:s2: 4294397952 .. 4295446528 crosses 4294967296 (stack 0 -> 1); 479232 bytes on the wrong side
```

and on the NEW one:

```
checked 7182 byte ranges against a 4294967296 B stack boundary in /mnt/storage/llama-models/qwen35-9b-mv4i-stackfix/manifest.json
PASS no range crosses a stack boundary
```

The two derivations are independent and agree on the same file, the same
sub-region and the same 479,232 bytes.

Packer output on the corrected run:

```
  weights          5056995328 B  4.710 GiB  (58.9 % of 8 GiB)
  GDN state        72.0 MB at 0x12f146000
  stack holes      27836416 B  26.5 MiB in 1 hole(s)
    27836416 B at 0xfe574000: stack boundary before blk.7.ffn_gate.weight.mv4i
  free for KV      3.194 GiB from 0x133946000 => 52331 tokens of context in 1 per-stack extent(s)
```

`tools/check_mv4i_set.py` (the pre-existing structural guard, untouched) on the
corrected set: `PASS every header, size, sub-region offset and HBM placement is
as spec 6.4/6.5a requires`.

---

## 6. Teeth: 11 mutants against `check_hbm_stack.py`

MEASURED, `scratchpad/teeth.py`. Every mutant rebuilds a directory of symlinks
plus a perturbed manifest and re-runs the checker.

| mutant | expect | got | what fired |
|---|---|---|---|
| m0 clean control | PASS | PASS | -- |
| m1 hole removed, i.e. the old flat layout | FAIL | FAIL 2 | file + sub-region crossing |
| m2 one small file overhangs by 4,096 B | FAIL | FAIL 1 | file crossing |
| **m3 file ends EXACTLY at the boundary** | **PASS** | **PASS** | negative control: the legal edge case is not flagged |
| **m4 file starts EXACTLY at the boundary** | **PASS** | **PASS** | negative control, other edge |
| **m5 boundary lands on a sub-region EDGE** | FAIL | FAIL 1, **file only** | the discriminating case: the file crosses, no sub-region does. Proves the two checks are different and that the file rule is the stronger one |
| m6 manifest `nbytes` disagrees with disk | FAIL | FAIL 1 | size comes from `getsize`, never the manifest |
| m7 one F32 side-blob entry straddles | FAIL | FAIL 1 | per-entry check |
| m8 GDN state region straddles | FAIL | FAIL 1 | region check |
| m9 a KV record straddles | FAIL | FAIL 1 | per-record check via `kv_extents` |
| m10 file header `NPORTS_W` corrupted 24 -> 25 | FAIL | FAIL 1 | sub-region base table no longer ascending |
| m11 manifest names a file that is not there | FAIL | FAIL 1 | missing on disk |

11 of 11 behave as specified, and m3/m4 are the ones that show the check is not
simply "flag anything near the boundary".

---

## 7. Measured and REJECTED -- do not retry

- **"Only `blk.7.ffn_gate` is affected because it is a `ffn_gate`."** No. It is
  affected because it is the file that happens to span offset 4 GiB in GGUF
  tensor order. MEASURED: no other `ffn_gate`, and no other tensor of any kind,
  crosses. Do not go looking for a shape-dependent cause.
- **Padding every tensor to a stack-aligned base.** Rejected: it would cost
  hundreds of MiB and buys nothing over a single hole.
- **Reordering the tensor list to avoid the hole.** Priced at 423 of 425
  recovered tokens and NOT adopted (section 4). Do not re-derive the saving;
  it is here.
- **Re-packing the model.** Rejected as unnecessary: all 251 payload digests
  are unchanged, so only `manifest.json` moves.
- **Treating the sub-region rule as sufficient.** Rejected by m5: a file can
  cross while no sub-region does. The file rule is the one to enforce.
- **Believing the residency map's "there is no cross-stack path".**
  Contradicted by the IP itself (section 3). The stack rule survives, its
  stated reason does not.

## 8. Measurement traps hit

- **The straddling sub-region is a SCALE lane, not a weight lane.** A search
  that only walked `w0..w23` would have found the file and missed the
  sub-region, and would have reported "the file crosses but no lane does",
  which is false. Walk `nports_w + n_scale_sub`, always.
- **`packed_layout` cannot be the checker's source.** It is what the packer
  used to lay the file out. Using it to check the layout is the round trip
  CLAUDE.md warns about. The checker reads the header instead, which is also
  why m10 is catchable at all.
- **`free // kv_bytes_per_token` looks like a capacity figure and is also a
  placement claim.** It silently asserts that no KV record straddles. It was
  true only by accident here.
- **A file-size figure from the manifest is not evidence the file is that
  size.** m6 exists because the first draft of the checker trusted `nbytes`.
- **`git commit -m msg -- <path>` commits the working tree.** Not hit, avoided
  by staging explicitly and committing with no pathspec.

---

## 9. Second item: do the 15 lm_head windows compute the same logits?

**Yes, bit-exactly, over all 248,320 elements.** MEASURED with
`tools/lmhead_window_equiv.c`, which links `ref/matvec_int4.c` and runs it once
over the whole `output.weight` tensor and once per window, on one deterministic
activation vector, in `MODE_RAW`.

`MODE_RAW` and not `MODE_BFP`: BFP normalizes by an `ns` scanned over the rows
of that job, so 15 windows legitimately produce 15 mantissa grids and a bit
comparison would be meaningless. RAW emits `sat32(round_shift(acc, out_shift))`
per row with no cross-row term, and is the mode the lm_head step is issued in.

```
shape    M=248320 K=4096  ROWS_IF=48 nb=128 grp=1 port_b=32 nports_w=24 n_scale_sub=3
whole    1 job, 248320 rows, y_exp=5 sat=0
windows  15, stride 17376 rows (MAXROWS_BFP=17408, floor to ROWS_IF)
  win  0 rows      0 ..  17375 (17376)  y_exp=5  mismatches 0
  ...
  win 14 rows 243264 .. 248319 ( 5056)  y_exp=5  mismatches 0

elements compared 248320 of 248320
y_exp differing windows 0
PASS 15-window and single-job logits are bit-identical
```

**Mutants, MEASURED:**

| mutant | verdict | detail |
|---|---|---|
| m0 clean | PASS | control |
| m1 one WEIGHT base +1 beat on window 3 | KILLED | 724 mismatches = 362 tiles x 2 rows, i.e. exactly the rows sub-region 0 supplies |
| **m2 scale skip computed with the weight stride** | **SILENT** | **a proven no-op at GRP = 1**, where `s_skip == w_skip` by arithmetic |
| m3 windows all read from row 0 | KILLED | 230,944 mismatches |
| m4 window one row short | KILLED | cover check: 248,305 of 248,320 |
| m5 one SCALE base +1 beat on window 3 | KILLED | 5,792 mismatches = 362 tiles x 16 rows, the rows scale sub-region 0 supplies |

4 of 5 bite. **m2 is the resolution floor and is the most useful row here:** the
`/ grp` divisor at `tools/gen_mv4i_desc.py:337` is **unexercised at this
geometry**, because `GRP = 1` makes the scale skip and the weight skip
identical. A defect in that divisor is invisible to this check and can only be
caught at a geometry with `GRP > 1`. m5 exists so that something at least
proves the scale sub-regions are read at all.

---

## 10. What this does NOT establish

- **Whether a cross-stack read actually works on this card.** The IP says the
  decode permits it. No measurement exists. Section 3.
- **Whether the flat layout is usable at all.** At least 12 of A's 27 masters
  read out of their own stack on EVERY tensor under it (section 3). The
  27-lane arena layout is the answer and is a decision for Oren, not made here.
- **Nothing was loaded to the card.** Placement is host-side; the corrected
  manifest is at `/mnt/storage/llama-models/qwen35-9b-mv4i-stackfix/`
  (symlinks to the existing payloads plus a 100 KB manifest; ~33 KB of disk).
  The original set is untouched, all digests verified equal.
- **`ARENA_SIZE = 160 MiB` in the residency map is too small for the real
  tensor list.** DERIVED from the packed set: one lane's bytes for the whole
  model are 187,088,896 B = **178.42 MiB**, weight lanes and scale lanes alike
  (they are equal at this geometry, `sub_sz == scl_sub_sz`, which does confirm
  the map's one-offset-per-tensor simplification). It still fits a 256 MiB
  pseudo-channel, but a build that hard-codes 160 MiB would truncate 6 tensors'
  worth of arena.
- **The gate was not re-run.** No `rtl/`, `sim/` or `tb/` file was touched, so
  no GHDL result can move.

## 11. Corrections

None yet. Append here with a date; mark superseded claims withdrawn in place.
