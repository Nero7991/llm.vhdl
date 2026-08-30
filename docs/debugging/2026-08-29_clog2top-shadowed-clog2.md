# `llama_top` declared its own `clog2` over the package one, and the real 9B map already elaborates at `C_MAXPOS = 131,072`

TRACK CLOG2TOP, 2026-08-29. Repo `llama.vhdl`, branch `fpga`.

HEAD when this work started: `5a19f9840bed61d0d7727faf75d39885c321516c`, read
with `git rev-parse HEAD` as its own step. Note that is NOT the sha the brief
was written against: `51323ca` was HEAD when the brief was composed and
`5a19f98` (a worklog commit recording CLOG2's result) landed in between.
Every base-vs-post measurement in this file is against a
`git archive 5a19f984` clean tree, because three other tracks had
uncommitted edits in `rtl/` throughout (`attn_block.vhd`, `attn_kv_axi.vhd`,
`gdn_block.vhd`) and the working tree is not attributable.

This work landed as `d80d3a95b71cd4cf9ee7f127ce22b8f6ddf0f7ea` (the RTL) and
`66370bffcaf565ed7a05339359f367fb704ff96e` (the bench).

Tools: GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6) [Dunoon edition], mcode backend;
Python 3 for the golden table. Machine at the start: root `/` 1.3T with 121G
free, 91% used; `/mnt/storage` 388G free; RAM 31G total with 19G available,
9G of 31G swap in use; load average 7.51 with TRACK WRITEDEC's Vivado and
three other tracks' GHDL processes already running.

---

## 1. The questions, verbatim

From the TRACK CLOG2TOP brief:

> **The defect:** `rtl/llama_top.vhd` declares its OWN `clog2` in the
> architecture declarative part, of a different shape (`while (2**v) < n`),
> which **hides the selective `use work.util_pkg.clog2;` already present at
> `:173`**.

and, as the headline:

> **Does the real 9B configuration elaborate with `C_MAXPOS = 131,072`, or
> only with the real KV BASES at some smaller `C_MAXPOS`?**

and the standing contradiction it was dispatched to settle. TRACK CLOG2's
correction #3:

> **Fixing `clog2` does not unblock `C_MAXPOS = 131072`, and cannot.** The
> argument is 6,803,283,968, which exceeds `natural'high` by 3.2x ... at
> 131,072 the overflow moves EARLIER, to `llama_top`'s own
> `constant KVREG_B : natural := C_LAY*C_NKVH*C_MAXPOS*REC_B_C` =
> 2,281,701,376.

against TRACK CKVMAP's report that **"the real 9B KV map elaborates"**.

---

## 2. The answers, up front

**The headline: YES. The real 9B configuration elaborates at
`C_MAXPOS = 131,072` today, and did so already at the baseline sha, before
this track changed anything.** MEASURED on a clean `git archive 5a19f984`:
`llama_top` with `-gC_K_BASE_CH=282598912 -gC_V_BASE_CH=353902080
-gC_KV_ADDR_W=33 -gC_MAXPOS=131072 -gC_CTXLEN=131072` and the real subsystem C
returns rc=0 in 1,261,112 kB peak RSS. The guard has teeth in the same tree:
the same config at `C_KV_ADDR_W=32` refuses, and at `C_V_BASE_CH=353902079`
the overlap assert fires by name.

**The contradiction resolves in CKVMAP's favour, and the mechanism is a domain
change, not a disagreement about arithmetic.** Both tracks computed correctly;
they computed about different files. TRACK CKVMAP (`9d287f2`) converted the KV
guard from BYTES to 16-BYTE CHUNKS, and that landed at 19:11:31 on 2026-08-29,
**during** CLOG2's own full-gate run. CLOG2's correction #3 is arithmetic about
`constant KVREG_B : natural := C_LAY*C_NKVH*C_MAXPOS*REC_B_C`, a constant that
**no longer exists in `rtl/llama_top.vhd`**. What is there now is
`constant KVREG_CH : natural := C_LAY*C_NKVH*C_MAXPOS*REC_CH_C` with
`REC_CH_C = REC_B_C / 16`, which is 16x smaller and stays inside `natural` and
inside the old `clog2`'s `2**30` ceiling with room to spare:

```
KVREG_CH        = 8 * 4 * 131072 * 17          =    71,303,168   (printed by the tool, section 4.2)
max(base) + reg = 353,902,080 + 71,303,168     =   425,205,248
2**28 = 268,435,456  <  425,205,248  <=  536,870,912 = 2**29    =>  clog2 = 29 = C_KV_ADDR_W - 4
```

Per the project rule, **where a document and the RTL disagree the RTL wins**.
CLOG2's correction #3 is hereby **WITHDRAWN as a statement about the current
tree**; it remains correct as a statement about the byte-domain tree it was
measured on, and its second half -- that a perfect `clog2(natural)` alone
could not have got there -- is exactly why CKVMAP's chunk conversion was the
right fix rather than a wider integer.

**A consequence worth stating separately: the `unsigned` overload
`util_pkg.clog2(u : unsigned)` is not needed by `llama_top` and is not used by
it.** It is a good function and it stays; but the escape hatch that actually
opened `C_MAXPOS = 131,072` was CKVMAP's, not CLOG2's. Nothing in the KV-fit
guard was rewritten against `clog2(unsigned)` by this track, because the guard
that exists does not overflow. The brief's instruction to "rewrite the KV-fit
guard against the new `clog2(unsigned)`" is therefore **declined with a
measurement**, not skipped: rewriting a guard that already evaluates correctly
would replace a `natural`-domain check that has a working negative-constant
refusal with an `unsigned`-domain one that has to reinvent it. The coordinator
independently withdrew that instruction mid-track, on TRACK KVVALUE's
measurement, with the note that the `clog2(unsigned)` overload "is still the
right tool if any guard needs a magnitude past `natural'high`; just do not
assume the KV guards are such a case." Agreed, and section 4.7 is the probe
that shows what a guard which DOES need it looks like.

**The defect itself is real and is fixed.** `architecture rtl of llama_top`
declared `function clog2(n : natural) return natural` over the selective
`use work.util_pkg.clog2;` at `:173`. It is deleted. **The file had been using
two different `clog2` functions at once** -- the entity's generic defaults
(`VN_W : positive := maximum(13, clog2(region_max(SHAPE) + 1))` at `:196`) are
in the ENTITY, outside the architecture, so they always resolved to the
package one, while `CHK_VN_W` at `:866` recomputes the same expression inside
the architecture and got the local one. The two agreed, so nothing was wrong;
they were never guaranteed to.

**The deletion is behaviour-preserving where the old body was defined and
strictly better where it was not.** MEASURED: 21 `llama_top` elaboration rows,
base vs post on a clean archive with only this hunk applied, **zero rows
moved**; and a config whose chunk sum exceeds `2**30` dies at base with an
unattributed `overflow detected` and elaborates clean at post.

**The handoff's recommendation for the OTHER four copies is CORRECTED, with a
measurement.** The brief and CLOG2's section 9 suggest folding
`rtl/hbm_tg.vhd` and the three `sim/micro` copies into `util_pkg` and deleting
them. **That would break two real build flows.** `hw/fk33/build_fk33_hbmbw.tcl`
adds exactly two files from `rtl/` -- `hbm_tg.vhd` and `hbm_tg_ip.vhd` -- and
`rtl/util_pkg.vhd` is not among them (contrast `build_fk33_pcieep.tcl:187`,
which does add it); and `sim/run_micro.sh:27` hands `sim/ooc_micro.tcl` a
single file, `sim/run_micro_pnr.sh:24` two, with no package in either. Both are
deliberately dependency-free designs. They are therefore **fixed in place**,
keeping that property, and the reason is written into each file so the next
reader does not "tidy" it away.

---

## 3. The procedure, in the order it was run, and what each step isolates

1. **Read the RTL before the write-ups.** `grep -n "KVREG_B\|KVREG_CH"
   rtl/llama_top.vhd`. Isolates: *does the constant the contradiction is about
   still exist?* It does not. This one grep settled the headline; everything
   after it is confirmation.
2. **Pin a baseline sha and take a clean archive**, because three tracks had
   uncommitted `rtl/` edits. Isolates: *is what I am about to measure mine?*
3. **Run the real KV row and BOTH its controls on that archive, before
   changing anything.** Isolates: *does 131,072 elaborate today, and does the
   guard that permits it have teeth?* A passing row alone would only prove the
   check cannot fail.
4. **Enumerate every `clog2` CALL SITE in `llama_top`**, not just the
   declaration. Isolates: *how many functions is this file actually using?*
   This is what found that `:196` is in the entity and resolves differently
   from `:866` in the architecture.
5. **Build an equivalence oracle before touching the source.** Two oracles,
   neither of them the other body: a Python golden table
   (`(n-1).bit_length()`, closed form, arbitrary precision, generated outside
   VHDL entirely) and a 64-bit shift oracle. Isolates: *a shared bug between a
   doubling loop and a halving loop*, which comparing the two bodies to each
   other cannot.
6. **Mutation teeth on the bench**, 18 mutants across all seven bodies, the
   two oracles and the golden table. Isolates: *does the bench have any
   resolution?*
7. **Delete the local declaration; re-run all 21 elaboration rows base vs
   post** from the same archive plus only that hunk. Isolates: *did the change
   move anything?*
8. **Find a config that must FAIL at base and PASS at post.** Isolates: *is
   the deletion load-bearing, or only cosmetic?* Without this row the change
   is unfalsifiable.
9. **Read the build filesets before deleting the other four copies.**
   `grep -n "add_files" hw/fk33/build_fk33_hbmbw.tcl`, `sim/run_micro*.sh`,
   `sim/ooc_micro.tcl`. Isolates: *what does each copy's design actually get
   compiled with?* This is the step that reversed the recommendation.
10. **Reproduce `hbm_tg`'s `clog2(0)` standalone** at `-gAXI_DW=4`, fix, and
    re-run the whole legal `AXI_DW` ladder plus the two illegal values.
11. **Re-verify TRACK CLOG2's 22-name homograph sweep independently**, from a
    parser rather than by reading its table.
12. **Full unfiltered `sim/regress.sh`.**

---

## 4. Evidence, as raw output

### 4.1 The constant the contradiction is about no longer exists

`rtl/llama_top.vhd` at `5a19f984`, the KV-fit guard, verbatim:

```vhdl
      constant CHK_KV_REC  : natural := 0 - ((C_HD*C_CM_W/8) mod 16);
      constant REC_CH_C    : natural := REC_B_C / 16;
      constant KVREG_CH    : natural := C_LAY*C_NKVH*C_MAXPOS*REC_CH_C;
      constant CHK_KV_FIT  : natural :=
        (C_KV_ADDR_W - 4)
        - clog2(maximum(C_K_BASE_CH, C_V_BASE_CH) + KVREG_CH);
```

There is no `KVREG_B`. `grep -c KVREG_B rtl/llama_top.vhd` is 0. CKVMAP's own
comment above it states the conversion and the numbers, and the RTL agrees
with the comment.

### 4.2 The real 9B config, and its controls, on the clean baseline archive

`llama_top` built from `git archive 5a19f984`, `ghdl -r --stop-time=1ns`,
`C_KV_AXI` on:

```
BASELINE real_kv_map rc=0
addr_short rc=1
    ghdl-mcode:error: bound check failure at .../base/rtl/llama_top.vhd:3965
    ghdl-mcode:error: error during elaboration
overlap rc=1
    .../base/rtl/llama_top.vhd:4007:7:@0ms:(assertion failure): llama_top: the K and V KV
    regions overlap.  Each is 71303168 chunks of 16 bytes.
ceiling rc=0
```

`:3965` is `CHK_KV_FIT`, the negative-`natural` refusal. The 71,303,168 is
printed by the tool, not asserted from my arithmetic, which is the point of
printing it: `8 * 4 * 131072 * 17 = 71,303,168` confirms `C_LAY = 8`,
`C_NKVH = 4`, `REC_CH_C = 17` at this shape as a MEASUREMENT rather than the
inference CLOG2 had to settle for.

`ceiling` is `C_MAXPOS = 233,396`, the arena limit, also rc=0 -- so 131,072 is
not sitting on a boundary that a small change would push over.

### 4.3 `llama_top` was using two different `clog2` functions

```
rtl/llama_top.vhd:173   use work.util_pkg.clog2;
rtl/llama_top.vhd:196     VN_W : positive := maximum(13, clog2(region_max(SHAPE) + 1));   <- ENTITY: package clog2
rtl/llama_top.vhd:830   architecture rtl of llama_top is
rtl/llama_top.vhd:835     function clog2(n : natural) return natural is  ... while (2**v) < n ...
rtl/llama_top.vhd:866     constant CHK_VN_W : natural := VN_W - clog2(region_max(SHAPE) + 1);  <- ARCH: local clog2
```

`:196` is inside the entity's generic clause and cannot see an architecture
declaration; `:866` is in the architecture and cannot see past one. So
`CHK_VN_W` was comparing the output of the package function against the output
of the local function, both spelled `clog2(region_max(SHAPE) + 1)`. **Line
numbers in this file are not stable** -- CLOG2 watched the local `clog2` move
`:782` to `:789` to `:835` within an hour -- so identify these by content.

### 4.4 The equivalence bench: seven bodies, two oracles, one golden table

`tools/clog2top_equiv_tb.vhd`, run against `rtl/util_pkg.vhd` at HEAD:

```
GOLD  3099 Python-generated values, 7 bodies vs an out-of-VHDL oracle, ok
EXH   exhaustive 0..2**21 ok, 2097153 values, every body defined there
ZERO  n=0 -> pkg=0 shift=0 tg_new=0 top_old=0  (tg_old(0): bound check failure -- NOT CALLED)
ONE   n=1 -> pkg=0 tg_old=0 tg_new=0 micro_old=0 micro_new=0
DBL   2**30      = 1073741824 -> top_old=30 micro_old=30 pkg=30  (last value the doubling bodies survive)
DBL   2**30+1    = 1073741825 -> pkg=31 oracle=31 tg_new=31  (top_old/micro_old: overflow -- NOT CALLED)
DBL   natural'high = 2147483647 -> pkg=31 oracle=31 tg_new=31
RND   1048576 draws over 0..natural'high-1 ok
CLOG2TOP EQUIV: PASS
rc=0
```

The bodies are: the one deleted from `llama_top`; `hbm_tg`'s old and new;
`sim/micro`'s old and new; `util_pkg.clog2`; and the shift oracle. The old
bodies are called only on their own domains -- `top_old` and `micro_old` not
above `2**30`, `tg_old` not at 0 -- and above and below those the oracles are
the only witnesses.

The golden table is regenerated with:

```python
import random
random.seed(20260829)
def clog2(n):
    return 0 if n <= 1 else (n-1).bit_length()
```

over every `2**k +/- 1` for k=0..31, the arguments `llama_top` actually forms
(12,288 / 12,289 / 131,072 / 131,073 / 233,396 / 425,205,248 / 71,303,168 /
256 / the small head and layer counts), and 3,000 random draws.

### 4.5 Mutation teeth, 18 mutants

Every mutant is a single-token edit, run against a shortened bench (`2**17`
exhaustive, 8,192 random) so the sweep is the same shape and the run is 2.5 s.

| mutant | edit | verdict | first failure |
|---|---|---|---|
| A1_le | `top_old`: `(2**v) < n` -> `<= n` | **BITES** | `GOLD top_old n=1 got=1 want=0` |
| A2_step2 | `top_old`: `v := v + 1` -> `+ 2` | **BITES** | `GOLD top_old n=2 got=2 want=1` |
| A3_init1 | `top_old`: `v : natural := 0` -> `:= 1` | **BITES** | `GOLD top_old n=0 got=1 want=0` |
| A4_at131073 | `top_old`: +1 at exactly n=131073 | **BITES** | `GOLD top_old n=131073 got=19 want=18` |
| B1_nozero | `tg_new`: `if n <= 1` -> `if n <= 0` | NO BITE | equivalent, see below |
| B2_nominus | `tg_new`: `v := n - 1` -> `v := n` | **BITES** | `GOLD tg_new n=2 got=2 want=1` |
| B3_div3 | `tg_new`: `v := v / 2` -> `/ 3` | **BITES** | `GOLD tg_new n=3 got=1 want=2` |
| C1_nozero | `micro_new`: `if n <= 1` -> `if n <= 0` | NO BITE | equivalent, see below |
| C2_nominus | `micro_new`: `v := n - 1` -> `v := n` | **BITES** | `GOLD micro_new n=2 got=2 want=1` |
| C3_retplus | `micro_new`: `return r` -> `return r + 1` | **BITES** | `GOLD micro_new n=2 got=2 want=1` |
| D1_shift30 | oracle: `for r in 1 to 63` -> `1 to 30` | **BITES** | `GOLD shift n=1073741825 got=64 want=31` |
| D2_shiftgt | oracle: `p >= nn` -> `p > nn` | **BITES** | `GOLD shift n=2 got=2 want=1` |
| D3_goldbad | corrupt one entry of the Python table | **BITES** | `GOLD pkg n=1073741825 got=31 want=30` |
| E1_for30 | `util_pkg`: `for i in 1 to 31` -> `1 to 30` | **BITES** | `GOLD pkg n=1073741825 got=30 want=31` |
| E2_nominus | `util_pkg`: `m := n - 1` -> `m := n` | **BITES** | `GOLD pkg n=2 got=2 want=1` |
| F1_for32 | `util_pkg`: `for i in 1 to 31` -> `1 to 32` | NO BITE | equivalent, see below |
| F2_shift64 | oracle: `for r in 1 to 63` -> `1 to 64` | NO BITE | equivalent, see below |

**A4 is the row that justifies embedding the real argument values.** It is a
body that is correct everywhere except at exactly `clog2(C_MAXPOS + 1)` for
the one `C_MAXPOS` that matters. Exhaustive 0..2**17 misses it, the random
phase has a 1-in-2**31 chance of hitting it, and only the golden table's named
entry catches it. A bench that sweeps ranges but never asks "what does the
design actually call this with" would pass that mutant.

**D1, D3 and E1 land only above `2**30`**, which no old-vs-new differential
could reach, because that is precisely where the old bodies abort. This
reproduces TRACK CLOG2's M3 finding on a second, independently written bench.

**The four NO BITE mutants are equivalent, and the argument is short enough to
check by hand rather than by more testing.** B1 and C1: with `if n <= 0` the
mutant falls through at `n = 1` and computes `v := 0`, whose loop is a no-op
and whose result is 0 -- the same answer, and the guard still catches `n = 0`,
which is its only load-bearing job (it is what stops `v := n - 1` going to
-1). F1: `natural'high < 2**31`, so 31 halvings already take the worst case to
zero and the 32nd iteration runs with `m` already 0. F2: the same for the
shift oracle, where `2**63` already exceeds every `natural`. No test can
distinguish any of the four because there is nothing to distinguish.

### 4.6 The deletion moved nothing: 21 rows, base vs post

Both trees are `git archive 5a19f984`; `post` differs from `base` in
`rtl/llama_top.vhd` and nothing else (`diff -rq base/rtl post/rtl` names one
file). Same GHDL, same generics, run back to back.

```
base   default_9b           rc=0   peakRSS=  2202860 kB expect=ok    OK
base   regmax_short         rc=1   peakRSS=    44544 kB expect=fail  OK
base   regmax_edge_lo       rc=1   peakRSS=    44544 kB expect=fail  OK
base   regmax_edge_ok       rc=0   peakRSS=  2203020 kB expect=ok    OK
base   vn_w_short           rc=1   peakRSS=    44544 kB expect=fail  OK
base   vn_w_ok              rc=0   peakRSS=  2202980 kB expect=ok    OK
base   kv_nblk_bad          rc=1   peakRSS=   661216 kB expect=fail  OK
base   kv_nblk_ok           rc=0   peakRSS=  1260928 kB expect=ok    OK
base   kv_gran_bad          rc=1   peakRSS=   660580 kB expect=fail  OK
base   kv_addr_wrap         rc=1   peakRSS=   661068 kB expect=fail  OK
base   kv_addr_fits         rc=0   peakRSS=  1261064 kB expect=ok    OK
base   kv_overlap           rc=1   peakRSS=  1260880 kB expect=fail  OK
base   ctx_at_max           rc=0   peakRSS=  1261020 kB expect=ok    OK
base   ctx_one_short        rc=0   peakRSS=  1261044 kB expect=ok    OK
base   ctx_over_max         rc=1   peakRSS=   660948 kB expect=fail  OK
base   all_real             rc=0   peakRSS=  2518668 kB expect=ok    OK
base   real_kv_map          rc=0   peakRSS=  1261112 kB expect=ok    OK
base   real_kv_addr_short   rc=1   peakRSS=   661116 kB expect=fail  OK
base   real_kv_overlap      rc=1   peakRSS=  1261400 kB expect=fail  OK
base   real_kv_ceiling      rc=0   peakRSS=  1260964 kB expect=ok    OK
base   real_kv_ctx_over     rc=1   peakRSS=   660236 kB expect=fail  OK

post   default_9b           rc=0   peakRSS=  2202780 kB expect=ok    OK
post   regmax_short         rc=1   peakRSS=    44352 kB expect=fail  OK
post   regmax_edge_lo       rc=1   peakRSS=    44544 kB expect=fail  OK
post   regmax_edge_ok       rc=0   peakRSS=  2203160 kB expect=ok    OK
post   vn_w_short           rc=1   peakRSS=    44736 kB expect=fail  OK
post   vn_w_ok              rc=0   peakRSS=  2203348 kB expect=ok    OK
post   kv_nblk_bad          rc=1   peakRSS=   660992 kB expect=fail  OK
post   kv_nblk_ok           rc=0   peakRSS=  1261060 kB expect=ok    OK
post   kv_gran_bad          rc=1   peakRSS=   661236 kB expect=fail  OK
post   kv_addr_wrap         rc=1   peakRSS=   661028 kB expect=fail  OK
post   kv_addr_fits         rc=0   peakRSS=  1260868 kB expect=ok    OK
post   kv_overlap           rc=1   peakRSS=  1261076 kB expect=fail  OK
post   ctx_at_max           rc=0   peakRSS=  1261208 kB expect=ok    OK
post   ctx_one_short        rc=0   peakRSS=  1260972 kB expect=ok    OK
post   ctx_over_max         rc=1   peakRSS=   661112 kB expect=fail  OK
post   all_real             rc=0   peakRSS=  2518568 kB expect=ok    OK
post   real_kv_map          rc=0   peakRSS=  1261304 kB expect=ok    OK
post   real_kv_addr_short   rc=1   peakRSS=   660944 kB expect=fail  OK
post   real_kv_overlap      rc=1   peakRSS=  1261296 kB expect=fail  OK
post   real_kv_ceiling      rc=0   peakRSS=  1260964 kB expect=ok    OK
post   real_kv_ctx_over     rc=1   peakRSS=   660968 kB expect=fail  OK
```

21 for 21, identical verdicts, peak RSS within noise.

### 4.7 And it is not cosmetic: the row that separates base from post

A synthetic probe that pushes the CHUNK sum above `2**30`, the only region
where the two bodies differ. `C_K_BASE_CH=1073741824`,
`C_V_BASE_CH=1145044992`, `C_KV_ADDR_W=35`, `C_MAXPOS=131072`:

```
DERIVED: 1145044992 + 71303168 = 1216348160   2**30 = 1073741824   clog2 = 31 = 35 - 4

base  above_2**30_chunks  rc=1
      ghdl-mcode:error: overflow detected
      in process .llama_top(rtl).u_vres@seq_vec_res(rtl).strict_chk
        from: work.llama_top(rtl).clog2 at llama_top.vhd:838
      ghdl-mcode:error: error during elaboration
post  above_2**30_chunks  rc=0
```

`work.llama_top(rtl).clog2` -- the architecture's function, named by the tool,
which is the direct confirmation that the local declaration was the one being
called. This probe is a 35-bit byte address, i.e. 32 GiB, past the FK33's 8 GiB
of HBM; it is an elaboration probe for the guard, not a proposed map.

Note the attribution here is *worse* than the case CLOG2 documented: the
process named is `u_vres@seq_vec_res(rtl).strict_chk`, an unrelated bystander
that merely happens to be the elaboration point where the constant is forced.
The function is named correctly, the caller is not, and the process that is
named actively misleads.

### 4.8 `hbm_tg`: the `clog2(0)` bound check failure, before and after

Before (`git archive 5a19f984`, `hbm_tg` standalone):

```
--- AXI_DW=256 (default, BYTES_PER_BEAT=32) ---
rc=0
--- AXI_DW=4 (BYTES_PER_BEAT=0, the clog2(0) case) ---
rc=1
ghdl-mcode:error: bound check failure at .../base/rtl/hbm_tg.vhd:197
ghdl-mcode:error: error during elaboration
```

`:197` was `variable r : natural := 0; variable v : natural := n - 1;`. No
message, no name, and it points at a variable declaration inside a function
body rather than at the generic that is wrong.

After, the whole ladder:

```
AXI_DW=256  rc=0
AXI_DW=512  rc=0
AXI_DW=128  rc=0
AXI_DW=64   rc=0
AXI_DW=32   rc=0
AXI_DW=16   rc=0
AXI_DW=8    rc=0
AXI_DW=4    rc=1   rtl/hbm_tg.vhd:229
AXI_DW=1    rc=1   rtl/hbm_tg.vhd:229
```

with `:229` being `constant CHK_AXI_DW_MIN : natural := BYTES_PER_BEAT - 1;`,
so the name is on the line the error points at. `AXI_DW=8` is the boundary
(one byte per beat) and passes; `AXI_DW=4` is one step past it and refuses --
a pair, not a single row.

```
ghdl-mcode:error: bound check failure at .../rtl/hbm_tg.vhd:229
  from: work.hbm_tg(rtl).DECL_ELAB at hbm_tg.vhd:229
```

A `natural` that goes negative rather than an `assert ... severity failure`,
because Vivado silently ignores a failing severity-failure assert in synthesis
and a concurrent assert would run after the whole design has elaborated, far
too late for a constant.

### 4.9 Why the other four copies must stay local

```
$ grep -n "add_files" hw/fk33/build_fk33_hbmbw.tcl
327:add_files -norecurse $tgRoot/rtl/hbm_tg.vhd
328:add_files -norecurse $tgRoot/rtl/hbm_tg_ip.vhd
1086:add_files -fileset constrs_1 -norecurse $scriptPath/fk33_example.xdc
1090:add_files -norecurse ./$ProjectName/...bd_wrapper.v
```

Four `add_files` lines in the whole build, two of them from `rtl/`, and
`rtl/util_pkg.vhd` is not one of them. Contrast the endpoint build, which does
add it:

```
$ grep -n "util_pkg" hw/fk33/build_fk33_pcieep.tcl
187:add_files -norecurse /home/.../rtl/util_pkg.vhd
```

The hbmbw tcl is GENERATED (`hw/fk33/gen_hbmbw.py:211` emits those two
`add_files` lines), so the dependency could not be added from `rtl/` alone in
any case.

And the micro flow:

```
sim/run_micro.sh:27      run micro_c_lane micro/micro_c_lane.vhd
sim/run_micro_pnr.sh:24  micro/c_lane.vhd micro/micro_c_array.vhd
sim/ooc_micro.tcl:59     foreach f $files { read_vhdl -vhdl2008 [file normalize $f] }
```

One or two files, read exactly as handed, no package. Verified after the edit
that all three still analyse standalone:

```
sim/micro/c_lane.vhd            analyze rc=0  0 errors
sim/micro/c_lane_p.vhd          analyze rc=0  0 errors
sim/micro/micro_c_lane_sh.vhd   analyze rc=0  0 errors
```

### 4.10 TRACK CLOG2's 22-name homograph sweep, re-verified independently

Not read off its table -- re-derived by parsing the package declarative parts
(comments stripped) and every `function <name>(` in `rtl/`, `sim/`,
`sim/micro/` and `tb/`:

```
rtl/util_pkg.vhd: 2 exported functions: clog2 msb_pos
rtl/llama_map_pkg.vhd: 14 exported functions: att_kv att_q att_qg is_attn_block key_dim
    mk_shape mk_shape_scaled n_attn_blocks n_gdn_blocks n_steps qkv_dim region_max
    region_sizes val_dim
rtl/model_cfg_pkg.vhd: 6 exported functions: attn_layers d_inner gdn_layers
    gdn_sweep_cycles key_heads_per_card val_heads_per_card

TOTAL exported function names: 22

LOCAL DECLARATIONS OF AN EXPORTED NAME:

  clog2   package profile: (n : natural)
    rtl/hbm_tg.vhd:215  (n : natural)      -> same profile
    sim/micro/c_lane.vhd:53  (n : positive)         -> overload only
    sim/micro/c_lane_p.vhd:71  (n : positive)       -> overload only
    sim/micro/micro_c_lane_sh.vhd:62  (n : positive) -> overload only

  msb_pos   package profile: (v : integer)
    rtl/gdn_conv.vhd:178  (a : unsigned)             -> overload only
    rtl/gdn_head_emit.vhd:156  (a : unsigned)        -> overload only
    rtl/gdn_recur.vhd:228  (a : unsigned)            -> overload only
    rtl/gdn_recur_pipe.vhd:374  (a : unsigned)       -> overload only
    rtl/gdn_y_emit.vhd:126  (a : unsigned)           -> overload only
    sim/tb_gdn_conv_tvalid_skew.vhd:129  (a : unsigned) -> overload only
```

**CLOG2's sweep is CONFIRMED**, with two refinements. First, `llama_top` no
longer appears, which is this track's change. Second, "same profile" is not
the same claim as "hides the package one": `rtl/hbm_tg.vhd` has no
`use work.util_pkg` at all (its only use clauses are `ieee.std_logic_1164` and
`ieee.numeric_std`), so there is nothing there for it to hide. Shadowing needs
BOTH a matching profile AND the package made visible, and only `llama_top` ever
had both. A profile-only sweep over-reports; state the use clauses alongside.

My `msb_pos` line numbers differ from CLOG2's by one on three rows (178 vs
179, 374 vs 375, 129 vs 130) because I record the `function` line and it
recorded the following one. Same six sites.

### 4.11 `sim/realshape_gate.sh`, and a contention window that looked like a failure

Run on the WORKING TREE first, which is the wrong thing to do and is recorded
because it is the trap:

```
/home/.../rtl/attn_block.vhd:1027:50: no function declarations for operator "*"
/home/.../rtl/attn_block.vhd:1027:20: no function declarations for operator "+"
default_9b         rc=1   peakRSS=   15552 kB  wall=0.12   expect=ok
...
REALSHAPE GATE: FAIL  10 row(s)
```

Ten rows red, every one at ~15 MB peak RSS -- an ANALYSIS failure, not an
elaboration failure, which is the tell: a row that really elaborated `llama_top`
peaks at 660 MB to 2.6 GB. `rtl/attn_block.vhd` is TRACK WRITEDEC's file and
was mid-edit; `git archive HEAD` has different content at that line entirely.

Re-run on a clean `git archive 836b8025` -- HEAD at the time, carrying both of
this track's commits AND TRACK KVVALUE's `attn_kv_axi` fix:

```
kv_addr_wrap       rc=1   peakRSS=  661052 kB  wall=0.71   expect=fail
kv_addr_fits       rc=0   peakRSS= 1261248 kB  wall=1.44   expect=ok
kv_overlap         rc=1   peakRSS= 1261096 kB  wall=1.37   expect=fail
    llama_top.vhd:4023:7:@0ms:(assertion failure): llama_top: the K and V KV regions
    overlap.  Each is 2176 chunks of 16 bytes.
ctx_at_max         rc=0   peakRSS= 1261268 kB  wall=1.38   expect=ok
ctx_one_short      rc=0   peakRSS= 1261168 kB  wall=1.33   expect=ok
ctx_over_max       rc=1   peakRSS=  661000 kB  wall=0.70   expect=fail
all_real           rc=0   peakRSS= 2618920 kB  wall=2.34   expect=ok
real_kv_map        rc=0   peakRSS= 1261416 kB  wall=1.41   expect=ok
real_kv_addr_short rc=1   peakRSS=  661004 kB  wall=0.73   expect=fail
real_kv_overlap    rc=1   peakRSS= 1261284 kB  wall=1.35   expect=fail
    llama_top.vhd:4023:7:@0ms:(assertion failure): llama_top: the K and V KV regions
    overlap.  Each is 71303168 chunks of 16 bytes.
real_kv_ceiling    rc=0   peakRSS= 1261304 kB  wall=1.36   expect=ok
real_kv_ctx_over   rc=1   peakRSS=  660900 kB  wall=0.72   expect=fail

row  kv_map_manifest_link  ok    16 rows against tools/hbm_map.py and the manifest

REALSHAPE GATE: PASS  rows 25 (13 of them guards that must refuse)
```

**PASS 25, the number TRACK KVVALUE reports for this gate.** Zero rows moved by
this track, on the script that owns these rows rather than on my transcription
of its generic strings into a shell function -- which is why it was worth
running even after section 4.6 had already compared all 21 by hand.

And the declaration really is gone: the one `grep -n "function clog2"` hit left
in `rtl/llama_top.vhd` is at `:837`, inside the replacement comment.

### 4.12 Full regression, unfiltered

See section 9 for the last `OVERALL` line.

---

## 5. Measured and REJECTED -- do not retry

- **"Delete `rtl/hbm_tg.vhd`'s local `clog2` and fold it into `util_pkg`"**
  (CLOG2 section 9, and the CLOG2TOP brief). **REJECTED, measured.**
  `hw/fk33/build_fk33_hbmbw.tcl:327-328` is the entire `rtl/` fileset for that
  bitstream and `util_pkg.vhd` is not in it. The tcl is generated by
  `gen_hbmbw.py`, so the dependency cannot be added from `rtl/` alone either.
  Fixed in place instead. **Do not re-open this without changing
  `gen_hbmbw.py` in the same commit.**
- **"Delete the three `sim/micro` copies."** **REJECTED, measured, same
  reason.** `sim/run_micro.sh:27` passes one file and
  `sim/run_micro_pnr.sh:24` passes two to `sim/ooc_micro.tcl:59`, which reads
  exactly what it is handed. A `use work.util_pkg.clog2;` breaks every micro
  synthesis run.
- **"Rewrite the KV-fit guard against `clog2(unsigned)`"** (the CLOG2TOP
  brief). **DECLINED, measured.** The guard is in the CHUNK domain since
  CKVMAP's `9d287f2`; its argument at the real map is 425,205,248, which is
  inside `natural` and inside even the old body's `2**30` ceiling. Rewriting it
  would trade a working negative-`natural` refusal for an `unsigned` one that
  has to reinvent that refusal, and buy nothing. Revisit only if a future map
  pushes the CHUNK sum past `2**30` -- section 4.7 is the probe that shows what
  that looks like.
- **"`C_MAXPOS = 131,072` does not elaborate and this track must make it."**
  **REJECTED: it already did, at the baseline sha, before any change here.**
  Section 4.2. The premise came from CLOG2's correction #3, which was measured
  on the pre-CKVMAP byte-domain tree.
- **Changing `C_MAXPOS`'s default from 4 to 131,072.** NOT DONE, and
  deliberately. CKVMAP's reason still holds and is independent of everything
  above: with `C_KV_AXI` false the `gkvmem` generate declares
  `kvhdr(0 to C_LAY*2*C_NKVH*C_MAXPOS-1)` and
  `kvmem(0 to C_LAY*2*C_NKVH*C_MAXPOS*C_NBLK-1)`, which at 131,072 is 8.4M and
  67M signal entries. The real map is a build configuration, not a default.
- **Hand-editing the three `ip_repo/*/src/util_pkg.vhd` copies.** REJECTED,
  same as CLOG2 -- they are generator outputs. But see the correction in
  section 8: the claim that "the next packaging run fixes them" is a claim
  about a run that nothing schedules.

---

## 6. Measurement traps hit, including my own

- **HEAD moved between reading the brief and taking the baseline.** The brief
  was written at `51323ca`; `git rev-parse HEAD` as its own step returned
  `5a19f984`. Everything here is pinned to the latter. Read the sha, do not
  infer it.
- **The working tree was not attributable at any point during this track.**
  `diff -rq base/rtl rtl` showed `attn_block.vhd`, `attn_kv_axi.vhd` and
  `gdn_block.vhd` all differing from the baseline archive, from three other
  running tracks. Measuring "before and after" in the working tree would have
  attributed their edits to mine. Every base-vs-post row in section 4.6 is
  `git archive` plus exactly one file copied in.
- **A `bound check failure` reports the line of the DECLARATION, not of the
  call.** `hbm_tg.vhd:197` was `variable v : natural := n - 1`, which is where
  the value goes out of range, and says nothing about `AXI_DW`. The negative-
  `natural`-constant idiom fixes this only because the constant's NAME is on
  the line the error points at. The idiom is worthless if the name is bad.
- **`overflow detected` can name an unrelated process.** Section 4.7:
  `in process .llama_top(rtl).u_vres@seq_vec_res(rtl).strict_chk` is the
  elaboration point that first forces the constant, not the code that is
  wrong. The `from:` line is the trustworthy half.
- **My own bench had a hole that only a mutant found.** The first version
  swept ranges and boundaries but embedded none of the values `llama_top`
  actually forms. Mutant A4 -- a body correct everywhere except at exactly
  `clog2(131073)` -- passed it. Coverage of a range is not coverage of the
  call sites in the range. Fixed by naming the real arguments in the golden
  table; A4 bites afterwards.
- **`ghdl -a` prints `warning: declaration of "n" hides variable "n"` and
  still returns 0.** A procedure parameter shadowing an outer variable in the
  bench was harmless here but is the same defect class the whole track is
  about, so it was renamed rather than left. Read the warnings.
- **A 2-minute tool timeout is shorter than this bench.** The full bench is
  1m58s and the install-and-run in one command hit the wall at exactly that;
  the analysis had succeeded and the run had not started. Split the analyse
  and the run, and read `rc` from the step you mean.
- **I ran two full gates at once, and it was my error.** A first full gate was
  launched with `nohup ... &`, its log stopped at the five-line header, and I
  concluded it had died -- so I launched a second. It had not died: `regress.sh`
  writes per-row results into `$REGRESS_SCRATCH/res.*` and prints its table only
  at the END, so an empty-looking log is indistinguishable from a dead run.
  MEASURED: the "dead" run was at 43 result files while the replacement was at
  26. Count `res.*`, do not read the log. The second run was stopped and the
  first allowed to finish. This is exactly the "do not run two heavy gates
  concurrently" instruction, broken by me, and the machine had a third
  (TRACK KVVALUE's) and a fourth (TRACK WRITEDEC's, since completed) in flight
  at the same time.
- **TRACK WRITEDEC's queued gate waits on `pgrep -f "regress.sh --only
  llama_top"`.** My own targeted `--only llama_top` run therefore held their
  full gate for its duration. Not damage, but a real coupling: a `pgrep -f`
  gate on a shared script name serialises against every other track that runs
  the same command, and neither side can see the other.
- **`git status --cached` is not a thing** (it is `git diff --cached`). It
  errors out rather than silently reporting nothing, so it cost only a line,
  but a gate you believe you ran and did not is the worst kind.

---

## 7. What was NOT verified

- **No Vivado synthesis was run on any of this**, because TRACK WRITEDEC held
  Vivado for the whole track and three GHDL gates were already in flight. What
  can be said without it is DERIVED, not MEASURED, and it is worth stating
  precisely because there is a real hazard here.

  **The hazard: `util_pkg.clog2` deliberately uses a bounded FOR and not a
  `while`, because "a `while` on a runtime integer trips Vivado's
  2000-iteration loop-convergence guard"** (CLOG2 section 4.4, and the same
  note is in `util_pkg`'s own `msb_pos`). The bodies this track put into
  `hbm_tg` and the three `sim/micro` files are `while v > 0 loop v := v / 2`.

  **The argument that they are safe.** The guard is about loops whose trip
  count the elaborator cannot bound. Every call here is on an elaboration-time
  constant -- `clog2(BYTES_PER_BEAT)` from a generic, `clog2(ACC_N)` from a
  generic -- so the loop is fully evaluated at elaboration and terminates in at
  most 31 iterations, three orders of magnitude under the guard. And
  `rtl/hbm_tg.vhd` ALREADY had a `while v > 0` halving body before this track
  touched it, in the shipped hbmbw bitstream, so that exact shape is known to
  synthesise for that exact call; the only change to it is an `n <= 1` early
  return, which cannot affect convergence. The `sim/micro` change swaps a
  `while` doubling loop for a `while` halving loop, same call, same bound.

  **What that argument does not cover, and what would settle it:**
  `bash sim/run_micro.sh c` and `bash sim/run_micro_pnr.sh` on a quiet box.
  Until then the micro files' new bodies have not been through the OOC flow
  they exist to feed.
- **The behavioural KV cache (`C_KV_AXI` false) was never elaborated at
  `C_MAXPOS = 131,072`.** Every KV row here has `C_KV_AXI` true. The
  `gkvmem` path at that depth needs 8.4M and 67M signal entries and was not
  attempted; whether it merely takes hours or actually fails is unmeasured.
- **`REC_CH_C = 17` and `C_LAY * C_NKVH = 32` are MEASURED at the shape those
  rows run** (printed by the overlap assert, section 4.2), but the shape is a
  record generic GHDL cannot override, so they are measured for the compiled-in
  `SHAPE` and not swept.
- **Nothing here checks a VALUE.** Every row is an elaboration. `real_kv_map`
  passing means the bounds are legal at 131,072; it does not mean a token
  written at position 131,071 is read back. That is TRACK KVVALUE's oracle and
  it is the thing that would actually close this.
- **The `ip_repo` copies were not regenerated**, so a build straight from
  `ip_repo` still uses the pre-`209d69e` doubling body.

---

## 8. Corrections to earlier documents

**CORRECTION 1, to `docs/debugging/2026-08-29_clog2-overflow.md` section 2,
correction #3.** The claim *"Fixing `clog2` does not unblock
`C_MAXPOS = 131072`, and cannot"*, and the arithmetic that supports it, are
**WITHDRAWN as statements about the current tree**. They were measured against
the byte-domain KV guard, which TRACK CKVMAP replaced with a chunk-domain one
at `9d287f2` -- landing at 19:11:31, during CLOG2's own gate run. `KVREG_B`
does not exist in `rtl/llama_top.vhd`. The real map elaborates at
`C_MAXPOS = 131,072` (section 4.2). The withdrawn text is left in place there
per the append-never-delete rule; this is the dated correction that supersedes
it. Its section 6.1 constant `K = 17408` remains correct as a property of the
byte-domain file at the time, and is superseded rather than wrong -- the chunk
form makes the same quantity 16x smaller.

**CORRECTION 2, to the same file's section 9 and to the CLOG2TOP brief.** The
recommendation to fold `rtl/hbm_tg.vhd:196` and the three `sim/micro` copies
into `util_pkg` and delete them is **wrong**, and the reason is measurable in
one grep per flow (section 4.9). Both are deliberately dependency-free designs
whose build scripts hand the tool an explicit, short file list.

**CORRECTION 3, to the same file's section 5 and section 9.** *"they are
refreshed by the next packaging run"* and *"the next packaging run fixes
them"* overstate what is scheduled. MEASURED:
`grep -rn "package_llama_ip" --include=*.sh --include=*.tcl --include=*.py .`
matches only the script itself and CLOG2's own write-up. **No gate, no script
and no CI step ever runs `ip_repo/package_llama_ip.tcl`**, and
`sim/regress.sh` does not mention `ip_repo` at all. The three copies are
git-tracked source that drifts from `rtl/` with nothing to catch it -- they
already differ from the old `rtl/util_pkg.vhd` in `msb_pos` as well, so they
were regenerated at least once and then left. The decision not to hand-edit
them is still right; the expectation that they self-heal is not.

**CONFIRMATION, independent and concurrent.** TRACK KVVALUE
(`6c9aa09`, `e366335`, `662b247`, `ef1aa7e`) reached corrections 1 and 2's
first half by a different route and at a different sha while this track was
running: `grep -n "KVREG_B" rtl/llama_top.vhd` empty at `bdc998c`, `KVREG_CH`
= 71,303,168, and `real_kv_map` rc=0 on a clean archive with nothing changed.
Two tracks, two archives, two shas, same answer. Recorded as a separate
confirmation rather than folded into correction 1, because the value of it is
that it was independent -- neither track saw the other's measurement first.

**CORRECTION 5, to the CLOG2TOP brief.** *"`llama_top` holds the base in
16-byte chunks and shifts left by 4 at the instantiation"* is correct, and I
record only that the shift is at `KBASE_C`/`VBASE_C` in the declarative part
rather than in the port map itself -- `llama_top` has a standing rule of NO
EXPRESSIONS IN THE PORT MAP (GHDL 1.0 mcode raised `TYPES.INTERNAL_ERROR :
trans.adb:553` on an actual that was an expression). The seam is one shift
wide either way and `attn_kv_axi` is untouched, exactly as the brief says.
TRACK KVVALUE separately verified the actual port map expression,
`shift_left(to_unsigned(C_K_BASE_CH, C_KV_ADDR_W), 4)` into `k_base`, as exact.

---

## 9. Full regression

Run against the WORKING TREE starting 20:03:06 and finishing after
TRACK WRITEDEC landed `bfdae6b` mid-run, `--keep`, `REGRESS_SCRATCH` under this
track's own scratch directory. `BASELINE_PASS` read out of `sim/regress.sh:403`
at gate time: **93**. Last `OVERALL` block, verbatim and unfiltered:

```
 suite sim   PASS 74   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 100   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 100 passing, above the floor of 93 -- but this tree has rows a clean checkout
 does not get: [20 rows listed]  DO NOT raise BASELINE_PASS from this run
 REGRESSION: PASS
```

**Zero rows moved.** `BASELINE_PASS` untouched, and the run's own advice against
raising it from a dirty tree is followed. CLOG2's run at `1216a5e` was PASS 99; the one
extra sim row is `sim:tb_attn_kv_map`, which
`git diff --name-status 1216a5e..HEAD -- 'sim/tb_*.vhd'` shows as the only
`A` between the two runs. It is TRACK KVVALUE's, not mine. (I first wrote
`sim:tb_check_kv_map` here from memory of the coordinator's relay, which
mentioned a `check_kv_map.py` row in `realshape_gate.sh` -- a different gate
and a different artefact. Corrected by `ls`ing the result files rather than
by recalling a name.)

`sim:tb_llama_top_seq` PASS in 308 s and all six `tb_llama_top*` rows,
`sim:tb_hbm_tg`, `sim:tb_attn_block` and `sim:tb_realshape_9b` green -- the rows
whose closure contains the four files this track edited.

**This run is NOT the attributable evidence and is not offered as such.** It
straddles TRACK WRITEDEC's `attn_block.vhd` edit, which was analysis-broken in
the working tree at 20:09 (section 4.11) and committed at 20:12. It came out
green, which is a useful negative result and nothing more. The attributable
evidence is section 4.6 (21 rows, base vs post, one file different) and section
4.11's clean-archive `REALSHAPE GATE: PASS rows 25`.

---

## 10. Open, not answered

- **Does the behavioural KV cache elaborate at `C_MAXPOS = 131,072`?**
  Unmeasured; 8.4M + 67M signal entries. It is not on any path to the
  bitstream, since the real map requires `C_KV_AXI`.
- **Are `hbm_tg`'s and `sim/micro`'s new bodies synthesisable on the real
  part?** Same shape as the one CLOG2 put through Vivado, but not run here.
- **The `ip_repo` copies still carry the pre-`209d69e` doubling body**, and
  nothing regenerates or checks them (correction 3). Either add a packaging
  step to a gate, or add a gate row that diffs `ip_repo/*/src/util_pkg.vhd`
  against `rtl/util_pkg.vhd` and fails on drift. Neither was done here: both
  touch files this track does not own.
- **`.claude/worktrees/agent-a11967714803641b5/`** contains a full stale copy
  of the repo at an older sha, with the old `clog2` bodies in it. It is
  outside the repo tree and was not touched; noted only because it makes
  `grep -rn "function clog2"` over the whole directory report doubles.
- **`msb_pos(unsigned)` comes in two variants** (`p := i` versus
  `p := i - a'low`) across the six local declarations, which disagree for any
  vector whose low index is not 0. Carried forward from CLOG2's sweep,
  confirmed present, out of scope for both tracks, and still nobody's.
