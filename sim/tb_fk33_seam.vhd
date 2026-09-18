-- sim/tb_fk33_seam.vhd -- SUBSYSTEM D DRIVEN THROUGH THE HOST SEAM ONLY.
-- TRACK DSEAM, 2026-08-30.  The bench for `hw/fk33/rtl/fk33_seam.vhd`.
--
-- ======================================================================
-- THE QUESTION THIS BENCH ANSWERS, AND THE ONE IT DOES NOT
-- ======================================================================
-- ANSWERS: can a whole token run with NOTHING driving `llama_top`'s host
-- face except AXI4-Lite transactions, and does it produce THE SAME NUMBERS
-- as the direct drive that every existing gate row uses?
--
-- DOES NOT ANSWER: whether those numbers are a transformer.  This bench has
-- no arithmetic oracle and claims none.  The value oracle for this stimulus
-- path is `tools/ref9b/seamgate.sh` (rows `sim:seamgate_{real,stub,seq}`),
-- which captures `sim/tb_llama_top.vhd` and compares every modelled step
-- against `bisect_scaled.py` given the machine's own inputs.
--
-- ======================================================================
-- WHY A DIFFERENTIAL BENCH AND NOT A LANDMARK ALONE
-- ======================================================================
-- TWO `llama_top` INSTANCES, IDENTICAL GENERICS, ONE CLOCK.
--
--   `dut_ref`   host face driven by this bench's own processes, in exactly
--               the way `sim/tb_llama_top.vhd` drives it: `go` pulsed for a
--               cycle, `rel_mask` published per step from `PLAN(n_chk).rel`
--               with `n_chk` advanced on `obs_issue`, a descriptor memory
--               model, and the embedding written through `hw_*`.
--   `dut_seam`  host face driven by `fk33_seam` and BY NOTHING ELSE.  This
--               bench never touches its `go`, `tbl_len`, `rel_mask`,
--               `host_x_exp`, `tok_ack`, `d_*` or `hw_*`; it only issues
--               AXI4-Lite reads and writes at the seam.
--
-- THE ORACLE IS THEREFORE THE REFERENCE DRIVE, and the chain is stated
-- explicitly because a differential bench is easy to overclaim:
--
--   (i)  this bench shows seam-driven == directly-driven, exactly, over the
--        whole residual region and over the completion accounting;
--   (ii) directly-driven is the stimulus path `seamgate` judges against an
--        independent stepwise model.
--
-- Neither half is worth much alone.  (i) alone is a round trip against a
-- second copy of the same design.  (ii) alone says nothing about a seam that
-- did not exist when it was measured.  Together they say the seam changed no
-- number, and that the numbers it did not change are the ones an oracle has
-- looked at.
--
-- A LANDMARK IS ALSO PINNED (`EXP_X0`, `EXP_XSUM`), for the reason
-- `sim/tb_llama_top.vhd` pins four: a differential bench passes when BOTH
-- sides move together, and a change to `llama_top` moves both.  The landmark
-- is a CHANGE DETECTOR with a recorded reference point, never an oracle.
-- When it legitimately moves, say why in the commit message and record the
-- old and the new value.
--
-- ======================================================================
-- WHY `ref/run9b` IS NOT THE ORACLE HERE, AND THE BRIEF THAT ASKED FOR IT
-- ======================================================================
-- The dispatch brief for this track asked for "a bench that runs D through a
-- whole layer with no host, comparing against `ref/run9b`'s stream".  THE
-- SECOND HALF OF THAT IS NOT REACHABLE AND THE CORRECTION IS THE SAME ONE
-- TRACK BISECT ALREADY MADE AND RECORDED: `ref/run9b` is the Qwen3.5-9B
-- model -- hidden 4096, ffn 12288, 32 blocks -- and a GHDL run of this design
-- at that shape is ~35,650x the arithmetic of the scaled shape, which
-- `docs/WORKLOG.md` records as about fifteen days per token.  Every published
-- landmark in this family is at `mk_shape_scaled`, and `ref/run9b` has no
-- scaled mode.  The oracle that DOES exist at this shape is the stepwise one
-- (`tools/ref9b/bisect_scaled.py`), reached through `seamgate.sh`, and that
-- is the one named above.
--
-- `hw/fk33/host/fk33_run_token.py` remains the oracle for the CARD, at the
-- 9B shape, and it is bit-exact against `ref/run9b` over 1,675,264 rows.  It
-- is read-only to this track and nothing here replaces it.  What this bench
-- cannot do and that tool can is run on silicon; what that tool cannot do and
-- this bench can is run subsystems B, C and D at all.
--
-- ======================================================================
-- WHAT A FAILURE MEANS
-- ======================================================================
-- P1  the two DUTs disagree on any element of R_X            -> the seam
--     changed a number.
-- P2  the two disagree on `steps_done`, `err` or `err_code`  -> the seam
--     changed the completion accounting.  `steps_done` must equal the table
--     length at a clean completion; that is `seq_desc_fetch`'s own counting
--     identity and it is what named the head-emit defect.
-- P3  the seam's own STATUS never reaches (done | err)       -> a poller
--     would hang.  Held to a bounded wait deliberately: `fk33_seam.h` says
--     a done-only poller hangs forever and this bench must not be one.
-- P4  the seam's ARGMAX/STEPS_DONE registers disagree with the DUT's own
--     outputs                                                -> readback is
--     reporting something other than what happened.
-- P5  the landmark moved.
-- P6  the seam accepted a GO it should have refused, or refused one it
--     should have accepted (the GO-time checks: N_STEP, TBL_LEN, the
--     reserved HBM pointers, SEQ_POS).
--
-- Teeth: `sim/mutate_fk33_seam.sh`.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;
use work.llama_sched_pkg.all;
use work.util_pkg.all;          -- clog2, for the seam's slv port widths

entity tb_fk33_seam is
  generic(
    -- Two blocks is the smallest shape that runs a residual through a second
    -- block, which is what makes a stale rel index or a stale descriptor
    -- visible at all.  ATTN_INT 4 with BLOCKS 2 means every block is a GDN
    -- block, so subsystem C's stub never runs and `err_unit_stub` stays low.
    BLOCKS   : positive := 2;
    ATTN_INT : positive := 4;
    ATTN_HD  : positive := 32;
    -- The behavioural subsystem A.  DELIBERATE, and the reason is scope, not
    -- convenience: the real `matvec_int4` needs the 25-port synthetic weight
    -- memory model `sim/tb_llama_top.vhd` carries, and a second copy of that
    -- model here would be a second thing to keep in step for no additional
    -- question answered.  What this bench asks is whether the SEAM moves a
    -- number, and a behavioural A produces a data-dependent stream that a
    -- moved number still perturbs.  MEASURED in the teeth table.
    A_BEHAV  : boolean := true;
    -- TWO TOKENS, AND THE SECOND ONE IS NOT MARGIN.  MEASURED: at NTOK = 1
    -- mutation M9 -- `tok_ack` never raised, so D holds `tok_done` forever --
    -- SURVIVED every property this bench has.  Nothing in a one-token run
    -- ever asks D to start again, so an unacknowledged completion is
    -- invisible.  The same lesson `sim/tb_llama_top.vhd` recorded when NTOK
    -- was added there: "a bench that cannot tell an N-token sequence from N
    -- one-token runs has not tested a sequence".
    NTOK     : positive := 2;
    -- THE LANDMARK.  MEASURED 2026-08-30 by TRACK DSEAM on an unmutated
    -- tree at the generics above, GHDL 1.0.0 mcode, 27 s:
    --     tb_fk33_seam: R_X(0) = -17280 hash(R_X) = 53529 (seam hash 53529)
    -- Both DUTs produced the same pair, which is P1; the pair is pinned here
    -- so this row can ALSO fail on a change to `llama_top` that moves both
    -- sides together, which P1 cannot see by construction.
    --
    -- IT IS NOT COMPARABLE WITH `sim/tb_llama_top.vhd`'s EXP_X0/EXP_XSUM.
    -- Same hash function, DIFFERENT configuration -- BLOCKS 2 against 4, and
    -- the behavioural subsystem A against the real one -- so the numbers are
    -- at a different shape and a different datapath.  Comparing them would
    -- be the trap that family's own header warns about.
    --
    -- `integer'low` / -1 mean "not gated on values" and the PASS line says so
    -- rather than staying quiet about it; they are for manual runs at shapes
    -- nobody has recorded a landmark for.
    EXP_X0   : integer := -17280;
    EXP_XSUM : integer := 53529;
    MAXCYC   : natural := 2000000
  );
end entity;

architecture tb of tb_fk33_seam is

  constant SHAPE  : shape_t := mk_shape_scaled(BLOCKS, ATTN_INT, ATTN_HD);
  constant NSTEP  : natural := n_steps(SHAPE);
  constant TBL    : sched_tbl_t := build_table(SHAPE);
  constant PLAN   : plan_t := build_plan(SHAPE);
  constant REGMAX : positive := region_max(SHAPE);

  constant MANT_W : positive := 16;
  constant EXP_W  : positive := 16;
  constant STEP_W : positive := 11;
  constant X_EXP0 : integer  := 3;

  constant CLK_HALF : time := 0.5 ns;

  signal clk : std_logic := '0';
  -- TWO RESETS, AND THE SPLIT IS NOT COSMETIC.  `rst` is the seam's, which
  -- lives in the always-on PCIe domain; `drst` is the compute domain's, and
  -- the card really does have two (commit 2d07c3c: the HBM slave's reset is
  -- the SOURCE of the engine's).  Holding the two DUTs in reset while the
  -- program is written also stops a few hundred thousand NUMERIC_STD
  -- metavalue warnings from an idle design churning on uninitialised
  -- regions -- MEASURED, 273,150 lines and a 36 MB log on the first run,
  -- which a gate row that reads every line pays for.
  signal rst  : std_logic := '1';
  signal drst : std_logic := '1';
  signal running : boolean := true;
  signal cyc : natural := 0;

  -- ===================== the reference DUT's host face ==================
  signal r_go, r_abort, r_tok_ack : std_logic := '0';
  signal r_tbl_len : unsigned(STEP_W-1 downto 0)
                   := to_unsigned(NSTEP, STEP_W);
  signal r_x_exp   : signed(EXP_W-1 downto 0) := to_signed(X_EXP0, EXP_W);
  signal r_rel     : std_logic_vector(NREGION-1 downto 0) := (others => '0');
  signal r_busy, r_tok_done, r_err : std_logic;
  signal r_err_code : std_logic_vector(3 downto 0);
  signal r_err_step, r_steps_done : unsigned(STEP_W-1 downto 0);
  signal r_draddr : unsigned(15 downto 0);
  signal r_dren, r_drvalid : std_logic := '0';
  signal r_drdata : std_logic_vector(63 downto 0) := (others => '0');
  signal r_hw_we : std_logic := '0';
  signal r_hw_reg : natural range 0 to NREGION-1 := 0;
  signal r_hw_addr : natural range 0 to REGMAX-1 := 0;
  signal r_hw_data : signed(MANT_W-1 downto 0) := (others => '0');
  signal r_hr_reg : natural range 0 to NREGION-1 := 0;
  signal r_hr_addr : natural range 0 to REGMAX-1 := 0;
  signal r_hr_data : signed(MANT_W-1 downto 0);
  signal r_obs_issue : std_logic;
  signal r_n_chk : natural := 0;

  -- ===================== the seam DUT's host face =======================
  -- EVERY ONE OF THESE IS DRIVEN BY `fk33_seam` AND BY NOTHING ELSE.
  signal s_go, s_abort, s_tok_ack : std_logic;
  signal s_tbl_len : unsigned(STEP_W-1 downto 0);
  signal s_x_exp   : signed(EXP_W-1 downto 0);
  signal s_rel     : std_logic_vector(NREGION-1 downto 0);
  signal s_busy, s_tok_done, s_err : std_logic;
  signal s_err_code : std_logic_vector(3 downto 0);
  signal s_err_step, s_steps_done : unsigned(STEP_W-1 downto 0);
  signal s_draddr : unsigned(15 downto 0);
  signal s_dren, s_drvalid : std_logic;
  signal s_drdata : std_logic_vector(63 downto 0);
  signal s_hw_we : std_logic;
  signal s_hw_reg : natural range 0 to NREGION-1;
  signal s_hw_addr : natural range 0 to REGMAX-1;
  signal s_hw_data : signed(MANT_W-1 downto 0);
  signal s_hr_reg : natural range 0 to NREGION-1;
  signal s_hr_addr : natural range 0 to REGMAX-1;

  -- `fk33_seam`'s four region-access ports became std_logic_vector on
  -- 2026-09-03 because Vivado's block-design module inference REFUSES a
  -- `natural` port and no bitstream could be built with them
  -- (docs/debugging/2026-09-03_pcieep-build-two-blockers.md).  `llama_top`'s
  -- matching ports are still `natural`, so the conversion lives here rather
  -- than changing a second entity's face for a BD constraint that applies
  -- only to the seam.
  signal sv_hw_reg  : std_logic_vector(clog2(NREGION)-1 downto 0);
  signal sv_hw_addr : std_logic_vector(clog2(REGMAX)-1 downto 0);
  signal sv_hr_reg  : std_logic_vector(clog2(NREGION)-1 downto 0);
  signal sv_hr_addr : std_logic_vector(clog2(REGMAX)-1 downto 0);
  signal s_hr_data : signed(MANT_W-1 downto 0);
  signal s_obs_issue : std_logic;
  signal s_obs_tok_pos : unsigned(15 downto 0);
  signal s_smp_token, s_smp_n : unsigned(31 downto 0);
  signal s_smp_exp : signed(EXP_W-1 downto 0);
  signal s_f_ovf, s_f_lost, s_f_gate, s_f_stub, s_f_ecoll, s_f_kv : std_logic;

  -- ============================== AXI4-Lite =============================
  signal ax_awvalid : std_logic := '0';
  signal ax_awready : std_logic;
  signal ax_awaddr  : std_logic_vector(11 downto 0) := (others => '0');
  signal ax_wvalid  : std_logic := '0';
  signal ax_wready  : std_logic;
  signal ax_wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal ax_bvalid  : std_logic;
  signal ax_bready  : std_logic := '0';
  signal ax_bresp   : std_logic_vector(1 downto 0);
  signal ax_arvalid : std_logic := '0';
  signal ax_arready : std_logic;
  signal ax_araddr  : std_logic_vector(11 downto 0) := (others => '0');
  signal ax_rvalid  : std_logic;
  signal ax_rready  : std_logic := '0';
  signal ax_rdata   : std_logic_vector(31 downto 0);
  signal ax_rresp   : std_logic_vector(1 downto 0);

  -- =============================== verdict ==============================
  signal n_bad_val   : natural := 0;   -- P1
  signal n_bad_acct  : natural := 0;   -- P2
  signal n_bad_poll  : natural := 0;   -- P3
  signal n_bad_rback : natural := 0;   -- P4
  signal n_bad_land  : natural := 0;   -- P5
  signal n_bad_gate  : natural := 0;   -- P6
  signal done_flag   : boolean := false;

  -- register offsets, the same numbers `server/fk33_seam.h` defines
  constant A_ID       : natural := 16#00#;
  constant A_VERSION  : natural := 16#04#;
  constant A_CTRL     : natural := 16#14#;
  constant A_STATUS   : natural := 16#18#;
  constant A_ERR_INFO : natural := 16#1C#;
  constant A_SEQ_POS  : natural := 16#20#;
  constant A_N_STEP   : natural := 16#24#;
  constant A_XB_LO    : natural := 16#28#;
  constant A_ARGMAX   : natural := 16#44#;
  constant A_CAPS_FL  : natural := 16#4C#;
  constant A_TBL_LEN  : natural := 16#50#;
  constant A_X_EXP    : natural := 16#54#;
  constant A_WIN_SEL  : natural := 16#58#;
  constant A_WIN_ADDR : natural := 16#5C#;
  constant A_WIN_DATA : natural := 16#60#;

  function embed(i : natural) return integer is
  begin
    return ((i * 37) mod 251) - 125;
  end function;

  -- The positional hash `sim/tb_llama_top.vhd` publishes, same modulus, so
  -- the two families' numbers are comparable by eye when the shapes match.
  function hash_of(v : integer; acc : natural; i : natural) return natural is
  begin
    return (acc + ((v + 32768) * (i + 1))) mod 100003;
  end function;

begin

  clk <= not clk after CLK_HALF when running else '0';

  ticker : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      if cyc > MAXCYC then
        report "tb_fk33_seam: cycle cap " & integer'image(MAXCYC)
             & " reached." severity failure;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE REFERENCE DUT.  Driven exactly as sim/tb_llama_top.vhd drives it.
  -- ======================================================================
  dut_ref : entity work.llama_top
    generic map(SHAPE => SHAPE, A_BEHAV => A_BEHAV, NORM_ANCHOR => true,
                C_MAXPOS => 4, MANT_W => MANT_W, EXP_W => EXP_W,
                STEP_W => STEP_W)
    port map(
      clk => clk, rst => drst,
      go => r_go, abort => r_abort, tbl_len => r_tbl_len,
      host_x_exp => r_x_exp, rel_mask => r_rel, tok_ack => r_tok_ack,
      busy => r_busy, tok_done => r_tok_done, err => r_err,
      err_code => r_err_code, err_step => r_err_step,
      steps_done => r_steps_done,
      d_raddr => r_draddr, d_ren => r_dren, d_rdata => r_drdata,
      d_rvalid => r_drvalid,
      hw_we => r_hw_we, hw_reg => r_hw_reg, hw_addr => r_hw_addr,
      hw_data => r_hw_data,
      hr_reg => r_hr_reg, hr_addr => r_hr_addr, hr_data => r_hr_data,
      obs_issue => r_obs_issue);

  -- The reference's descriptor memory, at one clocked state of latency, so
  -- it matches the seam's RAM and a difference cannot be a memory-timing
  -- artefact.  The SWEEP over latency belongs to `tb_llama_top`, which has
  -- it; duplicating it here would double a long run for no new question.
  refmem : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      r_drvalid <= '0';
      if drst = '1' then
        r_drvalid <= '0';
      elsif r_dren = '1' then
        a := to_integer(r_draddr);
        if a < NSTEP*8 then
          r_drdata <= TBL(a);
        else
          r_drdata <= (others => '0');
        end if;
        r_drvalid <= '1';
      end if;
    end if;
  end process;

  -- The reference's release mask, `sim/tb_llama_top.vhd:1923` verbatim.
  r_rel <= PLAN(r_n_chk).rel when r_n_chk < NSTEP else (others => '0');

  refchk : process(clk) is
  begin
    if rising_edge(clk) then
      if drst = '1' or r_go = '1' then
        r_n_chk <= 0;
      elsif r_obs_issue = '1' and r_n_chk < SCHED_MAX_STEPS-1 then
        r_n_chk <= r_n_chk + 1;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE SEAM DUT.  Its whole host face comes from `fk33_seam`.
  -- ======================================================================
  dut_seam : entity work.llama_top
    generic map(SHAPE => SHAPE, A_BEHAV => A_BEHAV, NORM_ANCHOR => true,
                C_MAXPOS => 4, MANT_W => MANT_W, EXP_W => EXP_W,
                STEP_W => STEP_W)
    port map(
      clk => clk, rst => drst,
      go => s_go, abort => s_abort, tbl_len => s_tbl_len,
      host_x_exp => s_x_exp, rel_mask => s_rel, tok_ack => s_tok_ack,
      busy => s_busy, tok_done => s_tok_done, err => s_err,
      err_code => s_err_code, err_step => s_err_step,
      steps_done => s_steps_done,
      d_raddr => s_draddr, d_ren => s_dren, d_rdata => s_drdata,
      d_rvalid => s_drvalid,
      hw_we => s_hw_we, hw_reg => s_hw_reg, hw_addr => s_hw_addr,
      hw_data => s_hw_data,
      hr_reg => s_hr_reg, hr_addr => s_hr_addr, hr_data => s_hr_data,
      obs_tok_pos => s_obs_tok_pos,
      obs_issue => s_obs_issue,
      smp_token => s_smp_token, smp_n => s_smp_n, smp_exp => s_smp_exp,
      kv_err => s_f_kv,
      err_smp_ovf => s_f_ovf, err_lost_beat => s_f_lost,
      err_gate_drop => s_f_gate, err_unit_stub => s_f_stub,
      err_e_coll => s_f_ecoll);

  s_hw_reg  <= to_integer(unsigned(sv_hw_reg));
  s_hw_addr <= to_integer(unsigned(sv_hw_addr));
  s_hr_reg  <= to_integer(unsigned(sv_hr_reg));
  s_hr_addr <= to_integer(unsigned(sv_hr_addr));

  seam : entity work.fk33_seam
    generic map(NREG => NREGION, REGMAX => REGMAX, XREG => R_X,
                -- MUST match, and fk33_seam REFUSES them if they do not: the
                -- widths are generics rather than clog2 calls because Vivado's
                -- IP packager cannot evaluate a function in a port width.
                HREG_W => clog2(NREGION), HADDR_W => clog2(REGMAX),
                STEP_W => STEP_W, EXP_W => EXP_W, MANT_W => MANT_W,
                DESC_WORDS => SCHED_MAX_WORDS, REL_ENT => SCHED_MAX_STEPS,
                CAPS_VOCAB => SHAPE.vocab_shard, CAPS_EMBD => SHAPE.hidden,
                CAPS_LAYER => SHAPE.blocks, CAPS_CTX => 4,
                MAXPOS => 4, STRICT => true)
    port map(
      clk => clk, rst => rst,
      s_axi_awvalid => ax_awvalid, s_axi_awready => ax_awready,
      s_axi_awaddr => ax_awaddr,
      s_axi_wvalid => ax_wvalid, s_axi_wready => ax_wready,
      s_axi_wdata => ax_wdata,
      s_axi_bvalid => ax_bvalid, s_axi_bready => ax_bready,
      s_axi_bresp => ax_bresp,
      s_axi_arvalid => ax_arvalid, s_axi_arready => ax_arready,
      s_axi_araddr => ax_araddr,
      s_axi_rvalid => ax_rvalid, s_axi_rready => ax_rready,
      s_axi_rdata => ax_rdata, s_axi_rresp => ax_rresp,
      d_go => s_go, d_abort => s_abort, d_tbl_len => s_tbl_len,
      d_host_x_exp => s_x_exp, d_rel_mask => s_rel, d_tok_ack => s_tok_ack,
      d_busy => s_busy, d_tok_done => s_tok_done, d_err => s_err,
      d_err_code => s_err_code, d_err_step => s_err_step,
      d_steps_done => s_steps_done,
      d_raddr => s_draddr, d_ren => s_dren, d_rdata => s_drdata,
      d_rvalid => s_drvalid,
      hw_we => s_hw_we, hw_reg => sv_hw_reg, hw_addr => sv_hw_addr,
      hw_data => s_hw_data,
      hr_reg => sv_hr_reg, hr_addr => sv_hr_addr, hr_data => s_hr_data,
      obs_issue => s_obs_issue, obs_tok_pos => s_obs_tok_pos,
      smp_token => s_smp_token, smp_n => s_smp_n, smp_exp => s_smp_exp,
      f_smp_ovf => s_f_ovf, f_lost_beat => s_f_lost,
      f_gate_drop => s_f_gate, f_unit_stub => s_f_stub,
      f_e_coll => s_f_ecoll, f_kv_err => s_f_kv);

  -- ======================================================================
  -- THE STIMULUS.  One process, so the AXI master has a single driver.
  -- ======================================================================
  stim : process is

    procedure tick(n : natural) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure axi_w(off : natural; d : std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      ax_awaddr  <= std_logic_vector(to_unsigned(off, 12));
      ax_awvalid <= '1';
      ax_wdata   <= d;
      ax_wvalid  <= '1';
      ax_bready  <= '1';
      -- Both channels are accepted independently; hold each until its own
      -- ready.  Deliberately NOT "wait for both": an AXI master that assumes
      -- the two handshake together works against a slave that happens to do
      -- so and fails against one that does not.
      loop
        wait until rising_edge(clk);
        if ax_awready = '1' then ax_awvalid <= '0'; end if;
        if ax_wready  = '1' then ax_wvalid  <= '0'; end if;
        exit when ax_bvalid = '1';
      end loop;
      wait until rising_edge(clk);
      ax_awvalid <= '0';
      ax_wvalid  <= '0';
      ax_bready  <= '0';
    end procedure;

    procedure axi_wi(off : natural; v : integer) is
    begin
      axi_w(off, std_logic_vector(to_signed(v, 32)));
    end procedure;

    procedure axi_r(off : natural; d : out std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      ax_araddr  <= std_logic_vector(to_unsigned(off, 12));
      ax_arvalid <= '1';
      ax_rready  <= '1';
      loop
        wait until rising_edge(clk);
        if ax_arready = '1' then ax_arvalid <= '0'; end if;
        exit when ax_rvalid = '1';
      end loop;
      d := ax_rdata;
      wait until rising_edge(clk);
      ax_arvalid <= '0';
      ax_rready  <= '0';
    end procedure;

    procedure axi_ri(off : natural; v : out integer) is
      variable d : std_logic_vector(31 downto 0);
    begin
      axi_r(off, d);
      v := to_integer(signed(d));
    end procedure;

    -- ---- the reference DUT's own preload, hw_* directly ---------------
    procedure ref_preload is
    begin
      for i in 0 to SHAPE.hidden-1 loop
        wait until rising_edge(clk);
        r_hw_we   <= '1';
        r_hw_reg  <= R_X;
        r_hw_addr <= i;
        r_hw_data <= to_signed(embed(i), MANT_W);
      end loop;
      wait until rising_edge(clk);
      r_hw_we <= '0';
    end procedure;

    variable d      : std_logic_vector(31 downto 0);
    -- P5's counter.  A VARIABLE, not a signal: two `chk`-style increments in
    -- one delta collapse to a single signal assignment, and a bench that
    -- reports fewer checks than it ran passes while measuring nothing.
    variable bad_d  : natural := 0;
    variable iv     : integer;
    variable st     : integer;
    variable rx_ref : integer;
    variable rx_sea : integer;
    variable h_ref  : natural := 0;
    variable h_sea  : natural := 0;
    variable h0_ref : natural := 0;
    variable xt0    : integer := 0;
    variable nwait  : natural;
    variable x0     : integer := 0;
    variable nfail  : natural;
  begin
    report "tb_fk33_seam: shape blocks=" & integer'image(SHAPE.blocks)
         & " hidden=" & integer'image(SHAPE.hidden)
         & " ffn=" & integer'image(SHAPE.ffn)
         & " -> " & integer'image(NSTEP) & " descriptors, regmax "
         & integer'image(REGMAX) severity note;

    rst  <= '1';
    drst <= '1';
    tick(10);
    rst  <= '0';
    tick(2);

    -- ==================================================================
    -- IDENTITY.  A host that cannot read the magic is talking to the wrong
    -- block, and every later failure would be reported as an engine fault.
    -- ==================================================================
    axi_r(A_ID, d);
    assert d = x"4C4C4D32"
      report "tb_fk33_seam: ID reads " & integer'image(to_integer(unsigned(d)))
           & ", expected 0x4C4C4D32." severity error;
    if d /= x"4C4C4D32" then n_bad_rback <= n_bad_rback + 1; end if;
    axi_ri(A_VERSION, iv);
    assert iv = 2
      report "tb_fk33_seam: VERSION reads " & integer'image(iv)
           & ", expected 2." severity error;
    if iv /= 2 then n_bad_rback <= n_bad_rback + 1; end if;
    axi_ri(A_CAPS_FL, iv);
    -- 13 = bits 0, 2 and 3.  This row previously demanded 1, with the standing
    -- instruction: "if this ever reads 5 again, either the sampler was really
    -- built or the advertisement went back to lying; find out which before
    -- editing this."  ANSWERED 2026-09-17: THE SAMPLER WAS REALLY BUILT.
    --   * hw/fk33/gen_fk33_card.py now passes SMP_EN=true
    --   * Vivado synthesised it: `sampler_stream` appears in the card's OOC
    --     run at 204 LUT, and the whole card moved 209,814 -> 210,145 LUT and
    --     160,847 -> 162,756 FF, i.e. +331 LUT and +1,909 FF
    --   * the logits egress that bit 3 names is the same `gsmp` block; with
    --     SMP_EN false `gsmptie` ties the entire stream off, so both bits
    --     stand or fall together and tools/check_seam_regs.py grades them as
    --     one pair against gen_fk33_card.py's SMP_EN
    -- Bit 1 (HBM pointer fetch) stays 0 and that is still the honest report:
    -- the seam has no HBM master, and the v3 pointer registers refuse a
    -- non-zero write with FK33_SEAM_ERR_RSVD.
    --
    -- THIS NUMBER IS DUPLICATED KNOWLEDGE and the duplicate is deliberate: the
    -- constant lives in rtl/fk33_seam.vhd's architecture where a bench cannot
    -- read it.  What stops the two drifting is tools/check_seam_regs.py, which
    -- derives its expectation from the CARD's generic rather than from either
    -- copy.  If this row and that checker ever disagree, the checker wins.
    assert iv = 13
      report "tb_fk33_seam: CAPS_FLAGS reads " & integer'image(iv)
           & ", expected 13 (windows + sampler + logits; no HBM fetch)." severity error;
    if iv /= 13 then n_bad_rback <= n_bad_rback + 1; end if;

    -- ==================================================================
    -- P6a: A GO BEFORE ANYTHING IS PROGRAMMED MUST BE REFUSED, and it must
    -- be refused with the RIGHT code.  A seam that accepts an empty program
    -- and then reports a D fault has moved the blame one level down.
    -- ==================================================================
    axi_wi(A_CTRL, 1);
    axi_r(A_STATUS, d);
    if d(2) /= '1' or to_integer(unsigned(d(11 downto 8))) /= 2 then
      n_bad_gate <= n_bad_gate + 1;
      report "tb_fk33_seam: GO with TBL_LEN = 0 was not refused with "
           & "FK33_SEAM_ERR_NSTEP; STATUS = "
           & integer'image(to_integer(unsigned(d))) severity error;
    end if;
    if d(0) = '1' then
      n_bad_gate <= n_bad_gate + 1;
      report "tb_fk33_seam: DONE is set on a REFUSED go.  fk33_seam.h: on "
           & "any error done is never set." severity error;
    end if;
    axi_wi(A_CTRL, 32);          -- CLR_ERR

    -- ==================================================================
    -- PROGRAM THE CARD.  Descriptor table and release table: ONCE.
    -- ==================================================================
    axi_wi(A_WIN_SEL, 0);
    axi_wi(A_WIN_ADDR, 0);
    for w in 0 to NSTEP*8-1 loop
      axi_w(A_WIN_DATA, TBL(w)(31 downto 0));
      axi_w(A_WIN_DATA, TBL(w)(63 downto 32));
    end loop;

    -- ==================================================================
    -- P5: THE DESCRIPTOR WINDOW READS BACK WHAT WAS WRITTEN.
    --
    -- WHY IT EXISTS.  MEASURED 2026-09-16: `desc_ram` was moved to block RAM
    -- to reclaim 9,468 LUT, which required registering the host readback into
    -- `desc_q` one state earlier (the read channel already spends an idle
    -- cycle at `rd_wait = 1`, so this costs no AXI latency).  That is a REAL
    -- behavioural change to this path -- and this bench PASSED across it
    -- unchanged, because P1 reads back only through the XOUT window and
    -- NOTHING here had ever read the DESC window at all.
    --
    -- A green bench across a real change means the change is untested.  This
    -- is the case that distinguishes the two versions.
    --
    -- IT IS ALSO A HAZARD CHECK, not just a data check.  `WIN_ADDR`
    -- auto-increments on every WIN_DATA access, READ INCLUDED, so a readback
    -- that captured its word one state early would be reading against a
    -- moving address if the increment happened before `rd_wait = 2`.  It does
    -- not -- the increment is in the `rd_wait = 2` block -- and streaming the
    -- whole window back in order is what would catch it if that ever changed.
    -- ==================================================================
    axi_wi(A_WIN_SEL, 0);
    axi_wi(A_WIN_ADDR, 0);
    bad_d := 0;
    for w in 0 to NSTEP*8-1 loop
      axi_r(A_WIN_DATA, d);
      if d /= TBL(w)(31 downto 0) then bad_d := bad_d + 1; end if;
      axi_r(A_WIN_DATA, d);
      if d /= TBL(w)(63 downto 32) then bad_d := bad_d + 1; end if;
    end loop;
    n_bad_rback <= n_bad_rback + bad_d;
    report "tb_fk33_seam: P5 descriptor-window readback, "
         & integer'image(NSTEP*8*2) & " words checked, "
         & integer'image(bad_d) & " wrong" severity note;

    axi_wi(A_WIN_SEL, 1);
    axi_wi(A_WIN_ADDR, 0);
    for s in 0 to NSTEP-1 loop
      d := (others => '0');
      d(NREGION-1 downto 0) := PLAN(s).rel;
      axi_w(A_WIN_DATA, d);
    end loop;

    axi_wi(A_TBL_LEN, NSTEP);
    axi_wi(A_N_STEP, 1);
    axi_wi(A_X_EXP, X_EXP0);
    axi_wi(A_SEQ_POS, 0);

    -- ---- READ THE PROGRAM BACK.  This is a ROUND TRIP AND NOTHING MORE,
    -- ---- and it is here only to separate "the bus is broken" from "the
    -- ---- machine computed the wrong thing" when both would look alike.
    -- ---- It proves the window works; it proves nothing about D.
    axi_wi(A_WIN_SEL, 0);
    axi_wi(A_WIN_ADDR, 0);
    axi_r(A_WIN_DATA, d);
    if d /= TBL(0)(31 downto 0) then
      n_bad_rback <= n_bad_rback + 1;
      report "tb_fk33_seam: descriptor word 0 low half did not read back."
        severity error;
    end if;

    -- ==================================================================
    -- P6b: THE RESERVED HBM POINTERS MUST REFUSE A GO.  v2 has no HBM
    -- master; a host that hands one over and gets a token back was lied to.
    -- ==================================================================
    axi_wi(A_XB_LO, 64);
    axi_wi(A_CTRL, 1);
    axi_r(A_STATUS, d);
    if d(2) /= '1' or to_integer(unsigned(d(11 downto 8))) /= 5 then
      n_bad_gate <= n_bad_gate + 1;
      report "tb_fk33_seam: a non-zero X_BASE did not raise "
           & "FK33_SEAM_ERR_RSVD; STATUS = "
           & integer'image(to_integer(unsigned(d))) severity error;
    end if;
    axi_wi(A_XB_LO, 0);
    axi_wi(A_CTRL, 32);

    -- ==================================================================
    -- P6c: A SEQ_POS THAT IS NOT THE CARD'S NEXT POSITION MUST REFUSE.
    -- A host that loses count would otherwise attend over the wrong
    -- history and get a plausible wrong token.
    -- ==================================================================
    axi_wi(A_SEQ_POS, 1);
    axi_wi(A_CTRL, 1);
    axi_r(A_STATUS, d);
    if d(2) /= '1' or to_integer(unsigned(d(11 downto 8))) /= 8 then
      n_bad_gate <= n_bad_gate + 1;
      report "tb_fk33_seam: SEQ_POS = 1 at card position 0 did not raise "
           & "FK33_SEAM_ERR_SEQ; STATUS = "
           & integer'image(to_integer(unsigned(d))) severity error;
    end if;
    axi_wi(A_SEQ_POS, 0);
    axi_wi(A_CTRL, 32);

    -- ==================================================================
    -- THE COMPUTE DOMAIN LEAVES RESET.  Everything above is the seam's own
    -- register file and its two RAMs, none of which the engine can see.
    -- ==================================================================
    drst <= '1';
    tick(4);
    drst <= '0';
    tick(4);

    -- ==================================================================
    -- THE TOKEN LOOP.  Everything above happens ONCE PER MODEL; everything
    -- below happens once per position, on both DUTs, and the seam side is
    -- reached only through AXI4-Lite.
    -- ==================================================================
    for t in 0 to NTOK-1 loop

    -- ==================================================================
    -- THE ACTIVATION.  Once per token, through the X window.
    -- THE SAME ROW EVERY TOKEN, on purpose: with identical input, any
    -- difference between token 0's R_X and token t's is cross-token state
    -- and nothing else.
    -- ==================================================================
    axi_wi(A_SEQ_POS, t);
    axi_wi(A_WIN_SEL, 2);
    axi_wi(A_WIN_ADDR, 0);
    for i in 0 to SHAPE.hidden-1 loop
      axi_wi(A_WIN_DATA, embed(i));
    end loop;

    -- The reference gets the same row, written the old way.
    ref_preload;
    r_tbl_len <= to_unsigned(NSTEP, STEP_W);
    r_x_exp   <= to_signed(X_EXP0, EXP_W);
    tick(2);

    -- ==================================================================
    -- GO.  BOTH.  The reference's `go` is a bench pulse; the seam DUT's is
    -- CTRL bit 0 and this process never touches `s_go`.
    -- ==================================================================
    wait until rising_edge(clk);
    r_go <= '1';
    wait until rising_edge(clk);
    r_go <= '0';

    axi_wi(A_CTRL, 1);

    -- ==================================================================
    -- P3: POLL (done | err), NEVER done alone.
    -- ==================================================================
    nwait := 0;
    st := 0;
    loop
      axi_r(A_STATUS, d);
      st := to_integer(unsigned(d));
      exit when d(0) = '1' or d(2) = '1';
      nwait := nwait + 1;
      -- THE CAP IS 20,000 AND IT IS CHOSEN FROM MEASUREMENT, not from
      -- caution.  A clean token here takes 1,720 polls, so 20,000 is a 11.6x
      -- margin, and one poll is about five cycles -- so the cap costs at most
      -- ~100 us of simulated time.  A larger cap makes a HUNG mutant run to
      -- `--stop-time` and be classified WEDGE, which is an ABORT and says
      -- NOTHING about whether this bench can see the defect.  A cap the bench
      -- itself hits turns the same mutant into a P3 KILL, which is the
      -- evidence that was wanted.  MEASURED: at a cap of 200,000 the mutation
      -- table took about seven minutes per hung row.
      if nwait > 20000 then
        n_bad_poll <= n_bad_poll + 1;
        report "tb_fk33_seam: STATUS never reached (done | err) after "
             & integer'image(nwait) & " polls.  A host would hang here."
          severity error;
        exit;
      end if;
    end loop;
    report "tb_fk33_seam: token " & integer'image(t) & " seam STATUS "
         & integer'image(st) & " after " & integer'image(nwait) & " polls."
      severity note;
    if (st mod 2) /= 1 then
      n_bad_poll <= n_bad_poll + 1;
      report "tb_fk33_seam: the seam token did not complete cleanly; "
           & "STATUS = " & integer'image(st) severity error;
    end if;

    -- The reference side, waited the direct way.
    -- `tok_done` IS A LEVEL held until `tok_ack`, so it is very likely to be
    -- HIGH ALREADY by the time this line runs -- the seam poll above took
    -- 1,720 AXI reads.  `wait until` needs an EVENT, so an unguarded wait
    -- here sits for the whole 1 ms timeout on a passing run.  MEASURED on
    -- the first version of this bench: 1,000,000 idle cycles.
    if r_tok_done /= '1' then
      wait until r_tok_done = '1' for 1 ms;
    end if;
    if r_tok_done /= '1' then
      n_bad_acct <= n_bad_acct + 1;
      report "tb_fk33_seam: the REFERENCE DUT never reached tok_done.  "
           & "Nothing about the seam can be concluded from this run."
        severity error;
    end if;
    wait until rising_edge(clk);
    r_tok_ack <= '1';
    wait until rising_edge(clk);
    r_tok_ack <= '0';
    tick(4);

    -- ==================================================================
    -- P2: THE COMPLETION ACCOUNTING.  `steps_done` must equal the table
    -- length; that is seq_desc_fetch's own counting identity.
    -- ==================================================================
    if to_integer(r_steps_done) /= NSTEP then
      n_bad_acct <= n_bad_acct + 1;
      report "tb_fk33_seam: reference steps_done "
           & integer'image(to_integer(r_steps_done)) & " /= "
           & integer'image(NSTEP) severity error;
    end if;
    if r_steps_done /= s_steps_done or r_err /= s_err
       or (r_err = '1' and r_err_code /= s_err_code) then
      n_bad_acct <= n_bad_acct + 1;
      report "tb_fk33_seam: the two DUTs disagree on the completion.  "
           & "reference steps_done "
           & integer'image(to_integer(r_steps_done)) & " err "
           & std_logic'image(r_err) & "; seam steps_done "
           & integer'image(to_integer(s_steps_done)) & " err "
           & std_logic'image(s_err) severity error;
    end if;

    -- P4: the seam's own readback of the same facts.
    axi_ri(A_ERR_INFO, iv);
    if ((iv / 65536) mod 2048) /= to_integer(s_steps_done) then
      n_bad_rback <= n_bad_rback + 1;
      report "tb_fk33_seam: ERR_INFO steps_done field "
           & integer'image((iv / 65536) mod 2048) & " /= the DUT's "
           & integer'image(to_integer(s_steps_done)) severity error;
    end if;
    axi_ri(A_SEQ_POS, iv);
    if iv /= t + 1 then
      n_bad_rback <= n_bad_rback + 1;
      report "tb_fk33_seam: SEQ_POS after token " & integer'image(t)
           & " reads " & integer'image(iv) & ", expected "
           & integer'image(t + 1) & ".  The card's own position must advance "
           & "or the next GO is refused." severity error;
    end if;

    -- ==================================================================
    -- P1: THE NUMBERS.  Every element of R_X, both sides, plus the
    -- landmark.  The seam side is read ONLY through the XOUT window.
    -- ==================================================================
    axi_wi(A_WIN_SEL, 3);
    axi_wi(A_WIN_ADDR, 0);
    -- R_X's LIVE EXTENT is `hidden`, not `REGMAX`.  Every region is
    -- allocated the widest region's size, so elements `hidden .. REGMAX-1`
    -- of R_X are never written by anything and read back as 'U' on both
    -- sides.  Comparing them would compare two metavalues through
    -- `to_integer`, which is not a comparison, and it costs a NUMERIC_STD
    -- warning per element per side.
    for i in 0 to SHAPE.hidden-1 loop
      r_hr_reg  <= R_X;
      r_hr_addr <= i;
      wait until rising_edge(clk);
      wait for 0.1 ns;
      rx_ref := to_integer(r_hr_data);
      axi_ri(A_WIN_DATA, rx_sea);
      if rx_ref /= rx_sea then
        if n_bad_val < 8 then
          report "tb_fk33_seam: R_X(" & integer'image(i) & ") reference "
               & integer'image(rx_ref) & ", seam " & integer'image(rx_sea)
            severity error;
        end if;
        n_bad_val <= n_bad_val + 1;
        wait for 0 ns;
      end if;
      if i = 0 then
        xt0 := rx_ref;
        if t = 0 then x0 := rx_ref; end if;
      end if;
      h_ref := hash_of(rx_ref, h_ref, i);
      h_sea := hash_of(rx_sea, h_sea, i);
    end loop;

    report "tb_fk33_seam: token " & integer'image(t)
         & " R_X(0) = " & integer'image(xt0)
         & " hash(R_X) = " & integer'image(h_ref)
         & " (seam hash " & integer'image(h_sea) & ")" severity note;
    -- THE LANDMARK IS TOKEN 0's, and the hash accumulator is cleared between
    -- tokens so it stays token 0's whatever NTOK is.  P1 compares EVERY
    -- token; the landmark pins one, and the two jobs are different.
    if t = 0 then
      h0_ref := h_ref;
    end if;
    h_ref := 0;
    h_sea := 0;

    end loop;   -- the token loop

    -- P5: the landmark.
    if EXP_X0 /= integer'low and x0 /= EXP_X0 then
      n_bad_land <= n_bad_land + 1;
      report "tb_fk33_seam: R_X(0) = " & integer'image(x0)
           & ", the pinned landmark is " & integer'image(EXP_X0)
        severity error;
    end if;
    if EXP_XSUM >= 0 and h0_ref /= EXP_XSUM then
      n_bad_land <= n_bad_land + 1;
      report "tb_fk33_seam: token 0 hash(R_X) = " & integer'image(h0_ref)
           & ", the pinned landmark is " & integer'image(EXP_XSUM)
        severity error;
    end if;
    if EXP_X0 = integer'low and EXP_XSUM < 0 then
      report "tb_fk33_seam: NOTE -- this run is NOT gated on values.  Both "
           & "landmarks are at their sentinels." severity note;
    end if;

    tick(4);

    nfail := n_bad_val + n_bad_acct + n_bad_poll + n_bad_rback
           + n_bad_land + n_bad_gate;
    report "tb_fk33_seam: P1 value " & integer'image(n_bad_val)
         & "  P2 accounting " & integer'image(n_bad_acct)
         & "  P3 poll " & integer'image(n_bad_poll)
         & "  P4 readback " & integer'image(n_bad_rback)
         & "  P5 landmark " & integer'image(n_bad_land)
         & "  P6 go-gate " & integer'image(n_bad_gate) severity note;

    -- THE VERDICT LINE HAS TO SATISFY TWO READERS AND THEY DISAGREE.
    -- MEASURED, both of them, in that order:
    --   * `sim/regress.sh`'s FAIL_RE matches a bare `\bFAIL\b`, and its
    --     zero-counter neutraliser only strips `FAIL = 0` / `FAIL: 0`, WITH a
    --     separator.  A line reading `OVERALL PASS 1 FAIL 0` is therefore
    --     judged a FAILURE -- the row came back `FAIL sim:tb_fk33_seam`
    --     quoting its own passing line.
    --   * `sim/mutverdict.py` matches `<entity>\s*:?\s*PASS\b`, so
    --     `tb_fk33_seam RESULT: PASS` does not match it either and the
    --     unmutated ANCHOR of the mutation table classified ABORT:NOVERDICT.
    -- The form that satisfies both is the house one, `<entity>: PASS -- `.
    if nfail = 0 then
      report "tb_fk33_seam: PASS -- a whole token ran with "
           & "llama_top's host face driven by fk33_seam and by nothing "
           & "else, and every element of R_X, the completion accounting "
           & "and the card's own position match the direct drive.  NO "
           & "ARITHMETIC ORACLE RAN: see the header." severity note;
    else
      report "tb_fk33_seam: FAIL -- " & integer'image(nfail)
           & " faults." severity error;
    end if;

    done_flag <= true;
    running   <= false;
    wait;
  end process;

end architecture;
