# TRACK CBRUN, 2026-09-21 -- the four-arm OOC draw of the codebook write path

Provenance and method. The results and the verdict are in the dated CBRUN
section appended to
`docs/debugging/2026-09-20_the-codebook-stopped-being-ram.md`, which is TRACK
CBRAM's file and where the experiment was specified. This directory holds the
captures that section quotes.

**No hardware. No Vivado on the workstation** -- the workstation lane was
claimed by the main session for a `CBO_TARGET=matvec_int4_desc_axi` draw, and
this track ran entirely on the BC-250 (`cachyos-bc250`, resolved from the
router's DHCP lease at `192.0.2.133`, never from a hardcoded number).
`rtl/matvec_core.vhd` was NOT edited in the repository: every arm is a tree in
`/mnt/storage/fk33_builds/scratch/cbrun`, and TRACK CBREVERT owns the repo file.

## The four arms, and what each one settles

| arm | `rtl/matvec_core.vhd` | sha256 (first 16) |
|---|---|---|
| `old` | `git show 0b34200^:rtl/matvec_core.vhd`, the real pre-change RTL and byte-identical to build 10's file | `ef401b6ff079e055` |
| `new` | `HEAD` (`c189722`), byte-identical to build 11b's file | `974734a743f73201` |
| `fan` | CBRAM option R3a: per-copy COMBINATIONAL alias, `cbw_*` stay 48 wide | `1e801942f6a8d666` |
| `bcast` | CBRAM option R3b: `cbw_*` back to 1,536 wide, new 48-wide `cbr_*` rank stage, `CB_WR_LAT` 1 -> 2 | `6f0c687c1bf5e756` |

`old` and `new` were built by TRACK CBOOC's own `sim/ooc_cbooc_run.sh` in
`CBO_PREPARE_ONLY=1` mode, which is the mode that exists for this: it asserts
the provenance where git lives and writes `MANIFEST.txt` so the far side can
re-assert it by sha256 after the crossing. Its assertion passed --
`rtl/matvec_core.vhd` had not moved since `0b34200` (md5 `c3325ea1` at the
commit, at `HEAD` and in the working tree), so `0b34200^` IS
HEAD-minus-those-four-hunks and the `old` arm is not an imitation of the change.

`fan` and `bcast` were made by `make_arms.py` (committed here) as anchored
single-purpose substitutions **on the `new` tree, not on the `old` one**. Each
anchor is asserted to match exactly once; a substitution that matched nothing
would produce an arm identical to `new` and that arm would then read as a real
measurement of the shelf option. Building them from `old` would have
reintroduced all four of `0b34200`'s hunks and made any verdict unattributable.

**`bcast`'s write statement is byte-identical to `old`'s**, verified by md5 of
the extracted line (`0e6469929f647e84414589a72db95817` in both):

    cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));

**And `bcast`'s write LOOP is `new`'s loop with the function call removed, not
`old`'s combined loop.** This is deliberate and it buys a control CBRAM's
specification did not have. `new` differs from `old` in TWO ways: the W1 write
and the W0 capture were split into separate loops, AND the port index
expressions became `cb_rank_of(c)`. Keeping `new`'s split and changing only the
indices is what makes a `bcast` verdict attributable to the index expression.
An arm that restored both at once could not tell the two apart.

## The GHDL elaboration gate, all four arms, on the workstation before shipping

Each arm elaborates and prints its own announcement. The `CBRUN_ARM=` field was
added to `fan` and `bcast` because the runner's gate keys on `CB_COPIES` and
`CB_RANKS`, which are identical in `new`, `fan` and `bcast` -- without it the
three announcements would be indistinguishable and a mixed-up arm would look
like a result.

    old   LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1  CB_WR_LAT=1
    new   LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1  CB_RANKS=48  CB_WR_LAT=1
    fan   LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1  CB_RANKS=48  CB_WR_LAT=1  CBRUN_ARM=fan
    bcast LEVER C ACTIVE  CB_STYLE=distributed  CB_COPIES=1536  CB_LANES_PER_COPY=1  CB_RANKS=48  CB_WR_LAT=2  CBRUN_ARM=bcast

All four then fail at time 0 with `overflow detected`, identically
(`overflow_lines=1` in each, `assert_failures=0` in each). That is CBOOC's
documented property of running `matvec_core` as a TOP with unstimulated
`integer` ports sitting at `integer'left`. It is arm-invariant and is not an
elaboration failure; the gate keys on the announcement, never on the exit code.

## The geometry, copied verbatim from CBRAM's specification

    CBO_TARGET=matvec_core
    CBO_GEN="BLK=32 ROWS_IF=48 MAXCOLS=17408 MAXROWS_BFP=17408 CB_ROWS_PER_COPY=1 CB_STYLE=distributed"
    CBO_CLK="clk=13.333"

**`CB_STYLE=distributed` is the whole experiment.** At `regs`,
`CB_COPIES = CB_RANKS = 48` and `cb_rank_of(c) = c` is the identity, so all four
arms are the SAME NETLIST and the run prints four full result rows measuring
nothing. `sim/ooc_levercost_run.sh` carries `regs`; it was not reused.
`sim/ooc_cbooc.tcl` refuses `regs` unless `CBO_ALLOW_REGS=1`.

## One driver for all four arms, through CBOOC's unedited tcl

`cbrun_draw.sh` (committed here) draws every arm through the same
`sim/ooc_cbooc.tcl` at sha256 `afe4d0de963485ad...`, which matches
`git show HEAD:sim/ooc_cbooc.tcl` exactly. CBOOC's runner knows two arms and is
not this track's file to edit; drawing `old`/`new` through it and the shelf arms
through something else would have put a harness difference on the same axis as
the RTL difference, which is this project's recorded "control on the wrong axis"
failure.

## The memory cap was verified from inside the cgroup, and the check caught a real trap

TRACK ELABCLASS measured hours earlier that `ssh host 'bash -s'` can carry no
`XDG_RUNTIME_DIR`, in which case `systemd-run --user` silently does nothing and
Vivado runs UNCAPPED on this 14 GB box, which is on no WoL watchdog. So the cap
is never inferred from `systemd-run`'s exit status. The wrapper reads
`memory.high` back out of its OWN cgroup and refuses to `exec vivado` if it is
`max` or unreadable.

**The readback found a second, different failure of the same shape.** The first
form tried was `systemd-run ... bash -c '... $cg ...'`, and systemd expanded the
`$cg` in its own command line before bash ever saw it:

    Referenced but unset environment variable evaluates to an empty string: cg
    cgroup=/user.slice/.../cbrun_captest_2570525.scope
    memory.high=cat: /sys/fs/cgroup/memory.high: No such file or directory
    systemd_run_rc=0

`rc=0`, a correctly named scope, and a cap check that read nothing. Writing the
wrapper out to a FILE so no `$` reaches systemd's command line fixes it:

    cgroup=/user.slice/user-1000.slice/user@1000.service/app.slice/cbrun_captest2_2570598.scope
    memory.high=8589934592
    memory.max=11811160064
    memory.swap.current=0

and the live run carries the same, read out of the running scope's own cgroup:

    CBRUN_CAP_READBACK cgroup=/user.slice/.../cbrun_old_2570677.scope memory.high=8589934592 memory.max=11811160064

`MemoryHigh=8G` throttles, `MemoryMax=11G` is a hard in-cgroup kill line rather
than a box-level failure, and neither is above the 11G ceiling that a 12G cap
crossed when it made this box unreachable. A box-level swap guard kills the
scope at 20 GB of swap in use, because swap in use is the leading indicator and
free RAM is not.

## Files here

| file | what it is |
|---|---|
| `make_arms.py` | builds the `fan` and `bcast` trees from `new` by anchored substitution |
| `cbrun_draw.sh` | the four-arm driver, with the cap readback and the line-anchored sentinel |
| `collect.sh` | extracts the four-arm table from a finished run directory |
| `cbrun_driver.log` | the driver's own log, all four arms |
| `arm_<arm>_8-5859.txt` | the recognizer's lines per arm (there are none) with the ANCHORED message counts and the mapping-report row counts beside them. **`gdn_block` is not in `matvec_core`'s closure, so the positive control CBRAM specified for `8-5859` does not exist at this target even in principle** |
| `arm_new_vs_old.diff`, `arm_fan_vs_new.diff`, `arm_bcast_vs_new.diff` | exactly what each arm changes |
| `cbrun_netnames.tcl`, `run_netnames.sh`, `netnames_driver.log` | the checkpoint query that names the command nets, counts total cells, and proves `fan` is `new` |
| `result_cb_<arm>.csv` | the tcl's own result row per arm |
| `run_<arm>.log.gz` | the full per-arm harness log |
| `MANIFEST.txt`, `CBRUN_MANIFEST.txt` | the provenance both ends asserted |

## The result, in one table

Four arms, `opt` stage throughout, never mixed with the `synth` stage. Full
argument, predictions scored, traps and open items: the dated TRACK CBRUN
section of `docs/debugging/2026-09-20_the-codebook-stopped-being-ram.md`.

| arm | `cb_ram` | `cb_ff` | `8-5859` naming `cb_reg` | RAM32M16 | MUXF8 | LUT | FF | `cbw_ff` | max command-net fanout | cells |
|---|---|---|---|---|---|---|---|---|---|---|
| `old` | 26112 | 0 | **0** | 1573 | 0 | 78183 | 73463 | 19968 | 1536 sinks | 191787 |
| `new` | 26112 | 0 | **0** | 1573 | 0 | 77560 | 54126 | 624 | 128 sinks | 171716 |
| `bcast` | 26112 | 0 | **0** | 1573 | 0 | 77745 | 74092 | 19968 (+624 `cbr_*`) | 32 sinks | 191921 |
| `fan` | 26112 | 0 | **0** | 1573 | 0 | 77560 | 54126 | 624 | 128 sinks | 171716 |

**`cb` is distributed RAM in all four arms**, to the digit, so CBRAM's falsifier
2 has fired and the mechanism is not confirmed. **`fan` is the same netlist as
`new`** (identical cells, nets and pins; `cbx_any = 0`), so option R3a is struck.
**`[Synth 8-5859]` names `cb_reg` in none of the four arms** while the mapping
report names 1,536 `RAM32M16` copies in each, so its absence is not evidence of
a refused inference.

Every arm hit the 8G `MemoryHigh`, so every `memory.peak` here is the cap and
none is a footprint. Vivado's own accounting gives `peak = 3,941 MB` for `old`
at its largest synthesis phase.

**Anchor every message grep.** Unanchored, this log gives `8-7186 = 24,577` and
`8-10226 = 1`; anchored it gives **24,576 = 1,536 x 16** and **0**. Both
over-counts are the same line of `sim/ooc_cbooc.tcl`'s own source, echoed into
the log by the command that raises those message limits.
