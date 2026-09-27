# fmax limiters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pipeline c_attn, c_kv and v_swg, bit-exactly, until each rates >= 200 MHz on `vu35p_jc_m2`.

**Architecture:** Three independent RTL splits, smallest first. c_attn splits `attn_mac_array`'s S2 score tree into half-sums and a final add. c_kv registers `attn_kv_axi`'s read limit one cycle early behind a freshness bit. v_swg moves `sigmoid_q` into a five-stage `sigmoid_q_pipe` entity that `swiglu_mem` instantiates per lane. Each change is proved by the existing value benches plus one distinguishing check, then rated with `tools/rate`.

**Tech Stack:** VHDL-2008, GHDL (mcode) via `sim/regress.sh`, Vivado 2023.2 via `tools/rate/rate.py`, Python 3.

**Spec:** `docs/superpowers/specs/2026-09-26-fmax-limiters-design.md`

## Global Constraints

- Success: each of `c_attn`, `c_kv`, `v_swg` rates >= 200 MHz on `vu35p_jc_m2`, routed, over-constrained, FRESH; a single draw counts only at >= 217 MHz (achieved period <= 4.6 ns), otherwise a second draw at `target_ns` 4.0 must also reach >= 200 MHz (a re-run at the same target is not a draw: Vivado is deterministic).
- Bit-exact: every value bench passes unchanged; latency may grow only behind a valid flag.
- Levers stay off (`SWEEP_PIPE`, `SCORE_EARLY`, `NWIDE`, `FAST_POP` false); no card build in this plan.
- `rtl/fixed_pkg.vhd`'s `sigmoid_q` is not modified; it is the reference.
- No new `rtl/*.vhd` file: `swiglu_mem.vhd` is named explicitly in nine build/sim lists (`hw/fk33/gen_pcieep.py:1592` and others), so `sigmoid_q_pipe` lives in `rtl/swiglu_mem.vhd` above `swiglu_mem`.
- ONE Vivado on the workstation (c_attn peaks 16.5 GB + swap); the BC-250 (11G cap) takes only rows MEASURED under 5 GB.
- Gate runs: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/fmaxfix/<run> bash sim/regress.sh --only <substring> --keep`, read the `OVERALL PASS n` line (`PASS 0` means the substring matched nothing). No edits to any file while a gate runs.
- Commits: explicit paths only, `git commit -F <file>` for long messages, no Co-Authored-By line, no em-dashes.
- Label every number MEASURED / DERIVED / ESTIMATE in commit messages and docs.

## Review Focus

1. A `start` pulse (new token, `cpos_r` changes) while a c_kv read run is active: the registered limit must not survive it. Pinned in Task 2 Step 4 (mutant 2).
2. `swiglu_mem` at LANES 2 and 4 (and the w8 variants): the pipe's valid is taken from lane 0 for every lane. Pinned in Task 4 Step 3 (`--only swiglu` runs every LANES row).
3. `sigmoid_q` at the int32 extremes and exactly at the saturation edges (+-16 * 2^Q) and z = 0. Pinned in Task 3 Step 1.
4. `acc_clr` while a score is in the new S2b stage: the STRICT_PRODUCER assertion must see it. Pinned in Task 1 Step 3 (assertion extended) and Step 5 (bench green with STRICT_PRODUCER true).
5. The 9B card configuration (KV_BLOCK 32, NBLK 8, real HBM latency model) rather than the unit-bench geometry. Pinned in Tasks 1, 2 and 4 by `--only csweep` (`tb_csweep_rate`, the card's C sweep).

---

### Task 1: c_attn -- split `attn_mac_array` S2 into half-sums and a final add

**Files:**
- Modify: `rtl/attn_mac_array.vhd` (S2 score branch at `:437-457`, signals at `:246-261`, reset at `:329-332`, `acc_clr` assertion at `:499-503`)
- Modify: `sim/tb_attn_mac_array.vhd` (collector at `:136-151`, drain waits at `:247`, `:295`)
- Create: `hw/targets/ratings/vu35p_jc_m2/c_attn.QWEN35_9B.json`, `hw/targets/ratings/vu33p_fk33/c_attn.QWEN35_9B.json` (regenerated)

**Interfaces:**
- Produces: `p_valid`/`p_data`/`p_blk` of `attn_mac_array` arrive exactly 4 edges after `sc_valid` is sampled (was 3). Nothing else in the entity's contract changes.

- [ ] **Step 1: Write the distinguishing check in the bench**

In `sim/tb_attn_mac_array.vhd`, add a generic after the existing generics:
```vhdl
    -- Edges from the edge that samples sc_valid to the edge the collector sees
    -- the partial.  3 before the 2026-09-26 S2 split, 4 after it.
    P_LAT : positive := 4;
```
add a signal next to `par_n`:
```vhdl
  signal sc_hist : std_logic_vector(7 downto 0) := (others => '0');
  signal lat_bad : integer := 0;
```
and replace the body of the `collect` process's clocked branch with:
```vhdl
    if rising_edge(clk) then
      sc_hist <= sc_hist(6 downto 0) & sc_valid;
      if rst = '1' then
        par_n <= 0;
      elsif p_valid = '1' then
        -- The latency contract, measured on every partial: the score that
        -- produced it was sampled exactly P_LAT edges earlier.  sc_hist(k)
        -- holds sc_valid as sampled k+1 edges before this one.
        if sc_hist(P_LAT-1) /= '1' then
          lat_bad <= lat_bad + 1;
          report "tb_attn_mac_array: a partial arrived without a score "
               & integer'image(P_LAT) & " edges earlier" severity error;
        end if;
        b := to_integer(p_blk);
        for h in 0 to QH_TILE-1 loop
          par_got(h*ACC_N + b) <= to_integer(signed(p_data((h+1)*P_W-1 downto h*P_W)));
        end loop;
        par_n <= par_n + 1;
      end if;
    end if;
```
Change both drains that wait for the pipeline (`for i in 1 to 4 loop` at `:247`, and the `GAP + 3` wait at `:295`) to use `P_LAT + 1` and `GAP + P_LAT`, with the comment `-- drain P_LAT stages plus the collector's edge`. In the final verdict (`:333-346`), fail when `lat_bad /= 0` exactly as it does for `nerr /= 0`.

- [ ] **Step 2: Run the bench against the UNCHANGED RTL to see it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/fmaxfix/t1_red bash sim/regress.sh --only tb_attn_mac_array --keep`
Expected: `FAIL` with `a partial arrived without a score 4 edges earlier` (the old RTL delivers at 3). This is the old version failing the new case (CLAUDE.md: a check never shown to fail has not been shown to work).

- [ ] **Step 3: Split S2 in the RTL**

In `rtl/attn_mac_array.vhd` add after `constant T_W`:
```vhdl
  -- S2a sums each half of the DIM_TILE products; S2b adds the halves and does
  -- the P_W range compare.  A wide add tree and a wide compare were in one
  -- stage (the project rule, header), MEASURED 142.0 MHz on VU33P -2LV and
  -- 173.7 on VU35P -2 (block ratings, 2026-09-26).  T_W holds the full sum, so
  -- the two halves and their sum are exact: the split cannot change a value.
  constant HALF  : integer := DIM_TILE/2;
```
after `type p_arr`:
```vhdl
  type t_arr is array (0 to QH_TILE-1) of signed(T_W-1 downto 0);
```
after `signal pb_r`:
```vhdl
  signal hs_lo, hs_hi : t_arr := (others => (others => '0'));
  signal sv3  : std_logic := '0';
  signal blk3 : integer range 0 to ACC_N-1 := 0;
```
add to the process's variables:
```vhdl
    variable tl, th : signed(T_W-1 downto 0);
```
add `sv3 <= '0'; blk3 <= 0;` to the `rst = '1'` branch.

Replace, from `pv_r  <= '0';` through the end of the `when M_SCORE =>` branch (`:437-457`), with:
```vhdl
        pv_r  <= '0';
        ov_r2 <= '0';

        -- ---------------- S2b: the final add and the range compare -------
        sv3 <= '0';
        if sv3 = '1' then
          for h in 0 to QH_TILE-1 loop
            t := hs_lo(h) + hs_hi(h);
            if t > resize(not shift_left(to_signed(-1, P_W), P_W-1), T_W)
               or t < resize(shift_left(to_signed(-1, P_W), P_W-1), T_W) then
              er_r <= '1';
            end if;
            pd_r((h+1)*P_W-1 downto h*P_W)
              <= std_logic_vector(resize(t, P_W));
          end loop;
          pv_r <= '1';
          pb_r <= blk3;
        end if;

        case mode2 is
          when M_SCORE =>
            -- ---------------- S2a: the two half trees -------------------
            for h in 0 to QH_TILE-1 loop
              tl := (others => '0');
              th := (others => '0');
              for t2 in 0 to HALF-1 loop
                tl := tl + resize(p_reg(h*DIM_TILE + t2), T_W);
              end loop;
              for t2 in HALF to DIM_TILE-1 loop
                th := th + resize(p_reg(h*DIM_TILE + t2), T_W);
              end loop;
              hs_lo(h) <= tl;
              hs_hi(h) <= th;
            end loop;
            sv3  <= '1';
            blk3 <= blk2;
```
(the `when M_PV =>` and `when M_RS =>` branches follow unchanged). In the `acc_clr` STRICT_PRODUCER assertion change `assert mode1 = M_NONE and mode2 = M_NONE` to `assert mode1 = M_NONE and mode2 = M_NONE and sv3 = '0'`. In the header's STRUCTURE AND TIMING list replace the S2 line with:
```
--   S2   score: the two half trees (S2a), then the final add and the range
--        compare (S2b, 2026-09-26)
```

- [ ] **Step 4: Run the bench, now green**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/fmaxfix/t1_green bash sim/regress.sh --only tb_attn_mac_array --keep`
Expected: `PASS`, `OVERALL PASS 1`.

- [ ] **Step 5: Run every attention and card-sweep bench**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/fmaxfix/t1_attn bash sim/regress.sh --only attn --keep` then `... --only csweep --keep`
Expected: every row PASS (read `OVERALL PASS n` for both; `n` is the number of matched rows, 21 for `attn`, 1 for `csweep`). A FAIL in a file this task did not touch is contention: re-run on a quiet box before believing it.

- [ ] **Step 6: Rate on the gating part and the current card part**

```bash
python3 -c "import sys; sys.path.insert(0,'tools/rate'); import calib; calib.set_target('c_attn', 4.25, 'vu35p_jc_m2')"
python3 tools/rate/rate.py run c_attn --device vu35p_jc_m2 --model QWEN35_9B --mem 16G
python3 tools/rate/rate.py run c_attn --device vu33p_fk33 --model QWEN35_9B --mem 16G
```
Expected: `RATE_RECORD c_attn achieved` >= 217 MHz on `vu35p_jc_m2` with WNS < 0. If it is 200-217 MHz, take the second draw the spec requires: `calib.set_target('c_attn', 4.0, 'vu35p_jc_m2')` and rate again (re-running the SAME target is not a draw: Vivado is deterministic for identical inputs, MEASURED bit-identical across two machines); both must be >= 200, and the committed record is the second. If below 200 MHz, read the new worst path from `timing_routed.rpt` and stop: the split did not remove the limiter, and a re-design goes back to the spec. The critical endpoint must no longer be `er_r`.

- [ ] **Step 7: Commit**

```bash
git add rtl/attn_mac_array.vhd sim/tb_attn_mac_array.vhd hw/targets/blocks.json hw/targets/ratings/vu35p_jc_m2/c_attn.QWEN35_9B.json hw/targets/ratings/vu33p_fk33/c_attn.QWEN35_9B.json
git commit -F <msg>   # "c_attn: split attn_mac_array S2 (half trees, then add + compare); <MHz> on VU35P -2, <MHz> on VU33P -2LV (MEASURED); p_valid 4 edges after sc_valid, old RTL fails the new check"
```

---

### Task 2: c_kv -- register the read limit in `attn_kv_axi`

**Files:**
- Modify: `rtl/attn_kv_axi.vhd` (`GEN_RD` signals `:652-667`, `P_RD` `:737-915`)
- Create: `hw/targets/ratings/vu35p_jc_m2/c_kv.QWEN35_9B.json`, `hw/targets/ratings/vu33p_fk33/c_kv.QWEN35_9B.json` (regenerated)

**Interfaces:**
- Produces: no port change. An AR may issue one cycle later than before; never earlier, never beyond the limit the current `c_max` allows.

- [ ] **Step 1: Add the registered limit, the freshness bit and the safety assertion**

In `GEN_RD`'s declarations, add a constant and signals, and constrain the two unconstrained integers:
```vhdl
    -- The highest beat index a read run can reach, DERIVED: phase < BEAT_CH,
    -- MAXCTX records of CPR chunks, rounded up, plus one burst of overshoot.
    constant FB_MAX : natural := (2*BEAT_CH - 2 + MAXCTX*CPR)/BEAT_CH + MAXB;
    signal lim_beat_r : natural range 0 to FB_MAX := 0;
    signal lim_ok_r   : std_logic := '0';
    -- '0' for the one cycle after anything the limit is computed from was
    -- reassigned (run start/end, flush, reset, token start): lim_beat_r then
    -- still holds the PREVIOUS run's limit.  Issue requires it '1'.
    signal lim_fresh  : std_logic := '0';
```
change `signal f_beat  : integer := 0;` to `signal f_beat  : natural range 0 to FB_MAX := 0;` and `signal c_max   : integer := 0;` to `signal c_max   : natural range 0 to MAXCTX := 0;`.

In `P_RD`, in the `rst = '1'` branch add `lim_fresh <= '0'; lim_ok_r <= '0';`. As the first statements of the `else` branch (before `dout := 0;`) add:
```vhdl
          -- The read limit, registered one cycle ahead of its use (block
          -- ratings 2026-09-26: this arithmetic was 28 levels in the issue
          -- cycle, 114.9 MHz on VU33P -2LV).  A limit one cycle old is SAFE:
          -- c_max only grows within a run and cpos_r/run_p0/ph_ch are fixed
          -- in it, so the old limit is never above the true one.  The cycles
          -- where that premise breaks clear lim_fresh below.
          lim_fresh <= '1';
          lim_rec := c_max + RBUF - 2;
          if lim_rec > to_integer(cpos_r) - 1 - to_integer(run_p0) then
            lim_rec := to_integer(cpos_r) - 1 - to_integer(run_p0);
          end if;
          if lim_rec >= 0 then
            lim_ok_r   <= '1';
            lim_beat_r <= (ph_ch + (lim_rec+1)*CPR + BEAT_CH - 1)/BEAT_CH;
          else
            lim_ok_r   <= '0';
          end if;
          if start = '1' then lim_fresh <= '0'; end if;
```
Add `lim_fresh <= '0';` to each of the three branches that reset `c_max` (the flush clear, the end-of-run clear, and the new-run start that assigns `run_p0`/`ph_ch`).

Replace the issue branch (the final `else` of the run state machine, `if arv = '0' and outst + dout < MAXOUT then ... end if;`) with:
```vhdl
            if arv = '0' and outst + dout < MAXOUT
               and lim_fresh = '1' and lim_ok_r = '1' then
              left := lim_beat_r - f_beat;
              if left > 0 then
                n := burst_len(ar_addr, left);
                alen <= n;
                arv  <= '1';
              end if;
              -- The safety argument, checked in simulation on every issue: the
              -- registered limit never exceeds the one this cycle's values give.
              -- pragma translate_off
              lim_rec := c_max + RBUF - 2;
              if lim_rec > to_integer(cpos_r) - 1 - to_integer(run_p0) then
                lim_rec := to_integer(cpos_r) - 1 - to_integer(run_p0);
              end if;
              assert lim_rec >= 0
                     and lim_beat_r <= (ph_ch + (lim_rec+1)*CPR + BEAT_CH - 1)/BEAT_CH
                report "attn_kv_axi: the registered read limit is above the "
                     & "current one; a stale limit would issue past the buffer"
                severity failure;
              -- pragma translate_on
            end if;
```

- [ ] **Step 2: Run the KV, attention and card-sweep benches**

Run: `... --only kv --keep`, `... --only csweep --keep`, `... --only attn --keep` (scratch dirs `/mnt/storage/fk33_builds/fmaxfix/t2_kv`, `t2_cs`, `t2_attn`).
Expected: all PASS. A GHDL range error on `f_beat`/`c_max`/`lim_beat_r` means `FB_MAX` or the `c_max` bound is wrong: fix the DERIVATION, do not widen the range to make it pass.

- [ ] **Step 3: Mutant 1 -- drop the run-boundary clears**

Delete (temporarily) the three `lim_fresh <= '0';` lines added in the run-boundary branches. Run `--only kv` and `--only csweep`.
Expected: at least one FAILs on `the registered read limit is above the current one`. Restore the lines. If NEITHER fails, the benches never restart a run after `c_max` grew: record that as a non-biting mutation in the commit message and add to `sim/kv_axi_harness.vhd`'s stimulus a case that reads head 0 positions 0..MAXCTX-1 in order and then immediately head 1 position 0, then re-run this step.

- [ ] **Step 4: Mutant 2 -- drop the token-start clear**

Delete (temporarily) `if start = '1' then lim_fresh <= '0'; end if;`. Run `--only kv` and `--only csweep`.
Expected: report either result by name. A survivor is recorded as the check's resolution floor (CLAUDE.md: report mutations that do not bite), not deleted. Restore the line.

- [ ] **Step 5: Rate**

```bash
python3 -c "import sys; sys.path.insert(0,'tools/rate'); import calib; calib.set_target('c_kv', 4.25, 'vu35p_jc_m2')"
python3 tools/rate/rate.py run c_kv --device vu35p_jc_m2 --model QWEN35_9B --mem 16G
python3 tools/rate/rate.py run c_kv --device vu33p_fk33 --model QWEN35_9B --mem 16G
```
Expected: >= 217 MHz on `vu35p_jc_m2`, or 200-217 plus a second draw at `target_ns` 4.0 also >= 200 (Task 1 Step 6). The endpoint must no longer be `alen`. If the new worst path is `burst_len` (`ar_addr` -> `to4k` -> `alen`), stop and bring it back to the spec: the next split registers `to4k` from `ar_addr` one cycle ahead, which needs its own safety argument.

- [ ] **Step 6: Commit**

```bash
git add rtl/attn_kv_axi.vhd hw/targets/blocks.json hw/targets/ratings/vu35p_jc_m2/c_kv.QWEN35_9B.json hw/targets/ratings/vu33p_fk33/c_kv.QWEN35_9B.json
git commit -F <msg>   # ratings MEASURED; mutant 1 and mutant 2 results by name
```

---

### Task 3: `sigmoid_q_pipe`, bit-exact to `fixed_pkg.sigmoid_q`

**Files:**
- Modify: `rtl/swiglu_mem.vhd` (new entity ABOVE `entity swiglu_mem`, same file on purpose)
- Create: `sim/tb_sigmoid_q_pipe.vhd`

**Interfaces:**
- Produces: `entity work.sigmoid_q_pipe generic(Q : natural := 12; TAG_W : positive := 1) port(clk, rst : in std_logic; i_v : in std_logic; i_z : in signed(31 downto 0); i_tag : in std_logic_vector(TAG_W-1 downto 0); o_v : out std_logic; o_s : out signed(31 downto 0); o_tag : out std_logic_vector(TAG_W-1 downto 0); busy : out std_logic)`. `o_s = sigmoid_q(i_z, Q)` and `o_tag = i_tag`, exactly 5 edges after `i_v` is sampled; `busy` is '1' while any stage holds a valid.

- [ ] **Step 1: Write the exhaustive bench**

`sim/tb_sigmoid_q_pipe.vhd`:
```vhdl
-- sim/tb_sigmoid_q_pipe.vhd -- 2026-09-26.  rtl/swiglu_mem.vhd's sigmoid_q_pipe
-- against rtl/fixed_pkg.vhd's sigmoid_q, EXHAUSTIVELY over every z in
-- [-17*2^Q, 17*2^Q] (both saturation edges, z = 0 and every SIG_ROM interval),
-- plus the int32 extremes, with a bubble every 7th cycle.  The input z rides
-- the pipe's tag, so every output is checked against its own input and no
-- queue is needed.  The latency (5 edges) and `busy` are checked too.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fixed_pkg.all;

entity tb_sigmoid_q_pipe is
  generic(Q : natural := 12; LAT : positive := 5);
end entity;

architecture sim of tb_sigmoid_q_pipe is
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal i_v, o_v, busy : std_logic := '0';
  signal i_z, o_s : signed(31 downto 0) := (others => '0');
  signal i_tag, o_tag : std_logic_vector(31 downto 0) := (others => '0');
  signal running : boolean := true;
  signal n_in, n_out, n_bad : integer := 0;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.sigmoid_q_pipe
    generic map(Q => Q, TAG_W => 32)
    port map(clk => clk, rst => rst, i_v => i_v, i_z => i_z, i_tag => i_tag,
             o_v => o_v, o_s => o_s, o_tag => o_tag, busy => busy);

  check : process(clk)
    variable want : signed(31 downto 0);
    variable nb, no : integer := 0;      -- counted in VARIABLES (CLAUDE.md)
  begin
    if rising_edge(clk) and o_v = '1' then
      want := sigmoid_q(signed(o_tag), Q);
      no := no + 1;
      if o_s /= want then
        nb := nb + 1;
        if nb <= 10 then
          report "tb_sigmoid_q_pipe: z " & integer'image(to_integer(signed(o_tag)))
               & " got " & integer'image(to_integer(o_s))
               & " want " & integer'image(to_integer(want)) severity error;
        end if;
      end if;
      n_out <= no; n_bad <= nb;
    end if;
  end process;

  stim : process
    variable z, k, sent : integer;
    procedure push(v : integer) is
    begin
      i_v <= '1'; i_z <= to_signed(v, 32); i_tag <= std_logic_vector(to_signed(v, 32));
      wait until rising_edge(clk);
      sent := sent + 1;
    end procedure;
  begin
    sent := 0;
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    -- the latency, measured on one isolated sample
    i_v <= '1'; i_z <= to_signed(0, 32); i_tag <= (others => '0');
    wait until rising_edge(clk);
    i_v <= '0'; sent := 1;
    for c in 1 to LAT loop
      assert o_v = '0' report "tb_sigmoid_q_pipe: o_v early at edge " & integer'image(c) severity error;
      wait until rising_edge(clk);
    end loop;
    assert o_v = '1' report "tb_sigmoid_q_pipe: o_v not LAT edges after i_v" severity error;
    -- the sweep
    k := 0;
    z := -17 * 2**Q;
    while z <= 17 * 2**Q loop
      k := k + 1;
      if k mod 7 = 0 then
        i_v <= '0'; wait until rising_edge(clk);
      end if;
      push(z);
      z := z + 1;
    end loop;
    push(integer'low); push(integer'low + 1); push(integer'high); push(integer'high - 1);
    i_v <= '0';
    for c in 1 to LAT + 2 loop wait until rising_edge(clk); end loop;
    assert busy = '0' report "tb_sigmoid_q_pipe: busy after drain" severity error;
    running <= false;
    if n_bad = 0 and n_out = sent then
      report "tb_sigmoid_q_pipe: PASS -- " & integer'image(n_out) & " samples, bit-exact to sigmoid_q" severity note;
    else
      report "tb_sigmoid_q_pipe: FAIL -- " & integer'image(n_bad) & " wrong, "
           & integer'image(n_out) & " out of " & integer'image(sent) & " sent" severity failure;
    end if;
    wait;
  end process;
end architecture;
```

- [ ] **Step 2: Run it to see it fail**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/fmaxfix/t3_red bash sim/regress.sh --only sigmoid_q_pipe --keep`
Expected: FAIL / BUILD-ERROR naming `sigmoid_q_pipe` (the entity does not exist).

- [ ] **Step 3: Write the pipe**

Insert at the top of `rtl/swiglu_mem.vhd`, after its header comment and before the existing `library` clauses of `swiglu_mem`:
```vhdl
-- ===========================================================================
-- sigmoid_q_pipe -- 2026-09-26.  fixed_pkg.sigmoid_q(z, Q), bit-exact, in five
-- registered stages, one listed operation each (the project timing rule).
-- It lives in THIS file on purpose: nine build and sim lists name
-- swiglu_mem.vhd explicitly (hw/fk33/gen_pcieep.py:1592 among them), and a new
-- file would have to be added to every one.  swiglu_mem ran sigmoid_q in ONE
-- stage: 32 levels, 83.4 MHz on VU33P -2LV (block ratings, 2026-09-26).
--
--   B1  saturation flags; k and frac, which are BIT SLICES of the offset in
--       the non-saturated domain (z in (-16, 16)*2^Q gives offset in
--       (0, 32*2^Q), so k = offset*16 >> Q is in [0, 511] and frac is the low
--       Q bits; the reference's clamps are no-ops there, and saturated
--       inputs never use k or frac)
--   B2  lo = SIG_ROM(k), hi = SIG_ROM(k+1)
--   B3  (hi - lo) * frac, at D_W x (Q+1) bits: one DSP, not a 64x64 cascade
--   B4  lo + (prod >> Q), plus the rounding bias, shifted to Q30 -> Q
--   B5  saturation select and the [0, 1] clamp
-- rtl/attn_gate.vhd stages the same interpolation for C; its OUTPUT stage is
-- deliberately different (Q15, clamped to 32767), so it is not reused here.
-- ===========================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.fixed_luts_pkg.all;

entity sigmoid_q_pipe is
  generic(Q : natural := 12; TAG_W : positive := 1);
  port(
    clk, rst : in  std_logic;
    i_v      : in  std_logic;
    i_z      : in  signed(31 downto 0);
    i_tag    : in  std_logic_vector(TAG_W-1 downto 0);
    o_v      : out std_logic;
    o_s      : out signed(31 downto 0);
    o_tag    : out std_logic_vector(TAG_W-1 downto 0);
    busy     : out std_logic
  );
end entity;

architecture rtl of sigmoid_q_pipe is
  function step_max return natural is
    variable m : natural := 0;
  begin
    for k in 0 to SIG_ROM'high - 1 loop
      if SIG_ROM(k+1) - SIG_ROM(k) > m then m := SIG_ROM(k+1) - SIG_ROM(k); end if;
    end loop;
    return m;
  end function;
  function step_min return integer is
    variable m : integer := integer'high;
  begin
    for k in 0 to SIG_ROM'high - 1 loop
      if SIG_ROM(k+1) - SIG_ROM(k) < m then m := SIG_ROM(k+1) - SIG_ROM(k); end if;
    end loop;
    return m;
  end function;
  -- Vivado ignores asserts in synthesis: out-of-range naturals stop it instead.
  constant CHK_STEP_NONNEG : natural := step_min;          -- table rises
  constant CHK_Q_POS       : natural := Q - 1;             -- frac has >= 1 bit
  constant D_W   : positive := clog2(step_max + 1) + 1;    -- signed step width
  constant HI_Z  : signed(63 downto 0) := shift_left(to_signed(16, 64), Q);
  constant LO_Z  : signed(63 downto 0) := -HI_Z;
  constant ONE_Q : signed(63 downto 0) := shift_left(to_signed(1, 64), Q);

  type tag_t is array (1 to 5) of std_logic_vector(TAG_W-1 downto 0);
  signal v   : std_logic_vector(1 to 5) := (others => '0');
  signal tg  : tag_t := (others => (others => '0'));
  signal lsat1, hsat1, lsat2, hsat2, lsat3, hsat3, lsat4, hsat4 : std_logic := '0';
  signal k1  : natural range 0 to SIG_ROM'high - 1 := 0;
  signal f1, f2 : unsigned(Q-1 downto 0) := (others => '0');
  signal lo2, hi2, lo3 : signed(31 downto 0) := (others => '0');
  signal p3  : signed(D_W + Q downto 0) := (others => '0');
  signal r4  : signed(63 downto 0) := (others => '0');
  signal s5  : signed(31 downto 0) := (others => '0');
begin
  o_v   <= v(5);
  o_s   <= s5;
  o_tag <= tg(5);
  busy  <= '0' when v = "00000" else '1';

  process(clk)
    variable z, off, idx : signed(63 downto 0);
    variable r           : signed(63 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        v <= (others => '0');
      else
        v <= i_v & v(1 to 4);
        tg(1) <= i_tag;
        for i in 2 to 5 loop tg(i) <= tg(i-1); end loop;

        -- B1
        z := resize(i_z, 64);
        if z <= LO_Z then lsat1 <= '1'; else lsat1 <= '0'; end if;
        if z >= HI_Z then hsat1 <= '1'; else hsat1 <= '0'; end if;
        off := z + HI_Z;
        idx := shift_left(off, 4);
        if z <= LO_Z or z >= HI_Z then
          k1 <= 0;
          f1 <= (others => '0');
        else
          k1 <= to_integer(shift_right(idx, Q));
          f1 <= unsigned(idx(Q-1 downto 0));
        end if;

        -- B2
        lo2 <= to_signed(SIG_ROM(k1), 32);
        hi2 <= to_signed(SIG_ROM(k1 + 1), 32);
        f2  <= f1;
        lsat2 <= lsat1; hsat2 <= hsat1;

        -- B3
        p3  <= resize(hi2 - lo2, D_W) * signed('0' & f2);
        lo3 <= lo2;
        lsat3 <= lsat2; hsat3 <= hsat2;

        -- B4: interp = lo + (prod >> Q), then sigmoid_q's rounding to Q
        if Q <= 30 then
          if 30 - Q > 0 then
            r := resize(lo3, 64) + resize(shift_right(p3, Q), 64)
                 + shift_left(to_signed(1, 64), 30 - Q - 1);
            r4 <= shift_right(r, 30 - Q);
          else
            r4 <= resize(lo3, 64) + resize(shift_right(p3, Q), 64);
          end if;
        else
          r4 <= shift_left(resize(lo3, 64) + resize(shift_right(p3, Q), 64), Q - 30);
        end if;
        lsat4 <= lsat3; hsat4 <= hsat3;

        -- B5
        if lsat4 = '1' then
          s5 <= (others => '0');
        elsif hsat4 = '1' then
          s5 <= resize(ONE_Q, 32);
        elsif r4 < 0 then
          s5 <= (others => '0');
        elsif r4 > ONE_Q then
          s5 <= resize(ONE_Q, 32);
        else
          s5 <= resize(r4, 32);
        end if;
      end if;
    end if;
  end process;
end architecture;

```

- [ ] **Step 4: Run the bench, now green**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/fmaxfix/t3_green bash sim/regress.sh --only sigmoid_q_pipe --keep`
Expected: `PASS -- 139270 samples, bit-exact to sigmoid_q` (DERIVED at Q = 12: the sweep is 2*17*4096 + 1 = 139,265 samples, plus the isolated latency sample and the 4 extremes; the bench itself checks the printed count equals `sent`). `OVERALL PASS 1`.

- [ ] **Step 5: Teeth**

Mutant A: in B4 remove the `+ shift_left(to_signed(1, 64), 30 - Q - 1)` bias. Run Step 4. Expected: FAIL with value mismatches. Restore.
Mutant B: in B1 change `z >= HI_Z` to `z > HI_Z` (both occurrences). Run Step 4. Expected: FAIL at z = 16*2^Q. Restore.
Record both results by name.

- [ ] **Step 6: Commit**

```bash
git add rtl/swiglu_mem.vhd sim/tb_sigmoid_q_pipe.vhd
git commit -F <msg>   # exhaustive over [-17,17]*2^Q, mutants A and B killed (or not, by name)
```

---

### Task 4: v_swg -- `swiglu_mem` runs the sigmoid in the pipe

**Files:**
- Modify: `rtl/swiglu_mem.vhd` (architecture of `swiglu_mem`: signals `:262-283`, stage B `:473-480`, `drained` `:499-500`)
- Create: `hw/targets/ratings/vu35p_jc_m2/v_swg.QWEN35_9B.json`, `hw/targets/ratings/vu33p_fk33/v_swg.QWEN35_9B.json` (regenerated)

**Interfaces:**
- Consumes: `sigmoid_q_pipe` from Task 3 (port list above).
- Produces: no port change to `swiglu_mem`; `done` fires 4 cycles later per pass (the pipe is 5 stages where B was 1). The one-edge `o_raddr -> o_rdata` read latency is unchanged.

- [ ] **Step 1: Instantiate the pipe per lane and retire stage B**

In `swiglu_mem`'s architecture add:
```vhdl
  signal sg_v    : std_logic_vector(LANES-1 downto 0);
  signal sg_busy : std_logic_vector(LANES-1 downto 0);
  type tag64a is array(0 to LANES-1) of std_logic_vector(63 downto 0);
  signal sg_ti, sg_to : tag64a;
```
before the main `process(clk)` add:
```vhdl
  -- Stage B, 2026-09-26: sigmoid_q in five stages (sigmoid_q_pipe, above), the
  -- operands riding its tag.  All lanes are driven by the same `va`, so every
  -- lane's valid is lane 0's; b_* are now wires from the pipe's registers.
  gen_sig : for l in 0 to LANES-1 generate
    sg_ti(l) <= std_logic_vector(a_vq(l)) & std_logic_vector(a_hq(l));
    u_sig : entity work.sigmoid_q_pipe
      generic map(Q => Q, TAG_W => 64)
      port map(clk => clk, rst => rst, i_v => va, i_z => a_vq(l), i_tag => sg_ti(l),
               o_v => sg_v(l), o_s => b_sig(l), o_tag => sg_to(l), busy => sg_busy(l));
    b_vq(l) <= signed(sg_to(l)(63 downto 32));
    b_hq(l) <= signed(sg_to(l)(31 downto 0));
  end generate;
  vb <= sg_v(0);
```
In the process delete the stage-B block (`vb <= va;` and the `if va = '1' then ... b_sig/b_vq/b_hq ... end if;`), and delete `vb <= '0'` from the reset list (it is now a wire). Change the declarations of `b_sig, b_vq, b_hq` and `vb` to drop their `:= ...` initialisers if GHDL rejects an initialiser on a signal driven by a concurrent statement (it does not; leave them if it compiles). Change `drained` to:
```vhdl
        drained := (vf = '0' and va = '0' and sg_busy(0) = '0' and vc = '0'
                    and vd = '0');
```

- [ ] **Step 2: Mutant first -- `drained` without the pipe**

Before running the green bench, run the swiglu benches with `sg_busy(0) = '0' and` removed from `drained`:
Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/fmaxfix/t4_mut bash sim/regress.sh --only swiglu --keep`
Expected: FAIL in at least one row (the max pass settles while up to five elements are still in the pipe). A survivor is recorded by name as a non-biting mutation. Restore the term.

- [ ] **Step 3: Run the swiglu benches and the card's swiglu rows**

Run: `... --only swiglu --keep` (scratch `t4_swg`) and `... --only llama_top_swg --keep` (scratch `t4_top`).
Expected: every row PASS (`tb_swiglu_mem`, `tb_swiglu_mem_9b`, `tb_swiglu_mem_w8`, `tb_swiglu_mem_w8_9b`, `tb_swiglu_ps`, `tb_llama_top_swg`, `tb_llama_top_swgw`).

- [ ] **Step 4: Rate**

```bash
python3 -c "import sys; sys.path.insert(0,'tools/rate'); import calib; calib.set_target('v_swg', 4.25, 'vu35p_jc_m2')"
python3 tools/rate/rate.py run v_swg --device vu35p_jc_m2 --model QWEN35_9B --lane bc250
```
Expected: `RATE_RECORD v_swg` (v_swg MEASURED 4.0 GB, so the BC-250 lane). If >= 217 MHz, or 200-217 plus a second draw at `target_ns` 4.0 also >= 200, go to Step 6. Otherwise read the new worst path in `timing_routed.rpt` and go to Step 5 if it ends in `c_silu`/`d_out` (the C or D multiply); if it is in stage A (`a_vq`, `to_qq`), stop and take it back to the spec.

- [ ] **Step 5 (only if Step 4 missed and the path is C or D): split C and D**

Add signals:
```vhdl
  type s64a is array(0 to LANES-1) of signed(63 downto 0);
  signal c_p1, d_p2 : s64a := (others => (others => '0'));
  signal c_hq1 : s32a := (others => (others => '0'));
  signal vc1, vd1 : std_logic := '0';
```
Replace the stage C and D blocks with:
```vhdl
        vc1 <= vb;
        if vb = '1' then
          for l in 0 to LANES-1 loop
            c_p1(l)  <= b_vq(l) * b_sig(l);
            c_hq1(l) <= b_hq(l);
          end loop;
        end if;
        vc <= vc1;
        if vc1 = '1' then
          for l in 0 to LANES-1 loop
            c_silu(l) <= resize(shift_right(c_p1(l), Q), 32);
            c_hq(l)   <= c_hq1(l);
          end loop;
        end if;

        vd1 <= vc;
        if vc = '1' then
          for l in 0 to LANES-1 loop
            d_p2(l) <= c_silu(l) * c_hq(l);
          end loop;
        end if;
        vd <= vd1;
        if vd1 = '1' then
          for l in 0 to LANES-1 loop
            d_out(l) <= resize(shift_right(d_p2(l), Q), 32);
          end loop;
        end if;
```
add `vc1 <= '0'; vd1 <= '0';` to the reset list, and `vc1 = '0' and vd1 = '0'` to `drained`. Re-run Step 3 and Step 4.

- [ ] **Step 6: Rate on the current card part and commit**

```bash
python3 tools/rate/rate.py run v_swg --device vu33p_fk33 --model QWEN35_9B --lane bc250
git add rtl/swiglu_mem.vhd hw/targets/blocks.json hw/targets/ratings/vu35p_jc_m2/v_swg.QWEN35_9B.json hw/targets/ratings/vu33p_fk33/v_swg.QWEN35_9B.json
git commit -F <msg>   # ratings MEASURED, whether C/D were split, the drained mutant's result
```

---

### Task 5: Re-rate everything the changes re-keyed, and close

**Files:**
- Create/modify: `hw/targets/ratings/*/{c_attn,c_attn_levers,c_kv,v_swg}.QWEN35_9B.json`
- Modify: `docs/superpowers/specs/2026-09-26-fmax-limiters-design.md` (append a dated RESULT section)

- [ ] **Step 1: List what is stale**

Run: `python3 tools/rate/rate.py status | grep STALE`
Expected: `c_attn`, `c_attn_levers` (same top), `c_kv`, `v_swg` on the devices not rated in Tasks 1-4 (`vu35p_jc_m1`, `vu35p_jc_m2l`, `vu35p_jc_m3`, and `c_attn_levers` everywhere). Nothing else: a stale row outside these four means a change leaked into another block's dependencies; stop and find it.

- [ ] **Step 2: Re-rate on both lanes**

Workstation (one at a time): every stale `c_attn`, `c_attn_levers`, `c_kv` row, `--mem 16G`. BC-250: every stale `v_swg` row, `--lane bc250`. Use one command per row, e.g. `python3 tools/rate/rate.py run c_attn_levers --device vu35p_jc_m1 --model QWEN35_9B --mem 16G`. A met target (`fmax_is_lower_bound` true) is retargeted with `calib.set_target(row, calib.next_target(target, wns), device)` and re-run.

- [ ] **Step 3: Gate**

Run: `REGRESS_SCRATCH=/mnt/storage/fk33_builds/fmaxfix/t5_gate bash sim/regress.sh --only rate --keep`
Expected: `sim:ratetests` PASS, `sim:ratestale` PASS with `stale 0`.

- [ ] **Step 4: Record the result and commit**

Append to the spec a `## RESULT 2026-09-<dd>` section with the before/after table for the three rows on all five devices (MEASURED), the new slowest block per device, and every mutant's result. Then:
```bash
git add docs/superpowers/specs/2026-09-26-fmax-limiters-design.md hw/targets/blocks.json hw/targets/ratings/
git commit -F <msg>
```
