# `llama_top` computed subsystem B as if every token were token 0, and now it does not

**Date:** 2026-08-29. Branch `fpga`. Track BTOP1.
**Design under test:** repository commit **`78e0e4a60263d2d945913f293f9daae6a813e8ec`**,
taken as a `git archive` snapshot into `/mnt/storage/btop1` (the pristine
"before" tree) and `/mnt/storage/btop1_fix` (the same tree plus this track's
changes). Every number below is against one of those two trees and none
against the working tree. The sha was read with `git rev-parse HEAD` as its
own step before the `git archive`, for the reason section 7 gives.
**No hardware was touched.** No `xsdb`, no `hw_server`, no `vivado`, nothing
under `hw/fk33/`, nothing opening `/dev/xdma*`.

Labels: **MEASURED** (a tool ran, and it is named), **DERIVED** (arithmetic
shown), **ESTIMATE** (a judgement, with its assumption stated).

---

## 1. The question, verbatim

From this track's brief:

> **THE DEFECT: defect candidate B-TOP-1**
>
> > **`llama_top` computes subsystem B as if every token were token 0.**
> > `rtl/llama_top.vhd:3270` drives `b_tk0 <= '1'` at *every* token, so the
> > recurrent state is written and never read, and `:4048` resets
> > `gdn_exp_capture` once per token so only conv tap `KCONV-1` is ever valid.
> >
> > The behaviour is DECLARED, but the declaration's premise ("there is no
> > token loop yet") **expired** when `tb_llama_top_seq` reached `NTOK=3`.
> > `--tk0 seq` measures the cost: **60 to 75 of 128 mantissas per seam wrong
> > at tokens 1 and 2.**
>
> **Your job: make `llama_top` drive `b_tk0` correctly per token, so B's
> recurrence actually runs.**
>
> [...] **RY-MODEL named two mutations that SURVIVE and are the resolution
> floor: S10 and S11.** [...] **If S10 and S11 still survive after your change,
> the recurrence still is not running** -- that is a sharp, ready-made test of
> whether you actually fixed it, and I want it reported explicitly either way.

---

## 2. The answers, up front

**The recurrence runs. S10 and S11 are dead.**

MEASURED, `bash tools/ref9b/seamgate.sh seq` on mutant trees:

| mutation | before the fix (`78e0e4a`) | after the fix |
|---|---|---|
| S10, the decay rounding bias deleted | **SEAMGATE PASS**, 61 seams x 3 tokens | **SEAMGATE FAIL (DIVERGENCE)**, `R_Y-0` element 47, tokens 1 and 2 |
| S11, the per-layer term deleted from B's state address | **SEAMGATE PASS**, 61 seams x 3 tokens | **SEAMGATE FAIL (DIVERGENCE)**, `R_Y-2` element 0, 65 of 128, tokens 1 and 2 |

Both still pass **token 0**, and that is the design and not a residual gap:
at the first token of a sequence `tk0` is high in ANY correct implementation,
so there is no previous state for either mutation to corrupt.

**The fix is TWO drivers, not one, and fixing either alone is neither
behaviour.** `b_tk0` is the recurrent state; `b_seq_rst` is the causal conv's
tap history. They were justified by the same expired sentence and they had to
move together.

* `b_tk0` now follows `tok_pos`, the file's own sequence position, so it is
  high only at the first token of a sequence.
* `b_seq_rst` now fires only at `tok_pos = 0`. That is what
  `rtl/gdn_exp_capture.vhd`'s header says the port is for -- "`seq_rst` clears
  the counters at the start of a sequence" -- and firing it on every `go` is
  once per TOKEN, which is why `tvalid` marked only tap `KCONV-1` valid at
  every token and the causal conv had no history anywhere.

**CORRECTION TO THE BRIEF, and it is the size of the defect.** The brief's
"60 to 75 of 128 mantissas per seam" is the cost of the `b_tk0` half ALONE,
which is what RY-MODEL's `--tk0 seq` modelled. With the `b_seq_rst` half
included the cost is larger. MEASURED, the new `tools/ref9b/gdn_oracle.py`
default against the PRE-FIX capture:

```
  R_Y-0        tok 1  exp 10 expected vs 10 captured, 86 of 128 mantissas differ, first at 0 (expected -102, captured -229)
  R_Y-2        tok 1  exp 9 expected vs 9 captured, 67 of 128 mantissas differ, first at 0 (expected -1517, captured -8077)
  R_Y-0        tok 2  exp 10 expected vs 10 captured, 88 of 128 mantissas differ, first at 0 (expected -599, captured -3345)
  R_Y-2        tok 2  exp 8 expected vs 8 captured, 65 of 128 mantissas differ, first at 4 (expected -5755, captured -6955)
```

**65 to 88 of 128**, not 60 to 75. Both numbers are correct about what they
measured; the brief's is the smaller half.

**A THIRD THING THE FIX DOES, and it is the one to watch.** Opening `tvalid`
turns a harmless zero into a live wrong number under `B_SRC_REAL`:
`cvdata_p` writes ZERO into every conv tap but the newest, which was inert
while those slots were masked. `rtl/llama_top.vhd`'s `S_GO` now REFUSES that
combination rather than summing zeros at a real captured exponent, and
`gdn_oracle.py` refuses it on the model side too. Holding a real history is a
new `(KCONV-1) x qkv_dim` buffer, 3 x 8,192 words at the 9B shape, and
`B_SRC_REAL` cannot be run today for an unrelated reason
(`rtl/llama_top.vhd:52-58`). Section 8 lists it as open.

---

## 3. The procedure, in the order it was run

Each step is named with what it isolates.

1. **Establish the correct condition from the RTL and the port contract, not
   from the comment that declared the current behaviour.**
   `rtl/gdn_exp_capture.vhd`'s header defines `seq_rst` as a per-SEQUENCE
   clear and defines `tvalid` as "after `n` captures the valid taps are the
   newest `n`"; `rtl/llama_top.vhd:822` defines `tok_pos` as "a sequence is a
   reset followed by N `go`/`tok_done` handshakes and NOT N resets".
   *Isolates: whether a sequence position already exists in this file. It
   does, and subsystem C already takes `c_cpos` from it, so B and C cannot
   disagree about which token this is.*
2. **Capture the BEFORE.** `seamgate.sh seq` on the pristine `78e0e4a` tree.
   *Isolates: that the row was green before the change, so a later red is the
   change and not the tree.*
3. **Reproduce RY-MODEL's number on that capture** with `--tk0 seq`.
   *Isolates: that this track and RY-MODEL are measuring the same object
   before either claims the other is wrong.*
4. **Run S10 and S11 at `seq` on the pristine tree.** *Isolates: the sharp
   test's "before" reading. Both were recorded as survivors at `real`, which
   is a ONE-token configuration where they cannot be anything else -- see
   trap T2. A survival measured only at `real` measures nothing.*
5. **Fix both drivers**, plus the `B_SRC_REAL` refusal.
6. **Move the model with the RTL**, because a recipe whose model has not
   followed it is a recipe with no oracle. `gdn_oracle.py` now writes `tk0`,
   `tvalid` and `e_t` per the sequence position.
7. **Cross-check the model refactor against the OLD capture in the OLD mode.**
   *Isolates: whether the refactor changed anything it should not have. If
   `--tk0 pre-btop1` on the pre-fix capture does not reproduce 6 of 6, the
   oracle edit is a second defect wearing the first one's clothes.*
8. **Run all three gate rows on the fixed tree.**
9. **Teeth: S10 and S11 at `seq` AND at `real`**, plus two new mutations B1
   and B2 that restore each half of the defect separately. *Isolates: that
   the kill came from the recurrence rather than from the mutation being
   loud, and that neither half of the fix is doing all the work.*
10. **Re-pin the landmarks that legitimately moved, and say which and why.**

---

## 4. What was wrong, exactly

`rtl/llama_top.vhd` at `78e0e4a`, two sites, one premise.

```vhdl
            when S_GO =>
              b_start <= '1';
              b_tk0   <= '1';   -- one token only; there is no token loop yet
```

```vhdl
        if go = '1' then
          -- One sequence reset per token, issued while everything is idle.
          b_seq_rst <= '1';
        end if;
```

and the justification, at `:2757-2761`:

> a tap older than the number of `gdn_exp_capture` captures is masked out by
> `tvalid` and ZEROED inside `gdn_conv`, so at `tk0` -- which is all this file
> has, **there being no token loop** -- only tap KCONV-1 is ever summed.

**There is a token loop.** `sim/tb_llama_top_seq.vhd` runs `NTOK = 3`, it is
two gate rows (`sim:tb_llama_top_seq`, `sim:seamgate_seq`), and it ran three
tokens in every measurement in this document.

Consequences, DERIVED from `rtl/gdn_recur_pipe.vhd` and
`rtl/gdn_exp_capture.vhd`:

* `TK0_ED` (`:592`, `:645`, `:722`) masks the previous state to zero whenever
  `tk0` is high. With `tk0` hardwired, the state was written by every token
  and read by none. Subsystem B is Gated DeltaNet -- a recurrent architecture
  -- so this is not a scaling error, it is a different model.
* `gdn_exp_capture`'s per-entry counter saturates at `K` and `seq_rst` clears
  it. With `seq_rst` on every `go`, the count at the time B started was always
  exactly 1, so `tvalid` was `0001` at every token and the causal conv had one
  tap everywhere.

**The behaviour was DECLARED at both sites, which is what made it survive.** A
stand-in with a false justification is one nobody re-examines: the sentence
answers the question before it is asked.

## 5. The fix

`rtl/llama_top.vhd`, `gb_real`'s `S_GO`:

```vhdl
              if tok_pos = 0 then b_tk0 <= '1'; else b_tk0 <= '0'; end if;
```

`rtl/llama_top.vhd`, `qexpp`:

```vhdl
        if go = '1' and tok_pos = 0 then
          b_seq_rst <= '1';
        end if;
```

plus a simulation-only refusal in `S_GO` for `B_SRC_REAL and tok_pos > 0`,
and the same refusal in `gdn_oracle.py`.

**Why `tok_pos` and not a new counter.** It is the file's only sequence
position, it is reset by `rst` and advanced only by the `tok_done`/`tok_ack`
handshake, so it is stable for the whole of a token and `tok_pos = 0` is
exactly the first token of a sequence. `attn_block` already takes `c_cpos`
from it (`:4032`), so using anything else would have created a second opinion
about which token this is -- the shape of defect C1.

**Nothing had to be cleared at a sequence boundary.** At `tok_pos = 0` the
state read is masked, so the stale contents of `stmem` and `semem` from a
previous sequence cannot reach an output, and token 0 overwrites them. That
is the design `gdn_recur_pipe`'s `TK0_ED` exists for. NOT VERIFIED: that token
0 writes EVERY `(head, col, group)` entry, which is what makes the argument
complete rather than merely plausible; see section 8.

**Nothing in `ref/gdn_block_cap_vec.c` had to change**, which is the payoff of
RY-MODEL having allocated `smem`/`semem` per layer and run the loops
layer-major while `tk0` was 1 everywhere and the state was inert. Only the
Python that WRITES the stimulus moved.

---

## 6. The evidence

### 6.1 Before: the pristine tree at `78e0e4a`

MEASURED, `bash tools/ref9b/seamgate.sh seq`:

```
tb_llama_top RESULT: PASS -- 61 descriptors, 4 blocks, 3 tokens per run, 1 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -14252 hash(R_X) = 7668
  token 0: 61 seams bit-exact against a model, 0 not checked
  token 1: 61 seams bit-exact against a model, 0 not checked
  token 2: 61 seams bit-exact against a model, 0 not checked

SEAMGATE PASS -- seq: 3 token(s), at least 61 seams per token
```

MEASURED, `python3 tools/ref9b/gdn_oracle.py <that capture> --blocks 4
--attn-int 2 --attn-hd 64 --norm anchor --kv-block 16 --n-rot 16 --tk0 seq`
on the PRE-FIX tools, reproducing RY-MODEL exactly:

```
  R_Y-0        tok 1  exp 10 expected vs 10 captured, 75 of 128 mantissas differ, first at 0 (expected -226, captured -229)
  R_Y-2        tok 1  exp 9 expected vs 9 captured, 62 of 128 mantissas differ, first at 0 (expected -8521, captured -8077)
  R_Y-0        tok 2  exp 10 expected vs 10 captured, 75 of 128 mantissas differ, first at 0 (expected -3572, captured -3345)
  R_Y-2        tok 2  exp 8 expected vs 8 captured, 60 of 128 mantissas differ, first at 4 (expected -6890, captured -6955)
# 2 of 6 R_Y seams match the model bit for bit
```

MEASURED, S10 and S11 at `seq` on the pristine tree, which is the "before"
half of the sharp test:

```
[S10/seq gate rc=0]
  token 0: 61 seams bit-exact against a model, 0 not checked
  token 1: 61 seams bit-exact against a model, 0 not checked
  token 2: 61 seams bit-exact against a model, 0 not checked
SEAMGATE PASS -- seq: 3 token(s), at least 61 seams per token

[S11/seq gate rc=0]
  token 0: 61 seams bit-exact against a model, 0 not checked
  token 1: 61 seams bit-exact against a model, 0 not checked
  token 2: 61 seams bit-exact against a model, 0 not checked
SEAMGATE PASS -- seq: 3 token(s), at least 61 seams per token
```

### 6.2 The model refactor is behaviour-preserving in the old mode

MEASURED, the NEW `gdn_oracle.py` run against the PRE-FIX capture:

```
### pre-btop1 model vs PRE-FIX capture (expect all ok) ###
# 6 of 6 R_Y seams match the model bit for bit
EVERY MODELLED R_Y MATCHES ITS MODEL BIT FOR BIT, given the machine's own inputs.

### seq model vs PRE-FIX capture (expect divergence: this IS the defect) ###
  R_Y-0        tok 1  exp 10 expected vs 10 captured, 86 of 128 mantissas differ, first at 0 (expected -102, captured -229)
  R_Y-2        tok 1  exp 9 expected vs 9 captured, 67 of 128 mantissas differ, first at 0 (expected -1517, captured -8077)
  R_Y-0        tok 2  exp 10 expected vs 10 captured, 88 of 128 mantissas differ, first at 0 (expected -599, captured -3345)
  R_Y-2        tok 2  exp 8 expected vs 8 captured, 65 of 128 mantissas differ, first at 4 (expected -5755, captured -6955)
# 2 of 6 R_Y seams match the model bit for bit
```

This is the check that separates "the oracle changed" from "the oracle broke".
`--tk0 pre-btop1` reproduces the old default bit for bit on the old capture,
so the rewritten `tvalid` / `e_t` generation degenerates correctly. Then the
same tool in its new default names the defect on the same file.

### 6.3 The sharp test: S10 and S11

MEASURED, `bash tools/ref9b/seamgate.sh seq` on mutant copies of the FIXED
tree. Both were `SEAMGATE PASS` on the pristine tree (section 6.1).

```
[S10/seq gate rc=1]
  token 0: 61 seams bit-exact against a model, 0 not checked
SEAMGATE FAIL (DIVERGENCE) -- seq token 1: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 47 -- expected 5787, captured 5788 (exponent 10 vs 10, 2 of 128 mantissas differ)
SEAMGATE FAIL (DIVERGENCE) -- seq token 2: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 4 -- expected -22471, captured -22472 (exponent 10 vs 10, 4 of 128 mantissas differ)
SEAMGATE FAIL -- seq

[S11/seq gate rc=1]
  token 0: 61 seams bit-exact against a model, 0 not checked
SEAMGATE FAIL (DIVERGENCE) -- seq token 1: a modelled seam does not
    FIRST DIVERGENCE: R_Y-2 at element 0 -- expected -1779, captured -1685 (exponent 9 vs 9, 65 of 128 mantissas differ)
SEAMGATE FAIL (DIVERGENCE) -- seq token 2: a modelled seam does not
    FIRST DIVERGENCE: R_Y-2 at element 8 -- expected -259, captured -271 (exponent 8 vs 8, 62 of 128 mantissas differ)
SEAMGATE FAIL -- seq
```

**The SIGNATURES are the part worth reading, not just the verdicts.**

* **S10 is 2 of 128 and off by one.** That is a rounding-bias defect showing
  as a rounding-bias defect: the decay's `+2**12` before a `>> 13` changes an
  element only where it crosses a tie. A mutation that killed the row by 128
  of 128 would have proved the state is read; this proves the state is read
  AND that the gate resolves a sub-LSB change in it.
* **S11 is 65 of 128 at `R_Y-2`, not at `R_Y-0`.** DERIVED: dropping the layer
  term from the B state address makes every GDN layer share one state region.
  Block 0 is the first GDN layer to run each token, so it writes the shared
  region and reads back its own -- it is right. Block 2 reads what block 0
  left. Naming the SECOND GDN block is what a layer-aliasing defect should
  look like, and it is a different fingerprint from S10's.

**THE CONTROL: the same four mutations at `real`, on the same FIXED tree.**
MEASURED, `bash tools/ref9b/seamgate.sh real`:

```
[S10/real gate rc=0]   64 seams bit-exact, 0 not checked   SEAMGATE PASS
[S11/real gate rc=0]   64 seams bit-exact, 0 not checked   SEAMGATE PASS
[B1/real  gate rc=0]   64 seams bit-exact, 0 not checked   SEAMGATE PASS
[B2/real  gate rc=0]   64 seams bit-exact, 0 not checked   SEAMGATE PASS
```

**All of them survive `real`, and that is arithmetic rather than a gap.**
`real` captures ONE token; at token 0 `tk0` is high in any correct design, so
no mutation downstream of the recurrent state has a previous state to corrupt.
The pair -- killed at `seq`, alive at `real`, same tree, same mutation -- is
what shows the kill came from the recurrence running and not from the mutation
being loud enough to disturb something else. It is also the measurement that
`tools/ref9b/mutate_seamgate.sh` could not make before, because every one of
its B-side rows ran `real` only. See trap T1.

### 6.4 Two new teeth: each half of the defect, separately

Two new rows, **B1** and **B2**, restore ONE half of defect B-TOP-1 each, on
an otherwise fixed tree. They exist because "the numbers moved after I changed
two things" is not a measurement of either thing.

MEASURED, `bash tools/ref9b/seamgate.sh seq`:

```
[B1/seq gate rc=1]   -- b_tk0 driven high at every token again
  token 0: 61 seams bit-exact against a model, 0 not checked
SEAMGATE FAIL (DIVERGENCE) -- seq token 1: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 0 -- expected -102, captured -75 (exponent 10 vs 10, 84 of 128 mantissas differ)
SEAMGATE FAIL (DIVERGENCE) -- seq token 2: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 0 -- expected -599, captured 751 (exponent 10 vs 11, 88 of 128 mantissas differ)
SEAMGATE FAIL -- seq

[B2/seq gate rc=1]   -- b_seq_rst pulsed on every go again
  token 0: 61 seams bit-exact against a model, 0 not checked
SEAMGATE FAIL (DIVERGENCE) -- seq token 1: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 0 -- expected -102, captured -226 (exponent 10 vs 10, 87 of 128 mantissas differ)
SEAMGATE FAIL (DIVERGENCE) -- seq token 2: a modelled seam does not
    FIRST DIVERGENCE: R_Y-0 at element 0 -- expected -599, captured -3572 (exponent 10 vs 10, 85 of 128 mantissas differ)
SEAMGATE FAIL -- seq
```

**Each half fails on its own, and they fail DIFFERENTLY.** B1 and B2 both
diverge at `R_Y-0` element 0 with the same EXPECTED value -- `-102` at token 1,
`-599` at token 2, because the model is the same in both runs -- and different
CAPTURED values: `-75` against `-226` at token 1. So neither half is a
restatement of the other, and neither half of the fix is carrying the whole
change. B1 at token 2 also moves the EXPONENT (10 against 11), which B2 does
not.

**B2 IS THE MACHINE RY-MODEL'S `--tk0 seq` FLAG WAS MODELLING, and the
numbers close the loop.** Follow `R_Y-0` token 1 element 0 across four runs:

| the machine | `b_tk0` | `b_seq_rst` | captured | the model that predicts it | its prediction |
|---|---|---|---|---|---|
| pristine `78e0e4a` | per token | per token | **-229** | pre-fix default / `--tk0 pre-btop1` | **-229** (6 of 6 exact) |
| B2 mutant | per sequence | per token | **-226** | pre-fix `--tk0 seq` | **-226** |
| fixed tree | per sequence | per sequence | **-102** | new default (`--tk0 seq`) | **-102** (61 of 61 exact) |
| B1 mutant | per token | per sequence | -75 | -- no model wired for this half -- | -- |

RY-MODEL's `--tk0 seq` changed `tk0` and left `tvalid` at one tap, which is
exactly B2's configuration -- and its prediction of `-226` is what the B2
mutant physically produces. **A flag that was written to describe the spec
turns out to have been describing a half-fixed machine**, and B2 is the run
that proves it rather than an argument that asserts it. It is also the
cleanest statement of why the brief's 60-to-75 figure is the smaller half: it
is the distance from the pristine machine to B2, not to the fix.

### 6.5 The three gate rows on the fixed tree

MEASURED, on `/mnt/storage/btop1_fix`:

| cfg | tokens | floor | result | verdict |
|---|---|---|---|---|
| `real` | 1 | 64 | 64 seams, 0 not checked | **SEAMGATE PASS** |
| `stub` | 1 | 63 | 63 seams, 1 not checked (`R_Y-3`, the ramp) | **SEAMGATE PASS** |
| `seq` | 3 | 61 | 61 seams per token, 0 not checked, all three | **SEAMGATE PASS** |

The `seq` row's own summary line, which is where the moved numbers are:

```
tb_llama_top RESULT: PASS -- 61 descriptors, 4 blocks, 3 tokens per run, 1 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -732 hash(R_X) = 86454
  token 0: 61 seams bit-exact against a model, 0 not checked
  token 1: 61 seams bit-exact against a model, 0 not checked
  token 2: 61 seams bit-exact against a model, 0 not checked

SEAMGATE PASS -- seq: 3 token(s), at least 61 seams per token
```

**`R_X(0)` moved from -14252 to -732 and `hash(R_X)` from 7668 to 86454, and
the gate is green.** That pair is the whole argument that the new numbers are
RIGHT rather than merely different: the comparison is not against a recorded
value, it is against `ref/gdn_block_cap_vec.c` and the other oracles re-run on
this run's own captured inputs, and every seam of every token agrees bit for
bit. A fix that had merely changed the numbers would have gone red here.

The floors were NOT changed. 64 / 63 / 61 stand.

### 6.6 The landmarks that moved, and the ones that did not

**MOVED, and re-pinned:** `sim/tb_llama_top_seq.vhd`, all four.

```
tb_llama_top: P14 landmarks measured -- EXP_X0 => -732, EXP_XSUM => 86454, EXP_XALL => 79978, EXP_STEPH => 50729   (4 of the pinned landmarks moved)
```

| landmark | was | now |
|---|---|---|
| `EXP_X0` | -14252 | **-732** |
| `EXP_XSUM` | 7668 | **86454** |
| `EXP_XALL` | 96762 | **79978** |
| `EXP_STEPH` | 57526 | **50729** |

`EXP_X0` and `EXP_XSUM` are independently confirmed by the seam-gate run
above, which printed the same two values from a separate GHDL invocation at a
different `NRUNS`.

The same four are also held as a `LAND_SEQ` string in
`sim/mutate_llama_top_land.sh`, for its own control rows, and both copies were
moved together. See trap T3.

**RE-RUN AFTER THE RE-PIN, which is the step that makes a re-pin a claim
rather than a hope.** MEASURED:

```
[tb_llama_top_seq rc=0]
tb_llama_top: P14 landmarks measured -- EXP_X0 => -732, EXP_XSUM => 86454, EXP_XALL => 79978, EXP_STEPH => 50729   (0 of the pinned landmarks moved)
tb_llama_top RESULT: PASS -- 61 descriptors, 4 blocks, 3 tokens per run, 2 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -732 hash(R_X) = 86454
```

That run's generic set is character-for-character `mutate_llama_top_land.sh`'s
`G_SEQ` plus the new `LAND_SEQ`, so it IS that script's `P0s` control row --
"the clean design must PASS with its landmarks pinned" -- and the whole script
was not re-run for it. NOT MEASURED: rows `P1`, `P2` and `P3` of that script
on the fixed tree. They mutate `rtl/attn_block.vhd` and `rtl/gdn_silu.vhd`,
neither of which this track touched, and all three kill on a landmark MOVING
rather than on any particular value -- but that is an argument, not a run, and
it is listed as open in section 9.

**DID NOT MOVE, and were NOT re-pinned:** `sim/tb_llama_top_real.vhd`.
MEASURED on the fixed tree:

```
[tb_llama_top_real rc=0]
tb_llama_top: P14 landmarks measured -- EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 17333   (0 of the pinned landmarks moved)
tb_llama_top RESULT: PASS -- 64 descriptors, 4 blocks, 1 tokens per run, 2 descriptor-latency points, R_X bit-identical across all of them, R_X(0) = -16364 hash(R_X) = 91622
```

That is the expected result and it is a check rather than a formality: `real`
is `NTOK = 1`, `tok_pos` is 0 for its only token, and the fixed drivers
therefore produce exactly what the hardwired ones did. A landmark that HAD
moved there would have meant the change reached token 0, which it must not.

**ALSO DID NOT MOVE:** `sim/tb_llama_top_normw.vhd`, the other `NTOK = 1`
row, MEASURED on the fixed tree:

```
[tb_llama_top_normw rc=0]
tb_llama_top: P14 landmarks measured -- EXP_X0 => -16350, EXP_XSUM => 90889, EXP_XALL => 90889, EXP_STEPH => 18618   (0 of the pinned landmarks moved)
```

**ALSO UNMOVED:** `sim/tb_llama_top_smp` (`NTOK = 2`) and
`sim/tb_llama_top_smp_beh`. Both PASS on the fixed tree with zero assertion
errors. Their logits DO change at token 1 -- they must -- but that row's check
is a recomputation from the design's own region contents rather than a pinned
value, so it follows the design without a re-pin.

```
tb_llama_top_smp: PASS.  2 tokens, 64 logits each, two lm_head windows, A_BEHAV=false
tb_llama_top_smp: PASS.  2 tokens, 64 logits each, two lm_head windows, A_BEHAV=true
```

### 6.7 RE-VERIFIED ON THE CURRENT HEAD, not only on the snapshot

HEAD moved four times while this track ran: `78e0e4a` (the snapshot) ->
`0e4f98d` -> `1399425` -> `5154518` -> `8889cfa` -> `359192d`. None of those
commits touched a file this track owns, MEASURED with
`git diff --stat 78e0e4a..359192d -- <the eight paths>` (empty) -- but
`8889cfa` DID change `rtl/attn_block.vhd`'s default generics, and my re-pinned
landmarks are a property of the whole token.

So the whole thing was re-measured on a fresh `git archive
359192d7c8d466b30a23e7d80b369b3f662b352a` with this track's eight files copied
over it. MEASURED:

```
SEAMGATE PASS -- real: 1 token(s), at least 64 seams per token     [rc=0]
SEAMGATE PASS -- stub: 1 token(s), at least 63 seams per token     [rc=0]
SEAMGATE PASS -- seq:  3 token(s), at least 61 seams per token     [rc=0]
    token 0 / 1 / 2: 61 seams bit-exact against a model, 0 not checked

[tb_llama_top_seq rc=0]   EXP_X0 => -732, EXP_XSUM => 86454, EXP_XALL => 79978, EXP_STEPH => 50729   (0 of the pinned landmarks moved)
[tb_llama_top_real rc=0]  EXP_X0 => -16364, EXP_XSUM => 91622, EXP_XALL => 91622, EXP_STEPH => 17333  (0 of the pinned landmarks moved)
```

`rtl/attn_block.vhd`'s change was to DEFAULT generics only, and TRACK
CGENERICS' own note says every instantiation maps the shapes explicitly. That
claim is now measured from this side too: the landmarks are identical either
side of it.

---

## 7. Measured and REJECTED -- do not retry

**Do not judge a subsystem-B mutation at the `real` or `stub` configuration.**
Those capture ONE token. `rtl/gdn_recur_pipe.vhd` masks the state read at
`tk0`, and at token 0 `tk0` is high in ANY correct design, so nothing
downstream of the recurrent state can be exercised there whatever the top
level drives. MEASURED: S10 and S11 survive `seamgate.sh real` on the FIXED
tree, and that survival says nothing about the gate. `tools/ref9b/mutate_seamgate.sh`
ran every B-side row at `real` only, which is why those two were recorded as
the gate's resolution floor; `run_gate` now takes the configuration as a
parameter and the two rows run both.

**Do not add a conv tap history buffer to make `B_SRC_REAL` work.** Not
measured as a failure, rejected on scope and on cost. It is a new
`(KCONV-1) x qkv_dim` signal -- 3 x 8,192 sixteen-bit words at the 9B shape,
ESTIMATE ~90 MB of ghdl-mcode signal storage at the ~228 bytes per scalar
TRACK REALSHAPE measured -- added to the file whose elaboration headroom
TRACK REALFIX had just fought a 46 GB signal for. And `B_SRC_REAL` cannot be
run today for an independent reason (`rtl/llama_top.vhd:52-58`: it makes
`R_ALPHA` physically impossible and saturates the gate shut). Both sides now
REFUSE that combination instead. Section 8 keeps it open.

**Do not model this by making `gdn_oracle.py` reconstruct a state from the
capture.** `ref/gdn_block_cap_vec.c` already carries one state per layer
across the sequence layer-major, which RY-MODEL wrote when the state was
inert. The correct change was to the three fields the Python WRITES -- `tk0`,
`tvalid`, `e_t` -- and nothing else.

**Do not keep `--tk0 top` as a spelling.** It meant "what the top level does",
and after this change that is `--tk0 seq`. A caller passing `top` from a stale
document would have silently compared the fixed machine against the pre-fix
model and read the difference as a defect. `argparse` now rejects the name.

**Do not re-pin `sim/tb_llama_top_real.vhd` or `sim/tb_llama_top_normw.vhd`.**
MEASURED: both are `NTOK = 1`, both still print exactly their pinned values,
and a re-pin there would be a change with no cause.

---

## 8. Measurement traps hit

**T1. `tools/ref9b/mutate_seamgate.sh` ran EVERY row at `real`, which is ONE
token, and that is why S10 and S11 were recorded as the gate's resolution
floor.** The recorded reason for their survival -- "the top level discards that
state every token" -- was true, and it was not the only reason. At a
single-token capture `tk0` is high in ANY correct design, so a mutation
downstream of the recurrent state cannot be seen there no matter what the top
level drives. **The survival was arithmetically forced by the row's own
configuration and would have been recorded identically against a perfect top
level.** MEASURED both ways: S10 and S11 survive `seamgate.sh seq` on the
pristine tree (the defect) AND survive `seamgate.sh real` on the fixed tree
(the configuration). Only the `seq` result is evidence about the design.
*The rule: a B-side mutation's verdict is meaningless without the configuration
beside it. `run_gate` now takes the configuration as an argument and the two
rows print both.*

**T2. The brief's "60 to 75 of 128 mantissas" measures HALF the defect.**
`--tk0 seq` changed only `tk0`; it left `tvalid` at one valid tap, which is the
`b_seq_rst` half still in place. Fixing only what that flag models would have
left the causal conv with no history and the seam gate would have gone red with
no obvious cause. The whole defect is 65 to 88 of 128. *The rule: a flag that
models "the spec" is a model of the spec's answer to ONE question. Read what
the flag actually writes into the stimulus before treating its delta as the
size of a defect.*

**T3. The `seq` landmarks are pinned in TWO files.**
`sim/tb_llama_top_seq.vhd` carries them as generics and
`sim/mutate_llama_top_land.sh:76` carries the same four as a `LAND_SEQ` string
for its own control rows. Re-pinning only the bench leaves that script's `P0s`
control red, which reads as "the clean design fails" -- the single most
misleading state a teeth table can be in. Both were updated together.

**T4. `--tk0 top` was named after the design rather than after the
behaviour.** "top" meant "whatever `rtl/llama_top.vhd` does", so the day the
top level changed, the name became a lie while every caller kept working. It
is now `pre-btop1`, which names a fixed historical behaviour and cannot rot,
and the old spelling is REJECTED rather than aliased so a stale caller fails
loudly instead of comparing the fixed machine against the broken model.

**T5. `seamgate.sh`'s scratch layout nests `work` twice.** With
`SEAMGATE_SCRATCH=$SG` the script passes `SCRATCH="$SG/work"` to
`capture_llama_top.sh`, which then creates `$SCRATCH/work/run`, so the GHDL log
is at `$SG/work/work/run/run.log`. Not a defect, just a path that is one level
deeper than it reads.

---

## 9. Open, not yet answered

1. **`B_SRC_REAL` now needs a real conv tap history, and it does not have
   one.** Before this change the zeros in taps `0..KCONV-2` were masked and
   inert; now they are valid from token 1. Both the RTL and the model REFUSE
   the combination rather than summing zeros at a real captured exponent, so
   nothing can go quietly wrong -- but `B_SRC_REAL` is now blocked at
   multi-token configurations for a second, independent reason on top of the
   `R_ALPHA` one at `rtl/llama_top.vhd:52-58`. Whoever opens that door needs
   both.
2. **The gate never reaches `KCONV` tokens, so `tvalid`'s SATURATION is
   unexercised.** `KCONV = 4` and the `seq` row runs `NTOK = 3`, so the valid
   count goes 1, 2, 3 and never saturates at 4, and the oldest tap is never
   evicted. DERIVED from `rtl/gdn_exp_capture.vhd`'s counter, not measured.
   `NTOK = 4` would cover it; `sim/tb_llama_top_seq.vhd`'s header records that
   NTOK 3 rather than 4 was a gate-cost choice and that the larger point is
   run by hand.
3. **That token 0 writes EVERY `(head, col, group)` state entry was not
   proved directly.** The argument that a sequence needs no state clear rests
   on it. The evidence is indirect and strong: `ref/gdn_block_cap_vec.c`
   starts from a `calloc`ed state and the `seq` row is bit-exact at all three
   tokens, so any entry the RTL left unwritten while the model wrote it (or
   the reverse) would diverge. A direct check would count `st_wen` pulses per
   token against `VH*DM*NBR`.
4. **No synthesis was run.** The change adds a comparison of `tok_pos` against
   zero at two sites and one simulation-only assert. ESTIMATE: negligible, on
   the assumption that a `natural` equality against a constant synthesises to
   a comparator on `clog2(C_MAXPOS)` bits. NOT MEASURED -- a Vivado run was
   already occupying the machine and this track never invoked it.
5. **The recurrent state path is now EXERCISED but its own numerics are only
   checked through the composition.** `ref/gdn_block_vec.c` is INCLUDED by the
   capture driver rather than independently transcribed, which is that file's
   stated limit. S10 and S12 dying says the composition reproduces the
   recurrence bit-exactly; it does not make `gdn_recur_pipe`'s five stages
   independently verified.
6. **`sim/regress.sh` was NOT touched**, deliberately: TRACK GATEHYGIENE owns
   it and it is modified in the working tree. Its `:439` and `:939` comments
   still quote the pre-RY-MODEL floors of 61/60/59, which RY-MODEL recorded as
   stale (its trap T4) and which remain stale. They are comments, not gates.
7. **`sim/mutate_llama_top_land.sh`'s `P1`, `P2` and `P3` rows were not re-run
   on the fixed tree.** Its `P0s` and `P0r` controls were, by equivalence
   (section 6.6). The three mutation rows target files this track did not
   touch and kill on a landmark MOVING rather than on a value, so they should
   be unaffected -- but the whole script is a ~15 minute run and it was not
   made. Somebody should run it once the machine is quiet.
8. **`sim/mutate_llama_top_kv.sh`'s 23 structural rows were not re-run
   either.** Same reasoning and the same caveat. That table's verdicts are
   quoted in two write-ups and are worth re-confirming against a design whose
   token 1 and token 2 numbers have all moved.
