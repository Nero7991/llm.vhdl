# a450 mv_tile: the read port's burst-issue guard limited the tile at 440 MHz

## 1. The question
2026-11-13. `mv_tile` (plan Task 3, `docs/superpowers/plans/2026-11-12-a450-per-port-tiles.md`) rated out of
context on `xcvu35p-fsvh2104-2L-e` at 0.85 V (device row `vu35p_jc_2l85`) at 2.222 ns (450 MHz): routed WNS
-0.051 ns, 439.9 MHz. What limits it, and what closes it?

## 2. The answer
The limiter was the AR-issue guard of the shared read port (`axi_rd_fsm`): `f_level + promised + want <= DEPTH`,
a wide add/compare on the FIFO level driving the `this_len` CE and `arv` D in one cycle. Re-registering its inputs
made it worse; replacing it with an incremental credit counter (`free`, compared against constants, a 2-cycle
`hold` after each handshake, registered `run`) in a tile-local copy (`rtl/mv_rdfsm.vhd`, `rtl/mv_rdport.vhd`)
routed at WNS +0.156 ns, 484.0 MHz (commit 1460fb69). The shared `axi_rd_port`/`axi_rd_fsm` were not edited
(they are in the closure of every existing A rating).

## 3. Procedure
1. Rate `a450_tile` with `tools/rate/rate.py` (routed; `route_design` present in each `vivado.log`).
2. Read the top routed setup paths after each run; check whether the reviewer's predicted limiters (scale multiply,
   `pop` join, flit-FIFO fanout) appear.
3. Change only the read-port issue logic between runs; re-run `tb_mv_tile` (checks=93 cases=26) and the mutant files
   before each rate, so a timing change never hides a value change.

## 4. Evidence (routed, MEASURED)
| Run | WNS | MHz | Worst path | Levels |
|---|---|---|---|---|
| shared axi_rd_fsm | -0.051 | 439.9 | `fifo/mcnt_reg[9]_replica` -> `fsm/this_len_reg[4]/CE` | 6 (route 67.6%) |
| copy, registered level + want | -0.100 | 430.7 | `fsm/st_reg[0]` -> `fsm/this_len_reg[0]/CE` | 8 |
| copy, + registered may_issue/want_issue | -0.150 | 421.6 | `fsm/st_reg[1]_replica` -> `fsm/want_issue_reg[1]/CE` | 9 (CARRY8 x4, LUT6 x5, logic 47%) |
| credit counter `free` + hold + registered run | **+0.156** | **484.0** | `cbw_v_reg[0]` -> `cbl_reg[31][11]` LUTRAM WE (fanout 512) | 0 |

Scale multiply (predicted limiter): met at +0.083 ns in the first run. `pop` join and flit-FIFO stage: not on the
report. Peaks: 6.44 GB (capped at 6G, first run), 4.91, 5.17 GB at an 8G cap.

## 5. Measured and REJECTED (do not retry)
- **Registering the guard's inputs** (`lvl_r`, `want_r`) with a +1 staleness margin: -0.100 ns. The path moves into the
  state decode feeding the same CE.
- **Additionally registering the comparison** (`may_issue`, `want_issue`) with a +2 margin: -0.150 ns. Each register
  added in front of the same wide integer arithmetic added levels.

## 6. Traps hit
- The rating's 4 GB memory estimate was wrong: the first run hit its 6G cap (6.44 GB). Use 8G for this row.
- +0.156 ns is inside the 0.4-0.75 ns routed run-to-run noise: it passes the fixed target, it is not margin. The
  next limiter is the codebook write-enable fanout (512); replicate `cbw_v` if the composition squeezes it.

## 7. Open
- Whether the composed A (24 tiles + distributor + chain + HBM, plan Task 7) still closes at 450 MHz.
- Sim-only gaps the review listed: a per-job `sum(arlen+1) = n_beats` assertion; the credit assertion is weak by one
  beat on a landing cycle.
