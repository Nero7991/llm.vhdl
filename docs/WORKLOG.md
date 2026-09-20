# Parallel worklog

A live board, not a report. One section per track that is in flight, the files
each track owns so two agents cannot collide, and **the next step written down
BEFORE the result arrives**, branched by what the result could be.

Why the branches are pre-written: deciding what to do next while holding a
fresh result is how scope drifts and how a negative result gets talked into
being a positive one. If the branch was written before the answer was known,
the answer only has to be classified, not argued with.

## STATE OF THE BOARD, 2026-08-30 morning

### 2026-09-20 TRACK CSWEEP: C's 5.14 cycles per beat is NOT a narrow mover. It is a per-POSITION FSM, the cache costs ZERO, and `SWEEP_PIPE` takes 22.5% off the slope

- **Files owned and changed:** `rtl/attn_block.vhd` (new generic `SWEEP_PIPE`, OFF by default), new `sim/tb_csweep_rate.vhd`, new `sim/mutate_attn_sweep_pipe.sh`, pass-through generic added to `sim/tb_attn_block.vhd` and `sim/tb_attn_kv_seam.vhd`. `rtl/attn_kv_axi.vhd` UNCHANGED. **No hardware, no Vivado** (the box's one lane was on a card build all day). Write-up: `docs/debugging/2026-09-20_c-sweeps-at-5-cycles-per-beat.md`.
- **PER-BEAT vs PER-POSITION, settled first because the brief said that was the whole question. It is PER POSITION and it is NOT a fourth narrow-mover finding.** MEASURED, `sim/tb_csweep_rate.vhd` at the REAL 9B geometry with a pipelined 100-cycle HBM model: one position of one KV head is **87.42 cycles = KSPAN 7.00 + MIDGAP 56.42 + VSPAN 7.00 + LOOP 17.00**, x N_KVH 4 = **349.68 against the card's 349.2, a 0.14% agreement**. The 16 beats of data movement are 16% of the position; 64.5% is the score-and-softmax chain with nothing overlapped onto it.
- **THE CACHE COSTS ZERO, and there are two independent proofs.** `krdy_low = vrdy_low = 0` at every position, and the `IDEAL_CACHE` control -- `attn_kv_axi` removed entirely, `_rdy` tied high -- reproduces **the same integers** (kspan 1792, midgap 14444, vspan 1792, loop 4284 at position 64). An RD_LAT sweep leaves every span unchanged; only the per-JOB constant moves. **Do not open a wider port, a deeper burst, a larger MAXOUT or a larger RBUF against this number.** MAXB cannot rise anyway: the FK33 HBM slave is AXI3 and `rtl/hbm_tg_ip.vhd:1036` truncates ARLEN to 4 bits.
- **FIX, `SWEEP_PIPE`, DEFAULTING TO THE OLD BEHAVIOUR:** fetch the V record of this position while the score and the softmax drain, and the K record of the NEXT position during P_PV and P_POSN. `krec` is free from the end of P_SCORE and the quantizer cannot be concurrent with the sweep, so **no double buffer**. MEASURED: per pair **87.42 -> 67.37**, slope **355.17 -> 275.11 (-22.5%)**, and `SWEEP_PIPE=false` is **identical on every number** to `git show HEAD:rtl/attn_block.vhd` built into its own library. DERIVED on the card: per job **349.2 -> 269.1**, token slope **2,793.4 -> 2,152.7**, and tok/s +3.8% at 2,048, **+11.0% at 8,192, +24.5% at 65,536**; the last supported token costs 5.68x the first instead of 7.08x.
- **VALUES ARE BIT-IDENTICAL, against two independent C oracles, not a round trip.** `tb_attn_block` BIT-EXACT against `ref/attn_block_vec.c` over 130 values with the generic both ways; `tb_attn_kv_seam` BIT-EXACT against `ref/attn_block_seq_vec.c` over **2,056 output values AND 2,176 record bytes in HBM** both ways, with every returned beat matched to the layer and position it was requested for. The seam run is 2,040 ns faster with it on. Final-tree gate, one invocation per group: `tb_csweep_rate` **PASS 1**, `tb_attn` **PASS 16**, `seamgate` **PASS 6**, `tb_llama_top_kv` **PASS 1**, `kvmap` **PASS 1**, FAIL 0 everywhere.
- **NEXT, one line for whoever runs the next card build:** `SWEEP_PIPE => true` at the `attn_block` instance in `rtl/llama_top.vhd` (and therefore `rtl/fk33_llama_top.vhd`, which is generated from it) -- **not this track's files.**
- **OPEN, and the first one gates the next step:** the AREA and TIMING cost of `SWEEP_PIPE` is **UNMEASURED** (no Vivado lane was free; DERIVED ~23 FF plus a 4-bit mux, an ESTIMATE). `MIDGAP`'s 56.42 cycles have NOT been split -- about 40 of them are the `attn_score_q12` drain plus the `attn_softmax` state machine, and **that is where 84% of what remains lives**. Whether position p+1's SCORE can run while position p's softmax drains is the next lever and was not attempted.

### 2026-09-20 TRACK BRECUR: the GDN recurrence is NOT serial, and 98,422 of `gdn_block`'s 149,579 cycles are a BENCH DEFAULT

- **Files owned and changed:** `sim/tb_gdn_block.vhd` (additive instrumentation only, 124 lines), new `sim/ooc_gdn_recur_pipe_lanes.tcl`, new `hw/fk33/results/brecur_ooc_2026-09-20/`. **No RTL changed.** No hardware. **No Vivado on the workstation** -- its lane was on the card build all day; the four area draws ran on the BC-250. Write-up: `docs/debugging/2026-09-20_the-gdn-recurrence.md`.
- **THE ANSWER: it is one generic, and it is already threaded.** `rtl/llama_top.vhd:816` ships `B_RECUR_LANES = 4` while `rtl/gdn_block.vhd:207` defaults the same generic to **32** and calls it "section 3.1's assumption". The only justification given for the 4 is that it is *"the exact set `sim/tb_gdn_block.vhd` defaults to"*. The sweep is `VAL_HEADS*DIM*(DIM/RECUR_LANES)`, so the lane count divides the largest phase of a B job directly.
- **MEASURED at 9B, `tb_gdn_block`, producers eager:** `RECUR_LANES=4` -> **149,579** cycles (`recur 131,134`); `RECUR_LANES=16` -> **51,157** (`recur 32,830`). **-98,422 cycles, -65.8%.** The 4-lane baseline reproduces TRACK BMOVER's independent 149,579 **to the cycle**. `st_req` equals the derived `VAL_HEADS*DIM*NB_R` exactly in both.
- **WHAT IS TRULY SERIAL: only the token position.** Heads are independent; the column loop is ALREADY pipelined at `NB = DIM/LANES`; and the `DIM` elements inside a column are independent and are visited `LANES` at a time **only because the state memory port is `LANES*16` bits wide**. At the shipping 4, the four per-lane multipliers are idle **31/32 of the time**. This is a loop written serially, not a dependency.
- **THE CEILING IS IN THE MOVER, NOT THE ARITHMETIC, and it is a file B does not own.** `rtl/gdn_state_axi.vhd:212` is `constant WPB : positive := AXI_DW / WBITS` with `WBITS = RECUR_LANES*16`, `AXI_DW = 256`, so **`RECUR_LANES <= 16`**, and `:232` forces exact tiling. The reachable set is `{1,2,4,8,16}`. **`gdn_block`'s own default of 32 does not elaborate on the card at all** -- and it fails as a bare `positive` bound-check, not as one of that file's named refusals.
- **VALUES BIT-IDENTICAL.** The two 9B dumps, normalised on the one lane-dependent index, match **byte for byte over 532,481 lines** (the whole y stream, all 524,288 state mantissas, all 4,096 exponents), md5 `9545a7f0...`. The raw files differ in size, so the normalisation is load-bearing. Plus `tb_gdn_block_vec` PASS against `ref/gdn_block_vec.c`.
- **AREA, MEASURED, four OOC draws on the BC-250**, one Vivado, `MemoryHigh=10G`, all one session/one tree: DSP **17 / 33 / 65 / 129** at LANES 4/8/16/32 (`4*LANES+1` exactly at every point), LUT **9,427 / 12,549 / 17,292 / 27,861**, BRAM 3.5 / 6.5 / 12.5 / 24.5, Fmax 299.0 MHz unchanged. **Shipping -> proposed is +48 DSP (of 793 free), +9 BRAM (of 105), +7,865 LUT against a card at 99.81% CLB.** **The HBM arena does not move** -- 32,768 beats of 256 bits either way -- so no manifest, no re-image, no host change.
- **THE CONTROL HALF-PASSED, and that is a result.** The LANES=32 row reproduces the published **129 DSP** exactly and does **NOT** reproduce the published **24,037 LUT** (measured **27,861**, +15.9%). That figure is from a 2026-08-26 tree, before the head-boundary double buffer, and a different part suffix. **Do not quote 24,037 for `gdn_recur_pipe` again without re-deriving it.** This sweep's internal deltas are unaffected -- all four rows are same-tree.
- **TEETH.** `PH_ORDER` killed a value-neutral mutant (conv read enable asserted during the sweep) and its **attribution control (`PH_ORDER=false`) PASSES every value check**, so it is the SOLE detector. **`PH_ISSUE` is reported as NOT shown to discriminate**: every mutant built for it is caught first by `gdn_recur_pipe:670` or `:794`, and it is an end-of-run check so a deadlocking mutant never reaches it. Kept as a derivation pin; **must not be credited with a kill later.** The five printed spans sum to the total ALGEBRAICALLY, so no assertion was put on that sum -- it would be decoration.
- **GATES:** `--only gdn` **PASS 21 FAIL 0 NOCHECK 1** (the pre-existing `tb_gdn_conv_cycles`, unchanged); `--only bmover` **PASS 1 FAIL 0**; `--only tb_llama_top_b` **PASS 3 FAIL 0**; `--only seamgate` **PASS 6 FAIL 0** including `bconst`. Note every seamgate row is at LANES=4, because `sim/tb_llama_top.vhd` does not expose `B_RECUR_LANES`.
- **NEXT, and it is ONE LINE for whoever runs the next card build:** add `"--generic", "B_RECUR_LANES=16",` to `hw/fk33/gen_fk33_card.py` beside the `B_*` generics already at `:148/:158/:170`. Nothing else -- `rtl/llama_top.vhd:816` already maps it into both `u_gdn` and `u_state`, and `rtl/fk33_llama_top.vhd:851` already carries it. **DERIVED saving: 24 jobs x 98,422 = 2,362,128 cycles a token, 31.5 ms at 75 MHz**; the B job goes 222,805 -> ~124,383. **The risk is CLB, not cycles or DSP**, and only a routed `FK33_CARD=1` build answers it.
- **OPEN:** the **drain phase, 8,977 cycles** -- 49% of the non-recurrence cost and 17.3% of the block after this lever, and TRACK BMOVER's attribution list does not mention it at all; no attribution is offered here and the measurement that would settle it (last `st_ren` to last `y_valid`) is one span this bench does not print. Also: LUT in context rather than OOC; post-route Fmax at 16; the oracle at LANES=16 (blocked on one generic in `sim/tb_llama_top.vhd`, another track's file); and the unexplained 2.5% bench-to-card residual BMOVER also saw.

### 2026-09-20 TRACK AIDLE: A's 0.51 cycles per weight word is ONE LINE in the FIFO, it is 96.7% per-word, and closing it costs ZERO LUTs

- **Files owned and changed:** `rtl/{stream_fifo,async_fifo,axi_rd_port,weight_streamer,matvec_int4,matvec_int4_desc_axi}.vhd`, `hw/fk33/gen_fk33_engine.py` + its generated `hw/fk33/rtl/fk33_engine.vhd`, new `sim/ooc_aidle{.tcl,_run.sh}`. Commits `1a36aec`, `29b9ddd`. **No hardware. No Vivado on the workstation** -- the three area draws ran on the BC-250, whose lane was idle all day. Write-up: `docs/debugging/2026-09-20_a-accept-port-idle.md`.
- **PER-JOB vs PER-WORD, settled first because the brief said the distinction was the whole question.** DSIDE's fit over all 311 A_JOB steps gives `engine = 294.07 + 1.51010 * beats`; the token's excess over the 1-cycle-per-word floor is **2,737,524 cycles, of which the per-job constant is 91,456 (3.34%) and the per-word term is 2,646,056 (96.66%)**. **It is a per-word stall.** Every per-job cost in A added together is capped at 0.30% of the token; do not open one against this number again.
- **ROOT CAUSE, and it is one line in `rtl/stream_fifo.vhd` and the identical line in `rtl/async_fifo.vhd`:** `do_rd <= '1' when mcnt > 0 and (ocnt + inflight) < 2` counts the beat LEAVING the two-entry output stage at this same edge as if it were staying. **MEASURED with a perfect producer and a perfect consumer, no AXI and no array in the loop: 1.501 cycles per beat, q_valid low 1,003 of 3,003 cycles.** `matvec_core.vhd:860` accepts a word only when all 27 ports present a beat in the SAME cycle, so 1.5 in the FIFO is 1.5 in the array. The card's own fitted slope is **1.51010** -- the gap to 1.5000 is everything HBM, the address map, the CDC, MAXOUT, MAXB and the AR throttle contribute put together.
- **FIX, behind `FAST_POP`, DEFAULTING TO THE OLD BEHAVIOUR:** bound on what the stage holds AFTER this edge's pop, `after_e = ocnt + inflight - pop < 2`. Same invariant one pop later; order and values untouched. **MEASURED, 100x4096 ideal memory: 613 -> 422 cycles, W-stall 202 -> 10, cycles/word 1.5963 -> 1.0989.** On the real `M=2048,K=4096` shape (48 jobs a token): **8,333 -> 5,582, -33.0%**. **DERIVED on the card: 2,593,664 cycles a token, 8.61% of the striped token, zero DSPs, and it helps GENERATION as well as prefill** -- 94.4% of the 2,746,816 PREFILL identified as the whole prize, which its row 5 wanted 1,536 non-existent DSPs for.
- **AREA, MEASURED on the BC-250, three OOC draws of `weight_streamer` at the FK33 geometry.** `base` (pre-change RTL from git) and `ctrl` (FAST_POP=false) are IDENTICAL on every number, so the default-off path prunes to the shipping netlist. `fast` is identical too on LUT/FF/CARRY8/BRAM and the census shows why: **27 LUT4 become LUT5, one per read port, and the LUT TOTAL does not move.** **Zero extra LUTs against a card at 99.81% CLB.** Harness teeth test: a fourth draw at `NPORTS_W=12` moves LUT 10,192 -> 5,663, so that is a measurement and not a silence.
- **THE ONE RISK, and it is TIMING, not area.** The new term puts `q_ready` into `do_rd`, and in context `q_ready` is the AND of 24 weight FIFOs' `q_valid` with the 3 scale ports and `xq_cnt`, fanning back to all 27 read enables. OOC gives up **0.424 ns on the core clock (11.709 -> 11.285 of 13.333)** and the binding aclk path does not move at all -- but OOC treats `q_ready` as a port. **That 0.424 ns is a LOWER BOUND; only a routed FK33_CARD=1 build answers it**, and the shipped build routes at WNS +0.001. Fallback if it does not close: register `q_ready` into `do_rd`, one FF per port, giving back part of the lever -- not designed, not measured.
- **NEXT, and it is one line for whoever runs the next card build:** `hw/fk33/gen_fk33_engine.py` `FAST_POP_DEFAULT = False -> True`, regenerate, `git diff` the output. Then read the CORE-clock row of the timing summary (the global WNS lives in the AXI domain and will not move), confirm CLB does not move, and read the engine's `CYCLES`/`BEATS` registers per job: **expected ratio about 1.01 against today's 1.51.** Nobody has ever read those two registers per job on the card.
- **OPEN:** the in-context timing above; no DUAL_CLK rate simulation (every number here is single-clock, as TRACK COUNTERS' were); a 3.2% bench-to-card residual at the 2048x4096 shape, same direction and same size as BMOVER's unexplained 2.5%; whether HBM can actually sustain one word per core cycle (DERIVED yes at 60% duty on the busiest pseudo-channel, never measured); and **`rtl/fk33_eng_cdc.vhd`'s two `async_fifo` instances carry the same 2-in-3 cadence, are another track's file, and nobody has asked whether D's 2,963,566 cycles of `S_XRD`/`S_DRAIN` contain any of it.**

### 2026-09-20 TRACK BNARROWSYN: `NWIDE` costs the +28 BRAM tiles it was DERIVED to cost and REFUNDS 368 LUT and 1,659 FF; URAM takes the whole thing and gives 28 tiles back

- **No hardware. Four OOC Vivado draws of `gdn_state_store` at 9B**, one at a
  time, `MemoryHigh=10G`, none at its cap (peaks 3.1-3.4 GB, zero swap).
  `sim/ooc_bnarrow_run.sh` + `sim/ooc_bnarrow.tcl`, raw output in
  `hw/fk33/results/bnarrow_ooc_2026-09-20/`, write-up appended as the last
  section of `docs/debugging/2026-09-20_b-job-660k-cycles.md` (append only).
- **MEASURED, all arms at `PIPE WIDE MAXOUT=8` so `ctrl` IS the card path.**
  `NWIDE=true`: **+28 BRAM tiles (28 -> 56), -368 LUT, -1,659 FF**, URAM/DSP
  and the synthesis WNS estimate unchanged to the digit. The DERIVED tile
  figure was exact; the LOGIC term has the other sign, because the three
  movers give back more than the memories take (`u_edma` -298 LUT/-808 FF,
  `u_cdma` -183/-806, `u_kdma` -373/-297 against `u_conv` +484, `u_cw` +385).
- **`CONV_STYLE => "ultra"` takes the unit's Block RAM Tile count to ZERO**:
  112 banks -> 112 URAM288, `8-10226` and `8-7186` **0 in all four logs**,
  census names all 144 URAM. DERIVED on the placed card that is 567 -> **539
  tiles (133 free)** and URAM 32 -> 144 of 320. It needs the `chk_style`
  guard widened in `rtl/gdn_conv_tap_mem.vhd` and `rtl/gdn_conv_w_mem.vhd`.
- **THE REJECTED 12-BANK ARM WAS REJECTED FOR THE WRONG REASON.** Built,
  bench-verified (107/107, two mutations of the sub-word decode FAIL 45 and 4),
  drawn: **12 RAMB36, no LUT-as-memory blowup** -- so "refusal 1" does not
  apply to a decoded sub-word write, and the header's "same tile count" is
  wrong by 2x. It still loses, on the axis nobody argued about: **+650 LUT**.
- **VERDICT for the next card build: `NWIDE => true` FITS** (77 free tiles
  after it, 105 before, and CLB pressure goes DOWN). **Hold `ultra` one
  question**: the BRAM mapping report states `READ_FIRST` per port and the
  **Ultra RAM report has no write-mode column at all**, and neither GHDL nor
  OOC synthesis can tell you what a URAM288 returns on a same-address
  collision. Diffs for both levers are in the results README; the files
  (`rtl/llama_top.vhd` and the two memories) belong to other tracks.
- **TRAP, recorded because it nearly fired:** the rejected arm's source is a
  SECOND `gdn_conv_tap_mem`, and `sim/regress.sh:1472` globs `sim/*.vhd` into
  one provider slot per design unit. In `sim/` it would have silently
  re-pointed every gate row at the rejected arm. It lives in the results
  directory instead. Also: a Vivado message count of exactly **100 is the
  message limit**, not a census -- five ids hit it here.

### 2026-09-20 TRACK WIDEDRAIN: lever L1 is applied, MEASURED in `llama_top` to the cycle, and the specified patch was wrong in three places

- **No hardware, no Vivado. GHDL only.** Write-up appended as section 10 of
  `docs/2026-09-20_d-side-vector-traffic.md` (append-only, DSIDE's sections
  1-9 untouched).
- **MEASURED in the integration top, not in an extracted copy** -- which is
  the open item DSIDE 6.3 left. `sim/tb_llama_top_real` (drain narrow)
  **26,382 cycles** a token; `sim/tb_llama_top_wdrain`, the SAME generic map
  plus `A_DRAIN_WIDE => true`, **24,204**. Delta **2,178**. DERIVED from that
  schedule's 37 drained A jobs, `sum(M) = 2,904` against
  `sum(ceil(M/4)) = 726` = **2,178**. Model and integration agree to the
  cycle.
- **All four landmarks bit-identical across the arms**, `EXP_STEPH` included
  -- a running hash over EVERY region write, region-tagged, in order. The
  whole write STREAM is identical, not just the residual.
- **THE PATCH AS SPECIFIED REFUSES THE WHOLE TREE.** Its elaboration pin is
  `0 - (A_ROWS_IF mod LANES)` and llama_top's defaults are `A_ROWS_IF = 4`,
  `LANES = 8` -- a negative `natural` in every configuration including
  `A_DRAIN_WIDE => false`. `A_ROWS_IF = 4` is forced: `A_NPORTS` is the
  package constant 5. Pinned on `boolean'pos(A_DRAIN_WIDE)` instead, and
  widened to admit both nestings.
- **AND IT WAS IN THE WRONG ARM FOR THE CARD.** `llama_top.vhd:4394` is
  `ga_real`; the card sets `A_DESC` and runs `ga_desc`, which lives inside
  `tools/gen_cardtop.py`. Applying L1 to `rtl/llama_top.vhd` alone saves the
  card NOTHING. Applied to both; the generated `rtl/fk33_llama_top.vhd`
  carries it.
- **THERE IS A THIRD `v_reg_d` SITE AND IT IS THE INSTRUMENT.** `wsump`, the
  observability write hash, read the D-vec destination as if it were the
  group port's region. Found by the bench, not by reading: three landmarks
  agreed and `EXP_STEPH` moved 17333 -> 26718. The data was right and the
  observer was wrong.
- **VERIFIED, not trusted:** 311 A jobs at the 9B shape, 296 draining,
  `dst_off` in {0, 2048, 4096} and `n_rows mod 8 = 0` for every one.
  `sum(M) = 1,426,944` -> `178,368`, **saving 1,248,576 a token (4.15%
  striped)**. One number sharpened: `build_plan`'s default is 297 A jobs; 311
  is the count with the lm_head's 15 windows.
- **A_DRAIN_WIDE STAYS FALSE.** It has never been synthesised, the fallback
  is a run-time branch so both muxes are built, and only a routed A/B answers
  timing. The ask is one OOC or routed pair, not a card build on trust.
- Files: `rtl/llama_top.vhd`, `tools/gen_cardtop.py`,
  `rtl/fk33_llama_top.vhd` + `sim/tb_fk33_cardtop_ident.vhd` (generated),
  `sim/tb_llama_top.vhd` (one generic), `sim/tb_llama_top_wdrain.vhd` (new
  row), `sim/mutate_a_drain_wide.sh` (new teeth).

### 2026-09-20 TRACK IMGLOCK: the card now says which image it is holding, and every tool refuses a manifest that disagrees

- **The defect, MEASURED this morning: nothing on the card recorded which
  packed image was resident and nothing on the host checked.** The flat
  manifest was driven at the lane-striped image; both declare
  `desc_arena_base = 0x1ffadd000`, so the flat descriptor table overwrote the
  striped one, and `pl_open` programmed the flat `kv_base = 0x10d93e000` into
  the KV seam register so C wrote its records into the WEIGHT image.
- **`109dc27` (C's KV base as a host-programmed register) is what made the
  striped image runnable and delivered 2.04x, AND is what converted this class
  from a wrong answer into data loss.** Both halves of that trade are real and
  the register stays. This is the guard it needed.
- **The interlock**: `fk33_load_weights.py load` writes a 512-byte IMAGE
  RECORD into the last 512 bytes of the descriptor arena extent the manifest
  already reserves (`0x1ffb03e00` on every 9B set) -- the eleven region
  numbers verbatim plus a BLAKE2b-128 PLACEMENT fingerprint over every piece
  address. `pl_open`, `fk33ctl.py seam --manifest`, `fk33_imgfp.py check` and
  `fk33_chat.sh` read it back and REFUSE on disagreement, naming both
  manifests and the field. It is invalidated BEFORE the first weight byte
  moves, so a load that dies half way leaves "no image", which is a refusal.
- **PLACEMENT, not content, and that is measured, not assumed.** All 250
  per-file `blake2b_128` are IDENTICAL across flat, striped and seg27, so no
  content digest separates them; `-striped` and `-striped-seg27` place all 250
  objects and every piece at IDENTICAL addresses and differ only in the GDN
  state and KV regions, so the `c419de7` byte probe cannot separate them
  either. That was its stated gap and it is now closed: the six packed sets
  fingerprint to six distinct values.
- **The incident predicted exactly from the two manifests: 35 objects, 0
  missed and 0 extra**, at every token count from 1 to 34, once `C_MAXPOS` is
  read from the CARD (65536) rather than from the morning's document
  (131072, which predicts 41).
- **TEETH, all green and all off-hardware:** `server/tests/imglock_selftest.c`
  13 rows / 15 checks against `fk33_sim` with **X3 the attribution control**
  (the same pair, no record: ACCEPTED, so nothing else in `pl_open` catches
  it) and **X12 the ordering row** (the refusal lands before the v2 program
  check, i.e. before any base register is written);
  `fk33_imgfp.py selfcheck` 32 rows including two NOT-BITING rows under their
  own names and a two-way C/Python cross-check; three new R rows in
  `fk33_load_weights.py selfcheck`.
- **Gate row `sim:imglock`** = `make -s -C server imglock-check`, all three
  suites in one command, **0.42 s, 24 MB peak**, no card, no model file, no
  `/mnt/storage`.
- **FOUND WHILE BUILDING IT, both recorded in the doc:** the record's
  `objs_loaded` was counted against `mani["files"]`, which omits the GDN
  constant image, so every full load recorded itself as PARTIAL (`5 of 4`);
  and a 512-byte write at `0x1f0027e00` made the loader selfcheck's sparse
  fake-HBM really extend to 8.32 GB, which the `M9` mutation then `f.read()`
  whole -- **18 MB / 0.05 s became 7,953 MB / 7.25 s while every row still
  printed PASS.** Bounded to `f.read(span)`: 20.5 MB / 0.10 s.
- **NEXT, and it needs the card, so the dispatcher runs it:** the resident
  seg27 image predates the record, so `fk33_chat.sh` will REFUSE (the byte
  probe reports both striped images and an ambiguous probe is a refusal by
  design). Run `fk33_load_weights.py verify <seg27 manifest>` then
  `fk33_imgfp.py write <seg27 manifest>`, then `fk33ctl.py seam --manifest
  <seg27 manifest>` and a bare `fk33_chat.sh` to confirm it selects seg27.
- **Files owned:** `hw/fk33/host/fk33_imgfp.py`, `fk33_load_weights.py`,
  `fk33_chat.sh`, `fk33ctl.py`, `fk33_resident_image.py`,
  `server/fk33_imglock.[ch]`, `server/tests/imglock_selftest.c`,
  `server/pl_backend.[ch]`, `server/fk33_sim.c`, `server/fk33_seam.h`,
  `server/Makefile`, `sim/regress.sh` (one row),
  `docs/debugging/2026-09-20_two-manifests-one-card.md`.
- **Full write-up:** `docs/debugging/2026-09-20_two-manifests-one-card.md`,
  with the REJECTED list (a new seam register; a carved page at the top of
  HBM, which has NO gap and would refuse every existing image until every
  manifest was re-derived; a host-side state file; a content digest).

### 2026-09-20 TRACK BNARROW: the three NARROW movers are beat-wide too -- 307,784 -> 222,805 cycles a B job, -84,979 at every read latency

- **Landed at `748ff91`.** One generic `NWIDE` on `rtl/gdn_state_store.vhd`,
  default FALSE, gives `gdn_exp_mem`, `gdn_conv_tap_mem` and `gdn_conv_w_mem`
  a beat-wide port and puts the exponent, conv-tap and constants movers in
  `gdn_state_axi`'s existing `WIDE` mode. Closes ranked fix 4 and the open
  item "the three small movers' per-beat cost" of
  `docs/debugging/2026-09-20_b-job-660k-cycles.md`, which now carries the full
  appended write-up.
- **THE MECHANISM WAS THE PORT WIDTH AND NOTHING ELSE.** MEASURED on this
  tree with PIPE+WIDE already on: `ld_exp 4,142`, `ld_conv 24,622`,
  `ld_const 33,069`, `sv_exp 4,114`, `sv_conv 24,593` = **90,540 of 307,784,
  29.4%**, i.e. 32 cycles per beat on the exponents and 16 on the other two.
  That is `WPB = AXI_DW/WORD_BITS` exactly. Not a handshake (PIPE removed
  that), not the shared AXI pair (the phases are serial and R was
  back-pressured 57,846 cycles), not latency (swept 0/40/80, `ld_conv` moves
  39 and 79 cycles -- once per phase).
- **MEASURED, `MAXOUT 8` as the card runs it, RD_LAT 0/40/80:**
  307,628/307,784/307,944 -> **222,649/222,805/222,965**, exactly **-84,979**
  at every latency. Per beat 32.4/16.0/16.0/32.1/16.0 ->
  1.35/1.03/1.02/1.14/1.01. All **770,970** value checks green including the
  adversarial stalled pass.
- **THE LATENCY SENSITIVITY INVERTS AT `MAXOUT 4`**, which is why it was
  swept: with NWIDE on, `ld_const` becomes 2,069/2,108/**3,236** because four
  bursts of 16 cover 64 cycles and the consumer now takes one. `MAXOUT 8`
  removes it (2,148 at RD_LAT 80) and the card already passes 8. NWIDE adds
  no new requirement, it depends on one already met.
- **VALUES, against an independent oracle, from ONE private worktree two
  lines apart:** `sim:seamgate_bconst` **PASS in both arms** (176s and 148s)
  against `tools/ref9b/gdn_oracle.py`. `tb_llama_top_bconst`, same two arms:
  all four pinned landmarks unchanged (`EXP_X0 => 10278` ...), `R_X
  bit-identical`, jobs issued / completions / KV records / KV beats identical
  element for element, and **-8,460 cycles per token, three times exactly**.
- **TEETH: 13 mutants, every attribution control green.** The row worth
  reading is **N6, which DID NOT BITE -- and that was a mutant defect, not a
  blind check.** Replacing a registered select with a combinational one while
  leaving the VHDL sensitivity list alone makes the mutation DEAD; it passed
  385,488 checks in one bench and 107 in another and was about to be written
  up as a resolution floor. With `ra_s` added to the list it kills 24,564
  checks. **N11** (done one beat early) hangs in BOTH arms, so its kill
  belongs to an older property and is not counted. **N12** (NWIDE not
  threaded through) moves no value at all: it is caught only by the new
  `BNARROW_BOUND` phase check, and with `-gNBOUND=false` it passes all
  385,483 value checks.
- **GATE, verbatim:** `--only gdn OVERALL PASS 21 FAIL 0 NOCHECK 1` (the
  NOCHECK is the pre-existing `tb_gdn_conv_cycles`, unchanged);
  `--only bmover OVERALL PASS 1`, `checks=770970 job_cycles=222805`;
  `--only tb_llama_top_b OVERALL PASS 3`.
- **NEXT, and it is one line the dispatcher applies**, because
  `rtl/llama_top.vhd` is TRACK DSIDE's file: in `u_state`'s generic map,
  `WIDE => true)` becomes `WIDE => true,` plus `NWIDE => true)`. Nothing else
  changes; llama_top is the input to three generators, so run the `--check`
  rows after.
- **DERIVED card effect** at 24 jobs a token, with the 2.5% bench-to-card
  residual carried rather than absorbed: **2.04 M (additive) to 2.09 M
  (proportional) cycles a token, 27.2 to 27.9 ms at 75 MHz**. On the
  lane-striped image that is about 9.4% of the token, and BENABLE plus
  BNARROW together about 34%.
- **OPEN, and it is the first thing anyone should run: THE CENSUS.** No
  Vivado ran in this track. The two conv memories' WIDE arms are **48 and 64
  banks of 512 x 16**, DERIVED at +12 and +16 BRAM tiles (28 -> 56 in
  `gdn_state_store`); `gdn_exp_mem`'s 32-way banked distributed RAM is not
  even derived. The 12-bank alternative with a wider word has the same tiles
  and makes the UNIT write a sub-word slice, which is the refusal that
  MEASURED 0 BRAM and 28,160 LUT on `gdn_conv_tap_mem` once already -- so the
  bounded-area risk was taken deliberately over the silent-inference one.
  Count `[Synth 8-10226]` and `[Synth 8-7186]`, read
  `report_ram_utilization` and an object-level census, and do not transfer
  TRACK BMOVERSYN's 32 URAM288 result: different array, different shape.
- Also open: whether 512-deep banks pack; the 2.5% residual, inherited;
  `gdn_block`'s own 149,579 cycles are now **67%** of the job and the mover
  is 71,164, so the recurrence is the next lever, not the mover.

### 2026-09-20 TRACK PREFILL: batching A across prompt positions is a COSTED NO -- 1.100x, capped at K=2, and K=2 needs 1,536 DSPs against 793 free

- **Scoping only. No RTL changed, no hardware, no Vivado.** Peak RSS
  **10,944 KiB MEASURED** (`/usr/bin/time -v`, the manifest parse; everything
  else was awk/grep). Write-up: `docs/2026-09-20_prefill-batching-scope.md`.
- **THE CRUX, settled from the RTL.** The array is exactly one weight word
  wide, and it is an identity, not a ratio: `NPORTS_W * AXI_DW = 24 * 256 =
  6,144 = ROWS_IF * BLK * 4 = 48 * 32 * 4`, with the scale side matching at
  `3 * 256 = 48 * 16` (`hw/fk33/gen_fk33_engine.py:84-98`, `:225-228`;
  `rtl/matvec_core.vhd:983-1008`). **So the structural floor is 1.000 cycles
  per word and the striped card MEASURES 1.5298: the multiplier array is busy
  65.4% of core cycles.** Per word it does `BLK*ROWS_IF = 1,536` products;
  K positions need K passes, so per-position cycles per word is
  `max(K,1.53)/K` -- **1.000 at K=2 and at every K after it. The ceiling is
  1.53x of A's engine time and K=4, 8, 16 are worth exactly what K=2 is.**
- **AND "BEATS" HAS NEVER MEANT AXI BEATS.** `rtl/matvec_int4_desc_axi.vhd:
  68-70` says so outright. Re-derived independently from the manifest's own
  shapes over the 249 tensors the profile touches: **5,184,256 weight words,
  0.0025% from the ACLK doc's 5,184,384**, = 3.98 GB of weight traffic a
  token. Read as AXI beats it is 166 MB, wrong by 24x (= `NPORTS_W`), and the
  engine would have looked memory-starved.
- **THE AMDAHL BOUND, and it is what decides it.** Batchable = A engine-side
  only = 7,931,072 of 30,115,246 = **26.3%**. B (52.6%) is recurrent
  (`gdn_recur_pipe.vhd:506`, `gdn_recur.vhd:595-600,632`,
  `gdn_block.vhd:889-894`) and fetches NO weight from HBM -- its projections
  are A-job outputs (`llama_top.vhd:5382,5399,5417,5438`). C writes one
  position (`attn_block.vhd:1433,1454`), sweeps the whole context
  (`:1665-1673`) and touches only the KV cache. The three VEC ops are
  element-wise with an on-chip ROM gain (`llama_top.vhd:466-467`). A's own
  card-side 2.96 M is per-position too. **Result: 1.100x today, 1.144x after
  BENABLE, and the hard ceiling with A's engine time at ZERO is 1.358x
  (1.570x after BENABLE).** 500-token prefill 200.8 s -> 182.5 s.
- **IT DOES NOT FIT ANYWAY.** MEASURED, the shipped build's own
  `bd_wrapper_utilization_placed.rpt`: **DSP 2,087 of 2,880 (793 free)** and
  **CLB 54,854 of 54,960 = 99.81% (106 free)**. K=2 wants +1,536 DSP and
  about 21,000 LUT of fabric adder tree. **The "109% LUT" figure is the
  2026-09-16 build and is superseded; the free-LUT count (76,585) is not
  headroom, the 106 free CLBs are.**
- **THE SHARPEST LINE IN THE REPORT.** Full batching and simply closing A's
  own accept-port idle save the **identical 2,746,816 cycles**, because both
  are capped by the same 1-word-per-cycle floor. One costs 1,536 DSPs that do
  not exist and helps prefill only; the other costs none and helps generation
  too. **Batching is the cheaper fix with a DSP bill attached.**
- **Ranked alternatives** (cycles/token): overlap positions t/t+1 (A||B)
  14.26 M, prefill-only, 0 DSP, **1.899x** (1.531x after BENABLE), LUT cost
  NOT estimated; BENABLE 8.28 M, both, landed; A clock split 3.98 M, both,
  unbuilt; close A's idle 2.75 M, both, 0 DSP; batching 2.75 M, prefill only,
  impossible. **Overlap and batching are equally prefill-only**, which is the
  argument for the other three.
- **Cross-reference TRACK DSIDE:** A's 1.25 M drain cycles through the
  one-element region port are inside the 2,963,566 card-side figure this
  track treats as non-amortisable, so DSIDE's fix and this verdict do not
  conflict -- DSIDE shrinks the serial part, which RAISES batching's ceiling
  and lowers its absolute value.
- **Open, not determined:** the slope of C against position (bandwidth floor
  272 cyc/position, FSM cost uncounted, under 2% at 500 tokens either way,
  and **no C_JOB has ever been measured at a position other than 0**); where
  A's 8,832 cycles per job of overhead go (the card's own `CYCLES`/`BEATS`
  counters can be read per job and nobody has); whether the overlap lever
  fits in 106 CLBs.
- **NEXT, and it is the operator's call:** nothing here is a dispatchable
  change. If prefill is the goal, scope the overlap lever's LUT cost; if
  throughput generally is the goal, rows 2-4 all beat it and two of them are
  already written.

### 2026-09-20 TRACK DSIDE: 5.15 M cycles a token go through a ONE-element region-file port while an EIGHT-element port sits beside it with one client; A's drain is 1.25 M of them and the fix is llama_top-only

- **The on-card control needs no new measurement.** Same length N = 4,096,
  same region file: `VEC_RES` (the group port) **1,058 cycles**, `VEC_NORM`
  (the element port) **11,336**. `seq_vec_res` reads TWO operand regions and
  writes one and is still **10.7x cheaper per element**. The region file has
  four ports (`llama_top.vhd:1334-1389`); the LANES = 8 group read (two
  operand regions at once) and group write (per-lane `w_be`) have exactly one
  client between them.
- **MEASURED census, 5,153,058 cycles = 17.11% of the striped token and 8.32%
  of the flat one:** A `S_XRD` 1,536,622, A `S_DRAIN` 1,426,944, `VEC_SWG`
  1,179,840, `VEC_NORM` 532,740, B 394,944, C 81,968.
- **TRACK ACLK's S_XRD/S_DRAIN figure is CONFIRMED to the cycle** and was
  0.21% low: `sum(K+2) + sum(M) = 2,963,566` exactly, plus `311 x 20` fixed
  states = 2,969,786, **27.26%** of the striped `A_JOB` total. All 311 steps
  fit `dur = K + M(drained) + 21 + 294 + 1.5101*beats` with residuals in
  **[-197, +81]**, sd 51.5 (0.147% of the mean step). **Two wrong-model
  controls:** charging the drain to the lm_head windows too gives max
  residual 13,356 (68x worse); dropping the `K+2` term gives 6,249 (32x).
- **CORRECTION to the brief:** `gvr` has TWO passes, not three (the gain is
  preloaded, `llama_top.vhd:3462-3470`), so the vector-movement total is
  **1,712,580**, not the 1,979,000 the brief DERIVED.
- **PROVED IN SIMULATION, new files `rtl/region_drain.vhd` and
  `sim/tb_region_drain.vhd`** (auto-discovered row, `OVERALL PASS 1 FAIL 0`,
  48 checks, peak RSS 664 MB): the drain goes from `n + 2` to
  `ceil(n/8) + 2` cycles with both region images identical to an INDEPENDENT
  model over the whole 49,152-word address space, at twelve shapes including
  a non-multiple-of-8 tail and two misaligned offsets that correctly FALL
  BACK. 11 mutants, 9 BITE (2 of those as range errors); **N1_no_reset
  SURVIVES and is reported: the extracted entity has one entry point, so
  llama_top's path-independent `r = 0` reset is invisible here.** Attribution
  control (model replaced by narrow-vs-wide): every kill is attributable to
  the round trip, so the independent model bought nothing against THIS
  mutant set.
- **DERIVED: -1,248,576 cycles a token, 4.15% striped / 2.02% flat**, exact
  arithmetic over the schedule rather than a ratio.
- **THE PATCH IS WRITTEN OUT, NOT APPLIED** -- BENABLE holds
  `rtl/llama_top.vhd`. Five hunks behind `A_DRAIN_WIDE : boolean := false`:
  a group-write region signal `wg_reg`, a `wgmux` on `act_unit` (the same
  rule `elmux` uses), `memp`'s group arm reading `wg_reg`, **`wr_region <=
  wg_reg` so the region LOCK names the region actually written** (without
  this the lever is silently wrong in the guard, not in the data), and the
  wide arm in `S_DRAIN`. All 311 A jobs have `dst_off` in {0, 2048, 4096}
  and `n_rows mod 8 = 0`, MEASURED, so the fallback never runs in the
  shipping schedule.
- **NEXT, ranked:** L2 `gsr` on both group ports + `swiglu_mem` at LANES 8
  (-1,769,472, needs new wide ports on that unit); L3 A's `S_XRD`
  (-1,344,000, but it widens `matvec_int4`'s x bank); L4 `gvr` (-465,920).
  **REJECTED, do not retry:** writing y through during `S_RUN` (only
  +178,368 over L1 and it puts region writes inside the run window); and
  overlapping drain N with XRD N+1 (a `seq_desc_fetch` change, not an
  adapter change). Detail, arithmetic and the full diff in
  `docs/2026-09-20_d-side-vector-traffic.md`.
- **`BASELINE_PASS` was NOT raised** for the new row; it is a floor so the
  gate stays green, and CLAUDE.md's rule against editing `regress.sh` while a
  gate may be live is why. The next full unfiltered gate should raise it by 1.

### 2026-09-20 TRACK SMPWIN: there is NO seam sample window; the chain that IS reachable is CONSTANT on the only reference we have

- **The question was "can the shipping bitstream publish enough of the
  token-0 logit vector through the seam sample window". NO, and the premise
  was wrong.** 0x58/0x5C/0x60 are `WIN_SEL`/`WIN_ADDR`/`WIN_DATA`, the four
  indirect windows (`fk33_seam.vhd:378-380`, `:513-517`). `W_XOUT` reads zero
  (`HOST_WINDOW=false` -> `region_mem.vhd:414`) and the logits never enter a
  region: every `FLG_TO_SMP` job has `dst = R_NONE`
  (`seq_desc_fetch.vhd:502`), and 17,376 rows do not fit `REGMAX = 4096`.
  The sampler's whole surface is ARGMAX 0x44, LOGIT_EXP 0x48, SMP_N 0x64.
  `CAPS_FLAGS = 0x3D`: bit 2 SAMPLER set, **bit 3 LOGITS clear**.
- **Closes LOGITCMP's open item** (prefix argmax under `--upto`): it works as
  derived, and MEASURED it is worth much less than it looked. On `tok0.r9bs`
  the winner 846 is in window 1 and beats every later window's maximum by
  5.17 to 10.21 logits = **16 to 33 INT4 error scales**, so the reference
  chain is the constant 846. 15 GOs = 5.93 s of card time (DERIVED from
  `profile_striped_tok0.txt`, 0.4015 s per token at 75 MHz) to confirm what
  the shipping argmax already reports. **It is a LOCALISER for a disagreement
  that already exists, not a routine check**; `next` bisects in 4 GOs.
- **The finding that changes how SMP_N is read:** the published argmax is
  `sampler_stream`'s own FOLD COUNT (`:51-62`), not `llama_top`'s `smp_idx`,
  which is wired to nothing. A lost beat shifts every later index, so
  `SMP_N == expected` is the condition under which the index means anything.
- **Landed** `84455bf`: `tools/ref9b/smpwin_sweep.py` (9 guards, `--selftest`
  14 mutants 0 fail with an attribution control per firing guard and two
  non-biting rows), `logit_compare.py` PARTIAL-vector support via a
  `LOGITS_ROWS` record (`--partial-selftest` 5 rows 0 fail; the existing
  nine-row table unchanged), `hw/fk33/host/smpwin_sweep_on_card.sh` (refuses
  on `FK33_ALLOW_HARDWARE`, exit 3). Write-up appended to
  `docs/debugging/2026-09-20_the-card-cannot-publish-a-logit-vector.md`.
- **No hardware touched. No Vivado run. Peak RSS of anything this track ran:
  75.6 MB.**
- **Next, and it is the operator's call:** run the sweep ONLY if a card
  full-token argmax disagrees with the reference. Otherwise the open items
  worth one GO each are `SMP_N` (must read 248,320), `LOGIT_EXP` and
  `FAULTS` at token 0, none of which has ever been recorded against a
  prediction. A costed logits path (A's output to HBM, one extra master on a
  build that is LUT-bound at 109%) is in section S10 of the write-up.

### 2026-09-20 TRACK BENABLE: B's mover levers are ON in llama_top (`PIPE`, `WIDE`, `MAXOUT => 8`); values bit-identical, DERIVED 8.28 M cycles per token off the card

- **The change is three lines** in `rtl/llama_top.vhd`'s `u_state` generic
  map, all three generics already existing on `gdn_state_store` and all
  three defaulting to the shipping behaviour. Nothing else in the RTL.
- **`llama_top` feeds THREE generators, not one.** `tools/gen_cardtop.py`
  (`rtl/fk33_llama_top.vhd`, what the card build compiles) was known;
  `sim/ooc_gdnadapt_extract.py` (`rtl/ooc_gdnadapt_top.vhd`) was not, and
  `sim:gdnstale` went red on the edit. Both regenerated, `--check` green,
  and `git diff` on each output carries the generic map and nothing else.
  `hw/fk33/gen_fk33_card.py` reads the generated top and was unaffected.
- **ACTIVE (MEASURED, BC-250, two isolated trees that `diff -rq` says
  differ in exactly one file):** per-token `cycles elapsed` falls by
  **5,136 x6** (bstate_seq), **7,941 x3** (bconst), **7,704 x2**
  (bstate), while jobs issued, completions, KV records and KV beats are
  identical element for element in both arms.
- **VALUES UNCHANGED:** all four landmarks identical in all three rows in
  both arms (`0 of the pinned landmarks moved`), and for bstate/bstate_seq
  those landmarks are the FLAT arm's, an implementation with no mover in
  it. `sim:seamgate_bconst` PASS on the changed tree checks the nine `R_Y`
  seams bit for bit against `tools/ref9b/gdn_oracle.py`.
- **Gate:** BC-250 `PASS 3 FAIL 0` both arms; workstation `--only gdn`
  PASS 21 / NOCHECK 1, `bmover` 1, `cardtop` 3, `fk33card` 1, `gdnstale`
  1, `seamgate` 6, all FAIL 0.
- **DERIVED for the card:** 660,601 x 0.4778 = 315,633 per job, 8.28 M
  cycles per token (110 ms at 75 MHz), about 27% off the lane-striped
  token. The 2.5% bench-to-card residual is still unexplained and the
  ratio assumes it scales; the additive alternative gives 8.07 M.
- **TRAP, and it voided the first experiment:** another track's
  `bc250-sync-llama-vhdl.sh` overwrote `rtl/llama_top.vhd` on the BC-250
  mid-baseline, because the sync pushes the workstation's WORKING TREE to
  one shared path. One row of that baseline was corrupted and one was
  not. **When a BC-250 measurement depends on an uncommitted file, copy
  the tree under `/home/labuser/` and run there.** Also: the BC-250
  needs `--timeout 3600` for `tb_llama_top_bstate_seq` (1,083 s).
- **NEXT (not this track's files):** routed timing with the levers on, in
  the next `FK33_CARD=1` build; then the three narrow movers' remaining
  90,540 cycles per job (`gdn_conv_tap_mem`, `gdn_conv_w_mem`,
  `gdn_exp_mem`). Detail in
  `docs/debugging/2026-09-20_b-job-660k-cycles.md`.

### 2026-09-20 TRACK ARENAPLACE: the GDN state is back on segment 27 where the packer puts it, one rule now, and the defect cost at most 2.5% of a B job (DERIVED 0 today)

- **CONFIRMED as STRIPE27 described it.** `.bak-arenas` (the packer) says
  `gdn_state_base 0x1b0000000` segment 27; the live manifest says
  `0x1abde4000` segment 26, with `kv_base 0x1ad71c000` also segment 26.
  26,443,776 B of GDN state and 42,876,928 B = 2,463 tokens of KV in a segment
  six weight lanes have bytes in. **One correction to the census**: it is 198
  tensors with ONE lane in segment 26 and 51 with TWO, not "two per tensor".
- **THE FIX IS ONE RULE, CALLED, NOT RESTATED.** `relayout_arenas()` now calls
  `pack_model_fk33.stripe_context_tokens()` on a striped manifest instead of
  `PK.place()`, and the new `hbm_map.stripe_residency_fails()` (fault P7) is in
  `plan().check()`, so `gen_layer_program.py` and `pack_gdn_consts.py` refuse
  the defective image too. MEASURED: a full repack and the fixed re-layout
  agree to the byte on `gdn_state_base` and `kv_base`. **On a FLAT manifest the
  result is byte-identical to HEAD's**, key for key.
- **TEETH, 29 of 29 in `check_kv_map.py --teeth`.** The mutant is the SHIPPED
  image at its real path: REFUSED on exactly one row. **Attribution control,
  the same image with only the residency rows off: ACCEPTED by all 38
  pre-existing rows**, which is the measurement that none of them could see it.
  One byte below the segment boundary REFUSED, exactly on it accepted, one
  page below REFUSED, `kv_base` alone dragged back REFUSED. **Reported not
  biting, under its own name:** one byte ABOVE the boundary, which is inside a
  reserved segment and costs nothing; its real guard is `hbm_map`'s existing
  4 KB alignment rule, MEASURED firing on it.
- **A HOLE THIS TRACK OPENED AND CLOSED (M-C).** The first fix branched on the
  lane-segment SET being non-empty, so a `lane_stripe` block with an EMPTY
  `segments` list fell through to the 4 KB rule and reproduced the defect
  silently. Branch on the BLOCK's presence; an empty lane plan is now a P7
  fault. An empty set is not evidence of a flat image.
- **THE CORRECTED IMAGE, FOR THE DISPATCHER TO LOAD:**
  `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27`. Same 250
  symlinks, **all 250 per-file blake2b equal to the shipped set and 0 of 250
  `hbm_offset` moved**; `gdn_const.bin` blake2b `ec3eda1a...b917`, equal.
  `gdn_state 0x1b0000000` seg 27, `kv_base 0x1b1938000`, KV spans segments
  27..31, all reserved. `max_context_tokens` 75,181 against the card's
  `C_MAXPOS` 65,536 (read from `gen_fk33_card.py`), margin 1.147x.
  `check_kv_map` 40 rows 0 refused; `check_hbm_stack` PASS. **The token program
  does NOT need regenerating: `.dtbl`, `.rel` AND `.arena` are byte-identical**
  because no weight piece moved and `desc_arena_base` is unchanged.
  `check_kv_map.py`'s DEFAULT striped manifest now points here.
- **MAGNITUDE, DERIVED.** At most **16,429 cycles per B job (2.5%)**, the
  unattributed residual between the card's 660,601 and BMOVER's 644,172, shared
  with three other named candidates; at most 1.3% of a striped token. **And 0
  today**, because D issues steps serially, so no weight lane is active while
  B's mover or C's KV port uses pseudo-channel 26. B asks for a 3.13% duty
  cycle on that PC (68,864 beats x 4.00 ns against an 8.808 ms job), so this
  becomes load-bearing exactly when BMOVER's lever 5 (overlap the state load
  with A) lands. **The flat-vs-striped equality is NOT a control for this:**
  flat puts the state at segment 16, which also holds weights.
- **`check_mv4i_set.py`: recorded, NOT fixed.** Re-MEASURED: 249 FAILURES rc=1
  on BOTH striped sets, PASS on flat. **Nothing in the repo invokes it** (every
  hit outside `.claude/worktrees` is a comment or docstring), so its wrong
  verdict has cost nothing. Making it striping-aware means routing its
  placement, overlap and sub-region rules through `hbm_map.file_pieces()`.
- Write-up: section 10 appended to
  `docs/debugging/2026-09-20_stripe-width-after-the-kv-halved.md` (append only).
  **Trap worth the whole section: a `cp` onto a SYMLINK writes through it and
  silently reverted this track's edits to `tools/hbm_map.py`; `git status`
  showed the file clean.**

### 2026-09-20 TRACK STRIPE27: one lane per pseudo-channel BUYS NOTHING at 75 MHz, and at most 3.2% of a token at 200 MHz. Built anyway, as a measurement image that must not be loaded.

- **The answer, DERIVED.** A pseudo-channel passes one 32 B beat every 4.00 ns
  (STRUCTURAL, `32 B / (32 B x 250 MHz)`), so two lanes get one every 8.00 ns.
  The card's striped A consumes one every **20.40 ns** (MEASURED, 7,931,072
  cycles over 5,184,384 beats at 75 MHz): the supply bound is slack by 12.40 ns
  and **the memory is already idle 61% of the time**. At 200 MHz the demand is
  10.15 ns against the same 8.00 ns, still 21% slack. Halving the bound to
  4.00 ns changes nothing that binds at either clock.
- **AND THE PREMISE WAS WRONG.** The KV halving freed nothing. The packer's bar
  has been `DEFAULT_MIN_CONTEXT_TOKENS = 65536` since 2026-08-30, which is the
  number `C_MAXPOS` was lowered TO; `gen_fk33_card.py`'s own comment says the
  halving was done "so the STRIPED layout fits", i.e. the card was writing a
  131,072-token extent into a layout that yielded 75,340. Re-running the
  identical width search: chosen width `n = 10` before, `n = 10` after.
- **The curve, re-run (MEASURED).** n=12 -> 1 lane/PC, 61.8% fill, 44,432 tok;
  n=11 -> 2, 69.7%, 59,852; **n=10 -> 2, 74.2%, 75,272 (chosen)**; n=9 -> 90,692;
  n=8 -> 106,113; n<=7 REFUSED (segment overflow, then 3+ lanes per PC).
- **The image exists**: `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-stripe27`,
  27 lanes on 27 segments, **max 1 lane per PC on all 249 tensors** (census),
  all 7 stripe checks PASS, `check_hbm_stack` PASS. **250 of 250 blake2b digests
  equal the shipped striped set** while 2,978 of 6,972 pieces moved and 2,534
  changed pseudo-channel: the addresses changed, the values did not.
- **DO NOT LOAD IT.** It yields 44,341 tokens against the card's `C_MAXPOS`
  65,536. `tools/check_kv_map.py --striped-manifest <it>` refuses on 3 rows
  (past `hbm.size`, into `gdn_const`, into `desc_arena`). The boundary is exact:
  `C_MAXPOS=44342` REFUSED, `44341` ACCEPTED. Needs a card at 32,768.
- **NEW REFUSAL in `tools/pack_model_fk33.py`.** `--stripe-min-context` is an
  operator preference; the card's `C_MAXPOS` is a compiled-in extent, and
  nothing connected them, so the packer wrote an unloadable image and reported
  success. Added `scrape_card_maxpos()` (scrapes `hw/fk33/gen_fk33_card.py`),
  the refusal, `hbm.card_c_maxpos` / `card_kv_tokens_available` /
  `card_kv_fits`, and `--stripe-allow-under-maxpos`. **Attribution control: the
  same layout with the new check off is accepted rc=0 with 7 of 7 pre-existing
  stripe checks PASS.** Controls: the shipped n=10 and the flat set both re-pack
  byte-identical with `card_kv_fits: true`.
- **A separate defect found on the way, in the LOADED image.**
  `hbm_map.write_arenas()` re-places the GDN state with a 4 KB round-up and
  never reads `lane_stripe`, so it pulled `gdn_state_base` from segment 27 back
  to segment 26 in the shipped striped manifest. 26.4 MB of GDN state and the
  first 2,463 tokens of KV now share pseudo-channel 26 with two weight lanes.
  The packer refuses exactly this placement; the second allocator bypasses it,
  and `check_kv_map` passes it because the bytes do not OVERLAP a piece. Not
  fixed here. Magnitude unmeasured.
- **Token program generated** (`gen_layer_program.py --token --x-exp 0`): the
  `.dtbl` and `.rel` are byte-IDENTICAL to the shipped striped set's and only
  `token.arena` differs (10,376 of 159,232 B), which is the 27 per-lane bases.
- Write-up: `docs/debugging/2026-09-20_stripe-width-after-the-kv-halved.md`.
  Also REJECTED there: `check_mv4i_set.py` reports **249 FAILURES on the
  SHIPPED striped set too** (v1-only), so its verdict on any striped image
  carries no information.

### 2026-09-20 TRACK LOGITCMP: the logit-level comparison at token 0 CANNOT BE MADE on the shipping bitstream. The whole comparison path is built, teeth-tested and green; the card has no vector to give it.

- **The blocker, three independent reasons, any one sufficient.** (1) The v2
  window seam publishes ARGMAX and LOGIT_EXP and nothing else
  (`rtl/fk33_seam.vhd:91-94`; `pl_backend.c:1243` refuses the request).
  (2) Subsystem A has no HBM write-back for its output -- `y_addr` is a 16-bit
  local bus, and `gen_wb` is the WEIGHT-fetch generate. (3) The region
  read-back window is compiled out: `gen_fk33_card.py` passes
  `HOST_WINDOW=false`, so `hr_data` reads zero. Evidence in the transcript
  itself: `c2h 0` over 182 GOs.
  Write-up: `docs/debugging/2026-09-20_the-card-cannot-publish-a-logit-vector.md`.
- **Built anyway, because both halves already existed and only met at a card
  that does not.** `run_prompt --dump-logits <p.r9bs>` writes token 0 as
  `LOGITS` (S32 + shared exponent), `LOGIT_EXP` and `TOKEN` in the EXISTING
  `tools/ref9b` stream format -- `seam_stream.h`'s C writer reused, not
  reimplemented -- so `r9bs.py` and `check_token.py` read it unchanged.
  `tools/ref9b/logit_compare.py` adds what neither owns: ranks, top-k overlap,
  the best-fit scale, the residual distribution and a **per lm_head window**
  breakdown over the 15 shards. MEASURED against the simulated v1 card at the
  real 9B shape: 0.18 s, 60 MB.
- **On a v2 card it reports UNAVAILABLE and exits 2, never 0.** That took three
  attempts to get right and is the part most likely to have been wrong
  silently.
- **New gate row `sim:logitcmp`**, self-contained (no GGUF, no manifest, no
  capture, no card): 9 mutations of a synthetic 248,320-element dump scored PER
  FIELD, with `check_token.py` as the attribution control on every row.
  MEASURED 3.0 s, 75 MB, `OVERALL PASS 1`. Two mutants deliberately DO NOT
  bite: `common` (an error both inputs share -- the resolution floor) and
  `tokenbias` (check_token's kill by construction). Teeth on the teeth: two
  mutants of the comparator itself fail exactly one row each.
- **The operator procedure is `hw/fk33/host/logit_compare_on_card.sh`**, which
  prints its commands and refuses to touch hardware (exit 3 if
  `FK33_ALLOW_HARDWARE` is in the environment). `--check` verifies every
  precondition that does not need the card. **Use the one-id prompt 248045**,
  not the DC-DC prompt: the existing reference capture is that id (its own log,
  `argmax=846 logit=12.782196`, matching the record's `max=+12.7822`).
- **NEXT, for whoever picks this up.** Either (a) record `SMP_N`, `LOGIT_EXP`
  and the argmax at token 0 on the one-id prompt, which runs today and is
  unmeasured, or (b) decide whether a logits-DMA bitstream is worth a build.
  The host half is already written and tested.

### 2026-09-20 TRACK ACLK (verification pass): the A clock-domain split is VERIFIED to the limit of what runs without synthesis. Byte-identity OFF holds; `--bd-only` with the switch ON PASSES on the BC-250 WITH an OFF control beside it; `sim:runguard` goes RED if the switch is exported without `FK33_CARD=1`.

- The first attempt committed `99e5d99` / `886ebc0` / `11a4d6a` and was
  rate-limited before reporting ANY verification. Everything below was re-run
  from scratch, not inherited. Appended as section 9 of
  `docs/2026-09-20_a-clock-domain-split.md` (pure append, 346 lines).
- **Byte-identity OFF: MEASURED.** Regenerated with `FK33_CARD=1
  FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75`, both SHA256 unchanged,
  `git diff` empty, rc=0 checked BEFORE the diff was believed. **Teeth added:**
  in a throwaway worktree, OFF vs ON differ by 177 tcl lines and 9 xdc lines,
  so the identity test is not passing because the switch does nothing.
- **Gate rows, seven each column.** OFF: `tb_eng_cdc` 1, `seamgate` 6,
  `cardtop` 3, `fk33card` 1, `runguard` 1, `bdports` 1, `srvseam` 1, all
  `REGRESSION: PASS`. ON: identical **except `runguard` PASS 0 FAIL 1**.
- **That red row is the generator's own guard, not a defect.** `sim:runguard`
  runs `gen_pcieep.py --selftest` with no `FK33_CARD`, which is the one
  configuration the split refuses (`ABORT: FK33_ENG_SPLIT_CLK=1 without
  FK33_CARD=1`). With both exported the row PASSES (MEASURED). Section 6's
  "runguard PASS 1 / PASS 1" is **withdrawn as written** -- true only for an ON
  column that also sets `FK33_CARD=1`, which was not stated. **The switch is
  not composable with a whole-gate run**; open for a decision, not changed.
- **`--bd-only` ON, on the BC-250, WITH THE OFF CONTROL.** Lane gated on
  PRESENCE by `/proc/PID/exe`, address re-resolved from the router lease,
  tree synced first. Both runs: `FK33_BD_ONLY_DONE` x2, `FK33_BD_VALIDATE OK`
  x2, `FK33_UNCONNECTED count=0`, `^ERROR:` 0, zero REAL `41-759`, peak
  3.8 GB under a 6G cap. **The split adds exactly four CRITICAL WARNINGs**
  (`BD 41-737` read-only on `eng_cdc`'s clock/reset pins) against 3 of the
  identical class already in the shipped OFF build. Everything else in the
  census is unchanged, including the 32 pre-existing `41-1377`.
  It ANSWERS section 8's open packager question: `sa`/`ma` ARE inferred as
  AXI-Lite and the two-hop 256-byte assignment resolves.
- **The 41-759 count is the log-contains-its-own-script trap again.** An
  unanchored `grep -c` says 1; the hit is `pcieep_build.sh`'s echoed source.
  Real Vivado messages: **0**.
- **Mutants: 15 of 15 as expected**, both attribution controls biting (W12/W34
  for the redundant wait pairs, G2 for G1). Seven survivors reported under
  their own names with the real guard for each. The bench already drives BOTH
  ratios (13.333/5 then swapped 5/13.333, periods are signals), 11,678 checks
  counted in variables, so the one-ratio objection does not apply.
- **Constraints, anchored.** `^set_clock_groups .*-asynchronous` 2 -> 3;
  `^set_max_delay .*-datapath_only` **0 in both**; no `if` in the file, so the
  XDC reader cannot skip the block. The missing max-delay is DELIBERATE -- a
  clock group is a false path and outranks a max-delay exception -- but the
  consequence is real and now recorded: **nothing bounds routed skew on the
  crossing**, justified by precedent only.
- **Projection re-derived; section 7 reproduces EXACTLY** (striped 0.4015 ->
  0.3484 s, 1.15x). **At 200 MHz A is datapath-bound, not memory-bound:** one
  PC gives 32 B per ACLK cycle at 250 MHz = 4.0 ns/beat, 2 lanes per PC = 8.0
  ns/lane-beat = 1.60 cycles at 200 MHz, against a measured 2.03, so **21% of
  the busiest PC's supply is still unused**. **CORRECTION:** section 7's flat
  row used an unsourced 108 ns/beat and so projected flat getting SLOWER than
  measured; the profile's own arithmetic gives **102.16 ns/beat**, flat token
  0.8254 s, **1.00x**. Conclusion unchanged, number corrected.
- **The post-split token depends on B.** B is MEASURED at 660,601 cycles/job
  (52.6% of a striped token); another track's levers project ~308k (ESTIMATE).
  DERIVED: split alone 1.15x, B alone 1.39x, **both 1.70x (0.2356 s)**. If B
  lands first the A split's share RISES from 15% to 23%.
- **A trap worth knowing: `gen_pcieep.py` is NOT path-portable.** It ABORTs
  from any checkout that is not `/home/orencollaco/GitHub/llama.vhdl`, because
  a guard compares an absolute path baked into `build_fk33_i2cprobe.tcl`.
  Harmless today only because `bc250-sync-llama-vhdl.sh`'s `DEST` happens to
  be exactly that path. Third file with this trap.
- **NOT DETERMINED:** anything needing synthesis or routing (timing, area,
  `report_cdc`, `FK33_ENGSPLIT`, the 44 RAMB36 y FIFO, `clk_wiz_0`'s four
  outputs from one VCO); the routed skew; why Vivado refuses `ASSOCIATED_RESET`
  on `eng_cdc`; `seamgate`'s six rows are unattributable because another track
  was editing `rtl/swiglu_mem.vhd` while they compiled; and the projection is
  still cross-build arithmetic until the card's own counters are read at
  200 MHz.
- **No hardware was touched and no Vivado ran on the workstation** (a card
  build held its lane throughout).

### 2026-09-20 TRACK SWGFAST: LANDED at `7ed6535`. VEC_SWG's 5.0 cycles/element is 1+1+2+1 (G load, U load, the unit's two passes, write-back). `swiglu_mem` gains LANES (default 1); at LANES = 4 the unit is 6,157 cycles instead of 24,588 -- which is 30% of the VEC_SWG step and **0.95% of a token**. NEEDS ONE LINE IN llama_top TO REACH THE CARD. NEVER SYNTHESISED.

- **Accounting** (docs/debugging/2026-09-20_vec-swg-5-cycles-per-element.md):
  the unit is 2N + 12 = 24,588 (MEASURED, `SWGFAST_CYCLES` in
  sim/tb_swiglu_mem.vhd); llama_top's `gsr` adds N+2 for each of G, U and
  the write-back. DERIVED 61,459 against the card's 61,473; VEC_NORM leaves
  the identical 14-cycle residual (unit 3,125 MEASURED `NORMFAST_CYCLES`,
  11,322 against 11,336). Neither unit has a per-element multi-cycle loop.
- **Change:** `rtl/swiglu_mem.vhd` LANES generic (banks, per-lane pipeline,
  per-lane running max + one S_MAX state above LANES = 1). MEASURED
  24,588 / 12,301 / 6,157 at N = 12288 for LANES 1/2/4. Identity re-run with
  the CURRENT bench in all six arms (the first pass's dumps predated the
  lane-stress trials): HEAD-unit vs LANES 1/2/4 at N = 128 AND N = 12288,
  **6 of 6 `cmp` IDENTICAL** (3,741 and 233,491 lines). DERIVED step
  61,473 -> 49,186 (-20%) / 43,042 (-30%). Mutation table 19 rows x 3 LANES
  (`bankswap`, the swapped bank/offset split, added), 0 unexpected. Gate
  re-run after the last edit: tb_swiglu_mem(+_9b) PASS 2,
  tb_rmsnorm_bf_mem PASS 1, tb_llama_top_swg PASS 1, seamgate_swg PASS 1.
- **What it is actually worth, and this is the number to quote:** VEC_SWG is
  **3.18%** of a flat token (1,967,136 of 61,907,125 cycles; A_JOB is 68.95%,
  B_JOB 25.61%). LANES = 2 removes 0.64% of a token, LANES = 4 removes
  **0.95%**. The unit gets 4x faster and the token gets about one percent
  faster; only the second is a result. 3N of the 5N is the adapter and no
  generic on this unit can reach it.
- **NEVER SYNTHESISED, at any LANES.** No Vivado ran for this change. The
  area figures in hw/fk33/results/swgmem_2026-09-19/ are the PRE-change unit,
  so LANES 2/4 area is ESTIMATE and even LANES = 1 has not been re-drawn.
  Weigh an UNMEASURED DSP/LUT cost against under one percent of a token
  before building anything.
- **Two planted trials** (`one_big0..3`, `one_big_last`) were added because
  `lanemax` survived at LANES = 4 and `nodrain` had never bitten. A second
  attribution control (mutants against HEAD's trial set) says the new trials
  earned exactly **4 kills of 24 rows**: `nodrain` at all three LANES and
  `lanemax` at LANES = 4. An older random trial already caught every other
  lane mutant.
- **Trap recorded:** this track's earlier WORKLOG entry was committed by
  TRACK ACLK's `11a4d6a` (pathspec commit on a shared file captures the
  working tree). Recorded, not amended.
- **`rmsnorm_bf_mem` unchanged:** its unit share is 27.6% of VEC_NORM.
- **NEXT (not this track's files):** `rtl/llama_top.vhd` generic
  `SWG_LANES : positive := 1` beside NORM_LANES and
  `generic map(N => NN, Q => 12, LANES => SWG_LANES)` in `gsr`;
  `hw/fk33/gen_fk33_card.py` `--generic SWG_LANES=2` (conservative) or 4.
  Area above LANES = 1 is ESTIMATE (+16 DSP, +2.3 k LUT per lane); the
  OOC draw on the BC-250 is `sim/ooc_swgmem_run.sh`'s `draw` with
  `"N=12288 Q=12 LANES=4"`. The other 3N per step is the adapter's serial
  region-file traffic (one word per cycle each way) and is a llama_top /
  sequencer lever, listed in the write-up.

### 2026-09-20 TRACK ACLK: the A clock-domain split is in the tree behind `FK33_ENG_SPLIT_CLK=1` (default OFF, byte-identical when off). Bench + 15 mutants green. DERIVED: 1.15x per striped token, 1.0x on the flat image. NOT YET BUILT.

Oren's question: "can we not clock the blocks that have more cycles faster?"
Answer for A, and the contract, in `docs/2026-09-20_a-clock-domain-split.md`.

**What landed** (`99e5d99`, `886ebc0`):
- `rtl/fk33_eng_cdc.vhd`: the seam cell between `card` (75 MHz clk_out3) and
  `eng` (new clk_out4 at `FK33_ENG_FAST_MHZ`, default 200). Every
  `CARD_SEAM_TO_ENG`/`FROM_ENG` net and the card's AXI-Lite write master
  cross through it. x and y are `rtl/async_fifo.vhd` (y sized to a whole job,
  256 beats = 44 RAMB36); the AXI-Lite write is a toggle handshake carrying
  `a_x_exp`/`a_job_index` with it; **done crosses as a rising-edge EVENT
  cleared by the next accepted write, not as a level**, because
  `a_desc_adapter`'s S_WAIT argument is "the GO that put us here cleared
  done_l" and a level synchroniser would hand it the previous job's done.
  Three orderings the single-clock card relied on are enforced by handshake
  on both sides (x before the first write; done never stale; every y beat
  before done).
- `hw/fk33/gen_pcieep.py`: the switch, `fast_reset` (ext_reset_in =
  xdma/axi_aresetn, so `check_reset_topology`'s descendancy rule still holds
  and its nine teeth rows pass retargeted), `axil2eng`/`engctl` at NUM_CLKS 3,
  the `eng_cdc` cell and its wiring, the two-hop address map, one
  `set_clock_groups -asynchronous` line with a sentinel, `check_cdc_pins`
  (48 pins, teeth on each face), live-cell `FK33_ENGCDC`, implemented-design
  `FK33_ENGSPLIT` (distinct clocks, >= 10 ASYNC_REG cells under
  `bd_i/eng_cdc`, `report_cdc` both ways), `split_gate_teeth`.
- **The 28 HBM masters are not touched.** They already run on `hbm_aclk` =
  xdma/axi_aclk at 250 MHz with the crossing inside `axi_rd_port`, exactly as
  the engine-only 200 MHz build; the split moves ONE engine clock pin.

**MEASURED:**
- `sim:tb_eng_cdc` OVERALL PASS 1 (11,678 checks; 13.333/5 ns, swapped
  5/13.333 ns with a 12-element tail burst, both overflow faults, sticky err).
- `sim/mutate_eng_cdc.sh`: 15 of 15 as expected. Killed: both-halves x wait
  (W12), both-halves y wait (W34), done not cleared by a write (W5), done as a
  LEVEL (W6), gray encoder only (G2), late full flag (F1, ABORT). Survivors,
  stated as the floor: each single half of a redundant wait (W1-W4), one-flop
  sync (W7), same-edge toggle (W8), binary pointers (G1), early full (F2).
  W12 SURVIVED the first bench: the request path's own latency exceeds the x
  FIFO's at either ratio; the tail burst made the ordering reachable.
- Switch off: regenerate with `FK33_CARD=1 FK33_CB_STYLE=distributed
  FK33_ENG_CORE_MHZ=75`, `git diff` on the tcl and xdc EMPTY. `--selftest`
  PASS in all four configurations. `sim:runguard` PASS 1 / PASS 1,
  `sim:cardtop` PASS 3 / PASS 3, `sim:fk33card` PASS 1 / PASS 1 (off / on).
- On the way: `async_fifo`'s read side pops 2 beats per 3 rclk cycles with
  `q_ready` high (`do_rd` gated on `ocnt + inflight < 2`).

**DERIVED, from the token-0 profiles and the manifest shapes:** an `A_JOB`
step is 27.2% card-side (x push `K+2` and drain `M` at the card clock,
2,963,566 cycles) and 72.8% engine-side (7,931,072 cycles over ~5.18 M beats
= **1.53 cycles/beat, the datapath floor: at 75 MHz the striped A is
compute-bound**). The 200 MHz engine-only build measured 2.03 cycles/beat on
the same striping = 10.15 ns/beat, against the busiest-PC (2 lanes) supply
bound of 8.0 ns/beat = 1.6 cycles at 200 MHz: within 21% of the memory bound.
Token: striped **0.4015 s -> 0.3484 s (1.15x)**, A 0.1453 -> 0.0921 s; flat
0.8254 -> ~0.83 s (the single-PC bound is clock-independent). By cycles B is
the bigger block (52.6%) but its fmax is unmeasured; A's 200 MHz is.

**NOT done:** any Vivado run. The BC-250 lane had one Vivado present
(3.75 GB RSS) when checked, so `--bd-only` with the switch on is the next
step (3 min, 3.4 GB): it answers whether the packager infers `sa`/`ma` as
write-only AXI4-Lite compatible with `card/a` and `engctl/S01`, and whether
`eng_cdc/sa/reg0` exists. Then a routed card build with
`FK33_ENG_SPLIT_CLK=1` (start at `FK33_ENG_FAST_MHZ=175` if 200 fails) reads
`FK33_ENGSPLIT`, the two `report_cdc` files and `fk33_pcieep_engcdc_util.rpt`.

**Files owned:** rtl/fk33_eng_cdc.vhd, sim/tb_eng_cdc.vhd,
sim/mutate_eng_cdc.sh, hw/fk33/gen_pcieep.py (split parts),
docs/2026-09-20_a-clock-domain-split.md.

### 2026-09-20 TRACK KVREG: subsystem C's KV base is a SEAM REGISTER, not a generic. C_MAXPOS halved to 65536 so the striped image fits. Host refuses an unfit manifest. NOT YET BUILT.

- **Defect** (docs/debugging/2026-09-20_the-kv-cache-base-is-compiled-into-
  the-bitstream.md): `C_K_BASE_CH`/`C_V_BASE_CH` were compiled from the
  FLAT manifest; the striped image's kv_base is elsewhere and C wrote 40
  weight objects. **Fix, landed in this track:** `rtl/llama_top.vhd` gains
  input ports `kv_k_base`/`kv_v_base` (byte addresses, defaulting to the
  compiled pair, so every bench is unchanged) handed straight to
  `attn_kv_axi`; `rtl/fk33_seam.vhd` gains **A_KVK_LO/HI 0x90/0x94,
  A_KVV_LO/HI 0x98/0x9C (RW, reset 0, in the GO-time zero refusal with
  ARENA/BST) and A_KV_MAXPOS 0xA0 (RO, the seam's MAXPOS generic, which
  gen_pcieep.py sets from gen_fk33_card.py's C_MAXPOS)**; CAPS bit 5
  (`FK33_CAP_ENG_KV_BASE`, 0x1D -> 0x3D). gen_pcieep SEAM_TO_CARD wires
  both; gen_fk33_card sets **C_MAXPOS=C_CTXLEN=65536, C_V_BASE_CH=318324224**
  (2*65536*8704 = 1.14 GB fits the striped image's 1.378 GB free; 131072
  needs 2.28 GB and does not). All four generated files regenerated.
- **Host:** `pl_backend.c` reads KV_MAXPOS, programs K = hbm.kv_base and
  V = K + MAXPOS*8704, reads all four back, and REFUSES an image whose free
  KV space (below gdn_const/the arena) cannot hold the pair. MEASURED on the
  simulated card with the real striped manifest: `--sim-kv-maxpos 131072`
  refused ("903618560 bytes short"), 65536 programmed K 0x1AD71C000 /
  V 0x1CF71C000. Without the caps bit it prints that the base is compiled
  in and continues. `fk33ctl.py seam` prints the pair or UNREADABLE.
- **Gates:** `sim:kvmap` now checks BOTH manifests' KV extent at the card's
  C_MAXPOS against every weight piece and the gdn_state/gdn_const/arena
  regions; the teeth row "striped image with the compiled flat pair at
  131072" REFUSES naming `output.weight.mv4i lane 15 seg 17`, and its
  attribution control (extent rows off) is ACCEPTED, i.e. the old rows were
  blind. New bench row `sim:tb_llama_top_kvport` (decoy generics, real
  bases on the ports; landmarks identical to tb_llama_top_seq); tb_fk33_seam
  P6g (17 checks). Mutants: A (seam never latches) fails P6g 8-13, 17 by
  name; B (engine port map back to the constants) see the report.
- **NEXT: a card build** (`FK33_CARD=1`, ~47 GB with swap, alone on the
  box) and, on silicon, `fk33ctl.py seam` must show caps 0x3D and the pair
  after `run_prompt --open-only`; then the striped image's token 0 argmax
  must be 846 and `fk33_load_weights.py verify` clean AFTER the token.
  Until that bitstream exists the shipped `.bit` still has the base
  compiled in and must only be run with the flat image.

### 2026-09-20 03:05: THE CARD ANSWERS THE PROMPT. Qwen3.5-9B on the FK33, 23-token prefill + 160 generated tokens, no faults, first token = reference.

- Bitstream `hw/fk33/bit/fk33_card_swg_75mhz_2026-09-20.bit` (sha256
  8257e25c..., from `8dbe160`/`e40067f`: seq_rst + `rmsnorm_bf_mem` +
  `swiglu_mem`, every stand-in gone). The synthesised netlist (362,195 LUT,
  82.4%, SMALLER than the previous card: the stub's 1,152 LUTRAM blocks
  left with the real SwiGLU) failed to route TWICE from the same
  placement: `Congestion_SpreadLogic_high` 209 unrouted / 121 overlaps,
  then `route_design -directive AlternateCLBRouting` on the same
  placement gave the SAME 209 / 121 to the digit (MEASURED: a route
  directive cannot fix a placement-bound overlap). Re-implemented from
  the synth checkpoint with `place_design -directive ExtraNetDelay_high`:
  routed, WNS +0.050, no congestion report. Evidence and the Tcl in
  `hw/fk33/results/card_swg_2026-09-20/`. **A card build's placement is a
  draw: two of five draws failed today; re-implement from the DCP with a
  different placer directive rather than resynthesising (47 GB, 1 h).**
- MEASURED on silicon (`dcdc_prompt_160.txt` in that directory):
  `prefill 23 ids, first argmax 1206` = the reference's first token;
  divergence at token 1 (4087 "To answer" vs 3418 "To understand"),
  thereafter a coherent, correct answer: "DC-DC converters and
  transformers operate on different principles ... Transformers work by
  electromagnetic induction and only work with AC ... DC-DC converters
  take DC as input ... a DC-DC converter typically uses a transformer
  internally (via a switching mechanism like PWM)". 182 positions, KV
  cache and GDN state across tokens, faults 0, ~0.8 s/token at 75 MHz.
- Token-level agreement with the BF16 reference beyond token 0 is NOT
  expected and was not the goal: INT4 weights + Q12 fixed point on the
  card against BF16/double, and greedy decoding amplifies any early
  difference. The next measurement is a logit-level comparison at token 0
  (the card's full logits row vs the reference's) to quantify the
  arithmetic gap, then speed.

### 2026-09-19 08:10: TWO ROOT CAUSES ON SILICON IN ONE MORNING. B WAS NEVER RUNNING TOKEN 0, AND THE NORM CLAMPS ON THE EMBEDDING. seq_rst LANDED (`1b8d28f`) AND IS BUILDING; THE NORM PORT IS IN FLIGHT.

- **ROOT CAUSE 1 (`1b8d28f`, docs/debugging/2026-09-19_b-ran-every-probe-token-as-not-the-first.md)**:
  the card's `tok_pos` advances on every closed token and was cleared ONLY
  by the PCIe link reset; the seam's SEQ_RESET cleared its own `cur_pos`
  and nothing in the engine (`run_prompt.c:343` said so in a comment).
  Every B-reaching probe after the first token ran at `tk0 = 0` against a
  zero loaded state, the update quantiser chose `e_u = se_j + 2 = 2`, and
  Y came out at exponent 10 / attn_gate argmax 2591. MEASURED by reading
  layer-0 S back from HBM (`fk33ctl.dma_read` at `gdn_state_base`):
  mantissas 0/-1 at a uniform exponent 2, and the model with tk0 forced
  to 0 reproduces 507,460 of 524,288 mantissas, the exponent and the
  argmax. After one reconfiguration, the first token gives **2131, the
  reference**. Fix: `llama_top.seq_rst` (clears tok_pos, re-arms KV seq
  reset), seam SEQ_RESET idle-only and pulsing `d_seq_rst`, `A_TOK_POS`
  0x8C, CAPS bit 4, host readback in `pl_seq_reset`, `tb_fk33_seam` P6f
  (9 checks; two mutants killed by name). `--bd-only` validates,
  FK33_UNCONNECTED count=0. **Building as `seqrst-build.service`
  (launched 07:39, MemoryHigh 24G / Max 26G, `$SD/build6/`), swap guard
  kills it at 30 GB.** MEASURED: its cgroup is 23.5 GB resident + 23.9 GB
  SWAPPED in synthesis = a 47 GB footprint; "at least 21.5 GB" in CLAUDE.md
  under-states it by half because swap was never counted.
- **HBM does NOT survive a reconfiguration** (MEASURED: gdn_const verify
  fails 0x751 bytes in). A reload costs the weight load (~4.5 GB, 251/251
  in a few minutes), not just 2 minutes.
- **ROOT CAUSE 2 (`573b677`, docs/debugging/2026-09-19_the-embedding-sits-below-the-norms-window.md)**:
  with a true first token, B's input (the tap column) is 0.7727x the
  reference for q, k AND v at corr 0.999. X scaled by 4: unchanged; by
  1/4: 0.9774x. `rmsnorm_rs_mem` (still the norm in `llama_top:2571`)
  floors the mean square at 2^-12, rms 2^-6; the embedding row's rms is
  2^-6.35. The 08-26 fix `rmsnorm_bf` has no `_mem` variant and was never
  composed in. **A subagent (worktree) is porting it: `rmsnorm_bf_mem`,
  identity bench, top swap, `vec_oracle.norm_bf`, gate rows after the
  build ends, OOC on the BC-250.** This needs a THIRD build after the
  seqrst one.
- **10:45 UPDATE: the norm port LANDED (`3527c44` `feb84b1` `b601ca8`,
  merged fast-forward).** `rtl/rmsnorm_bf_mem.vhd` behind rs_mem's ports;
  identity bench 1,822 checks bit-exact incl. the x_exp 19 embedding case;
  10 mutants bite, 4 survive by name (`owe_norst`, `xwswap`,
  `transpose_all`, `align_rnd`); `vec_oracle.norm_bf` 220/220 bit-exact
  against the C oracle, and `--norm real` now means bf; `llama_top` binds
  it (`done` +1 cycle, 149 vs 148). OOC on the BC-250 at N=4096: 4,995 LUT
  / 2,411 FF / 6 BRAM / 40 DSP / WNS +0.971 against rs_mem 4,825 / 1,629 /
  6 / 40 / +0.971 (control reproduced the 08-30 draw to the digit). Gate on
  the BC-250: seamgate 5/5, tb_llama_top 10/10 (one row needs
  `--timeout 2400` there), cardtop 3/3, tb_fk33_seam 2/2, no golden moved
  (DERIVED: no bench-shape vector reaches the clamp region; open item).
  **The BC-250 runs llama_top-level rows now**: GHDL 6.0.0 refused
  `axi_rd_port.vhd:260`, fixed in `0f6b82c` on both GHDL versions.
  **The norm build is ARMED behind the seqrst build** (`$SD/build7/arm.sh`,
  unit `norm-build`, same caps, own swap guard) at HEAD `b601ca8`.
- **11:46: THE SEQRST BUILD DID NOT ROUTE.** `Route 35-162`: 9,293 signals
  unrouted, 7,871 node overlaps, congestion 85-88% in all four directions,
  bitgen not run. Same strategy (`Congestion_SpreadLogic_high`) as the four
  card builds that routed with no congestion report at all; LUT 83.74%
  against 83.47%. A placement draw, not a size change (the 08-30
  scatter-per-draw doc). Log and placed utilization kept in
  `hw/fk33/results/card_seqrst_2026-09-19_ROUTEFAIL/`; the synth DCP is in
  `$SD/build6/root` for a re-implementation if the norm draw also fails.
  **The norm build (unit `norm-build`, launched 11:47 by the arm script on
  the unit ending) carries seq_rst too and supersedes it; running.**
  Oren has authorised the main session to reload bitstreams itself
  (sudoless `fk33_reload.sh` via `/usr/local/sbin/fk33-pci`, `f5ec164`).
- **16:02: THE NORM BUILD ROUTED (WNS +0.054, no congestion report) and is
  ON THE CARD**: `hw/fk33/bit/fk33_card_seqrst_bfnorm_75mhz_2026-09-19.bit`
  (sha256 f6c89e4f..., from `b601ca8`), results in
  `hw/fk33/results/card_seqrst_bfnorm_2026-09-19/`. Reloaded sudoless
  (first use of `fk33-pci`; its `lsmod | grep -q` misread under pipefail,
  fixed to capture-then-test). MEASURED on silicon: `attn_gate(Y)` = 2131
  on TWO consecutive runs with `--seq-reset` between (was 2591 on the
  second before), `engine tok_pos` reads back 0 after the reset, and
  `logit_exp` moved 19 -> 18 (Y grew, the norm fix). Token 0 end to end:
  no faults, 504 steps, **argmax 247749 against the reference 846**.
- **ROOT CAUSE 3 (docs/debugging/2026-09-19_the-swiglu-on-the-card-is-a-product-with-no-gate.md)**:
  bisecting XN entering each block with `hw/fk33/host/fk33_bisect_layers.sh`
  (probes are free now): blocks 0-2 right, first DIFF entering block 4;
  inside block 3 C's Y is RIGHT (attn_output 3456 = ref), G and U are
  right, `ffn_down(H)` is wrong with H at exponent 9 vs 13 (block 0: 10 vs
  14, argmax survived by luck). **`rtl/llama_top.vhd:1832`: the D-vec
  SwiGLU is the behavioural `g*u/2^16` with no silu, in every
  configuration; `rtl/swiglu.vhd` has no D-vec adapter.** The last
  stand-in in the composed top (the banner's "ATTENTION IS A STUB" line is
  stale: C is real and measured right). **Adapter track dispatched 16:40
  (worktree): `swiglu_mem` + `gsr`/`SWG_REAL` + `vec_oracle.swg_real` +
  `seamgate_swg` + OOC on the BC-250.** Fourth build after it lands.
- **18:00: THE SWIGLU ADAPTER LANDED (`6ebc2d5`, merged `8dbe160`) AND
  THE FOURTH BUILD IS RUNNING** (unit `swg-build`, `$SD/build8/`, same
  caps and guards, HEAD `8dbe160`, `SWG_REAL=true` in the card generics,
  51 card sources). MEASURED by the track: `swiglu_mem` bit-identical to
  the shipping `swiglu -> vec_mem -> bfp_pack` chain at N=12288 (184,336
  checks), 9 of 12 mutants bite (non-biting by name: `nodrain`, `nosat`,
  `doneearly`), `vec_oracle.swg_real` vs the double-precision R_H-3 corr
  0.999996 (Q12 grid is the limiting term), `seamgate_swg` 64 seams x 3
  tokens bit-exact with both controls failing at R_H-0; gate groups all
  green on both boxes; OOC at N=12288 +2,493 LUT / 19.5 BRAM / 16 DSP,
  +4.664 ns at 13.333 ns. The banner's "ATTENTION IS A STUB" line was
  stale and is fixed. `regress.sh`'s rc grep gained `-a` (a NUL-holed log
  had hidden an rc line).
- **The DC-DC prompt ran end to end on the seqrst+bfnorm card** (23-token
  prefill + 16 generated, 39 positions through 32 blocks, no faults,
  ~0.8 s/token): text is nonsense, first divergence at token 0, as
  expected with every FFN at `g*u`. Same command is the test after the
  swg build.
- **Still open**: the first-token whole-token argmax 0 / logit exp -25.
  The seqrst bitstream makes B-reaching probes free again (no reload per
  probe), which is what the bisection needs.
- **BC-250**: up, synced, Vivado present, **no GHDL**; it can take OOC
  synthesis, not gate rows.

### 2026-09-19 00:20: THE LAST STAND-IN IS GONE AT THE SIM SHAPE. FULL GATE 145 PASS. THE CONSTANTS BUILD IS ARMED BEHIND THE ROUTER.

- **Track F (`3fdfe8f`, `d93a745`, merged)**: `C_QKN_IMAGE` on `llama_top`,
  the model's PER-LAYER `attn_q_norm`/`attn_k_norm` gains (8 layers x 2 x
  256 at 9B, `hw/fk33/gen/qkn_9b.hex`; `C_QKN_EXP` stays 12, largest
  mantissa 11,968 MEASURED) selected by the C job's layer, pinned two-sided
  to `2 * n_attn_blocks` at elaboration. MEASURED at the sim shape:
  `R_Y-3` bit for bit at tokens 0/1/2 with the image model, and the ramp
  model FAILS the same capture at 8/63/64 of 64 mantissas; at 2 attention
  layers, 6 of 6 with the image and 0 of 6 for each of ramp / layers
  swapped / q-k swapped. Rows `sim:qknimage`, `sim:tb_llama_top_qkn`,
  `sim:seamgate_qkn`. Empty default leaves `tb_llama_top_real`'s four
  landmarks unmoved. Card generics now carry `C_QKN_IMAGE`.
  **So every learned constant the design consumes is now the model's**, at
  least where a bench can see it: A's weights (descriptors), the D-vec norm
  gains (image), B's taps/alpha/beta (regions), B's conv weights/dt/a/ssm
  norm (HBM `gdn_const`), C's QK-norm gains (image).
- **Gate rows for B** (`252b4f6` `220d3b7` `4e14b4c`): `sim:gdnconst`,
  `sim:constimage`, `sim:tb_llama_top_bconst`, `sim:seamgate_bconst` (9 of
  9 R_Y, floor 61 + RY_FLOOR 9; control 0 of 9). The capture file list had
  been missing `gdn_conv_w_mem.vhd` since `e212f04`, which had turned
  `seamgate_{real,stub,seq}` red unheard; fixed there.
- **Full gate at `1abb514`, `--jobs 1`, MEASURED: 145 PASS, 2 FAIL**, both
  `--check` rows stale from track D's own edits (`sim:gdnstale`:
  `rtl/ooc_gdnadapt_top.vhd` is extracted from `gb_real`; `sim:cardtop`:
  `tb_fk33_cardtop_ident.vhd` is derived from `tb_llama_top.vhd` by
  `gen_cardtop.py --bench`). Regenerated in `3b61938`/`907918a`; both read
  OK. The generator-input trap in CLAUDE.md, again, and again caught only
  by the `--check` rows. `BASELINE_PASS` stays 130 (this tree carries 22
  rows a clean checkout does not get).
- **Memory incident avoided**: the 9B-geometry store bench sat at its 8 GB
  cap beside the 15 GB router and swap went 7 -> 15 GB in an hour; stopped
  by PID (`/proc/PID/exe`), swap back to 7 GB at once. Its appetite is
  > 8 GB and UNKNOWN (a capped `memory.peak` is the cap); rerun when the
  box is quiet. The reference `llama-server` on 8140 is stopped.
- **The constants build is armed** (`$SD/build5/arm.sh`): chained on the
  maxpos build's own `FK33_BUILD_DONE`, then a `/proc/PID/exe` presence
  check, then `const-build.service` at `MemoryHigh=20G`, same recipe. It
  takes the tree at launch, i.e. HEAD `907918a` with all of the above.
  BD validated on the BC-250 with the new seam wire.

### 2026-09-18 23:00: THE B CONSTANTS PATH IS IN THE TREE. AT THE SIM SHAPE, B NOW COMPUTES THE MODEL'S ARITHMETIC: 9 OF 9 R_Y SEAMS OVER 3 TOKENS, BIT FOR BIT, WITH BOTH CONTROLS AT 0 OF 9

Four tracks plus the dispatcher's, all landed between 22:00 and 23:00
(`18d5864` contract; A `e212f04`; B `2177bee` `0126c24` `4c1c4cd`; C
`7430bae` `f212358` `d3c043b` `ff8ff6b`; E `39b1992` `ee42054`; D
`f425d82`; card regen `14289cf`). `docs/2026-09-18_b-constants-path.md` is
the contract and was corrected in place by the tracks where the build
differed.

What exists now:

- **HBM region `gdn_const`**, 66,048 B per GDN layer x 24 = 1,585,152 B at
  `hbm.gdn_const_base = 0x1FF95A000` (ends at the descriptor arena; nothing
  placed moved; `max_context_tokens` 233,638 -> 233,237). Image
  `/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/gdn_const.bin`, blake2b
  `ec3eda1a…`, `--check` PASS; the packer's selftest catches 7 of 8 mutant
  packers (`round_half_up` is the named non-biter). Per-layer exponents:
  conv 14..17, dt 10..12, a 8..17, norm 14..15; the units accept those
  ranges (checked: `to_q_wide`, `rsh_r`, `gdn_conv`'s `e_acc`, `rmsnorm_rs`).
- **`gdn_state_store`'s fourth, load-only phase** into the new
  `gdn_conv_w_mem` (KCONV slots, no rotation) plus a scalar register file;
  9,475 checks at the sim shape, 7 mutants of which 6 bite (M7, a dead
  clamp, is unobservable by design; M6 bites by ONE check, attribution
  control run). `CONST_EN = false` is bit-identical to before.
- **Seam registers 0x84/0x88** (`bst_const_base`), host define, sim model,
  `fk33ctl seam`, drift check 55 rows; `pl_backend` writes it from the
  manifest; the host loader loads and verifies the image.
- **`llama_top` `B_CONST_HBM`**: conv weights, dt, a, ssm_norm and their
  exponents from the store. `NORM_W_IMAGE` now pinned two-sided to
  `2*blocks+1` ops at elaboration (a LONG image was never refused; found
  by track E).
- **`gen_pcieep.py` refuses a missing seam/card pin at Python time** and
  the Tcl carries an `FK33_SEAMWIRE` existence guard; the old generator
  silently emitted a connect to a pin the wrapper did not have (MEASURED).
- **The card generics** now carry `B_SRC_REAL=true`, `B_CONST_HBM=true`
  and `NORM_W_IMAGE=hw/fk33/gen/norm_w_9b.hex` (99 BRAM tiles MEASURED by
  GAIN16's `cbland` on this exact image, not NWROM's 114). BD validated on
  the BC-250: `FK33_SEAMWIRE 37`, `FK33_UNCONNECTED count=0`,
  `FK33_BD_VALIDATE OK`.

**The verification (MEASURED, `tools/ref9b/gdn_oracle.py --b-const`, which
reads the packed image and runs the C model per layer; byte-identical to
the old oracle with the option off):**

| run (sim shape, real pooled weights) | R_Y match |
|---|---|
| 1 token, B_CONST_HBM | 3 of 3 |
| same capture, stand-in model | 0 of 3 (127-128 of 128 differ) |
| 3 tokens, B_SRC_REAL + B_STATE_AXI + B_CONST_HBM | **9 of 9** |
| control A: stand-in constants, real inputs | 0 of 9 |
| control B: image constants, stand-in inputs | 0 of 9 |

A gate-row track is turning this into `sim:gdnconst`, `sim:constimage`,
`sim:tb_llama_top_bconst` and `sim:seamgate_bconst`. The 9B-geometry store
bench with the fourth phase is running (`$SD/st9b`).

**Still stand-ins after this lands:** C's QK-norm gains (8 layers x 2 x
256, an image; not started). Nothing else in B or D.

**Next:** the constants build queues behind the maxpos build (one Vivado
here; maxpos is in routing). Recipe unchanged except the tree; budget
`MemoryHigh=20G`. Then: reload, load weights + `gdn_const.bin` + arena,
verify, `run_prompt` at token 0 against `reference_tokens.txt`, and the
step-8 probe (expect 3994).

### 2026-09-18 22:20: THE WRONG ARGMAX IS ROOT-CAUSED. THE CARD RUNS B ON STAND-IN INPUTS AND STAND-IN WEIGHTS, AND NO CARD BUILD HAS EVER ASKED FOR THE MODEL'S LEARNED CONSTANTS

`docs/debugging/2026-09-18_the-card-runs-subsystem-b-on-stand-in-inputs-and-weights.md`.

The step-8 mismatch (ssm_out on B's Y: card 2768, reference 3994) is not a
drain defect and not a B defect. **`hw/fk33/gen_fk33_card.py` does not pass
`B_SRC_REAL`**, so on the card B's conv taps, alpha and beta are `m12`
stand-ins and B reads exactly one per-token input, z. Independently, the
conv WEIGHTS, `ssm_dt_bias`, `ssm_a` and the `ssm_norm` weight are stand-ins
in EVERY configuration (no path exists, `rtl/llama_top.vhd:4068`), the D-vec
norm gain is the synthetic ramp because `NORM_W_IMAGE` is not passed either,
and C's QK-norm gains are stand-ins. Same class as the 2026-09-11 "C is a
stub" finding, same file, found seven days later by the same grep. **And it was
already on this board**: the 2026-09-11 entry below names `NORM_W_IMAGE` a
correctness blocker and `B_SRC_REAL = false` a tracked gap; the bring-up
plan never carried it, so the first whole token was judged against the
reference with an outcome that was known in advance.

MEASURED, the drain is CLEARED: a new `--probe-dup-src REGION` in
`tools/gen_layer_program.py` appends a copy of the last A job reading REGION
and probes it, turning the sampler into a read port on any A-drained region.
`ssm_beta`/`ssm_alpha` reading Z: 5/25 = reference 5/25 (14%/28% margins);
reading QKV[0:4096] (q,k): 31/26 = reference 31/26 (34%/35%). B was not in
those programs. `attn_gate(Z)` is a 0.5% tie and is not a discriminator.

**What a correct token needs, and none of it is a bug fix:**

1. `B_SRC_REAL=true` in the card generics. Zero structural cost, verified in
   sim with the tier on 2026-09-05.
2. `NORM_W_IMAGE` at 9B (65 x 4096 gains, ~114 BRAM; 222 of 672 free on the
   running bitstream).
3. A path for B's conv weights (64 KiB per layer): through HBM as a fourth
   phase of `gdn_state_store`'s mover into a 16-tile BRAM, load-only. A
   1.5 MiB ROM (~341 tiles) does not fit. Plus `ssm_dt_bias`/`ssm_a`/
   `ssm_norm` (24 x 192 int16, an image). The oracle models `m12` weights and
   changes with it. THIS IS THE TRACK.
4. C's QK-norm gains, an image.

The maxpos build (`$SD/build4`, MAXPOS 131072 + grant address map, lands
~23:40) carries none of this; it is still worth loading for multi-token runs
past position 4, and its Y will still be wrong.

Uncommitted at this entry: `server/tests/run_prompt.c` (`--resume`,
`--seq-reset`), `server/pl_backend.c/.h` (`pl_resume_pos`),
`tools/gen_layer_program.py` (`--upto`, `--probe-smp`, `--probe-dup-src`,
partial arena image). Reference harnesses live in the session scratch
(`$SD/probe_ref.c`, `probe_ref2.c`, `probe_hyp.c`) and are described in the
debugging doc.

### 2026-09-18 21:10: FOUR WHOLE TOKENS RAN ON THE CARD. B COMPLETES. THE SEAM'S MAXPOS DEFAULTED TO 4. THE ARGMAX IS WRONG.

Bitstream `hw/fk33/bit/fk33_card_xexp_wdog_seam_75mhz_2026-09-18.bit`
(25,017,338 B, WNS +0.143, routed legally, built 21:03: x_exp port +
WDOG 4,000,000 + seam ack fix + progress registers). Oren reloaded it;
the weight image did NOT survive the reconfiguration (verify: 245 FAIL) and
was reloaded and re-verified (250/250), arena verified, layer 0's state
slot zeroed.

**`run_prompt --max-new 1`: positions 0, 1, 2, 3 each ran to `done=1`** --
504 issues (TBL_LEN - 1, the clean count), ~60.0M cycles = 0.80 s per token
at 75 MHz, `FAULTS = 0`, trips 0. MEASURED from the progress registers
polled every 2 ms:

| step | what | issued at cycle | took |
|---|---|---|---|
| 7 | first B_JOB (`blk.0`, GDN) | 320,642 | **617,226** (3x the old watchdog) |
| 12 | A_JOB `ffn_gate` 12,288 x 4,096 | 1,048,088 | 282,670 (89 B/cycle) |
| 503 -> 504 | last lm_head window -> END | 59,995,673 | done at 60,079,143 |

So subsystem B runs to completion on silicon with the tiered store, C's
attention layers ran (steps in between), the sampler saw all 248,320 logits
(`smp_n 248320`) and published an argmax.

**Then position 4 was refused EC_POS.** `rtl/fk33_seam.vhd:215 MAXPOS :
positive := 4` -- the simulation default -- and no build had ever set it.
`gen_pcieep.py` now sets `CONFIG.MAXPOS` from `gen_fk33_card.py`'s
`C_MAXPOS` (read from the file, not restated) with read-back. Build
`maxpos-build` launched 21:12 with that and the grant address map.

**The argmax is WRONG.** After the 4-token prefix `248045,846,198,623`
(`<|im_start|>user\nIn`) the card's argmax is **151353** (detokenises to an
invalid byte sequence). llama.cpp on the BF16 GGUF, `/completion` with the
same ids, greedy: **279** (" the"). `ref/run9b --acts bfp` (rung 3, the
hardware model) on the same ids is running for the third opinion. Every
structural check passed; the value is off. Exactly the case the README of
`goal_dcdc` warns about: a plausible-looking, silently wrong token.

Two candidate causes already on the table, neither measured: the x_exp
path was changed today and has no bench at `A_DESC = true`; and the card's
embedding is the packed INT4 row (`--mv4i`, recipe wide) where the
reference's headline runs use the BF16 row. The tool that settles it is
element-wise: `run9b --out F.r9bs` writes every region per step, and the
card exposes R_X through the XOUT window after a token.

### 2026-09-18 19:50: FULL GATE GREEN AT 141 (WAS 139 + 2 NEW ROWS); THE STATE STORE PASSES AT THE 9B GEOMETRY

`OVERALL PASS 141 FAIL 0 NOVERDICT 0 NOCHECK 5 SKIPPED 19`, `--jobs 2`,
beside the running Vivado. Includes `sim:tb_fk33_seam_wdog` and the
regress.sh judge fix (no row changed verdict under it).

`sim/tb_gdn_state_store` run by hand at the card's shape (VAL_HEADS 32,
DIM 128, AXI_DW 256, MAXB 16, MAXOUT 4, LAYER_STRIDE 1,101,824, 4 tokens x 2
layers): **827,408 checks, bad=0**. First time the store has been simulated
at 9B; needs `ulimit -s unlimited`. So if B hangs on the card it is not the
store's arithmetic; look at the grant/port path.

### 2026-09-18 18:40: A SECOND GO SHOWED THE SEAM MAKES ANY D ERROR PERMANENT; FIXED, REPRODUCED IN SIM, BUILD RESTARTED WITH EVERYTHING

Repeating the GO on a zeroed state slot gave the same error with **CYCLES =
1**: D never ran it. Cause in the RTL: the seam acked at the `err` instant,
a WDOG error raises `err` up to 200,000 cycles BEFORE `tok_done` (the
S_ABORT drain), D parked with `tok_done` high and ignored every later GO,
and the seam re-reported D's sticky error one cycle after each. Fixed:
ack follows `d_tok_done` as a level, the error latch waits for `d_busy`,
GO refused while `tok_done` is high; `pl_backend` waits for busy to drop
after an error. New row `sim:tb_fk33_seam_wdog` (WDOG_LIMIT 64, every
token a watchdog) with P7: FAILS on the old seam with the exact silicon
signature (`token 1 CYCLES = 1`), PASSES on the fix; `tb_fk33_seam`
landmark unchanged. Two read-only progress registers added (`STEPS_ISS`
0x7C, `ISSUE_CYC` 0x80) so a stuck token can be localised by polling.

Also found: `sim/regress.sh` judged the failing row NOVERDICT three times
(`printf | grep -q` under pipefail: SIGPIPE on a 13 MB log). Fixed with
`grep -c` in all three judge sites.

Build restarted 18:38 (`xexp-seam-build`): x_exp port + WDOG 4,000,000 +
seam ack fix + progress registers. ~21:40. The 11:28 bitstream on the card
cannot recover from any D error without a reload; B is not to be debugged
on it. Doc: addendum in
`docs/debugging/2026-09-18_first-token-on-silicon-stops-at-step-7.md`.

### 2026-09-18 18:30: THE FIRST GO ON THE COMPOSED CARD RAN SEVEN STEPS, AND THE WATCHDOG IS TOO SMALL FOR 9B BY ARITHMETIC

The 11:28 bitstream is on the card (Oren ran `fk33_reload.sh`; steps 0-3
clean: seam LLM2 v2, caps 0xD, 15 offsets agree). At Oren's direction the
non-sudo steps ran from this session: step 4 (`run_prompt --open-only
--allow-hardware HOST`, 505 descriptors streamed and read back, TBL_LEN 505,
ARENA 0x1_FFADD000, BST 0x1_0C006000 read back), step 7 (flat `noembd`
image, 4.18 GiB in 6.35 s, digest-verified; arena 159,232 B verified), step
8 (`--max-new 1`).

**Result: the GO was ACCEPTED, D ran a VEC_NORM and SIX A JOBS through the
card's descriptor plane -- `ga_desc`, the arm no bench covers -- in ~320,000
cycles with FAULTS 0, then the first B job hit `WDOG_LIMIT = 200,000` and D
reported ERR_WDOG** (`ERR_INFO 0x00070074`: code 4, step 7, 7 done; CYCLES
520,706). The seam wraps it as code 6 and `pl_backend` printed "the
descriptor program was refused", which is wrong for this case; both
messages now decode ERR_INFO.

**200,000 cannot fit a 9B job, DERIVED two ways** (doc:
`docs/debugging/2026-09-18_first-token-on-silicon-stops-at-step-7.md`): B's
recurrent pass alone is 131,072 cycles plus 68,864 state beats each way;
and at the MEASURED A rate (~80 B/cycle on the flat image) the 12,288-row
FFN jobs need ~320,000 each, so step 11 would fire it even with B fixed.
`gen_fk33_card.py` now passes `WDOG_LIMIT=4000000` (53 ms at 75 MHz).
Whether B completes at all is NOT established; the rebuild answers it.

The running x_exp build (17:25) does not carry the watchdog. Decision
pending: restart with both, or let it finish and queue a second.

### 2026-09-18 17:25: THE x_exp FIX IS IN THE TREE, NOT YET IN A BITSTREAM

Oren chose the live port. Four generators edited, five generated files
regenerated, and every board-free check that can see the change is green:

* `rtl/fk33_llama_top.vhd` (`tools/gen_cardtop.py`): `ga_desc` now claims the
  exponent read port at issue (`a_exp_region <= job_src`, the sibling arms'
  line, **which this arm had never had**), latches `r_xexp` from
  `exp_rd_data` in `S_GO` on the edge `ad_start` first rises, and exports it
  as `a_x_exp`. `gnd_a` ties it off in the other arm.
* `hw/fk33/rtl/fk33_engine.vhd` (`gen_fk33_engine.py`): generic
  `USE_XEXP_PORT := false` forwarded to the unit; port `d_x_exp` on
  `x_exp_in`. Default FALSE so the host-driven engine-only flow is untouched.
* `hw/fk33/build_fk33_pcieep.tcl` (`gen_pcieep.py`, `FK33_CARD=1` only):
  `CONFIG.USE_XEXP_PORT {true}` on `eng` with a readback, and the net
  `card/a_x_exp -> eng/d_x_exp`. Same environment test for both halves,
  asserted equal.
* `fk33_card.vhd`, `compose4_top.vhd`: regenerated. `sim:c4stale` caught the
  second one RED before it was regenerated, which is the gate doing its job.

MEASURED: `tb_fk33_cardtop_adesc` checks 13 -> 14 (`a_x_exp` driven at
`A_DESC = true`); `tb_fk33_cardtop_ident` PASS 108 unchanged; `cardtop`,
`runguard`, `kvmap`, `c4stale` green; `--bd-only` under `FK33_CARD=1`:
`FK33_XEXP_PORT true`, `FK33_UNCONNECTED count=0`, `FK33_BD_VALIDATE OK`,
0 errors. Wire mutant (net row removed from the generator): `count=1
/eng/d_x_exp`, FAIL. **And the mutant showed Vivado prints NO 41-759 for a
defaulted port** -- the check is the only guard on that wire (CLAUDE.md,
TRAPS).

NOT measured: the value. No bench runs a job through `ga_desc` against a
descriptor-plane engine. The oracle is the card (`run_prompt` first
divergence vs `reference_tokens.txt`). Doc: fourth addendum of
`docs/debugging/2026-09-17_x-exp-is-baked-into-every-a-descriptor.md`.

**Next: a full `FK33_CARD=1` build with the fix, same recipe as 11:28**
(`FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75
FK33_IMPL_STRATEGY=Congestion_SpreadLogic_high`, `MemoryHigh=20G`). One
32-bit register and one 32-bit net against a design that routed at +0.061;
not launched until Oren says so. Meanwhile the 11:28 bitstream is on the
bench for steps 0-5, which the fix does not touch.

### 2026-09-18 11:28: A BITSTREAM WITH THE SAMPLER, BOTH HBM BASES WIRED, AND THE K CACHE OUT OF THE GDN ARENA

**`hw/fk33/bit/fk33_card_smp_bases_75mhz_2026-09-18.bit`**, 24,880,718 B,
sha256 `a8db5c2b...`. `FK33_BUILD_DONE`, 0 errors, **routed legally** (node
overlaps converged to 0, no `[Route 35-2]`), **`FK33_TIMING WNS=+0.061 ns
WHS=+0.009 ns`** from the build's own sentinel, 0 of 1,412,614 endpoints
failing. Reports and the full log in
`hw/fk33/results/card_smp_bases_2026-09-18/`.

| routed | 2026-09-17 19:04 (no sampler) | **this** |
|---|---|---|
| CLB LUTs | 336,326 (76.49%) | **342,479 (77.89%)** |
| CLB Registers | 304,036 | 306,570 |
| BRAM / URAM / DSP | 449.5 / 32 / 2121 | 449.5 / 32 / 2121 |
| WNS | +0.009 | **+0.061** |
| strategy | Performance_RefinePlacement | **Congestion_SpreadLogic_high** |

Same-stage, same-tree comparison (both routed, both `report_utilization` after
`write_bitstream`, mtime checked). The sampler and the seam registers cost
**+6,153 LUT / +2,534 FF**; BRAM, URAM and DSP are identical.

**What it carries that 19:04 did not:** `SMP_EN=true` with `CAPS_FLAGS=0xD`
(`e62fded`); `a_arena_base` and `bst_state_base` driven from seam registers
`0x6C..0x78`, with a GO refused while either is zero (`2bcd236`); C's K/V
cache moved 1,179,648 B up, out of the correctly sized GDN arena (`2bcd236`);
and the `FK33_UNCONNECTED` build check, which printed `count=0` inside this
run. **This is the first `FK33_CARD=1` build with no `[BD 41-759]` in its
log.**

**What it does NOT carry, stated:** the baked `x_exp`
(`docs/debugging/2026-09-17_x-exp-is-baked-into-every-a-descriptor.md`),
still an open design question; and no whole-token bench covers the
`A_DESC = true` arm this bitstream implements.

**The congestion question is answered by this run and not by a controlled
experiment.** Two variables changed against the failed build: the strategy,
and the bases/K-V. It routed. The clean control (19:04 sources under this
strategy) was not run, so "the strategy fixed it" is the likely reading and
not a measured one.

**Bring-up:** `docs/2026-09-18_seam-bringup-on-the-card.md`, steps 1 onward,
now including the base registers in step 4 and the argmax read in step 8.
Card work is Oren's.

### 2026-09-17 22:00: THE HOST CAN NOW SPEAK THE SEAM THE BITSTREAM CARRIES, AND TWO BLOCKERS SURFACED ON THE WAY

**The finding that reordered the evening.** Looking for what would drive the
seam on card day found that nothing could:

| | before tonight |
|---|---|
| `rtl/fk33_seam.vhd` | **v2** since TRACK DSEAM: windows, `TBL_LEN`, `X_EXP`, no HBM fetch |
| `server/fk33_sim.c` | v1 only |
| `server/pl_backend.c` | v1 only -- writes a block at `X_BASE` and GOes |
| `hw/fk33/host/*.py` | the **engine at 0x12000**, never the seam |

The bitstream in place-and-route implemented a protocol no program in the repo
spoke. `8bdea36` + `47055c4` give the simulator a v2 mode (version-switched, so
v1's 84 checks keep their meaning); `ace2ce6` makes `pl_backend` speak it.
**124 checks, 0 failed**, up from 84 this morning. `server_e2e.py` still PASS.

MEASURED, driving the sim with the REAL 505-descriptor program:

```
program    token.dtbl: 8080 halves (505 descriptors of 8 64-bit words)
card       seam v2 @BAR+0xE000 ... chunk=1
decode     1197 ids generated, pos 1219
bytes      h2c 19972096, go 1219
```

1,219 GOs for 1,219 positions, and 19,972,096 = 1219 * 4096 * 4 exactly.

**THERE IS NO CHUNKED PREFILL ON THIS CARD.** `rtl/fk33_seam.vhd:746` refuses
any `N_STEP` but 1, with a comment on the line. A 23-token prompt is 23 GOs,
and each is **4,096 MMIO writes** of the activation row where v1 did one DMA.
`pl_open` now forces `max_chunk` to 1 and says so, rather than letting a host
discover it one `EC_NSTEP` at a time.

**I got the v2 model wrong first, from the header's prose, and the RTL said
otherwise** (`47055c4`). Two contradictions, each of which would have produced
a wrong driver rather than a failing test: `N_STEP` above, and `TBL_LEN = 0`
being `EC_NSTEP` and not `EC_DESC`. The model was also STRICTER than the card
in two places, which is worse than useless -- those are now `model_strict`,
off by default.

**BLOCKER FOUND AND FIXED: the packed manifest's GDN arena was 1,179,648 B
short**, exactly `24 layers x 49,152 B` of conv tap history
(`docs/debugging/2026-09-17_gdn-arena-omitted-the-conv-tap-history.md`). Stale
artefact, not a code defect. The lane-striped manifest had it too and was
migrated; three older packs are over-reserved, which is safe. The cross-check
was worth more than the fix: the program emits **505** descriptors and
`fk33_seam.vhd:123-125` predicts that number outright, and it fits the card's
windows exactly (505 <= `REL_ENT` 576, 505*8 = 4040 <= `DESC_WORDS` 4608).

**BLOCKER FOUND, NOT FIXED, AND IT NEEDS A DECISION:
`docs/debugging/2026-09-17_x-exp-is-baked-into-every-a-descriptor.md`.**
`hw/fk33/rtl/fk33_engine.vhd:1309` sets `USE_XEXP_PORT => false`, so the card's
A takes `x_exp` from the DESCRIPTOR -- which the RTL's own comment calls "stale
by construction" in the integrated system -- and
`gen_layer_program.py:666` bakes ONE `--x-exp` into all 311 of them.
`seq_opdec.vhd:531` propagates the unit's `y_exp`, so the error carries.
**DERIVED from reading, NOT measured.**

**And the larger gap the same file found:** the card's A binding is
`A_DESC = true` (`fk33_card.vhd:217`), and **no whole-token bench covers it**.
`llama_top` uses `matvec_int4`, a unit with no descriptor plane;
`fk33_llama_top.vhd:738-749` names the two arms and says "THE TWO ARE NOT
EQUIVALENT AND MUST NOT BE READ AS A TUNING CHOICE". So the card's A path has
unit coverage and **no token-level coverage**, which is why 300 passing checks
in `sim_tb_llama_top_seq` have never seen the `x_exp` question.

**Also landed:** `fk33ctl.py seam` (`67c7071`), the first host-side read of the
seam at all -- `fk33_regs.h` had no seam block. One read-only pass, writes
nothing, distinguishes a dead bus from a real-but-wrong answer from a tie-off,
and cross-checks its own register map against `server/fk33_seam.h` at run time.

Build status at 21:59: routing, phase 3.2, 0 errors, 0 placement overlaps,
post-placement WNS +0.375 (**which is not a result** -- nothing before
`route_design` orders two runs correctly on this part).

### 2026-09-17 21:10: THERM-255's HOST HALF IS LANDED, AND THE GOAL HAS A HARNESS

Two things landed while the `FK33_CARD=1` + sampler build runs (started 20:45,
in synthesis at 21:05; unit `buildsmp`, capped `MemoryHigh=20G`, one Vivado on
this box and none on the BC-250).

**`5e8495d` -- THERM-255, all six consumers.** `729df43` enumerated them and
said outright that the fix was designed but NOT landed, because the obvious one
turns a dead veto into a phantom retry on every job. That is resolved: `run_job`
clears the trip counter and PROVES the clear, then publishes
`p["therm"] = dict(trip0, trip1, moved, cleared, guard, saturated)`, and
`run_token`'s wrapper reads that instead of sampling the register either side of
a call that clears it. **The phantom trip is not an argument, it is measured**:
the old wrapper logs `1 call / 1 trip` on a job that merely cleared the counter,
the new one logs `1 call / 0 trip`. The RTL is untouched -- saturation is
correct -- and the CORRECTION is appended in place to the original write-up.
Three new `fk33_run_job.py selfcheck` rows, three new `fk33_run_token.py
selfcheck` rows over a wrapper that **had no coverage at all**, and the 255
fixture section 2a asked for. Every one with its attribution control.

**`2d3cbcf` -- `server/tests/run_prompt.c`.** The committed goal
(`hw/fk33/results/goal_dcdc_2026-09-17/`) now has a program that drives it:
`pl_prefill` then `pl_decode`, FIRST DIVERGENCE against the 1,197 reference
ids. Simulated transport only, never a `/dev` path. MEASURED: the full 1,197
generated, pos 1219, `h2c 10064064 = 1219 * 8256` exactly, no negative return in
1,197 iterations. **The divergence at position 0 is the expected result and
proves nothing about any number** -- the sim's logits are synthetic. It proves
the loop, and the reference becomes an oracle the day it points at silicon.
`--check-argmax` adds the one check with teeth today: the host rescans the
returned row against the card's own argmax register. That is NOT
`pl_backend.c:742`, which compares the row HEADER against the register, two
copies of one computed index; this recomputes it from the data and so catches
both copies being wrong together, which is the `smp_base` shape fixed in
`e62fded`. New sim knob `fault_argmax_bias` exists because the obvious mutant
(`fault_stale_argmax`) is intercepted by the existing check and would have
credited the new one with a kill it did not make.

**Open on both: neither has run against the card.**


### 2026-09-17 19:06: THE WHOLE DESIGN FITS. A, B, C AND D, ROUTED, 75 MHz.

`hw/fk33/bit/fk33_card_withA_75mhz_2026-09-17.bit`, 24,938,098 bytes,
`FK33_BUILD_DONE`, 0 errors. **Subsystem A is IN.**

| | this morning | now |
|---|---|---|
| post-synthesis LUT | 479,909 (**109.15%**) | **347,629 (79.06%)** |
| routed LUT | never routed | **336,326 (76.49%)** = 284,283 logic + 52,043 memory |
| registers | 500,677 | 304,036 (34.57%) |
| route | gave up, global congestion **level 7** | 0 failed / 0 unrouted / 0 overlaps |
| WNS / WHS | never reached | **+0.009 / +0.010**, TNS/THS 0.000 |

**THE ENTIRE GAP WAS ONE LINE.** `gen_vstub[2].gv.vproc.buf` was
`variable buf : buf_t(0 to REGMAX-1)` in a clocked process -- 12,288 x 16 =
196,608 bits in FLIP-FLOPS, 39% of the design's registers -- and the thing
stopping it inferring as memory was a **statically dead** 12,288-wide
combinational read (the NORM_ANCHOR probe). Its identical twin `buf2` had been
distributed RAM all along. `251cbca`, writeup in
`docs/debugging/2026-09-17_one-flop-array-was-the-whole-lut-gap.md`.

**TWO OBVIOUS-LOOKING FIXES CHANGED NOTHING FIRST** -- both measured at
`lut=292383 ff=357608`, identical to the digit: hoisting to a single read site
(the recorded `region_mem` 3-refused/2-accepted threshold does NOT carry over)
and `ram_style` on its own (**no `8-6849` ever named the array** -- Vivado
never treated it as a RAM candidate, which is silence, not a refusal).

**WHAT THIS IS NOT.** A routed bitstream is not a working accelerator. It fits,
closes timing, and is loadable. **It has NOT been on the card** -- programming
needs a human. Whether A computes correctly in hardware is untested, and the
two known gaps are unchanged: `ga_desc` has NO value coverage, and the `x_exp`
divergence between the two A arms is unexplained.

**DO NOT** difference this against the 2026-09-16 engine-less build (316,167
LUT) to price subsystem A at ~20,000 LUT. That build predates this fix, so the
arms differ in RTL as well as in A's presence.

**STILL AVAILABLE if more LUTs are ever needed:** `buf` and `buf2` are 1,152
`RAM64M8` between them and BRAM is at 66.89%, URAM at 10%. And the same
question has not been asked of `u_arr` (50,523 LUT) or `u_kv` (23,101 LUT,
zero LUTRAM).

---

### 2026-09-17 03:50: THERE IS A BITSTREAM. IT CONTAINS B, C AND D, AND NO SUBSYSTEM A.

`hw/fk33/bit/fk33_card_noeng_75mhz_2026-09-17.bit`, 24,695,270 bytes,
`FK33_BUILD_DONE`, 0 errors. Built with
`FK33_CARD=1 FK33_ENG=0 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75`.

**READ THIS BEFORE USING IT: it is not a working accelerator.** With no engine,
Vivado ties `a_y_we`, `a_y_addr`, `a_y_data`, `a_y_mask`, `a_y_exp`,
`a_job_done` and `a_job_err` to 0, so an A job issued by subsystem D never
reports done and the host's poll hangs. It proves the FLOW -- synthesis, place,
route, timing, bitstream over B, C, D, the host seam and the PCIe/HBM shell --
and NOTHING about subsystem A. Label it that way wherever it is used.

**IT HAS NOT BEEN ON THE CARD.** Programming is a hardware action and needs a
human; nothing in this session went near `/dev/xdma*`, `xsdb` or `flash.sh`.

| stage | result |
|---|---|
| synthesis | 330,408 LUT (**75.15%**), 425,925 FF (48.44%), 257 BRAM, 32 URAM, 536 DSP; peak 14.29 GB under a 20G cap, so a real peak |
| place | WNS +0.463 pre-route (**not a result** -- it gave back 0.45 ns, inside the recorded 0.4-0.6 band) |
| route | **WNS +0.013, WHS +0.010**, TNS/THS 0.000; 0 failed / 0 unrouted / 0 partially routed / 0 node overlaps; congestion **level 5** against the engine-on build's level 7; 3 h 30 m |

Reports in `hw/fk33/results/noeng_2026-09-17/` (`ff8af51`). Full account, with
the dead ends, in `docs/debugging/2026-09-16_card-build-is-lut-bound-at-109-percent.md`.

**WHAT THIS DOES NOT RESOLVE.** The card WITH subsystem A is still 109.15% LUT
and still does not route. Nothing here reclaimed a single LUT of that; the
engine was removed, not shrunk. The open item is unchanged and is
architectural: 22,000-31,000 LUT.

**THREE DEFECTS FOUND ON THE WAY, TWO OF THEM MINE (`a138ad0`, `5d880ff`):**

- `_ENG_ADDR_PART` opened with `+=` in the card-off branch, so **the
  engine-only build could not generate at all** while the card build was fine.
  It survived because the byte-identity check was run only with `FK33_CARD=1`:
  a control applied to the arm that was never broken.
- **`--selftest` graded whatever configuration was last written to disk.** Row
  expectations come from the environment, the mutated text from the file, and
  nothing compared them: the same command printed PASS, then FAIL, then PASS,
  with no code change. A mismatch is now VOID with the command to fix it.
- Two address-map rows were engine-dependent and said so only by failing (A5
  now an explicit SKIP, A6's expectation follows `ENG_ON`).

**NEXT, and it is Oren's call:**
1. Program the card with this bitstream and exercise B/C/D from the host (needs
   a human at the hardware).
2. Or go after the 22,000-31,000 LUT so subsystem A can come back.

---

### 2026-09-16: THE ELABORATION WALL IS DOWN. THE CARD SYNTHESISES. A FULL BITSTREAM BUILD IS RUNNING.

**The wall was never the memory SIZE. It was the WRITE PORT COUNT.**

`ga_desc.ap` and `ga_real.ap` stored y as `variable yb : buf_t(0 to
A_MAXROWS-1)` written inside `for rr in 0 to A_ROWS_IF-1 loop` at the DYNAMIC
index `to_integer(unsigned(y_addr)) + rr`. That is `A_ROWS_IF` INDEPENDENT
WRITE PORTS. At 4 (default) Vivado gives up fast with `[Synth 8-3391]`; at 48
(the card) elaboration never returns and emits nothing at all.

**Killed by its own control:** `A_MAXROWS` forced 12,288 -> 512, a 24x
reduction, HANGS EXACTLY AS HARD. Every earlier `A_MAXROWS` control had been
run at DEFAULT generics where nothing is broken, so it could not have failed.
**A control applied to the healthy arm is decoration.** And `8-3391`'s text
blames the bit count and suggests `dissolveMemorySizeLimit` -- a remedy that
would have changed nothing. Full bisect in
`docs/debugging/2026-09-14_the-wall-is-a-3d-ram-vivado-warned-about.md`.

**LANDED TODAY**

| commit | what |
|---|---|
| `dcbea17` | `ga_tie` fix: the card's six weight-master outputs had NO DRIVER in the only shipping configuration. New row `sim:tb_fk33_cardtop_adesc`, the first thing ever to elaborate the `A_DESC` arm. Teeth: 6 bad pre-fix, 0 post-fix, 7 `a_*` controls pass in BOTH. |
| `2f4ab91` | `gb_real.bp.yb` -> block RAM. Teeth: read-index mutant fails `tb_llama_top_real`. |
| `6a2d282` | `ga_desc.ap.yb` -> one beat per word. **Card elaborates: 3:54, 0 errors**, from a >25 min silent hang. |
| `f4e69bf` | `ga_real.ap.yb`, same defect at 4 ports. Teeth: lane-reversal mutant fails `tb_llama_top_real` at `R_X(0) = -16111`. |
| `4b1d58f` | DSP census over-counted **9x**. See below. |
| `a913ca8` `03ca377` `85c7898` `63fe87f` | corrections and root cause, appended in place. |

All three 196,608-bit process variables are gone (`zb` was `587d9b5`).

**MILESTONES MEASURED TODAY**

- **`fk33_card` full synthesis: 745 s, 0 errors, 61 MB DCP.** B, C and D are a
  netlist for the first time.
- **`--bd-only` with `FK33_CARD=1`: `FK33_BD_VALIDATE OK`,
  `FK33_BD_ONLY_DONE`**, 0 errors, `FK33_ENG portcheck bad=0`, zero
  address-overlap warnings, all seven AXI interfaces inferred. That is the
  class no bench can reach.
- **A full `FK33_CARD=1` bitstream build is RUNNING** (launched 14:18, cap
  `MemoryHigh=18G`, 24 GB free, `llama-server` left up).

**CORRECTED CARD AREA (B+C+D; A is a separate cell), xcvu33p:**

| resource | used | available | % |
|---|---|---|---|
| CLB LUT | 292,383 | 439,680 | 66.5% |
| DSP48E2 | **538** | 2,880 | 18.7% |
| Block RAM | 197 | 672 | 29.3% |
| URAM | 32 | 320 | 10.0% |

**THE DSP FIGURE WAS FIRST REPORTED AS 4,842, i.e. 168% AND "DOES NOT FIT".**
`REF_NAME =~ DSP*` matches each `DSP48E2` PLUS its eight internal primitives:
538 * 9 = 4842. A plausible-looking over-count on the one resource most likely
to be exhausted, and it would have been quoted as a blocker against B and C.
Cross-checked against the log's own `Report Cell Usage` (the LUT sum matches
to the digit). Same class as the recorded `PRIMITIVE_GROUP == DSP` trap, which
matched NOTHING -- **a census filter can be wrong in both directions.**

**WHAT IS STILL NOT VERIFIED, and a bitstream will not change it**

- **`ga_desc` has NO value coverage.** The identity bench connects none of the
  `a_*` ports, so `6a2d282` is verified for elaboration and structure only.
  `ga_real`'s twin fix IS teeth-tested, which is the difference.
- **The `x_exp` divergence is OPEN** and would break the arm-identity claim if
  real: `ga_real` reads it live from the lock, the card engine takes it from
  the descriptor (`fk33_engine.vhd:1309` `USE_XEXP_PORT => false`), there is no
  `a_x_exp` port, and `gen_layer_program.py` bakes ONE static value per program
  while `fk33_seam.h` calls `X_EXP` a per-token host register.
- **`BASELINE_PASS` deliberately NOT raised** for `sim:tb_fk33_cardtop_adesc`:
  the floor is a clean-checkout number and this tree carries 23 working-tree-only
  rows.


### 2026-09-15: THE CARD'S WEIGHT MASTERS HAD NO DRIVER, AND TWO THINGS THE SEAM BENCH MUST SETTLE FIRST

**LANDED, teeth-tested.** `fk33_llama_top`'s six weight-master OUTPUT ports
(`m_arvalid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_rready`) had
**no driver at all** in the card configuration (`A_BEHAV` false, `A_DESC`
true). `ga_real` drives them, `ga_tie` ties them off, and their guards are
`if not A_BEHAV and not A_DESC` and `if A_BEHAV` -- so the card matched
NEITHER. Fixed in `tools/gen_cardtop.py` as `ga_tie : if A_BEHAV or A_DESC`.
Full write-up:
`docs/debugging/2026-09-15_card-top-weight-masters-undriven.md`.

New gate row `sim:tb_fk33_cardtop_adesc`, which is **the first thing in this
project ever to elaborate the `A_DESC` arm**. MEASURED, both directions:
against the pre-fix guard `checks=13 bad=6` (exactly the six ports), against
the fix `checks=13 bad=0`. The seven `a_*` checks are a POSITIVE CONTROL and
pass in BOTH runs, which is what makes the six failures attributable to the
tie-off rather than to a generate that never elaborated.

**It does NOT close the coverage gap of `9b4477a`.** It checks that ports have
DRIVERS, not that the binding computes anything. That remains open.

#### AND THE SEAM BENCH IS BIGGER THAN "FLIP THE GENERIC" -- TWO BLOCKERS FOUND BY READING

**(a) The bench has no engine on the far side of the `a_*` ports.**
`sim/tb_fk33_cardtop_ident.vhd` never connects one: `grep -cE
"\ba_(awaddr|wdata|bvalid|y_we|y_data|job_done|x_we)\b"` returns **0** and its
port map ends at `bst_bresp`. With `A_DESC => true`, `a_bvalid` is stuck low so
`a_desc_adapter` never completes a descriptor write and `ad_done` never
asserts; `a_y_we` is stuck low so no y beat arrives. The arm HANGS; it does not
run. **A behavioural stub is ruled out by the bench's own header** -- *"the
true arm drives the REAL `matvec_int4_desc_axi` and not a behavioural model of
it"*, on the m7-mutant round-trip argument. So the bench must instantiate the
real engine and build a descriptor arena reproducing `ga_real`'s S_EXP
arithmetic exactly (`n_rows`, `n_cols`, `out_shift`, `w_exp`, `out_mode`,
`w_base[p] = A_MEM_BASE + j_step*A_JOB_STRIDE + p*A_SUB_BYTES`, `s_base`,
`w_beats = tiles*nb`, `s_beats = (tiles*nb*A_ROWS_IF*2+15)/16`).

**(b) OPEN, AND IT MAY BREAK THE IDENTITY CLAIM OUTRIGHT: the two arms do not
agree on where `x_exp` comes from.** `ga_real` reads it LIVE from the lock
(`r_xexp <= resize(exp_rd_data, 32)`, S_EXP), which its own comment calls *"the
producing job's captured exponent ... part of the locked object"*. The card's
engine takes it from the DESCRIPTOR: `hw/fk33/rtl/fk33_engine.vhd:1309` sets
`USE_XEXP_PORT => false` and `:1353` ties `x_exp_in => x_exp_zero`. And
`fk33_llama_top` has **no `a_x_exp` port**, so `ga_desc` has no way to send a
live value even if the engine would take one. Meanwhile
`tools/gen_layer_program.py` takes `x_exp` as **one program-level argument**
(`a.x_exp`, required at `:1175`), i.e. a single static value stamped into every
descriptor.

`matvec_int4_desc_axi`'s own header already states the hazard: *"the activation
vector's block exponent is a per-token value produced by the previous stage, so
the descriptor's copy is stale by construction"*, and `USE_XEXP_PORT` exists
precisely to fix it. **The card does not use it.**

**AND THE LIVE VALUE IS EXPLICITLY PER-TOKEN**, which makes the static copy
more suspicious rather than less. `server/fk33_seam.h:265-276` calls `TBL_LEN`
and `X_EXP` *"the two things subsystem D actually needs from a host every
token"*, and maps `X_EXP` to the top's `host_x_exp` port
(`rtl/fk33_llama_top.vhd:765`, consumed at `:1714`). So the live path is
host -> `host_x_exp` -> the exponent lock -> `ga_real`'s `exp_rd_data`, updated
every token; the descriptor path is a value frozen at program-generation time.

**NOT YET DETERMINED, and do not write this up as a defect until it is:**
whether the shipping flow keeps the descriptor's `x_exp` current by other means
(the host rewriting descriptors per token), or whether `x_exp` is intended to be
fixed for a program. If neither holds, the two arms cannot compute identically
and the bench's landmark rule -- *"THE LANDMARKS ARE NOT RE-DERIVED FOR THE
true ARM AND MUST NOT BE"* -- is unsatisfiable as written. **Settle this BEFORE
building the arena**, because the arena's `x_exp` field is the thing in
question and building it first would bake the assumption in.

#### STILL OPEN, unchanged
The `8-3391` y stores: `ga_desc.ap.yb` (the one the CARD builds),
`ga_real.ap.yb` (`rtl/llama_top.vhd:3543`) and `gb_real.bp.yb` (`:4477`), all
12,288-element process variables. `gb_real.bp.zb` was fixed in `587d9b5`.


### 2026-09-12: THE A AUDIT -- A MEASURED 42,633-LUT LEVER SITTING UNUSED, AND A CHECK THE CARD QUALIFIES FOR

Completing the per-subsystem generic audit (B, C and D done; A was the gap).
`hw/fk33/rtl/fk33_engine.vhd` has exactly two generics and
`hw/fk33/build_fk33_pcieep.tcl` passes **neither**, so both defaults apply.
**Neither is a defect -- both are documented -- but one is a large unused
lever.**

**1. `CB_STYLE = "regs"`, and `"distributed"` is worth -42,633 CLB LUT.**
Already MEASURED by TRACK LEVERC48 (`a4828ab`) at `ROWS_IF = 48`:
**-42,633 CLB LUT, MUXF7 24,583 -> 0, MUXF8 12,288 -> 0**, costing
**+13,195 CLB FF and +12,288 LUTRAM**. That is **9.7% of the part's 439,680
LUT**, available today.

**BUT THE FIGURE IS 264 COMMITS OLD AND A'S PATH HAS MOVED.** `a4828ab` is
dated **2026-08-30**; `git rev-list --count a4828ab..HEAD` = **264**, and
`git diff --name-only` over A's path shows **`hw/fk33/rtl/fk33_engine.vhd`,
`rtl/matvec_int4_desc_axi.vhd` and `rtl/matvec_int4_desc_pkg.vhd` have all
changed since**. `rtl/matvec_core.vhd`, which holds the `CB_STYLE`
implementation itself, has NOT. **Re-measure before acting on -42,633.** This
file already records a case where a week-old area table was wrong by 9.7x on
one subsystem and a whole conclusion was built on it; 264 commits is a good
deal more than a week.

The default is DELIBERATE and the reason is stated in the file: `"regs"` is
*"the shipping value and keeps this entity byte-identical in behaviour to the
bitstream on card 1"*. **So this is a DECISION, not an oversight** -- but it
is a decision made when the fit looked hopeless, and tonight's corrected B and
C figures change what it is being traded against. Worth re-deciding, not worth
flipping silently.

Note the file also records WHY the lever was previously unreachable: it was
forwarded through `matvec_int4_desc_axi`/`matvec_int4`/`matvec_int4_axi` but
`fk33_engine` -- the entity the card and `compose4_top` actually bind -- had
no generics at all, so it was reachable *"from a unit synthesis of
matvec_core and from NO top the card or the composition actually builds"*.
**And `-generic` on the `synth_design` line does not help: it reaches the
TOP's generics only, never a deep instance.**

**2. `CHECK_JOB_INDEX = false`, and the card QUALIFIES for true.** The file's
own rule: *"A build that drives `job_index` from `rtl/a_job_counter.vhd` sets
this true and gains the check."* VERIFIED: `rtl/fk33_llama_top.vhd`
instantiates `u_jc : entity work.a_job_counter` and wires
`job_index => a_job_index` (:3666). The card therefore drives it from the
counter and is **not opting in**, losing the v2 descriptor index check that
refuses *"a well-formed descriptor for the WRONG step"*.

This is the file's stated safe direction -- *"forgetting to opt in loses a
check, forgetting to opt out breaks a working card"* -- so it is a missed
check rather than a hazard. `gen_compose4_top.py --wire` already opts in; the
card does not.

### 2026-09-12 (earlier): B'S 5,472-BRAM BLOCKER IS THE ARM THE CARD DOES NOT BUILD. ON THE CARD'S ARM IT IS 50.

**MEASURED, one variable, same tree, same box, both arms 0 errors**
(`GDNADAPT_MAXROWS=2048` on BOTH, only `B_STATE_AXI` varied):

| `B_STATE_AXI` | LUT | FF | BRAM | URAM | DSP |
|---|---|---|---|---|---|
| `false` -- what EVERY prior B figure used | 148,995 | 77,973 | **5,472** | 0 | 191 |
| `true` -- **what `fk33_card.vhd` passes** | 85,255 | 69,783 | **50** | **32** | 194 |

**The project's headline B blocker -- "5,472 RAMB36 against 672 on the part"
-- is an ARTIFACT OF THE ARM THE CARD DOES NOT BUILD.** On the card's arm B's
mover uses **50 of 672 BRAM tiles and 32 of 320 URAM288**. It fits, with room.
LUT falls 43% as well.

**Two independent corroborations, which is why this is not another of tonight's
mis-measurements:**
1. The CONTROL reproduces 5,472 **exactly**, so the setup is sound and the
   figure's true configuration is now known: `B_STATE_AXI=false`,
   `MAXROWS_OVR=2048` -- NOT the 9B shape, which fails by documented design.
2. The recorded standalone `gdn_state_store` figure is **32 URAM288**, and 32
   URAM288 is precisely what appears when the tiered arm is selected --
   because `gen_st_tier` is what instantiates it. Two separate measurements
   agreeing on a number that only exists in one of the two arms.

**SCOPE LIMIT, stated rather than glossed:** `maxrows=2048`, so the LUT and FF
magnitudes are NOT 9B figures. The BRAM result should carry to 9B because the
flat state array is sized by LAYERS (`NLY*STLY`) and not by `MAXROWS` -- but
that is REASONING, not measurement, and the 9B shape cannot be synthesised in
this harness at all (`zb`/`yb` are process variables of 12,288 x 16 bits).

**WHAT THIS CHANGES.** "B does not fit" has been a standing project premise.
It rests on a measurement of a configuration the card does not build. Taken
with the corrected C figure (112,519 LUT at the card's shape, area in the MAC
array), **both of the two subsystems believed to be area blockers were
measured in configurations the card does not use.**

### 2026-09-12 (earlier): B'S HARNESS FAILS AT THE 9B SHAPE BY DOCUMENTED DESIGN, AND I CALLED IT A DEFECT

**WITHDRAWN IN FULL, WITHIN THE HOUR, AND THE HEADING ABOVE IS THE CLAIM BEING
WITHDRAWN.** I recorded that `sim/ooc_gdnadapt.tcl` "does not run at HEAD" and
that the headline B blocker was therefore unreproducible. **Both are wrong.**

`rtl/ooc_gdnadapt_top.vhd:69-79` documents this failure in its own header:

> `MAXROWS_OVR` ... exists because the block declares `zb` and `yb` as process
> VARIABLES of `buf_t(0 to A_MAXROWS-1)`, and at the 9B shape that is
> 12,288 x 16 bits EACH. **Synthesis of the extracted block at the default
> shape fails:** `ERROR: [Synth 8-3391] ... 'gb_real.bp.zb_reg' ...` and Vivado
> then terminates abnormally (signal 11). **This generic is the control that
> separates "the block is unsynthesisable" from "the block is unsynthesisable
> AT THIS SIZE", which are different findings.**

So the harness behaves exactly as documented, `MAXROWS_OVR` is the provided
workaround, and 196,608 bits is precisely `12,288 x 16`. I ran it at the
default `MAXROWS_OVR=0` and reported the documented outcome as a defect.

**What this cost, and the lesson:** a control run of the pre-edit script (the
right instinct) correctly told me my edit was innocent -- and I then converted
"not my edit" into "already broken" without reading the twenty lines of header
that name the error verbatim. **Ruling out one cause promotes nothing; this
file already says so about the BRAM attribution, and I did it again.** The
cheap step I skipped was reading the entity, which this file also already
prescribes.

**FOUR wrong claims of mine in this one thread, each retracted by evidence:**
(1) `C_MAXPOS=131072` breaks it -- refuted at `maxpos=4`; (2) harness and card
"disagree" about `zb_reg` -- built on (1); (3) the harness is broken at HEAD --
refuted by its own header; (4) commit `121dc7d`'s message attributing the
5,472 RAMB36 figure to this harness's flat arm -- still unsupported, since the
figure's own `MAXROWS` is unknown. I also varied TWO generics at once in the
first attempt.

**WHAT IS ACTUALLY ESTABLISHED, all of it structural and read from the RTL:**
`B_STATE_AXI` selects `gen_st_flat : if not B_STATE_AXI` (the flat all-layers
state array) against `gen_st_tier : if B_STATE_AXI` (state over AXI to HBM);
`hw/fk33/rtl/fk33_card.vhd` passes **true**; the harness defaults **false**.
So B's area on the arm the card builds is **still unmeasured**, and the
experiment is runnable -- at a reduced `MAXROWS_OVR`, which makes it a valid
one-variable test of `B_STATE_AXI` even though the magnitudes are not 9B.

**THE CARD PATH REMAINS CLEAN**, from `cardooc`'s own log rather than any
harness: 0 ERROR lines, zero `zb_reg` mentions, full elaboration of
`fk33_card`.

### 2026-09-12 (earlier): C AT THE CARD'S REAL SHAPE IS 112,519 LUT, AND THE AREA IS THE MAC ARRAY

**MEASURED on the BC-250: `sim/ooc_gdnadapt.tcl` fails at HEAD**, producing no
utilization at all:

```
ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for
'gb_real.bp.zb_reg' because the memory pattern used is not supported.
Failed to dissolve the memory into bits because the number of bits (196608)
is too large.
```

**CONTROL, and it is the only reason this is attributable:** the script was
checked out from `121dc7d~1` -- the version before tonight's edit -- shipped
to the box and run verbatim. **It fails identically.** So tonight's edit did
not break it; **it was already broken.**

**CONSEQUENCE: the project's headline B blocker, 5,472 RAMB36 against 672 on
the part, is NOT REPRODUCIBLE from the harness credited with it.** Either the
tree has moved since it was taken or it came from a different script. Until
that is resolved, **do not quote 5,472 as a current measurement**, and do not
treat "B does not fit" as established.

**AND B'S AREA ON THE ARM THE CARD BUILDS IS STILL UNKNOWN.** The experiment
that motivated all this could not be run.

**WHAT SURVIVES, from READING the RTL rather than from any measurement:**
`B_STATE_AXI` selects between two mutually exclusive generates in
`rtl/ooc_gdnadapt_top.vhd` -- `gen_st_flat : if not B_STATE_AXI` (the flat
all-layers state array) and `gen_st_tier : if B_STATE_AXI` (state over AXI to
HBM) -- and `hw/fk33/rtl/fk33_card.vhd` passes **true** while the harness
defaults **false**. So the concern is structurally real and remains
unquantified.

**CORRECTION to commit `121dc7d`'s message**, which claimed the 5,472 figure
came from this harness's flat arm. The structural half is right; the
attribution half is unsupported, because the harness does not run.

**TWO WRONG DIAGNOSES OF MINE ALONG THE WAY, both retracted by measurement:**
(1) "`C_MAXPOS=131072` breaks it" -- refuted, the rerun at `maxpos=4` failed
identically; (2) "the harness and the card disagree about `zb_reg`" -- built
on (1) and premature. **I also varied TWO generics at once** (`B_STATE_AXI`
and `C_MAXPOS`) in the first attempt, after a night of insisting on
one-variable controls, which is what made (1) look plausible.

**THE CARD PATH IS CLEAN, and this is from `cardooc`'s own log, not a
harness:** 0 ERROR lines, zero `zb_reg` mentions, full elaboration of
`fk33_card`. Whatever ails the harness does not ail the card.

### 2026-09-12 (earlier): C AT THE CARD'S REAL SHAPE IS 112,519 LUT, AND THE AREA IS THE MAC ARRAY

**MEASURED, card-faithful, 0 errors** (`C_KV_AXI=true C_KV_BLOCK=32
C_N_ROT=64 C_MAXPOS=131072 C_CTXLEN=131072 C_KV_RBUF=4`), BC-250,
`report_utilization -hierarchical`:

```
ooc_cattnadapt_top   112,519 LUT   115,424 FF   301 DSP   16 BRAM   0 URAM
  gcr.gkvaxi.u_kv     25,485 LUT    20,584 FF     3 DSP            <- attn_kv_axi
  gcr.u_attn          84,918 LUT    94,521 FF   298 DSP            <- attn_block
    u_arr             55,689 LUT    39,312 FF   256 DSP            <- the MAC array
  (top itself)         2,196
```

**FINAL, every card generic set (2026-09-12): 112,549 LUT, 115,426 FF,
301 DSP, 16 BRAM, 0 URAM.** The last two unset generics were the HBM bases
`C_K_BASE_CH`/`C_V_BASE_CH`, left at 0, where zero is NOT neutral because the
address adders constant-fold away. Setting them to the card's 282598912 /
353902080 costs **+30 LUT** (112,519 -> 112,549), all of it inside
`attn_kv_axi` (25,485 -> 25,515) with `attn_block` unchanged to the digit. So
the "optimistic" caveat was right in direction and **negligible in magnitude,
0.03%** -- recorded because a caveat that turns out not to matter is still
worth closing rather than leaving open.

**C's mover is 25.6% of the part's 439,680 LUT**, and the area sits in
`attn_block`/`u_arr`, i.e. in the COMPUTE, which is where it should be.
`attn_kv_axi` is 23% of the mover. Memory is inferred properly here: 16 BRAM
tiles, `u_attn/ypre` as a `RAM_SDP 4096x24`.

**THE ENTRY THAT STOOD HERE FOR AN HOUR IS WITHDRAWN IN FULL.** It said "C's
area is `attn_kv_axi` and it is 238,410 LUT of registers", concluded the KV
interface was built from a quarter-million flip-flops with zero memory
primitives, and called that the thing to attack. **All of it was an artifact
of generics I failed to set.** Same harness, same tree, same box, the only
difference being the three generics named above:

| | wrong run | card-faithful | ratio |
|---|---|---|---|
| top LUT | 325,794 | **112,519** | 2.9x |
| `attn_kv_axi` LUT | 238,410 | **25,485** | **9.4x** |
| `attn_kv_axi` FF | 274,550 | **20,584** | 13.3x |
| BRAM | 16 (top) | 16 | -- |

**`C_KV_RBUF` 64 vs 4 -- one buffer-depth generic -- moved that block by 9.4x
and the whole measurement by 2.9x.** The "registers where memory was intended"
signature vanished entirely at the real depth.

**Two independent confirmations the corrected figure is the right one:** it
agrees in magnitude with the standalone `attn_kv_axi` measurement of 33,259
LUT taken earlier from a different harness, and that agreement is what makes
238,410 the lone outlier rather than leaving the standalone unexplained. **A
7x disagreement between two harnesses was the tell, and chasing it rather than
picking the number that suited the story is the only reason this was caught.**

**THE LESSON, FIFTH INSTANCE OF THE SAME SHAPE IN TWO DAYS AND THE FIRST ONE
THAT WAS MINE:** an unset generic is a claim that the default is right, and
**OOC harnesses are where measurements come from, so their defaults matter
more than the design's.** The audit recorded yesterday covered
`fk33_card.vhd` against `llama_top` and did not cover the harnesses. Worse,
`rtl/ooc_cattnadapt_top.vhd` defaults `C_KV_RBUF` to **64** where the
`llama_top` it was EXTRACTED FROM says **4** -- an extraction that changes a
default looks exactly like the thing it came from and has no tell.

`sim/ooc_cattnadapt.tcl` now exposes `CATTN_MAXPOS`, `CATTN_CTXLEN` and
`CATTN_RBUF`, with defaults that reproduce every figure taken before the
change.

### 2026-09-11 (earlier): THE COMPOSED AREA FIGURE OMITS SUBSYSTEM C'S ENTIRE MOVER

**ATTRIBUTED INSIDE ONE SYNTHESIS, not by subtracting contexts.**
`report_utilization -hierarchical`, `ooc_cattnadapt_top`, card geometry
(`C_KV_AXI=true C_KV_BLOCK=32 C_N_ROT=64`), BC-250, 0 errors:

```
ooc_cattnadapt_top        325,794 LUT   369,197 FF   296 DSP
  gcr.gkvaxi.u_kv         238,410 LUT   274,550 FF     0 DSP    <- attn_kv_axi
  gcr.u_attn               85,188 LUT    94,351 FF   296 DSP    <- attn_block
    u_arr                  56,155 LUT    39,247 FF   256 DSP
    8 head units            ~4,088
    u_emit                     692
  (top itself)              2,196
```

**`attn_kv_axi` is 73% of C's mover and 54% of the WHOLE PART's LUTs by
itself** (439,680 on xcvu33p). The attention compute is 85,188. **The area
problem is the KV cache interface, not the arithmetic** -- and nothing was
looking there, because every composed top instantiates `attn_block` and NOT
`attn_kv_axi`.

**AND THE SHAPE IS THE REAL FINDING: it uses NO MEMORY PRIMITIVES AT ALL.**
`LUTRAMs 0, SRLs 0, RAMB36 0, RAMB18 0, URAM 0, DSP 0` -- 238,410 **logic**
LUTs and **274,550 flip-flops**. A KV cache interface holding a quarter of a
million registers and not one block RAM is this file's own recorded
signature: *"if a run reports `RAM=0 FF=1024` you have registers"*. The part
has 320 idle URAM288 and 672 BRAM tiles.

**OPEN, AND IT DECIDES WHETHER THE ABOVE IS THE REAL NUMBER: the same module
measured 33,259 LUT / 20,653 FF standalone earlier the same session**
(`sim/ooc_attn_kv_axi_card.tcl`, card geometry), against 238,410 / 274,550
here. **A 7x discrepancy for one module.** Either the two harnesses pass
different generics, or it is the cross-context effect this file already
records. **Do not quote either figure as C's KV cost until that is settled**,
and settle it by diffing the two harnesses' generics, not by preferring the
number that suits the argument.

**CORRECTION, same night, BEFORE THIS WAS ACTED ON: the 238,410 IS NOT THE
CARD'S CONFIGURATION AND THE HEADLINE ABOVE IS WITHDRAWN.** The discrepancy
the entry flagged as open is now settled, and it settles AGAINST my own
number. `rtl/ooc_cattnadapt_top.vhd`'s generic defaults are not the card's,
and I overrode only three of them:

| generic | ooc top default | what the CARD gets | used in my run |
|---|---|---|---|
| `C_MAXPOS` | **4** | **131072** | 4 |
| `C_KV_RBUF` | **64** | **4** (`llama_top`'s default; card does not override) | 64 |
| `C_KV_BLOCK` | 4 | 32 | 32 (overridden) |
| `C_N_ROT` | 8 | 64 | 64 (overridden) |

So that synthesis built a **16x oversized read buffer at a toy 4-position
context**. `POSW` is derived (`clog2(C_MAXPOS+1)`) so it followed C_MAXPOS
down. **238,410 LUT measures a configuration nothing will ever build.**

Note the divergence that made it possible: **the extracted OOC top defaults
`C_KV_RBUF` to 64 while the `llama_top` it was extracted from defaults it to
4.** An extraction that changes a default is a trap with no tell, because the
harness looks like the thing it came from.

**This is the unset-generic defect shape for the FIFTH time in two days, and
this time I walked into it myself** -- after writing the entry that says to
audit generics rather than wait for the next one to surface. The audit I did
covered `fk33_card.vhd` against `llama_top`; it did not cover the OOC
harnesses, and those are where measurements come from.

What SURVIVES the correction: the attribution SHAPE is still informative --
within that synthesis `attn_kv_axi` dominated `attn_block` and used **zero**
memory primitives while holding 274,550 flip-flops. Whether that holds at
`RBUF=4` and `MAXPOS=131072` is now the question, and it is being re-measured.

Levers already closed, both MEASURED with one-variable controls on the same
tree and box: `C_N_ROT` 8 -> 64 costs +21 LUT, and `C_KV_BLOCK` is
non-monotonic in LUT with its minimum at the 32 the card already builds
(413,341 / 325,794 / 350,326 at 16 / 32 / 64). **So neither knob touches the
238,410, which is now the only thing worth attacking.**

### 2026-09-11 (earlier): THE COMPOSED AREA FIGURE OMITS SUBSYSTEM C'S ENTIRE MOVER

**STRUCTURAL, not an estimate.** `hw/fk33/rtl/compose4_top.vhd` instantiates
`attn_block` ONCE and `attn_kv_axi` **ZERO** times, and it does not
instantiate `llama_top`'s `gcr` block at all. So every composed area number
this project has quoted contains C's compute block and **none of C's data
mover**.

**MEASURED the same day, one coherent synthesis (not a sum across trees):**
C's mover at the CARD's geometry -- `ooc_cattnadapt_top`, `C_KV_AXI=true`,
`C_KV_BLOCK=32`, on the BC-250, 0 errors:

```
CLB LUTs*        325773 of 439680   74.09%     <-- C's MOVER ALONE
CLB Registers    369188 of 879360   41.98%
DSPs                296 of   2880   10.28%     (= 2*G*KV_BLOCK + rest, G=4)
Block RAM Tile       16 of    672    2.38%
F7 Muxes          53519      F8 Muxes  20334
```

`attn_block` alone was 87,340 LUT in its own context, so the mover's
buffering and muxing is the bulk of that 325,773 -- and it is exactly what
the composed top leaves out.

**MY OWN EARLIER NOTE THIS SESSION IS WITHDRAWN.** I recorded that compose4
"excludes both HBM-facing blocks, understating the fit by ~37k LUT + 32 URAM
+ 12 BRAM". The scale is wrong by an order of magnitude: the omission is C's
whole mover, not two peripheral blocks.

**AND THE HEADLINE B+C+D FIGURE SAYS SO ABOUT ITSELF.**
`hw/fk33/gen_compose4_top.py:16` states that TRACK DISTRAM's 217,381 CLB LUT
is *"the SUM of seven independent `synth_design -mode out_of_context` runs,
with `opt_design` deliberately not run, across FOUR different pinned trees,
none of them placed and none routed."* That is the cross-context arithmetic
this project forbids elsewhere, labelled as such at the source and quoted
downstream anyway.

**DO NOT turn this into a new total by subtraction.** 325,773 minus 87,340 is
two measurements from different contexts, not a delta; this file has already
recorded that Vivado maps the same RTL differently depending on what surrounds
it. What is established is STRUCTURAL -- the composed number omits the mover
-- and that the mover is large in its own right. **The fit question needs one
composed synthesis that actually contains C's mover, which is precisely what
`cardooc` is doing.**

**AND C_N_ROT 8 -> 64 IS FREE. MEASURED, two points, one variable.** Same
harness, same tree, same box, `C_KV_AXI=true` and `C_KV_BLOCK=32` held
constant, only `C_N_ROT` varied. Both runs print a `CATTN_CONFIG` line, so the
generic demonstrably took effect rather than being silently ignored:

| C_N_ROT | LUT | FF | DSP |
|---|---|---|---|
| 8 (harness default, what every prior C figure used) | 325,773 | 369,188 | 296 |
| 64 (what the card builds) | 325,794 | 369,197 | 296 |
| **delta** | **+21** | **+9** | **0** |

**An 8x increase in rotation pairs costs 21 LUTs, 0.006%.** Today's `C_N_ROT`
correctness fix is therefore free, and the worry that the card's rotation
count would move the fit is **MEASURED and REJECTED -- do not retry it.**

`sim/ooc_cattnadapt.tcl` never set `C_N_ROT` before today, so every C area
figure in this project was taken at one eighth of the shipping rotation count.
That turned out not to matter, but it was not KNOWN not to matter.

**AREA ONLY.** This harness has no `route_design`, so no timing claim is made
or admissible from it.

**AND C_KV_BLOCK IS NOT THE LEVER: LUT IS NON-MONOTONIC WITH ITS MINIMUM AT
THE VALUE THE CARD ALREADY BUILDS.** Three points, same tree, same box,
`C_KV_AXI=true` and `C_N_ROT=64` held, only `C_KV_BLOCK` varied:

| C_KV_BLOCK | NBLK | LUT | FF | DSP |
|---|---|---|---|---|
| 16 | 16 | 413,341 | 376,889 | 168 |
| **32 (the card)** | 8 | **325,794** | 369,197 | 296 |
| 64 | 4 | 350,326 | 367,949 | 552 |

Moving off 32 costs **+26.9% LUT** going down and **+7.5%** going up, while
DSP scales structurally. **So C_KV_BLOCK is MEASURED and REJECTED as an answer
to C's area -- do not retry it.** LUT is the scarce resource here; DSP sits at
10% of the part.

**CORRECTION, appended 2026-09-12: THESE THREE MAGNITUDES ARE NOT THE CARD'S
SHAPE.** This sweep ran before the harness-defaults defect was found, so all
three points carry `C_MAXPOS=4`, `C_CTXLEN=4`, `C_KV_RBUF=64` instead of the
card's 131072/131072/4. The card-faithful total at blk=32 is **112,519 LUT,
not 325,794**. What survives is the SHAPE -- non-monotonic with a minimum at
32 -- because that rests on a structural argument about
`NBLK = HEAD_DIM/KV_BLOCK` rather than on the magnitudes, and the DSP model
below is unaffected since DSP does not depend on the KV buffer depth. **The
sweep has NOT been repeated at the corrected settings**, so do not quote
413,341 / 325,794 / 350,326 as card numbers. See
`docs/debugging/2026-09-12_the-harness-defaults-that-were-not-the-cards.md`.

**DSP is EXACTLY structural and the derived model holds at all three points:**
`2*G*KV_BLOCK + 40` with G=4 gives 168 / 296 / 552 against measured
168 / 296 / 552.

**A PREDICTION I REGISTERED AND GOT HALF WRONG, recorded because the wrong
half is the informative one.** Before the blk=64 point ran I predicted DSP 552
(**right, exactly**) and LUT *below* 325,794 on the reasoning that
`NBLK = HEAD_DIM/KV_BLOCK` sizes the `emin_tree` and NBLK would drop 8 -> 4.
LUT **ROSE** to 350,326. **The "NBLK drives LUT" explanation is REFUTED**: it
is right about the 16 point and wrong about the 64 point, so it is not the
mechanism, and whatever dominates LUT here is not the reduction tree width.
Not chased further, because the lever is closed either way.

This is the file's own rule arriving intact: **a quantity that is structural is
a constant and holds exactly (DSP); a quantity that scatters is not a slope
(LUT). Do not fit the second kind.**

A caution on the 74% itself: it is an isolated synthesis of a generated
wrapper top with no surrounding context to optimise against, so it is an upper
bound on that block's contribution rather than its cost in situ.

### 2026-09-11 (earlier): THE CARD BLOCK DESIGN IS CLEAN -- 0 ERRORS, ON THE BC-250

**`--bd-only` PASSES on the card configuration: 0 errors,
`FK33_BD_VALIDATE OK`, peak 3,754 MB, ~4 min on the BC-250.** First run since
today's `C_REAL` / `C_N_ROT=64` / `C_KV_BLOCK=32` changes.

**What this buys: the long silent synthesis phase is NOT a block-design
problem.** `--bd-only` is the stage that catches packager errors, the
`natural`-port and `clog2`-in-a-port-width refusals, and address-map
collisions -- none of which any bench can reach. All clean. So whatever
`cardooc` is doing for hours, it is not a malformed BD.

**ANCHORING THE SENTINEL MATTERED, MEASURED:** `FK33_BD_ONLY_DONE` matches
**6** times unanchored and **2** anchored -- four matches are the script's own
commented source echoed into its own log. A waiter on the unanchored pattern
would have declared success at launch. Third recorded instance of the
self-match trap in this project, and the first where it was checked BEFORE
believing the result rather than after.

**OPEN, flagged not dismissed: 32 x `BD 41-1377`.** "Network address
<0x0000_0000 [256M]> is occupied by different slave segments,
`/hbm/SAXI_00/HBM_MEM00` in `/jtag_hbm/Data` and `/hbm/SAXI_16/HBM_MEM00` in
`/xdma/M_AXI`. This is illegal and must be resolved before passing
validation." **And validation then passed.** Those are two different MASTERS'
address spaces -- the same structural fact that `parse_address_map` was taught
today -- so Vivado is likely being conservative, but a message saying
"illegal" beside a clean validate is contradictory and is not yet understood.
167 critical warnings total, 0 errors.

### 2026-09-11 (earlier): THE CARD NORMALISES WITH A RAMP, NOT THE MODEL'S GAINS

**FOUND, NOT FIXED, and it is a correctness blocker for inference on the
card.** `hw/fk33/rtl/fk33_card.vhd` passes `NORM_REAL => true` and does NOT
pass `NORM_W_IMAGE`, which therefore defaults to `""`. `rtl/fk33_llama_top.vhd`
is explicit about what that means: *"this ramp is what runs when it is
empty"*. So the bitstream under construction computes RMSNorm with a
**synthetic ramp gain instead of the model's learned gains**. The structure is
real and the numbers are wrong.

**This is the FOURTH instance of the SAME defect shape in one day**, after
`C_REAL` (C built as a stub), `C_KV_BLOCK` (4 vs 32) and `C_N_ROT` (8 vs 64):
**a generic whose declared DEFAULT is the SIMULATION value, so leaving it
alone looks conservative and is wrong for the card.** Four for four. The
lesson has outgrown the individual instances: **on the card top, an unset
generic is a claim that the simulation default is right for hardware, and that
claim has been false every single time it has been checked.** Audit the whole
generic list against what the card needs, rather than waiting for the next one
to surface.

**NOT fixed here, deliberately, and the reason is NOT effort.**
`NORM_W_IMAGE` is declared by its own RTL to be **stimulus, not a card path**:
*"It is NOT a weight region, a descriptor field or a packing. The design still
has no way for a norm gain to reach this unit from HBM."* Setting it would
bake every layer's gains in as an elaboration-time constant table, which is
legitimate for a fixed model but is a real BRAM decision on a part where the
fit is already the open question, and it is not the mechanism the design
intends. **Do not set it casually to make a seam comparison pass.** The actual
missing feature is a fetch path for norm gains, which is new RTL of the same
class as `B_SRC_REAL`.

**THE AUDIT THE LESSON DEMANDS, DONE: 58 generics, 15 passed, 43 left at
default, and only ONE new defect in them.** Two suspicions were raised and
both are REFUTED, which is the point of writing them down rather than leaving
them as unease:

- **`A_N_JOBS = 311` is CORRECT**, not a stale default. DERIVED at the 9B
  shape and independently cross-checked: `gen_mv4i_desc.py` records
  "311 of 311 A jobs, 0 refused" and `check_a_geometry.py` names the same
  figure.
- **`A_MEM_BASE` DOES NOT MATTER on the card path.** With `A_DESC => true`
  the generated `ga_desc` branch takes real `w_base`/`s_base` from the
  descriptor plane. The fabricated `A_MEM_BASE + j_step * A_JOB_STRIDE`
  belongs to `ga_real`, which the card does not build. It looked like a
  half-configured pair with `A_JOB_STRIDE` and is not.
- **`SMP_EN = false` independently cross-confirms today's `CAPS_FLAGS` fix.**
  There is genuinely no sampler, so clearing bit 2 was right for a reason
  arrived at separately from the one that prompted it.

Net: one new defect (`NORM_W_IMAGE`), one already-tracked gap
(`B_SRC_REAL = false`), and 41 widths and lane counts that are legitimately
defaulted. **The unset-generic risk is now BOUNDED rather than open.**

Consequence to carry forward: **a card bitstream produced before that lands
cannot be judged against the reference on `R_XN-L`, `R_XN.ffn-L` or
`R_XN.final`** (9 of the 63 captured seams), because the model's gain is not
what normalises them. It can still prove the plumbing, the sequencing and the
seam contract, which is what the current build is for.

### 2026-09-11 (earlier): FOUR DEFECTS IN THE RUN GUARD, AND A VOID IS NOT NEUTRAL

**`sim:runguard` was red on every card-on file, so it was red for as long as
the card is the build target.** Not a regression; four separate defects, and
the first three were only visible once the one in front of them was fixed.

1. **The needle arm refused EVERYTHING.** `_ADDR_NEW_NEEDLES` pinned the
   engine-only spelling of the seam's `d_err` wiring, which does not exist
   with `FK33_CARD=1`. So `_arm_new` reported a missing needle for every row
   INCLUDING the unmutated control: A0 "refused the shipping address map",
   three legal maps were reported as wrongly refused, and **`MAP ALONE=0` was
   an ARTIFACT** -- an arm that refuses everything leaves nothing attributable
   to `check_bar_map` alone. The selftest was reporting its own defect as the
   address map's.
2. **That masked a REAL BLIND SPOT.** With the arm honest, A5 was **accepted
   by everything**: the engine control page moved onto the 8 KB scratch, which
   the emitted file's own comment says cost a `--bd-only` run.
   `parse_address_map` skipped every `-target_address_space` line as "HBM".
   With the card on, `eng/s_axi/reg0` is assigned at 0x12000 inside a
   `foreach sp {jtag_axil/Data xdma/M_AXI_LITE}` loop and carries that flag
   because it goes to two named masters. `SEG_SPACE` has said
   `"eng": "BAR",  # both s_axi and s_axix` all along; **only one of the two
   was ever covered.** Two further facts had to be handled: one segment may
   hold two legitimate addresses in two masters' spaces, so only HOST-master
   assignments belong in a check about what the host sees; and the master is
   the Tcl variable `$sp`, so the enclosing `foreach` binding is tracked.
3. **The tie-off teeth graded the wrong configuration**, VOIDing on a missing
   engine-only anchor.
4. **And the VOID was hiding the worst one: `check_seam_tieoff`'s verdict was
   a property of the caller's shell.** D's presence came from `CARD_ON`, read
   from the environment at import. MEASURED, same card-on file, same bytes:
   **`FK33_CARD` unset REFUSES the shipping file and ACCEPTS a re-added
   tie-off; `FK33_CARD=1` does the exact opposite.** Generation never saw it
   because there the environment and the text always agree. Now derived from
   the TEXT, and the card-on invariant is graded rather than skipped
   (C0 accepted, C1 refused).

**MEASURED after: A1-A8 refused, A0/A9/A10/A11 accepted, MAP ALONE=4,
NEITHER=0, `sim:runguard` PASS.** CONTROL on the real engine-only file from
`1380dbf`: old and new identical, 10 BAR rows, both accepted, under both
environment settings. The guard was correct for the configuration it was
written against and went blind exactly when the card arrived.

**THE LESSON, and it is the sharpest one in this file: a VOID is not a neutral
outcome.** VOID is correctly not a pass here, but it also STOPS THE TEST, and
everything downstream goes ungraded. **Three of the four defects were
downstream of a check that aborted early.** When a selftest reports VOID, ask
what it did NOT get to run, not only why it stopped.

Also fixed: `tb_fk33_seam` still pinned `CAPS_FLAGS=5` after the sampler bit
was cleared, feeding the mismatch into its P4 readback counter. My own
regression, caught by the gate.

**BASELINE_PASS STAYS AT 130.** The gate refuses the raise in its own words:
this tree has 22 rows a clean checkout does not get, so `PASS 137` is not a
clean-checkout floor and raising to it would be unreachable after a clone.

**VERIFIED GREEN.** A clean full gate at `64c7f3a`, started after every edit
landed (an earlier run was DISCARDED because `gen_pcieep.py` was edited while
it ran, and an overlapped run proves nothing about either version):

```
PASS  sim:tb_fk33_seam   54s        PASS -- a whole token ran with llama
PASS  sim:runguard        0s        SELFTEST PASS
suite sim  PASS 113  FAIL 0  NOVERDICT 0
suite tb   PASS  26  FAIL 0  NOVERDICT 0      139 passing, 0 failing
```

No peak figure for that run: the cgroup is removed when the unit exits, so
`memory.peak` read 0. That is an absent measurement, not a small one.

Write-ups: `docs/debugging/2026-09-11_the-guard-that-was-blind-to-a-real-bar-page.md`
(with a same-day CORRECTION appended for defect 4).

### 2026-09-11 (earlier): THE WALL IS AFTER ELABORATION, AND NOTHING IS HUNG

**RTL elaboration of the card COMPLETES. The standing claim that card builds
stall in `synth_design` RTL Elaboration is WITHDRAWN.** MEASURED on `cardooc`
(OOC `fk33_card`, shipping config, `flatten_hierarchy=none`): the log's last
three lines are `done synthesizing module` for `attn_block`, then
`fk33_llama_top`, then **`fk33_card` itself, the top**. What follows is a
silent single-threaded phase that prints nothing at all.

**And it is not hung. It is computing at 101% of one core**, measured 36
minutes into that phase with the log byte-frozen the whole time
(`utime+stime` delta 3,000 ticks in 30 s; RSS 9,526 MB). `wchan` reads
`futex_wait_queue` on the process leader and would have told you the opposite,
because the leader waits while a worker thread does the work. **`wchan` alone
is the wrong liveness test here.**

**This reframes every previous card attempt.** Three runs show the identical
two-phase-line signature and each was stopped or abandoned, not observed to
fail: `cardbb` 09-10 stopped at 121 min with no DCP (37 modules), `cardooc`
09-09 abandoned (60 modules), `cardooc` 09-11 still running (**90 modules,
top reached**). Attempt 12's "elaboration exceeds 6 h" is the same phase,
mis-named. **No card build has ever been allowed to run this phase to
completion**, so whether it terminates is now THE open question, and the
per-subsystem fallback should not be chosen until it is answered.

Do not kill a card build on the strength of a frozen log again. Read the last
module NAME, not the count, and measure CPU over a wall-clock interval.

Two traps, both mine: I read a rising module count as progress into those
modules when it was completion of them, and I asserted my own monitor's stop
rule was "the biggest threat" to the run when reading it back shows it only
`exit 0`s the observer and never touches the job.

Full write-up:
`docs/debugging/2026-09-11_the-wall-is-after-elaboration-not-in-it.md`

### 2026-09-11 (earlier): THE CARD WAS BUILDING SUBSYSTEM C AS A STUB

**The card could not have run inference, whatever happened to synthesis.**
`hw/fk33/rtl/fk33_card.vhd` passed twelve generics and **`C_REAL` was not one
of them**, so the default `false` applied and the card elaborated
`gc : if not C_REAL generate` -- a three-state stub FSM -- instead of `gcr`,
**where `attn_block` AND `attn_kv_axi` both live**. `fk33_llama_top`
instantiates `attn_block` exactly once, at `:5893`, inside `gcr`.

`docs/PLAN_TO_FIRST_INFERENCE.md:236` required `C_REAL`, `C_KV_AXI`,
`NORM_REAL` and `B_SRC_REAL` all true. The card passed `C_KV_AXI` and **none of
the other three**.

Three consequences, each independently checkable: there was no attention on the
card; the five KV generics were **inert**, being consumed inside `gcr`; and
`gkvtie : if not (C_REAL and C_KV_AXI) generate` **tied the `kv0`/`kv1` AXI
ports off**, despite the block design wiring them through a grant to HBM.

**THE GUARD LESSON, and it is the sharpest of the day.** `check_kv_map.py`
validated all six KV generics, had no notion of `C_REAL`, and reported 23 green
rows -- and this dispatcher ADDED rows to that checker two days ago without
noticing the generics were inert. **A checker comparing two descriptions of a
thing cannot tell you whether the thing is built.**

**FIXED (`34a9ce1`):** the card now passes `C_REAL=true`, `NORM_REAL=true` and
`C_N_ROT=64`. `B_SRC_REAL` stays false deliberately -- PLAN STEP 3b records it
"has never executed past token 0 anywhere in this repository" and it needs a
conv tap history buffer that does not exist. That is new RTL, not a generic.

**ONE DEFECT SHAPE, HIT THREE TIMES TODAY.** A generic whose declared DEFAULT is
the SIMULATION value, which therefore looks conservative and is wrong for the
card:

| generic | default | card needs | how it was caught |
|---|---|---|---|
| `C_KV_BLOCK` | 4 | 32 | my own error; an out-of-range `natural` would have caught it hours into synthesis |
| `C_REAL` | false | true | reading the ARTIFACT's generic map against the plan |
| `C_N_ROT` | 8 | 64 | asking what the GENERATED RoPE table wants |

`C_N_ROT` is the subtle one: `attn_block` asserts only `N_ROT mod 2 = 0 and
N_ROT <= HEAD_DIM`, so 8 is LEGAL at HEAD_DIM 256. It raises nothing, indexes 4
of the table's 32 entries, and rotates the wrong number of dimensions.
**Now guarded twice** (`8b2aeac`): `realshape_gate.sh`'s `real_card_nrot`
elaborates it (rc=0, 1.27 GB, 1.37 s), and `check_kv_map.py` pins it to
`2*IMROPE_NPAIR` so regenerating the table moves the requirement.

**MEASURED, and it closes a gap in the fit answer.** `attn_kv_axi` at the
card's own geometry: **33,259 LUT, 20,653 FF, 0 BRAM, 0 URAM**. Its only
previous run used `MAXCTX=2048` and its own header says not to quote that as
the card's. A control at 2048 gives 32,483 LUT, so **a 64x context increase
costs 2.4% more LUT** -- the harness's "should be small" prediction was right
and my suspicion that context drove the wall was WRONG.
Neither `attn_kv_axi` nor `gdn_state_store` (4,028 LUT, 32 URAM288, 12 RAMB36)
is in `compose4_top`, which is where the project's "does it fit" answer comes
from, so **that answer understates the card by ~37,000 LUT plus 32 URAM and 12
BRAM and should be re-derived rather than quoted.**

**THE WALL HAS A NAME: `synth_design` RTL Elaboration.** `grep -c 'Finished RTL
Elaboration'` is **zero across every surviving log**, twelve attempts, two
machines. And every one of those ran with C STUBBED, so the wall exists WITHOUT
the real C. `cardreal` is the first build of the configuration that could
actually run the model; at 30 min it is at 23.5 GiB against a 26 GiB cap, above
`card13`'s 23.1 GiB plateau, as expected.

### 2026-09-11 (earlier): THE BUILD REPORTED FAILURE AT 02:10 AND KEPT RUNNING

**Attempt 12 (`cardfull`) did not finish and had already failed.** The parent
Vivado hit the 360-minute `FK33_SYNTH_MAX_MIN` bound at 02:10:47,
`fk33_assert_run_done` raised, and it exited. **The run it had launched was
still going at 06:00** -- 9 h 52 m old, 588 CPU-minutes, 5.0 cores busy,
holding 19.4 GB. `launch_runs` detaches; the parent's `error` does not reach
the child. **A build script's failure is not evidence that the build stopped.**
Fourth recorded instance of a harness reporting a fact about the harness.

**`HOST_WINDOW => false` IS genuinely in the build and did NOT clear the
wall.** Verified against the thing being built, not the repo: no copy of
`fk33_card.vhd` exists under `BUILD_ROOT`, `build_fk33_pcieep.tcl:256` adds the
repo path directly, and `create_bd_cell -type module -reference fk33_card` is a
module reference rather than a packaged IP. Necessary, not sufficient.

**MEASURED AND REJECTED: the memory cap was NOT the constraint.** I raised it
live 22 -> 28 GiB predicting memory would climb. PSI `full avg60` fell 0.10 ->
0.00, so the cap was causing real pressure -- and `memory.current` moved
**0.10 GiB in fifteen minutes**, with cores busy falling 5.0 -> 1.0 and
`runme.log` still untouched since 20:11. The job does not want more than
~22 GiB. **Do not raise the cap again expecting progress.**
The cap itself had been derived from `llama-server` holding 18 GB. That service
went down overnight and nothing revisited the number, so **a cap derived from
another process's footprint outlived its premise.**

**THE A-ONLY BITSTREAM WAS DESTROYED, and the hole is now closed.** 22,095,214
bytes, md5 `7203f6ddc20eae762e91c1261a72acf3`, 0 errors, wiped when `cardfull`
recreated `BUILD_ROOT`. `pcieep_build.sh` only *printed* "Next:
./save_bitstream.sh". It now copies unconditionally to `bit/autosave/` under a
timestamped name that never overwrites (`f0bed60`).
**The first draft of that fix was itself broken and looked fine:** line 72
`cd`s into `BUILD_ROOT` and never returns, so `$PWD` at the end IS the doomed
directory. Both forms print an identical healthy `FK33_AUTOSAVE ... md5 ...`
line; only a mutant built from the script's real `cd` sequence separated them
(fixed 1 file in the surviving tree, mutant 0). My own teeth test supplied
`PWD` and could not have caught it.

**Equivalent bitstreams survive and the hardware test is NOT blocked:**
`bit/fk33_pcieep_eng_epr_wns+0p001.bit` (21,647,330 B, WNS +0.001) and
`bit/fk33_i2cprobe.bit`, which `pcieep.sh` needs for the VCCINT step.

**IN FLIGHT: attempt 13 (`card13`), launched 07:29.** Three changes, not a
repeat: `FK33_SYNTH_MAX_MIN=1200` so the parent cannot declare failure before
elaboration can finish (12 proved it exceeds 6 h); `MemoryMax=26G` sized to the
box as it now is; and the autosave, so anything it produces survives.
Branches, written before the result: **clears elaboration** -> let it run to a
bitstream, then `save_bitstream.sh` and program the card. **Hits the wall
again** -> stop treating one-piece card synthesis as viable; go per-subsystem
(B 221.4 MHz, C 239.5 MHz, 3-4 min each) and compose at implementation.
**Dies on memory** -> the stop rule fires first; re-measure, do not re-cap.

Full write-up, incl. the procedure and every rejected hypothesis:
`docs/debugging/2026-09-11_the-orphaned-run-and-the-cap-that-was-not-the-constraint.md`

### 2026-09-10: B AND C ARE FINE, THE CARD TOP IS THE WALL, AND INFERENCE RUNS

**Inference is DEMONSTRATED end to end.** `server/llama_server` rebuilt from the
current tree, serving `:8000`: `/v1/models`, `/v1/completions`,
`/v1/chat/completions` non-streaming AND streaming (27 SSE chunks, `[DONE]`).
Three server gate rows green (`PASS 3`, read off `OVERALL PASS n`, not the
verdict). Greedy output at temperature 0, which the model card states is
hardware-exact against the AXU3EG VHDL engine.
**Be precise: the backend reports `cpu`.** It is the bit-exact fixed-point
reference path, NOT the FK33. Card-backed inference still needs a bitstream.

**B AND C EACH SYNTHESISE IN MINUTES AND EACH MEETS 200 MHz** -- measured for
the first time:

| unit | wall | LUT | FF | DSP | BRAM | WNS | fmax |
|---|---|---|---|---|---|---|---|
| `gdn_block` (B) | 3 min | 75,246 | 52,203 | 253 | 43 | +0.483 | **221.4 MHz** |
| `attn_block` (C) | 4 min | 87,340 | 101,319 | 298 | 11 | +0.825 | **239.5 MHz** |

Seven minutes for both, against ~40 hours of whole-card attempts that produced
nothing.

**THE PER-SUBSYSTEM SPLIT IS TRIED AND REFUTED.** Black-boxing B and C moves
the wall from elaboration into optimisation rather than removing it: the card
top with both stubbed hit a 120-minute ceiling, no sentinel, no `.dcp`,
0 errors. **So B and C are not what makes the card intractable** -- the card
top itself is. Unlike every earlier stall this one is NOT the message cap:
`[Common 17-14]` appears **0** times.

**A TRAP THAT NEARLY PRODUCED A FALSE ROOT CAUSE.** The first black-box run
targeted `llama_top`, not `fk33_llama_top`. `tools/gen_cardtop.py`'s D3
transform replaces `llama_top`'s flat `NREGION*REGMAX` array with a
`region_mem` instance, so the card top has **0** occurrences and `llama_top`
has **1**. Against `llama_top` it failed in 6 minutes with
`[Synth 8-3391] Failed to dissolve the memory into bits (2752512)` -- which
looks exactly like the answer to a 40-hour wall, is real for `llama_top`, and
is IRRELEVANT to the card. Only asking which top the harness actually targets
caught it. Same shape as the recorded stale-table failure.

**VHDL DOES NOT INFER BLACK BOXES.** A missing unit is
`[Synth 8-5826] no such design unit`, because `entity work.X` is a DIRECT
BINDING; that is a Verilog behaviour. A stub entity with
`attribute black_box of <arch> : architecture is "yes"` is required. Worth
knowing before designing any DCP flow over VHDL sources.

**`region_mem` could NOT be probed** and is the remaining prime suspect: it has
an unconstrained array generic `SZ` (the per-region size table) and an array
aggregate cannot be passed as `-generic`
(`[Synth 8-78]` / `[Synth 8-318]`). It needs a small sizing wrapper -- minutes,
against the two hours every card-level test costs. That is the cheapest next
measurement.

**A-only bitstream building now** (`aonly2`, 20G cap). The card-free
configuration is the one path on this box documented to reach
`write_bitstream`, and the seam contract v2 explicitly supports a card without
D. **The first attempt was OOM-killed by MY cap**: 14G chosen from the
documented 10.66 GB with no margin, 21,699 throttle events, killed at 12:21:22.
The card-free build defaults to `-jobs 4` / `maxThreads 8` -- far more parallel
workers than the card build's ONE -- so 10.66 GB was never the number to size
against. Contained to its own cgroup; the box was never at risk.

**Next, branched before the answer:**
- `aonly2` completes -> a real bitstream exists; then wire card-backed inference
  behind the v2 seam contract.
- `aonly2` fails -> the A-only path is also blocked and the honest position is
  that this design does not build on this box without restructuring.
- Either way the card wall needs `region_mem` probed via a sizing wrapper before
  any further whole-card attempt.


### 2026-09-09 (LATEST): THE CARD WAS NEVER 9B. NINE HOURS OF VIVADO FITTING A STAND-IN.

**`hw/fk33/gen_fk33_card.py` set SIX generics and none of the KV geometry**, so
every card build instantiated `rtl/fk33_llama_top.vhd`'s defaults: `C_MAXPOS`
**4** against 131072, `C_CTXLEN` **1**, `C_K_BASE_CH` **1** against 282598912,
`C_V_BASE_CH` **254** against 353902080, `C_KV_ADDR_W` **16** against 33. A
four-position KV cache with a context length of one.

**It was reported twenty times and nothing branched on it.** `[BD 41-2383]
Width mismatch ... '/card/kv0_araddr'(16) - Only lower order bits will be
connected`. The build gates on `^ERROR`; a CRITICAL WARNING is not one. So a
silent 17-bit truncation of C's whole KV address path passed every gate, and
the bitstream would have built, run, and addressed the low 64 KiB of HBM for
every head of every layer.

**A SECOND instance in the same log:** `fk33_seam` also took its defaults
(`REGMAX` 4096 / `HADDR_W` 12) against the card's 12,288-element region needing
14 bits, so host registers 4096..12287 were unreachable.

**FIXED AND VERIFIED, 20 -> 4 -> 0.** `--bd-only` after the KV generics: 4
mismatches, 0 errors. After `CONFIG.REGMAX 12288` / `CONFIG.HADDR_W 14`: **0
mismatches, 0 errors**, with `FK33_SEAM REGMAX=12288 HADDR_W=14` confirming the
property took. Each step attributable to one change.

**WHY `check_kv_map.py` WAS GREEN THE WHOLE TIME, and this is the reusable
part.** All 16 rows passed, including `C_KV_ADDR_W - 4 >= clog2(top chunk)` at
ZERO slack. It validates the KVR block in `sim/realshape_gate.sh` against the
HBM manifest and **never reads `gen_fk33_card.py`**. The guard was not weak and
not wrong -- it was correct, rigorous, and **checking a different artifact than
the one that ships**. That is the "guard that passes for the wrong reason"
class one level up: a checker over the SIMULATION configuration says nothing
about the HARDWARE configuration unless something asserts the two are equal.
It is also referenced nowhere in `sim/regress.sh`, only in `realshape_gate.sh`
-- the recorded "a script nothing schedules" pattern as well.

It now has a fourth side comparing each generic in `gen_fk33_card.py` against
the already-manifest-checked KVR value. Teeth, against the ACTUAL pre-fix file
from `git show HEAD:`: control 0 refusals, pre-fix file **5**, and
`C_KV_ADDR_W` 33->32 **1** -- that last being the state the "does it set it"
row cannot catch, and not an arbitrary mutant but `realshape_gate.sh`'s own
known-bad `real_kv_addr_short` value.

**THE MEMORY WORK IS INVALIDATED.** cardbuild8/9/10 -- about nine hours of
Vivado, three stop-rule trips and a long argument about a 24 GB ceiling -- were
fitting the stand-in. **22.40, 23.18 and 24.00 GB are not quotable for the 9B
card in either direction.** The check that would have settled it,
`grep -c '"--generic"'`, costs one second and was never run. The 22.40 GB
lower-bound correction from earlier today stands but is now moot.

**`cardbuild11` is the first build of the actual 9B design**, cap 24G, flatten
`none`, swap baseline 4,210 MB. Its memory requirement is UNKNOWN and could go
either way: wider addresses and 18-bit positions cost something, but the KV
storage was already in HBM so nothing large moved on-chip.

**Next, branched before the answer:**
- completes -> first real bitstream; run the full gate once the box is free.
- stops at the cap -> the geometry is now correct, so trimming `C_KV_BLOCK`
  32->16 or adding RAM are the levers, and for the first time those would be
  decisions about the real design.

**Open:** nothing enumerates which OTHER BD cells are instantiated with
defaults. Two were found by reading one log, and the same failure mode looks
identical everywhere. `[BD 41-2383]` is still ungated; every instance found
today was a genuine defect.


### 2026-09-09: cardbuild9 is in silent global elaboration; the length guard now has teeth

**The card build.** `cardbuild9` (`FK33_CARD=1 bash pcieep_build.sh` under
`systemd-run --user -p MemoryMax=24G`) started 23:13:51 and at 52 min is at
**19.87 GB, climbing ~48 MB/min**, `memory.events` all zero (`low 0 high 0
max 0 oom 0`), swap **3474 MB against a 3479 MB baseline** (i.e. below it),
available 6.4 GB. Its `runme.log` has been static at 23:17:25 for 49 minutes.

**That silence is not a hang, and this is how it was established** rather than
assumed: two Vivado workers identified via `/proc/PID/exe` are each burning
101 ticks/s (1.01 core), which is exactly the `general.maxThreads 2` this
configuration sets, and one worker's RSS grows ~12 MB per 15 s. Global
synthesis (`synth_checkpoint_mode None`) elaborates the whole PCIe/GT IP set
plus the 48 card sources in one pass and prints nothing while doing it. **A
buffered-looking log plus live CPU is the third recorded form of "the harness
is reporting a fact about the harness"**; the kernel's view of the process is
what settles it.

Stop rule in force, unchanged: oomd fires, OR swap grows >500 MB from the
3479 MB baseline, OR available <2 GB. A watcher is armed on those conditions
rather than polled by hand.

**THE FULL GATE IS DELIBERATELY NOT RUNNING, and here is the arithmetic.**
Available 6,403 MB now; cardbuild8 peaked at 22.40 GB unthrottled so this run
should take ~2,530 MB more; the recorded full-gate peak at `--jobs 1` is
2,181 MB. That leaves **1,678 MB at coincident peak, below the 2,000 MB stop
threshold**, so the gate waits for the build instead of running beside it.
Only the one affected bench was run, and it exited before this was written.
The gate is owed as soon as `cardbuild9` ends, whichever way it ends.

**`err_len_ovf` now actually tests its threshold** (`8abe9f7`, doc
`docs/debugging/2026-09-09_the-length-guard-was-checked-by-never-firing-it.md`).
It had been in the verdict only as "must stay '0'", and the bench's own
traffic never exceeds 4 beats against a 16-beat cap, so that term passed
identically against a guard tied to '0'. A directed phase on a SECOND DUT
instance (needed because `b_arlen`/`c_arlen` already have drivers) now drives
all five sources at 15, 16 and 32 beats plus a sticky-after-withdrawal check:
17 checks, six mutants, all killed.

**The attribution control came out unusually clean and is the point.** In all
six mutant runs every pre-existing verdict term holds -- misdeliveries 0,
`err_switch_busy` '0', `err_len_ovf` '0', switches 7619, reads 5142, writes
3352, all four per-port counters non-zero -- so the old bench returns PASS on
all six and the new phase is the sole detector for every one. Those counters
are also byte-identical to the reference run, so the added instance perturbs
nothing.

**The resolution floor was measured before it was closed, not guessed.** The
first version used 15 and 16 only, 12 checks. A mutant testing
`axlen(MLEN_W)` instead of the whole upper nibble -- which catches 16..31 and
passes 32 silently -- **PASSED that version**. The five 32-beat cases exist to
close a demonstrated hole; do not trim them as redundant.

`rtl/bc_port_grant.vhd` was NOT edited: every mutant was a copy in scratch,
confirmed by `git diff --quiet`, which matters because a card synthesis was
reading that file at the time.

**Next, branched before the answer:**
- cardbuild9 completes synthesis -> let it run on into implementation and
  `write_bitstream`; run the full gate once the box is free.
- cardbuild9 hits the cap or the stop rule -> the decision already put to Oren
  stands: add RAM (2 free DIMM slots, 2 x 32 GB preferred over filling four),
  or trim the card geometry for a first bitstream (smaller `C_KV_BLOCK`, fewer
  `A_ROWS_IF`, or B omitted).

**Still open, and unchanged by the above:** `err_switch_busy` and
`err_len_ovf` are sticky outputs that **nothing reads**. The work above shows
the guard fires correctly; it does not make anyone able to hear it. Wiring
them is an RTL change and would invalidate a build that is currently running,
so it is queued behind the bitstream rather than done now.


### 2026-09-05 (latest): THE REAL BASELINE IS -0.637, AND "DIRECTIVES LOSE" IS REFUTED

Three composed runs, **all routes clean**, all on ONE netlist
(`bram=253.5 dsp=2177`; the KV=4 cell is `dsp=1953`). Full writeup:
`docs/debugging/2026-09-05_the-composed-baseline-and-what-directives-are-worth.md`.

| run | KV | directives | routed WNS | fmax |
|---|---|---|---|---|
| `c4base` | 32 | **all four empty** | **-0.637** | 177.4 MHz |
| **`c4nd`** | 32 | `''`/`ExtraNetDelay_high`/`AggressiveExplore`/`NoTimingRelaxation` | **-0.422** | **184.4 MHz** |
| `c4kv4c` | **4** | *(same as `c4nd`)* | -1.731 | 148.6 MHz |

**Two controlled one-variable results now stand on the same netlist:**
**directives are worth +0.215 ns**, and **`KV_BLOCK` 32 -> 4 costs 1.309 ns.**

**"Directives lose" is REFUTED.** That verdict came from comparing `c4nd`'s
-0.422 against `impl_pb`'s -0.402, a run whose artifacts do not exist.
**Best reproducible composed figure: -0.422 (184.4 MHz). Distance to 200 MHz:
0.422 ns.**

**DIRECTIVES MOVE THE CONGESTION; `KV_BLOCK` DOES NOT.**

| run | South | East | North | West |
|---|---|---|---|---|
| `c4base` (none) | **L6** | L6 | **L6** | *(no row)* |
| `c4nd` (directives) | **L5** | L6 | **L5** | L5 |
| `c4kv4c` (directives, KV=4) | L5 | L6 | L5 | L5 |

`ExtraNetDelay_high` placement drops South and North a full level. Cutting
`u_arr`'s DSPs 8x drops nothing. **First positive evidence since the DSP-density
hypothesis died: the congestion responds to PLACEMENT, not to how much
arithmetic sits in the congested block.** Any further work shrinking `c_attn` to
relieve congestion is aimed at the wrong variable, measured twice now.

**THE WITHDRAWN -0.402 IS QUANTITATIVELY SUSPICIOUS.** It claimed -0.402 with
directives empty; the current tree measures **-0.637** under the same
conditions. So the vanished baseline was **0.235 ns BETTER** than anything
reproducible today. Either **the design regressed 0.235 ns in a day and nothing
detected it**, or `impl_pb` was a different netlist. Artifacts are gone, so
neither can be checked. The new `C4_TIMING` fingerprint makes this ambiguity
impossible in future.

**TOOLING FIX LANDED AND PROVED ITSELF ON ITS FIRST RUN.** `C4_TIMING` now
carries `bram`, `dsp`, `lut` and the directives on the verdict line.
Confirming `c4base` shares `c4nd`'s netlist took **one grep** instead of the
cross-referencing that had already failed four times. Teeth-tested in `tclsh`
across five states; the legacy regex still matches. The Tcl's instruction to
compare against the unrecoverable -0.402 is retired.

**IN FLIGHT: `c4ewr`** completes a 2x2. The `ExploreWithRemap`/`ExtraTimingOpt`/
`AggressiveExplore`/`Explore` set is **0.189 ns better at KV=4** and has never
been run at KV=32. If that carries over, the composed design lands near -0.233
and the gap to 200 MHz roughly halves. Four cells also allow the directive and
`KV_BLOCK` effects to be checked for **additivity** rather than assumed; three
cells cannot detect an interaction.

### (superseded) CONTROLLED. KV_BLOCK=4 COSTS 1.309 ns AND THE CONGESTION HYPOTHESIS IS DEAD

**`c4kv4c` landed: the FIRST controlled composed timing comparison in this
project.** Identical directives, identical tree, same KV=4 synthesis DCP, both
routes clean, only `KV_BLOCK` differs.

| | `c4nd` KV=32 | `c4kv4c` KV=4 | delta |
|---|---|---|---|
| **routed WNS** | **-0.422** | **-1.731** | **-1.309** |
| **achieved** | **184.4 MHz** | **148.6 MHz** | **-35.8 MHz** |
| LUT | 263,544 | 249,376 | -14,168 |
| DSP | 2,177 | 1,953 | -224 |
| CLB sites | 49,620 (90.3%) | 46,770 (**85.1%**) | -2,850 |
| routed nets | 3,535,996 | 3,264,841 | -271,155 |
| F8 mux | 3,961 | 8,425 | **+113%** |

**HEADLINE REINSTATED, WITH A BIGGER NUMBER.** The withdrawn confounded figure
was 1.120; the true cost is **1.309**, because the confound was *masking* part
of it -- the other directive set is **0.189 ns BETTER at KV=4** (-1.542 against
-1.731). **Running the control changed the number, in the unflattering
direction. A confound is not noise that averages out.**

**THE CONGESTION HYPOTHESIS IS REFUTED, properly this time.** Controlled, the
maximum routed congestion level is **IDENTICAL in all four directions** (South
5, East 6, North 5, West 5) while `u_arr`'s DSPs fell **8x**, 14,168 LUT and
**271,155 routed nets** left the design, and CLB occupancy dropped 5.2 points.
`u_arr`'s DSP density is not what drives the Level 5/6 windows.

**And the confounded run was directionally WRONG, not merely unattributable.**
It showed South going 5 -> 6, written up as "congestion got worse"; controlled,
congestion does not move at all and the 5 -> 6 belonged to the *directive*
change. "Confounded" is usually heard as "real effect, uncertain size". Here the
**sign** of the observed change was an artifact.

**Fourth measured case of phys_opt over-promising, and the largest:** -1.123
phys_opt against -1.731 routed, **0.608 ns** given back. Four cases now span
0.428 to 0.633 and **not one was optimistic in the routed direction**.

**THE DECISION IS NOW PRICED.** `KV_BLOCK = 4` buys **5.2 points of CLB
headroom and 224 DSP**, and costs **35.8 MHz**. `rtl/attn_block.vhd:223` and
`rtl/llama_top.vhd:479` cite the same spec clause 2.1.1 with 32 against 4 and
nothing checks that they agree. **Which value the model requires is Oren's
call.**

**Still open:** what actually drives the Level 5/6 congestion -- DSP density is
eliminated and **nothing has replaced it**; and the composed baseline with all
directives empty on the current tree, which no surviving run establishes (see
`docs/debugging/2026-09-05_the-composed-timing-record-is-not-comparable.md`).

### (superseded, kept for the method) THE KV_BLOCK EXPERIMENT WAS NOT CONTROLLED.

**Read this before the entry below it, which is partly withdrawn.**

`c4nd` and `c4kv4` differ in **five** things, not one. Per each run's own
`C4_DIRECTIVES` sentinel and each run's `run.sh`:

| run | KV_BLOCK | opt | place | phys_opt | route | routed |
|---|---|---|---|---|---|---|
| `c4nd` | 32 | *(none)* | `ExtraNetDelay_high` | `AggressiveExplore` | `NoTimingRelaxation` | -0.422 |
| `c4kv4` | **4** | **`ExploreWithRemap`** | **`ExtraTimingOpt`** | `AggressiveExplore` | **`Explore`** | -1.542 |

**WITHDRAWN:** the 1.120 ns; "KV_BLOCK=4 costs 1.120 ns"; **the refutation of
the congestion hypothesis** (congestion is a placement and routing outcome and
all four directives changed, so that hypothesis is **untested, not refuted**);
the critical-path move; the routed CLB figure.

**SURVIVES: everything at synthesis**, because synthesis does not read
implementation directives, and both runs' synthesis hierarchies confirm it --
`a_eng` **92,134 LUT in both to the digit**, `d_norm` **5,017 in both**. So
**-14,383 LUT** and **-224 DSP** (exactly `2*G*KV_BLOCK`), `u_arr` 57,927 ->
39,905, and F8 muxes **+113%** all stand. **KV_BLOCK=4 is a real area saving of
known size; its timing cost is not established.**

**CONTROL RUNNING: `c4kv4c`** -- the same KV=4 synthesis DCP re-implemented with
`c4nd`'s exact directives, so the pair differs only in `KV_BLOCK`. Synthesis is
not re-run because it cannot differ.

**What this cost, named plainly.** I wrote the "attributed to the mechanism
being discussed rather than to the uncontrolled variable" entry into `CLAUDE.md`
this morning, and then made the same error within the hour **in the document
announcing the first one**. The area controls (`a_eng`, `d_norm` unmoving to the
digit) are genuinely good controls -- **on the wrong axis**. They prove
synthesis was identical, which is why the area survives, and say nothing about
implementation. A well-chosen control on one axis reads as rigour and disguises
the missing one. Both `C4_DIRECTIVES` lines sat in the logs the whole time; the
comparison was made from memory of what the run was *for*.

**Rule: enumerate what differs between two runs from the runs' own recorded
parameters, never from the intent of whoever launched them.**

### (partly WITHDRAWN, see above) KV_BLOCK=4 COSTS 1.120 ns

**`c4kv4` landed. Both routes clean** (`nets=3264259 errors=0 unrouted=0
partial=0`). Full writeup:
`docs/debugging/2026-09-05_kv-block-4-is-a-cost-not-a-lever.md`.

| | `c4nd` KV=32 | `c4kv4` KV=4 | delta |
|---|---|---|---|
| **routed WNS** | **-0.422** | **-1.542** | **-1.120** |
| achieved | **184.4 MHz** | **152.9 MHz** | -31.5 MHz |
| LUT | 263,544 | 248,727 | -14,817 |
| DSP | 2,177 | 1,953 | -224 |
| CLB sites | 49,620 (90.3%) | 46,706 (**85.0%**) | -2,914 |
| F8 mux | 3,961 | 8,425 | **+113%** |

**`KV_BLOCK = 4` is a COST, not a lever. `compose4_top`'s accidental 32 has been
FLATTERING every composed number on record.** If 4 is the correct spec value,
the real distance to 200 MHz is **1.542 ns**, the worst composed figure ever
measured here.

**Clean isolation:** `a_eng` 92,134 LUT in both runs to the digit, `d_norm`
5,017 in both, `b_gdn` differs by 3. Every change is inside `c_attn`.

**MY CONGESTION HYPOTHESIS IS REFUTED.** The doc from earlier today argued
`u_arr`'s DSP density caused the composed context penalty, on the evidence of
100% DSP occupancy in the windows `u_arr` owns. DSP in `u_arr` fell **8x**
(256 -> 32, exactly `2*G*KV_BLOCK`), CLB occupancy fell 5.3 points, 14,817 LUT
left the design, and **routed congestion got WORSE**: South Level 5 -> **6**,
East 6 -> 6. DSP density was *correlated* with the congested windows, not
causal. **What drives them is now OPEN with no candidate measured**, which is a
worse position than that doc claimed and the true one. The prediction was
registered in `fa92069` **before** the run, which is why one experiment settled
it instead of the story surviving indefinitely.

**Why timing got worse:** the critical path MOVED OUT of the array. At KV=32 it
is `c_attn/u_arr/p_reg_reg -> u_arr/er_r_reg`; at KV=4 it is
`c_attn/vhdr_reg -> c_attn/vref_r_reg`. `u_arr` gives up 18,022 LUT but `c_attn`
only 14,380, because ~3,642 LUT and ~2,051 FF reappear around it as deeper
muxing. A narrower array does the same work in more steps.

**Third measured case of phys_opt over-promising:** -1.004 phys_opt against
-1.542 routed, 0.538 ns given back. `c4nd` gave back 0.428. Quoting phys_opt
would have made `c4nd` read as *meeting* 200 MHz.

**DECISION FOR OREN, and it is no longer cosmetic.** `rtl/attn_block.vhd:223`
and `rtl/llama_top.vhd:479` both cite spec clause 2.1.1 with different
`KV_BLOCK` values, 32 against 4, and **nothing checks that they agree**. The
disagreement is now measured at **31.5 MHz against 5.3 points of device
occupancy**. Which value the model requires is a spec question, not a tools one.

### 2026-09-05 THE FULL DESIGN FITS, BUT CLB OCCUPANCY IS THE CONSTRAINT

**Nobody had asked whether shell + A + B + C + D physically fits on the
xcvu33p.** The bitstream goal has been pursued as a timing problem for weeks
while the shipping bitstream holds shell + subsystem A only.

MEASURED, all same-stage (physopt postRoute for the shell path, routed for the
composed top). Full writeup and the do-not-retry list in
`docs/debugging/2026-09-05_does-the-full-design-fit-on-the-card.md`.

| resource | shell | A+B+C+D | TOTAL | device | % |
|---|---|---|---|---|---|
| LUT  | 50,999 | 263,544 | 314,543 | 439,680 | **71.5** |
| FF   | 62,065 | 245,425 | 307,490 | 879,360 | 35.0 |
| BRAM | 69.0   | 253.5   | 322.5   | 672     | 48.0 |
| URAM | 0      | 0       | 0       | 320     | 0.0 |
| DSP  | 0      | 2,177   | 2,177   | 2,880   | **75.6** |

**It fits on every hard resource.** DSP is tightest at 75.6%, LUT next at 71.5%.

**The binding constraint is in none of those rows.** The composed design ALONE
occupies **49,620 of 54,960 CLB sites, 90.3% of the device**, at 5.31 LUT/CLB.
Fitting the total needs **5.72 LUT/CLB**, 7.7% denser than this design has ever
been packed, in a design already at congestion Level 5 in `c_attn/u_arr` and
missing 200 MHz by 0.4 ns. 71.5% LUT reads comfortable; 90.3% CLB does not.

DERIVED the shell alone by same-stage subtraction of a `-cells [get_cells
bd_i/eng]` report from the full design **in the same run**. Cross-checked that
both contexts hold the same subsystem A by the exact DSP match, 1,585 in each.

Three traps recorded as do-not-retry:

- **The 109.3% summed CLB figure is NOT a non-fit proof.** `CLB` counts occupied
  *sites*, a placement outcome, and is the one row in `report_utilization` that
  does not sum. It is still the most informative row here.
- ~~**The composed SYNTHESIS figure is 350,283 LUT against 263,544 routed**, a 25%
  over-count.~~ **WITHDRAWN same day.** That compared a week-old synthesis run
  against this week's routed run and charged a week of design change to the
  stage. Same-tree measurement: `c4nd` synth **267,202** against `c4nd` routed
  **263,544**, a stage effect of **-1.4%**. Synthesis LUT is still not a
  placement result, but not for this reason.
- Deriving the shell from a synthesis A against a placed shell+A mixes stages in
  the direction that under-states the shell.

**Consequence: `c4kv4` is not only a timing experiment.** `c_attn`'s array
carries `DSPs(u_arr) = 2*G*KV_BLOCK`, which is 256 at the composed top's
`KV_BLOCK = 32` and 32 at the design's actual `KV_BLOCK = 4`. That is 224 of the
2,177 DSP, and the LUT and CLB it takes with it land in the region owning 65-95%
of every Level 5 congestion window. **The same one-line generator gap is the
leading candidate for both the timing miss and the CLB pressure.** Read the
`clb` field of its `C4_UTIL ... routed` line alongside the WNS, not after it.

Open: whether the placer actually reaches 5.72 LUT/CLB. Nothing here measures
that, and the only way to know is to build shell + composed engine, which has
never been done.

**CORRECTION, same day: the subsystem attribution table in the debugging doc was
a week stale and is withdrawn.** It came from
`hw/fk33/results/compose4_2026-08-29/`. Against this week's tree: `d_norm` is
**5,017 LUT / 2,004 FF**, not 48,501 / 133,169 (wrong by 9.7x and 66x, so D is
**1.9%** of the design, not 13.8%); `a_eng` is **92,134**, not 134,633; the top
is **267,202**, not 350,283. **The headline fit arithmetic is unaffected**, since
it used the routed 263,544 throughout. The stale table was *internally
consistent* -- its parts summed correctly and left the same 6,376 of glue as the
correct one -- so no arithmetic check could have caught it. Only the date in the
path would have, and it was not read.

**c4kv4 SYNTH RESULT (route still running, no WNS quoted or implied):**

| | `c4nd` KV=32 | `c4kv4` KV=4 | delta |
|---|---|---|---|
| LUT | 267,202 | 252,819 | **-14,383 (-5.4%)** |
| FF | 237,905 | 239,960 | +2,055 |
| F8 mux | 3,961 | 8,425 | **+4,464 (+113%)** |
| DSP | 2,177 | 1,953 | **-224 (exactly as derived)** |

**Clean isolation:** `a_eng` is 92,134 LUT in both runs to the digit, `d_norm`
5,017 in both, `b_gdn` differs by 3 LUT. Every change is inside `c_attn`.
`u_arr` falls 57,927 to 39,905 with DSP 256 to 32, exactly the `2*G*KV_BLOCK`
prediction. But `c_attn` as a whole falls only 14,380, so ~3,642 LUT and ~2,051
FF reappear elsewhere in it and F8 muxes more than double: a narrower array
needs deeper muxing.

**The refusal to project was worth it.** Scaling `u_arr` by the 8x reduction
predicts about -50,000 LUT against a measured -18,022 in `u_arr` and -14,383
net: wrong by **3.4x**, in the flattering direction. LEVERC48 on a fresh case.

### 2026-09-05 (latest): B CAN RUN PAST TOKEN 0, AND B'S HEADLINE BLOCKER IS UNVERIFIED

**Landed (pending the clean gate's verdict at time of writing):** `llama_top`'s
causal-conv tap history was hardcoded to zeros for every tap older than the
current token, and `u_state` was instantiated with `cv_seg => 0, cv_grp => 0,
cv_x => open, tok_adv => '0'`. The state tier existed, was tested, and was
wired to nothing. Four connections and a narrowed assert fix it.

**9 of 9 R_Y seams bit-exact** against `tools/ref9b/gdn_oracle.py`, which now
fills tap history from CAPTURED per-token QKV records fetched by capture key,
never consulting the store it is checking. Discriminating control: the mutant
that keeps the hardcoded zeros scores **3 of 9**, failing exactly the tokens
where history exists.

**NOT PROTECTED BY THE GATE, and this is the honest caveat.** `B_SRC_REAL`
defaults false and no row sets it true. A row that did is **not constructible
from a clean checkout**: `B_SRC_REAL=true` fails on synthetic weights and
passes on real ones, and the real weight image is not in git. Verified
out-of-gate; regressions in this path will be silent.

**`rtl/llama_top.vhd:66-70` is now stale**: it says the default stays FALSE
"for the OTHER reason ALONE: the conv tap history". That reason is discharged.
The remaining bar is the STIMULUS, not the tap history.

### RESOLVED: B'S -4.008 REPRODUCES, THE MOVER FITS, AND THE PATH IS LOGIC DEPTH

MEASURED 2026-09-05 against the repaired extraction (`f2bbd50`).  `-4.008`
reproduces EXACTLY at both `MAXROWS` 64 and 256 -- LUT 127,260 / FF 46,279 /
BRAM 5,472 / WNS -4.008, every figure matching the 2026-09-03 record.  So the
staleness alarm below is RETIRED: the number was stale in provenance and
correct in value.

**THE MOVER FITS** with `-generic B_STATE_AXI=true`: BRAM **5,472 tiles (814%
of the device) -> 50 (7.44%)**, URAM 0 -> 32, LUT 127,260 -> 65,044, failing
endpoints **110,298 -> 858**.  Through the generic, not the text substitution.

**AND NO DIRECTIVE CAN FIX THE TIMING.**  The path is 31 logic levels,
**77.7% logic and 22.3% route**, five DSPs cascaded through PCOUT inside
`gdn_conv`.  Driving route delay to ZERO still leaves 6.739 ns against a
5.000 ns period.  That is a closed-form refutation of the entire
strategy/directive lever on this block.  It has to be pipelined.

**RESOLVED: B'S COMPUTE MEETS 200 MHz. THE 111 MHz BLOCKER WAS STIMULUS.**
Startpoints restricted to the 52,045 sequential cells inside `gb_real.u_gdn`
give **Slack (MET) +0.837 ns = 240.2 MHz**, cross-validated by the repo's own
2026-09-03 measurement of `gdn_block` ALONE at **+0.483 = 221 MHz**. Two
independent methods, both comfortably past target.

**CORRECTED SAME SESSION: that is true of the block IN ISOLATION and false of
the composed design.** `compose4_top` instantiates `gdn_block` directly with
`cv_x`/`cv_w` as top-level PORTS and carries NO hash (`function m12` occurs 0
times; constants `1103515245`/`668265261` occur 0 times), so its census is
uncontaminated and `b_gdn` genuinely fails at **-0.402 routed**.

| B measurement | result | real? |
|---|---|---|
| `gdn_block` alone / restricted startpoints | +0.483 / +0.837 | yes, MEETS |
| OOC mover total, -4.008 (111 MHz) | stimulus | **no, discard** |
| composed `b_gdn`, routed, in context | **-0.402** | **yes, THE blocker** |

**B's real problem is CONTEXT, worth 0.885 ns**, and it is SHARED: `c_attn`
-0.401, `a_eng` -0.338, `d_norm` -0.168 -- three independent subsystems within
0.064 ns, the signature of a global effect rather than four defects. Two of
B's three numbers are now known fine or fictitious, leaving ONE real target.

NOT established: the mover's OWN logic (address generation, handshakes,
buffering) is still unmeasured -- it sits in `gb_real` beside the generators,
which own all 400 worst paths. Its worst path is better than -3.226 ns and
that is all that can be said. The next measurement is a harness driving taps,
weights and scalars from registers or memory.

**CONFIRMED: B's path IS THE SYNTHETIC WEIGHT HASH, not the datapath.** The
path traverses `DSP_MULTIPLIER U[43]` and `DSP_ALU ALU_OUT[47]`; `gdn_conv`'s
MAC is 16x16 and its product is 32 bits, so **those bits are unreachable from
it**. The only wide multiplies are `m12`'s two 32x32. All 15 worst paths share
ONE startpoint fanning out to sixteen `p1_reg[t][ln]` A-inputs at constant
depth -- the signature of `m12`'s shared first argument.

So **`-4.008` / 111 MHz does not characterise the shipping design**, where conv
weights come from memory. It does NOT follow that B is fast: **B's real fmax is
UNKNOWN**. Three documents quote 111 MHz as the headline blocker; it is
measuring a test-pattern generator.

**AND compose4_top MEASURES AN EASIER C THAN WILL BE BUILT.** `llama_top:479`
passes `C_KV_BLOCK = 4` into `attn_block`; `gen_compose4_top.py` contains the
string `KV_BLOCK` **zero** times, so `compose4_top` silently takes
`attn_block`'s own default of **32**. `NBLK = HEAD_DIM/KV_BLOCK` sizes the
reduction on C's critical path. ROUTED against routed, same flow both sides:
**-1.438 at 4 (155.3 MHz) against -0.596 at 32 (178.6 MHz) = 0.842 ns**, still
20x the composed miss. (An earlier entry said 2.436 ns; that was the
SYNTHESIS-to-synthesis delta and is withdrawn.) **C misses at BOTH settings**,
so this changes how far short C is, not whether. So `c_attn -0.401` and the
best composed result **-0.041 (198.4 MHz)** are BOTH measured on a C that is
easier than the real design. A generic passed by OMISSION leaves no line to
review and no diff to notice.
(`attn_block:223` and `llama_top:479` cite the SAME spec clause 2.1.1 with
different values, 32 against 4. One is wrong; neither is checked.)

**C ATTRIBUTED for the first time, and it is the MIRROR IMAGE:**
`gcr.u_attn/vhdr_reg[0]` -> `vref_r_reg[N][6]`, 23 levels,
**logic 2.361 ns (35.8%) / route 4.232 ns (64.2%)**, seven paths at exactly
-1.611, one per head. **Route-bound, so directives ARE the right lever for C**
-- the opposite conclusion to B, and an OOC route estimate is an upper bound.

`docs/debugging/2026-09-05_b-mover-is-logic-depth-not-routing.md`.

### (superseded) B'S -4.008 ns (111 MHz) IS UNVERIFIED, NOT WRONG

`sim/ooc_gdnadapt_extract.py` has been REFUSING TO RUN since `5f1db1a`
(2026-09-03 16:20): nested generates inside `gb_real` broke a depth count whose
END pattern was pinned to a literal two-space indent. **It failed loudly and
was never heard, because nothing invoked it.** Measured body drift, attributed:

| generated file                | pre-existing at HEAD | from the tap edit |
|-------------------------------|----------------------|-------------------|
| `rtl/ooc_gdnadapt_top.vhd`    | **225**              | 106               |
| `rtl/ooc_gdnadapt_ss_top.vhd` | **60**               | 82                |

`-4.008` was measured at `e9beec9` (13:11 the same day), when the extraction
was genuinely in sync, and went stale three hours later. **It was not wrong
when taken; it stopped describing the tree.** A re-measurement against a fresh
extraction is queued as `bmover-chain.scope`, gated on Vivado PRESENCE via
`/proc/PID/exe`.

**C is NOT exposed the same way** -- measured, body drift 0. Its extractor
anchors on the block's own indentation rather than counting depth, which is
immune to nesting by construction. I asserted the parallel before measuring it
and it was false; see the CORRECTION in the debugging file.

Write-up: `docs/debugging/2026-09-05_b-mover-extraction-went-stale-unheard.md`.

### COMPOSED TOP: phys_opt reaches +0.006 PRE-ROUTE, route still running

`place=ExtraNetDelay_high / physopt=AggressiveExplore / route=NoTimingRelaxation`,
fresh synthesis from a pinned tree at HEAD. This is exactly the untried item
recorded at `2026-09-04_composed-top-routed.md:224`.

```
placed   wns -0.406   failing 147
physopt  wns  0.006   failing 0
routed   wns -0.422   failing 1066     <- clean route, 0 errors
```

**RESULT: IT LOSES. -0.422 routed = 184.4 MHz**, worse than the no-directive
baseline (185.1) and far worse than the prior best (-0.041, 198.4 MHz). 77.3
minutes. Recorded under "do not retry" in
`docs/debugging/2026-09-04_composed-top-routed.md` FOLLOW-UP 3.

**`phys_opt` reached +0.006 with ZERO failing endpoints and routing gave back
0.428 ns.** Nothing before `route_design` is a timing result on this design.

**The experiment changed THREE knobs at once** (opt, place, route) against the
prior best, so the loss cannot be attributed to `NoTimingRelaxation`, which is
the knob the open item actually named. Attribution needs three more 77-minute
runs; given the direction, spend them elsewhere.

### VOID: `compose4_top` does not contain `llama_top`

A follow-up run meant to measure the tap mux's cost in the composed top
returned **bit-identical utilization** (lut 267202, ff 237905, bram 253.5, dsp
2177 both sides). `compose4_top` instantiates `attn_block`, `fk33_engine`,
`gdn_block`, `ooc_normadapt` and the five `seq_*` units -- **`gdn_block`
directly, never `llama_top`** -- so `gb_real`, where the change lives, is not
in that design at all.

Stopped rather than finished. **Verify the change is inside the DUT before
designing the comparison**; it costs one grep of the instantiation list. Same
family as FOLLOW-UP 3's three-knobs-at-once error.

It also explains structurally why the composed top is not an inference design:
the per-unit data movers are absent by construction.

### 2026-09-05 (earlier): THE CARD BITSTREAM MEETS 200 MHz, AND IT WAS ALMOST LOST IN /tmp

**`hw/fk33/pcieep_build.sh` produced a bitstream that MEETS its 200 MHz
constraint**, built with `FK33_IMPL_STRATEGY=Performance_ExplorePostRoutePhysOpt`
(the strategy knob is new, in `gen_pcieep.py`, defaulting to the old value and
validated by readback). Re-derived from the copied reports, not from the build
log:

```
WNS(ns)  TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints   WHS(ns)
  0.001    0.000                      0               672531     0.009
All user specified timing constraints are met.
# of routable nets 286806 / fully routed 286806 / routing errors 0
```

**The artifact lived ONLY in the session scratchpad under `/tmp`.** The
write-up recorded its size and its timing and not its path;
`find hw -name '*.bit'` returned nothing newer than 2026-08-29, and it was
recovered only by searching on the byte size the document happens to quote.
Now preserved, md5-verified byte-identical:

```
hw/fk33/bit/fk33_pcieep_eng_epr_wns+0p001.bit               21,647,330  201b6206...
hw/fk33/bit/pcieep_eng_epr_2026-09-05/
    bd_wrapper_postroute_physopt.dcp                       215,948,390  e1c8af9d...
    timing_summary_postroute_physopted.rpt, route_status.rpt,
    utilization_placed.rpt, README.md
```

`hw/fk33/bit/` is gitignored (`.gitignore:134`) by design, so
`docs/debugging/2026-09-05_card-bitstream-meets-200mhz.md` is the only TRACKED
record that any of it exists. **A `git clean -x` takes it silently.**

**The `.dcp` matters more than the `.bit`.** The margin is 1 ps and no seed
sweep was run, so nothing shows the result is REPRODUCIBLE. Regenerate with
`write_bitstream` from the checkpoint; a rebuild is a gamble.

**Host software is green, and one of its recorded bugs is spent.**
`llama_server.cpp` carried a note that the FK33 arm "has been unable to open
its backend" and that `server_e2e.py` "has been reporting server never came
up". MEASURED today, both false: `server_e2e.py:195` now passes
`--desc-arena-bytes 159232`.

```
SERVER_E2E     PASS (0 failed)   6 chat cases + the tool-role refusal
SERVER_STORIES PASS (0 failed)   11 checks
gate --only srv                  OVERALL PASS 3 FAIL 0, REGRESSION: PASS
```

The note was corrected IN PLACE, not deleted: its CAUSE is still live
(`llama_server` deliberately supplies no default, because a silent default is
what `pl_open`'s refusal exists to prevent), only its consequence is spent.

**THE CONV TAP-HISTORY BLOCKER IS MUCH SMALLER THAN RECORDED.**
`llama_top.vhd:4636` sizes it as "a new `(KCONV-1) x qkv_dim` buffer". It is
not new. `rtl/gdn_state_store.vhd:45` already carries the CONV TAP HISTORY
(49,152 B), `llama_top:4232` instantiates it, and `llama_top:4258` already
connects the WRITE side from `gdn_job_seq`. The per-layer worry is answered by
the design itself (`gdn_state_store.vhd:139`): "Not per layer: every GDN layer
is visited once per token so all of them rotate in lockstep."

What actually remains is two connections, and `llama_top:4252` says so --
"one change lifts the token-1 refusal later":

- `tok_adv` is tied to `'0'`, so the rotation never advances
- `cv_x` is left `open`, so the stored taps reach nothing

**The real constraint is not storage.** `cvdata_p` produces `cv_x`, `cv_w` and
`cv_cw_exp` together and the store carries only taps, so wiring it splits one
producer in two; and the store exists only under `B_STATE_AXI`, so
`B_SRC_REAL` would stop being independent of it. **Not done, deliberately:**
that is a design decision with real blast radius, and the
`assert not (B_SRC_REAL and tok_pos > 0)` at `:4645` exists precisely to
refuse a plausible wrong number until it is taken.

**GATE GREEN, and it caught one of my own commits.** `OVERALL PASS 132
FAIL 0, REGRESSION: PASS` (floor 124; do NOT raise it, this tree has 22 rows a
clean checkout does not get and `regress.sh` says so). The first run was
`PASS 131 FAIL 1` on `sim:cardtop` -- appending a COMMENT to
`rtl/llama_top.vhd` left the generated `rtl/fk33_llama_top.vhd` stale, because
that hand-written file is a generator INPUT and nothing on it says so.
Regenerated in `14c43fb`; rule and root cause in `CLAUDE.md` and
`docs/debugging/2026-09-05_generator-input-staleness.md`.

**THE STRATEGY SWEEP LANDED, AND THE SHIPPED BITSTREAM USES THE WORST PASSING
STRATEGY.** 8 points, implementation only (synthesis reused), one Vivado.
**299 ps spread on identical RTL**, +0.096 to -0.203:

| strategy | WNS | achievable |
|---|---|---|
| **`Performance_NetDelay_high`** | **+0.096** | **203.9 MHz** |
| `Performance_ExtraTimingOpt` | +0.033 | 201.3 MHz |
| `Performance_ExploreWithRemap` | +0.0098 | 200.4 MHz |
| `Performance_ExplorePostRoutePhysOpt` **(shipped)** | +0.0009 | 200.0 MHz |
| `Performance_Explore` | -0.0066 | misses, 20 ep |
| `Performance_Retiming` / `RefinePlacement` | -0.203 | 192.2 MHz, 9,213 ep |
| `Flow_RunPostRoutePhysOpt` | -0.221 | 191.5 MHz, 5,194 ep |

**The control validated the whole sweep:** `RefinePlacement` returned
-0.203225 = **192.19 MHz**, and this file already recorded the previously
shipped bitstream at **"measured 192.2 MHz"** (line ~167), weeks earlier and
independently.

**There is no seed to sweep.** MEASURED: Vivado 2023.2 has no `-seed` on
`place_design`/`phys_opt_design`/`route_design`, only `-directive`.

**Post-route phys_opt is INSURANCE, measured both ways:** no-op at positive
slack (EPR 0.001 -> 0.001), but +131 ps and 1,007 endpoints recovered at
negative slack (Flow -0.352 -> -0.221). **Keep it in whatever becomes the
default** -- it is what will claw back ~130 ps when B's and C's movers push
this design negative.

**LEAD:** rows 6/7 fail on **9,213 endpoints**, the same count this board
records as *"A-only endpoint bitstream's 9,213 failing endpoints still
unattributed by hierarchy"*. Same design. `sim/ooc_mover_paths.tcl` can census
it from a run already on disk.

Full write-up: `docs/debugging/2026-09-05_pcieep-strategy-sweep.md`.
Cross-machine identity: `docs/debugging/2026-09-05_cross-machine-bitstream-identity.md`.

**THE BC-250 IS DOWN and needs a physical power-cycle.** It completed the
cross-machine build first (that result is safe and committed). A second build
was then launched with the cap raised 11G -> 12G on a 14 GB box and it became
unreachable; not proven causal (its `wlan0` is a USB dongle) but recorded in
`CLAUDE.md`. No WoL watchdog, so it stays down until someone power-cycles it.

#### Open, and explicitly NOT settled

- **Whether `Performance_ExplorePostRoutePhysOpt` becomes the pcieep default.**
  Costs build time, buys the clock, 1 ps of margin, no seed sweep. NOT decided.
- **`RECUR_LANES` 4 or 32 for `compose4_top`.** The composed top bakes 32 into
  a 512-bit B state port where `llama_top` uses 4; 112 DSPs on the binding
  resource. NOT decided.
- **Whether to wire the conv taps** (above). NOT decided.
- **The composed top is still at -0.041 (198.4 MHz)** and has NOT been rebuilt
  with this strategy.
- **Correctness on hardware, and hardware access.** Unchanged, and outside
  what any build can settle. No agent may program this card.

### 2026-09-04 (evening): THE 9B SHAPE WAS ALREADY RIGHT, AND THE GENERATED TOP WAS STALE

Oren asked whether `compose4_top` can be used to get the real 9B shape into
`llama_top` so the full inference goal is reachable. **The composed top is
ALREADY at the real 9B shape**, MEASURED, 13 of 13 literals:

```
SHAPE_OK 13 literals agree with model_cfg_pkg (MODEL at NCARDS=1):
  attn 16x4 hd=256 layers=8, gdn 16/32 hd=128 layers=24
```

**There is no retarget to do. What there was is no gate holding it.** The
shape is hand-transcribed at THREE independent sites and only the region
file's `RG_SHAPE : shape_t := mk_shape(MODEL, NCARDS)` actually derives from
`MODEL`. `attn_block.vhd:199-206` says its four generics are "DERIVED from
QWEN35_9B" -- **the derivation is in the COMMENT and the VHDL has literals.**
`gdn_block.vhd` does not mention `model_cfg_pkg` at all. The generator
restates the same four AGAIN as Python strings. Flipping `MODEL` to
`QWEN38_27B` would move the region file and leave A, B and C at 9B numbers
with no error raised anywhere.

New: `sim/shape_probe.vhd` (deliberately NOT `tb_*`, so it is not
auto-discovered as a row) and `sim/check_model_shape.py`. Its expected values
come from GHDL elaborating `model_cfg_pkg`'s own functions rather than from
arithmetic in Python, because a guard that restates the thing it guards agrees
with it by construction.

**AND `hw/fk33/rtl/compose4_top.vhd` WAS STALE.** Commit `11bf64b` added the
`job_index` port to `fk33_engine.vhd` and did not regenerate the top that
instantiates it. Nothing checked: `tools/gen_cardtop.py` has had `--check`
since TRACK CARDTOP and is gated; `gen_compose4_top.py` had none. It surfaced
only because an unrelated run regenerated the file and `git status` showed it
modified when the generation should have been a no-op. **That is luck, not a
gate.** Fixed: `gen_compose4_top.py --check` (M1 is the real historical file,
KILLED) and the `sim:c4stale` row. `fk33_engine.vhd` was MEASURED in sync and
stays UNGATED, because its generator takes no arguments and writes
unconditionally -- even `--help` rewrites the repo file.

**UNIT V IS WIRED**, `--wire-v`, additive and OFF by default so section 14's
`--wire` numbers keep describing what they measured.
`ELABV_RESULT OK cells=444169`, 0 errors. Controls: `--wire` output
byte-identical at 134,199 bytes, default at 123,286, and the comparison has
teeth (449 lines differ with V on).

**WHAT ACTUALLY BLOCKS FULL INFERENCE IS TIMING, NOT SHAPE.** The composed top
carries all four subsystems' compute at the real 9B shape plus D's control
plane plus unit V. Absent are B's and C's data movers, and both are short:

| piece | state |
|---|---|
| B `gdn_block` | 22 BRAM, 141 DSP, **WNS +0.483 = 221 MHz, MEETS 200** |
| B's mover `gb_real` | fits after the `gdn_state_store` substitution, **111 MHz**, path UNATTRIBUTED |
| C's mover `gcr` | fits on area (60 BRAM), **151.3 MHz**, KV-AXI arm will not synthesise |

**AND 200 MHz IS A CHOSEN DESIGN POINT, NOT A BOARD CONSTRAINT.**
`gen_pcieep.py:360` sets it from the duty identity `f_core / f_axi = 200/250 =
80.0%`. At the shipped bitstream's measured 192.2 MHz that becomes 76.9%,
which INCREASES HBM margin and costs ~3.9% throughput. So the existing
bitstream is usable as built. **This is Oren's call and has not been made.**

Full write-up: `docs/debugging/2026-09-04_composed-top-9b-shape.md`.

**THE NEW ROW EARNED ITS KEEP IMMEDIATELY.** `sim:c4stale`'s FIRST
clean-checkout run FAILED: `rtl/ooc_normadapt_top.vhd` was **untracked and not
gitignored**, while both its siblings were tracked. The COMMITTED
`compose4_top.vhd` instantiates `ooc_normadapt`, so **a clean checkout of HEAD
referenced an entity whose file was not in the repository** -- nobody could
have built the composed top from a fresh clone. Fixed by tracking it, after
confirming it is byte-identical to what the extractor produces from the
current `llama_top.vhd`. Swept: it was the only untracked `.vhd` under `rtl/`.

**Gate state:** working tree `OVERALL PASS 132 FAIL 0` (131 + `shapechk`;
`c4stale` took it 130 -> 131). Clean-checkout floor measured separately,
because the gate itself warns that 22 of this tree's rows are unreachable
after a fresh clone.

**RESULT, the branch taken:** synth PASSED (`elab rc=0`, `synth rc=0`, both
`C4_DONE` line-anchored), so section 14 got a COMPANION section 15, not an
edit. **And the first number was not reportable.** The V-wired top is 2,308
LUT below section 14's table -- but ten commits touched `rtl/` since
2026-09-02, so that delta conflates unit V with all of them. A CONTROL was
synthesised the same day from a tree differing in exactly one file:

| | `--wire` control | `--wire --wire-v` | delta |
|---|---|---|---|
| CLB LUT | 270,125 | 267,833 | **-2,292** |
| CLB Registers | 237,896 | 237,905 | **+9** |
| CARRY8 | 12,514 | 12,554 | **+40** |
| Block RAM / DSP | 327.5 / 2,177 | 327.5 / 2,177 | **0 / 0** |

**Unit V costs +9 FF and +40 CARRY8 at zero BRAM and zero DSP, and SAVES
2,292 LUT.** Mechanism is an ESTIMATE (93 boundary ports internalised, 1,185
-> 1,092), not established. Confound stated in section 15: the two runs had
different `MemoryHigh` caps, so their RSS peaks are NOT comparable and no
memory delta is claimed.

**Composed synthesis is a WORKSTATION job, measured:** 16.4-20.1 GB peak, so
it does not fit the BC-250's 14 GB.

**A DISPATCHER ERROR THAT COST NOTHING ONLY BY MARGIN.** The gate-liveness
test asked "is any process's cwd inside the scratch dir". Between rows nothing
satisfies that, so it reported the gate DEAD twice while it was running fine.
Acting on the first false report, a second full gate was launched: **two gates
plus a Vivado ran concurrently**, memory reached 19.9 of 31.9 GiB. No OOM, but
that is margin, not design. The duplicate (orphaned session 1213141, six
processes) was killed by explicit pid after confirming its sid was not the
live shell's. **Liveness is now tested by SESSION ID, which is stable across
rows.** This is the project's own trap in a new place: identify a process by
what the kernel maintains about it, never by a property that merely happens to
hold at the moment you look. `cwd` is as unreliable a needle as a command
line, for a different reason.

### 2026-09-03 (night, last): THE HOST SOFTWARE IS GATED, and its teeth are 1 of 4

`server/pl_backend.c` is the driver and `server/llama_server.cpp` is the
OpenAI-compatible server. **Nothing scheduled either of their harnesses.** Both
pass; that was never the point.

**THE ROT ALREADY HAPPENED AND NOBODY SAW IT.** `server/tests/server_e2e.py`
began failing 2026-08-29 when `pl_open` started refusing an undeclared
descriptor arena: `seam_selftest.c` was updated for it, `llama_server.cpp` was
not. It stayed red for days saying only *"FAIL: server never came up"*, because
it sent the server's stderr to `DEVNULL` and could not show the refusal that
explained it. It was fixed earlier in this session (`c13976e`) -- but only
because someone happened to run it.

Two rows now exist, `sim:srvseam` and `sim:srve2e`, added by the THREE edits
`regress.sh` demands (command, plan printf, and the dispatch case in `run_one`,
which is the one its old comment used to omit).

**THE TEETH WERE MEASURED FIRST, AND THREE OF FOUR MUTANTS SURVIVED:**

| mutant | result |
|---|---|
| M4 off-by-one in `pl_prefill`'s KV bound | **KILLED** |
| M1 `FK33_SEAM_ID_MAGIC` changed | SURVIVED |
| M2 alignment refusal DELETED outright | SURVIVED |
| M3 identity comparison disabled (`if (0)`) | SURVIVED |

M4 proves the row can fail, so it is real and not decoration. The survivors are
the more valuable half:

- **M1 is a SHARED CONSTANT.** `fk33_sim.c` and `pl_backend.c` both read it, so
  moving it moves BOTH sides and the comparison still agrees. Self-consistency,
  not an oracle -- the `m7 mutant` shape exactly.
- **M3 shows T2 PASSES FOR THE WRONG REASON.** T2 is titled "a wrong seam base
  is refused by the identity read" and asserts only `pl_open(...) < 0`. With
  the identity check disabled it still fails, for a different reason.
- **M2** means T6's "four layout refusals" never reaches the alignment
  predicate in `check_geometry()`.

**So "84 checks, 0 failed" is NOT coverage of the identity read, the alignment
refusal, or the seam magic.** Tightening those three is open work, stated as
open rather than implied closed by a green row.

**Two limitations recorded rather than hidden:** `srve2e` is a NO-OP on a clean
checkout (it needs a 9 MB uncommitted `.qtk` and returns 0 without it), so it
is teeth on a developer tree only -- which is precisely where the 2026-08-29
regression lived. And a failing row's detail line is make's `Error 1`, not the
selftest's, because `SELFCHECK_CMD` is expanded UNQUOTED so `sh -c` and `&&`
cannot be used; the failing checks are in the row's log.

**Process note worth keeping:** the `count == 1` anchor guard refused a mutation
whose target line appears TWICE, and one intermediate run was discarded rather
than recorded as a survival because the mutation had failed to apply and the
run was on clean code. `make` was also verified to have genuinely rebuilt
between mutants -- three survivals is more often a broken measurement than a
weak test.

### 2026-09-03 (night, later): THE WIRED TOP ROUTES. 60.5% LUT, 75.6% DSP, 181.7 MHz.

`gen_compose4_top.py:177` said "the wired top needs its own place-and-route
run". It has now had one. The wired top was generated into a SCRATCH tree, so
the checked-in unwired `compose4_top.vhd` and TRACK ROUTE3's numbers on it are
untouched.

`C4_DONE synth wire4` then `C4_DONE impl wire4`, both `EXIT 0`.

| | post-route | device | % |
|---|---|---|---|
| CLB LUT | 266,138 | 439,680 | 60.53 |
| CLB register | 243,161 | 879,360 | 27.65 |
| Block RAM tile | 327.5 | 672 | 48.74 |
| DSP | 2,177 | 2,880 | **75.59** |

**Routing is CLEAN: 521,388 of 521,388 routable nets, 0 routing errors, and DRC
reports 0 errors and 0 critical warnings.**

| clock | target | WNS | failing |
|---|---|---|---|
| `hbm_aclk` | 250 MHz | **+0.006** | **0** of 12,862 |
| `core_clk` | 200 MHz | **-0.502** | 5,287 of 956,041 |

**Hold was never a problem.** Synthesis showed WHS -0.100 with 402,321 failing
endpoints; routing fixed it to **+0.010 with ZERO**. The synthesis stage's
"Timing constraints are not met" is HOLD, and reading it as a setup failure
would have been wrong.

**THE CENSUS OVERTURNED THE WORST PATH, and this is the transferable part.**
The routed report lists FOUR paths for 5,287 failing endpoints and its worst is
in `c_attn/u_arr`. Counting endpoints on the routed DCP instead:

| bucket | failing | share | worst |
|---|---|---|---|
| **`a_eng`** | **4,024** | **76.1%** | -0.493 |
| `c_attn` | 603 | 11.4% | **-0.502** |
| `b_gdn` | 591 | 11.2% | -0.460 |
| `d_norm` | 69 | 1.3% | -0.439 |

`CENSUS_TOTAL 5287` matches the summary's own count, which is the check that
both measure the same population. **The worst path is in C; 76% of the work is
in A.** Only the census names the work.

**AND ALL FOUR BUCKETS LIE WITHIN 0.063 ns OF EACH OTHER.** A single broken
path leaves one bucket far worse. Four subsystems inside 63 ps is a
DESIGN-WIDE shortfall against an aggressive target, not a localised defect.
Do not go hunting for "the" critical path.

**The lead, labelled a lead:** DRC reports 2,728 DSP pipelining warnings on
2,177 DSPs (1,762 unpipelined inputs, 632 missing MREG, 334 missing PREG),
bucketing `a_eng` 1,592, `c_attn` 689, `b_gdn` 348, `d_norm` 99. Both orderings
agree A dominates and 0.502 ns on 5 ns is 10%. But that is a correlation of two
rankings over four buckets and no advisory has been shown to lie ON a failing
path. The discriminator is to pipeline A's DSPs and re-run impl.

**Also unmeasured: whether 200 MHz is needed.** 181.7 MHz is 91% of target and
no throughput requirement here has been checked against it. That question is
worth answering BEFORE spending retiming effort.

**THE CAVEAT ON THE FIT, which is not small:** `compose4_top` instantiates
`gdn_block` DIRECTLY and does NOT contain `gb_real`, so 48.74% BRAM excludes
B's recurrent state entirely and URAM is 0. The results README explicitly
refuses to add this column to the mover's own 63,905 LUT / 34 BRAM / 32 URAM /
194 DSP, because parts do not sum across synthesis contexts. **DSP at 75.59% is
the tightest resource and is the number to watch when the mover is added.**

**CORRECTION, same day, MEASURED: most of the -0.502 was the DIRECTIVES.**
A controlled re-implementation from the SAME `wire4_synth.dcp` -- identical
netlist, only `opt`/`place`/`phys_opt`/`route` directives changed, plus a
post-route `phys_opt` the default flow never runs:

| | default | high effort |
|---|---|---|
| WNS | -0.502 | **-0.090** |
| failing endpoints | 5,287 | **815** |
| achieved | 181.7 MHz | **196.5 MHz** |

**82% of the gap closed with no RTL change.** So "the design misses 200 MHz"
was the wrong sentence; the DEFAULT FLOW misses by 0.502 and the design misses
by 0.090. Same class of error as reading a synthesis estimate as a routed one.

**Timing MET at +0.016 BEFORE routing, and routing cost 0.106 ns**, so what
remains is routing detour rather than logic depth -- which points AWAY from the
DSP-pipelining lead recorded above. That lead is neither confirmed nor refuted;
it was never tested and at -0.090 may not be needed.

The census moved the same way and A became relatively MORE dominant: `a_eng`
4,024 -> 615 (75.5% of what is left), `b_gdn` 591 -> 157, `c_attn` 603 -> **42**,
`d_norm` 69 -> 1. **`c_attn` fell 14x, so the default run's worst path being in
C was misleading twice over**: C was both a small share AND the share that
effort almost entirely removes.

Still unmeasured: whether 200 MHz is required at all.

Full write-up: `hw/fk33/results/wire4_2026-09-03/README.md`.

### 2026-09-03 (night): B's data mover FITS. The blocker was one array, and it is gone.

**`gb_real` is subsystem B's data mover.** It is 614 lines of `llama_top.vhd`,
it instantiates `gdn_block`, every `llama_top` gate row has exercised it for
weeks, and it had NEVER been synthesised. The standing blocker "per-unit data
movers for B/C (~1,600 unwritten lines)" is a statement about ENTITIES. The
logic exists.

Extracted (`sim/ooc_gdnadapt_extract.py`) and built alone it needed **5,472
RAMB36 against 672 on the part, 814%**. Vivado's own RAM inference table names
the object outright:

```
| gb_real.stmem_p.stmem_reg | 3072 K x 64 (READ_FIRST) | 5472 RAMB36 |
```

3072 Ki x 64 is **24.0 MiB exactly** = 1.0 MiB per layer x all 24 GDN layers
resident at once. That is this project's own 24 MB finding, now attached to a
line number (`llama_top.vhd:3847`).

**Substituting `gdn_state_store` for that one array fixes it.** MEASURED,
`sim/ooc_gdnadapt_ss.tcl`, `MAXROWS=64`, `OOC_EXIT 0` with sentinel:

| | before | after | device |
|---|---|---|---|
| Block RAM tile | 5,472 (**814%**) | **34 (5.06%)** | 672 |
| URAM | 0 | 32 (10.00%) | 320 |
| CLB LUT | 127,260 (28.9%) | **63,905 (14.53%)** | 439,680 |
| CLB FF | 46,279 | 37,933 | 879,360 |
| DSP | 141 | 194 (6.74%) | 2,880 |
| WNS | -4.008 | **-4.008** | |

**The LUT count HALVED**, which was not the goal and not predicted: a
3-million-entry address computation is not free. **DSP went UP** 141 to 194, the
store buying area back in address arithmetic; a saving reported without that row
would be dishonest.

**`gdn_block` itself was never the problem: 22 BRAM tiles, 141 DSP, WNS +0.483 =
221 MHz, which MEETS the card's 200 MHz.**

**THE THREE MODULES BUILT THIS WEEK COMPOSE EXACTLY, and that is now CHECKED
rather than assumed.** `gdn_job_seq`'s `ss_load_start`/`ss_save_start`/
`ss_layer`/`ss_done`/`ss_err` and its `cvw_*` group map one-to-one onto
`gdn_state_store`; `b_start`/`b_busy` map onto `gdn_block`. `tok_adv` is
deliberately the caller's, being per-token not per-layer. The only signal
needing a new source is `q_data`, this token's qkv column.

**AND THE TOKEN-1 REFUSAL IS THE SAME CHANGE.** `llama_top.vhd:4316` refuses
`B_SRC_REAL` past token 0 and names exactly what is missing: *"a new (KCONV-1)
x qkv_dim buffer, 3 x 8,192 words at the 9B shape"*. That is
`rtl/gdn_conv_tap_mem.vhd`, which exists and is already inside
`gdn_state_store`. The refusal's SECOND reason -- that `B_SRC_REAL` raises the
degenerate-residual count -- is a BENCH artifact, not a silicon one: the file
says it is "A's synthetic weights" that make `R_ALPHA` physically impossible,
and that "sourcing the taps ALONE is neutral".

**WHAT IS STILL NOT DONE.** No substitution has been made in `llama_top` --
this is an OOC measurement of a generated variant. The integration wants the
`C_KV_AXI` pattern: a default-false `B_STATE_AXI` generic, top-level AXI master
ports with defaults on the inputs, tied off when false. And the measurement ties
the store's conv face off while keeping `gb_real`'s own memory 3, so it is an
UPPER bound; the real integration replaces memory 3 too, which is what lifts
:4316.

**THE TIMING IS NOW B'S TOP OPEN ITEM AND IT IS UNATTRIBUTED.** `-4.008` before
the substitution and `-4.008` after, to the digit. The write-up had guessed
`stmem` was the largest suspect for the critical path; that is now REJECTED,
measured. 111 MHz against the card's 200 is unexplained.

**THE PROCESS LESSON, which cost the first version of the write-up.** A size
sweep showed the 5,472 did not move when the buffers were quadrupled, so it was
not the buffers -- and from "not the buffers" this dispatcher concluded "then it
is `gdn_block`", wrote it up with a table, cross-checked the arithmetic against
the known 24 MB figure and got AGREEMENT. `gdn_block` alone is 22 tiles. **An
invariance argument identifies what a number is NOT, never what it is**, an
agreeing cross-check does not rescue a wrong owner, and the naming table had
been sitting in the log from the first run. Both lessons are in `CLAUDE.md`.

Full write-up: `docs/debugging/2026-09-03_b-mover-does-not-fit.md`.


### 2026-09-03 (evening): the first integration lands, and `--wire` is not "nothing is wired"

**A CORRECTION TO THIS SESSION'S OWN READING OF THE BOARD.** It was reported
here and to Oren that the subsystems are "not wired to anything". That is true
of the CHECKED-IN `hw/fk33/rtl/compose4_top.vhd` -- and that file is the
UNWIRED variant. `hw/fk33/gen_compose4_top.py` has a `--wire` flag that emits a
materially different top: `seam_a` (`a_desc_adapter`, D-to-A), `seam_b` and
`seam_c` (both `u_seam`), and `region_mem`. It is off by default for a stated
reason -- *"so the co-residency measurement vehicle, and TRACK ROUTE3's numbers
taken on it, are preserved exactly."*

So the CONTROL plane has a generated wiring. What is missing is the DATA plane,
and the generator says so at line 928: the region file's *"real drivers are the
per-unit data movers, which do not exist yet."*

**`a_job_index` also existed after all**, as a generated top-level port wired to
`a_desc_adapter.u_index`. It appears in no hand-written `.vhd`, which is why a
grep for it found nothing and why this session first concluded the wrong thing
twice. The port is `u_index`; the signal is `a_job_index`.

**WIRED THIS SESSION.** `rtl/a_job_counter.vhd` now drives it:

* `hw/fk33/rtl/fk33_engine.vhd` forwards `job_index` and `CHECK_JOB_INDEX` to
  `matvec_int4_desc_axi`. Both default so the host-driven card flow -- the one
  that produced 311 of 311 jobs element-exact -- is untouched.
* `gen_compose4_top.py --wire` instantiates the counter, drives BOTH
  `a_desc_adapter.u_index` (16 bits) and the engine's `job_index` (32) from it,
  and **retires the `a_job_index` top-level input**. That port existed because
  nothing in the RTL decided the value. Something does now.
* `job_retire` is D's `u_ack`, VERIFIED to be a one-cycle pulse:
  `seq_desc_fetch.vhd:963` drives it from `S_COMPLETE`, and every branch of
  that state assigns a new state, so the unit cannot sit there. A level would
  multi-count and walk off the descriptor table.

**MEASURED: the wired top elaborates in Vivado, ELAB_EXIT 0, zero ERRORs**,
with `seam_a_idx` and `seam_a` both present as cells. GHDL cannot answer this
-- the composed top instantiates UNISIM `BUFGCE` and has never been
GHDL-elaborable, which is a property of the existing top and not of this
change.

**AND WIRING IT FOUND A BUG IN THE MODULE.** `seq_desc_fetch.vhd:166`: *"`go`
is a level or a pulse; it is only read in S_IDLE."* D can read a level because
it leaves S_IDLE at once. The counter could not: it checked `tok_start` before
`job_retire`, so a host holding `go` high would have pinned the count at zero
and **every A job of that token would have fetched descriptor 0**. Fixed by
reloading on the RISING edge, which accepts the weaker contract.

**THE BENCH PASSED BOTH BEFORE AND AFTER THAT FIX** -- 122 checks, green
either way, because it had no case holding `tok_start` high across a retire.
*A green bench across a real fix is the tell that the fix is untested.* Case
added (134 checks); the pre-fix version fails 4 of them with `u_index is 0` on
every retire, the predicted failure observed. Six mutants now, all killed, each
by its own property.

The reusable form: **before connecting a signal, read the DRIVER's stated
contract for it, not the shape you expect, and where they differ take the
weaker one** -- that is the one the other end is allowed to produce.

Doc: `docs/debugging/2026-09-03_a-desc-ptr.md`, final two sections.

### 2026-09-03 (later still): CORRECTION -- `a_desc_ptr` duplicated `a_desc_adapter`

**Withdrawn: `rtl/a_desc_ptr.vhd`**, committed `e01c535` earlier today and
removed in the next commit. The version-2 descriptor index work in that commit
STANDS; only the pointer module is withdrawn.

**`rtl/a_desc_adapter.vhd` already existed** -- 328 lines, with a gate row --
and already owned the address (`arena_base + u_index * DESC_STRIDE`, :213), the
`u_index >= N_JOBS` bound check (:230), the non-power-of-two stride refusal
(:127) and the AXI-Lite writes. Its own header cites `tools/hbm_map.py` on why
a hardcoded arena address became "a FOURTH model of the same address" and takes
`arena_base` as a PORT so as not to be the fifth. `a_desc_ptr` made it the
fifth.

**HOW: I grepped for the DOCUMENT's word, not the RTL's.** Three documents call
it `a_job_index`; no VHDL file does. The port is `u_index`. A null grep for one
spelling is not evidence about the design. **This is the second instance in one
day** -- the first was claiming A's weight fetcher did not exist. Both times I
reasoned from prose rather than from entity declarations. The rule that was
already written down ("a 'not done HERE' comment is a statement about ITS
FILE") was not enough. The operational version: **grep the entity declarations
for the SHAPE you are about to build -- a port of that width, a generic of that
name -- not for the words a document used.**

**The replacement is smaller and better.** `rtl/a_job_counter.vhd` does only
the thing that was missing: nothing drove `u_index`. And narrowing it exposed a
design improvement `a_desc_ptr` did not have -- it advances on **retire**, not
issue, so the index is constant across a whole job and
`a_desc_adapter:200-212`'s "must be sampled one cycle later" hazard does not
arise instead of being answered carefully. 122 checks; five mutants killed, and
Z2b (priority inverted between `tok_start` and `job_retire`) fails exactly one
check and nothing else.

Doc: `docs/debugging/2026-09-03_a-desc-ptr.md`, CORRECTION section at the end.
The filename is deliberately unchanged so the link in `e01c535` still resolves.

### 2026-09-03 (later): the A descriptor pointer is DECIDED, and B has a job sequencer

Two of the five standing blockers closed, and one of them turned out to be two
blockers that were the same question.

**BLOCKERS 1 AND 4 WERE ONE DECISION.** "A's `DESC_PTR` sourcing is an
unresolved design decision" and "`job_ordinal` is 8-bit and cannot address 311
jobs" are two faces of one missing field: D's 64-byte step header has nothing
pointing at A's per-job data. Both `DESC_PTR` and `a_job_index` were exported
as top-level inputs of the composed top rather than wired, which is why the gap
stayed visible instead of being guessed at.

**THE DECISION, taken by Oren: the card COUNTS.** `rtl/a_desc_ptr.vhd` holds
the number of A jobs dispatched so far in the current token and emits
`BASE + n*STRIDE`. No fetch, no new region, no D format change.

**AND THAT IS WHY THE DESCRIPTOR FORMAT CHANGED ANYWAY.** An arithmetic pointer
does not remove the problem, it MOVES it: it imposes an ordering contract on
the host, and an unchecked ordering contract produces a WRONG TOKEN rather than
an error. A well-formed descriptor for the wrong step passes every single check
in `S_CHECK` -- magic, version, geometry, opcode, four pads, shape -- because
**nothing else in a descriptor says which step it belongs to**. So descriptor
**version 2** stamps the descriptor's own index into extension word 3 and
`matvec_int4_desc_axi` refuses a disagreement with `EC_DESC` / `ED_JOB_INDEX`
before the array starts. Version 1 is still accepted.

**THE MUTANTS MAP ONE-TO-ONE, which is the attribution.** Three RTL mutants,
each deleting one new arm: X1 (the index comparison) fails only bench row (c),
X2 ("a v1 descriptor may not carry an index") only row (d), X4 (version check
widened to accept anything) only row (f). No row rides on another row's kill.
Four counter mutants, all killed: monotonic across tokens, live base, wrap on
overflow, sticky `err`.

**A PARALLEL COUNTER IN THE PACKER WOULD HAVE DRIFTED.** `addr` advances only
on the success path, so a refused step consumes no slot while a per-step
counter keeps counting. The stamp is DERIVED from the address slot instead,
`(addr - desc_base) // a_slot`, so the two cannot disagree -- and if the tool
ever emits a sparse table, the card's dispatch count disagrees with the stamp
and the check refuses it LOUDLY.

**BLOCKER 2 CLOSED: `rtl/gdn_job_seq.vhd`.** One GDN layer for one token: load,
run `gdn_block`, refill the conv taps, save. 39 CLB LUT / 146 FF, fmax 916 MHz.
The refill goes AFTER the unit because the taps hold the previous `KCONV-1`
columns while it reads them. **The qkv read takes TWO edges, not one** -- a
one-stage version failed 31 of 32 data checks with the count and the order both
green. `tok_adv` is deliberately not a port: it belongs to whoever knows where
a token ends, and this module is one layer.

**MUTANT D2 IS WHY THE ATTRIBUTION CONTROL EXISTS.** Refilling the taps BEFORE
the unit runs satisfies every other ordering check in the bench -- every group
written once, in order, with correct data, after the load and before the save.
It fails 9 with the full bench and **0 with the control**. Without the control
the table would have credited the kill to nothing in particular.

**WHAT IS STILL NOT CONNECTED, stated plainly.** `rtl/llama_top.vhd` does not
instantiate `matvec_int4_desc_axi` at all; it instantiates the raw
`matvec_int4` and synthesises A's bases arithmetically. Nothing instantiates
`gdn_job_seq` either, and nothing pulses `a_dispatch`, `tok_start` or
`tok_adv`. **Three mechanisms are decided, implemented and verified as units,
and none of them is wired to anything.** Blockers 3 (C's mover) and 5 (unit V,
P&R) are untouched.

Docs: `docs/debugging/2026-09-03_gdn-job-seq.md`,
`docs/debugging/2026-09-03_a-desc-ptr.md`,
`docs/2026-08-28_matvec-descriptor-format.md` (version 2 section appended).

### 2026-09-03: the third phase lands, and B's per-layer state is complete on-chip

**`gdn_state_store` now runs THREE movers over ONE pair of HBM masters** --
mantissas, exponents, conv taps -- with a five-state sequencer and a 3:1 AXI
mux. One `load_start` moves all 1,101,824 bytes of a layer in three transfers
and pulses `done` once.

**MEASURED, composed OOC, shipping shape, 5.0 ns: 4,028 CLB LUT (2,108 logic +
1,920 as memory), 2,004 FF, 32 URAM288, 12 RAMB36, 3 DSP, WNS +1.400.** That
is the WHOLE resident state tier for all 24 GDN layers: 0.92% of the device's
LUTs, 1.79% of its BRAM, 10.0% of its URAM.

**THE PARTS DO NOT SUM, FOR THE THIRD TIME, AND NOW THE SHAPE IS KNOWN.**
3,310 + 317 = 3,627 against 4,028 measured: **+401 LUT, +11.1%**. The
two-phase composition was +347, +11.7%. Two increments of the same size, so
**the muxes are NOT growing faster than linearly in phases** -- which was the
obvious worry about going from a 2:1 to a 3:1 and is now measured instead of
assumed. Three DSPs, one `layer * LAYER_STRIDE` per mover.

**THE GENERIC CHOICE THAT REMOVED THE ARITHMETIC.** `gdn_state_axi` emits
`flat = (head*DIM + col)*N_GRP + grp`. Instantiating the conv mover at
`VAL_HEADS => 1, DIM => CONV_WORDS, N_GRP => 1` makes head and grp identically
zero, so **`col` IS the flat word address** and it wires straight to
`gdn_conv_tap_mem`'s mover port -- no multiply, no add, nothing for an
integration error to hide in. That is defect D1 applied rather than restated:
pick the decomposition so the caller never has to invert it. **Mutation C7 --
instantiating it at `VAL_HEADS => CONV_WORDS/DIM, DIM => DIM` instead, which
is the natural-looking choice -- fails 920 of 7,968 checks.**

**THE BENCH NEEDED A FOURTH TOKEN, AND THAT IS THE COVERAGE LESSON.** The
conv history is `KCONV-1 = 3` columns deep, so a three-token run never once
presents a FULL history: every conv check would have been reading a history
that was partly zeros, and a rotation wrong only when all three slots are live
would have passed all of them while the suite said PASS. `NTOK` 3 -> 4, and
`n_full` is now asserted non-zero so a future shrink cannot silently undo it.
**Coverage of the input space is not coverage of the output space**: 1,024
conv groups were checked and only **256** of them had a full history behind
them.

**Seven of eight new mutations bite** (phase skipped; conv aliased onto the
exponent base; load/save swapped; the wrong `sel` held, which dies in the
mover's own bound check; the rotation frozen; `m_r_en` left open; the head/col
decomposition). The three earlier mutations still bite against the extended
bench, so the older properties were not weakened by the new shape.

**C8 does NOT bite** -- the `busy` gate on the unit's conv write -- and it is
the third of its kind after `s5` and `s6`. The bench never violates the
ownership rule, so a gate against that violation has nothing to suppress. Kept
as defence, reported as untested. Three of these now; the pattern is that
every ownership gate in this tier is structurally invisible to a bench whose
stimulus obeys the ownership rule, and only a deliberately misbehaving caller
would exercise them.

**What is still missing is a CALLER, not storage.** Nothing feeds the tap
write port from A's qkv stream and nothing pulses `tok_adv`. `B_SRC_REAL`
still cannot run past token 0, but the reason has moved: it is now the absence
of a job sequencer rather than the absence of anywhere to put the state.

**CORRECTION TO MY OWN FRAMING TODAY, AND IT MATTERS MORE THAN THE TIER.**
I have been calling the conv tap history "the" reason `B_SRC_REAL` cannot pass
token 0, and repeating it into three documents. Reading `llama_top`'s own
header rather than the assert shows TWO reasons, and it MEASURED them:
"B_SRC_REAL defaults FALSE and the reason is measured, not conservatism: with
it TRUE the degenerate-residual count RISES, 0/3/10/23 -> 3/5/11/24 at
4/8/16/32 blocks, because A's synthetic weights make R_ALPHA's VALUES
physically impossible and gdn_scalar's gate saturates shut. **Sourcing the taps
ALONE is neutral.**"

So the tap store removes an ASSERT and changes no number. What changes numbers
is A -- and **I then got the SIZE of that wrong too, in the same hour, and the
two mistakes have one shape.**

I quoted `rtl/seq_desc_fetch.vhd:113-115` -- "The base array ... is NOT fetched
here ... Fetching it is remaining work" -- and wrote it up as "A does not fetch
its weights, and writing that fetcher is the top blocker". **The fetcher
exists.** `rtl/matvec_int4_desc_axi.vhd` reads a descriptor from `DESC_PTR`,
drives the core's `w_base`/`s_base` from its base array
(`dw(DESC_BASE0 + p)`), carries its own base-array bounds checks, and is
covered by FOUR gate rows: `tb_a_geom`, `tb_matvec_fk33_desc`,
`tb_matvec_fk33_desc_dual`, `tb_matvec_fk33_desc_xexp`.

What is wrong is the INTEGRATION: `llama_top.vhd:3335` instantiates the RAW
`matvec_int4` and fabricates the bases as a uniform stride
(`base + p*A_SUB_BYTES`), and its own warning says the cost -- "The per-job
weight address block is FABRICATED ... running would have read the next
sub-region's bytes and reported success."

**The genuinely open piece is where `DESC_PTR` comes from**, and
`tools/gen_layer_program.py:36` states it as a DECISION rather than a gap:
"which mechanism delivers them to the card is an open integration decision,
not a derivation." D's step table is dense at a 64-byte stride, so step i+1's
header occupies exactly the bytes step i's base array would need; the two
cannot share a block, so the pointer must live somewhere and today it does not.

**THE LESSON, TWICE IN ONE HOUR: a "not done HERE / remaining work" comment is
a statement about ITS FILE, not about the repository.** I took one as a
project-level fact about the conv taps and again about A's weight fetch, and
both times the real situation was narrower -- once because a second blocker
mattered more, once because the capability already existed and was gated.
**Grep for the capability before quoting its absence.**

**THE HONEST ORDER OF WHAT REMAINS TO A RIGHT TOKEN**, corrected twice:
1. Wire `matvec_int4_desc_axi` into `llama_top` in place of the raw core, and
   decide where each A job's `DESC_PTR` comes from. Nothing downstream can be
   right first, and the fetch logic is already written and gated.
2. The B job sequencer, which is also what feeds the tap write port and
   pulses `tok_adv`.
3. C's mover.
4. The descriptor index (`job_ordinal` is 8 bits and cannot address 311 jobs).
5. Unit V, then P&R.

Nothing in that list is software. The state tier landed today is item 2's
prerequisite and not item 1's.

### 2026-09-02, later still: both phases of the state move, the conv arena is reserved, and a standing check had been red

**LANDED: the exponent phase.** `rtl/gdn_state_store.vhd` now instantiates
`gdn_state_axi` TWICE -- once at the mantissa shape and once at
`WORD_BITS => 8, N_GRP => 1` -- with a four-state sequencer and a 2:1 on the
ONE pair of HBM masters. One `load_start` moves 1,052,672 bytes in two
transfers and pulses `done` once. **MEASURED, composed OOC, shipping shape,
5.0 ns: 3,310 CLB LUT (1,390 logic + 1,920 as memory), 1,355 FF, 32 URAM288,
0 BRAM, 2 DSP, WNS +1.400 (278 MHz).** The parts sum to 2,963, so the second
mover, the sequencer and the muxes cost **+347 LUT, +11.7%** -- the second time
in two days that a composed draw came in above the sum of its components, and
the second time neither component's own census showed it.

`sim/tb_gdn_state_store.vhd`: **4,632 checks, 512 of them exponents**, three
tokens, three evictions per layer per token.

**A DESIGN DEFECT AND A BENCH DEFECT, WITH THE SAME SIGNATURE, ON THE SAME
DAY.** Both shifted the data by exactly one element, and that is why the second
cost an hour:

* **Design.** `gdn_exp_mem`'s mover-facing read had to be REGISTERED. The
  mover collects a word TWO edges after issuing its address because
  `gdn_state_mem` is a block RAM; an ASYNCHRONOUS port presents each byte one
  edge early and the mover collects the NEXT one. That is defect D2 of the
  write-up recurring on a second port, and the fix is 8 FF on the mover port
  only -- the unit's port must stay asynchronous.
* **Bench.** After fixing that, 511 of 512 exponent checks still failed,
  shifted by one. The obvious reading was that the fix was wrong.
  **PROBE A settled it in one run**: a loop reading the exponents straight back
  through the unit port with NO DMA in between failed 767 of 768. The mover had
  not run. The cause was a relay signal inside the DUT -- `se_rdata <=
  ex_r_data` -- adding a delta, against a bench that checked the combinational
  read after a fixed `wait for 0 ns; wait for 0 ns;`.

**THE REUSABLE PART: a fixed delta count encodes a private detail of the DUT's
internal wiring in the bench.** Add one relay inside the DUT and every read
shifts by one address, and the bench reports a data error in the wrong module.
`unit_eread` now parks at a FALLING edge and waits a real 1 ns -- half a clock
period, so no rising edge can occur and the read is still proven
combinational, but the check survives any internal rewiring.

**EIGHT MUTATIONS, SIX BITE, AND THE ATTRIBUTION CONTROL SAYS THE NEW CHECKS
EARN THREE.** Every mutant was re-run against the bench with the exponent
checks removed. Three (an asynchronous mover read; the exponent phase skipped;
load and save swapped for that phase only) pass the control and are genuine new
detections. Three do not: `sel_e` never asserted and `done` reported early are
caught by machinery that already existed, and **writing the exponents on top of
the mantissas is caught by the MANTISSA checks** -- it reads like an exponent
bug and is not. Without the control this table would have claimed six.

**TWO MUTATIONS DO NOT BITE AND ARE REPORTED UNDER THEIR OWN NAMES.** Forcing
the idle mover's `arready`/`rvalid` low, and gating the unit's exponent write
with `busy`, are both defensive: an idle `gdn_state_axi` holds `arvalid` low
and the bench never violates the ownership rule, so neither has anything to
discriminate against. They are kept and they are UNTESTED, and no mutation of
this bench can change that. That is the resolution floor, not a gap to paper
over.

**LANDED: the conv tap history is reserved.** `(conv_kernel-1) * qkv_dim * 16`
= 49,152 B per layer, 1,179,648 B total, now DERIVED in
`hbm_map.arena_sizes()` from `model_cfg_pkg`'s `conv_kernel`, the
`qkv_dim = 2*key_dim + val_dim` identity that `gen_layer_program` and
`llama_map_pkg` already use, and a new `scrape_gdn_conv_mant_bits()` that reads
the width off `gdn_block`'s own `cv_x` port. It went INSIDE
`gdn_state_bytes_per_layer` rather than becoming a fourth arena, so there is
one base and one stride: 1,052,672 -> **1,101,824**, total 25,264,128 ->
**26,443,776** (+4.7%). **`server/fk33_manifest.c` needed no change** -- it
reads `gdn_state_base` and `gdn_state_bytes` and nothing finer. **Nothing moves
it yet**, so `B_SRC_REAL` still cannot run past token 0, and the module says so
in its own header rather than implying otherwise.

**AND A FINDING NOBODY WAS LOOKING FOR: `sim/realshape_gate.sh` was RED, at
HEAD, and had been for an unknown length of time.** Running it to check the
arena change found 10 of its rows failing. **The control -- the same script in
a worktree at `8e22ff3` -- failed the same ten**, which is what turned "my
change broke it" into "it was already broken" for the cost of one command.
Both causes were flag mismatches with `sim/regress.sh`, in a file nothing had
touched: no `-frelaxed` (10 rows, dying on
`attn_block.vhd:1065: constant "g" is not visible here`), and no
`--max-stack-alloc=0` (the `all_real` row, dying at GHDL's 128 KB default on a
256 KB object). It is now **PASS, 25 rows, 13 of them guards that must
refuse** -- and all 13 still refuse, which is the check that the fix did not
defang them. Write-up
`docs/debugging/2026-09-02_realshape-gate-silently-red.md`.

**The general lesson is in that file's section 7.** The script is deliberately
NOT a gate row, for a good reason its header states: ten of its rows must make
the elaborator REFUSE, which no testbench can express. The consequence is that
nothing runs it unless a person does, and **the repository has no record of
when it last passed**, so the honest answer to "how long was it red" is
unknown. Where two harnesses run the same tree, their flag sets are an
interface, and this interface has no check -- still doesn't.

**GATE, BOTH TREES.** Working tree **PASS 121, FAIL 0**; clean-checkout
archive with the new files overlaid and `MV4I_FK33_FILE=/nonexistent`
**PASS 113, FAIL 0**. `BASELINE_PASS` 112 -> **113**, taken from the archive
number as rule 10 requires -- **the runner REFUSED the working-tree number**,
naming 23 rows a clean checkout does not get (19 untracked `sim/tb_*.vhd` plus
the four FK33 rows needing the model set). Teeth run on the same archive tree
with `sim/tb_gdn_conv_tap_mem.vhd` deliberately omitted: `PASS 112 FAIL 0`,
`BASELINE DROP: 112 passing, expected at least 113`, `REGRESSION: FAIL`. Note
the `FAIL 0` -- nothing was red, the run is red only because a row vanished,
which is the one class every other check in that runner is blind to.

**LANDED: `rtl/gdn_conv_tap_mem.vhd`**, the on-chip conv tap history --
`gdn_conv` is a causal kernel-4 depthwise conv, so the previous 3 columns of
the whole 8,192-wide qkv stream have to survive from token to token, and
`llama_top`'s stub returns ZERO for all of them. **MEASURED: 12 RAMB36, 317
CLB LUT, 8 FF, WNS +3.831 (261 MHz).**

**IT TOOK FOUR VERSIONS AND THE FIRST COST 35,726 LUT AND ZERO BRAM.** Each
was stopped by a DIFFERENT Vivado refusal:

| version | structure | CLB LUT | BRAM |
|---|---|---:|---:|
| 1 | one array of 192-bit words, variable-offset partial writes | **35,726** | 0 |
| 2 | array-of-array of 16-bit banks, whole-word writes | -- | 0 |
| 3 | banks inside a generate, TRUE dual port | -- | 0 |
| 4 | banks inside a generate, SIMPLE dual port | **317** | **12** |

**`49 KB is 12 RAMB36` was true of the bits in all four and predicted nothing
about three of them.** Version 2 removed a real defect -- a bit slice whose
bounds are expressions is not a byte-enable -- and the count stayed zero
because a second cause was behind it (`[Synth 8-11357]`, an
`array of array of vector` is a "3D-RAM" and gets dissolved into 393,216
registers whatever `ram_style` says). Version 3 fixed that and hit a third
(`[Synth 8-4767]`, the true-dual-port template needs one process PER PORT, and
two VHDL processes cannot drive one signal). **Re-census after every rewrite;
a rewrite that obviously fixes the inference may be fixing a different thing.**

Version 4 is a SIMPLE dual port -- one write port, one read port, each muxed
between the unit and the mover -- which is sound because they are mutually
exclusive by construction, and which makes the mover-wins rule STRUCTURAL
instead of defensive. In version 3 that rule was a priority term no bench
could see: in simulation port B assigns second and simply overwrites, so
removing it PASSED 107 of 107 while being an undefined same-address dual-port
write in hardware.

**Nine mutations, eight bite.** T4 (rotate by the live `phase` rather than the
captured one) does not, and the RTL comment that justified the capture has been
corrected: it claimed a reachable boundary case and there is none, because
`tok_adv` fires only after every layer has read and written. The 2 FF stay as
defence and are recorded as UNTESTED rather than as verified. **T5 -- making
the bank read combinational -- bites on exactly ONE of the 107 checks**, the
pair that asserts the data has not moved BEFORE the clock edge. Without that
one check the wrong primitive passes, which is how `region_mem` cost 91,073
LUT.

**AND A BENCH BUG THAT LOOKED EXACTLY LIKE A DUT BUG: VHDL identifiers are
CASE-INSENSITIVE, so `for t` nested inside `for T` is the SAME name.** All 48
tap-order checks failed on the first run and the DUT was correct. GHDL says so
in one `-Whide` line that reads like pedantry --
`declaration of "t" hides constant "t"` -- and it is the whole diagnosis.

**A PHANTOM REGRESSION IN THE CHAT TEMPLATE, AND THE HARNESS WAS THE BUG.**
Re-running `server/verify_chat_template.py` as a goal check reported
`992 identical, 1045 DIFFER ... CHAT_TEMPLATE FAIL`, with the two thinking
preambles exactly SWAPPED. `git diff HEAD -- server/` was empty, so it could
not be this session's work; a direct probe compiling `qwen35_chat_render` and
calling it twice showed the C emitting **74 bytes at `think=0` and 63 at
`think=1`, which is correct and matches jinja2 byte for byte**.

**The harness was running last week's MUTANT.** `--cbin` defaults to
`build_artifacts_tok/chat_batch`, the script only rebuilds under `--build`, and
a `--build --mutate think-default` run compiles the mutant TO THAT SAME PATH
and leaves it there. Every subsequent plain run then tests the mutant and
reports a FAIL that reads exactly like a regression in `qwen35_chat.c`. Half an
hour went into hunting one.

Fixed in `server/verify_chat_template.py`: a mutation now builds to
`<cbin>.<mutation>` so it can never poison the clean binary, and a run without
`--build` REFUSES if the binary is missing or older than any of its four
sources rather than reporting on it. **Teeth-checked as a sequence**: clean
build PASS -> `--mutate think-default` BITES -> plain run PASS again. Before
the fix that third step was the FAIL.

**AND I BROKE THE ONE-VIVADO RULE, BY ACCIDENT, THE WAY IT ACTUALLY HAPPENS.**
Not by deciding to run two: by launching each OOC census with `nohup ... &` and
then launching the NEXT one after reading the previous one's log, without ever
confirming the previous PROCESS had exited. A log line is not an exit. Three
Vivados accumulated -- the two register-based versions were slow precisely
BECAUSE they had failed to infer BRAM and were elaborating 393,216 registers,
so the failing runs are the ones that linger -- and with two gates also running
the box reached **0 free, 12 GB of swap in use, 3 GB available**. That is the
state described in this project's own memory-budget section, one step before
the night the machine had to be power-cycled.

Killed all nine PIDs, resolved by reading `/proc/PID/exe` rather than by any
`pgrep` pattern; memory went straight back to 21 GB free and both gates
survived. **Nothing was lost, and the reason nothing was lost is luck.** The
rule that would have caught it: after `nohup vivado &`, gate the next launch
on the PROCESS being gone, never on the log being complete.

**Next:** the B job sequencer (load state, run `gdn_block`, save state, plus
the activation movement `gb_real`'s `bp` process does today) and, with it, the
third HBM phase for the conv taps -- `gdn_state_axi` at
`WORD_BITS => 16, N_GRP => 1` -- plus whatever pulses `tok_adv`. Then the same
for C. Write-up `docs/debugging/2026-09-02_conv-tap-history.md`.

### 2026-09-02, later: the GDN state mover exists and works, and its bench found nine defects of which FIVE were the bench's

Oren widened the goal to "bitstream and inference, plus driver, server and
integration for generating output". **The survey answer is that the software
side is essentially DONE and waiting on the RTL**, which is not what I
expected: `server/fk33_transport.h` says in its own header that
`fk33_transport_open_chardev()` IS the real transport and that pointing it at
`/dev/xdma0_user` talks to the card -- *"'swap in the real transport' is not a
code change at all, it is an argument change. What is NOT written here is the
ENGINE the real transport would be talking to."* The OpenAI-compatible server
(`server/llama_server.cpp`) already has an FK33 arm with the real Qwen3.5 chat
template, a tokenizer bit-exact against llama.cpp, the prefill/decode seam and
the host sampler; it runs against a simulated card and says so in its own
`/v1/models` description. **So writing more host software now would be building
against nothing. The critical path is the RTL and nothing else.**

**LANDED: `rtl/gdn_state_axi.vhd`**, the HBM mover for one GDN layer, plus
`sim/tb_gdn_state_axi.vhd`. Bulk DMA and not a cache, because `gdn_block`'s
`st_rdata` is a registered read one cycle after the address and no prefetch
reaches HBM from there. **MEASURED on the BC-250 lane at the shipping
geometry: 269 LUT, 703 FF, 1 DSP, 0 BRAM, 0 URAM, WNS +2.670 at 5.0 ns
(434 MHz).** It is free next to the 32 URAM288 store it feeds. The one DSP is
`layer * LAYER_STRIDE` and a shift-and-add would remove it if DSP ever binds
-- worth knowing, since the composition IS DSP-bound at 2,177 of 2,880.

**393 checks per run, six geometries (up to 1,545 checks), five mutations, all
five bite.** Write-up `docs/debugging/2026-09-02_gdn-state-dma.md`.

**THE LESSON IS THE DEFECT SPLIT: nine found, and FIVE were in the BENCH.**
Every one of those five presented as a design bug -- all zeros, all 'X', a
one-beat shift, a WLAST violation. Named in the write-up as B1..B5. Two are
repeats of traps this repository already documents and I broke anyway on the
same day I read them: **`while busy = '1'` after a start pulse completes
INSTANTLY** (llama_top's own S_ARM comment says so; 384 of 390 checks failed
with the store reading zeros), and **two processes driving one resolved signal
resolve rather than take turns** (the same defect fixed in `f_lost` that
morning).

**B5 is the one worth carrying forward.** A BRESP-completeness check was
written specifically to kill mutant M2 (a save that reports done before its
writes retire), added, and **M2 still passed** -- because the slave model
answered B in one cycle, so every response was in hand by the time `done`
reached the stimulus. The check existed and did not discriminate. A 6-cycle
write-response latency is what turned it into a check. **A check written for a
mutant, that the mutant survives, is exactly the shape of a guard that passes
for the wrong reason, and the only way to know is to re-run the mutant AFTER
adding the check.**

**Two design defects were found ONLY by the parameter sweep and cannot fire at
the shipping numbers:** a `LAYER_STRIDE` that is not a whole number of beats
(layers 0 and 1 correct, layer 2 wrong) and unbounded outstanding AW. The real
stride is aligned (1,052,672 / 32 = 32,896) so neither is reachable today.
**A defect the shipping parameters happen to avoid is still a defect**, because
the next shape change reaches it silently.

**Census filter trap, again:** `get_cells -hier -filter {PRIMITIVE_GROUP == LUT}`
returns **0** in this Vivado on a design whose own `report_utilization` says
269 in the same run. Fixed to `REF_NAME =~ LUT*` / `FD*` in both OOC scripts.
**A census that reports zero reads as a tiny module, not as a broken filter.**

**COMPOSED CENSUS: 497 LUT, 708 FF, 32 URAM288, 1 DSP, WNS +1.400 at 5.0 ns.**
**The parts do NOT sum** -- the arbiter costs +228 LUT and 1.15 ns that neither
component's own census shows. That is the "separately-measured units do not
share" assumption being tested and coming back NO; it is small (0.11% of the
device) but a budget built from the component numbers would have been 228 LUT
short. Also: the object census says 548 LUT and `report_utilization` says 497.
Both are right -- PRIMITIVES versus SITES -- and **the site count is the budget
number**, which is also what the per-module figures were, so they are
comparable. Quoting 548 against them would have overstated by 10%.

**THE EXPONENT STORE LANDED TOO, AND IT CORRECTED HOW I HAVE BEEN MEASURING
AREA ALL SESSION.** `rtl/gdn_exp_mem.vhd` is one layer's state exponents,
4,096 bytes, exactly `gdn_state_exp_bytes_per_layer`. **It cannot be BRAM or
URAM and that is not a preference**: `gdn_block:317` labels the port
"COMBINATIONAL read", drives the address combinationally (:632-633) and
consumes it on the SAME edge (:1203); both alternatives have registered reads.
That is the `region_mem` lesson recurring -- one combinational port turned that
store into 91,073 LUT and zero BRAM. Its bench checks the read **without
advancing time** (drive the address, wait two deltas, the data must already be
right), which a registered read cannot pass; all three mutations bite,
including that one at 31 failures.

**THE MEASUREMENT CORRECTION, and it is the most reusable thing here.** The
object census said **550 LUT**; `report_utilization` said **2,466**. Wrong by
**4.5x**, not the 10% gap seen earlier on ordinary logic.
`get_cells -filter {REF_NAME =~ LUT*}` **does not see distributed RAM at all**
-- it counted 546 logic LUTs and missed the memory; the separate `RAM64M8`
count of 384 is a correct primitive count and a useless budget number, because
**each RAM64M8 occupies FIVE LUT sites** (1,920 / 384 = 5).

**The rule that survives all three census defects found today:
`CLB LUTs` from `report_utilization` is the budget number. An object census
answers "which primitive did I get", not "what does it cost".** All four OOC
scripts are annotated. The earlier figures in this session are unaffected --
269 and 497 are site counts and none of those designs contains distributed RAM.

**And the attribute question came out OPPOSITE to the mantissa store.** For
`gdn_exp_mem`, `ram_style = "distributed"` and `"auto"` are byte-identical, so
the attribute earns nothing; for `gdn_state_mem`, `auto` gave 228 BRAM and the
`ultra` attribute was the difference between fitting and not. **Two stores in
one subsystem, opposite answers, neither guessable from the other.**

**GATE FLOOR: 108 -> 112**, measured as a full-tree number on a clean archive
(`OVERALL PASS 112 ... matches the recorded floor of 112`) and **shown to fire**
by a teeth run (`BASELINE DROP: 111 passing, expected at least 112`).
**It drifted mid-session and that is recorded in the comment**: it was set to
111, then a fourth row was added an hour later and the 111 went stale. Rule
10's failure mode arriving from inside one session rather than across a clone.

**PROCESS MISTAKE, AND IT IS NOT THE ONE I FIRST WROTE DOWN.** I edited
`sim/regress.sh` while a full gate was running from it, reasoned that bash
reads scripts by file offset so a length-changing edit could corrupt the run,
and discarded a 124-row gate on that basis.

**The reasoning is right in general and WRONG HERE, because `regress.sh`
already guards against exactly this and says so.** At `:337` it takes a
private `mktemp` copy of itself, `bash -n` checks the copy, and re-execs it --
with a comment naming the very hazard ("a half-written source ... re-execing
it would produce exactly the failure this guard exists to prevent"). The
running gate was reading `/tmp/regress-self.*.sh`, not the file I edited, and
was immune by construction.

So the discard cost about 25 minutes for nothing. **The lesson is not "never
edit the harness mid-run" -- it is that I applied a general principle without
checking whether this specific harness already handled it, and the check was
one `grep` away in the file I had just edited.** Being cautious is not the
same as being correct, and an unnecessary discard is a real cost, not a free
safety margin.

**STILL MISSING for B:** the per-layer state EXPONENTS (4,096 B, reserved in
the arena, no mover), the conv tap history (49,152 B per layer, **no arena
reservation at all**), and the mux between the DMA's store ports and
`gdn_block`'s `st_*` ports, which is described and not written.


### 2026-09-02, session: the B data mover is NOT a port, because B's state does not fit the device

**Oren asked what remains to flash a bitstream, and chose the B/C data movers
as the next step. Sizing them first changed what they are.**

**THE FINDING, MEASURED** by elaborating this repository's own shape functions
against `QWEN35_9B` under GHDL (not hand arithmetic):
**the Gated DeltaNet recurrent state for all 24 GDN layers is 201,326,592 bits
= 24.0 MB, against 14.2 MB of BRAM plus URAM on the entire `xcvu33p`.** It
overruns every on-chip memory the part has by **1.69x**, with nothing left for
anything else. Write-up
`docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md`; the plan gains
`STEP 3b`.

**So "port `gb_real`'s 635 lines" is WITHDRAWN as the description of this
work.** That framing was written from a line count and never from a sizing.
`gb_real`'s `stmem` is a process variable holding every layer at once, which is
a correct simulation model and cannot become hardware. **A data mover's cost is
in what it moves, and that is not visible in its source: the offending array is
three lines long.**

**ONE layer is 1.0 MB and does fit**, so the design is one layer resident
on-chip streamed to and from HBM per job, 24 jobs per token, DERIVED 50.4 MB of
HBM traffic per token. `rtl/attn_kv_axi.vhd` is the existing precedent and
should be followed rather than reinvented.

**The lane count cannot be swept out of this.** `NBR = DIM/RECUR_LANES` and the
word is `RECUR_LANES*16` wide, so the lane term cancels exactly. `llama_top`'s
own comment says the same independently. Do not retry.

**A SECOND piece of new RTL is required regardless: the conv tap history.**
`llama_top` holds none, and refuses rather than computing a wrong number, so
**`B_SRC_REAL` -- the mode the card must run in -- has never executed past
token 0 anywhere in this repository.**

**LANDED, and the census answered it.** `rtl/gdn_state_mem.vhd` (one layer,
`ram_style` a generic) censused OOC on the **BC-250 lane**
(`sim/ooc_gdn_state.tcl`, three points), workstation lane on the GHDL gate, no
Vivado on this box:

| `ram_style` | URAM288 | RAMB36 | share |
|---|---:|---:|---|
| `"ultra"` | **32** | 0 | 10.0% of 320 URAM, WNS +2.549 at 5.0 ns |
| `"block"` | 0 | **228** | 33.9% of 672 BRAM |
| `"auto"` (no attribute) | 0 | **228** | 33.9% of 672 BRAM |

**THE HEADLINE IS THE THIRD ROW: Vivado picks BRAM on its own and never URAM.**
Without an explicit `ram_style = "ultra"` this store silently costs 228 tiles;
against the wired `compose4_top`'s 327.5 that is 82.7% of the device **before**
the 171-tile gain image, which would put it over. With `ultra` the BRAM column
does not move at all and it spends 32 of 320 idle URAM. **The attribute is the
difference between fitting and not, and it is the first use found for the
URAM.**

**Predictions scored: 32 URAM was EXACT, 256 RAMB36 was WRONG (228).** The
width-quantisation rule bit the URAM case and not the BRAM case, and there was
no way to tell which in advance -- two methods, one right each. The census is
what settles it, not either rule.

**MEASUREMENT TRAP, recorded because it reached a CSV:** the census script's
WNS comes from a `regexp` over `report_timing_summary` with `0.0` as the
initialiser. It matched for `ultra` and NOT for the other two, so those rows
carry `wns 0.0, fmax 200.0` -- **the default wearing the shape of a
measurement**, in the same column as a real one. Only the `ultra` timing figure
is quotable. Two more columns (`LUTasRAM`, `LUT`, `FF`) are filter bugs
(`REF_NAME =~ RAM*` also matches `RAMB36E2`) and were discarded rather than
reported.

**AND THE HBM SIDE IS ALREADY ALLOCATED, which de-risks the rest.**
`tools/hbm_map.py::arena_sizes()` derives, and `tools/pack_model_fk33.py`
already reserves, `gdn_state_mant_bytes_per_layer = 1,048,576` /
`gdn_state_exp_bytes_per_layer = 4,096` / 24 layers / 25,264,128 B total.
**1,048,576 bytes is 8,388,608 bits: the same number measured from the shape
functions, to the byte, by a different tool for a different purpose.** Three
independent derivations now agree. The architecture was always "the state lives
in HBM"; only the RTL that moves it is missing. **Except the conv tap history,
which nothing reserves** -- 49,152 B per layer, 1.125 MB total -- and it must
be added to `arena_sizes()` rather than quietly placed, because this address
space has already had one silent two-allocator collision whose symptom was a
wrong token.

**The new memory has an oracle, and three of its first four mutants SURVIVED.**
`sim/tb_gdn_state_mem.vhd` compares against a model coded from `llama_top`'s
`stmem_p`, not from the DUT. First version: 2,825 checks, 0 mismatches, and
nearly worthless. M2 (transposed read address) died; **M1 (write before read),
M3 (read ungated) and M4 (write ungated) all lived.** M1 lives correctly and
permanently -- `mem` is a SIGNAL, so read-old is structural and the ordering
this file's header claimed was load-bearing is not, which corrected the RTL
comment. M3 was invisible because the comparison only looked at cycles where
the reference had also read; M4 because the stimulus let the write port HOLD
while `w_en` was low, so the unwanted write was a no-op. **A stimulus that
holds its inputs cannot see a missing enable.** Hardened: 4,323 checks, M2/M3/M4
all dead. **Attribution control: the two fixes are orthogonal** -- every-cycle
comparison alone catches M3 and not M4 (130 vs 0), scrambled ports alone catch
M4 and not M3 (1,325 vs 0). Neither alone would have been enough and it would
have looked improved either way. **Bench reach measured, not assumed: it runs
at 65,536 words (real DIM, real lanes, half the head count) under a 6 GB cap
and DIED at the real 131,072 under 8 GB. No simulation here has exercised this
memory at the 9B head count.**

**ALSO LANDED, and its attribution control is the interesting part:** `f_lost`
had **three drivers** (`ap`, `bp`, `cp` each assigning the resolved
`std_logic`). MEASURED with a standalone three-driver GHDL model: one driver
at '1' against two initial '0's resolves to **'X', not '1'**. Now one signal
per adapter, OR-ed once. **The attribution control says this earns NOTHING in
detection:** mutant M1 (`bp` reports a lost beat on every y element) kills
`tb_llama_top`, `_real`, `_normw` and `_seq` identically with and without the
split, because those rows assert `err_lost_beat = '0' severity failure` and 'X'
is not '0'. It is here because the reported VALUE becomes correct and because
**multiple drivers are not synthesisable**, which blocked lifting any adapter
onto the card. My first draft of the comment claimed it fixed a dead `fail`
counter in `tb_llama_top_smp`; that claim is **wrong and was corrected in
place** -- that row runs `B_BEHAV => true`, so `ga_real` is its only driver and
the value there was already a clean '1'. The fragility was latent, not live.


Written to survive a context compaction. Every figure here is MEASURED unless
labelled, and several supersede figures still standing elsewhere in this file.

### 2026-08-31, dispatcher (new session): the overnight session died on the API limit one message before landing GAIN16. This entry catches the board up

**How the session ended, and why the tree was dirty.** At 00:42:52 MDT the
weekly API limit fired **one message after the dispatcher resumed TRACK GAIN16
with "Block on swcb properly, then land".** GAIN16's agent failed before it
could commit; ROUTE2's agent failed at 00:51 with all of its commits already
in; the gate-floor teeth Run B background job was killed at 01:05. So from
`3b2003c` (the entry below) to now, the record lived only in `git log` and in
`docs/debugging/`, and GAIN16's entire result sat uncommitted in the working
tree. **A second harness may enter this repo (Oren, 00:30 UTC): the tag
`v2.0-fk33-matvec` at `3f1235c` is the known-good rollback point Oren asked
for.** `docs/PLAN_TO_FIRST_INFERENCE.md` (`3f1235c`) is the standing plan.

**TRACK GWTWO COMPLETE (`21db25b`, `93ddac7`, `c3a2f01`).** The gain image at
`GW = 1` is **135 RAMB36 / 141 tile**. ROUTE2's composed BRAM gap is measured
at **52, not 51** (`253.5 + 171 = 424.5` against 372.5). The image's aspect
ratio is worth 36 tiles and is free. Full gate on the landed tree green.

**TRACK ROUTE2 COMPLETE. STEP 2 IS ANSWERED, WITH A RETRACTION ATTACHED**
(commits through `48633e5`; write-up
`docs/debugging/2026-08-30_route2-composed-route-with-both-levers.md`).
The composed A+B+C+D **ROUTES with both levers on** (`166cbd4`), and then the
controls came home: the `CB_STYLE=regs` control routes too (`5b10182`), the
second uncontrolled variable was the PBLOCK, and **"the levers made it route"
is withdrawn** (`53d4619`); the double control reproduces the killed
configuration to four exact columns (`48633e5`). What stands, all MEASURED:
lever C buys **fit and timing**, not routability; the routed design is now
**DSP-bound at 2,177 of 2,700 = 80.63%** of `pb_core` against LUT's 68.33%;
**BRAM 253.5 of 372.5, i.e. +119.0 headroom without the gain image and -52.0
with it.** The whole-composition route with a non-empty `NORM_W_IMAGE` has
**never been drawn by anyone** and is the next Vivado question after the
gain-store form settles.

**TRACK GAIN16: the 16 tiles are closed by 20, and the closure is being
re-verified before it lands.** Write-up
`docs/debugging/2026-08-31_gain16-closing-the-last-bram-tiles.md`. The gain
store becomes an **11-bit codebook index (99 RAMB36, MEASURED as the `sw11`
lossy probe) plus a 1,567-entry codebook built at elaboration from
`norm_w_9b.hex` itself** -- one input, no second image, no drift pair. Zero
DSP (41 at all six points) and zero WNS (+0.971 at all six). The 14-bit
alternative is a measured negative: 126 tiles, 9 saved, **7 short**. The
mechanism is **9 RAMB36 per bit of stored word** at three of four widths, and
splitting widths across arrays buys exactly nothing (`sw9_4_1` = 126 = `sw14`,
47% more synth time). **Do not retry either.**

**The elaboration-form decision GAIN16 left open is DECIDED by this
dispatcher: the record-free form ships.** The record form (`cbb_t`) sat in
Vivado elaboration > 15 min pinned at its 11G cap, undrawn; the record-free
form (`cb_mark`/`cb_count`/`cb_map`/`cb_rom`, four plain-array functions) is
DERIVED to produce identical constants, PASSed the 266,240-element oracle as
`cb_clean`, and is now installed in `rtl/llama_top.vhd`. The head-to-head
elaboration draw is a **documented non-goal**: the decision does not depend on
it, because the record-free form is strictly cheaper to elaborate at identical
output. GAIN16's own open item asks for the comparison before anyone *quotes
an elaboration time*; nothing here quotes one.

**Three verifications were dispatched with pre-written branches; two have
returned, one is in flight:**

- **Teeth Run B: RETURNED with exactly the required verdict.** Clean archive
  of `93ddac7` with `BASELINE_PASS=104` printed **OVERALL PASS 103 FAIL 0 and
  REGRESSION: FAIL, "BASELINE DROP: 103 passing, expected at least 104."**
  The floor is shown to discriminate, not merely to match, and the raise
  landed as `0c16b27`. Run A (floor 103, same archive) had already PASSed
  with "matches the recorded floor". The landing is complete: `c094867`,
  `a433bab`, `197e813`, `45cd94e` (ROUTE3's generator option), `0c16b27`.
- **Oracle on the installed file: RETURNED, and the swap is verified.**
  `GAIN16_ORACLE_ROW cbland mutant=none verdict=PASS rc=0 compared=266240
  mismatched=0 never_written=0 wrong_nidx=0`.
- **`cbland`: RETURNED, and the `sw11` probe did not mislead.** The shipping
  record-free file measures **RAMB36 99, RAMB18 12, tile 105, DSP 41, LUT
  5,155, FF 2,351, WNS +0.971 (248.2 MHz), synth 334 s, peak RSS 13.62 GiB
  under a 14G cap** (an honest peak, under its cap). Elaboration completed in
  minutes, where the record form sat > 15 min at its cap undrawn -- the swap
  is the fix, not merely a workaround. **Margin: 253.5 + 99 = 352.5 against
  372.5, i.e. +20.0, MEASURED on the shipping design, not on the probe.**
  Landed as `c094867` (RTL), `a433bab` (four closure repairs), `197e813`
  (write-up and artefacts).

**TRACK ROUTE3 is in flight on the workstation lane, run by the dispatcher in
session (no subagents for RTL tracks).** The question: does the composed
A+B+C+D route with a NON-EMPTY `NORM_W_IMAGE`? Every composed draw before
this one carried the synthetic ramp, so the composed BRAM figure never
included the gain store. The mirror is ROUTE2's accepted configuration
exactly (`C4_PBLOCK=1` in `pb_core`, CB_STYLE=distributed, HEAD's `gvr`
extraction) plus one changed variable: the real 266,240-line image, md5
`69f614a1515e1160f5dc9e8a9e72fdc3`, baked in by `45cd94e`. Tree `bebd952`.

**Pre-registered branches, so the answer only has to be classified:**

- **Routes, 0 nets with routing errors, 0 DRC errors.** The composition fits
  WITH the gain store. The fit question is fully closed and STEP 3 (the card
  top, row N3) is the whole remaining critical path.
- **Routes but WNS negative.** Routability holds; timing is a separate lever
  hunt. Named suspect from LEVERC48 CORRECTION 2: `CB_BCAST` (WNS reverses
  with lane count, -0.269 at 1,536).
- **Does not route.** The deliverable becomes WHERE: congestion by region,
  which nets, and whether ROUTE2's DSP-saturated windows moved.
- **BRAM over 372.5 in `pb_core`.** The OOC +20 margin did not survive
  composition; the no-sharing assumption between separately-measured units
  breaks. Report the measured deficit.
- **Elaboration time explodes at composed scale.** The record-form hang was
  OOC, the record-free form elaborated in minutes at OOC; if the composed
  synth sits in elaboration anyway, that IS the result and it is reported.

**TRACK ROUTE3 COMPLETE (`8eaaf18`). Branch 2 fires: routes but WNS
negative.** `nets=3,526,125 errors=0 unrouted=0 partial=0`;
**BRAM 351.5 against 372.5 in `pb_core` = +21.0 headroom** -- the OOC +20
margin survives composition, one tile better than the paper sum. DSP unmoved
at 2,177; LUT +109, FF +344 against ROUTE2's ramp. **WNS -0.815 against
-0.575, failing endpoints 9,056 -> 25,860, TNS -876 -> -7,437, hold clean.**
The 200-path census on the routed checkpoint puts **162 in `matvec_core`,
28 in the attention array, and ZERO in `d_norm`**: the gain codebook is no
critical path; the regression lands on the lever-C / `CB_BCAST` family
LEVERC48 already named. **The fit question is closed with the gain store
in.** The timing lever hunt is its own track and its quarry is unchanged.
Write-up: `docs/debugging/2026-08-31_route3-composed-route-with-the-gain-image.md`.

**The final-tree gate is GREEN.** Clean archive of `bebd952` (codebook,
closure repairs, generator option, floor raise, this board entry):
`OVERALL PASS 103 FAIL 0, baseline: 103 passing, matches the recorded floor
of 103, REGRESSION: PASS` (`llama-finalgate.service`, log at
/mnt/storage/llama-finalgate/gate.log).

**Operational notes for the next session.**

- **`hw/design_mv_generated.tcl` is dirty in the working tree and that is NOT
  this project's business.** The hunk sets `FIFO_DEPTH 2048, MAXOUT 8` on the
  AXU3EG `mv` block design (the OLD board, Zynq MPSoC era); mtime 2026-08-23,
  predating the overnight session. Provenance is Oren's own AXU3EG
  experimentation. It is deliberately left uncommitted and unreverted: do not
  sweep it into anything, and do not "clean" it without asking Oren.

- **`systemd-run --user --scope` attaches the scope's lifetime to the
  CLIENT.** Killing the client kills the scope. This is what killed teeth Run
  B twice (the overnight session's `borip14fp`, and once more under the new
  dispatcher). For detached jobs use transient **services**
  (`systemd-run --user --unit=...` without `--scope`), which return
  immediately and survive the launcher.
- The card was rebooted and reloaded with `fk33_pcieep_eng.bit` by Oren on
  2026-08-30 ~14:17 MDT and holds the verified striped image.
- Oren's standing instruction remains **two agents, one per Vivado lane**.
- **The gate-floor teeth for the 103 raise is only half proven** (Run A
  matched; Run B was killed mid-run) until the service above returns.
- GAIN16 found **eight dead hand-maintained source closures** across four
  tracks, two of them via a one-second textual invariant
  (`hw/fk33/results/gain16_2026-08-30/closure_audit.py`). The four fixes are
  part of the uncommitted landing. The generalisation, measured 8 for 8:
  **copying a list rotted; borrowing one did not.**

### 2026-09-02, in session, no subagents: STEP 3 is three increments in and the card top is token-identical to the oracle

**Oren's ruling stands: NO subagents for RTL work**, and none were used. The
two Claude subagents that were running died on the weekly rate limit; the
DeepSeek harness's own subagents produced a 5,363-line card-top draft that
was quarantined unreviewed and has now been DELETED.

**STEP 2 is closed and the fit question with it.** TRACK ROUTE3 (`8eaaf18`,
by the harness) routed the composed A+B+C+D **with the real gain image in**:
`nets=3,526,125 errors=0 unrouted=0`, BRAM **351.5 of 372.5 in `pb_core`,
+21.0 headroom**, DSP unmoved at 2,177, WNS **-0.815**. The 200-path census
puts 162 paths in `matvec_core`, 28 in the attention array and **zero in
`d_norm`**, so the gain codebook is not a critical path and the timing
regression belongs to the lever-C / `CB_BCAST` family LEVERC48 already named.
**Fit is answered; timing is the separate lever hunt it always was.**

**STEP 3, increments 1 to 3a, all landed in session:**

| increment | file | evidence |
|---|---|---|
| 1 | `rtl/region_mem.vhd` | 6 mutations, **5 bite**, `F` does not and cannot |
| 2 | `rtl/a_desc_adapter.vhd` | 2,184 checks, **9 mutations, 9 bite** |
| 3a | `tools/gen_cardtop.py` | **token-identical to `llama_top`** |

**THE HEADLINE: `R_X(0) = -12739 hash(R_X) = 38863` from BOTH `llama_top` and
the generated card top**, same bench, same generics. MEASURED separately, one
run each.

**D1 was CORRECTED, not overturned** (`2aac831`): the card top is still a
separate file and `llama_top` is still the untouched oracle, but the fork is
GENERATED. `llama_top` is 5,684 lines and the card's decisions touch about
**8.6%** of it, so hand-copying the other 91% is a transcription task with a
defect rate -- which is exactly what the quarantined 5,363-line draft was.

**Three findings that only composition could produce, and the third is the
important one:**

1. **`region_mem` dropped a 7-bit mask.** `llama_top` indexes the group ports
   as `v_reg_a(6 downto 0)`; `region_mem` takes `unsigned(7 downto 0)` and
   never masks. `NREGION` is 14 so bit 7 is never set in normal traffic --
   **which is why `region_mem` passed its own bench with 5 of 6 mutations
   biting and was still not a drop-in replacement.** Its bench drives its own
   ports and cannot see what `llama_top` does to those signals first.
2. **`llama_top.vhd:1301` documents the wrong memory semantics.** It says
   `write-first, so an in-place overtake is visible`; `mem` is a SIGNAL, so
   reads see pre-write data and the overtake is exactly what is NOT visible.
   `region_mem` matches the CODE. **Recorded, deliberately NOT fixed:** a
   one-word edit to the oracle during a fork makes a token-identity result
   unattributable.
3. **The identity bench's own PASS was NOT an identity result.** It reports
   `R_X` bit-identical **across descriptor-latency points**, which is
   SELF-consistency and is satisfied by a consistently-wrong card top. The
   generator now injects a pin against the landmark `llama_top` itself
   produces, read from `sim/cardtop_ident_expect.txt`, and with that file
   absent it injects an unconditional FAILURE so an unpinned bench cannot
   report success.

**The gate row `sim:cardtop` is the point of the generator, not an extra.**
It runs `gen_cardtop.py --check --bench`, regenerating and diffing, and sits
beside `sim:ipsync` which exists for the identical drift on `ip_repo/*/src`.
Teeth-checked four ways: clean tree OK; hand-edited output STALE; upstream
moved STALE; **anchor vanished, rc 2, ABORTS naming the anchor**. That last
is `ooc_normadapt_extract.py`'s recorded failure mode.

**Floor: `BASELINE_PASS` 99 -> 103 (`0c16b27`, harness) -> 105 (`fcee6df`).**
Both measured on `git archive`, never the working tree, which carries
untracked `sim/tb_*.vhd` the gate auto-discovers; GWTWO's `PASS 111` was real
and unreachable. Increment 3a adds two more rows and the floor must be
re-measured, not incremented.

**NEXT, in order:** increment 3b, the A binding (D1/D2) and the `w_active`
gate (D4) into the generator; then item 4's bench at the REAL shape; then
STEP 4, the seam to D; then STEP 5, the token. The timing lever hunt
(-0.815 WNS, `CB_BCAST` suspect) is queued and its cheapest first move is a
placement-directive sweep on the ROUTE3 checkpoint.

### 2026-09-02 evening, in session, no subagents: the region file infers ZERO BRAM, and D3's "~34 RAMB36" was never implemented

**The fit question for the card was open and nobody had ever synthesised the
region file.** `region_mem` is now instantiated in `compose4_top --wire` with
`HOST_WINDOW => false` (the card configuration) and the wired top elaborates:
`C4_DONE elab rg`, 0 errors, 436,048 cells, 40,210 ports. The UNWIRED output
is byte-identical to the committed `hw/fk33/rtl/compose4_top.vhd`, verified by
regenerate-and-diff, so TRACK ROUTE3's numbers stay comparable.

**MEASURED, OOC at the real 9B shape on the BC-250: 0 RAMB36, 0 RAMB18,
0 URAM, 91,073 LUT of which 81,920 are LUTRAM.** The design note carried
"~34 RAMB36 -- cheap" as a DERIVED figure and concluded the card "fits inside
the same envelope". It is not 34 tiles, it is zero tiles and 91k LUTs, which
would have taken pb_core from 67.3% to about 90.7% LUT occupancy.

**TWO INDEPENDENT DEFECTS, and both must be fixed:**

1. **The THIRD READER blocks inference.** Each bank is read at three sites --
   the element read plus the group's `x` and `e`. Vivado's own words: with two
   readers `[Synth 8-3971] recognized as a true dual port RAM template`; with
   three, `[Synth 8-6849] Infeasible attribute ram_style = "block"` on all
   fourteen banks and a LUTRAM fallback. A TDP BRAM has two ports.
2. **The per-region sizing was never implemented.** `bank : bank_t` is MAXW
   deep for all fourteen regions, so `R_BETA` and `R_ALPHA` (`val_heads`
   elements each) get the same 1,536-word array as an FFN bank.

**"~34 RAMB36" WAS NEVER WRONG -- IT WAS NEVER BUILT.** 9,480 words x 128 bits
is 33.7 RAMB36, exactly the note's number. It described D3's intent; the code
declares a uniform array. A DERIVED number and the RTL disagreed for two days
because nothing had ever run the tool on this file.

**THE FIX, MEASURED:**

| configuration | BRAM | LUT | LUTRAM |
|---|---|---|---|
| as committed (uniform, 3 readers) | **0** | 91,073 | 81,920 |
| sized per region, 3 readers (R8) | **0** | 84,839 | 76,800 |
| uniform, 2 readers (R6) | 224 | 2,913 | 0 |
| **sized + 2 readers (R9)** | **100** | **2,918** | **0** |

R8 proves the two defects are independent. **R9 is the target: 100 tiles
against 224.5 spare, and 91,073 LUTs returned.**

**METHOD, and this is the reusable part.** EIGHT probes that ADDED features to
a working control (three read ports, byte-enable write, bank-in-generate,
separate write process, guarded read, and the byte-enable/multi-read
combinations) ALL INFERRED BRAM and found nothing -- a search that adds to a
passing control can only ever exonerate. DELETING from the failing file found
it in three runs, because a bisection needs an endpoint that fails. And the
tool control should have been probe ONE, not probe FIVE: four `region_mem`
variants were synthesised on the untested assumption that Vivado would infer
BRAM here at all.

Full account, twelve rejected hypotheses under "do not retry", the measurement
traps, and my own 47%-wrong tile estimate:
`docs/debugging/2026-09-02_region-mem-zero-bram.md`.

**CORRECTION to the cardtop design note 3.5.** It reads ROUTE3 as "BRAM
351.5/372.5", +21.0 spare. `pbutil_c3img_routed.rpt` says
`Block RAM Tile | 351.5 | ... | 576 | 61.02`, so the pblock holds **576**
tiles and **224.5** are spare. Where 372.5 came from is not established.

**RESOLVED THE SAME EVENING (`1da4a71`, `ca99235`). THE REGION FILE IS BRAM
AND THE FIT QUESTION IS CLOSED:**

| | this morning | now |
|---|---|---|
| BRAM | 0 | **100 RAMB36** (224.5 spare) |
| LUT | 91,073 | **3,496** |
| LUTRAM | 81,920 | **0** |

87,577 LUTs returned. The region file would have taken pb_core from 67.3% LUT
to about 90.7%; it now leaves it roughly where ROUTE3 measured it.

**The pad contract has teeth, and design-note 11.4's PRESCRIBED FIX WAS
WRONG.** The bench it asked for was written -- element writes past every
region's size, asserting region_mem's contract and not llama_top's -- and `F`
STILL SURVIVED. The reason is an OBSERVABILITY limit 11.4 missed: the write
guard and the read guard are REDUNDANT, so with a MAXW-deep array no stimulus
alone can discriminate `F`. What made it bite was the SIZING: with `bank`
declared `0 to NW-1` an unguarded pad write is an out-of-bounds index. `F` and
`G` went from "does not bite" to KILLED; `G` needed its own stimulus because
the two writers have SEPARATE guards.

**The group-read merge is NOT the merge that broke the hold contract**, and
the difference is measured: mutant `J` reproduces the old merge and the bench
still KILLS it on `el_rdata`. `x` and `e` are both gated by `r_en` alone so
they always update together; the element read fires on `el_ren` and stays
separate.

**PREVIOUSLY NOT LANDED, now landed:** the `region_mem` fix itself. Per-region sizing
makes an out-of-range write a real hazard rather than a theoretical one, and
the pad contract is still UNVERIFIED (mutations F, G and F+G all fail to bite
because the bench never drives an out-of-size access). Getting to two readers
means merging `x`/`e`, which `region_mem.vhd:286-293` records as having BROKEN
the hold contract once already. Both need bench work first.

**NEXT:** close the pad-contract gap in `sim/tb_region_mem.vhd`, then land
sizing; then the `x`/`e` merge through a registered SIGNAL (not the variable
form, which infers no BRAM) re-earned against the bench; then re-measure; then
the B/C data movers; then P&R of the wired top.

### 2026-09-02 late afternoon, in session, no subagents: the B/C seam landed and found a shipped bug in the A seam

**`rtl/u_seam.vhd` (130 lines) is the D-to-unit control seam, and it serves
BOTH B and C.** They are nearly the same shape and the differences are exactly
what it is parameterised over, read off the RTL rather than assumed: B's `done`
is a one-cycle PULSE with THREE error bits (`gdn_block.vhd:625,162-164`), C's is
a LEVEL held until its own `done_ack` with ONE `err` (`attn_block.vhd:1799`).
The seam latches `done`, emits `unit_ack`, and takes a single `unit_err` that
the glue reduces. Both are instantiated in `gen_compose4_top.py --wire`, on
slots `U_B` and `U_C`; only `U_V` and slot 3 remain tied NOT ready.

**IT FOUND AN EPOCH BUG THAT HAD ALREADY SHIPPED IN `rtl/a_desc_adapter.vhd`
(`3a145fd`), BEHIND A BENCH REPORTING 2,496 CHECKS AND 0 MISMATCHES.** Both it
and the first draft of the seam latched `job_epoch` at the issue edge.
`seq_desc_fetch` bumps `epoch_r` ON that edge (`:790`) and compares the echo
against the bumped value at `S_COMPLETE` (`:834`), so **every completion would
have been rejected as stale on the card**. `llama_top`'s seven adapters all
latch on `job_issue` instead, and `llama_top:3047` says so in as many words:
"Latch at job_issue. NOT at u_start". The rule existed and was lost by writing
against a port list rather than against the working code.

**The adapter's bench returned PASS for the bug AND PASS for the fix**, because
it held `job_epoch` constant across each job, so the two latch timings read the
same value and no timing error could be expressed. Both files are fixed and
both benches now kill it: 312 mismatches of 2,496, and 200 of 200.

**Two checks were true, correctly computed, and UNREACHABLE.** A generated
epoch counter SURVIVED (D's `epoch_r` is global across five units; the bench
only ever issued to one, so a per-job counter stayed in lockstep), and the error
latch SURVIVED (no job in the stimulus ever reported an error). Foreign epoch
bumps and an error stimulus were added; both mutants now die, and the bench
REFUSES to pass a run where either stimulus count is zero.

Full account, 10 mutations, 5 attribution controls, and the mutations that did
NOT bite under their own names:
`docs/debugging/2026-09-02_epoch-latch-off-by-one.md`.

**`compose4_top --wire` NOW ELABORATES: `C4_DONE elab seam6`, 0 errors,
429,938 cells, 39,700 ports.** It never had before. Three integration defects
that no unit bench could structurally see, all found by pushing it through
Vivado:

1. `NUNIT` and `EPOCH_W` were undeclared. `NUNIT` now comes from
   `llama_map_pkg`; `EPOCH_W` is LIFTED from `seq_desc_fetch`'s own generic
   default, with an abort if D ever stops declaring it.
2. Instance label `u_a` hid the constant `U_A` -- VHDL identifiers are
   case-insensitive. Labels are now `seam_a`/`seam_b`/`seam_c`.
3. `LITE_AW => 8` against the engine's 12-bit `s_axi_awaddr`. **The adapter's
   own bench cannot see this**: it drives a slave model of the adapter's chosen
   width, so it agrees with the adapter and not with the engine. `LITE_AW` is
   now lifted from the engine's parsed port.

**SCOPE CORRECTION, and it is the important line here.** `gdn_block` and
`attn_block` have NO region-facing ports. `llama_top`'s per-unit blocks are
DATA MOVERS, not handshake converters, and they are large: `ga_real` 353 lines,
`gb_real` 635, `gcr` 942 (measured by generate label). So `u_seam` covers the
CONTROL contract -- the part that is shared, the part D enforces, and the part
where the epoch defect lived in both files -- and roughly **1,600 lines of
per-unit data movement remain for B and C alone**. "Add seams for B, C and V"
understated the wiring work.

**`a_job_index` is a top-level PORT, deliberately not wired.** The obvious
source, D's `job_ordinal`, is wrong twice: it is 8 bits so it cannot address the
311 A jobs at all, and `llama_top` uses it as `wsyn(r, c, j_ord)`, a synthetic
weight selector in the simulation model. Wiring it would have elaborated
cleanly and produced wrong descriptors on the card. Nothing in the RTL decides
this yet, so the decision stays visible.

**A RELATED HAZARD, NOT YET A BUG:** `a_desc_adapter` also latches `u_index` at
the `u_start` edge. `llama_top:3047` says every `job_*` field still decodes the
PREVIOUS bank there, not only the epoch. It is safe today only because
`u_index` is a top-level input and is not sourced from D's decode. A warning is
now at that latch.

**NEXT, in order:** the region file into the wired top (`region_mem` with
`HOST_WINDOW=false`) and the B/C data movement; the descriptor-index decision;
then P&R of the WIRED top, whose numbers do NOT carry over from ROUTE3; then
the token check against `ref/run9b --acts bfp`. The composed bench that drives
the REAL `seq_desc_fetch` through the real seams into the real units does not
exist, so the seam is currently verified against a MIRROR of D, not against D.

### 2026-08-30 late morning, dispatcher: two lanes, both full, and the budget written down first

**Oren's standing instruction for this stretch: TWO agents, not four.** One per
Vivado lane. The REFILL RULE's "four concurrent tracks" is a target for keeping
the backlog moving, not a licence to exceed the machine, and it is explicitly
overridden here.

**THE BUDGET, stated before dispatch rather than after, because that is the
whole point of the rule:**

| resident / expected | GiB |
|---|---:|
| `llama-server`, permanent | 18.0 |
| box total | 31.0 |
| **available to this project** | **~13.0** |
| TRACK ROUTE2, composed `route_design` -- MEASURED leaving `free physical = 233 MB` while ALONE | 17.3 alloc / 11.9 RSS |
| TRACK GWTWO, on the BC-250, not on this box | 0 here |
| **left on the workstation for anything else** | **~1** |

**So the workstation is FULL with one job, and that job is ROUTE2.** The gate
itself is only 2.13 GiB (GATEGREEN, MEASURED, and it retires the 20.9 GiB figure
this dispatcher quoted all night), **but 17.3 + 2.13 against 13 is exactly the
arithmetic that hung the box on 2026-08-30.** The `BASELINE_PASS` correction
below is therefore DEFERRED, not forgotten: it requires measuring the floor,
measuring the floor requires running the gate, and the gate does not fit beside
a composed route. It runs when ROUTE2's lane frees.

**TRACK ROUTE2 dispatched, workstation lane, STEP 2 of `docs/PLAN_TO_FIRST_INFERENCE.md`.**
The question is the one everything downstream is waiting on: **does the composed
A+B+C+D design ROUTE with both levers on?** Both levers are landed and measured
at the real geometry (`47c9d9c`, `a4828ab`); **nobody has put them together and
asked the router.** Until that verdict exists, every schedule below is
unfalsifiable.

**The complication found at dispatch time, which changes what STEP 2 IS:
`compose4_top` picks up NEITHER lever automatically.**

- Its `a_eng` reaches `matvec_int4_desc_axi`, which after LEVERC48 **defaults
  `CB_STYLE` to `"regs"`.** Drawing it unchanged silently draws the un-levered
  design and would have looked like a clean negative result.
- Its `d_norm` is `ooc_normadapt`, **GENERATED by `sim/ooc_normadapt_extract.py`
  from `llama_top`'s norm region -- and RMSWIRE reports that extractor now
  ABORTS against HEAD** (`--shift` finds no `xw`; the flat ports it extracted are
  gone). **A `compose4_top` whose `d_norm` is a stale extraction of a design that
  no longer exists is not a measurement of anything.**

So ROUTE2 owns fixing the extractor (or instantiating the real thing, its call,
stated either way) and forwarding `CB_STYLE` through the generator
`hw/fk33/gen_compose4_top.py` -- **never the generated output** -- before it can
place or route.

**Pre-written branches, so the answer only has to be classified:**

- **Routes, 0 nets with routing errors, WNS reported.** STEP 2 closes; the
  workstation lane goes to STEP 3, the card top (N3), and the BRAM sum becomes
  the only open fit question.
- **Routes but WNS is negative.** Still closes the existence question, which is
  the valuable half. Timing is a separate lever hunt and `CB_BCAST` is now the
  named suspect (LEVERC48 CORRECTION 2: WNS **reverses** with lane count,
  -0.269 at 1,536).
- **Does not route.** The deliverable becomes WHERE: congestion by region, which
  nets, whether it is still net-dominated, and whether the 33,767 failing
  endpoints moved. **"It still does not route" without that is barely a result.**
- **Does not route AND the endpoints barely moved.** Then the two levers were
  the wrong axis and the pblock squeeze that PLACED at 85.4% of the die (paying
  0.602 ns) becomes the live path rather than the fallback.

**TRACK GWTWO continues on the BC-250**, drawing the `GW` curve for the norm gain
image. **BRAM is short by 51 tiles** (composed 246.5 + `gvr` 177 = 423.5 against
372.5 inside `pb_core`), and **45 of the 51 are the gain image.** Its constraint,
carried into the brief: the load-rate margin **is** `GW`, so `GW=1` leaves no
margin against a race RMSWIRE proved is invisible for **1,030 cycles, [977,
2006]** -- not the 116-cycle window this dispatcher asserted and RMSWIRE
corrected.

ROUTE2 draws with `compose4`'s long-standing **empty**-gain-image convention
(`NORM_W_IMAGE = ""`), so its BRAM total does **not** include the gain table.
**The two tracks are therefore measuring complementary halves of the same fit
question and must not be added carelessly.** If ROUTE2 routes on LUT but the
BRAM sum cannot fit, that is GWTWO's problem, and it is already dispatched
against it.

### 2026-08-30 08:30, added by the dispatcher: three landings and one new constraint

**TRACK RESETLAND landed (`8b7eefe`).** All three of RESETGUARD's orphaned
changes are in, plus a third file the brief did not know about. Generated
artefacts MEASURED byte-identical over 676 tracked files. The reset-topology
guard now has teeth with the attribution control run on every row: **7 dangerous
rows all abort, and `GUARD OFF` is `PASS` on every one**, so the new check earns
all seven kills alone rather than inheriting them. Two rows corrected the agent
rather than the guard, and are recorded as such. Remaining hole, stated as
fail-OPEN: the guard reads the block design and **cannot see the RTL**, so a
soft-reset bit added inside `fk33_engine.vhd` or `llama_top.vhd` leaves it green.

**TRACK RMSMUX draw 1 is in, on the BC-250, and every pre-registered falsifier
held.** This is the largest area lever measured on this project so far:

| quantity | predicted | MEASURED `mem_d1` |
|---|---|---:|
| `ARG` census root (the x and w reads) | -- | **443**, from **17,916** in the flat unit |
| CLB LUT | 4,798..7,823 | **4,825** |
| MUXF7 / MUXF8 | 0 / 0 | **0 / 0** |
| CLB FF | below 1,700 | **1,629** |
| DSP | 40 | **40** |
| WNS @ 5.0 ns | not predicted | **+0.971**, 248.2 MHz |

**FINAL, all three draws in, TRACK RMSMUX complete** (`5152e91`, artefacts
`hw/fk33/results/rmsmux_2026-08-30/`). Against its own same-session control,
same flow, one tool at a time:

| | `rmsnorm_rs` control | `rmsnorm_rs_mem` | delta |
|---|---:|---:|---:|
| CLB LUT | 40,934 | **4,825** | **-36,109, -88.2%** |
| CLB FF | 67,196 | **1,629** | **-65,567, -97.6%** |
| MUXF7 | 17,408 | **0** | **-17,408, -100%** |
| MUXF8 | 8,704 | **0** | **-8,704, -100%** |
| BRAM tile | 0 | 6 | +6 of 425.5 free |
| DSP | 40 | 40 | 0 |
| WNS @ 5.0 ns | +1.675 | +0.971 | -0.704 ns, still meets 200 MHz |

**Scatter is `1.0000x`: the two identical-command draws are byte-identical in
every CSV field AND their censuses hash the same** (`2c85f5c4...`), agreeing
down to per-root primitive tallies. **Operationally, and this is the part the
fit table needs: SCATTER's 1.55x must NOT be applied to this 4,825.** The
pre-registered hypothesis (that SCATTER's spread came from register merging on
a foldable constant ROM, and a memory-backed unit has no fold to perform) is
**unrefuted, not proven** -- two draws, one box, one session.

The control's own census settles the attribution **on the shipped file**, not on
a transform of a superseded one: `ARG` 17,916 + `sq` 17,474 = **86.5% of the
shipped unit's LUT and 100.0% of its MUXF7 and MUXF8**, both agreeing with
LUTDIET's census to the LUT. The saving exceeds the 35,390 of read mux because
the memory form also removes `gow.o` (WRITEDEC's write decode, 2,356).

**Still open and NOT derivable from the above: the COMPOSED number.** Nothing
here is placed, routed or composed, and TIMING's composed baseline was drawn
with a foldable `w_mant`.

The 1024:1 read mux is gone, measured rather than argued: **no root anywhere
carries a single MUXF7 or MUXF8, and there is no `sq` root at all.** The FF
figure is the one worth pausing on, because it was a mechanism-level prediction
and not a curve fit: three dropped registers, `o_we` + `o_wa` + `o_wd` = 75
flops predicted, **71 measured**. Two independently derived transforms of the
same file agree root for root to the LUT on everything except the one thing that
differs between them. Scatter conclusion is held until `mem_d2` returns, as
pre-registered.

**NEW CONSTRAINT, found by TRACK NORMURAM, and it changes a composition
everyone assumed was free.** Section 12 of the RMSMUX write-up reads NORMURAM's
gain-loader word stream as free to reuse against `rmsnorm_rs_mem`'s bank port.
**It is free in ORDER and in GRANULARITY but NOT in RATE.**

- Today: budget to `r_go` is `NN+4`, load is `NN/GW+1`, margin **GW = 4.0x and
  independent of shape**. A bench at hidden 64 exercises the ratio a build at
  4096 has.
- Composed: `w_we`/`w_waddr`/`w_wdata` is one 16-bit word per cycle, so the load
  becomes `NN+2` and the margin becomes about **`1 + 1/LANES`**: 1.26x at the
  shipping `NORM_LANES = 4`, **1.07x at `NORM_LANES = 16`**, which
  `rmsnorm_rs_mem`'s own sweep covers as legal.

DERIVED by NORMURAM, reviewed for shape by the dispatcher, **not independently
re-derived**. The conclusion does not turn on the exact `S_RAW` arrival term:
any margin that depends on `LANES` has already lost the property that made the
current form checkable.

Second and worse for checking: the reader walks LANES elements per cycle against
the writer's one, both ascending, so "fully resident before use" stops being a
phase separation and becomes a race. **The deadline moves from `r_go`, which
`gvr` can see and `wbusy` checks today, to the unit's internal `S_RAW`, which
`gvr` cannot see at all.** NORMURAM's U6/U6x pair is direct evidence that this
fault class leaves the values correct and every landmark unmoved.

**Ruling: the composition is sequenced AFTER NORMURAM's six points land, and the
`nw_empty` = 49,654 anchor is not retired** -- NORMADAPT, NWROM, NWFIX and
NORMURAM all quote it as the scale their numbers sit on.

**General rule extracted, and it is reusable past this track: a change that
removes a check and tightens the margin that check was guarding is not a wiring
change.** NORMURAM was dispatched to compose two levers, judged it a redesign,
stopped, and reported. That was correct.

### The single most important thing on the board

**The composed A+B+C+D does not route on this part as currently written, and
Vivado said so itself, unprompted:**

```
[Route 35-447] Congestion is preventing the router from routing all nets.
iteration 0  494,506 -> 150,615 -> 65,271 -> 35,976 -> 23,310 -> 16,757  (56m35s)
iteration 1  69,858 -> 183,525 -> 111,513   (RISING -- the router is thrashing)
```

Placed occupancy **54,866 of 54,960 CLB = 99.83%**, congestion level 7, 33,767
failing endpoints after placement, **20,000 of the 20,000 worst net-dominated**
(mean net 4.575 ns against mean logic 0.670 ns). The route was killed as a
decision, not a completion (`ac35293`); `c4dev_physopt.dcp` is kept.

### TRACK LEVERC48 COMPLETE (`a4828ab`). STEP 1c IS DONE.

MEASURED at ROWS_IF=48 (1,536 lanes), OOC synth of `matvec_core`, same-session
`v_regs` vs `v_dist`, against HEAD's exact file (md5 verified with `git show`):

```
CLB LUT       121,139 -> 78,506    -42,633
LUT as memory   1,126 -> 13,414    +12,288 = 8.000/lane EXACT
MUXF7          24,583 -> 0         -24,583
MUXF8          12,288 -> 0         -12,288 = 8.000/lane EXACT
CLB FF         60,268 -> 73,463    +13,195  (DERIVED +13,200, residual -5)
WNS @ 3.3 ns   +0.242 -> -0.027
```

**BOTH PROJECTIONS WERE WRONG AND THE RANGE DID NOT CONTAIN THE ANSWER.** See
CLAUDE.md `09f59ac`: a constant per-lane figure, from the same three points,
predicts 42,428 against 42,633 (0.48%), while both fits missed by 8.6% and 14.9%
and their average was worse than either.

**CORRECTION 1, and it is the one that mattered: `matvec_core.vhd` has carried
the lever C implementation since `845ea28`. The real gap was that NOTHING COULD
SELECT IT** -- no wrapper declared or forwarded `CB_STYLE`, so the lever was
**implemented and unreachable from any build.** Now forwarded through
`matvec_int4`, `matvec_int4_desc_axi` and `matvec_int4_axi`, defaulting to
`"regs"`. **Proven in SYNTHESIS, a mechanism CBINFER never tested:** with
`CB_STYLE` on the `synth_design` line, `cb_reg*` goes 6,144 FF / 0 RAM to
0 FF / 26,112 RAM, saving 45,768 LUT there.

**CORRECTION 2: WNS REVERSES with lane count.** CBINFER's "marginally better at
all three geometries" is true and **does not extrapolate**: +0.116 at 768,
0.000 at 1,024, **-0.269 at 1,536**. At the real 5.0 ns period the cost is
-0.029 ns with 1.18 ns margin, so not a blocker -- but it is **the first
evidence `CB_BCAST` is load-bearing rather than optional.**

**CORRECTION 3: still NOT a fit-closer.** The codebook's footprint is 54,921
LUT, not 49,152, so LEVERC's CLB bound rescales to **5,329..10,177 CLB against
an 11,534 overshoot.** Does not close it at either end, and **this is synthesis,
not placement.**

**Verification worth copying:** the `[Synth 8-7186]` trap reproduced exactly --
**101 log lines saying the RAM was not inferred, beside 1,536 `RAM32M16` rows in
the same run's mapping report.** Its own announcement guard was keyed on a
string and its **own control caught it printing `LEVER C ACTIVE` over a register
bank**; re-keyed on `CB_LANES_PER_COPY = 1`. The coherency oracle now runs at the
real 1,536 replicas (LEVERC's ran at 64) with K3a/K3b/K3c/K9a/K2b all killing.
Neutrality: the same pair drawn three times from three source md5s, **all six
runs identical in every column including WNS**.

**Open and NAMED rather than absorbed: 517 unexplained flip-flops** at the
wrapper level (+13,717 against the codebook's +13,195 closed form), and why the
per-lane curve has a minimum at 768.

**No new `tb_*.vhd`, so `BASELINE_PASS` stays 99.**

### TRACK RMSWIRE COMPLETE (`47c9d9c`). STEP 1a IS DONE, and composition found a cost no unit draw could.

| | `ctl_flat` | `mem_bank` | delta |
|---|---:|---:|---:|
| CLB LUT | 67,318 | **5,265** | **-62,053, -92.2%** |
| CLB FF | 191,664 | **2,149** | **-189,515** |
| MUXF7 / MUXF8 | 26,736 / 13,296 | **0 / 0** | -100% |
| **BRAM tile** | **171** | **177** | **+6** |
| WNS @ 5.0 ns | +1.675 | +0.971 | 248.2 MHz |

**The saving is 72% LARGER than RMSMUX's standalone -36,109, and the census says
exactly why: `gvr.uw_data` -- 19,728 LUT / 9,328 MUXF7 / 4,592 MUXF8 -- is the
ADAPTER'S OWN 4096-to-1 write-back read mux, absent from every standalone draw.**
Nobody had measured it, because a unit draw structurally cannot see it. **This is
the counter-example to "compose late": composing EARLIER would have found a
62,053-LUT structure two tracks were unknowingly leaving on the table.**

**BRAM CONFIRMED BY MEASUREMENT, and the dispatcher's DERIVED figure holds:**
`246.5 + 177 = 423.5` against `372.5` available in `pb_core` -- **51 short**. The
gain image did not move (171 RAMB36 at both points). **45 of those 51 tiles are
NOT this lever.** The binding term is the gain image, and NORMURAM's `GW = 2`
fallback has still not been measured.

**`wact_chk` EARNS ZERO KILLS**, stated plainly. Kept only because `onlyWA =
K:wact` shows it discriminates and it is the sole check on the real deadline if
the gate is ever relaxed. **R1, R2 and R11 do not bite and are named** -- R1
(gate removed, survives) measures the gate at **zero cycles**.

**THREE CORRECTIONS THAT OUTLIVE THIS TRACK.**

1. **`sim/mutate_llama_top_kv.sh` needed `vec_mem` + `rmsnorm_rs_mem` added by
   hand.** Three harnesses read that hand-maintained closure, and without it
   **every row of all three, INCLUDING THE CONTROLS, was `NOBUILD`.**
   `regress.sh` computes its own closure and stayed green throughout, so **the
   gate structurally cannot catch this class.** A mutation harness whose
   controls all fail to build reports nothing and looks like it ran.
2. **`ooc_normadapt_extract.py --shift` now aborts against HEAD** (no `xw`).
   Correct behaviour, but **NORMADAPT's `na_shift` probe is no longer
   reproducible.**
3. **`nw_empty = 49,654` IS RETIRED as a cross-track control.** It was a draw of
   a configuration -- flat port, foldable constant gain -- that `llama_top` no
   longer contains. **This reverses the dispatcher's ruling this morning that it
   must not be retired**, and correctly: that ruling was right while the tree
   still held that configuration and wrong the moment this landed. Prior
   conclusions stand for their own trees; **nothing replaces it as a shared
   scale, and four tracks were quoting it.**

### TRACK RMSWIRE, in flight: the lever is wired, and there are TWO deadlines

**Landed and green.** `rmsnorm_rs_mem` is wired into `llama_top` at the real 9B
shape. All six `sim:tb_llama_top*` rows PASS, including `tb_llama_top_normw`,
the only wrapper that exercises the gain loader. **The token landmarks did not
move, so the numeric oracle is unchanged.** New gate row
`sim:tb_rmswire_loadrace` PASS at `N=4096 LANES=4`.

**THE FINDING, and it outranks the area number the track was dispatched for.
There are TWO deadlines, not one:**

- **`S_RAW` at `start+1067`** corrupts only `max_raw`.
- **`S_EMIT` at `start+2097`** corrupts every output word.
- **The strict boundary, 2007, is the INVISIBLE one.** At `start_at=1991`, 21
  elements are read from the PREVIOUS norm op's gain **and the output is
  bit-identical to the oracle.**

Both boundaries are now pinned to the cycle and predicted exactly by one
corrected model.

**A race that produces bit-identical output cannot be caught by any check that
compares values.** This is the inverse of this project's usual failure mode:
normally the structure looks right and the numbers are wrong, and here **the
numbers are right and the design is wrong.** It is exactly what TRACK NORMURAM
refused the composition over -- it said the fault class "leaves the VALUES
correct and is invisible to the landmarks" -- and RMSWIRE has now put a number
on it: **the invisible window is 116 cycles wide, 2007 to 2123.** Nobody had one.

**CORRECTION, 2026-08-30, by TRACK RMSWIRE. WITHDRAWN: the dispatcher's "116
cycles wide, 2007 to 2123". THE WINDOW IS 1,030 CYCLES AND I HAD BOTH ENDS
WRONG.** `2007` is the window's first SAFE cycle, not its start, and `2123` was
invented. MEASURED, both boundaries pinned to the cycle (`2006` corrupt / `2007`
clean, `976` corrupt / `977` clean):

```
window = [977, 2006] = 1030 cycles = exactly S_EMIT arrival - S_RAW arrival = 2097 - 1067
```

17 points swept across it with the ordinary previous-op stale gain
(`invisible_window.txt`):

```
start_at  raw_rise  stale_raw  differing verdict
977       2044      1373       0        INVISIBLE
1400      2467       809       0        INVISIBLE
1991      3058        21       0        INVISIBLE
2006      3073         1       0        INVISIBLE
```

**Up to 1,373 of 4,096 elements read from the WRONG gain vector and not one
output word moves, anywhere in the window.**

**`tb_llama_top`'s four `EXP_*` landmarks are TOKEN HASHES and pass
throughout.** Whoever builds the card top (row N3) inherits this deadline and
**cannot see it from outside the unit** without the tap.

**THE TAP NOW EXISTS.** `rtl/rmsnorm_rs_mem.vhd` gained one output, `w_active`,
high through `S_RAW` AND `S_EMIT` and low in the `S_SHIFT1`/`S_SHIFT2` gap, so
**one pin times both deadlines**: first rise is `S_RAW`, rise-after-fall is
`S_EMIT`. Every number above was measured off it. Named association throughout
means a parent may leave it unassociated.

**THE THREE MEMORY FIGURES ARE NOT INTERCHANGEABLE, and this run is the worked
example:**

| figure | value | what it is |
|---|---:|---|
| Vivado `Memory (MB): peak` | **17.3 GiB** | the tool's peak ALLOCATION; swap absorbed it |
| summed `/proc` `VmRSS` | **11.94 GiB** | sampled RESIDENT; 5.4 GiB below Vivado's, sign of the error unknown |
| cgroup `memory.peak` | **11.0015 GiB** | **THE CAP**, 1.6 MB above `MemoryHigh=11G`. Not a footprint. |

The last row reproduces CLAUDE.md's warning exactly, on a real job.

**CROSS-VALIDATION worth having: `ctl_flat` reproduced NORMURAM's `nu_u1` on
DIFFERENT hardware, every field identical** -- `lut=67318 ff=191664 bram=171
f7=26736 f8=13296 wns=1.675`, at 1,625 s against 641 s (2.53x). That is the
BC-250/workstation bit-identity property re-confirmed on a composed draw rather
than a unit one.

**Attribution, R3: `K:loadassert / K:loadassert / K:landmarks` -- the landmarks
earn that kill on their own, so NEITHER new assertion gets credit for it.**

**Correction to my brief, accepted: I sent a COMPOSED `llama_top` draw to the
14 GB BC-250** on the strength of RMSMUX's 10.58 GB peak, which was a UNIT draw.
That is the "figure from a smaller design applied to a bigger one" error, made
in the brief itself. Vivado reported a 17.1 GB peak; the box survived on swap
(MEASURED mid-run: 10 GB free, 2 of 46 GB swap, load 1.13).

**And a distinction worth keeping: Vivado's `Memory (MB): peak` is not the
cgroup's `memory.peak`.** The former is the process's own peak allocation, which
swap can absorb -- which is why 17.1 GB "fit" on a 14 GB box. Quote the cgroup
figure, and only from a run that never reached its cap.

### THE STRIPING EXPERIMENT RAN ON SILICON, 2026-08-30 14:20. 11.09x.

```
mean cycles/beat   flat 22.49   striped 2.03   speedup 11.09x
```

**The pre-registered band was 1.60 to 3.0 and the measurement is 2.03.** Neither
falsifier fired: not 10-12 (half the lanes still sharing a channel), not ~21.6
(the descriptors not being the striped ones).

| tensor | flat | striped |
|---|---:|---:|
| `blk.0.ssm_alpha.weight` | 23.45 | **2.38** |
| `blk.0.ffn_gate.weight` | 22.19 | **2.02** |
| `blk.11.attn_k.weight` | 22.38 | **2.00** |
| `blk.20.ffn_down.weight` | 21.95 | **1.72** |

**The census is printed beside every number**, so the layout and the measurement
cannot be read apart. Whole-image: flat `{(1,27): 235, ...}`, striped
`{(25,2): 249}` -- every one of the 249 tensors on 25 channels with at most 2
lanes on the busiest. G1, G2 and G2b all PASS. Both manifests pinned by sha256
in the log, because that file has moved under three tracks.

**`trips=0` before AND after all eight jobs**, with the counter cleared and
observed 0 before each. The thermal veto was discriminating rather than
saturated, because the cold power cycle reset it -- so no number here is
contaminated by THERM-255.

**STRIPEREADY's caveat against its own interest did NOT bite:** only 15 to 17 of
27 lanes read the pseudo-channel their own engine master is wired to, so ~40%
cross the HBM global switch laterally, **and 2.03 was reached anyway.** Lateral
crossing is cheaper than the estimate feared. That is now a measured fact rather
than an assumption, and it is the one genuinely new thing this run taught beyond
confirming the prediction.

Log: `/mnt/storage/stripe_experiment_2026-08-30.log`. The card is left holding
the striped image, fully verified; re-running the command is safe.

### AND THE CARD BOOTS ITSELF NOW

`hw/fk33/bit/fk33_pcieep.mcs` written to card 1's SPI flash. On the next full
power cycle the FPGA configured from flash, trained inside the ~100 ms PERST
window, and the BIOS enumerated **root port `00:1d.0`** unaided --
`06:00.0 Xilinx Corporation Device [10ee:9034]`, `LnkSta: Speed 8GT/s (ok),
Width x4 (ok)`.

**This retires the entire rescan/reboot problem.** The port is live at every
boot from now on, and any bitstream goes in behind it with `remove -> configure
-> rescan` (`sudo hw/fk33/host/fk33_reload.sh --with-vccint`), which is the
August procedure that always worked and had simply lost its precondition.

**`00:1c.4` was the RTX 3090's slot, not the card's.** A whole deadlock theory
was built on that misidentification this morning; it was settled by flashing and
looking, not by more inference.

### TRACK GATEGREEN COMPLETE (`392f818`, `df0b194`). THE TREE IS GREEN.

Full both-suite run on a clean `git archive 32a7b47`, GHDL 1.0.0 mcode,
`--jobs 1`:

```
 suite sim   PASS 79   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 3
 suite tb    PASS 26   FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 1
 OVERALL     PASS 105  FAIL 0   NOVERDICT 0   TIMEOUT 0   BUILD-ERROR 0   NOCHECK 4   SKIPPED 6
 REGRESSION: PASS
```

**Zero red rows, so no bisection was needed.** Every row for every file the 32
commits touched passed, including the two new auto-discovered rows.

**`BASELINE_PASS` LEFT AT 99, DELIBERATELY.** The floor run (with the documented
`MV4I_FK33_FILE=/nonexistent`) measures **101**, and the gate itself printed the
raise suggestion. But `sim/tb_a_wbase.vhd` landed in `d7a6bf7` AFTER the archive
(verified with `git merge-base --is-ancestor`), so 101 describes a commit that is
no longer HEAD and **102 would be arithmetic over a row nobody has run.** The
measurement, the recipe and the reason are written into `sim/regress.sh` so the
next track closes it with one run and no re-derivation.

**WHAT THE GATE DOES NOT COVER, and this matters because seven tracks quoted
area and timing numbers today:** GHDL simulation plus seven Python/Tcl
self-checks. **No synthesis, no timing, no placement, no routing, no area, no
power, no card.** Six `*_cmp` rows are skipped by design, so **the netlist is
never compared to the behavioural model.** Four rows are NOCHECK. **Five `rtl/`
files are reached by no testbench at all.**

And the line worth keeping: **`FAIL 0` means no row noticed anything, not that
the rows would notice.** ATTNTEETH found `tb_attn_block` passing a broken tree
on a degenerate oracle, and BASEFAB's control denies its own new row credit for
seven of eight kills. **Much of this suite's apparent discrimination is
incidental.**

**TWO CORRECTIONS TO MY BRIEF.**
1. "Nobody has run the full gate" was wrong -- TRACK STRAYROW ran one on a clean
   archive of `2217778` (`912ada7`). **The practice was followed; only the
   number was stale.**
2. **THE MEMORY WARNING DOES NOT SURVIVE MEASUREMENT.** The full gate at
   `--jobs 1` peaks at **2.13 GiB** (cgroup `memory.peak`, under its 8G cap so a
   real peak), beside a 7-10.6 GiB Vivado `place_design`, `MemAvailable` never
   below 19 GiB. **The 20.9 GiB `ghdl-mcode` figure belongs to something else
   and the whole dispatch budget was provisioned against it all night.** Landed
   in CLAUDE.md; **the bench that actually reaches 20.9 GiB is now an open item
   and must be pinned before that number is quoted again.**

**ITS OWN TRAP, and it is a guard passing its teeth-check on a live operator
error:** the first gate ran WITHOUT `MV4I_FK33_FILE=/nonexistent`, so four FK33
rows ran off a `.mv4i` that has sat on this box since 28 Aug, and the headline
came out **105**. **The gate refused the raise and named all four rows.** Note
the `NOT IN GIT` check was silent and correct (an archive has no `.git`); the
optional-row refusal is a separate mechanism and it is the one that fired.

**Largest unverified surface:** `rtl/llama_top.vhd` changed after `32a7b47`
(BASEFAB's `d7a6bf7`), so the six `tb_llama_top*` rows are unverified at HEAD.

### TRACK BASEFAB COMPLETE (`d7a6bf7`). THE URGENCY CLAIM WAS WRONG, AND THAT IS GOOD NEWS.

**The form claim was right; the urgency claim that drove the dispatch was
wrong.** `w_base(p) = A_MEM_BASE + step*A_JOB_STRIDE + p*A_SUB_BYTES` is a
two-parameter affine map and PACKSTRIPE's allocator assigns segments per tensor,
greedily on fill, which no closed form expresses. **But `llama_top`'s
fabrication is not on the striped path and never was.**

MEASURED by BASEFAB and **independently VERIFIED by the dispatcher**:

- `hw/fk33/rtl/fk33_engine.vhd` binds **`matvec_int4_desc_axi`**, not `matvec_int4`.
- `grep -c 'seq_' hw/fk33/rtl/fk33_engine.vhd` = **0**.
- `rtl/matvec_int4_desc_axi.vhd:610-615` drives
  `w_base <= dw(DESC_BASE0 + p)` -- **27 arbitrary 40-bit addresses fetched from
  the descriptor image.**
- `tools/gen_mv4i_desc.py`'s `sub_base()` already emits striped bases from the
  v2 manifest's `pieces`.

**So striping is expressible end to end on the card TODAY, PACKSTRIPE is not
blocked by G3, and DSEAM's "on silicon every A job would read the wrong bytes"
is conditional on an integration that does not exist. G3 is a defect in the
SIMULATION top.** This materially de-risks the striping experiment.

**A REAL DEFECT FIXED, because it is reachable today: the fabricated block was
UNBOUNDED.** DERIVED at 9B, the FFN gate job needs **393,216 beats per port
against a 256-beat sub-region, short by 1,536x**. Over-capacity jobs walked into
port p+1's region and completed **`done=1, err=0`**. `llama_top` now refuses in
`S_EXP` before `start`, so zero address beats are issued.

**THE ATTRIBUTION CONTROL IS THE HEADLINE AND IT DENIES CREDIT FOR SEVEN OF
EIGHT KILLS.** `sim/tb_a_wbase.vhd` kills 8 of 11; **only M9, the new guard, is
a detection the six pre-existing rows do not already make.** And those rows kill
via **recorded numeric landmarks, not address checks** -- they fire because
`wword` happens to be address-sensitive. The two `smp` rows, whose memory answers
on `addr mod A_JOB_STRIDE`, **pass every address mutation in the table.**

**M5 IS THE MOST USEFUL ROW IN THE TABLE:** a uniform one-stride shift of every
base **survives the bench and is caught only by the control**. *A checker of
relative properties can never see a base that is uniformly wrong* -- which is
G3's own shape. **Only an address-level oracle can catch a wrong base, and the
oracle is the base array.**

**THE DECISION THAT IS ACTUALLY OWNERLESS is not the base array, it is the
integration.** `docs/2026-08-28_matvec-descriptor-format.md` says "D issues, A
consumes" at :84 and "D fetching it is remaining work" at :570 -- **two mutually
exclusive integrations in one file, and nobody has chosen.** BASEFAB argues D
fetching it is the WRONG choice for a structural reason: `seq_desc_fetch`'s
descriptor address is `resize(fetch_idx & "000", 16)`, a **fixed 8-word stride**
on which its 0-DSP claim rests, and a 39-word descriptor is not addressable by
`step*8`.

**UNVERIFIED, under their own names:** M10_guard_ge and M11_port_rev **have no
control column** -- both survived the bench, but whether the pre-existing rows
catch them is unmeasured because the batch was cut short. Run M11 first;
`tb_llama_top.vhd:892`'s `sub = p` assert should catch it.

**No full gate run** -- GATEGREEN held the box and BASEFAB correctly judged a
contended run not to be evidence. **`BASELINE_PASS` needs +1 for its row**
(`sim/tb_a_wbase.vhd`); `sim/regress.sh` untouched. GATEGREEN notified.

### TRACK TRIPVETO (`729df43`). SIX consumers, THREE failure directions, and the fix deliberately NOT landed.

**Six consumers in four files, and the load-bearing column is the failure
DIRECTION, not the file:**

| # | where | verdict at `trip_cnt = 255` |
|---|---|---|
| 1 | `fk33_run_job.py:909, 1000-1001` | **false PASS**, veto dead; `:926` prints a correct warning about exactly this and proceeds |
| 2 | `fk33_run_token.py:737-738, 748, 775-776` | **false PASS**, `t1 == t0` forever, no trip logged, no retry fires |
| 3 | `fk33_run_token.py:980-981, 1044-1045, 1352` | silent under-report |
| 4 | `therm_selftest.py:256, 294-297` | **INVERTED** -- it asserts the counter MUST move, so saturation makes it FAIL a WORKING guard |
| 5 | `fk33ctl.py:358` | silent under-report |
| 6 | `hw/fk33/tcl/aux_probe.tcl:114-116` | silent under-report, on the JTAG path |
| -- | `fk33_stripe_experiment.py:227-260` | defended (STRIPEREADY's) |

Named as NOT consumers so nobody re-checks: `fk33_run_layer.py`,
`fk33_load_weights.py`, all of `server/`, all of `tools/`.

**CORRECTION TO MY BRIEF, and it is the reusable part: my starting grep finds
THREE OF SIX.** `fk33_run_token.py` names them `t0`/`t1` and `trips0`/`trips1`,
`therm_selftest.py` uses `trips_before`/`trips_after`, and `aux_probe.tcl` is
Tcl outside the searched path. **The REGISTER name is the search key, not the
variable names.**

**THE RTL SATURATION IS CORRECT. DO NOT REBUILD.** TRIPVETO opened expecting to
recommend widening and its own measurement killed that: **wrapping trades a
permanent, detectable failure for a periodic, undetectable one**; 16 bits buys
~4.5 h at the measured 30 crossings/s and changes nothing about the failure
mode; and any fixed width saturates above some rate. The one thing worth riding
along with a future `fk33_thermal.vhd` change is a **sticky `trip_cnt_sat` bit,
one FF** -- the only thing that can close consumers 3, 5 and 6, which no host
change can reach, because clearing destroys the history they report.

**WHY THE FIX WAS NOT LANDED, and this was the right call.** Applying
STRIPEREADY's clear-and-prove shape inside `fk33_run_job.py` **BREAKS
`fk33_run_token.py`**: its retry wrapper samples `t0` immediately before
`_ORIG_RUN_JOB(...)` and `t1` immediately after, so if `run_job` clears then
`t1 < t0` on every job, `t1 != t0` fires, and **a phantom trip is logged and a
retry burned on every job of every layer of every token.** That converts a dead
veto into a live false alarm **which would read as evidence about THERM-255
itself.** The correct fix is a structured channel that `run_token` consumes
instead of sampling around the call: two files, hardware-only consumer, not
something to half-land before a reboot.

**TWO TRAPS FOUND BY READING, for whoever takes the fix:**
- `SimBar._status` at `fk33_run_job.py:774` fires the injected trip only when
  `self.trip == faults["trip0"]`. After a clear that is `0 == 255`, so the
  `trip0=255, trip_during=1` mutant **would not bite AND would look like it
  had.**
- `tests_fk33ctl.py:137` and `:175` both pin the count at **3** (DERIVED:
  `(0x8A0377CD >> 16) & 0xFF = 3`). **The existing fixture cannot see this
  defect at all.**

**Correction appended in place:** `2026-08-30_therm255-...md:262` ("nothing here
is fixed") is now stale FOR THE RTL IN THE TREE -- the capture-a-cycle-late
defect is fixed at `fk33_thermal.vhd:1146-1160`. **It remains true for the
bitstream ON THE CARD.**

**OPERATIONAL NOTE FOR THE STRIPING RUN:** `fk33_stripe_experiment.py` defends
itself, so the one-command experiment is safe. **`fk33_run_job.py` and
`fk33_run_token.py` invoked directly are NOT**, and at 255 they will report
health.

### TRACK STRIPEREADY COMPLETE (`0eac8d4`, `639880e`). THE EXPERIMENT IS ONE COMMAND.

```bash
cd /home/orencollaco/GitHub/llama.vhdl
python3 hw/fk33/host/fk33_stripe_experiment.py run
```

It pins BOTH manifests by hash, runs every offline guard, loads and verifies the
FLAT image, runs the four published jobs, repeats for the STRIPED image, and
prints one table with CYCLES, BEATS, STARVED, cycles/beat, **the trip count**
and the channel census on each row. Idempotent, both phases are full loads, and
it finishes with the card holding a verified striped image. **If it refuses it
produces no number and names the guard.**

**The `index.txt` gap is closed WITHOUT touching the packer**, which matters
because the packer has moved the manifest under three tracks now.
`tools/ref9b/make_index.py` reads geometry and shape only, never `hbm_offset`
and never `pieces`; STRIPEREADY enumerated its inputs, PREDICTED the striped
index would be byte-identical to the flat apart from line 1, then generated it:
MEASURED **428 body lines identical, one differing provenance comment**, and
`git diff --stat -- tools/pack_model_fk33.py` empty. Blocker measured shut both
ways (`index.txt does not exist` to `248320 of 248320 logits, 0 differ`).
**But `plan` is INERT to placement** -- flat vs striped differs in two lines,
both timings -- **so it closes the gap without being a striping verifier and
must not be quoted as one.**

**THE FINDING, and it sits directly on the measurement path.**
`hw/fk33/host/fk33_run_job.py`'s thermal veto rests on `trip_cnt`, which
**SATURATES at 255**. VERIFIED by the dispatcher at
`hw/fk33/rtl/fk33_thermal.vhd:1166`:

```vhdl
if trip_cnt /= to_unsigned(255, trip_cnt'length) then
  trip_cnt <= trip_cnt + 1;
end if;
```

At 255 the veto's `trip1 != trip0` test is **false forever** while still
printing `trips=255 (was 255)`. **The guard stops discriminating exactly when
the condition it guards is worst, and reports health while doing so** -- and
THERM-255, the open issue named for that number, is the reason the counter gets
there. STRIPEREADY's own runner defends itself (clear, then refuse unless the
post-clear word reads 0) and correctly flagged the rest as needing an owner.
Dispatched as TRACK TRIPVETO.

**T12 IS CLOSED**, after three tracks carried it. Honestly reported: its first
mutant was **not clean** -- it overlapped the f32 blob and `hbm_map` killed it
for the wrong reason, and **the neighbouring arms revealed that, not its own**.
The clean version is a same-size permutation that five checks pass and the
runner refuses. **Closed at the host, still open at the packer.**

**THE PREDICTION IS UNCHANGED, and its load-bearing input is now MEASURED over
all 249 tensors rather than inferred:** `striped {(25, 2): 249}` -- every
tensor, 25 channels, exactly 2 lanes on the busiest. The flat half of that
census **independently reproduces the counters document** (235/13/1, the missing
3-segment file being `token_embd`, absent from `noembd`).

**NEW FALSIFIER INPUT, and it weakens the run rather than strengthening it:**
only **15 to 17 of 27 lanes** read the channel their own master is wired to, so
the result leans hard on STRIPEPATH's lateral-crossing ESTIMATE -- and the four
measurement tensors split 17/15/17/15, **not enough spread to test it.**

**Verification:** 11 mutants x 5 arms, **control surviving in every arm**. G1
earns 1 independent kill, the census family 3, whole-image scope 1 that the
four-tensor scope cannot see, the oracle join 1. **M2, M3, M4 earn G1 nothing
and are named. M7 and M8 survive as designed. G4's extent-count cross-check
earns ZERO and is labelled.** Six commands traced with zero `/dev` opens.

**Correction to my brief, and it is right:** "verify the striped image and the
striped descriptors" is TWO guards and either can pass while the other fails --
**which is exactly the `output.weight` byte-identity case TOKENSTRIPE hit.**

### TRACK CBINFER COMPLETE (`0d24f7d`). LEVER C IS ALIVE: Vivado DOES infer LUTRAM.

LEVERC's own first open item said this "must be the first thing a Vivado lane
checks, before any area number", because a NO would have made lever C **1,536
register copies, strictly worse than today**, and moot every row containing it.

**1. YES.** MEASURED at three geometries on `xcvu33p-fsvh2104-2L-e`, Vivado
2023.2: at `CB_STYLE = "distributed"` every codebook copy becomes one
`RAM32M16` (16 x 8, 8 LUTs) and the 16:1 mux per lane vanishes. The clean line
is the object-level census at ROWS_IF=8:

```
v_regs_r8   cells named cb_reg*:  RAM=0     FF=1024
v_dist_r8   cells named cb_reg*:  RAM=4352  FF=0
```

**LEVERC's 12,288-LUTRAM assumption is now MEASURED rather than assumed:**
LUTRAM added per lane is **8.000 at all three points** (128, 256, 512 lanes),
MUXF8 removed 8.000/lane, MUXF7 removed 16.00/lane -- **matching CONGEST's
shell per-lane census exactly**.

**2. The `ram_style` attribute from a function of a generic is ACCEPTED and
EARNS NOTHING.** The Final Mapping Report attributes 128 of 128 copies to `User
Attribute` -- but the attribution control (both attributes deleted) is
**byte-identical in every column** and merely relabels the inference `Implied`.
**So LEVERC's two-sibling-architecture fallback is not required and would buy
nothing.** `dont_touch = "false"` versus deleting it is also identical, so
presence-not-value was tested and refuted.

**3. `ram_style = "registers"` does NOT change today's shipping build** --
identical on eleven columns and WNS to the last digit, with a repeat draw
reproducing itself exactly, so it is a demonstrated no-op rather than a
coincidence.

**THE TRAP THAT WOULD HAVE INVERTED ANSWER 1, and it is the mirror image of
NORMURAM's URAM trap the same morning.** Vivado's log says, one hundred times:

```
WARNING: [Synth 8-7186] Applying attribute ram_style = "distributed" is ignored,
object 'cb[0][0]' is not inferred as ram due to incorrect usage
```

**Every object it names IS a `RAM32M16` in the same run's mapping report.**
Where `[Synth 8-10226]` claimed a resource the design never got, this one denies
one the design did get. **Vivado's inference log is unreliable in BOTH
directions; only the mapping report and the primitive census are
authoritative.** Landed in CLAUDE.md as `7888ef9`.

**CORRECTION OWED TO LEVERC, and it does not change their conclusion.** A
`RAM32M16` is 8 LUTs and CLB-atomic, so LEVERC's fragmented "4 per CLB" case is
unreachable. Their CLB saving narrows to **4,608 .. 8,946** from 3,072 .. 8,946.
**Lever C still does not close the fit under either bound; LEVERC's conclusion
stands.**

**NEXT VIVADO JOB, and it must go on the WORKSTATION:** the FK33 geometry
`ROWS_IF=48` was **not drawn**. ROWS_IF=16 already peaked at **14.38 GB summed
Vivado RSS on the BC-250's 14 GB**, so 48 does not fit there. Projections to
1,536 lanes are labelled: the structural per-lane figures are exact at three
points, but the **total-LUT saving is an ESTIMATE of 36,000-39,000** because
per-lane saving falls with lane count (29.11 / 27.71 / 26.05) and two models
disagree. DERIVED and exact: **+13,200 FF** at ROWS_IF=48 (three-point model,
residuals 0, -2, +4).

**Its own trap, recorded against itself:** the first primitive-census parser
assumed a four-column Primitives table (it has three) and **silently wrote zeros
into six CSV rows beside a populated utilization table** -- the exact failure
the cross-check exists to catch. Parser now hard-errors on zero rows.

**Not covered:** OOC synthesis, not placement, and lever C's claim is about
PACKING which only a place run measures. `matvec_core` alone, not the composed
design.

### TRACK NORMURAM COMPLETE (`c479ae8`, `57ecea4`, `5026897`). The gain image is out of LUT fabric.

`rtl/llama_top.vhd`'s `gvr` generate reshapes `NW_TBL` to 4 elements per word,
lets Vivado infer BLOCK RAM, and shifts it into a plain register. The
empty-image build (`gwc`) keeps the old code **character for character**.

| point | LUT | BRAM | URAM | WNS |
|---|---:|---:|---:|---:|
| `nu_empty` pinned, no image | 49,654 | 0 | 0 | +1.675 |
| `nu_ec` NEW RTL, no image | **49,654** bit-identical | 0 | 0 | +1.675 |
| `nu_a` route (a), image | 83,709 | 0 | 0 | +1.675 |
| `nu_rom` pinned, image | 89,970 | 0 | 0 | +1.675 |
| `nu_u1` NEW RTL, image | **67,318** | 171 | 0 | +1.675 |
| `nu_u2` same command again | **67,318** | 171 | 0 | +1.675 |

**Saving +15,279 to +60,747 LUT, and the WHOLE INTERVAL belongs to the
before-side.** `nu_empty` reproduces NWFIX's control on all eleven columns;
`nu_u1`/`nu_u2` agree on the entire `report_utilization` with byte-identical
censuses (md5 `1b341a73`). WNS unchanged on all six points. The gain store,
address generator, shift register and busy logic together are **313 LUT and
58,453 FF**, landing within 259 LUT of NWFIX's HBM floor **and spending no HBM
bandwidth**.

**THREE CORRECTIONS THAT OUTRANK THE NUMBER.**

1. **Route (a) is a no-op, and not for the reason anyone gave.** `Synth 8-6040`
   fires word for word with `:= 0` deleted, because **a VHDL signal of subtype
   `natural range 0 to NW_N-1` has an initial value regardless** -- the language
   gives it `subtype'left`, which is 0. **There is no way to spell "no initial
   value".** The width would have refused it anyway: 65 x 65,536 needs 911
   primitives against 672 RAMB36 / 320 URAM288.
2. **URAM cannot hold this table at all** -- see the relabelling above.
3. **"+32,943" was the DROP saving.** Any real gain pays `rmsnorm_rs`'s 17,367
   LUT fold wherever it lives, so **no route that keeps the image reaches
   349,421.**

**THE ATTRIBUTION CONTROL CHANGED A CLAIM IN THE NEW CHECK'S FAVOUR, which is
the rarer direction.** U6 is a margin failure that leaves the VALUES CORRECT,
killed by the new `wbusy` assertion; U6x is the same mutant with that assertion
disabled and it **survives with zero landmarks moved**. Both m7-class packing
mutants killed on all four landmarks. **U7 reported as a row that does not
bite**: the landmarks cannot see `GW`.

**NEW MEASUREMENT TRAP, landed in CLAUDE.md as `cc06f35`: a capped job's
`memory.peak` is the CAP, not the peak.** MEASURED: a five-point batch under
`MemoryHigh=13G` reported `memory.peak` **1.1 MB above 13 GiB** -- the throttle
holding it there, not the job's appetite. **The only honest unthrottled figure
was `nu_empty`'s 10.54 GiB.** Cap for safety; read `memory.peak` for size only
from a run that never reached its cap.

**Open:** nothing here is placed or routed; the Vivado half of the values oracle
is still open; and **171 BRAM is 25.45% of the device**, so a `GW = 2` point is
the obvious next measurement if BRAM binds. The `rmsnorm_rs_mem` composition is
DEFERRED, not rejected, for the rate reasons recorded above.

### TRACK ATTNTEETH COMPLETE (`5755473`,`a8053ca`,`1e18ce3`). The oracle's STIMULUS was the defect.

**`tb_attn_block` passed a deliberately broken tree, and the mechanism was never
in the bench.** Root cause is ONE LINE of the oracle's stimulus,
`ref/attn_block_vec.c:864`:

```c
for (i = 0; i < N * N_KVH; i++)    vin[i] = m12(65537 + SEED, i);
```

Uniform on [-2048, 2047] with no per-block structure, so every block's peak
lands in the top binade and `kv_quant` gives all NBLK blocks the SAME exponent.
MEASURED with a probe at the fold site: all six folds are `e0=e1=e2=e3=6`.
**`v_ref` is the minimum over that, and a minimum over a constant vector is that
constant.** P8 compared exactly the right numbers, bit-exactly, with no
tolerance, **and could not have disagreed whatever the reduction did.**

**All four hypotheses in my brief were wrong** -- shared source, narrow scope,
stale vector, early exit. Each was checked and each refuted. The defect was
upstream of every one of them.

| tag | mutation | before | after | `kv_seam` |
|---|---|---|---|---|
| M1 | drop the last tree stage (TIMING's) | PASS | KILLED | KILLED |
| M2 | no reduction, return block 0 | PASS | KILLED | KILLED |
| M3 | maximum not minimum | PASS | KILLED | KILLED |
| M4 | pad with 127 | PASS | SURVIVED | SURVIVED |
| M5 | result never folded in | KILLED | KILLED | KILLED |
| M6 | per-TOKEN not per-SEQUENCE | PASS | SURVIVED | KILLED |
| M7 | defect C1, `v_ref` shared across layers | PASS | SURVIVED | KILLED |
| M8 | drop the LAST block exponent | PASS | KILLED | SURVIVED |

**1 of 8 to 5 of 8. M8 is the one that matters: it survived BOTH benches
before.**

**THE ATTRIBUTION CONTROL PAID FOR ITSELF AGAIN. P9 is credited with ZERO
kills.** All eight verdicts are identical with P9 disabled; P8 does all the
killing, and P9 is justified as a stimulus gate rather than a detector.
**Without the control this would have claimed four detections for a check that
makes none.** P9's own teeth-check (flat stimulus, honest RTL) fails with every
sub-check firing while P8 passes.

**Survivors kept and explained:** M4's pad branch is unreachable (`NBLK` is
4/4/8, all powers of two -- dead code, not a missed defect). M6 and M7 are
structural to a one-token one-layer bench and `kv_seam` owns and kills both.
**The two benches have DISJOINT blind spots**, which is a stronger statement
than either being adequate.

**AND IT CAUGHT ITS OWN FIX REINTRODUCING THE DEFECT ONE LEVEL UP.** A per-head
PERMUTATION taper gives every head the same `v_ref`, so `attn_emit`'s cross-head
fold went degenerate. **It passed the generator's assert, P9 as first written,
and the whole suite.** The sibling enumeration caught it; nothing checking the
fix did.

**HIGHEST-VALUE FOLLOW-ON, NOT YET OWNED:** `ref/attn_block_seq_vec.c:214-215`
still carries the untapered line word for word, giving `e_grid = {20,20}` on
layer 1 -- **a minimum over a constant vector on half the design**. And
`tb_attn_kv_seam`'s teeth on this structure are **ONE block exponent of sixteen
headers** (15 of 16 folds are flat `6 6 6 6`), which is the repo's entire
coverage of the fold, at a hand-picked seed. Blocked on `sim/regress.sh`
(GATEGREEN's), whose lines 1499-1518 justify that generator's SEED=2 in terms of
exactly these numbers.

### TRACK TOKENSTRIPE COMPLETE (`6ca385f`, `a25847b`). The sixth consumer, and a guard fixed rather than muted.

**Defect sized first:** 15 window descriptors, **0 errors, 405 of 405
sub-region bases wrong**. After: 405/405 MOVE, 0 wrong against the manifest,
lm-head **3 to 25 pseudo-channels**. It was THREE lines, not two -- `TailJob`
uses `__slots__`, so `pieces` had to be declared there or the assignment raises.

**THE TRAP, and it explains why a track looking straight at this missed it:**
`output.weight.mv4i` sits at `hbm_offset` **0 under BOTH layouts** (same
`blake2b_128`), so the pre-change tail's 15 descriptors are **byte-identical
between the flat and the striped manifest. Diffing the two runs shows
nothing.** Only comparison against the manifest's `pieces` sees it.

**`tools/weights_residency.py` was FIXED, not muted, and the old rule was
another coincidence-of-geometry guard.** `stack_hole_bytes` is not "the gaps":
`place()` returns `hole` only for a stack-boundary skip and the striped branch
never calls `place()`, so it is structurally 0. The old check compared it
against ALL inter-placement gaps, **and the two coincide under the flat layout
only because a bump allocator leaves no other gaps.** Replaced by a closed
ledger, DERIVED exact to the byte before any rule was written:
`2,690,994,176 = 0 + 2,422,558,720 + 268,435,456`.

**It is STRICTER on the flat layout, not looser**: the old rule compared totals,
so a `stack_holes` entry at the wrong address, a list disagreeing with its own
total, and an emptied list all passed. All three now fail and the pre-change
file survives all three. Ledger earns **10 independent kills**; rows earning
nothing (S1b, S5, S6) are named.

**Corrections issued:** STRIPEPATH's "running `fk33_run_token.py` needs the
card" is WRONG -- `plan` and `selfcheck` are offline and were traced clean, so
its section 9.2 step 4 is superseded. And my brief's framing was off: the
manifest's `stack_hole_bytes` was always correct; it was the CHECKER's
re-derivation that was flat-only, which is why the fix is a consumer change.

**Traps it hit and reported against itself:** its first teeth table credited the
change with 8 kills it had not earned, for want of a whole-ledger-removed arm.

**STILL OPEN and blocking a full striped re-run:** the striped packed dir has
**no `index.txt`** (PACKSTRIPE's artefact), so `plan`'s host re-run cannot cover
the striped set. T12 remains unclosed.

### TRACK STRIPEPATH COMPLETE, 2026-08-30 (`d7f96cd`, `9d73018`). The striping path emits.

**The defect, SIZED before it was fixed:** pre-change, `fk33_run_layer` on the
striped set emitted 296 descriptors, **0 errors, and 7,992 of 7,992 bases
wrong**. It failed silently and completely.

**After: all bases MOVE and land where the manifest placed their file offset**,
reaching **25 distinct pseudo-channels** read from address bits [32:28].
`output.weight` goes from 3 segments to **25**. Inertness on the flat set:
**24,258 descriptor words, nine diffs**, one intentional and named.

**Guards that could not see their own defect, found here:**
`check_hbm_stack` printed **PASS** with a piece straddling the 4 GiB stack line.
It now earns 7 kills with the pre-change file earning zero on every row and its
control surviving, so that attribution is clean. And **the range count was never
a discriminator at all**: 7,154 on BOTH layouts, because
`250 + 249*27 = 249*28 + 1 = 6,973`.

**Zero-kill checks named and NOT credited** (the most valuable part of the
report): the extent rule in `check_byte_cover` (its NOEXT arm kills identically
to NEW on all 13 rows), and the `pieces` threading in `gen_layer_program` and
`fk33_run_layer`. Non-biting mutants **T5 and T12** reported under their own
names, with **T12 flagged as the hole nothing here closes**.

**CORRECTION issued by STRIPEPATH, and it binds every future track on this
path:** PIECES' quoted numbers do not reproduce -- against today's manifest the
pre-PIECES world does not emit 311 jobs, it dies on an `hbm_map` OVERLAP, and
the bases are not byte-identical to the flat program's. **The defect is real and
was measured directly; the specific numbers must not be quoted. PACKSTRIPE has
now moved the manifest between tracks twice.** Pin the manifest's identity
(path plus hash) in any write-up that measures against it.

Also corrected: `fk33_run_layer` needed **no** `hbm_map.plan().check()`, because
`make_layer` already calls `place_desc_arena()` which runs one and raises. "The
same two lines" was wrong once already.

### THE CARD EXPERIMENT IS READY, AND ITS PREDICTION IS PINNED IN ADVANCE

Section 9 of `docs/debugging/2026-08-30_stripepath-five-emitters.md` carries the
offline arm, the card arm (Oren's only) and a failure-mode table.

**Prediction, stated before the run: cycles/beat should fall from the MEASURED
21.67 to between 1.60 and 3.0.** DERIVED: 27 beats on one pseudo-channel = 21.60
core cycles; at most 2 lanes per channel = 1.60, which is exactly the RTL's own
ideal-memory floor.

**The falsifiers are stated too, and this is what makes it an experiment rather
than a demonstration.** A measured **10 to 12** means half the lanes still share
a channel. An **unchanged 21.6** means the image or the descriptors are not the
striped ones, and is **NOT evidence about the theory**.

**No new bitstream is needed.** Two things still block it:

1. **`hw/fk33/host/fk33_run_token.py:1103` is a SIXTH consumer with the
   identical defect**, on the token path, emitting the lm-head's 15 window
   descriptors. **Until it lands, a striped set gives a correct 32-layer body
   and a WRONG lm-head.** Dispatched as TRACK TOKENSTRIPE.
2. **PCIe enumeration.** The card is configured (`d31ab02`) but its root port is
   hidden by the BIOS; see the CORRECTION in
   `docs/debugging/2026-08-30_restoring-the-card-after-a-power-cycle.md` -- a
   rescan cannot work and the fix is a warm reboot, deferred by Oren until the
   synthesis and gate lanes quiesce.

Also handed over: `tools/weights_residency.py` fails on a striped manifest for a
reason unrelated to what it guards (`stack_hole_bytes` computed for the flat
layout against 2.69 GiB of by-design arena gaps) -- **needs an owner BEFORE it
gets muted**, also TOKENSTRIPE. And `pack_model_fk33.expand_pieces()` remains a
**second producer** of piece extents.

### TRACK SEAMMAP COMPLETE, 2026-08-30 (`1e46fb3`). N2 option (a) has an address.

**`0xE000` is assigned, and it was checked rather than inherited.** MEASURED
against the EMITTED `build_fk33_pcieep.tcl` rather than a document: BAR
occupancy is 0x3000 SYSMON, 0x9000 GPIO, 0xA000 id, 0xB/C/D000 thermal,
0x10000 + 8K scratch, 0x12000/0x13000 engine. **`0xE000` and `0xF000` are the
only free 4 KB pages below the scratch**, and `0xE000` is the lower. It is
inside the 128 KB BAR and 4 KB aligned, which `fk33_seam`'s 12-bit
`s_axi_awaddr` requires. `FK33_SEAM_BASE_PROPOSED` is now `FK33_SEAM_BASE`
across all four callers, and **the generator refuses to emit while the
`_PROPOSED` define survives**.

**THE FINDING, AND IT IS A DESIGN DECISION THE BRIEF DID NOT ANTICIPATE. There
is no subsystem D behind this seam (N3), so its D face is driven by constants,
and the OBVIOUS tie-off hangs the host.** MEASURED at `rtl/fk33_seam.vhd:549`:
the completion arm runs only `if running = '1'`, and `running` is cleared ONLY
by `d_err`, `d_tok_done` or ABORT. **Tie both low and a GO sets `running`
forever** -- neither done nor err ever sets, and the `(done | err)` poll loop
this seam's own header prescribes never exits.

So `d_err` is tied HIGH: every GO refuses one cycle later with `EC_DESC` and
`ERR_INFO[3:0] = 0xF`, **a code `llama_top` cannot produce**, so the refusal is
distinguishable from a real error rather than merely silent. Faking a completion
via `d_tok_done <= d_go` was considered and REJECTED.

**SEAMMAP's own correction to my brief, and it is right: N2 must NOT be reported
as "done" without the clause.** What sits at `0xE000` is a real, addressable,
honest seam **with no transformer behind it**. The brief framed the
instantiation as mechanical; it was not.

**Verification worth copying.** `check_bar_map` **parses the emitted script**
rather than restating the map, deliberately avoiding the hand-table shape that
produced the descriptor-base coincidence defect. Address teeth ran a 3-arm
attribution control (pre-SEAMMAP needles / new needles / the parser): 8
refusals, 3 must-not-refuse, `MAP ALONE=4 both=4 NEITHER=0`, with **the
pre-existing arm empty on every row** (DERIVED: `git show
d53af73:hw/fk33/gen_pcieep.py | grep -ci seam` = 0). `md5sum -c` over **1,868**
tracked files.

**NON-BITER, reported under its own name and it is the useful one:** relocating
`fk33_id` to `0xF000` is legal on every rule and WRONG, because `fk33_regs.h`
hardcodes `0xA000`. **The check verifies internal consistency, not agreement
with the host header.** Filed as work.

**QUEUED, NOT REFUSED: a Vivado `--bd-only` run.** SEAMMAP requested it and did
not take it, because its memory footprint is unmeasured and both lanes were
committed (NORMURAM on the workstation, CBINFER on the BC-250). **It is the only
non-hardware thing that answers whether the seam responds at `0xE000`**, and it
would settle three things that cannot be checked statically: the inferred
segment name `fk33_seam_0/s_axi/reg0`, whether module reference accepts
`fk33_seam`'s `unsigned`/`natural range` ports, and whether
`core_reset/peripheral_reset` ([0:0]) connects to the scalar `rst`. All three
fail LOUDLY at the BD stage, none silently. **Dispatch when a lane frees.**

Also open from SEAMMAP: `rtl/fk33_seam.vhd`'s `CAPS_FLAGS_V = 0x5` sets
`FK33_CAP_SAMPLER` in a bitstream with no sampler (reported to DSEAM, correctly
not fixed -- not its file); `fk33_regs.h` has no seam block and its non-thermal
bases are unpinned; `desc_ram` BRAM inference is unsynthesised.

### TRACK TIMING COMPLETE, 2026-08-30 (`9e3348e`..`5d25911`). Three results.

**1. SUBSYSTEM C CLOSES 200 MHz STANDALONE FOR THE FIRST TIME.** The 256 failing
endpoints were one structure: `c_attn/vref_r`, and `LAYERS*N_KVH*EXP_W` =
8*4*8 = **exactly 256 bits**. All forty worst placed paths ran
`vref_r_reg` to `vref_r_reg` through 28 logic levels, and the post-synthesis
report named the mechanism itself (`Logic Levels: 28 (CARRY8=8 ...)`): a SERIAL
min-fold over `NBLK`=8 seeded from `vref_r`. Reassociated into a balanced tree
with `vref_r` folded last. Min is associative, commutative and idempotent on
integers, so the change is **bit-exact and latency-neutral by construction**,
and CARRY8 is unchanged at 2,734 -- the same comparisons, re-bracketed.

MEASURED on the BC-250, before and after: **WNS -3.122 to +0.825, Fmax 123.1 to
239.5 MHz.**

**2. THE FIT, WITH RMSMUX MEASURED AND THE SQUEEZE DENSITY. The two levers are
EQUALS, correcting TIMING's own earlier claim that lever C led:**

| configuration | CLB |
|---|---:|
| RMSMUX alone | **92.1%** |
| lever C alone | **92.9%** |
| **both together** | **84.1%, the first configuration with real margin** |

**3. THE BRIEF I GAVE TIMING WAS WRONG, AND IT SAID SO.** I told it "only 256 of
1,027,089 endpoints fail". **That was the POST-SYNTHESIS count; the placed
report already on disk said 33,767.** There were two independent problems and my
brief described only the first. The other 33,511 are **net-delay, not logic**:
mean net 4.575 ns against mean logic 0.670 ns, 20,000 of 20,000 net-dominated.
The attribution control is the convincing part: **subsystem A, unchanged and
proven on silicon, fails 3,779 endpoints in this composition.** Root cause is
area, at 54,866 of 54,960 CLB.

Also retired: the post-synthesis 279,484 hold violations are an **artefact**,
collapsing to 7,881 on placement with no RTL change, and the named path has
`Logic Levels: 0`.

**NEW OPEN ISSUE, and it is the highest-value line in TIMING's report:
`tb_attn_block` PASSES A DELIBERATELY BROKEN TREE.** This is the bench named
after the unit, carrying subsystem C's bit-exact oracle, and it was found only
by running the mutant. **A guard passing for the wrong reason, in the one place
that was most trusted.** It needs an owner. Note this is the same unit that
"passed seven properties and 13 of 17 wiring mutations while computing wrong
numbers" in the CLAUDE.md verification list, so this is the SECOND time
`attn_block`'s evidence has been shown not to discriminate.

**AND THE STANDING CAUTION ON ALL THREE NUMBERS ABOVE.** Those percentages need
a density reached only under pressure, and reaching it cost **0.602 ns of WNS**
on a design whose observed failure is `[Route 35-447]` **routing congestion**,
not area. **The next question is not another area number. It is whether an 84%
configuration ROUTES.**

### SUPERSEDED 2026-08-30 by TRACK TIMING's pblock squeeze (`1ebac6e`)

**The table immediately below is SUPERSEDED. Its density constant was measured
on an empty die and is wrong under pressure.** It is kept because the levers and
their ordering are still right and because the correction is the point.

The squeeze constrained the composed design to a pblock at 85.4% of the die and
asked whether the placer would fail. **It did not fail. It placed.**

```
PS_PLACE_RC       0
PS_UTIL  lut 347906  clb 49497
PS_DENSITY        7.029 LUT per CLB
PS_WNS            -3.658
```

| | whole die free | pblock, 85.4% |
|---|---:|---:|
| CLB | 54,866 | **49,497** |
| density | 6.324 | **7.029** (+11.1%) |
| non-mux density | 5.617 | **6.553** |
| WNS | -3.056 | **-3.658** |

**Density is elastic. 6.324 was a property of an empty die, not of the
netlist** -- the same netlist packed into 5,369 fewer CLB under pressure. This
falsifies the `D_nonmux = 5.617` constant that the C4 arithmetic used. LEVERC's
mux term is untouched: 8.00 is pinned by the CLB structure, exactly as its
architectural argument requires.

| configuration | old (5.617) | **squeeze-measured (6.553)** |
|---|---:|---:|
| today + shell + ROM best | 123.5% | **110.1%** |
| **+ lever C + gain to BRAM** | 105.3% | **92.9%** |
| + lever C + BRAM + `d_norm` | 94.7% | **82.7%** |
| **+ `d_norm` + BRAM, no lever C** | 102.2% | **90.7%** |

**Two levers may suffice on CLB count. The 105.2% relayed to Oren is
superseded.**

**RELABELLED 2026-08-30 by TRACK NORMURAM: those rows said "gain to URAM" and
the resource is BRAM.** MEASURED, Vivado's own words in TRACK NWROM's log
(`/mnt/storage/nwrom/out/vivado_nw_lfura65.log:412`, sitting in the artefacts
since 2026-08-29 and never read past the result CSV):

```
WARNING: [Synth 8-10226] The ram_style = ultra set on ROM
"ooc_nwrom_memura__GCB101/gvr.nwrom" can not be honored for this device.
The URAM primitives on this device do not support initializations to any
non 0 values.  This ROM will be implemented using BRAMs
```

Both of NWROM's memory probes report **`uram=0`**. The "114 URAM288" that this
brief, TRACK SCATTER section 11 and TIMING's table all carried is the **`bram`
column of a run in which the URAM request was REFUSED and silently downgraded.**
The probe never used a single URAM.

**The LUT saving is real and unaffected; what changes is the currency.** The
gain image costs **114 to 135 BRAM tiles of the 672 on this part**, and nobody
has been charging that against a BRAM budget. RMSMUX's vectors want 6 more.
**"320 idle URAM288" is true and unusable**: URAM on this device is available
only to a store written at RUN TIME, so the only URAM-capable way to serve this
gain is the HBM route, which is a point in route (c)'s favour that no brief
made.

**No design change followed, and that is correct.** Vivado falls back to BRAM
either way; asking for `rom_style = "block"` explicitly only stops the log
carrying a WARNING that claims a resource the design never gets, which is
exactly how the misread happened.

**TIMING's own prediction was refuted on both limbs** and it says so: it
predicted the placer would either fail or stay near 6.32, and neither happened.
The pre-registered threshold of 48,000 CLB was not met at 49,497, so by the
letter the claim survives and by its spirit it does not.

**TIMING's withdrawn 93.2% and this measured 92.9% agree, and that is TWO ERRORS
CANCELLING, not vindication.** Section 7a inflated density for an
architecturally backwards reason AND under-estimated achievable density under
pressure, by similar amounts in opposite directions. **The 93.2% stays
withdrawn**; reasoning is what gets reused and none of that reasoning was right.

**AND THE CATCH, WHICH IS PROBABLY THE REAL RESULT. The squeeze bought CLB
capacity in exactly the currency this design has already run out of.** WNS went
**-3.056 to -3.658**, and the router had already declared, at the LOOSER
density, that `[Route 35-447] congestion is preventing the router from routing
all nets`. At 7.029 there is less routing resource per cell, not more.

**"Fits by CLB count" and "builds" are different claims, and this experiment
moved only the first.** A design at 92.9% CLB and 7.029 density gives the router
a HARDER job than the one that already failed. Nobody may quote a percentage
from the table above as a fit verdict.

**Everything containing "+ lever C" is gated on TRACK CBINFER**, which is
answering LEVERC's own first open item: whether Vivado infers LUTRAM from
`cb`'s array-of-array-of-`signed` at all. If it does not, lever C is 1,536
register copies, strictly worse than today, and those rows are moot.

**The fit needs THREE levers, and the ordering is not what anyone assumed:**

| configuration | CLB |
|---|---:|
| today | 121% |
| + lever C alone (IQ4_NL codebook to LUTRAM) | 115.9% |
| **+ `d_norm/gvr.u_rms` read muxes alone** | **102.2%** |
| + lever C + norm gain image out of LUTs | 105.2% |
| + all three | 94.6% |

**`d_norm` alone beats lever C alone by 13.7 points and nobody was working on
it.** It is 43,213 LUT plus 17,696 MUXF7 of 1024:1 read muxes, it has **never
run on silicon** (the token run's 64 RMS norms ran on the host), so it carries
less regression risk than lever C, which is inside `matvec_core`.

**Caveats that bound all of the above, and must travel with it:**
- The 94.6% row is **overstated by ~17,405 LUT**: TRACK NORMURAM MEASURED that
  "+32,943" is the saving from DROPPING the gain image, not MOVING it, because
  any real gain pays a 17,367 LUT `w_mant` fold wherever the table lives.
- The norm-image term is the best of six draws of the one quantity SCATTER
  ruled **NOT SAFE to quote as a point** (82,597..128,065). Range or nothing.
- `compose4` **wires nothing to anything** -- no inter-subsystem nets, no host
  plumbing. The real top adds logic and nets on top of 420,240. The total is a
  FLOOR.
- A `pblock_squeeze` (netlist unchanged, die restricted to 46,920 CLB) is in
  flight and is **the only measurement** of packing under pressure. Everything
  else about density is inference.

### The engine runs at 1/22 speed and the cause is the address map, not the RTL

DERIVED before fitting, then MEASURED to 0.32%: one core weight word is
24 weight + 3 scale beats = 27 x 32 B = 864 B; one 256-bit HBM port at 250 MHz
is 8.000 GB/s; 27 beats through ONE port = 21.60 core cycles at 200 MHz.
**Measured slope 21.67.** The card sustains 7.39-7.88 GB/s -- 92-99% of exactly
one AXI port, with 26 idle -- because **235 of 250 tensors have all 27 lane
sub-regions inside ONE 256 MiB segment**, which is the pseudo-channel granule.

The attribution control is what makes it solid: the same shipping RTL with only
the memory model swapped runs at **1.60 cycles/beat at identical `MAXOUT=16`,
`MAXB=16`, `DEPTH=512`** -- which kills the outstanding-read hypothesis
outright, including TRACK A7's `outst` depth.

**Fix is in the packer, not the RTL.** Supply model `max(1.60 datapath, M/1.25
memory)` where M = lanes per pseudo-channel: M=1 and M=2 both give **1.60**, M=3
gives 2.40, M=27 gives 21.60. **M=2 is exactly the knee**, so the shipping
default is 27 lanes on 25 segments, max 2 per PC: full datapath-floor
throughput at **75,340 tokens**, against Oren's stated 64k requirement.
**The model has NO anchor at M=2** -- flagged as its largest unhedged
assumption.

**BLOCKED:** `gen_layer_program.py` correctly refuses a striped manifest rather
than emitting a wrong program, so **nothing can emit a token program for a
striped set** until TRACK STRIPEPATH lands. The card experiment cannot run
before then.

### Decisions taken by Oren, with their triggers

- **N2 = option (a)**: the seam in front of D. "We don't want host controlling."
  `rtl/fk33_seam.vhd` landed (`9270c7a`). **`0xE000` is still assigned nowhere
  in `gen_pcieep.py`** -- the block has registers and no address.
- **Context requirement is 64k**, not 262,144. Ceiling on one card is ~202,681,
  but **X1 must be checked against the SHIPPING striping layout, never against
  202,681**, which describes a configuration nobody intends to build.
- **9B is single-card.** Two cards buy a fit and context, **not speed**.
  MEASURED: `attn_mac_array` is **exactly invariant under tensor parallelism**
  because `G := N_QH/N_KVH` divides numerator and denominator by the same N --
  the N=2 draw returned **298 DSP, identical to N=1, to the unit**. The ladder
  that does shrink it (`QH_TILE` below `G`) is available at N=1 with no second
  card, no subsystem E and no peer link. Reopens only on context, a bigger
  model, or batching.
- **Lever C reopened** by its own stated trigger. Its closure had been
  discharged against the subsystem-A-only PBLOCK route, not against A+B+C+D.

### The defect class this project keeps finding

**Guards that pass for the wrong reason. Six more today**, in addition to the
four already recorded:

1. `check_hbm_stack.py` PASSED over **7,154 ranges of which zero exist**.
2. The **42-field descriptor cross-check cannot see a wrong address.** With a
   piece's address mutated, `make_plan` reported **69 of 69 fields agree** --
   the placement is on both sides and cancels. It had the same defect via
   `hbm_base`. This is the check that was described everywhere as "gates every
   job".
3. `gen_layer_program.py --token` on a striped set emitted **311 of 311 A jobs,
   0 refused, all 6,723 bases byte-identical to the flat program's** -- a
   complete, gateware-acceptable, wrong program reported as success.
4. `tb_attn_block` -- the bench named after the unit, carrying subsystem C's
   bit-exact oracle -- **passes a deliberately broken min-fold tree**.
5. Lever C's closure in this file, discharged against the wrong design.
6. The 2026-08-25 capacity table's "9B fits with ~2.9 GiB spare" **counted
   weights only**; at 262,144 the real figure is 9.625 GB against 8.590 GB. It
   underwrote the single-card strategy for five days and survives only because
   the answer came back 64k.

**And one model failure of a different shape:** a one-parameter packing model
calibrated on a single placed design was wrong by **12 points with its sign
inverted**. It was correctly labelled ESTIMATE with its assumption stated, and
that was not enough. See CLAUDE.md.

### The machine

The workstation **hung hard at 01:25** under six concurrent Vivados --
`kcompactd0` stuck 75 s, RCU stalls, nine CPUs in soft lockup, power button,
FPGA configuration lost, ninety minutes of place-and-route destroyed. **A single
composed route leaves 233 MB free while ALONE on the box**, so no pre-flight
`free` check could ever have caught it. Rules in CLAUDE.md; the second lane
(BC-250) was idle at load 0.07 the entire night and was never used.

**The card is currently UNCONFIGURED** -- slot power was cut -- and nothing has
been reprogrammed since.

## THE REFILL RULE (read this first, every time)

**Standing instruction from Oren, 2026-08-28: the parallel slots must not go
empty while the backlog is non-empty, and this runs overnight.**

So: **every time an agent completes, before writing the report, check the
BACKLOG below and dispatch the next ready item.** Closing a track and refilling
its slot are one action, not two. It is easy to land a result, write it up well,
and only then notice that four slots have been idle for the whole write-up --
that happened once already today and Oren caught it, not me.

Target **four concurrent tracks**. Fewer only when the backlog genuinely has
nothing whose dependencies are met. If that ever happens, say so explicitly
rather than quietly running one agent.

A backlog item is READY when its file ownership does not collide with a running
track and its listed dependency has landed. If nothing is ready, the right move
is to look for what the last few results NEWLY unblocked, because every landing
today opened at least one new item.

**Discipline for closing a track.** When an agent lands, do exactly one of:

- **MARK OFF** the branch that fired, move the row to the Landed table with its
  commit, and dispatch whatever that branch names.
- **WRITE THE ISSUE DOWN** in Open issues below, with the evidence, then either
  send the agent a follow-up (if the fix is determined) or raise it with Oren
  (if it is a decision rather than a fix). Never silently retry.

Status values: `RUNNING`, `LANDED`, `BLOCKED-DECISION` (needs Oren),
`BLOCKED-DEP` (waiting on another track).

---

## WHAT STANDS BETWEEN THIS PROJECT AND 9B INFERENCE ON THE CARD

**Added 2026-08-29 by TRACK BOARDAUDIT. Every fact here is MEASURED against the
tree at `5a19f984`, and the audit went looking for it because several tracks
had each said a piece of it in their own write-ups and no place on this board
said it whole.**

**The one-sentence answer: the design routes, a bitstream exists and is loaded,
the 9B weights are resident in HBM and verified against a digest the loader did
not produce -- and NOTHING HAS VERIFIED WHAT ANY OF IT COMPUTES, because the
card carries subsystem A alone and no tool in this repository can start a job
on it.**

The five things that are true, in the order they were established:

1. **The bitstream routes and loads.** `ed1ffe2`, 0 nets with routing errors,
   288,506 fully routed, `hw/fk33/bit/fk33_pcieep_eng.bit` 22,568,402 bytes.
   Loaded on card 1: configures, links Gen3 x4, identifies as `0x464B3333`,
   SYSMON reads through the design, BAR writes work, the DMA BRAM and both HBM
   stacks round-trip. `docs/debugging/2026-08-29_first-engine-load-on-card.md`.
2. **The weights are on the card and are the right bytes.** 4,487,442,432 B
   written in 8.76 s and read back and matched against the manifest's pack-time
   `blake2b_128` and an independently written header parse. TRACK WEIGHTS,
   `9d7a9e5`. That write-up's own words: **"a loaded magazine, not a fired shot."**
3. **The card carries subsystem A and nothing else.** MEASURED:
   `hw/fk33/rtl/fk33_engine.vhd` instantiates `matvec_int4_desc_axi` and no
   other work unit. There is no B, no C, no D on the silicon.
4. **No host tool can start a job on it.** MEASURED: `gen_pcieep.py` puts the
   engine's register map at `ENG_CTL_BASE = 0x00012000`;
   `grep -rn '0x12000\|ENG_CTL' hw/fk33/host/ server/ tools/` returns nothing.
   `fk33_regs.h` has no engine block. `fk33ctl.py` has ten commands and none of
   them starts an operation.
5. **The host seam that WAS written targets a contract no gateware implements.**
   MEASURED: `server/fk33_seam.h` defines `FK33_SEAM_*` with magic `"LLM2"` at a
   base its own comment calls **PROPOSED, NOT DECIDED**; no file under `rtl/` or
   `hw/fk33/rtl/` mentions it. `server/pl_backend.c`'s third line says
   **"Nothing here has ever run against the card."**

**So there are three gaps, not one, and they are of different kinds.**

- A **tooling** gap: N1, the host-side runner for one A job, checked against
  `ref/matvec_int4.c`. Writable and testable with **no hardware** through
  `fk33_transport_open_sim`/`_filedir`; only the final run needs the bench.
- A **decision** gap: N2, whether the seam or the descriptor plane is the
  contract. Nobody should pick this for Oren.
- A **design** gap: N3, an RTL top that composes A+B+C+D for the card. It does
  not exist. `rtl/llama_top.vhd` composes all four but is a simulation top: it
  binds `matvec_int4`, which has no descriptor plane, and `C_REAL`, `C_KV_AXI`,
  `NORM_REAL` and `B_SRC_REAL` all default FALSE. N3 is blocked on B+C+D
  fitting, which is WRITEDEC and N5.

**The ordering matters and the cheap step is first.** N1 is small, needs no
decision and no new RTL, and it is the only one of the three that converts
"9B inference on the card" from an unfalsifiable claim into a measurable one.
Every schedule below it rests on arithmetic nobody has ever checked on this
silicon.

---

## File ownership, right now

Two agents editing one file has already cost this project real time. Nothing
below may be edited by a track that does not own it.

**REWRITTEN 2026-08-29 by TRACK BOARDAUDIT. The table it replaces named four
tracks that had landed days earlier (C-ORACLE, B-ACCURACY, TOK-C, A-CTRL) and
named none of the tracks actually running that night.** An ownership table that
lists dead owners is worse than none: it makes free files look taken and taken
files look free, and both errors cost a dispatch.

| path | owner | note |
|---|---|---|
| `sim/regress.sh` | **SHARED** | any track adding a test edits it. Re-read it immediately before editing, keep the edit to the rows you add, and re-check `BASELINE_PASS` at commit time. Editing it under a running instance is already safe; see the note below. |
| `rtl/rmsnorm_rs.vhd`, `rtl/gdn_block.vhd`, `rtl/attn_block.vhd`, `sim/ooc_writedec_*`, `hw/fk33/results/writedec_*` | **TRACK WRITEDEC** | RUNNING. Has already committed `51323ca` for `rmsnorm_rs` and is working through `gdn_block` and `attn_block`. |
| `sim/tb_llama_top.vhd`, `sim/realshape_gate.sh`, `sim/elab9b_run.sh`, `rtl/attn_kv_axi.vhd`, `rtl/attn_c_ports_skel.vhd` | **TRACK KVVALUE** | RUNNING |
| `rtl/llama_top.vhd`, `rtl/hbm_tg.vhd`, the `sim/micro` copies | **TRACK CLOG2TOP** | RUNNING |
| `docs/WORKLOG.md` | **TRACK BOARDAUDIT** | RUNNING, exclusively, by arrangement with Oren for the duration of the audit. Released when this track reports. |
| `hw/fk33/gen_pcieep.py`, `hw/fk33/*.tcl`, `hw/fk33/*.xdc`, `hw/fk33/gen_fk33_engine.py`, `hw/fk33/rtl/fk33_engine.vhd` | free | released by TRACK SHELL at `928ad9f`, then by TRACK PBLOCK at `ed1ffe2`. `rtl/fk33_engine.vhd` is GENERATED, so edit `gen_fk33_engine.py`. **Wanted by backlog rows N3 and N4.** |
| `hw/fk33/host/fk33_load_weights.py` | **A TRACK IS ACTIVE HERE** | Committed `4b26b7e` and `6d9c857` on 2026-08-29 while BOARDAUDIT was running: the fast residency check passed an object neither check ever read. Track name not declared in either message. **Treat as owned until it reports.** |
| `hw/fk33/host/**` except `fk33_load_weights.py` | free | never claimed by a track. **Wanted by backlog row N1**, which is the first thing to dispatch. N1 adds a NEW file and edits `fk33_regs.h`, so it does not collide with the loader work above -- but confirm that before dispatching, because this row was measured wrong once already tonight. |
| `rtl/attn_*.vhd` (except `attn_kv_axi`, `attn_c_ports_skel`, `attn_block`), `sim/tb_attn_*.vhd`, `ref/attn_*` | free | released by TRACK C-ORACLE `8baa413`, TRACK C-SEAM and TRACK RY-ORACLE |
| `rtl/gdn_*.vhd`, `rtl/l2norm_rs.vhd`, `sim/tb_gdn_*.vhd`, `ref/gdn_*`, `ref/l2norm*` | free | released by TRACK B-ACCURACY, TRACK B-FIX, TRACK B-RECUR `ea26eec` and TRACK BGATE2 `dfe308c`. **`rtl/gdn_block.vhd` is the exception: WRITEDEC holds it.** |
| `tools/qwen35_tokenizer.py`, `tools/*tokenizer*`, `server/**` | free | released by TRACK TOK-C `0181cc3` and TRACK SERVER `3963a60`. **Wanted by N2 once the decision is made.** |
| `rtl/matvec_int4*.vhd`, `rtl/weight_streamer.vhd`, `rtl/axi_rd_port.vhd`, `rtl/axi_rd_fsm.vhd`, `rtl/async_fifo.vhd`, `hw/mv_driver.c`, matvec benches | free | released by TRACK A-CTRL `a4f7e17` and TRACK OUTMODE `0ff6828`. **Wanted by backlog rows N7, N8 and N10.** |
| `tools/gen_layer_program.py`, `tools/dprog_oracle.py`, `tools/hbm_map.py` | free | released by TRACK D-PROG `a2b20f3`, TRACK SCHED-FIX and TRACK ARENA-MANIFEST `b28e92b` |

**A COMPLETED AGENT CAN STILL WAKE UP AND COMMIT.** Observed 2026-08-28: the
subsystem-A-sim track reported done, was superseded, and then woke hours later
and committed `2b12a7b` while TRACK A-CTRL already owned those files. It landed
clean (a doc correction plus a comment in `sim/regress.sh`, `BASELINE_PASS`
untouched, the bench itself not touched) so nothing was lost, but that was
luck rather than design. Consequences:

- "Completed" is not "released". A track's ownership row stays until its files
  are verified quiescent, not merely until its report arrives.
- After any late commit, re-run the affected tests yourself rather than
  trusting either agent's report. That agent explicitly said its own
  confirmation run never returned and declined to claim it, which was the right
  call; the run was completed separately and all three passed.
- Prefer giving a superseded track NO further instructions. Sending it a
  follow-up is what turns a harmless late commit into a genuine collision.

**`git commit -m msg -- <paths>` COMMITS THE WORKING TREE, NOT THE INDEX.
THREE INDEPENDENT TRACKS HIT THIS ON THE SAME DAY** -- C-ORACLE, B-ACCURACY,
and me, the last of them one commit after documenting it. B-ACCURACY hit it in
its most deceptive form: it staged a single hunk of the shared `regress.sh`
with `git apply --cached` and then named the file on the commit line, which
discarded the careful staging entirely. It caught this only because the
committed `--stat` disagreed with the staged one, 22 lines against 7.

Three instances in a day means this is not an advisory to be more careful; it
is a property of the command that has to be worked around structurally. **On a
shared file: stage the hunk, then commit with NO pathspec.**
Observed 2026-08-28: TRACK C-ORACLE's first commit swept in TRACK A-CTRL's
uncommitted `sim/regress.sh` edits (`BASELINE_PASS=78`, rows for tests whose
files were not committed yet) purely because they were sitting in the working
tree at that path. It caught this and amended them out, and HEAD is clean, but
the pathspec form is the exact form this project's standing instruction
mandates in order to AVOID `git add -A`, so the two rules fight each other on
shared files.

The rule that resolves it: **for a SHARED file, run `git diff -- <file>` and
confirm every hunk is yours BEFORE committing.** If it is not, stage only your
hunks with `git add -p` and then commit with no pathspec so the index is what
lands. For files only your track owns, the pathspec form is still correct and
still the default.

An amend is only available while the bad commit is still the tip. Two tracks
committing within a minute of each other would have made it permanent.

**Editing `sim/regress.sh` under a running instance is ALREADY SAFE, and you
do not need to `pgrep` first.** bash reads a script lazily by byte offset, so
in general editing a script mid-run resumes the shell mid-token and the process
that dies is not the one that edited it. `sim/regress.sh` was bitten by exactly
this three times during its own development, once to a third party, so section
0 now copies the file to a private temp path, syntax-checks the copy in case
the original was mid-write, and re-execs that (`:287`, `:299`). From then on
the running process reads a file nobody else can name.

Recorded because a track disclosed having edited it during another run and
could not rule out damage. There was none, and there could not have been. The
disclosure was still the right call: reporting a suspected collision you cannot
disprove is worth more than a silent hope, and the answer only took one grep.

**CORRECTION, appended: commit `4891c6d` mixes two authors' work.** Its
message describes only my `regress.sh` note; everything else in it is TRACK
A-CTRL's own worklog update, swept in by a pathspec commit while A-CTRL was
editing the same file. Nothing was lost and A-CTRL's content is intact; the
defect is a message that described half its contents. It could not be amended,
because another track committed on top within the minute -- which is the
failure mode recorded two paragraphs above, reproduced against its own author
inside an hour.

The root cause is worth more than the incident. I ran the prescribed check,
saw it print DIRTY, and committed anyway, because I had chained the check and
the commit into one command so the check merely PRECEDED the action instead of
GATING it. **A check whose result you do not branch on is decoration.** Run the
check as its own step, read it, then act.

**Standing rule for every track: no hardware.** No `xsdb`, `hw_server`,
`vivado ... program`, `pcieep.sh`, `jtag.sh`, `flash.sh`, `program.tcl`, and
nothing that opens `/dev/xdma*`. A live FK33 is in this session, and an agent
has already destroyed its factory flash image by crossing that line.

---

## In flight

**This section is REWRITTEN at every dispatch, not appended to.** I set that
rule on 2026-08-29 after an independent review found it listing two tracks as
RUNNING a day after both landed, and then broke it myself across eight
consecutive dispatches. Appending is one action and retiring a row is another,
and only the first feels like progress. If this table names a track that has
landed, the table is the defect.

**Corrected 2026-08-29 by TRACK BOARDAUDIT: BGATE2 had LANDED (`dfe308c`) and
was still listed here as RUNNING, which is the defect this section's own rule
names. It is moved to Landed. BOARDAUDIT is added, because it was running and
was not listed.**

**REWRITTEN 2026-08-31 by the dispatcher.** The four rows this table carried
(READCONV, ACOV, NWROM, GRAY1) were all long landed or answered: READCONV's
question was subsumed by RMSMUX/RMSWIRE (the read muxes are gone, measured),
ACOV is backlog row N8 (open, undispatched), NWROM was answered by NORMURAM
and GWTWO (the image is in BRAM at 135 tiles, then the codebook at ~99), and
GRAY1 is backlog row N10 (open, undispatched). Naming them here as RUNNING was
the defect this section's own rule describes.

**REWRITTEN 2026-09-14 by the dispatcher.** Both rows this table carried
(CARDOOC running, CARDSMALL scheduled) are CLOSED. CARDOOC was stopped by Oren
at 60.5 h; CARDSMALL and seven follow-on probe rounds answered the question.

| track | state | outcome |
|---|---|---|
| **CARDOOC** | **STOPPED 2026-09-14 by Oren, at 60.5 h** | Never left `RTL Elaboration`. Stopping it returned `MemAvailable` 2,346 -> **26,923 MB** and swap used 24,155 -> 3,417 MB. |
| **CARDSMALL + rounds 1-8** | **CLOSED** | The wall is INSIDE `RTL Elaboration`, and the trigger is the inter-subsystem WIRING. See `docs/debugging/2026-09-14_the-wall-is-a-3d-ram-vivado-warned-about.md`. |

**The Vivado lanes are now BOTH FREE.** Workstation: 26.9 GB available, zero
Vivado. BC-250: zero Vivado.

### What rounds 0-8 established

**The wall is in `RTL Elaboration`**, proven by `synth_design -rtl` with
`fk33_engine` as the control: the control completes in 115 s
(`Finished RTL Optimization Phase 1`), while `fk33_llama_top` and `fk33_card`
print `Starting RTL Elaboration` at t = 4 s and never print `Finished`.

**The trigger is the wiring, not the parts.** Two tops carry A+B+C+D at the real
9B shape and differ in exactly one property:

| top | wired between subsystems? | outcome |
|---|---|---|
| `compose4_top` | **NO** (co-residency; `gen_compose4_top.py` says so outright) | synthesises, places, **ROUTES**: WNS -0.422, 286,806 nets |
| `fk33_llama_top` | **YES** (sequencer glue, region-file client muxing) | never finishes RTL Elaboration |

**Every individual entity elaborates and synthesises fine**, in seconds to
minutes: `vec_mem` 17 s, `sampler_stream` 17 s, `seq_vec_issue` 17 s,
`region_mem` 46 s, `rmsnorm_rs_mem` 58 s, `matvec_int4_desc_axi` 166 s,
`fk33_engine` 170 s.

**Nothing reachable by a generic changes it**: context (32x), `C_REAL`,
`C_KV_AXI`, `NORM_REAL`, `B_STATE_AXI`, `HOST_WINDOW`, and all three
`-flatten_hierarchy` modes are indistinguishable. `A_DESC` and `A_ROWS_IF`
cannot be varied at all (`8-549` port width mismatch).

**`-flatten_hierarchy none` is REFUTED as this flow's justification.**
`ooc_card_dcp.tcl`'s header rests the whole approach on it; `none`, `rebuilt`
and `full` differ by under one second and 0.02 GiB.

**A 60-hour question is now a 5-minute one.** `-rtl` on `fk33_llama_top`
reproduces the wall in 37 s.

### Measured, and worth keeping

- **`HOST_WINDOW => false` is worth 100 BRAM tiles and 7,176 LUT.** Isolated
  `region_mem`: `false` gives lut=4038 ff=27 **ramb=100**; `true` gives
  lut=11214 ff=3611 **ramb=0**. This CONFIRMS `region_mem.vhd`'s header claim
  ("a memory with a combinational read port CANNOT be a BRAM") by measurement,
  and the card's setting is correct.
- **First UNTHROTTLED card-OOC memory figure: 7.97 GiB** (`memory.events`
  `high 0, max 0, oom 0`). Every previous card figure was a cap.
- **The card half wants at least 39.1 GiB**, not the 15.52 GB the tcl header
  claimed; that figure was a mid-run sample of a job that never finished.

### Named lead, NOT measured

`fk33_llama_top`'s **per-client element port muxing** around the region file --
the file's own words are "Per-CLIENT element ports, muxed below", where a client
is not a unit ("unit V is an ADAPTER in front of NVOP engines, and each engine
needs its own port"). A combinational mux across clients x `NREGION` x `REGMAX`
is the shape that stalls elaboration. Test by reducing the client count or mux
width and re-running `-rtl`.

**CARDSMALL was a SCALING PROBE, not an attribution experiment** (historical; it returned a null result and rounds 1-8 followed). `C_MAXPOS`
and `C_CTXLEN` move together deliberately as one "context size" axis. A result
does NOT attribute the wall to either generic individually, and must not be
written up as if it did.

Design notes, because `fk33_card` has **no generic clause at all** (it is
generated by `hw/fk33/gen_fk33_card.py` and hardcodes the generic map into
`fk33_llama_top`), so `-generic` cannot reach the shape -- the recorded rule
that **`-generic` reaches only the TOP's generics, never a deep instance**
applies here:

- Both inputs are DERIVED ON THE BC-250 from the synced tree at run time, by
  `sed` over `hw/fk33/rtl/fk33_card.vhd` and `hw/fk33/ooc_card_dcp.tcl`, so
  they cannot drift from it. The repo files are never modified.
- The card `sed` is asserted to change **exactly 2 lines**, and the tcl `sed`
  is asserted both to no longer read the full-shape card AND to read the
  reduced one. Either assertion failing aborts the point.
- The orchestrator refuses to start unless the SYNCED card is still
  full-shape (`131072`), so a probe cannot silently measure a reduced tree.
- Point 2 **chains on point 1's anchored sentinel** (`^CARDOOC_WROTE `), with
  the `/proc/PID/exe` presence check as the safety net -- per the recorded
  rule that presence is a lane check, not a queue, and two waiters on
  presence alone both start.
- A game-running check (`ps -eo comm=` matching `\.exe$`, never the full
  cmdline, because the Steam reaper carries the exe path in its own argv)
  holds the launch off if Oren is still using the box.
- `MemoryMax` + `MemorySwapMax` are the guard the 2026-09-05 incident lacked:
  a runaway gets its own cgroup killed instead of thrashing the box offline.

Memory budget at dispatch, stated per the global-budget rule: **workstation**
31 GiB, `llama-server` 18, `cardooc` 22.7 resident under a 24G cap, swap free
13.2 GB -- nothing new is launched here. **BC-250** 15.2 GB RAM + 47.4 GB free
swap, zero Vivado, one job capped at 12 GB RSS. Two lanes, one tool each; no
third Vivado anywhere.

**TRACK CARDTOP was dispatched and RECALLED the same hour, 2026-08-31.** It
went to a harness subagent, and Oren's ruling is that the subagent model is
not strong enough for VHDL/RTL design work. **No subagents for RTL tracks
from here.** Audit on recall: no commits, no edits to any tracked file; its
only output was four new files, quarantined UNREVIEWED to
`/mnt/storage/cardtop_flash_draft_2026-08-31/` (a 5,363-line
`fk33_llama_top.vhd` draft plus three sketches). Do not copy anything back
without a full review. STEP 3 (row N3) returns to undispatched; when it runs,
it runs in the dispatcher's own session.

The dispatcher also holds: teeth Run B (gate for the floor-103 commit), then
the full gate on the final tree at the new HEAD.

**Landed since the last rewrite:** OI3B, COMPOSE, WEIGHTS, REALSHAPE, REALFIX,
SEAMGATE, RY-MODEL, SCHED-FIX, ORDINAL, ARENA-MANIFEST, KVSIZE, CGENERICS,
BUILD-E2E, GATEHYGIENE, BTOP1, LUTDIET, CKVMAP, CLOG2, BGATE2 (`dfe308c`),
BOARDAUDIT (`7c5f5a3`..`d7952b6`), KVVALUE (`ef1aa7e`), WRITEDEC (`971524c`),
AJOBRUN (`1fdf42e`), CLOG2TOP (`61e6a12`), ERRINFO (`a269ed4`, row N12),
NORMADAPT (`45981f0`), OI3MUT (`3853650`, row N6), RESETLAND (`8b7eefe`),
GATEGREEN (`392f818`, `df0b194`), BASEFAB (`d7a6bf7`), STRIPEREADY (`0eac8d4`,
`639880e`), TRIPVETO (`729df43`), TOKENSTRIPE (`6ca385f`, `a25847b`),
STRIPEPATH (`d7f96cd`, `9d73018`), SEAMMAP (`1e46fb3`), TIMING
(`9e3348e`..`5d25911`), ATTNTEETH (`5755473`, `a8053ca`, `1e18ce3`), NORMURAM
(`c479ae8`, `57ecea4`, `5026897`), CBINFER (`0d24f7d`), LEVERC48 (`a4828ab`),
RMSMUX (`5152e91`), RMSWIRE (`47c9d9c`), GWTWO (`21db25b`, `93ddac7`,
`c3a2f01`), ROUTE2 (through `48633e5`).

### The fit, corrected. MY ARITHMETIC WAS STRUCTURALLY WRONG.

I told the board that NORMADAPT's 129,877 LUT target was "four times the
31,359 `pb_core` gap". **That subtraction was never valid**, and NORMADAPT
caught it: the 31,359 shortfall comes from the OPTIMISTIC booking, whose
`D_norm` is the bare `rmsnorm_rs` with **no adapter storage at all**. You
cannot reduce a shortfall computed from a total that never contained the thing
you removed. The 129,877 figure was also a MODEL and overstates by 52% -- the
real adapter's own logic is 102,204, and `wv` **does not exist in `llama_top`**.

MEASURED position now: **realistic B+C+D = 273,844 LUT**, over the device by
**5,622** and over `pb_core` by **40,079**, against 350,457 before NORMADAPT.
What NORMADAPT actually bought was collapsing the gap between the optimistic
and realistic bookings from 85,333 to **8,720**. **READCONV is the remaining
lever**, and TRACK NWROM may yet move the number the wrong way.

## ROW N1 IS ANSWERED. SUBSYSTEM A COMPUTES CORRECTLY ON THE FK33.

MEASURED 2026-08-29 20:12-20:16 by the dispatcher on card 1, under Oren's
one-night authorisation. **Twelve jobs. All eight distinct `(M, K)` geometries
in the 9B model. Every mantissa and every `y_exp` bit-identical to
`ref/matvec_int4.c`.** `err_code=0x0 (EC_NONE)` throughout; `BEATS` matched
`tiles*nblk` exactly every time. Write-up:
`docs/debugging/2026-08-29_first-arithmetic-on-the-silicon.md`.

The load-bearing row is `blk.11.attn_k.weight --rows 100`: that is the **exact
argv `sim/regress.sh:1428` feeds `sim/tb_matvec_fk33`**, on a byte-identical
file, so the card and the simulator agree on the same job. The two awkward
geometries were chosen deliberately: `M = 8224` is the only shape in the model
that is **not** a multiple of 32, and `M = 248320` is the lm_head (run at 64
rows, one window inside the 17,408 cap -- this does **NOT** contradict LMHEAD's
finding that the gateware refuses it as one job).

**Every result is unconfounded by THERM-255, and that was checked rather than
assumed:** counter cleared at 20:12:27, read 0 before and after every job,
`LATCHED TRIP none since the last clear` still true at 20:16.

**What this does NOT establish:** subsystem A alone. `fk33_engine.vhd`
instantiates `matvec_int4_desc_axi` and nothing else, so **B, C and D have
never run on this silicon** -- row N3 stands. One activation vector per job,
supplied by the host; nothing here exercises a layer, a sequence or the KV
cache. And one row-count per geometry, so an off-by-one at a window boundary
is not excluded.

**Tracks that landed and appear NOWHERE on this board, found by TRACK BOARDAUDIT
2026-08-29.** Each has a full write-up in `docs/debugging/` and none is named in
any Landed row. Recorded here rather than reconstructed into rows, because the
write-ups are the artefact and the point is that the board lost them:
**PBLOCK** (`ed1ffe2`, `2026-08-29_shell-pblock.md` -- the routed bitstream),
**FIRSTLOAD** (`2026-08-29_first-engine-load-on-card.md` -- the bitstream loads,
links and identifies; three instrument defects; the memory finding raised then
withdrawn),
**CARD2** (`2026-08-29_second-fk33-verify-and-flash-backup.md` -- card 2 works,
its factory flash is dumped and double-read),
**SERVER** (`3963a60`, `2026-08-29_host-seam-v2.md` -- backlog row 5),
**B-RECUR** (`ea26eec`, `2026-08-29_gdn-recur-coverage-and-dm.md` -- backlog row 8),
**SPECREC** (`f65e2bc`, `2026-08-29_spec-reconciliation.md` -- backlog row 9;
this one DOES have a Landed row, so the board contradicted itself),
**CAPTURE** (`2026-08-29_capture-llama-top-r9bs.md`),
**C-SEAM** (`2026-08-29_c-seam-layer-interleave.md`),
**CDC-STATIC** (`be982b3`, `2026-08-29_cdc-static-analysis.md`),
**ADDRARENA** (`2026-08-29_addrarena-one-hbm-map.md`),
**EMBED-BF16** (`2026-08-29_embedding-bf16-upgrade.md`),
**HOST-EMBED** (`2026-08-29_host-embedding-gather.md`),
**REFTOKEN** (`2026-08-29_ref-token-automatic-verdict.md`),
**LOGITS-SEAM** (`2026-08-29_logits-seam-model.md`),
**GDN-ORACLE** (`2026-08-29_gdn-block-oracle.md`).
**MEASURED: `grep -ci` on this file for each of those filenames returned 0.**
Three of the four dispatches wasted today were onto work whose write-up was
sitting in `docs/debugging/` unreferenced.

**CORRECTION, appended the same night: fifteen was a sample, and the real
figure is far worse.** A full inventory of all **91** write-ups dated 2026-08-28
or 2026-08-29 measured that only about **18 have a row in the Landed table at
all**. The remainder split two ways, and the second is the larger problem:

* **18 tracks are named ONLY by the bare "Landed since the last rewrite"
  sentence above** -- OI3B, COMPOSE, WEIGHTS, REALSHAPE, REALFIX, SEAMGATE,
  RY-MODEL, SCHED-FIX, ORDINAL, ARENA-MANIFEST, KVSIZE, CGENERICS, BUILD-E2E,
  GATEHYGIENE, BTOP1, LUTDIET, CKVMAP, CLOG2. Every one is committed and fully
  written up, and none has a commit, a result or a single line a reader
  scanning `## Landed` would ever see. **A name-drop is not a record.** That
  sentence is the single densest piece of under-recording on this board.
* **Roughly 35 more appear NOWHERE**: no filename, no track name, no commit.
  They include whole subsystems of the day's work -- `fk33-spi-flash-boot`,
  `fk33-thermal-protection`, `fk33-free-running-observability`,
  `hbm-stack-boundary-straddle`, `llama-top-first-seams`,
  `subsystem-c-top-and-mac-array`, `cdc-and-fifo-coverage`,
  `codebook-coherency-oracle`, `three-range-defects` (the commit that actually
  fixed OI-2, OI-7 and OI-8), and `thermal-guard-255-trips`, **which is an OPEN
  hardware defect and is now recorded as THERM-255 above.**

**The generalisation, and it is the reason the board keeps failing this way.**
The commit log cannot be used to recover this: only **2 of 183** commits since
2026-08-28 use the `TRACK X:` convention, and 95 distinct message prefixes were
counted. **The reliable index is the write-up header**, because nearly every
file in `docs/debugging/` declares its own track and, where it has one, its own
backlog row number. Anyone auditing this board again should start there and not
with `git log`. And the cheap fix for the future is one line: **when a track
lands, its Landed row cites the write-up FILENAME**, so a `grep` can find it.

**AN OPEN CONTRADICTION, RECORDED RATHER THAN PAPERED OVER.** CKVMAP reported
"the real 9B KV map elaborates" (2,452,864 kB / 2.36 s, `realshape_gate` PASS
24). CLOG2 reported, as its load-bearing finding, that **`C_MAXPOS = 131,072`
cannot elaborate and fixing `clog2` cannot make it**: the argument is
6,803,283,968, **3.2x `natural'high`**, so it cannot be FORMED as a `natural`;
a perfect `clog2(natural)` moves the ceiling only to 123,361, still short; and
at 131,072 the overflow moves EARLIER, into `llama_top`'s own
`constant KVREG_B : natural := C_LAY*C_NKVH*C_MAXPOS*REC_B_C` = 2,281,701,376.
Both may be true of different configurations -- CKVMAP deliberately did not
change the default and called the real map a build configuration. **TRACK
CLOG2TOP is dispatched to settle it.** `C_MAXPOS = 131,072` is Oren's decision
and is not being reopened; if it does not elaborate, it gets made to.

**Two of my own framings were wrong and are corrected here.** (1) I told CLOG2
that `llama_top:785` "blamed a bystander"; it MEASURED that `:785` WAS the
failing `while` line inside the local `clog2`. **Missing attribution, not
misattribution** -- it names the function correctly and fails to name the
caller. (2) I said fixing `clog2` would unblock the KV map. It does not and
cannot; that is what the `clog2(unsigned)` overload exists for, and on the real
value it returns **33**, exactly `C_KV_ADDR_W`, corroborating CGENERICS'
zero-slack finding by an independent route.

**B+C+D CLOSES, and the cheapest fix is not the one anyone expected.** LUTDIET
(`4950666`) MEASURED that decoding the variable-index write with a per-word
generate and a CONSTANT index takes `rmsnorm_rs` from 169,746 to **40,804 LUT**
at identical ports, identical FF, identical WNS and **zero BRAM** -- a 76%
reduction with no memory and no interface change. That alone projects B+C+D at
**210,890 LUT against 233,765 free in `pb_core`**, against COMPOSE's 2.88x-over
starting point. The margin is 22,875 LUT, **9.8%**, which is positive and thin.

**It also corrected the mechanism, and the correction changes where to look.**
COMPOSE described the cost as a mux tree. The mux tree is **17.5%** of it.
**80.5% is the variable-index WRITE into the flat register, and that structure
uses ZERO MUXF7 and ZERO MUXF8** -- so hunting this cost by its F7/F8 signature
finds one fifth of it. Same split by netlist census in B (79.8% write / 8.9%
read, 88.7% of 585,430 primitives) and C (54.1% / 3.5%).

**Two of my own figures were wrong and are corrected here.** "Lose roughly 500K
to fit" was the DEVICE number; `pb_core` needs **538,135**. And COMPOSE
UNDERSTATED the composition: it booked D's norm at 169,746, the unit WITHOUT
the vector storage `llama_top` must add, while B and C included theirs. With
it, D's norm is 299,030 and B+C+D is ~901K, not 772K.

**`BASELINE_PASS` IS NOW 93, AND THE OLD 101 WAS UNREACHABLE ON EVERY TREE.**
GATEHYGIENE (`1399425`, `5154518`, `7676510`) found the gate had been printing
`REGRESSION: FAIL` for **every track since `e788a0e`**, including on the working
tree it was calibrated against. The planner globs `sim/tb_*.vhd` off the
FILESYSTEM and nothing distinguished a row backed by a committed file from a
private one, so two tracks counted the same two untracked benches and neither
was wrong on what it could see. 93 is a MEASURED clean-`git archive` ceiling
(97 rows, 4 NOCHECK, FAIL 0); the working tree measures **99**, the difference
being ~20 rows a clone does not get. The gate now names those rows and
**refuses to suggest raising the floor** while the list is non-empty.

**CGENERICS stopped rather than editing `rtl/llama_top.vhd` under BTOP1**, which
was the instruction and is why its remediation is a handoff rather than a
collision. That remediation -- encode C's KV bases in the format's own 16-byte
granule, `C_K_BASE_CH` 282,598,912 and `C_V_BASE_CH` 353,902,080 -- is the first
thing to dispatch when BTOP1 releases the file. It is blocked on CLOG2 too: the
chunk-domain sum needs a `clog2` that does not overflow.

**Standing instruction to every track: nothing may be run against the card.**
A SECOND FK33 arrived 2026-08-29; its factory flash image was backed up the
same day and is the only surviving copy of a SQRL factory image, card 1's
having been destroyed by an agent that crossed this line.

**This is NOT contradicted by the overnight authorisation in the Decisions
table, and the distinction is the whole point.** Oren authorised **himself**,
on 2026-08-29 only, to JTAG-configure card 1 and run host-side tests. That is a
DISPATCHER-level act by the person at the bench. **The TRACK-level prohibition
above is unchanged, unconditional and absolute**: no agent runs `xsdb`,
`hw_server`, `vivado ... program`, `pcieep.sh`, `jtag.sh`, `flash.sh`,
`program.tcl`, anything under `hw/fk33/host/`, or anything opening
`/dev/xdma*`, whatever any decision row says. A track that reads the
authorisation as applying to itself has misread it. Backlog row N1 is written
to respect exactly this split: an agent writes and fully exercises the runner
through `fk33_transport_open_sim`/`_filedir`, and only the final run is Oren's.

**This note previously said "there is no bitstream at present in any case".
That is no longer true.** TRACK PBLOCK's `ed1ffe2` produced a routed,
timing-clean bitstream (`hw/fk33/bit/fk33_pcieep_eng.bit`, 22,568,402 bytes).
The instruction is unchanged and now carries its full weight: the constraint is
the hardware boundary itself, not the absence of anything to load.

## Open, raised 2026-08-29, each needing a decision rather than more work

| # | item | state |
|---|---|---|
| **BUILD-HANG** | **A FK33 shell build has been hung for 27.6 hours and nothing noticed.** MEASURED 2026-08-29 19:05 by reading `/proc`: pid 1043119 (`vrs`) has been blocked on `wait_on_run synth_1` since **Aug 28 15:27:12**, with **7 minutes of CPU across 27.6 hours** and 2.5 MB RSS. It is not slow, it is stopped. The cause is worse than a hang: `launch_runs` printed `Time (s): cpu = 00:00:17` and **reported success**, but `synth_1` **never started** -- there is no `runme.log`, no `.vivado.begin`/`.end` marker, and no `synth_1` directory in `fk33_pcieep.runs/` at all, only the `bd_*` sub-runs. `wait_on_run` then waited forever for a run that did not exist. The parent is reparented to systemd, so the agent that launched it is long gone and never got an answer. **This is the project's own recurring defect class in a new place: a command that returns success while doing nothing, paired with a wait that cannot time out.** Any future shell build can hit it, and the symptom is indistinguishable from a legitimately long place-and-route. Scratch is `<scratchpad>/pcieep3`, 138 MB, left intact for inspection. | **PROCESS CLEARED, DEFECT OPEN.** Oren approved the kill 2026-08-29; pids 1041037/1043086/1043119 are gone and 83 GB of cold scratch from landed tracks was cleared alongside it, taking root from 98% to **91%** (38 G to 121 G free). The `pcieep3` scratch was among the ten removed. **The defect itself is untouched:** the REAL fix is a bounded wait plus a post-`launch_runs` assertion that the run directory exists, and it belongs to whoever next owns `hw/fk33/gen_pcieep.py`. Until then any shell build can hang indefinitely with a symptom indistinguishable from a long place-and-route. |
| **THERM-255** | **THE THERMAL GUARD TRIPPED 255 TIMES OVERNIGHT AND IT WAS NOT HEAT. OPEN, UNRESOLVED, AND RECORDED NOWHERE ON THIS BOARD UNTIL NOW.** Found by TRACK BOARDAUDIT 2026-08-29 in `docs/debugging/2026-08-29_thermal-guard-255-trips.md` (`0540c35`), which is an OPEN write-up whose own status line says a watcher is running. MEASURED on card 1 at `06:00.0` running `fk33_pcieep_therm.bit`: the trip counter was cleared to 0 and read **255** about 14 hours later, which is the SATURATING maximum of an 8-bit field, so the true count is 255 or more -- roughly **one trip every three minutes**. Every temperature was cool (die 35.3 C peak 37.3 against a 90 C halt; HBM 37/37 peak 38 against 85; both SYSMON stickies 0) and `trip_cause` was **0** on a saturated counter. What WAS set is `THERM_STATUS` bit 30, **the two HBM temperature copies disagreed, a CDC fault**. Working hypothesis, NOT confirmed: the HBM staleness path declares the sensor invalid after `G_STALE_MS` = 250 ms without a fresh accepted sample and correctly fails safe by treating an invalid sensor as HOT. **EACH TRIP HALTS THE COMPUTE DOMAIN.** | **OPEN, AND IT MATTERS TONIGHT.** Oren is authorised to load and run on card 1 on 2026-08-29 in order to answer backlog row N1. On a card doing real work this defect presents as **random stalls with no apparent cause**, and the write-up's own words are that it is "precisely the class of fault that gets attributed to the wrong subsystem for a week". **So before believing any N1 result, read the trip counter and the CDC sticky, and read them AFTER the run as well as before.** A stalled or wrong N1 result with a non-zero trip count is not evidence about subsystem A. **Measurement trap already recorded by that write-up and worth repeating here: a 60-second clean sample is NOT evidence of absence at a three-minute mean interval** -- twelve consecutive clean 5-second samples were taken and proved nothing. Note the engine build is a different bitstream from the thermal build this was seen on, so whether the same guard behaves this way in `fk33_pcieep_eng.bit` is itself unmeasured. |
| **IPREPO-DRIFT** | **Three copies of `util_pkg.vhd` under `ip_repo/*/src/` drift with nothing in the tree able to notice.** MEASURED by TRACK CLOG2TOP: they are regenerated from `rtl/` by `ip_repo/package_llama_ip.tcl`, and **nothing schedules that script** -- no gate row, no build script, and `sim/regress.sh` never mentions `ip_repo` at all. TRACK CLOG2's note that "the next packaging run fixes them" describes **a run that does not exist**. So `rtl/util_pkg.vhd` gained a corrected `clog2` tonight (`209d69e`) and the three IP copies still carry the overflowing doubling loop, silently. | **OPEN, no owner.** Two candidate fixes and they are not equivalent: a gate row that regenerates and diffs (catches drift, costs a Vivado invocation), or a cheap checker that compares the copies to `rtl/` byte-for-byte and refuses (catches drift with no Vivado, but cannot catch a packaging script that is itself wrong). Note this is the same class as the `sim/tr.txt` hole GATEHYGIENE closed: a load-bearing input that no gate reads. |
| **DESC-RULE2** | **`tools/gen_mv4i_desc.py`'s second base rule omits the `align4k()` that `ref/matvec_int4.c:474` and `tools/pack_int4.py:477` both apply.** MEASURED by TRACK AJOBRUN. At `GRP=1` with `K` in {4096, 12288}, `tiles*nb*port_b` is always a multiple of 4096, so **rule 2 agrees with rule 1 by coincidence of geometry on every file it has ever seen** -- and falsely refuses anything else (measured: `M=96 K=128` gives `[4096, 8192]` against `[4096, 4352]`). **That two-rule cross-check is the only guard against the one descriptor corruption the gateware cannot see**, so it is currently a guard that passes for the wrong reason. AJOBRUN's `selfcheck` carries a probe that MEASURES and PRINTS it without asserting, so it flips green when fixed. | **OPEN, no owner.** Small and self-contained. Worth doing before any shape outside the current model is packed, because the failure mode is a guard that has never actually discriminated. |
| **B-CONV-HIST** | **Raised by TRACK BTOP1 (`bf99d39`), and it is the cost of its own fix.** Opening `tvalid` so the causal conv has history turns `cvdata_p`'s zero taps from inert into a **live wrong number** under `B_SRC_REAL`: a zero mantissa carried at a real captured exponent. Both checkers refuse it independently -- `S_GO` asserts and `gdn_oracle.py` raises -- so this is not a silent defect, which is the good news. A real history needs a new `(KCONV-1) x qkv_dim` buffer, **ESTIMATE ~90 MB of GHDL signal at the 9B shape**, in the file TRACK REALFIX just fought a 46 GB signal down to make elaborate at all. BTOP1 **refused it rather than bodging it** and listed it open, which was right. Note `B_SRC_REAL` is already unrunnable for a separate `R_ALPHA` reason at `rtl/llama_top.vhd:52-58`, so nothing regresses today by leaving this. | **CLOSED AS WON'T-FIX, Oren, 2026-08-29.** `B_SRC_REAL` is not wanted, so the buffer is not built. **The two refusals stay and are the guard: `S_GO`'s assert and `gdn_oracle.py`'s raise must NOT be deleted as dead code by a later cleanup on the grounds that `B_SRC_REAL` is never true.** That deletion is exactly how a won't-fix becomes a silent defect. See the Decisions table; reopening requires fixing `R_ALPHA` first, so it is two problems, not one. |
| **B-BLK-1** | `rtl/gdn_block.vhd:958` maps value head h to key head `h/(VAL_HEADS/KEY_HEADS)` (contiguous) where the model tiles, `h mod KEY_HEADS`. MEASURED wrong on 30 of 32 value heads at the 9B shape. `VPK` appears in exactly one RTL file, so nothing downstream compensates. B spec sections 2.9 and 4 both give the RATIO and neither says WHICH heads, which is the proximate cause. | **DECIDED** 2026-08-29: fold into TRACK B-LAYER, now in flight |
| **BFP repack rule** | The 9B reference's float-to-BFP repack always normalises (`reg_put`, `exp = 14 - floor(log2(amax))`, no clamp); every shipping unit on the path clamps (`sh = max(0, msb_pos(amax) - 14)`) and so stays under-normalised on quiet blocks. MEASURED by RUNNING `rtl/bfp_pack.vhd`: 341 of 760 exponents differ, all quiet blocks, none loud, reconstructed VALUES exact. **193 of 490 BFP records per token (39.4%) are on the unclamped rule, so `--mode exact` reports a FALSE first divergence before reaching any real defect.** Three routes scoped in section 6 of REF9B's write-up; they are not equivalent. | **OREN'S CALL.** TRACK CAPTURE told to work around it and report which route the capture work says is needed, NOT to pick one |
| **`matvec_int4_axi` register 15** | No completeness guard and no idle interlock, so a partial codebook load through that plane is silently consumed. It is the standalone register-mapped plane; the FK33 path uses `matvec_int4_desc_axi.vhd`, which loads all sixteen atomically and rejects an unloaded codebook with `EC_DESC`. | Left as a decision, not a fix. Not on the FK33 path |
| **OI-9 error-code space** | Full. Widen, subdivide via `ERR_INFO`, or take a reserved D value, with consequences for D. | **DECIDED, Oren, 2026-08-29: SUBDIVIDE VIA `ERR_INFO`**, because it leaves the byte layout untouched. No longer a decision; it is backlog row N12. D-PROG was told to STOP and report rather than choose, and that was right. |
| **AXIRD-FRST** | **`frst <= rst;` in `rtl/axi_rd_port.vhd`'s `g_sc` generate is DEAD, and this is the THIRD time it has been found.** Raised first by TRACK ACOV as its mutation row `B1`, flagged again to TRACK FLOOR, and written down here so a fourth rediscovery costs nothing. RE-MEASURED 2026-08-29 by TRACK FLOOR, by enumerating every occurrence of the signal in the file: declared `:157`, driven `:203` (inside `g_sc`) and `:241` (inside `g_dc`), and READ at only `:282` and `:292`, **both of which are inside `g_dc`**. Exactly one generate elaborates, so under `DUAL_CLK = false` the signal is driven and never read. The `g_sc` FSM and FIFO both take `rst => rst` directly. Harmless to the netlist -- synthesis drops a dangling driver -- but it reads as though the single-clock branch has a FIFO reset that is used, and it is a mutation site no bench can cover, which is why ACOV scored it. | **OPEN, and deliberately NOT fixed by TRACK FLOOR: `rtl/**` was outside its ownership and the correct move was to record it rather than reach.** The fix is one deleted line and belongs to whoever next owns `rtl/axi_rd_port.vhd`. Note the deletion is only safe together with the observation above that no read survives outside `g_dc`; a reader who deletes the `g_dc` assignment at `:241` instead breaks the dual-clock path. **RE-VERIFIED AT HEAD 2026-08-29 by TRACK STRAYROW, and THE LINE NUMBERS ABOVE ARE NOW STALE** -- `75f95a8` (TRACK A7) added `abort_c` and the `gate_chk` process to the same file and moved everything down. Identify it by CONTENT, not by line: the dead driver is the bare `frst    <= rst;` that is the FIRST statement inside `g_sc`, and the live one is `frst  <= rst_s2;` inside `g_dc`. MEASURED at `75f95a8` with `grep -n frst rtl/axi_rd_port.vhd` against the generate boundaries from `grep -n 'generate' rtl/axi_rd_port.vhd`: declared `:157`; driven `:239` (inside `g_sc`, which spans `:236`-`:273`) and `:309` (inside `g_dc`, `:276`-`:372`); READ only at `:357` and `:367`, both inside `g_dc`. **The finding is unchanged and the warning is unchanged: the safe deletion is the `g_sc` driver, now `:239`, NOT the `g_dc` one, now `:309`.** TRACK STRAYROW did not fix it -- `rtl/**` was outside its ownership too, and it was told explicitly to confirm and record rather than reach. Raw measurement in `docs/debugging/2026-08-29_strayrow-gate-row-and-three-handoffs.md` section 5.7. **This is the fourth finding and the second re-measurement; the next reader should be able to act on it without re-deriving anything.** |
| **IPSYNC-DOC** | **`ip_repo/check_ip_sync.py`'s docstring now documents a defect that has been FIXED, which is the same trap TRACK FLOOR just cleared out of `tools/lmhead_window_check.py`.** Its "THE HONEST WEAKNESS" note says `hw/package_mac_axi.tcl` and `hw/package_matvec_engine.tcl` "both END IN AN ERROR, `Unknown property 'CONFIG.ASSOCIATED_BUSIF' on bus_interface`, after `ipx::save_core` has already run". TRACK FLOOR fixed both scripts 2026-08-29 and MEASURED the before and after with Vivado 2023.2 (pre-fix rc=1 and no `PACKAGE_DONE`; post-fix rc=0, `CLOCK_ASSOC: s_axi`, `PACKAGE_DONE 1`). The surrounding paragraph is still correct and worth keeping -- the checker genuinely cannot see a packaging script that is itself wrong -- so only the worked example is stale. | **OPEN, no owner. `ip_repo/**` was outside TRACK FLOOR's ownership**, so it recorded this instead of editing, which is the same call it made on AXIRD-FRST. **CLOSED 2026-08-29 by TRACK STRAYROW (`15b2f39`), exactly as FLOOR asked.** The worked example is kept in its FIXED form rather than deleted: it now states that it was first recorded by TRACK NOGUARD, that TRACK FLOOR root-caused and fixed it in `d2adbcd`, and that the MEASURED before/after was pre-fix rc=1 with no `PACKAGE_DONE` against post-fix rc=0 with `CLOCK_ASSOC: s_axi` and `PACKAGE_DONE 1`, citing `docs/debugging/2026-08-29_floor-and-three-defects.md`. The surrounding weakness paragraph is untouched. **Deleting the example would also have broken a live cross-reference in the other direction:** `hw/package_mac_axi.tcl:36` points back at this note by name. VERIFIED at HEAD rather than taken from this entry -- both packaging scripts now read the value through `ipx::get_bus_parameters` and `error "PACKAGE FAIL"` if it is not `s_axi`, and both are committed clean. MEASURED after the edit: `--selftest` `SELFTEST PASS` with `CHECK ALONE=6`, live run `IPSYNC: 3 IP(s), 32 packaged .vhd, 0 finding(s)` / `IPSYNC: PASS`. A sweep for siblings citing the same example found none: the only other live citations of `ASSOCIATED_BUSIF` outside `docs/debugging/` are the two fixed scripts themselves. |
| **STRAY-NEXTJOB** | **A reset that lands with bursts outstanding leaves `axi_rd_port` delivering the PREVIOUS job's beats as the NEXT job's, and this is now REPRODUCED rather than argued.** It is the open item in section 8 of `docs/debugging/2026-08-29_a7-dual-clock-run-gate.md`, which TRACK A7 raised and deliberately did not fix. MEASURED 2026-08-29 by TRACK STRAYROW (full write-up `docs/debugging/2026-08-29_strayrow-gate-row-and-three-handoffs.md`, control E) on the COMMITTED RTL with A7's `outst` clamp present, using `sim/tb_axi_rd_port_stray.vhd` with its `DRAIN_WAIT` cut from 200 to 4 core cycles: all three clock ratios report a value-oracle failure, `BEAT got 3133 want 5120` at `anear`, `got 3108 want 5120` at `aslow`, `got 3155 want 5120` at `afast` -- a beat from a burst issued BEFORE the reset, handed to the consumer as the new job's word 0. **The clamp does not touch this. It is a wrong-numbers failure, not a hang.** The mechanism is in `rtl/axi_rd_fsm.vhd`: after a reset `arv = '0'` and `outst = 0`, so a following `start` satisfies `S_DRAIN`'s exit condition immediately, the clear runs, and pre-reset beats then land in `S_RUN` and are written to the FIFO. On the FK33 the two reset nets genuinely differ (`core_aresetn` against the XDMA's `axi_aresetn`), so the slave keeping its queue across the port's reset is the SHIPPING case, not a bench contrivance. | **OPEN. It is a DESIGN DECISION, not a fix, and it is deliberately NOT taken by one track.** A7 section 6 sets out the fork: preserving `outst`/`arv` across `rst` so `S_DRAIN` waits for the strays is correct if the slave does NOT share the reset (the FK33 case) and HANGS if it does (the case `sim/tb_axi_rd_port_dual.vhd`'s J7 models). **Nothing says the card computed anything wrong**: it needs a reset mid-job followed by a restart inside the drain window, and the shipping flow has not been shown to produce one. The gate row is parked on the safe side at `DRAIN_WAIT = 200` so it goes in GREEN; the oracle that catches this is already in the file, so whoever takes the decision shrinks one constant and has the check. `rtl/**` was outside TRACK STRAYROW's ownership. |

### OI-3b, raised by TRACK C-SEAM 2026-08-29 -- the purest instance yet

**`sim/tb_llama_top_seq.vhd` PASSES with defect C1 fully restored** (299 s,
`OVERALL PASS 1 FAIL 0`). As a negative control -- because a PASS is otherwise
indistinguishable from a mutant that never reached the checker -- `v_ref` was
collapsed to a SINGLE register shared across every layer AND every KV head,
strictly worse than C1. **It PASSES again** (319 s).

Cause: the `R_X` landmark is `report`ed, never `assert`ed. Its actual gate is
self-consistency across KV read latencies, and **a deterministic defect is
consistent with itself.** The bench's own header already said "still PASS"
before and after C1's fix; the same fact sat in the file, unread as a gap.

MEASURED by the dispatcher, and stronger than reported: four of the six
`tb_llama_top*` benches carry NO assert at all, and `_seq` carries neither
assert nor report.

    tb_llama_top       45 asserts    tb_llama_top_seq        0
    tb_llama_top_smp   16 asserts    tb_llama_top_real       0
                                     tb_llama_top_normw      0
                                     tb_llama_top_smp_beh    0

**That is a lead, NOT a verdict**, and the distinction must be kept: `regress.sh`
judges rows TEXTUALLY via `FAIL_RE`/`PASS_RE` (`:1207`), so a bench with zero
asserts can still fail correctly by PRINTING `MISMATCH`, and one with many
asserts can still be decoration if they do not cover the value. C-SEAM's
empirical negative control is the real evidence. **TRACK OI3B owns this.**

Generalisation from C-SEAM, worth keeping: interleaving the layers is necessary
and nowhere near sufficient. Only schedule **plus an independent value oracle at
the output** kills the mutant.

### The BACKLOG table is not being maintained

Three landed rows were found still open today (1, 12, and OI-4), and one of them
caused a track to be dispatched onto finished work. The In flight section has a
rule about exactly this and the BACKLOG table has none. **Strike a row in the
same action that lands it.**

### TRACK REALSHAPE, 2026-08-29: the real shape has never elaborated, and it is the DEFAULT

`ghdl -r llama_top` with **no generic overrides** dies: 24.9 GB, 18.2 s,
`STORAGE_ERROR : grt-table.adb:58`. VERIFIED INDEPENDENTLY by the dispatcher:
`mk_shape(MODEL, NCARDS)` occurs **exactly once in the whole VHDL tree**, at
`rtl/llama_top.vhd:168`, as `llama_top`'s OWN DEFAULT, commented "Defaults to
the real build target. A simulation passes `mk_shape_scaled(...)`."

**So the never-elaborated configuration is the top level's default -- the one
synthesis gets if nobody overrides it.** Every simulation ever run has passed
the scaled shape instead.

The wall is not a subsystem. `gdn_block` standalone at the exact 9B generics
takes 0.35 s / 299 MB. It is one declaration: `rtl/llama_top.vhd:2731-2733`
models B's per-layer recurrent state as a **signal** array of 201,326,592 bits.
MEASURED ~228 bytes per GHDL scalar signal, so DERIVED **~46 GB**. The same
bits as a process variable measured **206 MB / 0.17 s**.

Six defects, five invisible at `mk_shape_scaled`. The sharpest is **R4**:
`attn_kv_axi:455`'s guard `NBLK <= 16` is UNREACHABLE at the shipping
`HEAD_DIM 256`, so the illegal value prints `overflow detected` with no line
number, and at `HEAD_DIM 32/64` the same value prints the named assert. It also
makes `llama_top:3650`'s mirror guard dead. **Zero margin, hit exactly by the
shipping geometry, and one step past it the diagnostic vanishes.**

`VN_W` 14 gives only 1.33x at 9B and **fails outright at 27B** (`ffn` 17408),
which matters for the stated end goal.

**The prize:** with `stmem` shrunk in a throwaway probe, the FULL composition
including real B elaborates in **2.09 GB / 1.93 s**, so a real-shape
elaboration gate row is affordable. TRACK REALFIX is going for it.

### Raised by TRACK D-PROG, 2026-08-29 -- the most serious of the day

**Every check on the layer program was an agreement check against the schedule
itself.** Two were further transcriptions of it (`seq_tbl_pkg`,
`llama_sched_pkg`), one asked only whether a descriptor is well FORMED (the
gateware has no idea which tensor a job should have used), and the fourth
diffed a run against a run driven by the second. That column is jointly
compatible with a program that is internally perfect and computes the wrong
model, and the earlier write-up said so itself.

`tools/dprog_oracle.py` is the first check that is not: it decodes the EMITTED
BYTES against artefacts from other sources -- llama.cpp's execution order via
`tools/ref9b/seam_map.py`, the packed `manifest.json`, and decisively each
`.mv4i` file's own 4 KB header, whose sub-region offset table at `0x38` pins
every weight base exactly. On the generated program: **39,330 checks, 0 FAIL**,
whole token, 505 steps. Teeth: 25 of 27 mutations killed, including **all six
that the earlier table recorded as RTL-silent**.

**Then the same oracle was run against `--stamp sched`, byte-identical to
`sim/llama_sched_pkg.vhd`, the table `llama_top` actually executes: 2,401
FAILS.** 311 `w_exp`, 253 `out_shift`, and `nsub_w = 29` on every step, which
the FK33's A wrapper refuses with `ERR_GEOM`. Byte-identity against a walker
test proves the step SEQUENCE agrees and says nothing about the numbers a real
run needs. **TRACK SCHED-FIX confirmed the numbers and CORRECTED the framing (`78e2f5a`).**
It reproduced the dump independently, without D-PROG's tool, and byte-compared:
0 mismatches of 4,040 words, so the transcription is faithful.

**But the 2,401 is three different things and only one is a defect, and the
headline was wrong in a way that matters.** `sim/llama_sched_pkg.vhd` is NOT
"the table `llama_top` actually executes" in any shipping sense: it is
`sim/`-only, consumed solely by `sim/tb_llama_top.vhd:484`, and in no synthesis
flow. VERIFIED INDEPENDENTLY by the dispatcher: `llama_top` appears nowhere
under `hw/`, and `hw/fk33/rtl/fk33_engine.vhd` wraps `matvec_int4_desc_axi`,
i.e. **subsystem A only, no D on the card today.** That is not a quibble that
shrinks the finding; it is WHY the finding was invisible.

**The real defect, fixed:** `nsub_w`/`nsub_s` were 29/4, the superseded
`ROWS_IF=58` budget, carried in under comments claiming they were "the real
ones". Right values 24/3, confirmed from an artefact no generator wrote: every
packed `.mv4i` header's own bytes (`nports_w` at `0x1A`, `n_scale_sub` at
`0x34`). All 311 A jobs would have been refused before `start` with `EC_GEOM`
(NOT `ERR_GEOM`, which does not exist) and a polling driver would hang.

**Seven independent reasons it went unnoticed**, the last being the one to
generalise: `seq_desc_fetch` only range-checks against `NSUB_MAX=64`; the base
array is not fetched yet; `llama_top:2280` binds `matvec_int4`, which has no
descriptor plane, so no `tb_llama_top*` row can contain an `EC_GEOM` check;
`tb_a_geom` restated the constants itself; `check_a_geometry.py` covered two of
four numbers; no D on the card; and **the two generators agreed with each
other.** Producer-versus-producer agreement is not evidence.

**Deliberately NOT "fixed": `w_exp`/`out_shift`.** `llama_sched_pkg` emits at an
arbitrary shape with no tensor to take a value from, and the ranges are
measured constraints. The 1,157 residual failures are the CORRECT result and
are now asserted to stay.

**OI-4 is STALE at HEAD and should be closed.** `tools/gen_layer_program.py`
(1,015 lines) landed at `a2b20f3`: job sequencing, region routing and the D
fields A does not read all exist. Backlog 6's items 1 to 3 were already done.

Two corrections worth carrying: **`token_embd.weight` needs ZERO descriptor
jobs, not 15** (host-side gather into `R_X`; the 505-step program contains no A
job on it), and "one matvec job is emitted" understates it by 310 -- **311 are
emitted and all pass**. `output.weight`'s 15 windows are confirmed.

**Trap to propagate:** `gen_layer_program.py` defaults to the PRE-QKV-PAD packed
set, where 48 of 311 A jobs are refused. **Always pass `--manifest`.**

**OI-9 preference, asked for and NOW ACTED ON:** subdivide via `ERR_INFO`. It
already carries a word index, so it costs neither a format change nor a
reserved D value. **Oren chose exactly this on 2026-08-29.** D-PROG's preference
was recorded and then sat unasked for a day, which is the deferral-becomes-a-
decision failure mode this board has its own section about.

### Raised by TRACK DESC-MUT, 2026-08-29

* **Two weakening mutations are stopped only by a declared VHDL integer range.**
  `S5` and `F3` accept a descriptor that should be refused, and the only thing
  preventing it is a range declaration, **which is a bit width in synthesis and
  not a check**. So they are caught in simulation and would NOT be caught on the
  card. Recorded as ABORT rather than counted as kills, which is the honest
  reading. No owner.
* **`EC_CORE` (0xE) is reachable by no bench in the tree.** Mutation `R1` deletes
  the `core_err -> EC_CORE` path and survives both judges. Closing it needs a
  stimulus no bench currently produces.
* **"Refused for the right reason" is recoverable for only 6 of 9 error codes**,
  and this is now MEASURED rather than suspected. `EC_DESC` (0x3) is raised at
  nine sites with two confirmed collisions even with `ERR_INFO` pinned. Not
  fixable by renumbering: `EC_SHAPE` took the last 4-bit value, which is OI-9,
  and `ERR_INFO` is a word index by construction.
* **Subsystem A coverage gaps:** `rtl/matvec_int4.vhd` and `rtl/axi_rd_port.vhd`
  have no mutation script; `USE_XEXP_PORT=true` appears in NO bench at all; and
  `DUAL_CLK=true` is a manual run, so the descriptor-path CDC, whose absence
  once broke 17 of 22 cases, has no automatic coverage.

### Two blind spots recorded, with no owner

* **Gray coding has no automated defence, and TRACK BOARDAUDIT narrowed that to exactly one class.** TRACK CDC-STATIC landed real machinery (`sim/cdc_teeth.sh`, `sim/mutate_async_fifo.sh` class GRAY `G1`..`G6`, `docs/debugging/2026-08-29_cdc-static-analysis.md`, `be982b3`) and it closes two of three classes: the encoder/decoder MISMATCH (`G2`) is killed by simulation, and the 2FF-vs-1FF MTBF class (`G3`/`G4`/`C6`) by `report_cdc`. **What remains undefended is `G1` alone: both gray functions replaced by identity, consistently.** It is worse than uncaught -- the binary-pointer design reports TWO FEWER `report_cdc` warnings than the correct one, so any "the report must not get worse" rule PASSES it. Vivado classifies by width, depth, ASYNC_REG and fan-in and never inspects an encoding. Simulation and static analysis are complementary on topology and **both blind to the encoding.** The CDC-STATIC write-up says this about itself in its own section 7; backlog row N10.
* **`K2b`, a standing hazard, not a task.** `P_CB_CHK`'s idle invariant watches `cbw_v(0)`, the command REGISTER, not the write. Any future change that deepens the codebook command path makes the invariant vacuous with nothing in the tree noticing. Lever C is no longer being taken (the shell routes without it), but the hazard is not specific to lever C.

## Decisions taken, with their triggers

**Why this section exists.** An independent review on 2026-08-29 named
"decisions deferred so long they have quietly become decisions" as a failure
mode of this project. A deferral with no recorded trigger is indistinguishable
from having forgotten. Each row below says what was decided, by whom, on what
evidence, and **what event should reopen it**.

| decision | by | on what evidence | trigger to revisit |
|---|---|---|---|
| ~~**Congestion fallback is lever C (IQ4_NL codebook to LUTRAM)**, pre-authorised.~~ **TRIGGER FIRED, DECISION CLOSED AS NOT NEEDED.** | Oren, 2026-08-29; closed by TRACK BOARDAUDIT 2026-08-29 | CONGEST measured the codebook at 86,992 primitives, 39.5% of `matvec_core`, and 97.7%/98.8% of the design's MUXF7/MUXF8. ~7.1x win, zero throughput cost. Risk is a 32x write-coherency surface. | **The stated trigger was "if TRACK PBLOCK routes the design, the fallback is not needed", and PBLOCK routed it at `ed1ffe2`** (0 nets with routing errors, 288,506 fully routed). Lever C was not taken and its 32x write-coherency surface was never opened. The row stayed live for a day after the event that retired it. Reopen only if a LATER build fails to route; the pre-authorisation stands, and the standing condition still holds -- **if lever C is ever taken, its oracle work is dispatched ALONGSIDE, not after.** Note `K2b` in the blind-spot list is a hazard in this same code and is NOT specific to lever C, so it does not close with this row. |

### LEVER C REOPENED 2026-08-30 -- its own stated trigger has fired

The row says **"Reopen only if a LATER build fails to route; the
pre-authorisation stands."** A later build is failing to route. No new decision
from Oren is needed; this records that the condition was met.

**The closure reasoning was evaluated against the wrong design, and that is
worth naming as a defect in the decision log rather than in the RTL.** The
stated trigger was "if TRACK PBLOCK routes the design, the fallback is not
needed", and PBLOCK routed `ed1ffe2` cleanly. But **PBLOCK routed the
subsystem-A-only shell.** The design that has to fit is A+B+C+D, which did not
exist in routable form on 2026-08-29. A trigger discharged against a smaller
design than the one it was protecting is the same shape as the guards-that-pass-
for-the-wrong-reason class in CLAUDE.md.

**MEASURED by TRACK TIMING, 2026-08-30**, from COMPOSE4's surviving placed
checkpoint plus its own runs:

- Placed CLB occupancy **54,866 of 54,960 = 99.83%**, congestion level 7.
- **33,767 failing endpoints after placement**, not the 256 the post-synthesis
  report shows. Of the 20,000 worst, **20,000 of 20,000 are net-dominated**:
  mean net delay **4.575 ns** against mean logic delay **0.670 ns**.
- Attribution control: **subsystem A alone fails 3,779 endpoints** while being
  byte-for-byte the entity that closes 200 MHz on the card today. It cannot
  have acquired a logic problem by being placed beside B, C and D.
- WNS after `phys_opt_design` **-2.834 ns** (from -3.056).

**The fit arithmetic, which is the real answer to N3:**

```
composed 346,971 + shell 40,326 + norm image 32,943 = 420,240 LUT
raw LUT:  420,240 / 439,680 = 95.6%          <- looks survivable, and is not the constraint
at the MEASURED 6.32 LUT/CLB -> 66,494 CLB of 54,960 = 121%
at 7.0                        -> 60,034 CLB           = 109%
at an unreachable 8.0         -> 52,530 CLB           =  96%
```

**The binding constraint is CLB packing density, not LUT count.** That is
exactly why lever C is more valuable than its LUT saving suggests: CONGEST
MEASURED the codebook at 86,992 primitives, 39.5% of `matvec_core`, and
**97.7% / 98.8% of the whole design's MUXF7 / MUXF8**. MUXF7/F8 pin LUTs into
specific CLB slots, so removing them attacks the 6.32 directly. **Do not
justify lever C on its ~7.1x LUT win alone; the packing effect is the point and
it has not been measured.**

**CORRECTION 2026-08-30, from TRACK LEVERC (`845ea28`): the MUXF7/F8 figures
above are the A-ONLY SHELL build's, and this block applied them to the COMPOSED
fit. That is the same defect this block was written to record, committed inside
it.**

MEASURED in the composed A+B+C+D, from TRACK TIMING's own `TT_MUX` census: the
codebook is **37.7% of MUXF7 (24,576 / 65,108) and 47.6% of MUXF8
(12,288 / 25,788)** -- not 97.7% / 98.8%. `d_norm/gvr.u_rms` alone carries
17,696 F7 and 8,736 F8, and `c_attn/u_arr` another 15,796 F7. **Attribution corrected the same day:** I wrote here that TIMING had made the
same substitution in its section 7a. **It had not, and that accusation is
withdrawn.** TIMING applied 97.7% / 98.8% to `a_eng`'s OWN census, explicitly
labelled as such, giving 24,297 MUXF7 against LEVERC's structural
**24,576 = 1536 x 16** -- 1.1% agreement, and as a share of the composed design
its figure reads 37.3% / 47.5%, the same quantity. **The substitution was mine
alone.** I inferred a second instance from a superficial reading and published
it as a finding about another track's work.

**A second correction, which reverses the sign of the argument.** This block
said removing MUXF7/F8 "attacks the 6.32 directly" because they pin LUTs into
CLB slots. LEVERC's arithmetic says the premise is backwards: **a MUXF8 shape
occupies 4 LUT6 in one CLB half and wastes none of them, so a paired mux region
sits at exactly 8.00 LUT/CLB -- the device maximum.** The codebook mux is the
DENSEST structure in the design, not the loosest, and removing it LOWERS the
average density. An indivisible shape costs the placer freedom, not LUT sites.

Bounded rather than point-estimated, since the non-mux logic also cannot exceed
8 LUT/CLB (which refutes the fully-unpaired extreme by arithmetic):

```
mux-region density        4.69 .. 8.00 LUT/CLB
CLB saving from lever C   3,072 .. 8,946
overshoot (11,534 CLB)    27% .. 78% closed
post-lever-C occupancy    104.7% .. 115.4%
density moves             6.05 (down) .. 6.66 (up)   from 6.324
```

**Lever C alone does not close the fit under either bound.** That agrees with
TIMING's conclusion while removing the reasoning both of us used to reach it.

**`K2b` is CLOSED** by the same track, independently of whether lever C ships.
`P_CB_CHK` watched the command register; re-aiming it at "the last stage" does
not fix it, because the next change moves past that too. The new `P_CB_MODEL`
watches no register at all: it rebuilds the write path from the entity's ports,
delays it by a declared `CB_WR_LAT`, and requires `cb` to equal it every copy
every cycle. **Its attribution control denied credit for thirteen of fifteen
apparent detections** -- without it the table would have claimed fifteen where
two are real.

Standing condition carried forward from the original row and still binding:
**if lever C is taken, its oracle work is dispatched ALONGSIDE, not after.**
Its known risk is a 32x write-coherency surface. `K2b` remains a standing
hazard in this same code and is not specific to lever C.
| **Tandem PCIe, ALL OF IT: deferred until 9B inference works on the card.** Not just the Field Updates hierarchy question -- the whole subject, including MCAP and ICAP. Do NOT restructure the shell for it, and do NOT spend a slot on it. | Oren, 2026-08-29 (superseding his earlier 'decide after it routes') | The earlier deferral was already the right call on TANDEM's own evidence (`abbd2ed`): its stage-1 pblock excludes `SLICE_X216Y0:SLICE_X232Y239` at DRC severity **Error**, **50,135 placed cells sit inside it**, and there is nothing to the right of `SLICE_X232` so every one of them moves LEFT into the half that already fails to route. Oren has now widened it: a bitstream-reload path is worth nothing until there is a bitstream worth reloading. | **9B inference running on the card.** Not 'the design routes' -- routing is necessary and nowhere near sufficient. Until then the standing procedure is the warm JTAG configure into a live root port plus `echo 1 > /sys/bus/pci/rescan`, which WORKS and is documented in `docs/debugging/2026-08-28_fk33-first-light.md`. **Nobody should re-litigate the reload path before then.** Accepted costs, both real: retrofitting the three-partition hierarchy later is the expensive path, and the card still cannot configure itself at power-on. |
| **Logits egress is the full writeback, NOT on-card top-k.** Not a judgement call in the end. | evidence, confirmed by dispatcher 2026-08-29 | EGRESS measured writeback at 124 us, **0.32% of the 38.27 ms budget** and 32x oversupplied vs the 300 MB/s A can produce logits at, on two already-reserved idle pseudo-channels. The fabric direction is INVERTED from the intuition: top-k's logic lands inside `matvec_core`, which is 72-81% of every level-6/7 congestion window, while the writeback lands at the die edge. Top-k also loses repetition/frequency penalties, `logit_bias` outside k, speculative verification, and the oracle at the seam that decides a token, and makes `top_p` an approximation whose error the host CANNOT DETECT. | If the writeback is ever measured to add materially to `matvec_core`'s congestion. Two unexplored options are recorded in `docs/debugging/2026-08-29_logits-egress.md`: top-k plus the exact normaliser, and C2H from the existing 43-BRAM36 result buffer. |
| **Card 2's factory flash: DUMP IT, and this is NOT a Tandem question.** It was previously bundled into the Tandem trigger and should not have been. | dispatcher, 2026-08-29 | Card 1's SQRL factory image was **destroyed** by an agent crossing the hardware boundary. Card 2's copy is the ONLY surviving one and is card 1's restore path. That value is independent of Tandem, of routing, and of inference. `hw/fk33/flash.sh` already has a readback mode; it writes nothing, but note its own warning that **readback IS itself a JTAG configuration**, so the card stops running the factory image until a power cycle. Check VCCINT is above the 0.698 V floor first, and treat an all-0xFF or all-0x00 readback as a **failed read that looks like a backup**. | **DONE 2026-08-29, and this row did not say so.** `docs/debugging/2026-08-29_second-fk33-verify-and-flash-backup.md`: card 2 self-configured from its own SPI flash (`CFG_DONE 1`, every BOOT_STATUS error bit clear) and the flash was read out to `hw/fk33/bit/fk33_factory_backup_153300001366.{bin,mcs}`. **Teeth on the readback: it was read TWICE and the two reads are md5-identical (`dcb97432538b9c7d2855b1d9c93658f7`)**, which is the check that separates a real backup from an all-0xFF read that looks like one. Two findings came free: **the SQRL factory image does NOT raise VCCINT** (card 2 measured 0.677 V running it, never observable before because card 1's image was destroyed), and `jtag.sh` was resetting the WRONG CARD's FTDI regardless of `FK33_TARGET`, now fixed. **What is NOT done: the backup has no off-disk copy.** It is untracked in git and sits only on a root filesystem at 91%. That is backlog row N9 and it is trivial. |
| **OI-9, the full descriptor error-code space: SUBDIVIDE VIA `ERR_INFO`.** Not widening the code field, and not raiding a value reserved for subsystem D. | Oren, 2026-08-29 | It keeps the descriptor's byte layout UNCHANGED, so nothing already byte-pinned in `docs/2026-08-28_matvec-descriptor-format.md` moves -- and that format is the one artefact subsystem A, subsystem D and the host builder all read, and the one that has already been verified. `ERR_INFO` already carries a word index, so the sub-case rides in a field that exists. Accepted costs, both real: **`ERR_INFO` stops being free for anything else**, and the host decoder gains a second lookup. | `ERR_INFO` being needed for a second purpose, or the sub-case count outgrowing that field too. **This is no longer a decision and backlog row 10 is struck**; it becomes a dispatchable implementation item owning `rtl/matvec_int4_desc_pkg.vhd`, `rtl/matvec_int4_desc_axi.vhd`, the host decoder in `server/pl_backend.c` and `sim/tb_matvec_fk33_desc.vhd`. |
| **B-CONV-HIST: CLOSED AS WON'T-FIX.** `B_SRC_REAL` is not wanted, so the causal conv does not get a real history and the `(KCONV-1) x qkv_dim` buffer is not built. | Oren, 2026-08-29 | `B_SRC_REAL` is **already unrunnable for a separate `R_ALPHA` reason**, recorded in `rtl/llama_top.vhd`'s own header: with it TRUE the degenerate-residual count RISES, 0/3/10/23 -> 3/5/11/24 at 4/8/16/32 blocks, because A's synthetic weights make `R_ALPHA`'s VALUES physically impossible and `gdn_scalar`'s gate saturates shut. So nothing regresses by leaving this. The buffer BTOP1 refused would have been an ESTIMATE ~90 MB of GHDL signal at the 9B shape, in the file TRACK REALFIX had just fought a 46 GB signal down to make elaborate at all. | **THE TWO REFUSALS ARE THE GUARD AND MUST NOT BE REMOVED AS DEAD CODE BY A LATER CLEANUP.** `S_GO` asserts and `tools/gdn_oracle.py` raises, independently, on the zero-mantissa-at-a-real-exponent value; that is why this closes as won't-fix rather than as a latent defect. Deleting either refusal because "`B_SRC_REAL` is never true" is precisely how a won't-fix becomes a silent defect. **Reopen only if `B_SRC_REAL` is wanted, and note that is TWO problems, not one: `R_ALPHA` has to be fixed first.** |
| **Hardware, overnight 2026-08-29: OREN PERSONALLY may JTAG-configure card 1 and run host-side tests.** | Oren, 2026-08-29 | Backlog row N1 cannot be answered without it: the bitstream is loaded, the weights are resident, and no arithmetic has ever been checked on this silicon. | **THIS CHANGES NOTHING FOR AGENTS. The no-hardware rule for every track is absolute and unchanged.** Scope, and it is narrow: JTAG configure of **card 1** and host-side tests, by Oren, **scoped to the night of 2026-08-29 and not a permanent grant**. NOT authorised, by anyone: any VCCINT change (stay at wiper 68, ~0.717 V), any flash write, anything touching **card 2**, and any subagent doing any of it for any reason. Card 2's factory image is the only surviving SQRL factory image in existence and is card 1's restore path. |
| **`C_MAXPOS` = 131,072 for the 9B bitstream**, not the 233,396 the resized arenas allow. | Oren, 2026-08-29 | KVSIZE's resize took the arenas from 61,229 to 233,396 tokens, so both values fit and the choice was never a derivation -- TRACK CGENERICS said so explicitly and set neither. 131,072 is Qwen3.5-9B's own native context; everything past it depends on RoPE extension work that does not exist, so the extra 102,324 tokens would be capacity the weights cannot use. Costs ~44% of the arena as headroom. | RoPE scaling landing, or an arena needing the space back. Note `C_KV_ADDR_W = 33` is NOT freed by this: CGENERICS measured it exact with **zero slack** at the chunk-domain sum, and only a value SMALLER than 131,072 would change it. |
| **Cross-stack read measurement on the card: NOT taken.** Needs hardware; raised with Oren and never confirmed. | pending | 12 of 27 masters read cross-stack; a stack offers at most 15 engine ports. | **PREMISE FALSIFIED 2026-08-29 by TRACK BOARDAUDIT.** The stated reason for deprioritising was "the design does not route, so there is no engine bitstream to measure with". **The design routes (`ed1ffe2`) and the engine bitstream has been loaded on card 1**, links Gen3 x4, and both HBM stacks round-trip through the host BAR at 0.51 GB/s write / 0.78 GB/s read. So the blocker is now only the hardware boundary and Oren's time, not the absence of a bitstream. It is still not urgent -- it should follow N1, because measuring the bandwidth of an engine that has never been shown to compute anything is the wrong order. |


## Open issues

### OI-1: RESOLVED 2026-08-28 -- descriptor in memory

A is bit-exact at the FK33 geometry and the HBM can serve its 27 masters
(30 already measured at 288.0 GB/s, 100% of ceiling). Three things stand
between that and arithmetic on silicon, and the first is a decision:

1. **The register map.** `rtl/matvec_int4_axi.vhd:252,265` asserts
   `NPORTS_W=4 / NPORTS_S=1` and holds four `W_BASE`/`W_BASE_HI` pairs plus one
   `S_BASE` pair. FK33 needs 24+3. Its own header argues the map must NOT grow
   with a generic, on the grounds that it would be "a map no driver could
   parse". So this is a fork, not an edit.
2. **The HBM-to-core CDC does not exist.** `weight_streamer` is single-clock.
   At ACLK = f_core the duty is exactly 100% with zero margin, so the CDC is
   mandatory.
3. **`axi_rd_port`'s `MAXOUT` defaults to 2** (32 outstanding beats); the
   measured 288 GB/s run used 16.

Items 2 and 3 are determined work. **Item 1 was Oren's call and is now
answered: descriptor in memory.** All three landed 2026-08-28 as TRACK A-CTRL
above. This issue is closed; the record is kept because the rejected options
and their costs are the part worth re-reading.

**Two gaps opened by that work, both MEASURED by
`sim/tb_matvec_fk33_desc.vhd`'s mutation table, both deliberately NOT closed:**

- **A well-formed base pointing at the WRONG sub-region is undetectable.**
  Case 19 aims weight sub-region 7's base at sub-region 8's bytes. The design
  accepts, computes and reports success, and 4 of 100 result elements are wrong
  -- exactly the two rows that bit slice 7 carries, in each of the two live
  tiles. Nothing in the descriptor says what a sub-region should CONTAIN, so
  only the weight store's own hash can catch this. Same family as OI-3.
- **A `w_beats` that is too small HANGS.** Case 20 halves it; the array starves
  and the job never completes and never errors, because `WDOG_LIMIT` covers the
  descriptor FETCH only. Not a wrong answer, but a driver polling for
  `done or err` waits forever. Closing it needs a compute-phase watchdog whose
  limit is a per-geometry number, which is a decision rather than an
  implementation, so it was left for Oren.

### OI-2: `attn_emit.vhd:400` is a bound violation at `NGRP = 1` (latent)

**RESOLVED at HEAD, 2026-08-29.** `rtl/attn_emit.vhd` no longer assigns
`grp <= 1` anywhere; `:410` is now a comment documenting the old defect, and
the `NGRP = 1` case takes an explicit `grp <= 0; state <= S_SHIFTS`. VERIFIED
by reading the file at HEAD, not by trusting this entry. The description below
is kept for the record and is no longer the state of the tree.


`grp` is declared `integer range 0 to NGRP-1` (`:263`) and line 400 assigns
`grp <= 1` unconditionally. `NGRP` is `positive`, so `NGRP = 1` (one KV head)
is a legal generic value that is an immediate bound violation. Default is 2,
so nothing hits it today. Found by the integration track, verified directly,
deliberately not fixed.

### OI-3: the bench cannot see two classes of defect

Of nine mutations on the integration bench, **two pass while broken**: an
exponent claim re-aimed at R_X, and the prefetch consuming at k-3. Both change
every element and no property in the bench can observe either. Fourth and fifth
instance of the same family. This is the honest ceiling on what `tb_llama_top`
proves, and it is not closed by any track above.

**UPDATE 2026-08-29, TRACK BOARDAUDIT. Probably closed, and NOT MEASURED, which
is the whole point of saying so.** TRACK OI3B (`5578132`) gave the family a real
value gate: `sim/tb_llama_top.vhd`'s `P14` fires when
`results(0)(NTOK-1)(0) /= L_X0`, with `L_X0` pinned in `sim/tb_llama_top_real.vhd`.
The two defects OI-3 names are `rtl/llama_top.vhd`'s
`c_exp_region <= to_unsigned(R_VIN, 8)` and `if k >= 2 then qg_buf(k-2) <= el_rdata`,
both live in the config `tb_llama_top_real` exercises, and both move `R_X(0)`.
So the gate ought to kill them.

**But nothing has shown that it does.** MEASURED: no `sim/mutate_llama_top_*.sh`
row and no line of OI3B's own teeth table names either mutation; OI3B's teeth
were taken on defect C1, the `v_ref` collapse and the `gdn_silu` truncation.
**A gate that ought to catch a defect and has never been shown to is exactly the
class this project keeps being bitten by**, so this stays OPEN as backlog row N6
until two mutations have been run. It is cheap: two mutations, one bench.

### OI-5: RESOLVED 2026-08-28 (`c8a57d8`) -- the Python decoder was wrong on 243 ids

Found by TRACK TOK-C while verifying the C port, and deliberately NOT fixed
there. `tools/extract_tokenizer.py`'s `TOKEN_TYPE` table has `5: BYTE,
6: UNUSED`; llama.cpp has it the other way round (`5 = UNUSED`, `6 = BYTE`).
The 243 tokens with `token_type == 5` are ids 248,077..248,319, text
`[PAD248077]`..`[PAD248319]` -- vocabulary padding, not byte-map characters.
llama.cpp decodes them to the **empty string**;
`qwen35_tokenizer.py::piece_bytes` returns their literal text. MEASURED against
the oracle: 243 of 248,320 ids mismatch.

Unreachable from `encode`, so every corpus number in
`docs/debugging/2026-08-28_qwen35-tokenizer.md` stands. Reachable from a
sampler, so a server using the Python would emit text llama.cpp does not.
`server/qwen35_tok.c` is correct. The fix is one line in `piece_bytes` plus the
label swap in `extract_tokenizer.py`, but it needs a re-run of that file's
numbers, so it is an issue rather than a drive-by edit. This also withdraws
that file's claim that "13 byte-mapped characters carry NORMAL type": this
vocabulary has ZERO tokens of type BYTE. Write-up:
`docs/debugging/2026-08-28_qwen35-tokenizer-c.md` section 8.1.

**RESOLVED, `c8a57d8`.** The label swap and the decoder case are both fixed,
but the part worth keeping is the third change. **No corpus of any size could
ever have caught this**, because UNUSED tokens are unreachable from `encode`,
so the only ids the corpus can decode are the ids encoding produced. The
Python's verifier had no way to look anywhere else, which is why the C found it
and the Python did not, despite the Python having been checked over 53,411
strings AND a 1.1M-codepoint sweep. Coverage of the input space is not coverage
of the output space.

So `tools/verify_tokenizer.py` gained `--all-ids`, decoding every id in the
vocabulary one per string against the oracle -- the check the C's verifier had
and the Python's lacked. MEASURED after the fix: 248,320 ids, 0 mismatches,
corpus still 0/0. Teeth-checked by removing the fix again: 243 mismatches,
every one a `[PAD*]` token with `type=5`.

**Generalise this before the next tokenizer-shaped thing:** when a check is
driven by generated inputs, ask what part of the output space those inputs
cannot reach, and enumerate it separately.

### OI-7: `l2norm_rs` rejects a legal input, at `severity failure`

**RESOLVED at HEAD, 2026-08-29.** `rtl/l2norm_rs.vhd:256` now states the bound
INCLUSIVELY (`ssq <= shift_left(...)`), matching `:97`. Fixed by RANGE rather
than by widening `SSQ_BITS`, which would have admitted up to `2^38-1` and
thrown away half the overflow detection. VERIFIED at HEAD.


Found by TRACK B-ACCURACY and deliberately not fixed, because `l2norm_rs` sits
under `gdn_block` and `llama_top` as of `3246046`.

`rtl/l2norm_rs.vhd:97` states the bound INCLUSIVELY: `ssq <= N * 2^30`, i.e.
`2^37` at `N = 128`. `:245` asserts it STRICTLY: `ssq < 2^SSQ_BITS` with
`SSQ_BITS = 30 + LOG2N = 37` (`:128`). The vector `x[i] = -32768` for all `i`
is a legal int16 input whose `ssq` is exactly `128 * 2^30 = 2^37`, so the
maximum legal input trips the assert. MEASURED on untouched RTL:

    rtl/l2norm_rs.vhd:245: (assertion failure):
        l2norm_rs: ssq outside the u37 bound implied by N

`severity failure`, so it kills the run rather than saturating.

**Corroboration the finder did not cite:** `:90` calls this "the u38 bound",
and representing `2^37` inclusively does require 38 bits, while the constant
computes 37. The author's comment disagrees with the author's constant, which
is what an off-by-one looks like from the outside. Fix is `SSQ_BITS = 31 +
LOG2N`, or make the compare `<=`.

**Not determined: whether `ssq = 2^37` is reachable from `gdn_block`'s real
activations.** Spec 2.1.3's requantizer argues against it. That is an argument,
not a measurement, and the distinction is the whole issue: an unreachable
defect is a latent trap, a reachable one is a crash. `msb(ssq) = 37` is also
the single exponent the new 182-case sweep cannot reach, so adding it to the
vector set would turn the regression red, which is not the same thing as
reporting the defect. The generator carries it as a comment naming the
measurement.

### OI-8: `matvec_core` reads `ybuf` one past the end at the top of its row range

**RESOLVED at HEAD, 2026-08-29** (`7ccc239`). `rtl/matvec_core.vhd:928` reads
`ybuf(ybuf_addr(rd_t))` through the clamping function at `:128`, which bounds
the ADDRESS rather than gating the read, so the BRAM read port still infers.
The same buffer's WRITE side was a separate defect, OI-10, fixed at `:865`.
VERIFIED at HEAD.


Found by TRACK A-SHAPE while sweeping legal shapes, and not fixed because
`rtl/matvec_core.vhd` is not that track's file.

`ybuf` is declared `array(0 to TILES-1)` (`:191`), `rd_t` is an
**unconstrained** integer (`:389`) that `S_EMIT` advances to `tiles_r`
(`:883-884`), and `:835` reads `ybuf(rd_t)` **unconditionally every cycle**.
So whenever `ceil(n_rows / ROWS_IF) = TILES` -- that is, whenever `n_rows`
falls in the top `ROWS_IF` rows of the declared `MAXROWS_BFP` range -- the last
emit cycle indexes one past the array. Verified here by inspection of all three
lines.

MEASURED by the finder at `MAXROWS_BFP=192 / ROWS_IF=48`: `n_rows = 145` and
`n_rows = 192` each abort with
`index (4) out of bounds (0 to 3) at rtl/matvec_core.vhd:835`.

**Synthesis-benign, simulation-fatal**, the same shape as OI-7: `rd_v` is `'0'`
that cycle so nothing consumes `ybuf_q`, but GHDL kills the run. **It bites
hardest for exactly the build you would want to ship**: one that sets
`MAXROWS_BFP` to the precise `n_rows` it needs in order to save BRAM, because
then every job trips it.

Consequence for the shape check that found it: A-SHAPE's sweep deliberately
stays below the trap, so **the top corner of the row range is unverified**, and
that is precisely where an off-by-one in `tiles` would show. Closing OI-8
unblocks that verification too.

### OI-10: RESOLVED 2026-08-29 (`0ff6828`) -- `matvec_core` wrote `ybuf` past the end in raw mode

Filed by TRACK RANGE, reproduced and fixed by TRACK OUTMODE. Write-up:
`docs/debugging/2026-08-29_out_mode-raw-oracle-and-oi10.md`.

Reproduced exactly as filed. `ybuf(re2_t)` was written whenever `out_mode /=
"10"`, while `S_IDLE` bounds `n_rows` against `MAXROWS_BFP` only when
`out_mode = "00"` -- and spec 7.6 makes `n_rows > MAXROWS_BFP` **legal** in raw
("in raw mode `M` may exceed `MAXROWS_BFP`", `lm_head` being the caller).
MEASURED at `MAXROWS_BFP = 64 / ROWS_IF = 4`, `out_mode = "01"`, `n_rows = 65`:
`index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:839`, with the SAME
65 rows in partial mode passing in the pass immediately before it.

**Two corrections to the filing, both worth carrying.**

1. **It is NOT reachable "on exactly the argument that produced OI-8".** That
   argument is `n_rows` in the top `ROWS_IF` rows *of* the range, and raw mode
   at exactly `MAXROWS_BFP` passes on unfixed RTL (measured). The write pointer
   stops at `tiles - 1`; only OI-8's read pointer runs one past. OI-10 needs
   `n_rows` **above** the range. Do not look for it at the top corner.
2. **`out_mode = "10"` was NOT unexercised.** `sim/tb_matvec_core` PASS 2 has
   been running partial and comparing `y_data` against the reference's `ACC`
   line all along. `out_mode = "01"` was driven, too, by
   `sim/tb_matvec_cb_lockstep` -- but that bench compares four runs **against
   each other** at one tile and never against `ref/matvec_int4.c`, so raw had
   no oracle. "Never run" was wrong; "never checked against the reference" was
   right, and it is the half that mattered.

Fixed by narrowing the write ENABLE to `out_mode = "00"`, not by clamping the
address as OI-8 did: OI-8 clamped because that access is a READ that must stay
unconditional to infer the BRAM read port, while this is a WRITE whose
condition already IS the write enable. `ybuf` is the BFP output buffer and
nothing else, so the raw write was dead as well as out of range.

`sim/tb_matvec_core` now drives all three modes against the reference and needed
no new vector -- `ref/matvec_int4.c` already writes the `YDATA` line and that IS
the raw payload; the loader was dropping it. 343 output values compared, up from
24. Six mutations; the one that does NOT bite is the alternative address-clamp
fix, which is the bench's permanent resolution floor here because nothing reads
`ybuf` in raw mode at all.

### OI-11: WITHDRAWN for the FK33 arm, RESOLVED 2026-08-29 for the AXU3EG arm

Filed by TRACK RANGE against `sim/tb_matvec_fk33_desc.vhd`; examined by TRACK
OUTMODE.

**The FK33 arm does not have this defect and did not have it when the issue was
written.** Its `k = 0` branch is `if st(2) = '1' ... elsif st(0) /= '1' then
"is LEGAL and never completed (timeout N)"`, so a hang exits the bounded poll
with both bits clear and is scored as a failure. `git log -S"is LEGAL and never
completed"` puts that line in `f693faf`, which predates `7ccc239`, the commit
under which OI-11 was filed. Withdrawn for that arm.

**The gap is real on the AXU3EG arm**, which the filing did not name. That arm
ties off the weight masters, so an accepted descriptor can never complete by
construction and there is no `done` to poll; its verdict was `err` alone after a
fixed window. A design that silently did nothing -- never started, never errored
-- scored as an acceptance.

Closed by requiring the accepted descriptor to be RUNNING: STATUS bit 1 (`busy`)
set and bit 0 (`done`) clear after the window. That is the only completion-class
statement available where completion cannot happen. TEETH, MEASURED: an RTL
mutant that never raises `busy` on the accepted path passes the ENTIRE bench at
HEAD -- both shape sweeps, all 22 cases, `GHDL_EXIT=0` -- and fails 9 of 9 legal
AXU3EG shapes with the check in place. Nothing else in the tree saw it.

### OI-9: DECIDED 2026-08-29 -- the error-code space is full, and it gets subdivided

**Oren's decision, 2026-08-29: SUBDIVIDE VIA `ERR_INFO`.** Not widening the
4-bit field, and not raiding a value reserved for subsystem D. The reason is
that it leaves the descriptor's byte layout UNCHANGED, and that layout is the
one artefact A, D and the host builder all read and the one already verified.
Accepted cost: `ERR_INFO` stops being free for anything else, and the host
decoder gains a second lookup. Implementation is backlog row N12, and it must
carry DESC-MUT's measurement that **`EC_DESC` (0x3) is raised at NINE sites with
two confirmed collisions even with `ERR_INFO` pinned** -- subdividing `EC_DESC`
is the first thing this route buys. The statement of the problem follows and is
unchanged.

`EC_SHAPE = 0xF` (`rtl/matvec_int4_desc_pkg.vhd:52-57`) took the last free
value. `0x0, 0x3, 0x4, 0x9..0xE` were already taken and `0x1, 0x2, 0x5..0x8`
stay reserved for subsystem D, whose header this format shares verbatim. The
field is 4 bits and it is now full.

Not urgent, and deliberately not pre-solved: the next error condition anyone
wants to report has nowhere to go, and the options (widen the field, subdivide
a code using `ERR_INFO`, or take a reserved D value) all have consequences for
D. Whoever needs the next code decides. Recorded now so that decision is not
discovered at the worst moment. **Superseded by the decision above.**

### OI-6: llama.cpp aborts on some malformed UTF-8 (upstream, informational)

`unicode_cpt_from_utf8` masks a 4-byte UTF-8 lead with `0x07` and applies no
upper bound, so the bytes `F4 BF BF BF` decode to U+13FFFF;
`unicode_cpt_to_utf8` then throws `std::invalid_argument` and nothing between
there and `llama_tokenize` catches it. The process dies with SIGABRT.
Reproduced against `llama.cpp.upstream@1692f9e5`. Only reachable from a host
that feeds raw bytes; a JSON parser rejects them first. Recorded so nobody
re-derives it while fuzzing, and because it is why the byte fuzz excludes lead
bytes `0xF0..0xFF` -- there is no oracle answer to compare against.

### OI-12: RESOLVED 2026-08-29 (`ed1ffe2`) -- the FK33 shell build did not route

**CLOSED by TRACK BOARDAUDIT 2026-08-29, against the tree rather than against a
document.** The cause was never area, timing or the placer: it was
`hw/fk33/fk33_pcieep.xdc:133-140`, an **inherited SQRL constraint** assigning
the whole block design to a pblock holding 67% of the assigned LUTs and 33% of
the assigned DSPs. It is `IS_SOFT`, so the placer crammed and spilled rather
than failing, and SHELL's own `runme.log` said so in nine `Place 30-640` lines
nobody read. Deleting it plus a small pblock at `CLOCKREGION_X0Y0:X6Y3` routes.

VERIFIED in the tree, not in a report: `hw/fk33/results/pblock_2026-08-29/ASX_route_status.rpt`
says **0 nets with routing errors, 288,506 fully routed**, and
`hw/fk33/bit/fk33_pcieep_eng.bit` is 22,568,402 bytes. `ed1ffe2` is an ancestor
of HEAD. The bitstream has since been loaded on card 1 and configures, links
Gen3 x4 and identifies (`docs/debugging/2026-08-29_first-engine-load-on-card.md`).

**This entry sat unmodified for a day saying "There is no routed checkpoint and
no bitstream" while both existed**, and the BACKLOG row for the same work said
the opposite. Two places recording one fact is how that happens. The
description below is kept for the record and is no longer the state of the tree.

**PROVENANCE CORRECTED 2026-08-30 by TRACK BITPREP** (`e0e4fec`,
`docs/debugging/2026-08-30_bitprep-rebuild-readiness.md`). `ed1ffe2` is the
right commit for the **constraints and the routing** and the wrong one for the
**netlist**. MEASURED from the artefact's own header: `write_bitstream` stamped
`fk33_pcieep_eng.bit` at **2026/08/29 14:38:06**, and `ed1ffe2` landed at
**14:42:42, four minutes later**. The netlist was synthesised around 06:56 that
morning from `rtl/` at **`54b3c1a`**, with `hw/fk33/` in the state committed as
`928ad9f`. No git SHA is stamped in the bitstream (`UserID=0XFFFFFFFF`), so
this is reconstructed from build logs, not read off the artefact. Several
write-ups say `ed1ffe2`; they are **not** being edited, because most of them
are talking about the routing, where it is correct. When the question is *what
RTL is on the card*, the answer is `54b3c1a`.

**What a rebuild is actually worth, MEASURED by BITPREP.** The pcieep build
consumes **fifteen** RTL files and B, C and D are not among them. `54b3c1a..HEAD`
has 28 `rtl/` commits and **only 8 touch this design**, of which one is
assert-only and one is inert at this geometry. The real content of a rebuild is
**four commits: `0ff6828`, `75f95a8` (A7's `outst` clamp), `3ecc729` (DONE1's
`done_l` race), `a4a564c` (THERMFIX's thermal guard)** -- not twenty-eight. All
four confirmed absent from the loaded bit.

**`hw/fk33/bit/` is gitignored (`.gitignore:134`), so the tree held the ONLY
copy of what is on the card.** Archived 2026-08-30 to
`/mnt/storage/fk33-bitstream-archive/`, all six `.bit` files, with the loaded
one named `fk33_pcieep_eng.2026-08-29T1438.rtl-54b3c1a.bit`. Its sha256 is
`6b12b3c46ee26396bcbc1f75cf240fe6231528a7a10c95ac91596b52bce164c6` and it was
verified equal to the working copy after the archive. **This is the rollback
artefact.** Note `hw/fk33/pcieep.sh` prefers `bit/fk33_pcieep.bit`, which is the
Aug-27 **pre-engine** build -- without `EP_BIT` set explicitly it will configure
a card with no engine and report success.


### OI-12, superseded text

**MEASURED 2026-08-29, `928ad9f`.** The first build carrying subsystem A on the
card's HBM ports places, but `route_design` terminates:

    ERROR: [Route 35-3] Design is not routable as its global congestion
                        level is 7.

7 is the top of the scale. Six attempts at initial net routing over 7 min 48 s,
then abandoned. **There is no routed checkpoint and no bitstream.**

**It is not area.** Whole design 39.50% LUT, 14.22% FF, 38.91% BRAM36, 55.03%
DSP, 0 URAM. The engine's own area in the shell is within 1.8% of the
out-of-context figure on every line (LUT 132,113 vs 134,534; FF 63,797 vs
64,067; DSP and BRAM36 identical), so the OOC numbers were honest and the
shell costs 41,581 LUT and 69 BRAM36 on top.

**It is probably not timing either, though that is not settled.** Design-wide
WNS went -0.763 after place, -0.368 after phys_opt, -0.260 at the router's last
update before it quit, against 250 MHz on the HBM AXI side and 200 MHz on the
core.

**What is NOT known is what is congested.** `report_design_analysis
-congestion` did not complete in the time available, so the 128x128
long-congestion regions south and east are the only localisation there is. The
untried experiments, in order of cheapness: a pblock putting the engine in the
clock regions nearest the HBM BLI interfaces (its core clock currently spans
all 8x4 regions); a lower clock, which separates congestion from the
timing-driven replication that added 185 of the design's 3,887 control sets;
and a different placer directive.

Write-up, including five things measured and rejected:
`docs/debugging/2026-08-29_fk33-shell-integration-does-not-route.md`.

### OI-13: the aux domain's CDC check does not scale to subsystem A

The impl-stage verification that made the aux domain trustworthy -- enumerate
every path crossing the clock boundary and demand that none is ANALYSED, since
an asynchronous group excludes a path without stopping it being enumerated --
**does not terminate** on a design containing subsystem A. MEASURED: over 20
minutes on `get_timing_paths -from <core> -to <axi> -max_paths 8`, killed.
`report_timing_summary` on the same checkpoint likewise. 28 gray-pointer FIFOs
plus 28 four-phase clear handshakes is an enormous enumeration where the aux
domain is a handful of single-bit crossings.

`gen_pcieep.py` now checks only that both clock lookups RESOLVE, which is what
decides whether the XDC `set_clock_groups` matched anything (an empty group is
a warning, not an error), and writes `report_clock_interaction` to a file for a
human. It is labelled in the script as the weaker check it is. **Consequence:
nothing currently proves the per-port CDC is being treated as asynchronous
rather than timed, and no per-clock WNS figure exists for this design.** If the
group did NOT apply, every WNS above is pessimistic rather than optimistic.

### OI-4: RESOLVED 2026-08-29 (`a2b20f3`) -- the descriptor-program generator exists

**CLOSED by TRACK BOARDAUDIT 2026-08-29.** `tools/gen_layer_program.py` is
1,155 lines, names backlog row 6 in its own header, and emits real bytes:
`d_table.hex` and a per-job `a<NN>_<tensor>.hex` for each of the 311 A jobs,
behind a full CLI. `tools/dprog_oracle.py` (956 lines) checks the EMITTED BYTES
against artefacts from other sources. Both VERIFIED present at HEAD.

Note the WORKLOG's own D-PROG section already said "**OI-4 is STALE at HEAD and
should be closed**" and the entry was left open anyway. A correction written in
one section does not close an issue recorded in another.

**Trap that survives the closure: `gen_layer_program.py` defaults to the
PRE-QKV-PAD packed set, where 48 of 311 A jobs are refused. Always pass
`--manifest`.**

Superseded text: Subsystem D's control core is integrated and mutation-tested,
but nothing emits the descriptor program it executes. This is **host software**
and it is on the critical path for both the card and the server. **UNBLOCKED
2026-08-28:** the descriptor format is settled and byte-pinned in
`docs/2026-08-28_matvec-descriptor-format.md`, whose section 7 carries a
reference builder in C for the A job. Still nothing emits it.

---

## Landed

| track | result | commit |
|---|---|---|
| **RY-ORACLE: subsystem C's output gets a value oracle, and it found a defect** | `R_Y` had NO integration-level model, which is why R7 was unkillable. Now modelled from the machine's own captured `R_QG`/`R_KIN`/`R_VIN`; coverage 58 -> 59 of 63. **R7 killed on the numbers.** B's three `R_Y` seams stay open for a STRUCTURAL reason (input includes recurrent state no region holds), not for want of effort. **Unplanned finding, defect C1:** `attn_block`'s `v_ref` fold has no layer dimension while its own comment says it must; live at the real shape's 8 attention layers; no bench could see it because `tb_attn_block` hardwires `layer => 0`. **Also WITHDREW the `R_ER` alarm as a stimulus artefact:** synthetic weights grow the residual 1.06e6x over four blocks against 1.10x real, and at the real shape there are ZERO annihilation cases. Warned that fixing C1 SILENTLY UN-KILLS R7. | `686fd97`, `08df58b`, `d6819e8`, `b32ecb5`, `0e867a0`, `eeb1200` |
| **BISECT: the first value oracle to reach integration level** | Built the capture path, then CORRECTED its own brief: the 9B reference cannot bisect a GHDL run (35,650x the arithmetic, ~15 days/token, and `v_n` at 13 bits cannot express `ffn = 12288`). Built a stepwise oracle instead: **58 of 63 seams clean in all three configurations**, N2 killed on the numbers at `R_XN-0` element 63. **Retracted its own gate verdict**: it read the FIRST of two report blocks in a log whose scratch tree had been deleted mid-run. Lesson: a grep returns every candidate verdict, only the LAST is the verdict. | `ecfd178`, `f6fda25`, `85f4e71` |
| **A-MUT: subsystem A's first mutation coverage, and the adversarial trace is the WEAKEST** | 57 mutations x 3 traces, ABORT as a third verdict. Committed gate 36 kills, ragged 40, **adversarial only 30** -- ten mutations the plain trace kills survive it, because identical products make rounding invisible (all at the rail) and adder-tree changes invisible by symmetry (`2*p == p+p`). **Saturation coverage and value diversity are OPPOSED.** Eight mutations are invisible to the committed gate (`tr.txt` has K=96 and M=8 exact, SATEV 0), including removal of the `sat32` clamp. Two stimulus gaps closed: `xmem` poisoned not zeroed, and an `err`-goes-HIGH assert (the guard on a `ybuf` overrun was itself unguarded). No RTL defect found. | `a3dc2f4` |
| **EMBDROP: 562 MiB per card, 2.195 GiB per cluster** | Repacked without `token_embd.weight` after Oren's decision. Recovered 589,287,424 B = tensor plus 17,080,320 B of stack-boundary hole no longer skipped; 6.86% of HBM, **29.5% of the N=4 spare**; `max_context_tokens` 52,319 -> 61,311. Made it a REVERSIBLE named flag, not a deletion. Checked the one thing that could falsify the premise: **`output.weight` is NOT tied** (different GGUF offsets, different bytes). Found `pl_open_opts`'s default bases point INSIDE the weight image in BOTH sets. Caught a stale line number in the dispatcher's own brief, off by 39. | `46216b3` |
| **TOKIO: the embedding was already decided, and the lm_head table was refused by its own gateware** | `seq_tbl_pkg` encoded a single 248,320-row lm_head job the descriptor plane REFUSES; now 15 windows at stride 17,376 (not 17,408: `17408 mod 48 = 32`). It now matches `gen_layer_program.py`'s DEFAULT output byte for byte, where before it matched only under `--one-lmhead-job`. **The embedding decision was NOT open** -- the host-writes-`R_X` path was already built (`seq_opdec`'s `tok_fsm` exists solely to publish it). New bench asks what four table-walking benches structurally cannot: they all take `TBL_STEPS` from the package. Scored one mutant killed by the LANGUAGE separately rather than claiming 11 of 11, and found a decoration check of its own. | `80d3a61` |
| **SPECREC: the six absent C units were six absent NAMES** | All thirteen spec-named responsibilities ARE implemented; the backlog verdict was an absent name read as an absent responsibility. `attn_score_q12.vhd` is real, is half of `attn_score_tree`, and is on NO spec list -- the mirror defect. Fourteen false claims corrected in place across five files, prioritised by blast radius. **27 read masters is 28**, so free HBM ports for B and C drop from 3 to 2. Nine analyses that never became work, four of them missing CHECKS -- and a missing check generates no artefact, so nothing reminds anyone. | `5b41635`, `f65e2bc`, part of `686fd97` |
| **CD-SEED: 60 gates in C and D, ZERO false-reds** | B's defect class is structurally impossible on C/D's bench side: all 25 benches are bit-exact, and C's bounds are DERIVED per case rather than fitted to a seed, so they move with the stimulus. B-SEED's 'widen it' rule does NOT transfer -- `attn_gate`'s oracle 1 attains its gate exactly at 20 of 40 seeds and widening would delete it. **One real defect fixed:** two committed vector files had no `tb_vector_args` row, so neither generator was ever built or run and five checks were unreachable. **Found that `mutate_attn_*.sh` score a DIED run as a KILL**, making C's published ratios unsafe. | `e27a9ad`, `9b02e8e` |
| **B-SEED: nine of thirty-five B thresholds fire on the HONEST unit** | Three at 98%, 82% and 58% of seeds. **The recursion is the finding:** B-RECUR's retune from that morning was ITSELF false-red -- its 52-seed sweep said honest max 15.429, thirty different seeds found 32.122, and two sweeps disagreeing 2.08x on a maximum means no feasible seed count bounds the tail. So COUNTS carry these benches, not maxima. Two thresholds had ZERO resolution left (a 2.5% window and a window of zero), recorded as never load-bearing again. Retunes took false-reds to 0 with all four kill ratios unchanged. Found a `SEED` knob that was inert: declared, printed, never passed. | `81297ee`, `0503be8`, `4a17dcc` |
| **TANDEM: available, and unevaluable until the design routes** | Confirmed by the TOOL, not the documentation: `create_ip xdma:4.1` accepts all four modes on this part. But the stage-1 pblock is a DRC-Error exclusion zone at `SLICE_X216Y0:SLICE_X232Y239`, **50,135 placed cells sit inside it**, and there is nothing to the right, so they all move LEFT into the congested half. Two things nobody had noticed: `DFX_over_PCIe` emits MCAP with NO stage-1 pblock, and **every non-GT pin is in bank 65, the config bank**, so observability must become static logic under any Tandem variant. Corrected the one-day ICAP estimate: right for the plumbing, wrong for the capability. | `abbd2ed` |
| **SHELL: the composed design does NOT route** | First FK33 build containing real arithmetic (subsystem A's descriptor plane as `fk33_engine`, 28 AXI masters). Places, then `[Route 35-3] Design is not routable as its global congestion level is 7` after six attempts over 7:47. **No bitstream exists.** NOT a timing miss (WNS -0.260) and NOT an area blowout (39.50% LUT, 55.03% DSP, 38.91% BRAM36). The engine SHRANK in the shell vs OOC (134,534 -> 132,113 LUT), so the OOC figures were honest. Corrected its brief three times: 192.5 vs 145.5 BRAM36 are different builds, masters are 28 not 27, and backlog 2's `llama_top` is a sim top with stories260K ROMs and no HBM interface. Found a combinational halt mask that did not block a GO, caught by a scratch bench with a firing negative control rather than by inspection. Peak RSS 22.81 GB. Filed OI-12 and OI-13. | `928ad9f`, `70c35db`, `d807a1c` |
| **LMHEAD: the whole token's A program is expressible** | `311 of 311 A jobs emitted, 0 refused` (was 296 of 297). 15 raw row windows at stride 17,376. **Route 2 refuted with the RTL as judge:** `matvec_int4_desc_axi`'s `S_CHECK` bounds `n_rows` in EVERY `out_mode`, so a 248,320-row descriptor is refused `err_code 0x3` in raw and BFP alike -- answering OUTMODE's open question NO. Raw over BFP is load-bearing: in BFP 832 of 1024 mantissas move and every value is exactly 2x, feeding a sampler whose only input is a bare 32-bit integer. 248,320 of 248,320 logits bit-identical, 9 of 10 mutations killed, m10 named a permanent structural non-biter. The 'destination region nobody has decided' does NOT exist: `dst = R_NONE` + `FLG_TO_SMP` was always there. Found a defect in `seq_tbl_pkg`, which encodes the job the gateware refuses. | `a781326` |
| **B-GATE: the flagship mutation now fails the gate** | `gdn_silu` and `rmsnorm_bf` had oracles that were PRINTED, not gated. Route B (in-bench real-valued oracle) chosen and Route A killed with one line: an RTL-only mutation leaves the generator reading the UNMUTATED 0.7704 LSB while the bench reads 1.68e10. Flagship closed WITH a control (same tree, only the bench swapped: FAIL new, PASS old). Gates max/count/mean/floor. **Warning for all of subsystem B: the committed `rmsnorm_bf` seed is the benign extreme of a 13x range** (honest worst 0.770 -> 9.999 LSB over nine seeds), so the pre-existing `ACC_LSB=1.0` fires on the HONEST unit at eight of nine seeds. Any B threshold calibrated on one seed is suspect. Also: a max-only gate could not have been made honest for either unit, and a mutation that destroys a unit reads BETTER than the correct one on every figure but the floor. 33 of 43 mutations killed, all 11 BOTH-class killed, 10 survivors named. | `728fcfe` |
| **QKV-PAD: 49 refused A jobs became 1** | Each fused row segment padded with ZERO rows to a whole `ROWS_IF` tile: starts 0/2064/4128, M = 8224 vs M_logical 8192, uniform across all 24 tensors and derived from GGUF metadata rather than the brief. Zero is the fill BECAUSE it is the only one also invisible under a WRONG scan domain (measured: a full-scale pad shifts ns 5 -> 8). 33,554,432 nibbles and 1,048,576 scales identical; 5 of 5 equivalence mutants bite. Found a silent pass in the tooling: a tile-aligned but WRONG `row_start` makes a descriptor the RTL accepts whose bases read past the tensor, and the gateware can never see it because `row_start` is not a descriptor field. | `e28083f` |
| **OUTMODE: raw mode had no oracle and wrote past the end of ybuf** | `out_mode=01` was already DRIVEN, by `tb_matvec_cb_lockstep` -- but that bench compares four runs against EACH OTHER and never against the reference. A round trip, not an oracle. With a real oracle attached, raw needed no new vector (`ref/matvec_int4.c` already emits `YDATA`; the loader dropped the line). Coverage 184/24 -> 464/343 values, masked rows now scored against zero rather than skipped. OI-10 fixed by narrowing the write ENABLE, not clamping the address as OI-8 did, with the reason in the code. **M6, the alternative fix form, DOES NOT BITE and is reported as a permanent floor:** nothing reads `ybuf` in raw mode, so no bench can separate the two forms. OI-11 WITHDRAWN for the arm it named (`f693faf` predates the filing, verified by ancestry) and closed on the AXU3EG arm it missed, where a `busy <= '0'` mutant passed all 22 cases. | `0ff6828`, `b65d9ad` |
| **B-FIX: three verification defects, and a corrected diagnosis** | Fixed D1 (golden two days behind its generator), D2 (the chain gate ran at the one `Z_DELAY` that hides the defect; bisection put the threshold at (520,540], corrected from '~512', and 640 is DERIVED from 616 cycles per head), and D3. **Corrected B-MUT's diagnosis on D3:** the sentinel-cancellation story explains only 14 of 17 cases past 100 LSB and the joint-worst case has NO saturation. The unifying statement is that the error is |a| times the softplus error, so the gate became a DOMAIN PREDICATE on inputs rather than a threshold. BOTH-class score 0 of 5 -> 4 of 5. Trap recorded: ghdl-mcode cannot override a `real` generic. | `ebcca86`, `6332abe`, `6e20668` |
| **TRACK TOP-KV: the KV seam at the INTEGRATION level** | `llama_top` instantiates `attn_kv_axi`, connects `attn_block`'s four seam handshakes, and advances a sequence position on `tok_done`/`tok_ack` instead of hardwiring 0. Four tokens of one sequence, TWO attention layers, three KV read latencies (100/7/403), R_X bit-identical per token, 0 KV faults. 26 mutation rows, 13 killed, 9 survivors all analysed. **Also closes backlog 14:** the gate had NO row with the real path on, and now has two. The 32-block real-weight landmark is byte-identical (`R_X(0) = -14110 hash 52347`, all 65 `log2 rms` samples). Regression 81 -> 83. `docs/debugging/2026-08-29_llama-top-kv-seam-multitoken.md` | see git log |
| Thermal guard synthetic trip | Guard halts, latches, freezes compute, releases. Teeth-checked. | `0b8831c` |
| Subsystem A at FK33 geometry | Bit-exact from real `.mv4i` bytes, 27 masters. Regression 76 -> 77. | `055b6ed` |
| AXI3 burst cap | HBM is AXI3, 16 beats not 128. Bit-exact at both; bench now runs the legal one. | `809ada7` |
| HBM port feasibility | 27 masters fit; 30 already measured at 288.0 GB/s, 100% of ceiling. Design note only. | doc only |
| Qwen3.5 tokenizer | Bit-exact vs llama.cpp, 53,411 strings x 2 + 1.1M codepoints. 7 of 9 mutations bite. | `4123bd8` |
| Qwen3.5 tokenizer in C | Bit-exact vs llama.cpp: 53,409 strings x 2, ALL 248,320 token ids, 1.1M codepoints, 20,051 malformed-byte strings. 7 of 7 mutations bite. +42,704 bytes linked, no new dependency. Found OI-5 and OI-6. | `0181cc3` |
| Full gate re-measured | 77 PASS / 0 FAIL, matches the recorded floor. Verified independently after `3246046`. | n/a |
| **C-ORACLE: `attn_block` did NOT compute attention** | First block-level oracle for subsystem C. 64 of 64 mantissas wrong on first comparison; bisected to TWO independent defects in `rtl/attn_block.vhd` (cached V exponents overwritten by the current token's, because `hdr_valid` is a level not a pulse; and every accumulator rescaled twice per rise, because `rs_have` re-latched from a still-standing `rs_valid`). Both fixed, oracle never adjusted. 17 wiring mutations, 17 killed. Regression 77, unchanged: a property was added to an existing test, not a test. VERIFIED SEPARATELY: `tb_attn_block` PASS and `tb_llama_top` PASS after the RTL fix. Note what that second one is and is not evidence for -- it shows the fix broke nothing, NOT that the fix is right, since `llama_top` runs one token at `cur_pos = 0` and never reaches either defect. The evidence the fix is right is the bit-exact oracle. | `8baa413` |
| A-sim MAXB correction | The original A agent woke, independently confirmed the AXI3 defect in its own bench, and appended a dated CORRECTION rather than editing the wrong claim out. Confirmation run completed separately: matvec_fk33, weight_streamer, axi_rd_port all PASS. | `2b12a7b` |
| **A-CTRL: the descriptor control plane, the CDC, and MAXOUT** (OI-1) | Descriptor format is D's, byte for byte, plus a four-word A extension AFTER the base array where D never reads. `matvec_int4_desc_axi` fetches and checks it before starting anything; `matvec_int4_axi` retained unchanged for the AXU3EG. Per-port async FIFO closes the HBM-to-core CDC; MAXOUT 2 -> 16. MEASURED: 100 of 100 elements bit-exact against `ref/matvec_int4.c` on the core bus AND 100 of 100 rows bit-exact through the AXI-Lite map, at `MAXB=16`, at four AXI/core clock ratios including a non-integer one. 22-case mutation table: 19 refused with the right code, 2 named as undetectable (see OI-1), 1 is the clean case. Found and fixed two of its own defects: a delta-skewed clock signal (broke `tb_matvec_int4_ip`) and a descriptor fetch left in the wrong clock domain (broke 17 of 22 cases under `DUAL_CLK`). Full gate 78 PASS / 0 FAIL, matches the raised floor. | `a4f7e17` |
| Magnitude blocker | Explosion was the STIMULUS (synthetic row norm 2^4.87 vs real 2^-0.03). PART 5 withdrawn, PART 3 reinstated. `attn_block` wired behind `C_REAL`. | `3246046` |
| **B-FIX: the three defects B-MUT measured in the CHECKING** | D1 `sim/gdn_conv_vec.txt` regenerated: 19 of 641 lines move, all case headers, all at `c % 7 == 0`, only the `cw_exp`/`e_seg`/`err` fields; no `x`/`w`/`sm`/oracle line moves and the worst-vs-oracle figure is unchanged at `4.99999999998181e-1`. Mutation R13 went pass -> FAIL against the committed golden. D2 `sim/regress.sh` now passes `-gZ_DELAY=640` to `tb_gdn_emit_chain`; MEASURED, the `z_have` mutation passes at 0/7/40/520 and fails at 540 and above, control PASSes at 640, so the kill threshold is (520, 540] and not the "~512" previously estimated. Cost 52 s -> 61 s. D3 the answer is NOT the expected one: the sentinel-cancellation diagnosis is INCOMPLETE -- the joint-worst case (70) has ZERO sentinel saturation and is 32767.9963 LSB wrong through the softplus negative-tail flush times an abs(a) of 3.09e14. `sim/tb_gdn_scalar.vhd` now GATES accuracy on a domain defined by a predicate on the INPUTS: 259 of 320 cases, worst 15.3271 LSB(Q15), gate 23.0, plus a count-past-1-LSB gate at 100 (67 measured) that catches B5 which the max cannot see, plus a beta gate and an in-domain-count FLOOR so the domain cannot empty. Teeth: 4 of 5 BOTH mutations now fail the BENCH; B4 deliberately still survives. `gdn_scalar` becomes the second of B's seven units with an accuracy gate `regress.sh` can fail. Full gate 81 PASS / 0 FAIL, matches the recorded floor; no test added or removed. Writeup: `docs/debugging/2026-08-29_b-verification-defects-d1-d3.md`. | `ebcca86`, `6332abe` + this |

---

## BACKLOG, ordered, ready-to-dispatch

**AUDITED END TO END 2026-08-29 by TRACK BOARDAUDIT against `git rev-parse HEAD`
= `5a19f984`.** Every row below was judged by reading the tree and `git log`,
never by reading another document. Nine of the fourteen rows were already done;
four had never been struck by anyone and two of those cost a dispatch. The
genuinely open work is in the NEW rows at the bottom, and it is not what the
old table said it was.

**STRIKE A ROW IN THE SAME ACTION THAT LANDS IT.** This table had no such rule
and the In flight table did, which is exactly the difference in their accuracy.

### Closed rows, with what closes each

| # | task | closed by |
|---|---|---|
| ~~1~~ | `attn_block` <-> `attn_kv_axi` seam | `e7e7ae5`, with `sim/tb_attn_kv_seam.vhd`, `ref/attn_block_seq_vec.c`, `sim/mutate_attn_kv_seam.sh`. **Unstruck for a day; TRACK C-SEAM was dispatched onto it.** The dispatch was not wasted: it found OI-3b. |
| ~~2~~ | FK33 shell integration, then the congestion | Integration `928ad9f` / `70c35db`. Congestion RESOLVED by TRACK PBLOCK `ed1ffe2`: an **inherited SQRL constraint** at `hw/fk33/fk33_pcieep.xdc:133-140` assigned the whole block design to a pblock holding 67% of the assigned LUTs; it is `IS_SOFT`, so the placer crammed rather than failing, and `runme.log` said so in nine `Place 30-640` lines nobody read. Artefacts VERIFIED present: `hw/fk33/results/pblock_2026-08-29/ASX_route_status.rpt` (0 nets with routing errors, 288,506 fully routed) and `hw/fk33/bit/fk33_pcieep_eng.bit`, 22,568,402 bytes. **The bitstream has since been LOADED** (`docs/debugging/2026-08-29_first-engine-load-on-card.md`): configures, links Gen3 x4, identifies, BAR and DMA and HBM all round-trip. **What it COMPUTES is still unverified, and that is now row N1.** |
| ~~3~~ | `llama_top` instantiates `attn_kv_axi` and carries a sequence position | TRACK TOP-KV, see Landed |
| ~~4~~ | Token I/O: embedding and LM head | TRACK TOKIO `80d3a61` + TRACK EMBDROP `46216b3` |
| ~~5~~ | `pl_backend` v2 and the server seam | **LANDED, TRACK SERVER, `3963a60`, `docs/debugging/2026-08-29_host-seam-v2.md`.** `server/pl_backend.{c,h}` is a full v2: `pl_prefill`/`pl_decode`, `fk33_transport` with chardev, filedir and sim backends, `fk33_manifest.c`. **This row was never struck. It is the SEVENTH such instance.** But read row N2 before believing the work is usable: `server/pl_backend.c`'s own first three lines say **"Nothing here has ever run against the card"**, and the register contract it drives is implemented by no RTL in this repository. |
| ~~6~~ | Subsystem D: the layer-level descriptor program | `tools/gen_layer_program.py`, 1,155 lines, `a2b20f3`, naming this row in its own header. Oracle `tools/dprog_oracle.py`, 956 lines. |
| ~~8~~ | `gdn_recur` / `gdn_exp_capture` mutation coverage + the `d_m` grid defect | **LANDED, TRACK B-RECUR, `ea26eec`, `docs/debugging/2026-08-29_gdn-recur-coverage-and-dm.md`**, whose title is the answer: *the 8.955 LSB is not the d_m grid defect, and the gate that held it fires on the honest unit*. `sim/mutate_gdn_recur.sh` and `sim/mutate_gdn_exp_capture.sh` both exist. **Never struck. EIGHTH instance.** |
| ~~9~~ | Subsystem C spec reconciliation | **LANDED, TRACK SPECREC, `5b41635` / `f65e2bc`, `docs/debugging/2026-08-29_spec-reconciliation.md`.** The row's own premise was refuted: all thirteen spec-named responsibilities ARE implemented; six absent NAMES were read as six absent units. **Never struck, and the board contradicted itself, because the Landed table has carried a SPECREC row the whole time. NINTH instance.** |
| ~~11~~ | The five B units with no accuracy gate `regress.sh` can fail | **LANDED.** `728fcfe` (`gdn_silu`, `rmsnorm_bf`), `81297ee`, `2868f6b` (the three emit units), then TRACK BGATE2 `f3cb87a` / `2c89814` / `589513c` / `1216a5e` / `dfe308c` pinned the goldens to the gate rather than to whatever lies in `sim/`. **`2868f6b` closed this TWELVE HOURS BEFORE BGATE2 was dispatched onto it**, which is the most expensive instance of the day and is written up in `2c89814`. Full unfiltered gate at `1216a5e`: `OVERALL PASS 99 FAIL 0`. |
| ~~12~~ | A whole-model 9B numeric reference | `91ba5ef`, `885420c`, `ecfd178`, `f6fda25`, `686fd97`, `0e867a0`; `docs/debugging/2026-08-29_9b-whole-model-reference.md`. The `llama_top` capture that was its remaining gap landed as TRACK CAPTURE, `docs/debugging/2026-08-29_capture-llama-top-r9bs.md`. |
| ~~13~~ | A composed synthesis at the real shape | **LANDED as two tracks, and the answer was NEGATIVE.** TRACK COMPOSE `01a9e95` measured B+C+D out of context at the real 9B shape: **DSP 591, and the model was right to 1.5%, so the DSP risk is retired**; LUT 771,900 against 268,222 free is **2.88x over**. TRACK REALFIX `3e93bed` retired the row's other half by making the real 9B shape elaborate in GHDL, so the first full-shape elaboration no longer happens inside Vivado on the critical path. **Residual is row N5**, a re-measurement after WRITEDEC. |
| ~~14~~ | Two real-path rows for the gate | TRACK TOP-KV: `sim/tb_llama_top_real.vhd` and `sim/tb_llama_top_seq.vhd` |

### Still open, ordered

| # | task | depends on | owns |
|---|---|---|---|
| **N1** | **NOTHING HAS VERIFIED WHAT THE CARD COMPUTES, AND NO TOOL IN THIS REPOSITORY CAN.** This is the standing question and it now has a row. MEASURED: `hw/fk33/gen_pcieep.py` puts the engine's own register map at **`ENG_CTL_BASE = 0x00012000`** and its activation writer at `ENG_XW_BASE = 0x00013000`; `grep -rn '0x12000\|0x00012000\|ENG_CTL' hw/fk33/host/ server/ tools/` returns **nothing**. `hw/fk33/host/fk33_regs.h` has no engine block at all, and `fk33ctl.py`'s commands are `sysmon thermal id scratch gpio vccint selftest bench load verify` -- none of which starts a job. So: write the host-side runner that builds one `matvec_int4_desc_axi` descriptor, points it at a real `.mv4i` weight already resident in HBM, starts it at `0x12000`, and compares the result against `ref/matvec_int4.c`. **The agent-safe half is all of it except the last step:** `server/fk33_transport.h` already offers `fk33_transport_open_sim` and `fk33_transport_open_filedir`, so the runner can be written and fully exercised with NO hardware. **The real run is Oren's, at the bench.** This is the first arithmetic on this silicon and every schedule below it is unfalsifiable until it happens. **Read open issue THERM-255 before trusting any result from it:** the thermal guard has been measured tripping roughly once every three minutes for reasons that are not heat, and each trip halts the compute domain, so a stall or a wrong answer with a non-zero trip count is not evidence about subsystem A. | none | `hw/fk33/host/` (new file), `hw/fk33/host/fk33_regs.h` |
| **N2** | **THE HOST SEAM CONTRACT HAS NO GATEWARE, AND NOBODY HAS SAID WHICH SIDE MOVES.** MEASURED: `server/fk33_seam.h` defines a register block with magic `0x4C4C4D32` ("LLM2") at `FK33_SEAM_BASE_PROPOSED = 0x0000E000`, and its own comment says **"BASE IS PROPOSED, NOT DECIDED"**. `grep -rln 'LLM2\|4C4C4D32\|SEAM_ID' rtl/ hw/fk33/rtl/ hw/fk33/gen_pcieep.py` returns **zero files**; `0xE000` is assigned nowhere in `gen_pcieep.py`. So the whole of row 5's work drives a contract no bitstream implements, which is why `pl_backend.c` line 2 says it has never run. **This is a DECISION, not a fix, and it is Oren's:** either (a) build an `fk33_seam` AXI-Lite block in front of subsystem D, which presumes D is on the card and it is not, or (b) retarget `pl_backend` at the descriptor plane that IS on the card, which makes the host own the step loop, or (c) leave the seam as the target contract and accept that row 5 is dead code until N3 lands. Do not let a track pick one. | N1 for evidence | decision |

### N2 RESOLVED 2026-08-30 by Oren: option (a). Build the seam in front of D.

Oren, verbatim: **"we don't want host controlling, let's get D working"**.

That selects **(a) build an `fk33_seam` AXI-Lite block in front of subsystem D**
and rejects (b) explicitly. (b) was "retarget `pl_backend` at the descriptor
plane that IS on the card, which makes the host own the step loop" -- and the
host owning the step loop is the thing being ruled out.

**The row's own objection to (a) stands and is now a work item rather than a
reason not to choose it:** (a) "presumes D is on the card and it is not". So (a)
depends on N3, the composed A+B+C+D place-and-route. That is the ordering, not
a blocker.

What this makes true:

- `server/fk33_seam.h`'s magic `0x4C4C4D32` ("LLM2") and
  `FK33_SEAM_BASE_PROPOSED = 0x0000E000` stop being proposed. The base still has
  to be **assigned in `gen_pcieep.py`**, where `0xE000` is currently assigned
  nowhere, and the register block still has to be **implemented in RTL**, where
  `grep -rln 'LLM2\|4C4C4D32\|SEAM_ID' rtl/ hw/fk33/rtl/ hw/fk33/gen_pcieep.py`
  returns zero files.
- Row 5's work stops being dead code, and `server/pl_backend.c` line 2 -- "Nothing
  here has ever run against the card" -- becomes a thing to fix rather than a
  thing to accept.
- The host-side step loop in `hw/fk33/host/fk33_run_token.py` becomes a
  **reference implementation and an oracle**, not the shipping path. It stays
  valuable exactly because it is bit-exact against `ref/run9b`: it is what the
  seam's output gets compared to.

**What it does NOT change, MEASURED, and this is the part that matters for
expectations.** Removing the host from the inner loop is worth the PCIe traffic
and nothing else. Fitting the card's own cycle counters across a 6x range of job
size:

```
CYCLES = 21.67 * BEATS + 215
  BEATS= 128 CYCLES=  2992  cycles/beat=23.38
  BEATS= 384 CYCLES=  8582  cycles/beat=22.35
  BEATS= 256 CYCLES=  5724  cycles/beat=22.36
  BEATS= 768 CYCLES= 16847  cycles/beat=21.94
```

The intercept is **215 cycles = 1.07 us**, so the per-job setup that D amortises
is worth **0.33 ms across a whole 311-job token**. The 21.67 cycles per beat is
**per-beat and does not amortise**, so **D does not touch it.** Anyone expecting
D to fix the engine's internal rate should read this first.
| **N3** | **NO RTL TOP COMPOSES A+B+C+D FOR THE CARD.** MEASURED: `hw/fk33/rtl/fk33_engine.vhd` instantiates `matvec_int4_desc_axi` and **nothing else** -- subsystem A alone. `rtl/llama_top.vhd` does instantiate all four (`matvec_int4`, `gdn_block`, `attn_block` + `attn_kv_axi`, the five `seq_*` + `rmsnorm_rs`, plus `sampler_stream`) but it is a SIMULATION top: it binds **`matvec_int4`, which has no descriptor plane**, and `C_REAL`, `C_KV_AXI`, `NORM_REAL` and `B_SRC_REAL` all default **false**. So between "B+C+D fits" and "9B runs on the card" there is an entire unwritten top level, and no row named it until now. **Blocked on WRITEDEC** (there is no point composing something that does not fit) and on N2 (the top level's host interface is exactly what N2 decides). | WRITEDEC, N2 | `hw/fk33/gen_fk33_engine.py`, `hw/fk33/rtl/fk33_engine.vhd` (generated), a new synthesis top |
| **N4** | **BUILD-HANG's real fix, which nobody owns.** A shell build sat blocked on `wait_on_run synth_1` for **27.6 hours** for a run `launch_runs` reported as started and never created. The processes were killed 2026-08-29 with Oren's approval; **the defect is untouched.** Fix is two lines of discipline in `hw/fk33/gen_pcieep.py`: a **bounded** wait, and a post-`launch_runs` assertion that the run directory actually exists. Small, self-contained, and the file is free. | none | `hw/fk33/gen_pcieep.py` |
| **N5** | **Re-measure the composed B+C+D after WRITEDEC lands.** COMPOSE MEASURED 771,900 LUT against 268,222 free. LUTDIET MEASURED the fix on one unit (`rmsnorm_rs` 169,746 -> 40,804 LUT at identical ports, FF, WNS and zero BRAM) and PROJECTED B+C+D at 210,890 against 233,765 free in `pb_core` -- a **9.8% margin, which is positive and thin**. A projection is not a measurement and 9.8% is not enough margin to schedule against. Re-run `sim/ooc_compose_bcd.tcl` on the post-WRITEDEC tree. | WRITEDEC | `sim/ooc_compose_bcd.tcl`, `hw/fk33/results/` |
| **N6** | **OI-3's two named mutations have never been re-run against the gate that should now catch them.** TRACK OI3B (`5578132`) gave `tb_llama_top` a real value gate (`P14`, pinning `L_X0`). The two defects OI-3 names live at `rtl/llama_top.vhd`'s `c_exp_region <= to_unsigned(R_VIN, 8)` and `if k >= 2 then qg_buf(k-2) <= el_rdata`, both inside the config `tb_llama_top_real` exercises, and both move `R_X(0)`. So the gate *should* kill them -- but MEASURED by TRACK BOARDAUDIT, no mutate script and no line of OI3B's teeth table names either one, and OI3B's teeth were taken on different mutations (C1, the `v_ref` collapse, the `gdn_silu` truncation). **A gate that should catch a defect and has never been shown to is exactly the class this project keeps being bitten by.** Cheap: two mutations, one bench. | OI3B (landed) | `sim/mutate_llama_top_land.sh`, `sim/tb_llama_top*.vhd` |
| **N7** | **`EC_CORE` (0xE) is reachable by no bench in the tree**, and mutation `R1` deleting the `core_err -> EC_CORE` path survives both judges. Closing it needs a stimulus no bench currently produces. Raised by TRACK DESC-MUT with no owner; still none. | none | `sim/tb_matvec_fk33_desc.vhd`, `sim/mutate_mv4i_desc*.sh` |
| **N8** | **Subsystem A coverage gaps, all three named by DESC-MUT and all three still open.** `rtl/matvec_int4.vhd` and `rtl/axi_rd_port.vhd` have **no mutation script**; `USE_XEXP_PORT=true` appears in **no bench at all**; and `DUAL_CLK=true` is a manual run, so the descriptor-path CDC -- whose absence once broke 17 of 22 cases -- has no automatic coverage. | none | `sim/mutate_matvec_int4.sh` (new), `sim/mutate_axi_rd_port.sh` (new), `sim/regress.sh` |
| **N9** | **The only surviving SQRL factory image has no off-disk copy.** `hw/fk33/bit/fk33_factory_backup_153300001366.{bin,mcs}` (33,554,432 B and 92,282,892 B) were dumped 2026-08-29 and VERIFIED by two independent reads with identical md5 (`dcb97432538b9c7d2855b1d9c93658f7`). They are **untracked in git** and sit only on a root filesystem at **91%**. Card 1's factory image was destroyed; this is its restore path and the only irreplaceable artefact in the project. Copy it to `/mnt/storage` (388 G free) and record the digest. Trivial, and the cost of not doing it is unbounded. | none | `hw/fk33/bit/` (copy only), a note in `docs/` |
| ~~**10**~~ | ~~OI-9 is a decision: widen, subdivide, or take a reserved D value. Ask Oren rather than choosing.~~ **DECIDED by Oren 2026-08-29: SUBDIVIDE VIA `ERR_INFO`.** See the Decisions table. The row is no longer a decision; it is row N12. | -- | -- |
| **N12** | **OI-9 implementation: subdivide the descriptor error space via `ERR_INFO`.** Oren decided the route on 2026-08-29, so this is determined work. VERIFIED still needed at HEAD: `rtl/matvec_int4_desc_pkg.vhd` accounts for all sixteen 4-bit values (`EC_NONE 0x0`, `EC_DESC 0x3`, `EC_WDOG 0x4`, `EC_GEOM 0x9`..`EC_SHAPE 0xF`, with `0x1,0x2,0x5..0x8` reserved for D) and says so in its own comment. **The byte layout must not move** -- that is the reason the route was chosen. Two things this must carry, both already MEASURED by TRACK DESC-MUT: **`EC_DESC` (0x3) is raised at NINE sites with two confirmed collisions even with `ERR_INFO` pinned**, so "refused for the right reason" is currently recoverable for only 6 of 9 codes and subdividing `EC_DESC` is the first thing this buys; and `ERR_INFO` is a word index by construction, so the sub-case encoding has to coexist with that meaning rather than replace it. Update the host decoder in the same change or the card gains a code the host cannot name. | none | `rtl/matvec_int4_desc_pkg.vhd`, `rtl/matvec_int4_desc_axi.vhd`, `server/pl_backend.c` (the decoder), `sim/tb_matvec_fk33_desc.vhd`, `docs/2026-08-28_matvec-descriptor-format.md` |
| **7** | **OI-3 proper: the two defect classes `tb_llama_top` structurally cannot see.** Distinct from N6, which only asks whether the existing gate already covers them. If N6 measures that it does, this row closes; if it measures that it does not, this row is the work. | N6 | `sim/tb_llama_top.vhd` |
| **N10** | **Gray coding still has no automated defence, and this is now precise.** TRACK CDC-STATIC's `sim/cdc_teeth.sh` and `docs/debugging/2026-08-29_cdc-static-analysis.md` (`be982b3`) closed two of the three classes: the encoder/decoder MISMATCH (`G2`) is caught by simulation, and the 2FF-vs-1FF MTBF class by `report_cdc`. **`G1`, both gray functions replaced by identity, is caught by neither** -- and is worse than uncaught, because the binary-pointer design reports TWO FEWER `report_cdc` warnings than the correct one, so any "the report must not get worse" rule passes it. The doc says so about itself. No owner. | none | `rtl/async_fifo.vhd`, `sim/cdc_teeth.sh` |
| **N11** | **`K2b`: `P_CB_CHK`'s idle invariant watches the command REGISTER, not the write.** VERIFIED unchanged at HEAD: the assert is on `cbw_v(0)`, which is the stage-W0 command register set the cycle `cb_we='1' and st=S_IDLE`, not the stage-W1 write into `cb(c)`. Any future change that deepens the codebook command path makes the invariant vacuous with nothing in the tree noticing. A standing hazard, not a task; recorded so it is not discovered by a defect. | none | `rtl/matvec_core.vhd` |

### THE ORDERED READY-TO-DISPATCH LIST

**STALE AS A WHOLE -- AUDIT BEFORE USING. Checked 2026-09-11:** this list was
produced 2026-08-29 and **row 1 (N1) has been ANSWERED since that same evening**
without ever being struck. The list reads as current and is not. Before
dispatching ANY row here, grep this file for a section that closes it -- for N1
that is "ROW N1 IS ANSWERED" -- because the closing sections are written and the
table is not updated. That asymmetry has now cost three dispatches by the board's
own count, plus one near-miss on 2026-09-11.


**Produced 2026-08-29 by TRACK BOARDAUDIT at HEAD `5a19f984`, after auditing
every row above against the tree.** READY means both of: its file ownership
does not collide with WRITEDEC, KVVALUE or CLOG2TOP, and its dependency has
landed. Ownership was checked against the rewritten table at the top of this
file, not against the stale one it replaced.

**Dispatch in this order. The first three are mutually non-colliding and can
run concurrently right now.**

| order | row | why now | owns | collides with a running track? |
|---|---|---|---|---|
| ~~1~~ | ~~**N1**~~ | **ANSWERED 2026-08-29, STRUCK 2026-09-11.** Subsystem A computes correctly on the FK33: twelve jobs, all eight distinct `(M, K)` geometries, every mantissa and `y_exp` bit-identical to `ref/matvec_int4.c`, `err_code=EC_NONE` throughout, unconfounded by THERM-255 (counter read 0 before AND after every job). See `docs/debugging/2026-08-29_first-arithmetic-on-the-silicon.md` and the "ROW N1 IS ANSWERED" section above. **This row sat unstruck for 13 days and this dispatcher nearly dispatched onto it on 2026-09-11**, reading the list before the section that closes it -- the TENTH recorded instance of the board's own strike-on-landing rule not being followed. Original text: **The only item that converts "9B inference on the card" from unfalsifiable into measurable.** No dependency, no decision, no new RTL. **CORRECTED while this list was being written: `hw/fk33/host/` is NOT wholly free.** An undeclared track committed `4b26b7e` / `6d9c857` into `hw/fk33/host/fk33_load_weights.py` minutes ago. N1 adds a new file and edits `fk33_regs.h`, so it does not collide -- **but this is the second ownership error of the night and it was caught by watching `git log`, not by reading the table. Re-check `git log --oneline` for the target directory immediately before dispatching anything.** Write and fully exercise the runner through `fk33_transport_open_sim`/`_filedir` with **no hardware**; hand the final run to Oren, who is authorised for card 1 tonight and only tonight. | `hw/fk33/host/` (new file), `hw/fk33/host/fk33_regs.h` | no |
| **2** | **N12** | Oren decided the route hours ago, so it is determined work rather than a question. Carries DESC-MUT's `EC_DESC` nine-site collision measurement, which is the thing the route actually buys. | `rtl/matvec_int4_desc_pkg.vhd`, `rtl/matvec_int4_desc_axi.vhd`, `server/pl_backend.c`, `sim/tb_matvec_fk33_desc.vhd`, `sim/regress.sh` (shared) | no |
| **3** | **N4** | Small, self-contained, and it is the fix for a defect that already cost 27.6 hours of a build slot silently. `hw/fk33/gen_pcieep.py` was released by PBLOCK and nobody has claimed it. Fold **N9** into this track: copying the only surviving SQRL factory image off a 91%-full root disk is minutes of work and the cost of not doing it is unbounded. | `hw/fk33/gen_pcieep.py`; plus `hw/fk33/bit/` (copy only) for N9 | no |
| **4** | **N8** | Three named subsystem-A coverage gaps, all still open, all independent of everything running. Sequence it AFTER N12 if N12 is running, because both touch `sim/regress.sh` and one of them touches `tb_matvec_fk33_desc`. | `sim/mutate_matvec_int4.sh` (new), `sim/mutate_axi_rd_port.sh` (new), `sim/regress.sh` (shared) | no, but serialise with N12 |
| **5** | **N7** | `EC_CORE` reachable by no bench. Genuinely open, no owner. **Serialise after N12**, which is in the same file, and there is a real argument for making them one track: N12 subdivides the error space and N7 makes one of its codes reachable. | `sim/tb_matvec_fk33_desc.vhd`, `sim/mutate_mv4i_desc*.sh` | serialise with N12 |
| **6** | **N10** | The one gray-coding class nothing defends, now narrowed to `G1` alone by CDC-STATIC. Honest risk: it may be unclosable, and the write-up already argues so. Dispatch it as a question, not as a task, and accept "measured, cannot be closed, here is why" as a good result. | `rtl/async_fifo.vhd`, `sim/cdc_teeth.sh` | no |
| BLOCKED | **N6** | Cheap and valuable, but **KVVALUE owns `sim/tb_llama_top.vhd`**. Dispatch the moment KVVALUE releases. Closing N6 also closes or reopens backlog row 7, so it gates that too. | `sim/mutate_llama_top_land.sh`, `sim/tb_llama_top*.vhd` | **yes, KVVALUE** |
| BLOCKED | **N5** | Depends on WRITEDEC. It replaces LUTDIET's 9.8% PROJECTED margin with a measurement, and 9.8% is not a margin anyone should schedule against. Dispatch the moment WRITEDEC lands. | `sim/ooc_compose_bcd.tcl`, `hw/fk33/results/` | **yes, WRITEDEC** |
| BLOCKED | **N3** | Depends on WRITEDEC (no point composing what does not fit) and on N2 (its host interface is what N2 decides). The single largest piece of unwritten work between here and 9B on the card. | `hw/fk33/gen_fk33_engine.py`, a new synthesis top | **yes, WRITEDEC; and N2** |
| **OREN** | **N2** | A decision, not a fix: is the seam or the descriptor plane the contract? Raise it; do not let a track choose. N1's result is the evidence that should inform it, which is another reason N1 goes first. | decision | n/a |

**If all four slots are somehow free: N1, N12, N4+N9, N8.**

**What this list does NOT contain, said explicitly.** No row here claims the
card computes anything correctly, because nothing has measured that. N1 is the
row that would, and until it returns a number, every downstream estimate on
this board -- the LUT margin, the token budget, the schedule -- is arithmetic
about a machine whose arithmetic has never been checked.

## 2026-09-07 -- the three-cell card block design builds

**`pcieep_build.sh --bd-only` passes with the card in it.** Exit 0, zero
`ERROR:` lines, zero address-overlap warnings, `validate_bd_design` and
`make_wrapper` both clean, in BOTH configurations (`FK33_CARD=1` and unset).
This is LEGALITY ONLY: nothing was synthesised, so area, fit and timing for the
three-cell design remain unknown.

The design is `eng` (subsystem A) + `card` (B, C, D) + `bcgrant`, joined by the
11-net A seam, the card's AXI-Lite master onto the engine's control slave
through a new 2:1 smartconnect, the 34-net host seam replacing the subsystem-D
tie-off, and B/C through the grant onto SAXI_30/31 via a clock converter each.

Six faults were fixed to get there, none of them reachable by simulation; the
order matters because each was invisible until the previous one was fixed. See
`docs/debugging/2026-09-07_wiring-the-card-into-the-block-design.md`.

**Two guard defects found on the way, both worth remembering:**

- `FK33_ENG portcheck bad=2 (must be 0)` **and the build passed.** The counter
  was printed and never branched on, so a dangling master, an undriven ACLK or
  an undriven `compute_halt` would all have been reported into a log and
  ignored. It now raises.
- The seam tie-off guard reads the generated script's TEXT. Deleting the
  tie-off at Tcl run time would have left its text in place and the guard would
  have kept passing even if the delete matched nothing. The tie-off is now not
  emitted at all when the card is on.

**The grant's pool went from 3 HBM ports to 2, because 2 is all there is.**
32 SAXI, minus 2 host, minus A's 28. It never needed 3: port 0 is driven only
on AR/R and port 2 only on AW/W/B, so C's write moved onto port 0's idle write
channels. See
`docs/debugging/2026-09-07_the-grant-pool-was-one-port-over-budget.md`.

Full gate PASS 137 FAIL 0 BUILD-ERROR 0, unchanged from baseline.

**Next:** OOC synthesis of `fk33_card` is running, to get the first area figure
for B+C+D together. The 3h30m `synth_design -rtl` attempt that preceded this
was NOT the same thing -- it set `dissolveMemorySizeLimit 200000`, which
expands inferred memories into individual bits, and the hypothesis under test
is that real synthesis is faster because it infers BRAM instead.

## 2026-09-08 -- the software path is complete and verified; the bitstream is not

**Re-verified end to end tonight, all green, nothing outstanding on the host
side.** The OpenAI-compatible server, the driver/transport, the tokenizer, the
chat template and the FK33 host seam are finished work:

```
SEAM_SELFTEST   PASS (84 checks, 0 failed)   12 groups incl. the real transport
SERVER_STORIES  PASS (0 failed)              11 checks, echo/stream invariants
SERVER_E2E      PASS (0 failed)              6 chat cases + usage + tool refusal
```

Live against a running server: `/v1/models`, `/v1/chat/completions` streaming
and non-streaming, `/v1/completions`, correct `usage` accounting on both arms.
`stories260k` produces coherent prose and is token-identical to the AXU3EG VHDL
engine at temperature 0.

**What is NOT inference, stated plainly because the server states it too.** The
`qwen3.5-9b-fk33` arm runs the real chat template, the real tokenizer (bit-exact
against llama.cpp) and the real prefill/decode-returning-logits protocol against
a **SIMULATED** card that does not execute a transformer. Its tokens are
gibberish by construction and the model description says so. The only card
backends are `sim` and `file`; there is deliberately no flag that opens
`/dev/xdma*`.

So the remaining gap to generated output on hardware is exactly two things, both
below the host software, and neither is a software task:

1. **A bitstream for the three-cell card.** The block design builds as of
   2026-09-07; area, fit and timing are still unknown.
2. **A whole-model 9B numeric reference**, without which a real card's output
   cannot be checked against anything.

**Measurement trap hit tonight, recorded because it nearly produced a wrong
"fix".** `--model qwen35` refused at startup with `pl_open: block layout
refused: out of range: SEQ_POS + N_STEP past the KV capacity, or a block past
the top of HBM`. Grepping the journal for error-shaped words returned that line
and fragments, and it reads like a KV-capacity bug. It is not: the server
prints, immediately after, a complete remedy naming `--manifest` and
`--desc-arena-bytes` and the exact figure (159,232 bytes for the 9B program's
311 descriptors at a 512-byte slot). **The guidance was there and the grep cut
it off.** The zero default is deliberate -- `llama_server.cpp:986` says a silent
default is what the refusal exists to prevent -- and must not be "fixed".
Read the whole refusal, not a grep of it.

**Card OOC synthesis: still running at 5h15m, 15.4 GB under a 16 GB cap**,
`memory.events high 0` (no throttling), swap flat at 4 GB throughout, one RSS
dip at ~4h49m that was a genuine phase change rather than reclaim. This is the
first attempt at B+C+D together. The 3h30m `synth_design -rtl` that preceded it
is not comparable: it set `dissolveMemorySizeLimit 200000`, expanding inferred
memories to individual bits, and reached 14.5 GB without finishing.

## 2026-09-08 -- the card build runs bounded, and wants more than 17 GiB

Seven launches took the `FK33_CARD=1` build from "OOM-killed in 2.5 minutes" to
"running real synthesis under a hard cap". Three method changes did it, all
committed and gated on `FK33_CARD`:

1. **`synth_checkpoint_mode None`** -- the block design synthesises inside the
   top run instead of spawning an out-of-context run per IP. One run instead of
   many, and a bounded process that fails on a diagnosable error rather than
   ten that take the machine.
2. **VHDL 2008 on the 48 card sources, VHDL-93 on the two wrapper tops.** The
   requirements are OPPOSITE and each is invisible until the other is fixed.
3. **`set_param general.maxThreads 2`** -- bounds the parallel workers Vivado
   forks INSIDE a run. 10 processes -> 4, 21.16 GB -> 14.21 GB.

**Result: synthesis runs, reaches the GT wizard IP, and pins the cgroup at the
17 GiB ceiling in sustained reclaim.** `oom_kill 0` throughout -- `MemoryMax`
throttles before it kills -- but `MemAvailable` fell to 5.3 GB and swap began
to creep, so it was stopped by hand. **The true peak is NOT known; all that is
established is that it wants more than 17 GiB.**

Three memory mechanisms, each behaving differently, all met tonight:
`MemoryHigh` reclaims and is INVISIBLE to systemd-oomd; systemd-oomd kills on
PSI regardless of either limit; `MemoryMax` reclaims first and only then kills
its own cgroup. **`ManagedOOMPreference=avoid` was tried and is WRONG** -- it
frees nothing and redirects the kill onto a bystander, which here is
`code-server`.

**Next, and it is Oren's call rather than a track's:**

- **More RAM.** 2 free DIMM slots, 128 GB max; the documented preference is
  2 x 32 GB replacing the current pair rather than filling all four (which
  drops below 6000 MT/s). This is the only option that certainly works.
- **Or trim the card for a FIRST bitstream.** Nothing requires the first
  working card to be the full 9B geometry. A smaller `C_KV_BLOCK`, fewer
  `A_ROWS_IF`, or B omitted would prove the three-cell wiring on real hardware,
  which is worth more than a full-size build that cannot be synthesised.

Full write-up incl. the four measured-and-rejected remedies:
`docs/debugging/2026-09-08_the-card-build-and-two-wrong-fixes.md`

## PROCESS DEFECT, 2026-09-14: I MONITORED THE JOB I WAS WATCHING AND NOT THE JOBS I WAS RUNNING

`probe10` finished at **08:41 MDT** with the root cause in its log. I read it at
**12:30**, when Oren asked. **Three hours forty-nine minutes**, with the answer
on disk and BOTH Vivado lanes idle.

There was a monitor on `cardooc` the whole time, firing every 30 minutes. There
was none on `probe9`/`probe10`, which were the jobs actually doing the work. I
even built `chain10.sh` to chain probe10 onto probe9's completion -- so the
chaining was careful and the NOTIFICATION was absent. A chain tells the next job
when to start; it does not tell ME when the last one ended.

**The rule: every background job that produces a RESULT I am waiting on gets a
completion notification, not just a completion.** `systemd-run` + a `sleep` loop
is a scheduler, not a monitor. The check is: "if this finishes while I am
looking elsewhere, what wakes me?" If the answer is "nothing", it is not
monitored, however well it is chained.

This is the REFILL RULE failing in a new way. The rule was written about not
leaving agent slots empty; here the slots were empty because I did not know the
work had finished. **Idle-because-unnoticed is indistinguishable from
idle-because-unscheduled, and costs the same.**


## 2026-09-14: MY CLAMP TURNED A DETECTABLE FAULT INTO SILENT WRONG NUMBERS

Fixing `gb_real.bp`'s `zb` (the 60-hour elaboration wall), v1 of the change
stored z DM-wide with a lane/word cursor pair. It was written up as an
IDENTITY, with three arguments from the code: sequential writes, a read of
exactly one word, and all writes completing before any read.

**All three arguments were true and the change was still wrong.**
`tb_llama_top` went **PASS 8 -> FAIL 6**, `R_X(0)` off by 29, with
`schedule mismatches=0 KV faults=0 B-state AXI faults=0`. Structure intact,
numbers wrong -- this file's oldest recorded lesson, hit again by me.

**The defect: `S_ZRD` has TWO entry paths and I reset the cursors on one.**
The `not B_SRC_REAL` bypass entered with stale cursors. I had verified the
index algebra twice and never enumerated the state's predecessors.

**AND THE REASON IT WAS SILENT RATHER THAN LOUD WAS MY OWN GUARD.** I wrote

    if zword < VH-1 then zword := zword + 1; end if;

as defensive clamping. `zword` is declared `natural range 0 to VH-1`, so
**without the clamp the second sweep would have raised a range error in
simulation on the first overrun.** The clamp caught that fault and converted it
into every element landing in the last word -- wrong numbers, no diagnostic.
It cost a full bench cycle plus a differential run to find what the subtype
would have reported immediately.

**A bounds guard on a value whose subtype already bounds it is not defence, it
is suppression.** Where a range is already declared, let it fire. v2 keys the
reset off `k = 0` at the top of `S_ZRD` -- both paths set `k := 0` before
entering, so a future third path cannot miss it -- and increments without
clamping.

**What actually found it: a DIFFERENTIAL run.** Keeping the old array alongside
the new store and asserting equality at every read printed
`ZBDIFF h=0 j=0 k=0 zlane=0 zword=3 VH=4 DM=32` in under a minute. Re-deriving
the algebra a third time would not have; the cursor was wrong, not the algebra.
**When a rewrite claims to be an identity, run both and assert it, rather than
arguing it.**


## 2026-09-15: THE CARD'S A BINDING (`ga_desc`) HAS NO BEHAVIOURAL COVERAGE

Found while trying to extend `sim/tb_fk33_cardtop_ident.vhd` to cover the arm a
fix has to change.

`fk33_llama_top`'s A-facing ports are **defaulted inputs** -- `a_y_we : in
std_logic := '0'`, `a_bvalid := '0'`, `a_job_done := '0'`, `a_y_data := (others
=> '0')` -- because "a VHDL entity cannot have a conditional port clause". The
identity bench **never connects any of them**: `grep -c` for `a_awaddr|a_y_we|
a_job_done|a_x_we` over the whole bench returns **0**, and its port map ends at
`bst_bresp`.

So with `A_DESC => true`:

- `a_bvalid` is stuck low, so `a_desc_adapter` never completes a descriptor
  write and `ad_done` never asserts;
- `a_y_we` is stuck low, so no y beat ever reaches `ga_desc.ap`;
- the FSM sits in S_GO/S_RUN and the run times out.

**The `A_DESC` generic is present on the bench and cannot be exercised.** The
bench's own header states the rule that both arms "must compute the SAME
numbers" and that the true arm "drives the REAL `matvec_int4_desc_axi`" -- that
is the INTENT; the wiring for it does not exist.

**Consequences, stated plainly:**

1. `ga_desc` -- the branch the CARD BUILDS -- has never been simulated. Its
   `ap` process, its y buffer, its handshake with `a_desc_adapter` and
   `a_job_counter`, and the S_GO ordering rule its own header calls "THE ONE
   ORDERING RULE" are all unverified behaviourally.
2. Every landmark this project quotes for the card top was measured on the
   `ga_real` arm, i.e. on the binding the card does NOT use.
3. Any fix to `ga_desc` -- including the y-store rewrite the elaboration stall
   requires -- is unverifiable until this is closed. Structure and synthesis
   can be checked; VALUES cannot.

This is this repository's own recorded failure mode: a per-unit evidence class
that says nothing about the composition, and a generic whose default quietly
selects the arm that is NOT shipped. It is the same shape as the harness-default
traps already catalogued, one level up: not a wrong default VALUE, but a bench
that cannot run the non-default arm at all.

**What closing it needs:** a descriptor-plane engine model in the bench -- an
AXI-Lite slave that accepts the adapter's descriptor writes and responds, plus a
y-beat producer whose numbers match what `ga_real` computes, since the identity
claim is that both arms agree. That is bench engineering, not a generic flip.

