# The card top's weight-master outputs have no driver in the only configuration that ships

## 1. The question

Verbatim, 2026-09-15, continuing the work recorded in WORKLOG `9b4477a`:

> Extend `sim/tb_fk33_cardtop_ident.vhd` so the `A_DESC=true` / `ga_desc` arm
> can actually run, then fix `ga_desc.ap`'s y store.

Build under examination: `rtl/fk33_llama_top.vhd` as emitted by
`tools/gen_cardtop.py` at `9b4477a`, the card top for the SQRL FK33
(`xcvu33p-fsvh2104-2L-e`). Configuration of interest: `A_BEHAV = false`,
`A_DESC = true`, which is the configuration `hw/fk33/ooc_card_dcp.tcl` builds
and the only one that ships.

Symptom at the outset: none. Nothing was failing. The gate was green at
`OVERALL PASS 130 FAIL 0`, and the card configuration had never been
elaborated by anything.

## 2. The answer

**With `A_BEHAV = false` and `A_DESC = true`, six OUTPUT ports of
`fk33_llama_top` have no driver at all:** `m_arvalid`, `m_araddr`, `m_arlen`,
`m_arsize`, `m_arburst`, `m_rready`.

The three A arms are guarded:

| generate | condition |
|---|---|
| `ga_behav` | `if A_BEHAV` |
| `ga_desc`  | `if A_DESC` |
| `ga_real`  | `if not A_BEHAV and not A_DESC` |
| `ga_tie`   | `if A_BEHAV` |

`ga_real` drives the six from `matvec_int4`. `ga_tie` ties them off. The card
configuration matches **neither**, so the ports are undriven: `'U'` in
simulation, and in synthesis an undriven output into the smartconnect, where an
undriven `m_arvalid` is a weight read request that may or may not be issued.

Fixed in `tools/gen_cardtop.py` by emitting `ga_tie : if A_BEHAV or A_DESC
generate`. This is the exact twin of the existing `gnd_a` generate, which
exists because "a VHDL entity cannot have a conditional port clause" and so the
`a_*` outputs need a driver in the arm that does not use them. The identical
argument applies to the `m_*` outputs in the arm that does not use them, and it
was missed when the third arm was added.

**Found by reading the four generate conditions, not by any run** — and it
could not have been found by a run, because no bench set `A_DESC`. The defect
and the reason it stayed invisible are the same fact.

## 3. The procedure

1. **Ask which arm the card builds, and what drives each port in that arm.**
   Not "does the file look right" but, for one named port, which statement
   assigns it under this generic setting. `grep -n` for every assignment to
   `m_ar*` and `m_rready` in the generated top returns exactly two sites: the
   `ga_tie` block at 3521 and the `ga_real` port map at 3951.
2. **Enumerate the generate conditions and take their intersection with the
   card's generics.** Four conditions, one configuration; the table above is
   the whole argument. This is arithmetic over the guards, not an inspection.
3. **Confirm the generator does not repair it downstream.** `grep -n ga_tie
   tools/gen_cardtop.py` returns nothing, so the generated top inherits
   `llama_top`'s two-arm guard unchanged.
4. **Write a bench that elaborates the card configuration and asks only whether
   each output has a driver.** No stimulus, no arithmetic: driven-ness is a
   property of the generate conditions, so nothing needs to be driven to
   observe it. `sim/tb_fk33_cardtop_adesc.vhd`.
5. **Include a positive control in the same run.** The seven `a_*` outputs are
   checked by the same rule. If both sets read `'U'` the bench is broken rather
   than the RTL; the `a_*` set passing is what makes the `m_*` verdict
   attributable to the tie-off rather than to a generate that never elaborated.
6. **Teeth-test it against the pre-fix RTL.** Revert the one guard in the
   generated file, re-run the same row, and require the check to fail. A check
   never shown to fail has not been shown to work.
7. **Restore by regenerating, not by editing back.** `python3
   tools/gen_cardtop.py` followed by `--check`, so the restoration is
   deterministic rather than a second hand-edit that has to be trusted.

## 4. The evidence

Every assignment to the six ports in the generated top, MEASURED:

```
$ grep -n "^\s*m_ar\w*\s*<=\|^\s*m_rready\s*<=\|m_arvalid =>" rtl/fk33_llama_top.vhd
3521:    m_arvalid <= (others => '0');
3522:    m_araddr  <= (others => '0');
3523:    m_arlen   <= (others => '0');
3524:    m_arsize  <= (others => '0');
3525:    m_arburst <= (others => '0');
3526:    m_rready  <= (others => '0');
3951:        m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
3952:        m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,

$ grep -n "ga_tie" tools/gen_cardtop.py
(no output)
```

The bench against the MUTANT (pre-fix guard, `ga_tie : if A_BEHAV generate`):

```
FAIL: m_arvalid has no driver with A_DESC true
FAIL: m_araddr has no driver with A_DESC true
FAIL: m_arlen has no driver with A_DESC true
FAIL: m_arsize has no driver with A_DESC true
FAIL: m_arburst has no driver with A_DESC true
FAIL: m_rready has no driver with A_DESC true
TB_FK33_CARDTOP_ADESC checks=13 bad=6
TB_FK33_CARDTOP_ADESC FAIL
 OVERALL     PASS 0   FAIL 1
```

The same bench against the FIXED RTL:

```
PASS  sim:tb_fk33_cardtop_adesc  2s  TB_FK33_CARDTOP_ADESC PASS
 OVERALL     PASS 1   FAIL 0
```

`checks=13` is 6 driven-ness checks plus the 7-check positive control, and it
matches the number of `chk` calls in the file. **The 7 control checks pass in
BOTH runs**, which is the line that makes the 6 failures attributable.

## 5. Measured and REJECTED -- do not retry

- **"Enable `A_DESC` in `tb_fk33_cardtop_ident` and the `ga_desc` arm is
  covered."** It is not, and this was the plan of record when the session
  started. That bench **never connects any `a_*` port**: `grep -cE
  "\ba_(awaddr|wdata|bvalid|y_we|y_data|job_done|x_we)\b"` returns **0** and the
  port map ends at `bst_bresp`. With `A_DESC => true`, `a_bvalid` is stuck low
  so `a_desc_adapter` never completes a descriptor write and `ad_done` never
  asserts; `a_y_we` is stuck low so no y beat reaches `ga_desc.ap`. The FSM sits
  in S_GO/S_RUN and times out. Flipping the generic produces a hang, not
  coverage. **Do not retry as a generic flip; it needs an engine on the far
  side of those ports.**
- **"Model the engine in the bench to get an oracle for `ga_desc`'s numbers."**
  Not wrong, but unnecessary and expensive for the arithmetic:
  `matvec_int4_desc_axi` is REAL RTL at `rtl/matvec_int4_desc_axi.vhd`, and
  `sim/tb_matvec_fk33_desc.vhd` (2,041 lines) already drives it at the card
  geometry with weight slaves and a descriptor image. **The engine's numbers
  are already covered.** What is uncovered is `ga_desc`'s own data MOVEMENT.
  Do not rebuild the engine; build the seam.
- **"The BC-250 is down, its sweep results are lost."** WITHDRAWN the same
  hour. `ssh labuser@192.0.2.200` returned `No route to host` and that was
  read as a statement about the box. The box was up; the address was stale.
  See the traps section.

## 6. Measurement traps hit

- **A failed connection to a hardcoded address measures the ADDRESS, not the
  host.** The BC-250 is on DHCP over a USB WiFi dongle. This repo's `CLAUDE.md`
  carried `192.0.2.200`; the router's lease says
  `79834 40:a5:ef:5f:0a:79 192.0.2.133 cachyos-bc250`.
  `~/GitHub/DevOps/CLAUDE.md` already said `.133` **and already said "Find it
  from the router, never by guessing"** -- the guess was made anyway because a
  number was sitting in the nearer file. Both the repo `CLAUDE.md` and
  `~/GitHub/DevOps/bc250-sync-llama-vhdl.sh` (whose `HOST` default was the same
  stale `.200`) were corrected. This is the same shape as every other trap in
  `CLAUDE.md`: a fact about the harness reported as a fact about the job.
- **A `systemd-run --user` unit does not inherit your shell's cwd.** The first
  full-gate launch reported `Running as unit: gate-adesc.service` and was dead
  within seconds with `bash: sim/regress.sh: No such file or directory`,
  `status=127`. The launch message is not a statement that the job started.
  Use `--working-directory` and absolute paths, and read the log rather than
  the launch line.
- **A waiter that backgrounds its own work is tracked by the harness only up to
  the foreground command.** `nohup bash -c "until ...; done" ... &` followed by
  `echo armed` reported "completed, exit code 0" **three seconds after arming**,
  because what completed was the `echo`. The gate was still running with 12 row
  directories. This is the recorded "a waiter's exit code is the harness's, not
  the job's" in a new place; the fix is to let the blocking loop itself be the
  backgrounded command.
- **Row directories, not log lines, are the gate's progress signal.** Its stdout
  is block-buffered into a file, so `gate.log` sat at 301 bytes while 12 rows
  had completed.

## 7. What this does NOT settle

Stated explicitly, because the fix is small and the temptation to over-claim it
is not.

- **It does not close the `ga_desc` coverage gap.** `sim/tb_fk33_cardtop_adesc`
  checks that ports have DRIVERS. It runs no job, issues no `go`, and reads no
  arithmetic. The adapter handshake, the S_XRD/S_GO ordering rule, the y buffer
  and S_DRAIN writeback remain unverified for values. WORKLOG `9b4477a` stands.
- **It is not established that this defect caused any observed failure.** It is
  unrelated to the elaboration wall, which was root-caused separately to
  `[Synth 8-3391]` on `gb_real.bp.zb_reg` and fixed in `587d9b5`. No claim is
  made here that the undriven ports produced a symptom anyone saw.
- **What the card's block design connects `m_*` to was not checked.** If those
  ports are left open at the next level up, the practical consequence of the
  defect is smaller than the worst case described above. This was not
  determined, and the fix is correct either way.
- **The remaining y-store work is untouched.** `ga_desc.ap`'s `yb`, plus
  `ga_real.ap.yb` (`rtl/llama_top.vhd:3543`) and `gb_real.bp.yb` (`:4477`), are
  still process variables of 12,288 elements.

## 8. Corrections

None yet. Append here in place rather than by editing the above.
