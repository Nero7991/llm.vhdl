# `clog2` overflows above 2**30, and the reported wall is not where it was thought to be

TRACK CLOG2, 2026-08-29. Repo `llama.vhdl`, branch `fpga`. HEAD when this work
started: `8889cfa2714c166e96eca682a630dd8b6beecc9e`. HEAD when the gate
finished and this was committed: `1216a5e299b3b88c475e931dbd4566fb5e0bc38d`.
Both read with `git rev-parse HEAD` as its own step; other tracks landed
between the two and none of them touch `rtl/util_pkg.vhd`.

Tools: GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6) [Dunoon edition], mcode backend.
Machine at the start of the run: root `/` 1.3T, 39G free, 97% used;
`/mnt/storage` 388G free; RAM 31G total, 20G available, 6G of 31G swap in use;
load average 8.40 with a Vivado synthesis already running.

---

## 1. The question, verbatim

From the TRACK CLOG2 brief, quoting TRACK CGENERICS (`8889cfa`):

> **`util_pkg.clog2` is a `while v < n loop v := v*2` doubling loop over
> `natural`, so it overflows above 2**30.** `llama_top:3812` / `:3834` call it
> on `maximum(C_K_BASE, C_V_BASE) + KVREG_B`. Bisected: with `C_K_BASE = 0` the
> largest `C_MAXPOS` this file accepts is **61,680** (rc=0); **61,681 dies with
> `overflow detected ... from clog2 at llama_top.vhd:785`, a line that has
> nothing to do with the KV map.** The map needs 131,072.

And the job: fix the overflow, make the diagnostic attributable, audit the
whole class, and prove exactness at the boundaries.

---

## 2. The answer, up front

**The overflow is real and is now fixed in `rtl/util_pkg.vhd`.** The doubling
body was correct for `n <= 2**30` and aborted elaboration for every `n` above
it. The new body halves `n-1` instead of doubling toward `n`, so the working
value only ever decreases and no intermediate can leave `natural`. It is
equivalent to the old body everywhere the old body was defined
(MEASURED: 2,097,153 exhaustive values, 93 boundary values, 523,978 random
draws, zero mismatches) and correct against an independent shift-based oracle
over the whole of `natural`.

**But three things in the quoted question are wrong, and the third one matters
more than the fix.**

1. **The function that failed at `llama_top:3812`/`:3834` is not
   `util_pkg.clog2`.** `architecture rtl of llama_top` declares its *own*
   `clog2` at lines 782-787, of a *different* shape
   (`while (2**v) < n loop v := v + 1`), which hides the selective
   `use work.util_pkg.clog2;` at line 173 for the entire architecture.
   **Fixing `util_pkg` does not change `llama_top`'s behaviour at all.**
   `rtl/llama_top.vhd` is another track's file, so the drop-in replacement is
   handed over in section 7 rather than applied here.

   **The bisect numbers survive this correction unchanged**, and that is worth
   stating because it is the natural next worry. MEASURED separately for both
   bodies (4.2, 4.3): `while (2**v) < n loop v := v+1` and
   `while v < n loop v := v*2` break at **exactly the same threshold**, `2**30`,
   because both need `2**31` for the first time at `n = 2**30 + 1`. So
   61,680 passing and 61,681 failing is the correct boundary for either
   function, and the constant `K = 17408` derived from it in section 6.1 stands.
   What the threshold cannot do is tell you *which* function overflowed; only
   the qualified name in the tool's message does that.

2. **The diagnostic does not blame a bystander.** `llama_top:785` *is* the
   failing line: it is the `while (2**v) < n loop` inside that local `clog2`.
   The message names the failing function correctly. What it does not name is
   the *caller*, and in a 4,000-line file a function body 3,000 lines away from
   the constant you are editing reads as unrelated. The defect is missing
   caller attribution, not misattribution.

3. **Fixing `clog2` does not unblock `C_MAXPOS = 131072`, and cannot.**
   At that shape the argument is
   `max(C_K_BASE, C_V_BASE) + KVREG_B = 6,803,283,968`, which exceeds
   `natural'high = 2,147,483,647` by a factor of 3.2. It cannot be *formed* as
   a `natural`, let alone measured by one. `2**31` is a ceiling of the integer
   type, not of the loop, and no rewrite of `clog2(natural)` lifts it. With a
   perfect `clog2(natural)` the ceiling moves from `C_MAXPOS = 61,680` only to
   **123,361**, still short of 131,072 (DERIVED, section 6). Worse, at 131,072
   the overflow moves *earlier*, to `llama_top:3873`'s own
   `constant KVREG_B : natural := C_LAY*C_NKVH*C_MAXPOS*REC_B_C`, which is
   2,281,701,376 and overflows before `clog2` is reached.

   So `rtl/util_pkg.vhd` gains a second overload,
   **`clog2(u : unsigned) return natural`**, which is the actual escape hatch:
   the caller builds the quantity as an `unsigned` of whatever width it needs
   and never forms a 32-bit intermediate. MEASURED end to end on the real
   value: `clog2` of `6,803,283,968` returns **33**, which is exactly
   `C_KV_ADDR_W`, corroborating CGENERICS' zero-slack finding from an
   independent direction.

---

## 3. The procedure, in the order it was run, and what each step isolates

1. **Locate every `clog2` in the tree**, not just the one named.
   `grep -rn "function clog2" --include=*.vhd`. This is what found the
   architecture-local copy in `llama_top` and four more. Isolates: *is the
   named file actually the one that runs?*
2. **Read the enclosing declarative region** of `llama_top:782` and the use
   clauses at the top of the file. Isolates: *does the local declaration
   shadow the package one?* (Architecture declarative part vs a selective
   `use` clause: the explicit declaration wins.)
3. **Reproduce both bodies standalone**, in a scratch design, with the
   argument as a generic so it can be swept. Two separate reproducers: one
   with the `llama_top`-shaped local `clog2` shadowing a package `clog2`, one
   with only the package one. Isolates: *which body produces the reported
   message, and at what threshold?*
4. **Write the new body**, then **an independent oracle that does not loop** --
   the defining inequality `2**(r-1) < n <= 2**r` evaluated with 64-bit
   unsigned shifts. Isolates: *a shared bug between a halving loop and a
   doubling loop.* Comparing two loops against each other would not.
5. **Equivalence bench**: exhaustive 0..2**21, all `2**k-1 / 2**k / 2**k+1`
   for k=0..30, 2**20 random draws over the full `natural` range, the four
   named values, and the real out-of-`natural` KV extent. The old body is
   called only where it is defined (`n <= 2**30`); above that the oracle is the
   only witness, which is the entire reason for having one.
6. **Mutation teeth on the new bodies**, 12 mutants, each a single-token edit
   to `rtl/util_pkg.vhd`. Isolates: *does the bench have any resolution at
   all?* This is what caught a coverage hole in my own bench (section 6).
7. **Audit every other function in the utility packages** for a 32-bit
   accumulator, by grepping the package bodies for `*` and `**` and reading
   each hit with its real configured operands.
8. **Vivado 2023.2 synthesis of both bodies** on a probe whose port widths are
   the answers, with the project's out-of-range-`natural` elaboration guard,
   plus the same probe against the old body. Isolates: *does the fix survive
   the tool that actually consumes it, and was the defect ever live there?*
9. **Full `sim/regress.sh`**, unfiltered, because `util_pkg` is in 78 files'
   analysis closure and a new overload can create ambiguity anywhere.

---

## 4. Evidence, as raw output

### 4.1 There are six `clog2` bodies in this tree, of four different shapes

```
rtl/util_pkg.vhd:8                      variable v : natural := 1;  while v < n loop v := v*2;    r := r+1
rtl/llama_top.vhd:782                   variable v : natural := 0;  while (2**v) < n loop v := v + 1
rtl/hbm_tg.vhd:196                      variable v : natural := n-1; while v > 0 loop r := r+1; v := v/2
sim/micro/c_lane.vhd:38                 function clog2(n : positive)  while v < n loop v := v*2
sim/micro/c_lane_p.vhd:56               (same as c_lane)
sim/micro/micro_c_lane_sh.vhd:47        (same as c_lane)
ip_repo/{llama_engine_axi,matvec_engine,mac_axi}_1_0/src/util_pkg.vhd
                                        copies of the old rtl/util_pkg.vhd body
```

### 4.2 The local copy in `llama_top` shadows the package one

**Line numbers in `llama_top.vhd` are not stable and should not be quoted.**
The local `clog2` was at `:782` when this track read the file, at `:789` when
TRACK CKVMAP measured it independently a few minutes later, and at `:835` after
CKVMAP landed `9d287f2`. Identify it by content, not by line. As read here:
line 173 is `use work.util_pkg.clog2;`, line 777 opened
`architecture rtl of llama_top is`, and the function was, verbatim:

```vhdl
  function clog2(n : natural) return natural is
    variable v : natural := 0;
  begin
    while (2**v) < n loop v := v + 1; end loop;
    return v;
  end function;
```

Line **785** is the `while`. Reproduced with the same nesting (scratch
`repro.vhd`, a package `clog2` made visible by a use clause and an
architecture-local `clog2` declared over it):

```
--- N=2**30 (expect ok, and which clog2 answers) ---
repro.vhd:14:5:@0ms:(report note): N=1073741824 clog2=30
rc=0
--- N=2**30+1 (expect the reported failure) ---
/usr/bin/ghdl-mcode:error: overflow detected
  from: work.repro(rtl).clog2 at repro.vhd:8
/usr/bin/ghdl-mcode:error: error during elaboration
rc=1
```

`work.repro(rtl).clog2` -- the *architecture's* function, not the package's.
`repro.vhd:8` is the `while (2**v) < n` line, the exact analogue of
`llama_top.vhd:785`. The package `clog2` is never called.

### 4.3 The package body fails at the same threshold, on its own

```
--- util_pkg.clog2 N=1073741824 ---
repro2.vhd:6:17:@0ms:(report note): N=1073741824 clog2=30
rc=0
--- util_pkg.clog2 N=1073741825 ---
/usr/bin/ghdl-mcode:error: overflow detected
  from: work.upkg.clog2 at repro_pkg.vhd:9
/usr/bin/ghdl-mcode:error: error during elaboration
--- util_pkg.clog2 N=2147483647 ---
/usr/bin/ghdl-mcode:error: overflow detected
  from: work.upkg.clog2 at repro_pkg.vhd:9
/usr/bin/ghdl-mcode:error: error during elaboration
```

Both shapes break at exactly `2**30`, so the threshold alone cannot tell them
apart; only the qualified name in the message can. That is why step 1 of the
procedure is "find every copy" and not "read the one that was named".

### 4.4 The fix, and the equivalence run

`rtl/util_pkg.vhd`, new bodies:

```vhdl
  function clog2(n : natural) return natural is
    variable m : natural;
    variable r : natural := 0;
  begin
    if n <= 1 then return 0; end if;
    m := n - 1;
    for i in 1 to 31 loop
      if m > 0 then m := m / 2; r := r + 1; end if;
    end loop;
    return r;
  end function;

  function clog2(u : unsigned) return natural is
    alias    uu  : unsigned(u'length-1 downto 0) is u;
    variable hi  : integer := -1;
    variable cnt : natural := 0;
  begin
    if u'length = 0 then return 0; end if;
    for i in 0 to uu'high loop
      if uu(i) = '1' then hi := i; cnt := cnt + 1; end if;
    end loop;
    if hi < 0  then return 0;      end if;
    if cnt = 1 then return hi;     end if;
    return hi + 1;
  end function;
```

`31` is exact and not a guess: `natural'high < 2**31`, so 31 halvings take
`natural'high - 1` to zero. A bounded FOR rather than a `while`, for the same
reason `msb_pos` in the same file already uses one -- a `while` on a runtime
integer trips Vivado's 2000-iteration loop-convergence guard.

`tools/clog2_equiv_tb.vhd`, run against `rtl/util_pkg.vhd`:

```
clog2_equiv_tb.vhd:110: EXHAUSTIVE 0..2**21 ok, 2097153 values
clog2_equiv_tb.vhd:141: BOUNDARIES 2**k-1/2**k/2**k+1, k=0..30 ok, 93 values
clog2_equiv_tb.vhd:150: 2**30      = 1073741824 -> clog2 = 30  (old body: LAST VALUE IT SURVIVES)
clog2_equiv_tb.vhd:154: 2**30+1    = 1073741825 -> clog2 = 31  (old body: overflow, elaboration aborted)
clog2_equiv_tb.vhd:158: natural'high = 2147483647 -> clog2 = 31  (old body: overflow, elaboration aborted)
clog2_equiv_tb.vhd:183: KVREG_B    = x0000000088000000
clog2_equiv_tb.vhd:185: KV extent  = x000000019581E000
clog2_equiv_tb.vhd:196: REAL 9B KV extent 6803283968 -> clog2 = 33  (C_KV_ADDR_W = 33, zero slack)
clog2_equiv_tb.vhd:206: 2**33-1 -> 33, 2**33 -> 33, 2**33+1 -> 34
clog2_equiv_tb.vhd:251: WIDTH SWEEP w=1..13 exhaustive ok, 16382 values; top-bit-set 64-bit and null range ok
clog2_equiv_tb.vhd:280: RANDOM full-range ok, 1048576 draws, 523978 of them also checked against the old body
clog2_equiv_tb.vhd:283: CLOG2 EQUIV: PASS  exhaustive=2097153 boundary=93 random=1048576
rc=0
```

`x0000000088000000` = 2,281,701,376 = `KVREG_B` at `C_MAXPOS = 131072`.
`x000000019581E000` = 6,803,283,968 = the full KV extent. Both printed by the
tool rather than asserted from my arithmetic, which is the point of printing
them.

The bench lives in `tools/`, **deliberately not** `sim/` or `tb/`:
`sim/regress.sh` globs `sim/tb_*.vhd` and `tb/tb_*.vhd` for gate rows and
`rtl,sim,sim/micro,tb/*.vhd` for its analysis closure, and `tools/` is in none
of them. It therefore adds no gate row and `BASELINE_PASS` is untouched. Run it
by hand; the header of the file carries the command.

### 4.5 Mutation teeth

Every mutant is a single-token edit to a copy of `rtl/util_pkg.vhd`, run
against the bench with the random sweep shortened to 8,192 draws.

| mutant | edit | verdict | first failure |
|---|---|---|---|
| M1 | `if n <= 1` -> `if n <= 2` | **BITES** | EXH old/new, n small |
| M2 | `m := n - 1` -> `m := n` | **BITES** | EXH old/new |
| M3 | `for i in 1 to 31` -> `1 to 30` | **BITES** | **BND oracle only** |
| M4 | `m := m / 2` -> `m := m / 3` | **BITES** | EXH old/new |
| M5 | `return r` -> `return r + 1` | **BITES** | EXH old/new |
| M6 | `for i in 1 to 31` -> `1 to 32` | NO BITE | -- |
| M7 | `if n <= 1` -> `if n < 1` | NO BITE | -- |
| U1 | `if cnt = 1` -> `if cnt = 2` | **BITES** | `EXH unsigned/natural mismatch at n=1 uns=1 nat=0` |
| U2 | `return hi + 1` -> `return hi` | **BITES** | `EXH unsigned/natural mismatch at n=3 uns=1 nat=2` |
| U3 | `if hi < 0` -> `if hi < 1` | NO BITE | -- |
| U4 | `for i in 0 to uu'high` -> `uu'high-1` | NO BITE, then **BITES** | see below |
| U5 | null-range branch returns 1 not 0 | NO BITE, then **BITES** | see below |

**M3 is the most valuable row.** Shortening the loop to 30 iterations is
invisible to the exhaustive phase and to every value the *old* body could
reach; it is caught only by the boundary phase, at `n > 2**30`. A bench built
solely as "old vs new" -- the obvious thing to build for a refactor -- would
have passed a `clog2` that is wrong in exactly the region this whole track
exists to fix.

**M6, M7 and U3 are equivalent mutants, not resolution-floor gaps**, and the
argument is short enough to check by hand rather than by more testing:
M6's 32nd iteration runs with `m` already 0 and is a no-op; M7 differs from the
original only at `n = 1`, where `m := 0` makes the loop a no-op and the result
is 0 either way; U3 differs only at `hi = 0`, i.e. `u = 1`, whose answer is 0
either way. No test can distinguish them because there is nothing to
distinguish.

**U4 and U5 were genuine holes in my own bench, and the mutation run is the
only thing that found them.** Every unsigned fed in was either
`to_unsigned(n,32)` with `n <= 2**31-1` (bit 31 always clear) or a 64-bit value
under 2**34 (bit 63 always clear), and no null range was ever passed. So the
top bit of the containing vector was never set in any test case, and dropping
it from the scan changed nothing. Coverage of the *value* space was not
coverage of the *vector* space. Fixed by adding an exhaustive sweep of every
value at every width 1..13 (16,382 cases, top bit set in half of them), the
64-bit top-bit values, and a genuine null slice. Both mutants bite afterwards:

```
U4_lastbit  BITES   :: WIDTH mismatch w=2 v=2 uns=0 nat=1
U5_nullret  BITES   :: null-range unsigned wrong
```

### 4.6 Vivado, both bodies, on the real part

GHDL is not the tool that matters for a function that sizes ports, so both
bodies were put through **Vivado 2023.2 synthesis** (`xczu3eg-sfvc784-1-e`,
`-mode out_of_context`) on a probe entity whose two port widths are
`clog2(natural'high)` and `clog2(<the 6.8 GB KV extent as a 128-bit unsigned>)`,
with the project's out-of-range-`natural` idiom as an elaboration guard
(Vivado silently ignores `assert ... severity failure`).

New body:

```
CLOG2_SYNTH_PROBE: width(d)=31  width(u)=33   expect 31 and 33
CLOG2_SYNTH_PROBE: PASS
rc=0
```

So Vivado elaborates the bounded FOR body, the `unsigned` overload, and a
128-bit constant expression, and gets 31 and 33 -- the same answers GHDL gives.

**Teeth on that probe** (claim 32 where the answer is 33):

```
ERROR: [Synth 8-11323] assigned value '-1' out of range [.../probe_bad.vhd:20]
ERROR: [Synth 8-285] failed synthesizing module 'clog2_synth_probe' [.../probe_bad.vhd:11]
ERROR: [Common 17-69] Command failed: Vivado Synthesis failed
rc=1
```

The guard fires. A probe that cannot fail proves nothing.

**The OLD body, same probe** (`git show 8889cfa:rtl/util_pkg.vhd`):

```
ERROR: [Synth 8-11585] Evaluated value has exceeded beyond integer type range [.../util_pkg_old.vhd:11]
ERROR: [Synth 8-11323] assigned value '2147483648' out of range [.../util_pkg_old.vhd:11]
ERROR: [Synth 8-285] failed synthesizing module 'clog2_synth_probe' [.../probe_old.vhd:9]
rc=1
```

Two things worth recording. First, **the defect was live in synthesis, not only
in simulation** -- `util_pkg_old.vhd:11` is the `while v < n loop v := v*2`
line. Second, Vivado **errors rather than silently wrapping**, and its message
is actually the better of the two: it names the offending value, `2147483648`.
It still points at the function body and not at the caller, which is the same
attribution gap GHDL has.

### 4.7 Audit of the rest of the utility packages

Grepped every `rtl/*_pkg.vhd` body for `*` and `**` and read each hit with its
real configured operands.

| site | expression | worst configured value | verdict |
|---|---|---|---|
| `rtl/util_pkg.vhd:11` (old) | `v := v*2` | 2**31 | **THE DEFECT, fixed** |
| `rtl/model_cfg_pkg.vhd:148` | `head_dim*head_dim*val_heads/lanes` then `* gdn_layers` | 27B, N=1, LANES=1: `128*128*48 = 786,432`, `* 48 = 37,748,736` | safe, 57x headroom |
| `rtl/llama_map_pkg.vhd:281..296` | head counts times head dims | low thousands | safe |
| `rtl/llama_map_pkg.vhd:346` | `n_gdn*16 + n_attn*13` | low hundreds | safe |
| `rtl/matvec_int4_desc_pkg.vhd`, `mv4i_arith_pkg.vhd`, `imrope_pkg.vhd`, `rom_init_pkg.vhd`, `fixed_pkg.vhd`, `fixed_luts_pkg.vhd` | no multiplicative accumulator in the body | -- | safe |

#### Extended: every LOCAL declaration that shadows a utility-package name

Prompted by TRACK CKVMAP: a package-level fix silently fails to apply wherever
a local homograph hides it, so the audit has to cover the shadowing set and not
only the package. Swept all 22 function names exported by `util_pkg`,
`llama_map_pkg` and `model_cfg_pkg` against every `function <name>(` in
`rtl/`, `sim/` and `tb/`:

| name | local declarations | is it a homograph? |
|---|---|---|
| `clog2` | `rtl/llama_top.vhd`, `rtl/hbm_tg.vhd:196`, `sim/micro/c_lane.vhd:38`, `sim/micro/c_lane_p.vhd:56`, `sim/micro/micro_c_lane_sh.vhd:47` | **YES** for `llama_top` and `hbm_tg` (same `(natural) return natural` profile, so they HIDE the package one). The three micro copies take `positive`, so they are overloads, but nothing in those files calls it with a `natural`, so in practice they are the only `clog2` there too. |
| `msb_pos` | `rtl/gdn_conv.vhd:179`, `rtl/gdn_recur.vhd:228`, `rtl/gdn_recur_pipe.vhd:375`, `rtl/gdn_head_emit.vhd:156`, `rtl/gdn_y_emit.vhd:126`, `sim/tb_gdn_conv_tvalid_skew.vhd:130` | **NO.** All six take `unsigned`; `util_pkg`'s takes `integer`. Different profile, so they overload rather than hide. All six are bounded FOR loops over `a'range` with no accumulator, so none carries the overflow class. |
| the other 20 names | none | -- |

Two incidental notes from that sweep, neither in my scope and neither an
overflow: the six `msb_pos(unsigned)` bodies come in **two variants**,
`p := i` (`gdn_head_emit`, `gdn_y_emit`) and `p := i - a'low`
(`gdn_conv`, `gdn_recur`, `gdn_recur_pipe`, the bench), which disagree for any
vector whose low index is not 0. And nothing shadows any `llama_map_pkg` or
`model_cfg_pkg` name at all.

**`clog2` was the only 32-bit accumulator hazard in the utility packages.**
`msb_pos` in the same file is already safe: `to_unsigned(v,32)` accepts every
`integer` up to `natural'high` and the loop is bounded.

The byte-scale arithmetic the brief worried about (`> 4 GiB`) does not live in
these packages at all -- it lives in `llama_top`'s generics and in
`tools/hbm_map.py`. `llama_map_pkg` and `model_cfg_pkg` are element-count
geometry, which is why they are three orders of magnitude clear.

### 4.8 Full regression, unfiltered

`util_pkg` is in the analysis closure of 78 files, and a new overload can
create ambiguity anywhere, so the whole gate was run rather than a filtered
subset. Last `OVERALL` line, verbatim:

```
 suite sim   PASS 73   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 99   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 5   SKIPPED 19
 baseline: 99 passing, above the floor of 93 -- but this tree has rows a clean
 checkout does not get: [20 rows listed]  DO NOT raise BASELINE_PASS from this run
 REGRESSION: PASS
```

**Zero rows moved.** `BASELINE_PASS` is untouched, and the run's own advice
against raising it from a dirty tree is followed.

**One contamination window, checked and closed.** That run started 18:52:38 and
TRACK CKVMAP's four files (including `rtl/llama_top.vhd` and
`sim/tb_llama_top.vhd`) hit the working tree at 19:11:31, mid-run. Result-file
mtimes say which rows straddle it:

```
res.sim_tb_llama_top        18:56:36     res.sim_tb_llama_top_smp      18:57:22
res.sim_tb_llama_top_normw  18:56:06     res.sim_tb_llama_top_smp_beh  18:57:24
res.sim_tb_llama_top_real   18:57:21     res.sim_tb_llama_top_seq      19:01:41
```

All six `tb_llama_top*` rows finished by 19:01:41, **before** the change, so
they are attributable to the pre-CKVMAP tree. Nineteen rows ran after 19:11:31,
of which sixteen are `tb/`-suite engine rows and `tb_llama_engine_axi`, none of
which has `llama_top` in its closure. **The three that do are
`sim:seamgate_{real,stub,seq}`** (19:13:05, 19:13:38, 19:16:46), which drive
`sim/tb_llama_top.vhd` through `tools/ref9b/capture_llama_top.sh`. Re-run on a
single coherent tree (HEAD `3722ae8`, CKVMAP landed, my change present):

```
 OVERALL     PASS 3   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 0   SKIPPED 0
 REGRESSION: PASS
```

Also carried from CKVMAP: **the third field of a `regress.sh` result line is
elapsed SECONDS, not a check count** (`regress.sh:1736`). No claim in this file
rests on that field; recorded so the next reader does not lose a round to it.

Note for anyone working from the same brief as I was: **`BASELINE_PASS` is 93,
not 101.** TRACK GATEHYGIENE reset it from 101 to 93 earlier the same day
(`sim/regress.sh:403`). Read the value out of the file at gate time rather than
carrying it in a brief.

---

---

## 5. Measured and REJECTED -- do not retry

- **"Fix `util_pkg.clog2` and CGENERICS' wall 2 goes away."** REJECTED, twice
  over. `llama_top` does not call `util_pkg.clog2` (4.2), and even if it did,
  the argument at `C_MAXPOS = 131072` is 6,803,283,968 and does not fit
  `natural` (6.1). Do not re-open the KV map on the strength of this commit.
- **A `real`-typed overload as the escape hatch.** REJECTED before writing it.
  A doubling loop over `real` is exact for powers of two, but `real` in a
  constant function is on much thinner ice in Vivado synthesis than `unsigned`
  is, and the whole point of the escape hatch is that it has to survive
  elaboration in the synthesiser as well as in GHDL. `unsigned` is exact,
  arbitrary-width, and already the type the design's address arithmetic is
  written in.
- **"Compare against `n/2` instead of computing `v*2`"** (one of the two shapes
  the brief suggested). Not rejected on correctness -- it works -- but it needs
  a divide per iteration *and* still carries a running `v`, where halving `n-1`
  needs one variable and no invariant to reason about. The halving shape is
  also the one `rtl/hbm_tg.vhd:196` already uses independently, so it is the
  shape this project has converged on twice.
- **An `assert ... severity failure` guard inside the fixed `clog2`.**
  REJECTED as pointless: after the fix there is no `n` in `natural` for which
  the body can abort, so there is nothing to guard. Adding a guard that can
  never fire is a checker never shown to fail. (And per the correction carried
  from CGENERICS: an out-of-range `natural`-constant guard would refuse with a
  bare `bound check failure at <file>:<line>` and no message at all, so it is
  not the free win it looks like.)
- **Editing the three `ip_repo/*/src/util_pkg.vhd` copies.** REJECTED. They are
  *outputs*: `ip_repo/package_llama_ip.tcl` builds the IP from `$llama/rtl/*`
  with source import, so they are refreshed by the next packaging run and a
  hand-edit would diverge from the generator. They still carry the old body
  today; see "open, not answered".

---

## 6. Arithmetic behind the claims in section 2

### 6.1 The ceiling a perfect `clog2(natural)` would give

DERIVED from CGENERICS' own bisect, with no new measurement. With
`C_K_BASE = 0` the argument is `KVREG_B = C_MAXPOS * K` for a constant
`K = C_LAY*C_NKVH*REC_B_C`. The bisect boundary pins `K`: the largest accepted
`C_MAXPOS` is 61,680 and the first rejected is 61,681, and the old body's
threshold is exactly `2**30 = 1,073,741,824`, so

```
61680 * K <= 1073741824 < 61681 * K   =>   17405.0 < K <= 17405.3 ... no.
```

`K` is pinned **uniquely**, to a single integer, by the two-sided bound:

```
61680 * K <= 1073741824  =>  K <= 1073741824/61680 = 17408.26...  =>  K <= 17408
61681 * K >  1073741824  =>  K >  1073741824/61681 = 17407.98...  =>  K >= 17408
                                                                  =>  K  = 17408
```

Checked forwards:

```
61680 * 17408 = 1,073,725,440  <= 1,073,741,824   (accepted, matches the bisect)
61681 * 17408 = 1,073,742,848  >  1,073,741,824   (rejected, matches the bisect)
61680 * 17409 = 1,073,787,120  >  1,073,741,824   (would have rejected 61680, so K is not 17409)
```

Cross-checked structurally against `rtl/llama_top.vhd:3665`,
`REC_B_C = 16 + C_HD*C_CM_W/8`: at `C_CM_W = 8` and `C_HD = 256` that is 272,
and `C_LAY * C_NKVH * 272 = 17408` gives `C_LAY * C_NKVH = 64`, consistent with
8 attention layers (32 blocks / attn_interval 4) and 8 KV heads. Labelled
INFERRED, not MEASURED: the 9B shape was not elaborated to confirm
`C_HD = 256`, `C_NKVH = 8`.

So with a `clog2(natural)` that is correct all the way to `natural'high`:

```
C_MAXPOS_max = floor(2147483647 / 17408) = 123,361
```

against the 131,072 the map needs. **Short by 5.9%.** And at `C_MAXPOS = 131072`
the first thing to overflow is no longer `clog2` at all but
`llama_top:3873`'s own `constant KVREG_B : natural := C_LAY*C_NKVH*C_MAXPOS*REC_B_C`
= 2,281,701,376.

### 6.2 The answer at the real value

```
KVREG_B   = 131,072 * 17,408          = 2,281,701,376   (x88000000, printed by the bench)
KV extent = 4,521,582,592 + 2,281,701,376 = 6,803,283,968   (x1_9581E000, printed)
2**32 = 4,294,967,296 < 6,803,283,968 <= 8,589,934,592 = 2**33
=> clog2 = 33 = C_KV_ADDR_W, with zero slack.
```

MEASURED by `clog2(unsigned)` and independently checked by the 128-bit
shift oracle in the same run.

---

## 7. Handover: the `llama_top` local `clog2`

Not applied here -- `rtl/llama_top.vhd` is TRACK BTOP1's file. Lines 782-787
should become, byte for byte:

```vhdl
  function clog2(n : natural) return natural is
    variable m : natural;
    variable r : natural := 0;
  begin
    if n <= 1 then return 0; end if;
    m := n - 1;
    for i in 1 to 31 loop
      if m > 0 then m := m / 2; r := r + 1; end if;
    end loop;
    return r;
  end function;
```

or, better, be **deleted outright** so that the `use work.util_pkg.clog2;`
already present at line 173 takes effect and there is one `clog2` in the
design rather than two. Deleting it is the change I would make; it was not
made here only because of file ownership.

Either way that is necessary but **not sufficient** for `C_MAXPOS = 131072`.
The KV-fit check at `llama_top:3873`/`:3874`/`:3835` has to stop forming
`natural` intermediates. The shape that works, using the new overload:

```vhdl
      constant KVREG_BU : unsigned(63 downto 0) :=
        resize(to_unsigned(C_LAY, 64) * C_NKVH * C_MAXPOS * REC_B_C, 64);
      constant KV_ENDU  : unsigned(63 downto 0) :=
        KVREG_BU + maximum(C_K_BASE, C_V_BASE);
      constant CHK_KV_FIT : natural := C_KV_ADDR_W - clog2(KV_ENDU);
```

**TRAP to carry into that edit, MEASURED here:** numeric_std's
`"*"(UNSIGNED, NATURAL)` returns **`2*L'LENGTH` bits, not `L'LENGTH`**.
`u64 := to_unsigned(131072,64) * 17408` is a run-time `bound check failure`,
not a truncation and not an analysis error. Either `resize` as above, or feed
the product straight into `clog2`, which takes an unsigned of any width. This
cost one bench run to find.

---

## 8. Measurement traps hit

- **`ghdl -r ... | head` reports the pipeline's rc, not GHDL's.** Carried from
  the brief; quoted `${PIPESTATUS[0]}` throughout. It bit once anyway, in a
  `tail -4` that silently hid the report lines of an otherwise-good run.
- **`git archive HEAD` can straddle another track's commit.** Carried from the
  brief; `SHA=$(git rev-parse HEAD)` was run as its own step and the sha is
  stated at the top of this file.
- **The threshold does not identify the function.** Both `clog2` shapes in this
  design break at exactly `2**30`, so bisecting to 61,680/61,681 tells you
  *that* a `clog2` overflowed and nothing about *which*. Only the qualified
  name in the GHDL message does. Bisect narrows the value; it does not narrow
  the code.
- **My own expectation was wrong on a 1-bit all-ones vector.** I asserted
  `clog2(not to_unsigned(0,1)) = 1`; the correct answer is 0, because a 1-bit
  all-ones vector is the *value* 1. The width is not the answer. The assertion
  failed, the function was right, and the note is kept in the bench.
- **A bench built as "old vs new" has a blind spot shaped exactly like the
  bug.** The old body cannot be evaluated above `2**30`, which is precisely the
  region the fix exists to cover. Mutant M3 lands there and nowhere else.

---

## 9. Open, not answered

- **`rtl/llama_top.vhd:782` is still the old shape.** Handed to BTOP1
  (section 7). Nothing in this commit changes `llama_top`'s behaviour.
- **`rtl/hbm_tg.vhd:196`** has the correct halving shape already, but with
  `variable v : natural := n - 1` in the declaration, so `clog2(0)` is a bound
  check failure there rather than 0. Not touched (not my file, and no caller
  passes 0 today). Worth folding into `util_pkg` and deleting.
- **`sim/micro/c_lane.vhd:38`, `c_lane_p.vhd:56`, `micro_c_lane_sh.vhd:47`**
  each carry a private `clog2(n : positive)` of the doubling shape. Same defect
  class, same `2**30` threshold. Micro-benches with small parameters, so no
  live exposure. Not touched.
- **`ip_repo/{llama_engine_axi,matvec_engine,mac_axi}_1_0/src/util_pkg.vhd`**
  still carry the old body. They are regenerated from `rtl/` by
  `ip_repo/package_llama_ip.tcl`, so the next packaging run fixes them; until
  then a build straight from `ip_repo` uses the old function. Deliberately not
  hand-edited (section 5).
- **Whether `C_HD = 256` and `C_NKVH = 8` for the 9B shape** was inferred from
  the factorisation of 17408, not measured. It does not affect any conclusion:
  17408 is pinned by the bisect boundary alone.
