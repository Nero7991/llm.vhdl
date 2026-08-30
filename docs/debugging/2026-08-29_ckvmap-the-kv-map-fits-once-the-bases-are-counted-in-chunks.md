# The real 9B KV map is settable once the bases count chunks, not bytes

**Date** 2026-08-29. **Track** CKVMAP. **Base commit** `bf99d39` ("b_tk0:
subsystem B is a recurrence and the top level was running it as one token,
three times"), pinned with `SHA=$(git rev-parse HEAD)` as its own step before
any `git archive`, and the archive verified against HEAD by md5 of
`rtl/llama_top.vhd` (`93d75acfc30a91514603ca1b9fe3c019` both sides) because
HEAD has moved about fifty times today.

**Hardware** none. Nothing here opened `/dev/xdma*`, ran `xsdb`, `hw_server`,
`vivado ... program`, or touched `hw/fk33/`.

**Machine at start**, MEASURED with `df -h` / `free -g`: root `/dev/nvme1n1p6`
39 G free at 97 percent, `/mnt/storage` 388 G free, RAM 31 G total with 24 G
available and 5 G of swap in use, with TRACK LUTDIET's Vivado running
throughout. Memory fell to 18 G available mid-run; every measurement below
that is a wall time, not a verdict, should be read with that in mind.

**This is the remediation TRACK CGENERICS scoped and handed off** in section 7
of `docs/debugging/2026-08-29_cgenerics-kv-map-does-not-fit-a-vhdl-natural.md`,
which stopped because `rtl/llama_top.vhd` was owned by TRACK BTOP1 at the time.

---

## 1. The question, verbatim

> **The problem it found:** subsystem C's real KV map cannot be set, and the
> arithmetic is not why. [...] Every value in KVSIZE's map is correct; the TYPE
> is too small.
>
> **Verify every one of those five numbers yourself before building on them.**
> [...] show it against `tools/hbm_map.py`'s region block, which
> ARENA-MANIFEST made the authority for the HBM address map. If the manifest
> and CGENERICS disagree, the manifest wins and that disagreement is your
> headline finding.
>
> **What success looks like:** The real 9B shape **elaborates** with C's real
> KV map set, and you have shown it does by running it, not by reasoning that
> it should. [...] does anything **read** these generics correctly in the chunk
> domain? [...] **Find every consumer and check the domain at each one.**

---

## 2. The answer, up front

**All five of CGENERICS' numbers verify against the manifest, and the whole
real composition now elaborates at the real KV map with no measurable cost.**
MEASURED, GHDL 1.0.0 mcode, real A + real B + real B source + real RMSNorm +
sampler + real C over three AXI masters, at the true 9B shape:

```
small scaled bases (the pre-existing all_real row)   RSSKB 2452300  WALL 2.37
THE REAL KV MAP, C_MAXPOS 131072, C_KV_ADDR_W 33     RSSKB 2452864  WALL 2.36
```

A difference of 564 kB, 0.02 percent. TRACK REALFIX's baseline for the default
real shape reproduces exactly: `default_9b rc=0 peakRSS=2203252 kB wall=2.05`
against its recorded 2.20 GB / 2.12 s. **No regression in either number.**

The fix is that `C_K_BASE` and `C_V_BASE` are gone and `C_K_BASE_CH` and
`C_V_BASE_CH` are in their place, counting the record's own 16-byte chunks.
**The rename is the safety mechanism and not cosmetic.** A domain change under
the old name would have been a silent 16x address error at every existing call
site, which is precisely the defect class this project keeps finding at seams.
MEASURED, both seam kinds refuse a stale name loudly:

```
$ ghdl -r --std=08 llama_top -gC_K_BASE=0
/usr/bin/ghdl-mcode:error: cannot find in top entity generic 'c_k_base'
/usr/bin/ghdl-mcode:error: error during elaboration          rc=1
$ ghdl -r --std=08 llama_top -gC_K_BASE_CH=0                 rc=0
```

and a stale VHDL named association is an analysis error, not a mis-binding.

**Three consumers existed and all three now agree on the domain.** The generics
are chunks; `KBASE_C`/`VBASE_C` shift back to bytes in one place; everything
downstream of the port map -- `attn_kv_axi`, `tb_llama_top`'s slave decode and
shadow -- is bytes exactly as before.

**Two claims that reached me were wrong and are corrected in section 6**, one
of them in my own brief.

---

## 3. The procedure, in the order it was run, and what each step isolates

1. **Pin the tree**, `SHA=$(git rev-parse HEAD)` as its own step, `git archive`
   second, md5 of the target file compared against `git show HEAD:` third.
   Isolates every measurement from the three other running tracks.
2. **Re-derive the map from `tools/hbm_map.py` and the manifest**, not from
   CGENERICS' arithmetic. Isolates the placement authority from the derivation.
   This is the step the brief said would be the headline if it disagreed.
3. **Measure `natural'high` and GHDL's behaviour on an unknown generic name.**
   The second is what decides whether a rename is safe or is itself a silent
   16x hazard, so it is measured before any design choice rests on it.
4. **Enumerate every consumer of the two generics by grep over the whole tree**
   and read the domain at each. Isolates "who reads this" from "who mentions
   this".
5. **Confirm `attn_kv_axi`'s port domain from its arithmetic**, not from
   CGENERICS' claim that it needs no change. `rec_addr` is the whole question.
6. **Reproduce both walls on the pinned tree** before changing anything, so the
   before/after is measured on one machine in one session.
7. **Apply the encoding change**, then re-run the existing gates unchanged, then
   add rows that cover the region the existing gates provably cannot reach.
8. **Teeth on every guard**, each refusal paired with the row one generic away
   that must still pass, and **the guards that do NOT bite recorded under their
   own names** in section 5.3.
9. **Check the mutation harness's anchors survive**, mechanically, because
   `sim/mutate_llama_top_kv.sh` matches source text and a moved anchor is a
   silent loss of a mutation row.
10. **Baseline the one script whose rows fail**, on the unmodified tree, before
    reporting anything about it.

---

## 4. The evidence, as raw output

### 4.1 The map, re-derived from the manifest (MEASURED, `tools/hbm_map.py`)

`arena_sizes()` called directly, and the manifest read directly, rather than
either restated:

```
weights_end                  4496318464  0x10c006000
gdn_state_base               4496318464  0x10c006000
gdn_state_bytes              25264128    0x1818000
kv_base                      4521582592  0x10d81e000
kv_bytes_per_token           17408       0x4400
kv_record_bytes              272         0x110
kv_bytes_per_layer_per_token 2176        0x880
kv_layers                    8
desc_arena_base              8584548352  0x1ffadd000
size                         8589934592  0x200000000

arena_sizes attn_layers                      8
arena_sizes gdn_layers                       24
arena_sizes kv_record_bytes                  272
arena_sizes kv_bytes_per_token               17408
```

**The manifest and CGENERICS agree exactly.** There is no headline
disagreement. `REC_B = 16 + 256*8/8 = 272` re-derived from `C_HD`/`C_CM_W`
independently, and `8*4*272 = 8704` per region per token, which is the
manifest's `kv_bytes_per_token / 2`.

### 4.2 The five numbers (DERIVED, arithmetic shown)

```
1) C_K_BASE_CH = 4521582592/16 = 282598912   exact: yes   13.2% of natural
   REC_CH   = 272/16 = 17                    exact: yes
   KVREG_CH = 8*4*131072*17 = 71303168       ( = 544 * C_MAXPOS )
2) C_V_BASE_CH = 282598912 + 71303168 = 353902080          16.5% of natural
   cross-check in bytes: 353902080*16 = 5662433280
                       = kv_base + 8704*131072 = 5662433280   MATCH
3) chunk-domain sum = 353902080 + 71303168 = 425205248
4) 2**28 = 268435456 < 425205248 <= 536870912 = 2**29  ->  clog2 = 29
   and 425205248 < 2**30 = 1073741824, so the doubling loop does NOT overflow
5) C_KV_ADDR_W - 4 = 33 - 4 = 29 ; the check is 29 <= 29, satisfied EXACTLY

byte-domain equivalent, for contrast:
   byte sum = 6803283968   >  natural'high 2147483647
   clog2 would be 33, but no `natural` can hold the argument to ask
```

**All five verify.** The equivalence of the two forms is exact, not
approximate: every term is a whole number of 16-byte chunks and
`clog2(16*y) = clog2(y) + 4` for `y >= 1`, so `clog2(bytes) <= C_KV_ADDR_W` and
`clog2(chunks) <= C_KV_ADDR_W - 4` accept and refuse the same layouts. **No
check was loosened to make the real map fit.**

### 4.3 The type wall and the loop wall, reproduced on the pinned tree

```
$ ghdl -r --std=08 probe
integer'high = 2147483647
natural'high = 2147483647

W1  -gC_K_BASE=4521582592 -gC_V_BASE=5662433280 -gC_KV_ADDR_W=33 -gC_MAXPOS=131072
    /usr/bin/ghdl-mcode:error: value not in range for generic 'c_k_base'    rc=1

W2  -gC_K_BASE=0 -gC_V_BASE=1140850688 -gC_KV_ADDR_W=33 -gC_MAXPOS=131072
    /usr/bin/ghdl-mcode:error: overflow detected
    in process .llama_top(rtl).gb_real.u_gdn@gdn_block(rtl).P24
      from: work.llama_top(rtl).DECL_ELAB at llama_top.vhd:3874           rc=1
```

`llama_top.vhd:3874` is `CHK_KV_FIT`'s own declaration, so on this HEAD the KV
map's overflow **is** attributed to the right constant. CGENERICS' unattributed
`:785` was a different row and it still reproduces (section 6, correction 4).

### 4.4 The consumers, and the domain at each

Grep over `*.vhd *.tcl *.sh *.py *.c *.h` for both names. Four sites read the
value; every other hit is a comment or an unrelated `k_base` in the C server.

| site | what it does | domain | changed? |
|---|---|---|---|
| `rtl/llama_top.vhd` generics | the value itself | **chunks** now | yes |
| `rtl/llama_top.vhd` `KBASE_C`/`VBASE_C` | actual for `attn_kv_axi` | **bytes** | yes, one shift |
| `rtl/llama_top.vhd` KV guards | fit / overlap / alignment | **chunks** now | yes |
| `rtl/attn_kv_axi.vhd` `k_base`/`v_base` | `rec_addr = unsigned(base) + idx*REC_B` | **bytes** | **NO** |
| `sim/tb_llama_top.vhd:1252` | generic map, plus its own slave decode | **bytes**, converts at the map | yes, 3 hunks |
| `sim/realshape_gate.sh` (14 flags) | `-g` overrides | chunks now | yes, mechanical |
| `sim/elab9b_run.sh` (10 flags) | `-g` overrides | chunks now | yes, mechanical |
| `sim/mutate_llama_top_kv.sh` | mutates `k_base => KBASE_C` port map text | unaffected | no |

**CGENERICS' claim that `attn_kv_axi` needs no change is CONFIRMED, and the
reason is specific rather than general.** `rtl/attn_kv_axi.vhd:403-408`:

```vhdl
function rec_addr(base : std_logic_vector; lay, hd, ps : integer)
  ...
  return unsigned(base) + to_unsigned(idx*REC_B, ADDR_W);
```

`REC_B` is in bytes, so `base` is a byte address and must stay one. The claim
would have broken if the port had been fed chunks. It is not: `KBASE_C` shifts
left by 4 and the seam is exactly one shift wide, written out at the port map
rather than implied.

**Every pre-existing value was already a multiple of 16** -- 16, 4064, 0,
34816, 2228224 -- so the conversion of the 24 script flags was exact, and a
Python pass asserted `val % 16 == 0` on each rather than trusting it.

**All 22 mutation anchors in `sim/mutate_llama_top_kv.sh` survive unchanged**
(15 `mutate_rtl` anchors plus 7 in-place `s.replace` anchors, checked by
counting each anchor in the before and after file: zero counts changed).

### 4.5 The gate, before and after

`sim/realshape_gate.sh` unmodified except for the flag conversion and five new
rows, run on the pinned tree:

```
default_9b         rc=0   peakRSS= 2203252 kB  wall=2.05   expect=ok
regmax_short       rc=1   ...                              expect=fail
...
all_real           rc=0   peakRSS= 2452480 kB  wall=2.59   expect=ok
real_kv_map        rc=0   peakRSS= 1260324 kB  wall=1.54   expect=ok
real_kv_addr_short rc=1   peakRSS=  660940 kB  wall=0.71   expect=fail
    bound check failure at rtl/llama_top.vhd:3955
real_kv_overlap    rc=1   peakRSS= 1260228 kB  wall=1.45   expect=fail
    llama_top.vhd:3997: llama_top: the K and V KV regions overlap.  Each is
    71303168 chunks of 16 bytes.
real_kv_ceiling    rc=0   peakRSS= 1260236 kB  wall=1.57   expect=ok
real_kv_ctx_over   rc=1   peakRSS=  661196 kB  wall=0.71   expect=fail
    bound check failure at rtl/llama_top.vhd:3922

REALSHAPE GATE: PASS  rows 24 (13 of them guards that must refuse)
```

19 rows before, 24 after; 10 refusals before, 13 after. **Re-run against the
actual repository working tree after the change was applied there**, not only
against the scratch copy: `REALSHAPE GATE: PASS rows 24 (13 of them guards
that must refuse)`, `default_9b rc=0 peakRSS=2203144 kB wall=2.45`.

### 4.6 The value gates

`sim/regress.sh --only llama_top`, on the pinned scratch tree, all six rows:

```
sim:tb_llama_top          PASS
sim:tb_llama_top_normw    PASS
sim:tb_llama_top_real     PASS
sim:tb_llama_top_seq      PASS
sim:tb_llama_top_smp      PASS
sim:tb_llama_top_smp_beh  PASS
```

**That run is the one to believe, and it is deliberately the SCRATCH one.** It
is a `git archive` of the pinned SHA with only this track's four files changed,
so nothing else can have moved. A repeat against the repository working tree
was started and is NOT reported here, because by then the working tree also
held TRACK CLOG2's uncommitted `rtl/util_pkg.vhd` and TRACK BGATE2's
uncommitted `rtl/rmsnorm_rs.vhd`, and three concurrent `regress.sh` runs were
on the box -- a red row from it would not have been attributable to anything.
See section 7 for the ownership consequence of that same overlap.

`sim/regress.sh` itself was NOT touched, no new `sim/tb_*.vhd` was added, and
`BASELINE_PASS` is therefore unchanged. `sim/realshape_gate.sh` and
`sim/elab9b_run.sh` are scripts, not gate rows; `realshape_gate.sh:28` says so
in as many words, because ten of its rows must make the elaborator refuse and
no testbench can express that.

### 4.7 The relocated alignment assert has teeth

```
tb_llama_top -gKV_K_BASE_G=17   rc=1
  tb_llama_top.vhd:1238: (assertion failure): tb_llama_top: the KV bases must
  be 16-byte aligned -- that is attn_kv_axi's record granule.  K base 17,
  V base 4064.  llama_top's C_K_BASE_CH/C_V_BASE_CH count 16-byte chunks, so
  a base that is not a multiple of 16 cannot even be passed to it.
tb_llama_top -gKV_K_BASE_G=16   rc=0
```

---

## 5. Teeth

### 5.1 The guards that DO bite

Every row one generic from the control, MEASURED, `rc` unpiped.

```
control_real_map           rc=0  (clean)
addr_w_32_one_short        rc=1  bound check failure at rtl/llama_top.vhd:3955
v_base_one_chunk_low       rc=1  llama_top.vhd:3997: the K and V KV regions
                                 overlap.  Each is 71303168 chunks of 16 bytes.
v_base_exact_ok            rc=0  (clean)
ctxlen_one_over            rc=1  bound check failure at rtl/llama_top.vhd:3922
kv_block_16_ok             rc=0  (clean)
kv_block_8_illegal         rc=1  bound check failure at rtl/llama_top.vhd:3916
stale_byte_value_K         rc=1  value not in range for generic 'c_k_base_ch'
maxpos_at_arena_ceil       rc=0  (clean)          C_MAXPOS 233396, still 33 bits
maxpos_past_clog2_29       rc=1  bound check failure at rtl/llama_top.vhd:3955
                                 C_MAXPOS 233706, the first value needing 34
```

`v_base_one_chunk_low` is worth naming: the V base 16 bytes low, at the real
map, is refused by the overlap assert with a message. That is the finest
resolution the encoding can express, and it is one record granule.

### 5.2 The `C_KV_ADDR_W` slack is real, and it is set by the BASE

CGENERICS' "zero slack" reproduces exactly: `29 <= 29`, and 32 refuses. But the
sensitivity is not what my brief said it was. DERIVED:

```
sum(M) = C_K_BASE_CH + 1088*M = 282598912 + 1088*M
clog2 = 29 requires 2**28 < sum <= 2**29
  M = 1        sum = 282600000   clog2 = 29
  M = 233705   sum = 536869952   clog2 = 29
  M = 233706   sum = 536871040   clog2 = 30
  M = 233396   sum = 536533760   clog2 = 29     (the arena ceiling)
C_K_BASE_CH alone = 282598912 > 2**28 = 268435456
```

**`clog2` is 29 for every `C_MAXPOS` from 1 to 233,705**, which strictly
contains the whole feasible range, because the base address alone already
exceeds `2**28`. `C_MAXPOS` cannot move `C_KV_ADDR_W` at any value the arena
permits. Confirmed by measurement, not only arithmetic: `maxpos_at_arena_ceil`
passes at 33 bits and `maxpos_past_clog2_29` is the first refusal.

### 5.3 The guards that do NOT bite -- the resolution floor

These are the most valuable rows here and each is a real gap.

```
stale_byte_num_small   rc=0  -gC_V_BASE_CH=34816  at C_MAXPOS=4, ADDR_W=20
correct_chunk_small    rc=0  -gC_V_BASE_CH=2176   the same row, correct value
k_base_off_by_one_ch   rc=0  C_K_BASE_CH=282598913, C_V_BASE_CH=353902081
addr_w_34_one_wide     rc=0  C_KV_ADDR_W=34 at the real map
```

* **`stale_byte_num_small` is the residual domain hazard and it is not
  closed.** Someone who renames a stale flag but keeps its byte number gets a
  clean elaboration pointing V at byte 557,056 instead of 34,816. The rename
  defends against copying a whole stale flag, which is the common case and is
  MEASURED to refuse; it cannot defend against copying the number alone.
  Nothing in the RTL can, because 34,816 is a perfectly legal chunk count.
* **`k_base_off_by_one_ch` says nothing in `llama_top` knows where the arena
  actually is.** The base is an input. There is no link from the RTL to
  `hbm.kv_base`, so a base one chunk -- or one megabyte -- off the manifest
  elaborates clean and would read and write real weights. The gate row pins the
  correct value, and the gate row is the only thing that does.
* **`addr_w_34_one_wide` shows the fit check is an upper bound only.** 33 is a
  minimum. CGENERICS' "one bit more and it is a wasted pin" is a hardware-cost
  statement; the RTL does not and should not refuse a wider bus.
* **`CHK_KV_REC`, the new guard, has never been shown to refuse anything.**
  `C_HD` is `SHAPE.attn_head_dim` and SHAPE is a record generic GHDL cannot
  override, so C_HD is 256 in every configuration this file can be elaborated
  at; `C_HD*C_CM_W/8` is then `32*C_CM_W`, a multiple of 16 for **all sixteen**
  values of `C_CM_W` tried. It is kept as insurance against a future head dim
  below 32, and it is labelled unreachable in the RTL so nobody reads it as
  tested. It is decoration today.

### 5.4 The alignment guard was RETIRED, and that is a deliberate loss

`assert C_K_BASE mod 16 = 0 and C_V_BASE mod 16 = 0` is gone from
`rtl/llama_top.vhd`. With the bases counted in chunks there is no representable
value that violates it, so it could never fire again, and a check that cannot
fail is decoration rather than evidence. The requirement is now enforced by the
encoding.

**It was not simply deleted.** `sim/tb_llama_top.vhd` still takes BYTE generics
(`KV_K_BASE_G`, `KV_V_BASE_G`) and still uses byte addresses for its slave
decode, so a misaligned base is still expressible there -- and the assert moved
there, with teeth, next to the pre-existing `KV_FIT_OK` one.

---

## 6. Corrections, appended not edited

1. **My brief said "only a value SMALLER than 131,072 would move
   [`C_KV_ADDR_W`]". That is FALSE, and the true statement is stronger.** No
   value of `C_MAXPOS` in the feasible range moves it, in either direction:
   `clog2` is 29 from 1 to 233,705 because `C_K_BASE_CH` alone exceeds `2**28`.
   The zero slack is a property of where the arena put the base, not of the
   context length. Section 5.2 has the numbers and the measured boundary.
2. **CGENERICS' section 6 note 6 says the pair at `C_MAXPOS = 233,396` ends
   "2,048 bytes" below `desc_arena_base`. MEASURED from the manifest it is
   8,192 bytes.** `0x1FFADD000 - 0x1FFADB000 = 0x2000`. Both figures are small,
   and CGENERICS' conclusion is unaffected, but the number is wrong by 4x and
   it is exactly the sort of figure a later track would reuse.
3. **CGENERICS' section 7 names the constant `CHK_KV_ADDR`. No such constant
   exists.** The one it means is `CHK_KV_FIT`, and the set of REALFIX natural
   constants in this generate is `CHK_KV_NBLK`, `CHK_KV_GRAN`, `CHK_KV_CTX`,
   `CHK_KV_FIT` -- `CHK_HDR_FITS`, also listed there, lives in
   `rtl/attn_kv_axi.vhd:398`, not in `llama_top`.
4. **CGENERICS' unattributed-overflow finding stands, at `:792` on this HEAD**,
   not `:785`; BTOP1's landing moved the line. Reproduced verbatim on the
   pinned baseline tree at `C_MAXPOS = 61,681`, `C_KV_ADDR_W = 31`, with 61,680
   passing.
5. **THE `clog2` THAT THE KV GUARDS CALL IS NOT `util_pkg.clog2`.** This
   matters to TRACK CLOG2 and neither CGENERICS nor my brief knew it.
   `rtl/llama_top.vhd:173` has `use work.util_pkg.clog2;` but
   `rtl/llama_top.vhd:789` **declares its own** in the architecture declarative
   part, which hides the use-clause name for the whole architecture including
   the KV generate. GHDL names it in the diagnostic:
   `from: work.llama_top(rtl).clog2 at llama_top.vhd:792`, not
   `work.util_pkg.clog2`. The two bodies also differ:

   ```vhdl
   -- util_pkg          while v < n loop v := v*2; r := r+1; end loop;
   -- llama_top:789     while (2**v) < n loop v := v + 1; end loop;
   ```

   Same `2**30` ceiling, different mechanism. **A fix confined to
   `rtl/util_pkg.vhd` will not reach any guard in `llama_top`.** CGENERICS'
   section 8 quotes the `util_pkg` body as the cause of the `llama_top`
   overflow; that attribution is wrong even though the ceiling it names is
   right. Left untouched here: `llama_top`'s local `clog2` is never asked for
   more than `2**30` on the KV path any more, and rewriting it is CLOG2's
   territory, not this track's.
6. **`sim/elab9b_run.sh` fails 4 of 17 rows and did so BEFORE this change.**
   MEASURED on an unmodified archive of the same commit: `PASS 13 FAIL 4` on
   both trees, the same four rows. It is TRACK REALSHAPE's historical
   investigation harness and REALFIX superseded three of its expectations
   (`kv_addr_wrap expect=ok` documents a check that REALFIX then added). Not a
   regression, and not fixed here: correcting another track's harness
   expectations is not this track's call.

---

## 7. Scope taken beyond the brief, and why

The brief scoped this track to `rtl/llama_top.vhd` plus this document. Three
further files were edited. None is owned by a running track
(`docs/WORKLOG.md` lists `sim/tb_llama_top.vhd` as free since `3246046`), and
none is on the brief's do-not-touch list, but the extension is declared rather
than buried:

* `sim/tb_llama_top.vhd` -- 3 hunks. Unavoidable: it is the only VHDL named
  association of these generics, so a rename is an analysis error until it is
  updated. It keeps its byte domain; two constants convert at the boundary and
  the retired alignment assert moves here.
* `sim/realshape_gate.sh` -- 14 flags converted, 5 rows added.
* `sim/elab9b_run.sh` -- 10 flags converted, nothing else.

**The alternative that would have touched no other file was considered and
rejected.** It was: keep `C_K_BASE`/`C_V_BASE` as byte generics and ADD
`C_K_BASE_CH`/`C_V_BASE_CH` defaulting to 0, with the effective base being
`C_K_BASE/16 + C_K_BASE_CH`. It has real merits -- zero external edits, and the
alignment guard keeps its teeth in `llama_top` -- but it makes one address the
sum of two generics, which is a new seam of exactly the kind this project keeps
finding defects in, and it leaves a byte generic in place that still cannot
express the real base. Recorded here so the tradeoff is visible rather than
re-litigated.

**A TIMING COLLISION HAPPENED AND IT IS RECORDED RATHER THAN HOPED AWAY.**
MEASURED from `ps -eo lstart`: TRACK CLOG2's full `sim/regress.sh` gate started
at **18:52:19**; this track's four files were written into the working tree at
**19:11:31**. `regress.sh` re-execs a private copy of itself (`:287`, `:299`)
so the SCRIPT is safe, but each row analyses the RTL when that row runs, so
CLOG2's gate spans the change: rows before 19:11:31 saw the old
`rtl/llama_top.vhd` and rows after saw the new one. **Its result for the
`tb_llama_top*` family is therefore not attributable to either tree.** Nothing
was lost -- the same six rows are green on a clean pinned archive, section 4.6
-- but if that gate comes back red in a `llama_top` row, this is the first
thing to check, and the honest move is to re-run it on a quiet box rather than
to blame either track. There is no way to make a working-tree edit atomic with
respect to a running gate; the mitigation is to say when it happened.

**Nothing changed any DEFAULT, and "setting the generics" could not mean that.**
`C_MAXPOS`'s default cannot become 131,072: with `C_KV_AXI` false the
behavioural cache `gkvmem` is sized `C_LAY*2*C_NKVH*C_MAXPOS`, which would be
8.4 million signal entries in every bench that leaves it false. The bases'
defaults cannot become the real ones either -- `kv_overlap` and
`kv_default_base` are gate rows that depend on the scaled defaults overlapping.
So the real map is a build CONFIGURATION; what landed is (a) an encoding that
can express it, (b) the values recorded with their provenance in the generic's
own header in `rtl/llama_top.vhd`, and (c) `real_kv_map` and its four
neighbours in `sim/realshape_gate.sh` as the standing, re-runnable proof.
`sim/ooc_compose_bcd.tcl` sets `GEN(llama_top) {}` -- no synthesis path sets
these at all today.

---

## 8. Measured and REJECTED -- do not retry

* **Do not widen the integer type, and do not try to keep a byte-domain
  generic.** MEASURED: `natural'high = 2147483647`; the real base is
  4,521,582,592. VHDL-2008 offers no wider standard integer and GHDL refuses
  the value before any guard in the design runs. This is a language fact, not a
  tool setting.
* **Do not change the DOMAIN of `C_K_BASE`/`C_V_BASE` while keeping the
  names.** Three call sites would have silently become 16x wrong and every one
  would have elaborated clean. The rename is load-bearing; MEASURED, GHDL
  refuses an unknown generic name with `cannot find in top entity generic`,
  rc=1.
* **Do not fix this in `rtl/util_pkg.vhd`.** MEASURED: `llama_top` declares its
  own `clog2` at `:789` which hides the package one for the whole architecture.
  See correction 5. This is the single most likely wasted afternoon in this
  area.
* **Do not set `C_MAXPOS` to 233,396 to "use the arena".** It elaborates
  (`real_kv_ceiling rc=0`) and `C_KV_ADDR_W = 33` still holds, so the RTL does
  not stop you. It is refused on model grounds: 131,072 is Qwen3.5-9B's native
  context and everything past it needs RoPE extension work that does not exist.
  Decision recorded in `docs/WORKLOG.md`, not re-opened here.
* **Do not read `sim/elab9b_run.sh`'s red rows as a regression from this
  change.** Baselined on an unmodified tree: `PASS 13 FAIL 4` both sides, same
  rows. See correction 6.
* **Do not treat a green `sim/realshape_gate.sh` from before today as evidence
  about the KV map.** CGENERICS said this and it is worth restating with the
  new numbers: every pre-existing row ran at `C_MAXPOS <= 256` with bases under
  36 MB, so the entire 32-bit wall was outside its coverage. That is why the
  five new rows exist.

---

## 9. Measurement traps hit, including my own

* **I nearly reported the arena margin as CGENERICS wrote it.** The 2,048-byte
  figure looked precise and was in a document that had verified everything else
  correctly. It is 8,192. The only reason it was caught is that section 4.1
  recomputed every manifest-derived quantity instead of quoting the handoff --
  which is exactly what the brief asked for and which felt redundant while
  doing it, because the first eight numbers all matched.
* **`ghdl -r ... | head` reports the PIPELINE's rc.** Every rc in this document
  is from an unpiped run or `${PIPESTATUS[0]}`. Restating CGENERICS' trap
  because I hit it again in the first teeth harness.
* **`ghdl -r` after editing the source but before `ghdl -m` reports
  `file "rtl/llama_top.vhd" has changed and must be reanalysed` with rc=1**,
  which in a teeth table reads exactly like a guard biting. My first
  stale-flag-name row produced that, not the refusal I wanted; the real
  refusal only appeared after a rebuild. A teeth row that fails for the wrong
  reason is worse than one that does not fail.
* **A background `nohup ... &` from this harness returns exit code 0
  immediately and leaves a 4-line log.** The first `regress.sh --only
  llama_top` run appeared to complete successfully having produced only the
  banner. Read the row count, never the exit status.
* **`peakRSS` on the new rows is LOWER than on `all_real`, and that is not the
  KV map being cheap.** `real_kv_map` runs under `$CKV`, which sets
  `A_BEHAV=true B_BEHAV=true`; `all_real` does not. The like-for-like
  comparison is the pair in section 2, both with everything real, and it is the
  only one that supports the "no cost" claim.
* **`C_MAXPOS = 233,706` is the first refusal, not 233,705.** Off-by-one in the
  first sensitivity calculation; the boundary is stated as a measured pair for
  that reason.
* **THE THIRD FIELD OF A `regress.sh` RESULT LINE IS ELAPSED SECONDS, NOT A
  CHECK COUNT.** `sim/regress.sh:1736` writes
  `printf '%s\t%s\t%s\t%s\n' "$key" "$1" "$(( $(date +%s) - t0 ))" "$2"`. I
  spent a round investigating why `tb_llama_top_normw` read 86 against a
  baseline 82 and whether my new assert had added four checks; it had not,
  the box was under two concurrent regress runs and a Vivado. The rendered
  line `sim:tb_llama_top PASS 147` invites exactly this reading, and CGENERICS'
  section 4.8 quotes six such lines in a context where they look like check
  counts. **Any conclusion drawn from a change in that number is a conclusion
  about machine load.**
* **`ghdl -m` after editing a source, before `ghdl -r`, or the run is
  worthless.** Covered above as a teeth trap; noting separately that it also
  applies to a `regress.sh` scratch work library reused by hand afterwards,
  which is how it bit the second time.

---

## 10. Open, not yet answered

* **Nothing here checked a VALUE.** Every measurement is a shape, a width, a
  range or an address, at elaboration. That the KV cache reads and writes
  correct records at the real geometry is the `sim/tb_attn_kv_seam` family's
  question and it was not asked. **The real map elaborating is not the real map
  working.**
* **Nothing links the RTL's bases to the manifest.** `k_base_off_by_one_ch`
  elaborates clean. The only thing pinning `C_K_BASE_CH` to `hbm.kv_base` is
  the gate row and the comment in the generic header, both of which a person
  maintains. A generated package, or a check in `tools/hbm_map.py`, would close
  it; neither exists and neither is in this track's scope.
* **Vivado was not run.** REALFIX established that `natural`-constant guards
  survive synthesis and asserts do not, and that result is relied on rather
  than re-measured, because TRACK LUTDIET held the tool throughout. The new
  `shift_left(to_unsigned(...), 4)` on a constant is trivially constant-folded
  in principle and that is an ESTIMATE, not a measurement.
* **`attn_kv_axi`'s run-time ceiling is 246,723 positions**, DERIVED from
  `rec_addr`'s `to_unsigned(idx*REC_B, ADDR_W)` where `idx*REC_B` is a 32-bit
  `integer` expression: `(32*MAXCTX-1)*272 <= 2147483647`. CGENERICS raised
  this; it is confirmed here and still nothing checks it, because it is a
  run-time expression inside a function. It is above the arena ceiling of
  233,396 so it does not bind today, and it is 88 percent above the 131,072
  that was chosen.
* **`rtl/attn_c_ports_skel.vhd` STATES A CONTRACT THE REAL MAP CANNOT
  SATISFY, and it is the file whose entire purpose is to make the contract
  reviewable.** MEASURED by reading it: `k_base`/`v_base` are
  `std_logic_vector(31 downto 0)` at `:113-114`, but `C_KV_ADDR_W` is **33**;
  and `cur_pos`/`ctx_len` are `unsigned(15 downto 0)` at `:111-112`, but
  `C_MAXPOS = 131072` gives `POSW = clog2(131073) = 18`. Both are stale by the
  same event -- the 27B-to-9B retarget plus the arena resize -- and neither is
  a live defect, because the skeleton is deliberately never instantiated
  (grep confirms: it appears only in its own file and in one comment in
  `rtl/attn_lane_skel.vhd`, and `regress.sh`'s coverage report lists it under
  `NOTB`). It is a documentation defect of the same class CGENERICS found in
  `attn_block`'s defaults. **Not edited: `rtl/attn_*.vhd` is TRACK C-ORACLE's
  in `docs/WORKLOG.md`'s ownership table.** Flagged for whoever owns it.
* **`sim/ooc_compose_bcd.tcl:104` now names generics that do not exist**
  (`C_K_BASE 16 / C_V_BASE 4064`) in a comment. CGENERICS already flagged that
  file's section 6 note 5 as stale for a different reason. Not owned by this
  track, not edited, flagged again.
* **The 24 converted script flags were verified only by the `val % 16 == 0`
  assertion and by the gate's verdicts staying identical.** Every row kept its
  expected verdict, which is strong, but no row's ADDRESS was compared before
  and after -- the gate checks that elaboration succeeds or refuses, not where
  a record lands.
