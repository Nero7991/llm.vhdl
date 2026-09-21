# Build 12: the control. Build 9's lever state at current HEAD.

Launched 2026-09-21 08:2x from detached worktree `/mnt/storage/fk33_builds/wt12`
at `d4af6ed`. IN FLIGHT at the time of writing.

## Why a build with no new levers

Two consecutive card builds failed and neither produced an attributable result.
Build 10 routed legally and missed timing by 5.819 ns, never attributed. Build
11b failed to route, and the cause turned out to be a launch-environment value
nobody chose (`CB_STYLE=regs`), not the lever it was launched to test. Oren's
call: re-establish that HEAD routes at all, so that every later build has a
control. Build 10 never had one.

The cost is stated plainly: ~4.5 hours for zero speed gain.

## Composition, and how each value was verified rather than assumed

| lever | build 12 | how |
|---|---|---|
| per-row codebook `0b34200` | REVERTED | `rtl/matvec_core.vhd` md5 `b616c7822f93154b08200f9418489012`, the file builds 9 and 10 were synthesised from |
| `CB_STYLE` | **`distributed`** | `--setenv=FK33_CB_STYLE=distributed`, read back from the unit's `Environment`. THE LOAD-BEARING LINE, and the one build 11b lacked. |
| `NWIDE` | false | `rtl/llama_top.vhd:5548`; entity default is `false` at `rtl/gdn_state_store.vhd:136`, so this is build 9's state |
| `FAST_POP` | false | `hw/fk33/gen_fk33_engine.py:114` `FAST_POP_DEFAULT = False`, regenerated |
| `SWEEP_PIPE` | false | `rtl/llama_top.vhd:6997`, regenerated into `rtl/fk33_llama_top.vhd` |
| `SCORE_EARLY` | false | same line |
| `SWG_WIDE` / `SWG_LANES` | false / 1 | already the default; `fk33_card.vhd` does not override them, so GSRWIDE's lever was never on |

`build12_levers_off.patch` is the exact 70-line diff applied in the worktree,
6 changed lines across 4 files. HEAD keeps every track's levers; this build is a
recorded variant rather than a repo-wide revert, so nobody's work is undone.

The generators were run rather than their outputs hand-edited:
`tools/gen_cardtop.py` (no environment inputs, `--check`/`--bench` only) and
`hw/fk33/gen_fk33_engine.py` (no `os.environ` reads). The build then regenerated
`fk33_engine.vhd` itself and produced the same 91,192 bytes, which is why
editing the GENERATOR rather than the generated file was necessary: a hand-edit
would have been silently overwritten at launch.

Worktree md5s at launch:

```
0dff963bf2f6d388ba664586205c49f0  rtl/llama_top.vhd
40728a3b854a6df9226f36e73b3424d0  rtl/fk33_llama_top.vhd
ec2aa59ba43a2d8e36b0cfb3e342042d  hw/fk33/rtl/fk33_engine.vhd
b616c7822f93154b08200f9418489012  rtl/matvec_core.vhd
```

## Gated before launch, in the worktree

Every row non-zero, so the substring actually matched something.

| `--only` | OVERALL |
|---|---|
| `cardtop` | PASS 3 FAIL 0 |
| `fk33card` | PASS 1 FAIL 0 |
| `tb_matvec_core` | PASS 2 FAIL 0 |
| `tb_matvec_cb` | PASS 2 FAIL 0 |
| `seamgate` | PASS 6 FAIL 0 |
| `runguard` | PASS 1 FAIL 0 |

The matvec rows reproduce `5dc3ee5`'s and CBREVERT's figures (2/2), which is the
control that the revert changed no value.

## Budget, counted before dispatch

Box 31 GiB, 5 used / 12 free / 25 available, swap 6 GiB at launch. No Vivado on
either lane (CBOOC and CBCENSUS had both released). Unit capped
`MemoryHigh=24G MemoryMax=26G`, **verified by reading the cgroup back** rather
than from the exit status: `memory.high = 25769803776`,
`memory.max = 27917287424`. A `FK33_CARD=1` build has measured ~23.5 GiB
resident plus ~23.9 GiB swap, so it runs alone, with `swapguard.sh` killing the
unit at 30 GiB swap or 10 GiB free on `/mnt/storage`, and `watch.sh` gating on
the anchored `^FK33_BUILD_DONE` sentinel and reporting unit-end-without-sentinel
as a FAILURE.

## What this build can and cannot tell us

**CAN:** whether current HEAD, with the codebook reverted and `CB_STYLE`
correct, still routes and closes as build 9 did (+0.061). That makes it the
control every later lever build is measured against.

**CANNOT:** anything about any lever, since it carries none. In particular it
does not bear on build 10's unexplained -5.819, which had NWIDE on.

## Open

- Build 10's -5.819 legal-route timing failure is now the only unexplained card
  failure.
- The per-row codebook's cost in the card context is still unknown: builds 9 and
  10 predate it and 11b drew it as the identity. The only measurement anywhere
  is CBOOC's out-of-context `FF -19,345`, a saving.
- `SWEEP_PIPE` and `SCORE_EARLY` have never been in any card build, and by the
  WORKLOG rule against building RTL no synthesiser has drawn, they need an OOC
  draw before they go on one.
