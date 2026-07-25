# FFN Staging-Register Elimination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the wide zero-logic register-to-register staging copies in the FFN datapath of `engine_shared.vhd` that are the on-silicon HOLD-violation hazard, so the AXU3EG llama engine produces deterministic, correct tokens.

**Architecture:** The layer FSM currently stages operands into wide registers (`sw_hb_mant`, `sw_hb2_mant`, `res_a_mant`, `res_b_mant`) one clock before the consumer unit (swiglu / residual) runs. These are 1024-2752-bit reg-to-reg copies with data delay (~0.175 ns) barely above clock skew (~0.12 ns) -> non-deterministic hold capture on silicon. The consumer units read their inputs COMBINATIONALLY across their whole multi-cycle sweep, and every source register is already stable for that entire window. So the staging registers are redundant: replace them with direct wires (swiglu, fixed source) or a small combinational mux (residual, two source pairs), which (a) removes the reg-to-reg hold arcs entirely and (b) frees ~4800-5500 FFs.

**Tech Stack:** VHDL-2008, GHDL (functional sim / regression), Vivado 2023.2 (synth/impl via `~/vivado-mem.sh`), Zynq UltraScale+ XCZU3EG, serial board bring-up.

## Global Constraints

- Bit-exact functional equivalence is MANDATORY: `tb_engine_shared` must stay **PASS 24/24 tokens** after every RTL edit. This is the primary correctness gate.
- Do NOT change any file under `rtl/` other than `engine_shared.vhd`. The consumer units (`swiglu.vhd`, `residual.vhd`) are unchanged.
- Do NOT commit to git unless the user explicitly asks (project rule). Leave validated changes on disk; note git state instead.
- ALWAYS build via `~/vivado-mem.sh` (31 GB box OOMs otherwise). Source `/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh` first for standalone vivado.
- Board deploy: swap ONLY `/tftpboot/system.bit.bin`; keep `image.ub` = the current design_2 engine image. The known-good 0.1 build is preserved at `/tftpboot/system.bit.bin.prev-hold01` (md5 017270c7) and must remain the rollback.
- The route pre-hook `AlinxMigrated/tcl/route_hold_uncertainty.tcl` keeps its proven global 0.100 ns hold uncertainty; `FFN_MD_ENABLE 0` stays 0 (the FFN set_min_delay pairs break attention via shared mm_xin). This plan fixes the arcs in RTL instead, so no constraint changes are needed.
- No em-dashes / no emojis in any file (project rule).

## Background / evidence (why this is the fix)

- The `to_signed(integer)` sign-drop bug and the attention hold path are already FIXED on silicon (0.1 ns global hold uncertainty): att-rmsnorm/att-out/attNum/attSum are correct and deterministic. Remaining failure = FFN residual (`C4`/`C8`/final vary run-to-run, token[4]=0).
- A dedicated impl/constraints investigation proved clock-skew reduction and all constraint levers CANNOT close this: the worst FFN hold path `x_mant_cur_reg[261] -> res_a_mant_reg[261]` is a 1-LUT reg-to-reg copy, data delay 0.175 ns, effective skew 0.019 ns; margin must come from inserting data delay, but at 82% LUT the router congests above the 0.1 bar. Fix must be RTL. Full detail in memory `llama-pl-tosigned-and-silicon-nondeterminism`.
- The offending arcs (all in `engine_shared.vhd`): `x_mant_cur -> res_a_mant` (L_RES1_S), `wo_reg -> res_b_mant` (L_RES1_S), `xm_mant -> res_a_mant` (L_RES2_S), `w2_reg -> res_b_mant` (L_RES2_S), `w1_reg -> sw_hb_mant` (L_SW_S), `w3_reg -> sw_hb2_mant` (L_SW_S).

## File Structure

- Modify only: `rtl/engine_shared.vhd`
  - Remove FSM staging assignments in states `L_RES1_S`, `L_RES2_S`, `L_SW_S`.
  - Convert `sw_hb_mant/exp`, `sw_hb2_mant/exp`, `res_a_mant/exp`, `res_b_mant/exp` from process-driven registers to concurrent (combinational) signals.
  - Add one new register `res_sel` to select the residual source pair.
- Test / regression: `sim/tb_engine_shared.vhd` (existing; run via GHDL, no edit).
- Build scripts (no edit, used as-is): `AlinxMigrated/build_all_fixed.sh`, `tcl/build_design2_impl.tcl`, `tcl/route_hold_uncertainty.tcl`.

## Reusable command snippets (referenced by steps)

**GHDL 24/24 regression** (from `~/GitHub/llama.vhdl/sim`, ~2-4 min):
```bash
cd /home/orencollaco/GitHub/llama.vhdl/sim
W=$(mktemp -d)
ghdl -i --std=08 --workdir="$W" ../rtl/*.vhd tb_engine_shared.vhd >/dev/null 2>&1
ghdl -m --std=08 --workdir="$W" tb_engine_shared 2>&1 | grep -iE 'error' | head
ghdl -r --std=08 --workdir="$W" tb_engine_shared --max-stack-alloc=0 2>&1 | grep -iE 'PASS|FAIL'
# Expect: PASS:engine_shared 24/24
```

**Full build** (RTL changed -> must re-package IP; ~45 min, background):
```bash
cd /home/orencollaco/GitHub/AlinxMigrated
nohup bash build_all_fixed.sh > /tmp/ffn_buildN.log 2>&1 &
# wait, then:
grep -iE "IMPL_STATUS|WNS|WHS|WHS_SRC|WHS_DST|Utilization|LUT as Logic|failed to route|node overlaps|BUILD_ALL_DONE" /tmp/ffn_buildN.log | tail -20
```

**Utilization + worst hold path from routed report** (post-build, no rebuild):
```bash
R=/home/orencollaco/GitHub/AlinxMigrated/axu3eg_trd.runs/impl_1/design_2_wrapper_utilization_placed.rpt
grep -iE "CLB LUTs|CLB Registers|Block RAM Tile" $R | head
# worst hold path already printed as WHS_SRC/WHS_DST at end of build log
```

**Bootgen + stage + serial board determinism test** (only after timing report looks good):
```bash
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh >/dev/null 2>&1
cd /home/orencollaco/GitHub/AlinxMigrated/axu3eg_trd.runs/impl_1
printf 'all:\n{\n  design_2_wrapper.bit\n}\n' > /tmp/gen_d2.bif
bootgen -arch zynqmp -image /tmp/gen_d2.bif -process_bitstream bin -w on
cp -a design_2_wrapper.bit.bin /tftpboot/system.bit.bin
# reboot + read taps over serial (SSH network is intermittent):
SP=/tmp/claude-1000/-home-orencollaco-GitHub-zcu106-2023-2-axu3eg/cc8deed8-3cd2-425a-b31b-2a64b15ef251/scratchpad
# use SP/sc.py "<cmd>" <secs> for single serial cmds; stay SILENT 85s after any reboot
```
Board reg map: START `0x80110000`, STATUS `0x80110004`, COUNT `0x80110008`, DBG_POS `0x80110010`, ID `0x80110020` (=0x6C6C6D31), TOKEN[i] `0x80110040+4i`. Taps: C0 emb, C4 after-L0, C8 after-L4, CC final, D4 att-rms, D8 att-out, F4 attSum(0x801100F4), F8 attNum(0x801100F8). Golden tokens: `403 407 261 378 432 383 286 261 376 298 340 361`. Attention-correct reference (must NOT regress): D4=0x010DD572, F4=0x00001A84, F8=0xFCF48DB4.

---

### Task 1: Eliminate the swiglu staging registers (pure win: wires, -5504 FF, 0 LUT)

Replace `sw_hb_mant/sw_hb_exp/sw_hb2_mant/sw_hb2_exp` (registers driven in `L_SW_S`) with direct combinational wires to `w1_reg/w1_exp_r` and `w3_reg/w3_exp_r`. Sources are stable for the whole swiglu sweep (w1_reg written in L_W1_W, w3_reg in L_W3_W, neither rewritten until the next layer). This removes the `w1_reg->sw_hb_mant` and `w3_reg->sw_hb2_mant` hold arcs and frees 2x HIDDEN*16 = 5504 FFs at zero LUT cost.

**Files:**
- Modify: `rtl/engine_shared.vhd` (decls near line 237-240; FSM state `L_SW_S` at line 708-711; add concurrent assigns after the `u_hbpack` instantiation ~line 415)
- Test: `sim/tb_engine_shared.vhd` (GHDL, no edit)

**Interfaces:**
- Consumes: `w1_reg` / `w1_exp_r` (std_logic_vector(HIDDEN*16-1 downto 0) / integer), `w3_reg` / `w3_exp_r` (same types) -- existing FFN W1/W3 matmul output registers.
- Produces: signals `sw_hb_mant/sw_hb_exp/sw_hb2_mant/sw_hb2_exp` become combinational aliases; `u_sw` port map is unchanged (still references those names).

- [ ] **Step 1: Capture the pre-change GHDL baseline**

Run the GHDL 24/24 regression snippet (above) on the current tree.
Expected: `PASS:engine_shared 24/24`. If it does not pass BEFORE editing, STOP -- the tree is not clean.

- [ ] **Step 2: Remove the swiglu staging assignments in `L_SW_S`**

In `rtl/engine_shared.vhd`, the `L_SW_S` state currently reads:
```vhdl
          when L_SW_S =>
            sw_hb_mant  <= w1_reg; sw_hb_exp  <= w1_exp_r;
            sw_hb2_mant <= w3_reg; sw_hb2_exp <= w3_exp_r;
            sw_start <= '1'; state <= L_SW_W;
```
Replace it with (staging removed; the operands are now wired combinationally elsewhere):
```vhdl
          when L_SW_S =>
            -- sw_hb*/sw_hb2* are now concurrent wires to w1_reg/w3_reg (stable
            -- through the swiglu sweep); no reg-to-reg staging copy -> no hold hazard.
            sw_start <= '1'; state <= L_SW_W;
```

- [ ] **Step 3: Convert the swiglu staging signals to concurrent wires**

The declarations (near line 237-240) stay as-is (still `signal sw_hb_mant : std_logic_vector(HIDDEN*16-1 downto 0);` etc.), but they must now have exactly ONE driver: a concurrent assignment. Add these concurrent statements in the architecture body, immediately AFTER the `u_hbpack: entity work.bfp_pack ... ;` instantiation (around line 417, outside the FSM process):
```vhdl
  -- FFN staging-register elimination (Task 1): swiglu reads its operands
  -- combinationally across its sweep and w1_reg/w3_reg are stable for that whole
  -- window, so feed them directly instead of a wide reg-to-reg staging copy
  -- (removes the w1_reg->sw_hb_mant / w3_reg->sw_hb2_mant on-silicon hold hazard).
  sw_hb_mant  <= w1_reg;
  sw_hb_exp   <= w1_exp_r;
  sw_hb2_mant <= w3_reg;
  sw_hb2_exp  <= w3_exp_r;
```

- [ ] **Step 4: Confirm no other driver of these four signals remains**

Run:
```bash
cd /home/orencollaco/GitHub/llama.vhdl
grep -nE "sw_hb_mant|sw_hb_exp|sw_hb2_mant|sw_hb2_exp" rtl/engine_shared.vhd
```
Expected: each signal appears exactly at (a) its declaration, (b) the new concurrent assignment, (c) the `u_sw` port map. NO occurrence inside any `when ... =>` FSM state or with `<=` inside the clocked process. If a stray process assignment remains, remove it (multiple drivers = synth error / X).

- [ ] **Step 5: GHDL regression must stay 24/24**

Run the GHDL 24/24 regression snippet.
Expected: `PASS:engine_shared 24/24`. If FAIL, the equivalence assumption is wrong (a source was not actually stable) -- revert Step 2-3 and STOP; do not proceed to a build.

- [ ] **Step 6: Full build and read the timing/utilization**

Run the Full build snippet (`/tmp/ffn_build1.log`). Wait for `BUILD_ALL_DONE`.
Expected: `IMPL_STATUS: write_bitstream Complete`, WNS large positive, **0 failed-to-route / 0 node overlaps / 0 critical warnings**, and CLB Registers LOWER than the baseline by ~5.5k FF. Record WHS, WHS_SRC, WHS_DST and the LUT/FF/BRAM utilization.
Success signal for this task: the worst hold path (WHS_SRC/DST) is NO LONGER a `sw_hb*` arc, and WHS real margin is >= the 0.1 build's +0.109 ns (ideally higher because 5.5k FF of routing pressure is gone). If it congests (overlaps > 0), this is unexpected for a FF-removal-only change -- capture the log and STOP.

- [ ] **Step 7: Board determinism test (only if Step 6 timing is clean)**

Deploy via the Bootgen+stage snippet, reboot, and read taps over serial across 3 clean boots (stay SILENT 85 s after each reboot; SSH network is intermittent so prefer serial `sc.py`). For each boot: set DBG_POS=4, START, poll STATUS.done, read `C0 C4 C8 CC D4 D8 F4 F8` and TOK[0..8].
Expected / interpretation:
- Attention MUST NOT regress: D4=0x010DD572, F4=0x00001A84, F8=0xFCF48DB4 on every boot.
- If `C4`/`C8`/final are now STABLE across boots and tokens extend past `403 407 261 378` toward golden -> swiglu elimination was sufficient (unlikely alone, but possible). 
- If `C4`/`C8` still vary (residual arcs remain) -> expected; proceed to Task 2. Either way, if attention stayed correct and the build was clean, KEEP this bitstream staged is optional -- Task 2 will rebuild. Restore `/tftpboot/system.bit.bin.prev-hold01` if leaving the bench.

- [ ] **Step 8: Checkpoint (no git commit)**

Do NOT `git commit` (project rule). Note in the session / memory: Task 1 done, GHDL 24/24, FF delta, WHS, and whether C4/C8 determinism improved. Leave `engine_shared.vhd` edited on disk.

---

### Task 2: Eliminate the residual staging registers (mux, -2048 FF, +~1k LUT)

Replace `res_a_mant/res_a_exp/res_b_mant/res_b_exp` (registers driven in `L_RES1_S` and `L_RES2_S`) with combinational muxes selected by a new `res_sel` register (0 = pass-1 attention residual, sources `x_mant_cur`/`wo_reg`; 1 = pass-2 FFN residual, sources `xm_mant`/`w2_reg`). All four sources are stable for the whole residual sweep of their pass. This removes the `x_mant_cur->res_a_mant`, `wo_reg->res_b_mant`, `xm_mant->res_a_mant`, `w2_reg->res_b_mant` hold arcs (the measured WORST path `x_mant_cur->res_a_mant` among them). The mux adds ~1k LUTs; the design is LUT-bound, so watch utilization/congestion -- Task 1's freed routing should absorb it.

**Files:**
- Modify: `rtl/engine_shared.vhd` (decls near line 257-260; add `res_sel` decl; FSM states `L_RES1_S` line 662-666 and `L_RES2_S` line 736-740; add concurrent mux assigns near the Task 1 concurrent block)
- Test: `sim/tb_engine_shared.vhd` (GHDL, no edit)

**Interfaces:**
- Consumes: `x_mant_cur`/`x_exp_cur`, `xm_mant`/`xm_exp`, `wo_reg`/`wo_exp_r`, `w2_reg`/`w2_exp_r` (existing; mant = std_logic_vector(DIM*16-1 downto 0), exp = integer).
- Produces: new `signal res_sel : std_logic`; `res_a_mant/res_a_exp/res_b_mant/res_b_exp` become combinational mux outputs; `u_res` port map unchanged.

- [ ] **Step 1: Add the `res_sel` selector register declaration**

In `rtl/engine_shared.vhd`, near the residual signal declarations (after line 262, `signal res_o_exp : integer;`), add:
```vhdl
  -- Residual source selector (Task 2): 0 = pass-1 (attention residual, a=x_mant_cur
  -- b=wo_reg), 1 = pass-2 (FFN residual, a=xm_mant b=w2_reg).  Latched in the FSM,
  -- held through the residual sweep, drives the combinational res_a/res_b muxes.
  signal res_sel : std_logic := '0';
```

- [ ] **Step 2: Remove staging + set `res_sel` in `L_RES1_S`**

The `L_RES1_S` state currently reads:
```vhdl
          when L_RES1_S =>
            res_a_mant <= x_mant_cur; res_a_exp <= x_exp_cur;
            res_b_mant <= wo_reg;     res_b_exp <= wo_exp_r;
            res_start  <= '1';
            state <= L_RES1_W;
```
Replace with:
```vhdl
          when L_RES1_S =>
            res_sel   <= '0';        -- a=x_mant_cur, b=wo_reg (combinational mux)
            res_start <= '1';
            state <= L_RES1_W;
```

- [ ] **Step 3: Remove staging + set `res_sel` in `L_RES2_S`**

The `L_RES2_S` state currently reads:
```vhdl
          when L_RES2_S =>
            res_a_mant <= xm_mant; res_a_exp <= xm_exp;
            res_b_mant <= w2_reg;  res_b_exp <= w2_exp_r;
            res_start  <= '1';
            state <= L_RES2_W;
```
Replace with:
```vhdl
          when L_RES2_S =>
            res_sel   <= '1';        -- a=xm_mant, b=w2_reg (combinational mux)
            res_start <= '1';
            state <= L_RES2_W;
```

- [ ] **Step 4: Add the residual mux concurrent assignments**

Immediately after the Task 1 concurrent block (the `sw_hb*` assigns), add:
```vhdl
  -- FFN staging-register elimination (Task 2): residual reads a/b combinationally
  -- across its sweep and the four source registers are stable for their pass, so
  -- mux them directly instead of a wide reg-to-reg staging copy (removes the
  -- x_mant_cur->res_a_mant / wo_reg->res_b_mant / xm_mant->res_a_mant /
  -- w2_reg->res_b_mant on-silicon hold hazards; the mux LUT delay kills the hazard).
  res_a_mant <= x_mant_cur when res_sel = '0' else xm_mant;
  res_a_exp  <= x_exp_cur  when res_sel = '0' else xm_exp;
  res_b_mant <= wo_reg     when res_sel = '0' else w2_reg;
  res_b_exp  <= wo_exp_r   when res_sel = '0' else w2_exp_r;
```

- [ ] **Step 5: Confirm single-driver on the residual signals**

Run:
```bash
cd /home/orencollaco/GitHub/llama.vhdl
grep -nE "res_a_mant|res_a_exp|res_b_mant|res_b_exp" rtl/engine_shared.vhd
```
Expected: each appears only at (a) declaration, (b) the new concurrent mux, (c) the `u_res` port map -- NO `<=` inside any FSM state. Also confirm `res_sel` is assigned only in `L_RES1_S` and `L_RES2_S`.

- [ ] **Step 6: GHDL regression must stay 24/24**

Run the GHDL 24/24 regression snippet.
Expected: `PASS:engine_shared 24/24`. A subtle failure here would mean `res_sel` timing (set at `_S`, effective at `_W` when `res_start` is seen) does not align -- if FAIL, verify `res_start` is asserted at `_S` (so the residual samples on the `_W` cycle when `res_sel` is already updated) and STOP.

- [ ] **Step 7: Full build; check utilization does not congest**

Run the Full build snippet (`/tmp/ffn_build2.log`). Wait for `BUILD_ALL_DONE`.
Expected: `write_bitstream Complete`, **0 overlaps / 0 route fails**. LUT should rise ~1k vs Task 1 (the muxes) but net FF down ~2k. Record WHS/WHS_SRC/WHS_DST + utilization. Success signal: the worst hold path is no longer a `res_a_mant`/`res_b_mant` arc and WHS real margin is comfortably positive (target >= +0.15 ns), route clean. If it congests, the LUT budget is the limiter -- capture the report and stop; the fallback is that Task 1 (FF relief) may still have improved determinism on its own.

- [ ] **Step 8: Board determinism test (3 clean boots)**

Deploy + reboot + read taps over serial as in Task 1 Step 7, across 3 clean boots.
Expected (success): attention still correct (D4/F4/F8 reference), AND `C4`/`C8`/final now STABLE across all 3 boots, AND tokens match golden `403 407 261 378 432 383 286 261 376 ...`. That is the end-goal: deterministic correct inference on silicon.
If C4/C8 stable but tokens still wrong (not 0, but not golden) -> a residual FUNCTIONAL bug remains (different from the hold issue); capture taps and investigate separately.
If C4/C8 still vary -> the residual mux did not fully remove the hazard (e.g. a feeder arc like `mm_o_mant->wo_reg` became the new worst path); read WHS_SRC/DST from the build log to identify the new arc and extend the same pattern.

- [ ] **Step 9: Finalize board state + checkpoint**

If the goal is met: leave the working bitstream on `/tftpboot/system.bit.bin` and note the md5. If not met or leaving the bench: restore `/tftpboot/system.bit.bin.prev-hold01`. Do NOT git commit. Update memory `llama-pl-tosigned-and-silicon-nondeterminism` with the outcome (FF/LUT deltas, WHS, determinism result, tokens).

---

## Self-Review

- **Spec coverage:** All six offending arcs are addressed -- Task 1 removes the two `sw_hb*` arcs, Task 2 removes the four `res_a/res_b` arcs. The measured worst path (`x_mant_cur->res_a_mant`) is in Task 2.
- **Type consistency:** mant buses are `std_logic_vector(DIM*16-1 downto 0)` (res, sources x_mant_cur/xm_mant/wo_reg/w2_reg all DIM*16) and `std_logic_vector(HIDDEN*16-1 downto 0)` (sw, sources w1_reg/w3_reg HIDDEN*16); all exps are `integer`. Verified against the declarations. `res_sel` is `std_logic`.
- **Single-driver:** Steps 4/5 (each task) explicitly verify exactly one driver per converted signal -- the critical VHDL correctness point for reg->concurrent conversion.
- **Equivalence basis:** consumers read inputs combinationally across their sweep (verified: residual S_ACC/S_PACK lines 92-93/110-111, swiglu S_CALC lines 82/93); sources are stable across each op (verified from FSM write points). This is why removing the staging register is functionally exact, and GHDL 24/24 is the gate that proves it every step.
- **Risk:** Task 2's mux adds LUTs to a LUT-bound design. Ordered Task 1 (frees ~5.5k FF, 0 LUT) FIRST so its routing relief is in place before Task 2 spends LUTs. If Task 2 congests, Task 1 alone is still a net improvement and a valid stopping point.
