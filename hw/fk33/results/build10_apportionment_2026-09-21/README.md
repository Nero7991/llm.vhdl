# Build 10's timing failure, apportioned: the codebook owns the WNS and 1.55% of the failure

MEASURED 2026-09-21 on the BC-250 lane, from build 10's own preserved ROUTED
checkpoint. Read-only: `open_checkpoint`, `report_route_status`,
`get_timing_paths`. No `write_*`, no hardware, no re-implementation.

## The answer

```
bucket           endpoints    share    worst slack
u_kv                 11643    67.71%        -2.772
c_attn                5220    30.36%        -2.858
codebook_cmd           267     1.55%        -5.819
a_core_other            57     0.33%        -2.457
other                    7     0.04%        -0.172
                     -----   -------
total                17194   100.00%
```

**The codebook command net owns the WNS and almost none of the failure.**
It is the worst path at -5.819 and it is 267 of 17,194 endpoints.

**98.08% of build 10's failing endpoints are in subsystem C** (`u_kv` 67.71% +
`c_attn` 30.36% = 16,863).

DERIVED, as an UPPER BOUND on what a codebook fanout fix alone can buy: remove
the `codebook_cmd` bucket entirely and the worst remaining path is `c_attn` at
**-2.858**, so WNS improves from -5.819 to about **-2.858**, a gain of ~2.961 ns,
and **16,927 endpoints still fail**. This is a bound and not a prediction:
removing a 1,536-sink net changes placement and routing globally, so the real
outcome could be better or worse. What it does establish is that **a codebook
fix cannot close build 10's composition**, which is exactly what was registered
in advance ("expect a fanout fix to MOVE the WNS, not close it") and is now
quantified.

## Why this needed a lane rather than the committed report

`report_timing_summary` samples ten paths per clock group. TRACK B10WHY found
the committed report contains **20 violated paths against 17,194 failing
endpoints (0.058%)** and correctly refused to attribute from it. The same
ten-per-group sample on build 11b pointed all ten worst paths at `u_kv` and
nearly produced a confident wrong answer.

This query returned **`B10AP_NPATHS 17194`** -- exactly the failing-endpoint
count from the timing summary, and below the 20,000 cap, so nothing was
truncated. The buckets sum to 17,194 exactly, so no path is double-counted or
dropped. **This is a census, not a sample.**

## Provenance, asserted rather than assumed

- Checkpoint `build10_routed_bd_wrapper.dcp`, sha256
  `fb54d3ec9243387ade8c9d5d116332e5da53502b15a30d6d603159782aa29fda`, verified
  against `KEEP_build10_dcp/SHA256SUMS` before transfer AND again on the BC-250
  after transfer. Both `OK`.
- **The requirement was read from the checkpoint, not from a document:**
  `B10AP_CLOCK name=clk_out3_bd_clk_wiz_0_0 period=13.333`. Build 10 is
  genuinely at 75 MHz, unlike build 11b at 5.000 ns / 200 MHz, so its -5.819 is
  a real slack number and build 11b's -9.762 is not comparable to it.
- **Build 10 routed LEGALLY, confirmed from the checkpoint:** 681,039 of 681,039
  routable nets fully routed, **0 nets with routing errors**. Build 11b had
  146,948 in resource conflict. Both printed `route_design completed
  successfully`; only this table separates them.
- Cap verified by reading the scope's own cgroup back:
  `memory.high=10737418240` (10 GiB), `memory.max=11811160064` (11 GiB), under
  the BC-250's hard 11G ceiling. `XDG_RUNTIME_DIR` and
  `DBUS_SESSION_BUS_ADDRESS` were exported because `systemd-run --user`
  otherwise silently does nothing over ssh, and the readback was written to a
  FILE because `systemd-run`'s own command-line expansion has previously eaten a
  `$cg` and made the check exit 0 for the wrong reason.

## Limitations, stated

- **The bucketing is first-match on an ordered list**, checked as `u_kv`,
  `codebook_cmd`, `a_core_other`, `c_attn`, `b_gdn`, `other`, against BOTH the
  startpoint and endpoint pin names. A path running from `c_attn` into `u_kv` is
  counted as `u_kv`. So **`u_kv`'s 11,643 is an upper bound and `c_attn`'s 5,220
  a lower bound.** The codebook figure is unaffected by this ordering, because
  the WNS path landed in `codebook_cmd` rather than being absorbed, and because
  the codebook's sinks are in `core`, not in either C module.
- Per-bucket TNS was not collected, only counts and worst slack. The shares
  above are shares of ENDPOINTS, not of TNS.
- This says nothing about build 10's causes, only about where its failing
  endpoints are. TRACK B10WHY separately established that `u_kv`'s path is a
  34-level, 17-deep CARRY8 chain -- a LOGIC DEPTH problem that no fanout
  attribute touches -- and that `u_kv` is the WNS owner in both card builds that
  CLOSED.
- The second clock domain `fk33_dmabram` (250 MHz) is independently at -0.109 on
  54 endpoints and is not in this census, which covers `clk_out3` only.

## What this changes

The project spent 2026-09-20 and part of 2026-09-21 treating the codebook as
build 10's and build 11b's problem. Build 11b's failure turned out to be
`CB_STYLE=regs` plus a silent 200 MHz retarget. Build 10's failure is now
measured as **overwhelmingly subsystem C**, with the codebook contributing the
worst single path and 1.55% of the endpoints.

**The next lever to attack is C's KV AXI reader, not A's codebook.**
