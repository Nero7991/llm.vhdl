# A whole class of testbenches the regression gate can never fail

## The question, verbatim

> Fix `tb_bfp_cmp` (rotted, hidden as SKIPPED in the gate).

Date: 2026-08-28. Repo `llama.vhdl`, branch `fpga`, at `4d3a83f`.
GHDL 1.0.0 mcode, Ubuntu 22.04. No Vivado involved.

Symptom: `sim/tb_bfp_cmp.vhd` port-maps a signal `in_q` on `beh.bfp_pack`.
`rtl/bfp_pack.vhd` has not had an `in_q` port since its input became a
read-ahead BRAM port (`o_raddr` out, `i_rdata` in). The file cannot elaborate
against the committed RTL, and the gate reports it as SKIPPED, not FAIL.

## The answer, up front

`sim/regress.sh` rule (a) classifies any testbench declaring `library beh` as a
post-synthesis netlist compare and skips it **before anything elaborates it**,
so nothing in any gate has ever checked that these files still match the RTL
they instantiate. Thirteen testbenches are in that class; exactly one,
`tb_bfp_cmp`, has drifted. The one-file rot is minor. The hole that let it rot
silently for months is the finding, and it is closed by
`tools/check_beh_ports.py`, which checks the port maps statically without
needing xsim.

## The procedure, in the order it was run

1. **Read the skip reason rather than assume it.** `sim/regress.sh:554-560`,
   rule (a): a match on `^\s*library\s+beh\s*;` produces a SKIP with the reason
   "post-synthesis netlist-vs-behavioral compare, needs xsim + UNISIM". The
   reason is TRUE. The gate genuinely cannot run these. What it does not do is
   check them any other way. This is what makes the class invisible: a SKIPPED
   line removes a red line rather than adding one, which `regress.sh:339` says
   about a different case in its own header.
2. **Establish the blast radius before fixing anything.** Compare every
   `entity beh.<X>` port map in the class against `<X>`'s declared ports. This
   distinguishes "one file rotted" from "the class rotted", and the answer
   changes what the fix should be. Result: 13 port maps, 1 stale.
3. **Separate the two kinds of mismatch.** A formal the entity does not declare
   is a hard elaboration error. An entity port the testbench does not map is
   legal: VHDL leaves an unassociated output open, and these entities carry
   debug and probe outputs a compare bench has no reason to observe. Twelve of
   the thirteen have unmapped ports and are healthy. Conflating the two would
   have reported 13 failures and buried the 1 real one.
4. **Give the check teeth, in both directions**, before trusting it (below).

## The evidence

Full class scan, current tree:

```
check_beh_ports: 13 port map(s) across the `library beh` class
  STALE sim/tb_bfp_cmp.vhd
        entity beh.bfp_pack, declared in rtl/bfp_pack.vhd
        formals not on the entity: in_q
        (entity ports left open, not an error: i_rdata, o_raddr)
check_beh_ports: FAIL, 1 stale port map(s)
exit=1
```

The port lists that disagree:

```
rtl/bfp_pack.vhd        clk rst start o_raddr i_rdata done o_mant o_exp
sim/tb_bfp_cmp.vhd      clk rst start in_q            done o_mant o_exp
```

`sim/post_bfp_net_ren.vhd`, the netlist half of the compare, also declares
`in_q ( 5503 downto 0 )`. It is **untracked** (a build artefact, no git
history), so it was generated from the superseded design. Repairing the
testbench alone would not restore the comparison: the netlist has to be
regenerated from the current `bfp_pack` under Vivado. That is a separate job
and is NOT done here.

### Teeth check, three properties

| property | method | result |
|---|---|---|
| fires on an injected defect | `bogus_formal=>'0'` inserted into `tb_res_cmp`'s port map, a currently-healthy file | detected, count 1 -> 2 |
| does not fire on a legal aggregate | `i_rdata => (others => '0')` as an actual | no false positive |
| goes GREEN when the defect is repaired | `tb_bfp_cmp` port map corrected | `PASS`, exit 0 |

The third matters as much as the first. A check that is red on the current tree
and cannot be shown to go green is indistinguishable from a check that is
always red.

## Measured and REJECTED -- do not retry

- **`(\w+)\s*=>` as the formal regex.** This was the first implementation and
  it is wrong twice. `i_rdata => (others => '0')` yields a spurious formal
  named `others`; the teeth check caught it immediately, reporting
  `formals not on the entity: others` on a port map that was in fact correct.
  Do not parse formals without tracking parenthesis depth.
- **`port\s+map\s*\((.*?)\)\s*;` as the port-map extractor.** Non-greedy, so it
  ends the port map at the first `);` it encounters, which any nested paren
  reaches early. Replaced by balanced-paren extraction. Both defects were in a
  checker written to find defects, which is the argument for the teeth rule.
- **Reporting unmapped entity ports as failures.** Twelve of thirteen files
  have them, all debug or probe outputs, all legal. This would have produced a
  13-line red wall with the single real defect inside it.

## Measurement traps hit

- **A `sed` injection that lands in the wrong construct proves nothing.** The
  first teeth attempt rewrote `(others=>'0')` in a *signal declaration* rather
  than in a port map, and the run still exited 1 because `tb_bfp_cmp` was
  independently stale. Exit status alone therefore looked like success. Always
  grep the injected text to confirm WHERE it landed, and read the specific
  finding for the file you targeted, not the aggregate exit code.
- **A SKIPPED line is not a neutral line.** It is a red line that was removed.
  `regress.sh` reports skips explicitly and never drops them silently, which is
  correct, but a human reading `73 PASS 0 FAIL` will not audit 19 skip reasons.

## Open, not yet answered

- The netlist `sim/post_bfp_net_ren.vhd` needs regenerating from the current
  `bfp_pack` before the equivalence check means anything. Until then
  `tb_bfp_cmp` is a stale test of a superseded design, and repairing only its
  port map would produce a file that elaborates and checks nothing useful.
- `tools/check_beh_ports.py` is NOT yet wired into `sim/regress.sh`. Two agents
  are concurrently editing that file, and a collision there is worse than a day
  of delay. Wire it in as a gate step once the tree settles.
- Whether the other twelve netlists under `sim/post_*.vhd` are equally stale is
  NOT established. This check compares the testbench against the BEHAVIOURAL
  entity only. Nothing here validates the netlist half of any of the thirteen.
